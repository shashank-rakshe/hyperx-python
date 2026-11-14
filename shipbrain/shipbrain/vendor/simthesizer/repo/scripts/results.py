"""Shared result loading, DAG timing, and serving metrics. All times are seconds."""

import argparse
import json
import math
import statistics
from collections import deque
from dataclasses import dataclass
from itertools import accumulate
from pathlib import Path

LATENCIES = {
    "ttft": "TTFT",
    "tpot": "TPOT",
    "itl": "ITL",
    "e2e": "LLM E2E",
    "normalized_e2e": "LLM E2E / output token",
    "request_e2e": "Request DAG E2E",
}
SCALARS = {
    "makespan": "s",
    "output_throughput": "token/s",
    "request_throughput": "request/s",
}


def metric_unit(metric):
    return "s/token" if metric == "normalized_e2e" else SCALARS.get(metric, "s")


def number(value, field):
    if type(value) not in (int, float) or not math.isfinite(value) or value < 0:
        raise ValueError(f"{field} must be finite and non-negative")
    return value


def integer(value, field):
    if type(value) is not int or value < 0:
        raise ValueError(f"{field} must be a non-negative integer")
    return value


def indices(value, size, field):
    if not isinstance(value, list):
        raise TypeError(f"{field} must be a list")
    for index in value:
        if integer(index, field) >= size:
            raise ValueError(f"{field} index {index} is out of range")
    if len(set(value)) != len(value):
        raise ValueError(f"{field} contains duplicate indices")
    return sorted(value)


def parse_request(row):
    if not isinstance(row, dict):
        raise TypeError("expected a request object")
    integer(row.get("request_id"), "request_id")
    number(row.get("arrival_time"), "arrival_time")
    nodes = row.get("sub_requests")
    if not isinstance(nodes, list) or not nodes:
        raise ValueError("sub_requests must be a non-empty list")
    row["initial"] = indices(row.get("initial"), len(nodes), "initial")
    for index, node in enumerate(nodes):
        if not isinstance(node, dict) or node.get("kind") not in ("llm", "tool_call"):
            raise ValueError(f"sub-request {index}: expected llm or tool_call")
        for field in ("input_tokens", "output_tokens"):
            integer(node.get(field), field)
        node["next"] = indices(node.get("next"), len(nodes), "next")
        node["interval"] = number(
            0 if node.get("interval") is None else node["interval"], "interval"
        )
        if node["kind"] == "tool_call":
            node["duration"] = number(node.get("duration"), "duration")
            continue
        latencies = node.get("token_latency")
        if not isinstance(latencies, list) or len(latencies) != node["output_tokens"]:
            raise ValueError(
                f"sub-request {index}: token_latency must contain exactly "
                f"{node['output_tokens']} entries; only complete results are supported"
            )
        for value in latencies:
            number(value, "token_latency")
        for field, count in (
            ("input_token_ids", "input_tokens"),
            ("output_token_ids", "output_tokens"),
        ):
            tokens = node.get(field)
            if tokens is not None:
                if not isinstance(tokens, list) or len(tokens) != node[count]:
                    raise ValueError(f"{field} length differs from {count}")
                for token in tokens:
                    integer(token, field)
    timeline(row)
    return row


def timeline(row):
    """A node starts after all parents finish, plus its own interval."""
    nodes = row["sub_requests"]
    degrees = [0] * len(nodes)
    starts = [row["arrival_time"]] * len(nodes)
    ends = [0.0] * len(nodes)
    for node in nodes:
        for child in node["next"]:
            degrees[child] += 1
    roots = [i for i, degree in enumerate(degrees) if degree == 0]
    if row["initial"] != roots:
        raise ValueError("initial does not match DAG roots")
    queue = deque(roots)
    visited = 0
    while queue:
        index = queue.popleft()
        node = nodes[index]
        starts[index] += node["interval"]
        duration = (
            math.fsum(node["token_latency"])
            if node["kind"] == "llm"
            else node["duration"]
        )
        ends[index] = number(starts[index] + duration, "completion time")
        visited += 1
        for child in node["next"]:
            starts[child] = max(starts[child], ends[index])
            degrees[child] -= 1
            if degrees[child] == 0:
                queue.append(child)
    if visited != len(nodes):
        raise ValueError("request DAG contains a cycle")
    return starts, ends


@dataclass
class Run:
    label: str
    path: Path
    requests: dict

    @property
    def origin(self):
        return min(row["arrival_time"] for row in self.requests.values())

    def token_times(self):
        for row in self.requests.values():
            starts, _ = timeline(row)
            for index, node in enumerate(row["sub_requests"]):
                if node["kind"] == "llm":
                    for elapsed in accumulate(node["token_latency"]):
                        yield starts[index] + elapsed


def load_run(spec):
    label, separator, filename = spec.partition("=")
    path = Path(filename if separator else spec)
    label = label if separator else path.stem
    if not label or (separator and not filename):
        raise ValueError("expected [LABEL=]PATH")
    requests = {}
    with path.open() as source:
        for line_number, line in enumerate(source, 1):
            if not line.strip():
                continue
            try:
                row = parse_request(json.loads(line))
                request_id = row["request_id"]
                if request_id in requests:
                    raise ValueError(f"duplicate request_id {request_id}")
                requests[request_id] = row
            except (TypeError, ValueError, OverflowError) as exc:
                raise ValueError(f"{path}:{line_number}: {exc}") from exc
    if not requests:
        raise ValueError(f"{path}: empty result")
    return Run(label, path, dict(sorted(requests.items())))


def match_runs(reference, candidate):
    """Require the same workload; optional traces are checked when both exist."""
    if reference.requests.keys() != candidate.requests.keys():
        raise ValueError(
            f"{candidate.label}: request IDs differ from {reference.label}"
        )
    for request_id, left in reference.requests.items():
        right = candidate.requests[request_id]
        prefix = f"{candidate.label}: request {request_id}"
        for field in ("arrival_time", "initial"):
            if left[field] != right[field]:
                raise ValueError(f"{prefix}: {field} differs")
        if len(left["sub_requests"]) != len(right["sub_requests"]):
            raise ValueError(f"{prefix}: sub-request count differs")
        for index, (a, b) in enumerate(
            zip(left["sub_requests"], right["sub_requests"])
        ):
            for field in (
                "kind",
                "input_tokens",
                "output_tokens",
                "next",
                "interval",
                "duration",
            ):
                if a.get(field) != b.get(field):
                    raise ValueError(f"{prefix}, sub-request {index}: {field} differs")
            for field in ("model", "input_token_ids", "output_token_ids"):
                if (
                    a.get(field) is not None
                    and b.get(field) is not None
                    and a[field] != b[field]
                ):
                    raise ValueError(f"{prefix}, sub-request {index}: {field} differs")


def load_runs(specs):
    runs = [load_run(spec) for spec in specs]
    if len({run.label for run in runs}) != len(runs):
        raise ValueError("duplicate run labels; use LABEL=PATH to distinguish them")
    for run in runs[1:]:
        match_runs(runs[0], run)
    return runs


def measurements(run):
    samples = {metric: {} for metric in LATENCIES}
    finish = run.origin
    output_tokens = 0
    for request_id, row in run.requests.items():
        _, ends = timeline(row)
        finish = max(finish, max(ends))
        samples["request_e2e"][(request_id,)] = max(ends) - row["arrival_time"]
        for index, node in enumerate(row["sub_requests"]):
            if node["kind"] != "llm" or not node["token_latency"]:
                continue
            latencies = node["token_latency"]
            key = (request_id, index)
            output_tokens += len(latencies)
            samples["ttft"][key] = latencies[0]
            samples["e2e"][key] = math.fsum(latencies)
            samples["normalized_e2e"][key] = math.fsum(latencies) / len(latencies)
            if len(latencies) > 1:
                samples["tpot"][key] = statistics.fmean(latencies[1:])
            for token, latency in enumerate(latencies[1:], 1):
                samples["itl"][(*key, token)] = latency
    duration = finish - run.origin
    samples["makespan"] = {(): duration}
    samples["output_throughput"] = {(): output_tokens / duration} if duration else {}
    samples["request_throughput"] = (
        {(): len(run.requests) / duration} if duration else {}
    )
    return samples


def percentile(sorted_values, percent):
    position = (len(sorted_values) - 1) * percent / 100
    low = math.floor(position)
    high = math.ceil(position)
    return sorted_values[low] + (sorted_values[high] - sorted_values[low]) * (
        position - low
    )


def summarize(samples, percentiles):
    values = sorted(samples.values())
    return {
        "mean": statistics.fmean(values) if values else None,
        **{f"p{p:g}": percentile(values, p) if values else None for p in percentiles},
    }


def relative_error(reference, candidate):
    if reference is None or candidate is None or reference == 0:
        return None
    return 100 * (candidate - reference) / reference


def paired_errors(reference, candidate):
    if reference.keys() != candidate.keys():
        raise ValueError("metric sample IDs differ")
    differences = [candidate[key] - value for key, value in reference.items()]
    absolute = [abs(value) for value in differences]
    percentages = [
        abs(relative_error(value, candidate[key]))
        for key, value in reference.items()
        if value > 0
    ]
    total = math.fsum(reference.values())
    return {
        "count": len(differences),
        "mae": statistics.fmean(absolute) if absolute else None,
        "bias": statistics.fmean(differences) if differences else None,
        "mape_pct": statistics.fmean(percentages) if percentages else None,
        "mape_count": len(percentages),
        "wape_pct": 100 * math.fsum(absolute) / total if total else None,
    }


def throughput(run, window, end):
    """Fixed-width [left, right) bins on the shared arrival-relative clock."""
    edges = [i * window for i in range(math.floor(end / window) + 2)]
    counts = [0] * (len(edges) - 1)
    origin = run.origin
    for time in run.token_times():
        counts[min(math.floor((time - origin) / window), len(counts) - 1)] += 1
    return edges, [count / window for count in counts]


def positive_float(value):
    parsed = float(value)
    if not math.isfinite(parsed) or parsed <= 0:
        raise argparse.ArgumentTypeError("must be finite and positive")
    return parsed


def percent(value):
    parsed = float(value)
    if not math.isfinite(parsed) or not 0 <= parsed <= 100:
        raise argparse.ArgumentTypeError("must be between 0 and 100")
    return parsed


def protect_output(path, runs):
    if path.resolve() in {run.path.resolve() for run in runs}:
        raise ValueError("output must not overwrite an input result")


def table(headers, rows):
    def display(value):
        if value is None:
            return "n/a"
        return f"{value:.6g}" if isinstance(value, float) else str(value)

    lines = [headers, *[[display(value) for value in row] for row in rows]]
    widths = [max(len(row[i]) for row in lines) for i in range(len(headers))]
    return "\n".join(
        "  ".join(value.ljust(width) for value, width in zip(row, widths)).rstrip()
        for row in lines
    )
