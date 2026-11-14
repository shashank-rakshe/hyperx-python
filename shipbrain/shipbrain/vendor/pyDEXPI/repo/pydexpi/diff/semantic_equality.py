from collections.abc import Iterable
from typing import TypeVar

# TAG_ATTRIBUTES is re-exported: callers have long imported it from this module.
from pydexpi.diff.engine import TAG_ATTRIBUTE_ORDER, TAG_ATTRIBUTES, same_value  # noqa: F401
from pydexpi.pydexpi_classes.pydexpi_classes import PyDexpiBaseModel, Undefined
from pydexpi.toolkits.base_model_utils import get_data_attributes

T = TypeVar("T", bound=PyDexpiBaseModel)


def id_equality[T: PyDexpiBaseModel](object1: T, object2: T) -> bool:
    """Determine if two pyDEXPI objects are semantically equal based on id equality.

    Parameters
    ----------
    object1 : T
        The first pyDEXPI object to compare.
    object2 : T
        The second pyDEXPI object to compare.

    Returns
    -------
    bool
        True if the objects have the same id, False otherwise.
    """
    return object1.id == object2.id


class TagEquality:
    """A callable class for semantic equality based on tag attributes.

    Compares the first tag attribute, in :attr:`tag_attribute_order`, that is set on at least one
    of the two objects. Tag attributes are attributes like tagName, subTagName, lineNumber, etc.
    An attribute unset on both sides (``None`` or ``Undefined``) says nothing about identity and
    is skipped. If no tag attribute is set on either object, falls back to comparing all data
    attributes.

    NOTE: TagEquality does not work out-of-the-box for all pyDEXPI models,
    because it fails to distinguish objects without tags or data attributes that are not
    sufficiently descriptive, such as pipes or piping nodes.

    Attributes
    ----------
    tag_attributes : set of str
        The names of attributes that are considered tag attributes.
    tag_attribute_order : tuple of str
        The same names in the order they are tried. Deterministic: a set of strings would iterate
        in an order that depends on ``PYTHONHASHSEED``.
    """

    def __init__(self, tag_attributes: Iterable[str] | None = None):
        """Initialize TagEquality with optional tag attribute names.

        If none are provided, the default pyDEXPI tag attributes are used, in the order of
        ``engine.TAG_ATTRIBUTE_ORDER``.

        Parameters
        ----------
        tag_attributes : iterable of str, optional
            The names of attributes considered tag attributes. A sequence is tried in its own
            order; an unordered collection (a set) is tried in sorted order, so the result never
            depends on hash seeding. If None, the default attributes are used.
        """
        self.tag_attribute_order: tuple[str, ...] = TAG_ATTRIBUTE_ORDER
        if tag_attributes is not None:
            self.tag_attributes = tag_attributes

    @property
    def tag_attributes(self) -> set[str]:
        """The tag attribute names, as a set. Assigning to it also sets the order."""
        return set(self.tag_attribute_order)

    @tag_attributes.setter
    def tag_attributes(self, tag_attributes: Iterable[str]) -> None:
        if isinstance(tag_attributes, (set, frozenset)):
            self.tag_attribute_order = tuple(sorted(tag_attributes))
        else:
            self.tag_attribute_order = tuple(dict.fromkeys(tag_attributes))

    def __call__(self, object1: T, object2: T) -> bool:
        """Determine if two pyDEXPI objects are semantically equal based on tag attributes.

        Parameters
        ----------
        object1 : T
            The first pyDEXPI object to compare.
        object2 : T
            The second pyDEXPI object to compare.

        Returns
        -------
        bool
            True if the objects have the same tag or data attributes, False otherwise.
        """
        # Compare the first tag attribute that at least one of the two objects sets
        for attr in self.tag_attribute_order:
            if hasattr(object1, attr) and hasattr(object2, attr):
                try:
                    attr1 = getattr(object1, attr)
                    attr2 = getattr(object2, attr)
                except AttributeError:
                    continue  # If attribute access fails, skip to next attribute

                # Unset on both sides: this attribute cannot tell the objects apart. Returning
                # the comparison here made every pair of untagged objects of a class "equal".
                if _is_unset(attr1) and _is_unset(attr2):
                    continue

                # bool(): these are arbitrary attribute values, and `__eq__` is not obliged
                # to return a bool -- the annotation on this method says it does.
                return bool(attr1 == attr2)

        # Case no tag attribute is found, compare fallback
        return self._fallback_equality(object1, object2)

    def _fallback_equality(self, object1: T, object2: T) -> bool:
        """Fallback equality that compares objects without tag attributes.

        Compares all data attributes of two pyDEXPI objects for equality.
        However, this is not sufficient for typical pyDEXPI models, as many classes have data
        attributes that are not sufficiently descriptive, such as pipes or piping nodes.

        Subclasses of TagEquality can override this method to implement a more suitable fallback
        equality, or future versions of TagEquality could fix this."""
        # Get all attribute names from both objects
        attrs1 = get_data_attributes(object1)
        attrs2 = get_data_attributes(object2)

        # Check if the sets of attribute names are the same
        if set(attrs1) != set(attrs2):
            raise RuntimeError("Attribute sets differ between objects, should be identical.")

        # Compare values of all attributes. Two NaNs in the same place are the same value.
        for attr in attrs1:
            val1 = attrs1[attr]
            val2 = attrs2[attr]
            if not same_value(val1, val2):
                return False

        return True


def _is_unset(value: object) -> bool:
    """Return ``True`` for a tag value that carries no tag: ``None`` or ``Undefined``."""
    return value is None or isinstance(value, Undefined)
