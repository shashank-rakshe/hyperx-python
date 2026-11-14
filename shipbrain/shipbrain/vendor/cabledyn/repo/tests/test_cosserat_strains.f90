! File: tests/test_cosserat_strains.f90
! SPDX-License-Identifier: Apache-2.0
! Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
PROGRAM test_cosserat_strains
  !! reference-parity check for the Cosserat reference frame + material strain
  !! measures against independently computed values.
  !! Two element configurations -- a z-aligned reference (Lam0 = I) under axial
  !! stretch + bend + twist, and a 45-degree tilted reference (Lam0 != I) -- are
  !! checked at both 2-point Gauss stations to a tight 1e-12 tolerance. Also
  !! verifies the undeformed reference state has zero strain (a patch-test-grade
  !! consistency check).
  USE CableDyn_Precision, ONLY: wp
  USE CableDyn_Cosserat, ONLY: CD_Reference_Frame, CD_Cosserat_Strains
  IMPLICIT NONE

  REAL(wp), PARAMETER :: TOL = 1.0e-12_wp
  REAL(wp), PARAMETER :: INV3 = 0.57735026918962584_wp   ! 1/sqrt(3)
  INTEGER :: nfail
  REAL(wp) :: Lam0(3, 3), L0, q(12), G(3), K(3), r1r(3), r2r(3)
  nfail = 0

  ! === case A: reference along +z (Lam0 = I), L0 = 2 ===
  r1r = [0.0_wp, 0.0_wp, 0.0_wp]; r2r = [0.0_wp, 0.0_wp, 2.0_wp]
  CALL CD_Reference_Frame(r1r, r2r, Lam0, L0)
  CALL require(ABS(L0 - 2.0_wp) < TOL, 'A:L0')
  CALL check_mat(Lam0, eye3(), 'A:Lam0=I')
  q = [0.0_wp, 0.0_wp, 0.0_wp, 0.05_wp, -0.03_wp, 0.02_wp, &
       0.1_wp, 0.2_wp, 2.1_wp, -0.04_wp, 0.06_wp, -0.01_wp]
  CALL CD_Cosserat_Strains(q, Lam0, L0, -INV3, G, K)
  CALL check_vec(G, [0.06308801134229178_wp, 0.1316976621442573_wp, 0.04578947623822072_wp], 'A:Gamma(-)')
  CALL check_vec(K, [-0.044772548559833654_wp, 0.045073899204735285_wp, -0.01544914948605582_wp], 'A:Kappa(-)')
  CALL CD_Cosserat_Strains(q, Lam0, L0, +INV3, G, K)
  CALL check_vec(G, [0.0065719846534966_wp, 0.07804026529291247_wp, 0.05302731494046542_wp], 'A:Gamma(+)')
  CALL check_vec(K, [-0.04477254855983366_wp, 0.045073899204735285_wp, -0.015449149486055818_wp], 'A:Kappa(+)')

  ! === case B: 45-degree tilted reference (Lam0 != I), L0 = sqrt(2) ===
  r1r = [0.0_wp, 0.0_wp, 0.0_wp]; r2r = [1.0_wp, 0.0_wp, 1.0_wp]
  CALL CD_Reference_Frame(r1r, r2r, Lam0, L0)
  CALL require(ABS(L0 - 1.4142135623730951_wp) < TOL, 'B:L0')
  q = [0.0_wp, 0.0_wp, 0.0_wp, 0.1_wp, 0.0_wp, 0.0_wp, &
       1.1_wp, 0.05_wp, 1.0_wp, 0.0_wp, 0.15_wp, 0.05_wp]
  CALL CD_Cosserat_Strains(q, Lam0, L0, -INV3, G, K)
  CALL check_vec(G, [0.020475169127431747_wp, 0.08384473820709289_wp, 0.04823700913685891_wp], 'B:Gamma(-)')
  CALL check_vec(K, [-0.07112490364423243_wp, 0.10774530613165918_wp, -0.028666606778814736_wp], 'B:Kappa(-)')
  CALL CD_Cosserat_Strains(q, Lam0, L0, +INV3, G, K)
  CALL check_vec(G, [-0.073108666183338_wp, 0.02227213874379352_wp, 0.0490038487844886_wp], 'B:Gamma(+)')
  CALL check_vec(K, [-0.07112490364423243_wp, 0.10774530613165918_wp, -0.02866660677881474_wp], 'B:Kappa(+)')

  ! === undeformed reference state -> zero strain (consistency) ===
  r1r = [0.3_wp, -0.2_wp, 0.1_wp]; r2r = [0.9_wp, 0.4_wp, 1.3_wp]
  CALL CD_Reference_Frame(r1r, r2r, Lam0, L0)
  q = [r1r(1), r1r(2), r1r(3), 0.0_wp, 0.0_wp, 0.0_wp, &
       r2r(1), r2r(2), r2r(3), 0.0_wp, 0.0_wp, 0.0_wp]
  CALL CD_Cosserat_Strains(q, Lam0, L0, -INV3, G, K)
  CALL require(nan_max_abs(G) < TOL .AND. nan_max_abs(K) < TOL, 'undeformed:zero-strain(-)')
  CALL CD_Cosserat_Strains(q, Lam0, L0, +INV3, G, K)
  CALL require(nan_max_abs(G) < TOL .AND. nan_max_abs(K) < TOL, 'undeformed:zero-strain(+)')

  ! === coincident reference points -> defined degenerate frame, never NaN ===
  ! (the L0 == 0 and identity checks also fail if Lam0/L0 were NaN, since NaN == 0
  !  and NaN < TOL are both false -- so this gates the old divide-by-zero NaN out.)
  r1r = [0.5_wp, -0.3_wp, 0.7_wp]; r2r = r1r
  CALL CD_Reference_Frame(r1r, r2r, Lam0, L0)
  CALL require(ABS(L0) < TOL .AND. nan_max_abs(Lam0 - eye3()) < TOL, 'coincident:defined-frame-no-nan')

  IF (nfail > 0) THEN
    WRITE (*, '(A,I0,A)') 'FAIL: ', nfail, ' assertion(s) failed'
    ERROR STOP 1
  END IF
  WRITE (*, '(A)') 'PASS: Fortran Cosserat strains match the independent reference values'

CONTAINS

  INCLUDE 'nan_max_abs.inc'

  PURE FUNCTION eye3() RESULT(I3)
    REAL(wp) :: I3(3, 3)
    INTEGER :: k
    I3 = 0.0_wp
    DO k = 1, 3
      I3(k, k) = 1.0_wp
    END DO
  END FUNCTION eye3

  SUBROUTINE check_mat(got, want, label)
    REAL(wp), INTENT(IN) :: got(3, 3), want(3, 3)
    CHARACTER(*), INTENT(IN) :: label
    CALL require(nan_max_abs(got - want) < TOL, label)
  END SUBROUTINE check_mat

  SUBROUTINE check_vec(got, want, label)
    REAL(wp), INTENT(IN) :: got(3), want(3)
    CHARACTER(*), INTENT(IN) :: label
    CALL require(nan_max_abs(got - want) < TOL, label)
  END SUBROUTINE check_vec

  SUBROUTINE require(cond, label)
    LOGICAL, INTENT(IN) :: cond
    CHARACTER(*), INTENT(IN) :: label
    IF (.NOT. cond) THEN
      WRITE (*, '(A,A,A)') 'MISMATCH [', label, ']: condition false'
      nfail = nfail + 1
    END IF
  END SUBROUTINE require

END PROGRAM test_cosserat_strains
