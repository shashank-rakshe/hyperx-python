"""Validation rule: the drawn nesting of process blocks agrees with the step hierarchy."""

from pydexpi.pydexpi_classes.pydexpi_classes import EngineeringModel
from pydexpi.toolkits.diagram_toolkit import Bounds
from pydexpi.toolkits.process_drawing import ContainmentProblem, containment_problems
from pydexpi.validation.engine import LevelOfRecommendation, RuleScope, ValidationIssue
from pydexpi.validation.rules._naming import referenced_object_name


class ProcessStepDrawnInsideParent:
    """Validate that a drawn sub-step's block lies inside the block of the step above it, and
    that no block lies inside one it does not belong to.

    A process step may hold steps (``ProcessStep.subProcessSteps``), and a drawing shows that
    the way every flow diagram does: the inner block is drawn inside the outer one. A drawing's
    *structure* follows the hierarchy -- a sub-step's ``RepresentationGroup`` is held by that of
    the nearest drawn step above it -- but a group's holder says nothing about where its symbol is
    on the sheet. A block may be drawn at any position, whatever is drawn around it. So the sheet
    can show a containment the model does not hold, or hide one it does, and this rule reports both
    (``process_drawing.containment_problems``):

    - a drawn step whose block reaches outside the block of the nearest drawn step above it;
    - a drawn step whose block lies inside the block of a step that is neither above nor below
      it, so that the sheet shows it inside a step it does not belong to.

    Measured on the boxes of the two symbols, with ``process_drawing.CONTAINMENT_TOLERANCE``.

    RECOMMENDED: DEXPI 2.0.1 says nothing about where a ``RepresentationGroup`` is drawn
    relative to another -- its diagram model gives a group a holder and its primitives
    coordinates, and no rule relating the two -- so this is pyDEXPI's reading of what a block
    drawn inside a block means, a drawing convention and no DEXPI requirement.

    Model-scoped: it reads the drawing of two steps and the hierarchy between them, and what
    breaks it -- the *parent's* block, or the step's place in the hierarchy -- is neither the
    step nor its own drawing. It applies to the ``EngineeringModel`` because it
    needs both the conceptual model and the diagram.
    """

    id = "pydexpi_process_step_drawn_inside_parent"
    name = "Process step drawn inside its parent"
    description = (
        "Validates that the block of a drawn sub-step lies inside the block of the nearest "
        "drawn step above it, and that no drawn step's block lies inside the block of a step "
        "it is not a sub-step of."
    )
    level_of_recommendation = LevelOfRecommendation.RECOMMENDED
    source = (
        "pyDEXPI drawing convention: a sub-step is drawn inside its parent's block, as its "
        "RepresentationGroup is held by its parent's. DEXPI 2.0.1 relates the two groups "
        "(Core.Diagram.RepresentationGroup.Groups) and not their geometry"
    )
    applies_to = EngineeringModel
    scope = RuleScope.MODEL

    def validate(self, obj: EngineeringModel) -> list[ValidationIssue]:
        """Evaluate rule against given EngineeringModel.

        Parameters
        ----------
        obj : EngineeringModel
            The model to validate; one without a process model or without a diagram has
            nothing to report.

        Returns
        -------
        list[ValidationIssue]
            One issue per misplaced block, in the hierarchy's order, naming the step and the
            step its block is measured against.
        """
        return [self._issue(problem) for problem in containment_problems(obj)]

    @classmethod
    def _issue(cls, problem: ContainmentProblem) -> ValidationIssue:
        step, other = referenced_object_name(problem.step), referenced_object_name(problem.other)
        if problem.kind == "outside_parent":
            short = f"The block of {step} is not inside the block of {other}, the step it is in"
            if problem.shift is not None:
                dx, dy = problem.shift
                remedy = (
                    f"Moving the block by dx={dx:g}, dy={dy:g} brings it inside by the "
                    f"shortest way; enlarging the block of {other} makes room instead."
                )
            else:
                remedy = (
                    f"It is larger than that block, so no move brings it inside: make it "
                    f"smaller, or enlarge the block of {other}."
                )
            long = (
                f"{step} is a sub-step of {other}, and its block reaches {problem.overhang:g} "
                f"outside that step's block: it spans {_box(problem.box)} and the block of "
                f"{other} spans {_box(problem.other_box)}. {remedy}"
            )
        else:
            short = f"The block of {step} lies inside the block of {other}, which it is not in"
            long = (
                f"{step} is drawn inside the block of {other} -- it spans {_box(problem.box)}, "
                f"within {_box(problem.other_box)} -- but is not a sub-step of it, so the sheet "
                "shows a containment the model does not hold. Move the block out, or, if the "
                f"step belongs there, make it a sub-step of {other}."
            )
        return ValidationIssue(
            short_description=short,
            long_description=(
                long + " A drawing convention of pyDEXPI, not a DEXPI requirement: DEXPI 2.0.1 "
                "says which group holds which, not where either is drawn."
            ),
            applied_rule_id=cls.id,
            level_of_recommendation=cls.level_of_recommendation,
            affected_component_ids=[problem.step.id, problem.other.id],
        )


def _box(box: Bounds) -> str:
    return f"({box.min_x:g}, {box.min_y:g}) to ({box.max_x:g}, {box.max_y:g})"
