import SwiftUI

/// Inline, collapsible glossary editor — keeps configuration on the single screen (no Settings
/// window). Persists to `TranslationPreferences.glossaryKey`, which the Refiner and the
/// pipeline's synthesis stage already consume. One line per `term = preferred rendering`.
/// Collapsed by default, so it adds no height until opened.
struct GlossaryEditor: View {
    @AppStorage(TranslationPreferences.glossaryKey) private var glossary = ""
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isOpen = false

    private var termCount: Int {
        glossary.split(whereSeparator: \.isNewline)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.count
    }

    var body: some View {
        VStack(spacing: Theme.s1 + 2) {
            Button {
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.16)) { isOpen.toggle() }
            } label: {
                HStack(spacing: Theme.s2) {
                    Image(systemName: "character.book.closed").font(.system(size: 12)).foregroundStyle(Theme.textTertiary)
                    Text("Glossary").font(.system(size: 12)).foregroundStyle(Theme.textTertiary)
                    Spacer()
                    if termCount > 0 {
                        Text("\(termCount) term\(termCount == 1 ? "" : "s")")
                            .font(.system(size: 11)).foregroundStyle(Theme.copperLight)
                    }
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.textTertiary)
                        .rotationEffect(.degrees(isOpen ? 180 : 0))
                }
                .padding(.horizontal, Theme.s3)
                .padding(.vertical, Theme.s2)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .cardSurface(Theme.rSmall)
            .help("Names/terms Šapat should render a specific way")
            .accessibilityLabel("Glossary, \(termCount) terms")
            .accessibilityHint("Names and terms Šapat should render a specific way")

            if isOpen {
                VStack(alignment: .leading, spacing: Theme.s1) {
                    TextEditor(text: $glossary)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(Theme.textPrimary)
                        .scrollContentBackground(.hidden)
                        .frame(height: 80)
                        .padding(Theme.s2)
                        .background(RoundedRectangle(cornerRadius: Theme.rSmall - 2, style: .continuous).fill(Theme.stoneSunken))
                        .accessibilityLabel("Glossary terms")
                    Text("One per line, e.g. “k8s = Kubernetes”. Applied as terminology only — never as new facts.")
                        .font(.caption2)
                        .foregroundStyle(Theme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(Theme.s2)
                .cardSurface(Theme.rSmall)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }
}
