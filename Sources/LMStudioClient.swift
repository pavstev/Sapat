import Foundation

/// Wire-level transport to a local LM Studio server. It is the LM Studio *backend*'s
/// low-level surface: a single chat round-trip plus the native REST queries for readiness
/// and the loaded model's context length (which the OpenAI-compatible surface doesn't
/// expose). The whole-recording chunk/merge orchestration and the refinement prompts now
/// live in `Refiner` (backend-neutral); this type only speaks the protocol.
struct LMStudioClient {
    /// LM Studio's OpenAI-compatible chat-completions endpoint (default port 1234).
    var chatEndpoint = URL(string: "http://localhost:1234/v1/chat/completions")!
    /// LM Studio's native REST API — reports per-model `state` + `loaded_context_length`,
    /// which the OpenAI-compatible surface doesn't expose.
    var modelsEndpoint = URL(string: "http://localhost:1234/api/v0/models")!
    /// Model id to request. Defaults to `TranslationPreferences.model`.
    var model = TranslationPreferences.model
    /// Long transcripts + a larger model need headroom over the old 45s.
    var timeout: TimeInterval = 120

    /// Used to size chunking when the loaded context length can't be read (e.g. the model was
    /// loaded through a different tool). LM Studio's out-of-the-box default is 4096, so
    /// assuming it keeps us safe rather than optimistic.
    static let fallbackContextLength = 4096

    // MARK: - Readiness (native API)

    /// Where a model sits in LM Studio right now.
    enum ModelPresence: Equatable {
        case loaded            // in memory, ready to serve
        case downloadedNotLoaded
        case absent            // not downloaded
        case serverUnreachable
    }

    /// True when the server answers at all (any HTTP status — even a 5xx mid-startup means
    /// it's up and we shouldn't try to start it again).
    func isServerReachable() async -> Bool {
        var request = URLRequest(url: modelsEndpoint)
        request.timeoutInterval = 5
        guard let (_, response) = try? await URLSession.shared.data(for: request) else { return false }
        return response is HTTPURLResponse
    }

    /// Whether a model matching `modelKey` is loaded / merely downloaded / absent. Matching is
    /// normalized (see `modelsMatch`) because `lms get qwen/qwen3-8b` lands a download whose
    /// reported id is something like `lmstudio-community/Qwen3-8B-MLX-4bit`.
    func presence(of modelKey: String) async -> ModelPresence {
        guard let models = await fetchModels() else { return .serverUnreachable }
        let matching = models.filter { Self.modelsMatch($0.id, modelKey) }
        guard !matching.isEmpty else { return .absent }
        return matching.contains { $0.state == "loaded" } ? .loaded : .downloadedNotLoaded
    }

    /// The loaded model that best matches the configured `model`, with its **actual** API id
    /// (sent in the chat request) and context window (sizes chunking). Prefers an exact id,
    /// then a normalized match, then any loaded model.
    struct ResolvedModel { let id: String; let context: Int }

    func resolveModel() async -> ResolvedModel? {
        guard let models = await fetchModels() else { return nil }
        let loaded = models.filter { $0.state == "loaded" }
        let pick = loaded.first { $0.id == model }
            ?? loaded.first { Self.modelsMatch($0.id, model) }
            ?? loaded.first
        guard let pick else { return nil }
        let context = pick.loadedContextLength ?? pick.maxContextLength ?? Self.fallbackContextLength
        return ResolvedModel(id: pick.id, context: context)
    }

    /// Loose model-id comparison: reduce each id to its last path component, lowercased,
    /// alphanumerics only, then match if one contains the other. So `qwen/qwen3-8b` matches
    /// `lmstudio-community/Qwen3-8B-MLX-4bit` (qwen38b ⊂ qwen38bmlx4bit) but not `qwen3-80b`.
    static func modelsMatch(_ a: String, _ b: String) -> Bool {
        let na = normalizedModelKey(a), nb = normalizedModelKey(b)
        guard !na.isEmpty, !nb.isEmpty else { return false }
        return na.contains(nb) || nb.contains(na)
    }

    static func normalizedModelKey(_ id: String) -> String {
        let leaf = id.split(separator: "/").last.map(String.init) ?? id
        return leaf.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    private func fetchModels() async -> [ModelInfo]? {
        var request = URLRequest(url: modelsEndpoint)
        request.timeoutInterval = 8
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              let decoded = try? JSONDecoder().decode(ModelsResponse.self, from: data)
        else { return nil }
        return decoded.data
    }

    // MARK: - Single chat completion

    /// One chat-completions round-trip. Returns the model's raw assistant text (the caller
    /// sanitizes). Inspects `finish_reason` so a truncated *output* is at least logged rather
    /// than silently shipped. Throws `LMStudioError` on any connectivity/status problem.
    func complete(messages: [ChatMessage], temperature: Double, maxTokens: Int, modelID: String) async throws -> String {
        var request = URLRequest(url: chatEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = timeout

        let payload = ChatRequest(
            model: modelID,
            messages: messages,
            temperature: temperature,
            maxTokens: maxTokens,
            stream: false)
        request.httpBody = try JSONEncoder().encode(payload)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch let error as URLError {
            switch error.code {
            case .cannotConnectToHost, .cannotFindHost, .networkConnectionLost,
                 .timedOut, .notConnectedToInternet:
                throw LMStudioError.notRunning
            default:
                throw LMStudioError.other(error.localizedDescription)
            }
        }

        guard let http = response as? HTTPURLResponse else {
            throw LMStudioError.other("Unexpected response from LM Studio.")
        }
        if http.statusCode == 404 {
            throw LMStudioError.modelNotLoaded
        }
        guard (200..<300).contains(http.statusCode) else {
            throw LMStudioError.other("LM Studio returned HTTP \(http.statusCode).")
        }

        let decoded = try JSONDecoder().decode(ChatResponse.self, from: data)
        guard let choice = decoded.choices.first else {
            throw LMStudioError.other("LM Studio returned no choices.")
        }
        if choice.finishReason == "length" {
            Log.llm.error("LM Studio output hit the length cap — refined text may be cut short.")
        }
        return choice.message.content
    }

    // MARK: - Wire types

    private struct ChatRequest: Encodable {
        let model: String
        let messages: [ChatMessage]
        let temperature: Double
        let maxTokens: Int
        let stream: Bool
        enum CodingKeys: String, CodingKey {
            case model, messages, temperature, stream
            case maxTokens = "max_tokens"
        }
    }

    private struct ChatResponse: Decodable {
        let choices: [Choice]
        struct Choice: Decodable {
            let message: WireMessage
            let finishReason: String?
            enum CodingKeys: String, CodingKey {
                case message
                case finishReason = "finish_reason"
            }
        }
        struct WireMessage: Decodable { let role: String; let content: String }
    }

    private struct ModelsResponse: Decodable { let data: [ModelInfo] }

    private struct ModelInfo: Decodable {
        let id: String
        let state: String?
        let loadedContextLength: Int?
        let maxContextLength: Int?
        enum CodingKeys: String, CodingKey {
            case id, state
            case loadedContextLength = "loaded_context_length"
            case maxContextLength = "max_context_length"
        }
    }
}

enum LMStudioError: LocalizedError, Equatable {
    case notRunning
    case modelNotLoaded
    case cliNotFound
    case setupFailed(String)
    case other(String)

    var errorDescription: String? {
        switch self {
        case .notRunning: return "LM Studio isn't running."
        case .modelNotLoaded: return "No model is loaded in LM Studio."
        case .cliNotFound: return "The LM Studio command-line tool (lms) wasn't found."
        case .setupFailed(let message): return message
        case .other(let message): return message
        }
    }
}
