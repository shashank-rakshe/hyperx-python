"""How an exported node is identified, in one place.

Neo4j namespaces node identity as ``[<id_namespace>:]<graph_level>:<dexpi id>`` with the raw id
kept alongside as ``sourceId``, so several abstraction levels -- and several independent models --
can share one database. GraphML can do the same on request.

The composition lives here rather than in either exporter because the point is that the two
agree *by construction*. A second copy of the rule, however carefully written, is a second thing to
keep in step, and the ``:`` reservation below is what makes the composite parseable at all.

``:`` is reserved as the separator and rejected in both the namespace and the DEXPI id. pyDEXPI
never invents a namespace: it is caller-owned, because only the caller knows which models are
independent.
"""


def validate_id_namespace(id_namespace: str | None) -> None:
    """Reject namespaces that would corrupt or ambiguate the composite ``:ID``.

    ``None`` means "no model namespace" and is always valid.  Anything else must
    be a non-empty string without surrounding whitespace and without ``:``.
    Nothing is silently normalized: stripping or rewriting an identifier could
    merge two namespaces the caller meant to keep apart.
    """
    if id_namespace is None:
        return
    if not isinstance(id_namespace, str):
        raise TypeError(
            f"id_namespace must be a string or None, got {type(id_namespace).__name__}."
        )
    if not id_namespace.strip():
        raise ValueError(
            "id_namespace must not be empty or whitespace-only; pass None for no namespace."
        )
    if id_namespace != id_namespace.strip():
        raise ValueError(
            f"id_namespace {id_namespace!r} has leading or trailing whitespace; "
            f"it is rejected rather than stripped so that no two distinct "
            f"namespaces can silently merge."
        )
    if ":" in id_namespace:
        raise ValueError(
            f"id_namespace {id_namespace!r} contains ':', which is reserved as "
            f"the separator in the composite Neo4j :ID."
        )


def namespaced(node_id: str, graph_level: str, id_namespace: str | None = None) -> str:
    """Compose the Neo4j ``:ID`` — ``[<id_namespace>:]<graph_level>:<node_id>``.

    The level is mandatory and there is deliberately no fallback to the bare
    id: an un-namespaced id is exactly the cross-level collision this scheme
    exists to remove.  The namespace is caller-owned; pyDEXPI never invents one.

    ``:`` is reserved as the composite separator, so it must not appear in any
    part.  The namespace is checked once up front by
    :func:`validate_id_namespace`; node ids are checked here, because the
    model types them as arbitrary ``str`` — an id containing ``:`` would let
    two different (namespace, level, id) triples compose to the same ``:ID``.
    """
    if ":" in node_id:
        raise ValueError(
            f"DEXPI id {node_id!r} contains ':', which is reserved as the "
            f"separator in the composite Neo4j :ID. Rename the object id to "
            f"export it to Neo4j."
        )
    if id_namespace is not None:
        return f"{id_namespace}:{graph_level}:{node_id}"
    return f"{graph_level}:{node_id}"
