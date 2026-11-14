"""The runner: score adapters over tasks, across slices and seeds.

For each (adapter, task, metric, slice) it computes the metric over the slice's
samples once per seed, aggregates to mean/std/95% CI, and records the result. Reported
-numbers adapters short-circuit to their stored values; reported metrics they don't
carry are skipped (never predicted). Multi-seed is built in here, not bolted on.
"""

from __future__ import annotations

from collections.abc import Sequence

from .adapters import ModelAdapter
from .aggregate import aggregate
from .leaderboard import Leaderboard, ResultRecord
from .metrics import get_metric
from .tasks import EvalTask

DEFAULT_SEEDS: tuple[int, ...] = (0, 1, 2)


def run_task(
    adapter: ModelAdapter,
    task: EvalTask,
    *,
    seeds: Sequence[int] = DEFAULT_SEEDS,
    leaderboard: Leaderboard | None = None,
) -> list[ResultRecord]:
    """Run one adapter over one task; return (and optionally store) the results."""
    records: list[ResultRecord] = []
    grouped = task.slices()

    for metric_name in task.metrics:
        for slice_, samples in grouped.items():
            reported = adapter.reported_score(metric_name, slice_.drawing_type)
            if reported is not None:
                agg = aggregate([reported])
                kind = "reported"
                citation = adapter.reported_citation(metric_name, slice_.drawing_type) or ""
            elif not adapter.can_predict:
                continue  # a reported-only adapter that didn't report this metric
            else:
                metric = get_metric(metric_name)  # only measured adapters need the function
                gts = [s.ground_truth for s in samples]
                seed_list = list(seeds) if adapter.is_stochastic else list(seeds)[:1]
                values = [
                    metric([adapter.predict(s, seed=seed) for s in samples], gts)
                    for seed in seed_list
                ]
                agg = aggregate(values)
                kind = "measured"
                citation = ""

            record = ResultRecord(
                model=adapter.name,
                metric=metric_name,
                value=agg.mean,
                std=agg.std,
                ci95=agg.ci95,
                n_seeds=agg.n,
                kind=kind,
                citation=citation,
                drawing_type=slice_.drawing_type,
                origin=slice_.origin,
                condition=slice_.condition,
                dataset=slice_.dataset,
            )
            records.append(record)
            if leaderboard is not None:
                leaderboard.add(record)
    return records


def run_matrix(
    adapters: Sequence[ModelAdapter],
    tasks: Sequence[EvalTask],
    *,
    seeds: Sequence[int] = DEFAULT_SEEDS,
    leaderboard: Leaderboard | None = None,
) -> list[ResultRecord]:
    """Run every adapter over every task (the full matrix)."""
    out: list[ResultRecord] = []
    for task in tasks:
        for adapter in adapters:
            out.extend(run_task(adapter, task, seeds=seeds, leaderboard=leaderboard))
    return out
