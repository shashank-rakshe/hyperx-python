.. SPDX-License-Identifier: Apache-2.0

Tutorials
=========

The tutorials form one path from a single chain to a coupled floating wind turbine. Each is
self-contained, runs a deck from the ``examples/`` folder in seconds to a minute, shows the real
console output and result files, explains what the numbers mean, and ends with exercises. Work
them in order the first time; each one introduces a concept the next relies on.

.. list-table::
   :header-rows: 1
   :widths: 6 34 44 16

   * - #
     - Tutorial
     - You learn
     - Run time
   * - 1
     - :doc:`tutorial_catenary`
     - deck anatomy, static equilibrium from a trivial seed, ``.out`` and ``.static.out``,
       touchdown, mesh convergence
     - < 1 s
   * - 2
     - :doc:`tutorial_spread`
     - multi-line systems, the full output-channel vocabulary, per-line files, restoring force
     - < 1 s
   * - 3
     - :doc:`tutorial_lazywave`
     - finite bending stiffness, buoyancy sections, sag/hog bends, curvature and bend radius
     - < 1 s
   * - 4
     - :doc:`tutorial_motion`
     - time-domain dynamics with a prescribed fairlead trajectory (``motionFile``)
     - < 1 s
   * - 5
     - :doc:`tutorial_dynamics`
     - current, regular and JONSWAP waves; time-step and mesh convergence
     - seconds
   * - 6
     - :doc:`tutorial_ropes`
     - polyester and nylon: linear, viscoelastic, and Syrope constitutive models
     - seconds
   * - 7
     - :doc:`tutorial_bodies`
     - 6-DOF rigid buoys (``BODIES``) and rigid rods (``RODS``) in a mooring system
     - seconds
   * - 8
     - :doc:`tutorial_python`
     - parameter sweeps, provenance, statistics, rainflow fatigue, and spectra from Python
     - seconds
   * - 9
     - :doc:`tutorial_openfast`
     - the IEA-15MW VolturnUS-S floating turbine with CableDyn in ``openfast.exe``
       (``CompMooring = 5``; OpenFAST is maintained by NLR, the National Laboratory of the
       Rockies, formerly NREL) and the MoorDyn A/B
     - ~1 min
   * - —
     - :doc:`tutorial_standalone`
     - a compact standalone-driver checklist: deck order, option reference, the three Lozon
       cables, prescribed motion, and convergence practice
     - seconds

Before you start
----------------

* Complete :doc:`quickstart` so the executable, the ``examples`` folder, and a ``results``
  folder are in place. Commands are shown for the Windows release in PowerShell, run from the
  folder that holds ``CableDyn_driver.exe`` and ``examples``::

     C:\CableDyn> .\CableDyn_driver.exe .\examples\<deck>.dat .\results\<root>

* **Built from source?** Use ``build\bin\cabledyn.exe`` (Windows, conda toolchain) or
  ``./build/cabledyn`` (Linux/macOS) instead of ``.\CableDyn_driver.exe``, and ``examples/``
  from the repository root. Everything else — arguments, files, exit codes, numbers — is
  identical.
* Never edit the shipped decks in place: copy one, rename it, and edit the copy. Decks that
  reference auxiliary files (motion, Syrope, bathymetry) must be copied together with their
  ``data`` folder, because those paths are relative to the deck.
* Skim :doc:`concepts` for the vocabulary (line, section, point, End A / End B). Units are SI
  throughout; tensions are in N, angles in degrees, ``z`` is positive up with the still-water
  line at ``z = 0``.

.. admonition:: A zero exit code is not validation
   :class: tip

   Every tutorial ends by checking the result against physics you can estimate by hand, or by
   refining the time step or mesh. Keep that habit for your own models.
