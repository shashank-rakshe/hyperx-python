"""The step hierarchy of a DEXPI process model, and the delegation of ports down it.

A ``ProcessStep`` holds the steps it is made of in ``subProcessSteps``, and a port of a step may
be *delegated* to a step inside it: the inner step's port names the outer step's port as its
``superReference``, and the outer one lists it back in ``subReference``.

DEXPI 2.0.1 declares the two properties and says nothing else about them: no description, and
"TODO check multiplicities" on both (``Port.SubReference``, ``src/model/Process/Process/Process.py``
L703-707, and ``Port.SuperReference``, L717-723, at tag ``V2.0.1`` of
https://gitlab.com/dexpi/Specification). It makes ``SubReference`` a composition, which pyDEXPI
reads as a reference (the ``PORT-SUBREFERENCE`` deviation: both producers write one, and a port
composed by its step and by its super port would be owned twice). What a delegation *means* is
therefore pyDEXPI's reading, stated here once and held by everything that checks one.

**The delegation invariant.** For every port ``p`` with ``p.superReference = q``:

(a) *reciprocity*: ``p`` is in ``q.subReference``, once, and every entry of ``q.subReference``
    names ``q`` back;
(b) *one connection*: ``p.connectorReference is q.connectorReference``. A delegate takes part in
    its super port's connection, and is never the ``source`` or ``target`` of one;
(c) *downwards*: the step ``p`` is a port of lies below the step ``q`` is a port of, at any depth
    of ``subProcessSteps``. A port of a ``ProcessStepDetail`` counts as its step's; a port of an
    ``InstrumentationActivity`` is on no step;
(d) *the same port*: the same class and the same ``nominalDirection``;
(e) *no cycle* along ``superReference`` (which, being single-valued, already gives a port at most
    one super port).

Chains over several levels are allowed: a delegate may be delegated again.

**Two producers, two readings.** The CO2 terminal export writes a delegate as the invariant
has it -- a stand-in for its super port, on the same side, naming no connection of its own (the
lenient loader derives the super port's, ``ElementBuilder.derive_absent_references``).
bpmn2dexpi writes the *inside face* of the super port instead: the sub-process holds a ``Source``
whose **outlet** delegates the parent's **inlet** (10 links), or a ``Sink`` whose inlet delegates
the parent's outlet (8), and that port is the end of a stream of its own, inside the
sub-process. All 18 of its delegates therefore break (b) and (d), which
:func:`delegation_problems` reports and nothing here repairs. A port that ends a connection of
its own is a port in its own right, whatever it delegates (:func:`connection_ends` is what says
which do).

Nothing here changes a model; the rule ``pydexpi_process_port_delegation_consistent`` and the
MCP server's ``describe_item`` both read the model through these functions, so they cannot
disagree about what a delegation is.
"""

from __future__ import annotations

from collections.abc import Iterable
from dataclasses import dataclass
from typing import cast

from pydexpi.pydexpi_classes.pydexpi_classes import (
    Port,
    ProcessConnection,
    ProcessModel,
    ProcessStep,
)
from pydexpi.toolkits.display_name import referenced_object_name
from pydexpi.toolkits.model_toolkit import get_all_instances_in_model
from pydexpi.toolkits.process_toolkit import iter_process_steps, ports_of

__all__ = [
    "DELEGATION_CLAUSES",
    "DelegationProblem",
    "StepTree",
    "connection_ends",
    "cut_delegations",
    "delegates_of",
    "delegation_problems",
    "is_delegated",
    "listed_below",
    "listing_ports",
    "model_ports",
    "super_chain",
]

#: The clauses of the delegation invariant, as :class:`DelegationProblem.clause` names them.
DELEGATION_CLAUSES: dict[str, str] = {
    "a": "reciprocity",
    "b": "one connection",
    "c": "downwards",
    "d": "the same port",
    "e": "no cycle",
}


# ---------------------------------------------------------------------------
# The step hierarchy
# ---------------------------------------------------------------------------


class StepTree:
    """Where every step and port of a process model sits in its step hierarchy, by identity.

    One cycle-safe walk (:func:`~pydexpi.toolkits.process_toolkit.iter_process_steps`). A port of
    a ``ProcessStepDetail`` is on the step holding the detail; a port of an
    ``InstrumentationActivity`` is on no step, since no step holds an activity.

    Parameters
    ----------
    process_model : ProcessModel
        The process model to read.
    """

    def __init__(self, process_model: ProcessModel) -> None:
        self._parents: dict[int, ProcessStep | None] = {}
        self._port_steps: dict[int, ProcessStep] = {}
        for step, holder in iter_process_steps(process_model):
            self._parents[id(step)] = holder if isinstance(holder, ProcessStep) else None
            for owner in (step, *(step.processStepDetails or [])):
                for port in ports_of(owner):
                    self._port_steps.setdefault(id(port), step)

    def holds(self, step: ProcessStep) -> bool:
        """Whether *step* is in the hierarchy at all."""
        return id(step) in self._parents

    def parent_of(self, step: ProcessStep) -> ProcessStep | None:
        """The step holding *step* in its ``subProcessSteps``, or None for a top-level step."""
        return self._parents.get(id(step))

    def step_of(self, port: Port) -> ProcessStep | None:
        """The step *port* is a port of, directly or through one of its details, or None."""
        return self._port_steps.get(id(port))

    def is_below(
        self,
        step: ProcessStep,
        ancestor: ProcessStep,
        *,
        moved: tuple[ProcessStep, ProcessStep | None] | None = None,
    ) -> bool:
        """Whether *step* lies strictly below *ancestor*, at any depth.

        With `moved`, a ``(step, new parent)`` pair, the answer is for the hierarchy as it would
        be with that step under that parent (None: at the top level), with nothing changed.
        """
        seen: set[int] = set()
        current = self._parent(step, moved)
        while current is not None and id(current) not in seen:
            if current is ancestor:
                return True
            seen.add(id(current))
            current = self._parent(current, moved)
        return False

    def _parent(
        self, step: ProcessStep, moved: tuple[ProcessStep, ProcessStep | None] | None
    ) -> ProcessStep | None:
        if moved is not None and step is moved[0]:
            return moved[1]
        return self._parents.get(id(step))


# ---------------------------------------------------------------------------
# Ports, their connections and their delegation links
# ---------------------------------------------------------------------------


def model_ports(process_model: ProcessModel) -> list[Port]:
    """Every port *process_model* composes, once each, in walk order.

    On steps, step details and instrumentation activities alike. A port something references
    and nothing owns is not among them: ``pydexpi_model_references_in_composition_tree`` reports
    that one.
    """
    return cast(
        "list[Port]",
        get_all_instances_in_model(process_model, (Port,)),  # type: ignore[arg-type]
    )


def connection_ends(process_model: ProcessModel) -> dict[int, list[tuple[ProcessConnection, str]]]:
    """``id(port) -> [(connection, "source" | "target")]`` for every end of every connection.

    Read from the connections' own ``source`` and ``target``, never from a port's
    ``connectorReference``: a delegate names a connection it is not an end of.

    A port in this map can stand without a super port -- it is part of its own connection -- so
    it does not depend on its delegation for its place in the model. A delegate
    in pyDEXPI's reading is never in it (clause (b)); bpmn2dexpi's delegates all are.
    """
    ends: dict[int, list[tuple[ProcessConnection, str]]] = {}
    for connection in process_model.processConnections or []:
        for end in ("source", "target"):
            port = connection.__dict__.get(end)
            if port is not None:
                ends.setdefault(id(port), []).append((connection, end))
    return ends


def super_chain(port: Port) -> tuple[list[Port], bool]:
    """The ports above *port* along ``superReference``, nearest first, and whether that is cyclic.

    The chain stops before the first port met a second time; the flag says that one was. A
    cyclic chain is clause (e) broken, on *port* itself or further up.
    """
    chain: list[Port] = []
    seen = {id(port)}
    current = port.__dict__.get("superReference")
    while isinstance(current, Port):
        if id(current) in seen:
            return chain, True
        seen.add(id(current))
        chain.append(current)
        current = current.__dict__.get("superReference")
    return chain, False


def listed_below(port: Port) -> list[Port]:
    """The ports *port* lists in ``subReference``, and those they list, at any depth, once each.

    Read downwards, from the super port's side, so it needs no walk of the model: what
    :mod:`~pydexpi.toolkits.process_materials` takes for the ports that carry one stream's
    material. A delegate its super port does not list is not among them; clause (a) is what
    reports that one. Cycle-safe.
    """
    found: list[Port] = []
    seen = {id(port)}
    pending = [port]
    while pending:
        for listed in pending.pop().__dict__.get("subReference") or []:
            if isinstance(listed, Port) and id(listed) not in seen:
                seen.add(id(listed))
                found.append(listed)
                pending.append(listed)
    return found


def delegates_of(ports: Iterable[Port], port: Port) -> list[Port]:
    """The ports of *ports* that name *port* as their ``superReference``, in order.

    Read from the delegates' side, which is what requires *port*: a port *port* merely lists in
    its ``subReference`` without being named back is not one (:func:`listing_ports`).
    """
    return [candidate for candidate in ports if candidate.__dict__.get("superReference") is port]


def listing_ports(ports: Iterable[Port], port: Port) -> list[Port]:
    """The ports of *ports* that list *port* in their ``subReference``, in order."""
    return [
        candidate
        for candidate in ports
        if any(listed is port for listed in candidate.__dict__.get("subReference") or [])
    ]


def is_delegated(ports: Iterable[Port], port: Port) -> bool:
    """Whether *port* is in a delegation from above: it names a super port, or one lists it."""
    return port.__dict__.get("superReference") is not None or bool(listing_ports(ports, port))


# ---------------------------------------------------------------------------
# The invariant, checked
# ---------------------------------------------------------------------------


@dataclass(frozen=True)
class DelegationProblem:
    """One clause of the delegation invariant that one link breaks.

    Attributes
    ----------
    clause : str
        ``"a"`` to ``"e"`` (:data:`DELEGATION_CLAUSES`).
    port : Port
        The delegate: the lower port of the link.
    super_port : Port
        The port it delegates, or, for a link only ``subReference`` states, the port listing it.
    message : str
        What is wrong, naming both ports.
    """

    clause: str
    port: Port
    super_port: Port
    message: str


def _named(connection: ProcessConnection | None) -> str:
    return "no connection" if connection is None else referenced_object_name(connection)


def _link_problems(
    port: Port,
    super_port: Port,
    tree: StepTree,
    ends: dict[int, list[tuple[ProcessConnection, str]]],
) -> list[DelegationProblem]:
    """The clauses the link ``port.superReference = super_port`` breaks, in clause order."""
    name, super_name = referenced_object_name(port), referenced_object_name(super_port)
    problems: list[DelegationProblem] = []

    def broken(clause: str, message: str) -> None:
        problems.append(DelegationProblem(clause, port, super_port, message))

    if not any(listed is port for listed in super_port.__dict__.get("subReference") or []):
        broken(
            "a",
            f"{name} names {super_name} as its super port, but {super_name} does not list it as "
            "a sub-port",
        )

    own = port.__dict__.get("connectorReference")
    above = super_port.__dict__.get("connectorReference")
    if own is not above:
        broken(
            "b",
            f"{name} names {_named(own)} as its connection and its super port {super_name} "
            f"names {_named(above)}",
        )
    for connection, end in ends.get(id(port), []):
        broken(
            "b",
            f"{name} is the {end} of {referenced_object_name(connection)}, and a delegated port "
            "ends no connection",
        )

    step, super_step = tree.step_of(port), tree.step_of(super_port)
    if step is None or super_step is None:
        off = [n for n, s in ((name, step), (super_name, super_step)) if s is None]
        broken("c", f"{' and '.join(off)} {'is' if len(off) == 1 else 'are'} on no process step")
    elif step is super_step:
        broken("c", f"{name} and {super_name} are ports of one step")
    elif not tree.is_below(step, super_step):
        broken(
            "c",
            f"{referenced_object_name(step)}, which {name} is a port of, is not inside "
            f"{referenced_object_name(super_step)}, which {super_name} is a port of",
        )

    if type(port) is not type(super_port):
        broken(
            "d", f"{name} is a {type(port).__name__} and {super_name} a {type(super_port).__name__}"
        )
    direction = port.__dict__.get("nominalDirection")
    super_direction = super_port.__dict__.get("nominalDirection")
    if direction != super_direction:
        broken(
            "d", f"{name} is {_direction(direction)} and {super_name} {_direction(super_direction)}"
        )

    chain, cyclic = super_chain(port)
    if cyclic and (chain[-1] if chain else port).__dict__.get("superReference") is port:
        # Reported for the links on the cycle itself, not for a chain that merely leads into one.
        loop = " -> ".join(referenced_object_name(member) for member in (port, *chain, port))
        broken("e", f"the super ports of {name} lead back to it ({loop})")

    return problems


def _direction(direction: object) -> str:
    value = getattr(direction, "value", direction)
    return "of no direction" if value is None else f"an {value}"


def delegation_problems(
    process_model: ProcessModel, *, tree: StepTree | None = None
) -> list[DelegationProblem]:
    """Every clause of the delegation invariant a link of *process_model* breaks.

    A link is a port and the port its ``superReference`` names, checked against (a) to (e); and a
    port listed in a ``subReference`` that does not name the listing port back, which is clause
    (a) alone, since nothing else is claimed by a link only one side states. A port a
    ``subReference`` lists more than once is clause (a) too, once per port: one link, stated
    twice. Problems come in the model's port order, a link's in clause order.

    A delegate and a super port that *both* name no connection are not reported for (b): they
    agree, and the missing mandatory ``connectorReference`` is
    ``pydexpi_mandatory_attribute_has_value``'s to report, once per port.

    `tree` is the model's :class:`StepTree`, for a caller that has built one already.
    """
    tree = tree or StepTree(process_model)
    ends = connection_ends(process_model)
    problems: list[DelegationProblem] = []
    for port in model_ports(process_model):
        super_port = port.__dict__.get("superReference")
        if isinstance(super_port, Port):
            problems += _link_problems(port, super_port, tree, ends)
        # An entry that is no port links nothing: a load reports it.
        entries = [e for e in port.__dict__.get("subReference") or [] if isinstance(e, Port)]
        counted: set[int] = set()
        for listed in entries:
            if id(listed) in counted:
                continue
            counted.add(id(listed))
            port_name, listed_name = referenced_object_name(port), referenced_object_name(listed)
            times = sum(1 for entry in entries if entry is listed)
            if times > 1:
                problems.append(
                    DelegationProblem(
                        "a",
                        listed,
                        port,
                        f"{port_name} lists {listed_name} as a sub-port {times} times",
                    )
                )
            named = listed.__dict__.get("superReference")
            if named is port:
                continue
            names = (
                "names no super port"
                if named is None
                else f"names {referenced_object_name(named)} as its super port"
            )
            problems.append(
                DelegationProblem(
                    "a",
                    listed,
                    port,
                    f"{port_name} lists {listed_name} as a sub-port, but {listed_name} {names}",
                )
            )
    return problems


def cut_delegations(
    process_model: ProcessModel,
    step: ProcessStep,
    new_parent: ProcessStep | None,
    *,
    tree: StepTree | None = None,
) -> list[tuple[Port, Port]]:
    """The delegation links moving *step* under *new_parent* would cut, as ``(port, super port)``.

    A link is cut when clause (c) holds for it now and would not once *step*, with everything
    inside it, hangs under *new_parent* (None: at the top level). Only a link from a port inside
    the moved subtree to a super port outside it can be: the two ports of any other link keep
    their places relative to each other. A link that breaks (c) already is not cut by the move,
    and is left to the rule. Nothing is changed. `tree` is the model's :class:`StepTree`, for
    a caller that has built one already.
    """
    tree = tree or StepTree(process_model)
    moved = (step, new_parent)
    cut: list[tuple[Port, Port]] = []
    for port in model_ports(process_model):
        super_port = port.__dict__.get("superReference")
        if not isinstance(super_port, Port):
            continue
        below, above = tree.step_of(port), tree.step_of(super_port)
        if below is None or above is None:
            continue
        if tree.is_below(below, above) and not tree.is_below(below, above, moved=moved):
            cut.append((port, super_port))
    return cut
