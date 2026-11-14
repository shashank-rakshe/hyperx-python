---
slug: /
title: What is Simthesizer?
sidebar_label: Introduction
---

# What is Simthesizer?

**Simthesizer** (_simulator_ + _synthesizer_) is an agent-driven simulation
framework for LLM serving systems. It ships one simulator that evolves: a
coding agent gets the representation and the process to extend it for the
serving system you care about.

It has two parts:

- **The framework.** Skills shipped in
  [`.agents/skills/`](https://github.com/casys-kaist/Simthesizer/tree/main/.agents/skills)
  take a natural-language feature request through specification, mapping,
  implementation, and validation. Requirements stay traceable, and fidelity is
  checked against independent observations such as real runs. See
  [Agent workflow](framework/agent-workflow.md).
- **The simulator.** A deterministic discrete-event simulator in Rust
  expresses the complete serving workflow, control decisions included, as one
  dynamic event graph. New mechanisms enter as graph nodes owned by
  components, so one shared simulator evolves instead of being rewritten. See
  [Simulator overview](simulator/overview.md).

## What it simulates

The native input is an **agent workload**: each request is a DAG of LLM calls
and tool calls, with think time between them. The output repeats that DAG and
adds per-token latency to every LLM call.

Compute costs come from per-layer latency tables profiled with vLLM on real
hardware. Communication costs come from a flow-level network model. Simulating
needs no GPU.

## Where to go next

- [Install](getting-started/installation.md) the toolchain.
- [Run the quickstart](getting-started/quickstart.md) to simulate, profile, and
  validate.
- [Read the paper](https://arxiv.org/abs/2608.24650).
