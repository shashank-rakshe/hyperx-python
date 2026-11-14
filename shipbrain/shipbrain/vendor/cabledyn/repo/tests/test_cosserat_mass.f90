! File: tests/test_cosserat_mass.f90
! SPDX-License-Identifier: Apache-2.0
! Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
PROGRAM test_cosserat_mass
  !! reference-parity check for the finite-EI element consistent mass
  !! (CD_Cosserat_Element_Mass) against independently computed values.
  !! A 45-degree tilted reference (Lam0 != I, so
  !! the rotational inertia is genuinely rotated to the global frame) with
  !! rho_A=2, I_rho_t=1e-3, I_rho_n=2e-3 is checked: full diagonal, Frobenius
  !! norm, total sum, the translational/rotational block factors, and symmetry.
  USE CableDyn_Precision, ONLY: wp
  USE CableDyn_Cosserat, ONLY: CD_Reference_Frame
  USE CableDyn_CosseratDynamic, ONLY: CD_Cosserat_Element_Mass, CD_Assemble_Cosserat_Mass
  IMPLICIT NONE

  REAL(wp), PARAMETER :: RHO_A = 2.0_wp, I_RHO_T = 1.0e-3_wp, I_RHO_N = 2.0e-3_wp
  REAL(wp), PARAMETER :: FTOL = 1.0e-12_wp, RTOL = 1.0e-12_wp
  INTEGER :: nfail, i
  REAL(wp) :: Lam0(3, 3), L0, M(12, 12), md(12), mdref(12), block_diag
  nfail = 0

  CALL CD_Reference_Frame([0.0_wp, 0.0_wp, 0.0_wp], [1.0_wp, 0.0_wp, 1.0_wp], Lam0, L0)
  M = CD_Cosserat_Element_Mass(L0, Lam0, RHO_A, I_RHO_T, I_RHO_N)

  ! diagonal vs reference
  mdref = [0.9428090415820634_wp, 0.9428090415820634_wp, 0.9428090415820634_wp, &
           0.0007071067811865475_wp, 0.0004714045207910317_wp, 0.0007071067811865475_wp, &
           0.9428090415820634_wp, 0.9428090415820634_wp, 0.9428090415820634_wp, &
           0.0007071067811865475_wp, 0.0004714045207910317_wp, 0.0007071067811865475_wp]
  DO i = 1, 12
    md(i) = M(i, i)
  END DO
  CALL require(nan_max_abs(md - mdref) < FTOL, 'mass-diagonal-vs-reference')
  CALL require(ABS(SQRT(SUM(M*M)) - 2.581989542968755_wp) < RTOL, 'mass-frobenius-vs-reference')
  CALL require(ABS(SUM(M) - 8.492352442050436_wp) < RTOL, 'mass-sum-vs-reference')

  ! translational coupling: M(1,7) = rho_A * L0/6
  block_diag = RHO_A*L0/6.0_wp
  CALL require(ABS(M(1, 7) - block_diag) < FTOL .AND. ABS(M(1, 1) - RHO_A*L0/3.0_wp) < FTOL, &
               'mass-translational-block')
  ! translational isotropy + decoupling from rotation: M(1,2) = 0, M(1,4) = 0
  CALL require(ABS(M(1, 2)) < FTOL .AND. ABS(M(1, 4)) < FTOL, 'mass-translation-decoupled')
  ! symmetry
  CALL require(nan_max_abs(M - TRANSPOSE(M)) < FTOL, 'mass-symmetric')

  ! === global assembly vs the reference_mass_matrix (2-element rod) ===
  CALL check_global_assembly()

  IF (nfail > 0) THEN
    WRITE (*, '(A,I0,A)') 'FAIL: ', nfail, ' assertion(s) failed'
    ERROR STOP 1
  END IF
  WRITE (*, '(A)') 'PASS: Fortran Cosserat consistent mass matches the independent reference values'

CONTAINS

  INCLUDE 'nan_max_abs.inc'

  SUBROUTINE check_global_assembly()
    !! 2-element rod (rho_A=2, I_rho_t=1e-3, I_rho_n=2e-3) along +z: assembled
    !! global mass vs the reference_mass_matrix (diag / Frobenius / sum;
    !! shared node-2 diagonal = 2*rho_A*L0e/3). Plus a fail-closed zero-length span.
    INTEGER, PARAMETER :: NN = 3, NE = 2, NDOF = 6*NN
    INTEGER :: conn(2, NE), es, k
    REAL(wp) :: nref(3, NN), ra(NE), it(NE), in_(NE), Mg(NDOF, NDOF), gd(NDOF), gdref(NDOF)
    REAL(wp) :: bad_nref(3, NN), Mbad(NDOF, NDOF)
    CHARACTER(120) :: em
    nref(:, 1) = [0.0_wp, 0.0_wp, 0.0_wp]; nref(:, 2) = [0.0_wp, 0.0_wp, 0.5_wp]
    nref(:, 3) = [0.0_wp, 0.0_wp, 1.0_wp]
    conn(:, 1) = [1, 2]; conn(:, 2) = [2, 3]
    ra = RHO_A; it = I_RHO_T; in_ = I_RHO_N
    CALL CD_Assemble_Cosserat_Mass(nref, conn, ra, it, in_, Mg, es, em)
    CALL require(es == 0, 'global-mass-ErrStat')
    gdref = [0.3333333333333333_wp, 0.3333333333333333_wp, 0.3333333333333333_wp, &
             0.00016666666666666666_wp, 0.00016666666666666666_wp, 0.0003333333333333333_wp, &
             0.6666666666666666_wp, 0.6666666666666666_wp, 0.6666666666666666_wp, &
             0.0003333333333333333_wp, 0.0003333333333333333_wp, 0.0006666666666666666_wp, &
             0.3333333333333333_wp, 0.3333333333333333_wp, 0.3333333333333333_wp, &
             0.00016666666666666666_wp, 0.00016666666666666666_wp, 0.0003333333333333333_wp]
    DO k = 1, NDOF
      gd(k) = Mg(k, k)
    END DO
    CALL require(nan_max_abs(gd - gdref) < FTOL, 'global-mass-diagonal-vs-reference')
    CALL require(ABS(SQRT(SUM(Mg*Mg)) - 1.5275256135332067_wp) < RTOL, 'global-mass-frobenius-vs-reference')
    CALL require(ABS(SUM(Mg) - 6.004_wp) < RTOL, 'global-mass-sum-vs-reference')
    CALL require(nan_max_abs(Mg - TRANSPOSE(Mg)) < FTOL, 'global-mass-symmetric')
    ! fail closed on a collapsed reference span
    bad_nref = nref; bad_nref(:, 2) = nref(:, 1)
    CALL CD_Assemble_Cosserat_Mass(bad_nref, conn, ra, it, in_, Mbad, es, em)
    CALL require(es /= 0, 'global-mass-reject-zero-length-span')
  END SUBROUTINE check_global_assembly

  SUBROUTINE require(cond, label)
    LOGICAL, INTENT(IN) :: cond
    CHARACTER(*), INTENT(IN) :: label
    IF (.NOT. cond) THEN
      WRITE (*, '(A,A,A)') 'MISMATCH [', label, ']: condition false'
      nfail = nfail + 1
    END IF
  END SUBROUTINE require

END PROGRAM test_cosserat_mass
