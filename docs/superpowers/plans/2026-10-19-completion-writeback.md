# Bitable Completion Writeback Implementation Plan

> **For agentic workers:** Execute this plan inline with small verification checkpoints.

**Goal:** Let users mark a task complete or undo completion in Todo, writing only the mapped completion field to Feishu and reconciling the displayed view.

**Architecture:** Add a typed PUT and single-record GET to `FeishuBitableClient`; resolve the current completion field name and option from field metadata in `BitableBindingService`; serialize same-record mutations in the native bridge; return a refreshed or safely stale snapshot to the UI. The WebView never receives tokens or sends arbitrary field names.

**Tech Stack:** Swift 5.9, Foundation URLSession, AppKit/WKWebView bridge, existing HTML/CSS/JavaScript.

**Spec:** `SPEC.md`, sections 4, 6, 14, 15, 17, and 20 milestone 4.

## Global Constraints

- Send only the mapped completion field in record update bodies.
- Keep access and refresh tokens in the native layer and Keychain.
- Do not claim cloud success until the update response or a record read confirms the desired value.
- Preserve service ordering and re-read the selected view after confirmed writes.
- Stale cached snapshots stay read-only; serialize writes per record and restore the prior UI state on failure.

---

### Task 1: Client update/read APIs and request tests

**Files:**
- Modify: `macOS/Sources/TodoDesktop/Services/FeishuBitableClient.swift`
- Modify: `macOS/Package.swift`
- Create: `macOS/Tests/TodoDesktopTests/FeishuBitableClientTests.swift`

- [x] Add URLProtocol-backed tests proving a record update uses PUT, Bearer auth, and only the requested mapped field/value, and that a record GET decodes the returned record.
- [x] Run those tests and confirm the expected methods are missing.
- [x] Implement generic authenticated request handling plus `updateRecord` and `getRecord`, preserving current GET behavior and API error decoding.
- [x] Run the focused tests and macOS Debug build.

### Task 2: Completion mutation and reconciliation

**Files:**
- Modify: `macOS/Sources/TodoDesktop/Services/BitableBindingService.swift`
- Modify: `macOS/Sources/TodoDesktop/Domain/BitableModels.swift`

- [x] Resolve the currently mapped single-select field by stored field ID; reject deleted/changed fields or options before writing.
- [x] Update one record with only `{ currentDoneFieldName: desiredOptionName }`.
- [x] If the update response is uncertain, GET that record once and accept only when the stored option matches the requested state; otherwise return an actionable error without retrying the write.
- [x] After confirmed update, refresh the whole selected view; if that refresh fails, persist and return the confirmed single-record state as stale so UI does not falsely roll back a successful write.

### Task 3: Bridge concurrency and UI behavior

**Files:**
- Modify: `macOS/Sources/TodoDesktop/TodoDesktopApp.swift`
- Modify: `macOS/Sources/TodoDesktop/Resources/prototype.html`

- [x] Add `todos.setDone` with current-account/binding/record validation and a native per-record in-flight guard.
- [x] Enable native checkboxes only for a fresh snapshot; disable the row while its write is pending.
- [x] On success render the returned reconciled snapshot; on failure restore the old checkbox state and show the returned error.
- [x] Preserve demo-mode prototype behavior and verify JavaScript syntax.

### Task 4: Documentation and verification

**Files:**
- Modify: `SPEC.md`

- [x] Mark the third milestone source/build work as implemented while explicitly retaining real-Base acceptance as pending.
- [x] Document the write bridge, confirmed-write reconciliation, and uncertainty handling.
- [x] Run the full Swift test suite and Debug package compile, check JavaScript syntax, and report that no live Feishu write was performed.
