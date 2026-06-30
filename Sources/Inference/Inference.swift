import Foundation

/// The engine-agnostic inference boundary the whole app depends on.
///
/// Nothing above this protocol knows whether generation happens in-process (MLX), via a
/// bundled/loopback server, in LM Studio, or in a cloud backend — selecting the backend
/// must never change a caller. The context-aware chunk/merge orchestration that guarantees
/// a long transcript never loses its start lives in `Refiner`, one layer up, and depends
/// only on `generate` + `contextWindow` here.
///
/// Implementations are `Sendable` so they can be handed to the `Refiner` actor and the
/// `ThoughtPipeline` without crossing isolation unsafely.
protocol Inference: Sendable {
    /// Bring the engine to a ready state (load a model, start a server, …). A no-op for
    /// backends that need no setup. `onStatus` streams display-ready progress strings, or
    /// `nil` to clear the status line. Throws when the engine genuinely can't be made ready.
    func prepare(onStatus: @escaping @Sendable (String?) -> Void) async throws

    /// Free-form generation. Returns the model's raw assistant text (callers that need the
    /// mechanical scaffolding stripped apply `OutputSanitizer` themselves — intermediate
    /// reasoning stages deliberately do not).
    func generate(_ request: InferenceRequest) async throws -> String

    /// Generation constrained to a JSON schema; decode into `T`. The default implementation
    /// (see the extension) instructs strict-JSON output and repairs-and-retries once before
    /// failing — backends with native grammar/schema-constrained decoding may override.
    func generateStructured<T: Decodable & Sendable>(
        _ request: InferenceRequest, as type: T.Type, schema: JSONSchema
    ) async throws -> T

    /// The loaded model's usable context window, in tokens. Sizes chunking in `Refiner`.
    var contextWindow: Int { get async }
}

extension Inference {
    /// Convenience: prepare without observing status.
    func prepare() async throws { try await prepare(onStatus: { _ in }) }

    /// Default structured generation: ask for strict JSON matching `schema`, parse it, and on
    /// failure repair-and-retry exactly once (per the architecture's §6 contract) before
    /// surfacing a clear error. Works for any backend; engines with native schema-constrained
    /// decoding can override for a hard guarantee.
    func generateStructured<T: Decodable & Sendable>(
        _ request: InferenceRequest, as type: T.Type, schema: JSONSchema
    ) async throws -> T {
        let schemaJSON = schema.jsonString
        let instruction = """
        Respond with a single JSON object that strictly conforms to this JSON Schema. Output \
        ONLY the JSON — no prose, no markdown, no code fences, no comments. Every required \
        field must be present; use null or empty arrays where you have nothing, never omit a \
        field or invent data.

        JSON Schema (\(schema.name)):
        \(schemaJSON)

        /no_think
        """

        var messages = request.messages
        // Fold the schema instruction into the system message so it dominates.
        if let firstSystem = messages.firstIndex(where: { $0.role == .system }) {
            messages[firstSystem] = ChatMessage(.system, messages[firstSystem].content + "\n\n" + instruction)
        } else {
            messages.insert(ChatMessage(.system, instruction), at: 0)
        }
        var attemptRequest = request
        attemptRequest.messages = messages

        let raw = try await generate(attemptRequest)
        if let value = JSONExtraction.decode(T.self, from: raw) { return value }

        // Repair pass: hand the model back its own output and the failure, ask for clean JSON.
        let repair = InferenceRequest(
            messages: messages + [
                ChatMessage(.assistant, raw),
                ChatMessage(.user, """
                That was not valid JSON for the schema. Output ONLY a single valid JSON object \
                conforming to the schema above — no prose, no code fences. Begin with '{'.
                """),
            ],
            temperature: 0,
            maxTokens: request.maxTokens
        )
        let repaired = try await generate(repair)
        if let value = JSONExtraction.decode(T.self, from: repaired) { return value }
        throw InferenceError.decodingFailed(
            "The model did not return JSON matching the \(schema.name) schema after a repair attempt.")
    }
}

// MARK: - Request

/// One chat message in an inference request.
struct ChatMessage: Sendable, Codable, Equatable {
    enum Role: String, Sendable, Codable { case system, user, assistant }
    let role: Role
    let content: String
    init(_ role: Role, _ content: String) {
        self.role = role
        self.content = content
    }
}

/// A backend-neutral generation request. `maxTokens == nil` lets the backend choose a cap
/// from its context budget.
struct InferenceRequest: Sendable {
    var messages: [ChatMessage]
    var temperature: Double
    var maxTokens: Int?

    init(messages: [ChatMessage], temperature: Double = 0.2, maxTokens: Int? = nil) {
        self.messages = messages
        self.temperature = temperature
        self.maxTokens = maxTokens
    }

    /// Convenience for the common system + user shape.
    init(system: String, user: String, temperature: Double = 0.2, maxTokens: Int? = nil) {
        self.init(
            messages: [ChatMessage(.system, system), ChatMessage(.user, user)],
            temperature: temperature,
            maxTokens: maxTokens)
    }
}

// MARK: - Errors

enum InferenceError: LocalizedError, Equatable {
    case notReady(String)
    case generationFailed(String)
    case emptyOutput
    case decodingFailed(String)

    var errorDescription: String? {
        switch self {
        case .notReady(let message): return message
        case .generationFailed(let message): return message
        case .emptyOutput: return "The model returned an empty response."
        case .decodingFailed(let message): return message
        }
    }
}
