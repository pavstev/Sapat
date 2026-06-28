import AVFoundation
import Foundation

/// Normalizes an arbitrary user-picked file into something WhisperKit can read.
///
/// WhisperKit loads audio via `AVAudioFile`, which opens the common audio containers
/// (wav, m4a/aac, mp3, aiff, caf, flac) directly but **cannot** open video containers
/// (mp4, mov, …). So audio files pass straight through, while a video — or any format
/// `AVAudioFile` refuses — has its audio track exported to a temporary m4a first. There is
/// no length limit; long files just take longer (WhisperKit's VAD skips the silent parts).
enum AudioImporter {
    /// A path ready for transcription, plus whether we created a temp file to clean up.
    struct Prepared {
        let url: URL
        let isTemporary: Bool
    }

    // MARK: - Preparing

    static func prepare(_ url: URL) async throws -> Prepared {
        // Fast path: AVAudioFile can read it as-is (covers most dictation recordings).
        if (try? AVAudioFile(forReading: url)) != nil {
            return Prepared(url: url, isTemporary: false)
        }
        // Otherwise pull the audio track out of the container (handles video + exotic formats).
        Log.recorder.info("Import: extracting audio track from \(url.lastPathComponent, privacy: .public)")
        do {
            let extracted = try await exportAudioTrack(from: url)
            return Prepared(url: extracted, isTemporary: true)
        } catch {
            Log.recorder.error("Import: audio extraction failed: \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }

    /// Removes a temp file produced by `prepare`. No-op for pass-through originals.
    static func cleanUp(_ prepared: Prepared) {
        guard prepared.isTemporary else { return }
        try? FileManager.default.removeItem(at: prepared.url)
    }

    // MARK: - Audio-track extraction

    private static func exportAudioTrack(from url: URL) async throws -> URL {
        let asset = AVURLAsset(url: url)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        guard !audioTracks.isEmpty else { throw ImportError.noAudioTrack }

        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw ImportError.exportUnavailable
        }
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("sapat-import-\(UUID().uuidString).m4a")
        try? FileManager.default.removeItem(at: output)
        session.outputURL = output
        session.outputFileType = .m4a

        // AVAssetExportSession isn't Sendable, but it's confined to this function and the
        // completion fires exactly once — safe to read back in the continuation.
        nonisolated(unsafe) let export = session
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            export.exportAsynchronously {
                switch export.status {
                case .completed:
                    continuation.resume()
                case .cancelled:
                    continuation.resume(throwing: CancellationError())
                default:
                    continuation.resume(throwing: ImportError.exportFailed(
                        export.error?.localizedDescription ?? "the audio couldn't be extracted"))
                }
            }
        }
        return output
    }

    enum ImportError: LocalizedError, Equatable {
        case noAudioTrack
        case exportUnavailable
        case exportFailed(String)

        var errorDescription: String? {
            switch self {
            case .noAudioTrack: return "That file has no audio track."
            case .exportUnavailable: return "That audio format isn't supported."
            case .exportFailed(let message): return message
            }
        }
    }
}
