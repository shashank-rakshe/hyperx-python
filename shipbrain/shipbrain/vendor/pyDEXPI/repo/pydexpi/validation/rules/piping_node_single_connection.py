"""Validation rule: a piping node is the end of at most one piping connection."""

from pydexpi.pydexpi_classes.plant.piping import PipingConnection
from pydexpi.pydexpi_classes.pydexpi_classes import EngineeringModel
from pydexpi.toolkits import model_toolkit
from pydexpi.toolkits.display_name import get_display_name
from pydexpi.validation.engine import LevelOfRecommendation, RuleScope, ValidationIssue


class PipingNodeSingleConnection:
    """Validate that every PipingNode is referenced by at most one connection endpoint.

    A node is one physical port, so a pipe attaches to it at most once. Two
    pipes ending on one node are not a junction -- a junction is a PipeTee --
    and a single pipe whose source and target are the same node goes nowhere.

    **Endpoint references are counted, not connections.** A PipingConnection
    whose ``sourceNode`` and ``targetNode`` are the same node references it
    twice and is a violation, although only one connection is involved.

    **Segments' own end references are not counted.** A segment names the node
    it starts or ends on, and at a boundary two segments name the same node --
    the upstream one ending on the item's outlet and the downstream one starting
    there. That is how the corpus shares a boundary node, not a second pipe on
    the port.

    RECOMMENDED rather than MANDATORY: DEXPI 2.0 gives ``SourceNode`` and
    ``TargetNode`` each an opposite multiplicity of ``0..1``, which forbids two
    connections *starting* at one node or two *ending* at it, but does not
    clearly forbid one of each. The combined rule is the convention
    ``PipingValidityCode.MULTIPLE_NODE_REFERENCE_VIOLATION`` names.
    """

    id = "pydexpi_piping_node_single_connection"
    name = "Piping node single connection"
    description = (
        "Validates that every PipingNode is the sourceNode or targetNode of at most one "
        "PipingConnection endpoint."
    )
    level_of_recommendation = LevelOfRecommendation.RECOMMENDED
    source = "pyDEXPI piping convention (PipingValidityCode.MULTIPLE_NODE_REFERENCE_VIOLATION)"
    applies_to = EngineeringModel
    # MODEL, explicitly rather than by default: the question is how many
    # connections across the whole model end on one node, and a nozzle's node
    # can be reached from any piping system. Handed one segment it would miss a
    # pipe in another.
    scope = RuleScope.MODEL

    def validate(self, obj: EngineeringModel) -> list[ValidationIssue]:
        """Evaluate rule against given EngineeringModel.

        Parameters
        ----------
        obj : EngineeringModel
            EngineeringModel to validate.

        Returns
        -------
        list[ValidationIssue]
            One issue per node referenced by more than one connection endpoint.
        """
        # Keyed by identity, as a node is one object: two distinct nodes with
        # equal fields must not be counted together.
        endpoints: dict[int, tuple[object, list[tuple[PipingConnection, str]]]] = {}
        connections = model_toolkit.get_all_instances_in_model(obj, (PipingConnection,))
        for connection in connections:
            for attribute in ("sourceNode", "targetNode"):
                node = getattr(connection, attribute)
                if node is not None:
                    endpoints.setdefault(id(node), (node, []))[1].append((connection, attribute))
        return [self._issue(node, held) for node, held in endpoints.values() if len(held) > 1]

    @classmethod
    def _issue(cls, node, held: list[tuple[PipingConnection, str]]) -> ValidationIssue:
        ends = ", ".join(
            f"{get_display_name(connection)} {attribute}" for connection, attribute in held
        )
        node_name = get_display_name(node)
        return ValidationIssue(
            short_description=f"{node_name} is referenced by {len(held)} connection endpoints",
            long_description=(
                f"{node_name} is referenced by {len(held)} connection endpoints ({ends}). "
                "A node is one port, so a pipe attaches to it at most once; a junction is a "
                "PipeTee, not two pipes on one node."
            ),
            applied_rule_id=cls.id,
            level_of_recommendation=cls.level_of_recommendation,
            affected_component_ids=[
                node.id,
                *dict.fromkeys(connection.id for connection, _attribute in held),
            ],
        )
