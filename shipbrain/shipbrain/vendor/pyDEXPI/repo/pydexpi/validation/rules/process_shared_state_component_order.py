"""Validation rule: every template a material is read against lists the same components in order."""

from pydexpi.pydexpi_classes.pydexpi_classes import ProcessModel, Stream
from pydexpi.toolkits.display_name import get_display_name
from pydexpi.toolkits.process_materials import (
    PairingConflict,
    state_component_order,
    stream_template_conflicts,
)
from pydexpi.validation.engine import LevelOfRecommendation, RuleScope, ValidationIssue


class ProcessSharedStateComponentOrder:
    """Validate that a material state, and a stream, is read against one ordered component list.

    A ``Composition``'s fraction vector lists one value per component, "the order of items in the
    array ... determined by the list of chemical components ... in the corresponding
    MaterialTemplate" (DEXPI 2.0.1, Process.py L16-26). A ``MaterialState`` may be referenced by
    several streams, and each stream and its two ports may name a template, so a state can be
    paired with several. Unless they list the same components, by id, in the same order -- ``[A,
    B]`` against ``[B, A]``, or ``[A, B]`` against ``[A, C]`` -- one vector is read against two
    different components at one position. Two cases are reported:

    - a state whose paired templates (through each stream referencing it, the stream's own
      template and its ports') differ, naming the first two and the first differing position;
    - a stream whose own template and an end port's differ, whether or not it has a state.

    A stream's ports are its two ends and every port delegating one of them, at any depth
    (``process_materials.stream_material_ports``): a delegated port takes part in its super
    port's connection, and so carries the same material.

    Distinct templates listing the same ids in the same order agree.

    RECOMMENDED: the specification says the order is the corresponding template's, and pairs a
    state with no template itself; reading the pairing through the streams is pyDEXPI's.

    Model-scoped: which streams reference a state is a question about the whole process model.
    """

    id = "pydexpi_process_shared_state_component_order"
    name = "Process shared state component order"
    description = (
        "Validates that every MaterialTemplate a MaterialState is read against -- through each "
        "Stream referencing it and those streams' MaterialPorts -- lists the same components in "
        "the same order, and that a Stream's template agrees with its ports' templates."
    )
    level_of_recommendation = LevelOfRecommendation.RECOMMENDED
    source = (
        "DEXPI 2.0.1 Composition: the order of a vector is the corresponding MaterialTemplate's "
        "(Process.py L16-26); the pairing through streams and ports is pyDEXPI's reading"
    )
    applies_to = ProcessModel
    scope = RuleScope.MODEL

    def validate(self, obj: ProcessModel) -> list[ValidationIssue]:
        """Evaluate rule against given ProcessModel.

        Parameters
        ----------
        obj : ProcessModel
            The process model to validate.

        Returns
        -------
        list[ValidationIssue]
            One issue per stream disagreeing with its ports, and one per state read against
            disagreeing templates.
        """
        issues: list[ValidationIssue] = []
        for connection in obj.processConnections or []:
            if not isinstance(connection, Stream):
                continue
            conflicts = stream_template_conflicts(connection)
            if conflicts:
                issues.append(
                    self._issue(
                        f"{get_display_name(connection)} and its ports name different templates",
                        conflicts,
                        [connection.id],
                    )
                )
        for state in obj.materialStates or []:
            _ids, conflicts = state_component_order(obj, state)
            if conflicts:
                issues.append(
                    self._issue(
                        f"{get_display_name(state)} is read against templates that disagree",
                        conflicts,
                        [state.id],
                    )
                )
        return issues

    @classmethod
    def _issue(
        cls, short: str, conflicts: list[PairingConflict], first: list[str]
    ) -> ValidationIssue:
        affected = list(
            dict.fromkeys(
                [
                    *first,
                    *(
                        template.id
                        for conflict in conflicts
                        for template in (conflict.first.template, conflict.second.template)
                    ),
                ]
            )
        )
        return ValidationIssue(
            short_description=short,
            long_description=(
                "; ".join(conflict.describe() for conflict in conflicts)
                + ". Value i of a fraction vector belongs to component i of the template it is "
                "read against, so every template one material is read against must list the "
                "same components in the same order."
            ),
            applied_rule_id=cls.id,
            level_of_recommendation=cls.level_of_recommendation,
            affected_component_ids=affected,
        )
