"""Leaderboard: persist eval results to SQLite and render SOTA comparisons.

Every harness result (keyed by model, metric, and slice, with mean/std/95% CI over
seeds) is stored in a SQLite table, so runs accumulate and are queryable. The render
methods produce the comparison that backs the "we beat SOTA" claim: our models vs
published-SOTA numbers vs frontier-API baselines, per drawing type and metric, best
first.
"""

from __future__ import annotations

import sqlite3
from collections.abc import Sequence
from dataclasses import dataclass
from pathlib import Path

from .metrics import HIGHER_IS_BETTER

_PERCENT_AS_IS = {"counting_mape"}  # already a percentage
_RAW = {"chamfer_distance"}  # a distance, not a fraction


@dataclass
class ResultRecord:
    """One leaderboard entry: a (model, metric, slice) measurement with dispersion."""

    model: str
    metric: str
    value: float
    std: float = 0.0
    ci95: float = 0.0
    n_seeds: int = 1
    drawing_type: str = "unknown"
    origin: str = "unknown"
    condition: str = "clean"
    dataset: str = "unknown"
    kind: str = "measured"  # measured | reported
    citation: str = ""  # source + model for reported numbers; empty for measured


_SCHEMA = """
CREATE TABLE IF NOT EXISTS results (
    model TEXT, metric TEXT, value REAL, std REAL, ci95 REAL, n_seeds INTEGER,
    drawing_type TEXT, origin TEXT, condition TEXT, dataset TEXT, kind TEXT, citation TEXT
)
"""


def format_value(metric: str, value: float, ci95: float = 0.0) -> str:
    """Human-readable value for a metric (percentages for fractional metrics)."""
    if metric in _RAW:
        return f"{value:.4f} +/-{ci95:.4f}" if ci95 else f"{value:.4f}"
    if metric in _PERCENT_AS_IS:
        return f"{value:.1f}% +/-{ci95:.1f}" if ci95 else f"{value:.1f}%"
    return f"{value * 100:.1f}% +/-{ci95 * 100:.1f}" if ci95 else f"{value * 100:.1f}%"


class Leaderboard:
    """A SQLite-backed store of :class:`ResultRecord` rows."""

    def __init__(self, db_path: str | Path = ":memory:") -> None:
        self.conn = sqlite3.connect(str(db_path))
        self.conn.row_factory = sqlite3.Row
        self.conn.execute(_SCHEMA)
        self.conn.commit()

    def add(self, record: ResultRecord) -> None:
        self.conn.execute(
            "INSERT INTO results VALUES (?,?,?,?,?,?,?,?,?,?,?,?)",
            (
                record.model,
                record.metric,
                record.value,
                record.std,
                record.ci95,
                record.n_seeds,
                record.drawing_type,
                record.origin,
                record.condition,
                record.dataset,
                record.kind,
                record.citation,
            ),
        )
        self.conn.commit()

    def add_many(self, records: Sequence[ResultRecord]) -> None:
        for record in records:
            self.add(record)

    def query(
        self, *, metric: str | None = None, drawing_type: str | None = None
    ) -> list[ResultRecord]:
        sql = "SELECT * FROM results"
        clauses, params = [], []
        if metric is not None:
            clauses.append("metric = ?")
            params.append(metric)
        if drawing_type is not None:
            clauses.append("drawing_type = ?")
            params.append(drawing_type)
        if clauses:
            sql += " WHERE " + " AND ".join(clauses)
        rows = self.conn.execute(sql, params).fetchall()
        return [ResultRecord(**dict(row)) for row in rows]

    def metrics(self) -> list[str]:
        rows = self.conn.execute("SELECT DISTINCT metric FROM results").fetchall()
        return sorted(r["metric"] for r in rows)

    def drawing_types(self, metric: str) -> list[str]:
        rows = self.conn.execute(
            "SELECT DISTINCT drawing_type FROM results WHERE metric = ?", (metric,)
        ).fetchall()
        return sorted(r["drawing_type"] for r in rows)

    def render_table(self, metric: str, drawing_type: str) -> str:
        """Render one comparison table (rows = model × condition), best first."""
        records = self.query(metric=metric, drawing_type=drawing_type)
        if not records:
            return ""
        higher_better = HIGHER_IS_BETTER.get(metric, True)
        records.sort(key=lambda r: r.value, reverse=higher_better)
        lines = [
            f"### {drawing_type} - {metric}  ({'higher' if higher_better else 'lower'} is better)",
            "",
            "| rank | model | condition | score | seeds | kind | source |",
            "|---|---|---|---|---|---|---|",
        ]
        for rank, r in enumerate(records, start=1):
            marker = "  <- best" if rank == 1 else ""
            source = r.citation if r.kind == "reported" else "measured by us (synthetic GT)"
            lines.append(
                f"| {rank} | {r.model}{marker} | {r.condition} | "
                f"{format_value(metric, r.value, r.ci95)} | {r.n_seeds} | {r.kind} | {source} |"
            )
        return "\n".join(lines)

    def render_report(self) -> str:
        """Render every (drawing_type, metric) comparison present in the store."""
        blocks: list[str] = [
            "# Matrix evaluation leaderboard",
            "",
            "_Legend: kind=measured -> computed by us on synthetic ground truth; "
            "kind=reported -> literature-cited (see source). No external APIs are called._",
            "",
        ]
        for metric in self.metrics():
            for drawing_type in self.drawing_types(metric):
                table = self.render_table(metric, drawing_type)
                if table:
                    blocks.append(table)
                    blocks.append("")
        return "\n".join(blocks)

    def close(self) -> None:
        self.conn.close()
