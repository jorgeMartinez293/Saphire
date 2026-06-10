import Foundation
import SQLite3

// MARK: - Mail reading (Apple Mail "Envelope Index", read-only)
//
// We read Apple Mail's metadata store directly instead of driving Mail.app via
// AppleScript. The AppleScript path needs an Automation (Apple Events) TCC grant;
// for Saphire — an LSUIElement background agent — that permission prompt never
// surfaces, so `osascript` blocks forever and the tool call hangs with no result
// and no visible prompt. Reading the SQLite store needs only Full Disk Access
// (which the WhatsApp reader already requires), so both tools share one grant.
//
// Layout:
//   ~/Library/Mail/V<n>/MailData/Envelope Index   one SQLite db, all accounts
//     messages   one row per message (sender→addresses, subject→subjects,
//                date_received epoch, read 0/1, mailbox→mailboxes, summary, …)
//     addresses  ROWID → address + comment (display name)
//     subjects   ROWID → subject text
//     mailboxes  ROWID → url (…/INBOX, …/Bandeja de entrada for Exchange)
// Message bodies live in <ROWID>.emlx files on disk, read on demand for full_body.

/// Debug trace gate: set the SAPHIRE_DEBUG environment variable to write the
/// /tmp/saphire-req.log trace. Off by default — the trace sits on hot paths
/// (every chat request, every tool call) and each line is synchronous file I/O.
let saphireDebugEnabled = ProcessInfo.processInfo.environment["SAPHIRE_DEBUG"] != nil

/// Appends a timestamped line to /tmp/saphire-req.log. No-op unless
/// SAPHIRE_DEBUG is set; @autoclosure so callers don't even build the
/// interpolated message when logging is off.
func saphireDebug(_ s: @autoclosure () -> String) {
    guard saphireDebugEnabled else { return }
    let line = "[\(Date())] \(s())\n"
    if let h = FileHandle(forWritingAtPath: "/tmp/saphire-req.log") {
        h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close()
    } else {
        try? line.write(toFile: "/tmp/saphire-req.log", atomically: true, encoding: .utf8)
    }
}

/// Errors surfaced as the tool result text.
private func mailError(_ m: String) -> String { "Error al leer el correo: \(m)" }

/// Newest `~/Library/Mail/V<n>` directory (Mail bumps the version on upgrades).
private func mailVersionDir() -> URL? {
    let home = FileManager.default.homeDirectoryForCurrentUser
    let mail = home.appendingPathComponent("Library/Mail")
    guard let entries = try? FileManager.default.contentsOfDirectory(atPath: mail.path) else {
        return nil
    }
    let versions = entries
        .filter { $0.hasPrefix("V") && Int($0.dropFirst()) != nil }
        .sorted { (Int($0.dropFirst()) ?? 0) < (Int($1.dropFirst()) ?? 0) }
    guard let latest = versions.last else { return nil }
    return mail.appendingPathComponent(latest)
}

/// Path to the live Envelope Index inside the newest Mail version dir.
private func envelopeIndexPath() -> String? {
    mailVersionDir()?.appendingPathComponent("MailData/Envelope Index").path
}

/// Reads matching messages from Mail's inbox(es) (all accounts aggregated).
/// `query` filters by sender/subject (empty = most recent). Read-only. Same
/// external signature as the old AppleScript reader, so the call site is unchanged.
func readEmailViaMail(query: String, unreadOnly: Bool, limit: Int,
                      fullBody: Bool, maxChars: Int = 6000) async throws -> String {
    let lim = max(1, min(limit, 25))
    let q = query.trimmingCharacters(in: .whitespacesAndNewlines)

    saphireDebug("readEmailViaMail START q=\(q) unread=\(unreadOnly) limit=\(lim) full=\(fullBody)")
    return await withCheckedContinuation { (cont: CheckedContinuation<String, Never>) in
        DispatchQueue.global(qos: .userInitiated).async {
            saphireDebug("readEmailViaMail on global queue")
            let fm = FileManager.default
            guard let store = envelopeIndexPath() else {
                cont.resume(returning: mailError("no se encontró Mail. ¿Está configurada la "
                    + "app Mail con alguna cuenta?"))
                return
            }
            // Tell "file missing" from "blocked by macOS": reading Mail's data needs
            // Full Disk Access, and without it TCC hides the path (no auto-prompt).
            saphireDebug("mail store=\(store) exists=\(fm.fileExists(atPath: store))")
            guard fm.fileExists(atPath: store) else {
                let dir = URL(fileURLWithPath: store).deletingLastPathComponent().path
                if !fm.isReadableFile(atPath: dir) {
                    cont.resume(returning: mailError("macOS está bloqueando el acceso a los datos "
                        + "de Mail. Concede a Saphire «Acceso a disco completo» en Ajustes del "
                        + "Sistema → Privacidad y seguridad → Acceso a disco completo, y reinicia "
                        + "Saphire."))
                } else {
                    cont.resume(returning: mailError("no se encontró el índice de Mail. ¿Has "
                        + "abierto Mail y añadido una cuenta?"))
                }
                return
            }
            // Copy the store (+ WAL/SHM) to temp so we read the latest committed
            // data without touching or locking Mail's live files.
            guard let work = try? copyMailStoreToTemp(store) else {
                cont.resume(returning: mailError("no se pudo preparar una copia del índice de Mail."))
                return
            }
            defer { try? fm.removeItem(at: work.deletingLastPathComponent()) }
            saphireDebug("mail store copied to temp ok")

            var db: OpaquePointer?
            let uri = "file:\(work.path)?mode=ro"
            guard sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else {
                sqlite3_close(db)
                cont.resume(returning: mailError("no se pudo abrir el índice de Mail."))
                return
            }
            defer { sqlite3_close(db) }

            saphireDebug("mail db opened, querying…")
            let out = queryInbox(db, query: q, unreadOnly: unreadOnly, limit: lim, fullBody: fullBody)
            saphireDebug("mail query done, out chars=\(out.count)")
            cont.resume(returning: out.count > maxChars ? String(out.prefix(maxChars)) + "…" : out)
        }
    }
}

/// Copies "Envelope Index" + its -wal/-shm into a fresh temp dir, returns the copy.
private func copyMailStoreToTemp(_ storePath: String) throws -> URL {
    let fm = FileManager.default
    let dir = fm.temporaryDirectory.appendingPathComponent("saphire-mail-\(UUID().uuidString)")
    try fm.createDirectory(at: dir, withIntermediateDirectories: true)
    let dest = dir.appendingPathComponent("EnvelopeIndex")
    for suffix in ["", "-wal", "-shm"] {
        let src = URL(fileURLWithPath: storePath + suffix)
        guard fm.fileExists(atPath: src.path) else { continue }
        let to = URL(fileURLWithPath: dest.path + suffix)
        try? fm.removeItem(at: to)
        try fm.copyItem(at: src, to: to)
    }
    return dest
}

/// Runs the inbox query and renders one block per message. When `fullBody` is
/// set, the message's .emlx is read from disk and its text appended.
private func queryInbox(_ db: OpaquePointer?, query: String, unreadOnly: Bool,
                        limit: Int, fullBody: Bool) -> String {
    // Aggregate every account's inbox: IMAP "…/INBOX", Exchange "…/Bandeja de entrada".
    var sql = """
    SELECT m.date_received, m.read, a.comment, a.address, s.subject, m.ROWID
    FROM messages m
    LEFT JOIN addresses a ON m.sender = a.ROWID
    LEFT JOIN subjects s ON m.subject = s.ROWID
    WHERE m.mailbox IN (
        SELECT ROWID FROM mailboxes
        WHERE url LIKE '%/INBOX' OR url LIKE '%Bandeja%20de%20entrada'
    )
    AND m.deleted = 0
    """
    if unreadOnly { sql += " AND m.read = 0" }
    if !query.isEmpty { sql += " AND (s.subject LIKE ? OR a.comment LIKE ? OR a.address LIKE ?)" }
    sql += " ORDER BY m.date_received DESC LIMIT ?;"

    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
        return mailError("consulta de correo fallida.")
    }
    defer { sqlite3_finalize(stmt) }
    var idx: Int32 = 1
    if !query.isEmpty {
        let like = "%\(query)%"
        mailBindText(stmt, idx, like); idx += 1
        mailBindText(stmt, idx, like); idx += 1
        mailBindText(stmt, idx, like); idx += 1
    }
    sqlite3_bind_int(stmt, idx, Int32(limit))

    struct Row { let date: Double; let read: Bool; let name: String; let addr: String
                 let subject: String; let rowid: Int64 }
    var rows: [Row] = []
    while sqlite3_step(stmt) == SQLITE_ROW {
        rows.append(Row(
            date: sqlite3_column_double(stmt, 0),
            read: sqlite3_column_int(stmt, 1) == 1,
            name: mailColText(stmt, 2) ?? "",
            addr: mailColText(stmt, 3) ?? "",
            subject: mailColText(stmt, 4) ?? "(sin asunto)",
            rowid: sqlite3_column_int64(stmt, 5)))
    }
    if rows.isEmpty {
        return query.isEmpty
            ? (unreadOnly ? "No hay correos sin leer en el inbox." : "No hay correos en el inbox.")
            : "No se encontraron correos que coincidan con «\(query)»."
    }

    // For full_body, resolve the .emlx files for all matched messages in one walk.
    let bodies: [Int64: String] = fullBody
        ? emlxBodies(forROWIDs: rows.map { $0.rowid }) : [:]

    var blocks: [String] = []
    for (i, r) in rows.enumerated() {
        let from = r.name.isEmpty ? r.addr : (r.addr.isEmpty ? r.name : "\(r.name) <\(r.addr)>")
        var b = "—— Correo \(i + 1) ——\n"
        b += "De: \(from)\n"
        b += "Asunto: \(r.subject)\n"
        b += "Fecha: \(mailDate(r.date))\n"
        b += "Estado: \(r.read ? "leído" : "NO leído")\n"
        if fullBody {
            let body = bodies[r.rowid]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            b += "Cuerpo:\n\(body.isEmpty ? "[no se pudo extraer el cuerpo]" : body)\n"
        }
        blocks.append(b)
    }
    return blocks.joined(separator: "\n")
}

// MARK: - .emlx body extraction

/// Walks the newest Mail version dir once, collecting the text body of every
/// `<ROWID>.emlx` (or `.partial.emlx`) whose ROWID is wanted. One pass keeps it
/// cheap even though the Mail tree is large.
private func emlxBodies(forROWIDs ids: [Int64]) -> [Int64: String] {
    guard let root = mailVersionDir() else { return [:] }
    let wanted = Set(ids)
    var names: [String: Int64] = [:]
    for id in ids {
        names["\(id).emlx"] = id
        names["\(id).partial.emlx"] = id
    }
    var found: [Int64: URL] = [:]
    let fm = FileManager.default
    guard let en = fm.enumerator(at: root, includingPropertiesForKeys: nil,
                                 options: [.skipsHiddenFiles]) else { return [:] }
    for case let url as URL in en {
        guard let id = names[url.lastPathComponent] else { continue }
        // Prefer the full .emlx over a .partial.emlx for the same message.
        if found[id] == nil || url.lastPathComponent.hasSuffix(".emlx")
            && !url.lastPathComponent.hasSuffix(".partial.emlx") {
            found[id] = url
        }
        if found.count == wanted.count { break }
    }
    var out: [Int64: String] = [:]
    for (id, url) in found {
        if let raw = emlxMessage(url) { out[id] = plainText(fromMessage: raw) }
    }
    return out
}

/// Extracts the RFC822 message from an .emlx file. Format: an ASCII byte-count
/// line, then exactly that many message bytes, then a trailing plist.
private func emlxMessage(_ url: URL) -> String? {
    guard let data = try? Data(contentsOf: url),
          let nl = data.firstIndex(of: 0x0A) else { return nil }
    let head = String(data: data[data.startIndex..<nl], encoding: .ascii)?
        .trimmingCharacters(in: .whitespaces) ?? ""
    guard let count = Int(head) else { return nil }
    let start = data.index(after: nl)
    let end = data.index(start, offsetBy: count, limitedBy: data.endIndex) ?? data.endIndex
    // ISO Latin-1 never fails and preserves bytes; MIME decoding happens later.
    return String(data: data[start..<end], encoding: .isoLatin1)
}

/// Best-effort plain text from an RFC822 message: prefer a text/plain part,
/// fall back to text/html (tags stripped), decoding base64/quoted-printable.
private func plainText(fromMessage raw: String) -> String {
    let (headers, body) = splitHeadersBody(raw)
    let ctype = headerValue("content-type", in: headers).lowercased()

    if ctype.contains("multipart"), let boundary = mimeBoundary(ctype) {
        let parts = body.components(separatedBy: "--\(boundary)")
        var htmlFallback: String?
        for part in parts {
            let (ph, pb) = splitHeadersBody(part)
            let pt = headerValue("content-type", in: ph).lowercased()
            let cte = headerValue("content-transfer-encoding", in: ph).lowercased()
            if pt.contains("text/plain") {
                return decodeBody(pb, cte: cte)
            } else if pt.contains("text/html"), htmlFallback == nil {
                htmlFallback = stripHTML(decodeBody(pb, cte: cte))
            } else if pt.contains("multipart") {
                // Nested multipart/alternative inside multipart/mixed, etc.
                let nested = plainText(fromMessage: part)
                if !nested.isEmpty { return nested }
            }
        }
        if let h = htmlFallback { return h }
        return ""
    }

    let cte = headerValue("content-transfer-encoding", in: headers).lowercased()
    let decoded = decodeBody(body, cte: cte)
    return ctype.contains("text/html") ? stripHTML(decoded) : decoded
}

/// Splits a MIME entity into its header block and body at the first blank line.
private func splitHeadersBody(_ s: String) -> (headers: String, body: String) {
    if let r = s.range(of: "\r\n\r\n") {
        return (String(s[..<r.lowerBound]), String(s[r.upperBound...]))
    }
    if let r = s.range(of: "\n\n") {
        return (String(s[..<r.lowerBound]), String(s[r.upperBound...]))
    }
    return (s, "")
}

/// Reads one header's value, unfolding RFC822 continuation lines.
private func headerValue(_ name: String, in headers: String) -> String {
    let lines = headers.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
    var i = 0
    while i < lines.count {
        let line = lines[i]
        if line.lowercased().hasPrefix(name.lowercased() + ":") {
            var value = String(line.dropFirst(name.count + 1))
            var j = i + 1
            while j < lines.count, lines[j].first == " " || lines[j].first == "\t" {
                value += " " + lines[j].trimmingCharacters(in: .whitespaces)
                j += 1
            }
            return value.trimmingCharacters(in: .whitespaces)
        }
        i += 1
    }
    return ""
}

/// Pulls the boundary token out of a multipart Content-Type value.
private func mimeBoundary(_ contentType: String) -> String? {
    guard let r = contentType.range(of: "boundary=") else { return nil }
    var b = String(contentType[r.upperBound...])
    if let semi = b.firstIndex(of: ";") { b = String(b[..<semi]) }
    b = b.trimmingCharacters(in: .whitespaces)
    if b.hasPrefix("\"") && b.hasSuffix("\"") && b.count >= 2 { b = String(b.dropFirst().dropLast()) }
    return b.isEmpty ? nil : b
}

/// Decodes a part body per its Content-Transfer-Encoding (base64 / quoted-
/// printable / identity), interpreting the result as UTF-8 when possible.
private func decodeBody(_ body: String, cte: String) -> String {
    let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
    if cte.contains("base64") {
        let cleaned = trimmed.components(separatedBy: .whitespacesAndNewlines).joined()
        if let d = Data(base64Encoded: cleaned),
           let s = String(data: d, encoding: .utf8) ?? String(data: d, encoding: .isoLatin1) {
            return s
        }
        return trimmed
    }
    if cte.contains("quoted-printable") {
        return decodeQuotedPrintable(trimmed)
    }
    return trimmed
}

/// Minimal quoted-printable decoder (=XX hex bytes + soft line breaks),
/// reinterpreting the assembled bytes as UTF-8.
private func decodeQuotedPrintable(_ s: String) -> String {
    var bytes: [UInt8] = []
    let chars = Array(s)
    var i = 0
    while i < chars.count {
        let c = chars[i]
        if c == "=" && i + 2 < chars.count {
            let hex = String(chars[i + 1]) + String(chars[i + 2])
            if hex == "\r\n" || (chars[i + 1] == "\r" && chars[i + 2] == "\n") {
                i += 3; continue
            }
            if chars[i + 1] == "\n" { i += 2; continue } // soft break (LF only)
            if let byte = UInt8(hex, radix: 16) { bytes.append(byte); i += 3; continue }
        }
        if c == "=" && i + 1 < chars.count && chars[i + 1] == "\n" { i += 2; continue }
        bytes.append(contentsOf: Array(String(c).utf8))
        i += 1
    }
    return String(bytes: bytes, encoding: .utf8) ?? String(bytes: bytes, encoding: .isoLatin1) ?? s
}

/// Crudely strips HTML to readable text: drops script/style, turns block tags
/// into newlines, removes the rest, and unescapes the common entities.
private func stripHTML(_ html: String) -> String {
    var s = html
    for tag in ["script", "style", "head"] {
        s = s.replacingOccurrences(
            of: "<\(tag)[^>]*>.*?</\(tag)>", with: " ",
            options: [.regularExpression, .caseInsensitive])
    }
    s = s.replacingOccurrences(of: "<(br|/p|/div|/tr|/li|/h[1-6])[^>]*>",
                               with: "\n", options: [.regularExpression, .caseInsensitive])
    s = s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
    let entities = ["&nbsp;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">",
                    "&quot;": "\"", "&#39;": "'", "&apos;": "'"]
    for (k, v) in entities { s = s.replacingOccurrences(of: k, with: v) }
    // Collapse runs of blank lines/space the stripping leaves behind.
    s = s.replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
    s = s.replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
    return s.trimmingCharacters(in: .whitespacesAndNewlines)
}

// MARK: - sqlite + date helpers (file-local; mirror WhatsApp.swift)

private func mailColText(_ stmt: OpaquePointer?, _ col: Int32) -> String? {
    guard let c = sqlite3_column_text(stmt, col) else { return nil }
    return String(cString: c)
}

private func mailBindText(_ stmt: OpaquePointer?, _ idx: Int32, _ value: String) {
    let TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    sqlite3_bind_text(stmt, idx, value, -1, TRANSIENT)
}

/// Formats a Unix timestamp (Mail stores date_received as epoch seconds) as a
/// short local string.
private func mailDate(_ epoch: Double) -> String {
    guard epoch > 0 else { return "—" }
    let df = DateFormatter()
    df.locale = Locale(identifier: "es_ES")
    df.dateFormat = "d MMM yyyy HH:mm"
    return df.string(from: Date(timeIntervalSince1970: epoch))
}
