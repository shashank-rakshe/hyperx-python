# SPDX-License-Identifier: Apache-2.0
# Verify that no CableDyn binary imports openblas.dll when src/cabledyn_blas.c loads it at
# run time. A LAPACK routine that the Fortran sources call but cabledyn_blas.c does not
# define is resolved from the OpenBLAS import library instead; openblas.dll then loads at
# process start with a worker pool sized from OMP_NUM_THREADS or the CPU count, and each
# worker commits about 128 MB (about 4 GB on a 32-CPU machine).

foreach(_required OBJDUMP BINARIES)
  if(NOT DEFINED ${_required} OR "${${_required}}" STREQUAL "")
    message(FATAL_ERROR "check_blas_runtime_imports: missing ${_required}")
  endif()
endforeach()

string(REPLACE "|" ";" _binaries "${BINARIES}")
set(_failures "")
foreach(_binary IN LISTS _binaries)
  if(NOT EXISTS "${_binary}")
    message(FATAL_ERROR "check_blas_runtime_imports: missing ${_binary}")
  endif()
  execute_process(
    COMMAND "${OBJDUMP}" -p "${_binary}"
    RESULT_VARIABLE _rc
    OUTPUT_VARIABLE _out
    ERROR_VARIABLE _err)
  if(NOT _rc EQUAL 0)
    message(FATAL_ERROR "check_blas_runtime_imports: ${OBJDUMP} -p ${_binary} failed (${_rc})\n${_err}")
  endif()
  if(NOT _out MATCHES "DLL Name: ")
    message(FATAL_ERROR "check_blas_runtime_imports: no import table read from ${_binary}")
  endif()
  string(TOLOWER "${_out}" _lower)
  string(FIND "${_lower}" "dll name: openblas.dll" _pos)
  if(_pos GREATER_EQUAL 0)
    # List the imported symbols: each is a routine to forward in src/cabledyn_blas.c.
    string(SUBSTRING "${_out}" ${_pos} -1 _block)
    string(REGEX MATCH "^[^\n]*\n[^\n]*\n(([ \t]+[0-9a-fA-F]+[ \t]+[0-9]+[ \t]+[A-Za-z0-9_]+\n)*)" _m "${_block}")
    string(REGEX REPLACE "[ \t]+[0-9a-fA-F]+[ \t]+[0-9]+[ \t]+" " " _symbols "${CMAKE_MATCH_1}")
    string(REPLACE "\n" "" _symbols "${_symbols}")
    get_filename_component(_name "${_binary}" NAME)
    string(APPEND _failures "  ${_name} imports openblas.dll:${_symbols}\n")
  endif()
endforeach()

if(NOT _failures STREQUAL "")
  message(FATAL_ERROR
    "check_blas_runtime_imports: openblas.dll is imported at load time, bypassing the "
    "one-thread BLAS pool of src/cabledyn_blas.c. Define the listed routines there.\n${_failures}")
endif()
message(STATUS "check_blas_runtime_imports: no CableDyn binary imports openblas.dll")
