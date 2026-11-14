"""Hashing and equality of whole models.

Two different notions live here, and they must not be confused:

- :func:`canonical_json_hash` / :func:`canonical_json_equality` compare models *ignoring the order*
  of their unordered lists. A list whose order carries meaning (``pydexpi.toolkits.list_order``:
  every list the specification declares ordered -- a vector's values, a template's component
  list, the drawing's geometry and z-order -- and a segment's flow order) is compared in order.
  The hash is Python's ``hash()`` of the canonical bytes, so it is salted per process: compare two
  values from the same run, never persist one.
- :func:`model_digest` fingerprints the *exact serialized state* of a model, list order included,
  as a SHA-256 digest that is the same in every process and on every machine. It is what an
  application stores to recognise a model state later.
"""

import hashlib
import json

from pydexpi.loaders.json_serializer import JsonSerializer
from pydexpi.pydexpi_classes.pydexpi_classes import EngineeringModel, PyDexpiBaseModel

__all__ = ["canonical_json_equality", "canonical_json_hash", "model_digest"]

# Neither hash covers the "dexpiVersion" a JSON document declares: the hashes describe the model,
# and a stored base_hash or a compared hash must not change because the files pyDEXPI writes
# began to declare their version. `model_digest` reads `model_to_dict`, which never carries it.
# Compact, like the exact serializer: the canonical bytes are compared, never read. Before
# CPython 3.13, ``json.dumps`` writes an indented document with its pure-Python encoder, which a
# line tracer such as coverage's slows by an order of magnitude: on 3.12 under coverage, a
# comparison of the reference P&ID took over a second indented, under a tenth of that compact.
#
# Nor does either follow how a JSON *document* spells a number that is not finite. Documents
# write a NaN or an infinity as a string; both serializers here keep the float, which
# `json.dumps` hashes as Python's bare ``NaN`` / ``Infinity``, as it always did. A `model_digest`
# is stored -- in an application's own records -- so the bytes it reads
# must never change: do not give `_exact_serializer` another spelling, and do not let it follow
# `JsonSerializer`'s default. The canonical bytes are never stored, and stay as they were too.
_json_loader = JsonSerializer(
    id_canonicalization=True, declare_version=False, indent=None, non_finite="constants"
)
_exact_serializer = JsonSerializer(indent=None, non_finite="constants")


def canonical_json_hash(model: EngineeringModel) -> int:
    """Calculate a hash of the model by first converting it to a canonical JSON
    string and then hashing that string. This is useful for comparing models
    for equality, as it ignores the order of the lists whose order carries
    nothing and keeps the order of the ones whose order does (see the module
    docstring).

    The value is Python's ``hash()`` of those bytes, which is salted per
    process (``PYTHONHASHSEED``). Compare two results from the same process;
    never store one or compare across processes -- use :func:`model_digest`
    for that.

    Args:
        model (EngineeringModel): The model to hash.

    Returns:
        int: The hash of the model, valid within the current process only.
    """
    json_str = _json_loader.export_to_bytes(model)
    return hash(json_str)


def canonical_json_equality(model1: EngineeringModel, model2: EngineeringModel):
    """Compare two models for equality by first converting them to canonical JSON
    strings and then comparing those strings. Unordered lists are compared as
    multisets, ordered ones in order (see the module docstring), so a swapped
    pair of fraction values or a reordered component list is a difference.

    Args:
        model1 (EngineeringModel): The first model to compare.
        model2 (EngineeringModel): The second model to compare.

    Returns:
        bool: True if the models are equal, False otherwise.
    """
    json_str1 = _json_loader.export_to_bytes(model1)
    json_str2 = _json_loader.export_to_bytes(model2)
    return json_str1 == json_str2


def model_digest(model: PyDexpiBaseModel) -> str:
    """Return the SHA-256 digest of *model*'s exact serialized state, order-sensitively.

    Two models digest equally only if they serialize identically: same ids, same values, **and
    the same order in every list**. This is deliberately stricter than semantic equality (``id_diff``
    reporting no changes) and than :func:`canonical_json_equality`, both of which ignore the order
    of unordered lists.
    Reordering a segment's items, or the z-order of drawn groups, changes the digest.

    Unlike :func:`canonical_json_hash`, the digest never involves Python's ``hash()``: it is the
    same in every process and on every machine, so it can be stored and compared later.

    The input is the pyDEXPI JSON serializer's representation of the model, written as JSON with
    sorted keys and no insignificant whitespace, encoded as UTF-8.

    Parameters
    ----------
    model : PyDexpiBaseModel
        A whole ``EngineeringModel``, or any subtree of one.

    Returns
    -------
    str
        The digest, as 64 lowercase hexadecimal digits.
    """
    document = _exact_serializer.model_to_dict(model)
    payload = json.dumps(document, sort_keys=True, separators=(",", ":"), ensure_ascii=False)
    return hashlib.sha256(payload.encode("utf-8")).hexdigest()
