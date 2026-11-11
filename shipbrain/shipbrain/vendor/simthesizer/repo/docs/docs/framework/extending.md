---
title: Extending the simulator
---

# Extending the simulator

The simulator is built so that the agent, or you, can add a mechanism without
touching the engine or editing a central list. These rules keep that true.

## Add a component

Every component trait (`System`, `Scheduler`, `Router`, `ModelRunner`,
`Model`, `ComputeSimulator`, `NetworkSimulator`) has its own registry beside
the trait. To add an implementation:

1. Implement the trait and `Module` (systems and runners also implement
   `LogicalHandler`), and derive `Deserialize` on the type itself, skipping
   runtime-only fields.
2. Register it under a new `kind`.
3. Select it from a scenario TOML with `kind = "<your kind>"`.

Registrations are collected at link time, so any crate that depends on the
core can add a `kind`. Never add a closed `match` over implementations.

## Add behavior

- New runtime work enters as **graph nodes**. No component advances time
  itself: it returns a latency or adds nodes.
- Express new semantics as **logical nodes** owned by a component, not as new
  node kinds.
- Build a new topology by **composing systems** through seeding and sinks
  before duplicating lifecycle code.
- A new parallelism axis is a **new runner**. Collectives stay point-to-point
  transfers joined by barriers.

## Add costs

- Price compute from profiles. Extend the profile rather than adding a formula
  fallback.
- A new cost needs a mechanism or an explicit config knob. Propose any proxy
  before implementing it.
- Model memory by allocating and reclaiming real blocks, not with capacity or
  hit-rate factors.

## Add a model

A new model gets its own `Model` implementation, built from its real
configuration, and its own profile on the target hardware. Never alias a
similar model. Each layer name must resolve to profile components, directly
or through the scenario's `components` map.

Source of truth:
[`ARCHITECTURE.md`](https://github.com/casys-kaist/Simthesizer/blob/main/ARCHITECTURE.md#evolution-rules).
