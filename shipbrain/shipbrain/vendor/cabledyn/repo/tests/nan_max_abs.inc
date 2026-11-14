! File: tests/nan_max_abs.inc
! SPDX-License-Identifier: Apache-2.0
! Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
!
! NaN-aware replacement for MAXVAL(ABS(x)) in test assertions, included after a test
! program's CONTAINS. MAXVAL skips NaN elements, so "MAXVAL(ABS(a - b)) < tol" passes when
! some entries are NaN; nan_max_abs returns NaN whenever any element is NaN, so every
! "<" / "<=" comparison against it fails.

  PURE REAL(wp) FUNCTION nan_max_abs(x) RESULT(m)
    USE CableDyn_Precision, ONLY: wp
    USE, INTRINSIC :: IEEE_ARITHMETIC, ONLY: IEEE_IS_NAN, IEEE_VALUE, IEEE_QUIET_NAN
    REAL(wp), INTENT(IN) :: x(..)
    LOGICAL :: has_nan
    m = 0.0_wp
    has_nan = .FALSE.
    SELECT RANK (x)
    RANK (0)
      m = ABS(x)
      has_nan = IEEE_IS_NAN(x)
    RANK (1)
      IF (SIZE(x) > 0) m = MAXVAL(ABS(x))
      has_nan = ANY(IEEE_IS_NAN(x))
    RANK (2)
      IF (SIZE(x) > 0) m = MAXVAL(ABS(x))
      has_nan = ANY(IEEE_IS_NAN(x))
    RANK (3)
      IF (SIZE(x) > 0) m = MAXVAL(ABS(x))
      has_nan = ANY(IEEE_IS_NAN(x))
    RANK (4)
      IF (SIZE(x) > 0) m = MAXVAL(ABS(x))
      has_nan = ANY(IEEE_IS_NAN(x))
    RANK DEFAULT
      has_nan = .TRUE.
    END SELECT
    IF (has_nan) m = IEEE_VALUE(m, IEEE_QUIET_NAN)
  END FUNCTION nan_max_abs
