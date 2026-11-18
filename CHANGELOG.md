# Changelog

## 1.2.0

### New feature
- New setting to choose the color of the sublist count (for example 2/5). By default it keeps the theme accent color.

### Fixed
- In thin panels the widget now shows an icon that opens the full list in a popup, instead of a cut-off title bar. The full list is still embedded on the desktop and in panels large enough to fit it.
- A tasks file with unexpected values (for example a number as a title, or an empty sublist entry) no longer causes tasks to be skipped and then removed on the next save.
- "Delete selected" can no longer remove tasks other than the ones selected after tasks were added, imported or filtered.
- An open sublist now refreshes correctly after a sync.
- Today, Tomorrow and overdue labels now update at midnight.
- Markdown import reads the same file the export writes.
- The iCalendar export now ends with a proper line ending.
- The settings page scrolls, uses standard desktop controls, and lets the storage path, Markdown path and title be cleared.
- Removed the binding loop warnings the widget logged on every start.

### Faster
- Large lists open and filter much faster: filtering 300 tasks went from about 1.3 s to 70 ms.
- Each task row is about 5 times cheaper to build, since its menus and dialogs are created only when used.
- Saving is about 6 times faster, and the tasks file is no longer rewritten when nothing changed, so sync tools don't re-download it.

## 1.1.0

### New feature
- The widget background can now be switched on or off from desktop edit mode, using the standard Plasma background toggle. The default look is unchanged. (#7)

### Fixed
- Text fields now accept typing when the widget is placed in a panel on Wayland. Before, keystrokes in the add-task, filter and rename fields went to the previously focused window. Desktop behaviour is unchanged. (#4)

## 1.0.1

### Fixed
- Sample tasks can no longer overwrite saved tasks, even if the tasks file is missing, empty or unreadable at startup.
- Large task lists (roughly 300 tasks or 90 KB and up) keep saving. Before, saving silently stopped at that size.
- A tasks file changed by another tool or widget is no longer overwritten without checking first.
- A backup (`tasks.json.bak`) and timestamped snapshots are kept before risky writes.
- Deletions sync only for tasks that were actually deleted.
- Save and read problems now show an error banner with a Retry button instead of failing silently.
- Applying settings no longer writes an old task list back.

## 1.0.0

Initial release: nested sublists, priorities, categories, due dates, drag-and-drop reorder, Markdown export (Obsidian Tasks compatible), iCalendar export, and UUID-based sync across machines.
