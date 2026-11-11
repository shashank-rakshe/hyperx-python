.. SPDX-License-Identifier: Apache-2.0

Tutorial 6 — Synthetic ropes
============================

**Goal:** choose between the three polyester/nylon models — linear ``EA``, viscoelastic (a
series-Kelvin model with slow and dynamic stiffness), and Syrope (working curve with load
history) — and see where each one matters.

**Decks:** ``polyester_catenary_mooring.dat``, ``ve_polyester_catenary_mooring.dat``,
``ve_nylon_loaddependent_mooring.dat``, ``ve_polyester_dynamic_waves.dat``,
``syrope_polyester_mooring.dat`` (+ ``data/syrope/``) · **Route:** ``EI = 0`` cable path ·
**Run time:** < 1 s each

Why a rope needs more than one ``EA``
-------------------------------------

A polyester or nylon rope is stiffer under wave-frequency cycling than under a slowly applied
mean load, and its stiffness depends on the largest load it has ever carried. A single ``EA``
must therefore be chosen for one purpose: the **static** (slow) stiffness sets the mean offset,
the **dynamic** stiffness sets wave-frequency tension ranges. CableDyn offers three levels,
selected entirely by the ``EA`` and ``BA`` tokens of the ``LINE TYPES`` row — no extra columns:

.. code-block:: text

   TypeName          Diam    Mass   EA                                                    BA             ...
   polyester         0.1438  22.42  1.42e8                                                -1.0           ...
   poly_ve           0.1438  22.42  1.424e8|2.50e8                                        4.0e9|1.1e7    ...
   nylon_mean_load   0.1500  24.00  6.0e7|1.00e8|0.4                                      4.0e9|1.1e7    ...
   rope              0.1438  22.42  "SYROPE:data/syrope/syrope_settings.dat|1.53e8|23.12"  5.0e10|1.0e5   ...

.. list-table::
   :header-rows: 1
   :widths: 24 30 46

   * - Model
     - ``EA`` / ``BA`` tokens
     - Use it when
   * - linear
     - ``EA``; ``BA`` or ``-ζ``
     - first estimates, or when a single secant stiffness is justified for the load case
   * - viscoelastic (series-Kelvin), constant dynamic stiffness (MoorDyn ``ElasticMod 2``)
     - ``Es|Ed``; ``Bs|Bd`` (N·s)
     - the vendor gives a static and a dynamic stiffness; mean offset and wave ranges both matter
   * - viscoelastic, load-dependent dynamic stiffness (``ElasticMod 3``)
     - ``Es|alphaMBL|vbeta``; ``Bs|Bd``
     - nylon or polyester whose dynamic stiffness grows with mean load
   * - Syrope
     - ``"SYROPE:<settings>|alpha|beta"``; ``BA_s|BA_d``
     - polyester with a measured original working curve and a known load history (pretension
       and storm peaks shift the working curve)

The equations are in :doc:`theory`; the token rules in :doc:`driver_format`.

Statics: the slow stiffness decides
-----------------------------------

.. code-block:: powershell

   New-Item -ItemType Directory -Force results | Out-Null   # already there after the quickstart
   .\CableDyn_driver.exe .\examples\polyester_catenary_mooring.dat    .\results\poly_lin
   .\CableDyn_driver.exe .\examples\ve_polyester_catenary_mooring.dat .\results\poly_ve

Both decks describe the same 690 m semi-taut polyester leg in 200 m of water:

.. code-block:: text

   poly_lin.out  FairTen1 = 4.2291139E+004  AnchTen1 = 3.1765601E+004  FairIncl1 = 4.0917746E+001
   poly_ve.out   FairTen1 = 4.2291825E+004  AnchTen1 = 3.1766281E+004  FairIncl1 = 4.0917412E+001

They agree to 0.002 %: the static solution of a viscoelastic rope uses the slow stiffness ``Es``
(1.424e8 N, versus 1.42e8 N in the linear deck). The dynamic branch ``Ed`` only engages when
the tension cycles. ``ve_nylon_loaddependent_mooring.dat`` (a 46.6°-inclined nylon leg,
``FairTen1`` = 30.01 kN) behaves the same way in statics.

Dynamics: the dynamic stiffness decides
---------------------------------------

``ve_polyester_dynamic_waves.dat`` marches the viscoelastic leg for 10 s under a 1.5 m, 10 s
Airy wave. Make a linear twin by replacing the line type with ``poly_lin 0.1438 22.42 1.424e8
-1.0 0.0 1.2 0.2 1.0 0.0`` (and the ``SECTIONS`` type name), then run both:

.. code-block:: text

   linear twin        FairTen1 mean 42.29 kN   min 42.15 kN   max 42.45 kN
   viscoelastic       FairTen1 mean 42.29 kN   min 42.15 kN   max 42.42 kN

With the fairlead held, the wave only acts on the rope itself and the tension barely moves, so
the models agree. Drive the fairlead with platform motion (Exercise 1) and the stiffer dynamic
branch produces visibly larger tension ranges for the same motion — the effect that governs
fatigue of synthetic moorings.

Syrope: working curve and load history
--------------------------------------

The Syrope deck is a 20 m taut polyester test leg. Its ``EA`` token names a settings file; the
settings file names the original working-curve (OWC) table:

.. code-block:: text

   data/syrope/syrope_settings.dat:
   syrope_owc.dat  OWC     - Original working-curve table file (relative to this file)
   EXP             WCType  - Working-curve formulation {LINEAR; QUADRATIC; EXP}
   0.20            k1      - First working-curve shape parameter
   1.50            k2      - Second working-curve shape parameter

and a ``SYROPE IC`` section gives the rope's history before the simulation starts — the
largest tension it has seen (``Tmax0``) and its mean tension (``Tmean0``):

.. code-block:: text

   --------------------- SYROPE IC ----------------------------------------
   Line(s) Tmax0   Tmean0
   1       2.0e6   1.5e6

.. code-block:: powershell

   .\CableDyn_driver.exe .\examples\syrope_polyester_mooring.dat .\results\syrope

The static initial condition is solved on the ``Tmax0`` working curve, and the line starts in
that equilibrium: ``FairTen1`` is 972.8 kN at t = 0 and stays there over the 2 s run (the fairlead
is held). With both ends fixed, the geometry and ``Tmax0`` set the mean tension, so ``Tmean0``
does not enter the state. The driver prints a note because this deck's 1.5 MN differs from the
972.8 kN equilibrium. Syrope lines run dynamically (``dtM``/``TMax``). A Syrope section can also
sit between chains: ``composite_chain_syrope_chain.dat`` is a chain–polyester–chain mooring on a
moving vessel, every polyester element starting on its working curve.

.. important::

   Copy the Syrope deck **together with** ``data/syrope/syrope_settings.dat`` and
   ``data/syrope/syrope_owc.dat``. Paths are relative to the file that names them; the OWC table
   is part of the material model and belongs in your analysis record.

Exercises
---------

1. **Cycled rope.** Give ``ve_polyester_dynamic_waves.dat`` a motion file with a 2 m, 10 s surge
   of point 2 (see :doc:`tutorial_motion` for the file format), run the viscoelastic deck and its
   linear twin, and compare tension standard deviations over the last two cycles.
2. **Load history.** In the Syrope deck (copied with its ``data/syrope`` folder), raise
   ``Tmax0`` from 2.0e6 to 3.0e6 N and rerun. The higher past peak leaves more permanent
   elongation and a softer working curve, so at the same 20.5 m span the rope carries 709.2 kN
   instead of 972.8 kN. Load history is a first-order input for polyester.
3. **Vendor data.** For your own rope, write down the source of ``Es``, ``Ed``, the damping pair,
   the MBL scaling, and the working curve before running anything.

Next: :doc:`tutorial_bodies`.
