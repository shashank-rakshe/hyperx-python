"""Replay single-LLM requests through vLLM and record client-visible token times."""

import argparse
import asyncio
import hashlib
import json
import os
import time
import tomllib
from datetime import UTC, datetime
from pathlib import Path


def load_workload(path):
    requests = [
        json.loads(line) for line in path.read_text().splitlines() if line.strip()
    ]
    ids = set()
    for request in requests:
        subs = request["sub_requests"]
        if (
            len(subs) != 1
            or subs[0]["kind"] != "llm"
            or subs[0]["next"]
            or request["initial"] != [0]
            or subs[0].get("interval", 0)
            or subs[0].get("kv_tokens", 0)
        ):
            raise ValueError(
                "baseline requires fresh single-LLM requests without delays"
            )
        sub = subs[0]
        if (
            len(sub["input_token_ids"]) != sub["input_tokens"]
            or sub["input_tokens"] < 1
            or sub["output_tokens"] < 1
            or request["arrival_time"] < 0
            or request["request_id"] in ids
        ):
            raise ValueError("invalid request lengths, arrival time, or duplicate ID")
        ids.add(request["request_id"])
    if not requests:
        raise ValueError("empty workload")
    return requests


async def replay(engine, requests):
    from vllm import SamplingParams
    from vllm.sampling_params import RequestOutputKind

    async def request_one(request, epoch, prefix):
        sub = request["sub_requests"][0]
        arrival = epoch + request["arrival_time"]
        await asyncio.sleep(max(0.0, arrival - time.perf_counter()))
        last = arrival
        latencies = []
        params = SamplingParams(
            temperature=0,
            ignore_eos=True,
            max_tokens=sub["output_tokens"],
            detokenize=False,
            output_kind=RequestOutputKind.DELTA,
        )
        async for output in engine.generate(
            prompt={"prompt_token_ids": sub["input_token_ids"]},
            sampling_params=params,
            request_id=f"{prefix}{request['request_id']}",
        ):
            count = sum(len(completion.token_ids) for completion in output.outputs)
            if count:
                now = time.perf_counter()
                latencies.extend([(now - last) / count] * count)
                last = now
        if len(latencies) != sub["output_tokens"]:
            raise RuntimeError(
                f"request {request['request_id']} did not finish all tokens"
            )
        return {**request, "sub_requests": [{**sub, "token_latency": latencies}]}

    for size in (1, engine.vllm_config.scheduler_config.max_num_seqs):
        warmup = [
            {
                "request_id": index,
                "arrival_time": 0,
                "sub_requests": [{"input_token_ids": [1] * 64, "output_tokens": 8}],
            }
            for index in range(size)
        ]
        epoch = time.perf_counter()
        await asyncio.gather(
            *(request_one(row, epoch, f"warmup-{size}-") for row in warmup)
        )
    epoch = time.perf_counter()
    results = await asyncio.gather(
        *(request_one(row, epoch, "run-") for row in requests)
    )
    return results, time.perf_counter() - epoch


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", type=Path, required=True)
    parser.add_argument("--workload", type=Path, required=True)
    parser.add_argument("--output-jsonl", type=Path, required=True)
    parser.add_argument("--model", help="Override the model with a local directory")
    args = parser.parse_args()
    config = tomllib.loads(args.config.read_text())["engine"]
    if args.model:
        config["model"] = args.model
    requests = load_workload(args.workload)
    if any(
        row["sub_requests"][0]["input_tokens"] + row["sub_requests"][0]["output_tokens"]
        > config["max_model_len"]
        for row in requests
    ):
        raise ValueError("workload exceeds max_model_len")
    args.output_jsonl.parent.mkdir(parents=True, exist_ok=True)
    metadata_path = args.output_jsonl.with_suffix(".meta.json")
    if args.output_jsonl.exists() or metadata_path.exists():
        raise FileExistsError("baseline output already exists")

    import torch
    import vllm
    from vllm.engine.arg_utils import AsyncEngineArgs
    from vllm.v1.engine.async_llm import AsyncLLM

    engine = AsyncLLM.from_engine_args(AsyncEngineArgs(**config))
    try:
        results, seconds = asyncio.run(replay(engine, requests))
    finally:
        engine.shutdown()
    with args.output_jsonl.open("x") as output:
        for row in results:
            output.write(json.dumps(row) + "\n")
    props = torch.cuda.get_device_properties(0)
    metadata = {
        "measured_at": datetime.now(UTC).isoformat(),
        "engine": config,
        "device": {
            "name": props.name,
            "memory_bytes": props.total_memory,
            "uuid": str(props.uuid),
        },
        "cuda_visible_devices": os.environ.get("CUDA_VISIBLE_DEVICES"),
        "versions": {"vllm": vllm.__version__, "torch": torch.__version__},
        "workload_sha256": hashlib.sha256(args.workload.read_bytes()).hexdigest(),
        "requests": len(results),
        "wall_seconds": seconds,
        "metric": "client-visible token intervals from scheduled arrival; coalesced tokens split evenly",
    }
    with metadata_path.open("x") as output:
        json.dump(metadata, output, indent=2)
    print(f"Completed {len(results)} requests in {seconds:.3f}s")


if __name__ == "__main__":
    main()
