"""Validation rule: a process connection leaves an outlet port and enters an inlet port."""

from pydexpi.pydexpi_classes.pydexpi_classes import PortDirection, ProcessConnection
from pydexpi.toolkits.display_name import get_display_name
from pydexpi.validation.engine import LevelOfRecommendation, RuleScope, ValidationIssue
from pydexpi.validation.rules._naming import referenced_object_name


class ProcessStreamDirection:
    """Validate that every process connection runs from an ``Outlet`` port to an ``Inlet`` port.

    A stream -- and, by the same reading, an energy or information flow -- carries what leaves one
    step into another: its ``source`` port's ``nominalDirection`` is ``Outlet`` and its
    ``target`` port's ``Inlet``. Named for the stream, the common case; every ``ProcessConnection``
    is held to it.

    RECOMMENDED: DEXPI 2.0.1 gives ``Port.NominalDirection`` (Process.py L693) and the connection's
    ``Source`` / ``Target`` (L884-898) no stated relation. The CO2
    terminal export has four streams between two inlets and four between two outlets.

    Model-scoped: it reads the two ports the connection references, and an edit to a port --
    a change of its ``nominalDirection`` -- changes one
    without touching the connection, so a scoped run over the edited port would never reach
    this rule (AGENTS.md, *Validation rules*).
    """

    id = "pydexpi_process_stream_direction"
    name = "Process stream direction"
    description = (
        "Validates that every ProcessConnection's source port has the nominal direction Outlet "
        "and its target port Inlet."
    )
    level_of_recommendation = LevelOfRecommendation.RECOMMENDED
    source = (
        "pyDEXPI convention: a connection leaves an Outlet port and enters an Inlet port; "
        "DEXPI 2.0.1 relates Port.NominalDirection to neither end"
    )
    applies_to = ProcessConnection
    scope = RuleScope.MODEL

    def validate(self, obj: ProcessConnection) -> list[ValidationIssue]:
        """Evaluate rule against given ProcessConnection.

        Parameters
        ----------
        obj : ProcessConnection
            The connection to validate.

        Returns
        -------
        list[ValidationIssue]
            One issue per end whose port faces the wrong way. A port without a direction is a
            missing mandatory attribute, which the loader reports, and is not reported here.
        """
        issues: list[ValidationIssue] = []
        name = get_display_name(obj)
        for end, expected in (("source", PortDirection.OUTLET), ("target", PortDirection.INLET)):
            port = obj.__dict__.get(end)
            if port is None:
                continue
            direction = port.__dict__.get("nominalDirection")
            if direction is None or direction == expected:
                continue
            issues.append(
                ValidationIssue(
                    short_description=f"{name}'s {end} port is an {direction.value}",
                    long_description=(
                        f"{name} has {referenced_object_name(port)} as its {end}, a port with the "
                        f"nominal direction {direction.value}. A connection leaves an Outlet "
                        "port and enters an Inlet port."
                    ),
                    applied_rule_id=self.id,
                    level_of_recommendation=self.level_of_recommendation,
                    affected_component_ids=[obj.id, port.id],
                )
            )
        return issues
