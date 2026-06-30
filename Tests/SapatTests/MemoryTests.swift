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

    func testVDSPCosineMatchesScalarAndNormalizedDot() {
        let a = (0..<512).map { Float(sin(Double($0) * 0.1)) }
        let b = (0..<512).map { Float(cos(Double($0) * 0.07)) }
        func scalarCosine(_ x: [Float], _ y: [Float]) -> Float {
            var d: Float = 0, nx: Float = 0, ny: Float = 0
            for i in 0..<x.count { d += x[i] * y[i]; nx += x[i] * x[i]; ny += y[i] * y[i] }
            let den = nx.squareRoot() * ny.squareRoot()
            return den == 0 ? 0 : d / den
        }
        XCTAssertEqual(VectorMath.cosine(a, b), scalarCosine(a, b), accuracy: 1e-4)
        // cosine on L2-normalized vectors collapses to a dot product (the cached-search path).
        let dot = VectorMath.dot(VectorMath.l2Normalized(a), VectorMath.l2Normalized(b))
        XCTAssertEqual(dot, VectorMath.cosine(a, b), accuracy: 1e-4)
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

    func testSearchReflectsIndexAndRemoveAfterCacheBuilt() async {
        let store = makeStore()
        await store.index(id: "1", date: Date(timeIntervalSince1970: 1), serbian: "",
                          artifact: "distributed tracing across microservices", intent: "", mode: "m")
        _ = await store.search(query: "distributed tracing", limit: 3) // builds the embedding cache
        await store.index(id: "2", date: Date(timeIntervalSince1970: 2), serbian: "",
                          artifact: "kubernetes pod autoscaling policy", intent: "", mode: "m")
        let added = await store.search(query: "kubernetes autoscaling", limit: 3)
        XCTAssertEqual(added.first?.id, "2", "a row indexed after the cache was built is searchable")
        await store.remove(id: "2")
        let removed = await store.search(query: "kubernetes autoscaling", limit: 3)
        XCTAssertFalse(removed.contains { $0.id == "2" }, "a removed row drops out of results")
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
