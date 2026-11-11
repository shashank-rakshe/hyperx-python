<!-- SPDX-License-Identifier: Apache-2.0 -->

# Bergdahl dynamic mooring-chain experiment

This directory reproduces CableDyn's comparison with the 33 m dynamically scaled chain
experiment of Bergdahl et al. (2016), <https://doi.org/10.3390/jmse4010005>. No model parameter
is fitted to the measured force.

## Model and data

- Tables 7 and 8 of the article give the line properties and the mean cycle-maximum force for
  30 period-radius combinations.
- The article's CC BY 4.0 supplement gives the two unfiltered force histories used for the
  waveform comparison. The downloaded archive has SHA-256
  `e119e594e50d7ecf08b397b57b80fd48882484f220b00b4fee54c9cbafc2a254`; its `expData.dat` has
  SHA-256 `3ec499aef50a8b7d06fc2b75a3970e769df49ae4071e1f4c93ebd838f231db41`.
- The equivalent hydrodynamic diameter preserves the reported steel volume. The drag
  coefficients are translated so that the normal projected width and tangential wetted
  perimeter are preserved.
- The published contact modulus, damping and friction are mapped to the CableDyn seabed law.
- Each run has 12 motion cycles: a three-cycle smooth build-up, four settling cycles and the
  five assessed cycles.

## Reproduce

The primary calculation uses a 0.20 m nominal element length, a 0.0003125 s step and the default
dynamic Newton tolerance (relative 1e-8); [Time step](#time-step) explains the step. From the
repository root, with `path/to/cabledyn.exe` replaced by the release executable or a local
build, run all 30 conditions:

```powershell
python validation/experiments/bergdahl/prepare_bergdahl_cases.py `
  validation/experiments/bergdahl/work --element-length 0.20 --dt 0.0003125 `
  --cycles 12 --ramp-cycles 3

python validation/experiments/bergdahl/run_bergdahl_cases.py `
  path/to/cabledyn.exe validation/experiments/bergdahl/work --workers 4

python validation/experiments/bergdahl/reduce_bergdahl_cases.py `
  validation/experiments/bergdahl/work
```

For the refinement checks, repeat the three commands with `--period 1.25 --period 3.50
--radius 0.20` added to the preparation step and these settings:

| Check | Element length | Time step | Work directory |
| --- | ---: | ---: | --- |
| Coarse mesh | 0.40 m | 0.0003125 s | `work/h0p400_dt0p0003125` |
| Fine mesh | 0.10 m | 0.0003125 s | `work/h0p100_dt0p0003125` |
| Fine time step | 0.20 m | 0.00015625 s | `work/h0p200_dt0p00015625` |
| Coarse time step | 0.20 m | 0.000625 s | `work/h0p200_dt0p000625` |

Then write the refinement and waveform summaries:

```powershell
python validation/experiments/bergdahl/summarise_refinement.py
python validation/experiments/bergdahl/reduce_bergdahl_waveforms.py `
  validation/experiments/bergdahl/work path/to/expData.dat
```

`summarise_refinement.py` writes `refinement_summary.csv` and `refinement_summary.json` into this
directory. The other scripts write into `work/`: `case_manifest.json` (preparation),
`comparison_summary.csv` and `aggregate_metrics.json` (reduction), and the waveform CSVs and
`waveform_metrics.json`. The committed files of those names are copies of the `work/` outputs
of the primary run. `provenance.json` is written by hand after the run: it records the
executable and its SHA-256, the case counts, the refinement differences and the SHA-256 of each
committed summary file (`sha256sum`, or `Get-FileHash` in PowerShell).

## Results

`comparison_summary.csv`, `aggregate_metrics.json` and `provenance.json` hold the compact
results and the checksum of the executable used. The calculated force is `FairTen1`, the force
at the upper line end. Across the 30 conditions, the cycle maxima have an RMSE of 1.58 N, a
mean absolute percentage error of 3.11%, a mean bias of +0.47 N, a Pearson correlation of
0.993 and a Lin concordance coefficient of 0.989. For the two waveform
conditions, halving the nominal element length and the time step changes the mean cycle maximum
by no more than 0.29% and 0.27%, respectively. The phase-averaged force histories had RMSEs
of 5.93% and 2.56% of the measured force range with 0.3.0; that comparison was not rerun for
0.4.0, 0.4.1 or 0.4.2 (its waveform files and metrics are the 0.3.0 run's, `provenance.json`). The
0.4.1 and 0.4.2 reruns reproduce the 0.4.0 force maxima, metrics and refinement summaries byte for byte. The line's upper
end lies 0.3 m above the still-water level, so 0.4.0's dry weight of the part above the surface
changed the results: the RMSE from 1.583 N to 1.577 N and the mean absolute percentage
error from 3.13% to 3.11%. The waveform CSVs carry the measured phase averages computed from the
supplement's `expData.dat`.

## Time step

The chain's axial wave speed is c = (EA/m)^1/2 ≈ 350 m/s, so its 0.20 m segments carry axial
modes up to about 2c/l ≈ 3500 rad/s. The force maxima are snap loads, which converge in the
step only once the step resolves these modes, roughly dtM ≲ l/(2c) ≈ 0.29 ms (see "Snap loads
on slack lines" in the [modelling guide](https://cabledyn.readthedocs.io/en/latest/modeling.html)).
At a coarser step the maxima do not settle: at the T = 1.25 s, 0.20 m condition they are
68.7 N at 0.625 ms, against 68.1 N at 0.3125 ms and 67.9 N at 0.15625 ms (with 0.3.0,
72.2 N at 0.625 ms with every step taken as given, `off ei0_substeps`). At 0.3125 ms and below the step resolves the
axial wave over a 0.2 m segment, so the rotation- and snap-resolved sub-steps of
`ei0_substeps auto` take no part in the primary matrix (its results equal those taken as
given); the 0.1 m mesh at 0.3125 ms and the 0.625 ms step use them. Coarse steps also
leave the maxima sensitive to the Newton tolerance and to small changes in the solver's
iteration path. With 0.3.0, a 1.25 ms step and a relative tolerance of 1e-5, the five cycle maxima of
a condition have standard deviations of up to 1.6 N, their means are 2–15% above the converged
values, and the 30-condition RMSE is 3.7 N. At the 0.3125 ms step the standard deviation is at
most 0.19 N.
