# ShipBrain — local LLM assistant for ship structure CAD / FE mesh / FEA

Type a command in a chat window, like in Claude:

> *Mesh a deck panel 4800 x 3200 mm, plate 12 mm, FB 150x12 at 800, one T 400x10/150x15 web frame, 5 m water head, clamped edges*

The model reads the request, calls a tool, and the tool builds the mesh. You get a Nastran `.bdf` and a
CalculiX/Abaqus `.inp`, a 3D preview and a short summary. **No GPU and no internet are needed on the workstation.**

```
 you ──► GUI (browser page, local) ──► small fine-tuned LLM (CPU, GGUF/llamafile)
                    ▲                         │  ```tool {"name": "panel_mesh", "args": {...}}```
                    │                         ▼
                    └──── answer ◄──── tools (deterministic code): mesher, Roark checks, CalculiX,
                                       gmsh, knowledge search, your private ship tools (plugin)
```

**How it is built.** The model never writes mesh files or works out numbers in its head. It writes a short JSON spec and
code does the rest: builds the mesh, checks it and writes the files (the same rule as "XML by code" in the ship-rules repo).
A small model can learn to write that JSON reliably, and the results stay correct.

## What it can do now

| Tool | What it does | Verified |
|---|---|---|
| `panel_mesh` | stiffened panel: plate + stiffeners (FlatBar / T / L / HP) + frames, shell or beam stiffeners, pressure, edge supports → `.bdf` + `.inp` | CalculiX deflection matches Roark within 0.2 % (simply supported and clamped) |
| `cad_mesh` | any STEP / IGES / BREP / STL → shell (quad) or solid (tet) mesh via gmsh | test with a STEP box |
| `solve_calculix` | runs CalculiX on the CPU, returns max displacement / von Mises | yes, when `ccx` is installed |
| `plate_check`, `stiffener_check`, `plate_buckling`, `section_props` | hand checks (Roark tables, beam theory, Johnson-Ostenfeld) | unit tests |
| `knowledge_search` | BM25 search over your folder of rules, notes and PDFs; answers cite rule ids | your 458-rule index loads |
| `calc` | exact arithmetic (sandboxed) | tested |
| `cadquery_build` | runs a CadQuery script → STEP/STL (only with `--allow-code`) | needs cadquery |
| *your plugins* | any `TOOLS = {...}` file, e.g. your private `ship_mcp.py` (rules_search, check_members, alike_score, xml_from_members…) | plugin loader tested |

With no model connected, the app still works: `/panel_mesh {"length": 4800, "width": 3200}` runs a tool directly, and plain
questions search the knowledge folder.

## Quick start (workstation, CPU only)

```bash
pip install numpy gmsh pymupdf          # gmsh / pymupdf are optional
python -m shipbrain --model shipbrain-q4_k_m.gguf \
       --knowledge D:\ship_src  --plugin D:\cad-llm-repo
```
The page opens at http://127.0.0.1:7860. If the model is already running elsewhere (Ollama, LM Studio, llama-server), use
`--server http://127.0.0.1:11434 --model-name shipbrain` in place of `--model`.

**Two files only:** `python packaging/build_exe.py` builds `shipbrain.exe` (app, GUI and tools, about 70 MB).
`packaging/make_llamafile.md` explains how to pack the model into `shipbrain.llamafile`.
Then run `shipbrain.exe --model shipbrain.llamafile`.

## Making the model ("modify the LLM weights")

The model is fine-tuned with QLoRA, which changes a small set of extra weights and then merges them into the model. This is
the same kind of fine-tuning that is done to GPT-style models. It needs a GPU **once**. A free Colab T4 is enough. After that
the model runs on any CPU.

```bash
# 1. data: every tool result and number is computed by the real tools (never written by hand)
python training/make_dataset.py --n 4000 --out data/train.jsonl --eval-out data/eval.jsonl \
       --knowledge ship_src/rules_index.json          # optional: adds rule-retrieval tasks (keep this data private)
# your existing ship data from cad_vlm_all_in_one.py can be added too: --data data/train.jsonl ship_data/*.jsonl

# 2. score the base model first (served by llama-server / Ollama)
python training/evaluate.py --server http://127.0.0.1:8080 --data data/eval.jsonl --out eval_before.json

# 3. fine-tune on the GPU and export a CPU model
pip install unsloth
python training/finetune.py --data data/train.jsonl --base unsloth/Qwen3-4B-Instruct-2507 --out shipbrain_model

# 4. score again
python training/evaluate.py --server http://127.0.0.1:8080 --data data/eval.jsonl --out eval_after.json
```

Base model: `Qwen3-1.7B` (fast, weaker), `Qwen3-4B-Instruct-2507` (default), `Qwen3-8B` (best, slower). See
`packaging/make_llamafile.md` for CPU speeds.

### Making the brain stronger: what goes where

| You have… | Put it… | Why |
|---|---|---|
| rule books, yard standards, method notes, class rules you are licensed to use, past reports | `--knowledge` folder | facts change; search finds them on every question; no retraining |
| a repeatable task (a new member type, a new check, a new file format) | a **tool** (Python function) + a few lines in `make_dataset.py` | code does it exactly; the model only learns when to call it |
| your way of working, answer style, how to read a request | more / better **training samples** → fine-tune again | this is what weights are good at |
| drawings → model pairs (your `ship_pairs.py` tiles) | fine-tune the vision model (Qwen3-VL) as in the ship-rules repo | reading images needs a vision model |

## Tests

```bash
python -m pytest tests -q        # 18 tests: mesher, BDF format, CalculiX vs Roark, gmsh, knowledge, plugins,
                                 # agent loop and GUI server end to end against a mock streaming model
```

## Next steps (not done yet)

- **Train and measure.** Training has not run yet; there was no GPU in the build session. Run steps 1-4 above and compare `eval_before.json` with `eval_after.json`.
- **HyperX.** Import the generated `.bdf` into HyperX through its Python API (docs in `../docs`) for panel sizing.
- **CFD.** A tool that writes an OpenFOAM case (blockMesh/snappyHexMesh dictionaries) from a STEP hull or part. Today the assistant only explains the set-up.
- **More meshers.** Openings with cut-outs, brackets, girders deeper than frames, corrugated bulkheads, double-bottom blocks built from your ship XML.
- **Vision.** Read a deck-plan tile and send the member JSON straight to `panel_mesh`, by joining with `ship_rag.py panel`.

## Private data

Do **not** commit ship drawings, XMLs, rule texts, `rules_index.json`, generated training data, or model weights.
**This repository is public.** `.gitignore` already excludes these files. Keep them on the company drive and point the app at them with
`--knowledge` / `--plugin`.
