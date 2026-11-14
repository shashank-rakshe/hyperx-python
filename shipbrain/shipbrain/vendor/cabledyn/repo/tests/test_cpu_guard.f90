! File: tests/test_cpu_guard.f90
! SPDX-License-Identifier: Apache-2.0
! Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
PROGRAM test_cpu_guard
  !! The x86-64-v3 start-up processor check (src/cabledyn_cpu_guard.c).
  !!
  !! Argument 1 is 1 when the build sets CABLEDYN_TARGET_AVX2 and 0 otherwise: the guard must
  !! be armed exactly then. An armed guard has already let this process start, so the processor
  !! must then report no missing feature. The feature list and its count must agree, and a
  !! short buffer must be truncated, never overrun.
  USE, INTRINSIC :: ISO_C_BINDING, ONLY: C_INT, C_CHAR, C_NULL_CHAR
  IMPLICIT NONE
  INTERFACE
    FUNCTION cpu_guard_armed() BIND(C, name='cabledyn_cpu_guard_armed') RESULT(armed)
      IMPORT :: C_INT
      INTEGER(C_INT) :: armed
    END FUNCTION cpu_guard_armed
    FUNCTION cpu_missing_features(buf, length) BIND(C, name='cabledyn_cpu_missing_features') RESULT(n)
      IMPORT :: C_INT, C_CHAR
      CHARACTER(KIND=C_CHAR), INTENT(OUT) :: buf(*)
      INTEGER(C_INT), VALUE :: length
      INTEGER(C_INT) :: n
    END FUNCTION cpu_missing_features
  END INTERFACE
  CHARACTER(KIND=C_CHAR) :: buf(160), tiny(4)
  CHARACTER(16) :: arg
  INTEGER :: expected, n, n_tiny, used, i, nfail

  nfail = 0
  CALL GET_COMMAND_ARGUMENT(1, arg)
  READ (arg, *) expected

  IF (cpu_guard_armed() /= expected) THEN
    PRINT '(A,I0,A,I0)', 'FAIL: guard armed = ', cpu_guard_armed(), ', build expects ', expected
    nfail = nfail + 1
  END IF

  buf = 'x'
  n = cpu_missing_features(buf, SIZE(buf))
  used = 0
  DO i = 1, SIZE(buf)
    IF (buf(i) == C_NULL_CHAR) EXIT
    used = i
  END DO
  PRINT '(A,I0,A,160A)', 'missing x86-64-v3 features: ', n, ' ', buf(1:used)
  IF ((n == 0) .NEQV. (used == 0)) THEN
    PRINT '(A)', 'FAIL: the feature count and the feature list disagree'
    nfail = nfail + 1
  END IF
  IF (expected == 1 .AND. n /= 0) THEN
    PRINT '(A)', 'FAIL: an armed guard let a processor without x86-64-v3 start'
    nfail = nfail + 1
  END IF

  ! a 4-character buffer holds at most 3 characters and the terminator
  tiny = 'y'
  n_tiny = cpu_missing_features(tiny, SIZE(tiny))
  IF (n_tiny /= n .OR. ALL(tiny /= C_NULL_CHAR)) THEN
    PRINT '(A)', 'FAIL: a short buffer changed the count or lost its terminator'
    nfail = nfail + 1
  END IF

  IF (nfail > 0) ERROR STOP 1
  PRINT '(A)', 'PASS: cpu guard'
END PROGRAM test_cpu_guard
