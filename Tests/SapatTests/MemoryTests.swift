import XCTest
@testable import Sapat

/// Vector math helpers underpinning hybrid retrieval.
final class VectorMathTests: XCTestCase {
    func testCosine() {
        XCTAssertEqual(VectorMath.cosine([1, 0, 0], [1, 0, 0]), 1, accuracy: 1e-6)
        XCTAssertEqual(VectorMath.cosine([1, 0], [0, 1]), 0, accuracy: 1e-6)
        XCTAssertEqual(VectorMath.cosine([1, 0], [-1, 0]), -1, accuracy: 1e-6)
        XCTAssertEqual(VectorMath.cosine([], []), 0)
    }

    func testEmbeddingBlobRoundTrip() {
        let vector: [Float] = [0.1, -0.2, 3.5, 42, -0.0001]
        let restored = VectorMath.vector(VectorMath.data(vector))
        XCTAssertEqual(restored.count, vector.count)
        for (a, b) in zip(vector, restored) { XCTAssertEqual(a, b, accuracy: 1e-6) }
    }

    func testReciprocalRankFusion() {
        // "b" appears high in both lists → should win.
        let fused = VectorMath.reciprocalRankFusion([["a", "b", "c"], ["b", "d"]])
        XCTAssertEqual(fused.first?.id, "b")
        let ids = fused.map(\.id)
        XCTAssertTrue(ids.contains("a") && ids.contains("d"))
    }

    func testFTSMatchSanitizesTokens() {
        XCTAssertEqual(MemoryStore.ftsMatch(from: "retry queue!"), "\"retry\" OR \"queue\"")
        XCTAssertNil(MemoryStore.ftsMatch(from: "a or b"))  // all tokens < 3 chars
    }
}

/// The GRDB-backed semantic memory store: indexing, keyword retrieval, removal, idempotent
/// backfill. Uses a throwaway on-disk database.
final class MemoryStoreTests: XCTestCase {
    private var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("memory-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    private func makeStore() -> MemoryStore {
        MemoryStore(path: tmp.appendingPathComponent("mem-\(UUID().uuidString).sqlite"))
    }

    func testIndexAndKeywordSearch() async {
        let store = makeStore()
        await store.index(id: "1", date: Date(timeIntervalSince1970: 1), serbian: "",
                          artifact: "Refactor the retry queue to be idempotent", intent: "make retries safe", mode: "engineering-report")
        await store.index(id: "2", date: Date(timeIntervalSince1970: 2), serbian: "",
                          artifact: "The login page needs a dark mode toggle", intent: "add dark mode", mode: "polished-english")
        let count = await store.count()
        XCTAssertEqual(count, 2)
        let hits = await store.search(query: "retry queue idempotent", limit: 3)
        XCTAssertEqual(hits.first?.id, "1", "the most relevant record ranks first")
    }

    func testRemove() async {
        let store = makeStore()
        await store.index(id: "1", date: Date(), serbian: "", artifact: "something about caching", intent: "", mode: "x")
        await store.remove(id: "1")
        let count = await store.count()
        XCTAssertEqual(count, 0)
        let hits = await store.search(query: "caching", limit: 3)
        XCTAssertTrue(hits.isEmpty)
    }

    func testBackfillIsIdempotent() async {
        let store = makeStore()
        let rows = [
            (id: "a", date: Date(timeIntervalSince1970: 1), serbian: "", artifact: "alpha note", mode: "m"),
            (id: "b", date: Date(timeIntervalSince1970: 2), serbian: "", artifact: "beta note", mode: "m"),
        ]
        await store.backfill(rows)
        await store.backfill(rows) // again
        let count = await store.count()
        XCTAssertEqual(count, 2, "backfill must not duplicate existing rows")
    }
}
