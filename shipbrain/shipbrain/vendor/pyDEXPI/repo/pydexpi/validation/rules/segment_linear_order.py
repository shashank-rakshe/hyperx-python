"""Validation rule: a PipingNetworkSegment is one run, listed in flow order (a convention)."""

from collections import Counter

from pydexpi.pydexpi_classes.plant.piping import (
    PipeTee,
    PipingConnection,
    PipingNetworkSegment,
    PropertyBreak,
)
from pydexpi.toolkits.display_name import get_display_name
from pydexpi.toolkits.piping_toolkit import (
    DexpiCorruptPipingSegmentException,
    segment_chain,
    segment_ends,
)
from pydexpi.validation.engine import LevelOfRecommendation, RuleScope, ValidationIssue

#: Items that end a run rather than sit inside one: a tee branches it, and a property break
#: marks where the run's properties change, which starts a new segment by the convention.
EDGE_ONLY_TYPES = (PipeTee, PropertyBreak)


class SegmentLinearOrder:
    """Validate that a segment follows the Proteus segment convention.

    Three things, in this order:

    1. **One linear run.** No item is entered by two of the segment's connections or
       left by two of them, and the segment has exactly one start and one end.
    2. **Listed in flow order.** ``items`` and ``connections`` each follow the run from
       its start to its end.
    3. **A PipeTee or PropertyBreak only at an end of the run**, never in the middle.

    Each step only means something once the one before has passed, so a segment that is
    not one run is reported for that and nothing else. An empty segment is left to
    ``SegmentNotEmpty``.

    None of this is DEXPI compliance, which is why the rule is RECOMMENDED. Since
    DEXPI 2.0.1 the opposite multiplicities of ``PipingConnection.SourceItem`` and
    ``TargetItem`` are unlimited (they were 1, so an item could start or end at most one
    connection), DEXPI has never ordered a segment's ``Items`` or ``Connections``, and its
    text puts no tee or property break at a segment boundary; the one place it mentions
    the convention, under ``PropertyBreak``, attributes a new segment after a reducer to
    "the Proteus Specification". Where a segment starts and ends -- what DEXPI does
    define -- is ``SegmentConnectivity``, MANDATORY.

    The convention is still what the corpus follows and what pyDEXPI's piping toolkit
    builds on. Linearity is read through
    :func:`~pydexpi.toolkits.piping_toolkit.segment_chain`, the function every walk of a
    run calls, so a segment this rule calls one run is one the toolkit can walk, and the
    reverse.
    """

    id = "pydexpi_segment_linear_order"
    name = "Segment linear order"
    description = (
        "Validates that a PipingNetworkSegment is one unbranched run with its items and "
        "connections listed in flow order, and a PipeTee or PropertyBreak only at its ends"
    )
    level_of_recommendation = LevelOfRecommendation.RECOMMENDED
    source = (
        "Proteus segment convention, which pyDEXPI's piping toolkit follows. Not "
        "DEXPI 2.0.1: PipingConnection.SourceItem / TargetItem have unlimited opposite "
        "multiplicities and PipingNetworkSegment.Items / Connections are not ordered"
    )
    applies_to = PipingNetworkSegment
    scope = RuleScope.OBJECT

    def validate(self, segment: PipingNetworkSegment) -> list[ValidationIssue]:
        """Evaluate rule against given PipingNetworkSegment.

        Parameters
        ----------
        segment : PipingNetworkSegment
            Segment to validate.

        Returns
        -------
        list[ValidationIssue]
            List of validation issues found.
        """
        if not segment.items and not segment.connections:
            return []
        issues = self._linearity_issues(segment)
        if issues:
            return issues
        try:
            chain = segment_chain(segment)
        except DexpiCorruptPipingSegmentException:
            return [self._not_one_run_issue(segment)]
        return [*self._order_issues(segment, chain), *self._edge_issues(segment, chain)]

    def _linearity_issues(self, segment: PipingNetworkSegment) -> list[ValidationIssue]:
        """Items entered or left twice, and a start or end count other than one."""
        issues = []
        item_ids = {id(item) for item in segment.items}
        entering = Counter(
            id(connection.targetItem)
            for connection in segment.connections
            if id(connection.targetItem) in item_ids
        )
        leaving = Counter(
            id(connection.sourceItem)
            for connection in segment.connections
            if id(connection.sourceItem) in item_ids
        )
        for item in segment.items:
            for counted, way in ((entering, "incoming"), (leaving, "outgoing")):
                if counted[id(item)] > 1:
                    issues.append(
                        self._issue(
                            f"{get_display_name(item)} has multiple {way} connections",
                            f"{get_display_name(item)} has multiple {way} connections in "
                            f"{get_display_name(segment)}, so the segment is not one linear run.",
                            [segment.id, item.id],
                        )
                    )

        starts, ends = segment_ends(segment)
        for points, kind, way, reference in (
            (starts, "start", "incoming", "source"),
            (ends, "end", "outgoing", "target"),
        ):
            if len(points) == 1:
                continue
            item_count = sum(1 for point in points if not isinstance(point, PipingConnection))
            issues.append(
                self._issue(
                    f"{get_display_name(segment)} has an invalid {kind} point",
                    f"Segment has {item_count} items with no {way} connections and "
                    f"{len(points) - item_count} connections with external {reference} "
                    f"references, but one linear run has exactly one {kind} point.",
                    [segment.id],
                )
            )
        return issues

    def _not_one_run_issue(self, segment: PipingNetworkSegment) -> ValidationIssue:
        """What is left when every item has one way in and out and the ends are single."""
        return self._issue(
            f"{get_display_name(segment)} is not one linear run",
            f"Not every item and connection of {get_display_name(segment)} lies once on the run "
            "from its start to its end: an element is listed twice, or some form a closed loop "
            "beside the run.",
            [segment.id],
        )

    def _order_issues(self, segment: PipingNetworkSegment, chain: list) -> list[ValidationIssue]:
        """One issue when either list departs from the run's flow order."""
        in_flow = [id(element) for element in chain]
        listed = [id(element) for element in (*segment.items, *segment.connections)]
        item_ids = {id(item) for item in segment.items}
        flow_items = [element for element in in_flow if element in item_ids]
        flow_connections = [element for element in in_flow if element not in item_ids]
        if (
            listed[: len(segment.items)] == flow_items
            and listed[len(segment.items) :] == flow_connections
        ):
            return []
        return [
            self._issue(
                f"{get_display_name(segment)} items/connections unsorted",
                "Items and connections in segment are not sorted in the order they are connected.",
                [segment.id],
            )
        ]

    def _edge_issues(self, segment: PipingNetworkSegment, chain: list) -> list[ValidationIssue]:
        """A PipeTee or PropertyBreak anywhere but at an end of the run."""
        ends = {id(chain[0]), id(chain[-1])}
        return [
            self._issue(
                f"{get_display_name(item)} in middle of segment",
                f"{get_display_name(item)} is in the middle of {get_display_name(segment)}, "
                "but it can only be at the start or end of the segment.",
                [item.id, segment.id],
            )
            for item in segment.items
            if isinstance(item, EDGE_ONLY_TYPES) and id(item) not in ends
        ]

    def _issue(
        self, short_description: str, long_description: str, affected: list[str]
    ) -> ValidationIssue:
        return ValidationIssue(
            short_description=short_description,
            long_description=long_description,
            applied_rule_id=self.id,
            level_of_recommendation=self.level_of_recommendation,
            affected_component_ids=affected,
        )
