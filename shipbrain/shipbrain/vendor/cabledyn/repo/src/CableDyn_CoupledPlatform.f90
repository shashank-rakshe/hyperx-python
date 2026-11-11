! File: src/CableDyn_CoupledPlatform.f90
! SPDX-License-Identifier: Apache-2.0
! Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
MODULE CableDyn_CoupledPlatform
  !! Coupled body6 platform + EI=0 mooring static equilibrium. Used by the validation
  !! tests (tests/test_l4_platform_mooring.f90); no product path calls it.
  !!
  !! A 6-DOF rigid platform with pose [r_body(3), theta(3)] (theta a rotation vector,
  !! updated multiplicatively on the left via CD_Compose_Rotvec) is held by N mooring
  !! lines, each attached at a body-frame fairlead offset. A Newton solve on the pose
  !! drives the world-frame wrench balance
  !!     R(pose) = W_body(pose) - sum_i J_i^T g_i = 0,
  !! where for line i: the fairlead sits at r_body + R(theta) offset_i, an inner
  !! EI=0 cable solve with that fairlead pinned returns the reaction force g_i and the
  !! Schur-condensed 3x3 fairlead stiffness K_fair_i, and J_i = [I3 | -hat(R offset_i)]
  !! is the 3x6 attachment motion Jacobian (so J^T g = [g, ell x g] is the body wrench).
  !!
  !! W_body is the bundled linear hydrostatic model W(pose) = w0 - C (pose - pose_ref)
  !! (dW = -C); the mooring supplies the surge/sway/yaw stiffness C lacks. The Newton
  !! tangent is assembled fully in the SPATIAL rotation increment delta_omega (the same
  !! coordinate the pose update and J use): the hydrostatic rotational columns are mapped
  !! by dexp_inv(theta), the mooring block sum J^T K_fair J is already spatial, and the
  !! geometric rotating-lever block sum [hat(g) hat(ell)] = outer(ell,g) - (g.ell) I
  !! closes the rotation-rotation tangent. An Armijo line search on the non-dimensional
  !! residual globalises the step and backtracks on an inner-line-solve failure.
  USE CableDyn_Precision, ONLY: wp, CD_ZERO, CD_ONE, CD_All_Finite, CD_Is_Finite
  USE CableDyn_SO3, ONLY: CD_Hat, CD_Exp_SO3, CD_Dexp_Inv_SO3, CD_Compose_Rotvec
  USE CableDyn_Assemble, ONLY: CD_Assemble_Cable_Tangent_Force
  USE CableDyn_Static, ONLY: CableSolverConfig, CD_Static_Cable_Solve, CD_STATIC_OK, CD_STATIC_SINGULAR
  USE CableDyn_Linalg, ONLY: CD_Solve_Dense_As_Banded
  IMPLICIT NONE
  PRIVATE

  PUBLIC :: CD_Fairlead_Solve
  PUBLIC :: CD_Platform_Residual_Tangent
  PUBLIC :: CD_Solve_Platform_Mooring
  INTEGER, PARAMETER, PUBLIC :: CD_PLAT_OK = 0, CD_PLAT_BADINPUT = 1
  INTEGER, PARAMETER, PUBLIC :: CD_PLAT_SINGULAR = 2, CD_PLAT_INNER_FAIL = 3

CONTAINS

  SUBROUTINE CD_Fairlead_Solve(seed, elem_conn, l0, ea, tension_only, f_ext, anchor_node, &
                               fairlead_node, fairlead_pos, cfg, q, g, k_fair, ErrStat, ErrMsg)
    !! Solve one EI=0 mooring line with its fairlead prescribed at fairlead_pos (and its
    !! anchor fixed at the seed). Returns the converged state q, the fairlead reaction
    !! g = (f_int - f_ext)[fairlead] (the generalised force the body applies to hold the
    !! fairlead), and K_fair = d g / d(fairlead pos) -- the analytic Schur complement of
    !! the converged line tangent onto the 3 fairlead DOFs (the free interior DOFs
    !! condensed; the anchor stays fixed). A singular / non-converged inner solve returns
    !! ErrStat = CD_PLAT_INNER_FAIL so the outer line search can backtrack.
    REAL(wp), INTENT(IN)  :: seed(:)            !! (3 n_nodes) warm-start state
    INTEGER, INTENT(IN)  :: elem_conn(:, :)     !! (2, n_elem)
    REAL(wp), INTENT(IN)  :: l0(:), ea(:)        !! (n_elem)
    LOGICAL, INTENT(IN)  :: tension_only
    REAL(wp), INTENT(IN)  :: f_ext(:)            !! (3 n_nodes) external (gravity) load
    INTEGER, INTENT(IN)  :: anchor_node, fairlead_node   !! 1-based node indices
    REAL(wp), INTENT(IN)  :: fairlead_pos(3)
    TYPE(CableSolverConfig), INTENT(IN) :: cfg
    REAL(wp), INTENT(OUT) :: q(:)                !! (3 n_nodes) converged state
    REAL(wp), INTENT(OUT) :: g(3), k_fair(3, 3)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg

    INTEGER :: n_dof, n_nodes, n_elem, n_free, i, j, c, es, n_iter
    INTEGER :: fdof(3), adof(3)
    INTEGER, ALLOCATABLE :: fixed(:), free(:)
    REAL(wp), ALLOCATABLE :: q0(:), Kt(:, :), fint(:), tension(:)
    REAL(wp), ALLOCATABLE :: k_rr(:, :), k_rf(:, :), k_fr(:, :), xcol(:)
    REAL(wp) :: k_ff(3, 3)
    LOGICAL :: conv, stalled, at_floor
    CHARACTER(1024) :: em

    ErrStat = CD_PLAT_OK; ErrMsg = ''
    q = CD_ZERO; g = CD_ZERO; k_fair = CD_ZERO
    n_dof = SIZE(seed)
    n_nodes = n_dof/3
    n_elem = SIZE(elem_conn, 2)

    IF (MOD(n_dof, 3) /= 0 .OR. n_dof < 6 .OR. SIZE(q) /= n_dof .OR. SIZE(f_ext) /= n_dof) THEN
      CALL fail('seed/q/f_ext must be (3 n_nodes) positions-only states'); RETURN
    END IF
    IF (anchor_node < 1 .OR. anchor_node > n_nodes .OR. fairlead_node < 1 .OR. &
        fairlead_node > n_nodes .OR. anchor_node == fairlead_node) THEN
      CALL fail('anchor_node/fairlead_node out of range or equal'); RETURN
    END IF
    IF (.NOT. CD_All_Finite(fairlead_pos)) THEN
      CALL fail('fairlead_pos must be finite'); RETURN
    END IF

    fdof = 3*(fairlead_node - 1) + [1, 2, 3]
    adof = 3*(anchor_node - 1) + [1, 2, 3]
    ALLOCATE (fixed(6))
    fixed(1:3) = adof
    fixed(4:6) = fdof

    ALLOCATE (q0(n_dof), source=seed)
    q0(fdof) = fairlead_pos

    CALL CD_Static_Cable_Solve(q0, elem_conn, l0, ea, tension_only, f_ext, fixed, cfg, &
                               q, conv, stalled, at_floor, n_iter, es, em)
    IF (es == CD_STATIC_SINGULAR) THEN
      ErrStat = CD_PLAT_INNER_FAIL
      ErrMsg = 'CD_Fairlead_Solve: inner mooring-line tangent singular (slack/compression): '//TRIM(em)
      RETURN
    ELSE IF (es /= CD_STATIC_OK) THEN
      CALL fail('inner mooring-line solve input error: '//TRIM(em)); RETURN
    END IF
    IF (.NOT. (conv .OR. at_floor)) THEN
      ErrStat = CD_PLAT_INNER_FAIL
      ErrMsg = 'CD_Fairlead_Solve: inner mooring-line solve did not converge'
      RETURN
    END IF

    ! tangent + internal force at the converged state
    ALLOCATE (Kt(n_dof, n_dof), fint(n_dof), tension(n_elem))
    CALL CD_Assemble_Cable_Tangent_Force(RESHAPE(q, [3, n_nodes]), elem_conn, l0, ea, &
                                         tension_only, Kt, fint, tension, es, em)
    IF (es /= 0) THEN
      CALL fail('tangent assembly at converged state failed: '//TRIM(em)); RETURN
    END IF
    g = fint(fdof) - f_ext(fdof)

    ! Schur condensation of the free interior DOFs onto the fairlead block:
    !   K_fair = k_ff - k_fr k_rr^-1 k_rf.
    CALL build_free(fixed, n_dof, free)
    n_free = SIZE(free)
    k_ff = Kt(fdof, fdof)
    IF (n_free == 0) THEN
      k_fair = k_ff   ! single-element line: nothing to condense
      RETURN
    END IF
    ALLOCATE (k_rr(n_free, n_free), k_rf(n_free, 3), k_fr(3, n_free), xcol(n_free))
    k_rr = Kt(free, free)
    k_rf = Kt(free, fdof)
    k_fr = Kt(fdof, free)
    ! Solve k_rr X = k_rf column by column (X is free x 3), then K_fair = k_ff - k_fr X.
    k_fair = k_ff
    DO c = 1, 3
      xcol = k_rf(:, c)
      CALL CD_Solve_Dense_As_Banded(k_rr, xcol, es, em)
      IF (es /= 0 .OR. .NOT. CD_All_Finite(xcol)) THEN
        ErrStat = CD_PLAT_INNER_FAIL
        ErrMsg = 'CD_Fairlead_Solve: Schur reduction singular (k_rr): '//TRIM(em)
        RETURN
      END IF
      DO i = 1, 3
        DO j = 1, n_free
          k_fair(i, c) = k_fair(i, c) - k_fr(i, j)*xcol(j)
        END DO
      END DO
    END DO

  CONTAINS

    SUBROUTINE fail(msg)
      CHARACTER(*), INTENT(IN) :: msg
      ErrStat = CD_PLAT_BADINPUT
      ErrMsg = 'CD_Fairlead_Solve: '//msg
    END SUBROUTINE fail

  END SUBROUTINE CD_Fairlead_Solve

  SUBROUTINE CD_Solve_Platform_Mooring(n_lines, elem_conn, l0, ea, tension_only, f_ext, seed, &
                                       offset, anchor_node, fairlead_node, w0, cmat, pose_ref, &
                                       pose0, cfg, rel_tol, max_iter, pose, fairlead_forces, &
                                       converged, n_iter, ErrStat, ErrMsg)
    !! Coupled 6-DOF platform + mooring static Newton (bundled linear hydrostatic wrench
    !! W = w0 - C (pose - pose_ref)). All N lines share the mesh topology (elem_conn, l0,
    !! ea) and the gravity load f_ext; they differ by fairlead offset + warm-start seed.
    INTEGER, INTENT(IN)  :: n_lines
    INTEGER, INTENT(IN)  :: elem_conn(:, :)      !! (2, n_elem) shared
    REAL(wp), INTENT(IN)  :: l0(:), ea(:)         !! (n_elem) shared
    LOGICAL, INTENT(IN)  :: tension_only
    REAL(wp), INTENT(IN)  :: f_ext(:)             !! (3 n_nodes) shared gravity load
    REAL(wp), INTENT(IN)  :: seed(:, :)           !! (3 n_nodes, n_lines) per-line warm start
    REAL(wp), INTENT(IN)  :: offset(:, :)         !! (3, n_lines) body-frame fairlead offsets
    INTEGER, INTENT(IN)  :: anchor_node, fairlead_node
    REAL(wp), INTENT(IN)  :: w0(6), cmat(6, 6), pose_ref(6), pose0(6)
    TYPE(CableSolverConfig), INTENT(IN) :: cfg
    REAL(wp), INTENT(IN)  :: rel_tol
    INTEGER, INTENT(IN)  :: max_iter
    REAL(wp), INTENT(OUT) :: pose(6)
    REAL(wp), INTENT(OUT) :: fairlead_forces(3, n_lines)
    LOGICAL, INTENT(OUT) :: converged
    INTEGER, INTENT(OUT) :: n_iter, ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg

    INTEGER :: n_dof, iteration, bt, es
    REAL(wp), ALLOCATABLE :: seeds(:, :), states(:, :)
    REAL(wp) :: residual(6), k_sys(6, 6), dpose(6), trial_pose(6)
    REAL(wp) :: forces(3, n_lines), trial_forces(3, n_lines)
    REAL(wp) :: merit, merit_trial, alpha, fscale, mscale
    LOGICAL :: ok, trial_ok
    CHARACTER(1024) :: em
    REAL(wp), PARAMETER :: ARMIJO_C1 = 1.0e-4_wp

    ErrStat = CD_PLAT_OK; ErrMsg = ''
    converged = .FALSE.; n_iter = 0
    pose = CD_ZERO; fairlead_forces = CD_ZERO
    n_dof = SIZE(f_ext)

    ! --- validation ---
    IF (n_lines < 1) THEN
      CALL fail('at least one mooring line is required'); RETURN
    END IF
    IF (MOD(n_dof, 3) /= 0 .OR. SIZE(seed, 1) /= n_dof .OR. SIZE(seed, 2) /= n_lines &
        .OR. SIZE(offset, 1) /= 3 .OR. SIZE(offset, 2) /= n_lines) THEN
      CALL fail('seed (3n_nodes,n_lines) / offset (3,n_lines) shape mismatch'); RETURN
    END IF
    IF (.NOT. CD_All_Finite(pose0) .OR. .NOT. CD_All_Finite(w0) &
        .OR. .NOT. CD_All_Finite(cmat) .OR. .NOT. CD_All_Finite(pose_ref)) THEN
      CALL fail('pose0/w0/cmat/pose_ref must be finite'); RETURN
    END IF
    IF (.NOT. CD_Is_Finite(rel_tol) .OR. rel_tol <= CD_ZERO .OR. max_iter < 1) THEN
      CALL fail('rel_tol must be positive and max_iter >= 1'); RETURN
    END IF

    ALLOCATE (seeds(n_dof, n_lines), source=seed)
    ALLOCATE (states(n_dof, n_lines))
    pose = pose0

    DO iteration = 1, max_iter
      n_iter = iteration
      CALL CD_Platform_Residual_Tangent(pose, n_lines, elem_conn, l0, ea, tension_only, f_ext, &
                                        seeds, offset, anchor_node, fairlead_node, w0, cmat, &
                                        pose_ref, cfg, residual, k_sys, states, forces, ok, es, em)
      IF (es /= CD_PLAT_OK .AND. es /= CD_PLAT_INNER_FAIL) THEN
        ErrStat = es; ErrMsg = em; RETURN     ! a genuine input/model error surfaces
      END IF
      IF (.NOT. ok) THEN
        ! The current pose itself failed an inner solve -- cannot proceed from here.
        ErrStat = CD_PLAT_INNER_FAIL
        ErrMsg = 'CD_Solve_Platform_Mooring: inner mooring-line solve failed at the current pose: '//TRIM(em)
        RETURN
      END IF
      seeds = states
      CALL residual_scales(forces, offset, n_lines, fscale, mscale)
      merit = nd_residual(residual, fscale, mscale)
      IF (merit <= rel_tol) THEN
        converged = .TRUE.
        fairlead_forces = forces
        RETURN
      END IF

      ! Newton step: d(residual)/d(pose) = -k_sys, so dpose = k_sys^-1 residual.
      dpose = residual
      CALL CD_Solve_Dense_As_Banded(k_sys, dpose, es, em)
      IF (es /= 0 .OR. .NOT. CD_All_Finite(dpose)) THEN
        ErrStat = CD_PLAT_SINGULAR
        ErrMsg = 'CD_Solve_Platform_Mooring: 6-DOF system tangent singular -- mooring does '// &
                 'not restrain every platform DOF: '//TRIM(em)
        RETURN
      END IF

      ! Armijo backtracking on the non-dimensional residual; backtrack on inner-solve failure.
      alpha = CD_ONE
      ok = .FALSE.
      DO bt = 1, 12
        trial_pose = step_pose(pose, alpha*dpose)
        CALL CD_Platform_Residual_Tangent(trial_pose, n_lines, elem_conn, l0, ea, tension_only, f_ext, &
                                          seeds, offset, anchor_node, fairlead_node, w0, cmat, &
                                          pose_ref, cfg, residual, k_sys, states, trial_forces, trial_ok, es, em)
        IF (es /= CD_PLAT_OK .AND. es /= CD_PLAT_INNER_FAIL) THEN
          ErrStat = es; ErrMsg = em; RETURN
        END IF
        IF (.NOT. trial_ok) THEN
          alpha = 0.5_wp*alpha; CYCLE       ! overshoot into a failed inner solve -> shorten
        END IF
        CALL residual_scales(trial_forces, offset, n_lines, fscale, mscale)
        merit_trial = nd_residual(residual, fscale, mscale)
        IF (merit_trial <= (CD_ONE - ARMIJO_C1*alpha)*merit) THEN
          pose = trial_pose
          seeds = states
          forces = trial_forces
          ok = .TRUE.
          EXIT
        END IF
        alpha = 0.5_wp*alpha
      END DO
      IF (.NOT. ok) THEN
        ! line search exhausted: report non-convergence with the pre-step iterate's forces
        fairlead_forces = forces
        converged = .FALSE.
        RETURN
      END IF
    END DO

    ! Exhausted max_iter without converging. Re-evaluate at the final pose so the returned
    ! pose and fairlead_forces describe the SAME configuration (the loop's `forces` lags the
    ! pose by the last accepted step). A re-evaluation inner failure is reported honestly.
    CALL CD_Platform_Residual_Tangent(pose, n_lines, elem_conn, l0, ea, tension_only, f_ext, &
                                      seeds, offset, anchor_node, fairlead_node, w0, cmat, &
                                      pose_ref, cfg, residual, k_sys, states, forces, ok, es, em)
    IF (es /= CD_PLAT_OK .AND. es /= CD_PLAT_INNER_FAIL) THEN
      ErrStat = es; ErrMsg = em; RETURN
    END IF
    fairlead_forces = forces
    converged = .FALSE.

  CONTAINS

    SUBROUTINE fail(msg)
      CHARACTER(*), INTENT(IN) :: msg
      ErrStat = CD_PLAT_BADINPUT
      ErrMsg = 'CD_Solve_Platform_Mooring: '//msg
    END SUBROUTINE fail

  END SUBROUTINE CD_Solve_Platform_Mooring

  SUBROUTINE CD_Platform_Residual_Tangent(pose, n_lines, elem_conn, l0, ea, tension_only, f_ext, &
                                          seeds, offset, anchor_node, fairlead_node, w0, cmat, &
                                          pose_ref, cfg, residual, k_sys, states, forces, all_ok, &
                                          ErrStat, ErrMsg)
    !! Assemble the coupled 6-DOF residual R = W_body(pose) - sum_i J_i^T g_i and the Newton
    !! tangent k_sys = -d(residual)/d(pose increment) at `pose`, running the inner fairlead
    !! solve for every line. The tangent is fully in SPATIAL rotation-increment coordinates:
    !! the hydrostatic rotational columns mapped by dexp_inv(theta), the mooring block
    !! sum J^T K_fair J, and the geometric rotating-lever block outer(ell,g) - (g.ell) I.
    !! all_ok = .FALSE. with ErrStat = CD_PLAT_INNER_FAIL if any inner solve fails (the outer
    !! line search backtracks); a genuine input/model error sets ErrStat to that code.
    REAL(wp), INTENT(IN)  :: pose(6)
    INTEGER, INTENT(IN)  :: n_lines, elem_conn(:, :), anchor_node, fairlead_node
    REAL(wp), INTENT(IN)  :: l0(:), ea(:), f_ext(:), seeds(:, :), offset(:, :)
    LOGICAL, INTENT(IN)  :: tension_only
    REAL(wp), INTENT(IN)  :: w0(6), cmat(6, 6), pose_ref(6)
    TYPE(CableSolverConfig), INTENT(IN) :: cfg
    REAL(wp), INTENT(OUT) :: residual(6), k_sys(6, 6), states(:, :), forces(:, :)
    LOGICAL, INTENT(OUT) :: all_ok
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg

    REAL(wp) :: rot(3, 3), dwrench(6, 6), ell(3), fairlead_pos(3), gline(3), kfair(3, 3)
    REAL(wp) :: jac(3, 6), jt_kf(6, 3), geom(3, 3)
    REAL(wp), ALLOCATABLE :: qline(:)
    INTEGER :: li, es_l, n_dof
    CHARACTER(1024) :: em_l

    all_ok = .TRUE.; ErrStat = CD_PLAT_OK; ErrMsg = ''
    residual = CD_ZERO; k_sys = CD_ZERO
    n_dof = SIZE(f_ext)
    ALLOCATE (qline(n_dof))
    rot = CD_Exp_SO3(pose(4:6))
    ! body wrench W = w0 - C (pose - pose_ref); residual starts at the body wrench.
    residual = w0 - MATMUL(cmat, pose - pose_ref)
    dwrench = -cmat
    ! map the rotational columns of dW to the spatial increment, then k_sys = -dW_spatial.
    dwrench(:, 4:6) = MATMUL(dwrench(:, 4:6), CD_Dexp_Inv_SO3(pose(4:6)))
    k_sys = -dwrench
    DO li = 1, n_lines
      ell = MATMUL(rot, offset(:, li))
      fairlead_pos = pose(1:3) + ell
      CALL CD_Fairlead_Solve(seeds(:, li), elem_conn, l0, ea, tension_only, f_ext, anchor_node, &
                             fairlead_node, fairlead_pos, cfg, qline, gline, kfair, es_l, em_l)
      IF (es_l == CD_PLAT_INNER_FAIL) THEN
        all_ok = .FALSE.; ErrStat = CD_PLAT_INNER_FAIL; ErrMsg = em_l; RETURN
      ELSE IF (es_l /= CD_PLAT_OK) THEN
        all_ok = .FALSE.; ErrStat = es_l; ErrMsg = em_l; RETURN
      END IF
      states(:, li) = qline
      forces(:, li) = gline
      jac(:, 1:3) = eye3()
      jac(:, 4:6) = -CD_Hat(ell)
      residual = residual - matvec6(TRANSPOSE(jac), gline)   ! residual -= J^T g
      jt_kf = MATMUL(TRANSPOSE(jac), kfair)                   ! (6,3)
      k_sys = k_sys + MATMUL(jt_kf, jac)                      ! + J^T K_fair J
      ! geometric rotating-lever term: outer(ell,g) - (g.ell) I, into the moment/rotation block
      geom = outer3(ell, gline) - DOT_PRODUCT(gline, ell)*eye3()
      k_sys(4:6, 4:6) = k_sys(4:6, 4:6) + geom
    END DO
  END SUBROUTINE CD_Platform_Residual_Tangent

  ! --------------------------------------------------------------------------- !
  ! private helpers                                                             !
  ! --------------------------------------------------------------------------- !

  SUBROUTINE build_free(fixed, n_dof, free)
    !! Sorted complement of `fixed` in 1..n_dof.
    INTEGER, INTENT(IN) :: fixed(:), n_dof
    INTEGER, ALLOCATABLE, INTENT(OUT) :: free(:)
    LOGICAL :: is_fixed(n_dof)
    INTEGER :: i, k
    is_fixed = .FALSE.
    DO i = 1, SIZE(fixed)
      IF (fixed(i) >= 1 .AND. fixed(i) <= n_dof) is_fixed(fixed(i)) = .TRUE.
    END DO
    ALLOCATE (free(COUNT(.NOT. is_fixed)))
    k = 0
    DO i = 1, n_dof
      IF (.NOT. is_fixed(i)) THEN
        k = k + 1; free(k) = i
      END IF
    END DO
  END SUBROUTINE build_free

  PURE FUNCTION step_pose(pose, dpose) RESULT(out)
    !! Translation additive; rotation multiplicative on the left (spatial increment).
    REAL(wp), INTENT(IN) :: pose(6), dpose(6)
    REAL(wp) :: out(6)
    out(1:3) = pose(1:3) + dpose(1:3)
    out(4:6) = CD_Compose_Rotvec(pose(4:6), dpose(4:6))
  END FUNCTION step_pose

  SUBROUTINE residual_scales(forces, offset, n_lines, fscale, mscale)
    !! Force scale = largest fairlead pull; moment scale = that force times the largest
    !! lever (max ||offset||), so the moment residual is not artificially strict.
    REAL(wp), INTENT(IN) :: forces(:, :), offset(:, :)
    INTEGER, INTENT(IN) :: n_lines
    REAL(wp), INTENT(OUT) :: fscale, mscale
    INTEGER :: i
    REAL(wp) :: lever
    fscale = CD_ONE; lever = CD_ONE
    DO i = 1, n_lines
      fscale = MAX(fscale, NORM2(forces(:, i)))
      lever = MAX(lever, NORM2(offset(:, i)))
    END DO
    mscale = fscale*lever
  END SUBROUTINE residual_scales

  PURE REAL(wp) FUNCTION nd_residual(residual, fscale, mscale)
    !! max of the force- and moment-residual relative norms.
    REAL(wp), INTENT(IN) :: residual(6), fscale, mscale
    nd_residual = MAX(NORM2(residual(1:3))/fscale, NORM2(residual(4:6))/mscale)
  END FUNCTION nd_residual

  PURE FUNCTION eye3() RESULT(m)
    REAL(wp) :: m(3, 3)
    m = CD_ZERO
    m(1, 1) = CD_ONE; m(2, 2) = CD_ONE; m(3, 3) = CD_ONE
  END FUNCTION eye3

  PURE FUNCTION outer3(a, b) RESULT(m)
    REAL(wp), INTENT(IN) :: a(3), b(3)
    REAL(wp) :: m(3, 3)
    INTEGER :: i, j
    DO j = 1, 3
      DO i = 1, 3
        m(i, j) = a(i)*b(j)
      END DO
    END DO
  END FUNCTION outer3

  PURE FUNCTION matvec6(a, v) RESULT(r)
    !! 6x3 matrix times a 3-vector -> 6-vector (J^T g).
    REAL(wp), INTENT(IN) :: a(6, 3), v(3)
    REAL(wp) :: r(6)
    r = MATMUL(a, v)
  END FUNCTION matvec6

END MODULE CableDyn_CoupledPlatform
