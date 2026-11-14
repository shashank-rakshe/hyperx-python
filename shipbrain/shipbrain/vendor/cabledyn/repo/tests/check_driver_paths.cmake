# SPDX-License-Identifier: Apache-2.0
# Command-line path contract of the standalone driver:
#   * deck, output and auxiliary paths outside the ASCII range (accented, Hangul and
#     emoji names) are opened exactly -- or refused with a reason -- and never replaced
#     by a best-fit look-alike (café -> cafe);
#   * no output file may be the deck or a file the deck reads, however it is spelled;
#   * reserved Windows device names are refused instead of blocking on the console;
#   * an output root beyond the path limit in a folder that does not exist is refused with
#     the reason (exit 1), not a run-time crash;
#   * a second run on an output root that a live run holds is refused, and the lock
#     disappears with the run.
if(DEFINED DELAYED_RUN)
  # Helper mode: start a second run on the output root once the first holds it (its lock
  # file exists; polled rather than a fixed sleep, so a loaded machine cannot swap the
  # roles), and report its exit status and diagnostics on stderr.
  set(_lock_wait 0)
  while(NOT EXISTS "${WORK}/shared.cabledyn.lock" AND _lock_wait LESS 600)
    execute_process(COMMAND "${CMAKE_COMMAND}" -E sleep 0.1)
    math(EXPR _lock_wait "${_lock_wait} + 1")
  endwhile()
  execute_process(
    COMMAND "${DRIVER}" long.dat shared
    WORKING_DIRECTORY "${WORK}"
    RESULT_VARIABLE rc OUTPUT_VARIABLE out ERROR_VARIABLE err
    TIMEOUT 120)
  message(NOTICE "DELAYED rc=${rc}\n${err}")
  return()
endif()
if(NOT DEFINED DRIVER OR NOT DEFINED STATIC_DECK OR NOT DEFINED DYNAMIC_DECK OR NOT DEFINED WORK)
  message(FATAL_ERROR "DRIVER, STATIC_DECK, DYNAMIC_DECK, and WORK are required")
endif()

file(REMOVE_RECURSE "${WORK}")
file(MAKE_DIRECTORY "${WORK}")
file(READ "${STATIC_DECK}" static_text)
file(READ "${DYNAMIC_DECK}" dynamic_text)

function(run_driver deck root)
  execute_process(
    COMMAND "${DRIVER}" "${deck}" "${root}"
    WORKING_DIRECTORY "${WORK}"
    RESULT_VARIABLE rc OUTPUT_VARIABLE out ERROR_VARIABLE err
    TIMEOUT 120)
  set(run_rc "${rc}" PARENT_SCOPE)
  set(run_err "${err}" PARENT_SCOPE)
endfunction()

function(expect_refusal what pattern)
  if(run_rc EQUAL 0 OR NOT run_err MATCHES "${pattern}")
    message(FATAL_ERROR "${what}: expected refusal matching '${pattern}', got rc=${run_rc}\n${run_err}")
  endif()
endfunction()

# The refusal the driver gives when a name cannot be spelled for the runtime exactly
# (a file system without 8.3 short names); anything else must succeed.
set(unrepresentable "cannot represent|no 8.3 short name")

# --- non-ASCII deck and output directories ---------------------------------------
foreach(dir IN ITEMS "café" "한글" "emoji😀")
  file(MAKE_DIRECTORY "${WORK}/${dir}")
  file(WRITE "${WORK}/${dir}/d.dat" "${static_text}")
  run_driver("${dir}/d.dat" "${dir}/r")
  if(run_rc EQUAL 0)
    if(NOT EXISTS "${WORK}/${dir}/r.out")
      message(FATAL_ERROR "run on ${dir}/d.dat succeeded without writing ${dir}/r.out")
    endif()
  elseif(NOT run_err MATCHES "${unrepresentable}")
    message(FATAL_ERROR "run on ${dir}/d.dat failed: rc=${run_rc}\n${run_err}")
  endif()
endforeach()
# The best-fit look-alike of café must never be created or read.
if(EXISTS "${WORK}/cafe")
  message(FATAL_ERROR "a run on café wrote to the look-alike directory cafe")
endif()
file(MAKE_DIRECTORY "${WORK}/cafe")
file(WRITE "${WORK}/cafe/d.dat" "not a deck\n")
run_driver("café/d.dat" "café/r2")
if(NOT run_rc EQUAL 0 AND NOT run_err MATCHES "${unrepresentable}")
  message(FATAL_ERROR "café/d.dat must be read, not its look-alike cafe/d.dat: rc=${run_rc}\n${run_err}")
endif()
if(EXISTS "${WORK}/cafe/r2.out")
  message(FATAL_ERROR "outputs for café/r2 landed in the look-alike directory cafe")
endif()

# --- a working folder whose name mixes scripts -------------------------------------
# No single Windows ANSI code page spells "ü 한글 é", so a run from inside it must succeed
# with relative names: a driver linked with the UTF-8 active-code-page manifest
# (UTF8_MANIFEST, MSVC-style toolchains) opens every name directly, and the GNU build keeps
# relative names that its runtime opens in the current folder. From outside, the folder is
# part of both paths; without the manifest a name the code page cannot spell needs an 8.3
# short name, so only there may the run be refused for that reason.
set(mixed "${WORK}/ü 한글 é")
file(MAKE_DIRECTORY "${mixed}")
file(WRITE "${mixed}/deck.dat" "${static_text}")
execute_process(
  COMMAND "${DRIVER}" deck.dat inside
  WORKING_DIRECTORY "${mixed}"
  RESULT_VARIABLE rc OUTPUT_VARIABLE out ERROR_VARIABLE err
  TIMEOUT 120)
if(NOT rc EQUAL 0 OR NOT EXISTS "${mixed}/inside.out")
  message(FATAL_ERROR "run inside the mixed-script folder failed: rc=${rc}\n${err}")
endif()
run_driver("ü 한글 é/deck.dat" "ü 한글 é/outside")
if(run_rc EQUAL 0)
  if(NOT EXISTS "${mixed}/outside.out")
    message(FATAL_ERROR "run on the mixed-script folder succeeded without writing outside.out")
  endif()
elseif(UTF8_MANIFEST OR NOT run_err MATCHES "${unrepresentable}")
  message(FATAL_ERROR "run on the mixed-script folder from outside failed: rc=${run_rc}\n${run_err}")
endif()

# --- a non-ASCII auxiliary file named inside a UTF-8 deck --------------------------
file(MAKE_DIRECTORY "${WORK}/해저😀")
file(WRITE "${WORK}/해저😀/깊이é.xyz" "-100 -100 100\n1000 -100 100\n-100 100 100\n1000 100 100\n")
string(REPLACE "100.0        WtrDpth" "해저😀/깊이é.xyz bathymetryFile" aux_text "${static_text}")
file(WRITE "${WORK}/aux_deck.dat" "${aux_text}")
run_driver("aux_deck.dat" "aux_run")
if(NOT run_rc EQUAL 0 AND NOT run_err MATCHES "${unrepresentable}")
  message(FATAL_ERROR "deck naming a non-ASCII bathymetry file failed: rc=${run_rc}\n${run_err}")
endif()

# --- outputs never overwrite an input ------------------------------------------------
file(WRITE "${WORK}/clash.Line3.t.out" "${static_text}")
run_driver("clash.Line3.t.out" "clash")
expect_refusal("deck named like a per-line output" "would overwrite the input deck")
if(CMAKE_HOST_WIN32)
  # Case-insensitive filesystem: "./CLASH" names the same files as "clash".
  run_driver("clash.Line3.t.out" "./CLASH")
  expect_refusal("deck named like a per-line output, respelled root" "would overwrite the input deck")
endif()
file(READ "${WORK}/clash.Line3.t.out" after)
if(NOT after STREQUAL static_text)
  message(FATAL_ERROR "the refused run modified its deck")
endif()
# the VIV lift output of a line and the modal-analysis output
foreach(clash_name IN ITEMS "clash.Line2.V.out" "clash.modes.out")
  file(WRITE "${WORK}/${clash_name}" "${static_text}")
  run_driver("${clash_name}" "clash")
  expect_refusal("deck named like ${clash_name}" "would overwrite the input deck")
  file(READ "${WORK}/${clash_name}" after)
  if(NOT after STREQUAL static_text)
    message(FATAL_ERROR "the refused run modified its deck ${clash_name}")
  endif()
endforeach()
file(WRITE "${WORK}/auxclash.static.out" "-100 -100 100\n1000 -100 100\n-100 100 100\n1000 100 100\n")
string(REPLACE "100.0        WtrDpth" "auxclash.static.out bathymetryFile" clash_text "${static_text}")
file(WRITE "${WORK}/auxclash_deck.dat" "${clash_text}")
run_driver("auxclash_deck.dat" "auxclash")
expect_refusal("output over the bathymetry file" "would overwrite the input file")

# --- an output root beyond the path limit in a folder that does not exist ----------------
# Its runtime spelling (extended-length on Windows) is about 700 characters: a failing OPEN
# of such a name ended an ifx-built driver inside the Intel run-time (0xC0000409); it must
# be refused with the reason instead.
string(REPEAT "a" 200 seg_a)
string(REPEAT "b" 200 seg_b)
string(REPEAT "c" 200 seg_c)
file(WRITE "${WORK}/long_root_deck.dat" "${static_text}")
run_driver("long_root_deck.dat" "${WORK}/no_such_folder/${seg_a}/${seg_b}/${seg_c}/run")
if(NOT run_rc EQUAL 1 OR NOT run_err MATCHES "cannot write output files")
  message(FATAL_ERROR "long output root in a missing folder: expected exit 1 and 'cannot write output files', "
                      "got rc=${run_rc}\n${run_err}")
endif()

# --- reserved Windows device names -----------------------------------------------------
if(WIN32)
  run_driver("CON" "dev_run")
  expect_refusal("deck CON" "reserved Windows device")
  run_driver("sub/nul.dat" "dev_run")
  expect_refusal("deck sub/nul.dat" "reserved Windows device")
  file(WRITE "${WORK}/dev_deck.dat" "${static_text}")
  run_driver("dev_deck.dat" "COM1")
  expect_refusal("output root COM1" "reserved Windows device")
  string(REPLACE "100.0        WtrDpth" "CON bathymetryFile" dev_text "${static_text}")
  file(WRITE "${WORK}/dev_aux.dat" "${dev_text}")
  run_driver("dev_aux.dat" "dev_run")
  expect_refusal("bathymetryFile CON" "reserved Windows device")
endif()

# --- one live run per output root --------------------------------------------------------
string(REGEX REPLACE "\n[0-9.]+[ \t]+TMax" "\n2000.0 TMax" long_text "${dynamic_text}")
if(long_text STREQUAL dynamic_text)
  message(FATAL_ERROR "the dynamic deck has no TMax row to lengthen")
endif()
file(WRITE "${WORK}/long.dat" "${long_text}")
# The pipeline runs both commands at once: the helper starts its run while the
# long run (second, whose output is captured here) holds the root.
execute_process(
  COMMAND "${CMAKE_COMMAND}" -DDELAYED_RUN=1 "-DDRIVER=${DRIVER}" "-DWORK=${WORK}" -P "${CMAKE_CURRENT_LIST_FILE}"
  COMMAND "${DRIVER}" long.dat shared
  WORKING_DIRECTORY "${WORK}"
  RESULTS_VARIABLE pair_rc OUTPUT_VARIABLE pair_out ERROR_VARIABLE pair_err
  TIMEOUT 600)
if(NOT pair_rc STREQUAL "0;0" OR NOT pair_err MATCHES "DELAYED rc=1"
   OR NOT pair_err MATCHES "another CableDyn run is writing output root")
  message(FATAL_ERROR "concurrent runs on one output root: expected the second to be refused, got "
                      "${pair_rc}\n${pair_err}")
endif()
if(EXISTS "${WORK}/shared.cabledyn.lock")
  message(FATAL_ERROR "the output-root lock outlived its run")
endif()
file(WRITE "${WORK}/short.dat" "${dynamic_text}")
run_driver("short.dat" "shared")
if(NOT run_rc EQUAL 0)
  message(FATAL_ERROR "a run after the lock was released failed: rc=${run_rc}\n${run_err}")
endif()
