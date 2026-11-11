"""Validation rule: a PipingNetworkSegment starts and ends where it says it does."""

from pydexpi.pydexpi_classes.plant.piping import PipingConnection, PipingNetworkSegment
from pydexpi.toolkits.display_name import get_display_name
from pydexpi.toolkits.piping_toolkit import segment_ends
from pydexpi.validation.engine import LevelOfRecommendation, RuleScope, ValidationIssue
from pydexpi.validation.rules._naming import referenced_object_name


class SegmentConnectivity:
    """Validate that a segment's declared ends are where its connections start and end.

    DEXPI defines ``PipingNetworkSegment.SourceItem`` as "the item at which the
    PipingNetworkSegment starts" and ``SourceNode`` as "the PipingNode at which [it]
    starts", and ``TargetItem`` / ``TargetNode`` likewise for where it ends. This rule
    holds the declared ends to the segment's own items and connections, read through
    :func:`~pydexpi.toolkits.piping_toolkit.segment_ends`:

    * a segment that starts with one of its own items starts at that item, so
      ``sourceItem`` must be it;
    * a segment that starts with a connection coming from outside it (or from nowhere)
      starts where that connection does, so ``sourceItem`` and ``sourceNode`` must be
      the connection's own;
    * and the same for the target end.

    Nothing here needs the segment to be one linear run listed in flow order. That is
    the Proteus segment convention, not DEXPI: since 2.0.1 an item may be the source or
    target of any number of connections, and a segment's ``Items`` and ``Connections``
    are not ordered. :class:`SegmentLinearOrder` reports it, at RECOMMENDED level.
    A segment that branches has several ends, and its declared end must be one
    of them; a segment with no start at all (a closed loop, or an empty segment) may not
    declare one. Where a segment has exactly one start, the checks and their messages
    are those of a linear run.

    An element that touches nothing else in the segment -- an item none of its
    connections enters or leaves, or a connection that neither starts nor ends at one
    of its items -- is not counted as a start or an end while the segment holds anything
    else: a stray pipe or an orphan item says nothing about where the run starts, and
    would otherwise pass as the declared end. ``SegmentLinearOrder`` reports it. A
    segment made only of such elements (a single pipe between two outside items, a
    single item) keeps them all.

    **An omitted end is read as "starts (or ends) nowhere", not as unstated.** All four
    attributes are 0..1, and pyDEXPI uses ``None`` for an open end: the segment and its end pipe
    name no item or node. So a ``None`` declared end agrees with an end connection that names none,
    and is reported as a mismatch against one that does. The specification leaves open when
    ``SourceNode`` may be omitted (a ``TODO`` in its 2.0.1 source); until it says, ``None`` cannot
    mean both an open end and "not stated".

    Where a segment starts at one of its own items, ``sourceNode`` is that item's inlet
    and not a connection's, so it is not compared here;
    ``SegmentReferenceNodesAndItemsMatch`` checks that it belongs to the item.
    """

    id = "pydexpi_segment_connectivity"
    name = "Segment connectivity"
    description = (
        "Validates that a PipingNetworkSegment's sourceItem/sourceNode and targetItem/targetNode "
        "are where its items and connections start and end"
    )
    level_of_recommendation = LevelOfRecommendation.MANDATORY
    source = (
        "DEXPI 2.0.1 Specification, PipingNetworkSegment.SourceItem / SourceNode (the item / "
        "PipingNode at which the PipingNetworkSegment starts) and TargetItem / TargetNode (at "
        "which it ends)"
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
        starts, ends = self._without_strays(segment, segment_ends(segment))
        return [
            *self._validate_end(segment, starts, is_source=True),
            *self._validate_end(segment, ends, is_source=False),
        ]

    def _validate_end(
        self, segment: PipingNetworkSegment, points: list, *, is_source: bool
    ) -> list[ValidationIssue]:
        """Check one declared end of `segment` against the places it actually starts or ends.

        Parameters
        ----------
        segment : PipingNetworkSegment
            Segment being validated.
        points : list
            The segment's starts (``is_source``) or ends, from ``segment_ends``.
        is_source : bool
            True for the start (``sourceItem`` / ``sourceNode``), False for the end.

        Returns
        -------
        list[ValidationIssue]
            List of validation issues found.
        """
        direction = "source" if is_source else "target"
        declared_item = getattr(segment, f"{direction}Item")
        declared_node = getattr(segment, f"{direction}Node")

        if not points:
            if declared_item is None and declared_node is None:
                return []
            return [self._issue_without_points(segment, direction, declared_item, declared_node)]
        if len(points) == 1:
            return self._issues_against_one(segment, points[0], direction)
        if any(self._agrees(point, declared_item, declared_node, direction) for point in points):
            return []
        return [self._issue_against_several(segment, points, direction)]

    @staticmethod
    def _without_strays(segment: PipingNetworkSegment, ends) -> tuple[list, list]:
        """`ends`' starts and ends, less every element that touches nothing else.

        Such an element is both a start and an end. It is dropped only while the segment
        holds an element that is not one, so a one-pipe or one-item segment keeps its
        only element.
        """
        stray = {id(point) for point in ends.starts} & {id(point) for point in ends.ends}
        members = {id(member) for member in [*segment.items, *segment.connections]}
        if not stray or members <= stray:
            return list(ends.starts), list(ends.ends)
        return (
            [point for point in ends.starts if id(point) not in stray],
            [point for point in ends.ends if id(point) not in stray],
        )

    @staticmethod
    def _agrees(point, declared_item, declared_node, direction: str) -> bool:
        """Whether the declared end is the one `point` gives, by identity."""
        if isinstance(point, PipingConnection):
            return (
                getattr(point, f"{direction}Item") is declared_item
                and getattr(point, f"{direction}Node") is declared_node
            )
        return point is declared_item

    def _issues_against_one(
        self, segment: PipingNetworkSegment, point, direction: str
    ) -> list[ValidationIssue]:
        """The issues for a segment with exactly one start (or end): each attribute on its own."""
        end_kind = "start" if direction == "source" else "end"
        declared_item = getattr(segment, f"{direction}Item")
        if not isinstance(point, PipingConnection):
            if declared_item is point:
                return []
            return [
                self._issue(
                    segment,
                    f"{get_display_name(segment)} {direction}Item mismatch",
                    f"Segment {direction}Item {referenced_object_name(declared_item)} does not "
                    f"match {end_kind} item {referenced_object_name(point)}.",
                )
            ]
        issues = []
        for attribute in (f"{direction}Item", f"{direction}Node"):
            declared, actual = getattr(segment, attribute), getattr(point, attribute)
            if declared is not actual:
                issues.append(
                    self._issue(
                        segment,
                        f"{get_display_name(segment)} {attribute} mismatch",
                        f"Segment {attribute} {referenced_object_name(declared)} does not match "
                        f"{attribute} of {end_kind} connection {referenced_object_name(actual)}.",
                    )
                )
        return issues

    def _issue_against_several(
        self, segment: PipingNetworkSegment, points: list, direction: str
    ) -> ValidationIssue:
        """The issue for a declared end that is none of a segment's several starts (or ends)."""
        end_kind = "start" if direction == "source" else "end"
        declared_item = getattr(segment, f"{direction}Item")
        declared_node = getattr(segment, f"{direction}Node")
        places = "; ".join(self._place(point, direction) for point in points)
        # The attribute that fails: the node, when the item is one of the places' own --
        # an item end agrees on the item alone, so that leaves a connection's item whose
        # node is not the declared one.
        item_is_one = any(
            (getattr(point, f"{direction}Item") if isinstance(point, PipingConnection) else point)
            is declared_item
            for point in points
        )
        failing = f"{direction}Node" if item_is_one else f"{direction}Item"
        return self._issue(
            segment,
            f"{get_display_name(segment)} {failing} is none of its {end_kind}s",
            f"Segment {direction}Item {referenced_object_name(declared_item)} with "
            f"{direction}Node {referenced_object_name(declared_node)} is none of the "
            f"{len(points)} places its items and connections {end_kind}: {places}.",
        )

    def _issue_without_points(
        self, segment: PipingNetworkSegment, direction: str, declared_item, declared_node
    ) -> ValidationIssue:
        """The issue for a declared end on a segment that has no start (or end) at all."""
        end_kind = "start" if direction == "source" else "end"
        named = declared_item if declared_item is not None else declared_node
        attribute = f"{direction}Item" if declared_item is not None else f"{direction}Node"
        return self._issue(
            segment,
            f"{get_display_name(segment)} {attribute} names no {end_kind}",
            f"Segment {attribute} {referenced_object_name(named)} names where the segment "
            f"{end_kind}s, but none of its items and connections {end_kind}s anywhere: it is "
            "empty, or every item is entered by one of its own connections.",
        )

    @staticmethod
    def _place(point, direction: str) -> str:
        """One start (or end) of a segment, as a message names it."""
        if not isinstance(point, PipingConnection):
            return f"item {referenced_object_name(point)}"
        item = getattr(point, f"{direction}Item")
        node = getattr(point, f"{direction}Node")
        return (
            f"connection {referenced_object_name(point)} at {referenced_object_name(item)} "
            f"node {referenced_object_name(node)}"
        )

    def _issue(
        self, segment: PipingNetworkSegment, short_description: str, long_description: str
    ) -> ValidationIssue:
        return ValidationIssue(
            short_description=short_description,
            long_description=long_description,
            applied_rule_id=self.id,
            level_of_recommendation=self.level_of_recommendation,
            affected_component_ids=[segment.id],
        )
