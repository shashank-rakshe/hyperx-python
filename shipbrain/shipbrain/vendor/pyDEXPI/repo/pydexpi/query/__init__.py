"""Query API for pyDEXPI models.

Provides a developer-friendly query layer on top of the existing
pyDEXPI object model and NetworkX graph functionality.
"""

from pydexpi.query.engine import QueryEngine
from pydexpi.query.errors import (
    AmbiguousTagError,
    ObjectNotFoundError,
    QueryError,
)
from pydexpi.query.index import ModelIndex
from pydexpi.query.resolver import Resolver
from pydexpi.query.results import (
    ConnectionResult,
    FreePort,
    NodeState,
    ObjectDescription,
    PathResult,
    SearchMatch,
    SearchResultPage,
)
from pydexpi.query.search import SearchField, search_objects
