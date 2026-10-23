# OAuth 与视图绑定基础实施计划

> 本计划依照已批准的 `SPEC.md` 第二里程碑执行；本次不实现未经确认的 OAuth 令牌交换，也不将模拟校验报告为真实绑定成功。

**目标：** 为真实 macOS 应用建立可持久化的视图链接接收、协议化 WebView 桥接和账号 workspace 存储，等待已验证的飞书 OAuth 后继续资源校验。

**架构：** Swift/AppKit 宿主管理链接解析、待授权链接和账号 workspace；WKWebView 通过版本化 request/result 消息调用宿主。HTML 文件直接预览时继续保留原型模拟交互，原生应用环境只显示真实宿主状态，不生成假绑定。

**技术栈：** Swift 5.9、Foundation、AppKit、WebKit、Codable、Application Support JSON 文件。

**规格：** `SPEC.md` 第 14、15、20 节。

## 全局约束

- 任务内容的唯一事实来源仍是飞书多维表格；本机只存绑定、界面偏好和待授权链接。
- 用户提供的 `App Secret` 由原生界面输入并保存在本机 Keychain；不得进入便签 HTML/WebView bridge、workspace JSON 或日志。此处旧的安全边界已由后续批准的用户自建应用直连方案取代。
- 只有 OAuth 身份、资源、字段和权限校验都通过后才创建正式绑定。
- 待授权链接不是已绑定便签，不显示模拟任务，也不伪称资源可访问。
- 不新增第三方运行时依赖。
- 当前阶段不发起 Bitable 网络请求；OAuth 与真实 API 接入要等安全方案确认。

---

### Task 1：资源定位与账号 workspace 持久化

**文件：**
- 新建：`macOS/Sources/TodoDesktop/Domain/FeishuIdentity.swift`
- 新建：`macOS/Sources/TodoDesktop/Domain/ViewBinding.swift`
- 新建：`macOS/Sources/TodoDesktop/Services/ViewLinkParser.swift`
- 新建：`macOS/Sources/TodoDesktop/Storage/WorkspaceRepository.swift`
- 新建：`macOS/Sources/TodoDesktop/Storage/PendingViewLinkStore.swift`

**接口：**
- `ViewLinkParser.parse(_:) throws -> ParsedViewLink`：HTTPS 飞书 URL 解析 Base 或 wiki token、`table_id`、`view_id`；缺少标识、非飞书域名、非 HTTPS 或 URL 凭据均返回明确错误。
- `WorkspaceRepository.load(for:) throws -> AccountWorkspace`、`save(_:) throws`：以 `FeishuIdentity(userID, tenantID)` 隔离存取 `Application Support/TodoDesktop/workspaces/` 下的 Codable JSON；文件名使用身份摘要，不在路径泄露身份原文。
- `PendingViewLinkStore.load() -> String?`、`save(_:)`、`clear()`：在授权尚未接通时保留用户刚粘贴的 URL，供授权成功后继续绑定。
- 持久化结构不包含 access token、refresh token、App Secret 或任务记录。

**验收：** `swift build` 通过；源码审查确认路径按身份摘要隔离、待授权链接可清除、workspace JSON 不含凭证字段。

### Task 2：Native ↔ WebView 请求/结果桥

**文件：**
- 新建：`macOS/Sources/TodoDesktop/Bridge/BridgeMessage.swift`
- 新建：`macOS/Sources/TodoDesktop/Bridge/TodoBridgeHandler.swift`
- 修改：`macOS/Sources/TodoDesktop/TodoDesktopApp.swift`

**接口：**
- 入站消息统一为 `{ protocolVersion: 1, requestId: string, method: string, params: object }`。
- 出站结果统一为 `{ protocolVersion: 1, requestId: string, ok: boolean, result?: object, error?: { code, message } }`。
- 首批处理 `app.bootstrap`、`notes.list`、`notebook.list`、`notes.createBinding`。
- 未连接账号时，`notes.createBinding` 先校验链接并持久化 pending URL，返回 `AUTH_REQUIRED`；不得创建 workspace binding。
- `app.bootstrap` 返回 `authenticated: false` 与 `pendingViewUrl`；应用启动时前端据此保持空白便签并回填链接。
- 保留现有 `togglePinned` 原生动作，逐步纳入 request/result 协议，不破坏已实现置顶。

**验收：** `swift build` 通过；检查请求版本、未知方法、无身份提交和 URL 解析错误均返回协议错误，不造成成功提示。

### Task 3：区分原型演示与原生应用状态

**文件：**
- 修改：`prototype.html`
- 修改：`macOS/Sources/TodoDesktop/Resources/prototype.html`（与根原型保持一致）
- 修改：`macOS/Sources/TodoDesktop/TodoDesktopApp.swift`

**行为：**
- 原生应用中绑定、便签夹和启动空态使用 Native bridge 返回的数据；禁止用 `localNotebook` 临时数组创建假绑定。
- 未授权提交合法链接后显示“链接已保存，完成飞书授权后继续”，保留表单链接；无效链接显示解析错误。
- 直接打开 `prototype.html` 时继续使用现有本地演示逻辑，并明确它仍是原型预览。
- 新增绑定的资源预览与字段映射 UI 留给 OAuth 和 Bitable metadata adapter 完成后；本任务不提供假资源信息。

**验收：** `swift build` 通过；确认原生桥不可用时原型仍能独立演示，原生桥可用时没有示例任务被展示为真实账号数据。

## 当前计划未覆盖的后续步骤

- 飞书 OAuth 授权码、回调、令牌换取/刷新、身份识别与 Keychain 保存。
- Base/table/view 权限验证、元数据读取、字段映射及 schema 校验。
- Bitable 记录读取、任务投射、完成字段写回和刷新策略。
- 多窗口便签夹的真实窗口创建与生命周期。

**历史说明（方案已被后续决策取代）：** 本计划编写时曾暂缓令牌交换，理由是尚未确定 App Secret 边界。后续产品决策明确不部署公网令牌服务，改为每位用户在自己的飞书组织创建应用、在 Todo 原生凭证面板录入 App ID/App Secret，凭证写入 Keychain，桌面客户端直接请求飞书 OAuth endpoint。该历史段落不再作为当前实现约束。

## 本轮完成记录

- Task 1：已完成身份摘要、Base/wiki 链接解析、workspace Codable 模型及 Application Support/UserDefaults 存储实现。
- Task 2：已完成协议版本/requestId 桥、bootstrap、空 notebook、置顶消息与待授权链接保存。
- Task 3：已完成 Native host 与独立原型演示分流；Native 未授权时不会创建绑定或展示假任务。
- 验证：`swift build` 通过；原型内联 JavaScript 通过 `node --check`；原型与 Swift Package 资源副本一致。
- 未完成：真实飞书授权与资源验证尚未接通；Native App 的视觉交互尚未手动验收。
