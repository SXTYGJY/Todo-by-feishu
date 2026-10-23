import Foundation

struct FeishuTokenClient {
    private let appID: String
    private let appSecret: String
    private let session: URLSession

    init(appID: String,
         appSecret: String,
         session: URLSession = .shared) {
        self.appID = appID
        self.appSecret = appSecret
        self.session = session
    }

    func exchange(code: String, redirectURI: String, codeVerifier: String) async throws -> RawFeishuTokens {
        return try await requestUserToken(
            body: [
                "grant_type": "authorization_code",
                "client_id": appID,
                "client_secret": appSecret,
                "code": code,
                "redirect_uri": redirectURI,
                "code_verifier": codeVerifier
            ]
        )
    }

    func refresh(_ refreshToken: String) async throws -> RawFeishuTokens {
        return try await requestUserToken(
            body: [
                "grant_type": "refresh_token",
                "client_id": appID,
                "client_secret": appSecret,
                "refresh_token": refreshToken
            ]
        )
    }

    func userInfo(accessToken: String) async throws -> FeishuUserInfo {
        var request = URLRequest(url: URL(string: "https://open.feishu.cn/open-apis/authen/v1/user_info")!)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let data = try await send(request)
        let envelope = try JSONDecoder().decode(FeishuEnvelope<FeishuUserInfo>.self, from: data)
        guard envelope.code == 0, let user = envelope.data else {
            throw OAuthError.identityLookupFailed(envelope.message ?? "飞书返回错误。")
        }
        return user
    }

    private func requestUserToken(body: [String: String]) async throws -> RawFeishuTokens {
        var request = URLRequest(url: URL(string: "https://open.feishu.cn/open-apis/authen/v2/oauth/token")!)
        request.httpMethod = "POST"
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let data = try await send(request)
        let response = try JSONDecoder().decode(FeishuTokenResponse.self, from: data)
        guard response.code == 0, let tokens = response.tokenSet, !tokens.accessToken.isEmpty else {
            throw OAuthError.tokenExchangeFailed(response.message ?? "令牌响应格式无效。")
        }
        return tokens
    }

    private func send(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw OAuthError.tokenExchangeFailed("飞书没有返回有效的 HTTP 响应。")
        }
        guard (200..<300).contains(http.statusCode) else {
            // 只展示接口路径和飞书错误信息；绝不打印请求体、令牌或 App Secret。
            let details = (try? JSONDecoder().decode(FeishuHTTPErrorResponse.self, from: data))
            let description = [details?.message, details?.troubleshooter, details?.logID.map { "log_id: \($0)" }]
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            let code = details?.code.map(String.init) ?? "未知"
            let path = request.url?.path ?? "未知接口"
            throw OAuthError.tokenExchangeFailed("接口 \(path) 返回 HTTP \(http.statusCode)，飞书错误码 \(code)。\(description)")
        }
        return data
    }
}

private struct FeishuHTTPErrorResponse: Decodable {
    let code: Int?
    let message: String?
    let troubleshooter: String?
    let logID: String?

    enum CodingKeys: String, CodingKey {
        case code
        case message = "msg"
        case error
    }

    enum ErrorKeys: String, CodingKey {
        case troubleshooter
        case logID = "log_id"
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        code = try? values.decode(Int.self, forKey: .code)
        message = try? values.decode(String.self, forKey: .message)
        if let nested = try? values.nestedContainer(keyedBy: ErrorKeys.self, forKey: .error) {
            troubleshooter = try? nested.decode(String.self, forKey: .troubleshooter)
            logID = try? nested.decode(String.self, forKey: .logID)
        } else {
            troubleshooter = nil
            logID = nil
        }
    }
}

struct RawFeishuTokens: Decodable {
    let accessToken: String
    let refreshToken: String
    let expiresIn: TimeInterval
    let refreshExpiresIn: TimeInterval?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
        case refreshExpiresIn = "refresh_token_expires_in"
    }
}

private struct FeishuTokenResponse: Decodable {
    let code: Int
    let message: String?
    private let data: RawFeishuTokens?
    private let directAccessToken: String?
    private let directRefreshToken: String?
    private let directExpiresIn: TimeInterval?
    private let directRefreshExpiresIn: TimeInterval?

    var tokenSet: RawFeishuTokens? {
        if let data { return data }
        guard let accessToken = directAccessToken,
              let refreshToken = directRefreshToken,
              let expiresIn = directExpiresIn else { return nil }
        return RawFeishuTokens(accessToken: accessToken,
                               refreshToken: refreshToken,
                               expiresIn: expiresIn,
                               refreshExpiresIn: directRefreshExpiresIn)
    }

    enum CodingKeys: String, CodingKey {
        case code
        case message = "msg"
        case data
        case directAccessToken = "access_token"
        case directRefreshToken = "refresh_token"
        case directExpiresIn = "expires_in"
        case directRefreshExpiresIn = "refresh_token_expires_in"
    }
}

struct FeishuUserInfo: Decodable {
    let openID: String
    let tenantKey: String?
    let name: String?

    enum CodingKeys: String, CodingKey {
        case openID = "open_id"
        case tenantKey = "tenant_key"
        case name
    }
}

private struct FeishuEnvelope<T: Decodable>: Decodable {
    let code: Int
    let message: String?
    let data: T?
    enum CodingKeys: String, CodingKey {
        case code
        case message = "msg"
        case data
    }
}
