# Changelog

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
