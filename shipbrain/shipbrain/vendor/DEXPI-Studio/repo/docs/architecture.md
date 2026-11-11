# Architecture

## High-level structure

DEXPI Studio enforces a strict split between **core logic** and **GUI widgets**.

```
src/dexpi_studio/
├── app.py
├── core/                  # no PySide6 imports
│   ├── capabilities.py
│   ├── pydexpi_adapter.py
│   ├── model_tree.py
│   ├── selection.py
│   ├── assistant_chat.py
│   └── chat_history.py
└── gui/
    ├── main_window.py
    ├── actions.py
    ├── selection_model.py
    ├── diagram/
    │   ├── scene.py
    │   ├── view.py
    │   └── items.py
    └── widgets/
        ├── model_tree.py
        ├── properties_panel.py
        ├── messages_panel.py
        ├── assistant_panel.py
        ├── assistant_settings_dialog.py
        ├── export_dialog.py
        ├── ribbon.py
        └── welcome_dialog.py
```

## Architecture rules

1. `core/` must stay UI-agnostic (no PySide6)
2. pyDEXPI remains the source of truth for parsing/rendering/export
3. GUI composes adapters, widgets, and selection state
4. Local-first behavior (no cloud/telemetry)
5. Read-only model handling for MVP

## Key runtime flows

### File open flow

1. User opens a file in `MainWindow`
2. `core.pydexpi_adapter.load_dexpi_file` loads model via pyDEXPI
3. Adapter builds tree/index/render payloads
4. GUI updates diagram, model tree, properties, and logs

### Selection flow

1. Selection originates from tree, diagram, or search dropdown
2. `gui.selection_model.SelectionModel` broadcasts selected ID
3. `MainWindow` synchronizes:
   - diagram highlight
   - tree selection
   - properties panel
   - assistant selected context

### Search flow

1. Query entered in always-visible search input
2. `pydexpi.query.QueryEngine` resolves matches
3. Compact dropdown renders two-line result rows
4. Selection/highlight updates on click, keyboard, or enter

### Chat flow

1. `assistant_panel` requests context from `MainWindow`
2. `core.assistant_chat` constructs provider-agnostic messages
3. `core.chat_history` stores local chat sessions and markdown exports

## Why this scales

- Core logic remains testable without GUI dependencies
- GUI can evolve without changing pyDEXPI integration contracts
- Feature additions (search/chat/render polish) stay layered and maintainable
