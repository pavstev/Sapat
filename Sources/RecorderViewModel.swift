import AppKit
import AVFoundation
import Foundation
import Observation

/// Owns all app state and logic. Created once by `AppDelegate` and injected into the
/// SwiftUI popover via the environment, so recording can be driven by the global
/// hotkey even while the popover is closed.
@MainActor
@Observable
final class RecorderViewModel {
    // MARK: Configuration
    // large-v3: the most accurate multilingual model — best for Serbian. Slower per
    // clip than turbo, but the bake-off showed ~3x fewer word errors.
    private let whisperModel = "openai_whisper-large-v3"
    private let sourceLanguage = "sr" // Serbian

    // Recording format: 16 kHz mono 16-bit PCM WAV — exactly what WhisperKit wants.
    private static let sampleRate = 16_000.0
    private static let channelCount = 1
    private static let bitDepth = 16
    /// Below this, a "recording" is a stray tap, not speech.
    private static let minRecordingSeconds: TimeInterval = 0.3

    // MARK: Observed state (read by the view)
    private(set) var state: AppState = .preparing(progress: nil)
    private(set) var level: Double = 0 // mic level 0...1, drives the record-button pulse
    private(set) var levelHistory: [Double] = [] // recent levels for the menu-bar waveform
    private(set) var recordingDuration: TimeInterval = 0 // elapsed seconds, shown while recording
    private(set) var serbianText = ""
    private(set) var englishText = ""
    private(set) var translationSource: TranslationSource?
    private(set) var notice: String? // transient info, e.g. "No speech detected"
    /// Non-nil while LM Studio is being made ready (server start / model download / load).
    private(set) var lmStudioStatus: String?
    /// Sub-status during processing: elapsed transcription time, or "Refining N of M sections…".
    private(set) var processingDetail: String?
    /// File name when processing an imported recording (nil for live mic recordings).
    private(set) var importedFileName: String?
    private(set) var showCopiedConfirmation = false

    /// Called on every state change so AppKit (the status-bar icon) can react.
    var onStateChange: ((AppState) -> Void)?

    /// Set by AppDelegate so the popover's close (✕) button can dismiss it.
    var onRequestClose: (() -> Void)?

    /// Fires on each metering tick with the recent level buffer (drives the menu-bar waveform).
    var onLevelChange: (([Double]) -> Void)?

    var isRecording: Bool {
        if case .recording = state { return true }
        return false
    }

    var isBusy: Bool {
        switch state {
        case .preparing, .transcribing, .translating: return true
        default: return false
        }
    }

    /// Whether the record button should accept a tap right now.
    var canRecord: Bool {
        switch state {
        case .idle, .done, .recording: return true
        default: return false
        }
    }

    /// Whether Import should accept a file right now — same idea as `canRecord`, but never
    /// while a recording is actually in progress.
    var canImport: Bool {
        switch state {
        case .idle, .done: return true
        default: return false
        }
    }

    // MARK: Dependencies
    private let whisper = WhisperEngine()
    private var llm = LMStudioClient()
    private let lmStudio = LMStudioManager()
    /// Coalesces concurrent readiness work (the launch warm-up and a refine) so we never
    /// run two `lms` downloads/loads at once.
    private var readinessTask: Task<Void, Error>?

    /// Translation history store; set by AppDelegate.
    var history: HistoryStore?

    // MARK: Recording internals
    private var recorder: AVAudioRecorder?
    private var recordingURL: URL?
    private var meterTimer: Timer?
    private var processingTimer: Timer?
    private var processingElapsed = 0 // seconds, drives the elapsed clock in the detail line
    private var transcriptionFraction = 0.0 // WhisperKit's live progress, for the % + estimate

    /// The audio behind the current job, kept so a failed run can be retried without
    /// re-recording. A live recording is durably saved (and deleted on success); an import
    /// points at the user's own file.
    private enum PendingSource {
        case recording(URL) // our durable WAV — clean up on success
        case imported(URL)  // the user's file — never delete
    }
    private var pending: PendingSource?
    private var copiedTask: Task<Void, Never>?
    private var noticeTask: Task<Void, Never>?

    // MARK: Lifecycle

    /// Run once at launch: request the microphone and prewarm the Whisper model.
    func prepare() async {
        setState(.preparing(progress: nil))

        let granted = await requestMicrophoneAccess()
        guard granted else {
            setState(.error(AppError(
                message: "Microphone access denied. Šapat needs the microphone to hear you.",
                action: RecoveryAction(label: "Open Microphone Settings", kind: .openMicrophoneSettings)
            )))
            return
        }

        do {
            try await whisper.load(model: whisperModel) { [weak self] fraction in
                Task { @MainActor in self?.setPreparingProgress(fraction) }
            }
            setState(.idle)
            warmUpLMStudio()
            pruneOldRecordings(keeping: 30)
        } catch {
            setState(.error(AppError(
                message: "Couldn't load the speech model. \(error.localizedDescription)",
                action: nil
            )))
        }
    }

    /// Best-effort, non-blocking: at launch we get LM Studio fully ready (server up, model
    /// downloaded + loaded) so the first refinement is instant. Failures here are silent —
    /// the refine path runs the same readiness check and surfaces a real error only if a
    /// recording actually needs LM Studio and it still can't be made ready.
    private func warmUpLMStudio() {
        Task { [weak self] in
            do {
                try await self?.ensureLMStudioReady()
            } catch {
                Log.llm.info("LM Studio warm-up deferred: \(error.localizedDescription, privacy: .public)")
                self?.setLMStudioStatus(nil)
            }
        }
    }

    /// Lightweight progress update during the first-run model download. Skips the
    /// status-bar/log churn of `setState` since it can fire many times a second.
    private func setPreparingProgress(_ fraction: Double) {
        guard case .preparing = state else { return }
        state = .preparing(progress: fraction)
    }

    // MARK: Intent

    /// Start recording if idle/done, stop-and-process if recording. Ignored while busy.
    func toggleRecording() {
        switch state {
        case .recording:
            stopAndProcess()
        case .idle, .done:
            startRecording()
        default:
            break
        }
    }

    /// Transcribe + refine an existing audio or video file (picked or dropped). No length
    /// limit — long files just take longer, and silence is skipped by the same VAD path as
    /// a live recording. Video has its audio track extracted first.
    func importRecording(from url: URL) {
        guard canImport else { return }
        clearResults()
        importedFileName = url.lastPathComponent
        pending = .imported(url)
        setState(.transcribing)
        processingDetail = "Preparing \(url.lastPathComponent)…"
        Task { await runImport(url: url) }
    }

    private func runImport(url: URL) async {
        let prepared: AudioImporter.Prepared
        do {
            prepared = try await AudioImporter.prepare(url)
        } catch {
            importedFileName = nil
            processingDetail = nil
            setState(.error(AppError(
                message: "Couldn't read “\(url.lastPathComponent)”. \(error.localizedDescription)",
                action: nil
            )))
            return
        }
        await transcribeAndRefine(audioPath: prepared.url.path)
        AudioImporter.cleanUp(prepared)
    }

    /// Discards an in-progress recording without transcribing it (Esc / Cancel button).
    func cancelRecording() {
        guard case .recording = state else { return }
        stopMetering()
        recorder?.stop()
        recorder = nil
        level = 0
        levelHistory = []
        recordingDuration = 0
        if let url = recordingURL { try? FileManager.default.removeItem(at: url) }
        recordingURL = nil
        clearResults()
        setState(.idle)
        flashNotice("Recording canceled")
    }

    /// "Retry" after an error, cheapest viable path first: re-refine an existing transcript
    /// (LM Studio hiccup), else re-transcribe from the saved audio (transcription failed),
    /// else re-run launch preparation.
    func retryAfterError() {
        if !serbianText.isEmpty {
            Task { await refine() }
            return
        }
        switch pending {
        case .recording(let url) where FileManager.default.fileExists(atPath: url.path):
            Task { await transcribeAndRefine(audioPath: url.path) }
        case .imported(let url):
            importedFileName = url.lastPathComponent
            setState(.transcribing)
            Task { await runImport(url: url) }
        default:
            Task { await prepare() }
        }
    }

    /// Called by AppDelegate when the global hotkey couldn't be registered.
    func noteHotkeyUnavailable() {
        flashNotice("Couldn't register \(SapatShortcut.display) — another app may be using it.")
    }

    func performRecoveryAction(_ action: RecoveryAction) {
        switch action.kind {
        case .openMicrophoneSettings:
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                NSWorkspace.shared.open(url)
            }
        case .openLMStudio:
            let appURL = URL(fileURLWithPath: "/Applications/LM Studio.app")
            if FileManager.default.fileExists(atPath: appURL.path) {
                NSWorkspace.shared.open(appURL)
            } else if let site = URL(string: "https://lmstudio.ai") {
                NSWorkspace.shared.open(site)
            }
        case .copyCommand(let command):
            copyToPasteboard(command)
        }
    }

    /// Copies the current English translation to the clipboard (explicit Copy button).
    func copyEnglish() {
        guard !englishText.isEmpty else { return }
        copyToPasteboard(englishText)
        flashCopied()
    }

    // MARK: Recording

    private func startRecording() {
        clearResults()

        // Save to a durable, uniquely-named file so the recording survives a failed
        // transcription/refinement and can be retried (deleted once it succeeds).
        let url = Self.newRecordingURL()
        try? FileManager.default.removeItem(at: url)

        // AVAudioRecorder converts from the hardware format to our target format internally.
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: Self.sampleRate,
            AVNumberOfChannelsKey: Self.channelCount,
            AVLinearPCMBitDepthKey: Self.bitDepth,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false
        ]

        do {
            let recorder = try AVAudioRecorder(url: url, settings: settings)
            recorder.isMeteringEnabled = true
            guard recorder.record() else {
                setState(.error(AppError(message: "Couldn't start recording.", action: nil)))
                return
            }
            self.recorder = recorder
            recordingURL = url
            recordingDuration = 0
            setState(.recording)
            startMetering()
        } catch {
            setState(.error(AppError(
                message: "Couldn't start recording. \(error.localizedDescription)",
                action: nil
            )))
        }
    }

    private func stopAndProcess() {
        stopMetering()
        let duration = recorder?.currentTime ?? 0
        recorder?.stop()
        recorder = nil
        level = 0
        levelHistory = []
        recordingDuration = 0

        guard let url = recordingURL, duration > Self.minRecordingSeconds else {
            if let url = recordingURL { try? FileManager.default.removeItem(at: url) } // nothing worth keeping
            recordingURL = nil
            flashNotice("No speech detected — try again")
            setState(.idle)
            return
        }
        pending = .recording(url)
        Task { await transcribeAndRefine(audioPath: url.path) }
    }

    private func transcribeAndRefine(audioPath: String) async {
        setState(.transcribing)
        startProcessingTimer()
        let serbian: String
        do {
            serbian = try await whisper.run(audioPath: audioPath, task: .transcribe, language: sourceLanguage)
        } catch {
            stopProcessingTimer()
            processingDetail = nil
            setState(.error(AppError(
                message: "Transcription failed. \(error.localizedDescription)",
                action: nil
            )))
            return
        }
        stopProcessingTimer()
        guard isMeaningful(serbian) else {
            processingDetail = nil
            flashNotice("No speech detected — try again")
            setState(.idle)
            return
        }
        serbianText = serbian
        await refine()
    }

    /// Refines the current `serbianText` into English with LM Studio — the only path now
    /// (no Whisper fallback). LM Studio is made ready first; on failure the transcript
    /// stays on screen and the error offers Retry + Open LM Studio, so nothing the speaker
    /// said is lost.
    private func refine() async {
        guard !serbianText.isEmpty else { return }
        setState(.translating)
        processingDetail = nil
        do {
            try await ensureLMStudioReady()
            let english = try await llm.refine(
                serbianText,
                tone: TranslationPreferences.tone,
                glossary: TranslationPreferences.glossary,
                onProgress: { [weak self] detail in
                    Task { @MainActor in self?.processingDetail = detail }
                }
            )
            finish(english: english)
        } catch is CancellationError {
            setLMStudioStatus(nil)
            processingDetail = nil
            setState(.idle)
        } catch {
            setLMStudioStatus(nil)
            processingDetail = nil
            setState(.error(lmStudioError(for: error)))
        }
    }

    /// Ensures the server is up and the configured model is loaded, coalescing a concurrent
    /// launch warm-up so two `lms` downloads/loads never run at once. The off-main readiness
    /// work reports progress through an `AsyncStream` (it can't touch main-actor state
    /// directly), which we drain here to update `lmStudioStatus`.
    private func ensureLMStudioReady() async throws {
        llm.model = TranslationPreferences.model
        if let existing = readinessTask {
            try await existing.value
            return
        }
        // Coalesce concurrent callers (the launch warm-up + a refine) onto one readiness run
        // so two `lms` downloads/loads never run at once. The task inherits this main actor,
        // so the progress callback can update state directly; the manager throttles it.
        let task = Task { try await self.performReadiness() }
        readinessTask = task
        defer { readinessTask = nil }
        try await task.value // re-throws any setup failure to the caller
    }

    private func performReadiness() async throws {
        defer { setLMStudioStatus(nil) }
        try await lmStudio.ensureReady(modelKey: TranslationPreferences.model, client: llm) { [weak self] status in
            Task { @MainActor in self?.setLMStudioStatus(status) }
        }
    }

    private func finish(english: String) {
        let cleaned = english.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else {
            setState(.error(AppError(message: "The translation came back empty.", action: nil)))
            return
        }
        englishText = cleaned
        translationSource = .lmStudio
        processingDetail = nil
        copyToPasteboard(cleaned)
        flashCopied()
        setState(.done)
        saveToHistory(serbian: serbianText, english: cleaned)
        // Succeeded — the durable recording is no longer needed for retry.
        if case .recording(let url)? = pending { try? FileManager.default.removeItem(at: url) }
        pending = nil
    }

    private func saveToHistory(serbian: String, english: String) {
        history?.add(serbian: serbian, english: english, model: whisperModel, source: "LM Studio")
    }

    // MARK: Helpers

    private func setLMStudioStatus(_ status: String?) {
        guard status != lmStudioStatus else { return } // avoid redundant SwiftUI invalidations
        lmStudioStatus = status
    }

    /// Turns an LM Studio failure into a user-facing error that keeps the transcript on
    /// screen and offers a way to fix things (Retry re-refines; the action opens LM Studio).
    private func lmStudioError(for error: Error) -> AppError {
        let openLMStudio = RecoveryAction(label: "Open LM Studio", kind: .openLMStudio)
        guard let lmError = error as? LMStudioError else {
            return AppError(message: "Couldn't refine the translation. \(error.localizedDescription)", action: openLMStudio)
        }
        switch lmError {
        case .cliNotFound:
            return AppError(
                message: "LM Studio's command-line tool (lms) isn't installed, so the translation can't be refined. In LM Studio run “Install lms” (or `npx lmstudio install-cli`), then Retry.",
                action: openLMStudio
            )
        case .notRunning:
            return AppError(message: "LM Studio isn't running. Start it, then Retry.", action: openLMStudio)
        case .modelNotLoaded:
            return AppError(message: "No model is loaded in LM Studio. Load \(TranslationPreferences.model), then Retry.", action: openLMStudio)
        case .setupFailed(let message):
            return AppError(message: "Couldn't get LM Studio ready: \(message)", action: openLMStudio)
        case .other(let message):
            return AppError(message: "LM Studio couldn't refine the translation: \(message)", action: openLMStudio)
        }
    }

    /// Cheap guard against Whisper hallucinating text from silence/noise.
    private func isMeaningful(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return false }
        return trimmed.rangeOfCharacter(from: .letters) != nil
    }

    private func clearResults() {
        serbianText = ""
        englishText = ""
        translationSource = nil
        notice = nil
        processingDetail = nil
        importedFileName = nil
        transcriptionFraction = 0
        pending = nil
    }

    private func setState(_ newState: AppState) {
        Log.recorder.info("state → \(String(describing: newState), privacy: .public)")
        state = newState
        onStateChange?(newState)
    }

    // MARK: Microphone permission

    private func requestMicrophoneAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    continuation.resume(returning: granted)
                }
            }
        default:
            return false
        }
    }

    // MARK: Metering (drives the pulse)

    private func startMetering() {
        // Timer fires on the main run loop and we're already on the main actor, so
        // update directly instead of allocating a Task per tick (20 Hz).
        meterTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateLevel() }
        }
    }

    private func updateLevel() {
        guard let recorder else { return }
        recorder.updateMeters()
        let power = recorder.averagePower(forChannel: 0) // dBFS, roughly -160...0
        level = Double(max(0, min(1, (power + 55) / 55)))
        levelHistory.append(level)
        if levelHistory.count > 18 { levelHistory.removeFirst(levelHistory.count - 18) }
        recordingDuration = recorder.currentTime
        onLevelChange?(levelHistory)
    }

    private func stopMetering() {
        meterTimer?.invalidate()
        meterTimer = nil
    }

    // MARK: Processing progress (transcription elapsed-time clock)

    private func startProcessingTimer() {
        processingElapsed = 0
        transcriptionFraction = 0
        processingDetail = transcriptionDetail()
        processingTimer?.invalidate()
        // Fires on the main run loop; we're on the main actor.
        processingTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.processingElapsed += 1
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.transcriptionFraction = await self.whisper.transcriptionProgress
                    self.processingDetail = self.transcriptionDetail()
                }
            }
        }
    }

    private func stopProcessingTimer() {
        processingTimer?.invalidate()
        processingTimer = nil
    }

    /// Detail under the status line while transcribing: a real percentage + time estimate
    /// once WhisperKit reports progress, otherwise an elapsed clock. Prefixed with the file
    /// name for imports.
    private func transcriptionDetail() -> String {
        let prefix = importedFileName.map { "\($0) · " } ?? ""
        if transcriptionFraction > 0.01 {
            let pct = Int((transcriptionFraction * 100).rounded())
            if let remaining = estimatedRemaining() { return "\(prefix)\(pct)% · ~\(remaining) left" }
            return "\(prefix)\(pct)%"
        }
        return "\(prefix)\(clockString(processingElapsed))"
    }

    /// Projects time-remaining from how long the elapsed fraction took. Needs a couple of
    /// seconds of signal first so the first estimate isn't wild.
    private func estimatedRemaining() -> String? {
        guard transcriptionFraction > 0.02, processingElapsed >= 2 else { return nil }
        let projectedTotal = Double(processingElapsed) / transcriptionFraction
        let remaining = Int((projectedTotal - Double(processingElapsed)).rounded())
        guard remaining > 0 else { return nil }
        return clockString(remaining)
    }

    private func clockString(_ seconds: Int) -> String {
        String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    // MARK: Durable recording files (so a failed run can be retried)

    private static func newRecordingURL() -> URL {
        let name = "rec-\(timestamp())-\(UUID().uuidString.prefix(6)).wav"
        if let dir = try? Brand.recordingsDirectory() { return dir.appendingPathComponent(name) }
        return Brand.temporaryRecordingURL
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: Date())
    }

    /// Bound the saved-recordings folder so failed-and-forgotten captures don't pile up
    /// forever, while keeping the most recent ones around to retry.
    private func pruneOldRecordings(keeping limit: Int) {
        guard let dir = try? Brand.recordingsDirectory() else { return }
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        let wavs = files.filter { $0.pathExtension == "wav" }
        guard wavs.count > limit else { return }
        let byNewest = wavs.sorted {
            let lhs = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let rhs = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return lhs > rhs
        }
        for url in byNewest.dropFirst(limit) { try? fm.removeItem(at: url) }
    }

    // MARK: Clipboard + confirmations

    private func copyToPasteboard(_ string: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(string, forType: .string)
    }

    private func flashCopied() {
        showCopiedConfirmation = true
        copiedTask?.cancel()
        copiedTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            self?.showCopiedConfirmation = false
        }
    }

    private func flashNotice(_ message: String) {
        notice = message
        noticeTask?.cancel()
        noticeTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled else { return }
            self?.notice = nil
        }
    }
}
