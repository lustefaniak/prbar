import Foundation

/// JSON schemas for the rules directory's files, so an editor completes and
/// checks them as they are typed (`# yaml-language-server: $schema=…`).
/// Built from the same field lists the loader checks outputs against, so
/// the schema can't offer a field the loader refuses; the copies in
/// `docs/schema/rules/` are this output, checked by a test.
enum RuleSchema {
    enum File: String, CaseIterable, Sendable {
        case select, decide, lists
    }

    static let baseURL = "https://raw.githubusercontent.com/lustefaniak/prbar/main/docs/schema/rules/"

    static func url(_ file: File) -> String { baseURL + "\(file.rawValue).schema.json" }

    static func json(_ file: File) -> String {
        let object: [String: Any]
        switch file {
        case .select: object = policy(file, fields: RuleOutputs.select, title: "PRBar select rules",
                                      what: "whether PRBar reviews a pull request")
        case .decide: object = policy(file, fields: RuleOutputs.decide, title: "PRBar decide rules",
                                      what: "what PRBar posts once a review is in")
        case .lists: object = lists()
        }
        let data = (try? JSONSerialization.data(
            withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return (String(data: data, encoding: .utf8) ?? "{}") + "\n"
    }

    private static let guide = "https://github.com/lustefaniak/prbar/blob/main/docs/rules.md"

    private static func policy(_ file: File, fields: [RuleOutputs.Field], title: String, what: String) -> [String: Any] {
        let condition: [String: Any] = [
            "type": "string",
            "description": "A CEL expression that is true or false. The first match whose condition holds decides; a match without one always does. Facts and functions: \(guide)#reference-facts",
        ]
        var outputProperties: [String: Any] = [:]
        for field in fields {
            outputProperties[field.name] = property(field)
        }
        let output: [String: Any] = [
            "type": "object",
            "description": "What this rule decides.",
            "additionalProperties": false,
            "required": fields.filter(\.required).map(\.name),
            "properties": outputProperties,
        ]
        return [
            "$schema": "http://json-schema.org/draft-07/schema#",
            "$id": url(file),
            "title": title,
            "description": "A policy in rules/\(file.rawValue)/: \(what). The stage's files run in name order and the first match decides; with no match, the prbar.yaml settings do. Guide: \(guide)",
            "type": "object",
            "additionalProperties": false,
            "required": ["rule"],
            "properties": [
                "name": ["type": "string", "description": "The policy's name."],
                "description": ["type": "string"],
                "rule": ["$ref": "#/definitions/rule"],
            ],
            "definitions": [
                "rule": [
                    "type": "object",
                    "additionalProperties": false,
                    "required": ["match"],
                    "properties": [
                        "id": ["type": "string"],
                        "description": ["type": "string"],
                        "variables": [
                            "type": "array",
                            "description": "Named sub-expressions, read in conditions as variables.<name>.",
                            "items": ["$ref": "#/definitions/variable"],
                        ],
                        "match": [
                            "type": "array",
                            "description": "Tried top to bottom; the first whose condition holds decides.",
                            "items": ["$ref": "#/definitions/match"],
                        ],
                    ],
                ],
                "variable": [
                    "type": "object",
                    "additionalProperties": false,
                    "required": ["name", "expression"],
                    "properties": [
                        "name": ["type": "string", "pattern": "^[A-Za-z_][A-Za-z0-9_]*$"],
                        "expression": ["type": "string", "description": "A CEL expression."],
                        "description": ["type": "string"],
                    ],
                ],
                "match": [
                    "type": "object",
                    "additionalProperties": false,
                    "properties": [
                        "condition": condition,
                        "output": [
                            "description": "What this rule decides, as YAML fields, or as a quoted CEL expression for an output that has to be computed.",
                            "oneOf": [
                                ["$ref": "#/definitions/output"],
                                ["type": "string", "description": "A CEL map with the same fields, for an output that has to be computed: '{\"rule\": \"x\", \"action\": <a CEL expression>}'."],
                            ],
                        ],
                        "explanation": ["type": "string"],
                        "rule": [
                            "$ref": "#/definitions/rule",
                            "description": "Rules that apply only when this match's condition holds; when none of them matches, evaluation goes on after this match.",
                        ],
                    ],
                    "oneOf": [["required": ["output"]], ["required": ["rule"]]],
                ],
                "output": output,
            ],
        ]
    }

    private static func property(_ field: RuleOutputs.Field) -> [String: Any] {
        var out: [String: Any] = ["description": field.help]
        switch field.kind {
        case .string:
            out["type"] = "string"
        case .bool:
            out["type"] = "boolean"
        case .int:
            out["type"] = "integer"
            out["minimum"] = 0
        case .oneOf(let values):
            out["type"] = "string"
            out["enum"] = values
            if !field.values.isEmpty {
                out["description"] = field.help + " " + values.map { "\($0): \(field.values[$0] ?? "")" }.joined(separator: " ")
            }
        case .severity:
            let names = AnnotationSeverity.allCases.map(\.rawValue)
            out["type"] = "string"
            out["enum"] = names + names.map { "severity.\($0)" }
        }
        return out
    }

    private static func lists() -> [String: Any] {
        [
            "$schema": "http://json-schema.org/draft-07/schema#",
            "$id": url(.lists),
            "title": "PRBar rule lists",
            "description": "rules/lists.yaml: named lists of logins, repositories or anything else the rules compare against, read as lists.<name>. Guide: \(guide)",
            "type": "object",
            "additionalProperties": ["type": "array", "items": ["type": "string"]],
            "propertyNames": ["pattern": "^[A-Za-z_][A-Za-z0-9_]*$"],
        ]
    }
}
