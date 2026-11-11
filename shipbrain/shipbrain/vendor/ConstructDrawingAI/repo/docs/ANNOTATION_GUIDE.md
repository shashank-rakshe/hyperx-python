# Annotation guide — building the REAL electrical/architectural test set

This turns real plan sheets into the held-out **real-drawing scoreboard** — the only board
that counts as accuracy. The pipeline pre-labels each sheet with the trained detector so you
**correct**, not label from scratch; your corrections become CIR pairs the scoreboard loads
directly.

> **Note:** for *electrical*, DELP already gives us 403 real annotated sheets
> (`datasets/real/electrical/roboflow__delp/`), so the immediate need for hand-annotation is
> **architectural** (no ready real annotated arch set) and additional electrical diversity
> across more design firms.

## Workflow

```bash
# 1. Build a batch (select from the Missouri index, rasterize @300 DPI, pre-label E-sheets)
python -m perception.annotation build --letter E --count 40      # detector pre-labels
python -m perception.annotation build --letter A --count 40      # no pre-labels (label from scratch)

# 2. Label Studio (one-time install; heavy Django app, so it is not a project dependency)
pip install label-studio
label-studio start
#   - Create a project; paste datasets/real/_annotation/<discipline>/label_config.xml as the
#     labeling config; import datasets/real/_annotation/<discipline>/import.json.
#   - Enable Local Storage pointing at the batch's images/ dir so the sheets display.

# 3. Correct the pre-labels (E) or draw boxes (A). Then export as JSON-MIN or JSON.

# 4. Ingest the export back into the real board (scoreboard-loadable CIR + PNG pairs)
python -m perception.annotation ingest \
    --export export.json --images datasets/real/_annotation/electrical/images \
    --out datasets/real/electrical/missouri --discipline electrical
```

Then the real board picks it up with no new plumbing:
`python -m perception eval-detector --profile local_debug --real-root datasets/real/electrical`.

## Electrical classes (the detector's vocabulary — `perception/labels.py`)

Annotate exactly these 10; a symbol not in this list is **skipped** (or note it for a future
class). Box the **glyph itself**, tightly — not its leader text or circuit label.

| Class | What it is / looks like |
|---|---|
| **Duplex Receptacle** | standard wall outlet (two sockets) — circle with two parallel lines |
| **Quad Receptacle** | double duplex (four sockets) |
| **GFCI Receptacle** | ground-fault outlet (wet areas) — often marked "GFI/GFCI/WP" |
| **Light Fixture** | ceiling luminaire (troffer/surface) — often a square/rectangle with an X or fill |
| **Recessed Downlight** | recessed can light — a circle (sometimes with a cross) |
| **Wall Light** | wall-mounted sconce |
| **Single-Pole Switch** | wall switch — "S" (sometimes S with a subscript) |
| **Three-Way Switch** | "S₃" — three-way switching |
| **Junction Box** | J-box — a small square/circle marked "J" |
| **Panelboard** | the distribution panel — a filled/hatched rectangle, usually in the electrical room |

## Box + scope conventions

- **Tight boxes** around the symbol glyph; exclude the callout text, tag, and any leader line.
- **Plan area only.** Skip the **title block, legend, notes, schedules, and revision clouds** —
  annotate the devices drawn on the floor plan, not legend exemplars or schedule rows.
- **Skip** walls, room tags, dimensions, and free text (they are not detection targets; the
  detector's ground truth is symbols + the panel).
- If a symbol is ambiguous, check the sheet's **legend** (usually on E-001/E-101) — it defines
  that project's glyph set. If it maps to none of the 10 classes, skip it.
- A symbol clipped at the sheet edge: box the visible part.

## Provenance (do not skip)

These sheets are public records but the A/E firm's copyright persists → **evaluation only**:
annotate and score, never redistribute. The ingester stamps `research`/`unknown` automatically.

## Known pre-label failure modes (A10 QA — the current local-debug detector)

The pre-labels come from a **synthetic-only** detector, so treat them as hints, not truth.
Measured behaviour you should expect and correct:

- **Over-firing on large sheets.** On full 300-DPI Missouri E-sheets it emits ~230–640
  boxes/sheet (avg ~418) — far more than real device counts. Delete aggressively. Use
  `--prelabel-conf 0.5` (or higher) to suppress the low-confidence noise up front.
- **Panelboard hallucination.** It stamps "Panelboard" all over plain linework
  (206 across 4 sheets, where the truth is ~1 each). Be skeptical of *every* Panelboard
  pre-label — verify against the electrical room / one-line before keeping.
- **Recessed Downlight / Duplex over-prediction.** These two classes dominate its output;
  many are false positives on repetitive hatching or dimension ticks.
- **Sim-to-real collapse is real.** On the DELP real set the same detector scores ~0% mAP
  (it mislocalizes and mis-classes real glyphs). So on architectural sheets — where there
  are *no* pre-labels at all — expect to label from scratch; do not wait for useful hints.

Rule of thumb: if a pre-label doesn't sit tightly on a symbol you can name from the legend,
delete it. Under-keeping is safer than under-deleting for a *ground-truth* set.

## Diversity target

≥5 distinct design firms/projects per discipline (the batch builder already spreads the
selection round-robin across projects), so the eval board is not single-source.
