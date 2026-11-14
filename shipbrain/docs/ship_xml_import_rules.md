# Ship XML import rules (from the repository owner's CAD app)

These are the rules the CAD app applies when it imports a ship structure XML, so that the raw gaps (every part is drawn to the FACE of the part it butts into) are closed without moving the real positions of frames, decks and webs. Names of companies, hulls and parts were removed.


the CAD app - Ship XML Import Rules
Version: build 25 Sep 2026 14:50.  Code: the source file
1. Goal
The goal is an ideal FE surface model: natural connections (all edges blue/connected) without changing the real position of frames, decks and webs. The XML draws every part so it stops at the FACE of the part it butts into, so the raw import leaves gaps equal to a plate thickness. The rules below close those gaps. They apply the same way to every XML, with no special cases for particular part names.
Priority: web, frame and deck positions are fixed references. Everything else (flanges, faceplates, brackets) aligns to them.
2. What is NOT changed
Member dimensions from the XML are kept exactly (for example 375x12+150x20 stays 375 high, not 395).
<Offset> is never applied. PlateGroup Offset is ignored, so a Y=0 plate stays at Y=0 (previously it moved 6 mm).
Snipes, notches and corner arcs are kept exactly as drawn. FE idealisation (removing snipes) is switched OFF.
Part names and thickness suffixes ("[10mm]", "_Reflected") are kept after any move.
3. Import order (per panel)
Pre-scan the whole XML and register every panel (plane, plate thicknesses, Extent box), every stiffener web, every flange and every panel faceplate (thickness = FlatBar Width).
Boundary Limits of the panel: plate edges go to the referenced parts (ModelRef ObjType/CompType/CompId).
Decide whether to move the whole panel (Rule 9).
Build the plates, then close their thickness gaps (Rule 4).
Build the stiffeners (Root-V, far edge to flange, web onto frame).
Build the faceplates and brackets, then the bracket rules.
Write <xml name>_report.txt next to the XML, with the gap list and every rule that fired.
4. Rules
Rule 1 - Boundary Limits
When
A plate Boundary <Limit> references another part through ModelRef (Plate, Stiffener, Faceplate, Surface).
What it does
The plate edge moves onto the referenced part. ObjType, CompType and CompId must all match, so two parts with the same CompId but different types are never confused. Fixes on U and V are merged per axis, not added together.
Real case
Many panels. The CompType mix-up gave gaps equal to the faceplate thickness.
Report line
"Boundary-resolve limit=..", "Corner-extend key=..", "Centreline denomY=.."
Rule 2 - Corner slide along a sloped edge
When
A boundary fix moves a plate corner along one axis, and the other edge at that corner is sloped.
What it does
The corner slides ALONG the sloped edge instead of moving straight. The plate keeps its real straight-edge length and does not tilt.
Real case
PART-ID: 600 mm (was 599.869). PART-ID: 200 mm (was 198.2).
Report line
(no separate line: check the part dimension)
Rule 3 - Web onto frame
When
A stiffener web lies parallel to another panel plane on its material side, exactly its own web thickness away (+/-0.5 mm).
What it does
The web moves onto that plane, and its flange moves with it. Brackets attached to the web follow (Rule 11).
Real case
PART-ID: 793 -> 800 mm (as in the drawing).
Report line
"Web-onto-frame: target=.. delta=.. (web t=..)"
Rule 4 - Thickness-gap snap (the universal rule)
When
A straight edge of a plate, web, flange, faceplate or bracket meets all three conditions:  a) it is parallel to a neighbour panel plane that crosses its own plane (|n.W| <= 0.3);  b) the gap equals one of that neighbour's plate thicknesses, or the part's own thickness (+/-0.5 mm);  c) the snapped edge midpoint lies inside the neighbour panel's <Extent> box (+5 mm).
What it does
The edge moves onto the neighbour plane. Limits:  - members (web/flange/faceplate) move only their END edges; the root and section height are never changed;  - plates may target faceplates, but never their own panel's faceplate;  - the gap is measured at the final panel position (after Rule 9).
Real case
DER: LP0_11/ERB_5 13 mm, FR32_3/XYZ_6 24 mm, FR27_4/BGIR_2 50 mm, FR37_1/S3P 21 mm, FR37_7/S10P 12 mm, R_INN2_1 20 mm, 2BSP flange 21 mm, 25 mm flange gaps. In DER, 351 plate edges matched this rule.
Report line
"Edge-to-neighbour: target=.. gap=.. du=.. dv=.."
Rule 5 - Root-V (web root onto its plate)
When
The stiffener web root is not on its own panel plate.
What it does
If the web's far edge is already on another panel plane (anchored), only the root edge is stretched. Otherwise the whole web and its flange are translated together, and the height is kept.
Real case
Webs between two decks keep both ends. Free webs keep their XML height.
Report line
"Root-V key=.. delta=..", "Root-V STRETCH (far edge anchored) dv=.."
Rule 6 - Web far edge to Flange1
When
A T or L section: the web tip is not touching its flange.
What it does
The web extends only to the flange's NEAR face (delta = gap - flange thickness). If the gap is exactly the flange thickness, the flange moves onto the web tip instead, so the section height stays exact.
Real case
375x12+150x20 stays 375 (was 395). XYZ_12/S1P: the flange moves onto the web.
Report line
"Flange onto web tip: moved .."
Rule 7 - Web-panel snap
When
A stiffener with no own Flange or Faceplate has its web tip near a panel.
What it does
The web tip moves to the panel. This is switched off when the stiffener has its own flange or faceplate.
Real case
Prevents false moves on flanged stiffeners.
Report line
"Web-panel-snap: panel=.. delta=.."
Rule 8 - Panel faceplate flush
When
A panel faceplate is off its panel plate.
What it does
If the plate plane already crosses the faceplate strip (the strip touches the plate), the faceplate stays exactly as in the XML, so one-sided faceplates are kept. Only a strip lying completely off the plate is centred on it. The V-direction flush runs only when the faceplate runs along constant V (|u.v| <= 0.005), so cambered or sloped edges are not lifted.
Real case
ECS-B-Y5550_T1P (20/130 one-sided) is kept as authored (it was moved 55 mm). AFT-FR7_3 no longer jumps 91.7 mm in Z.
Report line
"Own-panel-flush delta=..", "FaceplaneReg .."
Rule 9 - Whole-panel move
When
The boundary fixes on one axis (U or V) are all the same shift, and nothing holds the far side on that axis (no other Limit on that axis references a part). Each axis is decided on its own.
What it does
The whole panel (plates, stiffeners, faceplates, brackets) moves as one rigid body along that axis instead of stretching the plate, so the plates keep their real XML size. The other axis keeps its normal thickness-gap extension. Later snaps measure at the moved position, so a gap is never counted twice.
Real case
PART-ID, PART-ID, PART-ID: 325 mm kept and on FR34 (were 339.5 = 325 + 12.5 plate + 2 clearance).
Report line
"Panel MOVED as a whole ..", "Panel MOVED along U/V (nothing holds the other side): .. mm"
Rule 9b - Cross-panel match uses corrected values
When
A Limit with no ModelRef is matched to a coplanar sibling panel’s anchored point.
What it does
The sibling’s CORRECTED position is used, not its raw XML value. A raw value that stops at a face is itself being corrected, so copying it would move the part the wrong way.
Real case
ECS-C-Y0_T1 Faceplate stays on its web at Z=41900 (it was pulled 12 mm down to Y0_T2’s raw top 41888).
Report line
"FaceplaneReg .. haveCrossFix=.."
Rule 10 - Bracket End1/End2 alignment
When
A bracket names End1/End2 parts (Stiffener web/flange, Faceplate or Panel).
What it does
Each end is aligned on its own (independent gates) to the web plane, the flange plane or the panel plane. Unresolvable panel-only ends refine to the nearest sibling stiffener or faceplate. A bracket lying IN its end stiffener's web plane skips the flange slide.
Real case
Y7300_1-7BP (+49.9) and H41C-LB16A-1BP (-24.35 into the stiffener) are fixed.
Report line
"Web key=..", "Flange key=.. skipped: bracket is in that stiffener web plane", "Sibling-refine .."
Rule 11 - Bracket follows moved members
When
The web or flange a bracket is attached to was moved by Rules 3, 5, 6 or 9.
What it does
The bracket follows the web's frame-line move. Every bracket vertex lying on the OLD plane of a moved flange or web moves onto the new plane, in the bracket's own plane, so the bracket stays attached without being distorted.
Real case
PART-ID follows its flange. 5BP follows its web.
Report line
"follows web .. frame-line move", "edge follows moved .. (n vertices, .. mm)"
Rule 12 - Name-preserving moves
When
Any rigid move (panel move, flange move, reflected instance).
What it does
The move is built into the geometry, so the tree keeps the real part name and thickness instead of showing "FACE".
Real case
PART-ID keeps its name and [mm] thickness.
Report line
-
5. Why the XML looks like this (AVEVA Marine TM-2102)
The XML comes from AVEVA Marine Planar Hull. Its training manual explains where the gaps come from:
AVEVA behaviour (manual section)
Effect in XML -> our rule
Each panel lies on its MOULD plane (UV plane of the panel CoordSys); plate thickness goes to one side (MaterialSide / Mside: TOP for decks, AFT for transverse, CL for longitudinal) (2.6.2, 5.2).
The panel plane is the FE mid/mould surface. Parts connect on planes, not on plate faces.
Intersecting-panel boundary with no displacement: the system picks the correct SIDE of the intersecting panel and follows its thickness steps (4.1.3.3).
Plates stop at the neighbour’s FACE, so gap = neighbour thickness -> Rule 4 (thickness-gap snap).
Parallel displacement from an intersecting panel is measured from the thickest plate (4.1.3.3).
Gap = thickness + displacement (e.g. 12.5 + 2 = 14.5 on FR34) -> Rule 9 moves the panel, the size is kept.
Plate Material "25,10": the plate is offset from the mould plane (5.2).
This is <Offset>. Ignored: the FE model stays on the mould plane.
Stiffener connection codes: welded hard in, lapped, or STOPPED SHORT (50, 100 mm ...) (7.6).
A stiffener end gap that is not a thickness can be a deliberate production clearance.
Stiffener material lies to the LEFT of the mould (trace) line (7.2).
The web plane is the trace line; web thickness goes to one side -> Rule 3 (web onto frame).
Welded flange (faceplate) can be symmetrical or UNSYMMETRICAL: "Hang" = hang-out in the -W direction (8.1).
One-sided faceplates are intended -> Rule 8 keeps them as authored.
Bracket leg A runs along the owning panel, leg B along the other; it normally lies in line with its profile (10.1).
A bracket in its stiffener’s web plane follows that web -> Rules 10 and 11.
Endcuts, notches, snipes and excess are production details; the model is shown "a perfect fit" (2.5, 7.7).
Snipes and notches are kept as drawn (user rule); excess is never in the XML geometry.
Panels valid P&S; separate P/S panels get suffix P / S (11.3). Reflected = starboard copy.
Instance Reflected is mirrored at Y=0, keeping the name (Rule 12).
6. Reading the report
<xml name>_report.txt lists the remaining gaps and every rule line above, one line per part.
"SUMMARY: moved N | extended M" gives the totals per part.
Some gap lines are expected and are not errors (for example real clearances and centreline half-thickness joints). Check the part in the model before treating a line as a bug.
7. Known open items
S5S knuckle gap.
Half-thickness centreline joints (32 cases in DER): not snapped yet.
FR15_1P-1P and FR15_UPP1P faceplate, 8L_UPP1S/S3S to FR15_UPP2S faceplate: waiting for your retest.
Size rounding (180.001, 279.919): part names needed.
