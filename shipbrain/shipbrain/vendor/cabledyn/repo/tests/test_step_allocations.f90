! File: tests/test_step_allocations.f90
! SPDX-License-Identifier: Apache-2.0
! Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
PROGRAM test_step_allocations
  !! Allocation-count gate for the per-step advance of the OpenFAST aggregate route (the
  !! calls openfast.exe makes every step): after warm-up steps size every reusable
  !! workspace, a further march of fluid-field updates and moving-point steps (EI = 0 lines
  !! and a Hermite cable) must make no heap allocation at all. The count comes from
  !! malloc/calloc/realloc wrappers linked into this executable (tests/allocation_counter.c,
  !! GNU ld --wrap); it covers ALLOCATE, run-time-sized automatic arrays, and the array
  !! temporaries a compiler places on the heap. The snapshot is outside the counted window
  !! (its storage is sized once, at the first call). The output calls (loads, mesh, output
  !! channels) are counted and reported but not gated: the channel evaluation still
  !! allocates per call. With a fourth argument "ranges" the deck's range graphs (LINES flag r)
  !! are accumulated after every step inside the gated window, which must stay allocation-free
  !! too: the envelope accumulation, the touchdown evaluation, and the EI = 0 and Hermite line
  !! samples with their FairTen/AnchTen end-force recovery.
  !!
  !! With the single argument "torsion" the gate runs on a finite-EI cable with condensed torsion
  !! instead (CD_HFMF_UpdateStates): a line clamped at both ends and restrained in torsion, its
  !! coupled end swaying while the parent rolls about the line axis and the imposed twist
  !! changes, so every step evaluates the twist kernel, its Hessian and the bordered solve. The
  !! committed-state outputs (CD_HFMF_SetCoupledKinematics, CD_HFMF_CalcOutput with the connection
  !! moment, both end forces, the energy and the torque query) are gated as well. With "nodal"
  !! the same cable carries the nodal twist (polar inertia and torsional damping), with its
  !! 7-DOF-per-node band and the node-torque and element-twist queries; with "free" the nodal
  !! twist of the same cable free in torsion at its held end (restrained at the coupled end only).
  !!
  !! With "current_grid" the gate runs the evaluation of a MoorDyn-C current grid (Currents 2 and
  !! 5) that every standalone step makes at every node: CD_Current_Grid_Velocity, and the gradient
  !! of the EI = 0 static tangent (CD_Current_Grid_Gradient), at points inside and outside a
  !! sheared grid and at times before, inside and past its last sample.
  !!
  !! With "motion_roll" or "motion_vessel" the gate runs the standalone driver's march of a mixed
  !! EI = 0 + finite-EI deck with the deck's prescribed motion (CD_AGG_MotionKinematics, then
  !! CD_AGG_Step_Moving with the roll column or with the vessel orientation and rates): a straight
  !! line restrained in torsion whose End A rolls about its axis, beside an EI = 0 chain.
  !!
  !! With "mixed_current" the same march of a mixed deck takes the deck's own current
  !! (deck_current): a MoorDyn-C Currents 5 grid that varies in space and time, sampled at every
  !! node of the chain and of the finite-EI cable before each step, past its last sample too.
  !! With "driver_vessel" the gate runs a whole standalone driver run in process
  !! (CD_Run_Deck_Driver) of a finite-EI line on the cubic-Hermite route moved by a vesselMotion
  !! record, and counts the step phase of every step after warm-up (tests/allocation_phase_counter.c:
  !! the end kinematics, the vessel orientation and rates handed to the cable, its implicit step).
  !!
  !! Usage: test_step_allocations <deck.dat> <water_depth_m> <n_steps> [ranges]
  !!        test_step_allocations torsion | nodal | free | current_grid | motion_roll | motion_vessel |
  !!                              mixed_current
  !!        test_step_allocations driver_vessel
  USE, INTRINSIC :: ISO_C_BINDING, ONLY: C_INT, C_LONG_LONG
  USE CableDyn_Precision, ONLY: wp
  USE CableDyn_EndConnection, ONLY: CD_ENDCONN_RIGID
  USE CableDyn_HermiteTorsion, ONLY: CD_HermiteTorsionType
  USE CableDyn_OpenFAST_HermiteFMF, ONLY: CD_HFMF_ModuleType, CD_HFMF_Init, CD_HFMF_Set_EndConnection, &
                                          CD_HFMF_Set_Torsion, CD_HFMF_UpdateStates, CD_HFMF_CalcOutput, CD_HFMF_End, &
                                          CD_HFMF_SetCoupledKinematics
  USE CableDyn_HermiteCableDynamic, ONLY: CD_HermiteCable_Dyn_End_Force, CD_HermiteCable_Dyn_Energy, &
                                          CD_HermiteCable_Dyn_Torsion_State, CD_HermiteCable_Dyn_Node_Torque, &
                                          CD_HermiteCable_Dyn_Element_Twist
  USE CableDyn_DeckDriver, ONLY: CD_Run_Deck_Driver
  USE CableDyn_Hydro, ONLY: CD_CurrentGridType, CD_Current_Grid_Resample, CD_Current_Grid_Velocity, &
                            CD_Current_Grid_Gradient
  USE CableDyn_OpenFAST_Aggregate, ONLY: CD_AGG_ModuleType, CD_AGG_Init_From_Deck, CD_AGG_NMovingPoints, &
                                         CD_AGG_NFluidNodes, CD_AGG_NumChannels, CD_AGG_GetMovingPointMesh, &
                                         CD_AGG_Snapshot, CD_AGG_SetFluidFields, CD_AGG_Step_Moving, &
                                         CD_AGG_CalcOutput, CD_AGG_EvalChannel, CD_AGG_End, &
                                         CD_AGG_Range_Sample, CD_AGG_UpdateStates_Moving, CD_AGG_MotionKinematics, &
                                         CD_AGG_Refresh_Accelerations
  IMPLICIT NONE
  INTERFACE
    FUNCTION cd_test_allocation_count() BIND(C, NAME='cd_test_allocation_count') RESULT(n)
      IMPORT :: C_LONG_LONG
      INTEGER(C_LONG_LONG) :: n
    END FUNCTION cd_test_allocation_count
    SUBROUTINE cd_test_allocation_counting(on) BIND(C, NAME='cd_test_allocation_counting')
      IMPORT :: C_INT
      INTEGER(C_INT), VALUE :: on
    END SUBROUTINE cd_test_allocation_counting
    SUBROUTINE cd_test_phase_counting(on, warm) BIND(C, NAME='cd_test_phase_counting')
      IMPORT :: C_INT, C_LONG_LONG
      INTEGER(C_INT), VALUE :: on
      INTEGER(C_LONG_LONG), VALUE :: warm
    END SUBROUTINE cd_test_phase_counting
    FUNCTION cd_test_phase_solve_entries() BIND(C, NAME='cd_test_phase_solve_entries') RESULT(n)
      IMPORT :: C_LONG_LONG
      INTEGER(C_LONG_LONG) :: n
    END FUNCTION cd_test_phase_solve_entries
  END INTERFACE
  INTEGER, PARAMETER :: WARMUP_STEPS = 40
  REAL(wp), PARAMETER :: DT = 0.025_wp, SURGE_AMPLITUDE = 0.5_wp, SURGE_PERIOD = 20.0_wp
  TYPE(CD_AGG_ModuleType) :: agg
  CHARACTER(1024) :: deck, arg
  CHARACTER(2048) :: em
  REAL(wp), ALLOCATABLE :: pos0(:, :), pos(:, :), vel(:, :), acc(:, :), loads(:, :), orient(:, :, :)
  REAL(wp), ALLOCATABLE :: fluid_v(:, :), fluid_a(:, :), waterline(:)
  REAL(wp) :: depth, value
  INTEGER :: es, n_steps, ncp, nfluid, nch, i, ios
  INTEGER(C_LONG_LONG) :: n_step_alloc, n_output_alloc
  LOGICAL :: ranges

  IF (COMMAND_ARGUMENT_COUNT() == 1) THEN
    CALL GET_COMMAND_ARGUMENT(1, arg)
    SELECT CASE (TRIM(arg))
    CASE ('torsion', 'nodal', 'free')
      CALL torsion_gate(TRIM(arg) /= 'torsion', TRIM(arg) == 'free')
    CASE ('current_grid')
      CALL current_grid_gate()
    CASE ('motion_roll', 'motion_vessel')
      CALL motion_gate(TRIM(arg) == 'motion_vessel')
    CASE ('mixed_current')
      CALL mixed_current_gate()
    CASE ('driver_vessel')
      CALL driver_vessel_gate()
    CASE DEFAULT
      ERROR STOP 'a single argument must be "torsion", "nodal", "free", "current_grid", "motion_roll", '// &
        '"motion_vessel", "mixed_current" or "driver_vessel"'
    END SELECT
    STOP
  END IF
  IF (COMMAND_ARGUMENT_COUNT() /= 3 .AND. COMMAND_ARGUMENT_COUNT() /= 4) THEN
    PRINT '(A)', 'usage: test_step_allocations <deck.dat> <water_depth_m> <n_steps> [ranges]'
    ERROR STOP 2
  END IF
  ranges = COMMAND_ARGUMENT_COUNT() == 4
  IF (ranges) THEN
    CALL GET_COMMAND_ARGUMENT(4, arg)
    IF (TRIM(arg) /= 'ranges') ERROR STOP 'the fourth argument must be "ranges"'
  END IF
  CALL GET_COMMAND_ARGUMENT(1, deck)
  CALL GET_COMMAND_ARGUMENT(2, arg)
  READ (arg, *, IOSTAT=ios) depth
  IF (ios /= 0) ERROR STOP 'invalid water depth'
  CALL GET_COMMAND_ARGUMENT(3, arg)
  READ (arg, *, IOSTAT=ios) n_steps
  IF (ios /= 0 .OR. n_steps <= 0) ERROR STOP 'invalid step count'

  CALL CD_AGG_Init_From_Deck(agg, TRIM(deck), DT, es, em, env_gravity=9.80665_wp, env_rho_water=1025.0_wp, &
                             env_wtrdpth=depth, external_fluid=.TRUE., range_files=ranges)
  CALL check('initialization')
  IF (ranges .AND. .NOT. agg%ranges%active) ERROR STOP 'the deck requests no range graph'
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

  n_step_alloc = 0
  n_output_alloc = 0
  CALL march(0, WARMUP_STEPS, .FALSE.)
  CALL march(WARMUP_STEPS, n_steps, .TRUE.)
  CALL CD_AGG_End(agg, es, em)
  CALL check('end')
  PRINT '(A,I0,A,I0,A,I0,A)', TRIM(deck)//': ', n_steps, ' counted steps, ', n_step_alloc, &
    ' heap allocations in the steps, ', n_output_alloc, ' in the outputs'
  IF (n_step_alloc /= 0) THEN
    PRINT '(A)', 'FAIL: the per-step aggregate advance allocated after warm-up'
    ERROR STOP 1
  END IF
  PRINT '(A)', 'PASS: no heap allocation in the per-step advance after warm-up'

CONTAINS

  SUBROUTINE march(first_step, count, counted)
    INTEGER, INTENT(IN) :: first_step, count
    LOGICAL, INTENT(IN) :: counted
    REAL(wp) :: t, w, ramp
    LOGICAL :: converged, stalled
    INTEGER :: k, n_iter, ich
    INTEGER(C_LONG_LONG) :: c0

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
      c0 = cd_test_allocation_count()
      IF (counted) CALL cd_test_allocation_counting(1_C_INT)
      CALL CD_AGG_SetFluidFields(agg, fluid_v, fluid_a, waterline, es, em)
      CALL check('fluid fields')
      CALL CD_AGG_Step_Moving(agg, DT, pos, vel, acc, converged, stalled, n_iter, es, em, t_committed=t, &
                              orientation=orient)
      IF (ranges .AND. es == 0) CALL CD_AGG_Range_Sample(agg, t, es, em)
      CALL cd_test_allocation_counting(0_C_INT)
      CALL check('step')
      IF (.NOT. converged .OR. stalled) ERROR STOP 'aggregate step did not converge'
      n_step_alloc = n_step_alloc + (cd_test_allocation_count() - c0)
      c0 = cd_test_allocation_count()
      IF (counted) CALL cd_test_allocation_counting(1_C_INT)
      CALL CD_AGG_CalcOutput(agg, es, em)
      IF (es == 0) CALL CD_AGG_GetMovingPointMesh(agg, pos, vel, acc, loads, es, em)
      DO ich = 1, nch
        IF (es == 0) CALL CD_AGG_EvalChannel(agg, ich, value, es, em)
      END DO
      CALL cd_test_allocation_counting(0_C_INT)
      CALL check('output')
      n_output_alloc = n_output_alloc + (cd_test_allocation_count() - c0)
    END DO
  END SUBROUTINE march

  SUBROUTINE torsion_gate(nodal, free_end)
    !! Zero heap allocation in CD_HFMF_UpdateStates of a cable with condensed torsion, or with the
    !! nodal twist (free_end: free in torsion at the held end 1).
    LOGICAL, INTENT(IN) :: nodal, free_end
    INTEGER, PARAMETER :: NE = 20, NN = NE + 1, NDOF = 6*NN, N_WARM = 40, N_COUNT = 200
    REAL(wp), PARAMETER :: LL = 10.0_wp, DTT = 0.01_wp
    TYPE(CD_HFMF_ModuleType) :: cab
    TYPE(CD_HermiteTorsionType) :: tors
    REAL(wp) :: q(NDOF), l0(NE), eye(3, 3), frame(3, 2), t, x(3), v(3), a(3), dcm(3, 3), f(3), m(3), psi
    REAL(wp) :: fe(3), ke, se, th, mt, ntq(NN), etw(NE)
    INTEGER :: k
    INTEGER(C_LONG_LONG) :: c0, n_alloc, n_out, n_energy
    n_out = 0
    n_energy = 0
    q = 0.0_wp
    DO k = 1, NN
      q(6*k - 5) = LL*REAL(k - 1, wp)/REAL(NE, wp)
      q(6*k - 2) = 1.0_wp
    END DO
    l0 = LL/REAL(NE, wp)
    eye = 0.0_wp
    eye(1, 1) = 1.0_wp
    eye(2, 2) = 1.0_wp
    eye(3, 3) = 1.0_wp
    CALL CD_HFMF_Init(cab, l0, [(1.0e5_wp, k=1, NE)], [(100.0_wp, k=1, NE)], [(1.0_wp, k=1, NE)], &
                      [(0.0_wp, k=1, NE)], q, [1, 2, 3, NDOF - 5, NDOF - 4, NDOF - 3], 0.0_wp, 0.0_wp, 0.8_wp, &
                      DTT, NN, es, em, max_iter=60, tol=1.0e-8_wp)
    CALL check('torsion cable init')
    CALL CD_HFMF_Set_EndConnection(cab, [0.0_wp, 0.0_wp], RESHAPE([1.0_wp, 0.0_wp, 0.0_wp, 1.0_wp, 0.0_wp, 0.0_wp], &
                                                                  [3, 2]), es, em, &
                                   coupled_d0_parent=[1.0_wp, 0.0_wp, 0.0_wp], parent_orientation=eye, &
                                   connection_mode=[CD_ENDCONN_RIGID, CD_ENDCONN_RIGID])
    CALL check('torsion cable end connections')
    tors%active = .TRUE.
    tors%phi = 2.0_wp
    tors%ends = RESHAPE([1.0_wp, 0.0_wp, 0.0_wp, 0.0_wp, 0.0_wp, 1.0_wp, 1.0_wp, 0.0_wp, 0.0_wp, &
                         0.0_wp, 0.0_wp, 1.0_wp], [3, 4])
    ALLOCATE (tors%gj(NE))
    tors%gj = 80.0_wp
    IF (nodal) THEN
      ALLOCATE (tors%irn(NE), tors%bt(NE))
      tors%irn = 0.05_wp
      tors%bt = 0.5_wp
    END IF
    IF (free_end) tors%end_free(1) = .TRUE.
    tors%has_theta = .TRUE.
    frame(:, 1) = [1.0_wp, 0.0_wp, 0.0_wp]
    frame(:, 2) = [0.0_wp, 0.0_wp, 1.0_wp]
    CALL CD_HFMF_Set_Torsion(cab, tors, es, em, coupled_frame_parent=frame, parent_orientation=eye)
    CALL check('torsion cable torsion')
    n_alloc = 0
    DO k = 1, N_WARM + N_COUNT
      t = DTT*REAL(k, wp)
      x = [LL, 0.05_wp*SIN(2.0_wp*t), 0.0_wp]
      v = [0.0_wp, 0.1_wp*COS(2.0_wp*t), 0.0_wp]
      a = [0.0_wp, -0.2_wp*SIN(2.0_wp*t), 0.0_wp]
      psi = 3.0_wp*t
      dcm = eye
      dcm(2, 2) = COS(psi)
      dcm(3, 3) = COS(psi)
      dcm(2, 3) = SIN(psi)
      dcm(3, 2) = -SIN(psi)
      c0 = cd_test_allocation_count()
      IF (k > N_WARM) CALL cd_test_allocation_counting(1_C_INT)
      CALL CD_HFMF_UpdateStates(cab, x, v, a, es, em, u_orientation=dcm, u_angular_velocity=[3.0_wp, 0.0_wp, 0.0_wp], &
                                u_angular_acceleration=[0.0_wp, 0.0_wp, 0.0_wp], u_twist=2.0_wp - psi + 0.3_wp*SIN(t))
      CALL cd_test_allocation_counting(0_C_INT)
      CALL check('torsion cable step')
      n_alloc = n_alloc + (cd_test_allocation_count() - c0)
      ! the outputs of the committed state and the non-stepping boundary write: the loads and
      ! connection moment, the end forces, the energy and the twist and torque queries
      c0 = cd_test_allocation_count()
      IF (k > N_WARM) CALL cd_test_allocation_counting(1_C_INT)
      CALL CD_HFMF_SetCoupledKinematics(cab, x, v, a, es, em, u_orientation=dcm, &
                                        u_angular_velocity=[3.0_wp, 0.0_wp, 0.0_wp], &
                                        u_angular_acceleration=[0.0_wp, 0.0_wp, 0.0_wp])
      IF (es == 0) CALL CD_HFMF_CalcOutput(cab, f, es, em, y_moment=m)
      IF (es == 0) CALL CD_HermiteCable_Dyn_End_Force(cab%line, 1, fe, es, em)
      IF (es == 0) CALL CD_HermiteCable_Dyn_End_Force(cab%line, NN, fe, es, em)
      IF (es == 0) CALL CD_HermiteCable_Dyn_Torsion_State(cab%line, th, mt, es, em)
      IF (es == 0 .AND. nodal) CALL CD_HermiteCable_Dyn_Node_Torque(cab%line, ntq, es, em)
      IF (es == 0 .AND. nodal) CALL CD_HermiteCable_Dyn_Element_Twist(cab%line, etw, es, em)
      CALL cd_test_allocation_counting(0_C_INT)
      CALL check('torsion cable output')
      n_out = n_out + (cd_test_allocation_count() - c0)
      ! the energy diagnostic (not a per-step output; its mass product uses a run-time-sized
      ! temporary): only its torsion part is required to be allocation-free, so the count of
      ! the call may not exceed that of the same call without torsion (one temporary)
      c0 = cd_test_allocation_count()
      IF (k > N_WARM) CALL cd_test_allocation_counting(1_C_INT)
      CALL CD_HermiteCable_Dyn_Energy(cab%line, ke, se, es, em)
      CALL cd_test_allocation_counting(0_C_INT)
      CALL check('torsion cable energy')
      IF (k > N_WARM) n_energy = MAX(n_energy, cd_test_allocation_count() - c0)
    END DO
    IF (nodal .AND. .NOT. cab%line%tw_active) ERROR STOP 'the nodal gate runs without the nodal twist'
    CALL CD_HFMF_End(cab)
    PRINT '(A,I0,A,I0,A,I0,A)', 'torsion cable: ', N_COUNT, ' counted steps, ', n_alloc, &
      ' heap allocations in the steps, ', n_out, ' in the outputs'
    PRINT '(A,I0)', 'torsion cable energy diagnostic: heap allocations per call ', n_energy
    IF (n_alloc /= 0 .OR. n_out /= 0 .OR. n_energy > 1) THEN
      PRINT '(A)', 'FAIL: the per-step advance or the outputs of a cable with torsion allocated after warm-up'
      ERROR STOP 1
    END IF
    PRINT '(A)', 'PASS: no heap allocation in the per-step advance or outputs of a cable with torsion after warm-up'
  END SUBROUTINE torsion_gate

  SUBROUTINE current_grid_gate()
    TYPE(CD_CurrentGridType) :: grid
    REAL(wp) :: xc(4), yc(2), zc(4), tc(4), v_in(3, 4, 2, 4, 4), u(3), g(3, 3), p(3), t, total
    INTEGER(C_LONG_LONG) :: n0, n1
    INTEGER :: ix, iy, iz, it, k
    xc = [-60.0_wp, -20.0_wp, 10.0_wp, 50.0_wp]
    yc = [-30.0_wp, 30.0_wp]
    zc = [-50.0_wp, -25.0_wp, -10.0_wp, 0.0_wp]
    tc = [0.0_wp, 5.0_wp, 12.0_wp, 20.0_wp]
    DO it = 1, 4
      DO iz = 1, 4
        DO iy = 1, 2
          DO ix = 1, 4
            v_in(:, ix, iy, iz, it) = [0.4_wp + 0.006_wp*xc(ix) + 0.01_wp*tc(it), 0.003_wp*yc(iy), 0.001_wp*zc(iz)]
          END DO
        END DO
      END DO
    END DO
    CALL CD_Current_Grid_Resample(xc, yc, zc, tc, v_in, grid, es, em)
    CALL check('current grid resample')
    total = 0.0_wp
    ! warm-up (any lazy runtime set-up outside the counted window)
    CALL CD_Current_Grid_Velocity(grid, [1.0_wp, 2.0_wp, -3.0_wp], 1.0_wp, u, es, em)
    CALL check('current grid warm-up')
    CALL cd_test_allocation_counting(1_C_INT)
    n0 = cd_test_allocation_count()
    DO k = 1, 20000
      t = -1.0_wp + 0.0037_wp*REAL(k, wp)
      p = [-80.0_wp + 0.0071_wp*REAL(k, wp), -45.0_wp + 0.0047_wp*REAL(k, wp), -60.0_wp + 0.0033_wp*REAL(k, wp)]
      CALL CD_Current_Grid_Velocity(grid, p, t, u, es, em)
      CALL check('current grid velocity')
      CALL CD_Current_Grid_Gradient(grid, p, t, g, es, em)
      CALL check('current grid gradient')
      total = total + SUM(u) + SUM(g)
    END DO
    n1 = cd_test_allocation_count()
    CALL cd_test_allocation_counting(0_C_INT)
    PRINT '(A,I0,A,ES12.4,A)', 'current grid: 20000 evaluations, ', n1 - n0, ' heap allocations (checksum ', total, ')'
    IF (n1 /= n0) THEN
      PRINT '(A)', 'FAIL: the current grid evaluation allocated'
      ERROR STOP 1
    END IF
    PRINT '(A)', 'PASS: no heap allocation in the current grid evaluation'
  END SUBROUTINE current_grid_gate

  SUBROUTINE motion_gate(vessel)
    !! Zero heap allocation in the standalone driver's per-step march of a mixed deck with its
    !! prescribed motion: the 100 m straight neutral line of test_mixed_route_torsion, clamped and
    !! restrained in torsion at both ends, End A rolled about the line axis (by a vessel, or by the
    !! motionFile roll column), beside a chain on a second moving point.
    LOGICAL, INTENT(IN) :: vessel
    INTEGER, PARAMETER :: N_WARM = 40, N_COUNT = 160, NT = N_WARM + N_COUNT
    REAL(wp), PARAMETER :: DTM = 0.05_wp, PI = 3.14159265358979323846_wp
    TYPE(CD_AGG_ModuleType), ALLOCATABLE :: mag
    REAL(wp), ALLOCATABLE :: p(:, :), v(:, :), a(:, :), ld(:, :), o(:, :, :), w(:, :), al(:, :), roll(:)
    REAL(wp) :: t, ro, dro, d2ro, om
    INTEGER :: u, k, n, n_it
    INTEGER(C_LONG_LONG) :: c0, n_alloc
    LOGICAL :: turns, rolls, converged, stalled
    ! one file root per mode: the two gates may run at once in one directory
    CHARACTER(32) :: root
    root = MERGE('step_alloc_motion_vessel', 'step_alloc_motion_roll  ', vessel)
    om = 2.0_wp*PI/10.0_wp
    OPEN (NEWUNIT=u, FILE=TRIM(root)//'.txt', STATUS='REPLACE', ACTION='WRITE')
    DO k = 0, NT
      t = DTM*k
      ro = 15.0_wp*(1.0_wp - COS(om*t))
      dro = 15.0_wp*om*SIN(om*t)
      d2ro = 15.0_wp*om*om*COS(om*t)
      IF (vessel) THEN
        WRITE (u, '(F8.3,A,ES25.16E3,A,ES25.16E3,A,ES25.16E3,A)') t, ' 0 0 -50 ', ro, ' 0 0 0 0 0 ', dro*PI/180.0_wp, &
          ' 0 0 0 0 0 ', d2ro*PI/180.0_wp, ' 0 0'
      ELSE
        WRITE (u, '(F8.3,A,ES25.16E3)') t, ' 1 0 0 -50 0 0 0 0 0 0 ', ro
        WRITE (u, '(F8.3,A)') t, ' 3 0 10 -50 0 0 0 0 0 0'
      END IF
    END DO
    CLOSE (u)
    OPEN (NEWUNIT=u, FILE=TRIM(root)//'.dat', STATUS='REPLACE', ACTION='WRITE')
    WRITE (u, '(A)') 'step allocation gate: mixed deck with prescribed motion'
    WRITE (u, '(A)') '--- LINE TYPES ---'
    WRITE (u, '(A)') 'Name Diam Mass EA BA EI GAs GJ Irt Irn Cdn Cdt Can Cat'
    WRITE (u, '(A)') '(-) (m) (kg/m) (N) (-) (Nm2) (N) (Nm2) (kgm) (kgm) (-) (-) (-) (-)'
    WRITE (u, '(A,ES24.16,A)') 'cab 0.2 ', 1025.0_wp*0.01_wp*PI, ' 1.0e7 0.0 1.0e6 1.0e8 5.0e4 1.0 1.0e-12 0 0 0 0'
    WRITE (u, '(A)') 'chain 0.1 50.0 1.0e9 -1.0 0.0 0 0 0 0 1.37 0.64 1.0 0.0'
    WRITE (u, '(A)') '--- POINTS ---'
    WRITE (u, '(A)') 'ID Type X Y Z Mass Vol CdA Ca'
    WRITE (u, '(A)') '(-) (-) (m) (m) (m) (kg) (m3) (m2) (-)'
    WRITE (u, '(A)') '1 '//MERGE('Vessel ', 'Coupled', vessel)//' 0.0 0.0 -50.0 0 0 0 0'
    WRITE (u, '(A)') '2 Fixed 100.0 0.0 -50.0 0 0 0 0'
    WRITE (u, '(A)') '3 '//MERGE('Vessel ', 'Coupled', vessel)//' 0.0 10.0 -50.0 0 0 0 0'
    WRITE (u, '(A)') '4 Fixed 0.0 100.0 -100.0 0 0 0 0'
    WRITE (u, '(A)') '--- LINES ---'
    WRITE (u, '(A)') 'ID NodeA NodeB Outputs'
    WRITE (u, '(A)') '(-) (-) (-) (-)'
    WRITE (u, '(A)') '1 1 2 -'
    WRITE (u, '(A)') '2 3 4 -'
    WRITE (u, '(A)') '--- SECTIONS ---'
    WRITE (u, '(A)') 'LineID LineType Length NumSegs'
    WRITE (u, '(A)') '(-) (-) (m) (-)'
    WRITE (u, '(A)') '1 cab 100.0 40'
    WRITE (u, '(A)') '2 chain 110.0 20'
    WRITE (u, '(A)') '--- END CONNECTIONS ---'
    WRITE (u, '(A)') 'LineID End Stiffness EzX EzY EzZ TorsStiffness NxX NxY NxZ Pretwist'
    WRITE (u, '(A)') '(-) (-) (N-m/rad) (-) (-) (-) (N-m/rad) (-) (-) (-) (deg)'
    WRITE (u, '(A)') '1 A Rigid 1 0 0 Rigid 0 0 1 0'
    WRITE (u, '(A)') '1 B Rigid 1 0 0 Rigid 0 0 1 90'
    WRITE (u, '(A)') '--- OPTIONS ---'
    WRITE (u, '(A)') '9.80665 g'
    WRITE (u, '(A)') '1025.0 rhoW'
    WRITE (u, '(A)') '0.05 dtM'
    WRITE (u, '(A)') '10.0 TMax'
    IF (vessel) THEN
      WRITE (u, '(A)') TRIM(root)//'.txt vesselMotion'
      WRITE (u, '(A)') '0|0|-50 vesselRef'
    ELSE
      WRITE (u, '(A)') TRIM(root)//'.txt motionFile'
    END IF
    WRITE (u, '(A)') '--- OUTPUTS ---'
    WRITE (u, '(A)') 'Torq1N1'
    WRITE (u, '(A)') '--- END ---'
    CLOSE (u)
    ALLOCATE (mag)
    CALL CD_AGG_Init_From_Deck(mag, TRIM(root)//'.dat', DTM, es, em, forbid_deck_ambient=.TRUE., &
                               run_tmax=10.0_wp, host_orientation=.TRUE., prescribed_motion=.TRUE.)
    CALL check('motion deck initialization')
    n = CD_AGG_NMovingPoints(mag, es, em)
    CALL check('motion moving-point count')
    ALLOCATE (p(3, n), v(3, n), a(3, n), ld(3, n), o(3, 3, n), w(3, n), al(3, n), roll(n))
    CALL CD_AGG_GetMovingPointMesh(mag, p, v, a, ld, es, em)
    CALL check('motion initial mesh')
    CALL CD_AGG_MotionKinematics(mag, 1, p, v, a, o, w, al, roll, turns, rolls, es, em)
    CALL check('motion row 1')
    IF (turns .EQV. rolls) ERROR STOP 'the motion gate drives neither or both frame inputs'
    CALL CD_AGG_UpdateStates_Moving(mag, p, v, a, es, em)
    CALL check('motion row 1 transfer')
    CALL CD_AGG_Refresh_Accelerations(mag, es, em)
    CALL check('motion row 1 accelerations')
    n_alloc = 0
    DO k = 1, NT
      c0 = cd_test_allocation_count()
      IF (k > N_WARM) CALL cd_test_allocation_counting(1_C_INT)
      CALL CD_AGG_MotionKinematics(mag, k + 1, p, v, a, o, w, al, roll, turns, rolls, es, em)
      IF (es == 0) THEN
        IF (turns) THEN
          CALL CD_AGG_Step_Moving(mag, DTM, p, v, a, converged, stalled, n_it, es, em, t_committed=DTM*k, &
                                  orientation=o, angular_velocity=w, angular_acceleration=al)
        ELSE
          CALL CD_AGG_Step_Moving(mag, DTM, p, v, a, converged, stalled, n_it, es, em, t_committed=DTM*k, roll=roll)
        END IF
      END IF
      CALL cd_test_allocation_counting(0_C_INT)
      CALL check('motion step')
      IF (.NOT. converged .OR. stalled) ERROR STOP 'motion step did not converge'
      n_alloc = n_alloc + (cd_test_allocation_count() - c0)
    END DO
    CALL CD_AGG_End(mag, es, em)
    PRINT '(A,I0,A,I0,A)', 'mixed deck with '//MERGE('vessel motion', 'roll column  ', vessel)//': ', N_COUNT, &
      ' counted steps, ', n_alloc, ' heap allocations in the steps'
    IF (n_alloc /= 0) THEN
      PRINT '(A)', 'FAIL: the prescribed-motion march of a mixed deck allocated after warm-up'
      ERROR STOP 1
    END IF
    PRINT '(A)', 'PASS: no heap allocation in the prescribed-motion march of a mixed deck after warm-up'
  END SUBROUTINE motion_gate

  SUBROUTINE driver_vessel_gate()
    !! Zero heap allocation in the step phase of the standalone driver's march of a finite-EI line on
    !! the cubic-Hermite route (a lazy cable from a Vessel fairlead to a Fixed anchor on the seabed),
    !! moved by a vesselMotion record (surge 1 m and roll 3 deg from rest): every step hands the
    !! cable the vessel's orientation, angular velocity and acceleration with its fairlead state.
    INTEGER, PARAMETER :: N_WARM = 40, NT = 200
    REAL(wp), PARAMETER :: DTM = 0.05_wp, PI = 3.14159265358979323846_wp
    CHARACTER(*), PARAMETER :: ROOT = 'step_alloc_driver_vessel'
    REAL(wp) :: t, x, vx, ax, ro, dro, d2ro, om
    INTEGER :: u, k
    INTEGER(C_LONG_LONG) :: c0, n_alloc, n_steps
    LOGICAL :: converged
    om = 2.0_wp*PI/10.0_wp
    OPEN (NEWUNIT=u, FILE=ROOT//'.txt', STATUS='REPLACE', ACTION='WRITE')
    DO k = 0, NT + 1
      t = DTM*k
      x = 0.5_wp*(1.0_wp - COS(om*t))
      vx = 0.5_wp*om*SIN(om*t)
      ax = 0.5_wp*om*om*COS(om*t)
      ro = 1.5_wp*(1.0_wp - COS(om*t))
      dro = 1.5_wp*om*SIN(om*t)*PI/180.0_wp
      d2ro = 1.5_wp*om*om*COS(om*t)*PI/180.0_wp
      ! time x y z roll pitch yaw vx vy vz wx wy wz ax ay az alx aly alz
      WRITE (u, '(F8.3,ES25.16E3,A,ES25.16E3,A,ES25.16E3,A,ES25.16E3,A,ES25.16E3,A,ES25.16E3,A)') t, x, &
        ' 0 -10 ', ro, ' 0 0 ', vx, ' 0 0 ', dro, ' 0 0 ', ax, ' 0 0 ', d2ro, ' 0 0'
    END DO
    CLOSE (u)
    OPEN (NEWUNIT=u, FILE=ROOT//'.dat', STATUS='REPLACE', ACTION='WRITE')
    WRITE (u, '(A)') 'step allocation gate: finite-EI line on a vessel, standalone driver'
    WRITE (u, '(A)') '--- LINE TYPES ---'
    WRITE (u, '(A)') 'Name Diam Mass EA BA EI Cdn Cdt Can Cat'
    WRITE (u, '(A)') '(-) (m) (kg/m) (N) (-) (Nm2) (-) (-) (-) (-)'
    WRITE (u, '(A)') 'cab 0.16 36.7 469000000 -0.5 19900 1.2 0.1 1 0'
    WRITE (u, '(A)') '--- POINTS ---'
    WRITE (u, '(A)') 'ID Type X Y Z Mass Vol CdA Ca'
    WRITE (u, '(A)') '(-) (-) (m) (m) (m) (kg) (m3) (m2) (-)'
    WRITE (u, '(A)') '1 Vessel -20 0 -10 0 0 0 0'
    WRITE (u, '(A)') '2 Fixed -200 0 -100 0 0 0 0'
    WRITE (u, '(A)') '--- LINES ---'
    WRITE (u, '(A)') 'ID NodeA NodeB Outputs'
    WRITE (u, '(A)') '(-) (-) (-) (-)'
    WRITE (u, '(A)') '1 1 2 -'
    WRITE (u, '(A)') '--- SECTIONS ---'
    WRITE (u, '(A)') 'LineID LineType Length NumSegs'
    WRITE (u, '(A)') '(-) (-) (m) (-)'
    WRITE (u, '(A)') '1 cab 260 80'
    WRITE (u, '(A)') '--- OPTIONS ---'
    WRITE (u, '(A)') '9.80665 g'
    WRITE (u, '(A)') '1025.0 rhoW'
    WRITE (u, '(A)') '100 WtrDpth'
    WRITE (u, '(F5.3,A)') DTM, ' dtM'
    WRITE (u, '(F6.2,A)') DTM*NT, ' TMax'
    WRITE (u, '(A)') ROOT//'.txt vesselMotion'
    WRITE (u, '(A)') '0|0|-10 vesselRef'
    WRITE (u, '(A)') '--- OUTPUTS ---'
    WRITE (u, '(A)') 'FairTen1'
    WRITE (u, '(A)') '--- END ---'
    CLOSE (u)
    c0 = cd_test_allocation_count()
    CALL cd_test_phase_counting(1_C_INT, INT(N_WARM, C_LONG_LONG))
    CALL CD_Run_Deck_Driver(ROOT//'.dat', ROOT, converged, es, em)
    n_steps = cd_test_phase_solve_entries()
    CALL cd_test_phase_counting(0_C_INT, 0_C_LONG_LONG)
    n_alloc = cd_test_allocation_count() - c0
    CALL check('driver run')
    IF (.NOT. converged) ERROR STOP 'the driver run did not converge'
    PRINT '(A,I0,A,I0,A,I0,A)', 'standalone driver, finite-EI line on a vessel: ', n_steps, ' steps (', &
      n_steps - N_WARM, ' counted), ', n_alloc, ' heap allocations in their step phase'
    IF (n_steps /= NT) THEN
      PRINT '(A)', 'FAIL: the step phase window did not see every step (CD_Profile_Enter not wrapped?)'
      ERROR STOP 1
    END IF
    IF (n_alloc /= 0) THEN
      PRINT '(A)', 'FAIL: the step phase of the standalone Hermite march allocated after warm-up'
      ERROR STOP 1
    END IF
    PRINT '(A)', 'PASS: no heap allocation in the step phase of the standalone Hermite march after warm-up'
  END SUBROUTINE driver_vessel_gate

  SUBROUTINE mixed_current_gate()
    !! Zero heap allocation in the standalone driver's per-step march of a mixed deck in its own
    !! current: a sagging finite-EI line beside a chain, both fairleads surging (motionFile), in
    !! a Currents 5 grid (x, y, z, t) whose last sample (6 s) the 10 s march passes.
    INTEGER, PARAMETER :: N_WARM = 40, N_COUNT = 160, NT = N_WARM + N_COUNT
    REAL(wp), PARAMETER :: DTM = 0.05_wp, PI = 3.14159265358979323846_wp
    REAL(wp), PARAMETER :: XS(2) = [-10.0_wp, 110.0_wp], YS(2) = [-10.0_wp, 120.0_wp], &
                           ZS(3) = [-210.0_wp, -100.0_wp, 0.0_wp], TS(3) = [0.0_wp, 3.0_wp, 6.0_wp]
    CHARACTER(*), PARAMETER :: DIR = 'step_alloc_mixed_current/'
    TYPE(CD_AGG_ModuleType), ALLOCATABLE :: mag
    REAL(wp), ALLOCATABLE :: p(:, :), v(:, :), a(:, :), ld(:, :), o(:, :, :), w(:, :), al(:, :), roll(:)
    REAL(wp) :: t, x, vx, ax, om
    INTEGER :: u, k, n, n_it, ix, iy, iz, it
    INTEGER(C_LONG_LONG) :: c0, n_alloc
    LOGICAL :: turns, rolls, converged, stalled
    om = 2.0_wp*PI/10.0_wp
    OPEN (NEWUNIT=u, FILE=DIR//'motion.txt', STATUS='REPLACE', ACTION='WRITE')
    DO k = 0, NT
      t = DTM*k
      x = 0.5_wp*(1.0_wp - COS(om*t))
      vx = 0.5_wp*om*SIN(om*t)
      ax = 0.5_wp*om*om*COS(om*t)
      WRITE (u, '(F8.3,A,ES25.16E3,A,ES25.16E3,A,ES25.16E3,A)') t, ' 1 ', x, ' 0 -50 ', vx, ' 0 0 ', ax, ' 0 0'
      WRITE (u, '(F8.3,A,ES25.16E3,A,ES25.16E3,A,ES25.16E3,A)') t, ' 3 ', x, ' 20 -50 ', vx, ' 0 0 ', ax, ' 0 0'
    END DO
    CLOSE (u)
    OPEN (NEWUNIT=u, FILE=DIR//'current_profile_4d.txt', STATUS='REPLACE', ACTION='WRITE')
    WRITE (u, '(A)') '2 2 3 3'
    WRITE (u, '(A)') '-10.0 110.0'
    WRITE (u, '(A)') '-10.0 120.0'
    WRITE (u, '(A)') '-210.0 -100.0 0.0'
    WRITE (u, '(A)') '0.0 3.0 6.0'
    WRITE (u, '(A)') 'x y z t ux uy uz'
    DO it = 1, 3
      DO iz = 1, 3
        DO iy = 1, 2
          DO ix = 1, 2
            WRITE (u, '(4F10.3,3F12.6)') XS(ix), YS(iy), ZS(iz), TS(it), &
              (1.0_wp + ZS(iz)/250.0_wp)*(0.3_wp + 0.002_wp*XS(ix) + 0.1_wp*(it - 1)), &
              (1.0_wp + ZS(iz)/250.0_wp)*(0.2_wp - 0.001_wp*YS(iy)), 0.0_wp
          END DO
        END DO
      END DO
    END DO
    CLOSE (u)
    OPEN (NEWUNIT=u, FILE=DIR//'deck.dat', STATUS='REPLACE', ACTION='WRITE')
    WRITE (u, '(A)') 'step allocation gate: mixed deck in its own current'
    WRITE (u, '(A)') '--- LINE TYPES ---'
    WRITE (u, '(A)') 'Name Diam Mass EA BA EI Cdn Cdt Can Cat'
    WRITE (u, '(A)') '(-) (m) (kg/m) (N) (-) (Nm2) (-) (-) (-) (-)'
    WRITE (u, '(A)') 'cab 0.2 60.0 4.0e8 0.0 1.0e4 1.2 0.1 1.0 0.0'
    WRITE (u, '(A)') 'chain 0.1 50.0 1.0e9 -1.0 0.0 1.37 0.64 1.0 0.0'
    WRITE (u, '(A)') '--- POINTS ---'
    WRITE (u, '(A)') 'ID Type X Y Z Mass Vol CdA Ca'
    WRITE (u, '(A)') '(-) (-) (m) (m) (m) (kg) (m3) (m2) (-)'
    WRITE (u, '(A)') '1 Coupled 0.0 0.0 -50.0 0 0 0 0'
    WRITE (u, '(A)') '2 Fixed 95.0 0.0 -60.0 0 0 0 0'
    WRITE (u, '(A)') '3 Coupled 0.0 20.0 -50.0 0 0 0 0'
    WRITE (u, '(A)') '4 Fixed 0.0 110.0 -100.0 0 0 0 0'
    WRITE (u, '(A)') '--- LINES ---'
    WRITE (u, '(A)') 'ID NodeA NodeB Outputs'
    WRITE (u, '(A)') '(-) (-) (-) (-)'
    WRITE (u, '(A)') '1 1 2 -'
    WRITE (u, '(A)') '2 3 4 -'
    WRITE (u, '(A)') '--- SECTIONS ---'
    WRITE (u, '(A)') 'LineID LineType Length NumSegs'
    WRITE (u, '(A)') '(-) (-) (m) (-)'
    WRITE (u, '(A)') '1 cab 100.0 40'
    WRITE (u, '(A)') '2 chain 110.0 20'
    WRITE (u, '(A)') '--- OPTIONS ---'
    WRITE (u, '(A)') '9.80665 g'
    WRITE (u, '(A)') '1025.0 rhoW'
    WRITE (u, '(A)') '200.0 WtrDpth'
    WRITE (u, '(A)') '0.05 dtM'
    WRITE (u, '(A)') '10.0 TMax'
    WRITE (u, '(A)') '5 Currents'
    WRITE (u, '(A)') 'motion.txt motionFile'
    WRITE (u, '(A)') '--- OUTPUTS ---'
    WRITE (u, '(A)') 'FairTen1'
    WRITE (u, '(A)') '--- END ---'
    CLOSE (u)
    ALLOCATE (mag)
    CALL CD_AGG_Init_From_Deck(mag, DIR//'deck.dat', DTM, es, em, forbid_deck_ambient=.TRUE., &
                               run_tmax=10.0_wp, host_orientation=.TRUE., prescribed_motion=.TRUE., &
                               deck_current=.TRUE.)
    CALL check('current deck initialization')
    n = CD_AGG_NMovingPoints(mag, es, em)
    CALL check('current moving-point count')
    ALLOCATE (p(3, n), v(3, n), a(3, n), ld(3, n), o(3, 3, n), w(3, n), al(3, n), roll(n))
    CALL CD_AGG_GetMovingPointMesh(mag, p, v, a, ld, es, em)
    CALL check('current initial mesh')
    CALL CD_AGG_MotionKinematics(mag, 1, p, v, a, o, w, al, roll, turns, rolls, es, em)
    CALL check('current row 1')
    CALL CD_AGG_UpdateStates_Moving(mag, p, v, a, es, em)
    CALL check('current row 1 transfer')
    CALL CD_AGG_Refresh_Accelerations(mag, es, em)
    CALL check('current row 1 accelerations')
    n_alloc = 0
    DO k = 1, NT
      c0 = cd_test_allocation_count()
      IF (k > N_WARM) CALL cd_test_allocation_counting(1_C_INT)
      CALL CD_AGG_MotionKinematics(mag, k + 1, p, v, a, o, w, al, roll, turns, rolls, es, em)
      IF (es == 0) CALL CD_AGG_Step_Moving(mag, DTM, p, v, a, converged, stalled, n_it, es, em, t_committed=DTM*k)
      CALL cd_test_allocation_counting(0_C_INT)
      CALL check('current step')
      IF (.NOT. converged .OR. stalled) ERROR STOP 'current step did not converge'
      n_alloc = n_alloc + (cd_test_allocation_count() - c0)
    END DO
    CALL CD_AGG_End(mag, es, em)
    PRINT '(A,I0,A,I0,A)', 'mixed deck in a Currents 5 grid: ', N_COUNT, ' counted steps, ', n_alloc, &
      ' heap allocations in the steps'
    IF (n_alloc /= 0) THEN
      PRINT '(A)', 'FAIL: the march of a mixed deck in its own current allocated after warm-up'
      ERROR STOP 1
    END IF
    PRINT '(A)', 'PASS: no heap allocation in the march of a mixed deck in its own current after warm-up'
  END SUBROUTINE mixed_current_gate

  SUBROUTINE check(stage)
    CHARACTER(*), INTENT(IN) :: stage

    IF (es /= 0) THEN
      PRINT '(A)', 'FAIL: '//stage//': '//TRIM(em)
      ERROR STOP 1
    END IF
  END SUBROUTINE check

END PROGRAM test_step_allocations
