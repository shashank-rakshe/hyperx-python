psi - Pipe Stress Infinity, https://github.com/denisgomes/psi (GPL-3.0, Denis Gomes), copied as written from commit 840f24f
(the latest, 2023-05-02). Folders kept: psi (the program), examples, v&v, tests; docs, website and artwork left out.

Changes made by ShipBrain (nothing else is changed):
1. psi/loads.py (4 identical lines in Weight, Fluid, Seismic): `wxl, wyl, wzl = wl` became
   `wxl, wyl, wzl = (float(v) for v in np.ravel(wl))` - numpy 1.24 and later refuse one-element arrays inside a list
   assigned to an array column. Same numbers.
2. psi/reports.py: the report templates' `format` filter unwraps one-element arrays first - numpy 2 no longer formats
   them as numbers (psi keeps results as one-element arrays because of its units). Same numbers.
3. psi/data/materials.csv: A53A elastic modulus at 300 F was 274000000 psi (a typing error, ten times its neighbours
   27.7e6 and 27.0e6); it is now 27400000. psi reads the modulus only at the reference temperature (70 F by default).

How the changes were checked: unchanged psi was run on Python 3.11 with numpy 1.23.5, scipy 1.10.1, pint 0.9 (its
pinned versions) and OPENBLAS_CORETYPE=Haswell (the OpenBLAS bundled with numpy 1.23 returns wrong solutions on this
CPU without it - checked: the same matrix solved by scipy and numpy 2 gives the right answer). That reference passes
47 of psi's 48 tests (test_variable_spring fails in both). The changed copy on Python 3.13 / numpy 2.5 passes the
same 47 and prints the same numbers for every example and v&v input (only the sign of some zeros differs).

What psi does not have yet (its own state): bends (Bend raises NotImplementedError - corners are sharp joints between
runs), reducers, only one material (A53 grade A) and one code (B31.1-1967), one fluid (water).
