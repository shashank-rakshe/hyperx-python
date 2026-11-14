! File: src/CableDyn_HermiteCableStatic.f90
! SPDX-License-Identifier: Apache-2.0
! Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
MODULE CableDyn_HermiteCableStatic
  !! Finite-EI static equilibrium of a single line built from cubic-Hermite
  !! bending-cable elements (CableDyn_HermiteCable). The line is a chain of
  !! 2-node elements sharing interior nodes; each node carries [r(3), m(3)] with
  !! m = dr/ds, so the global DOF count is 6*n_nodes.
  !!
  !! Equilibrium R(q) = f_int(q) - f_ext(q) = 0 is solved by a damped Newton
  !! iteration with EI load continuation. External loads are:
  !!   * distributed submerged self-weight w (N/m, signed: > 0 net-heavy pulls
  !!     -z, < 0 net-buoyant pushes +z), applied as the CONSISTENT cubic-Hermite
  !!     generalized load on the z translation AND tangent DOFs (w l0/2 on each
  !!     end r_z, +/- w l0^2/12 on the end m_z). A lumped translation-only load
  !!     drops the tangent terms and can leave a both-ends-position-fixed span
  !!     spuriously straight;
  !!   * a penalty seabed reaction on each node: the C1-blended nodal law along the local
  !!     floor normal (x, y and z) at the normal penetration (CD_Seabed_Normal_Contact),
  !!     or the scalar k_n times the node's tributary length;
  !!   * optionally, above a free surface, the displaced-water buoyancy that the
  !!     submerged weight w assumes, restored on the dry part of each element;
  !!   * optionally, the steady-current drag, seabed friction and rotational end
  !!     connections.
  !! The tangent uses the closed-form element Kt plus the derivatives of these loads
  !! (the waterline-crossing derivative of the dry-part load among them); the self-weight
  !! generalized load is configuration-independent so it adds nothing to K.
  !!
  !! This is the finite-EI power-cable / lazy-wave static path. Unlike the Cosserat
  !! finite-EI solve it has no rotation DOFs, so it neither leaves the |theta| < pi
  !! chart nor suffers the rotational-vs-axial conditioning split; the bending
  !! stiffness enters as a well-scaled block of the position/tangent tangent.
  USE CableDyn_Precision, ONLY: wp, CD_ZERO, CD_ONE, CD_All_Finite, CD_Is_Finite
  USE CableDyn_FatalReport, ONLY: CD_Fatal_Thread_Init
  USE CableDyn_HermiteCable, ONLY: CD_HermiteCable_Element, CD_HermiteCable_Curvature, &
                                   CD_HermiteCable_Peak_Curvature, &
                                   CD_HermiteCable_Axial_Resultant, &
                                   CD_HermiteCable_Axial_Resultant_Range, CD_HermiteCable_Dry_Buoyancy, &
                                   CD_HermiteCable_Shapes, CD_HCABLE_OK
  USE CableDyn_Linalg, ONLY: CD_Solve_Banded, CD_Solve_Banded_Refined, CD_LINALG_OK
  USE CableDyn_EndConnection, ONLY: CD_EndConn_Spring, CD_EndConn_Basis, CD_EndConn_Project, &
                                    CD_ENDCONN_OK, CD_ENDCONN_PINNED, CD_ENDCONN_FINITE, &
                                    CD_ENDCONN_RIGID
  USE CableDyn_SeabedContact, ONLY: CD_Seabed_Normal_Law, CD_SEABED_CONTACT_BLEND, CD_Seabed_Friction_Spring, &
                                    CD_Seabed_Friction_Aniso, CD_Seabed_Friction_Mu_Dir, CD_FRICTION_SPRING, &
                                    CD_Seabed_Normal_Contact, CD_Seabed_End_Support, CD_Seabed_End_Element_Share
  USE CableDyn_Bathymetry, ONLY: CD_BathymetryType, CD_Bathymetry_Is_Initialized, &
                                 CD_Bathymetry_Floor, CD_Bathymetry_Floor_Gradient, CD_BATHY_OK, &
                                 CD_Bathymetry_Rotate_Curvature
  USE CableDyn_HermiteCableDynamic, ONLY: CD_HermiteCable_Drag_Element, CD_HCDYN_OK
  USE CableDyn_Static, ONLY: CD_Static_As_Laid_Reference, CD_STATIC_OK
  USE CableDyn_Hydro, ONLY: CD_Current_Profile_Velocity, CD_CurrentGridType, CD_Current_Grid_Velocity, &
                            CD_Current_Profile_Gradient, CD_Current_Grid_Gradient, CD_HYDRO_OK
  USE CableDyn_HermiteTorsion, ONLY: CD_HermiteTorsionType, CD_HermiteTorsion_Line, CD_HermiteTorsion_Unwrap, &
                                     CD_HermiteTorsion_Coupling_Twist, &
                                     CD_HermiteTorsion_Accept, CD_HermiteTorsion_Compliance, &
                                     CD_HermiteTorsion_Validate, CD_HermiteTorsion_Bordered_Solve, &
                                     CD_HermiteTorsion_Inertia, CD_HermiteTorsion_Lowest_Mode, CD_HTORS_OK, &
                                     CD_HTORS_KBAND, CD_HTORS_MAX_STEP, CD_HTORS_ZERO_MODE_TOL, CD_HTORS_PI, &
                                     CD_HTORS_UNRELIABLE, CD_HTORS_MAX_TWIST
!$ USE OMP_LIB, ONLY: omp_get_max_threads, omp_in_parallel
  IMPLICIT NONE
  PRIVATE

  PUBLIC :: CD_HermiteCable_Static_Solve
  PUBLIC :: CD_HermiteCable_Static_Solve_Continuation
  PUBLIC :: CD_HermiteCable_Branch_Audit
  PUBLIC :: CD_HermiteCable_Static_Solve_Sequenced
  PUBLIC :: CD_HermiteCable_Sequence_Coarse_Max_Length
  PUBLIC :: CD_HermiteCable_Trivial_Seed
  PUBLIC :: CD_HermiteCable_Resolution_Metrics
  PUBLIC :: CD_HermiteCable_Refine_Mesh
  PUBLIC :: CD_HermiteCable_Prolong_Arc
  PUBLIC :: CD_HermiteCable_Static_Solve_AutoMesh
  PUBLIC :: CD_HermiteCable_Current_Load
  PUBLIC :: CD_HermiteCable_Friction_Anchors, CD_HermiteCable_Friction_Reference, CD_HermiteCable_As_Laid_Offsets
  PUBLIC :: CD_HermiteCable_Mean_Axial_Extremes
  PUBLIC :: CD_HermiteCable_Kink_Advice, CD_HermiteCable_Element_Ratio
  PUBLIC :: CD_Arclength_Dot, CD_Arclength_Unit_Tangent, CD_Arclength_Bordered_Update
  INTEGER, PARAMETER, PUBLIC :: CD_HCSTAT_OK = 0, CD_HCSTAT_BADINPUT = 1, CD_HCSTAT_NOCONVERGE = 2

  ! Finite-EI mesh-resolution diagnosis of a converged static IC. A cubic-Hermite element
  ! resolves the curvature field only where it spans a small fraction of a bending wavelength,
  ! i.e. where h*kappa << 1; a lazy-wave arch or a touchdown transition discretised too coarsely
  ! carries a large h*kappa and can stall the subsequent dynamic Newton. These metrics are the
  ! preflight trigger for the adaptive mesh policy and the fields the finite-EI preflight
  ! report prints.
  TYPE, PUBLIC :: CD_HermiteResolutionType
    REAL(wp) :: h_kappa_peak = CD_ZERO    !! max over elements of l0(e) * peak-sampled |kappa| (dimensionless)
    INTEGER :: h_kappa_elem = 0           !! element index carrying h_kappa_peak
    REAL(wp) :: kappa_peak = CD_ZERO      !! max sampled element |curvature| [1/m]
    REAL(wp) :: curv_jump_peak = CD_ZERO  !! max element-to-element |kappa| step [1/m]
    REAL(wp) :: axial_min = CD_ZERO        !! continuous minimum signed axial resultant [N]
    REAL(wp) :: axial_min_xi = CD_ZERO     !! station of axial_min within axial_min_elem
    REAL(wp) :: axial_strain_min = CD_ZERO !! minimum continuous axial strain N/EA [-]
    REAL(wp) :: axial_strain_min_resultant = CD_ZERO !! resultant at axial_strain_min [N]
    REAL(wp) :: axial_strain_min_xi = CD_ZERO !! station of axial_strain_min within its element
    REAL(wp) :: axial_tolerance = CD_ZERO  !! local force tolerance at axial_strain_min [N]
    INTEGER :: axial_min_elem = 0          !! element carrying axial_min
    INTEGER :: axial_strain_min_elem = 0   !! element carrying axial_strain_min
    LOGICAL :: axial_compression = .FALSE. !! some element lies below the local strain tolerance
    REAL(wp) :: axial_violation = CD_ZERO  !! max over elements of -(min resultant)/tolerance (> 1: compression)
    INTEGER :: n_contact = 0              !! nodes within contact_band of the seabed
    INTEGER :: n_islands = 0              !! contiguous contact runs (physical multi-island contact is allowed)
    LOGICAL :: contact_chatter = .FALSE.  !! isolated interior contact/gap node: topology is mesh-scale
    REAL(wp) :: hop_axial = CD_ZERO       !! signed axial resultant at the first element boundary [N]
    REAL(wp) :: end_axial = CD_ZERO       !! signed axial resultant at the last element boundary [N]
    REAL(wp) :: hop_boundary_ratio = CD_ZERO !! h/sqrt(EI/T) at the first element boundary
    REAL(wp) :: end_boundary_ratio = CD_ZERO !! h/sqrt(EI/T) at the last element boundary
    REAL(wp) :: boundary_ratio_peak = CD_ZERO !! maximum end boundary-layer resolution ratio
    LOGICAL :: boundary_unresolved = .FALSE. !! boundary_ratio_peak exceeds the default target
    INTEGER :: rec_scale = 1              !! recommended global refinement factor (power of two)
    LOGICAL :: fragile = .FALSE.          !! curvature, boundary-layer or contact-topology screen fails
  END TYPE CD_HermiteResolutionType

  ! Default resolution target for h_kappa_peak and the cap on the recommended refinement factor;
  ! callers may pass their own target.
  REAL(wp), PARAMETER, PUBLIC :: CD_HC_HKAPPA_TARGET = 0.12_wp
  ! Element count beyond which the automatic global refinement stops (its polish cost grows
  ! with the mesh; the unmet accuracy target is reported, not refined without bound).
  INTEGER, PARAMETER :: AUTO_MAX_ELEMENTS = 8192
  REAL(wp), PARAMETER, PUBLIC :: CD_HC_BOUNDARY_TARGET = 1.0_wp
  REAL(wp), PARAMETER :: CD_HC_AXIAL_STRAIN_TOL = 2.0e-6_wp
  INTEGER, PARAMETER, PUBLIC :: CD_HC_REFINE_CAP = 16
  ! A converged static state with more than this much centreline rotation concentrated
  ! in one element is not a resolved finite-EI branch. This is deliberately looser than
  ! the adaptive accuracy target above: it is a safety gate against accepting a numerical
  ! fold as an equilibrium, not an automatic mesh-accuracy claim.
  REAL(wp), PARAMETER, PUBLIC :: CD_HC_KINK_LIMIT = 0.7_wp
  ! Compression that is significant relative to the line's own tension level. A cable
  ! carries its load in tension; a converged static state whose continuous signed axial
  ! resultant falls below -CD_HC_COMPRESSION_REL_TOL * (peak tension) is either an
  ! unresolved axial oscillation or a compressed (strut/fold) branch. The absolute strain
  ! band CD_HC_AXIAL_STRAIN_TOL alone is not tension-relative: for a stiff EA it can exceed
  ! the peak tension of a light line.
  REAL(wp), PARAMETER, PUBLIC :: CD_HC_COMPRESSION_REL_TOL = 1.0e-3_wp
  ! Round-off floor of the axial resultant EA*(|r'| - 1), as a strain.
  REAL(wp), PARAMETER :: CD_HC_AXIAL_ROUNDOFF = 1.0e-10_wp
  ! Compression screens of CD_HermiteCable_Resolution_Metrics (compression_mode):
  !   STRAIN   -- element e is compressive below -CD_HC_AXIAL_STRAIN_TOL*EA(e) (default);
  !   RELATIVE -- below -max(CD_HC_COMPRESSION_REL_TOL*peak tension, round-off*max EA),
  !               the tension-relative criterion of the physical-branch audit;
  !   STRICT   -- the tighter of the two (a strain band can exceed the peak tension of a
  !               light line on a stiff EA; a relative band can exceed the strain band of a
  !               heavily loaded soft section). It takes the peak tension pointwise and the
  !               strain band from the centre element's EA, whereas the branch audit
  !               (CD_HermiteCable_Branch_Audit) takes the element-mean peak and the
  !               length-weighted EA of the three-element window;
  !   OSCILLATION -- below -max(CD_HC_OSCILLATION_REL_TOL*peak tension, round-off*max EA):
  !               the pointwise axial oscillation that a coarse stiff-EA Hermite mesh shows
  !               in tight bends and at contact nodes (an accuracy screen, not a branch test).
  INTEGER, PARAMETER, PUBLIC :: CD_HC_COMPRESSION_STRAIN = 0, CD_HC_COMPRESSION_RELATIVE = 1, &
                                CD_HC_COMPRESSION_STRICT = 2, CD_HC_COMPRESSION_OSCILLATION = 3
  REAL(wp), PARAMETER, PUBLIC :: CD_HC_OSCILLATION_REL_TOL = 0.1_wp

  ! Post-solve physical-branch audit of a converged static line (see
  ! CD_HermiteCable_Branch_Audit). failed_check identifies the first failed criterion.
  INTEGER, PARAMETER, PUBLIC :: CD_HC_AUDIT_PASS = 0, CD_HC_AUDIT_BACKTRACK = 1, &
                                CD_HC_AUDIT_COMPRESSION = 2, CD_HC_AUDIT_KINK = 3
  ! Steady current acting on a finite-EI line at rest (optional argument current of the
  ! static solvers): the Morison drag of the relative velocity u_f - 0 on every element,
  ! through CD_HermiteCable_Drag_Element with the element fluid velocity taken as the mean
  ! of the current at its two nodes -- the held-field drag of the dynamic path. The current
  ! is uniform (velocity), a depth profile (profile_z, profile_velocity) sampled at the
  ! iterate's node elevations, or a current grid (grid, MoorDyn-C Currents 2 and 5) sampled at
  ! the iterate's node positions at t = 0, the static start. frame_cs = (cos, sin) rotates the
  ! global current into the solve frame (global x = c xl - s yl, y = s xl + c yl), and the solve
  ! frame's node positions, shifted by origin (the solve frame's horizontal origin in the turned
  ! frame, where a solve translates it), into the global ones the grid is sampled at. The section properties are given
  ! per reference-arc interval (arc_end, the cumulative rest length at each interval end,
  ! with diam/cdn/cdt), so a refined or coarsened mesh of the same line looks them up by
  ! its element midpoints. load_factor scales the drag load (a continuation parameter; 1 is
  ! the physical current).
  ! Static seabed friction (CD_Seabed_Friction_Spring at each node in contact): a
  ! horizontal spring of the nodal normal stiffness from the node to its reference
  ! position, capped at mu times the normal contact force. The reference is a profile
  ! along the unstretched arc length (ref_s ascending; ref_xy(1:2, :) the solve-frame
  ! offsets from node 1, the held first end), interpolated at each node, so it survives
  ! mesh refinement and a translated solve origin: the as-laid position of the line, which
  ! is instead rebuilt on the mesh itself when its lay is given (laid_on_mesh, below).
  ! frozen_capacity (optional, one entry per node of the solved mesh) holds the capacities
  ! fixed: the springs are then conservative (the energy-minimising step applies), as the
  ! frozen drag of a fixed-point pass.
  ! mu_axial > 0 (and different from mu) makes the friction anisotropic: mu is then the
  ! lateral coefficient and mu_axial the one along the horizontal nodal tangent
  ! (CD_Seabed_Friction_Aniso); the frozen capacities then carry the direction factor.
  TYPE, PUBLIC :: CD_HermiteStaticFrictionType
    REAL(wp) :: mu = 0.0_wp
    REAL(wp) :: mu_axial = -1.0_wp
    REAL(wp), ALLOCATABLE :: ref_s(:), ref_xy(:, :)
    REAL(wp), ALLOCATABLE :: frozen_capacity(:)
    ! the reference is the as-laid position (staticsFriction asLaid; otherwise the still-water
    ! equilibrium of a current deck)
    LOGICAL :: as_laid = .FALSE.
    ! The lay of an as-laid reference that is rebuilt on every mesh it is applied to
    ! (laid_on_mesh, CD_HermiteCable_As_Laid_Offsets): the nodes of a refined or coarsened
    ! mesh are laid and sink as the deck nodes are, under their own lumped weights and nodal
    ! seabed stiffnesses, which no interpolation of the deck-mesh profile gives at a section
    ! change or on a varying slope. The line is laid from laid_origin (global x, y of its
    ! lower end, node 1 or, laid_from_top, the last node) along laid_azimuth [rad, global] at
    ! laid_tension [N], over the bathymetry when laid_bathymetry; the offsets are taken from
    ! laid_node1 (global x, y of node 1) in the solve frame laid_frame_cs = (cos, sin). With
    ! laid_in_plane only the sink of the nodes leaves the vertical plane of the chord.
    LOGICAL :: laid_on_mesh = .FALSE.
    LOGICAL :: laid_from_top = .FALSE., laid_in_plane = .FALSE., laid_bathymetry = .FALSE.
    REAL(wp) :: laid_origin(2) = 0.0_wp, laid_node1(2) = 0.0_wp
    REAL(wp) :: laid_azimuth = 0.0_wp, laid_tension = 0.0_wp
    REAL(wp) :: laid_frame_cs(2) = [1.0_wp, 0.0_wp]
    ! The dry part of a laid line (laid_water_weight > 0, on a bathymetry): the nodes of a line
    ! laid within its section radius of the still-water level laid_waterline_z sink under the
    ! buoyancy the solver gives back there (CD_HermiteCable_As_Laid_Offsets). laid_water_weight
    ! is rho g [N/m^3]; the section diameter is laid_diam on the reference-arc intervals ending
    ! at laid_arc_end (cumulative rest length from node 1), so any mesh of the line looks it up.
    REAL(wp) :: laid_water_weight = 0.0_wp, laid_waterline_z = 0.0_wp
    REAL(wp), ALLOCATABLE :: laid_arc_end(:), laid_diam(:)
  END TYPE CD_HermiteStaticFrictionType

  TYPE, PUBLIC :: CD_HermiteStaticCurrentType
    REAL(wp) :: load_factor = 1.0_wp
    REAL(wp) :: rho = 1025.0_wp
    REAL(wp) :: waterline_z = 0.0_wp
    REAL(wp) :: velocity(3) = 0.0_wp
    REAL(wp) :: frame_cs(2) = [1.0_wp, 0.0_wp]
    REAL(wp) :: origin(2) = [0.0_wp, 0.0_wp]
    ! drag = .FALSE.: a zero-velocity carrier of the as-laid seabed friction in still water
    LOGICAL :: drag = .TRUE.
    REAL(wp), ALLOCATABLE :: profile_z(:), profile_velocity(:, :)
    TYPE(CD_CurrentGridType), ALLOCATABLE :: grid
    REAL(wp), ALLOCATABLE :: arc_end(:), diam(:), cdn(:), cdt(:)
    ! Seabed friction held by the line against the current (allocated: active).
    TYPE(CD_HermiteStaticFrictionType), ALLOCATABLE :: friction
  END TYPE CD_HermiteStaticCurrentType

  TYPE, PUBLIC :: CD_HermiteBranchAuditType
    LOGICAL :: physical = .TRUE.            !! every criterion passed
    INTEGER :: failed_check = CD_HC_AUDIT_PASS
    REAL(wp) :: backtrack = CD_ZERO         !! length travelled against the chord heading [m]
    REAL(wp) :: backtrack_limit = CD_ZERO   !! admissible tangent reversal (sine of the angle past vertical)
    REAL(wp) :: tangent_reversal = CD_ZERO  !! largest unit-tangent component against the chord heading
    INTEGER :: backtrack_elem = 0           !! element with the largest tangent reversal
    LOGICAL :: self_contact_checked = .FALSE. !! the geometric self-contact test ran (diameters given)
    REAL(wp) :: self_gap = HUGE(1.0_wp)     !! smallest clearance between non-neighbouring parts [m]
    INTEGER :: contact_elem_a = 0, contact_elem_b = 0 !! elements carrying self_gap
    LOGICAL :: backtrack_checked = .FALSE.  !! false for a (near-)vertical chord
    REAL(wp) :: axial_min = CD_ZERO         !! minimum continuous signed axial resultant [N]
    REAL(wp) :: axial_max = CD_ZERO         !! maximum continuous signed axial resultant [N]
    REAL(wp) :: mean_axial_min = CD_ZERO    !! minimum element-mean axial force [N]
    REAL(wp) :: mean_axial_max = CD_ZERO    !! maximum element-mean axial force [N]
    REAL(wp) :: compression_limit = CD_ZERO !! compression band [N] of criterion 2
    LOGICAL :: compressed = .FALSE.         !! element-mean compression beyond compression_limit
    INTEGER :: axial_min_elem = 0           !! element carrying mean_axial_min
    REAL(wp) :: smoothed_axial_min = CD_ZERO !! minimum 3-element length-weighted mean axial force [N]
    LOGICAL :: smoothed_compressed = .FALSE. !! smoothed compression beyond compression_limit
    INTEGER :: smoothed_min_elem = 0        !! centre element of smoothed_axial_min
    REAL(wp) :: nodal_axial_min = CD_ZERO   !! minimum interior-node material axial force [N]
    INTEGER :: nodal_min_node = 0           !! interior node carrying nodal_axial_min
    REAL(wp) :: h_kappa_peak = CD_ZERO
    INTEGER :: h_kappa_elem = 0
  END TYPE CD_HermiteBranchAuditType

  ! The line is a chain of 2-node elements with 6 DOF/node in nodal order, so the
  ! global tangent couples DOFs at most 11 apart: a constant half-bandwidth known
  ! a priori. The Newton assembles DIRECTLY into LAPACK general-band storage
  ! (DGBSV layout: entry (i, j) at ab(KL_H + KU_H + 1 + i - j, j), with KL_H extra
  ! rows for the factorization fill) -- no dense tangent, no bandwidth scan.
  INTEGER, PARAMETER :: KL_H = 11, KU_H = 11
  INTEGER, PARAMETER :: I8 = SELECTED_INT_KIND(18)
  INTEGER, PARAMETER :: LDAB_H = 2*KL_H + KU_H + 1
  ! A refined full-load equilibrium can occasionally need stronger globalization after
  ! prolongation. Continue from the best full-load iterate in bounded residual-decreasing
  ! batches, without replaying EI or buoyancy continuation (which could select a different
  ! equilibrium branch). These are failure-path budgets, not physical-model parameters.
  INTEGER, PARAMETER :: MAX_FULL_LOAD_RECOVERY_PASSES = 4
  INTEGER, PARAMETER :: FULL_LOAD_BACKTRACKS = 12

  ! Trust-region-style full-Newton switch. The update takes the FULL Newton step
  ! (instead of the caller's damping factor) when the PROPOSED STEP is small (below
  ! DQ_TRUST element lengths / tangent units) and the scaled residual is not far-field
  ! (below R_TRUST). Rationale, on a net-buoyant (lazy-wave) buoyancy continuation:
  !   * The step size, not the residual, is the reliable basin indicator on a stiff
  !     net-buoyant line. A warm stage can sit at a small scaled residual while Newton
  !     proposes a large step (the tangent is soft along the arch mode and the linear
  !     prediction overshoots the nonlinear stiffening); taking that step raises the
  !     residual by orders of magnitude. Conversely a secant-predicted stage start can show
  !     an O(1) scaled residual -- a tiny O(increment^2) strain error amplified by EA into
  !     force units -- while Newton proposes a small step that is essentially exact: under
  !     fixed damping the iteration then re-proposes the same small step several times,
  !     contracting the residual by only (1 - damping) per iteration.
  !   * Small proposed steps are trustworthy (the linearization is local and any contact
  !     flip they cross is self-correcting on the next iteration); large proposed steps
  !     are not, whatever the residual says.
  ! The switch keys on the current iteration's own pre-update values, so it re-damps by
  ! itself whenever the proposed step grows back above the trust radius. Effect: warm
  ! continuation stages converge in a few full Newton iterations instead of many damped
  ! ones, reaching the same converged states.
  REAL(wp), PARAMETER :: DQ_TRUST = 1.0e-2_wp
  REAL(wp), PARAMETER :: PI_W = 3.14159265358979323846_wp
  REAL(wp), PARAMETER :: R_TRUST = 1.0_wp

CONTAINS

  SUBROUTINE CD_HermiteCable_Static_Solve(l0, EA, EI, w, seed, fixed_dofs, seabed_z, kn, &
                                          n_cont, max_iter, tol, damping, &
                                          q_out, curv_out, res_out, iters_out, ErrStat, ErrMsg, &
                                          f_nodal, n_buoy_steps, contact_kn, bathymetry, contact_frame_cs, &
                                          backtracking, axial_quadrature_order, bending_quadrature_order, &
                                          residual_history, history_count, equilibrate_linear_system, &
                                          endconn_stiffness, endconn_direction, endconn_mode, &
                                          waterline_z, dry_buoyancy, merit_line_search, pseudo_transient, &
                                          energy_minimization, stable, water_weight, current, residual_out, &
                                          tangent_out, friction, residual_unmet, torsion, energy_out, &
                                          end_share_hold, f_nodal_twist, stall_limit)
    !! Solve the finite-EI static equilibrium of a Hermite bending-cable line.
    !!
    !! l0(ne), EA(ne), EI(ne), w(ne) : per-element rest length, axial/bending stiffness,
    !!                                 and signed submerged weight per unit length.
    !! seed(6*nn)                    : initial guess [r,m] per node (nn = ne + 1).
    !! fixed_dofs(:)                  : global DOF indices held at their seed value
    !!                                 (endpoint positions, planar y DOFs, ...).
    !! seabed_z, kn                   : penalty seabed plane and stiffness (kn >= 0).
    !! n_cont                         : EI continuation steps (>= 1).
    !! max_iter, tol, damping         : Newton budget, residual tolerance, update factor.
    !!                                  The damping factor governs the far field; whenever
    !!                                  the proposed step is inside the internal trust
    !!                                  radius (DQ_TRUST, with the R_TRUST residual
    !!                                  ceiling) the update takes the full Newton step.
    !! f_nodal (optional, 6*nn)       : external generalized nodal loads, ramped with the
    !!                                  load-continuation factor: r-slot entries are point
    !!                                  forces [N]; m-slot entries are moment-like loads
    !!                                  [N.m] conjugate to the material tangent (a tip
    !!                                  bending moment). Configuration-independent, so it
    !!                                  adds nothing to K.
    !! n_buoy_steps (optional, >= 1)  : override for the internal buoyancy-load continuation
    !!                                  step count on a net-buoyant line (default 40 -- the
    !!                                  cold-seed smooth-branch tracer). Pass 1 to POLISH a
    !!                                  seed that is already on the smooth branch at full
    !!                                  buoyancy (a mesh-sequenced prolongation, or a solved
    !!                                  suspended span extended by a grounded run): the ramp
    !!                                  would otherwise re-collapse the arch 40 times per
    !!                                  solve. Ignored for net-heavy lines (always 1 step).
    !! backtracking (optional)         : require each Newton update to reduce the true
    !!                                  full-load residual, with bounded step halving.
    !!                                  Default false preserves established solve histories.
    !! endconn_stiffness (optional, 2) : linear isotropic end-bending stiffness
    !!                                  [N.m/rad] at node 1 and node nn.
    !!                                  A zero entry is a pinned end and contributes
    !!                                  nothing, so omitting the pair reproduces the
    !!                                  established free-tangent boundary exactly.
    !! endconn_direction (optional,3,2): preferred no-moment unit directions for those ends.
    !!                                  Required whenever endconn_stiffness is present.
    !!                                  The spring restrains only the tangent DIRECTION;
    !!                                  |m| (axial stretch) is left free by construction --
    !!                                  see CableDyn_EndConnection. Ramped with the same EI
    !!                                  continuation factor as the bending stiffness, so a
    !!                                  stiff connection cannot break the cold-seed ramp.
    !! endconn_mode (optional,2)       : Pinned, Finite, or Rigid. If omitted, zero/positive
    !!                                  stiffness selects Pinned/Finite for compatibility.
    !!                                  Rigid enforces the tangent direction exactly while
    !!                                  leaving its magnitude free and requires zero stiffness.
    !! waterline_z, dry_buoyancy(ne)   : optional free surface and displaced-water buoyancy
    !!   (optional, together)           rho g A per reference length [N/m, >= 0]. w is the
    !!                                  submerged weight; the part of an element above the
    !!                                  surface regains its buoyancy as an extra downward
    !!                                  load (exact dry-interval integration with the
    !!                                  waterline-crossing tangent, the same treatment as the
    !!                                  dynamic Hermite path). Omitted: fully submerged line.
    !! water_weight (optional)         : rho g of the water [N/m^3], with dry_buoyancy. The
    !!                                  section radius sqrt(dry_buoyancy/(pi water_weight))
    !!                                  then spreads the waterline crossing over the partial
    !!                                  immersion of the circular section (radius argument of
    !!                                  CD_HermiteCable_Dry_Buoyancy); omitted, the centreline
    !!                                  crossing law applies.
    !! merit_line_search (optional)    : with backtracking, accept a step on the Armijo
    !!                                  decrease of the scaled residual's squared two-norm
    !!                                  instead of a decrease of its max-norm. A max-norm
    !!                                  test can reject every useful Newton step when one
    !!                                  component transiently grows (a contact node crossing
    !!                                  the floor), stalling the iteration. Default false.
    !! pseudo_transient (optional)     : pseudo-transient continuation. Each update solves
    !!                                  (K + D/tau) dq = -R, D = |diag K| on the free DOFs,
    !!                                  and takes the full step; tau starts at 1 and grows by
    !!                                  switched evolution relaxation (tau_k+1 = tau_k *
    !!                                  |R_k-1|/|R_k|, at most tenfold per update), so the
    !!                                  iteration moves from a damped relaxation of the
    !!                                  potential toward the stable equilibrium near the seed
    !!                                  into plain Newton near convergence. Default false.
    !! energy_minimization (optional)  : trust-region Newton on the total potential energy
    !!                                  (strain energy, weight, seabed penalty, dry-part
    !!                                  buoyancy, end springs and nodal loads). Each update
    !!                                  solves (K + mu D) dq = -R, D = |diag K|, and is
    !!                                  accepted when the energy decrease is at least a tenth
    !!                                  of the quadratic model's; mu grows fourfold on a
    !!                                  rejection and shrinks on a good step. The iteration
    !!                                  can only descend, so it converges to a stable
    !!                                  equilibrium (a local energy minimum) and never to a
    !!                                  saddle such as a compressed strut. Below the
    !!                                  round-off level of the energy the scaled residual
    !!                                  norm decides acceptance. Default false.
    !! stable (optional, out)          : at the returned state, whether the tangent K on
    !!                                  the free DOFs (symmetric part) is positive definite
    !!                                  -- a stable equilibrium, a strict local minimum of
    !!                                  the potential energy. Tested by a Jacobi-scaled
    !!                                  banded Cholesky factorization. With seabed friction
    !!                                  the tangent holds each node's friction capacity at
    !!                                  its equilibrium value (the capacity's dependence on
    !!                                  the normal force is left out; see the final
    !!                                  evaluation).
    !! torsion (optional, inout)       : condensed isotropic torsion of the line (uniform torque,
    !!                                  CableDyn_HermiteTorsion), used when torsion%active.
    !!                                  The loads and EI/buoyancy stages above run without it;
    !!                                  the imposed twist is then ramped as the last load
    !!                                  stage, from the twist of that untwisted equilibrium
    !!                                  (zero torque) to torsion%phi, in steps of at most
    !!                                  pi/4 halved on a failed stage. Each Newton step adds
    !!                                  E_t = (Phi - Theta)**2/(2 C) and solves the bordered
    !!                                  system [B g; g^T -C] by Sherman-Morrison on the band
    !!                                  factor (CD_HermiteTorsion_Bordered_Solve); Theta is
    !!                                  unwrapped against the last accepted iterate and every
    !!                                  accepted iterate changes it by at most pi/2 (longer
    !!                                  steps are cut). Each converged stage is tested for
    !!                                  stability (the inertia of the tangent on the free
    !!                                  DOFs); an unstable one (above a buckling onset) is
    !!                                  left by negative-curvature descent along the lowest
    !!                                  mode and energy minimisation, unless torsion%descend
    !!                                  is false. On a converged return torsion holds the
    !!                                  accepted Theta (has_theta), the torque and the
    !!                                  stability report; any other return leaves its Theta
    !!                                  state unchanged. A re-solve with has_theta needs the
    !!                                  untwisted equilibrium within pi/2 of the stored Theta
    !!                                  (otherwise its turn count is ambiguous and the solve
    !!                                  stops by name); start a new solve with has_theta
    !!                                  false and theta_hint instead. residual_history and
    !!                                  history_count cover the untwisted stages only;
    !!                                  iters_out and res_out include the twist stages. Not
    !!                                  combined with pseudo_transient,
    !!                                  equilibrate_linear_system or tangent_out.
    !! energy_out (optional, out)      : the total potential energy of energy_minimization at
    !!                                  the returned state (with residual_out, a check that
    !!                                  the residual is its gradient).
    !! end_share_hold (optional, 2)    : shares in [0, 1] of the end elements lying on the
    !!                                  floor (node 1 end, node nn end) at which the potential
    !!                                  takes the floor-carried end moments of held ends
    !!                                  resting on the seabed; the residual keeps the shares of
    !!                                  each iterate (CD_Seabed_End_Element_Share). Omitted, an
    !!                                  energy line search holds the shares of its start.
    !! f_nodal_twist (optional, 6*nn)  : with torsion, generalized nodal loads (as f_nodal)
    !!                                  ramped with the imposed twist: none at the untwisted
    !!                                  state, the fraction of the twist continuation at each
    !!                                  stage, in full at the target Phi. The change of a load
    !!                                  that follows the line's shape (the drag of discrete
    !!                                  attachments in a current, evaluated at a twisted state)
    !!                                  then leaves the untwisted state in equilibrium under
    !!                                  f_nodal alone.
    !! stall_limit (optional, >= 1)    : max_iter becomes the cap of a long descent, which
    !!                                  stops (not converged) once stall_limit updates have
    !!                                  not brought the two-norm of the scaled residual below
    !!                                  half its value at the last such fall (the first: the
    !!                                  start), so after stall_limit updates without any. A
    !!                                  descent that is still converging is then not cut at a
    !!                                  fixed count; the norm, unlike the largest component
    !!                                  that decides convergence, does not change when the
    !!                                  line is turned.
    REAL(wp), INTENT(IN) :: l0(:), EA(:), EI(:), w(:), seed(:)
    INTEGER, INTENT(IN) :: fixed_dofs(:)
    REAL(wp), INTENT(IN) :: seabed_z, kn, tol, damping
    INTEGER, INTENT(IN) :: n_cont, max_iter
    REAL(wp), INTENT(OUT) :: q_out(:), curv_out(:), res_out
    INTEGER, INTENT(OUT) :: iters_out
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    REAL(wp), INTENT(IN), OPTIONAL :: f_nodal(:)
    INTEGER, INTENT(IN), OPTIONAL :: n_buoy_steps
    REAL(wp), INTENT(IN), OPTIONAL :: contact_kn(:), contact_frame_cs(2)
    TYPE(CD_BathymetryType), INTENT(IN), OPTIONAL :: bathymetry
    LOGICAL, INTENT(IN), OPTIONAL :: backtracking
    INTEGER, INTENT(IN), OPTIONAL :: axial_quadrature_order, bending_quadrature_order
    REAL(wp), INTENT(OUT), OPTIONAL :: residual_history(:)
    INTEGER, INTENT(OUT), OPTIONAL :: history_count
    LOGICAL, INTENT(IN), OPTIONAL :: equilibrate_linear_system
    REAL(wp), INTENT(IN), OPTIONAL :: endconn_stiffness(2), endconn_direction(3, 2)
    INTEGER, INTENT(IN), OPTIONAL :: endconn_mode(2)
    REAL(wp), INTENT(IN), OPTIONAL :: waterline_z, dry_buoyancy(:), water_weight
    TYPE(CD_HermiteStaticCurrentType), INTENT(IN), OPTIONAL :: current
    ! Residual R (6*nn) and banded tangent (LAPACK general band, 2*11+11+1 rows) at the
    ! returned state (optional), before the held DOFs are eliminated.
    REAL(wp), INTENT(OUT), OPTIONAL :: residual_out(:), tangent_out(:, :)
    LOGICAL, INTENT(IN), OPTIONAL :: merit_line_search
    LOGICAL, INTENT(IN), OPTIONAL :: pseudo_transient
    LOGICAL, INTENT(IN), OPTIONAL :: energy_minimization
    LOGICAL, INTENT(OUT), OPTIONAL :: stable
    ! Seabed friction (optional; a current's own friction component applies otherwise).
    TYPE(CD_HermiteStaticFrictionType), INTENT(IN), OPTIONAL :: friction
    ! TRUE when the solve ran to the end and failed only on the final residual (ErrStat =
    ! NOCONVERGE, "Newton did not converge"): the state is a finite best iterate a caller
    ! may continue from.
    LOGICAL, INTENT(OUT), OPTIONAL :: residual_unmet
    REAL(wp), INTENT(OUT), OPTIONAL :: energy_out
    REAL(wp), INTENT(IN), OPTIONAL :: end_share_hold(2)
    TYPE(CD_HermiteTorsionType), INTENT(INOUT), OPTIONAL :: torsion
    REAL(wp), INTENT(IN), OPTIONAL :: f_nodal_twist(:)
    INTEGER, INTENT(IN), OPTIONAL :: stall_limit

    INTEGER :: ne, nn, ndof, c, it, es, i, b, nci, n_buoy, omp_threads, axial_order, bending_order
    ! stall_limit: the residual merit at the start of an update, its value at the last halving
    ! of the norm, and the number of updates that had reached that state.
    REAL(wp) :: merit_update, merit_fall
    INTEGER :: it_fall
    REAL(wp) :: eifac, rnorm, fscale, bfac, rmerit, ptc_tau, ptc_rprev, pi_total, pi_abs, lm_mu, chord
    REAL(wp), ALLOCATABLE :: q(:), trib(:), w_cur(:), q_base(:)
    REAL(wp) :: endconn_k(2), endconn_d0(3, 2), direction_norm
    REAL(wp) :: rigid_basis(3, 3, 2), projected_tangent(3)
    INTEGER :: endconn_kind(2)
    ! Newton workspace, allocated ONCE per solve (never inside the iteration):
    ! the residual, the banded tangent, and the update direction.
    REAL(wp), ALLOCATABLE :: R(:), dq(:), ab(:, :), ab_recovery(:, :), scaled_residual(:)
    REAL(wp), ALLOCATABLE :: elem_f(:, :), elem_K(:, :, :), elem_E(:)
    INTEGER, ALLOCATABLE :: elem_es(:)
    CHARACTER(200), ALLOCATABLE :: elem_em(:)
    ! Secant-predictor history: the converged states of the two previous buoyancy
    ! stages (q_sec1 = stage b-1, q_sec2 = stage b-2).
    REAL(wp), ALLOCATABLE :: q_sec1(:), q_sec2(:)
    LOGICAL, ALLOCATABLE :: freemask(:), solve_mask(:)
    LOGICAL :: has_buoy, use_nodal_contact, use_bathymetry, use_backtracking, use_equilibration
    LOGICAL :: use_endconn, use_rigid, use_dry, dry_now, use_merit, stalled, use_ptc, use_energy
    ! Steady-current drag (optional current): per-element section data on this mesh. The
    ! drag is not a potential force, so iterations that carry it take the Newton step on
    ! the full tangent with the residual-merit line search, never the energy step.
    LOGICAL :: use_current, drag_now
    REAL(wp), ALLOCATABLE :: cur_d(:), cur_cn(:), cur_ct(:)
    ! Seabed friction: coefficient, per-node spring stiffness and reference (x, y). Like
    ! the drag it depends on the normal force, so it is carried by the Newton step.
    LOGICAL :: use_friction, fr_frozen, fr_aniso
    REAL(wp) :: fr_mu, fr_mu_a
    REAL(wp), ALLOCATABLE :: fr_k(:), fr_ref(:, :), fr_cap(:)
    ! Residual/energy-only evaluation (the energy line search needs no tangent).
    LOGICAL :: skip_tangent
    ! Stability-tangent evaluation (see the stable argument): each node's friction
    ! capacity held at its equilibrium value.
    LOGICAL :: stab_eval
    REAL(wp), ALLOCATABLE :: ab_energy(:, :), r_energy(:), q_energy(:), sym(:, :)
    ! Condensed torsion (optional torsion argument): use_tors when active, tors_on once the
    ! twist stage runs. tors_g is dTheta/dq at the last assembly (global DOFs), tors_gr the same
    ! in the rigid-end basis with held DOFs zeroed, tors_h d2Theta/dq2 (band, 23 rows),
    ! tors_v the lowest mode of an unstable tangent (descent direction).
    LOGICAL :: use_tors, tors_on, tors_have_mode, tors_descending
    REAL(wp) :: tors_c, tors_phi_cur, tors_theta_acc, tors_theta_eval, tors_mt, tors_lambda
    ! the share of f_nodal_twist the residual takes: the twist continuation's fraction
    REAL(wp) :: tors_load_frac
    REAL(wp), ALLOCATABLE :: tors_g(:), tors_gr(:), tors_h(:, :), tors_v(:), tors_rhs(:), tors_q(:), tors_gs(:)
    REAL(wp), ALLOCATABLE :: tors_grs(:), tors_gt(:)
    REAL(wp), ALLOCATABLE :: tors_rhs2(:, :)
    ! the untwisted equilibrium the twist starts from (its state, accepted Theta and Phi = Theta_0),
    ! whose inertia an unstable twist stage is compared with (untwisted_inertia)
    REAL(wp), ALLOCATABLE :: tors_q_untw(:)
    REAL(wp) :: tors_th_untw, tors_phi_untw
    REAL(wp) :: contact_cs(2), end_support(3, 2), end_floor(3), end_g(2), end_sfac
    ! Floor-carried end moments in the potential: the end element shares of the last
    ! evaluation, and the shares held (end_share_held) by an energy line search or the caller.
    REAL(wp) :: end_share_last(2), end_share_pi(2)
    LOGICAL :: end_share_held, end_share_caller
    INTEGER :: end_es
    CHARACTER(1024) :: end_em

    ErrStat = CD_HCSTAT_OK
    ErrMsg = ''
    IF (PRESENT(residual_unmet)) residual_unmet = .FALSE.
    res_out = CD_ZERO
    iters_out = 0
    IF (PRESENT(residual_out)) THEN
      IF (SIZE(residual_out) /= 6*(SIZE(l0) + 1)) THEN
        ErrStat = CD_HCSTAT_BADINPUT
        ErrMsg = 'CD_HermiteCable_Static_Solve: residual_out must have 6*n_nodes entries'; RETURN
      END IF
    END IF
    IF (PRESENT(tangent_out)) THEN
      IF (SIZE(tangent_out, 1) /= LDAB_H .OR. SIZE(tangent_out, 2) /= 6*(SIZE(l0) + 1)) THEN
        ErrStat = CD_HCSTAT_BADINPUT
        ErrMsg = 'CD_HermiteCable_Static_Solve: tangent_out must be shaped (2*11+11+1, 6*n_nodes)'; RETURN
      END IF
    END IF
    IF (PRESENT(history_count)) history_count = 0
    IF (PRESENT(residual_history)) residual_history = CD_ZERO

    ne = SIZE(l0)
    omp_threads = 1
!$  omp_threads = MIN(4, omp_get_max_threads())
!$  IF (omp_in_parallel()) omp_threads = 1
    nn = ne + 1
    ndof = 6*nn
    use_nodal_contact = PRESENT(contact_kn)
    use_bathymetry = PRESENT(bathymetry)
    use_backtracking = .FALSE.
    IF (PRESENT(backtracking)) use_backtracking = backtracking
    use_merit = .FALSE.
    IF (PRESENT(merit_line_search)) use_merit = merit_line_search
    stalled = .FALSE.
    use_ptc = .FALSE.
    IF (PRESENT(pseudo_transient)) use_ptc = pseudo_transient
    ptc_tau = CD_ONE
    ptc_rprev = CD_ZERO
    use_energy = .FALSE.
    IF (PRESENT(energy_minimization)) use_energy = energy_minimization
    skip_tangent = .FALSE.
    stab_eval = .FALSE.
    pi_total = CD_ZERO
    pi_abs = CD_ZERO
    lm_mu = CD_ZERO
    rmerit = CD_ZERO
    use_equilibration = .FALSE.
    IF (PRESENT(equilibrate_linear_system)) use_equilibration = equilibrate_linear_system
    axial_order = 4
    bending_order = 4
    IF (PRESENT(axial_quadrature_order)) axial_order = axial_quadrature_order
    IF (PRESENT(bending_quadrature_order)) bending_order = bending_quadrature_order
    contact_cs = [CD_ONE, CD_ZERO]
    use_endconn = .FALSE.
    use_rigid = .FALSE.
    endconn_k = CD_ZERO
    endconn_d0 = CD_ZERO
    endconn_kind = CD_ENDCONN_PINNED
    rigid_basis = CD_ZERO
    IF (ne < 1 .OR. SIZE(EA) /= ne .OR. SIZE(EI) /= ne .OR. SIZE(w) /= ne) THEN
      CALL fail('l0/EA/EI/w must be same length ne >= 1'); RETURN
    END IF
    IF (SIZE(seed) /= ndof .OR. SIZE(q_out) /= ndof .OR. SIZE(curv_out) /= nn) THEN
      CALL fail('seed/q_out must be 6*(ne+1); curv_out must be ne+1'); RETURN
    END IF
    IF (n_cont < 1 .OR. max_iter < 1 .OR. .NOT. CD_Is_Finite(tol) .OR. tol <= CD_ZERO .OR. &
        .NOT. CD_Is_Finite(damping) .OR. damping <= CD_ZERO .OR. damping > CD_ONE) THEN
      CALL fail('need n_cont>=1, max_iter>=1, finite tol>0, finite 0<damping<=1'); RETURN
    END IF
    IF (PRESENT(stall_limit)) THEN
      IF (stall_limit < 1) THEN
        CALL fail('need stall_limit >= 1'); RETURN
      END IF
    END IF
    IF (PRESENT(residual_history)) THEN
      IF (SIZE(residual_history) < max_iter) THEN
        CALL fail('residual_history must have at least max_iter entries'); RETURN
      END IF
    END IF
    IF (axial_order < 1 .OR. axial_order > 6 .OR. bending_order < 1 .OR. bending_order > 6) THEN
      CALL fail('quadrature orders must lie in [1,6]'); RETURN
    END IF
    IF (kn < CD_ZERO .OR. .NOT. CD_Is_Finite(kn) .OR. .NOT. CD_Is_Finite(seabed_z)) THEN
      CALL fail('kn>=0 and finite seabed_z required'); RETURN
    END IF
    IF (.NOT. CD_All_Finite(seed) .OR. .NOT. CD_All_Finite(l0) .OR. &
        .NOT. CD_All_Finite(EA) .OR. .NOT. CD_All_Finite(EI) .OR. &
        .NOT. CD_All_Finite(w)) THEN
      CALL fail('inputs must be finite'); RETURN
    END IF
    IF (ANY(l0 <= CD_ZERO) .OR. ANY(EA < CD_ZERO) .OR. ANY(EI < CD_ZERO)) THEN
      CALL fail('l0>0, EA>=0, EI>=0 required'); RETURN
    END IF
    IF (ANY(fixed_dofs < 1) .OR. ANY(fixed_dofs > ndof)) THEN
      CALL fail('fixed_dofs out of range'); RETURN
    END IF
    IF (PRESENT(f_nodal)) THEN
      IF (SIZE(f_nodal) /= ndof) THEN
        CALL fail('f_nodal must be 6*(ne+1)'); RETURN
      END IF
      IF (.NOT. CD_All_Finite(f_nodal)) THEN
        CALL fail('f_nodal must be finite'); RETURN
      END IF
    END IF
    IF (PRESENT(f_nodal_twist)) THEN
      IF (.NOT. PRESENT(torsion)) THEN
        CALL fail('f_nodal_twist needs torsion'); RETURN
      END IF
      IF (SIZE(f_nodal_twist) /= ndof) THEN
        CALL fail('f_nodal_twist must be 6*(ne+1)'); RETURN
      END IF
      IF (.NOT. CD_All_Finite(f_nodal_twist)) THEN
        CALL fail('f_nodal_twist must be finite'); RETURN
      END IF
    END IF
    IF (use_nodal_contact) THEN
      IF (SIZE(contact_kn) /= nn .OR. .NOT. CD_All_Finite(contact_kn) .OR. ANY(contact_kn <= CD_ZERO)) THEN
        CALL fail('contact_kn must be finite, positive, and have length n_nodes'); RETURN
      END IF
    END IF
    IF (use_bathymetry) THEN
      IF (.NOT. CD_Bathymetry_Is_Initialized(bathymetry)) THEN
        CALL fail('bathymetry must be initialized'); RETURN
      END IF
    END IF
    IF (PRESENT(contact_frame_cs)) THEN
      IF (.NOT. CD_All_Finite(contact_frame_cs) .OR. &
          ABS(SUM(contact_frame_cs*contact_frame_cs) - CD_ONE) > 1.0e-9_wp) THEN
        CALL fail('contact_frame_cs must be a finite unit heading'); RETURN
      END IF
      contact_cs = contact_frame_cs
    END IF
    IF (PRESENT(waterline_z) .NEQV. PRESENT(dry_buoyancy)) THEN
      CALL fail('waterline_z and dry_buoyancy must be supplied together'); RETURN
    END IF
    use_dry = PRESENT(dry_buoyancy)
    dry_now = .FALSE.
    drag_now = .FALSE.
    IF (use_dry) THEN
      IF (SIZE(dry_buoyancy) /= ne .OR. .NOT. CD_Is_Finite(waterline_z)) THEN
        CALL fail('dry_buoyancy must have length ne and waterline_z must be finite'); RETURN
      END IF
      IF (.NOT. CD_All_Finite(dry_buoyancy) .OR. ANY(dry_buoyancy < CD_ZERO)) THEN
        CALL fail('dry_buoyancy must be finite and non-negative'); RETURN
      END IF
    END IF
    IF (PRESENT(water_weight)) THEN
      IF (.NOT. use_dry .OR. .NOT. (water_weight > CD_ZERO) .OR. .NOT. CD_Is_Finite(water_weight)) THEN
        CALL fail('water_weight must be finite, positive and supplied with dry_buoyancy'); RETURN
      END IF
    END IF
    use_current = PRESENT(current)
    drag_now = .FALSE.
    IF (use_current) THEN
      CALL setup_current(es, ErrMsg)
      IF (es /= CD_HCSTAT_OK) THEN
        ErrStat = es; RETURN
      END IF
    END IF
    ! The argument contract (>= 1) holds regardless of the weight signature: a bad value is
    ! rejected here even when a net-heavy line would go on to ignore the argument, so input
    ! rejection never depends on the cable weights.
    IF (PRESENT(n_buoy_steps)) THEN
      IF (n_buoy_steps < 1) THEN
        CALL fail('n_buoy_steps must be >= 1'); RETURN
      END IF
    END IF
    IF (PRESENT(endconn_stiffness) .NEQV. PRESENT(endconn_direction)) THEN
      CALL fail('endconn_stiffness and endconn_direction must be supplied together'); RETURN
    END IF
    IF (PRESENT(endconn_mode) .AND. .NOT. PRESENT(endconn_stiffness)) THEN
      CALL fail('endconn_mode requires endconn_stiffness and endconn_direction'); RETURN
    END IF
    IF (PRESENT(endconn_stiffness)) THEN
      IF (.NOT. CD_All_Finite(endconn_stiffness) .OR. ANY(endconn_stiffness < CD_ZERO)) THEN
        CALL fail('end-connection stiffnesses must be finite and non-negative'); RETURN
      END IF
      IF (PRESENT(endconn_mode)) THEN
        endconn_kind = endconn_mode
      ELSE
        WHERE (endconn_stiffness > CD_ZERO)
          endconn_kind = CD_ENDCONN_FINITE
        ELSEWHERE
          endconn_kind = CD_ENDCONN_PINNED
        END WHERE
      END IF
      DO i = 1, 2
        IF (endconn_kind(i) < CD_ENDCONN_PINNED .OR. endconn_kind(i) > CD_ENDCONN_RIGID) THEN
          CALL fail('end-connection mode must be Pinned, Finite, or Rigid'); RETURN
        END IF
        IF (endconn_kind(i) == CD_ENDCONN_PINNED) THEN
          IF (endconn_stiffness(i) > CD_ZERO) THEN
            CALL fail('a Pinned end connection must have zero stiffness'); RETURN
          END IF
          CYCLE
        ELSE IF (endconn_kind(i) == CD_ENDCONN_FINITE) THEN
          IF (endconn_stiffness(i) <= CD_ZERO) THEN
            CALL fail('a Finite end connection requires positive stiffness'); RETURN
          END IF
        ELSE IF (endconn_stiffness(i) > CD_ZERO) THEN
          CALL fail('a Rigid end connection is an exact constraint and must not carry a penalty stiffness'); RETURN
        END IF
        IF (.NOT. CD_All_Finite(endconn_direction(:, i))) THEN
          CALL fail('preferred direction must be finite at each connected end'); RETURN
        END IF
        direction_norm = SQRT(DOT_PRODUCT(endconn_direction(:, i), endconn_direction(:, i)))
        IF (.NOT. CD_Is_Finite(direction_norm) .OR. direction_norm <= SQRT(TINY(CD_ONE))) THEN
          CALL fail('preferred direction must be non-zero at each connected end'); RETURN
        END IF
        endconn_d0(:, i) = endconn_direction(:, i)/direction_norm
        IF (endconn_kind(i) == CD_ENDCONN_RIGID) THEN
          CALL CD_EndConn_Basis(endconn_d0(:, i), rigid_basis(:, :, i), es, ErrMsg)
          IF (es /= CD_ENDCONN_OK) THEN
            CALL fail('invalid rigid preferred direction: '//TRIM(ErrMsg)); RETURN
          END IF
        END IF
      END DO
      endconn_k = endconn_stiffness
      use_endconn = ANY(endconn_kind == CD_ENDCONN_FINITE)
      use_rigid = ANY(endconn_kind == CD_ENDCONN_RIGID)
    END IF
    use_tors = .FALSE.
    tors_on = .FALSE.
    tors_have_mode = .FALSE.
    tors_descending = .FALSE.
    tors_c = CD_ZERO
    tors_phi_cur = CD_ZERO
    tors_load_frac = CD_ZERO
    tors_theta_acc = CD_ZERO
    tors_theta_eval = CD_ZERO
    tors_mt = CD_ZERO
    tors_lambda = CD_ZERO
    IF (PRESENT(torsion)) use_tors = torsion%active
    IF (use_tors) THEN
      CALL CD_HermiteTorsion_Validate(torsion, l0, es, ErrMsg)
      IF (es /= CD_HTORS_OK) THEN
        CALL fail(TRIM(ErrMsg)); RETURN
      END IF
      ! a free end (infinite end compliance): the static torque is zero, nothing to solve
      IF (ANY(torsion%end_free)) THEN
        CALL fail('torsion: a line free in torsion at one end carries no static torque; solve it without '// &
                  'torsion'); RETURN
      END IF
      tors_c = CD_HermiteTorsion_Compliance(torsion, l0)
      IF (.NOT. (tors_c > CD_ZERO) .OR. .NOT. CD_Is_Finite(tors_c)) THEN
        CALL fail('torsion: the line compliance must be finite and positive'); RETURN
      END IF
      ! the twist ramp takes stages of at most pi/4: bound it (and its integer stage count)
      IF (ABS(torsion%phi) > CD_HTORS_MAX_TWIST .OR. ABS(torsion%theta_hint) > CD_HTORS_MAX_TWIST .OR. &
          ABS(torsion%theta) > CD_HTORS_MAX_TWIST) THEN
        BLOCK
          CHARACTER(160) :: tw
          INTEGER :: tw_ios
          tw = ''
          IF (ABS(torsion%phi) > CD_HTORS_MAX_TWIST) THEN
            WRITE (tw, '(A,ES12.5,A)', IOSTAT=tw_ios) 'torsion: the imposed twist Phi = ', torsion%phi, &
              ' rad exceeds 1000 turns (2000 pi rad), the largest static twist'
          ELSE
            tw = 'torsion: the twist state (theta or theta_hint) exceeds 1000 turns (2000 pi rad)'
          END IF
          CALL fail(TRIM(tw))
        END BLOCK
        RETURN
      END IF
      IF (use_ptc .OR. use_equilibration) THEN
        CALL fail('torsion is not combined with pseudo_transient or equilibrate_linear_system'); RETURN
      END IF
      ! the band holds only B of K = B + g g^T / C: no banded tangent can carry the rank-one term
      IF (PRESENT(tangent_out)) THEN
        CALL fail('torsion is not combined with tangent_out (the twisted tangent is not banded)'); RETURN
      END IF
      DO i = 1, 2
        IF (endconn_kind(i) /= CD_ENDCONN_RIGID) CYCLE
        IF (NORM2(torsion%ends(:, 2*i - 1) - endconn_d0(:, i)) > 1.0e-8_wp) THEN
          CALL fail('torsion: the director at a rigid end must be the rigid connection direction'); RETURN
        END IF
      END DO
    END IF

    ALLOCATE (q(ndof), trib(nn), freemask(ndof), solve_mask(ndof), w_cur(ne))
    ALLOCATE (R(ndof), dq(ndof), ab(LDAB_H, ndof), elem_f(12, ne), elem_K(12, 12, ne), &
              elem_E(ne), elem_es(ne), elem_em(ne))
    IF (use_equilibration) ALLOCATE (ab_recovery(LDAB_H, ndof), scaled_residual(ndof))
    ALLOCATE (q_sec1(ndof), q_sec2(ndof))
    IF (use_backtracking) ALLOCATE (q_base(ndof))
    IF (use_energy .OR. use_tors) &
      ALLOCATE (ab_energy(LDAB_H, ndof), r_energy(ndof), q_energy(ndof), sym(KL_H + 1, ndof))
    IF (use_tors) THEN
      ALLOCATE (tors_g(ndof), tors_gr(ndof), tors_h(2*CD_HTORS_KBAND + 1, ndof), tors_v(ndof), tors_rhs(ndof), &
                tors_q(ndof), tors_gs(ndof), tors_rhs2(ndof, 2), tors_grs(ndof), tors_gt(ndof))
      tors_g = CD_ZERO
      tors_gr = CD_ZERO
      tors_v = CD_ZERO
    END IF
    q = seed
    q_sec1 = seed
    q_sec2 = seed
    freemask = .TRUE.
    DO i = 1, SIZE(fixed_dofs)
      freemask(fixed_dofs(i)) = .FALSE.
      q(fixed_dofs(i)) = seed(fixed_dofs(i))
    END DO
    solve_mask = freemask
    IF (use_rigid) THEN
      DO i = 1, 2
        IF (endconn_kind(i) /= CD_ENDCONN_RIGID) CYCLE
        IF (i == 1) THEN
          b = 3
        ELSE
          b = 6*(nn - 1) + 3
        END IF
        IF (ANY(.NOT. freemask(b + 1:b + 3))) THEN
          CALL fail('rigid end tangent DOFs must not also appear in fixed_dofs'); RETURN
        END IF
        CALL CD_EndConn_Project(q(b + 1:b + 3), endconn_d0(:, i), projected_tangent, es, ErrMsg)
        IF (es /= CD_ENDCONN_OK) THEN
          CALL fail('could not project rigid endpoint tangent: '//TRIM(ErrMsg)); RETURN
        END IF
        q(b + 1:b + 3) = projected_tangent
        solve_mask(b + 2:b + 3) = .FALSE.
      END DO
      q_sec1 = q
      q_sec2 = q
    END IF
    ! nodal tributary lengths for lumped weight + seabed penalty
    trib = CD_ZERO
    DO i = 1, ne
      trib(i) = trib(i) + 0.5_wp*l0(i)
      trib(i + 1) = trib(i + 1) + 0.5_wp*l0(i)
    END DO
    ! A held end resting on the floor: the seabed can carry the end element's weight with its
    ! consistent end moment (CD_Seabed_End_Support; per unit weight, the floor's normal
    ! share cos(slope) n of the weight), which the nodal contact cannot. Held translations
    ! keep their seed, so this factor is fixed for the solve; the share of the element lying
    ! on the floor (end_element_share) follows the iterate.
    end_support = CD_ZERO
    end_share_last = CD_ZERO
    end_share_pi = CD_ZERO
    end_share_caller = PRESENT(end_share_hold)
    IF (end_share_caller) THEN
      IF (.NOT. CD_All_Finite(end_share_hold) .OR. ANY(end_share_hold < CD_ZERO) .OR. &
          ANY(end_share_hold > CD_ONE)) THEN
        CALL fail('end_share_hold must lie in [0, 1]'); RETURN
      END IF
      end_share_pi = end_share_hold
    END IF
    end_share_held = end_share_caller
    IF (use_nodal_contact .OR. kn > CD_ZERO) THEN
      DO i = 1, 2
        c = MERGE(1, nn, i == 1)
        b = 6*(c - 1)
        IF (ANY(freemask(b + 1:b + 3)) .OR. .NOT. (w(MERGE(1, ne, i == 1)) > CD_ZERO)) CYCLE
        end_floor(1) = seabed_z
        end_g = CD_ZERO
        IF (use_bathymetry) THEN
          CALL CD_Bathymetry_Floor_Gradient(bathymetry, contact_cs(1)*q(b + 1) - contact_cs(2)*q(b + 2), &
                                            contact_cs(2)*q(b + 1) + contact_cs(1)*q(b + 2), &
                                            end_floor(1), end_floor(2), end_floor(3), end_es, end_em)
          ! A failed query fails closed in the contact assembly at the same point.
          IF (end_es /= CD_BATHY_OK) CYCLE
          end_g = [contact_cs(1)*end_floor(2) + contact_cs(2)*end_floor(3), &
                   -contact_cs(2)*end_floor(2) + contact_cs(1)*end_floor(3)]
        END IF
        end_sfac = SQRT(CD_ONE + end_g(1)*end_g(1) + end_g(2)*end_g(2))
        end_support(:, i) = (CD_Seabed_End_Support((end_floor(1) - q(b + 3))/end_sfac)/(end_sfac*end_sfac))* &
                            [-end_g(1), -end_g(2), CD_ONE]
      END DO
    END IF
    use_friction = .FALSE.
    fr_frozen = .FALSE.
    fr_mu = CD_ZERO
    fr_aniso = .FALSE.
    fr_mu_a = CD_ZERO
    es = CD_HCSTAT_OK
    IF (PRESENT(friction)) THEN
      CALL setup_friction(friction, es, ErrMsg)
    ELSE IF (PRESENT(current)) THEN
      IF (ALLOCATED(current%friction)) CALL setup_friction(current%friction, es, ErrMsg)
    END IF
    IF (use_friction .AND. es /= CD_HCSTAT_OK) THEN
      ErrStat = es; RETURN
    END IF
    ! Force scale for the RELATIVE convergence test: the total submerged weight the
    ! line carries (with a unit floor for a weightless line). An absolute residual
    ! floor is unusable here -- a stiff EA makes the round-off floor of ||R|| scale
    ! with EA, not with tol. Applied nodal loads enter in FORCE units: r-slot entries
    ! are forces; m-slot entries are moment-like (work-conjugate to the dimensionless
    ! material tangent, N.m) and convert to the force scale through the same nodal
    ! tributary length the residual norm uses -- folding a raw N.m magnitude in as a
    ! force would let a long-element moment-loaded solve satisfy tol with a still-
    ! unbalanced moment.
    fscale = MAX(CD_ONE, SUM(ABS(w)*l0))
    IF (PRESENT(f_nodal)) THEN
      DO i = 1, nn
        fscale = MAX(fscale, MAXVAL(ABS(f_nodal(6*(i - 1) + 1:6*(i - 1) + 3))))
        fscale = MAX(fscale, MAXVAL(ABS(f_nodal(6*(i - 1) + 4:6*(i - 1) + 6)))/trib(i))
      END DO
    END IF
    IF (PRESENT(f_nodal_twist)) THEN
      DO i = 1, nn
        fscale = MAX(fscale, MAXVAL(ABS(f_nodal_twist(6*(i - 1) + 1:6*(i - 1) + 3))))
        fscale = MAX(fscale, MAXVAL(ABS(f_nodal_twist(6*(i - 1) + 4:6*(i - 1) + 6)))/trib(i))
      END DO
    END IF
    ! The tension a taut line must carry: with its ends farther apart than its length L, a line
    ! is stretched by at least chord/L - 1 over its series axial stiffness, so it carries at
    ! least that force whatever its weight. A line that carries little weight for its tension
    ! -- a weightless or near-neutral taut line, a tendon -- otherwise had a weight scale far
    ! below the round-off of its axial forces (EA (|r'| - 1) is formed from coordinate
    ! differences), and Newton stagnated at the round-off floor of an equilibrium it had
    ! reached: a neutrally buoyant 60 m cable at 61 kN stopped at ||R|| 1e-4 N against tol x
    ! 1 N. A slack line (chord <= L) keeps its weight scale. The bound holds only while the
    ! solve holds both end positions, which keeps the chord; with an end free to move (a
    ! cantilever) the seed's chord implies no tension at equilibrium. An element without axial
    ! stiffness (EA = 0) leaves the series stiffness, and so the bound, at zero.
    IF (.NOT. (ANY(freemask(1:3)) .OR. ANY(freemask(6*(nn - 1) + 1:6*(nn - 1) + 3))) .AND. ALL(EA > CD_ZERO)) THEN
      chord = NORM2(q(6*(nn - 1) + 1:6*(nn - 1) + 3) - q(1:3))
      IF (chord > SUM(l0)) fscale = MAX(fscale, (chord/SUM(l0) - CD_ONE)*SUM(l0)/SUM(l0/EA))
      ! The round-off floor of the residual itself, for a line whose chord is at least its
      ! length. The axial force is formed from coordinate differences, so a nodal force carries
      ! a round-off of about eps max(EA/l0) |x| (|x| the largest coordinate; the EI = 0 path's
      ! floor is 16 eps max(EA/L0) max(|q|, L0)), and the residual can fall no lower. The scale
      ! keeps tol x fscale at 16 times that floor. A neutral line whose length equals its span,
      ! straight at zero strain, carries neither weight nor tension and otherwise met the 1 N
      ! floor of the scale: under neutral attachments its polish stalled at ||R|| = 7.6e-8 N
      ! against tol x 1 N = 1e-8 N (EA 1e7, 2.5 m elements, |x| = 100 m) and failed at every load
      ! step. A slack line keeps its scale: a weightless one can stall at that floor on its straight
      ! compressed strut, a saddle, and is solved by the weight continuation that accepts the
      ! floor on its bowed equilibrium (light_line_route of the deck driver).
      IF (chord >= (CD_ONE - 1.0e-9_wp)*SUM(l0) .AND. tol > CD_ZERO) THEN
        BLOCK
          REAL(wp) :: xmax
          xmax = MAXVAL(l0)
          DO i = 1, nn
            xmax = MAX(xmax, MAXVAL(ABS(q(6*(i - 1) + 1:6*(i - 1) + 3))))
          END DO
          fscale = MAX(fscale, 16.0_wp*EPSILON(CD_ONE)*MAXVAL(EA/l0)*xmax/tol)
        END BLOCK
      END IF
    END IF

    ! Buoyancy load continuation. A net-buoyant section (w < 0, e.g. a lazy-wave buoyancy
    ! module) makes the equilibrium non-unique: alongside the smooth buoyant arch there are
    ! spurious KINKED local equilibria, and a direct damped-Newton solve can converge to one of
    ! them -- which one is knife-edge sensitive to the buoyancy value and to floating-point
    ! rounding (i.e. platform-dependent). Tracing the arch branch by ramping the buoyant
    ! weight from ~0 (a smooth, near-neutral middle) up to its target in small warm-started
    ! steps keeps every Newton solve on the smooth branch, giving a deterministic result. For
    ! a purely net-heavy line (all w >= 0) this is a single step: the EI continuation alone.
    has_buoy = ANY(w < CD_ZERO)
    n_buoy = 1
    ! 40 buoyancy steps reach the smooth arch deterministically across the net-buoyant range of
    ! a lazy-wave line (a smooth, monotone curvature-vs-buoyancy family with no kink basins),
    ! with the same result as a finer continuation.
    ! A caller with a seed ALREADY on the smooth branch at full buoyancy overrides this to 1
    ! (polish mode) via n_buoy_steps; see the argument note.
    IF (has_buoy) THEN
      n_buoy = 40
      IF (PRESENT(n_buoy_steps)) n_buoy = n_buoy_steps   ! validated >= 1 in the prologue
    END IF
    DO b = 1, n_buoy
      bfac = REAL(b, wp)/REAL(n_buoy, wp)
      DO i = 1, ne
        IF (w(i) < CD_ZERO) THEN
          w_cur(i) = bfac*w(i)      ! ramp net-buoyant elements 0 -> target along the arch branch
        ELSE
          w_cur(i) = w(i)           ! net-heavy elements carry full weight throughout
        END IF
      END DO
      ! EI load continuation on the first buoyancy step (onset from the seed); full EI after,
      ! warm-started from the previous buoyancy solution held in q.
      nci = n_cont
      IF (b > 1) nci = 1
      ! Secant predictor: start stage b at the linear extrapolation of the two previous
      ! converged stage states (uniform bfac increments -> extrapolation factor one).
      ! Without it, every warm stage's first Newton direction answers the raw
      ! buoyancy increment along the soft arch mode and overshoots (see the
      ! trust-region full-Newton switch, DQ_TRUST/R_TRUST); the extrapolated start
      ! already carries that shift, leaving only the O(increment^2) branch curvature to correct. Deterministic -- pure
      ! arithmetic on converged states, no control flow keyed to iteration counts -- and
      ! it preserves fixed DOFs exactly (both history states hold the same seed values).
      IF (b >= 3) q = 2.0_wp*q_sec1 - q_sec2
      DO c = 1, nci
        eifac = REAL(c, wp)/REAL(nci, wp)
        ! The dry-part buoyancy is part of the physical full-load problem, not of the
        ! EI/buoyancy homotopy: it acts only in the final stage, which starts from the
        ! previous converged stage. Intermediate iterates that leave the water therefore
        ! cannot redirect the continuation branch of a line that ends submerged.
        dry_now = use_dry .AND. b == n_buoy .AND. c == nci
        ! The steady-current drag, like the dry buoyancy, belongs to the full-load problem.
        drag_now = use_current .AND. b == n_buoy .AND. c == nci
        IF (PRESENT(history_count)) history_count = 0
        IF (PRESENT(residual_history)) residual_history = CD_ZERO
        it_fall = 0
        DO it = 1, max_iter
          ! newton_step measures the residual at the CURRENT q and updates only when
          ! not yet converged, so it never over-steps a converged state.
          CALL newton_step(rnorm, es, ErrMsg, .TRUE.)
          IF (PRESENT(stall_limit) .AND. rnorm >= tol .AND. es == CD_HCSTAT_OK) THEN
            ! The norm has halved when its square (the merit) falls below a quarter.
            IF (it == 1) THEN
              merit_fall = merit_update
            ELSE IF (merit_update < 0.25_wp*merit_fall) THEN
              merit_fall = merit_update
              it_fall = it - 1
            END IF
          END IF
          ! A stall is sticky by design: every later stage then runs a single step, so the
          ! stage loops still end at the full load and full EI, where the final evaluation
          ! gives the verdict (a stalled solve ends NOCONVERGE).
          IF (stalled) EXIT
          IF (es /= CD_HCSTAT_OK) THEN
            ! Define the outputs on failure: the last iterate and no curvature.
            q_out = q
            curv_out = CD_ZERO
            ErrStat = es; RETURN
          END IF
          iters_out = iters_out + 1
          res_out = rnorm
          IF (PRESENT(residual_history)) residual_history(it) = rnorm
          IF (PRESENT(history_count)) history_count = it
          IF (rnorm < tol) EXIT
          IF (PRESENT(stall_limit)) THEN
            IF (it - it_fall >= stall_limit) EXIT
          END IF
        END DO
      END DO
      q_sec2 = q_sec1
      q_sec1 = q
    END DO

    ! Condensed torsion: the imposed twist is the last load stage.
    IF (use_tors) THEN
      CALL torsion_continuation(es, ErrMsg)
      IF (es /= CD_HCSTAT_OK) THEN
        q_out = q
        curv_out = CD_ZERO
        ErrStat = es; RETURN
      END IF
    END IF

    ! Evaluate the TRUE residual at the final q and full EI (eifac = 1, w_cur = w here): the
    ! last update inside the loop may have reached tolerance, and its post-update
    ! residual must drive the convergence verdict rather than the pre-update value.
    IF (PRESENT(stable)) stable = .FALSE.
    CALL newton_step(rnorm, es, ErrMsg, .FALSE.)
    IF (es /= CD_HCSTAT_OK) THEN
      q_out = q
      curv_out = CD_ZERO
      ErrStat = es; RETURN
    END IF
    res_out = rnorm
    IF (PRESENT(residual_out)) residual_out = R
    IF (PRESENT(tangent_out)) tangent_out = ab
    IF (PRESENT(energy_out)) energy_out = pi_total
    IF (PRESENT(stable)) THEN
      ! A seabed friction capacity mu*N follows the normal force, so a sliding node's
      ! friction row depends on its vertical position with no reciprocal term: a
      ! triangular, non-potential coupling that leaves the tangent's eigenvalues positive
      ! but can make its symmetric part indefinite. The stability tangent holds each
      ! capacity at its equilibrium value (the conservative spring of the frozen-capacity
      ! mode) and keeps every other term, the current drag Jacobian included.
      IF (use_friction .AND. .NOT. fr_frozen) THEN
        stab_eval = .TRUE.
        CALL newton_step(rnorm, es, ErrMsg, .FALSE.)
        stab_eval = .FALSE.
        IF (es /= CD_HCSTAT_OK) THEN
          q_out = q
          curv_out = CD_ZERO
          ErrStat = es; RETURN
        END IF
      END IF
      IF (use_tors) THEN
        CALL torsion_stability(stable, es, ErrMsg)
        IF (es /= CD_HCSTAT_OK) THEN
          q_out = q
          curv_out = CD_ZERO
          ErrStat = es; RETURN
        END IF
      ELSE
        stable = tangent_positive_definite()
      END IF
    END IF
    IF (use_tors) THEN
      ! the accepted Theta becomes state only on a converged return: a NOCONVERGE return
      ! leaves the caller's torsion state (and its branch) as it was
      IF (res_out < tol) THEN
        torsion%theta = tors_theta_acc
        torsion%has_theta = .TRUE.
        torsion%torque = tors_mt
        torsion%energy = pi_total
      END IF
      IF (.NOT. PRESENT(stable)) THEN
        IF (torsion%check_stability) THEN
          CALL torsion_stability(torsion%stable, es, ErrMsg)
          IF (es /= CD_HCSTAT_OK) THEN
            q_out = q
            curv_out = CD_ZERO
            ErrStat = es; RETURN
          END IF
        END IF
      ELSE
        torsion%stable = stable
      END IF
      ! an unstable state kept as the untwisted equilibrium's own instability (torsion_stage)
      torsion%untwisted_instability = torsion%keep_untwisted_instability .AND. .NOT. torsion%stable .AND. &
                                      torsion%n_negative_untwisted > 0 .AND. &
                                      torsion%n_negative <= torsion%n_negative_untwisted
    END IF

    IF (res_out >= tol) THEN
      ErrStat = CD_HCSTAT_NOCONVERGE
      IF (PRESENT(residual_unmet)) residual_unmet = .TRUE.
      BLOCK
        ! Format into a local buffer: a record longer than the caller's ErrMsg
        ! must truncate, not abort the internal write.
        CHARACTER(1024) :: wbuf
        INTEGER :: wios
        wbuf = ''
        WRITE (wbuf, '(A,ES12.5,A,ES12.5)', IOSTAT=wios) &
          'CD_HermiteCable_Static_Solve: Newton did not converge, ||R||=', res_out, ' > tol=', tol
        ErrMsg = wbuf
      END BLOCK
    END IF

    q_out = q
    DO i = 1, nn
      curv_out(i) = nodal_curvature(i)
    END DO

  CONTAINS

    RECURSIVE SUBROUTINE newton_step(rnorm, es, em, do_update)
      !! Assemble the residual/tangent at the current q and EI factor, return the
      !! relative residual norm rnorm, and (only when do_update .and. rnorm >= tol)
      !! apply one damped Newton update to the free DOFs. With do_update = .FALSE.
      !! this is a pure residual evaluation.
      !!
      !! The tangent is assembled DIRECTLY into the preallocated LAPACK band array
      !! (half-bandwidth 11 by the element connectivity); Dirichlet DOFs are applied
      !! IN-BAND (row/column zeroed within the band, unit diagonal, zero residual
      !! slot), which preserves the bandwidth exactly and makes the full-size solve
      !! return dq = 0 at every fixed DOF -- no dense tangent, no free-DOF copy.
      REAL(wp), INTENT(OUT) :: rnorm
      INTEGER, INTENT(OUT) :: es
      CHARACTER(*), INTENT(OUT) :: em
      LOGICAL, INTENT(IN) :: do_update
      REAL(wp) :: qe(12)
      REAL(wp) :: pen, dqnorm, z_floor, gxg, gyg, gx, gy, xg, yg, normal, normal_gap, kn_eff
      REAL(wp) :: curv_g(3), curv_l(3)
      REAL(wp) :: step_scale, trial_norm, row_scale, column_scale, merit, trial_merit, merit_base, diag_floor
      REAL(wp) :: gradient_component, column_norm2, fdry(4), kdry(4, 4), e_term
      ! Frictionless contact on a sloped floor: the force along the upward surface normal
      ! nvec at the normal penetration pen/sfac, and its tangent (CD_Seabed_Normal_Contact).
      REAL(wp) :: sfac, nvec(3), fcon(3), jcon(3, 3)
      INTEGER :: jr, jc
      INTEGER :: e, a, b, gi, gj, j, es2, bt, es_trial, zdof(4)
      LOGICAL :: dry, accepted
      CHARACTER(1024) :: em2, em_trial
      CHARACTER(160) :: em_b ! a per-node bathymetry query message (at most 69 characters)

      es = CD_HCSTAT_OK; em = ''; rnorm = CD_ZERO; merit = CD_ZERO
      IF (use_rigid) THEN
        IF (.NOT. rigid_rays_valid(q)) THEN
          es = CD_HCSTAT_NOCONVERGE
          em = 'rigid endpoint tangent left the positive prescribed ray'
          RETURN
        END IF
      END IF
      R = CD_ZERO
      ab = CD_ZERO

      ! Evaluate independent element kernels concurrently into solve-lifetime buffers,
      ! then scatter in element order to retain deterministic residual/tangent sums.
      !$OMP PARALLEL DEFAULT(SHARED) PRIVATE(qe) NUM_THREADS(omp_threads) IF(ne >= 32)
      CALL CD_Fatal_Thread_Init() ! this thread can report its own stack overflow
      !$OMP DO SCHEDULE(STATIC)
      DO e = 1, ne
        qe(1:3) = q(6*(e - 1) + 1:6*(e - 1) + 3)
        qe(4:6) = q(6*(e - 1) + 4:6*(e - 1) + 6)
        qe(7:9) = q(6*e + 1:6*e + 3)
        qe(10:12) = q(6*e + 4:6*e + 6)
        IF (skip_tangent) THEN
          CALL CD_HermiteCable_Element(qe, l0(e), EA(e), eifac*EI(e), elem_E(e), elem_f(:, e), &
                                       ErrStat=elem_es(e), ErrMsg=elem_em(e), &
                                       axial_quadrature_order=axial_order, &
                                       bending_quadrature_order=bending_order)
        ELSE
          CALL CD_HermiteCable_Element(qe, l0(e), EA(e), eifac*EI(e), elem_E(e), elem_f(:, e), &
                                       elem_K(:, :, e), elem_es(e), elem_em(e), &
                                       axial_quadrature_order=axial_order, &
                                       bending_quadrature_order=bending_order)
        END IF
      END DO
      !$OMP END DO
      !$OMP END PARALLEL
      pi_total = SUM(elem_E)
      pi_abs = SUM(ABS(elem_E))
      DO e = 1, ne
        IF (elem_es(e) /= CD_HCABLE_OK) THEN
          es = CD_HCSTAT_NOCONVERGE; em = 'element failed: '//TRIM(elem_em(e)); RETURN
        END IF
        DO a = 1, 12
          gi = elem_gdof(e, a)
          R(gi) = R(gi) + elem_f(a, e)
          IF (skip_tangent) CYCLE
          DO b = 1, 12
            gj = elem_gdof(e, b)
            ab(KL_H + KU_H + 1 + gi - gj, gj) = ab(KL_H + KU_H + 1 + gi - gj, gj) + elem_K(a, b, e)
          END DO
        END DO
      END DO

      ! ---- external self-weight: CONSISTENT cubic-Hermite generalized load on z DOFs ----
      ! For a uniform -z load w per reference length over element e, the consistent nodal
      ! loads are r_z: w*l0/2 at each end node and m_z: +/- w*l0^2/12 (the tangent-DOF
      ! terms a lumped model drops). R = fint - fext, so -fext contributes +w to R.
      ! Configuration-independent (integrals over reference length) -> adds nothing to K.
      DO e = 1, ne
        R(6*(e - 1) + 3) = R(6*(e - 1) + 3) + w_cur(e)*0.5_wp*l0(e)          ! node e   r_z
        R(6*(e - 1) + 6) = R(6*(e - 1) + 6) + w_cur(e)*l0(e)*l0(e)/12.0_wp   ! node e   m_z
        R(6*e + 3) = R(6*e + 3) + w_cur(e)*0.5_wp*l0(e)                      ! node e+1 r_z
        R(6*e + 6) = R(6*e + 6) - w_cur(e)*l0(e)*l0(e)/12.0_wp               ! node e+1 m_z
        ! Its potential, with heights measured from the seed height of node 1 (a constant,
        ! so the energy stays consistent with R when that DOF is free) to limit round-off.
        e_term = w_cur(e)*(0.5_wp*l0(e)*(q(6*(e - 1) + 3) + q(6*e + 3) - 2.0_wp*seed(3)) + &
                           l0(e)*l0(e)/12.0_wp*(q(6*(e - 1) + 6) - q(6*e + 6)))
        pi_total = pi_total + e_term
        pi_abs = pi_abs + ABS(e_term)
      END DO
      ! the floor-carried end moments of held ends whose end element lies on the seabed
      es2 = CD_HCSTAT_OK
      IF (end_support(3, 1) > CD_ZERO) CALL add_end_support(1, 1, 2, -CD_ONE, es2, em2)
      IF (es2 /= CD_HCSTAT_OK) THEN
        es = CD_HCSTAT_NOCONVERGE; em = TRIM(em2); RETURN
      END IF
      IF (end_support(3, 2) > CD_ZERO) CALL add_end_support(2, ne, nn - 1, CD_ONE, es2, em2)
      IF (es2 /= CD_HCSTAT_OK) THEN
        es = CD_HCSTAT_NOCONVERGE; em = TRIM(em2); RETURN
      END IF

      ! ---- dry-part buoyancy recovery above the optional free surface ----
      ! Configuration-dependent through the waterline crossings, so it adds the crossing
      ! tangent to K. Applied at full strength in the final continuation stage.
      IF (dry_now) THEN
        DO e = 1, ne
          zdof = [6*(e - 1) + 3, 6*(e - 1) + 6, 6*e + 3, 6*e + 6]
          IF (PRESENT(water_weight)) THEN
            CALL CD_HermiteCable_Dry_Buoyancy(q(zdof), l0(e), dry_buoyancy(e), waterline_z, fdry, kdry, dry, &
                                              energy=e_term, radius=SQRT(dry_buoyancy(e)/(PI_W*water_weight)))
          ELSE
            CALL CD_HermiteCable_Dry_Buoyancy(q(zdof), l0(e), dry_buoyancy(e), waterline_z, fdry, kdry, dry, &
                                              energy=e_term)
          END IF
          IF (.NOT. dry) CYCLE
          pi_total = pi_total + e_term
          pi_abs = pi_abs + ABS(e_term)
          R(zdof) = R(zdof) + fdry
          DO b = 1, 4
            DO a = 1, 4
              ab(KL_H + KU_H + 1 + zdof(a) - zdof(b), zdof(b)) = &
                ab(KL_H + KU_H + 1 + zdof(a) - zdof(b), zdof(b)) + kdry(a, b)
            END DO
          END DO
        END DO
      END IF

      ! ---- steady-current drag on the line at rest (non-conservative) ----
      IF (drag_now) THEN
        CALL add_current_drag(es2, em2)
        IF (es2 /= CD_HCSTAT_OK) THEN
          es = CD_HCSTAT_NOCONVERGE; em = 'current drag: '//TRIM(em2); RETURN
        END IF
      END IF

      ! ---- optional external generalized nodal loads, ramped with the continuation factor ----
      IF (PRESENT(f_nodal)) THEN
        R = R - eifac*f_nodal
        e_term = eifac*DOT_PRODUCT(f_nodal, q)
        pi_total = pi_total - e_term
        pi_abs = pi_abs + ABS(e_term)
      END IF
      IF (PRESENT(f_nodal_twist)) THEN
        IF (tors_load_frac > CD_ZERO) THEN
          R = R - eifac*tors_load_frac*f_nodal_twist
          e_term = eifac*tors_load_frac*DOT_PRODUCT(f_nodal_twist, q)
          pi_total = pi_total - e_term
          pi_abs = pi_abs + ABS(e_term)
        END IF
      END IF

      ! ---- optional rotational line-end connections ----
      ! Ramped with the same factor as EI: a stiff connection introduced at full strength
      ! against a cold seed would fight the bending continuation it is meant to ride along.
      IF (use_endconn) THEN
        CALL add_end_connection(1, MERGE(endconn_k(1), CD_ZERO, &
                                         endconn_kind(1) == CD_ENDCONN_FINITE), &
                                endconn_d0(:, 1), es2, em2)
        IF (es2 /= CD_ENDCONN_OK) THEN
          es = CD_HCSTAT_NOCONVERGE; em = 'end connection at node 1: '//TRIM(em2); RETURN
        END IF
        CALL add_end_connection(nn, MERGE(endconn_k(2), CD_ZERO, &
                                          endconn_kind(2) == CD_ENDCONN_FINITE), &
                                endconn_d0(:, 2), es2, em2)
        IF (es2 /= CD_ENDCONN_OK) THEN
          es = CD_HCSTAT_NOCONVERGE; em = 'end connection at final node: '//TRIM(em2); RETURN
        END IF
      END IF

      ! ---- penalty seabed on nodal translation DOFs ----
      ! The optional production contact path uses nodal stiffnesses matching the deck
      ! law and includes structured-floor slope terms. The scalar API path remains
      ! unchanged for existing direct callers.
      DO a = 1, nn
        gi = 6*(a - 1) + 3
        gx = CD_ZERO; gy = CD_ZERO; z_floor = seabed_z
        curv_l = CD_ZERO
        IF (use_bathymetry) THEN
          xg = contact_cs(1)*q(gi - 2) - contact_cs(2)*q(gi - 1)
          yg = contact_cs(2)*q(gi - 2) + contact_cs(1)*q(gi - 1)
          CALL CD_Bathymetry_Floor_Gradient(bathymetry, xg, yg, z_floor, gxg, gyg, es2, em_b, crease_curvature=curv_g)
          IF (es2 /= CD_BATHY_OK) THEN
            es = CD_HCSTAT_NOCONVERGE; em = 'bathymetry query failed: '//TRIM(em_b); RETURN
          END IF
          gx = contact_cs(1)*gxg + contact_cs(2)*gyg
          gy = -contact_cs(2)*gxg + contact_cs(1)*gyg
          ! the curvature of a rounded crease, turned into the solve frame like the gradient
          IF (ANY(ABS(curv_g) > CD_ZERO)) curv_l = CD_Bathymetry_Rotate_Curvature(curv_g, contact_cs)
        END IF
        pen = z_floor - q(gi)
        ! The penetration normal to the floor is pen/sfac (sfac = 1 on a level floor).
        sfac = SQRT(CD_ONE + gx*gx + gy*gy)
        IF (use_friction) THEN
          ! capacity mu*N with N the normal force; its gradient (gx, gy, -1)*normal_gap
          IF (use_nodal_contact) THEN
            CALL CD_Seabed_Normal_Law(pen/sfac, contact_kn(a), normal, normal_gap)
            normal_gap = normal_gap/sfac
          ELSE IF (pen > CD_ZERO) THEN
            normal = kn*trib(a)*pen/sfac
            normal_gap = kn*trib(a)/sfac
          ELSE
            normal = CD_ZERO
            normal_gap = CD_ZERO
          END IF
          CALL add_friction(a, normal, normal_gap, gx, gy)
        END IF
        IF (use_nodal_contact) THEN
          kn_eff = contact_kn(a)
          IF (use_bathymetry) THEN
            ! Frictionless: the force acts along the upward normal of the (sloped) floor.
            CALL CD_Seabed_Normal_Contact(pen, gx, gy, kn_eff, fcon, jcon, curvature=curv_l)
            e_term = seabed_potential(pen/sfac, kn_eff)
            pi_total = pi_total + e_term
            pi_abs = pi_abs + e_term
            R(gi - 2:gi) = R(gi - 2:gi) - fcon
            DO jc = 1, 3
              DO jr = 1, 3
                ab(KL_H + KU_H + 1 + jr - jc, gi - 3 + jc) = ab(KL_H + KU_H + 1 + jr - jc, gi - 3 + jc) + jcon(jr, jc)
              END DO
            END DO
          ELSE
            CALL CD_Seabed_Normal_Law(pen, kn_eff, normal, normal_gap)
            e_term = seabed_potential(pen, kn_eff)
            pi_total = pi_total + e_term
            pi_abs = pi_abs + e_term
            R(gi) = R(gi) - normal
            ab(KL_H + KU_H + 1, gi) = ab(KL_H + KU_H + 1, gi) + normal_gap
          END IF
        ELSE IF (pen > CD_ZERO) THEN
          ! upward reaction kn*trib*pen/sfac along the floor normal nvec (vertical when level);
          ! -fext adds -kn*trib*(pen/sfac)*nvec and its tangent kn*trib*nvec*nvec^T
          nvec = [-gx, -gy, CD_ONE]/sfac
          R(gi - 2:gi) = R(gi - 2:gi) - kn*trib(a)*(pen/sfac)*nvec
          pi_total = pi_total + 0.5_wp*kn*trib(a)*(pen/sfac)**2
          pi_abs = pi_abs + 0.5_wp*kn*trib(a)*(pen/sfac)**2
          DO jc = 1, 3
            DO jr = 1, 3
              ab(KL_H + KU_H + 1 + jr - jc, gi - 3 + jc) = ab(KL_H + KU_H + 1 + jr - jc, gi - 3 + jc) + &
                                                           kn*trib(a)*nvec(jr)*nvec(jc)
            END DO
          END DO
        END IF
      END DO

      ! Exact rigid line ends are solved in a local tangent basis.  The first
      ! coordinate remains the free tangent magnitude; the two transverse
      ! coordinates are homogeneous constraints.  Transforming both rows and
      ! columns preserves symmetry and avoids the conditioning and arbitrary
      ! stiffness scale of a penalty approximation.
      ! ---- condensed torsion: -M_t dTheta/dq in R, -M_t d2Theta/dq2 in the band ----
      IF (tors_on) THEN
        CALL add_torsion(es2, em2)
        IF (es2 /= CD_HCSTAT_OK) THEN
          es = CD_HCSTAT_NOCONVERGE; em = TRIM(em2); RETURN
        END IF
      END IF

      IF (use_rigid) CALL apply_rigid_system(R, ab)
      IF (tors_on) CALL torsion_reduce()

      ! Dimensionally-consistent relative residual over the FREE DOFs. Translational (r)
      ! DOFs carry force residuals [N]; material-tangent (m) DOFs carry moment residuals
      ! [N.m], because the Hermite tangent shape functions carry the element length.
      ! Divide r-slots by the force scale and m-slots by force * local-length (trib ~
      ! element length) so the convergence verdict is dimensionless and
      ! mesh-length-independent. The solve below uses the RAW residual, not this norm.
      rnorm = CD_ZERO
      rmerit = CD_ZERO
      DO gi = 1, ndof
        IF (.NOT. solve_mask(gi)) CYCLE
        IF (MOD(gi - 1, 6) >= 3) THEN                       ! material-tangent slot (m)
          gj = (gi - 1)/6 + 1                               ! owning node
          rnorm = MAX(rnorm, ABS(R(gi))/(fscale*trib(gj)))
          rmerit = rmerit + (R(gi)/(fscale*trib(gj)))**2
        ELSE                                                ! translational slot (r)
          rnorm = MAX(rnorm, ABS(R(gi))/fscale)
          rmerit = rmerit + (R(gi)/fscale)**2
        END IF
      END DO
      IF (.NOT. CD_Is_Finite(rnorm)) THEN
        es = CD_HCSTAT_NOCONVERGE; em = 'non-finite residual'; RETURN
      END IF
      IF (do_update) merit_update = rmerit
      ! Pure residual evaluation, or already at tolerance: do not step.
      IF (.NOT. do_update .OR. rnorm < tol) RETURN

      ! ---- Dirichlet in band form: zero row + column, unit diagonal, zero RHS ----
      DO j = 1, ndof
        IF (solve_mask(j)) CYCLE
        DO gi = MAX(1, j - KL_H), MIN(ndof, j + KU_H)       ! column j entries (rows gi)
          ab(KL_H + KU_H + 1 + gi - j, j) = CD_ZERO
        END DO
        DO gj = MAX(1, j - KU_H), MIN(ndof, j + KL_H)       ! row j entries (columns gj)
          ab(KL_H + KU_H + 1 + j - gj, gj) = CD_ZERO
        END DO
        ab(KL_H + KU_H + 1, j) = CD_ONE
        R(j) = CD_ZERO
      END DO

      IF (use_energy .AND. .NOT. drag_now .AND. .NOT. (use_friction .AND. .NOT. fr_frozen)) THEN
        CALL energy_update(es, em)
        RETURN
      END IF
      ! Pseudo-transient continuation: (K + D/tau) dq = -R with D the magnitude of the
      ! tangent diagonal, tau advanced by switched evolution relaxation (SER).
      IF (use_ptc) THEN
        IF (ptc_rprev > CD_ZERO) THEN
          IF (drag_now) THEN
            ! A current-loaded line may first move away from the still-water shape before
            ! the residual falls: the pseudo-time step keeps growing (a relaxation march).
            ptc_tau = MIN(1.0e12_wp, ptc_tau*MAX(1.2_wp, MIN(10.0_wp, ptc_rprev/MAX(rnorm, TINY(CD_ONE)))))
          ELSE
            ptc_tau = MIN(1.0e12_wp, ptc_tau*MIN(10.0_wp, ptc_rprev/MAX(rnorm, TINY(CD_ONE))))
          END IF
        END IF
        ptc_rprev = rnorm
        diag_floor = CD_ZERO
        DO j = 1, ndof
          IF (solve_mask(j)) diag_floor = MAX(diag_floor, ABS(ab(KL_H + KU_H + 1, j)))
        END DO
        diag_floor = 1.0e-12_wp*diag_floor
        DO j = 1, ndof
          IF (.NOT. solve_mask(j)) CYCLE
          ab(KL_H + KU_H + 1, j) = ab(KL_H + KU_H + 1, j) + &
                                   MAX(ABS(ab(KL_H + KU_H + 1, j)), diag_floor)/ptc_tau
        END DO
      END IF
      dq = -R
      IF (use_equilibration) THEN
        ! Recovery-only diagonal equilibration for a stalled full-load polish.
        ! Position increments carry length units while material-tangent increments
        ! are dimensionless; their conjugate residual rows carry force and moment
        ! units. Transform K dq = -R to the matching dimensionless system before
        ! DGBSV, then recover the same physical dq. Successful native solves never
        ! enter this path, so their branch and iteration history remain unchanged.
        DO j = 1, ndof
          IF (MOD(j - 1, 6) < 3) THEN
            column_scale = trib((j - 1)/6 + 1)
          ELSE
            column_scale = CD_ONE
          END IF
          DO gi = MAX(1, j - KU_H), MIN(ndof, j + KL_H)
            IF (MOD(gi - 1, 6) < 3) THEN
              row_scale = CD_ONE
            ELSE
              row_scale = CD_ONE/trib((gi - 1)/6 + 1)
            END IF
            ab(KL_H + KU_H + 1 + gi - j, j) = &
              row_scale*ab(KL_H + KU_H + 1 + gi - j, j)*column_scale
          END DO
          IF (MOD(j - 1, 6) < 3) THEN
            row_scale = CD_ONE
          ELSE
            row_scale = CD_ONE/trib((j - 1)/6 + 1)
          END IF
          dq(j) = row_scale*dq(j)
          scaled_residual(j) = row_scale*R(j)
        END DO
        ab_recovery = ab
        merit = residual_merit(scaled_residual)
      END IF
      IF (tors_on) THEN
        tors_rhs = dq
        CALL CD_HermiteTorsion_Bordered_Solve(ab, KL_H, KU_H, tors_gr, tors_c, tors_rhs, dq, es2, em2)
        IF (es2 /= CD_HTORS_OK) THEN
          es = CD_HCSTAT_NOCONVERGE; em = 'torsion: '//TRIM(em2); RETURN
        END IF
      ELSE IF (use_equilibration) THEN
        CALL CD_Solve_Banded_Refined(ab, KL_H, KU_H, dq, es2, em2)
      ELSE
        CALL CD_Solve_Banded(ab, KL_H, KU_H, dq, es2, em2)
      END IF
      IF (es2 /= CD_LINALG_OK) THEN
        es = CD_HCSTAT_NOCONVERGE; em = 'tangent solve failed: '//TRIM(em2); RETURN
      END IF
      IF (use_equilibration) THEN
        DO j = 1, ndof
          IF (MOD(j - 1, 6) < 3) dq(j) = trib((j - 1)/6 + 1)*dq(j)
        END DO
      END IF
      IF (use_rigid) CALL rigid_increment_to_global(dq)
      ! dq(fixed) = 0 by construction, so the blanket update leaves fixed DOFs untouched.
      ! Take the full Newton step only when the proposed step is inside the trust radius
      ! and the residual is not far-field (see DQ_TRUST / R_TRUST); otherwise the
      ! caller's damping factor governs. The step norm mirrors the residual norm's
      ! scaling: translational entries per local element length (trib), tangent entries
      ! as-is (|m| ~ 1 by construction).
      dqnorm = CD_ZERO
      DO j = 1, ndof
        IF (.NOT. solve_mask(j)) CYCLE
        IF (MOD(j - 1, 6) >= 3) THEN
          dqnorm = MAX(dqnorm, ABS(dq(j)))
        ELSE
          dqnorm = MAX(dqnorm, ABS(dq(j))/trib((j - 1)/6 + 1))
        END IF
      END DO
      step_scale = damping
      IF (rnorm < R_TRUST .AND. dqnorm < DQ_TRUST) step_scale = CD_ONE
      IF (use_ptc) step_scale = CD_ONE
      IF (use_rigid) CALL limit_rigid_step(dq, step_scale)
      IF (tors_on) CALL limit_torsion_step(tors_g, dq, step_scale)
      IF (.NOT. use_backtracking .OR. use_ptc) THEN
        IF (tors_on) THEN
          CALL torsion_take_step(step_scale, es2, em2)
          IF (es2 /= CD_HCSTAT_OK) THEN
            es = CD_HCSTAT_NOCONVERGE; em = TRIM(em2); RETURN
          END IF
        ELSE
          q = q + step_scale*dq
        END IF
      ELSE
        q_base = q
        merit_base = rmerit
        DO bt = 0, FULL_LOAD_BACKTRACKS
          q = q_base + step_scale*dq
          CALL newton_step(trial_norm, es_trial, em_trial, .FALSE.)
          IF (es_trial == CD_HCSTAT_OK) THEN
            ! Merit mode: Armijo sufficient decrease of f = |F|^2/2 along the Newton
            ! direction (directional derivative -2f). Default: the scaled max-norm
            ! must decrease.
            IF (use_merit) THEN
              accepted = rmerit <= (CD_ONE - 2.0e-4_wp*step_scale)*merit_base
            ELSE
              accepted = trial_norm < rnorm
            END IF
            IF (accepted) THEN
              IF (tors_on) tors_theta_acc = tors_theta_eval
              RETURN
            END IF
          END IF
          step_scale = 0.5_wp*step_scale
        END DO
        q = q_base
        ! In merit mode an exhausted line search leaves q unchanged; the next iteration
        ! would recompute the same direction, so the solve stops here.
        IF (use_merit .AND. .NOT. use_equilibration) stalled = .TRUE.
        IF (use_equilibration) THEN
          ! The refined Newton direction can still stagnate at a nearby non-smooth
          ! contact transition. Use a column-normalised residual-gradient direction
          ! for the same scaled merit, then require an actual merit reduction. The
          ! positive diagonal preconditioner preserves descent, and this branch is
          ! available only in the bounded recovery solve.
          dq = CD_ZERO
          DO j = 1, ndof
            gradient_component = CD_ZERO
            column_norm2 = CD_ZERO
            DO gi = MAX(1, j - KU_H), MIN(ndof, j + KL_H)
              gradient_component = gradient_component + &
                                   ab_recovery(KL_H + KU_H + 1 + gi - j, j)*scaled_residual(gi)
              column_norm2 = column_norm2 + ab_recovery(KL_H + KU_H + 1 + gi - j, j)**2
            END DO
            dq(j) = -gradient_component/MAX(column_norm2, CD_ONE)
            IF (MOD(j - 1, 6) < 3) dq(j) = trib((j - 1)/6 + 1)*dq(j)
          END DO
          IF (use_rigid) CALL rigid_increment_to_global(dq)
          step_scale = CD_ONE
          IF (use_rigid) CALL limit_rigid_step(dq, step_scale)
          DO bt = 0, FULL_LOAD_BACKTRACKS
            q = q_base + step_scale*dq
            CALL newton_step(trial_norm, es_trial, em_trial, .FALSE.)
            IF (es_trial == CD_HCSTAT_OK) THEN
              scaled_residual = R
              DO gi = 1, ndof
                IF (MOD(gi - 1, 6) >= 3) scaled_residual(gi) = scaled_residual(gi)/trib((gi - 1)/6 + 1)
              END DO
              trial_merit = residual_merit(scaled_residual)
              IF (trial_merit < merit) RETURN
            END IF
            step_scale = 0.5_wp*step_scale
          END DO
          q = q_base
        END IF
      END IF
    END SUBROUTINE newton_step

    RECURSIVE SUBROUTINE energy_update(es, em)
      !! One modified-Newton step on the total potential energy; see energy_minimization.
      !! Called with R/ab assembled, constrained and in the rigid-end basis at the current
      !! q. The shift mu makes the symmetric part of K + mu*D positive definite (a banded
      !! Cholesky factorization is the test), so the direction descends toward a stable
      !! equilibrium; the step length follows an Armijo backtracking on the energy. mu is
      !! relaxed fourfold after a full step and raised fourfold when a line search fails.
      !! Sets stalled when mu exceeds its cap without an accepted step (q unchanged).
      INTEGER, INTENT(OUT) :: es
      CHARACTER(*), INTENT(OUT) :: em
      REAL(wp), PARAMETER :: ARMIJO = 1.0e-4_wp
      INTEGER, PARAMETER :: MAX_SHIFTS = 60, MAX_HALVINGS = 30
      REAL(wp), PARAMETER :: NEWTON_MERIT = 1.0e-4_wp, NEWTON_MU = 1.0e-6_wp
      REAL(wp) :: pi0, pi_abs0, merit0, dmax, gd, alpha, trial_norm, sc, share0(2)
      INTEGER :: shift, bt, j, i, es_trial, info
      LOGICAL :: accepted
      CHARACTER(1024) :: em_trial
      EXTERNAL :: dpbtrf, dpbtrs

      es = CD_HCSTAT_OK; em = ''
      ab_energy = ab
      r_energy = R
      q_energy = q
      IF (tors_on) THEN
        tors_gs = tors_g
        tors_grs = tors_gr
      END IF
      pi0 = pi_total
      pi_abs0 = pi_abs
      merit0 = rmerit
      ! The floor-carried end moments enter the energy at the end element shares of q_energy,
      ! held over the line search below: along it the residual's end-support load is then the
      ! gradient of the energy the Armijo test uses (gd = R.dq), at the start and at every trial.
      share0 = end_share_last
      ! Close to equilibrium (small residual, and the energy steps needing at most a
      ! negligible shift, i.e. a positive definite tangent), a plain Newton step on the
      ! full (possibly nonsymmetric) tangent with a residual-merit line search comes first. The energy is only a
      ! globalisation device: across the 1 um seabed-contact blend or a waterline the
      ! potential is only piecewise smooth, and on a structured floor the curvature of the
      ! bilinear grid is not differentiated, so near the solution its line search can
      ! collapse to round-off steps where the Newton iteration converges.
      ! (Not during a torsional negative-curvature descent: a Newton step would return to the saddle.)
      IF (merit0 < NEWTON_MERIT .AND. lm_mu <= NEWTON_MU .AND. .NOT. tors_descending) THEN
        dq = -r_energy
        DO j = 1, ndof
          IF (.NOT. solve_mask(j)) dq(j) = CD_ZERO
        END DO
        IF (tors_on) THEN
          tors_rhs = dq
          CALL CD_HermiteTorsion_Bordered_Solve(ab, KL_H, KU_H, tors_gr, tors_c, tors_rhs, dq, es_trial, em_trial)
        ELSE
          CALL CD_Solve_Banded(ab, KL_H, KU_H, dq, es_trial, em_trial)
        END IF
        IF (es_trial == CD_LINALG_OK .AND. CD_All_Finite(dq)) THEN
          IF (use_rigid) CALL rigid_increment_to_global(dq)
          alpha = CD_ONE
          IF (use_rigid) CALL limit_rigid_step(dq, alpha)
          IF (tors_on) CALL limit_torsion_step(tors_gs, dq, alpha)
          skip_tangent = .TRUE.
          ! Only a step that at least halves the merit (a full or half Newton step) is
          ! taken; a Newton direction that makes slower progress leaves the step to the
          ! energy iteration below.
          DO bt = 0, 1
            q = q_energy + alpha*dq
            CALL newton_step(trial_norm, es_trial, em_trial, .FALSE.)
            IF (es_trial == CD_HCSTAT_OK .AND. rmerit <= 0.5_wp*merit0) THEN
              skip_tangent = .FALSE.
              IF (tors_on) tors_theta_acc = tors_theta_eval
              RETURN
            END IF
            alpha = 0.5_wp*alpha
          END DO
          skip_tangent = .FALSE.
        END IF
        q = q_energy
      END IF
      dmax = CD_ZERO
      DO j = 1, ndof
        IF (solve_mask(j)) dmax = MAX(dmax, ABS(ab_energy(KL_H + KU_H + 1, j)))
      END DO
      IF (.NOT. end_share_caller) THEN
        end_share_pi = share0
        end_share_held = .TRUE.
      END IF
      DO shift = 1, MAX_SHIFTS
        ! Symmetric part of K + mu*D in LAPACK lower band storage; fixed DOFs decoupled.
        sym = CD_ZERO
        DO j = 1, ndof
          IF (.NOT. solve_mask(j)) THEN
            sym(1, j) = CD_ONE
            CYCLE
          END IF
          DO i = j, MIN(ndof, j + KL_H)
            IF (.NOT. solve_mask(i)) CYCLE
            sym(1 + i - j, j) = 0.5_wp*(ab_energy(KL_H + KU_H + 1 + i - j, j) + ab_energy(KL_H + KU_H + 1 + j - i, i))
          END DO
          IF (lm_mu > CD_ZERO) sym(1, j) = sym(1, j) + &
                                           lm_mu*MAX(ABS(ab_energy(KL_H + KU_H + 1, j)), 1.0e-12_wp*dmax)
        END DO
        CALL dpbtrf('L', ndof, KL_H, sym, KL_H + 1, info)
        IF (info /= 0) THEN
          lm_mu = MAX(4.0_wp*lm_mu, 1.0e-8_wp)
          IF (lm_mu > 1.0e12_wp) EXIT
          CYCLE
        END IF
        dq = -r_energy
        DO j = 1, ndof
          IF (.NOT. solve_mask(j)) dq(j) = CD_ZERO
        END DO
        IF (tors_on) THEN
          ! (B_sym + mu D + g g^T / C) dq = -R by Sherman-Morrison on the Cholesky factor: the
          ! rank-one term is positive semidefinite, so the direction still descends.
          tors_rhs2(:, 1) = dq
          tors_rhs2(:, 2) = tors_grs
          CALL dpbtrs('L', ndof, KL_H, 2, sym, KL_H + 1, tors_rhs2, ndof, info)
          IF (info == 0) dq = tors_rhs2(:, 1) - tors_rhs2(:, 2)*(DOT_PRODUCT(tors_grs, tors_rhs2(:, 1))/ &
                                                                 (tors_c + DOT_PRODUCT(tors_grs, tors_rhs2(:, 2))))
        ELSE
          CALL dpbtrs('L', ndof, KL_H, 1, sym, KL_H + 1, dq, ndof, info)
        END IF
        IF (info /= 0 .OR. .NOT. CD_All_Finite(dq)) THEN
          lm_mu = MAX(4.0_wp*lm_mu, 1.0e-8_wp)
          IF (lm_mu > 1.0e12_wp) EXIT
          CYCLE
        END IF
        gd = DOT_PRODUCT(r_energy, dq)
        IF (use_rigid) CALL rigid_increment_to_global(dq)
        sc = CD_ONE
        IF (use_rigid) CALL limit_rigid_step(dq, sc)
        IF (tors_on) CALL limit_torsion_step(tors_gs, dq, sc)
        alpha = sc
        skip_tangent = .TRUE.
        DO bt = 0, MAX_HALVINGS
          q = q_energy + alpha*dq
          CALL newton_step(trial_norm, es_trial, em_trial, .FALSE.)
          accepted = .FALSE.
          IF (es_trial == CD_HCSTAT_OK) THEN
            IF (-alpha*gd <= 1.0e-12_wp*pi_abs0) THEN
              ! Below the round-off level of the energy the residual decides.
              accepted = rmerit < merit0
            ELSE
              accepted = pi_total <= pi0 + ARMIJO*alpha*gd
            END IF
          END IF
          IF (accepted) THEN
            skip_tangent = .FALSE.
            end_share_held = end_share_caller
            IF (tors_on) tors_theta_acc = tors_theta_eval
            IF (bt == 0) THEN
              lm_mu = 0.25_wp*lm_mu
              IF (lm_mu < 1.0e-10_wp) lm_mu = CD_ZERO
            END IF
            RETURN
          END IF
          alpha = 0.5_wp*alpha
        END DO
        skip_tangent = .FALSE.
        lm_mu = MAX(4.0_wp*lm_mu, 1.0e-8_wp)
        IF (lm_mu > 1.0e12_wp) EXIT
      END DO
      skip_tangent = .FALSE.
      end_share_held = end_share_caller
      q = q_energy
      stalled = .TRUE.
    END SUBROUTINE energy_update

    SUBROUTINE add_torsion(ecs, ecm)
      !! Condensed torsion at the current q: Theta (unwrapped against the last accepted value; a
      !! change above pi/2 is refused so that the caller cuts the step), M_t = (Phi - Theta)/C,
      !! R <- R - M_t dTheta/dq, band <- band - M_t d2Theta/dq2, energy + (Phi - Theta)**2/(2 C).
      INTEGER, INTENT(OUT) :: ecs
      CHARACTER(*), INTENT(OUT) :: ecm
      REAL(wp) :: raw, th, e_t
      INTEGER :: ks
      CHARACTER(1024) :: km
      ecs = CD_HCSTAT_OK
      ecm = ''
      IF (skip_tangent) THEN
        CALL CD_HermiteTorsion_Line(q, l0, torsion%ends, raw, tors_g, ks, km, &
                                    couple=torsion%couple, quadrature_order=torsion%quadrature_order)
      ELSE
        tors_h = CD_ZERO
        CALL CD_HermiteTorsion_Line(q, l0, torsion%ends, raw, tors_g, ks, km, hband=tors_h, &
                                    couple=torsion%couple, quadrature_order=torsion%quadrature_order)
      END IF
      IF (ks /= CD_HTORS_OK) THEN
        ecs = CD_HCSTAT_NOCONVERGE
        ecm = 'torsion: '//TRIM(km)
        RETURN
      END IF
      th = CD_HermiteTorsion_Unwrap(raw, tors_theta_acc)
      IF (ABS(th - tors_theta_acc) > CD_HTORS_MAX_STEP) THEN
        ecs = CD_HCSTAT_NOCONVERGE
        ecm = 'torsion: the twist changed by more than pi/2 from the last accepted state; cut the step'
        RETURN
      END IF
      tors_theta_eval = th
      tors_mt = (tors_phi_cur - th)/tors_c
      R = R - tors_mt*tors_g
      IF (.NOT. skip_tangent) ab(KL_H + 1:LDAB_H, :) = ab(KL_H + 1:LDAB_H, :) - tors_mt*tors_h
      e_t = 0.5_wp*tors_c*tors_mt*tors_mt
      pi_total = pi_total + e_t
      pi_abs = pi_abs + e_t
    END SUBROUTINE add_torsion

    SUBROUTINE torsion_reduce()
      !! dTheta/dq in the solve coordinates (the rigid-end basis, as apply_rigid_system maps R),
      !! with every held DOF zeroed.
      INTEGER :: iend, base, j
      tors_gr = tors_g
      IF (use_rigid) THEN
        DO iend = 1, 2
          IF (endconn_kind(iend) /= CD_ENDCONN_RIGID) CYCLE
          base = MERGE(3, 6*(nn - 1) + 3, iend == 1)
          tors_gr(base + 1:base + 3) = MATMUL(TRANSPOSE(rigid_basis(:, :, iend)), tors_g(base + 1:base + 3))
        END DO
      END IF
      DO j = 1, ndof
        IF (.NOT. solve_mask(j)) tors_gr(j) = CD_ZERO
      END DO
    END SUBROUTINE torsion_reduce

    SUBROUTINE limit_torsion_step(grad, increment, scale)
      !! Predictive twist-step limit: the linearised change grad . increment may not exceed half
      !! the accepted limit (the acceptance test after the step remains in force).
      REAL(wp), INTENT(IN) :: grad(:), increment(:)
      REAL(wp), INTENT(INOUT) :: scale
      REAL(wp) :: dth
      dth = ABS(DOT_PRODUCT(grad, increment))
      IF (dth*scale > 0.5_wp*CD_HTORS_MAX_STEP) scale = 0.5_wp*CD_HTORS_MAX_STEP/dth
    END SUBROUTINE limit_torsion_step

    SUBROUTINE torsion_take_step(scale, ecs, ecm)
      !! q <- q + scale dq under the twist acceptance rule (CD_HermiteTorsion_Accept): the new
      !! Theta, unwrapped against the last accepted value, may change by at most pi/2 and the
      !! line must pass the fold guard; otherwise the step is halved, at most 30 times.
      REAL(wp), INTENT(IN) :: scale
      INTEGER, INTENT(OUT) :: ecs
      CHARACTER(*), INTENT(OUT) :: ecm
      REAL(wp) :: sfac, raw, th
      INTEGER :: k, ks
      CHARACTER(1024) :: km
      tors_q = q
      sfac = scale
      km = ''
      DO k = 0, 30
        q = tors_q + sfac*dq
        CALL CD_HermiteTorsion_Line(q, l0, torsion%ends, raw, tors_gt, ks, km, &
                                    couple=torsion%couple, quadrature_order=torsion%quadrature_order)
        IF (ks == CD_HTORS_OK) THEN
          CALL CD_HermiteTorsion_Accept(tors_theta_acc, raw, th, ks, km)
          IF (ks == CD_HTORS_OK) THEN
            tors_theta_acc = th
            ecs = CD_HCSTAT_OK
            ecm = ''
            RETURN
          END IF
        END IF
        sfac = 0.5_wp*sfac
      END DO
      q = tors_q
      ecs = CD_HCSTAT_NOCONVERGE
      ecm = 'torsion: no admissible Newton step ('//TRIM(km)//')'
    END SUBROUTINE torsion_take_step

    SUBROUTINE torsion_continuation(ecs, ecm)
      !! The imposed-twist load stage. From the converged untwisted state (Theta_0 on the branch
      !! of torsion%theta_hint on a first solve; on a re-solve with has_theta, within pi/2 of
      !! torsion%theta, or the solve stops by name) Phi is ramped from Theta_0
      !! (zero torque) to torsion%phi in stages of at most pi/4; a failed stage is restored and
      !! halved, at most MAX_CUTS times. Each converged stage is tested for stability and an
      !! unstable one is left by descent (torsion_stage).
      INTEGER, INTENT(OUT) :: ecs
      CHARACTER(*), INTENT(OUT) :: ecm
      INTEGER, PARAMETER :: MAX_CUTS = 10
      REAL(wp), ALLOCATABLE :: q_keep(:)
      REAL(wp) :: raw, phi0, total, lam, lam_try, dlam, dlam_max, th_keep, res_untwisted
      INTEGER :: ks, cuts, wios
      LOGICAL :: ok
      CHARACTER(1024) :: km
      CHARACTER(1024) :: why
      CHARACTER(1024) :: wbuf
      ecs = CD_HCSTAT_OK
      ecm = ''
      res_untwisted = res_out
      torsion%ramp_steps = 0
      torsion%descents = 0
      torsion%stable = .FALSE.
      torsion%n_negative = 0
      torsion%lambda_min = CD_ZERO
      torsion%n_negative_untwisted = -1
      torsion%untwisted_instability = .FALSE.
      CALL CD_HermiteTorsion_Line(q, l0, torsion%ends, raw, tors_g, ks, km, &
                                  couple=torsion%couple, quadrature_order=torsion%quadrature_order)
      IF (ks /= CD_HTORS_OK) THEN
        ecs = CD_HCSTAT_NOCONVERGE
        ecm = 'CD_HermiteCable_Static_Solve: torsion at the untwisted equilibrium: '//TRIM(km)
        RETURN
      END IF
      IF (torsion%has_theta) THEN
        ! A re-solve: the untwisted state must lie within the step limit of the stored Theta,
        ! or its branch is ambiguous (the line may have released more than half a turn of writhe)
        CALL CD_HermiteTorsion_Accept(torsion%theta, raw, tors_theta_acc, ks, km)
        IF (ks /= CD_HTORS_OK) THEN
          ecs = CD_HCSTAT_NOCONVERGE
          ecm = 'CD_HermiteCable_Static_Solve: torsion: the untwisted equilibrium lies more than 90 deg of '// &
                'twist from the stored Theta, so its turn count is ambiguous; solve from a fresh torsion '// &
                'state (has_theta false) with theta_hint on the intended branch'
          RETURN
        END IF
      ELSE IF (ALLOCATED(torsion%couple)) THEN
        ! the hint is the holonomy's; the coupling twist is unambiguous
        tors_theta_acc = CD_HermiteTorsion_Unwrap(raw, torsion%theta_hint + &
                                                  CD_HermiteTorsion_Coupling_Twist(q, l0, torsion%couple, &
                                                                                   torsion%quadrature_order))
      ELSE
        tors_theta_acc = CD_HermiteTorsion_Unwrap(raw, torsion%theta_hint)
      END IF
      phi0 = tors_theta_acc
      total = torsion%phi - phi0
      tors_on = .TRUE.
      tors_q_untw = q
      tors_th_untw = tors_theta_acc
      tors_phi_untw = phi0
      ! |total| <= 4000 pi (Phi and Theta_0 within 1000 turns of zero, Theta_0 within pi of its
      ! start): at most 16000 stages, so the integer stage count cannot overflow
      dlam_max = CD_ONE/REAL(MAX(1, CEILING(MIN(ABS(total), 2.0_wp*CD_HTORS_MAX_TWIST + CD_HTORS_PI)/ &
                                            (0.25_wp*CD_HTORS_PI))), wp)
      dlam = dlam_max
      lam = CD_ZERO
      cuts = 0
      ALLOCATE (q_keep(ndof))
      DO
        lam_try = MIN(CD_ONE, lam + dlam)
        IF (lam_try >= CD_ONE) THEN
          tors_phi_cur = torsion%phi
          tors_load_frac = CD_ONE
        ELSE
          tors_phi_cur = phi0 + lam_try*total
          tors_load_frac = lam_try
        END IF
        q_keep = q
        th_keep = tors_theta_acc
        CALL torsion_stage(ok, why)
        IF (ok) THEN
          lam = lam_try
          torsion%ramp_steps = torsion%ramp_steps + 1
          IF (lam >= CD_ONE) EXIT
          dlam = MIN(dlam_max, 2.0_wp*dlam)
        ELSE
          q = q_keep
          tors_theta_acc = th_keep
          cuts = cuts + 1
          IF (cuts > MAX_CUTS) THEN
            ecs = CD_HCSTAT_NOCONVERGE
            wbuf = ''
            IF (lam <= CD_ZERO .AND. res_untwisted >= tol) THEN
              ! not a loop: the untwisted equilibrium itself never reached the tolerance
              WRITE (wbuf, '(A,ES12.5,A,ES12.5,A)', IOSTAT=wios) &
                'CD_HermiteCable_Static_Solve: torsion continuation could not start: the untwisted '// &
                'equilibrium ends at ||R|| = ', res_untwisted, ' above tol = ', tol, &
                ' (a residual floor of this line); a looser tolerance is needed'
              ecm = wbuf
              RETURN
            END IF
            IF (lam <= CD_ZERO .AND. torsion%n_negative_untwisted > 0) THEN
              ! the first stage failed on an instability the untwisted state already has: not a
              ! loop of the twist (with no twist to impose, not a twist at all)
              WRITE (wbuf, '(A,I0,A,ES12.5,A,ES12.5,A)', IOSTAT=wios) &
                'CD_HermiteCable_Static_Solve: torsion stage failed: the untwisted equilibrium it starts '// &
                'from is itself unstable (', torsion%n_negative_untwisted, ' negative stiffness mode(s) at '// &
                'Phi = Theta_0 = ', phi0, ' rad, target Phi ', torsion%phi, ' rad): '//TRIM(why)
              ecm = wbuf
              RETURN
            END IF
            WRITE (wbuf, '(A,ES12.5,A,ES12.5,A)', IOSTAT=wios) &
              'CD_HermiteCable_Static_Solve: torsion continuation stalled at Phi = ', tors_phi_cur, &
              ' rad (target ', torsion%phi, ' rad): '//TRIM(why)// &
              '; the twisted line has no nearby static equilibrium on this path (for example a loop '// &
              'forming), which needs a dynamic analysis'
            ecm = wbuf
            RETURN
          END IF
          dlam = 0.5_wp*dlam
        END IF
      END DO
    END SUBROUTINE torsion_continuation

    SUBROUTINE torsion_stage(ok, why)
      !! Newton to tol at the current Phi, then (torsion%check_stability) the stability test and,
      !! for an unstable state with torsion%descend, the negative-curvature descent.
      LOGICAL, INTENT(OUT) :: ok
      CHARACTER(*), INTENT(OUT) :: why
      INTEGER :: it2, ks, wios
      REAL(wp) :: rn
      LOGICAL :: st
      CHARACTER(1024) :: km
      CHARACTER(1024) :: wbuf
      ok = .FALSE.
      why = ''
      km = ''
      rn = HUGE(CD_ONE)
      stalled = .FALSE.
      DO it2 = 1, max_iter
        CALL newton_step(rn, ks, km, .TRUE.)
        IF (stalled) THEN
          why = 'the Newton iteration stalled'
          EXIT
        END IF
        IF (ks /= CD_HCSTAT_OK) THEN
          why = km
          EXIT
        END IF
        iters_out = iters_out + 1
        res_out = rn
        IF (rn < tol) THEN
          ok = .TRUE.
          EXIT
        END IF
      END DO
      stalled = .FALSE.
      IF (.NOT. ok) THEN
        IF (LEN_TRIM(why) == 0) THEN
          wbuf = ''
          WRITE (wbuf, '(A,ES12.5)', IOSTAT=wios) 'Newton did not converge, ||R||=', rn
          why = wbuf
        END IF
        RETURN
      END IF
      IF (.NOT. torsion%check_stability) RETURN
      CALL torsion_stability(st, ks, km)
      IF (ks /= CD_HCSTAT_OK) THEN
        ok = .FALSE.
        why = km
        RETURN
      END IF
      torsion%stable = st
      IF (st) RETURN
      ! An unstable stage: is the instability the twist's? The untwisted state's negative count
      ! (once, at the start of the twist) tells; a stage with no more negative eigenvalues than
      ! it is kept under keep_untwisted_instability (a descent would leave an instability the
      ! twist did not bring, and with current drag cannot run at all).
      IF (torsion%keep_untwisted_instability .OR. torsion%descend) THEN
        CALL untwisted_inertia(ks, km)
        IF (ks /= CD_HCSTAT_OK) THEN
          ok = .FALSE.
          why = km
          RETURN
        END IF
      END IF
      IF (torsion%keep_untwisted_instability .AND. torsion%n_negative_untwisted >= 0 .AND. &
          torsion%n_negative <= torsion%n_negative_untwisted) RETURN
      IF (.NOT. torsion%descend) RETURN
      CALL torsion_descent(ok, why)
    END SUBROUTINE torsion_stage

    SUBROUTINE untwisted_inertia(ecs, ecm)
      !! torsion%n_negative_untwisted, once: the stability test of the untwisted equilibrium the
      !! twist started from (tors_q_untw at Phi = Theta_0, no torque); the current state, its
      !! accepted Theta and Phi are then restored and tested again, which restores its report
      !! and the lowest mode the descent takes.
      INTEGER, INTENT(OUT) :: ecs
      CHARACTER(*), INTENT(OUT) :: ecm
      REAL(wp), ALLOCATABLE :: q_now(:)
      REAL(wp) :: th_now, phi_now
      LOGICAL :: st0
      ecs = CD_HCSTAT_OK
      ecm = ''
      IF (torsion%n_negative_untwisted >= 0 .OR. .NOT. ALLOCATED(tors_q_untw)) RETURN
      q_now = q
      th_now = tors_theta_acc
      phi_now = tors_phi_cur
      q = tors_q_untw
      tors_theta_acc = tors_th_untw
      tors_phi_cur = tors_phi_untw
      CALL torsion_stability(st0, ecs, ecm)
      q = q_now
      tors_theta_acc = th_now
      tors_phi_cur = phi_now
      IF (ecs /= CD_HCSTAT_OK) RETURN
      torsion%n_negative_untwisted = MERGE(0, MAX(1, torsion%n_negative), st0)
      CALL torsion_stability(st0, ecs, ecm)
      torsion%stable = st0
    END SUBROUTINE untwisted_inertia

    SUBROUTINE torsion_stability(st, ecs, ecm)
      !! Stability of the state q with torsion: the inertia of the symmetric tangent
      !! B + g g^T / C on the free DOFs (CD_HermiteTorsion_Inertia). A negative (or unreliable)
      !! count is checked by the lowest Jacobi-scaled eigenvalue (CD_HermiteTorsion_Lowest_Mode),
      !! whose mode is kept for the descent; with torsion%zero_mode_allowed one eigenvalue within
      !! CD_HTORS_ZERO_MODE_TOL of zero is neutral. A seabed friction capacity is held at its
      !! equilibrium value, as for the stable argument.
      LOGICAL, INTENT(OUT) :: st
      INTEGER, INTENT(OUT) :: ecs
      CHARACTER(*), INTENT(OUT) :: ecm
      REAL(wp) :: rn, ztol
      INTEGER :: ks, kin, nb, nk
      CHARACTER(1024) :: km
      st = .FALSE.
      ecs = CD_HCSTAT_OK
      ecm = ''
      tors_have_mode = .FALSE.
      IF (use_friction .AND. .NOT. fr_frozen) stab_eval = .TRUE.
      CALL newton_step(rn, ks, km, .FALSE.)
      stab_eval = .FALSE.
      IF (ks /= CD_HCSTAT_OK) THEN
        ecs = CD_HCSTAT_NOCONVERGE
        ecm = 'torsion stability evaluation failed: '//TRIM(km)
        RETURN
      END IF
      CALL CD_HermiteTorsion_Inertia(ab, KL_H, KU_H, solve_mask, tors_gr, tors_c, nb, nk, kin, km)
      torsion%lambda_min = CD_ZERO
      torsion%n_negative = nk
      IF (kin /= CD_HTORS_OK .AND. kin /= CD_HTORS_UNRELIABLE) THEN
        ecs = CD_HCSTAT_NOCONVERGE
        ecm = 'torsion stability evaluation failed: '//TRIM(km)
        RETURN
      END IF
      IF (kin == CD_HTORS_OK .AND. nk == 0) THEN
        st = .TRUE.
        RETURN
      END IF
      CALL CD_HermiteTorsion_Lowest_Mode(ab, KL_H, KU_H, solve_mask, tors_gr, tors_c, tors_lambda, tors_v, ks, km)
      IF (ks /= CD_HTORS_OK) THEN
        ecs = CD_HCSTAT_NOCONVERGE
        ecm = 'torsion stability evaluation failed: '//TRIM(km)
        RETURN
      END IF
      tors_have_mode = .TRUE.
      torsion%lambda_min = tors_lambda
      ! The zero-mode band is relative to the softest physical scale of the Jacobi-scaled
      ! spectrum, the smallest EI/(EA Le^2) (bending against stretching), and at least
      ! a round-off floor: an absolute 1e-8 could absorb a genuine soft bending mode of a stiff-EA
      ! cable.
      ztol = CD_HTORS_ZERO_MODE_TOL*MIN(CD_ONE, soft_scale())
      ztol = MAX(ztol, 1.0e3_wp*EPSILON(CD_ONE))
      IF (kin == CD_HTORS_OK) THEN
        ! a reliable count of nk >= 1 negative eigenvalues: stable only as the allowed zero mode
        st = torsion%zero_mode_allowed .AND. nk == 1 .AND. ABS(tors_lambda) <= ztol
      ELSE
        nk = MERGE(1, 0, tors_lambda < -ztol)
        torsion%n_negative = nk
        st = tors_lambda > ztol .OR. (torsion%zero_mode_allowed .AND. tors_lambda >= -ztol)
      END IF
    END SUBROUTINE torsion_stability

    REAL(wp) FUNCTION soft_scale() RESULT(sc)
      !! min over elements of EI/(EA Le^2) (1 without an axially stiff element).
      INTEGER :: e
      sc = CD_ONE
      DO e = 1, ne
        IF (EA(e) > CD_ZERO .AND. EI(e) > CD_ZERO) sc = MIN(sc, EI(e)/(EA(e)*l0(e)*l0(e)))
      END DO
    END FUNCTION soft_scale

    SUBROUTINE torsion_descent(ok, why)
      !! Leave an unstable twisted equilibrium: perturb along the lowest mode (both senses, a
      !! decreasing amplitude) to a state of lower total energy, then minimise the energy
      !! (energy_update without its Newton shortcut, which would return to the saddle) and test
      !! the stability again; at most MAX_DESCENTS times.
      LOGICAL, INTENT(OUT) :: ok
      CHARACTER(*), INTENT(OUT) :: why
      INTEGER, PARAMETER :: MAX_DESCENTS = 4
      REAL(wp) :: e0, amp, a, rn, vscale, th0
      INTEGER :: attempt, k, j, ks, it2
      LOGICAL :: saved_energy, st, moved
      CHARACTER(1024) :: km
      ok = .FALSE.
      why = ''
      km = ''
      IF (drag_now .OR. (use_friction .AND. .NOT. fr_frozen)) THEN
        why = 'the twisted equilibrium is unstable, and its energy descent needs conservative loads '// &
              '(no current drag or sliding seabed friction)'
        RETURN
      END IF
      DO attempt = 1, MAX_DESCENTS
        IF (.NOT. tors_have_mode) THEN
          why = 'no unstable mode was found for the descent'
          RETURN
        END IF
        skip_tangent = .TRUE.
        CALL newton_step(rn, ks, km, .FALSE.)
        skip_tangent = .FALSE.
        IF (ks /= CD_HCSTAT_OK) THEN
          why = km
          RETURN
        END IF
        e0 = pi_total
        ! the energies compared below take the end element shares of this state (energy_update)
        IF (.NOT. end_share_caller) THEN
          end_share_pi = end_share_last
          end_share_held = .TRUE.
        END IF
        tors_rhs = tors_v
        IF (use_rigid) CALL rigid_increment_to_global(tors_rhs)
        vscale = CD_ZERO
        DO j = 1, ndof
          IF (MOD(j - 1, 6) >= 3) THEN
            vscale = MAX(vscale, ABS(tors_rhs(j)))
          ELSE
            vscale = MAX(vscale, ABS(tors_rhs(j))/trib((j - 1)/6 + 1))
          END IF
        END DO
        IF (.NOT. (vscale > CD_ZERO)) THEN
          end_share_held = end_share_caller
          why = 'the unstable mode vanishes on the free DOFs'
          RETURN
        END IF
        amp = 0.05_wp/vscale
        ! predictive twist limit (the post-trial unwrap cannot tell 3 pi/2 from -pi/2); tors_g is
        ! dTheta/dq at q from the evaluation above
        a = CD_ONE
        CALL limit_torsion_step(tors_g, amp*tors_rhs, a)
        amp = a*amp
        tors_q = q
        th0 = tors_theta_acc
        moved = .FALSE.
        DO k = 0, 11
          a = amp*0.25_wp**(k/2)
          IF (MOD(k, 2) == 1) a = -a
          q = tors_q + a*tors_rhs
          skip_tangent = .TRUE.
          CALL newton_step(rn, ks, km, .FALSE.)
          skip_tangent = .FALSE.
          IF (ks == CD_HCSTAT_OK .AND. pi_total < e0) THEN
            tors_theta_acc = tors_theta_eval
            moved = .TRUE.
            EXIT
          END IF
        END DO
        end_share_held = end_share_caller
        IF (.NOT. moved) THEN
          q = tors_q
          tors_theta_acc = th0
          why = 'no energy-decreasing perturbation along the unstable mode'
          RETURN
        END IF
        saved_energy = use_energy
        use_energy = .TRUE.
        tors_descending = .TRUE.
        lm_mu = CD_ZERO
        stalled = .FALSE.
        ok = .FALSE.
        DO it2 = 1, MAX(max_iter, 200)
          CALL newton_step(rn, ks, km, .TRUE.)
          IF (stalled .OR. ks /= CD_HCSTAT_OK) EXIT
          iters_out = iters_out + 1
          res_out = rn
          IF (rn < tol) THEN
            ok = .TRUE.
            EXIT
          END IF
        END DO
        use_energy = saved_energy
        tors_descending = .FALSE.
        stalled = .FALSE.
        lm_mu = CD_ZERO
        IF (.NOT. ok) THEN
          why = 'the energy descent from the unstable twisted state did not converge'
          IF (LEN_TRIM(km) > 0) why = TRIM(why)//' ('//TRIM(km)//')'
          RETURN
        END IF
        torsion%descents = torsion%descents + 1
        CALL torsion_stability(st, ks, km)
        IF (ks /= CD_HCSTAT_OK) THEN
          ok = .FALSE.
          why = km
          RETURN
        END IF
        torsion%stable = st
        IF (st) RETURN
        ok = .FALSE.
      END DO
      why = 'the descent did not reach a stable twisted equilibrium'
    END SUBROUTINE torsion_descent

    SUBROUTINE setup_friction(fr, ecs, ecm)
      !! Validate the friction and map its reference onto the nodes of this mesh; the
      !! spring stiffness is the nodal normal contact stiffness. mu <= 0 leaves it off.
      TYPE(CD_HermiteStaticFrictionType), INTENT(IN) :: fr
      INTEGER, INTENT(OUT) :: ecs
      CHARACTER(*), INTENT(OUT) :: ecm
      ecs = CD_HCSTAT_OK
      ecm = ''
      IF (.NOT. (fr%mu > CD_ZERO)) RETURN
      use_friction = .TRUE.
      fr_mu = fr%mu
      fr_aniso = fr%mu_axial > CD_ZERO .AND. ABS(fr%mu_axial - fr%mu) > CD_ZERO
      fr_mu_a = fr%mu_axial
      ALLOCATE (fr_k(nn), fr_ref(2, nn))
      IF (use_nodal_contact) THEN
        fr_k = contact_kn
      ELSE
        fr_k = kn*trib
      END IF
      ! an as-laid reference is laid on this mesh, with its nodal loads and stiffnesses
      CALL CD_HermiteCable_Friction_Reference(fr, l0, q(1:2), fr_ref, ecs, ecm, EA=EA, w=w, node_kn=fr_k, &
                                              bathymetry=bathymetry)
      IF (ecs /= CD_HCSTAT_OK) RETURN
      IF (ALLOCATED(fr%frozen_capacity)) THEN
        IF (SIZE(fr%frozen_capacity) /= nn) THEN
          ecs = CD_HCSTAT_BADINPUT; ecm = 'friction: frozen_capacity must have one entry per node'; RETURN
        END IF
        fr_frozen = .TRUE.
        ALLOCATE (fr_cap(nn))
        fr_cap = fr%frozen_capacity
      END IF
    END SUBROUTINE setup_friction

    SUBROUTINE add_friction(node, normal_f, normal_gap_f, gxf, gyf)
      !! Friction spring of one node (see CD_Seabed_Friction_Spring) with its
      !! Jacobian: in x/y through the stretch and, through the capacity mu*normal, in the
      !! penetration (z and, on a sloping floor, x/y).
      INTEGER, INTENT(IN) :: node
      REAL(wp), INTENT(IN) :: normal_f, normal_gap_f, gxf, gyf
      REAL(wp) :: ff(2), dfd(2, 2), dfc(2), dcap(3), cap, dxy(2), e_fr, mu_d, qd, gqd(2)
      INTEGER :: ix, rr, cc
      ix = 6*(node - 1) + 1
      dxy = q(ix:ix + 1) - fr_ref(:, node)
      IF (fr_frozen) THEN
        ! Frozen capacity: a conservative spring with potential (C^2/k) (s - 1).
        cap = fr_cap(node)
        IF (.NOT. (cap > CD_ZERO)) RETURN
        CALL CD_Seabed_Friction_Spring(dxy, fr_k(node), cap, ff, dfd, dfc)
        e_fr = cap*cap/fr_k(node)*(SQRT(CD_ONE + fr_k(node)**2*(dxy(1)**2 + dxy(2)**2)/(cap*cap)) - CD_ONE)
        pi_total = pi_total + e_fr
        pi_abs = pi_abs + e_fr
        dcap = CD_ZERO
      ELSE IF (stab_eval) THEN
        ! Stability tangent: the capacity (direction-dependent when anisotropic) held at its
        ! equilibrium value, so the same force with a symmetric positive definite Jacobian.
        IF (.NOT. (normal_f > CD_ZERO)) RETURN
        IF (fr_aniso) THEN
          CALL CD_Seabed_Friction_Mu_Dir(dxy, fr_mu_a, fr_mu, q(ix + 3:ix + 4), mu_d, qd, gqd)
          cap = mu_d*normal_f
        ELSE
          cap = fr_mu*normal_f
        END IF
        CALL CD_Seabed_Friction_Spring(dxy, fr_k(node), cap, ff, dfd, dfc)
        dcap = CD_ZERO
      ELSE
        IF (.NOT. (normal_f > CD_ZERO)) RETURN
        IF (fr_aniso) THEN
          ! dfc is d(force)/d(normal); the line axis (nodal tangent) is held fixed
          CALL CD_Seabed_Friction_Aniso(CD_FRICTION_SPRING, dxy, fr_k(node), normal_f, fr_mu_a, fr_mu, &
                                        q(ix + 3:ix + 4), ff, dfd, dfc)
          dcap = normal_gap_f*[gxf, gyf, -CD_ONE]
        ELSE
          CALL CD_Seabed_Friction_Spring(dxy, fr_k(node), fr_mu*normal_f, ff, dfd, dfc)
          ! d(capacity)/d(x, y, z): the penetration is z_floor(x, y) - z.
          dcap = fr_mu*normal_gap_f*[gxf, gyf, -CD_ONE]
        END IF
      END IF
      R(ix:ix + 1) = R(ix:ix + 1) + ff
      IF (skip_tangent) RETURN
      DO rr = 1, 2
        DO cc = 1, 2
          ab(KL_H + KU_H + 1 + (ix + rr - 1) - (ix + cc - 1), ix + cc - 1) = &
            ab(KL_H + KU_H + 1 + (ix + rr - 1) - (ix + cc - 1), ix + cc - 1) + dfd(rr, cc) + dfc(rr)*dcap(cc)
        END DO
        ab(KL_H + KU_H + 1 + (ix + rr - 1) - (ix + 2), ix + 2) = &
          ab(KL_H + KU_H + 1 + (ix + rr - 1) - (ix + 2), ix + 2) + dfc(rr)*dcap(3)
      END DO
    END SUBROUTINE add_friction

    SUBROUTINE setup_current(ecs, ecm)
      !! Validate the current and map its section properties onto this mesh.
      INTEGER, INTENT(OUT) :: ecs
      CHARACTER(*), INTENT(OUT) :: ecm
      ALLOCATE (cur_d(ne), cur_cn(ne), cur_ct(ne))
      CALL current_element_props(current, l0, cur_d, cur_cn, cur_ct, ecs, ecm)
    END SUBROUTINE setup_current

    SUBROUTINE add_current_drag(ecs, ecm)
      !! Drag of the steady current on the line at rest (relative velocity u_f - 0), with
      !! its position Jacobian unless only the residual is wanted. R = f_int - f_ext, so the
      !! load enters R and the tangent with a minus sign.
      INTEGER, INTENT(OUT) :: ecs
      CHARACTER(*), INTENT(OUT) :: ecm
      REAL(wp) :: qe(12)
      INTEGER :: e, a, b2, gi2, gj2
      LOGICAL :: want_jac
      ecs = CD_HCSTAT_OK
      ecm = ''
      want_jac = .NOT. skip_tangent
      ! The element loads are independent: evaluated concurrently into the element buffers
      ! (free once the internal forces are scattered), then scattered in element order, so
      ! the sums are those of the serial loop.
      !$OMP PARALLEL DEFAULT(SHARED) PRIVATE(qe) NUM_THREADS(omp_threads) IF(ne >= 32)
      CALL CD_Fatal_Thread_Init() ! this thread can report its own stack overflow
      !$OMP DO SCHEDULE(STATIC)
      DO e = 1, ne
        qe(1:6) = q(6*(e - 1) + 1:6*e)
        qe(7:12) = q(6*e + 1:6*e + 6)
        CALL current_element_load(current, qe, l0(e), cur_d(e), cur_cn(e), cur_ct(e), want_jac, &
                                  elem_f(:, e), elem_K(:, :, e), elem_es(e), elem_em(e))
      END DO
      !$OMP END DO
      !$OMP END PARALLEL
      DO e = 1, ne
        IF (elem_es(e) /= CD_HCSTAT_OK) THEN
          ecs = elem_es(e)
          ecm = elem_em(e)
          RETURN
        END IF
        DO a = 1, 12
          gi2 = elem_gdof(e, a)
          R(gi2) = R(gi2) - elem_f(a, e)
          IF (skip_tangent) CYCLE
          DO b2 = 1, 12
            gj2 = elem_gdof(e, b2)
            ab(KL_H + KU_H + 1 + gi2 - gj2, gj2) = ab(KL_H + KU_H + 1 + gi2 - gj2, gj2) - elem_K(a, b2, e)
          END DO
        END DO
      END DO
    END SUBROUTINE add_current_drag

    LOGICAL FUNCTION tangent_positive_definite() RESULT(pd)
      !! Positive definiteness of the symmetric part of the assembled tangent on the free
      !! DOFs, after symmetric Jacobi scaling (a non-positive diagonal fails at once).
      REAL(wp), ALLOCATABLE :: sb(:, :), dsc(:)
      INTEGER :: jj, ii, info
      EXTERNAL :: dpbtrf
      pd = .FALSE.
      ALLOCATE (sb(KL_H + 1, ndof), dsc(ndof))
      dsc = CD_ONE
      DO jj = 1, ndof
        IF (.NOT. solve_mask(jj)) CYCLE
        IF (.NOT. (ab(KL_H + KU_H + 1, jj) > CD_ZERO)) RETURN
        dsc(jj) = CD_ONE/SQRT(ab(KL_H + KU_H + 1, jj))
      END DO
      sb = CD_ZERO
      DO jj = 1, ndof
        IF (.NOT. solve_mask(jj)) THEN
          sb(1, jj) = CD_ONE
          CYCLE
        END IF
        DO ii = jj, MIN(ndof, jj + KL_H)
          IF (.NOT. solve_mask(ii)) CYCLE
          sb(1 + ii - jj, jj) = 0.5_wp*(ab(KL_H + KU_H + 1 + ii - jj, jj) + ab(KL_H + KU_H + 1 + jj - ii, ii))* &
                                dsc(ii)*dsc(jj)
        END DO
      END DO
      CALL dpbtrf('L', ndof, KL_H, sb, KL_H + 1, info)
      pd = info == 0
    END FUNCTION tangent_positive_definite

    PURE REAL(wp) FUNCTION seabed_potential(gap, stiffness) RESULT(u)
      !! Antiderivative in gap of CD_Seabed_Normal_Law (zero for a clear node, C2 at the
      !! blend edges): the penalty potential whose z-gradient is minus the normal force.
      REAL(wp), INTENT(IN) :: gap, stiffness
      IF (gap <= -CD_SEABED_CONTACT_BLEND) THEN
        u = CD_ZERO
      ELSE IF (gap < CD_SEABED_CONTACT_BLEND) THEN
        u = stiffness*(gap + CD_SEABED_CONTACT_BLEND)**3/(12.0_wp*CD_SEABED_CONTACT_BLEND)
      ELSE
        u = stiffness*(0.5_wp*gap*gap + CD_SEABED_CONTACT_BLEND**2/6.0_wp)
      END IF
    END FUNCTION seabed_potential

    LOGICAL FUNCTION rigid_rays_valid(state) RESULT(valid)
      REAL(wp), INTENT(IN) :: state(:)
      INTEGER :: iend, base
      REAL(wp) :: magnitude
      valid = .TRUE.
      DO iend = 1, 2
        IF (endconn_kind(iend) /= CD_ENDCONN_RIGID) CYCLE
        IF (iend == 1) THEN
          base = 3
        ELSE
          base = 6*(nn - 1) + 3
        END IF
        magnitude = DOT_PRODUCT(state(base + 1:base + 3), endconn_d0(:, iend))
        IF (.NOT. CD_Is_Finite(magnitude) .OR. magnitude <= SQRT(TINY(CD_ONE))) THEN
          valid = .FALSE.
          RETURN
        END IF
      END DO
    END FUNCTION rigid_rays_valid

    SUBROUTINE limit_rigid_step(increment, scale)
      !! The reduced axial coordinate is a tangent magnitude, not a signed
      !! coordinate. Keep every Newton trial on the positive prescribed ray;
      !! otherwise a sufficiently large axial update could cross through zero
      !! and converge to the antiparallel branch without violating the two
      !! eliminated transverse equations.
      REAL(wp), INTENT(IN) :: increment(:)
      REAL(wp), INTENT(INOUT) :: scale
      INTEGER :: iend, base
      REAL(wp) :: current_magnitude, magnitude_increment
      DO iend = 1, 2
        IF (endconn_kind(iend) /= CD_ENDCONN_RIGID) CYCLE
        IF (iend == 1) THEN
          base = 3
        ELSE
          base = 6*(nn - 1) + 3
        END IF
        current_magnitude = DOT_PRODUCT(q(base + 1:base + 3), endconn_d0(:, iend))
        magnitude_increment = DOT_PRODUCT(increment(base + 1:base + 3), endconn_d0(:, iend))
        IF (magnitude_increment < CD_ZERO) &
          scale = MIN(scale, 0.5_wp*current_magnitude/(-magnitude_increment))
      END DO
    END SUBROUTINE limit_rigid_step

    SUBROUTINE apply_rigid_system(residual, tangent)
      REAL(wp), INTENT(INOUT) :: residual(:), tangent(:, :)
      INTEGER :: iend, base
      REAL(wp) :: local_residual(3)
      DO iend = 1, 2
        IF (endconn_kind(iend) /= CD_ENDCONN_RIGID) CYCLE
        IF (iend == 1) THEN
          base = 3
        ELSE
          base = 6*(nn - 1) + 3
        END IF
        local_residual = MATMUL(TRANSPOSE(rigid_basis(:, :, iend)), &
                                residual(base + 1:base + 3))
        residual(base + 1:base + 3) = local_residual
        CALL transform_band_tangent_block(tangent, base + 1, rigid_basis(:, :, iend))
      END DO
    END SUBROUTINE apply_rigid_system

    SUBROUTINE rigid_increment_to_global(increment)
      REAL(wp), INTENT(INOUT) :: increment(:)
      INTEGER :: iend, base
      REAL(wp) :: global_increment(3)
      DO iend = 1, 2
        IF (endconn_kind(iend) /= CD_ENDCONN_RIGID) CYCLE
        IF (iend == 1) THEN
          base = 3
        ELSE
          base = 6*(nn - 1) + 3
        END IF
        global_increment = MATMUL(rigid_basis(:, :, iend), increment(base + 1:base + 3))
        increment(base + 1:base + 3) = global_increment
      END DO
    END SUBROUTINE rigid_increment_to_global

    SUBROUTINE transform_band_tangent_block(tangent, first, basis)
      !! In-place congruence transform A <- T**T A T for one adjacent
      !! three-DOF block, retaining the module's general-band storage.
      REAL(wp), INTENT(INOUT) :: tangent(:, :)
      INTEGER, INTENT(IN) :: first
      REAL(wp), INTENT(IN) :: basis(3, 3)
      REAL(wp) :: old_values(3), new_values(3)
      INTEGER :: row, col, j

      ! Right multiplication, mixing the three selected columns.
      DO row = MAX(1, first - KU_H), MIN(ndof, first + 2 + KL_H)
        DO j = 1, 3
          old_values(j) = band_entry(tangent, row, first + j - 1)
        END DO
        new_values = MATMUL(old_values, basis)
        DO j = 1, 3
          CALL set_band_entry(tangent, row, first + j - 1, new_values(j))
        END DO
      END DO

      ! Left multiplication by the transpose, mixing the selected rows.
      DO col = MAX(1, first - KL_H), MIN(ndof, first + 2 + KU_H)
        DO j = 1, 3
          old_values(j) = band_entry(tangent, first + j - 1, col)
        END DO
        new_values = MATMUL(TRANSPOSE(basis), old_values)
        DO j = 1, 3
          CALL set_band_entry(tangent, first + j - 1, col, new_values(j))
        END DO
      END DO
    END SUBROUTINE transform_band_tangent_block

    PURE REAL(wp) FUNCTION band_entry(tangent, row, col) RESULT(value)
      REAL(wp), INTENT(IN) :: tangent(:, :)
      INTEGER, INTENT(IN) :: row, col
      value = CD_ZERO
      IF (row < 1 .OR. row > ndof .OR. col < 1 .OR. col > ndof) RETURN
      IF (row - col < -KU_H .OR. row - col > KL_H) RETURN
      value = tangent(KL_H + KU_H + 1 + row - col, col)
    END FUNCTION band_entry

    SUBROUTINE set_band_entry(tangent, row, col, value)
      REAL(wp), INTENT(INOUT) :: tangent(:, :)
      INTEGER, INTENT(IN) :: row, col
      REAL(wp), INTENT(IN) :: value
      IF (row < 1 .OR. row > ndof .OR. col < 1 .OR. col > ndof) RETURN
      IF (row - col < -KU_H .OR. row - col > KL_H) RETURN
      tangent(KL_H + KU_H + 1 + row - col, col) = value
    END SUBROUTINE set_band_entry

    SUBROUTINE add_end_connection(node, k_rot, d0, ec_stat, ec_msg)
      !! Scatter one rotational end connection into the residual and the band tangent.
      !!
      !! The spring is a function of that node's tangent triple only, so its 3x3 tangent
      !! block sits on the band diagonal (|gi - gj| <= 2, against a half-bandwidth of 11)
      !! and cannot widen the band. A non-positive stiffness is a pinned end and returns
      !! without touching anything.
      INTEGER, INTENT(IN) :: node
      REAL(wp), INTENT(IN) :: k_rot, d0(3)
      INTEGER, INTENT(OUT) :: ec_stat
      CHARACTER(*), INTENT(OUT) :: ec_msg
      REAL(wp) :: f_ec(3), k_ec(3, 3), cross(3), theta
      INTEGER :: base, i, j, gi2, gj2
      ec_stat = CD_ENDCONN_OK
      ec_msg = ''
      IF (k_rot <= CD_ZERO) RETURN
      base = 6*(node - 1) + 3                    ! tangent DOFs are base+1 .. base+3
      CALL CD_EndConn_Spring(q(base + 1:base + 3), d0, eifac*k_rot, f_ec, k_ec, ec_stat, ec_msg)
      IF (ec_stat /= CD_ENDCONN_OK) RETURN
      ! Spring potential k*theta**2/2, theta the angle between the tangent and d0.
      cross = [q(base + 2)*d0(3) - q(base + 3)*d0(2), q(base + 3)*d0(1) - q(base + 1)*d0(3), &
               q(base + 1)*d0(2) - q(base + 2)*d0(1)]
      theta = ATAN2(NORM2(cross), DOT_PRODUCT(q(base + 1:base + 3), d0))
      pi_total = pi_total + 0.5_wp*eifac*k_rot*theta*theta
      pi_abs = pi_abs + 0.5_wp*eifac*k_rot*theta*theta
      R(base + 1:base + 3) = R(base + 1:base + 3) + f_ec
      DO j = 1, 3
        gj2 = base + j
        DO i = 1, 3
          gi2 = base + i
          ab(KL_H + KU_H + 1 + gi2 - gj2, gj2) = ab(KL_H + KU_H + 1 + gi2 - gj2, gj2) + k_ec(i, j)
        END DO
      END DO
    END SUBROUTINE add_end_connection

    SUBROUTINE add_end_support(iend, e, inode, sgn, sp_stat, sp_msg)
      !! Scatter the floor-carried end moment of held end iend (end element e, inner node
      !! inode; sgn = -1 at node 1, +1 at node nn) into the residual and the band tangent:
      !! the element's consistent weight moment w l0^2/12 along end_support(:, iend) times
      !! the share of the element lying on the floor (CD_Seabed_End_Element_Share of the
      !! inner node's elastic normal force, the same contact law as the assembly below). The
      !! share couples the end tangent to the inner node's translations. The load is not
      !! conservative where the share is between 0 and 1 (its conjugate force on the inner
      !! node, mom (dS/dgap) (d.m) n, would be a contact force the floor does not exert), so
      !! the potential takes the share end_share_pi (the share at the iterate, or the share
      !! held by an energy line search, see energy_update): the residual is then the gradient
      !! of the potential along a search, as for the other non-potential loads (current drag,
      !! friction). The share at the iterate is recorded in end_share_last.
      INTEGER, INTENT(IN) :: iend, e, inode
      REAL(wp), INTENT(IN) :: sgn
      INTEGER, INTENT(OUT) :: sp_stat
      CHARACTER(*), INTENT(OUT) :: sp_msg
      REAL(wp) :: z_fl, gxg_s, gyg_s, g_s(2), sf, n_in(3), pen_s, normal_s, normal_gap_s, elem, delem, mom
      REAL(wp) :: elem_pi
      INTEGER :: base, bin, i, j
      CHARACTER(1024) :: em_s
      sp_stat = CD_HCSTAT_OK
      sp_msg = ''
      base = MERGE(3, 6*(nn - 1) + 3, iend == 1)  ! end tangent DOFs are base+1 .. base+3
      bin = 6*(inode - 1)                         ! inner-node translations bin+1 .. bin+3
      z_fl = seabed_z
      g_s = CD_ZERO
      IF (use_bathymetry) THEN
        CALL CD_Bathymetry_Floor_Gradient(bathymetry, contact_cs(1)*q(bin + 1) - contact_cs(2)*q(bin + 2), &
                                          contact_cs(2)*q(bin + 1) + contact_cs(1)*q(bin + 2), &
                                          z_fl, gxg_s, gyg_s, sp_stat, em_s)
        IF (sp_stat /= CD_BATHY_OK) THEN
          sp_stat = CD_HCSTAT_NOCONVERGE; sp_msg = 'bathymetry query failed: '//TRIM(em_s); RETURN
        END IF
        g_s = [contact_cs(1)*gxg_s + contact_cs(2)*gyg_s, -contact_cs(2)*gxg_s + contact_cs(1)*gyg_s]
      END IF
      sf = SQRT(CD_ONE + g_s(1)*g_s(1) + g_s(2)*g_s(2))
      n_in = [-g_s(1), -g_s(2), CD_ONE]/sf
      pen_s = (z_fl - q(bin + 3))/sf
      IF (use_nodal_contact) THEN
        CALL CD_Seabed_Normal_Law(pen_s, contact_kn(inode), normal_s, normal_gap_s)
      ELSE IF (pen_s > CD_ZERO) THEN
        normal_s = kn*trib(inode)*pen_s
        normal_gap_s = kn*trib(inode)
      ELSE
        normal_s = CD_ZERO
        normal_gap_s = CD_ZERO
      END IF
      CALL CD_Seabed_End_Element_Share(normal_s, normal_gap_s, 0.5_wp*w_cur(e)*l0(e), elem, delem)
      end_share_last(iend) = elem
      elem_pi = elem
      IF (end_share_held) elem_pi = end_share_pi(iend)
      mom = sgn*w_cur(e)*l0(e)*l0(e)/12.0_wp
      IF (elem_pi > CD_ZERO) THEN
        pi_total = pi_total + mom*elem_pi*DOT_PRODUCT(end_support(:, iend), q(base + 1:base + 3))
        pi_abs = pi_abs + ABS(mom*elem_pi*DOT_PRODUCT(end_support(:, iend), q(base + 1:base + 3)))
      END IF
      IF (.NOT. (elem > CD_ZERO)) RETURN
      R(base + 1:base + 3) = R(base + 1:base + 3) + (mom*elem)*end_support(:, iend)
      ! d(gap)/d(r_inner) = -n_in (floor gradient held over the node)
      IF (.NOT. (delem <= CD_ZERO .AND. delem >= CD_ZERO)) THEN
        DO j = 1, 3
          DO i = 1, 3
            ab(KL_H + KU_H + 1 + base + i - bin - j, bin + j) = ab(KL_H + KU_H + 1 + base + i - bin - j, bin + j) - &
                                                                mom*delem*end_support(i, iend)*n_in(j)
          END DO
        END DO
      END IF
    END SUBROUTINE add_end_support

    PURE REAL(wp) FUNCTION residual_merit(residual) RESULT(value)
      !! Half the squared two-norm of the scaled residual over free DOFs. The
      !! common force scale is omitted because it does not change descent.
      REAL(wp), INTENT(IN) :: residual(:)
      INTEGER :: j

      value = CD_ZERO
      DO j = 1, ndof
        IF (solve_mask(j)) value = value + 0.5_wp*residual(j)*residual(j)
      END DO
    END FUNCTION residual_merit

    PURE INTEGER FUNCTION elem_gdof(e, a) RESULT(g)
      !! Map element-local DOF a (1..12) of element e to the global DOF index.
      INTEGER, INTENT(IN) :: e, a
      IF (a <= 6) THEN
        g = 6*(e - 1) + a
      ELSE
        g = 6*e + (a - 6)
      END IF
    END FUNCTION elem_gdof

    REAL(wp) FUNCTION nodal_curvature(a) RESULT(kap)
      !! Centreline curvature reported at node a (element midpoint of an adjacent element).
      INTEGER, INTENT(IN) :: a
      REAL(wp) :: qe(12), kL, kR
      INTEGER :: es3
      CHARACTER(200) :: em3
      kap = CD_ZERO
      IF (a <= ne) THEN
        CALL gather_elem(a, qe)
        CALL CD_HermiteCable_Curvature(qe, l0(a), CD_ZERO, kR, es3, em3)
        IF (es3 == CD_HCABLE_OK) kap = kR
      END IF
      IF (a >= 2) THEN
        CALL gather_elem(a - 1, qe)
        CALL CD_HermiteCable_Curvature(qe, l0(a - 1), CD_ONE, kL, es3, em3)
        IF (es3 == CD_HCABLE_OK) kap = MAX(kap, kL)
      END IF
    END FUNCTION nodal_curvature

    SUBROUTINE gather_elem(e, qe)
      INTEGER, INTENT(IN) :: e
      REAL(wp), INTENT(OUT) :: qe(12)
      qe(1:3) = q(6*(e - 1) + 1:6*(e - 1) + 3)
      qe(4:6) = q(6*(e - 1) + 4:6*(e - 1) + 6)
      qe(7:9) = q(6*e + 1:6*e + 3)
      qe(10:12) = q(6*e + 4:6*e + 6)
    END SUBROUTINE gather_elem

    SUBROUTINE fail(msg)
      CHARACTER(*), INTENT(IN) :: msg
      ErrStat = CD_HCSTAT_BADINPUT
      ErrMsg = 'CD_HermiteCable_Static_Solve: '//msg
    END SUBROUTINE fail

  END SUBROUTINE CD_HermiteCable_Static_Solve

  SUBROUTINE CD_HermiteCable_As_Laid_Offsets(fr, l0, EA, node_load, node_kn, offsets, ErrStat, ErrMsg, bathymetry, &
                                             node_dry_load)
    !! As-laid friction reference of the nodes of mesh l0 (the lay of fr, laid_* above;
    !! CD_Static_As_Laid_Reference): node i at the stretched arc length of the elements
    !! l0 (1 + laid_tension/EA) along the seabed from the lower end, and on a bathymetry
    !! moved with its sink into the penalty seabed under its nodal load node_load(i) [N,
    !! downward positive] over its nodal seabed stiffness node_kn(i) [N/m] (with the
    !! turning force of the laid tension). offsets(1:2, i) is the reference of node i less
    !! the global position laid_node1 of node 1, in the solve frame laid_frame_cs; with
    !! laid_in_plane on a bathymetry only the sink offset across the chord leaves its plane.
    !! node_load holds the submerged weights. On a bathymetry with fr%laid_water_weight > 0 a
    !! node sinks under the normal load the solver applies at its laid position instead
    !! (laid_dry_loads): with the buoyancy the line gives back on its part above the still-water
    !! level fr%laid_waterline_z (CD_HermiteCable_Dry_Buoyancy of the laid centreline: a section
    !! within its radius of the surface is partly dry), and node_dry_load(i) [N, downward, the
    !! buoyancy of the attachments on node i] where node i is laid above that level.
    TYPE(CD_HermiteStaticFrictionType), INTENT(IN) :: fr
    REAL(wp), INTENT(IN) :: l0(:), EA(:), node_load(:), node_kn(:)
    REAL(wp), INTENT(OUT) :: offsets(:, :)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    TYPE(CD_BathymetryType), INTENT(IN), OPTIONAL :: bathymetry
    REAL(wp), INTENT(IN), OPTIONAL :: node_dry_load(:)
    REAL(wp), ALLOCATABLE :: ref_g(:, :), ref_0(:, :), wn(:), sn(:), kn_o(:), l0_r(:), ea_r(:), load(:)
    REAL(wp) :: dg(2), dg0(2), cs(2)
    INTEGER :: k, ne, es
    CHARACTER(1024) :: em
    ErrStat = CD_HCSTAT_OK
    ErrMsg = ''
    ne = SIZE(l0)
    IF (ne < 1 .OR. SIZE(EA) /= ne .OR. SIZE(node_load) /= ne + 1 .OR. SIZE(node_kn) /= ne + 1 .OR. &
        SIZE(offsets, 1) /= 2 .OR. SIZE(offsets, 2) /= ne + 1) THEN
      ErrStat = CD_HCSTAT_BADINPUT; ErrMsg = 'as-laid friction reference: inconsistent array sizes'; RETURN
    END IF
    IF (.NOT. CD_All_Finite(node_load) .OR. .NOT. CD_All_Finite(node_kn)) THEN
      ErrStat = CD_HCSTAT_BADINPUT; ErrMsg = 'as-laid friction reference: nodal loads and stiffnesses must be finite'
      RETURN
    END IF
    IF (PRESENT(node_dry_load)) THEN
      IF (SIZE(node_dry_load) /= ne + 1 .OR. .NOT. CD_All_Finite(node_dry_load)) THEN
        ErrStat = CD_HCSTAT_BADINPUT
        ErrMsg = 'as-laid friction reference: node_dry_load must be finite, one entry per node'; RETURN
      END IF
    END IF
    offsets = CD_ZERO
    ALLOCATE (ref_g(2, ne + 1))
    IF (PRESENT(bathymetry)) THEN
      load = node_load
      IF (fr%laid_water_weight > CD_ZERO) THEN
        CALL laid_dry_loads(load, es, em)
        IF (es /= CD_HCSTAT_OK) THEN
          ErrStat = CD_HCSTAT_BADINPUT; ErrMsg = 'as-laid friction reference: '//TRIM(em); RETURN
        END IF
      END IF
      ! the static penalty penetration factor w_i/k_i of every node
      ALLOCATE (wn(ne + 1))
      WHERE (node_kn > CD_ZERO)
        wn = MAX(load, CD_ZERO)/node_kn
      ELSEWHERE
        wn = CD_ZERO
      END WHERE
      IF (fr%laid_from_top) THEN
        sn = wn(ne + 1:1:-1)
        kn_o = node_kn(ne + 1:1:-1)
      ELSE
        sn = wn
        kn_o = node_kn
      END IF
    END IF
    IF (fr%laid_from_top) THEN
      ! the line is laid from its bottom end, here the last node
      l0_r = l0(ne:1:-1)
      ea_r = EA(ne:1:-1)
    ELSE
      l0_r = l0
      ea_r = EA
    END IF
    ! sn and kn_o are unallocated (absent) without a bathymetry
    CALL CD_Static_As_Laid_Reference(fr%laid_origin, fr%laid_azimuth, l0_r, ea_r, fr%laid_tension, ref_g, es, em, &
                                     bathymetry=bathymetry, sink=sn, kn=kn_o)
    IF (es /= CD_STATIC_OK) THEN
      ErrStat = CD_HCSTAT_BADINPUT; ErrMsg = TRIM(em); RETURN
    END IF
    IF (fr%laid_from_top) ref_g = ref_g(:, ne + 1:1:-1)
    ! the laid line without the sink of its nodes: its cross-plane offset is geometric
    ref_0 = ref_g
    IF (fr%laid_in_plane .AND. PRESENT(bathymetry)) THEN
      CALL CD_Static_As_Laid_Reference(fr%laid_origin, fr%laid_azimuth, l0_r, ea_r, fr%laid_tension, ref_0, es, em, &
                                       bathymetry=bathymetry)
      IF (es /= CD_STATIC_OK) THEN
        ErrStat = CD_HCSTAT_BADINPUT; ErrMsg = TRIM(em); RETURN
      END IF
      IF (fr%laid_from_top) ref_0 = ref_0(:, ne + 1:1:-1)
    END IF
    cs = fr%laid_frame_cs
    DO k = 1, ne + 1
      dg = ref_g(:, k) - fr%laid_node1
      offsets(:, k) = [cs(1)*dg(1) + cs(2)*dg(2), -cs(2)*dg(1) + cs(1)*dg(2)]
      IF (fr%laid_in_plane) THEN
        ! the laid line lies in the vertical plane of the chord: only the sink offset of the
        ! nodes on a cross slope (zero on a flat floor) leaves it
        dg0 = ref_0(:, k) - fr%laid_node1
        offsets(2, k) = (-cs(2)*dg(1) + cs(1)*dg(2)) - (-cs(2)*dg0(1) + cs(1)*dg0(2))
      END IF
    END DO

  CONTAINS

    SUBROUTINE laid_dry_loads(nl, esd, emd)
      !! The nodal loads nl (the submerged weights on entry) as the static solve and the dynamics
      !! apply them to a node resting at its laid position: the line laid without its sink, the
      !! seabed under every node, the tangent along the laid path stretched by the laid tension.
      !! There a node of load W stands at the height z = z_floor - W (1 + |grad z_floor|^2)/k of
      !! the penalty seabed's static penetration, and the line gives back the buoyancy
      !! laid_water_weight pi d^2/4 of its part above laid_waterline_z
      !! (CD_HermiteCable_Dry_Buoyancy with the section radius d/2, d the laid_diam of the
      !! element's midpoint arc), a node above that level also node_dry_load: W = nl + the dry
      !! load at z(W), solved by Newton's method with the dry load's exact height derivative (its
      !! residual decreases monotonically in W), each step halved until it reduces the residual's
      !! 2-norm: a full step can jump between a node held off the floor (wholly dry) and one sunk
      !! below the surface (wholly wet) and cycle there. The turning force of the laid tension is left
      !! out of the height. nl is unchanged where the line lies below the surface by more than
      !! its radius.
      REAL(wp), INTENT(INOUT) :: nl(:)
      INTEGER, INTENT(OUT) :: esd
      CHARACTER(*), INTENT(OUT) :: emd
      INTEGER, PARAMETER :: MAX_NEWTON = 200
      REAL(wp), PARAMETER :: LOAD_RTOL = 1.0e-12_wp
      ! the Armijo slope of the step acceptance and the shortest step tried
      REAL(wp), PARAMETER :: ARMIJO = 1.0e-4_wp, MIN_STEP = 2.0_wp**(-30)
      REAL(wp), ALLOCATABLE :: ref_u(:, :), zf(:), dzds(:), sfac2(:), de(:), base(:), wl(:), z(:), fd(:), &
                               gres(:), dg(:), lo(:), up(:), y(:), wl_acc(:)
      REAL(wp) :: dir(2), gx, gy, ga, qz(4), fdry(4), kdry(4, 4), s_mid, stretch, scale_w, piv, gnorm, &
                  gnorm_acc, lam
      INTEGER :: j, e, ix, esq, it
      LOGICAL :: dry, any_dry
      esd = CD_HCSTAT_OK
      emd = ''
      IF (.NOT. (ALLOCATED(fr%laid_arc_end) .AND. ALLOCATED(fr%laid_diam))) RETURN
      IF (SIZE(fr%laid_arc_end) < 1 .OR. SIZE(fr%laid_diam) /= SIZE(fr%laid_arc_end)) THEN
        esd = CD_HCSTAT_BADINPUT; emd = 'the dry-part diameter profile is inconsistent'; RETURN
      END IF
      IF (ANY(node_kn <= CD_ZERO)) RETURN
      ! the laid path without the sink, from the lower end, in node order
      ALLOCATE (ref_u(2, ne + 1), zf(ne + 1), dzds(ne + 1), sfac2(ne + 1), de(ne))
      IF (fr%laid_from_top) THEN
        CALL CD_Static_As_Laid_Reference(fr%laid_origin, fr%laid_azimuth, l0(ne:1:-1), EA(ne:1:-1), &
                                         fr%laid_tension, ref_u, esq, emd, bathymetry=bathymetry)
        ref_u = ref_u(:, ne + 1:1:-1)
      ELSE
        CALL CD_Static_As_Laid_Reference(fr%laid_origin, fr%laid_azimuth, l0, EA, fr%laid_tension, ref_u, esq, &
                                         emd, bathymetry=bathymetry)
      END IF
      IF (esq /= CD_STATIC_OK) THEN
        esd = CD_HCSTAT_BADINPUT; RETURN
      END IF
      dir = [COS(fr%laid_azimuth), SIN(fr%laid_azimuth)]
      DO j = 1, ne + 1
        CALL CD_Bathymetry_Floor_Gradient(bathymetry, ref_u(1, j), ref_u(2, j), zf(j), gx, gy, esq, emd)
        IF (esq /= CD_BATHY_OK) THEN
          esd = CD_HCSTAT_BADINPUT; RETURN
        END IF
        ! the rise of the laid path per unit length along it, in node order (laid from the last
        ! node, the node order runs against the lay)
        ga = gx*dir(1) + gy*dir(2)
        dzds(j) = MERGE(-CD_ONE, CD_ONE, fr%laid_from_top)*ga/SQRT(CD_ONE + ga*ga)
        sfac2(j) = CD_ONE + gx*gx + gy*gy
      END DO
      s_mid = CD_ZERO
      ix = 1
      DO e = 1, ne
        s_mid = s_mid + 0.5_wp*l0(e)
        DO WHILE (ix < SIZE(fr%laid_arc_end))
          IF (fr%laid_arc_end(ix) >= s_mid) EXIT
          ix = ix + 1
        END DO
        s_mid = s_mid + 0.5_wp*l0(e)
        de(e) = fr%laid_diam(ix)
      END DO
      base = nl
      wl = nl
      scale_w = MAX(CD_ONE, MAXVAL(ABS(base)))
      ALLOCATE (z(ne + 1), fd(ne + 1), gres(ne + 1), dg(ne + 1), lo(ne + 1), up(ne + 1), y(ne + 1), &
                wl_acc(ne + 1))
      wl_acc = wl
      gnorm_acc = HUGE(CD_ONE)
      lam = CD_ONE
      DO it = 1, MAX_NEWTON
        ! the dry load at the heights of the loads wl, and its derivative with respect to them
        z = zf - MAX(wl, CD_ZERO)*sfac2/node_kn
        fd = CD_ZERO
        dg = CD_ONE
        lo = CD_ZERO
        up = CD_ZERO
        any_dry = .FALSE.
        DO e = 1, ne
          IF (.NOT. (de(e) > CD_ZERO)) CYCLE
          stretch = CD_ONE + fr%laid_tension/EA(e)
          qz = [z(e), stretch*dzds(e), z(e + 1), stretch*dzds(e + 1)]
          CALL CD_HermiteCable_Dry_Buoyancy(qz, l0(e), fr%laid_water_weight*0.25_wp*PI_W*de(e)**2, &
                                            fr%laid_waterline_z, fdry, kdry, dry, radius=0.5_wp*de(e))
          IF (.NOT. dry) CYCLE
          any_dry = .TRUE.
          fd(e) = fd(e) + fdry(1)
          fd(e + 1) = fd(e + 1) + fdry(3)
          ! d(fd)/d(wl) = -kdry dz/dwl, dz/dwl = -sfac2/kn where the load presses the node in
          IF (wl(e) > CD_ZERO) THEN
            dg(e) = dg(e) + kdry(1, 1)*sfac2(e)/node_kn(e)
            lo(e + 1) = lo(e + 1) + kdry(3, 1)*sfac2(e)/node_kn(e)
          END IF
          IF (wl(e + 1) > CD_ZERO) THEN
            dg(e + 1) = dg(e + 1) + kdry(3, 3)*sfac2(e + 1)/node_kn(e + 1)
            up(e) = up(e) + kdry(1, 3)*sfac2(e + 1)/node_kn(e + 1)
          END IF
        END DO
        IF (PRESENT(node_dry_load)) THEN
          WHERE (z > fr%laid_waterline_z) fd = fd + node_dry_load
          any_dry = any_dry .OR. ANY(z > fr%laid_waterline_z .AND. ABS(node_dry_load) > CD_ZERO)
        END IF
        IF (it == 1 .AND. .NOT. any_dry) RETURN
        gres = wl - base - fd
        IF (MAXVAL(ABS(gres)) <= LOAD_RTOL*scale_w) EXIT
        ! a step that does not reduce the residual is halved from the last accepted loads (the
        ! Newton step is a descent direction of its 2-norm); the shortest is taken as it is
        gnorm = SQRT(SUM(gres*gres))
        IF (.NOT. (gnorm <= (CD_ONE - ARMIJO*lam)*gnorm_acc) .AND. lam > MIN_STEP) THEN
          lam = 0.5_wp*lam
          wl = wl_acc + lam*y
          CYCLE
        END IF
        wl_acc = wl
        gnorm_acc = gnorm
        lam = CD_ONE
        ! (I + K D) dw = -gres, tridiagonal (diagonal dg, sub lo, super up): Thomas elimination;
        ! the diagonal is at least 1 and grows with the dry stiffness
        y = -gres
        DO j = 2, ne + 1
          piv = lo(j)/dg(j - 1)
          dg(j) = dg(j) - piv*up(j - 1)
          y(j) = y(j) - piv*y(j - 1)
        END DO
        y(ne + 1) = y(ne + 1)/dg(ne + 1)
        DO j = ne, 1, -1
          y(j) = (y(j) - up(j)*y(j + 1))/dg(j)
        END DO
        wl = wl + y
        IF (.NOT. CD_All_Finite(wl)) THEN
          esd = CD_HCSTAT_BADINPUT; emd = 'the dry-part load is not finite'; RETURN
        END IF
      END DO
      IF (MAXVAL(ABS(gres)) > LOAD_RTOL*scale_w) THEN
        esd = CD_HCSTAT_BADINPUT; emd = 'the dry-part load of the laid line did not converge'; RETURN
      END IF
      nl = wl
    END SUBROUTINE laid_dry_loads
  END SUBROUTINE CD_HermiteCable_As_Laid_Offsets

  SUBROUTINE CD_HermiteCable_Friction_Reference(fr, l0, origin, ref, ErrStat, ErrMsg, EA, w, node_kn, bathymetry)
    !! Reference position (x, y) of every node of mesh l0: origin (the position of node 1,
    !! the held first end, in the caller's frame) plus the friction reference offset
    !! profile interpolated linearly in unstretched arc length (constant past its ends).
    !! An as-laid reference whose lay is given (fr%laid_on_mesh) is instead rebuilt on mesh
    !! l0 itself (CD_HermiteCable_As_Laid_Offsets) when the mesh's axial stiffnesses EA,
    !! submerged weights per length w (lumped to the nodes) and nodal seabed stiffnesses
    !! node_kn are given, and the bathymetry it was laid on (fr%laid_bathymetry).
    TYPE(CD_HermiteStaticFrictionType), INTENT(IN) :: fr
    REAL(wp), INTENT(IN) :: l0(:), origin(2)
    REAL(wp), INTENT(OUT) :: ref(:, :)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    REAL(wp), INTENT(IN), OPTIONAL :: EA(:), w(:), node_kn(:)
    TYPE(CD_BathymetryType), INTENT(IN), OPTIONAL :: bathymetry
    REAL(wp), ALLOCATABLE :: node_load(:)
    INTEGER :: node, k, np
    REAL(wp) :: s, t
    LOGICAL :: on_mesh
    ErrStat = CD_HCSTAT_OK
    ErrMsg = ''
    ref = CD_ZERO
    on_mesh = fr%as_laid .AND. fr%laid_on_mesh .AND. PRESENT(EA) .AND. PRESENT(w) .AND. PRESENT(node_kn)
    IF (on_mesh .AND. fr%laid_bathymetry) on_mesh = PRESENT(bathymetry)
    IF (on_mesh) THEN
      IF (SIZE(w) /= SIZE(l0) .OR. SIZE(ref, 1) /= 2 .OR. SIZE(ref, 2) /= SIZE(l0) + 1 .OR. &
          .NOT. CD_Is_Finite(fr%mu) .OR. .NOT. CD_All_Finite(w)) THEN
        ErrStat = CD_HCSTAT_BADINPUT; ErrMsg = 'friction: as-laid reference inputs inconsistent or non-finite'; RETURN
      END IF
      ! the element weights lumped to the nodes
      ALLOCATE (node_load(SIZE(l0) + 1))
      node_load = CD_ZERO
      DO k = 1, SIZE(l0)
        node_load(k:k + 1) = node_load(k:k + 1) + 0.5_wp*w(k)*l0(k)
      END DO
      IF (fr%laid_bathymetry) THEN
        CALL CD_HermiteCable_As_Laid_Offsets(fr, l0, EA, node_load, node_kn, ref, ErrStat, ErrMsg, bathymetry)
      ELSE
        CALL CD_HermiteCable_As_Laid_Offsets(fr, l0, EA, node_load, node_kn, ref, ErrStat, ErrMsg)
      END IF
      IF (ErrStat /= CD_HCSTAT_OK) THEN
        ErrMsg = 'friction: '//TRIM(ErrMsg); RETURN
      END IF
      DO node = 1, SIZE(l0) + 1
        ref(:, node) = origin + ref(:, node)
      END DO
      RETURN
    END IF
    IF (.NOT. (ALLOCATED(fr%ref_s) .AND. ALLOCATED(fr%ref_xy))) THEN
      ErrStat = CD_HCSTAT_BADINPUT; ErrMsg = 'friction: reference profile required'; RETURN
    END IF
    np = SIZE(fr%ref_s)
    IF (np < 2 .OR. SIZE(fr%ref_xy, 1) /= 2 .OR. SIZE(fr%ref_xy, 2) /= np .OR. &
        .NOT. CD_Is_Finite(fr%mu) .OR. .NOT. CD_All_Finite(fr%ref_s) .OR. &
        .NOT. CD_All_Finite(fr%ref_xy)) THEN
      ErrStat = CD_HCSTAT_BADINPUT; ErrMsg = 'friction: finite mu and a (2, n >= 2) reference required'; RETURN
    END IF
    IF (ANY(fr%ref_s(2:np) <= fr%ref_s(1:np - 1))) THEN
      ErrStat = CD_HCSTAT_BADINPUT; ErrMsg = 'friction: reference arc lengths must increase'; RETURN
    END IF
    s = CD_ZERO
    k = 1
    DO node = 1, SIZE(l0) + 1
      DO WHILE (k < np - 1)
        IF (fr%ref_s(k + 1) >= s) EXIT
        k = k + 1
      END DO
      t = (s - fr%ref_s(k))/(fr%ref_s(k + 1) - fr%ref_s(k))
      t = MIN(CD_ONE, MAX(CD_ZERO, t))
      ref(:, node) = origin + (CD_ONE - t)*fr%ref_xy(:, k) + t*fr%ref_xy(:, k + 1)
      IF (node <= SIZE(l0)) s = s + l0(node)
    END DO
  END SUBROUTINE CD_HermiteCable_Friction_Reference

  SUBROUTINE CD_HermiteCable_Friction_Anchors(l0, q, fr, contact_kn, seabed_z, anchors, force, &
                                              ErrStat, ErrMsg, bathymetry, contact_frame_cs, EA, w)
    !! Elastic-plastic friction anchors that continue a static equilibrium solved with
    !! seabed friction fr into the dynamics: the static spring force f_s of every node
    !! (CD_Seabed_Friction_Spring at its normal force in state q) and the anchor
    !! x - f_s/k at which a linear spring of the same stiffness k (contact_kn) gives f_s.
    !! force(1:2, node) returns f_s (the force the seabed exerts is -f_s).
    !! EA, w (optional, per element): the axial stiffnesses and submerged weights per length
    !! of the static solve, with which an as-laid reference is laid on mesh l0 as it was
    !! there (CD_HermiteCable_Friction_Reference).
    REAL(wp), INTENT(IN) :: l0(:), q(:), contact_kn(:), seabed_z
    TYPE(CD_HermiteStaticFrictionType), INTENT(IN) :: fr
    REAL(wp), INTENT(OUT) :: anchors(:, :), force(:, :)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    TYPE(CD_BathymetryType), INTENT(IN), OPTIONAL :: bathymetry
    REAL(wp), INTENT(IN), OPTIONAL :: contact_frame_cs(2), EA(:), w(:)
    REAL(wp), ALLOCATABLE :: ref(:, :)
    REAL(wp) :: z_floor, gxg, gyg, xg, yg, normal, normal_gap, dfd(2, 2), dfc(2), cs(2)
    INTEGER :: node, ix, nn, es
    CHARACTER(200) :: em
    ErrStat = CD_HCSTAT_OK
    ErrMsg = ''
    nn = SIZE(l0) + 1
    anchors = CD_ZERO
    force = CD_ZERO
    IF (SIZE(q) /= 6*nn .OR. SIZE(contact_kn) /= nn .OR. SIZE(anchors, 1) /= 2 .OR. &
        SIZE(anchors, 2) /= nn .OR. SIZE(force, 1) /= 2 .OR. SIZE(force, 2) /= nn) THEN
      ErrStat = CD_HCSTAT_BADINPUT
      ErrMsg = 'CD_HermiteCable_Friction_Anchors: inconsistent array sizes'; RETURN
    END IF
    IF (.NOT. CD_All_Finite(contact_kn) .OR. ANY(contact_kn <= CD_ZERO)) THEN
      ErrStat = CD_HCSTAT_BADINPUT
      ErrMsg = 'CD_HermiteCable_Friction_Anchors: contact_kn must be finite and positive'; RETURN
    END IF
    IF (PRESENT(contact_frame_cs)) THEN
      IF (.NOT. CD_All_Finite(contact_frame_cs) .OR. &
          ABS(SUM(contact_frame_cs*contact_frame_cs) - CD_ONE) > 1.0e-9_wp) THEN
        ErrStat = CD_HCSTAT_BADINPUT
        ErrMsg = 'CD_HermiteCable_Friction_Anchors: contact_frame_cs must be a finite unit heading'; RETURN
      END IF
    END IF
    ALLOCATE (ref(2, nn))
    CALL CD_HermiteCable_Friction_Reference(fr, l0, q(1:2), ref, ErrStat, ErrMsg, EA=EA, w=w, node_kn=contact_kn, &
                                            bathymetry=bathymetry)
    IF (ErrStat /= CD_HCSTAT_OK) THEN
      ErrMsg = 'CD_HermiteCable_Friction_Anchors: '//TRIM(ErrMsg); RETURN
    END IF
    cs = [CD_ONE, CD_ZERO]
    IF (PRESENT(contact_frame_cs)) cs = contact_frame_cs
    DO node = 1, nn
      ix = 6*(node - 1) + 1
      z_floor = seabed_z
      IF (PRESENT(bathymetry)) THEN
        xg = cs(1)*q(ix) - cs(2)*q(ix + 1)
        yg = cs(2)*q(ix) + cs(1)*q(ix + 1)
        CALL CD_Bathymetry_Floor_Gradient(bathymetry, xg, yg, z_floor, gxg, gyg, es, em)
        IF (es /= CD_BATHY_OK) THEN
          ErrStat = CD_HCSTAT_NOCONVERGE
          ErrMsg = 'CD_HermiteCable_Friction_Anchors: bathymetry query failed: '//TRIM(em); RETURN
        END IF
      END IF
      IF (PRESENT(bathymetry)) THEN
        CALL CD_Seabed_Normal_Law((z_floor - q(ix + 2))/SQRT(CD_ONE + gxg*gxg + gyg*gyg), contact_kn(node), &
                                  normal, normal_gap)
      ELSE
        CALL CD_Seabed_Normal_Law(z_floor - q(ix + 2), contact_kn(node), normal, normal_gap)
      END IF
      IF (fr%mu_axial > CD_ZERO .AND. ABS(fr%mu_axial - fr%mu) > CD_ZERO) THEN
        CALL CD_Seabed_Friction_Aniso(CD_FRICTION_SPRING, q(ix:ix + 1) - ref(:, node), contact_kn(node), normal, &
                                      fr%mu_axial, fr%mu, q(ix + 3:ix + 4), force(:, node), dfd, dfc)
      ELSE
        CALL CD_Seabed_Friction_Spring(q(ix:ix + 1) - ref(:, node), contact_kn(node), fr%mu*normal, &
                                       force(:, node), dfd, dfc)
      END IF
      anchors(:, node) = q(ix:ix + 1) - force(:, node)/contact_kn(node)
    END DO
  END SUBROUTINE CD_HermiteCable_Friction_Anchors

  SUBROUTINE current_element_props(current, l0, d, cn, ct, ErrStat, ErrMsg)
    !! Validate a steady current and map its section properties (given per reference-arc
    !! interval) onto the elements of mesh l0 by element midpoint.
    TYPE(CD_HermiteStaticCurrentType), INTENT(IN) :: current
    REAL(wp), INTENT(IN) :: l0(:)
    REAL(wp), INTENT(OUT) :: d(:), cn(:), ct(:)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    INTEGER :: e, k, nsec
    REAL(wp) :: arc, smid
    ErrStat = CD_HCSTAT_OK
    ErrMsg = ''
    ! a carrier without drag (drag = .FALSE.: the static seabed friction alone) loads no
    ! element, whatever its velocity, and needs no drag properties
    IF (.NOT. current%drag) THEN
      d = CD_ZERO
      cn = CD_ZERO
      ct = CD_ZERO
      RETURN
    END IF
    IF (.NOT. (current%rho > CD_ZERO) .OR. .NOT. CD_Is_Finite(current%rho) .OR. &
        .NOT. (current%load_factor >= CD_ZERO) .OR. .NOT. CD_Is_Finite(current%load_factor) .OR. &
        .NOT. CD_All_Finite(current%velocity) .OR. .NOT. CD_Is_Finite(current%waterline_z) .OR. &
        .NOT. CD_All_Finite(current%frame_cs)) THEN
      ErrStat = CD_HCSTAT_BADINPUT
      ErrMsg = 'current: rho > 0, load_factor >= 0 and finite velocity/waterline/frame required'; RETURN
    END IF
    IF (.NOT. (ALLOCATED(current%arc_end) .AND. ALLOCATED(current%diam) .AND. ALLOCATED(current%cdn) .AND. &
               ALLOCATED(current%cdt))) THEN
      ErrStat = CD_HCSTAT_BADINPUT; ErrMsg = 'current: section arc_end/diam/cdn/cdt required'; RETURN
    END IF
    nsec = SIZE(current%arc_end)
    IF (nsec < 1 .OR. SIZE(current%diam) /= nsec .OR. SIZE(current%cdn) /= nsec .OR. &
        SIZE(current%cdt) /= nsec) THEN
      ErrStat = CD_HCSTAT_BADINPUT; ErrMsg = 'current: section arrays must share one length'; RETURN
    END IF
    IF (ALLOCATED(current%profile_z) .NEQV. ALLOCATED(current%profile_velocity)) THEN
      ErrStat = CD_HCSTAT_BADINPUT; ErrMsg = 'current: profile_z and profile_velocity go together'; RETURN
    END IF
    arc = CD_ZERO
    k = 1
    DO e = 1, SIZE(l0)
      smid = arc + 0.5_wp*l0(e)
      DO WHILE (k < nsec)
        IF (current%arc_end(k) >= smid) EXIT
        k = k + 1
      END DO
      d(e) = current%diam(k)
      cn(e) = current%cdn(k)
      ct(e) = current%cdt(k)
      arc = arc + l0(e)
    END DO
  END SUBROUTINE current_element_props

  SUBROUTINE current_element_load(current, qe, l0e, d, cn, ct, want_jac, fd, djq, ErrStat, ErrMsg)
    !! Steady-current drag on one element at rest: the load fd(12) (f_ext) and, when
    !! want_jac, its position Jacobian, both scaled by current%load_factor. The element
    !! fluid velocity is the mean of the current at its two nodes, rotated into the solve
    !! frame. A depth profile is sampled at the nodes' elevations and a current grid at their
    !! positions, so the current moves with them: the Jacobian carries that dependence too
    !! (below).
    TYPE(CD_HermiteStaticCurrentType), INTENT(IN) :: current
    REAL(wp), INTENT(IN) :: qe(12), l0e, d, cn, ct
    LOGICAL, INTENT(IN) :: want_jac
    REAL(wp), INTENT(OUT) :: fd(12), djq(12, 12)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    REAL(wp) :: ve(12), djv(12, 12), ua(3), ub(3), ug(3), ul(3), ga(3, 3), gb(3, 3), dfdu(12, 3), rot(3, 3)
    INTEGER :: es
    CHARACTER(200) :: em
    ErrStat = CD_HCSTAT_OK
    ErrMsg = ''
    fd = CD_ZERO
    djq = CD_ZERO
    ve = CD_ZERO
    ! no drag on a friction-only carrier (current_element_props)
    IF (.NOT. current%drag) RETURN
    IF (ALLOCATED(current%grid)) THEN
      CALL CD_Current_Grid_Velocity(current%grid, global_position(qe(1:3)), 0.0_wp, ua, es, em)
      IF (es == CD_HYDRO_OK) CALL CD_Current_Grid_Velocity(current%grid, global_position(qe(7:9)), 0.0_wp, ub, &
                                                           es, em)
      IF (es /= CD_HYDRO_OK) THEN
        ErrStat = CD_HCSTAT_NOCONVERGE; ErrMsg = TRIM(em); RETURN
      END IF
      ug = 0.5_wp*(ua + ub)
    ELSE IF (ALLOCATED(current%profile_z)) THEN
      CALL CD_Current_Profile_Velocity(qe(3), current%profile_z, current%profile_velocity, ua, es, em)
      IF (es == CD_HYDRO_OK) CALL CD_Current_Profile_Velocity(qe(9), current%profile_z, current%profile_velocity, &
                                                              ub, es, em)
      IF (es /= CD_HYDRO_OK) THEN
        ErrStat = CD_HCSTAT_NOCONVERGE; ErrMsg = TRIM(em); RETURN
      END IF
      ug = 0.5_wp*(ua + ub)
    ELSE
      ug = current%velocity
    END IF
    ul = [current%frame_cs(1)*ug(1) + current%frame_cs(2)*ug(2), &
          -current%frame_cs(2)*ug(1) + current%frame_cs(1)*ug(2), ug(3)]
    IF (want_jac) THEN
      CALL CD_HermiteCable_Drag_Element(qe, ve, l0e, ul, current%waterline_z, current%rho, d, cn, ct, fd, &
                                        djq, djv, es, em)
    ELSE
      CALL CD_HermiteCable_Drag_Element(qe, ve, l0e, ul, current%waterline_z, current%rho, d, cn, ct, fd, &
                                        ErrStat=es, ErrMsg=em)
    END IF
    IF (es /= CD_HCDYN_OK) THEN
      ErrStat = CD_HCSTAT_NOCONVERGE; ErrMsg = TRIM(em); RETURN
    END IF
    IF (want_jac .AND. (ALLOCATED(current%grid) .OR. ALLOCATED(current%profile_z))) THEN
      ! The current at the nodes moves with them. The element fluid velocity is
      ! u = R^T (U(x_a) + U(x_b))/2, with R the turn of frame_cs (global = R solve frame, z
      ! alone) and x = R (x_l + origin) the global node position (a profile reads only z), so
      ! du/dx_l,a = R^T G_a R / 2 with G = dU/dx the field's gradient at the node. The drag sees
      ! u - v(s), and a uniform velocity c of the element is the nodal velocity [c, 0, c, 0]
      ! (its tangent rates zero: the Hermite shape functions of the two positions sum to one),
      ! so d fd/du = -(djv(:, 1:3) + djv(:, 7:9)) and d fd/dx_l,a = d fd/du du/dx_l,a. Without
      ! it a sheared current entered the Newton tangent as if it were uniform.
      IF (ALLOCATED(current%grid)) THEN
        CALL CD_Current_Grid_Gradient(current%grid, global_position(qe(1:3)), 0.0_wp, ga, es, em)
        IF (es == CD_HYDRO_OK) CALL CD_Current_Grid_Gradient(current%grid, global_position(qe(7:9)), 0.0_wp, gb, &
                                                             es, em)
        IF (es /= CD_HYDRO_OK) THEN
          ErrStat = CD_HCSTAT_NOCONVERGE; ErrMsg = TRIM(em); RETURN
        END IF
      ELSE
        CALL CD_Current_Profile_Gradient(qe(3), current%profile_z, current%profile_velocity, ga)
        CALL CD_Current_Profile_Gradient(qe(9), current%profile_z, current%profile_velocity, gb)
      END IF
      rot = RESHAPE([current%frame_cs(1), current%frame_cs(2), CD_ZERO, -current%frame_cs(2), current%frame_cs(1), &
                     CD_ZERO, CD_ZERO, CD_ZERO, CD_ONE], [3, 3])
      dfdu = -(djv(:, 1:3) + djv(:, 7:9))
      djq(:, 1:3) = djq(:, 1:3) + 0.5_wp*MATMUL(dfdu, MATMUL(TRANSPOSE(rot), MATMUL(ga, rot)))
      djq(:, 7:9) = djq(:, 7:9) + 0.5_wp*MATMUL(dfdu, MATMUL(TRANSPOSE(rot), MATMUL(gb, rot)))
    END IF
    fd = current%load_factor*fd
    IF (want_jac) djq = current%load_factor*djq

  CONTAINS

    PURE FUNCTION global_position(xl) RESULT(xg)
      !! The global position of a solve-frame node position xl (shifted by the frame's origin,
      !! then turned back by frame_cs).
      REAL(wp), INTENT(IN) :: xl(3)
      REAL(wp) :: xg(3), xs(2)
      xs = xl(1:2) + current%origin
      xg = [current%frame_cs(1)*xs(1) - current%frame_cs(2)*xs(2), &
            current%frame_cs(2)*xs(1) + current%frame_cs(1)*xs(2), xl(3)]
    END FUNCTION global_position
  END SUBROUTINE current_element_load

  SUBROUTINE CD_HermiteCable_Current_Load(l0, q, current, load, ErrStat, ErrMsg)
    !! Generalized load vector (6*(ne+1), f_ext) of a steady current on a finite-EI line at
    !! rest in configuration q: the drag the static solve applies with its current argument.
    REAL(wp), INTENT(IN) :: l0(:), q(:)
    TYPE(CD_HermiteStaticCurrentType), INTENT(IN) :: current
    REAL(wp), INTENT(OUT) :: load(:)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    REAL(wp) :: d(SIZE(l0)), cn(SIZE(l0)), ct(SIZE(l0)), fd(12), djq(12, 12)
    INTEGER :: ne, e
    ne = SIZE(l0)
    load = CD_ZERO
    IF (SIZE(q) /= 6*(ne + 1) .OR. SIZE(load) /= 6*(ne + 1)) THEN
      ErrStat = CD_HCSTAT_BADINPUT
      ErrMsg = 'CD_HermiteCable_Current_Load: q and load must be 6*(ne+1)'; RETURN
    END IF
    CALL current_element_props(current, l0, d, cn, ct, ErrStat, ErrMsg)
    IF (ErrStat /= CD_HCSTAT_OK) RETURN
    DO e = 1, ne
      CALL current_element_load(current, q(6*(e - 1) + 1:6*e + 6), l0(e), d(e), cn(e), ct(e), .FALSE., &
                                fd, djq, ErrStat, ErrMsg)
      IF (ErrStat /= CD_HCSTAT_OK) RETURN
      load(6*(e - 1) + 1:6*e + 6) = load(6*(e - 1) + 1:6*e + 6) + fd
    END DO
  END SUBROUTINE CD_HermiteCable_Current_Load

  SUBROUTINE CD_HermiteCable_Mean_Axial_Extremes(l0, EA, q, t_min, t_max, e_min, s_min, ErrStat, ErrMsg)
    !! Smallest and largest element-mean axial force (three-point Gauss mean of the axial
    !! resultant EA (|r'| - 1)) of state q, with the element holding the smallest and the
    !! unstretched arc length of its midpoint.
    REAL(wp), INTENT(IN) :: l0(:), EA(:), q(:)
    REAL(wp), INTENT(OUT) :: t_min, t_max, s_min
    INTEGER, INTENT(OUT) :: e_min, ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    REAL(wp), PARAMETER :: GX(3) = [0.5_wp - 0.5_wp*SQRT(0.6_wp), 0.5_wp, 0.5_wp + 0.5_wp*SQRT(0.6_wp)]
    REAL(wp), PARAMETER :: GW(3) = [5.0_wp/18.0_wp, 8.0_wp/18.0_wp, 5.0_wp/18.0_wp]
    REAL(wp) :: t_e, s_e, ng
    INTEGER :: e, k
    ErrStat = CD_HCSTAT_OK
    ErrMsg = ''
    t_min = HUGE(CD_ONE)
    t_max = -HUGE(CD_ONE)
    e_min = 1
    s_min = CD_ZERO
    s_e = CD_ZERO
    IF (SIZE(EA) /= SIZE(l0) .OR. SIZE(q) /= 6*(SIZE(l0) + 1)) THEN
      ErrStat = CD_HCSTAT_BADINPUT
      ErrMsg = 'CD_HermiteCable_Mean_Axial_Extremes: inconsistent array sizes'; RETURN
    END IF
    DO e = 1, SIZE(l0)
      t_e = CD_ZERO
      DO k = 1, 3
        CALL CD_HermiteCable_Axial_Resultant(q(6*(e - 1) + 1:6*(e + 1)), l0(e), EA(e), GX(k), ng, ErrStat, ErrMsg)
        IF (ErrStat /= CD_HCABLE_OK) THEN
          ErrStat = CD_HCSTAT_NOCONVERGE; RETURN
        END IF
        t_e = t_e + GW(k)*ng
      END DO
      t_max = MAX(t_max, t_e)
      IF (t_e < t_min) THEN
        t_min = t_e; e_min = e; s_min = s_e + 0.5_wp*l0(e)
      END IF
      s_e = s_e + l0(e)
    END DO
  END SUBROUTINE CD_HermiteCable_Mean_Axial_Extremes

  PURE LOGICAL FUNCTION current_has_drag(cur) RESULT(has)
    !! Whether a static current object carries a flow (a zero-velocity one only carries the
    !! static seabed friction of a line in still water): the current diagnoses apply then only.
    TYPE(CD_HermiteStaticCurrentType), INTENT(IN) :: cur
    has = cur%drag
  END FUNCTION current_has_drag

  FUNCTION current_compression_note(l0, EA, qx, seabed_z, flat, frictional, frictionless_run, EI, w) RESULT(note)
    !! Diagnosis of a current that has no tension-only equilibrium on the traced branch:
    !! empty unless the state qx (the last one reached) carries an element-mean axial force
    !! (three-point Gauss mean of EA (|r'| - 1), free of the end-node boundary layer) below
    !! -1e-3 of the largest one. A compressed element on or near the seabed plane (flat:
    !! within 1 % of the line's height above it) means the drag drives the grounded run
    !! along the frictionless seabed toward its end harder than the suspended span pulls
    !! it back: the run can only buckle or slide past its end. With seabed friction
    !! (frictional) the grounded run is held, and compression there means the current
    !! pushes the suspended span into the touchdown harder than it can carry.
    REAL(wp), INTENT(IN) :: l0(:), EA(:), qx(:), seabed_z
    LOGICAL, INTENT(IN) :: flat, frictional
    ! TRUE for the two frictionless grounded-run diagnoses (the run folds against its end or
    ! is pushed along the seabed in compression).
    LOGICAL, INTENT(OUT), OPTIONAL :: frictionless_run
    ! The bending stiffness and weight per length of the elements (both or neither): on an
    ! element longer than half its bending length (EI/|w|)^(1/3) the element-mean axial force of
    ! a stiff line oscillates and can read a compression the line does not carry, so a
    ! compression there names the mesh, not a limit of the current.
    REAL(wp), INTENT(IN), OPTIONAL :: EI(:), w(:)
    CHARACTER(1024) :: note
    REAL(wp) :: t_min, t_max, s_min, z_min, z_top, need
    INTEGER :: k, k_min, wios, ne, es
    CHARACTER(1024) :: em
    note = ''
    IF (PRESENT(frictionless_run)) frictionless_run = .FALSE.
    ne = SIZE(l0)
    CALL CD_HermiteCable_Mean_Axial_Extremes(l0, EA, qx, t_min, t_max, k_min, s_min, es, em)
    IF (es /= CD_HCSTAT_OK) RETURN
    z_top = seabed_z
    DO k = 1, ne + 1
      z_top = MAX(z_top, qx(6*k - 3))
    END DO
    IF (.NOT. (t_min < -1.0e-3_wp*t_max)) RETURN
    ! Height of the compressed element: the lower of its two nodes.
    z_min = MIN(qx(6*(k_min - 1) + 3), qx(6*k_min + 3))
    IF (PRESENT(EI) .AND. PRESENT(w)) THEN
      ! the compressed element and its neighbours against half their bending length
      need = CD_ZERO
      DO k = MAX(1, k_min - 1), MIN(ne, k_min + 1)
        IF (EI(k) > CD_ZERO .AND. ABS(w(k)) > CD_ZERO) &
          need = MAX(need, l0(k)/(0.5_wp*(EI(k)/ABS(w(k)))**(1.0_wp/3.0_wp)))
      END DO
      IF (need > 1.0_wp) THEN
        WRITE (note, '(A,ES10.3,A,F10.2,A,F6.2,A)', IOSTAT=wios) 'the line reads an element-mean axial '// &
          'compression (', t_min, ' N at unstretched arc length ', s_min, ' m) on elements ', need, &
          ' times half the bending length (EI/|w|)^(1/3), where the element-mean axial force of a stiff '// &
          'line oscillates and can read a compression the line does not carry; refine those elements '// &
          '(NumSegs) to half the bending length or less; '
        RETURN
      END IF
    END IF
    IF (flat .AND. z_min <= seabed_z + 0.01_wp*(z_top - seabed_z) .AND. frictional) THEN
      WRITE (note, '(A,ES10.3,A,F10.2,A,ES10.3,A)', IOSTAT=wios) 'the line is in axial compression at '// &
        'the seabed (', t_min, ' N at unstretched arc length ', s_min, ' m, ', z_min - seabed_z, &
        ' m above the seabed): the friction holds the grounded run and the current pushes the '// &
        'suspended span into the touchdown, so no tension-only equilibrium continues from the '// &
        'still-water layout; '
    ELSE IF (flat .AND. z_min <= seabed_z + 0.01_wp*(z_top - seabed_z) .AND. -t_min > t_max) THEN
      ! A compression beyond the peak tension is no loaded equilibrium but a run folded
      ! against its end (the state the refinement then rejects).
      IF (PRESENT(frictionless_run)) frictionless_run = .TRUE.
      WRITE (note, '(A,ES10.3,A,F10.2,A,ES10.3,A)', IOSTAT=wios) 'the run on the seabed folds against '// &
        'its end (element-mean axial force ', t_min, ' N at unstretched arc length ', s_min, &
        ' m, beyond the peak tension ', t_max, ' N): the current pushes it along the frictionless seabed '// &
        'into its end, so no tension-only equilibrium continues from the still-water layout (declare '// &
        'OPTIONS frictionMu where the seabed holds the run); '
    ELSE IF (flat .AND. z_min <= seabed_z + 0.01_wp*(z_top - seabed_z)) THEN
      IF (PRESENT(frictionless_run)) frictionless_run = .TRUE.
      WRITE (note, '(A,ES10.3,A,F10.2,A,ES10.3,A)', IOSTAT=wios) 'the run on the seabed is in axial '// &
        'compression (', t_min, ' N at unstretched arc length ', s_min, ' m, ', z_min - seabed_z, &
        ' m above the seabed): the current pushes it along the frictionless seabed toward its end '// &
        'harder than the suspended span pulls it back, so no tension-only equilibrium continues from '// &
        'the still-water layout (declare OPTIONS frictionMu where the seabed holds the run); '
    ELSE
      WRITE (note, '(A,ES10.3,A,F10.2,A,ES10.3,A)', IOSTAT=wios) 'the line is in axial compression (', &
        t_min, ' N at unstretched arc length ', s_min, ' m, ', z_min - seabed_z, ' m above the seabed), '// &
        'which the current cannot hold in a tension-only equilibrium; '
    END IF
  END FUNCTION current_compression_note

  SUBROUTINE CD_HermiteCable_Static_Solve_Continuation(l0, EA, EI, w, seed, fixed_dofs, seabed_z, kn, &
                                                       max_iter, tol, ei_start, iteration_budget, &
                                                       q_out, curv_out, res_out, iters_out, ErrStat, ErrMsg, &
                                                       contact_kn, bathymetry, contact_frame_cs, &
                                                       axial_quadrature_order, bending_quadrature_order, &
                                                       endconn_stiffness, endconn_direction, endconn_mode, &
                                                       waterline_z, dry_buoyancy, water_weight, current)
    !! Bending-stiffness continuation from an EI = 0 equilibrium seed.
    !!
    !! The seed is expected to be the exact extensible catenary of the same line (all
    !! loads at full value: submerged weight including buoyancy sections, seabed support
    !! and end positions), which is the EI -> 0 limit of the finite-EI equilibrium. The
    !! equilibrium is traced along the one-parameter family EI(lambda) = lambda*EI,
    !! lambda = ei_start -> 1, with end-connection stiffness scaled alike. For a
    !! tensioned line this family is smooth, so every stage starts inside the Newton
    !! basin of the branch that is continuously connected to the catenary; loads are not
    !! ramped, which avoids the non-unique intermediate states of a buoyancy ramp.
    !!
    !! Steps are geometric in lambda. Each stage is an energy trust-region solve (the
    !! pseudo-transient Newton retry after it) with an allowance of PTC_ITER_FACTOR*max_iter
    !! iterations; a stage that does not converge is retried from the last accepted state
    !! with half the logarithmic step. When the step falls below 1/64 decade a single
    !! full-stiffness descent from the last converged state is tried (a limit point where
    !! the equilibrium snaps to another stable configuration); the continuation then stops
    !! with NOCONVERGE, as it does once iteration_budget Newton iterations are spent.
    !! A full-stiffness descent (that one, or the restart from the seed of a first stage
    !! that does not converge) has RESTART_ITER_FACTOR stage allowances; its energy pass runs
    !! on to one and a half of them, within the budget, while its residual keeps falling, and
    !! stops after that allowance without the norm of the residual halving (stall_limit of
    !! CD_HermiteCable_Static_Solve).
    !! Intermediate stages use a looser tolerance (MAX(tol, 1e-6)); the final stage uses tol.
    !! The budget makes the failure path bounded: a caller's fallback route receives control
    !! after at most that many Newton iterations.
    !!
    !! Arguments mirror CD_HermiteCable_Static_Solve. ei_start in (0, 1] is the first
    !! stiffness fraction (1 solves the full problem directly from the seed).
    REAL(wp), INTENT(IN) :: l0(:), EA(:), EI(:), w(:), seed(:)
    INTEGER, INTENT(IN) :: fixed_dofs(:)
    REAL(wp), INTENT(IN) :: seabed_z, kn, tol, ei_start
    INTEGER, INTENT(IN) :: max_iter, iteration_budget
    REAL(wp), INTENT(OUT) :: q_out(:), curv_out(:), res_out
    INTEGER, INTENT(OUT) :: iters_out
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    REAL(wp), INTENT(IN), OPTIONAL :: contact_kn(:), contact_frame_cs(2)
    TYPE(CD_BathymetryType), INTENT(IN), OPTIONAL :: bathymetry
    INTEGER, INTENT(IN), OPTIONAL :: axial_quadrature_order, bending_quadrature_order
    REAL(wp), INTENT(IN), OPTIONAL :: endconn_stiffness(2), endconn_direction(3, 2)
    INTEGER, INTENT(IN), OPTIONAL :: endconn_mode(2)
    REAL(wp), INTENT(IN), OPTIONAL :: waterline_z, dry_buoyancy(:), water_weight
    TYPE(CD_HermiteStaticCurrentType), INTENT(IN), OPTIONAL :: current

    ! Largest and smallest logarithmic continuation steps [decades of lambda].
    REAL(wp), PARAMETER :: DLOG_MAX = 1.0_wp, DLOG_MIN = 1.0_wp/64.0_wp
    ! Intermediate stages only need to seed the next stage.
    REAL(wp), PARAMETER :: INTERMEDIATE_TOL = 1.0e-6_wp
    ! Current fixed point: pass limit, and the relative change of the frozen drag that ends it.
    INTEGER, PARAMETER :: MAX_PICARD = 25
    REAL(wp), PARAMETER :: PICARD_TOL = 1.0e-6_wp, CURRENT_STEP_MIN = 1.0_wp/64.0_wp
    ! Largest centreline move between accepted stages, as a fraction of the line length.
    REAL(wp), PARAMETER :: STAGE_MOVE_TOL = 0.02_wp
    ! Every stage (energy solve and pseudo-transient retry) gets this multiple of max_iter.
    INTEGER, PARAMETER :: PTC_ITER_FACTOR = 4
    ! A full-stiffness restart from the seed descends from far away: its stage allowance, of
    ! the iterations without progress in the energy pass.
    INTEGER, PARAMETER :: RESTART_ITER_FACTOR = 10
    INTEGER :: ne, nn, it, es, n_accepted
    REAL(wp) :: lambda, lambda_try, dlog, stage_tol, res
    REAL(wp), ALLOCATABLE :: q(:), q_try(:), curv(:), ei_stage(:)
    REAL(wp) :: k_stage(2)
    CHARACTER(1024) :: em
    LOGICAL :: final_stage, restart_stage, snapped
    ! The current is brought in after the still-water EI continuation (unallocated: the
    ! stages run without the configuration-dependent drag).
    TYPE(CD_HermiteStaticCurrentType), ALLOCATABLE :: cur_stage
    REAL(wp), ALLOCATABLE :: f_drag(:), f_prev(:), q_level(:)
    REAL(wp) :: cur_frac
    LOGICAL :: picard_ok, drag_homotopy, planar_run_limit
    INTEGER :: iters_first
    CHARACTER(1024) :: arc_msg
    ! Arclength workspace: residual, banded tangent (and a copy to factor), drag load, free DOFs.
    REAL(wp), ALLOCATABLE :: fres(:), kband(:, :), kwork(:, :), dvec(:)
    LOGICAL, ALLOCATABLE :: free(:)
    REAL(wp) :: wq
    ! A Rigid end in the arclength solve: the end tangent in the basis of its direction (the
    ! static solve's residual and tangent come in it), the two transverse components held.
    REAL(wp) :: arc_basis(3, 3, 2)
    LOGICAL :: arc_rigid(2)
    CHARACTER(1024) :: first_msg
    CHARACTER(16) :: frac_txt
    ! Seabed friction of the current (active in every stage after the still-water one).
    LOGICAL :: use_fric
    TYPE(CD_HermiteStaticFrictionType), ALLOCATABLE :: fric_stage
    REAL(wp), ALLOCATABLE :: cap_work(:)

    ErrStat = CD_HCSTAT_OK
    ErrMsg = ''
    res_out = CD_ZERO
    iters_out = 0
    ne = SIZE(l0)
    nn = ne + 1
    IF (ne < 1 .OR. SIZE(EI) /= ne .OR. SIZE(seed) /= 6*nn .OR. SIZE(q_out) /= 6*nn .OR. &
        SIZE(curv_out) /= nn) THEN
      ErrStat = CD_HCSTAT_BADINPUT
      ErrMsg = 'CD_HermiteCable_Static_Solve_Continuation: inconsistent array sizes'; RETURN
    END IF
    IF (.NOT. CD_Is_Finite(ei_start) .OR. ei_start <= CD_ZERO .OR. ei_start > CD_ONE .OR. &
        iteration_budget < 1) THEN
      ErrStat = CD_HCSTAT_BADINPUT
      ErrMsg = 'CD_HermiteCable_Static_Solve_Continuation: need 0 < ei_start <= 1 and iteration_budget >= 1'
      RETURN
    END IF
    q_out = seed
    curv_out = CD_ZERO
    ALLOCATE (q(6*nn), q_try(6*nn), curv(nn), ei_stage(ne))
    k_stage = CD_ZERO
    IF (PRESENT(current)) ALLOCATE (f_drag(6*nn), f_prev(6*nn), q_level(6*nn))
    ! A current rides along the stiffness homotopy as the drag frozen at the last accepted
    ! configuration (drag_homotopy); if that path fails, the still-water homotopy is traced
    ! and the drag is then brought in by load steps at full stiffness.
    ! Seabed friction holds the line relative to its as-laid position (the reference of its
    ! springs; in still water a zero-velocity current carries it). The springs are
    ! memoryless, so the equilibrium does not depend on the path that reaches it: they ride
    ! along the homotopy with the drag, their capacities frozen at the same configuration
    ! (fric_stage). The frictionless homotopy of the fallback path runs without them.
    use_fric = .FALSE.
    IF (PRESENT(current)) THEN
      IF (ALLOCATED(current%friction)) use_fric = current%friction%mu > CD_ZERO
    END IF
    IF (use_fric) ALLOCATE (fric_stage, SOURCE=current%friction)
    drag_homotopy = PRESENT(current)
    arc_rigid = .FALSE.
    CALL ei_homotopy()
    IF (.NOT. PRESENT(current)) THEN
      IF (ErrStat /= CD_HCSTAT_OK) RETURN
    ELSE
      ! Steady current: a fixed-point iteration at full stiffness solves the conservative
      ! problem with the drag frozen at the previous configuration until the frozen drag
      ! reproduces itself; a final Newton solve with the configuration-dependent drag and
      ! its Jacobian then converges from that state.
      picard_ok = ErrStat == CD_HCSTAT_OK
      IF (picard_ok) THEN
        CALL full_fixed_point(picard_ok)
        IF (.NOT. picard_ok) first_msg = TRIM(fixed_point_name())//' not reached: '// &
                                         TRIM(compression_note(q))//TRIM(em)
      ELSE
        first_msg = ErrMsg
      END IF
      IF (.NOT. picard_ok) THEN
        ! Fallback: the still-water equilibrium first, then the drag by load steps.
        ErrStat = CD_HCSTAT_OK
        ErrMsg = ''
        drag_homotopy = .FALSE.
        ! The fallback path has its own iteration budget; iters_out reports both.
        iters_first = iters_out
        iters_out = 0
        IF (use_fric) DEALLOCATE (fric_stage)
        CALL ei_homotopy()
        iters_out = iters_out + iters_first
        IF (ErrStat /= CD_HCSTAT_OK) THEN
          ErrMsg = TRIM(ErrMsg)//' (with the current along the homotopy: '//TRIM(first_msg)//')'
          RETURN
        END IF
        IF (use_fric) ALLOCATE (fric_stage, SOURCE=current%friction)
        ! The load steps have their own iteration budget as well.
        iters_first = iters_out
        iters_out = 0
        CALL drag_load_steps(picard_ok)
        ! A stalled load step is the signature of a limit point of the equilibrium path in
        ! the drag fraction: follow the path around it by pseudo-arclength continuation.
        ! Not for a line held in its plane whose run on a frictionless seabed is driven into
        ! compression: the planar path does not turn back (the grounded run must leave the
        ! plane or fold), and tracing it only delays the diagnosis.
        planar_run_limit = .FALSE.
        IF (.NOT. picard_ok .AND. COUNT(MOD(fixed_dofs - 1, 6) == 1) >= nn) &
          planar_run_limit = frictionless_run_limit(q)
        IF (.NOT. picard_ok .AND. .NOT. planar_run_limit) THEN
          arc_msg = em
          iters_out = 0
          IF (use_fric) THEN
            IF (ALLOCATED(fric_stage%frozen_capacity)) DEALLOCATE (fric_stage%frozen_capacity)
          END IF
          CALL drag_arclength(picard_ok)
          IF (.NOT. picard_ok) em = TRIM(arc_msg)//'; arclength continuation: '//TRIM(em)
          ! The fixed point below freezes the drag again: the live drag of the arclength
          ! stages must not be added to it.
          IF (ALLOCATED(cur_stage)) DEALLOCATE (cur_stage)
        END IF
        iters_out = iters_out + iters_first
        IF (.NOT. picard_ok) THEN
          ErrStat = CD_HCSTAT_NOCONVERGE
          ! Formatted into a short buffer: the assembled message may exceed ErrMsg and is
          ! truncated by the assignment (an internal WRITE past the record length aborts).
          WRITE (frac_txt, '(F6.3)') cur_frac
          IF (current_has_drag(current)) THEN
            ErrMsg = 'CD_HermiteCable_Static_Solve_Continuation: current load stepping stopped at drag '// &
                     'fraction '//TRIM(ADJUSTL(frac_txt))//': '//TRIM(compression_note(q))//TRIM(em)// &
                     ' (with the current along the homotopy: '//TRIM(first_msg)//')'
          ELSE
            ErrMsg = 'CD_HermiteCable_Static_Solve_Continuation: seabed friction load stepping stopped at '// &
                     'load fraction '//TRIM(ADJUSTL(frac_txt))//': '//TRIM(em)// &
                     ' (with the friction along the homotopy: '//TRIM(first_msg)//')'
          END IF
          q_out = q; RETURN
        END IF
        CALL full_fixed_point(picard_ok)
        IF (.NOT. picard_ok) THEN
          ErrStat = CD_HCSTAT_NOCONVERGE
          ErrMsg = 'CD_HermiteCable_Static_Solve_Continuation: '//TRIM(fixed_point_name())//' not reached: '// &
                   TRIM(compression_note(q))//TRIM(em)
          q_out = q; RETURN
        END IF
      END IF
      ! Full problem: configuration-dependent drag with its Jacobian (Newton, residual merit),
      ! and the seabed friction with its live capacities.
      IF (use_fric) THEN
        IF (ALLOCATED(fric_stage%frozen_capacity)) DEALLOCATE (fric_stage%frozen_capacity)
      END IF
      IF (ALLOCATED(cur_stage)) DEALLOCATE (cur_stage)
      ALLOCATE (cur_stage, SOURCE=current)
      stage_tol = tol
      CALL stage_solve(ei_stage, q, q_try, curv, res, it, es, em, .FALSE.)
      iters_out = iters_out + it
      IF (es == CD_HCSTAT_NOCONVERGE .AND. iters_out < iteration_budget) THEN
        CALL stage_solve(ei_stage, q, q_try, curv, res, it, es, em, .TRUE.)
        iters_out = iters_out + it
      END IF
      IF (es /= CD_HCSTAT_OK) THEN
        ErrStat = CD_HCSTAT_NOCONVERGE
        ErrMsg = 'CD_HermiteCable_Static_Solve_Continuation: current equilibrium did not converge: '//TRIM(em)
        q_out = q; RETURN
      END IF
      q = q_try
    END IF
    q_out = q
    curv_out = curv
    res_out = res

  CONTAINS

    SUBROUTINE ei_homotopy()
      !! Stiffness continuation lambda*EI from the seed to lambda = 1 (sets q; on failure
      !! sets ErrStat/ErrMsg/q_out). With drag_homotopy the current's drag, frozen at the last
      !! accepted configuration, loads every stage.
      q = seed
      lambda = CD_ZERO
      lambda_try = ei_start
      dlog = DLOG_MAX
      n_accepted = 0
      restart_stage = .FALSE.
      snapped = .FALSE.
      DO
        final_stage = lambda_try >= CD_ONE
        IF (final_stage) lambda_try = CD_ONE
        stage_tol = tol
        IF (.NOT. final_stage) stage_tol = MAX(tol, INTERMEDIATE_TOL)
        ei_stage = lambda_try*EI
        IF (PRESENT(endconn_stiffness)) k_stage = lambda_try*endconn_stiffness
        ! A current rides along the stiffness homotopy as the drag frozen at the last accepted
        ! configuration (a conservative load for the energy-minimising stages); the exact
        ! configuration-dependent drag is restored after the final stage.
        IF (drag_homotopy) THEN
          CALL CD_HermiteCable_Current_Load(l0, q, current, f_drag, es, em)
          IF (es /= CD_HCSTAT_OK) THEN
            ErrStat = es; ErrMsg = 'CD_HermiteCable_Static_Solve_Continuation: '//TRIM(em); q_out = q; RETURN
          END IF
          IF (use_fric) THEN
            IF (.NOT. ALLOCATED(fric_stage%frozen_capacity)) ALLOCATE (fric_stage%frozen_capacity(nn))
            CALL friction_capacity(q, fric_stage%frozen_capacity)
          END IF
        END IF
        IF (drag_homotopy) THEN
          CALL stage_solve(ei_stage, q, q_try, curv, res, it, es, em, .FALSE., f_drag)
        ELSE
          CALL stage_solve(ei_stage, q, q_try, curv, res, it, es, em, .FALSE.)
        END IF
        iters_out = iters_out + it
        IF (es == CD_HCSTAT_NOCONVERGE .AND. iters_out < iteration_budget) THEN
          ! A stage outside the Newton basin of its start is relaxed by pseudo-transient
          ! continuation from the same start before the step is reduced.
          IF (drag_homotopy) THEN
            CALL stage_solve(ei_stage, q, q_try, curv, res, it, es, em, .TRUE., f_drag)
          ELSE
            CALL stage_solve(ei_stage, q, q_try, curv, res, it, es, em, .TRUE.)
          END IF
          iters_out = iters_out + it
        END IF
        IF (es == CD_HCSTAT_BADINPUT) THEN
          ErrStat = es; ErrMsg = em; q_out = q_try; RETURN
        END IF
        ! Path following: a converged stage whose centreline moved more than a small
        ! fraction of the line length from the previous accepted stage may have jumped to
        ! another equilibrium branch; it is retried with a smaller stiffness step.
        IF (es == CD_HCSTAT_OK .AND. n_accepted > 0) THEN
          IF (max_move(q, q_try) > STAGE_MOVE_TOL*SUM(l0) .AND. dlog > 2.0_wp*DLOG_MIN .AND. .NOT. snapped) &
            es = CD_HCSTAT_NOCONVERGE
        END IF
        IF (es == CD_HCSTAT_OK) THEN
          q = q_try
          lambda = lambda_try
          n_accepted = n_accepted + 1
          IF (final_stage) EXIT
          dlog = MIN(DLOG_MAX, 1.5_wp*dlog)
        ELSE
          ! The first stage has no accepted predecessor. When the catenary is too sharp for
          ! the mesh at a small stiffness (a near-slack bend tighter than an element), the
          ! stiffness-scaled problem is ill-conditioned near the seed; the full-stiffness
          ! problem is regular, so the energy descent restarts there from the seed.
          IF (n_accepted == 0) THEN
            IF (lambda_try < CD_ONE .AND. iters_out < iteration_budget) THEN
              lambda_try = CD_ONE
              restart_stage = .TRUE.
              CYCLE
            END IF
            ErrStat = CD_HCSTAT_NOCONVERGE
            ErrMsg = 'CD_HermiteCable_Static_Solve_Continuation: initial stage failed: '//TRIM(em)
            q_out = q_try; RETURN
          END IF
          dlog = 0.5_wp*dlog
          IF (dlog < DLOG_MIN) THEN
            ! The branch ends at a limit point in the stiffness: past it the equilibrium
            ! snaps to another stable configuration. Descend once at full stiffness from
            ! the last converged state, with the restart allowance and no move limit.
            IF (.NOT. snapped .AND. iters_out < iteration_budget) THEN
              snapped = .TRUE.
              restart_stage = .TRUE.
              lambda_try = CD_ONE
              CYCLE
            END IF
            ErrStat = CD_HCSTAT_NOCONVERGE
            BLOCK
              ! Local buffer: a record longer than the caller's ErrMsg truncates
              ! instead of aborting the internal write.
              CHARACTER(1024) :: wmsg
              INTEGER :: wios
              wmsg = ''
              WRITE (wmsg, '(A,ES10.3,A)', IOSTAT=wios) &
                'CD_HermiteCable_Static_Solve_Continuation: EI continuation stalled at EI fraction ', &
                lambda, ' (step below 1/64 decade)'
              ErrMsg = wmsg
            END BLOCK
            q_out = q; RETURN
          END IF
        END IF
        IF (iters_out >= iteration_budget) THEN
          ErrStat = CD_HCSTAT_NOCONVERGE
          BLOCK
            ! Local buffer: a record longer than the caller's ErrMsg truncates
            ! instead of aborting the internal write.
            CHARACTER(1024) :: wmsg
            INTEGER :: wios
            wmsg = ''
            WRITE (wmsg, '(A,I0,A,ES10.3)', IOSTAT=wios) &
              'CD_HermiteCable_Static_Solve_Continuation: iteration budget (', &
              iteration_budget, ') exhausted at EI fraction ', lambda
            ErrMsg = wmsg
          END BLOCK
          q_out = q; RETURN
        END IF
        IF (n_accepted == 0) THEN
          lambda_try = ei_start
        ELSE
          lambda_try = MIN(CD_ONE, lambda*10.0_wp**dlog)
        END IF
      END DO
    END SUBROUTINE ei_homotopy

    SUBROUTINE full_fixed_point(ok)
      !! The drag fixed point at full stiffness and full drag, from q, on its own
      !! iteration budget (iters_out reports both).
      LOGICAL, INTENT(OUT) :: ok
      INTEGER :: iters_before
      ei_stage = EI
      IF (PRESENT(endconn_stiffness)) k_stage = endconn_stiffness
      restart_stage = .FALSE.
      iters_before = iters_out
      iters_out = 0
      CALL fixed_point_level(CD_ONE, ok)
      iters_out = iters_out + iters_before
    END SUBROUTINE full_fixed_point

    LOGICAL FUNCTION frictionless_run_limit(qx) RESULT(run_limit)
      !! TRUE when the diagnosis of state qx is a grounded run driven along a frictionless
      !! seabed (see current_compression_note).
      REAL(wp), INTENT(IN) :: qx(:)
      CHARACTER(1024) :: note
      LOGICAL :: flat
      flat = .NOT. PRESENT(bathymetry)
      run_limit = .FALSE.
      IF (.NOT. PRESENT(current)) RETURN
      IF (.NOT. current_has_drag(current)) RETURN
      note = current_compression_note(l0, EA, qx, seabed_z, flat, use_fric, run_limit, EI=EI, w=w)
    END FUNCTION frictionless_run_limit

    FUNCTION compression_note(qx) RESULT(note)
      !! current_compression_note for this line (flat seabed plane unless bathymetry).
      REAL(wp), INTENT(IN) :: qx(:)
      CHARACTER(1024) :: note
      LOGICAL :: flat
      flat = .NOT. PRESENT(bathymetry)
      note = ''
      IF (.NOT. PRESENT(current)) RETURN
      IF (.NOT. current_has_drag(current)) RETURN
      note = current_compression_note(l0, EA, qx, seabed_z, flat, use_fric, EI=EI, w=w)
    END FUNCTION compression_note

    FUNCTION fixed_point_name() RESULT(name)
      !! The frozen-load fixed point of this solve in its messages: the current drag, or the
      !! seabed friction a zero-velocity carrier holds in still water.
      CHARACTER(40) :: name
      name = 'seabed friction fixed point'
      IF (PRESENT(current)) THEN
        IF (current_has_drag(current)) name = 'current drag fixed point'
      END IF
    END FUNCTION fixed_point_name

    FUNCTION fraction_name() RESULT(name)
      !! The continuation parameter of the load steps in messages (see fixed_point_name).
      CHARACTER(16) :: name
      name = 'load fraction'
      IF (PRESENT(current)) THEN
        IF (current_has_drag(current)) name = 'drag fraction'
      END IF
    END FUNCTION fraction_name

    SUBROUTINE drag_arclength(ok)
      !! Pseudo-arclength continuation of F(q, lambda) = R(q; lambda * drag) = 0 in the drag
      !! fraction lambda, from the last converged state (q, cur_frac) to lambda = 1, passing
      !! limit points where the path turns back in lambda. Each corrector iteration solves
      !! the bordered system
      !!   [ K    -D ] [dq]   [ -F ]
      !!   [ t_q  t_l] [dl] = [ -g ]
      !! by block elimination with two banded solves (K z1 = -F, K z2 = D; the band is
      !! kept), g being the distance from the predictor's hyperplane. q is weighted by
      !! 1/line length in the arclength metric. When the path crosses lambda = 1 the state
      !! at lambda = 1 is solved at fixed drag from the interpolated point.
      LOGICAL, INTENT(OUT) :: ok
      INTEGER, PARAMETER :: MAX_ARC_STEPS = 400, MAX_CORR = 15
      REAL(wp), PARAMETER :: DS_MIN = 1.0e-5_wp, DS_MAX = 0.2_wp, CORR_TOL = INTERMEDIATE_TOL
      REAL(wp), ALLOCATABLE :: z1(:), z2(:), tq(:), tq_new(:), qp(:), qc(:), qa(:)
      REAL(wp) :: lam, lam_p, lamc, tl, tl_new, ds, g, res_c, lam_a
      INTEGER :: step, corr, k, es_a, n_corr
      LOGICAL :: conv
      ok = .FALSE.
      IF (.NOT. ALLOCATED(fres)) ALLOCATE (fres(6*nn), kband(LDAB_H, 6*nn), kwork(LDAB_H, 6*nn), dvec(6*nn), &
                                           free(6*nn))
      ALLOCATE (z1(6*nn), z2(6*nn), tq(6*nn), tq_new(6*nn), qp(6*nn), qc(6*nn), qa(6*nn))
      IF (.NOT. ALLOCATED(cur_stage)) ALLOCATE (cur_stage, SOURCE=current)
      free = .TRUE.
      DO k = 1, SIZE(fixed_dofs)
        free(fixed_dofs(k)) = .FALSE.
      END DO
      ! A Rigid end: the static solve returns its end-tangent rows and columns in the basis of
      ! the end direction (CD_EndConn_Basis), whose first component is the free tangent
      ! magnitude and whose two transverse components are held.
      arc_rigid = .FALSE.
      IF (PRESENT(endconn_mode) .AND. PRESENT(endconn_direction)) THEN
        DO k = 1, 2
          IF (endconn_mode(k) /= CD_ENDCONN_RIGID) CYCLE
          CALL CD_EndConn_Basis(endconn_direction(:, k), arc_basis(:, :, k), es_a, em)
          IF (es_a /= CD_ENDCONN_OK) THEN
            em = 'arclength continuation: '//TRIM(em); RETURN
          END IF
          arc_rigid(k) = .TRUE.
          free(arc_tangent_base(k) + 2:arc_tangent_base(k) + 3) = .FALSE.
        END DO
      END IF
      ei_stage = EI
      IF (PRESENT(endconn_stiffness)) k_stage = endconn_stiffness
      wq = CD_ONE/SUM(l0)
      lam = cur_frac
      ! Tangent at the start: dq/dlambda = K^-1 D.
      CALL arc_assemble(q, lam, res_c, es_a)
      IF (es_a /= CD_HCSTAT_OK) RETURN
      CALL arc_tangent(tq, tl, es_a)
      IF (es_a /= CD_HCSTAT_OK) RETURN
      IF (tl < CD_ZERO) THEN
        tq = -tq; tl = -tl
      END IF
      ds = 0.05_wp
      DO step = 1, MAX_ARC_STEPS
        ! Predictor along the unit tangent: (q, lambda) moves by ds*(tq, tl), whose length
        ! in the weighted metric (CD_Arclength_Dot) is ds.
        qp = q + ds*tq
        lam_p = lam + ds*tl
        qc = qp
        lamc = lam_p
        conv = .FALSE.
        n_corr = 0
        DO corr = 1, MAX_CORR
          n_corr = corr
          CALL arc_assemble(qc, lamc, res_c, es_a)
          IF (es_a /= CD_HCSTAT_OK) EXIT
          g = CD_Arclength_Dot(wq, tq, tl, qc - qp, lamc - lam_p)
          IF (res_c < CORR_TOL .AND. ABS(g) < 1.0e-10_wp) THEN
            conv = .TRUE.
            EXIT
          END IF
          kwork = kband
          z1 = -fres
          CALL CD_Solve_Banded(kwork, KL_H, KU_H, z1, es_a, em)
          IF (es_a /= CD_LINALG_OK) EXIT
          kwork = kband
          z2 = dvec
          CALL CD_Solve_Banded(kwork, KL_H, KU_H, z2, es_a, em)
          IF (es_a /= CD_LINALG_OK) EXIT
          CALL arc_to_global(z1)
          CALL arc_to_global(z2)
          CALL CD_Arclength_Bordered_Update(wq, tq, tl, g, z1, z2, qc, lamc, es_a)
          IF (es_a /= 0) EXIT
          IF (.NOT. CD_All_Finite(qc) .OR. .NOT. CD_Is_Finite(lamc)) EXIT
        END DO
        iters_out = iters_out + n_corr
        IF (.NOT. conv) THEN
          ds = 0.5_wp*ds
          IF (ds < DS_MIN .OR. iters_out >= iteration_budget) THEN
            WRITE (em, '(A,F6.3,A)') 'stalled at '//TRIM(fraction_name())//' ', lam, &
              ' (arclength step below its minimum)'
            RETURN
          END IF
          CYCLE
        END IF
        ! Crossing lambda = 1: interpolate and solve at the full drag.
        IF (lamc >= CD_ONE) THEN
          qa = q + (qc - q)*(CD_ONE - lam)/MAX(lamc - lam, TINY(CD_ONE))
          lam_a = CD_ONE
          cur_stage%load_factor = current%load_factor
          stage_tol = MAX(tol, INTERMEDIATE_TOL)
          CALL stage_solve(ei_stage, qa, q_try, curv, res, it, es, em, .FALSE.)
          iters_out = iters_out + it
          IF (es == CD_HCSTAT_NOCONVERGE) THEN
            CALL stage_solve(ei_stage, qa, q_try, curv, res, it, es, em, .TRUE.)
            iters_out = iters_out + it
          END IF
          IF (es == CD_HCSTAT_OK) THEN
            q = q_try
            cur_frac = CD_ONE
            ok = .TRUE.
            RETURN
          END IF
          ds = 0.5_wp*ds
          IF (ds < DS_MIN) RETURN
          CYCLE
        END IF
        ! Accept; new tangent oriented along the travelled direction.
        CALL arc_assemble(qc, lamc, res_c, es_a)
        IF (es_a /= CD_HCSTAT_OK) RETURN
        CALL arc_tangent(tq_new, tl_new, es_a)
        IF (es_a /= CD_HCSTAT_OK) RETURN
        IF (CD_Arclength_Dot(wq, tq_new, tl_new, tq, tl) < CD_ZERO) THEN
          tq_new = -tq_new; tl_new = -tl_new
        END IF
        q = qc
        lam = lamc
        cur_frac = MAX(CD_ZERO, lam)
        tq = tq_new
        tl = tl_new
        IF (n_corr <= 4) ds = MIN(DS_MAX, 1.5_wp*ds)
        IF (iters_out >= iteration_budget) THEN
          WRITE (em, '(A,F6.3)') 'iteration budget exhausted at '//TRIM(fraction_name())//' ', lam
          RETURN
        END IF
      END DO
      WRITE (em, '(A,F6.3)') 'step limit reached at '//TRIM(fraction_name())//' ', lam
    END SUBROUTINE drag_arclength

    SUBROUTINE arc_assemble(qx, lamx, resx, esx)
      !! Residual, banded tangent and drag load (dvec = D, the drag at full current) at
      !! (qx, lamx); fixed DOFs zeroed in dvec.
      REAL(wp), INTENT(IN) :: qx(:), lamx
      REAL(wp), INTENT(OUT) :: resx
      INTEGER, INTENT(OUT) :: esx
      REAL(wp) :: qdum(6*nn), cdum(nn)
      INTEGER :: itx, kk, jj
      cur_stage%load_factor = lamx*current%load_factor
      IF (PRESENT(endconn_stiffness)) THEN
        CALL CD_HermiteCable_Static_Solve(l0, EA, EI, w, qx, fixed_dofs, seabed_z, kn, 1, 1, HUGE(CD_ONE), &
                                          CD_ONE, qdum, cdum, resx, itx, esx, em, n_buoy_steps=1, &
                                          contact_kn=contact_kn, bathymetry=bathymetry, &
                                          contact_frame_cs=contact_frame_cs, &
                                          axial_quadrature_order=axial_quadrature_order, &
                                          bending_quadrature_order=bending_quadrature_order, &
                                          endconn_stiffness=k_stage, endconn_direction=endconn_direction, &
                                          endconn_mode=endconn_mode, waterline_z=waterline_z, &
                                          dry_buoyancy=dry_buoyancy, water_weight=water_weight, &
                                          current=cur_stage, residual_out=fres, tangent_out=kband)
      ELSE
        CALL CD_HermiteCable_Static_Solve(l0, EA, EI, w, qx, fixed_dofs, seabed_z, kn, 1, 1, HUGE(CD_ONE), &
                                          CD_ONE, qdum, cdum, resx, itx, esx, em, n_buoy_steps=1, &
                                          contact_kn=contact_kn, bathymetry=bathymetry, &
                                          contact_frame_cs=contact_frame_cs, &
                                          axial_quadrature_order=axial_quadrature_order, &
                                          bending_quadrature_order=bending_quadrature_order, &
                                          waterline_z=waterline_z, dry_buoyancy=dry_buoyancy, &
                                          water_weight=water_weight, current=cur_stage, &
                                          residual_out=fres, tangent_out=kband)
      END IF
      IF (esx == CD_HCSTAT_NOCONVERGE) esx = CD_HCSTAT_OK
      IF (esx /= CD_HCSTAT_OK) RETURN
      CALL CD_HermiteCable_Current_Load(l0, qx, current, dvec, esx, em)
      IF (esx /= CD_HCSTAT_OK) RETURN
      ! the drag load in the basis of a Rigid end, as the residual and tangent are
      DO kk = 1, 2
        IF (.NOT. arc_rigid(kk)) CYCLE
        jj = arc_tangent_base(kk)
        dvec(jj + 1:jj + 3) = MATMUL(TRANSPOSE(arc_basis(:, :, kk)), dvec(jj + 1:jj + 3))
      END DO
      ! Held DOFs: zero residual and load, identity rows and columns of the band.
      DO kk = 1, SIZE(dvec)
        IF (free(kk)) CYCLE
        dvec(kk) = CD_ZERO
        fres(kk) = CD_ZERO
        DO jj = MAX(1, kk - KU_H), MIN(SIZE(dvec), kk + KL_H)
          kband(KL_H + KU_H + 1 + jj - kk, kk) = CD_ZERO
        END DO
        DO jj = MAX(1, kk - KL_H), MIN(SIZE(dvec), kk + KU_H)
          kband(KL_H + KU_H + 1 + kk - jj, jj) = CD_ZERO
        END DO
        kband(KL_H + KU_H + 1, kk) = CD_ONE
      END DO
    END SUBROUTINE arc_assemble

    SUBROUTINE arc_tangent(tqx, tlx, esx)
      !! Unit tangent (weighted metric) of the path at the last assembled point:
      !! dq/dlambda = K^-1 D, normalised with the lambda component tlx.
      REAL(wp), INTENT(OUT) :: tqx(:), tlx
      INTEGER, INTENT(OUT) :: esx
      kwork = kband
      tqx = dvec
      CALL CD_Solve_Banded(kwork, KL_H, KU_H, tqx, esx, em)
      IF (esx /= CD_LINALG_OK) THEN
        esx = CD_HCSTAT_NOCONVERGE; RETURN
      END IF
      esx = CD_HCSTAT_OK
      CALL arc_to_global(tqx)
      CALL CD_Arclength_Unit_Tangent(wq, tqx, tlx)
    END SUBROUTINE arc_tangent

    INTEGER FUNCTION arc_tangent_base(iend) RESULT(base)
      !! The DOF before the end tangent of End A (iend 1) or End B (iend 2).
      INTEGER, INTENT(IN) :: iend
      base = MERGE(3, 6*(nn - 1) + 3, iend == 1)
    END FUNCTION arc_tangent_base

    SUBROUTINE arc_to_global(vx)
      !! A solved increment from the basis of each Rigid end back to the global components.
      REAL(wp), INTENT(INOUT) :: vx(:)
      INTEGER :: ie, b0
      DO ie = 1, 2
        IF (.NOT. arc_rigid(ie)) CYCLE
        b0 = arc_tangent_base(ie)
        vx(b0 + 1:b0 + 3) = MATMUL(arc_basis(:, :, ie), vx(b0 + 1:b0 + 3))
      END DO
    END SUBROUTINE arc_to_global

    SUBROUTINE drag_load_steps(ok)
      !! Bring the current in at full stiffness from the still-water equilibrium in load
      !! steps (fraction of the drag advancing by up to half the load, halved on failure),
      !! each solved by the drag fixed point.
      LOGICAL, INTENT(OUT) :: ok
      LOGICAL :: level_ok
      REAL(wp) :: cur_try, cur_step
      ok = .FALSE.
      ei_stage = EI
      IF (PRESENT(endconn_stiffness)) k_stage = endconn_stiffness
      restart_stage = .FALSE.
      cur_frac = CD_ZERO
      cur_step = 0.25_wp
      DO
        cur_try = MIN(CD_ONE, cur_frac + cur_step)
        q_level = q
        CALL fixed_point_level(cur_try, level_ok)
        IF (level_ok) THEN
          cur_frac = cur_try
          IF (cur_frac >= CD_ONE) THEN
            ok = .TRUE.
            RETURN
          END IF
          cur_step = MIN(0.5_wp, 1.5_wp*cur_step)
        ELSE
          q = q_level
          cur_step = 0.5_wp*cur_step
          IF (cur_step < CURRENT_STEP_MIN) RETURN
        END IF
        IF (iters_out >= iteration_budget) RETURN
      END DO
    END SUBROUTINE drag_load_steps

    SUBROUTINE fixed_point_level(frac, ok)
      !! Fixed-point iteration on the drag frozen at the previous configuration, at the
      !! drag fraction frac (from q, which it updates). Under-relaxed when the frozen drag
      !! stops contracting.
      REAL(wp), INTENT(IN) :: frac
      LOGICAL, INTENT(OUT) :: ok
      REAL(wp) :: relax, change, change_prev, cap_change
      INTEGER :: k_picard
      ok = .FALSE.
      relax = CD_ONE
      change_prev = HUGE(CD_ONE)
      CALL CD_HermiteCable_Current_Load(l0, q, current, f_prev, es, em)
      IF (es /= CD_HCSTAT_OK) RETURN
      f_prev = frac*f_prev
      f_drag = f_prev
      ! Seabed friction rides along with its capacities frozen at the same configuration
      ! as the drag, and they are iterated to their fixed point together.
      IF (use_fric) THEN
        IF (.NOT. ALLOCATED(fric_stage%frozen_capacity)) ALLOCATE (fric_stage%frozen_capacity(nn))
        CALL friction_capacity(q, fric_stage%frozen_capacity)
      END IF
      DO k_picard = 1, MAX_PICARD
        stage_tol = MAX(tol, INTERMEDIATE_TOL)
        CALL stage_solve(ei_stage, q, q_try, curv, res, it, es, em, .FALSE., f_drag)
        iters_out = iters_out + it
        IF (es == CD_HCSTAT_NOCONVERGE .AND. iters_out < iteration_budget) THEN
          CALL stage_solve(ei_stage, q, q_try, curv, res, it, es, em, .TRUE., f_drag)
          iters_out = iters_out + it
        END IF
        IF (es /= CD_HCSTAT_OK) RETURN
        q = q_try
        CALL CD_HermiteCable_Current_Load(l0, q, current, f_drag, es, em)
        IF (es /= CD_HCSTAT_OK) RETURN
        f_drag = frac*f_drag
        change = MAXVAL(ABS(f_drag - f_prev))
        cap_change = CD_ZERO
        IF (use_fric) THEN
          cap_work = fric_stage%frozen_capacity
          CALL friction_capacity(q, fric_stage%frozen_capacity)
          cap_change = MAXVAL(ABS(fric_stage%frozen_capacity - cap_work))/ &
                       MAX(MAXVAL(ABS(fric_stage%frozen_capacity)), TINY(CD_ONE))
        END IF
        IF (change <= PICARD_TOL*MAX(MAXVAL(ABS(f_drag)), TINY(CD_ONE)) .AND. cap_change <= PICARD_TOL) THEN
          ok = .TRUE.
          RETURN
        END IF
        IF (change > change_prev) relax = MAX(0.125_wp, 0.5_wp*relax)
        change_prev = change
        f_drag = f_prev + relax*(f_drag - f_prev)
        f_prev = f_drag
        IF (iters_out >= iteration_budget) RETURN
      END DO
    END SUBROUTINE fixed_point_level

    SUBROUTINE friction_capacity(qx, cap)
      !! Friction capacity mu*normal of every node in state qx (the seabed law of the
      !! static solve: nodal stiffnesses, or kn times the tributary length).
      REAL(wp), INTENT(IN) :: qx(:)
      REAL(wp), INTENT(OUT) :: cap(:)
      REAL(wp) :: z_floor, gxg, gyg, xg, yg, normal, normal_gap, trib_k, cs(2), mu_c, q_c, gq_c(2)
      REAL(wp), ALLOCATABLE :: fr_ref_c(:, :), kn_c(:)
      INTEGER :: k, es_c
      CHARACTER(1024) :: em_c
      cs = [CD_ONE, CD_ZERO]
      IF (PRESENT(contact_frame_cs)) cs = contact_frame_cs
      IF (current%friction%mu_axial > CD_ZERO .AND. ABS(current%friction%mu_axial - current%friction%mu) > CD_ZERO) THEN
        ALLOCATE (fr_ref_c(2, nn))
        ! an as-laid reference laid on this mesh, as the solve lays it (with its nodal
        ! seabed stiffnesses: contact_kn, or kn times the tributary length)
        ALLOCATE (kn_c(nn))
        IF (PRESENT(contact_kn)) THEN
          kn_c = contact_kn
        ELSE
          kn_c = CD_ZERO
          DO k = 1, ne
            kn_c(k:k + 1) = kn_c(k:k + 1) + 0.5_wp*l0(k)
          END DO
          kn_c = kn*kn_c
        END IF
        CALL CD_HermiteCable_Friction_Reference(current%friction, l0, qx(1:2), fr_ref_c, es_c, em_c, EA=EA, w=w, &
                                                node_kn=kn_c, bathymetry=bathymetry)
        IF (es_c /= CD_HCSTAT_OK) DEALLOCATE (fr_ref_c)
      END IF
      DO k = 1, nn
        z_floor = seabed_z
        gxg = CD_ZERO
        gyg = CD_ZERO
        IF (PRESENT(bathymetry)) THEN
          xg = cs(1)*qx(6*k - 5) - cs(2)*qx(6*k - 4)
          yg = cs(2)*qx(6*k - 5) + cs(1)*qx(6*k - 4)
          CALL CD_Bathymetry_Floor_Gradient(bathymetry, xg, yg, z_floor, gxg, gyg, es_c, em_c)
          IF (es_c /= CD_BATHY_OK) THEN
            ! Only a frozen capacity estimate: the solve that follows queries the same
            ! point and fails closed on it.
            z_floor = seabed_z
            gxg = CD_ZERO
            gyg = CD_ZERO
          END IF
        END IF
        IF (PRESENT(contact_kn)) THEN
          CALL CD_Seabed_Normal_Law((z_floor - qx(6*k - 3))/SQRT(CD_ONE + gxg*gxg + gyg*gyg), contact_kn(k), &
                                    normal, normal_gap)
        ELSE
          trib_k = CD_ZERO
          IF (k > 1) trib_k = trib_k + 0.5_wp*l0(MAX(k - 1, 1))
          IF (k < nn) trib_k = trib_k + 0.5_wp*l0(MIN(k, ne))
          normal = kn*trib_k*MAX(z_floor - qx(6*k - 3), CD_ZERO)/SQRT(CD_ONE + gxg*gxg + gyg*gyg)
        END IF
        cap(k) = current%friction%mu*MAX(normal, CD_ZERO)
        IF (ALLOCATED(fr_ref_c)) THEN
          ! anisotropic: the capacity of the present slip direction, mu(d) N
          CALL CD_Seabed_Friction_Mu_Dir(qx(6*k - 5:6*k - 4) - fr_ref_c(:, k), current%friction%mu_axial, &
                                         current%friction%mu, qx(6*k - 2:6*k - 1), mu_c, q_c, gq_c)
          cap(k) = mu_c*MAX(normal, CD_ZERO)
        END IF
      END DO
    END SUBROUTINE friction_capacity

    PURE REAL(wp) FUNCTION max_move(qa, qb) RESULT(d)
      !! Largest nodal position change between two states.
      REAL(wp), INTENT(IN) :: qa(:), qb(:)
      INTEGER :: k
      d = CD_ZERO
      DO k = 1, SIZE(qa)/6
        d = MAX(d, NORM2(qa(6*(k - 1) + 1:6*(k - 1) + 3) - qb(6*(k - 1) + 1:6*(k - 1) + 3)))
      END DO
    END FUNCTION max_move

    SUBROUTINE stage_solve(ei_x, seed_x, q_x, curv_x, res_x, it_x, es_x, em_x, ptc, f_frozen)
      REAL(wp), INTENT(IN) :: ei_x(:), seed_x(:)
      REAL(wp), INTENT(OUT) :: q_x(:), curv_x(:), res_x
      INTEGER, INTENT(OUT) :: it_x, es_x
      CHARACTER(*), INTENT(OUT) :: em_x
      LOGICAL, INTENT(IN) :: ptc
      REAL(wp), INTENT(IN), OPTIONAL :: f_frozen(:)
      INTEGER :: iter_x, stall_x
      iter_x = PTC_ITER_FACTOR*max_iter
      IF (restart_stage) iter_x = MAX(iter_x, MIN(iteration_budget - iters_out, RESTART_ITER_FACTOR*iter_x))
      ! The energy pass of a restart descends from far away (on a long line, through more than
      ! a thousand iterations in which the residual rises and falls while the energy falls):
      ! past the restart allowance it runs on while the residual keeps falling, and stops after
      ! an allowance without progress. A fixed count sat within the scatter of the length of
      ! such a descent, so the last digits of the input (as from turning the line about the
      ! vertical) decided whether the statics solved. The extension ends at one and a half
      ! allowances: a descent still going there can settle on a folded branch that a
      ! different start avoids (the PTC retry and the caller's other routes follow).
      stall_x = iter_x
      IF (restart_stage .AND. .NOT. ptc) iter_x = MAX(iter_x, MIN(iteration_budget - iters_out, (3*iter_x)/2))
      IF (PRESENT(endconn_stiffness)) THEN
        CALL CD_HermiteCable_Static_Solve(l0, EA, ei_x, w, seed_x, fixed_dofs, seabed_z, kn, 1, iter_x, &
                                          stage_tol, CD_ONE, q_x, curv_x, res_x, it_x, es_x, em_x, &
                                          f_nodal=f_frozen, n_buoy_steps=1, contact_kn=contact_kn, &
                                          bathymetry=bathymetry, &
                                          contact_frame_cs=contact_frame_cs, backtracking=.TRUE., &
                                          merit_line_search=.TRUE., pseudo_transient=ptc, &
                                          energy_minimization=.NOT. ptc, &
                                          axial_quadrature_order=axial_quadrature_order, &
                                          bending_quadrature_order=bending_quadrature_order, &
                                          endconn_stiffness=k_stage, endconn_direction=endconn_direction, &
                                          endconn_mode=endconn_mode, waterline_z=waterline_z, &
                                          dry_buoyancy=dry_buoyancy, water_weight=water_weight, current=cur_stage, &
                                          friction=fric_stage, stall_limit=stall_x)
      ELSE
        CALL CD_HermiteCable_Static_Solve(l0, EA, ei_x, w, seed_x, fixed_dofs, seabed_z, kn, 1, iter_x, &
                                          stage_tol, CD_ONE, q_x, curv_x, res_x, it_x, es_x, em_x, &
                                          f_nodal=f_frozen, n_buoy_steps=1, contact_kn=contact_kn, &
                                          bathymetry=bathymetry, &
                                          contact_frame_cs=contact_frame_cs, backtracking=.TRUE., &
                                          merit_line_search=.TRUE., pseudo_transient=ptc, &
                                          energy_minimization=.NOT. ptc, &
                                          axial_quadrature_order=axial_quadrature_order, &
                                          bending_quadrature_order=bending_quadrature_order, &
                                          waterline_z=waterline_z, dry_buoyancy=dry_buoyancy, &
                                          water_weight=water_weight, current=cur_stage, friction=fric_stage, &
                                          stall_limit=stall_x)
      END IF
    END SUBROUTINE stage_solve

  END SUBROUTINE CD_HermiteCable_Static_Solve_Continuation

  SUBROUTINE CD_HermiteCable_Sequence_Coarse_Max_Length(l0, EA, EI, w, n_levels, max_length, &
                                                        ErrStat, ErrMsg, contact_diameter, coarse_elements)
    !! Return the longest ACTUAL coarse cell produced by the interface-preserving
    !! 3:2 hierarchy.  This is the same grouping routine used by the sequenced
    !! solver, so callers can enforce a physical coarsening limit on nonuniform
    !! meshes without approximating the hierarchy by a global mean element length.
    REAL(wp), INTENT(IN) :: l0(:), EA(:), EI(:), w(:)
    INTEGER, INTENT(IN) :: n_levels
    REAL(wp), INTENT(OUT) :: max_length
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    REAL(wp), INTENT(IN), OPTIONAL :: contact_diameter(:)
    INTEGER, INTENT(OUT), OPTIONAL :: coarse_elements

    INTEGER, ALLOCATABLE :: nodes(:)
    INTEGER :: ne, target_ne, next_target_ne, level, cell

    ErrStat = CD_HCSTAT_OK
    ErrMsg = ''
    max_length = CD_ZERO
    IF (PRESENT(coarse_elements)) coarse_elements = 0
    ne = SIZE(l0)
    IF (ne < 1 .OR. SIZE(EA) /= ne .OR. SIZE(EI) /= ne .OR. SIZE(w) /= ne) THEN
      CALL fail_query('l0/EA/EI/w must be same length ne >= 1'); RETURN
    END IF
    IF (.NOT. CD_All_Finite(l0) .OR. .NOT. CD_All_Finite(EA) .OR. &
        .NOT. CD_All_Finite(EI) .OR. .NOT. CD_All_Finite(w)) THEN
      CALL fail_query('inputs must be finite'); RETURN
    END IF
    IF (ANY(l0 <= CD_ZERO) .OR. ANY(EA < CD_ZERO) .OR. ANY(EI < CD_ZERO)) THEN
      CALL fail_query('l0>0, EA>=0, EI>=0 required'); RETURN
    END IF
    IF (n_levels < 1 .OR. n_levels > 20) THEN
      CALL fail_query('n_levels must be in [1,20]'); RETURN
    END IF
    IF (PRESENT(contact_diameter)) THEN
      IF (SIZE(contact_diameter) /= ne .OR. .NOT. CD_All_Finite(contact_diameter) .OR. &
          ANY(contact_diameter <= CD_ZERO)) THEN
        CALL fail_query('contact_diameter must contain ne finite positive values'); RETURN
      END IF
    END IF
    target_ne = ne
    DO level = 1, n_levels - 1
      next_target_ne = target_ne - target_ne/3
      IF (next_target_ne >= target_ne) THEN
        CALL fail_query('n_levels must define distinct meshes with >= 2 coarse elements'); RETURN
      END IF
      target_ne = next_target_ne
    END DO
    IF (target_ne < 2) THEN
      CALL fail_query('coarsest level must keep >= 2 elements'); RETURN
    END IF

    IF (PRESENT(contact_diameter)) THEN
      CALL build_sequence_coarse_nodes(EA, EI, w, target_ne, .TRUE., nodes, contact_diameter)
    ELSE
      CALL build_sequence_coarse_nodes(EA, EI, w, target_ne, .TRUE., nodes)
    END IF
    DO cell = 1, SIZE(nodes) - 1
      max_length = MAX(max_length, SUM(l0(nodes(cell):nodes(cell + 1) - 1)))
    END DO
    IF (PRESENT(coarse_elements)) coarse_elements = SIZE(nodes) - 1

  CONTAINS

    SUBROUTINE fail_query(msg)
      CHARACTER(*), INTENT(IN) :: msg
      ErrStat = CD_HCSTAT_BADINPUT
      ErrMsg = 'CD_HermiteCable_Sequence_Coarse_Max_Length: '//msg
    END SUBROUTINE fail_query

  END SUBROUTINE CD_HermiteCable_Sequence_Coarse_Max_Length

  SUBROUTINE build_sequence_coarse_nodes(EA, EI, w, target_elements, retain_interfaces, nodes, &
                                         contact_diameter)
    !! Build the first/coarsest hierarchy partition from the exact fine mesh.
    !! Mandatory material/load/contact interfaces survive the primary hierarchy.
    REAL(wp), INTENT(IN) :: EA(:), EI(:), w(:)
    INTEGER, INTENT(IN) :: target_elements
    LOGICAL, INTENT(IN) :: retain_interfaces
    INTEGER, ALLOCATABLE, INTENT(OUT) :: nodes(:)
    REAL(wp), INTENT(IN), OPTIONAL :: contact_diameter(:)

    INTEGER, ALLOCATABLE :: tmp(:), run_start(:), run_end(:), subgroups(:)
    LOGICAL, ALLOCATABLE :: keep_node(:)
    INTEGER :: ne, nn, fine_node, count, seg_start, seg_end, nseg, ngroup, group, child
    INTEGER :: nrun, remaining, best_run, desired_groups
    REAL(wp) :: score, best_score, exact_quota

    ne = SIZE(EA)
    nn = ne + 1
    ALLOCATE (tmp(nn), keep_node(nn))
    keep_node = .FALSE.
    keep_node(1) = .TRUE.
    keep_node(nn) = .TRUE.
    IF (retain_interfaces) THEN
      DO fine_node = 2, ne
        keep_node(fine_node) = sequence_material_jump(EA(fine_node - 1), EA(fine_node)) .OR. &
                               sequence_material_jump(EI(fine_node - 1), EI(fine_node)) .OR. &
                               sequence_material_jump(w(fine_node - 1), w(fine_node))
        IF (PRESENT(contact_diameter)) keep_node(fine_node) = keep_node(fine_node) .OR. &
                                                              sequence_material_jump(contact_diameter(fine_node - 1), &
                                                                                     contact_diameter(fine_node))
      END DO
      ALLOCATE (run_start(ne), run_end(ne))
      nrun = 0
      seg_start = 1
      DO WHILE (seg_start < nn)
        seg_end = seg_start + 1
        DO WHILE (seg_end < nn .AND. .NOT. keep_node(seg_end))
          seg_end = seg_end + 1
        END DO
        nrun = nrun + 1
        run_start(nrun) = seg_start
        run_end(nrun) = seg_end
        seg_start = seg_end
      END DO
      ! Start from the nearest-integer section quotas, then make only
      ! the minimum deterministic corrections needed to hit the GLOBAL target.
      ! Independent NINT quotas can undershoot badly when many short sections are
      ! present and turn the following 3:2 polish into 2:1; rebuilding every quota
      ! from scratch can unnecessarily move established few-section partitions.
      ALLOCATE (subgroups(nrun))
      DO group = 1, nrun
        nseg = run_end(group) - run_start(group)
        exact_quota = REAL(nseg, wp)*REAL(target_elements, wp)/REAL(ne, wp)
        subgroups(group) = MIN(nseg, MAX(1, NINT(exact_quota)))
      END DO
      desired_groups = MIN(ne, MAX(target_elements, nrun))
      remaining = desired_groups - SUM(subgroups)
      DO WHILE (remaining > 0)
        best_run = 0
        best_score = -HUGE(CD_ONE)
        DO group = 1, nrun
          nseg = run_end(group) - run_start(group)
          IF (subgroups(group) >= nseg) CYCLE
          exact_quota = REAL(nseg, wp)*REAL(target_elements, wp)/REAL(ne, wp)
          score = exact_quota - REAL(subgroups(group), wp)
          IF (score > best_score) THEN
            best_score = score
            best_run = group
          END IF
        END DO
        IF (best_run == 0) EXIT
        subgroups(best_run) = subgroups(best_run) + 1
        remaining = remaining - 1
      END DO
      DO WHILE (remaining < 0)
        best_run = 0
        best_score = -HUGE(CD_ONE)
        DO group = 1, nrun
          IF (subgroups(group) <= 1) CYCLE
          nseg = run_end(group) - run_start(group)
          exact_quota = REAL(nseg, wp)*REAL(target_elements, wp)/REAL(ne, wp)
          score = REAL(subgroups(group), wp) - exact_quota
          IF (score > best_score) THEN
            best_score = score
            best_run = group
          END IF
        END DO
        IF (best_run == 0) EXIT
        subgroups(best_run) = subgroups(best_run) - 1
        remaining = remaining + 1
      END DO
      DO group = 1, nrun
        seg_start = run_start(group)
        seg_end = run_end(group)
        nseg = seg_end - seg_start
        ngroup = subgroups(group)
        DO child = 1, ngroup - 1
          ! 64-bit product: child*nseg exceeds the default integer range for ne > ~46,000.
          fine_node = seg_start + INT((INT(child, I8)*nseg + ngroup/2)/ngroup)
          keep_node(fine_node) = .TRUE.
        END DO
      END DO
    ELSE
      ngroup = target_elements
      DO group = 1, ngroup - 1
        fine_node = 1 + NINT(REAL(group, wp)*REAL(ne, wp)/REAL(ngroup, wp))
        keep_node(fine_node) = .TRUE.
      END DO
    END IF
    count = 0
    DO fine_node = 1, nn
      IF (.NOT. keep_node(fine_node)) CYCLE
      count = count + 1
      tmp(count) = fine_node
    END DO
    ALLOCATE (nodes(count))
    nodes = tmp(1:count)

  END SUBROUTINE build_sequence_coarse_nodes

  PURE LOGICAL FUNCTION sequence_material_jump(a, b) RESULT(changed)
    REAL(wp), INTENT(IN) :: a, b
    changed = ABS(a - b) > 32.0_wp*EPSILON(CD_ONE)*MAX(CD_ONE, ABS(a), ABS(b))
  END FUNCTION sequence_material_jump

  SUBROUTINE CD_HermiteCable_Static_Solve_Sequenced(l0, EA, EI, w, seed, fixed_dofs, seabed_z, kn, &
                                                    n_cont, max_iter, tol, damping, n_levels, &
                                                    q_out, curv_out, res_out, iters_by_level, &
                                                    ErrStat, ErrMsg, contact_diameter, contact_kbot, &
                                                    bathymetry, contact_frame_cs, reseed_coarse_tangents, &
                                                    extra_coarse_level, axial_quadrature_order, &
                                                    bending_quadrature_order, endconn_stiffness, &
                                                    endconn_direction, endconn_mode, waterline_z, dry_buoyancy, &
                                                    iteration_budget, water_weight, current)
    !! Public deterministic mesh-continuation entry. The interface-preserving 3:2
    !! hierarchy is the primary path. If its full-load branch polish fails, retry one
    !! level shallower and gentler 4:3 and 5:4 hierarchies before the optional deeper
    !! path, an interface-preserving binary hierarchy and, when needed, a conservative
    !! cell-averaged binary coarse homotopy. Every accepted result is polished on the
    !! exact caller mesh. All attempts solve identical final equations with identical
    !! tolerances; the alternative mesh path is numerical globalization, not a physical
    !! or convergence-criterion fallback.
    !! extra_coarse_level optionally permits one additional 3:2 coarse level only after
    !! the requested hierarchy returns NOCONVERGE. Its work is accumulated into the
    !! first iteration-log entry; the exact caller mesh and tolerance remain mandatory.
    !! waterline_z/dry_buoyancy (optional, together) are the free surface and per-element
    !! displaced-water buoyancy of CD_HermiteCable_Static_Solve; coarse levels carry the
    !! length-weighted buoyancy of their merged elements.
    !! iteration_budget (optional): no further hierarchy family is started once the
    !! Newton iterations already spent reach this budget; the call then returns
    !! NOCONVERGE, bounding the failure path.
    REAL(wp), INTENT(IN) :: l0(:), EA(:), EI(:), w(:), seed(:)
    INTEGER, INTENT(IN) :: fixed_dofs(:)
    REAL(wp), INTENT(IN) :: seabed_z, kn, tol, damping
    INTEGER, INTENT(IN) :: n_cont, max_iter, n_levels
    REAL(wp), INTENT(OUT) :: q_out(:), curv_out(:), res_out
    INTEGER, INTENT(OUT) :: iters_by_level(:)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    REAL(wp), INTENT(IN), OPTIONAL :: contact_diameter(:), contact_kbot, contact_frame_cs(2)
    TYPE(CD_BathymetryType), INTENT(IN), OPTIONAL :: bathymetry
    LOGICAL, INTENT(IN), OPTIONAL :: reseed_coarse_tangents, extra_coarse_level
    INTEGER, INTENT(IN), OPTIONAL :: axial_quadrature_order, bending_quadrature_order
    REAL(wp), INTENT(IN), OPTIONAL :: endconn_stiffness(2), endconn_direction(3, 2)
    INTEGER, INTENT(IN), OPTIONAL :: endconn_mode(2)
    REAL(wp), INTENT(IN), OPTIONAL :: waterline_z, dry_buoyancy(:), water_weight
    TYPE(CD_HermiteStaticCurrentType), INTENT(IN), OPTIONAL :: current
    INTEGER, INTENT(IN), OPTIONAL :: iteration_budget

    INTEGER, ALLOCATABLE :: primary_iters(:), shallow_iters(:), gentle_iters(:), fine_iters(:), deeper_iters(:)
    INTEGER, ALLOCATABLE :: binary_iters(:), direct_iters(:)
    INTEGER :: fallback_levels, shallow_levels, shallow_cost, gentle_cost, fine_cost, deeper_levels, deeper_cost
    INTEGER :: coarse_estimate, primary_coarse, next_coarse, i
    CHARACTER(1024) :: primary_msg, shallow_msg, gentle_msg, fine_msg, deeper_msg, binary_msg, averaged_msg, direct_msg
    LOGICAL :: tried_shallow, try_deeper

    CALL solve_seq_try(l0, EA, EI, w, seed, fixed_dofs, seabed_z, kn, &
                       n_cont, max_iter, tol, damping, n_levels, &
                       q_out, curv_out, res_out, iters_by_level, &
                       ErrStat, ErrMsg, contact_diameter, contact_kbot, &
                       bathymetry, contact_frame_cs, reseed_coarse_tangents, &
                       binary_hierarchy=.FALSE., preserve_interfaces=.TRUE., &
                       axial_quadrature_order=axial_quadrature_order, &
                       bending_quadrature_order=bending_quadrature_order, &
                       endconn_stiffness=endconn_stiffness, &
                       endconn_direction=endconn_direction, endconn_mode=endconn_mode, &
                       waterline_z=waterline_z, dry_buoyancy=dry_buoyancy, water_weight=water_weight, current=current)
    CALL reject_unresolved_sequence(l0, q_out, ErrStat, ErrMsg)
    IF (ErrStat /= CD_HCSTAT_NOCONVERGE .OR. n_levels <= 1) RETURN

    ALLOCATE (primary_iters(SIZE(iters_by_level)))
    primary_iters = iters_by_level
    primary_msg = ErrMsg
    shallow_cost = 0
    gentle_cost = 0
    fine_cost = 0
    deeper_cost = 0
    tried_shallow = n_levels > 2
    IF (tried_shallow) THEN
      ! An unresolved or stalled coarse branch can mean that the requested hierarchy
      ! starts below the cable's bending-resolution limit. Retry the same exact-interface
      ! 3:2 path with one fewer level before changing the hierarchy family. The caller
      ! mesh, physical equations and final tolerance remain identical.
      shallow_levels = n_levels - 1
      ALLOCATE (shallow_iters(shallow_levels))
      CALL solve_seq_try(l0, EA, EI, w, seed, fixed_dofs, seabed_z, kn, &
                         n_cont, max_iter, tol, damping, shallow_levels, &
                         q_out, curv_out, res_out, shallow_iters, &
                         ErrStat, shallow_msg, contact_diameter, contact_kbot, &
                         bathymetry, contact_frame_cs, reseed_coarse_tangents, &
                         binary_hierarchy=.FALSE., preserve_interfaces=.TRUE., &
                         axial_quadrature_order=axial_quadrature_order, &
                         bending_quadrature_order=bending_quadrature_order, &
                         endconn_stiffness=endconn_stiffness, &
                         endconn_direction=endconn_direction, endconn_mode=endconn_mode, &
                         waterline_z=waterline_z, dry_buoyancy=dry_buoyancy, water_weight=water_weight, current=current)
      CALL reject_unresolved_sequence(l0, q_out, ErrStat, shallow_msg)
      shallow_cost = SUM(shallow_iters)
      IF (ErrStat == CD_HCSTAT_OK) THEN
        iters_by_level = primary_iters
        iters_by_level(1) = iters_by_level(1) + shallow_cost
        ErrMsg = ''
        RETURN
      END IF
      ! Every later diagnostic reports the primary route; it carries the shallow one too.
      primary_msg = TRIM(primary_msg)//'; shallow 3:2: '//TRIM(shallow_msg)
    END IF

    IF (budget_spent(SUM(primary_iters) + shallow_cost)) RETURN
    ! When only one coarse level is admissible, removing that level would leave no
    ! branch-selection mesh. A 4:3 hierarchy supplies an intermediate resolution
    ! between the primary 3:2 level and a cold solve on the caller mesh.
    ALLOCATE (gentle_iters(n_levels))
    CALL solve_seq_try(l0, EA, EI, w, seed, fixed_dofs, seabed_z, kn, &
                       n_cont, max_iter, tol, damping, n_levels, &
                       q_out, curv_out, res_out, gentle_iters, &
                       ErrStat, gentle_msg, contact_diameter, contact_kbot, &
                       bathymetry, contact_frame_cs, reseed_coarse_tangents, &
                       binary_hierarchy=.FALSE., preserve_interfaces=.TRUE., &
                       axial_quadrature_order=axial_quadrature_order, &
                       bending_quadrature_order=bending_quadrature_order, &
                       endconn_stiffness=endconn_stiffness, &
                       endconn_direction=endconn_direction, &
                       endconn_mode=endconn_mode, &
                       gentle_hierarchy=.TRUE., waterline_z=waterline_z, dry_buoyancy=dry_buoyancy, &
                       water_weight=water_weight, current=current)
    CALL reject_unresolved_sequence(l0, q_out, ErrStat, gentle_msg)
    gentle_cost = SUM(gentle_iters)
    IF (ErrStat == CD_HCSTAT_OK) THEN
      iters_by_level = primary_iters + gentle_iters
      iters_by_level(1) = iters_by_level(1) + shallow_cost
      ErrMsg = ''
      RETURN
    END IF

    IF (budget_spent(SUM(primary_iters) + shallow_cost + gentle_cost)) RETURN
    ! The 5:4 ladder retains a branch-selection mesh when the 4:3 intermediate remains
    ! just below the bending-resolution threshold. It is still distinct from a cold
    ! caller-mesh solve and retains all exact section interfaces.
    ALLOCATE (fine_iters(n_levels))
    CALL solve_seq_try(l0, EA, EI, w, seed, fixed_dofs, seabed_z, kn, &
                       n_cont, max_iter, tol, damping, n_levels, &
                       q_out, curv_out, res_out, fine_iters, &
                       ErrStat, fine_msg, contact_diameter, contact_kbot, &
                       bathymetry, contact_frame_cs, reseed_coarse_tangents, &
                       binary_hierarchy=.FALSE., preserve_interfaces=.TRUE., &
                       axial_quadrature_order=axial_quadrature_order, &
                       bending_quadrature_order=bending_quadrature_order, &
                       endconn_stiffness=endconn_stiffness, &
                       endconn_direction=endconn_direction, &
                       endconn_mode=endconn_mode, &
                       fine_hierarchy=.TRUE., waterline_z=waterline_z, dry_buoyancy=dry_buoyancy, &
                       water_weight=water_weight, current=current)
    CALL reject_unresolved_sequence(l0, q_out, ErrStat, fine_msg)
    fine_cost = SUM(fine_iters)
    IF (ErrStat == CD_HCSTAT_OK) THEN
      iters_by_level = primary_iters + fine_iters
      iters_by_level(1) = iters_by_level(1) + shallow_cost + gentle_cost
      ErrMsg = ''
      RETURN
    END IF

    IF (budget_spent(SUM(primary_iters) + shallow_cost + gentle_cost + fine_cost)) RETURN
    try_deeper = .FALSE.
    IF (PRESENT(extra_coarse_level)) try_deeper = extra_coarse_level
    primary_coarse = SIZE(l0)
    DO i = 2, n_levels
      primary_coarse = primary_coarse - primary_coarse/3
    END DO
    IF (try_deeper .AND. n_levels >= 20) try_deeper = .FALSE.
    IF (try_deeper) THEN
      next_coarse = primary_coarse - primary_coarse/3
      IF (next_coarse >= 2) THEN
        deeper_levels = n_levels + 1
        ALLOCATE (deeper_iters(deeper_levels))
        CALL solve_seq_try(l0, EA, EI, w, seed, fixed_dofs, seabed_z, kn, &
                           n_cont, max_iter, tol, damping, deeper_levels, &
                           q_out, curv_out, res_out, deeper_iters, &
                           ErrStat, deeper_msg, contact_diameter, contact_kbot, &
                           bathymetry, contact_frame_cs, reseed_coarse_tangents, &
                           binary_hierarchy=.FALSE., preserve_interfaces=.TRUE., &
                           axial_quadrature_order=axial_quadrature_order, &
                           bending_quadrature_order=bending_quadrature_order, &
                           endconn_stiffness=endconn_stiffness, &
                           endconn_direction=endconn_direction, endconn_mode=endconn_mode, &
                           waterline_z=waterline_z, dry_buoyancy=dry_buoyancy, water_weight=water_weight, &
                           current=current)
        CALL reject_unresolved_sequence(l0, q_out, ErrStat, deeper_msg)
        deeper_cost = SUM(deeper_iters)
        IF (ErrStat == CD_HCSTAT_OK) THEN
          iters_by_level = primary_iters
          iters_by_level(1) = iters_by_level(1) + shallow_cost + gentle_cost + fine_cost + deeper_cost
          ErrMsg = ''
          RETURN
        END IF
      ELSE
        try_deeper = .FALSE.
      END IF
    END IF
    IF (budget_spent(SUM(primary_iters) + shallow_cost + gentle_cost + fine_cost + deeper_cost)) RETURN
    ! Match the binary fallback's coarsest resolution to (or keep it finer than)
    ! the primary hierarchy. Reusing n_levels verbatim would over-coarsen by
    ! 2^(n_levels-1) and can violate the resolution policy that selected the
    ! 3:2 ladder in the first place.
    fallback_levels = 1
    coarse_estimate = SIZE(l0)
    DO WHILE (fallback_levels < n_levels)
      next_coarse = coarse_estimate - coarse_estimate/2
      IF (next_coarse < primary_coarse) EXIT
      fallback_levels = fallback_levels + 1
      coarse_estimate = next_coarse
    END DO
    ALLOCATE (binary_iters(fallback_levels))
    CALL solve_seq_try(l0, EA, EI, w, seed, fixed_dofs, seabed_z, kn, &
                       n_cont, max_iter, tol, damping, fallback_levels, &
                       q_out, curv_out, res_out, binary_iters, &
                       ErrStat, binary_msg, contact_diameter, contact_kbot, &
                       bathymetry, contact_frame_cs, reseed_coarse_tangents, &
                       binary_hierarchy=.TRUE., preserve_interfaces=.TRUE., &
                       axial_quadrature_order=axial_quadrature_order, &
                       bending_quadrature_order=bending_quadrature_order, &
                       endconn_stiffness=endconn_stiffness, &
                       endconn_direction=endconn_direction, endconn_mode=endconn_mode, &
                       waterline_z=waterline_z, dry_buoyancy=dry_buoyancy, water_weight=water_weight, current=current)
    CALL reject_unresolved_sequence(l0, q_out, ErrStat, binary_msg)
    IF (ErrStat == CD_HCSTAT_OK) THEN
      iters_by_level = primary_iters
      iters_by_level(1) = iters_by_level(1) + shallow_cost + gentle_cost + fine_cost + deeper_cost
      iters_by_level(1:fallback_levels) = iters_by_level(1:fallback_levels) + binary_iters
      ErrMsg = ''
      RETURN
    END IF

    IF (fallback_levels == 1) THEN
      iters_by_level = primary_iters
      iters_by_level(1) = iters_by_level(1) + shallow_cost + gentle_cost + fine_cost + deeper_cost + SUM(binary_iters)
      IF (try_deeper) THEN
        ErrMsg = '3:2, 4:3, 5:4, deeper 3:2 exact-interface and direct fallback exhausted; primary: '// &
                 TRIM(primary_msg)//'; 4:3: '//TRIM(gentle_msg)//'; 5:4: '//TRIM(fine_msg)// &
                 '; deeper: '//TRIM(deeper_msg)//'; direct: '//TRIM(binary_msg)
      ELSE
        ErrMsg = '3:2 exact-interface, 4:3 exact-interface, 5:4 exact-interface and direct fallback exhausted; '// &
                 'primary: '//TRIM(primary_msg)//'; 4:3: '//TRIM(gentle_msg)//'; 5:4: '// &
                 TRIM(fine_msg)//'; direct: '//TRIM(binary_msg)
      END IF
      RETURN
    END IF

    ! Preserve the exact-interface fallback cost before reusing a separate local
    ! iteration buffer for the cell-averaged hierarchy.
    coarse_estimate = SUM(binary_iters)
    IF (budget_spent(SUM(primary_iters) + shallow_cost + gentle_cost + fine_cost + deeper_cost + &
                     coarse_estimate)) RETURN
    CALL solve_seq_try(l0, EA, EI, w, seed, fixed_dofs, seabed_z, kn, &
                       n_cont, max_iter, tol, damping, fallback_levels, &
                       q_out, curv_out, res_out, binary_iters, &
                       ErrStat, averaged_msg, contact_diameter, contact_kbot, &
                       bathymetry, contact_frame_cs, reseed_coarse_tangents, &
                       binary_hierarchy=.TRUE., preserve_interfaces=.FALSE., &
                       axial_quadrature_order=axial_quadrature_order, &
                       bending_quadrature_order=bending_quadrature_order, &
                       endconn_stiffness=endconn_stiffness, &
                       endconn_direction=endconn_direction, endconn_mode=endconn_mode, &
                       waterline_z=waterline_z, dry_buoyancy=dry_buoyancy, water_weight=water_weight, current=current)
    CALL reject_unresolved_sequence(l0, q_out, ErrStat, averaged_msg)
    iters_by_level = primary_iters
    iters_by_level(1) = iters_by_level(1) + shallow_cost + gentle_cost + fine_cost + deeper_cost + coarse_estimate
    iters_by_level(1:fallback_levels) = iters_by_level(1:fallback_levels) + binary_iters
    IF (ErrStat == CD_HCSTAT_OK) THEN
      ErrMsg = ''
      RETURN
    END IF

    IF (budget_spent(SUM(iters_by_level))) RETURN
    ! Contact active sets can change discontinuously when a hierarchy exposes new
    ! nodes. If every branch-preserving ladder fails, make one independent cold solve
    ! on the exact caller mesh. This is not a relaxed acceptance path: the same final
    ! equations, tolerance, and interior-curvature safety gate remain mandatory.
    ALLOCATE (direct_iters(1))
    CALL solve_seq_try(l0, EA, EI, w, seed, fixed_dofs, seabed_z, kn, &
                       n_cont, max_iter, tol, damping, 1, &
                       q_out, curv_out, res_out, direct_iters, &
                       ErrStat, direct_msg, contact_diameter, contact_kbot, &
                       bathymetry, contact_frame_cs, reseed_coarse_tangents, &
                       binary_hierarchy=.FALSE., preserve_interfaces=.TRUE., &
                       axial_quadrature_order=axial_quadrature_order, &
                       bending_quadrature_order=bending_quadrature_order, &
                       endconn_stiffness=endconn_stiffness, &
                       endconn_direction=endconn_direction, endconn_mode=endconn_mode, &
                       waterline_z=waterline_z, dry_buoyancy=dry_buoyancy, water_weight=water_weight, current=current)
    CALL reject_unresolved_sequence(l0, q_out, ErrStat, direct_msg)
    iters_by_level(1) = iters_by_level(1) + direct_iters(1)
    IF (ErrStat == CD_HCSTAT_OK) THEN
      ErrMsg = ''
    ELSE IF (try_deeper) THEN
      ErrMsg = '3:2 exact-interface: '//TRIM(primary_msg)//'; 4:3 exact-interface: '// &
               TRIM(gentle_msg)//'; 5:4 exact-interface: '//TRIM(fine_msg)// &
               '; deeper 3:2 exact-interface: '//TRIM(deeper_msg)// &
               '; binary exact-interface: '//TRIM(binary_msg)// &
               '; binary cell-averaged: '//TRIM(averaged_msg)//'; exact-mesh cold: '//TRIM(direct_msg)
    ELSE
      ErrMsg = '3:2 exact-interface: '//TRIM(primary_msg)//'; 4:3 exact-interface: '// &
               TRIM(gentle_msg)//'; 5:4 exact-interface: '//TRIM(fine_msg)// &
               '; binary exact-interface: '//TRIM(binary_msg)// &
               '; binary cell-averaged: '//TRIM(averaged_msg)// &
               '; exact-mesh cold: '//TRIM(direct_msg)
    END IF

  CONTAINS

    LOGICAL FUNCTION budget_spent(cost)
      !! True (with the NOCONVERGE result set) once cost reaches iteration_budget.
      INTEGER, INTENT(IN) :: cost
      budget_spent = .FALSE.
      IF (.NOT. PRESENT(iteration_budget)) RETURN
      IF (cost < iteration_budget) RETURN
      budget_spent = .TRUE.
      ErrStat = CD_HCSTAT_NOCONVERGE
      iters_by_level = primary_iters
      iters_by_level(1) = iters_by_level(1) + MAX(0, cost - SUM(primary_iters))
      ErrMsg = 'mesh-sequenced fallback stopped at its iteration budget; primary hierarchy: '//TRIM(primary_msg)
    END FUNCTION budget_spent

  END SUBROUTINE CD_HermiteCable_Static_Solve_Sequenced

  SUBROUTINE solve_seq_try(l0, EA, EI, w, seed, fixed_dofs, seabed_z, kn, &
                           n_cont, max_iter, tol, damping, n_levels, &
                           q_out, curv_out, res_out, iters_by_level, &
                           ErrStat, ErrMsg, contact_diameter, contact_kbot, &
                           bathymetry, contact_frame_cs, reseed_coarse_tangents, &
                           binary_hierarchy, preserve_interfaces, &
                           axial_quadrature_order, bending_quadrature_order, &
                           gentle_hierarchy, fine_hierarchy, &
                           endconn_stiffness, endconn_direction, endconn_mode, &
                           waterline_z, dry_buoyancy, water_weight, current)
    !! Mesh-sequenced static solve: the DEFAULT fine-mesh architecture for hard equilibria
    !! (net-buoyant lazy-wave arches, installed cables with touchdown). The full nonlinear
    !! work -- buoyancy continuation, contact settlement, branch selection among the kinked
    !! local equilibria that coexist with the smooth arch -- happens ONCE on the coarsest
    !! mesh, where every Newton iteration is cheap and the smooth branch is easy to hold;
    !! each finer level (at most roughly 3:2 growth up to the caller's mesh) starts at the
    !! cubic-Hermite interpolant of the previous solution and only POLISHES at full loads
    !! (n_cont = 1, n_buoy_steps = 1). A direct fine-mesh solve of a long lazy-wave can
    !! fold into a kinked equilibrium; the sequenced ladder reaches the smooth branch
    !! deterministically.
    !!
    !! All arrays describe the CALLER's fine mesh (ne elements); coarser levels are built
    !! internally by merging balanced runs within each homogeneous section (series
    !! compliance for EA/EI, length-weighted weight, exact total length) and decimating
    !! the seed at the surviving nodes.
    !!
    !! n_levels                : mesh levels including the caller's (>= 1; 1 = plain
    !!                           solve). The primary hierarchy limits consecutive element-count
    !!                           growth to roughly 3:2 and admits arbitrary ne; every
    !!                           EA/EI/weight/contact-diameter interface is retained.
    !!                           At least 2 elements must remain on the coarsest level.
    !! gentle_hierarchy        : internal recovery option using 4:3 rather than 3:2
    !!                           consecutive element-count growth.
    !! fine_hierarchy          : internal recovery option using 5:4 rather than 3:2
    !!                           consecutive element-count growth.
    !! iters_by_level(n_levels): Newton iterations spent per level -- the cost of
    !!                           the solve.
    !! Fixed DOFs are enforced at each level where their node exists (a node survives
    !! level k when it belongs to that level's interface-preserving node partition);
    !! constraints at
    !! nodes that only exist on finer meshes engage once those levels are reached, and
    !! always hold exactly on the caller's mesh. Their enforced values are the CALLER's
    !! seed values at every level (prolongated values are overwritten before polishing).
    !! Other arguments and outputs mirror CD_HermiteCable_Static_Solve; q_out / curv_out /
    !! res_out are the finest-level results. Generalized nodal loads (f_nodal) are not
    !! supported on the sequenced path -- they live on fine nodes with no unique coarse
    !! representative; use the plain solve.
    !! contact_diameter/contact_kbot optionally preserve the production diameter-weighted
    !! nodal seabed law on the final requested mesh. Flat-bed coarse levels use the smooth
    !! equivalent scalar tributary law (derived from contact_kbot and the grounded-end
    !! diameter) for branch selection; the final polish switches to
    !! the exact nodal law. Structured bathymetry retains nodal contact at every level.
    !! reseed_coarse_tangents optionally rebuilds unit chord tangents after the first
    !! decimation. It is intended for deck-generated centreline seeds; arbitrary caller
    !! derivative data are preserved by the default false setting.
    REAL(wp), INTENT(IN) :: l0(:), EA(:), EI(:), w(:), seed(:)
    INTEGER, INTENT(IN) :: fixed_dofs(:)
    REAL(wp), INTENT(IN) :: seabed_z, kn, tol, damping
    INTEGER, INTENT(IN) :: n_cont, max_iter, n_levels
    REAL(wp), INTENT(OUT) :: q_out(:), curv_out(:), res_out
    INTEGER, INTENT(OUT) :: iters_by_level(:)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    REAL(wp), INTENT(IN), OPTIONAL :: contact_diameter(:), contact_kbot, contact_frame_cs(2)
    TYPE(CD_BathymetryType), INTENT(IN), OPTIONAL :: bathymetry
    LOGICAL, INTENT(IN), OPTIONAL :: reseed_coarse_tangents
    LOGICAL, INTENT(IN) :: binary_hierarchy, preserve_interfaces
    INTEGER, INTENT(IN), OPTIONAL :: axial_quadrature_order, bending_quadrature_order
    LOGICAL, INTENT(IN), OPTIONAL :: gentle_hierarchy, fine_hierarchy
    REAL(wp), INTENT(IN), OPTIONAL :: endconn_stiffness(2), endconn_direction(3, 2)
    INTEGER, INTENT(IN), OPTIONAL :: endconn_mode(2)
    REAL(wp), INTENT(IN), OPTIONAL :: waterline_z, dry_buoyancy(:), water_weight
    TYPE(CD_HermiteStaticCurrentType), INTENT(IN), OPTIONAL :: current

    ! Coarse-level dry buoyancy; left unallocated (an absent optional) without a free surface.
    REAL(wp), ALLOCATABLE :: dry_l(:)
    REAL(wp) :: dry_sum
    INTEGER :: ne, nn, lev, target_ne, next_target_ne, ne_l, nn_l, i, j, k, s, es, iters_l, nfx, level_node
    INTEGER :: diagnostic_es
    INTEGER :: recovery_pass, recovery_iters
    REAL(wp) :: res_l, recovery_res_before, kn_level, coarse_tangent(3), tangent_norm, coarse_seed_tol
    REAL(wp), ALLOCATABLE :: l0_l(:), EA_l(:), EI_l(:), w_l(:), seed_l(:), q_l(:), curv_l(:)
    REAL(wp), ALLOCATABLE :: diameter_l(:), contact_kn_l(:)
    REAL(wp), ALLOCATABLE :: q_prev(:)
    INTEGER, ALLOCATABLE :: fx_l(:), nodes_l(:), nodes_prev(:)
    TYPE(CD_HermiteResolutionType) :: coarse_diag
    CHARACTER(1024) :: em_l
    ! The level solve failed only on its final residual (a finite best iterate to continue from).
    LOGICAL :: unmet_l
    CHARACTER(1024) :: diagnostic_msg
    CHARACTER(240) :: level_context
    LOGICAL :: contact_active, use_level_nodal_contact, rebuild_coarse_tangents, coarse_seed_ready
    LOGICAL :: use_gentle_hierarchy, use_fine_hierarchy
    LOGICAL :: previous_state_resolved
    REAL(wp) :: contact_cs(2), diameter_sum

    ErrStat = CD_HCSTAT_OK
    ErrMsg = ''
    res_out = CD_ZERO
    contact_active = PRESENT(contact_diameter) .AND. PRESENT(contact_kbot)
    rebuild_coarse_tangents = .FALSE.
    use_gentle_hierarchy = .FALSE.
    use_fine_hierarchy = .FALSE.
    previous_state_resolved = .FALSE.
    IF (PRESENT(reseed_coarse_tangents)) rebuild_coarse_tangents = reseed_coarse_tangents
    IF (PRESENT(gentle_hierarchy)) use_gentle_hierarchy = gentle_hierarchy
    IF (PRESENT(fine_hierarchy)) use_fine_hierarchy = fine_hierarchy
    contact_cs = [CD_ONE, CD_ZERO]
    IF (PRESENT(contact_frame_cs)) contact_cs = contact_frame_cs

    ne = SIZE(l0)
    nn = ne + 1
    ! Everything the wrapper's OWN preprocessing consumes validates HERE, before the
    ! coarsening or decimation touches it -- not in the delegated per-level solves, which
    ! only see the already-processed arrays. coarsen_props indexes EA/EI/w over the
    ! l0-derived range and forms sums/quotients of the values (a short array reads out of
    ! bounds; a non-finite entry or a negative length corrupts the coarse mesh -- and a
    ! negative l0 whose pair-sum stays positive would pass the per-level check); the seed
    ! decimation copies entries the finest level alone would validate too late.
    IF (ne < 1 .OR. SIZE(EA) /= ne .OR. SIZE(EI) /= ne .OR. SIZE(w) /= ne) THEN
      CALL fail_seq('l0/EA/EI/w must be same length ne >= 1'); RETURN
    END IF
    IF (.NOT. CD_All_Finite(l0) .OR. .NOT. CD_All_Finite(EA) .OR. &
        .NOT. CD_All_Finite(EI) .OR. .NOT. CD_All_Finite(w)) THEN
      CALL fail_seq('inputs must be finite'); RETURN
    END IF
    IF (ANY(l0 <= CD_ZERO) .OR. ANY(EA < CD_ZERO) .OR. ANY(EI < CD_ZERO)) THEN
      CALL fail_seq('l0>0, EA>=0, EI>=0 required'); RETURN
    END IF
    IF (n_levels < 1) THEN
      CALL fail_seq('n_levels must be >= 1'); RETURN
    END IF
    IF (SIZE(iters_by_level) /= n_levels) THEN
      CALL fail_seq('iters_by_level must have n_levels entries'); RETURN
    END IF
    iters_by_level = 0
    IF (n_levels > 20) THEN
      CALL fail_seq('n_levels too large'); RETURN
    END IF
    target_ne = ne
    DO k = 1, n_levels - 1
      IF (binary_hierarchy) THEN
        next_target_ne = target_ne - target_ne/2
      ELSE IF (use_fine_hierarchy) THEN
        next_target_ne = target_ne - target_ne/5
      ELSE IF (use_gentle_hierarchy) THEN
        next_target_ne = target_ne - target_ne/4
      ELSE
        next_target_ne = target_ne - target_ne/3
      END IF
      IF (next_target_ne >= target_ne) THEN
        CALL fail_seq('n_levels must define distinct meshes with >= 2 coarse elements'); RETURN
      END IF
      target_ne = next_target_ne
    END DO
    IF (target_ne < 2) THEN
      CALL fail_seq('coarsest level must keep >= 2 elements'); RETURN
    END IF
    IF (SIZE(seed) /= 6*nn) THEN
      CALL fail_seq('seed must be 6*(ne+1)'); RETURN
    END IF
    IF (.NOT. CD_All_Finite(seed)) THEN
      CALL fail_seq('inputs must be finite'); RETURN
    END IF
    IF (PRESENT(contact_diameter) .NEQV. PRESENT(contact_kbot)) THEN
      CALL fail_seq('contact_diameter and contact_kbot must be supplied together'); RETURN
    END IF
    IF (PRESENT(bathymetry) .AND. .NOT. contact_active) THEN
      CALL fail_seq('bathymetry requires nodal contact inputs'); RETURN
    END IF
    IF (contact_active) THEN
      IF (SIZE(contact_diameter) /= ne .OR. .NOT. CD_All_Finite(contact_diameter) .OR. &
          ANY(contact_diameter <= CD_ZERO) .OR. .NOT. CD_Is_Finite(contact_kbot) .OR. contact_kbot <= CD_ZERO) THEN
        CALL fail_seq('invalid contact diameter/kBot inputs'); RETURN
      END IF
    END IF
    IF (SIZE(q_out) /= 6*nn .OR. SIZE(curv_out) /= nn) THEN
      CALL fail_seq('q_out must be 6*(ne+1); curv_out must be ne+1'); RETURN
    END IF
    IF (SIZE(fixed_dofs) > 0) THEN
      IF (ANY(fixed_dofs < 1) .OR. ANY(fixed_dofs > 6*nn)) THEN
        CALL fail_seq('fixed_dofs out of range'); RETURN
      END IF
    END IF
    IF (PRESENT(endconn_stiffness) .NEQV. PRESENT(endconn_direction)) THEN
      CALL fail_seq('endconn_stiffness and endconn_direction must be supplied together'); RETURN
    END IF
    IF (PRESENT(waterline_z) .NEQV. PRESENT(dry_buoyancy)) THEN
      CALL fail_seq('waterline_z and dry_buoyancy must be supplied together'); RETURN
    END IF
    IF (PRESENT(dry_buoyancy)) THEN
      IF (SIZE(dry_buoyancy) /= ne .OR. .NOT. CD_Is_Finite(waterline_z)) THEN
        CALL fail_seq('dry_buoyancy must have length ne and waterline_z must be finite'); RETURN
      END IF
      IF (.NOT. CD_All_Finite(dry_buoyancy) .OR. ANY(dry_buoyancy < CD_ZERO)) THEN
        CALL fail_seq('dry_buoyancy must be finite and non-negative'); RETURN
      END IF
    END IF

    ! zero-size placeholders so MOVE_ALLOC below always finds an allocated target
    ALLOCATE (q_prev(0), nodes_prev(0))

    DO lev = 1, n_levels
      target_ne = ne
      DO k = lev, n_levels - 1
        IF (binary_hierarchy) THEN
          target_ne = target_ne - target_ne/2
        ELSE IF (use_fine_hierarchy) THEN
          target_ne = target_ne - target_ne/5
        ELSE IF (use_gentle_hierarchy) THEN
          target_ne = target_ne - target_ne/4
        ELSE
          target_ne = target_ne - target_ne/3
        END IF
      END DO
      CALL level_nodes(target_ne, preserve_interfaces, nodes_l)
      ne_l = SIZE(nodes_l) - 1
      nn_l = ne_l + 1
      ! Use the smooth scalar tributary law while selecting the branch on coarse
      ! flat-bed levels, then switch to the exact production nodal law for the
      ! caller's final mesh. Structured bathymetry has no scalar representation
      ! and therefore retains nodal contact throughout.
      use_level_nodal_contact = contact_active .AND. (lev == n_levels .OR. PRESENT(bathymetry))
      ! EA_l is the allocation sentinel. q_l and nodes_l leave via MOVE_ALLOC;
      ! the property/seed/diagnostic arrays are rebuilt for the next nested level.
      IF (ALLOCATED(EA_l)) DEALLOCATE (l0_l, EA_l, EI_l, w_l, seed_l, curv_l, fx_l)
      ALLOCATE (l0_l(ne_l), EA_l(ne_l), EI_l(ne_l), w_l(ne_l), seed_l(6*nn_l), &
                q_l(6*nn_l), curv_l(nn_l), fx_l(SIZE(fixed_dofs)))
      CALL coarsen_props(l0, EA, EI, w, nodes_l, l0_l, EA_l, EI_l, w_l)
      IF (PRESENT(dry_buoyancy)) THEN
        ! Length-weighted buoyancy (total displaced weight preserved); the caller mesh is
        ! carried bitwise.
        IF (ALLOCATED(dry_l)) DEALLOCATE (dry_l)
        ALLOCATE (dry_l(ne_l))
        IF (ne_l == ne) THEN
          dry_l = dry_buoyancy
        ELSE
          DO j = 1, ne_l
            dry_sum = CD_ZERO
            DO k = nodes_l(j), nodes_l(j + 1) - 1
              dry_sum = dry_sum + dry_buoyancy(k)*l0(k)
            END DO
            dry_l(j) = dry_sum/l0_l(j)
          END DO
        END IF
      END IF
      IF (contact_active) THEN
        IF (ALLOCATED(diameter_l)) DEALLOCATE (diameter_l, contact_kn_l)
        ALLOCATE (diameter_l(ne_l), contact_kn_l(nn_l))
        DO j = 1, ne_l
          diameter_sum = CD_ZERO
          DO k = nodes_l(j), nodes_l(j + 1) - 1
            diameter_sum = diameter_sum + contact_diameter(k)*l0(k)
          END DO
          diameter_l(j) = diameter_sum/l0_l(j)
        END DO
        ! Tributary nodal law: half of each adjacent element's diameter x length.
        contact_kn_l = CD_ZERO
        DO j = 1, ne_l
          contact_kn_l(j) = contact_kn_l(j) + 0.5_wp*contact_kbot*diameter_l(j)*l0_l(j)
          contact_kn_l(j + 1) = contact_kn_l(j + 1) + 0.5_wp*contact_kbot*diameter_l(j)*l0_l(j)
        END DO
        kn_level = contact_kbot*diameter_l(1)
      ELSE
        kn_level = kn
      END IF

      IF (lev == 1) THEN
        ! decimate the caller seed at the surviving nodes
        DO j = 1, nn_l
          i = nodes_l(j)
          seed_l(6*(j - 1) + 1:6*(j - 1) + 6) = seed(6*(i - 1) + 1:6*(i - 1) + 6)
        END DO
        ! A derivative sampled from the fine Hermite geometry is not generally the
        ! derivative of its decimated coarse representation. For deck-generated
        ! centreline seeds, rebuild unit chord tangents so the coarse cold start is
        ! the same physical seed a native coarse deck would construct. The option is
        ! explicit and defaults false to preserve arbitrary caller-supplied tangents.
        IF (rebuild_coarse_tangents .AND. ne_l < ne) THEN
          DO j = 1, nn_l
            IF (j < nn_l) THEN
              coarse_tangent = seed_l(6*j + 1:6*j + 3) - &
                               seed_l(6*(j - 1) + 1:6*(j - 1) + 3)
            ELSE
              coarse_tangent = seed_l(6*(j - 1) + 1:6*(j - 1) + 3) - &
                               seed_l(6*(j - 2) + 1:6*(j - 2) + 3)
            END IF
            tangent_norm = NORM2(coarse_tangent)
            IF (tangent_norm > CD_ZERO) &
              seed_l(6*(j - 1) + 4:6*(j - 1) + 6) = coarse_tangent/tangent_norm
          END DO
        END IF
      ELSE
        ! Interpolate at each finer level's actual material coordinate. The hierarchy
        ! is nested but is not required to be a uniform doubling: the final remainder
        ! group and every material/load/contact-diameter interface survive explicitly.
        CALL hermite_prolongate_nested(q_prev, nodes_prev, nodes_l, l0, seed_l)
        IF (contact_active) THEN
          ! Nodal contact on the coarse level does not constrain the cubic curve
          ! between its nodes. A newly exposed refinement node can consequently be
          ! interpolated far below the floor, injecting a large artificial penalty
          ! impulse into the otherwise full-load branch polish. Project only those
          ! newly inserted nodal positions to the declared floor. This changes the
          ! initial guess, never the final equations, material data, or tolerance.
          CALL project_contact(seed_l, nodes_prev, nodes_l, es, em_l)
          IF (es /= CD_HCSTAT_OK) THEN
            ErrStat = es
            ErrMsg = 'CD_HermiteCable_Static_Solve_Sequenced: contact-seed projection failed: '//TRIM(em_l)
            RETURN
          END IF
        END IF
      END IF

      ! map the caller's fixed DOFs onto this level's surviving nodes, enforcing the
      ! CALLER's seed values (a prolongated value at a fixed DOF is overwritten so the
      ! constraint pins the requested number, not the interpolant)
      nfx = 0
      DO i = 1, SIZE(fixed_dofs)
        j = (fixed_dofs(i) - 1)/6 + 1                    ! fine node
        s = MOD(fixed_dofs(i) - 1, 6) + 1                ! DOF slot within the node
        level_node = node_pos(nodes_l, j)
        IF (level_node > 0) THEN
          nfx = nfx + 1
          fx_l(nfx) = 6*(level_node - 1) + s
          seed_l(fx_l(nfx)) = seed(fixed_dofs(i))
        END IF
      END DO

      IF (lev == 1) THEN
        CALL solve_level(n_cont, 40)
      ELSE
        CALL solve_level(1, 1)
      END IF
      iters_by_level(lev) = iters_l
      IF (es == CD_HCSTAT_NOCONVERGE .AND. lev > 1 .AND. &
          unmet_l .AND. CD_All_Finite(q_l)) THEN
        ! Continue the SAME full-EI/full-load problem from the last finite Newton
        ! iterate. Discarding that state would merely repeat part of the failed pass.
        ! Each call remains n_cont=1, n_buoy_steps=1; the physical problem and
        ! tolerance are unchanged. Stop early if a backtracked batch cannot reduce
        ! the residual, because another deterministic pass would repeat it.
        seed_l = q_l
        DO recovery_pass = 1, MAX_FULL_LOAD_RECOVERY_PASSES
          recovery_res_before = res_l
          CALL solve_level(1, 1, use_backtracking_in=.TRUE.)
          recovery_iters = iters_l
          iters_by_level(lev) = iters_by_level(lev) + recovery_iters
          IF (es == CD_HCSTAT_OK) EXIT
          IF (.NOT. unmet_l .OR. .NOT. CD_All_Finite(q_l)) EXIT
          IF (.NOT. CD_Is_Finite(res_l) .OR. &
              res_l >= recovery_res_before*(CD_ONE - 32.0_wp*EPSILON(CD_ONE))) EXIT
          seed_l = q_l
        END DO
      END IF
      IF (es == CD_HCSTAT_NOCONVERGE .AND. lev > 1 .AND. &
          unmet_l .AND. CD_All_Finite(q_l)) THEN
        ! A native DGBSV polish can stall on a mixed-unit Hermite tangent whose
        ! pivot sequence differs between LAPACK implementations. Continue from the
        ! best branch-preserving iterate with the same equations, tolerance and
        ! backtracking, but equilibrate the linear system before factorisation.
        ! This is attempted only after the native recovery is exhausted.
        seed_l = q_l
        DO recovery_pass = 1, MAX_FULL_LOAD_RECOVERY_PASSES
          recovery_res_before = res_l
          CALL solve_level(1, 1, use_backtracking_in=.TRUE., use_equilibration_in=.TRUE.)
          recovery_iters = iters_l
          iters_by_level(lev) = iters_by_level(lev) + recovery_iters
          IF (es == CD_HCSTAT_OK) EXIT
          IF (.NOT. unmet_l .OR. .NOT. CD_All_Finite(q_l)) EXIT
          IF (.NOT. CD_Is_Finite(res_l) .OR. &
              res_l >= recovery_res_before*(CD_ONE - 32.0_wp*EPSILON(CD_ONE))) EXIT
          seed_l = q_l
        END DO
      END IF
      coarse_seed_ready = .FALSE.
      IF (es == CD_HCSTAT_NOCONVERGE .AND. lev < n_levels .AND. &
          unmet_l .AND. CD_All_Finite(q_l) .AND. &
          CD_Is_Finite(res_l)) THEN
        ! Nested iteration needs a resolved state on an intermediate mesh, not the
        ! final caller tolerance. A maximum scaled imbalance below 0.1 per cent is
        ! sufficiently close for Hermite prolongation, with a tighter square-root
        ! forcing value when the requested final tolerance is below 1e-6. The final
        ! mesh is never admitted here and must still meet tol exactly.
        coarse_seed_tol = MAX(tol, MIN(1.0e-3_wp, SQRT(tol)))
        IF (res_l < coarse_seed_tol) THEN
          CALL CD_HermiteCable_Resolution_Metrics(l0_l, q_l, -HUGE(CD_ONE), CD_ZERO, &
                                                  CD_HC_KINK_LIMIT, coarse_diag, diagnostic_es, diagnostic_msg)
          coarse_seed_ready = diagnostic_es == CD_HCSTAT_OK .AND. &
                              coarse_diag%h_kappa_peak <= CD_HC_KINK_LIMIT
        END IF
      END IF
      IF (coarse_seed_ready) THEN
        ! ErrStat describes acceptance of this state as the next mesh's initial
        ! guess only. No coarse state is returned as a physical equilibrium.
        es = CD_HCSTAT_OK
        em_l = ''
      END IF
      IF (es /= CD_HCSTAT_OK .AND. lev < n_levels .AND. previous_state_resolved .AND. &
          es == CD_HCSTAT_NOCONVERGE .AND. unmet_l) THEN
        ! A failed intermediate polish is not a result and must not contaminate the
        ! next seed. Retain the last strictly converged, continuously resolved state
        ! in q_prev and let the next level prolongate it directly. The caller mesh
        ! can never be skipped and remains subject to the exact residual tolerance.
        IF (ALLOCATED(q_l)) DEALLOCATE (q_l)
        CYCLE
      END IF
      IF (es /= CD_HCSTAT_OK) THEN
        ErrStat = es
        IF (lev > 1) THEN
          WRITE (level_context, '(A,I0,A,I0,A,ES10.3,A)') &
            'CD_HermiteCable_Static_Solve_Sequenced: full-load polish at level ', lev, &
            ' (ne=', ne_l, ', residual=', res_l, ') failed after bounded full-load '// &
            'recovery (native and equilibrated); cold continuation disabled: '
        ELSE
          WRITE (level_context, '(A,I0,A,I0,A)') 'CD_HermiteCable_Static_Solve_Sequenced: level ', &
            lev, ' (ne=', ne_l, ') failed: '
        END IF
        ErrMsg = TRIM(level_context)//TRIM(em_l)
        RETURN
      END IF
      CALL CD_HermiteCable_Resolution_Metrics(l0_l, q_l, -HUGE(CD_ONE), CD_ZERO, &
                                              CD_HC_KINK_LIMIT, coarse_diag, diagnostic_es, diagnostic_msg)
      previous_state_resolved = diagnostic_es == CD_HCSTAT_OK .AND. &
                                coarse_diag%h_kappa_peak <= CD_HC_KINK_LIMIT
      CALL MOVE_ALLOC(q_l, q_prev)
      CALL MOVE_ALLOC(nodes_l, nodes_prev)
    END DO

    ! finest-level results (the loop ends with lev = n_levels solved into q_prev/curv_l;
    ! the finest level IS the caller's mesh, so the sizes match the prologue validation)
    q_out = q_prev
    curv_out = curv_l
    res_out = res_l

  CONTAINS

    SUBROUTINE level_nodes(target_elements, retain_interfaces, nodes)
      !! Build a nested subset of fine nodes. target_elements sets the approximate
      !! global resolution. The primary modes retain every section/load/contact
      !! discontinuity; the last-resort cell-averaged homotopy restores all of them on
      !! the exact final mesh before an equilibrium can be accepted.
      INTEGER, INTENT(IN) :: target_elements
      LOGICAL, INTENT(IN) :: retain_interfaces
      INTEGER, ALLOCATABLE, INTENT(OUT) :: nodes(:)
      INTEGER, ALLOCATABLE :: tmp(:), subgroups(:)
      LOGICAL, ALLOCATABLE :: keep_node(:)
      INTEGER :: fine_node, count, seg_start, seg_end, nseg, ngroup, group
      INTEGER :: nparent, remaining, best_parent
      REAL(wp) :: score, best_score

      IF (SIZE(nodes_prev) == 0) THEN
        IF (contact_active) THEN
          CALL build_sequence_coarse_nodes(EA, EI, w, target_elements, retain_interfaces, nodes, &
                                           contact_diameter)
        ELSE
          CALL build_sequence_coarse_nodes(EA, EI, w, target_elements, retain_interfaces, nodes)
        END IF
        RETURN
      END IF
      ALLOCATE (tmp(nn))
      ALLOCATE (keep_node(nn))
      keep_node = .FALSE.
      keep_node(1) = .TRUE.
      keep_node(nn) = .TRUE.
      IF (SIZE(nodes_prev) > 0) THEN
        ! Refine the PREVIOUS partition itself. Building another independent
        ! globally-balanced grid and taking its union with nodes_prev can nearly
        ! double the element count (and defeats the bounded 3:2 growth contract).
        ! Subdividing each parent run keeps the hierarchy genuinely nested; the
        ! first level already carried every mandatory interface in the primary modes.
        nparent = SIZE(nodes_prev) - 1
        ALLOCATE (subgroups(nparent))
        subgroups = 1
        remaining = MIN(ne, MAX(target_elements, nparent)) - nparent
        ! Add one child at a time to the parent whose current largest child is
        ! longest in fine-element count. This integer apportionment reaches the
        ! requested GLOBAL count exactly; independently rounding every parent can
        ! turn a requested 3:2 level into a 2:1 jump when all quotas are near 1.5.
        DO WHILE (remaining > 0)
          best_parent = 0
          best_score = -CD_ONE
          DO group = 1, nparent
            nseg = nodes_prev(group + 1) - nodes_prev(group)
            IF (subgroups(group) >= nseg) CYCLE
            score = REAL(nseg, wp)/REAL(subgroups(group), wp)
            IF (score > best_score) THEN
              best_score = score
              best_parent = group
            END IF
          END DO
          IF (best_parent == 0) EXIT
          subgroups(best_parent) = subgroups(best_parent) + 1
          remaining = remaining - 1
        END DO
        DO group = 1, nparent
          seg_start = nodes_prev(group)
          seg_end = nodes_prev(group + 1)
          nseg = seg_end - seg_start
          ngroup = subgroups(group)
          DO fine_node = 0, ngroup
            ! 64-bit product: fine_node*nseg exceeds the default integer range on long meshes.
            keep_node(seg_start + INT((INT(fine_node, I8)*nseg + ngroup/2)/ngroup)) = .TRUE.
          END DO
        END DO
      END IF
      count = 0
      DO fine_node = 1, nn
        IF (.NOT. keep_node(fine_node)) CYCLE
        count = count + 1
        tmp(count) = fine_node
      END DO
      ALLOCATE (nodes(count))
      nodes = tmp(1:count)
    END SUBROUTINE level_nodes

    INTEGER FUNCTION node_pos(nodes, fine_node) RESULT(position)
      INTEGER, INTENT(IN) :: nodes(:), fine_node
      INTEGER :: lo, hi, mid
      position = 0
      lo = 1; hi = SIZE(nodes)
      DO WHILE (lo <= hi)
        mid = (lo + hi)/2
        IF (nodes(mid) == fine_node) THEN
          position = mid
          RETURN
        ELSE IF (nodes(mid) < fine_node) THEN
          lo = mid + 1
        ELSE
          hi = mid - 1
        END IF
      END DO
    END FUNCTION node_pos

    SUBROUTINE project_contact(q_seed, old_nodes, new_nodes, stat, msg)
      !! Project newly inserted refinement nodes out of the declared floor. Existing
      !! coarse nodes retain their equilibrium penalty penetration exactly.
      REAL(wp), INTENT(INOUT) :: q_seed(:)
      INTEGER, INTENT(IN) :: old_nodes(:), new_nodes(:)
      INTEGER, INTENT(OUT) :: stat
      CHARACTER(*), INTENT(OUT) :: msg
      INTEGER :: node, gi, bathy_stat
      REAL(wp) :: z_floor, xg, yg
      CHARACTER(1024) :: bathy_msg

      stat = CD_HCSTAT_OK
      msg = ''
      DO node = 1, SIZE(new_nodes)
        IF (node_pos(old_nodes, new_nodes(node)) > 0) CYCLE
        gi = 6*(node - 1) + 3
        z_floor = seabed_z
        IF (PRESENT(bathymetry)) THEN
          xg = contact_cs(1)*q_seed(gi - 2) - contact_cs(2)*q_seed(gi - 1)
          yg = contact_cs(2)*q_seed(gi - 2) + contact_cs(1)*q_seed(gi - 1)
          CALL CD_Bathymetry_Floor(bathymetry, xg, yg, z_floor, bathy_stat, bathy_msg)
          IF (bathy_stat /= CD_BATHY_OK) THEN
            stat = CD_HCSTAT_NOCONVERGE
            msg = 'bathymetry query failed: '//TRIM(bathy_msg)
            RETURN
          END IF
        END IF
        q_seed(gi) = MAX(q_seed(gi), z_floor)
      END DO
    END SUBROUTINE project_contact

    SUBROUTINE solve_level(n_cont_level, n_buoy_level, damping_level_in, use_backtracking_in, &
                           use_equilibration_in)
      INTEGER, INTENT(IN) :: n_cont_level, n_buoy_level
      REAL(wp), INTENT(IN), OPTIONAL :: damping_level_in
      LOGICAL, INTENT(IN), OPTIONAL :: use_backtracking_in
      LOGICAL, INTENT(IN), OPTIONAL :: use_equilibration_in
      REAL(wp) :: damping_level
      LOGICAL :: backtracking_level, equilibration_level
      damping_level = damping
      IF (PRESENT(damping_level_in)) damping_level = damping_level_in
      backtracking_level = .FALSE.
      IF (PRESENT(use_backtracking_in)) backtracking_level = use_backtracking_in
      equilibration_level = .FALSE.
      IF (PRESENT(use_equilibration_in)) equilibration_level = use_equilibration_in
      IF (.NOT. use_level_nodal_contact) THEN
        CALL CD_HermiteCable_Static_Solve(l0_l, EA_l, EI_l, w_l, seed_l, fx_l(1:nfx), &
                                          seabed_z, kn_level, n_cont_level, max_iter, tol, damping_level, &
                                          q_l, curv_l, res_l, iters_l, es, em_l, &
                                          residual_unmet=unmet_l, n_buoy_steps=n_buoy_level, &
                                          backtracking=backtracking_level, &
                                          equilibrate_linear_system=equilibration_level, &
                                          axial_quadrature_order=axial_quadrature_order, &
                                          bending_quadrature_order=bending_quadrature_order, &
                                          endconn_stiffness=endconn_stiffness, &
                                          endconn_direction=endconn_direction, endconn_mode=endconn_mode, &
                                          waterline_z=waterline_z, dry_buoyancy=dry_l, water_weight=water_weight, &
                                          current=current)
      ELSE IF (PRESENT(bathymetry)) THEN
        CALL CD_HermiteCable_Static_Solve(l0_l, EA_l, EI_l, w_l, seed_l, fx_l(1:nfx), &
                                          seabed_z, kn_level, n_cont_level, max_iter, tol, damping_level, &
                                          q_l, curv_l, res_l, iters_l, es, em_l, &
                                          residual_unmet=unmet_l, n_buoy_steps=n_buoy_level, contact_kn=contact_kn_l, &
                                          bathymetry=bathymetry, contact_frame_cs=contact_cs, &
                                          backtracking=backtracking_level, &
                                          equilibrate_linear_system=equilibration_level, &
                                          axial_quadrature_order=axial_quadrature_order, &
                                          bending_quadrature_order=bending_quadrature_order, &
                                          endconn_stiffness=endconn_stiffness, &
                                          endconn_direction=endconn_direction, endconn_mode=endconn_mode, &
                                          waterline_z=waterline_z, dry_buoyancy=dry_l, water_weight=water_weight, &
                                          current=current)
      ELSE
        CALL CD_HermiteCable_Static_Solve(l0_l, EA_l, EI_l, w_l, seed_l, fx_l(1:nfx), &
                                          seabed_z, kn_level, n_cont_level, max_iter, tol, damping_level, &
                                          q_l, curv_l, res_l, iters_l, es, em_l, &
                                          residual_unmet=unmet_l, n_buoy_steps=n_buoy_level, contact_kn=contact_kn_l, &
                                          contact_frame_cs=contact_cs, backtracking=backtracking_level, &
                                          equilibrate_linear_system=equilibration_level, &
                                          axial_quadrature_order=axial_quadrature_order, &
                                          bending_quadrature_order=bending_quadrature_order, &
                                          endconn_stiffness=endconn_stiffness, &
                                          endconn_direction=endconn_direction, endconn_mode=endconn_mode, &
                                          waterline_z=waterline_z, dry_buoyancy=dry_l, water_weight=water_weight, &
                                          current=current)
      END IF
    END SUBROUTINE solve_level

    SUBROUTINE fail_seq(msg)
      CHARACTER(*), INTENT(IN) :: msg
      ErrStat = CD_HCSTAT_BADINPUT
      ErrMsg = 'CD_HermiteCable_Static_Solve_Sequenced: '//msg
    END SUBROUTINE fail_seq

  END SUBROUTINE solve_seq_try

  SUBROUTINE reject_unresolved_sequence(l0, q, ErrStat, ErrMsg)
    !! Convert a residual-converged but element-localized fold into a diagnosed
    !! NOCONVERGE result. This gives the public sequence wrapper an opportunity to
    !! try an independent hierarchy and prevents a kinked branch from entering dynamics.
    REAL(wp), INTENT(IN) :: l0(:), q(:)
    INTEGER, INTENT(INOUT) :: ErrStat
    CHARACTER(*), INTENT(INOUT) :: ErrMsg
    INTEGER :: es, ne
    TYPE(CD_HermiteResolutionType) :: diag
    CHARACTER(1024) :: em

    IF (ErrStat /= CD_HCSTAT_OK) RETURN
    ne = SIZE(l0)
    IF (ne < 1 .OR. SIZE(q) /= 6*(ne + 1) .OR. .NOT. CD_All_Finite(q)) THEN
      ErrStat = CD_HCSTAT_NOCONVERGE
      ErrMsg = 'mesh-sequenced equilibrium produced an invalid state for curvature diagnosis'
      RETURN
    END IF
    ! Use the same adaptive interior-element curvature sampling as AutoMesh and
    ! the final deck gate. A cubic element can hide its peak between nodal stations;
    ! detecting it here lets the wrapper try its independent hierarchies first.
    CALL CD_HermiteCable_Resolution_Metrics(l0, q, -HUGE(CD_ONE), CD_ZERO, &
                                            CD_HC_KINK_LIMIT, diag, es, em)
    IF (es /= CD_HCSTAT_OK) THEN
      ErrStat = CD_HCSTAT_NOCONVERGE
      ErrMsg = 'mesh-sequenced curvature diagnosis failed: '//TRIM(em)
      RETURN
    END IF
    IF (diag%h_kappa_peak > CD_HC_KINK_LIMIT) THEN
      ErrStat = CD_HCSTAT_NOCONVERGE
      BLOCK
        ! Format into a local buffer: a record longer than the caller's ErrMsg
        ! must truncate, not abort the internal write.
        CHARACTER(1024) :: wbuf
        INTEGER :: wios
        wbuf = ''
        WRITE (wbuf, '(A,ES12.5,A,ES12.5,A,I0)', IOSTAT=wios) &
          'mesh-sequenced equilibrium is unresolved/kinked: max(h*kappa)=', diag%h_kappa_peak, &
          ' > safety limit=', CD_HC_KINK_LIMIT, ' at element ', diag%h_kappa_elem
        ErrMsg = TRIM(wbuf)//TRIM(CD_HermiteCable_Kink_Advice(diag%h_kappa_peak, diag%h_kappa_elem, SIZE(l0)))
      END BLOCK
    END IF
  END SUBROUTINE reject_unresolved_sequence

  PURE FUNCTION CD_HermiteCable_Kink_Advice(h_kappa, elem, n_elem, deck_ratio) RESULT(advice)
    !! The remedy of an unresolved/kinked refusal (max(h*kappa) = h_kappa above CD_HC_KINK_LIMIT
    !! at element elem of n_elem): on a resolved bend the curvature kappa does not change with the
    !! mesh, so h*kappa falls in proportion to the element length and a mesh n times finer there
    !! clears the limit for n >= h_kappa/CD_HC_KINK_LIMIT; deck_ratio (default 1) is the deck
    !! element's length over the solve element's (an automatically refined mesh), which the
    !! factor for NumSegs takes. A fold that stays kinked on the finer mesh is a non-physical
    !! branch, not a resolution limit. Starts with '; '.
    REAL(wp), INTENT(IN) :: h_kappa
    INTEGER, INTENT(IN) :: elem, n_elem
    REAL(wp), INTENT(IN), OPTIONAL :: deck_ratio
    CHARACTER(320) :: advice
    REAL(wp) :: f
    INTEGER :: n, ios
    f = h_kappa/CD_HC_KINK_LIMIT
    IF (PRESENT(deck_ratio)) f = f*MAX(CD_ONE, deck_ratio)
    IF (.NOT. (f < 1.0e6_wp)) f = 1.0e6_wp
    n = MAX(2, CEILING(f))
    advice = ''
    WRITE (advice, '(A,I0,A,I0,A,I0,A)', IOSTAT=ios) '; refine NumSegs at least ', n, 'x about element ', elem, &
      ' (of ', n_elem, ' in the solve): h*kappa falls in proportion to the element length on a resolved bend '// &
      '(a fold that stays kinked on the finer mesh is a non-physical branch)'
  END FUNCTION CD_HermiteCable_Kink_Advice

  PURE REAL(wp) FUNCTION CD_HermiteCable_Element_Ratio(l0_ref, l0_fin, elem) RESULT(ratio)
    !! The length of the element of the mesh l0_ref (the deck's) that holds the rest-arc midpoint
    !! of element elem of the mesh l0_fin (a refinement of it) over that element's length: the
    !! refinement already applied there (1 outside the meshes or for one mesh).
    REAL(wp), INTENT(IN) :: l0_ref(:), l0_fin(:)
    INTEGER, INTENT(IN) :: elem
    REAL(wp) :: s_mid, s_acc
    INTEGER :: k
    ratio = CD_ONE
    IF (elem < 1 .OR. elem > SIZE(l0_fin) .OR. SIZE(l0_ref) < 1) RETURN
    IF (.NOT. (l0_fin(elem) > CD_ZERO)) RETURN
    s_mid = SUM(l0_fin(1:elem - 1)) + 0.5_wp*l0_fin(elem)
    s_acc = CD_ZERO
    DO k = 1, SIZE(l0_ref)
      s_acc = s_acc + l0_ref(k)
      IF (s_mid <= s_acc .OR. k == SIZE(l0_ref)) THEN
        ratio = MAX(CD_ONE, l0_ref(k)/l0_fin(elem))
        RETURN
      END IF
    END DO
  END FUNCTION CD_HermiteCable_Element_Ratio

  SUBROUTINE CD_HermiteCable_Resolution_Metrics(l0, q, seabed_z, contact_band, &
                                                h_kappa_target, diag, ErrStat, ErrMsg, &
                                                bathymetry, contact_frame_cs, EA, EI, compression_mode, &
                                                elem_h_kappa, chatter_node, axial_offset)
    !! Diagnose the mesh resolution of a converged finite-EI static IC and recommend a global
    !! refinement factor. This is the preflight trigger for the adaptive mesh policy: a lazy-wave
    !! arch or touchdown transition resolved with too few elements carries a large h*kappa and
    !! stalls the subsequent dynamic Newton (the documented 200 m coarse-mesh failure).
    !!
    !! l0(ne)         : per-element rest length (the h in h*kappa).
    !! q(6*(ne+1))    : converged DOFs [r,m] per node. Element curvature is evaluated from these
    !!                  at interior stations; node z positions give the seabed-contact count.
    !! seabed_z       : seabed plane; contact_band (>= 0) : proximity band that counts a node as
    !!                  in seabed contact (a node z <= local floor + contact_band).
    !! bathymetry/contact_frame_cs (optional): use the same local structured floor and
    !!                  chord-to-global heading as the contact solve. Without bathymetry,
    !!                  the scalar seabed_z plane is used exactly as before.
    !! h_kappa_target : the resolution threshold (> 0); diag%rec_scale is the smallest power of
    !!                  two (capped at CD_HC_REFINE_CAP) that brings h_kappa_peak at or below it.
    !! compression_mode (optional, with EA): CD_HC_COMPRESSION_STRAIN (default),
    !!                  CD_HC_COMPRESSION_RELATIVE, CD_HC_COMPRESSION_STRICT or
    !!                  CD_HC_COMPRESSION_OSCILLATION; selects the
    !!                  element force tolerance of diag%axial_compression (see the constants).
    !!                  STRICT judges the three-element mean of the element-mean axial force
    !!                  (smoothed_element_means) instead of the pointwise resultant.
    !! elem_h_kappa(ne) (optional out): l0(e) * peak |kappa| of every element, the field whose
    !!                  maximum is h_kappa_peak (the local refinement of AutoMesh marks from it).
    !! chatter_node(ne+1) (optional out): every interior node whose contact state differs from
    !!                  both of its neighbours (the nodes behind diag%contact_chatter).
    !! axial_offset(ne) (optional, with EA): an axial force constant along each element added to
    !!                  its EA resultant wherever the axial force is judged, such as the
    !!                  (K/GJ) M_t of torque-tension coupling on a line restrained in torsion (EA
    !!                  then the kernel's EA - K^2/GJ).
    REAL(wp), INTENT(IN) :: l0(:), q(:), seabed_z, contact_band, h_kappa_target
    TYPE(CD_HermiteResolutionType), INTENT(OUT) :: diag
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    TYPE(CD_BathymetryType), INTENT(IN), OPTIONAL :: bathymetry
    REAL(wp), INTENT(IN), OPTIONAL :: contact_frame_cs(2)
    REAL(wp), INTENT(IN), OPTIONAL :: EA(:), EI(:)
    INTEGER, INTENT(IN), OPTIONAL :: compression_mode
    REAL(wp), INTENT(OUT), OPTIONAL :: elem_h_kappa(:)
    LOGICAL, INTENT(OUT), OPTIONAL :: chatter_node(:)
    REAL(wp), INTENT(IN), OPTIONAL :: axial_offset(:)

    INTEGER :: ne, nn, e, a, es3, mode
    REAL(wp) :: qe(12), ke, ke_prev, hk, u_peak, z, z_floor, xg, yg, contact_cs(2), &
                axial_element_min, axial_element_min_xi, axial_element_max, axial_element_max_xi, &
                axial_element_strain, tol_e, tol_rel, ratio
    REAL(wp), ALLOCATABLE :: elem_min(:), elem_min_xi(:), elem_max(:)
    CHARACTER(1024) :: em3
    LOGICAL, ALLOCATABLE :: contact_node(:)
    LOGICAL :: in_island, axial_strain_seen

    ErrStat = CD_HCSTAT_OK
    ErrMsg = ''
    diag = CD_HermiteResolutionType()
    contact_cs = [CD_ONE, CD_ZERO]
    axial_strain_seen = .FALSE.
    IF (PRESENT(contact_frame_cs)) contact_cs = contact_frame_cs
    mode = CD_HC_COMPRESSION_STRAIN
    IF (PRESENT(compression_mode)) mode = compression_mode

    ne = SIZE(l0)
    nn = ne + 1
    IF (ne < 1) THEN
      ErrStat = CD_HCSTAT_BADINPUT; ErrMsg = 'CD_HermiteCable_Resolution_Metrics: ne >= 1 required'; RETURN
    END IF
    IF (mode < CD_HC_COMPRESSION_STRAIN .OR. mode > CD_HC_COMPRESSION_OSCILLATION) THEN
      ErrStat = CD_HCSTAT_BADINPUT
      ErrMsg = 'CD_HermiteCable_Resolution_Metrics: unknown compression_mode'; RETURN
    END IF
    IF (SIZE(q) /= 6*nn) THEN
      ErrStat = CD_HCSTAT_BADINPUT
      ErrMsg = 'CD_HermiteCable_Resolution_Metrics: q must be 6*(ne+1)'; RETURN
    END IF
    IF (PRESENT(axial_offset)) THEN
      IF (SIZE(axial_offset) /= ne .OR. .NOT. PRESENT(EA)) THEN
        ErrStat = CD_HCSTAT_BADINPUT
        ErrMsg = 'CD_HermiteCable_Resolution_Metrics: axial_offset must be ne, with EA'; RETURN
      END IF
    END IF
    IF (PRESENT(elem_h_kappa)) THEN
      IF (SIZE(elem_h_kappa) /= ne) THEN
        ErrStat = CD_HCSTAT_BADINPUT
        ErrMsg = 'CD_HermiteCable_Resolution_Metrics: elem_h_kappa must have length ne'; RETURN
      END IF
      elem_h_kappa = CD_ZERO
    END IF
    IF (PRESENT(chatter_node)) THEN
      IF (SIZE(chatter_node) /= nn) THEN
        ErrStat = CD_HCSTAT_BADINPUT
        ErrMsg = 'CD_HermiteCable_Resolution_Metrics: chatter_node must have length ne+1'; RETURN
      END IF
      chatter_node = .FALSE.
    END IF
    IF (PRESENT(EA)) THEN
      IF (SIZE(EA) /= ne .OR. .NOT. CD_All_Finite(EA) .OR. ANY(EA < CD_ZERO)) THEN
        ErrStat = CD_HCSTAT_BADINPUT
        ErrMsg = 'CD_HermiteCable_Resolution_Metrics: EA must be finite, non-negative, and have length ne'
        RETURN
      END IF
      diag%axial_min = HUGE(CD_ONE)
      diag%axial_min_elem = 1
      diag%axial_strain_min = HUGE(CD_ONE)
      diag%axial_strain_min_elem = 1
      ! Treat strain-level excursions below two microstrain as the numerical zero
      ! band.  This is deliberately much smaller than any cable working strain, but
      ! avoids chasing the last sub-kilonewton oscillation with another global mesh
      ! doubling after the signed resultant has already converged by an order of
      ! magnitude. Each element is assessed against its own EA so a stiff section
      ! cannot conceal a strain-level excursion in an adjacent softer section.
    END IF
    IF (PRESENT(EI) .AND. .NOT. PRESENT(EA)) THEN
      ErrStat = CD_HCSTAT_BADINPUT
      ErrMsg = 'CD_HermiteCable_Resolution_Metrics: EI requires EA for the boundary screen'
      RETURN
    END IF
    IF (PRESENT(EI)) THEN
      IF (SIZE(EI) /= ne .OR. .NOT. CD_All_Finite(EI) .OR. ANY(EI < CD_ZERO)) THEN
        ErrStat = CD_HCSTAT_BADINPUT
        ErrMsg = 'CD_HermiteCable_Resolution_Metrics: EI must be finite, non-negative, and have length ne'
        RETURN
      END IF
    END IF
    IF (contact_band < CD_ZERO .OR. .NOT. CD_Is_Finite(contact_band) .OR. &
        .NOT. CD_Is_Finite(seabed_z) .OR. h_kappa_target <= CD_ZERO .OR. &
        .NOT. CD_Is_Finite(h_kappa_target)) THEN
      ErrStat = CD_HCSTAT_BADINPUT
      ErrMsg = 'CD_HermiteCable_Resolution_Metrics: need finite seabed_z, contact_band >= 0, h_kappa_target > 0'
      RETURN
    END IF
    IF (.NOT. CD_All_Finite(l0) .OR. .NOT. CD_All_Finite(q)) THEN
      ErrStat = CD_HCSTAT_BADINPUT; ErrMsg = 'CD_HermiteCable_Resolution_Metrics: inputs must be finite'; RETURN
    END IF
    ! Reject non-positive element lengths, as the Hermite static solvers do: l0 is the h in
    ! h*kappa, so a zero/negative length would silently report a zero/negative metric and pass a
    ! malformed mesh as not fragile.
    IF (ANY(l0 <= CD_ZERO)) THEN
      ErrStat = CD_HCSTAT_BADINPUT; ErrMsg = 'CD_HermiteCable_Resolution_Metrics: l0 > 0 required'; RETURN
    END IF
    IF (PRESENT(bathymetry)) THEN
      IF (.NOT. CD_Bathymetry_Is_Initialized(bathymetry)) THEN
        ErrStat = CD_HCSTAT_BADINPUT
        ErrMsg = 'CD_HermiteCable_Resolution_Metrics: bathymetry must be initialized'; RETURN
      END IF
    END IF
    IF (PRESENT(contact_frame_cs)) THEN
      IF (.NOT. CD_All_Finite(contact_frame_cs) .OR. &
          ABS(SUM(contact_frame_cs*contact_frame_cs) - CD_ONE) > 1.0e-9_wp) THEN
        ErrStat = CD_HCSTAT_BADINPUT
        ErrMsg = 'CD_HermiteCable_Resolution_Metrics: contact_frame_cs must be a finite unit heading'; RETURN
      END IF
    END IF

    ! Per-element PEAK curvature, sampled from the element DOFs across [0,1] by
    ! hermite_element_peak_curvature (a base grid refined adaptively where the curvature is
    ! non-smooth, so a narrow interior spike from a near-degenerate span is not stepped over).
    ! Nodal values alone are not enough: a cubic-Hermite element with opposed endpoint tangents
    ! can be nearly straight at its two nodes while bowing sharply in the interior. h*kappa,
    ! kappa_peak, and the curvature jump all use this per-element peak; curv_jump (largest
    ! element-to-element peak step) is accumulated in the same sweep.
    diag%h_kappa_peak = CD_ZERO
    diag%h_kappa_elem = 1
    diag%kappa_peak = CD_ZERO
    diag%curv_jump_peak = CD_ZERO
    ke_prev = CD_ZERO
    ALLOCATE (elem_min(ne), elem_min_xi(ne), elem_max(ne))
    elem_min = CD_ZERO; elem_min_xi = CD_ZERO; elem_max = CD_ZERO
    DO e = 1, ne
      qe(1:6) = q(6*(e - 1) + 1:6*(e - 1) + 6)
      qe(7:12) = q(6*e + 1:6*e + 6)
      CALL CD_HermiteCable_Peak_Curvature(qe, l0(e), ke, u_peak, es3, em3)
      IF (es3 /= CD_HCABLE_OK) THEN
        ErrStat = CD_HCSTAT_BADINPUT; ErrMsg = em3; RETURN
      END IF
      diag%kappa_peak = MAX(diag%kappa_peak, ke)
      hk = l0(e)*ke
      IF (PRESENT(elem_h_kappa)) elem_h_kappa(e) = hk
      IF (hk > diag%h_kappa_peak) THEN
        diag%h_kappa_peak = hk
        diag%h_kappa_elem = e
      END IF
      IF (e >= 2) diag%curv_jump_peak = MAX(diag%curv_jump_peak, ABS(ke - ke_prev))
      ke_prev = ke
      IF (PRESENT(EA)) THEN
        CALL CD_HermiteCable_Axial_Resultant_Range(qe, l0(e), EA(e), axial_element_min, &
                                                   axial_element_min_xi, axial_element_max, &
                                                   axial_element_max_xi, es3, em3)
        IF (es3 /= CD_HCABLE_OK) THEN
          ErrStat = CD_HCSTAT_BADINPUT
          ErrMsg = 'CD_HermiteCable_Resolution_Metrics: axial-resultant extraction failed: '//TRIM(em3)
          RETURN
        END IF
        IF (PRESENT(axial_offset)) THEN
          axial_element_min = axial_element_min + axial_offset(e)
          axial_element_max = axial_element_max + axial_offset(e)
        END IF
        elem_min(e) = axial_element_min
        elem_min_xi(e) = axial_element_min_xi
        elem_max(e) = axial_element_max
        IF (axial_element_min < diag%axial_min) THEN
          diag%axial_min = axial_element_min
          diag%axial_min_elem = e
          diag%axial_min_xi = axial_element_min_xi
        END IF
        IF (EA(e) > CD_ZERO) THEN
          axial_strain_seen = .TRUE.
          axial_element_strain = axial_element_min/EA(e)
          IF (axial_element_strain < diag%axial_strain_min) THEN
            diag%axial_strain_min = axial_element_strain
            diag%axial_strain_min_resultant = axial_element_min
            diag%axial_strain_min_elem = e
            diag%axial_strain_min_xi = axial_element_min_xi
            diag%axial_tolerance = CD_HC_AXIAL_STRAIN_TOL*EA(e)
          END IF
        END IF
      END IF
    END DO
    IF (PRESENT(EA)) THEN
      IF (.NOT. axial_strain_seen) diag%axial_strain_min = CD_ZERO
      IF (mode == CD_HC_COMPRESSION_STRAIN) THEN
        diag%axial_compression = diag%axial_strain_min < -CD_HC_AXIAL_STRAIN_TOL
        IF (axial_strain_seen) diag%axial_violation = -diag%axial_strain_min/CD_HC_AXIAL_STRAIN_TOL
      ELSE
        ! Tension-relative screen: report the element with the largest violation ratio.
        diag%axial_violation = -HUGE(CD_ONE)
        tol_rel = MAX(MERGE(CD_HC_OSCILLATION_REL_TOL, CD_HC_COMPRESSION_REL_TOL, &
                            mode == CD_HC_COMPRESSION_OSCILLATION)*MAX(MAXVAL(elem_max), CD_ZERO), &
                      CD_HC_AXIAL_ROUNDOFF*MAXVAL(EA))
        ! The strict screen (tensile_safety True) judges the three-element mean of the
        ! element-mean axial force (smoothed_element_means), the force in equilibrium, as the
        ! dynamic tensile audit does; the others judge the pointwise resultant, whose
        ! oscillation about that mean grows with the element length.
        IF (mode == CD_HC_COMPRESSION_STRICT) THEN
          CALL smoothed_element_means(l0, q, EA, elem_min, es3, em3, axial_offset)
          IF (es3 /= CD_HCSTAT_OK) THEN
            ErrStat = CD_HCSTAT_BADINPUT
            ErrMsg = 'CD_HermiteCable_Resolution_Metrics: '//TRIM(em3)
            RETURN
          END IF
        END IF
        DO e = 1, ne
          tol_e = tol_rel
          IF (mode == CD_HC_COMPRESSION_STRICT) tol_e = MIN(tol_e, CD_HC_AXIAL_STRAIN_TOL*EA(e))
          tol_e = MAX(tol_e, TINY(CD_ONE))
          ratio = -elem_min(e)/tol_e
          IF (ratio > diag%axial_violation) THEN
            diag%axial_violation = ratio
            diag%axial_strain_min_resultant = elem_min(e)
            diag%axial_strain_min_elem = e
            diag%axial_strain_min_xi = elem_min_xi(e)
            diag%axial_tolerance = tol_e
          END IF
        END DO
        diag%axial_compression = diag%axial_violation > CD_ONE
      END IF
    END IF

    ! Tension-controlled bending boundary layers have characteristic length
    ! sqrt(EI/T). The curvature screen above cannot detect an unresolved end layer
    ! when the global peak lies at a sag or hog bend. Evaluate the first and last
    ! element boundaries independently. A non-tensile or zero-EI boundary is not a
    ! tension-dominated bending layer and is therefore left at a zero ratio.
    IF (PRESENT(EI)) THEN
      qe(1:6) = q(1:6)
      qe(7:12) = q(7:12)
      CALL CD_HermiteCable_Axial_Resultant(qe, l0(1), EA(1), CD_ZERO, diag%hop_axial, es3, em3)
      IF (es3 /= CD_HCABLE_OK) THEN
        ErrStat = CD_HCSTAT_BADINPUT
        ErrMsg = 'CD_HermiteCable_Resolution_Metrics: HOP axial-resultant extraction failed: '//TRIM(em3)
        RETURN
      END IF
      qe(1:6) = q(6*(ne - 1) + 1:6*ne)
      qe(7:12) = q(6*ne + 1:6*(ne + 1))
      CALL CD_HermiteCable_Axial_Resultant(qe, l0(ne), EA(ne), CD_ONE, diag%end_axial, es3, em3)
      IF (es3 /= CD_HCABLE_OK) THEN
        ErrStat = CD_HCSTAT_BADINPUT
        ErrMsg = 'CD_HermiteCable_Resolution_Metrics: end axial-resultant extraction failed: '//TRIM(em3)
        RETURN
      END IF
      IF (PRESENT(axial_offset)) THEN
        diag%hop_axial = diag%hop_axial + axial_offset(1)
        diag%end_axial = diag%end_axial + axial_offset(ne)
      END IF
      IF (EI(1) > CD_ZERO .AND. diag%hop_axial > CD_HC_AXIAL_STRAIN_TOL*EA(1)) &
        diag%hop_boundary_ratio = l0(1)/SQRT(EI(1)/diag%hop_axial)
      IF (EI(ne) > CD_ZERO .AND. diag%end_axial > CD_HC_AXIAL_STRAIN_TOL*EA(ne)) &
        diag%end_boundary_ratio = l0(ne)/SQRT(EI(ne)/diag%end_axial)
      diag%boundary_ratio_peak = MAX(diag%hop_boundary_ratio, diag%end_boundary_ratio)
      diag%boundary_unresolved = &
        diag%boundary_ratio_peak > CD_HC_BOUNDARY_TARGET*(CD_ONE + 1.0e-10_wp)
    END IF

    ! Seabed-contact nodes and the number of contiguous contact runs (touchdown islands).
    ALLOCATE (contact_node(nn))
    contact_node = .FALSE.
    diag%n_contact = 0
    diag%n_islands = 0
    in_island = .FALSE.
    DO a = 1, nn
      z = q(6*(a - 1) + 3)
      z_floor = seabed_z
      IF (PRESENT(bathymetry)) THEN
        xg = contact_cs(1)*q(6*(a - 1) + 1) - contact_cs(2)*q(6*(a - 1) + 2)
        yg = contact_cs(2)*q(6*(a - 1) + 1) + contact_cs(1)*q(6*(a - 1) + 2)
        CALL CD_Bathymetry_Floor(bathymetry, xg, yg, z_floor, es3, em3)
        IF (es3 /= CD_BATHY_OK) THEN
          ErrStat = CD_HCSTAT_BADINPUT
          ErrMsg = 'CD_HermiteCable_Resolution_Metrics: bathymetry query failed: '//TRIM(em3); RETURN
        END IF
      END IF
      IF (z <= z_floor + contact_band) THEN
        contact_node(a) = .TRUE.
        diag%n_contact = diag%n_contact + 1
        IF (.NOT. in_island) THEN
          diag%n_islands = diag%n_islands + 1
          in_island = .TRUE.
        END IF
      ELSE
        in_island = .FALSE.
      END IF
    END DO

    ! More than one contact island is not intrinsically a discretisation defect: a
    ! non-monotone floor or separated heavy sections can produce several resolved
    ! grounded runs. Refine only a topology that changes over one interior node --
    ! either an isolated contact node or an isolated suspended gap. End nodes are
    ! excluded because a single supported anchor/fairlead node is a valid boundary
    ! condition. Curvature resolution remains an independent h*kappa requirement.
    diag%contact_chatter = .FALSE.
    DO a = 2, nn - 1
      IF ((contact_node(a) .NEQV. contact_node(a - 1)) .AND. &
          (contact_node(a) .NEQV. contact_node(a + 1))) THEN
        diag%contact_chatter = .TRUE.
        EXIT
      END IF
    END DO
    IF (PRESENT(chatter_node)) THEN
      DO a = 2, nn - 1
        chatter_node(a) = (contact_node(a) .NEQV. contact_node(a - 1)) .AND. &
                          (contact_node(a) .NEQV. contact_node(a + 1))
      END DO
    END IF

    ! Recommended global refinement: the smallest power-of-two factor that brings h_kappa_peak
    ! at or below the target, capped so a pathological IC cannot ask for an unbounded mesh.
    diag%rec_scale = 1
    DO WHILE ((diag%h_kappa_peak > h_kappa_target*diag%rec_scale .OR. &
               diag%boundary_ratio_peak > CD_HC_BOUNDARY_TARGET*diag%rec_scale*(CD_ONE + 1.0e-10_wp)) .AND. &
              diag%rec_scale < CD_HC_REFINE_CAP)
      diag%rec_scale = diag%rec_scale*2
    END DO

    diag%fragile = (diag%h_kappa_peak > h_kappa_target) .OR. diag%boundary_unresolved .OR. diag%contact_chatter
  END SUBROUTINE CD_HermiteCable_Resolution_Metrics

  SUBROUTINE CD_HermiteCable_Branch_Audit(l0, q, EA, audit, ErrStat, ErrMsg, end_zone, compression_allowance, &
                                          reject_compression, diameter)
    !! Physical-branch audit of a converged finite-EI static line. A residual-converged
    !! state is accepted as the physical equilibrium only if it passes every criterion:
    !!
    !!  1. No fold or loop. With the optional per-element diameter(ne) the test is
    !!     geometric self-contact: the line may not come closer to a non-neighbouring part
    !!     of itself than the sum of the two radii (hermite_self_contact) -- every loop of a
    !!     planar line crosses itself, and a fold lying on itself touches. The tangent
    !!     reversal below is then only reported. Without diameters the reversal decides.
    !!     Reversal: without horizontal external loads the horizontal component of
    !!     the internal force is one constant H along the line. For EI = 0 (H >= 0) the
    !!     tangent is parallel to the force, so the centreline advances monotonically
    !!     along the horizontal chord heading. Bending (shear, or a small compression H < 0
    !!     that the bending stiffness carries) can lean the tangent slightly past the
    !!     vertical, but a fold or loop turns it back against the heading: every closed
    !!     loop and every hairpin contains a tangent opposite to its travel. The unit
    !!     tangent is sampled at eight stations per element; the state fails when its
    !!     component against the horizontal chord heading exceeds sin(30 deg) anywhere
    !!     outside the optional end_zone(2) arc lengths [m] next to node 1 and node nn
    !!     (the boundary layers of rotationally restrained ends). The length travelled
    !!     against the heading is reported in audit%backtrack. The check is skipped for a
    !!     chord with no horizontal extent (any vertical plane contains it).
    !!  2. Compression (evaluated always, rejected only with reject_compression). The
    !!     element-mean axial force (three-point Gauss mean of the signed axial resultant,
    !!     the quantity that enters equilibrium; pointwise traces of a stiff-EA Hermite
    !!     element oscillate about it) is compared with -max(CD_HC_COMPRESSION_REL_TOL *
    !!     peak mean tension, compression_allowance, round-off). A bending-stiff line in a
    !!     STABLE equilibrium can carry some compression; whether a compressed state is a
    !!     buckled or strut branch is decided by the stability of the equilibrium, which
    !!     callers test separately, so by default the compression is only reported
    !!     (audit%compressed).
    !!  3. No element-localized fold: max(l0 * peak curvature) <= CD_HC_KINK_LIMIT.
    !!
    !! Node 1 is the anchor end and node nn the fairlead end; q is ordered like the solve.
    !! audit%axial_min/axial_max report the pointwise extremes; audit%mean_axial_min and
    !! audit%mean_axial_max the element means used by criterion 2.
    !! audit%smoothed_axial_min is the minimum over e of the length-weighted mean of the
    !! element means of e-1, e, e+1 (clipped at the line ends); audit%smoothed_compressed
    !! compares it with the same compression_limit. An isolated compressed element between
    !! tensile neighbours (a mesh-local kink, e.g. next to a nodal seabed-contact reaction)
    !! is excluded by it; a run of three or more compressed elements never is.
    !! audit%nodal_axial_min is the minimum over interior nodes of the length-weighted
    !! average of the two adjacent element means: the nodal material axial force (the node
    !! Tension output channel under OPTIONS OutputRecovery element).
    REAL(wp), INTENT(IN) :: l0(:), q(:), EA(:)
    TYPE(CD_HermiteBranchAuditType), INTENT(OUT) :: audit
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    REAL(wp), INTENT(IN), OPTIONAL :: end_zone(2), compression_allowance
    LOGICAL, INTENT(IN), OPTIONAL :: reject_compression
    REAL(wp), INTENT(IN), OPTIONAL :: diameter(:)

    INTEGER, PARAMETER :: NSAMPLE = 8
    REAL(wp), PARAMETER :: REVERSAL_LIMIT = 0.5_wp
    REAL(wp), PARAMETER :: G3X(3) = [0.5_wp - 0.5_wp*SQRT(0.6_wp), 0.5_wp, 0.5_wp + 0.5_wp*SQRT(0.6_wp)]
    REAL(wp), PARAMETER :: G3W(3) = [5.0_wp/18.0_wp, 8.0_wp/18.0_wp, 5.0_wp/18.0_wp]
    INTEGER :: ne, nn, e, k, es
    REAL(wp) :: qe(12), heading(2), hlen, total, zone(2), s0, s_mid, xi, x_prev, x_cur, back_e, back_max
    REAL(wp) :: H(4), dH(4), r(3), rp(3), ke, u_peak, nmin, nmax, umin, umax, ea_max, nmean, ng, allowance
    REAL(wp) :: reversal, emean(SIZE(l0)), sm, wl
    LOGICAL :: reject_c, folded
    CHARACTER(1024) :: em

    ErrStat = CD_HCSTAT_OK
    ErrMsg = ''
    audit = CD_HermiteBranchAuditType()
    ne = SIZE(l0)
    nn = ne + 1
    IF (ne < 1 .OR. SIZE(q) /= 6*nn .OR. SIZE(EA) /= ne) THEN
      ErrStat = CD_HCSTAT_BADINPUT
      ErrMsg = 'CD_HermiteCable_Branch_Audit: inconsistent array sizes'; RETURN
    END IF
    IF (.NOT. CD_All_Finite(q) .OR. .NOT. CD_All_Finite(l0) .OR. ANY(l0 <= CD_ZERO) .OR. &
        .NOT. CD_All_Finite(EA) .OR. ANY(EA < CD_ZERO)) THEN
      ErrStat = CD_HCSTAT_BADINPUT
      ErrMsg = 'CD_HermiteCable_Branch_Audit: inputs must be finite with l0 > 0 and EA >= 0'; RETURN
    END IF
    zone = CD_ZERO
    IF (PRESENT(end_zone)) zone = MAX(CD_ZERO, end_zone)
    allowance = CD_ZERO
    IF (PRESENT(compression_allowance)) allowance = MAX(CD_ZERO, compression_allowance)
    total = SUM(l0)
    back_max = CD_ZERO

    ! --- 1. backtracking against the horizontal chord heading ---
    heading = q(6*(nn - 1) + 1:6*(nn - 1) + 2) - q(1:2)
    hlen = NORM2(heading)
    audit%backtrack_limit = REVERSAL_LIMIT
    IF (hlen > 1.0e-6_wp*total) THEN
      audit%backtrack_checked = .TRUE.
      heading = heading/hlen
      s0 = CD_ZERO
      back_max = CD_ZERO
      DO e = 1, ne
        qe(1:6) = q(6*(e - 1) + 1:6*e)
        qe(7:12) = q(6*e + 1:6*(e + 1))
        x_prev = DOT_PRODUCT(qe(1:2), heading)
        back_e = CD_ZERO
        DO k = 1, NSAMPLE
          xi = REAL(k, wp)/REAL(NSAMPLE, wp)
          CALL CD_HermiteCable_Shapes(xi, l0(e), H, dH)
          r = H(1)*qe(1:3) + H(2)*qe(4:6) + H(3)*qe(7:9) + H(4)*qe(10:12)
          rp = dH(1)*qe(1:3) + dH(2)*qe(4:6) + dH(3)*qe(7:9) + dH(4)*qe(10:12)
          x_cur = DOT_PRODUCT(r(1:2), heading)
          s_mid = s0 + REAL(k, wp)/REAL(NSAMPLE, wp)*l0(e)
          IF (s_mid > zone(1) .AND. s_mid < total - zone(2)) THEN
            IF (x_cur < x_prev) back_e = back_e + (x_prev - x_cur)
            IF (NORM2(rp) > CD_ZERO) THEN
              reversal = -DOT_PRODUCT(rp(1:2), heading)/NORM2(rp)
              IF (reversal > back_max) THEN
                back_max = reversal
                audit%backtrack_elem = e
              END IF
            END IF
          END IF
          x_prev = x_cur
        END DO
        audit%backtrack = audit%backtrack + back_e
        s0 = s0 + l0(e)
      END DO
    END IF

    ! --- 2. compression beyond bending support and 3. element-localized folds ---
    audit%axial_min = HUGE(CD_ONE)
    audit%axial_max = -HUGE(CD_ONE)
    audit%mean_axial_min = HUGE(CD_ONE)
    audit%mean_axial_max = -HUGE(CD_ONE)
    audit%axial_min_elem = 1
    audit%h_kappa_elem = 1
    ea_max = MAXVAL(EA)
    DO e = 1, ne
      qe(1:6) = q(6*(e - 1) + 1:6*e)
      qe(7:12) = q(6*e + 1:6*(e + 1))
      CALL CD_HermiteCable_Axial_Resultant_Range(qe, l0(e), EA(e), nmin, umin, nmax, umax, es, em)
      IF (es /= CD_HCABLE_OK) THEN
        ErrStat = CD_HCSTAT_NOCONVERGE
        ErrMsg = 'CD_HermiteCable_Branch_Audit: '//TRIM(em); RETURN
      END IF
      audit%axial_min = MIN(audit%axial_min, nmin)
      audit%axial_max = MAX(audit%axial_max, nmax)
      nmean = CD_ZERO
      DO k = 1, 3
        CALL CD_HermiteCable_Axial_Resultant(qe, l0(e), EA(e), G3X(k), ng, es, em)
        IF (es /= CD_HCABLE_OK) THEN
          ErrStat = CD_HCSTAT_NOCONVERGE
          ErrMsg = 'CD_HermiteCable_Branch_Audit: '//TRIM(em); RETURN
        END IF
        nmean = nmean + G3W(k)*ng
      END DO
      emean(e) = nmean
      IF (nmean < audit%mean_axial_min) THEN
        audit%mean_axial_min = nmean
        audit%axial_min_elem = e
      END IF
      audit%mean_axial_max = MAX(audit%mean_axial_max, nmean)
      CALL CD_HermiteCable_Peak_Curvature(qe, l0(e), ke, u_peak, es, em)
      IF (es /= CD_HCABLE_OK) THEN
        ErrStat = CD_HCSTAT_NOCONVERGE
        ErrMsg = 'CD_HermiteCable_Branch_Audit: '//TRIM(em); RETURN
      END IF
      IF (l0(e)*ke > audit%h_kappa_peak) THEN
        audit%h_kappa_peak = l0(e)*ke
        audit%h_kappa_elem = e
      END IF
    END DO
    audit%compression_limit = MAX(CD_HC_COMPRESSION_REL_TOL*MAX(audit%mean_axial_max, CD_ZERO), allowance, &
                                  CD_HC_AXIAL_ROUNDOFF*ea_max)
    audit%smoothed_axial_min = HUGE(CD_ONE)
    audit%smoothed_min_elem = 1
    DO e = 1, ne
      k = MAX(1, e - 1)
      wl = SUM(l0(k:MIN(ne, e + 1)))
      sm = DOT_PRODUCT(l0(k:MIN(ne, e + 1)), emean(k:MIN(ne, e + 1)))/wl
      IF (sm < audit%smoothed_axial_min) THEN
        audit%smoothed_axial_min = sm
        audit%smoothed_min_elem = e
      END IF
    END DO
    audit%smoothed_compressed = audit%smoothed_axial_min < -audit%compression_limit
    audit%nodal_axial_min = HUGE(CD_ONE)
    audit%nodal_min_node = 1
    DO e = 2, ne
      sm = (l0(e - 1)*emean(e - 1) + l0(e)*emean(e))/(l0(e - 1) + l0(e))
      IF (sm < audit%nodal_axial_min) THEN
        audit%nodal_axial_min = sm
        audit%nodal_min_node = e
      END IF
    END DO
    IF (ne == 1) audit%nodal_axial_min = emean(1)

    IF (audit%backtrack_checked) audit%tangent_reversal = back_max
    audit%compressed = audit%mean_axial_min < -audit%compression_limit
    reject_c = .FALSE.
    IF (PRESENT(reject_compression)) reject_c = reject_compression
    folded = audit%backtrack_checked .AND. audit%tangent_reversal > REVERSAL_LIMIT
    IF (PRESENT(diameter)) THEN
      IF (SIZE(diameter) /= ne .OR. .NOT. CD_All_Finite(diameter) .OR. ANY(diameter <= CD_ZERO)) THEN
        ErrStat = CD_HCSTAT_BADINPUT
        ErrMsg = 'CD_HermiteCable_Branch_Audit: diameter must hold ne finite positive values'; RETURN
      END IF
      CALL hermite_self_contact(l0, q, diameter, NSAMPLE, folded, audit%self_gap, audit%contact_elem_a, &
                                audit%contact_elem_b)
      audit%self_contact_checked = .TRUE.
    END IF
    IF (folded) THEN
      audit%physical = .FALSE.
      audit%failed_check = CD_HC_AUDIT_BACKTRACK
    ELSE IF (reject_c .AND. audit%compressed) THEN
      audit%physical = .FALSE.
      audit%failed_check = CD_HC_AUDIT_COMPRESSION
    ELSE IF (audit%h_kappa_peak > CD_HC_KINK_LIMIT) THEN
      audit%physical = .FALSE.
      audit%failed_check = CD_HC_AUDIT_KINK
    END IF
  END SUBROUTINE CD_HermiteCable_Branch_Audit

  SUBROUTINE hermite_self_contact(l0, q, diameter, nsample, contact, gap_min, elem_a, elem_b)
    !! Smallest clearance between non-neighbouring parts of a Hermite centreline. The
    !! centreline is sampled at nsample stations per element into straight segments with
    !! the element's radius; two segments further apart along the line than pi times the
    !! sum of their radii plus their lengths (a cable cannot bend tighter than its own
    !! radius) are in self-contact when their distance is below the sum of their radii.
    !! A uniform spatial hash (cell size = longest segment + largest diameter, 27-cell
    !! neighbourhood) keeps the search linear in the number of segments.
    !! gap_min is the smallest (distance - radii) found among the admissible pairs, and
    !! elem_a/elem_b the elements carrying it.
    REAL(wp), INTENT(IN) :: l0(:), q(:), diameter(:)
    INTEGER, INTENT(IN) :: nsample
    LOGICAL, INTENT(OUT) :: contact
    REAL(wp), INTENT(OUT) :: gap_min
    INTEGER, INTENT(OUT) :: elem_a, elem_b
    INTEGER(I8), PARAMETER :: P1 = 73856093_I8, P2 = 19349663_I8, P3 = 83492791_I8
    INTEGER :: ne, np, ns, e, k, i, j, di, dj, dk, nt, b
    INTEGER(I8) :: cx, cy, cz
    REAL(wp) :: qe(12), H(4), dH(4), hc, sep, d, dmax, lmax
    REAL(wp), ALLOCATABLE :: p(:, :), rad(:), arc(:)
    INTEGER, ALLOCATABLE :: head(:), nxt(:), owner(:)
    INTEGER(I8), ALLOCATABLE :: cell(:, :)

    contact = .FALSE.
    gap_min = HUGE(CD_ONE)
    elem_a = 0
    elem_b = 0
    ne = SIZE(l0)
    np = ne*nsample + 1
    ns = np - 1
    ALLOCATE (p(3, np), rad(ns), arc(np), owner(ns))
    arc(1) = CD_ZERO
    p(:, 1) = q(1:3)
    DO e = 1, ne
      qe(1:6) = q(6*(e - 1) + 1:6*e)
      qe(7:12) = q(6*e + 1:6*(e + 1))
      DO k = 1, nsample
        i = (e - 1)*nsample + k
        CALL CD_HermiteCable_Shapes(REAL(k, wp)/REAL(nsample, wp), l0(e), H, dH)
        p(:, i + 1) = H(1)*qe(1:3) + H(2)*qe(4:6) + H(3)*qe(7:9) + H(4)*qe(10:12)
        rad(i) = 0.5_wp*diameter(e)
        owner(i) = e
        arc(i + 1) = arc(i) + l0(e)/REAL(nsample, wp)
      END DO
    END DO
    lmax = CD_ZERO
    DO i = 1, ns
      lmax = MAX(lmax, NORM2(p(:, i + 1) - p(:, i)))
    END DO
    dmax = 2.0_wp*MAXVAL(rad)
    hc = MAX(lmax + dmax, TINY(CD_ONE))
    nt = 2*ns + 1
    ALLOCATE (head(0:nt - 1), nxt(ns), cell(3, ns))
    head = 0
    DO i = 1, ns
      cell(:, i) = FLOOR(0.5_wp*(p(:, i) + p(:, i + 1))/hc, I8)
      b = bucket(cell(1, i), cell(2, i), cell(3, i))
      nxt(i) = head(b)
      head(b) = i
    END DO
    DO i = 1, ns
      DO di = -1, 1
        DO dj = -1, 1
          DO dk = -1, 1
            cx = cell(1, i) + di; cy = cell(2, i) + dj; cz = cell(3, i) + dk
            j = head(bucket(cx, cy, cz))
            DO WHILE (j > 0)
              IF (j > i .AND. cell(1, j) == cx .AND. cell(2, j) == cy .AND. cell(3, j) == cz) THEN
                sep = arc(j) - arc(i + 1)
                IF (sep > ACOS(-CD_ONE)*(rad(i) + rad(j))) THEN
                  d = segment_distance(p(:, i), p(:, i + 1), p(:, j), p(:, j + 1)) - rad(i) - rad(j)
                  IF (d < gap_min) THEN
                    gap_min = d
                    elem_a = owner(i)
                    elem_b = owner(j)
                  END IF
                END IF
              END IF
              j = nxt(j)
            END DO
          END DO
        END DO
      END DO
    END DO
    contact = gap_min < CD_ZERO

  CONTAINS

    INTEGER FUNCTION bucket(ax, ay, az)
      INTEGER(I8), INTENT(IN) :: ax, ay, az
      bucket = INT(MODULO(IEOR(IEOR(ax*P1, ay*P2), az*P3), INT(nt, I8)))
    END FUNCTION bucket

  END SUBROUTINE hermite_self_contact

  PURE REAL(wp) FUNCTION segment_distance(a0, a1, b0, b1) RESULT(dist)
    !! Distance between the segments [a0,a1] and [b0,b1] (closest points, clamped).
    REAL(wp), INTENT(IN) :: a0(3), a1(3), b0(3), b1(3)
    REAL(wp) :: u(3), v(3), w0(3), a, b, c, d, e, den, sc, tc
    u = a1 - a0
    v = b1 - b0
    w0 = a0 - b0
    a = DOT_PRODUCT(u, u)
    b = DOT_PRODUCT(u, v)
    c = DOT_PRODUCT(v, v)
    d = DOT_PRODUCT(u, w0)
    e = DOT_PRODUCT(v, w0)
    den = a*c - b*b
    IF (a <= TINY(CD_ONE) .AND. c <= TINY(CD_ONE)) THEN
      dist = NORM2(w0)
      RETURN
    END IF
    IF (a <= TINY(CD_ONE)) THEN
      sc = CD_ZERO
      tc = MIN(CD_ONE, MAX(CD_ZERO, e/c))
    ELSE IF (c <= TINY(CD_ONE)) THEN
      tc = CD_ZERO
      sc = MIN(CD_ONE, MAX(CD_ZERO, -d/a))
    ELSE
      IF (den > 1.0e-14_wp*a*c) THEN
        sc = MIN(CD_ONE, MAX(CD_ZERO, (b*e - c*d)/den))
      ELSE
        sc = CD_ZERO
      END IF
      tc = (b*sc + e)/c
      IF (tc < CD_ZERO) THEN
        tc = CD_ZERO
        sc = MIN(CD_ONE, MAX(CD_ZERO, -d/a))
      ELSE IF (tc > CD_ONE) THEN
        tc = CD_ONE
        sc = MIN(CD_ONE, MAX(CD_ZERO, (b - d)/a))
      END IF
    END IF
    dist = NORM2(w0 + sc*u - tc*v)
  END FUNCTION segment_distance

  SUBROUTINE CD_HermiteCable_Refine_Mesh(l0, q, fixed_dofs, scale, &
                                         l0_ref, q_ref, fixed_ref, ErrStat, ErrMsg, inherit_dofs)
    !! Refine a Hermite line state by a power-of-two global factor. Element rest lengths are
    !! split equally and the new nodal state is cubic-Hermite prolongated from the parent state.
    !! Constraints are rebuilt on the refined mesh: original nodes keep their constraints, and an
    !! inserted node inherits only caller-declared all-node reduction DOF slots (inherit_dofs)
    !! that both neighbouring parent nodes had constrained. Endpoint pins therefore never create
    !! artificial interior pins by inference; callers that know a slot is a global reduction
    !! (for example planar y / m_y) must say so explicitly.
    REAL(wp), INTENT(IN) :: l0(:), q(:)
    INTEGER, INTENT(IN) :: fixed_dofs(:), scale
    REAL(wp), ALLOCATABLE, INTENT(OUT) :: l0_ref(:), q_ref(:)
    INTEGER, ALLOCATABLE, INTENT(OUT) :: fixed_ref(:)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    INTEGER, INTENT(IN), OPTIONAL :: inherit_dofs(:)

    INTEGER :: ne, nn, sc, e, a, slot, nfx, parent_l, parent_r, old_node, k
    REAL(wp), ALLOCATABLE :: l0_cur(:), q_cur(:), l0_next(:), q_next(:)
    INTEGER, ALLOCATABLE :: fixed_tmp(:)
    LOGICAL, ALLOCATABLE :: fixed_map(:, :)
    LOGICAL :: inherit_slot(6)

    ErrStat = CD_HCSTAT_OK
    ErrMsg = ''

    ne = SIZE(l0)
    nn = ne + 1
    IF (ne < 1) THEN
      CALL fail_ref('ne >= 1 required'); RETURN
    END IF
    IF (SIZE(q) /= 6*nn) THEN
      CALL fail_ref('q must be 6*(ne+1)'); RETURN
    END IF
    IF (scale < 1 .OR. scale > CD_HC_REFINE_CAP .OR. .NOT. is_power_of_two(scale)) THEN
      CALL fail_ref('scale must be a power of two between 1 and CD_HC_REFINE_CAP'); RETURN
    END IF
    IF (SIZE(fixed_dofs) > 0) THEN
      IF (ANY(fixed_dofs < 1) .OR. ANY(fixed_dofs > 6*nn)) THEN
        CALL fail_ref('fixed_dofs out of range'); RETURN
      END IF
    END IF
    IF (.NOT. CD_All_Finite(l0) .OR. .NOT. CD_All_Finite(q)) THEN
      CALL fail_ref('inputs must be finite'); RETURN
    END IF
    IF (ANY(l0 <= CD_ZERO)) THEN
      CALL fail_ref('l0 > 0 required'); RETURN
    END IF
    inherit_slot = .FALSE.
    IF (PRESENT(inherit_dofs)) THEN
      DO k = 1, SIZE(inherit_dofs)
        IF (inherit_dofs(k) < 1 .OR. inherit_dofs(k) > 6) THEN
          CALL fail_ref('inherit_dofs entries must be node DOF slots 1..6'); RETURN
        END IF
        inherit_slot(inherit_dofs(k)) = .TRUE.
      END DO
    END IF

    ALLOCATE (l0_cur(ne), q_cur(6*nn))
    l0_cur = l0
    q_cur = q
    sc = 1
    DO WHILE (sc < scale)
      ALLOCATE (l0_next(2*SIZE(l0_cur)), q_next(6*(2*SIZE(l0_cur) + 1)))
      DO e = 1, SIZE(l0_cur)
        l0_next(2*e - 1) = 0.5_wp*l0_cur(e)
        l0_next(2*e) = 0.5_wp*l0_cur(e)
      END DO
      CALL hermite_prolongate(q_cur, l0_cur, l0_next, q_next)
      CALL MOVE_ALLOC(l0_next, l0_cur)
      CALL MOVE_ALLOC(q_next, q_cur)
      sc = 2*sc
    END DO
    CALL MOVE_ALLOC(l0_cur, l0_ref)
    CALL MOVE_ALLOC(q_cur, q_ref)

    ALLOCATE (fixed_map(6, nn))
    fixed_map = .FALSE.
    DO e = 1, SIZE(fixed_dofs)
      old_node = (fixed_dofs(e) - 1)/6 + 1
      slot = MOD(fixed_dofs(e) - 1, 6) + 1
      fixed_map(slot, old_node) = .TRUE.
    END DO

    ALLOCATE (fixed_tmp(6*(ne*scale + 1)))
    nfx = 0
    DO a = 1, ne*scale + 1
      IF (MOD(a - 1, scale) == 0) THEN
        old_node = (a - 1)/scale + 1
        DO slot = 1, 6
          IF (fixed_map(slot, old_node)) CALL push_fixed(a, slot)
        END DO
      ELSE
        parent_l = (a - 1)/scale + 1
        parent_r = parent_l + 1
        DO slot = 1, 6
          IF (inherit_slot(slot) .AND. fixed_map(slot, parent_l) .AND. fixed_map(slot, parent_r)) THEN
            CALL push_fixed(a, slot)
          END IF
        END DO
      END IF
    END DO
    ALLOCATE (fixed_ref(nfx))
    IF (nfx > 0) fixed_ref = fixed_tmp(1:nfx)

  CONTAINS

    LOGICAL PURE FUNCTION is_power_of_two(n)
      INTEGER, INTENT(IN) :: n
      INTEGER :: m
      IF (n < 1) THEN
        is_power_of_two = .FALSE.
        RETURN
      END IF
      m = n
      DO WHILE (MOD(m, 2) == 0)
        m = m/2
      END DO
      is_power_of_two = (m == 1)
    END FUNCTION is_power_of_two

    SUBROUTINE push_fixed(node, dof_slot)
      INTEGER, INTENT(IN) :: node, dof_slot
      nfx = nfx + 1
      fixed_tmp(nfx) = 6*(node - 1) + dof_slot
    END SUBROUTINE push_fixed

    SUBROUTINE fail_ref(msg)
      CHARACTER(*), INTENT(IN) :: msg
      ErrStat = CD_HCSTAT_BADINPUT
      ErrMsg = 'CD_HermiteCable_Refine_Mesh: '//msg
    END SUBROUTINE fail_ref

  END SUBROUTINE CD_HermiteCable_Refine_Mesh

  SUBROUTINE smoothed_element_means(l0, q, EA, sm, ErrStat, ErrMsg, axial_offset)
    !! Three-element mean of the element-mean axial force: sm(e) is the length-weighted
    !! mean, over elements e-1, e, e+1 (clipped at the line ends), of the three-point Gauss
    !! mean of the signed axial resultant EA (|r'| - 1) -- the force that enters equilibrium,
    !! free of the pointwise oscillation of a stiff-EA cubic-Hermite element (per element,
    !! the smoothed_axial_min of CD_HermiteCable_Branch_Audit) -- plus axial_offset(e) where
    !! given (the coupling force of CD_HermiteCable_Resolution_Metrics).
    REAL(wp), INTENT(IN) :: l0(:), q(:), EA(:)
    REAL(wp), INTENT(OUT) :: sm(:)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    REAL(wp), INTENT(IN), OPTIONAL :: axial_offset(:)
    REAL(wp), PARAMETER :: GX(3) = [0.5_wp - 0.5_wp*SQRT(0.6_wp), 0.5_wp, 0.5_wp + 0.5_wp*SQRT(0.6_wp)]
    REAL(wp), PARAMETER :: GW(3) = [5.0_wp/18.0_wp, 8.0_wp/18.0_wp, 5.0_wp/18.0_wp]
    REAL(wp) :: emean(SIZE(l0)), ng
    INTEGER :: e, k, ne, lo, hi
    ErrStat = CD_HCSTAT_OK
    ErrMsg = ''
    ne = SIZE(l0)
    DO e = 1, ne
      emean(e) = CD_ZERO
      DO k = 1, 3
        CALL CD_HermiteCable_Axial_Resultant(q(6*(e - 1) + 1:6*(e + 1)), l0(e), EA(e), GX(k), ng, ErrStat, ErrMsg)
        IF (ErrStat /= CD_HCABLE_OK) THEN
          ErrStat = CD_HCSTAT_NOCONVERGE; RETURN
        END IF
        emean(e) = emean(e) + GW(k)*ng
      END DO
      IF (PRESENT(axial_offset)) emean(e) = emean(e) + axial_offset(e)
    END DO
    ErrStat = CD_HCSTAT_OK
    DO e = 1, ne
      lo = MAX(1, e - 1)
      hi = MIN(ne, e + 1)
      sm(e) = DOT_PRODUCT(l0(lo:hi), emean(lo:hi))/SUM(l0(lo:hi))
    END DO
  END SUBROUTINE smoothed_element_means

  SUBROUTINE compressive_refinement_marks(l0, q, EA, marks, ErrStat, ErrMsg, compression_mode)
    !! Mark every element whose continuous signed axial resultant is below the
    !! numerical zero band, together with one neighbour on either side. (The strict screen of
    !! CD_HermiteCable_Resolution_Metrics decides on the element means whether to refine;
    !! the split follows the pointwise dips, where the element means err.)  The halo
    !! prevents a new child-size jump from being placed directly at the oscillation.
    !! compression_mode selects the band as in CD_HermiteCable_Resolution_Metrics.
    REAL(wp), INTENT(IN) :: l0(:), q(:), EA(:)
    LOGICAL, INTENT(OUT) :: marks(:)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    INTEGER, INTENT(IN) :: compression_mode
    INTEGER :: e, es
    REAL(wp) :: qe(12), nmin, xmin, nmax, xmax, tol_rel, tol_e
    REAL(wp), ALLOCATABLE :: elem_min(:)
    LOGICAL, ALLOCATABLE :: raw(:)
    CHARACTER(1024) :: em

    ErrStat = CD_HCSTAT_OK; ErrMsg = ''
    IF (SIZE(l0) < 1 .OR. SIZE(EA) /= SIZE(l0) .OR. SIZE(q) /= 6*(SIZE(l0) + 1)) THEN
      ErrStat = CD_HCSTAT_BADINPUT
      ErrMsg = 'compressive_refinement_marks: inconsistent array sizes'; RETURN
    END IF
    ALLOCATE (raw(SIZE(l0)), elem_min(SIZE(l0)))
    raw = .FALSE.; marks = .FALSE.
    tol_rel = -HUGE(CD_ONE)
    DO e = 1, SIZE(l0)
      qe(1:6) = q(6*(e - 1) + 1:6*e)
      qe(7:12) = q(6*e + 1:6*(e + 1))
      CALL CD_HermiteCable_Axial_Resultant_Range(qe, l0(e), EA(e), nmin, xmin, nmax, xmax, es, em)
      IF (es /= CD_HCABLE_OK) THEN
        ErrStat = CD_HCSTAT_BADINPUT
        ErrMsg = 'compressive_refinement_marks: '//TRIM(em); RETURN
      END IF
      elem_min(e) = nmin
      tol_rel = MAX(tol_rel, nmax)
    END DO

    tol_rel = MAX(MERGE(CD_HC_OSCILLATION_REL_TOL, CD_HC_COMPRESSION_REL_TOL, &
                        compression_mode == CD_HC_COMPRESSION_OSCILLATION)*MAX(tol_rel, CD_ZERO), &
                  CD_HC_AXIAL_ROUNDOFF*MAXVAL(EA))
    DO e = 1, SIZE(l0)
      SELECT CASE (compression_mode)
      CASE (CD_HC_COMPRESSION_RELATIVE, CD_HC_COMPRESSION_OSCILLATION)
        tol_e = tol_rel
      CASE (CD_HC_COMPRESSION_STRICT)
        tol_e = MIN(tol_rel, CD_HC_AXIAL_STRAIN_TOL*EA(e))
      CASE DEFAULT
        tol_e = CD_HC_AXIAL_STRAIN_TOL*EA(e)
      END SELECT
      raw(e) = elem_min(e) < -tol_e
    END DO
    DO e = 1, SIZE(l0)
      IF (.NOT. raw(e)) CYCLE
      marks(MAX(1, e - 1):MIN(SIZE(l0), e + 1)) = .TRUE.
    END DO
    IF (.NOT. ANY(marks)) THEN
      ErrStat = CD_HCSTAT_BADINPUT
      ErrMsg = 'compressive_refinement_marks: compression flag had no marked element'
    END IF
  END SUBROUTINE compressive_refinement_marks

  SUBROUTINE refine_marked_elements(l0, q, fixed_dofs, marks, l0_ref, q_ref, fixed_ref, &
                                    parent_ref, ErrStat, ErrMsg, inherit_dofs)
    !! Bisect selected Hermite elements.  The prolongated centreline is identical
    !! before the subsequent equilibrium polish.  Original nodal constraints are
    !! retained and new nodes inherit only explicitly declared all-node DOF slots.
    REAL(wp), INTENT(IN) :: l0(:), q(:)
    INTEGER, INTENT(IN) :: fixed_dofs(:)
    LOGICAL, INTENT(IN) :: marks(:)
    REAL(wp), ALLOCATABLE, INTENT(OUT) :: l0_ref(:), q_ref(:)
    INTEGER, ALLOCATABLE, INTENT(OUT) :: fixed_ref(:), parent_ref(:)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    INTEGER, INTENT(IN), OPTIONAL :: inherit_dofs(:)
    INTEGER :: ne, nn, nref, e, j, node_new, node_old, slot, k, nfx
    INTEGER, ALLOCATABLE :: fixed_tmp(:)
    LOGICAL, ALLOCATABLE :: fixed_map(:, :)
    LOGICAL :: inherit_slot(6)
    REAL(wp) :: r1(3), r2(3), m1(3), m2(3), midpoint_r(3), midpoint_m(3), L

    ErrStat = CD_HCSTAT_OK; ErrMsg = ''
    ne = SIZE(l0); nn = ne + 1
    IF (ne < 1 .OR. SIZE(q) /= 6*nn .OR. SIZE(marks) /= ne) THEN
      CALL fail_local('invalid l0/q/marks arrays'); RETURN
    END IF
    IF (.NOT. ANY(marks)) THEN
      CALL fail_local('at least one element must be marked'); RETURN
    END IF
    IF (ANY(l0 <= CD_ZERO) .OR. .NOT. CD_All_Finite(l0) .OR. .NOT. CD_All_Finite(q)) THEN
      CALL fail_local('l0 and q must be finite, with l0 > 0'); RETURN
    END IF
    IF (SIZE(fixed_dofs) > 0) THEN
      IF (ANY(fixed_dofs < 1) .OR. ANY(fixed_dofs > 6*nn)) THEN
        CALL fail_local('fixed_dofs out of range'); RETURN
      END IF
    END IF

    inherit_slot = .FALSE.
    IF (PRESENT(inherit_dofs)) THEN
      DO k = 1, SIZE(inherit_dofs)
        IF (inherit_dofs(k) < 1 .OR. inherit_dofs(k) > 6) THEN
          CALL fail_local('inherit_dofs entries must be node DOF slots 1..6'); RETURN
        END IF
        inherit_slot(inherit_dofs(k)) = .TRUE.
      END DO
    END IF

    nref = ne + COUNT(marks)
    ALLOCATE (l0_ref(nref), q_ref(6*(nref + 1)), parent_ref(nref))
    j = 0
    DO e = 1, ne
      IF (marks(e)) THEN
        j = j + 1; l0_ref(j) = 0.5_wp*l0(e); parent_ref(j) = e
        j = j + 1; l0_ref(j) = 0.5_wp*l0(e); parent_ref(j) = e
      ELSE
        j = j + 1; l0_ref(j) = l0(e); parent_ref(j) = e
      END IF
    END DO
    node_new = 1
    q_ref(1:6) = q(1:6)
    DO e = 1, ne
      IF (marks(e)) THEN
        r1 = q(6*(e - 1) + 1:6*(e - 1) + 3)
        m1 = q(6*(e - 1) + 4:6*(e - 1) + 6)
        r2 = q(6*e + 1:6*e + 3)
        m2 = q(6*e + 4:6*e + 6)
        L = l0(e)
        midpoint_r = 0.5_wp*(r1 + r2) + 0.125_wp*L*(m1 - m2)
        midpoint_m = 1.5_wp*(r2 - r1)/L - 0.25_wp*(m1 + m2)
        node_new = node_new + 1
        q_ref(6*(node_new - 1) + 1:6*(node_new - 1) + 3) = midpoint_r
        q_ref(6*(node_new - 1) + 4:6*(node_new - 1) + 6) = midpoint_m
      END IF
      node_new = node_new + 1
      q_ref(6*(node_new - 1) + 1:6*node_new) = q(6*e + 1:6*(e + 1))
    END DO

    ALLOCATE (fixed_map(6, nn), fixed_tmp(6*(nref + 1)))
    fixed_map = .FALSE.; nfx = 0
    DO k = 1, SIZE(fixed_dofs)
      node_old = (fixed_dofs(k) - 1)/6 + 1
      slot = MOD(fixed_dofs(k) - 1, 6) + 1
      fixed_map(slot, node_old) = .TRUE.
    END DO
    node_new = 1
    CALL copy_old_constraints(1, node_new)
    DO e = 1, ne
      IF (marks(e)) THEN
        node_new = node_new + 1
        DO slot = 1, 6
          IF (inherit_slot(slot) .AND. fixed_map(slot, e) .AND. fixed_map(slot, e + 1)) &
            CALL push_fixed(node_new, slot)
        END DO
      END IF
      node_new = node_new + 1
      CALL copy_old_constraints(e + 1, node_new)
    END DO
    ALLOCATE (fixed_ref(nfx))
    IF (nfx > 0) fixed_ref = fixed_tmp(1:nfx)

  CONTAINS
    SUBROUTINE copy_old_constraints(old_node, new_node)
      INTEGER, INTENT(IN) :: old_node, new_node
      INTEGER :: s
      DO s = 1, 6
        IF (fixed_map(s, old_node)) CALL push_fixed(new_node, s)
      END DO
    END SUBROUTINE copy_old_constraints

    SUBROUTINE push_fixed(node, dof_slot)
      INTEGER, INTENT(IN) :: node, dof_slot
      nfx = nfx + 1
      fixed_tmp(nfx) = 6*(node - 1) + dof_slot
    END SUBROUTINE push_fixed

    SUBROUTINE fail_local(msg)
      CHARACTER(*), INTENT(IN) :: msg
      ErrStat = CD_HCSTAT_BADINPUT
      ErrMsg = 'refine_marked_elements: '//TRIM(msg)
    END SUBROUTINE fail_local
  END SUBROUTINE refine_marked_elements

  SUBROUTINE CD_HermiteCable_Static_Solve_AutoMesh(l0, EA, EI, w, seed, fixed_dofs, seabed_z, kn, &
                                                   n_cont, max_iter, tol, damping, h_kappa_target, &
                                                   contact_band, max_scale, inherit_dofs, &
                                                   l0_out, EA_out, EI_out, w_out, q_out, curv_out, &
                                                   fixed_out, applied_scale, diag_out, res_out, &
                                                   iters_out, ErrStat, ErrMsg, contact_diameter, contact_kbot, &
                                                   bathymetry, contact_frame_cs, initial_polish, require_resolved, &
                                                   axial_quadrature_order, bending_quadrature_order, &
                                                   require_tensile, refine_non_axial, endconn_stiffness, &
                                                   endconn_direction, endconn_mode, waterline_z, dry_buoyancy, &
                                                   compression_mode, energy_polish_in, tensile_advisory, water_weight, &
                                                   current, local_refinement, max_elements)
    !! Solve the finite-EI static equilibrium and AUTOMATICALLY select the minimum safe mesh: the
    !! metric-gated mesh-economics entry. Solve at the caller's (coarse) mesh; if
    !! CD_HermiteCable_Resolution_Metrics flags it fragile, refine by the recommended power-of-two
    !! factor -- cubic-Hermite prolongation of the converged IC (CD_HermiteCable_Refine_Mesh),
    !! per-element property replication (a split child inherits its parent's per-length EA/EI/w),
    !! and constraint rebuild -- then re-solve (full-load polish, n_cont = n_buoy_steps = 1) and
    !! re-diagnose, until the
    !! mesh is not fragile or the cumulative factor reaches max_scale. A mesh that is already
    !! resolved is returned UNCHANGED (applied_scale = 1, no over-refinement). Start coarse, pay
    !! only for the resolution the geometry needs.
    !!
    !! inherit_dofs : node DOF slots (1..6) that an inserted node inherits when both parent
    !!                neighbours are constrained (e.g. [2,5] for a planar y / m_y reduction);
    !!                mirrors CD_HermiteCable_Refine_Mesh. max_scale : cumulative power-of-two cap
    !!                (>= 1); pass 1 to disable refinement (a plain solve + diagnosis).
    !! Outputs the (possibly refined) mesh in the allocatable *_out arrays, the applied cumulative
    !! refinement factor, and the final resolution diagnosis.
    !! initial_polish (optional, default false): the supplied seed is an already
    !!                converged full-load equilibrium. Re-establish equilibrium
    !!                with one full-load stage (EI and buoyancy) before diagnosis
    !!                instead of replaying either cold-seed continuation.
    !! require_resolved (optional, default false): return NOCONVERGE if max_scale is
    !!                exhausted while h*kappa or mesh-scale contact chatter remains fragile. The
    !!                production adaptive-mesh route enables this fail-closed contract;
    !!                direct diagnostic callers receive the capped result.
    !! waterline_z/dry_buoyancy (optional, together): free surface and per-element
    !!                displaced-water buoyancy of CD_HermiteCable_Static_Solve on the caller
    !!                mesh; a split child inherits its parent's value.
    !! compression_mode (optional): compression screen of the tensile refinement
    !!                (CD_HC_COMPRESSION_*; default CD_HC_COMPRESSION_STRAIN).
    !! tensile_advisory (optional, default false): with require_tensile, refine locally as
    !!                usual but return the best state instead of NOCONVERGE when the
    !!                compression screen cannot be met (an accuracy measure, not a gate).
    !! energy_polish_in (optional, default false): polish the initial state and every
    !!                prolongated refinement with the trust-region energy minimization of
    !!                CD_HermiteCable_Static_Solve instead of the damped Newton update.
    !! max_elements (optional): a lower element limit than AUTO_MAX_ELEMENTS (8192), the most
    !!                elements a refinement may produce; values outside [1, 8192] use 8192. It lets
    !!                a test reach the limit on a small, well-conditioned line.
    !! local_refinement (optional, default false): refine for the curvature, end boundary-layer
    !!                and contact-topology screens element by element instead of globally. A
    !!                pass runs when the same screens fail as for the global refinement; it
    !!                splits into the power-of-two number of equal children that meets its
    !!                criterion every element whose h*kappa exceeds min(h_kappa_target,
    !!                CD_HC_HKAPPA_TARGET), every element longer than half its bending length
    !!                (EI/|w|)^(1/3), each end element for its boundary-layer ratio, and the
    !!                elements about an isolated contact or gap node once (local_resolution_mesh);
    !!                the neighbours are then split until the mesh is graded (grade). Every
    !!                element keeps the cumulative cap max_scale relative to its caller element,
    !!                the mesh keeps the element limit of the global refinement, and the split
    !!                elements are cubic-Hermite prolongated exactly as there. The pass repeats
    !!                on the re-solved state while a screen fails and an element can still be
    !!                split. applied_scale then reports the largest factor of any element. The
    !!                axial (tensile) refinement is local in either mode and unchanged.
    REAL(wp), INTENT(IN) :: l0(:), EA(:), EI(:), w(:), seed(:)
    INTEGER, INTENT(IN) :: fixed_dofs(:)
    REAL(wp), INTENT(IN) :: seabed_z, kn, tol, damping, h_kappa_target, contact_band
    INTEGER, INTENT(IN) :: n_cont, max_iter, max_scale, inherit_dofs(:)
    REAL(wp), ALLOCATABLE, INTENT(OUT) :: l0_out(:), EA_out(:), EI_out(:), w_out(:), q_out(:), curv_out(:)
    INTEGER, ALLOCATABLE, INTENT(OUT) :: fixed_out(:)
    INTEGER, INTENT(OUT) :: applied_scale, iters_out
    TYPE(CD_HermiteResolutionType), INTENT(OUT) :: diag_out
    REAL(wp), INTENT(OUT) :: res_out
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    REAL(wp), INTENT(IN), OPTIONAL :: contact_diameter(:), contact_kbot, contact_frame_cs(2)
    TYPE(CD_BathymetryType), INTENT(IN), OPTIONAL :: bathymetry
    LOGICAL, INTENT(IN), OPTIONAL :: initial_polish, require_resolved
    INTEGER, INTENT(IN), OPTIONAL :: axial_quadrature_order, bending_quadrature_order
    LOGICAL, INTENT(IN), OPTIONAL :: require_tensile, refine_non_axial
    REAL(wp), INTENT(IN), OPTIONAL :: endconn_stiffness(2), endconn_direction(3, 2)
    INTEGER, INTENT(IN), OPTIONAL :: endconn_mode(2)
    REAL(wp), INTENT(IN), OPTIONAL :: waterline_z, dry_buoyancy(:), water_weight
    TYPE(CD_HermiteStaticCurrentType), INTENT(IN), OPTIONAL :: current
    INTEGER, INTENT(IN), OPTIONAL :: compression_mode
    LOGICAL, INTENT(IN), OPTIONAL :: energy_polish_in, tensile_advisory, local_refinement
    INTEGER, INTENT(IN), OPTIONAL :: max_elements

    INTEGER :: ne, nn, it, scale, parent, j, es, axial_order, bending_order, local_passes, cmode
    LOGICAL :: energy_polish, advisory
    INTEGER, PARAMETER :: MAX_LOCAL_AXIAL_PASSES = 16
    ! Local resolution refinement (local_refinement): passes, the per-element level cap
    ! (log2 of max_scale), every element's number of bisections from its caller element,
    ! and the per-element h*kappa and isolated contact/gap nodes of the last diagnosis.
    INTEGER, PARAMETER :: MAX_LOCAL_RESOLUTION_PASSES = 12
    LOGICAL :: local_mode, nothing_to_split
    INTEGER :: kcap, local_res_passes, element_limit
    ! What stopped the local refinement short of its targets, other than the per-element cap.
    CHARACTER(160) :: local_stop
    INTEGER, ALLOCATABLE :: level_out(:), level_r(:)
    REAL(wp), ALLOCATABLE :: elem_hk(:)
    LOGICAL, ALLOCATABLE :: chatter_nodes(:)
    REAL(wp), ALLOCATABLE :: l0r(:), qr(:), EAr(:), EIr(:), wr(:), qnew(:), curvnew(:)
    REAL(wp), ALLOCATABLE :: contact_diam_out(:), contact_diam_r(:)
    ! Current-mesh dry buoyancy; unallocated (an absent optional) without a free surface.
    REAL(wp), ALLOCATABLE :: dry_out(:), dry_r(:)
    INTEGER, ALLOCATABLE :: fixedr(:), parent_map(:)
    LOGICAL, ALLOCATABLE :: axial_marks(:)
    CHARACTER(LEN(ErrMsg)) :: emloc
    LOGICAL :: contact_active, polish_initial, must_resolve, must_be_tensile, refine_other
    LOGICAL :: needs_refinement, local_axial, in_drag
    REAL(wp) :: contact_cs(2)
    ! Local axial refinement guards: an element budget and a no-progress stop, so a
    ! genuinely compressive equilibrium cannot grow the mesh geometrically.
    ! Passes without progress before the local axial refinement stops: the element-mean screen of
    ! tensile_safety True (CD_HC_COMPRESSION_STRICT) can hold for a pass while the split elements
    ! move toward the compression, so it is given two more.
    INTEGER :: max_axial_stall_passes
    INTEGER, PARAMETER :: AXIAL_BUDGET_FLOOR = 2048
    INTEGER :: axial_budget, axial_stall, axial_flat, wios
    ! A violation within this share of the previous pass's is flat: refinement does not move it.
    REAL(wp), PARAMETER :: AXIAL_FLAT_REL = 1.0e-3_wp
    REAL(wp) :: axial_prev, end_res_prev
    LOGICAL :: end_min, end_prev, end_settled
    CHARACTER(400) :: axial_stop
    CHARACTER(1024) :: wbuf

    ErrStat = CD_HCSTAT_OK
    ErrMsg = ''
    applied_scale = 1
    local_passes = 0
    axial_stall = 0
    axial_flat = 0
    axial_prev = CD_ZERO
    end_prev = .FALSE.
    end_res_prev = CD_ZERO
    axial_stop = ''
    iters_out = 0
    res_out = CD_ZERO
    contact_active = PRESENT(contact_diameter) .AND. PRESENT(contact_kbot)
    polish_initial = .FALSE.
    IF (PRESENT(initial_polish)) polish_initial = initial_polish
    must_resolve = .FALSE.
    IF (PRESENT(require_resolved)) must_resolve = require_resolved
    must_be_tensile = .FALSE.
    IF (PRESENT(require_tensile)) must_be_tensile = require_tensile
    refine_other = .TRUE.
    IF (PRESENT(refine_non_axial)) refine_other = refine_non_axial
    axial_order = 4
    bending_order = 4
    IF (PRESENT(axial_quadrature_order)) axial_order = axial_quadrature_order
    IF (PRESENT(bending_quadrature_order)) bending_order = bending_quadrature_order
    contact_cs = [CD_ONE, CD_ZERO]
    IF (PRESENT(contact_frame_cs)) contact_cs = contact_frame_cs
    cmode = CD_HC_COMPRESSION_STRAIN
    IF (PRESENT(compression_mode)) cmode = compression_mode
    max_axial_stall_passes = MERGE(4, 2, cmode == CD_HC_COMPRESSION_STRICT)
    energy_polish = .FALSE.
    IF (PRESENT(energy_polish_in)) energy_polish = energy_polish_in
    local_mode = .FALSE.
    IF (PRESENT(local_refinement)) local_mode = local_refinement
    element_limit = AUTO_MAX_ELEMENTS
    IF (PRESENT(max_elements)) THEN
      IF (max_elements >= 1 .AND. max_elements < AUTO_MAX_ELEMENTS) element_limit = max_elements
    END IF
    local_res_passes = 0
    local_stop = ''

    IF (max_scale < 1) THEN
      ErrStat = CD_HCSTAT_BADINPUT; ErrMsg = 'CD_HermiteCable_Static_Solve_AutoMesh: max_scale >= 1 required'; RETURN
    END IF
    IF (axial_order < 1 .OR. axial_order > 6 .OR. bending_order < 1 .OR. bending_order > 6) THEN
      ErrStat = CD_HCSTAT_BADINPUT
      ErrMsg = 'CD_HermiteCable_Static_Solve_AutoMesh: quadrature orders must lie in [1,6]'; RETURN
    END IF
    IF (PRESENT(contact_diameter) .NEQV. PRESENT(contact_kbot)) THEN
      ErrStat = CD_HCSTAT_BADINPUT
      ErrMsg = 'CD_HermiteCable_Static_Solve_AutoMesh: contact_diameter and contact_kbot must be supplied together'
      RETURN
    END IF
    IF (PRESENT(bathymetry) .AND. .NOT. contact_active) THEN
      ErrStat = CD_HCSTAT_BADINPUT
      ErrMsg = 'CD_HermiteCable_Static_Solve_AutoMesh: bathymetry requires nodal contact inputs'
      RETURN
    END IF
    IF (PRESENT(endconn_stiffness) .NEQV. PRESENT(endconn_direction)) THEN
      ErrStat = CD_HCSTAT_BADINPUT
      ErrMsg = 'CD_HermiteCable_Static_Solve_AutoMesh: end-connection arguments must be supplied together'
      RETURN
    END IF

    ! Validate the property/seed array sizes BEFORE the whole-array copies below: this wrapper
    ! allocates its outputs from SIZE(l0), so a mismatched EA/EI/w/seed would hit a non-conforming
    ! array assignment (a bounds error / undefined behaviour) before CD_HermiteCable_Static_Solve
    ! could reject it. Mirror the inner solver's own l0/EA/EI/w/seed checks so this fail-closed
    ! entry returns CD_HCSTAT_BADINPUT cleanly instead.
    ne = SIZE(l0)
    nn = ne + 1
    IF (ne < 1 .OR. SIZE(EA) /= ne .OR. SIZE(EI) /= ne .OR. SIZE(w) /= ne .OR. SIZE(seed) /= 6*nn) THEN
      ErrStat = CD_HCSTAT_BADINPUT
      ErrMsg = 'CD_HermiteCable_Static_Solve_AutoMesh: l0/EA/EI/w/seed sizes inconsistent'; RETURN
    END IF
    kcap = 0
    DO WHILE (2_I8**(kcap + 1) <= INT(max_scale, I8))
      kcap = kcap + 1
    END DO
    ALLOCATE (level_out(ne))
    level_out = 0
    axial_budget = MAX(max_scale, CD_HC_REFINE_CAP)
    IF (axial_budget > HUGE(axial_budget)/ne) THEN
      axial_budget = HUGE(axial_budget)
    ELSE
      ! A very coarse caller mesh keeps an absolute floor of refinable elements.
      axial_budget = MAX(axial_budget*ne, AXIAL_BUDGET_FLOOR)
    END IF
    IF (contact_active) THEN
      IF (SIZE(contact_diameter) /= ne .OR. .NOT. CD_All_Finite(contact_diameter) .OR. &
          ANY(contact_diameter <= CD_ZERO) .OR. .NOT. CD_Is_Finite(contact_kbot) .OR. contact_kbot <= CD_ZERO) THEN
        ErrStat = CD_HCSTAT_BADINPUT
        ErrMsg = 'CD_HermiteCable_Static_Solve_AutoMesh: invalid contact diameter/kBot inputs'; RETURN
      END IF
      ALLOCATE (contact_diam_out(ne))
      contact_diam_out = contact_diameter
    END IF
    IF (PRESENT(waterline_z) .NEQV. PRESENT(dry_buoyancy)) THEN
      ErrStat = CD_HCSTAT_BADINPUT
      ErrMsg = 'CD_HermiteCable_Static_Solve_AutoMesh: waterline_z and dry_buoyancy must be supplied together'
      RETURN
    END IF
    IF (PRESENT(dry_buoyancy)) THEN
      IF (SIZE(dry_buoyancy) /= ne) THEN
        ErrStat = CD_HCSTAT_BADINPUT
        ErrMsg = 'CD_HermiteCable_Static_Solve_AutoMesh: dry_buoyancy must have length ne'; RETURN
      END IF
      ALLOCATE (dry_out(ne))
      dry_out = dry_buoyancy
    END IF

    ! Solve at the caller's mesh.
    ALLOCATE (l0_out(ne), EA_out(ne), EI_out(ne), w_out(ne), q_out(6*nn), curv_out(nn))
    l0_out = l0; EA_out = EA; EI_out = EI; w_out = w
    ALLOCATE (fixed_out(SIZE(fixed_dofs)))
    fixed_out = fixed_dofs
    CALL solve_level(l0_out, EA_out, EI_out, w_out, seed, fixed_out, contact_diam_out, dry_out, &
                     q_out, curv_out, res_out, it, es, ErrMsg, polish_initial)
    iters_out = iters_out + it
    IF (es /= CD_HCSTAT_OK) THEN
      ErrStat = es; RETURN
    END IF

    ! Diagnose; refine and re-solve while fragile and under the cap.
    CALL diagnose(es)
    IF (es /= CD_HCSTAT_OK) THEN
      ErrStat = es; RETURN
    END IF

    needs_refinement = (must_be_tensile .AND. diag_out%axial_compression) .OR. &
                       (refine_other .AND. refinable(diag_out))
    local_axial = must_be_tensile .AND. diag_out%axial_compression .AND. &
                  .NOT. (refine_other .AND. refinable(diag_out))
    end_prev = local_axial .AND. ((diag_out%axial_strain_min_elem == 1 .AND. &
                                   diag_out%axial_strain_min_xi <= 1.0e-6_wp) .OR. &
                                  (diag_out%axial_strain_min_elem == SIZE(l0_out) .AND. &
                                   diag_out%axial_strain_min_xi >= CD_ONE - 1.0e-6_wp))
    end_res_prev = diag_out%axial_strain_min_resultant
    ! A local resolution pass runs while an element can still be split (local_resolution_mesh
    ! says when none can), at most MAX_LOCAL_RESOLUTION_PASSES times, and in the local mode an
    ! axial pass at most MAX_LOCAL_AXIAL_PASSES times (applied_scale, the largest factor of
    ! any element there, need not grow with every pass); the global passes, and the axial
    ! passes of the global mode, keep their cumulative-factor bound.
    DO WHILE (needs_refinement .AND. &
              ((local_axial .AND. local_passes < MAX_LOCAL_AXIAL_PASSES) .OR. &
               (.NOT. local_mode .AND. applied_scale < max_scale) .OR. &
               (.NOT. local_axial .AND. local_mode .AND. kcap > 0 .AND. &
                local_res_passes < MAX_LOCAL_RESOLUTION_PASSES)))
      ! A signed axial oscillation is local, usually at a section interface or the
      ! touchdown transition.  Split every offending element and its immediate
      ! neighbours rather than multiplying the whole installed line.  Curvature or
      ! contact-topology fragility still uses the established global power-of-two mesh.
      local_axial = must_be_tensile .AND. diag_out%axial_compression .AND. &
                    .NOT. (refine_other .AND. refinable(diag_out))
      IF (local_axial) THEN
        local_passes = local_passes + 1
        axial_prev = diag_out%axial_violation
        IF (ALLOCATED(axial_marks)) DEALLOCATE (axial_marks)
        ALLOCATE (axial_marks(SIZE(l0_out)))
        CALL compressive_refinement_marks(l0_out, q_out, EA_out, axial_marks, es, emloc, cmode)
        IF (es == CD_HCSTAT_OK) &
          CALL refine_marked_elements(l0_out, q_out, fixed_out, axial_marks, l0r, qr, fixedr, &
                                      parent_map, es, emloc, inherit_dofs)
        IF (es == CD_HCSTAT_OK) THEN
          IF (SIZE(l0r) > axial_budget) THEN
            WRITE (axial_stop, '(A,I0,A)', IOSTAT=wios) 'the element budget (', axial_budget, ') was reached'
            EXIT
          END IF
        END IF
        scale = 2
        IF (es == CD_HCSTAT_OK) THEN
          ALLOCATE (level_r(SIZE(l0r)))
          DO j = 1, SIZE(l0r)
            level_r(j) = level_out(parent_map(j)) + MERGE(1, 0, axial_marks(parent_map(j)))
          END DO
        END IF
      ELSE IF (local_mode) THEN
        ! Split the elements whose screen fails, graded into their neighbours.
        local_res_passes = local_res_passes + 1
        CALL local_resolution_mesh(nothing_to_split, es, emloc)
        IF (es == CD_HCSTAT_OK .AND. nothing_to_split) EXIT
        scale = 2
      ELSE
        ! Mesh-scale contact chatter can report rec_scale = 1 (a topology signal), so
        ! force at least one doubling; never exceed the cumulative cap.
        scale = MAX(2, diag_out%rec_scale)
        DO WHILE ((applied_scale*scale > max_scale .OR. SIZE(l0_out)*scale > element_limit) .AND. scale > 1)
          scale = scale/2
        END DO
        IF (scale < 2) EXIT
        CALL CD_HermiteCable_Refine_Mesh(l0_out, q_out, fixed_out, scale, l0r, qr, fixedr, es, emloc, &
                                         inherit_dofs=inherit_dofs)
        IF (es == CD_HCSTAT_OK) THEN
          ALLOCATE (parent_map(SIZE(l0r)), level_r(SIZE(l0r)))
          DO j = 1, SIZE(l0r)
            parent_map(j) = (j - 1)/scale + 1
            level_r(j) = level_out(parent_map(j)) + NINT(LOG(REAL(scale, wp))/LOG(2.0_wp))
          END DO
        END IF
      END IF
      IF (es /= CD_HCSTAT_OK) THEN
        ErrStat = es; ErrMsg = 'CD_HermiteCable_Static_Solve_AutoMesh: '//TRIM(emloc); RETURN
      END IF

      ! Replicate per-element properties: each split child inherits its parent element's per-length
      ! EA/EI/w (splitting an element does not change its section).
      ALLOCATE (EAr(SIZE(l0r)), EIr(SIZE(l0r)), wr(SIZE(l0r)))
      IF (contact_active) ALLOCATE (contact_diam_r(SIZE(l0r)))
      IF (ALLOCATED(dry_out)) ALLOCATE (dry_r(SIZE(l0r)))
      DO j = 1, SIZE(l0r)
        parent = parent_map(j)
        EAr(j) = EA_out(parent); EIr(j) = EI_out(parent); wr(j) = w_out(parent)
        IF (contact_active) contact_diam_r(j) = contact_diam_out(parent)
        IF (ALLOCATED(dry_out)) dry_r(j) = dry_out(parent)
      END DO
      DEALLOCATE (parent_map)
      IF (ALLOCATED(axial_marks)) DEALLOCATE (axial_marks)

      ! A cubic between two grounded nodes sags below the floor, so a node inserted there
      ! would start deep inside the penalty. Lift a node of the prolongated state only
      ! where it penetrates deeper than any node of the converged parent state (the
      ! parent nodes keep their equilibrium penetration exactly).
      IF (contact_active) THEN
        CALL lift_to_floor(qr, max_penetration(q_out), es, emloc)
        IF (es /= CD_HCSTAT_OK) THEN
          ErrStat = es; ErrMsg = 'CD_HermiteCable_Static_Solve_AutoMesh: '//TRIM(emloc); RETURN
        END IF
      END IF
      ! Re-solve on the refined mesh, polishing the prolongated IC (qr) at full load
      ! (n_buoy_steps = 1). qr is the seed (INTENT IN); qnew/curvnew take the output.
      ALLOCATE (qnew(SIZE(qr)), curvnew(SIZE(l0r) + 1))
      CALL solve_level(l0r, EAr, EIr, wr, qr, fixedr, contact_diam_r, dry_r, &
                       qnew, curvnew, res_out, it, es, emloc, .TRUE.)
      iters_out = iters_out + it
      ! (a still-water carrier of the as-laid friction is no current here)
      in_drag = .FALSE.
      IF (PRESENT(current)) in_drag = current_has_drag(current)
      IF (es /= CD_HCSTAT_OK .AND. local_axial .AND. .NOT. in_drag) THEN
        ! The tensile refinement of a compressive state could not be carried further: the
        ! last converged (parent-mesh) state keeps its compression, which is what the
        ! tensile contract rejects below (or returns, when advisory).
        WRITE (axial_stop, '(A)', IOSTAT=wios) 'a refined-mesh polish did not converge: '//TRIM(emloc)
        EXIT
      END IF
      IF (es /= CD_HCSTAT_OK) THEN
        ! Diagnosed on the last converged (parent-mesh) state, not on the unconverged iterate.
        IF (PRESENT(current)) THEN
          IF (current_has_drag(current)) &
            emloc = TRIM(current_compression_note(l0_out, EA_out, q_out, seabed_z,.NOT. PRESENT(bathymetry), &
                                                  ALLOCATED(current%friction), EI=EI_out, w=w_out))//TRIM(emloc)
        END IF
        ErrStat = es; ErrMsg = 'CD_HermiteCable_Static_Solve_AutoMesh: refined-mesh polish failed: '//TRIM(emloc)
        RETURN
      END IF

      ! Commit the refined mesh + solution.
      CALL MOVE_ALLOC(l0r, l0_out)
      CALL MOVE_ALLOC(EAr, EA_out)
      CALL MOVE_ALLOC(EIr, EI_out)
      CALL MOVE_ALLOC(wr, w_out)
      IF (contact_active) CALL MOVE_ALLOC(contact_diam_r, contact_diam_out)
      IF (ALLOCATED(dry_r)) CALL MOVE_ALLOC(dry_r, dry_out)
      CALL MOVE_ALLOC(fixedr, fixed_out)
      CALL MOVE_ALLOC(qnew, q_out)
      CALL MOVE_ALLOC(curvnew, curv_out)
      DEALLOCATE (qr)
      CALL MOVE_ALLOC(level_r, level_out)
      IF (local_mode) THEN
        ! The largest factor of any element from its caller element (an axial pass splits
        ! only the marked elements, so it raises the factor of those alone).
        applied_scale = MAX(applied_scale, MIN(max_scale, 2**MIN(MAXVAL(level_out), 30)))
      ELSE IF (local_axial) THEN
        applied_scale = MIN(max_scale, applied_scale*scale)
      ELSE
        applied_scale = applied_scale*scale
      END IF

      CALL diagnose(es)
      IF (es /= CD_HCSTAT_OK) THEN
        ErrStat = es; RETURN
      END IF
      ! A local axial pass must raise the minimum axial strain; a compressive
      ! equilibrium that refinement does not relieve stops here and fails closed below.
      ! A compression at a held end node (the end reaction pushing on the line) is a nodal
      ! equilibrium quantity that no refinement changes: once two passes place it there at
      ! the same value, the refinement stops.
      end_min = diag_out%axial_strain_min_elem == 1 .AND. diag_out%axial_strain_min_xi <= 1.0e-6_wp
      end_min = end_min .OR. (diag_out%axial_strain_min_elem == SIZE(l0_out) .AND. &
                              diag_out%axial_strain_min_xi >= CD_ONE - 1.0e-6_wp)
      end_settled = local_axial .AND. end_min .AND. end_prev .AND. &
                    ABS(diag_out%axial_strain_min_resultant - end_res_prev) <= &
                    1.0e-2_wp*ABS(end_res_prev)
      end_prev = local_axial .AND. end_min
      end_res_prev = diag_out%axial_strain_min_resultant
      IF (local_axial) THEN
        IF (diag_out%axial_violation < axial_prev) THEN
          axial_stall = 0
        ELSE
          axial_stall = axial_stall + 1
        END IF
        ! A compression that two successive passes leave where it was (to 0.1 %) is the
        ! equilibrium's, not the mesh's: splitting the elements around it further only grows
        ! the mesh to its budget. (A mesh compression falls as its elements are split.)
        IF (ABS(diag_out%axial_violation - axial_prev) <= AXIAL_FLAT_REL*axial_prev) THEN
          axial_flat = axial_flat + 1
        ELSE
          axial_flat = 0
        END IF
      END IF
      needs_refinement = (must_be_tensile .AND. diag_out%axial_compression) .OR. &
                         (refine_other .AND. refinable(diag_out))
      local_axial = must_be_tensile .AND. diag_out%axial_compression .AND. &
                    .NOT. (refine_other .AND. refinable(diag_out))
      IF (needs_refinement .AND. local_axial .AND. axial_stall >= max_axial_stall_passes) THEN
        axial_stop = 'the minimum axial strain stopped improving'
        EXIT
      END IF
      IF (needs_refinement .AND. local_axial .AND. axial_flat >= 2) THEN
        axial_stop = 'two passes left the compression where it was: it is the equilibrium''s, not the mesh''s'
        EXIT
      END IF
      IF (needs_refinement .AND. local_axial .AND. end_settled) THEN
        axial_stop = 'the compression is the reaction of a held end, which refinement does not change'
        EXIT
      END IF
    END DO
    ! In the local mode, name a pass limit that stopped the refinement (the element limit is
    ! named by local_resolution_mesh; a refinement that stops at the per-element cap keeps
    ! the cap wording below).
    IF (local_mode .AND. LEN_TRIM(local_stop) == 0 .AND. local_res_passes >= MAX_LOCAL_RESOLUTION_PASSES) &
      WRITE (local_stop, '(A,I0,A)', IOSTAT=wios) 'the limit of ', MAX_LOCAL_RESOLUTION_PASSES, &
      ' refinement passes was reached'
    IF (local_mode .AND. LEN_TRIM(axial_stop) == 0 .AND. local_passes >= MAX_LOCAL_AXIAL_PASSES) &
      WRITE (axial_stop, '(A,I0,A)', IOSTAT=wios) 'the limit of ', MAX_LOCAL_AXIAL_PASSES, ' passes was reached'

    ! A residual-converged, element-localized fold is not a usable equilibrium.
    ! Enforce this numerical-safety bound for every AutoMesh caller, including
    ! direct API users that retain the compatibility default require_resolved=.FALSE.
    ! The stricter accuracy/topology policy below remains opt-in.
    IF (diag_out%h_kappa_peak > CD_HC_KINK_LIMIT) THEN
      ErrStat = CD_HCSTAT_NOCONVERGE
      ! Every diagnostic below is formatted into a local buffer: a record longer than
      ! the caller's ErrMsg must truncate, not abort the internal write.
      wbuf = ''
      WRITE (wbuf, '(A,ES12.5,A,ES12.5,A,I0)', IOSTAT=wios) &
        'CD_HermiteCable_Static_Solve_AutoMesh: unresolved/kinked equilibrium: max(h*kappa)=', &
        diag_out%h_kappa_peak, ' > safety limit=', CD_HC_KINK_LIMIT, &
        ' at element ', diag_out%h_kappa_elem
      IF (LEN_TRIM(local_stop) > 0) wbuf = TRIM(wbuf)//' (local refinement stopped: '//TRIM(local_stop)//')'
      BLOCK
        REAL(wp) :: deck_ratio
        deck_ratio = CD_HermiteCable_Element_Ratio(l0, l0_out, diag_out%h_kappa_elem)
        wbuf = TRIM(wbuf)//TRIM(CD_HermiteCable_Kink_Advice(diag_out%h_kappa_peak, diag_out%h_kappa_elem, &
                                                            SIZE(l0_out), deck_ratio))
      END BLOCK
      ErrMsg = wbuf
      RETURN
    END IF

    advisory = .FALSE.
    IF (PRESENT(tensile_advisory)) advisory = tensile_advisory
    IF (must_be_tensile .AND. diag_out%axial_compression .AND. .NOT. advisory) THEN
      ErrStat = CD_HCSTAT_NOCONVERGE
      wbuf = ''
      IF (LEN_TRIM(axial_stop) > 0) THEN
        WRITE (wbuf, '(A,I0,A,ES12.5,A,ES12.5,A,I0,A,F8.5,A,ES12.5)', IOSTAT=wios) &
          'CD_HermiteCable_Static_Solve_AutoMesh: local axial refinement stopped after ', local_passes, &
          ' passes ('//TRIM(axial_stop)//') with compressive axial resultant=', &
          diag_out%axial_strain_min_resultant, &
          ' N below tolerance=', diag_out%axial_tolerance, ' N at element ', &
          diag_out%axial_strain_min_elem, ', xi=', diag_out%axial_strain_min_xi, &
          ', strain=', diag_out%axial_strain_min
      ELSE IF (LEN_TRIM(local_stop) > 0) THEN
        WRITE (wbuf, '(A,ES12.5,A,ES12.5,A,I0,A,F8.5,A,ES12.5)', IOSTAT=wios) &
          'CD_HermiteCable_Static_Solve_AutoMesh: local refinement stopped ('//TRIM(local_stop)// &
          ') with compressive axial resultant=', diag_out%axial_strain_min_resultant, &
          ' N below tolerance=', diag_out%axial_tolerance, ' N at element ', &
          diag_out%axial_strain_min_elem, ', xi=', diag_out%axial_strain_min_xi, &
          ', strain=', diag_out%axial_strain_min
      ELSE
        WRITE (wbuf, '(A,I0,A,ES12.5,A,ES12.5,A,I0,A,F8.5,A,ES12.5)', IOSTAT=wios) &
          'CD_HermiteCable_Static_Solve_AutoMesh: refinement cap ', max_scale, &
          ' exhausted with compressive axial resultant=', diag_out%axial_strain_min_resultant, &
          ' N below tolerance=', diag_out%axial_tolerance, ' N at element ', &
          diag_out%axial_strain_min_elem, ', xi=', diag_out%axial_strain_min_xi, &
          ', strain=', diag_out%axial_strain_min
      END IF
      ! In a current, name the limit the compression of this state shows (the grounded run
      ! pushed into its end, or into a friction-held touchdown): the driver's out-of-plane
      ! retry of a planar current needs it, as for the other routes' failures.
      IF (PRESENT(current)) THEN
        IF (current_has_drag(current)) &
          wbuf = TRIM(current_compression_note(l0_out, EA_out, q_out, seabed_z,.NOT. PRESENT(bathymetry), &
                                               ALLOCATED(current%friction), EI=EI_out, w=w_out))//TRIM(wbuf)
      END IF
      ErrMsg = wbuf
      RETURN
    END IF

    ! The fail-closed accuracy contract covers the curvature field and the contact
    ! topology. An end bending boundary layer thinner than the capped global refinement
    ! can resolve (h/sqrt(EI/T) above target at the cap) is an accuracy limit of the
    ! requested mesh, not an unresolved equilibrium: the state is returned with
    ! diag_out%boundary_unresolved set for the caller to report.
    IF (must_resolve .AND. diag_out%fragile .AND. &
        (diag_out%h_kappa_peak > h_kappa_target .OR. diag_out%contact_chatter)) THEN
      ErrStat = CD_HCSTAT_NOCONVERGE
      wbuf = ''
      IF (LEN_TRIM(local_stop) > 0) THEN
        WRITE (wbuf, '(A,ES12.5,A,ES12.5,A,L1,A,I0)', IOSTAT=wios) &
          'CD_HermiteCable_Static_Solve_AutoMesh: local refinement stopped ('//TRIM(local_stop)// &
          ') with unresolved h*kappa=', diag_out%h_kappa_peak, ' (target ', h_kappa_target, &
          '), contact chatter=', diag_out%contact_chatter, &
          ', contact islands=', diag_out%n_islands
      ELSE
        WRITE (wbuf, '(A,I0,A,ES12.5,A,ES12.5,A,L1,A,I0)', IOSTAT=wios) &
          'CD_HermiteCable_Static_Solve_AutoMesh: refinement cap ', max_scale, &
          ' exhausted with unresolved h*kappa=', diag_out%h_kappa_peak, ' (target ', h_kappa_target, &
          '), contact chatter=', diag_out%contact_chatter, &
          ', contact islands=', diag_out%n_islands
      END IF
      ErrMsg = wbuf
      RETURN
    END IF

  CONTAINS

    SUBROUTINE lift_to_floor(qx, pen_allowed, esx, emx)
      !! Raise nodes that penetrate the floor by more than pen_allowed to that depth.
      REAL(wp), INTENT(INOUT) :: qx(:)
      REAL(wp), INTENT(IN) :: pen_allowed
      INTEGER, INTENT(OUT) :: esx
      CHARACTER(*), INTENT(OUT) :: emx
      INTEGER :: node, gz
      REAL(wp) :: z_floor
      esx = CD_HCSTAT_OK
      emx = ''
      DO node = 1, SIZE(qx)/6
        gz = 6*(node - 1) + 3
        CALL floor_at(qx(gz - 2:gz - 1), z_floor, esx, emx)
        IF (esx /= CD_HCSTAT_OK) RETURN
        qx(gz) = MAX(qx(gz), z_floor - pen_allowed)
      END DO
    END SUBROUTINE lift_to_floor

    REAL(wp) FUNCTION max_penetration(qx) RESULT(pen)
      !! Deepest nodal penetration of a state (zero when every node is clear).
      REAL(wp), INTENT(IN) :: qx(:)
      INTEGER :: node, gz, esx
      REAL(wp) :: z_floor
      CHARACTER(1024) :: emx
      pen = CD_ZERO
      DO node = 1, SIZE(qx)/6
        gz = 6*(node - 1) + 3
        CALL floor_at(qx(gz - 2:gz - 1), z_floor, esx, emx)
        IF (esx /= CD_HCSTAT_OK) CYCLE
        pen = MAX(pen, z_floor - qx(gz))
      END DO
    END FUNCTION max_penetration

    SUBROUTINE floor_at(xy, z_floor, esx, emx)
      REAL(wp), INTENT(IN) :: xy(2)
      REAL(wp), INTENT(OUT) :: z_floor
      INTEGER, INTENT(OUT) :: esx
      CHARACTER(*), INTENT(OUT) :: emx
      INTEGER :: bstat
      REAL(wp) :: xg, yg
      CHARACTER(1024) :: bmsg
      esx = CD_HCSTAT_OK
      emx = ''
      z_floor = seabed_z
      IF (PRESENT(bathymetry)) THEN
        xg = contact_cs(1)*xy(1) - contact_cs(2)*xy(2)
        yg = contact_cs(2)*xy(1) + contact_cs(1)*xy(2)
        CALL CD_Bathymetry_Floor(bathymetry, xg, yg, z_floor, bstat, bmsg)
        IF (bstat /= CD_BATHY_OK) THEN
          esx = CD_HCSTAT_NOCONVERGE; emx = 'bathymetry query failed: '//TRIM(bmsg)
        END IF
      END IF
    END SUBROUTINE floor_at

    LOGICAL FUNCTION refinable(dg)
      !! Global refinement is requested for an unresolved curvature field or contact
      !! topology, and for an unresolved end boundary layer only while the remaining
      !! refinement cap can still bring h/sqrt(EI/T) to its target.
      TYPE(CD_HermiteResolutionType), INTENT(IN) :: dg
      IF (local_mode) THEN
        ! As below, with the factor still open to the end element of the larger ratio (on
        ! the caller mesh exactly the global test, so the same meshes refine).
        refinable = dg%h_kappa_peak > h_kappa_target .OR. dg%contact_chatter .OR. &
                    (dg%boundary_unresolved .AND. &
                     dg%boundary_ratio_peak <= CD_HC_BOUNDARY_TARGET*REAL(max_scale, wp)/ &
                     2.0_wp**MERGE(level_out(1), level_out(SIZE(level_out)), &
                                   dg%hop_boundary_ratio >= dg%end_boundary_ratio))
        RETURN
      END IF
      refinable = dg%h_kappa_peak > h_kappa_target .OR. dg%contact_chatter .OR. &
                  (dg%boundary_unresolved .AND. &
                   dg%boundary_ratio_peak <= CD_HC_BOUNDARY_TARGET*REAL(max_scale, wp)/REAL(applied_scale, wp))
    END FUNCTION refinable

    INTEGER FUNCTION end_layer_levels(ratio, level) RESULT(k)
      !! Bisections of an end element (at level bisections from its caller element) that bring
      !! its boundary-layer ratio h/sqrt(EI/T) to CD_HC_BOUNDARY_TARGET, within the cap; zero
      !! when the ratio is met. A layer the cap cannot reach is an accuracy limit (reported by
      !! diag%boundary_unresolved) that does not by itself start a pass (refinable), but a
      !! pass that runs refines it as far as the cap allows -- as the global factor rec_scale
      !! does.
      REAL(wp), INTENT(IN) :: ratio
      INTEGER, INTENT(IN) :: level
      k = 0
      IF (.NOT. (ratio > CD_HC_BOUNDARY_TARGET*(CD_ONE + 1.0e-10_wp))) RETURN
      DO WHILE (ratio > CD_HC_BOUNDARY_TARGET*2.0_wp**k*(CD_ONE + 1.0e-10_wp) .AND. level + k < kcap)
        k = k + 1
      END DO
    END FUNCTION end_layer_levels

    SUBROUTINE diagnose(esx)
      !! Resolution diagnosis of the current mesh and state (diag_out); in local mode also the
      !! per-element h*kappa and the isolated contact/gap nodes the local refinement marks from.
      INTEGER, INTENT(OUT) :: esx
      IF (local_mode) THEN
        IF (ALLOCATED(elem_hk)) DEALLOCATE (elem_hk, chatter_nodes)
        ALLOCATE (elem_hk(SIZE(l0_out)), chatter_nodes(SIZE(l0_out) + 1))
        IF (PRESENT(bathymetry)) THEN
          CALL CD_HermiteCable_Resolution_Metrics(l0_out, q_out, seabed_z, contact_band, h_kappa_target, &
                                                  diag_out, esx, ErrMsg, bathymetry=bathymetry, &
                                                  contact_frame_cs=contact_cs, EA=EA_out, EI=EI_out, &
                                                  compression_mode=cmode, elem_h_kappa=elem_hk, &
                                                  chatter_node=chatter_nodes)
        ELSE
          CALL CD_HermiteCable_Resolution_Metrics(l0_out, q_out, seabed_z, contact_band, h_kappa_target, &
                                                  diag_out, esx, ErrMsg, EA=EA_out, EI=EI_out, &
                                                  compression_mode=cmode, elem_h_kappa=elem_hk, &
                                                  chatter_node=chatter_nodes)
        END IF
      ELSE IF (PRESENT(bathymetry)) THEN
        CALL CD_HermiteCable_Resolution_Metrics(l0_out, q_out, seabed_z, contact_band, h_kappa_target, &
                                                diag_out, esx, ErrMsg, bathymetry=bathymetry, &
                                                contact_frame_cs=contact_cs, EA=EA_out, EI=EI_out, &
                                                compression_mode=cmode)
      ELSE
        CALL CD_HermiteCable_Resolution_Metrics(l0_out, q_out, seabed_z, contact_band, h_kappa_target, &
                                                diag_out, esx, ErrMsg, EA=EA_out, EI=EI_out, compression_mode=cmode)
      END IF
    END SUBROUTINE diagnose

    SUBROUTINE local_resolution_mesh(none, esx, emx)
      !! The locally refined mesh of a local resolution pass, in l0r/qr/fixedr with parent_map
      !! (the current element each new one lies in) and level_r. Levels needed per element:
      !!   h*kappa  -- the smallest k with h*kappa / 2^k <= min(h_kappa_target,
      !!               CD_HC_HKAPPA_TARGET). A pass runs only while the caller's target fails,
      !!               but it refines every element to the accuracy target (a looser caller
      !!               target, such as the safety-driven half kink limit, would leave the bends
      !!               of a locally refined line at a much coarser resolution than the global
      !!               factor, which refines every element by the factor of the worst one);
      !!   bending   -- the smallest k with h / 2^k <= half the bending length (EI/|w|)^(1/3),
      !!               the element-length rule of the finite-EI meshing guide: an element longer
      !!               than that cannot follow a bend (a grounded run over an uneven bed, a
      !!               touchdown) whose curvature it therefore does not show, and on such a mesh
      !!               a planar state can read as unstable out of its plane;
      !!   end layer -- end_layer_levels of each end element (as far as the cap allows);
      !!   contact   -- one level on the two elements at an isolated contact or gap node and
      !!                one more on each side;
      !! each limited to kcap bisections from the caller element. The levels are then graded:
      !! an element is split further while it is longer than max(2, its length ratio to the
      !! neighbour before the pass) times that neighbour's new length. A pass that would exceed
      !! the element limit (element_limit) gives up first the bending-length levels (one
      !! level at a time, graded), then the grading, and only then takes one level less of the
      !! h*kappa, end-layer and contact needs at a time: those name a bend or a boundary layer
      !! the state shows, where the bending-length rule is a mesh-quality rule. none is set
      !! when no element can be split.
      LOGICAL, INTENT(OUT) :: none
      INTEGER, INTENT(OUT) :: esx
      CHARACTER(*), INTENT(OUT) :: emx
      INTEGER, ALLOCATABLE :: base(:), bend(:), need(:), need_n(:), lev_c(:), lev_n(:), par_c(:), par_n(:)
      INTEGER, ALLOCATABLE :: fix_c(:), fix_n(:)
      REAL(wp), ALLOCATABLE :: l0_c(:), q_c(:), l0_n(:), q_n(:)
      LOGICAL, ALLOCATABLE :: split(:)
      INTEGER :: nec, e, a, k, red
      INTEGER(I8) :: n_new
      REAL(wp) :: hk_local, half_bend
      LOGICAL :: fits
      none = .TRUE.
      esx = CD_HCSTAT_OK
      emx = ''
      nec = SIZE(l0_out)
      ! base: the h*kappa, end-layer and contact needs; bend: the bending-length needs.
      ALLOCATE (base(nec), bend(nec), need(nec))
      hk_local = MIN(h_kappa_target, CD_HC_HKAPPA_TARGET)
      base = 0
      bend = 0
      DO e = 1, nec
        IF (.NOT. (elem_hk(e) > hk_local)) CYCLE
        k = 0
        DO WHILE (elem_hk(e) > hk_local*2.0_wp**k .AND. level_out(e) + k < kcap)
          k = k + 1
        END DO
        base(e) = MAX(base(e), k)
      END DO
      DO e = 1, nec
        IF (.NOT. (EI_out(e) > CD_ZERO .AND. ABS(w_out(e)) > CD_ZERO)) CYCLE
        half_bend = 0.5_wp*(EI_out(e)/ABS(w_out(e)))**(CD_ONE/3.0_wp)
        k = 0
        DO WHILE (l0_out(e) > half_bend*2.0_wp**k*(CD_ONE + 1.0e-12_wp) .AND. level_out(e) + k < kcap)
          k = k + 1
        END DO
        bend(e) = k
      END DO
      base(1) = MAX(base(1), end_layer_levels(diag_out%hop_boundary_ratio, level_out(1)))
      base(nec) = MAX(base(nec), end_layer_levels(diag_out%end_boundary_ratio, level_out(nec)))
      DO a = 2, nec
        IF (.NOT. chatter_nodes(a)) CYCLE
        DO e = MAX(1, a - 2), MIN(nec, a + 1)
          IF (level_out(e) < kcap) base(e) = MAX(base(e), 1)
        END DO
      END DO
      IF (ALL(base == 0) .AND. ALL(bend == 0)) RETURN
      ! Within the element limit: the bending-length levels go first, then the grading, then
      ! the other needs a level at a time (the first try is the whole graded need).
      fits = .FALSE.
      DO red = 0, MAXVAL(bend)
        need = MAX(base, bend - red)
        CALL grade(need)
        n_new = SUM(2_I8**need)
        fits = n_new <= INT(element_limit, I8)
        IF (fits) EXIT
      END DO
      DO red = 0, MAXVAL(base)
        IF (fits) EXIT
        need = MAX(base - red, 0)
        n_new = SUM(2_I8**need)
        fits = n_new <= INT(element_limit, I8)
      END DO
      IF (.NOT. fits .OR. ALL(need == 0)) THEN
        ! A need was given up to the limit (with no need at all the early return above names
        ! the per-element cap).
        WRITE (local_stop, '(A,I0,A)') 'the element limit ', element_limit, ' was reached'
        RETURN
      END IF
      none = .FALSE.

      ! Bisect level by level: the children of a split cubic-Hermite element carry the same
      ! cubic, so k bisections are the 2^k-fold uniform prolongation of the element.
      l0_c = l0_out
      q_c = q_out
      fix_c = fixed_out
      lev_c = level_out
      ALLOCATE (par_c(nec))
      par_c = [(e, e=1, nec)]
      DO WHILE (ANY(need > 0))
        split = need > 0
        CALL refine_marked_elements(l0_c, q_c, fix_c, split, l0_n, q_n, fix_n, par_n, esx, emx, inherit_dofs)
        IF (esx /= CD_HCSTAT_OK) RETURN
        ALLOCATE (need_n(SIZE(l0_n)), lev_n(SIZE(l0_n)))
        DO e = 1, SIZE(l0_n)
          need_n(e) = need(par_n(e)) - MERGE(1, 0, split(par_n(e)))
          lev_n(e) = lev_c(par_n(e)) + MERGE(1, 0, split(par_n(e)))
          par_n(e) = par_c(par_n(e))
        END DO
        CALL MOVE_ALLOC(l0_n, l0_c)
        CALL MOVE_ALLOC(q_n, q_c)
        CALL MOVE_ALLOC(fix_n, fix_c)
        CALL MOVE_ALLOC(par_n, par_c)
        CALL MOVE_ALLOC(need_n, need)
        CALL MOVE_ALLOC(lev_n, lev_c)
      END DO
      CALL MOVE_ALLOC(l0_c, l0r)
      CALL MOVE_ALLOC(q_c, qr)
      CALL MOVE_ALLOC(fix_c, fixedr)
      CALL MOVE_ALLOC(par_c, parent_map)
      CALL MOVE_ALLOC(lev_c, level_r)
    END SUBROUTINE local_resolution_mesh

    SUBROUTINE grade(need)
      !! Raise need until no element of the refined mesh is longer than max(2, its length
      !! ratio to the neighbour on the current mesh) times that neighbour's refined length,
      !! within the per-element cap, and no element left longer than both of its neighbours
      !! is split fewer times (from its caller element) than both: such an element is split
      !! until it is no longer than the longer neighbour or as often as the less split one.
      !! (A single coarser element between finer ones carries a spurious axial oscillation
      !! and can read as a compressed stretch.)
      INTEGER, INTENT(INOUT) :: need(:)
      LOGICAL :: changed
      INTEGER :: e, side, f, g, lm
      REAL(wp) :: allow, lnb
      changed = .TRUE.
      DO WHILE (changed)
        changed = .FALSE.
        DO e = 2, SIZE(need) - 1
          lm = MIN(level_out(e - 1) + need(e - 1), level_out(e + 1) + need(e + 1), kcap)
          lnb = MAX(l0_out(e - 1)/2.0_wp**need(e - 1), l0_out(e + 1)/2.0_wp**need(e + 1))
          DO WHILE (l0_out(e)/2.0_wp**need(e) > lnb*(CD_ONE + 1.0e-12_wp) .AND. level_out(e) + need(e) < lm)
            need(e) = need(e) + 1
            changed = .TRUE.
          END DO
        END DO
        DO e = 1, SIZE(need) - 1
          DO side = 0, 1
            f = e + side
            g = e + 1 - side
            allow = MAX(2.0_wp, l0_out(f)/l0_out(g))*(CD_ONE + 1.0e-12_wp)
            DO WHILE (l0_out(f)/2.0_wp**need(f) > allow*l0_out(g)/2.0_wp**need(g) .AND. &
                      level_out(f) + need(f) < kcap)
              need(f) = need(f) + 1
              changed = .TRUE.
            END DO
          END DO
        END DO
      END DO
    END SUBROUTINE grade

    SUBROUTINE solve_level(l0x, EAx, EIx, wx, seedx, fixedx, diamx, dryx, qx, curvx, resx, itx, esx, emx, polish)
      REAL(wp), INTENT(IN) :: l0x(:), EAx(:), EIx(:), wx(:), seedx(:)
      INTEGER, INTENT(IN) :: fixedx(:)
      ! dryx is unallocated without a free surface and then reaches the solver as absent.
      REAL(wp), ALLOCATABLE, INTENT(IN) :: diamx(:), dryx(:)
      REAL(wp), INTENT(OUT) :: qx(:), curvx(:), resx
      INTEGER, INTENT(OUT) :: itx, esx
      CHARACTER(*), INTENT(OUT) :: emx
      LOGICAL, INTENT(IN) :: polish
      REAL(wp), ALLOCATABLE :: knnode(:)
      INTEGER :: ielem, buoy_steps, cont_steps

      buoy_steps = MERGE(1, 40, polish)
      cont_steps = MERGE(1, n_cont, polish)
      IF (.NOT. contact_active) THEN
        IF (polish) THEN
          CALL CD_HermiteCable_Static_Solve(l0x, EAx, EIx, wx, seedx, fixedx, seabed_z, kn, &
                                            cont_steps, max_iter, tol, damping, qx, curvx, resx, itx, esx, emx, &
                                            n_buoy_steps=1, axial_quadrature_order=axial_order, &
                                            bending_quadrature_order=bending_order, &
                                            endconn_stiffness=endconn_stiffness, &
                                            endconn_direction=endconn_direction, endconn_mode=endconn_mode, &
                                            waterline_z=waterline_z, dry_buoyancy=dryx, water_weight=water_weight, &
                                            current=current, &
                                            energy_minimization=energy_polish)
        ELSE
          CALL CD_HermiteCable_Static_Solve(l0x, EAx, EIx, wx, seedx, fixedx, seabed_z, kn, &
                                            cont_steps, max_iter, tol, damping, qx, curvx, resx, itx, esx, emx, &
                                            axial_quadrature_order=axial_order, &
                                            bending_quadrature_order=bending_order, &
                                            endconn_stiffness=endconn_stiffness, &
                                            endconn_direction=endconn_direction, endconn_mode=endconn_mode, &
                                            waterline_z=waterline_z, dry_buoyancy=dryx, water_weight=water_weight, &
                                            current=current)
        END IF
        RETURN
      END IF
      ! Tributary nodal law: half of each adjacent element's diameter x length.
      ALLOCATE (knnode(SIZE(l0x) + 1))
      knnode = CD_ZERO
      DO ielem = 1, SIZE(l0x)
        knnode(ielem) = knnode(ielem) + 0.5_wp*contact_kbot*diamx(ielem)*l0x(ielem)
        knnode(ielem + 1) = knnode(ielem + 1) + 0.5_wp*contact_kbot*diamx(ielem)*l0x(ielem)
      END DO
      IF (PRESENT(bathymetry)) THEN
        CALL CD_HermiteCable_Static_Solve(l0x, EAx, EIx, wx, seedx, fixedx, seabed_z, kn, &
                                          cont_steps, max_iter, tol, damping, qx, curvx, resx, itx, esx, emx, &
                                          n_buoy_steps=buoy_steps, contact_kn=knnode, bathymetry=bathymetry, &
                                          contact_frame_cs=contact_cs, axial_quadrature_order=axial_order, &
                                          bending_quadrature_order=bending_order, &
                                          endconn_stiffness=endconn_stiffness, &
                                          endconn_direction=endconn_direction, endconn_mode=endconn_mode, &
                                          waterline_z=waterline_z, dry_buoyancy=dryx, water_weight=water_weight, &
                                          current=current, &
                                          energy_minimization=polish .AND. energy_polish)
      ELSE
        CALL CD_HermiteCable_Static_Solve(l0x, EAx, EIx, wx, seedx, fixedx, seabed_z, kn, &
                                          cont_steps, max_iter, tol, damping, qx, curvx, resx, itx, esx, emx, &
                                          n_buoy_steps=buoy_steps, contact_kn=knnode, contact_frame_cs=contact_cs, &
                                          axial_quadrature_order=axial_order, bending_quadrature_order=bending_order, &
                                          endconn_stiffness=endconn_stiffness, endconn_direction=endconn_direction, &
                                          endconn_mode=endconn_mode, waterline_z=waterline_z, dry_buoyancy=dryx, &
                                          water_weight=water_weight, current=current, &
                                          energy_minimization=polish .AND. energy_polish)
      END IF
    END SUBROUTINE solve_level

  END SUBROUTINE CD_HermiteCable_Static_Solve_AutoMesh

  PURE SUBROUTINE coarsen_props(l0f, EAf, EIf, wf, nodes, l0c, EAc, EIc, wc)
    !! Merge the fine-element runs delimited by nodes into coarse elements: exact total
    !! rest length, series compliance for the stiffnesses (a zero-stiffness member makes
    !! the merged element zero-stiffness), and length-weighted submerged weight (total
    !! weight preserved). The primary hierarchies supply interface nodes, so their coarse
    !! elements never cross a discontinuity. The last-resort cell-averaged hierarchy may
    !! cross one deliberately but preserves these integral properties before the exact
    !! caller mesh restores every interface.
    REAL(wp), INTENT(IN) :: l0f(:), EAf(:), EIf(:), wf(:)
    INTEGER, INTENT(IN) :: nodes(:)
    REAL(wp), INTENT(OUT) :: l0c(:), EAc(:), EIc(:), wc(:)
    INTEGER :: j, k
    REAL(wp) :: Lsum, wsum, cA, cI
    LOGICAL :: zA, zI
    IF (SIZE(l0c) == SIZE(l0f)) THEN
      ! the finest level IS the caller's mesh -- carry the arrays bitwise (the merge
      ! arithmetic below would reconstruct EA as l0/(l0/EA), two spurious roundings)
      l0c = l0f; EAc = EAf; EIc = EIf; wc = wf
      RETURN
    END IF
    DO j = 1, SIZE(l0c)
      Lsum = CD_ZERO; wsum = CD_ZERO; cA = CD_ZERO; cI = CD_ZERO
      zA = .FALSE.; zI = .FALSE.
      DO k = nodes(j), nodes(j + 1) - 1
        Lsum = Lsum + l0f(k)
        wsum = wsum + wf(k)*l0f(k)
        IF (EAf(k) <= CD_ZERO) THEN
          zA = .TRUE.
        ELSE
          cA = cA + l0f(k)/EAf(k)
        END IF
        IF (EIf(k) <= CD_ZERO) THEN
          zI = .TRUE.
        ELSE
          cI = cI + l0f(k)/EIf(k)
        END IF
      END DO
      l0c(j) = Lsum
      wc(j) = wsum/Lsum
      IF (zA) THEN
        EAc(j) = CD_ZERO
      ELSE
        EAc(j) = Lsum/cA
      END IF
      IF (zI) THEN
        EIc(j) = CD_ZERO
      ELSE
        EIc(j) = Lsum/cI
      END IF
    END DO
  END SUBROUTINE coarsen_props

  PURE SUBROUTINE hermite_prolongate_nested(q_c, nodes_c, nodes_f, l0_base, q_f)
    !! Prolongate a state between two NESTED subsets of the caller's material nodes.
    !! Unlike hermite_prolongate, this supports a short final group and mandatory
    !! section/load interfaces, so arbitrary element counts reach the same sequencing
    !! architecture instead of falling back solely because ne is odd or prime.
    REAL(wp), INTENT(IN) :: q_c(:), l0_base(:)
    INTEGER, INTENT(IN) :: nodes_c(:), nodes_f(:)
    REAL(wp), INTENT(OUT) :: q_f(:)
    INTEGER :: a, ec, fine_node, left_node, right_node
    REAL(wp) :: r1(3), r2(3), m1(3), m2(3), xi, h00, h10, h01, h11
    REAL(wp) :: g00, g10, g01, g11, L, left_length

    q_f = CD_ZERO
    ec = 1
    DO a = 1, SIZE(nodes_f)
      fine_node = nodes_f(a)
      DO WHILE (ec < SIZE(nodes_c) - 1 .AND. fine_node > nodes_c(ec + 1))
        ec = ec + 1
      END DO
      IF (fine_node == nodes_c(ec)) THEN
        q_f(6*(a - 1) + 1:6*a) = q_c(6*(ec - 1) + 1:6*ec)
        CYCLE
      END IF
      IF (fine_node == nodes_c(ec + 1)) THEN
        q_f(6*(a - 1) + 1:6*a) = q_c(6*ec + 1:6*(ec + 1))
        CYCLE
      END IF

      left_node = nodes_c(ec)
      right_node = nodes_c(ec + 1)
      L = SUM(l0_base(left_node:right_node - 1))
      left_length = SUM(l0_base(left_node:fine_node - 1))
      xi = left_length/L
      r1 = q_c(6*(ec - 1) + 1:6*(ec - 1) + 3)
      m1 = q_c(6*(ec - 1) + 4:6*(ec - 1) + 6)
      r2 = q_c(6*ec + 1:6*ec + 3)
      m2 = q_c(6*ec + 4:6*ec + 6)
      h00 = 1.0_wp - 3.0_wp*xi*xi + 2.0_wp*xi*xi*xi
      h10 = xi - 2.0_wp*xi*xi + xi*xi*xi
      h01 = 3.0_wp*xi*xi - 2.0_wp*xi*xi*xi
      h11 = -xi*xi + xi*xi*xi
      g00 = (-6.0_wp*xi + 6.0_wp*xi*xi)/L
      g10 = 1.0_wp - 4.0_wp*xi + 3.0_wp*xi*xi
      g01 = (6.0_wp*xi - 6.0_wp*xi*xi)/L
      g11 = -2.0_wp*xi + 3.0_wp*xi*xi
      q_f(6*(a - 1) + 1:6*(a - 1) + 3) = h00*r1 + h10*L*m1 + h01*r2 + h11*L*m2
      q_f(6*(a - 1) + 4:6*(a - 1) + 6) = g00*r1 + g10*m1 + g01*r2 + g11*m2
    END DO
  END SUBROUTINE hermite_prolongate_nested

  PURE SUBROUTINE hermite_prolongate(q_c, l0_c, l0_f, q_f)
    !! Refine a converged coarse solution onto the element-doubled mesh: coarse nodes
    !! copied, each new node placed on the parent element's cubic-Hermite interpolant at
    !! the ACTUAL split point xi = l0_f(2e-1)/l0_c(e) between its two child elements (the
    !! midpoint only when the children have equal rest length), with position and material
    !! tangent from the interpolant and its arc derivative.
    REAL(wp), INTENT(IN) :: q_c(:), l0_c(:), l0_f(:)
    REAL(wp), INTENT(OUT) :: q_f(:)
    INTEGER :: e, nec, nnf
    REAL(wp) :: r1(3), r2(3), m1(3), m2(3), xi, h00, h10, h01, h11, g00, g10, g01, g11, L
    nec = SIZE(l0_c)
    nnf = 2*nec + 1
    DO e = 1, nec
      r1 = q_c(6*(e - 1) + 1:6*(e - 1) + 3); m1 = q_c(6*(e - 1) + 4:6*(e - 1) + 6)
      r2 = q_c(6*e + 1:6*e + 3); m2 = q_c(6*e + 4:6*e + 6)
      L = l0_c(e)
      xi = l0_f(2*e - 1)/L
      h00 = 1.0_wp - 3.0_wp*xi*xi + 2.0_wp*xi*xi*xi
      h10 = xi - 2.0_wp*xi*xi + xi*xi*xi
      h01 = 3.0_wp*xi*xi - 2.0_wp*xi*xi*xi
      h11 = -xi*xi + xi*xi*xi
      g00 = (-6.0_wp*xi + 6.0_wp*xi*xi)/L
      g10 = 1.0_wp - 4.0_wp*xi + 3.0_wp*xi*xi
      g01 = (6.0_wp*xi - 6.0_wp*xi*xi)/L
      g11 = -2.0_wp*xi + 3.0_wp*xi*xi
      q_f(6*(2*e - 2) + 1:6*(2*e - 2) + 3) = r1
      q_f(6*(2*e - 2) + 4:6*(2*e - 2) + 6) = m1
      q_f(6*(2*e - 1) + 1:6*(2*e - 1) + 3) = h00*r1 + h10*L*m1 + h01*r2 + h11*L*m2
      q_f(6*(2*e - 1) + 4:6*(2*e - 1) + 6) = g00*r1 + g10*m1 + g01*r2 + g11*m2
    END DO
    q_f(6*(nnf - 1) + 1:6*(nnf - 1) + 3) = q_c(6*nec + 1:6*nec + 3)
    q_f(6*(nnf - 1) + 4:6*(nnf - 1) + 6) = q_c(6*nec + 4:6*nec + 6)
  END SUBROUTINE hermite_prolongate

  SUBROUTINE CD_HermiteCable_Prolong_Arc(l0_c, q_c, l0_f, q_f, ErrStat, ErrMsg)
    !! Carry a Hermite line state from one mesh to another of the same line: each node of
    !! the target mesh l0_f is placed on the cubic-Hermite interpolant of the source state
    !! (l0_c, q_c) at its unstretched arc length, with the material tangent dr/ds from the
    !! interpolant's arc derivative. The meshes need not be nested (any element counts);
    !! both must span the same unstretched length. Node 1 is the first node of both.
    REAL(wp), INTENT(IN) :: l0_c(:), q_c(:), l0_f(:)
    REAL(wp), INTENT(OUT) :: q_f(:)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    INTEGER :: a, ec, nec, nnf
    REAL(wp) :: s_f, s_left, total_c, total_f, r1(3), r2(3), m1(3), m2(3), xi, L
    REAL(wp) :: h00, h10, h01, h11, g00, g10, g01, g11
    ErrStat = CD_HCSTAT_OK
    ErrMsg = ''
    nec = SIZE(l0_c)
    nnf = SIZE(l0_f) + 1
    IF (nec < 1 .OR. SIZE(l0_f) < 1 .OR. SIZE(q_c) /= 6*(nec + 1) .OR. SIZE(q_f) /= 6*nnf) THEN
      ErrStat = CD_HCSTAT_BADINPUT
      ErrMsg = 'CD_HermiteCable_Prolong_Arc: inconsistent array sizes'; RETURN
    END IF
    IF (ANY(l0_c <= CD_ZERO) .OR. ANY(l0_f <= CD_ZERO) .OR. .NOT. CD_All_Finite(q_c)) THEN
      ErrStat = CD_HCSTAT_BADINPUT
      ErrMsg = 'CD_HermiteCable_Prolong_Arc: need positive element lengths and a finite state'; RETURN
    END IF
    total_c = SUM(l0_c)
    total_f = SUM(l0_f)
    IF (ABS(total_c - total_f) > 1.0e-9_wp*MAX(total_c, total_f)) THEN
      ErrStat = CD_HCSTAT_BADINPUT
      ErrMsg = 'CD_HermiteCable_Prolong_Arc: the two meshes span different unstretched lengths'; RETURN
    END IF
    ec = 1
    s_left = CD_ZERO
    s_f = CD_ZERO
    DO a = 1, nnf
      IF (a == nnf) s_f = total_c
      DO WHILE (ec < nec .AND. s_f > s_left + l0_c(ec))
        s_left = s_left + l0_c(ec)
        ec = ec + 1
      END DO
      L = l0_c(ec)
      xi = MIN(CD_ONE, MAX(CD_ZERO, (s_f - s_left)/L))
      r1 = q_c(6*(ec - 1) + 1:6*(ec - 1) + 3); m1 = q_c(6*(ec - 1) + 4:6*(ec - 1) + 6)
      r2 = q_c(6*ec + 1:6*ec + 3); m2 = q_c(6*ec + 4:6*ec + 6)
      h00 = 1.0_wp - 3.0_wp*xi*xi + 2.0_wp*xi*xi*xi
      h10 = xi - 2.0_wp*xi*xi + xi*xi*xi
      h01 = 3.0_wp*xi*xi - 2.0_wp*xi*xi*xi
      h11 = -xi*xi + xi*xi*xi
      g00 = (-6.0_wp*xi + 6.0_wp*xi*xi)/L
      g10 = 1.0_wp - 4.0_wp*xi + 3.0_wp*xi*xi
      g01 = (6.0_wp*xi - 6.0_wp*xi*xi)/L
      g11 = -2.0_wp*xi + 3.0_wp*xi*xi
      q_f(6*(a - 1) + 1:6*(a - 1) + 3) = h00*r1 + h10*L*m1 + h01*r2 + h11*L*m2
      q_f(6*(a - 1) + 4:6*(a - 1) + 6) = g00*r1 + g10*m1 + g01*r2 + g11*m2
      IF (a < nnf) s_f = s_f + l0_f(a)
    END DO
    ! The end nodes are the source end nodes exactly.
    q_f(1:6) = q_c(1:6)
    q_f(6*(nnf - 1) + 1:6*nnf) = q_c(6*nec + 1:6*(nec + 1))
  END SUBROUTINE CD_HermiteCable_Prolong_Arc

  RECURSIVE SUBROUTINE CD_HermiteCable_Trivial_Seed(p_a, p_b, l0, seabed_z, seed, ErrStat, ErrMsg)
    !! Build the TRIVIAL initial state for the Hermite static solve from nothing but the
    !! endpoints, the rest lengths, and the seabed -- the Hermite-path counterpart of the
    !! EI = 0 path's analytical-catenary IC. The caller provides geometry; the library
    !! provides a seed that is ISOMETRIC (sampled polyline length = SUM(l0) to 5e-4
    !! relative in the slack regimes, asserted fail-closed; the tolerance admits the
    !! deliberate one-sample touchdown fillet, see seed_sample_two_segment): a seed
    !! substantially shorter than the rest length carries an EA-amplified compressive
    !! state that buckles the continuation into folded local equilibria (the dominant
    !! failure mode when a bed-clamped bowed chord is up to ~30% short).
    !!
    !! Construction, in the vertical plane through the endpoints (planar y = plane; the
    !! seed is 3D-safe for out-of-plane endpoints via the horizontal unit vector):
    !!   * taut (SUM(l0) <= chord): nodes along the chord at rest-length stations
    !!     (uniform positive strain -- tension, not buckling), with tangents at the
    !!     consistent stretch gauge |m| = chord/SUM(l0) (m = dr/ds);
    !!   * ONE end on the bed, slack (either order -- the repository's finite-EI line
    !!     convention runs anchor -> fairlead, so a grounded end A is built as the
    !!     mirrored reversed line and mapped back, node i <- reversed node nn+1-i with
    !!     the tangent negated): the exact two-segment touchdown split. x_td from
    !!     sqrt(x_td^2 + h_a^2) + (x_ah - x_td) = L gives a straight span + straight
    !!     grounded run, isometric by construction. Beyond the L-shape length
    !!     (L >= h_a + x_ah, where x_td <= 0) NO planar equilibrium free of bed
    !!     wadding exists at all -- the surplus length must fold somewhere on a
    !!     frictionless bed -- so the seed switches to a quarter-ellipse landing leg
    !!     (vertical launch, tangentially horizontal touchdown) with the excess in a
    !!     sin^2-windowed bulge, and the SOLVED equilibrium is legitimately a
    !!     wadded-surplus shape. (An analytic grounded catenary is not used as the
    !!     primary here: CD_Catenary_Seed's endpoint closure can return hooked
    !!     non-classical shapes beyond its tested slackness.);
    !!   * BOTH ends on the bed, slack: a fully grounded laid-cable S -- the surplus
    !!     meanders in the bed plane (sine bow along the horizontal perpendicular, same
    !!     bisection). Planar-pinned callers note: no smooth in-plane shape exists for
    !!     this geometry at all (the L-shape law with h = 0), so a planar solve lands
    !!     in the wadded-surplus class from any seed;
    !!   * both ends above the bed: a suspended sine bow perpendicular to the chord on
    !!     the sagging side, depth by the same bisection; when that bow would cross the
    !!     seabed, an isometric double-touchdown construction instead (two touchdown
    !!     points moved apart, then vertical legs with the surplus in a smooth bow over
    !!     the middle run; seed_sample_double_touchdown).
    !! Node stations honour the caller's per-element rest lengths via an arc-length
    !! table; tangents are central differences at the branch's stretch gauge (|m| = 1
    !! unstretched on the isometric slack constructions; |m| = chord/SUM(l0) on the
    !! taut branch).
    REAL(wp), INTENT(IN) :: p_a(3), p_b(3), l0(:), seabed_z
    REAL(wp), INTENT(OUT) :: seed(:)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg

    INTEGER :: ne, nn, i, ns
    REAL(wp) :: Ltot, chord(3), chord_len, e_h(3), x_ah, h_a, h_b, x_td, bed_tol, mscale
    REAL(wp) :: pm(3), pp(3), tv(3), tn, s_i
    LOGICAL :: taut
    REAL(wp), ALLOCATABLE :: samp(:, :), arc(:), sta(:), l0_rev(:), seed_rev(:)

    ErrStat = CD_HCSTAT_OK
    ErrMsg = ''
    ne = SIZE(l0)
    nn = ne + 1
    IF (ne < 1 .OR. SIZE(seed) /= 6*nn) THEN
      CALL fail_seed('seed must be 6*(SIZE(l0)+1) with at least one element'); RETURN
    END IF
    IF (.NOT. (CD_All_Finite(p_a) .AND. CD_All_Finite(p_b) .AND. &
               CD_All_Finite(l0) .AND. CD_Is_Finite(seabed_z))) THEN
      CALL fail_seed('inputs must be finite'); RETURN
    END IF
    IF (ANY(l0 <= CD_ZERO)) THEN
      CALL fail_seed('l0 > 0 required'); RETURN
    END IF
    Ltot = SUM(l0)
    bed_tol = 1.0e-9_wp*MAX(Ltot, CD_ONE)
    IF (p_a(3) < seabed_z - bed_tol .OR. p_b(3) < seabed_z - bed_tol) THEN
      CALL fail_seed('endpoints must be at or above the seabed'); RETURN
    END IF
    chord = p_b - p_a
    chord_len = SQRT(SUM(chord**2))
    IF (chord_len <= 1.0e-12_wp*MAX(Ltot, CD_ONE)) THEN
      CALL fail_seed('endpoints are coincident'); RETURN
    END IF

    ! cumulative rest-length stations of the caller's nodes
    ALLOCATE (sta(nn))
    sta(1) = CD_ZERO
    DO i = 1, ne
      sta(i + 1) = sta(i) + l0(i)
    END DO

    IF (Ltot <= chord_len) THEN
      ! taut: rest-length stations along the chord (uniform tensile strain)
      DO i = 1, nn
        seed(6*i - 5:6*i - 3) = p_a + chord*(sta(i)/Ltot)
      END DO
    ELSE
      ! slack: isometric polyline constructions
      e_h = [chord(1), chord(2), CD_ZERO]
      x_ah = SQRT(SUM(e_h**2))
      IF (x_ah > 1.0e-12_wp*MAX(Ltot, CD_ONE)) THEN
        e_h = e_h/x_ah
      ELSE
        e_h = [CD_ONE, CD_ZERO, CD_ZERO]   ! vertically stacked endpoints: any horizontal
      END IF
      h_a = p_a(3) - seabed_z
      h_b = p_b(3) - seabed_z
      IF (h_a <= 1.0e-6_wp*MAX(Ltot, CD_ONE) .AND. h_b > 1.0e-6_wp*MAX(Ltot, CD_ONE)) THEN
        ! The grounded end is A (the repository's finite-EI line convention runs
        ! anchor -> fairlead, so this is the COMMON installed-cable order). The grounded
        ! construction below assumes the bed end is B: build the REVERSED line (swapped
        ! endpoints, reversed rest lengths) and mirror the result back -- node i reads
        ! reversed node nn+1-i with the tangent negated (the arc direction flips). One
        ! level deep only: the swapped call sees its end B on the bed.
        ALLOCATE (l0_rev(ne), seed_rev(6*nn))
        DO i = 1, ne
          l0_rev(i) = l0(ne + 1 - i)
        END DO
        CALL CD_HermiteCable_Trivial_Seed(p_b, p_a, l0_rev, seabed_z, seed_rev, ErrStat, ErrMsg)
        IF (ErrStat /= CD_HCSTAT_OK) RETURN
        DO i = 1, nn
          seed(6*i - 5:6*i - 3) = seed_rev(6*(nn + 1 - i) - 5:6*(nn + 1 - i) - 3)
          seed(6*i - 2:6*i) = -seed_rev(6*(nn + 1 - i) - 2:6*(nn + 1 - i))
        END DO
        RETURN
      END IF
      ns = MAX(1024, 8*ne) + 1
      ALLOCATE (samp(3, ns), arc(ns))
      IF (h_a <= 1.0e-6_wp*MAX(Ltot, CD_ONE) .AND. h_b <= 1.0e-6_wp*MAX(Ltot, CD_ONE)) THEN
        ! BOTH endpoints on the bed, slack: a fully grounded segment. The surplus length
        ! meanders IN the bed plane (a laid-cable S: sine bow along the horizontal
        ! perpendicular), the physically sensible stage-0 shape -- a vertical bow would
        ! either dip below the bed or lift a heavy line off it. Note for PLANAR-pinned
        ! callers (y fixed at every node): no smooth in-plane shape exists for this
        ! geometry at all (the L-shape well-posedness law with h = 0), so a planar solve
        ! from any seed lands in the wadded-surplus class regardless.
        CALL seed_sample_bowed_leg(p_a, p_b, [-e_h(2), e_h(1), CD_ZERO], Ltot, p_b, .FALSE., &
                                   samp, ErrStat, ErrMsg)
        IF (ErrStat /= CD_HCSTAT_OK) RETURN
      ELSE IF (h_b <= 1.0e-6_wp*MAX(Ltot, CD_ONE)) THEN
        x_td = -CD_ONE
        IF (Ltot > x_ah) x_td = (h_a**2 - (Ltot - x_ah)**2)/(2.0_wp*(Ltot - x_ah))
        ! Ltot > chord guarantees x_td < x_ah here; x_td <= 0 is beyond the L-shape bound
        IF (x_td > CD_ZERO) THEN
          CALL seed_sample_two_segment(p_a, p_a + e_h*x_td + [CD_ZERO, CD_ZERO, -h_a], p_b, samp)
        ELSE
          ! beyond the L-shape length: quarter-ellipse landing leg (vertical launch,
          ! tangentially horizontal touchdown -- no corner against the grounded run)
          ! with the excess length in a sin^2-windowed in-plane bulge that leaves both
          ! end tangents untouched; the touchdown sits at a modest forward offset
          x_td = MIN(0.3_wp*x_ah, 1.5_wp*h_a)
          CALL seed_sample_landing_leg(p_a, p_a + e_h*x_td + [CD_ZERO, CD_ZERO, -h_a], e_h, &
                                       Ltot - (x_ah - x_td), p_b, samp, ErrStat, ErrMsg)
          IF (ErrStat /= CD_HCSTAT_OK) RETURN
        END IF
      ELSE
        CALL seed_sample_bowed_leg(p_a, p_b, seed_sag_dir(p_a, p_b, e_h), Ltot, p_b, .FALSE., &
                                   samp, ErrStat, ErrMsg)
        IF (ErrStat /= CD_HCSTAT_OK) RETURN
        IF (MINVAL(samp(3, :)) < seabed_z - bed_tol) THEN
          ! A slack span with both endpoints above the bed is a valid grounded
          ! geometry, not an input error. Replace the penetrating suspended bow by
          ! an isometric two-touchdown path: two straight hanging legs plus a laid
          ! middle run (or an above-bed middle bow for length beyond the vertical-leg
          ! limit). The fine table deliberately chords each touchdown over roughly
          ! one sample, providing the same small bending-layer fillet as the proven
          ! one-touchdown seed.
          CALL seed_sample_double_touchdown(p_a, p_b, e_h, Ltot, seabed_z, samp, ErrStat, ErrMsg)
          IF (ErrStat /= CD_HCSTAT_OK) RETURN
        END IF
      END IF
      arc(1) = CD_ZERO
      DO i = 2, ns
        arc(i) = arc(i - 1) + SQRT(SUM((samp(:, i) - samp(:, i - 1))**2))
      END DO
      ! the isometry contract is ASSERTED, not trusted: any sampling regression fails
      ! loudly here instead of silently seeding an EA-amplified compressive state. The
      ! tolerance is 5e-4 relative -- the honest bound including the DELIBERATE
      ! one-sample touchdown fillet (see seed_sample_two_segment; its deficit is
      ! delta*(1 - cos(theta/2)) <= ~3e-4 of L at the steepest near-bound corners,
      ! delta = L/1024) -- still orders below the ~30% compressive class that buckles
      ! continuations. An exact corner is markedly less robust (see the fillet note in
      ! seed_sample_two_segment).
      IF (ABS(arc(ns) - Ltot) > 5.0e-4_wp*Ltot) THEN
        CALL fail_seed('internal: seed sample table is not isometric')
        RETURN
      END IF
      ! place the caller's stations by linear interpolation of the arc table (the table
      ! is isometric, so station s_i lands at arc s_i * arc(ns)/Ltot with the two equal
      ! to 5e-4 relative, the assertion above)
      DO i = 1, nn
        s_i = sta(i)*(arc(ns)/Ltot)
        seed(6*i - 5:6*i - 3) = seed_interp_arc(samp, arc, s_i)
      END DO
    END IF

    ! endpoints exactly (arc round-off must not move a pin)
    seed(1:3) = p_a
    seed(6*nn - 5:6*nn - 3) = p_b
    ! central-difference tangents. m = dr/ds, so |m| is the STRETCH gauge: the slack
    ! constructions are isometric (|m| = 1 = unstretched), but the taut branch lays
    ! element chords at l0*(chord/L) -- a uniformly stretched straight line whose
    ! consistent tangent is m = (chord/L)*chord_hat. Forcing |m| = 1 there would seed
    ! spurious tangent-DOF residuals on a no-load taut cable (EA-amplified for short
    ! as-built high-EA lines).
    taut = Ltot <= chord_len
    mscale = CD_ONE
    IF (taut) mscale = chord_len/Ltot
    DO i = 1, nn
      pm = seed(6*MAX(i - 1, 1) - 5:6*MAX(i - 1, 1) - 3)
      pp = seed(6*MIN(i + 1, nn) - 5:6*MIN(i + 1, nn) - 3)
      tv = pp - pm
      tn = SQRT(SUM(tv**2))
      IF (tn > 1.0e-12_wp*MAX(Ltot, CD_ONE)) THEN
        ! the slack path keeps a plain normalization (a folded-in scale factor rounds
        ! differently at the ULP and can flip basin-sensitive cases); the taut gauge
        ! applies as a separate multiply
        seed(6*i - 2:6*i) = tv/tn
        IF (taut) seed(6*i - 2:6*i) = seed(6*i - 2:6*i)*mscale
      ELSE
        seed(6*i - 2:6*i) = [mscale, CD_ZERO, CD_ZERO]
      END IF
    END DO

  CONTAINS

    SUBROUTINE fail_seed(msg)
      CHARACTER(*), INTENT(IN) :: msg
      ErrStat = CD_HCSTAT_BADINPUT
      ErrMsg = 'CD_HermiteCable_Trivial_Seed: '//msg
    END SUBROUTINE fail_seed

  END SUBROUTINE CD_HermiteCable_Trivial_Seed

  PURE FUNCTION seed_sag_dir(a, b, eh) RESULT(n_hat)
    !! In-plane unit perpendicular to the chord a -> b on the sagging side (negative-z
    !! component preferred; a vertical chord falls back to the -e_h side).
    REAL(wp), INTENT(IN) :: a(3), b(3), eh(3)
    REAL(wp) :: n_hat(3), c(3), cn2
    c = b - a
    cn2 = SQRT(SUM(c**2))
    c = c/cn2
    n_hat = -[CD_ZERO, CD_ZERO, CD_ONE] + DOT_PRODUCT([CD_ZERO, CD_ZERO, CD_ONE], c)*c
    cn2 = SQRT(SUM(n_hat**2))
    IF (cn2 > 1.0e-9_wp) THEN
      n_hat = n_hat/cn2
    ELSE
      n_hat = -eh
    END IF
  END FUNCTION seed_sag_dir

  PURE SUBROUTINE seed_sample_two_segment(a, td, b, s)
    !! Fine polyline of the two-segment touchdown shape: straight span a -> td, straight
    !! grounded run td -> b, sampled at uniform t so the touchdown corner is CHORDED
    !! across ~one sample spacing -- a DELIBERATE fillet. The fillet shortens the table by
    !! O(1e-4) relative (the isometry tolerance the builder asserts). An exact-corner variant
    !! (touchdown as an exact sample, table isometric to round-off) is far less robust on the
    !! initialization stress matrix: the exact corner seeds a node-scale kink at the
    !! touchdown that Newton walks into wadded local equilibria, while the one-sample fillet
    !! approximates the true bending boundary layer. Global isometry within tolerance + a
    !! local fillet is the robust combination.
    REAL(wp), INTENT(IN) :: a(3), td(3), b(3)
    REAL(wp), INTENT(OUT) :: s(:, :)
    REAL(wp) :: len1, len2, t, split
    INTEGER :: k, nsl
    nsl = SIZE(s, 2)
    len1 = SQRT(SUM((td - a)**2))
    len2 = SQRT(SUM((b - td)**2))
    split = len1/MAX(len1 + len2, 1.0e-30_wp)
    DO k = 1, nsl
      t = REAL(k - 1, wp)/REAL(nsl - 1, wp)
      IF (t <= split) THEN
        s(:, k) = a + (td - a)*(t/MAX(split, 1.0e-30_wp))
      ELSE
        s(:, k) = td + (b - td)*((t - split)/MAX(CD_ONE - split, 1.0e-30_wp))
      END IF
    END DO
  END SUBROUTINE seed_sample_two_segment

  SUBROUTINE seed_sample_double_touchdown(a, b, e_h, target, floor_z, s, es_b, em_b)
    !! Isometric seed for a slack line whose two endpoints are above the seabed.
    !! For target lengths between the reflected shortest bed-touching path and the
    !! vertical-leg/grounded-run path, move two touchdown points monotonically apart.
    !! Beyond that limit, keep vertical legs and place the surplus in a smooth
    !! non-negative vertical bow over the middle run. Bisections measure the exact
    !! sampled table subsequently returned, so the caller's isometry assertion remains
    !! the governing contract rather than an analytic approximation.
    REAL(wp), INTENT(IN) :: a(3), b(3), e_h(3), target, floor_z
    REAL(wp), INTENT(OUT) :: s(:, :)
    INTEGER, INTENT(OUT) :: es_b
    CHARACTER(*), INTENT(OUT) :: em_b

    REAL(wp) :: xspan, ha, hb, href, lmin, lbase, lo, hi, mid, measured, spread
    REAL(wp) :: td1(3), td2(3)
    INTEGER :: it

    es_b = CD_HCSTAT_OK; em_b = ''
    xspan = SQRT((b(1) - a(1))**2 + (b(2) - a(2))**2)
    ha = a(3) - floor_z; hb = b(3) - floor_z
    IF (ha <= CD_ZERO .OR. hb <= CD_ZERO) THEN
      CALL fail_double('double-touchdown geometry requires endpoints above the bed'); RETURN
    END IF
    IF (xspan <= 1.0e-12_wp*MAX(target, CD_ONE)) THEN
      ! Vertically aligned endpoints have no preferred horizontal touchdown
      ! direction (e_h carries the deterministic fallback selected by the caller).
      ! Spread the two bed contacts symmetrically until the three-segment length
      ! matches target; unlike a straight grounded run this construction has no
      ! finite upper-length limit.
      IF (target < (ha + hb)*(CD_ONE - 1.0e-9_wp)) THEN
        CALL fail_double('line is too short to reach the seabed from both endpoints'); RETURN
      END IF
      lo = CD_ZERO; hi = MAX(target, ha + hb)
      DO it = 1, 60
        IF (vertical_double_length(hi, ha, hb) >= target) EXIT
        hi = 2.0_wp*hi
      END DO
      DO it = 1, 80
        mid = 0.5_wp*(lo + hi)
        IF (vertical_double_length(mid, ha, hb) < target) THEN
          lo = mid
        ELSE
          hi = mid
        END IF
      END DO
      spread = hi
      td1 = a + 0.5_wp*spread*e_h; td1(3) = floor_z
      td2 = b - 0.5_wp*spread*e_h; td2(3) = floor_z
      CALL fill_three_segment(a, td1, td2, b, target, s)
      RETURN
    END IF
    href = xspan*ha/(ha + hb)
    lmin = SQRT(xspan*xspan + (ha + hb)**2)
    lbase = xspan + ha + hb
    IF (target < lmin*(CD_ONE - 1.0e-9_wp)) THEN
      CALL fail_double('line is too short to reach the seabed from both endpoints'); RETURN
    END IF

    IF (target <= lbase) THEN
      lo = CD_ZERO; hi = CD_ONE
      DO it = 1, 80
        mid = 0.5_wp*(lo + hi)
        measured = double_touch_polyline_length(xspan, ha, hb, href, mid)
        IF (measured < target) THEN
          lo = mid
        ELSE
          hi = mid
        END IF
      END DO
      CALL fill_double_touchdown(a, b, e_h, floor_z, target, href, hi, CD_ZERO, .FALSE., s)
    ELSE
      ! Solve the middle-bow amplitude against the same discretized table returned
      ! below. This absorbs arbitrary surplus without sending any seed point below
      ! the bed; the heavy-line continuation subsequently settles it onto contact.
      lo = CD_ZERO; hi = MAX(xspan, target - lbase)
      DO it = 1, 60
        CALL fill_double_touchdown(a, b, e_h, floor_z, target, href, CD_ONE, hi, .TRUE., s)
        IF (sample_curve_length(s) >= target) EXIT
        hi = 2.0_wp*hi
      END DO
      IF (sample_curve_length(s) < target) THEN
        CALL fail_double('middle-bow amplitude bracket failed'); RETURN
      END IF
      DO it = 1, 80
        mid = 0.5_wp*(lo + hi)
        CALL fill_double_touchdown(a, b, e_h, floor_z, target, href, CD_ONE, mid, .TRUE., s)
        IF (sample_curve_length(s) < target) THEN
          lo = mid
        ELSE
          hi = mid
        END IF
      END DO
      CALL fill_double_touchdown(a, b, e_h, floor_z, target, href, CD_ONE, hi, .TRUE., s)
    END IF

  CONTAINS
    SUBROUTINE fail_double(msg)
      CHARACTER(*), INTENT(IN) :: msg
      es_b = CD_HCSTAT_BADINPUT
      em_b = 'CD_HermiteCable_Trivial_Seed: '//msg
    END SUBROUTINE fail_double
  END SUBROUTINE seed_sample_double_touchdown

  PURE FUNCTION double_touch_polyline_length(xspan, ha, hb, href, alpha) RESULT(length)
    REAL(wp), INTENT(IN) :: xspan, ha, hb, href, alpha
    REAL(wp) :: length, x1, x2
    x1 = href*(CD_ONE - alpha)
    x2 = href + alpha*(xspan - href)
    length = SQRT(x1*x1 + ha*ha) + (x2 - x1) + SQRT((xspan - x2)**2 + hb*hb)
  END FUNCTION double_touch_polyline_length

  PURE FUNCTION vertical_double_length(spread, ha, hb) RESULT(length)
    REAL(wp), INTENT(IN) :: spread, ha, hb
    REAL(wp) :: length
    length = SQRT((0.5_wp*spread)**2 + ha*ha) + spread + &
             SQRT((0.5_wp*spread)**2 + hb*hb)
  END FUNCTION vertical_double_length

  PURE SUBROUTINE fill_three_segment(a, td1, td2, b, target, s)
    REAL(wp), INTENT(IN) :: a(3), td1(3), td2(3), b(3), target
    REAL(wp), INTENT(OUT) :: s(:, :)
    REAL(wp) :: l1, l2, l3, station
    INTEGER :: k
    l1 = SQRT(SUM((td1 - a)**2)); l2 = SQRT(SUM((td2 - td1)**2)); l3 = SQRT(SUM((b - td2)**2))
    DO k = 1, SIZE(s, 2)
      station = target*REAL(k - 1, wp)/REAL(SIZE(s, 2) - 1, wp)
      IF (station <= l1) THEN
        s(:, k) = a + (td1 - a)*(station/l1)
      ELSE IF (station < l1 + l2) THEN
        s(:, k) = td1 + (td2 - td1)*((station - l1)/l2)
      ELSE
        s(:, k) = td2 + (b - td2)*((station - l1 - l2)/l3)
      END IF
    END DO
    s(:, 1) = a; s(:, SIZE(s, 2)) = b
  END SUBROUTINE fill_three_segment

  PURE SUBROUTINE fill_double_touchdown(a, b, e_h, floor_z, target, href, alpha, amp, bowed, s)
    REAL(wp), INTENT(IN) :: a(3), b(3), e_h(3), floor_z, target, href, alpha, amp
    LOGICAL, INTENT(IN) :: bowed
    REAL(wp), INTENT(OUT) :: s(:, :)
    REAL(wp), PARAMETER :: PI_L = ACOS(-1.0_wp)
    REAL(wp) :: xspan, ha, hb, x1, x2, l1, lm, l3, station, u
    REAL(wp) :: td1(3), td2(3)
    INTEGER :: k

    xspan = SQRT((b(1) - a(1))**2 + (b(2) - a(2))**2)
    ha = a(3) - floor_z; hb = b(3) - floor_z
    x1 = href*(CD_ONE - alpha)
    x2 = href + alpha*(xspan - href)
    td1 = a + e_h*x1; td1(3) = floor_z
    td2 = a + e_h*x2; td2(3) = floor_z
    l1 = SQRT(x1*x1 + ha*ha)
    l3 = SQRT((xspan - x2)**2 + hb*hb)
    lm = target - l1 - l3
    DO k = 1, SIZE(s, 2)
      station = target*REAL(k - 1, wp)/REAL(SIZE(s, 2) - 1, wp)
      IF (station <= l1) THEN
        s(:, k) = a + (td1 - a)*(station/l1)
      ELSE IF (station < l1 + lm) THEN
        u = (station - l1)/lm
        s(:, k) = td1 + (td2 - td1)*u
        IF (bowed) s(3, k) = s(3, k) + amp*SIN(PI_L*u)**2
      ELSE
        s(:, k) = td2 + (b - td2)*((station - l1 - lm)/l3)
      END IF
    END DO
    s(:, 1) = a; s(:, SIZE(s, 2)) = b
  END SUBROUTINE fill_double_touchdown

  PURE FUNCTION sample_curve_length(s) RESULT(length)
    REAL(wp), INTENT(IN) :: s(:, :)
    REAL(wp) :: length
    INTEGER :: k
    length = CD_ZERO
    DO k = 2, SIZE(s, 2)
      length = length + SQRT(SUM((s(:, k) - s(:, k - 1))**2))
    END DO
  END FUNCTION sample_curve_length

  PURE FUNCTION seed_bowed_leg_length(a, leg_end, n_hat, h, nleg) RESULT(lenh)
    !! Sampled polyline length of the sine-bowed leg at depth h (the same sampling the
    !! final polyline uses, so the bisection target and the built shape agree exactly).
    REAL(wp), INTENT(IN) :: a(3), leg_end(3), n_hat(3), h
    INTEGER, INTENT(IN) :: nleg
    REAL(wp) :: lenh, tt, p_prev(3), p_cur(3)
    REAL(wp), PARAMETER :: PI_L = ACOS(-1.0_wp)
    INTEGER :: kk
    lenh = CD_ZERO
    p_prev = a
    DO kk = 2, nleg
      tt = REAL(kk - 1, wp)/REAL(nleg - 1, wp)
      p_cur = a + (leg_end - a)*tt + n_hat*(h*SIN(PI_L*tt))
      lenh = lenh + SQRT(SUM((p_cur - p_prev)**2))
      p_prev = p_cur
    END DO
  END FUNCTION seed_bowed_leg_length

  SUBROUTINE seed_sample_bowed_leg(a, leg_end, n_hat, leg_target, b, with_run, s, es_b, em_b)
    !! Fine polyline of a sine-bowed leg a -> leg_end (perpendicular direction n_hat,
    !! depth solved by bisection so the leg's polyline length hits leg_target), plus,
    !! when with_run, the straight grounded run leg_end -> b. Fails closed if no
    !! bracketing depth exists (leg_target below the leg chord cannot happen for the
    !! slack callers; the guard keeps the bisection fail-closed regardless).
    REAL(wp), INTENT(IN) :: a(3), leg_end(3), n_hat(3), leg_target, b(3)
    LOGICAL, INTENT(IN) :: with_run
    REAL(wp), INTENT(OUT) :: s(:, :)
    INTEGER, INTENT(OUT) :: es_b
    CHARACTER(*), INTENT(OUT) :: em_b
    REAL(wp), PARAMETER :: PI_L = ACOS(-1.0_wp)
    REAL(wp) :: leg_chord, run_len, split, h_lo, h_hi, h_mid, t
    INTEGER :: k, nsl, nleg, itb
    es_b = CD_HCSTAT_OK
    em_b = ''
    nsl = SIZE(s, 2)
    leg_chord = SQRT(SUM((leg_end - a)**2))
    run_len = CD_ZERO
    IF (with_run) run_len = SQRT(SUM((b - leg_end)**2))
    split = leg_target/MAX(leg_target + run_len, 1.0e-30_wp)
    nleg = MAX(2, MIN(nsl - 1, NINT(split*REAL(nsl - 1, wp)) + 1))
    IF (leg_target < leg_chord*(CD_ONE - 1.0e-9_wp)) THEN
      es_b = CD_HCSTAT_BADINPUT
      em_b = 'CD_HermiteCable_Trivial_Seed: bowed-leg target below its chord'
      RETURN
    END IF
    ! bracket the bow depth, then bisect on the sampled leg length
    h_lo = CD_ZERO
    h_hi = MAX(leg_chord, leg_target)
    DO itb = 1, 60
      IF (seed_bowed_leg_length(a, leg_end, n_hat, h_hi, nleg) >= leg_target) EXIT
      h_hi = 2.0_wp*h_hi
    END DO
    IF (seed_bowed_leg_length(a, leg_end, n_hat, h_hi, nleg) < leg_target) THEN
      es_b = CD_HCSTAT_BADINPUT
      em_b = 'CD_HermiteCable_Trivial_Seed: bow-depth bracket failed'
      RETURN
    END IF
    DO itb = 1, 80
      h_mid = 0.5_wp*(h_lo + h_hi)
      IF (seed_bowed_leg_length(a, leg_end, n_hat, h_mid, nleg) < leg_target) THEN
        h_lo = h_mid
      ELSE
        h_hi = h_mid
      END IF
      IF (h_hi - h_lo <= 1.0e-9_wp*MAX(leg_target, CD_ONE)) EXIT
    END DO
    h_mid = h_hi   ! never-shorter side of the bracket (tension, not compression)
    DO k = 1, nleg
      t = REAL(k - 1, wp)/REAL(nleg - 1, wp)
      s(:, k) = a + (leg_end - a)*t + n_hat*(h_mid*SIN(PI_L*t))
    END DO
    DO k = nleg + 1, nsl
      t = REAL(k - nleg, wp)/REAL(nsl - nleg, wp)
      s(:, k) = leg_end + (b - leg_end)*t
    END DO
  END SUBROUTINE seed_sample_bowed_leg

  PURE FUNCTION seed_landing_leg_length(a, e_h, x_t1, h_a, x_amp, nleg) RESULT(lenh)
    !! Sampled polyline length of the quarter-ellipse landing leg with a sin^2-windowed
    !! in-plane bulge of amplitude x_amp (the same sampling the final polyline uses; the
    !! last sample is the touchdown by construction).
    REAL(wp), INTENT(IN) :: a(3), e_h(3), x_t1, h_a, x_amp
    INTEGER, INTENT(IN) :: nleg
    REAL(wp) :: lenh, tt, p_prev(3), p_cur(3)
    REAL(wp), PARAMETER :: PI_L = ACOS(-1.0_wp)
    INTEGER :: kk
    lenh = CD_ZERO
    p_prev = a
    DO kk = 2, nleg
      tt = REAL(kk - 1, wp)/REAL(nleg - 1, wp)
      p_cur = a + e_h*(x_t1*(CD_ONE - COS(0.5_wp*PI_L*tt)) + x_amp*SIN(PI_L*tt)**2) &
              - [CD_ZERO, CD_ZERO, h_a*SIN(0.5_wp*PI_L*tt)]
      lenh = lenh + SQRT(SUM((p_cur - p_prev)**2))
      p_prev = p_cur
    END DO
  END FUNCTION seed_landing_leg_length

  SUBROUTINE seed_sample_landing_leg(a, td, e_h, leg_target, b, s, es_b, em_b)
    !! Fine polyline of the very-slack landing leg a -> td (quarter-ellipse: vertical
    !! launch at a, tangentially horizontal touchdown at td, so the junction with the
    !! grounded run carries no corner) whose excess length beyond the ellipse arc lives
    !! in a sin^2(pi t)-windowed bulge along e_h (both end tangents untouched, z
    !! untouched -- the leg never dips below the touchdown level), amplitude solved by
    !! bisection on the sampled polyline length; plus the straight grounded run td -> b.
    !! By convexity the quarter-ellipse arc is below x_t1 + h_a <= leg_target in the
    !! very-slack regime, so the bracket always opens from amplitude zero.
    REAL(wp), INTENT(IN) :: a(3), td(3), e_h(3), leg_target, b(3)
    REAL(wp), INTENT(OUT) :: s(:, :)
    INTEGER, INTENT(OUT) :: es_b
    CHARACTER(*), INTENT(OUT) :: em_b
    REAL(wp), PARAMETER :: PI_L = ACOS(-1.0_wp)
    REAL(wp) :: x_t1, h_a, run_len, split, a_lo, a_hi, a_mid, t
    INTEGER :: k, nsl, nleg, itb
    es_b = CD_HCSTAT_OK
    em_b = ''
    nsl = SIZE(s, 2)
    x_t1 = DOT_PRODUCT(td - a, e_h)
    h_a = a(3) - td(3)
    run_len = SQRT(SUM((b - td)**2))
    split = leg_target/MAX(leg_target + run_len, 1.0e-30_wp)
    nleg = MAX(2, MIN(nsl - 1, NINT(split*REAL(nsl - 1, wp)) + 1))
    IF (x_t1 < -1.0e-9_wp*MAX(leg_target, CD_ONE) .OR. h_a <= CD_ZERO) THEN
      es_b = CD_HCSTAT_BADINPUT
      em_b = 'CD_HermiteCable_Trivial_Seed: landing-leg geometry degenerate'
      RETURN
    END IF
    IF (seed_landing_leg_length(a, e_h, x_t1, h_a, CD_ZERO, nleg) > leg_target) THEN
      es_b = CD_HCSTAT_BADINPUT
      em_b = 'CD_HermiteCable_Trivial_Seed: landing-leg target below the ellipse arc'
      RETURN
    END IF
    ! bracket the bulge amplitude, then bisect on the sampled leg length
    a_lo = CD_ZERO
    a_hi = MAX(h_a, leg_target)
    DO itb = 1, 60
      IF (seed_landing_leg_length(a, e_h, x_t1, h_a, a_hi, nleg) >= leg_target) EXIT
      a_hi = 2.0_wp*a_hi
    END DO
    IF (seed_landing_leg_length(a, e_h, x_t1, h_a, a_hi, nleg) < leg_target) THEN
      es_b = CD_HCSTAT_BADINPUT
      em_b = 'CD_HermiteCable_Trivial_Seed: bulge-amplitude bracket failed'
      RETURN
    END IF
    DO itb = 1, 80
      a_mid = 0.5_wp*(a_lo + a_hi)
      IF (seed_landing_leg_length(a, e_h, x_t1, h_a, a_mid, nleg) < leg_target) THEN
        a_lo = a_mid
      ELSE
        a_hi = a_mid
      END IF
      IF (a_hi - a_lo <= 1.0e-9_wp*MAX(leg_target, CD_ONE)) EXIT
    END DO
    a_mid = a_hi   ! never-shorter side of the bracket (tension, not compression)
    DO k = 1, nleg
      t = REAL(k - 1, wp)/REAL(nleg - 1, wp)
      s(:, k) = a + e_h*(x_t1*(CD_ONE - COS(0.5_wp*PI_L*t)) + a_mid*SIN(PI_L*t)**2) &
                - [CD_ZERO, CD_ZERO, h_a*SIN(0.5_wp*PI_L*t)]
    END DO
    s(:, nleg) = td
    DO k = nleg + 1, nsl
      t = REAL(k - nleg, wp)/REAL(nsl - nleg, wp)
      s(:, k) = td + (b - td)*t
    END DO
  END SUBROUTINE seed_sample_landing_leg

  PURE FUNCTION seed_interp_arc(s, a_tab, s_i) RESULT(p)
    !! Linear interpolation of the sampled polyline at arc station s_i.
    REAL(wp), INTENT(IN) :: s(:, :), a_tab(:), s_i
    REAL(wp) :: p(3), t
    INTEGER :: lo, hi, mid
    IF (s_i <= a_tab(1)) THEN
      p = s(:, 1); RETURN
    END IF
    IF (s_i >= a_tab(SIZE(a_tab))) THEN
      p = s(:, SIZE(a_tab)); RETURN
    END IF
    lo = 1
    hi = SIZE(a_tab)
    DO WHILE (hi - lo > 1)
      mid = (lo + hi)/2
      IF (a_tab(mid) <= s_i) THEN
        lo = mid
      ELSE
        hi = mid
      END IF
    END DO
    t = (s_i - a_tab(lo))/MAX(a_tab(hi) - a_tab(lo), 1.0e-30_wp)
    p = s(:, lo) + (s(:, hi) - s(:, lo))*t
  END FUNCTION seed_interp_arc

  PURE REAL(wp) FUNCTION CD_Arclength_Dot(wq, a, al, b, bl) RESULT(d)
    !! Inner product of two path vectors (a, al) and (b, bl) of the pseudo-arclength
    !! continuation in (q, lambda): d = wq^2 a.b + al*bl, the positions weighted by wq
    !! (the inverse line length) so that they compare with the load fraction lambda.
    REAL(wp), INTENT(IN) :: wq, a(:), al, b(:), bl
    d = wq*wq*DOT_PRODUCT(a, b) + al*bl
  END FUNCTION CD_Arclength_Dot

  PURE SUBROUTINE CD_Arclength_Unit_Tangent(wq, tq, tl)
    !! Normalise the path tangent (dq/dlambda, 1) to unit length in the metric of
    !! CD_Arclength_Dot. On entry tq = dq/dlambda; on exit (tq, tl) is the unit tangent.
    REAL(wp), INTENT(IN) :: wq
    REAL(wp), INTENT(INOUT) :: tq(:)
    REAL(wp), INTENT(OUT) :: tl
    REAL(wp) :: nrm
    nrm = SQRT(wq*wq*DOT_PRODUCT(tq, tq) + CD_ONE)
    tq = tq/nrm
    tl = CD_ONE/nrm
  END SUBROUTINE CD_Arclength_Unit_Tangent

  PURE SUBROUTINE CD_Arclength_Bordered_Update(wq, tq, tl, g, z1, z2, qc, lamc, ErrStat)
    !! One corrector update of the bordered system
    !!   [ K       -D ] [dq  ]   [ -F ]
    !!   [ wq^2 tq  tl] [dlam] = [ -g ]
    !! by block elimination, given z1 = -K^-1 F and z2 = K^-1 D: dq = z1 + dlam z2 with
    !! dlam = (-g - wq^2 tq.z1)/(wq^2 tq.z2 + tl). g is the distance of the current
    !! point from the predictor's hyperplane (CD_Arclength_Dot of tq with qc - qp).
    !! ErrStat = 1 (no update) when the bordered row is singular or the update not finite.
    REAL(wp), INTENT(IN) :: wq, tq(:), tl, g, z1(:), z2(:)
    REAL(wp), INTENT(INOUT) :: qc(:), lamc
    INTEGER, INTENT(OUT) :: ErrStat
    REAL(wp) :: nrm, dlam
    ErrStat = 1
    nrm = CD_Arclength_Dot(wq, tq, tl, z2, CD_ONE)
    IF (.NOT. (ABS(nrm) >= TINY(CD_ONE))) RETURN
    dlam = (-g - CD_Arclength_Dot(wq, tq, tl, z1, CD_ZERO))/nrm
    IF (.NOT. CD_Is_Finite(dlam)) RETURN
    qc = qc + z1 + dlam*z2
    lamc = lamc + dlam
    IF (.NOT. CD_All_Finite(qc)) RETURN
    ErrStat = 0
  END SUBROUTINE CD_Arclength_Bordered_Update

END MODULE CableDyn_HermiteCableStatic
