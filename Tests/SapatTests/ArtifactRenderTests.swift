import XCTest
@testable import Sapat

/// The UI-layer pure logic: which stages each mode runs (drives the live strip), how each mode's
/// artifact is rendered, and the Markdown line classifier. All pure — no views, no MLX.
final class ArtifactRenderTests: XCTestCase {
    func testPlannedStagesPerMode() {
        XCTAssertEqual(OutputModes.polishedEnglish.plannedStages, [.clean])
        XCTAssertEqual(OutputModes.polishedSerbian.plannedStages, [.clean])
        XCTAssertEqual(OutputModes.structuredBrief.plannedStages, [.clean, .extract, .retrieve, .synthesize])
        XCTAssertEqual(OutputModes.standup.plannedStages, [.clean, .extract, .retrieve, .synthesize])
        XCTAssertEqual(OutputModes.promptRefiner.plannedStages, [.clean, .retrieve, .synthesize])
        XCTAssertEqual(OutputModes.engineeringReport.plannedStages,
                       [.clean, .extract, .retrieve, .reason, .critique, .synthesize])
    }

    func testRenderKindPerMode() {
        XCTAssertEqual(OutputModes.polishedEnglish.renderKind, .plain)
        XCTAssertEqual(OutputModes.polishedSerbian.renderKind, .plain)
        XCTAssertEqual(OutputModes.engineeringReport.renderKind, .markdown)
        XCTAssertEqual(OutputModes.structuredBrief.renderKind, .markdown)
        XCTAssertEqual(OutputModes.standup.renderKind, .formatted)
        XCTAssertEqual(OutputModes.promptRefiner.renderKind, .formatted)
    }

    func testMarkdownLineClassification() {
        let blocks = MarkdownText.parse("""
        # Title
        ## Problem
        ### Detail
        - first
        * second
        **Yesterday**
        Just a paragraph.

        """)
        let kinds = blocks.map(\.kind)
        XCTAssertEqual(kinds, [.h1, .h2, .h3, .bullet, .bullet, .h3, .paragraph, .blank])
        XCTAssertEqual(blocks[1].text, "Problem")
        XCTAssertEqual(blocks[3].text, "first")
        XCTAssertEqual(blocks[5].text, "Yesterday", "a fully-bold line becomes a heading (Standup)")
    }

    func testPartiallyBoldLineStaysParagraph() {
        let blocks = MarkdownText.parse("This has **bold** in the middle")
        XCTAssertEqual(blocks.first?.kind, .paragraph)
    }
}
