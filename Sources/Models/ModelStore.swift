import CryptoKit
import Foundation

/// Self-managed, update-surviving model cache.
///
/// Models are stored under `~/Library/Application Support/Sapat/Models` — **outside** the
/// app bundle — so the in-place updater (which swaps `Sapat.app`) never deletes them and a
/// multi-GB weight set is fetched once and reused across every future release. Downloads are
/// **resumable** (HTTP `Range`), **integrity-checked** (SHA-256 when a digest is known, else
/// size), and **never re-fetched** once a file is present and valid — the same "download only
/// if genuinely absent" guarantee the old LM Studio path had, now owned by the app itself.
///
/// An `actor` so download bookkeeping and file I/O stay off the main actor.
actor ModelStore {
    /// A file to fetch as part of a model.
    struct RemoteFile: Sendable, Equatable {
        let url: URL
        /// Path relative to the model's folder (e.g. `"config.json"` or `"weights/model.safetensors"`).
        let relativePath: String
        /// Lowercase hex SHA-256, when known. The strongest integrity signal.
        var sha256: String?
        /// Expected byte size, when known. Used for completeness when no digest is available.
        var expectedSize: Int64?
    }

    /// A model = an id (its folder name) and the files that compose it.
    struct ManagedModel: Sendable, Equatable {
        /// Folder name under the models root, e.g. `"Qwen3-4B-4bit"`.
        let id: String
        let files: [RemoteFile]
    }

    enum StoreError: LocalizedError, Equatable {
        case integrityFailed(String)
        case httpStatus(Int)
        case offline

        var errorDescription: String? {
            switch self {
            case .integrityFailed(let file): return "A downloaded model file failed its integrity check: \(file)."
            case .httpStatus(let code): return "The model download server returned HTTP \(code)."
            case .offline: return "Couldn't reach the model download server."
            }
        }
    }

    private let root: URL

    /// Defaults to `Brand.modelsDirectory()`; injectable for tests.
    init(root: URL? = nil) {
        self.root = root ?? ((try? Brand.modelsDirectory()) ?? FileManager.default.temporaryDirectory)
    }

    /// The on-disk folder for a model (created on demand).
    func folder(for model: ManagedModel) -> URL {
        let url = root.appendingPathComponent(model.id, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// True when every file of `model` is present and passes its integrity check — i.e. a
    /// fully usable, offline-ready model. Cheap; does not touch the network.
    func isInstalled(_ model: ManagedModel) -> Bool {
        let dir = root.appendingPathComponent(model.id, isDirectory: true)
        return model.files.allSatisfy { file in
            Self.isValid(at: dir.appendingPathComponent(file.relativePath), sha256: file.sha256, expectedSize: file.expectedSize)
        }
    }

    /// Ensures `model` is fully present, downloading any missing/invalid files with resume.
    /// Returns the model's folder. Already-valid files are skipped entirely (never re-fetched).
    /// `onProgress` reports an overall 0…1 fraction across the model's files.
    @discardableResult
    func install(_ model: ManagedModel, onProgress: (@Sendable (Double) -> Void)? = nil) async throws -> URL {
        let dir = folder(for: model)
        let knownTotal = model.files.compactMap(\.expectedSize).reduce(0, +)
        let count = model.files.count
        // If every file declares a size we can report a true overall fraction; otherwise we
        // fall back to per-file fractions averaged.
        let useByteProgress = model.files.allSatisfy { $0.expectedSize != nil } && knownTotal > 0
        var completedBytes: Int64 = 0

        for (index, file) in model.files.enumerated() {
            let dest = dir.appendingPathComponent(file.relativePath)
            if Self.isValid(at: dest, sha256: file.sha256, expectedSize: file.expectedSize) {
                completedBytes += file.expectedSize ?? 0
                onProgress?(useByteProgress ? Double(completedBytes) / Double(knownTotal)
                                            : Double(index + 1) / Double(count))
                continue
            }
            // Immutable snapshots for the @Sendable progress closure.
            let base = completedBytes
            try await download(file, to: dest) { fileBytesSoFar, fileFraction in
                guard let onProgress else { return }
                onProgress(useByteProgress ? Double(base + fileBytesSoFar) / Double(knownTotal)
                                           : (Double(index) + fileFraction) / Double(count))
            }
            guard Self.isValid(at: dest, sha256: file.sha256, expectedSize: file.expectedSize) else {
                throw StoreError.integrityFailed(file.relativePath)
            }
            completedBytes += file.expectedSize ?? 0
        }
        onProgress?(1)
        return dir
    }

    // MARK: - Download (resumable)

    /// Downloads `file` to `dest`, resuming from a partial `.part` when present. Writes to the
    /// `.part` and atomically moves it into place on success. `onProgress` receives
    /// (bytesWrittenThisFile, fraction-of-this-file).
    private func download(_ file: RemoteFile, to dest: URL, onProgress: @Sendable (Int64, Double) -> Void) async throws {
        let fm = FileManager.default
        try? fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        let part = dest.appendingPathExtension("part")

        var existing: Int64 = Self.fileSize(part) ?? 0
        var request = URLRequest(url: file.url)
        request.timeoutInterval = 60
        if existing > 0 { request.setValue("bytes=\(existing)-", forHTTPHeaderField: "Range") }

        let (bytes, response): (URLSession.AsyncBytes, URLResponse)
        do {
            (bytes, response) = try await URLSession.shared.bytes(for: request)
        } catch {
            throw StoreError.offline
        }
        guard let http = response as? HTTPURLResponse else { throw StoreError.offline }

        // 206 = resuming; 200 = server ignored Range (or fresh) → start over.
        if http.statusCode == 200, existing > 0 {
            try? fm.removeItem(at: part)
            existing = 0
        } else if !(http.statusCode == 200 || http.statusCode == 206) {
            throw StoreError.httpStatus(http.statusCode)
        }

        if !fm.fileExists(atPath: part.path) { fm.createFile(atPath: part.path, contents: nil) }
        let handle = try FileHandle(forWritingTo: part)
        defer { try? handle.close() }
        try handle.seekToEnd()

        let declaredTotal = file.expectedSize ?? (existing + max(0, response.expectedContentLength))
        var written = existing
        var buffer = Data()
        buffer.reserveCapacity(1 << 20)

        for try await byte in bytes {
            buffer.append(byte)
            if buffer.count >= (1 << 20) { // flush every ~1 MB
                try handle.write(contentsOf: buffer)
                written += Int64(buffer.count)
                buffer.removeAll(keepingCapacity: true)
                onProgress(written, declaredTotal > 0 ? Double(written) / Double(declaredTotal) : 0)
                if Task.isCancelled { return } // leave the .part for a later resume
            }
        }
        if !buffer.isEmpty {
            try handle.write(contentsOf: buffer)
            written += Int64(buffer.count)
        }
        try handle.close()
        try? fm.removeItem(at: dest)
        try fm.moveItem(at: part, to: dest)
        onProgress(written, 1)
    }

    // MARK: - Pure helpers (unit-tested)

    /// A file is valid when it exists and matches its SHA-256 (preferred) or its expected size.
    /// With neither provided, mere existence counts (best effort).
    static func isValid(at url: URL, sha256: String?, expectedSize: Int64?) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        if let sha256 {
            return self.sha256(of: url)?.caseInsensitiveCompare(sha256) == .orderedSame
        }
        if let expectedSize {
            return fileSize(url) == expectedSize
        }
        return true
    }

    /// Streaming SHA-256 of a file (nil if unreadable), so a multi-GB file isn't loaded whole.
    static func sha256(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func fileSize(_ url: URL) -> Int64? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? Int64
    }
}
