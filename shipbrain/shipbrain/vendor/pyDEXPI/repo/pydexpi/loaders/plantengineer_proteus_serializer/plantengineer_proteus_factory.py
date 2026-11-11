"""Parser factory for PlantEngineer exports."""

from lxml import etree

from pydexpi.loaders.plantengineer_proteus_serializer.relaxed_piping_network_system_parser import (
    RelaxedPipingNetworkSystemParser,
)
from pydexpi.loaders.proteus_serializer.proteus_parser.core import ModuleContext
from pydexpi.loaders.proteus_serializer.proteus_parser.parser_factory import ParserFactory


class PlantEngineerProteusFactory(ParserFactory):
    """ParserFactory that builds PipingNetworkSystem parsers without connection inference.

    Overrides only `make_piping_network_system_parser` to instantiate
    `RelaxedPipingNetworkSystemParser` in place of the stock `PipingNetworkSystemParser`. All
    other factory methods are inherited unchanged.
    """

    def make_piping_network_system_parser(
        self, context: ModuleContext, element: etree._Element
    ) -> RelaxedPipingNetworkSystemParser:
        """Creates a relaxed piping network system parser for the given XML element.

        Includes parsing segments and generic attributes, identically to
        `ParserFactory.make_piping_network_system_parser`, but the returned parser skips the
        stock inference of implicit connections between unconnected segments.
        """
        segment_parsers = self._parse_child_elements(element, context, "PipingNetworkSegment")
        label_parsers = self._parse_child_elements(element, context, "Label")

        return self._create_parser_with_common_elements(
            RelaxedPipingNetworkSystemParser,
            context,
            element,
            segment_parsers=segment_parsers,
            label_parsers=label_parsers,
            parse_associations=False,
        )
