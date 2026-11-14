.. SPDX-License-Identifier: Apache-2.0

CableDyn
========

**CableDyn** is an open-source (`Apache-2.0 <https://www.apache.org/licenses/LICENSE-2.0>`_),
geometrically exact finite-element solver for the statics and dynamics of mooring lines and
dynamic power cables of floating offshore wind turbines and substations, written in modern
**Fortran 2018**. Its strain and curvature are the exact large-deformation measures, never
linearised (:doc:`theory`). It targets dynamic power cables in the lazy-wave configuration and
taut, semi-taut, and catenary moorings. It reads MoorDyn v2 input decks and has been compared
with MoorDyn-C, MoorDyn-F, and OrcaFlex on common reference cases.

.. admonition:: Release status
   :class: note

   CableDyn ``v0.4.2`` is the current stable release. It is on PyPI with wheels that carry the
   solver (``pip install cabledyn``). It makes the modal analysis of long lines and the
   finite-EI dynamic step faster, holds the finite-EI static solve to its tolerance on graded
   meshes, in cross currents, with attachments, ``Rigid`` ends and as-laid friction, gives a
   mesh-independent axial damping ratio (``axialDampingRatio mode1``), and runs every shipped
   example deck in its test suite.
   Every comparative-accuracy statement is linked to a passing benchmark in :doc:`validation`.
   The project remains below ``1.0.0``, so public APIs may evolve between minor releases.

Two solver paths
----------------

CableDyn is built on **two position-based finite-element formulations**, with no rotation
degrees of freedom in the line elements:

.. list-table::
   :header-rows: 1
   :widths: 26 74

   * - Path
     - Used for
   * - ``EI = 0`` **cable path**
     - chains and moorings — a positions-only element, a banded Newton/Armijo static solve
       seeded from an analytical catenary, and generalised-α dynamics with Morison and seabed
       loads.
   * - **cubic-Hermite bending path**
     - lazy-wave dynamic power cables — a position + material-tangent element carrying the exact
       nonlinear centreline curvature, with a Newton static solve seeded from the exact catenary
       and continued in ``EI``, and generalised-α dynamics.

Which path a line section uses is decided by its line type's bending stiffness ``EI``. A mixed
deck — chain moorings *and* a finite-EI power cable — is normal. Time integration is the
implicit Chung & Hulbert (1993) generalised-α scheme. The solver core is caller-agnostic behind
a single coupling boundary, with a thin shell per target: an **OpenFAST v5 module**
(``CompMooring = 5``; OpenFAST is maintained by NLR, the National Laboratory of the Rockies,
formerly NREL) and a standalone **C binding** couplable to CFD.

Download to first result in five minutes
----------------------------------------

#. Download ``CableDyn_driver.exe``, ``SHA256SUMS.txt``, and **Source code (zip)** (for the
   ``examples`` folder) from the `v0.4.2 release
   <https://github.com/SMI-Lab-Inha/CableDyn/releases/tag/v0.4.2>`_ and verify the checksum —
   :doc:`installation`. No installer and no runtime DLLs.
#. Put ``CableDyn_driver.exe`` in a working folder, unzip the source archive, and copy its
   ``examples`` folder next to the executable.
#. Create the output folder (the driver does not create it) and solve a mooring line:

   .. code-block:: powershell

      New-Item -ItemType Directory -Force results | Out-Null
      .\CableDyn_driver.exe .\examples\chain_catenary_shallow_30m.dat .\results\shallow30

#. Read ``results\shallow30.out`` (fairlead tension 149.5 kN) and the along-line profile
   ``shallow30.static.out`` — :doc:`quickstart`.

What CableDyn does
------------------

.. list-table::
   :header-rows: 1
   :widths: 40 30 30

   * - Capability
     - ``CableDyn_driver.exe`` (standalone)
     - ``openfast.exe`` (``CompMooring = 5``)
   * - Chain, wire, polyester, nylon moorings (``EI = 0``); composite lines
     - static and dynamic
     - coupled dynamic
   * - Lazy-wave power cables with bending stiffness (``EI > 0``), touchdown
     - static and dynamic
     - coupled dynamic
   * - Mixed deck: moorings and power cables together
     - static and dynamic (held ends or a ``motionFile``/``vesselMotion``; moving bodies, rods,
       and points on the multibody march)
     - coupled dynamic
   * - Automatic Newton static equilibrium, no initial shape or relaxation
     - yes
     - yes (the coupled initial condition)
   * - Seabed contact, friction, structured bathymetry
     - yes
     - yes
   * - Current and waves
     - deck ``current``, ``waves`` and ``wavetrain`` (Airy, stream-function, JONSWAP and other
       spectra, directional spreading), WaterKin files
     - OpenFAST SeaState or WaterKin
   * - Prescribed endpoint motion
     - ``motionFile`` (position, velocity, acceleration), 6-DOF ``vesselMotion``, or
       ``vesselRAO`` (RAO response to the deck waves)
     - platform motion from OpenFAST
   * - Viscoelastic and Syrope synthetic-rope models
     - yes
     - see :doc:`capabilities`
   * - Buoys, clump weights, ``Rigid6`` bodies, rigid rods
     - yes
     - yes
   * - Line failures (``FAILURE``)
     - yes
     - yes
   * - Modal analysis (``nModes``), range graphs, discrete ``ATTACHMENTS``
     - yes
     - range graphs and ``ATTACHMENTS``
   * - Checkpoint/restart, linearisation, FAST.Farm, active tensioning
     - —
     - yes (:doc:`openfast`)
   * - Python automation and post-processing (studies, fatigue, spectra)
     - yes (:doc:`python`)
     - reads OpenFAST outputs
   * - C API for CFD and custom co-simulation
     - :doc:`capi`
     - —

Route-by-route detail and every named limitation: :doc:`capabilities`.

Learning path
-------------

:doc:`quickstart` → :doc:`tutorials`: grounded catenary → spread mooring → lazy-wave cable →
prescribed motion → waves and current → synthetic ropes → buoys and rods → Python studies →
coupled floating turbine in OpenFAST. :doc:`examples` catalogues every shipped deck.

Reference and theory
--------------------

* Input: :doc:`driver_format` (the deck), :doc:`options`, :doc:`file_formats`; results:
  :doc:`outputs`; command line: :doc:`cli`; units, signs, and angles: :doc:`conventions`.
* Porting a MoorDyn or OrcaFlex model: :doc:`migrating`. Something failed:
  :doc:`troubleshooting` maps every message to its fix; see also :doc:`faq`.
* The equations and solvers: :doc:`theory` and :doc:`solver_paths`.

Validation
----------

Static and dynamic results are compared with analytical solutions, OrcaFlex, MoorDyn-C, and
MoorDyn-F on reference structures — the IEA-15MW VolturnUS-S moorings and the Lozon et al.
(2025) lazy-wave power cables at 80, 200, and 800 m water depth. Every comparison, tolerance,
and reproduction command is in :doc:`validation`.

Acknowledgements
----------------

CableDyn builds on the work of others, and we are grateful to the developers and maintainers
of MoorDyn (Hall et al.), whose open input format CableDyn reads and which serves as a
comparison reference; of OpenFAST, maintained by NLR (National Laboratory of the Rockies,
formerly NREL), which hosts CableDyn as a mooring module; and of OrcaFlex (Orcina Ltd.),
the industry reference used for many of the comparisons in :doc:`validation`. The codes are
cited in :doc:`references`.

How to cite
-----------

If CableDyn contributes to published work, cite the method article and the software release
as described in :doc:`citing`.

Name
----

This software is developed independently at the Department of Naval Architecture and Ocean
Engineering, Inha University. It is not affiliated with, derived from, or endorsed by the
EPSRC-funded research project (2022--2025) of the same name led by the University of Edinburgh,
"CableDyn: Subsea Power Cable Dynamics Under Complex Ocean Environment"
(`cabledyn.eng.ed.ac.uk <https://cabledyn.eng.ed.ac.uk>`_).

.. toctree::
   :hidden:
   :caption: Getting started

   capabilities
   concepts
   installation
   quickstart
   modeling

.. toctree::
   :hidden:
   :caption: Tutorials

   tutorials
   tutorial_catenary
   tutorial_spread
   tutorial_lazywave
   tutorial_motion
   tutorial_dynamics
   tutorial_ropes
   tutorial_bodies
   tutorial_python
   tutorial_openfast
   tutorial_standalone
   examples

.. toctree::
   :hidden:
   :caption: User reference

   driver_format
   options
   file_formats
   outputs
   cli
   standalone_driver
   conventions
   migrating
   troubleshooting
   faq
   glossary

.. toctree::
   :hidden:
   :caption: Theory manual

   theory
   solver_paths

.. toctree::
   :hidden:
   :caption: Coupling & APIs

   openfast
   coupling
   coupling_boundary
   capi
   python
   python_postprocessing
   api_python
   api_reference

.. toctree::
   :hidden:
   :caption: Validation

   validation

.. toctree::
   :hidden:
   :caption: Project

   changelog
   citing
   references
   contributing
   development
