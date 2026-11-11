! File: src/CableDyn_Precision.f90
! SPDX-License-Identifier: Apache-2.0
! Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
MODULE CableDyn_Precision
  !! Working precision and shared real constants for the CableDyn Fortran core.
  !!
  !! Every module uses `wp` from here; never `REAL*8` or `DOUBLE PRECISION`
  !! (DEVELOPMENT.md "Coding Standards"). `wp` is IEEE double precision
  !! (15 significant digits, exponent range to 10^307), i.e. IEEE 754
  !! binary64.
  IMPLICIT NONE
  PRIVATE

  INTEGER, PARAMETER, PUBLIC :: wp = SELECTED_REAL_KIND(15, 307)

  REAL(wp), PARAMETER, PUBLIC :: CD_ZERO = 0.0_wp
  REAL(wp), PARAMETER, PUBLIC :: CD_ONE = 1.0_wp
  ! The smallest time step any march takes: the implicit integrators divide by dt^2, which
  ! overflows the inertia terms near 1e-155 s; this bound keeps a wide margin above that.
  REAL(wp), PARAMETER, PUBLIC :: CD_MIN_TIME_STEP = 1.0e-100_wp

  PUBLIC :: CD_All_Finite, CD_Is_Finite

  INTERFACE CD_All_Finite
    !! ALL(IEEE_IS_FINITE(x)) for a real(wp) array, as one call per array. A value is
    !! finite when its binary64 exponent field is not all ones, which is what
    !! IEEE_IS_FINITE tests; the bit test is inlined into the loop, whereas some
    !! compilers (IFX) evaluate IEEE_IS_FINITE as a library call per element.
    MODULE PROCEDURE all_finite_1, all_finite_2, all_finite_3
  END INTERFACE CD_All_Finite

  INTEGER, PARAMETER :: I8 = SELECTED_INT_KIND(18)
  INTEGER(I8), PARAMETER :: EXPONENT_MASK = 2047_I8

CONTAINS

  ELEMENTAL LOGICAL FUNCTION CD_Is_Finite(x) RESULT(finite)
    !! IEEE_IS_FINITE(x) for real(wp) by the same exponent-bit test as CD_All_Finite: no
    !! floating-point operation (so no signalling-NaN trap) and inlinable, where IFX calls
    !! IEEE_IS_FINITE through its run-time library.
    REAL(wp), INTENT(IN) :: x

    finite = IAND(SHIFTR(TRANSFER(x, 0_I8), 52), EXPONENT_MASK) /= EXPONENT_MASK
  END FUNCTION CD_Is_Finite

  PURE LOGICAL FUNCTION all_finite_1(x) RESULT(finite)
    REAL(wp), INTENT(IN) :: x(:)
    INTEGER :: i
    INTEGER(I8) :: nonfinite, exponent

    nonfinite = 0_I8
    DO i = 1, SIZE(x)
      exponent = IAND(SHIFTR(TRANSFER(x(i), 0_I8), 52), EXPONENT_MASK)
      nonfinite = IOR(nonfinite, MERGE(1_I8, 0_I8, exponent == EXPONENT_MASK))
    END DO
    finite = nonfinite == 0_I8
  END FUNCTION all_finite_1

  PURE LOGICAL FUNCTION all_finite_2(x) RESULT(finite)
    ! The column test is inlined rather than called per column: the arrays checked most
    ! often are 12 x 12 element matrices, where a call per column costs more than the test.
    REAL(wp), INTENT(IN) :: x(:, :)
    INTEGER :: i, j
    INTEGER(I8) :: nonfinite, exponent

    finite = .TRUE.
    DO j = 1, SIZE(x, 2)
      nonfinite = 0_I8
      DO i = 1, SIZE(x, 1)
        exponent = IAND(SHIFTR(TRANSFER(x(i, j), 0_I8), 52), EXPONENT_MASK)
        nonfinite = IOR(nonfinite, MERGE(1_I8, 0_I8, exponent == EXPONENT_MASK))
      END DO
      IF (nonfinite /= 0_I8) THEN
        finite = .FALSE.
        RETURN
      END IF
    END DO
  END FUNCTION all_finite_2

  PURE LOGICAL FUNCTION all_finite_3(x) RESULT(finite)
    REAL(wp), INTENT(IN) :: x(:, :, :)
    INTEGER :: i, j, k
    INTEGER(I8) :: nonfinite, exponent

    finite = .TRUE.
    DO k = 1, SIZE(x, 3)
      DO j = 1, SIZE(x, 2)
        nonfinite = 0_I8
        DO i = 1, SIZE(x, 1)
          exponent = IAND(SHIFTR(TRANSFER(x(i, j, k), 0_I8), 52), EXPONENT_MASK)
          nonfinite = IOR(nonfinite, MERGE(1_I8, 0_I8, exponent == EXPONENT_MASK))
        END DO
        IF (nonfinite /= 0_I8) THEN
          finite = .FALSE.
          RETURN
        END IF
      END DO
    END DO
  END FUNCTION all_finite_3

END MODULE CableDyn_Precision
