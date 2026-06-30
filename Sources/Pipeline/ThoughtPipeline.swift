import Foundation

/// The "thinking" — a typed, multi-stage pipeline that replaces the single refine call. Each
/// Output Mode is just a config of which stages run (§5.2):
///
///   1. Clean      — faithful, de-duplicated, sanitized base in the mode's language (`Refiner`).
///   2. Extract    — structured `Extraction` via schema-constrained generation (§6).
///   3. Retrieve   — semantic memory (wired in Phase 3).
///   4. Reason     — frame the problem, options, trade-offs, risks (grounded only in the input).
///   5. Self-critique — a second pass that strips overclaims / fabrication / resolved uncertainties.
///   6. Synthesize — render the final artifact for the selected mode.
///
/// An `actor`: its work is LLM round-trips and string assembly that must stay off the main
/// actor (F10). Pure-refine modes (Polished English/Serbian) short-circuit after Clean, so
/// today's flagship behaviour is unchanged and as fast as before.
actor ThoughtPipeline {
    private let inference: Inference
    private let refiner: Refiner
    /// Semantic memory for the Retrieve stage. Nil disables retrieval (e.g. in tests).
    private let memory: MemoryStore?

    init(inference: Inference, memory: MemoryStore? = nil) {
        self.inference = inference
        self.refiner = Refiner(inference: inference)
        self.memory = memory
    }

    struct Result: Sendable {
        /// The artifact shown and copied to the clipboard.
        let primary: String
        /// The faithful cleaned base (used for the transcript column and memory).
        let cleaned: String
        /// Structured extraction, when the mode ran the Extract stage.
        let extraction: Extraction?
    }

    func run(
        transcript serbian: String,
        mode: OutputMode,
        glossary: String = "",
        onProgress: (@Sendable (String) -> Void)? = nil
    ) async throws -> Result {
        // 1. Clean — always. The whole-recording chunk/merge guarantee lives here.
        let cleaned = try await refiner.refine(
            serbian, language: mode.cleanLanguage, register: mode.register,
            glossary: glossary, onProgress: onProgress)

        // Pure-refine modes: the cleaned base IS the artifact (Polished English/Serbian).
        guard !mode.isPureRefine else {
            return Result(primary: cleaned, cleaned: cleaned, extraction: nil)
        }

        // 2. Extract (structured).
        var extraction: Extraction?
        if mode.runsExtract {
            onProgress?("Extracting structure…")
            extraction = try await extract(cleaned)
        }

        // 3. Retrieve — pull the user's own related past notes from semantic memory.
        var retrieved: [MemoryStore.Hit] = []
        if let memory {
            onProgress?("Recalling related notes…")
            retrieved = await memory.search(query: cleaned, limit: 3)
        }
        let recall = Self.retrievedBlock(retrieved)

        // 4. Reason + 5. Self-critique.
        var analysis: String?
        if mode.runsReason {
            onProgress?("Reasoning through it…")
            analysis = try await reason(cleaned: cleaned, extraction: extraction, recall: recall)
            if mode.runsCritique, let draft = analysis {
                onProgress?("Checking for gaps & overclaims…")
                analysis = try await critique(draft: draft, source: cleaned)
            }
        }

        // 6. Synthesize.
        onProgress?("Writing the \(mode.label.lowercased())…")
        let artifact = try await synthesize(mode: mode, cleaned: cleaned, extraction: extraction, analysis: analysis, recall: recall, glossary: glossary)
        return Result(primary: artifact, cleaned: cleaned, extraction: extraction)
    }

    /// Renders retrieved memories as a clearly-fenced, optional context block. The prompts are
    /// explicit that this is the user's prior context, to use only if relevant — never to invent
    /// connections or import facts that weren't in the current input.
    private static func retrievedBlock(_ hits: [MemoryStore.Hit]) -> String {
        guard !hits.isEmpty else { return "" }
        let items = hits.enumerated().map { index, hit -> String in
            let text = hit.artifact.isEmpty ? hit.serbian : hit.artifact
            return "\(index + 1). \(text)"
        }.joined(separator: "\n")
        return """


        RELATED PAST NOTES FROM THIS USER (their own prior context — consider it only if directly \
        relevant; do NOT import facts from it into the current output or invent connections):
        \(items)
        """
    }

    // MARK: - Stages

    private func extract(_ cleaned: String) async throws -> Extraction {
        let request = InferenceRequest(system: Extraction.systemPrompt, user: cleaned, temperature: 0)
        return try await inference.generateStructured(request, as: Extraction.self, schema: Extraction.schema)
    }

    private func reason(cleaned: String, extraction: Extraction?, recall: String) async throws -> String {
        let user = PromptFragments.groundedMessage(cleaned: cleaned, extraction: extraction, analysis: nil, recall: recall)
        let raw = try await inference.generate(
            InferenceRequest(system: PipelinePrompts.reasoningSystem, user: user, temperature: 0.3))
        return OutputSanitizer.sanitize(raw)
    }

    private func critique(draft: String, source: String) async throws -> String {
        let user = "SOURCE (the only ground truth):\n\(source)\n\nDRAFT TO CHECK AND CORRECT:\n\(draft)"
        let raw = try await inference.generate(
            InferenceRequest(system: PipelinePrompts.critiqueSystem, user: user, temperature: 0))
        let corrected = OutputSanitizer.sanitize(raw)
        return corrected.isEmpty ? draft : corrected
    }

    private func synthesize(mode: OutputMode, cleaned: String, extraction: Extraction?, analysis: String?, recall: String, glossary: String) async throws -> String {
        let system = PipelinePrompts.synthesisSystem(instruction: mode.synthesisInstruction ?? "", glossary: glossary)
        let user = PromptFragments.groundedMessage(cleaned: cleaned, extraction: extraction, analysis: analysis, recall: recall)
        let raw = try await inference.generate(
            InferenceRequest(system: system, user: user, temperature: 0.2))
        return try OutputSanitizer.sanitizedNonEmpty(raw)
    }
}

/// Shared system prompts for the reasoning, critique, and synthesis stages. The mode-specific
/// part is `OutputMode.synthesisInstruction`; everything here enforces the same no-fabrication
/// contract as the refinement step, extended with "flag anything not grounded in the input".
enum PipelinePrompts {
    static let reasoningSystem = """
    You are reasoning about what a software developer said while thinking out loud. Using ONLY \
    what they said (provided below), do four things, concisely:
    1. Frame the core problem or decision precisely.
    2. Lay out the options the speaker raised, each with its trade-offs as they described them.
    3. Give a recommendation ONLY if the speaker leaned toward one; otherwise present the \
    trade-off neutrally and say the choice is open.
    4. List the risks and unknowns the speaker raised.

    Ground every sentence in what was actually said. Do NOT invent options, data, numbers, \
    causes, or conclusions the speaker did not state, and do NOT answer the speaker's open \
    questions or resolve their uncertainties. This is internal analysis that will be synthesized \
    later — be structured and terse. Output only the analysis.

    /no_think
    """

    static let critiqueSystem = """
    You are a strict fact-checker. You are given a SOURCE (the only ground truth — what the \
    speaker actually said) and a DRAFT derived from it. Return a corrected version of the DRAFT \
    that removes anything not grounded in the SOURCE: invented facts, numbers, names, scope, \
    causes, or conclusions; overclaims or false confidence; and any place the draft answered an \
    open question or resolved an uncertainty the speaker left open. Keep everything that IS \
    grounded, in the same structure and format. Do NOT add anything new. Output only the \
    corrected draft.

    /no_think
    """

    static func synthesisSystem(instruction: String, glossary: String) -> String {
        let glossaryBlock = PromptFragments.glossaryBlock(glossary)
        return """
        You produce a final artifact from what a software developer said while thinking out loud. \
        The input below is the only ground truth.

        === THE ARTIFACT TO PRODUCE ===
        \(instruction)

        === WORK ONLY WITH WHAT WAS SAID ===
        Use only the information in the input. Do NOT add claims, facts, numbers, dates, names, \
        scope, causes, conclusions, or recommendations the speaker did not state. Do not answer \
        their open questions or resolve their uncertainties. If the input is thin, the artifact is \
        short — never pad. Faithfulness always outranks completeness.

        === OUTPUT FORMAT — ABSOLUTE (copied directly to the clipboard) ===
        Return ONLY the artifact. No preamble ("Here is…"), no closing remarks, no notes about \
        what you did. The first character of your reply is the first character of the artifact.\(glossaryBlock)

        /no_think
        """
    }
}
