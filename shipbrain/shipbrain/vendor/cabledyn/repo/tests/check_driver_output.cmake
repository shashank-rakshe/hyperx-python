# SPDX-License-Identifier: Apache-2.0
# Run the standalone driver once and check both its exit code and its messages.
#   DRIVER        the cabledyn executable
#   ARGS          its arguments, separated by '|'
#   EXPECT_RC     the required exit code
#   MUST_MATCH    regular expressions the combined stdout/stderr must match (a CMake list)
#   MUST_NOT      regular expressions it must not match (a CMake list)
#   ONCE          regular expressions that must match exactly once (a CMake list)
#   WORKDIR       working directory (optional)
if(NOT DEFINED DRIVER OR NOT DEFINED EXPECT_RC)
  message(FATAL_ERROR "DRIVER and EXPECT_RC are required")
endif()
if(NOT DEFINED WORKDIR)
  set(WORKDIR "${CMAKE_CURRENT_BINARY_DIR}")
endif()
file(MAKE_DIRECTORY "${WORKDIR}")
string(REPLACE "|" ";" ARGS "${ARGS}")

execute_process(
  COMMAND "${DRIVER}" ${ARGS}
  WORKING_DIRECTORY "${WORKDIR}"
  RESULT_VARIABLE driver_result
  OUTPUT_VARIABLE driver_stdout
  ERROR_VARIABLE driver_stderr)
set(driver_text "${driver_stdout}\n${driver_stderr}")

if(NOT driver_result EQUAL EXPECT_RC)
  message(FATAL_ERROR
    "driver returned ${driver_result}, expected ${EXPECT_RC}\n${driver_text}")
endif()
# Every exit the driver makes itself with a non-zero code ends stderr with its closing line,
# which tells such an exit from a process ended from outside.
if(NOT EXPECT_RC EQUAL 0 AND
   NOT driver_stderr MATCHES "CableDyn_driver: ended with exit code ${EXPECT_RC}[\r\n]*$")
  message(FATAL_ERROR
    "stderr does not end with the closing line for exit code ${EXPECT_RC}:\n${driver_stderr}")
endif()
foreach(pattern IN LISTS MUST_MATCH)
  if(NOT driver_text MATCHES "${pattern}")
    message(FATAL_ERROR "driver output does not match \"${pattern}\":\n${driver_text}")
  endif()
endforeach()
foreach(pattern IN LISTS MUST_NOT)
  if(driver_text MATCHES "${pattern}")
    message(FATAL_ERROR "driver output matches \"${pattern}\":\n${driver_text}")
  endif()
endforeach()
foreach(pattern IN LISTS ONCE)
  string(REGEX MATCHALL "${pattern}" hits "${driver_text}")
  list(LENGTH hits nhits)
  if(NOT nhits EQUAL 1)
    message(FATAL_ERROR "\"${pattern}\" appears ${nhits} times, expected once:\n${driver_text}")
  endif()
endforeach()
