! File: src/CableDyn_FiniteEIStatic.f90
! SPDX-License-Identifier: Apache-2.0
! Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
MODULE CableDyn_FiniteEIStatic
  !! Finite-EI (geometrically-exact Cosserat) static equilibrium for a grounded,
  !! touching-down line -- the stiff power-cable regime an EI=0 cable cannot
  !! represent: a catenary-seeded finite-EI line solve composed with a
  !! non-dimensional static Newton solve. Used by the validation tests of the secondary
  !! Cosserat path; the production finite-EI statics are CableDyn_HermiteCableStatic.
  !!
  !! The pipeline:
  !!   1. Independent analytic grounded-catenary seed (positions in, here) ->
  !!      a 6-DOF/node state: catenary positions + tangent-aligned cross-section
  !!      rotations (shortest-arc rotvec from a horizontal reference tangent to the
  !!      local catenary tangent), on a straight reference rod along that reference
  !!      tangent (CD_FiniteEI_Touchdown_Seed).
  !!   2. Submerged-weight gravity, lumped to nodes (consistent linear-shape z force).
  !!   3. Non-dimensionalise by the line length L and axial stiffness F = max(EA):
  !!      r~ = r/L, EA~ = EA/F, EI~ = EI/(F L^2), GJ~ = GJ/(F L^2), f~ = f/F,
  !!      moments~ = m/(F L), seabed k_n~ = k_n L/F, z_floor~ = z_floor/L. The solve
  !!      runs entirely in the well-scaled variables (convergence governed by the
  !!      dimensionless bending parameter EI/(EA L_e^2) >~ 1e-5 -> a fine mesh).
  !!   4. Dense Newton/Armijo with a configuration-dependent penalty seabed, the step
  !!      taken in additive rotation coordinates and applied with the dexp-corrected
  !!      multiplicative SO(3) update (matching CableDyn_CosseratStatic).
  !!   5. Load continuation: ramp the weight 0 -> 1 (seabed full strength each stage),
  !!      warm-starting every stage, then scale positions back to dimensional.
  !!
  !! Conventions: q is the flat (6 n_nodes) state [r(3), theta(3)] per node; node nd
  !! owns DOFs 6*nd-5:6*nd. The line is a single open chain, node 1 = End A (anchor),
  !! node n = End B (fairlead); both endpoint TRANSLATIONS are pinned, rotations free.
  USE CableDyn_Precision, ONLY: wp, CD_ZERO, CD_ONE, CD_All_Finite, CD_Is_Finite
  USE CableDyn_CosseratAssemble, ONLY: CD_Assemble_Cosserat_Tangent_Force, &
                                       CD_Assemble_Cosserat_Internal_Force
  USE CableDyn_Cosserat, ONLY: CD_Reference_Frame, CD_Cosserat_Strains
  USE CableDyn_SO3, ONLY: CD_Dexp_SO3, CD_Compose_Rotvec
  USE CableDyn_Linalg, ONLY: CD_Solve_Dense_As_Banded
  USE CableDyn_Mesh, ONLY: CD_Partition_Free_Dofs
  USE CableDyn_CosseratStatic, ONLY: CosseratSolverConfig
  IMPLICIT NONE
  PRIVATE

  PUBLIC :: CD_FiniteEI_Touchdown_Seed
  PUBLIC :: CD_Solve_FiniteEI_Touchdown
  PUBLIC :: CD_FiniteEI_Centerline_Curvature
  PUBLIC :: CD_FiniteEI_Element_Bend_Moment
  INTEGER, PARAMETER, PUBLIC :: CD_FEI_OK = 0, CD_FEI_BADINPUT = 1, CD_FEI_SINGULAR = 2

  ! |theta| < pi - CHART_MARGIN keeps the seed rotation inside the rotation-vector chart.
  REAL(wp), PARAMETER :: CHART_MARGIN = 1.0e-6_wp
  REAL(wp), PARAMETER :: PI = 3.14159265358979323846_wp

CONTAINS

  SUBROUTINE CD_FiniteEI_Touchdown_Seed(cat_positions, anchor, fairlead, l0, q0, nodes_ref, &
                                        ErrStat, ErrMsg)
    !! Build the 6-DOF Cosserat seed from an analytic grounded-catenary position field.
    !!
    !! The straight reference rod runs along the horizontal reference tangent
    !! (fairlead - anchor projected to the x-y plane, normalised), arc-length spaced by
    !! l0; each node's seed rotation is the shortest-arc rotvec from that reference
    !! tangent to the local catenary tangent (nodal average of adjacent segment
    !! directions): a grounded-catenary initial guess with tangent-aligned
    !! rotations.
    REAL(wp), INTENT(IN)  :: cat_positions(:, :)   !! (3, n_nodes) catenary node positions
    REAL(wp), INTENT(IN)  :: anchor(3), fairlead(3)
    REAL(wp), INTENT(IN)  :: l0(:)                 !! (n_elem) unstretched element lengths
    REAL(wp), INTENT(OUT) :: q0(:)                 !! (6 n_nodes) seed state
    REAL(wp), INTENT(OUT) :: nodes_ref(:, :)       !! (3, n_nodes) straight reference rod
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg

    INTEGER :: n_nodes, n_elem, nd, e, base
    REAL(wp) :: ref_tan(3), hnorm, s, rotvec(3)
    REAL(wp), ALLOCATABLE :: et(:, :), tang(:, :)

    ErrStat = CD_FEI_OK
    ErrMsg = ''
    q0 = CD_ZERO
    nodes_ref = CD_ZERO
    n_nodes = SIZE(cat_positions, 2)
    n_elem = SIZE(l0)

    IF (SIZE(cat_positions, 1) /= 3 .OR. n_nodes < 2 .OR. n_elem /= n_nodes - 1) THEN
      CALL fail('cat_positions must be (3, n_nodes) with l0 of length n_nodes-1'); RETURN
    END IF
    IF (SIZE(q0) /= 6*n_nodes .OR. SIZE(nodes_ref, 1) /= 3 .OR. SIZE(nodes_ref, 2) /= n_nodes) THEN
      CALL fail('q0 must be (6 n_nodes) and nodes_ref (3, n_nodes)'); RETURN
    END IF
    IF (.NOT. CD_All_Finite(cat_positions) .OR. .NOT. CD_All_Finite(l0) &
        .OR. .NOT. CD_All_Finite(anchor) .OR. .NOT. CD_All_Finite(fairlead)) THEN
      CALL fail('cat_positions, l0, anchor, fairlead must be finite'); RETURN
    END IF
    IF (ANY(l0 <= CD_ZERO)) THEN
      CALL fail('l0 must be strictly positive'); RETURN
    END IF

    ! Horizontal reference tangent (the chord direction projected onto the x-y plane).
    ref_tan = [fairlead(1) - anchor(1), fairlead(2) - anchor(2), CD_ZERO]
    hnorm = SQRT(ref_tan(1)**2 + ref_tan(2)**2)
    IF (hnorm <= 1.0e-12_wp) THEN
      CALL fail('anchor and fairlead share a horizontal position; no reference tangent'); RETURN
    END IF
    ref_tan = ref_tan/hnorm

    ! Straight reference rod along ref_tan, arc-length spaced by l0 (node 1 at origin).
    s = CD_ZERO
    nodes_ref(:, 1) = CD_ZERO
    DO nd = 2, n_nodes
      s = s + l0(nd - 1)
      nodes_ref(:, nd) = s*ref_tan
    END DO

    ! Nodal tangents from adjacent analytical segments.
    ALLOCATE (et(3, n_elem), tang(3, n_nodes))
    DO e = 1, n_elem
      et(:, e) = cat_positions(:, e + 1) - cat_positions(:, e)
      CALL normalize(et(:, e), ErrStat, ErrMsg)
      IF (ErrStat /= 0) THEN
        ErrMsg = 'CD_FiniteEI_Touchdown_Seed: zero-length analytical segment'; RETURN
      END IF
    END DO
    tang(:, 1) = et(:, 1)
    tang(:, n_nodes) = et(:, n_elem)
    DO nd = 2, n_nodes - 1
      tang(:, nd) = et(:, nd - 1) + et(:, nd)
      CALL normalize(tang(:, nd), ErrStat, ErrMsg)
      IF (ErrStat /= 0) THEN
        ErrMsg = 'CD_FiniteEI_Touchdown_Seed: degenerate interior tangent'; RETURN
      END IF
    END DO

    DO nd = 1, n_nodes
      base = 6*(nd - 1)
      CALL shortest_arc_rotvec(ref_tan, tang(:, nd), rotvec, ErrStat, ErrMsg)
      IF (ErrStat /= 0) RETURN
      q0(base + 1:base + 3) = cat_positions(:, nd)
      q0(base + 4:base + 6) = rotvec
    END DO

  CONTAINS

    SUBROUTINE fail(msg)
      CHARACTER(*), INTENT(IN) :: msg
      ErrStat = CD_FEI_BADINPUT
      ErrMsg = 'CD_FiniteEI_Touchdown_Seed: '//msg
    END SUBROUTINE fail

  END SUBROUTINE CD_FiniteEI_Touchdown_Seed

  SUBROUTINE CD_Solve_FiniteEI_Touchdown(anchor, fairlead, cat_positions, l0, ea, ei, gj, w, &
                                         z_floor, seabed_kn, cfg, load_factors, q, nodes_ref, &
                                         tension, converged, stalled, n_stages_done, ErrStat, ErrMsg)
    !! Solve a uniform finite-EI line to grounded static equilibrium (non-dim + load
    !! continuation + penalty seabed) on the Cosserat element. Returns the dimensional
    !! state q (6 n_nodes), the straight reference rod nodes_ref, and per-element axial
    !! (effective, dry) tension EA*(chord/ref - 1) with tension(1) = anchor end,
    !! tension(n_elem) = fairlead end.
    REAL(wp), INTENT(IN)  :: anchor(3), fairlead(3)
    REAL(wp), INTENT(IN)  :: cat_positions(:, :)   !! (3, n_nodes) analytic catenary seed
    REAL(wp), INTENT(IN)  :: l0(:), ea(:), ei(:), gj(:), w(:)  !! (n_elem) props + submerged weight
    REAL(wp), INTENT(IN)  :: z_floor               !! seabed plane elevation [m]
    REAL(wp), INTENT(IN)  :: seabed_kn             !! scalar penalty stiffness [N/m] (tributary)
    TYPE(CosseratSolverConfig), INTENT(IN) :: cfg
    REAL(wp), INTENT(IN)  :: load_factors(:)       !! strictly increasing ramp in (0, 1], ending at 1
    REAL(wp), INTENT(OUT) :: q(:)                  !! (6 n_nodes) dimensional solution
    REAL(wp), INTENT(OUT) :: nodes_ref(:, :)       !! (3, n_nodes) reference rod
    REAL(wp), INTENT(OUT) :: tension(:)            !! (n_elem) axial tension
    LOGICAL, INTENT(OUT) :: converged, stalled
    INTEGER, INTENT(OUT) :: n_stages_done, ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg

    INTEGER :: n_elem, n_nodes, n_dof, nd, e, base, i, j, ns, s_idx, axis
    INTEGER, ALLOCATABLE :: elem_conn(:, :), fixed(:)
    REAL(wp), ALLOCATABLE :: gas(:), q0(:), f_ext(:)
    REAL(wp), ALLOCATABLE :: nodes_ref_nd(:, :), ea_nd(:), gas_nd(:), ei_nd(:), gj_nd(:)
    REAL(wp), ALLOCATABLE :: q0_nd(:), f_ext_nd(:), q_nd(:), q_stage(:)
    REAL(wp) :: lscale, fscale, ls2, kn_nd, zfloor_nd, chord, refl
    LOGICAL :: stage_conv, stage_stall

    ErrStat = CD_FEI_OK
    ErrMsg = ''
    converged = .FALSE.; stalled = .FALSE.; n_stages_done = 0
    n_elem = SIZE(l0)
    n_nodes = n_elem + 1
    n_dof = 6*n_nodes
    q = CD_ZERO; nodes_ref = CD_ZERO; tension = CD_ZERO

    ! --- input validation (fail closed) ---
    IF (n_elem < 1 .OR. SIZE(ea) /= n_elem .OR. SIZE(ei) /= n_elem .OR. SIZE(gj) /= n_elem &
        .OR. SIZE(w) /= n_elem .OR. SIZE(cat_positions, 1) /= 3 .OR. SIZE(cat_positions, 2) /= n_nodes) THEN
      CALL fail('inconsistent element/property/seed shapes'); RETURN
    END IF
    IF (SIZE(q) /= n_dof .OR. SIZE(nodes_ref, 1) /= 3 .OR. SIZE(nodes_ref, 2) /= n_nodes &
        .OR. SIZE(tension) /= n_elem) THEN
      CALL fail('q/nodes_ref/tension shapes inconsistent with the mesh'); RETURN
    END IF
    IF (.NOT. CD_All_Finite(l0) .OR. ANY(l0 <= CD_ZERO) &
        .OR. .NOT. CD_All_Finite(ea) .OR. ANY(ea <= CD_ZERO) &
        .OR. .NOT. CD_All_Finite(ei) .OR. ANY(ei <= CD_ZERO) &
        .OR. .NOT. CD_All_Finite(gj) .OR. ANY(gj <= CD_ZERO)) THEN
      CALL fail('l0, ea, ei, gj must be finite and strictly positive'); RETURN
    END IF
    IF (.NOT. CD_All_Finite(w)) THEN
      CALL fail('submerged weight w must be finite'); RETURN
    END IF
    IF (ANY(w <= CD_ZERO)) THEN
      ! A net-buoyant section is the lazy-wave arch regime -- the linear-Lagrange element
      ! needs a dedicated buoyancy continuation; fail closed rather than stall.
      CALL fail('net-buoyant section (w <= 0) is not supported on the finite-EI touchdown path'); RETURN
    END IF
    IF (.NOT. CD_Is_Finite(z_floor)) THEN
      CALL fail('z_floor must be finite'); RETURN
    END IF
    IF (.NOT. CD_Is_Finite(seabed_kn) .OR. seabed_kn <= CD_ZERO) THEN
      CALL fail('seabed_kn must be finite and positive'); RETURN
    END IF
    ns = SIZE(load_factors)
    ! Nested tests: Fortran does not short-circuit .OR., so an empty array must be
    ! rejected before load_factors(1) or load_factors(ns) is referenced.
    IF (ns < 1) THEN
      CALL fail('load_factors must be finite, strictly positive, and end at 1'); RETURN
    END IF
    IF (.NOT. CD_All_Finite(load_factors) .OR. load_factors(1) <= CD_ZERO &
        .OR. ABS(load_factors(ns) - CD_ONE) > 1.0e-12_wp) THEN
      CALL fail('load_factors must be finite, strictly positive, and end at 1'); RETURN
    END IF
    DO s_idx = 2, ns
      IF (load_factors(s_idx) <= load_factors(s_idx - 1)) THEN
        CALL fail('load_factors must be strictly increasing'); RETURN
      END IF
    END DO

    ! --- mesh + seed + weight (GAs = EA Kirchhoff shear penalty) ---
    ALLOCATE (elem_conn(2, n_elem), gas(n_elem), q0(n_dof), f_ext(n_dof))
    DO e = 1, n_elem
      elem_conn(:, e) = [e, e + 1]
    END DO
    gas = ea

    CALL CD_FiniteEI_Touchdown_Seed(cat_positions, anchor, fairlead, l0, q0, nodes_ref, ErrStat, ErrMsg)
    IF (ErrStat /= 0) RETURN

    f_ext = CD_ZERO
    DO e = 1, n_elem
      i = elem_conn(1, e); j = elem_conn(2, e)
      f_ext(6*(i - 1) + 3) = f_ext(6*(i - 1) + 3) - w(e)*l0(e)/2.0_wp
      f_ext(6*(j - 1) + 3) = f_ext(6*(j - 1) + 3) - w(e)*l0(e)/2.0_wp
    END DO

    ALLOCATE (fixed(6))
    fixed(1:3) = [1, 2, 3]
    fixed(4:6) = [6*(n_nodes - 1) + 1, 6*(n_nodes - 1) + 2, 6*(n_nodes - 1) + 3]

    ! --- non-dimensionalisation (L = line length, F = max EA) ---
    lscale = SUM(l0)
    fscale = MAXVAL(ea)
    ls2 = lscale*lscale
    ALLOCATE (nodes_ref_nd(3, n_nodes), ea_nd(n_elem), gas_nd(n_elem), ei_nd(n_elem), gj_nd(n_elem))
    ALLOCATE (q0_nd(n_dof), f_ext_nd(n_dof), q_nd(n_dof), q_stage(n_dof))
    nodes_ref_nd = nodes_ref/lscale
    ea_nd = ea/fscale
    gas_nd = gas/fscale
    ei_nd = ei/(fscale*ls2)
    gj_nd = gj/(fscale*ls2)
    DO nd = 1, n_nodes
      base = 6*(nd - 1)
      q0_nd(base + 1:base + 3) = q0(base + 1:base + 3)/lscale
      q0_nd(base + 4:base + 6) = q0(base + 4:base + 6)
    END DO
    DO nd = 1, n_nodes
      base = 6*(nd - 1)
      DO axis = 1, 3
        f_ext_nd(base + axis) = f_ext(base + axis)/fscale
        f_ext_nd(base + 3 + axis) = f_ext(base + 3 + axis)/(fscale*lscale)
      END DO
    END DO
    kn_nd = seabed_kn*lscale/fscale
    zfloor_nd = z_floor/lscale

    ! --- load continuation in non-dim space ---
    q_stage = q0_nd
    DO s_idx = 1, ns
      CALL newton_nd(q_stage, nodes_ref_nd, elem_conn, ea_nd, gas_nd, ei_nd, gj_nd, &
                     load_factors(s_idx)*f_ext_nd, fixed, kn_nd, zfloor_nd, n_nodes, n_dof, &
                     cfg, q_nd, stage_conv, stage_stall, ErrStat, ErrMsg)
      IF (ErrStat /= CD_FEI_OK) THEN
        CALL scale_back(q_nd, n_nodes, lscale, q)   ! best state on the failed stage
        converged = .FALSE.; stalled = stage_stall
        RETURN
      END IF
      IF (.NOT. stage_conv) THEN
        CALL scale_back(q_nd, n_nodes, lscale, q)
        converged = .FALSE.; stalled = stage_stall
        RETURN
      END IF
      n_stages_done = s_idx
      q_stage = q_nd
    END DO

    converged = .TRUE.
    stalled = .FALSE.
    CALL scale_back(q_nd, n_nodes, lscale, q)

    ! --- dimensional element tension EA*(chord/ref - 1) ---
    DO e = 1, n_elem
      i = elem_conn(1, e); j = elem_conn(2, e)
      chord = norm3(q(6*(j - 1) + 1:6*(j - 1) + 3) - q(6*(i - 1) + 1:6*(i - 1) + 3))
      refl = norm3(nodes_ref(:, j) - nodes_ref(:, i))
      tension(e) = ea(e)*(chord/refl - CD_ONE)
    END DO

  CONTAINS

    SUBROUTINE fail(msg)
      CHARACTER(*), INTENT(IN) :: msg
      ErrStat = CD_FEI_BADINPUT
      ErrMsg = 'CD_Solve_FiniteEI_Touchdown: '//msg
    END SUBROUTINE fail

  END SUBROUTINE CD_Solve_FiniteEI_Touchdown

  ! --------------------------------------------------------------------------- !
  ! private helpers                                                             !
  ! --------------------------------------------------------------------------- !

  SUBROUTINE newton_nd(q0, nodes_ref, elem_conn, ea, gas, ei, gj, f_ext, fixed, kn, zfloor, &
                       n_nodes, n_dof, cfg, q, converged, stalled, ErrStat, ErrMsg)
    !! Dense Newton/Armijo for the non-dim finite-EI Cosserat solve with a penalty
    !! seabed. Step in additive rotation coordinates, applied via the dexp-corrected
    !! multiplicative SO(3) update; the seabed adds k_n on the active (gap >= 0) z
    !! diagonals. Mirrors CableDyn_CosseratStatic + CableDyn_Static's seabed handling.
    REAL(wp), INTENT(IN) :: q0(:), nodes_ref(:, :), ea(:), gas(:), ei(:), gj(:), f_ext(:)
    INTEGER, INTENT(IN) :: elem_conn(:, :), fixed(:), n_nodes, n_dof
    REAL(wp), INTENT(IN) :: kn, zfloor
    TYPE(CosseratSolverConfig), INTENT(IN) :: cfg
    REAL(wp), INTENT(OUT) :: q(:)
    LOGICAL, INTENT(OUT) :: converged, stalled
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg

    INTEGER, ALLOCATABLE :: free(:)
    REAL(wp), ALLOCATABLE :: Kt(:, :), fint(:), seabed_f(:), Kt_free(:, :)
    REAL(wp), ALLOCATABLE :: R_free(:), dq(:), dq_global(:), q_trial(:), R_trial(:)
    REAL(wp) :: f_ext_base, conv_scale, scale_trial, rnorm, merit, merit_trial, alpha
    INTEGER :: n_free, iteration, bt, nd, zdof, es
    CHARACTER(1024) :: em

    converged = .FALSE.; stalled = .FALSE.
    ErrStat = CD_FEI_OK; ErrMsg = ''
    q = q0

    CALL CD_Partition_Free_Dofs(fixed, n_dof, free, ErrStat, ErrMsg)
    IF (ErrStat /= 0) THEN
      ErrMsg = 'newton_nd: '//TRIM(ErrMsg); ErrStat = CD_FEI_BADINPUT; RETURN
    END IF
    n_free = SIZE(free)
    IF (n_free == 0) THEN
      converged = .TRUE.; RETURN
    END IF

    ALLOCATE (Kt(n_dof, n_dof), fint(n_dof), seabed_f(n_dof))
    ALLOCATE (Kt_free(n_free, n_free), R_free(n_free), dq(n_free))
    ALLOCATE (dq_global(n_dof), q_trial(n_dof), R_trial(n_free))

    f_ext_base = infnorm(f_ext(free))
    CALL eval_residual(q, R_free, conv_scale)
    IF (ErrStat /= 0) RETURN
    rnorm = infnorm(R_free)
    IF (rnorm/conv_scale < cfg%rel_tol .OR. rnorm < cfg%abs_tol) THEN
      converged = .TRUE.; RETURN
    END IF

    DO iteration = 1, cfg%max_iter
      CALL CD_Assemble_Cosserat_Tangent_Force(nodes_ref, elem_conn, ea, gas, ei, gj, q, &
                                              .TRUE., Kt, fint, es, em)
      IF (es /= 0) THEN
        ErrStat = CD_FEI_BADINPUT; ErrMsg = 'newton_nd: tangent assembly failed: '//TRIM(em); RETURN
      END IF
      ! + seabed contact tangent: +k_n on each active (gap >= 0) z diagonal.
      DO nd = 1, n_nodes
        zdof = 6*(nd - 1) + 3
        IF (zfloor - q(zdof) >= CD_ZERO) Kt(zdof, zdof) = Kt(zdof, zdof) + kn
      END DO
      Kt_free = Kt(free, free)
      dq = -R_free
      CALL CD_Solve_Dense_As_Banded(Kt_free, dq, es, em)
      IF (es /= 0 .OR. .NOT. CD_All_Finite(dq)) THEN
        ErrStat = CD_FEI_SINGULAR
        ErrMsg = 'newton_nd: tangent singular or ill-conditioned (DGBSV): '//TRIM(em); RETURN
      END IF

      merit = 0.5_wp*DOT_PRODUCT(R_free, R_free)
      alpha = CD_ONE
      stalled = .TRUE.
      DO bt = 0, cfg%armijo_max_backtracks
        dq_global = CD_ZERO
        dq_global(free) = alpha*dq
        CALL apply_increment(q, dq_global, q_trial)
        CALL eval_residual(q_trial, R_trial, scale_trial)
        IF (ErrStat /= 0) RETURN
        merit_trial = 0.5_wp*DOT_PRODUCT(R_trial, R_trial)
        IF (merit_trial <= merit*(CD_ONE - cfg%armijo_c1*alpha)) THEN
          stalled = .FALSE.; EXIT
        END IF
        alpha = 0.5_wp*alpha
      END DO
      IF (stalled) RETURN

      q = q_trial
      R_free = R_trial
      conv_scale = scale_trial
      rnorm = infnorm(R_free)
      IF (rnorm/conv_scale < cfg%rel_tol .OR. rnorm < cfg%abs_tol) THEN
        converged = .TRUE.; RETURN
      END IF
    END DO

  CONTAINS

    SUBROUTINE eval_residual(qe, Rf, sc)
      REAL(wp), INTENT(IN) :: qe(:)
      REAL(wp), INTENT(OUT) :: Rf(:), sc
      INTEGER :: ndl, zdofl, es_e
      CHARACTER(1024) :: em_e
      CALL CD_Assemble_Cosserat_Internal_Force(nodes_ref, elem_conn, ea, gas, ei, gj, qe, &
                                               .TRUE., fint, es_e, em_e)
      IF (es_e /= 0) THEN
        ErrStat = CD_FEI_BADINPUT; ErrMsg = 'newton_nd: internal-force assembly failed: '//TRIM(em_e)
        Rf = CD_ZERO; sc = CD_ONE; RETURN
      END IF
      seabed_f = CD_ZERO
      DO ndl = 1, n_nodes
        zdofl = 6*(ndl - 1) + 3
        IF (zfloor - qe(zdofl) >= CD_ZERO) seabed_f(zdofl) = kn*(zfloor - qe(zdofl))
      END DO
      Rf = fint(free) - f_ext(free) - seabed_f(free)
      sc = MAX(f_ext_base, infnorm(seabed_f(free)), cfg%abs_tol)
    END SUBROUTINE eval_residual

    SUBROUTINE apply_increment(q_in, dqg, q_out)
      !! Translations additive; rotations dexp-corrected SO(3) compose; fixed re-imposed.
      REAL(wp), INTENT(IN) :: q_in(:), dqg(:)
      REAL(wp), INTENT(OUT) :: q_out(:)
      INTEGER :: ndl, basel
      REAL(wp) :: theta_old(3), delta_omega(3)
      q_out = q_in
      DO ndl = 1, n_nodes
        basel = 6*(ndl - 1)
        q_out(basel + 1:basel + 3) = q_in(basel + 1:basel + 3) + dqg(basel + 1:basel + 3)
        theta_old = q_in(basel + 4:basel + 6)
        delta_omega = MATMUL(CD_Dexp_SO3(theta_old), dqg(basel + 4:basel + 6))
        q_out(basel + 4:basel + 6) = CD_Compose_Rotvec(theta_old, delta_omega)
      END DO
      q_out(fixed) = q_in(fixed)
    END SUBROUTINE apply_increment

  END SUBROUTINE newton_nd

  SUBROUTINE scale_back(q_nd, n_nodes, lscale, q)
    !! Scale non-dim positions back to dimensional (rotations unchanged).
    REAL(wp), INTENT(IN) :: q_nd(:), lscale
    INTEGER, INTENT(IN) :: n_nodes
    REAL(wp), INTENT(OUT) :: q(:)
    INTEGER :: nd, base
    q = q_nd
    DO nd = 1, n_nodes
      base = 6*(nd - 1)
      q(base + 1:base + 3) = q_nd(base + 1:base + 3)*lscale
    END DO
  END SUBROUTINE scale_back

  SUBROUTINE CD_FiniteEI_Centerline_Curvature(q, n_nodes, arc, curv, ErrStat, ErrMsg)
    !! Geometric centreline curvature at each interior node [1/m] + its arc length from
    !! node 1 (anchor) [m]. The discrete curvature is the turn angle between the two
    !! segments meeting at an interior node over the mean of their (deformed) lengths --
    !! directly comparable to OrcaFlex's reported Curvature. Returns n_nodes-2 values in
    !! sequential node order (the mesh is a single open chain 1..n_nodes).
    REAL(wp), INTENT(IN)  :: q(:)            !! (6 n_nodes) state
    INTEGER, INTENT(IN)  :: n_nodes
    REAL(wp), INTENT(OUT) :: arc(:), curv(:) !! (n_nodes-2) each
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg

    INTEGER :: n_elem, e, nd, k
    REAL(wp), ALLOCATABLE :: seg(:, :), seglen(:)
    REAL(wp) :: t1(3), t2(3), cos_turn, cumulative

    ErrStat = CD_FEI_OK; ErrMsg = ''
    arc = CD_ZERO; curv = CD_ZERO
    n_elem = n_nodes - 1
    IF (n_nodes < 3 .OR. SIZE(q) /= 6*n_nodes .OR. SIZE(arc) /= n_nodes - 2 &
        .OR. SIZE(curv) /= n_nodes - 2) THEN
      ErrStat = CD_FEI_BADINPUT
      ErrMsg = 'CD_FiniteEI_Centerline_Curvature: shapes inconsistent (need n_nodes >= 3)'
      RETURN
    END IF
    IF (.NOT. CD_All_Finite(q)) THEN
      ErrStat = CD_FEI_BADINPUT; ErrMsg = 'CD_FiniteEI_Centerline_Curvature: q must be finite'; RETURN
    END IF

    ALLOCATE (seg(3, n_elem), seglen(n_elem))
    DO e = 1, n_elem
      seg(:, e) = q(6*e + 1:6*e + 3) - q(6*(e - 1) + 1:6*(e - 1) + 3)
      seglen(e) = norm3(seg(:, e))
      IF (seglen(e) <= CD_ZERO) THEN
        ErrStat = CD_FEI_BADINPUT; ErrMsg = 'CD_FiniteEI_Centerline_Curvature: zero-length segment'; RETURN
      END IF
    END DO

    cumulative = CD_ZERO
    k = 0
    DO nd = 2, n_nodes - 1
      cumulative = cumulative + seglen(nd - 1)
      t1 = seg(:, nd - 1)/seglen(nd - 1)
      t2 = seg(:, nd)/seglen(nd)
      cos_turn = MAX(-CD_ONE, MIN(CD_ONE, DOT_PRODUCT(t1, t2)))
      k = k + 1
      arc(k) = cumulative
      curv(k) = ACOS(cos_turn)/(0.5_wp*(seglen(nd - 1) + seglen(nd)))
    END DO
  END SUBROUTINE CD_FiniteEI_Centerline_Curvature

  SUBROUTINE CD_FiniteEI_Element_Bend_Moment(q, nodes_ref, ei, moment, ErrStat, ErrMsg)
    !! Per-element MATERIAL bending moment EI*sqrt(K1^2 + K2^2) [N.m] at the element
    !! centre (Gauss xi = 0, the segment midpoint where OrcaFlex reports its bend moment).
    !! Unlike the geometric curvature, this reads the Cosserat material curvature K from
    !! the rotational DOFs via the element strain measure, so a rotation/shear error in
    !! the solve changes it.
    REAL(wp), INTENT(IN)  :: q(:)            !! (6 n_nodes) state
    REAL(wp), INTENT(IN)  :: nodes_ref(:, :) !! (3, n_nodes) reference rod
    REAL(wp), INTENT(IN)  :: ei(:)           !! (n_elem) bending stiffness
    REAL(wp), INTENT(OUT) :: moment(:)       !! (n_elem)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg

    INTEGER :: n_nodes, n_elem, e, bi, bj
    REAL(wp) :: Lam0(3, 3), L0, q_elem(12), Gamma(3), Kappa(3)

    ErrStat = CD_FEI_OK; ErrMsg = ''
    moment = CD_ZERO
    n_nodes = SIZE(nodes_ref, 2)
    n_elem = n_nodes - 1
    IF (SIZE(nodes_ref, 1) /= 3 .OR. n_nodes < 2 .OR. SIZE(q) /= 6*n_nodes &
        .OR. SIZE(ei) /= n_elem .OR. SIZE(moment) /= n_elem) THEN
      ErrStat = CD_FEI_BADINPUT
      ErrMsg = 'CD_FiniteEI_Element_Bend_Moment: shapes inconsistent with the mesh'
      RETURN
    END IF
    IF (.NOT. CD_All_Finite(q) .OR. .NOT. CD_All_Finite(nodes_ref) &
        .OR. .NOT. CD_All_Finite(ei) .OR. ANY(ei < CD_ZERO)) THEN
      ErrStat = CD_FEI_BADINPUT
      ErrMsg = 'CD_FiniteEI_Element_Bend_Moment: q/nodes_ref/ei must be finite (ei >= 0)'
      RETURN
    END IF

    DO e = 1, n_elem
      IF (norm3(nodes_ref(:, e + 1) - nodes_ref(:, e)) <= CD_ZERO) THEN
        ErrStat = CD_FEI_BADINPUT
        ErrMsg = 'CD_FiniteEI_Element_Bend_Moment: zero-length reference span'
        RETURN
      END IF
      CALL CD_Reference_Frame(nodes_ref(:, e), nodes_ref(:, e + 1), Lam0, L0)
      bi = 6*(e - 1); bj = 6*e
      q_elem(1:6) = q(bi + 1:bi + 6)
      q_elem(7:12) = q(bj + 1:bj + 6)
      CALL CD_Cosserat_Strains(q_elem, Lam0, L0, CD_ZERO, Gamma, Kappa)
      moment(e) = ei(e)*SQRT(Kappa(1)**2 + Kappa(2)**2)
    END DO
  END SUBROUTINE CD_FiniteEI_Element_Bend_Moment

  SUBROUTINE normalize(v, ErrStat, ErrMsg)
    REAL(wp), INTENT(INOUT) :: v(3)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    REAL(wp) :: n
    ErrStat = CD_FEI_OK; ErrMsg = ''
    n = norm3(v)
    IF (n <= CD_ZERO .OR. .NOT. CD_Is_Finite(n)) THEN
      ErrStat = CD_FEI_BADINPUT; ErrMsg = 'zero vector'; RETURN
    END IF
    v = v/n
  END SUBROUTINE normalize

  SUBROUTINE shortest_arc_rotvec(a, b, rotvec, ErrStat, ErrMsg)
    !! Shortest-arc rotation vector mapping unit a to unit b = axis * angle.
    REAL(wp), INTENT(IN) :: a(3), b(3)
    REAL(wp), INTENT(OUT) :: rotvec(3)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    REAL(wp) :: cr(3), sine, cosine, angle
    ErrStat = CD_FEI_OK; ErrMsg = ''
    rotvec = CD_ZERO
    cr = cross3(a, b)
    sine = norm3(cr)
    cosine = MAX(-CD_ONE, MIN(CD_ONE, DOT_PRODUCT(a, b)))
    IF (sine < 1.0e-14_wp) THEN
      IF (cosine > CD_ZERO) THEN
        rotvec = CD_ZERO; RETURN
      END IF
      ErrStat = CD_FEI_BADINPUT
      ErrMsg = 'CD_FiniteEI_Touchdown_Seed: reference tangent antiparallel to a local tangent'
      RETURN
    END IF
    angle = ATAN2(sine, cosine)
    rotvec = (angle/sine)*cr
    IF (norm3(rotvec) >= PI - CHART_MARGIN) THEN
      ErrStat = CD_FEI_BADINPUT
      ErrMsg = 'CD_FiniteEI_Touchdown_Seed: tangent alignment reached the |theta| < pi chart boundary'
    END IF
  END SUBROUTINE shortest_arc_rotvec

  PURE FUNCTION cross3(a, b) RESULT(c)
    REAL(wp), INTENT(IN) :: a(3), b(3)
    REAL(wp) :: c(3)
    c = [a(2)*b(3) - a(3)*b(2), a(3)*b(1) - a(1)*b(3), a(1)*b(2) - a(2)*b(1)]
  END FUNCTION cross3

  PURE REAL(wp) FUNCTION norm3(v)
    REAL(wp), INTENT(IN) :: v(3)
    norm3 = SQRT(v(1)**2 + v(2)**2 + v(3)**2)
  END FUNCTION norm3

  PURE REAL(wp) FUNCTION infnorm(x)
    REAL(wp), INTENT(IN) :: x(:)
    IF (SIZE(x) == 0) THEN
      infnorm = CD_ZERO
    ELSE
      infnorm = MAXVAL(ABS(x))
    END IF
  END FUNCTION infnorm

END MODULE CableDyn_FiniteEIStatic
