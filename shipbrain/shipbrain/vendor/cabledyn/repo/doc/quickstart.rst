.. SPDX-License-Identifier: Apache-2.0

Quickstart: first result in five minutes
========================================

This page takes a Windows user from the downloaded release to a verified mooring-line result and
reads it back in Python. It assumes the layout from :doc:`installation`: ``CableDyn_driver.exe``
and the ``examples`` folder (from the release's **Source code (zip)**) side by side in
``C:\CableDyn``.

.. contents::
   :local:
   :depth: 1

1. Open a terminal in the release folder
----------------------------------------

.. code-block:: powershell

   Set-Location C:\CableDyn
   .\CableDyn_driver.exe --version        # prints the v0.4.2 banner, exit code 0

2. Solve a mooring line
-----------------------

``examples\chain_catenary_shallow_30m.dat`` is a 270 m R4 studless chain in 30 m of water: the
fairlead is at the surface, the anchor 250 m away on the seabed, so most of the chain rests on
the bottom. The second argument is an **output root** (a file stem, not a folder), and its folder
must exist:

.. code-block:: powershell

   New-Item -ItemType Directory -Force results | Out-Null
   .\CableDyn_driver.exe .\examples\chain_catenary_shallow_30m.dat .\results\shallow30

The run takes well under a second:

.. code-block:: text

    ===================================================================
      CableDyn  v0.4.2
      Geometrically exact finite-element statics and dynamics of
      mooring lines and dynamic power cables for floating offshore wind
    -------------------------------------------------------------------
      Author    Prof. Jae Hoon Seo
      Affil.    Inha University, Republic of Korea
      License   Apache-2.0     github.com/SMI-Lab-Inha/CableDyn
    ===================================================================
     Parsing CableDyn input file: .\examples\chain_catenary_shallow_30m.dat
      Created CableDyn model: 1 line object(s), 2 point(s), 1 section(s) [EI=0: 1, finite-EI: 0].
      Initial conditions: Newton static equilibrium with load continuation completed.
      Fairlead convention: force is on End A toward End B; inclinations are signed below horizontal.
      Line 1 fairlead effective tension:  1.49549E+005 N
         force [Fx, Fy, Fz]: [ 2.72025E+004,  0.00000E+000, -1.47054E+005] N, inclination=   79.520 deg
         line tangent: inclination=   78.587 deg, declination=  168.587 deg, azimuth=    0.000 deg
     CableDyn initialization completed.
   CableDyn_driver: converged run written to .\results\shallow30.out

What happened: CableDyn built an analytical catenary seed, then solved the full nonlinear static
equilibrium (weight, buoyancy, axial stretch, and seabed contact) by Newton iteration. No initial
shape, relaxation time, or damping had to be tuned. The fairlead carries 149.5 kN, pulling
steeply downward: the force points 79.5° below horizontal, and the line leaves the fairlead at
78.6° (its tangent) because it hangs almost vertically in this shallow water.

3. Check the exit code and the files
------------------------------------

.. code-block:: powershell

   $LASTEXITCODE           # 0
   Get-ChildItem results   # shallow30.out, shallow30.static.out

.. list-table::
   :header-rows: 1
   :widths: 12 88

   * - Exit
     - Meaning
   * - ``0``
     - converged; every requested output was written
   * - ``1``
     - the input or command line is unusable: missing or malformed deck, unknown keyword,
       unsupported feature combination, or an output folder that does not exist
   * - ``2``
     - the static solve or the time march did not converge (any partial ``.out`` is for
       inspection only), or a Windows GNU source build could not load its LAPACK library

Always check the exit code in scripts. If you forget to create ``results`` first, the driver
stops before solving with exit code ``1`` and says so::

   CableDyn_driver: cannot write output files at ".\results\shallow30" (check that the directory exists and is writable)

The full contract is in :doc:`standalone_driver` and :doc:`cli`; every fail-closed message is
listed in :doc:`troubleshooting`.

4. Read the result
------------------

``results\shallow30.out`` holds the channels requested in the deck's ``OUTPUTS`` section. A
static run writes a single row at ``t = 0``; columns are tab-separated and tensions are in N:

.. code-block:: text

   # CableDyn driver output (static IC; converged=T)
   Time(s)	FairTen1	AnchTen1	FairIncl1	AnchIncl1
     0.0000000000000000E+000	 1.4954922E+005	 3.0129121E+004	 7.8586898E+001	-1.3672965E+000

The anchor tension (30.1 kN) is the line-end force at the anchor: the 27.2 kN horizontal
tension, which the frictionless grounded chain carries unchanged along the seabed, plus the
weight of the anchor node's half element, which the anchor holds just above the penetrated
seabed. The anchor inclination is essentially zero: the
chain arrives along the seabed, as a drag anchor requires.

``results\shallow30.static.out`` is the along-arc profile, one row per node from End A
(fairlead) to End B (anchor): arc length, ``X``/``Y``/``Z``, effective tension, curvature, bend
moment, declination, inclination, and azimuth: a range graph of the static state. Open it in
Excel, `pyDatView <https://github.com/ebranlard/pyDatView>`_, or Python.

5. The same result in Python
----------------------------

With the wheel installed (:doc:`installation`):

.. code-block:: python

   from cabledyn import read_output
   result = read_output(r"results\shallow30.out")
   print(f"FairTen1 = {result.column('FairTen1')[0] / 1e3:.1f} kN")   # FairTen1 = 149.5 kN

And from the profile, how much of the line lies on the 30 m seabed:

.. code-block:: python

   profile = read_output(r"results\shallow30.static.out")
   z = profile.column("Z")
   print((z <= -29.99).sum(), "of", z.size, "nodes on the seabed")      # 40 of 46 nodes

Building from source instead? Replace ``.\CableDyn_driver.exe`` with ``build\bin\cabledyn.exe``
(Windows, conda toolchain) or ``./build/cabledyn`` (Linux/macOS); the arguments, outputs, and exit
codes are identical.

Next steps
----------

.. list-table::
   :widths: 30 70

   * - :doc:`tutorials`
     - The guided path: catenary statics → spread moorings → lazy-wave cables → prescribed
       motion → waves and current → synthetic ropes → buoys and rods → Python studies →
       coupled floating turbine.
   * - :doc:`tutorial_openfast`
     - Run the IEA-15MW VolturnUS-S floating turbine with CableDyn inside the release
       ``openfast.exe`` (``CompMooring = 5``).
   * - :doc:`examples`
     - Every shipped deck, what it demonstrates, and how long it takes.
   * - :doc:`driver_format`
     - The complete input-deck reference.
   * - :doc:`migrating`
     - Bring an existing MoorDyn or OrcaFlex model across.
