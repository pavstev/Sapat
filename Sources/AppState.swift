import Foundation

/// The single source of truth for what the UI is doing.
///
/// `preparing` covers the launch-time model prewarm + microphone request. The
/// optional progress is reserved for a download percentage if we wire one up; it is
/// `nil` for an indeterminate "preparing" spinner.
enum AppState: Equatable {
    case preparing(progress: Double?)
    case idle
    case recording
    case transcribing
    case translating
    case done
    case error(AppError)
}

/// A failure the user should see, optionally with a one-tap recovery action.
struct AppError: Equatable {
    var message: String
    var action: RecoveryAction?
}

/// A button the popover can render to help the user recover or improve the result.
struct RecoveryAction: Equatable {
    enum Kind: Equatable {
        case openMicrophoneSettings
        case openLMStudio
        case copyCommand(String)
    }

    var label: String
    var kind: Kind
}

/// Which engine produced the result. The single, typed representation of provenance — used by
/// the result card, the History rows, and `TranslationRecord` (persisted by its rawValue). A
/// legacy mapper preserves pre-2.0 history that stored a free-form `"LM Studio"`/`"Whisper"`.
enum TranslationSource: String, Codable, Equatable, Sendable {
    case mlx        // in-process MLX engine (the default)
    case lmStudio   // local LM Studio backend (opt-in)
    case cloud      // optional cloud backend (off by default)
    case whisper    // Whisper offline fallback (legacy)

    /// Short provenance name for the UI (rendered as "refined · <label>").
    var label: String {
        switch self {
        case .mlx: return "on-device"
        case .lmStudio: return "LM Studio"
        case .cloud: return "cloud"
        case .whisper: return "Whisper"
        }
    }

    /// SF Symbol for the History row / result provenance.
    var icon: String { self == .whisper ? "waveform" : "sparkles" }

    /// Maps a persisted value — a new rawValue, or a pre-2.0 free-form string — to a case.
    init(persisted raw: String) {
        if let value = TranslationSource(rawValue: raw) { self = value; return }
        switch raw {
        case "LM Studio": self = .lmStudio
        case "Whisper": self = .whisper
        default: self = .lmStudio // oldest records defaulted to LM Studio
        }
    }
}
