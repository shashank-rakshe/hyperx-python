# Tennessee Eastman — Semantum export

A DEXPI 2.0 **process** model of the Tennessee Eastman challenge problem, exported from Semantum's
*Model Broker for Diagrams*.

| | |
| --- | --- |
| Producer | Semantum, *Model Broker for Diagrams* 2.11.0-SNAPSHOT |
| Exported | 2025-12-05 |
| Source diagram | `TennesseeEastman.vpd` (Semantum's native format; not retained here) |

## Files

| File | What it is |
| --- | --- |
| `TennesseeEastman-vpd-enriched.xml` | The export, **exactly as received**. Do not edit — it is a fixture for the loader. It repeats some `xsd:ID`s, so it does not pass XSD validation. |
| `TennesseeEastman-vpd-enriched-corrected.xml` | The same export with the duplicate `xsd:ID`s made unique. Schema-valid. Its leading XML comment lists every change. |
| `TennesseeEastmanHMB.xlsx` | The heat and mass balance behind the model. |

## Loading it

This is a process model, so it needs the lenient mode, because most of its objects
omit the mandatory `Identifier`:

```python
from pydexpi.loaders.public import load_xml_file

model = load_xml_file("TennesseeEastman-vpd-enriched.xml", strict=False)
process = model.conceptualModel           # ProcessModel
len(process.processSteps)                 # 40
len(process.processConnections)           # 43, all wired at both ends
```

## Rendering it

This file carries a full `Diagram`, so it can be drawn:

```python
from pydexpi.exports.svg_export import DrawDiagram

diagram = model.diagram[0] if isinstance(model.diagram, list) else model.diagram
DrawDiagram(diagram, pretty=True).save_svg(object_name="TennesseeEastman", filepath="te.svg")
```

**Expect a mostly black drawing.** The file gives colour components on a 0–1 scale where DEXPI's
fields are 0–255, so a `1` meaning *white* renders as `rgb(1,1,1)`. Geometry, z-order and label
placement are unaffected. The renderer reads the values as written, so this is not something to
change in `svg_export.py`.

## Known limitation

**Ten of the 11 `Composition` objects have no place in DEXPI 2.0.1**, so load the file with
`strict=False`; a strict load refuses it. The file is DEXPI 2.0, and pyDEXPI reads it as 2.0.1:
`MoleFractiona` is read as `MoleFractions`, `PercentageUnit` as `RatioUnit`, and
`Composition1`, which `MaterialStateType1` names, moves into it, which moves into `MaterialState1`
-- each step an INFO entry. 2.0.1 removed the model-level `Compositions` container, and a
`Composition` belongs to the `MaterialStateType` that holds it; `Composition2`-`Composition11` are
named by none. A lenient load drops each with an ERROR entry carrying its XML (`content`), so its
data stays recoverable; a strict load refuses the file rather than drop them. The vectors load: a
`QualifiedValue` holds a `PhysicalQuantityVector`. Under the
DEXPI 2.0 classes the compositions loaded, and only the vector in each one's `MoleFractiona`
`QualifiedValue` was lost -- with `strict=False` the `QualifiedValue` was kept without its value,
with `strict=True` it was dropped.
