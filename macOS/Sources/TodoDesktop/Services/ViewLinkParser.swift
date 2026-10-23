import Foundation

enum ViewLinkParseError: LocalizedError {
    case invalidURL
    case unsupportedDomain
    case unsupportedPath
    case missingResourceToken
    case missingTableID
    case missingViewID
    case ambiguousParameter(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "请粘贴 HTTPS 格式的飞书多维表格视图链接。"
        case .unsupportedDomain:
            return "链接必须来自飞书域名。"
        case .unsupportedPath:
            return "链接需要指向飞书 Base 或 wiki 页面。"
        case .missingResourceToken:
            return "链接中没有 Base 或 wiki 标识。"
        case .missingTableID:
            return "链接中没有数据表标识。"
        case .missingViewID:
            return "链接中没有视图标识。"
        case .ambiguousParameter(let name):
            return "链接中的 \(name) 参数不唯一。"
        }
    }
}

struct ViewLinkParser {
    func parse(_ text: String) throws -> ParsedViewLink {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: value),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "https",
              components.user == nil,
              components.password == nil,
              let hostValue = components.host else {
            throw ViewLinkParseError.invalidURL
        }

        let host = hostValue.lowercased()
        guard host == "feishu.cn" || host.hasSuffix(".feishu.cn") else {
            throw ViewLinkParseError.unsupportedDomain
        }

        let path = components.path.split(separator: "/").map(String.init)
        guard path.count >= 2 else { throw ViewLinkParseError.unsupportedPath }
        let kind: ViewLinkKind
        switch path[0].lowercased() {
        case "base": kind = .base
        case "wiki": kind = .wiki
        default: throw ViewLinkParseError.unsupportedPath
        }

        let resourceToken = path[1]
        guard Self.isIdentifier(resourceToken) else { throw ViewLinkParseError.missingResourceToken }
        let queryItems = components.queryItems ?? []
        guard let tableID = try Self.uniqueValue(in: queryItems, names: ["table", "table_id"]),
              Self.isIdentifier(tableID) else {
            throw ViewLinkParseError.missingTableID
        }
        guard let viewID = try Self.uniqueValue(in: queryItems, names: ["view", "view_id"]),
              Self.isIdentifier(viewID) else {
            throw ViewLinkParseError.missingViewID
        }

        return ParsedViewLink(kind: kind,
                              resourceToken: resourceToken,
                              tableID: tableID,
                              viewID: viewID,
                              sourceURL: url)
    }

    private static func uniqueValue(in items: [URLQueryItem], names: [String]) throws -> String? {
        let values = items
            .filter { names.contains($0.name.lowercased()) }
            .compactMap(\.value)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let distinct = Set(values)
        guard distinct.count <= 1 else { throw ViewLinkParseError.ambiguousParameter(names[0]) }
        return distinct.first
    }

    private static func isIdentifier(_ value: String) -> Bool {
        !value.isEmpty && value.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil
    }
}
