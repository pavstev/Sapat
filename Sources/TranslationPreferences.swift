import Foundation

/// Translation tone presets for the LM Studio refinement. `technical` is the default — the
/// speaker is mostly dictating software work, so precision and correct terminology win.
enum Tone: String, CaseIterable, Identifiable {
    case technical, polished, formal, casual, literal

    var id: String { rawValue }

    var label: String {
        switch self {
        case .technical: return "Technical"
        case .polished: return "Polished"
        case .formal: return "Formal"
        case .casual: return "Casual"
        case .literal: return "Literal"
        }
    }

    /// SF Symbol shown beside the tone in the on-screen picker.
    var icon: String {
        switch self {
        case .technical: return "chevron.left.forwardslash.chevron.right"
        case .polished: return "sparkles"
        case .formal: return "briefcase"
        case .casual: return "bubble.left.and.bubble.right"
        case .literal: return "text.quote"
        }
    }

    /// Plain-English explanation shown in the picker's hover popup — what this tone does and
    /// when to reach for it.
    var summary: String {
        switch self {
        case .technical:
            return "Precise engineering English. Keeps exact API, system, and component names and the specific technical term — concise, no fluff. Best for dictating dev work."
        case .polished:
            return "Clean, natural, idiomatic English. The everyday choice for clear, readable writing."
        case .formal:
            return "Buttoned-up, professional English for business and official messages."
        case .casual:
            return "Relaxed and conversational — the way you'd write to a teammate."
        case .literal:
            return "Stays close to your own words and sentence shapes; only fixes grammar and correctness, with minimal rephrasing."
        }
    }

    /// A short, concrete "feels like…" line under the summary, for extra flavor in the popup.
    var example: String {
        switch self {
        case .technical: return "“Wire the retry queue to the idempotent webhook handler.”"
        case .polished: return "“Let's reconnect the retry queue to the webhook handler.”"
        case .formal: return "“Please connect the retry queue to the webhook handler.”"
        case .casual: return "“Just hook the retry queue up to the webhook thing.”"
        case .literal: return "Mirrors your phrasing, lightly cleaned up."
        }
    }

    var instruction: String {
        switch self {
        case .technical:
            return "Use precise, professional, technical English appropriate for software engineering. Prefer exact technical terminology and correct names for APIs, data structures, systems, and architecture; choose the specific term over a general one. Be unambiguous and concise; avoid casual phrasing, hedging, and marketing language. Where the speaker named a technical concept imprecisely, use the correct term — but never invent specifics they did not say."
        case .polished: return "Produce clean, natural, idiomatic English."
        case .formal: return "Use formal, professional English suitable for business writing."
        case .casual: return "Use relaxed, conversational English."
        case .literal: return "Prefer the speaker's own terms and sentence shapes where they are already precise; do not paraphrase beyond what grammar and correctness require."
        }
    }
}

/// UserDefaults-backed access to the selected Output Mode + glossary. The mode is chosen from
/// the on-screen `OutputModePicker` (`@AppStorage`, same `modeKey`); the glossary and model id
/// keep working from their defaults (there's no Settings screen — the app is a single screen).
enum TranslationPreferences {
    /// New: the selected Output Mode id. Replaces the closed tone selection.
    static let modeKey = "outputMode"
    /// Legacy tone key — kept only so an old install's value is recognized (any prior tone
    /// selection falls back to the default mode; modes replace tones).
    static let toneKey = "translationTone"
    static let glossaryKey = "translationGlossary"
    static let modelKey = "translationModel"

    /// Default reasoner model id — Qwen3-class (MLX), a strong multilingual model with good
    /// Serbian coverage. Used by the LM Studio backend; the in-process MLX engine resolves its
    /// own bundled/managed model.
    static let defaultModel = "qwen/qwen3-8b"

    /// The selected Output Mode (defaults to Polished English). An old tone selection simply
    /// falls back to the default — modes replace tones.
    static var outputMode: OutputMode {
        let id = UserDefaults.standard.string(forKey: modeKey) ?? ""
        return id.isEmpty ? OutputModes.default : OutputModes.mode(id: id)
    }

    static var glossary: String {
        UserDefaults.standard.string(forKey: glossaryKey) ?? ""
    }

    static var model: String {
        let value = UserDefaults.standard.string(forKey: modelKey) ?? ""
        return value.isEmpty ? defaultModel : value
    }
}
