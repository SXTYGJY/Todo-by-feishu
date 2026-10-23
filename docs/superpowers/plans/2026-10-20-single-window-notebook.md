# Single-Window Notebook Lifecycle Implementation Plan

> **For agentic workers:** Execute this plan inline with small verification checkpoints. Steps use checkbox (`- [x]`) syntax for tracking.

**Goal:** Complete single-window notebook switching with persistent account-scoped selection, reliable close/delete actions, and an AppKit context menu.

**Architecture:** Keep one `NSWindow` and one `WKWebView`. Native workspace storage remains the source of truth for bindings; a separate account-keyed state file stores the active binding. The WebView requests open, close, delete, and list operations through the existing bridge, while AppKit owns the right-click menu.

**Tech Stack:** Swift 5.9, AppKit, WebKit, Foundation JSON storage, existing HTML/CSS/JavaScript UI.

**Spec:** `docs/superpowers/specs/2026-10-20-single-window-notebook-design.md`

## Global Constraints

- Keep exactly one note window and one WebView.
- Scope bindings, snapshots, and active selection to the authenticated Feishu identity.
- Opening another binding must validate and refresh it before changing the visible note.
- Closing keeps the binding and snapshot; deleting removes local data only and never calls Feishu deletion APIs.
- Preserve the existing workspace schema version and decode existing version-1 workspace files.
- Do not add multi-window behavior, background polling, production token service, or preference persistence.

---

### Task 1: Persist account-scoped active binding and local delete operation

**Files:**
- Create: `macOS/Sources/TodoDesktop/Storage/ActiveBindingRepository.swift`
- Modify: `macOS/Sources/TodoDesktop/Services/BitableBindingService.swift`

**Interfaces:**
- `ActiveBindingRepository.load(for:) throws -> String?`
- `ActiveBindingRepository.save(_:for:) throws` where `nil` clears the selection.
- `BitableBindingService.deleteBinding(id:identity:) throws -> String?` removes the local binding and snapshot, retaining a tombstone only when snapshot cleanup must be retried.
- `BitableBindingService.bindings(for:)` retries cleanup for previously soft-deleted entries and returns only live bindings.

- [x] Add an account-keyed atomic JSON file under Application Support with private directory/file permissions.
- [x] Validate the state file's account key and schema version before returning its active binding.
- [x] Remove the workspace binding and local snapshot; retain a tombstone only when snapshot cleanup needs retry, and never call the Feishu client.
- [x] Retry stale snapshot cleanup for soft-deleted bindings when loading that account's notebook.

### Task 2: Implement native bridge lifecycle and restore behavior

**Files:**
- Modify: `macOS/Sources/TodoDesktop/TodoDesktopApp.swift`

**Interfaces:**
- `notebook.list` returns `{items, activeBindingId}` with `isActive` on each item.
- `notebook.open {bindingId}` validates ownership, refreshes the target view, persists selection, then returns its fresh snapshot.
- `notes.closeCurrent {bindingId}` clears active selection only when the ID matches the current account's active binding.
- `notes.deleteBinding {bindingId}` enforces the last-binding rule, clears active selection if needed, deletes local binding/cache, and returns the updated notebook plus optional cleanup warning.
- `notes.createBinding` persists the new binding as active.

- [x] Add the active-selection repository to `AppDelegate`.
- [x] Update notebook listing to mark the persisted active entry and include cached snapshots without selecting an arbitrary first entry.
- [x] Implement validate-refresh-persist ordering for `notebook.open`; errors must leave the previous active selection untouched.
- [x] Implement persistent close, local delete, and new-binding selection through the async bridge.
- [x] Keep cached launch restore read-only when refresh fails, scoped to the previously active binding.

### Task 3: Connect notebook UI, closed state, and page navigation

**Files:**
- Modify: `macOS/Sources/TodoDesktop/Resources/prototype.html`
- Modify: `prototype.html` (keep the standalone preview aligned with the shipped resource)

**Interfaces:**
- `window.__todoPreviousPage()` moves the visible note one date backward.
- `window.__todoCloseCurrentPage()` calls the same native close bridge operation as the in-app action.
- Native notebook selection uses `notebook.open`; it changes the visible note only after success.

- [x] Add a neutral `便签已关闭` state with the existing add/menu actions and a way to open the notebook.
- [x] Restore the account's persisted active note on startup; if no active note exists, show the closed state when bindings exist.
- [x] Keep a closed or deleted binding in the native notebook model as appropriate; do not use the HTML array as native source of truth.
- [x] Route close/delete actions through native bridge in app mode while retaining standalone preview behavior.
- [x] Replace the today/tomorrow toggle with a date offset so native “上一页” moves back one day and the paper-corner action advances one day.
- [x] Preserve previous note and dialog state when a notebook open request fails.

### Task 4: Add native contextual menu

**Files:**
- Modify: `macOS/Sources/TodoDesktop/TodoDesktopApp.swift`

**Interfaces:**
- `TodoNoteWebView.menu(for:)` returns an AppKit menu anchored by the native right-click event.
- “上一页” calls the WebView's `window.__todoPreviousPage()` entry point.
- “关闭当前页” calls the WebView's `window.__todoCloseCurrentPage()` entry point.

- [x] Use a focused `WKWebView` subclass to provide “上一页” and “关闭当前页” actions at the native click location.
- [x] Disable “上一页” when no active binding exists.
- [x] Keep close idempotent and ensure it never deletes a binding.

### Task 5: Review compatibility and document manual acceptance

**Files:**
- Modify: `docs/superpowers/specs/2026-10-20-single-window-notebook-design.md`

- [x] Record the implemented bridge behavior and any deviation from the approved acceptance criteria.
- [x] Ensure manual acceptance covers two-view switching, restart restore, offline active snapshot, close/reopen, last-binding delete protection, account isolation, and native menu location/actions.
- [x] Preserve the existing unit-test suite unchanged in this development step; run no tests unless explicitly requested.

## Self-Review

- **Spec coverage:** Tasks 1–2 cover account-scoped selection, close, delete, last-binding protection, stale-cache cleanup, and launch restore; Tasks 3–4 cover UI state and native context actions; Task 5 records compatibility and manual acceptance.
- **No new dependencies:** All work uses the existing Swift/AppKit/WebKit stack.
- **Compatibility:** Active selection is in a new sidecar file, so schema version 1 workspaces remain unchanged.
- **Data safety:** Open changes selection only after a successful refresh; deletion affects only the local workspace and cache.
