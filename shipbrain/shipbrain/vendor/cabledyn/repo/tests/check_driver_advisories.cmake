# SPDX-License-Identifier: Apache-2.0
# Driver advisories that do not stop a run:
#   * a prescribed motion that starts moving (a harmonic started at t = 0 is at its peak
#     velocity) prints a start-up shock note; one that starts from rest does not;
#   * a slack anchored line on a deck with no seabed (an OpenFAST MooringFile run
#     standalone) prints a no-seabed warning; a deck with a water depth does not;
#   * a dtM that resolves a line's axial period (2 x 410 m / sqrt(1.674e9 / 390) = 0.396 s) in
#     fewer than 6 steps prints the dtM advisory: 4.0 steps at 0.1 s, none at 0.05 s (7.9);
#   * a finite-EI cable whose grounded elements lock more than 15 % of the touchdown tension in
#     seabed friction prints the friction resolution note; a finer grounded mesh does not.
foreach(_required DRIVER WORK NO_SEABED_DECK SEABED_DECK)
  if(NOT DEFINED ${_required} OR "${${_required}}" STREQUAL "")
    message(FATAL_ERROR "check_driver_advisories: missing ${_required}")
  endif()
endforeach()

file(REMOVE_RECURSE "${WORK}")
file(MAKE_DIRECTORY "${WORK}")

function(run_driver label deck root out_var)
  execute_process(
    COMMAND "${DRIVER}" "${deck}" "${root}"
    WORKING_DIRECTORY "${WORK}"
    RESULT_VARIABLE _rc
    OUTPUT_VARIABLE _out
    ERROR_VARIABLE _err)
  if(NOT _rc EQUAL 0)
    message(FATAL_ERROR "check_driver_advisories: ${label} exit status ${_rc}, expected 0:\n${_out}${_err}")
  endif()
  set(${out_var} "${_out}${_err}" PARENT_SCOPE)
endfunction()

function(require_text label text needle)
  string(FIND "${text}" "${needle}" _pos)
  if(_pos LESS 0)
    message(FATAL_ERROR "check_driver_advisories: ${label} lacks '${needle}':\n${text}")
  endif()
endfunction()

function(forbid_text label text needle)
  string(FIND "${text}" "${needle}" _pos)
  if(_pos GREATER_EQUAL 0)
    message(FATAL_ERROR "check_driver_advisories: ${label} contains '${needle}':\n${text}")
  endif()
endfunction()

set(_deck_head [=[--------------------- CableDyn Input File ------------------------------------
Driver advisory check: held chain with a prescribed fairlead
--------------------- LINE TYPES ---------------------------------------------
TypeName Diam MassDenInAir EA BA EI Cd_n Cd_t Ca_n Ca_t
(-) (m) (kg/m) (N) (-) (N-m2) (-) (-) (-) (-)
chain 0.252 390.0 1.674e9 -1.0 0.0 1.37 0.64 1.0 0.0
--------------------- POINTS -------------------------------------------------
ID Type X Y Z
(-) (-) (m) (m) (m)
1 Fixed 400.0 0.0 -50.0
2 Coupled 0.0 0.0 0.0
--------------------- LINES --------------------------------------------------
ID NodeA NodeB Outputs
(-) (-) (-) (-)
1 2 1 -
--------------------- SECTIONS -----------------------------------------------
LineID LineType Length NumSegs
(-) (-) (m) (-)
1 chain 410.0 41
--------------------- OPTIONS ------------------------------------------------
50.0 WtrDpth
0.05 dtM
0.2 TMax
]=])
set(_deck_tail [=[--------------------- OUTPUTS ------------------------------------------------
FairTen1
--------------------- need this line ----------------------------------------
]=])

# 1 m heave at 1.904 rad/s: z = sin(omega t), vz = omega cos(omega t), tabulated to three
# decimals. The sine starts at its peak velocity; the second record starts from rest.
set(_times "0.00;0.05;0.10;0.15;0.20")
set(_z_sine "0.000;0.095;0.189;0.282;0.372")
set(_v_sine "1.904;1.895;1.870;1.827;1.768")
set(_sine "")
set(_rest "")
foreach(_k RANGE 0 4)
  list(GET _times ${_k} _t)
  list(GET _z_sine ${_k} _zs)
  list(GET _v_sine ${_k} _vs)
  string(APPEND _sine "${_t} 2 0.0 0.0 ${_zs} 0.0 0.0 ${_vs} 0.0 0.0 0.0\n")
  string(APPEND _rest "${_t} 2 0.0 0.0 0.000 0.0 0.0 0.0 0.0 0.0 0.0\n")
endforeach()
file(WRITE "${WORK}/sine.txt" "${_sine}")
file(WRITE "${WORK}/rest.txt" "${_rest}")
file(WRITE "${WORK}/sine.dat" "${_deck_head}sine.txt motionFile\n${_deck_tail}")
file(WRITE "${WORK}/rest.dat" "${_deck_head}rest.txt motionFile\n${_deck_tail}")

run_driver("sine start" "${WORK}/sine.dat" "${WORK}/sine" _sine_log)
require_text("sine start" "${_sine_log}" "Note: motionFile point 2 starts moving at 1.904 m/s")
require_text("sine start" "${_sine_log}" "Start the motion from rest")
run_driver("start from rest" "${WORK}/rest.dat" "${WORK}/rest" _rest_log)
forbid_text("start from rest" "${_rest_log}" "starts moving at")
forbid_text("start from rest" "${_rest_log}" "axial period")

string(REPLACE "0.05 dtM" "0.1 dtM" _coarse_head "${_deck_head}")
# the motion record on the coarser dtM grid
file(WRITE "${WORK}/coarse.txt" "0.0 2 0.0 0.0 0.000 0.0 0.0 0.0 0.0 0.0 0.0\n0.1 2 0.0 0.0 0.000 0.0 0.0 0.0 0.0 0.0 0.0\n0.2 2 0.0 0.0 0.000 0.0 0.0 0.0 0.0 0.0 0.0\n")
file(WRITE "${WORK}/coarse.dat" "${_coarse_head}coarse.txt motionFile\n${_deck_tail}")
run_driver("coarse dtM" "${WORK}/coarse.dat" "${WORK}/coarse" _coarse_log)
require_text("coarse dtM" "${_coarse_log}"
             "Note: LINE 1: dtM = 0.1000 s resolves its axial period of 0.396 s (twice its length over sqrt(EA/m)) in 4.0 steps, fewer than 6")
require_text("coarse dtM" "${_coarse_log}" "A dtM of at most 0.0660 s resolves them.")

run_driver("no seabed" "${NO_SEABED_DECK}" "${WORK}/no_seabed" _no_seabed_log)
require_text("no seabed" "${_no_seabed_log}" "below its Fixed anchor and the deck has no seabed")
require_text("no seabed" "${_no_seabed_log}" "for a standalone run add WtrDpth")
run_driver("seabed" "${SEABED_DECK}" "${WORK}/seabed" _seabed_log)
forbid_text("seabed" "${_seabed_log}" "WARNING")

# The seabed-friction resolution note: a lazy-wave cable whose grounded run has 10 m elements
# locks up to mu w L = 0.35 x 157.8 N/m x 10 m = 552 N per node, 46 % of the 1204 N tension at
# touchdown, and is told the grounded element length that resolves it; with 2.5 m elements
# (11 %, below the 15 % limit) it is not.
set(_friction_deck [=[--------------------- CableDyn Input File ------------------------------------
Driver advisory check: lazy-wave cable with seabed friction
--------------------- LINE TYPES ---------------------------------------------
Name Diam Mass EA BA EI GAs GJ Irt Irn Cdn Cdt Can Cat
(-) (m) (kg/m) (N) (-) (Nm2) (N) (Nm2) (kgm) (kgm) (-) (-) (-) (-)
bare 0.16 36.70 4.69e8 0.0 1.99e4 1.0e8 1.5e4 1.0 1.0 1.2 0.1 1.0 0.0
buoy 0.29 59.53 4.69e8 0.0 1.99e4 1.0e8 1.5e4 1.0 1.0 1.2 0.1 1.0 0.0
--------------------- POINTS -------------------------------------------------
ID Type X Y Z
(-) (-) (m) (m) (m)
7 Coupled 30.0 0.0 -20.0
8 Fixed 500.0 0.0 -200.0
--------------------- LINES --------------------------------------------------
ID NodeA NodeB Outputs
(-) (-) (-) (-)
4 7 8 -
--------------------- SECTIONS -----------------------------------------------
LineID LineType Length NumSegs
(-) (-) (m) (-)
4 bare 80.0 20
4 buoy 100.0 25
4 bare 420.0 42
--------------------- END CONNECTIONS ----------------------------------------
LineID End Stiffness EzX EzY EzZ TorsStiffness NxX NxY NxZ Pretwist
(-) (-) (N-m/rad) (-) (-) (-) (N-m/rad) (-) (-) (-) (deg)
4 A Rigid 0.1058 0 -0.9944 Free 0 1 0 0
4 B Rigid 1 0 0 Free 0 1 0 0
--------------------- OPTIONS ------------------------------------------------
9.80665 g
1025.0 rhoW
3.0e6 kBot
3.0e5 cBot
0.35 frictionMu
200.0 WtrDpth
0.05 dtM
0.1 TMax
--------------------- OUTPUTS ------------------------------------------------
FairTen4
--------------------- END ----------------------------------------------------
]=])
file(WRITE "${WORK}/friction_coarse.dat" "${_friction_deck}")
string(REPLACE "4 bare 420.0 42" "4 bare 420.0 168" _friction_fine "${_friction_deck}")
file(WRITE "${WORK}/friction_fine.dat" "${_friction_fine}")
run_driver("friction coarse" "${WORK}/friction_coarse.dat" "${WORK}/friction_coarse" _fc_log)
require_text("friction coarse" "${_fc_log}"
             "Note: line 4: seabed friction acts at the nodes, so a grounded element of 10.0 m locks or releases up to 552 N")
require_text("friction coarse" "${_fc_log}" "Grounded elements of at most 3.27 m resolve it.")
run_driver("friction fine" "${WORK}/friction_fine.dat" "${WORK}/friction_fine" _ff_log)
forbid_text("friction fine" "${_ff_log}" "seabed friction acts at the nodes")
