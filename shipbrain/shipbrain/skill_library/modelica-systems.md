---
name: modelica-systems
description: OpenModelica equation-based system simulation, Modelica models, OMEdit, engine room and machinery system dynamics
when: modelica|openmodelica|omedit|omsimulator|equation.based|system dynamics|\.mo file|fmu\b|co.?simulation
---
# OpenModelica and Modelica system simulation

OpenModelica (AGPL-3.0, pack `OpenModelica`: user documentation, OMEdit, the test suite with many example models) is a free environment for Modelica: acausal, equation-based models of physical systems made of connected components.
- Typical ship uses: engine and shaft line dynamics, cooling and fuel systems, electrical power plant, HVAC, control loops, hybrid propulsion. Components are connected with physical connectors (flow and potential variables); the solver sorts the equations itself.
- A model is a `.mo` text file: `model Name ... equation ... end Name;` Simulate with OMEdit (the GUI) or `omc` scripts; export a co-simulation unit (FMU) to couple it with other tools (OMSimulator).
- ShipBrain does not run OpenModelica here: it helps to find the syntax and library components in the pack (cite the chunk ids), to write the model text, and to reason about the equations. For plain 1D flow with a finite-volume scheme use `fvm_1d`; for engine intake and exhaust waves see the `engine-1d-cfd` skill and the `OpenWAM` pack.
