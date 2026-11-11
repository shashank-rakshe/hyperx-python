"""Preparer for PIDQA — Q&A over Piping & Instrumentation Diagrams (CC0).

Source: https://github.com/mgupta70/PIDQA — four CSVs of QA pairs (Simple Counting,
Spatial Counting, Spatial Connections, Value-Based), each keyed by ``P&ID_number``
and carrying a Cypher query for graph-based reasoning. The underlying P&ID images
live in the separate Dataset-P&ID collection, so PIDQA itself contributes QA pairs,
not symbol geometry.

Conversion: one :class:`cir.DrawingSet` per P&ID sheet (a single P&ID/process
``diagram`` view), with all of that sheet's QA pairs stored under
``metadata["qa_pairs"]`` for later L4 (agent) training/evaluation.
"""

from __future__ import annotations

import csv
from collections import defaultdict
from collections.abc import Iterator, Mapping
from typing import Any, ClassVar

from cir import Discipline, DrawingSet, Sheet, SourceFile, View, ViewType

from .base import DatasetPreparer


class PIDQAPreparer(DatasetPreparer):
    """Download + convert the PIDQA dataset into CIR."""

    name = "PIDQA"
    repo_url = "https://github.com/mgupta70/PIDQA.git"

    # category -> path within the repo
    _CSVS: ClassVar[dict[str, str]] = {
        "simple_counting": "Simple Counting/simple_counting.csv",
        "spatial_counting": "Spatial Counting/spatial_counting.csv",
        "spatial_connections": "Spatial Connections/spatial_connectivity.csv",
        "value_based": "Value/value_based.csv",
    }

    def download(self) -> None:
        self.git_clone(self.repo_url)

    def convert(self) -> Iterator[DrawingSet]:
        by_sheet: dict[str, list[dict[str, Any]]] = defaultdict(list)

        for category, rel_path in self._CSVS.items():
            path = self.raw_dir / rel_path
            if not path.exists():
                continue
            with path.open(newline="", encoding="utf-8") as handle:
                for row in csv.DictReader(handle):
                    pid = (row.get("P&ID_number") or "").strip()
                    if not pid:
                        continue
                    by_sheet[pid].append(self._qa_record(category, row))

        # numeric-friendly ordering of sheet ids ("0", "1", ..., "10", ...)
        for pid in sorted(by_sheet, key=lambda p: (len(p), p)):
            yield self._build_drawing_set(pid, by_sheet[pid])

    @staticmethod
    def _qa_record(category: str, row: Mapping[str, str | None]) -> dict[str, Any]:
        symbols = [
            value for key, value in row.items() if key and key.startswith("Symbol") and value
        ]
        record: dict[str, Any] = {
            "category": category,
            "q_id": row.get("Q_id"),
            "type": row.get("Type"),
            "question": row.get("Question"),
            "answer": row.get("GT"),
            "cypher": " ".join((row.get("Cypher") or "").split()),
            "symbol_classes": symbols,
        }
        if row.get("Prefix"):
            record["prefix"] = row["Prefix"]
        return record

    def _build_drawing_set(self, pid: str, qa_pairs: list[dict[str, Any]]) -> DrawingSet:
        view = View(id=f"pidqa-{pid}-v0", name=f"P&ID {pid}", view_type=ViewType.DIAGRAM)
        sheet = Sheet(
            id=f"pidqa-{pid}-s0",
            sheet_number=pid,
            discipline=Discipline.PROCESS,
            title=f"P&ID {pid}",
            views=[view],
        )
        return DrawingSet(
            id=f"pidqa-{pid}",
            name=f"PIDQA P&ID {pid}",
            project_name="PIDQA",
            source=SourceFile(
                filename=f"pid_{pid}",
                file_type="image",
                ingest_tool="datasets.preparers.pidqa",
            ),
            sheets=[sheet],
            metadata={
                "dataset": "PIDQA",
                "pid_number": pid,
                "n_qa": len(qa_pairs),
                "qa_pairs": qa_pairs,
            },
            **self.stamp(),
        )
