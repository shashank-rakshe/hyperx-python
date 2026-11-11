.. SPDX-License-Identifier: Apache-2.0

Standalone driver tutorial
==========================

This tutorial starts with a static chain, progresses to an installed finite-EI lazy-wave cable,
and finishes with prescribed fairlead motion. Commands assume the release executable and repository
``examples`` directory are in the current working directory. PowerShell paths are shown; quote any
path containing spaces.

1. Verify the executable and create the output folder
-----------------------------------------------------

.. code-block:: powershell

   .\CableDyn_driver.exe --version
   New-Item -ItemType Directory -Force results | Out-Null

The driver does not create output folders; every command below writes into ``results``.

The release executable is statically linked. It does not require a CableDyn, Intel Fortran, MKL,
or Visual C++ runtime DLL. A model may still reference ordinary input files through relative paths.

2. Run a static catenary
------------------------

.. code-block:: powershell

   .\CableDyn_driver.exe .\examples\chain_catenary_r3_100m.dat .\results\chain100

The second argument is an output root, not a directory. This run writes:

* ``results\chain100.out``: requested scalar channels at ``t=0``;
* ``results\chain100.static.out``: one row per node, ordered End A to End B, with coordinates,
  tension, curvature, moment, declination, inclination, and azimuth; and
* optional per-line files when a LINES output flag requests them.

No initial shape is supplied. CableDyn builds an analytical catenary seed and solves the nonlinear
static equilibrium under weight, buoyancy, axial stiffness, and declared seabed contact.

3. Read the input in object order
---------------------------------

The maintained deck order is ``LINE TYPES`` → ``POINTS`` → ``LINES`` → ``SECTIONS`` → ``OPTIONS``
→ ``OUTPUTS``. A line is one physical object from End A (fairlead/hang-off) to End B
(anchor/termination). Multiple SECTIONS belong to that same object; they are not separate lines.

For each edit, check these invariants:

#. Every SECTION ``LineID`` exists in LINES and every ``LineType`` exists in LINE TYPES.
#. Section lengths sum to the installed unstretched length.
#. ``NumSegs`` resolves the touchdown, buoyancy-module transitions, and curvature peaks.
#. Coordinates and depths use global metres with ``z`` positive upward.
#. Units are SI. Tension output is N, not kN.

4. Study every option
----------------------

Run the complete option-reference deck:

.. code-block:: powershell

   .\CableDyn_driver.exe .\examples\cabledyn_options_reference.dat .\results\options_reference

Its active rows reproduce all common defaults. Commented rows show mutually exclusive current,
wave, motion, bathymetry, WaterKin, and MoorDyn-compatibility forms. The authoritative meanings,
defaults, constraints, and ownership rules for standalone runs and for OpenFAST (maintained by
NLR, the National Laboratory of the Rockies, formerly NREL) are in :doc:`options`.

Do not tune Newton tolerances merely to make one model converge. First verify geometry, installed
length, units, submerged weight, endpoint order, contact depth, and mesh resolution. Production
reference runs should retain ``dynamic_solver 1e-8 1e-14 30 12`` and ``rhoInf = 0.4`` unless a
documented sensitivity study justifies another choice.

5. Solve the three installed Lozon cables
------------------------------------------

.. code-block:: powershell

   .\CableDyn_driver.exe .\examples\lozon_gomex80_power_cable.dat .\results\lozon80
   .\CableDyn_driver.exe .\examples\lozon_gomaine200_power_cable.dat .\results\lozon200
   .\CableDyn_driver.exe .\examples\lozon_humboldt800_power_cable.dat .\results\lozon800

These are complete installed cables with grounded tails. CableDyn determines touchdown and the
lazy-wave equilibrium from POINTS, SECTIONS, properties, and seabed data. There is no initial-shape
file. Plot ``Curvature`` and ``Tension`` against ``ArcLength`` from each ``.static.out`` file and
confirm that the curve is smooth across touchdown and section boundaries.

The maintained regression values are listed in :doc:`validation`. Reproducing a fairlead tension
without reproducing peak curvature is not a sufficient equilibrium check; a folded local branch can
have a plausible endpoint force.

6. Prescribe fairlead motion
----------------------------

.. code-block:: powershell

   .\CableDyn_driver.exe .\examples\lozon_gomex80_power_cable_motion.dat .\results\lozon80_motion

The deck references ``data/lozon/gomex80_heave_3m_12s_dt005.txt`` relative to its own directory.
Copy the deck and its ``data`` subtree together. Each motion station supplies absolute position,
velocity, and acceleration; CableDyn includes moving-support inertia rather than overwriting only
the endpoint coordinate.

For a new motion file:

#. Include the ``t=0`` row and every station through ``TMax``.
#. Use a constant cadence exactly equal to ``dtM``.
#. Provide consistent analytical or carefully differentiated velocity and acceleration.
#. Begin from the intended physical boundary state to avoid an artificial first-step jump.

7. Dynamic output and convergence
---------------------------------

Standalone ``.out`` rows follow ``dtM``. Reducing ``dtM`` increases both temporal resolution and
cost. For fatigue or snap/contact work, repeat at successively smaller values and compare means,
standard deviations, ranges, peaks, spectra, and damage-equivalent loads. A normal termination at
one step size establishes neither convergence nor physical validity.

Keep the complete deck, auxiliary files, executable SHA-256, console log, and static profile with
every production result. See :doc:`outputs` for Python/pyDatView post-processing and
:doc:`troubleshooting` for named initialisation and dynamic-solve failures.
