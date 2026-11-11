<!-- SPDX-License-Identifier: Apache-2.0 -->

# Active-tension (`CtrlChan`) coupled comparison

This directory reproduces the coupled check of active line tension control in OpenFAST,
maintained by NLR (National Laboratory of the Rockies, formerly NREL). A ServoDyn controller
commands a mooring winch through cable-control channel 1, and the same model runs with CableDyn
(`CompMooring = 5`) and stock MoorDyn (`CompMooring = 3`) in one OpenFAST binary.

## Signal path

```text
ServoDyn cable-control DLL (libcabctrl.dll, avrSWAP 2601/2602)
  -> ServoDyn y%CableDeltaL / CableDeltaLdot
  -> FAST glue mapping (Custom_SrvD_to_CD)
  -> CableDyn u%DeltaL / DeltaLdot
  -> CD_AGG_Apply_LineControl  (last-segment unstretched-length modulation)
  -> fairlead/anchor tension response
```

Both runs load the same deterministic controller DLL, so the `DeltaL(t)` command is identical.
The platform is held at its settled equilibrium (still water, no wind or aerodynamics, locked
rotor), so the controlled line's tension response depends only on the mooring model.

## Files

| File | Role |
| --- | --- |
| [`../cable_control_dll/cabctrl_discon.f90`](../cable_control_dll/cabctrl_discon.f90) | Minimal Bladed-style ServoDyn DLL: ignores all sensors and drives a closed-form pay-out, hold, haul-in `DeltaL(t)` / `DeltaLdot(t)` schedule on channel 1 |
| [`author_activetension_model.py`](author_activetension_model.py) | Writes the model from a base UMaine coupled directory: `CONTROL` and `OUTPUTS` sections in both mooring decks, a cable-control-only ServoDyn input (`CCmode = 5`), a held-platform ElastoDyn input and the two `.fst` run decks |
| [`../openfast_activetension_ab.py`](../openfast_activetension_ab.py) | Scores the two `.out` files: tension setpoints at the pay-out and haul-in holds, and anchor tensions |
| [`tests/data/activetension_ab_reference.csv`](../../../tests/data/activetension_ab_reference.csv) | Reference results |

## Reproduce

Requirements: an `openfast.exe` built with the CableDyn integration
([`integration/openfast/`](../../../integration/openfast/README.md)), and an IEA-15MW UMaine
coupled model directory containing the still-water pair `Main_settle_cd5.fst` /
`Main_settle_md3.fst` and their inputs.

```bash
# 1. Build the controller DLL into the model directory
mkdir -p <model_dir>
gfortran -shared -O2 -static-libgcc -static-libgfortran \
    -o <model_dir>/libcabctrl.dll validation/scripts/cable_control_dll/cabctrl_discon.f90

# 2. Write the active-tension model files
python validation/scripts/activetension/author_activetension_model.py <model_dir> \
    --servodyn-template <a valid ServoDyn .dat>

# 3. Run both cases with the same executable
openfast.exe Main_at_cd5.fst      # CompMooring = 5, CableDyn
openfast.exe Main_at_md3.fst      # CompMooring = 3, stock MoorDyn

# 4. Score
python validation/scripts/openfast_activetension_ab.py Main_at_cd5.out Main_at_md3.out
```

## Command schedule

`DeltaL` and `DeltaLdot` are continuous on control channel 1:

| Stage | Window (s) | `DeltaL` | Effect on the controlled fairlead |
| --- | --- | --- | --- |
| baseline | 0–40 | 0 | steady pretension |
| pay out | 40–100 | 0 → +2 m (smoothstep) | segment lengthens → **lower** tension |
| hold | 100–160 | +2 m | steady lower setpoint |
| haul in | 160–220 | +2 → −1 m (smoothstep) | segment shortens → **higher** tension |
| hold | 220–260 | −1 m | steady higher setpoint |

## Result

At the holds, where `DeltaLdot = 0`, the tensions of CableDyn and stock MoorDyn agree to within
0.03 %. The tension changes from the baseline, which are the active-tension response, agree to
within **0.6 %** on the controlled fairleads and **0.7 %** on the anchors. Both codes report the
line-end force, and CableDyn's Newton static equilibrium and MoorDyn's dynamic relaxation give
the same baseline tension to within 0.03 %. During the pay-out and haul-in ramps the tensions
differ by at most **0.13 %** of the baseline tension on the controlled fairleads and **0.39 %**
on the anchors; the scorer gates this at 1 %. Before CableDyn kept the committed lengths in the
generalised-α step after a length change, the controlled fairleads had run up to 97 kN (4.1 %)
above MoorDyn during the pay-out and 148 kN (6.3 %) below it during the haul-in, while the holds
agreed as they do now.
