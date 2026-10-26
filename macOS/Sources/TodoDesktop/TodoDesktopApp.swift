import AppKit
import CoreFoundation
import WebKit
import UniformTypeIdentifiers
import UserNotifications

private struct PendingBindingInspection {
    let inspection: BindingInspection
    let viewURL: String
    let accountKey: String
    let expiresAt: Date
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuDelegate, WKUIDelegate {
    private let initialSize = NSSize(width: 310, height: 390)
    private let minimumSize = NSSize(width: 270, height: 260)
    private let frameKey = "TodoDesktop.windowFrame"
    private let pinnedKey = "TodoDesktop.windowPinned"
    private var window: NSWindow!
    private var webView: TodoNoteWebView!
    private var dockMenu = NSMenu()
    private var bridgeHandler: TodoBridgeHandler!
    private var authCoordinator: AuthCoordinator!
    private let viewLinkParser = ViewLinkParser()
    private let pendingViewLinkStore = PendingViewLinkStore()
    private let bindingService = BitableBindingService()
    private let activeBindingRepository = ActiveBindingRepository()
    private let notePreferencesRepository = NotePreferencesRepository()
    private let focusSessionRepository = FocusSessionRepository()
    private var staleBindingIDs = Set<String>()
    private var freshSnapshotBindingIDs = Set<String>()
    private var activeCompletionMutations: [String: String] = [:]
    private var activeFixedTaskGenerations = Set<String>()
    private var pendingBindingInspections: [String: PendingBindingInspection] = [:]
    private var focusTimer: Timer?
    private var notificationPermissionRequestStarted = false
    private var notificationCenter: UNUserNotificationCenter? {
        let bundle = Bundle.main
        guard bundle.bundleURL.pathExtension == "app",
              bundle.infoDictionary?["CFBundlePackageType"] as? String == "APPL",
              bundle.bundleIdentifier == "com.todo.desktop" else {
            return nil
        }
        return UNUserNotificationCenter.current()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let iconURL = Bundle.module.url(forResource: "AppIcon",
                                            withExtension: "png",
                                            subdirectory: "Resources"),
           let icon = NSImage(contentsOf: iconURL) {
            NSApp.applicationIconImage = icon
        }
        NSApp.setActivationPolicy(.regular)
        buildApplicationMenu()
        buildDockMenu()
        createWindow()
        showWindow()
        focusTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.tickFocusSession() }
        }
        NSWorkspace.shared.notificationCenter.addObserver(self,
                                                          selector: #selector(pauseFocusForSleep(_:)),
                                                          name: NSWorkspace.willSleepNotification,
                                                          object: nil)
    }

    func applicationWillTerminate(_ notification: Notification) {
        pauseActiveFocusSession()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows {
            showWindow()
        }
        return true
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        dockMenu
    }

    func webView(_ webView: WKWebView,
                 runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping ([URL]?) -> Void) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .webP]
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        completionHandler(panel.runModal() == .OK ? panel.urls : nil)
    }

    func webView(_ webView: WKWebView,
                 runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping (Bool) -> Void) {
        let alert = NSAlert()
        alert.messageText = "确认删除便签？"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "删除便签")
        alert.addButton(withTitle: "取消")
        completionHandler(alert.runModal() == .alertFirstButtonReturn)
    }

    func windowDidMove(_ notification: Notification) {
        saveWindowFrame()
    }

    func windowDidResize(_ notification: Notification) {
        saveWindowFrame()
    }

    func windowWillClose(_ notification: Notification) {
        saveWindowFrame()
    }

    @objc private func showWindow(_ sender: Any? = nil) {
        if window == nil {
            createWindow()
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(sender)
    }

    @objc private func hideWindow(_ sender: Any? = nil) {
        window.orderOut(sender)
    }

    @objc private func closeWindow(_ sender: Any? = nil) {
        window.close()
    }

    @objc private func togglePinned(_ sender: Any? = nil) {
        let pinned = window.level != .floating
        setPinned(pinned)
    }

    private func setPinned(_ pinned: Bool) {
        window.level = pinned ? .floating : .normal
        window.collectionBehavior = pinned ? [.canJoinAllSpaces, .fullScreenAuxiliary] : []
        UserDefaults.standard.set(pinned, forKey: pinnedKey)
        updatePinLabel(pinned: pinned)
    }

    private func showTaskContextMenu(bindingID: String?, recordID: String?, canMutate: Bool) {
        guard let webView, let window else { return }
        let menu = NSMenu()
        var contextTodo: ProjectedTodo?
        if let bindingID, let recordID,
           let identity = authCoordinator.currentIdentity,
           (try? activeBindingRepository.load(for: identity)) == bindingID,
           !staleBindingIDs.contains(bindingID),
           let snapshot = bindingService.snapshot(identity: identity, bindingID: bindingID) {
            contextTodo = snapshot.items.first(where: { $0.id == recordID })
            if contextTodo != nil && canMutate {
                let delete = NSMenuItem(title: "删除条目…", action: #selector(deleteTaskFromMenu(_:)), keyEquivalent: "")
                delete.target = self
                delete.representedObject = ["bindingID": bindingID, "recordID": recordID]
                menu.addItem(delete)
                menu.addItem(.separator())
            }
        }
        if let bindingID, let recordID,
           let identity = authCoordinator.currentIdentity,
           (try? activeBindingRepository.load(for: identity)) == bindingID,
           canMutate, !staleBindingIDs.contains(bindingID),
           let todo = contextTodo,
           isYesterday(todo.dateMilliseconds), !todo.isDone {
            let move = NSMenuItem(title: "迁移到今天", action: #selector(moveTaskToTodayFromMenu(_:)), keyEquivalent: "")
            move.target = self
            move.representedObject = ["bindingID": bindingID, "recordID": recordID]
            menu.addItem(move)
            menu.addItem(.separator())
        }
        let close = NSMenuItem(title: "关闭当前页", action: #selector(closeCurrentPageFromContextMenu), keyEquivalent: "")
        close.target = self
        menu.addItem(close)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        let pointerInWindow = window.convertPoint(fromScreen: NSEvent.mouseLocation)
        let point = webView.convert(pointerInWindow, from: nil)
        menu.popUp(positioning: nil, at: point, in: webView)
    }

    @objc private func deleteTaskFromMenu(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? [String: String],
              let recordID = value["recordID"],
              let bindingID = value["bindingID"],
              let data = try? JSONSerialization.data(withJSONObject: recordID, options: [.fragmentsAllowed]),
              let json = String(data: data, encoding: .utf8) else { return }
        let alert = NSAlert()
        alert.messageText = "删除这条待办？"
        alert.informativeText = "此操作会删除飞书多维表格中的原始记录，并清除此任务在 Todo 本机保存的番茄钟数据。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "删除待办")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        guard let identity = authCoordinator.currentIdentity,
              (try? activeBindingRepository.load(for: identity)) == bindingID else { return }
        webView.evaluateJavaScript("window.__todoDeleteTask && window.__todoDeleteTask(\(json));")
    }

    private func isYesterday(_ milliseconds: Double) -> Bool {
        let calendar = Calendar.current
        guard let yesterday = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: Date())) else { return false }
        let taskDate = calendar.startOfDay(for: Date(timeIntervalSince1970: milliseconds / 1000))
        return taskDate == yesterday
    }

    @objc private func moveTaskToTodayFromMenu(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? [String: String],
              let bindingID = value["bindingID"], let recordID = value["recordID"],
              let data = try? JSONSerialization.data(withJSONObject: ["bindingId": bindingID, "recordId": recordID], options: [.fragmentsAllowed]),
              let json = String(data: data, encoding: .utf8) else { return }
        webView.evaluateJavaScript("window.__todoMoveTaskToToday && window.__todoMoveTaskToToday(\(json));")
    }

    @objc private func closeCurrentPageFromContextMenu() {
        webView.evaluateJavaScript("window.__todoCloseCurrentPage && window.__todoCloseCurrentPage();")
    }

    @objc private func terminate(_ sender: Any? = nil) {
        NSApp.terminate(sender)
    }

    @objc private func configureFeishuCredentials(_ sender: Any? = nil) {
        _ = presentFeishuCredentials()
    }

    @discardableResult
    private func presentFeishuCredentials() -> Bool {
        let existing: FeishuAppCredentials?
        do {
            existing = try authCoordinator.loadAppCredentials()
        } catch {
            showCredentialError(error.localizedDescription)
            return false
        }
        var appID = existing?.appID ?? ""
        var appSecret = existing?.appSecret ?? ""

        while true {
            let alert = NSAlert()
            alert.messageText = "配置飞书自建应用"
            alert.informativeText = "请填写你在自己飞书组织创建的应用凭证。Todo 会将其保存在本机钥匙串，并直接向飞书发起授权。"
            alert.alertStyle = .informational
            alert.addButton(withTitle: "保存")
            alert.addButton(withTitle: "取消")

            let form = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 112))
            let appIDLabel = NSTextField(labelWithString: "App ID")
            appIDLabel.frame = NSRect(x: 0, y: 88, width: 320, height: 18)
            let appIDField = NSTextField(string: appID)
            appIDField.placeholderString = "cli_…"
            appIDField.frame = NSRect(x: 0, y: 61, width: 320, height: 24)
            let secretLabel = NSTextField(labelWithString: "App Secret")
            secretLabel.frame = NSRect(x: 0, y: 33, width: 320, height: 18)
            let secretField = NSSecureTextField(string: appSecret)
            secretField.placeholderString = "粘贴 App Secret"
            secretField.frame = NSRect(x: 0, y: 6, width: 320, height: 24)
            form.addSubview(appIDLabel)
            form.addSubview(appIDField)
            form.addSubview(secretLabel)
            form.addSubview(secretField)
            alert.accessoryView = form
            alert.window.initialFirstResponder = appIDField

            guard alert.runModal() == .alertFirstButtonReturn else { return false }
            appID = appIDField.stringValue
            appSecret = secretField.stringValue

            do {
                let credentials = try FeishuAppCredentials(appID: appID, appSecret: appSecret)
                let changed = try authCoordinator.saveAppCredentials(credentials)
                if changed { bridgeHandler.sendEvent("auth.signedOut") }
                return true
            } catch {
                showCredentialError(error.localizedDescription)
            }
        }
    }

    private func showCredentialError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "无法保存飞书应用凭证"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "返回修改")
        alert.runModal()
    }

    private func createWindow() {
        let frame = restoredFrame()
        let style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable]
        window = NSWindow(contentRect: frame, styleMask: style, backing: .buffered, defer: false)
        window.title = "Todo"
        window.titleVisibility = .visible
        window.titlebarAppearsTransparent = false
        window.isMovableByWindowBackground = false
        window.isReleasedWhenClosed = false
        window.minSize = minimumSize
        window.delegate = self
        window.backgroundColor = .windowBackgroundColor
        window.isOpaque = true
        window.hasShadow = true
        let pinned = UserDefaults.standard.bool(forKey: pinnedKey)
        window.level = pinned ? .floating : .normal
        window.collectionBehavior = pinned ? [.canJoinAllSpaces, .fullScreenAuxiliary] : []

        let configuration = WKWebViewConfiguration()
        configuration.userContentController.addUserScript(
            WKUserScript(source: desktopAdaptationScript, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
        )
        bridgeHandler = TodoBridgeHandler()
        authCoordinator = AuthCoordinator()
        authCoordinator.onAuthorizationStarted = { [weak self] in
            self?.bridgeHandler.sendEvent("auth.started")
        }
        authCoordinator.onAuthorizationCompleted = { [weak self] identity, displayName in
            NSApp.activate(ignoringOtherApps: true)
            self?.window?.makeKeyAndOrderFront(nil)
            self?.bridgeHandler.sendEvent("auth.completed", payload: [
                "userId": identity.userID,
                "tenantId": identity.tenantID as Any? ?? NSNull(),
                "accountKey": identity.storageKey,
                "displayName": displayName ?? "飞书用户"
            ])
        }
        authCoordinator.onAuthorizationFailed = { [weak self] message in
            self?.bridgeHandler.sendEvent("auth.failed", payload: ["message": message])
        }
        bridgeHandler.onTogglePinned = { [weak self] in self?.togglePinned() }
        bridgeHandler.onTaskContextMenu = { [weak self] bindingID, recordID, canMutate in
            self?.showTaskContextMenu(bindingID: bindingID, recordID: recordID, canMutate: canMutate)
        }
        bridgeHandler.onRequest = { [weak self] request in
            self?.handleBridgeRequest(request) ?? .failure(request.requestID,
                                                            code: "HOST_UNAVAILABLE",
                                                            message: "桌面宿主暂不可用。")
        }
        bridgeHandler.onAsyncRequest = { [weak self] request, completion in
            Task { @MainActor in
                guard let self else {
                    completion(.failure(request.requestID, code: "HOST_UNAVAILABLE", message: "桌面宿主暂不可用。"))
                    return
                }
                completion(await self.handleAsyncBridgeRequest(request))
            }
        }
        configuration.userContentController.add(bridgeHandler, name: "todoHost")
        webView = TodoNoteWebView(frame: .zero, configuration: configuration)
        webView.onCloseCurrentPage = { [weak self] in
            self?.webView.evaluateJavaScript("window.__todoCloseCurrentPage && window.__todoCloseCurrentPage();")
        }
        bridgeHandler.webView = webView
        webView.uiDelegate = self
        webView.setValue(false, forKey: "drawsBackground")
        webView.allowsBackForwardNavigationGestures = false
        window.contentView = webView
        webView.frame = window.contentView?.bounds ?? NSRect(origin: .zero, size: frame.size)
        webView.autoresizingMask = [.width, .height]
        if let pageURL = Bundle.module.url(forResource: "prototype", withExtension: "html", subdirectory: "Resources") {
            webView.loadFileURL(pageURL, allowingReadAccessTo: pageURL.deletingLastPathComponent())
        } else {
            loadResourceError()
        }
    }

    private func restoredFrame() -> NSRect {
        if let value = UserDefaults.standard.string(forKey: frameKey) {
            let frame = NSRectFromString(value)
            if frame.width >= minimumSize.width, frame.height >= minimumSize.height,
               NSScreen.screens.contains(where: { $0.visibleFrame.intersects(frame) }) {
                return frame
            }
        }
        return defaultFrame()
    }

    private func defaultFrame() -> NSRect {
        let visible = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
        return NSRect(x: visible.maxX - initialSize.width - 30,
                      y: visible.maxY - initialSize.height - 50,
                      width: initialSize.width,
                      height: initialSize.height)
    }

    private func saveWindowFrame() {
        guard let window else { return }
        UserDefaults.standard.set(NSStringFromRect(window.frame), forKey: frameKey)
    }

    private func buildApplicationMenu() {
        let mainMenu = NSMenu()
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(menuItem("显示 Todo", action: #selector(showWindow(_:)), key: "o"))
        appMenu.addItem(menuItem("飞书应用凭证…", action: #selector(configureFeishuCredentials(_:))))
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(menuItem("隐藏 Todo", action: #selector(hideWindow(_:)), key: "h"))
        appMenu.addItem(menuItem("退出 Todo", action: #selector(terminate(_:)), key: "q"))
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        let editMenuItem = NSMenuItem()
        editMenuItem.title = "编辑"
        let editMenu = NSMenu(title: "编辑")
        editMenu.addItem(responderMenuItem("撤销", action: Selector(("undo:")), key: "z"))
        editMenu.addItem(responderMenuItem("重做", action: Selector(("redo:")), key: "Z"))
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(responderMenuItem("剪切", action: #selector(NSText.cut(_:)), key: "x"))
        editMenu.addItem(responderMenuItem("拷贝", action: #selector(NSText.copy(_:)), key: "c"))
        editMenu.addItem(responderMenuItem("粘贴", action: #selector(NSText.paste(_:)), key: "v"))
        editMenu.addItem(responderMenuItem("全选", action: #selector(NSResponder.selectAll(_:)), key: "a"))
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        let windowMenuItem = NSMenuItem(title: "窗口", action: nil, keyEquivalent: "")
        let windowMenu = NSMenu(title: "窗口")
        windowMenu.addItem(menuItem("关闭便签窗口", action: #selector(closeWindow(_:)), key: "w"))
        windowMenu.addItem(responderMenuItem("最小化", action: #selector(NSWindow.performMiniaturize(_:)), key: "m"))
        windowMenu.addItem(menuItem("显示 Todo", action: #selector(showWindow(_:))))
        windowMenu.addItem(NSMenuItem.separator())
        windowMenu.addItem(menuItem("置顶 / 取消置顶", action: #selector(togglePinned(_:))))
        windowMenuItem.submenu = windowMenu
        mainMenu.addItem(windowMenuItem)
        NSApp.mainMenu = mainMenu
    }

    private func buildDockMenu() {
        dockMenu.addItem(menuItem("显示 Todo", action: #selector(showWindow(_:))))
        dockMenu.addItem(menuItem("隐藏 Todo", action: #selector(hideWindow(_:))))
        dockMenu.addItem(menuItem("关闭便签窗口", action: #selector(closeWindow(_:))))
        dockMenu.addItem(NSMenuItem.separator())
        dockMenu.addItem(menuItem("退出 Todo", action: #selector(terminate(_:))))
    }

    private func menuItem(_ title: String, action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    private func responderMenuItem(_ title: String, action: Selector, key: String) -> NSMenuItem {
        NSMenuItem(title: title, action: action, keyEquivalent: key)
    }

    private func updatePinLabel(pinned: Bool) {
        let label = pinned ? "取消置顶" : "置顶"
        webView.evaluateJavaScript("document.getElementById('pin-label').textContent = '\(label)'")
        webView.evaluateJavaScript("document.getElementById('note').classList.toggle('pinned', \(pinned))")
    }

    private func handleBridgeRequest(_ request: BridgeRequest) -> BridgeResponse {
        switch request.method {
        case "app.bootstrap":
            var result: [String: Any] = [
                "authenticated": authCoordinator.isAuthenticated
            ]
            if let identity = authCoordinator.currentIdentity {
                result["userId"] = identity.userID
                result["tenantId"] = identity.tenantID ?? NSNull() as Any
                result["accountKey"] = identity.storageKey
                result["displayName"] = authCoordinator.currentDisplayName ?? "飞书用户"
            }
            if let pendingURL = pendingViewLinkStore.load() {
                result["pendingViewUrl"] = pendingURL
            }
            return .success(request.requestID, result: result)

        case "app.hide":
            hideWindow()
            return .success(request.requestID, result: ["hidden": true])

        case "notes.setPinned":
            guard let pinned = request.params["pinned"] as? Bool else {
                return .failure(request.requestID, code: "INVALID_ARGUMENT", message: "缺少置顶状态。")
            }
            setPinned(pinned)
            return .success(request.requestID, result: ["pinned": pinned])

        case "auth.start":
            do {
                if try authCoordinator.loadAppCredentials() == nil {
                    guard presentFeishuCredentials() else {
                        return .failure(request.requestID,
                                        code: "APP_CREDENTIALS_REQUIRED",
                                        message: "需要配置飞书自建应用凭证才能继续授权。")
                    }
                }
            } catch {
                return .failure(request.requestID,
                                code: "KEYCHAIN_ACCESS_FAILED",
                                message: "无法读取飞书应用凭证。请检查系统钥匙串访问权限后重试。\n\(error.localizedDescription)")
            }
            authCoordinator.startAuthorization()
            return .success(request.requestID, result: ["started": true])

        case "auth.credentials.configure":
            guard presentFeishuCredentials() else {
                return .success(request.requestID, result: ["configured": false])
            }
            do {
                return .success(request.requestID,
                                result: ["configured": try authCoordinator.loadAppCredentials() != nil])
            } catch {
                return .failure(request.requestID,
                                code: "KEYCHAIN_ACCESS_FAILED",
                                message: "飞书凭证保存后无法从钥匙串读取。\n\(error.localizedDescription)")
            }

        case "auth.status":
            var result: [String: Any] = ["authenticated": authCoordinator.isAuthenticated]
            if let identity = authCoordinator.currentIdentity {
                result["userId"] = identity.userID
                result["tenantId"] = identity.tenantID ?? NSNull() as Any
                result["accountKey"] = identity.storageKey
                result["displayName"] = authCoordinator.currentDisplayName ?? "飞书用户"
            }
            return .success(request.requestID, result: result)

        case "auth.signOut":
            authCoordinator.signOut()
            staleBindingIDs.removeAll()
            freshSnapshotBindingIDs.removeAll()
            bridgeHandler.sendEvent("auth.signedOut")
            return .success(request.requestID, result: ["signedOut": true])

        default:
            return .failure(request.requestID, code: "UNSUPPORTED_METHOD", message: "当前版本尚未支持此操作。")
        }
    }

    private func handleAsyncBridgeRequest(_ request: BridgeRequest) async -> BridgeResponse {
        do {
            switch request.method {
            case "app.bootstrap", "auth.status":
                return handleBridgeRequest(request)

            case "notes.inspectBinding":
                guard let viewURL = request.params["viewUrl"] as? String else {
                    return .failure(request.requestID, code: "INVALID_ARGUMENT", message: "缺少多维表格视图链接。")
                }
                guard let identity = authCoordinator.currentIdentity else {
                    return .failure(request.requestID, code: "AUTH_REQUIRED", message: "请先连接飞书账号。")
                }
                pendingViewLinkStore.save(viewURL)
                let token = try await authCoordinator.validAccessToken()
                let inspection = try await bindingService.inspect(viewURL: viewURL, accessToken: token)
                pendingBindingInspections = pendingBindingInspections.filter { $0.value.expiresAt > Date() }
                if pendingBindingInspections.count >= 8,
                   let oldestID = pendingBindingInspections.min(by: { $0.value.expiresAt < $1.value.expiresAt })?.key {
                    pendingBindingInspections.removeValue(forKey: oldestID)
                }
                let inspectionID = UUID().uuidString.lowercased()
                pendingBindingInspections[inspectionID] = PendingBindingInspection(
                    inspection: inspection,
                    viewURL: viewURL.trimmingCharacters(in: .whitespacesAndNewlines),
                    accountKey: identity.storageKey,
                    expiresAt: Date().addingTimeInterval(5 * 60)
                )
                var result = inspection.bridgeValue()
                result["inspectionID"] = inspectionID
                return .success(request.requestID, result: result)

            case "notes.createBinding":
                guard let viewURL = request.params["viewUrl"] as? String,
                      let inspectionID = request.params["inspectionID"] as? String,
                      let mappingValue = request.params["fieldMapping"] as? [String: Any],
                      let mapping = fieldMapping(from: mappingValue) else {
                    return .failure(request.requestID, code: "INVALID_ARGUMENT", message: "请提供视图链接和完整字段映射。")
                }
                guard let identity = authCoordinator.currentIdentity else {
                    return .failure(request.requestID, code: "AUTH_REQUIRED", message: "请先连接飞书账号。")
                }
                let normalizedURL = viewURL.trimmingCharacters(in: .whitespacesAndNewlines)
                guard let pending = pendingBindingInspections[inspectionID],
                      pending.expiresAt > Date(),
                      pending.accountKey == identity.storageKey,
                      pending.viewURL == normalizedURL else {
                    pendingBindingInspections.removeValue(forKey: inspectionID)
                    return .failure(request.requestID,
                                    code: "INSPECTION_EXPIRED",
                                    message: "视图字段确认已过期，请重新读取视图字段。")
                }
                let token = try await authCoordinator.validAccessToken()
                let (binding, snapshot) = try await bindingService.createBinding(inspection: pending.inspection,
                                                                                 fieldMapping: mapping,
                                                                                 identity: identity,
                                                                                 accessToken: token)
                pendingBindingInspections.removeValue(forKey: inspectionID)
                try activeBindingRepository.save(binding.id, for: identity)
                pendingViewLinkStore.clear()
                staleBindingIDs.remove(binding.id)
                freshSnapshotBindingIDs.insert(binding.id)
                return .success(request.requestID, result: [
                    "binding": bridgeValue(for: binding),
                    "preferences": notePreferencesRepository.load(accountKey: identity.storageKey, bindingID: binding.id),
                    "snapshot": bridgeValue(for: snapshot, stale: false)
                ])

            case "notes.list", "notebook.list":
                guard let identity = authCoordinator.currentIdentity else {
                    return .success(request.requestID, result: ["items": [], "activeBindingId": NSNull()])
                }
                let bindings = try bindingService.bindings(for: identity)
                var activeBindingID = try activeBindingRepository.load(for: identity)
                if let storedActiveBindingID = activeBindingID,
                   !bindings.contains(where: { $0.id == storedActiveBindingID }) {
                    try activeBindingRepository.save(nil, for: identity)
                    activeBindingID = nil
                }
                let items = bindings.map { binding -> [String: Any] in
                    var item = bridgeValue(for: binding)
                    item["isActive"] = binding.id == activeBindingID
                    item["open"] = binding.id == activeBindingID
                    if let snapshot = bindingService.snapshot(identity: identity, bindingID: binding.id) {
                        let snapshotIsStale = staleBindingIDs.contains(binding.id)
                            || !freshSnapshotBindingIDs.contains(binding.id)
                        if snapshotIsStale { staleBindingIDs.insert(binding.id) }
                        else { staleBindingIDs.remove(binding.id) }
                        item["snapshot"] = bridgeValue(for: snapshot, stale: snapshotIsStale)
                    }
                    return item
                }
                return .success(request.requestID, result: [
                    "items": items,
                    "activeBindingId": activeBindingID as Any? ?? NSNull()
                ])

            case "notebook.open":
                guard let bindingID = request.params["bindingId"] as? String,
                      let identity = authCoordinator.currentIdentity,
                      let binding = try bindingService.bindings(for: identity).first(where: { $0.id == bindingID }) else {
                    return .failure(request.requestID, code: "BINDING_NOT_FOUND", message: "找不到这张便签的视图关联。")
                }
                guard !hasActiveCompletionMutation(bindingID: bindingID) else {
                    return .failure(request.requestID, code: "MUTATION_IN_PROGRESS", message: "任务状态正在写回，请稍后再切换便签。")
                }
                staleBindingIDs.insert(bindingID)
                let token = try await authCoordinator.validAccessToken()
                var generationWarning: String?
                do {
                    try await generateFixedTasksForToday(binding: binding, identity: identity, accessToken: token)
                } catch {
                    generationWarning = "固定待办暂未生成，稍后刷新会重试：\(error.localizedDescription)"
                }
                let snapshot = try await bindingService.refresh(binding: binding,
                                                                identity: identity,
                                                                accessToken: token)
                try activeBindingRepository.save(bindingID, for: identity)
                staleBindingIDs.remove(bindingID)
                freshSnapshotBindingIDs.insert(bindingID)
                var result: [String: Any] = [
                    "binding": bridgeValue(for: binding),
                    "activeBindingId": bindingID,
                    "preferences": notePreferencesRepository.load(accountKey: identity.storageKey, bindingID: binding.id),
                    "snapshot": bridgeValue(for: snapshot, stale: false)
                ]
                if let generationWarning { result["warning"] = generationWarning }
                return .success(request.requestID, result: result)

            case "notes.getPreferences":
                guard let bindingID = request.params["bindingId"] as? String,
                      let identity = authCoordinator.currentIdentity,
                      let binding = try bindingService.bindings(for: identity).first(where: { $0.id == bindingID }) else {
                    return .failure(request.requestID, code: "BINDING_NOT_FOUND", message: "找不到这张便签的设置。")
                }
                return .success(request.requestID, result: [
                    "preferences": notePreferencesRepository.load(accountKey: identity.storageKey, bindingID: binding.id)
                ])

            case "notes.closeCurrent":
                guard let bindingID = request.params["bindingId"] as? String,
                      let identity = authCoordinator.currentIdentity else {
                    return .failure(request.requestID, code: "INVALID_ARGUMENT", message: "缺少当前便签或飞书账号。")
                }
                let activeBindingID = try activeBindingRepository.load(for: identity)
                guard activeBindingID == nil || activeBindingID == bindingID else {
                    return .failure(request.requestID, code: "NOT_ACTIVE_BINDING", message: "当前便签已经切换，请重新操作。")
                }
                try activeBindingRepository.save(nil, for: identity)
                return .success(request.requestID, result: ["closed": true, "activeBindingId": NSNull()])

            case "notes.deleteBinding":
                guard let bindingID = request.params["bindingId"] as? String,
                      let identity = authCoordinator.currentIdentity else {
                    return .failure(request.requestID, code: "INVALID_ARGUMENT", message: "缺少要删除的便签或飞书账号。")
                }
                let previousActiveID = try activeBindingRepository.load(for: identity)
                if previousActiveID == bindingID {
                    try activeBindingRepository.save(nil, for: identity)
                }
                var cleanupWarning: String?
                do {
                    cleanupWarning = try bindingService.deleteBinding(id: bindingID, identity: identity)
                } catch {
                    if previousActiveID == bindingID { try? activeBindingRepository.save(bindingID, for: identity) }
                    throw error
                }
                staleBindingIDs.remove(bindingID)
                freshSnapshotBindingIDs.remove(bindingID)
                do {
                    try notePreferencesRepository.delete(accountKey: identity.storageKey, bindingID: bindingID)
                } catch {
                    let message = "外观偏好清理失败：\(error.localizedDescription)"
                    cleanupWarning = [cleanupWarning, message].compactMap { $0 }.joined(separator: "\n")
                }
                do {
                    try focusSessionRepository.delete(accountKey: identity.storageKey, bindingID: bindingID)
                } catch {
                    let message = "番茄钟数据清理失败：\(error.localizedDescription)"
                    cleanupWarning = [cleanupWarning, message].compactMap { $0 }.joined(separator: "\n")
                }
                let bindings = try bindingService.bindings(for: identity, retryDeletedSnapshotCleanup: false)
                let activeBindingID = try activeBindingRepository.load(for: identity)
                let items = bindings.map { binding -> [String: Any] in
                    var item = bridgeValue(for: binding)
                    item["isActive"] = binding.id == activeBindingID
                    item["open"] = binding.id == activeBindingID
                    if let snapshot = bindingService.snapshot(identity: identity, bindingID: binding.id) {
                        let snapshotIsStale = staleBindingIDs.contains(binding.id)
                        item["snapshot"] = bridgeValue(for: snapshot, stale: snapshotIsStale)
                    }
                    return item
                }
                var result: [String: Any] = [
                    "items": items,
                    "activeBindingId": activeBindingID as Any? ?? NSNull()
                ]
                if let cleanupWarning { result["warning"] = cleanupWarning }
                return .success(request.requestID, result: result)

            case "notes.refresh":
                guard let bindingID = request.params["bindingId"] as? String,
                      let identity = authCoordinator.currentIdentity,
                      let binding = try bindingService.bindings(for: identity).first(where: { $0.id == bindingID }) else {
                    return .failure(request.requestID, code: "BINDING_NOT_FOUND", message: "找不到这张便签的视图关联。")
                }
                guard SnapshotRefreshAdmission.begin(
                    bindingID: bindingID,
                    hasActiveMutation: hasActiveCompletionMutation(bindingID: bindingID),
                    markStale: { staleBindingIDs.insert($0) }
                ) else {
                    return .failure(request.requestID, code: "MUTATION_IN_PROGRESS", message: "任务状态正在写回，请稍后再刷新。")
                }
                do {
                    let token = try await authCoordinator.validAccessToken()
                    var generationWarning: String?
                    do {
                        try await generateFixedTasksForToday(binding: binding, identity: identity, accessToken: token)
                    } catch {
                        generationWarning = "固定待办暂未生成，稍后刷新会重试：\(error.localizedDescription)"
                    }
                    let snapshot = try await bindingService.refresh(binding: binding,
                                                                    identity: identity,
                                                                    accessToken: token)
                    staleBindingIDs.remove(bindingID)
                    freshSnapshotBindingIDs.insert(bindingID)
                    var result: [String: Any] = ["snapshot": bridgeValue(for: snapshot, stale: false)]
                    if let generationWarning { result["warning"] = generationWarning }
                    return .success(request.requestID, result: result)
                } catch {
                    staleBindingIDs.insert(bindingID)
                    freshSnapshotBindingIDs.remove(bindingID)
                    if let snapshot = bindingService.snapshot(identity: identity, bindingID: binding.id) {
                        return .success(request.requestID, result: [
                            "snapshot": bridgeValue(for: snapshot, stale: true),
                            "error": error.localizedDescription
                        ])
                    }
                    throw error
                }

            case "notes.createTaskOptions":
                guard let bindingID = request.params["bindingId"] as? String,
                      let identity = authCoordinator.currentIdentity,
                      let binding = try bindingService.bindings(for: identity).first(where: { $0.id == bindingID }) else {
                    return .failure(request.requestID, code: "BINDING_NOT_FOUND", message: "找不到当前便签的视图关联。")
                }
                guard try activeBindingRepository.load(for: identity) == bindingID else {
                    return .failure(request.requestID, code: "NOT_ACTIVE_BINDING", message: "请先打开要添加任务的便签。")
                }
                let token = try await authCoordinator.validAccessToken()
                let creationOptions = try await bindingService.taskCreationOptions(binding: binding, accessToken: token)
                return .success(request.requestID, result: [
                    "options": creationOptions.options.map { ["id": $0.id, "name": $0.name] },
                    "plannedDurationAvailable": creationOptions.plannedDurationAvailable
                ])

            case "notes.createTask":
                guard let bindingID = request.params["bindingId"] as? String,
                      let title = request.params["title"] as? String,
                      let priorityOptionID = request.params["priorityOptionID"] as? String,
                      let dateNumber = request.params["dateMilliseconds"] as? NSNumber,
                      let clientToken = request.params["clientToken"] as? String,
                      UUID(uuidString: clientToken) != nil,
                      dateNumber.doubleValue.isFinite,
                      dateNumber.doubleValue >= 0,
                      dateNumber.doubleValue.rounded(.towardZero) == dateNumber.doubleValue,
                      let identity = authCoordinator.currentIdentity,
                      let binding = try bindingService.bindings(for: identity).first(where: { $0.id == bindingID }) else {
                    return .failure(request.requestID, code: "INVALID_ARGUMENT", message: "请填写待办内容、优先级和有效日期。")
                }
                guard try activeBindingRepository.load(for: identity) == bindingID else {
                    return .failure(request.requestID, code: "NOT_ACTIVE_BINDING", message: "当前便签已经切换，请重新操作。")
                }
                let token = try await authCoordinator.validAccessToken()
                let plannedDuration = request.params["plannedDurationHours"] as? NSNumber
                if let plannedDuration,
                   (!plannedDuration.doubleValue.isFinite || plannedDuration.doubleValue < 0.5
                    || (plannedDuration.doubleValue * 2).rounded() != plannedDuration.doubleValue * 2) {
                    return .failure(request.requestID, code: "INVALID_ARGUMENT", message: "计划时长需以 0.5 小时为单位。")
                }
                let creation = try await bindingService.createTask(binding: binding,
                                                                   identity: identity,
                                                                   title: title,
                                                                   priorityOptionID: priorityOptionID,
                                                                   dateMilliseconds: dateNumber.int64Value,
                                                                   plannedDurationHours: plannedDuration?.doubleValue,
                                                                   clientToken: clientToken,
                                                                   accessToken: token)
                var result: [String: Any] = [
                    "recordID": creation.recordID,
                    "visibleInView": creation.visibleInView
                ]
                if let snapshot = creation.snapshot {
                    if creation.isStale {
                        staleBindingIDs.insert(bindingID)
                        freshSnapshotBindingIDs.remove(bindingID)
                    } else {
                        staleBindingIDs.remove(bindingID)
                        freshSnapshotBindingIDs.insert(bindingID)
                    }
                    result["snapshot"] = bridgeValue(for: snapshot, stale: creation.isStale)
                } else {
                    staleBindingIDs.insert(bindingID)
                    freshSnapshotBindingIDs.remove(bindingID)
                }
                if let warning = creation.warning { result["warning"] = warning }
                return .success(request.requestID, result: result)

            case "notes.updateTask":
                guard let bindingID = request.params["bindingId"] as? String,
                      let recordID = request.params["recordId"] as? String,
                      let title = request.params["title"] as? String,
                      let priorityOptionID = request.params["priorityOptionID"] as? String,
                      let updatePlannedDuration = request.params["updatePlannedDuration"] as? Bool,
                      let identity = authCoordinator.currentIdentity,
                      let binding = try bindingService.bindings(for: identity).first(where: { $0.id == bindingID }) else {
                    return .failure(request.requestID, code: "INVALID_ARGUMENT", message: "缺少有效的便签、任务内容或优先级。")
                }
                guard try activeBindingRepository.load(for: identity) == bindingID,
                      !staleBindingIDs.contains(bindingID) else {
                    return .failure(request.requestID, code: "STALE_SNAPSHOT", message: "当前便签已切换或数据过期，请刷新后再编辑。")
                }
                let mutationKey = "\(identity.storageKey)|\(binding.resourceToken)|\(binding.tableID)|\(recordID)"
                guard activeCompletionMutations[mutationKey] == nil else {
                    return .failure(request.requestID, code: "MUTATION_IN_PROGRESS", message: "这条任务正在更新，请稍后再试。")
                }
                activeCompletionMutations[mutationKey] = bindingID
                defer { activeCompletionMutations.removeValue(forKey: mutationKey) }
                var plannedNumber: NSNumber?
                if updatePlannedDuration {
                    guard let rawDuration = request.params["plannedDurationHours"] else {
                        return .failure(request.requestID, code: "INVALID_ARGUMENT", message: "缺少计划时长值；清空时请传入 null。")
                    }
                    if !(rawDuration is NSNull) {
                        guard let number = rawDuration as? NSNumber,
                              CFGetTypeID(number) != CFBooleanGetTypeID() else {
                            return .failure(request.requestID, code: "INVALID_ARGUMENT", message: "计划时长必须是数字或空值。")
                        }
                        plannedNumber = number
                    }
                }
                if let plannedNumber,
                   (!plannedNumber.doubleValue.isFinite || plannedNumber.doubleValue < 0.5
                    || (plannedNumber.doubleValue * 2).rounded() != plannedNumber.doubleValue * 2) {
                    return .failure(request.requestID, code: "INVALID_ARGUMENT", message: "计划时长需以 0.5 小时为单位。")
                }
                let token = try await authCoordinator.validAccessToken()
                let result = try await bindingService.updateTask(binding: binding,
                                                                 identity: identity,
                                                                 recordID: recordID,
                                                                 title: title,
                                                                 priorityOptionID: priorityOptionID,
                                                                 plannedDurationHours: plannedNumber?.doubleValue,
                                                                 updatePlannedDuration: updatePlannedDuration,
                                                                 accessToken: token)
                if result.isStale {
                    staleBindingIDs.insert(bindingID)
                    freshSnapshotBindingIDs.remove(bindingID)
                } else {
                    staleBindingIDs.remove(bindingID)
                    freshSnapshotBindingIDs.insert(bindingID)
                }
                var value: [String: Any] = [
                    "snapshot": bridgeValue(for: result.snapshot, stale: result.isStale),
                    "visibleInView": result.visibleInView,
                    "stale": result.isStale
                ]
                if let warning = result.warning { value["warning"] = warning }
                return .success(request.requestID, result: value)

            case "notes.deleteTask":
                guard let bindingID = request.params["bindingId"] as? String,
                      let recordID = request.params["recordId"] as? String,
                      let identity = authCoordinator.currentIdentity,
                      let binding = try bindingService.bindings(for: identity).first(where: { $0.id == bindingID }) else {
                    return .failure(request.requestID, code: "INVALID_ARGUMENT", message: "缺少有效的便签或任务记录。")
                }
                guard try activeBindingRepository.load(for: identity) == bindingID,
                      !staleBindingIDs.contains(bindingID) else {
                    return .failure(request.requestID, code: "STALE_SNAPSHOT", message: "当前便签已切换或数据过期，请刷新后再删除。")
                }
                let mutationKey = "\(identity.storageKey)|\(binding.resourceToken)|\(binding.tableID)|\(recordID)"
                guard activeCompletionMutations[mutationKey] == nil else {
                    return .failure(request.requestID, code: "MUTATION_IN_PROGRESS", message: "这条任务正在更新，请稍后再试。")
                }
                activeCompletionMutations[mutationKey] = bindingID
                defer { activeCompletionMutations.removeValue(forKey: mutationKey) }
                let token = try await authCoordinator.validAccessToken()
                let result = try await bindingService.deleteTask(binding: binding,
                                                                 identity: identity,
                                                                 recordID: recordID,
                                                                 accessToken: token)
                var mutationWarning = result.warning
                do {
                    try focusSessionRepository.forgetTask(accountKey: identity.storageKey,
                                                          bindingID: bindingID,
                                                          taskID: recordID)
                } catch {
                    let cleanupWarning = "飞书记录已删除，但本机番茄钟数据未能清除：\(error.localizedDescription)"
                    mutationWarning = [mutationWarning, cleanupWarning].compactMap { $0 }.joined(separator: "\n")
                }
                if result.isStale {
                    staleBindingIDs.insert(bindingID)
                    freshSnapshotBindingIDs.remove(bindingID)
                } else {
                    staleBindingIDs.remove(bindingID)
                    freshSnapshotBindingIDs.insert(bindingID)
                }
                var value: [String: Any] = [
                    "snapshot": bridgeValue(for: result.snapshot, stale: result.isStale),
                    "stale": result.isStale
                ]
                if let mutationWarning { value["warning"] = mutationWarning }
                return .success(request.requestID, result: value)

            case "focus.state":
                guard let bindingID = request.params["bindingId"] as? String,
                      let taskID = request.params["taskId"] as? String,
                      let identity = authCoordinator.currentIdentity,
                      try activeBindingRepository.load(for: identity) == bindingID else {
                    return .failure(request.requestID, code: "INVALID_ARGUMENT", message: "当前便签或任务无效。")
                }
                let state = try focusSessionRepository.state(accountKey: identity.storageKey,
                                                             bindingID: bindingID,
                                                             taskID: taskID)
                if state.roundCompleted { requestFocusNotification() }
                return .success(request.requestID, result: focusBridgeValue(data: state.data, taskID: taskID, bindingID: bindingID))

            case "focus.start":
                guard let bindingID = request.params["bindingId"] as? String,
                      let taskID = request.params["taskId"] as? String,
                      let identity = authCoordinator.currentIdentity,
                      try activeBindingRepository.load(for: identity) == bindingID else {
                    return .failure(request.requestID, code: "INVALID_ARGUMENT", message: "当前便签或任务无效。")
                }
                let state = try focusSessionRepository.start(accountKey: identity.storageKey,
                                                             bindingID: bindingID,
                                                             taskID: taskID)
                requestNotificationPermissionIfNeeded()
                return .success(request.requestID, result: focusBridgeValue(data: state.data, taskID: taskID, bindingID: bindingID))

            case "focus.pause", "focus.completeTask":
                guard let bindingID = request.params["bindingId"] as? String,
                      let taskID = request.params["taskId"] as? String,
                      let identity = authCoordinator.currentIdentity,
                      try activeBindingRepository.load(for: identity) == bindingID else {
                    return .failure(request.requestID, code: "INVALID_ARGUMENT", message: "当前便签或任务无效。")
                }
                if request.method == "focus.pause" {
                    let (data, roundCompleted) = try focusSessionRepository.pause(accountKey: identity.storageKey,
                                                                                   bindingID: bindingID,
                                                                                   taskID: taskID)
                    if roundCompleted { requestFocusNotification() }
                    return .success(request.requestID, result: focusBridgeValue(data: data, taskID: taskID, bindingID: bindingID))
                }
                try focusSessionRepository.completeTask(accountKey: identity.storageKey,
                                                        bindingID: bindingID,
                                                        taskID: taskID)
                let data = try focusSessionRepository.tick(accountKey: identity.storageKey, bindingID: bindingID).0
                return .success(request.requestID, result: focusBridgeValue(data: data, taskID: taskID, bindingID: bindingID))

            case "focus.configure":
                guard let bindingID = request.params["bindingId"] as? String,
                      let taskID = request.params["taskId"] as? String,
                      let identity = authCoordinator.currentIdentity,
                      try activeBindingRepository.load(for: identity) == bindingID,
                      let work = request.params["workMinutes"] as? Int,
                      let shortBreak = request.params["shortBreakMinutes"] as? Int,
                      let longBreak = request.params["longBreakMinutes"] as? Int,
                      let longEvery = request.params["longBreakEvery"] as? Int else {
                    return .failure(request.requestID, code: "INVALID_ARGUMENT", message: "请检查番茄钟设置。")
                }
                let data = try focusSessionRepository.configure(accountKey: identity.storageKey,
                                                                bindingID: bindingID,
                                                                configuration: FocusConfiguration(workMinutes: work,
                                                                                                   shortBreakMinutes: shortBreak,
                                                                                                   longBreakMinutes: longBreak,
                                                                                                   longBreakEvery: longEvery))
                return .success(request.requestID, result: focusBridgeValue(data: data, taskID: taskID, bindingID: bindingID))

            case "notes.setPreferences":
                guard let bindingID = request.params["bindingId"] as? String,
                      let patch = request.params["patch"] as? [String: Any],
                      let identity = authCoordinator.currentIdentity,
                      let binding = try bindingService.bindings(for: identity).first(where: { $0.id == bindingID }) else {
                    return .failure(request.requestID, code: "INVALID_ARGUMENT", message: "找不到当前账号下的便签设置。")
                }
                do {
                    let preferences = try notePreferencesRepository.save(accountKey: identity.storageKey,
                                                                         bindingID: binding.id,
                                                                         patch: patch)
                    return .success(request.requestID, result: ["preferences": preferences])
                } catch let error as LocalizedError {
                    return .failure(request.requestID,
                                    code: "PREFERENCES_SAVE_FAILED",
                                    message: error.errorDescription ?? "无法保存便签外观设置。")
                }

            case "notes.createFixedTaskOccurrence":
                guard let bindingID = request.params["bindingId"] as? String,
                      let templateID = request.params["templateId"] as? String,
                      let dateKey = request.params["dateKey"] as? String,
                      let identity = authCoordinator.currentIdentity,
                      let binding = try bindingService.bindings(for: identity).first(where: { $0.id == bindingID }),
                      try activeBindingRepository.load(for: identity) == bindingID else {
                    return .failure(request.requestID, code: "INVALID_ARGUMENT", message: "当前便签或固定事项无效。")
                }
                let preferences = notePreferencesRepository.load(accountKey: identity.storageKey, bindingID: bindingID)
                let templates = preferences["fixedTasks"] as? [[String: Any]] ?? []
                guard templates.contains(where: { $0["id"] as? String == templateID }) else {
                    return .failure(request.requestID, code: "FIXED_TASK_NOT_FOUND", message: "找不到这条本机固定事项，请刷新后重试。")
                }
                let token = try await authCoordinator.validAccessToken()
                let createdRecordIDs = try await generateFixedTasks(binding: binding,
                                                                     identity: identity,
                                                                     accessToken: token,
                                                                     dateKey: dateKey,
                                                                     templateID: templateID)
                let snapshot = try await bindingService.refresh(binding: binding,
                                                                identity: identity,
                                                                accessToken: token)
                staleBindingIDs.remove(bindingID)
                freshSnapshotBindingIDs.insert(bindingID)
                let visible = createdRecordIDs.contains { recordID in
                    snapshot.items.contains(where: { $0.id == recordID })
                }
                var result: [String: Any] = [
                    "snapshot": bridgeValue(for: snapshot, stale: false),
                    "visibleInView": visible
                ]
                if !visible {
                    result["warning"] = "固定事项已保存，但当前视图没有显示新任务。请检查飞书视图筛选。"
                }
                return .success(request.requestID, result: result)

            case "todos.setDone":
                guard let bindingID = request.params["bindingId"] as? String,
                      let recordID = request.params["recordId"] as? String,
                      let isDone = request.params["done"] as? Bool,
                      let mutationID = request.params["mutationId"] as? String,
                      !mutationID.isEmpty else {
                    return .failure(request.requestID, code: "INVALID_ARGUMENT", message: "缺少有效的便签、记录或目标完成状态。")
                }
                guard let identity = authCoordinator.currentIdentity else {
                    return .failure(request.requestID, code: "AUTH_REQUIRED", message: "请先连接飞书账号。")
                }
                guard request.params["accountKey"] as? String == identity.storageKey else {
                    return .failure(request.requestID, code: "ACCOUNT_MISMATCH", message: "待写回操作所属飞书账号与当前账号不一致，已停止写回。")
                }
                guard let binding = try bindingService.bindings(for: identity).first(where: { $0.id == bindingID }) else {
                    return .failure(request.requestID, code: "BINDING_NOT_FOUND", message: "找不到当前账号下的目标便签，已停止写回。")
                }
                guard !staleBindingIDs.contains(bindingID) else {
                    return .failure(request.requestID, code: "STALE_SNAPSHOT", message: "当前显示的是过期快照，请先刷新后再勾选。")
                }
                let mutationKey = "\(identity.storageKey)|\(binding.resourceToken)|\(binding.tableID)|\(recordID)"
                guard activeCompletionMutations[mutationKey] == nil else {
                    return .failure(request.requestID, code: "MUTATION_IN_PROGRESS", message: "这条任务正在写回，请稍后再试。")
                }
                activeCompletionMutations[mutationKey] = bindingID
                defer { activeCompletionMutations.removeValue(forKey: mutationKey) }
                let token = try await authCoordinator.validAccessToken()
                let result = try await bindingService.setCompletion(binding: binding,
                                                                     identity: identity,
                                                                     recordID: recordID,
                                                                     isDone: isDone,
                                                                     accessToken: token)
                if result.isStale {
                    staleBindingIDs.insert(bindingID)
                    freshSnapshotBindingIDs.remove(bindingID)
                } else {
                    staleBindingIDs.remove(bindingID)
                    freshSnapshotBindingIDs.insert(bindingID)
                }
                var value: [String: Any] = [
                    "mutationId": mutationID,
                    "snapshot": bridgeValue(for: result.snapshot, stale: result.isStale),
                    "stale": result.isStale
                ]
                if let warning = result.warning { value["warning"] = warning }
                return .success(request.requestID, result: value)

            case "todos.moveToToday":
                guard let bindingID = request.params["bindingId"] as? String,
                      let recordID = request.params["recordId"] as? String,
                      let identity = authCoordinator.currentIdentity,
                      let binding = try bindingService.bindings(for: identity).first(where: { $0.id == bindingID }),
                      try activeBindingRepository.load(for: identity) == bindingID else {
                    return .failure(request.requestID, code: "INVALID_ARGUMENT", message: "当前便签或待迁移任务无效。")
                }
                guard !staleBindingIDs.contains(bindingID) else {
                    return .failure(request.requestID, code: "STALE_SNAPSHOT", message: "当前显示的是过期快照，请先刷新后再迁移。")
                }
                let mutationKey = "\(identity.storageKey)|\(binding.resourceToken)|\(binding.tableID)|\(recordID)"
                guard activeCompletionMutations[mutationKey] == nil else {
                    return .failure(request.requestID, code: "MUTATION_IN_PROGRESS", message: "这条任务正在更新，请稍后再试。")
                }
                activeCompletionMutations[mutationKey] = bindingID
                defer { activeCompletionMutations.removeValue(forKey: mutationKey) }
                let token = try await authCoordinator.validAccessToken()
                let result = try await bindingService.moveTaskToToday(binding: binding,
                                                                       identity: identity,
                                                                       recordID: recordID,
                                                                       accessToken: token)
                if result.isStale {
                    staleBindingIDs.insert(bindingID)
                    freshSnapshotBindingIDs.remove(bindingID)
                } else {
                    staleBindingIDs.remove(bindingID)
                    freshSnapshotBindingIDs.insert(bindingID)
                }
                var value: [String: Any] = [
                    "snapshot": bridgeValue(for: result.snapshot, stale: result.isStale),
                    "visibleInView": result.visibleInView,
                    "stale": result.isStale
                ]
                if let warning = result.warning { value["warning"] = warning }
                return .success(request.requestID, result: value)

            case "notes.openSource":
                guard let bindingID = request.params["bindingId"] as? String,
                      let identity = authCoordinator.currentIdentity,
                      let binding = try bindingService.bindings(for: identity).first(where: { $0.id == bindingID }) else {
                    return .failure(request.requestID, code: "BINDING_NOT_FOUND", message: "找不到这张便签的视图关联。")
                }
                guard NSWorkspace.shared.open(binding.sourceURL) else {
                    return .failure(request.requestID, code: "OPEN_FAILED", message: "无法在浏览器中打开飞书视图。")
                }
                return .success(request.requestID, result: ["opened": true])

            default:
                return handleBridgeRequest(request)
            }
        } catch let error as LocalizedError {
            if ["todos.setDone", "todos.moveToToday"].contains(request.method),
               let bindingID = request.params["bindingId"] as? String,
               let mutationError = error as? FeishuBitableError,
               case .mutationOutcomeUnknown = mutationError {
                staleBindingIDs.insert(bindingID)
                freshSnapshotBindingIDs.remove(bindingID)
            }
            let code: String
            if (error as NSError).domain == NSURLErrorDomain {
                code = "NETWORK_UNAVAILABLE"
            } else if let mutationError = error as? FeishuBitableError,
               case .mutationOutcomeUnknown = mutationError {
                code = "MUTATION_OUTCOME_UNKNOWN"
            } else if let mutationError = error as? FeishuBitableError,
                      case .mutationRejected = mutationError {
                code = "MUTATION_REJECTED"
            } else {
                code = "BITABLE_REQUEST_FAILED"
            }
            return .failure(request.requestID,
                            code: code,
                            message: error.errorDescription ?? "读取飞书多维表格失败。")
        } catch {
            let isNetworkError = (error as NSError).domain == NSURLErrorDomain
            if ["todos.setDone", "todos.moveToToday"].contains(request.method),
               let bindingID = request.params["bindingId"] as? String,
               error as? FeishuBitableError == nil {
                staleBindingIDs.insert(bindingID)
                freshSnapshotBindingIDs.remove(bindingID)
            }
            return .failure(request.requestID,
                            code: isNetworkError ? "NETWORK_UNAVAILABLE" : "BITABLE_REQUEST_FAILED",
                            message: error.localizedDescription)
        }
    }

    private func hasActiveCompletionMutation(bindingID: String) -> Bool {
        activeCompletionMutations.values.contains(bindingID)
    }

    private func generateFixedTasksForToday(binding: ViewBinding,
                                            identity: FeishuIdentity,
                                            accessToken: String) async throws {
        _ = try await generateFixedTasks(binding: binding,
                                         identity: identity,
                                         accessToken: accessToken,
                                         dateKey: Self.localDateKey(for: Date()))
    }

    private func generateFixedTasks(binding: ViewBinding,
                                    identity: FeishuIdentity,
                                    accessToken: String,
                                    dateKey: String,
                                    templateID: String? = nil) async throws -> [String] {
        let generationKey = "\(binding.id)|\(dateKey)"
        while activeFixedTaskGenerations.contains(generationKey) {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        guard activeFixedTaskGenerations.insert(generationKey).inserted else { return [] }
        defer { activeFixedTaskGenerations.remove(generationKey) }
        guard let startOfDate = Self.date(forLocalDateKey: dateKey) else {
            throw NotePreferencesError.invalidSelectedDate
        }
        let pending = try notePreferencesRepository.pendingFixedTaskOccurrences(accountKey: identity.storageKey,
                                                                                bindingID: binding.id,
                                                                                dateKey: dateKey)
            .filter { templateID == nil || $0.template.id == templateID }
        let existingRecordIDs = templateID.flatMap { templateID in
            notePreferencesRepository.fixedTaskOccurrenceRecordID(accountKey: identity.storageKey,
                                                                   bindingID: binding.id,
                                                                   templateID: templateID,
                                                                   dateKey: dateKey)
        }.map { [$0] } ?? []
        guard !pending.isEmpty else { return existingRecordIDs }
        let dateMilliseconds = Int64((startOfDate.timeIntervalSince1970 * 1000).rounded())
        let createdRecordIDs = try await bindingService.createFixedTaskOccurrences(binding: binding,
                                                                                    occurrences: pending,
                                                                                    dateMilliseconds: dateMilliseconds,
                                                                                    accessToken: accessToken) { occurrenceID, recordID in
            try notePreferencesRepository.markFixedTaskOccurrenceCreated(accountKey: identity.storageKey,
                                                                           bindingID: binding.id,
                                                                           occurrenceID: occurrenceID,
                                                                           recordID: recordID)
        }
        return existingRecordIDs + createdRecordIDs
    }

    private static func localDateKey(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar.current
        formatter.timeZone = Calendar.current.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private static func date(forLocalDateKey value: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar.current
        formatter.timeZone = Calendar.current.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        guard let date = formatter.date(from: value), formatter.string(from: date) == value else { return nil }
        return Calendar.current.startOfDay(for: date)
    }

    private func tickFocusSession() {
        guard let identity = authCoordinator?.currentIdentity,
              let bindingID = try? activeBindingRepository.load(for: identity) else { return }
        do {
            let (data, roundCompleted, previousTaskID) = try focusSessionRepository.tick(accountKey: identity.storageKey,
                                                                                          bindingID: bindingID)
            if roundCompleted { requestFocusNotification() }
            guard let taskID = data.activeTaskID ?? previousTaskID else { return }
            let state = focusBridgeValue(data: data, taskID: taskID, bindingID: bindingID)
            guard let payload = try? JSONSerialization.data(withJSONObject: state),
                  let json = String(data: payload, encoding: .utf8) else { return }
            webView.evaluateJavaScript("window.receiveFocusTick && window.receiveFocusTick(\(json));", completionHandler: nil)
        } catch {
            NSLog("Focus timer persistence failed: %@", error.localizedDescription)
        }
    }

    @objc private func pauseFocusForSleep(_ notification: Notification) {
        pauseActiveFocusSession()
    }

    private func pauseActiveFocusSession() {
        guard let identity = authCoordinator?.currentIdentity,
              let bindingID = try? activeBindingRepository.load(for: identity) else { return }
        try? focusSessionRepository.pauseCurrent(accountKey: identity.storageKey, bindingID: bindingID)
    }

    private func focusBridgeValue(data: FocusSessionData, taskID: String, bindingID: String) -> [String: Any] {
        let progress = data.tasks[taskID] ?? FocusTaskProgress()
        let breakRemaining = data.breakEndsAt.map { max(0, Int($0.timeIntervalSinceNow.rounded(.up))) } ?? 0
        return [
            "taskId": taskID,
            "bindingId": bindingID,
            "activeTaskId": data.activeTaskID as Any? ?? NSNull(),
            "mode": data.mode,
            "totalFocusedSeconds": progress.totalFocusedSeconds,
            "roundElapsedSeconds": progress.currentRoundSeconds,
            "completedRounds": progress.completedRounds,
            "roundDurationSeconds": data.configuration.workMinutes * 60,
            "breakRemainingSeconds": breakRemaining,
            "configuration": [
                "workMinutes": data.configuration.workMinutes,
                "shortBreakMinutes": data.configuration.shortBreakMinutes,
                "longBreakMinutes": data.configuration.longBreakMinutes,
                "longBreakEvery": data.configuration.longBreakEvery
            ]
        ]
    }

    private func requestNotificationPermissionIfNeeded() {
        guard !notificationPermissionRequestStarted else { return }
        notificationPermissionRequestStarted = true

        // focus.start is handled inside WKScriptMessageHandlerWithReply. Defer
        // the system permission UI until that synchronous WebKit callback exits.
        DispatchQueue.main.async { [weak self] in
            guard let center = self?.notificationCenter else {
                NSLog("Notifications are unavailable outside the packaged Todo.app bundle.")
                return
            }
            center.requestAuthorization(options: [.alert]) { granted, error in
                if let error {
                    NSLog("Notification authorization request failed: %@", error.localizedDescription)
                } else {
                    NSLog("Notification authorization granted: %@", granted ? "yes" : "no")
                }
            }
        }
    }

    private func requestFocusNotification() {
        guard let center = notificationCenter else { return }
        let content = UNMutableNotificationContent()
        content.title = "番茄钟完成"
        content.body = "这一轮专注结束了，可以休息一下。"
        content.sound = nil
        let request = UNNotificationRequest(identifier: UUID().uuidString,
                                            content: content,
                                            trigger: nil)
        center.add(request)
    }

    private func fieldMapping(from value: [String: Any]) -> FieldMapping? {
        guard let taskFieldID = value["taskFieldID"] as? String,
              let dateFieldID = value["dateFieldID"] as? String,
              let doneFieldID = value["doneFieldID"] as? String,
              let doneOptionID = value["doneOptionID"] as? String,
              let undoneOptionID = value["undoneOptionID"] as? String else { return nil }
        return FieldMapping(taskFieldID: taskFieldID,
                            dateFieldID: dateFieldID,
                            priorityFieldID: value["priorityFieldID"] as? String,
                            doneFieldID: doneFieldID,
                            doneOptionID: doneOptionID,
                            doneOptionName: "已完成",
                            undoneOptionID: undoneOptionID,
                            undoneOptionName: "未完成")
    }

    private func bridgeValue(for binding: ViewBinding) -> [String: Any] {
        [
            "id": binding.id,
            "viewId": binding.viewID,
            "name": binding.viewName ?? "多维表格待办",
            "url": binding.sourceURL.absoluteString,
            "open": true
        ]
    }

    private func bridgeValue(for snapshot: ViewSnapshot, stale: Bool) -> [String: Any] {
        var value: [String: Any] = [
            "fetchedAt": snapshot.fetchedAt.timeIntervalSince1970 * 1000,
            "stale": stale,
            "items": snapshot.items.map { item in
                [
                    "id": item.id,
                    "title": item.title,
                    "priority": item.priority as Any? ?? NSNull(),
                    "isDone": item.isDone,
                    "dateMilliseconds": item.dateMilliseconds,
                    "sourceOrder": item.sourceOrder,
                    "plannedDurationHours": item.plannedDurationHours as Any? ?? NSNull()
                ] as [String: Any]
            }
        ]
        if let issues = snapshot.projectionIssues, !issues.isEmpty {
            value["projectionIssues"] = issues.map { issue in
                [
                    "recordID": issue.recordID,
                    "dateMilliseconds": issue.dateMilliseconds as Any? ?? NSNull(),
                    "reason": issue.reason
                ] as [String: Any]
            }
        }
        return value
    }

    private func loadResourceError() {
        let message = "便签界面资源未找到。请重新运行 macOS 打包脚本。"
        let page = "<html><body style='font:14px -apple-system;padding:24px;background:#fdfd96'>\(message)</body></html>"
        webView.loadHTMLString(page, baseURL: nil)
    }

    private let desktopAdaptationScript = """
    (() => {
      const style = document.createElement('style');
      style.textContent = `
        html, body {
          width: 100%; height: 100%; min-height: 0; margin: 0; overflow: hidden;
          background: transparent !important;
        }
        body { display: block !important; place-items: initial !important; }
        .desktop {
          width: 100% !important; height: 100% !important; min-width: 0 !important; min-height: 0 !important;
          position: relative !important; border: 0 !important; border-radius: 0 !important;
          background: transparent !important; box-shadow: none !important; overflow: visible !important;
        }
        .note {
          position: absolute !important; inset: 0 !important; width: auto !important; height: auto !important;
          min-width: 0 !important; min-height: 0 !important; left: 0 !important; top: 0 !important;
          transform: none !important;
        }
      `;
      (document.head || document.documentElement).appendChild(style);
    })();
    """

}

@main
enum TodoDesktopMain {
    static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.run()
    }
}

private final class TodoNoteWebView: WKWebView {
    var onCloseCurrentPage: (() -> Void)?

    override func menu(for event: NSEvent) -> NSMenu? {
        nil
    }

}
