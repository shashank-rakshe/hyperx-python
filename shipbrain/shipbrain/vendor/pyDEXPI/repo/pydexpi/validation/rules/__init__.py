"""Validation rules for pyDEXPI models."""

from pydexpi.validation.rules.actuating_electrical_system_not_empty import (
    ActuatingElectricalSystemNotEmpty,
)
from pydexpi.validation.rules.actuating_system_not_empty import ActuatingSystemNotEmpty
from pydexpi.validation.rules.composition_fraction_vector_lengths import (
    CompositionFractionVectorLengths,
)
from pydexpi.validation.rules.composition_fractions import CompositionFractions
from pydexpi.validation.rules.connection_reference_nodes_and_items_match import (
    ConnectionReferenceNodesAndItemsMatch,
)
from pydexpi.validation.rules.engineering_model_not_empty import EngineeringModelNotEmpty
from pydexpi.validation.rules.instrument_in_at_most_one_loop import InstrumentInAtMostOneLoop
from pydexpi.validation.rules.instrumentation_loop_function_not_empty import (
    InstrumentationLoopFunctionNotEmpty,
)
from pydexpi.validation.rules.instrumentation_system_activity_not_empty import (
    InstrumentationSystemActivityNotEmpty,
)
from pydexpi.validation.rules.mandatory_attribute_has_value import MandatoryAttributeHasValue
from pydexpi.validation.rules.measuring_system_not_empty import MeasuringSystemNotEmpty
from pydexpi.validation.rules.model_composition_tree_unique import ModelCompositionTreeUnique
from pydexpi.validation.rules.model_references_in_composition_tree import (
    ModelReferencesInCompositionTree,
)
from pydexpi.validation.rules.operated_valve_reference_not_empty import (
    OperatedValveReferenceNotEmpty,
)
from pydexpi.validation.rules.piping_node_single_connection import PipingNodeSingleConnection
from pydexpi.validation.rules.piping_system_not_empty import PipingSystemNotEmpty
from pydexpi.validation.rules.plant_model_not_empty import PlantModelNotEmpty
from pydexpi.validation.rules.process_connection_ports_agree import (
    ProcessConnectionPortsAgree,
)
from pydexpi.validation.rules.process_fraction_vector_length import (
    ProcessFractionVectorLength,
)
from pydexpi.validation.rules.process_fractions_read_against_template import (
    ProcessFractionsReadAgainstTemplate,
)
from pydexpi.validation.rules.process_model_not_empty import ProcessModelNotEmpty
from pydexpi.validation.rules.process_port_connection_type import ProcessPortConnectionType
from pydexpi.validation.rules.process_port_delegation_consistent import (
    ProcessPortDelegationConsistent,
)
from pydexpi.validation.rules.process_port_role_names import ProcessPortRoleNames
from pydexpi.validation.rules.process_shared_state_component_order import (
    ProcessSharedStateComponentOrder,
)
from pydexpi.validation.rules.process_step_drawn_inside_parent import (
    ProcessStepDrawnInsideParent,
)
from pydexpi.validation.rules.process_stream_direction import ProcessStreamDirection
from pydexpi.validation.rules.qualified_value_binding import QualifiedValueBinding
from pydexpi.validation.rules.segment_connectivity import SegmentConnectivity
from pydexpi.validation.rules.segment_linear_order import SegmentLinearOrder
from pydexpi.validation.rules.segment_not_empty import SegmentNotEmpty
from pydexpi.validation.rules.segment_reference_nodes_and_items_match import (
    SegmentReferenceNodesAndItemsMatch,
)
from pydexpi.validation.rules.tee_nodes_connected import TeeNodesConnected

INBUILT_RULE_CLASSES = [
    "ActuatingElectricalSystemNotEmpty",
    "ActuatingSystemNotEmpty",
    "CompositionFractionVectorLengths",
    "CompositionFractions",
    "ConnectionReferenceNodesAndItemsMatch",
    "EngineeringModelNotEmpty",
    "InstrumentInAtMostOneLoop",
    "InstrumentationLoopFunctionNotEmpty",
    "InstrumentationSystemActivityNotEmpty",
    "MandatoryAttributeHasValue",
    "MeasuringSystemNotEmpty",
    "OperatedValveReferenceNotEmpty",
    "PipingNodeSingleConnection",
    "PipingSystemNotEmpty",
    "PlantModelNotEmpty",
    "ProcessConnectionPortsAgree",
    "ProcessFractionVectorLength",
    "ProcessFractionsReadAgainstTemplate",
    "ProcessModelNotEmpty",
    "ProcessPortConnectionType",
    "ProcessPortDelegationConsistent",
    "ProcessPortRoleNames",
    "ProcessSharedStateComponentOrder",
    "ProcessStepDrawnInsideParent",
    "ProcessStreamDirection",
    "QualifiedValueBinding",
    "SegmentConnectivity",
    "SegmentLinearOrder",
    "SegmentNotEmpty",
    "SegmentReferenceNodesAndItemsMatch",
    "TeeNodesConnected",
    "ModelCompositionTreeUnique",
    "ModelReferencesInCompositionTree",
]

# Single-sourced from the registry above rather than repeated as a literal: the two drifting
# apart is how a registered rule stops being importable. ruff wants a literal here (PLE0605).
__all__ = INBUILT_RULE_CLASSES  # noqa: PLE0605
