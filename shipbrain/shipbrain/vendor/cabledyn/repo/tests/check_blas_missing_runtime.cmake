# SPDX-License-Identifier: Apache-2.0
# Run the standalone driver and the C API from a directory that holds the CableDyn
# binaries and runtime DLLs but not openblas.dll, with PATH reduced to the Windows
# system directories. Both must fail at initialisation with a diagnostic that names
# the library, the location tried, the load error and the requesting entry point,
# not with a singular-system report from the first solve. A LAPACK call that bypasses
# initialisation must report the same cause, naming the routine.

foreach(_required BIN_DIR WORK_DIR DRIVER CAPI_TEST SOLVE_TEST DECK)
  if(NOT DEFINED ${_required} OR "${${_required}}" STREQUAL "")
    message(FATAL_ERROR "check_blas_missing_runtime: missing ${_required}")
  endif()
endforeach()

file(REMOVE_RECURSE "${WORK_DIR}")
file(MAKE_DIRECTORY "${WORK_DIR}")
file(GLOB _dlls "${BIN_DIR}/*.dll")
foreach(_dll IN LISTS _dlls)
  get_filename_component(_name "${_dll}" NAME)
  string(TOLOWER "${_name}" _lower)
  if(NOT _lower STREQUAL "openblas.dll")
    file(COPY "${_dll}" DESTINATION "${WORK_DIR}")
  endif()
endforeach()
file(COPY "${DRIVER}" "${CAPI_TEST}" "${SOLVE_TEST}" DESTINATION "${WORK_DIR}")
if(EXISTS "${WORK_DIR}/openblas.dll")
  message(FATAL_ERROR "check_blas_missing_runtime: openblas.dll was staged into ${WORK_DIR}")
endif()

# Only the Windows system directories: no conda or toolchain copy of openblas.dll.
file(TO_CMAKE_PATH "$ENV{SystemRoot}" _sysroot)
if(_sysroot STREQUAL "")
  set(_sysroot "C:/Windows")
endif()
if(EXISTS "${_sysroot}/System32/openblas.dll")
  message(FATAL_ERROR "check_blas_missing_runtime: ${_sysroot}/System32 holds an openblas.dll")
endif()
file(TO_NATIVE_PATH "${_sysroot}/System32" _sys32)
file(TO_NATIVE_PATH "${_sysroot}" _sysnative)
set(ENV{PATH} "${_sys32};${_sysnative}")
unset(ENV{OPENBLAS_NUM_THREADS})
unset(ENV{CABLEDYN_BLAS_THREADS})

get_filename_component(_driver_name "${DRIVER}" NAME)
get_filename_component(_capi_name "${CAPI_TEST}" NAME)
get_filename_component(_solve_name "${SOLVE_TEST}" NAME)
file(TO_NATIVE_PATH "${WORK_DIR}/openblas.dll" _expected_path)

function(require_text label text needle)
  string(FIND "${text}" "${needle}" _pos)
  if(_pos LESS 0)
    message(FATAL_ERROR "check_blas_missing_runtime: ${label} lacks '${needle}':\n${text}")
  endif()
endfunction()

function(forbid_text label text needle)
  string(FIND "${text}" "${needle}" _pos)
  if(_pos GREATER_EQUAL 0)
    message(FATAL_ERROR "check_blas_missing_runtime: ${label} contains '${needle}':\n${text}")
  endif()
endfunction()

# Standalone driver: exit status 2 and the diagnostic on stderr.
execute_process(
  COMMAND "${WORK_DIR}/${_driver_name}" "${DECK}" "${WORK_DIR}/out"
  WORKING_DIRECTORY "${WORK_DIR}"
  RESULT_VARIABLE _rc
  OUTPUT_VARIABLE _out
  ERROR_VARIABLE _err)
set(_all "${_out}${_err}")
if(NOT _rc EQUAL 2)
  message(FATAL_ERROR "check_blas_missing_runtime: driver exit status ${_rc}, expected 2:\n${_all}")
endif()
foreach(_needle
    "CableDyn_driver: the LAPACK runtime openblas.dll could not be loaded"
    "${_expected_path}"
    "not found"
    "standard DLL search order"
    "LoadLibrary failed with error 126")
  require_text("driver output" "${_all}" "${_needle}")
endforeach()
forbid_text("driver output" "${_all}" "singular")
message(STATUS "driver: ${_err}")

# C API: CableDyn_Create succeeds, CableDyn_InitDeck fails with CD_C_ALLOC_FAIL (2)
# and GetLastError carries the diagnostic.
execute_process(
  COMMAND "${WORK_DIR}/${_capi_name}" "${DECK}"
  WORKING_DIRECTORY "${WORK_DIR}"
  RESULT_VARIABLE _rc
  OUTPUT_VARIABLE _out
  ERROR_VARIABLE _err)
set(_all "${_out}${_err}")
if(NOT _rc EQUAL 0)
  message(FATAL_ERROR "check_blas_missing_runtime: C API probe exit status ${_rc}:\n${_all}")
endif()
foreach(_needle
    "create: 0"
    "init: 2"
    "message: CableDyn_InitDeck: the LAPACK runtime openblas.dll could not be loaded"
    "${_expected_path}"
    "LoadLibrary failed with error 126")
  require_text("C API output" "${_all}" "${_needle}")
endforeach()
forbid_text("C API output" "${_all}" "singular")
message(STATUS "C API: ${_out}")

# A LAPACK call that bypasses model initialisation: each forwarded routine returns the
# unavailable-runtime INFO, which the Fortran caller maps to the load diagnostic
# naming that routine (status 3 = CD_LINALG_BLAS_UNAVAILABLE).
execute_process(
  COMMAND "${WORK_DIR}/${_solve_name}"
  WORKING_DIRECTORY "${WORK_DIR}"
  RESULT_VARIABLE _rc
  OUTPUT_VARIABLE _out
  ERROR_VARIABLE _err)
set(_all "${_out}${_err}")
if(NOT _rc EQUAL 0)
  message(FATAL_ERROR "check_blas_missing_runtime: solve probe exit status ${_rc}:
${_all}")
endif()
foreach(_needle
    "solve status: 3"
    "solve message: DGBSV: the LAPACK runtime openblas.dll could not be loaded"
    "factor status: 3"
    "factor message: DGBTRF: the LAPACK runtime openblas.dll could not be loaded"
    "LoadLibrary failed with error 126")
  require_text("solve probe output" "${_all}" "${_needle}")
endforeach()
forbid_text("solve probe output" "${_all}" "singular")
message(STATUS "solve probe: ${_out}")

file(REMOVE_RECURSE "${WORK_DIR}")
