.. SPDX-License-Identifier: Apache-2.0

Conventions
===========

This chapter is the single source of truth for units, frames, sign rules, tension
definitions, and the seabed and hydrodynamic reference quantities. Other pages link here
rather than restating these rules; where any other page, code comment, or deck disagrees with
this chapter, this chapter wins and the other text is in error.

CableDyn follows the input/output conventions of OrcaFlex by Orcina (frames, sign rules,
angle definitions, and effective tension), checked against OrcaFlex 11.6d, the version used for every
OrcaFlex comparison in :doc:`validation`, so results can be compared with OrcaFlex directly, while
decks use the MoorDyn v2 vocabulary of the ecosystem of OpenFAST (maintained by NLR, the National
Laboratory of the Rockies, formerly NREL). The solver itself is CableDyn's own position-based
finite-element formulation (:doc:`theory`).

Units
-----

All input and output is SI; there are no unit keywords and no implicit scaling. Deck angles
are in degrees.

.. list-table::
   :header-rows: 1
   :widths: 30 18 52

   * - Quantity
     - Unit
     - Notes
   * - Length, position, diameter
     - m
     -
   * - Time
     - s
     -
   * - Mass per unit length ``MassDenInAir``
     - kg/m
     - dry mass per unstretched metre
   * - Force, tension
     - N
     - ``FairTen`` / ``AnchTen`` and all tension channels
   * - Axial stiffness ``EA``
     - N
     - :math:`T = EA\,\varepsilon`
   * - Bending stiffness ``EI``
     - N·m²
     - ``0`` selects the ``EI = 0`` cable path
   * - Axial damping ``BA``
     - N·s
     - a negative value is a damping ratio :math:`-\zeta` (dimensionless) of each element's axial
       mode, so the damping of the line's own axial modes depends on the mesh; give ``BA`` in
       N·s for mesh-independent damping (see :doc:`theory`)
   * - End-connection stiffness
     - N·m/rad
     - ``END CONNECTIONS`` table
   * - Curvature
     - 1/m
     -
   * - Bending moment
     - N·m
     -
   * - Water density ``rhoW``
     - kg/m³
     - default 1025
   * - Gravity ``g``
     - m/s²
     - default 9.80665
   * - Seabed stiffness ``kBot``
     - Pa/m (N/m³)
     - per unit contact area; default :math:`1.0\times10^{5}`
   * - Seabed damping ``cBot``
     - Pa·s/m (N·s/m³)
     - per unit contact area; default :math:`1.0\times10^{4}`
   * - Friction coefficient ``frictionMu``
     - —
     - dimensionless
   * - Point/body drag area ``CdA``
     - m²
     - drag coefficient times reference area
   * - Point/body displaced volume ``Vol``
     - m³
     -

Internally the solvers scale residuals by representative force levels for conditioning; this
is invisible at the deck and results boundary.

Global frame
------------

- Global axes are **right-handed** with :math:`+z` **pointing up**.
- The **still-water level is** :math:`z = 0`.
- A flat **seabed is the plane** :math:`z = -d`, where :math:`d` is the water depth
  (``WtrDpth``). A deck without ``WtrDpth`` or a bathymetry file has no seabed contact.
  A bathymetry file gives positive depths :math:`d(x, y)` and the floor
  :math:`z_\text{floor}(x, y) = -d(x, y)`.
- **Gravity acts in** :math:`-z`; buoyancy acts in :math:`+z`.
- **Environmental directions** (waves) give the direction the field **travels toward**,
  measured in the horizontal plane from :math:`+x` toward :math:`+y`. A current is supplied
  as a velocity vector, so its direction is explicit.

Sign conventions
----------------

- **Tension is positive** for a line under tensile axial force, i.e. axial strain
  :math:`\varepsilon > 0`.
- **Loads returned to a coupled object** (a fairlead, a body, a C-API or OpenFAST coupled
  point) are the force **exerted by the cable on the object**, in the global frame. A hanging
  line therefore pulls its fairlead downward and outward. These loads include the line's own
  inertia and hydrodynamic reaction at the coupled node.
- **Seabed penetration** is :math:`g = z_\text{floor} - z` (positive below the floor); the
  normal reaction acts in :math:`+z` on a level floor, and along the upward surface normal on a
  sloped bathymetry (:doc:`theory`).
- **Rotations** are right-handed about their axis.
- **Torque** on a line with torsion is positive for a right-handed twist of End B relative to
  End A (see `Torsion signs`_).

Line topology and arc length
----------------------------

- A line runs from **End A to End B**. Arc length :math:`s` is measured along the unstretched
  line from :math:`s = 0` at End A to :math:`s = L` at End B.
- A line is built from one or more **sections** listed A → B; each names a line type, a length,
  and a segment count, so mesh density may vary section to section. Section boundaries are
  nodes.
- **Role contract:** End A is the **fairlead / top** end (``Coupled``, ``Vessel``, or a body
  attachment) and End B is the **anchor / lower** end, matching OrcaFlex. A held line whose End A
  lies below End B fails closed.
- Output tangents point from End A toward End B.

Tension definitions
-------------------

- **Wall tension** is the axial force carried by the line wall, :math:`T_w = EA\,\varepsilon`
  for a member without internal or external pressure effects.
- **Effective tension** follows OrcaFlex:
  :math:`T_e = T_w + (P_o A_o - P_i A_i)`, where :math:`P_o, P_i` are the external and internal
  pressures and :math:`A_o, A_i` the external and internal cross-section areas.
- CableDyn models lines as solid members with no internal contents, and applies buoyancy as a
  distributed load (the Archimedes resultant of the pressure field), not as a pressure term in
  the tension. Under this convention the **reported tension is the effective tension**,
  :math:`T_e = EA\,\varepsilon` plus any axial damping or constitutive-state contribution on an
  ``EI = 0`` line, and the axial component :math:`\mathbf{F}\cdot\mathbf{t}` of the section
  force recovered from nodal equilibrium on a finite-EI line, which differs from
  :math:`EA\,\varepsilon` by :math:`EI\kappa^2` (:ref:`theory-output-recovery`). This is the
  quantity in the interior node tension channels, and the quantity compared with OrcaFlex
  effective tension in :doc:`validation`. On an ``EI = 0`` line node tensions are segment
  tensions, the mean of the two neighbouring element tensions, like OrcaFlex mid-segment tension.
  The continuous element field :math:`EA\,\varepsilon` of a finite-EI line is reported
  separately in ``.elements.out``. ``FairTen``, ``AnchTen``, and the end-node
  tension channels report the line-end force instead: the actual force on the attachment, the
  end element force (axial damping included) plus the end node's share of weight, seabed
  contact, and drag at the actual velocity, without the end node's inertia (:doc:`outputs`).
- Pressurised flooded-member (riser) effective tension with an inner diameter, contents, and a
  Poisson-ratio wall correction is not modelled.

Angles at line ends
-------------------

- **Declination** :math:`D` is measured from :math:`+z` (:math:`0^\circ` up,
  :math:`90^\circ` horizontal, :math:`180^\circ` down). ``FairDecl`` / ``AnchDecl`` report the
  declination of the End-A→End-B tangent; ``FairAngle`` / ``AnchAngle`` are identical aliases.
- **Inclination** ``FairIncl`` / ``AnchIncl`` is the signed angle below the horizontal,
  :math:`D - 90^\circ`: zero is horizontal, positive is downward, negative is upward.
- **Azimuth** is measured in the horizontal plane from :math:`+x` toward :math:`+y`. A direction
  with azimuth :math:`A` and declination :math:`D` is the unit vector
  :math:`(\sin D\cos A,\ \sin D\sin A,\ \cos D)`.
- An ``END CONNECTIONS`` reference direction (``EzX EzY EzZ``) is a vector along the
  End-A→End-B tangent; at a coupled end it is stored in the supporting body's frame and rotates
  with it.

Torsion signs
-------------

These apply to a finite-EI line solved in torsion: restrained at both ends, or at one end with
the other free to twist (:doc:`driver_format`). On a line free at one end the free end's
``Pretwist`` is not used (0), :math:`\Phi` is the restrained end's alone, and ``Twist<L>``
keeps its sign, the turn of End B relative to End A about the End A → End B tangent: a free
End B turns by ``+Twist<L>`` against End A's frame carried along the line, a free End A by
``−Twist<L>`` against End B's.

- The end frame of each end is its direction ``Ez`` (End A → End B) and its reference normal
  ``Nx``, in the frame of ``Ez``. ``Pretwist`` rolls the end frame about ``Ez`` by a right-handed
  angle, and the imposed twist is :math:`\Phi = \text{Pretwist}_B - \text{Pretwist}_A`. A
  ``motionFile`` roll turns the line's moving end right-handed about the tangent pointing into
  the line from that end, and enters with a minus sign,
  :math:`\Phi = \text{Pretwist}_B - \text{Pretwist}_A - \text{roll}`, whichever end moves. At
  End A this is a right-handed rotation about ``Ez``, as of a body or vessel carrying End A; at
  End B (a deck listing the anchor as End A) it is about ``−Ez``, the opposite sense to
  ``Pretwist`` (B).
- **Torque is positive** for a right-handed twist of End B relative to End A about the End A →
  End B tangent: the internal twisting moment :math:`GJ` times the twist rate, with arc length
  from End A, as OrcaFlex's ``Torque``. Reversing a line (swapping its ends) keeps the sign of
  the torque: the parser negates and swaps the pretwists, and :math:`\Phi` is unchanged.
- **Twist** channels are in degrees: ``Twist<L>N<J>`` is the cable's own twist from End A to
  node ``J``, ``Twist<L>`` the total :math:`\Phi - \Theta` with the end-spring windup. OrcaFlex
  reports the twist rate in deg/m and end twisting stiffness in kN·m/deg; CableDyn's
  ``TorsStiffness`` is in N·m/rad.
- The geometric twist :math:`\Theta` is the angle about the End B direction, right-handed, from
  the End B normal to the End A normal transported along the line. It is zero for a line in a
  plane whose two normals are perpendicular to that plane.

Orientation angles
------------------

Two Euler sequences are used, and they are deliberately different.

- **Rigid6 bodies** (``BODIES`` attitude columns, ``Body<N>R{x,y,z}`` outputs) use the intrinsic
  x-y'-z'' sequence, :math:`\mathbf{R} = \mathbf{R}_x(r_1)\,\mathbf{R}_y(r_2)\,\mathbf{R}_z(r_3)`
  about the body axes, in degrees.
- **Prescribed vessel motion** (``vesselMotion``, ``vesselRAO``) uses the OrcaFlex vessel
  convention :math:`\mathbf{R} = \mathbf{R}_z(\psi)\,\mathbf{R}_y(\theta)\,\mathbf{R}_x(\phi)`
  (roll :math:`\phi`, pitch :math:`\theta`, yaw :math:`\psi`), the intrinsic z-y'-x'' sequence.

Both are right-handed rotations from the object frame to the global frame.

Seabed
------

- **Normal stiffness per node** is :math:`k_{n,i} = k_\text{Bot}\,\tfrac{1}{2}\left(d_{i-1}L_{0,i-1} + d_i L_{0,i}\right)`,
  the node's tributary contact area: half of each adjacent element's line-type diameter
  :math:`d` times unstretched length :math:`L_0` (an end node has one adjacent element). The
  nodal stiffnesses sum to :math:`k_\text{Bot}\sum d\,L_0`. ``kBot`` is therefore a stiffness per
  unit contact area.
- **Normal damping per node** is :math:`c_{n,i} = k_{n,i}\,c_\text{Bot}/k_\text{Bot}`, with the same
  tributary area. It acts only while the node moves downward into the bed.
- **Rigid rods** use the same per-area law along their length. The rod is split into
  :math:`n = \max(20, \text{NumSegs})` equal segments, and the :math:`n + 1` stations (both ends
  and the interior points) carry :math:`k = k_\text{Bot}\,d\,\Delta l` and
  :math:`c = c_\text{Bot}\,d\,\Delta l`, with :math:`\Delta l = L/n` inside and :math:`L/(2n)`
  at the ends. Their moments about the rod centre are included.
- **Rigid6 bodies** declare no contact footprint. The reference point carries
  :math:`k = k_\text{Bot}\cdot 1\,\text{m}^2` [N/m] and :math:`c = c_\text{Bot}\cdot 1\,\text{m}^2`
  [N·s/m] (a fixed 1 m² reference area). MoorDyn Bodies have no seabed contact.
- **Friction** on a line node is a stick-slip spring on the horizontal motion: the nodal
  normal stiffness :math:`k_{n,i}` to an anchor, capped at :math:`\mu` times the total normal
  reaction (spring plus damper). It is isotropic by default (``frictionMu``);
  ``frictionMuAxial`` and ``frictionMuLateral`` (the OrcaFlex axial and normal coefficients)
  make the capacity depend on the slip direction relative to the line (:doc:`theory`). It holds
  its force at rest, and in a deck current the static solve includes it. Rigid rods and Rigid6
  bodies use isotropic Coulomb friction on the horizontal velocity with the lateral coefficient,
  regularised over :math:`10^{-3}` m/s and bounded the same way. Friction requires a dynamic run
  with a declared seabed.
- The contact law, its touchdown smoothing, and the friction laws are in :doc:`theory`.

Hydrodynamic reference quantities
---------------------------------

For a line type of hydrodynamic diameter :math:`d` (the ``Diam`` column), per unit length:

.. list-table::
   :header-rows: 1
   :widths: 34 30 36

   * - Term
     - Reference quantity
     - Coefficient
   * - Normal drag
     - projected width :math:`d`
     - ``Cd_n``
   * - Tangential drag
     - wetted perimeter :math:`\pi d`
     - ``Cd_t``
   * - Normal / tangential added mass
     - displaced area :math:`A = \pi d^2/4`
     - ``Ca_n`` / ``Ca_t``
   * - Froude–Krylov plus fluid inertia
     - displaced area :math:`A = \pi d^2/4`
     - :math:`1 + C_{a,n}`, :math:`1 + C_{a,t}`
   * - Buoyancy
     - displaced area :math:`A = \pi d^2/4`
     - —

Point and body objects use the drag area ``CdA`` and displaced volume ``Vol`` instead. The
Morison formulas are in :doc:`theory`.

Time integration parameter
--------------------------

``rhoInf`` is the generalised-α spectral radius at infinite frequency,
:math:`\rho_\infty \in [0, 1]`: :math:`1` is non-dissipative and smaller values damp
high-frequency content more strongly. The deck and OpenFAST routes default to
:math:`\rho_\infty = 0.4`; the low-level library configuration used directly through the
Fortran API defaults to :math:`0.8`. The integrator is defined in :doc:`theory`.

Precision and finiteness
------------------------

Computation is in IEEE double precision (Fortran ``SELECTED_REAL_KIND(15, 307)``).
**All accepted numeric input must be finite**: NaN or infinite values fail closed at
validation instead of propagating into a solve or an output file.
