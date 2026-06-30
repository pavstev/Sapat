import XCTest
@testable import Sapat

/// The engine-agnostic `Inference` surface: the default structured-generation path must parse
/// clean JSON, repair-and-retry exactly once on bad output (§6), and fail clearly after that.
final class InferenceTests: XCTestCase {
    private struct Extraction: Decodable, Sendable, Equatable {
        let intent: String
        let topics: [String]
    }

    private let schema = JSONSchema(
        name: "extraction",
        schema: .object(
            properties: [("intent", .type("string")), ("topics", .arrayOf(.type("string")))],
            required: ["intent", "topics"]))

    private func request() -> InferenceRequest {
        InferenceRequest(system: "extract", user: "ship the queue; topics are infra and retries")
    }

    func testStructuredDecodesCleanJSON() async throws {
        let mock = MockInference(fixed: #"Here you go: {"intent":"ship the queue","topics":["infra","retries"]}"#)
        let value = try await mock.generateStructured(request(), as: Extraction.self, schema: schema)
        XCTAssertEqual(value, Extraction(intent: "ship the queue", topics: ["infra", "retries"]))
        XCTAssertEqual(mock.generateCallCount, 1, "valid JSON should not trigger a repair pass")
    }

    func testStructuredRepairsOnceThenSucceeds() async throws {
        let mock = MockInference { _, callIndex in
            callIndex == 0
                ? "I cannot do that."                                   // bad first attempt
                : #"{"intent":"ship the queue","topics":["infra"]}"#    // good repair
        }
        let value = try await mock.generateStructured(request(), as: Extraction.self, schema: schema)
        XCTAssertEqual(value, Extraction(intent: "ship the queue", topics: ["infra"]))
        XCTAssertEqual(mock.generateCallCount, 2, "one repair pass expected")
    }

    func testStructuredFailsAfterRepair() async {
        let mock = MockInference(fixed: "never any json")
        do {
            _ = try await mock.generateStructured(request(), as: Extraction.self, schema: schema)
            XCTFail("expected a decoding failure")
        } catch let error as InferenceError {
            guard case .decodingFailed = error else { return XCTFail("wrong error: \(error)") }
        } catch {
            XCTFail("unexpected error type: \(error)")
        }
        XCTAssertEqual(mock.generateCallCount, 2, "exactly one repair attempt, then give up")
    }

    func testContextWindowAndGeneratePassthrough() async throws {
        let mock = MockInference(contextWindow: 4096, fixed: "hello")
        let window = await mock.contextWindow
        XCTAssertEqual(window, 4096)
        let output = try await mock.generate(InferenceRequest(system: "s", user: "u"))
        XCTAssertEqual(output, "hello")
    }
}
