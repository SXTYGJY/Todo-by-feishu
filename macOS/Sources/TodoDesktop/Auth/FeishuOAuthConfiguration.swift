import Foundation

struct FeishuOAuthConfiguration {
    let callbackHost: String
    let callbackPort: UInt16
    let callbackPath: String
    let scopes: [String]

    var redirectURI: String {
        "http://\(callbackHost):\(callbackPort)\(callbackPath)"
    }

    static let standard = FeishuOAuthConfiguration(
        callbackHost: "127.0.0.1",
        callbackPort: 43827,
        callbackPath: "/oauth/callback",
        scopes: ["bitable:app:readonly", "bitable:app", "offline_access"]
    )

    func authorizationURL(appID: String, state: String, codeChallenge: String) throws -> URL {
        var components = URLComponents(string: "https://accounts.feishu.cn/open-apis/authen/v1/authorize")!
        components.queryItems = [
            URLQueryItem(name: "app_id", value: appID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: scopes.joined(separator: " ")),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256")
        ]
        guard let url = components.url else { throw OAuthError.invalidAuthorizationURL }
        return url
    }
}

enum OAuthError: LocalizedError {
    case randomGenerationFailed
    case invalidAuthorizationURL
    case callbackAlreadyRunning
    case callbackTimedOut
    case invalidCallback
    case stateMismatch
    case authorizationDenied
    case invalidAppCredentials(String)
    case tokenExchangeFailed(String)
    case identityLookupFailed(String)

    var errorDescription: String? {
        switch self {
        case .randomGenerationFailed: return "无法生成安全授权信息，请稍后重试。"
        case .invalidAuthorizationURL: return "无法创建飞书授权链接。"
        case .callbackAlreadyRunning: return "飞书授权已经在进行中。"
        case .callbackTimedOut: return "等待飞书授权超时，请重试。"
        case .invalidCallback: return "飞书没有返回有效的授权结果。"
        case .stateMismatch: return "授权回调校验失败，请重新发起授权。"
        case .authorizationDenied: return "你取消了飞书授权。"
        case .invalidAppCredentials(let message): return message
        case .tokenExchangeFailed(let message): return "飞书令牌交换失败：\(message)"
        case .identityLookupFailed(let message): return "读取飞书账号信息失败：\(message)"
        }
    }
}
