"""Custom exceptions for the pyDEXPI Query API."""

from __future__ import annotations


class QueryError(Exception):
    """Base exception for all query-related errors."""


class ObjectNotFoundError(QueryError):
    """Raised when a requested object cannot be found.

    Parameters
    ----------
    identifier : str
        The identifier (ID or tag) that was not found.
    lookup_type : str
        The type of lookup that failed (e.g. ``"id"``, ``"tag"``).
    """

    def __init__(self, identifier: str, lookup_type: str = "id") -> None:
        self.identifier = identifier
        self.lookup_type = lookup_type
        super().__init__(f"No object found for {lookup_type}={identifier!r}")


class AmbiguousTagError(QueryError):
    """Raised when a ``get_*`` method finds multiple objects for a tag.

    Parameters
    ----------
    tag : str
        The ambiguous tag string.
    count : int
        Number of objects sharing that tag.
    """

    def __init__(self, tag: str, count: int) -> None:
        self.tag = tag
        self.count = count
        super().__init__(
            f"Tag {tag!r} is ambiguous: found {count} objects. "
            f"Use find_by_tag() to retrieve all matches."
        )
