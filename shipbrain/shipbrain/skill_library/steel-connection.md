---
name: steel-connection
description: steel connection 3D model and meshes from plain words: shear tab, column base, beam splice, extended endplate
when: (end|fin|base) ?plate|shear tab|beam splice|steel (connection|joint)|bolted joint.*(beam|column)
---
# Steel connections from plain words (steel_connection)

When the user describes a steel joint (end plate, fin plate / shear tab, base plate, beam splice), call `steel_connection`.
They never need CAD words: the model turns "IPE400 beam on a HEB300 column, extended end plate, M20 bolts" into the arguments.

Ask first if missing: the connection kind, the beam and/or column section (IPE / HEA / HEB or h, b, tw, tf in mm). Defaults for the rest:
bolt M20-8.8, plate thickness 20 (end plate) / 10 (fin plate) / 30 (base plate), beam 1000 mm, column 1500 mm, flush end plate (ext = 0).

What comes back: a STEP with every plate, bolt, weld a named part; a bill of parts with mass (`<name>_parts.csv`); EN 1993-1-8
spacing checks (edge 1.2 d0 ... 4t + 40, pitch 2.2 d0); clash checks between parts; and, when asked, meshes:
- mesh "shell": mid-surface all-quad mesh of the plates and the I-section walls (own mesher). Each bolt is a hole in both plates; the
  rim nodes of the two holes are tied (rigid shank). CalculiX input with supports and an end load (load_kn); solve = true runs it.
- mesh "hex": hexahedral meshes of the thick plates (end plate, base plate, ribs, cover plates), one input per part.

Say plainly: this is geometry, checks and meshes. It does NOT check the connection resistance (bolt shear, bearing, weld strength,
column web panel, ...): for the bolts use `bolt_group` (bolt group under shear and eccentric load, elastic and AISC instant-centre methods, bolt shear only) and `bolt` (one bolt: preload, fatigue); for the rest a code check or the user's own program. Contact between
plates is not modelled (bolts tie the plates; the base plate is supported in z by the concrete, with no uplift contact). Rolled section
root fillets are not modelled. A fin plate connection is nearly a pin: its FE deflection is much larger than a rigid-joint beam theory value.
IDEA StatiCa's connection library is proprietary and is NOT used.
