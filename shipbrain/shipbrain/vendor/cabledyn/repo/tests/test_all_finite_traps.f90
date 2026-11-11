! File: tests/test_all_finite_traps.f90
! SPDX-License-Identifier: Apache-2.0
! Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
PROGRAM test_all_finite_traps
  !! CD_All_Finite and CD_Is_Finite must classify every binary64 value without a floating-point operation:
  !! this program is built with invalid/zero/overflow trapping enabled (CMakeLists.txt), so a
  !! comparison or arithmetic on a signalling NaN inside the check would stop it. The
  !! non-finite values are built from their bit patterns, so nothing here touches them with a
  !! floating-point instruction before CD_All_Finite does.
  USE CableDyn_Precision, ONLY: wp, CD_All_Finite, CD_Is_Finite
  IMPLICIT NONE

  INTEGER, PARAMETER :: I8 = SELECTED_INT_KIND(18)
  ! binary64 bit patterns: signalling NaN (quiet bit clear), negative signalling NaN,
  ! quiet NaN, +Inf, -Inf, largest finite, smallest subnormal, negative zero
  INTEGER(I8), PARAMETER :: SNAN = INT(Z'7FF4000000000001', I8)
  INTEGER(I8), PARAMETER :: SNAN_NEG = INT(Z'FFF0000000000001', I8)
  INTEGER(I8), PARAMETER :: QNAN = INT(Z'7FF8000000000000', I8)
  INTEGER(I8), PARAMETER :: PINF = INT(Z'7FF0000000000000', I8)
  INTEGER(I8), PARAMETER :: NINF = INT(Z'FFF0000000000000', I8)
  INTEGER(I8), PARAMETER :: BIGGEST = INT(Z'7FEFFFFFFFFFFFFF', I8)
  INTEGER(I8), PARAMETER :: SUBNORMAL = INT(Z'0000000000000001', I8)
  INTEGER(I8), PARAMETER :: NEG_ZERO = INT(Z'8000000000000000', I8)
  INTEGER(I8), PARAMETER :: NONFINITE(5) = [SNAN, SNAN_NEG, QNAN, PINF, NINF]

  REAL(wp) :: v(6), m(4, 3), c(2, 3, 2), s
  INTEGER :: k, nfail

  nfail = 0
  v = TRANSFER([BIGGEST, SUBNORMAL, NEG_ZERO, BIGGEST, SUBNORMAL, NEG_ZERO], v)
  CALL require(CD_All_Finite(v), 'finite extremes, subnormal and negative zero are finite')
  CALL require(ALL(CD_Is_Finite(v)), 'scalar test: finite extremes, subnormal and negative zero are finite')
  DO k = 1, SIZE(NONFINITE)
    v = TRANSFER([BIGGEST, SUBNORMAL, NEG_ZERO, BIGGEST, SUBNORMAL, NEG_ZERO], v)
    v(4) = TRANSFER(NONFINITE(k), v(4))
    CALL require(.NOT. CD_All_Finite(v), 'rank 1: non-finite value detected without a trap')
    m = TRANSFER(BIGGEST, 1.0_wp)
    m(3, 2) = TRANSFER(NONFINITE(k), m(3, 2))
    CALL require(.NOT. CD_All_Finite(m), 'rank 2: non-finite value detected without a trap')
    CALL require(CD_All_Finite(m(:, 1)) .AND. CD_All_Finite(m(:, 3)), 'rank 2: finite columns pass')
    c = TRANSFER(SUBNORMAL, 1.0_wp)
    c(2, 3, 2) = TRANSFER(NONFINITE(k), c(2, 3, 2))
    CALL require(.NOT. CD_All_Finite(c), 'rank 3: non-finite value detected without a trap')
    s = TRANSFER(NONFINITE(k), s)
    CALL require(.NOT. CD_Is_Finite(s), 'scalar: non-finite value detected without a trap')
    CALL require(COUNT(.NOT. CD_Is_Finite(v)) == 1 .AND. .NOT. CD_Is_Finite(v(4)), &
                 'elemental: exactly the non-finite entry is flagged')
  END DO

  IF (nfail > 0) THEN
    WRITE (*, '(A,I0,A)') 'FAIL: ', nfail, ' assertion(s) failed'
    ERROR STOP 1
  END IF
  WRITE (*, '(A)') 'PASS: CD_All_Finite and CD_Is_Finite classify signalling NaN, quiet NaN and infinities '// &
    'without trapping'

CONTAINS

  SUBROUTINE require(cond, label)
    LOGICAL, INTENT(IN) :: cond
    CHARACTER(*), INTENT(IN) :: label
    IF (.NOT. cond) THEN
      WRITE (*, '(A,A,A)') 'MISMATCH [', label, ']: condition false'
      nfail = nfail + 1
    END IF
  END SUBROUTINE require

END PROGRAM test_all_finite_traps
