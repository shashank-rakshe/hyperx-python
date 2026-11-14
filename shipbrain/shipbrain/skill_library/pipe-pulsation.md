---
name: pipe-pulsation
description: piping pulsation and vibration: acoustic and structural natural frequencies against pump excitation (OpenPulse)
when: pulsation|acoustic (resonance|mode)|pipe vibration|piping vibration|natural frequenc\w* of (the |my |a )?pip|reciprocating (pump|compressor)|plunger pump
---
# Piping pulsation and vibration (pipe_pulsation)

For "pulsation", "acoustic resonance", "pipe vibration", "natural frequency of the pipe", reciprocating pump or compressor lines, call
`pipe_pulsation` (OpenPulse, GPL, copied in vendor/openpulse; mesh by ShipBrain's own 1D mesher - gmsh is never used).

Excitation frequencies - work them out from the user's words and pass them in excitation_hz:
- reciprocating (plunger / piston) pump or compressor: f1 = rpm / 60 x number of plungers (single acting); also check 2 x f1 and 3 x f1;
- centrifugal pump: vane passing = rpm / 60 x number of vanes; running speed rpm / 60;
- diesel or motor running speed rpm / 60 and its firing orders.
Keep at least 10 % separation (margin) between natural frequencies and excitation.

Ends: open_ends = the waypoints where the pipe opens into a tank, vessel, header or the sea (acoustic pressure about zero); a closed valve or a
pump with a closed check valve is a closed end. Supports: anchors / pinned / rests at the waypoints (default anchors at both ends).
Fix a resonance: acoustic - change a pipe length, add a volume bottle / pulsation damper or an orifice; structural - add or move a support (stiffer, shorter spans).
Say what it does not do: no water hammer (transient surge), no flow-induced damping, corners are sharp joints, end conditions idealised.
Checked: closed / open pipe modes n c / 2L and (2n-1) c / 4L, the wall correction of the speed of sound for water, corners connecting the fluid
column, and structural modes within 0.2 % of the exact Timoshenko beam (tests/test_pulsation.py).
