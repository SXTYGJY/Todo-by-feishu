# Pomodoro and Planned Duration Implementation Plan

**Goal:** Add optional Feishu planned-duration projection and creation, plus a local, per-task Pomodoro timer with a dedicated focus screen.

**Architecture:** Extend existing Bitable field mapping and projection with the optional numeric field named `计划时长`. Add a local JSON focus store scoped to Feishu identity and binding, and expose timer state/actions through the existing WKWebView bridge. Keep Feishu as the source for tasks and estimates; keep elapsed focus time local.

**Tech Stack:** Swift 5.9, AppKit, UserNotifications, existing WKWebView HTML/CSS/JavaScript bridge, JSONEncoder persistence.

**Spec:** `SPEC.md`, approved Pomodoro decisions from 2026-10-22.

## Global Constraints

- Keep task data and optional planned duration in the bound Feishu view.
- Store actual focused time and timer state only on this Mac, isolated by account and binding.
- The optional number field must be named `计划时长`; absence must not block task projection or Pomodoro.
- A work round triggers rest only after its full configured duration; switching tasks pauses that task's unfinished round.
- Do not add sounds or write focused time back to Feishu.

## Files

- Modify `macOS/Sources/TodoDesktop/Domain/BitableModels.swift` for optional field mapping and projection.
- Modify `macOS/Sources/TodoDesktop/Services/BitableBindingService.swift` for field discovery, projection and task creation.
- Create `macOS/Sources/TodoDesktop/Storage/FocusSessionRepository.swift` for local JSON persistence and timer rules.
- Modify `macOS/Sources/TodoDesktop/TodoDesktopApp.swift` for bridge operations, native notifications and lifecycle cleanup.
- Modify `macOS/Sources/TodoDesktop/Resources/prototype.html` for duration input, task display and focus UI.
- Modify `SPEC.md` to record implemented scope and boundaries.

## Tasks

1. Add optional `计划时长` mapping by exact field name and Number type; tolerate absent/mismatched fields.
2. Project the numeric value to each Todo and include optional numeric value in Feishu record creation.
3. Persist per-task elapsed seconds, unfinished work-round progress, completed rounds and configurable work/rest durations in account/binding scoped JSON.
4. Add bridge operations to read/start/pause/complete task timers and delete the binding's focus data.
5. Render planned duration when available, accept an optional half-hour-step value in the new-task form, and add a task-specific Pomodoro focus screen.
6. Update SPEC and perform a Swift build plus inline JavaScript syntax check; do not run the test suite in this pass.

