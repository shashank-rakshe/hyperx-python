# SPDX-License-Identifier: Apache-2.0
# Verify that a normal Windows installation contains every runtime dependency
# needed to start the standalone driver without an activated compiler environment.

# DECK (optional): a static deck the installed driver must solve.
foreach(_required BUILD_DIR INSTALL_PREFIX EXE_NAME)
  if(NOT DEFINED ${_required} OR "${${_required}}" STREQUAL "")
    message(FATAL_ERROR "check_windows_install_runtime: missing ${_required}")
  endif()
endforeach()

file(TO_CMAKE_PATH "${BUILD_DIR}" _build_dir)
file(TO_CMAKE_PATH "${INSTALL_PREFIX}" _install_prefix)
string(REGEX REPLACE "/+$" "" _build_dir "${_build_dir}")
string(REGEX REPLACE "/+$" "" _install_prefix "${_install_prefix}")
string(FIND "${_install_prefix}/" "${_build_dir}/" _inside_build)
if(NOT _inside_build EQUAL 0 OR _install_prefix STREQUAL _build_dir)
  message(FATAL_ERROR
    "check_windows_install_runtime: refusing to clean prefix outside the build tree: ${_install_prefix}")
endif()

file(REMOVE_RECURSE "${_install_prefix}")
execute_process(
  COMMAND "${CMAKE_COMMAND}" --install "${_build_dir}" --prefix "${_install_prefix}"
  RESULT_VARIABLE _install_rc
  OUTPUT_VARIABLE _install_out
  ERROR_VARIABLE _install_err)
if(NOT _install_rc EQUAL 0)
  message(FATAL_ERROR
    "check_windows_install_runtime: install failed (${_install_rc})\n${_install_out}\n${_install_err}")
endif()
if(_install_err MATCHES "CMake Warning|Invalid escape sequence")
  message(FATAL_ERROR
    "check_windows_install_runtime: install emitted a warning\n${_install_out}\n${_install_err}")
endif()

set(_installed_exe "${_install_prefix}/bin/${EXE_NAME}")
if(NOT EXISTS "${_installed_exe}")
  message(FATAL_ERROR "check_windows_install_runtime: missing ${_installed_exe}")
endif()

# Keep only Windows system locations on PATH. Dependent DLLs must resolve from
# the installed bin directory beside the executable.
set(_clean_path "$ENV{SystemRoot}/System32;$ENV{SystemRoot}")
execute_process(
  COMMAND "${CMAKE_COMMAND}" -E env "PATH=${_clean_path}" "${_installed_exe}" --version
  RESULT_VARIABLE _run_rc
  OUTPUT_VARIABLE _run_out
  ERROR_VARIABLE _run_err)
if(NOT _run_rc EQUAL 0)
  message(FATAL_ERROR
    "check_windows_install_runtime: installed driver failed in a clean environment "
    "(${_run_rc})\n${_run_out}\n${_run_err}")
endif()
if(NOT _run_out MATCHES "CableDyn")
  message(FATAL_ERROR
    "check_windows_install_runtime: installed driver returned an unexpected banner\n${_run_out}")
endif()

# --version exits before any solve, and the LAPACK runtime (openblas) is loaded on the
# first solve: a static deck must also run from the installed tree in the clean environment.
if(DEFINED DECK AND NOT "${DECK}" STREQUAL "")
  execute_process(
    COMMAND "${CMAKE_COMMAND}" -E env "PATH=${_clean_path}" "${_installed_exe}" "${DECK}"
            "${_install_prefix}/smoke_static"
    RESULT_VARIABLE _solve_rc
    OUTPUT_VARIABLE _solve_out
    ERROR_VARIABLE _solve_err)
  if(NOT _solve_rc EQUAL 0 OR NOT EXISTS "${_install_prefix}/smoke_static.out")
    message(FATAL_ERROR
      "check_windows_install_runtime: installed driver could not solve ${DECK} in a clean environment "
      "(${_solve_rc})\n${_solve_out}\n${_solve_err}")
  endif()
endif()

message(STATUS "Installed Windows runtime smoke passed: ${_installed_exe}")
