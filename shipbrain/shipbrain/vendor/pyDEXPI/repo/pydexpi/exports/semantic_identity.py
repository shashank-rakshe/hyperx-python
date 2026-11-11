"""Identity and diagnostics shared by semantic tables and relationship exports."""

from collections import Counter

import pandas as pd

from pydexpi.pydexpi_classes import PyDexpiBaseModel
from pydexpi.toolkits.base_model_utils import is_generated_id
from pydexpi.toolkits.model_toolkit import get_all_instances_in_model

IDENTITY_COLUMNS = ("id", "dexpi_class", "id_kind", "identity_diagnostic")


class IdentityContext:
    """Describe model identities without inventing source IDs or discarding duplicates."""

    def __init__(self, model: PyDexpiBaseModel):
        self.objects = get_all_instances_in_model(model)
        self.object_keys = {id(obj) for obj in self.objects}
        self.counts = Counter(self.object_id(obj) for obj in self.objects)

    @staticmethod
    def object_id(obj: PyDexpiBaseModel | None) -> str | None:
        """Return the unchanged model ID, or null for an absent/blank ID."""
        value = getattr(obj, "id", None)
        return value if isinstance(value, str) and value.strip() else None

    def record(self, obj: PyDexpiBaseModel) -> dict:
        """Return stable machine columns; UUID shape alone is not proof of provenance."""
        value = self.object_id(obj)
        return {
            "id": value,
            "dexpi_class": type(obj).__name__,
            "id_kind": "missing"
            if value is None
            else ("generated_shape" if is_generated_id(value) else "model"),
            "identity_diagnostic": "missing_id"
            if value is None
            else ("duplicate_id" if self.counts[value] > 1 else None),
        }

    def reference(self, obj: PyDexpiBaseModel | None, role: str) -> dict:
        """Describe a reference, distinguishing absent targets from detached objects."""
        value = self.object_id(obj)
        if obj is None:
            status = "missing"
        elif id(obj) not in self.object_keys:
            status = "outside_model"
        elif value is None:
            status = "missing_id"
        elif self.counts[value] > 1:
            status = "duplicate_id"
        else:
            status = "resolved"
        return {f"{role}_id": value, f"{role}_status": status}


def semantic_frame(rows: list[dict], columns: tuple[str, ...] = ()) -> pd.DataFrame:
    """Keep the machine schema even for empty or entirely nullable tables."""
    df = pd.DataFrame(rows)
    for column in (*IDENTITY_COLUMNS, *columns):
        if column not in df:
            df[column] = pd.Series([None] * len(df), dtype=object)
    df.attrs["stable_columns"] = (*IDENTITY_COLUMNS, *columns)
    return df
