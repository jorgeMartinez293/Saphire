import Foundation
import SQLite3

// MARK: - WhatsApp reading (ChatStorage.sqlite)
//
// The macOS WhatsApp app keeps its messages in an UNENCRYPTED Core Data SQLite
// store inside its shared group container. We read it directly (read-only) — no
// AppleScript, no UI scripting — to list recent chats, read a chat, or search
// the message text. Tables of interest:
//   ZWACHATSESSION      one row per chat (ZPARTNERNAME, ZUNREADCOUNT, …)
//   ZWAMESSAGE          one row per message (ZTEXT, ZISFROMME, ZMESSAGEDATE, …)
//   ZWAGROUPMEMBER      group sender → ZMEMBERJID
//   ZWAPROFILEPUSHNAME  JID → display name (resolves group senders)
// Core Data stores dates as seconds since 2001-01-01, hence the +978307200.

/// The WhatsApp reading tool exposed to the model. Read-only.
let readWhatsAppTool = ToolSpec.function(
    name: "read_whatsapp",
    description: "Lee los mensajes de WhatsApp del usuario desde la app de WhatsApp "
        + "del Mac. SOLO LECTURA: nunca envía ni borra nada. Tres modos: (1) sin "
        + "parámetros, lista los chats recientes con su nombre, mensajes sin leer y "
        + "último mensaje; (2) con 'chat', abre ese chat y devuelve sus mensajes más "
        + "recientes; (3) con 'query', busca ese texto en todos los mensajes. En "
        + "grupos identifica quién escribió cada mensaje. Se puede filtrar por rango "
        + "de fechas ('since'/'until') y por solo no leídos ('unread_only').",
    properties: [
        "chat": .init(type: "string",
                      description: "Nombre (o parte del nombre) del chat o contacto a abrir "
                          + "para leer sus mensajes. Déjalo vacío para listar los chats."),
        "query": .init(type: "string",
                       description: "Texto a buscar dentro de los mensajes de todos los chats. "
                           + "Si se indica junto con 'chat', la búsqueda se limita a ese chat."),
        "since": .init(type: "string",
                       description: "Fecha mínima (incluida) en formato \"YYYY-MM-DD\" o "
                           + "\"YYYY-MM-DD HH:MM\". Solo mensajes/chats a partir de ese momento. "
                           + "Para fechas relativas («ayer», «esta semana») llama antes a get_datetime."),
        "until": .init(type: "string",
                       description: "Fecha máxima (incluida) en formato \"YYYY-MM-DD\" o "
                           + "\"YYYY-MM-DD HH:MM\". Solo mensajes/chats hasta ese momento."),
        "unread_only": .init(type: "boolean",
                             description: "Si es true: al listar, solo chats con mensajes sin leer; "
                                 + "al abrir un chat, solo sus mensajes sin leer."),
        "limit": .init(type: "integer",
                       description: "Número máximo de chats o mensajes a devolver (1–50; por defecto 15).")
    ],
    required: []
)

/// Errors surfaced as the tool result text.
private func waError(_ m: String) -> String { "Error al leer WhatsApp: \(m)" }

/// Absolute path to the live ChatStorage.sqlite inside WhatsApp's group container.
private func whatsAppStorePath() -> String {
    let home = FileManager.default.homeDirectoryForCurrentUser
    return home
        .appendingPathComponent("Library/Group Containers/group.net.whatsapp.WhatsApp.shared/ChatStorage.sqlite")
        .path
}

/// Core Data reference date offset (2001-01-01 → 1970-01-01) in seconds.
private let coreDataEpoch: Double = 978_307_200

/// Reads WhatsApp messages. Dispatches on which arguments are present:
/// `chat` → read that chat; else `query` → search; else → list recent chats.
/// Runs off the main thread because sqlite calls block.
func readWhatsApp(chat: String, query: String, since: String, until: String,
                  unreadOnly: Bool, limit: Int, maxChars: Int = 6000) async -> String {
    let lim = max(1, min(limit, 50))
    let chatName = chat.trimmingCharacters(in: .whitespacesAndNewlines)
    let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
    // Parse the optional date bounds into Core Data timestamps. A date-only
    // `until` is bumped to the end of that day so the whole day is included.
    let sinceTS = parseWADate(since, endOfDay: false)
    let untilTS = parseWADate(until, endOfDay: true)

    saphireDebug("readWhatsApp START chat=\(chatName) q=\(q)")
    return await withCheckedContinuation { (cont: CheckedContinuation<String, Never>) in
        DispatchQueue.global(qos: .userInitiated).async {
            saphireDebug("readWhatsApp on global queue")
            let store = whatsAppStorePath()
            saphireDebug("wa store exists=\(FileManager.default.fileExists(atPath: store))")
            // Distinguish "file missing" from "blocked by macOS". WhatsApp's store
            // lives in another app's group container, so reading it needs Full Disk
            // Access. When FDA is missing, TCC hides the path: `fileExists` returns
            // false even though the file is there — and macOS shows NO prompt (FDA is
            // never auto-requested). Probe the parent dir to tell the cases apart so
            // we don't blame a missing install for what is really a permission block.
            let fm = FileManager.default
            guard fm.fileExists(atPath: store) else {
                let container = URL(fileURLWithPath: store).deletingLastPathComponent().path
                if !fm.isReadableFile(atPath: container) {
                    cont.resume(returning: waError("macOS está bloqueando el acceso a los datos de "
                        + "WhatsApp. Concede a Saphire «Acceso a disco completo» en Ajustes del "
                        + "Sistema → Privacidad y seguridad → Acceso a disco completo, y reinicia "
                        + "Saphire. (No salta aviso automático: hay que activarlo a mano.)"))
                } else {
                    cont.resume(returning: waError("no se encontró la base de datos de WhatsApp. "
                        + "¿Está instalada la app de WhatsApp y has iniciado sesión?"))
                }
                return
            }
            // Copy the store (and its WAL/SHM) to a temp dir so we read the latest
            // committed + WAL data without touching or locking WhatsApp's files.
            guard let work = try? copyStoreToTemp(store) else {
                cont.resume(returning: waError("no se pudo preparar una copia de la base de datos."))
                return
            }
            defer { try? FileManager.default.removeItem(at: work.deletingLastPathComponent()) }

            var db: OpaquePointer?
            // Open read-only via URI so we never modify the copy.
            let uri = "file:\(work.path)?mode=ro"
            guard sqlite3_open_v2(uri, &db,
                                  SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else {
                sqlite3_close(db)
                cont.resume(returning: waError("no se pudo abrir la base de datos de WhatsApp."))
                return
            }
            defer { sqlite3_close(db) }

            let out: String
            if !chatName.isEmpty {
                out = readChat(db, chatName: chatName, query: q, since: sinceTS,
                               until: untilTS, unreadOnly: unreadOnly, limit: lim)
            } else if !q.isEmpty {
                out = searchMessages(db, query: q, since: sinceTS, until: untilTS,
                                     unreadOnly: unreadOnly, limit: lim)
            } else {
                out = listChats(db, since: sinceTS, until: untilTS,
                                unreadOnly: unreadOnly, limit: lim)
            }
            cont.resume(returning: out.count > maxChars ? String(out.prefix(maxChars)) + "…" : out)
        }
    }
}

/// Copies ChatStorage.sqlite + -wal + -shm into a fresh temp directory and
/// returns the URL of the copied main file. Copying the WAL/SHM alongside keeps
/// the most recent (not-yet-checkpointed) messages visible.
private func copyStoreToTemp(_ storePath: String) throws -> URL {
    let fm = FileManager.default
    let dir = fm.temporaryDirectory.appendingPathComponent("saphire-wa-\(UUID().uuidString)")
    try fm.createDirectory(at: dir, withIntermediateDirectories: true)
    let dest = dir.appendingPathComponent("ChatStorage.sqlite")
    for suffix in ["", "-wal", "-shm"] {
        let src = URL(fileURLWithPath: storePath + suffix)
        guard fm.fileExists(atPath: src.path) else { continue }
        let to = URL(fileURLWithPath: dest.path + suffix)
        try? fm.removeItem(at: to)
        try fm.copyItem(at: src, to: to)
    }
    return dest
}

/// Lists the most recently active chats with unread count and a last-message
/// preview (pulled from the actual last message's text, not the encoded blob).
private func listChats(_ db: OpaquePointer?, since: Double?, until: Double?,
                       unreadOnly: Bool, limit: Int) -> String {
    var sql = """
    SELECT c.ZPARTNERNAME, c.ZUNREADCOUNT, c.ZSESSIONTYPE, c.ZLASTMESSAGEDATE, lm.ZTEXT
    FROM ZWACHATSESSION c
    LEFT JOIN ZWAMESSAGE lm ON c.ZLASTMESSAGE = lm.Z_PK
    WHERE c.ZLASTMESSAGEDATE IS NOT NULL AND c.ZHIDDEN = 0
    """
    if unreadOnly { sql += " AND c.ZUNREADCOUNT > 0" }
    if since != nil { sql += " AND c.ZLASTMESSAGEDATE >= ?" }
    if until != nil { sql += " AND c.ZLASTMESSAGEDATE <= ?" }
    sql += " ORDER BY c.ZLASTMESSAGEDATE DESC LIMIT ?;"

    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
        return waError("consulta de chats fallida.")
    }
    defer { sqlite3_finalize(stmt) }
    var idx: Int32 = 1
    if let since { sqlite3_bind_double(stmt, idx, since); idx += 1 }
    if let until { sqlite3_bind_double(stmt, idx, until); idx += 1 }
    sqlite3_bind_int(stmt, idx, Int32(limit))

    var lines: [String] = []
    while sqlite3_step(stmt) == SQLITE_ROW {
        let name = colText(stmt, 0) ?? "(sin nombre)"
        let unread = sqlite3_column_int(stmt, 1)
        let isGroup = sqlite3_column_int(stmt, 2) == 1
        let date = waDate(sqlite3_column_double(stmt, 3))
        let preview = (colText(stmt, 4)?.replacingOccurrences(of: "\n", with: " "))
            .map { $0.count > 50 ? String($0.prefix(50)) + "…" : $0 } ?? "[multimedia]"
        var line = "• \(name)"
        if isGroup { line += " [grupo]" }
        if unread > 0 { line += " — \(unread) sin leer" }
        line += "\n  \(date) · \(preview)"
        lines.append(line)
    }
    if lines.isEmpty {
        return unreadOnly ? "No hay chats de WhatsApp sin leer en ese criterio."
                          : "No hay chats de WhatsApp en ese criterio."
    }
    let title = unreadOnly ? "Chats de WhatsApp sin leer" : "Chats de WhatsApp recientes"
    return title + ":\n\n" + lines.joined(separator: "\n")
}

/// Reads the most recent messages of the chat whose name best matches
/// `chatName` (case-insensitive substring; most recently active wins). When
/// `query` is non-empty, only messages containing it are returned.
private func readChat(_ db: OpaquePointer?, chatName: String, query: String,
                      since: Double?, until: Double?, unreadOnly: Bool, limit: Int) -> String {
    // Resolve the chat: pick the most recently active session matching the name.
    let findSQL = """
    SELECT Z_PK, ZPARTNERNAME, ZSESSIONTYPE, ZUNREADCOUNT FROM ZWACHATSESSION
    WHERE ZPARTNERNAME LIKE ? AND ZHIDDEN = 0
    ORDER BY ZLASTMESSAGEDATE DESC LIMIT 1;
    """
    var find: OpaquePointer?
    guard sqlite3_prepare_v2(db, findSQL, -1, &find, nil) == SQLITE_OK else {
        return waError("consulta de chat fallida.")
    }
    bindText(find, 1, "%\(chatName)%")
    guard sqlite3_step(find) == SQLITE_ROW else {
        sqlite3_finalize(find)
        return "No se encontró ningún chat de WhatsApp que coincida con «\(chatName)»."
    }
    let chatPK = sqlite3_column_int64(find, 0)
    let partner = colText(find, 1) ?? chatName
    let isGroup = sqlite3_column_int(find, 2) == 1
    let unreadCount = Int(sqlite3_column_int(find, 3))
    sqlite3_finalize(find)

    // WhatsApp has no per-message read flag for incoming messages, so "unread"
    // means the chat's last `ZUNREADCOUNT` incoming messages: filter to incoming
    // and cap the limit at that count.
    if unreadOnly && unreadCount == 0 {
        return "El chat «\(partner)» no tiene mensajes sin leer."
    }
    let effectiveLimit = unreadOnly ? min(limit, unreadCount) : limit

    var sql = """
    SELECT m.ZMESSAGEDATE, m.ZISFROMME, p.ZPUSHNAME, m.ZTEXT
    FROM ZWAMESSAGE m
    LEFT JOIN ZWAGROUPMEMBER gm ON m.ZGROUPMEMBER = gm.Z_PK
    LEFT JOIN ZWAPROFILEPUSHNAME p ON p.ZJID = gm.ZMEMBERJID
    WHERE m.ZCHATSESSION = ? AND m.ZTEXT IS NOT NULL
    """
    if unreadOnly { sql += " AND m.ZISFROMME = 0" }
    if !query.isEmpty { sql += " AND m.ZTEXT LIKE ?" }
    if since != nil { sql += " AND m.ZMESSAGEDATE >= ?" }
    if until != nil { sql += " AND m.ZMESSAGEDATE <= ?" }
    sql += " ORDER BY m.ZMESSAGEDATE DESC LIMIT ?;"

    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
        return waError("consulta de mensajes fallida.")
    }
    defer { sqlite3_finalize(stmt) }
    var idx: Int32 = 1
    sqlite3_bind_int64(stmt, idx, chatPK); idx += 1
    if !query.isEmpty { bindText(stmt, idx, "%\(query)%"); idx += 1 }
    if let since { sqlite3_bind_double(stmt, idx, since); idx += 1 }
    if let until { sqlite3_bind_double(stmt, idx, until); idx += 1 }
    sqlite3_bind_int(stmt, idx, Int32(max(1, effectiveLimit)))

    var rows: [String] = []
    while sqlite3_step(stmt) == SQLITE_ROW {
        let date = waDate(sqlite3_column_double(stmt, 0))
        let fromMe = sqlite3_column_int(stmt, 1) == 1
        let sender: String
        if fromMe {
            sender = "Yo"
        } else if isGroup {
            sender = colText(stmt, 2) ?? "Alguien"
        } else {
            sender = partner
        }
        let text = colText(stmt, 3) ?? ""
        rows.append("[\(date)] \(sender): \(text)")
    }
    if rows.isEmpty {
        return query.isEmpty
            ? "No hay mensajes de texto en el chat «\(partner)» con ese criterio."
            : "No se encontraron mensajes con «\(query)» en el chat «\(partner)»."
    }
    // Query returns newest-first; present oldest-first so the thread reads naturally.
    var header = "Mensajes de WhatsApp con «\(partner)»\(isGroup ? " [grupo]" : "")"
    if unreadOnly { header += " (sin leer)" }
    if !query.isEmpty { header += " que contienen «\(query)»" }
    return header + ":\n\n" + rows.reversed().joined(separator: "\n")
}

/// Full-text-ish search of message bodies across every chat (substring match).
private func searchMessages(_ db: OpaquePointer?, query: String, since: Double?,
                            until: Double?, unreadOnly: Bool, limit: Int) -> String {
    var sql = """
    SELECT m.ZMESSAGEDATE, m.ZISFROMME, c.ZPARTNERNAME, c.ZSESSIONTYPE, p.ZPUSHNAME, m.ZTEXT
    FROM ZWAMESSAGE m
    JOIN ZWACHATSESSION c ON m.ZCHATSESSION = c.Z_PK
    LEFT JOIN ZWAGROUPMEMBER gm ON m.ZGROUPMEMBER = gm.Z_PK
    LEFT JOIN ZWAPROFILEPUSHNAME p ON p.ZJID = gm.ZMEMBERJID
    WHERE m.ZTEXT LIKE ?
    """
    // No per-message read flag → approximate unread search to messages in chats
    // that currently have unread messages.
    if unreadOnly { sql += " AND c.ZUNREADCOUNT > 0 AND m.ZISFROMME = 0" }
    if since != nil { sql += " AND m.ZMESSAGEDATE >= ?" }
    if until != nil { sql += " AND m.ZMESSAGEDATE <= ?" }
    sql += " ORDER BY m.ZMESSAGEDATE DESC LIMIT ?;"

    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
        return waError("búsqueda de mensajes fallida.")
    }
    defer { sqlite3_finalize(stmt) }
    var idx: Int32 = 1
    bindText(stmt, idx, "%\(query)%"); idx += 1
    if let since { sqlite3_bind_double(stmt, idx, since); idx += 1 }
    if let until { sqlite3_bind_double(stmt, idx, until); idx += 1 }
    sqlite3_bind_int(stmt, idx, Int32(limit))

    var rows: [String] = []
    while sqlite3_step(stmt) == SQLITE_ROW {
        let date = waDate(sqlite3_column_double(stmt, 0))
        let fromMe = sqlite3_column_int(stmt, 1) == 1
        let chatName = colText(stmt, 2) ?? "(chat)"
        let isGroup = sqlite3_column_int(stmt, 3) == 1
        let sender = fromMe ? "Yo" : (isGroup ? (colText(stmt, 4) ?? "Alguien") : chatName)
        let text = colText(stmt, 5) ?? ""
        rows.append("[\(date)] (\(chatName)) \(sender): \(text)")
    }
    if rows.isEmpty { return "No se encontraron mensajes de WhatsApp con «\(query)»." }
    return "Mensajes de WhatsApp que contienen «\(query)»:\n\n" + rows.joined(separator: "\n")
}

// MARK: - Watchdog support (cheap "anything new?" probes)

/// Newest modification time among ChatStorage.sqlite and its WAL — the
/// watchdog's zero-cost gate to skip the copy + query when nothing changed.
func waStoreNewestMTime() -> Date? {
    let store = whatsAppStorePath()
    let fm = FileManager.default
    var newest: Date? = nil
    for suffix in ["", "-wal"] {
        if let attrs = try? fm.attributesOfItem(atPath: store + suffix),
           let m = attrs[.modificationDate] as? Date {
            if newest == nil || m > newest! { newest = m }
        }
    }
    return newest
}

/// Incoming WhatsApp text messages strictly newer than `epoch` (Unix seconds),
/// newest first. Per-watcher filtering happens in Swift so one store copy
/// serves every WhatsApp watcher in a scan. Returns [] on any failure.
func waMessagesSince(epoch: Double, limit: Int = 50) async -> [WatchHit] {
    let sinceTS = epoch - coreDataEpoch
    return await withCheckedContinuation { (cont: CheckedContinuation<[WatchHit], Never>) in
        DispatchQueue.global(qos: .utility).async {
            let store = whatsAppStorePath()
            guard FileManager.default.fileExists(atPath: store),
                  let work = try? copyStoreToTemp(store) else {
                cont.resume(returning: []); return
            }
            defer { try? FileManager.default.removeItem(at: work.deletingLastPathComponent()) }

            var db: OpaquePointer?
            let uri = "file:\(work.path)?mode=ro"
            guard sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else {
                sqlite3_close(db); cont.resume(returning: []); return
            }
            defer { sqlite3_close(db) }

            let sql = """
            SELECT m.ZMESSAGEDATE, c.ZPARTNERNAME, c.ZSESSIONTYPE, p.ZPUSHNAME, m.ZTEXT
            FROM ZWAMESSAGE m
            JOIN ZWACHATSESSION c ON m.ZCHATSESSION = c.Z_PK
            LEFT JOIN ZWAGROUPMEMBER gm ON m.ZGROUPMEMBER = gm.Z_PK
            LEFT JOIN ZWAPROFILEPUSHNAME p ON p.ZJID = gm.ZMEMBERJID
            WHERE m.ZISFROMME = 0 AND m.ZTEXT IS NOT NULL AND m.ZMESSAGEDATE > ?
            ORDER BY m.ZMESSAGEDATE DESC LIMIT ?;
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                cont.resume(returning: []); return
            }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_double(stmt, 1, sinceTS)
            sqlite3_bind_int(stmt, 2, Int32(max(1, limit)))

            var hits: [WatchHit] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                let chat = colText(stmt, 1) ?? "(chat)"
                let isGroup = sqlite3_column_int(stmt, 2) == 1
                let sender = colText(stmt, 3)
                let origin = isGroup ? "\(chat) · \(sender ?? "alguien")" : chat
                hits.append(WatchHit(
                    epoch: sqlite3_column_double(stmt, 0) + coreDataEpoch,
                    origin: origin,
                    text: colText(stmt, 4) ?? ""))
            }
            cont.resume(returning: hits)
        }
    }
}

// MARK: - sqlite helpers

/// Reads a text column as a Swift String (nil when the column is NULL).
private func colText(_ stmt: OpaquePointer?, _ col: Int32) -> String? {
    guard let c = sqlite3_column_text(stmt, col) else { return nil }
    return String(cString: c)
}

/// Binds a Swift string to a parameter, copying it (SQLITE_TRANSIENT) so the
/// buffer stays valid for the life of the statement.
private func bindText(_ stmt: OpaquePointer?, _ idx: Int32, _ value: String) {
    let TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    sqlite3_bind_text(stmt, idx, value, -1, TRANSIENT)
}

/// Parses a "YYYY-MM-DD" or "YYYY-MM-DD HH:MM" string into a Core Data
/// timestamp (seconds since 2001-01-01). Returns nil when empty/unparseable.
/// A date-only string with `endOfDay` true resolves to 23:59:59 so an `until`
/// bound includes the whole day.
private func parseWADate(_ s: String, endOfDay: Bool) -> Double? {
    let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    let df = DateFormatter()
    df.locale = Locale(identifier: "en_US_POSIX")
    df.timeZone = TimeZone.current
    // Try full datetime first, then date-only.
    df.dateFormat = "yyyy-MM-dd HH:mm"
    if let d = df.date(from: trimmed) {
        return d.timeIntervalSince1970 - coreDataEpoch
    }
    df.dateFormat = "yyyy-MM-dd"
    if let d = df.date(from: trimmed) {
        let adjusted = endOfDay ? d.addingTimeInterval(86_399) : d
        return adjusted.timeIntervalSince1970 - coreDataEpoch
    }
    return nil
}

/// Formats a Core Data timestamp as a short local "yyyy-MM-dd HH:mm" string.
private func waDate(_ coreDataTime: Double) -> String {
    guard coreDataTime > 0 else { return "—" }
    let date = Date(timeIntervalSince1970: coreDataTime + coreDataEpoch)
    let df = DateFormatter()
    df.locale = Locale(identifier: "es_ES")
    df.dateFormat = "d MMM HH:mm"
    return df.string(from: date)
}
