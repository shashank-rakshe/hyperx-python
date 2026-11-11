"""Resolve flexible references to pyDEXPI domain objects.

The ``Resolver`` translates object instances, IDs, and tag strings
into concrete ``PyDexpiBaseModel`` instances using a ``ModelIndex``.
"""

from __future__ import annotations

from pydexpi.pydexpi_classes.pydexpi_classes import PyDexpiBaseModel
from pydexpi.query.errors import AmbiguousTagError, ObjectNotFoundError
from pydexpi.query.index import ModelIndex


class Resolver:
    """Resolve references by instance, ID, or tag.

    Resolution order for string references:

    1. Try ``by_id`` first (exact match).
    2. If not found, try ``by_tag``.
    3. If found in ``by_tag`` and exactly one match -> return it.
    4. If found in ``by_tag`` with multiple matches -> raise ``AmbiguousTagError``.
    5. If not found anywhere -> raise ``ObjectNotFoundError``.

    Parameters
    ----------
    index : ModelIndex
        The index to resolve references against.
    """

    def __init__(self, index: ModelIndex) -> None:
        self._index = index

    def resolve_one(self, ref: str | PyDexpiBaseModel) -> PyDexpiBaseModel:
        """Resolve a reference to exactly one domain object.

        Parameters
        ----------
        ref : str or PyDexpiBaseModel
            An object instance (returned as-is), an object ID, or a tag string.

        Returns
        -------
        PyDexpiBaseModel
            The resolved object.

        Raises
        ------
        ObjectNotFoundError
            If no matching object is found.
        AmbiguousTagError
            If a tag resolves to more than one object.
        """
        if isinstance(ref, PyDexpiBaseModel):
            return ref

        # 1. Try by ID
        obj = self._index.by_id.get(ref)
        if obj is not None:
            return obj

        # 2. Try by tag
        matches = self._index.by_tag.get(ref, [])
        if len(matches) == 1:
            return matches[0]
        if len(matches) > 1:
            raise AmbiguousTagError(ref, len(matches))

        raise ObjectNotFoundError(ref, lookup_type="id_or_tag")

    def resolve_many(self, ref: str | PyDexpiBaseModel) -> list[PyDexpiBaseModel]:
        """Resolve a reference and return all matching objects.

        Unlike ``resolve_one``, this never raises ``AmbiguousTagError``.

        Parameters
        ----------
        ref : str or PyDexpiBaseModel
            An object instance, an object ID, or a tag string.

        Returns
        -------
        list[PyDexpiBaseModel]
            Matching objects (may be empty).
        """
        if isinstance(ref, PyDexpiBaseModel):
            return [ref]

        # 1. Try by ID
        obj = self._index.by_id.get(ref)
        if obj is not None:
            return [obj]

        # 2. Try by tag (return all matches)
        return list(self._index.by_tag.get(ref, []))
