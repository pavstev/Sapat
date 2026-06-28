import XCTest
@testable import Sapat

/// Guards the History record's persistence contract — most importantly that history files
/// written before failure-tracking existed still load (decoding as completed), and that the
/// recording link a failed entry needs for Retry round-trips intact.
final class TranslationRecordTests: XCTestCase {
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    /// A legacy entry (only the original keys, no `status`) must decode as a completed
    /// translation rather than throwing — old history.json files predate the new fields.
    func testLegacyRecordDecodesAsCompleted() throws {
        let legacy = """
        {
          "id": "F1E2D3C4-0000-0000-0000-000000000001",
          "date": 760000000,
          "serbian": "Здраво",
          "english": "Hello",
          "model": "openai_whisper-large-v3",
          "source": "LM Studio"
        }
        """.data(using: .utf8)!

        let record = try decoder.decode(TranslationRecord.self, from: legacy)
        XCTAssertEqual(record.status, .completed)
        XCTAssertFalse(record.isFailed)
        XCTAssertNil(record.errorMessage)
        XCTAssertNil(record.audioFileName)
        XCTAssertNil(record.audioURL)
        XCTAssertEqual(record.english, "Hello")
    }

    /// A failed entry's status, error, and recording link must survive a save/load cycle so
    /// it can still be retried after a relaunch.
    func testFailedRecordRoundTrips() throws {
        let original = TranslationRecord(
            date: Date(timeIntervalSince1970: 760_000_000),
            serbian: "Текст",
            english: "",
            model: "openai_whisper-large-v3",
            source: "LM Studio",
            status: .failed,
            errorMessage: "LM Studio isn't running.",
            audioFileName: "rec-20260628-120000-abc123.wav"
        )

        let decoded = try decoder.decode(TranslationRecord.self, from: encoder.encode(original))
        XCTAssertEqual(decoded, original)
        XCTAssertTrue(decoded.isFailed)
        XCTAssertEqual(decoded.errorMessage, "LM Studio isn't running.")
        XCTAssertEqual(decoded.audioURL?.lastPathComponent, "rec-20260628-120000-abc123.wav")
    }

    /// An imported entry resolves its audio straight from the stored absolute path (we point
    /// at the user's own file rather than copying it).
    func testImportedRecordResolvesAudioPath() {
        let path = "/tmp/some/meeting.m4a"
        let record = TranslationRecord(
            date: Date(timeIntervalSince1970: 760_000_000),
            serbian: "",
            english: "",
            model: "openai_whisper-large-v3",
            source: "LM Studio",
            status: .failed,
            importedPath: path,
            importedFileName: "meeting.m4a"
        )
        XCTAssertEqual(record.audioURL?.path, path)
    }
}
