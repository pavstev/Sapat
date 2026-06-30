import XCTest
@testable import Sapat

/// The §6 structured-extraction type. Full decode, tolerant partial decode, and the readable
/// rendering used in downstream prompts.
final class ExtractionTests: XCTestCase {
    func testDecodesFullSchemaJSON() throws {
        let json = """
        {
          "intent": "ship the retry queue",
          "topics": ["infra", "webhooks"],
          "decisions": [{"decision": "use an idempotent handler", "rationale": "avoid duplicate side effects"}],
          "open_questions": ["which backoff strategy?"],
          "action_items": [{"task": "wire the handler", "owner": null, "context": "webhook path"}],
          "entities": [{"name": "retry queue", "kind": "system"}],
          "uncertainties": ["whether it scales"]
        }
        """
        let value = JSONExtraction.decode(Extraction.self, from: json)
        XCTAssertEqual(value?.intent, "ship the retry queue")
        XCTAssertEqual(value?.topics, ["infra", "webhooks"])
        XCTAssertEqual(value?.decisions.first?.rationale, "avoid duplicate side effects")
        XCTAssertEqual(value?.actionItems.first?.owner, nil)
        XCTAssertEqual(value?.entities.first?.kind, "system")
        XCTAssertEqual(value?.uncertainties, ["whether it scales"])
    }

    func testTolerantPartialDecode() throws {
        // Missing fields decode as empty rather than throwing.
        let json = #"{"intent":"do the thing","topics":["x"]}"#
        let value = JSONExtraction.decode(Extraction.self, from: json)
        XCTAssertEqual(value?.intent, "do the thing")
        XCTAssertEqual(value?.topics, ["x"])
        XCTAssertEqual(value?.decisions, [])
        XCTAssertEqual(value?.actionItems, [])
        XCTAssertEqual(value?.uncertainties, [])
    }

    func testIsEmpty() {
        XCTAssertTrue(Extraction().isEmpty)
        XCTAssertFalse(Extraction(intent: "x").isEmpty)
    }

    func testPromptTextRendersGroundedSections() {
        let extraction = Extraction(
            intent: "ship it",
            topics: ["infra"],
            decisions: [.init(decision: "use queue", rationale: "durability")],
            openQuestions: ["which db?"],
            actionItems: [.init(task: "wire it", owner: "stevan", context: "today")],
            entities: [.init(name: "Queue", kind: "system")],
            uncertainties: ["scaling"])
        let text = extraction.promptText
        XCTAssertTrue(text.contains("Intent: ship it"))
        XCTAssertTrue(text.contains("use queue (because: durability)"))
        XCTAssertTrue(text.contains("wire it [stevan] — today"))
        XCTAssertTrue(text.contains("Uncertainties (do NOT resolve):"))
    }

    func testSchemaIsValidJSON() throws {
        let data = Extraction.schema.jsonString.data(using: .utf8)!
        let object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(object["type"] as? String, "object")
        let required = object["required"] as? [String] ?? []
        XCTAssertTrue(required.contains("intent"))
        XCTAssertTrue(required.contains("action_items"))
    }
}
