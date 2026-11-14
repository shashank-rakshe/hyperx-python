! File: src/CableDyn_CosseratStatic.f90
! SPDX-License-Identifier: Apache-2.0
! Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
MODULE CableDyn_CosseratStatic
  !! Static Newton-Raphson + Armijo solver for the finite-EI (geometrically-exact)
  !! Cosserat path, for the 6-DOF/node element: drive the residual
  !! R = f_int(q) - f_ext to zero on the free DOFs by Newton iteration with an Armijo
  !! backtracking line search on the 1/2||R||^2 merit, the free-DOF tangent block
  !! packed to LAPACK general-band storage and solved with DGBSV.
  !!
  !! The Newton step dq is taken in ADDITIVE rotation-vector coordinates (the
  !! variable the element tangent differentiates), then applied with the
  !! dexp-corrected MULTIPLICATIVE rotation update (CableDyn_SO3
  !! CD_Dexp_SO3 / CD_Compose_Rotvec): translations get r <- r + dr; rotations get
  !! delta_omega = dexp(theta).dq_add then theta <- compose(theta, delta_omega), so
  !! the additive tangent and the on-manifold update share one coordinate system
  !! (quadratic convergence). Fixed DOFs are re-imposed after the SO(3) compose.
  !!
  !! Conventions: q is the flat (6 n_nodes) state [r(3), theta(3)] per node; node nd
  !! owns DOFs 6*nd-5:6*nd; fixed_dofs are 1-based global DOF indices held at q0.
  USE CableDyn_Precision, ONLY: wp, CD_ZERO, CD_ONE, CD_All_Finite, CD_Is_Finite
  USE CableDyn_CosseratAssemble, ONLY: CD_Assemble_Cosserat_Tangent_Force_Banded_Free, &
                                       CD_Assemble_Cosserat_Internal_Force, &
                                       CD_Cosserat_Free_Bandwidth
  USE CableDyn_SO3, ONLY: CD_Dexp_SO3, CD_Compose_Rotvec
  USE CableDyn_Mesh, ONLY: CD_Partition_Free_Dofs
  USE CableDyn_Linalg, ONLY: CD_Solve_Banded
  IMPLICIT NONE
  PRIVATE
  PUBLIC :: CosseratSolverConfig, CD_Static_Cosserat_Solve
  INTEGER, PARAMETER, PUBLIC :: CD_COS_OK = 0, CD_COS_BADINPUT = 1, CD_COS_SINGULAR = 2

  TYPE :: CosseratSolverConfig
    !! Newton / Armijo policy of the Cosserat static solve.
    REAL(wp) :: rel_tol = 1.0e-8_wp
    REAL(wp) :: abs_tol = 1.0e-12_wp
    INTEGER :: max_iter = 50
    REAL(wp) :: armijo_c1 = 1.0e-4_wp
    INTEGER :: armijo_max_backtracks = 12
  END TYPE CosseratSolverConfig

CONTAINS

  SUBROUTINE CD_Static_Cosserat_Solve(nodes_ref, elem_conn, ea, gas, ei, gj, q0, f_ext, &
                                      fixed_dofs, reduced_shear, cfg, q, converged, stalled, &
                                      n_iter, ErrStat, ErrMsg)
    REAL(wp), INTENT(IN) :: nodes_ref(:, :), ea(:), gas(:), ei(:), gj(:), q0(:), f_ext(:)
    INTEGER, INTENT(IN) :: elem_conn(:, :), fixed_dofs(:)
    LOGICAL, INTENT(IN) :: reduced_shear
    TYPE(CosseratSolverConfig), INTENT(IN) :: cfg
    REAL(wp), INTENT(OUT) :: q(:)
    LOGICAL, INTENT(OUT) :: converged, stalled
    INTEGER, INTENT(OUT) :: n_iter, ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg

    INTEGER :: n_dof, n_nodes, n_free, iteration, bt, es, kl, ku, ldab
    INTEGER, ALLOCATABLE :: free(:)
    REAL(wp), ALLOCATABLE :: Kb(:, :), fint(:), R_free(:), dq(:)
    REAL(wp), ALLOCATABLE :: dq_global(:), q_trial(:), R_trial(:), fint0(:)
    REAL(wp) :: f_ext_base, conv_scale, rnorm, merit, merit_trial, alpha, scale_trial
    CHARACTER(1024) :: em

    converged = .FALSE.; stalled = .FALSE.; n_iter = 0
    ErrStat = CD_COS_OK; ErrMsg = ''
    n_dof = SIZE(q0)
    q = CD_ZERO

    ! --- input validation (fail closed) ---
    IF (MOD(n_dof, 6) /= 0 .OR. n_dof < 12) THEN
      CALL fail('q0 must be a 6-DOF/node Cosserat state (6 n_nodes), n_nodes >= 2'); RETURN
    END IF
    IF (SIZE(q) /= n_dof .OR. SIZE(f_ext) /= n_dof) THEN
      CALL fail('q and f_ext must have the same shape as q0'); RETURN
    END IF
    IF (.NOT. CD_All_Finite(q0) .OR. .NOT. CD_All_Finite(f_ext)) THEN
      CALL fail('q0 and f_ext must be finite'); RETURN
    END IF
    IF (.NOT. pos_finite(cfg%rel_tol) .OR. .NOT. pos_finite(cfg%abs_tol) &
        .OR. .NOT. pos_finite(cfg%armijo_c1) .OR. cfg%armijo_c1 >= CD_ONE &
        .OR. cfg%max_iter < 1 .OR. cfg%armijo_max_backtracks < 0) THEN
      CALL fail('invalid solver config'); RETURN
    END IF
    n_nodes = n_dof/6

    ! Reject PARTIAL rotational Dirichlet (1 or 2 of a node's 3 rotation DOFs
    ! fixed). The dexp-corrected multiplicative update composes the full rotation
    ! triplet, so re-imposing only some components after the SO(3) compose leaves
    ! the BCH cross-terms inconsistent at finite rotation -- a subtle
    ! case. Only fully-free or fully-fixed rotational triplets are supported here
    ! (full hinge / twist-lock support via the additive-constraint projection is a
    ! possible extension). Translation is free.
    CALL reject_partial_rotational_dirichlet(fixed_dofs, n_nodes, ErrStat, ErrMsg)
    IF (ErrStat /= 0) RETURN

    CALL CD_Partition_Free_Dofs(fixed_dofs, n_dof, free, ErrStat, ErrMsg)
    IF (ErrStat /= 0) RETURN
    n_free = SIZE(free)
    q = q0
    IF (n_free == 0) THEN
      ! Every DOF prescribed. Still validate the mesh / properties / element
      ! domain (connectivity, zero-length spans, |theta| < pi chart, near-pi)
      ! before reporting success -- the normal path validates via the first
      ! residual evaluation, which this shortcut would otherwise skip, so an
      ! all-prescribed restart with a malformed mesh or out-of-chart fixed
      ! rotation must still fail closed rather than report a spurious solve.
      ALLOCATE (fint0(n_dof))
      CALL CD_Assemble_Cosserat_Internal_Force(nodes_ref, elem_conn, ea, gas, ei, gj, q0, &
                                               reduced_shear, fint0, es, em)
      DEALLOCATE (fint0)
      IF (es /= 0) THEN
        CALL fail('all-prescribed input failed mesh/element validation: '//TRIM(em)); RETURN
      END IF
      converged = .TRUE.; RETURN
    END IF

    CALL CD_Cosserat_Free_Bandwidth(elem_conn, n_nodes, free, kl, ku, ErrStat, ErrMsg)
    IF (ErrStat /= 0) THEN
      CALL fail('bandwidth analysis failed: '//TRIM(ErrMsg)); RETURN
    END IF
    ldab = 2*kl + ku + 1

    ALLOCATE (Kb(ldab, n_free), fint(n_dof), R_free(n_free))
    ALLOCATE (dq(n_free), dq_global(n_dof), q_trial(n_dof), R_trial(n_free))

    f_ext_base = infnorm(f_ext(free))

    CALL eval_residual(q, R_free, conv_scale)
    IF (ErrStat /= 0) RETURN
    rnorm = infnorm(R_free)
    IF (is_converged(rnorm, conv_scale)) THEN
      converged = .TRUE.; RETURN
    END IF

    DO iteration = 1, cfg%max_iter
      n_iter = iteration
      CALL CD_Assemble_Cosserat_Tangent_Force_Banded_Free(nodes_ref, elem_conn, ea, gas, ei, gj, q, &
                                                          reduced_shear, free, kl, ku, Kb, fint, es, em)
      IF (es /= 0) THEN
        CALL fail('tangent assembly failed: '//TRIM(em)); RETURN
      END IF
      dq = -R_free
      CALL CD_Solve_Banded(Kb, kl, ku, dq, es, em)
      IF (es /= 0 .OR. .NOT. CD_All_Finite(dq)) THEN
        ErrStat = CD_COS_SINGULAR
        ErrMsg = 'CableDyn_CosseratStatic: tangent singular or ill-conditioned (DGBSV): '//TRIM(em)
        RETURN
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
      IF (is_converged(rnorm, conv_scale)) THEN
        converged = .TRUE.; RETURN
      END IF
    END DO

  CONTAINS

    SUBROUTINE eval_residual(qe, Rf, sc)
      REAL(wp), INTENT(IN) :: qe(:)
      REAL(wp), INTENT(OUT) :: Rf(:), sc
      REAL(wp), ALLOCATABLE :: fint_e(:)
      INTEGER :: es_e
      CHARACTER(1024) :: em_e
      ALLOCATE (fint_e(n_dof))
      CALL CD_Assemble_Cosserat_Internal_Force(nodes_ref, elem_conn, ea, gas, ei, gj, qe, &
                                               reduced_shear, fint_e, es_e, em_e)
      IF (es_e /= 0) THEN
        CALL fail('internal-force assembly failed: '//TRIM(em_e)); Rf = CD_ZERO; sc = CD_ONE; RETURN
      END IF
      Rf = fint_e(free) - f_ext(free)
      sc = MAX(f_ext_base, infnorm(Rf), cfg%abs_tol)
    END SUBROUTINE eval_residual

    SUBROUTINE apply_increment(q_in, dqg, q_out)
      !! Translations additive; rotations dexp-corrected SO(3) compose; fixed re-imposed.
      REAL(wp), INTENT(IN) :: q_in(:), dqg(:)
      REAL(wp), INTENT(OUT) :: q_out(:)
      INTEGER :: nd, base
      REAL(wp) :: theta_old(3), delta_omega(3)
      q_out = q_in
      DO nd = 1, n_nodes
        base = 6*(nd - 1)
        q_out(base + 1:base + 3) = q_in(base + 1:base + 3) + dqg(base + 1:base + 3)
        theta_old = q_in(base + 4:base + 6)
        delta_omega = MATMUL(CD_Dexp_SO3(theta_old), dqg(base + 4:base + 6))
        q_out(base + 4:base + 6) = CD_Compose_Rotvec(theta_old, delta_omega)
      END DO
      q_out(fixed_dofs) = q_in(fixed_dofs)
    END SUBROUTINE apply_increment

    LOGICAL FUNCTION is_converged(rn, sc)
      REAL(wp), INTENT(IN) :: rn, sc
      is_converged = (rn/sc < cfg%rel_tol) .OR. (rn < cfg%abs_tol)
    END FUNCTION is_converged

    SUBROUTINE fail(msg)
      CHARACTER(*), INTENT(IN) :: msg
      ErrStat = CD_COS_BADINPUT
      ErrMsg = 'CD_Static_Cosserat_Solve: '//msg
    END SUBROUTINE fail

  END SUBROUTINE CD_Static_Cosserat_Solve

  PURE REAL(wp) FUNCTION infnorm(x)
    REAL(wp), INTENT(IN) :: x(:)
    infnorm = MAXVAL(ABS(x))
  END FUNCTION infnorm

  PURE LOGICAL FUNCTION pos_finite(x)
    REAL(wp), INTENT(IN) :: x
    pos_finite = CD_Is_Finite(x) .AND. x > CD_ZERO
  END FUNCTION pos_finite

  SUBROUTINE reject_partial_rotational_dirichlet(fixed_dofs, n_nodes, ErrStat, ErrMsg)
    !! Fail closed if any node has 1 or 2 (but not 0 or 3) of its three rotation
    !! DOFs (local 4,5,6) in fixed_dofs. Node nd owns global DOFs 6*nd-5:6*nd, so
    !! its rotation DOFs are 6*nd-2, 6*nd-1, 6*nd.
    INTEGER, INTENT(IN) :: fixed_dofs(:), n_nodes
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    INTEGER :: nd, base, cnt, k, d
    ErrStat = 0; ErrMsg = ''
    DO nd = 1, n_nodes
      base = 6*(nd - 1)
      cnt = 0
      DO k = 1, SIZE(fixed_dofs)
        d = fixed_dofs(k)
        IF (d == base + 4 .OR. d == base + 5 .OR. d == base + 6) cnt = cnt + 1
      END DO
      IF (cnt /= 0 .AND. cnt /= 3) THEN
        ErrStat = CD_COS_BADINPUT
        ErrMsg = 'CD_Static_Cosserat_Solve: partial rotational Dirichlet '// &
                 '(1 or 2 of 3 rotation DOFs fixed at a node) is not supported -- fix all 3 or none'
        RETURN
      END IF
    END DO
  END SUBROUTINE reject_partial_rotational_dirichlet

END MODULE CableDyn_CosseratStatic
