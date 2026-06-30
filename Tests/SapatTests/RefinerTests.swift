import XCTest
@testable import Sapat

/// The backend-neutral refinement orchestration. It must do a single pass when the transcript
/// fits, chunk + merge when it doesn't (so a long recording's start is never dropped), apply
/// the mechanical sanitizer to each reply, and surface an empty result as an error.
final class RefinerTests: XCTestCase {
    func testSinglePassWhenItFits() async throws {
        // A code-fenced reply proves the sanitizer runs on the way out.
        let mock = MockInference(contextWindow: 8192, fixed: "```\nThe queue ships now.\n```")
        let refiner = Refiner(inference: mock)
        let result = try await refiner.refine("Treba da pošaljemo red.", tone: .technical)
        XCTAssertEqual(result, "The queue ships now.")
        XCTAssertEqual(mock.generateCallCount, 1, "a short transcript refines in one pass")

        // The refine request is low-temperature and sized (maxTokens set).
        let first = mock.requests.first
        XCTAssertEqual(first?.temperature, 0.2)
        XCTAssertNotNil(first?.maxTokens)
    }

    func testChunksAndMergesLongTranscript() async throws {
        // Echo the user content so nothing is fabricated; a small context forces chunking.
        let mock = MockInference(contextWindow: 2048) { request, _ in
            request.messages.last?.content ?? ""
        }
        let refiner = Refiner(inference: mock)
        let sentence = "Ovo je rečenica broj koja opisuje sistem i njegovo ponašanje. "
        let transcript = String(repeating: sentence, count: 60) // ~3.6k chars → several chunks
        let result = try await refiner.refine(transcript, tone: .technical)
        XCTAssertFalse(result.isEmpty)
        XCTAssertGreaterThan(mock.generateCallCount, 1, "a long transcript is split into multiple calls")
    }

    func testEmptyOutputThrows() async {
        let mock = MockInference(fixed: "   ") // sanitizes to empty
        let refiner = Refiner(inference: mock)
        do {
            _ = try await refiner.refine("nešto", tone: .technical)
            XCTFail("expected an empty-output error")
        } catch let error as InferenceError {
            XCTAssertEqual(error, .emptyOutput)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }
}
