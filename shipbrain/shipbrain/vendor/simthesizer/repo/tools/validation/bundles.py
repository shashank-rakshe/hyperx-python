"""Backend-independent bundle integrity and pairing."""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path

from .validator import ContractError, digest, number


def read_json(path):
    return json.loads(path.read_text())


def object_hash(value):
    return hashlib.sha256(
        json.dumps(value, sort_keys=True, separators=(",", ":")).encode()
    ).hexdigest()


def fresh(out):
    if out.exists() and any(out.iterdir()):
        raise ContractError(f"output directory is not empty: {out}")
    out.mkdir(parents=True, exist_ok=True)


def check_bundle(root, filename):
    receipt = read_json(root / filename)
    if receipt.get("status") != "COMPLETE":
        raise ContractError(f"{root}: capture is not complete")
    for name in ["engine.csv", "workload.jsonl", "environment.json"]:
        if receipt.get("artifacts", {}).get(name) != digest(root / name):
            raise ContractError(f"{root}: artifact digest mismatch for {name}")
    if receipt.get("workload_sha256") != digest(root / "workload.jsonl") or receipt.get(
        "environment_sha256"
    ) != object_hash(read_json(root / "environment.json")):
        raise ContractError("bundle input identity mismatch")
    clock = receipt.get("clock", {})
    if receipt.get("schema_version") == 1:
        clock.setdefault(
            "column", "time_s"
        )  # normalized v1 CSV column default; never infer origin
    if (
        clock.get("basis") != "workload_start"
        or clock.get("unit") not in {"s", "ms", "us"}
        or not clock.get("column")
        or not clock.get("evidence")
    ):
        raise ContractError("bundle lacks an explicit observation clock mapping")
    number(clock.get("origin"), "clock.origin")
    return receipt


def bundle_directory(path):
    path = Path(path).resolve()
    if path.is_dir():
        return path
    if path.is_file() and path.name == "bundle.json":
        return path.parent
    raise ContractError(
        f"expected a bundle directory or its bundle.json receipt file: {path}"
    )


def pair(args):
    args = argparse.Namespace(**vars(args))
    args.reference = bundle_directory(args.reference)
    args.candidate = bundle_directory(args.candidate)
    reference = check_bundle(args.reference, "bundle.json")
    candidate = check_bundle(args.candidate, "bundle.json")
    if (
        any(receipt.get("split") == "heldout" for receipt in (reference, candidate))
        and not args.allow_heldout
    ):
        raise ContractError(
            "heldout data is excluded from the agent loop; evaluator must explicitly use --allow-heldout"
        )
    for key in ["workload_sha256", "environment_sha256", "capture_duration_s"]:
        if reference[key] != candidate[key]:
            raise ContractError(f"paired {key} differs")
    if reference.get("observation_scope") != candidate.get("observation_scope"):
        raise ContractError(
            "paired observation_scope differs; explicit entity correspondence is required"
        )
    policy = read_json(args.policy)
    policy_id = policy.get("comparison_id") or policy.get("policy_id")
    if not policy_id:
        raise ContractError(
            "comparison configuration must declare comparison_id (or legacy policy_id)"
        )
    case = {
        "schema_version": 1,
        "case_id": args.case_id,
        "data_kind": args.data_kind,
        "split": reference.get("split"),
        "split_group": reference.get("split_group"),
        "policy_id": policy_id,
        "policy_sha256": digest(args.policy),
        "workload": {
            "path": str((args.reference / "workload.jsonl").resolve()),
            "replay_mode": "fixed_arrivals",
        },
        "environment": read_json(args.reference / "environment.json"),
        "comparison": {
            "start_s": 0,
            "end_s": reference["capture_duration_s"],
            "bin_s": number(policy["bin_s"], "bin_s"),
            "reconstruction": "piecewise_constant",
            "window_evidence": "same predeclared duration in two complete run receipts",
        },
        "metrics": [],
        "bundle_evidence": {
            name: {"path": str(path.resolve()), "sha256": digest(path)}
            for name, path in [
                ("reference", args.reference / "bundle.json"),
                ("candidate", args.candidate / "bundle.json"),
            ]
        },
    }
    if reference.get("observation_scope") is not None:
        case["observation_scope"] = reference["observation_scope"]
    for role, receipt, root in [
        ("reference", reference, args.reference),
        ("candidate", candidate, args.candidate),
    ]:
        case[role] = {
            "path": str((root / "engine.csv").resolve()),
            "artifact_sha256": digest(root / "engine.csv"),
            "workload_sha256": receipt["workload_sha256"],
            "environment_sha256": receipt["environment_sha256"],
            "run_id": receipt["run_id"],
            "producer_revision": receipt.get("producer_revision")
            or receipt["producer"],
            "clock": dict(receipt["clock"]),
            "metrics": {},
        }
        if receipt.get("observation_scope") is not None:
            case[role]["observation_scope"] = receipt["observation_scope"]
    requested = list(policy.get("metrics", []))
    selected = {spec["name"] for spec in requested}
    if policy.get("include_additional_metrics", True):
        for name in sorted(
            set(reference.get("metrics", {})) | set(candidate.get("metrics", {}))
        ):
            if name not in selected:
                requested.append({"name": name, "required": False})
                selected.add(name)
    if not requested:
        raise ContractError("no requested or adapter-declared observations")
    for spec in requested:
        name = spec["name"]
        declarations = [
            receipt.get("metrics", {}).get(name) for receipt in (reference, candidate)
        ]
        available = next((item for item in declarations if item), {})
        # Preserve missing/mismatched declarations so the report explains what
        # cannot be compared while retaining usable evidence for other signals.
        case["metrics"].append(
            {
                **spec,
                "meaning": spec.get("meaning", available.get("meaning", "undeclared")),
                "unit": spec.get("unit", available.get("unit", "undeclared")),
            }
        )
        if "dimensions" in spec or "dimensions" in available:
            case["metrics"][-1]["dimensions"] = spec.get(
                "dimensions", available.get("dimensions")
            )
        for role, declaration in zip(["reference", "candidate"], declarations):
            if declaration:
                case[role]["metrics"][name] = {
                    **declaration,
                    "max_gap_s": number(policy["max_gap_s"], "max_gap_s"),
                }
    fresh(args.out)
    (args.out / "case.json").write_text(json.dumps(case, indent=2) + "\n")
    return case
