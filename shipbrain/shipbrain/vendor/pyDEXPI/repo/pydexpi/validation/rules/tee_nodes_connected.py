"""Validation rule: every node of a pipe tee is connected."""

from pydexpi.pydexpi_classes.plant.piping import PipeTee
from pydexpi.pydexpi_classes.pydexpi_classes import EngineeringModel
from pydexpi.toolkits import model_toolkit
from pydexpi.toolkits.display_name import get_display_name
from pydexpi.validation.engine import LevelOfRecommendation, RuleScope, ValidationIssue


class TeeNodesConnected:
    """Validate that no PipeTee has a node that nothing connects to.

    A tee exists because a line branches there. A model whose branch segment was
    removed keeps the tee on the run with a node no connection and no segment end
    holds: a dead tee, which the drawing still shows as a junction. This rule
    reports it, one issue per free node.

    A node counts as connected when anything names it as ``sourceNode`` or
    ``targetNode`` -- a ``PipingConnection`` or a ``PipingNetworkSegment`` end,
    the holders ``piping_toolkit.node_holders`` counts -- never because its own
    drawing refers to it.

    A tee whose third node is left free for a line still to be drawn is reported
    too, until that line is drawn.

    RECOMMENDED rather than MANDATORY: DEXPI does not require a node to be
    connected, and a tee with a free node is a valid model. It is the pyDEXPI
    piping convention that a tee is a branch point.
    """

    id = "pydexpi_tee_nodes_connected"
    name = "Tee nodes connected"
    description = (
        "Validates that every node of every PipeTee is held by a connection or segment end."
    )
    level_of_recommendation = LevelOfRecommendation.RECOMMENDED
    source = "pyDEXPI piping convention: a PipeTee is a branch point"
    applies_to = EngineeringModel
    # MODEL, explicitly: what holds a tee's node is a connection or a segment
    # anywhere in the model, and what frees one is a change to that segment,
    # never to the tee.
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
            One issue per node of a PipeTee that no connection or segment end holds.
        """
        # One walk, not one per node: node_holders asks the whole model each time it is called,
        # and validation may run after every change to a model.
        instances = model_toolkit.get_all_instances_in_model(obj)
        held = {
            id(node)
            for instance in instances
            for attribute in ("sourceNode", "targetNode")
            if (node := getattr(instance, attribute, None)) is not None
        }
        return [
            self._issue(tee, node)
            for tee in instances
            if isinstance(tee, PipeTee)
            for node in tee.nodes
            if id(node) not in held
        ]

    @classmethod
    def _issue(cls, tee: PipeTee, node) -> ValidationIssue:
        tee_name, node_name = get_display_name(tee), get_display_name(node)
        return ValidationIssue(
            short_description=f"{tee_name} has an unconnected node, {node_name}",
            long_description=(
                f"{node_name} of {tee_name} is held by no connection and no segment end. A tee "
                "is a branch point; with a node free it is a dead end, as deleting its branch "
                "leaves it. Draw a line to the node, or remove the tee and rejoin its run."
            ),
            applied_rule_id=cls.id,
            level_of_recommendation=cls.level_of_recommendation,
            affected_component_ids=[tee.id, node.id],
        )
