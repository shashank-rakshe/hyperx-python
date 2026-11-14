# SPDX-License-Identifier: Apache-2.0
# Verify the stack reserve written into Windows executables by the GNU link: the 64 MiB
# reserve of the CableDyn executables, and the 1 MiB reserve of the small-stack builds
# that the stack_* tests run (a later --stack option must override the directory-wide one).
# The reserve is read from the PE optional header itself, so no binutils are needed.
#
# CHECKS: '|'-separated <binary>=<expected SizeOfStackReserve in bytes> entries.

if(NOT DEFINED CHECKS OR "${CHECKS}" STREQUAL "")
  message(FATAL_ERROR "check_stack_reserve: missing CHECKS")
endif()

# Little-endian unsigned integer of <nbytes> bytes at <offset> of <file>.
function(_read_le file offset nbytes out)
  file(READ "${file}" _hex OFFSET ${offset} LIMIT ${nbytes} HEX)
  string(LENGTH "${_hex}" _len)
  math(EXPR _want "2 * ${nbytes}")
  if(NOT _len EQUAL _want)
    message(FATAL_ERROR "check_stack_reserve: ${file} is too short for a PE header")
  endif()
  set(_value "")
  math(EXPR _last "${nbytes} - 1")
  foreach(_byte RANGE ${_last} 0 -1)
    math(EXPR _at "2 * ${_byte}")
    string(SUBSTRING "${_hex}" ${_at} 2 _pair)
    string(APPEND _value "${_pair}")
  endforeach()
  math(EXPR _value "0x${_value}")
  set(${out} ${_value} PARENT_SCOPE)
endfunction()

string(REPLACE "|" ";" _checks "${CHECKS}")
set(_failures "")
foreach(_check IN LISTS _checks)
  string(FIND "${_check}" "=" _eq REVERSE)
  if(_eq LESS 1)
    message(FATAL_ERROR "check_stack_reserve: malformed entry '${_check}'")
  endif()
  string(SUBSTRING "${_check}" 0 ${_eq} _binary)
  math(EXPR _value_at "${_eq} + 1")
  string(SUBSTRING "${_check}" ${_value_at} -1 _expected)
  if(NOT _expected MATCHES "^[0-9]+$")
    message(FATAL_ERROR "check_stack_reserve: malformed expected reserve in '${_check}'")
  endif()
  if(NOT EXISTS "${_binary}")
    message(FATAL_ERROR "check_stack_reserve: missing ${_binary}")
  endif()
  get_filename_component(_name "${_binary}" NAME)

  # DOS header 'MZ', e_lfanew at 0x3C, 'PE\0\0' signature, 20-byte COFF header, then the
  # optional header: magic 0x10B (PE32, 4-byte reserve) or 0x20B (PE32+, 8-byte reserve),
  # SizeOfStackReserve at offset 72 in both.
  _read_le("${_binary}" 0 2 _mz)
  if(NOT _mz EQUAL 23117)
    message(FATAL_ERROR "check_stack_reserve: ${_name} is not a PE executable")
  endif()
  _read_le("${_binary}" 60 4 _pe)
  _read_le("${_binary}" ${_pe} 4 _signature)
  if(NOT _signature EQUAL 17744)
    message(FATAL_ERROR "check_stack_reserve: ${_name} has no PE signature")
  endif()
  math(EXPR _optional "${_pe} + 24")
  _read_le("${_binary}" ${_optional} 2 _magic)
  if(_magic EQUAL 523)
    set(_width 8)
  elseif(_magic EQUAL 267)
    set(_width 4)
  else()
    message(FATAL_ERROR "check_stack_reserve: ${_name} has an unknown optional header (${_magic})")
  endif()
  math(EXPR _at "${_optional} + 72")
  _read_le("${_binary}" ${_at} ${_width} _reserve)

  if(NOT _reserve EQUAL _expected)
    string(APPEND _failures "  ${_name}: stack reserve ${_reserve} bytes, expected ${_expected}\n")
  else()
    message(STATUS "${_name}: stack reserve ${_reserve} bytes")
  endif()
endforeach()

if(_failures)
  message(FATAL_ERROR "check_stack_reserve: unexpected stack reserve\n${_failures}")
endif()
message(STATUS "PASS: every checked executable has the expected stack reserve")
