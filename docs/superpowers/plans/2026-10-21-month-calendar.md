# Monthly Calendar Navigation Implementation Plan

**Goal:** Add a monthly calendar home state that works before a view is bound and remains reachable from a bound daily task view.

**Architecture:** Keep date selection in the existing HTML/WebView layer, reuse the selected date already persisted per binding, and add a compact 42-cell month grid with month navigation. The empty state shows the calendar and existing Feishu authorization/binding action; a bound task view can switch to the same calendar and return by selecting a date.

**Tech Stack:** Inline HTML, CSS, and JavaScript; existing Swift/AppKit bridge and per-binding note preferences.

**Spec:** `SPEC.md`, section 6, monthly calendar navigation.

## Global Constraints

- Feishu remains the task source of truth.
- Calendar cells do not infer task counts or status from incomplete view coverage.
- Existing daily navigation, date projection, writeback, and sort order remain unchanged.
- Preserve the date chosen in the unbound calendar when the first binding is created.

## Files

- Modify `prototype.html` for the standalone interaction prototype.
- Modify `macOS/Sources/TodoDesktop/Resources/prototype.html`, the resource loaded by the macOS app.
- Modify `SPEC.md` to record the approved calendar scope and behavior.

## Tasks

### Task 1: Record the approved behavior

- [x] Update the product goal and MVP scope to include a month calendar before and after binding.
- [x] Remove the conflicting statement that calendar is out of scope.
- [x] Document month navigation, date selection, empty-date copy, and selected-date behavior on first binding.

### Task 2: Add monthly calendar UI

- [x] Add a calendar view with previous/next month controls, a Today control, weekday labels, and a fixed six-week date grid.
- [x] Mark today and selected date distinctly; render adjacent-month days muted.
- [x] Keep the existing auth/binding action in the unbound calendar and hide it when opening the calendar from a bound note.
- [x] Add a small calendar entry control to the bound task date navigation.

### Task 3: Connect date navigation

- [x] Render the initial month using the selected date.
- [x] Month arrows change only the displayed month.
- [x] Selecting a date updates the selected date; with a binding it returns to the task view, without a binding it remains on the calendar.
- [x] Today selects the local current date and returns the calendar month to the current month.
- [x] Keep selected date in existing per-binding preferences and preserve a date chosen before the first binding is created.

### Task 4: Verify

- [x] Parse inline JavaScript in both HTML files.
- [x] Review both standalone and packaged HTML for matching calendar IDs, handlers, and key states.
- [x] Run `swift build` in `macOS/` to verify the app resource is accepted and packaged.

