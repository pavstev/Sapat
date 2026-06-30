import Foundation

/// `Inference` backed by a local LM Studio server. This keeps the existing, working LM Studio
/// path available as an opt-in backend (and the interim default until the in-process MLX
/// engine is wired). All LM-Studio-specific concerns — the `lms` CLI, the `:1234` server,
/// runtime install, model download/load, and the proprietary native model API — stay sealed
/// inside this file and its two helpers (`LMStudioManager`, `LMStudioClient`), so nothing
/// above the `Inference` protocol depends on LM Studio.
struct LMStudioInference: Inference {
    private let client: LMStudioClient
    private let manager: LMStudioManager
    private let modelKey: String

    init(model: String = TranslationPreferences.model) {
        self.modelKey = model
        self.client = LMStudioClient(model: model)
        self.manager = LMStudioManager()
    }

    func prepare(onStatus: @escaping @Sendable (String?) -> Void) async throws {
        try await manager.ensureReady(modelKey: modelKey, client: client) { status in
            onStatus(status)
        }
    }

    func generate(_ request: InferenceRequest) async throws -> String {
        let resolved = await client.resolveModel()
        let modelID = resolved?.id ?? modelKey                       // actual loaded id, so the request never 404s on naming
        let context = resolved?.context ?? LMStudioClient.fallbackContextLength
        let maxTokens = request.maxTokens ?? Self.defaultMaxTokens(for: request, context: context)
        return try await client.complete(
            messages: request.messages,
            temperature: request.temperature,
            maxTokens: maxTokens,
            modelID: modelID)
    }

    var contextWindow: Int {
        get async { await client.resolveModel()?.context ?? LMStudioClient.fallbackContextLength }
    }

    /// When a caller doesn't size `maxTokens` itself (e.g. a pipeline stage), leave generation
    /// room under a 0.9 safety budget after the prompt.
    private static func defaultMaxTokens(for request: InferenceRequest, context: Int) -> Int {
        let promptTokens = request.messages.reduce(0) { $0 + TranscriptChunker.estimateTokens($1.content) }
        return max(128, Int(Double(context) * 0.9) - promptTokens)
    }
}
