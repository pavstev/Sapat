import SwiftUI

/// Horizontal pipeline-stage stepper: shows each planned stage as a node that is done / active /
/// pending as the pipeline advances. Self-hides for a single stage, so pure-refine modes
/// (Polished English/Serbian) show nothing new.
struct StageStrip: View {
    let stages: [PipelineStage]
    let current: PipelineStage?

    var body: some View {
        if stages.count > 1 {
            HStack(spacing: 2) {
                ForEach(Array(stages.enumerated()), id: \.offset) { index, stage in
                    node(stage)
                    if index < stages.count - 1 {
                        Rectangle()
                            .fill(Theme.hairline)
                            .frame(height: 1)
                            .frame(maxWidth: .infinity)
                    }
                }
            }
            .padding(.horizontal, Theme.s3)
            .padding(.vertical, Theme.s2)
            .cardSurface(Theme.rSmall)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Pipeline progress")
            .accessibilityValue(current.map { "\($0.label)…" } ?? "starting")
        }
    }

    private enum NodeState { case done, active, pending }

    private func state(of stage: PipelineStage) -> NodeState {
        guard let current,
              let currentIndex = stages.firstIndex(of: current),
              let stageIndex = stages.firstIndex(of: stage)
        else { return .pending }
        if stageIndex < currentIndex { return .done }
        if stageIndex == currentIndex { return .active }
        return .pending
    }

    private func node(_ stage: PipelineStage) -> some View {
        let nodeState = state(of: stage)
        return VStack(spacing: 2) {
            ZStack {
                Circle()
                    .fill(nodeState == .done ? Theme.copper
                          : Theme.copperLight.opacity(nodeState == .active ? 0.20 : 0.06))
                    .frame(width: 18, height: 18)
                switch nodeState {
                case .done:
                    Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.stone)
                case .active:
                    ProgressView().controlSize(.mini).scaleEffect(0.55)
                case .pending:
                    Image(systemName: stage.icon).font(.system(size: 8)).foregroundStyle(Theme.textTertiary)
                }
            }
            Text(stage.label)
                .font(.system(size: 8, weight: nodeState == .active ? .semibold : .regular))
                .foregroundStyle(nodeState == .pending ? Theme.textTertiary : Theme.copperLight)
                .lineLimit(1)
        }
        .frame(width: 46)
    }
}
