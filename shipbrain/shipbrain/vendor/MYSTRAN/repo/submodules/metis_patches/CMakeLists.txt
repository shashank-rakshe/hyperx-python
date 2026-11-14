cmake_minimum_required(VERSION 3.10)
project(METIS C)
set(CMAKE_C_STANDARD 99)

set(CMAKE_POSITION_INDEPENDENT_CODE ON)
set(SHARED FALSE CACHE BOOL "build a shared library")
option(METIS_BUILD_PROGRAMS "Build METIS command line programs" OFF)

if(MSVC)
  set(METIS_INSTALL FALSE)
else()
  set(METIS_INSTALL TRUE)
endif()

# Configure libmetis library.
if(SHARED)
  set(METIS_LIBRARY_TYPE SHARED)
else()
  set(METIS_LIBRARY_TYPE STATIC)
endif(SHARED)

include(./conf/gkbuild.cmake)

# METIS' custom options
option(IDX64 "enable 64 bit ints" OFF)
option(REAL64 "enable 64 bit floats (i.e., double)" ON)

if(IDX64)
  set(_metis_idxwidth 64)
else()
  set(_metis_idxwidth 32)
endif()

if(REAL64)
  set(_metis_realwidth 64)
else()
  set(_metis_realwidth 32)
endif()

# Generate a metis.h in the build tree that prepends the width defines.
# Read the source header FIRST so an in-source build cannot corrupt the original.
set(METIS_GENERATED_INCLUDE_DIR "${CMAKE_CURRENT_BINARY_DIR}/include")
file(MAKE_DIRECTORY "${METIS_GENERATED_INCLUDE_DIR}")
file(READ "${CMAKE_CURRENT_SOURCE_DIR}/include/metis.h" _metis_public_header)
set(_metis_generated_header
  "#define IDXTYPEWIDTH ${_metis_idxwidth}\n#define REALTYPEWIDTH ${_metis_realwidth}\n${_metis_public_header}")
set(_metis_needs_write TRUE)

if(EXISTS "${METIS_GENERATED_INCLUDE_DIR}/metis.h")
  file(READ "${METIS_GENERATED_INCLUDE_DIR}/metis.h" _metis_existing_header)

  if(_metis_existing_header STREQUAL _metis_generated_header)
    set(_metis_needs_write FALSE)
  endif()
endif()

if(_metis_needs_write)
  file(WRITE "${METIS_GENERATED_INCLUDE_DIR}/metis.h" "${_metis_generated_header}")
endif()

# Add include directories.
# i.e., the -I equivalent
include_directories("${METIS_GENERATED_INCLUDE_DIR}")
include_directories(${GKLIB_PATH}/include)
include_directories(${CMAKE_INSTALL_PREFIX}/include)

# List of paths that the compiler will search for library files.
# i.e., the -L equivalent
link_directories(${GKLIB_PATH}/lib)
link_directories(${CMAKE_INSTALL_PREFIX}/lib)

# Recursively look for CMakeLists.txt in subdirs.
add_subdirectory("libmetis")

if(METIS_BUILD_PROGRAMS)
  add_subdirectory("programs")
endif()
