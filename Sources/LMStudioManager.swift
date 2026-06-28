import Foundation

/// Makes LM Studio mandatory by driving its `lms` CLI: locate the tool, start the local
/// server, install the MLX runtime, and make sure the configured model is downloaded and
/// loaded — then it's reused, never re-fetched. When it genuinely can't be made ready,
/// `ensureReady` throws and the caller shows an actionable error (no silent fallback to the
/// inferior Whisper path).
///
/// The download is resume-and-retry: `lms get` reports real progress and resumes a partial
/// `.part`, but its HuggingFace transfer can time out near the end — so we retry it (each
/// attempt resumes) until the model is actually present, rather than re-pulling from zero
/// or giving up. Progress is streamed out as ready-to-display strings (throttled).
struct LMStudioManager {
    /// Context window to request when we load the model ourselves — generous headroom so
    /// most recordings refine in a single pass. (The client still chunks if a transcript
    /// exceeds whatever is actually loaded, e.g. a smaller manual load.)
    var preferredContextLength = 8192
    /// Auto-unload the model after this long idle, so we don't hold ~6 GB forever.
    var modelIdleTTLSeconds = 3600

    /// `lms get` can stall and exit near the end; each retry resumes the `.part`.
    private static let maxDownloadAttempts = 10
    /// How often a streamed progress line is forwarded to the UI (real `lms` output updates
    /// many times a second; this keeps it from flooding the main actor).
    private static let progressThrottle: TimeInterval = 0.25

    /// Operation timeouts (seconds). Grouped so they're easy to find and tune.
    private enum Timeouts {
        static let serverStart: TimeInterval = 30
        static let serverReady: TimeInterval = 20
        static let runtimeInstall: TimeInterval = 1200
        static let runtimeQuery: TimeInterval = 30
        static let modelDownload: TimeInterval = 7200
        static let modelLoad: TimeInterval = 600
        static let modelLoadedWait: TimeInterval = 60
    }

    /// Poll / backoff intervals (nanoseconds).
    private enum Delays {
        static let processPoll: UInt64 = 200_000_000
        static let conditionPoll: UInt64 = 500_000_000
        static let presenceRetry: UInt64 = 1_000_000_000
        static let downloadBackoff: UInt64 = 1_500_000_000
    }

    /// Locates the `lms` CLI. A Finder-launched app inherits a minimal PATH that excludes
    /// `~/.lmstudio/bin` (where the installer puts it), so we probe explicit locations.
    static func locateCLI(
        home: String = NSHomeDirectory(),
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> String? {
        let candidates = [
            "\(home)/.lmstudio/bin/lms",
            "\(home)/.cache/lm-studio/bin/lms",
            "/opt/homebrew/bin/lms",
            "/usr/local/bin/lms",
        ]
        return candidates.first(where: isExecutable)
    }

    // MARK: - Readiness

    /// Ensures `modelKey` is loaded and serving: starts the server if needed, downloads the
    /// model if (and only if) it's genuinely absent, then loads it. Idempotent and cheap
    /// when already loaded or downloaded. `onStatus` receives display-ready progress strings.
    func ensureReady(
        modelKey: String,
        client: LMStudioClient,
        onStatus: @escaping @Sendable (String) -> Void
    ) async throws {
        if await client.presence(of: modelKey) == .loaded { return }

        guard let cli = Self.locateCLI() else { throw LMStudioError.cliNotFound }

        if await client.isServerReachable() == false {
            onStatus("Starting LM Studio…")
            try await Self.runChecked(cli, ["server", "start"], timeout: Timeouts.serverStart)
            await Self.waitUntil(timeout: Timeouts.serverReady) { await client.isServerReachable() }
        }

        // An MLX model can't load without the MLX runtime — and a fresh LM Studio has none,
        // so loading would fail with "No LM Runtime found". Make sure it's present first.
        try await ensureRuntime(cli: cli, onStatus: onStatus)

        // Resolve presence robustly — a transient query failure must NOT be read as "absent"
        // and trigger a needless multi-GB download.
        switch await stablePresence(of: modelKey, client: client) {
        case .loaded:
            return
        case .downloadedNotLoaded:
            try await loadModel(cli: cli, modelKey: modelKey, onStatus: onStatus)
        case .absent:
            try await downloadModel(cli: cli, modelKey: modelKey, client: client, onStatus: onStatus)
            try await loadModel(cli: cli, modelKey: modelKey, onStatus: onStatus)
        case .serverUnreachable:
            throw LMStudioError.notRunning
        }

        await Self.waitUntil(timeout: Timeouts.modelLoadedWait) { await client.presence(of: modelKey) == .loaded }
        guard await client.presence(of: modelKey) == .loaded else {
            throw LMStudioError.setupFailed("LM Studio couldn't load \(modelKey). Open LM Studio and load it manually, then Retry.")
        }
    }

    /// Presence, retried a few times so a momentary `/api/v0/models` hiccup (common while the
    /// server is busy downloading) doesn't masquerade as `.absent`.
    private func stablePresence(of modelKey: String, client: LMStudioClient) async -> LMStudioClient.ModelPresence {
        var last: LMStudioClient.ModelPresence = .serverUnreachable
        for attempt in 0..<3 {
            last = await client.presence(of: modelKey)
            if last != .serverUnreachable { return last }
            if attempt < 2 { try? await Task.sleep(nanoseconds: Delays.presenceRetry) }
        }
        return last
    }

    // MARK: - Download (resume + retry to completion)

    private func downloadModel(
        cli: String,
        modelKey: String,
        client: LMStudioClient,
        onStatus: @escaping @Sendable (String) -> Void
    ) async throws {
        let throttle = Throttle(Self.progressThrottle)
        var attempt = 0
        while true {
            // Stop the moment it's actually present — covers "finished on a prior attempt"
            // and is the real fix for re-downloading every message.
            if await client.presence(of: modelKey) != .absent { return }
            attempt += 1
            onStatus(attempt == 1 ? "Preparing to download the refinement model…"
                                  : "Resuming download (attempt \(attempt))…")
            do {
                try await Self.runChecked(cli, ["get", modelKey, "--mlx", "-y"], timeout: Timeouts.modelDownload) { line in
                    if throttle.allow(), let status = Self.progressStatus(from: line, label: "Downloading refinement model") {
                        onStatus(status)
                    }
                }
                return // `lms get` exited cleanly → the model is downloaded
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                guard attempt < Self.maxDownloadAttempts else {
                    throw LMStudioError.setupFailed(
                        "The model download keeps timing out (\(attempt) attempts). Open LM Studio to finish it, then Retry. (\(error.localizedDescription))")
                }
                try? await Task.sleep(nanoseconds: Delays.downloadBackoff) // brief backoff, then resume
            }
        }
    }

    private func loadModel(cli: String, modelKey: String, onStatus: @escaping @Sendable (String) -> Void) async throws {
        onStatus("Loading refinement model…")
        let throttle = Throttle(Self.progressThrottle)
        try await Self.runChecked(cli, [
            "load", modelKey, "-y",
            "--context-length", String(preferredContextLength),
            "--ttl", String(modelIdleTTLSeconds),
        ], timeout: Timeouts.modelLoad) { line in
            if throttle.allow(), let status = Self.progressStatus(from: line, label: "Loading refinement model") {
                onStatus(status)
            }
        }
    }

    // MARK: - Inference runtime (an MLX model won't load without it)

    /// Ensures an MLX runtime is installed and selected. A fresh LM Studio ships with none,
    /// so `lms load` of an MLX (`safetensors`) model fails until one is downloaded + selected.
    /// Cheap no-op once a runtime is active.
    private func ensureRuntime(cli: String, onStatus: @escaping @Sendable (String) -> Void) async throws {
        if await mlxRuntimeSelected(cli: cli) { return }
        onStatus("Installing the MLX runtime…")
        let output = try await Self.capture(cli, ["runtime", "get", "mlx-llm", "-y"], timeout: Timeouts.runtimeInstall)
        // `lms runtime get` downloads but does NOT activate; it prints the select command.
        if let name = Self.parseRuntimeSelectName(from: output) {
            try? await Self.runChecked(cli, ["runtime", "select", name], timeout: Timeouts.runtimeQuery)
        }
        guard await mlxRuntimeSelected(cli: cli) else {
            throw LMStudioError.setupFailed(
                "Couldn't activate the MLX runtime. Open LM Studio, install or select an MLX runtime, then Retry.")
        }
    }

    private func mlxRuntimeSelected(cli: String) async -> Bool {
        guard let output = try? await Self.capture(cli, ["runtime", "ls"], timeout: Timeouts.runtimeQuery) else { return false }
        return Self.stripControlCharacters(output)
            .split(whereSeparator: \.isNewline)
            .contains { $0.lowercased().contains("mlx") && $0.contains("✓") }
    }

    /// `lms runtime get` prints "… lms runtime select <name>@<ver>" — pull that name out so we
    /// can activate exactly what it just downloaded.
    static func parseRuntimeSelectName(from output: String) -> String? {
        captureGroups(#"runtime select\s+(\S+)"#, in: stripControlCharacters(output)).map { $0[1] }
    }

    // MARK: - Progress parsing (pure, unit-tested)

    /// Turns an `lms` progress line — e.g. `… 91.48% | 4.23 GB / 4.62 GB | 2.70 MB/s | ETA 02:26`
    /// (with spinner + ANSI noise) — into "Downloading refinement model — 91% · 4.23 GB / 4.62 GB · ETA 02:26".
    /// Returns nil for lines without a percentage.
    static func progressStatus(from raw: String, label: String) -> String? {
        guard raw.contains("%") else { return nil }
        let clean = stripControlCharacters(raw)
        guard let pct = captureGroups(#"([0-9]+(?:\.[0-9]+)?)\s*%"#, in: clean).flatMap({ Double($0[1]) }) else {
            return nil
        }
        var parts = ["\(label) — \(Int(pct.rounded()))%"]
        if let sizes = captureGroups(#"([0-9]+(?:\.[0-9]+)?\s*[KMGT]?B)\s*/\s*([0-9]+(?:\.[0-9]+)?\s*[KMGT]?B)"#, in: clean) {
            parts.append("\(normalizeSize(sizes[1])) / \(normalizeSize(sizes[2]))")
        }
        if let eta = captureGroups(#"ETA\s*([0-9:]+)"#, in: clean) {
            parts.append("ETA \(eta[1])")
        }
        return parts.joined(separator: " · ")
    }

    private static func normalizeSize(_ s: String) -> String {
        s.replacingOccurrences(of: "  ", with: " ").trimmingCharacters(in: .whitespaces)
    }

    static func stripControlCharacters(_ s: String) -> String {
        let noANSI = s.replacingOccurrences(
            of: "\u{1B}\\[[0-9;?]*[ -/]*[@-~]", with: "", options: .regularExpression)
        let scalars = noANSI.unicodeScalars.filter { $0 == " " || $0 == "\t" || ($0.value >= 0x20 && $0.value != 0x7F) }
        return String(String.UnicodeScalarView(scalars))
    }

    private static func captureGroups(_ pattern: String, in text: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range) else { return nil }
        return (0..<match.numberOfRanges).map { index in
            Range(match.range(at: index), in: text).map { String(text[$0]) } ?? ""
        }
    }

    // MARK: - Process plumbing (nonisolated: runs off the main actor)

    /// The one subprocess runner. Streams stdout+stderr to `onLine` (when given) for live
    /// progress, always accumulating a bounded tail for diagnostics. Polls so the call is
    /// cancellable and can time out; draining via a `readabilityHandler` means a chatty
    /// command can't deadlock the pipe. Returns the exit status + captured output — callers
    /// decide whether a nonzero status is an error.
    nonisolated private static func runProcess(
        _ launchPath: String,
        _ args: [String],
        timeout: TimeInterval,
        onLine: (@Sendable (String) -> Void)? = nil
    ) async throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = args
        process.environment = augmentedEnvironment()

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        let handle = pipe.fileHandleForReading
        let collected = OutputBuffer()
        handle.readabilityHandler = { fileHandle in
            let data = fileHandle.availableData
            guard !data.isEmpty else { return }
            let text = String(decoding: data, as: UTF8.self)
            collected.append(text)
            guard let onLine else { return }
            for piece in text.split(whereSeparator: { $0 == "\r" || $0 == "\n" }) {
                let line = String(piece)
                if !line.isEmpty { onLine(line) }
            }
        }

        try process.run()
        defer { handle.readabilityHandler = nil }

        let deadline = Deadline(seconds: timeout)
        while process.isRunning {
            if Task.isCancelled { process.terminate(); process.waitUntilExit(); throw CancellationError() }
            if deadline.isExpired {
                process.terminate(); process.waitUntilExit()
                throw LMStudioError.setupFailed("lms \(args.first ?? "command") timed out.")
            }
            try? await Task.sleep(nanoseconds: Delays.processPoll)
        }
        return (process.terminationStatus, collected.text)
    }

    /// Runs `lms` and throws if it exits nonzero (used for state-changing commands).
    nonisolated private static func runChecked(
        _ launchPath: String,
        _ args: [String],
        timeout: TimeInterval,
        onLine: (@Sendable (String) -> Void)? = nil
    ) async throws {
        let result = try await runProcess(launchPath, args, timeout: timeout, onLine: onLine)
        guard result.status == 0 else {
            throw LMStudioError.setupFailed("lms \(args.first ?? "command"): \(lastMeaningfulLine(result.output))")
        }
    }

    /// Runs `lms` and returns its output regardless of exit code (used for `runtime ls`/`get`).
    nonisolated private static func capture(_ launchPath: String, _ args: [String], timeout: TimeInterval) async throws -> String {
        try await runProcess(launchPath, args, timeout: timeout).output
    }

    private static func lastMeaningfulLine(_ output: String) -> String {
        stripControlCharacters(output)
            .split(whereSeparator: { $0 == "\n" || $0 == "\r" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last(where: { !$0.isEmpty }) ?? "the command failed"
    }

    nonisolated private static func augmentedEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let extra = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        env["PATH"] = env["PATH"].map { "\($0):\(extra)" } ?? extra
        return env
    }

    /// Polls `condition` until true or the timeout elapses (best effort, no throw).
    nonisolated private static func waitUntil(timeout: TimeInterval, _ condition: @Sendable () async -> Bool) async {
        let deadline = Deadline(seconds: timeout)
        while !deadline.isExpired {
            if await condition() { return }
            try? await Task.sleep(nanoseconds: Delays.conditionPoll)
        }
    }
}

/// A timeout computed once, checked many times.
private struct Deadline {
    private let end: Date
    init(seconds: TimeInterval) { end = Date().addingTimeInterval(seconds) }
    var isExpired: Bool { Date() > end }
}

/// Rate-limits streamed progress to at most one update per `interval`. Safe to call from the
/// pipe's background reader (lock-guarded).
private final class Throttle: @unchecked Sendable {
    private let lock = NSLock()
    private let interval: TimeInterval
    private var last = Date.distantPast

    init(_ interval: TimeInterval) { self.interval = interval }

    func allow() -> Bool {
        lock.lock(); defer { lock.unlock() }
        let now = Date()
        guard now.timeIntervalSince(last) >= interval else { return false }
        last = now
        return true
    }
}

/// Thread-safe, size-bounded accumulator for a subprocess's output. The readability handler
/// runs on a background queue, so access is locked.
private final class OutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = ""

    func append(_ chunk: String) {
        lock.lock(); defer { lock.unlock() }
        buffer += chunk
        if buffer.count > 4000 { buffer = String(buffer.suffix(4000)) }
    }

    var text: String {
        lock.lock(); defer { lock.unlock() }
        return buffer
    }
}
