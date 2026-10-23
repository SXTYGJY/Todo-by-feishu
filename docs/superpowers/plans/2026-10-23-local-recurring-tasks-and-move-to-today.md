# 本机固定待办与迁移到今天实施计划

> 本计划按用户已确认的产品策略直接执行，不涉及新增飞书字段。

**目标：** 为每张便签增加本机固定待办管理、按日期幂等创建飞书任务，并允许把视图中昨天的未完成任务通过原生右键菜单迁移到今天。

**架构：** 固定任务定义及发生记录去重账本保存在账号/便签隔离的本机偏好 JSON 中；在便签管理中增删改，新增时立即按当前选中日期复用现有 Bitable 创建记录流程。日常打开/刷新仍补建当天记录。迁移使用 WKWebView 的原生桥接菜单，只更新绑定日期字段并刷新视图快照，前端乐观移动任务。

**技术栈：** Swift 5、AppKit、WKWebView、现有飞书 Bitable OpenAPI 客户端、原生 JSON 偏好存储、内联 HTML/CSS/JavaScript。

**SPEC：** `SPEC.md` §6、§7、§15、§19。

## 全局约束

- 不新增或要求新增飞书字段；日期、优先级、完成情况和可选计划时长继续复用现有映射。
- 固定定义是本机偏好；每日发生项是飞书记录，状态/优先级/计划时长沿用模板。
- 每日发生项以账号、binding、模板 ID、日期构成幂等键，重试不得重复创建。
- 手动迁移仅适用于当前绑定视图快照中可见的昨天未完成项，只改日期字段。
- 继续复用现有原生 bridge 和便签 UI；不引入第三方依赖。

### Task 1：SPEC 与接口契约

**文件：** `SPEC.md`、本计划。

- [x] 明确本机固定任务模型、生成时机、去重与失败重试规则。
- [x] 明确昨天任务迁移前置条件、乐观更新、回滚和视图筛选边界。
- [x] 补充单元、集成和端到端验证覆盖点。

### Task 2：偏好模型与固定任务管理 UI

**文件：** `macOS/Sources/TodoDesktop/Storage/NotePreferencesRepository.swift`、`macOS/Sources/TodoDesktop/Resources/prototype.html`。

- [x] 给旧 JSON 增加兼容解码，保存每张便签的固定任务定义和每日发生账本。
- [x] 在 `… > 便签管理 > 固定事项` 面板列出当前便签模板，并支持新建、编辑和删除。
- [x] 读取当前 binding 的优先级选项；偏好修改即时写本机，新增后按当前选中日期立即写入飞书。

### Task 3：每日发生项幂等创建

**文件：** `macOS/Sources/TodoDesktop/Services/BitableBindingService.swift`、`macOS/Sources/TodoDesktop/TodoDesktopApp.swift`。

- [x] 刷新当前便签时检查本地当天尚未生成的模板；新建模板时支持指定当前选中日期立即生成。
- [x] 用稳定的 UUID client_token 调用现有创建 API；仅生成未完成记录并沿用计划时长。
- [x] 成功后持久化 occurrence record ID，失败保留同一 token 供重试；所有生成后一次刷新视图。

### Task 4：昨天任务右键迁移

**文件：** `macOS/Sources/TodoDesktop/Bridge/TodoBridgeHandler.swift`、`macOS/Sources/TodoDesktop/TodoDesktopApp.swift`、`macOS/Sources/TodoDesktop/Services/BitableBindingService.swift`、`macOS/Sources/TodoDesktop/Resources/prototype.html`。

- [x] 前端任务行右键事件发送 record/binding/鼠标坐标；原生弹出鼠标位置菜单。
- [x] 只对当前快照中的昨天未完成任务提供“迁移到今天”。
- [x] 前端先乐观切换到今天并显示该任务；原生只更新日期字段，刷新后用视图结果确认。
- [x] API 失败回滚日期并显示错误；若记录被视图筛选排除，提示检查视图筛选并以刷新结果为准。

### Task 5：验证与完成

**文件：** 源码与 SPEC。

- [x] 编译 macOS Debug app，检查 HTML/JS 语法与 Swift 编译结果。
- [x] 核对偏好旧版兼容、scope 隔离、日期/时区和失败路径；不触碰真实用户 Bitable 数据。
- [x] 更新 SPEC 里程碑与原“每日固定任务暂不实现”的旧状态。
