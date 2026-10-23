import Foundation

struct FeishuBitableClient {
    private let session: URLSession
    private let baseURL = URL(string: "https://open.feishu.cn/open-apis/bitable/v1")!

    init(session: URLSession = .shared) {
        self.session = session
    }

    func getView(appToken: String, tableID: String, viewID: String, accessToken: String) async throws -> BitableView {
        let path = "/apps/\(escaped(appToken))/tables/\(escaped(tableID))/views/\(escaped(viewID))"
        let response: APIEnvelope<ViewData> = try await get(path: path, query: [], accessToken: accessToken)
        guard let view = response.data?.view else {
            throw FeishuBitableError.invalidResponse("飞书未返回目标视图信息。")
        }
        return view
    }

    func listFields(appToken: String, tableID: String, accessToken: String) async throws -> [BitableField] {
        let path = "/apps/\(escaped(appToken))/tables/\(escaped(tableID))/fields"
        var fields: [BitableField] = []
        var pageToken: String?
        repeat {
            var query = [URLQueryItem(name: "page_size", value: "100")]
            if let pageToken { query.append(URLQueryItem(name: "page_token", value: pageToken)) }
            let response: APIEnvelope<ListData<BitableField>> = try await get(path: path, query: query, accessToken: accessToken)
            fields.append(contentsOf: response.data?.items ?? [])
            guard response.data?.hasMore == true else { break }
            guard let next = response.data?.pageToken, !next.isEmpty, next != pageToken else {
                throw FeishuBitableError.invalidResponse("读取字段分页时飞书没有返回有效的下一页标记。")
            }
            pageToken = next
        } while true
        return fields
    }

    func listRecords(appToken: String,
                     tableID: String,
                     viewID: String,
                     accessToken: String) async throws -> [BitableRecord] {
        let path = "/apps/\(escaped(appToken))/tables/\(escaped(tableID))/records"
        var records: [BitableRecord] = []
        var pageToken: String?
        var seen = Set<String>()
        repeat {
            var query = [
                URLQueryItem(name: "view_id", value: viewID),
                URLQueryItem(name: "page_size", value: "500")
            ]
            if let pageToken { query.append(URLQueryItem(name: "page_token", value: pageToken)) }
            let response: APIEnvelope<ListData<BitableRecord>> = try await get(path: path, query: query, accessToken: accessToken)
            for record in response.data?.items ?? [] where seen.insert(record.id).inserted {
                records.append(record)
            }
            guard response.data?.hasMore == true else { break }
            guard let next = response.data?.pageToken, !next.isEmpty, next != pageToken else {
                throw FeishuBitableError.invalidResponse("读取记录分页时飞书没有返回有效的下一页标记。")
            }
            pageToken = next
        } while true
        return records
    }

    func getRecord(appToken: String,
                   tableID: String,
                   recordID: String,
                   accessToken: String) async throws -> BitableRecord {
        let path = "/apps/\(escaped(appToken))/tables/\(escaped(tableID))/records/\(escaped(recordID))"
        let response: APIEnvelope<RecordData> = try await request(path: path,
                                                                   method: "GET",
                                                                   query: [],
                                                                   body: nil,
                                                                   accessToken: accessToken)
        guard let record = response.data?.record else {
            throw FeishuBitableError.invalidResponse("飞书未返回目标记录。")
        }
        return record
    }

    func updateRecord(appToken: String,
                      tableID: String,
                      recordID: String,
                      fields: [String: BitableValue],
                      accessToken: String) async throws -> BitableRecord {
        let path = "/apps/\(escaped(appToken))/tables/\(escaped(tableID))/records/\(escaped(recordID))"
        let body = try JSONEncoder().encode(RecordFieldsBody(fields: fields))
        let response: APIEnvelope<RecordData> = try await request(path: path,
                                                                   method: "PUT",
                                                                   query: [],
                                                                   body: body,
                                                                   accessToken: accessToken)
        guard let record = response.data?.record else {
            throw FeishuBitableError.invalidResponse("飞书未返回已更新的记录。")
        }
        return record
    }

    func createRecord(appToken: String,
                      tableID: String,
                      fields: [String: BitableValue],
                      clientToken: String,
                      accessToken: String) async throws -> BitableRecord {
        let path = "/apps/\(escaped(appToken))/tables/\(escaped(tableID))/records"
        let body = try JSONEncoder().encode(RecordFieldsBody(fields: fields))
        let response: APIEnvelope<RecordData> = try await request(path: path,
                                                                   method: "POST",
                                                                   query: [URLQueryItem(name: "client_token", value: clientToken)],
                                                                   body: body,
                                                                   accessToken: accessToken)
        guard let record = response.data?.record else {
            throw FeishuBitableError.invalidResponse("飞书未返回新建的记录。")
        }
        return record
    }

    func deleteRecord(appToken: String,
                      tableID: String,
                      recordID: String,
                      accessToken: String) async throws {
        let path = "/apps/\(escaped(appToken))/tables/\(escaped(tableID))/records/\(escaped(recordID))"
        let _: APIEnvelope<EmptyData> = try await request(path: path,
                                                           method: "DELETE",
                                                           query: [],
                                                           body: nil,
                                                           accessToken: accessToken)
    }

    private func get<T: Decodable>(path: String,
                                   query: [URLQueryItem],
                                   accessToken: String) async throws -> APIEnvelope<T> {
        try await request(path: path, method: "GET", query: query, body: nil, accessToken: accessToken)
    }

    private func request<T: Decodable>(path: String,
                                       method: String,
                                       query: [URLQueryItem],
                                       body: Data?,
                                       accessToken: String) async throws -> APIEnvelope<T> {
        let endpoint = URL(string: baseURL.absoluteString + path)!
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = query.isEmpty ? nil : query
        var request = URLRequest(url: components.url!)
        request.httpMethod = method
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw FeishuBitableError.invalidResponse("飞书没有返回有效的 HTTP 响应。")
        }
        let envelope = try? JSONDecoder().decode(APIEnvelope<T>.self, from: data)
        guard (200..<300).contains(http.statusCode) else {
            throw FeishuBitableError.requestFailed(httpStatus: http.statusCode,
                                                   code: envelope?.code,
                                                   message: envelope?.message)
        }
        guard let envelope else {
            throw FeishuBitableError.invalidResponse("飞书返回的数据格式无法识别。")
        }
        guard envelope.code == 0 else {
            throw FeishuBitableError.requestFailed(httpStatus: http.statusCode,
                                                   code: envelope.code,
                                                   message: envelope.message)
        }
        return envelope
    }

    private func escaped(_ component: String) -> String {
        component.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? component
    }
}

private struct APIEnvelope<T: Decodable>: Decodable {
    let code: Int
    let message: String?
    let data: T?

    enum CodingKeys: String, CodingKey {
        case code
        case message = "msg"
        case data
    }
}

private struct ListData<Item: Decodable>: Decodable {
    let items: [Item]?
    let hasMore: Bool?
    let pageToken: String?

    enum CodingKeys: String, CodingKey {
        case items
        case hasMore = "has_more"
        case pageToken = "page_token"
    }
}

private struct ViewData: Decodable {
    let view: BitableView?
}

private struct RecordData: Decodable {
    let record: BitableRecord?
}

private struct RecordFieldsBody: Encodable {
    let fields: [String: BitableValue]
}

private struct EmptyData: Decodable {}

enum FeishuBitableError: LocalizedError {
    case requestFailed(httpStatus: Int, code: Int?, message: String?)
    case invalidResponse(String)
    case missingField(String)
    case incompatibleField(String)
    case duplicateBinding
    case mutationRejected(String)
    case mutationOutcomeUnknown(String)

    var errorDescription: String? {
        switch self {
        case .requestFailed(let status, let code, let message):
            let codeText = code.map { "飞书错误码 \($0)" } ?? "未提供飞书错误码"
            let messageText = message?.trimmingCharacters(in: .whitespacesAndNewlines)
            return "多维表格接口 HTTP \(status)（\(codeText)）\(messageText.map { "：\($0)" } ?? "。请确认链接、授权和表格权限。")"
        case .invalidResponse(let message): return message
        case .missingField(let name): return "未选择\(name)字段。"
        case .incompatibleField(let message): return message
        case .duplicateBinding: return "这个视图已在便签夹中。"
        case .mutationRejected(let message): return message
        case .mutationOutcomeUnknown(let message): return message
        }
    }
}
