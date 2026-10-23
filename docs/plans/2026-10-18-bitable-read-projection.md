# Milestone 3: Feishu Bitable Read Projection Implementation Plan

> **For agentic workers:** This plan is being executed inline in the current session. Follow each task in order.

**Goal:** Complete the read-only projection milestone so an authorized account can bind a Bitable view, map fields, read the view's paginated records, cache a successful snapshot, and display today's tasks in the native Todo window.

**Architecture:** Keep Feishu tokens inside the native Swift layer. Add a Bitable API client for view metadata, fields, and paginated records; persist bindings and display-only snapshots per Feishu identity; expose only mapped task DTOs through the existing WKWebView bridge. The frontend performs no view sorting and filters only by the mapped local-calendar date, as specified.

**Tech Stack:** Swift 5.9, AppKit, WKWebView, URLSession, Foundation Codable, existing HTML/CSS/JS prototype.

**Spec:** `SPEC.md`, especially sections 5–7, 14–18, and milestone 3 in section 20.

## Global Constraints

- Feishu remains the source of truth; this milestone is read-only and does not write completion state.
- Keep access/refresh tokens native and in Keychain; never send them through the WebView bridge or logs.
- Preserve server record order and only filter records by the configured date for the selected day.
- Do not reconstruct Feishu view filtering or sorting in Todo.
- Retain the last fully successful snapshot when a refresh fails and expose it as stale/read-only.
- No test files or test commands are included in this run; compile/package verification is the requested implementation check.

---

### Task 1: Bitable API and data decoding

**Files:**
- Create: `macOS/Sources/TodoDesktop/Services/FeishuBitableClient.swift`
- Create: `macOS/Sources/TodoDesktop/Domain/BitableModels.swift`
- Modify: `macOS/Sources/TodoDesktop/Auth/AuthCoordinator.swift`

- [ ] Add authenticated request helpers for view metadata, paginated field metadata, and paginated view records.
- [ ] Decode Bitable's `{code,msg,data}` envelopes and preserve arbitrary field values safely.
- [ ] Use `AuthCoordinator.validAccessToken()` for each API request; never expose the token to JS.
- [ ] Fail with actionable HTTP/business error messages and no sensitive payload logging.

### Task 2: Binding and snapshot persistence

**Files:**
- Modify: `macOS/Sources/TodoDesktop/Domain/ViewBinding.swift`
- Modify: `macOS/Sources/TodoDesktop/Storage/WorkspaceRepository.swift`
- Create: `macOS/Sources/TodoDesktop/Storage/SnapshotRepository.swift`
- Create: `macOS/Sources/TodoDesktop/Services/BitableBindingService.swift`

- [ ] Validate the supplied app/table/view through OpenAPI.
- [ ] Require explicit field mapping for task text, date, priority, and completion; completion options must include “未完成” and “已完成”.
- [ ] Store field and option IDs, not names, while retaining names for display.
- [ ] Persist the binding under the current identity and store only mapped display DTO snapshots.
- [ ] Reject duplicate bindings for the same view and preserve the prior snapshot if refresh fails.

### Task 3: Bridge and live frontend projection

**Files:**
- Modify: `macOS/Sources/TodoDesktop/TodoDesktopApp.swift`
- Modify: `macOS/Sources/TodoDesktop/Resources/prototype.html`

- [ ] Implement `notes.inspectBinding`, `notes.createBinding`, `notes.list`, `notes.refresh`, and `notes.openSource`.
- [ ] Send only safe DTOs through the bridge: binding ID, field labels, mapped tasks, fetch time, stale state, and UI errors.
- [ ] Add field mapping controls to the existing bind dialog and keep the current account/empty/auth UI.
- [ ] Replace native-mode demo tasks with live mapped data, display today's items in service order, and mark cached snapshots stale/read-only on API failure.
- [ ] Keep checkbox writes disabled until milestone 4; do not imply local-only completion as cloud success.

### Task 4: Spec status and build verification

**Files:**
- Modify: `SPEC.md`

- [ ] Update milestone 2/3 status and document the read-only boundary and any API compatibility caveats.
- [ ] Run the macOS Debug package build and verify the generated app signature.
- [ ] Report build results and remaining milestone 4 work clearly.

