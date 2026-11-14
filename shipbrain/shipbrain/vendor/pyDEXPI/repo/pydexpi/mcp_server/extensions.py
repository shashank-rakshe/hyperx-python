"""How the MCP server is extended: entry-point plug-ins, and the fields they add to replies.

The core server answers questions about a model; an installed extension can add tools, prompts and
resources of its own. An extension is a callable ``register(mcp, sessions, file_access)`` that adds
its tools, prompts and resources to a server, declared under the entry-point group
:data:`ENTRY_POINT_GROUP`::

    [project.entry-points."pydexpi.mcp_extensions"]
    my_extension = "my_package.mcp:register"

The core never imports an extension by name: :func:`discover_extensions` finds what is
installed, and ``create_server`` registers it after the core's own tools. Registered last, its
tools would be listed last; an extension that wants them listed among the core's, where a client
reads them in context, says so with :func:`place_tools_after`, and ``create_server`` arranges the
list (:func:`arrange_tools`) once every extension is registered.

Discovery replies can say more than the core knows how to compute, and an extension can add fields
to them. The core reply calls :class:`ItemFields` at each place such a field goes, and an extension
registers a provider for that place with :func:`register_item_fields`; without one the reply simply
leaves the field out. A tool's description says what its reply holds, so the core declares the
passage of the description that documents each place (:func:`declare_field_passages`), and a
provider may give the passage that documents its fields: the core's description then names no
field the core does not give, and the extension's is the full one. Providers are per server, so
a server built without extensions never shows another server's fields.
"""

from __future__ import annotations

import logging
import textwrap
import weakref
from collections.abc import Callable, Mapping, Sequence
from importlib import metadata
from typing import Any, Protocol

from pydexpi.mcp_server.access import FileAccess
from pydexpi.mcp_server.session import ConnectionSessions

logger = logging.getLogger(__name__)

#: The entry-point group an MCP server extension is declared under.
ENTRY_POINT_GROUP = "pydexpi.mcp_extensions"

#: The places a discovery reply takes extension fields, and what each provider is passed:
#:
#: - ``"signal_port"`` -- ``(model, port)``: a drawn signal port of an instrument or sensing
#:   location in ``describe_item``'s ``signal_ports``, after its ``group_id``;
#: - ``"port_delegation"`` -- ``(model, process_model, port, delegated)``: a process port's
#:   ``delegation`` record, between ``delegates`` and ``problems``; ``delegated`` says whether
#:   the port is delegated or listed as delegated;
#: - ``"instrumentation_activity"`` -- ``(process_model, activity, system)``: an
#:   instrumentation activity's record, after its ``system``.
ITEM_FIELD_KINDS = ("signal_port", "port_delegation", "instrumentation_activity")

#: A provider of extra reply fields: called with what its kind is passed, it returns the fields
#: to merge, in the order they are to appear.
ItemFieldProvider = Callable[..., dict[str, Any]]


class McpExtension(Protocol):
    """What an entry point of :data:`ENTRY_POINT_GROUP` loads: a function registering an extension.

    It is called once per server, after the core's tools, with the server, its sessions and its
    file-access policy; a tool that touches a file goes through ``file_access.resolve``.
    """

    def __call__(self, mcp: Any, sessions: ConnectionSessions, file_access: FileAccess) -> None: ...


def discover_extensions() -> list[McpExtension]:
    """The installed MCP server extensions, in the order of their entry-point names.

    An entry point that fails to load is skipped, with a warning naming it and the error: one
    broken plug-in must not take the server down, and nothing else would say it is missing.
    """
    extensions: list[McpExtension] = []
    for entry_point in sorted(
        metadata.entry_points(group=ENTRY_POINT_GROUP), key=lambda point: point.name
    ):
        try:
            extensions.append(entry_point.load())
        except Exception:
            logger.warning(
                "Skipping the pyDEXPI MCP extension %r (%s): it failed to load.",
                entry_point.name,
                entry_point.value,
                exc_info=True,
            )
    return extensions


class ItemFields:
    """The extension fields of one server's discovery replies, by the place they go."""

    def __init__(self) -> None:
        self._providers: dict[str, list[ItemFieldProvider]] = {}
        self.passages: dict[str, str] = {}

    def register(self, kind: str, provider: ItemFieldProvider, passage: str | None = None) -> None:
        """Have *provider* add fields at the place *kind* names (:data:`ITEM_FIELD_KINDS`).

        *passage*, dedented whole lines, documents the place with the provider's fields in the
        description of the tool that replies there, in place of the core's passage. One
        provider of a kind may give one.
        """
        if kind not in ITEM_FIELD_KINDS:
            raise ValueError(f"Unknown kind of reply fields {kind!r}; known: {ITEM_FIELD_KINDS}.")
        if passage is not None:
            if kind in self.passages:
                raise ValueError(f"The reply fields {kind!r} are already described.")
            self.passages[kind] = passage
        self._providers.setdefault(kind, []).append(provider)

    def __call__(self, kind: str, *arguments: Any) -> dict[str, Any]:
        """The fields every provider of *kind* adds, merged in the order they were registered."""
        fields: dict[str, Any] = {}
        for provider in self._providers.get(kind, ()):
            fields.update(provider(*arguments))
        return fields


#: Fields of no extension: what a reply built outside a server carries.
NO_ITEM_FIELDS = ItemFields()


class _Arrangement:
    """What one server's tool list is to become once its extensions are registered."""

    def __init__(self) -> None:
        self.fields = ItemFields()
        self.placements: list[tuple[str, tuple[str, ...]]] = []
        self.passages: list[tuple[str, dict[str, str]]] = []


_BY_SERVER: weakref.WeakKeyDictionary[Any, _Arrangement] = weakref.WeakKeyDictionary()


def _arrangement_of(mcp: Any) -> _Arrangement:
    arrangement = _BY_SERVER.get(mcp)
    if arrangement is None:
        arrangement = _BY_SERVER[mcp] = _Arrangement()
    return arrangement


def item_fields_of(mcp: Any) -> ItemFields:
    """The extension fields of *mcp*'s discovery replies."""
    return _arrangement_of(mcp).fields


def register_item_fields(
    mcp: Any, kind: str, provider: ItemFieldProvider, passage: str | None = None
) -> None:
    """Have *provider* add fields to *mcp*'s discovery replies at the place *kind* names.

    *passage* is what the replying tool's description says of that place with these fields
    (:meth:`ItemFields.register`).
    """
    item_fields_of(mcp).register(kind, provider, passage)


def declare_field_passages(mcp: Any, tool: str, passages: Mapping[str, str]) -> None:
    """Declare which passage of *tool*'s description documents each place of extension fields.

    *passages* maps a kind (:data:`ITEM_FIELD_KINDS`) to the core's passage for it: dedented
    whole lines, found once in the description. :func:`arrange_tools` puts a provider's passage
    in its place.
    """
    unknown = set(passages) - set(ITEM_FIELD_KINDS)
    if unknown:
        raise ValueError(f"Unknown kinds of reply fields {sorted(unknown)}.")
    _arrangement_of(mcp).passages.append((tool, dict(passages)))


def place_tools_after(mcp: Any, anchor: str, names: Sequence[str]) -> None:
    """List the tools *names*, in that order, right after the tool *anchor* in *mcp*'s list.

    Applied by :func:`arrange_tools`, once every extension is registered, in the order the
    placements were made.
    """
    _arrangement_of(mcp).placements.append((anchor, tuple(names)))


def arrange_tools(mcp: Any) -> None:
    """Apply the tool placements and description passages made for *mcp*.

    ``create_server`` calls it after the extensions. The SDK has no public way to order its
    tool list or to change a registered tool's description, so this rebuilds its tool registry
    (``_tool_manager._tools``, insertion-ordered, which is the order ``tools/list`` gives); it
    is the one place in pyDEXPI that does. A placement or passage naming what is not there is a
    programming error and raises.
    """
    arrangement = _arrangement_of(mcp)
    tools: dict[str, Any] = mcp._tool_manager._tools
    for anchor, names in arrangement.placements:
        missing = [name for name in (anchor, *names) if name not in tools]
        if missing:
            raise ValueError(
                f"Cannot place the tools {list(names)} after {anchor!r}: no {missing}."
            )
        moved = {name: tools.pop(name) for name in names}
        arranged: dict[str, Any] = {}
        for name, tool in tools.items():
            arranged[name] = tool
            if name == anchor:
                arranged.update(moved)
        tools.clear()
        tools.update(arranged)
    for tool_name, passages in arrangement.passages:
        tool = tools[tool_name]
        for kind, passage in passages.items():
            replacement = arrangement.fields.passages.get(kind)
            if replacement is not None:
                tool.description = _replace_passage(tool.description, passage, replacement)


def _replace_passage(text: str, passage: str, replacement: str) -> str:
    """*text* with the dedented lines *passage* replaced by *replacement*, at their indent."""
    first = passage.splitlines()[0].strip()
    indent = next(
        (
            line[: len(line) - len(line.lstrip())]
            for line in text.splitlines()
            if line.strip() == first
        ),
        None,
    )
    old = textwrap.indent(passage, indent or "")
    if indent is None or text.count(old) != 1:
        raise ValueError(f"The description does not hold the passage {passage!r} exactly once.")
    return text.replace(old, textwrap.indent(replacement, indent))
