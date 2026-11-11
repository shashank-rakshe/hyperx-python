"""Loader/serializer for PlantEngineer's Proteus XML dialect (relaxed parsing, class aliasing).

Adapts the inbuilt Proteus XML parser to handle PlantEngineer exports, which are a dialect of
Proteus XML that uses a different set of component class names and does not honor the implicit
connection inference between segments, among others. Furthermore, PlantEngineer exports often
contain isolated, orphaned pipe tees that are not connected to anything and do not appear on the
diagram. These are not errors, but they can cause problems for graph-based analysis and
visualization, so a utility function is provided to remove them from the conceptual model.

`PlantEngineerProteusSerializer` is the intended entry point: it wires up the
`PlantEngineerProteusFactory` by default, whereas `PlantEngineerProteusLoader` inherits
`ProteusLoader.__init__` and so requires a parser factory argument.

Example
-------
>>> from pathlib import Path
>>> from pydexpi.loaders.plantengineer_proteus_serializer import (
...     PlantEngineerProteusSerializer,
...     remove_isolated_pipe_tees,
... )
>>> serializer = PlantEngineerProteusSerializer()
>>> model = serializer.load(Path("exports"), "plantengineer_export.xml")
>>> remove_isolated_pipe_tees(model.conceptualModel)  # optional cleanup, not automatic
"""

from .component_aliases import (
    COMPONENT_CLASS_ALIASES,
    rewrite_component_classes,
    rewrite_component_classes_in_tree,
    translate_component_class,
)
from .isolated_tees import get_isolated_pipe_tees, remove_isolated_pipe_tees
from .plantengineer_proteus_factory import PlantEngineerProteusFactory
from .plantengineer_proteus_loader import PlantEngineerProteusLoader
from .plantengineer_proteus_serializer import PlantEngineerProteusSerializer
from .relaxed_piping_network_system_parser import RelaxedPipingNetworkSystemParser
from .shape_defaults import (
    ensure_shape_symbol_registration_numbers,
    ensure_shape_symbol_registration_numbers_in_tree,
)
