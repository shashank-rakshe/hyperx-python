"""Optional, grounded visual-QA pairs for later L4 agent training.

Two modes, both **off by default** (the generator only runs them under ``--qa-pairs``):

* **Template (no model):** questions whose answers are read straight from the known ground
  truth — counts, panel voltage, circuit totals. Correct by construction, because they are
  computed from the canonical model, not inferred from pixels. This is the safe default
  when QA pairs are requested.
* **Local model (optional enrichment):** draft free-form pairs with a *locally served*
  model (vLLM/SGLang on the DGX Spark). Per the engine's no-external-APIs rule this path
  asserts the endpoint is local (:func:`_assert_local`) and refuses anything else.

Pairs are stored in ``DrawingSet.metadata["qa_pairs"]`` in the shape the eval harness reads
(:func:`eval.metrics._qa_pairs`): a list of ``{"q_id", "question", "answer"}``.
"""

from __future__ import annotations

from typing import Any
from urllib.parse import urlparse

from .model import DEVICE_CATALOG, DeviceKind, ElectricalModel

_LOCAL_HOSTS = {"localhost", "127.0.0.1", "::1", "0.0.0.0"}


class QAExternalEndpointError(RuntimeError):
    """Raised if a QA endpoint is not local — the engine never calls external APIs."""


def _assert_local(endpoint: str) -> None:
    """Permit only loopback endpoints (vLLM/SGLang on this machine / the DGX Spark)."""
    host = urlparse(endpoint).hostname
    if host not in _LOCAL_HOSTS:
        raise QAExternalEndpointError(
            f"QA endpoint {endpoint!r} (host {host!r}) is not local; the synthetic engine "
            f"only calls a locally-served model, never an external API."
        )


def template_qa_pairs(model: ElectricalModel) -> list[dict[str, Any]]:
    """Ground-truth-grounded QA pairs (no model needed). Answers are exact by construction."""
    counts = model.device_count_by_kind()
    receptacle_kinds = {
        DeviceKind.DUPLEX_RECEPTACLE,
        DeviceKind.QUAD_RECEPTACLE,
        DeviceKind.GFCI_RECEPTACLE,
    }
    n_receptacles = sum(n for k, n in counts.items() if k in receptacle_kinds)
    pairs: list[dict[str, Any]] = [
        {
            "q_id": f"{model.id}-q-circuits",
            "question": f"How many branch circuits are in panel {model.panel.name}?",
            "answer": str(len(model.circuits)),
        },
        {
            "q_id": f"{model.id}-q-voltage",
            "question": f"What is the voltage of panel {model.panel.name}?",
            "answer": model.panel.voltage,
        },
        {
            "q_id": f"{model.id}-q-receptacles",
            "question": "How many receptacles are on the power & lighting plan?",
            "answer": str(n_receptacles),
        },
        {
            "q_id": f"{model.id}-q-homerun",
            "question": "Which panel do the home-run circuits return to?",
            "answer": model.panel.name,
        },
    ]
    for kind, n in sorted(counts.items(), key=lambda kv: kv[0].value):
        pairs.append(
            {
                "q_id": f"{model.id}-q-count-{kind.value}",
                "question": f"How many '{DEVICE_CATALOG[kind].label}' symbols are on the plan?",
                "answer": str(n),
            }
        )
    return pairs


def local_model_qa(
    model: ElectricalModel, *, endpoint: str, image_b64: str | None = None, timeout: float = 30.0
) -> list[dict[str, Any]]:
    """Draft extra QA pairs with a *locally served* model. Optional; never an external API.

    Implemented as an OpenAI-compatible chat call to a loopback ``endpoint`` (vLLM/SGLang).
    Not exercised by the default pipeline or the tests; it is the hook for richer,
    human-curated QA generation on the DGX Spark.
    """
    _assert_local(endpoint)
    import json
    import urllib.request

    facts = {
        "panel": model.panel.name,
        "voltage": model.panel.voltage,
        "circuits": len(model.circuits),
        "devices": model.device_count_by_kind(),
    }
    prompt = (
        "You are drafting visual Q&A pairs for an electrical drawing. Using ONLY these "
        f"ground-truth facts {json.dumps({k: (v if not isinstance(v, dict) else {kk.value: vv for kk, vv in v.items()}) for k, v in facts.items()})}, "
        "write 3 question/answer pairs as JSON list of {question, answer}."
    )
    payload = json.dumps(
        {"model": "local", "messages": [{"role": "user", "content": prompt}], "temperature": 0.2}
    ).encode()
    req = urllib.request.Request(
        endpoint, data=payload, headers={"Content-Type": "application/json"}
    )
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        data = json.loads(resp.read())
    content = data["choices"][0]["message"]["content"]
    drafted = json.loads(content)
    return [
        {"q_id": f"{model.id}-q-local-{i}", "question": qa["question"], "answer": qa["answer"]}
        for i, qa in enumerate(drafted)
    ]
