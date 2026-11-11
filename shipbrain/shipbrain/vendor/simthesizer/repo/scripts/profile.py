"""Measure vLLM component GPU time with Proton, preserving exact batch shapes."""

import argparse
import copy
import fnmatch
import gc
import importlib.util
import inspect
import itertools
import json
import math
import os
import statistics
import sys
import sysconfig
import tempfile
import time
import tomllib
from contextlib import ExitStack, contextmanager
from datetime import UTC, datetime
from functools import wraps
from pathlib import Path
from unittest.mock import patch

# This filename must not shadow the stdlib profile module imported by cProfile.
if __name__ == "profile":
    spec = importlib.util.spec_from_file_location(
        "profile", Path(sysconfig.get_path("stdlib")) / "profile.py"
    )
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    sys.modules["profile"] = module
elif __name__ == "__main__":
    sys.path[0] = str(Path(__file__).resolve().parent.parent)


def merge(base, overrides):
    result = copy.deepcopy(base)
    for key, value in overrides.items():
        result[key] = (
            merge(result[key], value)
            if isinstance(value, dict) and isinstance(result.get(key), dict)
            else copy.deepcopy(value)
        )
    return result


def values(value, *, minimum=0):
    items = value if isinstance(value, list) else [value]
    if not items or any(type(item) is not int or item < minimum for item in items):
        raise ValueError(f"expected integers >= {minimum}, got {value!r}")
    return items


def expand_batches(batches):
    """Each request group is a Cartesian grid; groups concatenate in listed order."""
    cases = []
    seen = set()
    for batch in batches:
        if set(batch) - {"requests", "routing"}:
            raise ValueError(
                f"unknown batch fields: {set(batch) - {'requests', 'routing'}}"
            )
        groups = []
        for group in batch["requests"]:
            if set(group) - {"count", "query", "context", "phase"}:
                raise ValueError(f"unknown request fields: {group}")
            combinations = []
            for count, query, context in itertools.product(
                values(group.get("count", 1), minimum=1),
                values(group["query"], minimum=1),
                values(group.get("context", 0)),
            ):
                phase = group.get(
                    "phase", "decode" if query == 1 and context else "prefill"
                )
                if phase not in {"prefill", "decode"}:
                    raise ValueError(f"unknown request phase: {phase}")
                if phase == "decode" and (query != 1 or context < 1):
                    raise ValueError("decode requires query = 1 and context >= 1")
                combinations.append(
                    [{"query": query, "context": context, "phase": phase}] * count
                )
            groups.append(combinations)
        if not groups:
            raise ValueError("a batch needs at least one request group")
        routing = batch.get("routing", {})
        for parts in itertools.product(*groups):
            requests = list(itertools.chain.from_iterable(parts))
            for counts in itertools.product(
                *(values(value, minimum=1) for value in routing.values())
            ):
                routes = dict(zip(routing, counts))
                key = json.dumps(
                    {"requests": requests, "routing": routes}, sort_keys=True
                )
                if key not in seen:
                    seen.add(key)
                    cases.append({"requests": requests, "routing": routes})
    if not cases:
        raise ValueError("no batches to profile")
    return cases


def load_receipt(path):
    with path.open("rb") as file:
        receipt = tomllib.load(file)
    unknown = set(receipt) - {
        "engine",
        "measure",
        "components",
        "repeat",
        "batches",
        "variants",
    }
    if unknown:
        raise ValueError(f"unknown receipt fields: {sorted(unknown)}")
    if not receipt.get("components") or not all(
        isinstance(name, str) and isinstance(selector, str)
        for name, selector in receipt["components"].items()
    ):
        raise ValueError("components must map names to module path patterns")
    measure = merge(
        {"warmup_seconds": 1.0, "samples": 5, "iterations": 3},
        receipt.get("measure", {}),
    )
    if set(measure) != {"warmup_seconds", "samples", "iterations"}:
        raise ValueError("unknown measurement fields")
    warmup = measure["warmup_seconds"]
    if not isinstance(warmup, (float, int)) or not math.isfinite(warmup) or warmup < 0:
        raise ValueError("warmup_seconds must be finite and nonnegative")
    for name in ("samples", "iterations"):
        values(measure[name], minimum=1)
        if type(measure[name]) is not int:
            raise ValueError(f"{name} must be an integer")
    receipt["measure"] = measure
    variants = receipt.get("variants", [{"name": "default"}])
    if not variants or len({variant["name"] for variant in variants}) != len(variants):
        raise ValueError("variants must have unique names")
    for variant in variants:
        if set(variant) - {"name", "engine"}:
            raise ValueError(f"unknown variant fields: {variant}")
    receipt["variants"] = variants
    return receipt, expand_batches(receipt["batches"])


def select_modules(runner, selectors):
    modules = {
        f"model.{path}".rstrip("."): module
        for path, module in runner.get_model().named_modules()
    }
    modules["sampler"] = runner.sampler
    selected = {}
    for name, selector in selectors.items():
        matches = {
            path: module
            for path, module in modules.items()
            if fnmatch.fnmatchcase(path, selector)
        }
        if not matches:
            raise ValueError(
                f"{name}: no module matches {selector!r}; available: {', '.join(modules)}"
            )
        selected[name] = matches
    return selected


def repeat_forward(original, count):
    signature = inspect.signature(original)
    if not {"hidden_states", "residual"} <= signature.parameters.keys():
        raise ValueError("repeated blocks must accept hidden_states and residual")

    @wraps(original)
    def forward(*args, **kwargs):
        bound = signature.bind(*args, **kwargs)
        bound.apply_defaults()
        for _ in range(count):
            result = original(*bound.args, **bound.kwargs)
            if not isinstance(result, tuple) or len(result) != 2:
                raise ValueError(
                    "repeated blocks must return (hidden_states, residual)"
                )
            bound.arguments["hidden_states"], bound.arguments["residual"] = result
        return result

    return forward


class ScopedCallable:
    def __init__(self, target, call):
        self.target = target
        self.call = call

    def __call__(self, *args, **kwargs):
        return self.call(*args, **kwargs)

    def __getattr__(self, name):
        return getattr(self.target, name)


@contextmanager
def component_scopes(runner, selected):
    import triton.profiler as proton

    owners = {}
    with ExitStack() as stack:
        for name, matches in selected.items():
            for path, module in matches.items():
                if id(module) in owners:
                    raise ValueError(
                        f"{path} is selected by both {owners[id(module)]!r} and {name!r}"
                    )
                owners[id(module)] = name
                original = module if path == "sampler" else module.forward

                def scoped(*args, _original=original, _path=path, **kwargs):
                    with proton.scope(f"component:{_path}", {"calls": 1}):
                        return _original(*args, **kwargs)

                if path == "sampler":
                    stack.enter_context(
                        patch.object(runner, "sampler", ScopedCallable(module, scoped))
                    )
                else:
                    stack.enter_context(patch.object(module, "forward", scoped))
        yield


@contextmanager
def force_routing(runner, routes, num_tokens):
    import torch
    from vllm.model_executor.layers.fused_moe.runner.moe_runner import MoERunner

    patched = set()
    counters = []
    with ExitStack() as stack:
        for selector, active in routes.items():
            selected = select_modules(runner, {selector: selector})[selector]
            layers = {
                id(layer): layer
                for module in selected.values()
                for layer in module.modules()
                if isinstance(layer, MoERunner)
            }
            if not layers:
                raise ValueError(f"{selector}: no MoERunner found")
            for layer in layers.values():
                if id(layer) in patched:
                    raise ValueError("routing selectors must not overlap")
                patched.add(id(layer))
                top_k = layer.moe_config.experts_per_token
                if (
                    not top_k
                    <= active
                    <= min(layer.moe_config.num_experts, num_tokens * top_k)
                ):
                    raise ValueError(
                        f"cannot route {num_tokens} tokens with top_k={top_k} to {active} experts"
                    )
                if layer.is_monolithic:
                    raise ValueError("forced routing requires a modular MoE backend")
                dtype = (
                    layer.routed_experts.quant_method.topk_indices_dtype or torch.int32
                )
                device = next(layer.parameters()).device
                ids = (
                    (torch.arange(num_tokens * top_k, device=device) % active)
                    .to(dtype)
                    .view(num_tokens, top_k)
                )
                weights = torch.full(
                    (num_tokens, top_k), 1.0 / top_k, device=device, dtype=torch.float32
                )
                calls = [0]
                counters.append(calls)

                def route(
                    hidden_states,
                    router_logits,
                    indices_type,
                    *,
                    input_ids=None,
                    _ids=ids,
                    _weights=weights,
                    _calls=calls,
                ):
                    if hidden_states.shape[0] != _ids.shape[0]:
                        raise ValueError("forced routing token count changed")
                    _calls[0] += 1
                    return _weights, _ids

                stack.enter_context(
                    patch.object(layer.router, "_compute_routing", route)
                )
        yield
        if any(calls[0] == 0 for calls in counters):
            raise RuntimeError("the model bypassed forced expert routing")


def make_batch(requests, runner):
    from vllm import SamplingParams
    from vllm.v1.core.sched.output import NewRequestData, SchedulerOutput

    if (
        len(requests) > runner.max_num_reqs
        or sum(request["query"] for request in requests) > runner.max_num_tokens
    ):
        raise ValueError("batch exceeds the engine's request or token budget")
    block_sizes = [
        group.kv_cache_spec.block_size
        for group in runner.kv_cache_config.kv_cache_groups
    ]
    block_starts = [0] * len(block_sizes)
    batch = SchedulerOutput.make_empty()
    batch.num_common_prefix_blocks = [0] * len(block_sizes)
    for index, request in enumerate(requests):
        query, context = request["query"], request["context"]
        total = query + context
        if total > runner.max_model_len:
            raise ValueError(f"query + context = {total} exceeds max_model_len")
        blocks = []
        for group, block_size in enumerate(block_sizes):
            start = block_starts[group]
            end = start + math.ceil(total / block_size)
            if end > runner.kv_cache_config.num_blocks:
                raise ValueError(
                    "batch exceeds allocated KV blocks; increase kv_cache_memory_bytes"
                )
            blocks.append(list(range(start, end)))
            block_starts[group] = end
        req_id = str(index)
        tokens = [1] * (context if request["phase"] == "decode" else total)
        batch.scheduled_new_reqs.append(
            NewRequestData(
                req_id=req_id,
                prompt_token_ids=tokens,
                prefill_token_ids=tokens,
                mm_features=[],
                sampling_params=SamplingParams(
                    temperature=0, ignore_eos=True, max_tokens=2
                ),
                pooling_params=None,
                block_ids=tuple(blocks),
                num_computed_tokens=context,
                lora_request=None,
            )
        )
        batch.num_scheduled_tokens[req_id] = query
    batch.total_num_scheduled_tokens = sum(batch.num_scheduled_tokens.values())
    return batch


def read_proton(data):
    """Proton stores exclusive kernel metrics; scope times include descendants."""
    components = {}

    def visit(node):
        metrics = node.get("metrics", {})
        elapsed = metrics.get("time (ns)", 0)
        kernels = metrics.get("count", 0)
        for child in node.get("children", []):
            child_time, child_kernels = visit(child)
            elapsed += child_time
            kernels += child_kernels
        name = node["frame"]["name"]
        if name.startswith("component:"):
            path = name.removeprefix("component:")
            row = components.setdefault(path, {"total_us": 0, "calls": 0, "kernels": 0})
            row["total_us"] += elapsed / 1000
            row["calls"] += metrics.get("calls", 0)
            row["kernels"] += kernels
        return elapsed, kernels

    total, _ = visit(data[0])
    return components, total / 1000


def describe_worker(worker, selectors):
    import torch
    import triton
    import vllm
    from vllm.v1.worker.gpu.model_runner import GPUModelRunner

    runner = worker.model_runner
    if not isinstance(runner, GPUModelRunner):
        raise TypeError("profiling requires vLLM 0.31's V2 GPU model runner")
    selected = select_modules(runner, selectors)
    props = torch.cuda.get_device_properties(runner.device)
    return {
        "rank": worker.rank,
        "device": {
            "name": props.name,
            "uuid": str(props.uuid),
            "memory_bytes": props.total_memory,
            "capability": [props.major, props.minor],
        },
        "versions": {
            "vllm": vllm.__version__,
            "torch": torch.__version__,
            "triton": triton.__version__,
            "cuda": torch.version.cuda,
        },
        "model_runner": f"{type(runner).__module__}.{type(runner).__name__}",
        "model_config": runner.model_config.hf_config.to_dict(),
        "attention_backends": sorted(
            {
                group.backend.get_name()
                for groups in runner.attn_groups
                for group in groups
            }
        ),
        "components": {
            name: {path: type(module).__name__ for path, module in matches.items()}
            for name, matches in selected.items()
        },
    }


def profile_worker(worker, case, receipt, repetitions):
    import torch
    import triton.profiler as proton
    from vllm.v1.outputs import AsyncModelRunnerOutput

    runner = worker.model_runner
    selected = select_modules(runner, receipt["components"])
    batch = make_batch(case["requests"], runner)
    measure = receipt["measure"]
    req_ids = set(batch.num_scheduled_tokens)
    execution_order = None

    def execute():
        nonlocal execution_order
        batch.finished_req_ids = getattr(worker, "_profile_requests", set())
        worker._profile_requests = req_ids
        output = runner.execute_model(batch)
        if output is None:
            if execution_order is None:
                actual = runner.execute_model_state.input_batch
                execution_order = [int(req_id) for req_id in actual.req_ids]
                for row, index in enumerate(execution_order):
                    request = case["requests"][index]
                    if (
                        actual.num_scheduled_tokens[row] != request["query"]
                        or actual.num_computed_tokens_np[row] != request["context"]
                        or bool(actual.is_prefilling_np[row])
                        != (request["phase"] == "prefill")
                    ):
                        raise RuntimeError(
                            "vLLM prepared a different batch than requested"
                        )
            output = runner.sample_tokens(None)
        if isinstance(output, AsyncModelRunnerOutput):
            output.get_output()

    with torch.inference_mode(), ExitStack() as stack:
        for selector, count in repetitions.items():
            for module in select_modules(runner, {selector: selector})[
                selector
            ].values():
                stack.enter_context(
                    patch.object(
                        module, "forward", repeat_forward(module.forward, count)
                    )
                )
        stack.enter_context(
            force_routing(runner, case["routing"], batch.total_num_scheduled_tokens)
        )
        if not getattr(worker, "_profile_cache_initialized", False):
            for cache in runner.kv_caches:
                cache.zero_()
            runner.req_states.last_sampled_tokens.fill_(1)
            worker._profile_cache_initialized = True

        execute()
        torch.cuda.synchronize()
        deadline = time.perf_counter() + measure["warmup_seconds"]
        while time.perf_counter() < deadline:
            execute()
        torch.cuda.synchronize()

        samples = []
        total_samples = []
        started = time.perf_counter()
        with tempfile.TemporaryDirectory(prefix="simthesizer-proton-") as tmp:
            session = proton.start(
                str(Path(tmp) / "profile"),
                context="shadow",
                data="tree",
                backend="cupti",
            )
            try:
                proton.deactivate(session, flushing=True)
                stack.enter_context(component_scopes(runner, selected))
                for sample in range(measure["samples"]):
                    proton.activate(session)
                    for _ in range(measure["iterations"]):
                        execute()
                    torch.cuda.synchronize()
                    proton.deactivate(session, flushing=True)
                    components, total_us = read_proton(proton.data.get(session, sample))
                    samples.append(components)
                    total_samples.append(total_us / measure["iterations"])
                    proton.data.advance_phase(session)
                    proton.data.clear(session, sample)
            finally:
                proton.finalize(session)

        rows = []
        for name, matches in selected.items():
            for path in matches:
                timings = []
                counts = []
                for sample in samples:
                    row = sample.get(path, {"total_us": 0, "calls": 0})
                    counts.append(row["calls"])
                    timings.append(
                        row["total_us"] / row["calls"] if row["calls"] else None
                    )
                observed = [timing for timing in timings if timing is not None]
                rows.append(
                    {
                        "name": name,
                        "path": path,
                        "calls_per_sample": counts,
                        "samples_us": timings,
                        "median_us": statistics.median(observed) if observed else None,
                    }
                )
        if not all(total > 0 for total in total_samples):
            raise RuntimeError("Proton recorded no GPU activity for a complete step")
        return {
            "rank": worker.rank,
            "execution_order": execution_order,
            "components": rows,
            "step_kernel_us": total_samples,
            "measurement_seconds": time.perf_counter() - started,
        }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("receipt", type=Path)
    parser.add_argument("--output", type=Path)
    parser.add_argument(
        "--model", help="Override engine.model, e.g. a local model directory"
    )
    parser.add_argument("--variant", help="Run one named engine variant")
    parser.add_argument("--limit", type=int, help="Run the first N batch shapes")
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Print expanded batches without loading vLLM",
    )
    args = parser.parse_args()
    receipt, cases = load_receipt(args.receipt)
    if args.limit is not None:
        if args.limit < 1:
            parser.error("--limit must be positive")
        cases = cases[: args.limit]
    variants = receipt["variants"]
    if args.variant:
        variants = [variant for variant in variants if variant["name"] == args.variant]
        if not variants:
            parser.error(f"unknown variant: {args.variant}")
    if args.dry_run:
        print(json.dumps({"variants": variants, "cases": cases}, indent=2))
        return
    if args.output is None:
        parser.error("--output is required")

    # Run profiling callbacks in the engine process.
    os.environ["VLLM_ENABLE_V1_MULTIPROCESSING"] = "0"
    import vllm
    from vllm.transformers_utils.config import get_config

    if not vllm.__version__.startswith("0.31."):
        raise RuntimeError(f"requires vLLM 0.31.x, found {vllm.__version__}")
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with args.output.open("x", encoding="utf-8") as output:

        def write(record):
            output.write(json.dumps(record) + "\n")
            output.flush()

        for variant in variants:
            engine = merge(
                {
                    "load_format": "dummy",
                    "enforce_eager": True,
                    "enable_prefix_caching": False,
                    "skip_tokenizer_init": True,
                    "generation_config": "vllm",
                },
                receipt["engine"],
            )
            engine = merge(engine, variant.get("engine", {}))
            if args.model:
                engine["model"] = args.model
            if not engine["enforce_eager"]:
                raise ValueError("component scopes require engine.enforce_eager = true")
            source = get_config(
                engine["model"],
                trust_remote_code=engine.get("trust_remote_code", False),
                revision=engine.get("revision"),
            )
            repetitions = {
                path: getattr(source, count) if isinstance(count, str) else count
                for path, count in receipt.get("repeat", {}).items()
            }
            for count in repetitions.values():
                if type(count) is not int or count < 1:
                    raise ValueError(
                        "repeat counts must be positive integers or source model config field names"
                    )
            llm = vllm.LLM(**engine)
            try:
                metadata = llm.collective_rpc(
                    describe_worker, args=(receipt["components"],)
                )
                write(
                    {
                        "type": "metadata",
                        "format_version": 1,
                        "measured_at": datetime.now(UTC).isoformat(),
                        "variant": variant["name"],
                        "metric": "inclusive GPU kernel time per component invocation, microseconds",
                        "engine": engine,
                        "repeat": repetitions,
                        "measure": receipt["measure"],
                        "workers": metadata,
                        "cuda_visible_devices": os.environ.get("CUDA_VISIBLE_DEVICES"),
                    }
                )
                for index, case in enumerate(cases):
                    started = time.perf_counter()
                    workers = llm.collective_rpc(
                        profile_worker, args=(case, receipt, repetitions)
                    )
                    write(
                        {
                            "type": "measurement",
                            "variant": variant["name"],
                            "case": index,
                            **case,
                            "workers": workers,
                            "wall_seconds": time.perf_counter() - started,
                        }
                    )
                    print(
                        f"{variant['name']} {index + 1}/{len(cases)}: {time.perf_counter() - started:.2f}s",
                        file=sys.stderr,
                        flush=True,
                    )
            finally:
                llm.llm_engine.engine_core.shutdown()
                del llm
                gc.collect()
        write({"type": "complete", "cases": len(cases), "variants": len(variants)})


if __name__ == "__main__":
    main()
