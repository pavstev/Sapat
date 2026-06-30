import XCTest
@testable import Sapat

/// An `Inference` whose `stream` splits a fixed reply into N deltas — to exercise streaming
/// aggregation. (The plain `MockInference` uses the protocol's one-delta default `stream`.)
final class SplittingInference: Inference, @unchecked Sendable {
    let reply: String
    let parts: Int
    let context: Int
    let source: TranslationSource = .mlx

    init(reply: String, parts: Int = 3, context: Int = 8192) {
        self.reply = reply
        self.parts = parts
        self.context = context
    }

    func prepare(onStatus: @escaping @Sendable (String?) -> Void) async throws {}
    func generate(_ request: InferenceRequest) async throws -> String { reply }
    var contextWindow: Int { get async { context } }

    func stream(_ request: InferenceRequest) -> AsyncThrowingStream<String, Error> {
        let chunks = Self.split(reply, into: parts)
        return AsyncThrowingStream { continuation in
            for chunk in chunks { continuation.yield(chunk) }
            continuation.finish()
        }
    }

    static func split(_ s: String, into n: Int) -> [String] {
        let chars = Array(s)
        guard n > 1, chars.count >= n else { return [s] }
        let size = (chars.count + n - 1) / n
        return stride(from: 0, to: chars.count, by: size).map { String(chars[$0..<min($0 + size, chars.count)]) }
    }
}

/// Thread-safe delta collector — `onDelta` is `@Sendable`, so a captured `var` can't be mutated.
private final class DeltaCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var _text = ""
    private var _count = 0
    func add(_ delta: String) { lock.withLock { _text += delta; _count += 1 } }
    var text: String { lock.withLock { _text } }
    var count: Int { lock.withLock { _count } }
}

/// Streaming generation: the default wrapper, the Refiner streaming path (byte-identical to the
/// non-streaming path), and the pipeline streaming only the final user-visible stage.
final class StreamingTests: XCTestCase {
    func testDefaultStreamEmitsWholeReplyAsOneDelta() async throws {
        let mock = MockInference(fixed: "hello world")
        var deltas: [String] = []
        for try await delta in mock.stream(InferenceRequest(system: "s", user: "u")) { deltas.append(delta) }
        XCTAssertEqual(deltas, ["hello world"], "the default stream emits generate()'s whole reply as one delta")
    }

    func testRefineStreamingMatchesRefineAndStreamsRawDeltas() async throws {
        let reply = "```\nThe queue ships now.\n```" // sanitizes to "The queue ships now."
        let refiner = Refiner(inference: SplittingInference(reply: reply, parts: 4))
        let collector = DeltaCollector()
        let result = try await refiner.refineStreaming(
            "kratak transkript", language: .english, register: Tone.technical.instruction,
            onDelta: { collector.add($0) })

        XCTAssertEqual(result, "The queue ships now.", "the committed result is sanitize(complete)")
        XCTAssertEqual(collector.text, reply, "raw deltas concatenate to the model's reply")
        XCTAssertGreaterThan(collector.count, 1, "the reply actually arrived in pieces")

        let nonStreaming = try await Refiner(inference: SplittingInference(reply: reply)).refine("kratak transkript", tone: .technical)
        XCTAssertEqual(result, nonStreaming, "streaming yields the same sanitized output as non-streaming")
    }

    func testRefineStreamingFallsBackForLongTranscriptWithoutDeltas() async throws {
        // A tiny context forces chunk/merge → the non-streaming path; onDelta must never fire.
        let refiner = Refiner(inference: SplittingInference(reply: "merged section.", parts: 3, context: 2048))
        let transcript = String(repeating: "Ovo je rečenica koja opisuje sistem. ", count: 60)
        let collector = DeltaCollector()
        let result = try await refiner.refineStreaming(
            transcript, language: .english, register: Tone.technical.instruction,
            onDelta: { collector.add($0) })
        XCTAssertFalse(result.isEmpty)
        XCTAssertEqual(collector.count, 0, "the chunk/merge fallback does not stream (whole-recording guarantee)")
    }

    func testPipelineStreamsPureRefineCleanStage() async throws {
        let reply = "The application has slow startup."
        let collector = DeltaCollector()
        let streamed = try await ThoughtPipeline(inference: SplittingInference(reply: reply, parts: 3))
            .run(transcript: "x", mode: OutputModes.polishedEnglish, onDelta: { collector.add($0) })
        let plain = try await ThoughtPipeline(inference: SplittingInference(reply: reply))
            .run(transcript: "x", mode: OutputModes.polishedEnglish)
        XCTAssertEqual(streamed.primary, plain.primary)
        XCTAssertEqual(collector.text, reply, "pure-refine streams the clean stage")
    }

    func testPipelineStreamsOnlyFinalStageForSynthesisMode() async throws {
        let extractionJSON = """
        {"intent":"ship it","topics":["infra"],"decisions":[],"open_questions":[],\
        "action_items":[],"entities":[],"uncertainties":[]}
        """
        func makeMock() -> MockInference {
            MockInference(contextWindow: 8192) { request, _ in
                let system = request.messages.first { $0.role == .system }?.content ?? ""
                return system.contains("thought_extraction") ? extractionJSON : "Drafted artifact."
            }
        }
        let collector = DeltaCollector()
        let streamed = try await ThoughtPipeline(inference: makeMock())
            .run(transcript: "x", mode: OutputModes.structuredBrief, onDelta: { collector.add($0) })
        let plain = try await ThoughtPipeline(inference: makeMock())
            .run(transcript: "x", mode: OutputModes.structuredBrief)
        XCTAssertEqual(streamed.primary, plain.primary)
        // Only synthesize streamed (clean uses refine→generate; extract uses generate); the
        // default one-delta stream yields the synthesize output exactly once.
        XCTAssertEqual(collector.text, "Drafted artifact.")
    }
}
