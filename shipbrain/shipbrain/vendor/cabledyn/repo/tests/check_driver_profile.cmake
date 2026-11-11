# SPDX-License-Identifier: Apache-2.0
# The run-time profile of the standalone driver (CABLEDYN_PROFILE). The same deck runs
# without the variable, with CABLEDYN_PROFILE=0 and with CABLEDYN_PROFILE=1. Only the last
# run prints the profile, before the success line, which stays the last stdout line; its
# phase rows and step counts are present; and every output file of the three runs is
# byte-identical, so the profile never changes a result.
# Optional: EXPECT (a regular expression the profiled stdout must also match).
if(NOT DEFINED DRIVER OR NOT DEFINED DECK OR NOT DEFINED OUTPUT_ROOT)
  message(FATAL_ERROR "DRIVER, DECK, and OUTPUT_ROOT are required")
endif()

function(run_driver label profile_value)
  if(profile_value STREQUAL "<unset>")
    unset(ENV{CABLEDYN_PROFILE})
  else()
    set(ENV{CABLEDYN_PROFILE} "${profile_value}")
  endif()
  execute_process(
    COMMAND "${DRIVER}" "${DECK}" "${OUTPUT_ROOT}_${label}"
    RESULT_VARIABLE result
    OUTPUT_VARIABLE out
    ERROR_VARIABLE err)
  if(NOT result EQUAL 0)
    message(FATAL_ERROR "${label} run returned ${result}, expected 0\nstdout:\n${out}\nstderr:\n${err}")
  endif()
  set(stdout_${label} "${out}" PARENT_SCOPE)
endfunction()

run_driver(unset "<unset>")
run_driver(zero "0")
run_driver(profiled "1")

foreach(label unset zero)
  if(stdout_${label} MATCHES "Run-time profile")
    message(FATAL_ERROR "the ${label} run printed a profile:\n${stdout_${label}}")
  endif()
endforeach()

set(profiled "${stdout_profiled}")
foreach(row
    "Run-time profile armed by CABLEDYN_PROFILE\\."
    "Run-time profile \\(CABLEDYN_PROFILE\\), wall-clock time:"
    "\n    input parsing +[0-9]+\\.[0-9]+ s +[0-9]+\\.[0-9] %"
    "\n    initialisation and statics +[0-9]+\\.[0-9]+ s"
    "\n    dynamic march +[0-9]+\\.[0-9]+ s"
    "\n      fluid sampled by the driver +[0-9]+\\.[0-9]+ s"
    "\n      line, cable and object steps +[0-9]+\\.[0-9]+ s"
    "\n      checks and line failures +[0-9]+\\.[0-9]+ s"
    "\n      outputs +[0-9]+\\.[0-9]+ s"
    "\n      progress and bookkeeping +[0-9]+\\.[0-9]+ s"
    "\n    finalisation +[0-9]+\\.[0-9]+ s"
    # the total is 100 % of itself, or 0.000 s and 0.0 % when the whole run took less than half a
    # millisecond (a fast build on the short deck): the driver gives no share of a zero total
    "\n    total +([0-9]+\\.[0-9]+ s +100\\.0|0\\.000 s +0\\.0) %"
    "\n    March: [1-9][0-9]* committed step\\(s\\), [0-9]+\\.[0-9]+ ms per step\\.")
  if(NOT profiled MATCHES "${row}")
    message(FATAL_ERROR "the profiled stdout lacks \"${row}\":\n${profiled}")
  endif()
endforeach()
if(DEFINED EXPECT AND NOT profiled MATCHES "${EXPECT}")
  message(FATAL_ERROR "the profiled stdout lacks \"${EXPECT}\":\n${profiled}")
endif()
# the profile comes before the success line, which stays the last stdout line
string(STRIP "${profiled}" profiled_stripped)
if(NOT profiled_stripped MATCHES "\n    total [^\n]*\n.*CableDyn_driver: converged run written to [^\n]*$")
  message(FATAL_ERROR "the success line is not the last stdout line after the profile:\n${profiled}")
endif()

# every output file of the reference run, byte-identical in the other two runs
get_filename_component(out_dir "${OUTPUT_ROOT}" DIRECTORY)
get_filename_component(out_name "${OUTPUT_ROOT}" NAME)
file(GLOB reference_files "${out_dir}/${out_name}_unset*")
list(FILTER reference_files EXCLUDE REGEX "\\.lock$")
list(LENGTH reference_files n_files)
if(n_files EQUAL 0)
  message(FATAL_ERROR "the reference run wrote no output files under ${OUTPUT_ROOT}_unset")
endif()
foreach(reference IN LISTS reference_files)
  file(SHA256 "${reference}" reference_hash)
  foreach(label zero profiled)
    string(REPLACE "${out_name}_unset" "${out_name}_${label}" other "${reference}")
    if(NOT EXISTS "${other}")
      message(FATAL_ERROR "the ${label} run did not write ${other}")
    endif()
    file(SHA256 "${other}" other_hash)
    if(NOT other_hash STREQUAL reference_hash)
      message(FATAL_ERROR "${other} differs from ${reference}: the profile changed a result")
    endif()
  endforeach()
endforeach()
message(STATUS "driver profile: ${n_files} output file(s) identical with and without the profile")
