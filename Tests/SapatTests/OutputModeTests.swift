import XCTest
@testable import Sapat

/// The Output Mode registry that replaces the five tones. Polished English must stay a
/// pure-refine mode (today's behaviour) and the registry must resolve + fall back cleanly.
final class OutputModeTests: XCTestCase {
    func testRegistryHasAllSixModes() {
        let ids = OutputModes.all.map(\.id)
        XCTAssertEqual(ids, [
            "polished-english", "polished-serbian", "structured-brief",
            "engineering-report", "prompt-refiner", "standup",
        ])
    }

    func testDefaultIsPolishedEnglish() {
        XCTAssertEqual(OutputModes.default.id, "polished-english")
        XCTAssertTrue(OutputModes.default.isPureRefine, "Polished English must be pure refine (no synthesis pass)")
        XCTAssertEqual(OutputModes.default.cleanLanguage, .english)
    }

    func testModeLookupFallsBackToDefault() {
        XCTAssertEqual(OutputModes.mode(id: "structured-brief").id, "structured-brief")
        XCTAssertEqual(OutputModes.mode(id: "does-not-exist").id, OutputModes.default.id)
    }

    func testPolishedSerbianCleansInSerbianAndIsPureRefine() {
        let mode = OutputModes.mode(id: "polished-serbian")
        XCTAssertEqual(mode.cleanLanguage, .serbian)
        XCTAssertTrue(mode.isPureRefine)
    }

    func testEngineeringReportRunsThinkingStages() {
        let mode = OutputModes.mode(id: "engineering-report")
        XCTAssertTrue(mode.runsExtract)
        XCTAssertTrue(mode.runsReason)
        XCTAssertTrue(mode.runsCritique)
        XCTAssertFalse(mode.isPureRefine)
        XCTAssertNotNil(mode.synthesisInstruction)
    }

    func testStructuredBriefAndStandupExtractButDoNotReason() {
        for id in ["structured-brief", "standup"] {
            let mode = OutputModes.mode(id: id)
            XCTAssertTrue(mode.runsExtract, "\(id) should extract")
            XCTAssertFalse(mode.runsReason, "\(id) should not run the reason stage")
            XCTAssertFalse(mode.isPureRefine)
        }
    }

    func testEveryModeHasADistinctResultTitle() {
        let titles = OutputModes.all.map(\.resultTitle)
        XCTAssertEqual(Set(titles).count, titles.count, "result titles should be distinct")
    }
}
