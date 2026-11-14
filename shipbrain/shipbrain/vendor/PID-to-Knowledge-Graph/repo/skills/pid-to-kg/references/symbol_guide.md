# Symbol guide: drawing symbols → `kind`

This guide maps common P&ID symbols (ISO 10628, ISA and typical company practice) to the `kind` vocabulary. When a drawing has a legend sheet, the legend wins. Unrecognised symbols: use the closest kind, put the printed description in `name`, and lower `confidence`.

## Equipment (`equipment[].kind`)

| Symbol | `kind` |
|---|---|
| Vertical cylinder with flat or dished heads, open or closed top | `tank` (atmospheric) or `vessel` / `pressure_vessel` (closed, rated) |
| Tank with agitator (impeller shape on a shaft) | `agitated_tank` (or `reactor` if labelled) |
| Circle with a tangential outlet (volute) | `centrifugal_pump`. Use `slurry_pump`, `sump_pump` or `metering_pump` when labelled. A pump hanging into a sump is `sump_pump` |
| Circle with internal piston or diaphragm marks; "metering" or "dosing" label | `metering_pump` / `positive_displacement_pump` |
| Circle with a trapezoid or fan blades | `compressor`, `blower` or `fan` |
| Shell with tube passes, two circles overlapping, or a plate-pack symbol | `heat_exchanger` (or `cooler` / `heater`) |
| Tall vessel with trays or packing | `column` (`scrubber` if labelled) |
| Inverted cone (conical bottom), feed in at the side | `cyclone` / `hydrocyclone` |
| Large shallow circle or rectangle with rake/bridge; "thickener" or "clarifier" | `thickener` / `clarifier` |
| Inclined plates in a box (lamella) | `clarifier` |
| Rectangle with an inclined screw or a drum; "screen" | `screen` |
| Box with a diagonal (membrane/filter cartridge), filter press plates | `filter` / `membrane_filter` / `filter_press` |
| Rotating drum or ball shape; "mill" | `mill`; jaw/cone shapes are `crusher` |
| Belt or screw drawn between pulleys | `conveyor`; a hopper with a rotary or belt discharge is `feeder` |
| Open-topped box or V-hopper | `hopper` / `bin` / `box` (pump box, splitter box) |
| Pit drawn below grade | `sump`; earth embankment outline is `pond` |
| Static mixer (zig-zag inside a pipe section) | `static_mixer` |
| Dashed outline around several items labelled as a vendor package | `package_unit` |
| Sampler, UV unit, analyser shelter | `sampler`, `uv_unit`, `other` |
| Motor (circle with "M") drawn separately | `motor`, only when it is a tagged item on its own |

## In-line components (`components[].kind`)

| Symbol | `kind` |
|---|---|
| Two triangles tip to tip (bow-tie), plain | `gate_valve`, the default manual valve. Use `manual_valve` if the type is unclear |
| Bow-tie with a filled dot in the middle | `globe_valve` |
| Bow-tie with a circle in the middle | `ball_valve` |
| Bow-tie with a vertical line or disc in the middle | `butterfly_valve` |
| Bow-tie with a filled rectangle; "KGV"/"knife gate" | `knife_gate_valve` |
| Bow-tie with a curved top (weir) | `diaphragm_valve` |
| Plug symbol (bow-tie with a filled small rectangle) | `plug_valve` |
| Pinch valve symbol, or "PV"/"pinch" | `pinch_valve` |
| Bow-tie with one filled triangle, or a "Z"/arrow mark | `check_valve` |
| Bow-tie with an actuator (dome, box) and a tag from an instrument loop | `control_valve` (modulating) or `on_off_valve` (XV, shut-off) |
| Actuator marked "S" | `solenoid_valve` |
| Actuator marked "M" | `motor_operated_valve` |
| Three-port valve | `three_way_valve` |
| Angle valve with a spring (zig-zag) on top, discharging to a vent or drain | `relief_valve` (PSV/PRV) |
| Valve with an impulse line and no controller | `pressure_regulator` |
| Dish or curved line across the pipe, "RD" | `rupture_disc` |
| Y-shape or basket on the line | `strainer` |
| Trapezoid / cone on the line, "6x4" | `reducer` |
| Figure-8 shape | `spectacle_blind`; a single plate is `blind` |
| Wavy section, "hose" | `flexible_hose`; a bellows is `expansion_joint` |
| Small circle with window marks | `sight_glass` |
| Open-ended drain or vent with a valve, "DRAIN", "VENT" | `drain` / `vent` |
| Sample valve or "SP" | `sample_point` |
| Quick coupling, camlock | `quick_connect` |

## Not process items

Skip these, or record them only as notes:

- title block, revision table, stamps and approval text
- note boxes, unless they change meaning; then add them to `legend_notes`
- grid references and match lines
- equipment data tables (copy capacities into `attributes` of the matching equipment)
- electrical one-line elements, unless they drive process equipment
