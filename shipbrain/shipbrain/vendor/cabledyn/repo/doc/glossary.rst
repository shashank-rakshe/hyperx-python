.. SPDX-License-Identifier: Apache-2.0

Glossary
========

Offshore mooring/cable and solver terms as CableDyn uses them. Conventions (frames, signs,
tension) are defined precisely in :doc:`conventions`.

.. glossary::
   :sorted:

   End A
      The **fairlead / upper** end of a line (``NodeA`` in a ``LINES`` row); arc length
      :math:`s = 0`. See :doc:`concepts`.

   End B
      The **anchor / lower** end of a line (``NodeB``); arc length :math:`s = L`.

   fairlead
      The point where a mooring line or cable attaches to the floating platform (End A).

   anchor
      The fixed point where a mooring line terminates on the seabed (End B).

   boundary attachment
      The native object at a line end: an anchor, fairlead, connector, clump, float, vessel, or
      rigid body. A MoorDyn-style ``POINTS`` row is a deck record that translates to one of these;
      it is not a CableDyn finite-element node.

   compatibility object
      A ``POINTS``, ``BODIES``, or ``RODS`` record of the MoorDyn deck layout. These records are
      translated into line boundary objects or rigid bodies; their MoorDyn node identity is not
      part of the CableDyn line mesh.

   line
      One object spanning End A → End B, built from an ordered list of :term:`sections
      <section>`. The unit of the CableDyn model. Different from MoorDyn, where a composite is
      several lines.

   section
      A contiguous run of one :term:`line type` with its own length and mesh density; a line is
      an ordered list of sections A → B (the line-and-section arrangement OrcaFlex also uses).

   line type
      The reusable material a section refers to by name — diameter, mass, ``EA``, ``BA``, ``EI``,
      and the Morison coefficients.

   catenary
      The equilibrium shape of a heavy line hanging under gravity with no bending stiffness — the
      ``EI = 0`` path's geometry and the analytical static seed.

   taut mooring
      A mooring held under high pretension so the line is nearly straight and carries little
      catenary sag; typically synthetic rope. **Semi-taut** is the intermediate regime.

   spread mooring
      Several mooring lines radiating from a platform to anchors (e.g. three lines at 120°).

   lazy-wave
      A dynamic power-cable configuration with a net-buoyant middle :term:`section` that lifts an
      arch between the hang-off and the seabed, decoupling platform motion from the touchdown.
      The main application of the finite-EI path.

   sag bend
      The lower curvature peak of a :term:`lazy-wave` cable, below the buoyant arch — a
      fatigue-critical location.

   hang-off
      The upper end of a dynamic cable at the platform, where a bend stiffener limits curvature —
      the other fatigue-critical location.

   touchdown
      The region where a line meets the seabed; the touchdown point migrates as the platform
      moves.

   buoyancy module
      Discrete floats clamped to a cable to make a :term:`section` net-buoyant; in a deck, a
      net-buoyant :term:`line type` (or the ``EQUIVALENT BUOYANCY`` block).

   clump weight
      A discrete mass on a mooring line (a ``Point3`` body or a point with ``Mass``/``Vol``) that
      shapes the catenary and adds restoring.

   snap load
      A sudden tension spike when a slack line goes taut; a stiff transient the implicit
      integrator handles at large ``dt`` (:doc:`validation`).

   effective tension
      The OrcaFlex tension convention CableDyn reports, :math:`T_e = T_w + (P_oA_o - P_iA_i)`.
      With buoyancy applied as a distributed load it is the reported axial tension; see
      :doc:`conventions`.

   EI = 0
      A :term:`line type` with zero bending stiffness — routes to the positions-only cable path
      (chains, wire, taut synthetic moorings).

   cubic-Hermite element
      CableDyn's finite-EI (``EI > 0``) bending element: position + material tangent per node,
      :math:`C^1` centreline, exact curvature, no rotation DOFs. See :doc:`solver_paths`.

   Cosserat rod
      The secondary finite-EI element with SO(3) rotation DOFs; not part of the validated
      product. See :doc:`solver_paths`.

   generalised-alpha
      The implicit time integrator of :ref:`Chung & Hulbert (1993) <ref-chung1993>`, with
      tunable high-frequency dissipation set by the :term:`spectral radius`. See :doc:`theory`.

   spectral radius
      The generalised-α dissipation parameter :math:`\rho_\infty` (deck option ``rhoInf``);
      see :doc:`conventions` for its range and defaults.

   load continuation
      Applying the external load (or ``EI`` and buoyancy on the bending path) in stages and
      solving a Newton problem at each stage, from the seed to the full equilibrium. The static
      solve first tries Newton at the full load; continuation in ``EI`` is the default route of
      the bending path and load continuation the fallback of the cable path. The result is a
      true equilibrium, not a dynamic relaxation. See :doc:`theory`.

   Morison
      The semi-empirical hydrodynamic load model (drag + inertia by section-relative flow); the
      coefficients ``Cd_n``, ``Cd_t``, ``Ca_n``, ``Ca_t`` on a :term:`line type`.

   Froude-Krylov
      The load from the undisturbed wave pressure field, driven by the wave fluid acceleration.

   added mass
      The inertial reaction of the surrounding fluid to line acceleration (``Ca`` coefficients).

   Wheeler stretching
      A kinematics correction that evaluates linear-wave kinematics at a stretched elevation so
      that the fields extend to the instantaneous free surface; see :doc:`theory`.

   JONSWAP
      A standard irregular-sea wave spectrum (deck ``jonswap Hs Tp gamma dir waves``); other
      spectra are listed in :doc:`theory`.

   WaterKin
      A MoorDyn-F-compatible external water-kinematics file. Current and wave modes are
      independent; route ownership and supported combinations are listed in :doc:`capabilities`.

   viscoelastic rope
      A synthetic rope whose slow and dynamic axial responses differ. CableDyn models it as a
      series-Kelvin solid (MoorDyn ``ElasticMod`` 2/3) with a committed internal state; see
      :doc:`theory`.

   Syrope
      The polyester working-curve constitutive model selected with a ``SYROPE:`` ``EA`` token. It
      carries a slow-strain and a running-maximum-tension history that is committed with every
      step and rolled back with a failed step.

   original working curve
      The Syrope OWC table relating strain and tension before history-dependent modification.

   fail closed
      Reject an unsupported, ambiguous, non-finite, or inconsistent request with a named error
      instead of silently omitting or approximating the requested physics.

   coupling boundary
      The single kinematics-in / loads-out interface every caller uses; the reason one solver
      core serves the driver, OpenFAST, and CFD identically. See :doc:`coupling_boundary`.

   CompMooring = 5
      The setting in the ``.fst`` file of OpenFAST (maintained by NLR, the National Laboratory of
      the Rockies, formerly NREL) that selects CableDyn as the mooring/cable module (stock
      MoorDyn is ``= 3``). See :doc:`coupling`.

   FOWT
      Floating offshore wind turbine — CableDyn's application domain.

   VolturnUS-S
      The UMaine semi-submersible platform for the IEA-15MW turbine; the reference platform of
      the validation cases (:doc:`validation`).
