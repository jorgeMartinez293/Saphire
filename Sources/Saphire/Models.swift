import Foundation

enum Role: String, Codable, Hashable {
    case user, assistant, system
}

/// An image attached to a message. `base64` is raw (no data: prefix),
/// which is exactly what Ollama's /api/chat expects in `images`.
struct Attachment: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var base64: String
    var mime: String

    var dataURL: String { "data:\(mime);base64,\(base64)" }
}

struct ChatMessage: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var role: Role
    var content: String
    var thinking: String? = nil
    var attachments: [Attachment] = []
    /// Extracted text of documents attached to this message. Kept out of
    /// `content` so the full transcription isn't shown in the chat; it is fed to
    /// the model in `buildHistory`. Only `content` carries a short visible note.
    var documents: [DocumentRef] = []
    var createdAt: Date = Date()
}

/// A persistent fact the user wants the model to remember across all
/// sessions. Injected as a system message at the start of every chat.
struct MemoryFact: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var text: String
    var createdAt: Date = Date()
}

/// A recurring instruction Saphire runs on its own at a set local time.
/// Example: "todos los días a las 02:00 revisa mi correo y añade lo urgente a
/// Recordatorios". The prompt is fed to the model headlessly (no UI), tools and
/// all; the result is saved as a conversation and a notification is posted.
struct ScheduledTask: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    /// Short label shown in the list and the resulting conversation title.
    var title: String
    /// The instruction sent to the model when the task fires.
    var prompt: String
    var hour: Int          // 0–23, local time
    var minute: Int        // 0–59
    /// Days it runs, as `Calendar` weekday numbers (1=domingo … 7=sábado).
    /// Empty means every day.
    var weekdays: Set<Int> = []
    var enabled: Bool = true
    var model: String
    /// When the task last fired successfully — used to avoid double-firing and
    /// to catch up after the Mac was asleep at the scheduled time.
    var lastRun: Date? = nil
    var createdAt: Date = Date()

    /// "02:00" — zero-padded local time.
    var timeLabel: String { String(format: "%02d:%02d", hour, minute) }
}

/// A record of one headless scheduled-task execution. Kept apart from chat
/// `Conversation`s so autonomous runs never appear in the conversation sidebar;
/// they live in their own log (Ajustes → Tareas → Historial). Read-only.
struct TaskRun: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    /// The scheduled task this run came from (may no longer exist).
    var taskID: UUID
    /// Task title at run time, for display without a join.
    var title: String
    var model: String
    /// The instruction that was executed.
    var prompt: String
    /// The model's final prose output (already tool-resolved).
    var output: String
    /// False when the run ended in an error.
    var ok: Bool = true
    var startedAt: Date = Date()
}

/// A deterministic action the app can run on its own — no model — when the user
/// picks the option that carries it. This is what lets a queued question be
/// answered while Ollama is unloaded: the model decided the consequences up
/// front (during a scheduled run), so answering is just a local switch.
enum QuestionAction: Codable, Hashable {
    case none                                          // "No" / "Descartar"
    case saveMemory(text: String)                      // -> AppState.addMemory
    case createReminder(title: String, due: String?)   // -> manageReminders create
    case setTaskEnabled(taskID: UUID, enabled: Bool)   // -> setScheduledTaskEnabled
    case deleteScheduledTask(taskID: UUID)             // -> deleteScheduledTask

    /// Short human label for the consequence, shown under the option in the panel.
    var summary: String {
        switch self {
        case .none: return ""
        case .saveMemory(let t): return "Guardará en memoria: «\(t)»"
        case .createReminder(let t, let due):
            return "Creará el recordatorio «\(t)»" + (due.map { " (vence \($0))" } ?? "")
        case .setTaskEnabled(_, let on): return on ? "Activará la tarea" : "Desactivará la tarea"
        case .deleteScheduledTask: return "Borrará la tarea programada"
        }
    }
}

/// One answer the user can pick for an `InboxItem`. Each option carries the
/// deterministic action run when chosen.
struct QuestionOption: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var label: String
    var action: QuestionAction
}

/// What kind of inbox entry this is.
/// - `.question`: needs a decision — `options` are the answers, the UI requires
///   the user to pick one (or dismiss).
/// - `.notice`: information Saphire wants to pass on ("Juan dice que el proyecto
///   está terminado"). No answer required; `options`, if any, are optional
///   one-tap actions (e.g. guardar en memoria) shown alongside an "Vale".
enum InboxKind: String, Codable, Hashable {
    case question
    case notice
}

/// One entry in Saphire's inbox, prepared while the model was loaded (typically
/// during an autonomous scheduled run) so the user can act on it later — from a
/// notification + the overlay inbox — without ever reloading the model. Unifies
/// the old questions and the new informational notices: each option carries the
/// deterministic action it triggers, so resolving never touches the model.
struct InboxItem: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var kind: InboxKind = .question
    /// The question, or the notice's message.
    var title: String
    /// Why it came up (which fact/decision/source), shown as a subtitle.
    var detail: String? = nil
    /// Questions: 2–4 answers. Notices: 0+ optional actions. The UI always adds a
    /// dismiss/acknowledge button.
    var options: [QuestionOption] = []
    /// Title of the scheduled task that produced it, for the UI.
    var sourceTaskTitle: String? = nil
    var createdAt: Date = Date()
    /// When the user paged past / acknowledged / answered it.
    var answeredAt: Date? = nil
    var chosenOptionID: UUID? = nil

    /// Custom decoding so rows written by the previous `PendingQuestion` schema
    /// (keys `question`/`context`, no `kind`) still load: they map to a
    /// `.question` item. New rows use `title`/`detail`/`kind`.
    private enum CodingKeys: String, CodingKey {
        case id, kind, title, detail, options, sourceTaskTitle
        case createdAt, answeredAt, chosenOptionID
        case question, context   // legacy
    }

    init(id: UUID = UUID(), kind: InboxKind = .question, title: String,
         detail: String? = nil, options: [QuestionOption] = [],
         sourceTaskTitle: String? = nil, createdAt: Date = Date(),
         answeredAt: Date? = nil, chosenOptionID: UUID? = nil) {
        self.id = id; self.kind = kind; self.title = title; self.detail = detail
        self.options = options; self.sourceTaskTitle = sourceTaskTitle
        self.createdAt = createdAt; self.answeredAt = answeredAt
        self.chosenOptionID = chosenOptionID
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
        kind = (try? c.decode(InboxKind.self, forKey: .kind)) ?? .question
        title = (try? c.decode(String.self, forKey: .title))
            ?? (try? c.decode(String.self, forKey: .question)) ?? ""
        detail = (try? c.decode(String?.self, forKey: .detail))
            ?? (try? c.decode(String?.self, forKey: .context)) ?? nil
        options = (try? c.decode([QuestionOption].self, forKey: .options)) ?? []
        sourceTaskTitle = (try? c.decode(String?.self, forKey: .sourceTaskTitle)) ?? nil
        createdAt = (try? c.decode(Date.self, forKey: .createdAt)) ?? Date()
        answeredAt = (try? c.decode(Date?.self, forKey: .answeredAt)) ?? nil
        chosenOptionID = (try? c.decode(UUID?.self, forKey: .chosenOptionID)) ?? nil
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(kind, forKey: .kind)
        try c.encode(title, forKey: .title)
        try c.encodeIfPresent(detail, forKey: .detail)
        try c.encode(options, forKey: .options)
        try c.encodeIfPresent(sourceTaskTitle, forKey: .sourceTaskTitle)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encodeIfPresent(answeredAt, forKey: .answeredAt)
        try c.encodeIfPresent(chosenOptionID, forKey: .chosenOptionID)
    }
}

struct Conversation: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var title: String = "New chat"
    var model: String
    var messages: [ChatMessage] = []
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
    /// Pinned conversations sort to the top of the sidebar and are exempt from
    /// the automatic retention purge.
    var pinned: Bool = false
}

/// A text document the user attached to the next message (txt, md, source code,
/// or extracted PDF text). Its text is embedded into the user message as a
/// fenced context block so the model can reference it (lightweight RAG).
struct DocumentRef: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var name: String
    var text: String
}
