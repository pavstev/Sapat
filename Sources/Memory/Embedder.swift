import Accelerate
import Foundation
import NaturalLanguage

/// On-device text embeddings via Apple's NaturalLanguage framework — no download, no network,
/// no macros (a system framework, so it builds under the CLT). v1 embeds English text with the
/// classic 512-dim sentence embedding; this is the strong path for the English artifacts the
/// pipeline produces. Serbian-only content has no sentence-embedding model in the classic API,
/// so it relies on FTS5 keyword search instead (a v2 upgrade can add `NLContextualEmbedding`).
enum Embedder {
    /// English sentence-embedding dimension.
    static let dimension = 512

    /// A 512-dim English embedding for `text`, or nil when unavailable (empty text, or no model
    /// on this OS). Callers store nil embeddings as "FTS-only" rows.
    static func embed(_ text: String) -> [Float]? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let model = NLEmbedding.sentenceEmbedding(for: .english) else { return nil }
        guard let vector = model.vector(for: trimmed) else { return nil }
        return vector.map { Float($0) }
    }
}

/// Small vector helpers: cosine similarity (brute force is ample at personal scale), the
/// blob (de)serialization for storing embeddings in SQLite, and Reciprocal Rank Fusion for
/// combining the keyword and vector rankings into one hybrid result.
enum VectorMath {
    /// Cosine similarity, via Accelerate (vDSP) — dot / (‖a‖·‖b‖).
    static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        let n = vDSP_Length(a.count)
        var dotValue: Float = 0, sumSqA: Float = 0, sumSqB: Float = 0
        vDSP_dotpr(a, 1, b, 1, &dotValue, n)
        vDSP_svesq(a, 1, &sumSqA, n)
        vDSP_svesq(b, 1, &sumSqB, n)
        let denom = sumSqA.squareRoot() * sumSqB.squareRoot()
        return denom == 0 ? 0 : dotValue / denom
    }

    /// L2-normalized copy (‖v‖ == 1), so a later cosine collapses to a single dot product.
    static func l2Normalized(_ v: [Float]) -> [Float] {
        guard !v.isEmpty else { return v }
        let n = vDSP_Length(v.count)
        var sumSq: Float = 0
        vDSP_svesq(v, 1, &sumSq, n)
        var norm = sumSq.squareRoot()
        guard norm > 0 else { return v }
        var out = [Float](repeating: 0, count: v.count)
        vDSP_vsdiv(v, 1, &norm, &out, 1, n)
        return out
    }

    /// Plain dot product — cosine for already-L2-normalized vectors (the cached-search hot path).
    static func dot(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var value: Float = 0
        vDSP_dotpr(a, 1, b, 1, &value, vDSP_Length(a.count))
        return value
    }

    static func data(_ vector: [Float]) -> Data {
        vector.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    static func vector(_ data: Data) -> [Float] {
        let count = data.count / MemoryLayout<Float>.stride
        guard count > 0 else { return [] }
        var result = [Float](repeating: 0, count: count)
        _ = result.withUnsafeMutableBytes { data.copyBytes(to: $0) }
        return result
    }

    /// Reciprocal Rank Fusion: fuse several ranked id lists (best-first) into one score per id.
    /// `k` damps the contribution of lower ranks (60 is the conventional default).
    static func reciprocalRankFusion(_ rankings: [[String]], k: Double = 60) -> [(id: String, score: Double)] {
        var scores: [String: Double] = [:]
        for ranking in rankings {
            for (index, id) in ranking.enumerated() {
                scores[id, default: 0] += 1.0 / (k + Double(index + 1))
            }
        }
        return scores.sorted { $0.value > $1.value }.map { (id: $0.key, score: $0.value) }
    }
}
