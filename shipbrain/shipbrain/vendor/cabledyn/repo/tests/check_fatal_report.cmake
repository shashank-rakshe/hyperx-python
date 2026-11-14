# SPDX-License-Identifier: Apache-2.0
# An abnormal end of the driver process is never silent: run test_fatal_report with one
# fault and require a non-zero exit status together with the report line on stderr that
# names the cause and the simulated time reached.
#   EXE      the test_fatal_report executable
#   MODE     overflow | null | term
#   WHEN     before | during (whether a simulated time was recorded)
#   CAUSE    regular expression the cause must match
if(NOT DEFINED EXE OR NOT DEFINED MODE OR NOT DEFINED WHEN OR NOT DEFINED CAUSE)
  message(FATAL_ERROR "EXE, MODE, WHEN and CAUSE are required")
endif()

execute_process(
  COMMAND "${EXE}" "${MODE}" "${WHEN}"
  RESULT_VARIABLE result
  OUTPUT_VARIABLE out
  ERROR_VARIABLE err)

if(out MATCHES "SKIP:")
  message(STATUS "${out}")
  return()
endif()
if("${result}" STREQUAL "0" OR err MATCHES "FAIL: test_fatal_report")
  message(FATAL_ERROR "the ${MODE} fault did not end the process abnormally (status ${result}):\n"
                      "stdout:\n${out}\nstderr:\n${err}")
endif()
if(WHEN STREQUAL "during")
  set(when_text "after the step at simulated time t = 7534\\.600 s")
else()
  set(when_text "before the first time step")
endif()
set(expected "CableDyn_driver: (fatal error: |stopped by )${CAUSE}[^\n]* ${when_text}\\. The run did not finish")
if(NOT err MATCHES "${expected}")
  message(FATAL_ERROR "status ${result}, but stderr lacks the report \"${expected}\":\n${err}")
endif()
# On Windows a fault names the module and offset, and an access violation what it touched.
if(CMAKE_HOST_WIN32 AND MODE STREQUAL "null" AND
   NOT err MATCHES "exception 0xC0000005 in [^ ]+[.]exe[+]0x[0-9A-F]+, writing 0x0+[)]")
  message(FATAL_ERROR "the access violation report lacks its location and address:\n${err}")
endif()
string(REGEX MATCHALL "CableDyn_driver: (fatal error|stopped by)" reports "${err}")
list(LENGTH reports nreports)
if(NOT nreports EQUAL 1)
  message(FATAL_ERROR "the event was reported ${nreports} times, expected once:\n${err}")
endif()
message(STATUS "status ${result}; stderr:\n${err}")
