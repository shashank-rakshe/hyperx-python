"""
ShipBrain scorecard: realistic user requests, written by hand and NOT made by the training-data generators, to measure
whether the model understands what a user needs and drives the tools well - before and after training.

Categories:
  complete   all inputs given -> the right tool with the right key inputs
  messy      inputs in mixed units / shipyard shorthand / Hinglish / typos -> converted into the tool's units (mm, MPa, m3/h)
  missing    a key input is missing -> ask (a question, no tool call, no invented numbers)
  multi      a job of several steps -> the right FIRST step
  no_tool    a question of knowledge -> answer or search, without inventing numbers or calling a calculation tool

    python training/scorecard.py --write training/scorecard.jsonl            # (re)write the item file
    python training/scorecard.py --server http://127.0.0.1:8080 --out card.json
    python training/scorecard.py --local /kaggle/working/shipbrain_model/lora --out card_after.json
"""
import argparse, json, os, re, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))


def _items():
    I = []

    def add(cat, user, tool=None, args=None, tol=0.03, ask=False, no_tool=False):
        I.append({'id': f'{cat}-{len(I) + 1:03d}', 'category': cat, 'user': user,
                  'expect': {k: v for k, v in dict(tool=tool, args=args or {}, tol=tol, ask=ask, no_tool=no_tool).items()
                             if v not in (None, {}, False)}})

    # ------------------------------------------------------------ complete: everything given
    add('complete', 'Duplex plunger pump turning 360 rpm feeds a 88.9 x 5.5 mm seawater line going 3 m north and 2 m down into a header; supports at the bends - natural frequency and pulsation check', 'pipe_pulsation', {'od_mm': 88.9})
    add('complete', 'Need the flange width, web thickness and root radius for a HEA 260 rolled section from the standard tables', 'standard_part')
    add('complete', 'Across-flats and head height of a hexagon screw to ISO 4014, size M27, 90 mm long - from the standard, not memory', 'standard_part')
    add('complete', 'Which wall thickness and OD does NPS 12 schedule 40 pipe have in the ASME B36.10 table?', 'standard_part')
    add('complete', 'Slab 40 mm thick, k 2.1, internal heat 3e5 W/m3, faces held at 30 and 60 C: run a 1D finite volume solution with 16 cells and compare with the exact one', 'fvm_1d')
    add('complete', 'Finite volume check of a 1D convection diffusion problem, u 0.3 m/s, gamma 0.2, 25 cells, central scheme', 'fvm_1d')
    add('complete', 'Seawater at 0.8 m/s flows past a flexible rubber plate 500 mm high and 50 mm thick, clamped at its foot in a 1.2 m deep channel - fluid structure coupling, show me stress and deflection', 'elmer_flow')
    add('complete', 'CFD of a rigid plate 300 mm high in an oil flow of 0.01 m/s: pressure on the front and back faces and the drag', 'elmer_flow')
    add('complete', 'Run OpenFOAM for water at 1.5 m/s past bracket.step, then load the flow forces on the shell model and tell me the stress; fixed at x = 0', 'flow_load_stress')
    add('complete', 'OpenFOAM SST k-omega: seawater at 2 m/s past a plate 0.5 m high, 3D, 0.8 m wide - drag and Cd', 'openfoam_flow')
    add('complete', 'In the stress result of fls_fe.inp, what is the von Mises stress and displacement at x = 300, y = 0, z = 500 mm?', 'probe_result', {'x': 300, 'y': 0, 'z': 500})
    add('complete', 'Read me the pressure and velocity in the flow case my_flow at x = 1.2 m, y = 0.2 m, z = 0.025 m', 'probe_result', {'x': 1.2, 'y': 0.2, 'z': 0.025})
    add('complete', 'Set up the 1 m/s water flow past my plate 0.4 m high for ANSYS Fluent with SST turbulence - mesh and script please', 'cfd_export', {'target': 'fluent'})
    add('complete', 'Pontoon 36 m long, 10 m wide, 3.5 m deep, lightship 250 t with its centre of gravity 1.6 m above the keel, carrying 400 t at 1.1 m: what draft and what GM in sea water?', 'ship_hydrostatics', {'length': 36, 'beam': 10, 'depth': 3.5})
    add('complete', 'Is this barge stable? 28 x 7 x 3.2 m, 380 t total, KG 2.4 m, sits in a river', 'ship_hydrostatics', {'length': 28, 'beam': 7, 'depth': 3.2})
    add('complete', 'Generate a hull for me: 140 m long, 22 m beam, 12.5 m deep, 8.5 m draft, block coefficient 0.68, with a bulbous bow 4 m long', 'hull_generate', {'L': 140, 'B': 22, 'D': 12.5, 'T': 8.5, 'target_cb': 0.68})
    add('complete', 'I want 200 random ship hulls with Cb, Cp and LCB for a design study', 'hull_generate', {'samples': 200})
    add('complete', 'What power does a 130 m, 21 m beam, 7.8 m draft hull need at 15 knots? Block coefficient 0.7, entrance 0.3 L, run 0.25 L, depth 11 m', 'hull_resistance', {'L': 130, 'B': 21, 'T': 7.8})
    add('complete', 'Resistance of my 100 m x 16 m hull, 6 m draft, 9 m deep, at Froude numbers 0.18 and 0.24 by Holtrop', 'hull_resistance', {'L': 100, 'B': 16, 'T': 6})
    add('complete', 'I ran it in STAR-CCM+ and exported star_result.csv - what is the pressure at x = 0.5, y = 0.2, z = 0?', 'probe_result', {'x': 0.5, 'y': 0.2, 'z': 0})
    add('complete', 'Hot water header NPS 8 schedule 40 runs 10 m west, then 4 m south; fixed points at both ends; 120 C and 6 bar, full of water - check stresses to B31.1', 'pipe_stress', {'t_oper_c': 120})
    add('complete', 'Run the component based finite element analysis for a shear tab: IPE360 beam to a HEB300 column, four M20 8.8 bolts, 150 kN reaction', 'steel_cbfem', {'V': 150})
    add('complete', 'AISC check of a bolted extended end plate moment joint: beam W360X44, column W410X149, plate 300x550x32, four M30 A325 bolts at 140 gauge, 45 mm to the flanges, 6 mm web weld, 100 kN shear and 400 kN column axial, with a 25 mm stiffener', 'connection_check', {})
    add('complete', 'Lug plate with 6 bolts, 2 columns of 3, gauge 90 and pitch 80, M20 class 10.9, 150 kN carried 220 mm off the bolt centre - are the bolts alright?', 'bolt_group', {'d': 20})
    add('complete', 'Model a column foot for HEB260 with a 35 mm plate and M24 anchors', 'steel_connection', {'kind': 'base_plate'})
    add('complete', 'I want a bolted joint between two IPE330 beams, cover plates top, bottom and both sides of the web', 'steel_connection', {'kind': 'splice'})
    add('complete', 'Take bracket_layout.png, a thin pencil sketch, and give me single CAD lines along each stroke', 'trace_drawing', {'file': 'bracket_layout.png'})
    add('complete', 'Lay out a 114.3 mm OD pipe with 6 mm wall that runs 2 m aft, climbs 3 m and then goes 1.5 m to port', 'pipe_route', {'od': 114.3})
    add('complete', 'Check a 84 mm R3 studless chain, 700 m long, water depth 120 m, anchor 640 m from the fairlead', 'mooring',
        {'depth': 120, 'length': 700, 'radius': 640, 'd_mm': 84})
    add('complete', 'Mooring line: 76 mm R4 chain, 900 m, 200 m depth, anchor radius 820 m. Fairlead tension?', 'mooring',
        {'depth': 200, 'length': 900, 'radius': 820, 'd_mm': 76})
    add('complete', 'Plate 2400 x 800 x 12 mm under 0.05 MPa, clamped edges: stress and deflection by hand formula', 'plate_check',
        {'a': 2400, 'b': 800, 't': 12, 'q': 0.05})
    add('complete', 'Roark check: panel 3000 x 700, t 10, pressure 0.08 MPa, simply supported', 'plate_check',
        {'a': 3000, 'b': 700, 't': 10, 'q': 0.08})
    add('complete', 'Buckling stress of a 2800 x 800 x 14 plate field in compression along the long side, yield 355', 'plate_buckling',
        {'a': 2800, 'b': 800, 't': 14})
    add('complete', 'Section modulus of a flat bar 200 x 12 with 600 mm of 10 mm plating attached', 'section_props',
        {'profile.type': 'FlatBar', 'profile.h': 200, 'profile.t': 12, 't_plate': 10, 'b_eff': 600})
    add('complete', 'Stiffener check: HP 220x11, span 2400, spacing 700, plate 12 mm, pressure 0.06 MPa', 'stiffener_check',
        {'span': 2400, 'spacing': 700, 't_plate': 12, 'q': 0.06, 'profile.type': 'HP', 'profile.h': 220, 'profile.t': 11})
    add('complete', 'Tightening torque for an M20 8.8 bolt, thread friction 0.12', 'bolt', {'d': 20, 'cls': '8.8', 'mu_G': 0.12})
    add('complete', 'M16 class 10.9 bolt with 20 kN axial working load, load factor 0.2 - is it OK?', 'bolt',
        {'d': 16, 'cls': '10.9', 'F_A': 20000, 'Phi': 0.2})
    add('complete', 'Pressure drop for 120 m3/h seawater in 40 m of 125 mm bore pipe with 6 elbows', 'pipe_flow',
        {'flow_m3h': 120, 'segments.0.d_mm': 125, 'segments.0.length_m': 40, 'fluid': 'seawater'})
    add('complete', 'Ballast line 300 m3/h, 60 m of 200 mm bore rising 5 m: pump head?', 'pipe_flow',
        {'flow_m3h': 300, 'segments.0.d_mm': 200, 'segments.0.length_m': 60, 'segments.0.rise_m': 5})
    add('complete', 'MOOSE shell model of a 2000 x 800 x 12 mm plate at 0.1 MPa, simply supported', 'moose_plate',
        {'a': 2000, 'b': 800, 't': 12, 'q': 0.1})
    add('complete', 'Topology optimisation: bracket 500 x 400 mm welded on the left edge, 20 kN down at the bottom right corner, keep 40 %',
        'topology', {'L': 500, 'H': 400, 'volfrac': 0.4})
    add('complete', 'Convert my_bracket.sldprt to STEP', 'native_cad', {'file': 'my_bracket.sldprt'})
    add('complete', 'Open deck_block.3dm and tell me the solids and layers', ['native_cad', 'file_info'], {'file': 'deck_block.3dm'})
    add('complete', 'Trace the scanned drawing old_midship.png into DXF', 'trace_drawing', {'file': 'old_midship.png'})
    add('complete', 'Compare rev_A.dxf and rev_B.dxf and list what changed', 'compare_drawings', {'a': 'rev_A.dxf', 'b': 'rev_B.dxf'})
    add('complete', 'Element quality report for hold_model.bdf (Jacobian, warpage, aspect)', 'fe_quality', {'file': 'hold_model.bdf'})
    add('complete', 'Convert hold_model.bdf to Abaqus inp', 'fe_convert', {'file': 'hold_model.bdf'})
    add('complete', 'Make a STEP solid from the 3D scan impeller.stl and list its holes', ['reverse_cad', 'stl_to_step'], {'file': 'impeller.stl'})
    add('complete', 'Mesh the CAD model foundation.step with 50 mm elements', 'cad_mesh', {'file': 'foundation.step', 'element_size': 50})
    add('complete', 'What is in the file midship.bdf?', ['file_info', 'fe_quality', 'mesh_check'], {'file': 'midship.bdf'})
    add('complete', 'Hull girder check to IACS UR S11: L 180 m, B 30 m, Cb 0.8', 'class_rule', {'action': 'longitudinal', 'L': 180, 'B': 30, 'Cb': 0.8})
    add('complete', 'Find the DNV rule text on minimum bilge pipe diameter', 'class_rule', {'action': 'search', 'society': 'DNV'})
    add('complete', 'Build a stiffened deck panel 4800 x 3200 x 12 with FB 150x12 at 800 mm', 'panel_mesh',
        {'length': 4800, 'width': 3200, 'thickness': 12})
    add('complete', 'Repair pump_casing.step for FEA: remove holes under 10 mm and fillets under 5 mm', 'repair_model',
        {'file': 'pump_casing.step', 'holes_below': 10, 'fillets_below': 5})
    add('complete', 'Hot spot fatigue model of the bracket toe in bracket_assy.step', ['fatigue_mesh', 'file_info'])
    add('complete', 'Hex mesh the casting pump_foot.step with 4 mm cells', 'hex_mesh', {'file': 'pump_foot.step', 'size': 4})
    add('complete', 'I want a DXF of a 350 x 120 mm plate with one 25 mm hole in the centre', 'dxf_draw',
        {'parts.0.length': 350, 'parts.0.width': 120, 'parts.0.holes.0.d': 25, 'parts.0.holes.0.x': 175, 'parts.0.holes.0.y': 60})
    add('complete', 'Calculate 2 * pi * 0.35 * 1450 / 60', 'calc')
    add('complete', 'Lube oil line 20 m3/h, 30 m of 65 mm pipe, 4 bends, one globe valve - pressure loss?', 'pipe_flow',
        {'flow_m3h': 20, 'segments.0.d_mm': 65, 'segments.0.length_m': 30, 'fluid': 'lube oil'})
    add('complete', 'Mooring with 1 m/s current: 102 mm R3S chain, 1100 m line, 250 m depth, anchor 1000 m', 'mooring',
        {'depth': 250, 'length': 1100, 'radius': 1000, 'd_mm': 102, 'current': 1.0})
    # ------------------------------------------------------------ messy: units, shorthand, Hinglish, typos
    add('messy', 'plate 8 ft x 2.5 ft, 1/2 inch thick, 7 psi pressure - stress?', 'plate_check',
        {'a': 2438.4, 'b': 762, 't': 12.7, 'q': 0.0483}, tol=0.03)
    add('messy', 'Plate field 2.4 m x 0.8 m, 12 mm, tank head 6 m of seawater', 'plate_check',
        {'a': 2400, 'b': 800, 't': 12, 'q': 0.0603}, tol=0.05)
    add('messy', '2400x800x12 plate, 1.5 bar pressure, check karo', 'plate_check', {'a': 2400, 'b': 800, 't': 12, 'q': 0.15})
    add('messy', 'Bolt M24 grade 8.8, torque kitna lagega? friction 0.14', 'bolt', {'d': 24, 'cls': '8.8', 'mu_G': 0.14})
    add('messy', 'half inch UNC grade 5 bolt preload?', 'bolt', {'d': '1/2', 'cls': '5'})
    add('messy', 'chain 3 inch R3, depth 100 m, 650 m long, anchor 580 m', 'mooring', {'d_mm': 76.2, 'depth': 100, 'length': 650, 'radius': 580}, tol=0.02)
    add('messy', 'Anchor chain 84mm R3 in 400 ft water, 2200 ft line, anchor 2000 ft out', 'mooring',
        {'d_mm': 84, 'depth': 121.92, 'length': 670.56, 'radius': 609.6}, tol=0.02)
    add('messy', 'SW cooling 0.033 m3/s through DN125 x 40 m', 'pipe_flow', {'flow_m3h': 118.8, 'segments.0.d_mm': 125, 'segments.0.length_m': 40}, tol=0.05)
    add('messy', 'ballast pump 500 gpm, 8 inch pipe 50 m long. head loss?', 'pipe_flow', {'flow_m3h': 113.6, 'segments.0.d_mm': 203.2, 'segments.0.length_m': 50}, tol=0.05)
    add('messy', 'FW line 10 m3/hr, 2" pipe 25 m', 'pipe_flow', {'flow_m3h': 10, 'segments.0.d_mm': 50.8, 'segments.0.length_m': 25, 'fluid': 'fresh water'}, tol=0.05)
    add('messy', 'Stiffner FB150x12 span 2.4m spacing 600 plate 10 pressure 0.05 MPa', 'stiffener_check',
        {'span': 2400, 'spacing': 600, 't_plate': 10, 'q': 0.05, 'profile.type': 'FlatBar', 'profile.h': 150, 'profile.t': 12})
    add('messy', 'L 200x90x10/14 with 12mm plate b_eff 700 - I and Z?', 'section_props', {'profile.h': 200, 't_plate': 12, 'b_eff': 700})
    add('messy', 'T-bar web 300x12 flange 120x15, plate 14 x 750: section props', 'section_props',
        {'profile.type': 'TBar', 'profile.h': 300, 'profile.t': 12, 'profile.bf': 120, 'profile.tf': 15, 't_plate': 14, 'b_eff': 750})
    add('messy', 'brick mesh of shaft_seat.stp, element size 0.25 inch', 'hex_mesh', {'file': 'shaft_seat.stp', 'size': 6.35}, tol=0.02)
    add('messy', 'plate 10 inch by 5 inch with one 1 inch hole in the middle, make the drawing', 'dxf_draw',
        {'parts.0.length': 254, 'parts.0.width': 127, 'parts.0.holes.0.d': 25.4, 'parts.0.holes.0.x': 127, 'parts.0.holes.0.y': 63.5}, tol=0.02)
    add('messy', 'convert 4500 lbf.ft to kN.m', 'convert_units')
    add('messy', 'plate 2400 by 800 thk 12 under 0,05 MPa', 'plate_check', {'a': 2400, 'b': 800, 't': 12, 'q': 0.05})
    add('messy', 'MOOSE: 2.8m x 0.8m x 14mm, 2 bar, clamped all round', 'moose_plate', {'a': 2800, 'b': 800, 't': 14, 'q': 0.2})
    add('messy', 'Is 32 m3/h of MGO OK in a 1.5 inch line, 15 m?', 'pipe_flow', {'flow_m3h': 32, 'segments.0.d_mm': 38.1, 'segments.0.length_m': 15, 'fluid': 'mgo'}, tol=0.05)
    add('messy', 'Bracket 0.5 m x 0.4 m left edge welded 2 t load at tip, 40% material', 'topology', {'L': 500, 'H': 400, 'volfrac': 0.4})
    add('messy', 'bilge line 50 m3/h, 100NB pipe 30 m, 2 nrv + 4 bends', 'pipe_flow', {'flow_m3h': 50, 'segments.0.d_mm': 100, 'segments.0.length_m': 30}, tol=0.05)
    add('messy', 'plate 2400x800x12 load 50 kPa', 'plate_check', {'a': 2400, 'b': 800, 't': 12, 'q': 0.05})
    add('messy', 'M30 10.9 bolt preload with hydraulic tensioner', 'bolt', {'d': 30, 'cls': '10.9'})
    add('messy', 'Ek plate hai 3m x 0.75m, 11 mm, 8 m head - deflection batao', 'plate_check', {'a': 3000, 'b': 750, 't': 11, 'q': 0.0804}, tol=0.05)
    # ------------------------------------------------------------ missing: must ask
    add('missing', 'Check my anchor chain', ask=True)
    add('missing', 'What is the pressure drop in my ballast line?', ask=True)
    add('missing', 'Is my plate strong enough?', ask=True)
    add('missing', 'Tightening torque for my bolt?', ask=True)
    add('missing', 'Check the deck stiffener', ask=True)
    add('missing', 'What pump do I need for the cooling water?', ask=True)
    add('missing', 'Mooring line 84 mm R3 in 120 m water - fairlead tension?', ask=True)
    add('missing', 'Plate 2400 x 800 under 0.05 MPa - stress?', ask=True)
    add('missing', 'Convert the drawing to DXF', ask=True)
    add('missing', 'Compare the two revisions', ask=True)
    add('missing', 'Optimise my bracket shape', ask=True)
    add('missing', 'Run a MOOSE plate check at 0.1 MPa', ask=True)
    add('missing', 'Check the hull girder strength', ask=True)
    add('missing', 'Mesh it with 100 mm elements', ask=True)
    add('missing', 'I need a hexahedral mesh for my casting', ask=True)
    add('missing', 'Make a drawing of a stiffened deck panel', ask=True)
    add('missing', 'fuel line 30 m3/h ka pressure drop?', ask=True)
    add('missing', 'The discharge piping shakes when the pump runs, what is resonating?', ask=True)
    add('missing', 'Will my steam piping crack from heat growth?', ask=True)
    add('missing', 'I want the plastic strain and prying forces in my bolted joint', ask=True)
    add('missing', 'Verify the flexural steel of my concrete footing against the code', ask=True)
    add('missing', 'Does my gusset plate brace connection pass the AISC checks?', ask=True)
    add('missing', 'Give me the 3D model of a beam to column joint', ask=True)
    add('missing', 'Draw the 3D pipe between the pump and the tank for me', ask=True)
    # ------------------------------------------------------------ multi-step: the right first step
    add('multi', 'I uploaded deck_scan.png (old drawing). Make a vector copy and then compare it with deck_rev2.dxf',
        'trace_drawing', {'file': 'deck_scan.png'})
    add('multi', 'Take foundation.sldprt, convert it, mesh it with 40 mm elements and check the element quality',
        'native_cad', {'file': 'foundation.sldprt'})
    add('multi', 'Read hatch_cover.step, remove small holes below 8 mm, then mesh for FEA', ['file_info', 'repair_model'])
    add('multi', 'Check hold_model.bdf for quality problems and fix the duplicate nodes', ['fe_quality', 'mesh_check'], {'file': 'hold_model.bdf'})
    add('multi', 'Here is my scan part.stl - make a STEP and mesh it', ['reverse_cad', 'stl_to_step', 'file_info'], {'file': 'part.stl'})
    add('multi', 'Design the seawater cooling line for 120 m3/h: size the pipe and find the pump power. Route is 50 m with 8 bends.',
        'pipe_flow', {'flow_m3h': 120})
    add('multi', 'Convert block.3dm to STEP and then mesh the plates with 100 mm', 'native_cad', {'file': 'block.3dm'})
    add('multi', 'Check the plate 2400x800x12 at 0.05 MPa by hand and then with MOOSE shells', ['plate_check', 'moose_plate'],
        {'a': 2400, 'b': 800, 't': 12, 'q': 0.05})
    # ------------------------------------------------------------ no_tool: knowledge, no invented numbers
    add('no_tool', 'What is the difference between a web frame and an ordinary frame?', ['knowledge_search', None], no_tool=True)
    add('no_tool', 'Why do we use studless chain for offshore moorings?', ['knowledge_search', None], no_tool=True)
    add('no_tool', 'What does Jacobian ratio mean in a mesh quality check?', ['knowledge_search', None], no_tool=True)
    add('no_tool', 'Explain hot spot stress in simple words', ['knowledge_search', None], no_tool=True)
    add('no_tool', 'When is a pipe flow laminar?', ['knowledge_search', None], no_tool=True)
    add('no_tool', 'What is a lightening hole?', ['knowledge_search', None], no_tool=True)
    add('no_tool', 'Hi, what can you do?', [None], no_tool=True)
    add('no_tool', 'What is the difference between R3 and R4 chain grades?', ['knowledge_search', None], no_tool=True)
    return I


def _flat(d, p=''):
    out = {}
    if isinstance(d, dict):
        for k, v in d.items():
            out.update(_flat(v, f'{p}.{k}' if p else str(k)))
    elif isinstance(d, list):
        for i, v in enumerate(d):
            out.update(_flat(v, f'{p}.{i}' if p else str(i)))
    else:
        out[p] = d
    return out


ASK_WORDS = re.compile(r'\?|\b(please (give|tell|send|provide|share|upload)|which|what is the|could you|can you (give|tell|share)|need (the|to know))\b', re.I)


def score(item, reply):
    from shipbrain import agent
    e = item['expect']
    call = agent.parse_tool_call(reply)
    want = e.get('tool')
    wants = want if isinstance(want, list) else [want]
    out = {'id': item['id'], 'category': item['category'], 'got_tool': call['name'] if call else None}
    if e.get('ask'):
        out['ok'] = call is None and bool(ASK_WORDS.search(reply))
        return out
    if e.get('no_tool'):
        calc = call and call['name'] not in [w for w in wants if w]
        out['ok'] = not calc and len(reply.strip()) > 10
        return out
    out['tool_ok'] = bool(call) and call['name'] in wants
    out['args_ok'] = False
    if out['tool_ok']:
        got = _flat(call.get('args') or {})
        bad = []
        for k, v in (e.get('args') or {}).items():
            g = got.get(k)
            if isinstance(v, (int, float)) and not isinstance(v, bool):
                try:
                    if abs(float(g) - v) > max(1e-9, e.get('tol', 0.03) * abs(v)):
                        bad.append(k)
                except (TypeError, ValueError):
                    bad.append(k)
            elif str(v).lower() not in str(g).lower():
                bad.append(k)
        out['args_ok'] = not bad
        out['bad_args'] = bad
    out['ok'] = out['tool_ok'] and out['args_ok']
    return out


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument('--write')
    ap.add_argument('--items', default=os.path.join(HERE, 'scorecard.jsonl'))
    ap.add_argument('--server', default='http://127.0.0.1:8080')
    ap.add_argument('--model', default='local')
    ap.add_argument('--local')
    ap.add_argument('--out', default='scorecard_result.json')
    ap.add_argument('--limit', type=int, default=0)
    a = ap.parse_args(argv)
    if a.write:
        with open(a.write, 'w', encoding='utf-8') as f:
            for it in _items():
                f.write(json.dumps(it) + '\n')
        print(a.write, len(_items()), 'items')
        return
    sys.path.insert(0, HERE)
    from shipbrain import agent, knowledge
    from evaluate import LocalModel
    llm = LocalModel(a.local) if a.local else agent.LLM(a.server, a.model, temperature=0.0, max_tokens=500)
    import tempfile
    T = agent.Tools(tempfile.mkdtemp(), knowledge.load(None))
    items = [json.loads(l) for l in open(a.items, encoding='utf-8')]
    items = items[:a.limit] if a.limit else items
    res, t0 = [], time.time()
    for k, it in enumerate(items):
        try:
            sysmsg = {'role': 'system', 'content': agent.system_prompt(T, agent.PROMPT_COMPACT, question=it['user'])}   # as the app
            reply = ''.join(llm.stream([sysmsg, {'role': 'user', 'content': it['user']}]))
        except Exception as e:
            reply = f'ERROR {e}'
        r = score(it, reply)
        r['reply'] = reply[:400]
        res.append(r)
        print(f'{k + 1}/{len(items)} {time.time() - t0:.0f}s', end='\r')
    cats = {}
    for r in res:
        c = cats.setdefault(r['category'], {'n': 0, 'ok': 0})
        c['n'] += 1
        c['ok'] += bool(r['ok'])
    summary = {c: f"{v['ok']}/{v['n']} ({100 * v['ok'] / v['n']:.0f} %)" for c, v in sorted(cats.items())}
    allok = sum(v['ok'] for v in cats.values())
    summary['ALL'] = f"{allok}/{len(res)} ({100 * allok / max(1, len(res)):.0f} %)"
    json.dump({'summary': summary, 'items': res}, open(a.out, 'w'), indent=1)
    print()
    for k, v in summary.items():
        print(f'{k:10s} {v}')


if __name__ == '__main__':
    main()
