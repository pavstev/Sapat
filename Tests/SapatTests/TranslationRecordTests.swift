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
        XCTAssertEqual(record.source, .lmStudio, "legacy \"LM Studio\" string maps to the enum case")
    }

    /// Provenance is now a typed enum, persisted by rawValue, with a legacy mapper for the
    /// pre-2.0 free-form strings. Both must round-trip / map correctly.
    func testSourceEnumPersistenceAndLegacyMapping() throws {
        // New records round-trip by rawValue.
        for source: TranslationSource in [.mlx, .lmStudio, .cloud, .whisper] {
            let record = TranslationRecord(date: Date(timeIntervalSince1970: 1), serbian: "", english: "x",
                                           model: "m", source: source)
            XCTAssertEqual(try decoder.decode(TranslationRecord.self, from: encoder.encode(record)).source, source)
        }
        // Legacy free-form strings map to cases.
        XCTAssertEqual(TranslationSource(persisted: "LM Studio"), .lmStudio)
        XCTAssertEqual(TranslationSource(persisted: "Whisper"), .whisper)
        XCTAssertEqual(TranslationSource(persisted: "mlx"), .mlx)
        XCTAssertEqual(TranslationSource(persisted: ""), .lmStudio)
        XCTAssertEqual(TranslationSource(persisted: "garbage"), .lmStudio)
    }

    /// A failed entry's status, error, and recording link must survive a save/load cycle so
    /// it can still be retried after a relaunch.
    func testFailedRecordRoundTrips() throws {
        let original = TranslationRecord(
            date: Date(timeIntervalSince1970: 760_000_000),
            serbian: "Текст",
            english: "",
            model: "openai_whisper-large-v3",
            source: .lmStudio,
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

    /// The `pinned` flag is migration-safe: pre-pin history decodes as not pinned, and a set
    /// flag round-trips.
    func testPinnedIsMigrationSafe() throws {
        let legacy = """
        {"id":"F1E2D3C4-0000-0000-0000-000000000002","date":760000000,"serbian":"","english":"x","model":"m","source":"mlx"}
        """.data(using: .utf8)!
        XCTAssertFalse(try decoder.decode(TranslationRecord.self, from: legacy).pinned)

        let pinned = TranslationRecord(date: Date(timeIntervalSince1970: 1), serbian: "", english: "x",
                                       model: "m", source: .mlx, pinned: true)
        XCTAssertTrue(try decoder.decode(TranslationRecord.self, from: encoder.encode(pinned)).pinned)
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
            source: .lmStudio,
            status: .failed,
            importedPath: path,
            importedFileName: "meeting.m4a"
        )
        XCTAssertEqual(record.audioURL?.path, path)
    }
}
