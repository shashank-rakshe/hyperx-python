! File: tests/test_cosserat_force.f90
! SPDX-License-Identifier: Apache-2.0
! Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
PROGRAM test_cosserat_force
  !! reference-parity check for the geometrically-exact Cosserat element internal
  !! force and tangent (CD_Cosserat_Force_Tangent), against independently computed
  !! values. Two element states -- a
  !! z-aligned reference under axial + bend + twist, and a 45-degree tilted
  !! reference -- with EA=1e3, GAs=5e2, EI=2e2, GJ=1.5e2, reduced_shear=.TRUE.
  !!
  !! Checks per case:
  !!   (1) fint vs the full reference vector (exact 2nd-order AD on both
  !!       sides; matches to ~1e-8),
  !!   (2) Kt diagonal, Frobenius norm, and total sum vs the reference,
  !!   (3) Kt is the consistent tangent of fint (central FD of fint == Kt),
  !!   (4) Kt symmetry.
  !! Together (1) + (3) validate every Kt entry: fint matches the reference force
  !! exactly and Kt = d(fint)/dq, so Kt equals the reference d^2U/dq^2.
  USE CableDyn_Precision, ONLY: wp
  USE CableDyn_Cosserat, ONLY: CD_Reference_Frame, CD_Cosserat_Force_Tangent, &
                               CD_Cosserat_Internal_Force, CD_Cosserat_Force_Tangent_AD_Oracle, &
                               CD_Cosserat_Internal_Force_AD_Oracle
  USE, INTRINSIC :: IEEE_ARITHMETIC, ONLY: IEEE_VALUE, IEEE_POSITIVE_INF, IEEE_IS_FINITE
  IMPLICIT NONE

  REAL(wp), PARAMETER :: EA = 1.0e3_wp, GAS = 5.0e2_wp, EI = 2.0e2_wp, GJ = 1.5e2_wp
  REAL(wp), PARAMETER :: FTOL = 1.0e-6_wp      ! fint / Kt-diag absolute (forces ~ 50, Kt ~ 100s)
  REAL(wp), PARAMETER :: RTOL = 1.0e-8_wp      ! Frobenius / sum relative
  REAL(wp), PARAMETER :: FDTOL = 1.0e-2_wp     ! central-FD tangent consistency (Kt ~ 100s)
  REAL(wp), PARAMETER :: ATOL = 1.0e-9_wp      ! exact AD-vs-analytical block agreement
  REAL(wp), PARAMETER :: STOL = 1.0e-9_wp      ! symmetry
  INTEGER, PARAMETER :: TIDX(6) = [1, 2, 3, 7, 8, 9]
  INTEGER, PARAMETER :: RIDX(6) = [4, 5, 6, 10, 11, 12]   ! rotation DOFs
  INTEGER :: nfail
  REAL(wp) :: Lam0(3, 3), L0, q(12), fint(12), Kt(12, 12)
  REAL(wp) :: fint_ref(12), ktd_ref(12)
  nfail = 0

  ! === case A: z-aligned reference, L0 = 2 ===
  CALL CD_Reference_Frame([0.0_wp, 0.0_wp, 0.0_wp], [0.0_wp, 0.0_wp, 2.0_wp], Lam0, L0)
  q = [0.0_wp, 0.0_wp, 0.0_wp, 0.05_wp, -0.03_wp, 0.02_wp, &
       0.1_wp, 0.2_wp, 2.1_wp, -0.04_wp, 0.06_wp, -0.01_wp]
  fint_ref = [-17.95660792973516_wp, -52.45028091772676_wp, -49.37214347121599_wp, &
              58.534045207590246_wp, -24.804920756592008_wp, 1.7882904171651632_wp, &
              17.95660792973516_wp, 52.45028091772676_wp, 49.37214347121599_wp, &
              41.65016768145563_wp, -8.238205916589674_wp, -2.6236928686313297_wp]
  ktd_ref = [250.392996121786_wp, 250.344045337601_wp, 499.26295854061294_wp, &
             351.6428681467176_wp, 345.4331693618773_wp, 74.75355619436145_wp, &
             250.392996121786_wp, 250.344045337601_wp, 499.26295854061294_wp, &
             340.63303188867485_wp, 339.13179191451695_wp, 75.21037128568912_wp]
  CALL eval(q, Lam0, L0, fint, Kt)
  CALL check_case('A', q, Lam0, L0, fint, Kt, fint_ref, ktd_ref, &
                  1735.9095262770993_wp, 1859.8820095388353_wp)

  ! === case B: 45-degree tilted reference, L0 = sqrt(2) ===
  CALL CD_Reference_Frame([0.0_wp, 0.0_wp, 0.0_wp], [1.0_wp, 0.0_wp, 1.0_wp], Lam0, L0)
  q = [0.0_wp, 0.0_wp, 0.0_wp, 0.1_wp, 0.0_wp, 0.0_wp, &
       1.1_wp, 0.05_wp, 1.0_wp, 0.0_wp, 0.15_wp, 0.05_wp]
  fint_ref = [-27.590571420713086_wp, -25.1545851664985_wp, -43.00344857157739_wp, &
              24.717692528710458_wp, -10.942070736062174_wp, -20.52540944167078_wp, &
              27.590571420713086_wp, 25.1545851664985_wp, 43.00344857157739_wp, &
              -0.5753779948007338_wp, 29.643783275396746_wp, -5.306752240247487_wp]
  ktd_ref = [556.4119167805466_wp, 354.3398562604055_wp, 503.4617893321431_wp, &
             203.5182849869055_wp, 312.6124368264931_wp, 217.53681537880726_wp, &
             556.4119167805466_wp, 354.3398562604055_wp, 503.4617893321431_wp, &
             204.88184531317114_wp, 314.55980215656564_wp, 213.23213287408936_wp]
  CALL eval(q, Lam0, L0, fint, Kt)
  CALL check_case('B', q, Lam0, L0, fint, Kt, fint_ref, ktd_ref, &
                  2087.6025594517873_wp, 678.1814717927032_wp)

  ! === undeformed reference: zero internal force ===
  CALL CD_Reference_Frame([0.2_wp, -0.1_wp, 0.0_wp], [0.7_wp, 0.3_wp, 1.1_wp], Lam0, L0)
  q = [0.2_wp, -0.1_wp, 0.0_wp, 0.0_wp, 0.0_wp, 0.0_wp, &
       0.7_wp, 0.3_wp, 1.1_wp, 0.0_wp, 0.0_wp, 0.0_wp]
  CALL eval(q, Lam0, L0, fint, Kt)
  CALL require(nan_max_abs(fint) < 1.0e-9_wp, 'undeformed:zero-force')

  ! === analytical Gamma-geometric: zero relative rotation (kappa=0) isolates the
  !     Gamma part of the rotation-rotation geometric block; the full block must then
  !     equal the AD oracle (no kappa-geometric contamination). ===
  CALL check_gamma_geometric_kappa_zero()

  ! === fail-closed hardening: invalid inputs / near-pi relative rotation ===
  CALL CD_Reference_Frame([0.0_wp, 0.0_wp, 0.0_wp], [0.0_wp, 0.0_wp, 1.0_wp], Lam0, L0)
  q = 0.0_wp; q(9) = 1.0_wp                                   ! valid baseline state
  CALL expect_fail(q, Lam0, L0, EA, GAS, -1.0_wp, GJ, 'reject:negative-EI')
  CALL expect_fail(q, Lam0, 0.0_wp, EA, GAS, EI, GJ, 'reject:zero-L0')
  q(9) = IEEE_VALUE(1.0_wp, IEEE_POSITIVE_INF)
  CALL expect_fail(q, Lam0, L0, EA, GAS, EI, GJ, 'reject:non-finite-q')
  ! a nodal rotation vector outside the unique |theta| < pi chart (theta_2x = 3.2
  ! rad > pi) must fail closed (non-unique parametrisation).
  q = 0.0_wp; q(9) = 1.0_wp; q(10) = 3.2_wp
  CALL expect_fail(q, Lam0, L0, EA, GAS, EI, GJ, 'reject:out-of-chart-rotation')
  ! both nodal rotations IN chart (|theta| = pi/2 each) but the relative rotation
  ! Lam1^T Lam2 = pi exactly -> the log map is singular, reject.
  q = 0.0_wp; q(9) = 1.0_wp
  q(4) = 1.5707963267948966_wp; q(10) = -1.5707963267948966_wp
  CALL expect_fail(q, Lam0, L0, EA, GAS, EI, GJ, 'reject:singular-pi-relative-rotation')
  ! a LARGE but in-chart, sub-singular rotation (theta_2x = 3.0 rad, ~0.14 below
  ! pi) must NOT be rejected -- it stays reference-evaluable through the regular log
  q = 0.0_wp; q(9) = 1.0_wp; q(10) = 3.0_wp
  CALL expect_ok(q, Lam0, L0, 'accept:large-sub-singular-rotation')
  CALL check_tangent_rotation_sweep()
  CALL check_oracle_state_matrix()

  IF (nfail > 0) THEN
    WRITE (*, '(A,I0,A)') 'FAIL: ', nfail, ' assertion(s) failed'
    ERROR STOP 1
  END IF
  WRITE (*, '(A)') 'PASS: Fortran Cosserat fint + Kt match the independent reference values'

CONTAINS

  INCLUDE 'nan_max_abs.inc'

  SUBROUTINE eval(qin, Lam0in, L0in, f, K)
    REAL(wp), INTENT(IN) :: qin(12), Lam0in(3, 3), L0in
    REAL(wp), INTENT(OUT) :: f(12), K(12, 12)
    REAL(wp) :: f_fo(12), f_ad(12), f_fo_ad(12), K_ad(12, 12)
    INTEGER :: es, es_fo, es_ad
    CHARACTER(120) :: em
    CALL CD_Cosserat_Force_Tangent(qin, EA, GAS, EI, GJ, Lam0in, L0in, .TRUE., f, K, es, em)
    CALL require(es == 0, 'force-ErrStat')
    CALL CD_Cosserat_Force_Tangent_AD_Oracle(qin, EA, GAS, EI, GJ, Lam0in, L0in, .TRUE., f_ad, K_ad, es_ad, em)
    CALL require(es_ad == 0, 'ad-reference-ErrStat')
    CALL require(nan_max_abs(f - f_ad) < 1.0e-10_wp, 'analytic-fint-matches-Dual2-reference')
    CALL require(nan_max_abs(K - K_ad) < FDTOL, 'analytic-Kt-matches-Dual2-reference')
    CALL require(nan_max_abs(K(:, TIDX) - K_ad(:, TIDX)) < ATOL, &
                 'analytic-position-column-Kt-matches-Dual2-reference')
    CALL require(nan_max_abs(K(TIDX, :) - K_ad(TIDX, :)) < ATOL, &
                 'analytic-position-row-Kt-matches-Dual2-reference')
    ! force-only path (Dual1) must reproduce the tangent path's fint to the AD
    ! floor: both differentiate the SAME energy, so the residual the production
    ! solver uses is unchanged by the optimization (this is the correctness gate
    ! for the force-only split, not just a speed change).
    CALL CD_Cosserat_Internal_Force(qin, EA, GAS, EI, GJ, Lam0in, L0in, .TRUE., f_fo, es_fo, em)
    CALL require(es_fo == 0 .AND. nan_max_abs(f_fo - f) < 1.0e-10_wp, 'force-only-fint-matches-tangent')
    CALL CD_Cosserat_Internal_Force_AD_Oracle(qin, EA, GAS, EI, GJ, Lam0in, L0in, .TRUE., f_fo_ad, es_ad, em)
    CALL require(es_ad == 0 .AND. nan_max_abs(f_fo - f_fo_ad) < 1.0e-10_wp, 'force-only-fint-matches-Dual1-reference')
    CALL check_analytic_tangent_vs_oracle(qin, Lam0in, L0in, f_ad, K_ad)
  END SUBROUTINE eval

  SUBROUTINE check_analytic_tangent_vs_oracle(qin, Lam0in, L0in, f_ad, K_ad)
    !! Production closed-form tangent parity gate. The analytical fint (B^T s) and the
    !! full 12x12 tangent of CD_Cosserat_Force_Tangent -- B^T C B material, the
    !! translational/coupling geometric columns, and the rotation-rotation geometric
    !! block (SO(3) Hessian: Gamma + kappa parts) -- must match the retained Dual2 AD
    !! oracle to the exact-block floor on EVERY entry. The rotation-rotation block must
    !! also be symmetric (a non-symmetric block would signal a sign/transpose error in
    !! the SO(3) second variation).
    REAL(wp), INTENT(IN) :: qin(12), Lam0in(3, 3), L0in, f_ad(12), K_ad(12, 12)
    REAL(wp) :: f_an(12), K_an(12, 12), dsym
    INTEGER :: es_an, ii, jj
    CHARACTER(120) :: em
    CALL CD_Cosserat_Force_Tangent(qin, EA, GAS, EI, GJ, Lam0in, L0in, .TRUE., f_an, K_an, es_an, em)
    CALL require(es_an == 0, 'analytic-tangent-ErrStat')
    CALL require(nan_max_abs(f_an - f_ad) < 1.0e-9_wp, 'analytic-fint-matches-Dual2')
    CALL require(nan_max_abs(K_an - K_ad) < ATOL, 'analytic-tangent-full-Kt-matches-Dual2')
    dsym = 0.0_wp
    DO jj = 1, 6
      DO ii = 1, 6
        dsym = MAX(dsym, ABS(K_an(RIDX(ii), RIDX(jj)) - K_an(RIDX(jj), RIDX(ii))))
      END DO
    END DO
    CALL require(dsym < 1.0e-9_wp, 'analytic-tangent-rotRR-symmetric')
  END SUBROUTINE check_analytic_tangent_vs_oracle

  SUBROUTINE expect_fail(qin, Lam0in, L0in, ea_, gas_, ei_, gj_, label)
    !! The routine must fail closed (ErrStat /= 0) AND zero its outputs.
    REAL(wp), INTENT(IN) :: qin(12), Lam0in(3, 3), L0in, ea_, gas_, ei_, gj_
    CHARACTER(*), INTENT(IN) :: label
    REAL(wp) :: f(12), K(12, 12)
    INTEGER :: es
    CHARACTER(120) :: em
    CALL CD_Cosserat_Force_Tangent(qin, ea_, gas_, ei_, gj_, Lam0in, L0in, .TRUE., f, K, es, em)
    ! outputs are set to exactly 0.0 on failure; the tiny threshold confirms the
    ! zeroing while avoiding an exact-real-equality comparison (-Wcompare-reals)
    CALL require(es /= 0 .AND. nan_max_abs(f) < 1.0e-300_wp .AND. nan_max_abs(K) < 1.0e-300_wp, label)
    ! the force-only path shares validate_force_inputs, so it must fail closed on
    ! exactly the same inputs (audit the class, not just the tangent path)
    CALL CD_Cosserat_Internal_Force(qin, ea_, gas_, ei_, gj_, Lam0in, L0in, .TRUE., f, es, em)
    CALL require(es /= 0 .AND. nan_max_abs(f) < 1.0e-300_wp, label//':force-only')
  END SUBROUTINE expect_fail

  SUBROUTINE expect_ok(qin, Lam0in, L0in, label)
    !! A valid (if large-rotation) state must evaluate: ErrStat == 0, finite outputs.
    REAL(wp), INTENT(IN) :: qin(12), Lam0in(3, 3), L0in
    CHARACTER(*), INTENT(IN) :: label
    REAL(wp) :: f(12), K(12, 12)
    INTEGER :: es
    CHARACTER(120) :: em
    CALL CD_Cosserat_Force_Tangent(qin, EA, GAS, EI, GJ, Lam0in, L0in, .TRUE., f, K, es, em)
    CALL require(es == 0 .AND. ALL(IEEE_IS_FINITE(f)) .AND. ALL(IEEE_IS_FINITE(K)), label)
    CALL CD_Cosserat_Internal_Force(qin, EA, GAS, EI, GJ, Lam0in, L0in, .TRUE., f, es, em)
    CALL require(es == 0 .AND. ALL(IEEE_IS_FINITE(f)), label//':force-only')
  END SUBROUTINE expect_ok

  SUBROUTINE check_tangent_rotation_sweep()
    !! The production tangent must equal the central finite difference of the
    !! internal force across finite rotation magnitudes -- the surface where
    !! finite-rotation tangent errors would hide. Both sides are production
    !! routines (CD_Cosserat_Force_Tangent / CD_Cosserat_Internal_Force).
    REAL(wp), PARAMETER :: MAGS(4) = [0.0_wp, 0.3_wp, 0.8_wp, 1.5_wp]
    REAL(wp), PARAMETER :: U1(3) = [0.3713906763541037_wp, -0.7427813527082074_wp, 0.5570860145311556_wp]
    REAL(wp), PARAMETER :: U2(3) = [-0.31980107453341566_wp, 0.799502686333539_wp, 0.5096838504490689_wp]
    REAL(wp), PARAMETER :: HH = 1.0e-6_wp
    REAL(wp) :: Lam0s(3, 3), L0s, qs(12), qp(12), qm(12), f(12), K(12, 12), Kfd(12, 12)
    REAL(wp) :: fp(12), fm(12)
    INTEGER :: i, j, es
    CHARACTER(120) :: em
    CALL CD_Reference_Frame([0.0_wp, 0.0_wp, 0.0_wp], [0.0_wp, 0.0_wp, 1.0_wp], Lam0s, L0s)
    DO i = 1, SIZE(MAGS)
      qs = 0.0_wp
      qs(1:3) = [0.01_wp, -0.02_wp, 0.0_wp]
      qs(7:9) = [0.08_wp, -0.03_wp, 1.04_wp]
      qs(4:6) = MAGS(i)*U1
      qs(10:12) = 0.65_wp*MAGS(i)*U2
      CALL CD_Cosserat_Force_Tangent(qs, EA, GAS, EI, GJ, Lam0s, L0s, .TRUE., f, K, es, em)
      CALL require(es == 0, 'rotation-sweep:ErrStat')
      DO j = 1, 12
        qp = qs; qp(j) = qs(j) + HH
        qm = qs; qm(j) = qs(j) - HH
        CALL CD_Cosserat_Internal_Force(qp, EA, GAS, EI, GJ, Lam0s, L0s, .TRUE., fp, es, em)
        CALL CD_Cosserat_Internal_Force(qm, EA, GAS, EI, GJ, Lam0s, L0s, .TRUE., fm, es, em)
        Kfd(:, j) = (fp - fm)/(2.0_wp*HH)
      END DO
      CALL require(nan_max_abs(K - Kfd) < FDTOL, 'rotation-sweep:Kt-vs-FD')
    END DO
  END SUBROUTINE check_tangent_rotation_sweep

  SUBROUTINE oracle_state(refA, refB, q, reduced_shear, label)
    !! One deterministic element state: the production closed-form tangent (fint + full
    !! 12x12 Kt) must match the retained Dual2 AD oracle to the exact-block floor.
    REAL(wp), INTENT(IN) :: refA(3), refB(3), q(12)
    LOGICAL, INTENT(IN) :: reduced_shear
    CHARACTER(*), INTENT(IN) :: label
    REAL(wp) :: Lam0(3, 3), L0, f(12), K(12, 12), f2(12), K2(12, 12)
    INTEGER :: es, es2
    CHARACTER(120) :: em
    CALL CD_Reference_Frame(refA, refB, Lam0, L0)
    CALL CD_Cosserat_Force_Tangent(q, EA, GAS, EI, GJ, Lam0, L0, reduced_shear, f, K, es, em)
    CALL CD_Cosserat_Force_Tangent_AD_Oracle(q, EA, GAS, EI, GJ, Lam0, L0, reduced_shear, f2, K2, es2, em)
    CALL require(es == 0 .AND. es2 == 0, label//':ErrStat')
    CALL require(nan_max_abs(f - f2) < 1.0e-9_wp, label//':fint-vs-AD')
    CALL require(nan_max_abs(K - K2) < ATOL, label//':Kt-vs-AD')
  END SUBROUTINE oracle_state

  SUBROUTINE check_oracle_state_matrix()
    !! Deterministic (fixed-state) parity matrix against the Dual2 AD oracle, broadening
    !! the two single fixtures + rotation sweep. Covers, by construction: reduced AND full
    !! shear quadrature, a tilted reference frame, large-but-valid rotations, unequal node
    !! rotations, a near-threshold relative rotation (|phi| straddling the 0.25 SO(3)
    !! switch across the Gauss points), and a near-straight (tiny relative rotation) state.
    REAL(wp) :: q(12)
    ! tilted frame, unequal moderate nodal rotations -- both shear modes
    q = [0.20_wp, -0.10_wp, 0.00_wp, 0.30_wp, -0.20_wp, 0.15_wp, &
         0.95_wp, 0.42_wp, 1.25_wp, -0.10_wp, 0.25_wp, -0.18_wp]
    CALL oracle_state([0.2_wp, -0.1_wp, 0.0_wp], [0.7_wp, 0.5_wp, 1.2_wp], q, .TRUE., 'mat:tilted-unequal-reduced')
    CALL oracle_state([0.2_wp, -0.1_wp, 0.0_wp], [0.7_wp, 0.5_wp, 1.2_wp], q, .FALSE., 'mat:tilted-unequal-full')
    ! large but valid rotations (|theta| ~ 1.3-1.7, inside the |theta| < pi chart)
    q = [0.00_wp, 0.00_wp, 0.00_wp, 1.20_wp, -0.80_wp, 0.90_wp, &
         0.10_wp, -0.05_wp, 1.40_wp, -0.60_wp, 1.00_wp, 0.50_wp]
    CALL oracle_state([0.0_wp, 0.0_wp, 0.0_wp], [0.0_wp, 0.0_wp, 1.5_wp], q, .TRUE., 'mat:large-rot-reduced')
    CALL oracle_state([0.0_wp, 0.0_wp, 0.0_wp], [0.0_wp, 0.0_wp, 1.5_wp], q, .FALSE., 'mat:large-rot-full')
    ! near-threshold relative rotation: |theta2 - theta1| ~ 0.47 -> phi straddles 0.25
    q = [0.03_wp, -0.02_wp, 0.00_wp, 0.10_wp, 0.05_wp, -0.08_wp, &
         0.06_wp, 0.04_wp, 1.30_wp, 0.40_wp, -0.25_wp, 0.12_wp]
    CALL oracle_state([0.0_wp, 0.0_wp, 0.0_wp], [0.0_wp, 0.0_wp, 1.3_wp], q, .TRUE., 'mat:near-threshold')
    ! small curvature: relative rotation ~0.026 -> phi_min ~ 5.6e-3, exercising the
    ! small-angle Taylor branch of the directional Jacobians inside the tangent. (Even
    ! smaller relative rotations are limited to ~1e-8 relative vs AD by the lower-order
    ! SO(3) primitives' t^2/t^3 cancellation -- see VALIDATION.md scope note -- so they
    ! are out of scope for the 1e-12-class element-tangent parity gate.)
    q = [0.10_wp, 0.20_wp, -0.05_wp, 0.20_wp, 0.10_wp, -0.15_wp, &
         0.80_wp, 0.55_wp, 1.05_wp, 0.215_wp, 0.088_wp, -0.132_wp]
    CALL oracle_state([0.1_wp, 0.2_wp, 0.0_wp], [0.8_wp, 0.5_wp, 1.1_wp], q, .TRUE., 'mat:small-curvature')
  END SUBROUTINE check_oracle_state_matrix

  SUBROUTINE check_gamma_geometric_kappa_zero()
    !! With zero relative rotation (theta1 == theta2 => psi = 0 => kappa = 0) the
    !! moment vanishes, so the kappa-geometric part of the rotation-rotation tangent is
    !! identically zero and the analytical Gamma-geometric must reproduce the AD
    !! oracle's rotation-rotation block exactly. Two configurations exercise it: zero
    !! nodal rotation, and a finite EQUAL nodal rotation (the latter drives the
    !! dexp/dexp_inv directional machinery that theta = 0 leaves at the identity).
    REAL(wp) :: Lam0s(3, 3), L0s, qz(12), qf(12)
    REAL(wp), PARAMETER :: TH(3) = [0.5_wp, -0.3_wp, 0.7_wp]
    INTEGER :: c
    CALL CD_Reference_Frame([0.0_wp, 0.0_wp, 0.0_wp], [0.0_wp, 0.0_wp, 1.5_wp], Lam0s, L0s)
    ! zero nodal rotation, axial + transverse stretch
    qz = [0.03_wp, -0.02_wp, 0.0_wp, 0.0_wp, 0.0_wp, 0.0_wp, &
          0.06_wp, 0.04_wp, 1.62_wp, 0.0_wp, 0.0_wp, 0.0_wp]
    ! both shear-quadrature modes: reduced (production default) and full Gauss
    CALL require_rotRR_matches_ad(qz, Lam0s, L0s, .TRUE., 'gamma-geo:kappa0-theta0-reduced')
    CALL require_rotRR_matches_ad(qz, Lam0s, L0s, .FALSE., 'gamma-geo:kappa0-theta0-full')
    ! finite equal nodal rotations: psi = 0 still, but Lambda1 = Lambda2 != I
    qf = qz
    DO c = 1, 3
      qf(3 + c) = TH(c)
      qf(9 + c) = TH(c)
    END DO
    CALL require_rotRR_matches_ad(qf, Lam0s, L0s, .TRUE., 'gamma-geo:kappa0-finite-rotation-reduced')
    CALL require_rotRR_matches_ad(qf, Lam0s, L0s, .FALSE., 'gamma-geo:kappa0-finite-rotation-full')
  END SUBROUTINE check_gamma_geometric_kappa_zero

  SUBROUTINE require_rotRR_matches_ad(qin, Lam0in, L0in, reduced_shear, label)
    !! Assert the production analytical tangent's rotation-rotation block equals the
    !! Dual2 AD oracle's to the exact-block floor (used where kappa = 0 so the
    !! kappa-geometric term is identically zero, isolating the Gamma part). Exercised for
    !! both shear-quadrature modes so the full-Gauss branch is not left uncovered.
    REAL(wp), INTENT(IN) :: qin(12), Lam0in(3, 3), L0in
    LOGICAL, INTENT(IN) :: reduced_shear
    CHARACTER(*), INTENT(IN) :: label
    REAL(wp) :: f_an(12), K_an(12, 12), f_ad(12), K_ad(12, 12), drr
    INTEGER :: es_an, es_ad, ii, jj
    CHARACTER(120) :: em
    CALL CD_Cosserat_Force_Tangent(qin, EA, GAS, EI, GJ, Lam0in, L0in, reduced_shear, &
                                   f_an, K_an, es_an, em)
    CALL CD_Cosserat_Force_Tangent_AD_Oracle(qin, EA, GAS, EI, GJ, Lam0in, L0in, reduced_shear, &
                                             f_ad, K_ad, es_ad, em)
    CALL require(es_an == 0 .AND. es_ad == 0, label//':ErrStat')
    drr = 0.0_wp
    DO jj = 1, 6
      DO ii = 1, 6
        drr = MAX(drr, ABS(K_an(RIDX(ii), RIDX(jj)) - K_ad(RIDX(ii), RIDX(jj))))
      END DO
    END DO
    CALL require(drr < ATOL, label//':rotRR-matches-AD')
  END SUBROUTINE require_rotRR_matches_ad

  SUBROUTINE check_case(tag, qin, Lam0in, L0in, f, K, fref, kdref, frob_ref, sum_ref)
    CHARACTER(*), INTENT(IN) :: tag
    REAL(wp), INTENT(IN) :: qin(12), Lam0in(3, 3), L0in, f(12), K(12, 12)
    REAL(wp), INTENT(IN) :: fref(12), kdref(12), frob_ref, sum_ref
    REAL(wp) :: kd(12), frob, ksum, fp(12), fm(12), Kfd(12, 12), Kdum(12, 12), qp(12)
    REAL(wp), PARAMETER :: HH = 1.0e-6_wp
    INTEGER :: i, j, es
    CHARACTER(120) :: em
    ! (1) fint vs reference
    CALL require(nan_max_abs(f - fref) < FTOL, tag//':fint-vs-reference')
    ! (2) Kt diagonal / Frobenius / sum vs reference
    DO i = 1, 12
      kd(i) = K(i, i)
    END DO
    frob = SQRT(SUM(K*K))
    ksum = SUM(K)
    CALL require(nan_max_abs(kd - kdref) < FTOL, tag//':Kt-diag-vs-reference')
    CALL require(ABS(frob - frob_ref) < RTOL*frob_ref, tag//':Kt-frobenius-vs-reference')
    CALL require(ABS(ksum - sum_ref) < RTOL*ABS(sum_ref), tag//':Kt-sum-vs-reference')
    ! (3) Kt is the consistent tangent of fint (central FD)
    DO j = 1, 12
      qp = qin; qp(j) = qin(j) + HH
      CALL CD_Cosserat_Force_Tangent(qp, EA, GAS, EI, GJ, Lam0in, L0in, .TRUE., fp, Kdum, es, em)
      qp = qin; qp(j) = qin(j) - HH
      CALL CD_Cosserat_Force_Tangent(qp, EA, GAS, EI, GJ, Lam0in, L0in, .TRUE., fm, Kdum, es, em)
      Kfd(:, j) = (fp - fm)/(2.0_wp*HH)
    END DO
    CALL require(nan_max_abs(K - Kfd) < FDTOL, tag//':Kt-consistent-tangent-of-fint')
    ! (4) symmetry
    CALL require(nan_max_abs(K - TRANSPOSE(K)) < STOL, tag//':Kt-symmetric')
  END SUBROUTINE check_case

  SUBROUTINE require(cond, label)
    LOGICAL, INTENT(IN) :: cond
    CHARACTER(*), INTENT(IN) :: label
    IF (.NOT. cond) THEN
      WRITE (*, '(A,A,A)') 'MISMATCH [', label, ']: condition false'
      nfail = nfail + 1
    END IF
  END SUBROUTINE require

END PROGRAM test_cosserat_force
