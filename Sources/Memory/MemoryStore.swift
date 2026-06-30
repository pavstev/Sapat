import Foundation
import GRDB

/// Local, on-device semantic memory of past transcripts / artifacts. SQLite via GRDB with an
/// FTS5 keyword index plus a stored embedding per row; search fuses the two rankings with
/// Reciprocal Rank Fusion (§5.3 v1). It sits alongside the JSON `HistoryStore` (which stays
/// the durable record of truth, preserving the failed-entry retry guarantee) and serves two
/// jobs: retrieval for the pipeline's Retrieve stage, and a searchable knowledge base.
///
/// An `actor` so all DB access is serialized off the main actor.
actor MemoryStore {
    /// Process-wide store at the canonical on-disk location.
    static let shared = MemoryStore()

    struct Hit: Sendable, Equatable {
        let id: String
        let serbian: String
        let artifact: String
        let intent: String
        let mode: String
        let date: Date
        let score: Double
    }

    private let dbQueue: DatabaseQueue?

    /// L2-normalized embeddings cached in-actor so vector search skips the per-query BLOB scan +
    /// decode and collapses cosine to a single dot product. Built lazily on the first vector
    /// search; kept coherent by `index`/`remove`. `nil` until first built (so the launch backfill
    /// doesn't rebuild it per row).
    private var normalizedCache: [(id: String, vector: [Float])]?

    /// `path` is injectable for tests; defaults to `Brand.memoryDatabaseURL()`.
    init(path: URL? = nil) {
        let url = path ?? (try? Brand.memoryDatabaseURL())
        guard let url else { dbQueue = nil; return }
        let queue = try? DatabaseQueue(path: url.path)
        dbQueue = queue
        try? queue?.write { db in try Self.createSchema(db) }
    }

    private static func createSchema(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS memories (
              id TEXT PRIMARY KEY,
              date DOUBLE NOT NULL,
              serbian TEXT NOT NULL DEFAULT '',
              artifact TEXT NOT NULL DEFAULT '',
              intent TEXT NOT NULL DEFAULT '',
              mode TEXT NOT NULL DEFAULT '',
              embedding BLOB
            );
            """)
        // Standalone FTS5 index with an UNINDEXED id column mapping back to `memories`.
        try db.execute(sql: """
            CREATE VIRTUAL TABLE IF NOT EXISTS memories_fts
            USING fts5(mem_id UNINDEXED, text, tokenize = 'unicode61 remove_diacritics 2');
            """)
    }

    // MARK: - Indexing

    /// Insert or update one memory. The embedding is computed here from the most meaningful
    /// text (intent + artifact + transcript); a nil embedding means FTS-only (e.g. Serbian).
    func index(id: String, date: Date, serbian: String, artifact: String, intent: String, mode: String) {
        guard let dbQueue else { return }
        let embeddingSource = [intent, artifact, serbian].first { !$0.isEmpty } ?? ""
        let floats = Embedder.embed(embeddingSource)
        let embedding = floats.map { VectorMath.data($0) }
        let ftsText = [intent, artifact, serbian].filter { !$0.isEmpty }.joined(separator: " \n ")
        try? dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO memories (id, date, serbian, artifact, intent, mode, embedding)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                  date = excluded.date, serbian = excluded.serbian, artifact = excluded.artifact,
                  intent = excluded.intent, mode = excluded.mode, embedding = excluded.embedding;
                """, arguments: [id, date.timeIntervalSince1970, serbian, artifact, intent, mode, embedding])
            try db.execute(sql: "DELETE FROM memories_fts WHERE mem_id = ?", arguments: [id])
            try db.execute(sql: "INSERT INTO memories_fts (mem_id, text) VALUES (?, ?)", arguments: [id, ftsText])
        }
        // Keep the normalized-embedding cache coherent (only once it has been built).
        if normalizedCache != nil {
            normalizedCache?.removeAll { $0.id == id }
            if let floats { normalizedCache?.append((id, VectorMath.l2Normalized(floats))) }
        }
    }

    func remove(id: String) {
        try? dbQueue?.write { db in
            try db.execute(sql: "DELETE FROM memories WHERE id = ?", arguments: [id])
            try db.execute(sql: "DELETE FROM memories_fts WHERE mem_id = ?", arguments: [id])
        }
        normalizedCache?.removeAll { $0.id == id }
    }

    /// Lazily-built, in-actor cache of L2-normalized embeddings for vector search.
    private func normalizedEmbeddings() -> [(id: String, vector: [Float])] {
        if let normalizedCache { return normalizedCache }
        guard let dbQueue else { return [] }
        let rows = (try? dbQueue.read { db in
            try Row.fetchAll(db, sql: "SELECT id, embedding FROM memories WHERE embedding IS NOT NULL;")
        }) ?? []
        let built: [(id: String, vector: [Float])] = rows.compactMap { row in
            guard let id: String = row["id"], let data: Data = row["embedding"] else { return nil }
            return (id, VectorMath.l2Normalized(VectorMath.vector(data)))
        }
        normalizedCache = built
        return built
    }

    /// One-time backfill: index any records not already present (keeps JSON as the source of
    /// truth while seeding the semantic index). Cheap and idempotent.
    func backfill(_ records: [(id: String, date: Date, serbian: String, artifact: String, mode: String)]) {
        guard let dbQueue else { return }
        let existing = (try? dbQueue.read { db in try String.fetchSet(db, sql: "SELECT id FROM memories") }) ?? []
        for r in records where !existing.contains(r.id) {
            index(id: r.id, date: r.date, serbian: r.serbian, artifact: r.artifact, intent: "", mode: r.mode)
        }
    }

    func count() -> Int {
        guard let dbQueue else { return 0 }
        return (try? dbQueue.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM memories") ?? 0 }) ?? 0
    }

    // MARK: - Hybrid search (FTS5 + vector, fused with RRF)

    func search(query: String, excluding excludedID: String? = nil, limit: Int = 3) -> [Hit] {
        guard let dbQueue else { return [] }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        // 1. Keyword ranking via FTS5.
        var keywordIDs: [String] = []
        if let match = Self.ftsMatch(from: trimmed) {
            keywordIDs = (try? dbQueue.read { db in
                try String.fetchAll(db, sql: """
                    SELECT mem_id FROM memories_fts WHERE memories_fts MATCH ? ORDER BY rank LIMIT 20;
                    """, arguments: [match])
            }) ?? []
        }

        // 2. Vector ranking over the cached, L2-normalized embeddings — cosine collapses to a
        //    single dot product per row (no per-query BLOB scan + decode).
        var vectorIDs: [String] = []
        if let queryEmbedding = Embedder.embed(trimmed) {
            let query = VectorMath.l2Normalized(queryEmbedding)
            let scored: [(String, Float)] = normalizedEmbeddings().compactMap { entry in
                guard entry.vector.count == query.count else { return nil }
                return (entry.id, VectorMath.dot(query, entry.vector))
            }
            vectorIDs = scored.sorted { $0.1 > $1.1 }.prefix(20).map(\.0)
        }

        // 3. Fuse + fetch.
        var fused = VectorMath.reciprocalRankFusion([keywordIDs, vectorIDs])
        if let excludedID { fused.removeAll { $0.id == excludedID } }
        let topIDs = Array(fused.prefix(limit).map(\.id))
        guard !topIDs.isEmpty else { return [] }
        return fetchHits(ids: topIDs, scores: Dictionary(uniqueKeysWithValues: fused.map { ($0.id, $0.score) }))
    }

    private func fetchHits(ids: [String], scores: [String: Double]) -> [Hit] {
        guard let dbQueue, !ids.isEmpty else { return [] }
        let placeholders = databaseQuestionMarks(count: ids.count)
        let rows = (try? dbQueue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT id, date, serbian, artifact, intent, mode FROM memories WHERE id IN (\(placeholders));
                """, arguments: StatementArguments(ids))
        }) ?? []
        let hits = rows.compactMap { row -> Hit? in
            guard let id: String = row["id"] else { return nil }
            return Hit(
                id: id,
                serbian: row["serbian"] ?? "",
                artifact: row["artifact"] ?? "",
                intent: row["intent"] ?? "",
                mode: row["mode"] ?? "",
                date: Date(timeIntervalSince1970: row["date"] ?? 0),
                score: scores[id] ?? 0)
        }
        // Preserve fused order.
        return ids.compactMap { id in hits.first { $0.id == id } }
    }

    /// Builds a safe FTS5 MATCH expression: alphanumeric tokens of length ≥ 3, each quoted,
    /// OR-joined. Quoting avoids FTS5 syntax errors on punctuation/operators in user text.
    static func ftsMatch(from query: String) -> String? {
        let tokens = query
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 3 }
            .prefix(12)
        guard !tokens.isEmpty else { return nil }
        return tokens.map { "\"\($0)\"" }.joined(separator: " OR ")
    }
}

private func databaseQuestionMarks(count: Int) -> String {
    Array(repeating: "?", count: count).joined(separator: ", ")
}
