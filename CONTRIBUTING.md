# Contributing to KDoit

## Conventions

- Pure QML + Kirigami/Plasma components — no frameworks or build tooling.
- Theme colors via `Kirigami.Theme.*`, spacing via `Kirigami.Units.*` — never hardcode.
- Wrap user-facing strings in `i18n()`.
- Keep changes focused — no unrelated refactors.

## Workflow

No build step. Edit in place, install, and reload:

```bash
rsync -av --exclude='.git' KDoit/ ~/.local/share/plasma/plasmoids/com.github.lubdhak7414.kdoit/
plasmashell --replace
```

Test in isolation without touching your session:

```bash
plasmawindowed --statusnotifier com.github.lubdhak7414.kdoit
```

Source lives in `contents/ui/` (`main.qml`, `TaskModel.qml`, `TaskDelegate.qml`, …); config schema in `contents/config/main.xml`. Tasks persist as JSON in `plasmoid.configuration.tasksJson`.
