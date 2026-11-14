"""Validation rule: a delegated port and its super port describe one delegation, consistently."""

from pydexpi.pydexpi_classes.pydexpi_classes import ProcessModel
from pydexpi.toolkits.process_hierarchy import (
    DELEGATION_CLAUSES,
    DelegationProblem,
    delegation_problems,
)
from pydexpi.validation.engine import LevelOfRecommendation, RuleScope, ValidationIssue
from pydexpi.validation.rules._naming import referenced_object_name


class ProcessPortDelegationConsistent:
    """Validate the delegation invariant on every ``Port.superReference`` / ``subReference`` link.

    A port of a step may be delegated to a step inside it: the inner port names the outer one as
    its ``superReference`` and the outer one lists it in ``subReference``. For every such link
    pyDEXPI holds (:mod:`pydexpi.toolkits.process_hierarchy`):

    (a) reciprocity: each side names the other, once;
    (b) one connection: the delegate's ``connectorReference`` is its super port's, and the
        delegate is the source or target of no connection;
    (c) downwards: the delegate's step lies below its super port's, at any depth;
    (d) the same port: the same class and the same ``nominalDirection``;
    (e) no cycle along ``superReference``.

    One issue is reported per link, listing every clause it breaks.

    RECOMMENDED: DEXPI 2.0.1 declares ``Port.SubReference`` and ``Port.SuperReference``
    (Process.py L703-707 and L717-723 at tag V2.0.1) without a description, and states none of
    this -- not even that the two are inverses. The reading is pyDEXPI's, and starts from its
    ``PORT-SUBREFERENCE`` deviation: ``SubReference`` is a reference here, where the specification
    declares a composition, so the two properties are two views of one link, and nothing but this
    rule holds them together: it finds models that break the invariant.

    A delegate and a super port that both name no connection agree, and are not reported: the
    missing ``connectorReference`` is ``pydexpi_mandatory_attribute_has_value``'s, once per port.

    Model-scoped: every clause reads the other port of the link, the step hierarchy or the
    connections' ends, which an edit elsewhere changes without touching the port.
    """

    id = "pydexpi_process_port_delegation_consistent"
    name = "Process port delegation consistent"
    description = (
        "Validates every delegated port against its super port: the two name each other, the "
        "delegate names its super port's connection and ends none, sits on a step inside its "
        "super port's, has its class and direction, and no chain of super ports is cyclic."
    )
    level_of_recommendation = LevelOfRecommendation.RECOMMENDED
    source = (
        "pyDEXPI convention, from its PORT-SUBREFERENCE deviation: Port.SubReference read as a "
        "reference and as the inverse of Port.SuperReference, which DEXPI 2.0.1 declares "
        "without a description (Process.py L703-707, L717-723) and without stating reciprocity"
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
            One issue per delegation link that breaks a clause, naming the delegate and the port
            it delegates, in the model's port order.
        """
        links: dict[tuple[int, int], list[DelegationProblem]] = {}
        for problem in delegation_problems(obj):
            links.setdefault((id(problem.port), id(problem.super_port)), []).append(problem)
        return [self._issue(problems) for problems in links.values()]

    @classmethod
    def _issue(cls, problems: list[DelegationProblem]) -> ValidationIssue:
        port, super_port = problems[0].port, problems[0].super_port
        clauses = list(dict.fromkeys(problem.clause for problem in problems))
        broken = ", ".join(f"({clause}) {DELEGATION_CLAUSES[clause]}" for clause in clauses)
        return ValidationIssue(
            short_description=(
                f"{referenced_object_name(port)} does not delegate "
                f"{referenced_object_name(super_port)} consistently: {broken}"
            ),
            long_description=(
                "; ".join(problem.message for problem in problems)
                + ". A delegated port stands in for its super port on a step inside that "
                "port's step: the two name each other, share one connection that the "
                "delegate does not end, and are of one class and direction. This is pyDEXPI's "
                "reading of Port.SubReference and Port.SuperReference, which DEXPI 2.0.1 "
                "declares without describing them: a convention, not a DEXPI requirement."
            ),
            applied_rule_id=cls.id,
            level_of_recommendation=cls.level_of_recommendation,
            affected_component_ids=[port.id, super_port.id],
        )
