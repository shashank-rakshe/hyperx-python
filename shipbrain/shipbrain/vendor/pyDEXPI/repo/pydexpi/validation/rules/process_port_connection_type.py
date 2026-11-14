"""Validation rule: a process connection joins ports of the class its own class names."""

from pydexpi.pydexpi_classes.pydexpi_classes import ProcessConnection
from pydexpi.toolkits.display_name import get_display_name
from pydexpi.toolkits.process_toolkit import port_class_for_connection
from pydexpi.validation.engine import LevelOfRecommendation, RuleScope, ValidationIssue
from pydexpi.validation.rules._naming import referenced_object_name


class ProcessPortConnectionType:
    """Validate that each end of a process connection is a port of the class it joins.

    The specification defines each connection class by the ports it joins: a ``Stream`` is "a
    flow of fluid or solid material between two MaterialPort objects", an ``InformationFlow`` a
    flow "between two instances of InformationPort", and each energy flow a flow between two ports
    of its own energy form -- ``EnergyFlow`` between any two ``EnergyPort`` s
    (``process_toolkit.PORT_CONNECTIONS``, which cites each description).

    MANDATORY: that is the specification's own definition of the class, at Process.py L900,
    L925, L977, L1008, L1027 and L4302 of tag V2.0.1, even though the generated
    ``source``/``target`` are typed ``Port``. Every connection of the corpus's process models
    fits it.

    Object-scoped: it reads the connection and the two ports it references.
    """

    id = "pydexpi_process_port_connection_type"
    name = "Process port connection type"
    description = (
        "Validates that the source and target of every ProcessConnection are ports of the class "
        "the connection's own class joins: MaterialPorts for a Stream, InformationPorts for an "
        "InformationFlow, and EnergyPorts of the flow's own form for an energy flow."
    )
    level_of_recommendation = LevelOfRecommendation.MANDATORY
    source = (
        "DEXPI 2.0.1, the descriptions of Stream, InformationFlow, EnergyFlow and its subclasses "
        "(src/model/Process/Process/Process.py at V2.0.1)"
    )
    applies_to = ProcessConnection
    scope = RuleScope.OBJECT

    def validate(self, obj: ProcessConnection) -> list[ValidationIssue]:
        """Evaluate rule against given ProcessConnection.

        Parameters
        ----------
        obj : ProcessConnection
            The connection to validate.

        Returns
        -------
        list[ValidationIssue]
            One issue per end that is not a port of the class the connection joins. A missing end
            is the loader's to report.
        """
        expected = port_class_for_connection(type(obj))
        if expected is None:
            return []
        issues: list[ValidationIssue] = []
        name = get_display_name(obj)
        for end in ("source", "target"):
            port = obj.__dict__.get(end)
            if port is None or isinstance(port, expected):
                continue
            issues.append(
                ValidationIssue(
                    short_description=f"{name}'s {end} is a {type(port).__name__}",
                    long_description=(
                        f"{name} is a {type(obj).__name__}, which joins two "
                        f"{expected.__name__}s, and its {end} {referenced_object_name(port)} is a "
                        f"{type(port).__name__}."
                    ),
                    applied_rule_id=self.id,
                    level_of_recommendation=self.level_of_recommendation,
                    affected_component_ids=[obj.id, port.id],
                )
            )
        return issues
