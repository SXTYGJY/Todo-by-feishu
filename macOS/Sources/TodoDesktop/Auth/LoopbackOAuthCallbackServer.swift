import Foundation
import Network

struct OAuthCallback {
    let code: String
    let state: String
}

final class LoopbackOAuthCallbackServer: @unchecked Sendable {
    private let host: String
    private let port: UInt16
    private let path: String
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "com.todo-desktop.oauth-callback")
    private var readyContinuation: CheckedContinuation<Void, Error>?
    private var callbackContinuation: CheckedContinuation<OAuthCallback, Error>?
    private var timeout: DispatchWorkItem?
    private var completedResult: Result<OAuthCallback, Error>?
    private var finished = false
    private var expectedState = ""

    init(host: String, port: UInt16, path: String) {
        self.host = host
        self.port = port
        self.path = path
    }

    func start() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                guard self.listener == nil else {
                    continuation.resume(throwing: OAuthError.callbackAlreadyRunning)
                    return
                }
                self.finished = false
                self.readyContinuation = continuation
                do {
                    let endpointPort = NWEndpoint.Port(rawValue: self.port)!
                    let parameters = NWParameters.tcp
                    parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: endpointPort)
                    let listener = try NWListener(using: parameters)
                    self.listener = listener
                    listener.newConnectionHandler = { [weak self] connection in
                        self?.handle(connection)
                    }
                    listener.stateUpdateHandler = { [weak self] state in
                        guard let self else { return }
                        switch state {
                        case .ready:
                            let continuation = self.readyContinuation
                            self.readyContinuation = nil
                            continuation?.resume()
                        case .failed(let error):
                            let continuation = self.readyContinuation
                            self.readyContinuation = nil
                            continuation?.resume(throwing: error)
                            self.finish(.failure(error))
                        default:
                            break
                        }
                    }
                    listener.start(queue: self.queue)
                } catch {
                    self.readyContinuation = nil
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func arm(expectedState: String, timeout seconds: TimeInterval = 180) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                guard self.listener != nil, self.callbackContinuation == nil else {
                    continuation.resume(throwing: OAuthError.callbackAlreadyRunning)
                    return
                }
                self.expectedState = expectedState
                self.completedResult = nil
                let timeout = DispatchWorkItem { [weak self] in
                    self?.finish(.failure(OAuthError.callbackTimedOut))
                }
                self.timeout = timeout
                self.queue.asyncAfter(deadline: .now() + seconds, execute: timeout)
                continuation.resume()
            }
        }
    }

    func waitForCallback() async throws -> OAuthCallback {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<OAuthCallback, Error>) in
            queue.async {
                if let completedResult = self.completedResult {
                    self.completedResult = nil
                    continuation.resume(with: completedResult)
                } else if self.callbackContinuation == nil {
                    self.callbackContinuation = continuation
                } else {
                    continuation.resume(throwing: OAuthError.callbackAlreadyRunning)
                }
            }
        }
    }

    func cancel() {
        queue.async { self.finish(.failure(CancellationError())) }
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, _, error in
            guard let self else { return }
            guard error == nil, let data,
                  let request = String(data: data, encoding: .utf8),
                  let firstLine = request.components(separatedBy: "\r\n").first,
                  let target = firstLine.split(separator: " ").dropFirst().first,
                  let components = URLComponents(string: "http://\(self.host)\(target)"),
                  components.path == self.path else {
                self.respond(connection, status: "404 Not Found", title: "找不到授权回调", message: "请关闭此页面，回到 Todo 重新发起登录。", kind: "error")
                return
            }
            let items = components.queryItems ?? []
            if items.contains(where: { $0.name == "error" && $0.value == "access_denied" }),
               items.first(where: { $0.name == "state" })?.value == self.expectedState {
                self.respond(connection, status: "200 OK", title: "授权已取消", message: "你可以关闭此页面，回到 Todo 后重新尝试。", kind: "neutral")
                self.finish(.failure(OAuthError.authorizationDenied))
                return
            }
            guard let code = items.first(where: { $0.name == "code" })?.value,
                  let state = items.first(where: { $0.name == "state" })?.value,
                  !code.isEmpty, !state.isEmpty else {
                self.respond(connection, status: "400 Bad Request", title: "没有收到完整授权信息", message: "请关闭此页面，回到 Todo 后重新尝试登录。", kind: "error")
                self.finish(.failure(OAuthError.invalidCallback))
                return
            }
            guard state == self.expectedState else {
                self.respond(connection, status: "400 Bad Request", title: "授权状态校验失败", message: "为保护账号安全，请关闭此页面并回到 Todo 重新登录。", kind: "error")
                return
            }
            self.respond(connection, status: "200 OK", title: "飞书登录成功", message: "账号已连接，可以关闭此页面并返回 Todo。", kind: "success")
            self.finish(.success(OAuthCallback(code: code, state: state)))
        }
    }

    private func respond(_ connection: NWConnection, status: String, title: String, message: String, kind: String) {
        let body = page(title: title, message: message, kind: kind)
        let bytes = Data(body.utf8)
        let header = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(bytes.count)\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\nContent-Security-Policy: default-src 'none'; style-src 'unsafe-inline'\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(header.utf8) + bytes, completion: .contentProcessed { _ in connection.cancel() })
    }

    private func page(title: String, message: String, kind: String) -> String {
        let safeTitle = escapeHTML(title)
        let safeMessage = escapeHTML(message)
        let symbol = kind == "success" ? "✓" : (kind == "error" ? "!" : "…")
        return """
        <!doctype html>
        <html lang="zh-CN">
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <meta name="color-scheme" content="light">
          <title>\(safeTitle) · Todo</title>
          <style>
            :root{font-family:-apple-system,BlinkMacSystemFont,"SF Pro Text","PingFang SC",sans-serif;color:#45453d;background:#f3f0df;font-synthesis:none;text-rendering:optimizeLegibility}
            *{box-sizing:border-box}
            body{min-height:100vh;margin:0;display:grid;place-items:center;padding:24px;background:radial-gradient(ellipse at 50% 0%,#fffbea 0,#f3f0df 68%)}
            main{width:min(100%,420px);padding:38px 34px 32px;text-align:center;background:#fffdf5;border:1px solid #e6e0cc;border-radius:22px;box-shadow:0 18px 55px #57533a18,0 2px 7px #57533a0d}
            .brand{margin:0 0 25px;color:#77866c;font-size:12px;font-weight:650;letter-spacing:.16em}
            .mark{width:54px;height:54px;margin:0 auto 17px;display:grid;place-items:center;border-radius:50%;font-size:27px;font-weight:500;background:#e8eee2;color:#607a63}
            .error .mark{background:#f5e9df;color:#a5664f}.neutral .mark{background:#efeee6;color:#858171}
            h1{margin:0;font-size:21px;font-weight:650;letter-spacing:.01em}
            p{margin:11px 0 0;color:#817e70;font-size:14px;line-height:1.75}
            .foot{margin-top:28px;padding-top:17px;border-top:1px solid #eee9d9;color:#a09b89;font-size:11px}
            @media(max-width:420px){main{padding:32px 24px 26px}h1{font-size:19px}}
          </style>
        </head>
        <body>
          <main class="\(kind)">
            <div class="brand">TODO · 桌面待办</div>
            <div class="mark" aria-hidden="true">\(symbol)</div>
            <h1>\(safeTitle)</h1>
            <p>\(safeMessage)</p>
            <div class="foot">此页面由 Todo 在本机生成，可以安全关闭。</div>
          </main>
        </body>
        </html>
        """
    }

    private func escapeHTML(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    private func finish(_ result: Result<OAuthCallback, Error>) {
        guard !finished else { return }
        finished = true
        timeout?.cancel()
        listener?.cancel()
        listener = nil
        let ready = readyContinuation
        readyContinuation = nil
        ready?.resume(with: result.map { _ in () })
        let callback = callbackContinuation
        callbackContinuation = nil
        if let callback {
            callback.resume(with: result)
        } else {
            completedResult = result
        }
    }
}
