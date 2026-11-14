# Configuration and Registry Architecture

## Purpose

A scenario is one TOML tree that names every component and its parameters.
Hardware and serving parameters are required fields; the only policy default
is the round-robin router.

## Config Tree

- The root is `[system]`. Every polymorphic table carries a `kind` that selects
  a registered implementation; the remaining fields deserialize into that
  type, and unknown fields are rejected.
- Nesting mirrors ownership. A system owns its runner, model, and scheduler, or
  its child systems; a runner owns its compute and network simulators.
- Runtime state is never configured. It is built during initialization.

## Registries

- Each component trait (`System`, `ModelRunner`, `Model`, `Scheduler`,
  `Router`, `ComputeSimulator`, `NetworkSimulator`) declares its own registry
  and registration macro beside the trait.
- Registrations are collected at link time, so any crate that depends on the
  core can add a `kind` without editing it.
- Shared helpers extract `kind` and report errors; nothing holds a central list
  of kinds or registries.
- An unknown or duplicate `kind` fails deserialization.

## Lifecycle

1. **Deserialize** builds the component tree without side effects.
2. **Resolve paths** rewrites relative paths once, against the config file's
   directory. Each owner resolves its own fields and delegates to children.
3. **Initialize** runs top-down. A system reads the runner's parallel strategy,
   initializes the model with it, sizes the scheduler from the model, then
   initializes the runner, which loads profiles and registers its topology.
4. **Run** seeds the workload and starts the engine.

## Evolution Rules

- A new component implements its trait and `Module`, derives `Deserialize`,
  and registers a `kind`.
- A new trait-level registry is declared beside its trait with the shared
  helpers.
- Path fields are resolved during path resolution, never during initialization.
