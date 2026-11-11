# Profiling

`scripts/profile.py` runs synthetic batches through vLLM's V2 model runner and
measures selected components with Triton Proton's CUPTI backend. The project's
`vllm` dependency group pins vLLM 0.31.0. Enter `devenv --profile vllm shell`
before running it with `uv run scripts/profile.py`.

## Receipt

`examples/profiles/llama3_1_8b.toml` contains a complete example.

- `engine` contains native `vllm.LLM` arguments. Defaults use dummy weights,
  eager execution, greedy sampling, and no prefix caching or tokenizer.
- `components` maps output names to glob patterns over module paths. Paths start
  at `model` (the runner's model); `sampler` selects the runner's callable sampler.
  A pattern can select multiple module instances. Each instance retains its path.
- Each `batches` entry concatenates request groups in order. `count`, `query`, and
  `context` accept integers or lists; lists form a Cartesian product. `context`
  counts cached tokens before this step. One query token with a nonempty context
  defaults to decode; other requests default to prefill. `phase` can explicitly
  select prefill for a one-token final chunk. Invalid budgets fail before timing.
- `measure` sets `warmup_seconds`, `samples`, and `iterations` per sample.
- `repeat` maps a block path to an integer or a source model configuration field.
  Blocks must accept `hidden_states` and `residual` and return that pair. Repeated
  calls carry both values forward. The example retains one decoder and uses the
  source model's depth, before `hf_overrides`, as its repeat count.
- Optional `variants` entries have a unique `name` and native `engine` overrides,
  recursively merged into the base engine arguments. This supports TP, dtype,
  quantization, and model-shape experiments without a separate scaling language.
  Native TP uses real GPUs; explicit `hf_overrides` measure altered local shapes
  and do not measure TP collectives.
- Optional `batches.routing` maps module patterns to active-expert counts or lists.
  Descendant `MoERunner` instances route token slots round-robin across those
  experts. This replaces top-k selection; gate projection and expert execution
  still run. Monolithic MoE backends cannot use this override.

`--dry-run` expands the batches without loading vLLM. `--model` selects a local
model directory; `--variant` and `--limit` restrict a run. Output paths must not
already exist.

## Measurement

Proton scopes surround component calls in the running model. Each sample reports
the sum of descendant GPU kernel durations divided by the scope's invocation
count. The final estimate is the median of those sample means. Nested scopes
overlap and must not be summed. An uncalled component has null timings; a called
component that launches no GPU work has zero time.

This measures eager GPU work, excluding CPU dispatch gaps. It does not measure
compiled fusion or CUDA graph replay latency. `step_kernel_us` includes all
recorded GPU kernels, including runner preparation; it is not elapsed step time.
GPU kernels on concurrent streams can overlap.

The V2 sampler reads sampling state from mapped host memory. Its timings can
vary substantially between processes, even with CPU and memory NUMA binding.
Treat sampler estimates separately from the more stable GEMM measurements.

Inputs and KV contents are synthetic. KV storage starts at zero, and request
state is recreated at the requested lengths for each iteration. The script
checks the runner's prepared lengths and prefill/decode flags before sampling.
`execution_order` records vLLM's reordering of the requested batch.

Repeating a resident block preserves its launch sequence and residual-norm mix,
but shares its weights and KV storage. Cross-layer cache-capacity effects remain
outside this experiment. Hardware, effective model configuration, and software
versions accompany the measurements.

## Output

JSONL contains metadata for each variant, one measurement per exact batch shape
and routing choice, and a final `complete` record. Each worker reports component
paths, invocation counts, all sample means in microseconds, and their medians.
A failed run leaves a partial file without `complete`.

Profiles live at `examples/data/<device>/<model>.jsonl`. Rust's `table_lookup`
reads these files directly; see [cost models](cost-models.md) for projection and
component mapping. CSV profiles are not supported by the simulator.

## Sources

- [vLLM 0.31 profiling](https://docs.vllm.ai/en/v0.31.0/contributing/profiling/)
- [V2 model runner](https://github.com/vllm-project/vllm/blob/v0.31.0/vllm/v1/worker/gpu/model_runner.py)
- [Proton integration](https://github.com/vllm-project/vllm/blob/v0.31.0/vllm/profiler/wrapper.py)
