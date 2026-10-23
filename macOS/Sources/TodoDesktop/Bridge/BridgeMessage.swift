import Foundation

struct BridgeRequest {
    let protocolVersion: Int
    let requestID: String
    let method: String
    let params: [String: Any]

    init?(body: Any) {
        guard let value = body as? [String: Any],
              let protocolVersion = value["protocolVersion"] as? Int,
              let requestID = value["requestId"] as? String,
              !requestID.isEmpty,
              let method = value["method"] as? String else {
            return nil
        }
        self.protocolVersion = protocolVersion
        self.requestID = requestID
        self.method = method
        params = value["params"] as? [String: Any] ?? [:]
    }
}

struct BridgeResponse {
    let requestID: String
    let ok: Bool
    let result: [String: Any]?
    let error: [String: String]?

    static func success(_ requestID: String, result: [String: Any] = [:]) -> BridgeResponse {
        BridgeResponse(requestID: requestID, ok: true, result: result, error: nil)
    }

    static func failure(_ requestID: String, code: String, message: String) -> BridgeResponse {
        BridgeResponse(requestID: requestID, ok: false, result: nil, error: ["code": code, "message": message])
    }

    var dictionary: [String: Any] {
        var value: [String: Any] = ["protocolVersion": 1, "requestId": requestID, "ok": ok]
        if let result { value["result"] = result }
        if let error { value["error"] = error }
        return value
    }
}
