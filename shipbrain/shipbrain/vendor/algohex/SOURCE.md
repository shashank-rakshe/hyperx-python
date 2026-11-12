AlgoHex - https://github.com/cgg-bern/AlgoHex (AGPL-3.0; copyright David Bommes, see CREDITS), commit 27cd6e7e (2026-10-22).
Only its demo input (demo/HexMeshing/cylinder.ovm), LICENSE and CREDITS are copied here; the program itself is built from its
sources, unchanged, on GitHub's computers by .github/workflows/shipbrain-algohex.yml (the cloud sandbox cannot reach RWTH Aachen's
GitLab, where two of its libraries - CoMISo and libHexEx - are hosted, and ShipBrain does not fetch them from other places).
The workflow publishes the meshes and their quality as the release "algohex-latest". On a user's computer ShipBrain runs an AlgoHex
the user built (HexMeshing on the PATH or ALGOHEX_EXE) or its container image "algohex" (podman / docker build of its Dockerfile).
