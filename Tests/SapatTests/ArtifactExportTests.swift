import XCTest
@testable import Sapat

/// Export/share formatting — must reproduce the artifact verbatim and invent nothing beyond
/// structural headings (the no-fabrication ethos extends to what we export).
final class ArtifactExportTests: XCTestCase {
    func testPlainTextIsArtifactVerbatim() {
        XCTAssertEqual(ArtifactExport.plainText("Ship the queue."), "Ship the queue.")
    }

    func testMarkdownIncludesArtifactAndSerbianSource() {
        let md = ArtifactExport.markdown(
            artifact: "The queue ships.", serbian: "Red se šalje.",
            title: "Engineering report", source: "on-device")
        XCTAssertTrue(md.hasPrefix("# Engineering report"))
        XCTAssertTrue(md.contains("The queue ships."))
        XCTAssertTrue(md.contains("## Source (Serbian)"))
        XCTAssertTrue(md.contains("Red se šalje."))
        XCTAssertTrue(md.contains("on-device"))
    }

    func testMarkdownOmitsEmptySerbianAndSource() {
        let md = ArtifactExport.markdown(artifact: "ABC", serbian: "   ", title: "T", source: nil)
        XCTAssertEqual(md, "# T\n\nABC\n", "no Serbian section, no source line, no invented body")
    }

    func testSuggestedFilenameIsFilesystemSafe() {
        XCTAssertEqual(ArtifactExport.suggestedFilename(title: "Engineering Report!"), "sapat-engineering-report")
        XCTAssertEqual(ArtifactExport.suggestedFilename(title: "   "), "sapat-note")
    }
}
