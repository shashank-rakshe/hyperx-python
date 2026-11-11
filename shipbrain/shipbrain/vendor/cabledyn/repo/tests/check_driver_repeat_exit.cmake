# SPDX-License-Identifier: Apache-2.0
# Repeat a converged static run and require a clean exit every time. Guards the
# intermittent SIGSEGV of the libgfortran setlocale restore (src/cabledyn_crt_locale.c),
# which struck about 0.5% of runs after the outputs were complete. This is a probabilistic
# backstop (200 runs catch a 0.5% fault with probability ~63%); the deterministic guard of
# the mechanism is the crt_locale_guard test.
if(NOT DEFINED DRIVER OR NOT DEFINED DECK OR NOT DEFINED OUTPUT_ROOT OR NOT DEFINED RUNS)
  message(FATAL_ERROR "DRIVER, DECK, OUTPUT_ROOT, and RUNS are required")
endif()

foreach(run RANGE 1 ${RUNS})
  execute_process(
    COMMAND "${DRIVER}" "${DECK}" "${OUTPUT_ROOT}"
    RESULT_VARIABLE driver_result
    OUTPUT_VARIABLE driver_stdout
    ERROR_VARIABLE driver_stderr)
  if(NOT driver_result EQUAL 0 OR NOT driver_stdout MATCHES "converged run written")
    message(FATAL_ERROR
      "run ${run}/${RUNS} returned ${driver_result}, expected 0\n"
      "stdout:\n${driver_stdout}\nstderr:\n${driver_stderr}")
  endif()
endforeach()
