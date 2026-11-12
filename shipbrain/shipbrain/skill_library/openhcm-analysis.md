---
name: openhcm-analysis
description: what to do with an OpenHCM model: quantities, thickness checks, FE model, condition (corrosion) work
when: openhcm (analysis|check)|hull condition (analysis|assessment)|corrosion (margin|diminution)
---
# OpenHCM analysis

From an OpenHCM file ShipBrain can give counts, plate areas, steel mass, stiffener lengths, thickness list and compartments; with a mesh it can run the structural tools (mesh_check, analysis_run, show_result).
- Condition work: the format also carries measured / gauged thicknesses in the standard; ShipBrain reads the design thickness attribute only. Substantial corrosion assessment (diminution against class limits) needs the class
  rules (kept private) and the gauged data: ask for them, do not guess limits.
- A global or local FE check needs boundary conditions and loads the file does not hold: ask for the supports and the pressure / load case.
- Mass from plates alone excludes stiffeners, brackets and welds: say it.
