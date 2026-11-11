"""How validation messages name the objects they refer to.

:func:`referenced_object_name` lives in :mod:`pydexpi.toolkits.display_name`, beside the display
names it builds on, since messages outside validation use it too. It is re-exported here so
the rules that import it from this module keep working.
"""

from pydexpi.toolkits.display_name import referenced_object_name

__all__ = ["referenced_object_name"]
