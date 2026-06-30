import Foundation

/// The pipeline's user-visible stages, emitted as they run so the UI can light up a live
/// stepper instead of relying on an opaque progress string.
enum PipelineStage: String, Sendable, CaseIterable {
    case clean, extract, retrieve, reason, critique, synthesize

    /// Short present-tense label for the stage strip + status line.
    var label: String {
        switch self {
        case .clean: return "Cleaning"
        case .extract: return "Extracting"
        case .retrieve: return "Recalling"
        case .reason: return "Reasoning"
        case .critique: return "Checking"
        case .synthesize: return "Writing"
        }
    }

    /// SF Symbol for the stage node.
    var icon: String {
        switch self {
        case .clean: return "wand.and.sparkles"
        case .extract: return "list.bullet.rectangle"
        case .retrieve: return "brain"
        case .reason: return "lightbulb"
        case .critique: return "checkmark.shield"
        case .synthesize: return "doc.text"
        }
    }
}

/// A stage-entry event the pipeline emits. `retrievedCount` is populated on the `.retrieve`
/// event so the UI can show "informed by N past notes".
struct PipelineProgress: Sendable {
    let stage: PipelineStage
    let retrievedCount: Int?

    init(_ stage: PipelineStage, retrievedCount: Int? = nil) {
        self.stage = stage
        self.retrievedCount = retrievedCount
    }
}

extension OutputMode {
    /// The stages this mode will run, in order — drives the live stage strip. Pure-refine modes
    /// are a single Clean; synthesis modes always Retrieve (memory) and Synthesize, with
    /// Extract/Reason/Critique gated on the mode.
    var plannedStages: [PipelineStage] {
        guard !isPureRefine else { return [.clean] }
        var stages: [PipelineStage] = [.clean]
        if runsExtract { stages.append(.extract) }
        stages.append(.retrieve)
        if runsReason { stages.append(.reason) }
        if runsCritique { stages.append(.critique) }
        stages.append(.synthesize)
        return stages
    }
}
