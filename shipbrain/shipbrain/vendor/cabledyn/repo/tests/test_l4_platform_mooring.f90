! File: tests/test_l4_platform_mooring.f90
! SPDX-License-Identifier: Apache-2.0
! Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
PROGRAM test_l4_platform_mooring
  !! L4-1 coupled body6 platform + EI=0 mooring static equilibrium (synthetic gate). A 6-DOF
  !! platform moored by 3 taut catenary lines 120 deg apart -- each attached at a fairlead
  !! offset, feeding a full 6-DOF wrench [F, ell x F] back through the 0c transfer -- is
  !! solved by the coupled augmented Newton (CableDyn_CoupledPlatform). The symmetric
  !! configuration has an analytic signature:
  !!   1. the coupled 6-DOF Newton converges;
  !!   2. the platform stays centred (surge=sway=0) and upright (roll=pitch=yaw=0);
  !!   3. the three fairlead tensions are equal (magnitude + vertical pull);
  !!   4. the platform heaves DOWN to where the hydrostatic restoring carries the net
  !!      vertical mooring pull (-C33 z = sum g_z).
  !!
  !! Regression targets from an independent implementation of the same equilibrium (not part of
  !! the repository):
  !!   pose_z = -0.40271166681204623 m; |g| = 21884.092118268 N; g_z = 16191.934706089 N.
  !! Inner fairlead Schur solve (phi=0, taut), reference g + K_fair, also FD-checked here.
  USE CableDyn_Precision, ONLY: wp
  USE CableDyn_Static, ONLY: CableSolverConfig
  USE CableDyn_SO3, ONLY: CD_Compose_Rotvec
  USE CableDyn_CoupledPlatform, ONLY: CD_Fairlead_Solve, CD_Platform_Residual_Tangent, &
                                      CD_Solve_Platform_Mooring, CD_PLAT_OK
  IMPLICIT NONE

  REAL(wp), PARAMETER :: RHO = 1025.0_wp, G = 9.80665_wp, PI = 3.14159265358979323846_wp
  INTEGER, PARAMETER :: N_ELEM = 10, N_LINES = 3, NDOF_P = 3*(N_ELEM + 1)
  REAL(wp), PARAMETER :: R_ANCHOR = 60.0_wp, Z_ANCHOR = -50.0_wp
  REAL(wp), PARAMETER :: R_FAIR = 8.0_wp, Z_FAIR = -5.0_wp
  REAL(wp), PARAMETER :: W_SUB = 100.0_wp, EA_V = 1.0e6_wp, REST_FACTOR = 0.98_wp
  REAL(wp), PARAMETER :: C33 = RHO*G*12.0_wp
  REAL(wp), PARAMETER :: PHIS(3) = [0.0_wp, 2.0_wp*PI/3.0_wp, 4.0_wp*PI/3.0_wp]
  ! reference parity targets.
  REAL(wp), PARAMETER :: reference_POSE_Z = -0.40271166681204623_wp
  REAL(wp), PARAMETER :: reference_MAG = 21884.092118268367_wp
  REAL(wp), PARAMETER :: reference_GZ = 16191.934706088636_wp
  REAL(wp), PARAMETER :: reference_G0(3) = [-17032.45811576651_wp, 0.0_wp, 18288.206910361263_wp]

  INTEGER :: ndof, e, k, li, j, es, n_iter, nfail
  INTEGER, ALLOCATABLE :: elem_conn(:, :)
  REAL(wp), ALLOCATABLE :: l0(:), ea(:), f_ext(:), seed(:, :), offset(:, :)
  REAL(wp) :: w0(6), cmat(6, 6), pose_ref(6), pose0(6), pose(6)
  REAL(wp) :: fairlead_forces(3, N_LINES), span
  REAL(wp) :: anchor(3), fairlead(3), gf(3), k_fair(3, 3)
  REAL(wp) :: g_plus(3), g_minus(3), kfd(3, 3), kfair0(3, 3), fair0(3), dp(3), relmax
  REAL(wp), ALLOCATABLE :: q_inner(:)
  LOGICAL :: conv, all_ok
  CHARACTER(200) :: em
  TYPE(CableSolverConfig) :: cfg
  REAL(wp) :: mags(N_LINES), zs(N_LINES), sum_gz
  REAL(wp) :: pose_h(6), pose_p(6), pose_m(6), r0(6), r_p(6), r_m(6), ee(3)
  REAL(wp) :: ksys(6, 6), fd(6, 6), states_h(NDOF_P, N_LINES), forces_h(3, N_LINES), rel_tan

  nfail = 0
  ndof = 3*(N_ELEM + 1)
  span = NORM2([R_FAIR - R_ANCHOR, 0.0_wp, Z_FAIR - Z_ANCHOR])

  ALLOCATE (elem_conn(2, N_ELEM), l0(N_ELEM), ea(N_ELEM), f_ext(ndof))
  ALLOCATE (seed(ndof, N_LINES), offset(3, N_LINES), q_inner(ndof))
  DO e = 1, N_ELEM
    elem_conn(:, e) = [e, e + 1]
  END DO
  l0 = REST_FACTOR*span/REAL(N_ELEM, wp)   ! pre-stretched -> taut (tension > 0)
  ea = EA_V

  ! Gravity load: -W_SUB * tributary length on each node's z DOF (ends get half).
  f_ext = 0.0_wp
  DO k = 1, N_ELEM + 1
    f_ext(3*(k - 1) + 3) = -W_SUB*(span/REAL(N_ELEM, wp))
  END DO
  f_ext(3) = 0.5_wp*f_ext(3)
  f_ext(3*N_ELEM + 3) = 0.5_wp*f_ext(3*N_ELEM + 3)

  ! Per-line straight seed (anchor -> fairlead) + body-frame fairlead offset.
  DO li = 1, N_LINES
    anchor = [R_ANCHOR*COS(PHIS(li)), R_ANCHOR*SIN(PHIS(li)), Z_ANCHOR]
    fairlead = [R_FAIR*COS(PHIS(li)), R_FAIR*SIN(PHIS(li)), Z_FAIR]
    offset(:, li) = fairlead
    DO k = 1, N_ELEM + 1
      seed(3*(k - 1) + 1:3*(k - 1) + 3, li) = anchor + (fairlead - anchor)*REAL(k - 1, wp)/REAL(N_ELEM, wp)
    END DO
  END DO

  ! --- inner fairlead Schur solve vs the reference (phi=0) + FD-check of K_fair ---
  fair0 = [R_FAIR, 0.0_wp, Z_FAIR]
  CALL CD_Fairlead_Solve(seed(:, 1), elem_conn, l0, ea, .FALSE., f_ext, 1, N_ELEM + 1, &
                         fair0, CableSolverConfig(), q_inner, gf, k_fair, es, em)
  CALL require(es == CD_PLAT_OK, 'inner fairlead solve errstat: '//TRIM(em))
  CALL require(NORM2(gf - reference_G0) < 1.0e-3_wp*NORM2(reference_G0), 'inner fairlead force g matches reference')
  kfair0 = k_fair
  ! FD-check K_fair = d g / d(fairlead pos).
  kfd = 0.0_wp
  DO j = 1, 3
    dp = 0.0_wp; dp(j) = 1.0e-5_wp
    CALL CD_Fairlead_Solve(seed(:, 1), elem_conn, l0, ea, .FALSE., f_ext, 1, N_ELEM + 1, &
                           fair0 + dp, CableSolverConfig(), q_inner, g_plus, k_fair, es, em)
    CALL CD_Fairlead_Solve(seed(:, 1), elem_conn, l0, ea, .FALSE., f_ext, 1, N_ELEM + 1, &
                           fair0 - dp, CableSolverConfig(), q_inner, g_minus, k_fair, es, em)
    kfd(:, j) = (g_plus - g_minus)/(2.0e-5_wp)
  END DO
  relmax = nan_max_abs(kfair0 - kfd)/(nan_max_abs(kfd) + 1.0e-30_wp)
  WRITE (*, '(A,ES10.2)') 'L4 inner K_fair vs FD rel error = ', relmax
  CALL require(relmax < 1.0e-5_wp, 'K_fair condenses the converged line tangent (FD-checked)')

  ! --- coupled 6-DOF tangent vs central FD at a HEELED + offset pose ---
  ! The symmetric upright solve does NOT exercise the dexp_inv rotational-column mapping or
  ! the geometric rotating-lever term -- both vanish at theta = 0. A finite roll/pitch/yaw +
  ! offset exposes them, so FD-check the full tangent there.
  cmat = 0.0_wp
  cmat(3, 3) = C33
  cmat(4, 4) = 5.0e7_wp
  cmat(5, 5) = 5.0e7_wp
  w0 = 0.0_wp
  pose_ref = 0.0_wp
  pose_h = [0.6_wp, -0.4_wp, -0.5_wp, 0.06_wp, -0.09_wp, 0.04_wp]
  CALL CD_Platform_Residual_Tangent(pose_h, N_LINES, elem_conn, l0, ea, .FALSE., f_ext, seed, &
                                    offset, 1, N_ELEM + 1, w0, cmat, pose_ref, &
                                    CableSolverConfig(rel_tol=1.0e-12_wp), r0, ksys, states_h, &
                                    forces_h, all_ok, es, em)
  CALL require(es == CD_PLAT_OK .AND. all_ok, 'heeled residual/tangent assembly: '//TRIM(em))
  fd = 0.0_wp
  ! translation columns (j = 1..3): additive increment.
  DO j = 1, 3
    pose_p = pose_h; pose_m = pose_h
    pose_p(j) = pose_h(j) + 1.0e-6_wp
    pose_m(j) = pose_h(j) - 1.0e-6_wp
    CALL fd_residual(pose_p, r_p)
    CALL fd_residual(pose_m, r_m)
    fd(:, j) = (r_p - r_m)/(2.0e-6_wp)
  END DO
  ! rotation columns (j = 4..6): spatial (left) compose increment; j-3 in 1..3.
  DO j = 4, 6
    pose_p = pose_h; pose_m = pose_h
    ee = 0.0_wp; ee(j - 3) = 1.0e-6_wp
    pose_p(4:6) = CD_Compose_Rotvec(pose_h(4:6), ee)
    pose_m(4:6) = CD_Compose_Rotvec(pose_h(4:6), -ee)
    CALL fd_residual(pose_p, r_p)
    CALL fd_residual(pose_m, r_m)
    fd(:, j) = (r_p - r_m)/(2.0e-6_wp)
  END DO
  ! re-evaluate ksys at pose_h (the loop overwrote it with the last FD probe's tangent).
  CALL CD_Platform_Residual_Tangent(pose_h, N_LINES, elem_conn, l0, ea, .FALSE., f_ext, seed, &
                                    offset, 1, N_ELEM + 1, w0, cmat, pose_ref, &
                                    CableSolverConfig(rel_tol=1.0e-12_wp), r0, ksys, states_h, &
                                    forces_h, all_ok, es, em)
  ! ksys = -d(residual)/d(pose increment), so ksys + fd ~ 0.
  rel_tan = nan_max_abs(ksys + fd)/(nan_max_abs(ksys) + 1.0e-30_wp)
  WRITE (*, '(A,ES10.2)') 'L4 coupled 6-DOF tangent vs FD rel error (heeled) = ', rel_tan
  CALL require(rel_tan < 1.0e-5_wp, 'coupled 6-DOF tangent matches FD at a heeled pose')

  ! --- coupled symmetric platform solve ---
  cmat = 0.0_wp
  cmat(3, 3) = C33
  cmat(4, 4) = 5.0e7_wp
  cmat(5, 5) = 5.0e7_wp
  w0 = 0.0_wp
  pose_ref = 0.0_wp
  pose0 = [0.0_wp, 0.0_wp, -0.2_wp, 0.0_wp, 0.0_wp, 0.0_wp]
  cfg = CableSolverConfig()

  CALL CD_Solve_Platform_Mooring(N_LINES, elem_conn, l0, ea, .FALSE., f_ext, seed, offset, &
                                 1, N_ELEM + 1, w0, cmat, pose_ref, pose0, cfg, 1.0e-8_wp, 40, &
                                 pose, fairlead_forces, conv, n_iter, es, em)
  CALL require(es == CD_PLAT_OK, 'coupled platform solve errstat: '//TRIM(em))
  CALL require(conv, 'coupled platform Newton converged')

  ! (2) centred + upright by symmetry.
  CALL require(ABS(pose(1)) < 1.0e-6_wp .AND. ABS(pose(2)) < 1.0e-6_wp, 'platform centred (surge/sway ~ 0)')
  CALL require(nan_max_abs(pose(4:6)) < 1.0e-6_wp, 'platform upright (roll/pitch/yaw ~ 0)')
  ! (4) heaved down, matching the reference to a tight band.
  CALL require(pose(3) < 0.0_wp, 'platform heaves down under the mooring')
  CALL require(ABS(pose(3) - reference_POSE_Z) < 1.0e-4_wp*ABS(reference_POSE_Z), 'heave matches the reference')

  ! (3) equal fairlead tensions (magnitude + vertical pull), each holding the fairlead up.
  DO li = 1, N_LINES
    mags(li) = NORM2(fairlead_forces(:, li))
    zs(li) = fairlead_forces(3, li)
  END DO
  CALL require(MAXVAL(mags) - MINVAL(mags) < 1.0e-3_wp*MAXVAL(mags), 'equal fairlead tension magnitudes')
  CALL require(ALL(zs > 0.0_wp), 'each line pulls the platform down (g_z up at the fairlead)')
  CALL require(ABS(mags(1) - reference_MAG) < 1.0e-4_wp*reference_MAG, &
               'fairlead tension magnitude matches the reference')
  CALL require(ABS(zs(1) - reference_GZ) < 1.0e-4_wp*reference_GZ, 'fairlead vertical pull matches the reference')

  ! heave balance: hydrostatic restoring carries the net vertical mooring pull.
  sum_gz = SUM(zs)
  CALL require(ABS(-C33*pose(3) - sum_gz) < 1.0e-6_wp*ABS(sum_gz), 'heave restoring balances vertical mooring pull')

  WRITE (*, '(A,F12.6,A,F12.3,A,F12.3,A)') 'L4 pose_z=', pose(3), ' m  |g|=', mags(1), &
    ' N  g_z=', zs(1), ' N'

  IF (nfail > 0) THEN
    WRITE (*, '(A,I0,A)') 'FAIL: ', nfail, ' assertion(s) failed'
    ERROR STOP 1
  END IF
  WRITE (*, '(A)') 'PASS: L4-1 coupled platform + mooring static equilibrium on the Fortran core'

  DEALLOCATE (elem_conn, l0, ea, f_ext, seed, offset, q_inner)

CONTAINS

  INCLUDE 'nan_max_abs.inc'

  SUBROUTINE fd_residual(p, r)
    !! Coupled 6-DOF residual at pose p (tight inner solve), for the central-FD tangent check.
    REAL(wp), INTENT(IN) :: p(6)
    REAL(wp), INTENT(OUT) :: r(6)
    REAL(wp) :: ks(6, 6)
    LOGICAL :: ok
    INTEGER :: e2
    CHARACTER(200) :: m2
    CALL CD_Platform_Residual_Tangent(p, N_LINES, elem_conn, l0, ea, .FALSE., f_ext, seed, &
                                      offset, 1, N_ELEM + 1, w0, cmat, pose_ref, &
                                      CableSolverConfig(rel_tol=1.0e-12_wp), r, ks, states_h, &
                                      forces_h, ok, e2, m2)
  END SUBROUTINE fd_residual

  SUBROUTINE require(cond, label)
    LOGICAL, INTENT(IN) :: cond
    CHARACTER(*), INTENT(IN) :: label
    IF (.NOT. cond) THEN
      WRITE (*, '(A,A,A)') 'MISMATCH [', TRIM(label), ']: condition false'
      nfail = nfail + 1
    END IF
  END SUBROUTINE require

END PROGRAM test_l4_platform_mooring
