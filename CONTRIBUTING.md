# Contributing to KDoit

Pure QML — no build step, no dependencies beyond a Plasma 6 install.

## Setup

```bash
git clone https://github.com/lubdhak7414/KDoit.git
kpackagetool6 -t Plasma/Applet -i KDoit/
```

## Dev workflow

Edit files in `KDoit/contents/ui/`, then upgrade and reload:

```bash
kpackagetool6 -t Plasma/Applet -u KDoit/
plasmashell --replace &
```

To test without replacing your session:

```bash
plasmawindowed com.github.lubdhak7414.kdoit
```

## Project layout

```
contents/ui/main.qml          Root PlasmoidItem — nav stack, undo, selection, filtering
contents/ui/TaskModel.qml     ListModel + persistence — CRUD, UUID merge, export
contents/ui/TaskDelegate.qml  Drag, multi-select, priority stripe, context menus
contents/ui/AddTaskBar.qml    Text input + add button
contents/ui/EmptyState.qml    Context-aware placeholder
contents/ui/ConfigGeneral.qml Settings form
contents/config/main.xml      Config schema
```

Task schema: `uuid, title, done, priority, category, createdAt, modifiedAt, dueDate, sublist[]`

## Conventions

- Colors: `Kirigami.Theme.*` — never hardcode
- Spacing: `Kirigami.Units.*` — never hardcode pixel values
- User strings: `i18n()` throughout
- No frameworks, no build tooling, no abstractions beyond what the task needs
- Touch only the files a change requires — no unrelated refactors

## Data format

Tasks persist via dual-write: `~/.local/share/kdoit/tasks.json` (for external tools and sync) and `plasmoid.configuration.tasksJson` (for fast startup). File writes are atomic: base64-encode → write to `.tmp` → `mv -f` to final path.
