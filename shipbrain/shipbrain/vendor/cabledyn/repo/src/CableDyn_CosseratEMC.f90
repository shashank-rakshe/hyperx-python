! File: src/CableDyn_CosseratEMC.f90
! SPDX-License-Identifier: Apache-2.0
! Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
MODULE CableDyn_CosseratEMC
  !! Energy-conserving (Simo-Tarnow-class) time integrator for the finite-EI
  !! Cosserat rod -- an opt-in alternative to the generalized-alpha path
  !! (CableDyn_CosseratDynamic). Where gen-alpha shows a small, dt-convergent
  !! large-rotation ENERGY drift, this scheme conserves total mechanical energy to
  !! round-off independently of dt, by combining:
  !!
  !! CONSERVATION SCOPE: the total LUMPED-mass ENERGY is conserved to round-off at all dt.
  !! The invariant is the scheme's own energy -- lumped translational KE
  !! (1/2 sum m_a |v_a|^2) + lumped rotational KE (1/2 sum pi_a.J_ref,a^-1 pi_a) + strain
  !! energy -- NOT the consistent-mass CD_Cosserat_Mechanical_Energy, whose translational KE
  !! uses the assembled consistent matrix; measuring this scheme with the consistent energy
  !! shows an apparent drift that is a mass-model difference, not a conservation failure.
  !! Setting cfg%emc_consistent_mass = .TRUE. switches the translational mass to the
  !! CONSISTENT matrix (matching CD_Cosserat_Mechanical_Energy), so that path conserves the
  !! consistent-mass energy directly to round-off; it supports free-free meshes only, and
  !! the closed-form tangent applies to it (velocity formulation -- the translational
  !! identity block carries M3).
  !! Angular momentum is conserved EXACTLY for free rigid-body rotation
  !! (the kernel below); under the internal elastic torque it is conserved only to
  !! O(dt^3) (bounded, not secular). Exact total-momentum conservation needs the
  !! frame-invariant algorithmic-strain (Simo-Tarnow) stress in place of the generic
  !! discrete gradient, which this scheme does not use -- hence "energy-conserving", not
  !! "energy-momentum-conserving".
  !!
  !!   * the implicit MIDPOINT rule on the per-node BODY angular-momentum equation
  !!     pi_dot = pi x J_ref^{-1} pi  (the free-rigid-body kernel: conserves energy
  !!     1/2 pi.J^{-1}pi and |pi| exactly), with a CAYLEY reconstruction
  !!     exp(theta_{n+1}) = exp(theta_n) cay(dt Omega_h);
  !!   * the GONZALEZ discrete-gradient of the strain energy for the elastic force,
  !!     gbar = grad_W(q_h) + [(W_{n+1}-W_n - grad_W(q_h).dq)/|dq|^2] dq, which makes
  !!     the algorithmic force do work exactly equal to the strain-energy change;
  !!   * the translational midpoint rule.
  !!
  !! Working in BODY angular momentum makes the rotational kinetic energy
  !! 1/2 pi.J_ref^{-1}pi configuration-INDEPENDENT (J_ref constant in the reference
  !! frame), so the Hamiltonian is separable and the discrete gradient applies
  !! cleanly. The internal-force assembler returns grad_W in additive-theta
  !! coordinates; it is mapped to the body-rotation-increment conjugate by
  !!   f_body_rot = dexp_inv(theta) . fint_rot
  !! (checked against central differences of W in tests/test_emc.f90).
  !!
  !! SCOPE: free-free meshes and WHOLE-NODE clamped supports (a
  !! fixed node is held at its input position with zero velocity; all 6 of its DOFs
  !! must appear in fixed_dofs). Partial-node fixing (a hinge / roller) and moving
  !! supports are rejected (fail closed) as follow-ups. The Newton solve uses a dense
  !! finite-difference Jacobian + dense LU by default; the closed-form consistent tangent
  !! (cfg%emc_analytic_tangent, quadratic convergence, verified vs the FD oracle) is opt-in and
  !! is solved with one BANDED factorization + a SHERMAN-MORRISON update for the single rank-1
  !! Gonzalez-correction term (the tangent is banded B + dt*dq (x) dcorr), reducing the solve
  !! from O(ndof^3) to O(ndof*bandwidth^2). The mass model is LUMPED by default (per-node
  !! translational mass + per-node reference rotational inertia); cfg%emc_consistent_mass = .TRUE.
  !! (free-free only) switches the TRANSLATIONAL mass to the CONSISTENT matrix so the scheme
  !! conserves the consistent-mass energy. It uses the VELOCITY as the translational unknown, so the
  !! momentum balance is M3 (w - v_n) + dt f = 0 with a per-node midpoint displacement dt (v_n+w)/2
  !! (no M3^-1 solve, only a banded M3 matvec); the closed-form tangent applies too -- it is the
  !! lumped tangent with the translational identity block replaced by M3 and the mass dropped from
  !! the increment blocks, still banded + Sherman-Morrison. Rotational stays the lumped kernel,
  !! which already matches the energy diagnostic. The default integrator remains generalized-alpha;
  !! this scheme is selected explicitly by the caller.
  USE CableDyn_Precision, ONLY: wp, CD_All_Finite, CD_Is_Finite
  USE CableDyn_SO3, ONLY: CD_Hat, CD_Exp_SO3, CD_Log_SO3, CD_Dexp_Inv_SO3, CD_Dexp_Dir_SO3
  USE CableDyn_Cosserat, ONLY: CD_Reference_Frame
  USE CableDyn_Mesh, ONLY: CD_Validate_Connectivity, CD_Validate_Positive
  USE CableDyn_CosseratDynamic, ONLY: CD_Cosserat_Mechanical_Energy, CD_Assemble_Cosserat_Mass
  USE CableDyn_CosseratAssemble, ONLY: CD_Assemble_Cosserat_Internal_Force, CD_Assemble_Cosserat_Tangent_Force
  USE CableDyn_Linalg, ONLY: CD_Factor_Banded, CD_Solve_Factored_Banded, CD_LINALG_OK
  USE CableDyn_Dynamic, ONLY: GenAlphaConfig, CD_DYN_OK, CD_DYN_BADINPUT, CD_DYN_SINGULAR
  IMPLICIT NONE
  PRIVATE
  PUBLIC :: CD_Cosserat_EMC_Step
  PUBLIC :: CD_EMC_Reference_Inertia

  REAL(wp), PARAMETER :: CD_ZERO = 0.0_wp, CD_ONE = 1.0_wp, CD_HALF = 0.5_wp

CONTAINS

  SUBROUTINE CD_EMC_Reference_Inertia(nodes_ref, elem_conn, rho_a, i_rho_t, i_rho_n, &
                                      mnode, Jref, ErrStat, ErrMsg)
    !! Per-node lumped translational mass and constant reference rotational inertia:
    !!   m_a    = sum_{adj e} (L0_e/2) rho_A_e
    !!   J_ref,a = sum_{adj e} (L0_e/2) Lam0_e diag(i_rho_t, i_rho_t, i_rho_n) Lam0_e^T
    !! J_ref is constant (theta-independent); the spatial inertia is exp(theta) J_ref exp(theta)^T.
    REAL(wp), INTENT(IN) :: nodes_ref(:, :), rho_a(:), i_rho_t(:), i_rho_n(:)
    INTEGER, INTENT(IN) :: elem_conn(:, :)
    REAL(wp), INTENT(OUT) :: mnode(:), Jref(:, :, :)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    INTEGER :: n_nodes, n_elem, e, a, k
    REAL(wp) :: Lam0(3, 3), L0, w, Jp(3, 3)
    ErrStat = CD_DYN_OK; ErrMsg = ''
    n_nodes = SIZE(nodes_ref, 2); n_elem = SIZE(elem_conn, 2)
    IF (SIZE(nodes_ref, 1) /= 3) THEN
      ErrStat = CD_DYN_BADINPUT; ErrMsg = 'CD_EMC_Reference_Inertia: nodes_ref must be (3, n_nodes)'; RETURN
    END IF
    IF (.NOT. CD_All_Finite(nodes_ref)) THEN
      ErrStat = CD_DYN_BADINPUT; ErrMsg = 'CD_EMC_Reference_Inertia: nodes_ref must be finite'; RETURN
    END IF
    IF (SIZE(mnode) /= n_nodes .OR. SIZE(Jref, 1) /= 3 .OR. SIZE(Jref, 2) /= 3 .OR. SIZE(Jref, 3) /= n_nodes) THEN
      ErrStat = CD_DYN_BADINPUT; ErrMsg = 'CD_EMC_Reference_Inertia: mnode(n_nodes) / Jref(3,3,n_nodes)'; RETURN
    END IF
    ! Shared mesh contract: in-range, no self-edge, no duplicate undirected edge,
    ! every node referenced (so no node gets a zero lumped mass) -- the same contract
    ! the finite-EI assembler enforces, rather than an ad-hoc range-only check.
    CALL CD_Validate_Connectivity(elem_conn, n_nodes, n_elem, ErrStat, ErrMsg)
    IF (ErrStat /= 0) THEN; ErrStat = CD_DYN_BADINPUT; RETURN; END IF
    ! Per-element inertia arrays: shape (n_elem), finite, strictly positive (rejects +Inf).
    CALL CD_Validate_Positive('rho_a', rho_a, n_elem, ErrStat, ErrMsg)
    IF (ErrStat /= 0) THEN; ErrStat = CD_DYN_BADINPUT; RETURN; END IF
    CALL CD_Validate_Positive('i_rho_t', i_rho_t, n_elem, ErrStat, ErrMsg)
    IF (ErrStat /= 0) THEN; ErrStat = CD_DYN_BADINPUT; RETURN; END IF
    CALL CD_Validate_Positive('i_rho_n', i_rho_n, n_elem, ErrStat, ErrMsg)
    IF (ErrStat /= 0) THEN; ErrStat = CD_DYN_BADINPUT; RETURN; END IF
    mnode = CD_ZERO; Jref = CD_ZERO
    DO e = 1, n_elem
      CALL CD_Reference_Frame(nodes_ref(:, elem_conn(1, e)), nodes_ref(:, elem_conn(2, e)), Lam0, L0)
      IF (.NOT. (L0 > CD_ZERO) .OR. .NOT. CD_Is_Finite(L0)) THEN
        ErrStat = CD_DYN_BADINPUT; ErrMsg = 'CD_EMC_Reference_Inertia: element span must be finite and positive'; RETURN
      END IF
      w = CD_HALF*L0
      Jp = MATMUL(MATMUL(Lam0, diag3([i_rho_t(e), i_rho_t(e), i_rho_n(e)])), TRANSPOSE(Lam0))
      DO k = 1, 2
        a = elem_conn(k, e)
        mnode(a) = mnode(a) + w*rho_a(e)
        Jref(:, :, a) = Jref(:, :, a) + w*Jp
      END DO
    END DO
  END SUBROUTINE CD_EMC_Reference_Inertia

  SUBROUTINE CD_Cosserat_EMC_Step(nodes_ref, elem_conn, ea, gas, ei, gj, rho_a, i_rho_t, i_rho_n, &
                                  reduced_shear, q, v, f_ext, fixed_dofs, dt, cfg, &
                                  q_new, v_new, converged, n_iter, ErrStat, ErrMsg, analytic_fd_maxdiff)
    !! Advance one step with the energy-conserving scheme. State convention
    !! matches the multiplicative gen-alpha path: v rotational DOFs are the SPATIAL
    !! angular velocity omega. f_ext is the external generalized force (additive-conjugate
    !! for rotations); a constant external force does work consistently through the midpoint.
    !! The Newton tangent is a dense finite-difference Jacobian (dense LU) by default; setting
    !! cfg%emc_analytic_tangent = .TRUE. selects the closed-form consistent tangent, solved with
    !! a banded factorization + Sherman-Morrison rank-1 update (quadratic convergence, same root).
    !! The FD default is bit-for-bit unchanged.
    REAL(wp), INTENT(IN) :: nodes_ref(:, :), ea(:), gas(:), ei(:), gj(:)
    INTEGER, INTENT(IN) :: elem_conn(:, :)
    REAL(wp), INTENT(IN) :: rho_a(:), i_rho_t(:), i_rho_n(:)
    LOGICAL, INTENT(IN) :: reduced_shear
    REAL(wp), INTENT(IN) :: q(:), v(:), f_ext(:)
    INTEGER, INTENT(IN) :: fixed_dofs(:)
    REAL(wp), INTENT(IN) :: dt
    TYPE(GenAlphaConfig), INTENT(IN) :: cfg
    REAL(wp), INTENT(OUT) :: q_new(:), v_new(:)
    LOGICAL, INTENT(OUT) :: converged
    INTEGER, INTENT(OUT) :: n_iter
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    REAL(wp), INTENT(OUT), OPTIONAL :: analytic_fd_maxdiff
      !! diagnostic, meaningful ONLY with cfg%emc_analytic_tangent = .TRUE.: the running
      !! max |J_analytic - J_FD| over the Newton iterations (a central-difference FD Jacobian is
      !! also built each iteration purely to compare -- the in-tree parity oracle, not a solve
      !! path). Stays 0 on the default FD path (no analytic tangent to compare against).
    INTEGER :: n_nodes, ndof, a, nm, it, jcol
    INTEGER :: kd, maxspan, e, ie, je, es2
    REAL(wp), ALLOCATABLE :: mnode(:), Jref(:, :, :)
    REAL(wp), ALLOCATABLE :: P(:), Pn(:), Rvec(:), Rj(:), Ps(:), dP(:), Jac(:, :), Jfd(:, :)
    REAL(wp), ALLOCATABLE :: ab(:, :), uvec(:), vvec(:), yvec(:), zvec(:)
    REAL(wp), ALLOCATABLE :: M3(:, :), Mfull(:, :)
    INTEGER, ALLOCATABLE :: ipiv(:)
    LOGICAL, ALLOCATABLE :: node_fixed(:), dof_fixed(:)
    REAL(wp) :: th(3), om(3), Om0(3), eps, rnorm, r0, denom
    INTEGER :: n3
    LOGICAL :: cmass
    CHARACTER(1024) :: em2
    LOGICAL :: ok

    ErrStat = CD_DYN_OK; ErrMsg = ''; converged = .FALSE.; n_iter = 0
    n_nodes = SIZE(nodes_ref, 2); ndof = 6*n_nodes
    IF (SIZE(q) /= ndof .OR. SIZE(v) /= ndof .OR. SIZE(f_ext) /= ndof .OR. &
        SIZE(q_new) /= ndof .OR. SIZE(v_new) /= ndof) THEN
      ErrStat = CD_DYN_BADINPUT; ErrMsg = 'CD_Cosserat_EMC_Step: q/v/f_ext/outputs must be 6*n_nodes'; RETURN
    END IF
    ! The INTENT(OUT) outputs are now correctly sized; default them to the unadvanced
    ! input state so every subsequent early return (bad input, or a non-converged-but-
    ! non-error step) leaves q_new/v_new defined rather than undefined for the caller.
    q_new = q; v_new = v
    IF (.NOT. CD_Is_Finite(dt) .OR. dt <= CD_ZERO) THEN
      ErrStat = CD_DYN_BADINPUT; ErrMsg = 'CD_Cosserat_EMC_Step: dt must be finite and positive'; RETURN
    END IF
    ! Solver tolerances must be finite-positive and max_iter >= 1, else the
    ! convergence test (rnorm <= rel_tol*r0 / abs_tol) can spuriously accept the
    ! initial iterate -- the same contract the gen-alpha path enforces on its config.
    IF (.NOT. CD_Is_Finite(cfg%rel_tol) .OR. cfg%rel_tol <= CD_ZERO .OR. &
        .NOT. CD_Is_Finite(cfg%abs_tol) .OR. cfg%abs_tol <= CD_ZERO .OR. cfg%max_iter < 1) THEN
      ErrStat = CD_DYN_BADINPUT
      ErrMsg = 'CD_Cosserat_EMC_Step: invalid solver config (rel_tol/abs_tol/max_iter)'
      RETURN
    END IF
    IF (.NOT. CD_All_Finite(q) .OR. .NOT. CD_All_Finite(v) .OR. .NOT. CD_All_Finite(f_ext)) THEN
      ErrStat = CD_DYN_BADINPUT; ErrMsg = 'CD_Cosserat_EMC_Step: q/v/f_ext non-finite'; RETURN
    END IF

    ! Consistent translational mass (opt-in): matches CD_Cosserat_Mechanical_Energy's translational
    ! KE, so the scheme conserves the consistent-mass energy. Formulated with the velocity as the
    ! translational unknown, so both the FD Jacobian and the closed-form tangent apply. This revision
    ! supports free-free meshes only -- reject Dirichlet rather than silently produce a wrong result.
    cmass = cfg%emc_consistent_mass
    IF (cmass .AND. SIZE(fixed_dofs) > 0) THEN
      ErrStat = CD_DYN_BADINPUT
      ErrMsg = 'CD_Cosserat_EMC_Step: emc_consistent_mass supports free-free meshes only (no Dirichlet)'
      RETURN
    END IF

    ! Dirichlet: WHOLE-NODE clamped supports. A fixed node is held at its input position
    ! with zero velocity (a clamp / cantilever root). Every fixed node must carry all 6 of
    ! its DOFs in fixed_dofs; partial-node fixing (a hinge / roller) is rejected, mirroring
    ! the gen-alpha partial-rotational-Dirichlet restriction. Moving supports are a follow-up.
    ALLOCATE (node_fixed(n_nodes), dof_fixed(ndof))
    node_fixed = .FALSE.; dof_fixed = .FALSE.
    DO a = 1, SIZE(fixed_dofs)
      IF (fixed_dofs(a) < 1 .OR. fixed_dofs(a) > ndof) THEN
        ErrStat = CD_DYN_BADINPUT; ErrMsg = 'CD_Cosserat_EMC_Step: fixed DOF index out of range'; RETURN
      END IF
      dof_fixed(fixed_dofs(a)) = .TRUE.
    END DO
    DO a = 1, n_nodes
      IF (ALL(dof_fixed(6*a - 5:6*a))) THEN
        node_fixed(a) = .TRUE.
      ELSE IF (ANY(dof_fixed(6*a - 5:6*a))) THEN
        ErrStat = CD_DYN_BADINPUT
        ErrMsg = 'CD_Cosserat_EMC_Step: whole-node clamps only (all 6 node DOFs); partial-node fixing rejected'
        RETURN
      END IF
    END DO

    nm = 6*n_nodes; n3 = 3*n_nodes
    ALLOCATE (mnode(n_nodes), Jref(3, 3, n_nodes))
    CALL CD_EMC_Reference_Inertia(nodes_ref, elem_conn, rho_a, i_rho_t, i_rho_n, mnode, Jref, ErrStat, ErrMsg)
    IF (ErrStat /= CD_DYN_OK) RETURN

    IF (cmass) THEN
      ! Consistent translational mass, velocity formulation: the translational unknown is the
      ! velocity w = v_{n+1}, the momentum balance is M3 (w - v_n) + dt*f = 0, and the midpoint
      ! displacement dr = dt*(v_n + w)/2 is per-node -- so NO M3^-1 solve is needed, only the
      ! banded matvec M3 (w - v_n). Assemble the full consistent mass and keep the dense 3N
      ! translational block M3 for that matvec and the analytic tangent's trans-trans block.
      ! (The dense full-mass assembly is transient; a direct banded M3 assembler + banded matvec
      ! is a follow-up for very long lines.)
      ALLOCATE (Mfull(nm, nm), M3(n3, n3))
      CALL CD_Assemble_Cosserat_Mass(nodes_ref, elem_conn, rho_a, i_rho_t, i_rho_n, Mfull, es2, em2)
      IF (es2 /= 0) THEN
        ErrStat = CD_DYN_BADINPUT; ErrMsg = 'CD_Cosserat_EMC_Step: consistent mass assembly: '//TRIM(em2); RETURN
      END IF
      DO a = 1, n_nodes
        DO e = 1, n_nodes
          M3(3*a - 2:3*a, 3*e - 2:3*e) = Mfull(6*a - 5:6*a - 3, 6*e - 5:6*e - 3)
        END DO
      END DO
      DEALLOCATE (Mfull)
    END IF

    ALLOCATE (P(nm), Pn(nm), Rvec(nm), Rj(nm), Ps(nm), dP(nm), Jac(nm, nm))
    ! pack current state: translational slot = m_a v_trans (lumped momentum) or v_trans (consistent
    ! velocity unknown, init = v_n); rotational slot = pi_a = J_ref,a Omega_a, Omega = exp(theta)^T omega
    DO a = 1, n_nodes
      th = q(6*a - 2:6*a); om = v(6*a - 2:6*a)
      Om0 = MATMUL(TRANSPOSE(CD_Exp_SO3(th)), om)
      IF (cmass) THEN
        Pn(6*a - 5:6*a - 3) = v(6*a - 5:6*a - 3)
      ELSE
        Pn(6*a - 5:6*a - 3) = mnode(a)*v(6*a - 5:6*a - 3)
      END IF
      Pn(6*a - 2:6*a) = MATMUL(Jref(:, :, a), Om0)
      IF (node_fixed(a)) Pn(6*a - 5:6*a) = CD_ZERO   ! clamped support: held at rest
    END DO
    P = Pn
    IF (PRESENT(analytic_fd_maxdiff)) THEN
      analytic_fd_maxdiff = CD_ZERO
      ALLOCATE (Jfd(nm, nm))
    END IF
    ! Banded/Sherman-Morrison workspace for the analytic-tangent solve: the consistent tangent
    ! is J = B + dt*dq (x) dcorr with B block-banded (the element coupling) and a single dense
    ! rank-1 (the Gonzalez correction), solved with one banded factorization + Sherman-Morrison.
    ! Half-bandwidth from the actual connectivity (6*maxspan+5; = 11 for a sequential chain), so a
    ! non-chain mesh is handled correctly. The nm-length SM vectors are allocated unconditionally
    ! (negligible, and so the analytic-tangent call always has defined actual arguments -- the
    ! compiler cannot prove a conditional allocatable is set at the call site); the O(nm*bandwidth)
    ! band matrix `ab` and its pivots are allocated ONLY on the analytic path (they can be ~3*nm^2
    ! for a large node-index span, so the default FD path must not pay for them).
    ALLOCATE (uvec(nm), vvec(nm), yvec(nm), zvec(nm))
    kd = 0
    IF (cfg%emc_analytic_tangent) THEN
      maxspan = 1
      DO e = 1, SIZE(elem_conn, 2)
        maxspan = MAX(maxspan, ABS(elem_conn(1, e) - elem_conn(2, e)))
      END DO
      kd = MIN(6*maxspan + 5, nm - 1)
      ALLOCATE (ab(2*kd + kd + 1, nm), ipiv(nm))
    END IF

    ! Newton on the momentum-balance residual
    r0 = CD_ONE
    DO it = 1, cfg%max_iter
      n_iter = it
      CALL emc_residual(P, ok, Rvec)
      IF (.NOT. ok) THEN
        ErrStat = CD_DYN_BADINPUT; ErrMsg = 'CD_Cosserat_EMC_Step: residual evaluation left the rotation chart'; RETURN
      END IF
      rnorm = MAXVAL(ABS(Rvec))
      ! A non-finite residual (a diverged iterate) would slip through the tolerance
      ! comparisons below -- every `NaN <= x` is .FALSE. -- and then corrupt the FD
      ! Jacobian. Fail closed instead.
      IF (.NOT. CD_Is_Finite(rnorm)) THEN
        ErrStat = CD_DYN_SINGULAR; ErrMsg = 'CD_Cosserat_EMC_Step: non-finite residual (diverged)'; RETURN
      END IF
      IF (it == 1) r0 = MAX(rnorm, cfg%abs_tol)
      IF (rnorm <= cfg%abs_tol .OR. rnorm <= cfg%rel_tol*r0) THEN
        converged = .TRUE.; EXIT
      END IF
      IF (cfg%emc_analytic_tangent) THEN
        ! closed-form consistent tangent + banded/Sherman-Morrison solve (quadratic convergence)
        CALL emc_analytic_jacobian(P, Jac, uvec, vvec, ok)
        IF (.NOT. ok) THEN
          ErrStat = CD_DYN_BADINPUT; ErrMsg = 'CD_Cosserat_EMC_Step: analytic tangent left the rotation chart'; RETURN
        END IF
        IF (PRESENT(analytic_fd_maxdiff)) THEN
          ! diagnostic: CENTRAL-difference FD tangent at the same iterate vs the analytic one.
          ! dP is reused as scratch for the minus-side residual (it is overwritten by the solve).
          eps = 1.0e-6_wp
          DO jcol = 1, nm
            Ps = P; Ps(jcol) = Ps(jcol) + eps
            CALL emc_residual(Ps, ok, Rj)
            IF (.NOT. ok) THEN
              ErrStat = CD_DYN_BADINPUT
              ErrMsg = 'CD_Cosserat_EMC_Step: FD parity probe left the rotation chart'
              RETURN
            END IF
            Ps = P; Ps(jcol) = Ps(jcol) - eps
            CALL emc_residual(Ps, ok, dP)
            IF (.NOT. ok) THEN
              ErrStat = CD_DYN_BADINPUT
              ErrMsg = 'CD_Cosserat_EMC_Step: FD parity probe left the rotation chart'
              RETURN
            END IF
            Jfd(:, jcol) = (Rj - dP)/(2.0_wp*eps)
          END DO
          analytic_fd_maxdiff = MAX(analytic_fd_maxdiff, MAXVAL(ABS(Jac - Jfd)))
        END IF
        IF (.NOT. CD_All_Finite(Jac) .OR. .NOT. CD_All_Finite(uvec) &
            .OR. .NOT. CD_All_Finite(vvec)) THEN
          ErrStat = CD_DYN_SINGULAR; ErrMsg = 'CD_Cosserat_EMC_Step: non-finite Newton tangent'; RETURN
        END IF
        ! B = J - dt*dq (x) dcorr is banded (element coupling); solve (B + uvec vvec^T) dP = -Rvec
        ! by one banded factorization + Sherman-Morrison for the rank-1 Gonzalez correction.
        ab = CD_ZERO
        DO je = 1, nm
          DO ie = MAX(1, je - kd), MIN(nm, je + kd)
            ab(2*kd + 1 + ie - je, je) = Jac(ie, je) - uvec(ie)*vvec(je)
          END DO
        END DO
        CALL CD_Factor_Banded(ab, kd, kd, ipiv, es2, em2)
        IF (es2 /= CD_LINALG_OK) THEN
          ErrStat = CD_DYN_SINGULAR; ErrMsg = 'CD_Cosserat_EMC_Step: '//TRIM(em2); RETURN
        END IF
        yvec = -Rvec
        CALL CD_Solve_Factored_Banded(ab, kd, kd, ipiv, yvec, es2, em2)
        IF (es2 /= CD_LINALG_OK) THEN
          ErrStat = CD_DYN_SINGULAR; ErrMsg = 'CD_Cosserat_EMC_Step: '//TRIM(em2); RETURN
        END IF
        zvec = uvec
        CALL CD_Solve_Factored_Banded(ab, kd, kd, ipiv, zvec, es2, em2)
        IF (es2 /= CD_LINALG_OK) THEN
          ErrStat = CD_DYN_SINGULAR; ErrMsg = 'CD_Cosserat_EMC_Step: '//TRIM(em2); RETURN
        END IF
        denom = CD_ONE + DOT_PRODUCT(vvec, zvec)
        IF (.NOT. CD_Is_Finite(denom) .OR. ABS(denom) < 1.0e-12_wp) THEN
          ErrStat = CD_DYN_SINGULAR
          ErrMsg = 'CD_Cosserat_EMC_Step: Sherman-Morrison breakdown (rank-1 update singular)'; RETURN
        END IF
        dP = yvec - zvec*(DOT_PRODUCT(vvec, yvec)/denom)
        IF (.NOT. CD_All_Finite(dP)) THEN
          ErrStat = CD_DYN_SINGULAR; ErrMsg = 'CD_Cosserat_EMC_Step: non-finite Newton step'; RETURN
        END IF
      ELSE
        ! dense finite-difference Jacobian + dense solve (default)
        eps = 1.0e-7_wp
        DO jcol = 1, nm
          Ps = P; Ps(jcol) = Ps(jcol) + eps
          CALL emc_residual(Ps, ok, Rj)
          IF (.NOT. ok) THEN
            ErrStat = CD_DYN_BADINPUT; ErrMsg = 'CD_Cosserat_EMC_Step: Jacobian probe left the rotation chart'; RETURN
          END IF
          Jac(:, jcol) = (Rj - Rvec)/eps
        END DO
        ! A non-finite Jacobian entry would defeat solve_dense's pivot test (NaN comparisons
        ! are .FALSE.), so a bogus dP would be committed; reject it up front.
        IF (.NOT. CD_All_Finite(Jac)) THEN
          ErrStat = CD_DYN_SINGULAR; ErrMsg = 'CD_Cosserat_EMC_Step: non-finite Newton tangent'; RETURN
        END IF
        CALL solve_dense(Jac, -Rvec, dP, ok)
        IF (.NOT. ok .OR. .NOT. CD_All_Finite(dP)) THEN
          ErrStat = CD_DYN_SINGULAR; ErrMsg = 'CD_Cosserat_EMC_Step: singular or non-finite Newton step'; RETURN
        END IF
      END IF
      P = P + dP
    END DO
    IF (.NOT. converged) THEN
      ! Non-convergence is reported via `converged`, not an error code; q_new/v_new were
      ! defaulted to the unadvanced input state above (the step did not commit).
      ErrStat = CD_DYN_OK
      RETURN
    END IF

    ! commit: reconstruct q_new, v_new from the converged momenta
    CALL emc_reconstruct(P, q_new, v_new, ok)
    IF (.NOT. ok) THEN
      ! a rotational inertia solve failed at commit -- restore the unadvanced state so the
      ! caller does not receive a half-written configuration, and report the failure.
      q_new = q; v_new = v; converged = .FALSE.
      ErrStat = CD_DYN_SINGULAR; ErrMsg = 'CD_Cosserat_EMC_Step: singular reference inertia at reconstruction'
      RETURN
    END IF
  CONTAINS

    SUBROUTINE emc_analytic_jacobian(Ptry, Jout, uout, vout, okout)
      !! Closed-form consistent Newton tangent dR/dP (checked against finite differences).
      !! J = I - dt*Jgyro + dt*(Jforce + Jcorr). Fixed (clamped) nodes have zero increment
      !! sensitivity and a pure identity (constraint) row, matching emc_residual.
      !! The dense Jout carries the full tangent; the Gonzalez correction's dense part is the
      !! single rank-1 outer(uout, vout) = outer(dt*dq, dcorr) (uout/vout returned so the caller
      !! can peel it off for a banded + Sherman-Morrison solve). uout/vout are zero at fixed DOFs.
      REAL(wp), INTENT(IN) :: Ptry(:)
      REAL(wp), INTENT(OUT) :: Jout(:, :), uout(:), vout(:)
      LOGICAL, INTENT(OUT) :: okout
      REAL(wp) :: qn(ndof), qh(ndof), q1(ndof), dq(ndof), fmid(ndof), fint1(ndof)
      REAL(wp) :: ftr(3, n_nodes), frt(3, n_nodes)
      REAL(wp) :: Gm(6, 6, n_nodes), Gd(6, 6, n_nodes), G1(6, 6, n_nodes)
      REAL(wp) :: Di(3, 3, n_nodes), Tdev(3, 3, n_nodes), Jinv(3, 3, n_nodes)
      REAL(wp) :: dcorr(ndof), dW1(ndof), dWl(ndof), ddq2(ndof)
      REAL(wp), ALLOCATABLE :: Kt(:, :)
      REAL(wp) :: ph(3), pih(3), Oh(3), psi(3), dr(3), thn(3), thh(3), Rdn(3, 3), ejw(3)
      REAL(wp) :: Wn, W1, dWlin, dq2, corr, KG(6, 6), blk(6, 6), Gg(3, 3), I3(3, 3), I6(6, 6)
      INTEGER :: a, c, jj, es, k
      CHARACTER(1024) :: em
      okout = .TRUE.; I3 = diag3([CD_ONE, CD_ONE, CD_ONE])
      I6 = CD_ZERO
      DO k = 1, 6
        I6(k, k) = CD_ONE
      END DO
      ALLOCATE (Kt(ndof, ndof))
      ! configs from the trial momenta (matches emc_residual exactly)
      DO a = 1, n_nodes
        ph = CD_HALF*(Pn(6*a - 5:6*a - 3) + Ptry(6*a - 5:6*a - 3))
        pih = CD_HALF*(Pn(6*a - 2:6*a) + Ptry(6*a - 2:6*a))
        Jinv(:, :, a) = minv3(Jref(:, :, a))
        Oh = MATMUL(Jinv(:, :, a), pih); psi = dt*Oh
        IF (cmass) THEN; dr = dt*ph; ELSE; dr = dt*ph/mnode(a); END IF
        IF (node_fixed(a)) THEN; psi = CD_ZERO; dr = CD_ZERO; END IF
        thn = q(6*a - 2:6*a); Rdn = CD_Exp_SO3(thn)
        qn(6*a - 5:6*a - 3) = q(6*a - 5:6*a - 3); qn(6*a - 2:6*a) = thn
        qh(6*a - 5:6*a - 3) = q(6*a - 5:6*a - 3) + CD_HALF*dr
        qh(6*a - 2:6*a) = CD_Log_SO3(MATMUL(Rdn, cayley(CD_HALF*psi)))
        q1(6*a - 5:6*a - 3) = q(6*a - 5:6*a - 3) + dr
        q1(6*a - 2:6*a) = CD_Log_SO3(MATMUL(Rdn, cayley(psi)))
        dq(6*a - 5:6*a - 3) = dr; dq(6*a - 2:6*a) = psi
      END DO
      CALL CD_Assemble_Cosserat_Tangent_Force(nodes_ref, elem_conn, ea, gas, ei, gj, qh, reduced_shear, &
                                              Kt, fmid, es, em)
      IF (es /= 0) THEN; okout = .FALSE.; RETURN; END IF
      CALL CD_Assemble_Cosserat_Internal_Force(nodes_ref, elem_conn, ea, gas, ei, gj, q1, reduced_shear, fint1, es, em)
      IF (es /= 0) THEN; okout = .FALSE.; RETURN; END IF
      DO a = 1, n_nodes
        ftr(:, a) = fmid(6*a - 5:6*a - 3); frt(:, a) = MATMUL(CD_Dexp_Inv_SO3(qh(6*a - 2:6*a)), fmid(6*a - 2:6*a))
        pih = CD_HALF*(Pn(6*a - 2:6*a) + Ptry(6*a - 2:6*a)); psi = dt*MATMUL(Jinv(:, :, a), pih)
        thh = qh(6*a - 2:6*a); thn = q(6*a - 2:6*a)
        Gm(:, :, a) = CD_ZERO; Gd(:, :, a) = CD_ZERO; G1(:, :, a) = CD_ZERO
        IF (.NOT. node_fixed(a)) THEN
          ! translational config sensitivity d(dr)/d(trans unknown): consistent (velocity, w) drops
          ! the mass -- the mass sits in the M3 identity block below; lumped (momentum, p) keeps 1/m.
          IF (cmass) THEN
            Gm(1:3, 1:3, a) = (dt/4.0_wp)*I3
            Gd(1:3, 1:3, a) = (dt/2.0_wp)*I3
            G1(1:3, 1:3, a) = (dt/2.0_wp)*I3
          ELSE
            Gm(1:3, 1:3, a) = (dt/(4.0_wp*mnode(a)))*I3
            Gd(1:3, 1:3, a) = (dt/(2.0_wp*mnode(a)))*I3
            G1(1:3, 1:3, a) = (dt/(2.0_wp*mnode(a)))*I3
          END IF
          Gm(4:6, 4:6, a) = MATMUL(dth_dpsi(thn, psi, CD_HALF), (dt*CD_HALF)*Jinv(:, :, a))
          Gd(4:6, 4:6, a) = (dt*CD_HALF)*Jinv(:, :, a)
          G1(4:6, 4:6, a) = MATMUL(dth_dpsi(thn, psi, CD_ONE), (dt*CD_HALF)*Jinv(:, :, a))
        END IF
        Di(:, :, a) = CD_Dexp_Inv_SO3(thh)
        ! Tdev = d(dexp_inv(qh_rot) . fmid_rot)/d(qh_rot): the ELASTIC transform derivative only.
        ! It feeds both the residual force block AND dWl (d(dWlin)/dP), and dWlin is elastic; the
        ! external-load transform (-f_ext_rot) is added separately to the force block below.
        DO jj = 1, 3
          ejw = CD_ZERO; ejw(jj) = CD_ONE
          Tdev(:, jj, a) = MATMUL(-MATMUL(Di(:, :, a), MATMUL(CD_Dexp_Dir_SO3(thh, ejw), Di(:, :, a))), &
                                  fmid(6*a - 2:6*a))
        END DO
      END DO
      ! force tangent Jforce = d(force_term)/dP -> into Jout (no dt yet)
      Jout = CD_ZERO
      DO a = 1, n_nodes
        DO c = 1, n_nodes
          KG = MATMUL(Kt(6*a - 5:6*a, 6*c - 5:6*c), Gm(:, :, c))
          blk(1:3, :) = KG(1:3, :); blk(4:6, :) = MATMUL(Di(:, :, a), KG(4:6, :))
          IF (c == a) blk(4:6, 4:6) = blk(4:6, 4:6) + MATMUL(Tdev(:, :, a), Gm(4:6, 4:6, a))
          Jout(6*a - 5:6*a, 6*c - 5:6*c) = blk
        END DO
      END DO
      ! Gonzalez scalar corr and its gradient d(corr)/dP
      CALL strain_energy(qn, Wn, okout); IF (.NOT. okout) RETURN
      CALL strain_energy(q1, W1, okout); IF (.NOT. okout) RETURN
      dWlin = CD_ZERO; dq2 = CD_ZERO
      DO a = 1, n_nodes
        dWlin = dWlin + DOT_PRODUCT(ftr(:, a), dq(6*a - 5:6*a - 3)) + DOT_PRODUCT(frt(:, a), dq(6*a - 2:6*a))
        dq2 = dq2 + DOT_PRODUCT(dq(6*a - 5:6*a), dq(6*a - 5:6*a))
      END DO
      corr = CD_ZERO; IF (dq2 > 1.0e-28_wp) corr = (W1 - Wn - dWlin)/dq2
      dW1 = CD_ZERO; ddq2 = CD_ZERO; dWl = CD_ZERO
      DO a = 1, n_nodes
        dW1(6*a - 5:6*a) = MATMUL(fint1(6*a - 5:6*a), G1(:, :, a))
        ddq2(6*a - 5:6*a) = 2.0_wp*MATMUL(dq(6*a - 5:6*a), Gd(:, :, a))
        dWl(6*a - 5:6*a) = MATMUL([ftr(:, a), frt(:, a)], Gd(:, :, a))   ! node-local d(dWlin)/dP
      END DO
      ! global coupling sum_a dq_a^T Jforce[a,:] -- a SEPARATE loop: it writes every block, so
      ! folding it into the loop above would let a later node's local assignment overwrite it.
      DO a = 1, n_nodes
        dWl = dWl + MATMUL(dq(6*a - 5:6*a), Jout(6*a - 5:6*a, :))
      END DO
      dcorr = CD_ZERO
      IF (dq2 > 1.0e-28_wp) dcorr = (dW1 - dWl - corr*ddq2)/dq2
      ! Sherman-Morrison vectors: the full Gonzalez rank-1 across all nodes is dt*dq (x) dcorr.
      uout = dt*dq; vout = dcorr
      ! assemble the full residual tangent J = I - dt*Jgyro + dt*(Jforce + Jcorr)
      DO a = 1, n_nodes
        Jout(6*a - 5:6*a, :) = dt*Jout(6*a - 5:6*a, :)                              ! dt * force tangent
        Jout(6*a - 5:6*a, 6*a - 5:6*a) = Jout(6*a - 5:6*a, 6*a - 5:6*a) + dt*corr*Gd(:, :, a)  ! Gonzalez block
        Jout(6*a - 5:6*a, :) = Jout(6*a - 5:6*a, :) + dt*outer(dq(6*a - 5:6*a), dcorr)          ! Gonzalez rank-1
        ! external-load transform: d(-dt*dexp_inv(qh_rot).f_ext_rot)/dP = -dt*Tf.d(qh_rot)/dP,
        ! Tf[:,j] = -Di*dexp_dir(qh_rot,e_j)*Di*f_ext_rot; d(qh_rot)/dP = Gm(4:6,4:6,a).
        thh = qh(6*a - 2:6*a)
        DO jj = 1, 3
          ejw = CD_ZERO; ejw(jj) = CD_ONE
          Tdev(:, jj, a) = MATMUL(-MATMUL(Di(:, :, a), MATMUL(CD_Dexp_Dir_SO3(thh, ejw), Di(:, :, a))), &
                                  f_ext(6*a - 2:6*a))
        END DO
        Jout(6*a - 2:6*a, 6*a - 2:6*a) = Jout(6*a - 2:6*a, 6*a - 2:6*a) - dt*MATMUL(Tdev(:, :, a), Gm(4:6, 4:6, a))
        pih = CD_HALF*(Pn(6*a - 2:6*a) + Ptry(6*a - 2:6*a)); Oh = MATMUL(Jinv(:, :, a), pih)
        Gg = CD_HALF*(MATMUL(CD_Hat(pih), Jinv(:, :, a)) - CD_Hat(Oh))
        Jout(6*a - 2:6*a, 6*a - 2:6*a) = Jout(6*a - 2:6*a, 6*a - 2:6*a) - dt*Gg     ! - dt * gyro tangent
      END DO
      IF (cmass) THEN
        ! velocity: the translational "identity" is d(M3(w-vn))/dw = M3; rotational is +1 on pi
        DO a = 1, n_nodes
          DO c = 1, n_nodes
            Jout(6*a - 5:6*a - 3, 6*c - 5:6*c - 3) = Jout(6*a - 5:6*a - 3, 6*c - 5:6*c - 3) &
                                                     + M3(3*a - 2:3*a, 3*c - 2:3*c)
          END DO
          Jout(6*a - 2, 6*a - 2) = Jout(6*a - 2, 6*a - 2) + CD_ONE
          Jout(6*a - 1, 6*a - 1) = Jout(6*a - 1, 6*a - 1) + CD_ONE
          Jout(6*a, 6*a) = Jout(6*a, 6*a) + CD_ONE
        END DO
      ELSE
        DO k = 1, ndof
          Jout(k, k) = Jout(k, k) + CD_ONE                                          ! identity
        END DO
      END IF
      ! Dirichlet: a clamped node's row is the constraint P->0 (dR/dP = I on its block only)
      DO a = 1, n_nodes
        IF (node_fixed(a)) THEN
          Jout(6*a - 5:6*a, :) = CD_ZERO
          Jout(6*a - 5:6*a, 6*a - 5:6*a) = I6
        END IF
      END DO
    END SUBROUTINE emc_analytic_jacobian

    SUBROUTINE emc_residual(Ptry, okout, Rout)
      REAL(wp), INTENT(IN) :: Ptry(:)
      LOGICAL, INTENT(OUT) :: okout
      REAL(wp), INTENT(OUT) :: Rout(:)
      REAL(wp) :: ph(3), pih(3), Oh(3), psi(3), dr(3)
      REAL(wp) :: rn(3), r1(3), thn(3), th1(3), thh(3), Rdn(3, 3), Rd1(3, 3), Rdh(3, 3)
      REAL(wp) :: qn(ndof), q1(ndof), qh(ndof), fmid(ndof), Wn, W1, dWlin, dq2, corr
      REAL(wp) :: ftr(3, n_nodes), frt(3, n_nodes), drn(3, n_nodes), psin(3, n_nodes)
      REAL(wp) :: dw3(n3), mdw(n3)
      INTEGER :: b, es
      LOGICAL :: okl
      CHARACTER(1024) :: em
      okout = .TRUE.
      ! velocity translational momentum balance uses M3 (w - v_n): assemble the increment matvec
      IF (cmass) THEN
        DO b = 1, n_nodes
          dw3(3*b - 2:3*b) = Ptry(6*b - 5:6*b - 3) - Pn(6*b - 5:6*b - 3)
        END DO
        mdw = MATMUL(M3, dw3)
      END IF
      ! build n, n+1, midpoint configs from the trial state
      DO b = 1, n_nodes
        ph = CD_HALF*(Pn(6*b - 5:6*b - 3) + Ptry(6*b - 5:6*b - 3))
        pih = CD_HALF*(Pn(6*b - 2:6*b) + Ptry(6*b - 2:6*b))
        Oh = solve3(Jref(:, :, b), pih, okl)
        IF (.NOT. okl) THEN; okout = .FALSE.; RETURN; END IF
        psi = dt*Oh
        IF (cmass) THEN
          dr = dt*ph          ! velocity: dr = dt*(v_n + w)/2 (ph is the velocity midpoint)
        ELSE
          dr = dt*ph/mnode(b)
        END IF
        IF (node_fixed(b)) THEN; psi = CD_ZERO; dr = CD_ZERO; END IF   ! clamped: config held
        rn = q(6*b - 5:6*b - 3); thn = q(6*b - 2:6*b)
        Rdn = CD_Exp_SO3(thn)
        Rd1 = MATMUL(Rdn, cayley(psi)); Rdh = MATMUL(Rdn, cayley(CD_HALF*psi))
        r1 = rn + dr
        th1 = CD_Log_SO3(Rd1); thh = CD_Log_SO3(Rdh)
        qn(6*b - 5:6*b - 3) = rn; qn(6*b - 2:6*b) = thn
        q1(6*b - 5:6*b - 3) = r1; q1(6*b - 2:6*b) = th1
        qh(6*b - 5:6*b - 3) = rn + CD_HALF*dr; qh(6*b - 2:6*b) = thh
        drn(:, b) = dr; psin(:, b) = psi
      END DO
      ! midpoint internal force -> (translation, body-rot-increment) convention
      CALL CD_Assemble_Cosserat_Internal_Force(nodes_ref, elem_conn, ea, gas, ei, gj, qh, reduced_shear, fmid, es, em)
      IF (es /= 0) THEN; okout = .FALSE.; RETURN; END IF
      DO b = 1, n_nodes
        ftr(:, b) = fmid(6*b - 5:6*b - 3)
        frt(:, b) = MATMUL(CD_Dexp_Inv_SO3(qh(6*b - 2:6*b)), fmid(6*b - 2:6*b))
      END DO
      ! Gonzalez correction so the algorithmic force does work == strain-energy change.
      ! Fail closed if either endpoint leaves the rotation-domain contract (the energy
      ! routine then zeroes W and flags it) -- a zeroed W would otherwise feed a spurious
      ! finite residual for an invalid near-chart step.
      CALL strain_energy(qn, Wn, okout); IF (.NOT. okout) RETURN
      CALL strain_energy(q1, W1, okout); IF (.NOT. okout) RETURN
      dWlin = CD_ZERO; dq2 = CD_ZERO
      DO b = 1, n_nodes
        dWlin = dWlin + DOT_PRODUCT(ftr(:, b), drn(:, b)) + DOT_PRODUCT(frt(:, b), psin(:, b))
        dq2 = dq2 + DOT_PRODUCT(drn(:, b), drn(:, b)) + DOT_PRODUCT(psin(:, b), psin(:, b))
      END DO
      corr = CD_ZERO
      IF (dq2 > 1.0e-28_wp) corr = (W1 - Wn - dWlin)/dq2
      ! residuals: linear- and body-angular-momentum balance (external force at the midpoint)
      DO b = 1, n_nodes
        IF (node_fixed(b)) THEN
          ! clamped support: replace the momentum balance with the constraint P -> 0
          ! (the node is held at rest); its elastic force is the implicit reaction.
          Rout(6*b - 5:6*b) = Ptry(6*b - 5:6*b)
          CYCLE
        END IF
        ph = CD_HALF*(Pn(6*b - 5:6*b - 3) + Ptry(6*b - 5:6*b - 3))
        pih = CD_HALF*(Pn(6*b - 2:6*b) + Ptry(6*b - 2:6*b))
        Oh = solve3(Jref(:, :, b), pih, okl)
        IF (.NOT. okl) THEN; okout = .FALSE.; RETURN; END IF
        ! external load: translation direct; rotation mapped additive->body-increment
        ! (same dexp_inv(theta) transform as the internal force), so f_ext is the
        ! additive-conjugate generalized force the gen-alpha path also consumes.
        IF (cmass) THEN
          Rout(6*b - 5:6*b - 3) = mdw(3*b - 2:3*b) &
                                  + dt*(ftr(:, b) + corr*drn(:, b)) - dt*f_ext(6*b - 5:6*b - 3)
        ELSE
          Rout(6*b - 5:6*b - 3) = Ptry(6*b - 5:6*b - 3) - Pn(6*b - 5:6*b - 3) &
                                  + dt*(ftr(:, b) + corr*drn(:, b)) - dt*f_ext(6*b - 5:6*b - 3)
        END IF
        Rout(6*b - 2:6*b) = Ptry(6*b - 2:6*b) - Pn(6*b - 2:6*b) - dt*cross(pih, Oh) &
                            + dt*(frt(:, b) + corr*psin(:, b)) &
                            - dt*MATMUL(CD_Dexp_Inv_SO3(qh(6*b - 2:6*b)), f_ext(6*b - 2:6*b))
      END DO
    END SUBROUTINE emc_residual

    SUBROUTINE emc_reconstruct(Pfin, qo, vo, okr)
      REAL(wp), INTENT(IN) :: Pfin(:)
      REAL(wp), INTENT(OUT) :: qo(:), vo(:)
      LOGICAL, INTENT(OUT) :: okr
      REAL(wp) :: ph(3), pih(3), Oh(3), psi(3), thn(3), Rd1(3, 3), th1(3), Om1(3)
      LOGICAL :: ok1, ok2
      INTEGER :: b
      ! Jref is SPD (validated finite-positive in CD_EMC_Reference_Inertia) and these are
      ! the converged momenta, so the 3x3 inertia solves succeed in practice; still, do not
      ! silently commit a zeroed rotational state if one fails -- report it to the caller.
      okr = .TRUE.
      ! velocity formulation (consistent mass): the reconstructed velocity is the converged unknown
      ! w = Pfin_trans directly, and the displacement is the per-node midpoint dr = dt*(v_n + w)/2 --
      ! no M3^-1 solve. Free-free only, so no clamped nodes.
      DO b = 1, n_nodes
        IF (node_fixed(b)) THEN
          ! clamped support: held exactly at its input position with zero velocity
          qo(6*b - 5:6*b) = q(6*b - 5:6*b); vo(6*b - 5:6*b) = CD_ZERO
          CYCLE
        END IF
        ph = CD_HALF*(Pn(6*b - 5:6*b - 3) + Pfin(6*b - 5:6*b - 3))
        pih = CD_HALF*(Pn(6*b - 2:6*b) + Pfin(6*b - 2:6*b))
        Oh = solve3(Jref(:, :, b), pih, ok1)
        Om1 = solve3(Jref(:, :, b), Pfin(6*b - 2:6*b), ok2)
        IF (.NOT. (ok1 .AND. ok2)) THEN; okr = .FALSE.; RETURN; END IF
        psi = dt*Oh; thn = q(6*b - 2:6*b)
        Rd1 = MATMUL(CD_Exp_SO3(thn), cayley(psi))
        th1 = CD_Log_SO3(Rd1)
        IF (cmass) THEN
          qo(6*b - 5:6*b - 3) = q(6*b - 5:6*b - 3) + dt*ph   ! dr = dt*(v_n + w)/2
        ELSE
          qo(6*b - 5:6*b - 3) = q(6*b - 5:6*b - 3) + dt*ph/mnode(b)
        END IF
        qo(6*b - 2:6*b) = th1
        ! omega_{n+1} = exp(theta_{n+1}) Omega_{n+1}, Omega = J^{-1} pi
        IF (cmass) THEN
          vo(6*b - 5:6*b - 3) = Pfin(6*b - 5:6*b - 3)   ! velocity unknown w
        ELSE
          vo(6*b - 5:6*b - 3) = Pfin(6*b - 5:6*b - 3)/mnode(b)
        END IF
        vo(6*b - 2:6*b) = MATMUL(CD_Exp_SO3(th1), Om1)
      END DO
    END SUBROUTINE emc_reconstruct

    SUBROUTINE strain_energy(qq, W, okout)
      REAL(wp), INTENT(IN) :: qq(:)
      REAL(wp), INTENT(OUT) :: W
      LOGICAL, INTENT(INOUT) :: okout
      REAL(wp) :: se, ke, vv(ndof)
      INTEGER :: es
      CHARACTER(1024) :: em
      vv = CD_ZERO
      CALL CD_Cosserat_Mechanical_Energy(nodes_ref, elem_conn, ea, gas, ei, gj, rho_a, i_rho_t, i_rho_n, &
                                         reduced_shear, qq, vv, se, ke, es, em, multiplicative=.TRUE.)
      IF (es /= CD_DYN_OK) THEN; okout = .FALSE.; W = CD_ZERO; RETURN; END IF
      W = se
    END SUBROUTINE strain_energy

  END SUBROUTINE CD_Cosserat_EMC_Step

  ! ---- small local linear-algebra / SO(3) helpers ----

  PURE FUNCTION diag3(d) RESULT(M)
    REAL(wp), INTENT(IN) :: d(3)
    REAL(wp) :: M(3, 3)
    M = CD_ZERO; M(1, 1) = d(1); M(2, 2) = d(2); M(3, 3) = d(3)
  END FUNCTION diag3

  PURE FUNCTION cross(a, b) RESULT(c)
    REAL(wp), INTENT(IN) :: a(3), b(3)
    REAL(wp) :: c(3)
    c = [a(2)*b(3) - a(3)*b(2), a(3)*b(1) - a(1)*b(3), a(1)*b(2) - a(2)*b(1)]
  END FUNCTION cross

  FUNCTION cayley(phi) RESULT(R)
    !! Cayley map cay(phi_hat) = (I - 1/2 phi_hat)^{-1} (I + 1/2 phi_hat) in SO(3).
    REAL(wp), INTENT(IN) :: phi(3)
    REAL(wp) :: R(3, 3), H(3, 3), A(3, 3), B(3, 3), I3(3, 3)
    LOGICAL :: ok
    INTEGER :: j
    I3 = diag3([CD_ONE, CD_ONE, CD_ONE]); H = CD_Hat(phi)
    A = I3 - CD_HALF*H; B = I3 + CD_HALF*H
    DO j = 1, 3
      R(:, j) = solve3(A, B(:, j), ok)
    END DO
  END FUNCTION cayley

  FUNCTION solve3(A, b, ok) RESULT(x)
    REAL(wp), INTENT(IN) :: A(3, 3), b(3)
    LOGICAL, INTENT(OUT) :: ok
    REAL(wp) :: x(3), d
    d = det3(A)
    ok = ABS(d) > TINY(CD_ONE)*1.0e3_wp
    IF (.NOT. ok) THEN; x = CD_ZERO; RETURN; END IF
    x(1) = det3(repl(A, 1, b))/d; x(2) = det3(repl(A, 2, b))/d; x(3) = det3(repl(A, 3, b))/d
  END FUNCTION solve3

  ! ---- helpers for the closed-form consistent tangent (checked against finite differences) ----

  PURE FUNCTION minv3(M) RESULT(Mi)
    !! 3x3 inverse via adjugate/det (Mi entries are the adjugate directly; no transpose).
    REAL(wp), INTENT(IN) :: M(3, 3)
    REAL(wp) :: Mi(3, 3), d
    d = det3(M)
    Mi(1, 1) = (M(2, 2)*M(3, 3) - M(2, 3)*M(3, 2)); Mi(1, 2) = -(M(1, 2)*M(3, 3) - M(1, 3)*M(3, 2))
    Mi(1, 3) = (M(1, 2)*M(2, 3) - M(1, 3)*M(2, 2)); Mi(2, 1) = -(M(2, 1)*M(3, 3) - M(2, 3)*M(3, 1))
    Mi(2, 2) = (M(1, 1)*M(3, 3) - M(1, 3)*M(3, 1)); Mi(2, 3) = -(M(1, 1)*M(2, 3) - M(1, 3)*M(2, 1))
    Mi(3, 1) = (M(2, 1)*M(3, 2) - M(2, 2)*M(3, 1)); Mi(3, 2) = -(M(1, 1)*M(3, 2) - M(1, 2)*M(3, 1))
    Mi(3, 3) = (M(1, 1)*M(2, 2) - M(1, 2)*M(2, 1))
    Mi = Mi/d
  END FUNCTION minv3

  PURE FUNCTION vee(S) RESULT(v)
    REAL(wp), INTENT(IN) :: S(3, 3)
    REAL(wp) :: v(3)
    v = [S(3, 2) - S(2, 3), S(1, 3) - S(3, 1), S(2, 1) - S(1, 2)]*CD_HALF
  END FUNCTION vee

  PURE FUNCTION outer(a, b) RESULT(M)
    REAL(wp), INTENT(IN) :: a(:), b(:)
    REAL(wp) :: M(SIZE(a), SIZE(b))
    INTEGER :: i, j
    DO j = 1, SIZE(b)
      DO i = 1, SIZE(a)
        M(i, j) = a(i)*b(j)
      END DO
    END DO
  END FUNCTION outer

  FUNCTION dth_dpsi(thn, psi, s) RESULT(T)
    !! d/d(psi) of theta_out = log(exp(thn) cay(s*psi)); s = 1/2 (midpoint) or 1 (endpoint).
    !! dCay(phi)[d] = A^-1 (1/2 d_hat)(I+C), A=(I-1/2 phi_hat), phi=s*psi; dR = exp(thn) dCay;
    !! dtheta = dexp_inv(-theta_out) . vee(R^T dR) (checked against central differences).
    REAL(wp), INTENT(IN) :: thn(3), psi(3), s
    REAL(wp) :: T(3, 3), phi(3), A(3, 3), Ai(3, 3), C(3, 3), R(3, 3), tho(3), Di(3, 3)
    REAL(wp) :: dC(3, 3), dR(3, 3), I3(3, 3), ej(3)
    INTEGER :: j
    I3 = diag3([CD_ONE, CD_ONE, CD_ONE]); phi = s*psi
    A = I3 - CD_HALF*CD_Hat(phi); Ai = minv3(A)
    C = MATMUL(Ai, I3 + CD_HALF*CD_Hat(phi))
    R = MATMUL(CD_Exp_SO3(thn), C); tho = CD_Log_SO3(R); Di = CD_Dexp_Inv_SO3(-tho)
    DO j = 1, 3
      ej = CD_ZERO; ej(j) = s
      dC = MATMUL(MATMUL(Ai, CD_HALF*CD_Hat(ej)), I3 + C)
      dR = MATMUL(CD_Exp_SO3(thn), dC)
      T(:, j) = MATMUL(Di, vee(MATMUL(TRANSPOSE(R), dR)))
    END DO
  END FUNCTION dth_dpsi

  PURE FUNCTION repl(A, c, b) RESULT(M)
    REAL(wp), INTENT(IN) :: A(3, 3), b(3)
    INTEGER, INTENT(IN) :: c
    REAL(wp) :: M(3, 3)
    M = A; M(:, c) = b
  END FUNCTION repl

  PURE FUNCTION det3(M) RESULT(d)
    REAL(wp), INTENT(IN) :: M(3, 3)
    REAL(wp) :: d
    d = M(1, 1)*(M(2, 2)*M(3, 3) - M(2, 3)*M(3, 2)) - M(1, 2)*(M(2, 1)*M(3, 3) - M(2, 3)*M(3, 1)) &
        + M(1, 3)*(M(2, 1)*M(3, 2) - M(2, 2)*M(3, 1))
  END FUNCTION det3

  SUBROUTINE solve_dense(A, b, x, ok)
    !! Gaussian elimination with partial pivoting (dense; the FD-Jacobian Newton solve).
    REAL(wp), INTENT(IN) :: A(:, :), b(:)
    REAL(wp), INTENT(OUT) :: x(:)
    LOGICAL, INTENT(OUT) :: ok
    REAL(wp), ALLOCATABLE :: M(:, :)
    INTEGER :: n, i, j, k, piv
    REAL(wp) :: f, tmp(SIZE(b) + 1)
    n = SIZE(b); ok = .TRUE.
    ALLOCATE (M(n, n + 1)); M(:, 1:n) = A; M(:, n + 1) = b
    DO i = 1, n
      piv = i
      DO j = i + 1, n
        IF (ABS(M(j, i)) > ABS(M(piv, i))) piv = j
      END DO
      IF (ABS(M(piv, i)) <= TINY(CD_ONE)*1.0e3_wp) THEN; ok = .FALSE.; x = CD_ZERO; RETURN; END IF
      IF (piv /= i) THEN; tmp = M(i, :); M(i, :) = M(piv, :); M(piv, :) = tmp; END IF
      DO j = i + 1, n
        f = M(j, i)/M(i, i); M(j, :) = M(j, :) - f*M(i, :)
      END DO
    END DO
    DO i = n, 1, -1
      x(i) = M(i, n + 1)
      DO k = i + 1, n
        x(i) = x(i) - M(i, k)*x(k)
      END DO
      x(i) = x(i)/M(i, i)
    END DO
  END SUBROUTINE solve_dense

END MODULE CableDyn_CosseratEMC
