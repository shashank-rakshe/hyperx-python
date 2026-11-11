"""Proteus loader for PlantEngineer exports.

Preprocesses PlantEngineer's XML into a form the stock proteus parser accepts before delegating
to it: translating `ComponentClass` names to DEXPI names, and defaulting missing
`SymbolRegistrationNumber` generic attributes on `ShapeCatalogue` shapes.

The hook is `_load_parsed`, because that — not `load_xmlstring` — is the one method every entry
point funnels through. `load_xml_file` and `load_xml_from_stream` both delegate to
`load_xml_as_bytes`, which calls `_load_parsed` directly and never passes through
`load_xmlstring`. Overriding `load_xmlstring` therefore left `PlantEngineerProteusSerializer`'s
file, byte and stream paths loading PlantEngineer data as if it were stock Proteus, silently.

Preprocessing is applied to the parsed tree rather than to XML text, so that byte input is still
parsed under the encoding the document itself declares. Rewriting the text would mean decoding,
mutating and re-encoding, which strands the original XML declaration against the new bytes.
"""

from collections.abc import Callable
from typing import Any

from lxml import etree

from pydexpi.loaders.plantengineer_proteus_serializer.component_aliases import (
    rewrite_component_classes_in_tree,
)
from pydexpi.loaders.plantengineer_proteus_serializer.shape_defaults import (
    ensure_shape_symbol_registration_numbers_in_tree,
)
from pydexpi.loaders.proteus_serializer.proteus_parser.core import ProteusLoader
from pydexpi.pydexpi_classes.pydexpi_classes import EngineeringModel


class PlantEngineerProteusLoader(ProteusLoader):
    """Proteus loader that preprocesses PlantEngineer XML before parsing.

    Applies to every entry point — `load_xml_file`, `load_xml_as_bytes`, `load_xml_from_stream`
    and `load_xmlstring` — since all of them route through `_load_parsed`.
    """

    def _load_parsed(
        self,
        parse: Callable[[Any], etree._Element],
        data: str | bytes,
    ) -> EngineeringModel:
        """Parse `data`, normalize the PlantEngineer dialect, then run the stock loading passes.

        Wraps the caller-selected `parse` so the normalization happens between parsing and the
        loading passes, leaving the base class's registry reset and its well-formedness error
        handling untouched.

        Parameters
        ----------
        parse : Callable
            The parse function to apply to the data, selected by the caller so that string and
            byte input are decoded correctly.
        data : str or bytes
            The XML content to parse and load.

        Returns
        -------
        EngineeringModel
            The loaded DEXPI model object.
        """

        def parse_and_normalize(payload: Any) -> etree._Element:
            root = parse(payload)
            rewrite_component_classes_in_tree(root)
            ensure_shape_symbol_registration_numbers_in_tree(root)
            return root

        return super()._load_parsed(parse_and_normalize, data)
