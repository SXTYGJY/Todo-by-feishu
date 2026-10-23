import Foundation

enum BitableValue: Codable {
    case string(String)
    case integer(Int64)
    case number(Double)
    case boolean(Bool)
    case object([String: BitableValue])
    case array([BitableValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null; return }
        if let value = try? container.decode(Bool.self) { self = .boolean(value); return }
        if let value = try? container.decode(Int64.self) { self = .integer(value); return }
        if let value = try? container.decode(Double.self) { self = .number(value); return }
        if let value = try? container.decode(String.self) { self = .string(value); return }
        if let value = try? container.decode([String: BitableValue].self) { self = .object(value); return }
        if let value = try? container.decode([BitableValue].self) { self = .array(value); return }
        throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported Bitable field value")
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .integer(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .boolean(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    var text: String? {
        switch self {
        case .string(let value): return value
        case .object(let values): return values["text"]?.text
        default: return nil
        }
    }

    var timestampMilliseconds: Double? {
        switch self {
        case .integer(let value): return Double(value)
        case .number(let value): return value
        case .string(let value): return Double(value)
        default: return nil
        }
    }

    var numericValue: Double? {
        switch self {
        case .integer(let value): return Double(value)
        case .number(let value): return value
        case .string(let value): return Double(value)
        default: return nil
        }
    }
}

struct BitableOption: Decodable {
    let id: String
    let name: String
}

struct BitableFieldProperty: Decodable {
    let options: [BitableOption]?
}

struct BitableField: Decodable, Identifiable {
    let id: String
    let name: String
    let type: Int
    let property: BitableFieldProperty?

    enum CodingKeys: String, CodingKey {
        case id = "field_id"
        case name = "field_name"
        case type
        case property
    }
}

struct BitableView: Decodable {
    let id: String
    let name: String

    enum CodingKeys: String, CodingKey {
        case id = "view_id"
        case name = "view_name"
    }
}

struct BitableRecord: Decodable {
    let id: String
    let fields: [String: BitableValue]

    enum CodingKeys: String, CodingKey {
        case id
        case recordID = "record_id"
        case fields
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decodeIfPresent(String.self, forKey: .id)
            ?? values.decode(String.self, forKey: .recordID)
        fields = try values.decode([String: BitableValue].self, forKey: .fields)
    }
}

struct ProjectedTodo: Codable, Identifiable {
    let id: String
    let title: String
    let priority: String?
    let isDone: Bool
    let dateMilliseconds: Double
    let sourceOrder: Int
    var plannedDurationHours: Double? = nil
}

struct ProjectionIssue: Codable, Identifiable {
    let recordID: String
    let dateMilliseconds: Double?
    let reason: String

    var id: String { recordID }
}

struct ViewSnapshot: Codable {
    let fetchedAt: Date
    let items: [ProjectedTodo]
    var projectionIssues: [ProjectionIssue]? = nil
}

struct CompletionMutationResult {
    let snapshot: ViewSnapshot
    let isStale: Bool
    let warning: String?
}

struct TaskCreationResult {
    let recordID: String
    let snapshot: ViewSnapshot?
    let isStale: Bool
    let visibleInView: Bool
    let warning: String?
}

struct TaskMoveResult {
    let snapshot: ViewSnapshot
    let isStale: Bool
    let visibleInView: Bool
    let warning: String?
}

struct TaskMutationResult {
    let snapshot: ViewSnapshot
    let isStale: Bool
    let visibleInView: Bool
    let warning: String?
}

struct BindingInspection {
    let link: ParsedViewLink
    let view: BitableView
    let fields: [BitableField]

    func bridgeValue() -> [String: Any] {
        [
            "viewId": view.id,
            "viewName": view.name,
            "tableId": link.tableID,
            "fields": fields.map { field in
                [
                    "id": field.id,
                    "name": field.name,
                    "type": field.type,
                    "options": (field.property?.options ?? []).map { ["id": $0.id, "name": $0.name] }
                ] as [String: Any]
            }
        ]
    }
}

struct FieldMapping: Codable, Equatable {
    let taskFieldID: String
    let dateFieldID: String
    let priorityFieldID: String?
    let doneFieldID: String
    let doneOptionID: String
    let doneOptionName: String
    let undoneOptionID: String
    let undoneOptionName: String
    var taskFieldName: String? = nil
    var dateFieldName: String? = nil
    var priorityFieldName: String? = nil
    var doneFieldName: String? = nil
    var plannedDurationFieldID: String? = nil
    var plannedDurationFieldName: String? = nil
    var plannedDurationFieldChecked: Bool? = nil
}
