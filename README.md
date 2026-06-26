# KDoit

A to-do list widget for KDE Plasma 6 with nested sub-tasks, priorities, and due dates.

<p align="center">
  <img src="assets/preview.png" width="60%">
</p>

Set priorities with color coding, assign due dates that highlight when overdue, and nest sub-lists to break down complex work. Reorder by drag-and-drop, filter with search, and hide completed tasks. Everything persists to your Plasma configuration automatically.

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
- **Internationalization** — `i18n()` throughout (translators welcome)

## Configuration

Right-click the widget → Configure:

- **Default Priority** — priority assigned to new tasks
- **Hide Completed** — collapse finished tasks from view

## Known Limitations

- Sub-lists are flat (one level of nesting)
- Categories/tags are not yet implemented
- No synchronization across multiple Plasma instances

## Contributing

Pure QML, no build step. See [CONTRIBUTING.md](CONTRIBUTING.md) for conventions, the dev/reload workflow, project layout, and data format.

## License

Licensed under the GNU General Public License v3.0 — see [LICENSE](LICENSE).
