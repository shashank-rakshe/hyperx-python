"""Generate the *-corrected.xml siblings of the two DEXPI process examples.

Only unambiguous defects are corrected: a misspelling whose intended target provably exists in
the same document, or an id collision that nothing references. Anything needing a judgement the
authors alone can make (which port `#TODO` meant, whether `Volume` belongs on `Separating`) is
left untouched.
"""

import re
from pathlib import Path

BASE = Path("data/dexpi_process_examples")
CO2_DIR = BASE / "CO2 sequestration plant - Oslo"
TE_DIR = BASE / "Tennessee Eastman - Semantum export"


def insert_header(text: str, header: str) -> str:
    """Put `header` immediately after the XML declaration, keeping the declaration first."""
    match = re.match(r"^<\?xml[^>]*\?>\s*", text)
    assert match, "expected an XML declaration"
    return text[: match.end()] + header + text[match.end() :]


CO2_HEADER = """<!--
  CORRECTED COPY - generated from CO2TerminalExample.xml, do not edit by hand.

  Applied (each is a misspelling whose intended target exists in this same document):
    * type "Process/Process.MaterialTempate" -> "Process/Process.MaterialTemplate"   (1x, line 835)
    * type "Process/TransportingFluidsInPiping" -> "Process/Process.TransportingFluidsInPipe"
      (3x, lines 925, 981, 1039)
    * reference "#Trimethlybenzene" -> "#Trimethylbenzene"                           (1x, line 795)

  Deliberately NOT changed, because only the author can decide them:
    * 6 references to "#TODO" (lines 1461, 1511, 2797, 3294, 4365, 5185)
    * "#B22A" (line 3443) and "#SplittingMaterial7_XL1" (line 6093), which have several
      near-matches each
    * "#CO2AnalysisComponents" (line 836) versus the ListOfMaterialComponents with id "v" (line 784)
    * the mandatory Identifier absent from 410 objects - synthesising tag names would be
      inventing engineering data
    * Composition "MoleFractions", Stream "Density", MaterialStateType "Display" and
      PercentageUnit.PartsPerMillion, all pending a check against the DEXPI 2.0 model
-->
"""

TE_HEADER = """<!--
  CORRECTED COPY - generated from TennesseeEastman-vpd-enriched.xml, do not edit by hand.

  Applied:
    * The ids QualifiedValue1..QualifiedValue4 were reused across 58 elements, which xsd:ID
      forbids and which makes later objects overwrite earlier ones in any id-keyed store. Each
      occurrence after the first now carries a numeric suffix (QualifiedValue1__02, ...).
      Nothing in the document references these ids, so renaming them changes no relationships.

  Deliberately NOT changed, because only the author can decide them:
    * the mandatory Identifier absent from 158 objects
    * Separating "Volume"/"Part1"/"Part2", StrippingDistilling "Volume" and
      ReactingChemicals "Duty", which look transposed between classes
-->
"""


def _write(path: Path, text: str) -> None:
    """Write *text* verbatim, without newline translation.

    `Path.write_text` opens in text mode with `newline=None`, which rewrites each line
    feed to `os.linesep`. Regenerating these fixtures on Windows would then produce CRLF
    and diff against the LF copies committed here, for files whose whole point is that
    they are reproducibly generated. `AbstractTreeReferenceSerializer.save` passes
    `newline=""` for the same reason.
    """
    with open(path, "w", encoding="utf-8", newline="") as handle:
        handle.write(text)


def make_co2() -> None:
    source = CO2_DIR / "CO2TerminalExample.xml"
    text = source.read_text(encoding="utf-8")

    replacements = [
        ("Process/Process.MaterialTempate", "Process/Process.MaterialTemplate", 1),
        (
            'type="Process/TransportingFluidsInPiping"',
            'type="Process/Process.TransportingFluidsInPipe"',
            3,
        ),
        ('objects="#Trimethlybenzene"', 'objects="#Trimethylbenzene"', 1),
    ]
    for old, new, expected in replacements:
        found = text.count(old)
        assert found == expected, f"expected {expected} of {old!r}, found {found}"
        text = text.replace(old, new)

    out = CO2_DIR / "CO2TerminalExample-corrected.xml"
    _write(out, insert_header(text, CO2_HEADER))
    print(f"wrote {out}")


def make_te() -> None:
    source = TE_DIR / "TennesseeEastman-vpd-enriched.xml"
    text = source.read_text(encoding="utf-8")

    seen: dict[str, int] = {}

    def renumber(match: re.Match[str]) -> str:
        name = match.group(1)
        seen[name] = seen.get(name, 0) + 1
        if seen[name] == 1:
            return match.group(0)
        return f'id="{name}__{seen[name]:02d}"'

    text = re.sub(r'id="(QualifiedValue[1-4])"', renumber, text)
    assert sum(seen.values()) == 58, f"expected 58 occurrences, saw {sum(seen.values())}"
    print(f"  renumbered: {seen}")

    out = TE_DIR / "TennesseeEastman-vpd-enriched-corrected.xml"
    _write(out, insert_header(text, TE_HEADER))
    print(f"wrote {out}")


make_co2()
make_te()
