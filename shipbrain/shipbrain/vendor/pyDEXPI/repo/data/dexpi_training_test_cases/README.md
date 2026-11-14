# DEXPI TrainingTestCases (DEXPI 1.3 reference solutions)

The 35 XML files in this directory are the *verified reference solutions* from the DEXPI
project's public example corpus, vendored unchanged.

| | |
|---|---|
| Upstream | <https://gitlab.com/dexpi/TrainingTestCases> |
| Upstream path | `dexpi 1.3/example pids/<case>/` |
| Pinned commit | `a23d61e2e089eb2ca464cd552f9ae580a2785963` (`master`) |
| Licence | [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/) |
| Attribution | The DEXPI initiative (<https://dexpi.org/>) |

## Why these files are vendored rather than pulled in as a submodule

`.github/workflows/main.yml` checks out with `actions/checkout` and passes no `submodules:`
input, so a submodule would land as an empty directory and the tests that read this corpus would
silently collect nothing on every CI run — the one failure mode a conformance corpus must not
have. Upstream's working tree is also ~25 MB, of which these XML files are under 1 MB; the
remainder is `.pptx`, `.svg`, `.html`, `.pdf` and spreadsheet artefacts that pyDEXPI has no use
for. CC BY 4.0 permits the redistribution, and the repository has neither `.gitmodules` nor LFS
today.

## These files are byte-identical to upstream

Do not reformat, re-indent or re-serialize them. They are inputs to
`tests/test_loaders/test_training_test_cases.py`, which pins per-file object counts, error
counts and graph sizes; rewriting the bytes would silently move those numbers and destroy the
comparison against upstream. `.gitattributes` marks them `-text` so end-of-line conversion cannot
touch them on a Windows checkout.

To re-verify or re-pin, fetch each `Upstream case` path below from the pinned commit and compare
the SHA-256.

## What the corpus is for

Each case isolates one feature, which is what makes the suite a coverage map rather than a single
opaque error total: `P01` is a pipe between two nozzles and nothing else, `E13`/`E14` are a tank
plus a plant hierarchy, and `I01`–`I15` walk instrumentation feature by feature. When a parser
change recovers data, exactly the affected rows move.

Note that several of these files legitimately exercise behaviour pyDEXPI does not yet support;
the expected values recorded in the test are current behaviour, not a statement that current
behaviour is correct.

## Contents

| File | Upstream case | Bytes | SHA-256 |
|---|---|---:|---|
| `C01V04-VER.EX01.xml` | `C01 DEXPI Reference P&ID` | 445,726 | `a2b172f04e0dcf9a…` |
| `C02V03-VER.EX02.xml` | `C02 Process Column (BASF)` | 157,666 | `dfe4323c18d018ca…` |
| `C03V04-VER.EX02.xml` | `C03 Piping (Equinor)` | 68,507 | `a1c892f3bc21338c…` |
| `E01V02-VER.EX01.xml` | `E01 Tank` | 4,610 | `654c73ecd3eff689…` |
| `E02V02-VER.EX01.xml` | `E02 Tank with Nozzles` | 12,280 | `8bdab30cfa079009…` |
| `E03V01-VER.EX01.xml` | `E03 Pump With Nozzles` | 3,113 | `a26bda5dda7d3b8b…` |
| `E04V01-VER.EX01.xml` | `E04 HeatExchanger With Nozzles` | 2,728 | `f40f8618b0f9a4e1…` |
| `E05V01-VER.EX01.xml` | `E05 Pump With Nozzles And HeatExchanger With Nozzles` | 3,978 | `4e899b13e7eac2a1…` |
| `E06V01-VER.EX01.xml` | `E06 Pump, HeatExchanger, Nozzles Connected With PNS` | 6,288 | `2a6b4762cd1c85c9…` |
| `E07V01-VER.EX01.xml` | `E07 PressureVessel with ColumnSections` | 5,175 | `04ba63b74b4d9086…` |
| `E08V01-VER.EX01.xml` | `E08 ProcessColumn with ColumnSections` | 4,263 | `942d3e1e16308d92…` |
| `E09V01-VER.EX01.xml` | `E09 Tank with equipment bar` | 1,367 | `861ff607e401ed84…` |
| `E11V01-VER.EX01.xml` | `E11 Heat Exchanger with Chambers and Equipment Bar` | 4,650 | `0636399a6eb1f6fc…` |
| `E12V01-VER.EX01.xml` | `E12 Heat Exchanger with Chambers, Nozzles and Equipment Bar` | 11,286 | `edbe65f609085d7d…` |
| `E13V01-VER.EX01.xml` | `E13 Tank with Plant Structure Information` | 2,924 | `fde56b4547e3b00e…` |
| `E14V01-VER.EX01.xml` | `E14 Tank with Standard Plant Structure Information` | 3,588 | `8452c16b9f61cddb…` |
| `I01V01-VER.EX01.xml` | `I01 Measurement` | 4,918 | `fa9a947c0967f0fb…` |
| `I02V01-VER.EX01.xml` | `I02 Control` | 5,106 | `b3b8c59b7005e44e…` |
| `I03V01-VER.EX01.xml` | `I03 Measurement and Control` | 7,212 | `850f7d12e880b576…` |
| `I04V01-VER.EX01.xml` | `I04 Measurement and Control` | 7,477 | `91b301bad8f432fe…` |
| `I05V01-VER.EX01.xml` | `I05 Two flow indications and flow ratio control in CCR` | 12,267 | `19cd0e7aef5238af…` |
| `I06V01-VER.EX01.xml` | `I06 CCR flow indication and high alarm, flow control, control valve` | 12,311 | `949b2bcf9bf42b75…` |
| `I07V01-VER.EX01.xml` | `I07 Local and CCR pressure indic., alarm and safety switch` | 9,990 | `921f13ffe2f02f50…` |
| `I08V01-VER.EX01.xml` | `I08 Local pressure indication, CCR pressure indication, alarms and switches` | 13,989 | `f8eea14847801264…` |
| `I09V01-VER.EX01.xml` | `I09 Measurement` | 4,134 | `b2a4bbf0ea128f7f…` |
| `I10V01-VER.EX01.xml` | `I10 Measurement` | 3,560 | `3fe1c132d83b4f5d…` |
| `I11V01-VER.EX01.xml` | `I11 Measurement` | 4,308 | `4f3b10c9eafe82cf…` |
| `I12V01-VER.EX01.xml` | `I12 Control` | 5,122 | `e6b2cfae50a272d4…` |
| `I13V01-VER.EX01.xml` | `I13 Measurement` | 7,321 | `20310c5d3cd076de…` |
| `I14V01-VER.EX01.xml` | `I14 Measurement` | 5,847 | `5968128b25264d16…` |
| `I15V01-VER.EX01.xml` | `I15 Measurement` | 6,339 | `d588226c734060b5…` |
| `P01V01-VER.EX01.xml` | `P01 Pipe FromTo Nozzles` | 3,684 | `1c88ab8aec8ac9d7…` |
| `P02V01-VER.EX01.xml` | `P02 Pipe From OPC to Nozzle` | 4,259 | `6084e2bbaba4f018…` |
| `P03V01-VER.EX01.xml` | `P03 Pipe With Edge` | 2,903 | `7c5b3ef54e709e5a…` |
| `P04V01-VER.EX01.xml` | `P04 Pipe With Intersection` | 4,651 | `535a01b3433bdceb…` |

35 files, 863,547 bytes total.
