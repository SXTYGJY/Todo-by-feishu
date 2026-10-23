import Foundation
import WebKit

final class TodoBridgeHandler: NSObject, WKScriptMessageHandler {
    weak var webView: WKWebView?
    var onRequest: ((BridgeRequest) -> BridgeResponse)?
    var onAsyncRequest: ((BridgeRequest, @escaping (BridgeResponse) -> Void) -> Void)?
    var onTogglePinned: (() -> Void)?
    var onTaskContextMenu: ((String?, String?, Bool) -> Void)?

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        if let body = message.body as? [String: Any], body["action"] as? String == "togglePinned" {
            DispatchQueue.main.async { [weak self] in self?.onTogglePinned?() }
            return
        }
        if let body = message.body as? [String: Any], body["action"] as? String == "taskContextMenu" {
            let bindingID = body["bindingId"] as? String
            let recordID = body["recordId"] as? String
            let canMutate = body["canMutate"] as? Bool ?? false
            DispatchQueue.main.async { [weak self] in
                self?.onTaskContextMenu?(bindingID, recordID, canMutate)
            }
            return
        }

        guard let request = BridgeRequest(body: message.body) else { return }
        if request.protocolVersion == 1, let onAsyncRequest {
            DispatchQueue.main.async { [weak self] in
                onAsyncRequest(request) { [weak self] response in self?.send(response) }
            }
            return
        }
        let response: BridgeResponse
        if request.protocolVersion != 1 {
            response = .failure(request.requestID, code: "UNSUPPORTED_PROTOCOL", message: "不支持的桌面桥接协议版本。")
        } else {
            response = onRequest?(request) ?? .failure(request.requestID, code: "HOST_UNAVAILABLE", message: "桌面宿主暂不可用。")
        }
        send(response)
    }

    private func send(_ response: BridgeResponse) {
        guard let webView,
              JSONSerialization.isValidJSONObject(response.dictionary),
              let data = try? JSONSerialization.data(withJSONObject: response.dictionary, options: [.fragmentsAllowed]),
              let json = String(data: data, encoding: .utf8) else {
            return
        }
        DispatchQueue.main.async { [weak webView] in
            webView?.evaluateJavaScript("window.__todoNativeReceive && window.__todoNativeReceive(\(json));")
        }
    }

    func sendEvent(_ name: String, payload: [String: Any] = [:]) {
        var value: [String: Any] = ["event": name]
        value["payload"] = payload
        guard let webView,
              JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]),
              let json = String(data: data, encoding: .utf8) else {
            return
        }
        DispatchQueue.main.async { [weak webView] in
            webView?.evaluateJavaScript("window.__todoNativeEvent && window.__todoNativeEvent(\(json));")
        }
    }
}
