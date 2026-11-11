! File: tests/test_emc.f90
! SPDX-License-Identifier: Apache-2.0
! Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
PROGRAM test_emc
  !! Gate for the energy-conserving integrator (CableDyn_CosseratEMC). Energy is the
  !! conserved invariant gated here; exact momentum conservation is a documented follow-up.
  !! GATE A  energy conservation: a free-free finite-EI rod given a bending-velocity
  !!         kick conserves total mechanical energy to round-off over a long run, where
  !!         the generalized-alpha scheme shows a small drift. Machine-precision gate.
  !! GATE B  fail-closed: a partial-node Dirichlet (fixed) DOF list is rejected, with defined
  !!         outputs on the rejected return.
  !! GATE C  force convention: the body-increment rotational torque matches finite differences
  !!         of the potential.
  !! GATE E  non-convergence returns a defined, unadvanced state (conv = .FALSE., ErrStat OK).
  !! GATE F  an invalid solver configuration fails closed.
  !! GATE G  a clamped (whole-node Dirichlet) support conserves energy and holds the clamp.
  !! GATES H-J  the closed-form consistent tangent: energy and trajectory parity with the FD
  !!         Jacobian, direct tangent parity with quadratic convergence, and a clamped node.
  !! GATE K  the banded Sherman-Morrison solve on a longer rod.
  !! GATES L-N  consistent mass: energy conservation, fail-closed scope and its tangent.
  USE CableDyn_Precision, ONLY: wp
  USE CableDyn_SO3, ONLY: CD_Exp_SO3, CD_Log_SO3, CD_Dexp_Inv_SO3
  USE CableDyn_Dynamic, ONLY: GenAlphaConfig, CD_DYN_OK, CD_DYN_BADINPUT
  USE CableDyn_CosseratDynamic, ONLY: CD_Cosserat_Mechanical_Energy
  USE CableDyn_CosseratAssemble, ONLY: CD_Assemble_Cosserat_Internal_Force
  USE CableDyn_CosseratEMC, ONLY: CD_Cosserat_EMC_Step, CD_EMC_Reference_Inertia
  IMPLICIT NONE
  INTEGER, PARAMETER :: NE = 2, NN = NE + 1, ND = 6*NN
  REAL(wp), PARAMETER :: Lr = 1.0_wp, EA = 1.0e3_wp, GAS = 1.0e3_wp, EI = 5.0_wp, GJ = 5.0_wp
  REAL(wp), PARAMETER :: RHOA = 1.0_wp, IT = 1.0e-2_wp, IN_ = 2.0e-2_wp
  REAL(wp), PARAMETER :: PI = 3.14159265358979323846_wp
  REAL(wp) :: nodes_ref(3, NN)
  REAL(wp) :: ea_a(NE), gas_a(NE), ei_a(NE), gj_a(NE), ra(NE), ita(NE), ina(NE)
  INTEGER :: conn(2, NE)
  REAL(wp) :: mnode(NN), Jref(3, 3, NN)
  REAL(wp) :: q(ND), v(ND), f_ext(ND), q_new(ND), v_new(ND)
  TYPE(GenAlphaConfig) :: cfg
  INTEGER :: i, a, es, nit, nfail
  CHARACTER(200) :: em
  REAL(wp) :: dt, E0, Emax, Ecur
  LOGICAL :: conv

  nfail = 0
  DO i = 1, NN
    nodes_ref(:, i) = [REAL(i - 1, wp)*Lr/REAL(NE, wp), 0.0_wp, 0.0_wp]
  END DO
  DO i = 1, NE
    conn(:, i) = [i, i + 1]
    ea_a(i) = EA; gas_a(i) = GAS; ei_a(i) = EI; gj_a(i) = GJ
    ra(i) = RHOA; ita(i) = IT; ina(i) = IN_
  END DO
  CALL CD_EMC_Reference_Inertia(nodes_ref, conn, ra, ita, ina, mnode, Jref, es, em)
  IF (es /= CD_DYN_OK) THEN; WRITE (*, '(A)') 'FAIL: reference inertia: '//TRIM(em); nfail = nfail + 1; END IF

  ! --- GATE A: energy conservation ---
  q = 0.0_wp; v = 0.0_wp; f_ext = 0.0_wp
  DO a = 1, NN
    q(6*a - 5:6*a - 3) = nodes_ref(:, a)
    v(6*a - 3) = 0.5_wp*SIN(PI*nodes_ref(1, a)/Lr)        ! transverse (z) velocity kick
  END DO
  cfg%rho_inf = 1.0_wp; cfg%abs_tol = 1.0e-12_wp; cfg%rel_tol = 1.0e-10_wp
  cfg%max_iter = 60
  dt = 0.01_wp
  E0 = total_energy(q, v); Emax = 0.0_wp
  DO i = 1, 300
    CALL CD_Cosserat_EMC_Step(nodes_ref, conn, ea_a, gas_a, ei_a, gj_a, ra, ita, ina, .TRUE., &
                              q, v, f_ext, [INTEGER ::], dt, cfg, q_new, v_new, conv, nit, es, em)
    IF (es /= CD_DYN_OK .OR. .NOT. conv) THEN
      WRITE (*, '(A,I0,A,L1,A)') 'FAIL: EMC step ', i, ' es/conv (', conv, ') '//TRIM(em); nfail = nfail + 1; EXIT
    END IF
    q = q_new; v = v_new
    Ecur = total_energy(q, v)
    Emax = MAX(Emax, ABS(Ecur - E0)/ABS(E0))
  END DO
  WRITE (*, '(A,ES11.3)') '[GATE A] EMC energy drift over 300 steps = ', Emax
  IF (.NOT. (Emax <= 1.0e-9_wp)) THEN
    WRITE (*, '(A)') 'FAIL: GATE A energy not conserved to round-off'; nfail = nfail + 1
  END IF

  ! --- GATE B: PARTIAL-node fixing fails closed, with DEFINED outputs on the rejected return ---
  ! [1,2,3] fixes only 3 of node 1's 6 DOFs (a hinge/roller) -> rejected (whole-node clamps only).
  q_new = -777.0_wp; v_new = -777.0_wp        ! sentinel: must be overwritten to the input state
  CALL CD_Cosserat_EMC_Step(nodes_ref, conn, ea_a, gas_a, ei_a, gj_a, ra, ita, ina, .TRUE., &
                            q, v, f_ext, [1, 2, 3], dt, cfg, q_new, v_new, conv, nit, es, em)
  IF (es /= CD_DYN_BADINPUT) THEN
    WRITE (*, '(A)') 'FAIL: GATE B partial-node fixing should be rejected'; nfail = nfail + 1
  ELSE IF (.NOT. (nan_max_abs(q_new - q) <= 0.0_wp) .OR. .NOT. (nan_max_abs(v_new - v) <= 0.0_wp)) THEN
    WRITE (*, '(A)') 'FAIL: GATE B outputs left undefined on a rejected step'; nfail = nfail + 1
  ELSE
    WRITE (*, '(A)') '[GATE B] partial-node fixing rejected (fail-closed); outputs defined = input state'
  END IF

  ! --- GATE C: force-convention FD oracle (body-increment rotational torque) ---
  ! The EMC maps the assembler's additive internal force to the body rotation increment
  ! conjugate by f_body_rot = dexp_inv(theta) . fint_rot. Verify that transform against
  ! central differences of the strain energy at a FINITE nodal rotation: the energy gate
  ! alone cannot distinguish the force DIRECTION (the Gonzalez correction balances work
  ! either way), so this independently pins the conjugacy used in the residual.
  BLOCK
    REAL(wp) :: qf(ND), fint(ND), fbody(3), ftrue(3), Rd0(3, 3), dv(3), qp(ND), qm(ND), th(3), cmax
    INTEGER :: jj
    REAL(wp), PARAMETER :: HH = 1.0e-6_wp
    qf = 0.0_wp
    DO a = 1, NN
      qf(6*a - 5:6*a - 3) = nodes_ref(:, a)
      qf(6*a - 2:6*a) = [0.07_wp*a, -0.11_wp*a, 0.09_wp*a]    ! finite nodal rotations
    END DO
    CALL CD_Assemble_Cosserat_Internal_Force(nodes_ref, conn, ea_a, gas_a, ei_a, gj_a, qf, .TRUE., fint, es, em)
    cmax = 0.0_wp
    DO a = 1, NN
      th = qf(6*a - 2:6*a)
      fbody = MATMUL(CD_Dexp_Inv_SO3(th), fint(6*a - 2:6*a))   ! the production transform
      Rd0 = CD_Exp_SO3(th)                                     ! body frame R = exp(theta)
      DO jj = 1, 3
        dv = 0.0_wp; dv(jj) = HH
        qp = qf; qp(6*a - 2:6*a) = CD_Log_SO3(MATMUL(Rd0, CD_Exp_SO3(dv)))
        qm = qf; qm(6*a - 2:6*a) = CD_Log_SO3(MATMUL(Rd0, CD_Exp_SO3(-dv)))
        ftrue(jj) = (strain_only(qp) - strain_only(qm))/(2.0_wp*HH)
      END DO
      cmax = MAX(cmax, nan_max_abs(fbody - ftrue))
    END DO
    WRITE (*, '(A,ES11.3)') '[GATE C] |dexp_inv(theta) fint - FD-of-W body| = ', cmax
    IF (.NOT. (cmax <= 1.0e-6_wp)) THEN
      WRITE (*, '(A)') 'FAIL: GATE C force-transform convention does not match FD-of-W'; nfail = nfail + 1
    END IF
  END BLOCK

  ! --- GATE E: non-convergence returns a DEFINED, unadvanced state (not an error code) ---
  ! Starve the Newton solve (max_iter = 1) so a nonlinear step cannot converge; the step
  ! must report conv=.FALSE. with ErrStat=OK and leave the outputs equal to the input state.
  BLOCK
    REAL(wp) :: q0(ND), v0(ND)
    TYPE(GenAlphaConfig) :: cfg1
    q0 = 0.0_wp; v0 = 0.0_wp
    DO a = 1, NN
      q0(6*a - 5:6*a - 3) = nodes_ref(:, a)
      v0(6*a - 3) = 0.5_wp*SIN(PI*nodes_ref(1, a)/Lr)
    END DO
    cfg1 = cfg; cfg1%max_iter = 1
    q_new = -999.0_wp; v_new = -999.0_wp
    CALL CD_Cosserat_EMC_Step(nodes_ref, conn, ea_a, gas_a, ei_a, gj_a, ra, ita, ina, .TRUE., &
                              q0, v0, f_ext, [INTEGER ::], dt, cfg1, q_new, v_new, conv, nit, es, em)
    IF (conv) THEN
      WRITE (*, '(A)') 'FAIL: GATE E expected non-convergence at max_iter=1'; nfail = nfail + 1
    ELSE IF (es /= CD_DYN_OK) THEN
      WRITE (*, '(A)') 'FAIL: GATE E non-convergence must be reported via conv, not ErrStat'; nfail = nfail + 1
    ELSE IF (.NOT. (nan_max_abs(q_new - q0) <= 0.0_wp) .OR. .NOT. (nan_max_abs(v_new - v0) <= 0.0_wp)) THEN
      WRITE (*, '(A)') 'FAIL: GATE E outputs must equal the unadvanced input state'; nfail = nfail + 1
    ELSE
      WRITE (*, '(A)') '[GATE E] non-convergence: conv=.FALSE., ErrStat=OK, outputs=input state'
    END IF
  END BLOCK

  ! --- GATE F: invalid solver config fails closed ---
  BLOCK
    TYPE(GenAlphaConfig) :: bad
    bad = cfg; bad%max_iter = 0
    CALL CD_Cosserat_EMC_Step(nodes_ref, conn, ea_a, gas_a, ei_a, gj_a, ra, ita, ina, .TRUE., &
                              q, v, f_ext, [INTEGER ::], dt, bad, q_new, v_new, conv, nit, es, em)
    IF (es /= CD_DYN_BADINPUT) THEN
      WRITE (*, '(A)') 'FAIL: GATE F max_iter=0 should be rejected'; nfail = nfail + 1
    END IF
    bad = cfg; bad%rel_tol = -1.0_wp
    CALL CD_Cosserat_EMC_Step(nodes_ref, conn, ea_a, gas_a, ei_a, gj_a, ra, ita, ina, .TRUE., &
                              q, v, f_ext, [INTEGER ::], dt, bad, q_new, v_new, conv, nit, es, em)
    IF (es /= CD_DYN_BADINPUT) THEN
      WRITE (*, '(A)') 'FAIL: GATE F negative rel_tol should be rejected'; nfail = nfail + 1
    ELSE
      WRITE (*, '(A)') '[GATE F] invalid solver config (max_iter/tol) rejected (fail-closed)'
    END IF
  END BLOCK

  ! --- GATE G: clamped (whole-node Dirichlet) support conserves energy and holds the clamp ---
  ! Node 1 clamped (all 6 DOFs); the free nodes get a transverse kick. A cantilever does no
  ! work at the clamp (v=0 there), so total energy is conserved to round-off, and the clamped
  ! node stays exactly at its input position with zero velocity.
  BLOCK
    REAL(wp) :: q0(ND), v0(ND), E0g, Emg, Ec, holdmax
    INTEGER :: ig
    q0 = 0.0_wp; v0 = 0.0_wp
    DO a = 1, NN
      q0(6*a - 5:6*a - 3) = nodes_ref(:, a)
    END DO
    DO a = 2, NN
      v0(6*a - 3) = 0.3_wp*REAL(a - 1, wp)      ! transverse kick on the free nodes only
    END DO
    E0g = total_energy(q0, v0); Emg = 0.0_wp; holdmax = 0.0_wp
    DO ig = 1, 300
      CALL CD_Cosserat_EMC_Step(nodes_ref, conn, ea_a, gas_a, ei_a, gj_a, ra, ita, ina, .TRUE., &
                                q0, v0, f_ext, [1, 2, 3, 4, 5, 6], dt, cfg, q_new, v_new, conv, nit, es, em)
      IF (es /= CD_DYN_OK .OR. .NOT. conv) THEN
        WRITE (*, '(A,I0,A)') 'FAIL: GATE G clamped step ', ig, ' failed'; nfail = nfail + 1; EXIT
      END IF
      q0 = q_new; v0 = v_new
      Ec = total_energy(q0, v0); Emg = MAX(Emg, ABS(Ec - E0g)/ABS(E0g))
      holdmax = MAX(holdmax, nan_max_abs(q0(1:6) - [nodes_ref(:, 1), 0.0_wp, 0.0_wp, 0.0_wp]), nan_max_abs(v0(1:6)))
    END DO
    WRITE (*, '(A,ES11.3,A,ES11.3)') '[GATE G] clamped-beam energy drift = ', Emg, '  clamp hold = ', holdmax
    IF (.NOT. (Emg <= 1.0e-9_wp)) THEN
      WRITE (*, '(A)') 'FAIL: GATE G clamped-beam energy not conserved'; nfail = nfail + 1
    END IF
    IF (.NOT. (holdmax <= 1.0e-12_wp)) THEN
      WRITE (*, '(A)') 'FAIL: GATE G clamped node did not stay fixed at rest'; nfail = nfail + 1
    END IF
  END BLOCK

  ! --- GATE H: closed-form consistent tangent -- energy + trajectory parity vs the FD Jacobian ---
  ! The analytic tangent (opt-in) must solve the SAME residual as the default FD Jacobian: an
  ! identical trajectory to round-off, with the energy invariant preserved. A spinning rod
  ! exercises the finite-rotation gyroscopic and Gonzalez-correction tangents.
  BLOCK
    REAL(wp) :: q0(ND), v0(ND), fz(ND), qan(ND), van(ND), qfd(ND), vfd(ND), Eref, Edrift, dtraj
    INTEGER :: ih, na, nfd
    LOGICAL :: cA, cFD
    q0 = 0.0_wp; v0 = 0.0_wp; fz = 0.0_wp
    DO a = 1, NN
      q0(6*a - 5:6*a - 3) = nodes_ref(:, a)
      q0(6*a - 2:6*a) = [0.05_wp*a, -0.04_wp*a, 0.03_wp*a]      ! finite pre-rotation
      v0(6*a - 3) = 0.5_wp*SIN(PI*nodes_ref(1, a)/Lr)           ! bending velocity kick
      v0(6*a - 2:6*a) = [0.4_wp, 0.3_wp, -0.2_wp]               ! spatial angular velocity (gyro)
    END DO
    cfg%rho_inf = 1.0_wp; cfg%abs_tol = 1.0e-12_wp; cfg%rel_tol = 1.0e-10_wp; cfg%max_iter = 60
    dt = 0.01_wp; Eref = total_energy(q0, v0); Edrift = 0.0_wp; dtraj = 0.0_wp
    DO ih = 1, 100
      cfg%emc_analytic_tangent = .TRUE.
      CALL CD_Cosserat_EMC_Step(nodes_ref, conn, ea_a, gas_a, ei_a, gj_a, ra, ita, ina, .TRUE., &
                                q0, v0, fz, [INTEGER ::], dt, cfg, qan, van, cA, na, es, em)
      cfg%emc_analytic_tangent = .FALSE.
      CALL CD_Cosserat_EMC_Step(nodes_ref, conn, ea_a, gas_a, ei_a, gj_a, ra, ita, ina, .TRUE., &
                                q0, v0, fz, [INTEGER ::], dt, cfg, qfd, vfd, cFD, nfd, es, em)
      IF (es /= CD_DYN_OK .OR. .NOT. (cA .AND. cFD)) THEN
        WRITE (*, '(A,I0)') 'FAIL: GATE H step failed at ', ih; nfail = nfail + 1; EXIT
      END IF
      dtraj = MAX(dtraj, nan_max_abs(qan - qfd), nan_max_abs(van - vfd))
      q0 = qan; v0 = van
      Edrift = MAX(Edrift, ABS(total_energy(q0, v0) - Eref)/ABS(Eref))
    END DO
    WRITE (*, '(A,ES11.3,A,ES11.3)') '[GATE H] analytic energy drift = ', Edrift, &
      '  analytic-vs-FD trajectory = ', dtraj
    IF (.NOT. (Edrift <= 1.0e-9_wp)) THEN
      WRITE (*, '(A)') 'FAIL: GATE H analytic tangent broke energy conservation'; nfail = nfail + 1
    END IF
    IF (.NOT. (dtraj <= 1.0e-9_wp)) THEN
      WRITE (*, '(A)') 'FAIL: GATE H analytic path diverged from the FD path'; nfail = nfail + 1
    END IF
  END BLOCK

  ! --- GATE I: direct tangent parity (analytic vs FD) + quadratic convergence, applied moment ---
  ! One step of a fast-spinning rod under an applied nodal FORCE and MOMENT. The diagnostic
  ! reports max|J_analytic - J_FD| (central-difference oracle); the analytic tangent must match
  ! it to the FD floor, reach the same root as the FD solve, and converge no slower (quadratic).
  BLOCK
    REAL(wp) :: qi(ND), vi(ND), fi(ND), qo(ND), vo(ND), qo2(ND), vo2(ND), mdiff, rpar
    INTEGER :: na, nfd
    LOGICAL :: cA, cFD
    qi = 0.0_wp; vi = 0.0_wp; fi = 0.0_wp
    DO a = 1, NN
      qi(6*a - 5:6*a - 3) = nodes_ref(:, a)
      qi(6*a - 2:6*a) = [0.06_wp*a, -0.09_wp*a, 0.05_wp*a]      ! finite pre-rotation
      vi(6*a - 5:6*a - 3) = [0.3_wp, -0.2_wp, 0.4_wp]*a         ! translational velocity
      vi(6*a - 2:6*a) = [1.2_wp, 0.8_wp, -0.6_wp]               ! large spatial angular velocity
      fi(6*a - 3) = 2.0_wp*a                                    ! applied transverse FORCE
      fi(6*a - 2:6*a) = 5.0_wp*[0.2_wp, -0.5_wp, 0.3_wp]        ! applied nodal MOMENT (f_ext_rot)
    END DO
    cfg%rho_inf = 1.0_wp; cfg%abs_tol = 1.0e-12_wp; cfg%rel_tol = 1.0e-11_wp; cfg%max_iter = 60
    dt = 0.02_wp
    cfg%emc_analytic_tangent = .TRUE.
    CALL CD_Cosserat_EMC_Step(nodes_ref, conn, ea_a, gas_a, ei_a, gj_a, ra, ita, ina, .TRUE., &
                              qi, vi, fi, [INTEGER ::], dt, cfg, qo, vo, cA, na, es, em, analytic_fd_maxdiff=mdiff)
    cfg%emc_analytic_tangent = .FALSE.
    CALL CD_Cosserat_EMC_Step(nodes_ref, conn, ea_a, gas_a, ei_a, gj_a, ra, ita, ina, .TRUE., &
                              qi, vi, fi, [INTEGER ::], dt, cfg, qo2, vo2, cFD, nfd, es, em)
    rpar = MAX(nan_max_abs(qo - qo2), nan_max_abs(vo - vo2))
    WRITE (*, '(A,ES11.3,A,I0,A,I0,A,ES11.3)') '[GATE I] tangent maxdiff = ', mdiff, &
      '  n_iter analytic/FD = ', na, '/', nfd, '  result parity = ', rpar
    IF (es /= CD_DYN_OK .OR. .NOT. (cA .AND. cFD)) THEN
      WRITE (*, '(A)') 'FAIL: GATE I step failed'; nfail = nfail + 1
    END IF
    IF (.NOT. (mdiff <= 1.0e-6_wp)) THEN
      WRITE (*, '(A)') 'FAIL: GATE I analytic tangent does not match the FD oracle'; nfail = nfail + 1
    END IF
    IF (.NOT. (rpar <= 1.0e-9_wp)) THEN
      WRITE (*, '(A)') 'FAIL: GATE I analytic path did not reach the FD root'; nfail = nfail + 1
    END IF
    IF (na > nfd + 1) THEN
      WRITE (*, '(A)') 'FAIL: GATE I analytic tangent converged slower than FD (not quadratic)'; nfail = nfail + 1
    END IF
  END BLOCK

  ! --- GATE J: analytic tangent with a CLAMPED node -- exercises the Dirichlet identity row ---
  ! The clamped cantilever of GATE G, now driven by the analytic tangent: energy conserved, the
  ! clamp held exactly, and the tangent matching the FD oracle (a fixed node's row is the pure
  ! constraint P->0, dR/dP = I on its block only -- the analytic path must reproduce that).
  BLOCK
    REAL(wp) :: q0(ND), v0(ND), E0j, Emj, Ec, holdmax, mdiff
    INTEGER :: ij
    LOGICAL :: cj
    q0 = 0.0_wp; v0 = 0.0_wp
    DO a = 1, NN
      q0(6*a - 5:6*a - 3) = nodes_ref(:, a)
    END DO
    DO a = 2, NN
      v0(6*a - 3) = 0.3_wp*REAL(a - 1, wp)
    END DO
    cfg%rho_inf = 1.0_wp; cfg%abs_tol = 1.0e-12_wp; cfg%rel_tol = 1.0e-10_wp; cfg%max_iter = 60
    cfg%emc_analytic_tangent = .TRUE.
    dt = 0.01_wp; E0j = total_energy(q0, v0); Emj = 0.0_wp; holdmax = 0.0_wp; mdiff = 0.0_wp
    DO ij = 1, 200
      IF (ij == 1) THEN
        CALL CD_Cosserat_EMC_Step(nodes_ref, conn, ea_a, gas_a, ei_a, gj_a, ra, ita, ina, .TRUE., &
                                  q0, v0, f_ext, [1, 2, 3, 4, 5, 6], dt, cfg, q_new, v_new, cj, nit, es, em, &
                                  analytic_fd_maxdiff=mdiff)
      ELSE
        CALL CD_Cosserat_EMC_Step(nodes_ref, conn, ea_a, gas_a, ei_a, gj_a, ra, ita, ina, .TRUE., &
                                  q0, v0, f_ext, [1, 2, 3, 4, 5, 6], dt, cfg, q_new, v_new, cj, nit, es, em)
      END IF
      IF (es /= CD_DYN_OK .OR. .NOT. cj) THEN
        WRITE (*, '(A,I0,A)') 'FAIL: GATE J analytic clamped step ', ij, ' failed'; nfail = nfail + 1; EXIT
      END IF
      q0 = q_new; v0 = v_new
      Ec = total_energy(q0, v0); Emj = MAX(Emj, ABS(Ec - E0j)/ABS(E0j))
      holdmax = MAX(holdmax, nan_max_abs(q0(1:6) - [nodes_ref(:, 1), 0.0_wp, 0.0_wp, 0.0_wp]), nan_max_abs(v0(1:6)))
    END DO
    WRITE (*, '(A,ES11.3,A,ES11.3,A,ES11.3)') '[GATE J] analytic clamped energy drift = ', Emj, &
      '  clamp hold = ', holdmax, '  tangent maxdiff = ', mdiff
    IF (.NOT. (Emj <= 1.0e-9_wp)) THEN
      WRITE (*, '(A)') 'FAIL: GATE J analytic clamped energy not conserved'; nfail = nfail + 1
    END IF
    IF (.NOT. (holdmax <= 1.0e-12_wp)) THEN
      WRITE (*, '(A)') 'FAIL: GATE J analytic clamped node moved'; nfail = nfail + 1
    END IF
    IF (.NOT. (mdiff <= 1.0e-6_wp)) THEN
      WRITE (*, '(A)') 'FAIL: GATE J analytic tangent mismatch with a clamped node'; nfail = nfail + 1
    END IF
    cfg%emc_analytic_tangent = .FALSE.
  END BLOCK

  ! --- GATE K: banded + Sherman-Morrison solve on a LONGER rod (band kd = 11 << ndof) ---
  ! The consistent tangent is banded B + a single rank-1 (the Gonzalez correction). For a chain
  ! the half-bandwidth is 11 regardless of length, so an 8-node rod (ndof=48) drives a genuinely
  ! banded system. The analytic (banded+SM) path must (a) match the FD (dense-solve) path
  ! trajectory to round-off -- the direct proof the rank-1 peel + Sherman-Morrison are exact --
  ! (b) converge quadratically, and (c) conserve energy to round-off. NOTE on (c): the EMC uses a
  ! LUMPED mass, so its conserved invariant is the LUMPED-mass energy, not the consistent-mass
  ! CD_Cosserat_Mechanical_Energy (whose translational KE uses the consistent matrix; the two
  ! differ by O(1e-2) on a multi-element rod). A consistent-mass EMC variant is a documented
  ! follow-up. We therefore measure the strain energy (mass-model-independent) plus the lumped KE.
  BLOCK
    INTEGER, PARAMETER :: NE2 = 7, NN2 = NE2 + 1, ND2 = 6*NN2
    REAL(wp) :: nr2(3, NN2), ea2(NE2), gs2(NE2), ei2(NE2), gj2(NE2), r2(NE2), it2(NE2), in2(NE2)
    REAL(wp) :: mn2(NN2), jr2(3, 3, NN2), om(3), om0(3)
    INTEGER :: cn2(2, NE2), ik, na, nfd, ia
    REAL(wp) :: q2(ND2), v2(ND2), f2(ND2), qa2(ND2), va2(ND2), qf2(ND2), vf2(ND2)
    REAL(wp) :: se, ke, lke, E02, Edr, dtj
    LOGICAL :: cA, cF
    DO ik = 1, NN2
      nr2(:, ik) = [REAL(ik - 1, wp)*0.5_wp, 0.0_wp, 0.0_wp]   ! segment length 0.5 (= GATE A/H stiffness)
    END DO
    DO ik = 1, NE2
      cn2(:, ik) = [ik, ik + 1]; ea2(ik) = EA; gs2(ik) = GAS; ei2(ik) = EI; gj2(ik) = GJ
      r2(ik) = RHOA; it2(ik) = IT; in2(ik) = IN_
    END DO
    CALL CD_EMC_Reference_Inertia(nr2, cn2, r2, it2, in2, mn2, jr2, es, em)
    q2 = 0.0_wp; v2 = 0.0_wp; f2 = 0.0_wp
    DO ik = 1, NN2
      q2(6*ik - 5:6*ik - 3) = nr2(:, ik)
      q2(6*ik - 2:6*ik) = [0.04_wp*ik, -0.03_wp*ik, 0.02_wp*ik]
      v2(6*ik - 3) = 0.4_wp*SIN(PI*nr2(1, ik)/(REAL(NE2, wp)*0.5_wp))
      v2(6*ik - 2:6*ik) = [0.3_wp, 0.2_wp, -0.15_wp]
    END DO
    cfg%rho_inf = 1.0_wp; cfg%abs_tol = 1.0e-13_wp; cfg%rel_tol = 1.0e-12_wp; cfg%max_iter = 60
    dt = 0.01_wp
    lke = 0.0_wp
    DO ia = 1, NN2
      lke = lke + 0.5_wp*mn2(ia)*DOT_PRODUCT(v2(6*ia - 5:6*ia - 3), v2(6*ia - 5:6*ia - 3))
      om = v2(6*ia - 2:6*ia); om0 = MATMUL(TRANSPOSE(CD_Exp_SO3(q2(6*ia - 2:6*ia))), om)
      lke = lke + 0.5_wp*DOT_PRODUCT(om0, MATMUL(jr2(:, :, ia), om0))
    END DO
    CALL CD_Cosserat_Mechanical_Energy(nr2, cn2, ea2, gs2, ei2, gj2, r2, it2, in2, .TRUE., q2, v2, &
                                       se, ke, es, em, multiplicative=.TRUE.)
    E02 = se + lke; Edr = 0.0_wp; dtj = 0.0_wp
    DO ik = 1, 60
      cfg%emc_analytic_tangent = .TRUE.
      CALL CD_Cosserat_EMC_Step(nr2, cn2, ea2, gs2, ei2, gj2, r2, it2, in2, .TRUE., &
                                q2, v2, f2, [INTEGER ::], dt, cfg, qa2, va2, cA, na, es, em)
      cfg%emc_analytic_tangent = .FALSE.
      CALL CD_Cosserat_EMC_Step(nr2, cn2, ea2, gs2, ei2, gj2, r2, it2, in2, .TRUE., &
                                q2, v2, f2, [INTEGER ::], dt, cfg, qf2, vf2, cF, nfd, es, em)
      IF (es /= CD_DYN_OK .OR. .NOT. (cA .AND. cF)) THEN
        WRITE (*, '(A,I0)') 'FAIL: GATE K step ', ik; nfail = nfail + 1; EXIT
      END IF
      dtj = MAX(dtj, nan_max_abs(qa2 - qf2), nan_max_abs(va2 - vf2))
      IF (na > nfd + 1) THEN
        WRITE (*, '(A)') 'FAIL: GATE K banded+SM converged slower than the dense solve'; nfail = nfail + 1; EXIT
      END IF
      q2 = qa2; v2 = va2
      lke = 0.0_wp
      DO ia = 1, NN2
        lke = lke + 0.5_wp*mn2(ia)*DOT_PRODUCT(v2(6*ia - 5:6*ia - 3), v2(6*ia - 5:6*ia - 3))
        om = v2(6*ia - 2:6*ia); om0 = MATMUL(TRANSPOSE(CD_Exp_SO3(q2(6*ia - 2:6*ia))), om)
        lke = lke + 0.5_wp*DOT_PRODUCT(om0, MATMUL(jr2(:, :, ia), om0))
      END DO
      CALL CD_Cosserat_Mechanical_Energy(nr2, cn2, ea2, gs2, ei2, gj2, r2, it2, in2, .TRUE., q2, v2, &
                                         se, ke, es, em, multiplicative=.TRUE.)
      Edr = MAX(Edr, ABS(se + lke - E02)/ABS(E02))
    END DO
    WRITE (*, '(A,I0,A,ES11.3,A,ES11.3)') '[GATE K] long rod (ndof=', ND2, &
      ') banded+SM lumped-energy drift = ', Edr, '  vs-dense trajectory = ', dtj
    IF (.NOT. (Edr <= 1.0e-9_wp)) THEN
      WRITE (*, '(A)') 'FAIL: GATE K banded+SM lumped energy not conserved'; nfail = nfail + 1
    END IF
    IF (.NOT. (dtj <= 1.0e-9_wp)) THEN
      WRITE (*, '(A)') 'FAIL: GATE K banded+SM diverged from the dense solve'; nfail = nfail + 1
    END IF
    cfg%emc_analytic_tangent = .FALSE.
  END BLOCK

  ! --- GATE L: consistent-mass EMC conserves the CONSISTENT-mass energy (teeth: lumped drifts) ---
  ! The lumped EMC conserves only its lumped energy; measured with the consistent-mass
  ! CD_Cosserat_Mechanical_Energy it drifts O(1e-2) on a multi-element rod. emc_consistent_mass
  ! uses the consistent translational mass, so it conserves the consistent energy to round-off.
  ! Run the SAME rod + IC both ways: consistent << lumped is the discriminating gate.
  BLOCK
    INTEGER, PARAMETER :: NE3 = 6, NN3 = NE3 + 1, ND3 = 6*NN3
    REAL(wp) :: nr3(3, NN3), ea3(NE3), gs3(NE3), ei3(NE3), gj3(NE3), rr3(NE3), it3(NE3), in3(NE3)
    INTEGER :: cn3(2, NE3), il, na
    REAL(wp) :: q0s(ND3), v0s(ND3), q3(ND3), v3l(ND3), f3(ND3), qo3(ND3), vo3(ND3)
    REAL(wp) :: se, ke, E0c, Edc, Edl
    LOGICAL :: cv
    DO il = 1, NN3
      nr3(:, il) = [REAL(il - 1, wp)*0.5_wp, 0.0_wp, 0.0_wp]
    END DO
    DO il = 1, NE3
      cn3(:, il) = [il, il + 1]; ea3(il) = EA; gs3(il) = GAS; ei3(il) = EI; gj3(il) = GJ
      rr3(il) = RHOA; it3(il) = IT; in3(il) = IN_
    END DO
    q0s = 0.0_wp; v0s = 0.0_wp; f3 = 0.0_wp
    DO il = 1, NN3
      q0s(6*il - 5:6*il - 3) = nr3(:, il)
      v0s(6*il - 3) = 0.4_wp*SIN(PI*nr3(1, il)/(REAL(NE3, wp)*0.5_wp))
      v0s(6*il - 2:6*il) = [0.3_wp, 0.2_wp, -0.15_wp]
    END DO
    cfg%rho_inf = 1.0_wp; cfg%abs_tol = 1.0e-13_wp; cfg%rel_tol = 1.0e-12_wp; cfg%max_iter = 60
    dt = 0.01_wp
    ! LUMPED run (teeth): measure the consistent-mass energy drift
    cfg%emc_consistent_mass = .FALSE.
    q3 = q0s; v3l = v0s
    CALL CD_Cosserat_Mechanical_Energy(nr3, cn3, ea3, gs3, ei3, gj3, rr3, it3, in3, .TRUE., q3, v3l, &
                                       se, ke, es, em, multiplicative=.TRUE.)
    E0c = se + ke; Edl = 0.0_wp
    DO il = 1, 60
      CALL CD_Cosserat_EMC_Step(nr3, cn3, ea3, gs3, ei3, gj3, rr3, it3, in3, .TRUE., &
                                q3, v3l, f3, [INTEGER ::], dt, cfg, qo3, vo3, cv, na, es, em)
      IF (es /= CD_DYN_OK .OR. .NOT. cv) THEN
        WRITE (*, '(A)') 'FAIL: GATE L lumped step'; nfail = nfail + 1; EXIT
      END IF
      q3 = qo3; v3l = vo3
      CALL CD_Cosserat_Mechanical_Energy(nr3, cn3, ea3, gs3, ei3, gj3, rr3, it3, in3, .TRUE., q3, v3l, &
                                         se, ke, es, em, multiplicative=.TRUE.)
      Edl = MAX(Edl, ABS(se + ke - E0c)/ABS(E0c))
    END DO
    ! CONSISTENT run: the same consistent-mass energy must now conserve to round-off
    cfg%emc_consistent_mass = .TRUE.
    q3 = q0s; v3l = v0s
    Edc = 0.0_wp
    DO il = 1, 60
      CALL CD_Cosserat_EMC_Step(nr3, cn3, ea3, gs3, ei3, gj3, rr3, it3, in3, .TRUE., &
                                q3, v3l, f3, [INTEGER ::], dt, cfg, qo3, vo3, cv, na, es, em)
      IF (es /= CD_DYN_OK .OR. .NOT. cv) THEN
        WRITE (*, '(A)') 'FAIL: GATE L consistent step'; nfail = nfail + 1; EXIT
      END IF
      q3 = qo3; v3l = vo3
      CALL CD_Cosserat_Mechanical_Energy(nr3, cn3, ea3, gs3, ei3, gj3, rr3, it3, in3, .TRUE., q3, v3l, &
                                         se, ke, es, em, multiplicative=.TRUE.)
      Edc = MAX(Edc, ABS(se + ke - E0c)/ABS(E0c))
    END DO
    cfg%emc_consistent_mass = .FALSE.
    WRITE (*, '(A,ES11.3,A,ES11.3)') '[GATE L] consistent-mass energy drift: consistent = ', Edc, '  lumped = ', Edl
    IF (.NOT. (Edc <= 1.0e-9_wp)) THEN
      WRITE (*, '(A)') 'FAIL: GATE L consistent-mass EMC did not conserve the consistent energy'; nfail = nfail + 1
    END IF
    IF (Edl < 1.0e-3_wp) THEN
      WRITE (*, '(A)') 'FAIL: GATE L teeth absent -- lumped should drift the consistent energy'; nfail = nfail + 1
    END IF
  END BLOCK

  ! --- GATE M: consistent-mass fail-closed (free-free only; not with the analytic tangent) ---
  BLOCK
    REAL(wp) :: q0(ND), v0(ND)
    TYPE(GenAlphaConfig) :: cbad
    q0 = 0.0_wp; v0 = 0.0_wp
    DO a = 1, NN
      q0(6*a - 5:6*a - 3) = nodes_ref(:, a)
    END DO
    cbad = cfg; cbad%emc_consistent_mass = .TRUE.
    CALL CD_Cosserat_EMC_Step(nodes_ref, conn, ea_a, gas_a, ei_a, gj_a, ra, ita, ina, .TRUE., &
                              q0, v0, f_ext, [1, 2, 3, 4, 5, 6], dt, cbad, q_new, v_new, conv, nit, es, em)
    IF (es /= CD_DYN_BADINPUT) THEN
      WRITE (*, '(A)') 'FAIL: GATE M consistent-mass + Dirichlet should be rejected'; nfail = nfail + 1
    ELSE
      WRITE (*, '(A)') '[GATE M] consistent-mass + Dirichlet rejected (fail-closed; free-free only)'
    END IF
  END BLOCK

  ! --- GATE N: consistent-mass CLOSED-FORM TANGENT -- parity vs FD + quadratic convergence ---
  ! The velocity-formulation consistent-mass analytic tangent (lumped tangent with M3 in the
  ! translational block and the mass out of the G blocks) must match the FD oracle to the FD floor
  ! and converge quadratically -- the same root as the FD path.
  BLOCK
    INTEGER, PARAMETER :: NE4 = 6, NN4 = NE4 + 1, ND4 = 6*NN4
    REAL(wp) :: nr4(3, NN4), ea4(NE4), gs4(NE4), ei4(NE4), gj4(NE4), rr4(NE4), it4(NE4), in4(NE4)
    INTEGER :: cn4(2, NE4), ii, na, nfd
    REAL(wp) :: q4(ND4), v4(ND4), f4(ND4), qa4(ND4), va4(ND4), qf4(ND4), vf4(ND4), mdiff, rpar
    LOGICAL :: cA, cF
    DO ii = 1, NN4
      nr4(:, ii) = [REAL(ii - 1, wp)*0.5_wp, 0.0_wp, 0.0_wp]
    END DO
    DO ii = 1, NE4
      cn4(:, ii) = [ii, ii + 1]; ea4(ii) = EA; gs4(ii) = GAS; ei4(ii) = EI; gj4(ii) = GJ
      rr4(ii) = RHOA; it4(ii) = IT; in4(ii) = IN_
    END DO
    q4 = 0.0_wp; v4 = 0.0_wp; f4 = 0.0_wp
    DO ii = 1, NN4
      q4(6*ii - 5:6*ii - 3) = nr4(:, ii)
      q4(6*ii - 2:6*ii) = [0.05_wp*ii, -0.04_wp*ii, 0.03_wp*ii]
      v4(6*ii - 5:6*ii - 3) = [0.3_wp, -0.2_wp, 0.25_wp]
      v4(6*ii - 2:6*ii) = [0.8_wp, 0.5_wp, -0.4_wp]
      f4(6*ii - 3) = 1.5_wp*ii
    END DO
    cfg%rho_inf = 1.0_wp; cfg%abs_tol = 1.0e-13_wp; cfg%rel_tol = 1.0e-12_wp; cfg%max_iter = 60
    dt = 0.02_wp
    cfg%emc_consistent_mass = .TRUE.
    cfg%emc_analytic_tangent = .TRUE.
    CALL CD_Cosserat_EMC_Step(nr4, cn4, ea4, gs4, ei4, gj4, rr4, it4, in4, .TRUE., &
                              q4, v4, f4, [INTEGER ::], dt, cfg, qa4, va4, cA, na, es, em, analytic_fd_maxdiff=mdiff)
    cfg%emc_analytic_tangent = .FALSE.
    CALL CD_Cosserat_EMC_Step(nr4, cn4, ea4, gs4, ei4, gj4, rr4, it4, in4, .TRUE., &
                              q4, v4, f4, [INTEGER ::], dt, cfg, qf4, vf4, cF, nfd, es, em)
    cfg%emc_consistent_mass = .FALSE.
    rpar = MAX(nan_max_abs(qa4 - qf4), nan_max_abs(va4 - vf4))
    WRITE (*, '(A,ES11.3,A,I0,A,I0,A,ES11.3)') '[GATE N] cmass tangent maxdiff = ', mdiff, &
      '  n_iter analytic/FD = ', na, '/', nfd, '  result parity = ', rpar
    IF (es /= CD_DYN_OK .OR. .NOT. (cA .AND. cF)) THEN
      WRITE (*, '(A)') 'FAIL: GATE N step failed'; nfail = nfail + 1
    END IF
    IF (.NOT. (mdiff <= 1.0e-6_wp)) THEN
      WRITE (*, '(A)') 'FAIL: GATE N consistent-mass analytic tangent mismatches the FD oracle'; nfail = nfail + 1
    END IF
    IF (.NOT. (rpar <= 1.0e-9_wp)) THEN
      WRITE (*, '(A)') 'FAIL: GATE N analytic path did not reach the FD root'; nfail = nfail + 1
    END IF
    IF (na > nfd + 1) THEN
      WRITE (*, '(A)') 'FAIL: GATE N consistent-mass tangent converged slower than FD (not quadratic)'
      nfail = nfail + 1
    END IF
  END BLOCK

  IF (nfail > 0) THEN
    WRITE (*, '(A,I0,A)') 'FAIL: ', nfail, ' assertion(s) failed'; ERROR STOP 1
  END IF
  WRITE (*, '(A)') 'PASS: CableDyn_CosseratEMC energy-conserving integrator'
CONTAINS

  INCLUDE 'nan_max_abs.inc'
  FUNCTION strain_only(qq) RESULT(W)
    REAL(wp), INTENT(IN) :: qq(ND)
    REAL(wp) :: W, se, ke, vz(ND)
    INTEGER :: e2
    CHARACTER(200) :: m2
    vz = 0.0_wp
    CALL CD_Cosserat_Mechanical_Energy(nodes_ref, conn, ea_a, gas_a, ei_a, gj_a, ra, ita, ina, .TRUE., &
                                       qq, vz, se, ke, e2, m2, multiplicative=.TRUE.)
    W = se
  END FUNCTION strain_only

  FUNCTION total_energy(qq, vv) RESULT(E)
    !! E = strain energy (core) + lumped kinetic energy consistent with the EMC mass model:
    !!   sum_a [ 1/2 m_a |v_trans|^2 + 1/2 Omega_a . J_ref,a Omega_a ],  Omega = exp(theta)^T omega.
    REAL(wp), INTENT(IN) :: qq(ND), vv(ND)
    REAL(wp) :: E, se, ke, vz(ND), Om(3), th(3)
    INTEGER :: b, e2
    CHARACTER(200) :: m2
    vz = 0.0_wp
    CALL CD_Cosserat_Mechanical_Energy(nodes_ref, conn, ea_a, gas_a, ei_a, gj_a, ra, ita, ina, .TRUE., &
                                       qq, vz, se, ke, e2, m2, multiplicative=.TRUE.)
    E = se
    DO b = 1, NN
      th = qq(6*b - 2:6*b); Om = MATMUL(TRANSPOSE(CD_Exp_SO3(th)), vv(6*b - 2:6*b))
      E = E + 0.5_wp*mnode(b)*DOT_PRODUCT(vv(6*b - 5:6*b - 3), vv(6*b - 5:6*b - 3))
      E = E + 0.5_wp*DOT_PRODUCT(Om, MATMUL(Jref(:, :, b), Om))
    END DO
  END FUNCTION total_energy
END PROGRAM test_emc
