# ShipBrain — local LLM assistant for ship structure CAD / FE mesh / FEA

Type a command in a chat window, like in Claude:

> *Mesh a deck panel 4800 x 3200 mm, plate 12 mm, FB 150x12 at 800, one T 400x10/150x15 web frame, 5 m water head, clamped edges*

The model reads the request, calls a tool, and the tool builds the mesh. You get a Nastran `.bdf` and a
CalculiX/Abaqus `.inp`, a 3D preview and a short summary. **No GPU and no internet are needed on the workstation.**

```
 you ──► GUI (browser page, local) ──► small fine-tuned LLM (CPU, GGUF/llamafile)
                    ▲                         │  ```tool {"name": "panel_mesh", "args": {...}}```
                    │                         ▼
                    └──── answer ◄──── tools (deterministic code): own mesher, CadQuery, Roark checks,
                                       CalculiX, mesh checks, RAG search, your private ship tools (plugin)
```

**How it is built.** The model never writes mesh files or works out numbers in its head. It writes a short JSON spec and
code does the rest: builds the mesh, checks it and writes the files (the same rule as "XML by code" in the ship-rules repo).
A small model can learn to write that JSON reliably, and the results stay correct.

## What it can do now

Every tool answers with numbers that come from code, plus a `plain_english` summary. The assistant is told to write in
simple English, and to call `file_info` first when you ask about an uploaded file.

**Meshing (own mesher, no gmsh)**

| Tool | What it does | Verified |
|---|---|---|
| `panel_mesh` | stiffened panel (plate + FlatBar/T/L/HP stiffeners + frames), shell or beam stiffeners | CalculiX vs Roark 0.2 % |
| `build_structure` | **short building-block programs** (lesson of CAD2Program): `deck L=6000 B=4000 t=12; girder y=1000 h=600 t=12; web x=3000 h=800 t=10; opening ...; stiffeners spacing=500 profile=FB150x12; load p=0.05; fix x=0` -> plates + 1D stiffeners (cut at openings, none on girders) -> mesh / STEP. About 7x fewer characters for the model to write than coordinates, so it is faster on a CPU and makes fewer mistakes; clear error messages for wrong input |
| `plates_mesh` | **global structure mesh, 1D + 2D**: any assembly of flat plates (deck, girders, webs, brackets, floors, bulkheads, openings) as all-quad shells, plus 1D stiffeners (CBAR with offsets) that share the plate nodes. Joints share nodes by construction; the geometry is cleaned first | 0 free / duplicate nodes, 1 part; Roark −0.1 % / 0.0 %; 1D+2D vs structured mesher within 3 % |
| `cad_mesh` | STEP/BREP → cleaned → thin solids to mid-surface plates → mesh | STEP grillage → one connected mesh |
| `fatigue_mesh` | **fatigue hot-spot model**: cuts a box around the hot spot, meshes it t × t, finds the 0.5t / 1.5t read-out points; with `solve` it runs CalculiX and returns s_hs = 1.5 s(0.5t) − 0.5 s(1.5t) per surface | test |
| `geometry_clean` | **unclean geometry**: repeated or in-line points, corners that almost meet, warped plates (moves only the odd corner), slivers, duplicates, tiny holes; STEP repair, sewing, merging faces split in one plane | dirty model: 2 loose parts → 1 clean part |
| `mesh_check` | any `.bdf`/`.inp` (also from gmsh/ANSA/Patran): free nodes, duplicates, loose parts, free edges, angles, warp | |

**FE model: formats, conversion, editing (1D / 2D / 3D)**

| Tool | What it does |
|---|---|
| `fe_convert` | Nastran `.bdf` (read with **pyNastran**) ↔ Abaqus/CalculiX `.inp` ↔ ANSYS APDL `.mac`. Writes driver scripts for **PyMAPDL** (`ansys-mapdl-core`) and **Abaqus/CAE** (Python). Bars, shells, solids, properties, materials, supports and loads are kept: the same CalculiX answer through every format (test) |
| `repair_model` | **geometry repair for FEA from your words**: upload a STEP and say e.g. *"remove holes below 20, fillets below R10, chamfers under 3 and pins under 12 mm"* — holes (with their edge chamfers), fillets, chamfer strips, bosses/pins and small faces are removed (OpenCascade defeaturing), then sewn and fixed; every removal is re-counted on the result, and anything that would break the solid is kept and reported. FE meshes (bdf/inp): merge nodes, remove degenerate/duplicate elements, fix inside-out solids, consistent shell normals, delete loose bits. `mesh_size` meshes the clean part straight away | test bracket: 23 faces → 7, all 11 small features removed, valid solid |
| `surface_extract` | **mid-surface / outer-surface extraction** from solid CAD (STEP): every thin solid (flat, bent or curved plate, pipe wall) gives its mid (or outer) surface and thickness, grouped by thickness (`Mid_Surface_10T` …); faces saved as B-splines (SpaceClaim exports) are recognised as plane / cylinder / torus first; `mesh_size` meshes the flat mid-surfaces | real pump skid (3,389 solids, 31,000 B-spline faces): 1,290 thin solids → 1,749 mid faces in 45 thickness groups, 3 min on a CPU |
| `pipe_extract` | **piping**: straight pipes and elbows (OD, wall, bend radius / angle, length), joined into runs; wall from the model (hollow) or the pipe schedule (SCH10/40/80/160); bolts, pins and U-bolts left out; 1D FE model with pipe sections, tees and valve gaps joined | same skid: 260 pipes + 47 standard elbows, 56 m of pipe, 26 s |
| `surrogate_build` / `surrogate_predict` | **AI surrogate (reduced-order model)** of a parametric FE problem: a study of real CalculiX runs (own mesher), POD of the result fields + RBF in log space, **adaptive**: new runs where it is least accurate; accuracy by leave-one-out; each prediction (full field as ParaView .vtk + peaks, ~1 ms) has an error estimate, and when unsure or outside the range the real solver runs and the run is added. Exports a dependency-free **C++ header** for a C++ CAD/FE program | clamped plates L 1-3 m, B 0.5-1 m, t 8-20 mm, p 0.01-0.1 MPa, 70 runs: peak displacement within 2 %, peak stress within ~5 % (limited by FE mesh noise of the peak itself); C++ header gives the same numbers as Python |
| `result_insight` | post-processing of any CalculiX result: peak and where, utilisation vs yield with PASS/FAIL, hotspot areas, elements to refine (stress jump inside an element) with a suggested size, change against a baseline run, a report draft, .vtk | |
| `fe_edit` | equivalence, delete (group / box / ids / type), remove free nodes, translate, **mirror** (half → full breadth), **refine** (supports carried over; converges to Roark), split quads, renumber, merge models, set thickness |
| element-type conversion (`fe_edit` ops) | 2D → 3D `shell_to_solid` (hexa/penta through the thickness), 3D → 2D `solid_skin`, 2D → 1D `edges_to_beams`, 1D → 2D `beams_to_shells` |

PyMAPDL and Abaqus need their own licensed software on your PC. ShipBrain writes the input files and the scripts; it does not run ANSYS or Abaqus itself.

**Drawings**

| Tool | What it does |
|---|---|
| `drawing_to_3d` | DXF structural plan → 3D: outline/opening layers → plate with holes; girder/web/frame layers → vertical plates; stiffener layers → 1D beams. Writes a STEP and a 1D + 2D mesh. Scanned drawings need the vision model or redrawn DXF lines |
| `compare_drawings` | two drawings (PDF page, PNG/JPG, DXF), aligned automatically: red = removed, green = added, % same, list of changed areas |
| `compare_mesh_drawing` | FE mesh vs drawing (plan view at a height): % of mesh lines on drawn lines, coverage, and the shift that would line them up (calibration error) with an overlay image |
| `compare_drawings` (vector) | for PDFs with real lines/text and for DXF it also says **what** changed: lines added/removed, line style changed (solid ↔ dashed, thin ↔ heavy, layer), texts changed/added/removed, each number classified (plate thickness, weld size, section size, frame, dimension, off-centre-line, elevation), e.g. *"text changed '12' → '14' (plate thickness)"*, *"girder line solid → dashed"* |
| `drawing_check` | checks the arithmetic written on a drawing: products and sums such as `24 x 101.6 = 2438.4`, `6 @ 800 = 4800`, `1200 + 800 = 2000`; lists the ones that do not add up. Reads DXF and PDF text; scans only if Tesseract OCR is installed (optional, Apache-2.0) |
| `cad_view_check` | **machine-part** drawings only (front / top / side views): checks a 3D part against a drawing view: projects the model (front / top / side), compares the lines both ways and the proportions, and gives PASS / WARN / FAIL with hints (missing hole, extra feature, wrong size) and an overlay image |
| `file_info` | plain-English description of any uploaded file (FE model, STEP, DXF, PDF, image, JSON, XML, text) |

**Structure models (member level)**

| Tool | What it does |
|---|---|
| `drawing_to_model` | reads a **ship** structural drawing (PDF deck plans, elevations, sections) with the ship drawing reader (its own frame / OFF C.L / deck-height calibration, line-style and label rules) into a member model XML; lists the reader's open questions; optional score against a reference XML. On a real deckhouse drawing: 4.4 min, 55 blocks |
| `compare_structures` (default: coverage) | compares two structure models **independent of how members are split** (a drawing-read model and a yard model never split them the same way): share of stiffener length and plate area found in the other model, with the same section / thickness, both ways, and where the biggest gaps are. Real deckhouse, drawing-read vs yard model: plates 78-82 % (72 % same thickness), stiffeners 63-75 % (55 % same section) |
| `compare_structures` (method "members") | two versions of ONE structure model, member by member: plates (thickness, grade), stiffeners (section, grade), brackets, openings → same / changed / moved / added / removed, with positions. Reads structure JSON, or your ship XML through your private plugin (its `xml_to_members` is picked up automatically) |
| `structure_to_mesh` | structure model → cleaned → global 1D + 2D mesh (plates with thickness and openings as shells, stiffeners as beams with their sections), plus a STEP |

**Knowledge and memory (ideas from Voitta's knowledge engine, own implementation)**

| Feature | What it does |
|---|---|
| hybrid search | keyword (BM25) + meaning-based search fused by reciprocal rank fusion. Meaning-based search uses any local open-source embedding model served by llama.cpp (`--embed-server`, e.g. nomic-embed-text, Apache-2.0), on CPU |
| fast restarts | index and embeddings are cached; only files whose content changed are read again |
| search scope | `knowledge_search(..., scope="project-a")` searches one project or folder only |
| memory | `remember` / `recall` / `memory_feedback`: facts and yard practice you teach are used in later answers. Liked memories rank higher; clearly disliked ones are dropped |
| 👍 / 👎 on answers | a 👎 with your correction is remembered at once. All rated chats go to `feedback.jsonl`, and `make_dataset.py --feedback` turns the liked ones into training data for the next fine-tune |
| MCP server | `claude mcp add shipbrain -- python -m shipbrain.mcp_server --knowledge D:\ship_src`: Claude Code or other agents use the same tools |

**Engines and solvers (small brain, real solvers)**

ShipBrain builds the CAD and the mesh itself. The analysis runs in a solver that is already on the workstation:

| Tool | What it does |
|---|---|
| `choose_engine` | question -> analysis type (static, natural frequencies, buckling, ultimate, contact, impact, fatigue, fracture, CFD, heat, CAD, mesh) -> the best engine and the next tool; guide-only answers use the engine's knowledge pack (e.g. MoFEM tutorials) |
| `find_solvers` / `remember_solver` | finds CalculiX, MSC / NX Nastran, MYSTRAN, ANSYS, Abaqus, OpenFOAM, Code_Aster on the PATH and in their usual install folders, plus a user list |
| `solve` | the chosen solver runs the ShipBrain model in batch (static / modal / buckling): input written, solver run, results read back in plain English. CalculiX is tested here (static, natural frequencies 0.3 %, buckling 0.6 % vs handbook); the Nastran (.f06), ANSYS (APDL result export) and Abaqus (odb extract script) adapters follow their documented batch interfaces and must be checked once on the workstation (`python -m shipbrain.solvers --check`) |
| `analysis_run` | static / modal / buckling directly with CalculiX |

**Other tools:** `cadquery_build` (checked CAD), `solve_calculix`, `plate_check`, `stiffener_check`, `plate_buckling`, `section_props`,
`calc`, `knowledge_search` with automatic RAG, and your plugins (e.g. your private `ship_mcp.py`).

With no model connected, the app still works: `/panel_mesh {"length": 4800, "width": 3200}` runs a tool directly, and plain
questions search the knowledge folder.

## Quick start (workstation, CPU only)

```bash
pip install numpy scipy cadquery pyNastran ezdxf pymupdf pillow   # see requirements.txt for what each one is for
python -m shipbrain --model shipbrain-q4_k_m.gguf --allow-code \
       --knowledge D:\ship_src  --plugin D:\cad-llm-repo
```
The page opens at http://127.0.0.1:7860. If the model is already running elsewhere (Ollama, LM Studio, llama-server), use
`--server http://127.0.0.1:11434 --model-name shipbrain` in place of `--model`.

**Two files only:** `python packaging/build_exe.py` builds `shipbrain.exe` (app, GUI and tools; about 70 MB without
CadQuery, a few hundred MB with it).
`packaging/make_llamafile.md` explains how to pack the model into `shipbrain.llamafile`.
Then run `shipbrain.exe --model shipbrain.llamafile`.

## One universal model, every user different

The model weights are the same for everybody and hold only general engineering skill (public data). What differs per
user lives on that user's PC and is read at run time, so nobody needs their own retraining:

| Per user | Where | How |
|---|---|---|
| units, material and yield, design code, field of work, answer language | `profile.json` in the work folder | say it once ("I work in inches and psi, A36, AISC") -> `set_profile`; given to the model with every question |
| other units in a question | `convert_units` | inch / ft / psi / ksi / kip / kN.m / cm4 / msw ... converted into the tools' mm-N-MPa and the answer back |
| facts and corrections | memory | `remember`, thumbs up / down |
| books, rules, standards, company documents | knowledge folder + `.sbpack` packs | searched and cited |
| own scripts and tools | plugins folder | loaded as extra tools |
| installed solvers | `find_solvers` / `remember_solver` | whatever is on that workstation |
| CPU / GPU | `--gpu auto` | uses the card when it works, else the CPU |
| company data for training | private Kaggle dataset | gives that company its own private model; the public model never sees it |

## Other people's code, used whole and in its own language

Nothing is rewritten when it can be used as it is, so no core function can go missing:

- **Complete copies** of open-source repos (permissive licences) live in `shipbrain/vendor/<name>/repo`, unchanged, with
  their licence and the commit they came from: `awatif` (TypeScript + C++), `diff3d` (Python). Add more with
  `python -m shipbrain.polyglot add https://github.com/owner/repo` (MIT / BSD / Apache / ISC / CC0 only).
- **Any function, in its own language** (`code_functions` to find it, `code_call` to run it): Python is imported directly,
  TypeScript / JavaScript run in Node.js through tsx (`python -m shipbrain.polyglot setup awatif` installs their npm
  packages once), C / C++ / Rust run as their compiled WebAssembly (Awatif's C++ solver in `frame_solve`). Checked:
  Awatif's TypeScript solver, its C++ solver and the hand formula give the same cantilever deflection.
- **Knowledge packs hold every file** (`repopack build --full`): all code and docs of every repo, no size budget,
  20 packs, ~460,000 searchable pieces. Languages read: Python, C, C++, C#, Rust, TypeScript, JavaScript, Fortran, Julia,
  MATLAB, CUDA, Java, Kotlin, Go, Lua, Tcl, R, shell, GLSL, SQL, CMake, Qt UI. The search index is cached
  (`~/.cache/shipbrain`): first start ~40 s, then ~3 s; a search takes 0.01-0.2 s.
- Licences decide how a repo is used: permissive = copied whole, searched and trained on; GPL / AGPL / LGPL = searched
  only (with their licence), never trained on or copied into the code; brand material (SolidCraft's UI kit, look,
  theme, logo under its brand licence) left out.

## P&ID drawings -> process knowledge graph (pid-to-kg, used as written)

`pid_kg` runs the scripts of [PID-to-Knowledge-Graph](https://github.com/ScottDuncanAI/PID-to-Knowledge-Graph) (MIT),
copied whole into `shipbrain/vendor/` (its own 78 tests pass on the copy); its `SKILL.md` is loaded as a ShipBrain
skill as written. Steps: `probe` (vector / outlined / scanned pages), `render` (tiles), `hints` (text / OCR tags) ->
the sheets are read into `extract/page_NN.json` (needs a vision model: Claude, or ShipBrain started with a vision
model via `--mmproj`) -> `build` (graph.json, DuckDB, summary.md, qa_report.md) -> `query` (upstream, downstream,
path, loops, loop, instruments, describe, sql) and `export` (GraphML, Neo4j). Public P&ID sets to try it on are listed
in the copied [public-chemical-manufacturing-datasets](https://github.com/ScottDuncanAI/public-chemical-manufacturing-datasets)
(CC-BY-4.0); those drawings may be downloaded and read, not republished.

**The model learns from those public P&IDs:** on Kaggle, `training/public_pids.py` downloads the five sets (Haile, Pahala,
Virden (scanned), Salina, Ruttan), prepares the first P&ID pages of each with the real tools (probe, render, OCR / text
tags) and turns the real outputs into training samples. The drawings are used only for training there: they are never
stored in the repo or in a pack. `pid_kg` action `tags` lists the tags found on each sheet (read with pid-to-kg's
own ISA parser; to be confirmed when the sheet is read).

## Frames, beams and pipe supports: Awatif's solver inside

`frame_solve` checks 3D frames, beams, columns, portals and pipe supports with the linear solver of
[Awatif](https://github.com/madil4/awatif) (MIT): its own compiled C++/Eigen code (`shipbrain/vendor/awatif/lSolver.wasm`,
unchanged, with its source and licence) runs from Python through `wasmtime`; nothing else to install. The input follows
Awatif's rules: line loads go L/2 to each end of every element of the line mesh, load cases G / Q / W, its combinations
ULS-1 (1.35G + 1.5Q + 0.9W) and ULS-2 (1.35G + 1.05Q + 1.5W), plus SLS. Sections: pipe, rect, I, box or A / Iy / Iz / J;
moment releases; self weight. Output: governing combination and member, stress (axial + bending) and utilisation,
deflections, reactions, a Markdown report. A pipe model from `pipe_extract` is solved directly (supports and loads at
coordinates). Checked: cantilever tip deflection and root moment exact; simply supported UDL moment exact, deflection
within 1 % (Awatif's lumped line loads; finer mesh = closer). Without wasmtime, ShipBrain's own numpy frame solver
(exact fixed-end loads) is used and the answer says so. Buckling, shear and local checks are not included.

## Skills and hooks: teach it workflows without retraining

**Skills** are small Markdown files with the steps of a workflow. For every question the best matching skill is given to
the model, which then follows the steps. Built in (`shipbrain/skill_library/`): `fea-prep` (clean up CAD for FEA),
`piping-model`, `surrogate-study`, `result-review`, `other-units`. Your own go in `<workdir>/skills/`, or teach one in
the chat: *"Whenever I say 'monthly tank check', do: 1) plate_check ... 2) ... 3) ..."* -> `add_skill` saves it, and it
is used from then on (`list_skills` shows them all). A skill file:

```
---
name: monthly-tank-check
description: monthly tank wall check
when: monthly tank            # regex of trigger words (optional; else word match with the description)
---
1. plate_check for each tank wall plate with 0.15 MPa
2. stiffener_check for the vertical stiffeners
3. list any utilisation above 0.9
```

**Hooks** are functions in a plugin file (next to its `TOOLS`), called at fixed moments; the text they return is given
to the model as a note: `HOOKS = {'question': fn(question), 'tool_result': fn(name, args, result), 'compact': fn(notes)}`.
Example: a company rule checker that adds "site rule: yield 355 MPa" to every question about yield.

## Long chats on a small model

The model's window is small (8k tokens by default, `--ctx`). When a chat no longer fits, the oldest turns are replaced by
notes made **by code**, so nothing important is paraphrased away (idea from
[compact-state](https://github.com/BrijeshParmar/compact-state-skill), MIT): **State now**, **Decisions** (the user's
words, verbatim, dated), **IDs and paths** (every file name and id), **Next**. They are also saved as
`.state/<chat id>.md` in the work folder; to correct them, edit the file and add ` (edited)` to its first line.

## Small NVIDIA GPU (e.g. an older 4 GB card)

`python -m shipbrain --model shipbrain-q4_k_m.gguf` now checks for an NVIDIA GPU (`nvidia-smi`) and, when the model fits,
puts all of it on the GPU (`--gpu auto`, the default; `--gpu off` = CPU, `--gpu 20` = only 20 layers on the GPU).
Which llama.cpp build (llama.cpp releases page, Windows zip):

| Card (if unsure, use Vulkan) | Build |
|---|---|
| don't know / very old (e.g. Quadro K-series, GTX 600-700) | **`vulkan`**: works on almost any GPU with a current driver; start with `--gpu on` |
| Quadro M / P / T, GTX 900 / 1000 / 1600, RTX (2014 and newer) | `cuda` (fastest) or `vulkan` |

**Safety net:** if the model does not load on the GPU, or the first test answer fails, ShipBrain restarts it on the CPU by
itself and keeps going. So trying the GPU can never leave the app broken.

| Card memory | Fits on the GPU | Expected |
|---|---|---|
| 4 GB | 1.7B q4 (1.1 GB) + 0.6B draft + 8k context, about 3 GB in total | answers several times faster than on the CPU |
| 4 GB | 4B q4 (2.5 GB) does not fit with its context: use `--gpu 24` (part on the GPU) or stay with 1.7B | |

Training stays on Kaggle (free 16 GB T4): 4 GB is too little to fine-tune even the 1.7B model comfortably. The CAE tools
(mesher, surrogate, CalculiX) run on the CPU and do not need the GPU.

## Fast on a CPU

How ShipBrain keeps answers quick without a GPU:

| Measure | Effect |
|---|---|
| small model, quantised: **Qwen3-1.7B q4_k_m (~1.1 GB)** is the default; 4B (~2.5 GB) is an option for better answers | 1.7B writes about 2x faster than 4B |
| knowledge lives in the search index and tools, not in the weights | the model stays small; new repos and documents need no retraining |
| **compact system prompt**: tool names and argument names only (~870 tokens instead of ~2,800). The training data uses the same prompt | the first answer starts about 3x sooner |
| **prompt cache** (`cache_prompt`, `--cache-reuse`): the fixed system prompt is read once and reused | later questions skip that part |
| **shorter tool results** (lists cut, numbers rounded) in both the app and the training data | less to read after each tool call |
| **speculative decoding**: `--draft shipbrain-draft-q8_0.gguf` (a Qwen3-0.6B fine-tuned on the same data; the Kaggle run makes it) | typically 1.5-2x faster writing, same answers |
| extra llama.cpp settings: `--llama-args "-fa on --mlock"`, `--threads <physical cores>` | depends on the CPU |

Measure your PC: `python -m shipbrain.bench --server http://127.0.0.1:8081`. It reports prompt-reading and writing speed
in tokens per second, checks that the prompt cache works, and gives tips.

## Weight-space tools (`training/weightspace.py`)

**Grow the model skill by skill, without growing its size (adapter merging / task arithmetic).** Train one small LoRA
add-on per skill or per new repo: a short, cheap run on the free GPU or overnight on the CPU. Then fold all add-ons into
**one** model with `merge --method ties` (or `dare`, `linear`). The merged model has the same size and CPU speed as the
base, so a new repo needs only a new add-on, not a full retrain.

**Repair without training ("weight-space programming", after the MIT CSAIL 2026 idea; own implementation).**
`edit --good good.jsonl --bad bad.jsonl --eval data/eval.jsonl`:
1. Find the direction in the model's hidden states that separates bad behaviour (rambling, repeating, breaking the tool
   format) from good behaviour (clean tool calls).
2. Project that direction out of the output matrices of a few layers.
3. Keep the edit **only if the ShipBrain test score goes up**. Shorter answers decide a tie, because shorter is faster on
   a CPU.

The patch is saved separately and can be undone. As in the original work, this removes obstacles; it **cannot add a
skill** the model never learned, and it does not make the model smaller. Size and speed come from the base model,
quantisation and the measures in "Fast on a CPU".

Status: both tools are tested on a tiny local model (the merge arithmetic is exact, the edit loop runs end to end).
Real gains have to be measured on the trained ShipBrain model.

## Known limits (measured on a real engine-room structure model: 703 plates, 565 stiffeners)

| | first version | now | target |
|---|---|---|---|
| mesh time (4 CPU cores, 400 mm elements) | 135 s | **51 s** | |
| unconnected pieces | 165 | **10** | 1 |
| largest connected piece | 92 % | **98.7 %** | >= 99 % |
| loose brackets | 139 | **0** (262 bracket edges tied to their stiffeners) | 0 |
| near-duplicate nodes | 824 | **0** | 0 |
| inverted / degenerate elements | 518 | **14** | 0 |
| elements with a corner < 5 deg | 2,352 | **335** | 0 |
| max aspect ratio / max warp | 1014 / 79 deg | **134 / 6.7 deg** | |

- The 9 remaining loose plate pieces sit 105-773 mm from any other plate. That looks like structure missing from the
  source model, so they are reported, not forced shut.
- The remaining slivers are thin triangles between real lines 20-60 mm apart, wider than the 5 % snap tolerance. A
  larger snap made more zig-zag lines and more inverted elements, so it was not used.
- New mesher options: `snap_tol` (default 0.05 x element size), `min_seg` (h/10), `bracket_ties` (on), `repair` (on).
  The report lists every line clean-up, bracket tie and repair.
- The synthetic test models are fully clean: 1 part, no free or duplicate nodes, no bad elements.

## Making the model ("modify the LLM weights")

### Three free ways to train (pick one)

| Way | Account needed | GPU | How |
|---|---|---|---|
| **Kaggle** (recommended: the assistant can start and watch runs for you) | free Kaggle account + **phone verification** (needed for GPU and internet in notebooks) | free T4/P100, ~30 h per week, up to 12 h per run | `pip install kaggle`, set `KAGGLE_USERNAME` / `KAGGLE_KEY`, then `python training/kaggle_run.py start`, `watch`, `fetch` |
| **Google Colab** | free Google account | free T4 (when available) | open `training/ShipBrain_train_colab.ipynb`, run the cells |
| **Your own PC, no account** | none | none (CPU) | `python training/finetune_cpu.py --base Qwen/Qwen3-0.6B --max-samples 1000`. It is slow (hours to a day for small models) and saves checkpoints, so it can resume |

All three use only open-source software: Qwen3 models (Apache-2.0), Unsloth (Apache-2.0) or Transformers + PEFT
(Apache-2.0), and llama.cpp (MIT) for the CPU model file. The model file is saved to your private Hugging Face repo, or
downloaded from the Kaggle or Colab output.

**Colab: open `training/ShipBrain_train_colab.ipynb` in Google Colab** (File → Upload notebook, Runtime → T4 GPU) and
run the cells. It clones the code, makes the data, scores the base model, fine-tunes, scores again, writes the GGUF, and
uploads it to a **private** Hugging Face repo using a token stored in Colab's *Secrets* panel as `HF_TOKEN`.

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

The training data includes the retrieved context exactly as the app adds it at run time, so the model learns to use RAG.
Task families: panel mesh, plate-assembly mesh, recovery from a tool error, stated assumptions, CadQuery parts with checked
sizes, Roark / stiffener / buckling / section checks, rule retrieval (with your index).

**Publishing the model.** GGUF files are 1-5 GB. That is too big for git (GitHub's file limit is 100 MB). Upload them as a
GitHub Release asset (up to 2 GB per file) or to a Hugging Face model repo. Do not train on company data if you intend to
publish the model: a model fine-tuned with your rule index can repeat it.

### Making the brain stronger: what goes where

| You have… | Put it… | Why |
|---|---|---|
| rule books, yard standards, method notes, class rules you are licensed to use, past reports | `--knowledge` folder | facts change; search finds them on every question; no retraining |
| a repeatable task (a new member type, a new check, a new file format) | a **tool** (Python function) + a few lines in `make_dataset.py` | code does it exactly; the model only learns when to call it |
| your way of working, answer style, how to read a request | more / better **training samples** → fine-tune again | this is what weights are good at |
| CAD parts you trust | `examples/cadquery/your_part.py` with `# Prompt:` / `# Tags:` lines, then `python -m shipbrain.examples verify` | verified examples are retrieved when the model writes CAD code |
| drawings → model pairs (your `ship_pairs.py` tiles) | fine-tune the vision model (Qwen3-VL) as in the ship-rules repo | reading images needs a vision model |

**Your own models as private training data:** `python training/private_samples.py run --workdir <folder> --files a.stp b.stp` runs the pipe and surface tools on your real files once; `python training/private_samples.py make --runs runs.jsonl` turns the results into chat samples. Upload the `.jsonl` as a PRIVATE Kaggle dataset; never commit it.
**Your own code:** `python -m shipbrain.repopack build --repo <your code folder> --out packs --own` makes a `.private.sbpack` (git ignores it) that is searched at run time and may train your private model.

## Tests

```bash
python -m pytest tests -q        # 46 tests: memory, hybrid search, MCP, structure compare + mesh, semantic drawing diff, meshers, conformity, 1D+2D, cleaning, fatigue, formats + same solver answer through
                                 # each, edit ops, 1D/2D/3D conversions, DXF->3D, drawing and mesh-vs-drawing comparison,
                                 # CadQuery, RAG, plugins, agent loop + GUI server vs a mock model
```

## Next steps (not done yet)

- **Train and measure.** Training has not run yet; there was no GPU in the build session. Run steps 1-4 above and compare `eval_before.json` with `eval_after.json`.
- **HyperX.** Import the generated `.bdf` into HyperX through its Python API (docs in `../docs`) for panel sizing.
- **CFD.** A tool that writes an OpenFOAM case (blockMesh/snappyHexMesh dictionaries) from a STEP hull or part. Today the assistant only explains the set-up.
- **Fatigue sub-modelling.** Drive the cut boundary of the hot-spot box with the global model's displacements, not clamps. Add free-edge hot spots (cut-out corners) and S-N damage.
- **Global ship model from a general arrangement.** Decks, bulkheads and double bottom from main dimensions, then mesh.
- **Curved shell.** Mesh curved faces (hull shell) in the surface's own (u,v) parameters, with the same shared-edge rule.
- **Stiffener slots in the assembly mesher.** Slots where stiffeners pass through web frames; today the web is continuous at the crossing.
- **Ship primitives.** CAD2Program-style primitives (`plate`, `stiffener`, `bracket`, `bulkhead` + a few parameters) instead of free CadQuery code. Small models are more reliable with these.
- **Arrangement → structure.** Feed bulkhead and deck positions from a general-arrangement generator (e.g. ShipSpace-GA) into `plates_mesh`, with tank heads as pressure loads.
- **Vision.** Read a deck-plan tile and send the member JSON straight to `panel_mesh`, by joining with `ship_rag.py panel`.

## Private data

Do **not** commit ship drawings, XMLs, rule texts, `rules_index.json`, generated training data, or model weights.
**This repository is public.** `.gitignore` already excludes these files. Keep them on the company drive and point the app at them with
`--knowledge` / `--plugin`.

## Licences: free and open source only

Everything ShipBrain needs is free and open source: numpy and scipy (BSD), CadQuery (Apache-2.0) with OpenCascade (LGPL),
pyNastran (BSD), ezdxf (MIT), pdfplumber (MIT), pypdfium2 (Apache/BSD), Pillow (MIT-CMU), CalculiX (GPL, run as a
separate program), llama.cpp (MIT) and llamafile (Apache-2.0). Training uses Qwen3 (Apache-2.0), Unsloth (Apache-2.0),
Transformers and PEFT (Apache-2.0). PyMuPDF (AGPL or paid) was replaced. ANSYS and Abaqus are only targets of the file
converters and are never needed.

## Credits (ideas, no code copied)

- [agent3dify](https://github.com/neka-nat/agent3dify) (MIT): a fixed script contract with one JSON result line; a stall guard for repair loops; checking the model's projected views against the drawing.
- [text-to-cad](https://github.com/earthtojake/text-to-cad) (MIT): check the user's sizes against the built solid, not against the model's words; an example corpus with prompts.
- [solidcraft](https://github.com/tangency-labs/solidcraft) (MIT/Apache-2.0): a verified example and oracle set; small tool replies.
- [CAD2Program](https://manycore-research.github.io/CAD2Program/): small models do better emitting short parametric primitives than free B-rep code; used for `build_structure`.
- [OpenCourantRP](https://github.com/CAMLAB-UChile/OpenCourantRP) (AGPL-3.0): knowledge-only pack (manual, explicit-dynamics example decks for impact / crash / sloshing); never trained on, no code copied.
- [Voitta](https://github.com/voitta-ai/voitta-rag) (voitta-rag is AGPL-3.0, so nothing was copied): hybrid search, re-indexing only changed files, search scope, assistant memory with like/dislike, tools over MCP.
- [CAD-pdf-chatbot](https://github.com/adityawalture/CAD-pdf-chatbot) (no licence, so nothing copied): checking written dimension arithmetic, OCR fallback for scans.
- [CADCraft](https://github.com/storytold/cadcraft) (MIT/Apache-2.0): DXF as the drawing exchange format.
- [ShipSpace-GA](https://github.com/kodendaal/ShipSpace-GA) (MIT, data CC BY 4.0): an arrangement generator, planned as a source of bulkhead and deck positions.
