# DEXPI Studio

DEXPI Studio is a local-first desktop application for exploring DEXPI P&ID models with pyDEXPI.

## What you can do

- Open DEXPI XML/JSON files
- Render and inspect diagrams
- Browse the model tree and properties panel
- Use always-visible search with compact result dropdown
- Validate model structure and inspect logs
- Export via pyDEXPI exporters
- Use ChatP&ID with local chat persistence

## Local-first by design

- No cloud upload
- No telemetry
- No external file processing
- Data remains on your machine

## Design intent

DEXPI Studio remains a **GUI wrapper** around pyDEXPI:

- No custom parser
- No duplicated exporter logic
- No replacement for pyDEXPI CLI
- No duplicated renderer internals

## Next steps

- Continue with [Getting Started](getting_started.md)
- Read architecture details in [Architecture](architecture.md)
- Review boundaries in [Limitations](limitations.md)
