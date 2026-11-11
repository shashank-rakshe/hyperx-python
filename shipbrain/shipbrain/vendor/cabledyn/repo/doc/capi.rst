.. SPDX-License-Identifier: Apache-2.0

C API reference
===============

CableDyn ships a C ABI in the shared library ``cabledyn``. It is the embedding interface for
a host that owns time integration: a CFD solver (Star-CCM+, OpenFOAM), a vessel or platform
simulator, or a scripting layer. The host prescribes the motion of the coupled points each step,
and CableDyn returns the loads the cables exert on them, following the kinematics-in / loads-out
contract of :doc:`coupling_boundary`. The :doc:`Python package <python>` is a ctypes layer over
the same library. OpenFAST, maintained by NLR (National Laboratory of the Rockies, formerly NREL),
uses its own in-tree module instead (:doc:`openfast`).

Every declaration below is in the installed header ``CableDyn_CAPI.h``. All functions return
``void`` except six queries: ``CableDyn_IsInitialized`` returns ``bool``, and
``CableDyn_NCoupledDOF``, ``CableDyn_NPoints``, ``CableDyn_NLines``, ``CableDyn_GetAbiMinor`` and
``CableDyn_NObjects`` return ``int``. Results come back through caller-owned buffers and a status
code in ``*err_stat``.

.. contents:: On this page
   :local:
   :depth: 2

Overview
--------

A model lives behind an opaque handle. The lifecycle is:

.. code-block:: text

   CableDyn_Create
     -> [CableDyn_SetHostFluid]                                         (host fluid field)
     -> CableDyn_InitDeck | CableDyn_InitDeckAt | CableDyn_InitDeckRotating
        | CableDyn_InitLine | CableDyn_InitLines                      (initialize; may repeat)
     -> CableDyn_GetCoupledMotion                                     (read the initial state)
     -> loop:  [CableDyn_SaveState | CableDyn_RestoreState]           (host outer correctors)
               [CableDyn_UpdatePointFluidFields | CableDyn_UpdateFluidFields]
               [CableDyn_UpdateRotations]                             (a host that turns)
               CableDyn_Step(dt, motion at t+dt)
               CableDyn_CalcOutput [, CableDyn_GetCoupledMoments]     (loads at t+dt)
     -> CableDyn_Close

A host solver that drives the ``Coupled`` points of a deck, a CFD code in particular, should
read `Coupling a host (CFD) solver`_ first: it gives the call sequence and how it differs from
MoorDyn's C API.

.. list-table:: Function summary
   :header-rows: 1
   :widths: 38 62

   * - Function
     - Purpose
   * - ``CableDyn_GetVersion``, ``CableDyn_GetVersionString``
     - library version and C ABI version
   * - ``CableDyn_Create``, ``CableDyn_Close``
     - allocate and release a handle
   * - ``CableDyn_InitDeck``
     - build a model from a ``.dat`` deck and solve its static equilibrium
   * - ``CableDyn_InitLine``, ``CableDyn_InitLines``
     - build a structural-only model from caller-meshed arrays
   * - ``CableDyn_UpdateStates``
     - set the coupled-point motion without advancing time
   * - ``CableDyn_UpdatePointFluidFields``
     - set fluid kinematics at the deck points (point hydrodynamics)
   * - ``CableDyn_SetHostFluid``, ``CableDyn_NFluidNodes``, ``CableDyn_GetFluidNodePositions``,
       ``CableDyn_UpdateFluidFields``
     - supply the ambient fluid at the nodes of every line (`Step 9: moving water`_)
   * - ``CableDyn_Step``
     - advance one implicit step to :math:`t+\Delta t`
   * - ``CableDyn_CalcOutput``
     - loads at the coupled DOFs from the current state
   * - ``CableDyn_CalcOutputDerivatives``
     - loads and the analytic load Jacobians at a supplied state
   * - ``CableDyn_GetCoupledMotion``
     - read the current coupled-point motion
   * - ``CableDyn_GetLastError``
     - diagnostic text for the last failure on a handle
   * - ``CableDyn_GetInitNotes``
     - the notes of the last deck initialisation on a handle
   * - ``CableDyn_IsInitialized``, ``CableDyn_NCoupledDOF``, ``CableDyn_NPoints``,
       ``CableDyn_NLines``
     - state and size queries
   * - ``CableDyn_GetAbiMinor``, ``CableDyn_NObjects``, ``CableDyn_GetObjectInfo``,
       ``CableDyn_GetLineValues``, ``CableDyn_GetPointState``, ``CableDyn_GetBodyState``,
       ``CableDyn_GetRodState``, ``CableDyn_EvalChannel``
     - object queries (ABI 1.1): the objects of the model, their committed state, and any
       ``OUTPUTS`` channel (`Object queries`_)
   * - ``CableDyn_InitDeckAt``, ``CableDyn_SaveState``, ``CableDyn_RestoreState``,
       ``CableDyn_GetCoupledLayout``
     - host coupling (ABI 1.2): initialization with the statics at the host's positions, a
       one-slot state save and restore for outer correctors, and the owner of each block of
       the coupled vector (`Host coupling calls`_)
   * - ``CableDyn_InitDeckRotating``, ``CableDyn_UpdateRotations``,
       ``CableDyn_GetCoupledMoments``
     - host rotations (ABI 1.3): a host that turns the bodies its coupled points are fixed to,
       for lines restrained in torsion and Rigid end connections, and the moments the lines
       apply (`Host rotation calls`_)

Building and linking
--------------------

Build and install
~~~~~~~~~~~~~~~~~

The library is the CMake target ``cabledyn_shared``. It is part of the default build.

.. code-block:: bash

   cmake -S . -B build -DCMAKE_BUILD_TYPE=Release
   cmake --build build --target cabledyn_shared
   cmake --install build --prefix /opt/cabledyn

The install step places the library and the header under the standard GNU install directories.
It does not install a CMake package configuration file or a pkg-config file. Locate the two
files directly, as shown below.

.. list-table:: Installed C ABI files
   :header-rows: 1
   :widths: 22 40 38

   * - Platform
     - Library files
     - Header
   * - Linux
     - ``lib/libcabledyn.so.0.4.2``, the soname link ``libcabledyn.so.1``, and the development
       link ``libcabledyn.so``. ``lib`` is the platform ``CMAKE_INSTALL_LIBDIR``, which can be
       ``lib64`` or a multiarch directory.
     - ``include/CableDyn_CAPI.h``
   * - macOS
     - ``lib/libcabledyn.0.4.2.dylib``, ``lib/libcabledyn.1.dylib``, ``lib/libcabledyn.dylib``
     - ``include/CableDyn_CAPI.h``
   * - Windows, GNU toolchain
     - ``bin/libcabledyn.dll`` and the import library ``lib/libcabledyn.dll.a``. The GNU
       Fortran, OpenMP, and OpenBLAS runtime DLLs the build found are also copied to ``bin``.
     - ``include\CableDyn_CAPI.h``
   * - Windows, Intel Fortran with MSVC
     - ``bin/cabledyn.dll`` and the import library ``lib/cabledyn.lib``
     - ``include\CableDyn_CAPI.h``

The library links the Fortran runtime, LAPACK/BLAS, and, when the compiler supports it, the
OpenMP runtime. These must be loadable at run time: through the rpath or ``LD_LIBRARY_PATH`` on
Linux, and on ``PATH`` or next to the executable on Windows. When OpenMP is enabled, the lines of
one model are processed in parallel. ``OMP_NUM_THREADS`` controls the thread count.

CableDyn's linear systems are small and banded, so it runs OpenBLAS with one thread. A threaded
OpenBLAS starts one worker per logical CPU when its DLL loads, and on Windows each worker commits
a work buffer of about 128 MB at once (about 4 GB on a 32-CPU machine). The Windows GNU build
therefore does not import ``openblas.dll``: the first ``CableDyn_Create`` (or, in an executable,
the first solve) loads the ``openblas.dll`` next to the CableDyn library or executable with a
one-thread pool, falling back to the standard DLL search order. If it cannot be loaded,
``InitDeck``, ``InitDeckAt``, ``InitLine`` and ``InitLines`` return ``CD_C_ALLOC_FAIL`` and
``CableDyn_GetLastError`` names the library, each location tried and the Windows load error;
the standalone driver prints the same diagnostic and exits with status 2. Other builds
that link OpenBLAS call ``openblas_set_num_threads(1)`` at the first ``Create``; the Intel
release links the single-threaded reference LAPACK/BLAS. The environment variable
``CABLEDYN_BLAS_THREADS`` changes this: a positive integer sets that many BLAS threads, and
``default`` (or ``0``) leaves OpenBLAS to its
own ``OPENBLAS_NUM_THREADS`` or CPU-count setting. An explicit ``OPENBLAS_NUM_THREADS`` is always
respected when the DLL is loaded. If another component of the process loaded the same
``openblas.dll`` first, its pool already exists and CableDyn only limits how many workers its
calls use. Each OpenMP thread that calls into OpenBLAS still commits one work buffer.

The standalone Windows release executables do not contain this library. A process that embeds
CableDyn needs a ``cabledyn_shared`` build.

The library exports exactly the functions declared in ``CableDyn_CAPI.h``. It uses a module
definition file on Windows, an exported-symbols list on macOS, and a version script on Linux. No
Fortran module symbol is exported, so none can collide with host symbols.

CMake consumer
~~~~~~~~~~~~~~

.. code-block:: cmake

   cmake_minimum_required(VERSION 3.20)
   project(coupler LANGUAGES C)

   # CableDyn installs a header and a shared library but no CMake package,
   # so locate both files directly (set CMAKE_PREFIX_PATH to the install prefix).
   find_path(CABLEDYN_INCLUDE_DIR CableDyn_CAPI.h REQUIRED)
   find_library(CABLEDYN_LIBRARY NAMES cabledyn REQUIRED)

   add_executable(coupler coupler.c)
   target_include_directories(coupler PRIVATE "${CABLEDYN_INCLUDE_DIR}")
   target_link_libraries(coupler PRIVATE "${CABLEDYN_LIBRARY}")
   if(NOT WIN32)
     target_link_libraries(coupler PRIVATE m)   # only for the example's sin/cos
   endif()

.. code-block:: bash

   cmake -S . -B build -DCMAKE_PREFIX_PATH=/opt/cabledyn
   cmake --build build

``find_library(... NAMES cabledyn)`` finds ``libcabledyn.so`` or ``libcabledyn.dylib``,
``libcabledyn.dll.a`` with a GNU toolchain on Windows, and ``cabledyn.lib`` with MSVC.

Command lines
~~~~~~~~~~~~~

GCC or Clang on Linux and macOS:

.. code-block:: bash

   PREFIX=/opt/cabledyn
   gcc -std=c11 -Wall -Wextra coupler.c -I"$PREFIX/include" \
       -L"$PREFIX/lib" -Wl,-rpath,"$PREFIX/lib" -lcabledyn -lm -o coupler

MinGW-w64 GCC on Windows. The DLL is found at run time through ``PATH``:

.. code-block:: bash

   gcc -std=c11 -Wall -Wextra coupler.c -I"$PREFIX/include" -L"$PREFIX/lib" -lcabledyn -o coupler.exe
   PATH="$PREFIX/bin:$PATH" ./coupler.exe

MSVC (``cl``) from a Developer Command Prompt. An Intel Fortran with MSVC build already installs
``cabledyn.lib``:

.. code-block:: bat

   cl /nologo /W4 coupler.c /I "%PREFIX%\include" /link /LIBPATH:"%PREFIX%\lib" cabledyn.lib

A GNU-built ``libcabledyn.dll`` can also be linked from MSVC. Generate an MSVC import library
from the module definition file in the source tree, and name the DLL it binds to:

.. code-block:: bat

   lib /nologo /def:src\cabledyn.def /name:libcabledyn.dll /machine:x64 /out:cabledyn.lib
   cl /nologo /W4 coupler.c /I "%PREFIX%\include" /link cabledyn.lib

Mixing C runtimes this way is safe. No memory allocated on one side is freed on the other,
because every buffer the API touches is owned by the caller. The header needs C99
``<stdbool.h>`` and provides ``extern "C"`` guards for C++.

ABI and versioning
------------------

.. list-table::
   :header-rows: 1
   :widths: 40 16 44

   * - Identifier
     - Value
     - Meaning
   * - ``CABLEDYN_CAPI_VERSION_MAJOR`` / ``_MINOR`` / ``_PATCH``
     - 0 / 1 / 0
     - the CableDyn release the header belongs to
   * - ``CABLEDYN_CAPI_ABI_VERSION``
     - 1
     - the C ABI revision the header describes
   * - ``CABLEDYN_CAPI_ABI_MINOR`` / ``CableDyn_GetAbiMinor()``
     - 3
     - additive extensions of ABI 1: 1 adds the `Object queries`_, 2 the
       `Host coupling calls`_, 3 the `Host rotation calls`_
   * - ``CableDyn_GetVersion(&major, &minor, &patch, &abi)``
     - runtime
     - the same four numbers, reported by the loaded library
   * - ``CableDyn_GetVersionString``
     - runtime
     - ``"CableDyn 0.4.2 C-ABI 1"``
   * - shared-library ``SOVERSION``
     - 1
     - soname ``libcabledyn.so.1`` or install name ``libcabledyn.1.dylib``. The Windows DLL
       name carries no version.

The ABI version identifies the set of exported prototypes together with their semantics: the
argument order and types, the array layouts, and the meaning of the status codes. A change that
would break an existing caller raises ``CABLEDYN_CAPI_ABI_VERSION`` and ``SOVERSION`` together.
Examples are removing or renaming a function, changing a prototype, or changing a layout or a
status meaning. The release numbers change independently of the ABI. CableDyn 0.1.x is an early
public series, so the ABI may still change before 1.0.

At load time, check the library's ABI against the header you compiled with:

.. code-block:: c

   int major, minor, patch, abi;
   CableDyn_GetVersion(&major, &minor, &patch, &abi);
   if (abi != CABLEDYN_CAPI_ABI_VERSION) { /* refuse to run: header and library disagree */ }

The Python package does this check at import and rejects a library that speaks another ABI.

A minor extension only adds functions: every ABI 1 prototype and its semantics are unchanged,
so a caller built against an older header keeps working. A caller that uses the additions checks
``CableDyn_GetAbiMinor() >= 1`` before calling the object queries,
``CableDyn_GetAbiMinor() >= 2`` before calling the host-coupling functions, and
``CableDyn_GetAbiMinor() >= 3`` before calling the host-rotation functions.

Calling conventions
-------------------

These rules apply to every entry point. The Python package uses the same array order.

* **Scalars by value, results by pointer.** Counts, ``dt``, ``rho_inf``, ``eps_fd``, and
  ``fluid_density`` are passed by value. Every ``int *err_stat`` is always written.
* **Pointers that are not checked.** Scalar out-parameters must point to valid storage:
  ``err_stat``, ``converged``, ``stalled``, ``n_iter``, the four ``CableDyn_GetVersion``
  outputs, the ``value`` of ``CableDyn_EvalChannel``, and the ``void **`` of ``Create`` and
  ``Close``. They are not checked for ``NULL``; passing ``NULL`` is undefined behaviour.
* **Pointers that are checked.** Handles, arrays, and strings are checked for ``NULL``. An array
  may be ``NULL`` only where its declared length is zero. Each function's table states the exact
  rule. A ``NULL`` where data is required returns ``CD_C_BAD_INPUT``.
* **Array lengths.** Arrays are caller-owned, contiguous, and ``double`` or ``int``. The library
  reads or writes exactly the length given in each table. It cannot detect a shorter buffer: a
  short buffer is undefined behaviour. The sizes passed to a call must match the initialised
  model (``n_coupled_dof`` must equal ``CableDyn_NCoupledDOF``, ``n_point`` must equal
  ``CableDyn_NPoints``). Otherwise the call returns ``CD_C_BAD_INPUT`` and reads nothing.
* **Vectors.** Nodal positions, velocities, and fluid fields are interleaved ``x, y, z`` triples
  (``3 * n`` values). The coupled vectors ``q``, ``v``, ``a``, and ``loads`` are flat vectors of
  ``n_coupled_dof`` entries. Their layout depends on how the model was initialised; see
  `Coupled DOF layout`_.
* **Indices are 1-based.** This applies to element connectivity (``elem_conn``, two node
  indices per element), fixed-DOF indices (``fixed_dofs``), and ``coupled_map`` entries.
  DOF :math:`d` belongs to node :math:`\lfloor (d-1)/3 \rfloor + 1`, component
  :math:`(d-1) \bmod 3` (0 = x, 1 = y, 2 = z). Node :math:`k` therefore owns DOFs
  :math:`3k-2, 3k-1, 3k`.
* **Matrices are column-major.** The ``n``-by-``n`` blocks written by
  ``CableDyn_CalcOutputDerivatives`` store ``J[i + j*n]`` as :math:`\partial L_i/\partial x_j`
  (0-based ``i``, ``j``). This is the Fortran and LAPACK order. A row-major ``J[i][j]`` view of
  the same memory is the transpose.
* **Strings.** A deck path is ``deck_path_len`` bytes. An embedded ``NUL`` ends it early, and
  trailing blanks are ignored. The Fortran runtime opens the path, using the active ANSI code
  page on Windows. A relative path resolves against the process working directory. Files the
  deck references resolve against the deck's directory. Output strings are always
  ``NUL``-terminated and truncated to ``len - 1`` characters.
* **Units and frame.** SI throughout, in the global right-handed frame with z up and still
  water at :math:`z = 0` (:doc:`conventions`). See `State, units, and load sign`_.
* **Threads.** ``Create`` and ``Close`` are thread-safe; a process-wide mutex guards the handle
  registry, independently of OpenMP. Separate handles may run concurrently on separate threads.
  ``InitDeck``, ``InitDeckAt``, ``InitLine``, and ``InitLines`` are serialised by a second
  process-wide lock: they open and parse files through the Fortran runtime, which cannot open
  one file on two units at once (two threads reading the same deck, or decks sharing a Syrope
  OWC table) and whose formatted I/O is not safe to run concurrently. Concurrent initialisations therefore succeed but
  run one after another; a thread blocks while another thread initialises. ``Step``,
  ``UpdateStates``, ``CalcOutput``, and the other per-handle calls do no file or formatted I/O
  when they succeed and run concurrently on separate handles. A single handle must not be used
  from two threads at once, or while another thread closes it. The GNU Fortran runtime switches
  the process-wide numeric locale to ``"C"`` for the duration of each formatted I/O statement;
  a host thread that formats numbers with the C library at that moment can observe it.
  ``Close`` also releases the calling thread's OpenMP worker pool, so no worker thread is still
  shutting down when the host process exits. Close each handle on the thread that stepped it,
  before that thread ends; a pool left behind by a thread that ends without closing can deadlock
  the MinGW OpenMP runtime at process exit on Windows.
* **Handles** are raw pointers checked against a registry of live handles before any use.
  ``Close`` on ``NULL`` is a no-op. A closed, double-closed, or foreign pointer is rejected with
  ``CD_C_BAD_HANDLE`` and is never dereferenced. One limitation is inherent to a pointer ABI: if
  a stale copy's address has been reused by a new ``Create``, the copy cannot be told apart from
  the new handle.
* **Re-initialisation is atomic for decks.** Calling ``CableDyn_InitDeck`` or
  ``CableDyn_InitDeckAt`` on an initialised handle replaces the model only on success. If the
  new initialisation fails, the previous model is kept unchanged, and so is the state saved by
  ``CableDyn_SaveState``; a successful one discards that save. ``CableDyn_InitLine`` and
  ``CableDyn_InitLines`` build the point model in place: a failure during the build leaves the
  handle to be initialised again, an input rejected before it leaves the previous model live
  (``CableDyn_IsInitialized`` tells which), and either way the saved state is discarded. The one
  exception is a handle whose
  deck model runs on the coupled aggregate (finite-EI lines, bodies or rods): a failed
  ``InitLine``/``InitLines`` leaves that model live, and its saved state with it.
* **Time.** The library keeps no clock. Only ``dt`` enters ``CableDyn_Step``, and the host owns
  the time line.

Status codes
------------

.. list-table::
   :header-rows: 1
   :widths: 28 8 64

   * - Code
     - Value
     - Meaning
   * - ``CD_C_OK``
     - 0
     - success
   * - ``CD_C_BAD_HANDLE``
     - 1
     - the handle is ``NULL``, closed, or was not returned by ``CableDyn_Create``
   * - ``CD_C_ALLOC_FAIL``
     - 2
     - a memory allocation failed
   * - ``CD_C_BAD_INPUT``
     - 3
     - an argument was rejected. Causes include a ``NULL`` array where data is required, a size
       that does not match the model, a non-finite or out-of-range value, a deck that fails
       parsing or validation, or a deck feature this entry point does not support.
   * - ``CD_C_SOLVE_FAIL``
     - 4
     - a numerical failure: the static solve, an initial-acceleration solve, a hard failure in a
       dynamic step, or a failed load or derivative evaluation
   * - ``CD_C_NOT_INITIALIZED``
     - 5
     - the call needs a model, and no ``Init*`` call on this handle has succeeded

A step that finishes without meeting the Newton tolerance still returns ``CD_C_OK``. The
``converged`` flag reports that case; see :ref:`the step outcomes <capi-step-outcomes>`.

Diagnostics
~~~~~~~~~~~

Each handle keeps the text of its last failure, up to 4096 characters. The message is set by a
failing call on a valid handle and cleared by a successful one. ``CableDyn_GetLastError`` does
not change it, and neither does ``CableDyn_IsInitialized``. A call rejected with
``CD_C_BAD_HANDLE`` has no handle to store a message in. ``CableDyn_GetLastError`` on such a
pointer returns ``"CableDyn C API: bad handle"``. Read the message right after the failing call.
Any later call on the same handle can replace it.

Coupled DOF layout
------------------

``q_coupled``, ``v_coupled``, ``a_coupled``, and ``coupled_loads`` all use the same layout, and
so do the rows and columns of every Jacobian. The layout is fixed when the handle is
initialised.

``CableDyn_InitDeck`` or ``CableDyn_InitDeckAt``, point route (``EI = 0`` lines only)
   One ``x, y, z`` block for every deck point that is attached to at least one line end, in
   ``POINTS`` table order. This includes points of every type: ``Fixed`` anchors,
   ``Coupled``/``Vessel`` points, and ``Free``/``Connect`` points. ``n_coupled_dof`` is
   three times the number of attached points. A point referenced by no line gets no block, but
   it is still counted by ``CableDyn_NPoints``.

``CableDyn_InitDeck`` or ``CableDyn_InitDeckAt``, aggregate route (finite-EI lines, bodies, rods)
   One ``x, y, z`` block for every host-driven point and nothing else: first the
   ``Coupled``/``Vessel`` points attached to an ``EI = 0`` line, in ``POINTS`` table order,
   then the fairlead (End A, which must be ``Coupled``/``Vessel``) of each finite-EI line, in
   ``LINES`` table order, then the End B of each finite-EI line whose End B is also
   ``Coupled``/``Vessel`` (a line between two moving points, driven at both ends), in ``LINES``
   table order. ``Fixed`` anchors, ``Free``/``Connect`` points, bodies and rods have no block.

``CableDyn_InitLine``
   ``n_fixed`` entries. Entry ``k`` is the DOF ``fixed_dofs[k]``, in the order the caller
   listed them.

``CableDyn_InitLines`` without a ``coupled_map``
   The concatenation, in line order, of each line's ``fixed_dofs`` list.
   ``n_coupled_dof`` is the sum of ``n_fixed``.

``CableDyn_InitLines`` with a ``coupled_map``
   Line ``i``'s ``j``-th fixed DOF maps to system DOF ``coupled_map[6*i + j]`` (0-based ``i`` and
   ``j``, 1-based value). Lines that share a system DOF share that end point: its motion is
   applied to every such line, and their loads and Jacobian entries are summed.
   ``n_coupled_dof`` is the largest map entry.

Every block is prescribed by the caller on each ``Step`` and ``UpdateStates``, including the
anchor blocks of a deck. Fill the vectors once from ``CableDyn_GetCoupledMotion``, then
overwrite only the blocks the host drives. Deck ``Free`` and ``Connect`` points are the
exception, described under ``CableDyn_Step``.

On a deck model, ``CableDyn_GetCoupledLayout`` (ABI 1.2) returns the deck point id and type
of every block, so a host does not have to derive the layout from the deck: the host drives
the blocks of type ``CD_C_POINT_COUPLED``. `Coupling a host (CFD) solver`_ works through an
example.

State, units, and load sign
---------------------------

.. list-table::
   :header-rows: 1
   :widths: 26 20 54

   * - Quantity
     - Unit
     - Definition
   * - ``q`` (positions)
     - m
     - global coordinates of the coupled DOFs, not displacements
   * - ``v`` (velocities)
     - m/s
     - time derivative of ``q`` in the global frame
   * - ``a`` (accelerations)
     - m/s²
     - time derivative of ``v`` in the global frame
   * - ``coupled_loads``
     - N
     - force exerted **by the cables on the host** at each coupled DOF, in global axes
   * - ``dload_dq``
     - N/m
     - :math:`\partial L/\partial q`
   * - ``dload_dv``
     - N·s/m
     - :math:`\partial L/\partial v`
   * - ``dload_da``, ``added_mass``
     - kg
     - :math:`\partial L/\partial a` and :math:`M_a = -\partial L/\partial a`

**Load sign.** Each line satisfies :math:`M\ddot{q} + f_{\text{int}} - f_{\text{ext}} = R`, where
:math:`R` is the support reaction the host must supply at the prescribed DOFs. The returned load
is :math:`L = -R`, the equal and opposite force the cable applies to the host. This is the
MoorDyn coupled-load convention. It includes the cable's end inertia, and for deck models also
the weight, buoyancy, seabed, and hydrodynamic shares at the end node. A cable under tension
pulls each attached point toward the cable. For example, a line running along :math:`+x` from
end A to end B returns :math:`L_x > 0` at A and :math:`L_x < 0` at B. When lines share a point,
their loads at that point are summed.

**Jacobians.** For the tight Newton loop of a monolithic host, the linear load model is
:math:`L(q+\delta q, v+\delta v, a+\delta a) \approx L + J_q\,\delta q + J_v\,\delta v - M_a\,\delta a`.

.. _capi-host-coupling:

Coupling a host (CFD) solver
----------------------------

This section is for a host that moves a body with its own equations of motion, typically a CFD
solver with a rigid-body solver, and drives the deck's ``Coupled`` points as fairleads on that
body. It goes through the coupling step by step and compares each step with MoorDyn's C API
(``MoorDyn_Create``, ``MoorDyn_Init``, ``MoorDyn_Step``, ``MoorDyn_Serialize``), because a host
written for MoorDyn needs the differences below, not only renamed calls. The functions are
those of ABI 1.2: check ``CableDyn_GetAbiMinor() >= 2``.

The example is the floating box of foamMooring's ``EsfLOWC`` tutorial,
``tests/data/foam_esflowc_box_points.dat``: four slack ``EI = 0`` lines from ``Fixed`` anchors
1 to 4 to ``Coupled`` fairleads 5 to 8. The deck places the fairleads at
:math:`z = -0.062` m; the CFD box starts with them at :math:`z = -0.077` m.

Step 1: initialise at the host's positions
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

*MoorDyn.* ``MoorDyn_Create`` parses the input file; ``MoorDyn_Init(X, XD)`` then moves the
coupled points to the host's ``X`` and computes the initial condition there.

*CableDyn.* ``CableDyn_InitDeckAt(h, deck, deck_len, q0, n_q0, &err)`` does both in one call: it
parses the deck and solves the statics with every line-bound ``Coupled``/``Vessel`` point held at
its entry of ``q0``. ``CableDyn_InitDeck`` solves them at the deck coordinates instead, and a
host whose body starts elsewhere then gives the lines a start-up transient on its first steps.
For the box, the deck statics followed by fairleads held 15 mm lower move line 4's fairlead load
by up to 0.38 N, 74 % of its 0.52 N static value, and it is still 0.04 N off after 1 s
(:math:`\Delta t = 10^{-3}` s). After ``CableDyn_InitDeckAt`` the held fairleads keep their
load to round-off (:math:`2 \times 10^{-16}` N over the same second), and line 4's fairlead load
is the standalone value of the deck moved to the CFD positions, (0.3026, -0.0761, -0.4114) N
(MoorDyn: (0.3034, -0.0763, -0.4136) N).

``q0`` is one of two vectors; its length selects which:

* the ``Coupled``/``Vessel`` blocks alone, in coupled-vector order: 3 values per host point.
  This is the layout of MoorDyn's ``X`` for a deck whose coupled objects are points that are
  all attached to lines (MoorDyn's ``X`` also holds a ``Coupled`` point attached to no line,
  which has no block here), and the one a host that knows only its fairleads can build before
  any handle exists;
* the full coupled vector, ``CableDyn_NCoupledDOF`` values. Its ``Fixed``, ``Free`` and
  ``Connect`` blocks are not read.

The statics start at rest: there is no counterpart of MoorDyn's ``XD``. A host whose body is
already moving imposes the velocities on the coupled blocks with ``CableDyn_UpdateStates``
after the initialisation; the line interiors stay at rest.

Step 2: build the coupled vector from the layout
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

*MoorDyn.* The coupled vector holds the coupled objects and nothing else: 6 values per coupled
body or cantilevered rod, 3 per pinned rod or coupled point.

*CableDyn.* On the point route (decks of ``EI = 0`` lines) the vector has a block for every
line-bound point, ``Fixed`` anchors included, in ``POINTS`` order. On the aggregate route
(finite-EI lines, bodies or rods) only the host-driven points have blocks (`Coupled DOF
layout`_). Ask the handle rather than deriving the layout from the deck:

.. code-block:: c

   int n = CableDyn_NCoupledDOF(h, &err);                 /* 24 for the box */
   int ids[8], types[8];                                  /* n / 3 blocks */
   CableDyn_GetCoupledLayout(h, ids, types, n / 3, &err);

.. list-table:: Coupled vector of the box (point route)
   :header-rows: 1
   :widths: 14 18 18 50

   * - Block ``k``
     - DOFs
     - ``point_id[k]``
     - ``point_type[k]``
   * - 0 to 3
     - 0 to 11
     - 1 to 4
     - ``CD_C_POINT_FIXED``: the anchors
   * - 4 to 7
     - 12 to 23
     - 5 to 8
     - ``CD_C_POINT_COUPLED``: the fairleads, driven by the host

Seed ``q``, ``v`` and ``a`` once from ``CableDyn_GetCoupledMotion`` after the initialisation,
and before each step overwrite only the ``CD_C_POINT_COUPLED`` blocks. Every block is
prescribed on every step, so the anchor blocks must keep the values ``GetCoupledMotion``
returned: zeros there would move the anchors to the origin. ``CableDyn_CalcOutput`` returns a
load for every block, and the anchor blocks carry the anchor reactions, which are not loads on
the host.

Step 3: step with the motion at the end of the step
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

*MoorDyn.* ``MoorDyn_Step(X, XD, F, &t, &dt)`` takes the coupled state at the start of the
step, :math:`t`, extrapolates it over the step with ``XD``, and returns the forces at
:math:`t + \Delta t`.

*CableDyn.* ``CableDyn_Step(h, dt, q, v, a, ...)`` takes the prescribed position, velocity and
acceleration at the end of the step, :math:`t + \Delta t`, and ``CableDyn_CalcOutput`` then
returns the loads at :math:`t + \Delta t`. Pass the host's motion for the new time level (in a
CFD time step, the body's current iterate for it) with a consistent acceleration: the
integrator uses ``v`` and ``a``, not only ``q``. A host without body accelerations can use the
backward difference :math:`a = (v(t + \Delta t) - v(t)) / \Delta t`.

Step 4: outer correctors save and restore
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

A host that iterates its time step (PIMPLE outer correctors, predictor-corrector schemes)
advances the mooring once per pass and must rewind it between passes, or the mooring advances
by several steps per host step.

*MoorDyn.* The host serialises the system at the start of the time step
(``MoorDyn_Serialize``) and deserialises it before every repeated pass.

*CableDyn.* ``CableDyn_SaveState`` copies the whole model into the handle's single save slot
(every line, point, body and rod state with its solver history); ``CableDyn_RestoreState``
returns to it. A restore keeps the slot, so one save at the first pass of a time step serves
every later pass. A restore followed by a step is bit-identical to taking that step from the
saved state directly, and any number of steps may lie between the save and the restore (the
sub-steps of Step 6). A successful ``Init*`` call discards the save.

Key the save on the start time of the pass, :math:`t_{prev} = t - \Delta t`, not on its end
time :math:`t`. Save when a pass starts later than the saved state, which happens once the
previous step has been accepted and the model stands at :math:`t_{prev}`; restore before
every other pass, which starts from the same :math:`t_{prev}` whatever its :math:`\Delta t`.
A host that rejects a step and retries it with a smaller :math:`\Delta t` thus restores: keyed
on :math:`t`, the retry would look like a new step and save a model that the rejected pass has
already advanced. Compare the start times with a tolerance, as foamMooring's
``sixDoFMooringRestraints`` ``moorDynR2`` does (a new step when
:math:`t_{prev} - t_{saved} \ge 10^{-3}\,\Delta t`), since :math:`t - \Delta t` is subject to
round-off.

The names differ from MoorDyn's file calls: ``MoorDyn_SaveState`` writes the state to a file,
``CableDyn_SaveState`` keeps it in memory. Serialising the state to a caller buffer or a
restart file (``MoorDyn_Serialize``, ``MoorDyn_Save``/``MoorDyn_Load``) is not supported. A
restarted host re-initialises with ``CableDyn_InitDeckAt`` at its restart positions, which
gives the statics there rather than the dynamic state.

Step 5: sum the loads into a rigid-body force and moment
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

The sign convention is MoorDyn's: each block of ``coupled_loads`` is the force the lines exert
on that point, in newtons, in global axes (`State, units, and load sign`_). For a rigid body
with reference point :math:`r`, sum the ``CD_C_POINT_COUPLED`` blocks only:

.. math::

   F = \sum_k f_k, \qquad M_r = \sum_k (x_k - r) \times f_k

where :math:`x_k` is the fairlead position the step was taken with. The reference point
depends on the host's restraint: foamMooring's ``moorDynR2`` of ``rigidBodyMooringRestraints``
in point mode accumulates :math:`x_k \times f_k`, the moment about the global origin
(:math:`r = 0`), while its ``moorDynR2`` of ``sixDoFMooringRestraints`` accumulates
:math:`(x_k - x_{CoR}) \times f_k` about the body's centre of rotation
(:math:`r = x_{CoR}`). Do not add the anchor blocks.

Step 6: fixed step on the aggregate route
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

On the point route each ``CableDyn_Step`` takes any :math:`\Delta t > 0`. On the aggregate route
every step must use the deck's ``dtM``: a host step of :math:`m` times ``dtM`` is taken as
:math:`m` calls of ``CableDyn_Step``, with the host-driven motion interpolated linearly between
the start and the end of the host step. One ``CableDyn_SaveState`` before the first sub-step
and one ``CableDyn_RestoreState`` undo all of them. MoorDyn sub-steps internally with its own
``dtM``.

Step 7: units and frame
~~~~~~~~~~~~~~~~~~~~~~~

SI units in the global right-handed frame with z up and still water at :math:`z = 0`
(:doc:`conventions`), as in MoorDyn. A host in another frame or unit system converts the
motion it passes and the loads it receives.

Step 8: a host that turns: torsion and rigid end connections
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

The coupled vector carries translations only, which is all an ``EI = 0`` line or a pinned
finite-EI end takes. A finite-EI line restrained in torsion (``END CONNECTIONS``
``TorsStiffness``) twists with the body's roll about the line, and a ``Rigid`` bending end
connection holds the line's end tangent on a direction fixed to the body: both need the body's
rotation. ``CableDyn_InitDeck`` and ``CableDyn_InitDeckAt`` move the ends by translation only and
refuse a deck with a line restrained in torsion; a ``Rigid`` end connection there keeps its deck
direction.

*CableDyn.* Initialise with ``CableDyn_InitDeckRotating`` (``CableDyn_InitDeckAt`` that takes
rotations; ``n_q0 = 0`` for the deck positions) and, before every ``CableDyn_UpdateStates`` and
``CableDyn_Step``, pass the body's rotation at the same instant with
``CableDyn_UpdateRotations``: for each block of the coupled vector, the global-to-body
direction cosine matrix (row-major: its rows are the body axes in global axes, the OpenFAST
mesh orientation) and the body's angular velocity and acceleration in global axes. The body's
axes are the deck's at the static start, so the rotation starts at identity; a host whose body
starts rotated passes its rotation relative to that start. ``CableDyn_GetCoupledMoments`` then
returns the moment each line applies to the body about its fairlead, in global axes, beside the
force of ``CableDyn_CalcOutput``; add :math:`\sum_k m_k` to the moment of Step 5. *MoorDyn* has
no line torsion; its coupled bodies and rods take 6 values per object.

The rotations are inputs, like the motion: an end frame turned by more than a quarter turn
about its line since the last committed step is refused, and ``CableDyn_SaveState``/``CableDyn_RestoreState`` carry the
last rotations with the model.

Step 9: moving water
~~~~~~~~~~~~~~~~~~~~

A deck's steady current is marched as in the standalone driver: a ``current`` option, a WaterKin
``CurrentMod 1`` depth table or a MoorDyn-C ``Currents 1`` profile acts in the static start and in
every step, on lines between ``Fixed``, ``Coupled`` and ``Vessel`` points. Nothing else is needed.

A host that evaluates the water itself, such as a wave field not known in advance, supplies it at
the nodes:

.. code-block:: c

   CableDyn_SetHostFluid(h, 1, &err);                    /* before the initialization */
   CableDyn_InitDeckRotating(h, deck, len, q0, n_q0, &err);
   n = CableDyn_NFluidNodes(h, &err);

   CableDyn_GetFluidNodePositions(h, xyz, n, &err);      /* the field at t = 0 */
   CableDyn_UpdateFluidFields(h, vel, acc, eta, NULL, n, &err);
   for (;;) {                                            /* a step from t to t + dt */
       CableDyn_GetFluidNodePositions(h, xyz, n, &err);  /* the step-start positions */
       /* evaluate vel, acc, eta at xyz at time t + dt */
       CableDyn_UpdateFluidFields(h, vel, acc, eta, NULL, n, &err);
       CableDyn_Step(h, dt, q, v, a, n_dof, &converged, &stalled, &n_iter, &err);
   }

The convention is that of the standalone march and of the OpenFAST module:

* the field of a step from ``t`` to ``t + dt`` is sampled at ``t + dt`` at the step-start node
  positions, and it is held unchanged over the step;
* ``vel`` is the whole ambient velocity, current and waves together, ``acc`` the fluid
  acceleration, both as ``x, y, z`` triples in global axes, and ``eta`` the free-surface elevation
  above each node, which decides the wetting of its drag, added mass and buoyancy;
* the first call, before the first step, is the field at ``t = 0`` and sets the start acceleration;
  a step without any field is refused, because the march would otherwise run in still water;
* ``dynamic_pressure`` may be ``NULL``; rods use it for their end caps;
* the density is the deck's ``rhoW``;
* the nodes are every node of every line, then the deck's bodies, rods and hydrodynamic points.
  The field depends on position alone, so the host needs no node numbering;
* ``CableDyn_SaveState`` and ``CableDyn_RestoreState`` carry the held field.

With the host field, a deck runs on the coupled aggregate whatever its lines, needs ``dtM``, and
needs a seabed if it has ``EI = 0`` lines. Deck waves are refused. A steady deck current sets the
static start only, so the start is the equilibrium in that current, and the host's field is then
the whole water of the march; a deck current that varies in time is refused.

Seabed friction, ``staticsFriction asLaid`` and ``STIFFENERS`` work on this route.

With a host field the deck is read by the coupled rules, as in OpenFAST: it needs no ``TMax``, and a
``SEASTATE`` or ``WaveKinMod 2`` water policy takes the host's field. A deck current marched without
one follows the standalone rules and declares ``TMax``. Neither limits the host, which owns the clock
and may step past it.

Call sequence
~~~~~~~~~~~~~

The calls a restraint of a CFD rigid-body solver makes, with ``n_fair`` fairleads on one body
whose positions ``x_fair`` (``3 * n_fair`` values in coupled-vector order: on the point route
the deck's ``POINTS`` order of the ``Coupled`` points) the host computes from the body pose:

.. code-block:: c

   /* First call, the body at its initial pose. */
   CableDyn_Create(&h, &err);
   CableDyn_InitDeckAt(h, deck, (int)strlen(deck), x_fair, 3 * n_fair, &err);
   n = CableDyn_NCoupledDOF(h, &err);
   CableDyn_GetCoupledLayout(h, ids, types, n / 3, &err);  /* host blocks: CD_C_POINT_COUPLED */
   CableDyn_GetCoupledMotion(h, q, v, a, n, &err);         /* seed every block */
   t_saved = -HUGE_VAL;                                    /* nothing saved yet */

   /* Every call: a pass of the host time step from t_prev = t - dt to t. */
   if (t_prev - t_saved >= 1.0e-3 * dt) {   /* a new step: the model is at t_prev */
       CableDyn_SaveState(h, &err);
       t_saved = t_prev;
   } else {                                 /* a repeated pass from t_saved, any dt */
       CableDyn_RestoreState(h, &err);
   }
   /* the fairlead motion at t (the END of the step) into the host blocks, in layout order */
   for (j = 0, k = 0; k < n / 3; ++k) {
       if (types[k] != CD_C_POINT_COUPLED) continue;
       for (c = 0; c < 3; ++c) {
           q[3 * k + c] = x_fair[3 * j + c];
           v[3 * k + c] = v_fair[3 * j + c];
           a[3 * k + c] = a_fair[3 * j + c];
       }
       ++j;
   }
   /* a host that turns (CableDyn_InitDeckRotating): the body's rotation at t first */
   /* CableDyn_UpdateRotations(h, dcm, omega, alpha, n / 3, &err); */
   CableDyn_Step(h, dt, q, v, a, n, &converged, &stalled, &n_iter, &err);
   CableDyn_CalcOutput(h, f, n, &err);
   /* F = sum of f over the host blocks; M = sum of (x - r) x f over the same blocks */
   /* (+ the moments of CableDyn_GetCoupledMoments over the same blocks, Step 8) */

   /* End of the run. */
   CableDyn_Close(&h, &err);

Check ``err`` after every call. On the aggregate route, replace the single ``CableDyn_Step``
by the sub-steps of Step 6.

Function reference
------------------

Every table uses these columns:

* **Dir**: ``in``, ``out``, or ``inout``.
* **Length**: the element count read or written. A dash means a scalar.
* **NULL**: whether the pointer may be ``NULL``. A dash means a value argument.

Version queries
~~~~~~~~~~~~~~~

.. code-block:: c

   void CableDyn_GetVersion(int *major, int *minor, int *patch, int *abi_version);
   void CableDyn_GetVersionString(char *version, int version_len);

.. list-table::
   :header-rows: 1
   :widths: 18 8 10 10 12 42

   * - Argument
     - Dir
     - C type
     - Length
     - NULL
     - Meaning
   * - ``major``, ``minor``, ``patch``, ``abi_version``
     - out
     - ``int *``
     - 1 each
     - no (not checked)
     - library release and C ABI version
   * - ``version``
     - out
     - ``char *``
     - ``version_len``
     - yes: no-op
     - receives ``"CableDyn 0.4.2 C-ABI 1"``, truncated to ``version_len - 1`` characters and
       ``NUL``-terminated
   * - ``version_len``
     - in
     - ``int``
     - --
     - --
     - buffer capacity in bytes. A value below 1 makes the call a no-op.

Neither function needs a handle. There is no status argument.

``CableDyn_Create``
~~~~~~~~~~~~~~~~~~~

.. code-block:: c

   void CableDyn_Create(void **handle, int *err_stat);

.. list-table::
   :header-rows: 1
   :widths: 18 8 10 10 12 42

   * - Argument
     - Dir
     - C type
     - Length
     - NULL
     - Meaning
   * - ``handle``
     - out
     - ``void **``
     - 1
     - no (not checked)
     - receives a new, uninitialised handle, or ``NULL`` on failure
   * - ``err_stat``
     - out
     - ``int *``
     - 1
     - no (not checked)
     - ``CD_C_OK`` or ``CD_C_ALLOC_FAIL``

The handle stays uninitialised until an ``Init*`` call succeeds.

``CableDyn_Close``
~~~~~~~~~~~~~~~~~~

.. code-block:: c

   void CableDyn_Close(void **handle, int *err_stat);

.. list-table::
   :header-rows: 1
   :widths: 18 8 10 10 12 42

   * - Argument
     - Dir
     - C type
     - Length
     - NULL
     - Meaning
   * - ``handle``
     - inout
     - ``void **``
     - 1
     - pointer: no (not checked). ``*handle``: yes
     - handle to release. Set to ``NULL`` on success.
   * - ``err_stat``
     - out
     - ``int *``
     - 1
     - no (not checked)
     - ``CD_C_OK``, or ``CD_C_BAD_HANDLE`` for a closed or foreign pointer

``*handle == NULL`` is a no-op that returns ``CD_C_OK``. A pointer that is not a live handle is
left untouched: it is not freed, it is not set to ``NULL``, and ``CD_C_BAD_HANDLE`` is
returned. If two threads close the same handle, or copies of it, exactly one of them frees it.
That thread gets ``CD_C_OK`` and the others get ``CD_C_BAD_HANDLE``.

``CableDyn_InitDeck``
~~~~~~~~~~~~~~~~~~~~~

.. code-block:: c

   void CableDyn_InitDeck(void *handle, const char *deck_path, int deck_path_len, int *err_stat);

.. list-table::
   :header-rows: 1
   :widths: 18 8 10 10 12 42

   * - Argument
     - Dir
     - C type
     - Length
     - NULL
     - Meaning
   * - ``handle``
     - in
     - ``void *``
     - --
     - no: ``CD_C_BAD_HANDLE``
     - handle from ``CableDyn_Create``
   * - ``deck_path``
     - in
     - ``const char *``
     - ``deck_path_len``
     - no: ``CD_C_BAD_INPUT``
     - path of a ``.dat`` deck (:doc:`driver_format`). It need not be ``NUL``-terminated.
   * - ``deck_path_len``
     - in
     - ``int``
     - --
     - --
     - number of bytes to read. It must be at least 1, and the first byte must not be ``NUL``.
   * - ``err_stat``
     - out
     - ``int *``
     - 1
     - no (not checked)
     - status

The call parses and validates the deck and chooses one of two routes. A deck of ``EI = 0`` lines
without ``BODIES`` or ``RODS`` runs on the **point route**: the call builds every line as an
``EI = 0`` model, solves each line's static equilibrium with its end points at their deck
coordinates, and connects the lines through the deck points. A deck with finite-EI lines,
``BODIES`` or ``RODS`` runs on the **aggregate route** described next. On both routes gravity,
water density, seabed, currents, line hydrodynamic coefficients, ``rhoInf``, and the dynamic
Newton settings are taken from the deck. The deck's ``OUTPUTS`` section is parsed and validated,
but the C ABI writes no output files.

**Finite-EI lines, bodies and rods.** A deck with finite-EI (``EI > 0``) lines or with a
``BODIES`` or ``RODS`` table (``Point3`` buoys, free ``Rigid6`` bodies, or free, fixed and
``Pinned`` rods, with their lines; a ``Pinned`` rod turns about its fixed End A) runs on the same
coupled aggregate as the OpenFAST module, with these differences from the point-system decks:

* the coupled DOFs are the ``x, y, z`` of the deck's ``Coupled``/``Vessel`` points only, in
  the order of `Coupled DOF layout`_ (anchors are not part of the vector); the bodies and
  rods are integrated internally;
* the deck must declare ``dtM``, and every ``CableDyn_Step`` must use that ``dt``;
* a deck current is marched on lines between ``Fixed``, ``Coupled`` and ``Vessel`` points,
  deck waves are rejected, and other moving water comes from the host (`Step 9: moving
  water`_);
* ``CableDyn_UpdatePointFluidFields`` and ``CableDyn_CalcOutputDerivatives`` return
  ``CD_C_BAD_INPUT``;
* ``CableDyn_NPoints`` and ``CableDyn_NLines`` report the deck's point and line counts.

The deck is validated under the standalone-deck rules:

* ``dtM`` and ``TMax`` must both be present or both be absent.
* A deck with ``Free`` or ``Connect`` points must declare ``dtM``, and therefore ``TMax``.
* On the point route the time-step values themselves are not used: the step size is the ``dt``
  passed to each ``CableDyn_Step``. On the aggregate route ``dtM`` is required and is the fixed
  step of every ``CableDyn_Step``.

``CableDyn_InitDeck`` rejects the following with ``CD_C_BAD_INPUT``:

.. list-table::
   :header-rows: 1
   :widths: 44 56

   * - Deck content
     - Where it is supported
   * - ``Coupled``/``Vessel`` bodies or rods (6-DOF host nodes)
     - the OpenFAST module; the standalone driver with a ``motionFile``
   * - ``CoupledPinned``/``VesselPinned`` rods or bodies (a pin the host moves)
     - the OpenFAST module
   * - a ``motionFile`` option
     - the standalone driver (prescribe motion through ``CableDyn_Step`` instead)
   * - a ``FAILURE`` section (line failures)
     - the standalone driver; the OpenFAST module
   * - the ``LINES`` ``Outputs`` flag ``r`` (range graph)
     - the standalone driver; the OpenFAST module in a single-turbine run
   * - a ``CONTROL`` section (active line control)
     - the OpenFAST module
   * - ``WaveKinMod 2`` / ``SEASTATE`` wave kinematics
     - the OpenFAST module; a host that calls ``CableDyn_SetHostFluid``
   * - a ``waves`` option (regular or JONSWAP deck waves)
     - the standalone driver; supply time-varying fluid kinematics through
       ``CableDyn_UpdateFluidFields`` (`Step 9: moving water`_), or at the points of a point
       deck through ``CableDyn_UpdatePointFluidFields``
   * - a MoorDyn-C ``Currents 2``/``5`` table that varies in time
     - the standalone driver; supply time-varying fluid kinematics through
       ``CableDyn_UpdateFluidFields`` (`Step 9: moving water`_), or at the points of a point
       deck through ``CableDyn_UpdatePointFluidFields``
   * - FAST.Farm ``Turbine<J>`` points
     - the OpenFAST module in FAST.Farm
   * - ``frictionMu`` in a deck that has ``Free`` or ``Connect`` points
     - the point-system solver does not combine seabed friction with ``Free`` or ``Connect``
       points. Friction is available in decks without them.

.. important::

   The C ABI has no simulation clock and no per-node fluid input. A deck's current is applied
   as a steady field. A deck with a ``waves`` option, or a MoorDyn-C ``Currents 2``/``5`` table
   that varies in time, is rejected with ``CD_C_BAD_INPUT``, because it could not be evaluated
   in time; such a table constant in time is applied as the steady field. On a deck of
   ``EI = 0`` lines the field is sampled at every node of the static state and again at the
   step-start nodes before every ``CableDyn_Step``, as the standalone driver samples it, so a
   depth profile or grid follows the line. Time-varying fluid kinematics reach the ``Free``
   and ``Connect`` points through ``CableDyn_UpdatePointFluidFields``.

Parse and validation failures, including a file that cannot be opened, return
``CD_C_BAD_INPUT``. A static-solve or system-assembly failure returns ``CD_C_SOLVE_FAIL``. See
`Coupled DOF layout`_ for the resulting vectors.

``CableDyn_InitLine``
~~~~~~~~~~~~~~~~~~~~~

.. code-block:: c

   void CableDyn_InitLine(void *handle, int n_nodes, int n_elem, const double *q0,
                          const double *v0, const int *elem_conn, const double *l0,
                          const double *ea, const double *rho_a,
                          const int *fixed_dofs, int n_fixed, int tension_only,
                          double rho_inf, int *err_stat);

Builds one line from caller-meshed arrays. The model is **structural only**: two-node EI = 0
axial elements with a consistent mass matrix. It has no gravity or buoyancy (the external load
is zero), no seabed, no hydrodynamics, and no structural damping. There is no static solve. The
state starts at ``q0``, ``v0`` exactly, and the initial acceleration is computed from that
state. To get gravity, seabed, and hydrodynamics, use ``CableDyn_InitDeck``.

.. list-table::
   :header-rows: 1
   :widths: 14 7 13 14 11 41

   * - Argument
     - Dir
     - C type
     - Length
     - NULL
     - Meaning
   * - ``handle``
     - in
     - ``void *``
     - --
     - no: ``CD_C_BAD_HANDLE``
     - handle from ``CableDyn_Create``
   * - ``n_nodes``
     - in
     - ``int``
     - --
     - --
     - node count, at least 2
   * - ``n_elem``
     - in
     - ``int``
     - --
     - --
     - element count, at least 1
   * - ``q0``
     - in
     - ``const double *``
     - ``3*n_nodes``
     - no
     - initial nodal positions [m], global, interleaved ``x, y, z``
   * - ``v0``
     - in
     - ``const double *``
     - ``3*n_nodes``
     - no
     - initial nodal velocities [m/s]
   * - ``elem_conn``
     - in
     - ``const int *``
     - ``2*n_elem``
     - no
     - 1-based node pair of each element, ``(a1, b1, a2, b2, ...)``, each index in
       ``[1, n_nodes]``
   * - ``l0``
     - in
     - ``const double *``
     - ``n_elem``
     - no
     - unstretched element length [m], greater than 0
   * - ``ea``
     - in
     - ``const double *``
     - ``n_elem``
     - no
     - axial stiffness EA [N], greater than 0
   * - ``rho_a``
     - in
     - ``const double *``
     - ``n_elem``
     - no
     - mass per unit unstretched length [kg/m], greater than 0
   * - ``fixed_dofs``
     - in
     - ``const int *``
     - ``n_fixed``
     - only if ``n_fixed == 0``
     - 1-based DOF indices in ``[1, 3*n_nodes]`` that the caller prescribes. No duplicates are
       allowed. Their order defines the coupled vector.
   * - ``n_fixed``
     - in
     - ``int``
     - --
     - --
     - number of prescribed DOFs, at least 0. This becomes ``CableDyn_NCoupledDOF``.
   * - ``tension_only``
     - in
     - ``int``
     - --
     - --
     - nonzero: an element carries no compression (it goes slack). Zero: the element is linear
       in tension and compression.
   * - ``rho_inf``
     - in
     - ``double``
     - --
     - --
     - generalised-α high-frequency spectral radius, in ``[0, 1]`` (``0.8`` is a typical
       choice)
   * - ``err_stat``
     - out
     - ``int *``
     - 1
     - no (not checked)
     - status

Invalid counts, ``NULL`` arrays, non-finite values, non-positive ``l0``, ``ea``, or ``rho_a``,
out-of-range connectivity, out-of-range or duplicate ``fixed_dofs``, and a ``rho_inf`` outside
``[0, 1]`` (including NaN) all return ``CD_C_BAD_INPUT``. A failure of the initial acceleration
solve returns ``CD_C_SOLVE_FAIL``.

The Newton settings are fixed at their
defaults: relative residual tolerance :math:`10^{-8}`, at most 30 iterations per step, and at
most 12 line-search backtracks. So is the generalised-α scheme: these lines always take the
force-blended step (``alpha_force_blend`` ``True``, with the release cap on a tension-only line,
:doc:`theory`), with the rotation- and snap-resolved sub-steps of ``ei0_substeps auto`` at
their default settings (:doc:`options`). They cannot select the configuration blend of 0.1.1
and earlier (``False alpha_force_blend``) or ``off ei0_substeps``, which only a deck sets,
through ``CableDyn_InitDeck``.

``CableDyn_InitLines``
~~~~~~~~~~~~~~~~~~~~~~

.. code-block:: c

   void CableDyn_InitLines(void *handle, int n_lines, const int *n_nodes,
                           const int *n_elem, const int *n_fixed, const double *q0,
                           const double *v0, const int *elem_conn,
                           const double *l0, const double *ea,
                           const double *rho_a, const int *fixed_dofs,
                           const int *coupled_map, int n_coupled_map,
                           int tension_only, double rho_inf, int *err_stat);

Builds several structural-only lines, with the same model as ``CableDyn_InitLine``, in one
system. Every per-line array is the concatenation, in line order, of that line's
``CableDyn_InitLine`` array. Connectivity and ``fixed_dofs`` stay **local** to each line: node
1 is the first node of that line. ``tension_only`` and ``rho_inf`` apply to every line.

In the table below, :math:`N = \sum n\_nodes`, :math:`E = \sum n\_elem`, and
:math:`F = \sum n\_fixed`.

.. list-table::
   :header-rows: 1
   :widths: 14 7 13 13 12 41

   * - Argument
     - Dir
     - C type
     - Length
     - NULL
     - Meaning
   * - ``handle``
     - in
     - ``void *``
     - --
     - no: ``CD_C_BAD_HANDLE``
     - handle from ``CableDyn_Create``
   * - ``n_lines``
     - in
     - ``int``
     - --
     - --
     - line count, at least 1
   * - ``n_nodes``, ``n_elem``, ``n_fixed``
     - in
     - ``const int *``
     - ``n_lines`` each
     - no
     - per-line counts: at least 2, at least 1, and at least 0
   * - ``q0``, ``v0``
     - in
     - ``const double *``
     - ``3N`` each
     - no
     - initial positions [m] and velocities [m/s]
   * - ``elem_conn``
     - in
     - ``const int *``
     - ``2E``
     - no
     - line-local 1-based node pairs
   * - ``l0``, ``ea``, ``rho_a``
     - in
     - ``const double *``
     - ``E`` each
     - no
     - unstretched length [m], EA [N], mass per unit length [kg/m]
   * - ``fixed_dofs``
     - in
     - ``const int *``
     - ``F``
     - only if ``F == 0``
     - line-local 1-based prescribed DOFs
   * - ``coupled_map``
     - in
     - ``const int *``
     - ``n_coupled_map``
     - only if ``n_coupled_map == 0``
     - optional map from line fixed DOFs to shared system DOFs (below)
   * - ``n_coupled_map``
     - in
     - ``int``
     - --
     - --
     - either 0 (no map) or exactly ``6*n_lines``
   * - ``tension_only``, ``rho_inf``
     - in
     - ``int``, ``double``
     - --
     - --
     - as in ``CableDyn_InitLine``
   * - ``err_stat``
     - out
     - ``int *``
     - 1
     - no (not checked)
     - status

**The coupled map.** Supply a map to connect lines at shared points. The map has these
requirements:

* Every line must have exactly six fixed DOFs (``n_fixed[i] == 6``), normally the
  ``x, y, z`` of its two end nodes.
* The map holds six entries per line. Entry ``6*i + j`` (0-based) is the 1-based system DOF that
  receives line ``i``'s ``j``-th fixed DOF, in that line's ``fixed_dofs`` order.
* Entries must be positive and must use every index from 1 to their maximum with no gaps. That
  maximum becomes ``CableDyn_NCoupledDOF``.
* The map is checked per DOF only. Keep shared DOFs grouped as whole ``x, y, z`` triples so that
  a shared point stays one point.

Lines that share a DOF should start with the same coordinate there. ``CableDyn_GetCoupledMotion``
rejects shared DOFs whose line states differ by more than :math:`10^{-10}` in ``q``, ``v``, or
``a`` until the first ``Step`` or ``UpdateStates`` makes them equal.

Without a map, lines are independent, and their fixed DOFs are concatenated into the coupled
vector.

Raw-array handles have no deck points: ``CableDyn_NPoints`` is 0, and every coupled DOF is
prescribed by the caller.

``CableDyn_UpdateStates``
~~~~~~~~~~~~~~~~~~~~~~~~~

.. code-block:: c

   void CableDyn_UpdateStates(void *handle, const double *q_coupled, const double *v_coupled,
                              const double *a_coupled, int n_coupled_dof, int *err_stat);

.. list-table::
   :header-rows: 1
   :widths: 18 8 12 12 12 38

   * - Argument
     - Dir
     - C type
     - Length
     - NULL
     - Meaning
   * - ``handle``
     - in
     - ``void *``
     - --
     - no: ``CD_C_BAD_HANDLE``
     - initialised handle
   * - ``q_coupled``, ``v_coupled``, ``a_coupled``
     - in
     - ``const double *``
     - ``n_coupled_dof`` each
     - only if ``n_coupled_dof == 0``
     - coupled positions [m], velocities [m/s], and accelerations [m/s²]
   * - ``n_coupled_dof``
     - in
     - ``int``
     - --
     - --
     - must equal ``CableDyn_NCoupledDOF``
   * - ``err_stat``
     - out
     - ``int *``
     - 1
     - no (not checked)
     - status

Sets the coupled DOFs of every line to the supplied motion without advancing time. Interior node
positions and velocities are kept. Interior accelerations are recomputed from the equations of
motion at the new boundary state, so ``CableDyn_CalcOutput`` afterwards returns the loads for
that state. Use this call for a predictor–corrector host, or to evaluate loads at a trial
motion. Every block is written, including ``Free`` and ``Connect`` point blocks of a deck model.

The call is atomic. A non-finite value returns ``CD_C_BAD_INPUT``, and any failure leaves the
model unchanged.

``CableDyn_UpdatePointFluidFields``
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

.. code-block:: c

   void CableDyn_UpdatePointFluidFields(void *handle, const double *fluid_velocity,
                                        const double *fluid_acceleration,
                                        const double *waterline_z, int n_point,
                                        double fluid_density, int *err_stat);

.. list-table::
   :header-rows: 1
   :widths: 18 8 12 12 12 38

   * - Argument
     - Dir
     - C type
     - Length
     - NULL
     - Meaning
   * - ``handle``
     - in
     - ``void *``
     - --
     - no: ``CD_C_BAD_HANDLE``
     - handle initialised by ``CableDyn_InitDeck``
   * - ``fluid_velocity``
     - in
     - ``const double *``
     - ``3*n_point``
     - only if ``n_point == 0``
     - ambient fluid velocity at each point [m/s], global, interleaved ``x, y, z``
   * - ``fluid_acceleration``
     - in
     - ``const double *``
     - ``3*n_point``
     - only if ``n_point == 0``
     - ambient fluid acceleration at each point [m/s²]
   * - ``waterline_z``
     - in
     - ``const double *``
     - ``n_point``
     - only if ``n_point == 0``
     - global z of the free surface above each point [m]. A point is wetted when its z is at or
       below this value.
   * - ``n_point``
     - in
     - ``int``
     - --
     - --
     - must equal ``CableDyn_NPoints``. Point ``p`` is the ``p``-th row of the deck's
       ``POINTS`` table, including points not attached to any line.
   * - ``fluid_density``
     - in
     - ``double``
     - --
     - --
     - fluid density [kg/m³], finite and at least 0. A value of 0 disables point hydrodynamics.
   * - ``err_stat``
     - out
     - ``int *``
     - 1
     - no (not checked)
     - status

Stores the fields used by the lumped hydrodynamic load on deck ``Free`` and ``Connect`` points,
which is built from their ``CdA``, ``Ca``, and ``Vol`` columns:

.. math::

   F = \tfrac12\,\rho\,C_dA\,|u-\dot{x}|\,(u-\dot{x}) + \rho\,V\,(1+C_a)\,\dot{u},
   \qquad m_{\text{eff}} = m + \rho\,V\,C_a

The load applies while the point is wetted. Fields for points of other types are stored but
unused. The values persist until the next call. Before the first call the density is 0, so no
point hydrodynamic load is applied. The constant net weight
:math:`(\rho_w V - m)\,g`, taken from the deck's ``rhoW`` and ``g``, is always applied,
independently of this call.

A handle initialised from raw arrays has no deck points, so on such a handle the call always
returns ``CD_C_BAD_INPUT`` (a non-zero ``n_point`` fails the count check, and ``n_point = 0``
fails because the model has no point system). The call is atomic: every input is validated before
any value
is stored. A non-finite field returns ``CD_C_BAD_INPUT``.

``CableDyn_Step``
~~~~~~~~~~~~~~~~~

.. code-block:: c

   void CableDyn_Step(void *handle, double dt, const double *q_coupled,
                      const double *v_coupled, const double *a_coupled,
                      int n_coupled_dof, bool *converged, bool *stalled,
                      int *n_iter, int *err_stat);

.. list-table::
   :header-rows: 1
   :widths: 18 8 12 12 12 38

   * - Argument
     - Dir
     - C type
     - Length
     - NULL
     - Meaning
   * - ``handle``
     - in
     - ``void *``
     - --
     - no: ``CD_C_BAD_HANDLE``
     - initialised handle
   * - ``dt``
     - in
     - ``double``
     - --
     - --
     - step size [s], finite and at least ``1e-100`` (the time integration divides by
       ``dt**2``; a smaller step is ``CD_C_BAD_INPUT``)
   * - ``q_coupled``, ``v_coupled``, ``a_coupled``
     - in
     - ``const double *``
     - ``n_coupled_dof`` each
     - only if ``n_coupled_dof == 0``
     - prescribed coupled motion at the **end** of the step, :math:`t+\Delta t`
   * - ``n_coupled_dof``
     - in
     - ``int``
     - --
     - --
     - must equal ``CableDyn_NCoupledDOF``
   * - ``converged``
     - out
     - ``bool *``
     - 1
     - no (not checked)
     - true if every line met the Newton tolerance over the full step
   * - ``stalled``
     - out
     - ``bool *``
     - 1
     - no (not checked)
     - true if a line's line search stalled (backtracking exhausted)
   * - ``n_iter``
     - out
     - ``int *``
     - 1
     - no (not checked)
     - largest Newton iteration count over the lines
   * - ``err_stat``
     - out
     - ``int *``
     - 1
     - no (not checked)
     - status

``converged``, ``stalled``, and ``n_iter`` are always written. They are cleared on entry, even
when the call is rejected. The step advances every line over :math:`[t, t+\Delta t]` with the
Chung–Hulbert generalised-α method. The prescribed DOFs are held at the supplied end-of-step
``q``, ``v``, and ``a``. Pass a consistent ``v`` and ``a``: the integrator uses them, not only
``q``.

.. _capi-step-outcomes:

**Step outcomes.**

.. list-table::
   :header-rows: 1
   :widths: 26 20 54

   * - Outcome
     - Returned
     - Committed state
   * - converged
     - ``CD_C_OK``, ``converged = true``
     - the solution at :math:`t+\Delta t`
   * - soft non-convergence: the Newton iteration limit was reached, or the line search stalled
     - ``CD_C_OK``, ``converged = false``, ``stalled`` as observed
     - the best iterate at :math:`t+\Delta t`, with the prescribed DOFs at their supplied
       values. The model **has advanced**; do not repeat the step.
   * - hard failure, for example a singular tangent or an assembly or constitutive failure
     - ``CD_C_SOLVE_FAIL`` (or ``CD_C_ALLOC_FAIL``), ``converged = stalled = false``,
       ``n_iter = 0``
     - rolled back to the state at :math:`t`, including any viscoelastic or Syrope history and
       deck point states; on the aggregate route the whole model returns to the step start,
       bodies and rods included. The step can be retried, for example with a smaller ``dt``.
   * - rejected input: a size mismatch, a ``NULL`` array, a non-finite motion, or a
       ``dt <= 0``
     - ``CD_C_BAD_INPUT``
     - no step is taken

Before it reports a soft non-convergence, the step retries internally. It rolls back to
:math:`t` and re-solves the interval as two half steps. The prescribed motion at the midpoint
is the linear interpolation of the motion at the start and end of the step. A half step that
also fails to converge is split again, down to :math:`\Delta t/64`.

* If the subdivided solution covers the whole interval with convergence, that solution is
  committed, and ``converged = true``.
* Otherwise the model is restored to :math:`t` and the single full-``dt`` step is taken again.
  Its best iterate and flags are returned, so a partial subdivided state is never committed.

The retry costs time only on steps that would otherwise fail to converge.

**Deck models with Free or Connect points.** These points are integrated by CableDyn, not
prescribed. Each step:

#. Advances the points from the summed end loads of the attached lines, the constant net
   weight, and any point hydrodynamic load.
#. Solves the lines implicitly with the new point positions as end conditions.

The point update treats the attached line ends' own mass (structural and added), end-segment
stiffness, and axial damping linearly implicitly, so a massless ``Connect`` junction stays
stable and the end segments set no explicit ``dt`` limit. ``dt`` still has to resolve the
response of interest. A step whose point motion becomes non-finite fails with an error that
names the point. The host's
entries for ``Free`` and ``Connect`` blocks are not used as prescribed motion. Pass the values
last returned by ``CableDyn_GetCoupledMotion`` for those blocks. After the step, read them back
to obtain the integrated point motion.

``CableDyn_CalcOutput``
~~~~~~~~~~~~~~~~~~~~~~~

.. code-block:: c

   void CableDyn_CalcOutput(void *handle, double *coupled_loads, int n_coupled_dof, int *err_stat);

.. list-table::
   :header-rows: 1
   :widths: 18 8 12 12 12 38

   * - Argument
     - Dir
     - C type
     - Length
     - NULL
     - Meaning
   * - ``handle``
     - in
     - ``void *``
     - --
     - no: ``CD_C_BAD_HANDLE``
     - initialised handle
   * - ``coupled_loads``
     - out
     - ``double *``
     - ``n_coupled_dof``
     - only if ``n_coupled_dof == 0``
     - loads by the cables on the host [N], global axes
   * - ``n_coupled_dof``
     - in
     - ``int``
     - --
     - --
     - must equal ``CableDyn_NCoupledDOF``
   * - ``err_stat``
     - out
     - ``int *``
     - 1
     - no (not checked)
     - status

Evaluates the loads from the current state:

* after ``Init*``, the initial or static state,
* after ``CableDyn_Step``, the committed state at :math:`t+\Delta t`,
* after ``CableDyn_UpdateStates``, the updated state.

The model state is not changed. Once the size and pointer checks pass, the buffer is set to zero
before evaluation, so a failed evaluation leaves it all zero.

``CableDyn_CalcOutputDerivatives``
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

.. code-block:: c

   void CableDyn_CalcOutputDerivatives(void *handle, const double *q_coupled,
                                       const double *v_coupled, const double *a_coupled,
                                       int n_coupled_dof, double eps_fd,
                                       double *coupled_loads, double *dload_dq,
                                       double *dload_dv, double *dload_da,
                                       double *added_mass, int *err_stat);

.. list-table::
   :header-rows: 1
   :widths: 18 8 12 12 12 38

   * - Argument
     - Dir
     - C type
     - Length
     - NULL
     - Meaning
   * - ``handle``
     - in
     - ``void *``
     - --
     - no: ``CD_C_BAD_HANDLE``
     - initialised handle
   * - ``q_coupled``, ``v_coupled``, ``a_coupled``
     - in
     - ``const double *``
     - ``n`` each
     - only if ``n == 0``
     - the operating point: coupled positions, velocities, and accelerations
   * - ``n_coupled_dof``
     - in
     - ``int``
     - --
     - --
     - ``n``, which must equal ``CableDyn_NCoupledDOF``
   * - ``eps_fd``
     - in
     - ``double``
     - --
     - --
     - kept for ABI compatibility. It must be at least 0 (``NaN`` is rejected) and is
       otherwise unused.
   * - ``coupled_loads``
     - out
     - ``double *``
     - ``n``
     - only if ``n == 0``
     - loads at the operating point [N]
   * - ``dload_dq``
     - out
     - ``double *``
     - ``n*n``
     - only if ``n == 0``
     - :math:`\partial L/\partial q` [N/m], column-major
   * - ``dload_dv``
     - out
     - ``double *``
     - ``n*n``
     - only if ``n == 0``
     - :math:`\partial L/\partial v` [N·s/m], column-major
   * - ``dload_da``
     - out
     - ``double *``
     - ``n*n``
     - only if ``n == 0``
     - :math:`\partial L/\partial a` [kg], column-major
   * - ``added_mass``
     - out
     - ``double *``
     - ``n*n``
     - only if ``n == 0``
     - :math:`M_a = -\partial L/\partial a` [kg], column-major
   * - ``err_stat``
     - out
     - ``int *``
     - 1
     - no (not checked)
     - status

The derivative blocks are **analytic**, not finite differences. They are assembled from the exact
element, contact, and hydrodynamic tangents of each line and summed through the coupled layout.
Each line's interior DOFs are condensed out at the operating point: interior positions and
velocities are held, and interior accelerations are eliminated through the consistent mass
matrix, including added mass. The blocks therefore give the instantaneous response of the end
loads to the end motion, the linearisation a tightly coupled host needs. The acceleration block
is :math:`-(M_{cc} - M_{cf} M_{ff}^{-1} M_{fc})`. Every coupled DOF is differentiated as a
prescribed DOF, including ``Free`` and ``Connect`` blocks.

.. warning::

   This call **sets** the model state; it is not a pure query. On return, the model is at the
   supplied operating point: the coupled DOFs hold the supplied ``q``, ``v``, and ``a``, and the
   interior accelerations are recomputed, as after ``CableDyn_UpdateStates``. This holds on
   success, and also when a later stage of the call fails. The previous state is not restored.
   A host that needs its previous state back must call ``CableDyn_UpdateStates`` with it
   afterwards.

   Rejected arguments leave the model unchanged: a bad size, a ``NULL`` array, ``eps_fd < 0``,
   or an operating point that ``UpdateStates`` rejects. If ``n*n`` exceeds the ``int`` range,
   the call returns ``CD_C_BAD_INPUT``.

After the pointer checks pass, all five output buffers are set to zero, so a failed call leaves
them all zero.

``CableDyn_GetCoupledMotion``
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

.. code-block:: c

   void CableDyn_GetCoupledMotion(void *handle, double *q_coupled, double *v_coupled,
                                  double *a_coupled, int n_coupled_dof, int *err_stat);

.. list-table::
   :header-rows: 1
   :widths: 18 8 12 12 12 38

   * - Argument
     - Dir
     - C type
     - Length
     - NULL
     - Meaning
   * - ``handle``
     - in
     - ``void *``
     - --
     - no: ``CD_C_BAD_HANDLE``
     - initialised handle
   * - ``q_coupled``, ``v_coupled``, ``a_coupled``
     - out
     - ``double *``
     - ``n_coupled_dof`` each
     - only if ``n_coupled_dof == 0``
     - current coupled positions [m], velocities [m/s], and accelerations [m/s²]
   * - ``n_coupled_dof``
     - in
     - ``int``
     - --
     - --
     - must equal ``CableDyn_NCoupledDOF``
   * - ``err_stat``
     - out
     - ``int *``
     - 1
     - no (not checked)
     - status

Copies the current coupled motion. Right after ``CableDyn_InitDeck`` this is the static
solution: the deck coordinates of every attached point, with zero velocity and acceleration.
After ``CableDyn_InitDeckAt`` the host-driven blocks hold their entries of ``q0`` instead.
Use it to seed the host's coupled vectors before the first step. The buffers are set to zero
before the copy and stay zero if the call fails. The model is not changed.

``CableDyn_GetInitNotes``
~~~~~~~~~~~~~~~~~~~~~~~~~

.. code-block:: c

   int CableDyn_GetInitNotes(void *handle, char *notes, int notes_len);

ABI 1 minor extension 4. Copies the notes of the last deck initialisation on the handle, on the
point route and the aggregate alike: the ``Note:`` lines a driver run of the deck prints at its
start, without the prefix, one per line, each ended by a new line. The library prints no more or
less than before; the text is for a host that does not read its standard streams. The notes of
the march are not among them, and a raw-line initialisation has none.

The buffer follows ``CableDyn_GetLastError``: it is always ``NUL``-terminated when ``notes_len``
is positive and ``notes`` is not ``NULL``, and the text is truncated to ``notes_len - 1``
characters. The return value is the length of the whole text without the terminator, so a ``NULL``
buffer asks for the size. It is 0 without notes and -1 on a bad handle.

The notes belong to the last attempt: a failed initialisation replaces them, although the handle
keeps its previous model. They take what is known at initialisation. With
``CableDyn_SetHostFluid`` the deck's steady current sets the static start and counts; a field the
host applies afterwards does not.

.. code-block:: c

   int size = CableDyn_GetInitNotes(h, NULL, 0);
   char *notes = malloc((size_t)size + 1);
   CableDyn_GetInitNotes(h, notes, size + 1);

``CableDyn_GetLastError``
~~~~~~~~~~~~~~~~~~~~~~~~~

.. code-block:: c

   void CableDyn_GetLastError(void *handle, char *message, int message_len);

.. list-table::
   :header-rows: 1
   :widths: 18 8 12 12 12 38

   * - Argument
     - Dir
     - C type
     - Length
     - NULL
     - Meaning
   * - ``handle``
     - in
     - ``void *``
     - --
     - yes
     - the handle to query. For an invalid handle the text is ``"CableDyn C API: bad handle"``.
   * - ``message``
     - out
     - ``char *``
     - ``message_len``
     - yes: no-op
     - receives the message, truncated to ``message_len - 1`` characters and
       ``NUL``-terminated. An empty string means no failure has been recorded since the last
       success.
   * - ``message_len``
     - in
     - ``int``
     - --
     - --
     - buffer capacity in bytes. A value below 1 makes the call a no-op. A message is at most
       4096 characters, so a buffer of 4097 bytes always holds the full message and its
       terminating ``NUL``.

State and size queries
~~~~~~~~~~~~~~~~~~~~~~

.. code-block:: c

   bool CableDyn_IsInitialized(void *handle);
   int  CableDyn_NCoupledDOF(void *handle, int *err_stat);
   int  CableDyn_NPoints(void *handle, int *err_stat);
   int  CableDyn_NLines(void *handle, int *err_stat);

.. list-table::
   :header-rows: 1
   :widths: 26 74

   * - Function
     - Returns
   * - ``CableDyn_IsInitialized``
     - ``true`` if the handle holds a model. It returns ``false`` for an uninitialised handle and
       for a ``NULL``, closed, or foreign pointer, and has no status argument.
   * - ``CableDyn_NCoupledDOF``
     - length of the coupled vectors (`Coupled DOF layout`_)
   * - ``CableDyn_NPoints``
     - number of deck points, the ``n_point`` that ``CableDyn_UpdatePointFluidFields`` expects.
       This count includes points attached to no line, so it can exceed
       ``CableDyn_NCoupledDOF / 3``. It is 0 for a handle initialised from raw arrays.
   * - ``CableDyn_NLines``
     - number of lines in the model

The three counting queries return 0 whenever ``*err_stat`` is not ``CD_C_OK``:
``CD_C_BAD_HANDLE`` for an invalid pointer, ``CD_C_NOT_INITIALIZED`` before a successful
``Init*``. ``err_stat`` must be valid storage.

Object queries
~~~~~~~~~~~~~~

ABI 1 minor extension 1. These read the committed state of an initialised handle at any step:
the objects of the model and any output channel, through the evaluator behind the deck
``OUTPUTS`` channels and the per-line ``.Line<L>.p.out``/``.t.out`` files, so a query returns the
value the standalone driver writes for the same state.

.. code-block:: c

   int  CableDyn_GetAbiMinor(void);
   int  CableDyn_NObjects(void *handle, int kind, int *err_stat);
   void CableDyn_GetObjectInfo(void *handle, int kind, int index, int *id,
                               int *n_nodes, int *subtype, int *err_stat);
   void CableDyn_GetLineValues(void *handle, int index, int quantity, double *out,
                               int n_out, int *err_stat);
   void CableDyn_GetPointState(void *handle, int index, double *pos, double *vel,
                               double *force, int *err_stat);
   void CableDyn_GetBodyState(void *handle, int index, double *pose, double *vel,
                              double *acc, double *wrench, int *err_stat);
   void CableDyn_GetRodState(void *handle, int index, double *nodes, int n_nodes,
                             double *pose, double *vel, double *wrench, int *err_stat);
   void CableDyn_EvalChannel(void *handle, const char *token, int token_len,
                             double *value, int *err_stat);

``kind`` is ``CD_C_OBJ_LINE`` (1), ``CD_C_OBJ_POINT`` (2), ``CD_C_OBJ_BODY`` (3) or
``CD_C_OBJ_ROD`` (4). ``index`` is 0-based in the handle's inventory: lines in ascending deck
id, points in system order, bodies and rods in solver order. ``id`` is the deck id (a raw-line
handle numbers its lines 1..n).

.. list-table::
   :header-rows: 1
   :widths: 28 72

   * - Function
     - Result
   * - ``CableDyn_NObjects``
     - number of objects of ``kind``
   * - ``CableDyn_GetObjectInfo``
     - ``id``; ``n_nodes`` (lines: node count of the final mesh; rods: ``NumSegs + 1``; points and
       bodies: 1);
       ``subtype`` (lines: 1 finite-EI, 0 EI = 0; points: 1 Fixed, 2 Coupled, 3 Free,
       4 Connect)
   * - ``CableDyn_GetLineValues``
     - one quantity at every node of the line's final mesh, End A first:
       ``CD_C_LINE_POSITION`` (1),
       ``_VELOCITY`` (2), ``_ACCELERATION`` (4), 3 values per node, xyz interleaved;
       ``_TENSION`` (3, the ``Ten<L>N<k>`` node tension), ``_CURVATURE`` (5),
       ``_BEND_MOMENT`` (6, zero on an EI = 0 line), ``_DECLINATION`` (7), ``_AZIMUTH`` (8),
       one value per node; ``_SEGMENT_TENSION`` (9), one value per segment;
       ``_DECK_NODE`` (10), one value per node: the deck node ``J`` of the node (the ``<J>``
       of the node channels), 0 for a node a mesh refinement added, ``1 … n_nodes`` on a line
       meshed as the deck; ``_SECTION_CURVATURE`` (11), two values per node, ``CurvX`` and
       ``CurvY`` interleaved, on a finite-EI line. ``n_out`` must equal the value count. A library
       without code 10 or 11 rejects it with ``CD_C_BAD_INPUT``.
   * - ``CableDyn_GetPointState``
     - position, velocity and the resultant force of the attached lines (``Point<P>F``),
       3 doubles each
   * - ``CableDyn_GetBodyState``
     - 6 doubles each: pose ``[x y z rx ry rz]`` of the reference point (m; x-y'-z'' angles,
       deg), velocity (m/s; deg/s), acceleration (m/s\ :sup:`2`; deg/s\ :sup:`2`) and the
       net wrench about the reference point (N; N m): the ``Body<N>`` channels
   * - ``CableDyn_GetRodState``
     - node positions End A (node 0) to End B, 3 doubles per node; pose ``[x y z rx ry 0]``
       of End A with the axis roll and pitch from vertical; velocity and wrench about End A
   * - ``CableDyn_EvalChannel``
     - the value of one ``OUTPUTS`` token (:doc:`outputs`), for example ``FairTen1``,
       ``L2N5px``, ``Curv1N3``, ``Point4Fz``, ``Body1Pz`` or ``Rod2TenA``; a line-node token
       names a deck node

On a finite-EI line whose mesh the static solve refined, ``n_nodes`` and the
``CableDyn_GetLineValues`` arrays cover every node of the refined mesh, while a node token of
``CableDyn_EvalChannel`` (``Ten1N5``, ``L1N5px``) names deck node 5 at its node of that mesh
(:ref:`outputs-refined-nodes`); ``CD_C_LINE_DECK_NODE`` locates it: the array row whose value is
5.

``CableDyn_GetLineValues`` evaluates a whole line in one call, with no text token per node, and
each value is bit for bit the node channel's. It is the cheap way to read many nodes at every
step. Reading the tension, curvature and bend moment of a line after a step shares one evaluation
of its elements.

A ``NULL`` output pointer skips that output, except for the ``out`` array of
``CableDyn_GetLineValues`` and the ``value`` of ``CableDyn_EvalChannel``; the latter is not
checked and must point to valid storage. An index out of range, a wrongly sized buffer, an
unknown quantity or a malformed token returns ``CD_C_BAD_INPUT``, as does a channel the handle
cannot evaluate (for example ``TDP<L>`` on a point-route deck or an unknown object id); a failed
state query or a non-finite value returns ``CD_C_SOLVE_FAIL``. ``CableDyn_GetLastError`` gives
the reason. The queries do no file I/O and follow the threading rules of the other per-handle
calls.

``CableDyn_EvalChannel`` reads ``token_len`` bytes from ``token``, which need not be
``NUL``-terminated; an embedded ``NUL`` ends the token early, so ``token_len`` may be the
capacity of a larger buffer, as for the other string arguments. ``token_len`` must be at least 1,
and a token longer than 64 characters (the longest channel name) is rejected with
``CD_C_BAD_INPUT``.

Host coupling calls
~~~~~~~~~~~~~~~~~~~

ABI 1 minor extension 2: check ``CableDyn_GetAbiMinor() >= 2`` before calling these.
`Coupling a host (CFD) solver`_ shows how they fit together.

.. code-block:: c

   #define CD_C_POINT_FIXED 1
   #define CD_C_POINT_COUPLED 2   /* Coupled or Vessel */
   #define CD_C_POINT_FREE 3
   #define CD_C_POINT_CONNECT 4

   void CableDyn_InitDeckAt(void *handle, const char *deck_path, int deck_path_len,
                            const double *q0, int n_q0, int *err_stat);
   void CableDyn_SaveState(void *handle, int *err_stat);
   void CableDyn_RestoreState(void *handle, int *err_stat);
   void CableDyn_GetCoupledLayout(void *handle, int *point_id, int *point_type,
                                  int n_block, int *err_stat);

The ``CD_C_POINT_*`` codes are also the point ``subtype`` of ``CableDyn_GetObjectInfo``.

**CableDyn_InitDeckAt.** ``CableDyn_InitDeck`` with the static solve at the host's positions of
the coupled points. ``handle``, ``deck_path`` and ``deck_path_len`` are as for
``CableDyn_InitDeck``, and the call takes the same routes, rejects the same decks, and is
serialised and transactional in the same way.

.. list-table::
   :header-rows: 1
   :widths: 18 8 12 12 12 38

   * - Argument
     - Dir
     - C type
     - Length
     - NULL
     - Meaning
   * - ``q0``
     - in
     - ``const double *``
     - ``n_q0``
     - only if ``n_q0 == 0``
     - host positions [m], interleaved ``x, y, z``: either the ``Coupled``/``Vessel`` blocks
       alone, in coupled-vector order, or the full coupled vector (whose ``Fixed``, ``Free`` and
       ``Connect`` blocks are not read)
   * - ``n_q0``
     - in
     - ``int``
     - --
     - --
     - 3 times the number of line-bound ``Coupled``/``Vessel`` points, or
       ``CableDyn_NCoupledDOF`` of the new model; 0 for a deck without line-bound
       ``Coupled``/``Vessel`` points

Every line-bound ``Coupled``/``Vessel`` point is placed at its entry of ``q0`` before the static
solve, and the lines, ``Free``/``Connect`` points, bodies and rods are solved in equilibrium with
those points held there. The result equals ``CableDyn_InitDeck`` of the deck with those points
moved to ``q0``. The statics start at rest: every coupled velocity and acceleration is zero,
and ``CableDyn_GetCoupledMotion`` returns ``q0`` in the host-driven blocks. A
``Coupled``/``Vessel`` point referenced by no line has no block and keeps its deck coordinates.
On the aggregate route the two forms of ``q0`` coincide; a point that has two blocks there (a
fairlead shared by an ``EI = 0`` and a finite-EI line) needs the same position in both.

An ``n_q0`` that is negative, not a multiple of 3, or fits neither form, a ``NULL`` or
non-finite ``q0``, a line's End A moved below its ``Fixed`` End B anchor (on a deck without
``Free`` or ``Connect`` points), and the deck rejections of ``CableDyn_InitDeck`` return
``CD_C_BAD_INPUT``; the diagnostics of a ``q0`` that does not fit the deck call it
``coupled_positions``. A static-solve failure returns ``CD_C_SOLVE_FAIL``.

**CableDyn_SaveState, CableDyn_RestoreState.** One save slot per handle, for a host's outer
correctors.

.. list-table::
   :header-rows: 1
   :widths: 26 74

   * - Function
     - Effect
   * - ``CableDyn_SaveState``
     - copies the whole model into the slot, replacing any earlier save: every line, point,
       body and rod state with its solver history (viscoelastic, Syrope and seabed-friction
       states), the point fluid fields of ``CableDyn_UpdatePointFluidFields``, and the
       aggregate route's step time
   * - ``CableDyn_RestoreState``
     - returns the model to the slot and keeps the slot, so one save serves any number of
       restores

A restore followed by a step is bit-identical to taking that step from the saved state
directly, whatever ran between the save and the restore: the slot is a copy of the model
object, independent of the rollback buffers the steps use internally. The slot follows the
model it was taken from: a successful ``Init*`` call discards it; a failed ``CableDyn_InitDeck``
or ``CableDyn_InitDeckAt`` keeps it with the model; a failed ``CableDyn_InitLine`` or
``CableDyn_InitLines`` discards it, except on a handle whose model runs on the coupled
aggregate, which stays live with its save (`Calling conventions`_). Both calls return
``CD_C_NOT_INITIALIZED`` before an initialisation, and ``RestoreState`` returns
``CD_C_BAD_INPUT`` when nothing has been saved since the model was initialised. Each call copies
the model, so it allocates memory of the size of the model and costs about as much as copying
it; it does no file I/O and follows the threading rules of the other per-handle calls. On the
aggregate route ``SaveState`` returns ``CD_C_ALLOC_FAIL`` when the slot itself cannot be
allocated, and the handle then holds no save; running out of memory during the copy of the
model, on either route and in either call, aborts the process, as any Fortran assignment of
allocatable data does. There is no serialisation of the state to a caller buffer.

**CableDyn_GetCoupledLayout.** The owner of each 3-DOF block of the coupled vector.

.. list-table::
   :header-rows: 1
   :widths: 18 8 12 12 12 38

   * - Argument
     - Dir
     - C type
     - Length
     - NULL
     - Meaning
   * - ``point_id``
     - out
     - ``int *``
     - ``n_block``
     - yes: skipped
     - deck point id of block ``k`` (DOFs ``3k`` to ``3k+2``, 0-based)
   * - ``point_type``
     - out
     - ``int *``
     - ``n_block``
     - yes: skipped
     - ``CD_C_POINT_FIXED``, ``_COUPLED``, ``_FREE`` or ``_CONNECT``
   * - ``n_block``
     - in
     - ``int``
     - --
     - --
     - must equal ``CableDyn_NCoupledDOF / 3``

The host drives the ``CD_C_POINT_COUPLED`` blocks. On the point route the blocks are the
line-bound points of every type in ``POINTS`` order; on the aggregate route they are the
``Coupled``/``Vessel`` points only (`Coupled DOF layout`_), and a finite-EI line between two
``Coupled`` points has one block per end, its End B block after the fairleads of all
finite-EI lines, so that point id appears once per line end it carries. A handle initialised from raw arrays
has no deck points, and the call returns ``CD_C_BAD_INPUT``: its coupled vector is the caller's
own ``fixed_dofs`` list. A wrong ``n_block`` returns ``CD_C_BAD_INPUT``.

Host rotation calls
~~~~~~~~~~~~~~~~~~~

ABI 1 minor extension 3: check ``CableDyn_GetAbiMinor() >= 3`` before calling these.
`Step 8: a host that turns: torsion and rigid end connections`_ shows how they fit together.

.. code-block:: c

   void CableDyn_InitDeckRotating(void *handle, const char *deck_path,
                                  int deck_path_len, const double *q0, int n_q0,
                                  int *err_stat);
   void CableDyn_UpdateRotations(void *handle, const double *dcm,
                                 const double *omega, const double *alpha,
                                 int n_block, int *err_stat);
   void CableDyn_GetCoupledMoments(void *handle, double *coupled_moments,
                                   int n_coupled_dof, int *err_stat);

**CableDyn_InitDeckRotating.** ``CableDyn_InitDeckAt`` for a host that turns its coupled points:
the arguments, routes, rejections, serialisation and transactions are those of
``CableDyn_InitDeckAt``, and ``n_q0 = 0`` (``q0`` may be ``NULL``) solves the statics at the deck
positions, as ``CableDyn_InitDeck``. The handle takes each coupled block's rotation from
``CableDyn_UpdateRotations`` and passes it with every ``CableDyn_UpdateStates`` and
``CableDyn_Step``, so a line restrained in torsion and a ``Rigid`` bending end connection turn
with the host at their host-driven end, as on the coupled OpenFAST route. It accepts a deck
with a line restrained in torsion, which the other ``Init*`` calls refuse. The rotations start
at identity and rest. Another ``Init*`` call makes the handle one that takes no rotations.

**CableDyn_UpdateRotations.** The rotation of each 3-DOF block of the coupled vector for the
following ``CableDyn_UpdateStates`` and ``CableDyn_Step`` calls; it is kept until the next call.

.. list-table::
   :header-rows: 1
   :widths: 18 8 12 12 12 38

   * - Argument
     - Dir
     - C type
     - Length
     - NULL
     - Meaning
   * - ``dcm``
     - in
     - ``const double *``
     - ``9 * n_block``
     - only if ``n_block == 0``
     - ``dcm[9k + 3i + j]`` is :math:`R_{ij}` of block ``k``'s global-to-body direction cosine
       matrix, row-major: row ``i`` is body axis ``i`` in global axes (the OpenFAST mesh
       orientation). Identity is the body at its static-start attitude.
   * - ``omega``, ``alpha``
     - in
     - ``const double *``
     - ``3 * n_block`` each
     - only if ``n_block == 0``
     - the body's angular velocity [rad/s] and acceleration [rad/s²] in global axes
   * - ``n_block``
     - in
     - ``int``
     - --
     - --
     - must equal ``CableDyn_NCoupledDOF / 3``

Only a finite-EI line's host-driven end uses its block; the other blocks (``EI = 0`` lines,
the point route, bodies and rods) are checked and not used. The call is all or nothing: a
handle not initialised by ``CableDyn_InitDeckRotating``, a wrong ``n_block``, a ``NULL``
pointer, a non-finite entry, and a matrix that is not proper orthogonal to :math:`10^{-8}`
(:math:`\max |R R^T - I|` and :math:`|\det R - 1|`) return ``CD_C_BAD_INPUT`` and leave the
rotations unchanged. The rotations are checked against the lines at the next update or step:
an end frame turned by more than a quarter turn about its line since the last committed state is
refused there.
``CableDyn_SaveState`` saves the rotations with the model and ``CableDyn_RestoreState`` restores
them.

**CableDyn_GetCoupledMoments.** The moment [N m] each block of the coupled vector applies to the
host, about the coupled point in global axes, at the state ``CableDyn_CalcOutput`` reports
(after an update without a step, against the frozen interior as there). It is a finite-EI
line's torsional and bending reaction at its host-driven end, and zero for the other blocks and
on the point route. ``coupled_moments`` holds ``n_coupled_dof`` values (``NULL`` only if
``n_coupled_dof == 0``), which must equal ``CableDyn_NCoupledDOF``; it is set to zero before the
evaluation and stays zero if the call fails. It is available on any initialised handle, so a
host without rotations can read the moment of a ``Rigid`` end connection at its deck direction.

Examples
--------

Both programs compile without warnings under ``gcc -std=c11 -Wall -Wextra -pedantic`` and
``cl /W4``.

One line from arrays
~~~~~~~~~~~~~~~~~~~~

A pre-tensioned 100 m line along :math:`+x`. The x, y, z of both end nodes are prescribed. End B
surges ±0.05 m with a 10 s period. The program needs no input file.

.. code-block:: c

   /* One pre-tensioned EI=0 line between two driven end points. */
   #include "CableDyn_CAPI.h"

   #include <math.h>
   #include <stdbool.h>
   #include <stdio.h>

   #define N_NODES 11
   #define N_ELEM (N_NODES - 1)

   static int report(void *h, const char *where, int err)
   {
       char msg[4097]; /* a message is at most 4096 characters, plus the NUL */
       CableDyn_GetLastError(h, msg, (int)sizeof msg);
       fprintf(stderr, "%s failed (status %d): %s\n", where, err, msg);
       return 1;
   }

   int main(void)
   {
       double q0[3 * N_NODES], v0[3 * N_NODES] = {0.0};
       int elem_conn[2 * N_ELEM];
       double l0[N_ELEM], ea[N_ELEM], rho_a[N_ELEM];
       /* Coupled DOFs: x, y, z of node 1, then x, y, z of node N_NODES (1-based). */
       const int fixed_dofs[6] = {1, 2, 3, 3 * N_NODES - 2, 3 * N_NODES - 1, 3 * N_NODES};
       const double span = 100.0, dt = 0.05;
       void *h = NULL;
       int err = CD_C_OK;

       for (int i = 0; i < N_NODES; ++i) {         /* straight line along +x */
           q0[3 * i + 0] = span * i / N_ELEM;
           q0[3 * i + 1] = 0.0;
           q0[3 * i + 2] = -50.0;
       }
       for (int e = 0; e < N_ELEM; ++e) {
           elem_conn[2 * e + 0] = e + 1;           /* 1-based node indices */
           elem_conn[2 * e + 1] = e + 2;
           l0[e] = 0.999 * span / N_ELEM;          /* 0.1 % pre-strain, m */
           ea[e] = 1.0e8;                          /* N */
           rho_a[e] = 100.0;                       /* kg/m */
       }

       CableDyn_Create(&h, &err);
       if (err != CD_C_OK) return 1;
       CableDyn_InitLine(h, N_NODES, N_ELEM, q0, v0, elem_conn, l0, ea, rho_a,
                         fixed_dofs, 6, /*tension_only=*/1, /*rho_inf=*/0.8, &err);
       if (err != CD_C_OK) { report(h, "CableDyn_InitLine", err); CableDyn_Close(&h, &err); return 1; }

       const int n = CableDyn_NCoupledDOF(h, &err);    /* 6 */
       double q[6], v[6], a[6], loads[6];
       CableDyn_GetCoupledMotion(h, q, v, a, n, &err); /* start from the initial state */

       int status = 0;
       for (int k = 1; k <= 200 && status == 0; ++k) {
           const double t = k * dt, w = 2.0 * acos(-1.0) / 10.0, amp = 0.05;
           q[3] = span + amp * sin(w * t);             /* surge end B, prescribed at t */
           v[3] = amp * w * cos(w * t);
           a[3] = -amp * w * w * sin(w * t);

           bool converged = false, stalled = false;
           int n_iter = 0;
           CableDyn_Step(h, dt, q, v, a, n, &converged, &stalled, &n_iter, &err);
           if (err != CD_C_OK) { status = report(h, "CableDyn_Step", err); break; }
           if (!converged) fprintf(stderr, "t=%.2f: step not converged (stalled=%d)\n", t, stalled);

           CableDyn_CalcOutput(h, loads, n, &err);
           if (err != CD_C_OK) { status = report(h, "CableDyn_CalcOutput", err); break; }
           if (k % 50 == 0)
               printf("t=%6.2f s  Fx(A)=%12.1f N  Fx(B)=%12.1f N  iters=%d\n", t, loads[0], loads[3], n_iter);
       }
       CableDyn_Close(&h, &err);
       return status;
   }

The tension pulls end A toward :math:`+x` and end B toward :math:`-x`, so ``Fx(A)`` is positive
and ``Fx(B)`` is negative. Both oscillate about the 0.1 % pre-tension of about 100 kN.

A mooring deck
~~~~~~~~~~~~~~

Initialise from a deck, seed the coupled vectors from the static solution, and march. A real
host writes its own motion into the blocks of the points it drives before each step.

.. code-block:: c

   /* Couple a mooring deck to a host that drives its Coupled points. */
   #include "CableDyn_CAPI.h"

   #include <stdbool.h>
   #include <stdio.h>
   #include <stdlib.h>
   #include <string.h>

   int main(int argc, char **argv)
   {
       const char *deck = argc > 1 ? argv[1] : "mooring.dat";
       int major, minor, patch, abi, err = CD_C_OK, status = 1;
       void *h = NULL;
       double *q = NULL, *v = NULL, *a = NULL, *loads = NULL;
       char msg[4097]; /* a message is at most 4096 characters, plus the NUL */

       CableDyn_GetVersion(&major, &minor, &patch, &abi);
       if (abi != CABLEDYN_CAPI_ABI_VERSION) {
           fprintf(stderr, "library speaks C ABI %d, header expects %d\n", abi, CABLEDYN_CAPI_ABI_VERSION);
           return 1;
       }

       CableDyn_Create(&h, &err);
       if (err != CD_C_OK) return 1;
       CableDyn_InitDeck(h, deck, (int)strlen(deck), &err); /* parse + static solve */
       if (err != CD_C_OK) goto fail;

       const int n = CableDyn_NCoupledDOF(h, &err);
       if (err != CD_C_OK) goto fail;
       printf("%d lines, %d points, %d coupled DOFs\n", CableDyn_NLines(h, &err), CableDyn_NPoints(h, &err), n);

       q = calloc((size_t)n, sizeof *q);
       v = calloc((size_t)n, sizeof *v);
       a = calloc((size_t)n, sizeof *a);
       loads = calloc((size_t)n, sizeof *loads);
       if (!q || !v || !a || !loads) goto fail;

       /* Start from the static solution: every block (anchors too) must hold valid data. */
       CableDyn_GetCoupledMotion(h, q, v, a, n, &err);
       if (err != CD_C_OK) goto fail;

       const double dt = 0.05;
       for (int step = 1; step <= 100; ++step) {
           /* ... overwrite the blocks of the points the host drives with its motion at t+dt ... */
           bool converged, stalled;
           int n_iter;
           CableDyn_Step(h, dt, q, v, a, n, &converged, &stalled, &n_iter, &err);
           if (err != CD_C_OK) goto fail;
           if (!converged) fprintf(stderr, "step %d: not converged after %d iterations\n", step, n_iter);
           CableDyn_CalcOutput(h, loads, n, &err); /* N, global axes, cable on host */
           if (err != CD_C_OK) goto fail;
       }
       printf("block 1 load: %.1f %.1f %.1f N\n", loads[0], loads[1], loads[2]);
       status = 0;

   fail:
       if (status != 0 && h != NULL) {
           CableDyn_GetLastError(h, msg, (int)sizeof msg);
           fprintf(stderr, "CableDyn error %d: %s\n", err, msg);
       }
       free(q); free(v); free(a); free(loads);
       CableDyn_Close(&h, &err);
       return status;
   }

Deck features that ``CableDyn_InitDeck`` rejects, such as a ``Coupled`` rod, are reported
through ``CableDyn_GetLastError`` with status ``CD_C_BAD_INPUT``. For the matching Python calls,
see :doc:`python`. For solver diagnostics, see :doc:`troubleshooting`.
