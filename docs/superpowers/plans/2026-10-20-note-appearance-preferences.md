# Per-Note Appearance Preferences Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Persist the background image, paper opacity, and Chinese/English fonts independently for each Feishu account and bound note.

**Architecture:** Add an account-scoped native preferences repository under Application Support. Keep image bytes in an asset file and store only its filename with validated appearance values in a small JSON record. Expose load/update through the existing WebView bridge and restore the saved settings when a note becomes active.

**Tech Stack:** Swift, AppKit host, WKWebView bridge, HTML/CSS/JavaScript.

**Spec:** `SPEC.md`, sections 14–16 and 20.

## Global Constraints

- Keep tokens, App Secret, and task rows out of preference storage.
- Separate data by Feishu account and binding ID.
- Preserve existing `AccountWorkspace` schema and Bitable task behavior.
- Store custom image bytes as a file, not inline in JSON.
- Do not add or run automated tests unless requested; run a build check only.

---

### Task 1: Add native per-binding appearance storage

**Files:**
- Create: `macOS/Sources/TodoDesktop/Storage/NotePreferencesRepository.swift`
- Modify: `macOS/Sources/TodoDesktop/TodoDesktopApp.swift`

**Interfaces:**
- `load(accountKey:bindingID:) -> [String: Any]` returns defaults or stored appearance values and an optional data URL for the saved image.
- `save(accountKey:bindingID:patch:) -> [String: Any]` validates supported fonts, opacity, image MIME type, and a 5 MB limit; writes image assets separately and returns the normalized preference payload.
- `delete(accountKey:bindingID:)` removes that binding's preference JSON and image asset.

- [x] Add repository with account-scoped directories and atomic JSON writes.
- [x] Handle image replace/remove and preserve existing image on unrelated patches.
- [x] Add async bridge handlers `notes.getPreferences` / `notes.setPreferences`.
- [x] Remove preference files when a binding is deleted.

### Task 2: Restore and save preferences in the note UI

**Files:**
- Modify: `macOS/Sources/TodoDesktop/Resources/prototype.html`
- Mirror: `prototype.html`

- [x] Apply binding preferences when bootstrap, notebook restore, or notebook switching activates a binding.
- [x] Send updates for opacity, Chinese font, English font, image upload, and image removal through `notes.setPreferences`.
- [x] Keep the standalone HTML prototype functional without the native host.
- [x] Keep appearance updates local immediately and surface save failures without losing the current in-memory appearance.

### Task 3: Update status and build

**Files:**
- Modify: `SPEC.md`

- [x] Mark per-binding appearance persistence as implemented and update remaining milestone wording.
- [x] Build with `swift build` from `macOS/`.
- [x] Report manual runtime verification still needed for image picker, account separation, and settings after restart.
