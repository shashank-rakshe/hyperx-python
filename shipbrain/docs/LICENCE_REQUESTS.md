# Licence requests for repositories ShipBrain cannot use yet

These repositories have no licence file, so by default all rights are reserved and ShipBrain may not copy their code or data, publish them in its repository, or train on them (an educational purpose is not a
licence). Each is covered only by a private knowledge pack on the owner's own computer. Posting the short issue below on each repository asks the authors for a licence; when one is added
(MIT, Apache-2.0, BSD, GPL, LGPL, AGPL or CC0 for data are all usable here), ShipBrain can build the full pack and, where it fits, a working tool.

| Repository | What it is | What ShipBrain would do with a licence |
|---|---|---|
| https://github.com/noahbagz/ShipD | Ship-D: parametric hull generator and a 30,000-hull dataset with performance values | train and compare with the own hull generator (hullgen), a hull dataset for learning |
| https://github.com/shiplab/dbb | Design Building Block editor (blocks, hulls, hydrostatics, GZ, resistance, seakeeping) | knowledge pack, seakeeping and requirement checks |
| https://github.com/vsislab/ShipStructure | Ship landmark detection and recognition from images | knowledge pack (image tools) |
| https://github.com/davidemelozzi/Global-Ship-Hull-Structural-Analysis-Based-on-the-Finite-Element-Method | ANSYS command files for a global tanker hull model and a report | knowledge pack, worked example for the global hull skills |
| https://github.com/Ultravis66/marine-propeller-simulation | OpenFOAM (MRF) and STAR-CCM+ simulation of a 0.72 m marine propeller, with the STEP / STL geometry | knowledge pack, propeller CFD set-up |
| https://github.com/Andre-AH/OpenFOAM-propeller-simulation-template | OpenFOAM case template for a general propeller (pimpleFoam, AMI) | knowledge pack, case template for an OpenFOAM propeller tool |
| https://github.com/EirikSoevik/propeller-analysis | MATLAB propeller analysis: momentum theory, lifting line, cavitation | knowledge pack, compare with the own propeller_bem |
| https://github.com/zcstkhk/RhinoInside.NX | Rhino.Inside for Siemens NX: open Rhino geometry inside NX | knowledge pack (the Rhino / NX bridge) |
| https://github.com/theScriptingEngineer/NXOpen-CAE-python | NX Open Python scripts for CAE (meshing, loads, solutions) | knowledge pack, journal generator |
| https://github.com/gaoxifeng/Feature-Preserving-Octree-Hex-Meshing | feature-preserving octree hexahedral meshing (SIGGRAPH Asia) | knowledge pack, compare with the own hex mesher |
| https://github.com/Hazem-Kassab/Steel-Structures-Connections | steel connection calculations | knowledge pack, compare with steel_connection |
| https://github.com/CivilEngrTools/SteelConnDesign | steel connection design | knowledge pack |
| https://github.com/trevdna/BYU-Steel-Connection-Research | steel connection research code | knowledge pack |
| https://github.com/Cabji/steelCalc | steel calculators | knowledge pack |
| https://github.com/batiukmaks/Steel-Strength-Prediction | steel strength prediction | knowledge pack |

## Text to post as an issue

> Title: Please add a licence file
>
> Hello, and thank you for sharing this work. The repository has no licence, so by default nobody may reuse it. I would like to use it in an open-source, non-commercial educational ship-design
> assistant (ShipBrain). Could you add a licence file (for example MIT, Apache-2.0 or CC0 for data, or a copyleft licence such as GPL / LGPL if you prefer)? If you would rather keep it closed, that is
> fine too - just say so. Thank you.

For the shiplab repositories the same organisation already publishes `vesseljs` under MIT, so `dbb` may only be missing the file.
