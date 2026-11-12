Finite-Volume-Method-for-1D-CFD-Simulations - https://github.com/iammohith/Finite-Volume-Method-for-1D-CFD-Simulations (MIT, Mohith Sai Gorla).
The four scripts that were checked against exact solutions are copied unchanged in repo/. shipbrain/fvm1d.py runs a COPY of a script in Octave
with the input lines (k, A, L, n, Ta ...) replaced and the plot lines cut; the originals are never edited. oned_fin.m (ae(1) never set) and
oned_diffusion_convection_UpwindScheme.m (unfinished) are not copied: see skill fvm-1d.
