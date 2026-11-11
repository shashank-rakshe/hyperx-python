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

## One model that also sees: fixed base Qwen3-VL-4B-Instruct

The base model is **fixed** in `training/base_model.json`: `Qwen3-VL-4B-Instruct` (Apache-2.0). One model does text,
tool use, code and pictures; every Kaggle run trains it fresh on all the data, so nothing is lost and nothing changes
between runs except what it has learned. The draft model `Qwen3-0.6B` (same tokenizer) keeps it quick on a CPU.

- Files: `shipbrain-q4_k_m.gguf` (~2.5 GB) + `shipbrain-mmproj-f16.gguf` (the image part, ~0.8 GB). Keep them in one
  folder: `python -m shipbrain --model shipbrain-q4_k_m.gguf` finds the image part by itself.
- `look(file, page, question)`: the model looks at a picture or a PDF page (drawings, scans, sketches, screenshots).
- `pid_kg read`: the model reads each rendered P&ID sheet into pid-to-kg's format; every sheet is checked with
  pid-to-kg's own data model (one retry with the error), then `build` runs its QA.
- Training pictures: `training/synth_pid.py` draws P&ID sheets (ISA-style symbols) with exact answer keys, made at
  training time (400 per run); the questions are the same ones `pid_kg read` / `look` ask.
- Honest limit: a 4B model reads drawings far less reliably than a large model; its sheets are drafts for the QA loop.
  Ship drawings -> XML stay with the rule-based reader (`drawing_to_model`), which the model can now cross-check with `look`.

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
- Licences decide how a repo is used: permissive = copied whole, searched and trained on; GPL / AGPL / LGPL / MPL and
  non-commercial = searched and trained on too, because the owner declared ShipBrain open and non-commercial
  (`shipbrain/licence_mode.json`; GPL code is only run as a separate program, never mixed into ShipBrain's code);
  brand material (SolidCraft's UI kit, look, theme, logo under its brand licence) left out.

## STL meshes -> exact STEP solids (next.BREP.io's stl2step, used unchanged)

The BREP kernel family of [next.BREP.io](https://github.com/mmiscool/next.BREP.io_RUST_BREP_KERNEL) (Rust, 373,000
lines: NURBS, booleans, fillets, sheet metal, STEP) is copied whole into `shipbrain/vendor/BREP`. Its licence is MIT
wording **with extra conditions on modifications** (they must go to its author), so ShipBrain uses it **unchanged**
and never patches it (`DO_NOT_MODIFY.md`); the licence checker now marks such licences `conditional`.

- `stl_to_step` (and every CAD tool: `repair_model`, `surface_extract`, `pipe_extract`, `cad_mesh` now accept `.stl`):
  scans, 3D-print files and mesh exports become exact solids - planes, cylinders, cones, spheres and tori recognised.
  Checked: a filleted plate with holes comes back with its 6 planes + 6 cylinders and the identical volume in 0.2 s;
  then `repair_model` removes the holes and fillets from the STL as from a STEP.
- Build once: Rust from rustup.rs, then `python -c "from shipbrain import brep; brep.build()"` (~5 min; Windows,
  Linux, macOS). The Kaggle run does it by itself and adds STL inputs to the CAD training tasks.
- Found on the way: `repair_model` failed on trimmed cylinders in real STEP files - fixed.

## OCX (3Docx) ship models: the whole OCX library inside

[OCX](https://3docx.org) is the open XML standard for 3D ship structure models (class approval, yard to class, design to
production). ShipBrain carries two repos, copied whole and used as written:

- **OCX_Schema** ([OCXStandard/OCX_Schema](https://github.com/OCXStandard/OCX_Schema), Apache-2.0): the official schema
  of **every version 2.8.6 to 3.2.0 (12 versions)** as XSD and as **Python classes** - every element, type, attribute,
  child, allowed value and its documentation (554 classes in 3.2.0). The model is trained on it.
- **OCXReader** ([skfcz/OCXReader](https://github.com/skfcz/OCXReader), LGPL-2.1, C++ / OpenCascade): OCX -> exact STEP.
  LGPL, so it is copied **unchanged**, built and run **as its own program**; its code is also a trained knowledge pack (`COPYLEFT.md`).
  Its sample ship models (company / ship names) were left out.

Tools:

| tool | what it does |
|---|---|
| `ocx_syntax` | exact syntax of any OCX element / type / enumeration in any version: required attributes, children in order with how many, allowed values, where it is used, which versions have it, an XML example; search by meaning ("bulb", "watertight"); `changes_from` = what changed between two versions |
| `ocx_read` | any OCX file (2.8.x - 3.2): panels, plates and thickness, stiffeners and sections, brackets, pillars, seams, holes, frame tables, catalogues, plate area and weight; saved as a structure JSON |
| `ocx_validate` | against the official XSD of its version (exact place of each problem) + every element name against the library |
| `ocx_write` | structure JSON / OCX / ship XML -> **OCX 3.2.0** built with the official classes, checked against the official XSD |
| `ocx_to_step` | 3D CAD: OCXReader when built (`python -c "from shipbrain import ocx; ocx.reader_build()"`, needs CMake + vcpkg), else ShipBrain's own plate solids + stiffener beams |
| `ocx_query` | members of a model by name, kind, panel function (DECK, BULKHEAD ...) or plate thickness, with thickness, material, section, size, weight |
| `compare_structures`, `structure_to_mesh`, `file_info` | now take `.3docx` directly |

**Training on real OCX models** (`training/ocx_samples.py`, run by the Kaggle notebook): 14 public OCX exports (real CAD
models, schema 2.8.5 / 2.8.6 / 3.0.0, 20 kB to 64 MB, up to 1.16 million elements) are fetched at training time, never
stored in the repo. Names are removed first: file name, header (author, company, CAD system), vessel name, yard /
designer / owner, class number and class society; any sample still holding one of them is dropped. They give about 210
samples from the real tool results: what is in a model, panels / plates / stiffeners by name, function, thickness or
section, validation against the official XSD, upgrade to OCX 3.2.0, revision compare. Your own OCX files can be added
with `--src <folder> --rules <your private name list>`.

Checked: structure -> OCX 3.2.0 passes the official XSD and reads back member for member identical; four real OCX
exports from two different CAD systems (2.8.5 / 2.8.6, up to 590,000 elements) read in 0.1-3.3 s with thickness,
sections and frames right (two exporters write units and references differently - both handled); the XSD check finds
the real schema deviations in those exports. Curved shell panels are flattened onto their best plane for comparing
and meshing.

**OCXReader uses the same OpenCascade ShipBrain already has** (CadQuery's OCP is OpenCascade). `ocx.reader_build()`
builds it, unchanged, against the system OpenCascade 7.6 C++ files: on Linux `sudo apt install` the packages listed in
`ocx.APT`, then about 1 minute - no vcpkg. Windows / macOS use its vcpkg set-up (`VCPKG_ROOT`). Checked here: the
2.8.5 / 2.8.6 real models become STEP in 0.4-21 s (up to 430,000 STEP entities). OCXReader reads OCX 2.8.x only; for
3.x files `ocx_to_step` uses ShipBrain's own solids and says why.

## Outside data on Kaggle (the build session has no internet to those sites)

All outside data is downloaded on Kaggle, which has internet:

1. **Data notebook** (once, no GPU): Kaggle -> New Notebook -> Internet ON -> paste `training/kaggle/data_kernel.py`
   -> Save & Run All (30-90 min). It downloads PID2Graph, CubiCasa5K (2,000 plans), PIDQA, FloorPlanCAD (if its links
   work) and the free class rule books of IACS + 12 societies, builds the private class-rule packs, and leaves it all
   in its output `shipbrain_data/` with `manifest.json` (what came, what did not). Keep it **private** (default).
2. **Training notebook** (`training/kaggle/kernel.py`): Add Input -> Your Work -> Notebooks -> the data notebook. The run
   finds `shipbrain_data/` itself and uses it; anything missing in it is downloaded during the run instead.
3. Rule books that need a login: save them on your PC as `<society>/*.pdf`, upload as a private Kaggle dataset with
   "rules" in its name, attach it to the training notebook too.
4. Optional: `training/kaggle/detector_kernel.py` in a GPU notebook trains the drawing symbol detector.

## Native CAD files without the CAD program: cadmpeg (Apache-2.0)

[cadmpeg](https://github.com/cadmpeg/cadmpeg) opens native CAD files directly, written clean-room (no vendor SDKs).
ShipBrain runs its own program, pinned to commit `6c775550` (version 0.6.11):

| Format | how far cadmpeg reads it |
|---|---|
| STEP, IGES | full (IGES also written back) |
| FreeCAD `.FCStd`, Fusion 360 `.f3d` | complete shape with colours |
| SolidWorks `.sldprt`, CATIA V5 `.CATPart`, Inventor `.ipt`/`.iam`, ACIS `.sat`, Creo View `.pvz` | full solid |
| Rhino `.3dm` | exact, by ShipBrain's own reader (below); cadmpeg as backup |
| Siemens NX `.prt` parts | solid geometry (tested on an NX 1980 part: same size, volume within 0.06 % of NIST's STEP) |
| NX assemblies | component placements only: the parts' geometry is in separate .prt files, upload them too |
| OpenUSD | geometry, not yet full solids |
| Creo `.prt` | opened and listed only, no geometry yet |

- Tool `native_cad(file, op)`: `convert` (to STEP, or IGES), `inspect`, `check`, `measure` (volume, area, centroid, mass with
  a density), `diff` (geometry of two files, e.g. a native file against its STEP export). Answers say what STEP could not
  carry (feature history, appearance details) and when a format gives no geometry yet.
- Every CAD tool (file_info, cad_mesh, surface_extract, compare ...) now accepts these files directly: they are converted
  to STEP on the way in.
- Encrypted or licence-locked files are refused on purpose (its LEGAL.md); ShipBrain never tries to get around that.
- Install (once): the one-line installer from its [README](https://github.com/cadmpeg/cadmpeg#install), or with Rust
  `python -c "from shipbrain import cadmpeg; cadmpeg.build()"` (about 30 minutes on 2 cores; uses less memory than the
  default build). The chat gives the install card when it is missing.
- Not copied into this repo: its source is about 80 MB (plus 80 MB of test files); ShipBrain uses its released program
  instead. Its docs and code are the knowledge pack `packs/cadmpeg.sbpack` (7,202 chunks); 240 training conversations
  come from real runs on its public CC0 / NIST sample files (`training/cadmpeg_tasks.py`).

## Mooring lines and dynamic cables: CableDyn (Apache-2.0)

[CableDyn](https://github.com/SMI-Lab-Inha/CableDyn) (J. H. Seo et al., Ocean Engineering 368, 128332, 2026) is copied
as written in `vendor/cabledyn`: a geometrically exact finite-element solver for mooring lines and dynamic power cables -
statics from the geometry alone, implicit dynamics with waves / current / vessel motion, bending stiffness, bend
stiffeners, torsion, seabed contact and friction, modes, VIV, fibre ropes; it reads MoorDyn v2 decks and couples with
OpenFAST. Its own validation: within 0.06-0.6 % of OrcaFlex 11.6d on lazy-wave curvature and tension, and model tests.

- Tool `mooring(depth, length, radius, d_mm, grade, kind, fairlead_z, current, condition)`: one chain line from plain
  numbers -> fairlead / anchor tension and angle, touchdown point, grounded length, breaking load and the API RP 2SK
  check (CableDyn's own factors of safety). Chain properties: studless mass 19.9 d² t/m, EA 0.854·10⁸ d² kN (d in m),
  hydrodynamic diameter 1.8 d (exactly what CableDyn's own example decks use); MBL = c d² (44 - 0.08 d) kN with
  c = 0.0223 R3 ... 0.0320 R5 (DNV-OS-E302). A line shorter than the fairlead-anchor distance is refused with the reason.
- Tool `cable_run(deck)`: any CableDyn / MoorDyn v2 deck -> tensions and their maxima over time.
- Install: `pip install "cabledyn[post]"` (the wheel carries the solver) or the Windows `CableDyn_driver.exe`; or
  `python -c "from shipbrain import cabledyn; cabledyn.build()"` compiles ShipBrain's copy (gfortran + LAPACK + CMake).
- Skill `mooring`, knowledge pack `packs/CableDyn.sbpack`, 160 training conversations from real runs
  (`training/cabledyn_tasks.py`), tests incl. a hand catenary check.

## Siemens NX automation: NX Open journals (nxopentse) and renaming with links

For users who have NX / Simcenter 3D (reading NX files needs no NX - see above):
- [nxopentse](https://github.com/theScriptingEngineer/nxopentse) (AGPL-3.0, copied as written in `vendor/nxopentse`; the
  packaged successor of [NXOpen-CAE-python](https://github.com/theScriptingEngineer/NXOpen-CAE-python), which has no licence
  file and is therefore not copied) gives 149 NX Open Python functions: CAD (bodies, faces, features, datums, points,
  splines, assemblies, layers, colours, mass properties) and Simcenter CAE (mesh collectors, nodes, forces / moments /
  pressure on groups, constraints, solutions, subcases, solver sets, solving, results: load, export, combine, envelope,
  nodal / elemental values, screenshots).
- Tool `nx_open`: `find` / `syntax` read the functions from nxopentse's own code (never invented); `journal` writes an
  NX Open journal that opens the part and calls them in order (results passed on with `"$name"`, repeated with
  `for_each`, NX constants as `{"nx": "NXOpen..."}`), checked as valid Python, and runs it with NX's `run_journal` when
  NX is installed - otherwise the answer says how to run it in NX (File > Execute > NX Open..., Alt+F8).
- Tool `nx_rename`: [NX File Renamer](https://github.com/nahidmubin/Siemens_NX_File_Renamer) (GPL-3.0, copied as written
  without its .exe) renames a .prt and updates the assemblies / drawings in the same folder with NX's `ug_edit_part_names`
  (Windows with NX; needs pywin32).
- Skill `nx-open`, packs `nxopentse` and `Siemens_NX_File_Renamer`, 100 training conversations (`training/nx_tasks.py`).

## Rhino and NX import

- **Rhino `.3dm`**: `shipbrain/rhino.py` reads it with McNeel's own open library `rhino3dm` (MIT, `pip install rhino3dm`)
  and builds exact OpenCascade geometry: every face is its exact NURBS surface (weights kept: circles stay circles)
  bounded by its edges, faces sewn, closed polysurfaces become solids. Extrusions, surfaces, meshes, curves and block
  instances (with their placement, nested too) are read; units are converted to mm; layer, name and block are kept per
  object. Tested on McNeel's rhino3dm test models and on primitives: box, sphere, cylinder exact, extrusion 0.001 %.
  SubD objects are reported (convert them with ToNURBS in Rhino). Points are listed but kept out of the solid model.
- **Siemens NX `.prt`** parts: read by cadmpeg (above). An NX assembly holds only component placements: the answer says
  so and asks for the part files.
- Both work everywhere: `file_info`, `native_cad(op="convert")`, `cad_mesh`, `surface_extract`, `compare_structures` ...
- Volumes are measured with OpenCascade's precise rule (`rhino.volume`); its default rule is up to ~1 % off on
  rational NURBS (cylinders, spheres), which looks like a conversion error but is not.

## STL -> STEP with features: ReverseCAD (non-commercial licence)

[ReverseCAD](https://github.com/grizlizora/reverse-cad) (PolyForm Noncommercial 1.0.0; used because ShipBrain is declared
non-commercial) is copied whole into `shipbrain/vendor/reverse-cad` and run as written with Node.js. ShipBrain builds it
by itself on first use (`npm install` + TypeScript, about 10 s).

- Tool `reverse_cad(file, material)`: STL -> watertight STEP AP242 solid, volume / area / centre of mass / inertia, mass
  for steel, aluminium, PLA, PETG, ABS or glass, recognised holes, ISO threads, fillets, chamfers, slots, cavities, and its
  own 5-gate check of the STEP against the mesh (Hausdorff distance). The answer says the features are recognised from
  the mesh and must be checked (on test parts it sometimes calls a plain hole a tapped one).
- Its MCP server is built in as `reverse-cad` (cad_analyze_stl, cad_detect_threads, cad_verify_rsvs, cad_convert_to_step).
- Skill `reverse-cad`; knowledge pack `packs/reverse-cad.sbpack` (1,716 chunks); 80 training conversations made from real
  conversions of CadQuery parts (`training/reversecad_tasks.py` -> `training/data/reversecad_train.jsonl.gz`).
- `stl_to_step` (next.BREP.io) stays for exact curved faces; use both when needed.
- **Licence:** non-commercial only, and not by or for a for-profit company. Before any commercial or company use remove
  `vendor/reverse-cad`, its pack and its training data and train again, or buy the author's commercial licence.

## Pre-processing like HyperMesh (element quality, model check, OptiStruct .fem)

HyperMesh (Altair) is a paid pre-processor; its manual is Altair's copyright, so nothing from it is copied. ShipBrain
does the same jobs with its own free code, and writes files HyperMesh opens directly:

| HyperMesh step | ShipBrain |
|---|---|
| geometry cleanup / defeature | `repair_model` (holes, fillets, chamfers, small faces, sewing) |
| midsurface | `surface_extract(kind="mid")` |
| automesh (shells, solids) | own mesher: `plates_mesh`, `panel_mesh`, `structure_to_mesh`, `cad_mesh`, `fatigue_mesh` |
| check elements / quality index | **`fe_quality`** (new): aspect, warpage, skew, taper, Jacobian, quad/tria corner angles, shortest edge, % triangles, pass/warn/fail limits you can change; failing elements saved as named sets (`*ELSET` or `SET`) that any pre-processor shows |
| model checker | **`fe_quality`**: elements without property, property without material, zero thickness, duplicate elements, loads/constraints on missing nodes, no constraints |
| equivalence, free edges, normals | `mesh_check`, `fe_edit` (equivalence, orient_normals, remove_degenerate, repair ...) |
| export solver deck | `fe_convert(to=["fem"])` = OptiStruct (new), `bdf` Nastran, `inp` Abaqus/CalculiX, `mac` ANSYS |
| solve | free: MYSTRAN (`.bdf`), CalculiX (`.inp`) |

The skill `fe-preprocess` tells the model this order of work. Default quality limits are typical ship FE practice;
give your class or company limits as `criteria`, e.g. `{"aspect": [3, 5], "warpage": [10, 15]}`. If you have a HyperMesh
licence and its help pages or PDFs, put them in your private knowledge folder (not in this public repo) and ShipBrain
will search them too.

## Process simulation (DWSIM) and DEXPI P&IDs (pyDEXPI)

**DWSIM** ([DanWBR/dwsim10](https://github.com/DanWBR/dwsim10), GPL-3.0): the open-source chemical process simulator.
ShipBrain builds its own MCP server once (`python -c "from shipbrain import dwsim; dwsim.build()"`, needs the free
.NET 10 SDK - the chat shows the link) and runs it unchanged as a separate program.
- `process_sim`: `run` a DWSIM flowsheet (every stream: T, P, flow, phases, composition; every unit operation),
  `flash` a mixture (feed in **mass** fractions, DWSIM's convention) with any of its 30 property packages
  (Peng-Robinson, SRK, NRTL, UNIFAC, steam tables, GERG-2008, PC-SAFT ...), list `packages`.
- All 58 of its own operations (build flowsheets, unit operations, columns, reactors, dynamics, PID tuning ...) via
  `mcp_call(server="dwsim")`. `choose_engine` now routes process questions (flash, distillation, flowsheet ...) to it.
- Checked: built here; all **22 of its sample plants** (gas processing, columns, reactors, LNG, biodiesel ...) load and
  solve with no errors in 0.1-9.5 s; a 50/50 by mass water-methanol flash gives 64 % water by moles (exact).
- Training: `training/data/dwsim_train.jsonl.gz` - 347 samples from the real simulator (22 plants, 65 stream questions,
  260 flashes of 12 mixture families), kept in the repo so Kaggle need not build DWSIM.

**pyDEXPI** ([process-intelligence-research/pyDEXPI](https://github.com/process-intelligence-research/pyDEXPI)) and
**DEXPI Studio** (its desktop app), both AGPL-3.0, copied whole; pyDEXPI runs as its own program (`pip install
"pydexpi[png,pdf]"`, Python 3.12+). DEXPI is the open P&ID exchange standard.
- `dexpi`: `summary` (equipment with tags and classes, instruments, piping), `validate` (all of pyDEXPI's DEXPI rules),
  `tables` (equipment / line / instrument / piping-component / valve lists, xlsx or csv), `drawing` (PNG + SVG), `diff`
  of two revisions; its MCP server (43 operations: find by tag, connections, paths, exports ...) via `mcp_call(server="dexpi")`.
- Training: its real example P&IDs (DEXPI reference P&ID, 36 DEXPI training test cases, a CO2 terminal, Tennessee
  Eastman) -> summaries, validations, and the drawn P&IDs with their exact tag lists (`training/data/dexpi_*`).
- Code packs of DWSIM, pyDEXPI and DEXPI Studio are trained on too (copyleft allowed: ShipBrain is open, non-commercial).

## Document reading: LiteParse + ParseBench (run-llama, Apache-2.0)

- **LiteParse** (`pip install liteparse`; Rust core with PDFium, runs on the PC): now ShipBrain's PDF reader for the
  knowledge base and the class-rule books - lines, reading order and table grids kept (pypdfium2 stays as fallback).
  Tool `parse_document`: PDF / Word / Excel / PowerPoint / picture -> markdown with headings and tables, saved as
  `<name>.md`; it says which pages are scanned or mostly pictures, and `ocr: true` reads those (Tesseract; its language
  data is fetched once from the internet). A 14-page PDF reads in 0.1 s. Word / Excel / PowerPoint need LibreOffice.
- **ParseBench** (~2,000 human-verified pages of real insurance, finance and government documents; tables, charts,
  formatting, layout): the GitHub data job downloads it with its own command and turns each page into "page picture ->
  its verified markdown" training samples - only if the dataset's Hugging Face licence allows training (checked first
  and written to the release notes; no-derivatives licences are refused). Hugging Face is blocked in the build session.
- The rest of run-llama (LlamaIndex) is mostly demos of paid cloud services; their code packs were not added.
  LiteParse and ParseBench code are trained knowledge packs.

## Bolted joints and vibration

- `bolt` tool (`shipbrain/bolts.py`): metric ISO coarse threads, ISO 898-1 / ISO 3506 property classes, VDI 2230
  Part 1 formulas - stress area (matches the ISO table exactly), assembly preload at 90 % yield utilisation,
  tightening torque, preload scatter of the tightening method, and with an axial working load: bolt stress, fatigue
  (alternating stress vs endurance limit) and the clamping force left. **Inch bolts** too (US practice): UNC / UNF
  sizes #2 - 2 in, SAE J429 grades 2 / 5 / 8 and ASTM A325 / A490, ASME B1.1 stress area (same values as the
  Vibrationdata MATLAB bolt tool's table), preload c x A_t x S_p and nut-factor torque T = K D F (Shigley).
  Training samples in make_dataset (`t_bolt`). The Vibrationdata MATLAB package copy on GitHub
  (nkatsinas/vibrationdata_matlab) has no licence file, so its code is not copied; the formulas are standard.
  The Vibrationdata blog post on bolt calculations (Nov 2026) could not be read from the build session (its site is
  blocked) and its code is not on GitHub yet: send the code or the download and it is added as written.
- **Vibrationdata for Python** (Tom Irvine, MIT; [nkatsinas/vibrationdata_python](https://github.com/nkatsinas/vibrationdata_python))
  copied whole: 116 modules - shock response spectrum, PSD and spectral moments, rainflow, SDOF / modal response,
  plates and honeycomb panels, sine sweeps ... Its calculation functions run through `code_functions` / `code_call`
  as written (e.g. a flat PSD 0.04 G2/Hz, 20-2,000 Hz -> 8.9 GRMS, exact); a desktop toolkit it imports for its
  windows is given an empty stand-in where none is installed. Trained knowledge pack.

## MATLAB code without MATLAB: GNU Octave

MATLAB is paid; **GNU Octave** (free, GPL, https://octave.org) runs the same language. ShipBrain's code runner now
treats `.m` files like Python / TypeScript: `code_functions` lists their functions, `code_call` runs one as written in
Octave (arguments in, every output back), `run_script` runs a whole `.m` script. Octave is a separate program
(Windows installer, `sudo apt install octave`, `brew install octave`); the chat shows the link when it is missing.
Checked: Octave 8.4 - a two-output function and a vector function give the same numbers as the Python versions.
Windows made with MATLAB's GUIDE (.fig) do not run in Octave, but their calculation code does.

**Packages the user downloads** (not copied into ShipBrain, e.g. no licence for sharing): when a calculation needs
one that is not on the PC, the chat says where to get it - today Tom Irvine's Vibrationdata MATLAB package
(https://github.com/nkatsinas/vibrationdata_matlab: Code -> Download ZIP, plus GNU Octave). Tell ShipBrain the
folder once ("use the folder D:/vibrationdata_matlab-main as vibrationdata_matlab", tool `code_folder`, remembered in
`~/.shipbrain/repos.json`) and its functions run through `code_functions` / `code_call` like the copied repos.
More such packages go in `polyglot.DOWNLOADABLE` (name, link, why) - one line each.

## LLM serving simulation (Simthesizer)

[Simthesizer](https://github.com/casys-kaist/simthesizer) (MIT, Rust, HPCA 2027) is copied whole and run as written:
it simulates an LLM server under many users without a GPU. Tool `serving_sim`: users, requests per second, prompt
and answer length -> time to first word, tokens/s per user, answer time, total throughput. It ships one measured
set-up (Llama 3.1 8B on one RTX Pro 6000); other models / GPUs need its own GPU profiling (vLLM). Checked: builds in
17 s; 20 requests at 0.5/s -> first word 0.03 s, 88 tokens/s per user; 200 at 20/s -> the GPU saturates, first word
after 9 s (90 %: 17 s). ShipBrain's one-PC planner stays `shipbrain.speed` (CPU / small GPU). Its code is a trained pack.

**ShipBrain's own model on a GPU:** the Kaggle training run ends by measuring ShipBrain's model (the Qwen3-4B text
part of the base model, dummy weights - nothing large is downloaded) on its GPU with Simthesizer's own profiler
(Python 3.14 + vLLM 0.31 via `uv`; `training/serving/qwen3_4b.toml`, 29 batch shapes; checked here with its dry run).
The result lands in the run's output `shipbrain_serving/`; `serving.add_profile("shipbrain_serving")` installs it and
`serving_sim` then answers for ShipBrain itself on that card. Also as its own notebook:
`training/kaggle/serving_profile_kernel.py`. Simthesizer models dense models with head size = hidden / heads, so
Qwen3-4B is given as 20 heads x 128 (KV cache per token exact); the vision encoder is not included. Not run yet:
needs the Kaggle GPU; whether vLLM 0.31 accepts the T4 shows in that run's log.

## Class society rules (ships and offshore)

ShipBrain answers class rule questions **from the rules themselves**, with society, document, section and page, in
plain sentences - never from memory.

- **Calculators** (`class_rule` tool, action `longitudinal` / `k`): IACS UR S11 / S7 / S4 hull girder strength - wave
  coefficient, wave bending moments (hogging / sagging), minimum section modulus and moment of inertia, permissible
  bending and shear stress, required section modulus with a still-water moment, PASS / FAIL for your Z and I,
  material factor k. Checked by hand (L 200 m: C = 9.75, Z_min 19.1 m3). Wave shear forces are left to the rule text
  (their distribution factors were not reliable enough from memory to code).
- **Rule books** (`python -m shipbrain.classrules download --out <folder>`): crawls the free rule pages of IACS (CSR,
  UR, UI, Rec), DNV, ABS, BV, LR, ClassNK, KR, CCS, RINA, IRS, PRS, CRS, TL for their PDF rule books (ships and
  offshore). Rule books that need a free login: save them into `<folder>/<society>/` by hand. Then
  `python -m shipbrain.classrules build --pdfs <folder>` cuts them into sections with their formulas into **private**
  packs (`packs/class_rules_<society>.private.sbpack`, git-ignored: the rules are copyright of each society).
  `class_rule` action `search` finds the section and quotes the requirement and formula with document, section, page.
- **Training** (`training/class_rule_tasks.py`, in the Kaggle run): calculator questions for many ship sizes and, for
  every rule section with a formula, "what is the formula / requirement for ... in <society> rules?" -> search ->
  the requirement in words + formula + where its symbols are defined + document, section, page. The Kaggle run
  downloads the free rule books itself (SB_CLASS_RULES=0 to skip) and uses any rule PDFs you attach; **a model trained
  on them is private** (kept off GitHub, uploaded only to your private Hugging Face repo).
- The paid rule-check programs (BV Mars, DNV Nauticus Hull, ABS Eagle, ClassNK PrimeShip-Hull, LR RulesCalc, KR
  SeaTrust-HullScan, CCS Compass) are licensed software of each society and cannot be downloaded or copied.
- Not tested here: the rule sites are blocked in the build session's network; the crawler, section cutter, private
  pack, search and training were checked with a rule-style PDF.

## Answers in natural language

Every technical answer explains in sentences what the result means, gives the value with units and where it comes
from (formula, rule and section), then the numbers - never only JSON or a bare number (system prompt rules 6 - 7;
every training answer is written that way).

## OpenRouter (cloud models, many free)

`python -m shipbrain --openrouter "qwen/qwen2.5-vl-72b-instruct:free"` with your key in `OPENROUTER_API_KEY`
(https://openrouter.ai/keys; never on the command line). OpenRouter speaks the same OpenAI API, so every ShipBrain tool,
cad3dify (`drawing_to_step`) and pictures work the same. `shipbrain.server.openrouter_models(free_only=True, vision=True)`
lists the free models that take pictures.

## Part drawing -> STEP with a correct-it loop: cad3dify on ShipBrain's own model

[cad3dify](https://github.com/neka-nat/cad3dify) (MIT) is copied whole and run as written: a 2D CAD drawing picture ->
CadQuery code -> run -> STEP -> render it in 3D -> the model compares the render with the drawing and corrects the
code, again and again. It was written for paid cloud models; ShipBrain runs it **unchanged on its own local model**
(a small launcher gives it the local OpenAI-style server and its "execute only" path; the cloud SDKs are not needed).

- Tool `drawing_to_step(file, refinements)`: picture or PDF of a part -> STEP, size and volume.
- **Training** (`training/cad3dify_tasks.py`, in the Kaggle run) uses **cad3dify's own prompts, taken from its own
  classes**, so the model is good at exactly the job cad3dify gives it: a three-view drawing of each verified CAD
  example -> its CadQuery code, and the drawing next to cad3dify's own render of a WRONG version (one dimension
  changed) -> the corrected code. Here: 94 samples (35 generate, 59 refine) in 30 s.
- Checked with a stand-in model server: the first round and two refinement rounds run, each sending the picture, and
  the STEP is right (60 x 40 x 10 box with a 12 mm hole: volume exact).
- Found on the way (cad3dify bug, not patched - its code stays unchanged): .jpg drawings fail in the refinement step
  (it saves with Pillow format "JPG"); ShipBrain always hands it a PNG copy, which also makes PDFs work.
- Needs `pip install "langchain<1" "langchain-openai<1" "langchain-experimental<1" svglib rlPyCairo loguru` (the
  chat shows this if missing).

## Construction drawings: ConstructDrawingAI (non-commercial licence)

[ConstructDrawingAI](https://github.com/A-SHOJAEI/ConstructDrawingAI) (PolyForm Noncommercial 1.0.0) is copied whole
and run as written, in its own Python process (3.11+). It reads construction drawings (electrical, architectural,
P&ID) into one schema, the CIR, and answers from it:

- `drawing_takeoff`: quantity takeoff - counts per item with **MasterFormat / IFC codes**, items to review,
  connections (conductors, home runs, feeders), lengths / areas when a scale is known
- `drawing_qa`: counts, lists, sheets, disciplines with evidence; `action: "rfi"` drafts RFIs for unclear items
- **Training** (`training/construct_tasks.py`, in the Kaggle run): its synthetic engine draws electrical sets
  (power & lighting plan, single-line diagram, panel schedule) in many styles with scan damage, each with an exact
  answer key checked by its own validator. The vision model learns to count symbols, do a takeoff with MasterFormat
  codes, and read panel voltage / circuits straight from the picture; 12 sets give 64 samples (60 with pictures).
  Its code is also a knowledge pack (`packs/ConstructDrawingAI.sbpack`, 1,066 chunks) for search and code training.
- **Real drawings too** (`training/construct_real.py`, in the Kaggle run, downloaded there): **PID2Graph** (CC BY-SA:
  real OPEN100 P&IDs + Dataset-P&ID + synthetic, every symbol and line connection annotated; converted with
  ConstructDrawingAI's own converter) -> valves / instruments / other symbols / line connections per sheet; and
  **CubiCasa5K** (CC BY-NC: 5,000 real floor plans) -> rooms by type, bedrooms, bathrooms, doors, windows. Up to about
  740 picture samples, answers from the datasets' own annotation.
- **PIDQA** (CC0: 64,000 questions on P&IDs) is paired with the Dataset-P&ID pictures inside PID2Graph - only after a
  check: the tags PIDQA lists for a sheet must be read (OCR) on that picture on at least 6 of 10 sheets, else it is
  skipped. Checked here both ways (right tags: 7 of 10 -> used; blank pictures -> skipped).
- **FloorPlanCAD** (CC BY-NC): fetched from the links on its page (Google Drive, gdown) and used only if its class-name
  list is in the download (names are never guessed). Not tested (its host is blocked here).
- **Symbol detector**: `training/kaggle/detector_kernel.py` - a separate free Kaggle GPU notebook trains its
  electrical symbol detector with its own code on its own synthetic drawings (YOLO11; dataset export checked here:
  6 sets -> 22 tiles, 278 boxes). Save the result as `~/.shipbrain/cdai/electrical.pt`; then `drawing_detect` reads
  electrical drawing pictures -> CIR -> takeoff / Q&A.
- **DELP** electrical plans: its authors give the annotated set only on request (academic e-mail to the SkeySpot
  authors); put it into a folder and its own converter reads it.

**Licence: ShipBrain is declared open and non-commercial** (`shipbrain/licence_mode.json`, set on the owner's word:
"I am not going to use commercial"). That allows non-commercial material (PolyForm Noncommercial, CC BY-NC) and
copyleft code (GPL, LGPL, AGPL, MPL: LibreCAD, QCAD, Inkscape, OpenCourant, OCXReader packs) to be searched and trained
on; every such item is marked (`vendor/*/NONCOMMERCIAL.md` / `COPYLEFT.md`, `usage` in its pack, packs/NOTICE.md).
Copyleft means ShipBrain and models trained with it stay open under the same terms. No pack is private-only any more. Before any commercial use of ShipBrain
or of a model trained with it: set `noncommercial` to false, remove those items and train again - or get a commercial
licence from their authors.

## Drawing compare like a CAD compare tool (DXF, DWG, PDF)

`compare_drawings` on two revisions of a drawing now gives what a CAD compare tool gives:

- **A result drawing** `compare_<a>_vs_<b>_changes.dxf`: removed in red, added in green, changed in yellow, and
  every change inside a **numbered revision cloud** (magenta). It opens in any CAD program.
- **A numbered change list** (also as `.csv` for Excel): number, kind, what it was, what it is now, layer and position.
- **More than lines and text**: block insert moved / added / removed, block attributes changed, dimension value
  changed (e.g. 4000 → 3900), hatch changed, circles and arcs, and layer settings (colour, linetype, on/off, frozen).
- **Filters and tolerance**: ignore kinds (`ignore: ["hatches", "dimensions"]`) or layers (`ignore_layers`), and a
  position tolerance so tiny shifts do not count as changes.
- **DWG**: through the free **ODA File Converter** (opendesign.com → ODA File Converter, free download). Its
  licence does not allow ShipBrain to include it, so install it once; ShipBrain finds it by itself (PATH, the usual
  install folders) or from `SHIPBRAIN_ODA` / `~/.shipbrain/oda.txt`. Each DWG is converted once and cached.
  Without it: save the drawing as DXF in AutoCAD.

## Something not installed? The chat says what, why, and gives the link

When a tool needs free software that is not on the PC (ODA File Converter for DWG, CalculiX, MYSTRAN, Node.js, Rust,
a C compiler, Tesseract OCR, llama.cpp, or a Python package), the chat shows an **Install needed** card: the name,
why it is needed, the official download link (clickable) and the steps for Windows, Linux or macOS, then "ask again".
The model is trained to repeat it, and if it forgets the link, the app adds it under the answer. Ask *"what do I need
to install?"* (tool `setup_check`, or `python -m shipbrain.installs`) for the whole list with installed / missing.
All links live in one place: `shipbrain/installs.py`. Only free software is listed.

## MYSTRAN: a free Nastran-compatible solver that RUNS the .bdf ShipBrain writes

[MYSTRAN](https://github.com/MystranSolver/MYSTRANSolver) (MIT) is copied whole into `shipbrain/vendor/MYSTRAN`. It solves
static (SOL 101), natural frequencies (SOL 103) and buckling (SOL 105) from the same Nastran `.bdf` files, so the
Nastran path no longer only "writes the input": `solve(file, solver="mystran", analysis)` runs it.

- Windows: take the ready `mystran.exe` from the MYSTRAN releases (put it on PATH or `remember_solver` once).
  Linux / macOS / WSL: `python -c "from shipbrain import mystran; mystran.build()"` (gfortran + cmake + ninja, ~10 min).
- Checked on the same plates as CalculiX: pressure deflection 12.50 mm (CalculiX 12.40), first natural frequency
  44.06 Hz (hand 44.14, CalculiX 44.24), buckling factor 7.415 (hand 7.447, CalculiX 7.492).
- Running it for real fixed the never-tested `.f06` reader: MYSTRAN's displacement table layout, its `job.F06` file
  name, and buckling factors read from the eigenvalue column (Nastran too).

## Physics lab: OpenPhysicsAI, used as written

[OpenPhysicsAI](https://github.com/molanocortes/OpenPhysicsAI) (Apache-2.0) is copied whole into `shipbrain/vendor/`
(code, docs, examples, validation data; pictures and videos left out) and built once on Linux / macOS (on Windows inside
WSL): `python -c "from shipbrain import openphysics; openphysics.build()"` (~30 s; clang or gcc + make).

- `physics_lab`: its more than twenty C solvers, each checked against a closed form or a measurement - flow up to
  shocks, heat, fire, water and sloshing, sound, radar, magnetics and motors, fracture, impact, gears and mechanisms,
  metal / plastic 3D printing. `list` / `get` the 77 example scenarios, `run` one as written or with `changes`. Checked
  here: the Lisle 2017 gear tooth gives 117.21 MPa at 15 kN (strain gauge 115.7 MPa) in 1.5 s, and twice the load
  gives exactly twice the stress.
- `mcp_tools` / `mcp_call`: ShipBrain is now also an **MCP client**. It talks to OpenPhysicsAI's own MCP server (88
  operations: geometry, meshing, materials, structural / thermal analysis, topology optimisation, mechanisms, 3D
  printing, the lab) and to any server you list in `<workdir>/mcp_servers.json`.
- The engine router now RUNS flow / CFD, heat, fracture and impact questions with it (before: guidance only).
- Training: `training/physics_tasks.py` builds it on Kaggle and runs the 13 examples measured to finish within 40 s on
  4 CPU cores (`training/data/physics_quick.json`), as written and with a changed load, and learns from the real records.
- On a CPU most of its simulations are batch jobs: of the 77 examples, 13 finish within 40 s (0.3-31 s: gear tooth,
  radar, sound, small flow / gas / heat volumes, Mach 6 capsule, orbits), 48 take longer (2D / 3D flow, fire, water,
  fracture), 16 need macOS (Apple maths library or the GPU flow engine). The physics-lab skill tells the model to say
  so before a long run.

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

## Fast on a CPU (and with pictures)

**Where the time goes** (`python -m shipbrain.speed` measures your PC and predicts it; method from
[HuggingArch](https://github.com/shenh10/HuggingArch), MIT: cost from the architecture, bounded by the hardware):

- **Reading** the prompt (question, retrieved knowledge, pictures) is compute-bound: a 4B model reads ~20-60 tokens/s
  on a CPU. This is what makes you wait for the first word.
- **Writing** each word is memory-bound: all weights (~2.5 GB) + the KV cache are read per token, ~10-20 tokens/s.

| Measure | What it saves |
|---|---|
| **Knowledge at the end of the prompt**: retrieved text goes into the newest question, so the system prompt and the earlier turns stay one fixed prefix for llama.cpp's prompt cache | each turn reads only its new tokens; a long chat no longer re-reads its history |
| **Retrieval budget** (`--rag-budget`, default 1800 characters ~ 500 tokens), filled by priority: profile, skill, your memory, one CAD example, rule book, repo text; each cut to its share | at ~45 tokens/s every 100 retrieved tokens cost ~2 s of waiting |
| **Fast llama.cpp settings** set by ShipBrain: flash attention, 8-bit KV cache (`-fa on -ctk q8_0 -ctv q8_0`), physical-core threads, 512-token prompt batches; dropped automatically on an older llama-server | half the KV-cache bytes per written token; faster prompt reading |
| **Draft model** (`--draft shipbrain-draft-q8_0.gguf`, Qwen3-0.6B) | ~1.5-2x faster writing, same answers |
| **The 4 GB graphics card** (`--gpu auto`) | mostly speeds up READING: ~1500 tokens/s instead of ~45, the first word comes in about a second |
| **Pictures**: `look` sends 1024 px (~740 image tokens, ~25 s to read on a CPU, ~10 s with the card); crops of the part you need are cheaper; several questions about the same picture reuse the cache | image tokens grow with the square of the size |
| **Long chats**: old turns are folded into code-made notes at the context limit (`--ctx 8192`) | the KV cache, and so the writing speed, stays bounded |
| **Compact system prompt and short tool results** (in training too); knowledge lives in the search index, not the weights | fewer tokens to read |

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
python training/finetune.py --data data/train.jsonl --out shipbrain_model

# 4. score again
python training/evaluate.py --server http://127.0.0.1:8080 --data data/eval.jsonl --out eval_after.json
```

Base model: **fixed** to `Qwen3-VL-4B-Instruct` in `training/base_model.json` (vision built in; do not change between runs). See
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
separate program), llama.cpp (MIT) and llamafile (Apache-2.0), the OCX schema (Apache-2.0), xsdata and xmlschema (MIT),
OCXReader (LGPL-2.1, unchanged, run as a separate program). Non-commercial only (allowed because ShipBrain is
declared non-commercial, see above): ConstructDrawingAI and ReverseCAD (PolyForm Noncommercial 1.0.0). Training uses Qwen3 (Apache-2.0), Unsloth (Apache-2.0),
Transformers and PEFT (Apache-2.0). PyMuPDF (AGPL or paid) was replaced. ANSYS and Abaqus are only targets of the file
converters and are never needed.

## Credits (ideas, no code copied)

- [agent3dify](https://github.com/neka-nat/agent3dify) (MIT): a fixed script contract with one JSON result line; a stall guard for repair loops; checking the model's projected views against the drawing.
- [text-to-cad](https://github.com/earthtojake/text-to-cad) (MIT): check the user's sizes against the built solid, not against the model's words; an example corpus with prompts.
- [solidcraft](https://github.com/tangency-labs/solidcraft) (MIT/Apache-2.0): a verified example and oracle set; small tool replies.
  Now also: its five modelling skills (modeling, editing, checking, mechanisms, sheet metal; `vendor/solidcraft`) load
  in ShipBrain, and when SolidCraft is installed (free, https://solidcraft.io/download) its own MCP server
  (`solidcraft-cli mcp`) is a built-in server: `mcp_tools` / `mcp_call(server="solidcraft")`; without it the chat shows
  the download link. Its full code is a trained knowledge pack (3,580 files).
- [CAD2Program](https://manycore-research.github.io/CAD2Program/): small models do better emitting short parametric primitives than free B-rep code; used for `build_structure`.
- [OpenCourantRP](https://github.com/CAMLAB-UChile/OpenCourantRP) (AGPL-3.0): knowledge pack (manual, explicit-dynamics example decks for impact / crash / sloshing), trained on (copyleft allowed by the owner); no code copied.
- [Voitta](https://github.com/voitta-ai/voitta-rag) (voitta-rag is AGPL-3.0, so nothing was copied): hybrid search, re-indexing only changed files, search scope, assistant memory with like/dislike, tools over MCP.
- [CAD-pdf-chatbot](https://github.com/adityawalture/CAD-pdf-chatbot) (no licence, so nothing copied): checking written dimension arithmetic, OCR fallback for scans.
- [CADCraft](https://github.com/storytold/cadcraft) (MIT/Apache-2.0): DXF as the drawing exchange format.
- [ShipSpace-GA](https://github.com/kodendaal/ShipSpace-GA) (MIT, data CC BY 4.0): an arrangement generator, planned as a source of bulkhead and deck positions.
