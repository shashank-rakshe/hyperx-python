# Awatif linear frame solver (vendored, unchanged)

From https://github.com/madil4/awatif (MIT, Copyright (c) 2025 Mohamed Adil), commit c962730396ba9cc61b09c588130251f24d9383c6.

- `lSolver.wasm`  Awatif's compiled C++/Eigen solver, exactly as built in the repo (`components/analysis/l-solver/cpp/built`)
- `lSolver.cpp`   its source
- `getLoads.ts`, `loads-data-model.ts`  how Awatif turns line loads into nodal loads and its ULS combination factors;
  `shipbrain/awatif.py` follows these rules when it prepares the input

ShipBrain runs the .wasm from Python with `wasmtime` (Apache-2.0): see `shipbrain/awatif.py`.
