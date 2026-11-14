# File: CMakeLists.txt
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
#
# Fortran 2018 production core (ARCHITECTURE.md `src/`). Build + test:
#
#   cmake -S . -B build && cmake --build build && ctest --test-dir build --output-on-failure
#
cmake_minimum_required(VERSION 3.20)
# VERSION is a bare numeric triple matching the release version.
project(CableDynCore VERSION 0.4.2 LANGUAGES C Fortran
        DESCRIPTION "CableDyn geometrically exact cable/mooring solver — Fortran core")

option(CABLEDYN_ENABLE_COVERAGE "Instrument the GNU Fortran core for gcov/gcovr source coverage" OFF)
option(CABLEDYN_ENABLE_OPENMP "Enable OpenMP acceleration when the compiler provides it" ON)
option(CABLEDYN_STATIC_WINDOWS_RELEASE
       "Build a single-file non-OpenMP Windows release with Intel IFX/MSVC" OFF)
option(CABLEDYN_TARGET_AVX2
       "Compile the Fortran core for x86-64-v3 (AVX2, FMA, BMI1/2); programs then stop with a message on older processors"
       OFF)

if(CABLEDYN_STATIC_WINDOWS_RELEASE)
  if(NOT WIN32 OR NOT CMAKE_Fortran_COMPILER_ID STREQUAL "IntelLLVM" OR NOT MSVC)
    message(FATAL_ERROR
      "CABLEDYN_STATIC_WINDOWS_RELEASE requires Windows, Intel IFX, and the MSVC C compiler")
  endif()
  # Match OpenFAST's redistributable-free Release configuration: static IFX,
  # static MSVC CRT, and no OpenMP runtime dependency (IFX has no static OpenMP
  # runtime on Windows).
  set(CABLEDYN_ENABLE_OPENMP OFF CACHE BOOL "" FORCE)
  # The release executables target x86-64-v3 (CABLEDYN_TARGET_AVX2 below).
  set(CABLEDYN_TARGET_AVX2 ON CACHE BOOL "" FORCE)
  set(CMAKE_MSVC_RUNTIME_LIBRARY "MultiThreaded" CACHE STRING "" FORCE)
  # Run-time-sized arrays and array temporaries go to the heap (/heap-arrays:1024), as in
  # every IFX build (below); the released executable also receives a generous reserve below.
  #
  # /Qipo: the element, hydrodynamic, and assembly kernels live in separate modules
  # and are called per element and per Newton iteration; without interprocedural
  # optimisation IFX cannot inline across those module boundaries. The core archive
  # then holds IPO objects, so it links only through an IPO-capable IFX link (the
  # driver below, or the OpenFAST Release|x64 project, which enables whole-program
  # optimisation).
  #
  # The floating-point model is /fp:precise, as in every IFX build (below); the reference
  # LAPACK is built with /fp:precise as well.
  string(APPEND CMAKE_Fortran_FLAGS " /libs:static /Qipo")
  # CMake does not pass the compile flags to an IFX executable link on Windows. The shared
  # library (the Windows wheel's cabledyn.dll) links the same IPO objects, so it needs the
  # flag as well: without it IFX hands the intermediate objects to link.exe (LNK1107).
  string(APPEND CMAKE_EXE_LINKER_FLAGS " /Qipo")
  string(APPEND CMAKE_SHARED_LINKER_FLAGS " /Qipo")
  # LAPACK/BLAS: the netlib reference implementation compiled with this IFX
  # (release/build_static_windows.ps1 builds it), not MKL. Every CableDyn system is
  # banded with a small bandwidth, and MKL's sequential DGBTRF/DGBTRS/DTBSV spend
  # most of their time in per-column DGER/DAXPY dispatch on vectors of a few
  # entries: with MKL, 30-65% of the run time of the release benchmark decks was
  # spent inside MKL level-1/2 kernels, against 6-15% with the reference routines.
  set(CABLEDYN_STATIC_LAPACK_LIBRARIES "" CACHE STRING
      "Static reference LAPACK and BLAS libraries (in that order) built with the release IFX")
  if(NOT CABLEDYN_STATIC_LAPACK_LIBRARIES)
    message(FATAL_ERROR
      "CABLEDYN_STATIC_WINDOWS_RELEASE needs -DCABLEDYN_STATIC_LAPACK_LIBRARIES=<liblapack.lib>;<libblas.lib> "
      "(reference LAPACK built with IFX; release/build_static_windows.ps1 provides them)")
  endif()
  foreach(_cabledyn_static_lib IN LISTS CABLEDYN_STATIC_LAPACK_LIBRARIES)
    if(NOT EXISTS "${_cabledyn_static_lib}")
      message(FATAL_ERROR "CABLEDYN_STATIC_LAPACK_LIBRARIES entry not found: ${_cabledyn_static_lib}")
    endif()
  endforeach()
endif()

# x86-64-v3 (Intel Haswell, AMD Excavator and newer): the vector maths of the wave
# kinematics and the element kernels run four doubles wide instead of two. On the release
# benchmark decks the IFX driver is 13-33% faster; results change at round-off (the wider
# vector maths), identically on every x86-64-v3 processor. Contraction into fused
# multiply-adds stays off: the compiler would fuse the same expression differently where it
# is inlined, so a restored or re-entered state would no longer continue a run bit for bit
# (test_line_attachments), for 2-5% more speed. IFX takes the /arch form, documented for
# any processor with these instructions (the /Qx form is documented for Intel processors;
# both gave the same code and speed on the benchmarks).
# Only the Fortran sources take it: src/cabledyn_cpu_guard.c stays baseline x86-64 and
# stops a program on an older processor with a message before any Fortran code runs.
if(CABLEDYN_TARGET_AVX2)
  if(NOT CMAKE_SYSTEM_PROCESSOR MATCHES "^(AMD64|amd64|x86_64|X86_64)$")
    message(FATAL_ERROR "CABLEDYN_TARGET_AVX2 needs an x86-64 target (found ${CMAKE_SYSTEM_PROCESSOR})")
  endif()
  if(CMAKE_Fortran_COMPILER_ID STREQUAL "IntelLLVM")
    if(WIN32)
      string(APPEND CMAKE_Fortran_FLAGS " /arch:CORE-AVX2 /Qfma-")
    else()
      string(APPEND CMAKE_Fortran_FLAGS " -march=core-avx2 -no-fma")
    endif()
  elseif(CMAKE_Fortran_COMPILER_ID STREQUAL "GNU")
    if(CMAKE_Fortran_COMPILER_VERSION VERSION_LESS 11)
      message(FATAL_ERROR "CABLEDYN_TARGET_AVX2 needs GNU Fortran 11 or newer (-march=x86-64-v3)")
    endif()
    string(APPEND CMAKE_Fortran_FLAGS " -march=x86-64-v3 -ffp-contract=off")
  else()
    message(FATAL_ERROR "CABLEDYN_TARGET_AVX2 supports Intel IFX and GNU Fortran")
  endif()
  set_source_files_properties(src/cabledyn_cpu_guard.c PROPERTIES
    COMPILE_DEFINITIONS CABLEDYN_REQUIRE_X86_64_V3)
endif()

# src/cabledyn_mutex.c uses C11 <stdatomic.h>, which the MSVC C compiler provides only
# behind this flag, in every MSVC configuration (static release or not).
if(CMAKE_C_COMPILER_ID STREQUAL "MSVC")
  string(APPEND CMAKE_C_FLAGS " /experimental:c11atomics")
endif()

# Default to an optimised build unless the caller (or a multi-config generator) sets one.
if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
  if(CABLEDYN_ENABLE_COVERAGE)
    set(CMAKE_BUILD_TYPE Debug CACHE STRING "Build type" FORCE)
  else()
    set(CMAKE_BUILD_TYPE Release CACHE STRING "Build type" FORCE)
  endif()
endif()

# The Debug tier is a hardening tier, not just an unoptimised variant: alongside the
# non-short-circuit .AND./.OR. behaviour the -O0 CI cell already exposes, enable runtime
# bounds / pointer / array-temporary checking so a latent out-of-bounds access (e.g. a
# substring formed before the guard that should protect it) fails loudly here rather than
# reading stray memory under Release. Release builds are unaffected.
if(CMAKE_Fortran_COMPILER_ID STREQUAL "GNU")
  string(APPEND CMAKE_Fortran_FLAGS_DEBUG " -fcheck=all -fbacktrace")
endif()

# Emit/consume all .mod files from one directory so targets see each other's modules.
set(CMAKE_Fortran_MODULE_DIRECTORY "${CMAKE_BINARY_DIR}/mod")

# Strict, standard-conforming flags for gfortran (ifx/ifort can be added later).
if(CMAKE_Fortran_COMPILER_ID STREQUAL "GNU")
  add_compile_options($<$<COMPILE_LANGUAGE:Fortran>:-std=f2018>
                      $<$<COMPILE_LANGUAGE:Fortran>:-Wall>
                      $<$<COMPILE_LANGUAGE:Fortran>:-Wextra>
                      $<$<COMPILE_LANGUAGE:Fortran>:-fimplicit-none>
                      $<$<COMPILE_LANGUAGE:C>:-Wall>
                      $<$<COMPILE_LANGUAGE:C>:-Wextra>)
endif()
# Local variables are automatic in every procedure, whatever the OpenMP setting: separate
# models (C API handles, Python objects, FAST.Farm turbines) may step concurrently on
# several threads, and a local in static storage is shared by every thread that runs its
# procedure. Without OpenMP, IFX keeps fixed-size local arrays and CHARACTER locals in
# static storage (its default, /Qauto-scalar, makes only the numeric and LOGICAL scalars
# automatic), and gfortran moves a local array larger than -fmax-stack-var-size (64 KiB)
# there; /Qauto (-auto) and -frecursive put them on the stack (-fopenmp already implies
# -frecursive, so the default GNU build is unchanged). A value that must persist between
# calls is SAVEd explicitly.
if(CMAKE_Fortran_COMPILER_ID STREQUAL "GNU")
  add_compile_options($<$<COMPILE_LANGUAGE:Fortran>:-frecursive>)
elseif(CMAKE_Fortran_COMPILER_ID STREQUAL "IntelLLVM")
  if(WIN32)
    add_compile_options($<$<COMPILE_LANGUAGE:Fortran>:/Qauto>)
  else()
    add_compile_options($<$<COMPILE_LANGUAGE:Fortran>:-auto>)
  endif()
endif()
# The value-safe floating-point model in every IFX build and configuration: /fp:precise
# (-fp-model precise off Windows), for the core, the driver, the tests, the wheel and the
# OpenFAST build of the core alike. IFX defaults to /fp:fast, which lets it reassociate sums,
# replace a division by a multiplication with the reciprocal and flush subnormals to zero,
# differently at every inlined call site. The same expression then rounds differently on two
# code paths, so the gates that hold two routes to the same bits (a zero control command and
# an uncontrolled cable, a held Coupled End B and a Fixed one, a committed and a re-derived
# torque) fail, a subnormal deck value reads as zero, and a secant iteration can stall on
# equal residuals. GNU builds keep their default, value-safe model (no -ffast-math).
#
# Run-time-sized arrays and the compiler's array temporaries on the heap, in every IFX build:
# /heap-arrays:1024 (-heap-arrays 1024 off Windows). The library runs on threads whose stack the
# host sets (1 MiB for python.exe and an MSVC-linked program: the stack_c_api and c_api_threads
# gates), and large finite-EI meshes create array temporaries in deeply nested residual and
# assembly calls; without the option a non-static IFX build overflows those stacks. The size
# threshold leaves compile-time-sized locals up to 1 MiB on the stack: with a bare /heap-arrays,
# IFX 2025.3 heap-allocates the host frame of every procedure with internal procedures and
# never frees it, leaking memory on each call.
if(CMAKE_Fortran_COMPILER_ID STREQUAL "IntelLLVM")
  if(WIN32)
    add_compile_options($<$<COMPILE_LANGUAGE:Fortran>:/fp:precise>
                        $<$<COMPILE_LANGUAGE:Fortran>:/heap-arrays:1024>)
  else()
    add_compile_options("$<$<COMPILE_LANGUAGE:Fortran>:SHELL:-fp-model precise>"
                        "$<$<COMPILE_LANGUAGE:Fortran>:SHELL:-heap-arrays 1024>")
  endif()
endif()
# GNU builds on Windows (MinGW-w64): every executable gets a 64 MiB stack reserve instead of
# the 2 MiB MinGW default. With OpenMP, gfortran places fixed-size local arrays on the stack
# (-fopenmp implies -frecursive), and the stack depth of the OpenBLAS kernels varies with the
# CPU, so a small reserve can overflow on one machine and pass on another. A reserve is address
# space, not committed memory. The library itself must run within a small stack, since a host
# such as python.exe sets the stack of the threads that call it: the stack_* tests check that.
# The static IFX release sets its own reserve on the driver.
set(CABLEDYN_GNU_WINDOWS_STACK OFF)
if(MINGW AND CMAKE_Fortran_COMPILER_ID STREQUAL "GNU")
  set(CABLEDYN_GNU_WINDOWS_STACK ON)
  set(CABLEDYN_EXE_STACK_RESERVE 67108864)
  set(CABLEDYN_SMALL_STACK_RESERVE 1048576)
  add_link_options(
    "$<$<STREQUAL:$<TARGET_PROPERTY:TYPE>,EXECUTABLE>:-Wl,--stack,${CABLEDYN_EXE_STACK_RESERVE}>")
endif()

if(CABLEDYN_ENABLE_COVERAGE AND NOT CMAKE_Fortran_COMPILER_ID STREQUAL "GNU")
  message(FATAL_ERROR "CABLEDYN_ENABLE_COVERAGE requires GNU Fortran/gcov instrumentation")
endif()

if(CABLEDYN_ENABLE_OPENMP)
  find_package(OpenMP QUIET COMPONENTS Fortran)
endif()
if(OpenMP_Fortran_FOUND)
  message(STATUS "CableDyn: OpenMP Fortran enabled for element-parallel assembly")
else()
  message(STATUS "CableDyn: OpenMP Fortran not found; element-parallel assembly directives will be ignored")
endif()
# Linear-algebra backend for the static/dynamic solves (DGBSV wrappers for both
# the EI=0 and finite-EI paths). Prefer a system LAPACK (apt liblapack on CI);
# fall back to a conda OpenBLAS (which bundles BLAS+LAPACK) located via CONDA_PREFIX
# for local Windows builds where find_package(LAPACK) cannot locate it unaided. The
# static Windows release links the IFX-built reference LAPACK given above.
if(CABLEDYN_STATIC_WINDOWS_RELEASE)
  set(CABLEDYN_LAPACK ${CABLEDYN_STATIC_LAPACK_LIBRARIES})
  message(STATUS "CableDyn: static release LAPACK: ${CABLEDYN_STATIC_LAPACK_LIBRARIES}")
else()
  find_package(LAPACK QUIET)
endif()
if(CABLEDYN_STATIC_WINDOWS_RELEASE)
  # CABLEDYN_LAPACK is set above.
elseif(LAPACK_FOUND)
  set(CABLEDYN_LAPACK LAPACK::LAPACK)
else()
  find_library(CABLEDYN_OPENBLAS NAMES openblas
    HINTS ENV CONDA_PREFIX ENV CMAKE_PREFIX_PATH
    PATH_SUFFIXES Library/lib lib)
  if(NOT CABLEDYN_OPENBLAS)
    message(FATAL_ERROR
      "No LAPACK found and no OpenBLAS in CONDA_PREFIX/CMAKE_PREFIX_PATH. "
      "Install liblapack-dev (Linux) or activate the conda env (Windows).")
  endif()
  set(CABLEDYN_LAPACK ${CABLEDYN_OPENBLAS})
  message(STATUS "CableDyn: using OpenBLAS fallback for LAPACK: ${CABLEDYN_OPENBLAS}")
endif()
# A threaded OpenBLAS commits one work buffer per worker thread (about 4 GB on a 32-CPU
# machine) although every CableDyn solve is small; src/cabledyn_blas.c limits it to one
# thread at the first CableDyn_Create when the linked back end provides the setter.
include(CheckFunctionExists)
if(CABLEDYN_STATIC_WINDOWS_RELEASE)
  # Reference LAPACK has no thread pool.
  set(CABLEDYN_HAVE_OPENBLAS_SET_NUM_THREADS FALSE)
else()
  if(LAPACK_FOUND)
    set(CMAKE_REQUIRED_LIBRARIES ${LAPACK_LIBRARIES})
  else()
    set(CMAKE_REQUIRED_LIBRARIES ${CABLEDYN_OPENBLAS})
  endif()
  check_function_exists(openblas_set_num_threads CABLEDYN_HAVE_OPENBLAS_SET_NUM_THREADS)
  unset(CMAKE_REQUIRED_LIBRARIES)
endif()

set(CABLEDYN_RUNTIME_DLLS)
if(WIN32 AND CMAKE_Fortran_COMPILER_ID STREQUAL "GNU")
  # Collect the runtime bin dirs to search, independent of HOW the toolchain was resolved.
  # OpenBLAS and the GNU compiler runtimes do not necessarily live in the same directory: in
  # the conda gfortran toolchain openblas.dll is under Library/bin, while libgfortran/
  # libquadmath/libgcc_s/libgomp/libwinpthread are under Library/mingw-w64/bin. Gather prefix
  # roots from every place LAPACK/OpenBLAS could have been found -- the OpenBLAS fallback lib,
  # an activated conda env (CONDA_PREFIX), an explicit -DCMAKE_PREFIX_PATH configure, and the
  # libraries find_package(LAPACK/BLAS) actually resolved -- then expand each root into the bin
  # dirs the DLLs may sit in and stage each DLL from the first directory that has it, so
  # build/runtime is self-contained.
  set(_cabledyn_dll_roots)
  if(CABLEDYN_OPENBLAS)
    get_filename_component(_cabledyn_lib_dir "${CABLEDYN_OPENBLAS}" DIRECTORY)
    get_filename_component(_cabledyn_root "${_cabledyn_lib_dir}" DIRECTORY)
    list(APPEND _cabledyn_dll_roots "${_cabledyn_root}")
  endif()
  if(DEFINED ENV{CONDA_PREFIX})
    list(APPEND _cabledyn_dll_roots "$ENV{CONDA_PREFIX}")
  endif()
  foreach(_cabledyn_prefix IN LISTS CMAKE_PREFIX_PATH)
    list(APPEND _cabledyn_dll_roots "${_cabledyn_prefix}")
  endforeach()
  foreach(_cabledyn_lib IN LISTS LAPACK_LIBRARIES BLAS_LIBRARIES)
    if(EXISTS "${_cabledyn_lib}")
      get_filename_component(_cabledyn_lib_dir "${_cabledyn_lib}" DIRECTORY)
      get_filename_component(_cabledyn_root "${_cabledyn_lib_dir}" DIRECTORY)
      list(APPEND _cabledyn_dll_roots "${_cabledyn_root}")
    endif()
  endforeach()
  # Environment variables on Windows commonly use backslashes. Convert every
  # search root before it is propagated into install(FILES ...); otherwise the
  # generated cmake_install.cmake can interpret sequences such as \U as escapes.
  set(_cabledyn_normalized_roots)
  foreach(_cabledyn_root IN LISTS _cabledyn_dll_roots)
    file(TO_CMAKE_PATH "${_cabledyn_root}" _cabledyn_root_cmake)
    list(APPEND _cabledyn_normalized_roots "${_cabledyn_root_cmake}")
  endforeach()
  set(_cabledyn_dll_roots ${_cabledyn_normalized_roots})
  # Expand each root into the bin dirs the runtime DLLs may sit in. The four candidates cover a
  # root that is the env (Library/bin, Library/mingw-w64/bin), a root that is a conda Library
  # dir (bin, mingw-w64/bin), and a generic install prefix (bin). Nonexistent dirs are skipped
  # by the per-DLL EXISTS probe below.
  set(_cabledyn_dll_search_dirs)
  foreach(_cabledyn_root IN LISTS _cabledyn_dll_roots)
    list(APPEND _cabledyn_dll_search_dirs
         "${_cabledyn_root}/bin"
         "${_cabledyn_root}/mingw-w64/bin"
         "${_cabledyn_root}/Library/bin"
         "${_cabledyn_root}/Library/mingw-w64/bin")
  endforeach()
  if(_cabledyn_dll_search_dirs)
    list(REMOVE_DUPLICATES _cabledyn_dll_search_dirs)
  endif()
  foreach(_cabledyn_dll IN ITEMS
      openblas.dll
      libgomp-1.dll
      libgfortran-5.dll
      libquadmath-0.dll
      libgcc_s_seh-1.dll
      libwinpthread-1.dll)   # libgfortran-5.dll depends on it; without it the bundle is not self-contained
    set(_cabledyn_dll_found "")
    foreach(_cabledyn_dir IN LISTS _cabledyn_dll_search_dirs)
      if(EXISTS "${_cabledyn_dir}/${_cabledyn_dll}")
        set(_cabledyn_dll_found "${_cabledyn_dir}/${_cabledyn_dll}")
        break()
      endif()
    endforeach()
    if(_cabledyn_dll_found)
      list(APPEND CABLEDYN_RUNTIME_DLLS "${_cabledyn_dll_found}")
    elseif(_cabledyn_dll_search_dirs)
      # Surface an incomplete bundle rather than silently shipping a runtime/ that fails
      # outside conda with a missing GNU runtime DLL.
      message(WARNING "CableDyn: runtime DLL ${_cabledyn_dll} not found in any of "
                      "${_cabledyn_dll_search_dirs}; build/runtime may not be self-contained.")
    endif()
  endforeach()
endif()

# Run-time loading of OpenBLAS (Windows GNU builds that stage openblas.dll). A threaded
# OpenBLAS sizes its worker pool from OPENBLAS_NUM_THREADS while its DLL loads, and each
# worker commits a ~128 MB buffer at once (about 4 GB on a 32-CPU machine); Windows also
# maps delay-load imports in the background right after process start. With
# CABLEDYN_BLAS_RUNTIME_LOAD, src/cabledyn_blas.c defines the LAPACK entry points CableDyn
# calls and loads openblas.dll itself on first use with a one-thread pool, so neither the
# shared library nor any executable linking cabledyn_core imports it.
set(CABLEDYN_BLAS_RUNTIME_LOAD OFF)
if(WIN32 AND CMAKE_C_COMPILER_ID STREQUAL "GNU" AND CABLEDYN_HAVE_OPENBLAS_SET_NUM_THREADS)
  foreach(_cabledyn_dll_src IN LISTS CABLEDYN_RUNTIME_DLLS)
    get_filename_component(_cabledyn_dll_name "${_cabledyn_dll_src}" NAME)
    if(_cabledyn_dll_name STREQUAL "openblas.dll")
      set(CABLEDYN_BLAS_RUNTIME_LOAD ON)
    endif()
  endforeach()
  if(CABLEDYN_BLAS_RUNTIME_LOAD)
    message(STATUS "CableDyn: openblas.dll is loaded at run time with a one-thread pool")
  endif()
endif()

# Stage the shared runtime DLL set exactly once, through a single custom command whose copies
# are declared OUTPUTs.  The build graph then serializes it, so parallel POST_BUILD steps cannot
# race on shared files.  Put Windows development/test executables and one DLL set in bin/, keeping
# the build root free of an OpenBLAS DLL that could shadow NumPy's own runtime in Python-driven
# tests.  A second self-contained deployment set remains in runtime/. Each packaged executable
# copies only its OWN exe into runtime/ and depends on this target.
if(CABLEDYN_RUNTIME_DLLS)
  set(_cabledyn_runtime_dir "${CMAKE_BINARY_DIR}/runtime")
  set(_cabledyn_build_bin "${CMAKE_BINARY_DIR}/bin")
  set(CMAKE_RUNTIME_OUTPUT_DIRECTORY "${_cabledyn_build_bin}")
  set(_cabledyn_staged_dlls)
  set(_cabledyn_build_dlls)
  foreach(_cabledyn_dll_src IN LISTS CABLEDYN_RUNTIME_DLLS)
    get_filename_component(_cabledyn_dll_name "${_cabledyn_dll_src}" NAME)
    list(APPEND _cabledyn_staged_dlls "${_cabledyn_runtime_dir}/${_cabledyn_dll_name}")
    list(APPEND _cabledyn_build_dlls "${_cabledyn_build_bin}/${_cabledyn_dll_name}")
  endforeach()
  add_custom_command(
    OUTPUT ${_cabledyn_staged_dlls} ${_cabledyn_build_dlls}
    COMMAND ${CMAKE_COMMAND} -E make_directory "${_cabledyn_runtime_dir}"
    COMMAND ${CMAKE_COMMAND} -E make_directory "${_cabledyn_build_bin}"
    COMMAND ${CMAKE_COMMAND} -E copy_if_different ${CABLEDYN_RUNTIME_DLLS} "${_cabledyn_runtime_dir}"
    COMMAND ${CMAKE_COMMAND} -E copy_if_different ${CABLEDYN_RUNTIME_DLLS} "${_cabledyn_build_bin}"
    DEPENDS ${CABLEDYN_RUNTIME_DLLS}
    COMMENT "Staging Windows runtime DLLs into ${_cabledyn_build_bin} and ${_cabledyn_runtime_dir}"
    VERBATIM)
  add_custom_target(cabledyn_stage_runtime_dll_set ALL
                    DEPENDS ${_cabledyn_staged_dlls} ${_cabledyn_build_dlls})
endif()

function(cabledyn_stage_runtime_dlls target_name)
  if(CABLEDYN_RUNTIME_DLLS)
    # The shared DLL set is staged once by cabledyn_stage_runtime_dll_set; depend on it so the
    # bundle is complete when this target builds. Copy only this target's OWN executable here --
    # a distinct output per target, so no cross-target race on shared files.
    add_dependencies(${target_name} cabledyn_stage_runtime_dll_set)
    add_custom_command(TARGET ${target_name} POST_BUILD
      COMMAND ${CMAKE_COMMAND} -E make_directory
              "${CMAKE_BINARY_DIR}/runtime"
      COMMAND ${CMAKE_COMMAND} -E copy_if_different
              $<TARGET_FILE:${target_name}>
              "${CMAKE_BINARY_DIR}/runtime"
      VERBATIM)
  endif()
endfunction()

# --- the certified production core ---
# ONE compilation of the core sources (an OBJECT library), TWO link products:
#   cabledyn_core   (STATIC)  -- every in-repo executable/test and the OpenFAST-tree
#                                ExternalProject link against this, unchanged;
#   cabledyn_shared (SHARED)  -- the C-ABI product (CableDyn_CAPI's BIND(C) surface)
#                                consumed by the ctypes-based `cabledyn` Python package
#                                and any CFD-side C caller, the MoorDyn-C deployment
#                                pattern. PIC on the object library serves both.
add_library(cabledyn_obj OBJECT
  src/cabledyn_mutex.c
  src/cabledyn_blas.c
  src/cabledyn_crt_locale.c
  src/cabledyn_cpu_guard.c
  src/cabledyn_path.c
  src/cabledyn_fatal.c
  src/CableDyn_Precision.f90
  src/CableDyn_FatalReport.f90
  src/CableDyn_Profile.f90
  src/CableDyn_LoadPredictor.f90
  src/CableDyn_PathIO.f90
  src/CableDyn_Banner.f90
  src/CableDyn_Linalg.f90
  src/CableDyn_AD.f90
  src/CableDyn_SO3.f90
  src/CableDyn_HermiteArch.f90
  src/CableDyn_EndConnection.f90
  src/CableDyn_Vessel.f90
  src/CableDyn_HermiteCable.f90
  src/CableDyn_HermiteTorsion.f90
  src/CableDyn_HermiteCableStatic.f90
  src/CableDyn_HermiteCableDynamic.f90
  src/CableDyn_Conventions.f90
  src/CableDyn_RigidKinematics.f90
  src/CableDyn_Cosserat.f90
  src/CableDyn_CosseratAssemble.f90
  src/CableDyn_CosseratStatic.f90
  src/CableDyn_CosseratDynamic.f90
  src/CableDyn_CosseratEMC.f90
  src/CableDyn_FiniteEIModel.f90
  src/CableDyn_SeabedContact.f90
  src/CableDyn_Mesh.f90
  src/CableDyn_CableElem.f90
  src/CableDyn_Assemble.f90
  src/CableDyn_Loads.f90
  src/CableDyn_Bathymetry.f90
  src/CableDyn_WaveMath.f90
  src/CableDyn_Hydro.f90
  src/CableDyn_WaveSpectra.f90
  src/CableDyn_StreamWave.f90
  src/CableDyn_Static.f90
  src/CableDyn_Catenary.f90
  src/CableDyn_FiniteEIStatic.f90
  src/CableDyn_CoupledPlatform.f90
  src/CableDyn_Line.f90
  src/CableDyn_Damping.f90
  src/CableDyn_Viscoelastic.f90
  src/CableDyn_Syrope.f90
  src/CableDyn_VIV.f90
  src/CableDyn_Dynamic.f90
  src/CableDyn_Model.f90
  src/CableDyn_Modal.f90
  src/CableDyn_System.f90
  src/CableDyn_OpenFAST_Types.f90
  src/CableDyn_OpenFAST.f90
  src/CableDyn_OpenFAST_Mesh.f90
  src/CableDyn_OpenFAST_FMF.f90
  src/CableDyn_OpenFAST_HermiteFMF.f90
  src/CableDyn_CAPI.f90
  src/CableDyn_Driver.f90
  src/CableDyn_RangeOutput.f90
  src/CableDyn_DeckDriver.f90
  src/CableDyn_OpenFAST_Aggregate.f90
)
set_target_properties(cabledyn_obj PROPERTIES POSITION_INDEPENDENT_CODE ON)
set_target_properties(cabledyn_obj PROPERTIES C_STANDARD 11 C_STANDARD_REQUIRED ON C_EXTENSIONS OFF)
target_include_directories(cabledyn_obj PUBLIC "${CMAKE_Fortran_MODULE_DIRECTORY}")
target_link_libraries(cabledyn_obj PUBLIC ${CABLEDYN_LAPACK})
# The block sine, cosine and exponential of the wave kinematics (src/CableDyn_WaveMath.f90)
# round to an integer as (y + 1.5*2^52) - 1.5*2^52 and reduce the phase by pi/2 in exact parts.
# A value-unsafe floating-point model may reassociate both and fold the rounding to y, so that
# every sine, cosine and exponential is wrong by O(1). Every IFX build compiles with
# /fp:precise (-fp-model precise) already (above); a GNU build given -ffast-math (or -Ofast)
# in its flags still compiles this file with IEEE semantics.
if(CMAKE_Fortran_COMPILER_ID STREQUAL "GNU")
  set_source_files_properties(src/CableDyn_WaveMath.f90 PROPERTIES COMPILE_OPTIONS "-fno-fast-math")
endif()
if(CABLEDYN_HAVE_OPENBLAS_SET_NUM_THREADS)
  target_compile_definitions(cabledyn_obj PRIVATE CABLEDYN_HAVE_OPENBLAS_SET_NUM_THREADS=1)
endif()
if(CABLEDYN_BLAS_RUNTIME_LOAD)
  target_compile_definitions(cabledyn_obj PRIVATE CABLEDYN_BLAS_RUNTIME_LOAD=1)
endif()
if(NOT WIN32)
  # src/cabledyn_mutex.c and src/cabledyn_blas.c use POSIX threads off Windows.
  find_package(Threads REQUIRED)
  target_link_libraries(cabledyn_obj PUBLIC Threads::Threads)
endif()
if(OpenMP_Fortran_FOUND)
  target_link_libraries(cabledyn_obj PUBLIC OpenMP::OpenMP_Fortran)
endif()
if(CABLEDYN_ENABLE_COVERAGE)
  target_compile_options(cabledyn_obj PRIVATE -O0 -g --coverage)
  target_link_options(cabledyn_obj PUBLIC --coverage)
endif()

add_library(cabledyn_core STATIC $<TARGET_OBJECTS:cabledyn_obj>)
target_link_libraries(cabledyn_core PUBLIC cabledyn_obj)
if(MINGW)
  # Pull src/cabledyn_crt_locale.c into every executable that links the archive, so
  # its load-time constructor installs the libgfortran locale guard before any I/O.
  target_link_options(cabledyn_core INTERFACE "LINKER:--undefined=cabledyn_crt_locale_guard")
endif()

add_library(cabledyn_shared SHARED $<TARGET_OBJECTS:cabledyn_obj>)
target_link_libraries(cabledyn_shared PUBLIC cabledyn_obj)
set_target_properties(cabledyn_shared PROPERTIES
  OUTPUT_NAME cabledyn
  VERSION ${PROJECT_VERSION}
  SOVERSION 1)
# The shared library exports exactly the BIND(C) entry points declared in
# src/CableDyn_CAPI.h. Fortran module procedures and the registry mutex stay
# internal so they cannot become accidental ABI or collide with host symbols.
if(WIN32)
  target_sources(cabledyn_shared PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}/src/cabledyn.def")
elseif(APPLE)
  target_link_options(cabledyn_shared PRIVATE
    "LINKER:-exported_symbols_list,${CMAKE_CURRENT_SOURCE_DIR}/src/cabledyn.exp")
else()
  target_link_options(cabledyn_shared PRIVATE
    "LINKER:--version-script=${CMAKE_CURRENT_SOURCE_DIR}/src/cabledyn.map")
endif()
set_property(TARGET cabledyn_shared APPEND PROPERTY LINK_DEPENDS
  "${CMAKE_CURRENT_SOURCE_DIR}/src/cabledyn.def"
  "${CMAKE_CURRENT_SOURCE_DIR}/src/cabledyn.exp"
  "${CMAKE_CURRENT_SOURCE_DIR}/src/cabledyn.map")

# Install the supported C-ABI product as a conventional runtime/development pair.
# The static core remains an internal/OpenFAST integration artifact; external
# consumers receive the versioned shared library and its frozen public header.
include(GNUInstallDirs)
install(TARGETS cabledyn_shared
  RUNTIME DESTINATION ${CMAKE_INSTALL_BINDIR}
  LIBRARY DESTINATION ${CMAKE_INSTALL_LIBDIR}
  ARCHIVE DESTINATION ${CMAKE_INSTALL_LIBDIR})
install(FILES src/CableDyn_CAPI.h DESTINATION ${CMAKE_INSTALL_INCLUDEDIR})

# --- unit tests (CTest assertion programs) ---
#
# The module unit tests cross-validate against independent reference values, so they carry
# `fortran;unit;reference`; capability labels (`static`, `dynamic`) select a subset.
# The driver test is an end-to-end `integration` test (file -> solve -> CSV), not
# a reference-parity check, so it carries `fortran;integration;static` instead.
# Useful selections:
#   ctest --test-dir build -L fortran -LE slow  # fast Fortran developer loop
#   ctest --test-dir build -L reference    # the reference-parity unit checks
#   ctest --test-dir build -L integration  # the end-to-end driver check
#   ctest --test-dir build -L slow --parallel 4     # long validation cells
#   ctest --test-dir build -L 'static|dynamic'  # the solver checks (regex OR)
enable_testing()
add_executable(test_ad tests/test_ad.f90)
target_link_libraries(test_ad PRIVATE cabledyn_core)
add_test(NAME ad COMMAND test_ad)
set_tests_properties(ad PROPERTIES LABELS "fortran;unit")

add_executable(test_linalg tests/test_linalg.f90)
target_link_libraries(test_linalg PRIVATE cabledyn_core)
add_test(NAME linalg COMMAND test_linalg)
set_tests_properties(linalg PROPERTIES LABELS "fortran;unit")

# CD_All_Finite on signalling NaN and infinities with floating-point trapping on in every
# build type: a floating-point compare inside the finite check would stop the program.
add_executable(test_all_finite_traps tests/test_all_finite_traps.f90)
target_link_libraries(test_all_finite_traps PRIVATE cabledyn_core)
if(CMAKE_Fortran_COMPILER_ID STREQUAL "GNU")
  target_compile_options(test_all_finite_traps PRIVATE -ffpe-trap=invalid,zero,overflow)
endif()
add_test(NAME all_finite_traps COMMAND test_all_finite_traps)
set_tests_properties(all_finite_traps PROPERTIES LABELS "fortran;unit")

add_executable(test_so3 tests/test_so3.f90)
target_link_libraries(test_so3 PRIVATE cabledyn_core)
add_test(NAME so3 COMMAND test_so3)
set_tests_properties(so3 PROPERTIES LABELS "fortran;unit;reference")

add_executable(test_conventions tests/test_conventions.f90)
target_link_libraries(test_conventions PRIVATE cabledyn_core)
add_test(NAME conventions COMMAND test_conventions)
set_tests_properties(conventions PROPERTIES LABELS "fortran;unit")

add_executable(test_rigid_kinematics tests/test_rigid_kinematics.f90)
target_link_libraries(test_rigid_kinematics PRIVATE cabledyn_core)
add_test(NAME rigid_kinematics COMMAND test_rigid_kinematics)
set_tests_properties(rigid_kinematics PROPERTIES LABELS "fortran;unit;openfast")

add_executable(test_cosserat_strains tests/test_cosserat_strains.f90)
target_link_libraries(test_cosserat_strains PRIVATE cabledyn_core)
add_test(NAME cosserat_strains COMMAND test_cosserat_strains)
set_tests_properties(cosserat_strains PROPERTIES LABELS "fortran;unit;reference")

add_executable(test_cosserat_force tests/test_cosserat_force.f90)
target_link_libraries(test_cosserat_force PRIVATE cabledyn_core)
add_test(NAME cosserat_force COMMAND test_cosserat_force)
set_tests_properties(cosserat_force PROPERTIES LABELS "fortran;unit;reference")

add_executable(test_cosserat_assemble tests/test_cosserat_assemble.f90)
target_link_libraries(test_cosserat_assemble PRIVATE cabledyn_core)
add_test(NAME cosserat_assemble COMMAND test_cosserat_assemble)
set_tests_properties(cosserat_assemble PROPERTIES LABELS "fortran;unit;reference")

add_executable(test_cosserat_mass tests/test_cosserat_mass.f90)
target_link_libraries(test_cosserat_mass PRIVATE cabledyn_core)
add_test(NAME cosserat_mass COMMAND test_cosserat_mass)
set_tests_properties(cosserat_mass PROPERTIES LABELS "fortran;unit;reference;dynamic")

add_executable(test_cosserat_dynamic tests/test_cosserat_dynamic.f90)
target_link_libraries(test_cosserat_dynamic PRIVATE cabledyn_core)
add_test(NAME cosserat_dynamic COMMAND test_cosserat_dynamic)
set_tests_properties(cosserat_dynamic PROPERTIES LABELS "fortran;unit;dynamic")

add_executable(test_finite_ei_large_rotation tests/test_finite_ei_large_rotation.f90)
target_link_libraries(test_finite_ei_large_rotation PRIVATE cabledyn_core)
add_test(NAME finite_ei_large_rotation COMMAND test_finite_ei_large_rotation)
set_tests_properties(finite_ei_large_rotation PROPERTIES LABELS "fortran;dynamic;finite_ei")

add_executable(test_finite_ei_precession tests/test_finite_ei_precession.f90)
target_link_libraries(test_finite_ei_precession PRIVATE cabledyn_core)
add_test(NAME finite_ei_precession COMMAND test_finite_ei_precession)
set_tests_properties(finite_ei_precession PROPERTIES LABELS "fortran;dynamic;finite_ei")

add_executable(test_finite_ei_gyroscopic tests/test_finite_ei_gyroscopic.f90)
target_link_libraries(test_finite_ei_gyroscopic PRIVATE cabledyn_core)
add_test(NAME finite_ei_gyroscopic COMMAND test_finite_ei_gyroscopic)
set_tests_properties(finite_ei_gyroscopic PROPERTIES LABELS "fortran;dynamic;finite_ei")

add_executable(test_finite_ei_mult_tangent tests/test_finite_ei_mult_tangent.f90)
target_link_libraries(test_finite_ei_mult_tangent PRIVATE cabledyn_core)
add_test(NAME finite_ei_mult_tangent COMMAND test_finite_ei_mult_tangent)
set_tests_properties(finite_ei_mult_tangent PROPERTIES LABELS "fortran;dynamic;finite_ei")

add_executable(test_finite_ei_mult_step tests/test_finite_ei_mult_step.f90)
target_link_libraries(test_finite_ei_mult_step PRIVATE cabledyn_core)
add_test(NAME finite_ei_mult_step COMMAND test_finite_ei_mult_step)
set_tests_properties(finite_ei_mult_step PROPERTIES LABELS "fortran;dynamic;finite_ei")

add_executable(test_finite_ei_gyro_primitives tests/test_finite_ei_gyro_primitives.f90)
target_link_libraries(test_finite_ei_gyro_primitives PRIVATE cabledyn_core)
add_test(NAME finite_ei_gyro_primitives COMMAND test_finite_ei_gyro_primitives)
set_tests_properties(finite_ei_gyro_primitives PROPERTIES LABELS "fortran;dynamic;finite_ei")

add_executable(test_finite_ei_gyro_tangent tests/test_finite_ei_gyro_tangent.f90)
target_link_libraries(test_finite_ei_gyro_tangent PRIVATE cabledyn_core)
add_test(NAME finite_ei_gyro_tangent COMMAND test_finite_ei_gyro_tangent)
set_tests_properties(finite_ei_gyro_tangent PROPERTIES LABELS "fortran;dynamic;finite_ei")

add_executable(test_finite_ei_gyro_dynamics tests/test_finite_ei_gyro_dynamics.f90)
target_link_libraries(test_finite_ei_gyro_dynamics PRIVATE cabledyn_core)
add_test(NAME finite_ei_gyro_dynamics COMMAND test_finite_ei_gyro_dynamics)
set_tests_properties(finite_ei_gyro_dynamics PROPERTIES LABELS "fortran;dynamic;finite_ei")

add_executable(test_emc tests/test_emc.f90)
target_link_libraries(test_emc PRIVATE cabledyn_core)
add_test(NAME emc COMMAND test_emc)
set_tests_properties(emc PROPERTIES LABELS "fortran;dynamic;finite_ei")

add_executable(test_finite_ei_model tests/test_finite_ei_model.f90)
target_link_libraries(test_finite_ei_model PRIVATE cabledyn_core)
add_test(NAME finite_ei_model COMMAND test_finite_ei_model)
set_tests_properties(finite_ei_model PROPERTIES LABELS "fortran;unit;dynamic")

add_executable(test_hermite_arch tests/test_hermite_arch.f90)
target_link_libraries(test_hermite_arch PRIVATE cabledyn_core)
add_test(NAME hermite_arch COMMAND test_hermite_arch)
set_tests_properties(hermite_arch PROPERTIES LABELS "fortran;unit;static")

add_executable(test_hermite_cable tests/test_hermite_cable.f90)
target_link_libraries(test_hermite_cable PRIVATE cabledyn_core)
add_test(NAME hermite_cable COMMAND test_hermite_cable)
set_tests_properties(hermite_cable PROPERTIES LABELS "fortran;unit;static")

add_executable(test_hermite_torsion_kernel tests/test_hermite_torsion_kernel.f90)
target_link_libraries(test_hermite_torsion_kernel PRIVATE cabledyn_core)
add_test(NAME hermite_torsion_kernel
         COMMAND test_hermite_torsion_kernel ${CMAKE_CURRENT_SOURCE_DIR}/tests/data/torsion_oracle_reference.txt)
set_tests_properties(hermite_torsion_kernel PROPERTIES LABELS "fortran;unit;static")

add_executable(test_hermite_twist_kernel tests/test_hermite_twist_kernel.f90)
target_link_libraries(test_hermite_twist_kernel PRIVATE cabledyn_core)
add_test(NAME hermite_twist_kernel COMMAND test_hermite_twist_kernel)
set_tests_properties(hermite_twist_kernel PROPERTIES LABELS "fortran;unit")

add_executable(test_nodal_twist_dynamic tests/test_nodal_twist_dynamic.f90)
target_link_libraries(test_nodal_twist_dynamic PRIVATE cabledyn_core)
add_test(NAME nodal_twist_dynamic COMMAND test_nodal_twist_dynamic)
set_tests_properties(nodal_twist_dynamic PROPERTIES LABELS "fortran;unit;dynamic;openfast")

add_executable(test_hermite_torsion_static tests/test_hermite_torsion_static.f90)
target_link_libraries(test_hermite_torsion_static PRIVATE cabledyn_core)
add_test(NAME hermite_torsion_static
         COMMAND test_hermite_torsion_static ${CMAKE_CURRENT_SOURCE_DIR}/tests/data/torsion_analytic_refs.txt)
set_tests_properties(hermite_torsion_static PROPERTIES LABELS "fortran;unit;static;validation")

add_executable(test_torsion_validation tests/test_torsion_validation.f90)
target_link_libraries(test_torsion_validation PRIVATE cabledyn_core)
add_test(NAME torsion_validation
         COMMAND test_torsion_validation ${CMAKE_CURRENT_SOURCE_DIR}/tests/data/torsion_analytic_refs.txt)
set_tests_properties(torsion_validation PROPERTIES LABELS "fortran;unit;static;validation")
add_executable(test_hermite_torsion_dynamic tests/test_hermite_torsion_dynamic.f90)
target_link_libraries(test_hermite_torsion_dynamic PRIVATE cabledyn_core)
add_test(NAME hermite_torsion_dynamic COMMAND test_hermite_torsion_dynamic)
set_tests_properties(hermite_torsion_dynamic PROPERTIES LABELS "fortran;unit;dynamic;validation")

add_executable(test_hermite_cable_static tests/test_hermite_cable_static.f90)
target_link_libraries(test_hermite_cable_static PRIVATE cabledyn_core)
add_test(NAME hermite_cable_static COMMAND test_hermite_cable_static)
set_tests_properties(hermite_cable_static PROPERTIES LABELS "fortran;unit;static")

# Finite-EI static tangent of a depth-profile current: the profile's vertical gradient in the drag
# tangent, against central differences of the residual
add_executable(test_hermite_static_current_gradient tests/test_hermite_static_current_gradient.f90)
target_link_libraries(test_hermite_static_current_gradient PRIVATE cabledyn_core)
add_test(NAME hermite_static_current_gradient COMMAND test_hermite_static_current_gradient)
set_tests_properties(hermite_static_current_gradient PROPERTIES LABELS "fortran;unit;static;hermite")

# Finite-EI mesh-resolution diagnosis: h*kappa peak / curvature-jump / contact-island metrics
# and the power-of-two refinement recommendation -- the preflight trigger for the adaptive mesh
# policy. Synthetic controlled profiles + fail-closed validation.
add_executable(test_hermite_resolution tests/test_hermite_resolution.f90)
target_link_libraries(test_hermite_resolution PRIVATE cabledyn_core)
add_test(NAME hermite_resolution COMMAND test_hermite_resolution)
# Finite-EI static physical-branch safeguards: fold/loop and kink audit, compression
# screens, equilibrium stability and the EI continuation from the catenary seed.
add_executable(test_hermite_branch_audit tests/test_hermite_branch_audit.f90)
target_link_libraries(test_hermite_branch_audit PRIVATE cabledyn_core)
add_test(NAME hermite_branch_audit COMMAND test_hermite_branch_audit)
set_tests_properties(hermite_branch_audit PROPERTIES LABELS "fortran;hermite;static;unit")
set_tests_properties(hermite_resolution PROPERTIES LABELS "fortran;unit;static")

# Metric-gated mesh economics: solve coarse, auto-refine to the minimum safe mesh only where the
# resolution metric demands it (refine-when-fragile, no over-refinement, cap, equivalence, fail-closed).
add_executable(test_hermite_automesh tests/test_hermite_automesh.f90)
target_link_libraries(test_hermite_automesh PRIVATE cabledyn_core)
add_test(NAME hermite_automesh COMMAND test_hermite_automesh)
set_tests_properties(hermite_automesh PROPERTIES LABELS "fortran;unit;static")

# Mesh-sequenced static entry: coarse-first continuation + Hermite prolongation + per-level
# polish -- equivalence vs the direct solve on the committed 800 m lazy-wave rig, determinism,
# finest-only constraint enforcement, fail-closed validation. Needs the committed seed file.
add_executable(test_hermite_sequenced tests/test_hermite_sequenced.f90)
target_link_libraries(test_hermite_sequenced PRIVATE cabledyn_core)
add_test(NAME hermite_sequenced COMMAND test_hermite_sequenced WORKING_DIRECTORY ${CMAKE_BINARY_DIR})
set_tests_properties(hermite_sequenced PROPERTIES LABELS "fortran;unit;static")

add_executable(test_hermite_cable_dynamic tests/test_hermite_cable_dynamic.f90)
target_link_libraries(test_hermite_cable_dynamic PRIVATE cabledyn_core)
add_test(NAME hermite_cable_dynamic COMMAND test_hermite_cable_dynamic)
set_tests_properties(hermite_cable_dynamic PROPERTIES LABELS "fortran;unit;dynamic")

add_executable(test_hermite_drag_dynamics tests/test_hermite_drag_dynamics.f90)
target_link_libraries(test_hermite_drag_dynamics PRIVATE cabledyn_core)
add_test(NAME hermite_drag_dynamics COMMAND test_hermite_drag_dynamics)
set_tests_properties(hermite_drag_dynamics PROPERTIES LABELS "fortran;unit;dynamic")

add_executable(test_hermite_axial_damping tests/test_hermite_axial_damping.f90)
target_link_libraries(test_hermite_axial_damping PRIVATE cabledyn_core)
add_test(NAME hermite_axial_damping COMMAND test_hermite_axial_damping)
set_tests_properties(hermite_axial_damping PROPERTIES LABELS "fortran;unit;dynamic;damping")

# Active line control of a finite-EI cable: the length update rebuilds the caches a fresh
# build carries (bit for bit), is atomic and rewinds exactly; hanging, taut and paid-out
# vertical cables meet their closed forms; a slow ramp ends at the static equilibrium.
add_executable(test_hermite_cable_control tests/test_hermite_cable_control.f90)
target_link_libraries(test_hermite_cable_control PRIVATE cabledyn_core)
add_test(NAME hermite_cable_control COMMAND test_hermite_cable_control)
set_tests_properties(hermite_cable_control PROPERTIES LABELS "fortran;unit;dynamic;hermite")

# Active line control of a line restrained in torsion: the quasi-static torque GJ Phi/L(t) (with
# torque-tension coupling), the torsional damping of the twist per length, the length terms a
# fresh build carries, the energy of a length change with a real Irn, no lag at alpha_f > 0,
# restart mid-ramp (snapshot, mirror) and a CONTROL deck on the coupled aggregate.
add_executable(test_control_torsion tests/test_control_torsion.f90)
target_link_libraries(test_control_torsion PRIVATE cabledyn_core)
add_test(NAME control_torsion COMMAND test_control_torsion WORKING_DIRECTORY ${CMAKE_BINARY_DIR})
set_tests_properties(control_torsion PROPERTIES LABELS "fortran;unit;dynamic;hermite;openfast")

add_executable(test_hermite_added_mass tests/test_hermite_added_mass.f90)
target_link_libraries(test_hermite_added_mass PRIVATE cabledyn_core)
add_test(NAME hermite_added_mass COMMAND test_hermite_added_mass)
set_tests_properties(hermite_added_mass PROPERTIES LABELS "fortran;unit;dynamic")

add_executable(test_hermite_wave_forcing tests/test_hermite_wave_forcing.f90)
target_link_libraries(test_hermite_wave_forcing PRIVATE cabledyn_core)
add_test(NAME hermite_wave_forcing COMMAND test_hermite_wave_forcing)
set_tests_properties(hermite_wave_forcing PROPERTIES LABELS "fortran;unit;dynamic")

add_executable(test_cable_mesh tests/test_cable_mesh.f90)
target_link_libraries(test_cable_mesh PRIVATE cabledyn_core)
add_test(NAME cable_mesh COMMAND test_cable_mesh)
set_tests_properties(cable_mesh PROPERTIES LABELS "fortran;unit;reference")

add_executable(test_cable_elem tests/test_cable_elem.f90)
target_link_libraries(test_cable_elem PRIVATE cabledyn_core)
add_test(NAME cable_elem COMMAND test_cable_elem)
set_tests_properties(cable_elem PROPERTIES LABELS "fortran;unit;reference")

add_executable(test_cable_assemble tests/test_cable_assemble.f90)
target_link_libraries(test_cable_assemble PRIVATE cabledyn_core)
add_test(NAME cable_assemble COMMAND test_cable_assemble)
set_tests_properties(cable_assemble PROPERTIES LABELS "fortran;unit;reference")

add_executable(test_cable_loads tests/test_cable_loads.f90)
target_link_libraries(test_cable_loads PRIVATE cabledyn_core)
add_test(NAME cable_loads COMMAND test_cable_loads)
set_tests_properties(cable_loads PROPERTIES LABELS "fortran;unit;reference")

add_executable(test_bathymetry tests/test_bathymetry.f90)
target_link_libraries(test_bathymetry PRIVATE cabledyn_core)
add_test(NAME bathymetry COMMAND test_bathymetry)
set_tests_properties(bathymetry PROPERTIES LABELS "fortran;unit;seabed")

add_executable(test_range_tdp_locator tests/test_range_tdp_locator.f90)
target_link_libraries(test_range_tdp_locator PRIVATE cabledyn_core)
add_test(NAME range_tdp_locator COMMAND test_range_tdp_locator)
set_tests_properties(range_tdp_locator PROPERTIES LABELS "fortran;unit;seabed")

add_executable(test_hydro tests/test_hydro.f90)
target_link_libraries(test_hydro PRIVATE cabledyn_core)
add_test(NAME hydro COMMAND test_hydro)
set_tests_properties(hydro PROPERTIES LABELS "fortran;unit;hydro")

# The block sine, cosine and exponential of the wave kinematics against quadruple precision.
add_executable(test_wave_math tests/test_wave_math.f90)
target_link_libraries(test_wave_math PRIVATE cabledyn_core)
add_test(NAME wave_math COMMAND test_wave_math)
set_tests_properties(wave_math PROPERTIES LABELS "fortran;unit;hydro")

# The fast sum of the component wave kernel against a direct quadruple-precision sum.
add_executable(test_wave_component_sum tests/test_wave_component_sum.f90)
target_link_libraries(test_wave_component_sum PRIVATE cabledyn_core)
add_test(NAME wave_component_sum COMMAND test_wave_component_sum)
set_tests_properties(wave_component_sum PROPERTIES LABELS "fortran;unit;hydro" TIMEOUT 120)

add_executable(test_cable_static tests/test_cable_static.f90)
target_link_libraries(test_cable_static PRIVATE cabledyn_core)
add_test(NAME cable_static COMMAND test_cable_static)
set_tests_properties(cable_static PROPERTIES LABELS "fortran;unit;reference;static")

add_executable(test_catenary tests/test_catenary.f90)
target_link_libraries(test_catenary PRIVATE cabledyn_core)
add_test(NAME catenary COMMAND test_catenary)
set_tests_properties(catenary PROPERTIES LABELS "fortran;unit;reference;static")

add_executable(test_robust_init tests/test_robust_init.f90)
target_link_libraries(test_robust_init PRIVATE cabledyn_core)
add_test(NAME robust_init COMMAND test_robust_init)
set_tests_properties(robust_init PROPERTIES LABELS "fortran;integration;static")

add_executable(test_line tests/test_line.f90)
target_link_libraries(test_line PRIVATE cabledyn_core)
add_test(NAME line COMMAND test_line)
set_tests_properties(line PROPERTIES LABELS "fortran;unit;reference;static")

add_executable(test_l2_chain_parity tests/test_l2_chain_parity.f90)
target_link_libraries(test_l2_chain_parity PRIVATE cabledyn_core)
add_test(NAME l2_chain_parity COMMAND test_l2_chain_parity)
set_tests_properties(l2_chain_parity PROPERTIES LABELS "fortran;l2;validation;static")

add_executable(test_l2_volturnus_mooring tests/test_l2_volturnus_mooring.f90)
target_link_libraries(test_l2_volturnus_mooring PRIVATE cabledyn_core)
add_test(NAME l2_volturnus_mooring COMMAND test_l2_volturnus_mooring)
set_tests_properties(l2_volturnus_mooring PROPERTIES LABELS "fortran;l2;validation;static;external_ref")

add_executable(test_l2_lozon80_mooring tests/test_l2_lozon80_mooring.f90)
target_link_libraries(test_l2_lozon80_mooring PRIVATE cabledyn_core)
add_test(NAME l2_lozon80_mooring COMMAND test_l2_lozon80_mooring)
set_tests_properties(l2_lozon80_mooring PROPERTIES LABELS "fortran;l2;validation;static;external_ref")

add_executable(test_l2_lozon200_semitaut tests/test_l2_lozon200_semitaut.f90)
target_link_libraries(test_l2_lozon200_semitaut PRIVATE cabledyn_core)
add_test(NAME l2_lozon200_semitaut COMMAND test_l2_lozon200_semitaut)
set_tests_properties(l2_lozon200_semitaut PROPERTIES LABELS "fortran;l2;validation;static;external_ref")

add_executable(test_l2_lozon200_semitaut_deck tests/test_l2_lozon200_semitaut_deck.f90)
target_link_libraries(test_l2_lozon200_semitaut_deck PRIVATE cabledyn_core)
add_test(NAME l2_lozon200_semitaut_deck COMMAND test_l2_lozon200_semitaut_deck)
set_tests_properties(l2_lozon200_semitaut_deck PROPERTIES LABELS "fortran;l2;validation;static;external_ref")

add_executable(test_l3_orcaflex_static tests/test_l3_orcaflex_static.f90)
target_link_libraries(test_l3_orcaflex_static PRIVATE cabledyn_core)
add_test(NAME l3_orcaflex_static COMMAND test_l3_orcaflex_static)
set_tests_properties(l3_orcaflex_static PROPERTIES LABELS "fortran;l3;validation;static;orcaflex")

add_executable(test_l3_orcaflex_current_static tests/test_l3_orcaflex_current_static.f90)
target_link_libraries(test_l3_orcaflex_current_static PRIVATE cabledyn_core)
add_test(NAME l3_orcaflex_current_static COMMAND test_l3_orcaflex_current_static)
set_tests_properties(l3_orcaflex_current_static PROPERTIES LABELS "fortran;l3;validation;static;orcaflex;hydro")

# L3-4 finite-EI touchdown on the PRODUCTION cubic-Hermite bending-cable path (tensions via
# EA(|m|-1), max curvature resampled onto OrcaFlex's segment-midpoint grid).
add_executable(test_l3_hermite_touchdown tests/test_l3_hermite_touchdown.f90)
target_link_libraries(test_l3_hermite_touchdown PRIVATE cabledyn_core)
add_test(NAME l3_finite_ei_touchdown COMMAND test_l3_hermite_touchdown)
set_tests_properties(l3_finite_ei_touchdown PROPERTIES LABELS "fortran;l3;validation;static;orcaflex")

# Same case on the secondary Cosserat (rotation-DOF) path, kept as regression coverage.
add_executable(test_l3_orcaflex_finite_ei_static tests/test_l3_orcaflex_finite_ei_static.f90)
target_link_libraries(test_l3_orcaflex_finite_ei_static PRIVATE cabledyn_core)
add_test(NAME cosserat_orcaflex_finite_ei_static COMMAND test_l3_orcaflex_finite_ei_static)
set_tests_properties(cosserat_orcaflex_finite_ei_static PROPERTIES LABELS "fortran;cosserat;static;orcaflex")

# Finite-EI lazy-wave power-cable curvature across the three Lozon (2025) depths (80/200/800 m,
# VolturnUS-S) vs OrcaFlex. The committed suspended-span seeds live next to the test executable;
# the solve's buoyancy continuation makes them portable.
configure_file(tests/data/gomex80_lazywave_seed.xyz
               ${CMAKE_BINARY_DIR}/gomex80_lazywave_seed.xyz COPYONLY)
configure_file(tests/data/gomaine200_lazywave_seed.xyz
               ${CMAKE_BINARY_DIR}/gomaine200_lazywave_seed.xyz COPYONLY)
configure_file(tests/data/humboldt_lazywave_seed.xyz
               ${CMAKE_BINARY_DIR}/humboldt_lazywave_seed.xyz COPYONLY)
configure_file(tests/data/lozon_coupled_harmonics.dat
               ${CMAKE_BINARY_DIR}/lozon_coupled_harmonics.dat COPYONLY)
add_executable(test_lazywave_dynamics tests/test_lazywave_dynamics.f90)
target_link_libraries(test_lazywave_dynamics PRIVATE cabledyn_core)
add_test(NAME lazywave_dynamics COMMAND test_lazywave_dynamics WORKING_DIRECTORY ${CMAKE_BINARY_DIR})
set_tests_properties(lazywave_dynamics PROPERTIES LABELS "fortran;dynamic;slow")

add_executable(test_hermite_axial_drag_arbiter tests/test_hermite_axial_drag_arbiter.f90)
target_link_libraries(test_hermite_axial_drag_arbiter PRIVATE cabledyn_core)
add_test(NAME hermite_axial_drag_arbiter COMMAND test_hermite_axial_drag_arbiter)
set_tests_properties(hermite_axial_drag_arbiter PROPERTIES LABELS "fortran;validation;l3;dynamic;arbiter")

add_executable(test_l3_longduration_mooring tests/test_l3_longduration_mooring.f90)
target_link_libraries(test_l3_longduration_mooring PRIVATE cabledyn_core)
add_test(NAME l3_longduration_mooring COMMAND test_l3_longduration_mooring)
set_tests_properties(l3_longduration_mooring PROPERTIES LABELS "fortran;validation;l3;l5;dynamic;slow")

add_executable(test_l3_lazywave_dynamic tests/test_l3_lazywave_dynamic.f90)
target_link_libraries(test_l3_lazywave_dynamic PRIVATE cabledyn_core)
add_test(NAME l3_lazywave_dynamic COMMAND test_l3_lazywave_dynamic WORKING_DIRECTORY ${CMAKE_BINARY_DIR})
set_tests_properties(l3_lazywave_dynamic PROPERTIES LABELS "fortran;validation;l3;dynamic;slow")
# The same parity gate on the default force blend (CD_L3_FORCE_BLEND=1) with the same Newton
# tolerance; it writes its own curvature-profile file, so the two can run concurrently.
add_test(NAME l3_lazywave_dynamic_force_blend COMMAND test_l3_lazywave_dynamic WORKING_DIRECTORY ${CMAKE_BINARY_DIR})
set_tests_properties(l3_lazywave_dynamic_force_blend PROPERTIES LABELS "fortran;validation;l3;dynamic;slow"
                     ENVIRONMENT "CD_L3_FORCE_BLEND=1")

# L4-1c: the lazy-wave cables under a realistic COUPLED FOWT hang-off motion (the shared
# N-harmonic surge+heave table), scored vs OrcaFlex at all three depths.
add_executable(test_l4_lazywave_coupled tests/test_l4_lazywave_coupled.f90)
target_link_libraries(test_l4_lazywave_coupled PRIVATE cabledyn_core)
add_test(NAME l4_lazywave_coupled COMMAND test_l4_lazywave_coupled WORKING_DIRECTORY ${CMAKE_BINARY_DIR})
set_tests_properties(l4_lazywave_coupled PROPERTIES LABELS "fortran;validation;l4;dynamic;slow")

add_executable(test_l3_lazywave_curvature tests/test_l3_lazywave_curvature.f90)
target_link_libraries(test_l3_lazywave_curvature PRIVATE cabledyn_core)
add_test(NAME l3_lazywave_curvature COMMAND test_l3_lazywave_curvature)
set_tests_properties(l3_lazywave_curvature PROPERTIES
                     LABELS "fortran;l3;validation;static;orcaflex;external_ref;slow"
                     TIMEOUT 480)

# L3-5 companion: Humboldt 800 m sag-bend curvature MESH CONVERGENCE (480 -> 960 elements by
# mesh-sequencing continuation; documents that the peak is mesh-converged inside the OrcaFlex band).
add_executable(test_l3_lazywave_refinement tests/test_l3_lazywave_refinement.f90)
target_link_libraries(test_l3_lazywave_refinement PRIVATE cabledyn_core)
add_test(NAME l3_lazywave_refinement COMMAND test_l3_lazywave_refinement WORKING_DIRECTORY ${CMAKE_BINARY_DIR})
set_tests_properties(l3_lazywave_refinement PROPERTIES
                     LABELS "fortran;l3;validation;static;orcaflex;slow"
                     TIMEOUT 900)

# L3-5 closure cell: the SAME 800 m cable solved as the FULL INSTALLED cable (fairlead + seabed
# anchor + grounded run) vs the OrcaFlex installed-cable reference -- the fourth corner of the
# pinned-span-vs-installed protocol attribution, measured on both protocols. (The executable
# name avoids the substring "install": Windows' UAC installer-detection heuristic refuses to
# launch unelevated executables whose file name matches install/setup/update/patch.)
add_executable(test_l3_lazywave_fullcable tests/test_l3_lazywave_fullcable.f90)
target_link_libraries(test_l3_lazywave_fullcable PRIVATE cabledyn_core)
add_test(NAME l3_lazywave_fullcable COMMAND test_l3_lazywave_fullcable WORKING_DIRECTORY ${CMAKE_BINARY_DIR})
set_tests_properties(l3_lazywave_fullcable PROPERTIES
                     LABELS "fortran;l3;validation;static;orcaflex;slow"
                     TIMEOUT 900)

# STATIC-INITIALIZATION STRESS MATRIX: the robustness matrix for the sequenced
# static entry -- 122 parametric cases across depth / slackness / buoyancy ratio / EA-EI /
# seabed stiffness / span ratio / buoyant fraction, each solved from a trivial bowed seed
# with the production settings and gated on convergence + a turn-angle kink detector +
# penalty-consistent penetration (the committed reference gates certify specific cases;
# this certifies the initialization CLASS).
add_executable(test_static_init_sweep tests/test_static_init_sweep.f90)
target_link_libraries(test_static_init_sweep PRIVATE cabledyn_core)
add_test(NAME static_init_sweep COMMAND test_static_init_sweep WORKING_DIRECTORY ${CMAKE_BINARY_DIR})
# The hang guard allows for a checked Debug build, about ten times slower than Release.
if(CMAKE_BUILD_TYPE STREQUAL "Debug")
  set(_static_init_sweep_timeout 5400)
else()
  set(_static_init_sweep_timeout 900)
endif()
set_tests_properties(static_init_sweep PROPERTIES
                     LABELS "fortran;hermite;static;robustness;slow"
                     TIMEOUT ${_static_init_sweep_timeout})

# L3-6e: OUT-OF-PLANE (3D) dynamic lazy-wave -- the committed dynamic gates are planar;
# this one frees the y DOFs and drives the 80 m hang-off with an elliptical heave+sway
# whirl vs the OrcaFlex 3D reference.
add_executable(test_l3_lazywave_3d_dynamic tests/test_l3_lazywave_3d_dynamic.f90)
target_link_libraries(test_l3_lazywave_3d_dynamic PRIVATE cabledyn_core)
add_test(NAME l3_lazywave_3d_dynamic COMMAND test_l3_lazywave_3d_dynamic
         WORKING_DIRECTORY ${CMAKE_BINARY_DIR})
set_tests_properties(l3_lazywave_3d_dynamic PROPERTIES
                     LABELS "fortran;l3;validation;dynamic;orcaflex;slow"
                     TIMEOUT 900)

# L3-6d: MOVING-TOUCHDOWN dynamic lazy-wave -- the unpinned successor to the pinned L3-6
# protocol (Lozon 80 m installed cable on the live penalty seabed, heave-driven TDP
# migration) vs the OrcaFlex installed-cable dynamic reference.
add_executable(test_l3_lazywave_touchdown_dynamic tests/test_l3_lazywave_touchdown_dynamic.f90)
target_link_libraries(test_l3_lazywave_touchdown_dynamic PRIVATE cabledyn_core)
add_test(NAME l3_lazywave_touchdown_dynamic COMMAND test_l3_lazywave_touchdown_dynamic
         WORKING_DIRECTORY ${CMAKE_BINARY_DIR})
set_tests_properties(l3_lazywave_touchdown_dynamic PROPERTIES
                     LABELS "fortran;l3;validation;dynamic;orcaflex;slow"
                     TIMEOUT 900)

# Regression for the pinned-end tangent mode observed in 200 m coupled OpenFAST runs.
# A section-aligned installed lazy wave receives a smooth lateral hang-off translation
# and is then held for a 30 s march.  The motion must enter the suspended span without
# a mesh-local curvature spike or collapse of |dr/ds| at the moving endpoint.
add_executable(test_pinned_touchdown_stability tests/test_pinned_touchdown_stability.f90)
target_link_libraries(test_pinned_touchdown_stability PRIVATE cabledyn_core)
add_test(NAME pinned_touchdown_stability COMMAND test_pinned_touchdown_stability
         WORKING_DIRECTORY ${CMAKE_BINARY_DIR})
set_tests_properties(pinned_touchdown_stability PROPERTIES
                     LABELS "fortran;hermite;dynamic;contact;regression;slow"
                     TIMEOUT 900)

# Component (irregular) wave path: the general component-table kinematics kernel and its
# wiring into the Hermite dynamic model (the deterministic component-matched irregular-sea
# machinery behind L3-6c).
add_executable(test_hermite_irregular_waves tests/test_hermite_irregular_waves.f90)
target_link_libraries(test_hermite_irregular_waves PRIVATE cabledyn_core)
add_test(NAME hermite_irregular_waves COMMAND test_hermite_irregular_waves)
set_tests_properties(hermite_irregular_waves PROPERTIES LABELS "fortran;unit;dynamic")

# L3-6c: irregular-sea (JONSWAP) dynamic lazy-wave vs OrcaFlex -- the component-matched
# deterministic protocol (CableDyn's seeded JONSWAP realisation, given to both codes).
add_executable(test_l3_lazywave_irregular tests/test_l3_lazywave_irregular.f90)
target_link_libraries(test_l3_lazywave_irregular PRIVATE cabledyn_core)
add_test(NAME l3_lazywave_irregular COMMAND test_l3_lazywave_irregular
         WORKING_DIRECTORY ${CMAKE_BINARY_DIR})
set_tests_properties(l3_lazywave_irregular PROPERTIES
                     LABELS "fortran;l3;validation;dynamic;orcaflex;slow"
                     TIMEOUT 900)

add_executable(test_l4_platform_mooring tests/test_l4_platform_mooring.f90)
target_link_libraries(test_l4_platform_mooring PRIVATE cabledyn_core)
add_test(NAME l4_platform_mooring COMMAND test_l4_platform_mooring)
set_tests_properties(l4_platform_mooring PROPERTIES LABELS "fortran;l4;validation;static")

add_executable(test_damping tests/test_damping.f90)
target_link_libraries(test_damping PRIVATE cabledyn_core)
add_test(NAME damping COMMAND test_damping)
set_tests_properties(damping PROPERTIES LABELS "fortran;unit;reference;dynamic")

add_executable(test_viscoelastic tests/test_viscoelastic.f90)
target_link_libraries(test_viscoelastic PRIVATE cabledyn_core)
add_test(NAME viscoelastic COMMAND test_viscoelastic)
set_tests_properties(viscoelastic PROPERTIES LABELS "fortran;unit;dynamic")

add_executable(test_syrope tests/test_syrope.f90)
target_link_libraries(test_syrope PRIVATE cabledyn_core)
add_test(NAME syrope COMMAND test_syrope)
set_tests_properties(syrope PROPERTIES LABELS "fortran;unit;dynamic")

add_executable(test_core_release_regressions tests/test_core_release_regressions.f90)
target_link_libraries(test_core_release_regressions PRIVATE cabledyn_core)
add_test(NAME core_release_regressions COMMAND test_core_release_regressions)
set_tests_properties(core_release_regressions PROPERTIES LABELS "fortran;unit;dynamic;static")

add_executable(test_core_solver_regressions tests/test_core_solver_regressions.f90)
target_link_libraries(test_core_solver_regressions PRIVATE cabledyn_core)
add_test(NAME core_solver_regressions COMMAND test_core_solver_regressions)
set_tests_properties(core_solver_regressions PROPERTIES LABELS "fortran;unit;dynamic;static")

add_executable(test_aggregate_step_atomicity tests/test_aggregate_step_atomicity.f90)
target_link_libraries(test_aggregate_step_atomicity PRIVATE cabledyn_core)
add_test(NAME aggregate_step_atomicity COMMAND test_aggregate_step_atomicity
         WORKING_DIRECTORY ${CMAKE_BINARY_DIR})
set_tests_properties(aggregate_step_atomicity PROPERTIES LABELS "fortran;unit;dynamic;capi")

add_executable(test_line_values tests/test_line_values.f90)
target_link_libraries(test_line_values PRIVATE cabledyn_core)
add_test(NAME line_values_match_channels
         COMMAND test_line_values ${CMAKE_CURRENT_SOURCE_DIR}/tests/data/lazy_wave_touchdown_planar_coarse.dat
         WORKING_DIRECTORY ${CMAKE_BINARY_DIR})
set_tests_properties(line_values_match_channels PROPERTIES LABELS "fortran;unit;dynamic;capi")

add_executable(test_core_input_guards tests/test_core_input_guards.f90)
target_link_libraries(test_core_input_guards PRIVATE cabledyn_core)
add_test(NAME core_input_guards COMMAND test_core_input_guards WORKING_DIRECTORY ${CMAKE_BINARY_DIR})
set_tests_properties(core_input_guards PROPERTIES LABELS "fortran;unit;static")

add_executable(test_prescribed_motion tests/test_prescribed_motion.f90)
target_link_libraries(test_prescribed_motion PRIVATE cabledyn_core)
add_test(NAME prescribed_motion COMMAND test_prescribed_motion)
set_tests_properties(prescribed_motion PROPERTIES LABELS "fortran;unit;dynamic")

add_executable(test_model tests/test_model.f90)
target_link_libraries(test_model PRIVATE cabledyn_core)
add_test(NAME model COMMAND test_model)
set_tests_properties(model PROPERTIES LABELS "fortran;unit;dynamic")

add_executable(test_system tests/test_system.f90)
target_link_libraries(test_system PRIVATE cabledyn_core)
add_test(NAME system COMMAND test_system)
set_tests_properties(system PROPERTIES LABELS "fortran;unit;dynamic")

# A massless Free junction between lines carrying large Morison added mass stays stable at
# every dt (attached end-node added-mass self block treated implicitly by the point step).
add_executable(test_point_added_mass tests/test_point_added_mass.f90)
target_link_libraries(test_point_added_mass PRIVATE cabledyn_core)
add_test(NAME point_added_mass COMMAND test_point_added_mass)
set_tests_properties(point_added_mass PROPERTIES LABELS "fortran;unit;dynamic")

# Deck-level: a massless Connect joining a rope and a buoyancy section (Can = 1) marches
# 60 s under waves at a typical dtM with finite, bounded loads.
add_executable(test_deck_massless_connect tests/test_deck_massless_connect.f90)
target_link_libraries(test_deck_massless_connect PRIVATE cabledyn_core)
add_test(NAME deck_massless_connect COMMAND test_deck_massless_connect WORKING_DIRECTORY ${CMAKE_BINARY_DIR})
set_tests_properties(deck_massless_connect PROPERTIES LABELS "fortran;driver;integration;dynamic")

# Seabed contact of Free/Connect points: a clump weight rests on its own footprint in the
# statics and stays at rest in the monolithic and staggered marches, on a flat and a sloped
# seabed; the fold note of an EI = 0 line reaches the OpenFAST aggregate's line report.
add_executable(test_point_seabed_contact tests/test_point_seabed_contact.f90)
target_link_libraries(test_point_seabed_contact PRIVATE cabledyn_core)
add_test(NAME point_seabed_contact COMMAND test_point_seabed_contact WORKING_DIRECTORY ${CMAKE_BINARY_DIR})
set_tests_properties(point_seabed_contact PROPERTIES LABELS "fortran;driver;integration;dynamic;static")

add_executable(test_openfast_shell tests/test_openfast_shell.f90)
target_link_libraries(test_openfast_shell PRIVATE cabledyn_core)
add_test(NAME openfast_shell COMMAND test_openfast_shell)
set_tests_properties(openfast_shell PROPERTIES LABELS "fortran;unit;dynamic;openfast")

# The shell step keeps the point store on the committed step: prescribed points follow a
# non-dynamic step, and a failed dynamic-point step restores the step-entry points.
add_executable(test_fast_point_store tests/test_fast_point_store.f90)
target_link_libraries(test_fast_point_store PRIVATE cabledyn_core)
add_test(NAME fast_point_store COMMAND test_fast_point_store)
set_tests_properties(fast_point_store PROPERTIES LABELS "fortran;unit;dynamic;openfast")

# FMF lifecycle over the Hermite dynamic power cable: shell transparency (bit-identical to
# the direct step under the same prescribed kinematics), endpoint reaction balance and
# tension consistency at rest, dynamic fairlead-load sanity, fail-closed battery. Needs the
# committed 80 m seed file.
add_executable(test_hermite_fmf tests/test_hermite_fmf.f90)
target_link_libraries(test_hermite_fmf PRIVATE cabledyn_core)
add_test(NAME hermite_fmf COMMAND test_hermite_fmf WORKING_DIRECTORY ${CMAKE_BINARY_DIR})
set_tests_properties(hermite_fmf PROPERTIES LABELS "fortran;unit;dynamic;openfast")

add_executable(test_deck_hermite_cable tests/test_deck_hermite_cable.f90)
target_link_libraries(test_deck_hermite_cable PRIVATE cabledyn_core)
add_test(NAME deck_hermite_cable COMMAND test_deck_hermite_cable WORKING_DIRECTORY ${CMAKE_BINARY_DIR})
set_tests_properties(deck_hermite_cable PROPERTIES LABELS "fortran;unit;dynamic;openfast")
# OPTION cable_statics: the continuation and sequenced finite-EI static routes agree on the
# shipped Lozon power cables.
add_executable(test_cable_statics_modes tests/test_cable_statics_modes.f90)
target_link_libraries(test_cable_statics_modes PRIVATE cabledyn_core)
add_test(NAME cable_statics_modes COMMAND test_cable_statics_modes ${CMAKE_CURRENT_SOURCE_DIR}/examples)
set_tests_properties(cable_statics_modes PROPERTIES LABELS "fortran;driver;hermite;static")

# 6-DOF prescribed vessel motion (vesselMotion / vesselRAO): rigid-body kinematics, RAO
# phase convention and spectrum, pure-rotation bit-identity with motionFile rows, and the
# clamped hang-off moment under vessel pitch.
add_executable(test_vessel_motion tests/test_vessel_motion.f90)
target_link_libraries(test_vessel_motion PRIVATE cabledyn_core)
file(MAKE_DIRECTORY ${CMAKE_BINARY_DIR}/vessel_motion/vm_wk7)
add_test(NAME vessel_motion COMMAND test_vessel_motion WORKING_DIRECTORY ${CMAKE_BINARY_DIR}/vessel_motion)
set_tests_properties(vessel_motion PROPERTIES LABELS "fortran;unit;dynamic;validation")

# Discrete ATTACHMENTS (buoyancy modules, clumps) on a cubic-Hermite cable: convergence to
# the smeared section as the module pitch shrinks, resolved local curvature between
# modules, stable dynamics, and the deck grammar.
add_executable(test_line_attachments tests/test_line_attachments.f90)
target_link_libraries(test_line_attachments PRIVATE cabledyn_core)
file(MAKE_DIRECTORY ${CMAKE_BINARY_DIR}/line_attachments)
add_test(NAME line_attachments COMMAND test_line_attachments WORKING_DIRECTORY ${CMAKE_BINARY_DIR}/line_attachments)
set_tests_properties(line_attachments PROPERTIES LABELS "fortran;static;dynamic;validation")

# Bend stiffeners (STIFFENERS): element properties against closed forms and a fine integration,
# the deck grammar, and the stiffener's end on a stock-order LINES row.
add_executable(test_bend_stiffener tests/test_bend_stiffener.f90)
target_link_libraries(test_bend_stiffener PRIVATE cabledyn_core)
file(MAKE_DIRECTORY ${CMAKE_BINARY_DIR}/bend_stiffener)
add_test(NAME bend_stiffener COMMAND test_bend_stiffener WORKING_DIRECTORY ${CMAKE_BINARY_DIR}/bend_stiffener)
set_tests_properties(bend_stiffener PROPERTIES LABELS "fortran;driver;static")

# OpenFAST CompMooring=5 aggregate: one deck carrying BOTH EI=0 mooring lines AND finite-EI
# Hermite cables composed behind the same FMF moving-point facade. Proves pure-mooring
# equivalence to CD_FMF (bit-for-bit), mixed-deck composition + column routing, pure-cable
# build, coupled finite-EI touchdown/contact, and mixed-deck-with-dynamic-point fail-closed.
add_executable(test_openfast_aggregate tests/test_openfast_aggregate.f90)
target_link_libraries(test_openfast_aggregate PRIVATE cabledyn_core)
add_test(NAME openfast_aggregate COMMAND test_openfast_aggregate WORKING_DIRECTORY ${CMAKE_BINARY_DIR})
set_tests_properties(openfast_aggregate PROPERTIES LABELS "fortran;unit;dynamic;openfast")
add_test(NAME openfast_aggregate_touchdown COMMAND test_openfast_aggregate --touchdown-only
         WORKING_DIRECTORY ${CMAKE_BINARY_DIR})
set_tests_properties(openfast_aggregate_touchdown PROPERTIES
                     LABELS "fortran;unit;dynamic;openfast;contact")
# both runs of the executable write and re-read the same scratch decks in the build root
set_tests_properties(openfast_aggregate openfast_aggregate_touchdown PROPERTIES
                     RESOURCE_LOCK openfast_aggregate_files)

# Pinned and CoupledPinned rods on the coupled aggregate: the compound-pendulum period, a held
# host equal to a fixed pin, constant and harmonic pin accelerations against closed forms,
# sub-cycling, snapshot/restore, the output probe, restart, PtfmInit with the static start, a
# step without the staged rods, and rod ends without a line.
add_executable(test_openfast_pinned_rod tests/test_openfast_pinned_rod.f90)
target_link_libraries(test_openfast_pinned_rod PRIVATE cabledyn_core)
file(MAKE_DIRECTORY ${CMAKE_BINARY_DIR}/openfast_pinned_rod)
add_test(NAME openfast_pinned_rod COMMAND test_openfast_pinned_rod
         WORKING_DIRECTORY ${CMAKE_BINARY_DIR}/openfast_pinned_rod)
set_tests_properties(openfast_pinned_rod PROPERTIES LABELS "fortran;dynamic;openfast;validation")

# CoupledPinned bodies on the coupled aggregate: the compound-pendulum period and pin reaction of
# a held node, a constant node acceleration against closed forms, a CoupledPinned rod of the same
# inertia as a second route, a symmetric mooring that does not turn the body, the output probe,
# snapshot/restore and restart, PtfmInit with the static start, sub-cycling, the OpenFAST shell's
# state-mirror restore before the first step, the refusals, and the start of Free bodies and rods
# in a host fluid field.
add_executable(test_openfast_pinned_body tests/test_openfast_pinned_body.f90)
target_link_libraries(test_openfast_pinned_body PRIVATE cabledyn_core)
file(MAKE_DIRECTORY ${CMAKE_BINARY_DIR}/openfast_pinned_body)
add_test(NAME openfast_pinned_body COMMAND test_openfast_pinned_body
         WORKING_DIRECTORY ${CMAKE_BINARY_DIR}/openfast_pinned_body)
set_tests_properties(openfast_pinned_body PROPERTIES LABELS "fortran;dynamic;openfast;validation")

# Maintained IEA-15 MW mixed deck: the finite-EI power cable has a genuine multi-node
# grounded run and marches through the OpenFAST aggregate at 40 Hz with host current.
add_executable(test_openfast_touchdown tests/test_openfast_touchdown.f90)
target_link_libraries(test_openfast_touchdown PRIVATE cabledyn_core)
add_test(NAME openfast_touchdown
         COMMAND test_openfast_touchdown ${CMAKE_SOURCE_DIR}/examples/iea15mw_umaine_mixed_cabledyn.dat)
set_tests_properties(openfast_touchdown PROPERTIES
                     LABELS "fortran;integration;dynamic;openfast;contact"
                     # Fix the OpenBLAS dispatch so the trajectory retains coverage of
                     # the round-off-limited Newton state found on older x86 runners.
                     # Other BLAS implementations ignore this environment variable.
                     ENVIRONMENT "OPENBLAS_CORETYPE=Sandybridge")

# The reaction of a finite-EI cable assembles only the rows of its node: bit-identical to the
# full assembly at every node, with every load section, on hand-built cables and along a
# coupled trajectory of the same deck, and without touching the model's scratch.
add_executable(test_hermite_node_reaction tests/test_hermite_node_reaction.f90)
target_link_libraries(test_hermite_node_reaction PRIVATE cabledyn_core)
add_test(NAME hermite_node_reaction
         COMMAND test_hermite_node_reaction ${CMAKE_SOURCE_DIR}/examples/iea15mw_umaine_mixed_cabledyn.dat)
set_tests_properties(hermite_node_reaction PROPERTIES
                     LABELS "fortran;unit;dynamic;openfast;contact"
                     ENVIRONMENT "OPENBLAS_CORETYPE=Sandybridge")

# The dtM advisor on the coupled route: the mixed example's power cable (axial period 0.351 s)
# is noted at dtM = 0.1 s with a dtM that resolves it; nothing is noted at 0.05 s.
add_executable(test_dtm_advisor tests/test_dtm_advisor.f90)
target_link_libraries(test_dtm_advisor PRIVATE cabledyn_core)
add_test(NAME dtm_advisor
         COMMAND test_dtm_advisor ${CMAKE_SOURCE_DIR}/examples/iea15mw_umaine_mixed_cabledyn.dat)
set_tests_properties(dtm_advisor PROPERTIES LABELS "fortran;unit;openfast")

# The load predictor between supercycled OpenFAST solves: used only between consecutive commits,
# exact at the commit and for loads linear in time, second order otherwise.
add_executable(test_load_predictor tests/test_load_predictor.f90)
target_link_libraries(test_load_predictor PRIVATE cabledyn_core)
add_test(NAME load_predictor COMMAND test_load_predictor)
set_tests_properties(load_predictor PROPERTIES LABELS "fortran;unit;openfast")

# The same deck initialises without a static compression/mesh note: the touchdown
# contact kink is element-local, the smoothed element-mean axial force is tensile.
add_executable(test_flagship_compression_note tests/test_flagship_compression_note.f90)
target_link_libraries(test_flagship_compression_note PRIVATE cabledyn_core)
add_test(NAME flagship_compression_note
         COMMAND test_flagship_compression_note ${CMAKE_SOURCE_DIR}/examples/iea15mw_umaine_mixed_cabledyn.dat)
set_tests_properties(flagship_compression_note PROPERTIES LABELS "fortran;integration;static;contact")
add_executable(test_static_dry_weight tests/test_static_dry_weight.f90)
target_link_libraries(test_static_dry_weight PRIVATE cabledyn_core)
add_test(NAME static_dry_weight COMMAND test_static_dry_weight WORKING_DIRECTORY ${CMAKE_BINARY_DIR})
set_tests_properties(static_dry_weight PROPERTIES LABELS "fortran;integration;static;openfast")
# The tangent channels of a finite-EI line read its tangent DOF: at a clamped end the clamp's
# angles, at a pinned end and every other node the solution's tangent.
add_executable(test_end_tangent_channels tests/test_end_tangent_channels.f90)
target_link_libraries(test_end_tangent_channels PRIVATE cabledyn_core)
add_test(NAME end_tangent_channels COMMAND test_end_tangent_channels WORKING_DIRECTORY ${CMAKE_BINARY_DIR})
set_tests_properties(end_tangent_channels PROPERTIES LABELS "fortran;integration;static;outputs" TIMEOUT 600)
# The end reactions of a finite-EI cable at rest in a uniform current, pinned or clamped,
# suspended or touching down, balance its weight and its Morison drag integrated independently.
add_executable(test_static_current_balance tests/test_static_current_balance.f90)
target_link_libraries(test_static_current_balance PRIVATE cabledyn_core)
add_test(NAME static_current_balance COMMAND test_static_current_balance
         WORKING_DIRECTORY ${CMAKE_BINARY_DIR})
set_tests_properties(static_current_balance PROPERTIES LABELS "fortran;integration;static;hydro" TIMEOUT 600)

add_executable(test_viv_kernels tests/test_viv_kernels.f90)
target_link_libraries(test_viv_kernels PRIVATE cabledyn_core)
add_test(NAME viv_kernels COMMAND test_viv_kernels)
set_tests_properties(viv_kernels PROPERTIES LABELS "fortran;unit;dynamic;viv")

add_executable(test_hermite_viv tests/test_hermite_viv.f90)
target_link_libraries(test_hermite_viv PRIVATE cabledyn_core)
add_test(NAME hermite_viv COMMAND test_hermite_viv)
set_tests_properties(hermite_viv PROPERTIES LABELS "fortran;dynamic;viv")

add_executable(test_viv_coupled tests/test_viv_coupled.f90)
target_link_libraries(test_viv_coupled PRIVATE cabledyn_core)
add_test(NAME viv_coupled COMMAND test_viv_coupled WORKING_DIRECTORY ${CMAKE_BINARY_DIR})
set_tests_properties(viv_coupled PROPERTIES LABELS "fortran;integration;dynamic;viv;openfast")

add_executable(test_hfmf_mirror tests/test_hfmf_mirror.f90)
target_link_libraries(test_hfmf_mirror PRIVATE cabledyn_core)
add_test(NAME hfmf_mirror COMMAND test_hfmf_mirror WORKING_DIRECTORY ${CMAKE_BINARY_DIR})
set_tests_properties(hfmf_mirror PROPERTIES LABELS "fortran;unit;dynamic;openfast")

add_executable(test_output_formats tests/test_output_formats.f90)
target_link_libraries(test_output_formats PRIVATE cabledyn_core)
add_test(NAME output_formats COMMAND test_output_formats)
set_tests_properties(output_formats PROPERTIES LABELS "fortran;unit;output")

add_executable(test_c_api tests/test_c_api.f90)
target_link_libraries(test_c_api PRIVATE cabledyn_core)
add_test(NAME c_api COMMAND test_c_api)
set_tests_properties(c_api PROPERTIES LABELS "fortran;unit;dynamic;capi")

# One Newton tolerance for a finite-EI cable on every route: the mixed deck's cable (coupled
# aggregate) against the same cable alone (standalone cubic-Hermite route) at rhoInf 1 / dtM 0.05
# and rhoInf 0.4 / dtM 0.1, and the C API, OpenFAST and FAST.Farm builds of the aggregate driven
# by a host through the same motion, against the driver.
add_executable(test_coupled_cable_tolerance tests/test_coupled_cable_tolerance.f90)
target_link_libraries(test_coupled_cable_tolerance PRIVATE cabledyn_core)
add_test(NAME coupled_cable_tolerance COMMAND test_coupled_cable_tolerance $<TARGET_FILE:cabledyn>)
set_tests_properties(coupled_cable_tolerance PROPERTIES LABELS "fortran;driver;integration;dynamic;capi;openfast")

# Compile and run through the installed-style C header against the SHARED ABI
# product. This catches missing Windows exports, C/Fortran prototype drift, ABI
# version drift, and loader failures that the Fortran-native lifecycle gate cannot.
add_executable(test_c_api_shared tests/test_c_api_shared.c)
target_include_directories(test_c_api_shared PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}/src")
target_link_libraries(test_c_api_shared PRIVATE cabledyn_shared)
add_test(NAME c_api_shared
         COMMAND test_c_api_shared ${CMAKE_CURRENT_SOURCE_DIR}/examples/iea15mw_volturnus_mooring.dat
                 ${CMAKE_CURRENT_SOURCE_DIR}/examples/dynamic_chain_waves.dat)
set_tests_properties(c_api_shared PROPERTIES LABELS "c;unit;capi;shared")

# The host-coupling calls of ABI 1.2 through the public header and the shared library:
# initialization at the host's positions (the foamMooring EsfLOWC box, whose fairleads start
# below their deck coordinates), state save/restore on both routes, on a raw-array handle and
# with viscoelastic, Syrope, seabed-friction and point fluid-field state, the save-slot
# lifetime across failed initializations, and the layout query.
add_executable(test_c_api_host_coupling tests/test_c_api_host_coupling.c)
target_include_directories(test_c_api_host_coupling PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}/src")
target_link_libraries(test_c_api_host_coupling PRIVATE cabledyn_shared)
if(NOT WIN32)
  target_link_libraries(test_c_api_host_coupling PRIVATE m)
endif()
add_test(NAME c_api_host_coupling
         COMMAND test_c_api_host_coupling ${CMAKE_CURRENT_SOURCE_DIR}/tests/data/foam_esflowc_box_points.dat
                 ${CMAKE_CURRENT_SOURCE_DIR}/tests/data/host_coupling_chain_cable.dat
                 ${CMAKE_CURRENT_SOURCE_DIR}/examples/ve_polyester_catenary_mooring.dat
                 ${CMAKE_CURRENT_SOURCE_DIR}/examples/syrope_polyester_mooring.dat
                 ${CMAKE_CURRENT_SOURCE_DIR}/examples/clump_weight_free_point.dat)
set_tests_properties(c_api_host_coupling PROPERTIES LABELS "c;unit;capi;shared;dynamic")

add_executable(test_c_api_host_rotation tests/test_c_api_host_rotation.c)
target_include_directories(test_c_api_host_rotation PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}/src")
target_link_libraries(test_c_api_host_rotation PRIVATE cabledyn_shared)
if(NOT WIN32)
  target_link_libraries(test_c_api_host_rotation PRIVATE m)
endif()
add_test(NAME c_api_host_rotation
         COMMAND test_c_api_host_rotation ${CMAKE_CURRENT_SOURCE_DIR}/tests/data/foam_esflowc_box_points.dat
         WORKING_DIRECTORY ${CMAKE_BINARY_DIR})
set_tests_properties(c_api_host_rotation PROPERTIES LABELS "c;unit;capi;shared;dynamic;torsion")

# CableDyn_GetInitNotes on the point route, the aggregate and a host fluid field.
add_executable(test_c_api_init_notes tests/test_c_api_init_notes.c)
target_include_directories(test_c_api_init_notes PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}/src")
target_link_libraries(test_c_api_init_notes PRIVATE cabledyn_shared)
add_test(NAME c_api_init_notes COMMAND test_c_api_init_notes WORKING_DIRECTORY ${CMAKE_BINARY_DIR})
set_tests_properties(c_api_init_notes PROPERTIES LABELS "c;unit;capi;shared")

find_package(Threads QUIET)
if(Threads_FOUND AND CMAKE_USE_PTHREADS_INIT)
  add_executable(test_c_api_concurrency tests/test_c_api_concurrency.c)
  target_include_directories(test_c_api_concurrency PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}/src")
  target_link_libraries(test_c_api_concurrency PRIVATE cabledyn_core Threads::Threads)
  add_test(NAME c_api_concurrency COMMAND test_c_api_concurrency)
  set_tests_properties(c_api_concurrency PROPERTIES LABELS "c;unit;capi;threading")
else()
  message(STATUS "CableDyn: pthread C API concurrency stress gate unavailable on this toolchain; "
                 "the portable C API lifecycle gate remains enabled")
endif()

# Portable (Win32 or POSIX threads) stack bound of the shared library: each deck is
# initialised, stepped, saved and restored, evaluated, and initialised again at its coupled
# positions (CableDyn_InitDeckAt) on a thread with a 1 MiB stack (a host program, not
# CableDyn, chooses the stack of the threads that call the library). The
# decks are a 2048-element finite-EI cable (12294 DOFs), an EI=0 + finite-EI aggregate, and an
# EI=0 mooring; a stack need that grew with the model would overflow here.
add_executable(test_c_api_stack tests/test_c_api_stack.c)
target_include_directories(test_c_api_stack PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}/src")
target_link_libraries(test_c_api_stack PRIVATE $<TARGET_LINKER_FILE:cabledyn_shared>)
add_dependencies(test_c_api_stack cabledyn_shared)
if(NOT WIN32)
  target_link_libraries(test_c_api_stack PRIVATE Threads::Threads m)
endif()
add_test(NAME stack_c_api
         COMMAND test_c_api_stack 1024
                 0.05 ${CMAKE_CURRENT_SOURCE_DIR}/tests/data/stack_humboldt800_2048_elements.dat
                 0.025 ${CMAKE_CURRENT_SOURCE_DIR}/examples/iea15mw_umaine_mixed_cabledyn.dat
                 0.1 ${CMAKE_CURRENT_SOURCE_DIR}/examples/iea15mw_volturnus_mooring.dat)
set_tests_properties(stack_c_api PROPERTIES LABELS "c;unit;capi;stack" TIMEOUT 900)

# Portable (Win32 or POSIX threads) gate: concurrent InitDeck of one deck and of decks
# sharing a Syrope OWC table in the user's locale, concurrent Step on distinct handles,
# the missing-file diagnostic, and the BLAS thread/memory policy of CableDyn_Create.
add_executable(test_c_api_threads tests/test_c_api_threads.c)
target_include_directories(test_c_api_threads PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}/src")
# Link the import library alone: the usage requirements of cabledyn_shared carry the
# OpenBLAS import library, whose re-exported C runtime symbols (printf) would otherwise
# bind this C executable to openblas.dll at load time and defeat the memory check.
target_link_libraries(test_c_api_threads PRIVATE $<TARGET_LINKER_FILE:cabledyn_shared>)
add_dependencies(test_c_api_threads cabledyn_shared)
if(WIN32)
  target_link_libraries(test_c_api_threads PRIVATE psapi)
else()
  target_link_libraries(test_c_api_threads PRIVATE Threads::Threads m)
endif()
add_test(NAME c_api_threads
         COMMAND test_c_api_threads ${CMAKE_CURRENT_SOURCE_DIR}/examples/spread_3line_chain.dat
                 ${CMAKE_CURRENT_SOURCE_DIR}/examples/syrope_polyester_mooring.dat
                 $<IF:$<BOOL:${CABLEDYN_HAVE_OPENBLAS_SET_NUM_THREADS}>,1,0>)
# TIMEOUT: a process hung in its exit path cannot be terminated and keeps its output
# pipes open; without a timeout CTest waits for it forever.
set_tests_properties(c_api_threads PROPERTIES LABELS "c;unit;capi;threading" TIMEOUT 600)
if(CABLEDYN_BLAS_RUNTIME_LOAD)
  # openblas.dll must not be mapped before the first CableDyn call.
  target_compile_definitions(test_c_api_threads PRIVATE CABLEDYN_BLAS_RUNTIME_LOAD=1)
endif()
# The same gate with a 32-thread OpenMP setting, which a pthreads OpenBLAS loaded outside
# the one-thread policy would size its pool from: the memory bound then fails on any
# machine, not only on one with 32 logical CPUs.
add_test(NAME c_api_threads_omp32
         COMMAND test_c_api_threads ${CMAKE_CURRENT_SOURCE_DIR}/examples/spread_3line_chain.dat
                 ${CMAKE_CURRENT_SOURCE_DIR}/examples/syrope_polyester_mooring.dat
                 $<IF:$<BOOL:${CABLEDYN_HAVE_OPENBLAS_SET_NUM_THREADS}>,1,0>)
set_tests_properties(c_api_threads_omp32 PROPERTIES LABELS "c;unit;capi;threading"
                     ENVIRONMENT "OMP_NUM_THREADS=32" TIMEOUT 600)
# Repeated concurrent phases in one process, under the in-process watchdog.
add_test(NAME c_api_threads_stress
         COMMAND test_c_api_threads ${CMAKE_CURRENT_SOURCE_DIR}/examples/spread_3line_chain.dat
                 ${CMAKE_CURRENT_SOURCE_DIR}/examples/syrope_polyester_mooring.dat
                 $<IF:$<BOOL:${CABLEDYN_HAVE_OPENBLAS_SET_NUM_THREADS}>,1,0>)
set_tests_properties(c_api_threads_stress PROPERTIES LABELS "c;unit;capi;threading" TIMEOUT 600
                     ENVIRONMENT "CABLEDYN_THREAD_TEST_LOOPS=5;CABLEDYN_THREAD_TEST_TIMEOUT=540")
# Concurrent steps on every per-handle route at once, 4 threads per deck, each trajectory against
# its deck's serial reference: EI = 0 chain and finite-EI cable on the coupled aggregate,
# viscoelastic and Syrope segments, a mixed EI = 0/finite-EI deck, Free points, a finite-EI
# power cable and a Free rod. Static locals or closure trampolines shared by the threads fail it.
add_test(NAME c_api_threads_mixed
         COMMAND test_c_api_threads --mixed 40
                 ${CMAKE_CURRENT_SOURCE_DIR}/tests/data/host_coupling_chain_cable.dat
                 ${CMAKE_CURRENT_SOURCE_DIR}/examples/ve_polyester_catenary_mooring.dat
                 ${CMAKE_CURRENT_SOURCE_DIR}/examples/syrope_polyester_mooring.dat
                 ${CMAKE_CURRENT_SOURCE_DIR}/examples/iea15mw_umaine_mixed_cabledyn.dat
                 ${CMAKE_CURRENT_SOURCE_DIR}/tests/data/foam_esflowc_box_points.dat
                 ${CMAKE_CURRENT_SOURCE_DIR}/examples/lozon_gomaine200_power_cable.dat
                 ${CMAKE_CURRENT_SOURCE_DIR}/tests/data/c_api_free_rod.dat)
set_tests_properties(c_api_threads_mixed PROPERTIES LABELS "c;unit;capi;threading" TIMEOUT 600
                     ENVIRONMENT "CABLEDYN_THREAD_TEST_TIMEOUT=540")
if(WIN32)
  # Host threads that ran OpenMP teams, then an immediate process exit: MinGW-w64
  # libgomp could hang in its exit handler when a pool thread was still ending.
  add_test(NAME c_api_threads_exit
           COMMAND test_c_api_threads --exit-stress ${CMAKE_CURRENT_SOURCE_DIR}/examples/spread_3line_chain.dat 1000)
  set_tests_properties(c_api_threads_exit PROPERTIES LABELS "c;unit;capi;threading" TIMEOUT 600
                       ENVIRONMENT "CABLEDYN_THREAD_TEST_TIMEOUT=540")
endif()
# Every LAPACK routine the Fortran sources call must be forwarded by src/cabledyn_blas.c;
# one that is not makes the shared library or the driver import openblas.dll at load time.
if(CABLEDYN_BLAS_RUNTIME_LOAD AND CMAKE_OBJDUMP)
  add_test(NAME blas_runtime_imports
           COMMAND ${CMAKE_COMMAND} -DOBJDUMP=${CMAKE_OBJDUMP}
                   "-DBINARIES=$<TARGET_FILE:cabledyn_shared>|$<TARGET_FILE:cabledyn>"
                   -P ${CMAKE_CURRENT_SOURCE_DIR}/tests/check_blas_runtime_imports.cmake)
  set_tests_properties(blas_runtime_imports PROPERTIES LABELS "c;unit;capi")
endif()
# Without openblas.dll, the driver and the C API must fail at initialisation with the
# load diagnostic (library, location tried, load error, requesting entry point).
if(CABLEDYN_BLAS_RUNTIME_LOAD)
  add_executable(test_c_api_blas_missing tests/test_c_api_blas_missing.c)
  target_include_directories(test_c_api_blas_missing PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}/src")
  target_link_libraries(test_c_api_blas_missing PRIVATE $<TARGET_LINKER_FILE:cabledyn_shared>)
  add_dependencies(test_c_api_blas_missing cabledyn_shared)
  add_executable(test_blas_missing_solve tests/test_blas_missing_solve.f90)
  target_link_libraries(test_blas_missing_solve PRIVATE cabledyn_core)
  add_test(NAME blas_missing_runtime
           COMMAND ${CMAKE_COMMAND} "-DBIN_DIR=$<TARGET_FILE_DIR:cabledyn_shared>"
                   "-DWORK_DIR=${CMAKE_BINARY_DIR}/blas_missing_runtime"
                   "-DDRIVER=$<TARGET_FILE:cabledyn>" "-DCAPI_TEST=$<TARGET_FILE:test_c_api_blas_missing>"
                   "-DSOLVE_TEST=$<TARGET_FILE:test_blas_missing_solve>"
                   "-DDECK=${CMAKE_CURRENT_SOURCE_DIR}/examples/spread_3line_chain.dat"
                   -P ${CMAKE_CURRENT_SOURCE_DIR}/tests/check_blas_missing_runtime.cmake)
  set_tests_properties(blas_missing_runtime PROPERTIES LABELS "c;unit;capi;integration")
endif()

# A raw line with no external load converges at very small dt (round-off force scale).
add_executable(test_c_api_raw_small_dt tests/test_c_api_raw_small_dt.c)
target_include_directories(test_c_api_raw_small_dt PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}/src")
target_link_libraries(test_c_api_raw_small_dt PRIVATE cabledyn_core)
if(NOT WIN32)
  target_link_libraries(test_c_api_raw_small_dt PRIVATE m)
endif()
add_test(NAME c_api_raw_small_dt COMMAND test_c_api_raw_small_dt)
set_tests_properties(c_api_raw_small_dt PROPERTIES LABELS "c;unit;capi;dynamic")

# Long coupled marches must not grow the process memory: catches per-step leaks in the
# C API deck route (EI=0 chain) and the OpenFAST aggregate route (EI=0 moorings plus a
# finite-EI Hermite cable, with snapshot, fluid fields, outputs, and channels).
add_library(cabledyn_test_process_memory STATIC tests/process_memory.c)
if(WIN32)
  target_link_libraries(cabledyn_test_process_memory PUBLIC psapi)
endif()
add_executable(test_memory_growth tests/test_memory_growth.c)
target_include_directories(test_memory_growth PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}/src")
target_link_libraries(test_memory_growth PRIVATE cabledyn_core cabledyn_test_process_memory)
if(NOT WIN32)
  target_link_libraries(test_memory_growth PRIVATE m)
endif()
# Growth bounds [MiB]: observed 0.0 MiB over 20000 C-API steps and 0.11 MiB over 1000
# aggregate steps; 2 MiB leaves room for allocator page granularity.
if(CABLEDYN_STATIC_WINDOWS_RELEASE)
  # The static IFX core archive holds /Qipo objects, which only an IFX link reads (link.exe,
  # the C linker, reports every CableDyn_* symbol unresolved): the C tests that link the core
  # directly link through IFX there.
  set_target_properties(test_c_api_raw_small_dt test_memory_growth PROPERTIES LINKER_LANGUAGE Fortran)
endif()
add_test(NAME memory_growth
         COMMAND test_memory_growth 2 ${CMAKE_CURRENT_SOURCE_DIR}/examples/spread_3line_chain.dat 20000)
set_tests_properties(memory_growth PROPERTIES LABELS "c;capi;dynamic;memory" SKIP_RETURN_CODE 77)
add_executable(test_memory_growth_agg tests/test_memory_growth_agg.f90)
target_link_libraries(test_memory_growth_agg PRIVATE cabledyn_core cabledyn_test_process_memory)
add_test(NAME memory_growth_aggregate
         COMMAND test_memory_growth_agg ${CMAKE_CURRENT_SOURCE_DIR}/examples/iea15mw_umaine_mixed_cabledyn.dat
                 200.0 1000 2)
set_tests_properties(memory_growth_aggregate PROPERTIES LABELS "fortran;openfast;dynamic;memory"
                     SKIP_RETURN_CODE 77)

# Zero heap allocations in the per-step aggregate advance after warm-up, counted through
# GNU ld --wrap malloc/calloc/realloc wrappers (GNU toolchains only).
if(CMAKE_Fortran_COMPILER_ID STREQUAL "GNU" AND CMAKE_C_COMPILER_ID STREQUAL "GNU")
  add_executable(test_step_allocations tests/test_step_allocations.f90 tests/allocation_counter.c
                 tests/allocation_phase_counter.c)
  target_link_libraries(test_step_allocations PRIVATE cabledyn_core)
  # the phase window of a whole driver run (tests/allocation_phase_counter.c) wraps CD_Profile_Enter
  target_link_options(test_step_allocations PRIVATE
                      "-Wl,--wrap=malloc,--wrap=calloc,--wrap=realloc,--wrap=__cabledyn_profile_MOD_cd_profile_enter")
  add_test(NAME step_allocations
           COMMAND test_step_allocations ${CMAKE_CURRENT_SOURCE_DIR}/examples/iea15mw_umaine_mixed_cabledyn.dat
                   200.0 200)
  set_tests_properties(step_allocations PROPERTIES LABELS "fortran;openfast;dynamic;memory")
  # The same gate with the range graphs of every line accumulated after each step.
  add_test(NAME step_allocations_ranges
           COMMAND test_step_allocations ${CMAKE_CURRENT_SOURCE_DIR}/tests/data/range_mixed_alloc.dat
                   200.0 200 ranges)
  set_tests_properties(step_allocations_ranges PROPERTIES LABELS "fortran;openfast;dynamic;memory")
  # The same gate on a finite-EI cable with condensed torsion (a turning parent and a changing twist).
  add_test(NAME step_allocations_torsion COMMAND test_step_allocations torsion)
  set_tests_properties(step_allocations_torsion PROPERTIES LABELS "fortran;dynamic;memory")
  # And with the nodal twist (polar inertia, torsional damping, the 7-DOF-per-node band).
  add_test(NAME step_allocations_nodal_twist COMMAND test_step_allocations nodal)
  set_tests_properties(step_allocations_nodal_twist PROPERTIES LABELS "fortran;dynamic;memory")
  # And the MoorDyn-C current grid (Currents 2 and 5) every standalone step samples at the nodes.
  add_test(NAME step_allocations_current_grid COMMAND test_step_allocations current_grid)
  set_tests_properties(step_allocations_current_grid PROPERTIES LABELS "fortran;dynamic;memory")
  # The standalone driver's march of a mixed deck with its prescribed motion (roll column, vessel).
  add_test(NAME step_allocations_motion_roll COMMAND test_step_allocations motion_roll)
  set_tests_properties(step_allocations_motion_roll PROPERTIES LABELS "fortran;dynamic;memory")
  add_test(NAME step_allocations_motion_vessel COMMAND test_step_allocations motion_vessel)
  set_tests_properties(step_allocations_motion_vessel PROPERTIES LABELS "fortran;dynamic;memory")
  # And with the deck's own current on that march (a Currents 5 grid that varies in time).
  add_test(NAME step_allocations_mixed_current COMMAND test_step_allocations mixed_current)
  file(MAKE_DIRECTORY ${CMAKE_BINARY_DIR}/step_alloc_mixed_current)
  set_tests_properties(step_allocations_mixed_current PROPERTIES LABELS "fortran;dynamic;memory")
  # And with the nodal twist of a line free in torsion at one end.
  add_test(NAME step_allocations_torsion_one_end COMMAND test_step_allocations free)
  set_tests_properties(step_allocations_torsion_one_end PROPERTIES LABELS "fortran;dynamic;memory")
  # The standalone driver's march of a finite-EI line on the cubic-Hermite route moved by a vessel,
  # run in process: the step phase of every step after warm-up.
  add_test(NAME step_allocations_driver_vessel COMMAND test_step_allocations driver_vessel)
  set_tests_properties(step_allocations_driver_vessel PROPERTIES LABELS "fortran;driver;dynamic;memory")
endif()

add_executable(test_snap_load tests/test_snap_load.f90)
target_link_libraries(test_snap_load PRIVATE cabledyn_core)
add_test(NAME snap_load COMMAND test_snap_load)
set_tests_properties(snap_load PROPERTIES LABELS "fortran;l5;validation;dynamic")

add_executable(test_l2_2_dynamic_parity tests/test_l2_2_dynamic_parity.f90)
target_link_libraries(test_l2_2_dynamic_parity PRIVATE cabledyn_core)
add_test(NAME l2_2_dynamic_parity_wd0050_a1 COMMAND test_l2_2_dynamic_parity WD0050/A1)
add_test(NAME l2_2_dynamic_parity_wd0050_a2 COMMAND test_l2_2_dynamic_parity WD0050/A2)
add_test(NAME l2_2_dynamic_parity_wd0200_a1 COMMAND test_l2_2_dynamic_parity WD0200/A1)
add_test(NAME l2_2_dynamic_parity_wd0200_a2 COMMAND test_l2_2_dynamic_parity WD0200/A2)
add_test(NAME l2_2_dynamic_parity_wd0600_a1 COMMAND test_l2_2_dynamic_parity WD0600/A1)
add_test(NAME l2_2_dynamic_parity_wd0600_a2 COMMAND test_l2_2_dynamic_parity WD0600/A2)
set_tests_properties(l2_2_dynamic_parity_wd0050_a1 l2_2_dynamic_parity_wd0050_a2
                     l2_2_dynamic_parity_wd0200_a1 l2_2_dynamic_parity_wd0200_a2
                     l2_2_dynamic_parity_wd0600_a1 l2_2_dynamic_parity_wd0600_a2
                     PROPERTIES
                       TIMEOUT 600
                       WORKING_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}"
                       ENVIRONMENT "OMP_NUM_THREADS=1;OMP_THREAD_LIMIT=1")
set_tests_properties(l2_2_dynamic_parity_wd0050_a1 l2_2_dynamic_parity_wd0050_a2
                     l2_2_dynamic_parity_wd0200_a1 l2_2_dynamic_parity_wd0200_a2
                     l2_2_dynamic_parity_wd0600_a1 l2_2_dynamic_parity_wd0600_a2
                     PROPERTIES LABELS "fortran;l2;validation;dynamic")
# Non-vacuity of the L2-2 OrcaFlex summary gate: the same WD0050/A1 cell with half the normal
# drag must be rejected by the summary comparison (the run prints the failing statistic).
add_test(NAME l2_2_dynamic_parity_perturbed_rejected COMMAND test_l2_2_dynamic_parity WD0050/A1 cdn=0.5)
set_tests_properties(l2_2_dynamic_parity_perturbed_rejected PROPERTIES
                       TIMEOUT 600
                       WORKING_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}"
                       ENVIRONMENT "OMP_NUM_THREADS=1;OMP_THREAD_LIMIT=1"
                       PASS_REGULAR_EXPRESSION "MISMATCH \\[WD0050/A1:fairlead:orcaflex-summary-h1-"
                       LABELS "fortran;l2;validation;dynamic")

# Analytical-catenary arbiter self-validation: the canonical closed-form grounded-catenary
# static reference (submerged weight supplied explicitly, no buoyancy convention baked in) that
# backs the static parity gates. Runs the tool's self-check, which exits non-zero if the
# equations/constants regress past its gate -- so a stale arbiter fails loudly in the validation
# path instead of silently passing. Registered only when a Python interpreter is found (the tool
# needs numpy/scipy in the validation env).
find_package(Python3 COMPONENTS Interpreter QUIET)
if(Python3_Interpreter_FOUND)
  # A Python interpreter selected from a Windows conda environment is not necessarily
  # launched through ``conda activate``. In that case extension modules cannot find the
  # DLLs in <prefix>/Library/bin (NumPy/OpenBLAS is the common failure) even though Python
  # itself starts normally. Keep that interpreter runtime ahead of the inherited PATH for
  # Python-driven tests only. Do not add CableDyn's deployment directory here: its OpenBLAS
  # DLL may otherwise pre-empt the BLAS runtime already loaded by NumPy.
  set(_cabledyn_python_test_environment "")
  set(_cabledyn_python_runtime_path "")
  if(WIN32)
    execute_process(
      COMMAND "${Python3_EXECUTABLE}" -c "import sys; print(sys.prefix)"
      RESULT_VARIABLE _cabledyn_python_prefix_rc
      OUTPUT_VARIABLE _cabledyn_python_prefix
      OUTPUT_STRIP_TRAILING_WHITESPACE
      ERROR_QUIET)
    if(_cabledyn_python_prefix_rc EQUAL 0 AND
       EXISTS "${_cabledyn_python_prefix}/Library/bin")
      set(_cabledyn_python_runtime_path
          "${_cabledyn_python_prefix}/Library/bin;$ENV{PATH}")
      string(REPLACE ";" "\\;" _cabledyn_python_runtime_path_escaped
             "${_cabledyn_python_runtime_path}")
      set(_cabledyn_python_test_environment
          "PATH=${_cabledyn_python_runtime_path_escaped}")
    endif()
  endif()

  # Public examples are executable input specifications. Keep their OPTIONS
  # rows in the documented OpenFAST value/key/comment/unit/choice layout.
  add_test(NAME example_deck_style
           COMMAND ${Python3_EXECUTABLE} ${CMAKE_CURRENT_SOURCE_DIR}/tests/test_example_deck_style.py)
  set_tests_properties(example_deck_style PROPERTIES
    LABELS "python;documentation;examples"
    ENVIRONMENT "${_cabledyn_python_test_environment}")

  # Every OpenMP parallel region prepares its threads for the abnormal-end report.
  add_test(NAME omp_fatal_init
           COMMAND ${Python3_EXECUTABLE} ${CMAKE_CURRENT_SOURCE_DIR}/tests/test_omp_fatal_init.py)
  set_tests_properties(omp_fatal_init PROPERTIES
    LABELS "python;unit;stack"
    ENVIRONMENT "${_cabledyn_python_test_environment}")

  # Storage that concurrent models could share: closures, implicit SAVE, unreviewed static
  # variables, and the automatic-locals flags (tests/test_thread_safe_sources.py).
  add_test(NAME thread_safe_sources
           COMMAND ${Python3_EXECUTABLE} ${CMAKE_CURRENT_SOURCE_DIR}/tests/test_thread_safe_sources.py)
  set_tests_properties(thread_safe_sources PROPERTIES
    LABELS "python;unit;threading"
    ENVIRONMENT "${_cabledyn_python_test_environment}")

  add_test(NAME documentation_sources
           COMMAND ${Python3_EXECUTABLE} ${CMAKE_CURRENT_SOURCE_DIR}/tests/test_documentation.py)
  set_tests_properties(documentation_sources PROPERTIES
    LABELS "python;documentation"
    ENVIRONMENT "${_cabledyn_python_test_environment}")

  # Audit the exact Git archive that would form a source release.
  add_test(NAME release_tree_audit
           COMMAND ${Python3_EXECUTABLE}
                   ${CMAKE_CURRENT_SOURCE_DIR}/release/audit_release_tree.py
                   --tree ${CMAKE_CURRENT_SOURCE_DIR})
  set_tests_properties(release_tree_audit PROPERTIES
    LABELS "python;documentation;release"
    ENVIRONMENT "${_cabledyn_python_test_environment}")

  # Solver-neutral cross-code comparison contract. This stdlib-only gate keeps
  # MoorDyn/OrcaFlex channel spelling at the adapter edge and rejects their
  # internal POINT/ROD discretization as CableDyn regression objects.
  add_test(NAME fem_observable_compare
           COMMAND ${Python3_EXECUTABLE} ${CMAKE_CURRENT_SOURCE_DIR}/tests/test_fem_observable_compare.py)
  set_tests_properties(fem_observable_compare PROPERTIES
    LABELS "python;validation;cross-code;fem-observable"
    ENVIRONMENT "${_cabledyn_python_test_environment}")

  add_test(NAME validation_records
           COMMAND ${Python3_EXECUTABLE} ${CMAKE_CURRENT_SOURCE_DIR}/tests/test_validation_records.py)
  set_tests_properties(validation_records PROPERTIES
    LABELS "python;validation;physical;performance"
    ENVIRONMENT "${_cabledyn_python_test_environment}")

  # Finite-EI cable statics robustness matrix: sampled robustness decks (admissible,
  # inadmissible, tensile-rejected, metamorphic and at-rest twins) through the driver.
  # The per-deck bound is on CPU time, so the verdict does not depend on machine load;
  # PROCESSORS reserves the four driver processes the matrix runs at once, and the
  # wall-clock TIMEOUT only stops a hang. The Release bound of 150 s (Debug 1500 s) scales every
  # per-deck bound by 2.5 so that slower hosted CI runners pass; it still catches a pathological
  # slowdown.
  add_test(NAME cable_statics_matrix
           COMMAND ${Python3_EXECUTABLE} ${CMAKE_CURRENT_SOURCE_DIR}/tests/test_cable_statics_matrix.py
                   --exe $<TARGET_FILE:cabledyn>
                   --cases ${CMAKE_CURRENT_SOURCE_DIR}/tests/data/cable_statics_matrix.json
                   --output ${CMAKE_BINARY_DIR}/cable_statics_matrix
                   --workers 4
                   --cpu-limit $<IF:$<CONFIG:Debug>,1500,150>)
  set_tests_properties(cable_statics_matrix PROPERTIES
    LABELS "python;hermite;static;robustness;slow"
    PROCESSORS 4
    TIMEOUT 1800
    ENVIRONMENT "${_cabledyn_python_test_environment}")

  # Finite-EI laid cable in a current held by seabed friction (0.1-1.5 m/s x mu 0.1-1.0,
  # isotropic and anisotropic, three headings): converges, balances globally within the
  # Coulomb capacity and stays at rest when marched from the static state.
  add_test(NAME laid_cable_friction_current
           COMMAND ${Python3_EXECUTABLE} ${CMAKE_CURRENT_SOURCE_DIR}/tests/test_laid_cable_friction_current.py
                   --exe $<TARGET_FILE:cabledyn>
                   --output ${CMAKE_BINARY_DIR}/laid_cable_friction_current
                   --workers 4)
  set_tests_properties(laid_cable_friction_current PROPERTIES
    LABELS "python;hermite;static;robustness;seabed"
    PROCESSORS 4
    TIMEOUT 900
    ENVIRONMENT "${_cabledyn_python_test_environment}")

  # Static seabed friction toward the as-laid position: a run on a slope below the friction
  # angle holds (EI = 0 and finite EI), the march continues the static springs at rest, a
  # line laid at its run tension reproduces the frictionless statics, and the inputs are
  # checked.
  add_test(NAME static_friction_as_laid
           COMMAND ${Python3_EXECUTABLE} ${CMAKE_CURRENT_SOURCE_DIR}/tests/test_static_friction_as_laid.py
                   --exe $<TARGET_FILE:cabledyn>
                   --output ${CMAKE_BINARY_DIR}/static_friction_as_laid)
  set_tests_properties(static_friction_as_laid PROPERTIES
    LABELS "python;static;seabed"
    TIMEOUT 600
    ENVIRONMENT "${_cabledyn_python_test_environment}")

  # Discrete buoyancy modules on a lazy wave in a cross current on a frictional seabed: the static
  # solve converges without a fallback and its end tensions match the equivalent smeared section.
  add_test(NAME attachment_cross_current
           COMMAND ${Python3_EXECUTABLE} ${CMAKE_CURRENT_SOURCE_DIR}/tests/test_attachment_cross_current.py
                   --exe $<TARGET_FILE:cabledyn>
                   --data ${CMAKE_CURRENT_SOURCE_DIR}/tests/data
                   --output ${CMAKE_BINARY_DIR}/attachment_cross_current)
  set_tests_properties(attachment_cross_current PROPERTIES
    LABELS "python;hermite;static;robustness;attachments"
    TIMEOUT 600
    ENVIRONMENT "${_cabledyn_python_test_environment}")

  # A clump on a cable clamped in a tight bend at its anchor: the attachment polish accepts the
  # residual floor of its solves at the coupled static tolerance, as the line's own solve does.
  add_test(NAME attachment_polish_floor
           COMMAND ${Python3_EXECUTABLE} ${CMAKE_CURRENT_SOURCE_DIR}/tests/test_attachment_polish_floor.py
                   --exe $<TARGET_FILE:cabledyn>
                   --output ${CMAKE_BINARY_DIR}/attachment_polish_floor)
  set_tests_properties(attachment_polish_floor PROPERTIES
    LABELS "python;hermite;static;robustness;attachments"
    TIMEOUT 900
    ENVIRONMENT "${_cabledyn_python_test_environment}")

  # A lazy wave on a strongly graded deck mesh (4 m and 10 m elements beside a refined buoyant
  # section) in oblique and cross currents: the route is repeated on the mesh refined element by
  # element to the bending length, and agrees with the deck on 2 m elements. PROCESSORS reserves
  # the four driver processes the test runs at once.
  add_test(NAME graded_mesh_statics
           COMMAND ${Python3_EXECUTABLE} ${CMAKE_CURRENT_SOURCE_DIR}/tests/test_graded_mesh_statics.py
                   --exe $<TARGET_FILE:cabledyn>
                   --data ${CMAKE_CURRENT_SOURCE_DIR}/tests/data
                   --output ${CMAKE_BINARY_DIR}/graded_mesh_statics)
  set_tests_properties(graded_mesh_statics PROPERTIES
    LABELS "python;hermite;static;robustness;attachments"
    PROCESSORS 4
    TIMEOUT 1500
    ENVIRONMENT "${_cabledyn_python_test_environment}")

  # Finite-EI generalised-alpha blends: force-blend dtM convergence under prescribed surge.
  add_test(NAME hermite_force_blend_dt
           COMMAND ${Python3_EXECUTABLE} ${CMAKE_CURRENT_SOURCE_DIR}/tests/test_hermite_force_blend_dt.py
                   --exe $<TARGET_FILE:cabledyn>
                   --deck ${CMAKE_CURRENT_SOURCE_DIR}/examples/lozon_gomex80_power_cable_motion.dat
                   --output ${CMAKE_BINARY_DIR}/hermite_force_blend_dt)
  set_tests_properties(hermite_force_blend_dt PROPERTIES
    LABELS "python;hermite;dynamic;validation"
    TIMEOUT 600
    ENVIRONMENT "${_cabledyn_python_test_environment}")

  # Finite-EI dynamic tensile monitor on the element-mean axial force: a tensile lazy wave
  # passes on a coarse mesh, a genuine compression is rejected on coarse and fine meshes.
  add_test(NAME hermite_tensile_monitor
           COMMAND ${Python3_EXECUTABLE} ${CMAKE_CURRENT_SOURCE_DIR}/tests/test_hermite_tensile_monitor.py
                   --exe $<TARGET_FILE:cabledyn>
                   --deck ${CMAKE_CURRENT_SOURCE_DIR}/examples/lozon_gomex80_power_cable_motion.dat
                   --output ${CMAKE_BINARY_DIR}/hermite_tensile_monitor)
  set_tests_properties(hermite_tensile_monitor PROPERTIES
    LABELS "python;hermite;dynamic;validation"
    TIMEOUT 600
    ENVIRONMENT "${_cabledyn_python_test_environment}")

  # A heavily damped finite-EI line held at rest completes every step and stays at rest over
  # a sweep of the axial damping coefficient and dtM (the damping's residual round-off floor).
  add_test(NAME hermite_damped_rest
           COMMAND ${Python3_EXECUTABLE} ${CMAKE_CURRENT_SOURCE_DIR}/tests/test_hermite_damped_rest.py
                   --exe $<TARGET_FILE:cabledyn>
                   --output ${CMAKE_BINARY_DIR}/hermite_damped_rest)
  set_tests_properties(hermite_damped_rest PROPERTIES
    LABELS "python;hermite;dynamic;robustness"
    TIMEOUT 300
    ENVIRONMENT "${_cabledyn_python_test_environment}")

  # Range graphs (LINES flag r) and touchdown channels on every standalone route: envelopes
  # against the node channels, the analytic catenary TDP, quasi-static tracking under a
  # moving fairlead, and agreement with cabledyn.touchdown_history (needs numpy).
  execute_process(
    COMMAND "${Python3_EXECUTABLE}" -c "import numpy"
    RESULT_VARIABLE _range_tdp_numpy_rc
    OUTPUT_QUIET ERROR_QUIET)
  if(_range_tdp_numpy_rc EQUAL 0)
    add_test(NAME range_graph_tdp
             COMMAND ${Python3_EXECUTABLE} ${CMAKE_CURRENT_SOURCE_DIR}/tests/test_range_tdp.py
                     --exe $<TARGET_FILE:cabledyn>
                     --examples ${CMAKE_CURRENT_SOURCE_DIR}/examples
                     --output ${CMAKE_BINARY_DIR}/range_graph_tdp)
    set_tests_properties(range_graph_tdp PROPERTIES
      LABELS "python;integration;static;dynamic;validation"
      TIMEOUT 600
      ENVIRONMENT "${_cabledyn_python_test_environment}")
  else()
    message(STATUS "range_graph_tdp: skipped (numpy not importable in ${Python3_EXECUTABLE})")
  endif()

  # TMax = 0 checks the static start of a dynamic deck: vesselMotion and motionFile records
  # that outlast TMax, RangeStart at TMax = 0, a deck of each route without dtM, and the hint of a
  # deck without dtM and TMax.
  add_test(NAME static_check
           COMMAND ${Python3_EXECUTABLE} ${CMAKE_CURRENT_SOURCE_DIR}/tests/test_static_check.py
                   --exe $<TARGET_FILE:cabledyn>
                   --examples ${CMAKE_CURRENT_SOURCE_DIR}/examples
                   --output ${CMAKE_BINARY_DIR}/static_check)
  set_tests_properties(static_check PROPERTIES
    LABELS "python;driver;integration;static;dynamic"
    TIMEOUT 600
    ENVIRONMENT "${_cabledyn_python_test_environment}")

  # EI = 0 statics: a residual that cycles inside its round-off floor is converged, so a line in
  # a current solves the same under every small translation of its deck.
  add_test(NAME ei0_static_floor_cycle
           COMMAND ${Python3_EXECUTABLE} ${CMAKE_CURRENT_SOURCE_DIR}/tests/test_ei0_static_floor_cycle.py
                   --exe $<TARGET_FILE:cabledyn>
                   --output ${CMAKE_BINARY_DIR}/ei0_static_floor_cycle)
  set_tests_properties(ei0_static_floor_cycle PROPERTIES
    LABELS "python;static;robustness"
    TIMEOUT 300
    ENVIRONMENT "${_cabledyn_python_test_environment}")

  # A Point3 buoy that starts off balance under bodyIC static is noted with its unbalanced force.
  add_test(NAME point3_balance_note
           COMMAND ${Python3_EXECUTABLE} ${CMAKE_CURRENT_SOURCE_DIR}/tests/test_point3_balance_note.py
                   --exe $<TARGET_FILE:cabledyn>
                   --output ${CMAKE_BINARY_DIR}/point3_balance_note)
  set_tests_properties(point3_balance_note PROPERTIES
    LABELS "python;bodies;static"
    TIMEOUT 300
    ENVIRONMENT "${_cabledyn_python_test_environment}")

  # Taut single-section Syrope ropes whose tension varies along them start at rest: every element
  # takes its own secant on its working curve.
  add_test(NAME syrope_taut_rest
           COMMAND ${Python3_EXECUTABLE} ${CMAKE_CURRENT_SOURCE_DIR}/tests/test_syrope_taut_rest.py
                   --exe $<TARGET_FILE:cabledyn>
                   --output ${CMAKE_BINARY_DIR}/syrope_taut_rest)
  set_tests_properties(syrope_taut_rest PROPERTIES
    LABELS "python;syrope;static;dynamic"
    TIMEOUT 300
    ENVIRONMENT "${_cabledyn_python_test_environment}")

  # The static residual-floor note reports a residual above the tolerance it says was missed.
  add_test(NAME static_floor_note
           COMMAND ${Python3_EXECUTABLE} ${CMAKE_CURRENT_SOURCE_DIR}/tests/test_static_floor_note.py
                   --exe $<TARGET_FILE:cabledyn>
                   --output ${CMAKE_BINARY_DIR}/static_floor_note)
  set_tests_properties(static_floor_note PROPERTIES
    LABELS "python;hermite;static"
    TIMEOUT 300
    ENVIRONMENT "${_cabledyn_python_test_environment}")

  # The static balance of a Connect point between a heavy chain and two wires on the seabed does
  # not cycle between trial steps, and agrees with the independent catenary balance.
  add_test(NAME point_static_cycle
           COMMAND ${Python3_EXECUTABLE} ${CMAKE_CURRENT_SOURCE_DIR}/tests/test_point_static_cycle.py
                   --exe $<TARGET_FILE:cabledyn>
                   --output ${CMAKE_BINARY_DIR}/point_static_cycle)
  set_tests_properties(point_static_cycle PROPERTIES
    LABELS "python;static;points;robustness"
    TIMEOUT 300
    ENVIRONMENT "${_cabledyn_python_test_environment}")

  # A Rigid-ended cable in a strong current follows its drag path past a limit point by the
  # pseudo-arclength continuation, as a stiff rotational spring does.
  add_test(NAME arclength_rigid_end
           COMMAND ${Python3_EXECUTABLE} ${CMAKE_CURRENT_SOURCE_DIR}/tests/test_arclength_rigid_end.py
                   --exe $<TARGET_FILE:cabledyn>
                   --output ${CMAKE_BINARY_DIR}/arclength_rigid_end)
  set_tests_properties(arclength_rigid_end PROPERTIES
    LABELS "python;hermite;static;robustness;current"
    TIMEOUT 900
    ENVIRONMENT "${_cabledyn_python_test_environment}")

  # The finite-EI statics of a clamped lazy wave do not depend on its azimuth: its restart at full
  # stiffness runs while the residual keeps falling instead of to a fixed count.
  add_test(NAME hermite_static_azimuth
           COMMAND ${Python3_EXECUTABLE} ${CMAKE_CURRENT_SOURCE_DIR}/tests/test_hermite_static_azimuth.py
                   --exe $<TARGET_FILE:cabledyn>
                   --output ${CMAKE_BINARY_DIR}/hermite_static_azimuth)
  set_tests_properties(hermite_static_azimuth PROPERTIES
    LABELS "python;hermite;static;robustness"
    TIMEOUT 900
    ENVIRONMENT "${_cabledyn_python_test_environment}")

  # The note on grounded lines that a current moves over a seabed without friction: once per run
  # on every standalone route, and never without a grounded node, a current, or a march, or
  # with friction.
  add_test(NAME seabed_drift_note
           COMMAND ${Python3_EXECUTABLE} ${CMAKE_CURRENT_SOURCE_DIR}/tests/test_seabed_drift_note.py
                   --exe $<TARGET_FILE:cabledyn>
                   --examples ${CMAKE_CURRENT_SOURCE_DIR}/examples
                   --output ${CMAKE_BINARY_DIR}/seabed_drift_note)
  set_tests_properties(seabed_drift_note PROPERTIES
    LABELS "python;driver;integration;contact"
    TIMEOUT 600
    ENVIRONMENT "${_cabledyn_python_test_environment}")

  # A rod numbered as a body is not one of the body's points: a Rod1B end POINT listed before
  # the Body1 points gives the run of the same deck with the rod renumbered, bit for bit.
  # A lazy wave restrained in torsion starts in an in-plane current (its untwisted state's
  # out-of-plane instability is kept, not refused by the torsion stage). The four pretwists run
  # at once: PROCESSORS reserves them, so no other test shares the cores (on a four-core runner
  # the Debug build took up to 900 s when it did).
  add_test(NAME torsion_current_start
           COMMAND ${Python3_EXECUTABLE} ${CMAKE_CURRENT_SOURCE_DIR}/tests/test_torsion_current_start.py
                   --exe $<TARGET_FILE:cabledyn>
                   --data ${CMAKE_CURRENT_SOURCE_DIR}/tests/data
                   --output ${CMAKE_BINARY_DIR}/torsion_current_start)
  set_tests_properties(torsion_current_start PROPERTIES
    LABELS "python;driver;integration;static"
    PROCESSORS 4
    TIMEOUT 1800
    ENVIRONMENT "${_cabledyn_python_test_environment}")

  # An EI = 0 line above the still-water level on a deck without a seabed carries its dry weight
  # (it was modelled fully submerged), as with a seabed and as a finite-EI line.
  add_test(NAME no_seabed_surface
           COMMAND ${Python3_EXECUTABLE} ${CMAKE_CURRENT_SOURCE_DIR}/tests/test_no_seabed_surface.py
                   --exe $<TARGET_FILE:cabledyn>
                   --output ${CMAKE_BINARY_DIR}/no_seabed_surface)
  set_tests_properties(no_seabed_surface PROPERTIES
    LABELS "python;driver;integration;dynamic"
    TIMEOUT 300
    ENVIRONMENT "${_cabledyn_python_test_environment}")

  add_test(NAME body_rod_numbering
           COMMAND ${Python3_EXECUTABLE} ${CMAKE_CURRENT_SOURCE_DIR}/tests/test_body_rod_numbering.py
                   --exe $<TARGET_FILE:cabledyn>
                   --output ${CMAKE_BINARY_DIR}/body_rod_numbering)
  set_tests_properties(body_rod_numbering PROPERTIES
    LABELS "python;driver;integration;dynamic"
    TIMEOUT 600
    ENVIRONMENT "${_cabledyn_python_test_environment}")

  # Anchor uplift channels (AnchFz/AnchFH, TDP<L>Grd): the analytic laid and suspended elastic
  # catenaries, the Point<P>F identity on every standalone route, and a surge that lifts the
  # anchor of a catenary (needs numpy).
  if(_range_tdp_numpy_rc EQUAL 0)
    add_test(NAME anchor_uplift_channels
             COMMAND ${Python3_EXECUTABLE} ${CMAKE_CURRENT_SOURCE_DIR}/tests/test_anchor_uplift.py
                     --exe $<TARGET_FILE:cabledyn>
                     --examples ${CMAKE_CURRENT_SOURCE_DIR}/examples
                     --output ${CMAKE_BINARY_DIR}/anchor_uplift_channels)
    set_tests_properties(anchor_uplift_channels PROPERTIES
      LABELS "python;integration;static;dynamic;validation"
      TIMEOUT 600
      ENVIRONMENT "${_cabledyn_python_test_environment}")
  else()
    message(STATUS "anchor_uplift_channels: skipped (numpy not importable in ${Python3_EXECUTABLE})")
  endif()

  # Cross-flow VIV lock-in of a taut line against MoorDyn-F, at a coarse and a zig-zag-resolving
  # dtM (needs numpy).
  if(_range_tdp_numpy_rc EQUAL 0)
    add_test(NAME viv_lockin
             COMMAND ${Python3_EXECUTABLE} ${CMAKE_CURRENT_SOURCE_DIR}/tests/test_viv_lockin.py
                     --exe $<TARGET_FILE:cabledyn>
                     --output ${CMAKE_BINARY_DIR}/viv_lockin)
    # eight benchmark runs, four at a time (PROCESSORS reserves them, so no other test shares
    # the cores); a checked Debug build is about ten times slower than Release
    if(CMAKE_BUILD_TYPE STREQUAL "Debug")
      set(_viv_lockin_timeout 2400)
    else()
      set(_viv_lockin_timeout 600)
    endif()
    set_tests_properties(viv_lockin PROPERTIES
      LABELS "python;integration;dynamic;viv;validation"
      PROCESSORS 4
      TIMEOUT ${_viv_lockin_timeout}
      ENVIRONMENT "${_cabledyn_python_test_environment}")
    # Syrope polyester with hydrodynamics against MoorDyn-C (a fairlead swaying in water)
    add_test(NAME syrope_hydro
             COMMAND ${Python3_EXECUTABLE} ${CMAKE_CURRENT_SOURCE_DIR}/tests/test_syrope_hydro.py
                     --exe $<TARGET_FILE:cabledyn>
                     --output ${CMAKE_BINARY_DIR}/syrope_hydro)
    set_tests_properties(syrope_hydro PROPERTIES
      LABELS "python;integration;dynamic;validation"
      TIMEOUT ${_viv_lockin_timeout}
      ENVIRONMENT "${_cabledyn_python_test_environment}")
    # MoorDyn-C's VIV test case: the catenary riser of Thorsen et al. in a uniform current
    add_test(NAME viv_riser
             COMMAND ${Python3_EXECUTABLE} ${CMAKE_CURRENT_SOURCE_DIR}/tests/test_viv_riser.py
                     --exe $<TARGET_FILE:cabledyn>
                     --output ${CMAKE_BINARY_DIR}/viv_riser)
    set_tests_properties(viv_riser PROPERTIES
      LABELS "python;integration;dynamic;viv;validation"
      TIMEOUT ${_viv_lockin_timeout}
      ENVIRONMENT "${_cabledyn_python_test_environment}")
    # MoorDyn-C Currents 2 and 5 runs: tensions against MoorDyn-C v2.7.1, two sources of one
    # field, and the static start in a sheared grid on the EI = 0 and finite-EI routes
    add_test(NAME mdc_currents_runs
             COMMAND ${Python3_EXECUTABLE} ${CMAKE_CURRENT_SOURCE_DIR}/tests/test_mdc_currents_runs.py
                     --exe $<TARGET_FILE:cabledyn>
                     --data ${CMAKE_CURRENT_SOURCE_DIR}/tests/data/currents_mdc
                     --output ${CMAKE_BINARY_DIR}/mdc_currents_runs)
    set_tests_properties(mdc_currents_runs PROPERTIES
      LABELS "python;integration;dynamic;validation"
      TIMEOUT ${_viv_lockin_timeout}
      ENVIRONMENT "${_cabledyn_python_test_environment}")
  else()
    message(STATUS "viv_lockin: skipped (numpy not importable in ${Python3_EXECUTABLE})")
  endif()

  # Deck-driver end-to-end oracles (need numpy): one linear sea written as deck wave rows, as a
  # MoorDyn-C WaveKin 7 table and as a WaveKin 3 record gives one line response; the modes of a
  # two-section string are the roots of its closed-form frequency equation; a cylindrical bend
  # stiffener is the section of cable and sleeve, and a cable clamped at the angle a off its
  # tangent carries the root moment a sqrt(EI T).
  if(_range_tdp_numpy_rc EQUAL 0)
    add_test(NAME wave_input_equivalence
             COMMAND ${Python3_EXECUTABLE} ${CMAKE_CURRENT_SOURCE_DIR}/tests/test_wave_input_equivalence.py
                     --exe $<TARGET_FILE:cabledyn>
                     --output ${CMAKE_BINARY_DIR}/wave_input_equivalence)
    set_tests_properties(wave_input_equivalence PROPERTIES
      LABELS "python;driver;integration;dynamic;validation"
      TIMEOUT 600
      ENVIRONMENT "${_cabledyn_python_test_environment}")
    add_test(NAME composite_string_modes
             COMMAND ${Python3_EXECUTABLE} ${CMAKE_CURRENT_SOURCE_DIR}/tests/test_composite_string_modes.py
                     --exe $<TARGET_FILE:cabledyn>
                     --output ${CMAKE_BINARY_DIR}/composite_string_modes)
    set_tests_properties(composite_string_modes PROPERTIES
      LABELS "python;driver;integration;static;modal;validation"
      TIMEOUT 600
      ENVIRONMENT "${_cabledyn_python_test_environment}")
    add_test(NAME stiffener_section_equivalence
             COMMAND ${Python3_EXECUTABLE} ${CMAKE_CURRENT_SOURCE_DIR}/tests/test_stiffener_section_equivalence.py
                     --exe $<TARGET_FILE:cabledyn>
                     --examples ${CMAKE_CURRENT_SOURCE_DIR}/examples
                     --output ${CMAKE_BINARY_DIR}/stiffener_section_equivalence)
    set_tests_properties(stiffener_section_equivalence PROPERTIES
      LABELS "python;driver;integration;static;dynamic;finite_ei;validation"
      TIMEOUT 600
      ENVIRONMENT "${_cabledyn_python_test_environment}")
  endif()

  # Node channels on a refined finite-EI line name deck nodes: the static profile's DeckNode
  # column, the standalone static and dynamic cubic-Hermite routes, the mixed route (the OpenFAST
  # aggregate evaluator) and the C API on the coarse lazy-wave deck the static solve refines
  # (needs numpy).
  if(_range_tdp_numpy_rc EQUAL 0)
    if(WIN32 AND CABLEDYN_RUNTIME_DLLS)
      set(_node_channels_library "${CMAKE_BINARY_DIR}/runtime/$<TARGET_FILE_NAME:cabledyn_shared>")
    else()
      set(_node_channels_library "$<TARGET_FILE:cabledyn_shared>")
    endif()
    add_test(NAME node_channels_refined_line
             COMMAND ${Python3_EXECUTABLE} ${CMAKE_CURRENT_SOURCE_DIR}/tests/test_node_channels_refined.py
                     --exe $<TARGET_FILE:cabledyn>
                     --deck ${CMAKE_CURRENT_SOURCE_DIR}/tests/data/lazy_wave_touchdown_planar_coarse.dat
                     --output ${CMAKE_BINARY_DIR}/node_channels_refined_line
                     --library ${_node_channels_library})
    set_tests_properties(node_channels_refined_line PROPERTIES
      LABELS "python;integration;static;dynamic;capi"
      TIMEOUT 600
      ENVIRONMENT "${_cabledyn_python_test_environment}")
    # Discrete buoyancy modules in oblique and cross currents (speed, heading, module count and
    # mesh refinement swept): the attachment polish converges without its fallbacks on a frictional
    # seabed, and a mid-water lazy wave's end forces balance its weight, buoyancy and drag (C API).
    # PROCESSORS reserves the four driver processes the test runs at once.
    add_test(NAME attachment_polish_current
             COMMAND ${Python3_EXECUTABLE} ${CMAKE_CURRENT_SOURCE_DIR}/tests/test_attachment_polish_current.py
                     --exe $<TARGET_FILE:cabledyn>
                     --library ${_node_channels_library}
                     --source ${CMAKE_CURRENT_SOURCE_DIR}
                     --output ${CMAKE_BINARY_DIR}/attachment_polish_current)
    set_tests_properties(attachment_polish_current PROPERTIES
      LABELS "python;hermite;static;robustness;attachments;capi"
      PROCESSORS 4
      TIMEOUT 900
      ENVIRONMENT "${_cabledyn_python_test_environment}")
  else()
    message(STATUS "node_channels_refined_line, attachment_polish_current: skipped (numpy not importable in ${Python3_EXECUTABLE})")
  endif()

  # The arbiter imports numpy + scipy at load time; only register the test when they are
  # importable, so an image with python3 but without those packages does not fail the
  # validation suite with ModuleNotFoundError before any CableDyn gate runs.
  if(_cabledyn_python_runtime_path)
    execute_process(
      COMMAND "${CMAKE_COMMAND}" -E env "PATH=${_cabledyn_python_runtime_path}"
              "${Python3_EXECUTABLE}" -c "import numpy, scipy"
      RESULT_VARIABLE _arbiter_deps_rc
      OUTPUT_QUIET ERROR_QUIET)
  else()
    execute_process(
      COMMAND "${Python3_EXECUTABLE}" -c "import numpy, scipy"
      RESULT_VARIABLE _arbiter_deps_rc
      OUTPUT_QUIET ERROR_QUIET)
  endif()
  if(_arbiter_deps_rc EQUAL 0)
    add_test(NAME analytical_catenary_arbiter
             COMMAND ${Python3_EXECUTABLE} ${CMAKE_CURRENT_SOURCE_DIR}/validation/scripts/analytical_catenary.py)
    set_tests_properties(analytical_catenary_arbiter PROPERTIES
      LABELS "python;validation;l2;static;arbiter"
      ENVIRONMENT "${_cabledyn_python_test_environment}")
  else()
    message(STATUS "analytical_catenary_arbiter: skipped (numpy/scipy not importable in ${Python3_EXECUTABLE})")
  endif()

  # cabledyn PYTHON PACKAGE gate: pytest over the ctypes binding (python/cabledyn) against
  # the built shared library -- the MoorDyn-C-style Python deployment surface. The suite
  # pins the binding to the SAME physics the Fortran gates certify (static fairlead pull,
  # fixed-point hold, deck-writer round-trip through the production parser), so a
  # prototype drift between CableDyn_CAPI and the binding fails as a physics mismatch,
  # not just a crash.
  if(_cabledyn_python_runtime_path)
    execute_process(
      COMMAND "${CMAKE_COMMAND}" -E env "PATH=${_cabledyn_python_runtime_path}"
              "${Python3_EXECUTABLE}" -c "import numpy, pytest"
      RESULT_VARIABLE _pybind_deps_rc
      OUTPUT_QUIET ERROR_QUIET)
  else()
    execute_process(
      COMMAND "${Python3_EXECUTABLE}" -c "import numpy, pytest"
      RESULT_VARIABLE _pybind_deps_rc
      OUTPUT_QUIET ERROR_QUIET)
  endif()
  if(_pybind_deps_rc EQUAL 0)
    add_test(NAME python_package
             COMMAND ${Python3_EXECUTABLE} -m pytest ${CMAKE_CURRENT_SOURCE_DIR}/python/tests -q)
    if(WIN32 AND CABLEDYN_RUNTIME_DLLS)
      # Python 3.8+ deliberately ignores PATH for dependent-DLL resolution.
      # Exercise the self-contained deployment set whose shared library and GNU/OpenBLAS
      # runtimes are co-located, rather than the bare link product in the build root.
      set(_cabledyn_python_library
          "${CMAKE_BINARY_DIR}/runtime/$<TARGET_FILE_NAME:cabledyn_shared>")
    else()
      set(_cabledyn_python_library "$<TARGET_FILE:cabledyn_shared>")
    endif()
    set_tests_properties(python_package PROPERTIES
      LABELS "fortran;python;capi;integration"
      ENVIRONMENT
        "${_cabledyn_python_test_environment};CABLEDYN_LIBRARY=${_cabledyn_python_library};\
CABLEDYN_TEST_DRIVER=$<TARGET_FILE:cabledyn>;PYTHONPATH=${CMAKE_CURRENT_SOURCE_DIR}/python")
  else()
    message(STATUS "python_package: skipped (numpy/pytest not importable in ${Python3_EXECUTABLE})")
  endif()
endif()

add_executable(test_cable_dynamic tests/test_cable_dynamic.f90)
target_link_libraries(test_cable_dynamic PRIVATE cabledyn_core)
add_test(NAME cable_dynamic COMMAND test_cable_dynamic)
set_tests_properties(cable_dynamic PROPERTIES LABELS "fortran;unit;reference;dynamic")

add_executable(test_cable_driver tests/test_cable_driver.f90)
target_link_libraries(test_cable_driver PRIVATE cabledyn_core)
add_test(NAME cable_driver COMMAND test_cable_driver)
set_tests_properties(cable_driver PROPERTIES LABELS "fortran;integration;static")

add_executable(test_line_driver tests/test_line_driver.f90)
target_link_libraries(test_line_driver PRIVATE cabledyn_core)
add_test(NAME line_driver COMMAND test_line_driver)
set_tests_properties(line_driver PROPERTIES LABELS "fortran;integration;static")

# Standalone analytical L1 gates scored on src/ against closed-form solutions (not
# the reference); `ctest -L l1` selects them. All ten L1 cases are gated on the two
# PRODUCTION paths: the EI=0 cable path carries L1-1 axial patch, L1-5 taut-string
# transverse vibration, L1-7 static catenary and L1-9 seabed reaction; the cubic-Hermite
# bending-cable path carries L1-2 bending/axial patch, L1-3 linear cantilever, L1-4
# large-deflection elastica, L1-6 Euler-beam vibration, L1-8 energy stability and
# L1-10 convergence order.
add_executable(test_l1_catenary tests/test_l1_catenary.f90)
target_link_libraries(test_l1_catenary PRIVATE cabledyn_core)
add_test(NAME l1_catenary COMMAND test_l1_catenary)
set_tests_properties(l1_catenary PROPERTIES LABELS "fortran;l1;validation;static")

add_executable(test_l1_axial_patch tests/test_l1_axial_patch.f90)
target_link_libraries(test_l1_axial_patch PRIVATE cabledyn_core)
add_test(NAME l1_axial_patch COMMAND test_l1_axial_patch)
set_tests_properties(l1_axial_patch PROPERTIES LABELS "fortran;l1;validation;static")

add_executable(test_l1_seabed tests/test_l1_seabed.f90)
target_link_libraries(test_l1_seabed PRIVATE cabledyn_core)
add_test(NAME l1_seabed COMMAND test_l1_seabed)
set_tests_properties(l1_seabed PROPERTIES LABELS "fortran;l1;validation;static")

add_executable(test_l1_string tests/test_l1_string.f90)
target_link_libraries(test_l1_string PRIVATE cabledyn_core)
add_test(NAME l1_string COMMAND test_l1_string)
set_tests_properties(l1_string PROPERTIES LABELS "fortran;l1;validation;dynamic")

# Finite-EI L1 gates on the PRODUCTION cubic-Hermite bending-cable path.
add_executable(test_l1_hermite_bending_patch tests/test_l1_hermite_bending_patch.f90)
target_link_libraries(test_l1_hermite_bending_patch PRIVATE cabledyn_core)
add_test(NAME l1_bending_patch COMMAND test_l1_hermite_bending_patch)
set_tests_properties(l1_bending_patch PROPERTIES LABELS "fortran;l1;validation;static")

add_executable(test_l1_hermite_cantilever tests/test_l1_hermite_cantilever.f90)
target_link_libraries(test_l1_hermite_cantilever PRIVATE cabledyn_core)
add_test(NAME l1_cantilever COMMAND test_l1_hermite_cantilever)
set_tests_properties(l1_cantilever PROPERTIES LABELS "fortran;l1;validation;static")

add_executable(test_l1_hermite_convergence tests/test_l1_hermite_convergence.f90)
target_link_libraries(test_l1_hermite_convergence PRIVATE cabledyn_core)
add_test(NAME l1_convergence_order COMMAND test_l1_hermite_convergence)
set_tests_properties(l1_convergence_order PROPERTIES LABELS "fortran;l1;validation;static")

add_executable(test_l1_hermite_elastica tests/test_l1_hermite_elastica.f90)
target_link_libraries(test_l1_hermite_elastica PRIVATE cabledyn_core)
add_test(NAME l1_large_deflection COMMAND test_l1_hermite_elastica)
set_tests_properties(l1_large_deflection PROPERTIES LABELS "fortran;l1;validation;static")

add_executable(test_l1_hermite_beam_vibration tests/test_l1_hermite_beam_vibration.f90)
target_link_libraries(test_l1_hermite_beam_vibration PRIVATE cabledyn_core)
add_test(NAME l1_euler_beam COMMAND test_l1_hermite_beam_vibration)
set_tests_properties(l1_euler_beam PROPERTIES LABELS "fortran;l1;validation;dynamic")

add_executable(test_l1_hermite_energy_stability tests/test_l1_hermite_energy_stability.f90)
target_link_libraries(test_l1_hermite_energy_stability PRIVATE cabledyn_core)
add_test(NAME l1_energy_stability COMMAND test_l1_hermite_energy_stability)
set_tests_properties(l1_energy_stability PROPERTIES LABELS "fortran;l1;validation;dynamic")

# The same six cases on the secondary Cosserat (rotation-DOF) path, kept as regression
# coverage for that element; `ctest -L cosserat` selects them.
add_executable(test_l1_bending_patch tests/test_l1_bending_patch.f90)
target_link_libraries(test_l1_bending_patch PRIVATE cabledyn_core)
add_test(NAME cosserat_bending_patch COMMAND test_l1_bending_patch)
set_tests_properties(cosserat_bending_patch PROPERTIES LABELS "fortran;cosserat;static")

# Linear isotropic rotational end connection: the spring is a configuration-dependent
# generalized load, so its force, consistent tangent, symmetry and the exact
# stretch-freedom property f.d == 0 are gated directly rather than inferred from a
# system-level result.
add_executable(test_endconn_spring tests/test_endconn_spring.f90)
target_link_libraries(test_endconn_spring PRIVATE cabledyn_core)
add_test(NAME endconn_spring COMMAND test_endconn_spring)
set_tests_properties(endconn_spring PROPERTIES LABELS "fortran;unit;endconnection;static")

# The same connection inside the finite-EI static solve: an analytic rigid-body rotation
# against the spring (a case that only has an isolated equilibrium BECAUSE the connection
# is there), plus the system-level stretch-freedom and pinned-limit statements.
add_executable(test_endconn_static tests/test_endconn_static.f90)
target_link_libraries(test_endconn_static PRIVATE cabledyn_core)
add_test(NAME endconn_static COMMAND test_endconn_static)
set_tests_properties(endconn_static PROPERTIES LABELS "fortran;endconnection;static;integration")

add_executable(test_l1_cantilever tests/test_l1_cantilever.f90)
target_link_libraries(test_l1_cantilever PRIVATE cabledyn_core)
add_test(NAME cosserat_cantilever COMMAND test_l1_cantilever)
set_tests_properties(cosserat_cantilever PROPERTIES LABELS "fortran;cosserat;static")

add_executable(test_l1_convergence_order tests/test_l1_convergence_order.f90)
target_link_libraries(test_l1_convergence_order PRIVATE cabledyn_core)
add_test(NAME cosserat_convergence_order COMMAND test_l1_convergence_order)
set_tests_properties(cosserat_convergence_order PROPERTIES LABELS "fortran;cosserat;static")

add_executable(test_l1_large_deflection tests/test_l1_large_deflection.f90)
target_link_libraries(test_l1_large_deflection PRIVATE cabledyn_core)
add_test(NAME cosserat_large_deflection COMMAND test_l1_large_deflection)
set_tests_properties(cosserat_large_deflection PROPERTIES LABELS "fortran;cosserat;static")

add_executable(test_l1_euler_beam tests/test_l1_euler_beam.f90)
target_link_libraries(test_l1_euler_beam PRIVATE cabledyn_core)
add_test(NAME cosserat_euler_beam COMMAND test_l1_euler_beam)
set_tests_properties(cosserat_euler_beam PROPERTIES LABELS "fortran;cosserat;dynamic")

add_executable(test_l1_energy_stability tests/test_l1_energy_stability.f90)
target_link_libraries(test_l1_energy_stability PRIVATE cabledyn_core)
add_test(NAME cosserat_energy_stability COMMAND test_l1_energy_stability)
set_tests_properties(cosserat_energy_stability PROPERTIES LABELS "fortran;cosserat;dynamic")

add_executable(test_l3_wave_smoke tests/test_l3_wave_smoke.f90)
target_link_libraries(test_l3_wave_smoke PRIVATE cabledyn_core)
add_test(NAME l3_wave_smoke COMMAND test_l3_wave_smoke)
set_tests_properties(l3_wave_smoke PROPERTIES LABELS "fortran;l3;dynamic;hydro")

# --- the standalone deck driver (cabledyn <deck.dat> <out_root>), released as CableDyn_driver ---
add_executable(cabledyn app/cabledyn.f90)
target_link_libraries(cabledyn PRIVATE cabledyn_core)
set(CABLEDYN_DRIVER_UTF8_MANIFEST OFF)
if(WIN32 AND (MSVC OR CMAKE_Fortran_SIMULATE_ID STREQUAL "MSVC"))
  # MSVC-style linkers embed a .manifest source, merged with the linker's own manifest.
  # This one makes UTF-8 the active code page, so the Fortran runtime's narrow file calls
  # open a working folder or file whose name is outside the system ANSI code page. The
  # MinGW runtime of the GNU build reaches such names through src/cabledyn_path.c.
  target_sources(cabledyn PRIVATE app/utf8_code_page.manifest)
  set(CABLEDYN_DRIVER_UTF8_MANIFEST ON)
endif()
if(CABLEDYN_DRIVER_UTF8_MANIFEST)
  # With an MSVC-style linker the driver and the shared library (OUTPUT_NAME cabledyn)
  # would write cabledyn.pdb and cabledyn.ilk to one directory; the product name keeps
  # them apart.
  set_target_properties(cabledyn PROPERTIES OUTPUT_NAME "CableDyn_driver")
endif()
if(CABLEDYN_STATIC_WINDOWS_RELEASE)
  # A 952-element production lazy-wave deck needs more than the PE default 1 MB
  # stack before IFX can enter its first dynamic step. Reserving address space is
  # cheap on x64 and matches the large-model contract of the standalone product.
  target_link_options(cabledyn PRIVATE "LINKER:/STACK:268435456")
endif()
install(TARGETS cabledyn RUNTIME DESTINATION ${CMAKE_INSTALL_BINDIR})
if(SKBUILD)
  # A Python wheel (pyproject.toml, scikit-build-core, install component `python`) carries the
  # C-ABI library beside the package modules, where cabledyn._discovery looks first, and the
  # driver in the package's bin folder, where cabledyn.driver looks after CABLEDYN_DRIVER. The
  # wheel repair tools bundle the runtime and LAPACK libraries they need.
  install(TARGETS cabledyn_shared
    RUNTIME DESTINATION cabledyn COMPONENT python
    LIBRARY DESTINATION cabledyn COMPONENT python)
  install(TARGETS cabledyn RUNTIME DESTINATION cabledyn/bin COMPONENT python)
endif()
if(WIN32 AND CABLEDYN_RUNTIME_DLLS)
  # A conventional GNU/conda Windows install must be usable outside the build
  # environment, not only from the separately assembled release bundle.
  install(FILES ${CABLEDYN_RUNTIME_DLLS} DESTINATION ${CMAKE_INSTALL_BINDIR})
endif()

add_executable(test_deck_driver tests/test_deck_driver.f90)
target_link_libraries(test_deck_driver PRIVATE cabledyn_core)
add_test(NAME deck_driver COMMAND test_deck_driver)
set_tests_properties(deck_driver PROPERTIES LABELS "fortran;driver;integration;static;dynamic")

add_executable(test_stream_wave tests/test_stream_wave.f90)
target_link_libraries(test_stream_wave PRIVATE cabledyn_core)
add_test(NAME stream_wave COMMAND test_stream_wave)
set_tests_properties(stream_wave PROPERTIES LABELS "fortran;unit;driver;dynamic;validation;orcaflex")

add_executable(test_modal tests/test_modal.f90 tests/blas_config_probe.c)
target_link_libraries(test_modal PRIVATE cabledyn_core)
add_test(NAME modal COMMAND test_modal)
set_tests_properties(modal PROPERTIES LABELS "fortran;unit;driver;static;validation")
# Modal analysis of a line restrained in torsion: the twist angle of every node joins the modes
# (torsional, elastic-end and torque-tension coupled modes, the lateral modes under a torque, the
# Schur complement of the angles against the condensed static tangent).
add_executable(test_modal_torsion tests/test_modal_torsion.f90)
target_link_libraries(test_modal_torsion PRIVATE cabledyn_core)
add_test(NAME modal_torsion COMMAND test_modal_torsion)
set_tests_properties(modal_torsion PROPERTIES LABELS "fortran;unit;static;validation")
# The modal eigensolves through CableDyn's LAPACK layer with every argument array against a
# no-access page: no read or write outside the arrays the modal code passes.
if(NOT CABLEDYN_STATIC_WINDOWS_RELEASE)
  add_executable(test_lapack_guard_pages tests/test_lapack_guard_pages.c)
  target_link_libraries(test_lapack_guard_pages PRIVATE cabledyn_core)
  set_target_properties(test_lapack_guard_pages PROPERTIES LINKER_LANGUAGE Fortran)
  add_test(NAME lapack_guard_pages COMMAND test_lapack_guard_pages)
  set_tests_properties(lapack_guard_pages PROPERTIES
                       LABELS "c;unit;static" TIMEOUT 300
                       ENVIRONMENT "OPENBLAS_CORETYPE=Haswell"
                       FAIL_REGULAR_EXPRESSION "FAIL:")
endif()

# Stack bound (GNU Windows builds): the modal test and the driver relinked with a 1 MiB stack
# reserve, half the MinGW default, instead of the 64 MiB reserve of the other executables. A
# large local array (as the dense matrices test_modal once kept on the stack) or a library
# frame that grows with the model overflows here on every machine. The driver runs a
# 2048-element finite-EI cable. Linux and macOS executables take their main-thread stack
# from the environment (ulimit -s), so these links are Windows-only; test_c_api_stack covers
# the library on every platform.
if(CABLEDYN_GNU_WINDOWS_STACK)
  file(MAKE_DIRECTORY "${CMAKE_BINARY_DIR}/stack_small")
  add_executable(test_modal_small_stack tests/test_modal.f90 tests/blas_config_probe.c)
  target_link_libraries(test_modal_small_stack PRIVATE cabledyn_core)
  add_executable(cabledyn_small_stack app/cabledyn.f90)
  target_link_libraries(cabledyn_small_stack PRIVATE cabledyn_core)
  foreach(_cabledyn_small IN ITEMS test_modal_small_stack cabledyn_small_stack)
    # Appended after the 64 MiB directory-wide option; the last --stack wins (checked below).
    target_link_options(${_cabledyn_small} PRIVATE "-Wl,--stack,${CABLEDYN_SMALL_STACK_RESERVE}")
  endforeach()
  add_test(NAME stack_modal COMMAND test_modal_small_stack
           WORKING_DIRECTORY "${CMAKE_BINARY_DIR}/stack_small")
  set_tests_properties(stack_modal PROPERTIES LABELS "fortran;unit;driver;static;stack")
  add_test(NAME stack_driver_large_deck
           COMMAND cabledyn_small_stack
                   "${CMAKE_CURRENT_SOURCE_DIR}/tests/data/stack_humboldt800_2048_elements.dat"
                   "${CMAKE_BINARY_DIR}/stack_small/stack_driver_large_deck")
  set_tests_properties(stack_driver_large_deck PROPERTIES
                       LABELS "fortran;driver;integration;dynamic;stack" TIMEOUT 900)
  # The reserve each link actually received, read from the PE headers: <binary>=<bytes>.
  string(JOIN "|" _cabledyn_stack_checks
         "$<TARGET_FILE:cabledyn>=${CABLEDYN_EXE_STACK_RESERVE}"
         "$<TARGET_FILE:test_modal>=${CABLEDYN_EXE_STACK_RESERVE}"
         "$<TARGET_FILE:test_c_api_stack>=${CABLEDYN_EXE_STACK_RESERVE}"
         "$<TARGET_FILE:test_modal_small_stack>=${CABLEDYN_SMALL_STACK_RESERVE}"
         "$<TARGET_FILE:cabledyn_small_stack>=${CABLEDYN_SMALL_STACK_RESERVE}")
  add_test(NAME stack_reserve
           COMMAND ${CMAKE_COMMAND} "-DCHECKS=${_cabledyn_stack_checks}"
                   -P ${CMAKE_CURRENT_SOURCE_DIR}/tests/check_stack_reserve.cmake)
  set_tests_properties(stack_reserve PROPERTIES LABELS "unit;driver;stack")
  # The check itself must see a reserve that differs from the expected one.
  add_test(NAME stack_reserve_mismatch
           COMMAND ${CMAKE_COMMAND}
                   "-DCHECKS=$<TARGET_FILE:test_modal_small_stack>=${CABLEDYN_EXE_STACK_RESERVE}"
                   -P ${CMAKE_CURRENT_SOURCE_DIR}/tests/check_stack_reserve.cmake)
  set_tests_properties(stack_reserve_mismatch PROPERTIES LABELS "unit;driver;stack"
                       PASS_REGULAR_EXPRESSION
                       "stack reserve ${CABLEDYN_SMALL_STACK_RESERVE} bytes, expected ${CABLEDYN_EXE_STACK_RESERVE}")
endif()

add_executable(test_seabed_friction_aniso tests/test_seabed_friction_aniso.f90)
target_link_libraries(test_seabed_friction_aniso PRIVATE cabledyn_core)
add_test(NAME seabed_friction_aniso COMMAND test_seabed_friction_aniso)
set_tests_properties(seabed_friction_aniso PROPERTIES LABELS "fortran;unit;driver;dynamic;seabed")

add_executable(test_wave_spectra tests/test_wave_spectra.f90)
target_link_libraries(test_wave_spectra PRIVATE cabledyn_core)
add_test(NAME wave_spectra COMMAND test_wave_spectra)
set_tests_properties(wave_spectra PROPERTIES LABELS "fortran;unit;driver;dynamic;validation")

add_executable(test_dynamics_regressions tests/test_dynamics_regressions.f90)
target_link_libraries(test_dynamics_regressions PRIVATE cabledyn_core)
add_test(NAME dynamics_regressions COMMAND test_dynamics_regressions)
set_tests_properties(dynamics_regressions PROPERTIES LABELS "fortran;driver;integration;dynamic")
# Tension-only lines going slack and snapping taut at the default rhoInf: force blend, release
# cap and the driver's run audit (the driver executable is passed for its stdout).
add_executable(test_ei0_slack_dynamics tests/test_ei0_slack_dynamics.f90)
target_link_libraries(test_ei0_slack_dynamics PRIVATE cabledyn_core)
add_test(NAME ei0_slack_dynamics COMMAND test_ei0_slack_dynamics $<TARGET_FILE:cabledyn>)
set_tests_properties(ei0_slack_dynamics PROPERTIES LABELS "fortran;driver;integration;dynamic")

add_executable(test_deck_reader_io tests/test_deck_reader_io.f90)
target_link_libraries(test_deck_reader_io PRIVATE cabledyn_core)
add_test(NAME deck_reader_io COMMAND test_deck_reader_io)
set_tests_properties(deck_reader_io PROPERTIES LABELS "fortran;driver;integration;static")

add_executable(test_body_rod_physics tests/test_body_rod_physics.f90)
target_link_libraries(test_body_rod_physics PRIVATE cabledyn_core)
add_test(NAME body_rod_physics COMMAND test_body_rod_physics)
set_tests_properties(body_rod_physics PROPERTIES LABELS "fortran;driver;integration;dynamic")
add_executable(test_monolithic_gates tests/test_monolithic_gates.f90)
target_link_libraries(test_monolithic_gates PRIVATE cabledyn_core)
add_test(NAME monolithic_gates COMMAND test_monolithic_gates)
set_tests_properties(monolithic_gates PROPERTIES LABELS "fortran;driver;integration;dynamic")

# MoorDyn-C WaveKin 3/7 and Currents 1 vs MoorDyn-C v2.7.1 on shared inputs (the reference rows
# come from validation/scripts/wavekin_mdc_probe.cpp)
file(GLOB CD_WAVEKIN_MDC_FILES RELATIVE ${CMAKE_SOURCE_DIR}/tests/data/wavekin_mdc
     ${CMAKE_SOURCE_DIR}/tests/data/wavekin_mdc/*)
foreach(f IN LISTS CD_WAVEKIN_MDC_FILES)
  configure_file(tests/data/wavekin_mdc/${f} ${CMAKE_BINARY_DIR}/wavekin_mdc/${f} COPYONLY)
endforeach()
# the same with a mean level (an omega = 0 row, a raised record), against MoorDyn-C v2.7.2
file(GLOB CD_WAVEKIN_MDC_MEAN_FILES RELATIVE ${CMAKE_SOURCE_DIR}/tests/data/wavekin_mdc_mean
     ${CMAKE_SOURCE_DIR}/tests/data/wavekin_mdc_mean/*)
foreach(f IN LISTS CD_WAVEKIN_MDC_MEAN_FILES)
  configure_file(tests/data/wavekin_mdc_mean/${f} ${CMAKE_BINARY_DIR}/wavekin_mdc_mean/${f} COPYONLY)
endforeach()
add_executable(test_wavekin_modes tests/test_wavekin_modes.f90)
target_link_libraries(test_wavekin_modes PRIVATE cabledyn_core)
add_test(NAME wavekin_modes COMMAND test_wavekin_modes WORKING_DIRECTORY ${CMAKE_BINARY_DIR})
set_tests_properties(wavekin_modes PROPERTIES LABELS "fortran;driver;validation;dynamic")

# MoorDyn-C Currents 2 and 5 vs MoorDyn-C v2.7.1 and an independent evaluation on shared inputs
# (the reference rows come from validation/scripts/currents_mdc_reference.py)
file(GLOB_RECURSE CD_CURRENTS_MDC_FILES RELATIVE ${CMAKE_SOURCE_DIR}/tests/data/currents_mdc
     ${CMAKE_SOURCE_DIR}/tests/data/currents_mdc/*)
foreach(f IN LISTS CD_CURRENTS_MDC_FILES)
  configure_file(tests/data/currents_mdc/${f} ${CMAKE_BINARY_DIR}/currents_mdc/${f} COPYONLY)
endforeach()
add_executable(test_mdc_currents tests/test_mdc_currents.f90)
target_link_libraries(test_mdc_currents PRIVATE cabledyn_core)
add_test(NAME mdc_currents COMMAND test_mdc_currents WORKING_DIRECTORY ${CMAKE_BINARY_DIR}/mdc_currents_work)
set_tests_properties(mdc_currents PROPERTIES LABELS "fortran;driver;validation;dynamic")
file(MAKE_DIRECTORY ${CMAKE_BINARY_DIR}/mdc_currents_work)

add_executable(test_clamped_cable_ends tests/test_clamped_cable_ends.f90)
target_link_libraries(test_clamped_cable_ends PRIVATE cabledyn_core)
add_test(NAME clamped_cable_ends COMMAND test_clamped_cable_ends)
set_tests_properties(clamped_cable_ends PROPERTIES LABELS "fortran;driver;integration;static;dynamic")

add_executable(test_torsion_deck tests/test_torsion_deck.f90)
target_link_libraries(test_torsion_deck PRIVATE cabledyn_core)
add_test(NAME torsion_deck COMMAND test_torsion_deck)
set_tests_properties(torsion_deck PROPERTIES LABELS "fortran;driver;integration;static;dynamic")

add_executable(test_torsion_attachments tests/test_torsion_attachments.f90)
target_link_libraries(test_torsion_attachments PRIVATE cabledyn_core)
add_test(NAME torsion_attachments
         COMMAND test_torsion_attachments ${CMAKE_CURRENT_SOURCE_DIR}/tests/data/lazy_wave_torsion_attachments.dat
         WORKING_DIRECTORY ${CMAKE_BINARY_DIR})
set_tests_properties(torsion_attachments PROPERTIES LABELS "fortran;driver;integration;static;dynamic")
add_executable(test_rod_end_torsion tests/test_rod_end_torsion.f90)
target_link_libraries(test_rod_end_torsion PRIVATE cabledyn_core)
add_test(NAME rod_end_torsion COMMAND test_rod_end_torsion)
set_tests_properties(rod_end_torsion PROPERTIES LABELS "fortran;driver;integration;static;dynamic")

# Where the MoorDyn-parity features meet: a CoupledPinned body in a Currents 2/5 deck (refused on
# the coupled aggregate for the current files, standalone for the body), CONTROL on viscoelastic
# and Syrope segments in the host's cross-flow against the static start of the changed deck, and
# ATTACHMENTS on a turned torsion line in a sheared Currents 5 grid (a still run keeps the start)
add_executable(test_parity_integration tests/test_parity_integration.f90)
target_link_libraries(test_parity_integration PRIVATE cabledyn_core)
file(MAKE_DIRECTORY ${CMAKE_BINARY_DIR}/parity_integration)
add_test(NAME parity_integration
         COMMAND test_parity_integration ${CMAKE_CURRENT_SOURCE_DIR}/tests/data/lazy_wave_torsion_attachments.dat
         WORKING_DIRECTORY ${CMAKE_BINARY_DIR}/parity_integration)
set_tests_properties(parity_integration PROPERTIES LABELS "fortran;driver;integration;dynamic;openfast")

add_executable(test_two_moving_ends tests/test_two_moving_ends.f90)
target_link_libraries(test_two_moving_ends PRIVATE cabledyn_core)
add_test(NAME two_moving_ends COMMAND test_two_moving_ends)
set_tests_properties(two_moving_ends PROPERTIES LABELS "fortran;driver;integration;dynamic;openfast")

add_executable(test_cable_between_bodies tests/test_cable_between_bodies.f90)
target_link_libraries(test_cable_between_bodies PRIVATE cabledyn_core)
add_test(NAME cable_between_bodies COMMAND test_cable_between_bodies)
set_tests_properties(cable_between_bodies PROPERTIES LABELS "fortran;driver;integration;dynamic;static")
# The static passes of a cable restrained in torsion between two moored bodies converge at every
# pretwist (they stop at the resolution of the core's balance): the mirror-symmetric start, held.
add_executable(test_torsion_body_passes tests/test_torsion_body_passes.f90)
target_link_libraries(test_torsion_body_passes PRIVATE cabledyn_core)
add_test(NAME torsion_body_passes COMMAND test_torsion_body_passes)
set_tests_properties(torsion_body_passes PROPERTIES LABELS "fortran;driver;integration;dynamic;static")

add_executable(test_pinned_cable_light_object tests/test_pinned_cable_light_object.f90)
target_link_libraries(test_pinned_cable_light_object PRIVATE cabledyn_core)
add_test(NAME pinned_cable_light_object COMMAND test_pinned_cable_light_object)
set_tests_properties(pinned_cable_light_object PROPERTIES LABELS "fortran;driver;integration;dynamic")

add_executable(test_section_curvature tests/test_section_curvature.f90)
target_link_libraries(test_section_curvature PRIVATE cabledyn_core)
add_test(NAME section_curvature COMMAND test_section_curvature)
set_tests_properties(section_curvature PROPERTIES LABELS "fortran;driver;integration;static")

add_executable(test_syrope_composite tests/test_syrope_composite.f90)
target_link_libraries(test_syrope_composite PRIVATE cabledyn_core)
add_test(NAME syrope_composite COMMAND test_syrope_composite)
set_tests_properties(syrope_composite PROPERTIES LABELS "fortran;driver;integration;static;dynamic")

# Active line control of Syrope segments on the coupled route (the slow stretch carried over a
# length change, as MoorDyn-F/C carry it): quasi-static cycle, length step, restart, composites
add_executable(test_syrope_control tests/test_syrope_control.f90)
target_link_libraries(test_syrope_control PRIVATE cabledyn_core)
add_test(NAME syrope_control COMMAND test_syrope_control)
set_tests_properties(syrope_control PROPERTIES LABELS "fortran;integration;dynamic;openfast")

# Active line control of viscoelastic (ElasticMod 2/3) segments on the coupled route (the dl_1
# stretch carried over a length change, as MoorDyn-F/C carry it): quasi-static cycle, step, restart
add_executable(test_viscoelastic_control tests/test_viscoelastic_control.f90)
target_link_libraries(test_viscoelastic_control PRIVATE cabledyn_core)
add_test(NAME viscoelastic_control COMMAND test_viscoelastic_control)
set_tests_properties(viscoelastic_control PROPERTIES LABELS "fortran;integration;dynamic;openfast")

add_executable(test_torsion_coupling tests/test_torsion_coupling.f90)
target_link_libraries(test_torsion_coupling PRIVATE cabledyn_core)
add_test(NAME torsion_coupling COMMAND test_torsion_coupling)
set_tests_properties(torsion_coupling PROPERTIES LABELS "fortran;unit;driver;integration;static")
# A held line under strong torque-tension coupling (K up to 0.99 sqrt(EA GJ), either sense, one
# end free in torsion) stays still at the default dtM and dynamic tolerance: the round-off floor of
# the step's convergence norm carries the coupling's share of the axial force and of the torque.
add_executable(test_torsion_coupling_still tests/test_torsion_coupling_still.f90)
target_link_libraries(test_torsion_coupling_still PRIVATE cabledyn_core)
add_test(NAME torsion_coupling_still COMMAND test_torsion_coupling_still)
set_tests_properties(torsion_coupling_still PROPERTIES LABELS "fortran;driver;integration;dynamic")

# Torsion and prescribed motion on the standalone mixed EI = 0 + finite-EI route (the driver
# executable marches the aggregate): route equivalence with the cubic-Hermite route under vessel
# and roll-column motion, quasi-static torque, roll-column refusal.
add_executable(test_mixed_route_torsion tests/test_mixed_route_torsion.f90)
target_link_libraries(test_mixed_route_torsion PRIVATE cabledyn_core)
add_test(NAME mixed_route_torsion COMMAND test_mixed_route_torsion $<TARGET_FILE:cabledyn>)
set_tests_properties(mixed_route_torsion PROPERTIES LABELS "fortran;driver;integration;dynamic")
# A standalone TURBINES deck of a finite-EI cable between two turbines and chain legs on the mixed
# route, against its cable-only and legs-only decks (gate 9).
add_test(NAME mixed_route_turbines COMMAND test_mixed_route_torsion $<TARGET_FILE:cabledyn> turbines)
set_tests_properties(mixed_route_turbines PROPERTIES LABELS "fortran;driver;integration;dynamic")

# Deck currents on the standalone mixed route (the aggregate samples the deck current at every
# node before each step): OPTION uniform and profile and MoorDyn-C Currents 1/2/5 against the
# single-line routes, the wrap of a time-varying table, uniform writings of one field, snapshot
# and restore, and the refusals that remain (deck waves, double counting, no dtM).
add_executable(test_mixed_route_currents tests/test_mixed_route_currents.f90)
target_link_libraries(test_mixed_route_currents PRIVATE cabledyn_core)
add_test(NAME mixed_route_currents COMMAND test_mixed_route_currents $<TARGET_FILE:cabledyn>
         WORKING_DIRECTORY ${CMAKE_BINARY_DIR}/mixed_route_currents_work)
set_tests_properties(mixed_route_currents PROPERTIES LABELS "fortran;driver;integration;dynamic")
foreach(_mrc_case uni prof still wav c1 c2 c2u c2h c2d c5 c1u c5u)
  file(MAKE_DIRECTORY ${CMAKE_BINARY_DIR}/mixed_route_currents_work/${_mrc_case})
endforeach()

add_executable(test_coupled_torsion tests/test_coupled_torsion.f90)
target_link_libraries(test_coupled_torsion PRIVATE cabledyn_core)
add_test(NAME coupled_torsion COMMAND test_coupled_torsion WORKING_DIRECTORY ${CMAKE_BINARY_DIR})
set_tests_properties(coupled_torsion PROPERTIES LABELS "fortran;unit;static;dynamic;openfast")

# OpenFAST linearisation of a line restrained in torsion, by the shell's lin_eval recipe on the
# aggregate: the twist modes of A against n pi/L sqrt(GJ/Irn), the reduced roll stiffness GJ/L
# (nodal twist and condensed), the damping and inertia columns of the platform's angular rates.
add_executable(test_lin_torsion tests/test_lin_torsion.f90)
target_link_libraries(test_lin_torsion PRIVATE cabledyn_core)
add_test(NAME lin_torsion COMMAND test_lin_torsion WORKING_DIRECTORY ${CMAKE_BINARY_DIR})
set_tests_properties(lin_torsion PROPERTIES LABELS "fortran;unit;dynamic;openfast")
# A line restrained in torsion at one end only: the clamped-free torsional modes and waves of the
# nodal twist, the free end's coupling twist, the deck channels, the standalone driver and the
# coupled aggregate.
add_executable(test_torsion_one_end tests/test_torsion_one_end.f90)
target_link_libraries(test_torsion_one_end PRIVATE cabledyn_core)
add_test(NAME torsion_one_end COMMAND test_torsion_one_end WORKING_DIRECTORY ${CMAKE_BINARY_DIR})
set_tests_properties(torsion_one_end PROPERTIES LABELS "fortran;unit;driver;integration;static;dynamic;openfast")

add_executable(test_torsion_orcaflex tests/test_torsion_orcaflex.f90)
target_link_libraries(test_torsion_orcaflex PRIVATE cabledyn_core)
add_test(NAME torsion_orcaflex
         COMMAND test_torsion_orcaflex ${CMAKE_CURRENT_SOURCE_DIR}/tests/data/torsion_orcaflex_refs.txt)
set_tests_properties(torsion_orcaflex PROPERTIES LABELS "fortran;driver;integration;static;validation;l3")

add_executable(test_rod_hydro tests/test_rod_hydro.f90)
target_link_libraries(test_rod_hydro PRIVATE cabledyn_core)
add_test(NAME rod_hydro COMMAND test_rod_hydro)
set_tests_properties(rod_hydro PROPERTIES LABELS "fortran;unit;dynamic;static")

add_executable(test_body_hydro tests/test_body_hydro.f90)
target_link_libraries(test_body_hydro PRIVATE cabledyn_core)
add_test(NAME body_hydro COMMAND test_body_hydro)
set_tests_properties(body_hydro PROPERTIES LABELS "fortran;unit;dynamic;static")

add_executable(test_shared_anchor tests/test_shared_anchor.f90)
target_link_libraries(test_shared_anchor PRIVATE cabledyn_core)
add_test(NAME shared_anchor COMMAND test_shared_anchor)
set_tests_properties(shared_anchor PROPERTIES LABELS "fortran;driver;integration;static;dynamic")

add_executable(test_bodies_rods tests/test_bodies_rods.f90)
target_link_libraries(test_bodies_rods PRIVATE cabledyn_core)
add_test(NAME bodies_rods COMMAND test_bodies_rods)
set_tests_properties(bodies_rods PROPERTIES LABELS "fortran;driver;integration;static;dynamic")

add_test(
  NAME driver_nonconvergence
  COMMAND ${CMAKE_COMMAND}
    -DDRIVER=$<TARGET_FILE:cabledyn>
    -DDECK=${CMAKE_CURRENT_SOURCE_DIR}/tests/data/nonconvergent_motion.dat
    -DOUTPUT_ROOT=${CMAKE_CURRENT_BINARY_DIR}/driver_nonconvergence
    -P ${CMAKE_CURRENT_SOURCE_DIR}/tests/check_driver_nonconvergence.cmake)
set_tests_properties(driver_nonconvergence PROPERTIES
  LABELS "fortran;driver;integration;dynamic;failure")

# libgfortran's per-statement setlocale restore reads freed UCRT memory on MinGW-w64
# unless src/cabledyn_crt_locale.c redirects its import. The unit check requires the
# redirect there and releases the freed pages mid-WRITE, which faults deterministically
# without the guard; the repeat run requires a clean exit from every process.
add_executable(test_crt_locale_guard tests/test_crt_locale_guard.f90 tests/crt_locale_guard_heap.c)
target_link_libraries(test_crt_locale_guard PRIVATE cabledyn_core)
add_test(NAME crt_locale_guard COMMAND test_crt_locale_guard $<IF:$<BOOL:${MINGW}>,1,0>)
set_tests_properties(crt_locale_guard PROPERTIES LABELS "fortran;unit")
# The x86-64-v3 start-up processor check is armed exactly in CABLEDYN_TARGET_AVX2 builds.
add_executable(test_cpu_guard tests/test_cpu_guard.f90)
target_link_libraries(test_cpu_guard PRIVATE cabledyn_core)
add_test(NAME cpu_guard COMMAND test_cpu_guard $<IF:$<BOOL:${CABLEDYN_TARGET_AVX2}>,1,0>)
set_tests_properties(cpu_guard PROPERTIES LABELS "fortran;unit")
if(CABLEDYN_TARGET_AVX2)
  # The armed check stops the driver before any Fortran code runs, with the message naming
  # what is missing (a simulated feature, so the stop is exercised on any processor).
  add_test(NAME cpu_guard_stop
           COMMAND ${CMAKE_COMMAND} -E env CABLEDYN_CPU_GUARD_SIMULATE=SIMULATED-FEATURE
                   $<TARGET_FILE:cabledyn> --version)
  set_tests_properties(cpu_guard_stop PROPERTIES LABELS "fortran;unit"
    PASS_REGULAR_EXPRESSION "This computer lacks: SIMULATED-FEATURE"
    FAIL_REGULAR_EXPRESSION "CableDyn  v")
endif()
# An abnormal end of the driver process is never silent: a stack overflow (on a 1 MiB stack
# in Windows GNU builds), an access violation and, off Windows, SIGTERM each end the process
# with a report on stderr of the cause and the simulated time reached; the march records the
# time of every committed step for that report.
add_executable(test_fatal_report tests/test_fatal_report.f90 tests/fatal_report_faults.c)
target_link_libraries(test_fatal_report PRIVATE cabledyn_core)
if(CABLEDYN_GNU_WINDOWS_STACK)
  target_link_options(test_fatal_report PRIVATE "-Wl,--stack,${CABLEDYN_SMALL_STACK_RESERVE}")
endif()
file(MAKE_DIRECTORY "${CMAKE_BINARY_DIR}/fatal_report")
add_test(NAME fatal_report_march
         COMMAND test_fatal_report march ${CMAKE_CURRENT_SOURCE_DIR}/examples/dynamic_chain_held.dat
                 ${CMAKE_BINARY_DIR}/fatal_report/march)
set_tests_properties(fatal_report_march PROPERTIES LABELS "fortran;unit;driver;dynamic")
# The cause names the fault as each platform delivers it (macOS may deliver SIGBUS).
foreach(_fatal IN ITEMS "overflow|during|(stack overflow|segmentation fault|bus error)"
                        "overflow|before|(stack overflow|segmentation fault|bus error)"
                        "null|during|(access violation|segmentation fault|bus error)"
                        "term|during|a termination request")
  string(REPLACE "|" ";" _fatal_case "${_fatal}")
  list(GET _fatal_case 0 _fatal_mode)
  list(GET _fatal_case 1 _fatal_when)
  list(SUBLIST _fatal_case 2 -1 _fatal_cause)
  string(JOIN "|" _fatal_cause ${_fatal_cause})
  add_test(NAME fatal_report_${_fatal_mode}_${_fatal_when}
           COMMAND ${CMAKE_COMMAND} -DEXE=$<TARGET_FILE:test_fatal_report> -DMODE=${_fatal_mode}
                   -DWHEN=${_fatal_when} "-DCAUSE=${_fatal_cause}"
                   -P ${CMAKE_CURRENT_SOURCE_DIR}/tests/check_fatal_report.cmake)
  set_tests_properties(fatal_report_${_fatal_mode}_${_fatal_when} PROPERTIES
                       LABELS "fortran;unit;driver;stack" TIMEOUT 120)
endforeach()
# A stack overflow on an OpenMP worker thread with a 1 MiB stack is reported too: every
# thread that enters a parallel region gets room for the handlers (tests/test_omp_fatal_init.py
# checks that every region of the library and the driver asks for it).
add_test(NAME fatal_report_omp_overflow_during
         COMMAND ${CMAKE_COMMAND} -DEXE=$<TARGET_FILE:test_fatal_report> -DMODE=omp_overflow
                 -DWHEN=during "-DCAUSE=(stack overflow|segmentation fault|bus error)"
                 -P ${CMAKE_CURRENT_SOURCE_DIR}/tests/check_fatal_report.cmake)
set_tests_properties(fatal_report_omp_overflow_during PROPERTIES
                     LABELS "fortran;unit;driver;stack" TIMEOUT 120
                     ENVIRONMENT "OMP_NUM_THREADS=2;OMP_STACKSIZE=1M")
# POSIX: a hardware fault keeps its own siginfo and context through the report.
add_test(NAME fatal_report_fault_context COMMAND test_fatal_report context)
set_tests_properties(fatal_report_fault_context PROPERTIES
                     LABELS "fortran;unit;driver;stack" TIMEOUT 120
                     FAIL_REGULAR_EXPRESSION "FAIL:")
# POSIX: the report keeps every previous disposition -- an ignored signal (with or without
# SA_SIGINFO) stays ignored, a default one still ends the process, a handler still runs.
add_test(NAME fatal_report_sent_faults COMMAND test_fatal_report sent_faults)
set_tests_properties(fatal_report_sent_faults PROPERTIES
                     LABELS "fortran;unit;driver" TIMEOUT 120
                     FAIL_REGULAR_EXPRESSION "FAIL:")
add_test(NAME fatal_report_altstack COMMAND test_fatal_report altstack)
set_tests_properties(fatal_report_altstack PROPERTIES
                     LABELS "fortran;unit;driver;stack" TIMEOUT 120
                     FAIL_REGULAR_EXPRESSION "FAIL:")
add_test(NAME fatal_report_dispositions COMMAND test_fatal_report dispositions)
set_tests_properties(fatal_report_dispositions PROPERTIES
                     LABELS "fortran;unit;driver" TIMEOUT 120
                     FAIL_REGULAR_EXPRESSION "FAIL:")
add_test(
  NAME driver_repeat_exit
  COMMAND ${CMAKE_COMMAND}
    -DDRIVER=$<TARGET_FILE:cabledyn>
    -DDECK=${CMAKE_CURRENT_SOURCE_DIR}/tests/data/three_line_composite_tmax0.dat
    -DOUTPUT_ROOT=${CMAKE_CURRENT_BINARY_DIR}/driver_repeat_exit
    -DRUNS=200
    -P ${CMAKE_CURRENT_SOURCE_DIR}/tests/check_driver_repeat_exit.cmake)
set_tests_properties(driver_repeat_exit PROPERTIES
  LABELS "fortran;driver;integration;static")

# Run-time profile module: phase partition, a failed run's time kept in its phase, and exact
# line-step counts under OpenMP.
add_executable(test_profile tests/test_profile.f90)
target_link_libraries(test_profile PRIVATE cabledyn_core)
add_test(NAME profile COMMAND test_profile)
set_tests_properties(profile PROPERTIES LABELS "fortran;unit;driver"
                     ENVIRONMENT "OMP_NUM_THREADS=4")

# Run-time profile (CABLEDYN_PROFILE): printed only when requested, before the success line,
# with its phase rows and counts, and without changing any output file. One EI = 0 deck with
# waves (fluid, steps and line counts) and one finite-EI deck on the cubic-Hermite route.
add_test(
  NAME driver_profile_ei0
  COMMAND ${CMAKE_COMMAND}
    -DDRIVER=$<TARGET_FILE:cabledyn>
    -DDECK=${CMAKE_CURRENT_SOURCE_DIR}/examples/dynamic_chain_waves.dat
    -DOUTPUT_ROOT=${CMAKE_CURRENT_BINARY_DIR}/driver_profile_ei0
    "-DEXPECT=\n    EI = 0 line steps: [1-9][0-9]* \\(substeps and retries included\\), Newton iterations: [1-9][^\n]*\n    EI = 0 line step kernels: residual [0-9]+ \\([0-9.]+ s\\), residual and tangent [1-9][0-9]* \\([0-9.]+ s\\), factorisation [1-9][0-9]* \\([0-9.]+ s\\), back-substitution [1-9][0-9]* \\([0-9.]+ s\\)\\."
    -P ${CMAKE_CURRENT_SOURCE_DIR}/tests/check_driver_profile.cmake)
add_test(
  NAME driver_profile_finite_ei
  COMMAND ${CMAKE_COMMAND}
    -DDRIVER=$<TARGET_FILE:cabledyn>
    -DDECK=${CMAKE_CURRENT_SOURCE_DIR}/tests/data/held_start_gomex80_power_cable.dat
    -DOUTPUT_ROOT=${CMAKE_CURRENT_BINARY_DIR}/driver_profile_finite_ei
    "-DEXPECT=\n    Finite-EI cable steps: [1-9][0-9]*, residual evaluations: [1-9][0-9]*, tangent assemblies: [1-9][0-9]*, factorisations: [1-9][0-9]*, linear solves: [1-9][0-9]*, force-blend corrections: [0-9]+[^\n]*\n    Finite-EI cable step time \\(s\\): residual [0-9.]+, tangent [0-9.]+, effective matrix [0-9.]+, factorisation [0-9.]+, back-substitution [0-9.]+, added mass [0-9.]+, other [0-9.]+\\.\n    Finite-EI cable assembly time \\(s\\): band zeroing [0-9.]+, tangent element kernels [0-9.]+, tangent scatter [0-9.]+, structural residual [0-9.]+, weight [0-9.]+, attachments [0-9.]+, dry buoyancy [0-9.]+, seabed contact [0-9.]+, axial damping [0-9.]+, drag [0-9.]+, end connections [0-9.]+, wave Froude-Krylov [0-9.]+, held Froude-Krylov [0-9.]+, torsion [0-9.]+\\."
    -P ${CMAKE_CURRENT_SOURCE_DIR}/tests/check_driver_profile.cmake)
add_test(
  NAME driver_profile_failure
  COMMAND ${CMAKE_COMMAND}
    -DDRIVER=$<TARGET_FILE:cabledyn>
    -DDECK=${CMAKE_CURRENT_SOURCE_DIR}/tests/data/nonconvergent_motion.dat
    -DOUTPUT_ROOT=${CMAKE_CURRENT_BINARY_DIR}/driver_profile_failure
    -P ${CMAKE_CURRENT_SOURCE_DIR}/tests/check_driver_profile_failure.cmake)
set_tests_properties(driver_profile_ei0 driver_profile_finite_ei driver_profile_failure PROPERTIES
  LABELS "fortran;driver;integration;dynamic")

# Command-line contract: unknown options, an output root whose .out would overwrite
# the deck, and an unwritable output directory all fail before any solve.
configure_file(${CMAKE_CURRENT_SOURCE_DIR}/tests/data/nonconvergent_motion.dat
               ${CMAKE_CURRENT_BINARY_DIR}/driver_cli_self.out COPYONLY)
# Each case checks the exit code (1) and the diagnostic together.
add_test(NAME driver_cli_unknown_option
  COMMAND ${CMAKE_COMMAND} -DDRIVER=$<TARGET_FILE:cabledyn> -DEXPECT_RC=1
    "-DARGS=--no-such-option|${CMAKE_CURRENT_SOURCE_DIR}/tests/data/nonconvergent_motion.dat|cli_out"
    "-DMUST_MATCH=unknown option \"--no-such-option\""
    -DWORKDIR=${CMAKE_CURRENT_BINARY_DIR}/driver_cli_unknown_option
    -P ${CMAKE_CURRENT_SOURCE_DIR}/tests/check_driver_output.cmake)
add_test(NAME driver_cli_deck_overwrite
  COMMAND ${CMAKE_COMMAND} -DDRIVER=$<TARGET_FILE:cabledyn> -DEXPECT_RC=1
    "-DARGS=${CMAKE_CURRENT_BINARY_DIR}/driver_cli_self.out|${CMAKE_CURRENT_BINARY_DIR}/driver_cli_self"
    "-DMUST_MATCH=would overwrite the input deck"
    -P ${CMAKE_CURRENT_SOURCE_DIR}/tests/check_driver_output.cmake)
add_test(NAME driver_cli_missing_output_dir
  COMMAND ${CMAKE_COMMAND} -DDRIVER=$<TARGET_FILE:cabledyn> -DEXPECT_RC=1
    "-DARGS=${CMAKE_CURRENT_SOURCE_DIR}/tests/data/nonconvergent_motion.dat|${CMAKE_CURRENT_BINARY_DIR}/driver_cli_no_such_dir/run"
    "-DMUST_MATCH=cannot write output files"
    -P ${CMAKE_CURRENT_SOURCE_DIR}/tests/check_driver_output.cmake)
set_tests_properties(driver_cli_unknown_option driver_cli_deck_overwrite driver_cli_missing_output_dir
  PROPERTIES LABELS "fortran;driver;cli")
# The mixed EI=0/finite-EI standalone route writes no modal files: OPTION nModes fails closed.
add_test(NAME driver_cli_mixed_nmodes
  COMMAND ${CMAKE_COMMAND} -DDRIVER=$<TARGET_FILE:cabledyn> -DEXPECT_RC=1
    "-DARGS=${CMAKE_CURRENT_SOURCE_DIR}/tests/data/mixed_nmodes.dat|${CMAKE_CURRENT_BINARY_DIR}/driver_cli_mixed_nmodes"
    "-DMUST_MATCH=nModes is not supported for mixed EI=0/finite-EI decks"
    -P ${CMAKE_CURRENT_SOURCE_DIR}/tests/check_driver_output.cmake)
set_tests_properties(driver_cli_mixed_nmodes PROPERTIES LABELS "fortran;driver;cli")
# A lazy wave restrained in torsion and twisted two turns writes its modes with the twist.
add_test(NAME driver_cli_torsion_nmodes
  COMMAND ${CMAKE_COMMAND} -DDRIVER=$<TARGET_FILE:cabledyn> -DEXPECT_RC=0
    "-DARGS=${CMAKE_CURRENT_SOURCE_DIR}/tests/data/torsion_lazy_wave_modes.dat|${CMAKE_CURRENT_BINARY_DIR}/driver_cli_torsion_nmodes"
    "-DMUST_MATCH=torsion solved, total twist Twist1 =;imposed Pretwist.B. - Pretwist.A. = +7.20000E\\+02 deg;converged run written"
    -P ${CMAKE_CURRENT_SOURCE_DIR}/tests/check_driver_output.cmake)
set_tests_properties(driver_cli_torsion_nmodes PROPERTIES LABELS "fortran;driver;cli")
# Non-ASCII, reserved-device, input-clobbering, and concurrently used output paths.
add_test(
  NAME driver_cli_paths
  COMMAND ${CMAKE_COMMAND}
    -DDRIVER=$<TARGET_FILE:cabledyn>
    -DSTATIC_DECK=${CMAKE_CURRENT_SOURCE_DIR}/examples/chain_catenary_r3_100m.dat
    -DDYNAMIC_DECK=${CMAKE_CURRENT_SOURCE_DIR}/examples/dynamic_chain_held.dat
    -DUTF8_MANIFEST=${CABLEDYN_DRIVER_UTF8_MANIFEST}
    -DWORK=${CMAKE_CURRENT_BINARY_DIR}/driver_cli_paths
    -P ${CMAKE_CURRENT_SOURCE_DIR}/tests/check_driver_paths.cmake)
set_tests_properties(driver_cli_paths PROPERTIES LABELS "fortran;driver;cli")

# Advisories that do not stop a run: the start-up shock note of a prescribed motion that
# starts moving, and the no-seabed warning of an OpenFAST MooringFile run standalone.
add_test(NAME driver_advisories
  COMMAND ${CMAKE_COMMAND}
    -DDRIVER=$<TARGET_FILE:cabledyn>
    -DWORK=${CMAKE_CURRENT_BINARY_DIR}/driver_advisories
    -DNO_SEABED_DECK=${CMAKE_CURRENT_SOURCE_DIR}/examples/iea15mw_umaine_openfast_cabledyn.dat
    -DSEABED_DECK=${CMAKE_CURRENT_SOURCE_DIR}/examples/chain_catenary_shallow_30m.dat
    -P ${CMAKE_CURRENT_SOURCE_DIR}/tests/check_driver_advisories.cmake)
set_tests_properties(driver_advisories PROPERTIES LABELS "fortran;driver;integration")
# The fold note of an EI = 0 line, once per folded line and never on a usual layout: a current
# that pushes the grounded run 20 m past its anchor (TMax = 0, the line-model route), a seabed
# sloping down past the anchor (static run over a bathymetry), each with the remedy that fits
# the deck's friction, and no note on a grounded chain that does not fold, on the same current
# deck with frictionMu, on the same slope with as-laid friction, on a run the deck itself lays
# past its anchor (staticsFriction asLaid along layAzimuth), or on two lines through a clump
# resting on the seabed.
add_test(NAME driver_ei0_fold_note_current
  COMMAND ${CMAKE_COMMAND} -DDRIVER=$<TARGET_FILE:cabledyn> -DEXPECT_RC=0
    "-DARGS=${CMAKE_CURRENT_SOURCE_DIR}/tests/data/ei0_hairpin_current.dat|hairpin"
    "-DONCE=Note: line 1: the static layout carries the grounded run 20\\.[0-9]+ m past its anchor, where it folds back;the current drives the run along the seabed, which holds it only by friction"
    "-DMUST_MATCH=seabed friction \\(frictionMu\\) or a shorter line prevents it"
    -DWORKDIR=${CMAKE_CURRENT_BINARY_DIR}/driver_ei0_fold_note_current
    -P ${CMAKE_CURRENT_SOURCE_DIR}/tests/check_driver_output.cmake)
set_tests_properties(driver_ei0_fold_note_current PROPERTIES LABELS "fortran;driver;integration;static")
add_test(NAME driver_ei0_fold_note_slope
  COMMAND ${CMAKE_COMMAND} -DDRIVER=$<TARGET_FILE:cabledyn> -DEXPECT_RC=0
    "-DARGS=${CMAKE_CURRENT_SOURCE_DIR}/tests/data/ei0_fold_slope.dat|slope"
    "-DONCE=Note: line 1: the static layout carries the grounded run 2[0-9]\\.[0-9]+ m past its anchor, where it folds back;the seabed slope drives the run downhill"
    "-DMUST_MATCH=frictionMu with staticsFriction asLaid, which need dtM and TMax: the static-only solve carries no seabed friction\\) or a shorter line prevents it"
    -DWORKDIR=${CMAKE_CURRENT_BINARY_DIR}/driver_ei0_fold_note_slope
    -P ${CMAKE_CURRENT_SOURCE_DIR}/tests/check_driver_output.cmake)
set_tests_properties(driver_ei0_fold_note_slope PROPERTIES LABELS "fortran;driver;integration;static")
# ... and a fold of the grounded run onto itself between two grounded ends, named at its deck
# node (driver_ei0_fold_layouts checks that it is the node of the fold).
add_test(NAME driver_ei0_fold_note_turn
  COMMAND ${CMAKE_COMMAND} -DDRIVER=$<TARGET_FILE:cabledyn> -DEXPECT_RC=0
    "-DARGS=${CMAKE_CURRENT_SOURCE_DIR}/tests/data/ei0_fold_turn_current.dat|turn"
    "-DONCE=Note: line 1: the static layout folds the grounded run back on itself \\(a 180 deg turn at node 49, a hairpin\\);the current drives the run along the seabed, which holds it only by friction"
    "-DMUST_MATCH=seabed friction \\(frictionMu\\) or a shorter line prevents it"
    "-DMUST_NOT=past its anchor"
    -DWORKDIR=${CMAKE_CURRENT_BINARY_DIR}/driver_ei0_fold_note_turn
    -P ${CMAKE_CURRENT_SOURCE_DIR}/tests/check_driver_output.cmake)
set_tests_properties(driver_ei0_fold_note_turn PROPERTIES LABELS "fortran;driver;integration;static")
foreach(_deck IN ITEMS examples/chain_catenary_shallow_30m tests/data/ei0_hairpin_current_friction
                       tests/data/ei0_fold_slope_aslaid tests/data/ei0_aslaid_behind_anchor
                       tests/data/ei0_clump_no_fold)
  get_filename_component(_name "${_deck}" NAME)
  if(_name STREQUAL "chain_catenary_shallow_30m")
    set(_test driver_ei0_no_fold_note)
  else()
    set(_test driver_ei0_no_fold_note_${_name})
  endif()
  add_test(NAME ${_test}
    COMMAND ${CMAKE_COMMAND} -DDRIVER=$<TARGET_FILE:cabledyn> -DEXPECT_RC=0
      "-DARGS=${CMAKE_CURRENT_SOURCE_DIR}/${_deck}.dat|${_name}"
      "-DONCE=converged run written"
      "-DMUST_NOT=folds back|a hairpin"
      -DWORKDIR=${CMAKE_CURRENT_BINARY_DIR}/${_test}
      -P ${CMAKE_CURRENT_SOURCE_DIR}/tests/check_driver_output.cmake)
  set_tests_properties(${_test} PROPERTIES LABELS "fortran;driver;integration;static")
endforeach()
# The finite-EI twin of the current note: the same cause and remedy (fold_cause_remedy).
add_test(NAME driver_fei_fold_note_current
  COMMAND ${CMAKE_COMMAND} -DDRIVER=$<TARGET_FILE:cabledyn> -DEXPECT_RC=0
    "-DARGS=${CMAKE_CURRENT_SOURCE_DIR}/tests/data/fei_hairpin_current.dat|fei_hairpin"
    "-DONCE=Note: line 1: the static layout carries the grounded run [0-9.]+ m past its anchor, where it folds back;the current drives the run along the seabed, which holds it only by friction"
    "-DMUST_MATCH=seabed friction \\(frictionMu\\) or a shorter line prevents it"
    -DWORKDIR=${CMAKE_CURRENT_BINARY_DIR}/driver_fei_fold_note_current
    -P ${CMAKE_CURRENT_SOURCE_DIR}/tests/check_driver_output.cmake)
set_tests_properties(driver_fei_fold_note_current PROPERTIES LABELS "fortran;driver;integration;static")
# ... and the layouts behind those notes: the frictionless current carries the run past its
# anchor, frictionMu holds it short of the note threshold, and the as-laid run the note skips
# does lie past the anchor (so the no-note tests cannot pass on a layout that never got there).
if(Python3_Interpreter_FOUND)
  add_test(NAME driver_ei0_fold_layouts
           COMMAND ${Python3_EXECUTABLE} ${CMAKE_CURRENT_SOURCE_DIR}/tests/check_fold_layout.py
                   $<TARGET_FILE:cabledyn> ${CMAKE_CURRENT_SOURCE_DIR}/tests/data)
  set_tests_properties(driver_ei0_fold_layouts PROPERTIES
    LABELS "python;driver;integration;static"
    ENVIRONMENT "${_cabledyn_python_test_environment}")
  # Node tension through touchdown on a coarse mesh (10 m grounded elements) follows a four
  # times finer reference within 3.5 %: the touchdown element, grounded at one end only, takes
  # the floor reaction of its grounded stretch alone, not half an element's.
  add_test(NAME driver_touchdown_recovery
           COMMAND ${Python3_EXECUTABLE} ${CMAKE_CURRENT_SOURCE_DIR}/tests/check_touchdown_recovery.py
                   $<TARGET_FILE:cabledyn>)
  set_tests_properties(driver_touchdown_recovery PROPERTIES
    LABELS "python;driver;integration;static"
    ENVIRONMENT "${_cabledyn_python_test_environment}")
  # Node tension at touchdown converges at second order wherever the touchdown point falls in
  # its element: the local error over a sweep of meshes at 1.6, 0.8 and 0.4 m elements falls
  # by at least 2.5 from 0.8 to 0.4 m and stays below 0.35 N there (the touchdown element takes
  # the floor reaction of its grounded stretch).
  add_test(NAME driver_touchdown_convergence
           COMMAND ${Python3_EXECUTABLE} ${CMAKE_CURRENT_SOURCE_DIR}/tests/check_touchdown_convergence.py
                   $<TARGET_FILE:cabledyn>)
  set_tests_properties(driver_touchdown_convergence PROPERTIES
    LABELS "python;driver;integration;static"
    TIMEOUT 600
    ENVIRONMENT "${_cabledyn_python_test_environment}")
  # A hang-off through a tapered bend stiffener follows the planar elastica (scipy solve_bvp)
  # within 2 % of the root moment and 1 cm, and node by node on a sweep of element sizes within
  # 0.5 % of the local curvature on 0.1 m elements; skipped where scipy is not installed.
  add_test(NAME driver_bend_stiffener
           COMMAND ${Python3_EXECUTABLE} ${CMAKE_CURRENT_SOURCE_DIR}/tests/check_bend_stiffener.py
                   $<TARGET_FILE:cabledyn>)
  set_tests_properties(driver_bend_stiffener PROPERTIES
    LABELS "python;driver;integration;static;validation"
    SKIP_RETURN_CODE 77
    ENVIRONMENT "${_cabledyn_python_test_environment}")
  # The curvature of a stretched cable is the geometric one and the bend moment the section's:
  # both follow the elastica of the element energy at strains up to 1.2 %.
  add_test(NAME driver_curvature_stretch
           COMMAND ${Python3_EXECUTABLE} ${CMAKE_CURRENT_SOURCE_DIR}/tests/check_curvature_stretch.py
                   $<TARGET_FILE:cabledyn>)
  set_tests_properties(driver_curvature_stretch PROPERTIES
    LABELS "python;driver;integration;static;validation"
    SKIP_RETURN_CODE 77
    ENVIRONMENT "${_cabledyn_python_test_environment}")
  # The end tangent outputs of a clamped finite-EI line (channels, static profile, range graph,
  # initialisation reports on the finite-EI and mixed routes) are the clamp's angles.
  add_test(NAME driver_end_tangent_channels
           COMMAND ${Python3_EXECUTABLE} ${CMAKE_CURRENT_SOURCE_DIR}/tests/check_end_tangent_channels.py
                   $<TARGET_FILE:cabledyn>)
  set_tests_properties(driver_end_tangent_channels PROPERTIES
    LABELS "python;driver;integration;static;outputs"
    TIMEOUT 600
    ENVIRONMENT "${_cabledyn_python_test_environment}")
  # A negative BA damps the first axial mode of a line at zeta pi/(2N) per segment (the
  # default), and at zeta on every mesh under axialDampingRatio mode1, uniform and composite.
  add_test(NAME driver_axial_damping_ratio
           COMMAND ${Python3_EXECUTABLE} ${CMAKE_CURRENT_SOURCE_DIR}/tests/check_axial_damping_ratio.py
                   $<TARGET_FILE:cabledyn>)
  set_tests_properties(driver_axial_damping_ratio PROPERTIES
    LABELS "python;driver;integration;dynamic;validation"
    TIMEOUT 600
    ENVIRONMENT "${_cabledyn_python_test_environment}")
endif()
# The scan of the round-off CI job: it must flag a fallback note, a failed run and a forced
# BLAS kernel that did not take effect, or a clean scan would prove nothing.
if(Python3_Interpreter_FOUND)
  add_test(NAME example_fallback_scan
           COMMAND ${Python3_EXECUTABLE} ${CMAKE_CURRENT_SOURCE_DIR}/tests/test_check_example_fallbacks.py
                   $<TARGET_FILE:cabledyn> ${CMAKE_CURRENT_SOURCE_DIR}/examples)
  set_tests_properties(example_fallback_scan PROPERTIES
    LABELS "python;driver;integration"
    TIMEOUT 120
    ENVIRONMENT "${_cabledyn_python_test_environment}")
endif()
# A clamped finite-EI cable with a buoyant section on a Rigid6 body: the body static solve
# holds the objects at their deck poses, warns once, and reports no balanced clamped end loads.
# A lazy wave on a graded mesh in a cross current: the continuation route stops on a compression
# read on elements longer than half the bending length, which is no grounded-run limit, so the
# mesh-sequenced route still runs and solves the deck, with no fallback.
add_test(NAME driver_graded_cross_current
  COMMAND ${CMAKE_COMMAND} -DDRIVER=$<TARGET_FILE:cabledyn> -DEXPECT_RC=0
    "-DARGS=${CMAKE_CURRENT_SOURCE_DIR}/tests/data/lazy_wave_graded_cross_current.dat|graded"
    "-DMUST_NOT=failed Newton;stalled;looser tolerance"
    -DWORKDIR=${CMAKE_CURRENT_BINARY_DIR}/driver_graded_cross_current
    -P ${CMAKE_CURRENT_SOURCE_DIR}/tests/check_driver_output.cmake)
set_tests_properties(driver_graded_cross_current PROPERTIES LABELS "fortran;driver;integration;static" TIMEOUT 600)
add_test(NAME driver_clamped_buoyant_held
  COMMAND ${CMAKE_COMMAND} -DDRIVER=$<TARGET_FILE:cabledyn> -DEXPECT_RC=0
    "-DARGS=${CMAKE_CURRENT_SOURCE_DIR}/tests/data/clamped_buoyant_cable_held.dat|held"
    "-DONCE=held at their deck poses"
    "-DMUST_NOT=balanced in"
    -DWORKDIR=${CMAKE_CURRENT_BINARY_DIR}/driver_clamped_buoyant_held
    -P ${CMAKE_CURRENT_SOURCE_DIR}/tests/check_driver_output.cmake)
set_tests_properties(driver_clamped_buoyant_held PROPERTIES LABELS "fortran;driver;integration;static")
# A clamped finite-EI cable on a Rigid6 body that also holds a pinned rod: the body's junction
# group has nine coordinates, which the cable's kept Jacobian columns must span (the Debug
# build's bounds checks catch a cache sized for six).
add_test(NAME driver_clamped_cable_pinned_rod
  COMMAND ${CMAKE_COMMAND} -DDRIVER=$<TARGET_FILE:cabledyn> -DEXPECT_RC=0
    "-DARGS=${CMAKE_CURRENT_SOURCE_DIR}/tests/data/buoy_clamped_cable_pinned_rod.dat|pinned"
    "-DONCE=converged run written"
    -DWORKDIR=${CMAKE_CURRENT_BINARY_DIR}/driver_clamped_cable_pinned_rod
    -P ${CMAKE_CURRENT_SOURCE_DIR}/tests/check_driver_output.cmake)
set_tests_properties(driver_clamped_cable_pinned_rod PROPERTIES LABELS "fortran;driver;integration")
# A lazy-wave cable restrained in torsion (3D static solve) whose deck mesh is too coarse at
# touchdown: the deck-mesh equilibrium reads as unstable, the refined one is stable and used.
add_test(NAME driver_lazy_wave_torsion_coarse_refined
  COMMAND ${CMAKE_COMMAND} -DDRIVER=$<TARGET_FILE:cabledyn> -DEXPECT_RC=0
    "-DARGS=${CMAKE_CURRENT_SOURCE_DIR}/tests/data/lazy_wave_touchdown_torsion_coarse.dat|coarse"
    "-DONCE=failed the stability test with elements longer than half the bending length"
    "-DMUST_MATCH=stable on the refined mesh of 348 elements;torsion solved"
    -DWORKDIR=${CMAKE_CURRENT_BINARY_DIR}/driver_lazy_wave_torsion_coarse_refined
    -P ${CMAKE_CURRENT_SOURCE_DIR}/tests/check_driver_output.cmake)
set_tests_properties(driver_lazy_wave_torsion_coarse_refined PROPERTIES
  LABELS "fortran;driver;integration;static;torsion")
# The same deck with the mesh-sequenced route first: its state is prolongated to the refined mesh.
add_test(NAME driver_lazy_wave_torsion_coarse_sequenced
  COMMAND ${CMAKE_COMMAND} -DDRIVER=$<TARGET_FILE:cabledyn> -DEXPECT_RC=0
    "-DARGS=${CMAKE_CURRENT_SOURCE_DIR}/tests/data/lazy_wave_touchdown_torsion_coarse_sequenced.dat|coarse"
    "-DONCE=failed the stability test with elements longer than half the bending length"
    "-DMUST_MATCH=stable on the refined mesh of 348 elements;torsion solved"
    -DWORKDIR=${CMAKE_CURRENT_BINARY_DIR}/driver_lazy_wave_torsion_coarse_sequenced
    -P ${CMAKE_CURRENT_SOURCE_DIR}/tests/check_driver_output.cmake)
set_tests_properties(driver_lazy_wave_torsion_coarse_sequenced PROPERTIES
  LABELS "fortran;driver;integration;static;torsion")
# The same cable free in torsion (planar static): the coarse planar state is unstable out of its
# plane and the hand-off names it once; on a mesh that resolves the bending length it does not.
add_test(NAME driver_lazy_wave_planar_coarse_note
  COMMAND ${CMAKE_COMMAND} -DDRIVER=$<TARGET_FILE:cabledyn> -DEXPECT_RC=0
    "-DARGS=${CMAKE_CURRENT_SOURCE_DIR}/tests/data/lazy_wave_touchdown_planar_coarse.dat|coarse"
    "-DONCE=starts the dynamics from a static state solved in its vertical plane that is unstable"
    "-DMUST_MATCH=mesh of 87 elements, the coarsest 10.00 m long;4x meets that length"
    -DWORKDIR=${CMAKE_CURRENT_BINARY_DIR}/driver_lazy_wave_planar_coarse_note
    -P ${CMAKE_CURRENT_SOURCE_DIR}/tests/check_driver_output.cmake)
set_tests_properties(driver_lazy_wave_planar_coarse_note PROPERTIES
  LABELS "fortran;driver;integration;static")
add_test(NAME driver_lazy_wave_planar_refined_quiet
  COMMAND ${CMAKE_COMMAND} -DDRIVER=$<TARGET_FILE:cabledyn> -DEXPECT_RC=0
    "-DARGS=${CMAKE_CURRENT_SOURCE_DIR}/tests/data/lazy_wave_touchdown_planar_refined.dat|refined"
    "-DMUST_NOT=unstable out of"
    -DWORKDIR=${CMAKE_CURRENT_BINARY_DIR}/driver_lazy_wave_planar_refined_quiet
    -P ${CMAKE_CURRENT_SOURCE_DIR}/tests/check_driver_output.cmake)
set_tests_properties(driver_lazy_wave_planar_refined_quiet PROPERTIES
  LABELS "fortran;driver;integration;static")
# A Fixed anchor in a crease of a bathymetry grid: at the tabulated depth it rests on the seabed
# and is placed on the rounded surface; 1 cm below the rounded surface, between it and the grid
# surface but within the seabed tolerance of neither, it is rejected.
add_test(NAME driver_anchor_crease_tabulated
  COMMAND ${CMAKE_COMMAND} -DDRIVER=$<TARGET_FILE:cabledyn> -DEXPECT_RC=0
    "-DARGS=${CMAKE_CURRENT_SOURCE_DIR}/tests/data/anchor_crease_tabulated.dat|tabulated"
    "-DMUST_NOT=lies below the seabed"
    -DWORKDIR=${CMAKE_CURRENT_BINARY_DIR}/driver_anchor_crease_tabulated
    -P ${CMAKE_CURRENT_SOURCE_DIR}/tests/check_driver_output.cmake)
set_tests_properties(driver_anchor_crease_tabulated PROPERTIES LABELS "fortran;driver;static;seabed")
add_test(NAME driver_anchor_crease_between
  COMMAND ${CMAKE_COMMAND} -DDRIVER=$<TARGET_FILE:cabledyn> -DEXPECT_RC=1
    "-DARGS=${CMAKE_CURRENT_SOURCE_DIR}/tests/data/anchor_crease_between.dat|between"
    "-DMUST_MATCH=POINT 2 .Fixed. lies below the seabed"
    -DWORKDIR=${CMAKE_CURRENT_BINARY_DIR}/driver_anchor_crease_between
    -P ${CMAKE_CURRENT_SOURCE_DIR}/tests/check_driver_output.cmake)
set_tests_properties(driver_anchor_crease_between PROPERTIES LABELS "fortran;driver;static;seabed")
# The same pair with the buoyant stretch built from discrete ATTACHMENTS: the hand-off check runs
# on the discrete equilibrium the attachment polish gives.
add_test(NAME driver_lazy_wave_planar_coarse_att_note
  COMMAND ${CMAKE_COMMAND} -DDRIVER=$<TARGET_FILE:cabledyn> -DEXPECT_RC=0
    "-DARGS=${CMAKE_CURRENT_SOURCE_DIR}/tests/data/lazy_wave_touchdown_planar_coarse_att.dat|coarse_att"
    "-DONCE=starts the dynamics from a static state solved in its vertical plane that is unstable"
    "-DMUST_MATCH=mesh of 87 elements, the coarsest 10.00 m long;4x meets that length;25 attachment.s. lumped"
    -DWORKDIR=${CMAKE_CURRENT_BINARY_DIR}/driver_lazy_wave_planar_coarse_att_note
    -P ${CMAKE_CURRENT_SOURCE_DIR}/tests/check_driver_output.cmake)
set_tests_properties(driver_lazy_wave_planar_coarse_att_note PROPERTIES
  LABELS "fortran;driver;integration;static")
add_test(NAME driver_lazy_wave_planar_refined_att_quiet
  COMMAND ${CMAKE_COMMAND} -DDRIVER=$<TARGET_FILE:cabledyn> -DEXPECT_RC=0
    "-DARGS=${CMAKE_CURRENT_SOURCE_DIR}/tests/data/lazy_wave_touchdown_planar_refined_att.dat|refined_att"
    "-DMUST_NOT=unstable out of"
    -DWORKDIR=${CMAKE_CURRENT_BINARY_DIR}/driver_lazy_wave_planar_refined_att_quiet
    -P ${CMAKE_CURRENT_SOURCE_DIR}/tests/check_driver_output.cmake)
set_tests_properties(driver_lazy_wave_planar_refined_att_quiet PROPERTIES
  LABELS "fortran;driver;integration;static")

# Diagnostics that name the cause and the remedy. Each deck below was rejected by a message that
# named the wrong cause or none, or ran with no warning, before the message was written.
function(cabledyn_msg_test name deck rc must_match must_not)
  add_test(NAME driver_msg_${name}
    COMMAND ${CMAKE_COMMAND} -DDRIVER=$<TARGET_FILE:cabledyn> -DEXPECT_RC=${rc}
      "-DARGS=${CMAKE_CURRENT_SOURCE_DIR}/tests/data/${deck}|msg"
      "-DMUST_MATCH=${must_match}" "-DMUST_NOT=${must_not}"
      -DWORKDIR=${CMAKE_CURRENT_BINARY_DIR}/driver_msg_${name}
      -P ${CMAKE_CURRENT_SOURCE_DIR}/tests/check_driver_output.cmake)
  set_tests_properties(driver_msg_${name} PROPERTIES LABELS "fortran;driver;integration;static")
endfunction()
# A neutrally buoyant finite-EI line longer than its span has no catenary: it bows under the
# compression its bending stiffness carries, and the run says that nothing chose the bow's side.
cabledyn_msg_test(weightless_finite_ei msg_weightless_finite_ei.dat 0
  "line 1 is weightless and longer than its span, so it bows;solved bowed downward in the vertical plane"
  "net-heavy")
# With its ends one above the other nothing chooses the side of the bow either: refused, by name.
cabledyn_msg_test(weightless_finite_ei_vertical msg_weightless_finite_ei_vertical.dat 2
  "weightless .neutrally buoyant. line is longer than its vertical span;nothing chooses the side of the bow;offset its ends horizontally"
  "net-heavy")
# MoorDyn's line flag v (node velocities) is not written; V (the VIV lift) is upper case.
cabledyn_msg_test(line_flag_velocity msg_line_flag_velocity.dat 1
  "supported line-output flags are p, t, r and V .the VIV lift, upper case as MoorDyn's."
  "net-heavy")
# An EI=0 line type rejected as net-buoyant whose mass is a relative 4e-9 below the displaced water
# mass is named weightless and slack; one a relative 2e-6 below it keeps the plain message.
cabledyn_msg_test(weightless_ei0 msg_weightless_ei0.dat 1
  "is neutrally buoyant .its dry mass equals the displaced water mass to within a relative 1e-6.;weightless and slack: its static shape is indeterminate"
  "")
cabledyn_msg_test(net_buoyant_ei0 msg_net_buoyant_ei0.dat 1
  "is net-buoyant .dry mass <= displaced water mass.: buoyant / lazy-wave sections require a dynamic finite-EI deck"
  "weightless")
# A line half the length of its span converges at 100 % strain; the static solve says so.
cabledyn_msg_test(static_strain msg_static_strain.dat 0
  "Note: LINE 1 is stretched to a static strain of 100.0 % at the fairlead;above 10.0 % .the note level used without maxStrain." "")
# A 100 m one-segment top section of a 520 m line.
cabledyn_msg_test(coarse_section msg_coarse_section.dat 0
  "WARNING: LINE 1 section of type \"chain\" .100.00 m in 1 segment.s.. has segments of 100.00 m, 19.2 %" "")
# A well-meshed line with a modest stretch raises neither.
cabledyn_msg_test(quiet_catenary ../../examples/chain_catenary_r3_100m.dat 0 ""
  "static strain;too coarse to follow")
cabledyn_msg_test(shared_line msg_shared_line.dat 1
  "LINE 1 End B .NodeB, POINT 2, coupled. must be a Fixed .anchor. point;Workaround for this EI=0 line: split it into two lines that meet at a Connect point"
  "cannot be split")
# A finite-EI line between two Coupled points has both ends driven: neither the End B refusal nor
# the Connect-point split advice is given; as a static deck it asks for dtM and TMax.
cabledyn_msg_test(shared_line_finite_ei msg_shared_line_finite_ei.dat 1
  "finite-EI section .EI>0. requires a dynamic deck with dtM and TMax"
  "Workaround;must be a Fixed")
cabledyn_msg_test(pliant_connect_end_b msg_pliant_connect_end_b.dat 1
  "finite-EI LINE 1 in a mixed-topology deck: End B is POINT 2 .connect.;is not supported on the multibody march;End the cable on a Fixed point"
  "")
# The standalone mixed route takes a deck current (here the static start of the lazy-wave deck)
# and refuses deck waves by name.
cabledyn_msg_test(mixed_current msg_mixed_current.dat 0
  "CableDyn mixed standalone aggregate: 3 line.s. .2 EI=0, 1 finite-EI."
  "STILL WATER")
cabledyn_msg_test(mixed_waves msg_mixed_waves.dat 1
  "the deck waves OPTION is not supported for a standalone mixed EI=0/finite-EI deck;takes the deck current but evaluates no deck waves;couple the deck to OpenFAST .CompMooring = 5. with SeaState"
  "this coupled mode;the C API;FAST.Farm")
cabledyn_msg_test(mixed_connect_coupled_cable msg_mixed_connect_coupled_cable.dat 1
  "finite-EI LINE 3: a Coupled/Vessel End A .POINT 1. would need motionFile coupling to drive it;remove the Connect/Free points;held still .that route takes no motionFile either."
  "is driven by a motionFile")
# A Pinned rod that its line turns at the static start: the completion line reports the move of its
# End B and its turn, not the zero translation of its pin.
cabledyn_msg_test(pinned_rod_turn msg_pinned_rod_turn.dat 0
  "body/rod static equilibrium .1 object.s., largest move [1-9].[0-9]+E[-+][0-9]+ m, largest turn [1-9]"
  "largest move 0.000E\\+00")
# The standalone mixed route warns about a coarse section and notes a static strain above maxStrain.
cabledyn_msg_test(mixed_coarse_strain msg_mixed_coarse_strain.dat 0
  "WARNING: LINE 1 section of type \"chain\" .150.00 m in 1 segment.s.. has segments of 150.00 m, 17.6 %;Note: LINE 1 is stretched to a static strain of;above 1.00E-02 % .OPTION maxStrain."
  "LINE 2 section of type")
# The tensile qualification failure of a dynamic step names the remedy to the end (the message was
# cut at 256 characters: "... at element 64, xi= 0.5000; increase").
cabledyn_msg_test(tensile_safety_whole msg_tensile_safety_truncated.dat 2
  "tensile qualification failed;at element 64, xi= 0.5000; increase tensile_strain_tolerance only with an engineering basis, or use warn mode" "")
cabledyn_msg_test(anchor_below_seabed msg_anchor_below_seabed.dat 1
  "POINT 2 .Fixed. lies below the seabed;by 1.00E-02 m, more than the 1.00E-03 m seabed tolerance;Set the anchor Z to -100.00000 m" "")
if(WIN32 AND CABLEDYN_RUNTIME_DLLS)
  add_test(
    NAME windows_install_runtime
    COMMAND ${CMAKE_COMMAND}
      -DBUILD_DIR=${CMAKE_BINARY_DIR}
      -DINSTALL_PREFIX=${CMAKE_BINARY_DIR}/install-smoke
      -DEXE_NAME=$<TARGET_FILE_NAME:cabledyn>
      -DDECK=${CMAKE_CURRENT_SOURCE_DIR}/examples/chain_catenary_r3_100m.dat
      -P ${CMAKE_CURRENT_SOURCE_DIR}/tests/check_windows_install_runtime.cmake)
  set_tests_properties(windows_install_runtime PROPERTIES
    LABELS "fortran;driver;integration;installation;windows")
endif()

# Maintained reference standalone decks are executable specifications. These
# smoke gates catch parser drift, missing auxiliary motion files, and loss of
# the intended lazy-wave equilibrium branch.
foreach(_lozon_case IN ITEMS
    lozon_gomex80_power_cable
    lozon_gomaine200_power_cable
    lozon_humboldt800_power_cable
    lozon_gomex80_mooring
    lozon_gomaine200_mooring
    lozon_humboldt800_mooring
    lozon_gomex80_power_cable_motion)
  add_test(
    NAME example_${_lozon_case}
    COMMAND cabledyn
      "${CMAKE_CURRENT_SOURCE_DIR}/examples/${_lozon_case}.dat"
      "${CMAKE_CURRENT_BINARY_DIR}/example_${_lozon_case}")
  set_tests_properties(example_${_lozon_case} PROPERTIES
    LABELS "fortran;driver;integration;example;lozon")
endforeach()

# Torsion example: a lazy-wave cable twisted two turns at the hang-off through the motionFile
# roll column (condensed torsion, quasi-static).
add_test(
  NAME example_torsion_lazy_wave_hangoff_twist
  COMMAND cabledyn
    "${CMAKE_CURRENT_SOURCE_DIR}/examples/torsion_lazy_wave_hangoff_twist.dat"
    "${CMAKE_CURRENT_BINARY_DIR}/example_torsion_lazy_wave_hangoff_twist")
set_tests_properties(example_torsion_lazy_wave_hangoff_twist PROPERTIES
  LABELS "fortran;driver;integration;example;dynamic")

# The teaching/reference deck enumerates all active defaults and documents every
# mutually exclusive alternative.  Keep it runnable so the canonical OPTIONS
# example cannot drift away from the production parser.
add_test(
  NAME example_cabledyn_options_reference
  COMMAND cabledyn
    "${CMAKE_CURRENT_SOURCE_DIR}/examples/cabledyn_options_reference.dat"
    "${CMAKE_CURRENT_BINARY_DIR}/example_cabledyn_options_reference")
set_tests_properties(example_cabledyn_options_reference PROPERTIES
  LABELS "fortran;driver;integration;example;options")

if(Python3_Interpreter_FOUND)
  add_test(
    NAME lozon_example_equilibrium
    COMMAND ${Python3_EXECUTABLE} ${CMAKE_CURRENT_SOURCE_DIR}/tests/test_lozon_example_equilibrium.py
      --exe $<TARGET_FILE:cabledyn>
      --source ${CMAKE_CURRENT_SOURCE_DIR}
      --output ${CMAKE_CURRENT_BINARY_DIR}/lozon_example_equilibrium)
  set_tests_properties(lozon_example_equilibrium PROPERTIES
    LABELS "python;driver;integration;example;lozon;validation")
  # Modal analysis of decks restrained in torsion: the torsional modes of a straight clamped
  # line against the chain and the continuum, its other modes against TorsStiffness Free, and
  # the twisted lazy wave's modes.
  add_test(
    NAME modal_torsion_deck
    COMMAND ${Python3_EXECUTABLE} ${CMAKE_CURRENT_SOURCE_DIR}/tests/test_modal_torsion_deck.py
      --exe $<TARGET_FILE:cabledyn>
      --source ${CMAKE_CURRENT_SOURCE_DIR}
      --output ${CMAKE_CURRENT_BINARY_DIR}/modal_torsion_deck)
  set_tests_properties(modal_torsion_deck PROPERTIES LABELS "python;driver;integration;validation")
  # A modal analysis about an unstable static state writes its negative omega^2 as a negative
  # frequency of period 0 and notes it; the stable state of a finer mesh does neither.
  add_test(
    NAME modal_negative_note
    COMMAND ${Python3_EXECUTABLE} ${CMAKE_CURRENT_SOURCE_DIR}/tests/test_modal_negative_note.py
      --exe $<TARGET_FILE:cabledyn>
      --output ${CMAKE_CURRENT_BINARY_DIR}/modal_negative_note)
  set_tests_properties(modal_negative_note PROPERTIES LABELS "python;driver;modal" TIMEOUT 300)
  # Static-initialization robustness matrix: a deterministic sample of EI=0 mooring regimes
  # (catenary, semi-taut, taut, suspended, composite, slack/vertical, anchors off the seabed,
  # sloped seabed, fine mesh, soft seabed, current, one/two segments, Free/Connect points)
  # must converge to a balanced tension-only equilibrium that matches the elastic catenary.
  # Needs numpy + scipy in the interpreter (the same probe as the catenary arbiter).
  if(_cabledyn_python_runtime_path)
    execute_process(
      COMMAND "${CMAKE_COMMAND}" -E env "PATH=${_cabledyn_python_runtime_path}"
              "${Python3_EXECUTABLE}" -c "import numpy, scipy"
      RESULT_VARIABLE _statics_matrix_deps_rc
      OUTPUT_QUIET ERROR_QUIET)
  else()
    execute_process(
      COMMAND "${Python3_EXECUTABLE}" -c "import numpy, scipy"
      RESULT_VARIABLE _statics_matrix_deps_rc
      OUTPUT_QUIET ERROR_QUIET)
  endif()
  if(_statics_matrix_deps_rc EQUAL 0)
    add_test(
      NAME statics_robustness_matrix
      COMMAND ${Python3_EXECUTABLE} ${CMAKE_CURRENT_SOURCE_DIR}/tests/test_statics_robustness.py
        --exe $<TARGET_FILE:cabledyn>
        --output ${CMAKE_CURRENT_BINARY_DIR}/statics_robustness_matrix)
    # PROCESSORS reserves the four driver processes the matrix runs at once (--jobs 4); the
    # TIMEOUT only stops a hang.
    set_tests_properties(statics_robustness_matrix PROPERTIES
      LABELS "python;driver;integration;static;validation;slow"
      PROCESSORS 4
      TIMEOUT 3600
      ENVIRONMENT "${_cabledyn_python_test_environment}")
  else()
    message(STATUS "statics_robustness_matrix: skipped (numpy/scipy not importable in ${Python3_EXECUTABLE})")
  endif()
  # A finite-EI line longer than its span with little or no net weight: the weightless bow is the
  # pinned-pinned elastica, light lines bow toward their weight, and a march from the bow stays at rest.
  if(_statics_matrix_deps_rc EQUAL 0)
    add_test(
      NAME light_slack_statics
      COMMAND ${Python3_EXECUTABLE} ${CMAKE_CURRENT_SOURCE_DIR}/tests/test_light_slack_statics.py
        --exe $<TARGET_FILE:cabledyn>
        --output ${CMAKE_CURRENT_BINARY_DIR}/light_slack_statics)
    set_tests_properties(light_slack_statics PROPERTIES
      LABELS "python;driver;integration;static;validation"
      TIMEOUT 600
      ENVIRONMENT "${_cabledyn_python_test_environment}")
  else()
    message(STATUS "light_slack_statics: skipped (numpy/scipy not importable in ${Python3_EXECUTABLE})")
  endif()
endif()

add_executable(test_driver_channels tests/test_driver_channels.f90)
target_link_libraries(test_driver_channels PRIVATE cabledyn_core)
add_test(NAME driver_channels COMMAND test_driver_channels)
set_tests_properties(driver_channels PROPERTIES LABELS "fortran;driver;integration;static;dynamic")

add_executable(test_l3_orcaflex_wave_dynamic tests/test_l3_orcaflex_wave_dynamic.f90)
target_link_libraries(test_l3_orcaflex_wave_dynamic PRIVATE cabledyn_core)
add_test(NAME l3_orcaflex_wave_dynamic COMMAND test_l3_orcaflex_wave_dynamic)
set_tests_properties(l3_orcaflex_wave_dynamic PROPERTIES
  LABELS "fortran;l3;validation;dynamic;hydro;orcaflex" TIMEOUT 180)

# PORTABLE-COUNTER performance gate on the production EI=0 aggregate path: 60 s of the
# module cadence on the committed VolturnUS-S deck, gating COUNTS (Newton/step bands,
# zero substep fallbacks, finite loads) rather than machine-bound wall-clock seconds.
add_executable(test_of_mooring_counters tests/test_of_mooring_counters.f90)
target_link_libraries(test_of_mooring_counters PRIVATE cabledyn_core)
add_test(NAME openfast_mooring_counters
         COMMAND test_of_mooring_counters ${CMAKE_SOURCE_DIR}/examples/iea15mw_volturnus_mooring.dat
         WORKING_DIRECTORY ${CMAKE_BINARY_DIR})
set_tests_properties(openfast_mooring_counters PROPERTIES
                     LABELS "fortran;openfast;perf;dynamic")

# PORTABLE-COUNTER mesh-scaling gate on the standalone EI=0 dynamic route: the committed
# held chain re-meshed to 82 and 820 segments, gating COUNTS (zero temporal subdivisions,
# Newton/step bands that do not grow with the mesh, no dense n_dof**2 mass workspace)
# rather than wall-clock seconds. A solver that cannot recognise the fine-mesh residual
# round-off floor re-solves every step by subdivision and trips it.
add_executable(test_ei0_mesh_scaling_counters tests/test_ei0_mesh_scaling_counters.f90)
target_link_libraries(test_ei0_mesh_scaling_counters PRIVATE cabledyn_core)
add_test(NAME ei0_mesh_scaling_counters
         COMMAND test_ei0_mesh_scaling_counters ${CMAKE_SOURCE_DIR}/examples/dynamic_chain_held.dat
         WORKING_DIRECTORY ${CMAKE_BINARY_DIR})
set_tests_properties(ei0_mesh_scaling_counters PROPERTIES
                     LABELS "fortran;perf;dynamic" TIMEOUT 300)

if(CABLEDYN_RUNTIME_DLLS)
  foreach(_cabledyn_target IN ITEMS
      cabledyn
      cabledyn_shared)
    if(TARGET ${_cabledyn_target})
      cabledyn_stage_runtime_dlls(${_cabledyn_target})
    endif()
  endforeach()
endif()

# Static-dynamic consistency for the end connection: an equilibrium of the static solve
# must persist under a dynamic march, with a control run that MUST drift so the gate is
# demonstrably sensitive to the contribution being present.
add_executable(test_endconn_dynamic tests/test_endconn_dynamic.f90)
target_link_libraries(test_endconn_dynamic PRIVATE cabledyn_core)
add_test(NAME endconn_dynamic COMMAND test_endconn_dynamic)
set_tests_properties(endconn_dynamic PROPERTIES LABELS "fortran;endconnection;dynamic;integration")

if(CABLEDYN_ENABLE_COVERAGE)
  find_program(CABLEDYN_GCOVR gcovr)
  if(CABLEDYN_GCOVR)
    set(CABLEDYN_FORTRAN_COVERAGE_TARGETS
      test_ad
      test_linalg
      test_so3
      test_conventions
      test_rigid_kinematics
      test_emc
      test_hermite_arch
      test_cosserat_strains
      test_cosserat_force
      test_cosserat_assemble
      test_cosserat_mass
      test_cosserat_dynamic
      test_finite_ei_large_rotation
      test_finite_ei_precession
      test_finite_ei_gyroscopic
      test_finite_ei_mult_tangent
      test_finite_ei_mult_step
      test_finite_ei_gyro_primitives
      test_finite_ei_gyro_tangent
      test_finite_ei_gyro_dynamics
      test_finite_ei_model
      test_cable_mesh
      test_cable_elem
      test_cable_assemble
      test_cable_loads
      test_bathymetry
      test_hydro
      test_cable_static
      test_catenary
      test_robust_init
      test_line
      test_hermite_cable
      test_hermite_torsion_kernel
      test_hermite_twist_kernel
      test_nodal_twist_dynamic
      test_torsion_one_end
      test_hermite_torsion_static
      test_hermite_torsion_dynamic
      test_hermite_cable_static
      test_hermite_sequenced
      test_hermite_resolution
      test_hermite_automesh
      test_hermite_cable_dynamic
      test_hermite_drag_dynamics
      test_hermite_axial_damping
      test_hermite_cable_control
      test_control_torsion
      test_hermite_added_mass
      test_hermite_wave_forcing
      test_lazywave_dynamics
      test_l3_lazywave_dynamic
      test_l3_longduration_mooring
      test_hermite_axial_drag_arbiter
      test_l2_chain_parity
      test_l2_volturnus_mooring
      test_l2_lozon80_mooring
      test_l2_lozon200_semitaut
      test_l2_lozon200_semitaut_deck
      test_l3_orcaflex_static
      test_l3_orcaflex_current_static
      test_l3_orcaflex_finite_ei_static
      test_l3_lazywave_curvature
      test_l3_lazywave_refinement
      test_l3_lazywave_fullcable
      test_l4_platform_mooring
      test_damping
      test_viscoelastic
      test_syrope
      test_prescribed_motion
      test_model
      test_system
      test_openfast_shell
      test_hermite_fmf
      test_openfast_aggregate
      test_openfast_pinned_rod
      test_openfast_pinned_body
      test_of_mooring_counters
      test_ei0_mesh_scaling_counters
      test_c_api
      test_cable_dynamic
      test_cable_driver
      test_line_driver
      test_l1_catenary
      test_l1_axial_patch
      test_l1_seabed
      test_l1_string
      test_l1_hermite_bending_patch
      test_l1_hermite_cantilever
      test_l1_hermite_convergence
      test_l1_hermite_elastica
      test_l1_hermite_beam_vibration
      test_l1_hermite_energy_stability
      test_l3_hermite_touchdown
      test_l1_bending_patch
      test_l1_cantilever
      test_l1_convergence_order
      test_l1_large_deflection
      test_l1_euler_beam
      test_l1_energy_stability
      test_l3_wave_smoke
      test_deck_driver
      test_l3_orcaflex_wave_dynamic
      test_snap_load
      test_endconn_spring
      test_endconn_static
      test_endconn_dynamic
    )
    add_custom_target(fortran_coverage
      COMMAND ${CMAKE_CTEST_COMMAND} --test-dir ${CMAKE_BINARY_DIR}
              -L fortran -LE slow --output-on-failure
      COMMAND ${CABLEDYN_GCOVR}
              --root ${CMAKE_SOURCE_DIR}
              --filter ${CMAKE_SOURCE_DIR}/src/
              --exclude ${CMAKE_SOURCE_DIR}/tests/
              --exclude ${CMAKE_SOURCE_DIR}/app/
              --gcov-ignore-parse-errors negative_hits.warn_once_per_file
              --txt
              --xml-pretty
              --xml ${CMAKE_BINARY_DIR}/fortran-coverage.xml
              --html-details ${CMAKE_BINARY_DIR}/fortran-coverage.html
      WORKING_DIRECTORY ${CMAKE_BINARY_DIR}
      COMMENT "Running non-slow Fortran tests and reporting src/ coverage"
      DEPENDS ${CABLEDYN_FORTRAN_COVERAGE_TARGETS}
      VERBATIM
    )
  else()
    message(WARNING
      "CABLEDYN_ENABLE_COVERAGE is ON, but gcovr was not found. "
      "Install gcovr in the active environment to enable the fortran_coverage target.")
  endif()
endif()

# Dynamic steps at the residual round-off floor (a held stiff cable at rest, a strongly
# damped line on a refined mesh), and every shipped dynamic example must complete its march.
foreach(_floor_case IN ITEMS held_start_gomex80_power_cable held_start_humboldt800_power_cable
    ve_polyester_waves_fine_mesh umaine_power_cable_alone_static umaine_power_cable_alone_dynamic)
  add_test(NAME ${_floor_case}
    COMMAND cabledyn "${CMAKE_CURRENT_SOURCE_DIR}/tests/data/${_floor_case}.dat"
      "${CMAKE_CURRENT_BINARY_DIR}/${_floor_case}")
  set_tests_properties(${_floor_case} PROPERTIES LABELS "fortran;driver;integration;dynamic")
endforeach()
foreach(_dyn_example IN ITEMS dynamic_chain_held dynamic_chain_current dynamic_chain_waves
    ve_polyester_dynamic_waves syrope_polyester_mooring composite_chain_syrope_chain clump_weight_free_point
    connect_weighted_point)
  add_test(NAME example_${_dyn_example}
    COMMAND cabledyn "${CMAKE_CURRENT_SOURCE_DIR}/examples/${_dyn_example}.dat"
      "${CMAKE_CURRENT_BINARY_DIR}/example_${_dyn_example}")
  set_tests_properties(example_${_dyn_example} PROPERTIES LABELS "fortran;driver;integration;example;dynamic")
endforeach()
# Feature examples (vessel motion and RAOs, discrete buoyancy, range graphs and touchdown, wave
# spectra, stream waves, anisotropic friction, modal analysis, clamped ends on bodies, MoorDyn-C
# kinematics files, bodies and rods, line failure, cross-flow VIV, the mode-1 axial damping ratio,
# composite synthetic ropes on a floater, a cable between two moving ends, attachments under a
# bend stiffener, bathymetry with as-laid friction, torsion with one end free): every shipped
# deck must run to completion.
foreach(_feature_example IN ITEMS
    lazy_wave_vessel_motion lazy_wave_vessel_rao lazy_wave_bend_stiffener lazy_wave_buoyancy_modules lazy_wave_buoyancy_smeared
    chain_range_tdp chain_torsethaugen_spread chain_two_train_sea stream_wave_shallow_chain
    airy_wave_shallow_chain laid_cable_cross_current chain_modes lazy_wave_modes buoy_clamped_cable
    moordynC_wavekin/chain_wavekin7_currents1 spar_pinned_rods mixed_body_rods_points
    als_volturnus_line_break_time als_volturnus_line_break_tension
    viv_taut_line_crossflow composite_axial_damping_mode1 composite_ve_syrope_jonswap
    composite_chain_poly_chain_modes shared_cable_two_floaters lazy_wave_modules_stiffener
    chain_sloped_bathymetry_friction torsion_free_end_armoured_cable
    moordynC_currents/chain_wavekin3_currents2 moordynC_currents/chain_currents5_grid)
  get_filename_component(_feature_name "${_feature_example}" NAME)
  add_test(NAME example_${_feature_name}
    COMMAND cabledyn "${CMAKE_CURRENT_SOURCE_DIR}/examples/${_feature_example}.dat"
      "${CMAKE_CURRENT_BINARY_DIR}/example_${_feature_name}")
  set_tests_properties(example_${_feature_name} PROPERTIES LABELS "fortran;driver;integration;example;dynamic")
endforeach()
# The shipped decks no other test runs by name (static moorings, a buoy and a spar on legs):
# each must run as shipped.
foreach(_shipped_example IN ITEMS
    composite_chain_wire nylon_taut_mooring semitaut_chain_polyester spread_4line_chain
    taut_chain_steep ve_nylon_loaddependent_mooring wd0050_chain wire_catenary_mooring
    rigid6_buoy rod_moored_spar)
  add_test(NAME example_${_shipped_example}
    COMMAND cabledyn "${CMAKE_CURRENT_SOURCE_DIR}/examples/${_shipped_example}.dat"
      "${CMAKE_CURRENT_BINARY_DIR}/example_${_shipped_example}")
  set_tests_properties(example_${_shipped_example} PROPERTIES LABELS "fortran;driver;integration;example")
endforeach()

# Composite grounded moorings must initialize at every mesh refinement of the shipped decks.
add_executable(test_static_mesh_refinement tests/test_static_mesh_refinement.f90)
target_link_libraries(test_static_mesh_refinement PRIVATE cabledyn_core)
add_test(NAME static_mesh_refinement
  COMMAND test_static_mesh_refinement "${CMAKE_CURRENT_SOURCE_DIR}/examples")
set_tests_properties(static_mesh_refinement PROPERTIES LABELS "fortran;driver;integration;static")

add_executable(test_hermite_strain_bound tests/test_hermite_strain_bound.f90)
target_link_libraries(test_hermite_strain_bound PRIVATE cabledyn_core)
add_test(NAME hermite_strain_bound COMMAND test_hermite_strain_bound)
set_tests_properties(hermite_strain_bound PROPERTIES LABELS "fortran;unit;finite_ei")

# --- test time limits ---------------------------------------------------------------------
# Tests that run for minutes in an optimised build carry the `slow` label, so the fast
# loop (`ctest -L fortran -LE slow`) leaves them out. CTest applies no timeout of its own,
# so every test without an explicit TIMEOUT gets a default that stops a hang; the long
# tests get a larger one. Both leave room for the Debug (-fcheck=all) build.
foreach(_slow_test IN ITEMS example_als_volturnus_line_break_time example_als_volturnus_line_break_tension
                            static_init_sweep)
  if(TEST ${_slow_test})
    set_property(TEST ${_slow_test} APPEND PROPERTY LABELS slow)
  endif()
endforeach()
foreach(_long_test IN ITEMS l3_lazywave_dynamic l3_lazywave_dynamic_force_blend l4_lazywave_coupled
                            l3_longduration_mooring lazywave_dynamics static_init_sweep body_rod_physics
                            example_als_volturnus_line_break_time example_als_volturnus_line_break_tension
                            lozon_example_equilibrium memory_growth memory_growth_aggregate driver_repeat_exit)
  if(TEST ${_long_test})
    get_test_property(${_long_test} TIMEOUT _long_timeout)
    if(NOT _long_timeout)
      set_tests_properties(${_long_test} PROPERTIES TIMEOUT 5400)
    endif()
  endif()
endforeach()
get_property(_all_tests DIRECTORY PROPERTY TESTS)
foreach(_any_test IN LISTS _all_tests)
  get_test_property(${_any_test} TIMEOUT _any_timeout)
  if(NOT _any_timeout)
    set_tests_properties(${_any_test} PROPERTIES TIMEOUT 1800)
  endif()
endforeach()

# GNU warnings in the test programs. The solver core builds with no warning; these flags apply
# to the test executables only, where the diagnosed patterns are intended: exact real
# comparisons (bit identity and exact-zero limits are stated test contracts), integer
# divisions of node counts, loops whose out-of-range indices sit in guarded branches, and
# callback dummies the interface requires. GCC 15+ also reports allocatable descriptors nested
# in a default-initialized aggregate as uninitialized, although Fortran initializes every
# allocatable component as unallocated.
if(CMAKE_Fortran_COMPILER_ID STREQUAL "GNU")
  get_property(_cabledyn_targets DIRECTORY PROPERTY BUILDSYSTEM_TARGETS)
  foreach(_cabledyn_target IN LISTS _cabledyn_targets)
    get_target_property(_cabledyn_target_type ${_cabledyn_target} TYPE)
    if(_cabledyn_target MATCHES "^test_" AND _cabledyn_target_type STREQUAL "EXECUTABLE")
      target_compile_options(${_cabledyn_target} PRIVATE
                             $<$<COMPILE_LANGUAGE:Fortran>:-Wno-compare-reals>
                             $<$<COMPILE_LANGUAGE:Fortran>:-Wno-uninitialized>
                             $<$<COMPILE_LANGUAGE:Fortran>:-Wno-maybe-uninitialized>
                             $<$<COMPILE_LANGUAGE:Fortran>:-Wno-integer-division>
                             $<$<COMPILE_LANGUAGE:Fortran>:-Wno-do-subscript>
                             $<$<COMPILE_LANGUAGE:Fortran>:-Wno-unused-dummy-argument>)
    endif()
  endforeach()
endif()
