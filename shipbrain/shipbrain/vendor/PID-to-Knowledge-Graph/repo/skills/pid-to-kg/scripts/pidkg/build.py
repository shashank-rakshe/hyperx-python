"""Assemble page extractions into one knowledge graph for one plant."""

from __future__ import annotations

import datetime as _dt
import json
import re
from collections import defaultdict
from pathlib import Path
from typing import Any, Iterable, Optional

from pydantic import ValidationError

from . import __version__
from .isa import normalize_label, normalize_tag, parse_isa_tag
from .loops import derive_loops
from .models import (
    Edge,
    KnowledgeGraph,
    Node,
    PageExtraction,
    PlantInfo,
    ProcessRef,
    Provenance,
)
from .ontology import (
    ACTUATED_COMPONENT_KINDS,
    COMPONENT_DEXPI,
    EQUIPMENT_DEXPI,
)

TERMINAL_TYPES = {"Equipment", "Boundary"}


class BuildError(Exception):
    """Raised when extraction files cannot be loaded."""


def load_extractions(extract_dir: Path) -> list[PageExtraction]:
    files = sorted(Path(extract_dir).glob("page_*.json"))
    if not files:
        raise BuildError(f"no page_*.json files in {extract_dir}")
    pages: list[PageExtraction] = []
    errors: list[str] = []
    for f in files:
        try:
            data = json.loads(f.read_text(encoding="utf-8"))
            pages.append(PageExtraction.model_validate(data))
        except json.JSONDecodeError as e:
            errors.append(f"{f.name}: invalid JSON: {e}")
        except ValidationError as e:
            for err in e.errors():
                loc = ".".join(str(p) for p in err["loc"])
                errors.append(f"{f.name}: {loc}: {err['msg']}")
    if errors:
        raise BuildError("extraction files failed validation:\n  " + "\n  ".join(errors))
    pages.sort(key=lambda p: p.page)
    return pages


class GraphBuilder:
    def __init__(self, plant_id: str, plant_name: str, source_file: Optional[str] = None):
        self.plant = PlantInfo(id=plant_id, name=plant_name, source_file=source_file)
        self.nodes: dict[str, Node] = {}
        self.edges: list[Edge] = []
        self._edge_keys: set[tuple] = set()
        self.issues: list[dict[str, Any]] = []
        # page -> local id / normalized tag -> global node id
        self._local: dict[int, dict[str, str]] = defaultdict(dict)
        self._by_tag: dict[str, str] = {}
        # (page, line id) -> list of segment ids, and path item ids
        self._segments: dict[tuple[int, str], list[str]] = {}
        self._line_paths: dict[tuple[int, str], list[str]] = {}
        self._sheet_of_page: dict[int, str] = {}
        self._page_ids: dict[int, dict[str, str]] = defaultdict(dict)
        # (page, normalized tag) -> sheet suffix for tags reused by different items
        self.scopes: dict[tuple[int, str], str] = {}
        self._drawing_of_sheet: dict[str, Optional[str]] = {}

    # ------------------------------------------------------------------ utils

    def issue(self, severity: str, code: str, message: str, *, sheet: Optional[str] = None,
              page: Optional[int] = None, node: Optional[str] = None,
              bbox: Optional[list[float]] = None) -> None:
        self.issues.append({k: v for k, v in dict(
            severity=severity, code=code, message=message, sheet=sheet,
            page=page, node=node, bbox=bbox).items() if v is not None})

    def _upsert(self, node: Node) -> str:
        existing = self.nodes.get(node.id)
        if existing is None:
            self.nodes[node.id] = node
            return node.id
        if existing.type != node.type:
            # A valve tag drawn as a component on one sheet and as a bubble on
            # another is still one physical item: prefer Component.
            pair = {existing.type, node.type}
            if pair == {"Component", "Instrument"}:
                keep, other = (existing, node) if existing.type == "Component" else (node, existing)
                keep.attributes = {**other.attributes, **keep.attributes}
                keep.sheets = _merge_list(existing.sheets, node.sheets)
                keep.provenance = existing.provenance + node.provenance
                self.nodes[node.id] = keep
                return node.id
            self.issue("warning", "type_conflict",
                       f"'{node.id}' read as {existing.type} and as {node.type}; kept {existing.type}",
                       node=node.id)
        if existing.name and node.name and existing.type == node.type \
                and normalize_label(existing.name) != normalize_label(node.name) \
                and not _similar(existing.name, node.name):
            # Same tag, different description on different sheets: usually a
            # drawing inconsistency worth a human look. Both are kept.
            self.issue("warning", "name_conflict",
                       f"'{node.id}' is described as '{existing.name}' on {existing.sheets[0]} "
                       f"and as '{node.name}' on {node.sheets[0]}", node=node.id,
                       sheet=node.sheets[0])
            existing.attributes.setdefault("other_names", [])
            if node.name not in existing.attributes["other_names"]:
                existing.attributes["other_names"].append(node.name)
        existing.sheets = _merge_list(existing.sheets, node.sheets)
        existing.provenance.extend(node.provenance)
        existing.confidence = max(existing.confidence, node.confidence)
        for field in ("name", "kind", "status", "tag", "dexpi_class"):
            if getattr(existing, field) in (None, "", "other", "unknown") and getattr(node, field):
                setattr(existing, field, getattr(node, field))
        for k, v in node.attributes.items():
            if k not in existing.attributes or existing.attributes[k] in (None, "", "unknown"):
                existing.attributes[k] = v
        return node.id

    def _edge(self, source: str, target: str, etype: str, *, confidence: float = 1.0,
              derived: bool = False, sheet: Optional[str] = None, **attrs: Any) -> Optional[Edge]:
        if source == target:
            return None
        key = (source, target, etype, attrs.get("role"))
        if key in self._edge_keys:
            return None
        self._edge_keys.add(key)
        e = Edge(id=f"E{len(self.edges) + 1:05d}", source=source, target=target, type=etype,
                 confidence=round(confidence, 3), derived=derived, sheet=sheet,
                 attributes={k: v for k, v in attrs.items() if v not in (None, [], "")})
        self.edges.append(e)
        return e

    def _register(self, page: int, local_id: str, tag: Optional[str], gid: str) -> None:
        self._local[page][local_id] = gid
        nt = normalize_tag(tag)
        if nt:
            self._local[page].setdefault(nt, gid)
        nl = normalize_tag(local_id)
        if nl:
            self._local[page].setdefault(nl, gid)

    def resolve(self, page: int, ref: str) -> Optional[str]:
        """Resolve an item reference on a page: local id, then tag, then plant-wide tag."""
        if ref in self._local[page]:
            return self._local[page][ref]
        nt = normalize_tag(ref)
        if nt and nt in self._local[page]:
            return self._local[page][nt]
        if nt and nt in self._by_tag:
            return self._by_tag[nt]
        if nt and nt in self.nodes:
            return nt
        return None

    # ----------------------------------------------------------- phase 1: items

    def add_items(self, ext: PageExtraction) -> None:
        page = ext.page
        dn = ext.sheet.drawing_number
        sheet_id = f"SHEET:{normalize_tag(dn)}" if dn else f"SHEET:P{page:02d}"
        if sheet_id in self.nodes:
            sheet_id = f"{sheet_id}#P{page:02d}"
        self._sheet_of_page[page] = sheet_id
        self._drawing_of_sheet[sheet_id] = dn
        self.plant.sheets.append(sheet_id)
        self._upsert(Node(
            id=sheet_id, type="Sheet", label=dn or f"Page {page}", name=ext.sheet.title,
            sheets=[sheet_id], attributes=dict(
                page=page, drawing_number=dn, title=ext.sheet.title,
                revision=ext.sheet.revision, drawing_type=ext.sheet.drawing_type,
                issue_status=ext.sheet.issue_status,
                notes=ext.sheet.legend_notes, tiles_reviewed=ext.tiles_reviewed,
                unreadable=ext.unreadable)))

        def prov(item) -> list[Provenance]:
            return [Provenance(sheet=sheet_id, page=page, bbox=item.bbox, local_id=item.id)]

        for eq in ext.equipment:
            tag = normalize_tag(eq.tag)
            scope = self.scopes.get((page, tag)) if tag else None
            base = f"{tag}@{scope}" if scope else (tag or f"P{page:02d}.{eq.id}")
            gid = self._unique(page, base, eq.id, sheet_id, eq.bbox)
            kind = _slug(eq.kind)
            if kind not in EQUIPMENT_DEXPI:
                self.issue("info", "unknown_kind", f"equipment kind '{eq.kind}' not in vocabulary",
                           sheet=sheet_id, page=page, node=gid, bbox=eq.bbox)
            self._upsert(Node(
                id=gid, type="Equipment", label=tag or eq.name or kind, tag=tag, kind=kind,
                name=eq.name, status=eq.status, dexpi_class=EQUIPMENT_DEXPI.get(kind, "Equipment"),
                sheets=[sheet_id], confidence=eq.confidence, attributes=_clean(eq.attributes),
                provenance=prov(eq)))
            self._register(page, eq.id, eq.tag, gid)
            if tag and not scope:
                self._by_tag[tag] = gid

        for c in ext.components:
            tag = normalize_tag(c.tag)
            gid = self._unique(page, tag or f"P{page:02d}.{c.id}", c.id, sheet_id, c.bbox)
            kind = _slug(c.kind)
            if kind not in COMPONENT_DEXPI:
                self.issue("info", "unknown_kind", f"component kind '{c.kind}' not in vocabulary",
                           sheet=sheet_id, page=page, node=gid, bbox=c.bbox)
            attrs = _clean(dict(c.attributes, actuator=c.actuator, fail_position=c.fail_position,
                                normal_position=c.normal_position, size=c.size,
                                loop=normalize_tag(c.loop)))
            isa = parse_isa_tag(tag) if tag else None
            scope = self.scopes.get((page, tag)) if tag else None
            if scope:
                gid = self._unique(page, f"{tag}@{scope}", c.id, sheet_id, c.bbox)
            actuated = kind in ACTUATED_COMPONENT_KINDS or c.actuator not in (None, "manual", "none", "self")
            # Tagged manual/check valves (HV-103, CV-104) are not loop final elements, and
            # valve-type codes (KGV, BAV, PLV...) are not ISA loop tags at all.
            if isa and not _isa_valve_tag(isa):
                isa = None
            if isa and (actuated or kind == "relief_valve"):
                key = normalize_tag(c.loop) or isa.loop_key
                attrs.update(isa_letters=isa.letters, variable=isa.variable, role=isa.role,
                             loop_key=f"{key}@{scope}" if scope else key)
            elif c.loop:
                attrs.update(loop_key=normalize_tag(c.loop), role="final_element")
            self._upsert(Node(
                id=gid, type="Component", label=tag or (c.name if kind == "other" and c.name else _pretty(kind)),
                tag=tag, kind=kind,
                name=c.name, status=c.status, dexpi_class=COMPONENT_DEXPI.get(kind, "PipingComponent"),
                sheets=[sheet_id], confidence=c.confidence, attributes=attrs, provenance=prov(c)))
            self._register(page, c.id, c.tag, gid)
            if tag and not scope:
                self._by_tag[tag] = gid

        for ins in ext.instruments:
            if not ins.tag:
                gid = self._add_instrument(f"{ins.function}-0", page, sheet_id, node_id=f"P{page:02d}.{ins.id}",
                                           location=ins.location, name=ins.name, status=ins.status,
                                           confidence=ins.confidence, loop=ins.loop,
                                           attributes=ins.attributes, provenance=prov(ins),
                                           scoped=True, untagged=True)
                self._register(page, ins.id, None, gid)
                continue
            ntag = normalize_tag(ins.tag)
            scope = self.scopes.get((page, ntag))
            base = f"{ntag}@{scope}" if scope else ntag
            gid = self._unique(page, base, ins.id, sheet_id, ins.bbox)
            loop = ins.loop
            dup = gid[len(base):]  # '#2' for a second item with the same tag on this sheet
            if scope or dup:
                isa = parse_isa_tag(ntag)
                key = normalize_tag(loop) or (isa.loop_key if isa else None)
                loop = f"{key}{'@' + scope if scope else ''}{dup}" if key else None
            gid = self._add_instrument(ins.tag, page, sheet_id, node_id=gid, location=ins.location,
                                       name=ins.name, status=ins.status, confidence=ins.confidence,
                                       loop=loop, attributes=ins.attributes, provenance=prov(ins),
                                       scoped=bool(scope))
            self._register(page, ins.id, ins.tag, gid)

        for eq in ext.equipment:
            if eq.part_of:
                child, parent = self.resolve(page, eq.id), self.resolve(page, eq.part_of)
                if parent:
                    self._edge(child, parent, "PART_OF", confidence=eq.confidence, sheet=sheet_id)
                    self.nodes[child].attributes["part_of"] = parent
                else:
                    self.issue("error", "unresolved_reference",
                               f"equipment {eq.id} 'part_of': '{eq.part_of}' is not defined",
                               sheet=sheet_id, page=page)

        for o in ext.off_page_connectors:
            gid = f"P{page:02d}.{o.id}"
            self._upsert(Node(
                id=gid, type="OffPageConnector", label=o.name or o.other_item or o.id,
                tag=normalize_tag(o.tag), name=o.name, status=o.status, sheets=[sheet_id],
                confidence=o.confidence, provenance=prov(o),
                attributes=_clean(dict(o.attributes, direction=o.direction,
                                       other_drawing=o.other_drawing, other_item=o.other_item,
                                       line_number=o.line_number))))
            self._register(page, o.id, None, gid)

        for b in ext.boundaries:
            label = b.name or b.tag or b.id
            gid = f"BOUNDARY:{normalize_label(label)}"
            self._upsert(Node(
                id=gid, type="Boundary", label=label, name=b.name, status=b.status,
                sheets=[sheet_id], confidence=b.confidence, provenance=prov(b),
                attributes=_clean(dict(b.attributes, direction=b.direction))))
            self._register(page, b.id, None, gid)

    def _unique(self, page: int, gid: str, local_id: str, sheet_id: str, bbox) -> str:
        """Keep two different items that carry the same tag on one sheet apart."""
        seen = self._page_ids[page]
        base, n = gid, 1
        while gid in seen and seen[gid] != local_id:
            n += 1
            gid = f"{base}#{n}"
        if n > 1:
            self.issue("warning", "duplicate_tag",
                       f"tag '{base}' is used by more than one item on this sheet; the copy "
                       f"'{local_id}' was kept separate as '{gid}'", sheet=sheet_id, page=page,
                       node=gid, bbox=bbox)
        seen[gid] = local_id
        return gid

    def _add_instrument(self, tag: str, page: int, sheet_id: str, *, node_id: Optional[str] = None,
                        location: str = "unknown",
                        name: Optional[str] = None, status: Optional[str] = None,
                        confidence: float = 0.9, loop: Optional[str] = None,
                        attributes: Optional[dict] = None,
                        provenance: Optional[list[Provenance]] = None, scoped: bool = False,
                        untagged: bool = False) -> str:
        ntag = normalize_tag(tag)
        node_id = node_id or ntag
        isa = parse_isa_tag(ntag)
        attrs: dict[str, Any] = dict(attributes or {})
        attrs["location"] = location
        if isa:
            attrs.update(isa_letters=isa.letters, variable=isa.variable,
                         functions=isa.functions, role=isa.role,
                         loop_key=normalize_tag(loop) or (None if untagged else isa.loop_key))
        else:
            attrs.update(role="other", loop_key=normalize_tag(loop))
            self.issue("info", "non_isa_tag", f"instrument tag '{tag}' does not parse as ISA-5.1",
                       sheet=sheet_id, page=page, node=ntag)
        if untagged:
            attrs["untagged"] = True
            ntag = None
        label = f"{isa.letters} (untagged)" if untagged and isa else node_id
        self._upsert(Node(
            id=node_id, type="Instrument", label=label, tag=ntag, kind=attrs.get("role"),
            name=name, status=status, dexpi_class="ProcessInstrumentationFunction",
            sheets=[sheet_id], confidence=confidence, attributes=_clean(attrs),
            provenance=provenance or []))
        if not scoped:
            self._by_tag.setdefault(ntag, node_id)
        return node_id

    # ---------------------------------------------------- phase 2: connectivity

    def add_connectivity(self, ext: PageExtraction) -> None:
        page = ext.page
        sheet_id = self._sheet_of_page[page]
        view = "pfd" if ext.sheet.drawing_type == "pfd" else None

        # Expand every line into a chain of PipeSegment nodes first, so tees
        # can reference segments of other lines regardless of order.
        for line in ext.lines:
            key = (page, line.id)
            path_ids: list[str] = []
            for ref in line.path:
                gid = self.resolve(page, ref)
                if gid is None:
                    self.issue("error", "unresolved_reference",
                               f"line {line.id}: path item '{ref}' is not defined on this page",
                               sheet=sheet_id, page=page)
                    continue
                path_ids.append(gid)
            segs = []
            n = len(path_ids) + 1
            for k in range(1, n + 1):
                sid = f"P{page:02d}.{line.id}.{k}"
                label = line.line_number or f"{line.id}"
                self._upsert(Node(
                    id=sid, type="PipeSegment", label=f"{label} [{k}/{n}]" if n > 1 else label,
                    tag=normalize_tag(line.line_number), status=line.status, sheets=[sheet_id],
                    confidence=line.confidence, dexpi_class="PipingNetworkSegment",
                    attributes=_clean(dict(line_id=line.id, line_number=line.line_number,
                                           size=line.size, service=line.service,
                                           segment=k, segments=n)),
                    provenance=[Provenance(sheet=sheet_id, page=page, local_id=line.id)]))
                segs.append(sid)
            self._segments[key] = segs
            self._line_paths[key] = path_ids
            for i, item in enumerate(path_ids):
                fd = line.flow_direction
                self._edge(segs[i], item, "FLOWS_TO", confidence=line.confidence, sheet=sheet_id,
                           flow_direction=fd, line_number=line.line_number, drawing_type=view)
                self._edge(item, segs[i + 1], "FLOWS_TO", confidence=line.confidence, sheet=sheet_id,
                           flow_direction=fd, line_number=line.line_number, drawing_type=view)
                node = self.nodes[item]
                if node.type == "Instrument":
                    node.attributes["inline"] = True

        for line in ext.lines:
            segs = self._segments[(page, line.id)]
            src = self._resolve_endpoint(page, line.from_, sheet_id, f"line {line.id} 'from'")
            dst = self._resolve_endpoint(page, line.to, sheet_id, f"line {line.id} 'to'")
            fd = line.flow_direction
            if src:
                self._edge(src, segs[0], "FLOWS_TO", confidence=line.confidence, sheet=sheet_id,
                           flow_direction=fd, line_number=line.line_number, drawing_type=view)
            if dst:
                self._edge(segs[-1], dst, "FLOWS_TO", confidence=line.confidence, sheet=sheet_id,
                           flow_direction=fd, line_number=line.line_number, drawing_type=view)

        for ins in ext.instruments:
            gid = self.resolve(page, ins.id)
            if ins.measures is not None:
                target = self._resolve_endpoint(page, ins.measures, sheet_id,
                                                f"instrument {ins.tag} 'measures'")
                if target:
                    self._edge(gid, target, "MEASURES", confidence=ins.confidence, sheet=sheet_id)
            elif self.nodes[gid].attributes.get("inline"):
                upstream = [e.source for e in self.edges
                            if e.type == "FLOWS_TO" and e.target == gid
                            and self.nodes[e.source].type == "PipeSegment"]
                for u in upstream[:1]:
                    self._edge(gid, u, "MEASURES", confidence=ins.confidence, sheet=sheet_id,
                               inline=True)

        for sig in ext.signals:
            a = self._resolve_signal_end(page, sig.from_, sheet_id)
            b = self._resolve_signal_end(page, sig.to, sheet_id)
            if a and b:
                self._edge(a, b, "SIGNAL_TO", confidence=sig.confidence, sheet=sheet_id,
                           signal_type=sig.type, purpose=sig.purpose)

    def _resolve_endpoint(self, page: int, ep: Any, sheet_id: str, what: str) -> Optional[str]:
        if isinstance(ep, str):
            ep = ProcessRef(item=ep)
        if ep.item:
            gid = self.resolve(page, ep.item)
            if gid is None:
                self.issue("error", "unresolved_reference", f"{what}: '{ep.item}' is not defined",
                           sheet=sheet_id, page=page)
            return gid
        key = (page, ep.line)
        if key not in self._segments:
            self.issue("error", "unresolved_reference", f"{what}: line '{ep.line}' is not defined",
                       sheet=sheet_id, page=page)
            return None
        segs, path = self._segments[key], self._line_paths[key]
        if not ep.after:
            return segs[0]
        after = self.resolve(page, ep.after)
        if after in path:
            return segs[path.index(after) + 1]
        self.issue("warning", "tap_position", f"{what}: '{ep.after}' is not on line '{ep.line}'; "
                   "attached to the first segment", sheet=sheet_id, page=page)
        return segs[0]

    def _resolve_signal_end(self, page: int, ref: str, sheet_id: str) -> Optional[str]:
        gid = self.resolve(page, ref)
        if gid:
            return gid
        if parse_isa_tag(ref):
            # Signal lines nearly always end at instruments; a bubble referenced
            # only by a signal is created with reduced confidence and flagged.
            gid = self._add_instrument(ref, page, sheet_id, confidence=0.5,
                                       provenance=[Provenance(sheet=sheet_id, page=page)])
            self._register(page, ref, ref, gid)
            self.issue("info", "implicit_instrument",
                       f"'{ref}' appears only as a signal endpoint; created as an instrument",
                       sheet=sheet_id, page=page, node=gid)
            return gid
        self.issue("error", "unresolved_reference", f"signal endpoint '{ref}' is not defined",
                   sheet=sheet_id, page=page)
        return None

    # ------------------------------------------------- phase 3: cross-sheet links

    def link_off_page(self) -> None:
        """Pair outgoing and incoming off-page connectors across sheets, one to one.

        Every candidate pair is scored and pairs are accepted best-first. A
        drawing number that contradicts the other sheet rules a pair out, so a
        flag pointing at a drawing that was not supplied stays unmatched rather
        than being forced onto the nearest lookalike.
        """
        opcs = [n for n in self.nodes.values() if n.type == "OffPageConnector"]
        outs = [n for n in opcs if n.attributes.get("direction") == "out"]
        ins = [n for n in opcs if n.attributes.get("direction") == "in"]
        pairs = sorted(((self._opc_score(o, i), o.id, i.id) for o in outs for i in ins
                        if i.sheets[0] != o.sheets[0]), reverse=True)
        used: set[str] = set()
        for score, oid, iid in pairs:
            if score < 3 or oid in used or iid in used:
                continue
            used.update((oid, iid))
            o, i = self.nodes[oid], self.nodes[iid]
            o_dn, i_dn = self._drawing_of_sheet.get(o.sheets[0]), self._drawing_of_sheet.get(i.sheets[0])
            if (o.attributes.get("other_drawing") and not _same_drawing(o.attributes["other_drawing"], i_dn)) or                     (i.attributes.get("other_drawing") and not _same_drawing(i.attributes["other_drawing"], o_dn)):
                self.issue("warning", "off_page_reference_mismatch",
                           f"'{o.label}' ({o_dn}) and '{i.label}' ({i_dn}) were paired by line number "
                           f"{o.attributes.get('line_number')}, but their flags name other drawings "
                           f"({o.attributes.get('other_drawing')} / {i.attributes.get('other_drawing')})",
                           sheet=o.sheets[0], node=oid, bbox=_first_bbox(o))
            self._edge(oid, iid, "FLOWS_TO", confidence=min(o.confidence, 0.9),
                       off_page=True, match_score=round(score, 2))
            o.attributes["linked_to"] = iid
            self.nodes[iid].attributes["linked_from"] = oid
        for n in outs + ins:
            if n.id in used or self._link_opc_by_item(n):
                continue
            way = "to" if n.attributes.get("direction") == "out" else "from"
            self.issue("warning", "unmatched_off_page",
                       f"off-page connector '{n.label}' ({way} {n.attributes.get('other_drawing')}) "
                       "has no matching connector or item", sheet=n.sheets[0], node=n.id,
                       bbox=_first_bbox(n))

    def _opc_score(self, out: Node, inn: Node) -> float:
        out_dn = self._drawing_of_sheet.get(out.sheets[0])
        in_dn = self._drawing_of_sheet.get(inn.sheets[0])
        out_to, in_from = out.attributes.get("other_drawing"), inn.attributes.get("other_drawing")
        lo, li = out.attributes.get("line_number"), inn.attributes.get("line_number")
        same_line = bool(lo and li and normalize_tag(lo) == normalize_tag(li))
        # A flag naming a different drawing than the candidate's sheet is a
        # contradiction, unless the line numbers agree exactly (drawing
        # references on flags are a common drafting error; line numbers are not).
        contradiction = (out_to and in_dn and not _same_drawing(out_to, in_dn)) or                         (in_from and out_dn and not _same_drawing(in_from, out_dn))
        if contradiction and not same_line:
            return float("-inf")
        score = -1.0 if contradiction else 0.0
        if out_to and _same_drawing(out_to, in_dn):
            score += 3
        if in_from and _same_drawing(in_from, out_dn):
            score += 3
        if lo and li:
            score += 4 if same_line else -1
        score += 2 * _jaccard(_tokens(out.label, out.attributes.get("other_item")),
                              _tokens(inn.label, inn.attributes.get("other_item")))
        return score

    def _link_opc_by_item(self, opc: Node) -> bool:
        target = normalize_tag(opc.attributes.get("other_item"))
        gid = self._by_tag.get(target) if target else None
        if not gid or self.nodes[gid].type not in ("Equipment", "Component", "Instrument"):
            return False
        if opc.attributes.get("direction") == "out":
            self._edge(opc.id, gid, "FLOWS_TO", confidence=0.7, derived=True, off_page=True,
                       linked_by="other_item")
        else:
            self._edge(gid, opc.id, "FLOWS_TO", confidence=0.7, derived=True, off_page=True,
                       linked_by="other_item")
        opc.attributes["linked_item"] = gid
        return True

    # ---------------------------------------------------------- phase 4: derive

    def inherit_measurements(self) -> None:
        """Locate transmitters that read a primary element (FIT reading FE).

        An instrument with no process location of its own takes the location of
        an element that signals to it, or failing that, of an element/sensor in
        the same ISA loop that is located (bubbles drawn touching, no line).
        """
        located: dict[str, str] = {}
        for nid, n in self.nodes.items():
            if n.type == "Instrument" and n.attributes.get("inline"):
                located[nid] = nid  # an in-line element is itself the location
        for e in self.edges:
            if e.type == "MEASURES":
                located.setdefault(e.source, e.target)
        sig_in: dict[str, list[str]] = defaultdict(list)
        for e in self.edges:
            if e.type == "SIGNAL_TO":
                sig_in[e.target].append(e.source)
        by_loop: dict[str, list[str]] = defaultdict(list)
        for nid, n in self.nodes.items():
            if n.type == "Instrument" and n.attributes.get("loop_key"):
                by_loop[n.attributes["loop_key"]].append(nid)

        for nid, n in list(self.nodes.items()):
            if n.type != "Instrument" or nid in located:
                continue
            if n.attributes.get("role") not in ("transmitter", "switch", "gauge", "indicator",
                                                 "recorder", "totalizer", "element"):
                continue
            # Transmitters are field devices whatever bubble they are drawn with; other
            # read-outs must be field mounted to inherit a process location.
            if n.attributes.get("role") != "transmitter" and                     n.attributes.get("location") not in ("field", "unknown", "local_panel"):
                continue
            # A located field device wired into this one (FE -> FIT, DP -> DPT, AE -> AIT).
            source = next((s for s in sig_in.get(nid, []) if s in located
                           and self.nodes[s].type == "Instrument"
                           and self.nodes[s].attributes.get("location") in ("field", "unknown")), None)
            how = "signal from primary element"
            if source is None:
                source = next((m for m in by_loop.get(n.attributes.get("loop_key"), [])
                               if m != nid and m in located
                               and self.nodes[m].attributes.get("role") == "element"), None)
                how = "same loop as primary element"
            if source is not None:
                self._edge(nid, located[source], "MEASURES", derived=True,
                           confidence=min(n.confidence, self.nodes[source].confidence),
                           via=source, inferred_from=how)

    def derive_feeds(self) -> None:
        """Collapse pipes/fittings into equipment-to-equipment FEEDS edges.

        When a drawing set mixes a PFD with P&IDs, equipment-level flow comes
        from the P&IDs. PFD connections are added only where the P&IDs do not
        already connect the two items, with untagged PFD-only equipment (e.g.
        unnumbered pumps) treated as pass-through, and are marked view='pfd'.
        """
        flows = [e for e in self.edges if e.type == "FLOWS_TO"]
        has_pid = any(n.attributes.get("drawing_type") != "pfd"
                      for n in self.nodes.values() if n.type == "Sheet")
        pfd_sheets = {n.id for n in self.nodes.values()
                      if n.type == "Sheet" and n.attributes.get("drawing_type") == "pfd"}
        if not has_pid or not pfd_sheets:
            self._feeds_from(flows, lambda n: n.type in TERMINAL_TYPES)
            return
        detail = [e for e in flows if e.attributes.get("drawing_type") != "pfd"]
        self._feeds_from(detail, lambda n: n.type in TERMINAL_TYPES)
        reach: dict[str, set[str]] = defaultdict(set)
        adj: dict[str, list[str]] = defaultdict(list)
        for e in self.edges:
            if e.type == "FEEDS":
                adj[e.source].append(e.target)

        def reachable(a: str) -> set[str]:
            if a not in reach:
                seen, stack = set(), list(adj[a])
                while stack:
                    x = stack.pop()
                    if x not in seen:
                        seen.add(x)
                        stack.extend(adj[x])
                reach[a] = seen
            return reach[a]

        def pfd_terminal(n: Node) -> bool:
            pfd_only_untagged = n.type == "Equipment" and not n.tag and set(n.sheets) <= pfd_sheets
            return n.type in TERMINAL_TYPES and not pfd_only_untagged

        pfd = [e for e in flows if e.attributes.get("drawing_type") == "pfd"]
        self._feeds_from(pfd, pfd_terminal, view="pfd",
                         keep=lambda a, b: b not in reachable(a))

    def _feeds_from(self, flows: list[Edge], is_terminal, view: Optional[str] = None,
                    keep=lambda a, b: True) -> None:
        out_adj: dict[str, list[str]] = defaultdict(list)
        for e in flows:
            out_adj[e.source].append(e.target)
        for start in [n.id for n in self.nodes.values() if is_terminal(n)]:
            seen = {start}
            stack: list[tuple[str, list[str]]] = [(t, [t]) for t in out_adj[start]]
            while stack:
                node_id, via = stack.pop()
                if node_id in seen:
                    continue
                seen.add(node_id)
                node = self.nodes[node_id]
                if is_terminal(node):
                    if keep(start, node_id):
                        lines = _merge_list([], [self.nodes[v].attributes.get("line_number")
                                                 for v in via[:-1] if self.nodes[v].type == "PipeSegment"])
                        comps = [self.nodes[v].label for v in via[:-1]
                                 if self.nodes[v].type in ("Component", "Instrument", "Equipment")]
                        off_page = any(self.nodes[v].type == "OffPageConnector" for v in via)
                        self._edge(start, node_id, "FEEDS", derived=True,
                                   via_lines=[l for l in lines if l], via_items=comps,
                                   off_page=off_page or None, view=view)
                    continue
                for t in out_adj[node_id]:
                    stack.append((t, via + [t]))

    def finalize(self) -> KnowledgeGraph:
        plant_node = Node(id=f"PLANT:{self.plant.id}", type="Plant", label=self.plant.name,
                          name=self.plant.name, attributes=_clean({"source_file": self.plant.source_file}))
        self._upsert(plant_node)
        for sid in self.plant.sheets:
            self._edge(sid, plant_node.id, "PART_OF")
        stats = _stats(self.nodes.values(), self.edges, self.issues)
        return KnowledgeGraph(
            generator=f"pid-to-kg {__version__}",
            generated_at=_dt.datetime.now(_dt.timezone.utc).replace(microsecond=0).isoformat(),
            plant=self.plant, nodes=list(self.nodes.values()), edges=self.edges,
            stats=stats, issues=self.issues)


def build_graph(pages: Iterable[PageExtraction], plant_id: str, plant_name: str,
                source_file: Optional[str] = None) -> KnowledgeGraph:
    pages = list(pages)
    b = GraphBuilder(plant_id, plant_name, source_file)
    b.scopes = tag_scopes(pages)
    for (page, tag), scope in sorted(b.scopes.items()):
        b.issue("info", "tag_reused",
                f"'{tag}' identifies different items on different sheets; kept as "
                f"'{tag}@{scope}'", page=page, node=f"{tag}@{scope}")
    # P&ID sheets first, so their names and kinds win over a PFD's summary view.
    for p in sorted(pages, key=lambda p: (p.sheet.drawing_type == "pfd", p.page)):
        b.add_items(p)
    for p in pages:
        b.add_connectivity(p)
    b.link_off_page()
    b.inherit_measurements()
    derive_loops(b)
    b.derive_feeds()
    return b.finalize()


def tag_scopes(pages: list[PageExtraction]) -> dict[tuple[int, str], str]:
    """Find instrument tags that are reused for different instruments on different sheets.

    ISA tags should be unique plant-wide, and an instrument drawn on two sheets
    must merge into one node. Some drawing sets, however, restart numbering
    per unit. Instruments are compared by loop group: if the same loop group
    senses disjoint process locations on two sheets (different equipment or
    different pipe runs), every tag of that group on those sheets is scoped to
    its sheet. Returns {(page, normalized tag): sheet suffix}.
    """
    signature: dict[str, dict[int, set[str]]] = defaultdict(lambda: defaultdict(set))
    members: dict[str, dict[int, list[str]]] = defaultdict(lambda: defaultdict(list))
    suffix: dict[int, str] = {}
    for p in pages:
        suffix[p.page] = normalize_tag(p.sheet.drawing_number) or f"P{p.page:02d}"
        tags = {i.id: normalize_tag(i.tag) for grp in (p.equipment, p.components, p.instruments)
                for i in grp if i.tag}
        lines = {l.id: l for l in p.lines}

        def ends(line) -> set[str]:
            out = set()
            for ep in (line.from_, line.to):
                if isinstance(ep, str) and ep in tags:
                    out.add(tags[ep])
            return out

        def where(local_id: str, ref) -> set[str]:
            found: set[str] = set()
            if ref is not None and ref.item:
                found.add(tags.get(ref.item) or normalize_tag(ref.item))
            elif ref is not None and ref.line in lines:
                found |= ends(lines[ref.line])
            for l in p.lines:
                if local_id in l.path:
                    found |= ends(l)
            found.discard(None)
            return found

        for ins in p.instruments:
            if not ins.tag:
                continue
            t = normalize_tag(ins.tag)
            isa = parse_isa_tag(t)
            key = normalize_tag(ins.loop) or (isa.loop_key if isa else t)
            members[key][p.page].append(t)
            signature[key][p.page] |= where(ins.id, ins.measures)
        for c in p.components:
            t = normalize_tag(c.tag)
            isa = parse_isa_tag(t) if t else None
            actuated = _slug(c.kind) in ACTUATED_COMPONENT_KINDS or c.actuator not in (None, "manual", "none", "self")
            if isa and actuated:
                key = normalize_tag(c.loop) or isa.loop_key
                members[key][p.page].append(t)
                signature[key][p.page] |= where(c.id, None)

    # Equipment: the same printed tag on two P&ID sheets is one item unless the
    # equipment it connects to is disjoint AND neither sheet points at the
    # other. PFD sheets are a summary view of the same plant and never split.
    eq_sig: dict[str, dict[int, set[str]]] = defaultdict(lambda: defaultdict(set))
    refs: dict[int, set[str]] = defaultdict(set)
    for p in pages:
        if p.sheet.drawing_type == "pfd":
            continue
        terminal: dict[str, str] = {}
        for grp in (p.equipment, p.boundaries):
            for i in grp:
                terminal[i.id] = normalize_tag(i.tag) or normalize_label(i.name or i.id)
        for o in p.off_page_connectors:
            terminal[o.id] = normalize_tag(o.other_item) or normalize_label(o.name or o.id)
            if o.other_drawing:
                refs[p.page].add(normalize_tag(o.other_drawing))
        adj: dict[str, set[str]] = defaultdict(set)
        for l in p.lines:
            ends = []
            for ep in (l.from_, l.to):
                if isinstance(ep, str):
                    ends.append(ep)
                elif ep.item:
                    ends.append(ep.item)
                else:
                    ends.append("line:" + ep.line)
            chain = [ends[0]] + list(l.path) + [ends[1]]
            for a, b in zip(chain, chain[1:]):
                adj[a].add(b)
                adj[b].add(a)
            for x in chain:  # a tee onto this line reaches everything on it
                adj["line:" + l.id].add(x)
                adj[x].add("line:" + l.id)
        for e in p.equipment:
            tag = normalize_tag(e.tag)
            if not tag:
                continue
            seen, stack = {e.id}, list(adj[e.id])
            while stack:
                x = stack.pop()
                if x in seen:
                    continue
                seen.add(x)
                if x in terminal:
                    eq_sig[tag][p.page].add(terminal[x])
                    continue
                stack.extend(adj[x])
    eq_tags: dict[int, set[str]] = defaultdict(set)
    for p in pages:
        eq_tags[p.page] = {normalize_tag(e.tag) for e in p.equipment if e.tag}
    scopes: dict[tuple[int, str], str] = {}
    for tag, per_page in eq_sig.items():
        located = [pg for pg, s in per_page.items() if s]
        for a in located:
            for b in located:
                # Tags present on both sheets are themselves in question (a
                # sibling pump with the same reused tag), so they are not evidence.
                shared = eq_tags[a] & eq_tags[b]
                if a >= b or not (per_page[a] - shared).isdisjoint(per_page[b] - shared):
                    continue
                if suffix[b] in refs[a] or suffix[a] in refs[b]:
                    continue
                scopes[(a, tag)] = suffix[a]
                scopes[(b, tag)] = suffix[b]
    for key, per_page in signature.items():
        located = [pg for pg, s in per_page.items() if s]
        clash = {pg for a in located for b in located if a != b
                 and per_page[a].isdisjoint(per_page[b]) for pg in (a, b)}
        for pg in clash:
            for t in members[key][pg]:
                scopes[(pg, t)] = suffix[pg]
    return scopes


# ------------------------------------------------------------------- helpers


def _slug(s: str) -> str:
    return re.sub(r"[^a-z0-9]+", "_", (s or "other").lower()).strip("_") or "other"


def _pretty(kind: str) -> str:
    return kind.replace("_", " ")


def _clean(d: dict) -> dict:
    return {k: v for k, v in d.items() if v not in (None, "", [], {})}


def _merge_list(a: list, b: Iterable) -> list:
    out = list(a)
    for x in b:
        if x not in out:
            out.append(x)
    return out


def _first_bbox(n: Node) -> Optional[list[float]]:
    return next((p.bbox for p in n.provenance if p.bbox), None)


def _same_drawing(a: Optional[str], b: Optional[str]) -> bool:
    if not a or not b:
        return False
    na, nb = normalize_tag(a), normalize_tag(b)
    if na == nb or na.endswith(nb) or nb.endswith(na):
        return True
    # A trailing revision or sheet suffix: 'D-007-0' is drawing 'D-007'.
    return na.startswith(nb + "-") or nb.startswith(na + "-")


def _tokens(*parts: Optional[str]) -> set[str]:
    words: set[str] = set()
    for p in parts:
        words.update(w for w in normalize_label(p).split() if len(w) > 1
                     and w not in {"TO", "FROM", "DWG", "THE", "AND"})
    return words


_ISA_VALVE_FUNCTIONS = {"V", "CV", "SV", "Y", "Z", "SE", "SO", "SC", "Q"}


def _isa_valve_tag(isa) -> bool:
    """FV, LCV, PSV, XV, HV... rather than a valve-type code such as KGV or BAV."""
    if isa.role == "relief_device":
        return True
    rest = isa.letters[len(isa.variable_code):]
    return rest in _ISA_VALVE_FUNCTIONS or rest.endswith("CV")


def _similar(a: str, b: str) -> bool:
    """Descriptions that share most of their words ('SUMP' vs 'WTP SUMP')."""
    ta, tb = _tokens(a), _tokens(b)
    return bool(ta and tb) and (ta <= tb or tb <= ta or _jaccard(ta, tb) >= 0.5)


def _jaccard(a: set, b: set) -> float:
    return len(a & b) / len(a | b) if a and b else 0.0


def _stats(nodes: Iterable[Node], edges: list[Edge], issues: list[dict]) -> dict[str, Any]:
    nodes = list(nodes)
    by_type: dict[str, int] = defaultdict(int)
    for n in nodes:
        by_type[n.type] += 1
    e_type: dict[str, int] = defaultdict(int)
    for e in edges:
        e_type[e.type] += 1
    loops: dict[str, int] = defaultdict(int)
    for n in nodes:
        if n.type == "ControlLoop":
            loops[n.kind or "unknown"] += 1
    sev: dict[str, int] = defaultdict(int)
    for i in issues:
        sev[i["severity"]] += 1
    return {"nodes": len(nodes), "edges": len(edges), "nodes_by_type": dict(sorted(by_type.items())),
            "edges_by_type": dict(sorted(e_type.items())), "loops_by_type": dict(sorted(loops.items())),
            "issues_by_severity": dict(sev)}
