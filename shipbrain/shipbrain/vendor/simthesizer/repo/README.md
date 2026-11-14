<h1 align="center">Simthesizer</h1>

<p align="center">
  <strong>An agent-driven simulation framework for LLM serving systems.</strong>
</p>

<p align="center">
  <a href="https://arxiv.org/abs/2608.24650"><img alt="arXiv" src="https://img.shields.io/badge/arXiv-2608.24650-B31B1B?logo=arxiv&logoColor=white"></a>
  <a href="LICENSE"><img alt="License: MIT" src="https://img.shields.io/badge/License-MIT-blue.svg"></a>
  <img alt="Rust" src="https://img.shields.io/badge/Rust-stable-CE422B?logo=rust&logoColor=white">
  <img alt="Python" src="https://img.shields.io/badge/Python-3.14-3776AB?logo=python&logoColor=white">
  <img alt="No GPU required" src="https://img.shields.io/badge/simulation-no%20GPU%20required-2EA043">
</p>

<p align="center">
  <a href="https://arxiv.org/abs/2608.24650">Paper</a> |
  <a href="ARCHITECTURE.md">Architecture</a> |
  <a href="#-citation">Citation</a>
</p>

---

Simthesizer expresses the complete serving workflow, including the control
decisions that coordinate it, as one dynamic graph. A harnessed coding agent
lowers natural-language feature requests onto this graph under guardrails and
fidelity validation ([`.agents/skills/`](.agents/skills/)), evolving one shared
simulator instead of rewriting it for each new mechanism.

> [!NOTE]
> 🚧 Simthesizer v1 is in progress, with a better API and more accurate
> profiling. Stay tuned!

## 📰 News

- [2026/11] 🎉 Simthesizer is accepted to [HPCA 2027](https://hpca-conf.org/2027/).

## ⚙️ Requirements

| Task | Needs |
|---|---|
| Simulation | Rust stable |
| Profiling and baselines | [uv](https://docs.astral.sh/uv/), a GPU |

## 🚀 Run

```bash
cargo run --release -- \
  --config examples/scenarios/1xrtx-pro-6000--llama3_1_8b--realistic/simthesizer.toml \
  --workload examples/workloads/realistic.jsonl \
  --output-jsonl output/sim.jsonl
```

> [!TIP]
> No GPU needed. Output keeps the input DAG and adds per-token latency to each
> LLM call.

## 🎯 Profile and validate

```bash
# Profile kernel costs on a GPU
CUDA_VISIBLE_DEVICES=0 uv run --group vllm scripts/profile.py examples/profiles/llama3_1_8b.toml --output output/llama3_1_8b.jsonl

# Replay the workload on real vLLM
uv run --group vllm scripts/baseline.py --config <baseline.toml> --workload <workload.jsonl> --output-jsonl output/real.jsonl

# Compare and plot
uv run scripts/compare.py real=output/real.jsonl sim=output/sim.jsonl
uv run scripts/draw.py --output output/plot.png real=output/real.jsonl sim=output/sim.jsonl
```

See [ARCHITECTURE.md](ARCHITECTURE.md) for the design.

## 📄 Citation

```bibtex
@misc{simthesizer,
  title         = {Simthesizer: An Agent-Driven Simulation Framework for LLM Serving Systems},
  author        = {Kim, Wonung and Choi, Hyunmin and Kim, Minsu and Cho, Jaehong and Kim, Yeongwook and Park, Jongse},
  year          = {2026},
  eprint        = {2608.24650},
  archivePrefix = {arXiv}
}
```

## ⚖️ License

MIT. See [LICENSE](LICENSE).
