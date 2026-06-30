import SwiftUI

/// On-screen Output Mode selector — the app's single screen, so there's no Settings window. A
/// compact dropdown: tap to reveal the modes, hover any one to pop up a short explanation. The
/// choice persists via `@AppStorage` under the `modeKey` the `RecorderViewModel` reads, so the
/// next run picks it up live. (Generalizes the former five-tone `TonePicker` into the Output
/// Modes set without changing the popover layout.)
struct OutputModePicker: View {
    @AppStorage(TranslationPreferences.modeKey) private var modeRaw = OutputModes.default.id
    @State private var isOpen = false
    @State private var hovered: String?

    private var selected: OutputMode { OutputModes.mode(id: modeRaw) }

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
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textTertiary)
                Text("Mode")
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
        .help("Choose what Šapat turns your speech into")
    }

    // MARK: Expanded list of modes

    private var list: some View {
        VStack(spacing: 1) {
            ForEach(OutputModes.all) { mode in
                row(mode)
            }
        }
        .padding(Theme.s1)
        .cardSurface(Theme.rSmall)
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    private func row(_ mode: OutputMode) -> some View {
        let isSelected = mode.id == selected.id
        let isHover = hovered == mode.id
        return Button {
            modeRaw = mode.id
            isOpen = false
            hovered = nil
        } label: {
            HStack(spacing: Theme.s2) {
                Image(systemName: mode.icon)
                    .font(.system(size: 12))
                    .foregroundStyle(isSelected ? Theme.copper : Theme.copperLight)
                    .frame(width: 18)
                Text(mode.label)
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
            if inside { hovered = mode.id }
            else if hovered == mode.id { hovered = nil }
        }
        .popover(isPresented: hoverBinding(for: mode), arrowEdge: .trailing) {
            explanation(mode)
        }
    }

    private func hoverBinding(for mode: OutputMode) -> Binding<Bool> {
        Binding(
            get: { hovered == mode.id },
            set: { presented in if !presented, hovered == mode.id { hovered = nil } }
        )
    }

    private func explanation(_ mode: OutputMode) -> some View {
        VStack(alignment: .leading, spacing: Theme.s2) {
            HStack(spacing: Theme.s2) {
                Image(systemName: mode.icon)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.copperLight)
                Text(mode.label)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
            }
            Text(mode.summary)
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(mode.example)
                .font(.caption2)
                .italic()
                .foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Theme.s3)
        .frame(width: 260, alignment: .leading)
        .background(Theme.stoneRaised)
        .environment(\.colorScheme, .dark)
    }
}
