"""Short, human-facing text taken from docstrings.

Catalogues shown to users and agents -- the MCP server's class listing, for one -- summarise
each entry by the first sentence of its docstring. This is that one rule.
"""

import re

_SENTENCE_END = re.compile(r"(?<=\.)\s+(?=[A-Z])")
_ISSUE_REFERENCE = re.compile(r"\s*\(#\d+\)")


def first_sentence(doc: str) -> str:
    """First sentence of the first paragraph of *doc*, without issue references.

    A sentence ends at a period followed by a capitalised word, so abbreviations such as "i.e."
    or "e.g." do not cut it short. Issue references such as ``(#405)`` are dropped: they matter
    to maintainers, not to someone choosing an entry.

    Parameters
    ----------
    doc : str
        A docstring, as returned by ``inspect.getdoc``.

    Returns
    -------
    str
        The sentence, on one line; empty if *doc* is empty.
    """
    paragraph = " ".join(doc.split("\n\n", maxsplit=1)[0].split())
    sentence = _SENTENCE_END.split(paragraph, maxsplit=1)[0]
    return _ISSUE_REFERENCE.sub("", sentence)
