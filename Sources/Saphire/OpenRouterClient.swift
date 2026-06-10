import Foundation

/// Streaming client for OpenRouter's OpenAI-compatible Chat Completions API
/// (`https://openrouter.ai/api/v1/chat/completions`). One key unlocks Claude,
/// GPT, Gemini, Llama, etc. Mirrors `OllamaClient.chat`'s shape (same message,
/// tool and token-callback types) so `AppState` can route to either backend by
/// model with no other changes.
///
/// Translation done here: Ollama-native `OllamaMessage`/`ToolCallRequest` <->
/// OpenAI `messages`/`tool_calls`, SSE deltas -> the `(content, thinking)`
/// callback, and OpenAI's incremental `tool_calls` chunks -> whole
/// `ToolCallRequest`s. `ToolSpec` is already OpenAI function-call shaped, so it
/// is forwarded as-is.
actor OpenRouterClient {
    private let defaultEndpoint = URL(string: "https://openrouter.ai/api/v1/chat/completions")!

    /// Streams a chat completion from OpenRouter. Signature matches
    /// `OllamaClient.chat` minus `think` (reasoning models stream their thoughts
    /// on `delta.reasoning`, surfaced via the second `onToken` argument; nothing
    /// needs to be requested). Throws `OllamaClient.OllamaError` so AppState's
    /// existing error handling (e.g. "does not support tools") works unchanged.
    /// `endpoint` overrides the OpenRouter URL so the same OpenAI-compatible
    /// translation can drive any compatible server (LM Studio, OpenAI direct,
    /// vLLM, etc.). When nil, OpenRouter is used and a (possibly empty) key is
    /// required; for a custom local endpoint the key may be empty.
    @discardableResult
    func chat(
        apiKey: String,
        model: String,
        messages: [OllamaMessage],
        tools: [ToolSpec]? = nil,
        options: GenOptions = .gemma4Default,
        endpoint: URL? = nil,
        onToken: @escaping @Sendable (String, String) -> Void
    ) async throws -> [ToolCallRequest] {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let isOpenRouter = endpoint == nil
        guard !isOpenRouter || !key.isEmpty else {
            throw OllamaClient.OllamaError(message: "Falta la API key de OpenRouter (Ajustes › Generación).")
        }

        var req = URLRequest(url: endpoint ?? defaultEndpoint)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !key.isEmpty { req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        if isOpenRouter {
            // Optional OpenRouter attribution headers (used for its app rankings).
            req.setValue("https://github.com/saphire", forHTTPHeaderField: "HTTP-Referer")
            req.setValue("Saphire", forHTTPHeaderField: "X-Title")
        }

        // Anthropic models on OpenRouter support prompt caching via
        // `cache_control` breakpoints on message content. The system block
        // (identity + memory + tool guidance) and the conversation prefix are
        // stable across a turn's agent loop and between turns, so caching them
        // cuts both latency and input-token cost on repeat requests.
        let cacheable = Self.supportsPromptCaching(model)
        var body: [String: Any] = [
            "model": model,
            "stream": true,
            "messages": Self.openAIMessages(messages, cacheable: cacheable)
        ]
        if let t = options.temperature { body["temperature"] = t }
        if let p = options.topP { body["top_p"] = p }
        if let k = options.topK, k > 0 { body["top_k"] = k }
        if let rp = options.repeatPenalty { body["repetition_penalty"] = rp }
        if let n = options.numPredict, n > 0 { body["max_tokens"] = n }
        if let seed = options.seed { body["seed"] = seed }
        if let tools, !tools.isEmpty,
           let data = try? JSONEncoder().encode(tools),
           let json = try? JSONSerialization.jsonObject(with: data) {
            body["tools"] = json
        }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (bytes, resp) = try await URLSession.shared.bytes(for: req)
        guard let http = resp as? HTTPURLResponse else {
            throw OllamaClient.OllamaError(message: "OpenRouter: respuesta inválida")
        }
        guard http.statusCode == 200 else {
            // Drain the body to surface OpenRouter's JSON error message.
            var raw = ""
            for try await line in bytes.lines { raw += line }
            throw OllamaClient.OllamaError(message: Self.errorMessage(raw, status: http.statusCode))
        }

        // OpenAI streams tool calls incrementally: each SSE chunk may carry a
        // fragment (id / name / a slice of the JSON arguments) keyed by `index`.
        // Accumulate per index, then materialize once the stream ends.
        var toolByIndex: [Int: (id: String, name: String, args: String)] = [:]

        for try await line in bytes.lines {
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload.isEmpty { continue }
            if payload == "[DONE]" { break }
            guard let data = payload.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }

            if let err = obj["error"] as? [String: Any] {
                throw OllamaClient.OllamaError(message: err["message"] as? String ?? "OpenRouter error")
            }
            guard let choices = obj["choices"] as? [[String: Any]],
                  let choice = choices.first,
                  let delta = choice["delta"] as? [String: Any]
            else { continue }

            let content = delta["content"] as? String ?? ""
            // Reasoning models expose their chain of thought on `reasoning`.
            let thinking = delta["reasoning"] as? String ?? ""
            if !content.isEmpty || !thinking.isEmpty { onToken(content, thinking) }

            if let tcs = delta["tool_calls"] as? [[String: Any]] {
                for tc in tcs {
                    let index = tc["index"] as? Int ?? 0
                    var entry = toolByIndex[index] ?? (id: "", name: "", args: "")
                    if let id = tc["id"] as? String, !id.isEmpty { entry.id = id }
                    if let fn = tc["function"] as? [String: Any] {
                        if let n = fn["name"] as? String, !n.isEmpty { entry.name = n }
                        if let a = fn["arguments"] as? String { entry.args += a }
                    }
                    toolByIndex[index] = entry
                }
            }
        }

        return toolByIndex.keys.sorted().compactMap { idx in
            guard let e = toolByIndex[idx], !e.name.isEmpty else { return nil }
            let args = e.args.isEmpty ? "{}" : e.args
            return ToolCallRequest(name: e.name, argumentsJSON: args)
        }
    }

    /// Available model ids from GET /api/v1/models. Best-effort; used to validate
    /// or autocomplete the user's chosen remote models.
    func listModels(apiKey: String, modelsURL: URL? = nil) async throws -> [String] {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        var req = URLRequest(url: modelsURL ?? URL(string: "https://openrouter.ai/api/v1/models")!)
        if !key.isEmpty { req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
            throw OllamaClient.OllamaError(message: "OpenRouter no responde")
        }
        struct List: Decodable { struct M: Decodable { let id: String }; let data: [M] }
        return (try JSONDecoder().decode(List.self, from: data)).data.map(\.id)
    }

    // MARK: - Translation

    /// Maps Ollama-native messages to OpenAI Chat Completions `messages`.
    ///
    /// Ollama tracks tool turns by `tool_name` only, but OpenAI requires each
    /// `tool` message to carry a `tool_call_id` matching an assistant
    /// `tool_calls[].id`. Saphire's history is strictly linear (an assistant
    /// tool-call turn is immediately followed by its results in order), so we
    /// synthesize ids on the assistant turn and hand them out to the following
    /// tool turns, matching by name first, then FIFO.
    /// Whether `model` is an Anthropic model routed through OpenRouter, which is
    /// the family that honors `cache_control` prompt-cache breakpoints.
    private static func supportsPromptCaching(_ model: String) -> Bool {
        let m = model.lowercased()
        return m.contains("anthropic") || m.contains("claude")
    }

    /// Tags a message dict's content with an ephemeral `cache_control` breakpoint
    /// so Anthropic caches the prompt prefix up to and including it. Wraps a
    /// plain string into a single text part; for an existing parts array the tag
    /// goes on the last part. Empty content (e.g. an assistant tool-call turn) is
    /// left untouched — there's nothing to cache and an empty text part is invalid.
    private static func withCacheControl(_ d: [String: Any]) -> [String: Any] {
        var d = d
        let ephemeral: [String: Any] = ["type": "ephemeral"]
        if var parts = d["content"] as? [[String: Any]], !parts.isEmpty {
            parts[parts.count - 1]["cache_control"] = ephemeral
            d["content"] = parts
        } else if let s = d["content"] as? String, !s.isEmpty {
            d["content"] = [["type": "text", "text": s, "cache_control": ephemeral]]
        }
        return d
    }

    private static func openAIMessages(_ msgs: [OllamaMessage],
                                       cacheable: Bool = false) -> [[String: Any]] {
        var out: [[String: Any]] = []
        var pending: [(name: String, id: String)] = []

        for (i, m) in msgs.enumerated() {
            if m.role == "tool" {
                var d: [String: Any] = ["role": "tool", "content": m.content]
                let name = m.toolName ?? ""
                if let idx = pending.firstIndex(where: { $0.name == name }) {
                    d["tool_call_id"] = pending.remove(at: idx).id
                } else if !pending.isEmpty {
                    d["tool_call_id"] = pending.removeFirst().id
                } else {
                    d["tool_call_id"] = "call_\(i)"
                }
                if !name.isEmpty { d["name"] = name }
                out.append(d)
                continue
            }

            var d: [String: Any] = ["role": m.role]
            if let imgs = m.images, !imgs.isEmpty, m.role == "user" {
                var parts: [[String: Any]] = []
                if !m.content.isEmpty { parts.append(["type": "text", "text": m.content]) }
                for b in imgs {
                    parts.append(["type": "image_url",
                                  "image_url": ["url": "data:image/jpeg;base64,\(b)"]])
                }
                d["content"] = parts
            } else {
                d["content"] = m.content
            }
            if let tcs = m.toolCalls, !tcs.isEmpty {
                pending = []
                var arr: [[String: Any]] = []
                for (j, tc) in tcs.enumerated() {
                    let id = "call_\(i)_\(j)"
                    pending.append((tc.name, id))
                    arr.append(["id": id, "type": "function",
                                "function": ["name": tc.name, "arguments": tc.argumentsJSON]])
                }
                d["tool_calls"] = arr
            }
            out.append(d)
        }

        // Two cache breakpoints: the stable system block, and the tail of the
        // conversation so the whole prefix is reused on the next turn / round.
        if cacheable, !out.isEmpty {
            if let sysIdx = out.firstIndex(where: { ($0["role"] as? String) == "system" }) {
                out[sysIdx] = withCacheControl(out[sysIdx])
            }
            out[out.count - 1] = withCacheControl(out[out.count - 1])
        }
        return out
    }

    /// Extracts a human-readable message from an OpenRouter error body.
    private static func errorMessage(_ raw: String, status: Int) -> String {
        if let data = raw.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let err = obj["error"] as? [String: Any],
           let msg = err["message"] as? String {
            return "OpenRouter: \(msg)"
        }
        return "OpenRouter HTTP \(status)"
    }
}
