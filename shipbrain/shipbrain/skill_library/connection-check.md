# Connection resistance checks to AISC 360 (connection_check)

For "is this connection OK / strong enough / does it pass" on four connection types, call `connection_check` (Osoconn, MIT, compiled once):
- shear_clip_angle: double clip angle shear connection (beam web to girder web or column)
- moment_end_plate: extended end plate moment connection (4 or 8 bolts, column stiffener / doubler plate)
- vertical_brace, horizontal_brace: gusset plate brace connections

The user writes plain words; YOU turn them into Osoconn keywords in `params` (the error text lists the allowed ones). Units: NEWTON_MM
(N, mm, MPa, bolts M20 M22 M24 M27 M30 M36, metric W shapes W310X74) or KIP_IN (kip, in, bolts 3/4 7/8 1 1_1/8, W14X30). Convert the user's kN to N.
Unstated materials: A36 steel, E70 welds, A325 bolts, E 200000 MPa - say so. Methods LRFD (default) or ASD.
If the result is NOT OK: name the governing check, change one thing that addresses it (thicker plate, one more bolt, larger weld) and run again.
Wrong or missing input: the tool returns Osoconn's message with the allowed values or the inputs not given: fix it or ask the user.
Not covered: Eurocode checks (only bolt shear to EN 1993-1-8 with `bolt_group`), other connection types, plate buckling, fatigue. Say so plainly.
`steel_connection` builds the 3D model and meshes of an end plate / fin plate / base plate / splice; it accepts AISC W shapes too (W310X74, W14X30).
