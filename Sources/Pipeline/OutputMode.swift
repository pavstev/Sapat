import Foundation

/// A selectable Output Mode: the generalization of the old five tones. Each mode is a small
/// piece of data — which optional pipeline stages run, the Clean-stage language + register,
/// and an optional synthesis instruction + output schema — so adding a mode is data, not new
/// control flow. The inline picker (no Settings screen) lists `OutputModes.all`.
struct OutputMode: Identifiable, Sendable, Equatable {
    /// Optional stages beyond the always-on Clean (and the always-on Synthesize for non-refine
    /// modes). Their presence is what makes a mode "think" rather than just polish.
    enum Stage: String, Sendable { case extract, reason, critique }

    let id: String
    let label: String
    let icon: String
    let summary: String
    let example: String
    /// Language of the faithful Clean-stage base.
    let cleanLanguage: RefineLanguage
    /// Register/style instruction for the Clean stage.
    let register: String
    /// Column title for the artifact in the result card.
    let resultTitle: String
    /// Optional stages this mode runs (Clean + Synthesize are implicit).
    let extraStages: Set<Stage>
    /// The synthesis system instruction. `nil` means the mode is a pure refine: the cleaned
    /// base IS the artifact (Polished English / Serbian) — no synthesis pass.
    let synthesisInstruction: String?

    var runsExtract: Bool { extraStages.contains(.extract) }
    var runsReason: Bool { extraStages.contains(.reason) }
    var runsCritique: Bool { extraStages.contains(.critique) }
    /// True for Polished English/Serbian — the cleaned base is returned directly (byte-for-byte
    /// the old behaviour for Polished English).
    var isPureRefine: Bool { synthesisInstruction == nil }
}

/// The Output Mode registry + persisted selection. Replaces the closed `Tone` enum as the
/// single inline preference; `Tone` survives only as the source of the English register
/// instructions, so Polished English stays identical to today's default (Technical).
enum OutputModes {
    static let polishedEnglish = OutputMode(
        id: "polished-english",
        label: "Polished English",
        icon: "textformat",
        summary: "Today's behaviour: your Serbian, cleaned and de-duplicated into one precise English statement. The faithful default.",
        example: "“Wire the retry queue to the idempotent webhook handler.”",
        cleanLanguage: .english,
        register: Tone.technical.instruction,
        resultTitle: "ENGLISH",
        extraStages: [],
        synthesisInstruction: nil)

    static let polishedSerbian = OutputMode(
        id: "polished-serbian",
        label: "Polished Serbian",
        icon: "character.book.closed",
        summary: "Same faithful cleanup, but the output stays in your Serbian — de-duplicated and formalized, not translated.",
        example: "„Poveži red za ponovne pokušaje sa idempotentnim webhook handlerom.“",
        cleanLanguage: .serbian,
        register: serbianRegister,
        resultTitle: "СРПСКИ",
        extraStages: [],
        synthesisInstruction: nil)

    static let structuredBrief = OutputMode(
        id: "structured-brief",
        label: "Structured brief",
        icon: "list.bullet.rectangle",
        summary: "Your thinking organized into a clean doc: intent, topics, decisions, open questions, action items, uncertainties.",
        example: "Intent · Decisions · Open questions · Action items",
        cleanLanguage: .english,
        register: Tone.technical.instruction,
        resultTitle: "BRIEF",
        extraStages: [.extract],
        synthesisInstruction: """
        Render the speaker's thinking as a clean, scannable brief. Use these sections, each only \
        if it has content: a one-line "Intent:", then "Topics", "Decisions" (each with its \
        rationale), "Open questions", "Action items" (with owner if stated), and "Uncertainties". \
        Plain text with simple bold headings and "- " bullets. Be concise. Omit empty sections \
        entirely.
        """)

    static let engineeringReport = OutputMode(
        id: "engineering-report",
        label: "Engineering report",
        icon: "doc.text.magnifyingglass",
        summary: "A PR-style write-up: problem, approach, trade-offs, what was verified, risks — built only from what you said.",
        example: "## Problem · ## Approach · ## Trade-offs · ## Risks",
        cleanLanguage: .english,
        register: Tone.technical.instruction,
        resultTitle: "REPORT",
        extraStages: [.extract, .reason, .critique],
        synthesisInstruction: """
        Write a concise engineering report / PR description in Markdown using these headings, \
        each only if there is grounded content: "## Problem", "## Approach", "## Trade-offs", \
        "## What was verified", "## Risks / unknowns". Draw on the analysis provided, but include \
        only points the speaker actually made. Omit a heading entirely if there is nothing for it.
        """)

    static let promptRefiner = OutputMode(
        id: "prompt-refiner",
        label: "Prompt refiner",
        icon: "wand.and.stars",
        summary: "Turns a rambling monologue into one tight, self-contained prompt you can paste straight into an AI assistant.",
        example: "“Refactor X so that … given … with constraints …”",
        cleanLanguage: .english,
        register: Tone.technical.instruction,
        resultTitle: "PROMPT",
        extraStages: [],
        synthesisInstruction: """
        Turn the speaker's monologue into ONE tight, self-contained prompt to feed an AI coding \
        assistant. Capture the goal, the relevant context, and the constraints the speaker stated, \
        as a single clear instruction (a short paragraph, or a lead sentence + a few "- " bullets \
        if that's clearer). Do NOT add requirements, scope, or assumptions the speaker did not \
        state. Output only the prompt text — no meta commentary about it being a prompt.
        """)

    static let standup = OutputMode(
        id: "standup",
        label: "Standup",
        icon: "person.2.wave.2",
        summary: "A short status update in Yesterday / Today / Blockers form, mapped from what you actually reported.",
        example: "Yesterday · Today · Blockers",
        cleanLanguage: .english,
        register: Tone.technical.instruction,
        resultTitle: "STANDUP",
        extraStages: [.extract],
        synthesisInstruction: """
        Write a short standup update with exactly three bold headings: "Yesterday", "Today", \
        "Blockers". Map completed/past work to Yesterday, planned work and action items to Today, \
        and stated blockers, open questions, or uncertainties to Blockers. Terse "- " bullets. \
        Use only what was said; if a section has nothing, put "- —" under it.
        """)

    static let all: [OutputMode] = [
        polishedEnglish, polishedSerbian, structuredBrief, engineeringReport, promptRefiner, standup,
    ]

    static let `default` = polishedEnglish

    static func mode(id: String) -> OutputMode {
        all.first { $0.id == id } ?? `default`
    }

    /// Serbian Clean-stage register (the meta-prompt is English; this controls Serbian phrasing).
    static let serbianRegister =
        "Use clear, correct, professional written Serbian. Prefer precise terminology; keep English technical proper nouns (API, system, and product names) exactly as the speaker used them. Avoid casual phrasing and filler."
}
