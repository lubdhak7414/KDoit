# KDoit

A to-do list widget for KDE Plasma 6 with nested sub-tasks, priorities, and due dates.

Set priorities with color coding, assign due dates that highlight when overdue, and nest sub-lists to break down complex work. Reorder by drag-and-drop, filter with search, and hide completed tasks. Tasks persist to a JSON file and sync live across machines via Syncthing or any file-sync tool.

## Installation

```bash
git clone https://github.com/lubdhak7414/KDoit.git
rsync -av --exclude='.git' KDoit/ ~/.local/share/plasma/plasmoids/com.github.lubdhak7414.kdoit/
plasmashell --replace
```

Then add the widget via the panel's "Add Widgets" menu. Requires Plasma 6, Qt 6, and Kirigami 6 (Wayland and X11).

## Features

- **Priorities** — low / medium / high with theme-aware color-coded left stripe
- **Due dates** — with overdue and today highlighting
- **Categories** — filterable via header ComboBox, monochrome `#tag` display
- **Nested sub-lists** — drill in and back, with a done/total badge
- **Drag-and-drop reordering** — full-row drag, disabled while filtering or in a sub-list
- **Multi-select** — Ctrl+click toggle, Shift+click range-select, bulk delete
- **Search** — toggleable filter by title
- **Hide completed** — configurable toggle
- **Undo on delete** — 5-second window
- **Live sync** — polls the task file every 3 seconds; merges changes by UUID (newer `modifiedAt` wins), propagates remote deletions, and refreshes open sublist views in place
- **Internationalization** — `i18n()` throughout (translators welcome)

## Configuration

Right-click the widget → Configure:

- **Tasks file path** — where the JSON file is stored (default `~/.local/share/kdoit/tasks.json`); point multiple machines at the same Syncthing folder to sync tasks across them
- **Default Priority** — priority assigned to new tasks
- **Hide Completed** — collapse finished tasks from view
- **Enable live sync** — polls the task file every 3 seconds for external changes; off by default, enable only when sharing the file across machines

## Notes

- Live sync is **disabled by default**. Enable it in Configure only if you share the task file across machines (e.g. via Syncthing). Leaving it on when not needed polls disk every 3 seconds unnecessarily.
- File write uses standard GNU coreutils (`base64`, `stat`, `mv`, `printf`). These are present on any standard Linux system but may be absent in locked-down container or Flatpak environments.
- The tasks file path must not contain single-quote (`'`) characters — the path is passed to the shell unescaped in that position.

## Known Limitations

- Sub-lists are flat (one level of nesting)
- No tombstones — a task deleted on one machine can be re-added if the remote file still contains it with a newer `modifiedAt`

## Contributing

Pure QML, no build step. See [CONTRIBUTING.md](CONTRIBUTING.md) for conventions, the dev/reload workflow, project layout, and data format.

## License

Licensed under the GNU General Public License v3.0 — see [LICENSE](LICENSE).
