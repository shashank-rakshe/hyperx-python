! File: tests/test_output_formats.f90
! SPDX-License-Identifier: Apache-2.0
! Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
PROGRAM test_output_formats
  !! Gate for the channel-value formats of the time-series files (CD_CHANNEL_FMT, the
  !! standalone .out files; CD_NATIVE_CHANNEL_FMT, OpenFAST's native <root>.CD.out). Every
  !! value a channel can carry must print as a number any reader parses: no field of
  !! asterisks (a two-digit exponent overflows below 1e-99 and from 1e100, the round-off
  !! noise of a zero component such as the y position of a line in the x-z plane), and the
  !! exponent letter kept (an unstated exponent width drops it at three digits, which
  !! Python's float() rejects). Each field is TAB plus mantissa, 'E', sign and three
  !! digits, and reads back to its printed precision (zero exactly).
  USE CableDyn_Precision, ONLY: wp
  USE CableDyn_Conventions, ONLY: CD_CHANNEL_FMT, CD_NATIVE_CHANNEL_FMT
  IMPLICIT NONE
  REAL(wp), PARAMETER :: VALUES(13) = [0.0_wp, 1.0e-120_wp, -3.0e150_wp, 9.99999949e-100_wp, -1.0e-99_wp, &
                                       1.0e100_wp, -9.9999999e99_wp, 1.0e-310_wp, 5.0988032e5_wp, &
                                       -1.961023e-2_wp, 1.0_wp, HUGE(1.0_wp), -TINY(1.0_wp)]
  INTEGER :: nfail, i

  nfail = 0
  DO i = 1, SIZE(VALUES)
    CALL check(CD_CHANNEL_FMT, 'standalone', VALUES(i), 15, 5.0e-8_wp)
    CALL check(CD_NATIVE_CHANNEL_FMT, 'native', VALUES(i), 15, 5.0e-7_wp)
  END DO
  IF (nfail > 0) THEN
    WRITE (*, '(A,I0,A)') 'FAIL: ', nfail, ' assertion(s) failed'
    ERROR STOP 1
  END IF
  WRITE (*, '(A)') 'PASS: channel-value formats print every magnitude as a parseable number'

CONTAINS

  SUBROUTINE check(fmt, label, x, width, rel)
    !! Write TAB + x with fmt, then check the field's shape and its read-back value.
    CHARACTER(*), INTENT(IN) :: fmt, label
    REAL(wp), INTENT(IN) :: x, rel
    INTEGER, INTENT(IN) :: width
    CHARACTER(64) :: buf
    CHARACTER(:), ALLOCATABLE :: field
    REAL(wp) :: y
    INTEGER :: ios, ie, n
    CHARACTER(32) :: shown

    WRITE (shown, '(ES24.16E3)') x
    WRITE (buf, fmt, IOSTAT=ios) CHAR(9), x
    IF (ios /= 0) THEN
      CALL fail(label//' write failed for '//TRIM(shown)); RETURN
    END IF
    n = LEN_TRIM(buf)
    IF (buf(1:1) /= CHAR(9) .OR. n /= width + 1) THEN
      CALL fail(label//' field is not TAB plus a fixed width for '//TRIM(shown)//': "'//TRIM(buf)//'"'); RETURN
    END IF
    field = TRIM(ADJUSTL(buf(2:n)))
    IF (INDEX(field, '*') > 0) THEN
      CALL fail(label//' field overflows for '//TRIM(shown)//': "'//field//'"'); RETURN
    END IF
    ! mantissa, then E, a sign and exactly three exponent digits at the end of the field
    ie = INDEX(field, 'E', BACK=.TRUE.)
    IF (ie == 0 .OR. ie /= LEN(field) - 4) THEN
      CALL fail(label//' field lacks a three-digit E exponent for '//TRIM(shown)//': "'//field//'"'); RETURN
    END IF
    IF (VERIFY(field(ie + 1:ie + 1), '+-') /= 0 .OR. VERIFY(field(ie + 2:), '0123456789') /= 0) THEN
      CALL fail(label//' exponent is not a sign and three digits for '//TRIM(shown)//': "'//field//'"'); RETURN
    END IF
    READ (field, *, IOSTAT=ios) y
    IF (ios /= 0) THEN
      CALL fail(label//' field does not read back for '//TRIM(shown)//': "'//field//'"'); RETURN
    END IF
    ! ABS(.) >= 0, so "not > 0" tests an exact zero without a REAL equality compare
    IF (.NOT. (ABS(x) > 0.0_wp)) THEN
      IF (ABS(y) > 0.0_wp) CALL fail(label//' zero does not read back as zero: "'//field//'"')
    ELSE IF (ABS(y - x) > rel*ABS(x)) THEN
      CALL fail(label//' value does not round-trip for '//TRIM(shown)//': "'//field//'"')
    END IF
  END SUBROUTINE check

  SUBROUTINE fail(msg)
    CHARACTER(*), INTENT(IN) :: msg
    WRITE (*, '(A)') 'MISMATCH: '//msg
    nfail = nfail + 1
  END SUBROUTINE fail

END PROGRAM test_output_formats
