import AppKit
import SwiftUI
import UniformTypeIdentifiers
import UserNotifications

/// Modal sheets, routed through AppState so they can be opened from either the
/// main view or the title-bar accessory.
enum AppSheet: String, Identifiable {
    case settings
    var id: String { rawValue }
}

/// A fact the model proposed via `remember_fact`, awaiting the user's yes/no.
/// `resume` hands the decision back to the suspended tool call.
struct PendingMemory: Identifiable {
    let id = UUID()
    let fact: String
    let resume: (Bool) -> Void
}

/// A mutating shell command the model proposed via `run_command`, awaiting the
/// user's approval before it runs. `resume` hands the decision back to the
/// suspended tool call.
struct PendingCommand: Identifiable {
    let id = UUID()
    let command: String
    let reason: String
    let resume: (Bool) -> Void
}

/// Thread-safe accumulator for the assistant text streamed in one agent-loop
/// round. `onToken` fires inside the OllamaClient actor; the value is read back
/// on the main actor once that round's `await` returns, so a lock keeps it
/// data-race free across the boundary.
private final class TokenAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var text = ""
    func append(_ s: String) { lock.lock(); text += s; lock.unlock() }
    /// Returns the accumulated text and resets for the next round.
    func take() -> String {
        lock.lock(); defer { lock.unlock() }
        let v = text; text = ""; return v
    }
}

/// Races `op` against a wall-clock deadline. Returns nil if the deadline fires
/// first. The losing task is abandoned, not killed — a tool blocked in a
/// syscall (e.g. osascript waiting on a TCC prompt that never shows) cannot be
/// cancelled, only orphaned — so the agent loop always gets an answer.
private func raceAgainstTimeout(seconds: Double,
                                _ op: @escaping @Sendable () async -> String) async -> String? {
    final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var fired = false
        func claim() -> Bool {
            lock.lock(); defer { lock.unlock() }
            if fired { return false }
            fired = true; return true
        }
    }
    return await withCheckedContinuation { (cont: CheckedContinuation<String?, Never>) in
        let once = Once()
        Task {
            let r = await op()
            if once.claim() { cont.resume(returning: r) }
        }
        Task {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            if once.claim() { cont.resume(returning: nil) }
        }
    }
}

/// Thread-safe buffer for the content/thinking deltas streamed during one
/// assistant turn. Tokens arrive inside the client actor (off the main actor);
/// instead of hopping to the main actor per token — which mutates the
/// `@Published` conversations array and re-renders the whole transcript on every
/// token — they are accumulated here and drained by a ~25 fps timer on the main
/// actor. Cuts UI invalidations from one-per-token to ~25/sec.
private final class DeltaBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var content = ""
    private var thinking = ""
    func append(_ c: String, _ t: String) {
        lock.lock(); content += c; thinking += t; lock.unlock()
    }
    /// Returns the buffered (content, thinking) and resets. Empty strings mean
    /// nothing new since the last drain.
    func take() -> (content: String, thinking: String) {
        lock.lock(); defer { lock.unlock() }
        let r = (content, thinking); content = ""; thinking = ""; return r
    }
}

@MainActor
final class AppState: ObservableObject {
    @Published var conversations: [Conversation] = []
    @Published var currentID: UUID
    @Published var models: [String] = []
    @Published var selectedModel: String = "gemma4"
    @Published var thinkEnabled: Bool = false
    @Published var isStreaming: Bool = false
    @Published var input: String = ""
    @Published var pendingAttachments: [Attachment] = []
    @Published var errorText: String? = nil
    @Published var memory: [MemoryFact] = []
    @Published var scheduledTasks: [ScheduledTask] = []
    /// Log of headless scheduled-task executions (most-recent first). Kept apart
    /// from `conversations` so autonomous runs never show in the chat sidebar.
    @Published var taskRuns: [TaskRun] = []

    /// Inbox items Saphire queued for the user during autonomous runs: questions
    /// awaiting an answer and informational notices. Shown in the overlay inbox;
    /// resolving one runs a deterministic action with no model. See `InboxItem`.
    @Published var inboxItems: [InboxItem] = []
    /// Index of the item currently shown in the paged inbox.
    @Published var inboxIndex: Int = 0
    /// Drives the overlay's inbox mode (set by `showInbox`).
    @Published var showingInbox: Bool = false

    // MARK: - Voice dictation (push-to-talk via hold ⌥Space)
    /// True while the microphone is live and transcribing into `input`.
    @Published var isListening: Bool = false
    /// 5 normalized bar heights (0…1) for the overlay's voice spectrum.
    @Published var audioLevels: [CGFloat] = Array(repeating: 0, count: 5)
    private let voice = VoiceTranscriber()

    // MARK: - Tools / web search settings (persisted in UserDefaults)
    @Published var webSearchEnabled: Bool = UserDefaults.standard.bool(forKey: "webSearchEnabled") {
        didSet { UserDefaults.standard.set(webSearchEnabled, forKey: "webSearchEnabled") }
    }
    @Published var searchBackendKind: String =
        UserDefaults.standard.string(forKey: "searchBackendKind") ?? SearchBackendKind.tavily.rawValue {
        didSet { UserDefaults.standard.set(searchBackendKind, forKey: "searchBackendKind") }
    }
    @Published var tavilyKey: String = UserDefaults.standard.string(forKey: "tavilyKey") ?? "" {
        didSet { UserDefaults.standard.set(tavilyKey, forKey: "tavilyKey") }
    }
    @Published var searxngURL: String =
        UserDefaults.standard.string(forKey: "searxngURL") ?? "http://localhost:8080" {
        didSet { UserDefaults.standard.set(searxngURL, forKey: "searxngURL") }
    }

    // MARK: - Tool toggles (persisted in UserDefaults; new tools default on)
    /// Master switch: when off, no tools are advertised to the model.
    @Published var toolsEnabled: Bool = AppState.b("toolsEnabled", true) {
        didSet { UserDefaults.standard.set(toolsEnabled, forKey: "toolsEnabled") }
    }
    @Published var fetchUrlEnabled: Bool = AppState.b("fetchUrlEnabled", true) {
        didSet { UserDefaults.standard.set(fetchUrlEnabled, forKey: "fetchUrlEnabled") }
    }
    @Published var deepSearchEnabled: Bool = AppState.b("deepSearchEnabled", true) {
        didSet { UserDefaults.standard.set(deepSearchEnabled, forKey: "deepSearchEnabled") }
    }
    @Published var datetimeEnabled: Bool = AppState.b("datetimeEnabled", true) {
        didSet { UserDefaults.standard.set(datetimeEnabled, forKey: "datetimeEnabled") }
    }
    @Published var calculateEnabled: Bool = AppState.b("calculateEnabled", true) {
        didSet { UserDefaults.standard.set(calculateEnabled, forKey: "calculateEnabled") }
    }
    @Published var rememberFactEnabled: Bool = AppState.b("rememberFactEnabled", true) {
        didSet { UserDefaults.standard.set(rememberFactEnabled, forKey: "rememberFactEnabled") }
    }
    @Published var readEmailEnabled: Bool = AppState.b("readEmailEnabled", true) {
        didSet { UserDefaults.standard.set(readEmailEnabled, forKey: "readEmailEnabled") }
    }
    @Published var whatsappEnabled: Bool = AppState.b("whatsappEnabled", true) {
        didSet { UserDefaults.standard.set(whatsappEnabled, forKey: "whatsappEnabled") }
    }
    @Published var runCommandEnabled: Bool = AppState.b("runCommandEnabled", true) {
        didSet { UserDefaults.standard.set(runCommandEnabled, forKey: "runCommandEnabled") }
    }
    @Published var remindersEnabled: Bool = AppState.b("remindersEnabled", true) {
        didSet { UserDefaults.standard.set(remindersEnabled, forKey: "remindersEnabled") }
    }
    @Published var scheduleTaskToolEnabled: Bool = AppState.b("scheduleTaskToolEnabled", true) {
        didSet { UserDefaults.standard.set(scheduleTaskToolEnabled, forKey: "scheduleTaskToolEnabled") }
    }
    @Published var calendarEnabled: Bool = AppState.b("calendarEnabled", true) {
        didSet { UserDefaults.standard.set(calendarEnabled, forKey: "calendarEnabled") }
    }
    @Published var searchFilesEnabled: Bool = AppState.b("searchFilesEnabled", true) {
        didSet { UserDefaults.standard.set(searchFilesEnabled, forKey: "searchFilesEnabled") }
    }

    // MARK: - Watchdog (event watchers; persisted in UserDefaults + DB)
    /// Standing "tell me when X arrives" checks. See Watchdog.swift.
    @Published var watchers: [Watcher] = []
    /// Master switch for the periodic watcher scan (and the manage_watchers tool).
    @Published var watchdogEnabled: Bool = AppState.b("watchdogEnabled", true) {
        didSet { UserDefaults.standard.set(watchdogEnabled, forKey: "watchdogEnabled") }
    }
    /// Minutes between watcher scans. Each scan is a local SQLite read (no
    /// model), and is skipped outright when the source store hasn't changed.
    @Published var watchdogMinutes: Int = AppState.i("watchdogMinutes", 5) {
        didSet { UserDefaults.standard.set(watchdogMinutes, forKey: "watchdogMinutes") }
    }
    /// When the last watcher scan ran (per launch; not persisted).
    private var lastWatchdogScan: Date? = nil
    /// True while a scan is in flight, so a slow disk can't stack scans.
    private var watchdogScanning = false

    /// Documents staged for the next message (extracted text embedded as context).
    @Published var pendingDocuments: [DocumentRef] = []
    /// Sidebar filter text. Empty shows all conversations.
    @Published var searchQuery: String = ""

    // MARK: - Scheduled-task run conditions (persisted in UserDefaults)
    /// When on, a due task waits until the Mac has been idle (no input) for
    /// `taskIdleMinutes` before it runs.
    @Published var taskRequireIdle: Bool = AppState.b("taskRequireIdle", true) {
        didSet { UserDefaults.standard.set(taskRequireIdle, forKey: "taskRequireIdle") }
    }
    @Published var taskIdleMinutes: Int = AppState.i("taskIdleMinutes", 15) {
        didSet { UserDefaults.standard.set(taskIdleMinutes, forKey: "taskIdleMinutes") }
    }
    /// When on, a due task waits while a video/presentation is keeping the
    /// display awake.
    @Published var taskPauseDuringVideo: Bool = AppState.b("taskPauseDuringVideo", true) {
        didSet { UserDefaults.standard.set(taskPauseDuringVideo, forKey: "taskPauseDuringVideo") }
    }

    // MARK: - Generation parameters (persisted; tuned for gemma4 by default)
    @Published var numCtx: Int = AppState.i("numCtx", 16384) {
        didSet { UserDefaults.standard.set(numCtx, forKey: "numCtx") }
    }
    @Published var temperature: Double = AppState.d("temperature", 0.7) {
        didSet { UserDefaults.standard.set(temperature, forKey: "temperature") }
    }
    @Published var topP: Double = AppState.d("topP", 0.95) {
        didSet { UserDefaults.standard.set(topP, forKey: "topP") }
    }
    @Published var topK: Int = AppState.i("topK", 64) {
        didSet { UserDefaults.standard.set(topK, forKey: "topK") }
    }
    /// 0 means "no explicit limit" (the field is omitted from the request).
    @Published var numPredict: Int = AppState.i("numPredict", 0) {
        didSet { UserDefaults.standard.set(numPredict, forKey: "numPredict") }
    }
    @Published var repeatPenalty: Double = AppState.d("repeatPenalty", 1.0) {
        didSet { UserDefaults.standard.set(repeatPenalty, forKey: "repeatPenalty") }
    }
    @Published var keepAlive: String = AppState.s("keepAlive", "30m") {
        didSet { UserDefaults.standard.set(keepAlive, forKey: "keepAlive") }
    }

    // MARK: - OpenRouter (remote API backend, persisted in UserDefaults)
    /// OpenRouter API key. When set together with `openRouterModelsRaw`, the
    /// listed models appear in the picker and route to OpenRouter instead of the
    /// local Ollama server (auto-selected per model — see `isRemote`).
    @Published var openRouterKey: String = AppState.s("openRouterKey", "") {
        didSet { UserDefaults.standard.set(openRouterKey, forKey: "openRouterKey") }
    }
    /// One OpenRouter model id per line (e.g. `anthropic/claude-3.7-sonnet`).
    /// These are merged into `models`; a selected id in this set routes remotely.
    @Published var openRouterModelsRaw: String = AppState.s("openRouterModels", "") {
        didSet {
            UserDefaults.standard.set(openRouterModelsRaw, forKey: "openRouterModels")
            objectWillChange.send()
        }
    }

    /// Parsed, de-duplicated list of configured OpenRouter model ids.
    var remoteModels: [String] {
        var seen = Set<String>()
        return openRouterModelsRaw
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// Whether `model` should be served by OpenRouter rather than local Ollama.
    func isRemote(_ model: String) -> Bool { remoteModels.contains(model) }

    // MARK: - OpenAI-compatible endpoint (LM Studio, OpenAI direct, vLLM…)
    /// Base URL of an OpenAI-compatible server, e.g. `http://localhost:1234/v1`
    /// for LM Studio or `https://api.openai.com/v1`. Empty disables this backend.
    @Published var openAICompatBaseURL: String = AppState.s("openAICompatBaseURL", "") {
        didSet { UserDefaults.standard.set(openAICompatBaseURL, forKey: "openAICompatBaseURL") }
    }
    @Published var openAICompatKey: String = AppState.s("openAICompatKey", "") {
        didSet { UserDefaults.standard.set(openAICompatKey, forKey: "openAICompatKey") }
    }
    /// One model id per line served by the OpenAI-compatible endpoint.
    @Published var openAICompatModelsRaw: String = AppState.s("openAICompatModels", "") {
        didSet {
            UserDefaults.standard.set(openAICompatModelsRaw, forKey: "openAICompatModels")
            objectWillChange.send()
        }
    }

    /// Parsed, de-duplicated list of OpenAI-compatible model ids.
    var compatModels: [String] {
        guard !openAICompatBaseURL.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }
        var seen = Set<String>()
        return openAICompatModelsRaw
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// Whether `model` routes to the OpenAI-compatible endpoint.
    func isCompat(_ model: String) -> Bool { compatModels.contains(model) }

    /// The /chat/completions URL derived from `openAICompatBaseURL` (which may or
    /// may not already include the `/v1` suffix).
    private var compatChatURL: URL? {
        let base = openAICompatBaseURL.trimmingCharacters(in: .whitespaces)
        guard !base.isEmpty else { return nil }
        let trimmed = base.hasSuffix("/") ? String(base.dropLast()) : base
        return URL(string: trimmed + "/chat/completions")
    }

    private var compatModelsURL: URL? {
        let base = openAICompatBaseURL.trimmingCharacters(in: .whitespaces)
        guard !base.isEmpty else { return nil }
        let trimmed = base.hasSuffix("/") ? String(base.dropLast()) : base
        return URL(string: trimmed + "/models")
    }


    /// Pending request from `remember_fact` awaiting the user's confirmation.
    @Published var pendingMemoryConfirmation: PendingMemory? = nil

    /// Pending mutating command from `run_command` awaiting the user's approval.
    @Published var pendingCommandConfirmation: PendingCommand? = nil

    /// The assistant message currently being streamed, so tool execution can
    /// inject visible terminal blocks (command + output) into the live reply.
    private var streamingAssistantID: UUID? = nil

    /// Streamed deltas awaiting the next coalesced flush, and the timer that
    /// drains them into the live message at ~25 fps. See `DeltaBuffer`.
    private var renderBuffer: DeltaBuffer? = nil
    private var renderFlushTimer: Timer? = nil

    /// True while a scheduled task is running headlessly (no UI). Tool
    /// confirmations (run_command on mutating commands, remember_fact) are
    /// auto-denied in this mode since there's no user to prompt.
    private var headlessActive = false

    /// Title of the scheduled task currently running headlessly, stamped onto any
    /// question the model queues via `ask_user` during the run.
    private var headlessTaskTitle: String? = nil

    /// True when `ask_user`/`notify_user` queued an item during an interactive
    /// chat turn. The inbox overlay can't be shown mid-stream (it shares the
    /// overlay panel with the chat), so the reveal is deferred to the end of the
    /// turn — `finishStreaming`/`cancelStreaming` consume the flag and open it.
    private var inboxQueuedDuringTurn = false

    /// Fires every minute to check whether any scheduled task is due.
    private var scheduleTimer: Timer?

    /// Presence tracking for the question-inbox nudge: whether the user was idle
    /// on the previous tick, and when we last notified about pending questions
    /// (throttled so returning to the Mac doesn't spam alerts).
    private var wasIdle = false
    private var lastInboxNotify: Date? = nil

    /// Transient "🔍 buscando…" status shown while a tool runs.
    @Published var toolActivity: String? = nil

    // MARK: - UserDefaults helpers (respect an explicit default when unset)
    private static func b(_ k: String, _ d: Bool) -> Bool {
        UserDefaults.standard.object(forKey: k) as? Bool ?? d
    }
    private static func i(_ k: String, _ d: Int) -> Int {
        UserDefaults.standard.object(forKey: k) as? Int ?? d
    }
    private static func d(_ k: String, _ d: Double) -> Double {
        UserDefaults.standard.object(forKey: k) as? Double ?? d
    }
    private static func s(_ k: String, _ d: String) -> String {
        UserDefaults.standard.string(forKey: k) ?? d
    }

    /// Current generation options assembled from the persisted parameters.
    var genOptions: GenOptions {
        GenOptions(numCtx: numCtx, temperature: temperature, topP: topP, topK: topK,
                   numPredict: numPredict > 0 ? numPredict : nil,
                   repeatPenalty: repeatPenalty, seed: nil,
                   keepAlive: keepAlive.trimmingCharacters(in: .whitespaces))
    }

    /// Resets the generation parameters to the gemma4 defaults.
    func restoreGenerationDefaults() {
        let g = GenOptions.gemma4Default
        numCtx = g.numCtx ?? 16384
        temperature = g.temperature ?? 0.7
        topP = g.topP ?? 0.95
        topK = g.topK ?? 64
        numPredict = 0
        repeatPenalty = g.repeatPenalty ?? 1.0
        keepAlive = g.keepAlive ?? "30m"
    }

    /// Currently presented modal sheet (memory / settings).
    @Published var activeSheet: AppSheet? = nil

    /// Whether web search is usable right now (enabled + backend configured).
    var webSearchReady: Bool { webSearchEnabled && makeSearchBackend() != nil }

    private func makeSearchBackend() -> SearchBackend? {
        switch SearchBackendKind(rawValue: searchBackendKind) {
        case .tavily:
            let k = tavilyKey.trimmingCharacters(in: .whitespacesAndNewlines)
            return k.isEmpty ? nil : TavilyBackend(apiKey: k)
        case .searxng:
            let u = searxngURL.trimmingCharacters(in: .whitespacesAndNewlines)
            return u.isEmpty ? nil : SearXNGBackend(baseURL: u)
        case .none:
            return nil
        }
    }

    private let db = Database()
    private let client = OllamaClient()
    private let openRouter = OpenRouterClient()

    /// Routes a chat turn to the right backend by model: configured OpenRouter
    /// models hit the remote API, everything else the local Ollama server. Same
    /// shape as `OllamaClient.chat` so call sites are backend-agnostic. `think`
    /// is ignored remotely (reasoning models stream thoughts unprompted).
    private func chat(
        model: String,
        messages: [OllamaMessage],
        tools: [ToolSpec]? = nil,
        options: GenOptions = .gemma4Default,
        think: Bool,
        onToken: @escaping @Sendable (String, String) -> Void
    ) async throws -> [ToolCallRequest] {
        if isRemote(model) {
            return try await openRouter.chat(
                apiKey: openRouterKey, model: model, messages: messages,
                tools: tools, options: options, onToken: onToken)
        }
        if isCompat(model), let endpoint = compatChatURL {
            // Reuses the OpenRouter client's OpenAI translation, pointed at the
            // user's own OpenAI-compatible server (LM Studio, OpenAI, vLLM…).
            return try await openRouter.chat(
                apiKey: openAICompatKey, model: model, messages: messages,
                tools: tools, options: options, endpoint: endpoint, onToken: onToken)
        }
        return try await client.chat(
            model: model, messages: messages, tools: tools,
            options: options, think: think, onToken: onToken)
    }
    /// The in-flight streaming task, retained so it can be cancelled (Detener).
    private var currentTask: Task<Void, Never>? = nil
    /// Bumped whenever a stream starts or is cancelled, so a superseded task's
    /// finisher can tell it no longer owns `isStreaming`.
    private var streamToken = 0

    /// Conversations untouched for this many days are deleted automatically so
    /// history doesn't grow without bound.
    private let retentionDays = 7
    /// How long the headless run log is kept before automatic purge.
    private let taskRunRetentionDays = 30
    private var purgeTimer: Timer?

    init() {
        memory = db.loadMemory()
        scheduledTasks = db.loadScheduledTasks()
        watchers = db.loadWatchers()
        inboxItems = db.loadInboxItems()
        db.purgeConversations(olderThan: retentionDays)
        db.purgeTaskRuns(olderThan: taskRunRetentionDays)
        taskRuns = db.loadTaskRuns()
        let loaded = db.loadAll()
        if let first = loaded.first {
            conversations = loaded
            currentID = first.id
            selectedModel = first.model
        } else {
            let c = Conversation(model: "gemma4")
            conversations = [c]
            currentID = c.id
        }
        startPurgeTimer()
        startScheduleTimer()
    }

    /// Re-runs the retention purge once a day for long-running (menu-bar) sessions.
    private func startPurgeTimer() {
        purgeTimer = Timer.scheduledTimer(withTimeInterval: 86_400, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.purgeExpiredConversations() }
        }
        purgeTimer?.tolerance = 3600   // daily housekeeping; let the OS coalesce it
    }

    /// Deletes expired conversations and syncs the in-memory list with the DB.
    private func purgeExpiredConversations() {
        guard db.purgeConversations(olderThan: retentionDays) > 0 else { return }
        let live = Set(db.loadAll().map(\.id))
        conversations.removeAll { !live.contains($0.id) }
        if conversations.isEmpty {
            newConversation()
        } else if !conversations.contains(where: { $0.id == currentID }) {
            currentID = conversations[0].id
        }
    }

    // MARK: - Scheduled tasks (recurring autonomous runs)

    /// Adds a task, persists it, and asks for notification permission the first
    /// time (so the user learns when a task has run).
    func addScheduledTask(title: String, prompt: String, hour: Int, minute: Int,
                          weekdays: Set<Int>, model: String) {
        var t = ScheduledTask(title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                              prompt: prompt.trimmingCharacters(in: .whitespacesAndNewlines),
                              hour: hour, minute: minute, weekdays: weekdays, model: model)
        guard !t.title.isEmpty, !t.prompt.isEmpty else { return }
        // Mark today's slot as already handled so a task created after its time
        // today waits for the next occurrence instead of firing right away.
        t.lastRun = Date()
        scheduledTasks.append(t)
        db.saveScheduledTask(t)
        requestNotificationPermission()
    }

    func updateScheduledTask(_ t: ScheduledTask) {
        guard let i = scheduledTasks.firstIndex(where: { $0.id == t.id }) else { return }
        scheduledTasks[i] = t
        db.saveScheduledTask(t)
    }

    func setScheduledTaskEnabled(_ id: UUID, _ enabled: Bool) {
        guard let i = scheduledTasks.firstIndex(where: { $0.id == id }) else { return }
        scheduledTasks[i].enabled = enabled
        db.saveScheduledTask(scheduledTasks[i])
    }

    func deleteScheduledTask(_ id: UUID) {
        db.deleteScheduledTask(id: id)
        scheduledTasks.removeAll { $0.id == id }
    }

    /// Removes one entry from the headless run log.
    func deleteTaskRun(_ id: UUID) {
        db.deleteTaskRun(id: id)
        taskRuns.removeAll { $0.id == id }
    }

    /// Clears the entire headless run log.
    func clearTaskRuns() {
        for r in taskRuns { db.deleteTaskRun(id: r.id) }
        taskRuns.removeAll()
    }

    /// Backs the `manage_scheduled_tasks` tool: lets the model create/list/delete
    /// its own recurring tasks from the chat. Returns a short model-facing string.
    private func handleScheduledTaskTool(_ call: ToolCallRequest) -> String {
        let action = (argString("action", call) ?? "").trimmingCharacters(in: .whitespaces).lowercased()
        switch action {
        case "list":
            if scheduledTasks.isEmpty { return "No hay tareas programadas." }
            return scheduledTasks.map { t in
                let days = t.weekdays.isEmpty ? "todos los días" : describeWeekdays(t.weekdays)
                let state = t.enabled ? "" : " (desactivada)"
                return "• «\(t.title)» — \(t.timeLabel), \(days)\(state): \(t.prompt)"
            }.joined(separator: "\n")

        case "create":
            let title = (argString("title", call) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let prompt = (argString("instruction", call) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { return "Error: falta 'title' para crear la tarea." }
            guard !prompt.isEmpty else { return "Error: falta 'instruction' para crear la tarea." }
            guard let hm = parseHourMinute(argString("time", call) ?? "") else {
                return "Error: 'time' debe ir en formato 24h «HH:MM», p.ej. «08:00»."
            }
            let weekdays = parseWeekdays(argString("days", call) ?? "")
            addScheduledTask(title: title, prompt: prompt, hour: hm.hour, minute: hm.minute,
                             weekdays: weekdays, model: selectedModel)
            let days = weekdays.isEmpty ? "todos los días" : describeWeekdays(weekdays)
            return "Tarea programada creada: «\(title)» a las "
                + String(format: "%02d:%02d", hm.hour, hm.minute) + ", \(days). "
                + "Se ejecutará cuando el equipo esté inactivo."

        case "delete":
            let title = (argString("title", call) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { return "Error: falta 'title' para borrar la tarea." }
            let matches = scheduledTasks.filter { $0.title.caseInsensitiveCompare(title) == .orderedSame }
            guard !matches.isEmpty else { return "No se encontró ninguna tarea titulada «\(title)»." }
            matches.forEach { deleteScheduledTask($0.id) }
            return matches.count == 1 ? "Tarea borrada: «\(title)»."
                                      : "\(matches.count) tareas «\(title)» borradas."

        default:
            return "Error: acción desconocida «\(action)». Usa create, list o delete."
        }
    }

    /// "L M X" style label for a weekday set (used in tool responses).
    private func describeWeekdays(_ days: Set<Int>) -> String {
        let order: [(String, Int)] = [("L",2),("M",3),("X",4),("J",5),("V",6),("S",7),("D",1)]
        return order.filter { days.contains($0.1) }.map(\.0).joined(separator: " ")
    }

    /// Checks every minute whether any task is due. The check is catch-up
    /// safe: a task whose time already passed today (e.g. the Mac was asleep at
    /// 02:00) still fires on the next tick after wake, as long as it hasn't run
    /// since its scheduled moment today.
    private func startScheduleTimer() {
        scheduleTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkDueTasks() }
        }
        scheduleTimer?.tolerance = 5   // minute granularity; ±5s saves wakeups
        // Catch up immediately at launch (covers a task missed while quit).
        checkDueTasks()
        // Re-check right after the Mac wakes, without waiting for the next tick.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.checkDueTasks() }
        }
    }

    /// Returns the most recent scheduled fire moment for `task` on or before
    /// `now`, or nil if it isn't scheduled to have fired yet today/this week.
    private func dueMoment(for task: ScheduledTask, now: Date) -> Date? {
        let cal = Calendar.current
        guard let todayFire = cal.date(bySettingHour: task.hour, minute: task.minute,
                                       second: 0, of: now), todayFire <= now else { return nil }
        if !task.weekdays.isEmpty {
            let wd = cal.component(.weekday, from: todayFire)
            guard task.weekdays.contains(wd) else { return nil }
        }
        return todayFire
    }

    private func checkDueTasks() {
        // Piggyback on the 60s tick to nudge the user about queued inbox items
        // when they come back to the Mac (cheap; no model involved).
        nudgeInboxIfPresent()
        // …and to run the watchdog scan when its interval has elapsed. The scan
        // itself is deterministic SQLite (no model), so it may run any time.
        checkWatchersIfDue()
        // One scheduled run at a time, and never on top of a live user stream.
        guard !headlessActive, !isStreaming else { return }
        let now = Date()
        for task in scheduledTasks where task.enabled {
            guard let fire = dueMoment(for: task, now: now) else { continue }
            // Already ran for this scheduled moment? Skip.
            if let last = task.lastRun, last >= fire { continue }
            // A task is due. Hold it until the Mac is actually idle / not playing
            // video; the due moment stays valid, so the next tick retries until
            // the conditions are met.
            guard runConditionsMet() else { return }
            Task { await self.runScheduledTask(task) }
            return   // run one; the next tick picks up any others
        }
    }

    /// Whether the system is in a state where a scheduled task may run, per the
    /// user's settings: long-enough idle and no video keeping the display awake.
    private func runConditionsMet() -> Bool {
        if taskRequireIdle && systemIdleSeconds() < Double(taskIdleMinutes) * 60 { return false }
        if taskPauseDuringVideo && displaySleepPrevented() { return false }
        return true
    }

    /// Runs a task's prompt through the full agent loop with no UI. Stamps
    /// `lastRun` up front so a slow run can't be re-triggered by the next
    /// minute's tick.
    private func runScheduledTask(_ task: ScheduledTask) async {
        guard !headlessActive else { return }
        // Stamp lastRun now (persisted) so the 60s timer won't fire it again.
        if let i = scheduledTasks.firstIndex(where: { $0.id == task.id }) {
            scheduledTasks[i].lastRun = Date()
            db.saveScheduledTask(scheduledTasks[i])
        }
        await runHeadlessJob(sourceID: task.id, title: task.title,
                             prompt: task.prompt, model: task.model)
    }

    /// Core headless agent run shared by scheduled tasks and smart watchers:
    /// feeds `prompt` through the full agent loop with no UI, records the run in
    /// the task-run log, and posts a notification with the result.
    private func runHeadlessJob(sourceID: UUID, title: String,
                                prompt: String, model: String) async {
        guard !headlessActive else { return }
        headlessActive = true
        headlessTaskTitle = title
        defer { headlessActive = false; headlessTaskTitle = nil }

        if !isRemote(model) && !isCompat(model) { await client.ensureServerRunning() }

        // Remember how many inbox items were already queued so we can tell whether
        // this run raised new ones and surface them right away (see below).
        let inboxBefore = inboxItems.count

        var history: [OllamaMessage] = [systemMessage()]
        history.append(OllamaMessage(role: "user", content: prompt))
        let tools = buildTools()
        let acc = TokenAccumulator()
        let onToken: @Sendable (String, String) -> Void = { c, _ in
            if !c.isEmpty { acc.append(c) }
        }

        var finalText = ""
        var ok = true
        do {
            var rounds = 0
            var ranTools = false
            // Times we've caught the model stalling with a permission question and
            // pushed it to continue. Capped so a stubborn model can't loop forever.
            var nudges = 0
            let maxNudges = 2
            while true {
                rounds += 1
                let calls = try await chat(
                    model: model, messages: history, tools: tools,
                    options: genOptions, think: false, onToken: onToken)
                let prose = acc.take()
                if calls.isEmpty {
                    // No tool call. Normally the run is done — but a weak local model
                    // sometimes stops mid-task to ask the user something in prose
                    // ("¿procedo?", "¿cuál prefieres?"), which would abort the run
                    // with nothing executed. Catch that and push it forward instead
                    // of saving the question as the result. Genuine final answers
                    // (no question marks) fall through and end the loop.
                    if rounds < 10, nudges < maxNudges,
                       looksLikeStall(prose) {
                        nudges += 1
                        history.append(OllamaMessage(role: "assistant", content: prose))
                        history.append(OllamaMessage(role: "user", content:
                            "Estás en modo autónomo y ahora mismo no hay nadie que pueda "
                            + "responderte, así que NO pares con la pregunta en texto. "
                            + "Tienes dos caminos:\n"
                            + "1) Si es un permiso o confirmación trivial (la tarea ya "
                            + "está aprobada), toma la decisión razonable por defecto y "
                            + "ejecútala YA llamando a las herramientas necesarias.\n"
                            + "2) Si es una duda real que cambia el resultado y que solo "
                            + "el usuario puede decidir, llama a la herramienta `ask_user` "
                            + "para dejarle la pregunta preparada (con 2-4 opciones y la "
                            + "acción de cada una) y CONTINÚA con el resto de la tarea.\n"
                            + "En ningún caso te limites a preguntar en prosa."))
                        continue   // don't count this stall as output
                    }
                    if !prose.isEmpty { finalText += (finalText.isEmpty ? "" : "\n\n") + prose }
                    break
                }
                if !prose.isEmpty { finalText += (finalText.isEmpty ? "" : "\n\n") + prose }
                if rounds >= 10 { break }
                history.append(OllamaMessage(role: "assistant", content: prose, toolCalls: calls))
                for call in calls {
                    ranTools = true
                    let result = await executeTool(call)
                    history.append(OllamaMessage(role: "tool", content: result, toolName: call.name))
                }
            }
            // Same mute-model guard as the chat loop: gemma4 sometimes emits a
            // bare end-of-turn right after a tool result. Tools ran but no text
            // came back → force a tool-free final answer instead of "(sin respuesta)".
            if ranTools && finalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                history.append(OllamaMessage(role: "user", content:
                    "Ya tienes los resultados de las herramientas en los mensajes anteriores. "
                    + "Redacta AHORA el resultado final de la tarea con esa información. "
                    + "No llames a más herramientas."))
                _ = try await chat(model: model, messages: history, tools: nil,
                                   options: genOptions, think: false, onToken: onToken)
                finalText = acc.take()
            }
        } catch {
            ok = false
            finalText += (finalText.isEmpty ? "" : "\n\n") + "[Error: \(error.localizedDescription)]"
        }

        // Record the run in its own log (NOT the chat sidebar) so the user can
        // review what happened without autonomous runs polluting conversations.
        let run = TaskRun(taskID: sourceID, title: title, model: model,
                          prompt: prompt,
                          output: finalText.isEmpty ? "(sin respuesta)" : finalText,
                          ok: ok)
        taskRuns.insert(run, at: 0)
        db.saveTaskRun(run)

        postTaskNotification(title: title, summary: finalText)

        // If the run queued new inbox items, surface them now. The minute-tick
        // nudge only fires on an idle→active edge, so an item raised while the user
        // is already sitting at the Mac would otherwise sit silent in the DB. Open
        // the overlay if they're present; otherwise post a (throttle-bypassing)
        // notification so they're nudged the moment they look.
        if inboxItems.count > inboxBefore {
            if systemIdleSeconds() < 60 {
                showInbox()
            } else {
                lastInboxNotify = nil   // fresh batch: don't let the 2h throttle swallow it
                postInboxNotification(count: inboxItems.count)
            }
        }
    }

    /// Heuristic: does this tool-call-less prose look like the model stalling to
    /// ask the user something (permission OR a genuine doubt) instead of acting?
    /// Used only in headless runs to decide whether to nudge it onward — either to
    /// decide by itself or to queue the question via `ask_user`. Relaxed on purpose:
    /// any question mark plus a hint the text is directed at the user counts, so
    /// real doubts get routed to `ask_user` instead of silently ending the run.
    /// Only a clean, question-free final answer falls through.
    private func looksLikeStall(_ text: String) -> Bool {
        let t = text.lowercased()
        // No question at all → treat as a genuine final answer, let it end.
        guard t.contains("?") || t.contains("¿") else { return false }
        let phrases = [
            // Permission / confirmation seeking
            "te parece", "quieres que", "deseas que", "procedo", "procedemos",
            "continúo", "continuo", "sigo adelante", "puedo proceder",
            "puedo continuar", "confirma", "confírmame", "confirmas",
            "me das el visto", "de acuerdo?", "¿empiezo", "¿lo hago",
            "¿hago", "¿creo", "¿añado", "¿borro", "¿elimino", "¿envío",
            "¿leo", "necesito tu", "esperando tu", "dime si",
            "¿prefieres", "¿quieres", "¿debo", "¿avanzo",
            // Genuine doubts that only the user can settle → route to ask_user
            "¿cuál", "cual prefieres", "¿qué opción", "que opcion",
            "no estoy seguro", "no sé si", "no se si", "podrías indicarme",
            "podrias indicarme", "me indicas", "indícame", "indicame",
            "qué prefieres", "necesito saber", "necesitaría saber",
            "¿cómo quieres", "como quieres", "déjame saber", "dejame saber",
            "avísame", "avisame", "¿te gustaría", "te gustaria",
        ]
        return phrases.contains { t.contains($0) }
    }

    // MARK: - Watchdog (event watchers)

    func addWatcher(_ w: Watcher) {
        watchers.append(w)
        db.saveWatcher(w)
        requestNotificationPermission()
    }

    func setWatcherEnabled(_ id: UUID, _ enabled: Bool) {
        guard let i = watchers.firstIndex(where: { $0.id == id }) else { return }
        watchers[i].enabled = enabled
        // Re-arm from "now" so re-enabling doesn't replay everything that
        // arrived while the watcher was off.
        if enabled { watchers[i].lastSeen = Date().timeIntervalSince1970 }
        db.saveWatcher(watchers[i])
    }

    func deleteWatcher(_ id: UUID) {
        db.deleteWatcher(id: id)
        watchers.removeAll { $0.id == id }
    }

    /// Fires a scan from the minute tick when the interval has elapsed. The
    /// scan never loads the model; it's bounded by a couple of SQLite reads.
    private func checkWatchersIfDue() {
        guard watchdogEnabled, watchers.contains(where: { $0.enabled }),
              !watchdogScanning else { return }
        let interval = Double(max(1, watchdogMinutes)) * 60
        if let last = lastWatchdogScan, Date().timeIntervalSince(last) < interval { return }
        lastWatchdogScan = Date()
        watchdogScanning = true
        Task {
            await self.runWatchdogScan()
            self.watchdogScanning = false
        }
    }

    /// One scan: per source, skip outright if the store file hasn't changed
    /// since the oldest `lastSeen`; otherwise read everything new once and
    /// match it against each watcher in Swift.
    private func runWatchdogScan() async {
        let mailWatchers = watchers.filter { $0.enabled && $0.source == .email }
        if !mailWatchers.isEmpty, let oldest = mailWatchers.map(\.lastSeen).min(),
           let mtime = mailStoreNewestMTime(), mtime.timeIntervalSince1970 > oldest {
            let hits = await mailMessagesSince(epoch: oldest)
            for w in mailWatchers { await handleWatchHits(w, hits) }
        }
        let waWatchers = watchers.filter { $0.enabled && $0.source == .whatsapp }
        if !waWatchers.isEmpty, let oldest = waWatchers.map(\.lastSeen).min(),
           let mtime = waStoreNewestMTime(), mtime.timeIntervalSince1970 > oldest {
            let hits = await waMessagesSince(epoch: oldest)
            for w in waWatchers { await handleWatchHits(w, hits) }
        }
    }

    /// Applies one watcher to the scan's hits. On a match: advances `lastSeen`
    /// (so nothing fires twice), then either runs the watcher's smart
    /// instruction headlessly, or — the deterministic default — posts an
    /// immediate notification and queues an inbox notice. No model is touched
    /// unless the watcher explicitly carries an instruction.
    private func handleWatchHits(_ w: Watcher, _ hits: [WatchHit]) async {
        let mine = hits.filter {
            $0.epoch > w.lastSeen
                && watchContains($0.origin, w.filter)
                && watchContains($0.text, w.contains)
        }
        guard !mine.isEmpty, let newest = mine.map(\.epoch).max() else { return }
        guard let i = watchers.firstIndex(where: { $0.id == w.id }) else { return }
        watchers[i].lastSeen = max(watchers[i].lastSeen, newest)
        db.saveWatcher(watchers[i])

        let lines = mine.prefix(5).map {
            "[\(watchHitDateLabel($0.epoch))] \($0.origin): \(clipWatchText($0.text, 140))"
        }

        // One-shot watcher: it just fired, so remove it before doing the work.
        if w.once { deleteWatcher(w.id) }

        let instruction = w.instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        if !instruction.isEmpty, !headlessActive, !isStreaming {
            // Smart watcher: wake the model once, with the new messages inline.
            let prompt = instruction + "\n\nContexto: el vigilante «\(w.title)» ha "
                + "detectado \(mine.count) novedad(es):\n" + lines.joined(separator: "\n")
            await runHeadlessJob(sourceID: w.id, title: "Vigilante: \(w.title)",
                                 prompt: prompt, model: selectedModel)
            return
        }

        // Deterministic path (also the fallback when the model is busy):
        // notification now + a notice waiting in the inbox. Zero model time.
        let icon = w.source == .email ? "📬" : "💬"
        let first = mine[0]
        let title = mine.count == 1
            ? "\(icon) \(first.origin): \(clipWatchText(first.text, 100))"
            : "\(icon) \(mine.count) novedades de «\(w.title)»"
        let item = InboxItem(kind: .notice, title: title,
                             detail: lines.joined(separator: "\n"),
                             options: [],
                             sourceTaskTitle: "Vigilante: \(w.title)")
        inboxItems.append(item)
        db.saveInboxItem(item)
        postWatcherNotification(w, body: lines.joined(separator: "\n"))
    }

    private func clipWatchText(_ s: String, _ max: Int) -> String {
        let t = s.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return t.count > max ? String(t.prefix(max)) + "…" : t
    }

    /// Immediate alert for a fired watcher; tapping it opens the inbox.
    private func postWatcherNotification(_ w: Watcher, body: String) {
        requestNotificationPermission()
        let center = UNUserNotificationCenter.current()
        center.setNotificationCategories([
            UNNotificationCategory(identifier: AppState.questionCategoryID, actions: [],
                                   intentIdentifiers: [], options: [])
        ])
        let content = UNMutableNotificationContent()
        content.title = "Saphire · \(w.title)"
        content.body = String(body.prefix(240))
        content.sound = .default
        content.categoryIdentifier = AppState.questionCategoryID
        center.add(UNNotificationRequest(identifier: UUID().uuidString,
                                         content: content, trigger: nil))
    }

    /// Backs the `manage_watchers` tool: create/list/delete watchers from chat.
    private func handleWatchersTool(_ call: ToolCallRequest) -> String {
        let raw = (argString("action", call) ?? "")
            .trimmingCharacters(in: .whitespaces).lowercased()
            .folding(options: .diacriticInsensitive, locale: nil)
        // The tool is described in Spanish, so the local model often sends the
        // action/source in Spanish too. Normalize before matching instead of
        // silently failing (which let the model narrate a fake "creado").
        let action: String
        switch raw {
        case "create", "crear", "crea", "add", "nuevo", "añadir", "anadir": action = "create"
        case "list", "listar", "lista", "ver", "mostrar": action = "list"
        case "delete", "borrar", "borra", "eliminar", "elimina", "quitar", "remove": action = "delete"
        default: action = raw
        }
        switch action {
        case "list":
            if watchers.isEmpty { return "No hay vigilantes creados." }
            return watchers.map { w in
                var parts: [String] = [w.source == .email ? "correo" : "whatsapp"]
                if !w.filter.isEmpty { parts.append("de «\(w.filter)»") }
                if !w.contains.isEmpty { parts.append("que contenga «\(w.contains)»") }
                if !w.instruction.isEmpty { parts.append("acción: \(w.instruction)") }
                parts.append(w.once ? "aviso único" : "permanente")
                let state = w.enabled ? "" : " (desactivado)"
                return "• «\(w.title)»\(state) — " + parts.joined(separator: ", ")
            }.joined(separator: "\n")

        case "create":
            let title = (argString("title", call) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { return "Error: falta 'title' para crear el vigilante." }
            let srcRaw = (argString("source", call) ?? "")
                .trimmingCharacters(in: .whitespaces).lowercased()
                .folding(options: .diacriticInsensitive, locale: nil)
            let source: WatchSource
            switch srcRaw {
            case "email", "correo", "mail", "e-mail", "gmail": source = .email
            case "whatsapp", "wa", "wasap", "wsp", "mensaje", "mensajes": source = .whatsapp
            default:
                return "Error: 'source' debe ser \"email\" o \"whatsapp\"."
            }
            let filter = (argString("filter", call) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let contains = (argString("contains", call) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !filter.isEmpty || !contains.isEmpty else {
                return "Error: indica al menos 'filter' (remitente o chat) o 'contains' "
                    + "(texto), o el vigilante saltaría con cada mensaje."
            }
            let instruction = (argString("instruction", call) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let once = argBool("once", call, default: false)
            addWatcher(Watcher(title: title, source: source, filter: filter,
                               contains: contains, instruction: instruction, once: once))
            let what = source == .email ? "correo" : "WhatsApp"
            return "Vigilante creado: «\(title)» (\(what)"
                + (filter.isEmpty ? "" : ", de «\(filter)»")
                + (contains.isEmpty ? "" : ", que contenga «\(contains)»")
                + (once ? ", aviso único" : ", permanente") + "). "
                + "Se comprueba cada \(watchdogMinutes) min sin usar el modelo, "
                + "mientras Saphire esté abierta; solo detecta mensajes a partir de ahora."

        case "delete":
            let title = (argString("title", call) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { return "Error: falta 'title' para borrar el vigilante." }
            let matches = watchers.filter { $0.title.caseInsensitiveCompare(title) == .orderedSame }
            guard !matches.isEmpty else { return "No se encontró ningún vigilante titulado «\(title)»." }
            matches.forEach { deleteWatcher($0.id) }
            return matches.count == 1 ? "Vigilante borrado: «\(title)»."
                                      : "\(matches.count) vigilantes «\(title)» borrados."

        default:
            return "Error: acción desconocida «\(action)». Usa create, list o delete."
        }
    }

    // MARK: - Notifications

    private func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// Posts a local notification summarizing a finished headless run.
    private func postTaskNotification(title: String, summary: String) {
        let center = UNUserNotificationCenter.current()
        let content = UNMutableNotificationContent()
        content.title = "Saphire · \(title)"
        let body = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        content.body = body.isEmpty ? "Tarea ejecutada." : String(body.prefix(240))
        content.sound = .default
        center.add(UNNotificationRequest(identifier: UUID().uuidString,
                                         content: content, trigger: nil))
    }

    // MARK: - Inbox (questions + notices queued during autonomous runs)

    /// Identifier of the notification category whose tap opens the inbox.
    nonisolated static let questionCategoryID = "pending_questions"

    /// Parses the `options` arg of `ask_user`/`notify_user` into `QuestionOption`s,
    /// resolving each `action`/`value`/`due` into a deterministic `QuestionAction`.
    /// Invalid or unresolvable options are skipped.
    private func parseInboxOptions(_ call: ToolCallRequest) -> [QuestionOption] {
        var options: [QuestionOption] = []
        for o in argArray("options", call).prefix(4) {
            let label = (o["label"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let type = ((o["action"] as? String) ?? "none").lowercased()
            let value = (o["value"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let due = (o["due"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !label.isEmpty else { continue }
            let action: QuestionAction
            switch type {
            case "save_memory":
                guard !value.isEmpty else { continue }
                action = .saveMemory(text: value)
            case "create_reminder":
                guard !value.isEmpty else { continue }
                // Weak local models often cram the due date into the title value as
                // "Título;due:YYYY-MM-DD HH:MM" instead of using the separate `due`
                // field. Split it back out so the reminder isn't created with a
                // corrupted title and the date is honored.
                var title = value
                var embeddedDue: String? = nil
                if let r = value.range(of: ";due:", options: .caseInsensitive)
                    ?? value.range(of: " due:", options: .caseInsensitive)
                    ?? value.range(of: "due:", options: .caseInsensitive) {
                    title = String(value[..<r.lowerBound])
                        .trimmingCharacters(in: CharacterSet(charactersIn: " ;,"))
                    embeddedDue = String(value[r.upperBound...])
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                }
                guard !title.isEmpty else { continue }
                let finalDue = (due?.isEmpty == false) ? due
                    : (embeddedDue?.isEmpty == false ? embeddedDue : nil)
                action = .createReminder(title: title, due: finalDue)
            case "enable_task", "disable_task", "delete_task":
                guard let t = scheduledTasks.first(where: {
                    $0.title.caseInsensitiveCompare(value) == .orderedSame
                }) else { continue }   // unknown task title → skip this option
                action = type == "delete_task"
                    ? .deleteScheduledTask(taskID: t.id)
                    : .setTaskEnabled(taskID: t.id, enabled: type == "enable_task")
            default:
                action = .none
            }
            options.append(QuestionOption(label: label, action: action))
        }
        return options
    }

    /// Queues an item, persists it, and asks for notification permission. Shared
    /// tail of `ask_user` and `notify_user`.
    private func enqueueInboxItem(_ item: InboxItem) {
        inboxItems.append(item)
        db.saveInboxItem(item)
        requestNotificationPermission()
        // In an interactive chat the user is right there: surface the item as
        // soon as the turn ends instead of leaving it silent in the DB (the
        // idle→active nudge wouldn't fire with the user already at the Mac).
        if !headlessActive { inboxQueuedDuringTurn = true }
    }

    /// Backs the `ask_user` tool. Queues a question (with its options and the action
    /// each triggers) for the user and returns control so the model keeps going.
    /// Works both inside a headless scheduled run and in a normal chat; the queued
    /// item shows up in the team view either way.
    private func handleAskUserTool(_ call: ToolCallRequest) -> String {
        let question = (argString("question", call) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { return "Error: falta 'question'." }
        let options = parseInboxOptions(call)
        guard !options.isEmpty else {
            return "Error: necesito al menos 1 opción válida. 'options' debe ser una lista "
                + "de objetos {\"label\": texto, \"action\": tipo, \"value\": dato}; "
                + "para una opción sin acción usa \"action\": \"none\"."
        }
        enqueueInboxItem(InboxItem(
            kind: .question,
            title: question,
            detail: argString("context", call)?.trimmingCharacters(in: .whitespacesAndNewlines),
            options: options,
            sourceTaskTitle: headlessTaskTitle))
        return headlessActive
            ? "Pregunta encolada para el usuario; la responderá cuando vuelva al equipo. "
                + "Continúa con el resto de la tarea."
            : "Pregunta encolada: se le mostrará al usuario en cuanto termines esta respuesta. "
                + "NO repitas la pregunta en texto; cierra tu respuesta brevemente."
    }

    /// Backs the `notify_user` tool. Queues an informational notice (no answer
    /// required) for the user, with optional one-tap actions. Works both inside a
    /// headless scheduled run and in a normal chat.
    private func handleNotifyUserTool(_ call: ToolCallRequest) -> String {
        let message = (argString("message", call) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { return "Error: falta 'message'." }
        enqueueInboxItem(InboxItem(
            kind: .notice,
            title: message,
            detail: argString("context", call)?.trimmingCharacters(in: .whitespacesAndNewlines),
            options: parseInboxOptions(call),   // optional; notices can have 0
            sourceTaskTitle: headlessTaskTitle))
        return headlessActive
            ? "Aviso encolado para el usuario; lo verá cuando vuelva al equipo. "
                + "Continúa con el resto de la tarea."
            : "Aviso encolado: se le mostrará al usuario en cuanto termines esta respuesta. "
                + "NO repitas el aviso en texto; cierra tu respuesta brevemente."
    }

    /// Executes the deterministic action of the chosen option — or, with
    /// `optionID == nil`, just dismisses/acknowledges — and clears the item.
    /// Crucially this never touches the model: every branch is a local mutation,
    /// so a queued item can be resolved with Ollama unloaded.
    func resolveInboxItem(_ item: InboxItem, choosing optionID: UUID?) {
        if let optionID, let opt = item.options.first(where: { $0.id == optionID }) {
            switch opt.action {
            case .none:
                break
            case .saveMemory(let text):
                addMemory(text)
            case .createReminder(let title, let due):
                Task { _ = try? await manageReminders(action: "create", title: title,
                                                       notes: "", due: due ?? "", listName: "") }
            case .setTaskEnabled(let id, let on):
                setScheduledTaskEnabled(id, on)
            case .deleteScheduledTask(let id):
                deleteScheduledTask(id)
            }
        }
        var resolved = item
        resolved.answeredAt = Date()
        resolved.chosenOptionID = optionID
        db.saveInboxItem(resolved)          // keep the record, marked resolved
        inboxItems.removeAll { $0.id == item.id }
        if inboxIndex >= inboxItems.count { inboxIndex = max(0, inboxItems.count - 1) }
        if inboxItems.isEmpty { showingInbox = false }
    }

    /// Opens the overlay in inbox mode (called from the notification tap).
    func showInbox() {
        inboxIndex = 0
        showingInbox = true
        onShowOverlay?()
    }

    /// Set by AppDelegate so the model layer can ask the UI to surface the overlay.
    var onShowOverlay: (() -> Void)? = nil

    /// On each minute tick, if inbox items are waiting and the user has just come
    /// back to the Mac (idle → active), post one throttled notification inviting
    /// them to look. Tapping it opens the inbox.
    private func nudgeInboxIfPresent() {
        let active = systemIdleSeconds() < 60
        defer { wasIdle = !active }
        guard !inboxItems.isEmpty, active else { return }
        // Only on the idle→active edge (or first tick after launch while present).
        guard wasIdle else { return }
        if let last = lastInboxNotify, Date().timeIntervalSince(last) < 2 * 3600 { return }
        lastInboxNotify = Date()
        postInboxNotification(count: inboxItems.count)
    }

    private func postInboxNotification(count: Int) {
        requestNotificationPermission()
        let center = UNUserNotificationCenter.current()
        center.setNotificationCategories([
            UNNotificationCategory(identifier: AppState.questionCategoryID, actions: [],
                                   intentIdentifiers: [], options: [])
        ])
        // Tailor the copy to whether it's only questions, only notices, or a mix.
        let questions = inboxItems.filter { $0.kind == .question }.count
        let notices = count - questions
        let content = UNMutableNotificationContent()
        if questions > 0 && notices == 0 {
            content.title = "Saphire quiere preguntarte algo"
            content.body = questions == 1
                ? "Tienes 1 pregunta pendiente. Ábrela para responder."
                : "Tienes \(questions) preguntas pendientes. Ábrelas para responder."
        } else if questions == 0 {
            content.title = "Saphire tiene algo que contarte"
            content.body = notices == 1
                ? "Tienes 1 aviso nuevo. Ábrelo para verlo."
                : "Tienes \(notices) avisos nuevos. Ábrelos para verlos."
        } else {
            content.title = "Saphire tiene novedades"
            content.body = "Tienes \(count) cosas pendientes (\(questions) "
                + "pregunta\(questions == 1 ? "" : "s") y \(notices) "
                + "aviso\(notices == 1 ? "" : "s")). Ábrelas para verlas."
        }
        content.sound = .default
        content.categoryIdentifier = AppState.questionCategoryID
        center.add(UNNotificationRequest(identifier: UUID().uuidString,
                                         content: content, trigger: nil))
    }

    var current: Conversation {
        get { conversations.first { $0.id == currentID } ?? conversations[0] }
        set {
            if let i = conversations.firstIndex(where: { $0.id == newValue.id }) {
                conversations[i] = newValue
            }
        }
    }

    // MARK: - Conversation management

    func newConversation() {
        let c = Conversation(model: selectedModel)
        conversations.insert(c, at: 0)
        currentID = c.id
        input = ""
        pendingAttachments = []
    }

    func select(_ id: UUID) {
        currentID = id
        if let m = conversations.first(where: { $0.id == id })?.model { selectedModel = m }
    }

    func deleteConversation(_ id: UUID) {
        db.delete(id: id)
        conversations.removeAll { $0.id == id }
        if conversations.isEmpty { newConversation() }
        else if currentID == id { currentID = conversations[0].id }
    }

    /// Renames a conversation. An empty title falls back to a placeholder so the
    /// sidebar row never goes blank.
    func renameConversation(_ id: UUID, to title: String) {
        guard let i = conversations.firstIndex(where: { $0.id == id }) else { return }
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        conversations[i].title = t.isEmpty ? "Sin título" : t
        db.save(conversations[i])
    }

    /// Pins / unpins a conversation. Pinned chats sort to the top and are exempt
    /// from the automatic retention purge. Re-sorts so the move is immediate.
    func togglePin(_ id: UUID) {
        guard let i = conversations.firstIndex(where: { $0.id == id }) else { return }
        conversations[i].pinned.toggle()
        db.save(conversations[i])
        sortConversations()
    }

    /// Pinned first, then by most-recently-updated — matches the DB load order.
    private func sortConversations() {
        conversations.sort {
            $0.pinned != $1.pinned ? $0.pinned && !$1.pinned : $0.updatedAt > $1.updatedAt
        }
    }

    /// Conversations matching the sidebar search (title or message text). Empty
    /// query returns all. Always sorted pinned-first. Case- and
    /// diacritic-insensitive («cafe» finds «café») without allocating lowercased
    /// copies of every message on each keystroke.
    var filteredConversations: [Conversation] {
        let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return conversations }
        let opts: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        return conversations.filter { c in
            c.title.range(of: q, options: opts) != nil
                || c.messages.contains { $0.content.range(of: q, options: opts) != nil }
        }
    }

    /// Exports a conversation as a Markdown file via a save panel.
    func exportConversationMarkdown(_ id: UUID) {
        guard let c = conversations.first(where: { $0.id == id }) else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        let safeTitle = c.title.replacingOccurrences(of: "/", with: "-")
        panel.nameFieldStringValue = "\(safeTitle).md"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try conversationMarkdown(c).write(to: url, atomically: true, encoding: .utf8)
        } catch {
            errorText = "No se pudo exportar: \(error.localizedDescription)"
        }
    }

    func loadModels() async {
        // Best-effort local list: with only remote (OpenRouter) models configured
        // the Ollama server may be absent, which must not block the picker.
        // Only pay the (up-to-~10s) server bootstrap when a local model is in
        // play; if the user is on a remote model and has remote models set up,
        // skip it and just try a quick local list.
        let usingExternal = (isRemote(selectedModel) && !remoteModels.isEmpty)
            || (isCompat(selectedModel) && !compatModels.isEmpty)
        if !usingExternal {
            await client.ensureServerRunning()
        }
        var local: [String] = []
        do {
            local = try await client.listModels()
        } catch {
            if remoteModels.isEmpty && compatModels.isEmpty { errorText = error.localizedDescription }
        }
        // Local first, then configured remote (OpenRouter) and OpenAI-compatible
        // ids, all de-duplicated.
        var seen = Set(local)
        models = local
            + remoteModels.filter { seen.insert($0).inserted }
            + compatModels.filter { seen.insert($0).inserted }
        if !models.contains(selectedModel), let first = models.first { selectedModel = first }
    }

    // MARK: - Persistent memory

    func addMemory(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        let f = MemoryFact(text: t)
        memory.append(f)
        db.saveMemory(f)
    }

    func updateMemory(_ id: UUID, text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let i = memory.firstIndex(where: { $0.id == id }) else { return }
        if t.isEmpty { deleteMemory(id); return }
        memory[i].text = t
        db.saveMemory(memory[i])
    }

    func deleteMemory(_ id: UUID) {
        db.deleteMemory(id: id)
        memory.removeAll { $0.id == id }
    }

    /// System message prepended to every conversation: identity, the current
    /// date/time (so the model stops guessing "now"), language guidance, a short
    /// tool-usage hint, and any persistent memory facts.
    private func systemMessage() -> OllamaMessage {
        let df = DateFormatter()
        df.locale = Locale(identifier: "es_ES")
        df.dateFormat = "EEEE d 'de' MMMM 'de' yyyy, HH:mm"
        let now = df.string(from: Date())

        var blocks: [String] = [
            "Eres Saphire, un asistente de IA que se ejecuta localmente en el Mac del usuario.",
            "Fecha y hora actuales: \(now).",
            "Responde en el idioma del usuario (por defecto, español), de forma clara y concisa.",
            "ACCIÓN DIRECTA: cuando el usuario pida algo concreto, hazlo de inmediato sin pedir "
            + "confirmación ni aclaración previa. Si el usuario dice «lee mi último correo», "
            + "llama a read_email sin preguntar por remitente, asunto ni formato. Toma "
            + "decisiones razonables por defecto ante detalles no especificados. Solo pregunta "
            + "si la acción es irreversible (borrar, enviar) o si realmente no hay forma de "
            + "inferir el parámetro clave.",
        ]
        if toolsEnabled {
            blocks.append(
                "Dispones de herramientas; úsalas cuando aporten valor: web_search para datos "
                + "recientes o que no conoces; fetch_url para leer una página concreta; "
                + "deep_search para investigar a fondo un tema complejo de forma autónoma "
                + "(varias búsquedas y lecturas cruzadas, devuelve un informe con fuentes; "
                + "úsala para estudios, comparativas a fondo o «dónde está más barato X»); "
                + "get_datetime para la hora exacta; calculate para cualquier cálculo numérico; "
                + "read_email para consultar el correo del usuario en Mail (solo lectura: "
                + "recientes, no leídos o búsqueda por remitente/asunto); "
                + "read_whatsapp para leer los mensajes de WhatsApp del usuario (solo lectura: "
                + "listar chats, leer un chat concreto o buscar texto en los mensajes); "
                + "run_command para ejecutar comandos en la terminal del Mac (ver y modificar "
                + "archivos, inspeccionar el sistema, ejecutar programas) — el comando y su "
                + "salida se muestran siempre en el chat, y cualquier comando que borre, cree, "
                + "instale o sobrescriba algo requiere la aprobación del usuario antes de "
                + "ejecutarse; "
                + "manage_reminders para gestionar los recordatorios del Mac (listar, crear, "
                + "completar y borrar en la app Recordatorios); "
                + "manage_calendar para consultar y crear eventos en el Calendario del Mac; "
                + "manage_scheduled_tasks para crear, listar o borrar tareas recurrentes que la "
                + "propia Saphire ejecutará sola a una hora fija (úsala cuando el usuario pida "
                + "que recuerdes o automatices algo de forma periódica); "
                + "manage_watchers para crear vigilantes: avisos automáticos cuando llegue un "
                + "correo o mensaje de WhatsApp concreto (úsala cuando el usuario pida ser "
                + "avisado al recibir algo, p.ej. «avísame cuando me escriba Juan»; la "
                + "comprobación es ligera y no usa el modelo); "
                + "search_files para localizar archivos en el Mac por nombre o contenido "
                + "(Spotlight, solo lectura); "
                + "remember_fact para proponer guardar un dato estable del usuario (requiere su "
                + "confirmación); "
                + "ask_user para dejar al usuario una pregunta pendiente con 2-4 opciones de "
                + "respuesta en su bandeja (se muestra en el overlay como «Saphire te pregunta» "
                + "al terminar tu respuesta) — úsala cuando el usuario te lo pida o cuando una "
                + "decisión pueda esperar a que él responda; para dudas inmediatas de la "
                + "conversación pregunta directamente en texto; "
                + "notify_user para dejarle un aviso informativo (sin respuesta) en esa misma "
                + "bandeja, p.ej. el resultado de algo que debe ver más tarde. "
                + "Si el usuario te pide EXPLÍCITAMENTE usar ask_user o notify_user, llama a la "
                + "herramienta SIEMPRE; no la sustituyas por una pregunta o aviso en texto.")
            if headlessActive {
                blocks.append(
                    "MODO AUTÓNOMO: estás ejecutando una tarea programada sin el usuario "
                    + "delante. El usuario YA aprobó esta tarea al programarla; tu trabajo es "
                    + "ejecutarla entera, de principio a fin, en este mismo turno.\n"
                    + "PROHIBIDO pedir permiso o confirmación en texto. NUNCA escribas frases "
                    + "como «¿te parece bien si…?», «¿quieres que…?», «¿procedo?», «voy a empezar "
                    + "por…, ¿de acuerdo?». No anuncies un plan ni esperes respuesta: actúa y "
                    + "llama directamente a las herramientas. Si una frase termina en pregunta "
                    + "pidiendo permiso, estás fallando la tarea.\n"
                    + "Toma decisiones razonables por defecto cuando falte un detalle (p.ej. si "
                    + "no se especifica cuántos correos leer, lee los recientes y sigue). No hay "
                    + "nadie para responderte ahora mismo.\n"
                    + "remember_fact y los comandos que requieren permiso se rechazan solos: no "
                    + "los uses para cosas dudosas. Reserva ask_user EXCLUSIVAMENTE para una "
                    + "decisión real con consecuencias que el usuario debe tomar (p.ej. ¿guardar "
                    + "este dato?, ¿cuál de estas opciones?); nunca para pedir permiso de "
                    + "continuar. ask_user deja la pregunta preparada y NO detiene la tarea: "
                    + "encólala y sigue con el resto del trabajo.\n"
                    + "Cuando descubras información que el usuario querría saber pero que NO "
                    + "necesita respuesta (un resumen, una novedad, algo que alguien le ha "
                    + "dicho, un aviso), usa notify_user para dejársela como aviso. Aparecerá "
                    + "en su bandeja junto con las preguntas y el usuario irá pasando por todo. "
                    + "Distingue bien: notify_user para INFORMAR, ask_user solo cuando necesites "
                    + "que DECIDA. notify_user tampoco detiene la tarea: déjalo y continúa.")
            }
        }
        if !memory.isEmpty {
            let facts = memory.map { "- \($0.text)" }.joined(separator: "\n")
            blocks.append(
                "Datos que el usuario quiere que recuerdes de forma permanente entre sesiones; "
                + "tenlos en cuenta cuando sean relevantes:\n\(facts)")
        }
        return OllamaMessage(role: "system", content: blocks.joined(separator: "\n\n"))
    }

    // MARK: - Attachments

    func addAttachment(data: Data, mime: String) {
        let (out, outMime) = downscaleForVision(data, mime: mime)
        pendingAttachments.append(Attachment(base64: out.base64EncodedString(), mime: outMime))
    }

    /// Downscales an oversized image before it is sent to the model. gemma4's
    /// vision encoder tiles around ~896px, so shipping full-resolution photos
    /// only wastes tokens and latency. Returns the original bytes when the image
    /// is already small enough or anything goes wrong.
    private func downscaleForVision(_ data: Data, mime: String,
                                    maxDimension: CGFloat = 1024) -> (Data, String) {
        guard let rep = NSBitmapImageRep(data: data) else { return (data, mime) }
        let w = CGFloat(rep.pixelsWide), h = CGFloat(rep.pixelsHigh)
        let longSide = max(w, h)
        guard longSide > maxDimension else { return (data, mime) }

        let scale = maxDimension / longSide
        let newW = Int((w * scale).rounded()), newH = Int((h * scale).rounded())
        guard newW > 0, newH > 0,
              let resized = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: newW, pixelsHigh: newH,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else {
            return (data, mime)
        }
        resized.size = NSSize(width: newW, height: newH)

        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        guard let ctx = NSGraphicsContext(bitmapImageRep: resized) else { return (data, mime) }
        NSGraphicsContext.current = ctx
        ctx.imageInterpolation = .high
        rep.draw(in: NSRect(x: 0, y: 0, width: newW, height: newH))

        if let jpeg = resized.representation(using: .jpeg,
                                             properties: [.compressionFactor: 0.85]) {
            return (jpeg, "image/jpeg")
        }
        return (data, mime)
    }

    func addImageFromPasteboard() {
        let pb = NSPasteboard.general
        if let imgs = pb.readObjects(forClasses: [NSImage.self]) as? [NSImage],
           let img = imgs.first, let tiff = img.tiffRepresentation,
           let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            addAttachment(data: png, mime: "image/png")
        }
    }

    /// Single attach picker (the paperclip): images go to vision attachments,
    /// everything else (text / source / PDF) has its text extracted and staged
    /// as document context. The model receives whichever fits — image bytes for
    /// pictures, embedded text for documents — with no separate UI.
    func pickFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        let extTypes = documentExtensions.compactMap { UTType(filenameExtension: $0) }
        // Broad base types so files whose extension doesn't map to a concrete
        // UTType (e.g. .env, .conf) are still selectable; routing filters them.
        panel.allowedContentTypes = extTypes + [.image, .plainText, .text, .sourceCode, .pdf]
        guard panel.runModal() == .OK else { return }

        var failed: [String] = []
        for url in panel.urls {
            let type = UTType(filenameExtension: url.pathExtension.lowercased())
            if type?.conforms(to: .image) == true {
                guard let data = try? Data(contentsOf: url) else { failed.append(url.lastPathComponent); continue }
                let mime = url.pathExtension.lowercased() == "png" ? "image/png" : "image/jpeg"
                addAttachment(data: data, mime: mime)
            } else if let doc = extractDocumentText(at: url) {
                pendingDocuments.append(doc)
            } else {
                failed.append(url.lastPathComponent)
            }
        }
        if !failed.isEmpty {
            errorText = "No se pudo leer: \(failed.joined(separator: ", "))."
        }
    }

    func removeDocument(_ id: UUID) {
        pendingDocuments.removeAll { $0.id == id }
    }

    // MARK: - Voice dictation

    /// Starts push-to-talk: requests permission, opens the mic, and streams the
    /// live transcript into `input` while driving the spectrum bars.
    func startVoiceInput() async {
        guard !isListening, !isStreaming else { return }
        guard await VoiceTranscriber.requestPermissions() else {
            errorText = "Permiso de micrófono o reconocimiento de voz denegado."
            return
        }
        voice.onLevels = { [weak self] levels in self?.audioLevels = levels }
        voice.onTranscript = { [weak self] text in self?.input = text }
        do {
            try voice.start()
            errorText = nil
            isListening = true
        } catch {
            errorText = error.localizedDescription
        }
    }

    /// Stops dictation. When `send` is true, submits whatever was transcribed.
    func stopVoiceInput(send shouldSend: Bool) {
        guard isListening else { return }
        voice.stop()
        isListening = false
        audioLevels = Array(repeating: 0, count: 5)
        if shouldSend { send() }
    }

    // MARK: - Sending

    func send() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !pendingAttachments.isEmpty || !pendingDocuments.isEmpty,
              !isStreaming else { return }

        var convo = current
        convo.model = selectedModel
        // Documents are stored on the message (full text fed to the model in
        // buildHistory); the visible content only carries a short note so the
        // whole transcription isn't dumped into the chat.
        let note = documentNote(pendingDocuments)
        let visibleContent = note.isEmpty ? text
            : (text.isEmpty ? note : text + "\n\n" + note)
        let userMsg = ChatMessage(role: .user, content: visibleContent,
                                  attachments: pendingAttachments,
                                  documents: pendingDocuments)
        convo.messages.append(userMsg)
        if convo.title == "New chat" || convo.title.isEmpty {
            let titleSeed = !text.isEmpty ? text
                : (pendingDocuments.first?.name ?? "Imagen")
            convo.title = String(titleSeed.prefix(48)).ifEmpty("Imagen")
        }
        convo.updatedAt = Date()
        current = convo

        input = ""
        pendingAttachments = []
        pendingDocuments = []
        db.save(convo)

        startAssistantResponse()
    }

    /// True once the conversation holds at least one question from the user,
    /// which is what enables the Repetir / Editar actions.
    var hasUserMessage: Bool { current.messages.contains { $0.role == .user } }

    /// Re-asks the model the last question, discarding the previous answer.
    func regenerate() {
        guard !isStreaming else { return }
        var convo = current
        while convo.messages.last?.role == .assistant { convo.messages.removeLast() }
        guard convo.messages.last?.role == .user else { return }
        current = convo
        startAssistantResponse()
    }

    /// Re-asks a specific question (by message id), discarding that question's
    /// answer and everything after it. Drives the per-bubble "Repetir" button.
    func regenerate(messageID id: String) {
        guard !isStreaming, let uuid = UUID(uuidString: id) else { return }
        var convo = current
        guard let idx = convo.messages.firstIndex(where: { $0.id == uuid }),
              convo.messages[idx].role == .user else { return }
        convo.messages = Array(convo.messages.prefix(idx + 1))
        current = convo
        startAssistantResponse()
    }

    /// Pulls a specific question (by message id) back into the input box,
    /// dropping it and everything after so a fresh send replaces them. Drives
    /// the per-bubble "Editar" button.
    func editQuestion(messageID id: String) {
        guard !isStreaming, let uuid = UUID(uuidString: id) else { return }
        var convo = current
        guard let idx = convo.messages.firstIndex(where: { $0.id == uuid }),
              convo.messages[idx].role == .user else { return }
        let q = convo.messages[idx]
        convo.messages = Array(convo.messages.prefix(idx))
        current = convo
        input = q.content
        pendingAttachments = q.attachments
        db.save(convo)
    }

    /// Pulls the last question back into the input box for editing, dropping it
    /// and its answer from the transcript so a fresh send replaces them.
    func editLastQuestion() {
        guard !isStreaming else { return }
        var convo = current
        while convo.messages.last?.role == .assistant { convo.messages.removeLast() }
        guard let last = convo.messages.last, last.role == .user else { return }
        convo.messages.removeLast()
        current = convo
        input = last.content
        pendingAttachments = last.attachments
        db.save(convo)
    }

    /// Cancels the in-flight generation, keeping whatever streamed so far.
    func cancelStreaming() {
        guard isStreaming else { return }
        streamToken += 1            // invalidate the running task's finisher
        currentTask?.cancel()
        currentTask = nil
        stopRenderFlush()
        isStreaming = false
        toolActivity = nil
        streamingAssistantID = nil
        // If a command was waiting on the user, unblock its continuation.
        if pendingCommandConfirmation != nil { resolveCommandConfirmation(false) }
        if let ci = conversations.firstIndex(where: { $0.id == currentID }) {
            db.save(conversations[ci])
        }
        revealInboxIfQueuedThisTurn()
    }

    /// Appends an empty assistant placeholder and streams the model's reply for
    /// the conversation as it currently stands. Shared by send / regenerate.
    private func startAssistantResponse() {
        guard !isStreaming else { return }
        var convo = current
        let assistant = ChatMessage(role: .assistant, content: "")
        convo.messages.append(assistant)
        convo.updatedAt = Date()
        current = convo

        errorText = nil
        isStreaming = true
        streamToken += 1
        let token = streamToken
        let assistantID = assistant.id
        streamingAssistantID = assistantID
        let render = startRenderFlush(for: assistantID)
        var history = buildHistory()
        let model = selectedModel
        let think = thinkEnabled
        let options = genOptions

        currentTask = Task {
            let tools = self.buildTools()
            // Captures the prose the model streams in the current round so it can
            // be preserved in `history`. Without it, the assistant turn that
            // carries a tool call is replayed with empty content, so after a
            // permission prompt the model re-derives its answer from scratch
            // (the "restart / re-read" the user noticed) instead of continuing.
            let roundText = TokenAccumulator()
            // Feed deltas into the shared buffer; the main-actor flush timer
            // installed by `startRenderFlush` drains them at ~25 fps. No
            // per-token main-actor hop, no per-token transcript re-render.
            let onToken: @Sendable (String, String) -> Void = { c, t in
                if !c.isEmpty { roundText.append(c) }
                render.append(c, t)
            }
            do {
                // Agent loop: stream a turn; if the model asked for tools, run
                // them, feed results back, and let it answer. Capped to avoid loops.
                var rounds = 0
                var ranTools = false
                var lastProse = ""
                // Results of the calls already executed this turn, keyed by
                // name+arguments. A model that re-issues an identical call gets
                // the cached result back instead of re-running the tool; left
                // unchecked, that re-issue loop burns every round and the turn
                // ends with no answer.
                var executed: [String: String] = [:]
                var toolResults: [(name: String, result: String)] = []
                while true {
                    rounds += 1
                    let calls = try await self.chat(
                        model: model, messages: history, tools: tools, options: options,
                        think: think, onToken: onToken)
                    lastProse = roundText.take()
                    if calls.isEmpty || rounds >= 5 { break }
                    history.append(OllamaMessage(role: "assistant", content: lastProse, toolCalls: calls))
                    for call in calls {
                        ranTools = true
                        let key = call.name + "|" + call.argumentsJSON
                        let result: String
                        if let cached = executed[key] {
                            result = "(Llamada repetida: ya ejecutaste \(call.name) con estos mismos "
                                + "argumentos y este es el mismo resultado. NO vuelvas a llamarla; "
                                + "responde ya al usuario con esta información.)\n" + cached
                        } else {
                            self.toolActivity = self.toolActivityLabel(call)
                            self.appendToolBadge(call)
                            result = await self.executeTool(call)
                            executed[key] = result
                            toolResults.append((call.name, result))
                        }
                        history.append(OllamaMessage(role: "tool", content: result, toolName: call.name))
                    }
                    self.toolActivity = nil
                }
                // gemma4 sometimes emits end-of-turn right after a tool result:
                // Ollama answers 200 with a single EOS token, so the turn ends at
                // the tool badge with no text (looks like the tool "hung"). Force
                // a tool-free final answer so a turn that ran tools never ends mute.
                if ranTools && lastProse.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    history.append(OllamaMessage(role: "user", content:
                        "Ya tienes los resultados de las herramientas en los mensajes anteriores. "
                        + "Responde AHORA al usuario usando esa información. No llames a más herramientas."))
                    _ = try await self.chat(model: model, messages: history, tools: nil,
                                            options: options, think: think, onToken: onToken)
                    if roundText.take().trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        // Last resort: mute twice in a row — surface the raw tool
                        // results so the user still gets the data.
                        var dump = "El modelo no redactó respuesta; esto devolvieron las herramientas:\n"
                        for (name, result) in toolResults {
                            let r = result.count > 2000 ? String(result.prefix(2000)) + "…" : result
                            dump += "\n**\(name):**\n\(r)\n"
                        }
                        render.append(dump, "")
                    }
                }
            } catch let e as OllamaClient.OllamaError
                        where e.message.localizedCaseInsensitiveContains("does not support tools") {
                // Model can't use tools: answer plainly so the user still gets a reply.
                self.errorText = "El modelo no soporta tools; respondí sin herramientas."
                history = self.buildHistory()
                _ = try? await self.chat(model: model, messages: history, tools: nil,
                                         options: options, think: think, onToken: onToken)
            } catch is CancellationError {
                // User pressed Detener; keep the partial answer as-is.
            } catch let urlError as URLError where urlError.code == .cancelled {
                // URLSession surfaces task cancellation as URLError.cancelled.
            } catch {
                self.errorText = error.localizedDescription
            }
            self.toolActivity = nil
            self.finishStreaming(assistantID: assistantID, token: token)
        }
    }

    // MARK: - Tools

    /// Tools advertised to the model this turn, honoring the per-tool toggles.
    /// Returns nil (no tools) when the master switch is off or none are active.
    private func buildTools() -> [ToolSpec]? {
        guard toolsEnabled else { return nil }
        var t: [ToolSpec] = []
        if webSearchReady { t.append(webSearchTool) }
        // deep_search drives web_search/fetch_url internally, so it needs a
        // configured backend just like web_search does.
        if deepSearchEnabled && webSearchReady { t.append(deepSearchTool) }
        if fetchUrlEnabled { t.append(fetchUrlTool) }
        if datetimeEnabled { t.append(datetimeTool) }
        if calculateEnabled { t.append(calculateTool) }
        if readEmailEnabled { t.append(readEmailTool) }
        if whatsappEnabled { t.append(readWhatsAppTool) }
        if runCommandEnabled { t.append(runCommandTool) }
        if remindersEnabled { t.append(manageRemindersTool) }
        if calendarEnabled { t.append(manageCalendarTool) }
        if scheduleTaskToolEnabled { t.append(manageScheduledTasksTool) }
        if searchFilesEnabled { t.append(searchFilesTool) }
        if watchdogEnabled { t.append(manageWatchersTool) }
        if rememberFactEnabled { t.append(rememberFactTool) }
        // ask_user / notify_user: in an autonomous run they let the model defer a
        // decision or leave a note instead of dropping it. In a chat they queue the
        // same inbox item, so the user can resolve it later from the team view.
        t.append(askUserTool); t.append(notifyUserTool)
        return t.isEmpty ? nil : t
    }

    func executeTool(_ call: ToolCallRequest) async -> String {
        saphireDebug("executeTool ENTER name=\(call.name) args=\(call.argumentsJSON)")
        defer { saphireDebug("executeTool EXIT name=\(call.name)") }
        // Watchdog: ninguna herramienta puede colgar el turno indefinidamente.
        // Si excede su presupuesto, devuelve un error que el modelo puede
        // transmitir en vez de dejar la respuesta muerta en el badge de la tool.
        let limit = Self.toolTimeLimit(call.name)
        if let result = await raceAgainstTimeout(seconds: limit, { @Sendable [weak self] in
            await self?.performTool(call) ?? "Error: la app se está cerrando."
        }) {
            return result
        }
        saphireDebug("executeTool TIMEOUT name=\(call.name) after \(Int(limit))s")
        return "Error: la herramienta \(call.name) no respondió en \(Int(limit)) segundos y fue "
            + "cancelada. Informa al usuario de que la operación tardó demasiado."
    }

    /// Per-tool wall-clock budget for the executeTool watchdog. deep_search runs
    /// its own multi-round model loop and run_command already kills the process
    /// at its own (user-settable) timeout, so both get extra headroom.
    private static func toolTimeLimit(_ name: String) -> Double {
        switch name {
        case "deep_search": return 1200
        case "run_command": return 630
        case "web_search", "fetch_url": return 120
        default: return 60
        }
    }

    private func performTool(_ call: ToolCallRequest) async -> String {
        switch call.name {
        case "web_search":
            guard let backend = makeSearchBackend() else {
                return "Error: la búsqueda web no está configurada."
            }
            guard let q = argString("query", call), !q.isEmpty else {
                return "Error: falta el parámetro 'query'."
            }
            do { return try await backend.search(q) }
            catch { return "Error de búsqueda: \(error.localizedDescription)" }

        case "fetch_url":
            guard let u = argString("url", call), !u.isEmpty else {
                return "Error: falta el parámetro 'url'."
            }
            do { return try await fetchURLText(u) }
            catch { return "Error al leer la URL: \(error.localizedDescription)" }

        case "deep_search":
            guard let goal = argString("goal", call), !goal.isEmpty else {
                return "Error: falta el parámetro 'goal'."
            }
            return await runDeepSearch(goal: goal, maxSteps: argInt("max_steps", call, default: 6))

        case "get_datetime":
            let df = DateFormatter()
            df.locale = Locale(identifier: "es_ES")
            df.dateFormat = "EEEE d 'de' MMMM 'de' yyyy, HH:mm:ss (zzz)"
            return "Fecha y hora local actuales: \(df.string(from: Date()))."

        case "calculate":
            guard let expr = argString("expression", call), !expr.isEmpty else {
                return "Error: falta el parámetro 'expression'."
            }
            return evaluateExpression(expr)

        case "read_email":
            let query = argString("query", call) ?? ""
            let unreadOnly = argBool("unread_only", call, default: false)
            let limit = argInt("limit", call, default: 10)
            let fullBody = argBool("full_body", call, default: false)
            do {
                return try await readEmailViaMail(query: query, unreadOnly: unreadOnly,
                                                  limit: limit, fullBody: fullBody)
            } catch {
                return "Error al leer el correo: \(error.localizedDescription)"
            }

        case "read_whatsapp":
            let chat = argString("chat", call) ?? ""
            let query = argString("query", call) ?? ""
            let since = argString("since", call) ?? ""
            let until = argString("until", call) ?? ""
            let unreadOnly = argBool("unread_only", call, default: false)
            let limit = argInt("limit", call, default: 15)
            return await readWhatsApp(chat: chat, query: query, since: since, until: until,
                                      unreadOnly: unreadOnly, limit: limit)

        case "run_command":
            guard let command = argString("command", call)?
                    .trimmingCharacters(in: .whitespacesAndNewlines), !command.isEmpty else {
                return "Error: falta el parámetro 'command'."
            }
            let reason = argString("reason", call) ?? ""

            // Mutating commands (delete/create/install/overwrite) need approval.
            // In a headless scheduled run there's nobody to ask, so deny.
            if commandNeedsPermission(command) {
                if headlessActive {
                    return "No se ejecutó «\(command)»: requiere aprobación del usuario y "
                        + "esta es una tarea programada sin supervisión."
                }
                let approved = await confirmCommand(command, reason: reason)
                if !approved {
                    appendTerminalBlock(command: command,
                                        output: "(Permiso denegado por el usuario; no se ejecutó.)",
                                        exitCode: nil)
                    return "El usuario rechazó ejecutar el comando «\(command)». No se ejecutó."
                }
            }

            let result = await runShellCommand(command)
            appendTerminalBlock(command: command, output: result.output, exitCode: result.exitCode)
            let header = "Comando ejecutado (código de salida \(result.exitCode)):"
            return "\(header)\n\(result.output.isEmpty ? "(sin salida)" : result.output)"

        case "manage_reminders":
            let action = argString("action", call) ?? ""
            let title = argString("title", call) ?? ""
            let notes = argString("notes", call) ?? ""
            let due = argString("due", call) ?? ""
            let listName = argString("list_name", call) ?? ""
            do {
                return try await manageReminders(action: action, title: title,
                                                 notes: notes, due: due, listName: listName)
            } catch {
                return "Error al gestionar los recordatorios: \(error.localizedDescription)"
            }

        case "manage_calendar":
            let action = argString("action", call) ?? ""
            let title = argString("title", call) ?? ""
            let start = argString("start", call) ?? ""
            let end = argString("end", call) ?? ""
            let notes = argString("notes", call) ?? ""
            let calName = argString("calendar_name", call) ?? ""
            do {
                return try await manageCalendar(action: action, title: title, start: start,
                                                end: end, notes: notes, calendarName: calName)
            } catch {
                return "Error al gestionar el calendario: \(error.localizedDescription)"
            }

        case "manage_scheduled_tasks":
            return handleScheduledTaskTool(call)

        case "manage_watchers":
            return handleWatchersTool(call)

        case "search_files":
            return await searchFiles(query: argString("query", call) ?? "",
                                     mode: argString("mode", call) ?? "name",
                                     folder: argString("folder", call) ?? "",
                                     limit: argInt("limit", call, default: 20))

        case "ask_user":
            return handleAskUserTool(call)

        case "notify_user":
            return handleNotifyUserTool(call)

        case "remember_fact":
            guard let fact = argString("fact", call), !fact.isEmpty else {
                return "Error: falta el parámetro 'fact'."
            }
            if headlessActive {
                return "No se guardó en memoria durante una tarea programada "
                    + "(requiere confirmación del usuario)."
            }
            let approved = await confirmMemory(fact)
            if approved { addMemory(fact); return "Guardado en memoria: «\(fact)»." }
            return "El usuario rechazó guardar ese dato."

        default:
            return "Error: herramienta desconocida «\(call.name)»."
        }
    }

    /// Backs the `deep_search` tool: an autonomous nested agent loop that
    /// researches `goal` over several rounds (issuing web_search / fetch_url
    /// calls, cross-checking sources) and returns a synthesized, sourced report
    /// as the tool result. Runs with its own focused system prompt and only the
    /// two web tools, independent of the main conversation. Capped at `maxSteps`
    /// rounds; if the cap is hit mid-research, one final tool-free call forces
    /// the model to write the report from what it has gathered.
    private func runDeepSearch(goal: String, maxSteps: Int) async -> String {
        guard makeSearchBackend() != nil else {
            return "Error: deep_search necesita la búsqueda web configurada."
        }
        let steps = max(2, min(maxSteps, 12))
        let df = DateFormatter()
        df.locale = Locale(identifier: "es_ES")
        df.dateFormat = "EEEE d 'de' MMMM 'de' yyyy"
        let researchSystem = OllamaMessage(role: "system", content: """
            Eres un agente de investigación autónomo. Fecha actual: \(df.string(from: Date())). \
            Objetivo: investigar a fondo el \
            tema dado y entregar un informe completo, preciso y bien estructurado en \
            español.
            Método: descompón el objetivo en sub-preguntas; usa web_search con consultas \
            variadas y específicas (no repitas una consulta ya hecha: refínala o cambia \
            de ángulo); usa fetch_url para leer en detalle las fuentes más \
            prometedoras (no te quedes solo con los fragmentos). Cruza varias fuentes, \
            compara y verifica los datos concretos (precios, fechas, cifras, \
            disponibilidad), dando prioridad a la información más reciente. Sigue \
            buscando hasta tener información suficiente y actual.
            Cuando ya tengas bastante, responde SIN llamar a más herramientas con un \
            informe que incluya: (1) un resumen ejecutivo, (2) los hallazgos clave con \
            cifras concretas, (3) una comparación (usa una tabla Markdown si procede) y \
            (4) al final, la lista de fuentes (URLs) consultadas. Si el objetivo es \
            comparar precios u opciones, indica con claridad la opción más recomendable \
            y por qué.
            """)
        var history: [OllamaMessage] = [
            researchSystem,
            OllamaMessage(role: "user", content: "Objetivo de investigación: \(goal)")
        ]
        let tools = [webSearchTool, fetchUrlTool]
        let acc = TokenAccumulator()
        let onToken: @Sendable (String, String) -> Void = { c, _ in
            if !c.isEmpty { acc.append(c) }
        }

        // Clips all but the most recent tool results so a long investigation
        // doesn't outgrow num_ctx (which would silently evict the system prompt
        // and the earliest evidence). The model has already read the old pages;
        // keeping a stub preserves which sources were used without the bulk.
        func compactToolHistory(keepFull: Int = 4, clipTo: Int = 700) {
            let toolIdx = history.indices.filter { history[$0].role == "tool" }
            guard toolIdx.count > keepFull else { return }
            for i in toolIdx.dropLast(keepFull) where history[i].content.count > clipTo {
                history[i].content = String(history[i].content.prefix(clipTo))
                    + "\n…(contenido antiguo recortado; ya fue leído)"
            }
        }

        var report = ""
        var finishedNaturally = false
        do {
            var round = 0
            // Identical calls return their cached result instead of re-running:
            // a model stuck re-issuing the same search would otherwise burn
            // every remaining step on duplicates.
            var executed: [String: String] = [:]
            while round < steps {
                round += 1
                compactToolHistory()
                toolActivity = "🔬 Investigando (paso \(round)/\(steps))…"
                let calls = try await chat(
                    model: selectedModel, messages: history, tools: tools,
                    options: genOptions, think: false, onToken: onToken)
                let prose = acc.take()
                if !prose.isEmpty { report = prose }
                if calls.isEmpty { finishedNaturally = true; break }
                history.append(OllamaMessage(role: "assistant", content: prose, toolCalls: calls))
                for call in calls {
                    switch call.name {
                    case "web_search": toolActivity = "🔬 Buscando: \(argString("query", call) ?? "")"
                    case "fetch_url":  toolActivity = "🔬 Leyendo: \(argString("url", call) ?? "")"
                    default:           break
                    }
                    let key = call.name + "|" + call.argumentsJSON
                    let result: String
                    if let cached = executed[key] {
                        result = "(Llamada repetida: ya hiciste exactamente esta llamada y este "
                            + "es el mismo resultado. NO la repitas; usa otra consulta o redacta "
                            + "el informe.)\n" + String(cached.prefix(800))
                    } else {
                        result = await executeTool(call)
                        executed[key] = result
                    }
                    history.append(OllamaMessage(role: "tool", content: result, toolName: call.name))
                }
            }
            // Hit the step cap while still calling tools: force a final report
            // from the evidence gathered so far (no tools this time).
            if !finishedNaturally {
                toolActivity = "🔬 Redactando informe…"
                history.append(OllamaMessage(role: "user",
                    content: "Detente y redacta ya el informe final con lo que tienes, "
                        + "siguiendo el formato indicado. No llames a más herramientas."))
                _ = try await chat(
                    model: selectedModel, messages: history, tools: nil,
                    options: genOptions, think: false, onToken: onToken)
                let final = acc.take()
                if !final.isEmpty { report = final }
            }
        } catch {
            let partial = report.trimmingCharacters(in: .whitespacesAndNewlines)
            let err = "Error durante la investigación profunda: \(error.localizedDescription)"
            return partial.isEmpty ? err : "\(partial)\n\n[\(err)]"
        }

        let trimmed = report.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty
            ? "La investigación no obtuvo información suficiente sobre: \(goal)."
            : trimmed
    }

    /// Memo for the parsed tool-call arguments: one execution pulls several keys
    /// out of the same JSON (executeTool, badge, activity label), so parse it
    /// once per distinct arguments string instead of once per key.
    private var cachedArgsJSON: String? = nil
    private var cachedArgsObj: [String: Any] = [:]
    private func argObject(_ call: ToolCallRequest) -> [String: Any] {
        if cachedArgsJSON == call.argumentsJSON { return cachedArgsObj }
        let obj = ((try? JSONSerialization.jsonObject(with: Data(call.argumentsJSON.utf8)))
            as? [String: Any]) ?? [:]
        cachedArgsJSON = call.argumentsJSON
        cachedArgsObj = obj
        return obj
    }

    /// Pulls a string argument out of a tool call's raw JSON arguments.
    private func argString(_ key: String, _ call: ToolCallRequest) -> String? {
        argObject(call)[key] as? String
    }

    /// Boolean argument, tolerant of models that send `true`, `"true"`, or `1`.
    private func argBool(_ key: String, _ call: ToolCallRequest, default def: Bool) -> Bool {
        guard let v = argObject(call)[key] else { return def }
        if let b = v as? Bool { return b }
        if let n = v as? NSNumber { return n.boolValue }
        if let s = v as? String { return s == "true" || s == "1" }
        return def
    }

    /// Array-of-objects argument (used by `ask_user`'s `options`). Tolerates a
    /// model that sends the array inline or as a JSON string.
    private func argArray(_ key: String, _ call: ToolCallRequest) -> [[String: Any]] {
        guard let v = argObject(call)[key] else { return [] }
        if let arr = v as? [[String: Any]] { return arr }
        if let s = v as? String,
           let arr = try? JSONSerialization.jsonObject(with: Data(s.utf8)) as? [[String: Any]] { return arr }
        return []
    }

    /// Integer argument, tolerant of values sent as a JSON number or a string.
    private func argInt(_ key: String, _ call: ToolCallRequest, default def: Int) -> Int {
        guard let v = argObject(call)[key] else { return def }
        if let n = v as? NSNumber { return n.intValue }
        if let s = v as? String, let i = Int(s) { return i }
        return def
    }

    /// Short status line shown while a tool runs.
    private func toolActivityLabel(_ call: ToolCallRequest) -> String {
        switch call.name {
        case "web_search":   return "Buscando: \(argString("query", call) ?? "")"
        case "fetch_url":    return "Leyendo: \(argString("url", call) ?? "")"
        case "deep_search":  return "🔬 Investigación profunda: \(argString("goal", call) ?? "")"
        case "get_datetime": return "Consultando la hora…"
        case "calculate":    return "Calculando…"
        case "read_email":   return "Leyendo el correo…"
        case "read_whatsapp": return "Leyendo WhatsApp…"
        case "run_command":  return "Terminal: \(argString("command", call) ?? "")"
        case "manage_reminders": return "Recordatorios: \(argString("action", call) ?? "")"
        case "manage_calendar": return "Calendario: \(argString("action", call) ?? "")"
        case "manage_scheduled_tasks": return "Tareas programadas: \(argString("action", call) ?? "")"
        case "manage_watchers": return "Vigilantes: \(argString("action", call) ?? "")"
        case "search_files": return "Buscando archivos: \(argString("query", call) ?? "")"
        case "ask_user": return "Preparando una pregunta…"
        case "notify_user": return "Preparando un aviso…"
        case "remember_fact": return "Memoria…"
        default:             return "Ejecutando \(call.name)…"
        }
    }

    /// Injects a persistent one-line badge into the live assistant message so the
    /// user always sees *which* tool Saphire used (not just a transient status
    /// that vanishes). Mirrors `appendTerminalBlock`'s injection. `run_command`
    /// is skipped: it already shows a full console block, so a badge is redundant.
    private func appendToolBadge(_ call: ToolCallRequest) {
        guard let id = streamingAssistantID, call.name != "run_command" else { return }
        // Flush buffered prose first so the badge lands after the text the model
        // streamed before the call, not before it.
        flushRenderBuffer(to: id)
        appendDelta(to: id, content: "\n\n\(toolBadgeText(call))\n\n", thinking: "")
    }

    /// A minimalist full-width divider with a centered `<slug:detail>` label
    /// (styled by `.tool-mark` in chat.html). Emitted as raw HTML, which marked.js
    /// passes through untouched.
    private func toolBadgeText(_ call: ToolCallRequest) -> String {
        let slug: String, detail: String?
        switch call.name {
        case "web_search":   (slug, detail) = ("web_search", argString("query", call))
        case "fetch_url":    (slug, detail) = ("fetch_url", argString("url", call))
        case "deep_search":  (slug, detail) = ("deep_search", argString("goal", call))
        case "get_datetime": (slug, detail) = ("datetime", nil)
        case "calculate":    (slug, detail) = ("calculator", argString("expression", call))
        case "read_email":   (slug, detail) = ("email", argString("query", call))
        case "read_whatsapp": (slug, detail) = ("whatsapp", argString("chat", call) ?? argString("query", call))
        case "manage_reminders": (slug, detail) = ("reminders", argString("action", call))
        case "manage_calendar":  (slug, detail) = ("calendar", argString("action", call))
        case "manage_scheduled_tasks": (slug, detail) = ("scheduled_tasks", argString("action", call))
        case "manage_watchers": (slug, detail) = ("watchers", argString("action", call))
        case "search_files":  (slug, detail) = ("search_files", argString("query", call))
        case "remember_fact": (slug, detail) = ("memory", argString("fact", call))
        case "ask_user":     (slug, detail) = ("ask_user", nil)
        case "notify_user":  (slug, detail) = ("notify_user", nil)
        default:             (slug, detail) = (call.name, nil)
        }
        var label = slug
        if let d = detail?.trimmingCharacters(in: .whitespacesAndNewlines), !d.isEmpty {
            let clipped = d.count > 60 ? String(d.prefix(60)) + "…" : d
            label += ":\(clipped)"
        }
        return "<div class=\"tool-mark\"><span>\(htmlEscape("<\(label)>"))</span></div>"
    }

    /// Escapes the five HTML-significant characters so a tool's detail (which may
    /// contain `<`, `>`, `&`, quotes) renders as literal text inside the badge.
    private func htmlEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
         .replacingOccurrences(of: "<", with: "&lt;")
         .replacingOccurrences(of: ">", with: "&gt;")
         .replacingOccurrences(of: "\"", with: "&quot;")
         .replacingOccurrences(of: "'", with: "&#39;")
    }

    /// Safely evaluates a basic arithmetic expression (see `ArithmeticParser`).
    private func evaluateExpression(_ raw: String) -> String {
        var parser = ArithmeticParser(raw)
        guard let value = parser.parse(), value.isFinite else {
            return "Error: no se pudo evaluar «\(raw)»."
        }
        if value == value.rounded() && abs(value) < 1e15 {
            return "\(raw) = \(Int(value))"
        }
        return "\(raw) = \(value)"
    }

    // MARK: - remember_fact confirmation

    /// Suspends until the user confirms or rejects saving `fact`.
    private func confirmMemory(_ fact: String) async -> Bool {
        await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            pendingMemoryConfirmation = PendingMemory(fact: fact) { approved in
                cont.resume(returning: approved)
            }
        }
    }

    /// Called from the confirmation UI to resolve a pending `remember_fact`.
    func resolveMemoryConfirmation(_ approved: Bool) {
        let pending = pendingMemoryConfirmation
        pendingMemoryConfirmation = nil
        pending?.resume(approved)
    }

    // MARK: - run_command confirmation & visible output

    /// Suspends until the user approves or rejects running `command`.
    private func confirmCommand(_ command: String, reason: String) async -> Bool {
        await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            pendingCommandConfirmation = PendingCommand(command: command, reason: reason) { approved in
                cont.resume(returning: approved)
            }
        }
    }

    /// Called from the confirmation UI to resolve a pending `run_command`.
    func resolveCommandConfirmation(_ approved: Bool) {
        let pending = pendingCommandConfirmation
        pendingCommandConfirmation = nil
        pending?.resume(approved)
    }

    /// Injects a visible terminal block (the command and its output) into the
    /// live assistant message, so the user always sees exactly what ran. Renders
    /// as Markdown in both the window and the overlay.
    private func appendTerminalBlock(command: String, output: String, exitCode: Int32?) {
        guard let id = streamingAssistantID else { return }
        // Drain any buffered prose first so the terminal block lands after the
        // text the model streamed before the tool call, not before it.
        flushRenderBuffer(to: id)
        var block = "\n\n```console\n$ \(command)\n"
        if !output.isEmpty { block += "\(output)\n" }
        if let exitCode, exitCode != 0 { block += "[código de salida \(exitCode)]\n" }
        block += "```\n\n"
        appendDelta(to: id, content: block, thinking: "")
    }

    /// Most recent conversation turns replayed to the model each request. Older
    /// turns are dropped so a long chat doesn't grow the prompt without bound,
    /// blow past `numCtx`, and slow every turn. The system message (identity,
    /// date, memory) is always kept on top of this.
    private let maxHistoryMessages = 40
    /// Base64 images are only replayed for messages within this many of the tail.
    /// Older images waste tokens and vision-encoder time once they're out of the
    /// immediate context, so their text is kept but the image bytes are dropped.
    private let imageRetentionTail = 6

    private func buildHistory() -> [OllamaMessage] {
        var out: [OllamaMessage] = []
        out.append(systemMessage())

        let all = current.messages
        let kept = all.suffix(maxHistoryMessages)
        // Index (within `kept`) before which images are stripped.
        let imageCutoff = kept.count - imageRetentionTail

        for (i, m) in kept.enumerated() {
            if m.role == .assistant && m.content.isEmpty && m.documents.isEmpty { continue }
            let imgs = (i >= imageCutoff) ? m.attachments.map(\.base64) : []
            // Full document transcription is appended here (not in the visible
            // chat content) so the model can read it.
            let content = m.content + documentContextBlock(m.documents)
            out.append(OllamaMessage(role: m.role.rawValue, content: content,
                                     images: imgs.isEmpty ? nil : imgs))
        }
        return out
    }

    /// Begins coalesced rendering for `id`: installs a fresh buffer and a ~25 fps
    /// timer that drains buffered deltas into the live message. Returns the buffer
    /// so the stream's `onToken` can feed it without per-token main-actor hops.
    private func startRenderFlush(for id: UUID) -> DeltaBuffer {
        let buffer = DeltaBuffer()
        renderBuffer = buffer
        renderFlushTimer?.invalidate()
        renderFlushTimer = Timer.scheduledTimer(withTimeInterval: 0.04, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.flushRenderBuffer(to: id) }
        }
        return buffer
    }

    /// Drains whatever has accumulated in the render buffer into message `id`.
    /// Safe to call when nothing is buffered (no-op) or after the stream ends.
    private func flushRenderBuffer(to id: UUID) {
        guard let (content, thinking) = renderBuffer?.take(),
              !content.isEmpty || !thinking.isEmpty else { return }
        appendDelta(to: id, content: content, thinking: thinking)
    }

    /// Stops coalesced rendering and applies any final buffered delta so the last
    /// tokens aren't lost between the final drain and teardown.
    private func stopRenderFlush() {
        renderFlushTimer?.invalidate()
        renderFlushTimer = nil
        if let id = streamingAssistantID { flushRenderBuffer(to: id) }
        renderBuffer = nil
    }

    private func appendDelta(to id: UUID, content: String, thinking: String) {
        guard let ci = conversations.firstIndex(where: { $0.id == currentID }),
              let mi = conversations[ci].messages.firstIndex(where: { $0.id == id }) else { return }
        conversations[ci].messages[mi].content += content
        if !thinking.isEmpty {
            conversations[ci].messages[mi].thinking =
                (conversations[ci].messages[mi].thinking ?? "") + thinking
        }
    }

    private func finishStreaming(assistantID: UUID, token: Int) {
        guard token == streamToken else { return }  // a newer stream superseded us
        stopRenderFlush()
        isStreaming = false
        currentTask = nil
        streamingAssistantID = nil
        if let ci = conversations.firstIndex(where: { $0.id == currentID }) {
            conversations[ci].updatedAt = Date()
            db.save(conversations[ci])
        }
        revealInboxIfQueuedThisTurn()
    }

    /// If `ask_user`/`notify_user` ran during the turn that just ended, flip the
    /// overlay into inbox mode now so the question/notice actually appears
    /// (opening it mid-stream would hide the reply being written, since the
    /// overlay panel hosts either the chat or the inbox, never both).
    private func revealInboxIfQueuedThisTurn() {
        guard inboxQueuedDuringTurn else { return }
        inboxQueuedDuringTurn = false
        if !inboxItems.isEmpty { showInbox() }
    }
}

private extension String {
    func ifEmpty(_ fallback: String) -> String { isEmpty ? fallback : self }
}
