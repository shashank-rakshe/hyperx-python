! File: src/CableDyn_Profile.f90
! SPDX-License-Identifier: Apache-2.0
! Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
MODULE CableDyn_Profile
  !! Opt-in wall-clock profile of a standalone driver run, requested with the environment
  !! variable CABLEDYN_PROFILE (as for the OpenFAST module).
  !!
  !! The driver arms it once at start, in the input phase. The run then marks where each phase
  !! begins: CD_Profile_Enter(phase) adds the time since the previous mark to the phase that
  !! was running and makes phase the running one, so the phases partition the run exactly and
  !! a run that stops with an error has its time up to the stop in the phase it stopped in.
  !! Each time march enters its fluid update, its step, its checks, its output and its
  !! progress report in turn; CD_Profile_Step counts the committed steps. CD_Step_Model counts
  !! the EI = 0 line steps and their Newton iterations, and the step of an EI = 0 line times its
  !! kernels between CD_Profile_Kernel_Begin and CD_Profile_Kernel_End: the residual-only
  !! evaluations, the evaluations that also assemble the effective tangent, the factorisations of
  !! that tangent and the back-substitutions with it (CD_Profile_Kernels reads them; their times
  !! are summed over the lines, so they exceed the wall time when lines step concurrently).
  !! Unarmed, every entry point returns after one test, so a run that does not ask for the
  !! profile, and a host that loads the library, are not affected. The state is process-global
  !! and serves one run: the phase marks are taken on the driver's thread, and the line-step and
  !! kernel counters are updated atomically because lines step concurrently. The OpenFAST module
  !! arms it with its own profiler and disarms it (CD_Profile_Disarm) when the host does not ask.
  USE, INTRINSIC :: ISO_FORTRAN_ENV, ONLY: int64
  USE CableDyn_Precision, ONLY: wp
  IMPLICIT NONE
  PRIVATE
  PUBLIC :: CD_Profile_Requested, CD_Profile_Arm, CD_Profile_Disarm, CD_Profile_Armed, CD_Profile_Enter, &
            CD_Profile_Flush, CD_Profile_Step, CD_Profile_Count_Line_Step, CD_Profile_Seconds, CD_Profile_Counts, &
            CD_Profile_Kernel_Begin, CD_Profile_Kernel_End, CD_Profile_Kernels

  INTEGER, PARAMETER, PUBLIC :: CD_PROF_INPUT = 1     ! deck parsing and auxiliary input files
  INTEGER, PARAMETER, PUBLIC :: CD_PROF_INIT = 2      ! model build, static equilibrium, initial outputs
  INTEGER, PARAMETER, PUBLIC :: CD_PROF_FLUID = 3     ! march: deck waves and current sampled by the driver
  INTEGER, PARAMETER, PUBLIC :: CD_PROF_SOLVE = 4     ! march: line, cable and object steps
  INTEGER, PARAMETER, PUBLIC :: CD_PROF_CHECK = 5     ! march: plausibility checks and line failures
  INTEGER, PARAMETER, PUBLIC :: CD_PROF_OUTPUT = 6    ! march: output channels, line files, range graphs
  INTEGER, PARAMETER, PUBLIC :: CD_PROF_PROGRESS = 7  ! march: progress report and bookkeeping
  INTEGER, PARAMETER, PUBLIC :: CD_PROF_FINAL = 8     ! after the march: closing files, range files
  INTEGER, PARAMETER, PUBLIC :: CD_PROF_NPHASE = 8

  ! Kernels of the EI = 0 line step (CD_Cable_Gen_Alpha_Step)
  INTEGER, PARAMETER, PUBLIC :: CD_PROF_K_RESIDUAL = 1  ! residual-only evaluation
  INTEGER, PARAMETER, PUBLIC :: CD_PROF_K_TANGENT = 2   ! residual and effective-tangent evaluation
  INTEGER, PARAMETER, PUBLIC :: CD_PROF_K_FACTOR = 3    ! LU factorisation of the effective tangent
  INTEGER, PARAMETER, PUBLIC :: CD_PROF_K_SOLVE = 4     ! back-substitution with a factored tangent
  INTEGER, PARAMETER, PUBLIC :: CD_PROF_NKERNEL = 4

  LOGICAL, SAVE :: armed = .FALSE.
  INTEGER, SAVE :: current = CD_PROF_INPUT
  INTEGER(int64), SAVE :: rate = 0_int64, last = 0_int64
  INTEGER(int64), SAVE :: ticks(CD_PROF_NPHASE) = 0_int64
  INTEGER(int64), SAVE :: n_march_steps = 0_int64, n_line_steps = 0_int64, n_line_iter = 0_int64
  INTEGER, SAVE :: max_line_iter = 0
  INTEGER(int64), SAVE :: k_ticks(CD_PROF_NKERNEL) = 0_int64, k_calls(CD_PROF_NKERNEL) = 0_int64

CONTAINS

  LOGICAL FUNCTION CD_Profile_Requested() RESULT(requested)
    !! TRUE when CABLEDYN_PROFILE is set to a non-empty value other than 0.
    CHARACTER(32) :: value
    INTEGER :: stat
    value = ''
    CALL GET_ENVIRONMENT_VARIABLE('CABLEDYN_PROFILE', value, STATUS=stat)
    requested = stat == 0 .AND. LEN_TRIM(value) > 0 .AND. TRIM(value) /= '0'
  END FUNCTION CD_Profile_Requested

  SUBROUTINE CD_Profile_Arm()
    !! Zero the phases and counters and start the clock in the input phase.
    ticks = 0_int64
    n_march_steps = 0_int64
    n_line_steps = 0_int64
    n_line_iter = 0_int64
    max_line_iter = 0
    k_ticks = 0_int64
    k_calls = 0_int64
    current = CD_PROF_INPUT
    CALL SYSTEM_CLOCK(last, rate)
    armed = rate > 0_int64
  END SUBROUTINE CD_Profile_Arm

  SUBROUTINE CD_Profile_Disarm()
    !! Stop recording; the counts and times so far stay readable until the next CD_Profile_Arm.
    armed = .FALSE.
  END SUBROUTINE CD_Profile_Disarm

  LOGICAL FUNCTION CD_Profile_Armed() RESULT(is_armed)
    is_armed = armed
  END FUNCTION CD_Profile_Armed

  SUBROUTINE CD_Profile_Enter(phase)
    !! Add the wall time since the previous mark to the running phase, and run phase (a
    !! CD_PROF_* value) from here.
    INTEGER, INTENT(IN) :: phase
    IF (.NOT. armed) RETURN
    IF (phase < 1 .OR. phase > CD_PROF_NPHASE) RETURN
    CALL CD_Profile_Flush()
    current = phase
  END SUBROUTINE CD_Profile_Enter

  SUBROUTINE CD_Profile_Flush()
    !! Add the wall time since the previous mark to the running phase, which keeps running.
    INTEGER(int64) :: now
    IF (.NOT. armed) RETURN
    CALL SYSTEM_CLOCK(now)
    ticks(current) = ticks(current) + (now - last)
    last = now
  END SUBROUTINE CD_Profile_Flush

  SUBROUTINE CD_Profile_Step()
    !! Count a committed step of the march.
    IF (.NOT. armed) RETURN
    n_march_steps = n_march_steps + 1_int64
  END SUBROUTINE CD_Profile_Step

  SUBROUTINE CD_Profile_Count_Line_Step(n_iter)
    !! Count one EI = 0 line step (a nominal step, a recovery substep or a retry) and its
    !! Newton iterations. Lines of a system step in an OpenMP team, so the updates are atomic.
    INTEGER, INTENT(IN) :: n_iter
    INTEGER(int64) :: iterations
    IF (.NOT. armed) RETURN
    iterations = INT(MAX(0, n_iter), int64)
    !$OMP ATOMIC UPDATE
    n_line_steps = n_line_steps + 1_int64
    !$OMP ATOMIC UPDATE
    n_line_iter = n_line_iter + iterations
    !$OMP ATOMIC UPDATE
    max_line_iter = MAX(max_line_iter, n_iter)
  END SUBROUTINE CD_Profile_Count_Line_Step

  SUBROUTINE CD_Profile_Kernel_Begin(start)
    !! The clock at the start of a kernel (zero when the profile is not armed).
    INTEGER(int64), INTENT(OUT) :: start
    start = 0_int64
    IF (.NOT. armed) RETURN
    CALL SYSTEM_CLOCK(start)
  END SUBROUTINE CD_Profile_Kernel_Begin

  SUBROUTINE CD_Profile_Kernel_End(kernel, start)
    !! Count one call of kernel (a CD_PROF_K_* value) and add the time since start, taken by
    !! CD_Profile_Kernel_Begin. Lines step concurrently, so the updates are atomic.
    INTEGER, INTENT(IN) :: kernel
    INTEGER(int64), INTENT(IN) :: start
    INTEGER(int64) :: now
    IF (.NOT. armed) RETURN
    ! a kernel that began before the profile was armed has no start time
    IF (start == 0_int64 .OR. kernel < 1 .OR. kernel > CD_PROF_NKERNEL) RETURN
    CALL SYSTEM_CLOCK(now)
    !$OMP ATOMIC UPDATE
    k_calls(kernel) = k_calls(kernel) + 1_int64
    !$OMP ATOMIC UPDATE
    k_ticks(kernel) = k_ticks(kernel) + MAX(0_int64, now - start)
  END SUBROUTINE CD_Profile_Kernel_End

  SUBROUTINE CD_Profile_Kernels(calls, seconds)
    !! Calls and summed time [s] of each CD_PROF_K_* kernel since the profile was armed.
    INTEGER(int64), INTENT(OUT) :: calls(CD_PROF_NKERNEL)
    REAL(wp), INTENT(OUT) :: seconds(CD_PROF_NKERNEL)
    calls = k_calls
    seconds = 0.0_wp
    IF (rate > 0_int64) seconds = REAL(k_ticks, wp)/REAL(rate, wp)
  END SUBROUTINE CD_Profile_Kernels

  REAL(wp) FUNCTION CD_Profile_Seconds(phase) RESULT(seconds)
    !! Wall time attributed to phase so far [s]; zero when the profile is not armed.
    INTEGER, INTENT(IN) :: phase
    seconds = 0.0_wp
    IF (.NOT. armed) RETURN
    IF (phase < 1 .OR. phase > CD_PROF_NPHASE) RETURN
    seconds = REAL(ticks(phase), wp)/REAL(rate, wp)
  END FUNCTION CD_Profile_Seconds

  SUBROUTINE CD_Profile_Counts(march_steps, line_steps, line_iterations, line_max_iterations)
    !! Committed march steps, EI = 0 line steps, their Newton iterations and the most in one step.
    INTEGER(int64), INTENT(OUT) :: march_steps, line_steps, line_iterations
    INTEGER, INTENT(OUT) :: line_max_iterations
    march_steps = n_march_steps
    line_steps = n_line_steps
    line_iterations = n_line_iter
    line_max_iterations = max_line_iter
  END SUBROUTINE CD_Profile_Counts

END MODULE CableDyn_Profile
