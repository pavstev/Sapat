import XCTest
@testable import Sapat

/// The staged "thinking" pipeline. We assert the right stages run for each mode (by counting
/// model round-trips) without a real model — extraction requests return valid §6 JSON, all
/// others return plain drafted text.
final class ThoughtPipelineTests: XCTestCase {
    private let extractionJSON = """
    {"intent":"ship the retry queue","topics":["infra"],\
    "decisions":[{"decision":"idempotent handler","rationale":"avoid dupes"}],\
    "open_questions":["which backoff?"],\
    "action_items":[{"task":"wire handler","owner":null,"context":"webhook"}],\
    "entities":[{"name":"retry queue","kind":"system"}],\
    "uncertainties":["scaling"]}
    """

    /// Returns extraction JSON for the schema-constrained call, plain text otherwise.
    private func mock() -> MockInference {
        let json = extractionJSON
        return MockInference(contextWindow: 8192) { request, _ in
            let system = request.messages.first(where: { $0.role == .system })?.content ?? ""
            return system.contains("thought_extraction") ? json : "Drafted artifact."
        }
    }

    func testPolishedEnglishIsCleanOnly() async throws {
        let mock = mock()
        let pipeline = ThoughtPipeline(inference: mock)
        let result = try await pipeline.run(transcript: "Treba da pošaljemo red.", mode: OutputModes.polishedEnglish)
        XCTAssertEqual(result.primary, "Drafted artifact.")
        XCTAssertEqual(result.primary, result.cleaned, "pure refine: the artifact is the cleaned base")
        XCTAssertNil(result.extraction)
        XCTAssertEqual(mock.generateCallCount, 1, "Polished English runs only the Clean stage")
    }

    func testStructuredBriefCleansExtractsSynthesizes() async throws {
        let mock = mock()
        let pipeline = ThoughtPipeline(inference: mock)
        let result = try await pipeline.run(transcript: "kratak transkript", mode: OutputModes.structuredBrief)
        XCTAssertEqual(result.primary, "Drafted artifact.")
        XCTAssertNotNil(result.extraction)
        XCTAssertEqual(result.extraction?.intent, "ship the retry queue")
        XCTAssertEqual(mock.generateCallCount, 3, "Clean + Extract + Synthesize")
    }

    func testEngineeringReportRunsAllStages() async throws {
        let mock = mock()
        let pipeline = ThoughtPipeline(inference: mock)
        let result = try await pipeline.run(transcript: "kratak transkript", mode: OutputModes.engineeringReport)
        XCTAssertFalse(result.primary.isEmpty)
        XCTAssertNotNil(result.extraction)
        // Clean + Extract + Reason + Critique + Synthesize.
        XCTAssertEqual(mock.generateCallCount, 5)
    }

    func testStandupExtractsThenSynthesizes() async throws {
        let mock = mock()
        let pipeline = ThoughtPipeline(inference: mock)
        let result = try await pipeline.run(transcript: "kratak transkript", mode: OutputModes.standup)
        XCTAssertEqual(result.primary, "Drafted artifact.")
        XCTAssertEqual(mock.generateCallCount, 3, "Clean + Extract + Synthesize (no reason/critique)")
    }

    func testRetrievedMemoryIsInjectedIntoThePrompt() async throws {
        // Seed memory with a related past note, then run a repeat-topic recording and assert the
        // note reaches the synthesis prompt (the mechanism behind "memory improves a repeat topic").
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("pipe-mem-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let memory = MemoryStore(path: tmp)
        await memory.index(
            id: "past", date: Date(), serbian: "",
            artifact: "We decided to use an idempotent webhook handler for the retry queue.",
            intent: "retry queue design", mode: "engineering-report")

        let mock = mock()
        let pipeline = ThoughtPipeline(inference: mock, memory: memory)
        _ = try await pipeline.run(transcript: "again about the retry queue and the idempotent handler", mode: OutputModes.structuredBrief)

        let injected = mock.requests.contains { request in
            request.messages.contains { $0.content.contains("idempotent webhook handler") }
        }
        XCTAssertTrue(injected, "the retrieved past note should be injected into a downstream prompt")
    }
}
