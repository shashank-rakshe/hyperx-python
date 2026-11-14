"""A stable, human-readable text projection of a model, for review in Git.

The canonical DEXPI file stays the source of truth; this is a *review artifact*. It is designed so
that a small engineering change gives a small textual diff, and so that two model states the
semantic diff calls equal give identical text. It is deliberately not round-trippable, and a
textual diff of it is never turned back into a model change -- load both revisions and use
the semantic diff for that.

Format (version 2)::

    # pydexpi-projection 2

    ## conceptualModel.taggedPlantItems

    CentrifugalPump@3f9a1c0e2b7d  P-101
      designPressure = 10.0 PressureGaugeUnit.Bar
      nozzles = [Nozzle@a1b2c3d4e5f6, Nozzle@0f9e8d7c6b5a]
      tagName = "P-101"

    Nozzle@a1b2c3d4e5f6  N1
      ...

- One block per object: a header line -- ``Class@token`` and the object's tag, if any -- then its
  attributes indented two spaces, sorted by name. Unset attributes are left out.
- Composition children are listed in their parent as tokens and follow it as blocks,
  depth-first. A list whose order carries meaning (``pydexpi.toolkits.list_order``: the ones the
  specification declares ordered, and a segment's flow order) keeps it; any other is sorted by
  token, since its order is not a change.
- A reference is written ``name -> Class@token``; a reference list is sorted and unique, unless
  it is ordered (``ListOfMaterialComponents.component``), when it keeps its order.
- A value is rendered as data-type equality compares it: a list inside a value keeps its order
  where the specification declares it ordered (a ``PhysicalQuantityVector``'s values), and a unit
  is written class-qualified (``PressureGaugeUnit.Bar``), so a gauge and an absolute pressure, or
  two orders of one vector, never render alike.
- Sections group the blocks by where they live: the document itself, each list of the conceptual
  model, and the drawing (``diagram``, ``shapeCatalogues``). Within a section, top-level blocks
  are ordered by class and token -- so renaming a tag changes lines, and moves no block.

Version 2 changed four things version 1 sorted, flattened or kept: a
unit is class-qualified rather than its bare literal (``Bar``), a list inside a value keeps the
order the specification gives it, every list the specification declares ordered keeps its order --
a type group's elements, a shape's primitives, a template's fragments,
``ListOfMaterialComponents.component`` -- and an object's own *unordered* data lists
(``MaterialTemplate.phaseLabel``) are now sorted, where version 1 kept their file order. Under
version 1 a reordered vector, a gauge-to-absolute change or a swapped pair of component ids did
not show, and a reordered ``phaseLabel`` did. Every quantity line, and many drawing
lines, differ between the two versions, which is why the first line names the version.

Identity
--------
A token is ``Class@`` plus the first 12 hex digits of a SHA-256 of the object's identity key --
never Python's ``hash()``, which is salted per process. What the key is depends on whether the
object's id can be trusted across revisions:

- ``id_policy="all"`` trusts every id: right for models maintained as JSON,
  where ids survive every save and load -- including the ``id_<hex>`` ids ``make_id`` mints.
- ``id_policy="source"`` (the default) trusts every id that is *not shaped like* a ``make_id``
  id (``id_<32 hex>``). This is a heuristic on the id's shape, not knowledge of where it came
  from: an XML file's unidentified objects get a fresh ``make_id`` id on every load, and
  across the TrainingTestCases every re-minted id has that shape and every other id is stable.
  A file whose own ids happen to look like ``make_id`` ids would have them distrusted; one whose
  unstable ids look otherwise would have them trusted. For untrusted objects the key is derived
  from where the object sits and what it holds -- see ``_Tokens``.

A trusted object's token is its id alone, so no caption or content change touches it. An
untrusted object's token includes its content *and its tag*: renaming it gives it a new token.
In the corpus every tagged object has a trusted id, so this is rare for XML inputs; it is what the
rename column of the measurement in ADR 0002 records for an object created in code.
"""

from __future__ import annotations

import hashlib
import json
from collections.abc import Callable
from datetime import datetime
from enum import Enum
from typing import Any, Literal

from pydexpi.diff.domains import domain_of_location
from pydexpi.diff.ordering import is_order_significant
from pydexpi.pydexpi_classes.pydexpi_classes import (
    MultiLanguageString,
    PhysicalQuantity,
    PhysicalQuantityUnit,
    PyDexpiBaseModel,
    PyDexpiDataTypeBaseModel,
    Undefined,
)
from pydexpi.pydexpi_classes.unit_resolution import qualified_unit_name
from pydexpi.toolkits.base_model_utils import (
    get_composition_attributes,
    get_data_attributes,
    get_reference_attributes,
    is_generated_id,
)
from pydexpi.toolkits.display_name import (
    CAPTION_FALLBACK_ATTRIBUTES,
    DISPLAY_NAME_RESOLVERS,
    GENERIC_TAG_ATTRIBUTES,
    get_tag,
)
from pydexpi.versioning._index import _ModelIndex

__all__ = ["PROJECTION_FORMAT_VERSION", "IdPolicy", "model_to_projection"]

#: The version of the text format, written on the first line. 2: units class-qualified, lists
#: in values and ordered reference lists in their order.
PROJECTION_FORMAT_VERSION = "2"

IdPolicy = Literal["source", "all"]
"""Which ids to trust across revisions: those not shaped like ``make_id`` ids (a heuristic for
"supplied by the file"), or all of them."""

#: The attributes a caption is made of; a structural key leaves them out so a rename is not a
#: new object.
_CAPTION_ATTRIBUTES = frozenset(GENERIC_TAG_ATTRIBUTES + CAPTION_FALLBACK_ATTRIBUTES).union(
    name for _, names in DISPLAY_NAME_RESOLVERS for name in names
)

#: Hex digits of the SHA-256 kept in a token: 48 bits, so a collision among the objects of one
#: model is negligible -- and detected, since tokens are checked to be unique.
_TOKEN_HEX = 12


# ---------------------------------------------------------------------------
# Rendering values
# ---------------------------------------------------------------------------


def _is_unset(value: Any) -> bool:
    return value is None or isinstance(value, Undefined) or value == []


def _render(value: Any, *, sort_lists: bool = False) -> str:
    """One attribute value as text, exactly as fine as data-type equality.

    A list is sorted only when *sort_lists* says its order carries nothing: the caller decides
    that from the owning field (``pydexpi.toolkits.list_order``), so a ``PhysicalQuantityVector``'s
    values keep their order and a ``MultiLanguageString``'s languages do not. A unit is rendered
    class-qualified, so ``PressureGaugeUnit.Bar`` and ``PressureAbsoluteUnit.Bar`` differ.
    """
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, PhysicalQuantityUnit):
        return qualified_unit_name(value)
    if isinstance(value, Enum):
        return str(value.value)
    if isinstance(value, (int, float)):
        return repr(value)
    if isinstance(value, str):
        return json.dumps(value, ensure_ascii=False)
    if isinstance(value, datetime):
        return value.isoformat()
    if isinstance(value, Undefined):
        return "undefined"
    if isinstance(value, PhysicalQuantity):
        return f"{_render(value.value)} {_render(value.unit)}"
    if isinstance(value, MultiLanguageString):
        parts = sorted(
            f"{entry.language}:{_render(entry.value)}" for entry in value.singleLanguageStrings
        )
        return "{" + ", ".join(parts) + "}"
    if isinstance(value, PyDexpiDataTypeBaseModel):
        fields = [
            f"{name}="
            + _render(getattr(value, name), sort_lists=not is_order_significant(value, name))
            for name in sorted(type(value).model_fields)
            if not _is_unset(getattr(value, name))
        ]
        return f"{type(value).__name__}(" + ", ".join(fields) + ")"
    if isinstance(value, list):
        items = [_render(item, sort_lists=sort_lists) for item in value]
        return "[" + ", ".join(sorted(items) if sort_lists else items) + "]"
    return json.dumps(str(value), ensure_ascii=False)


# ---------------------------------------------------------------------------
# Identity
# ---------------------------------------------------------------------------


def _digest(*parts: object) -> str:
    payload = json.dumps(
        parts, ensure_ascii=False, separators=(",", ":"), sort_keys=True, default=str
    )
    return hashlib.sha256(payload.encode("utf-8")).hexdigest()


class _Tokens:
    """The token of every object.

    A trusted object's token comes from its id. An untrusted one's -- an id minted on load -- is
    *anchored*: it comes from its nearest trusted ancestor, the attribute and class path down from
    there, its own content (data without the caption attributes, plus the trusted objects it
    references), and its tag. Never from an untrusted ancestor's content, nor from its own
    position. An ordinal separates only objects equal in all of that, counted in document order.
    Leaving the caption attributes out of the content keeps a caption edit from counting twice;
    the tag itself is still part of the key, so renaming an untrusted object changes its token.

    That shape is the result of the measurement ADR 0002 records. Keying on the parent's token
    cascaded a property edit into every descendant (4032 changed lines for three edits across the
    corpus); keying on position renumbered siblings on insertion (685 lines against 83 for the
    inserted blocks themselves). Anchored keys cost only the edited object's own lines.

    ``strategy="positional"`` keeps the positional baseline, for that comparison's regression test.
    """

    def __init__(self, index: _ModelIndex, id_policy: IdPolicy, strategy: str = "anchored") -> None:
        self.index = index
        self.id_policy = id_policy
        self.strategy = strategy
        self.of: dict[str, str] = {}
        self._assign()
        tokens = list(self.of.values())
        if len(tokens) != len(set(tokens)):  # pragma: no cover - 48-bit collision
            raise AssertionError("Two objects share a projection token; widen _TOKEN_HEX.")

    def trusted(self, object_id: str) -> bool:
        return self.id_policy == "all" or not is_generated_id(object_id)

    def _assign(self) -> None:
        keys: list[tuple[str, tuple]] = []

        def visit(object_id: str, anchor: str, path: tuple) -> None:
            obj = self.index.objects[object_id]
            if self.trusted(object_id):
                self.of[object_id] = self._token(obj, _digest("id", object_id))
                anchor, path = self.of[object_id], ()
            elif object_id == self.index.root.id:
                # There is one root, and nothing to tell it apart from: a fixed key.
                self.of[object_id] = self._token(obj, _digest("root"))
                anchor, path = self.of[object_id], ()
            elif self.strategy == "positional":
                keys.append((object_id, (anchor, path)))
            else:
                keys.append((object_id, (anchor, path, self._content(obj), get_tag(obj))))
            for attribute, value in get_composition_attributes(obj).items():
                members = value if isinstance(value, list) else [value] if value is not None else []
                for member in members:
                    visit(member.id, anchor, (*path, attribute, type(member).__name__))

        visit(self.index.root.id, "", ())
        seen: dict[str, int] = {}
        for object_id, key in keys:
            digest = _digest(self.strategy, key)
            ordinal = seen.get(digest, 0)
            seen[digest] = ordinal + 1
            self.of[object_id] = self._token(
                self.index.objects[object_id], _digest(digest, ordinal)
            )

    def _content(self, obj: PyDexpiBaseModel) -> tuple:
        """Data without caption attributes, and the trusted objects referenced -- non-recursive,
        so it cannot cycle. (The key adds the tag separately.)"""
        data = {
            name: _render(value, sort_lists=not is_order_significant(obj, name))
            for name, value in get_data_attributes(obj).items()
            if not _is_unset(value) and name not in _CAPTION_ATTRIBUTES
        }
        references = sorted(
            f"{name}:{target.id}"
            for name, value in get_reference_attributes(obj).items()
            for target in (value if isinstance(value, list) else [value])
            if isinstance(target, PyDexpiBaseModel) and self.trusted(target.id)
        )
        return (data, references)

    @staticmethod
    def _token(obj: PyDexpiBaseModel, digest: str) -> str:
        return f"{type(obj).__name__}@{digest[:_TOKEN_HEX]}"


# ---------------------------------------------------------------------------
# Blocks and sections
# ---------------------------------------------------------------------------


def _block(obj: PyDexpiBaseModel, tokens: dict[str, str], keep: Callable[[str], bool]) -> list[str]:
    header = tokens[obj.id]
    tag = get_tag(obj)
    lines = [f"{header}  {tag}" if tag else header]
    attributes: dict[str, str] = {}
    for name, value in get_data_attributes(obj).items():
        if not _is_unset(value):
            ordered = is_order_significant(obj, name)
            attributes[name] = f"{name} = {_render(value, sort_lists=not ordered)}"
    for name, value in get_composition_attributes(obj).items():
        if isinstance(value, list):
            members = [tokens[m.id] for m in value if keep(m.id)]
            if not members:
                continue
            if not is_order_significant(obj, name):
                members.sort()
            attributes[name] = f"{name} = [" + ", ".join(members) + "]"
        elif isinstance(value, PyDexpiBaseModel) and keep(value.id):
            attributes[name] = f"{name} = {tokens[value.id]}"
    for name, value in get_reference_attributes(obj).items():
        if isinstance(value, list):
            named = [tokens.get(t.id, f"?{t.id}") for t in value]
            # An ordered reference list (ListOfMaterialComponents.component) keeps its order and
            # its repeats; any other is the set of objects it names.
            targets = named if is_order_significant(obj, name) else sorted(set(named))
            if targets:
                attributes[name] = f"{name} -> [" + ", ".join(targets) + "]"
        elif isinstance(value, PyDexpiBaseModel):
            attributes[name] = f"{name} -> {tokens.get(value.id, f'?{value.id}')}"
    lines.extend(f"  {attributes[name]}" for name in sorted(attributes))
    return lines


def _ordered_children(obj: PyDexpiBaseModel, tokens: dict[str, str]) -> list[PyDexpiBaseModel]:
    """Children in projection order: attribute by attribute, each list in its projected order."""
    ordered: list[PyDexpiBaseModel] = []
    for name, value in sorted(get_composition_attributes(obj).items()):
        if isinstance(value, list):
            members = list(value)
            if not is_order_significant(obj, name):
                members.sort(key=lambda member: tokens[member.id])
            ordered.extend(members)
        elif isinstance(value, PyDexpiBaseModel):
            ordered.append(value)
    return ordered


def model_to_projection(
    model: PyDexpiBaseModel,
    *,
    id_policy: IdPolicy = "source",
    include_graphics: bool = True,
) -> str:
    """Render *model* as stable, reviewable text.

    Parameters
    ----------
    model : PyDexpiBaseModel
        Normally an ``EngineeringModel``.
    id_policy : {"source", "all"}, optional
        Which ids to trust across revisions (see the module docstring). ``"all"`` for models
        maintained as JSON with stable ids; ``"source"`` (the default) for
        models loaded from XML, whose unidentified objects are re-minted on every load.
    include_graphics : bool, optional
        Include the drawing (``diagram`` and ``shapeCatalogues``). On by default; leave it off
        for a review of the engineering content alone.

    Returns
    -------
    str
        The projection, ``\\n``-separated, ending in a newline.
    """
    return _project(model, id_policy, include_graphics, "anchored")


def _project(
    model: PyDexpiBaseModel, id_policy: IdPolicy, include_graphics: bool, strategy: str
) -> str:
    """``model_to_projection`` with the identity strategy selectable, for the measurement."""
    index = _ModelIndex(model)
    tokens = _Tokens(index, id_policy, strategy).of

    def path_of(object_id: str) -> list[str]:
        path: list[str] = []
        while object_id in index.location:
            location = index.location[object_id]
            path.append(location.attribute)
            object_id = location.parent_id
        return path[::-1]

    def domain(object_id: str) -> str:
        return domain_of_location(index.root, path_of(object_id), index.objects[object_id])

    def keep(object_id: str) -> bool:
        return include_graphics or domain(object_id) != "graphics"

    sections: dict[str, list[PyDexpiBaseModel]] = {}
    for top in _ordered_children(index.root, tokens):
        if not keep(top.id):
            continue
        attribute = index.location[top.id].attribute
        if attribute == "conceptualModel":
            sections.setdefault("conceptualModel", []).append(top)
            for member in _ordered_children(top, tokens):
                section = f"conceptualModel.{index.location[member.id].attribute}"
                sections.setdefault(section, []).append(member)
        else:
            sections.setdefault(attribute, []).append(top)

    def emit(obj: PyDexpiBaseModel, lines: list[str], descend: bool) -> None:
        lines.append("")
        lines.extend(_block(obj, tokens, keep))
        if descend:
            for child in _ordered_children(obj, tokens):
                if keep(child.id):
                    emit(child, lines, descend=True)

    lines = [f"# pydexpi-projection {PROJECTION_FORMAT_VERSION}", "", "## (document)"]
    emit(index.root, lines, descend=False)
    for name in sorted(sections, key=_section_order):
        lines += ["", f"## {name}"]
        members = sections[name]
        if name != "conceptualModel":
            owner = index.objects[index.location[members[0].id].parent_id]
            attribute = name.rsplit(".", 1)[-1]
            if not is_order_significant(owner, attribute):
                members = sorted(
                    members, key=lambda member: (type(member).__name__, tokens[member.id])
                )
        for member in members:
            emit(member, lines, descend=name != "conceptualModel")
    return "\n".join(lines) + "\n"


def _section_order(name: str) -> tuple[int, str]:
    """The document's conceptual content first, then the drawing."""
    if name == "conceptualModel":
        return (0, "")
    if name.startswith("conceptualModel."):
        return (1, name)
    return (2, name)
