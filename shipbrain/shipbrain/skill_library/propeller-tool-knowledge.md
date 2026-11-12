---
name: propeller-tool-knowledge
description: propeller repositories shared (MATLAB lifting line, OpenFOAM propeller template, CFD comparison) and what ShipBrain does instead
when: lifting.line propeller|propeller (cfd|openfoam|simulation)|MRF (zone|propeller)|propeller repos?
---
# Propeller - tool knowledge

Three propeller repositories were shared; none has a licence, so ShipBrain neither copies nor trains on them - private knowledge packs (for the owner's computer) hold their text:
- a MATLAB propeller analysis (no induced velocities, complete momentum theory, lifting-line theory with induction factors, a convergence test over the number of sections, a cavitation check);
- an OpenFOAM propeller template (pimpleFoam with an AMI rotating region, forces function for thrust and torque, a propeller of at most 0.2 m diameter);
- a CFD study of a 0.72 m propeller at 2 m/s inflow and 42 rad/s with OpenFOAM (MRF) and STAR-CCM+ (rigid body motion).
ShipBrain's own `propeller_bem` is a blade-element-momentum code written from the textbook method. For CFD of a propeller: the rotating-region approach (MRF for steady, AMI / sliding mesh for transient), thrust and
torque from the blade patch forces, J = V / (n D) swept by changing the inflow at fixed rpm. ShipBrain does not run that case: say so, and give the set-up advice.
