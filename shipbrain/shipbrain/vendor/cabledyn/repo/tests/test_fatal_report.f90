! File: tests/test_fatal_report.f90
! SPDX-License-Identifier: Apache-2.0
! Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
PROGRAM test_fatal_report
  !! The driver's abnormal-end report (src/cabledyn_fatal.c, CableDyn_FatalReport).
  !!
  !!   test_fatal_report march <deck> <out_root>
  !!       runs a dynamic deck and checks that the march recorded the time of its last
  !!       committed step (TMax) for the report, and that the library, as a host such as
  !!       OpenFAST uses it (the report not installed), left the process's signal and
  !!       exception handlers as they were;
  !!   test_fatal_report sent_faults
  !!       (POSIX) SIGSEGV and SIGFPE sent with kill() are reported and sent again (the child
  !!       ends by the signal), never treated as hardware faults that re-execute;
  !!   test_fatal_report altstack
  !!       (POSIX) the main thread and each worker that calls CD_Fatal_Thread_Init get one
  !!       alternate signal stack of at least 64 KiB and the system's SIGSTKSZ;
  !!   test_fatal_report <fault> before|during
  !!       installs the report, optionally records a simulated time, and ends the process
  !!       with <fault>: overflow (unbounded recursion, a stack overflow), null (a write
  !!       through a null pointer), omp_overflow (a stack overflow on an OpenMP worker thread)
  !!       or term (SIGTERM; POSIX only). tests/check_fatal_report.cmake checks the exit status
  !!       and the stderr line;
  !!   test_fatal_report context
  !!       (POSIX) a child process with an earlier three-argument SIGSEGV handler faults at a
  !!       known address: that handler must receive the fault's own siginfo, the child must end
  !!       by the fault's signal, and the report must be written once;
  !!   test_fatal_report dispositions
  !!       (POSIX) an ignored SIGTERM, with or without SA_SIGINFO, stays ignored and unreported;
  !!       a default one is reported and ends the process; a previous handler still runs.
  USE, INTRINSIC :: ISO_C_BINDING, ONLY: C_DOUBLE, C_INT
  USE, INTRINSIC :: ISO_FORTRAN_ENV, ONLY: error_unit
  USE CableDyn_Precision, ONLY: wp
  USE CableDyn_FatalReport, ONLY: CD_Fatal_Report_Install, CD_Fatal_Report_Time, CD_Fatal_Thread_Init
  USE CableDyn_DeckDriver, ONLY: CD_Run_Deck_Driver, CD_DECKDRV_OK
  IMPLICIT NONE

  INTERFACE
    REAL(C_DOUBLE) FUNCTION last_time() BIND(C, name='cabledyn_fatal_report_last_time')
      IMPORT :: C_DOUBLE
    END FUNCTION last_time
    SUBROUTINE null_write() BIND(C, name='fatal_report_test_null_write')
    END SUBROUTINE null_write
    INTEGER(C_INT) FUNCTION raise_term() BIND(C, name='fatal_report_test_raise_term')
      IMPORT :: C_INT
    END FUNCTION raise_term
    INTEGER(C_INT) FUNCTION fault_context() BIND(C, name='fatal_report_test_fault_context')
      IMPORT :: C_INT
    END FUNCTION fault_context
    INTEGER(C_INT) FUNCTION dispositions() BIND(C, name='fatal_report_test_dispositions')
      IMPORT :: C_INT
    END FUNCTION dispositions
    INTEGER(C_INT) FUNCTION altstack() BIND(C, name='fatal_report_test_altstack')
      IMPORT :: C_INT
    END FUNCTION altstack
    INTEGER(C_INT) FUNCTION sent_faults() BIND(C, name='fatal_report_test_sent_faults')
      IMPORT :: C_INT
    END FUNCTION sent_faults
    INTEGER(C_INT) FUNCTION handlers_unchanged(phase) BIND(C, name='fatal_report_test_handlers_unchanged')
      IMPORT :: C_INT
      INTEGER(C_INT), VALUE :: phase
    END FUNCTION handlers_unchanged
  END INTERFACE

  CHARACTER(4096) :: mode, arg2, arg3
  CHARACTER(1024) :: msg
  LOGICAL :: converged
  INTEGER :: stat

  CALL GET_COMMAND_ARGUMENT(1, mode)
  CALL GET_COMMAND_ARGUMENT(2, arg2)
  CALL GET_COMMAND_ARGUMENT(3, arg3)

  IF (mode == 'march') THEN
    IF (last_time() >= 0.0_C_DOUBLE) CALL fail('a time is recorded before any step')
    ! Negative and NaN times are not committed steps and leave the record unchanged.
    CALL CD_Fatal_Report_Time(-1.0_wp)
    IF (last_time() >= 0.0_C_DOUBLE) CALL fail('a negative time was recorded')
    IF (handlers_unchanged(0_C_INT) /= 0_C_INT) CALL fail('cannot record the handlers')
    CALL CD_Run_Deck_Driver(TRIM(arg2), TRIM(arg3), converged, stat, msg)
    IF (handlers_unchanged(1_C_INT) /= 0_C_INT) CALL fail('the library changed the host handlers')
    IF (stat /= CD_DECKDRV_OK .OR. .NOT. converged) CALL fail('the deck did not run: '//TRIM(msg))
    ! examples/dynamic_chain_held.dat: TMax 10 s.
    IF (ABS(last_time() - 10.0_C_DOUBLE) > 1.0E-9_C_DOUBLE) THEN
      WRITE (msg, '(A,ES23.15)') 'the march recorded t = ', last_time()
      CALL fail(TRIM(msg)//', expected the last committed step at TMax = 10 s')
    END IF
    WRITE (*, '(A)') 'PASS: the march records the time of its last committed step'
    STOP
  END IF

  IF (mode == 'context') THEN
    SELECT CASE (fault_context())
    CASE (-1)
      WRITE (*, '(A)') 'SKIP: the fault-context check is POSIX-only'
    CASE (0)
      WRITE (*, '(A)') 'PASS: the fault reached the earlier handler with its own context'
    CASE DEFAULT
      CALL fail('the fault did not keep its own context')
    END SELECT
    STOP
  END IF

  IF (mode == 'sent_faults') THEN
    SELECT CASE (sent_faults())
    CASE (-1)
      WRITE (*, '(A)') 'SKIP: the sent-fault check is POSIX-only'
    CASE (0)
      WRITE (*, '(A)') 'PASS: faults sent with kill() are reported and sent again'
    CASE DEFAULT
      CALL fail('a fault sent with kill() was not sent again')
    END SELECT
    STOP
  END IF

  IF (mode == 'altstack') THEN
    SELECT CASE (altstack())
    CASE (-1)
      WRITE (*, '(A)') 'SKIP: the alternate-stack check is POSIX-only'
    CASE (0)
      WRITE (*, '(A)') 'PASS: each prepared thread has one alternate signal stack of the system size'
    CASE DEFAULT
      CALL fail('an alternate signal stack is missing or too small')
    END SELECT
    STOP
  END IF

  IF (mode == 'dispositions') THEN
    SELECT CASE (dispositions())
    CASE (-1)
      WRITE (*, '(A)') 'SKIP: the disposition check is POSIX-only'
    CASE (0)
      WRITE (*, '(A)') 'PASS: ignored signals stay ignored; others are reported and passed on'
    CASE DEFAULT
      CALL fail('a previous signal disposition was not kept')
    END SELECT
    STOP
  END IF

  CALL CD_Fatal_Report_Install()
  CALL CD_Fatal_Report_Install() ! idempotent
  IF (arg2 == 'during') THEN
    CALL CD_Fatal_Report_Time(0.05_wp)
    CALL CD_Fatal_Report_Time(7534.6_wp)
  END IF
  SELECT CASE (TRIM(mode))
  CASE ('overflow')
    WRITE (error_unit, '(A,I0)') 'unreachable: ', deep(1)
  CASE ('null')
    CALL null_write()
  CASE ('omp_overflow')
    CALL overflow_on_worker()
  CASE ('term')
    IF (raise_term() == 0_C_INT) THEN
      WRITE (*, '(A)') 'SKIP: no SIGTERM on this platform'
      STOP
    END IF
  CASE DEFAULT
    CALL fail('unknown mode "'//TRIM(mode)//'"')
  END SELECT
  CALL fail('the '//TRIM(mode)//' fault did not end the process')

CONTAINS

  RECURSIVE INTEGER FUNCTION deep(depth) RESULT(r)
    !! 64 KiB of stack per level without bound: a stack overflow on any stack size.
    INTEGER, INTENT(IN) :: depth
    INTEGER :: frame(16384)
    frame = depth
    IF (depth < 0) THEN
      r = 0
      RETURN
    END IF
    r = deep(depth + 1) + frame(MOD(depth, 16384) + 1)
  END FUNCTION deep

  SUBROUTINE overflow_on_worker()
    !! A stack overflow on OpenMP worker thread 1 (its stack set by OMP_STACKSIZE) while the
    !! main thread waits at the region's barrier.
!$  USE omp_lib, ONLY: omp_get_num_threads, omp_get_thread_num
    INTEGER :: r
    r = 0
    !$OMP PARALLEL NUM_THREADS(2) DEFAULT(SHARED) FIRSTPRIVATE(r)
    CALL CD_Fatal_Thread_Init()
!$  IF (omp_get_num_threads() >= 2) THEN
!$    IF (omp_get_thread_num() == 1) THEN
!$      r = deep(1)
!$      WRITE (error_unit, '(A,I0)') 'unreachable: ', r
!$    END IF
!$  END IF
    !$OMP END PARALLEL
!$  CALL fail('the parallel region had no worker thread')
    WRITE (*, '(A)') 'SKIP: this build has no OpenMP'
    STOP
  END SUBROUTINE overflow_on_worker

  SUBROUTINE fail(text)
    CHARACTER(*), INTENT(IN) :: text
    WRITE (error_unit, '(A)') 'FAIL: test_fatal_report: '//text
    ERROR STOP 3
  END SUBROUTINE fail

END PROGRAM test_fatal_report
