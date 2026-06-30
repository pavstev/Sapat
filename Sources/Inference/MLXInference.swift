#if canImport(MLXLLM)
import Foundation
import HuggingFace
import MLXHuggingFace
import MLXLLM
import MLXLMCommon
import Tokenizers

/// In-process LLM inference on Apple Silicon via MLX — the **default** engine. Loads a small,
/// strong, quantized reasoner once and serves the whole `ThoughtPipeline` locally: no sidecar,
/// no localhost server, no other apps. This is what makes Šapat self-contained (D1).
///
/// Compiled only when the MLX packages are present. The build uses `xcodebuild` (Xcode compiles
/// MLX's Metal kernels into `default.metallib`; a plain `swift build` under the Command Line
/// Tools cannot). The model is cached by the HuggingFace hub client outside the app bundle, so
/// it survives in-place updates and is fetched once.
///
/// Targets the mlx-swift-lm 3.31.x API: `#huggingFaceLoadModelContainer` (default hub client +
/// tokenizer loader) for loading, and `ChatSession` for generation. A fresh session per call
/// keeps generation stateless — the pipeline owns all context — so no history leaks between
/// stages.
actor MLXInference: Inference {
    /// Default reasoner: a small, strong, Apache-2.0 quantized chat model (3–4B class).
    static let defaultModelID = "mlx-community/Qwen3-4B-4bit"

    private let modelID: String
    private let maxContext: Int
    private var container: ModelContainer?

    init(modelID: String = MLXInference.defaultModelID, contextWindow: Int = 8192) {
        self.modelID = modelID
        self.maxContext = contextWindow
    }

    func prepare(onStatus: @escaping @Sendable (String?) -> Void) async throws {
        guard container == nil else { return }
        onStatus("Loading the on-device model…")
        do {
            let configuration = ModelConfiguration(id: modelID)
            container = try await #huggingFaceLoadModelContainer(configuration: configuration) { progress in
                onStatus("Downloading the on-device model… \(Int(progress.fractionCompleted * 100))%")
            }
            onStatus(nil)
        } catch {
            onStatus(nil)
            throw InferenceError.notReady("Couldn't load the on-device model: \(error.localizedDescription)")
        }
    }

    func generate(_ request: InferenceRequest) async throws -> String {
        let container = try await readyContainer()
        let system = request.messages.first { $0.role == .system }?.content
        let turns: [Chat.Message] = request.messages.compactMap { message in
            switch message.role {
            case .system: return nil               // folded into ChatSession instructions
            case .user: return .user(message.content)
            case .assistant: return .assistant(message.content)
            }
        }
        let parameters = GenerateParameters(
            maxTokens: request.maxTokens ?? 1024,
            temperature: Float(request.temperature))
        // A fresh session per call → stateless generation (the pipeline supplies all context).
        let session = ChatSession(container, instructions: system, generateParameters: parameters)
        return try await session.respond(to: turns)
    }

    var contextWindow: Int { get async { maxContext } }

    private func readyContainer() async throws -> ModelContainer {
        if let container { return container }
        try await prepare(onStatus: { _ in })
        guard let container else { throw InferenceError.notReady("The on-device model isn't loaded.") }
        return container
    }
}
#endif
