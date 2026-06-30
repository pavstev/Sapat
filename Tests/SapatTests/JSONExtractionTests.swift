import XCTest
@testable import Sapat

/// The lenient JSON scanner/decoder that backs structured generation. It must find the JSON
/// inside prose / code fences / reasoning blocks, and never miscount braces that appear inside
/// string literals — otherwise the whole structured-extraction pipeline (§6) is unreliable.
final class JSONExtractionTests: XCTestCase {
    func testPlainObject() {
        XCTAssertEqual(JSONExtraction.firstJSON(in: #"{"a":1}"#), #"{"a":1}"#)
    }

    func testProseAround() {
        XCTAssertEqual(JSONExtraction.firstJSON(in: #"Sure! Here you go: {"a":1} — done."#), #"{"a":1}"#)
    }

    func testCodeFence() {
        XCTAssertEqual(JSONExtraction.firstJSON(in: "```json\n{\"a\":[1,2]}\n```"), #"{"a":[1,2]}"#)
    }

    func testBraceInsideStringDoesNotBreakBalance() {
        XCTAssertEqual(JSONExtraction.firstJSON(in: #"{"k":"a}b{c"}"#), #"{"k":"a}b{c"}"#)
    }

    func testEscapedQuoteInsideString() {
        let input = #"{"k":"he said \"hi}\""}"#
        XCTAssertEqual(JSONExtraction.firstJSON(in: input), input)
    }

    func testNestedStructures() {
        let json = #"{"a":{"b":[1,{"c":2}]}}"#
        XCTAssertEqual(JSONExtraction.firstJSON(in: "x \(json) y"), json)
    }

    func testThinkBlockIsSkipped() {
        // A brace inside a reasoning block must not be mistaken for the JSON start.
        let input = "<think>let me consider {this}</think>\n{\"real\":true}"
        XCTAssertEqual(JSONExtraction.firstJSON(in: input), #"{"real":true}"#)
    }

    func testNoJSONReturnsNil() {
        XCTAssertNil(JSONExtraction.firstJSON(in: "there is no json here"))
    }

    private struct Sample: Decodable, Equatable { let name: String; let count: Int }

    func testDecodeFromMessyText() {
        let text = "Here is the result:\n```json\n{\"name\":\"x\",\"count\":3}\n```\nHope that helps!"
        XCTAssertEqual(JSONExtraction.decode(Sample.self, from: text), Sample(name: "x", count: 3))
    }

    func testDecodeFailsOnGarbage() {
        XCTAssertNil(JSONExtraction.decode(Sample.self, from: "no structured data at all"))
    }

    func testJSONValueSerialization() {
        let schema = JSONValue.object(
            properties: [
                ("intent", .type("string", description: "the core intent")),
                ("topics", .arrayOf(.type("string"))),
            ],
            required: ["intent", "topics"])
        let json = schema.jsonString
        // Round-trips to valid JSON with the expected shape.
        let data = json.data(using: .utf8)!
        let object = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(object["type"] as? String, "object")
        XCTAssertEqual((object["required"] as? [String]) ?? [], ["intent", "topics"])
        XCTAssertEqual(object["additionalProperties"] as? Bool, false)
    }
}
