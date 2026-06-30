import SwiftUI

/// How a mode's artifact should be rendered in the result card.
enum ArtifactRenderKind: Sendable { case plain, markdown, formatted }

extension OutputMode {
    var renderKind: ArtifactRenderKind {
        // Pure-refine (Polished English/Serbian) renders through the exact plain Text path —
        // never the markdown parser — so the output stays byte-for-byte unchanged.
        if isPureRefine { return .plain }
        switch id {
        case "engineering-report", "structured-brief": return .markdown
        default: return .formatted // standup, prompt-refiner
        }
    }
}

/// Renders an artifact per its mode's render kind. `.plain` is the same `Text` path used before
/// (locks the Polished-English byte-for-byte guarantee); `.markdown`/`.formatted` use a
/// lightweight per-line block renderer so headings, bold, and bullets read well without a heavy
/// whole-document parse that could drop the speaker's text.
struct ArtifactView: View {
    let text: String
    let kind: ArtifactRenderKind
    var font: Font = .system(size: 14)
    var color: Color = Theme.textPrimary

    var body: some View {
        switch kind {
        case .plain:
            Text(text)
                .font(font)
                .foregroundStyle(color)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .markdown, .formatted:
            MarkdownText(text)
        }
    }
}

/// A minimal, safe Markdown block renderer. Splits on newlines, classifies each line
/// (heading / bullet / blank / paragraph), and parses inline markup with
/// `AttributedString(markdown: interpretedSyntax: .inlineOnlyPreservingWhitespace)` inside a
/// `try?` with a plain fallback — so a malformed line never throws into the view and the
/// speaker's text is never lost. Deliberately avoids a whole-document parse (which collapses
/// headings and drops hard breaks on macOS).
struct MarkdownText: View {
    private let blocks: [Block]
    init(_ source: String) { blocks = MarkdownText.parse(source) }

    struct Block: Identifiable, Equatable {
        enum Kind: Equatable { case h1, h2, h3, bullet, paragraph, blank }
        let id: Int
        let kind: Kind
        let text: String
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.s2) {
            ForEach(blocks) { block in
                switch block.kind {
                case .blank:
                    Color.clear.frame(height: 2)
                case .h1:
                    heading(block.text, size: 15, weight: .bold)
                case .h2:
                    heading(block.text, size: 14, weight: .bold)
                case .h3:
                    heading(block.text, size: 13, weight: .semibold)
                case .bullet:
                    HStack(alignment: .top, spacing: Theme.s2) {
                        Text("•").font(.system(size: 13)).foregroundStyle(Theme.copperLight)
                        inline(block.text, size: 13)
                    }
                case .paragraph:
                    inline(block.text, size: 14)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }

    private func heading(_ text: String, size: CGFloat, weight: Font.Weight) -> some View {
        Text(MarkdownText.attributed(text))
            .font(.system(size: size, weight: weight))
            .foregroundStyle(Theme.textPrimary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func inline(_ text: String, size: CGFloat) -> some View {
        Text(MarkdownText.attributed(text))
            .font(.system(size: size))
            .foregroundStyle(Theme.textPrimary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    static func attributed(_ s: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: s, options: options)) ?? AttributedString(s)
    }

    /// Pure, testable line classifier.
    static func parse(_ source: String) -> [Block] {
        source.components(separatedBy: "\n").enumerated().map { index, raw in
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { return Block(id: index, kind: .blank, text: "") }
            if line.hasPrefix("### ") { return Block(id: index, kind: .h3, text: String(line.dropFirst(4))) }
            if line.hasPrefix("## ") { return Block(id: index, kind: .h2, text: String(line.dropFirst(3))) }
            if line.hasPrefix("# ") { return Block(id: index, kind: .h1, text: String(line.dropFirst(2))) }
            if line.hasPrefix("- ") || line.hasPrefix("* ") { return Block(id: index, kind: .bullet, text: String(line.dropFirst(2))) }
            // A fully-bold line reads as a heading (e.g. Standup's "**Yesterday**").
            if line.hasPrefix("**"), line.hasSuffix("**"), line.count > 4, !line.dropFirst(2).dropLast(2).contains("**") {
                return Block(id: index, kind: .h3, text: String(line.dropFirst(2).dropLast(2)))
            }
            return Block(id: index, kind: .paragraph, text: line)
        }
    }
}
