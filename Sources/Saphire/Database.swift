import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Tiny libsqlite3 wrapper. Stores whole conversations as JSON blobs in a
/// `messages` column — simple, durable, and fast enough for a personal chat.
final class Database {
    private var db: OpaquePointer?
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init() {
        let dir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Saphire", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("saphire.sqlite").path

        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601

        if sqlite3_open(path, &db) != SQLITE_OK {
            NSLog("Saphire: failed to open DB at \(path)")
        }
        // WAL keeps writes from blocking reads and makes the frequent
        // whole-conversation saves (every turn end, on the main actor) much
        // cheaper than the default rollback journal; NORMAL syncing is durable
        // enough under WAL. busy_timeout retries briefly instead of silently
        // failing a statement if another process happens to hold the lock.
        exec("PRAGMA journal_mode=WAL;")
        exec("PRAGMA synchronous=NORMAL;")
        exec("PRAGMA busy_timeout=3000;")
        exec("""
        CREATE TABLE IF NOT EXISTS conversations(
            id TEXT PRIMARY KEY,
            title TEXT NOT NULL,
            model TEXT NOT NULL,
            messages TEXT NOT NULL,
            created_at REAL NOT NULL,
            updated_at REAL NOT NULL
        );
        """)
        // Columns added after the initial schema. ALTER fails harmlessly (and is
        // ignored) when the column already exists, so this is a safe migration.
        exec("ALTER TABLE conversations ADD COLUMN pinned INTEGER NOT NULL DEFAULT 0;")
        exec("""
        CREATE TABLE IF NOT EXISTS memory(
            id TEXT PRIMARY KEY,
            text TEXT NOT NULL,
            created_at REAL NOT NULL
        );
        """)
        exec("""
        CREATE TABLE IF NOT EXISTS scheduled_tasks(
            id TEXT PRIMARY KEY,
            title TEXT NOT NULL,
            prompt TEXT NOT NULL,
            hour INTEGER NOT NULL,
            minute INTEGER NOT NULL,
            weekdays TEXT NOT NULL,
            enabled INTEGER NOT NULL,
            model TEXT NOT NULL,
            last_run REAL,
            created_at REAL NOT NULL
        );
        """)
        // Questions Saphire queued for the user during autonomous runs. The whole
        // PendingQuestion (with its options + actions) is stored as a JSON blob,
        // same approach as conversations.messages.
        exec("""
        CREATE TABLE IF NOT EXISTS pending_questions(
            id TEXT PRIMARY KEY,
            payload TEXT NOT NULL,
            answered INTEGER NOT NULL DEFAULT 0,
            created_at REAL NOT NULL
        );
        """)
        // Log of headless scheduled-task executions. Kept out of `conversations`
        // so autonomous runs never appear in the chat sidebar.
        exec("""
        CREATE TABLE IF NOT EXISTS task_runs(
            id TEXT PRIMARY KEY,
            task_id TEXT NOT NULL,
            title TEXT NOT NULL,
            model TEXT NOT NULL,
            prompt TEXT NOT NULL,
            output TEXT NOT NULL,
            ok INTEGER NOT NULL DEFAULT 1,
            started_at REAL NOT NULL
        );
        """)
    }

    private func exec(_ sql: String) {
        sqlite3_exec(db, sql, nil, nil, nil)
    }

    func save(_ c: Conversation) {
        guard let data = try? encoder.encode(c.messages),
              let json = String(data: data, encoding: .utf8) else { return }
        let sql = """
        INSERT INTO conversations(id,title,model,messages,created_at,updated_at,pinned)
        VALUES(?,?,?,?,?,?,?)
        ON CONFLICT(id) DO UPDATE SET
            title=excluded.title, model=excluded.model,
            messages=excluded.messages, updated_at=excluded.updated_at,
            pinned=excluded.pinned;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, c.id.uuidString, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, c.title, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 3, c.model, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 4, json, -1, SQLITE_TRANSIENT)
        sqlite3_bind_double(stmt, 5, c.createdAt.timeIntervalSince1970)
        sqlite3_bind_double(stmt, 6, c.updatedAt.timeIntervalSince1970)
        sqlite3_bind_int(stmt, 7, c.pinned ? 1 : 0)
        sqlite3_step(stmt)
    }

    func delete(id: UUID) {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "DELETE FROM conversations WHERE id=?;", -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, id.uuidString, -1, SQLITE_TRANSIENT)
        sqlite3_step(stmt)
    }

    /// Removes conversations with no activity in the last `days` days
    /// (measured by `updated_at`). Returns how many were deleted.
    @discardableResult
    func purgeConversations(olderThan days: Int) -> Int {
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400).timeIntervalSince1970
        var stmt: OpaquePointer?
        // Pinned conversations are kept indefinitely.
        guard sqlite3_prepare_v2(db, "DELETE FROM conversations WHERE updated_at < ? AND pinned = 0;", -1, &stmt, nil) == SQLITE_OK
        else { return 0 }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_double(stmt, 1, cutoff)
        sqlite3_step(stmt)
        return Int(sqlite3_changes(db))
    }

    func loadAll() -> [Conversation] {
        let sql = "SELECT id,title,model,messages,created_at,updated_at,pinned FROM conversations ORDER BY pinned DESC, updated_at DESC;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        var out: [Conversation] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let idC = sqlite3_column_text(stmt, 0),
                  let id = UUID(uuidString: String(cString: idC)),
                  let titleC = sqlite3_column_text(stmt, 1),
                  let modelC = sqlite3_column_text(stmt, 2),
                  let msgC = sqlite3_column_text(stmt, 3) else { continue }
            let messages = (try? decoder.decode([ChatMessage].self,
                from: Data(String(cString: msgC).utf8))) ?? []
            out.append(Conversation(
                id: id,
                title: String(cString: titleC),
                model: String(cString: modelC),
                messages: messages,
                createdAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 4)),
                updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 5)),
                pinned: sqlite3_column_int(stmt, 6) != 0
            ))
        }
        return out
    }

    // MARK: - Memory facts

    func saveMemory(_ f: MemoryFact) {
        let sql = """
        INSERT INTO memory(id,text,created_at) VALUES(?,?,?)
        ON CONFLICT(id) DO UPDATE SET text=excluded.text;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, f.id.uuidString, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, f.text, -1, SQLITE_TRANSIENT)
        sqlite3_bind_double(stmt, 3, f.createdAt.timeIntervalSince1970)
        sqlite3_step(stmt)
    }

    func deleteMemory(id: UUID) {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "DELETE FROM memory WHERE id=?;", -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, id.uuidString, -1, SQLITE_TRANSIENT)
        sqlite3_step(stmt)
    }

    func loadMemory() -> [MemoryFact] {
        let sql = "SELECT id,text,created_at FROM memory ORDER BY created_at ASC;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        var out: [MemoryFact] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let idC = sqlite3_column_text(stmt, 0),
                  let id = UUID(uuidString: String(cString: idC)),
                  let textC = sqlite3_column_text(stmt, 1) else { continue }
            out.append(MemoryFact(
                id: id,
                text: String(cString: textC),
                createdAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 2))
            ))
        }
        return out
    }

    // MARK: - Scheduled tasks

    func saveScheduledTask(_ t: ScheduledTask) {
        let sql = """
        INSERT INTO scheduled_tasks(id,title,prompt,hour,minute,weekdays,enabled,model,last_run,created_at)
        VALUES(?,?,?,?,?,?,?,?,?,?)
        ON CONFLICT(id) DO UPDATE SET
            title=excluded.title, prompt=excluded.prompt, hour=excluded.hour,
            minute=excluded.minute, weekdays=excluded.weekdays, enabled=excluded.enabled,
            model=excluded.model, last_run=excluded.last_run;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        let weekdays = t.weekdays.sorted().map(String.init).joined(separator: ",")
        sqlite3_bind_text(stmt, 1, t.id.uuidString, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, t.title, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 3, t.prompt, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int(stmt, 4, Int32(t.hour))
        sqlite3_bind_int(stmt, 5, Int32(t.minute))
        sqlite3_bind_text(stmt, 6, weekdays, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int(stmt, 7, t.enabled ? 1 : 0)
        sqlite3_bind_text(stmt, 8, t.model, -1, SQLITE_TRANSIENT)
        if let last = t.lastRun { sqlite3_bind_double(stmt, 9, last.timeIntervalSince1970) }
        else { sqlite3_bind_null(stmt, 9) }
        sqlite3_bind_double(stmt, 10, t.createdAt.timeIntervalSince1970)
        sqlite3_step(stmt)
    }

    func deleteScheduledTask(id: UUID) {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "DELETE FROM scheduled_tasks WHERE id=?;", -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, id.uuidString, -1, SQLITE_TRANSIENT)
        sqlite3_step(stmt)
    }

    func loadScheduledTasks() -> [ScheduledTask] {
        let sql = """
        SELECT id,title,prompt,hour,minute,weekdays,enabled,model,last_run,created_at
        FROM scheduled_tasks ORDER BY created_at ASC;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        var out: [ScheduledTask] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let idC = sqlite3_column_text(stmt, 0),
                  let id = UUID(uuidString: String(cString: idC)),
                  let titleC = sqlite3_column_text(stmt, 1),
                  let promptC = sqlite3_column_text(stmt, 2),
                  let modelC = sqlite3_column_text(stmt, 7) else { continue }
            let weekdaysStr = sqlite3_column_text(stmt, 5).map { String(cString: $0) } ?? ""
            let weekdays = Set(weekdaysStr.split(separator: ",").compactMap { Int($0) })
            let lastRun = sqlite3_column_type(stmt, 8) == SQLITE_NULL
                ? nil : Date(timeIntervalSince1970: sqlite3_column_double(stmt, 8))
            out.append(ScheduledTask(
                id: id,
                title: String(cString: titleC),
                prompt: String(cString: promptC),
                hour: Int(sqlite3_column_int(stmt, 3)),
                minute: Int(sqlite3_column_int(stmt, 4)),
                weekdays: weekdays,
                enabled: sqlite3_column_int(stmt, 6) != 0,
                model: String(cString: modelC),
                lastRun: lastRun,
                createdAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 9))
            ))
        }
        return out
    }

    // MARK: - Inbox items (questions + notices queued during autonomous runs)
    // Stored in the legacy-named `pending_questions` table as JSON blobs; old
    // PendingQuestion rows decode transparently as `.question` InboxItems.

    func saveInboxItem(_ item: InboxItem) {
        guard let data = try? encoder.encode(item),
              let json = String(data: data, encoding: .utf8) else { return }
        let sql = """
        INSERT INTO pending_questions(id,payload,answered,created_at) VALUES(?,?,?,?)
        ON CONFLICT(id) DO UPDATE SET payload=excluded.payload, answered=excluded.answered;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, item.id.uuidString, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, json, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int(stmt, 3, item.answeredAt == nil ? 0 : 1)
        sqlite3_bind_double(stmt, 4, item.createdAt.timeIntervalSince1970)
        sqlite3_step(stmt)
    }

    func deleteInboxItem(id: UUID) {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "DELETE FROM pending_questions WHERE id=?;", -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, id.uuidString, -1, SQLITE_TRANSIENT)
        sqlite3_step(stmt)
    }

    /// Loads queued inbox items. By default only the unresolved ones (what the
    /// inbox shows); resolved rows are kept for the record but filtered out here.
    func loadInboxItems(includeResolved: Bool = false) -> [InboxItem] {
        let sql = includeResolved
            ? "SELECT payload FROM pending_questions ORDER BY created_at ASC;"
            : "SELECT payload FROM pending_questions WHERE answered=0 ORDER BY created_at ASC;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        var out: [InboxItem] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let payloadC = sqlite3_column_text(stmt, 0),
                  let item = try? decoder.decode(InboxItem.self,
                                                 from: Data(String(cString: payloadC).utf8)) else { continue }
            out.append(item)
        }
        return out
    }

    // MARK: - Task runs (headless execution log)

    func saveTaskRun(_ r: TaskRun) {
        let sql = """
        INSERT INTO task_runs(id,task_id,title,model,prompt,output,ok,started_at)
        VALUES(?,?,?,?,?,?,?,?);
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, r.id.uuidString, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, r.taskID.uuidString, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 3, r.title, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 4, r.model, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 5, r.prompt, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 6, r.output, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int(stmt, 7, r.ok ? 1 : 0)
        sqlite3_bind_double(stmt, 8, r.startedAt.timeIntervalSince1970)
        sqlite3_step(stmt)
    }

    func deleteTaskRun(id: UUID) {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "DELETE FROM task_runs WHERE id=?;", -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, id.uuidString, -1, SQLITE_TRANSIENT)
        sqlite3_step(stmt)
    }

    /// Removes run-log rows older than `days`. Returns how many were deleted.
    @discardableResult
    func purgeTaskRuns(olderThan days: Int) -> Int {
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400).timeIntervalSince1970
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "DELETE FROM task_runs WHERE started_at < ?;", -1, &stmt, nil) == SQLITE_OK
        else { return 0 }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_double(stmt, 1, cutoff)
        sqlite3_step(stmt)
        return Int(sqlite3_changes(db))
    }

    func loadTaskRuns() -> [TaskRun] {
        let sql = "SELECT id,task_id,title,model,prompt,output,ok,started_at FROM task_runs ORDER BY started_at DESC;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        var out: [TaskRun] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let idC = sqlite3_column_text(stmt, 0),
                  let id = UUID(uuidString: String(cString: idC)),
                  let taskC = sqlite3_column_text(stmt, 1),
                  let taskID = UUID(uuidString: String(cString: taskC)),
                  let titleC = sqlite3_column_text(stmt, 2),
                  let modelC = sqlite3_column_text(stmt, 3),
                  let promptC = sqlite3_column_text(stmt, 4),
                  let outputC = sqlite3_column_text(stmt, 5) else { continue }
            out.append(TaskRun(
                id: id,
                taskID: taskID,
                title: String(cString: titleC),
                model: String(cString: modelC),
                prompt: String(cString: promptC),
                output: String(cString: outputC),
                ok: sqlite3_column_int(stmt, 6) != 0,
                startedAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 7))
            ))
        }
        return out
    }

    deinit { sqlite3_close(db) }
}
