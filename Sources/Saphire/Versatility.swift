import Foundation
import PDFKit

// MARK: - Document extraction (lightweight RAG)

/// Plain-text and source file extensions read verbatim as document context.
private let textDocumentExtensions: Set<String> = [
    "txt", "md", "markdown", "rtf", "csv", "tsv", "json", "yaml", "yml", "toml",
    "xml", "html", "htm", "log", "tex",
    "swift", "py", "js", "ts", "jsx", "tsx", "java", "kt", "c", "h", "cpp", "hpp",
    "cc", "m", "mm", "go", "rs", "rb", "php", "sh", "zsh", "bash", "sql", "r",
    "cs", "scala", "dart", "lua", "pl", "vue", "css", "scss", "ini", "conf", "env",
]

/// File types the document picker accepts (for the NSOpenPanel filter).
let documentExtensions: [String] = Array(textDocumentExtensions) + ["pdf"]

/// Reads a document from disk and returns its (name, extracted text), or nil if
/// the type is unsupported or extraction fails. PDFs go through PDFKit; text and
/// source files are read as UTF-8. Output is capped so one big file can't blow
/// the model's context window.
func extractDocumentText(at url: URL, maxChars: Int = 20000) -> DocumentRef? {
    let ext = url.pathExtension.lowercased()
    let name = url.lastPathComponent
    var text: String?

    if ext == "pdf" {
        if let doc = PDFDocument(url: url) {
            var acc = ""
            for i in 0..<doc.pageCount {
                if let page = doc.page(at: i), let s = page.string {
                    acc += s + "\n"
                    if acc.count > maxChars { break }
                }
            }
            text = acc
        }
    } else if textDocumentExtensions.contains(ext) {
        text = (try? String(contentsOf: url, encoding: .utf8))
            ?? (try? String(contentsOf: url, encoding: .isoLatin1))
    }

    guard var t = text?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else {
        return nil
    }
    if t.count > maxChars { t = String(t.prefix(maxChars)) + "\n…(documento truncado)" }
    return DocumentRef(name: name, text: t)
}

/// Full document text appended to the message content sent to the model (the
/// RAG context). Built on the fly in `buildHistory` from the message's stored
/// documents, so the transcription never lives in the visible chat content.
func documentContextBlock(_ docs: [DocumentRef]) -> String {
    guard !docs.isEmpty else { return "" }
    var out = ""
    for d in docs {
        out += "\n\n[Documento adjunto: \(d.name)]\n```\n\(d.text)\n```"
    }
    return out
}

/// Short note shown in the chat in place of the full transcription, e.g.
/// "📎 Documento adjunto: informe.pdf". Empty when there are no documents.
func documentNote(_ docs: [DocumentRef]) -> String {
    guard !docs.isEmpty else { return "" }
    let label = docs.count == 1 ? "Documento adjunto" : "Documentos adjuntos"
    return "📎 _\(label): \(docs.map(\.name).joined(separator: ", "))_"
}

// MARK: - Markdown export

/// Renders a conversation as a portable Markdown transcript (used by the
/// "Exportar a Markdown" action). Includes a small header and each turn labeled
/// by role; terminal/console blocks already in the content are preserved as-is.
func conversationMarkdown(_ c: Conversation) -> String {
    let df = DateFormatter()
    df.locale = Locale(identifier: "es_ES")
    df.dateFormat = "d 'de' MMMM 'de' yyyy, HH:mm"

    var out = "# \(c.title)\n\n"
    out += "- Modelo: `\(c.model)`\n"
    out += "- Fecha: \(df.string(from: c.createdAt))\n\n---\n"

    for m in c.messages {
        switch m.role {
        case .user:      out += "\n## 🧑 Usuario\n\n"
        case .assistant: out += "\n## 🤖 Saphire\n\n"
        case .system:    out += "\n## ⚙️ Sistema\n\n"
        }
        if let thinking = m.thinking, !thinking.isEmpty {
            out += "> _Razonamiento:_ \(thinking.replacingOccurrences(of: "\n", with: "\n> "))\n\n"
        }
        out += m.content.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
        if !m.attachments.isEmpty {
            out += "\n_(\(m.attachments.count) imagen(es) adjunta(s))_\n"
        }
    }
    return out
}
