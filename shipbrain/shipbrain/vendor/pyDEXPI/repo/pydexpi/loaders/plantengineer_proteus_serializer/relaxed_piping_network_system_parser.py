"""Piping network system parser that skips the stock segment-connection inference."""

from pydexpi.loaders.proteus_serializer.proteus_parser.core import ParserModule
from pydexpi.loaders.proteus_serializer.proteus_parser.parser_modules import (
    PipingNetworkSystemParser,
)


class RelaxedPipingNetworkSystemParser(PipingNetworkSystemParser):
    """PipingNetworkSystemParser without the implicit-connection inference between segments.

    `PipingNetworkSystemParser.reference_pass` calls `ParserModule.reference_pass` (to recurse
    into submodules) and then tries to infer a connection between any segment left without a
    source/target and its neighbor. PlantEngineer XML does not honor this implicit convention, but
    rather relies on consistent explicit connections. The absence of a connection element here
    does not indicate an inferred connection, but rather the absence of an explicit one. Therefore,
    `ParserModule.reference_pass` is called directly instead of `super().reference_pass()`.
    """

    def reference_pass(self) -> None:
        ParserModule.reference_pass(self)
