! File: tests/test_crt_locale_guard.f90
! SPDX-License-Identifier: Apache-2.0
! Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
MODULE crt_locale_guard_churn
  !! Heap churn evaluated inside an I/O statement, between libgfortran's locale query
  !! (statement start) and its restore (statement end).
  IMPLICIT NONE
  PRIVATE
  PUBLIC :: fill_heap, churned_value
  TYPE :: small_block
    INTEGER(1), ALLOCATABLE :: bytes(:)
  END TYPE small_block
  TYPE(small_block), ALLOCATABLE :: blocks(:)
  INTERFACE
    SUBROUTINE cabledyn_test_release_free_heap() BIND(C, name='cabledyn_test_release_free_heap')
    END SUBROUTINE cabledyn_test_release_free_heap
  END INTERFACE
CONTAINS
  SUBROUTINE fill_heap(n)
    !! Occupy many small-block heap pages, including the pages the locale query uses.
    INTEGER, INTENT(IN) :: n
    INTEGER :: i
    ALLOCATE (blocks(n))
    DO i = 1, n
      ALLOCATE (blocks(i)%bytes(2 + MOD(i, 12)))
    END DO
  END SUBROUTINE fill_heap

  INTEGER FUNCTION churned_value(k)
    !! Free every small block and return the free pages to the system, then return k.
    INTEGER, INTENT(IN) :: k
    IF (ALLOCATED(blocks)) DEALLOCATE (blocks)
    CALL cabledyn_test_release_free_heap()
    churned_value = k
  END FUNCTION churned_value
END MODULE crt_locale_guard_churn

PROGRAM test_crt_locale_guard
  !! Regression for the libgfortran setlocale use-after-free (src/cabledyn_crt_locale.c).
  !!
  !!   test_crt_locale_guard <min_slots>
  !!
  !! <min_slots> is the number of setlocale import slots the guard must redirect:
  !! 1 on MinGW-w64 (the libgfortran import), 0 where the guard is a no-op. The program
  !! never installs the guard before its I/O: the load-time constructor pulled in by
  !! the static core must already have done so. Each cycle frees the heap pages behind
  !! libgfortran's saved locale name while a WRITE is in flight; without the guard the
  !! restore at the end of that WRITE reads the released page and the process dies
  !! with SIGSEGV on the first cycles. Afterwards the slot count is checked, and a
  !! repeat install must redirect nothing new.
  USE, INTRINSIC :: ISO_C_BINDING, ONLY: C_INT
  USE crt_locale_guard_churn, ONLY: fill_heap, churned_value
  IMPLICIT NONE
  INTERFACE
    INTEGER(C_INT) FUNCTION cabledyn_crt_locale_guard_slots() BIND(C, name='cabledyn_crt_locale_guard_slots')
      IMPORT :: C_INT
    END FUNCTION cabledyn_crt_locale_guard_slots
  END INTERFACE
  INTEGER, PARAMETER :: NCYCLE = 100, NBLOCK = 50000
  CHARACTER(32) :: arg, text
  INTEGER :: min_slots, slots, ios, k, nfail

  nfail = 0
  CALL GET_COMMAND_ARGUMENT(1, arg)
  READ (arg, *, IOSTAT=ios) min_slots
  IF (ios /= 0) min_slots = 0

  DO k = 1, NCYCLE
    CALL fill_heap(NBLOCK)
    WRITE (text, '(I0,F5.1)') churned_value(k), 1.5
    IF (text /= int_text(k)//'  1.5') THEN
      WRITE (*, '(A,I0,2A)') 'FAIL cycle ', k, ' wrote ', TRIM(text)
      nfail = nfail + 1
      EXIT
    END IF
  END DO

  slots = cabledyn_crt_locale_guard_slots()
  IF (slots < min_slots) THEN
    WRITE (*, '(A,I0,A,I0)') 'FAIL guard redirected ', slots, ' setlocale slot(s), expected >= ', min_slots
    nfail = nfail + 1
  END IF
  IF (cabledyn_crt_locale_guard_slots() /= slots) THEN
    WRITE (*, '(A)') 'FAIL repeat install changed the redirected slot count'
    nfail = nfail + 1
  END IF

  IF (nfail /= 0) ERROR STOP 1
  WRITE (*, '(A,I0,A)') 'PASS crt_locale_guard (', slots, ' slot(s))'
CONTAINS
  FUNCTION int_text(k) RESULT(s)
    INTEGER, INTENT(IN) :: k
    CHARACTER(:), ALLOCATABLE :: s
    CHARACTER(16) :: buf
    WRITE (buf, '(I0)') k
    s = TRIM(buf)
  END FUNCTION int_text
END PROGRAM test_crt_locale_guard
