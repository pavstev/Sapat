import Foundation

/// Translation tone presets. Only affect the Ollama polish path — the offline Whisper
/// fallback can't honor them.
enum Tone: String, CaseIterable, Identifiable {
    case polished, formal, casual, literal

    var id: String { rawValue }

    var label: String {
        switch self {
        case .polished: return "Polished"
        case .formal: return "Formal"
        case .casual: return "Casual"
        case .literal: return "Literal"
        }
    }

    var instruction: String {
        switch self {
        case .polished: return "Produce clean, natural, idiomatic English."
        case .formal: return "Use formal, professional English suitable for business writing."
        case .casual: return "Use relaxed, conversational English."
        case .literal: return "Stay as literal to the source as possible while remaining grammatical."
        }
    }
}

/// UserDefaults-backed access to the tone + glossary, shared between the SettingsView
/// (`@AppStorage`, same keys) and the RecorderViewModel.
enum TranslationPreferences {
    static let toneKey = "translationTone"
    static let glossaryKey = "translationGlossary"

    static var tone: Tone {
        Tone(rawValue: UserDefaults.standard.string(forKey: toneKey) ?? "") ?? .polished
    }

    static var glossary: String {
        UserDefaults.standard.string(forKey: glossaryKey) ?? ""
    }
}
