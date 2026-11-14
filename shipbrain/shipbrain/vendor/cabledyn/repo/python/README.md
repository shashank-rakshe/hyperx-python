<!-- SPDX-License-Identifier: Apache-2.0 -->

# cabledyn: Python tools for CableDyn

`cabledyn` is for engineers who script CableDyn analyses. It runs the standalone
solver, reads and post-processes results, validates and edits input decks, runs
parameter studies, and couples to the solver in-process through the C interface.
The full reference is the
[Python chapter of the CableDyn manual](https://cabledyn.readthedocs.io/en/latest/python.html).

## Install

From PyPI (Python 3.10 or newer; NumPy is the only required dependency):

```powershell
py -m pip install cabledyn
py -m pip install "cabledyn[post]"   # adds pandas and matplotlib
```

The wheels for Windows x64, Linux x86-64 (both for processors with AVX2) and macOS
on Apple silicon carry the solver: the CableDyn shared library for the in-process
`CableDyn` class and the standalone driver that `CableDynDriver` and `cabledyn-run`
run. On another platform pip builds from the source distribution, which needs a
Fortran compiler and LAPACK.

The pure Python wheel attached to each
[GitHub release](https://github.com/SMI-Lab-Inha/CableDyn/releases/latest)
(`cabledyn-0.4.2-py3-none-any.whl`) carries no solver. `CableDynDriver` finds the
driver from an explicit path, then the `CABLEDYN_DRIVER` environment variable,
then the driver inside the package, then `PATH`; the in-process `CableDyn` class
uses the library inside the package, or one named by `CABLEDYN_LIBRARY` or found in
a source checkout's build tree.

## Components

| Component | Purpose |
|---|---|
| `CableDynDriver`, `cabledyn-run` | Run a deck, check completion, and read the output tables |
| `read_output`, `read_openfast_output`, `read_moordyn_output`, `read_moordyn_line`, `read_coupled_run`, `read_table` | Read CableDyn, OpenFAST (text and binary), and MoorDyn results |
| `TimeHistory`, `cabledyn-post` | Statistics, plots, spectra, coherence, rainflow fatigue, and CSV/TSV export |
| `compare_histories`, `resample`, `fft_filter`, `block_maxima`, `fit_gumbel`, `fit_weibull`, `line_geometry` | Run comparison, signal processing, extreme values, and line geometry |
| `DeckFile`, `DeckWriter`, `cabledyn-deck` | Validate, edit, and write decks, preserving comments and formatting |
| `generate_deck_cases`, `parameter_grid`, `run_study`, `cabledyn-study` | Generate and run parameter studies with hashed manifests |
| `CableDyn` | In-process coupling through the C interface |

## Example

```python
from cabledyn import CableDynDriver

driver = CableDynDriver(r"C:\CableDyn\CableDyn_driver.exe")
result = driver.run("model.dat", "results/baseline", timeout=600)

history = result.read_main()
print(history.statistics("FairTen1")[0])

fatigue = history.fatigue("FairTen1", start=600.0, stop=4200.0,
                          wohler_exponent=3.0, reference_frequency=1.0, bins=32)
print(fatigue.damage_equivalent_range)

profile = result.read_static()
profile.plot("Curvature", line_id=1)
```

A returned result is always a converged analysis: a failed solver step, timeout,
missing output, or malformed or non-finite data raises a typed exception. Existing
results are kept unless `overwrite=True`, and then restored if the new run fails.

Run a generated study from the command line:

```powershell
cabledyn-study generated\cases.json --executable C:\CableDyn\CableDyn_driver.exe `
  --output-directory generated\results --jobs 4 --channel FairTen1 --start 600 --stop 4200
```

`cabledyn-study` exits `1` if any case failed, `2` for an invalid manifest or
unsafe destination, and `3` if the cases ran but `study.json` or `summary.csv`
could not be written.

## Documentation

- [Python guide](https://cabledyn.readthedocs.io/en/latest/python.html)
- [Post-processing](https://cabledyn.readthedocs.io/en/latest/python_postprocessing.html)
- [API reference](https://cabledyn.readthedocs.io/en/latest/api_python.html)
- [Command-line tools](https://cabledyn.readthedocs.io/en/latest/cli.html)

Licensed under the Apache License 2.0.
