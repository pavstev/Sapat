import SwiftUI

/// On-screen tone selector — the app's single screen, so there's no Settings window. A
/// compact dropdown: tap to reveal the five presets, hover any one to pop up a short
/// explanation of what it does. The choice persists via `@AppStorage` under the same
/// `toneKey` the `RecorderViewModel` reads, so the next refinement picks it up live.
struct TonePicker: View {
    @AppStorage(TranslationPreferences.toneKey) private var toneRaw = Tone.technical.rawValue
    @State private var isOpen = false
    /// The row the pointer is over — drives both the highlight and its explanation popup.
    @State private var hovered: Tone?

    private var selected: Tone { Tone(rawValue: toneRaw) ?? .technical }

    var body: some View {
        VStack(spacing: Theme.s1 + 2) {
            trigger
            if isOpen { list }
        }
        .animation(.easeInOut(duration: 0.16), value: isOpen)
    }

    // MARK: Trigger — the collapsed dropdown row

    private var trigger: some View {
        Button {
            isOpen.toggle()
            if !isOpen { hovered = nil }
        } label: {
            HStack(spacing: Theme.s2) {
                Image(systemName: "textformat")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textTertiary)
                Text("Tone")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textTertiary)
                Spacer()
                Image(systemName: selected.icon)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.copperLight)
                Text(selected.label)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
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
        .help("Choose how Šapat phrases the English")
    }

    // MARK: Expanded list of presets

    private var list: some View {
        VStack(spacing: 1) {
            ForEach(Tone.allCases) { tone in
                row(tone)
            }
        }
        .padding(Theme.s1)
        .cardSurface(Theme.rSmall)
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    private func row(_ tone: Tone) -> some View {
        let isSelected = tone == selected
        let isHover = hovered == tone
        return Button {
            toneRaw = tone.rawValue
            isOpen = false
            hovered = nil
        } label: {
            HStack(spacing: Theme.s2) {
                Image(systemName: tone.icon)
                    .font(.system(size: 12))
                    .foregroundStyle(isSelected ? Theme.copper : Theme.copperLight)
                    .frame(width: 18)
                Text(tone.label)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.copper)
                }
            }
            .padding(.horizontal, Theme.s2)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: Theme.rSmall - 2, style: .continuous)
                    .fill(isHover ? Theme.copperLight.opacity(0.10) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in
            if inside { hovered = tone }
            else if hovered == tone { hovered = nil }
        }
        .popover(isPresented: hoverBinding(for: tone), arrowEdge: .trailing) {
            explanation(tone)
        }
    }

    /// Presents the explanation while this row is hovered; lets SwiftUI clear the hover when
    /// it dismisses the popover itself.
    private func hoverBinding(for tone: Tone) -> Binding<Bool> {
        Binding(
            get: { hovered == tone },
            set: { presented in if !presented, hovered == tone { hovered = nil } }
        )
    }

    private func explanation(_ tone: Tone) -> some View {
        VStack(alignment: .leading, spacing: Theme.s2) {
            HStack(spacing: Theme.s2) {
                Image(systemName: tone.icon)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.copperLight)
                Text(tone.label)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
            }
            Text(tone.summary)
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(tone.example)
                .font(.caption2)
                .italic()
                .foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Theme.s3)
        .frame(width: 250, alignment: .leading)
        .background(Theme.stoneRaised)
        .environment(\.colorScheme, .dark)
    }
}
