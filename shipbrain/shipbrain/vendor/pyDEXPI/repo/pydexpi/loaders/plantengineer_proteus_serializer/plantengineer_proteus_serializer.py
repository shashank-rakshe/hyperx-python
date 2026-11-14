from pydexpi.loaders.plantengineer_proteus_serializer.plantengineer_proteus_factory import (
    PlantEngineerProteusFactory,
)
from pydexpi.loaders.plantengineer_proteus_serializer.plantengineer_proteus_loader import (
    PlantEngineerProteusLoader,
)
from pydexpi.loaders.proteus_serializer.proteus_parser import ParserFactoryProtocol
from pydexpi.loaders.proteus_serializer.proteus_serializer import ProteusSerializer


class PlantEngineerProteusSerializer(ProteusSerializer):
    """Proteus serializer for PlantEngineer exports.

    Identical to `ProteusSerializer` except that it loads through
    `PlantEngineerProteusLoader`, which translates PlantEngineer's `ComponentClass` names to
    DEXPI names before parsing, and defaults to `PlantEngineerProteusFactory`, which skips the
    stock segment-connection inference. All other behavior (`load`, `load_from_bytes`,
    `load_from_stream`, `load_from_string`, `get_loading_errors`) is inherited unchanged.

    `__init__` is overridden (rather than a shared hook on `ProteusSerializer`) so this package
    stays self-contained without any changes to `pydexpi.loaders.proteus_serializer`.
    """

    def __init__(self, parser_factory: ParserFactoryProtocol = None):
        """Initialize the PlantEngineerProteusSerializer with a parser factory.

        Parameters
        ----------
        parser_factory : ParserFactoryProtocol, optional
            A factory to create parsers for the PlantEngineerProteusLoader. If not provided, a
            default PlantEngineerProteusFactory instance will be used.
        """
        parser_factory = parser_factory or PlantEngineerProteusFactory()
        self.proteus_loader = PlantEngineerProteusLoader(parser_factory)
