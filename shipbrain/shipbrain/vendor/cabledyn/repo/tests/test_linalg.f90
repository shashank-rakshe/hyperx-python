! File: tests/test_linalg.f90
! SPDX-License-Identifier: Apache-2.0
! Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
PROGRAM test_linalg
  !! Unit checks for CableDyn_Linalg (ARCHITECTURE.md `src/` linear algebra
  !! helpers). These tests certify the dense-to-DGBSV packing bridge used by the
  !! finite-EI Cosserat static/dynamic solvers before direct banded assembly lands.
  !! Reference: LAPACK Users' Guide, DGBSV general band solver storage convention.
  USE CableDyn_Precision, ONLY: wp, CD_ZERO, CD_All_Finite
  USE CableDyn_Linalg, ONLY: CD_LINALG_OK, CD_LINALG_SINGULAR, CD_Factor_Banded, CD_Solve_Banded, &
                             CD_Solve_Dense_As_Banded, CD_Solve_Dense_As_Banded_Multiple, &
                             CD_Solve_Factored_Banded, CD_Solve_Banded_Refined, &
                             CD_Solve_Factored_Banded_Multiple
  USE, INTRINSIC :: IEEE_ARITHMETIC, ONLY: IEEE_VALUE, IEEE_QUIET_NAN, IEEE_IS_FINITE
  USE, INTRINSIC :: IEEE_ARITHMETIC, ONLY: IEEE_POSITIVE_INF, IEEE_NEGATIVE_INF
  IMPLICIT NONE

  INTEGER :: nfail
  nfail = 0

  CALL test_general_band()
  CALL test_general_band_multiple_rhs()
  CALL test_direct_banded()
  CALL test_refined_banded()
  CALL test_factored_banded_reuse()
  CALL test_diagonal_band()
  CALL test_singular_reports_failure()
  CALL test_factored_multiple_rhs()
  CALL test_all_finite()

  IF (nfail > 0) THEN
    WRITE (*, '(A,I0,A)') 'FAIL: ', nfail, ' assertion(s) failed'
    ERROR STOP 1
  END IF
  WRITE (*, '(A)') 'PASS: dense free-block packing solves with DGBSV'

CONTAINS

  INCLUDE 'nan_max_abs.inc'

  SUBROUTINE test_general_band()
    REAL(wp) :: A(5, 5), x_ref(5), rhs(5)
    INTEGER :: es, kl, ku
    CHARACTER(160) :: em

    A = CD_ZERO
    A(1, 1) = 4.0_wp; A(2, 2) = 5.0_wp; A(3, 3) = 6.0_wp
    A(4, 4) = 7.0_wp; A(5, 5) = 8.0_wp
    A(2, 1) = 1.0_wp; A(3, 2) = -2.0_wp; A(4, 3) = 0.5_wp; A(5, 4) = 1.5_wp
    A(1, 2) = -1.0_wp; A(2, 3) = 0.25_wp; A(3, 4) = 2.0_wp; A(4, 5) = -0.75_wp
    A(3, 1) = 0.75_wp; A(5, 3) = -1.25_wp
    A(1, 3) = 0.5_wp; A(2, 4) = -0.5_wp

    x_ref = [1.0_wp, -2.0_wp, 0.5_wp, 3.0_wp, -1.0_wp]
    rhs = MATMUL(A, x_ref)

    CALL CD_Solve_Dense_As_Banded(A, rhs, es, em, kl, ku)
    CALL require(es == CD_LINALG_OK, 'general-band:status')
    CALL require(kl == 2 .AND. ku == 2, 'general-band:bandwidth')
    CALL require(nan_max_abs(rhs - x_ref) < 1.0e-12_wp, 'general-band:solution')
  END SUBROUTINE test_general_band

  SUBROUTINE test_general_band_multiple_rhs()
    REAL(wp) :: A(5, 5), x_ref(5, 3), rhs(5, 3)
    INTEGER :: es, kl, ku
    CHARACTER(160) :: em

    A = CD_ZERO
    A(1, 1) = 4.0_wp; A(2, 2) = 5.0_wp; A(3, 3) = 6.0_wp
    A(4, 4) = 7.0_wp; A(5, 5) = 8.0_wp
    A(2, 1) = 1.0_wp; A(3, 2) = -2.0_wp; A(4, 3) = 0.5_wp; A(5, 4) = 1.5_wp
    A(1, 2) = -1.0_wp; A(2, 3) = 0.25_wp; A(3, 4) = 2.0_wp; A(4, 5) = -0.75_wp
    A(3, 1) = 0.75_wp; A(5, 3) = -1.25_wp
    A(1, 3) = 0.5_wp; A(2, 4) = -0.5_wp

    x_ref(:, 1) = [1.0_wp, -2.0_wp, 0.5_wp, 3.0_wp, -1.0_wp]
    x_ref(:, 2) = [-0.5_wp, 1.0_wp, 2.0_wp, -1.5_wp, 0.25_wp]
    x_ref(:, 3) = [0.0_wp, 0.75_wp, -1.0_wp, 0.5_wp, 2.0_wp]
    rhs = MATMUL(A, x_ref)

    CALL CD_Solve_Dense_As_Banded_Multiple(A, rhs, es, em, kl, ku)
    CALL require(es == CD_LINALG_OK, 'general-band-multiple:status')
    CALL require(kl == 2 .AND. ku == 2, 'general-band-multiple:bandwidth')
    CALL require(nan_max_abs(rhs - x_ref) < 1.0e-12_wp, 'general-band-multiple:solution')
  END SUBROUTINE test_general_band_multiple_rhs

  SUBROUTINE test_direct_banded()
    REAL(wp) :: A(4, 4), ab(4, 4), x_ref(4), rhs(4)
    INTEGER :: es, i, j, row
    CHARACTER(160) :: em

    A = CD_ZERO
    A(1, 1) = 3.0_wp; A(2, 2) = 4.0_wp; A(3, 3) = 5.0_wp; A(4, 4) = 6.0_wp
    A(2, 1) = -0.5_wp; A(3, 2) = 1.25_wp; A(4, 3) = -1.5_wp
    A(1, 2) = 0.75_wp; A(2, 3) = -0.25_wp; A(3, 4) = 0.5_wp
    x_ref = [2.0_wp, -1.0_wp, 0.5_wp, 3.0_wp]
    rhs = MATMUL(A, x_ref)

    ab = CD_ZERO
    DO j = 1, 4
      DO i = MAX(1, j - 1), MIN(4, j + 1)
        row = 1 + 1 + 1 + i - j
        ab(row, j) = A(i, j)
      END DO
    END DO

    CALL CD_Solve_Banded(ab, 1, 1, rhs, es, em)
    CALL require(es == CD_LINALG_OK, 'direct-banded:status')
    CALL require(nan_max_abs(rhs - x_ref) < 1.0e-12_wp, 'direct-banded:solution')
  END SUBROUTINE test_direct_banded

  SUBROUTINE test_refined_banded()
    !! DGBSVX consumes compact original storage internally while the public helper
    !! accepts the project's extended DGBSV layout. A strongly mixed row/column
    !! scale checks both the conversion and the equilibrated refined solution.
    REAL(wp) :: A(4, 4), ab(4, 4), x_ref(4), rhs(4)
    INTEGER :: es, i, j, row
    CHARACTER(160) :: em

    A = CD_ZERO
    A(1, 1) = 2.0e-8_wp; A(2, 2) = 3.0e4_wp; A(3, 3) = 4.0e-3_wp; A(4, 4) = 5.0e8_wp
    A(2, 1) = -1.0e-4_wp; A(3, 2) = 2.0_wp; A(4, 3) = -3.0e2_wp
    A(1, 2) = 5.0e-5_wp; A(2, 3) = -7.0_wp; A(3, 4) = 6.0e2_wp
    x_ref = [2.0_wp, -1.0_wp, 0.5_wp, 3.0_wp]
    rhs = MATMUL(A, x_ref)
    ab = CD_ZERO
    DO j = 1, 4
      DO i = MAX(1, j - 1), MIN(4, j + 1)
        row = 3 + i - j
        ab(row, j) = A(i, j)
      END DO
    END DO

    CALL CD_Solve_Banded_Refined(ab, 1, 1, rhs, es, em)
    CALL require(es == CD_LINALG_OK, 'refined-banded:status')
    CALL require(nan_max_abs(rhs - x_ref) < 1.0e-9_wp, 'refined-banded:solution')
  END SUBROUTINE test_refined_banded

  SUBROUTINE test_factored_banded_reuse()
    REAL(wp) :: A(4, 4), ab(4, 4), x1_ref(4), x2_ref(4), rhs1(4), rhs2(4)
    INTEGER :: es, i, j, row, ipiv(4)
    CHARACTER(160) :: em

    A = CD_ZERO
    A(1, 1) = 3.0_wp; A(2, 2) = 4.0_wp; A(3, 3) = 5.0_wp; A(4, 4) = 6.0_wp
    A(2, 1) = -0.5_wp; A(3, 2) = 1.25_wp; A(4, 3) = -1.5_wp
    A(1, 2) = 0.75_wp; A(2, 3) = -0.25_wp; A(3, 4) = 0.5_wp
    x1_ref = [2.0_wp, -1.0_wp, 0.5_wp, 3.0_wp]
    x2_ref = [-0.5_wp, 1.25_wp, 2.0_wp, -1.0_wp]
    rhs1 = MATMUL(A, x1_ref)
    rhs2 = MATMUL(A, x2_ref)

    ab = CD_ZERO
    DO j = 1, 4
      DO i = MAX(1, j - 1), MIN(4, j + 1)
        row = 1 + 1 + 1 + i - j
        ab(row, j) = A(i, j)
      END DO
    END DO

    CALL CD_Factor_Banded(ab, 1, 1, ipiv, es, em)
    CALL require(es == CD_LINALG_OK, 'factored-banded:factor-status')
    CALL CD_Solve_Factored_Banded(ab, 1, 1, ipiv, rhs1, es, em)
    CALL require(es == CD_LINALG_OK, 'factored-banded:solve1-status')
    CALL CD_Solve_Factored_Banded(ab, 1, 1, ipiv, rhs2, es, em)
    CALL require(es == CD_LINALG_OK, 'factored-banded:solve2-status')
    CALL require(nan_max_abs(rhs1 - x1_ref) < 1.0e-12_wp, 'factored-banded:solution1')
    CALL require(nan_max_abs(rhs2 - x2_ref) < 1.0e-12_wp, 'factored-banded:solution2')
  END SUBROUTINE test_factored_banded_reuse

  SUBROUTINE test_diagonal_band()
    REAL(wp) :: A(3, 3), x_ref(3), rhs(3)
    INTEGER :: es, kl, ku
    CHARACTER(160) :: em

    A = CD_ZERO
    A(1, 1) = 2.0_wp; A(2, 2) = 3.0_wp; A(3, 3) = 4.0_wp
    x_ref = [1.5_wp, -2.0_wp, 0.25_wp]
    rhs = MATMUL(A, x_ref)

    CALL CD_Solve_Dense_As_Banded(A, rhs, es, em, kl, ku)
    CALL require(es == CD_LINALG_OK, 'diagonal-band:status')
    CALL require(kl == 0 .AND. ku == 0, 'diagonal-band:bandwidth')
    CALL require(nan_max_abs(rhs - x_ref) < 1.0e-12_wp, 'diagonal-band:solution')
  END SUBROUTINE test_diagonal_band

  SUBROUTINE test_singular_reports_failure()
    REAL(wp) :: A(2, 2), ab(1, 2), rhs(2)
    INTEGER :: es
    CHARACTER(160) :: em

    A = CD_ZERO
    A(1, 1) = 1.0_wp
    rhs = [1.0_wp, 2.0_wp]

    CALL CD_Solve_Dense_As_Banded(A, rhs, es, em)
    CALL require(es == CD_LINALG_SINGULAR, 'singular:status')

    ab = CD_ZERO
    ab(1, 1) = 1.0_wp
    rhs = [1.0_wp, 2.0_wp]
    CALL CD_Solve_Banded_Refined(ab, 0, 0, rhs, es, em)
    CALL require(es == CD_LINALG_SINGULAR, 'singular-refined:status')
  END SUBROUTINE test_singular_reports_failure

  SUBROUTINE test_factored_multiple_rhs()
    !! One DGBTRS call over several right-hand sides equals one solve per column.
    INTEGER, PARAMETER :: N = 7, KL = 2, KU = 1, NRHS = 3
    REAL(wp) :: ab(2*KL + KU + 1, N), rhs(N, NRHS), col(N)
    INTEGER :: ipiv(N), es, i, j
    CHARACTER(160) :: em

    ab = CD_ZERO
    DO j = 1, N
      DO i = MAX(1, j - KU), MIN(N, j + KL)
        ab(KL + KU + 1 + i - j, j) = MERGE(6.0_wp, 1.0_wp/REAL(i + 2*j, wp), i == j)
      END DO
    END DO
    CALL CD_Factor_Banded(ab, KL, KU, ipiv, es, em)
    CALL require(es == CD_LINALG_OK, 'factored-multiple: factor')
    DO j = 1, NRHS
      DO i = 1, N
        rhs(i, j) = REAL(i*j, wp) - 0.5_wp*REAL(j, wp)
      END DO
    END DO
    CALL CD_Solve_Factored_Banded_Multiple(ab, KL, KU, ipiv, rhs, es, em)
    CALL require(es == CD_LINALG_OK, 'factored-multiple: solve')
    DO j = 1, NRHS
      DO i = 1, N
        col(i) = REAL(i*j, wp) - 0.5_wp*REAL(j, wp)
      END DO
      CALL CD_Solve_Factored_Banded(ab, KL, KU, ipiv, col, es, em)
      CALL require(es == CD_LINALG_OK .AND. nan_max_abs(col - rhs(:, j)) <= 1.0e-14_wp*nan_max_abs(col), &
                   'factored-multiple: column matches single solve')
    END DO
    rhs(3, 2) = IEEE_VALUE(rhs(3, 2), IEEE_QUIET_NAN)
    CALL CD_Solve_Factored_Banded_Multiple(ab, KL, KU, ipiv, rhs, es, em)
    CALL require(es /= CD_LINALG_OK, 'factored-multiple: non-finite rhs fails closed')
  END SUBROUTINE test_factored_multiple_rhs

  SUBROUTINE test_all_finite()
    !! CD_All_Finite equals ALL(IEEE_IS_FINITE(x)) for every class of binary64 value.
    REAL(wp) :: v(8), m(3, 4), c(2, 2, 2)
    INTEGER :: k

    v = [0.0_wp, -0.0_wp, 1.0_wp, -HUGE(1.0_wp), HUGE(1.0_wp), TINY(1.0_wp), TINY(1.0_wp)*0.25_wp, &
         -TINY(1.0_wp)*1.0e-10_wp]
    CALL require(CD_All_Finite(v) .AND. ALL(IEEE_IS_FINITE(v)), 'all-finite: finite, huge and subnormal values')
    CALL require(CD_All_Finite(v(1:0)), 'all-finite: empty array')
    DO k = 1, 3
      v(5) = HUGE(1.0_wp)
      SELECT CASE (k)
      CASE (1)
        v(5) = IEEE_VALUE(v(5), IEEE_QUIET_NAN)
      CASE (2)
        v(5) = IEEE_VALUE(v(5), IEEE_POSITIVE_INF)
      CASE (3)
        v(5) = IEEE_VALUE(v(5), IEEE_NEGATIVE_INF)
      END SELECT
      CALL require(.NOT. CD_All_Finite(v) .AND. .NOT. ALL(IEEE_IS_FINITE(v)), 'all-finite: NaN or Inf detected')
    END DO
    m = 1.0_wp
    CALL require(CD_All_Finite(m), 'all-finite: rank 2 finite')
    m(2, 4) = IEEE_VALUE(m(2, 4), IEEE_POSITIVE_INF)
    CALL require(.NOT. CD_All_Finite(m), 'all-finite: rank 2 Inf in the last column')
    c = 2.0_wp
    CALL require(CD_All_Finite(c), 'all-finite: rank 3 finite')
    c(1, 2, 2) = IEEE_VALUE(c(1, 2, 2), IEEE_QUIET_NAN)
    CALL require(.NOT. CD_All_Finite(c), 'all-finite: rank 3 NaN')
    CALL require(.NOT. CD_All_Finite(m(:, 3:4)) .AND. CD_All_Finite(m(:, 1:3)), 'all-finite: array sections')
  END SUBROUTINE test_all_finite

  SUBROUTINE require(cond, label)
    LOGICAL, INTENT(IN) :: cond
    CHARACTER(*), INTENT(IN) :: label
    IF (.NOT. cond) THEN
      WRITE (*, '(A,A,A)') 'MISMATCH [', label, ']: condition false'
      nfail = nfail + 1
    END IF
  END SUBROUTINE require

END PROGRAM test_linalg
