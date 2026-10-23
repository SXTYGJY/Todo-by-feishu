import Foundation

enum ViewLinkKind: String, Codable {
    case base
    case wiki
}

struct ParsedViewLink: Codable, Equatable {
    let kind: ViewLinkKind
    let resourceToken: String
    let tableID: String
    let viewID: String
    let sourceURL: URL
}

struct ViewBinding: Codable, Identifiable {
    let id: String
    let accountKey: String
    let resourceKind: ViewLinkKind
    let resourceToken: String
    let tableID: String
    let viewID: String
    let sourceURL: URL
    var fieldMapping: FieldMapping?
    var viewName: String?
    let createdAt: Date
    var isDeleted: Bool

    init(link: ParsedViewLink,
         identity: FeishuIdentity,
         fieldMapping: FieldMapping? = nil,
         viewName: String? = nil) {
        id = UUID().uuidString.lowercased()
        accountKey = identity.storageKey
        resourceKind = link.kind
        resourceToken = link.resourceToken
        tableID = link.tableID
        viewID = link.viewID
        sourceURL = link.sourceURL
        self.fieldMapping = fieldMapping
        self.viewName = viewName
        createdAt = Date()
        isDeleted = false
    }
}

struct AccountWorkspace: Codable {
    let schemaVersion: Int
    let identity: FeishuIdentity
    var bindings: [ViewBinding]

    init(identity: FeishuIdentity, bindings: [ViewBinding] = []) {
        schemaVersion = 1
        self.identity = identity
        self.bindings = bindings
    }
}
