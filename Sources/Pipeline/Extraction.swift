import Foundation

/// The structured extraction produced by the pipeline's **Extract** stage (§6). A typed,
/// JSON-schema-constrained view of what the speaker actually said — never invented. Decoding
/// is tolerant (missing fields default to empty) so a slightly-incomplete model reply still
/// yields a usable value rather than forcing a hard failure.
struct Extraction: Codable, Sendable, Equatable {
    /// The speaker's core intent, stated once, precisely.
    var intent: String
    var topics: [String]
    var decisions: [Decision]
    var openQuestions: [String]
    var actionItems: [ActionItem]
    var entities: [Entity]
    /// Things the speaker was unsure about; never invent answers.
    var uncertainties: [String]

    struct Decision: Codable, Sendable, Equatable {
        var decision: String
        var rationale: String
    }

    struct ActionItem: Codable, Sendable, Equatable {
        var task: String
        var owner: String?
        var context: String
    }

    struct Entity: Codable, Sendable, Equatable {
        var name: String
        /// person | system | tech | file | ticket | other
        var kind: String
    }

    enum CodingKeys: String, CodingKey {
        case intent, topics, decisions, entities, uncertainties
        case openQuestions = "open_questions"
        case actionItems = "action_items"
    }

    init(
        intent: String = "", topics: [String] = [], decisions: [Decision] = [],
        openQuestions: [String] = [], actionItems: [ActionItem] = [],
        entities: [Entity] = [], uncertainties: [String] = []
    ) {
        self.intent = intent
        self.topics = topics
        self.decisions = decisions
        self.openQuestions = openQuestions
        self.actionItems = actionItems
        self.entities = entities
        self.uncertainties = uncertainties
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        intent = (try? c.decode(String.self, forKey: .intent)) ?? ""
        topics = (try? c.decode([String].self, forKey: .topics)) ?? []
        decisions = (try? c.decode([Decision].self, forKey: .decisions)) ?? []
        openQuestions = (try? c.decode([String].self, forKey: .openQuestions)) ?? []
        actionItems = (try? c.decode([ActionItem].self, forKey: .actionItems)) ?? []
        entities = (try? c.decode([Entity].self, forKey: .entities)) ?? []
        uncertainties = (try? c.decode([String].self, forKey: .uncertainties)) ?? []
    }

    /// True when nothing of substance was extracted (so callers can decide to skip synthesis
    /// that depends on structure).
    var isEmpty: Bool {
        intent.isEmpty && topics.isEmpty && decisions.isEmpty && openQuestions.isEmpty
            && actionItems.isEmpty && entities.isEmpty && uncertainties.isEmpty
    }

    /// A compact, human-readable rendering for embedding in downstream reason/synthesize
    /// prompts (more digestible to the model than raw JSON).
    var promptText: String {
        var lines: [String] = []
        if !intent.isEmpty { lines.append("Intent: \(intent)") }
        if !topics.isEmpty { lines.append("Topics: \(topics.joined(separator: ", "))") }
        if !decisions.isEmpty {
            lines.append("Decisions:")
            for d in decisions {
                lines.append("  - \(d.decision)" + (d.rationale.isEmpty ? "" : " (because: \(d.rationale))"))
            }
        }
        if !openQuestions.isEmpty {
            lines.append("Open questions:")
            openQuestions.forEach { lines.append("  - \($0)") }
        }
        if !actionItems.isEmpty {
            lines.append("Action items:")
            for a in actionItems {
                let owner = a.owner.map { " [\($0)]" } ?? ""
                lines.append("  - \(a.task)\(owner)" + (a.context.isEmpty ? "" : " — \(a.context)"))
            }
        }
        if !entities.isEmpty {
            lines.append("Entities: " + entities.map { "\($0.name) (\($0.kind))" }.joined(separator: ", "))
        }
        if !uncertainties.isEmpty {
            lines.append("Uncertainties (do NOT resolve):")
            uncertainties.forEach { lines.append("  - \($0)") }
        }
        return lines.joined(separator: "\n")
    }
}

extension Extraction {
    /// The JSON Schema fed to `Inference.generateStructured`.
    static var schema: JSONSchema {
        let decision = JSONValue.object(
            properties: [("decision", .type("string")), ("rationale", .type("string"))],
            required: ["decision", "rationale"])
        let actionItem = JSONValue.object(
            properties: [
                ("task", .type("string")),
                ("owner", .object([("type", .array([.string("string"), .string("null")])),
                                   ("description", .string("who will do it, or null if unstated"))])),
                ("context", .type("string")),
            ],
            required: ["task", "owner", "context"])
        let entity = JSONValue.object(
            properties: [
                ("name", .type("string")),
                ("kind", .object([("type", .string("string")),
                                  ("enum", .array(["person", "system", "tech", "file", "ticket", "other"].map { .string($0) }))])),
            ],
            required: ["name", "kind"])
        return JSONSchema(name: "thought_extraction", schema: .object(
            properties: [
                ("intent", .type("string", description: "the speaker's core intent, stated once, precisely")),
                ("topics", .arrayOf(.type("string"))),
                ("decisions", .arrayOf(decision)),
                ("open_questions", .arrayOf(.type("string"))),
                ("action_items", .arrayOf(actionItem)),
                ("entities", .arrayOf(entity)),
                ("uncertainties", .arrayOf(.type("string", description: "things the speaker was unsure about; never invent answers"))),
            ],
            required: ["intent", "topics", "decisions", "open_questions", "action_items", "entities", "uncertainties"]))
    }

    /// The semantic instruction for the Extract stage. The schema + strict-JSON rules are
    /// appended by `Inference.generateStructured`; this supplies the no-fabrication contract.
    static let systemPrompt = """
    You read a cleaned statement of what a software developer said while thinking out loud, and \
    extract its structure. Work ONLY with what is in the text — this is the same no-fabrication \
    contract as the refinement step.

    - intent: the single core thing the speaker is trying to do or decide, stated once and precisely.
    - topics: the subjects discussed (short noun phrases).
    - decisions: choices the speaker actually made, each with the rationale they gave (empty rationale if none stated).
    - open_questions: questions the speaker raised and did not answer.
    - action_items: concrete tasks. owner is the named person responsible, or null if unstated. context is a short note grounding the task in what was said.
    - entities: named things — people, systems, technologies, files, tickets — with a kind from {person, system, tech, file, ticket, other}.
    - uncertainties: things the speaker explicitly was unsure about. NEVER resolve or answer them; just record them.

    Do NOT invent decisions, owners, tickets, numbers, or conclusions the speaker did not state. \
    If a field has nothing, return an empty array (or empty string for intent). Faithfulness to \
    what was said always outranks completeness.
    """
}
