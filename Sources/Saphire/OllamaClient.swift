import Foundation

/// A tool call requested by the model. `argumentsJSON` is the raw JSON object
/// string of the call arguments (kept as a string so the value stays Sendable
/// and crosses actor boundaries cleanly).
struct ToolCallRequest: Codable, Sendable, Hashable {
    let name: String
    let argumentsJSON: String
}

struct OllamaMessage: Codable, Sendable {
    let role: String
    var content: String = ""
    var images: [String]? = nil
    /// Set on `assistant` turns that requested tools (replayed back to the model).
    var toolCalls: [ToolCallRequest]? = nil
    /// Set on `tool` turns to identify which tool produced `content`.
    var toolName: String? = nil
}

/// Generation/runtime options forwarded to Ollama's /api/chat. A `nil` field is
/// omitted from the request so the server keeps its own default for that key.
/// Sending these is what lets us exploit gemma4's large context window and keep
/// the model warm between overlay invocations.
struct GenOptions: Codable, Sendable {
    var numCtx: Int?
    var temperature: Double?
    var topP: Double?
    var topK: Int?
    var numPredict: Int?
    var repeatPenalty: Double?
    var seed: Int?
    /// Ollama `keep_alive`: how long the model stays resident after a request
    /// (e.g. "30m", "1h", "0" to unload immediately). Sent at the top level.
    var keepAlive: String?

    /// Tuned defaults for gemma4: a generous context window (vs Ollama's ~4096
    /// default) to use its long context, balanced sampling, and a warm model.
    /// `num_ctx` drives KV-cache size, so 16K is a RAM-friendly middle ground.
    static let gemma4Default = GenOptions(
        numCtx: 16384, temperature: 0.7, topP: 0.95, topK: 64,
        numPredict: nil, repeatPenalty: 1.0, seed: nil, keepAlive: "30m")

    /// The `options` sub-object for /api/chat, containing only non-nil keys.
    var optionsDict: [String: Any] {
        var d: [String: Any] = [:]
        if let numCtx { d["num_ctx"] = numCtx }
        if let temperature { d["temperature"] = temperature }
        if let topP { d["top_p"] = topP }
        if let topK { d["top_k"] = topK }
        if let numPredict { d["num_predict"] = numPredict }
        if let repeatPenalty { d["repeat_penalty"] = repeatPenalty }
        if let seed { d["seed"] = seed }
        return d
    }
}

/// Minimal streaming client for a local Ollama server.
actor OllamaClient {
    private let base = URL(string: "http://localhost:11434")!

    /// Dedicated session for /api/chat. `timeoutIntervalForRequest` acts as an
    /// *idle* timeout on a streaming response, and the shared session's 60s
    /// default is shorter than a cold model load plus a long uncached prefill
    /// (Ollama sends no bytes until the first token — a full 32K-token prefill
    /// at ~400 tok/s alone exceeds 60s). 300s tolerates that while still
    /// bounding a genuine server hang; the resource timeout caps one whole
    /// response at an hour.
    private let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 300
        cfg.timeoutIntervalForResource = 3600
        return URLSession(configuration: cfg)
    }()

    struct OllamaError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    // MARK: - Server bootstrap

    /// Ensures a local Ollama server is reachable. If not, spawns `ollama serve`
    /// and waits (up to ~10s) for it to come up. Safe to call repeatedly.
    ///
    /// A GUI app launched at login does not inherit the shell `PATH`, so we
    /// locate the binary via absolute paths rather than relying on `ollama`
    /// being on `PATH`.
    func ensureServerRunning() async {
        if await isReachable() { return }
        spawnServe()
        for _ in 0..<40 {
            try? await Task.sleep(nanoseconds: 250_000_000)  // 0.25s
            if await isReachable() { return }
        }
    }

    private func isReachable() async -> Bool {
        var req = URLRequest(url: base.appending(path: "api/tags"))
        req.timeoutInterval = 1.5
        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            return (resp as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    private func spawnServe() {
        let candidates = [
            "/opt/homebrew/bin/ollama",  // Apple Silicon Homebrew
            "/usr/local/bin/ollama",     // Intel Homebrew
            "/usr/bin/ollama"
        ]
        guard let path = candidates.first(where: {
            FileManager.default.isExecutableFile(atPath: $0)
        }) else { return }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = ["serve"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        // Detached: the server outlives this object and keeps running for the
        // rest of the session. Only spawned when nothing answers on :11434.
        try? p.run()
    }

    /// Installed model tags via GET /api/tags.
    func listModels() async throws -> [String] {
        let url = base.appending(path: "api/tags")
        let (data, resp) = try await URLSession.shared.data(from: url)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            throw OllamaError(message: "Ollama no responde en localhost:11434")
        }
        struct Tags: Decodable { struct M: Decodable { let name: String }; let models: [M] }
        let tags = try JSONDecoder().decode(Tags.self, from: data)
        return tags.models.map(\.name)
    }

    /// Streams a chat completion. `onToken` is invoked for each delta with
    /// (contentDelta, thinkingDelta). Either may be empty. Returns any tool
    /// calls the model requested this turn (empty for a plain answer).
    ///
    /// `tools` advertises callable functions to a tool-capable model. `think`
    /// is sent explicitly as `true`/`false`: omitting the field lets a
    /// thinking-capable model reason by default, so `false` must be sent to
    /// actually turn reasoning off. If the model rejects the field entirely
    /// ("does not support thinking"), the request is retried without it.
    @discardableResult
    func chat(
        model: String,
        messages: [OllamaMessage],
        tools: [ToolSpec]? = nil,
        options: GenOptions = .gemma4Default,
        think: Bool,
        onToken: @escaping @Sendable (String, String) -> Void
    ) async throws -> [ToolCallRequest] {
        do {
            return try await stream(model: model, messages: messages, tools: tools, options: options, think: think, onToken: onToken)
        } catch let e as OllamaError where e.message.localizedCaseInsensitiveContains("does not support thinking") {
            return try await stream(model: model, messages: messages, tools: tools, options: options, think: nil, onToken: onToken)
        }
    }

    /// One streaming attempt. `think == nil` omits the field; otherwise it is
    /// sent verbatim.
    private func stream(
        model: String,
        messages: [OllamaMessage],
        tools: [ToolSpec]?,
        options: GenOptions,
        think: Bool?,
        onToken: @escaping @Sendable (String, String) -> Void
    ) async throws -> [ToolCallRequest] {
        var req = URLRequest(url: base.appending(path: "api/chat"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var body: [String: Any] = [
            "model": model,
            "stream": true,
            "messages": messages.map { m -> [String: Any] in
                var d: [String: Any] = ["role": m.role, "content": m.content]
                if let imgs = m.images, !imgs.isEmpty { d["images"] = imgs }
                if let tn = m.toolName { d["tool_name"] = tn }
                if let tcs = m.toolCalls, !tcs.isEmpty {
                    d["tool_calls"] = tcs.map { tc -> [String: Any] in
                        let args = (try? JSONSerialization.jsonObject(with: Data(tc.argumentsJSON.utf8))) ?? [:]
                        return ["function": ["name": tc.name, "arguments": args]]
                    }
                }
                return d
            }
        ]
        if let think { body["think"] = think }
        if let tools, !tools.isEmpty,
           let toolsData = try? JSONEncoder().encode(tools),
           let toolsJSON = try? JSONSerialization.jsonObject(with: toolsData) {
            body["tools"] = toolsJSON
        }
        let opts = options.optionsDict
        if !opts.isEmpty { body["options"] = opts }
        if let ka = options.keepAlive, !ka.isEmpty { body["keep_alive"] = ka }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        // Request summary (which tools reach Ollama, prompt size). Only written
        // when SAPHIRE_DEBUG is set — see saphireDebug.
        if saphireDebugEnabled {
            let toolNames = (tools ?? []).map { $0.function.name }.joined(separator: ",")
            let chars = messages.reduce(0) { $0 + $1.content.count }
            let roles = messages.map { $0.role }.joined(separator: ">")
            saphireDebug("model=\(model) think=\(String(describing: think)) "
                + "num_ctx=\(opts["num_ctx"].map { "\($0)" } ?? "nil") "
                + "tools=\(tools?.count ?? 0)[\(toolNames)] "
                + "msgs=\(messages.count)(\(roles)) totalContentChars=\(chars)")
        }

        let (bytes, resp) = try await session.bytes(for: req)
        guard let http = resp as? HTTPURLResponse else {
            throw OllamaError(message: "Ollama: respuesta inválida")
        }
        guard http.statusCode == 200 else {
            // Drain the body to surface Ollama's error message (e.g. a model
            // that rejects the `think` field or doesn't support tools).
            var raw = ""
            for try await line in bytes.lines { raw += line }
            let msg = (try? JSONDecoder().decode([String: String].self, from: Data(raw.utf8)))?["error"]
            throw OllamaError(message: msg ?? "Ollama HTTP \(http.statusCode)")
        }

        var collected: [ToolCallRequest] = []
        for try await line in bytes.lines {
            guard let obj = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
            else { continue }
            if let err = obj["error"] as? String { throw OllamaError(message: err) }
            if let msg = obj["message"] as? [String: Any] {
                let c = msg["content"] as? String ?? ""
                let t = msg["thinking"] as? String ?? ""
                if !c.isEmpty || !t.isEmpty { onToken(c, t) }
                if let tcs = msg["tool_calls"] as? [[String: Any]] {
                    for tc in tcs {
                        guard let fn = tc["function"] as? [String: Any],
                              let name = fn["name"] as? String else { continue }
                        let argsJSON: String
                        if let s = fn["arguments"] as? String {
                            argsJSON = s
                        } else if let a = fn["arguments"],
                                  let d = try? JSONSerialization.data(withJSONObject: a) {
                            argsJSON = String(data: d, encoding: .utf8) ?? "{}"
                        } else {
                            argsJSON = "{}"
                        }
                        collected.append(ToolCallRequest(name: name, argumentsJSON: argsJSON))
                    }
                }
            }
            if obj["done"] as? Bool == true { break }
        }
        return collected
    }
}
