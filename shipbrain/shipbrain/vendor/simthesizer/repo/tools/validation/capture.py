"""Capture native component snapshots and normalize scheduler observations."""

import csv
import json
import math
import shutil
import subprocess
import tomllib
import uuid

from .bundles import fresh, object_hash, read_json
from .validator import ContractError, digest, number

METRICS = {
    "running_requests": (
        "running_requests",
        "engine.admitted_running_requests",
        "requests",
        "gauge_hold",
    ),
    "waiting_requests": (
        "waiting_requests",
        "engine.waiting_requests",
        "requests",
        "gauge_hold",
    ),
    "generation_rate": (
        "generation_tokens_total",
        "engine.generated_tokens.rate",
        "tokens/s",
        "counter",
    ),
}


def scheduler_nodes(tree, path=""):
    """Use the same configuration paths in input trees and native snapshots."""
    if isinstance(tree, dict):
        for key, value in tree.items():
            child = path + "/" + key.replace("~", "~0").replace("/", "~1")
            if key == "scheduler":
                yield child, value
            elif key == "schedulers":
                if not isinstance(value, list):
                    raise ContractError(f"{child}: expected a scheduler array")
                yield from ((f"{child}/{i}", item) for i, item in enumerate(value))
            else:
                yield from scheduler_nodes(value, child)
    elif isinstance(tree, list):
        for i, value in enumerate(tree):
            yield from scheduler_nodes(value, f"{path}/{i}")


def scheduler_paths(config):
    paths = []
    for path, node in scheduler_nodes(config):
        if not isinstance(node, dict) or node.get("kind") != "chunked_prefill":
            raise ContractError(f"{path}: scheduler semantics are unsupported")
        paths.append(path)
    return sorted(paths)


def metric_declarations(paths):
    return {
        f"{path}/{name}": {
            "column": f"{path}/{column}",
            "meaning": meaning,
            "unit": unit,
            "observation": observation,
            "dimensions": {"path": path},
            "verified": True,
            "evidence": "chunked_prefill admission and committed emissions; post-event engine clock; configuration path scope",
        }
        for path in paths
        for name, (column, meaning, unit, observation) in METRICS.items()
    }


def trace_rows(path, paths):
    previous = None
    with path.open() as stream:
        for line_number, line in enumerate(stream, 1):
            frame = json.loads(line)
            time = number(frame["time_s"], "time_s")
            if time < 0 or (previous is not None and time <= previous["time_s"]):
                raise ContractError(f"{path}:{line_number}: trace time must increase")
            native = dict(scheduler_nodes(frame["state"]))
            if set(native) != set(paths):
                raise ContractError("native scheduler paths differ from configuration")
            row = {"time_s": time}
            for scope in paths:
                try:
                    state = native[scope]
                    for column, *_ in METRICS.values():
                        value = state[column]
                        if type(value) is not int or value < 0:
                            raise ContractError(
                                f"{scope}/{column}: expected a nonnegative integer"
                            )
                        row[f"{scope}/{column}"] = value
                except (KeyError, IndexError, TypeError) as exc:
                    raise ContractError(
                        f"{path}:{line_number}: missing observations at {scope}"
                    ) from exc
                counter = f"{scope}/generation_tokens_total"
                if previous is not None and row[counter] < previous[counter]:
                    raise ContractError(f"{scope}: generation counter decreased")
            yield row
            previous = row


def sampling_bins(duration, interval):
    duration, interval = number(duration, "duration"), number(interval, "interval")
    if duration <= 0 or interval <= 0 or not math.isfinite(duration / interval):
        raise ContractError(
            "duration and interval must be positive with a finite ratio"
        )
    bins = math.ceil(duration / interval)
    if bins > 1_000_000:
        raise ContractError("more than 1000000 samples requested")
    return bins


def normalize_trace(trace, output, paths, duration, interval):
    bins = sampling_bins(duration, interval)
    rows = trace_rows(trace, paths)
    current = next(rows, None)
    if current is None or current["time_s"] != 0:
        raise ContractError("native trace must start at time zero")
    following = next(rows, None)
    with output.open("w", newline="") as stream:
        writer = csv.DictWriter(stream, fieldnames=list(current), lineterminator="\n")
        writer.writeheader()
        for i in range(bins + 1):
            time = min(i * interval, duration)
            while following is not None and following["time_s"] <= time:
                current = following
                following = next(rows, None)
            writer.writerow({**current, "time_s": time})
    if following is not None:
        raise ContractError(
            "simulator completion exceeds the capture horizon; do not truncate"
        )
    for scope in paths:
        if current[f"{scope}/running_requests"] or current[f"{scope}/waiting_requests"]:
            raise ContractError(f"{scope}: scheduler did not drain")
    return {
        "last_engine_event_s": current["time_s"],
        "generation_tokens_by_path": {
            scope: current[f"{scope}/generation_tokens_total"] for scope in paths
        },
    }


def expected_tokens(workload):
    total, count = 0, 0
    with workload.open() as stream:
        for line in stream:
            if not line.strip():
                continue
            row = json.loads(line)
            subs = row.get("sub_requests", [])
            if (
                row.get("initial") != [0]
                or len(subs) != 1
                or subs[0].get("kind") != "llm"
                or subs[0].get("next") != []
                or subs[0].get("interval") not in (None, 0)
            ):
                raise ContractError(
                    "capture requires independent fixed-arrival LLM roots"
                )
            sub = subs[0]
            if sub.get("known_tokens") not in (None, sub["input_tokens"]):
                raise ContractError(
                    "capture requires fresh roots without previously generated tokens"
                )
            output = sub["output_tokens"]
            if type(output) is not int or output < 0:
                raise ContractError("output_tokens must be a nonnegative integer")
            total += output
            count += 1
    if not count:
        raise ContractError("empty capture workload")
    return total


def run_sim(args):
    sampling_bins(args.duration, args.interval)
    expected = expected_tokens(args.workload)
    config_bytes = args.config.read_bytes()
    paths = scheduler_paths(tomllib.loads(config_bytes.decode())["system"])
    if not paths:
        raise ContractError("configuration has no supported scheduler observations")
    environment = read_json(args.environment)
    required = {"model", "model_revision", "hardware", "deployment", "serving_config"}
    if not isinstance(environment, dict) or any(
        environment.get(k) is None for k in required
    ):
        raise ContractError("environment specification is incomplete")
    fresh(args.out)
    for source, name in [
        (args.workload, "workload.jsonl"),
        (args.environment, "environment.json"),
    ]:
        shutil.copyfile(source, args.out / name)
    (args.out / "config.toml").write_bytes(config_bytes)
    receipt = {
        "schema_version": 1,
        "adapter": "simthesizer/component-state-v1",
        "status": "INCOMPLETE",
        "run_id": str(uuid.uuid4()),
        "producer_revision": args.revision,
        "binary_sha256": digest(args.binary),
        "config_path": str(args.config.resolve()),
        "config_sha256": digest(args.out / "config.toml"),
        "workload_sha256": digest(args.out / "workload.jsonl"),
        "environment_sha256": object_hash(environment),
        "capture_duration_s": args.duration,
        "sample_interval_s": args.interval,
        "expected_generation_tokens": expected,
        "clock": {
            "column": "time_s",
            "basis": "workload_start",
            "unit": "s",
            "origin": 0,
            "evidence": "native engine time; fixed arrivals preserved",
        },
        "metrics": metric_declarations(paths),
        "observation_scope": {
            "kind": "schedulers",
            "identity_basis": "configuration_path",
            "paths": paths,
        },
    }
    receipt_path = args.out / "bundle.json"

    def save():
        receipt_path.write_text(json.dumps(receipt, indent=2, allow_nan=False) + "\n")

    save()
    try:
        command = [
            str(args.binary.resolve()),
            "--config",
            str(args.config.resolve()),
            "--workload",
            str((args.out / "workload.jsonl").resolve()),
            "--output-jsonl",
            str((args.out / "results.jsonl").resolve()),
            "--output-engine-trace",
            str((args.out / "trace.jsonl").resolve()),
        ]
        receipt["command"] = command
        with (args.out / "process.log").open("w") as log:
            result = subprocess.run(
                command, stdout=log, stderr=subprocess.STDOUT, check=False
            )
        receipt["exit_code"] = result.returncode
        if result.returncode:
            raise ContractError("simulator failed; inspect process.log")
        if digest(args.config) != receipt["config_sha256"]:
            raise ContractError("configuration changed during capture")
        receipt.update(
            normalize_trace(
                args.out / "trace.jsonl",
                args.out / "engine.csv",
                paths,
                args.duration,
                args.interval,
            )
        )
        if sum(receipt["generation_tokens_by_path"].values()) != expected:
            raise ContractError("generated-token count differs from workload")
        receipt["artifacts"] = {
            name: digest(args.out / name)
            for name in (
                "engine.csv",
                "trace.jsonl",
                "results.jsonl",
                "workload.jsonl",
                "environment.json",
                "config.toml",
            )
        }
        receipt["status"] = "COMPLETE"
    except (OSError, ValueError, TypeError, KeyError) as exc:
        receipt["error"] = str(exc)
        save()
        raise
    save()
    return receipt
