# SPDX-License-Identifier: Apache-2.0
# The run-time profile of a run that stops with an error (CABLEDYN_PROFILE): the deck's march
# fails to converge, the driver exits with code 2, and the profile it prints before the closing
# line charges the time up to the stop to the phase that was running, not to the finalisation
# the run never reached (which stays exactly zero).
if(NOT DEFINED DRIVER OR NOT DEFINED DECK OR NOT DEFINED OUTPUT_ROOT)
  message(FATAL_ERROR "DRIVER, DECK, and OUTPUT_ROOT are required")
endif()

set(ENV{CABLEDYN_PROFILE} "1")
execute_process(
  COMMAND "${DRIVER}" "${DECK}" "${OUTPUT_ROOT}"
  RESULT_VARIABLE result
  OUTPUT_VARIABLE out
  ERROR_VARIABLE err)
if(NOT result EQUAL 2)
  message(FATAL_ERROR "the run returned ${result}, expected 2\nstdout:\n${out}\nstderr:\n${err}")
endif()
foreach(row
    "Run-time profile \\(CABLEDYN_PROFILE\\), wall-clock time:"
    "\n    dynamic march +[0-9]+\\.[0-9]+ s"
    "\n    finalisation +0\\.000 s +0\\.0 %"
    # the total is 100 % of itself, or 0.000 s and 0.0 % when the whole run took less than half a
    # millisecond (a fast build on the short deck): the driver gives no share of a zero total
    "\n    total +([0-9]+\\.[0-9]+ s +100\\.0|0\\.000 s +0\\.0) %")
  if(NOT out MATCHES "${row}")
    message(FATAL_ERROR "the stdout of the failed run lacks \"${row}\":\n${out}")
  endif()
endforeach()
if(NOT err MATCHES "CableDyn_driver: ended with exit code 2")
  message(FATAL_ERROR "the stderr of the failed run lacks the closing line:\n${err}")
endif()
message(STATUS "driver profile of a failed run: no time charged to finalisation")
