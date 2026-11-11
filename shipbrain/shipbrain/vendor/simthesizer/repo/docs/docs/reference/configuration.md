---
title: Configuration
---

# Configuration

A scenario is one TOML tree that names every component and its parameters.
Nesting mirrors ownership: a system owns its runner, model, and scheduler, or
its child systems, and a runner owns its compute and network simulators.

Every polymorphic table carries a `kind` that selects a registered
implementation. The remaining fields configure that implementation, and unknown
fields are rejected. Hardware and serving parameters are required, apart from
a few optional component fields such as `cudagraph_capture_sizes`. The only
policy default is the round-robin router.

## Example

The bundled single-GPU scenario
(`examples/scenarios/1xrtx-pro-6000--llama3_1_8b--realistic/simthesizer.toml`):

```toml
[system]
kind = "single_instance"

[system.model_runner]
kind = "ring"
tp = 1
link_bw = 1.0 # Unused at TP1.
link_latency = 0.0

[system.model_runner.compute_sim]
kind = "table_lookup"
perf_dir = "../../data/rtx-pro-6000/llama3_1_8b.jsonl"

[system.model_runner.compute_sim.components]
layernorm = ["input_norm", "post_attention_norm"]
qkv_projection = ["qkv"]
o_projection = ["output_projection"]
ffn1 = ["gate_up"]
act = ["activation"]
ffn2 = ["down"]
final_layernorm = ["final_norm"]

[system.model_runner.network_sim]
kind = "flow"

[system.scheduler]
kind = "chunked_prefill"
block_size = 16
max_batch = 32
max_num_batched_tokens = 2048
device_mem = 101976440832
device_mem_utilization = 0.9
enable_prefix_caching = false

[system.model]
kind = "llama3_1"
hidden_size = 4096
intermediate_size = 14336
max_position_embeddings = 131072
num_attention_heads = 32
num_hidden_layers = 32
num_key_value_heads = 8
vocab_size = 128256
```

Relative paths resolve against the config file's directory.

## Lifecycle

1. **Deserialize** builds the component tree without side effects.
2. **Resolve paths** rewrites relative paths once.
3. **Initialize** runs top-down. A system reads the runner's parallel strategy,
   initializes the model with it, sizes the scheduler from the model, then
   initializes the runner, which loads profiles and registers its topology.
4. **Run** seeds the workload and starts the engine.

## CLI

| Flag | Meaning |
|---|---|
| `--config PATH` | Scenario TOML |
| `--workload PATH` | Workload JSONL |
| `--output-jsonl PATH` | Result JSONL |
| `--output-engine-trace PATH` | Optional JSONL of component state over simulated time; must not already exist |

Source of truth:
[`architectures/configuration.md`](https://github.com/casys-kaist/Simthesizer/blob/main/architectures/configuration.md).
