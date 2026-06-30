import SwiftUI
import UniformTypeIdentifiers

/// Turns a finished job into shareable text + a Markdown document. Pure formatting over data the
/// view model already publishes — it invents nothing (parity with Copy / the no-fabrication ethos).
enum ArtifactExport {
    /// Plain text — exactly the artifact (byte-for-byte parity with Copy).
    static func plainText(_ artifact: String) -> String { artifact }

    /// A Markdown document: a heading (the mode), the artifact, and the Serbian source if present.
    static func markdown(artifact: String, serbian: String, title: String, source: String?) -> String {
        var doc = "# \(title)\n\n\(artifact)\n"
        let src = serbian.trimmingCharacters(in: .whitespacesAndNewlines)
        if !src.isEmpty { doc += "\n---\n\n## Source (Serbian)\n\n\(src)\n" }
        if let source, !source.isEmpty { doc += "\n_— refined \(source) with Šapat_\n" }
        return doc
    }

    /// A filesystem-safe filename stem (no extension).
    static func suggestedFilename(title: String) -> String {
        let safe = title.lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .filter { $0.isLetter || $0.isNumber || $0 == "-" }
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return safe.isEmpty ? "sapat-note" : "sapat-\(safe)"
    }
}

/// A tiny Markdown `FileDocument` for `.fileExporter` (Save as .md).
struct MarkdownDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.plainText] }
    static var writableContentTypes: [UTType] { [UTType(filenameExtension: "md") ?? .plainText] }

    var text: String
    init(_ text: String) { self.text = text }
    init(configuration: ReadConfiguration) throws {
        text = configuration.file.regularFileContents.map { String(decoding: $0, as: UTF8.self) } ?? ""
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}
