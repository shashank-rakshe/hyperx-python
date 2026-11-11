"""Validation rule: a port performs roles the specification lists for its class."""

from pydexpi.pydexpi_classes.pydexpi_classes import Port
from pydexpi.toolkits.display_name import get_display_name
from pydexpi.toolkits.process_toolkit import role_names_for
from pydexpi.validation.engine import LevelOfRecommendation, RuleScope, ValidationIssue
from pydexpi.validation.rules._naming import referenced_object_name


class ProcessPortRoleNames:
    """Validate that every role a port performs has a name its class's description lists.

    DEXPI 2.0.1 lists, for each concrete port class, the role names its ``PerformedRoles`` "should
    have": ``Feed``, ``Product``, ``Inlet``, ``Outlet`` and 25 more for a ``MaterialPort``,
    ``Input`` / ``Output`` for a thermal or mechanical energy port, and so on
    (``process_toolkit.PORT_ROLE_NAMES``, which cites each list). An ``EnergyPort`` lists none,
    and a port performing no role is not reported.

    RECOMMENDED: the specification says "should".

    Model-scoped: it reads the names of the roles the port references, and an edit to a role --
    renaming it -- changes one
    without touching the ports performing it (AGENTS.md, *Validation rules*).
    """

    id = "pydexpi_process_port_role_names"
    name = "Process port role names"
    description = (
        "Validates that every Role a Port performs has one of the names DEXPI 2.0.1 lists for the "
        "port's class."
    )
    level_of_recommendation = LevelOfRecommendation.RECOMMENDED
    source = (
        "DEXPI 2.0.1, the port classes' descriptions: roles 'should have one of the following "
        "Names' (src/model/Process/Process/Process.py L737-846 at V2.0.1)"
    )
    applies_to = Port
    scope = RuleScope.MODEL

    def validate(self, obj: Port) -> list[ValidationIssue]:
        """Evaluate rule against given Port.

        Parameters
        ----------
        obj : Port
            The port to validate.

        Returns
        -------
        list[ValidationIssue]
            One issue per role whose name the port's class does not list.
        """
        names = role_names_for(type(obj))
        if names is None:
            return []
        issues: list[ValidationIssue] = []
        port_name = get_display_name(obj)
        for role in obj.__dict__.get("performedRoles") or []:
            role_name = role.__dict__.get("name")
            if role_name in names:
                continue
            issues.append(
                ValidationIssue(
                    short_description=f"{port_name} performs the role {role_name!r}",
                    long_description=(
                        f"{port_name} is a {type(obj).__name__} performing "
                        f"{referenced_object_name(role)}, named {role_name!r}; DEXPI 2.0.1 lists "
                        f"{', '.join(names)} for its class."
                    ),
                    applied_rule_id=self.id,
                    level_of_recommendation=self.level_of_recommendation,
                    affected_component_ids=[obj.id],
                )
            )
        return issues
