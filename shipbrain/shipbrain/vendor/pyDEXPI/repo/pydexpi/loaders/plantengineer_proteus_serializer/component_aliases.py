"""Alias table for PlantEngineer's non-standard `ComponentClass` names.

PlantEngineer's Proteus export uses its own vendor-specific strings for the `ComponentClass`
attribute instead of the DEXPI-standard class names the stock
:class:`~pydexpi.loaders.proteus_serializer.proteus_serializer.ProteusSerializer` expects (e.g.
on `Equipment`, `PipingComponent`, `ActuatingSystemComponent`,
`ProcessSignalGeneratingSystemComponent`, `InformationFlowOffPageConnector`,
`InformationFlow`, `PipeOffPageConnectorReference` elements). This module holds the mapping from
PlantEngineer's name to the DEXPI name, and rewrites a Proteus XML string before it reaches the
stock parser so the rest of the proteus serializer needs no changes.

`COMPONENT_CLASS_ALIASES` is a scaffold: fill it in as PlantEngineer/DEXPI name pairs are
identified, e.g. ``"PE_CentrifugalPump": "CentrifugalPump"``. Names not present in the table pass
through unchanged, so partially populating the table is safe.

**An entry is needed only for names DEXPI does not already define.** Of the `ComponentClass`
values in the reference exports under `data/exports/xvisual/`, `Flange`, `Strainer`, `Nozzle` and
`Pump` are all DEXPI class names already and resolve without help -- adding aliases for them
would be noise at best and a wrong narrowing at worst (`Pump` is a DEXPI class in its own right;
mapping it to `CentrifugalPump` would invent a pump type the export never claimed). Check
`pydexpi.pydexpi_classes` before adding a row.

`Strainer/filter` is the one that does need a row, and the vendor supplied the answer rather than
us guessing it. `pump_example.xml` uses `Strainer/filter` where `pump_example_v2.xml` -- a newer
export of the same plant -- uses `Strainer`, on both of the elements that carry the class: the
`ShapeCatalogue` definition (`ID="XVT_609"` in both files) and the one `PipingComponent` in a
piping network segment that draws on it.
"""

from lxml import etree

from pydexpi.loaders.xml_parsing import parse_xml_string

"""Maps a PlantEngineer `ComponentClass` value to its DEXPI-standard equivalent."""
COMPONENT_CLASS_ALIASES: dict[str, str] = {
    "Pipe reducer": "PipeReducer",
    "Strainer/filter": "Strainer",
    "Pipe Tee": "PipeTee",
    "Pipe tee": "PipeTee",
    "Check valve": "CheckValve",
    "Ball valve": "BallValve",
    "Ball valveReference": "OperatedValveReference",
    "Centrifugal pump": "CentrifugalPump",
    "Line blind": "LineBlind",
    "Blind flange": "BlindFlange",
}


def translate_component_class(plantengineer_name: str) -> str:
    """Translate a single PlantEngineer `ComponentClass` value to its DEXPI name.

    Parameters
    ----------
    plantengineer_name : str
        The `ComponentClass` value as it appears in a PlantEngineer Proteus export.

    Returns
    -------
    str
        The DEXPI-standard `ComponentClass` name, or `plantengineer_name` unchanged if no alias
        is registered for it.
    """
    return COMPONENT_CLASS_ALIASES.get(plantengineer_name, plantengineer_name)


def rewrite_component_classes_in_tree(root: etree._Element) -> None:
    """Rewrite every `ComponentClass` attribute in a parsed Proteus tree, in place.

    This is the form the loader uses: it applies the alias table to an already-parsed tree, so
    that no entry point has to round-trip the document through a string (which would discard the
    encoding declared by the original bytes). `rewrite_component_classes` is the string-in,
    string-out wrapper around it.

    Elements without a `ComponentClass` attribute, and all other attributes, are left untouched.

    Parameters
    ----------
    root : etree._Element
        Root of a parsed Proteus document. Modified in place.
    """
    for element in root.iter(etree.Element):
        component_class = element.get("ComponentClass")
        if component_class is not None:
            element.set("ComponentClass", translate_component_class(component_class))


def rewrite_component_classes(xml_string: str) -> str:
    """Rewrite every `ComponentClass` attribute in a Proteus XML string via the alias table.

    Parses `xml_string`, applies `rewrite_component_classes_in_tree`, and serializes the result
    back to a string.

    Parameters
    ----------
    xml_string : str
        Proteus XML content using PlantEngineer's `ComponentClass` names.

    Returns
    -------
    str
        Proteus XML content with `ComponentClass` attributes translated to DEXPI names.
    """
    root = parse_xml_string(xml_string)
    rewrite_component_classes_in_tree(root)
    return etree.tostring(root, encoding="unicode")
