import Foundation

// MARK: - Watchdog (event watchers)
//
// A Watcher is a cheap, deterministic check — "did a new email/WhatsApp message
// matching X arrive?" — that Saphire runs every few minutes WITHOUT the model.
// The check is a direct read of Mail's Envelope Index / WhatsApp's ChatStorage
// (the same stores read_email / read_whatsapp already use), so it costs a few
// milliseconds of SQLite, not a model load. Only when a watcher fires does
// anything else happen: by default a notification + inbox notice (still no
// model); optionally, a watcher carries an `instruction` and then — and only
// then — the model is woken headlessly to act on the new messages.

/// Where a watcher looks.
enum WatchSource: String, Codable, Hashable, Sendable {
    case email, whatsapp
}

/// One standing watch: "tell me when something matching this arrives".
struct Watcher: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    /// Short label, also the delete key for the manage_watchers tool.
    var title: String
    var source: WatchSource
    /// Substring matched against the sender (email: name or address) or the
    /// chat/contact name (whatsapp). Empty = any sender/chat.
    var filter: String = ""
    /// Substring matched against the subject (email) or message text
    /// (whatsapp). Empty = any content.
    var contains: String = ""
    /// When non-empty, the model is woken headlessly with this instruction
    /// (plus the matched messages) each time the watcher fires. Empty keeps the
    /// watcher fully deterministic: notification + inbox notice only.
    var instruction: String = ""
    /// One-shot watcher: deletes itself the first time it fires. `false` (the
    /// default) is a permanent watch that keeps firing on every new match.
    var once: Bool = false
    var enabled: Bool = true
    /// Unix epoch of the newest item already seen. Only strictly newer items
    /// fire, so creating a watcher never replays the existing inbox.
    var lastSeen: Double = Date().timeIntervalSince1970
    var createdAt: Date = Date()
}

/// One new item a watcher matched. `epoch` is Unix seconds for both sources
/// (WhatsApp's Core Data timestamps are converted before they get here).
struct WatchHit: Sendable {
    let epoch: Double
    /// Sender ("Juan <j@x.com>") or chat origin ("Familia · Juan").
    let origin: String
    /// Subject (email) or message text (whatsapp).
    let text: String
}

/// Case- and diacritic-insensitive substring test shared by the watch matchers
/// («maria» matches «María García»).
func watchContains(_ haystack: String, _ needle: String) -> Bool {
    guard !needle.isEmpty else { return true }
    return haystack.range(of: needle,
                          options: [.caseInsensitive, .diacriticInsensitive]) != nil
}

/// Short "d MMM HH:mm" label for a hit's timestamp.
func watchHitDateLabel(_ epoch: Double) -> String {
    let df = DateFormatter()
    df.locale = Locale(identifier: "es_ES")
    df.dateFormat = "d MMM HH:mm"
    return df.string(from: Date(timeIntervalSince1970: epoch))
}

/// Lets the model create, list, and delete watchers from the chat — this is
/// what turns "avísame cuando me escriba Juan" into a standing watch.
let manageWatchersTool = ToolSpec.function(
    name: "manage_watchers",
    description: "Gestiona los vigilantes (modo watchdog) de Saphire: comprobaciones "
        + "automáticas y MUY ligeras (sin usar el modelo) que revisan cada pocos "
        + "minutos el correo o WhatsApp y avisan al usuario en cuanto llega algo "
        + "que coincida. Úsala cuando el usuario pida ser avisado al recibir algo, "
        + "p.ej. «avísame cuando reciba un correo de Juan» o «cuando me escriban "
        + "por WhatsApp del trabajo». Acciones: 'create' para crear un vigilante, "
        + "'list' para verlos, 'delete' para borrar uno por su título. Para "
        + "'create' indica 'source' y al menos 'filter' (remitente o chat) o "
        + "'contains' (texto). Deja 'instruction' vacía si el usuario solo quiere "
        + "el aviso; rellénala solo si además quiere que Saphire haga algo con el "
        + "mensaje al llegar (resumirlo, crear un recordatorio…).",
    properties: [
        "action": .init(type: "string", description: "Acción a realizar.",
                        enumValues: ["create", "list", "delete"]),
        "title": .init(type: "string",
                       description: "Título corto del vigilante, p.ej. «Correo de Juan». "
                           + "Obligatorio para create y delete."),
        "source": .init(type: "string",
                        description: "Qué vigilar (solo create).",
                        enumValues: ["email", "whatsapp"]),
        "filter": .init(type: "string",
                        description: "Remitente a vigilar (correo: nombre o dirección) o "
                            + "nombre del chat/contacto (whatsapp). Subcadena, sin "
                            + "distinguir mayúsculas ni acentos. Vacío = cualquiera."),
        "contains": .init(type: "string",
                          description: "Texto que debe contener el asunto (correo) o el "
                              + "mensaje (whatsapp). Vacío = cualquier contenido."),
        "instruction": .init(type: "string",
                             description: "Opcional: orden que Saphire ejecutará (con el "
                                 + "modelo, en segundo plano) cada vez que el vigilante "
                                 + "salte, p.ej. «Resume el correo y crea un recordatorio "
                                 + "si pide algo». Déjala vacía para un simple aviso."),
        "once": .init(type: "boolean",
                      description: "Si es true, el vigilante se BORRA solo en cuanto salte "
                          + "la primera vez (aviso único). Si es false (por defecto) es "
                          + "permanente y avisa cada vez que llegue algo que coincida. Si "
                          + "el usuario no deja claro si quiere un aviso único o permanente, "
                          + "NO lo adivines: pregúntale antes de crear el vigilante.")
    ],
    required: ["action"]
)
