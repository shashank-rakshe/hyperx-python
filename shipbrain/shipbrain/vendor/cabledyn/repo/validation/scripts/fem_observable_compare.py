#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Compare solver outputs through CableDyn's FEM-level observable contract.

The reference file may come from MoorDyn, OrcaFlex, OpenFAST, or another solver.
Only the manifest's solver-neutral observable names are reported.  Reference and
candidate channel names are deliberately kept as adapters at the edge.
"""

from __future__ import annotations

import argparse
import json
import math
import os
import re
from bisect import bisect_right
from dataclasses import dataclass
from pathlib import Path
from statistics import fmean
from typing import Iterable


ALLOWED_DOMAINS = {"line", "cable", "connector", "body", "vessel", "environment"}
METRIC_NAMES = {"nrmse", "bias", "std_relative", "peak_relative"}
TIME_TOKEN = re.compile(r"^time(?:\((?:s|sec)\)|\[(?:s|sec)\])?$", re.IGNORECASE)


class ComparisonError(RuntimeError):
    """A malformed input or failed regression contract."""


@dataclass(frozen=True)
class Table:
    names: tuple[str, ...]
    columns: dict[str, tuple[float, ...]]

    def column(self, name: str) -> tuple[float, ...]:
        key = name.casefold()
        matches = [values for channel, values in self.columns.items() if channel.casefold() == key]
        if len(matches) != 1:
            raise ComparisonError(f"channel {name!r} occurs {len(matches)} times; expected exactly once")
        return matches[0]


def _is_float(token: str) -> bool:
    try:
        float(token.replace("D", "E").replace("d", "e"))
        return True
    except ValueError:
        return False


def _is_time_token(token: str) -> bool:
    """Recognize supported physical spellings of the logical Time column."""
    return TIME_TOKEN.fullmatch(token) is not None


def _canonical_token(token: str) -> str:
    return "Time" if _is_time_token(token) else token


def read_table(path: Path, required_axis: str = "Time") -> Table:
    """Read a whitespace table, including wrapped MoorDyn header rows."""
    try:
        lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
    except OSError as exc:
        raise ComparisonError(f"cannot read {path}: {exc}") from exc

    logical_axis = _canonical_token(required_axis)
    start = next(
        (
            i
            for i, line in enumerate(lines)
            if logical_axis.casefold()
            in {_canonical_token(token).casefold() for token in line.split()}
            and line.split()
            and not _is_float(line.split()[0])
        ),
        None,
    )
    if start is None:
        raise ComparisonError(f"{path}: no {logical_axis} header")

    names: list[str] = []
    i = start
    while i < len(lines):
        tokens = lines[i].split()
        if not tokens:
            i += 1
            continue
        if i > start and (
            tokens[0].startswith("(") or any(_is_float(token) for token in tokens)
        ):
            break
        names.extend(tokens)
        i += 1
    # MoorDyn/OpenFAST write `Time`; CableDyn's standalone writers use
    # `Time(s)`. Keep units out of the logical schema so manifests can use the
    # same time column for either solver. Other channel tokens remain exact.
    names = [_canonical_token(name) for name in names]
    if (
        not names
        or logical_axis.casefold() not in {name.casefold() for name in names}
        or len({name.casefold() for name in names}) != len(names)
    ):
        raise ComparisonError(f"{path}: malformed or duplicate channel header")

    while i < len(lines):
        tokens = lines[i].split()
        if not tokens or all(
            token.startswith("(") and token.endswith(")") for token in tokens
        ):
            i += 1
            continue
        if _is_float(tokens[0]):
            break
        raise ComparisonError(f"{path}:{i + 1}: malformed row before numeric data")
    rows: list[list[float]] = []
    for line_number, line in enumerate(lines[i:], start=i + 1):
        tokens = line.split()
        if not tokens:
            continue
        if not _is_float(tokens[0]):
            raise ComparisonError(
                f"{path}:{line_number}: nonnumeric row encountered after numeric data began"
            )
        try:
            row = [float(token.replace("D", "E").replace("d", "e")) for token in tokens]
        except ValueError as exc:
            raise ComparisonError(
                f"{path}:{line_number}: numeric row contains a nonnumeric value"
            ) from exc
        if len(row) != len(names):
            raise ComparisonError(
                f"{path}:{line_number}: numeric row has {len(row)} values; expected {len(names)}"
            )
        rows.append(row)
    if not rows:
        raise ComparisonError(
            f"{path}: no complete numeric rows under the {logical_axis} header"
        )
    if any(not all(math.isfinite(value) for value in row) for row in rows):
        raise ComparisonError(f"{path}: non-finite output value")
    columns = {name: tuple(row[j] for row in rows) for j, name in enumerate(names)}
    return Table(tuple(names), columns)


def read_output(path: Path) -> Table:
    """Read a time history and enforce a strictly increasing logical Time."""
    table = read_table(path, "Time")
    times = table.column("Time")
    if any(b <= a for a, b in zip(times, times[1:])):
        raise ComparisonError(f"{path}: Time must be strictly increasing")
    return table


def extract_axis(table: Table, axis_name: str, filters: dict[str, object] | None = None) -> tuple[list[float], list[int]]:
    """Select rows and return a strictly increasing independent coordinate."""
    if filters is not None and not isinstance(filters, dict):
        raise ComparisonError("table filters must be a channel-to-value object")
    axis = table.column(_canonical_token(axis_name))
    indices = list(range(len(axis)))
    for channel, expected_raw in (filters or {}).items():
        expected = float(expected_raw)
        if not math.isfinite(expected):
            raise ComparisonError(f"filter {channel!r} must be finite")
        values = table.column(channel)
        indices = [i for i in indices if values[i] == expected]
    if not indices:
        raise ComparisonError("table filters select no rows")
    selected = [axis[i] for i in indices]
    if any(b <= a for a, b in zip(selected, selected[1:])):
        raise ComparisonError(f"{axis_name} must be strictly increasing after filtering")
    return selected, indices


def normalized_axis(values: list[float]) -> list[float]:
    if len(values) < 2 or values[-1] <= values[0]:
        raise ComparisonError("axis normalization requires at least two increasing coordinates")
    span = values[-1] - values[0]
    return [(value - values[0]) / span for value in values]


def observable_scale(observable: dict[str, object], key: str, case_name: str, observable_name: str) -> float:
    try:
        scale = float(observable.get(key, 1.0))
    except (TypeError, ValueError) as exc:
        raise ComparisonError(f"{case_name}/{observable_name}: {key} must be numeric") from exc
    if not math.isfinite(scale) or scale == 0.0:
        raise ComparisonError(f"{case_name}/{observable_name}: {key} must be finite and non-zero")
    return scale


def interpolate(times: tuple[float, ...], values: tuple[float, ...], targets: Iterable[float]) -> list[float]:
    result: list[float] = []
    for target in targets:
        if target < times[0] or target > times[-1]:
            raise ComparisonError("candidate does not span the requested reference time window")
        j = bisect_right(times, target)
        if j == 0:
            result.append(values[0])
        elif j == len(times):
            result.append(values[-1])
        elif times[j - 1] == target:
            result.append(values[j - 1])
        else:
            weight = (target - times[j - 1]) / (times[j] - times[j - 1])
            result.append(values[j - 1] + weight * (values[j] - values[j - 1]))
    return result


def _std(values: list[float]) -> float:
    mean = fmean(values)
    return math.sqrt(fmean((value - mean) ** 2 for value in values))


def metrics(reference: list[float], candidate: list[float], normalization: str) -> dict[str, float]:
    if len(reference) != len(candidate) or not reference:
        raise ComparisonError("observable series are empty or have different lengths")
    mean_ref = fmean(reference)
    rms_ref = math.sqrt(fmean(value * value for value in reference))
    span_ref = max(reference) - min(reference)
    if normalization == "range":
        scale = span_ref
    elif normalization == "rms":
        scale = rms_ref
    elif normalization == "magnitude":
        scale = max(abs(mean_ref), rms_ref, span_ref)
    else:
        raise ComparisonError(f"unknown normalization {normalization!r}")
    scale = max(scale, 1.0e-14)
    error = [got - want for want, got in zip(reference, candidate)]
    return {
        "nrmse": math.sqrt(fmean(value * value for value in error)) / scale,
        "bias": abs(fmean(candidate) - mean_ref) / scale,
        "std_relative": abs(_std(candidate) - _std(reference)) / max(_std(reference), scale * 1.0e-12),
        "peak_relative": abs(max(map(abs, candidate)) - max(map(abs, reference)))
        / max(max(map(abs, reference)), scale * 1.0e-12),
    }


def _resolve(root: Path, value: str) -> Path:
    expanded = Path(os.path.expandvars(value))
    return expanded if expanded.is_absolute() else root / expanded


def compare_manifest(manifest_path: Path, reference_root: Path, candidate_root: Path,
                     selected_case: str | None = None) -> tuple[list[dict[str, object]], bool]:
    try:
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise ComparisonError(f"cannot load manifest {manifest_path}: {exc}") from exc
    if manifest.get("schema") != 1 or not isinstance(manifest.get("cases"), list):
        raise ComparisonError("manifest requires schema=1 and a cases array")

    results: list[dict[str, object]] = []
    matched = False
    case_names: set[str] = set()
    for case in manifest["cases"]:
        if not isinstance(case, dict) or not isinstance(case.get("name"), str) or not case["name"]:
            raise ComparisonError("every manifest case requires a non-empty string name")
        name = case.get("name")
        if name in case_names:
            raise ComparisonError(f"duplicate manifest case name {name!r}")
        case_names.add(name)
        if selected_case and name != selected_case:
            continue
        matched = True
        observables = case.get("observables")
        if not isinstance(observables, list) or not observables:
            raise ComparisonError(f"{name}: observables must be a non-empty array")
        if case.get("normalize_axis", False) and any(
            key in case for key in ("axis_start", "axis_end", "time_start", "time_end")
        ):
            raise ComparisonError(f"{name}: normalized-axis comparisons cannot also select an axis window")
        ref_axis_name = case.get("reference_axis", case.get("reference_time", "Time"))
        cand_axis_name = case.get("candidate_axis", case.get("candidate_time", "Time"))
        if not isinstance(ref_axis_name, str) or not isinstance(cand_axis_name, str):
            raise ComparisonError(f"{name}: axis names must be strings")
        reference = read_table(_resolve(reference_root, case["reference"]), ref_axis_name)
        candidate = read_table(_resolve(candidate_root, case["candidate"]), cand_axis_name)
        ref_axis_all, ref_rows_all = extract_axis(reference, ref_axis_name, case.get("reference_filter"))
        cand_axis, cand_rows = extract_axis(candidate, cand_axis_name, case.get("candidate_filter"))
        axis_start = float(case.get("axis_start", case.get("time_start", ref_axis_all[0])))
        axis_end = float(case.get("axis_end", case.get("time_end", ref_axis_all[-1])))
        if not (math.isfinite(axis_start) and math.isfinite(axis_end) and axis_start <= axis_end):
            raise ComparisonError(f"{name}: comparison window must be finite and ordered")
        indices = [i for i, value in enumerate(ref_axis_all) if axis_start <= value <= axis_end]
        if not indices:
            raise ComparisonError(f"{name}: empty comparison window")
        ref_axis = [ref_axis_all[i] for i in indices]
        ref_rows = [ref_rows_all[i] for i in indices]
        if case.get("normalize_axis", False):
            ref_axis = normalized_axis(ref_axis)
            cand_axis = normalized_axis(cand_axis)
        observable_names: set[str] = set()
        for observable in observables:
            if not isinstance(observable, dict):
                raise ComparisonError(f"{name}: every observable must be an object")
            observable_name = observable.get("name", "")
            if not isinstance(observable_name, str) or not observable_name:
                raise ComparisonError(f"{name}: every observable requires a non-empty string name")
            if observable_name in observable_names:
                raise ComparisonError(f"{name}: duplicate observable name {observable_name!r}")
            observable_names.add(observable_name)
            domain = observable_name.split(".", 1)[0]
            if domain not in ALLOWED_DOMAINS:
                raise ComparisonError(
                    f"{name}: observable {observable_name!r} is not an FEM-level object; "
                    f"allowed domains are {sorted(ALLOWED_DOMAINS)}"
                )
            ref_scale = observable_scale(observable, "reference_scale", name, observable_name)
            cand_scale = observable_scale(observable, "candidate_scale", name, observable_name)
            ref_all = reference.column(observable["reference_channel"])
            ref = [ref_scale * ref_all[i] for i in ref_rows]
            candidate_all = candidate.column(observable["candidate_channel"])
            candidate_values = tuple(cand_scale * candidate_all[i] for i in cand_rows)
            got = interpolate(tuple(cand_axis), candidate_values, ref_axis)
            values = metrics(ref, got, observable.get("normalization", "magnitude"))
            limits = observable.get("limits")
            if not isinstance(limits, dict) or not limits:
                raise ComparisonError(f"{name}/{observable_name}: limits must be a non-empty object")
            if any(key not in METRIC_NAMES for key in limits):
                raise ComparisonError(f"{name}/{observable_name}: limits contain an unknown metric")
            for key, limit_raw in limits.items():
                limit = float(limit_raw)
                if not math.isfinite(limit) or limit < 0.0:
                    raise ComparisonError(f"{name}/{observable_name}: limit {key!r} must be finite and non-negative")
            failures = {key: values[key] for key, limit in limits.items() if values[key] > float(limit)}
            results.append({"case": name, "observable": observable_name, "metrics": values,
                            "limits": limits, "passed": not failures})
    if selected_case and not matched:
        raise ComparisonError(f"manifest has no case named {selected_case!r}")
    return results, all(bool(result["passed"]) for result in results) and bool(results)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("manifest", type=Path)
    parser.add_argument("--reference-root", type=Path, default=Path("."))
    parser.add_argument("--candidate-root", type=Path, default=Path("."))
    parser.add_argument("--case")
    parser.add_argument("--json", action="store_true", help="emit machine-readable results")
    args = parser.parse_args()
    try:
        results, passed = compare_manifest(
            args.manifest, args.reference_root, args.candidate_root, args.case
        )
    except (ComparisonError, KeyError, TypeError, ValueError) as exc:
        print(f"ERROR: {exc}")
        return 2
    if args.json:
        print(json.dumps({"passed": passed, "results": results}, indent=2))
    else:
        for result in results:
            state = "PASS" if result["passed"] else "FAIL"
            summary = ", ".join(f"{key}={value:.6g}" for key, value in result["metrics"].items())
            print(f"{state}: {result['case']} / {result['observable']}: {summary}")
    return 0 if passed else 1


if __name__ == "__main__":
    raise SystemExit(main())
