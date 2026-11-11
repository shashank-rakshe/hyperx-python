"""Record validation decisions and check evidence integrity."""

import hashlib
import json
import uuid
from pathlib import Path

from .validator import digest

ACTIONS = ("investigate", "revise", "complete", "blocked")


def local_path(root, name):
    path = Path(name)
    if path.is_absolute() or ".." in path.parts or not path.parts:
        raise ValueError("use a path relative to the task directory")
    resolved = (root / path).resolve()
    if root.resolve() not in resolved.parents:
        raise ValueError("path escapes the task directory")
    return resolved


def write_decision(args):
    root = args.task_root.resolve()
    state = local_path(root, args.state)
    evidence = [
        {"path": str(p), "sha256": digest(local_path(root, p))} for p in args.evidence
    ]
    decision = {
        "schema_version": 1,
        "decision_id": str(uuid.uuid4()),
        "action": args.action,
        "reason": args.reason,
        "evidence": evidence,
        "pending_checks": args.pending_check,
        "next_step": args.next_step,
        "blocker": args.blocker,
    }
    state.parent.mkdir(parents=True, exist_ok=True)
    temporary = state.with_name(state.name + "." + uuid.uuid4().hex + ".tmp")
    try:
        temporary.write_text(json.dumps(decision, indent=2) + "\n")
        temporary.replace(state)
    finally:
        temporary.unlink(missing_ok=True)
    return check_decision(root, args.state)


def check_decision(task_root, state_name, previous_digest=None):
    """Check declared state and evidence integrity, never their scientific merit."""
    root = Path(task_root).resolve()
    state = local_path(root, state_name)
    result = {
        "status": "CONTINUE",
        "action": None,
        "issues": [],
        "state_sha256": None,
        "reason": None,
        "next_step": None,
        "blocker": None,
    }
    try:
        if state.stat().st_size > 256 * 1024:
            raise ValueError("validation decision exceeds 256 KiB")
        raw = state.read_bytes()
        result["state_sha256"] = hashlib.sha256(raw).hexdigest()
        data = json.loads(raw)
        if not isinstance(data, dict) or data.get("schema_version") != 1:
            raise ValueError("expected validation decision schema_version 1")
        if (
            not isinstance(data.get("decision_id"), str)
            or not data["decision_id"].strip()
        ):
            raise ValueError("decision_id is required")
        action = data.get("action")
        if action not in ACTIONS:
            raise ValueError("invalid validation action")
        result.update(
            {
                k: data.get(k)
                for k in (
                    "action",
                    "reason",
                    "next_step",
                    "blocker",
                    "pending_checks",
                    "evidence",
                )
            }
        )
        if not isinstance(data.get("reason"), str) or not data["reason"].strip():
            result["issues"].append("explain the validation judgment")
        pending = data.get("pending_checks")
        if not isinstance(pending, list) or any(
            not isinstance(s, str) or not s.strip() for s in pending
        ):
            result["issues"].append("pending_checks must be a list of descriptions")
        elif action in ("complete", "blocked") and pending:
            result["issues"].append(
                "terminal decision declares pending local checks; execute them before closure, even if they cannot resolve a separate accuracy blocker"
            )
        evidence = data.get("evidence")
        if not isinstance(evidence, list) or not evidence:
            result["issues"].append(
                "link executed evidence and the validation assessment"
            )
        else:
            for entry in evidence:
                if not isinstance(entry, dict) or not isinstance(
                    entry.get("path"), str
                ):
                    raise TypeError("invalid evidence entry")
                path = local_path(root, entry["path"])
                if path == state or digest(path) != entry.get("sha256"):
                    result["issues"].append(
                        "missing or changed evidence: " + entry["path"]
                    )
        if action in ("investigate", "revise") and not (
            isinstance(data.get("next_step"), str) and data["next_step"].strip()
        ):
            result["issues"].append("state the next diagnostic or supported correction")
        if action == "blocked" and not (
            isinstance(data.get("blocker"), str) and data["blocker"].strip()
        ):
            result["issues"].append(
                "identify missing evidence/choice/capability and why available local checks cannot resolve it"
            )
        if previous_digest is not None and result["state_sha256"] == previous_digest:
            result["issues"].append("no updated validation decision from this turn")
        if not result["issues"] and action in ("complete", "blocked"):
            result["status"] = "COMPLETE" if action == "complete" else "BLOCKED"
    except (OSError, ValueError, TypeError, KeyError) as exc:
        result["issues"].append(str(exc))
    return result
