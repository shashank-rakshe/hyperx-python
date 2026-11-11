# SPDX-License-Identifier: Apache-2.0
# End-to-end check of the standalone process contract on a deterministic failed step.
if(NOT DEFINED DRIVER OR NOT DEFINED DECK OR NOT DEFINED OUTPUT_ROOT)
  message(FATAL_ERROR "DRIVER, DECK, and OUTPUT_ROOT are required")
endif()

execute_process(
  COMMAND "${DRIVER}" "${DECK}" "${OUTPUT_ROOT}"
  RESULT_VARIABLE driver_result
  OUTPUT_VARIABLE driver_stdout
  ERROR_VARIABLE driver_stderr)

if(NOT driver_result EQUAL 2)
  message(FATAL_ERROR
    "non-convergent driver returned ${driver_result}, expected 2\n"
    "stdout:\n${driver_stdout}\nstderr:\n${driver_stderr}")
endif()

if(NOT driver_stderr MATCHES "CableDyn_driver: ended with exit code 2[\r\n]*$")
  message(FATAL_ERROR "stderr does not end with the closing line for exit code 2:\n${driver_stderr}")
endif()
# The start-up statement of that contract, exactly as python/cabledyn/driver.py recognises it:
# without it a caller cannot tell an outside kill from an older driver's refusal.
string(FIND "${driver_stderr}"
       "  Exit status: every non-zero exit the driver makes itself ends stderr with \"CableDyn_driver: ended with exit code <n>\"."
       contract_at)
if(contract_at LESS 0)
  message(FATAL_ERROR "stderr lacks the exit-status statement:\n${driver_stderr}")
endif()

set(driver_text "${driver_stdout}\n${driver_stderr}")
if(NOT driver_text MATCHES "did not converge" OR
   NOT driver_text MATCHES "inspection only")
  message(FATAL_ERROR "failure diagnostic is incomplete:\n${driver_text}")
endif()
if(driver_text MATCHES "converged run written" OR
   driver_text MATCHES "completed run with warnings")
  message(FATAL_ERROR "failed march was reported as a completed run:\n${driver_text}")
endif()

set(output_file "${OUTPUT_ROOT}.out")
if(NOT EXISTS "${output_file}")
  message(FATAL_ERROR "inspection output was not retained: ${output_file}")
endif()
file(STRINGS "${output_file}" output_lines)
list(LENGTH output_lines output_line_count)
if(NOT output_line_count EQUAL 3)
  message(FATAL_ERROR
    "failed first step must leave two headers plus the converged t=0 row; "
    "found ${output_line_count} lines in ${output_file}")
endif()
list(GET output_lines 2 initial_row)
if(NOT initial_row MATCHES "^[ \t]*0\\.0+[Ee][+-]00")
  message(FATAL_ERROR "inspection output does not end at t=0: ${initial_row}")
endif()
