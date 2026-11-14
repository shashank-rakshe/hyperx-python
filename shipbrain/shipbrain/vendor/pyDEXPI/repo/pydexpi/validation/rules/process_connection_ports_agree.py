"""Validation rule: a process connection and the ports at its ends name each other."""

from pydexpi.pydexpi_classes.pydexpi_classes import Port, ProcessConnection
from pydexpi.toolkits.display_name import get_display_name
from pydexpi.validation.engine import LevelOfRecommendation, RuleScope, ValidationIssue
from pydexpi.validation.rules._naming import referenced_object_name


class ProcessConnectionPortsAgree:
    """Validate that a connection's source and target ports each name it as their connection.

    ``ProcessConnection.Source`` / ``.Target`` and ``Port.ConnectorReference`` describe one
    connection from its two sides, and pyDEXPI reads them as one relationship: the port a stream
    leaves names that stream as its ``connectorReference``, and so does the port it enters. One
    port as both the source and the target of a connection is reported too: a port is an end of
    at most one connection, once.

    RECOMMENDED: DEXPI 2.0.1 declares the two as separate associations
    (``Port.ConnectorReference``, Process.py L709-715, and ``ProcessConnection.Source`` /
    ``.Target``, L884-898, each marked "TODO check multiplicities"), and no text of the
    specification states that they are inverses. One declared bound even speaks against this
    reading: ``Port.ConnectorReference`` has ``oppositeUpper=1``, at most one port per
    connection, where a connection between two ports is named by two (and by their delegates).
    pyDEXPI reads that bound as an artefact of the unresolved TODO, not as a statement, and
    reports it as an erratum (``data/dexpi_process_examples/ERRATA.md``, erratum 3).
    This rule finds models where they disagree -- the CO2 terminal export's 13. An end that is missing is a missing mandatory attribute, which the
    loader reports, and is not reported here.

    Model-scoped: it reads the ``connectorReference`` of the two ports the connection references,
    which an edit to a port changes without touching the connection (AGENTS.md, *Validation
    rules*).
    """

    id = "pydexpi_process_connection_ports_agree"
    name = "Process connection ports agree"
    description = (
        "Validates that the source and target ports of every ProcessConnection name it as their "
        "connectorReference, and that no connection runs from a port to itself."
    )
    level_of_recommendation = LevelOfRecommendation.RECOMMENDED
    source = (
        "pyDEXPI convention: Port.ConnectorReference read as the inverse of "
        "ProcessConnection.Source/Target, which DEXPI 2.0.1 declares as separate associations; "
        "its opposite upper bound of 1 on Port.ConnectorReference, marked TODO, is read as an "
        "erratum (data/dexpi_process_examples/ERRATA.md, erratum 3)"
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
            One issue per end whose port names another connection or none, and one for a
            connection whose two ends are one port.
        """
        issues: list[ValidationIssue] = []
        name = get_display_name(obj)
        source, target = obj.__dict__.get("source"), obj.__dict__.get("target")
        one_port = source is target
        if isinstance(source, Port) and one_port:
            looped = source
            issues.append(
                self._issue(
                    obj,
                    looped,
                    f"{name} runs from {referenced_object_name(looped)} to itself",
                    f"{name} has {referenced_object_name(looped)} as both its source and its "
                    "target. A port is an end of at most one connection, once: a connection runs "
                    "between two ports.",
                )
            )
            return issues
        for end, port in (("source", source), ("target", target)):
            if port is None:
                continue
            named = port.__dict__.get("connectorReference")
            if named is obj:
                continue
            issues.append(
                self._issue(
                    obj,
                    port,
                    f"{name}'s {end} port names another connection",
                    f"{name} has {referenced_object_name(port)} as its {end}, but that port's "
                    f"connectorReference is {referenced_object_name(named)}. A connection and "
                    "the ports at its ends must name each other.",
                )
            )
        return issues

    @classmethod
    def _issue(
        cls, connection: ProcessConnection, port: Port, short: str, long: str
    ) -> ValidationIssue:
        return ValidationIssue(
            short_description=short,
            long_description=long,
            applied_rule_id=cls.id,
            level_of_recommendation=cls.level_of_recommendation,
            affected_component_ids=[connection.id, port.id],
        )
