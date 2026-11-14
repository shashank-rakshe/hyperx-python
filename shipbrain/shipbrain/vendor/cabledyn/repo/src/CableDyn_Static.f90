! File: src/CableDyn_Static.f90
! SPDX-License-Identifier: Apache-2.0
! Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
MODULE CableDyn_Static
  !! Static Newton-Raphson + Armijo solver for the positions-only EI=0 cable path.
  !! Given an initial guess, a constant external load f_ext
  !! (e.g. gravity from CableDyn_Loads), the prescribed (Dirichlet) DOFs, and an
  !! OPTIONAL penalty seabed,
  !! drive the residual R = f_int(q) - f_ext - f_seabed(q) to zero on the free DOFs by
  !! Newton iteration with an Armijo backtracking line search on the 1/2||R||^2 merit.
  !! The free-DOF tangent block is assembled directly in reduced LAPACK band storage
  !! (element, seabed and drag contributions alike) and solved with DGBSV, so every
  !! Newton iteration costs O(n_dof * bandwidth) in time and memory.
  !!
  !! When the OPTIONAL seabed arguments are present, the configuration-dependent
  !! penalty contact force + its residual-Jacobian term are recomputed inside every
  !! residual/tangent evaluation (grounded catenary / mooring equilibrium); when
  !! absent it is the constant-f_ext solve, bit-for-bit unchanged. An OPTIONAL
  !! steady current adds configuration-dependent Morison drag (CableCurrentLoad), and the
  !! same object carries the static seabed friction (friction springs from the as-laid
  !! position, CD_Static_As_Laid_Reference), with or without the drag. Damping and wave
  !! loads belong to the dynamic path.
  !!
  !! Conventions match the other modules: q is the flat (3 n_nodes) positions-only
  !! state [x1,y1,z1, x2,y2,z2, ...]; node nd owns DOFs 3*nd-2:3*nd; fixed_dofs are
  !! 1-based global DOF indices held at their q0 value.
  USE CableDyn_Precision, ONLY: wp, CD_ZERO, CD_ONE, CD_All_Finite, CD_Is_Finite
  USE CableDyn_Assemble, ONLY: CD_Assemble_Cable_Tangent_Force_Banded_Free, CD_Assemble_Cable_Internal_Force, &
                               CD_Cable_Free_Bandwidth, CD_Compute_Cable_Tension
  USE CableDyn_SeabedContact, ONLY: CD_Seabed_Normal_Law, CD_Seabed_Normal_Contact, CD_SEABED_CONTACT_BLEND, &
                                    CD_Seabed_Friction_Spring, CD_Seabed_Friction_Aniso, CD_Seabed_Friction_Mu_Dir, &
                                    CD_FRICTION_SPRING
  USE CableDyn_Bathymetry, ONLY: CD_BathymetryType, CD_Bathymetry_Is_Initialized, &
                                 CD_Bathymetry_Floor_Gradient, CD_BATHY_OK
  USE CableDyn_Hydro, ONLY: CD_Cable_Morison_Drag_Force, CD_Morison_Drag_Element_Load, CD_Current_Profile_Velocity, &
                            CD_CurrentGridType, CD_Current_Grid_Velocity, CD_Current_Grid_Gradient, &
                            CD_Current_Profile_Gradient, CD_Buoyancy_Recovery_Element_Force, CD_HYDRO_OK
  USE CableDyn_Linalg, ONLY: CD_Solve_Banded
  USE CableDyn_Mesh, ONLY: CD_Partition_Free_Dofs
  USE CableDyn_Catenary, ONLY: CD_Catenary_Seed, CD_CAT_OK
  IMPLICIT NONE
  PRIVATE

  PUBLIC :: CableSolverConfig
  PUBLIC :: CableCurrentLoad
  PUBLIC :: CD_StaticLineReport
  PUBLIC :: CD_Static_Cable_Solve
  PUBLIC :: CD_Static_Cable_Solve_Continuation
  PUBLIC :: CD_Static_Line_Equilibrium
  PUBLIC :: CD_Static_Line_End_Forces
  PUBLIC :: CD_Static_Line_Dry_Load
  PUBLIC :: CD_Static_Anchor_Seabed_Tolerance
  PUBLIC :: CD_Static_Friction_Anchors
  PUBLIC :: CD_Static_As_Laid_Reference

  TYPE :: CableSolverConfig
    !! Newton / Armijo policy and its default tolerances.
    REAL(wp) :: rel_tol = 1.0e-8_wp               !! ||R||/scale gate
    REAL(wp) :: abs_tol = 1.0e-14_wp              !! absolute ||R|| gate / scale floor
    INTEGER  :: max_iter = 50
    REAL(wp) :: armijo_c1 = 1.0e-4_wp             !! sufficient-decrease constant
    INTEGER  :: armijo_max_backtracks = 8
    REAL(wp) :: stall_rel_tol = 1.0e-6_wp         !! "at the round-off floor" threshold
    INTEGER  :: stall_window = 3                  !! flat-residual window length
  END TYPE CableSolverConfig

  TYPE :: CableCurrentLoad
    !! A steady current as a configuration-dependent Morison drag load on the static EI=0
    !! cable solve. At static equilibrium the cable is at rest, so the relative fluid
    !! velocity is the current itself; the drag force and its -d(force)/dq Jacobian
    !! (CableDyn_Hydro) enter every residual/tangent evaluation. The current is uniform
    !! (velocity), given per node (node_velocity) or as a depth profile re-sampled at the
    !! node elevations (profile_z/profile_velocity); the hydrodynamics are one
    !! diameter/drag set or per element (elem_diameter/elem_cdn/elem_cdt). Seabed friction
    !! held against the current is optional (friction_mu, friction_ref).
    REAL(wp) :: velocity(3) = CD_ZERO   !! uniform current velocity vector [m/s]
    REAL(wp) :: rho = CD_ZERO           !! water density [kg/m^3]
    REAL(wp) :: diameter = CD_ZERO      !! hydrodynamic diameter [m]
    REAL(wp) :: cdn = CD_ZERO           !! normal drag coefficient
    REAL(wp) :: cdt = CD_ZERO           !! tangential drag coefficient
    REAL(wp) :: waterline_z = CD_ZERO   !! still-water surface elevation [m]
    ! Optional per-node / per-element overrides (a depth profile sampled at the nodes, and a
    ! composite line's per-section hydrodynamics). When node_velocity is allocated it replaces
    ! velocity; when elem_diameter is allocated, elem_cdn/elem_cdt must be too and they replace
    ! the scalar diameter/cdn/cdt element by element.
    REAL(wp), ALLOCATABLE :: node_velocity(:, :)   !! (3, n_nodes) current at each node [m/s]
    REAL(wp), ALLOCATABLE :: elem_diameter(:)      !! (n_elem) hydrodynamic diameter [m]
    REAL(wp), ALLOCATABLE :: elem_cdn(:), elem_cdt(:)  !! (n_elem) drag coefficients
    REAL(wp), ALLOCATABLE :: node_waterline(:)     !! (n_nodes) waterline per node, replaces waterline_z
    ! A depth profile (levels profile_z strictly increasing, velocities profile_velocity(3, :)):
    ! when allocated, each node's current is re-sampled at the node's own elevation in every
    ! residual evaluation (the dynamic march samples it at the actual node depths too), so the
    ! static state is an equilibrium of the marched model. It replaces node_velocity/velocity.
    REAL(wp), ALLOCATABLE :: profile_z(:), profile_velocity(:, :)
    ! A current grid in space and time (MoorDyn-C Currents 2 and 5, CD_CurrentGridType): when
    ! allocated, each node's current is its value at the node's own position at t = 0 (the
    ! static start), re-sampled in every residual evaluation like the depth profile, which it
    ! replaces.
    TYPE(CD_CurrentGridType), ALLOCATABLE :: grid
    ! drag = .FALSE.: the object carries only the static seabed friction below (a line in
    ! still water); the drag fields are then ignored and need not be set.
    LOGICAL :: drag = .TRUE.
    ! Static seabed friction (friction_mu > 0 with friction_ref allocated, on a line with
    ! seabed contact): each node in contact carries a horizontal spring of its seabed
    ! stiffness from its reference position friction_ref(1:2, node), capped smoothly at
    ! friction_mu times its normal reaction (CD_Seabed_Friction_Spring). The reference is the
    ! still-water equilibrium in a current (staticsFriction none), or the as-laid position of
    ! the line (friction_as_laid, CD_Static_As_Laid_Reference), which also selects the
    ! as-laid seed.
    REAL(wp) :: friction_mu = CD_ZERO
    REAL(wp), ALLOCATABLE :: friction_ref(:, :)
    LOGICAL :: friction_as_laid = .FALSE.
    ! friction_mu_axial > 0 and different from friction_mu: anisotropic friction, with
    ! friction_mu the lateral coefficient (CD_Seabed_Friction_Aniso, line axis = chord
    ! through the neighbouring nodes).
    REAL(wp) :: friction_mu_axial = -1.0_wp
  END TYPE CableCurrentLoad

  TYPE :: CD_StaticLineReport
    !! Outcome of CD_Static_Line_Equilibrium: which seed and solver stage produced the accepted
    !! equilibrium (or the last failure), for diagnostics and fail-closed error messages.
    CHARACTER(64)  :: seed = ''          !! seed of the accepted (or last attempted) solve
    CHARACTER(64)  :: stage = ''         !! solver stage of the accepted (or last failed) solve
    CHARACTER(560) :: message = ''       !! outcome / failure reason (holds the bounded seed notes whole)
    INTEGER  :: n_iter = 0               !! Newton iterations over every attempt
    REAL(wp) :: min_tension = CD_ZERO    !! smallest element tension of the reported state [N]
    LOGICAL  :: slack_branch = .FALSE.   !! .TRUE. when the tension-only (slack-capable) solve was needed
  END TYPE CD_StaticLineReport

  ! ErrStat codes: 0 success; 1 invalid input; 2 singular/ill-conditioned tangent.
  INTEGER, PARAMETER, PUBLIC :: CD_STATIC_OK = 0
  INTEGER, PARAMETER, PUBLIC :: CD_STATIC_BADINPUT = 1
  INTEGER, PARAMETER, PUBLIC :: CD_STATIC_SINGULAR = 2
  ! Static seabed friction policies (OrcaFlex "statics seabed friction policy"): none, or
  ! friction toward the as-laid position (CD_Static_As_Laid_Reference).
  INTEGER, PARAMETER, PUBLIC :: CD_STATIC_FRICTION_NONE = 0
  INTEGER, PARAMETER, PUBLIC :: CD_STATIC_FRICTION_AS_LAID = 1

CONTAINS

  SUBROUTINE CD_Static_Cable_Solve(q0, elem_conn, l0, ea, tension_only, f_ext, fixed_dofs, &
                                   cfg, q, converged, stalled, at_floor, n_iter, ErrStat, ErrMsg, &
                                   seabed_z_floor, seabed_kn, current, current_load_factor, bathymetry, &
                                   regularized, compression_ratio)
    !! Solve EI=0 cable equilibrium. With the OPTIONAL seabed arguments present, a
    !! penalty seabed contact load is included in every residual/tangent evaluation
    !! (grounded catenary / mooring); without them it is the constant-f_ext solve.
    !! On a singular tangent (tension-only slack, etc.) returns
    !! ErrStat = CD_STATIC_SINGULAR; on a line-search/flat-residual stall returns
    !! converged=.FALSE., stalled=.TRUE. (at_floor flags a round-off-floor stall).
    !! ``q`` holds the (best) state in every exit path.
    !!
    !! Seabed:
    !! per node the C1 normal contact law (CD_Seabed_Normal_Law, along the floor normal on
    !! a bathymetry slope), added to f_ext with its residual-Jacobian term in the tangent.
    !! ``seabed_kn`` is per-node (n_nodes); pass both seabed args or neither.
    !!
    !! regularized (default .FALSE.): Levenberg-Marquardt globalization. The Newton system
    !! is shifted to (K_t + mu*kappa*I) dq = -R, kappa = max|T|/min(l0) the geometric
    !! stiffness scale of the line; mu shrinks by 4 after a full accepted step (towards the
    !! plain Newton step, so local convergence is unchanged), doubles after a backtracked
    !! one, and grows by 16 when the line search finds no descent (the step is retried
    !! rather than declared a stall). A penalty seabed makes the residual only piecewise
    !! smooth: every node that crosses the seabed plane kinks it, the plain Newton step
    !! overshoots each kink and Armijo cuts it to a few percent, so a touchdown that must
    !! migrate over many elements (a fine mesh of a stiff line) exhausts the plain solve.
    !! The shifted steps stay inside the region where the linearization holds. The flat-
    !! residual stall test is not applied and the iteration budget is 8*max_iter.
    !!
    !! compression_ratio r (optional, in [0, 1]): the slack-capable tension-only law used for
    !! the physical static equilibrium of an EI=0 line. An element carries T = EA eps in
    !! tension and T = r EA eps in compression (tension_only is then ignored): r = 0 is the
    !! exact tension-only law, r = 1 the compression-capable one, and a small r > 0 keeps a
    !! slack element's tangent non-singular while its compressive force stays negligible.
    !! Slack elements can leave directions without stiffness (a grounded node between two
    !! slack elements slides freely on a frictionless seabed), so in this mode the
    !! Levenberg-Marquardt shift never drops below a small floor.
    REAL(wp), INTENT(IN)  :: q0(:)              !! initial guess, (3 n_nodes)
    INTEGER, INTENT(IN)  :: elem_conn(:, :)    !! (2, n_elem), 1-based
    REAL(wp), INTENT(IN)  :: l0(:), ea(:)       !! (n_elem) unstretched lengths / EA
    LOGICAL, INTENT(IN)  :: tension_only
    REAL(wp), INTENT(IN)  :: f_ext(:)           !! constant external load, (3 n_nodes)
    INTEGER, INTENT(IN)  :: fixed_dofs(:)      !! 1-based prescribed DOF indices
    TYPE(CableSolverConfig), INTENT(IN) :: cfg
    REAL(wp), INTENT(OUT) :: q(:)               !! solution / best state, (3 n_nodes)
    LOGICAL, INTENT(OUT) :: converged, stalled, at_floor
    INTEGER, INTENT(OUT) :: n_iter, ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    REAL(wp), INTENT(IN), OPTIONAL :: seabed_z_floor   !! seabed plane elevation [m]
    REAL(wp), INTENT(IN), OPTIONAL :: seabed_kn(:)     !! per-node penalty stiffness (n_nodes) [N/m]
    TYPE(CableCurrentLoad), INTENT(IN), OPTIONAL :: current  !! steady current drag load
    REAL(wp), INTENT(IN), OPTIONAL :: current_load_factor    !! drag ramp in (0, 1] (default 1)
    TYPE(CD_BathymetryType), INTENT(IN), OPTIONAL :: bathymetry !! variable seabed elevation service
    LOGICAL, INTENT(IN), OPTIONAL :: regularized        !! Levenberg-Marquardt globalization
    REAL(wp), INTENT(IN), OPTIONAL :: compression_ratio !! slack-capable tension-only law ratio r

    INTEGER  :: n_dof, n_elem, n_nodes, n_free, iteration, k, bt, kl, ku, ldab
    INTEGER, ALLOCATABLE :: free(:), free_of(:)
    REAL(wp), ALLOCATABLE :: fint(:), tension(:), fint0(:)
    ! Kb: reduced free/free tangent in LAPACK general-band storage (factored in place by
    ! DGBSV); drag_kq_band: the summed drag position Jacobian in the same storage, added
    ! as cf*drag_kq_band exactly as the load ramp scales the drag force.
    REAL(wp), ALLOCATABLE :: Kb(:, :), drag_kq_band(:, :)
    REAL(wp), ALLOCATABLE :: R_free(:), dq(:), q_trial(:), R_trial(:)
    REAL(wp), ALLOCATABLE :: hist(:), kn(:), seabed_f(:)
    REAL(wp), ALLOCATABLE :: vzero(:), fluidvel(:, :), waterln(:)
    REAL(wp), ALLOCATABLE :: drag_f(:), drag_fz(:)
    REAL(wp) :: f_ext_base, conv_scale, scale_trial, z_floor_local, rnorm, merit, merit_trial, alpha, lo, hi
    REAL(wp) :: cf, r_floor
    LOGICAL  :: seabed_active, bathymetry_active, current_active, profile_active
    INTEGER  :: es
    LOGICAL  :: lm_mode
    REAL(wp) :: mu, kappa
    INTEGER  :: nmax_it
    REAL(wp), PARAMETER :: LM_MU_MAX = 1.0e10_wp
    ! Smallest Levenberg-Marquardt shift (relative to kappa) of the slack-capable law: keeps
    ! directions without any stiffness (a grounded node between slack elements) solvable.
    REAL(wp), PARAMETER :: LM_MU_MIN_SLACK = 1.0e-12_wp
    CHARACTER(1024) :: em
    ! slack-capable law: base assembly flag, compressed-branch ratio, and the second
    ! (compression-capable) assembly the blend needs when 0 < r < 1
    LOGICAL  :: law_to, reg_law, blend
    REAL(wp) :: r_comp
    ! energy line search of the conservative slack-capable solve
    LOGICAL  :: use_energy
    REAL(wp) :: slope, e_cur, e_mag, e_trial, e_mag_t
    REAL(wp), ALLOCATABLE :: Kb2(:, :), fint2(:), tension2(:)
    ! seabed friction of the current: capacities of the last seabed evaluation, and those
    ! frozen at the line-search base point for the energy (like the frozen drag)
    LOGICAL  :: friction_active
    REAL(wp), ALLOCATABLE :: fr_cap(:), fr_capz(:)

    converged = .FALSE.
    stalled = .FALSE.
    at_floor = .FALSE.
    n_iter = 0
    ErrStat = CD_STATIC_OK
    ErrMsg = ''
    n_dof = SIZE(q0)
    q = CD_ZERO

    ! --- input validation (tedious; fail closed) ---
    IF (MOD(n_dof, 3) /= 0 .OR. n_dof < 6) THEN
      CALL fail(ErrStat, ErrMsg, 'q0 must be a positions-only state of shape (3 n_nodes), n_nodes >= 2')
      RETURN
    END IF
    IF (SIZE(q) /= n_dof .OR. SIZE(f_ext) /= n_dof) THEN
      CALL fail(ErrStat, ErrMsg, 'q and f_ext must have the same shape as q0')
      RETURN
    END IF
    IF (.NOT. CD_All_Finite(q0) .OR. .NOT. CD_All_Finite(f_ext)) THEN
      CALL fail(ErrStat, ErrMsg, 'q0 and f_ext must be finite')
      RETURN
    END IF
    ! Every tolerance must be finite and positive (a non-finite or non-positive
    ! armijo_c1, in particular, would relax/poison the sufficient-decrease test and
    ! let residual-increasing steps through); armijo_c1 must be a proper Armijo
    ! constant in (0, 1); the iteration counts must be sensible.
    IF (.NOT. pos_finite(cfg%rel_tol) .OR. .NOT. pos_finite(cfg%abs_tol) &
        .OR. .NOT. pos_finite(cfg%armijo_c1) .OR. cfg%armijo_c1 >= CD_ONE &
        .OR. .NOT. pos_finite(cfg%stall_rel_tol) &
        .OR. cfg%max_iter < 1 .OR. cfg%armijo_max_backtracks < 0 .OR. cfg%stall_window < 2) THEN
      ! stall_window compares the spread of the last stall_window residuals, so a
      ! one-sample window is always "flat" and would stall after the first step.
      CALL fail(ErrStat, ErrMsg, 'invalid solver config (tolerances must be finite/positive, '// &
                'armijo_c1 in (0,1), iteration counts positive, stall_window >= 2)')
      RETURN
    END IF
    n_elem = SIZE(elem_conn, 2)
    n_nodes = n_dof/3

    ! --- constitutive law: plain (tension_only as given) or the slack-capable blend ---
    law_to = tension_only
    reg_law = PRESENT(compression_ratio)
    blend = .FALSE.
    r_comp = CD_ONE
    IF (reg_law) THEN
      r_comp = compression_ratio
      IF (.NOT. CD_Is_Finite(r_comp) .OR. r_comp < CD_ZERO .OR. r_comp > CD_ONE) THEN
        CALL fail(ErrStat, ErrMsg, 'compression_ratio must be finite and in [0, 1]')
        RETURN
      END IF
      ! r = 1 is exactly the compression-capable law; otherwise assemble tension-only and add
      ! r times the compressed elements' force (the compression-capable minus the tension-only
      ! assembly, nonzero only on compressed elements).
      law_to = r_comp < CD_ONE
      blend = r_comp > CD_ZERO .AND. r_comp < CD_ONE
    END IF

    ! --- optional seabed: flat z_floor or bathymetry, plus per-node k_n ---
    bathymetry_active = PRESENT(bathymetry)
    IF (PRESENT(seabed_z_floor) .AND. bathymetry_active) THEN
      CALL fail(ErrStat, ErrMsg, 'seabed_z_floor and bathymetry are mutually exclusive')
      RETURN
    END IF
    IF ((PRESENT(seabed_z_floor) .OR. bathymetry_active) .NEQV. PRESENT(seabed_kn)) THEN
      CALL fail(ErrStat, ErrMsg, 'seabed requires seabed_kn with either seabed_z_floor or bathymetry')
      RETURN
    END IF
    seabed_active = (PRESENT(seabed_z_floor) .OR. bathymetry_active) .AND. PRESENT(seabed_kn)
    z_floor_local = CD_ZERO
    IF (seabed_active) THEN
      ! Nested guards, NOT `.AND.`: Fortran does not guarantee short-circuit
      ! evaluation, so passing the absent OPTIONAL seabed_z_floor / bathymetry to the
      ! non-optional dummy of IEEE_IS_FINITE / CD_Bathymetry_Is_Initialized is
      ! non-conforming (F2018 15.5.2.12). At -O0 gfortran evaluates the RHS and
      ! dereferences the absent argument (SIGSEGV); Release short-circuits and passes.
      IF (PRESENT(seabed_z_floor)) THEN
        IF (.NOT. CD_Is_Finite(seabed_z_floor)) THEN
          CALL fail(ErrStat, ErrMsg, 'seabed_z_floor must be finite')
          RETURN
        END IF
      END IF
      IF (bathymetry_active) THEN
        IF (.NOT. CD_Bathymetry_Is_Initialized(bathymetry)) THEN
          CALL fail(ErrStat, ErrMsg, 'bathymetry object is not initialized')
          RETURN
        END IF
      END IF
      IF (SIZE(seabed_kn) /= n_nodes) THEN
        CALL fail(ErrStat, ErrMsg, 'seabed_kn must have shape (n_nodes)')
        RETURN
      END IF
      IF (.NOT. CD_All_Finite(seabed_kn) .OR. ANY(seabed_kn <= CD_ZERO)) THEN
        CALL fail(ErrStat, ErrMsg, 'seabed_kn must be finite and positive')
        RETURN
      END IF
      IF (PRESENT(seabed_z_floor)) z_floor_local = seabed_z_floor
      ALLOCATE (kn(n_nodes), source=seabed_kn)
      ALLOCATE (seabed_f(n_dof))
    END IF

    ! --- optional steady-current Morison drag (configuration-dependent, ramp-scaled) ---
    ! (a friction-only object, drag = .FALSE., carries no drag)
    current_active = PRESENT(current)
    IF (current_active) current_active = current%drag
    profile_active = .FALSE.
    cf = CD_ONE
    IF (PRESENT(current_load_factor)) THEN
      ! A ramp factor without a current is a caller error: it would silently do nothing.
      IF (.NOT. PRESENT(current)) THEN
        CALL fail(ErrStat, ErrMsg, 'current_load_factor given without a current load')
        RETURN
      END IF
      IF (.NOT. CD_Is_Finite(current_load_factor) .OR. current_load_factor <= CD_ZERO &
          .OR. current_load_factor > CD_ONE) THEN
        CALL fail(ErrStat, ErrMsg, 'current_load_factor must be finite and in (0, 1]')
        RETURN
      END IF
      cf = current_load_factor
    END IF
    IF (current_active) THEN
      IF (.NOT. CD_All_Finite(current%velocity) .OR. .NOT. CD_Is_Finite(current%waterline_z)) THEN
        CALL fail(ErrStat, ErrMsg, 'current velocity and waterline_z must be finite')
        RETURN
      END IF
      IF (ALLOCATED(current%elem_diameter)) THEN
        ! per-element hydrodynamics: the three arrays must all be present with n_elem entries
        IF (.NOT. (ALLOCATED(current%elem_cdn) .AND. ALLOCATED(current%elem_cdt))) THEN
          CALL fail(ErrStat, ErrMsg, 'current elem_diameter requires elem_cdn and elem_cdt')
          RETURN
        END IF
        IF (SIZE(current%elem_diameter) /= n_elem .OR. SIZE(current%elem_cdn) /= n_elem &
            .OR. SIZE(current%elem_cdt) /= n_elem) THEN
          CALL fail(ErrStat, ErrMsg, 'current per-element drag arrays must have shape (n_elem)')
          RETURN
        END IF
        IF (.NOT. CD_Is_Finite(current%rho) .OR. current%rho <= CD_ZERO &
            .OR. .NOT. CD_All_Finite(current%elem_diameter) .OR. ANY(current%elem_diameter <= CD_ZERO)) THEN
          CALL fail(ErrStat, ErrMsg, 'current rho and element diameters must be finite and positive')
          RETURN
        END IF
        IF (.NOT. CD_All_Finite(current%elem_cdn) .OR. ANY(current%elem_cdn < CD_ZERO) &
            .OR. .NOT. CD_All_Finite(current%elem_cdt) .OR. ANY(current%elem_cdt < CD_ZERO)) THEN
          CALL fail(ErrStat, ErrMsg, 'current drag coefficients must be finite and non-negative')
          RETURN
        END IF
      ELSE
        IF (.NOT. CD_Is_Finite(current%rho) .OR. current%rho <= CD_ZERO &
            .OR. .NOT. CD_Is_Finite(current%diameter) .OR. current%diameter <= CD_ZERO) THEN
          CALL fail(ErrStat, ErrMsg, 'current rho and diameter must be finite and positive')
          RETURN
        END IF
        IF (.NOT. CD_Is_Finite(current%cdn) .OR. current%cdn < CD_ZERO &
            .OR. .NOT. CD_Is_Finite(current%cdt) .OR. current%cdt < CD_ZERO) THEN
          CALL fail(ErrStat, ErrMsg, 'current drag coefficients must be finite and non-negative')
          RETURN
        END IF
      END IF
      ALLOCATE (vzero(n_dof), source=CD_ZERO)
      ALLOCATE (fluidvel(3, n_nodes), waterln(n_nodes))
      IF (ALLOCATED(current%node_velocity)) THEN
        IF (SIZE(current%node_velocity, 1) /= 3 .OR. SIZE(current%node_velocity, 2) /= n_nodes) THEN
          CALL fail(ErrStat, ErrMsg, 'current node_velocity must have shape (3, n_nodes)')
          RETURN
        END IF
        IF (.NOT. CD_All_Finite(current%node_velocity)) THEN
          CALL fail(ErrStat, ErrMsg, 'current node_velocity must be finite')
          RETURN
        END IF
        fluidvel = current%node_velocity
      ELSE
        DO k = 1, n_nodes
          fluidvel(:, k) = current%velocity
        END DO
      END IF
      profile_active = ALLOCATED(current%profile_z) .OR. ALLOCATED(current%grid)
      IF (profile_active .AND. .NOT. ALLOCATED(current%grid)) THEN
        IF (.NOT. ALLOCATED(current%profile_velocity)) THEN
          CALL fail(ErrStat, ErrMsg, 'current profile_z requires profile_velocity')
          RETURN
        END IF
        IF (SIZE(current%profile_velocity, 1) /= 3 .OR. &
            SIZE(current%profile_velocity, 2) /= SIZE(current%profile_z)) THEN
          CALL fail(ErrStat, ErrMsg, 'current profile_velocity must have shape (3, SIZE(profile_z))')
          RETURN
        END IF
      END IF
      IF (profile_active) THEN
        CALL sample_profile(q0, es, em)
        IF (es /= CD_HYDRO_OK) THEN
          CALL fail(ErrStat, ErrMsg, 'current profile: '//TRIM(em))
          RETURN
        END IF
      END IF
      waterln = current%waterline_z
      IF (ALLOCATED(current%node_waterline)) THEN
        IF (SIZE(current%node_waterline) /= n_nodes) THEN
          CALL fail(ErrStat, ErrMsg, 'current node_waterline must have shape (n_nodes)')
          RETURN
        END IF
        IF (.NOT. CD_All_Finite(current%node_waterline)) THEN
          CALL fail(ErrStat, ErrMsg, 'current node_waterline must be finite')
          RETURN
        END IF
        waterln = current%node_waterline
      END IF
      ALLOCATE (drag_f(n_dof), drag_fz(n_dof), source=CD_ZERO)
    END IF
    friction_active = .FALSE.
    IF (PRESENT(current) .AND. seabed_active) THEN
      ! Check finiteness before the mu > 0 gate: a NaN coefficient must fail closed, not
      ! silently disable (or make isotropic) the friction.
      IF (.NOT. (CD_Is_Finite(current%friction_mu) .AND. CD_Is_Finite(current%friction_mu_axial))) THEN
        CALL fail(ErrStat, ErrMsg, 'current friction coefficients must be finite')
        RETURN
      END IF
      IF (current%friction_mu > CD_ZERO .AND. ALLOCATED(current%friction_ref)) THEN
        IF (.NOT. CD_Is_Finite(current%friction_mu) .OR. SIZE(current%friction_ref, 1) /= 2 .OR. &
            SIZE(current%friction_ref, 2) /= n_nodes) THEN
          CALL fail(ErrStat, ErrMsg, 'current friction needs a finite mu and friction_ref of shape (2, n_nodes)')
          RETURN
        END IF
        IF (.NOT. CD_All_Finite(current%friction_ref)) THEN
          CALL fail(ErrStat, ErrMsg, 'current friction_ref must be finite')
          RETURN
        END IF
        friction_active = .TRUE.
        ALLOCATE (fr_cap(n_nodes), fr_capz(n_nodes), source=CD_ZERO)
      END IF
    END IF

    CALL CD_Partition_Free_Dofs(fixed_dofs, n_dof, free, ErrStat, ErrMsg)
    IF (ErrStat /= 0) RETURN
    n_free = SIZE(free)
    IF (n_free == 0) THEN
      ! Every DOF prescribed: q0 IS the reduced solution, but still force the
      ! normal mesh/property/contact validation before reporting success. Without
      ! this, an all-fixed malformed deck can bypass the assemblers and be marked
      ! converged.
      ALLOCATE (fint0(n_dof))
      CALL CD_Assemble_Cable_Internal_Force(reshape3(q0, n_dof), elem_conn, l0, ea, tension_only, &
                                            fint0, es, em)
      IF (es /= 0) THEN
        CALL fail(ErrStat, ErrMsg, 'all-prescribed input failed mesh/element validation: '//TRIM(em))
        RETURN
      END IF
      IF (seabed_active) THEN
        CALL eval_seabed(q0, seabed_f, .FALSE., es, em)
        IF (es /= 0) THEN
          CALL fail(ErrStat, ErrMsg, 'all-prescribed input failed seabed validation: '//TRIM(em))
          RETURN
        END IF
      END IF
      IF (current_active) THEN
        CALL eval_drag_force(q0, drag_f, es, em)
        IF (es /= CD_HYDRO_OK) THEN
          CALL fail(ErrStat, ErrMsg, 'all-prescribed input failed current-drag validation: '//TRIM(em))
          RETURN
        END IF
      END IF
      q = q0
      converged = .TRUE.
      RETURN
    END IF

    ! Reduced free-DOF band of the tangent: connectivity-only, so it is fixed for the
    ! whole solve (seabed terms stay inside a node's own DOFs, drag inside an element's).
    CALL CD_Cable_Free_Bandwidth(elem_conn, n_nodes, free, kl, ku, es, em)
    IF (es /= 0) THEN
      CALL fail(ErrStat, ErrMsg, 'bandwidth analysis failed: '//TRIM(em))
      RETURN
    END IF
    ldab = 2*kl + ku + 1
    ALLOCATE (free_of(n_dof), source=0)
    DO bt = 1, n_free
      free_of(free(bt)) = bt
    END DO
    ALLOCATE (Kb(ldab, n_free), fint(n_dof), tension(n_elem))
    IF (blend) ALLOCATE (Kb2(ldab, n_free), fint2(n_dof), tension2(n_elem))
    ALLOCATE (R_free(n_free), dq(n_free))
    IF (current_active) ALLOCATE (drag_kq_band(ldab, n_free))
    ALLOCATE (q_trial(n_dof), R_trial(n_free))
    lm_mode = .FALSE.
    IF (PRESENT(regularized)) lm_mode = regularized
    ! The exact tension-only law (r = 0) can have a singular tangent; only the shifted
    ! (Levenberg-Marquardt) system is solvable there.
    IF (reg_law .AND. r_comp <= CD_ZERO) lm_mode = .TRUE.
    ! The slack-capable solve is a minimization of the potential energy, and its line search
    ! uses the energy as the merit function. A steady-current drag is not conservative: it is
    ! frozen at the current iterate for each line search (its fixed point is the equilibrium).
    use_energy = reg_law .AND. lm_mode
    mu = CD_ONE
    kappa = CD_ZERO
    nmax_it = cfg%max_iter
    IF (lm_mode) nmax_it = 8*cfg%max_iter
    ! The slack-capable energy descent moves slack and folded runs node by node along the
    ! seabed, so its budget grows with the mesh (bounded: every iteration is O(n)).
    IF (use_energy) nmax_it = MAX(nmax_it, MIN(4*n_nodes, 40*cfg%max_iter))
    ALLOCATE (hist(nmax_it + 1))

    q = q0
    f_ext_base = infnorm(f_ext(free))

    ! initial residual (seabed force folded in, q-dependent scale)
    CALL eval_residual(q, R_free, conv_scale)
    IF (ErrStat /= 0) RETURN
    ! Round-off floor of the nodal residual: an element force EA*(l/l0 - 1) built from
    ! coordinates of magnitude |q| carries an absolute error ~ eps*|q|*EA/l0. rel_tol
    ! scales with the NODAL load, which shrinks as the mesh is refined while this floor
    ! grows (EA/l0), so a fine mesh of a stiff line can reach equilibrium to machine
    ! precision and still sit above rel_tol*scale. A Newton stall (no Armijo descent, or
    ! a flat residual history) whose residual is inside this floor is converged: no
    ! further digits exist to gain. Paths that meet rel_tol are unaffected.
    r_floor = 16.0_wp*EPSILON(CD_ONE)*MAXVAL(ea/l0)*MAX(MAXVAL(ABS(q0)), MAXVAL(l0))
    rnorm = infnorm(R_free)
    hist(1) = rnorm
    k = 1
    IF (is_converged(rnorm, conv_scale, cfg)) THEN
      converged = .TRUE.
      RETURN
    END IF

    DO iteration = 1, nmax_it
      n_iter = iteration
      ! structural free/free tangent (reduced band) + internal force at q
      CALL CD_Assemble_Cable_Tangent_Force_Banded_Free(reshape3(q, n_dof), elem_conn, l0, ea, &
                                                       law_to, free, kl, ku, Kb, fint, tension, es, em)
      IF (es /= 0) THEN
        CALL fail(ErrStat, ErrMsg, 'tangent assembly failed: '//TRIM(em))
        RETURN
      END IF
      IF (blend) THEN
        ! slack-capable law: + r (K_compression_capable - K_tension_only), nonzero only on
        ! the compressed elements
        CALL CD_Assemble_Cable_Tangent_Force_Banded_Free(reshape3(q, n_dof), elem_conn, l0, ea, &
                                                         .FALSE., free, kl, ku, Kb2, fint2, tension2, es, em)
        IF (es /= 0) THEN
          CALL fail(ErrStat, ErrMsg, 'tangent assembly failed: '//TRIM(em))
          RETURN
        END IF
        Kb = Kb + r_comp*(Kb2 - Kb)
      END IF
      ! + the seabed contact tangent (-d(f_contact)/dq) at q
      IF (seabed_active) THEN
        CALL eval_seabed(q, seabed_f, .TRUE., es, em)
        IF (es /= 0) THEN
          CALL fail(ErrStat, ErrMsg, 'seabed assembly failed: '//TRIM(em))
          RETURN
        END IF
      END IF
      ! + the steady-current drag tangent cf*(-d(f_drag)/dq) at q (cable at rest -> v=0,
      ! so only the q-Jacobian enters; the drag force ramps with cf in lock-step). The
      ! node currents and the drag buffer are refreshed at q first (a rejected trial of the
      ! previous iteration may have left them at another state).
      IF (current_active) THEN
        IF (profile_active) THEN
          CALL sample_profile(q, es, em)
          IF (es /= CD_HYDRO_OK) THEN
            CALL fail(ErrStat, ErrMsg, 'current profile: '//TRIM(em))
            RETURN
          END IF
        END IF
        CALL eval_drag_force(q, drag_f, es, em)
        IF (es /= CD_HYDRO_OK) THEN
          CALL fail(ErrStat, ErrMsg, 'current-drag assembly failed: '//TRIM(em))
          RETURN
        END IF
        CALL eval_drag_tangent(q, es, em)
        IF (es /= CD_HYDRO_OK) THEN
          CALL fail(ErrStat, ErrMsg, 'current-drag assembly failed: '//TRIM(em))
          RETURN
        END IF
        Kb = Kb + cf*drag_kq_band
      END IF
      ! R_free is the (carried) residual at q
      IF (lm_mode) THEN
        ! Geometric-stiffness scale of the seed line, fixed for the whole solve.
        IF (iteration == 1) kappa = MAX(MAXVAL(ABS(tension)), f_ext_base, cfg%abs_tol)/MINVAL(l0)
        DO bt = 1, n_free
          Kb(kl + ku + 1, bt) = Kb(kl + ku + 1, bt) + mu*kappa
        END DO
      END IF
      dq = -R_free
      CALL CD_Solve_Banded(Kb, kl, ku, dq, es, em)   ! dq <- K_free^-1 (-R_free); Kb holds the LU
      IF (es /= 0 .OR. .NOT. CD_All_Finite(dq)) THEN
        ErrStat = CD_STATIC_SINGULAR
        ErrMsg = 'CableDyn_Static: tangent is singular or ill-conditioned (DGBSV): '//TRIM(em)
        RETURN
      END IF

      merit = 0.5_wp*DOT_PRODUCT(R_free, R_free)
      alpha = CD_ONE
      stalled = .TRUE.   ! provisionally; cleared on an accepted step
      IF (use_energy) THEN
        ! Energy line search (conservative slack-capable solve): R is the gradient of the
        ! potential energy, so the shifted step must be a descent direction of it; if not,
        ! the shift is enlarged and the step recomputed. A trial is accepted on sufficient
        ! energy decrease, or -- once the energy change is inside its round-off -- on a
        ! residual decrease. Descending the energy lands on stable equilibria only: a
        ! compressed strut or arch is a saddle of the energy and is never approached.
        slope = DOT_PRODUCT(R_free, dq)
        IF (.NOT. (slope < CD_ZERO)) THEN
          IF (16.0_wp*mu <= LM_MU_MAX) THEN
            mu = 16.0_wp*mu
            stalled = .FALSE.
            CYCLE
          END IF
        ELSE
          ! drag_f holds the drag at q (the last residual evaluation was at q), fr_cap the
          ! friction capacities there
          IF (current_active) drag_fz = cf*drag_f
          IF (friction_active) fr_capz = fr_cap
          CALL eval_energy(q, e_cur, e_mag)
          DO bt = 0, cfg%armijo_max_backtracks
            q_trial = q
            q_trial(free) = q_trial(free) + alpha*dq
            CALL eval_residual(q_trial, R_trial, scale_trial)
            IF (ErrStat /= 0) RETURN
            merit_trial = 0.5_wp*DOT_PRODUCT(R_trial, R_trial)
            CALL eval_energy(q_trial, e_trial, e_mag_t)
            IF (e_trial <= e_cur + cfg%armijo_c1*alpha*slope) THEN
              stalled = .FALSE.
              EXIT
            END IF
            IF (ABS(e_trial - e_cur) <= 64.0_wp*EPSILON(CD_ONE)*MAX(e_mag, e_mag_t) &
                .AND. merit_trial <= merit*(CD_ONE - cfg%armijo_c1*alpha)) THEN
              stalled = .FALSE.
              EXIT
            END IF
            alpha = 0.5_wp*alpha
          END DO
        END IF
      ELSE
        DO bt = 0, cfg%armijo_max_backtracks
          q_trial = q
          q_trial(free) = q_trial(free) + alpha*dq
          CALL eval_residual(q_trial, R_trial, scale_trial)
          IF (ErrStat /= 0) RETURN
          merit_trial = 0.5_wp*DOT_PRODUCT(R_trial, R_trial)
          IF (merit_trial <= merit*(CD_ONE - cfg%armijo_c1*alpha)) THEN
            stalled = .FALSE.
            EXIT
          END IF
          alpha = 0.5_wp*alpha
        END DO
      END IF

      IF (stalled) THEN
        IF (hist(k) <= r_floor) THEN
          stalled = .FALSE.
          converged = .TRUE.
          RETURN
        END IF
        IF (lm_mode .AND. 16.0_wp*mu <= LM_MU_MAX) THEN
          ! No descent along the shifted step: enlarge the shift and retry from q.
          mu = 16.0_wp*mu
          stalled = .FALSE.
          CYCLE
        END IF
        at_floor = hist(k)/conv_scale < cfg%stall_rel_tol
        RETURN
      END IF
      IF (lm_mode) THEN
        IF (alpha >= CD_ONE) THEN
          mu = 0.25_wp*mu
          IF (reg_law) mu = MAX(mu, LM_MU_MIN_SLACK)
        ELSE
          mu = 2.0_wp*mu
        END IF
      END IF

      q = q_trial
      R_free = R_trial
      conv_scale = scale_trial
      rnorm = infnorm(R_free)
      k = k + 1
      hist(k) = rnorm
      IF (is_converged(rnorm, conv_scale, cfg)) THEN
        converged = .TRUE.
        RETURN
      END IF
      ! flat-residual stall over the last stall_window samples (Levenberg-Marquardt keeps
      ! iterating on a flat residual unless it is already inside the round-off floor)
      IF (k >= cfg%stall_window) THEN
        lo = MINVAL(hist(k - cfg%stall_window + 1:k))
        hi = MAXVAL(hist(k - cfg%stall_window + 1:k))
        IF (hi > CD_ZERO .AND. lo/hi > 0.99_wp) THEN
          IF (hist(k) <= r_floor) THEN
            converged = .TRUE.
            RETURN
          END IF
          IF (.NOT. lm_mode) THEN
            stalled = .TRUE.
            at_floor = hist(k)/conv_scale < cfg%stall_rel_tol
            RETURN
          END IF
        END IF
        ! Inside the round-off floor a residual can also cycle between two or more values (the
        ! rounding of the last digits alternating), which the flat test above never sees: when
        ! the last stall_window samples set no new minimum, there is no digit left to gain either
        IF (k > cfg%stall_window .AND. hist(k) <= r_floor) THEN
          IF (lo >= MINVAL(hist(1:k - cfg%stall_window))) THEN
            converged = .TRUE.
            RETURN
          END IF
        END IF
      END IF
    END DO
    ! exhausted max_iter without converging or stalling

  CONTAINS

    SUBROUTINE eval_residual(qe, Rf, sc)
      !! R_free = (f_int(qe) - f_ext - seabed_force(qe) - cf*drag_force(qe))[free];
      !! sc = max(||f_ext[free]||, ||seabed_force[free]||, ||cf*drag[free]||, abs_tol).
      !! Host-associates the seabed/current state + buffers. On an assembly failure it
      !! sets the host ErrStat/ErrMsg (caller checks).
      REAL(wp), INTENT(IN)  :: qe(:)
      REAL(wp), INTENT(OUT) :: Rf(:), sc
      REAL(wp), ALLOCATABLE :: fint_e(:)
      REAL(wp) :: scale_load, scale_drag
      INTEGER  :: es_e
      CHARACTER(1024) :: em_e
      ALLOCATE (fint_e(n_dof))
      CALL CD_Assemble_Cable_Internal_Force(reshape3(qe, n_dof), elem_conn, l0, ea, law_to, &
                                            fint_e, es_e, em_e)
      IF (es_e /= 0) THEN
        CALL fail(ErrStat, ErrMsg, 'internal-force assembly failed: '//TRIM(em_e))
        Rf = CD_ZERO
        sc = CD_ONE
        RETURN
      END IF
      IF (blend) THEN
        BLOCK
          REAL(wp), ALLOCATABLE :: fint_c(:)
          ALLOCATE (fint_c(n_dof))
          CALL CD_Assemble_Cable_Internal_Force(reshape3(qe, n_dof), elem_conn, l0, ea, .FALSE., &
                                                fint_c, es_e, em_e)
          IF (es_e /= 0) THEN
            CALL fail(ErrStat, ErrMsg, 'internal-force assembly failed: '//TRIM(em_e))
            Rf = CD_ZERO
            sc = CD_ONE
            RETURN
          END IF
          fint_e = fint_e + r_comp*(fint_c - fint_e)
        END BLOCK
      END IF
      IF (seabed_active) THEN
        CALL eval_seabed(qe, seabed_f, .FALSE., es_e, em_e)
        IF (es_e /= 0) THEN
          CALL fail(ErrStat, ErrMsg, 'seabed assembly failed: '//TRIM(em_e))
          Rf = CD_ZERO
          sc = CD_ONE
          RETURN
        END IF
        Rf = fint_e(free) - f_ext(free) - seabed_f(free)
        scale_load = infnorm(seabed_f(free))
      ELSE
        Rf = fint_e(free) - f_ext(free)
        scale_load = CD_ZERO
      END IF
      scale_drag = CD_ZERO
      IF (current_active) THEN
        IF (profile_active) THEN
          CALL sample_profile(qe, es_e, em_e)
          IF (es_e /= CD_HYDRO_OK) THEN
            CALL fail(ErrStat, ErrMsg, 'current profile: '//TRIM(em_e))
            Rf = CD_ZERO
            sc = CD_ONE
            RETURN
          END IF
        END IF
        CALL eval_drag_force(qe, drag_f, es_e, em_e)
        IF (es_e /= CD_HYDRO_OK) THEN
          CALL fail(ErrStat, ErrMsg, 'current-drag assembly failed: '//TRIM(em_e))
          Rf = CD_ZERO
          sc = CD_ONE
          RETURN
        END IF
        Rf = Rf - cf*drag_f(free)
        scale_drag = infnorm(cf*drag_f(free))
      END IF
      sc = MAX(f_ext_base, scale_load, scale_drag, cfg%abs_tol)
    END SUBROUTINE eval_residual

    SUBROUTINE eval_energy(qe, energy, magnitude)
      !! Potential energy of the conservative static problem at qe: the slack-capable axial
      !! strain energy (EA l0 eps^2/2 in tension, r times that in compression), the seabed
      !! penalty potential (the integral of CD_Seabed_Normal_Law over the normal penetration)
      !! and the potential of the constant external load, -f_ext . q. Its gradient on the free
      !! DOFs is the residual R. magnitude is the sum of the absolute values of the terms,
      !! the scale of the energy's round-off.
      REAL(wp), INTENT(IN) :: qe(:)
      REAL(wp), INTENT(OUT) :: energy, magnitude
      INTEGER :: e, a, b, i, es_e
      REAL(wp) :: ell, eps, w_el, zf, gx, gy, g, s, pot, bl
      CHARACTER(120) :: em_e

      energy = CD_ZERO
      magnitude = CD_ZERO
      DO e = 1, n_elem
        a = elem_conn(1, e)
        b = elem_conn(2, e)
        ell = NORM2(qe(3*b - 2:3*b) - qe(3*a - 2:3*a))
        eps = ell/l0(e) - CD_ONE
        w_el = 0.5_wp*ea(e)*l0(e)*eps*eps
        IF (eps < CD_ZERO) w_el = r_comp*w_el
        energy = energy + w_el
        magnitude = magnitude + w_el
      END DO
      IF (seabed_active) THEN
        bl = CD_SEABED_CONTACT_BLEND
        DO i = 1, n_nodes
          IF (bathymetry_active) THEN
            CALL CD_Bathymetry_Floor_Gradient(bathymetry, qe(3*i - 2), qe(3*i - 1), zf, gx, gy, es_e, em_e)
            IF (es_e /= CD_BATHY_OK) CYCLE
          ELSE
            zf = z_floor_local
            gx = CD_ZERO
            gy = CD_ZERO
          END IF
          s = SQRT(CD_ONE + gx*gx + gy*gy)
          g = (zf - qe(3*i))/s
          IF (g <= -bl) THEN
            pot = CD_ZERO
          ELSE IF (g < bl) THEN
            pot = kn(i)*(g + bl)**3/(12.0_wp*bl)
          ELSE
            pot = 0.5_wp*kn(i)*g*g + kn(i)*bl*bl/6.0_wp
          END IF
          energy = energy + pot
          magnitude = magnitude + pot
        END DO
      END IF
      DO i = 1, n_dof
        energy = energy - f_ext(i)*qe(i)
        magnitude = magnitude + ABS(f_ext(i)*qe(i))
      END DO
      IF (current_active) THEN
        ! the drag frozen at the line-search base point acts as a constant load
        DO i = 1, n_dof
          energy = energy - drag_fz(i)*qe(i)
          magnitude = magnitude + ABS(drag_fz(i)*qe(i))
        END DO
      END IF
      IF (friction_active) THEN
        ! friction springs with the capacities frozen at the base point: potential
        ! (C^2/k) (sqrt(1 + (k|d|/C)^2) - 1)
        DO i = 1, n_nodes
          IF (.NOT. (fr_capz(i) > CD_ZERO)) CYCLE
          pot = (qe(3*i - 2) - current%friction_ref(1, i))**2 + (qe(3*i - 1) - current%friction_ref(2, i))**2
          pot = fr_capz(i)**2/kn(i)*(SQRT(CD_ONE + kn(i)*kn(i)*pot/fr_capz(i)**2) - CD_ONE)
          energy = energy + pot
          magnitude = magnitude + pot
        END DO
      END IF
    END SUBROUTINE eval_energy

    SUBROUTINE eval_seabed(qe, f_contact, add_tangent, es_out, em_out)
      !! Penalty seabed contact force per node (flat floor or bathymetry surface, the
      !! shared C1 normal law). The contact is frictionless and acts along the local
      !! surface normal (CD_Seabed_Normal_Contact): vertical on a flat floor, tilted on a
      !! sloped bathymetry. With add_tangent, the residual-Jacobian block -d(f_contact)/dq of
      !! each node is added to the host band tangent Kb on the free DOFs.
      REAL(wp), INTENT(IN) :: qe(:)
      REAL(wp), INTENT(OUT) :: f_contact(:)
      LOGICAL, INTENT(IN) :: add_tangent
      INTEGER, INTENT(OUT) :: es_out
      CHARACTER(*), INTENT(OUT) :: em_out
      INTEGER :: i, ix, iy, iz, a, b
      REAL(wp) :: z_floor, dfdx, dfdy, gap, tangent, fvec(3), jac(3, 3), normal_i, curv(3), tang_n

      f_contact = CD_ZERO
      es_out = 0
      em_out = ''
      DO i = 1, n_nodes
        ix = 3*i - 2
        iy = ix + 1
        iz = ix + 2
        curv = CD_ZERO
        IF (bathymetry_active) THEN
          CALL CD_Bathymetry_Floor_Gradient(bathymetry, qe(ix), qe(iy), z_floor, dfdx, dfdy, es_out, em_out, &
                                            crease_curvature=curv)
          IF (es_out /= CD_BATHY_OK) RETURN
        ELSE
          z_floor = z_floor_local
          dfdx = CD_ZERO
          dfdy = CD_ZERO
        END IF
        gap = z_floor - qe(iz)
        IF (.NOT. (ABS(dfdx) > CD_ZERO .OR. ABS(dfdy) > CD_ZERO .OR. ANY(ABS(curv) > CD_ZERO))) THEN
          ! level floor: the normal is vertical (the historical flat-floor evaluation)
          CALL CD_Seabed_Normal_Law(gap, kn(i), f_contact(iz), tangent)
          IF (add_tangent) CALL add_band(iz, iz, tangent)
          IF (friction_active) THEN
            normal_i = f_contact(iz)
            CALL add_friction(qe, f_contact, add_tangent, i, normal_i, -tangent)
          END IF
          CYCLE
        END IF
        ! (the tangent follows the rounding of a bathymetry crease; zero curvature elsewhere)
        CALL CD_Seabed_Normal_Contact(gap, dfdx, dfdy, kn(i), fvec, jac, curvature=curv)
        f_contact(ix:iz) = fvec
        ! on a slope the capacity follows the magnitude of the normal reaction (its
        ! dependence on the position is left out of the tangent); in a crease band the
        ! elastic force also carries the curvature term of the potential, so the capacity
        ! is the scalar normal law there, as on the Hermite path and in the dynamics
        IF (friction_active) THEN
          IF (ANY(ABS(curv) > CD_ZERO)) THEN
            CALL CD_Seabed_Normal_Law(gap/SQRT(CD_ONE + dfdx*dfdx + dfdy*dfdy), kn(i), normal_i, tang_n)
          ELSE
            normal_i = NORM2(fvec)
          END IF
          CALL add_friction(qe, f_contact, add_tangent, i, normal_i, CD_ZERO)
        END IF
        IF (.NOT. add_tangent) CYCLE
        DO b = 1, 3
          DO a = 1, 3
            CALL add_band(ix + a - 1, ix + b - 1, jac(a, b))
          END DO
        END DO
      END DO
      es_out = 0
    END SUBROUTINE eval_seabed

    SUBROUTINE add_friction(qe, f_contact, add_tangent, node, normal, dnormal_dz)
      !! Friction spring of one node: the load -f on x/y (f from CD_Seabed_Friction_Spring at
      !! the capacity mu*normal) into f_contact and, with add_tangent, its Jacobian df/dq.
      REAL(wp), INTENT(IN) :: qe(:)
      REAL(wp), INTENT(INOUT) :: f_contact(:)
      LOGICAL, INTENT(IN) :: add_tangent
      INTEGER, INTENT(IN) :: node
      REAL(wp), INTENT(IN) :: normal, dnormal_dz
      REAL(wp) :: f(2), dfd(2, 2), dfc(2), mu_c, mu_d, q_d, gq_d(2), axis(2)
      INTEGER :: jx, r
      jx = 3*node - 2
      IF (current%friction_mu_axial > CD_ZERO .AND. ABS(current%friction_mu_axial - current%friction_mu) > CD_ZERO) THEN
        axis = friction_chord(qe, node)
        CALL CD_Seabed_Friction_Mu_Dir(qe(jx:jx + 1) - current%friction_ref(:, node), current%friction_mu_axial, &
                                       current%friction_mu, axis, mu_d, q_d, gq_d)
        fr_cap(node) = mu_d*MAX(normal, CD_ZERO)
        ! dfc is d(force)/d(normal) (the line axis is held fixed)
        CALL CD_Seabed_Friction_Aniso(CD_FRICTION_SPRING, qe(jx:jx + 1) - current%friction_ref(:, node), kn(node), &
                                      normal, current%friction_mu_axial, current%friction_mu, axis, f, dfd, dfc)
        mu_c = CD_ONE
      ELSE
        fr_cap(node) = current%friction_mu*MAX(normal, CD_ZERO)
        CALL CD_Seabed_Friction_Spring(qe(jx:jx + 1) - current%friction_ref(:, node), kn(node), fr_cap(node), &
                                       f, dfd, dfc)
        mu_c = current%friction_mu
      END IF
      f_contact(jx:jx + 1) = f_contact(jx:jx + 1) - f
      IF (.NOT. add_tangent) RETURN
      DO r = 1, 2
        CALL add_band(jx + r - 1, jx, dfd(r, 1))
        CALL add_band(jx + r - 1, jx + 1, dfd(r, 2))
        CALL add_band(jx + r - 1, jx + 2, mu_c*dfc(r)*dnormal_dz)
      END DO
    END SUBROUTINE add_friction

    SUBROUTINE sample_profile(qe, es_out, em_out)
      !! Current of every node at its own elevation in state qe (depth-profile current), or at
      !! its own position at t = 0 (current grid).
      REAL(wp), INTENT(IN) :: qe(:)
      INTEGER, INTENT(OUT) :: es_out
      CHARACTER(*), INTENT(OUT) :: em_out
      INTEGER :: i
      es_out = CD_HYDRO_OK
      em_out = ''
      IF (ALLOCATED(current%grid)) THEN
        DO i = 1, n_nodes
          CALL CD_Current_Grid_Velocity(current%grid, qe(3*i - 2:3*i), CD_ZERO, fluidvel(:, i), es_out, em_out)
          IF (es_out /= CD_HYDRO_OK) RETURN
        END DO
        RETURN
      END IF
      DO i = 1, n_nodes
        CALL CD_Current_Profile_Velocity(qe(3*i), current%profile_z, current%profile_velocity, fluidvel(:, i), &
                                         es_out, em_out)
        IF (es_out /= CD_HYDRO_OK) RETURN
      END DO
    END SUBROUTINE sample_profile

    SUBROUTINE eval_drag_force(qe, f, es_out, em_out)
      !! Steady-current drag force on the cable at rest: the scalar-property line assembler
      !! when the current carries one diameter/drag pair, else an element loop over the
      !! per-element diameters and coefficients.
      REAL(wp), INTENT(IN) :: qe(:)
      REAL(wp), INTENT(OUT) :: f(:)
      INTEGER, INTENT(OUT) :: es_out
      CHARACTER(*), INTENT(OUT) :: em_out
      INTEGER :: e, a, b
      REAL(wp) :: f2(6), jq2(6, 6), jv2(6, 6)

      IF (.NOT. ALLOCATED(current%elem_diameter)) THEN
        CALL CD_Cable_Morison_Drag_Force(qe, vzero, elem_conn, l0, fluidvel, waterln, &
                                         current%rho, current%diameter, current%cdn, current%cdt, &
                                         f, es_out, em_out)
        RETURN
      END IF
      f = CD_ZERO
      es_out = CD_HYDRO_OK
      em_out = ''
      DO e = 1, n_elem
        a = elem_conn(1, e)
        b = elem_conn(2, e)
        CALL CD_Morison_Drag_Element_Load(qe(3*a - 2:3*a), qe(3*b - 2:3*b), vzero(1:3), vzero(1:3), l0(e), &
                                          fluidvel(:, a), fluidvel(:, b), waterln(a), waterln(b), &
                                          current%rho, current%elem_diameter(e), current%elem_cdn(e), &
                                          current%elem_cdt(e), f2, jq2, jv2, es_out, em_out)
        IF (es_out /= CD_HYDRO_OK) RETURN
        f(3*a - 2:3*a) = f(3*a - 2:3*a) + f2(1:3)
        f(3*b - 2:3*b) = f(3*b - 2:3*b) + f2(4:6)
      END DO
    END SUBROUTINE eval_drag_force

    SUBROUTINE eval_drag_tangent(qe, es_out, em_out)
      !! Steady-current drag position Jacobian (cable at rest, v = 0) summed element by
      !! element into drag_kq_band on the free DOFs. The -d(force)/dv block is not needed
      !! in statics.
      REAL(wp), INTENT(IN) :: qe(:)
      INTEGER, INTENT(OUT) :: es_out
      CHARACTER(*), INTENT(OUT) :: em_out
      INTEGER :: e, a, b, i, j, fi, fj, gmap(6)
      REAL(wp) :: f2(6), jq2(6, 6), jv2(6, 6), de, cn, ct, grad_a(3, 3), grad_b(3, 3)

      drag_kq_band = CD_ZERO
      es_out = CD_HYDRO_OK
      em_out = ''
      DO e = 1, n_elem
        a = elem_conn(1, e)
        b = elem_conn(2, e)
        IF (ALLOCATED(current%elem_diameter)) THEN
          de = current%elem_diameter(e)
          cn = current%elem_cdn(e)
          ct = current%elem_cdt(e)
        ELSE
          de = current%diameter
          cn = current%cdn
          ct = current%cdt
        END IF
        CALL CD_Morison_Drag_Element_Load(qe(3*a - 2:3*a), qe(3*b - 2:3*b), vzero(1:3), vzero(1:3), l0(e), &
                                          fluidvel(:, a), fluidvel(:, b), waterln(a), waterln(b), &
                                          current%rho, de, cn, ct, f2, jq2, jv2, es_out, em_out)
        IF (es_out /= CD_HYDRO_OK) RETURN
        IF (profile_active) THEN
          ! A current re-sampled at the node positions moves with them: the load depends on
          ! position through the fluid velocity too, d(load)/du_a = -d(load)/dv_a, so
          ! -d(load)/dq_a gains -(jac_v block a) G_a with G = du/dx the field's gradient at the node
          ! (without it the Newton iteration can fail in a current sheared across the line).
          IF (ALLOCATED(current%grid)) THEN
            CALL CD_Current_Grid_Gradient(current%grid, qe(3*a - 2:3*a), CD_ZERO, grad_a, es_out, em_out)
            IF (es_out == CD_HYDRO_OK) &
              CALL CD_Current_Grid_Gradient(current%grid, qe(3*b - 2:3*b), CD_ZERO, grad_b, es_out, em_out)
            IF (es_out /= CD_HYDRO_OK) RETURN
          ELSE
            CALL CD_Current_Profile_Gradient(qe(3*a), current%profile_z, current%profile_velocity, grad_a)
            CALL CD_Current_Profile_Gradient(qe(3*b), current%profile_z, current%profile_velocity, grad_b)
          END IF
          jq2(:, 1:3) = jq2(:, 1:3) - MATMUL(jv2(:, 1:3), grad_a)
          jq2(:, 4:6) = jq2(:, 4:6) - MATMUL(jv2(:, 4:6), grad_b)
        END IF
        DO i = 1, 3
          gmap(i) = 3*a - 3 + i
          gmap(3 + i) = 3*b - 3 + i
        END DO
        DO j = 1, 6
          fj = free_of(gmap(j))
          IF (fj == 0) CYCLE
          DO i = 1, 6
            fi = free_of(gmap(i))
            IF (fi == 0) CYCLE
            drag_kq_band(kl + ku + 1 + fi - fj, fj) = drag_kq_band(kl + ku + 1 + fi - fj, fj) + jq2(i, j)
          END DO
        END DO
      END DO
    END SUBROUTINE eval_drag_tangent

    SUBROUTINE add_band(row_dof, col_dof, val)
      !! Kb(row, col) += val for a pair of free DOFs; a fixed row or column is dropped.
      !! Callers only couple DOFs of one node, which the element band always covers.
      INTEGER, INTENT(IN) :: row_dof, col_dof
      REAL(wp), INTENT(IN) :: val
      INTEGER :: fi, fj

      fi = free_of(row_dof)
      fj = free_of(col_dof)
      IF (fi == 0 .OR. fj == 0) RETURN
      Kb(kl + ku + 1 + fi - fj, fj) = Kb(kl + ku + 1 + fi - fj, fj) + val
    END SUBROUTINE add_band

  END SUBROUTINE CD_Static_Cable_Solve

  SUBROUTINE CD_Static_Cable_Solve_Continuation(q0, elem_conn, l0, ea, tension_only, f_ext, &
                                                fixed_dofs, cfg, load_factors, q, converged, &
                                                stalled, at_floor, n_iter_total, n_stages_done, &
                                                ErrStat, ErrMsg, seabed_z_floor, seabed_kn, current, bathymetry, &
                                                compression_ratio, lm_only, plain_only)
    !! Robust static initialisation by load continuation: solve the EI=0 cable
    !! equilibrium in stages, ramping the external load to lambda * f_ext for each
    !! lambda in load_factors (strictly increasing, ending at 1), warm-starting
    !! every stage from the previous converged state. The final stage (lambda = 1)
    !! is the same equilibrium CD_Static_Cable_Solve targets directly, but reaching
    !! it through a sequence of easier problems globalises the Newton solve so it
    !! converges from a poor cold seed where the single-shot solve stalls (load
    !! continuation as a globalisation strategy); the optional penalty seabed stiffness
    !! ramps with the load factor, and the final stage (lambda = 1) restores it in full,
    !! so the final fixed point is unchanged and only the path to it is eased. A stage
    !! that stalls or errors is returned honestly:
    !! converged=.FALSE., q holds that stage's best state, n_stages_done counts the
    !! stages that converged. No external state is ever substituted on failure.
    REAL(wp), INTENT(IN)  :: q0(:)
    INTEGER, INTENT(IN)  :: elem_conn(:, :)
    REAL(wp), INTENT(IN)  :: l0(:), ea(:)
    LOGICAL, INTENT(IN)  :: tension_only
    REAL(wp), INTENT(IN)  :: f_ext(:)
    INTEGER, INTENT(IN)  :: fixed_dofs(:)
    TYPE(CableSolverConfig), INTENT(IN) :: cfg
    REAL(wp), INTENT(IN)  :: load_factors(:)    !! strictly increasing ramp in (0, 1], ending at 1
    REAL(wp), INTENT(OUT) :: q(:)
    LOGICAL, INTENT(OUT) :: converged, stalled, at_floor
    INTEGER, INTENT(OUT) :: n_iter_total, n_stages_done, ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    REAL(wp), INTENT(IN), OPTIONAL :: seabed_z_floor
    REAL(wp), INTENT(IN), OPTIONAL :: seabed_kn(:)
    TYPE(CableCurrentLoad), INTENT(IN), OPTIONAL :: current  !! steady current drag, ramped per stage
    TYPE(CD_BathymetryType), INTENT(IN), OPTIONAL :: bathymetry !! variable seabed elevation service
    REAL(wp), INTENT(IN), OPTIONAL :: compression_ratio !! slack-capable law (see CD_Static_Cable_Solve)
    LOGICAL, INTENT(IN), OPTIONAL :: lm_only            !! skip the plain Newton try of each stage
    LOGICAL, INTENT(IN), OPTIONAL :: plain_only         !! skip the Levenberg-Marquardt retry of a stage

    INTEGER :: n_dof, ns, s, n_iter_stage
    LOGICAL :: plain_first, lm_retry
    REAL(wp), ALLOCATABLE :: q_stage(:), f_stage(:), kn_stage(:)

    converged = .FALSE.
    stalled = .FALSE.
    at_floor = .FALSE.
    n_iter_total = 0
    n_stages_done = 0
    ErrStat = CD_STATIC_OK
    ErrMsg = ''
    n_dof = SIZE(q0)
    q = CD_ZERO

    ! --- validate the continuation schedule (the inner solve validates the rest) ---
    IF (SIZE(q) /= n_dof .OR. SIZE(f_ext) /= n_dof) THEN
      CALL fail(ErrStat, ErrMsg, 'q and f_ext must have the same shape as q0')
      RETURN
    END IF
    ns = SIZE(load_factors)
    IF (ns < 1) THEN
      CALL fail(ErrStat, ErrMsg, 'load_factors must contain at least one stage')
      RETURN
    END IF
    IF (.NOT. CD_All_Finite(load_factors)) THEN
      CALL fail(ErrStat, ErrMsg, 'load_factors must be finite')
      RETURN
    END IF
    IF (load_factors(1) <= CD_ZERO) THEN
      CALL fail(ErrStat, ErrMsg, 'load_factors must be strictly positive')
      RETURN
    END IF
    DO s = 2, ns
      IF (load_factors(s) <= load_factors(s - 1)) THEN
        CALL fail(ErrStat, ErrMsg, 'load_factors must be strictly increasing')
        RETURN
      END IF
    END DO
    IF (ABS(load_factors(ns) - CD_ONE) > 1.0e-12_wp) THEN
      CALL fail(ErrStat, ErrMsg, 'load_factors must end at 1 (the full load)')
      RETURN
    END IF

    ALLOCATE (q_stage(n_dof), source=q0)
    ALLOCATE (f_stage(n_dof))
    IF (PRESENT(seabed_kn)) ALLOCATE (kn_stage(SIZE(seabed_kn)))
    DO s = 1, ns
      f_stage = load_factors(s)*f_ext
      ! The current drag ramps in lock-step with the weight: stage s applies cf = lambda_s
      ! of the full drag, so it grows with the suspended-span tension instead of hitting the
      ! cold seed at full strength. Only passed when a current is present (the inner solve
      ! rejects a ramp factor without a current).
      !
      ! The seabed penalty ALSO ramps with the load. A stiff penalty (a physical kBot ~ 3e6 Pa/m)
      ! at full strength on the cold catenary seed ill-conditions the contact Newton -- a composite
      ! semitaut line (a short grounded chain run under a taut fibre section) then stalls. Scaling
      ! the penalty by lambda_s and warm-starting each stage keeps the contact conditioned; the
      ! final stage (lambda = 1) restores the full penalty, so the converged equilibrium is
      ! unchanged (a net-heavy chain catenary, unaffected before, converges bit-for-bit).
      IF (PRESENT(seabed_kn)) kn_stage = load_factors(s)*seabed_kn
      plain_first = .TRUE.
      IF (PRESENT(lm_only)) plain_first = .NOT. lm_only
      IF (plain_first) THEN
        CALL solve_stage(.FALSE.)
      ELSE
        converged = .FALSE.
      END IF
      ! A stage the plain Newton-Armijo solve stalls on is retried from the same warm start with
      ! the Levenberg-Marquardt globalization (see CD_Static_Cable_Solve): a fine mesh of a stiff
      ! grounded line must migrate its touchdown across many seabed-contact kinks, which the
      ! plain step cannot cross within its budget. Stages the plain solve converges are
      ! untouched, so their equilibria are bit-identical. A singular plain tangent (a slack
      ! element under the tension-only law) is retried the same way.
      IF (plain_first .AND. ErrStat == CD_STATIC_SINGULAR) THEN
        ErrStat = CD_STATIC_OK
        ErrMsg = ''
      END IF
      lm_retry = .TRUE.
      IF (PRESENT(plain_only)) lm_retry = .NOT. plain_only
      IF (ErrStat == CD_STATIC_OK .AND. .NOT. converged .AND. lm_retry) CALL solve_stage(.TRUE.)
      IF (ErrStat /= CD_STATIC_OK) RETURN    ! inner solve surfaced an error; q holds its best state
      IF (.NOT. converged) RETURN            ! this stage stalled; honest failure, q is the best state
      n_stages_done = s
      q_stage = q                            ! warm-start the next (heavier) stage
    END DO
  CONTAINS

    SUBROUTINE solve_stage(reg)
      !! One continuation stage from q_stage (host state), plain (reg=.FALSE.) or with the
      !! Levenberg-Marquardt globalization (reg=.TRUE.).
      LOGICAL, INTENT(IN) :: reg
      IF (PRESENT(current) .AND. PRESENT(seabed_kn)) THEN
        CALL CD_Static_Cable_Solve(q_stage, elem_conn, l0, ea, tension_only, f_stage, fixed_dofs, &
                                   cfg, q, converged, stalled, at_floor, n_iter_stage, ErrStat, ErrMsg, &
                                   seabed_z_floor=seabed_z_floor, seabed_kn=kn_stage, &
                                   current=current, current_load_factor=load_factors(s), bathymetry=bathymetry, &
                                   regularized=reg, compression_ratio=compression_ratio)
      ELSE IF (PRESENT(current)) THEN
        ! seabed_kn absent: still forward seabed_z_floor/bathymetry so the inner solve fail-closes
        ! on an incomplete seabed pair ((floor or bathymetry) .NEQV. seabed_kn), as before the split.
        CALL CD_Static_Cable_Solve(q_stage, elem_conn, l0, ea, tension_only, f_stage, fixed_dofs, &
                                   cfg, q, converged, stalled, at_floor, n_iter_stage, ErrStat, ErrMsg, &
                                   seabed_z_floor=seabed_z_floor, &
                                   current=current, current_load_factor=load_factors(s), bathymetry=bathymetry, &
                                   regularized=reg, compression_ratio=compression_ratio)
      ELSE IF (PRESENT(seabed_kn)) THEN
        CALL CD_Static_Cable_Solve(q_stage, elem_conn, l0, ea, tension_only, f_stage, fixed_dofs, &
                                   cfg, q, converged, stalled, at_floor, n_iter_stage, ErrStat, ErrMsg, &
                                   seabed_z_floor=seabed_z_floor, seabed_kn=kn_stage, bathymetry=bathymetry, &
                                   regularized=reg, compression_ratio=compression_ratio)
      ELSE
        ! seabed_kn absent: forward seabed_z_floor/bathymetry so an incomplete seabed pair is still
        ! rejected by the inner solve (fail-closed), rather than silently running a no-seabed solve.
        CALL CD_Static_Cable_Solve(q_stage, elem_conn, l0, ea, tension_only, f_stage, fixed_dofs, &
                                   cfg, q, converged, stalled, at_floor, n_iter_stage, ErrStat, ErrMsg, &
                                   seabed_z_floor=seabed_z_floor, bathymetry=bathymetry, regularized=reg, &
                                   compression_ratio=compression_ratio)
      END IF
      n_iter_total = n_iter_total + n_iter_stage
    END SUBROUTINE solve_stage
  END SUBROUTINE CD_Static_Cable_Solve_Continuation

  SUBROUTINE CD_Static_Friction_Anchors(q, current, seabed_kn, anchors, ErrStat, ErrMsg, seabed_z_floor, &
                                        bathymetry)
    !! Stick-slip friction anchors that continue a static equilibrium q solved with the
    !! seabed friction of current into the dynamics: every node's static spring force f_s
    !! (CD_Seabed_Friction_Spring at its normal reaction in q) and the anchor x - f_s/k at
    !! which a linear spring of the same stiffness k (seabed_kn) gives f_s. Without the
    !! friction (or off the seabed) the anchor is the node's own position.
    REAL(wp), INTENT(IN) :: q(:), seabed_kn(:)
    TYPE(CableCurrentLoad), INTENT(IN) :: current
    REAL(wp), INTENT(OUT) :: anchors(:, :)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    REAL(wp), INTENT(IN), OPTIONAL :: seabed_z_floor
    TYPE(CD_BathymetryType), INTENT(IN), OPTIONAL :: bathymetry
    INTEGER :: n_nodes, i, es
    REAL(wp) :: z_floor, dfdx, dfdy, normal, tangent, fvec(3), jac(3, 3), f(2), dfd(2, 2), dfc(2), curv(3)
    CHARACTER(1024) :: em
    ErrStat = CD_STATIC_OK
    ErrMsg = ''
    n_nodes = SIZE(q)/3
    anchors = CD_ZERO
    IF (MOD(SIZE(q), 3) /= 0 .OR. SIZE(seabed_kn) /= n_nodes .OR. SIZE(anchors, 1) /= 2 .OR. &
        SIZE(anchors, 2) /= n_nodes) THEN
      CALL fail(ErrStat, ErrMsg, 'friction anchors: inconsistent shapes')
      RETURN
    END IF
    DO i = 1, n_nodes
      anchors(:, i) = q(3*i - 2:3*i - 1)
    END DO
    IF (.NOT. (current%friction_mu > CD_ZERO) .OR. .NOT. ALLOCATED(current%friction_ref)) RETURN
    IF (SIZE(current%friction_ref, 1) /= 2 .OR. SIZE(current%friction_ref, 2) /= n_nodes) THEN
      CALL fail(ErrStat, ErrMsg, 'friction anchors: friction_ref must have shape (2, n_nodes)')
      RETURN
    END IF
    DO i = 1, n_nodes
      z_floor = CD_ZERO
      dfdx = CD_ZERO
      dfdy = CD_ZERO
      curv = CD_ZERO
      IF (PRESENT(bathymetry)) THEN
        CALL CD_Bathymetry_Floor_Gradient(bathymetry, q(3*i - 2), q(3*i - 1), z_floor, dfdx, dfdy, es, em, &
                                          crease_curvature=curv)
        IF (es /= CD_BATHY_OK) THEN
          CALL fail(ErrStat, ErrMsg, 'friction anchors: bathymetry query failed: '//TRIM(em))
          RETURN
        END IF
      ELSE IF (PRESENT(seabed_z_floor)) THEN
        z_floor = seabed_z_floor
      ELSE
        RETURN
      END IF
      IF (ABS(dfdx) > CD_ZERO .OR. ABS(dfdy) > CD_ZERO .OR. ANY(ABS(curv) > CD_ZERO)) THEN
        IF (ANY(ABS(curv) > CD_ZERO)) THEN
          ! a crease band: the scalar normal law, as in the static residual
          CALL CD_Seabed_Normal_Law((z_floor - q(3*i))/SQRT(CD_ONE + dfdx*dfdx + dfdy*dfdy), seabed_kn(i), &
                                    normal, tangent)
        ELSE
          CALL CD_Seabed_Normal_Contact(z_floor - q(3*i), dfdx, dfdy, seabed_kn(i), fvec, jac)
          normal = NORM2(fvec)
        END IF
      ELSE
        CALL CD_Seabed_Normal_Law(z_floor - q(3*i), seabed_kn(i), normal, tangent)
      END IF
      IF (current%friction_mu_axial > CD_ZERO .AND. ABS(current%friction_mu_axial - current%friction_mu) > CD_ZERO) THEN
        CALL CD_Seabed_Friction_Aniso(CD_FRICTION_SPRING, q(3*i - 2:3*i - 1) - current%friction_ref(:, i), &
                                      seabed_kn(i), normal, current%friction_mu_axial, current%friction_mu, &
                                      friction_chord(q, i), f, dfd, dfc)
      ELSE
        CALL CD_Seabed_Friction_Spring(q(3*i - 2:3*i - 1) - current%friction_ref(:, i), seabed_kn(i), &
                                       current%friction_mu*normal, f, dfd, dfc)
      END IF
      anchors(:, i) = q(3*i - 2:3*i - 1) - f/seabed_kn(i)
    END DO
  END SUBROUTINE CD_Static_Friction_Anchors

  SUBROUTINE CD_Static_As_Laid_Reference(origin, azimuth, l0, ea, laid_tension, ref, ErrStat, ErrMsg, bathymetry, &
                                         sink, kn)
    !! As-laid position of a line on the seabed, the reference of its static seabed friction
    !! (OrcaFlex's "as laid" statics seabed friction policy): the line is laid from its
    !! bottom end (node 1, horizontal position origin) in the horizontal direction azimuth
    !! [rad, from global +x toward +y], following the seabed profile, at the effective
    !! tension laid_tension [N]. Node i then lies at the stretched arc length
    !! s_i = sum_{e < i} l0_e (1 + laid_tension/ea_e) from node 1 along the seabed, so
    !! ref(1:2, i) = origin + d_i (cos, sin)(azimuth), where the seabed path over the
    !! horizontal distance d_i is s_i long: d_i = s_i on a level floor (no bathymetry),
    !! and on a bathymetry the path is integrated in sub-steps of at most 1 m with the
    !! midpoint slope along the azimuth. If every node rested at its reference, the line
    !! would carry laid_tension throughout.
    !! sink (optional, per node, on a bathymetry): the static penalty penetration factor
    !! w_i/k_i of each node (its submerged weight over its seabed stiffness). A laid node
    !! sinks into the penalty seabed along the surface normal, which on a slope moves it
    !! horizontally by w_i (z_x, z_y)/k_i; its reference moves with it, so the normal sink
    !! adds no spurious friction deflection (a deflection normal to the seabed is not a
    !! friction deflection, as in OrcaFlex's in-plane friction): the spring of a node laid at
    !! rest on a slope carries only the slope load that friction holds there.
    !! kn (optional, per node, with sink): the nodal seabed stiffness. With a positive
    !! laid_tension on a bathymetry whose slope varies, the tension turns at every node of
    !! the laid path and presses it into the seabed (over a crest) or lifts it (in a hollow);
    !! the normal component of that turning force over kn is added to the node's sink, so
    !! the line laid at its as-laid tension rests on its laid path, its springs carrying
    !! only the slope and turning loads along the seabed.
    REAL(wp), INTENT(IN) :: origin(2), azimuth, l0(:), ea(:), laid_tension
    REAL(wp), INTENT(OUT) :: ref(:, :)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    TYPE(CD_BathymetryType), INTENT(IN), OPTIONAL :: bathymetry
    REAL(wp), INTENT(IN), OPTIONAL :: sink(:), kn(:)
    INTEGER :: n_elem, e, j, nsub, es
    REAL(wp) :: dir(2), d, ds, step, x, y, zf, gx, gy, g, dshort, sink_j, p(3, 3), t_in(3), t_out(3), nrm(3)
    REAL(wp), ALLOCATABLE :: ref0(:, :)
    CHARACTER(1024) :: em

    ErrStat = CD_STATIC_OK
    ErrMsg = ''
    n_elem = SIZE(l0)
    IF (n_elem < 1 .OR. SIZE(ea) /= n_elem .OR. SIZE(ref, 1) /= 2 .OR. SIZE(ref, 2) /= n_elem + 1) THEN
      CALL fail(ErrStat, ErrMsg, 'as-laid reference: inconsistent shapes')
      RETURN
    END IF
    IF (.NOT. (CD_All_Finite(origin) .AND. CD_Is_Finite(azimuth) .AND. CD_Is_Finite(laid_tension) .AND. &
               CD_All_Finite(l0) .AND. CD_All_Finite(ea))) THEN
      CALL fail(ErrStat, ErrMsg, 'as-laid reference: inputs must be finite')
      RETURN
    END IF
    IF (ANY(l0 <= CD_ZERO) .OR. ANY(ea <= CD_ZERO) .OR. laid_tension < CD_ZERO) THEN
      CALL fail(ErrStat, ErrMsg, 'as-laid reference: l0 and ea must be positive and laid_tension non-negative')
      RETURN
    END IF
    ! A laid tension that stretches an element beyond its length is no laid state (and would
    ! make the seabed path integration below unbounded): fail closed.
    IF (ANY(laid_tension > ea)) THEN
      CALL fail(ErrStat, ErrMsg, 'as-laid reference: asLaidTension stretches an element by more than 100 % '// &
                '(asLaidTension > EA); give the tension the line was laid with')
      RETURN
    END IF
    IF (PRESENT(bathymetry) .AND. SUM(l0)*2.0_wp > 1.0e7_wp) THEN
      CALL fail(ErrStat, ErrMsg, 'as-laid reference: the laid length exceeds the 1e7 m the seabed path '// &
                'integration supports')
      RETURN
    END IF
    dir = [COS(azimuth), SIN(azimuth)]
    ref(:, 1) = origin
    d = CD_ZERO
    DO e = 1, n_elem
      ds = l0(e)*(CD_ONE + laid_tension/ea(e))
      IF (PRESENT(bathymetry)) THEN
        ! the horizontal advance is ds less the shortening of the sloped sub-steps, so a
        ! level patch advances by exactly ds, bit-for-bit as on a flat floor
        nsub = MAX(1, CEILING(ds))
        step = ds/REAL(nsub, wp)
        dshort = CD_ZERO
        DO j = 1, nsub
          ! midpoint slope along the azimuth (at the level-floor midpoint of the sub-step)
          x = origin(1) + (d + REAL(j - 1, wp)*step - dshort + 0.5_wp*step)*dir(1)
          y = origin(2) + (d + REAL(j - 1, wp)*step - dshort + 0.5_wp*step)*dir(2)
          CALL CD_Bathymetry_Floor_Gradient(bathymetry, x, y, zf, gx, gy, es, em)
          IF (es /= CD_BATHY_OK) THEN
            CALL fail(ErrStat, ErrMsg, 'as-laid reference: bathymetry query failed: '//TRIM(em))
            RETURN
          END IF
          g = gx*dir(1) + gy*dir(2)
          dshort = dshort + step*(CD_ONE - CD_ONE/SQRT(CD_ONE + g*g))
        END DO
        d = d + (ds - dshort)
      ELSE
        d = d + ds
      END IF
      ref(:, e + 1) = origin + d*dir
    END DO
    IF (PRESENT(sink) .AND. PRESENT(bathymetry)) THEN
      IF (SIZE(sink) /= n_elem + 1 .OR. .NOT. CD_All_Finite(sink)) THEN
        CALL fail(ErrStat, ErrMsg, 'as-laid reference: sink must be finite, one entry per node')
        RETURN
      END IF
      IF (PRESENT(kn)) THEN
        IF (SIZE(kn) /= n_elem + 1 .OR. .NOT. CD_All_Finite(kn)) THEN
          CALL fail(ErrStat, ErrMsg, 'as-laid reference: kn must be finite, one entry per node')
          RETURN
        END IF
      END IF
      ! node 1 is held: its reference stays at origin. The turning force of the laid tension
      ! is evaluated on the path before the sink (a second-order correction).
      ref0 = ref
      DO j = 2, n_elem + 1
        sink_j = sink(j)
        IF (PRESENT(kn) .AND. laid_tension > CD_ZERO .AND. j <= n_elem) THEN
          IF (kn(j) > CD_ZERO) THEN
            DO e = 1, 3
              CALL CD_Bathymetry_Floor_Gradient(bathymetry, ref0(1, j + e - 2), ref0(2, j + e - 2), p(3, e), gx, gy, &
                                                es, em)
              IF (es /= CD_BATHY_OK) THEN
                CALL fail(ErrStat, ErrMsg, 'as-laid reference: bathymetry query failed: '//TRIM(em))
                RETURN
              END IF
              p(1:2, e) = ref0(:, j + e - 2)
              IF (e == 2) nrm = [-gx, -gy, CD_ONE]/SQRT(CD_ONE + gx*gx + gy*gy)
            END DO
            t_in = p(:, 2) - p(:, 1)
            t_out = p(:, 3) - p(:, 2)
            IF (NORM2(t_in) > CD_ZERO .AND. NORM2(t_out) > CD_ZERO) THEN
              ! the tension's force on node j is T (t_out - t_in); its component P into the
              ! seabed (against the upward normal) deepens the normal penetration by P/kn,
              ! which moves the node horizontally by (P/kn) (z_x, z_y)/s: in units of the
              ! sink (the factor of the gradient, w/kn for the weight) that is P/(kn s), with
              ! 1/s = nrm(3) the vertical component of the unit normal
              sink_j = MAX(CD_ZERO, sink_j - laid_tension*DOT_PRODUCT(t_out/NORM2(t_out) - t_in/NORM2(t_in), nrm)* &
                           nrm(3)/kn(j))
            END IF
          END IF
        END IF
        IF (.NOT. (sink_j > CD_ZERO)) CYCLE
        CALL CD_Bathymetry_Floor_Gradient(bathymetry, ref(1, j), ref(2, j), zf, gx, gy, es, em)
        IF (es /= CD_BATHY_OK) THEN
          CALL fail(ErrStat, ErrMsg, 'as-laid reference: bathymetry query failed: '//TRIM(em))
          RETURN
        END IF
        ref(:, j) = ref(:, j) + sink_j*[gx, gy]
      END DO
    END IF
  END SUBROUTINE CD_Static_As_Laid_Reference

  SUBROUTINE CD_Static_As_Laid_Seed(anchor, fairlead, l0, ea, weight, ref, q, ok, seabed_z_floor, bathymetry)
    !! As-laid seed of a line with static seabed friction (OrcaFlex's picture: the line laid
    !! from its anchor, node 1, and its top end then moved to the fairlead, node n): nodes
    !! 1..k rest on the seabed at their as-laid positions ref(1:2, :) (the friction
    !! reference, CD_Static_As_Laid_Reference), and nodes k..n form the fully suspended
    !! elastic catenary from node k to the fairlead. k is the first node at which the
    !! suspended span leaves the seabed at or above the local seabed angle along its own
    !! heading (tangent lift-off), found by bisection; a line laid past the point under its
    !! fairlead turns back there, over its grounded run. q holds the positions (3 n_nodes);
    !! ok = .FALSE. when no node qualifies. One of seabed_z_floor or bathymetry is given.
    REAL(wp), INTENT(IN) :: anchor(3), fairlead(3), l0(:), ea(:), weight(:), ref(:, :)
    REAL(wp), INTENT(OUT) :: q(:)
    LOGICAL, INTENT(OUT) :: ok
    REAL(wp), INTENT(IN), OPTIONAL :: seabed_z_floor
    TYPE(CD_BathymetryType), INTENT(IN), OPTIONAL :: bathymetry
    INTEGER :: n_nodes, k_lo, k_hi, k_mid, it
    REAL(wp) :: f_lo, f_hi, f_mid
    LOGICAL :: v_lo, v_hi, v_mid

    ok = .FALSE.
    q = CD_ZERO
    n_nodes = SIZE(l0) + 1
    IF (SIZE(q) /= 3*n_nodes .OR. SIZE(ref, 1) /= 2 .OR. SIZE(ref, 2) /= n_nodes .OR. SIZE(ea) /= n_nodes - 1 &
        .OR. SIZE(weight) /= n_nodes - 1) RETURN
    IF (.NOT. (PRESENT(seabed_z_floor) .OR. PRESENT(bathymetry))) RETURN
    k_lo = 1
    CALL laid_at(k_lo, f_lo, v_lo)
    IF (v_lo .AND. f_lo >= CD_ZERO) THEN
      ok = .TRUE.
      RETURN
    END IF
    k_hi = n_nodes - 1
    CALL laid_at(k_hi, f_hi, v_hi)
    IF (.NOT. (v_hi .AND. f_hi >= CD_ZERO)) RETURN
    DO it = 1, 64
      IF (k_hi - k_lo <= 1) EXIT
      k_mid = (k_lo + k_hi)/2
      CALL laid_at(k_mid, f_mid, v_mid)
      IF (v_mid .AND. f_mid >= CD_ZERO) THEN
        k_hi = k_mid
      ELSE
        k_lo = k_mid
      END IF
    END DO
    CALL laid_at(k_hi, f_hi, v_hi)
    ok = v_hi

  CONTAINS

    SUBROUTINE laid_at(k, mismatch, valid)
      !! The seed with lift-off node k into q; mismatch is the elevation angle of the first
      !! suspended element minus the seabed angle along its horizontal heading at the
      !! lift-off point (>= 0: the span leaves the seabed tangent or steeper).
      INTEGER, INTENT(IN) :: k
      REAL(wp), INTENT(OUT) :: mismatch
      LOGICAL, INTENT(OUT) :: valid
      INTEGER :: i, es_d
      REAL(wp) :: zf, gx, gy, g, p(3), h_s, g_s, u(3), uh
      REAL(wp), ALLOCATABLE :: q_sus(:)
      CHARACTER(1024) :: em_d

      valid = .FALSE.
      mismatch = -HUGE(CD_ONE)
      q(1:3) = anchor
      DO i = 2, k
        CALL floor_at(ref(1, i), ref(2, i), zf, gx, gy, es_d)
        IF (es_d /= 0) RETURN
        q(3*i - 2:3*i) = [ref(1, i), ref(2, i), zf]
      END DO
      p = q(3*k - 2:3*k)
      IF (fairlead(3) <= p(3)) RETURN
      ALLOCATE (q_sus(3*(n_nodes - k + 1)))
      CALL CD_Catenary_Seed(p, fairlead, l0(k:), ea(k:), weight(k:), q_sus, h_s, g_s, es_d, em_d, &
                            suspended=.TRUE.)
      IF (es_d /= CD_CAT_OK) RETURN
      IF (.NOT. CD_All_Finite(q_sus)) RETURN
      q(3*k - 2:) = q_sus
      u = q_sus(4:6) - q_sus(1:3)
      IF (NORM2(u) <= CD_ZERO) RETURN
      uh = NORM2(u(1:2))
      g = CD_ZERO
      IF (uh > CD_ZERO) THEN
        CALL floor_at(p(1), p(2), zf, gx, gy, es_d)
        IF (es_d /= 0) RETURN
        g = (gx*u(1) + gy*u(2))/uh
      END IF
      mismatch = ATAN2(u(3), MAX(uh, TINY(CD_ONE))) - ATAN(g)
      valid = .TRUE.
    END SUBROUTINE laid_at

    SUBROUTINE floor_at(x, y, zf, gx, gy, es_f)
      !! Seabed elevation and gradient under (x, y): the flat floor or the bathymetry.
      REAL(wp), INTENT(IN) :: x, y
      REAL(wp), INTENT(OUT) :: zf, gx, gy
      INTEGER, INTENT(OUT) :: es_f
      CHARACTER(1024) :: em_f
      es_f = 0
      gx = CD_ZERO
      gy = CD_ZERO
      IF (PRESENT(bathymetry)) THEN
        CALL CD_Bathymetry_Floor_Gradient(bathymetry, x, y, zf, gx, gy, es_f, em_f)
      ELSE
        zf = seabed_z_floor
      END IF
    END SUBROUTINE floor_at
  END SUBROUTINE CD_Static_As_Laid_Seed

  PURE FUNCTION friction_chord(q, node) RESULT(axis)
    !! Horizontal line axis at a node for anisotropic friction: the chord through its
    !! neighbours (one-sided at the ends), the axis of CableDyn_Model's dynamics.
    REAL(wp), INTENT(IN) :: q(:)
    INTEGER, INTENT(IN) :: node
    REAL(wp) :: axis(2)
    INTEGER :: nn, ia, ib
    nn = SIZE(q)/3
    ia = MAX(1, node - 1)
    ib = MIN(nn, node + 1)
    axis = q(3*ib - 2:3*ib - 1) - q(3*ia - 2:3*ia - 1)
  END FUNCTION friction_chord

  PURE REAL(wp) FUNCTION CD_Static_Anchor_Seabed_Tolerance(z_floor) RESULT(tol)
    !! Distance [m] within which a Fixed anchor counts as resting on the seabed at elevation
    !! z_floor: max(1 mm, 1e-5 |z_floor|). Anchors inside this band (above or below) are
    !! treated as on the seabed; an anchor further below is a genuine input error.
    REAL(wp), INTENT(IN) :: z_floor
    tol = MAX(1.0e-3_wp, 1.0e-5_wp*ABS(z_floor))
  END FUNCTION CD_Static_Anchor_Seabed_Tolerance

  SUBROUTINE CD_Static_Line_Equilibrium(anchor, fairlead, elem_conn, l0, ea, weight, f_ext, cfg, tension_only, &
                                        q, converged, report, ErrStat, ErrMsg, seabed_z_floor, seabed_kn, &
                                        bathymetry, current, load_factors, dry_waterline_z, dry_rho, dry_gravity, &
                                        dry_diameter, dry_load)
    !! Robust static equilibrium of one EI=0 line held at both ends: the single initializer
    !! shared by the static-only deck route and the dynamic-model initial condition (see
    !! line_equilibrium for the seeds and solver stages).
    !!
    !! f_ext is the submerged weight, full buoyancy everywhere. With the dry-part arguments
    !! (dry_waterline_z per node, dry_rho, dry_gravity, dry_diameter per element) the part of
    !! the line above its waterline carries its dry weight, as in the dynamic model's buoyancy
    !! recovery (CD_Buoyancy_Recovery_Element_Force): each element straddling or above the
    !! waterline gives back the buoyancy -(1 - f) rho g (pi/4) d^2 l0 / 2 at each of its nodes,
    !! f its submerged fraction. A line held above the surface (a fairlead on deck) then starts
    !! in the equilibrium the march holds; without them its dry part kept its buoyancy, and a
    !! chain hung 5 m above the surface jumped by 1e-3 of its fairlead load in the first step.
    !! The recovery load depends on the wetted lengths, so the solve is repeated with the
    !! recovery of the last solution as a constant load until the nodes move by less than
    !! DRY_TOL or the recovery changes by less than DRY_REL of the largest nodal load, below
    !! what the solver's own residual tolerance resolves (a fixed point: it contracts at the
    !! ratio of the recovery's stiffness rho g A / sin(inclination) to the line's own, a few
    !! 1e-3 for a hanging chain). A fully submerged
    !! line has no recovery and is solved once, unchanged. A fixed point that does not settle in
    !! DRY_MAX solves (a line floating at the surface, whose dry weight is its whole restoring)
    !! returns converged = .FALSE. with the reason. dry_load (optional) returns the recovery
    !! load at the solution, zero without the dry-part arguments: f_ext + dry_load is the
    !! external load of the equilibrium (its end forces, CD_Static_Line_End_Forces).
    REAL(wp), INTENT(IN) :: anchor(3), fairlead(3)
    INTEGER, INTENT(IN) :: elem_conn(:, :)
    REAL(wp), INTENT(IN) :: l0(:), ea(:), weight(:), f_ext(:)
    TYPE(CableSolverConfig), INTENT(IN) :: cfg
    LOGICAL, INTENT(IN) :: tension_only
    REAL(wp), INTENT(OUT) :: q(:)
    LOGICAL, INTENT(OUT) :: converged
    TYPE(CD_StaticLineReport), INTENT(OUT) :: report
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    REAL(wp), INTENT(IN), OPTIONAL :: seabed_z_floor
    REAL(wp), INTENT(IN), OPTIONAL :: seabed_kn(:)
    TYPE(CD_BathymetryType), INTENT(IN), OPTIONAL :: bathymetry
    TYPE(CableCurrentLoad), INTENT(IN), OPTIONAL :: current
    REAL(wp), INTENT(IN), OPTIONAL :: load_factors(:)
    REAL(wp), INTENT(IN), OPTIONAL :: dry_waterline_z(:), dry_rho, dry_gravity, dry_diameter(:)
    REAL(wp), INTENT(OUT), OPTIONAL :: dry_load(:)
    ! fixed-point tolerances on the node positions [m] and on the recovery load (relative to
    ! the largest nodal load), and the solve budget
    REAL(wp), PARAMETER :: DRY_TOL = 1.0e-9_wp, DRY_REL = 1.0e-10_wp
    INTEGER, PARAMETER :: DRY_MAX = 50
    REAL(wp), ALLOCATABLE :: f_dry(:), q_prev(:), f_prev(:)
    REAL(wp) :: change, f_scale
    INTEGER :: k, n_it
    CHARACTER(64) :: num

    IF (PRESENT(dry_load)) dry_load = CD_ZERO
    CALL line_equilibrium(anchor, fairlead, elem_conn, l0, ea, weight, f_ext, cfg, tension_only, q, converged, &
                          report, ErrStat, ErrMsg, seabed_z_floor, seabed_kn, bathymetry, current, load_factors)
    IF (.NOT. (PRESENT(dry_waterline_z) .AND. PRESENT(dry_rho) .AND. PRESENT(dry_gravity) .AND. &
               PRESENT(dry_diameter))) RETURN
    IF (ErrStat /= CD_STATIC_OK .OR. .NOT. converged) RETURN
    IF (SIZE(dry_waterline_z) /= SIZE(q)/3 .OR. SIZE(dry_diameter) /= SIZE(l0) .OR. &
        (PRESENT(dry_load) .AND. SIZE(f_ext) /= SIZE(q))) THEN
      CALL fail(ErrStat, ErrMsg, 'line equilibrium: dry_waterline_z (n_nodes) / dry_diameter (n_elem) shapes')
      converged = .FALSE.
      RETURN
    END IF
    IF (PRESENT(dry_load)) THEN
      IF (SIZE(dry_load) /= SIZE(q)) THEN
        CALL fail(ErrStat, ErrMsg, 'line equilibrium: dry_load must have shape (3 n_nodes)')
        converged = .FALSE.
        RETURN
      END IF
    END IF
    ALLOCATE (f_dry(SIZE(q)), q_prev(SIZE(q)), f_prev(SIZE(q)))
    CALL dry_recovery(q, f_dry)
    IF (ErrStat /= CD_STATIC_OK) RETURN
    ! fully submerged: no recovery, the solution stands as solved
    IF (ALL(ABS(f_dry) <= CD_ZERO)) RETURN
    f_scale = MAXVAL(ABS(f_ext))
    n_it = report%n_iter
    DO k = 1, DRY_MAX
      q_prev = q
      f_prev = f_dry
      CALL line_equilibrium(anchor, fairlead, elem_conn, l0, ea, weight, f_ext + f_dry, cfg, tension_only, q, &
                            converged, report, ErrStat, ErrMsg, seabed_z_floor, seabed_kn, bathymetry, current, &
                            load_factors)
      n_it = n_it + report%n_iter
      report%n_iter = n_it
      IF (ErrStat /= CD_STATIC_OK) RETURN
      IF (.NOT. converged) THEN
        report%message = 'with the dry weight above the waterline: '//TRIM(report%message)
        RETURN
      END IF
      change = MAXVAL(ABS(q - q_prev))
      CALL dry_recovery(q, f_dry)
      IF (ErrStat /= CD_STATIC_OK) RETURN
      IF (change <= DRY_TOL .OR. MAXVAL(ABS(f_dry - f_prev)) <= DRY_REL*f_scale) THEN
        ! the recovery the returned state was solved with (its end forces balance it exactly)
        IF (PRESENT(dry_load)) dry_load = f_prev
        RETURN
      END IF
    END DO
    converged = .FALSE.
    WRITE (num, '(ES9.2)') change
    report%message = 'the dry weight above the waterline did not settle to a fixed point (the nodes still move '// &
                     TRIM(ADJUSTL(num))//' m per solve): a line floating at the surface is outside the EI = 0 '// &
                     'static start'

  CONTAINS

    SUBROUTINE dry_recovery(qs, f)
      !! The buoyancy recovery of the dry part of every element in state qs.
      REAL(wp), INTENT(IN) :: qs(:)
      REAL(wp), INTENT(OUT) :: f(:)
      INTEGER :: es
      CHARACTER(1024) :: em
      CALL CD_Static_Line_Dry_Load(qs, elem_conn, l0, dry_waterline_z, dry_rho, dry_gravity, dry_diameter, f, es, em)
      IF (es /= CD_STATIC_OK) THEN
        CALL fail(ErrStat, ErrMsg, 'line equilibrium: '//TRIM(em))
        converged = .FALSE.
      END IF
    END SUBROUTINE dry_recovery
  END SUBROUTINE CD_Static_Line_Equilibrium

  SUBROUTINE CD_Static_Line_Dry_Load(q, elem_conn, l0, waterline_z, rho, gravity, diameter, f, ErrStat, ErrMsg)
    !! The dry part's weight of an EI = 0 line in state q (3 n_nodes), as the dynamic model's
    !! buoyancy recovery gives it (CD_Buoyancy_Recovery_Element_Force): each element straddling
    !! or above the waterline (waterline_z per node) gives back the buoyancy
    !! -(1 - f) rho g (pi/4) d^2 l0 / 2 at each of its nodes, f its submerged fraction
    !! (diameter per element). f is exactly zero for a line wholly below its waterline.
    REAL(wp), INTENT(IN) :: q(:)
    INTEGER, INTENT(IN) :: elem_conn(:, :)
    REAL(wp), INTENT(IN) :: l0(:), waterline_z(:), rho, gravity, diameter(:)
    REAL(wp), INTENT(OUT) :: f(:)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    REAL(wp) :: fe(6)
    INTEGER :: e, a, b, es
    CHARACTER(1024) :: em
    ErrStat = CD_STATIC_OK
    ErrMsg = ''
    f = CD_ZERO
    IF (SIZE(waterline_z) /= SIZE(q)/3 .OR. SIZE(diameter) /= SIZE(l0) .OR. SIZE(f) /= SIZE(q) .OR. &
        SIZE(elem_conn, 2) /= SIZE(l0)) THEN
      CALL fail(ErrStat, ErrMsg, 'dry-part buoyancy: waterline_z (n_nodes) / diameter (n_elem) / f shapes')
      RETURN
    END IF
    DO e = 1, SIZE(l0)
      a = elem_conn(1, e)
      b = elem_conn(2, e)
      CALL CD_Buoyancy_Recovery_Element_Force(q(3*a - 2:3*a), q(3*b - 2:3*b), l0(e), waterline_z(a), &
                                              waterline_z(b), rho, diameter(e), gravity, fe, es, em)
      IF (es /= CD_HYDRO_OK) THEN
        CALL fail(ErrStat, ErrMsg, 'dry-part buoyancy: '//TRIM(em))
        RETURN
      END IF
      f(3*a - 2:3*a) = f(3*a - 2:3*a) + fe(1:3)
      f(3*b - 2:3*b) = f(3*b - 2:3*b) + fe(4:6)
    END DO
  END SUBROUTINE CD_Static_Line_Dry_Load

  SUBROUTINE line_equilibrium(anchor, fairlead, elem_conn, l0, ea, weight, f_ext, cfg, tension_only, &
                              q, converged, report, ErrStat, ErrMsg, seabed_z_floor, seabed_kn, &
                              bathymetry, current, load_factors)
    !! Robust static equilibrium of one EI=0 line held at both ends under the constant load
    !! f_ext (CD_Static_Line_Equilibrium adds the dry part above the waterline).
    !!
    !! Node 1 is the anchor and node n the fairlead (both held); weight is the signed
    !! submerged weight per unit length of each element (downward positive) used by the seeds,
    !! f_ext the assembled external load. tension_only selects the physical constitutive law:
    !! an EI=0 mooring line cannot carry compression, so its equilibrium must have no element
    !! in compression (beyond round-off).
    !!
    !! Seeds, in order: the elastic catenary (grounded when the anchor rests on the seabed,
    !! fully suspended otherwise); on a bathymetry, a grounded run draped on the seabed
    !! profile that lifts off into a suspended catenary; the grounded catenary lowered by
    !! the static penalty penetration; for a grounded line longer than span plus rise, the
    !! H -> 0 limit (a straight hanging leg with the excess on the seabed, folded back where
    !! the seabed keeps falling); the other catenary variant; and a two-leg polyline of the
    !! right length that never compresses the line. Seed nodes deeper below the seabed than
    !! their static penetration are lifted onto it. With static seabed friction (current
    !! carrying friction_ref, CD_Static_As_Laid_Reference) the as-laid seed is tried first:
    !! the nodes up to a lift-off node rest at their as-laid positions, and the rest hang as
    !! the suspended catenary to the fairlead (the line laid, then its top end moved). The
    !! reference is laid from the lower end of the line: node 1, or node n when it lies below
    !! node 1 (a line without a Fixed anchor at node 1), whose seed is the mirror image, laid
    !! from node n and hanging to node 1.
    !! For each seed:
    !!   A. Newton (plain, then Levenberg-Marquardt) with the compression-capable law, first at
    !!      the full load, then by load continuation. Accepted when it converges and (for a
    !!      tension-only line) no element is compressed beyond a 1e-6 relative round-off
    !!      band: all elements are taut, so it is also the tension-only equilibrium.
    !!   B. (tension-only lines, when A fails or lands on a compressed strut/arch branch)
    !!      Levenberg-Marquardt with the slack-capable law of CD_Static_Cable_Solve: a
    !!      compressed-branch stiffness r EA with r EA of order 1e-3, then 1e-7, of the largest
    !!      nodal load (too weak to hold an arch), then the exact tension-only law (r = 0).
    !!      Accepted when the exact tension-only residual meets the solver tolerance (or, from
    !!      the 1e-7 stage, a 1e-6 relative admissibility tolerance).
    !! A line for which no seed yields an admissible equilibrium returns converged=.FALSE. with
    !! the reason in report%message (fail closed; q holds the last attempt). ErrStat /= 0 only
    !! for invalid inputs.
    REAL(wp), INTENT(IN) :: anchor(3), fairlead(3)
    INTEGER, INTENT(IN) :: elem_conn(:, :)
    REAL(wp), INTENT(IN) :: l0(:), ea(:), weight(:), f_ext(:)
    TYPE(CableSolverConfig), INTENT(IN) :: cfg
    LOGICAL, INTENT(IN) :: tension_only
    REAL(wp), INTENT(OUT) :: q(:)
    LOGICAL, INTENT(OUT) :: converged
    TYPE(CD_StaticLineReport), INTENT(OUT) :: report
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    REAL(wp), INTENT(IN), OPTIONAL :: seabed_z_floor
    REAL(wp), INTENT(IN), OPTIONAL :: seabed_kn(:)
    TYPE(CD_BathymetryType), INTENT(IN), OPTIONAL :: bathymetry
    TYPE(CableCurrentLoad), INTENT(IN), OPTIONAL :: current
    REAL(wp), INTENT(IN), OPTIONAL :: load_factors(:)  !! load-continuation ramp (default 0.25 .. 1)

    REAL(wp), PARAMETER :: ADM_REL = 1.0e-6_wp        ! admissibility band (relative)
    REAL(wp), PARAMETER :: BETA_SOFT = 1.0e-3_wp      ! first slack-capable stage
    REAL(wp), PARAMETER :: BETA_FIRM = 1.0e-7_wp      ! second slack-capable stage
    REAL(wp), PARAMETER :: RAMP_DEFAULT(4) = [0.25_wp, 0.5_wp, 0.75_wp, CD_ONE]
    REAL(wp), ALLOCATABLE :: ramp(:)
    INTEGER :: n_dof, n_elem, n_nodes, iseed, iorder, n_it, n_st, es
    INTEGER, PARAMETER :: SEED_ORDER(6) = [1, 5, 6, 2, 3, 4]
    ! with static seabed friction, the as-laid seed (7) first
    INTEGER, PARAMETER :: SEED_ORDER_LAID(7) = [7, 1, 5, 6, 2, 3, 4]
    INTEGER, ALLOCATABLE :: fixed(:), order(:)
    LOGICAL :: as_laid
    REAL(wp), ALLOCATABLE :: q_seed(:), q_try(:), q_mid(:), q_best(:), ten(:)
    REAL(wp) :: f_node, t_min, t_max, r_soft, r_firm, floor_a, slope_a, h_cat, g_cat
    LOGICAL :: has_seabed, anchor_grounded, conv, stalled, at_floor, have_seed, done, have_best
    CHARACTER(1024) :: em
    CHARACTER(64) :: seed_name
    ! The seed notes of a failed solve (report%message holds them after a fixed prefix). Up to
    ! seven seeds note up to three stages each, more than this holds: add_note ends the list with
    ! an omission marker instead of cutting a note.
    CHARACTER(480) :: notes
    LOGICAL :: notes_full
    TYPE(CableSolverConfig) :: cfg_adm

    converged = .FALSE.
    ErrStat = CD_STATIC_OK
    ErrMsg = ''
    report = CD_StaticLineReport()
    q = CD_ZERO
    n_dof = SIZE(q)
    n_elem = SIZE(l0)
    n_nodes = n_elem + 1
    IF (n_elem < 1 .OR. SIZE(elem_conn, 2) /= n_elem .OR. SIZE(ea) /= n_elem .OR. SIZE(weight) /= n_elem &
        .OR. n_dof /= 3*n_nodes .OR. SIZE(f_ext) /= n_dof) THEN
      CALL fail(ErrStat, ErrMsg, 'line equilibrium: inconsistent mesh/load shapes')
      RETURN
    END IF
    IF (.NOT. CD_All_Finite(anchor) .OR. .NOT. CD_All_Finite(fairlead) &
        .OR. .NOT. CD_All_Finite(weight) .OR. .NOT. CD_All_Finite(f_ext)) THEN
      CALL fail(ErrStat, ErrMsg, 'line equilibrium: end points and loads must be finite')
      RETURN
    END IF
    IF (PRESENT(seabed_z_floor) .AND. PRESENT(bathymetry)) THEN
      CALL fail(ErrStat, ErrMsg, 'line equilibrium: seabed_z_floor and bathymetry are mutually exclusive')
      RETURN
    END IF
    IF ((PRESENT(seabed_z_floor) .OR. PRESENT(bathymetry)) .NEQV. PRESENT(seabed_kn)) THEN
      CALL fail(ErrStat, ErrMsg, 'line equilibrium: seabed requires seabed_kn with seabed_z_floor or bathymetry')
      RETURN
    END IF
    has_seabed = PRESENT(seabed_kn)
    IF (has_seabed) THEN
      IF (SIZE(seabed_kn) /= n_nodes) THEN
        CALL fail(ErrStat, ErrMsg, 'line equilibrium: seabed_kn must have shape (n_nodes)')
        RETURN
      END IF
    END IF

    ALLOCATE (fixed(6), q_seed(n_dof), q_try(n_dof), q_mid(n_dof), q_best(n_dof), ten(n_elem))
    IF (PRESENT(load_factors)) THEN
      ! the continuation ramp is validated up front (it may otherwise only be reached by a
      ! fallback stage): positive, finite, strictly increasing, ending at the full load
      IF (SIZE(load_factors) < 1) THEN
        CALL fail(ErrStat, ErrMsg, 'line equilibrium: load_factors must contain at least one stage')
        RETURN
      END IF
      IF (.NOT. CD_All_Finite(load_factors) .OR. load_factors(1) <= CD_ZERO .OR. &
          ABS(load_factors(SIZE(load_factors)) - CD_ONE) > 1.0e-12_wp) THEN
        CALL fail(ErrStat, ErrMsg, 'line equilibrium: load_factors must be finite, positive and end at 1')
        RETURN
      END IF
      IF (SIZE(load_factors) > 1) THEN
        IF (ANY(load_factors(2:) <= load_factors(:SIZE(load_factors) - 1))) THEN
          CALL fail(ErrStat, ErrMsg, 'line equilibrium: load_factors must be strictly increasing')
          RETURN
        END IF
      END IF
      ramp = load_factors
    ELSE
      ramp = RAMP_DEFAULT
    END IF
    fixed = [1, 2, 3, n_dof - 2, n_dof - 1, n_dof]
    f_node = MAX(nodal_load_max(f_ext), TINY(CD_ONE)**0.25_wp)
    ! compressed-branch ratios: a fully collapsed slack element (eps = -1) then pushes with
    ! at most BETA * (largest nodal load), far too little to hold up a compressed arch
    r_soft = MIN(CD_ONE, BETA_SOFT*f_node/MAXVAL(ea))
    r_firm = MIN(CD_ONE, BETA_FIRM*f_node/MAXVAL(ea))
    cfg_adm = cfg
    cfg_adm%rel_tol = MAX(cfg%rel_tol, ADM_REL)

    anchor_grounded = .FALSE.
    floor_a = CD_ZERO
    slope_a = CD_ZERO
    IF (has_seabed) THEN
      floor_a = seabed_floor_at(anchor(1), anchor(2), es, em)
      IF (es /= 0) THEN
        CALL fail(ErrStat, ErrMsg, 'line equilibrium: seabed at the anchor: '//TRIM(em))
        RETURN
      END IF
      anchor_grounded = anchor(3) <= floor_a + CD_Static_Anchor_Seabed_Tolerance(floor_a)
      IF (PRESENT(bathymetry)) THEN
        ! mean seabed gradient along the horizontal anchor -> fairlead direction
        BLOCK
          REAL(wp) :: hvec(2), hlen, zf_f
          hvec = fairlead(1:2) - anchor(1:2)
          hlen = NORM2(hvec)
          IF (hlen > CD_ZERO) THEN
            zf_f = seabed_floor_at(fairlead(1), fairlead(2), es, em)
            IF (es == 0) slope_a = (zf_f - floor_a)/hlen
          END IF
        END BLOCK
      END IF
    END IF

    ! static seabed friction from an as-laid reference: the as-laid seed leads
    as_laid = .FALSE.
    IF (has_seabed .AND. PRESENT(current)) THEN
      IF (ALLOCATED(current%friction_ref) .AND. current%friction_mu > CD_ZERO .AND. current%friction_as_laid) &
        as_laid = SIZE(current%friction_ref, 1) == 2 .AND. SIZE(current%friction_ref, 2) == n_nodes
    END IF
    IF (as_laid) THEN
      order = SEED_ORDER_LAID
    ELSE
      order = SEED_ORDER
    END IF

    notes = ''
    notes_full = .FALSE.
    q_best = CD_ZERO
    have_best = .FALSE.
    DO iorder = 1, SIZE(order)
      ! seed order: (as laid,) catenary, bathymetry drape, catenary on the penetrated seabed,
      ! slack run, other catenary, polyline
      iseed = order(iorder)
      CALL build_seed(iseed, have_seed)
      IF (.NOT. have_seed) CYCLE
      report%seed = seed_name
      IF (has_seabed) THEN
        CALL lift_onto_seabed(q_seed, es, em)
        IF (es /= 0) THEN
          CALL fail(ErrStat, ErrMsg, 'line equilibrium: seed seabed projection: '//TRIM(em))
          RETURN
        END IF
      END IF
      ! the state returned on failure is the best attempt, and at least the first seed
      IF (.NOT. have_best) q_best = q_seed
      have_best = .TRUE.

      ! --- A: compression-capable Newton at the full load ---
      ! (not for the slack-run seed of a tension-only line: its grounded run is slack by
      ! construction, so the compression-capable law can only turn it into a strut)
      IF (.NOT. (tension_only .AND. iseed == 2)) THEN
        report%stage = 'compression-capable Newton'
        CALL run_solve(q_seed, [CD_ONE], .FALSE., -CD_ONE, cfg, q_try, conv)
        IF (ErrStat /= CD_STATIC_OK) RETURN
        CALL judge_compression_capable(done)
        IF (done) RETURN
      END IF

      ! --- B: slack-capable tension-only law, soft -> firm -> exact ---
      IF (tension_only) THEN
        report%stage = 'tension-only (slack-capable) Newton, soft compression branch'
        CALL run_solve(q_seed, [CD_ONE], .TRUE., r_soft, cfg, q_mid, conv)
        IF (ErrStat /= CD_STATIC_OK) RETURN
        IF (.NOT. conv) THEN
          report%stage = 'tension-only (slack-capable) load continuation'
          CALL run_solve(q_seed, ramp, .TRUE., r_soft, cfg, q_mid, conv)
          IF (ErrStat /= CD_STATIC_OK) RETURN
        END IF
        IF (.NOT. conv) q_mid = q_seed
        report%stage = 'tension-only (slack-capable) Newton, firm compression branch'
        CALL run_solve(q_mid, [CD_ONE], .TRUE., r_firm, cfg, q_try, conv)
        IF (ErrStat /= CD_STATIC_OK) RETURN
        IF (conv) THEN
          q_mid = q_try
          q_best = q_mid
          report%stage = 'tension-only Newton, exact law'
          CALL run_solve(q_mid, [CD_ONE], .TRUE., CD_ZERO, cfg, q_try, conv)
          IF (ErrStat /= CD_STATIC_OK) RETURN
          IF (conv) THEN
            CALL accept(q_try, .TRUE.)
            RETURN
          END IF
          ! the exact law may stall on a direction without stiffness; accept the firm stage
          ! when its exact tension-only residual is inside the admissibility band
          report%stage = 'tension-only admissibility check'
          CALL run_solve(q_mid, [CD_ONE], .TRUE., CD_ZERO, cfg_adm, q_try, conv)
          IF (ErrStat /= CD_STATIC_OK) RETURN
          IF (conv) THEN
            CALL accept(q_try, .TRUE.)
            RETURN
          END IF
        END IF
        CALL add_note(TRIM(seed_name)//': tension-only solve did not converge ('//TRIM(report%stage)//')')
      END IF

      ! --- last resort for this seed: compression-capable load continuation ---
      IF (.NOT. (tension_only .AND. iseed == 2)) THEN
        report%stage = 'compression-capable load continuation'
        CALL run_solve(q_seed, ramp, .FALSE., -CD_ONE, cfg, q_try, conv)
        IF (ErrStat /= CD_STATIC_OK) RETURN
        CALL judge_compression_capable(done)
        IF (done) RETURN
      END IF
    END DO

    q = q_best
    IF (LEN_TRIM(notes) == 0) notes = 'no seed could be constructed'
    report%message = 'no admissible static equilibrium: '//TRIM(notes)
    IF (tension_only) THEN
      CALL tension_range(q, t_min, t_max)
      report%min_tension = t_min
      ErrStat = CD_STATIC_OK
      ErrMsg = ''
    END IF

  CONTAINS

    SUBROUTINE judge_compression_capable(ok_done)
      !! Accept a converged compression-capable state (q_try) when the line may carry
      !! compression, or when no element is compressed beyond the admissibility band (it is
      !! then also the tension-only equilibrium); otherwise note why it was rejected.
      LOGICAL, INTENT(OUT) :: ok_done
      ok_done = .FALSE.
      IF (conv) THEN
        CALL tension_range(q_try, t_min, t_max)
        IF (.NOT. tension_only .OR. t_min >= -ADM_REL*MAX(t_max, f_node)) THEN
          CALL accept(q_try, .FALSE.)
          ok_done = .TRUE.
          RETURN
        END IF
        CALL add_note(TRIM(seed_name)//': '//TRIM(report%stage)//' found a compressed branch (min tension '// &
                      TRIM(real_str(t_min))//' N)')
      ELSE
        CALL add_note(TRIM(seed_name)//': '//TRIM(report%stage)//' did not converge')
      END IF
      IF (.NOT. tension_only) q_best = q_try
    END SUBROUTINE judge_compression_capable

    SUBROUTINE accept(qa, slack)
      !! Record the accepted equilibrium.
      REAL(wp), INTENT(IN) :: qa(:)
      LOGICAL, INTENT(IN) :: slack
      q = qa
      converged = .TRUE.
      report%slack_branch = slack
      CALL tension_range(q, t_min, t_max)
      report%min_tension = t_min
      report%message = 'converged ('//TRIM(report%stage)//', seed: '//TRIM(report%seed)//')'
    END SUBROUTINE accept

    SUBROUTINE add_note(txt)
      !! Append one seed note while the notes keep room for it and the omission marker;
      !! otherwise end them with the marker, so a note is never cut.
      CHARACTER(*), INTENT(IN) :: txt
      CHARACTER(*), PARAMETER :: OMITTED = '; further seed notes omitted'
      INTEGER :: n
      IF (notes_full) RETURN
      n = LEN_TRIM(notes)
      IF (n == 0) THEN
        IF (LEN_TRIM(txt) + LEN(OMITTED) <= LEN(notes)) THEN
          notes = TRIM(txt)
          RETURN
        END IF
        notes = OMITTED(3:)
      ELSE
        IF (n + 2 + LEN_TRIM(txt) + LEN(OMITTED) <= LEN(notes)) THEN
          notes = notes(1:n)//'; '//TRIM(txt)
          RETURN
        END IF
        notes = notes(1:n)//OMITTED
      END IF
      notes_full = .TRUE.
    END SUBROUTINE add_note

    SUBROUTINE run_solve(qs, factors, slack_law, ratio, cfg_use, qo, ok)
      !! One continuation solve from qs; slack_law selects the slack-capable law with ratio.
      REAL(wp), INTENT(IN) :: qs(:), factors(:)
      LOGICAL, INTENT(IN) :: slack_law
      REAL(wp), INTENT(IN) :: ratio
      TYPE(CableSolverConfig), INTENT(IN) :: cfg_use
      REAL(wp), INTENT(OUT) :: qo(:)
      LOGICAL, INTENT(OUT) :: ok
      INTEGER :: es_r
      CHARACTER(1024) :: em_r

      ok = .FALSE.
      IF (slack_law) THEN
        IF (has_seabed .AND. PRESENT(current)) THEN
          CALL CD_Static_Cable_Solve_Continuation(qs, elem_conn, l0, ea, .TRUE., f_ext, fixed, cfg_use, factors, &
                                                  qo, ok, stalled, at_floor, n_it, n_st, es_r, em_r, &
                                                  seabed_z_floor=seabed_z_floor, seabed_kn=seabed_kn, &
                                                  current=current, bathymetry=bathymetry, &
                                                  compression_ratio=ratio, lm_only=.TRUE.)
        ELSE IF (has_seabed) THEN
          CALL CD_Static_Cable_Solve_Continuation(qs, elem_conn, l0, ea, .TRUE., f_ext, fixed, cfg_use, factors, &
                                                  qo, ok, stalled, at_floor, n_it, n_st, es_r, em_r, &
                                                  seabed_z_floor=seabed_z_floor, seabed_kn=seabed_kn, &
                                                  bathymetry=bathymetry, compression_ratio=ratio, lm_only=.TRUE.)
        ELSE IF (PRESENT(current)) THEN
          CALL CD_Static_Cable_Solve_Continuation(qs, elem_conn, l0, ea, .TRUE., f_ext, fixed, cfg_use, factors, &
                                                  qo, ok, stalled, at_floor, n_it, n_st, es_r, em_r, &
                                                  current=current, compression_ratio=ratio, lm_only=.TRUE.)
        ELSE
          CALL CD_Static_Cable_Solve_Continuation(qs, elem_conn, l0, ea, .TRUE., f_ext, fixed, cfg_use, factors, &
                                                  qo, ok, stalled, at_floor, n_it, n_st, es_r, em_r, &
                                                  compression_ratio=ratio, lm_only=.TRUE.)
        END IF
      ELSE
        IF (has_seabed .AND. PRESENT(current)) THEN
          CALL CD_Static_Cable_Solve_Continuation(qs, elem_conn, l0, ea, .FALSE., f_ext, fixed, cfg_use, factors, &
                                                  qo, ok, stalled, at_floor, n_it, n_st, es_r, em_r, &
                                                  seabed_z_floor=seabed_z_floor, seabed_kn=seabed_kn, &
                                                  current=current, bathymetry=bathymetry, plain_only=tension_only)
        ELSE IF (has_seabed) THEN
          CALL CD_Static_Cable_Solve_Continuation(qs, elem_conn, l0, ea, .FALSE., f_ext, fixed, cfg_use, factors, &
                                                  qo, ok, stalled, at_floor, n_it, n_st, es_r, em_r, &
                                                  seabed_z_floor=seabed_z_floor, seabed_kn=seabed_kn, &
                                                  bathymetry=bathymetry, plain_only=tension_only)
        ELSE IF (PRESENT(current)) THEN
          CALL CD_Static_Cable_Solve_Continuation(qs, elem_conn, l0, ea, .FALSE., f_ext, fixed, cfg_use, factors, &
                                                  qo, ok, stalled, at_floor, n_it, n_st, es_r, em_r, current=current, &
                                                  plain_only=tension_only)
        ELSE
          CALL CD_Static_Cable_Solve_Continuation(qs, elem_conn, l0, ea, .FALSE., f_ext, fixed, cfg_use, factors, &
                                                  qo, ok, stalled, at_floor, n_it, n_st, es_r, em_r, &
                                                  plain_only=tension_only)
        END IF
      END IF
      report%n_iter = report%n_iter + n_it
      IF (es_r == CD_STATIC_BADINPUT) THEN
        ! invalid input is a caller error, not a solver outcome: fail closed at once
        ErrStat = CD_STATIC_BADINPUT
        ErrMsg = em_r
        ok = .FALSE.
        RETURN
      END IF
      IF (es_r /= CD_STATIC_OK) ok = .FALSE.     ! singular tangent: this attempt failed
      IF (ok) ok = CD_All_Finite(qo)
    END SUBROUTINE run_solve

    SUBROUTINE tension_range(qe, tmin, tmax)
      !! Smallest and largest compression-capable element tension of state qe.
      REAL(wp), INTENT(IN) :: qe(:)
      REAL(wp), INTENT(OUT) :: tmin, tmax
      INTEGER :: es_t
      CHARACTER(1024) :: em_t
      CALL CD_Compute_Cable_Tension(RESHAPE(qe, [3, n_nodes]), elem_conn, l0, ea, .FALSE., ten, es_t, em_t)
      IF (es_t /= 0) THEN
        tmin = -HUGE(CD_ONE)
        tmax = CD_ZERO
        RETURN
      END IF
      tmin = MINVAL(ten)
      tmax = MAXVAL(ten)
    END SUBROUTINE tension_range

    REAL(wp) FUNCTION seabed_floor_at(x, y, es_f, em_f) RESULT(zf)
      !! Seabed elevation under (x, y): the flat floor or the bathymetry surface.
      REAL(wp), INTENT(IN) :: x, y
      INTEGER, INTENT(OUT) :: es_f
      CHARACTER(*), INTENT(OUT) :: em_f
      REAL(wp) :: gx, gy
      es_f = 0
      em_f = ''
      zf = CD_ZERO
      IF (PRESENT(bathymetry)) THEN
        CALL CD_Bathymetry_Floor_Gradient(bathymetry, x, y, zf, gx, gy, es_f, em_f)
      ELSE IF (PRESENT(seabed_z_floor)) THEN
        zf = seabed_z_floor
      END IF
    END FUNCTION seabed_floor_at

    SUBROUTINE lift_onto_seabed(qs, es_l, em_l)
      !! Lift every free node that lies deeper below the seabed than its static penalty
      !! penetration (nodal weight / nodal contact stiffness) onto the seabed (a seed built
      !! on a plane that the actual seabed crosses, e.g. a sloped or bumpy bathymetry); a
      !! node within its penetration depth is left where the seed put it.
      REAL(wp), INTENT(INOUT) :: qs(:)
      INTEGER, INTENT(OUT) :: es_l
      CHARACTER(*), INTENT(OUT) :: em_l
      INTEGER :: i
      REAL(wp) :: zf
      es_l = 0
      em_l = ''
      DO i = 2, n_nodes - 1
        zf = seabed_floor_at(qs(3*i - 2), qs(3*i - 1), es_l, em_l)
        IF (es_l /= 0) RETURN
        IF (qs(3*i) < zf - MAX(-f_ext(3*i), CD_ZERO)/seabed_kn(i)) qs(3*i) = zf
      END DO
    END SUBROUTINE lift_onto_seabed

    SUBROUTINE build_seed(which, ok)
      !! Seed number `which` into q_seed (ok = .FALSE. when it cannot be built).
      INTEGER, INTENT(IN) :: which
      LOGICAL, INTENT(OUT) :: ok
      INTEGER :: es_s, i_s
      CHARACTER(1024) :: em_s
      LOGICAL :: hang
      REAL(wp) :: pen

      ok = .FALSE.
      SELECT CASE (which)
      CASE (1, 3)
        ! 1: grounded catenary when the anchor rests on the seabed, else fully suspended;
        ! 3: the other variant
        hang = .NOT. anchor_grounded
        IF (which == 3) hang = .NOT. hang
        IF (hang) THEN
          seed_name = 'suspended catenary'
        ELSE
          seed_name = 'grounded catenary'
        END IF
        IF (has_seabed .AND. .NOT. hang) THEN
          ! the seabed plane under the line: height at the anchor, gradient along the span
          CALL CD_Catenary_Seed(anchor, fairlead, l0, ea, weight, q_seed, h_cat, g_cat, es_s, em_s, &
                                suspended=.FALSE., seabed_z=floor_a, seabed_slope=slope_a)
        ELSE
          CALL CD_Catenary_Seed(anchor, fairlead, l0, ea, weight, q_seed, h_cat, g_cat, es_s, em_s, suspended=hang)
        END IF
        ok = es_s == CD_CAT_OK
        IF (ok) ok = CD_All_Finite(q_seed)
      CASE (2)
        ! a grounded line too long to lie in the vertical plane (the catenary H -> 0 limit):
        ! on a seabed that keeps falling past the fairlead the excess folds down the slope,
        ! otherwise it lies slack on the seabed between the anchor and the touchdown
        seed_name = 'slack grounded run'
        IF (.NOT. anchor_grounded) RETURN
        ok = .FALSE.
        IF (PRESENT(bathymetry)) THEN
          CALL fold_seed(ok)
          IF (ok) seed_name = 'folded grounded run'
        END IF
        IF (.NOT. ok) CALL slack_run_seed(anchor, fairlead, l0, floor_a, q_seed, ok)
        IF (ok) ok = CD_All_Finite(q_seed)
      CASE (6)
        ! a soft seabed: the grounded run sinks by its static penetration w/(kBot d), which a
        ! seed on the undeformed seabed plane cannot represent (a line that fits only thanks to
        ! the penetration looks longer than span + rise there)
        seed_name = 'catenary on the penetrated seabed'
        IF (.NOT. (anchor_grounded .AND. has_seabed)) RETURN
        pen = CD_ZERO
        DO i_s = 2, n_nodes - 1
          pen = MAX(pen, MAX(-f_ext(3*i_s), CD_ZERO)/seabed_kn(i_s))
        END DO
        IF (.NOT. (pen > CD_ZERO)) RETURN
        CALL CD_Catenary_Seed(anchor, fairlead, l0, ea, weight, q_seed, h_cat, g_cat, es_s, em_s, &
                              suspended=.FALSE., seabed_z=floor_a - pen, seabed_slope=slope_a)
        ok = es_s == CD_CAT_OK
        IF (ok) ok = CD_All_Finite(q_seed)
      CASE (5)
        ! a grounded run draped on the actual seabed (a slope or a gridded bathymetry the
        ! planar catenary seed cannot close), lifting off into a suspended catenary
        seed_name = 'seabed-draped catenary'
        IF (.NOT. (anchor_grounded .AND. PRESENT(bathymetry))) RETURN
        CALL drape_seed(ok)
        IF (ok) ok = CD_All_Finite(q_seed)
      CASE (7)
        ! the as-laid line with its top end moved to the fairlead: a grounded run at the
        ! friction reference positions lifting off into a suspended catenary. The reference
        ! is laid from the lower end of the line (CD_Static_As_Laid_Reference): node 1, or
        ! node n when it lies below node 1, whose seed is built on the reversed line
        seed_name = 'as-laid run'
        IF (.NOT. as_laid) RETURN
        IF (fairlead(3) < anchor(3)) THEN
          CALL laid_seed_from_last(ok)
        ELSE
          IF (.NOT. anchor_grounded) RETURN
          CALL CD_Static_As_Laid_Seed(anchor, fairlead, l0, ea, weight, current%friction_ref, q_seed, ok, &
                                      seabed_z_floor=seabed_z_floor, bathymetry=bathymetry)
        END IF
        IF (ok) ok = CD_All_Finite(q_seed)
      CASE DEFAULT
        seed_name = 'two-leg polyline'
        CALL polyline_seed(anchor, fairlead, l0, has_seabed, floor_a, q_seed)
        ok = CD_All_Finite(q_seed)
      END SELECT
    END SUBROUTINE build_seed

    SUBROUTINE laid_seed_from_last(ok)
      !! As-laid seed of a line laid from its last node (node n below node 1, the reference
      !! laid from node n): CD_Static_As_Laid_Seed on the reversed line (node n first, with
      !! the element and reference arrays reversed), its node order then reversed back into
      !! q_seed. ok = .FALSE. when node n does not rest on the seabed or the seed has no
      !! lift-off node.
      LOGICAL, INTENT(OUT) :: ok
      INTEGER :: es_r, i_r
      REAL(wp) :: floor_n
      REAL(wp), ALLOCATABLE :: q_rev(:)
      CHARACTER(1024) :: em_r
      ok = .FALSE.
      floor_n = seabed_floor_at(fairlead(1), fairlead(2), es_r, em_r)
      IF (es_r /= 0) RETURN
      IF (fairlead(3) > floor_n + CD_Static_Anchor_Seabed_Tolerance(floor_n)) RETURN
      ALLOCATE (q_rev(n_dof))
      CALL CD_Static_As_Laid_Seed(fairlead, anchor, l0(n_elem:1:-1), ea(n_elem:1:-1), weight(n_elem:1:-1), &
                                  current%friction_ref(:, n_nodes:1:-1), q_rev, ok, &
                                  seabed_z_floor=seabed_z_floor, bathymetry=bathymetry)
      IF (.NOT. ok) RETURN
      DO i_r = 1, n_nodes
        q_seed(3*i_r - 2:3*i_r) = q_rev(3*(n_nodes - i_r) + 1:3*(n_nodes - i_r) + 3)
      END DO
    END SUBROUTINE laid_seed_from_last

    SUBROUTINE drape_seed(ok)
      !! Seed for a grounded line on a non-planar or sloped seabed: nodes 1..k lie on the
      !! seabed along the horizontal anchor -> fairlead direction (each at the arc length of
      !! its unstretched position, measured along the local seabed slope), and nodes k..n
      !! form the fully suspended catenary from the lift-off node k to the fairlead. k is the
      !! first node at which the suspended span leaves the seabed at or above the local
      !! seabed angle (tangent lift-off), found by bisection on k. ok = .FALSE. when no node
      !! qualifies (a line too long for its span, handled by the slack-run seed).
      LOGICAL, INTENT(OUT) :: ok
      INTEGER :: k_lo, k_hi, k_mid, it
      REAL(wp) :: f_lo, f_hi, f_mid
      LOGICAL :: v_lo, v_hi, v_mid

      ok = .FALSE.
      k_lo = 1
      CALL drape_at(k_lo, f_lo, v_lo)
      IF (v_lo .AND. f_lo >= CD_ZERO) THEN
        ! the suspended span from the anchor already clears the seabed: no grounded run
        ok = .TRUE.
        RETURN
      END IF
      k_hi = n_nodes - 1
      CALL drape_at(k_hi, f_hi, v_hi)
      IF (.NOT. (v_hi .AND. f_hi >= CD_ZERO)) RETURN
      DO it = 1, 64
        IF (k_hi - k_lo <= 1) EXIT
        k_mid = (k_lo + k_hi)/2
        CALL drape_at(k_mid, f_mid, v_mid)
        IF (v_mid .AND. f_mid >= CD_ZERO) THEN
          k_hi = k_mid
        ELSE
          k_lo = k_mid
        END IF
      END DO
      CALL drape_at(k_hi, f_hi, v_hi)
      ok = v_hi
    END SUBROUTINE drape_seed

    SUBROUTINE drape_at(k, mismatch, valid)
      !! Build the drape seed with lift-off node k into q_seed; mismatch is the elevation
      !! angle of the first suspended element minus the seabed angle at the lift-off point
      !! along the span (>= 0: the span leaves the seabed upward, tangent or steeper).
      INTEGER, INTENT(IN) :: k
      REAL(wp), INTENT(OUT) :: mismatch
      LOGICAL, INTENT(OUT) :: valid
      INTEGER :: i, es_d, nsub, j
      REAL(wp) :: hd(2), hlen, arc, d, zf, g, p(3), step, arc_prev
      REAL(wp), ALLOCATABLE :: q_sus(:)
      REAL(wp) :: h_s, g_s, u(3)
      CHARACTER(1024) :: em_d

      valid = .FALSE.
      mismatch = -HUGE(CD_ONE)
      hd = fairlead(1:2) - anchor(1:2)
      hlen = NORM2(hd)
      IF (hlen <= CD_ZERO) RETURN
      hd = hd/hlen
      q_seed(1:3) = anchor
      p = anchor
      d = CD_ZERO
      arc_prev = CD_ZERO
      g = CD_ZERO
      DO i = 2, k
        ! advance the unstretched arc along the seabed in a few sub-steps of local slope
        arc = arc_prev + l0(i - 1)
        nsub = 4
        step = (arc - arc_prev)/REAL(nsub, wp)
        DO j = 1, nsub
          CALL seabed_slope_along(anchor(1) + d*hd(1), anchor(2) + d*hd(2), hd, g)
          d = d + step/SQRT(CD_ONE + g*g)
        END DO
        arc_prev = arc
        IF (d >= hlen) RETURN
        zf = seabed_floor_at(anchor(1) + d*hd(1), anchor(2) + d*hd(2), es_d, em_d)
        IF (es_d /= 0) RETURN
        q_seed(3*i - 2:3*i) = [anchor(1) + d*hd(1), anchor(2) + d*hd(2), zf]
      END DO
      p = q_seed(3*k - 2:3*k)
      IF (fairlead(3) <= p(3)) RETURN
      ALLOCATE (q_sus(3*(n_nodes - k + 1)))
      CALL CD_Catenary_Seed(p, fairlead, l0(k:), ea(k:), weight(k:), q_sus, h_s, g_s, es_d, em_d, &
                            suspended=.TRUE.)
      IF (es_d /= CD_CAT_OK) RETURN
      IF (.NOT. CD_All_Finite(q_sus)) RETURN
      q_seed(3*k - 2:) = q_sus
      CALL seabed_slope_along(p(1), p(2), hd, g)
      u = q_sus(4:6) - q_sus(1:3)
      IF (NORM2(u) <= CD_ZERO) RETURN
      mismatch = ATAN2(u(3), MAX(DOT_PRODUCT(u(1:2), hd), TINY(CD_ONE))) - ATAN(g)
      valid = .TRUE.
    END SUBROUTINE drape_at

    SUBROUTINE fold_seed(ok)
      !! H -> 0 seed on a seabed that falls away beyond the fairlead: the line hangs straight
      !! down from the fairlead to the seabed point P under it; the rest lies on the seabed
      !! from the anchor down the slope past P to a fold point F and back up to P (the two
      !! grounded legs share the excess length equally). On a frictionless slope this is the
      !! tension-only equilibrium shape: the tension falls to zero at the fold, where the
      !! grounded chain is held from both sides. ok = .FALSE. when the seabed does not fall
      !! beyond P or the line is not longer than the hang plus the seabed path to P.
      LOGICAL, INTENT(OUT) :: ok
      INTEGER, PARAMETER :: NTAB = 4000
      REAL(wp) :: hd(2), hlen, zp, c, arc_ap, g, e, a, dmax, total, s_node, pp(3), s_arc, d
      REAL(wp) :: dtab(0:NTAB), atab(0:NTAB)
      INTEGER :: i, j, es_f
      CHARACTER(1024) :: em_f

      ok = .FALSE.
      hd = fairlead(1:2) - anchor(1:2)
      hlen = NORM2(hd)
      IF (hlen <= CD_ZERO) RETURN
      hd = hd/hlen
      zp = seabed_floor_at(fairlead(1), fairlead(2), es_f, em_f)
      IF (es_f /= 0) RETURN
      c = fairlead(3) - zp
      total = SUM(l0)
      IF (c <= CD_ZERO .OR. c >= total) RETURN
      CALL seabed_slope_along(fairlead(1), fairlead(2), hd, g)
      IF (.NOT. (g < CD_ZERO)) RETURN
      ! arc-length table of the seabed profile along hd (horizontal distance -> arc)
      dmax = 2.0_wp*total + hlen
      dtab(0) = CD_ZERO
      atab(0) = CD_ZERO
      DO j = 1, NTAB
        dtab(j) = dmax*REAL(j, wp)/REAL(NTAB, wp)
        CALL seabed_slope_along(anchor(1) + 0.5_wp*(dtab(j - 1) + dtab(j))*hd(1), &
                                anchor(2) + 0.5_wp*(dtab(j - 1) + dtab(j))*hd(2), hd, g)
        atab(j) = atab(j - 1) + (dtab(j) - dtab(j - 1))*SQRT(CD_ONE + g*g)
      END DO
      ! seabed arc from the anchor to P (horizontal distance hlen)
      j = MIN(MAX(INT(hlen/dmax*REAL(NTAB, wp)), 0), NTAB - 1)
      arc_ap = atab(j) + (atab(j + 1) - atab(j))*(hlen - dtab(j))/(dtab(j + 1) - dtab(j))
      IF (total - c <= arc_ap) RETURN
      e = 0.5_wp*(total - c - arc_ap)
      a = arc_ap + e
      s_node = CD_ZERO
      q_seed(1:3) = anchor
      DO i = 2, n_nodes
        s_node = s_node + l0(i - 1)
        IF (s_node <= a + e) THEN
          ! on the seabed: down the slope to the fold at arc a, then back up
          s_arc = s_node
          IF (s_node > a) s_arc = a - (s_node - a)
          j = 0
          DO WHILE (j < NTAB - 1 .AND. atab(j + 1) < s_arc)
            j = j + 1
          END DO
          d = dtab(j) + (dtab(j + 1) - dtab(j))*(s_arc - atab(j))/MAX(atab(j + 1) - atab(j), TINY(CD_ONE))
          pp(1:2) = anchor(1:2) + d*hd
          pp(3) = seabed_floor_at(pp(1), pp(2), es_f, em_f)
          IF (es_f /= 0) RETURN
        ELSE
          pp = [fairlead(1), fairlead(2), zp]
          pp = pp + MIN((s_node - a - e)/c, CD_ONE)*(fairlead - pp)
        END IF
        q_seed(3*i - 2:3*i) = pp
      END DO
      q_seed(3*n_nodes - 2:3*n_nodes) = fairlead
      ok = .TRUE.
    END SUBROUTINE fold_seed

    SUBROUTINE seabed_slope_along(x, y, hd, g)
      !! Seabed gradient dz/ds along the horizontal unit direction hd at (x, y) (0 for a flat
      !! floor).
      REAL(wp), INTENT(IN) :: x, y, hd(2)
      REAL(wp), INTENT(OUT) :: g
      REAL(wp) :: zf, gx, gy
      INTEGER :: es_g
      CHARACTER(1024) :: em_g
      g = CD_ZERO
      IF (.NOT. PRESENT(bathymetry)) RETURN
      CALL CD_Bathymetry_Floor_Gradient(bathymetry, x, y, zf, gx, gy, es_g, em_g)
      IF (es_g == CD_BATHY_OK) g = gx*hd(1) + gy*hd(2)
    END SUBROUTINE seabed_slope_along

  END SUBROUTINE line_equilibrium

  SUBROUTINE polyline_seed(anchor, fairlead, l0, has_seabed, z_floor, q)
    !! Positions-only seed that never compresses a line longer than its chord: the nodes are
    !! spread (by unstretched arc length) along a two-leg path anchor -> C -> fairlead whose
    !! length equals the line length. With a seabed, C lies on the seabed level z_floor,
    !! displaced from the anchor along the horizontal anchor->fairlead direction (past the
    !! fairlead when the line is longer than span + rise, so the excess lies on the seabed as
    !! a closed triangle); otherwise C hangs below the chord midpoint (a V). A line not
    !! longer than its chord is the straight, uniformly stretched chord.
    REAL(wp), INTENT(IN) :: anchor(3), fairlead(3), l0(:), z_floor
    LOGICAL, INTENT(IN) :: has_seabed
    REAL(wp), INTENT(OUT) :: q(:)
    INTEGER :: n_nodes, i, it
    REAL(wp) :: total, chord, hd(2), hspan, c(3), lo, hi, mid, s, leg1, frac, zc
    REAL(wp) :: arc, u(3)

    n_nodes = SIZE(l0) + 1
    total = SUM(l0)
    chord = NORM2(fairlead - anchor)
    hd = fairlead(1:2) - anchor(1:2)
    hspan = NORM2(hd)
    IF (hspan > 1.0e-9_wp*MAX(CD_ONE, chord)) THEN
      hd = hd/hspan
    ELSE
      hd = [CD_ONE, CD_ZERO]
    END IF
    ! downward unit normal to the chord in the vertical plane of hd (hd itself for a
    ! vertical chord, so the V opens sideways instead of folding onto the chord)
    u = [CD_ZERO, CD_ZERO, -CD_ONE]
    IF (chord > CD_ZERO) u = u - DOT_PRODUCT(u, fairlead - anchor)/chord**2*(fairlead - anchor)
    IF (NORM2(u) > 1.0e-6_wp) THEN
      u = u/NORM2(u)
    ELSE
      u = [hd(1), hd(2), CD_ZERO]
    END IF
    c = 0.5_wp*(anchor + fairlead)
    IF (total > chord*(CD_ONE + 1.0e-12_wp)) THEN
      ! V apex at distance d from the chord midpoint: legs of length sqrt((chord/2)^2 + d^2)
      c = c + SQRT(MAX((0.5_wp*total)**2 - (0.5_wp*chord)**2, CD_ZERO))*u
      zc = MIN(anchor(3), fairlead(3))
      IF (has_seabed) zc = MIN(zc, z_floor)
      IF (has_seabed .AND. c(3) < zc) THEN
        ! the V would cut the seabed: put the apex on the seabed level and slide it along hd
        ! from under the V apex until the two legs have the line length
        lo = DOT_PRODUCT(c(1:2) - anchor(1:2), hd)
        hi = MAX(ABS(lo), CD_ZERO) + 2.0_wp*total + CD_ONE
        DO it = 1, 200
          mid = 0.5_wp*(lo + hi)
          IF (path_len_s(mid) < total) THEN
            lo = mid
          ELSE
            hi = mid
          END IF
        END DO
        s = 0.5_wp*(lo + hi)
        c = [anchor(1) + s*hd(1), anchor(2) + s*hd(2), zc]
      END IF
    END IF
    leg1 = NORM2(c - anchor)
    q(1:3) = anchor
    arc = CD_ZERO
    DO i = 2, n_nodes
      arc = arc + l0(i - 1)
      frac = arc/total
      s = frac*(leg1 + NORM2(fairlead - c))
      IF (s <= leg1 .AND. leg1 > CD_ZERO) THEN
        q(3*i - 2:3*i) = anchor + (s/leg1)*(c - anchor)
      ELSE
        q(3*i - 2:3*i) = c + ((s - leg1)/MAX(NORM2(fairlead - c), TINY(CD_ONE)))*(fairlead - c)
      END IF
    END DO
    q(3*n_nodes - 2:3*n_nodes) = fairlead

  CONTAINS

    REAL(wp) FUNCTION path_len_s(sv) RESULT(p)
      !! Length of the two legs through the seabed-level apex at horizontal offset sv.
      REAL(wp), INTENT(IN) :: sv
      REAL(wp) :: cv(3)
      cv = [anchor(1) + sv*hd(1), anchor(2) + sv*hd(2), zc]
      p = NORM2(cv - anchor) + NORM2(fairlead - cv)
    END FUNCTION path_len_s
  END SUBROUTINE polyline_seed

  SUBROUTINE slack_run_seed(anchor, fairlead, l0, z_floor, q, ok)
    !! Seed of the H -> 0 limit of a grounded line longer than span + rise: the line hangs
    !! straight down from the fairlead to a touchdown point P on the seabed level z_floor
    !! (under the fairlead, or a short step from a vertically-above anchor), and the rest of
    !! its length lies slack (uniformly shortened) along the seabed between the anchor and P.
    !! This is the tension-only equilibrium shape up to the stretch of the hanging leg. ok is
    !! .FALSE. when the line is too short for a slack run (the catenary seed applies then).
    REAL(wp), INTENT(IN) :: anchor(3), fairlead(3), l0(:), z_floor
    REAL(wp), INTENT(OUT) :: q(:)
    LOGICAL, INTENT(OUT) :: ok
    INTEGER :: n_nodes, i
    REAL(wp) :: total, hd(2), hspan, rise, p(3), leg_hang, leg_bed, run, arc

    ok = .FALSE.
    q = CD_ZERO
    n_nodes = SIZE(l0) + 1
    total = SUM(l0)
    hd = fairlead(1:2) - anchor(1:2)
    hspan = NORM2(hd)
    rise = fairlead(3) - z_floor
    IF (rise <= CD_ZERO .OR. total <= rise) RETURN
    IF (hspan > 1.0e-3_wp*rise) THEN
      p = [fairlead(1), fairlead(2), z_floor]
    ELSE
      ! vertical span: step the touchdown sideways so the grounded run has a length
      p = [anchor(1) + 0.25_wp*(total - rise), anchor(2), z_floor]
    END IF
    leg_hang = NORM2(fairlead - p)
    leg_bed = NORM2(p - [anchor(1), anchor(2), z_floor])
    run = total - leg_hang            ! unstretched length that lies on the seabed
    IF (run <= leg_bed .OR. leg_bed <= CD_ZERO) RETURN
    q(1:3) = anchor
    arc = CD_ZERO
    DO i = 2, n_nodes
      arc = arc + l0(i - 1)
      IF (arc <= run) THEN
        q(3*i - 2:3*i) = anchor + (arc/run)*(p - anchor)
      ELSE
        q(3*i - 2:3*i) = p + ((arc - run)/leg_hang)*(fairlead - p)
      END IF
    END DO
    q(3*n_nodes - 2:3*n_nodes) = fairlead
    ok = .TRUE.
  END SUBROUTINE slack_run_seed

  SUBROUTINE CD_Static_Line_End_Forces(q, elem_conn, l0, ea, f_ext, tension_only, force_a, force_b, &
                                       ErrStat, ErrMsg, seabed_z_floor, seabed_kn, bathymetry, current)
    !! Force the line exerts on each held end point at state q: the end element's axial
    !! tension along the line plus the end node's lumped external loads (its share of the
    !! submerged weight, seabed contact and steady-current drag). This is the end-point
    !! reaction of the lumped discretisation -- MoorDyn's line-end force and OrcaFlex's end
    !! force -- and equals minus the static residual at the held node. force_a belongs to
    !! node 1 (the anchor), force_b to node n (the fairlead); their norms are AnchTen/FairTen.
    REAL(wp), INTENT(IN) :: q(:)
    INTEGER, INTENT(IN) :: elem_conn(:, :)
    REAL(wp), INTENT(IN) :: l0(:), ea(:), f_ext(:)
    LOGICAL, INTENT(IN) :: tension_only
    REAL(wp), INTENT(OUT) :: force_a(3), force_b(3)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    REAL(wp), INTENT(IN), OPTIONAL :: seabed_z_floor
    REAL(wp), INTENT(IN), OPTIONAL :: seabed_kn(:)
    TYPE(CD_BathymetryType), INTENT(IN), OPTIONAL :: bathymetry
    TYPE(CableCurrentLoad), INTENT(IN), OPTIONAL :: current

    INTEGER :: n_dof, n_nodes, n_elem, k, e, a, b, node, es
    REAL(wp), ALLOCATABLE :: fint(:)
    REAL(wp) :: zf, gx, gy, fvec(3), jac(3, 3), curv(3), f2(6), jq2(6, 6), jv2(6, 6), va(3), vb(3), de, cn, ct, wla, wlb
    CHARACTER(1024) :: em
    INTEGER :: ends(2)
    LOGICAL :: drag_ends

    ErrStat = CD_STATIC_OK
    ErrMsg = ''
    force_a = CD_ZERO
    force_b = CD_ZERO
    n_dof = SIZE(q)
    n_nodes = n_dof/3
    n_elem = SIZE(l0)
    IF (MOD(n_dof, 3) /= 0 .OR. n_nodes /= n_elem + 1 .OR. SIZE(f_ext) /= n_dof) THEN
      CALL fail(ErrStat, ErrMsg, 'end forces: inconsistent state/mesh shapes')
      RETURN
    END IF
    IF (PRESENT(seabed_kn)) THEN
      IF (SIZE(seabed_kn) /= n_nodes) THEN
        CALL fail(ErrStat, ErrMsg, 'end forces: seabed_kn must have one entry per node')
        RETURN
      END IF
    END IF
    ALLOCATE (fint(n_dof))
    CALL CD_Assemble_Cable_Internal_Force(RESHAPE(q, [3, n_nodes]), elem_conn, l0, ea, tension_only, fint, es, em)
    IF (es /= 0) THEN
      CALL fail(ErrStat, ErrMsg, 'end forces: '//TRIM(em))
      RETURN
    END IF
    ! line on point = -(internal force) + lumped external load, node by node
    fint = f_ext - fint
    ends = [1, n_nodes]
    IF (PRESENT(seabed_kn) .AND. (PRESENT(seabed_z_floor) .OR. PRESENT(bathymetry))) THEN
      DO k = 1, 2
        node = ends(k)
        curv = CD_ZERO
        IF (PRESENT(bathymetry)) THEN
          CALL CD_Bathymetry_Floor_Gradient(bathymetry, q(3*node - 2), q(3*node - 1), zf, gx, gy, es, em, &
                                            crease_curvature=curv)
          IF (es /= CD_BATHY_OK) THEN
            CALL fail(ErrStat, ErrMsg, 'end forces: '//TRIM(em))
            RETURN
          END IF
        ELSE
          zf = seabed_z_floor
          gx = CD_ZERO
          gy = CD_ZERO
        END IF
        CALL CD_Seabed_Normal_Contact(zf - q(3*node), gx, gy, seabed_kn(node), fvec, jac, curvature=curv)
        fint(3*node - 2:3*node) = fint(3*node - 2:3*node) + fvec
      END DO
    END IF
    drag_ends = PRESENT(current)
    IF (drag_ends) drag_ends = current%drag
    IF (drag_ends) THEN
      DO e = 1, n_elem
        a = elem_conn(1, e)
        b = elem_conn(2, e)
        IF (.NOT. (ANY(ends == a) .OR. ANY(ends == b))) CYCLE
        IF (ALLOCATED(current%grid)) THEN
          CALL CD_Current_Grid_Velocity(current%grid, q(3*a - 2:3*a), CD_ZERO, va, es, em)
          IF (es == CD_HYDRO_OK) CALL CD_Current_Grid_Velocity(current%grid, q(3*b - 2:3*b), CD_ZERO, vb, es, em)
          IF (es /= CD_HYDRO_OK) THEN
            CALL fail(ErrStat, ErrMsg, 'end forces: '//TRIM(em))
            RETURN
          END IF
        ELSE IF (ALLOCATED(current%profile_z) .AND. ALLOCATED(current%profile_velocity)) THEN
          CALL CD_Current_Profile_Velocity(q(3*a), current%profile_z, current%profile_velocity, va, es, em)
          IF (es == CD_HYDRO_OK) CALL CD_Current_Profile_Velocity(q(3*b), current%profile_z, &
                                                                  current%profile_velocity, vb, es, em)
          IF (es /= CD_HYDRO_OK) THEN
            CALL fail(ErrStat, ErrMsg, 'end forces: '//TRIM(em))
            RETURN
          END IF
        ELSE IF (ALLOCATED(current%node_velocity)) THEN
          va = current%node_velocity(:, a)
          vb = current%node_velocity(:, b)
        ELSE
          va = current%velocity
          vb = current%velocity
        END IF
        IF (ALLOCATED(current%elem_diameter)) THEN
          de = current%elem_diameter(e)
          cn = current%elem_cdn(e)
          ct = current%elem_cdt(e)
        ELSE
          de = current%diameter
          cn = current%cdn
          ct = current%cdt
        END IF
        wla = current%waterline_z
        wlb = current%waterline_z
        IF (ALLOCATED(current%node_waterline)) THEN
          wla = current%node_waterline(a)
          wlb = current%node_waterline(b)
        END IF
        CALL CD_Morison_Drag_Element_Load(q(3*a - 2:3*a), q(3*b - 2:3*b), [CD_ZERO, CD_ZERO, CD_ZERO], &
                                          [CD_ZERO, CD_ZERO, CD_ZERO], l0(e), va, vb, &
                                          wla, wlb, current%rho, de, cn, ct, f2, jq2, jv2, es, em)
        IF (es /= CD_HYDRO_OK) THEN
          CALL fail(ErrStat, ErrMsg, 'end forces: '//TRIM(em))
          RETURN
        END IF
        IF (ANY(ends == a)) fint(3*a - 2:3*a) = fint(3*a - 2:3*a) + f2(1:3)
        IF (ANY(ends == b)) fint(3*b - 2:3*b) = fint(3*b - 2:3*b) + f2(4:6)
      END DO
    END IF
    force_a = fint(1:3)
    force_b = fint(3*n_nodes - 2:3*n_nodes)
  END SUBROUTINE CD_Static_Line_End_Forces

  ! --------------------------------------------------------------------------- !
  ! private helpers                                                             !
  ! --------------------------------------------------------------------------- !

  REAL(wp) FUNCTION nodal_load_max(f) RESULT(m)
    !! Largest nodal load magnitude of a flat (3 n_nodes) load vector.
    REAL(wp), INTENT(IN) :: f(:)
    INTEGER :: i
    m = CD_ZERO
    DO i = 1, SIZE(f)/3
      m = MAX(m, NORM2(f(3*i - 2:3*i)))
    END DO
  END FUNCTION nodal_load_max

  FUNCTION real_str(x) RESULT(s)
    !! Compact scientific rendering of a real for messages.
    REAL(wp), INTENT(IN) :: x
    CHARACTER(24) :: s
    WRITE (s, '(ES12.4)') x
    s = ADJUSTL(s)
  END FUNCTION real_str

  PURE FUNCTION reshape3(q, n_dof) RESULT(nodes)
    !! Copy the flat positions-only state into a (3, n_nodes) node array.
    INTEGER, INTENT(IN) :: n_dof
    REAL(wp), INTENT(IN) :: q(n_dof)
    REAL(wp) :: nodes(3, n_dof/3)
    nodes = RESHAPE(q, [3, n_dof/3])
  END FUNCTION reshape3

  LOGICAL FUNCTION pos_finite(x) RESULT(ok)
    !! True iff x is a finite, strictly-positive real (config-tolerance guard).
    REAL(wp), INTENT(IN) :: x
    ok = CD_Is_Finite(x) .AND. x > CD_ZERO
  END FUNCTION pos_finite

  LOGICAL FUNCTION is_converged(rnorm, scale, cfg) RESULT(ok)
    REAL(wp), INTENT(IN) :: rnorm, scale
    TYPE(CableSolverConfig), INTENT(IN) :: cfg
    ok = (rnorm/scale < cfg%rel_tol) .OR. (rnorm < cfg%abs_tol)
  END FUNCTION is_converged

  REAL(wp) FUNCTION infnorm(x) RESULT(r)
    REAL(wp), INTENT(IN) :: x(:)
    IF (SIZE(x) == 0) THEN
      r = CD_ZERO
    ELSE
      r = MAXVAL(ABS(x))
    END IF
  END FUNCTION infnorm

  SUBROUTINE fail(ErrStat, ErrMsg, msg)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    CHARACTER(*), INTENT(IN)  :: msg
    ErrStat = CD_STATIC_BADINPUT
    ErrMsg = 'CableDyn_Static: '//msg
  END SUBROUTINE fail

END MODULE CableDyn_Static
