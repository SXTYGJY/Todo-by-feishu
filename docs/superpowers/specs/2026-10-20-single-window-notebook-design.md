# Single-Window Notebook Lifecycle Design

**Date:** 2026-10-20  
**Status:** Implemented in source; native runtime acceptance pending
**Scope:** Complete the persistent notebook and note lifecycle using one native window.

## Context

The current app has one `NSWindow` and one `WKWebView`. Account workspaces already persist view bindings, and the app can inspect, create, and list bindings. In native mode, the WebView can switch its displayed binding from the notebook list, but the notebook entries are partly held in an HTML `localNotebook` array. Close and delete currently change only that in-memory array; AppKit does not yet provide the specified per-note context menu. The latest accepted writeback implementation exists in source, and the user has completed its acceptance; the previous `UNSUPPORTED_METHOD` report was from an older app bundle.

The user chose to implement single-window switching first. Simultaneous independent note windows are deferred.

## Goals

- Keep one `NSWindow` and one `WKWebView`; switch the displayed view binding through the notebook.
- Persist the currently displayed binding so restart restores it when appropriate.
- Closing the current note clears the active display while keeping its binding and snapshot in the account notebook.
- Deleting a binding removes only local workspace data, cached snapshot, and binding-specific window/UI preferences; it never changes Feishu data.
- Reopen a notebook entry only after validating the current account can still access the bound Base/table/view and mapped fields; refresh the view before showing it as current.
- Implement a native AppKit context menu at the click location with “上一页” and “关闭当前页”.
- Route HTML actions through native bridge methods for active binding state, close, delete, notebook list, and notebook open.
- Keep tokens and Feishu API access in the native layer.

## Non-Goals

- Multiple `NSWindow` instances or simultaneous visible notes.
- Persistent background image, opacity, or font settings; these belong to a later phase.
- Feishu auto-launch, background polling, or production token-exchange service.
- Changing Bitable schema, task data, or completion-writeback behavior.

## Architecture

### One-window state model

`AppDelegate` remains the owner of one window, one WebView, and one bridge. Add a small `NoteSessionCoordinator` (or an equivalently focused service) to hold the active binding ID and perform persisted notebook operations. The workspace remains the source of truth for all non-deleted bindings; the coordinator stores only which binding is currently displayed and whether the UI is in the closed-note empty state.

Persist the active binding ID in the account workspace or a separate account-keyed UI-state file. On launch:

1. Read the authenticated Feishu identity and that account's workspace.
2. If a persisted active binding exists, load its cached snapshot as stale, validate access and mapping, refresh, then display it. If validation/refresh fails, retain the binding in the notebook and show the cache as read-only with an actionable error.
3. If there is no active binding but one or more saved bindings, show a neutral “便签已关闭” state with `+`, `…`, and a notebook entry. Do not imply the account has never bound a view.
4. If no binding exists, retain the existing unbound onboarding state.

The active binding ID is scoped to the authenticated identity. Signing out clears the active display; signing into another account loads only that account's workspace and UI state.

### Lifecycle operations

- **Create/bind:** retain current URL inspection, field mapping, and binding creation. Persist the returned binding as active and show its fresh snapshot in the single window.
- **Notebook list:** return only non-deleted bindings from the native repository, including whether the selected binding is active. Do not use the HTML array as the source of truth.
- **Open/switch:** accept a binding ID, confirm it belongs to the current identity, re-read view/field metadata, refresh the selected view, persist the active binding ID, and then update the WebView. If validation fails, keep the prior visible note (if any), leave the target binding in the notebook, and display the failure.
- **Close current page:** clear the active binding ID but keep the binding and snapshot. Render the neutral closed-note state; the Todo process and window remain usable so the user can reopen a note from the notebook without restarting Feishu or Todo.
- **Delete:** require the existing confirmation; reject deleting the last non-deleted binding. Remove only the selected binding and its snapshot/preferences. If it was active, switch to the closed-note state or another explicitly active binding. Never call Feishu delete APIs.
- **Refresh:** refresh the active binding only. Preserve the current note if refresh fails and mark it stale/read-only.

### Native context menu

Install an AppKit context-menu handler for the note surface. The menu is anchored to the actual right-click position. “上一页” invokes a narrow JavaScript entry point in the same WebView to decrement its date offset. “关闭当前页” calls the same native close operation as the HTML menu. On the unbound/closed-note state, omit or disable “上一页”; close remains harmless and does not delete a binding.

The HTML `closeCurrentPage` and `deleteCurrentNote` functions call native bridge methods in app mode and retain local-only behavior only in standalone demo mode.

## Bridge Contract

- `notebook.list` → `{items:[{id,name,url,isActive,snapshot?}]}`
- `notebook.open` `{bindingId}` → validates ownership/access, refreshes, persists active binding, returns fresh snapshot
- `notes.closeCurrent` `{bindingId}` → verifies it is the active binding, clears persisted active binding, returns closed state
- `notes.deleteBinding` `{bindingId}` → validates last-binding rule, deletes local binding/snapshot, returns updated notebook and active state
- `notes.setDone` remains unchanged and continues to require a fresh snapshot.

Each bridge operation validates the current account and resolves binding IDs only through its workspace. The WebView receives no access or refresh token.

## Failure Behavior

- If offline during notebook open, do not claim fresh validation. Keep the entry and show the reason. A previously cached snapshot may be shown read-only only when it is the currently active binding; selecting a different closed entry requires successful validation before switching.
- If a view, field, or permission is missing, preserve the binding and explain the cause.
- If workspace persistence fails, do not report open/close/delete as successful and keep or restore the previous visible state.
- If snapshot cleanup fails after deleting a binding, report the local cleanup failure and retry cleanup on next launch; Feishu data is untouched.
- Reject bridge requests whose binding ID is not owned by the current authenticated identity.

## Acceptance Criteria

1. Two bindings appear as separate entries in the notebook; opening either switches the single window to that view and shows only its records.
2. A successful switch is persisted; restarting Todo restores that account's selected binding and refreshes it.
3. Closing the current note shows the closed-note state, preserves the notebook entry/cache, and leaves Todo running. The entry can be reopened without restarting either app.
4. Deleting a non-final binding removes its local entry and snapshot only; the Feishu view and records remain unchanged.
5. Deleting the last non-deleted binding is rejected; closing the last displayed note remains allowed.
6. If the selected view is deleted or permission is revoked, switching fails with an explanation and preserves both the binding and prior displayed note.
7. Right-click opens an AppKit menu at the click location; “上一页” changes the active note's date by one day; “关闭当前页” follows the persistent close behavior.
8. Account A's selected binding and snapshot do not appear while account B is active; switching back restores A's state.
9. Existing version-1 workspace files decode without data loss.
10. Unit tests cover account isolation, active-binding persistence, close/delete behavior, last-binding protection, and snapshot cleanup. Manual acceptance covers menu location, switching, restart, and account switching.

## Implementation Boundaries

Expected areas: `Domain/ViewBinding.swift` only if a persisted state field is needed; `Storage/WorkspaceRepository.swift`; `Services/BitableBindingService.swift`; `TodoDesktopApp.swift`; `Bridge/TodoBridgeHandler.swift`; and `Resources/prototype.html`. Add focused service tests under `macOS/Tests/TodoDesktopTests/`. Do not add multi-window abstractions in this phase. Defer settings persistence and unrelated visual redesign.

## Design Self-Review

- **Scope:** one-window notebook lifecycle only; multi-window support and preference persistence are explicitly excluded.
- **Data source:** workspace bindings remain the source of truth; cached task snapshots remain read-only fallback data, never a second task database.
- **Compatibility:** if the workspace schema is unchanged, active selection can use a separate account-keyed UI-state file; if the schema changes, decoding must default safely for existing version-1 files. Implementation should prefer the separate UI-state file to avoid an unnecessary schema migration.
- **Safety:** delete operations touch only local files; opening another entry validates before changing the currently displayed note.
- **Testability:** repository/service behavior is covered by deterministic unit tests; AppKit menu positioning and WebView switching remain manual acceptance items.

## Implementation Record (2026-10-20)

- Added an account-scoped active-binding sidecar repository; version-1 workspace files remain unchanged.
- Added native bridge operations for notebook list/open, persistent close, and local binding deletion. Opening another binding validates and refreshes before persisting the switch.
- Added a closed-note empty state and notebook-entry deletion controls. Local delete protects the last binding, removes only workspace/cache data, and retries snapshot cleanup for tombstoned entries.
- Added a native AppKit `WKWebView` context menu with “上一页” and “关闭当前页”; page navigation now uses an integer day offset.
- `swift build` completed successfully on 2026-10-20. Automated tests and native UI acceptance have not been run in this development step.

## Manual Acceptance Checklist

- Add two distinct view bindings under one Feishu account; both appear in the notebook.
- Switch between them; each switch revalidates access and refreshes before replacing the currently displayed note.
- Make one view unavailable; switching to it reports the error and leaves the prior note displayed.
- Close the current note; the “便签已关闭” state remains in the same window and can reopen the binding from the notebook without restarting Todo or Feishu.
- Restart Todo; the previously active binding is restored from that account's state and its cache remains read-only if refresh fails.
- Delete a closed/non-current entry from the notebook; it disappears locally and its Feishu view/records remain untouched.
- Confirm the last remaining binding cannot be deleted but can be closed.
- Sign out and sign in to another Feishu account; no bindings or snapshots cross accounts; switching back restores the first account's state.
- Right-click at several points on the note; the native menu appears at the pointer with “上一页” and “关闭当前页”. Previous page decrements the date; close clears the active note only.
