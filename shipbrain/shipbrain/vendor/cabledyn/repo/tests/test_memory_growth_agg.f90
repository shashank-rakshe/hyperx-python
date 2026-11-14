! File: tests/test_memory_growth_agg.f90
! SPDX-License-Identifier: Apache-2.0
! Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
PROGRAM test_memory_growth_agg
  !! Long-march memory-growth gate for the OpenFAST aggregate route (the per-step surface
  !! openfast.exe drives): snapshot, fluid fields, moving-point step, output, mesh
  !! loads, and every deck output channel, on a mixed EI=0 mooring + Hermite cable deck.
  !! After warm-up steps (lazily sized workspaces reach capacity) the process memory
  !! (Windows private commit, Linux resident set) must grow by less than the bound over
  !! the measured march. Exits 77 (CTest skip) where no process memory counter exists.
  !!
  !! Usage: test_memory_growth_agg <deck.dat> <water_depth_m> <n_steps> <max_growth_MiB>
  USE, INTRINSIC :: ISO_C_BINDING, ONLY: C_DOUBLE
  USE CableDyn_Precision, ONLY: wp
  USE CableDyn_OpenFAST_Aggregate, ONLY: CD_AGG_ModuleType, CD_AGG_Init_From_Deck, CD_AGG_NMovingPoints, &
                                         CD_AGG_NFluidNodes, CD_AGG_NumChannels, CD_AGG_GetMovingPointMesh, &
                                         CD_AGG_Snapshot, CD_AGG_SetFluidFields, CD_AGG_Step_Moving, &
                                         CD_AGG_CalcOutput, CD_AGG_EvalChannel, CD_AGG_End
  IMPLICIT NONE
  INTERFACE
    FUNCTION cd_test_process_memory_mib() BIND(C, NAME='cd_test_process_memory_mib') RESULT(mib)
      IMPORT :: C_DOUBLE
      REAL(C_DOUBLE) :: mib
    END FUNCTION cd_test_process_memory_mib
  END INTERFACE
  INTEGER, PARAMETER :: WARMUP_STEPS = 40
  REAL(wp), PARAMETER :: DT = 0.025_wp, SURGE_AMPLITUDE = 0.5_wp, SURGE_PERIOD = 20.0_wp
  TYPE(CD_AGG_ModuleType) :: agg
  CHARACTER(1024) :: deck, arg
  CHARACTER(2048) :: em
  REAL(wp), ALLOCATABLE :: pos0(:, :), pos(:, :), vel(:, :), acc(:, :), loads(:, :), orient(:, :, :)
  REAL(wp), ALLOCATABLE :: fluid_v(:, :), fluid_a(:, :), waterline(:)
  REAL(wp) :: depth, max_growth, mem_start, mem_end, value
  INTEGER :: es, n_steps, ncp, nfluid, nch, i, ios

  IF (COMMAND_ARGUMENT_COUNT() /= 4) THEN
    PRINT '(A)', 'usage: test_memory_growth_agg <deck.dat> <water_depth_m> <n_steps> <max_growth_MiB>'
    ERROR STOP 2
  END IF
  CALL GET_COMMAND_ARGUMENT(1, deck)
  CALL GET_COMMAND_ARGUMENT(2, arg)
  READ (arg, *, IOSTAT=ios) depth
  IF (ios /= 0) ERROR STOP 'invalid water depth'
  CALL GET_COMMAND_ARGUMENT(3, arg)
  READ (arg, *, IOSTAT=ios) n_steps
  IF (ios /= 0 .OR. n_steps <= 0) ERROR STOP 'invalid step count'
  CALL GET_COMMAND_ARGUMENT(4, arg)
  READ (arg, *, IOSTAT=ios) max_growth
  IF (ios /= 0 .OR. .NOT. max_growth > 0.0_wp) ERROR STOP 'invalid growth bound'
  IF (cd_test_process_memory_mib() < 0.0_C_DOUBLE) THEN
    PRINT '(A)', 'SKIP: no process memory counter on this platform'
    STOP 77
  END IF

  CALL CD_AGG_Init_From_Deck(agg, TRIM(deck), DT, es, em, env_gravity=9.80665_wp, env_rho_water=1025.0_wp, &
                             env_wtrdpth=depth, external_fluid=.TRUE.)
  CALL check('initialization')
  ncp = CD_AGG_NMovingPoints(agg, es, em)
  CALL check('moving-point count')
  nfluid = CD_AGG_NFluidNodes(agg, es, em)
  CALL check('fluid-node count')
  nch = CD_AGG_NumChannels(agg)
  IF (ncp <= 0) ERROR STOP 'deck has no moving points to drive'
  ALLOCATE (pos0(3, ncp), pos(3, ncp), vel(3, ncp), acc(3, ncp), loads(3, ncp), orient(3, 3, ncp))
  ALLOCATE (fluid_v(3, nfluid), fluid_a(3, nfluid), waterline(nfluid))
  CALL CD_AGG_GetMovingPointMesh(agg, pos0, vel, acc, loads, es, em)
  CALL check('initial mesh')
  orient = 0.0_wp
  DO i = 1, ncp
    orient(1, 1, i) = 1.0_wp
    orient(2, 2, i) = 1.0_wp
    orient(3, 3, i) = 1.0_wp
  END DO
  fluid_v = 0.0_wp
  fluid_a = 0.0_wp
  waterline = 0.0_wp

  CALL march(0, WARMUP_STEPS)
  mem_start = REAL(cd_test_process_memory_mib(), wp)
  CALL march(WARMUP_STEPS, n_steps)
  mem_end = REAL(cd_test_process_memory_mib(), wp)
  CALL CD_AGG_End(agg, es, em)
  CALL check('end')
  PRINT '(A,I0,A,F10.2,A,F10.2,A,F9.3,A,F9.3,A)', TRIM(deck)//': ', n_steps, ' steps, memory ', mem_start, &
    ' -> ', mem_end, ' MiB (growth ', mem_end - mem_start, ' MiB, ', 1024.0_wp*(mem_end - mem_start)/n_steps, &
    ' KiB/step)'
  IF (.NOT. (mem_end - mem_start < max_growth)) THEN
    PRINT '(A,F9.3,A)', 'FAIL: memory grew beyond the ', max_growth, ' MiB bound'
    ERROR STOP 1
  END IF
  PRINT '(A)', 'PASS: bounded memory over a long aggregate march'

CONTAINS

  SUBROUTINE march(first_step, count)
    INTEGER, INTENT(IN) :: first_step, count
    REAL(wp) :: t, w, ramp
    LOGICAL :: converged, stalled
    INTEGER :: k, n_iter, ich

    w = 2.0_wp*ACOS(-1.0_wp)/SURGE_PERIOD
    DO k = first_step + 1, first_step + count
      t = k*DT
      ramp = MIN(t/SURGE_PERIOD, 1.0_wp)
      pos = pos0
      vel = 0.0_wp
      acc = 0.0_wp
      pos(1, :) = pos0(1, :) + ramp*SURGE_AMPLITUDE*SIN(w*t)
      vel(1, :) = ramp*SURGE_AMPLITUDE*w*COS(w*t)
      acc(1, :) = -ramp*SURGE_AMPLITUDE*w*w*SIN(w*t)
      CALL CD_AGG_Snapshot(agg, es, em)
      CALL check('snapshot')
      CALL CD_AGG_SetFluidFields(agg, fluid_v, fluid_a, waterline, es, em)
      CALL check('fluid fields')
      CALL CD_AGG_Step_Moving(agg, DT, pos, vel, acc, converged, stalled, n_iter, es, em, t_committed=t, &
                              orientation=orient)
      CALL check('step')
      IF (.NOT. converged .OR. stalled) ERROR STOP 'aggregate step did not converge'
      CALL CD_AGG_CalcOutput(agg, es, em)
      CALL check('output')
      CALL CD_AGG_GetMovingPointMesh(agg, pos, vel, acc, loads, es, em)
      CALL check('mesh loads')
      DO ich = 1, nch
        CALL CD_AGG_EvalChannel(agg, ich, value, es, em)
        CALL check('channel')
      END DO
    END DO
  END SUBROUTINE march

  SUBROUTINE check(stage)
    CHARACTER(*), INTENT(IN) :: stage

    IF (es /= 0) THEN
      PRINT '(A)', 'FAIL: '//stage//': '//TRIM(em)
      ERROR STOP 1
    END IF
  END SUBROUTINE check

END PROGRAM test_memory_growth_agg
