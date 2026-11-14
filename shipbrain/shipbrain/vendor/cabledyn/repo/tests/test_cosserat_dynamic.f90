! File: tests/test_cosserat_dynamic.f90
! SPDX-License-Identifier: Apache-2.0
! Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
PROGRAM test_cosserat_dynamic
  !! Unit checks for the finite-EI generalised-α step (CD_Cosserat_Gen_Alpha_Step)
  !! and the consistent-mass initial acceleration (CD_Cosserat_Initial_Acceleration):
  !!   (1) at-rest equilibrium is a fixed point -- a straight rod at its reference,
  !!       v = a = 0, f_ext = 0 takes a gen-α step with no spurious motion (clamped
  !!       cantilever AND free-free, the latter exercising the n_free = n_dof path
  !!       where the singular K_t is regularised by the positive-definite mass);
  !!   (2) the initial acceleration at rest with f_ext = 0 is zero;
  !!   (3) partial rotational Dirichlet is rejected.
  !! The physical first-mode period / energy-stability validation is L1-6 / L1-8.
  USE CableDyn_Precision, ONLY: wp
  USE CableDyn_CosseratDynamic, ONLY: CD_Cosserat_Gen_Alpha_Step, CD_Cosserat_Initial_Acceleration, &
                                      CD_Cosserat_Mechanical_Energy, CD_Assemble_Cosserat_Mass, &
                                      CD_Assemble_Cosserat_Mass_Banded_Free, CD_Cosserat_Mass_MatVec, &
                                      CD_CosseratGenAlphaWorkspace, CD_Clear_CosseratGenAlpha_Workspace, &
                                      CD_Reset_Cosserat_Dyn_Counts
  USE CableDyn_CosseratAssemble, ONLY: CD_Assemble_Cosserat_Internal_Force, CD_Cosserat_Free_Bandwidth
  USE CableDyn_Cosserat, ONLY: CD_Reference_Frame, CD_Cosserat_Element_Energy
  USE CableDyn_Dynamic, ONLY: GenAlphaConfig, CD_DYN_OK
  USE, INTRINSIC :: IEEE_ARITHMETIC, ONLY: IEEE_VALUE, IEEE_POSITIVE_INF
  IMPLICIT NONE

  REAL(wp), PARAMETER :: EA = 1.0e3_wp, GAS = 5.0e2_wp, EI = 2.0e2_wp, GJ = 1.5e2_wp
  REAL(wp), PARAMETER :: RHO_A = 1.0_wp, I_RHO_T = 1.0e-3_wp, I_RHO_N = 2.0e-3_wp
  INTEGER, PARAMETER :: NE = 4, NN = NE + 1, NDOF = 6*NN
  INTEGER :: nfail, i, es, n_iter, es_ws, n_iter_ws, dyn_force_count
  INTEGER :: conn(2, NE)
  REAL(wp) :: nodes_ref(3, NN), ea_a(NE), gas_a(NE), ei_a(NE), gj_a(NE)
  REAL(wp) :: ra(NE), it(NE), in_(NE)
  REAL(wp) :: q(NDOF), vel(NDOF), acc(NDOF), q_new(NDOF), v_new(NDOF), a_new(NDOF), f_ext(NDOF)
  REAL(wp) :: a_presc(NDOF), mmat(NDOF, NDOF), fint(NDOF), resid_free
  REAL(wp) :: q_ft(NDOF), v_ft(NDOF), a_ft(NDOF), a0field(NDOF), qh(NDOF), vh(NDOF), ah(NDOF)
  REAL(wp) :: q_ws(NDOF), v_ws(NDOF), a_ws(NDOF)
  REAL(wp) :: A_ACC, V0L, DTL, dx_exp, dv_exp, rig_q, rig_v, rig_a, off_q, x_mass(NDOF), y_dense(NDOF)
  REAL(wp) :: y_matvec(NDOF)
  REAL(wp), ALLOCATABLE :: Mb(:, :), Mfree(:, :), Mfrom_band(:, :)
  INTEGER, ALLOCATABLE :: free(:)
  INTEGER :: ii, kl, ku, ldab, row
  LOGICAL :: converged, stalled, converged_ws, stalled_ws
  TYPE(GenAlphaConfig) :: cfg
  TYPE(CD_CosseratGenAlphaWorkspace) :: work
  CHARACTER(120) :: em, em_ws
  nfail = 0
  dyn_force_count = 0

  DO i = 1, NN
    nodes_ref(:, i) = [0.0_wp, 0.0_wp, REAL(i - 1, wp)/REAL(NE, wp)]
  END DO
  DO i = 1, NE
    conn(:, i) = [i, i + 1]
    ea_a(i) = EA; gas_a(i) = GAS; ei_a(i) = EI; gj_a(i) = GJ
    ra(i) = RHO_A; it(i) = I_RHO_T; in_(i) = I_RHO_N
  END DO
  ! straight reference state (positions = nodes_ref, zero rotation)
  q = 0.0_wp
  DO i = 1, NN
    q(6*i - 5:6*i - 3) = nodes_ref(:, i)
  END DO
  vel = 0.0_wp; acc = 0.0_wp; f_ext = 0.0_wp

  ! (2) initial acceleration at rest, f_ext = 0 -> a0 = 0 (clamped node 1)
  CALL CD_Cosserat_Initial_Acceleration(nodes_ref, conn, ea_a, gas_a, ei_a, gj_a, ra, it, in_, &
                                        .TRUE., q, f_ext, [1, 2, 3, 4, 5, 6], acc, es, em)
  CALL require(es == CD_DYN_OK .AND. nan_max_abs(acc) < 1.0e-12_wp, 'initial-accel-zero-at-rest')

  ! (2b) prescribed-support acceleration coupling: an accelerating clamped node must enter the
  ! consistent free solve via -M_fp a_p, not be dropped. With f_ext = 0 and a straight (fint = 0)
  ! state the free equations reduce to M(free,:) a = 0, so a nonzero support acceleration MUST
  ! drive nonzero interior accelerations while the free-row residual stays at the solver floor;
  ! a_prescribed absent would leave a(free) = 0 on the motionFile path.
  a_presc = 0.0_wp
  a_presc(1) = 0.7_wp; a_presc(2) = -0.4_wp; a_presc(3) = 0.3_wp   ! clamped-node translational accel
  acc = 0.0_wp
  CALL CD_Cosserat_Initial_Acceleration(nodes_ref, conn, ea_a, gas_a, ei_a, gj_a, ra, it, in_, &
                                        .TRUE., q, f_ext, [1, 2, 3, 4, 5, 6], acc, es, em, &
                                        a_prescribed=a_presc)
  CALL require(es == CD_DYN_OK, 'prescribed-accel:errstat')
  a_ws = 0.0_wp
  CALL CD_Cosserat_Initial_Acceleration(nodes_ref, conn, ea_a, gas_a, ei_a, gj_a, ra, it, in_, &
                                        .TRUE., q, f_ext, [1, 2, 3, 4, 5, 6], a_ws, es_ws, em_ws, &
                                        a_prescribed=a_presc, workspace=work)
  CALL require(es_ws == CD_DYN_OK .AND. nan_max_abs(a_ws - acc) < 1.0e-14_wp, &
               'initial-workspace:matches-legacy')
  CALL require(ALLOCATED(work%assembly%fe), 'initial-workspace:assembly-force-workspace')
  CALL require(nan_max_abs(acc(1:6) - a_presc(1:6)) < 1.0e-14_wp, 'prescribed-accel:fixed-slots-set')
  CALL require(nan_max_abs(acc(7:NDOF)) > 1.0e-6_wp, 'prescribed-accel:coupling-drives-interior')
  CALL CD_Assemble_Cosserat_Mass(nodes_ref, conn, ra, it, in_, mmat, es, em)
  CALL require(es == 0, 'prescribed-accel:mass-assembled')
  ALLOCATE (free(NDOF - 6))
  DO ii = 1, SIZE(free)
    free(ii) = ii + 6
  END DO
  CALL CD_Cosserat_Free_Bandwidth(conn, NN, free, kl, ku, es, em)
  CALL require(es == 0, 'mass-band:bandwidth')
  ldab = 2*kl + ku + 1
  ALLOCATE (Mb(ldab, SIZE(free)), Mfree(SIZE(free), SIZE(free)), Mfrom_band(SIZE(free), SIZE(free)))
  CALL CD_Assemble_Cosserat_Mass_Banded_Free(nodes_ref, conn, ra, it, in_, free, kl, ku, Mb, es, em)
  CALL require(es == 0, 'mass-band:assemble')
  Mfree = mmat(free, free)
  Mfrom_band = 0.0_wp
  DO i = 1, SIZE(free)
    DO ii = MAX(1, i - ku), MIN(SIZE(free), i + kl)
      row = kl + ku + 1 + ii - i
      Mfrom_band(ii, i) = Mb(row, i)
    END DO
  END DO
  CALL require(nan_max_abs(Mfrom_band - Mfree) < 1.0e-14_wp, 'mass-band:matches-dense-free-block')
  DO ii = 1, NDOF
    x_mass(ii) = 0.01_wp*REAL(ii, wp) - 0.2_wp
  END DO
  y_dense = MATMUL(mmat, x_mass)
  CALL CD_Cosserat_Mass_MatVec(nodes_ref, conn, ra, it, in_, x_mass, y_matvec, es, em)
  CALL require(es == 0 .AND. nan_max_abs(y_matvec - y_dense) < 1.0e-14_wp, 'mass-matvec:matches-dense')
  CALL CD_Assemble_Cosserat_Internal_Force(nodes_ref, conn, ea_a, gas_a, ei_a, gj_a, q, .TRUE., fint, es, em)
  CALL require(es == 0, 'prescribed-accel:fint-assembled')
  resid_free = nan_max_abs(MATMUL(mmat(7:NDOF, :), acc) - (f_ext(7:NDOF) - fint(7:NDOF)))
  CALL require(resid_free < 1.0e-9_wp, 'prescribed-accel:free-rows-consistent (M a = f - fint)')

  ! (2c) moving-support gen-alpha contract: a rigidly ACCELERATING translating rod whose clamped
  ! support (node 1) is prescribed to follow its trajectory must stay strain-free -- the whole rod
  ! translates rigidly. This exercises both v_fixed_target and (crucially) a_fixed_target, whose
  ! M_fp coupling enters the free residual. With f_ext = M a0 (the consistent rigid-accel inertial
  ! load), the exact solution is x_i(t+dt) = x_i + dt V0 + 1/2 dt^2 A for EVERY node. A held support
  ! (no targets) instead pins node 1 and the rod strains -- the discrimination check below.
  A_ACC = 0.3_wp; V0L = 0.1_wp; DTL = 0.05_wp
  a0field = 0.0_wp
  DO ii = 1, NN
    a0field(6*ii - 5) = A_ACC          ! uniform x-translation acceleration field
  END DO
  CALL CD_Assemble_Cosserat_Mass(nodes_ref, conn, ra, it, in_, mmat, es, em)
  CALL require(es == 0, 'moving-support:mass-assembled')
  f_ext = MATMUL(mmat, a0field)        ! inertial load making rigid accel A_ACC the free motion
  vel = 0.0_wp; acc = 0.0_wp
  DO ii = 1, NN
    vel(6*ii - 5) = V0L                 ! uniform x-velocity at t_n
    acc(6*ii - 5) = A_ACC               ! uniform x-acceleration at t_n (a_n(fixed) kept)
  END DO
  dx_exp = DTL*V0L + 0.5_wp*DTL*DTL*A_ACC
  dv_exp = DTL*A_ACC
  q_ft = q; v_ft = 0.0_wp; a_ft = 0.0_wp
  q_ft(1) = q(1) + dx_exp               ! node-1 x prescribed to its t_{n+1} target
  v_ft(1) = V0L + dv_exp
  a_ft(1) = A_ACC
  CALL CD_Cosserat_Gen_Alpha_Step(nodes_ref, conn, ea_a, gas_a, ei_a, gj_a, ra, it, in_, .TRUE., &
                                  q, vel, acc, f_ext, [1, 2, 3, 4, 5, 6], DTL, cfg, &
                                  q_new, v_new, a_new, converged, stalled, n_iter, es, em, &
                                  q_fixed_target=q_ft, v_fixed_target=v_ft, a_fixed_target=a_ft)
  CALL require(es == CD_DYN_OK .AND. converged .AND. .NOT. stalled, 'moving-support:step-converged')
  CALL CD_Cosserat_Gen_Alpha_Step(nodes_ref, conn, ea_a, gas_a, ei_a, gj_a, ra, it, in_, .TRUE., &
                                  q, vel, acc, f_ext, [1, 2, 3, 4, 5, 6], DTL, cfg, &
                                  q_ws, v_ws, a_ws, converged_ws, stalled_ws, n_iter_ws, es_ws, em_ws, &
                                  q_fixed_target=q_ft, v_fixed_target=v_ft, a_fixed_target=a_ft, workspace=work)
  CALL require(es_ws == CD_DYN_OK .AND. converged_ws .EQV. converged .AND. stalled_ws .EQV. stalled .AND. &
               n_iter_ws == n_iter, 'workspace:status-matches-legacy')
  CALL require(nan_max_abs(q_ws - q_new) < 1.0e-14_wp .AND. nan_max_abs(v_ws - v_new) < 1.0e-14_wp .AND. &
               nan_max_abs(a_ws - a_new) < 1.0e-14_wp, 'workspace:state-matches-legacy')
  CALL require(ALLOCATED(work%q_n) .AND. ALLOCATED(work%eff_band) .AND. ALLOCATED(work%assembly%Ke), &
               'workspace:allocated-after-step')
  CALL CD_Clear_CosseratGenAlpha_Workspace(work)
  CALL require(.NOT. ALLOCATED(work%q_n) .AND. .NOT. ALLOCATED(work%eff_band) .AND. &
               .NOT. ALLOCATED(work%assembly%Ke), 'workspace:clear-releases')
  rig_q = 0.0_wp; rig_v = 0.0_wp; rig_a = 0.0_wp; off_q = 0.0_wp
  DO ii = 1, NN
    rig_q = MAX(rig_q, ABS(q_new(6*ii - 5) - (q(6*ii - 5) + dx_exp)))   ! every node x translated
    rig_v = MAX(rig_v, ABS(v_new(6*ii - 5) - (V0L + dv_exp)))
    rig_a = MAX(rig_a, ABS(a_new(6*ii - 5) - A_ACC))
    off_q = MAX(off_q, ABS(q_new(6*ii - 4) - q(6*ii - 4)), ABS(q_new(6*ii - 3) - q(6*ii - 3)))  ! y,z fixed
  END DO
  CALL require(rig_q < 1.0e-8_wp, 'moving-support:rigid-x-translation (all nodes follow)')
  CALL require(rig_v < 1.0e-7_wp, 'moving-support:rigid-x-velocity')
  CALL require(rig_a < 1.0e-7_wp, 'moving-support:rigid-x-acceleration')
  CALL require(off_q < 1.0e-9_wp, 'moving-support:no-transverse-drift')

  ! Discrimination: the HELD step (no targets) pins node 1 and does NOT translate it rigidly.
  CALL CD_Cosserat_Gen_Alpha_Step(nodes_ref, conn, ea_a, gas_a, ei_a, gj_a, ra, it, in_, .TRUE., &
                                  q, vel, acc, f_ext, [1, 2, 3, 4, 5, 6], DTL, cfg, &
                                  qh, vh, ah, converged, stalled, n_iter, es, em)
  CALL require(es == CD_DYN_OK, 'moving-support:held-step-ok')
  CALL require(ABS(qh(1) - q(1)) < 1.0e-12_wp, 'moving-support:held-pins-support')
  CALL require(ABS(q_new(1) - q(1) - dx_exp) < 1.0e-8_wp, 'moving-support:moving-advances-support')
  vel = 0.0_wp; acc = 0.0_wp; f_ext = 0.0_wp   ! restore the rest state for the cases below

  ! (1a) fixed point: clamped cantilever, at rest, f_ext = 0 -> no motion
  acc = 0.0_wp
  CALL CD_Cosserat_Gen_Alpha_Step(nodes_ref, conn, ea_a, gas_a, ei_a, gj_a, ra, it, in_, .TRUE., &
                                  q, vel, acc, f_ext, [1, 2, 3, 4, 5, 6], 0.05_wp, cfg, &
                                  q_new, v_new, a_new, converged, stalled, n_iter, es, em)
  CALL require(es == CD_DYN_OK .AND. converged, 'clamped:step-converged')
  CALL require(nan_max_abs(q_new - q) < 1.0e-12_wp .AND. nan_max_abs(v_new) < 1.0e-12_wp .AND. &
               nan_max_abs(a_new) < 1.0e-12_wp, 'clamped:at-rest-fixed-point')
  CALL check_dynamic_force_callback()

  ! (1b) fixed point: FREE-FREE (no fixed DOFs), at rest -> no motion. Exercises
  ! n_free = n_dof, where K_t is singular (rigid modes) but the effective tangent
  ! (1-am)/(beta dt^2) M + (1-af) K_t stays positive-definite via the mass.
  CALL CD_Cosserat_Gen_Alpha_Step(nodes_ref, conn, ea_a, gas_a, ei_a, gj_a, ra, it, in_, .TRUE., &
                                  q, vel, acc, f_ext, [INTEGER ::], 0.05_wp, cfg, &
                                  q_new, v_new, a_new, converged, stalled, n_iter, es, em)
  CALL require(es == CD_DYN_OK .AND. converged, 'free-free:step-converged')
  CALL require(nan_max_abs(q_new - q) < 1.0e-12_wp .AND. nan_max_abs(v_new) < 1.0e-12_wp, &
               'free-free:at-rest-fixed-point')

  ! (1c) modified Newton is opt-in and must preserve the same fixed-point contract.
  cfg%modified_newton = .TRUE.
  CALL CD_Cosserat_Gen_Alpha_Step(nodes_ref, conn, ea_a, gas_a, ei_a, gj_a, ra, it, in_, .TRUE., &
                                  q, vel, acc, f_ext, [INTEGER ::], 0.05_wp, cfg, &
                                  q_new, v_new, a_new, converged, stalled, n_iter, es, em)
  CALL require(es == CD_DYN_OK .AND. converged, 'modified-newton:step-converged')
  CALL require(nan_max_abs(q_new - q) < 1.0e-12_wp .AND. nan_max_abs(v_new) < 1.0e-12_wp, &
               'modified-newton:at-rest-fixed-point')
  cfg%modified_newton = .FALSE.
  CALL check_modified_newton_reuses_tangent()

  ! (3) partial rotational Dirichlet rejected (fix node-1 theta_x only)
  CALL CD_Cosserat_Gen_Alpha_Step(nodes_ref, conn, ea_a, gas_a, ei_a, gj_a, ra, it, in_, .TRUE., &
                                  q, vel, acc, f_ext, [1, 2, 3, 4], 0.05_wp, cfg, &
                                  q_new, v_new, a_new, converged, stalled, n_iter, es, em)
  CALL require(es /= CD_DYN_OK .AND. .NOT. converged, 'reject:partial-rotational-dirichlet')

  ! (3b) multiplicative-SO(3) rotation update (kinematics): the at-rest straight
  ! rod is a fixed point on the multiplicative path too (psi = 0 -> compose returns
  ! theta_n), and a prescribed moving support is not yet supported on this path -> rejects.
  cfg%multiplicative_rotation = .TRUE.
  CALL CD_Cosserat_Gen_Alpha_Step(nodes_ref, conn, ea_a, gas_a, ei_a, gj_a, ra, it, in_, .TRUE., &
                                  q, vel, acc, f_ext, [INTEGER ::], 0.05_wp, cfg, &
                                  q_new, v_new, a_new, converged, stalled, n_iter, es, em)
  CALL require(es == CD_DYN_OK .AND. converged, 'multiplicative:at-rest-step-converged')
  CALL require(nan_max_abs(q_new - q) < 1.0e-12_wp .AND. nan_max_abs(v_new) < 1.0e-12_wp, &
               'multiplicative:at-rest-fixed-point')
  CALL CD_Cosserat_Gen_Alpha_Step(nodes_ref, conn, ea_a, gas_a, ei_a, gj_a, ra, it, in_, .TRUE., &
                                  q, vel, acc, f_ext, [1, 2, 3, 4, 5, 6], 0.05_wp, cfg, &
                                  q_new, v_new, a_new, converged, stalled, n_iter, es, em, &
                                  q_fixed_target=q, v_fixed_target=vel, a_fixed_target=acc)
  CALL require(es /= CD_DYN_OK .AND. .NOT. converged, 'reject:multiplicative-with-moving-support')

  ! (3c) Review hardening: the multiplicative path must validate the composed END-OF-STEP candidate,
  ! not just the (1-af) alpha-blend pose. compose() always wraps each node into the |theta|<pi
  ! chart, so the only candidate failure is a relative rotation at the log-singular window
  ! (~5e-7 of pi). Spinning adjacent end nodes to +/- pi/2 (dt*omega = pi/2 with a_n = 0) makes
  ! the predictor candidate's relative rotation exactly pi (singular) while each node sits at
  ! pi/2 (in chart) and the (1-af) blend relative stays ~1.7 (safe) -- the blend would hide it.
  ! The step must fail closed and echo t_n rather than return a q_new the next step rejects.
  a_ft = 0.0_wp; v_ft = 0.0_wp
  v_ft(6*(NN - 1) - 2) = 1.5707963267948966_wp/0.05_wp    ! node NN-1: dt*omega = +pi/2
  v_ft(6*NN - 2) = -1.5707963267948966_wp/0.05_wp         ! node NN:   dt*omega = -pi/2 -> relative pi
  CALL CD_Cosserat_Gen_Alpha_Step(nodes_ref, conn, ea_a, gas_a, ei_a, gj_a, ra, it, in_, .TRUE., &
                                  q, v_ft, a_ft, f_ext, [INTEGER ::], 0.05_wp, cfg, &
                                  q_new, v_new, a_new, converged, stalled, n_iter, es, em)
  CALL require(es /= CD_DYN_OK .AND. .NOT. converged, 'reject:multiplicative-singular-candidate')
  CALL require(nan_max_abs(q_new - q) < 1.0e-14_wp, 'multiplicative-singular-candidate:echoes-tn')

  ! (3d) Review hardening: a dynamic load callback on the multiplicative path is not yet supported
  ! (its rotational load-stiffness columns need the same J_c chain as the structural tangent)
  ! -> fail closed instead of running an inconsistent effective tangent.
  CALL CD_Cosserat_Gen_Alpha_Step(nodes_ref, conn, ea_a, gas_a, ei_a, gj_a, ra, it, in_, .TRUE., &
                                  q, vel, acc, f_ext, [INTEGER ::], 0.02_wp, cfg, &
                                  q_new, v_new, a_new, converged, stalled, n_iter, es, em, &
                                  load_force_proc=small_tip_dynamic_force)
  CALL require(es /= CD_DYN_OK .AND. .NOT. converged, 'reject:multiplicative-with-load-callback')
  cfg%multiplicative_rotation = .FALSE.

  ! (4) element strain energy vs the reference + mechanical-energy diagnostic
  CALL check_energy()

  ! (5) fail-closed: the gen-α step rejects every invalid input with ErrStat /= 0
  ! AND echoes the t_n state (q_new = q) so a caller can retry from a valid state
  CALL check_step_fail_closed()

  IF (nfail > 0) THEN
    WRITE (*, '(A,I0,A)') 'FAIL: ', nfail, ' assertion(s) failed'
    ERROR STOP 1
  END IF
  WRITE (*, '(A)') 'PASS: Fortran finite-EI gen-alpha step is well-formed (fixed point + rejections)'

CONTAINS

  INCLUDE 'nan_max_abs.inc'

  SUBROUTINE check_step_fail_closed()
    !! Every invalid input must return ErrStat /= 0 (not converged). For failures
    !! AFTER the finiteness check, the t_n state must also be echoed (q_new = q,
    !! the retryable-state contract). Covers the gen-α input validation
    !! (non-finite state, bad dt, bad config) plus the finite-EI domain guards
    !! (non-positive stiffness/inertia, zero-length span, out-of-chart rotation).
    REAL(wp) :: bad_q(NDOF), bad_nref(3, NN), inf, bad_ea(NE), bad_ra(NE)
    TYPE(GenAlphaConfig) :: badcfg
    inf = IEEE_VALUE(1.0_wp, IEEE_POSITIVE_INF)
    bad_ea = ea_a; bad_ea(1) = -1.0_wp
    bad_ra = ra; bad_ra(1) = -1.0_wp
    bad_nref = nodes_ref; bad_nref(:, 2) = nodes_ref(:, 1)   ! collapse node 2 -> L0 = 0
    bad_q = q; bad_q(9) = inf                                ! non-finite q

    ! non-finite q fails AT the finiteness check (before the echo) -> no echo
    CALL step_expect_fail(nodes_ref, ea_a, ra, bad_q, 0.05_wp, cfg, .FALSE., 'reject:non-finite-q')
    ! the rest fail AFTER the t_n echo -> q_new must equal q
    CALL step_expect_fail(nodes_ref, ea_a, ra, q, 0.0_wp, cfg, .TRUE., 'reject:dt-zero')
    CALL step_expect_fail(nodes_ref, ea_a, ra, q, -0.05_wp, cfg, .TRUE., 'reject:dt-negative')
    badcfg = cfg; badcfg%rho_inf = 1.5_wp
    CALL step_expect_fail(nodes_ref, ea_a, ra, q, 0.05_wp, badcfg, .TRUE., 'reject:bad-rho-inf')
    CALL step_expect_fail(nodes_ref, bad_ea, ra, q, 0.05_wp, cfg, .TRUE., 'reject:non-positive-EA')
    CALL step_expect_fail(nodes_ref, ea_a, bad_ra, q, 0.05_wp, cfg, .TRUE., 'reject:non-positive-rhoA')
    CALL step_expect_fail(bad_nref, ea_a, ra, q, 0.05_wp, cfg, .TRUE., 'reject:zero-length-span')
    bad_q = q; bad_q(10) = 3.5_wp                            ! theta_2x > pi (out of chart)
    CALL step_expect_fail(nodes_ref, ea_a, ra, bad_q, 0.05_wp, cfg, .TRUE., 'reject:out-of-chart-rotation')
    ! both nodal rotations IN chart (|theta| = pi/2) but element 1-2 relative
    ! rotation is pi (log-singular): the chart-only check would miss it, but the
    ! shared per-element contract (chart + singular) must reject it before the
    ! alpha-blend can hide it -> fail closed, q_n echoed
    bad_q = q; bad_q(4) = 1.5707963267948966_wp; bad_q(10) = -1.5707963267948966_wp
    CALL step_expect_fail(nodes_ref, ea_a, ra, bad_q, 0.05_wp, cfg, .TRUE., 'reject:singular-relative-rotation')
  END SUBROUTINE check_step_fail_closed

  SUBROUTINE check_dynamic_force_callback()
    !! Finite-EI external dynamic force callbacks must be evaluated inside the
    !! generalized-alpha residual/line-search path, not frozen before the step.
    REAL(wp) :: qo(NDOF), vo(NDOF), ao(NDOF)
    INTEGER :: es_l, nit_l
    LOGICAL :: cvg, stl
    CHARACTER(120) :: em_l

    dyn_force_count = 0
    CALL CD_Cosserat_Gen_Alpha_Step(nodes_ref, conn, ea_a, gas_a, ei_a, gj_a, ra, it, in_, .TRUE., &
                                    q, vel, acc, f_ext, [1, 2, 3, 4, 5, 6], 0.02_wp, cfg, &
                                    qo, vo, ao, cvg, stl, nit_l, es_l, em_l, &
                                    load_force_proc=small_tip_dynamic_force)
    CALL require(es_l == CD_DYN_OK .AND. cvg .AND. .NOT. stl, 'dynamic-force-callback:converged')
    CALL require(dyn_force_count > 0, 'dynamic-force-callback:called')
    CALL require(ABS(qo(15) - q(15)) > 1.0e-10_wp, 'dynamic-force-callback:moves-tip')
  END SUBROUTINE check_dynamic_force_callback

  SUBROUTINE small_tip_dynamic_force(qin, vin, force, ErrStat, ErrMsg)
    REAL(wp), INTENT(IN) :: qin(:), vin(:)
    REAL(wp), INTENT(OUT) :: force(:)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg

    dyn_force_count = dyn_force_count + 1
    force = 0.0_wp
    ErrStat = CD_DYN_OK
    ErrMsg = ''
    IF (SIZE(qin) /= NDOF .OR. SIZE(vin) /= NDOF .OR. SIZE(force) /= NDOF) THEN
      ErrStat = 1
      ErrMsg = 'small_tip_dynamic_force: shape mismatch'
      RETURN
    END IF
    force(15) = -0.05_wp - 0.1_wp*vin(15)
  END SUBROUTINE small_tip_dynamic_force

  SUBROUTINE check_modified_newton_reuses_tangent()
    !! Modified Newton is a finite-EI performance option: after a fresh tangent
    !! assembly it may try the stale tangent for later residual evaluations in
    !! the same step. The test is intentionally nonlinear enough to require a
    !! stale-tangent attempt; a regression that refreshes before every solve
    !! leaves the stale counters at zero and fails here.
    REAL(wp) :: q0(NDOF), v0(NDOF), a_init(NDOF), f_load(NDOF), zeta, amp, dqmax, dvmax, damax
    REAL(wp) :: q_full(NDOF), v_full(NDOF), a_full(NDOF)
    REAL(wp) :: q_mod(NDOF), v_mod(NDOF), a_mod(NDOF)
    TYPE(GenAlphaConfig) :: cfg_full, cfg_mod
    INTEGER :: es_l, nit_full, nit_mod
    LOGICAL :: cvg_full, stl_full, cvg_mod, stl_mod
    CHARACTER(120) :: em_l
    TYPE(CD_CosseratGenAlphaWorkspace) :: mod_work

    amp = 2.0e-3_wp
    q0 = q
    DO ii = 1, NN
      zeta = nodes_ref(3, ii)
      q0(6*ii - 5) = q0(6*ii - 5) + amp*SIN(3.141592653589793_wp*zeta)
      q0(6*ii - 2) = q0(6*ii - 2) + amp*3.141592653589793_wp*COS(3.141592653589793_wp*zeta)
    END DO
    v0 = 0.0_wp
    f_load = 0.0_wp

    cfg_full = cfg
    cfg_full%abs_tol = 1.0e-11_wp
    cfg_full%rel_tol = 1.0e-10_wp
    cfg_full%max_iter = 120
    cfg_full%modified_newton = .FALSE.
    cfg_mod = cfg_full
    cfg_mod%modified_newton = .TRUE.

    CALL CD_Cosserat_Initial_Acceleration(nodes_ref, conn, ea_a, gas_a, ei_a, gj_a, ra, it, in_, &
                                          .TRUE., q0, f_load, [INTEGER ::], a_init, es_l, em_l)
    CALL require(es_l == CD_DYN_OK, 'cosserat-mod-newton:init-accel')

    CALL CD_Cosserat_Gen_Alpha_Step(nodes_ref, conn, ea_a, gas_a, ei_a, gj_a, ra, it, in_, .TRUE., &
                                    q0, v0, a_init, f_load, [INTEGER ::], 0.02_wp, cfg_full, &
                                    q_full, v_full, a_full, cvg_full, stl_full, nit_full, es_l, em_l)
    CALL require(es_l == CD_DYN_OK .AND. cvg_full .AND. .NOT. stl_full, 'cosserat-mod-newton:full-converged')

    CALL CD_Reset_Cosserat_Dyn_Counts(mod_work)
    CALL CD_Cosserat_Gen_Alpha_Step(nodes_ref, conn, ea_a, gas_a, ei_a, gj_a, ra, it, in_, .TRUE., &
                                    q0, v0, a_init, f_load, [INTEGER ::], 0.02_wp, cfg_mod, &
                                    q_mod, v_mod, a_mod, cvg_mod, stl_mod, nit_mod, es_l, em_l, &
                                    workspace=mod_work)
    CALL require(es_l == CD_DYN_OK .AND. cvg_mod .AND. .NOT. stl_mod, 'cosserat-mod-newton:modified-converged')
    CALL require(mod_work%n_stale_accept + mod_work%n_stale_reject > 0, &
                 'cosserat-mod-newton:stale-tangent-attempted')
    CALL require(mod_work%n_deferred_refresh == 0, 'cosserat-mod-newton:no-pre-solve-refresh')
    CALL CD_Clear_CosseratGenAlpha_Workspace(mod_work)
    dqmax = nan_max_abs(q_mod - q_full)
    dvmax = nan_max_abs(v_mod - v_full)
    damax = nan_max_abs(a_mod - a_full)
    IF (.NOT. (dqmax < 1.0e-8_wp .AND. dvmax < 1.0e-6_wp .AND. damax < 1.0e-4_wp)) THEN
      WRITE (*, '(A,3(1X,ES12.4))') 'cosserat-mod-newton diffs:', dqmax, dvmax, damax
    END IF
    CALL require(dqmax < 1.0e-8_wp .AND. dvmax < 1.0e-6_wp .AND. damax < 1.0e-4_wp, &
                 'cosserat-mod-newton:matches-full-newton')
    CALL require(nit_mod <= cfg_mod%max_iter, 'cosserat-mod-newton:iteration-bound')
  END SUBROUTINE check_modified_newton_reuses_tangent

  SUBROUTINE step_expect_fail(nref, ea_i, ra_i, qin, dt_i, cfg_i, expect_echo, label)
    REAL(wp), INTENT(IN) :: nref(3, NN), ea_i(NE), ra_i(NE), qin(NDOF), dt_i
    TYPE(GenAlphaConfig), INTENT(IN) :: cfg_i
    LOGICAL, INTENT(IN) :: expect_echo
    CHARACTER(*), INTENT(IN) :: label
    REAL(wp) :: vn(NDOF), an(NDOF), qo(NDOF), vo(NDOF), ao(NDOF)
    INTEGER :: es_l, nit_l
    LOGICAL :: cvg, stl
    CHARACTER(120) :: em_l
    vn = 0.0_wp; an = 0.0_wp
    CALL CD_Cosserat_Gen_Alpha_Step(nref, conn, ea_i, gas_a, ei_a, gj_a, ra_i, it, in_, .TRUE., &
                                    qin, vn, an, f_ext, [1, 2, 3, 4, 5, 6], dt_i, cfg_i, qo, vo, ao, &
                                    cvg, stl, nit_l, es_l, em_l)
    CALL require(es_l /= CD_DYN_OK .AND. .NOT. cvg, label)
    IF (expect_echo) CALL require(nan_max_abs(qo - qin) < 1.0e-30_wp, label//':echoes-tn')
  END SUBROUTINE step_expect_fail

  SUBROUTINE check_energy()
    !! Element strain energy vs the reference (config A from the force test: z-aligned
    !! reference, EA=1e3/GAs=5e2/EI=2e2/GJ=1.5e2, reduced shear), and the global
    !! mechanical-energy diagnostic (kinetic = 0 at rest; strain = element sum).
    REAL(wp) :: Lam0(3, 3), L0e, qA(12), UA
    REAL(wp) :: nref2(3, 2), q2(12), v2(12), strain_e, kinetic_e, vt(12)
    INTEGER :: conn1(2, 1), es2
    CHARACTER(120) :: em2
    CALL CD_Reference_Frame([0.0_wp, 0.0_wp, 0.0_wp], [0.0_wp, 0.0_wp, 2.0_wp], Lam0, L0e)
    qA = [0.0_wp, 0.0_wp, 0.0_wp, 0.05_wp, -0.03_wp, 0.02_wp, &
          0.1_wp, 0.2_wp, 2.1_wp, -0.04_wp, 0.06_wp, -0.01_wp]
    UA = CD_Cosserat_Element_Energy(qA, 1.0e3_wp, 5.0e2_wp, 2.0e2_wp, 1.5e2_wp, Lam0, L0e, .TRUE.)
    CALL require(ABS(UA - 9.418262475481793_wp) < 1.0e-9_wp, 'element-energy-vs-reference')

    ! single-element mechanical energy: strain = element energy; kinetic = 1/2 v^T M v
    nref2(:, 1) = [0.0_wp, 0.0_wp, 0.0_wp]; nref2(:, 2) = [0.0_wp, 0.0_wp, 2.0_wp]
    conn1(:, 1) = [1, 2]
    q2 = qA
    v2 = 0.0_wp
    CALL CD_Cosserat_Mechanical_Energy(nref2, conn1, [1.0e3_wp], [5.0e2_wp], [2.0e2_wp], [1.5e2_wp], &
                                       [1.0_wp], [1.0e-3_wp], [2.0e-3_wp], .TRUE., q2, v2, &
                                       strain_e, kinetic_e, es2, em2)
    CALL require(es2 == CD_DYN_OK .AND. ABS(strain_e - 9.418262475481793_wp) < 1.0e-9_wp .AND. &
                 ABS(kinetic_e) < 1.0e-30_wp, 'mechanical-energy-at-rest')
    ! kinetic > 0 with a nonzero velocity
    vt = 0.0_wp; vt(1) = 1.0_wp; vt(7) = 1.0_wp     ! rigid x-velocity of both nodes
    CALL CD_Cosserat_Mechanical_Energy(nref2, conn1, [1.0e3_wp], [5.0e2_wp], [2.0e2_wp], [1.5e2_wp], &
                                       [1.0_wp], [1.0e-3_wp], [2.0e-3_wp], .TRUE., q2, vt, &
                                       strain_e, kinetic_e, es2, em2)
    ! rigid x-velocity 1 of a rho_A=1, L0=2 rod: KE = 1/2 * (rho_A L0) * 1^2 = 1.0
    CALL require(es2 == CD_DYN_OK .AND. ABS(kinetic_e - 1.0_wp) < 1.0e-12_wp, 'kinetic-energy-rigid-velocity')

    ! fail closed on a stiffness array of the wrong length (n_elem = 1, ea length 0)
    strain_e = -1.0_wp
    CALL CD_Cosserat_Mechanical_Energy(nref2, conn1, [REAL(wp) ::], [5.0e2_wp], [2.0e2_wp], [1.5e2_wp], &
                                       [1.0_wp], [1.0e-3_wp], [2.0e-3_wp], .TRUE., q2, v2, &
                                       strain_e, kinetic_e, es2, em2)
    CALL require(es2 /= CD_DYN_OK .AND. ABS(strain_e) < 1.0e-30_wp, 'energy:reject-short-stiffness')
    ! fail closed on a non-positive stiffness value (EI <= 0)
    strain_e = -1.0_wp
    CALL CD_Cosserat_Mechanical_Energy(nref2, conn1, [1.0e3_wp], [5.0e2_wp], [-2.0e2_wp], [1.5e2_wp], &
                                       [1.0_wp], [1.0e-3_wp], [2.0e-3_wp], .TRUE., q2, v2, &
                                       strain_e, kinetic_e, es2, em2)
    CALL require(es2 /= CD_DYN_OK .AND. ABS(strain_e) < 1.0e-30_wp, 'energy:reject-non-positive-stiffness')
    ! fail closed on an out-of-chart nodal rotation (the direct element-energy call
    ! bypasses the force/tangent chart check, so the wrapper must enforce it)
    strain_e = -1.0_wp
    q2 = qA; q2(10) = 3.5_wp                  ! theta_2x > pi (out of chart)
    CALL CD_Cosserat_Mechanical_Energy(nref2, conn1, [1.0e3_wp], [5.0e2_wp], [2.0e2_wp], [1.5e2_wp], &
                                       [1.0_wp], [1.0e-3_wp], [2.0e-3_wp], .TRUE., q2, v2, &
                                       strain_e, kinetic_e, es2, em2)
    CALL require(es2 /= CD_DYN_OK .AND. ABS(strain_e) < 1.0e-30_wp, 'energy:reject-out-of-chart')
    ! fail closed on a log-singular relative rotation: both nodal rotations are IN
    ! chart (|theta| = pi/2 each) but their relative rotation is pi (the force/
    ! tangent path rejects this; the energy diagnostic must mirror it via the
    ! shared CD_Cosserat_Validate_Rotation_State)
    strain_e = -1.0_wp; kinetic_e = -1.0_wp
    q2 = 0.0_wp; q2(3) = 0.0_wp; q2(9) = 2.0_wp     ! straight reference along z
    q2(4) = 1.5707963267948966_wp; q2(10) = -1.5707963267948966_wp
    CALL CD_Cosserat_Mechanical_Energy(nref2, conn1, [1.0e3_wp], [5.0e2_wp], [2.0e2_wp], [1.5e2_wp], &
                                       [1.0_wp], [1.0e-3_wp], [2.0e-3_wp], .TRUE., q2, v2, &
                                       strain_e, kinetic_e, es2, em2)
    CALL require(es2 /= CD_DYN_OK .AND. ABS(strain_e) < 1.0e-30_wp .AND. ABS(kinetic_e) < 1.0e-30_wp, &
                 'energy:reject-singular-relative-rotation')
  END SUBROUTINE check_energy

  SUBROUTINE require(cond, label)
    LOGICAL, INTENT(IN) :: cond
    CHARACTER(*), INTENT(IN) :: label
    IF (.NOT. cond) THEN
      WRITE (*, '(A,A,A)') 'MISMATCH [', label, ']: condition false'
      nfail = nfail + 1
    END IF
  END SUBROUTINE require

END PROGRAM test_cosserat_dynamic
