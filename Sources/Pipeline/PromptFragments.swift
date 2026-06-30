import Foundation

/// Shared prompt fragments, so the formatting and no-fabrication framing have one source of
/// truth across the refiner and the pipeline (rather than being re-spelled at each call site).
enum PromptFragments {
    /// The optional "apply this glossary" block — identical wherever a prompt embeds the
    /// glossary. Empty when no glossary is set.
    static func glossaryBlock(_ glossary: String) -> String {
        let terms = glossary.trimmingCharacters(in: .whitespacesAndNewlines)
        return terms.isEmpty ? "" : "\n\nApply this glossary for specific names/terms:\n\(terms)"
    }

    /// The grounded user message shared by the Reason and Synthesize stages: the cleaned
    /// transcript (the only ground truth), the optional structured extraction, optional prior
    /// analysis, and the optional recalled-memory block — assembled in a fixed order.
    static func groundedMessage(cleaned: String, extraction: Extraction?, analysis: String?, recall: String) -> String {
        var user = "WHAT THE SPEAKER SAID (cleaned — the only ground truth):\n\(cleaned)"
        if let extraction, !extraction.isEmpty {
            user += "\n\nEXTRACTED STRUCTURE:\n\(extraction.promptText)"
        }
        if let analysis, !analysis.isEmpty {
            user += "\n\nANALYSIS (grounded reasoning to draw on):\n\(analysis)"
        }
        return user + recall
    }
}
