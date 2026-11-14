! File: src/CableDyn_System.f90
! SPDX-License-Identifier: Apache-2.0
! Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
MODULE CableDyn_System
  !! Multi-line persistent system owner for the Fortran production core. This
  !! module corresponds to doc/coupling_boundary.md and lifts the single-line
  !! CableDyn_Model lifecycle into one system object with aggregate coupled kinematics
  !! and load exchange. Line models stay independent objects; shared fixed, coupled and
  !! dynamic (free/connect) points are composed around them by this owner rather than
  !! bypassing it. Rigid6 bodies and rods are marched over a system by the deck driver.
  USE CableDyn_Precision, ONLY: wp, CD_ZERO, CD_All_Finite, CD_Is_Finite
  USE CableDyn_FatalReport, ONLY: CD_Fatal_Thread_Init
  USE, INTRINSIC :: ISO_FORTRAN_ENV, ONLY: int64
  USE CableDyn_Model, ONLY: CD_ModelType, CD_Model_Is_Initialized, CD_End_Model, &
                            CD_Model_NCoupledDOF, CD_Model_NDOF, CD_Model_NElem, &
                            CD_Get_Model_CoupledDofs, CD_Get_Model_CoupledMotion, &
                            CD_Get_Model_State, CD_Get_Model_Tension, CD_Get_Model_Internal_Rates, &
                            CD_Model_Has_Viscoelastic, CD_Get_Model_VE_Dl1, CD_Set_Model_VE_Dl1, &
                            CD_Model_Has_Syrope, CD_Get_Model_Syrope_State, CD_Set_Model_Syrope_State, &
                            CD_Model_Has_VIV, CD_Get_Model_VIV_State, CD_Set_Model_VIV_State, CD_Get_Model_VIV_Lift, &
                            CD_Model_Has_Friction, CD_Get_Model_Friction_Anchors, CD_Set_Model_Friction_Anchors, &
                            CD_Latch_Model_VIV_Window, &
                            CD_Get_Model_EndNodeMassDiag, CD_Get_Model_EndNodeAddedMass, &
                            CD_Get_Model_EndNodeTangent, CD_Set_Model_EndQuery, CD_Get_Model_EndQuery, &
                            CD_Model_Seabed_Point_Load, &
                            CD_Update_Model_SegmentLength, CD_ModelControlSaveType, CD_Save_Model_Control, &
                            CD_Restore_Model_Control, &
                            CD_Update_Model_CoupledMotion, CD_Update_Model_Interior_State, CD_Step_Model, &
                            CD_Get_Model_Substep_Counts, CD_SubstepStats, &
                            CD_Calc_Model_CoupledLoads, CD_Recompute_Model_Acceleration, &
                            CD_Calc_Model_CoupledKinematicDerivatives, &
                            CD_Calc_Model_CoupledAccelDerivative, CD_Update_Model_CoupledAccelDerivative, &
                            CD_Calc_Model_CoupledEndMass, &
                            CD_Update_Model_External_Loads, CD_Update_Model_Hydro_Fields, &
                            CD_MODEL_OK, CD_MODEL_BADINPUT, &
                            CD_MODEL_SOLVEFAIL, CD_MODEL_NOT_INITIALIZED, CD_MODEL_ALLOCFAIL, CD_Copy_Model
  USE CableDyn_Line, ONLY: CD_Nodal_Seabed_Stiffness
!$ USE OMP_LIB, ONLY: omp_get_max_threads
  IMPLICIT NONE
  PRIVATE

  ! Per-line OpenMP loops (line step, coupled-load recovery) run a thread team only when the
  ! lines' combined position DOFs reach OMP_LINES_MIN_DOF; below it the team's fork/join cost
  ! exceeds the per-line work. The team is capped at OMP_LINES_MAX_THREADS: larger teams were
  ! slower than four threads on every measured multi-line mooring (see line_team_size).
  INTEGER, PARAMETER :: OMP_LINES_MIN_DOF = 64
  INTEGER, PARAMETER :: OMP_LINES_MAX_THREADS = 4
  ! CD_Step_System subdivision depth that disables the stall fallback (its MAX_SUBDIV): the
  ! junction scheme subdivides the whole coupled step itself
  INTEGER, PARAMETER :: JUNCTION_NO_SUBDIV = 6

  PUBLIC :: CD_SystemType
  PUBLIC :: CD_SystemPointType
  PUBLIC :: CD_LineEndpointBinding
  PUBLIC :: CD_System_Fallback_Count
  PUBLIC :: CD_Get_System_Substep_Counts
  PUBLIC :: CD_System_Fallback_Reset
  PUBLIC :: CD_System_Snapshot
  PUBLIC :: CD_System_Restore
  PUBLIC :: CD_Init_System_From_Models
  PUBLIC :: CD_Init_System_From_Points
  PUBLIC :: CD_End_System
  PUBLIC :: CD_System_NLines
  PUBLIC :: CD_System_NCoupledDOF
  PUBLIC :: CD_System_NPoints
  PUBLIC :: CD_System_NDynamicPoints
  PUBLIC :: CD_System_NHydroPoints, CD_Get_System_HydroPoint_Positions, CD_Set_System_HydroPoint_Fluid
  PUBLIC :: CD_System_NSystemCoupledDOF
  PUBLIC :: CD_Get_System_DynamicPoint_States
  PUBLIC :: CD_Set_System_DynamicPoint_States
  PUBLIC :: CD_System_Line_NDOF
  PUBLIC :: CD_System_Line_NElem
  PUBLIC :: CD_System_Line_Has_Viscoelastic
  PUBLIC :: CD_Get_System_Line_VE_Dl1
  PUBLIC :: CD_Set_System_Line_VE_Dl1
  PUBLIC :: CD_System_Line_Has_Syrope
  PUBLIC :: CD_System_Line_Has_Friction
  PUBLIC :: CD_Get_System_Line_Friction_Anchors
  PUBLIC :: CD_Set_System_Line_Friction_Anchors
  PUBLIC :: CD_Get_System_Line_Syrope_State
  PUBLIC :: CD_System_Line_VIV_MirrorSize, CD_Get_System_Line_VIV_State, CD_Set_System_Line_VIV_State, &
            CD_Get_System_Line_VIV_Lift
  PUBLIC :: CD_Set_System_Line_Syrope_State
  PUBLIC :: CD_Get_System_PointBlocks
  PUBLIC :: CD_Get_System_Point_State
  PUBLIC :: CD_Get_System_Line_State
  PUBLIC :: CD_Get_System_Line_Tension
  PUBLIC :: CD_Get_System_Line_Stretch
  PUBLIC :: CD_Get_System_Line_Internal_Rates
  PUBLIC :: CD_Get_System_CoupledMotion
  PUBLIC :: CD_Update_System_CoupledMotion
  PUBLIC :: CD_Update_System_Point_States
  PUBLIC :: CD_Step_System
  PUBLIC :: CD_Calc_System_CoupledLoads
  PUBLIC :: CD_Calc_System_CoupledKinematicDerivatives
  PUBLIC :: CD_Calc_System_CoupledAccelDerivative
  PUBLIC :: CD_Recompute_System_Acceleration
  PUBLIC :: CD_Update_System_Line_External_Loads
  PUBLIC :: CD_Update_System_Point_Fluid_Fields
  PUBLIC :: CD_Update_System_Line_Hydro_Fields
  PUBLIC :: CD_Update_System_Line_Interior_State
  PUBLIC :: CD_Step_System_DynamicPoints
  PUBLIC :: CD_Step_System_Junction
  PUBLIC :: CD_System_Junction_Rewind
  PUBLIC :: CD_System_Point_Base
  PUBLIC :: CD_System_Point_Environment
  PUBLIC :: CD_System_Point_Seabed
  PUBLIC :: CD_Detach_System_LineEnds
  PUBLIC :: CD_Update_System_Line_SegmentLength
  PUBLIC :: CD_Save_System_Line_Control, CD_Restore_System_Line_Control
  PUBLIC :: CD_System_Is_Initialized
  PUBLIC :: CD_System_Has_DynamicPoints

  INTEGER, PARAMETER, PUBLIC :: CD_SYSTEM_OK = 0
  INTEGER, PARAMETER, PUBLIC :: CD_SYSTEM_BADINPUT = 1
  INTEGER, PARAMETER, PUBLIC :: CD_SYSTEM_SOLVEFAIL = 2
  INTEGER, PARAMETER, PUBLIC :: CD_SYSTEM_NOT_INITIALIZED = 3
  INTEGER, PARAMETER, PUBLIC :: CD_SYSTEM_ALLOCFAIL = 4
  INTEGER, PARAMETER, PUBLIC :: CD_POINT_FIXED = 1
  INTEGER, PARAMETER, PUBLIC :: CD_POINT_COUPLED = 2
  INTEGER, PARAMETER, PUBLIC :: CD_POINT_FREE = 3
  INTEGER, PARAMETER, PUBLIC :: CD_POINT_CONNECT = 4
  INTEGER, PARAMETER, PUBLIC :: CD_LINE_END_A = 1
  INTEGER, PARAMETER, PUBLIC :: CD_LINE_END_B = 2

  TYPE :: CD_SystemPointType
    !! Named system point. Fixed/coupled points are externally prescribed.
    !! Free/connect points are integrated by the system dynamic-point step.
    INTEGER :: id = 0
    INTEGER :: point_type = CD_POINT_COUPLED
    REAL(wp) :: q(3) = CD_ZERO
    REAL(wp) :: v(3) = CD_ZERO
    REAL(wp) :: a(3) = CD_ZERO
    REAL(wp) :: mass = CD_ZERO
    REAL(wp) :: volume = CD_ZERO
    REAL(wp) :: cda = CD_ZERO
    REAL(wp) :: ca = CD_ZERO
    REAL(wp) :: force(3) = CD_ZERO
    ! Reserve points (line-failure pre-allocation) are carried INACTIVE: they own
    ! a frozen coupled block and mirror slots from init (static layout) but are
    ! skipped by the dynamic step until a detach activates them. Regular points
    ! are active from construction.
    LOGICAL :: active = .TRUE.
    ! The attached lines' end-node consistent-mass diagonal share (sum of rho_a*l0/3
    ! over end elements bound to this point), precomputed at init: the dynamic point
    ! step treats it IMPLICITLY (added to the effective mass, its lagged product
    ! removed from the reaction) so a light or massless point with attached lines
    ! integrates stably -- the MoorDyn lumped-end-mass convention adapted to the
    ! consistent EI=0 mass (the m/6 neighbour cross term stays in the lagged load).
    REAL(wp) :: line_mass_diag = CD_ZERO
    REAL(wp) :: fluid_velocity(3) = CD_ZERO
    REAL(wp) :: fluid_acceleration(3) = CD_ZERO
    REAL(wp) :: waterline_z = CD_ZERO
    REAL(wp) :: fluid_density = CD_ZERO
    ! Seabed contact of a Free/Connect point (a clump weight or a grounded buoy): normal
    ! stiffness seabed_k = kBot*A [N/m] and one-sided normal damping seabed_c = cBot*A
    ! [N.s/m] over its contact footprint A, applied with the line nodes' contact law
    ! against the floor of a line bound to the point (CD_System_Point_Seabed). Zero: no
    ! contact (the default, and every point not built from a deck footprint).
    REAL(wp) :: seabed_k = CD_ZERO
    REAL(wp) :: seabed_c = CD_ZERO
  END TYPE CD_SystemPointType

  TYPE :: CD_LineEndpointBinding
    !! Bind one line endpoint to one system point id.
    INTEGER :: line_index = 0
    INTEGER :: line_end = 0
    INTEGER :: point_id = 0
  END TYPE CD_LineEndpointBinding

  TYPE :: CD_SystemType
    !! Persistent multi-line owner. The contained line models are deep copies of
    !! initialized inputs and are released by CD_End_System.
    LOGICAL :: initialized = .FALSE.
    INTEGER :: n_lines = 0
    INTEGER :: n_local_coupled_dof = 0
    INTEGER :: n_system_coupled_dof = 0
    INTEGER, ALLOCATABLE :: coupled_dof_map(:)
    ! Zero-based compact system DOF base per points-array entry, FROZEN at
    ! point-map construction (-1 for output-only unbound points). Stored rather
    ! than rederived from live bindings so a line-end rewire (a line failure,
    ! CD_Detach_System_LineEnds) cannot shift any other point's block: the exchange
    ! layout is init-static, matching the mirror/checkpoint extent rule.
    INTEGER, ALLOCATABLE :: point_dof_base(:)
    TYPE(CD_SystemPointType), ALLOCATABLE :: points(:)
    TYPE(CD_LineEndpointBinding), ALLOCATABLE :: bindings(:)
    TYPE(CD_ModelType), ALLOCATABLE :: lines(:)
    REAL(wp), ALLOCATABLE :: q_work(:)
    REAL(wp), ALLOCATABLE :: v_work(:)
    REAL(wp), ALLOCATABLE :: a_work(:)
    REAL(wp), ALLOCATABLE :: load_work(:)
    REAL(wp), ALLOCATABLE :: point_force_work(:, :)
    REAL(wp), ALLOCATABLE :: point_mass_work(:)
    TYPE(CD_SystemPointType), ALLOCATABLE :: point_rollback(:)
    ! Per-line staging for deterministic parallel solves/output. Each worker owns one
    ! line model and one disjoint slice; statuses are consumed in line order after the
    ! parallel region so failure selection and mapped-load accumulation stay reproducible.
    INTEGER, ALLOCATABLE :: line_off(:), line_stat(:), line_iter(:)
    LOGICAL, ALLOCATABLE :: line_converged(:), line_stalled(:)
    CHARACTER(1024), ALLOCATABLE :: line_msg(:)
    REAL(wp), ALLOCATABLE :: line_load_work(:)
    ! Snapshot of the COMMITTED system state (every line's q/v/a/f_ext + every point) for
    ! the aggregate stage-then-commit contract. The per-line q_rollback buffers CANNOT
    ! serve this role: after a step that succeeded via the adaptive-substep fallback they
    ! hold a mid-interval half-step state, not the step start. Flat buffers concatenate
    ! the lines in order; they allocate on first CD_System_Snapshot (amortised zero;
    ! never touched by the step itself).
    REAL(wp), ALLOCATABLE :: snap_q(:), snap_v(:), snap_a(:), snap_fext(:)
    TYPE(CD_SystemPointType), ALLOCATABLE :: snap_points(:)
    ! Detach TOPOLOGY joins the snapshot: a line failure between snapshot and
    ! restore rewires bindings and the exchange map, and restoring only the point
    ! states would leave the endpoints mapped to the reserve while every point
    ! field (active, line_mass_diag) rolls back -- an inconsistent system.
    TYPE(CD_LineEndpointBinding), ALLOCATABLE :: snap_bindings(:)
    INTEGER, ALLOCATABLE :: snap_map(:)
    ! Length-derived line state joins the snapshot (active line control): l0 and
    ! l0_dot restore directly, the structural mass and any recompute-capable
    ! seabed coefficients are REBUILT from the restored lengths through the same
    ! init helpers (bitwise-deterministic), and the distributed-load remainder
    ! restores with f_ext -- the documented bit-identical restore must hold
    ! WITHOUT the caller re-applying its command.
    REAL(wp), ALLOCATABLE :: snap_l0(:), snap_l0_dot(:), snap_fbase(:), snap_l0_c(:), snap_l0_dot_c(:)
    ! Viscoelastic dl_1 joins the snapshot (per-element, concatenated like
    ! snap_l0): the state advances with every committed line step, so the
    ! aggregate stage-then-commit restore must rewind it with q/v/a.
    REAL(wp), ALLOCATABLE :: snap_ve_dl_1(:)
    ! Syrope slow-strain and running-max states join the snapshot the same way
    ! (per-element, concatenated like snap_l0).
    REAL(wp), ALLOCATABLE :: snap_syrope_slow(:), snap_syrope_tmax(:)
    ! Stick-slip seabed friction anchors join the snapshot ((x, y) per node, concatenated
    ! over the friction lines; sized like snap_q, of which it uses two thirds at most).
    REAL(wp), ALLOCATABLE :: snap_fr_anchor(:)
    ! the sub-stepping diagnostics of every line (CD_SubstepStats): they roll back with the
    ! states, so a restored and re-advanced step counts once
    TYPE(CD_SubstepStats), ALLOCATABLE :: snap_sub(:)
    ! VIV shedding phase and cross-flow mean squares join the snapshot (phi then the two
    ! mean squares per node, 3 per node: sized like snap_q, line by line).
    REAL(wp), ALLOCATABLE :: snap_viv(:)
    LOGICAL :: snap_valid = .FALSE.
    ! Adaptive-substep fallback tripwire: how many times CD_Step_System entered the
    ! subdivision retry of this system since its initialisation or the last
    ! CD_System_Fallback_Reset. An increment on the RARE stall path only (the converged path
    ! never touches it), so it is always on: diagnostics can assert that a healthy run never
    ! needed the fallback. Per system, so concurrent systems never mix their counts; not part
    ! of the snapshot (a restored step keeps its count) and of no result.
    INTEGER :: n_fallback_entries = 0
  END TYPE CD_SystemType

CONTAINS

  SUBROUTINE CD_Init_System_From_Models(system, models, ErrStat, ErrMsg, coupled_dof_map)
    !! Initialize a system by deep-copying initialized line models.
    TYPE(CD_SystemType), INTENT(INOUT) :: system
    TYPE(CD_ModelType), INTENT(IN) :: models(:)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    INTEGER, INTENT(IN), OPTIONAL :: coupled_dof_map(:)

    TYPE(CD_SystemType) :: candidate
    INTEGER :: i, es, copy_stat, istat, n_local, nc
    CHARACTER(1024) :: em, copy_msg

    ErrStat = CD_SYSTEM_OK
    ErrMsg = ''
    n_local = 0
    IF (SIZE(models) < 1) THEN
      CALL fail(ErrStat, ErrMsg, 'system requires at least one initialized line model')
      RETURN
    END IF
    DO i = 1, SIZE(models)
      IF (.NOT. CD_Model_Is_Initialized(models(i))) THEN
        CALL fail(ErrStat, ErrMsg, 'all line models must be initialized')
        RETURN
      END IF
      nc = CD_Model_NCoupledDOF(models(i), es, em)
      IF (es /= CD_MODEL_OK) THEN
        ErrStat = CD_SYSTEM_SOLVEFAIL
        ErrMsg = 'CableDyn_System: line coupled-DOF query failed: '//TRIM(em)
        RETURN
      END IF
      n_local = n_local + nc
    END DO
    IF (PRESENT(coupled_dof_map)) THEN
      CALL validate_coupled_map(coupled_dof_map, n_local, ErrStat, ErrMsg)
      IF (ErrStat /= CD_SYSTEM_OK) RETURN
    END IF
    ALLOCATE (candidate%lines(SIZE(models)), STAT=istat)
    IF (istat /= 0) THEN
      CALL alloc_fail(ErrStat, ErrMsg, 'line storage')
      RETURN
    END IF
    candidate%n_lines = SIZE(models)
    candidate%n_local_coupled_dof = n_local
    ALLOCATE (candidate%line_off(candidate%n_lines + 1), candidate%line_stat(candidate%n_lines), &
              candidate%line_iter(candidate%n_lines), candidate%line_converged(candidate%n_lines), &
              candidate%line_stalled(candidate%n_lines), candidate%line_msg(candidate%n_lines), &
              candidate%line_load_work(n_local), STAT=istat)
    IF (istat /= 0) THEN
      CALL CD_End_System(candidate, es, em)
      CALL alloc_fail(ErrStat, ErrMsg, 'per-line parallel workspace')
      RETURN
    END IF
    candidate%line_off(1) = 1
    DO i = 1, SIZE(models)
      CALL CD_Copy_Model(models(i), candidate%lines(i), copy_stat, copy_msg)
      IF (copy_stat /= CD_MODEL_OK) THEN
        CALL CD_End_System(candidate, es, em)
        IF (copy_stat == CD_MODEL_ALLOCFAIL) THEN
          CALL alloc_fail(ErrStat, ErrMsg, 'line model copy')
        ELSE
          ErrStat = CD_SYSTEM_SOLVEFAIL
          ErrMsg = 'CableDyn_System: line model copy failed: '//TRIM(copy_msg)
        END IF
        RETURN
      END IF
      nc = CD_Model_NCoupledDOF(models(i), es, em)
      IF (es /= CD_MODEL_OK) THEN
        CALL CD_End_System(candidate, copy_stat, copy_msg)
        ErrStat = CD_SYSTEM_SOLVEFAIL
        ErrMsg = 'CableDyn_System: copied line coupled-DOF query failed: '//TRIM(em)
        RETURN
      END IF
      candidate%line_off(i + 1) = candidate%line_off(i) + nc
    END DO
    ALLOCATE (candidate%coupled_dof_map(n_local), STAT=istat)
    IF (istat /= 0) THEN
      CALL CD_End_System(candidate, es, em)
      CALL alloc_fail(ErrStat, ErrMsg, 'coupled map')
      RETURN
    END IF
    IF (PRESENT(coupled_dof_map)) THEN
      candidate%coupled_dof_map = coupled_dof_map
      IF (n_local == 0) THEN
        candidate%n_system_coupled_dof = 0
      ELSE
        candidate%n_system_coupled_dof = MAXVAL(coupled_dof_map)
      END IF
    ELSE
      DO i = 1, n_local
        candidate%coupled_dof_map(i) = i
      END DO
      candidate%n_system_coupled_dof = n_local
    END IF
    ALLOCATE (candidate%q_work(candidate%n_system_coupled_dof), candidate%v_work(candidate%n_system_coupled_dof), &
              candidate%a_work(candidate%n_system_coupled_dof), candidate%load_work(candidate%n_system_coupled_dof), &
              STAT=istat)
    IF (istat /= 0) THEN
      CALL CD_End_System(candidate, es, em)
      CALL alloc_fail(ErrStat, ErrMsg, 'coupled work vectors')
      RETURN
    END IF
    candidate%initialized = .TRUE.
    CALL CD_End_System(system, es, em)
    system = candidate
    CALL CD_End_System(candidate, es, em)
  END SUBROUTINE CD_Init_System_From_Models

  SUBROUTINE CD_Init_System_From_Points(system, models, points, bindings, ErrStat, ErrMsg)
    !! Initialize a system and construct the coupled DOF map from point ids and
    !! line-end bindings. Each line must bind both endpoint triples.
    TYPE(CD_SystemType), INTENT(INOUT) :: system
    TYPE(CD_ModelType), INTENT(IN) :: models(:)
    TYPE(CD_SystemPointType), INTENT(IN) :: points(:)
    TYPE(CD_LineEndpointBinding), INTENT(IN) :: bindings(:)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg

    TYPE(CD_SystemType) :: candidate
    INTEGER, ALLOCATABLE :: map(:), pbase(:)
    INTEGER :: es, istat, i, pidx
    REAL(wp) :: md
    CHARACTER(1024) :: em

    CALL build_point_coupled_map(models, points, bindings, map, pbase, ErrStat, ErrMsg)
    IF (ErrStat /= CD_SYSTEM_OK) RETURN
    CALL CD_Init_System_From_Models(candidate, models, ErrStat, ErrMsg, coupled_dof_map=map)
    IF (ErrStat /= CD_SYSTEM_OK) RETURN
    ! Reserve (inactive) points own coupled blocks ABOVE the line-referenced range:
    ! widen the system exchange extent and its workspaces to cover them, so the
    ! layout is already final when a detach activates a reserve.
    IF (MAXVAL(pbase) + 3 > candidate%n_system_coupled_dof) THEN
      candidate%n_system_coupled_dof = MAXVAL(pbase) + 3
      DEALLOCATE (candidate%q_work, candidate%v_work, candidate%a_work, candidate%load_work)
      ALLOCATE (candidate%q_work(candidate%n_system_coupled_dof), candidate%v_work(candidate%n_system_coupled_dof), &
                candidate%a_work(candidate%n_system_coupled_dof), candidate%load_work(candidate%n_system_coupled_dof), &
                STAT=istat)
      IF (istat /= 0) THEN
        CALL CD_End_System(candidate, es, em)
        CALL alloc_fail(ErrStat, ErrMsg, 'reserved coupled workspace')
        RETURN
      END IF
      candidate%q_work = CD_ZERO
      candidate%v_work = CD_ZERO
      candidate%a_work = CD_ZERO
      candidate%load_work = CD_ZERO
    END IF
    ALLOCATE (candidate%points(SIZE(points)), candidate%bindings(SIZE(bindings)), STAT=istat)
    IF (istat /= 0) THEN
      CALL CD_End_System(candidate, es, em)
      CALL alloc_fail(ErrStat, ErrMsg, 'point binding storage')
      RETURN
    END IF
    candidate%points = points
    candidate%bindings = bindings
    CALL MOVE_ALLOC(pbase, candidate%point_dof_base)
    ! Precompute each point's attached-line end-node consistent-mass diagonal share
    ! (rho_a*l0/3 summed over bound end elements). This field is DERIVED, never
    ! caller-supplied: reset it, then accumulate from the bindings. The dynamic point
    ! step treats it implicitly so light/massless points integrate stably.
    candidate%points(:)%line_mass_diag = CD_ZERO
    DO i = 1, SIZE(bindings)
      pidx = find_point_index(candidate%points, bindings(i)%point_id)
      IF (pidx < 1) THEN
        CALL fail(ErrStat, ErrMsg, 'binding point id has no matching point (mass-diagonal precompute)')
        CALL CD_End_System(candidate, es, em)
        RETURN
      END IF
      CALL CD_Get_Model_EndNodeMassDiag(models(bindings(i)%line_index), bindings(i)%line_end, md, es, em)
      IF (es /= CD_MODEL_OK) THEN
        CALL fail(ErrStat, ErrMsg, 'end-node mass-diagonal precompute failed: '//TRIM(em))
        CALL CD_End_System(candidate, es, em)
        RETURN
      END IF
      candidate%points(pidx)%line_mass_diag = candidate%points(pidx)%line_mass_diag + md
    END DO
    ALLOCATE (candidate%point_force_work(3, SIZE(points)), candidate%point_mass_work(SIZE(points)), &
              candidate%point_rollback(SIZE(points)), STAT=istat)
    IF (istat /= 0) THEN
      CALL CD_End_System(candidate, es, em)
      CALL alloc_fail(ErrStat, ErrMsg, 'point work storage')
      RETURN
    END IF
    CALL CD_End_System(system, es, em)
    system = candidate
    CALL CD_End_System(candidate, es, em)
  END SUBROUTINE CD_Init_System_From_Points

  SUBROUTINE CD_End_System(system, ErrStat, ErrMsg)
    !! Release all contained line models. Safe on an uninitialized system.
    TYPE(CD_SystemType), INTENT(INOUT) :: system
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg

    INTEGER :: i, es
    CHARACTER(1024) :: em

    IF (ALLOCATED(system%lines)) THEN
      DO i = 1, SIZE(system%lines)
        CALL CD_End_Model(system%lines(i), es, em)
      END DO
      DEALLOCATE (system%lines)
    END IF
    IF (ALLOCATED(system%coupled_dof_map)) DEALLOCATE (system%coupled_dof_map)
    IF (ALLOCATED(system%points)) DEALLOCATE (system%points)
    IF (ALLOCATED(system%bindings)) DEALLOCATE (system%bindings)
    IF (ALLOCATED(system%point_dof_base)) DEALLOCATE (system%point_dof_base)
    IF (ALLOCATED(system%q_work)) DEALLOCATE (system%q_work)
    IF (ALLOCATED(system%v_work)) DEALLOCATE (system%v_work)
    IF (ALLOCATED(system%a_work)) DEALLOCATE (system%a_work)
    IF (ALLOCATED(system%load_work)) DEALLOCATE (system%load_work)
    IF (ALLOCATED(system%point_force_work)) DEALLOCATE (system%point_force_work)
    IF (ALLOCATED(system%point_mass_work)) DEALLOCATE (system%point_mass_work)
    IF (ALLOCATED(system%point_rollback)) DEALLOCATE (system%point_rollback)
    IF (ALLOCATED(system%line_off)) DEALLOCATE (system%line_off)
    IF (ALLOCATED(system%line_stat)) DEALLOCATE (system%line_stat)
    IF (ALLOCATED(system%line_iter)) DEALLOCATE (system%line_iter)
    IF (ALLOCATED(system%line_converged)) DEALLOCATE (system%line_converged)
    IF (ALLOCATED(system%line_stalled)) DEALLOCATE (system%line_stalled)
    IF (ALLOCATED(system%line_msg)) DEALLOCATE (system%line_msg)
    IF (ALLOCATED(system%line_load_work)) DEALLOCATE (system%line_load_work)
    IF (ALLOCATED(system%snap_q)) DEALLOCATE (system%snap_q, system%snap_v, &
                                              system%snap_a, system%snap_fext)
    IF (ALLOCATED(system%snap_points)) DEALLOCATE (system%snap_points)
    IF (ALLOCATED(system%snap_bindings)) DEALLOCATE (system%snap_bindings)
    IF (ALLOCATED(system%snap_map)) DEALLOCATE (system%snap_map)
    IF (ALLOCATED(system%snap_l0)) DEALLOCATE (system%snap_l0, system%snap_l0_dot)
    IF (ALLOCATED(system%snap_l0_c)) DEALLOCATE (system%snap_l0_c, system%snap_l0_dot_c)
    IF (ALLOCATED(system%snap_fbase)) DEALLOCATE (system%snap_fbase)
    IF (ALLOCATED(system%snap_ve_dl_1)) DEALLOCATE (system%snap_ve_dl_1)
    IF (ALLOCATED(system%snap_viv)) DEALLOCATE (system%snap_viv)
    IF (ALLOCATED(system%snap_syrope_slow)) DEALLOCATE (system%snap_syrope_slow, system%snap_syrope_tmax)
    IF (ALLOCATED(system%snap_fr_anchor)) DEALLOCATE (system%snap_fr_anchor)
    IF (ALLOCATED(system%snap_sub)) DEALLOCATE (system%snap_sub)
    system%snap_valid = .FALSE.
    system%initialized = .FALSE.
    system%n_lines = 0
    system%n_local_coupled_dof = 0
    system%n_system_coupled_dof = 0
    ErrStat = CD_SYSTEM_OK
    ErrMsg = ''
  END SUBROUTINE CD_End_System

  INTEGER FUNCTION CD_System_NLines(system, ErrStat, ErrMsg) RESULT(n)
    !! Return the number of line models owned by an initialized system.
    TYPE(CD_SystemType), INTENT(IN) :: system
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg

    IF (.NOT. system%initialized) THEN
      n = 0
      ErrStat = CD_SYSTEM_NOT_INITIALIZED
      ErrMsg = 'CableDyn_System: system is not initialized'
      RETURN
    END IF
    n = system%n_lines
    ErrStat = CD_SYSTEM_OK
    ErrMsg = ''
  END FUNCTION CD_System_NLines

  INTEGER FUNCTION CD_System_NCoupledDOF(system, ErrStat, ErrMsg) RESULT(n)
    !! Return the compact system exchange DOF count. With a shared-point map this
    !! can be smaller than the sum of all line endpoint DOFs.
    TYPE(CD_SystemType), INTENT(IN) :: system
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg

    n = 0
    IF (.NOT. system%initialized) THEN
      ErrStat = CD_SYSTEM_NOT_INITIALIZED
      ErrMsg = 'CableDyn_System: system is not initialized'
      RETURN
    END IF
    n = system%n_system_coupled_dof
    ErrStat = CD_SYSTEM_OK
    ErrMsg = ''
  END FUNCTION CD_System_NCoupledDOF

  INTEGER FUNCTION CD_System_NPoints(system, ErrStat, ErrMsg) RESULT(n)
    !! Return the number of stored system/deck points (SIZE(system%points)), or 0 for a
    !! line-initialized system. This can exceed CD_System_NCoupledDOF/3 when the system has
    !! unbound (output-only) Fixed/Coupled points: the coupled-DOF map only counts bound
    !! points, while the point fluid-field update is sized by the full stored point count.
    TYPE(CD_SystemType), INTENT(IN) :: system
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg

    n = 0
    IF (.NOT. system%initialized) THEN
      ErrStat = CD_SYSTEM_NOT_INITIALIZED
      ErrMsg = 'CableDyn_System: system is not initialized'
      RETURN
    END IF
    IF (ALLOCATED(system%points)) n = SIZE(system%points)
    ErrStat = CD_SYSTEM_OK
    ErrMsg = ''
  END FUNCTION CD_System_NPoints

  INTEGER FUNCTION CD_System_NDynamicPoints(system) RESULT(n)
    !! Number of DYNAMIC (Free/Connect) system points -- the states the system
    !! integrates itself, as opposed to externally prescribed Fixed/Coupled points.
    !! 0 for an uninitialized system or one carrying no point store.
    TYPE(CD_SystemType), INTENT(IN) :: system
    INTEGER :: i
    n = 0
    IF (.NOT. system%initialized) RETURN
    IF (.NOT. ALLOCATED(system%points)) RETURN
    DO i = 1, SIZE(system%points)
      IF (system%points(i)%point_type == CD_POINT_FREE .OR. &
          system%points(i)%point_type == CD_POINT_CONNECT) n = n + 1
    END DO
  END FUNCTION CD_System_NDynamicPoints

  INTEGER FUNCTION CD_System_NHydroPoints(system) RESULT(n)
    !! Number of DYNAMIC (Free/Connect) points that are hydro-active -- carrying a submerged volume
    !! (Vol > 0, for Froude-Krylov + buoyancy wetting) or a Morison coefficient (CdA > 0 for drag,
    !! Ca > 0 for added mass) -- i.e. the points the coupled fluid contract samples the ambient field
    !! at. A massless coefficient-free dynamic point is NOT counted, so a mooring with no hydro buoy
    !! adds zero fluid nodes. A Vol-only buoy
    !! IS counted so it takes the wave Froude-Krylov load rho*Vol*(1+Ca)*accel consistently with the
    !! lines and Rigid6 bodies (in still water no field is set, so it stays constant-buoyancy).
    TYPE(CD_SystemType), INTENT(IN) :: system
    INTEGER :: i
    n = 0
    IF (.NOT. system%initialized) RETURN
    IF (.NOT. ALLOCATED(system%points)) RETURN
    DO i = 1, SIZE(system%points)
      IF ((system%points(i)%point_type == CD_POINT_FREE .OR. &
           system%points(i)%point_type == CD_POINT_CONNECT) .AND. &
          (system%points(i)%volume > CD_ZERO .OR. system%points(i)%cda > CD_ZERO .OR. &
           system%points(i)%ca > CD_ZERO)) n = n + 1
    END DO
  END FUNCTION CD_System_NHydroPoints

  SUBROUTINE CD_Get_System_HydroPoint_Positions(system, xyz, ErrStat, ErrMsg)
    !! Committed positions (3, NHydroPoints) of the hydro-active dynamic points, in points-array
    !! order -- where the host samples the ambient field for the coupled fluid contract. Shape
    !! must match CD_System_NHydroPoints; a no-op when the system carries no hydro point.
    TYPE(CD_SystemType), INTENT(IN) :: system
    REAL(wp), INTENT(OUT) :: xyz(:, :)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    INTEGER :: i, k, nh
    ErrStat = CD_SYSTEM_OK
    ErrMsg = ''
    nh = CD_System_NHydroPoints(system)
    IF (nh == 0) RETURN
    IF (SIZE(xyz, 1) /= 3 .OR. SIZE(xyz, 2) /= nh) THEN
      CALL fail(ErrStat, ErrMsg, 'hydro-point positions must be shaped (3, NHydroPoints)')
      RETURN
    END IF
    k = 0
    DO i = 1, SIZE(system%points)
      IF ((system%points(i)%point_type == CD_POINT_FREE .OR. &
           system%points(i)%point_type == CD_POINT_CONNECT) .AND. &
          (system%points(i)%volume > CD_ZERO .OR. system%points(i)%cda > CD_ZERO .OR. &
           system%points(i)%ca > CD_ZERO)) THEN
        k = k + 1
        xyz(:, k) = system%points(i)%q
      END IF
    END DO
  END SUBROUTINE CD_Get_System_HydroPoint_Positions

  SUBROUTINE CD_Set_System_HydroPoint_Fluid(system, fluid_velocity, fluid_acceleration, &
                                            waterline_z, fluid_density, ErrStat, ErrMsg)
    !! Prescribe the ambient fluid field on the hydro-active dynamic points, in the SAME
    !! points-array order as CD_Get_System_HydroPoint_Positions. Non-hydro points are untouched
    !! (their fluid_density stays zero, so point_environment_force is a no-op for them and a
    !! pure-buoyancy / coefficient-free point is bit-identical). Fails closed on a wrong shape,
    !! a non-finite field, or a negative density.
    TYPE(CD_SystemType), INTENT(INOUT) :: system
    REAL(wp), INTENT(IN) :: fluid_velocity(:, :), fluid_acceleration(:, :), waterline_z(:)
    REAL(wp), INTENT(IN) :: fluid_density
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    INTEGER :: i, k, nh
    ErrStat = CD_SYSTEM_OK
    ErrMsg = ''
    nh = CD_System_NHydroPoints(system)
    IF (nh == 0) RETURN
    IF (SIZE(fluid_velocity, 1) /= 3 .OR. SIZE(fluid_velocity, 2) /= nh .OR. &
        SIZE(fluid_acceleration, 1) /= 3 .OR. SIZE(fluid_acceleration, 2) /= nh .OR. &
        SIZE(waterline_z) /= nh) THEN
      CALL fail(ErrStat, ErrMsg, 'hydro-point fluid fields must be shaped (3, NHydroPoints) / (NHydroPoints)')
      RETURN
    END IF
    IF (.NOT. (CD_All_Finite(fluid_velocity) .AND. CD_All_Finite(fluid_acceleration) .AND. &
               CD_All_Finite(waterline_z) .AND. CD_Is_Finite(fluid_density))) THEN
      CALL fail(ErrStat, ErrMsg, 'hydro-point fluid fields must be finite')
      RETURN
    END IF
    IF (fluid_density < CD_ZERO) THEN
      CALL fail(ErrStat, ErrMsg, 'hydro-point fluid density must be non-negative')
      RETURN
    END IF
    k = 0
    DO i = 1, SIZE(system%points)
      IF ((system%points(i)%point_type == CD_POINT_FREE .OR. &
           system%points(i)%point_type == CD_POINT_CONNECT) .AND. &
          (system%points(i)%volume > CD_ZERO .OR. system%points(i)%cda > CD_ZERO .OR. &
           system%points(i)%ca > CD_ZERO)) THEN
        k = k + 1
        system%points(i)%fluid_velocity = fluid_velocity(:, k)
        system%points(i)%fluid_acceleration = fluid_acceleration(:, k)
        system%points(i)%waterline_z = waterline_z(k)
        system%points(i)%fluid_density = fluid_density
      END IF
    END DO
  END SUBROUTINE CD_Set_System_HydroPoint_Fluid

  INTEGER FUNCTION CD_System_NSystemCoupledDOF(system) RESULT(n)
    !! Size of the compact coupled-motion exchange vector (per-LINE-END slots): the
    !! surface CD_Get/Update_System_CoupledMotion carry. 0 for an uninitialized system.
    TYPE(CD_SystemType), INTENT(IN) :: system
    n = 0
    IF (.NOT. system%initialized) RETURN
    n = system%n_system_coupled_dof
  END FUNCTION CD_System_NSystemCoupledDOF

  SUBROUTINE CD_Get_System_DynamicPoint_States(system, buf, ErrStat, ErrMsg)
    !! Copy every DYNAMIC (Free/Connect) point's committed [v(3); q(3); a(3)] into buf,
    !! in the points-array order (the deterministic layout a checkpoint mirror packs).
    !! buf must be exactly 9 * CD_System_NDynamicPoints long.
    TYPE(CD_SystemType), INTENT(IN) :: system
    REAL(wp), INTENT(OUT) :: buf(:)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    INTEGER :: i, k
    ErrStat = CD_SYSTEM_OK
    ErrMsg = ''
    buf = CD_ZERO
    IF (.NOT. system%initialized) THEN
      ErrStat = CD_SYSTEM_NOT_INITIALIZED
      ErrMsg = 'CableDyn_System: system is not initialized'; RETURN
    END IF
    IF (SIZE(buf) /= 9*CD_System_NDynamicPoints(system)) THEN
      ErrStat = CD_SYSTEM_BADINPUT
      ErrMsg = 'CableDyn_System: dynamic-point state buffer must be 9 * n_dynamic'; RETURN
    END IF
    ! The point STORE: the line-endpoint states travel separately through the compact
    ! coupled-motion vector (per-line-end slots), so this block carries only the
    ! integrator's own point kinematics.
    k = 0
    DO i = 1, point_store_size(system)
      IF (.NOT. point_is_dynamic(system, i)) CYCLE
      buf(k + 1:k + 3) = system%points(i)%v
      buf(k + 4:k + 6) = system%points(i)%q
      buf(k + 7:k + 9) = system%points(i)%a
      k = k + 9
    END DO
  END SUBROUTINE CD_Get_System_DynamicPoint_States

  SUBROUTINE CD_Set_System_DynamicPoint_States(system, buf, ErrStat, ErrMsg)
    !! Restore every DYNAMIC (Free/Connect) point's [v; q; a] from buf (the layout
    !! CD_Get_System_DynamicPoint_States packs) and SCATTER the restored kinematics into
    !! the bound line endpoints through the coupled-motion map -- the same channel the
    !! dynamic-point step uses -- so the lines' endpoint states are consistent with the
    !! restored points (a checkpoint restore writes line INTERIORS separately; a
    !! free-bound endpoint is neither host boundary nor static, it is this state).
    TYPE(CD_SystemType), INTENT(INOUT) :: system
    REAL(wp), INTENT(IN) :: buf(:)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    INTEGER :: i, k, es, base
    CHARACTER(1024) :: em
    ErrStat = CD_SYSTEM_OK
    ErrMsg = ''
    IF (.NOT. system%initialized) THEN
      ErrStat = CD_SYSTEM_NOT_INITIALIZED
      ErrMsg = 'CableDyn_System: system is not initialized'; RETURN
    END IF
    IF (SIZE(buf) /= 9*CD_System_NDynamicPoints(system)) THEN
      ErrStat = CD_SYSTEM_BADINPUT
      ErrMsg = 'CableDyn_System: dynamic-point state buffer must be 9 * n_dynamic'; RETURN
    END IF
    IF (.NOT. CD_All_Finite(buf)) THEN
      ErrStat = CD_SYSTEM_BADINPUT
      ErrMsg = 'CableDyn_System: dynamic-point states must be finite'; RETURN
    END IF
    ! Scatter the restored per-point kinematics into the bound line endpoints through
    ! the coupled-motion map, so the setter is SELF-SUFFICIENT: the next dynamic-point
    ! step reads its entry kinematics from the line endpoints, and a standalone rewind
    ! that only wrote the store would leave the endpoints at the drifted state. The
    ! point slots are per-POINT in the compact map (the step's one-value-per-point
    ! contract, verified by the gather guard), so writing one value per point is exact;
    ! vessel/fixed slots are read back unchanged. A caller that restores the full
    ! coupled vector first (the checkpoint reload) makes this a harmless idempotent
    ! rewrite of the same values. The scatter is staged straight from buf and the point
    ! store is written only after it succeeds, so a failure leaves both unchanged.
    CALL CD_Get_System_CoupledMotion(system, system%q_work, system%v_work, system%a_work, es, em)
    IF (es /= CD_SYSTEM_OK) THEN
      ErrStat = es; ErrMsg = 'CableDyn_System: dynamic-point restore read: '//TRIM(em); RETURN
    END IF
    k = 0
    DO i = 1, point_store_size(system)
      IF (.NOT. point_is_dynamic(system, i)) CYCLE
      base = point_coupled_base(system, i)
      IF (base >= 0) THEN
        system%v_work(base + 1:base + 3) = buf(k + 1:k + 3)
        system%q_work(base + 1:base + 3) = buf(k + 4:k + 6)
        system%a_work(base + 1:base + 3) = buf(k + 7:k + 9)
      END IF
      k = k + 9
    END DO
    CALL CD_Update_System_CoupledMotion(system, system%q_work, system%v_work, system%a_work, es, em)
    IF (es /= CD_SYSTEM_OK) THEN
      ErrStat = es; ErrMsg = 'CableDyn_System: dynamic-point restore scatter: '//TRIM(em); RETURN
    END IF
    k = 0
    DO i = 1, point_store_size(system)
      IF (.NOT. point_is_dynamic(system, i)) CYCLE
      system%points(i)%v = buf(k + 1:k + 3)
      system%points(i)%q = buf(k + 4:k + 6)
      system%points(i)%a = buf(k + 7:k + 9)
      k = k + 9
    END DO
  END SUBROUTINE CD_Set_System_DynamicPoint_States

  INTEGER FUNCTION point_store_size(system) RESULT(n)
    TYPE(CD_SystemType), INTENT(IN) :: system
    n = 0
    IF (ALLOCATED(system%points)) n = SIZE(system%points)
  END FUNCTION point_store_size

  LOGICAL FUNCTION point_is_dynamic(system, i) RESULT(dyn)
    TYPE(CD_SystemType), INTENT(IN) :: system
    INTEGER, INTENT(IN) :: i
    dyn = system%points(i)%point_type == CD_POINT_FREE .OR. &
          system%points(i)%point_type == CD_POINT_CONNECT
  END FUNCTION point_is_dynamic

  INTEGER FUNCTION CD_System_Line_NDOF(system, line_index, ErrStat, ErrMsg) RESULT(n)
    !! Return the full state size for one contained line.
    TYPE(CD_SystemType), INTENT(IN) :: system
    INTEGER, INTENT(IN) :: line_index
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg

    n = query_line_int(system, line_index, CD_Model_NDOF, ErrStat, ErrMsg)
  END FUNCTION CD_System_Line_NDOF

  INTEGER FUNCTION CD_System_Line_NElem(system, line_index, ErrStat, ErrMsg) RESULT(n)
    !! Return the element count for one contained line.
    TYPE(CD_SystemType), INTENT(IN) :: system
    INTEGER, INTENT(IN) :: line_index
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg

    n = query_line_int(system, line_index, CD_Model_NElem, ErrStat, ErrMsg)
  END FUNCTION CD_System_Line_NElem

  SUBROUTINE CD_Get_System_Point_State(system, point_id, q, v, a, ErrStat, ErrMsg)
    !! Copy the current state for one point-owned system node.
    TYPE(CD_SystemType), INTENT(IN) :: system
    INTEGER, INTENT(IN) :: point_id
    REAL(wp), INTENT(OUT) :: q(3), v(3), a(3)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg

    INTEGER :: pidx

    q = CD_ZERO
    v = CD_ZERO
    a = CD_ZERO
    IF (.NOT. system%initialized) THEN
      ErrStat = CD_SYSTEM_NOT_INITIALIZED
      ErrMsg = 'CableDyn_System: system is not initialized'
      RETURN
    END IF
    IF (.NOT. ALLOCATED(system%points)) THEN
      CALL fail(ErrStat, ErrMsg, 'point state query requires a point-initialized system')
      RETURN
    END IF
    pidx = find_point_index(system%points, point_id)
    IF (pidx == 0) THEN
      CALL fail(ErrStat, ErrMsg, 'point state query references an unknown point id')
      RETURN
    END IF
    q = system%points(pidx)%q
    v = system%points(pidx)%v
    a = system%points(pidx)%a
    ErrStat = CD_SYSTEM_OK
    ErrMsg = ''
  END SUBROUTINE CD_Get_System_Point_State

  SUBROUTINE CD_Get_System_Line_State(system, line_index, q, v, a, ErrStat, ErrMsg)
    !! Copy the full state for one contained line.
    TYPE(CD_SystemType), INTENT(IN) :: system
    INTEGER, INTENT(IN) :: line_index
    REAL(wp), INTENT(OUT) :: q(:), v(:), a(:)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg

    INTEGER :: es
    CHARACTER(1024) :: em

    q = CD_ZERO
    v = CD_ZERO
    a = CD_ZERO
    CALL validate_line_index(system, line_index, ErrStat, ErrMsg)
    IF (ErrStat /= CD_SYSTEM_OK) RETURN
    CALL CD_Get_Model_State(system%lines(line_index), q, v, a, es, em)
    IF (es /= CD_MODEL_OK) THEN
      ErrStat = CD_SYSTEM_SOLVEFAIL
      ErrMsg = 'CableDyn_System: line state query failed: '//TRIM(em)
      RETURN
    END IF
    ErrStat = CD_SYSTEM_OK
    ErrMsg = ''
  END SUBROUTINE CD_Get_System_Line_State

  PURE LOGICAL FUNCTION CD_System_Line_Has_Viscoelastic(system, line_index) RESULT(has)
    !! True if the given contained line carries series-Kelvin viscoelastic state -- the coupled
    !! checkpoint mirror queries this to size and pack the per-line dl_1 block.
    TYPE(CD_SystemType), INTENT(IN) :: system
    INTEGER, INTENT(IN) :: line_index
    has = .FALSE.
    IF (line_index >= 1 .AND. line_index <= system%n_lines) &
      has = CD_Model_Has_Viscoelastic(system%lines(line_index))
  END FUNCTION CD_System_Line_Has_Viscoelastic

  SUBROUTINE CD_Get_System_Line_VE_Dl1(system, line_index, dl1, ErrStat, ErrMsg)
    !! Copy one contained line's per-element viscoelastic dl_1 (checkpoint mirror pack).
    TYPE(CD_SystemType), INTENT(IN) :: system
    INTEGER, INTENT(IN) :: line_index
    REAL(wp), INTENT(OUT) :: dl1(:)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg

    INTEGER :: es
    CHARACTER(1024) :: em

    dl1 = CD_ZERO
    CALL validate_line_index(system, line_index, ErrStat, ErrMsg)
    IF (ErrStat /= CD_SYSTEM_OK) RETURN
    CALL CD_Get_Model_VE_Dl1(system%lines(line_index), dl1, es, em)
    IF (es /= CD_MODEL_OK) THEN
      ErrStat = CD_SYSTEM_SOLVEFAIL
      ErrMsg = 'CableDyn_System: line dl_1 query failed: '//TRIM(em)
      RETURN
    END IF
    ErrStat = CD_SYSTEM_OK
    ErrMsg = ''
  END SUBROUTINE CD_Get_System_Line_VE_Dl1

  SUBROUTINE CD_Set_System_Line_VE_Dl1(system, line_index, dl1, ErrStat, ErrMsg)
    !! Overwrite one contained line's per-element viscoelastic dl_1 from a checkpoint
    !! mirror (the cross-process restart reload).
    TYPE(CD_SystemType), INTENT(INOUT) :: system
    INTEGER, INTENT(IN) :: line_index
    REAL(wp), INTENT(IN) :: dl1(:)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg

    INTEGER :: es
    CHARACTER(1024) :: em

    CALL validate_line_index(system, line_index, ErrStat, ErrMsg)
    IF (ErrStat /= CD_SYSTEM_OK) RETURN
    CALL CD_Set_Model_VE_Dl1(system%lines(line_index), dl1, es, em)
    IF (es /= CD_MODEL_OK) THEN
      ErrStat = CD_SYSTEM_SOLVEFAIL
      ErrMsg = 'CableDyn_System: line dl_1 reload failed: '//TRIM(em)
      RETURN
    END IF
    ErrStat = CD_SYSTEM_OK
    ErrMsg = ''
  END SUBROUTINE CD_Set_System_Line_VE_Dl1

  PURE LOGICAL FUNCTION CD_System_Line_Has_Syrope(system, line_index) RESULT(has)
    !! True if the given contained line carries Syrope (working-curve) state -- the
    !! coupled checkpoint mirror queries this to size and pack the per-line state block.
    TYPE(CD_SystemType), INTENT(IN) :: system
    INTEGER, INTENT(IN) :: line_index
    has = .FALSE.
    IF (line_index >= 1 .AND. line_index <= system%n_lines) &
      has = CD_Model_Has_Syrope(system%lines(line_index))
  END FUNCTION CD_System_Line_Has_Syrope

  SUBROUTINE CD_Get_System_Line_Syrope_State(system, line_index, slow, tmax, ErrStat, ErrMsg)
    !! Copy one contained line's per-element Syrope states (slow-spring static strain +
    !! running-maximum tension) for the checkpoint mirror pack.
    TYPE(CD_SystemType), INTENT(IN) :: system
    INTEGER, INTENT(IN) :: line_index
    REAL(wp), INTENT(OUT) :: slow(:), tmax(:)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg

    INTEGER :: es
    CHARACTER(1024) :: em

    slow = CD_ZERO
    tmax = CD_ZERO
    CALL validate_line_index(system, line_index, ErrStat, ErrMsg)
    IF (ErrStat /= CD_SYSTEM_OK) RETURN
    CALL CD_Get_Model_Syrope_State(system%lines(line_index), slow, tmax, es, em)
    IF (es /= CD_MODEL_OK) THEN
      ErrStat = CD_SYSTEM_SOLVEFAIL
      ErrMsg = 'CableDyn_System: line Syrope-state query failed: '//TRIM(em)
      RETURN
    END IF
    ErrStat = CD_SYSTEM_OK
    ErrMsg = ''
  END SUBROUTINE CD_Get_System_Line_Syrope_State

  PURE INTEGER FUNCTION CD_System_Line_VIV_MirrorSize(system, line_index) RESULT(n)
    !! Reals of one contained line's VIV checkpoint block (CD_Get_System_Line_VIV_State):
    !! 3 per node plus the averaging time, or 0 for a line without VIV.
    TYPE(CD_SystemType), INTENT(IN) :: system
    INTEGER, INTENT(IN) :: line_index
    n = 0
    IF (line_index < 1 .OR. line_index > system%n_lines) RETURN
    IF (.NOT. CD_Model_Has_VIV(system%lines(line_index))) RETURN
    n = 3*SIZE(system%lines(line_index)%viv_phi) + 1
  END FUNCTION CD_System_Line_VIV_MirrorSize

  SUBROUTINE CD_Get_System_Line_VIV_State(system, line_index, buf, ErrStat, ErrMsg)
    !! One contained line's committed VIV state as a flat checkpoint block: the shedding
    !! phases (n_nodes), the cross-flow velocity and acceleration mean squares interleaved
    !! per node (2 n_nodes), then the averaging time.
    TYPE(CD_SystemType), INTENT(IN) :: system
    INTEGER, INTENT(IN) :: line_index
    REAL(wp), INTENT(OUT) :: buf(:)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    INTEGER :: nn, es
    CHARACTER(160) :: em
    REAL(wp), ALLOCATABLE :: phi(:), ms(:, :)

    buf = CD_ZERO
    CALL validate_line_index(system, line_index, ErrStat, ErrMsg)
    IF (ErrStat /= CD_SYSTEM_OK) RETURN
    IF (SIZE(buf) /= CD_System_Line_VIV_MirrorSize(system, line_index) .OR. SIZE(buf) == 0) THEN
      CALL fail(ErrStat, ErrMsg, 'line VIV state block has the wrong size')
      RETURN
    END IF
    nn = (SIZE(buf) - 1)/3
    ALLOCATE (phi(nn), ms(2, nn))
    CALL CD_Get_Model_VIV_State(system%lines(line_index), phi, ms, buf(3*nn + 1), es, em)
    IF (es /= CD_MODEL_OK) THEN
      ErrStat = CD_SYSTEM_SOLVEFAIL
      ErrMsg = 'CableDyn_System: line VIV state query failed: '//TRIM(em)
      RETURN
    END IF
    buf(1:nn) = phi
    buf(nn + 1:3*nn) = RESHAPE(ms, [2*nn])
    ErrStat = CD_SYSTEM_OK
    ErrMsg = ''
  END SUBROUTINE CD_Get_System_Line_VIV_State

  SUBROUTINE CD_Set_System_Line_VIV_State(system, line_index, buf, ErrStat, ErrMsg)
    !! Overwrite one contained line's VIV state from a checkpoint block (see
    !! CD_Get_System_Line_VIV_State).
    TYPE(CD_SystemType), INTENT(INOUT) :: system
    INTEGER, INTENT(IN) :: line_index
    REAL(wp), INTENT(IN) :: buf(:)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    INTEGER :: nn, es
    CHARACTER(160) :: em

    CALL validate_line_index(system, line_index, ErrStat, ErrMsg)
    IF (ErrStat /= CD_SYSTEM_OK) RETURN
    IF (SIZE(buf) /= CD_System_Line_VIV_MirrorSize(system, line_index) .OR. SIZE(buf) == 0) THEN
      CALL fail(ErrStat, ErrMsg, 'line VIV state block has the wrong size')
      RETURN
    END IF
    nn = (SIZE(buf) - 1)/3
    CALL CD_Set_Model_VIV_State(system%lines(line_index), buf(1:nn), RESHAPE(buf(nn + 1:3*nn), [2, nn]), &
                                buf(3*nn + 1), es, em)
    IF (es /= CD_MODEL_OK) THEN
      ErrStat = CD_SYSTEM_SOLVEFAIL
      ErrMsg = 'CableDyn_System: line VIV state reload failed: '//TRIM(em)
      RETURN
    END IF
    ErrStat = CD_SYSTEM_OK
    ErrMsg = ''
  END SUBROUTINE CD_Set_System_Line_VIV_State

  SUBROUTINE CD_Get_System_Line_VIV_Lift(system, line_index, lift, ErrStat, ErrMsg)
    !! VIV lift force on every node of one contained line at the committed state (3, n_nodes).
    TYPE(CD_SystemType), INTENT(IN) :: system
    INTEGER, INTENT(IN) :: line_index
    REAL(wp), INTENT(OUT) :: lift(:, :)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    INTEGER :: es
    CHARACTER(160) :: em

    lift = CD_ZERO
    CALL validate_line_index(system, line_index, ErrStat, ErrMsg)
    IF (ErrStat /= CD_SYSTEM_OK) RETURN
    CALL CD_Get_Model_VIV_Lift(system%lines(line_index), lift, es, em)
    IF (es /= CD_MODEL_OK) THEN
      ErrStat = CD_SYSTEM_SOLVEFAIL
      ErrMsg = 'CableDyn_System: line VIV lift query failed: '//TRIM(em)
      RETURN
    END IF
    ErrStat = CD_SYSTEM_OK
    ErrMsg = ''
  END SUBROUTINE CD_Get_System_Line_VIV_Lift

  SUBROUTINE CD_Set_System_Line_Syrope_State(system, line_index, slow, tmax, ErrStat, ErrMsg)
    !! Overwrite one contained line's per-element Syrope states from a checkpoint mirror
    !! (the cross-process restart reload).
    TYPE(CD_SystemType), INTENT(INOUT) :: system
    INTEGER, INTENT(IN) :: line_index
    REAL(wp), INTENT(IN) :: slow(:), tmax(:)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg

    INTEGER :: es
    CHARACTER(1024) :: em

    CALL validate_line_index(system, line_index, ErrStat, ErrMsg)
    IF (ErrStat /= CD_SYSTEM_OK) RETURN
    CALL CD_Set_Model_Syrope_State(system%lines(line_index), slow, tmax, es, em)
    IF (es /= CD_MODEL_OK) THEN
      ErrStat = CD_SYSTEM_SOLVEFAIL
      ErrMsg = 'CableDyn_System: line Syrope-state reload failed: '//TRIM(em)
      RETURN
    END IF
    ErrStat = CD_SYSTEM_OK
    ErrMsg = ''
  END SUBROUTINE CD_Set_System_Line_Syrope_State

  PURE LOGICAL FUNCTION CD_System_Line_Has_Friction(system, line_index) RESULT(has)
    !! True if the given contained line carries stick-slip seabed friction anchors -- the
    !! coupled checkpoint mirror queries this to size and pack the anchor block.
    TYPE(CD_SystemType), INTENT(IN) :: system
    INTEGER, INTENT(IN) :: line_index
    has = .FALSE.
    IF (line_index >= 1 .AND. line_index <= system%n_lines) &
      has = CD_Model_Has_Friction(system%lines(line_index))
  END FUNCTION CD_System_Line_Has_Friction

  SUBROUTINE CD_Get_System_Line_Friction_Anchors(system, line_index, anchors, ErrStat, ErrMsg)
    !! Copy one contained line's stick-slip friction anchors, (2, n_nodes).
    TYPE(CD_SystemType), INTENT(IN) :: system
    INTEGER, INTENT(IN) :: line_index
    REAL(wp), INTENT(OUT) :: anchors(:, :)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    INTEGER :: es
    CHARACTER(1024) :: em
    anchors = CD_ZERO
    CALL validate_line_index(system, line_index, ErrStat, ErrMsg)
    IF (ErrStat /= CD_SYSTEM_OK) RETURN
    CALL CD_Get_Model_Friction_Anchors(system%lines(line_index), anchors, es, em)
    IF (es /= CD_MODEL_OK) THEN
      ErrStat = CD_SYSTEM_SOLVEFAIL
      ErrMsg = 'CableDyn_System: line friction-anchor query failed: '//TRIM(em)
      RETURN
    END IF
    ErrStat = CD_SYSTEM_OK
    ErrMsg = ''
  END SUBROUTINE CD_Get_System_Line_Friction_Anchors

  SUBROUTINE CD_Set_System_Line_Friction_Anchors(system, line_index, anchors, ErrStat, ErrMsg)
    !! Overwrite one contained line's stick-slip friction anchors from a checkpoint mirror.
    TYPE(CD_SystemType), INTENT(INOUT) :: system
    INTEGER, INTENT(IN) :: line_index
    REAL(wp), INTENT(IN) :: anchors(:, :)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    INTEGER :: es
    CHARACTER(1024) :: em
    CALL validate_line_index(system, line_index, ErrStat, ErrMsg)
    IF (ErrStat /= CD_SYSTEM_OK) RETURN
    CALL CD_Set_Model_Friction_Anchors(system%lines(line_index), anchors, es, em)
    IF (es /= CD_MODEL_OK) THEN
      ErrStat = CD_SYSTEM_SOLVEFAIL
      ErrMsg = 'CableDyn_System: line friction-anchor reload failed: '//TRIM(em)
      RETURN
    END IF
    ErrStat = CD_SYSTEM_OK
    ErrMsg = ''
  END SUBROUTINE CD_Set_System_Line_Friction_Anchors

  SUBROUTINE CD_Get_System_Line_Tension(system, line_index, tension, ErrStat, ErrMsg)
    !! Copy element tensions for one contained line.
    TYPE(CD_SystemType), INTENT(IN) :: system
    INTEGER, INTENT(IN) :: line_index
    REAL(wp), INTENT(OUT) :: tension(:)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg

    INTEGER :: es
    CHARACTER(1024) :: em

    tension = CD_ZERO
    CALL validate_line_index(system, line_index, ErrStat, ErrMsg)
    IF (ErrStat /= CD_SYSTEM_OK) RETURN
    CALL CD_Get_Model_Tension(system%lines(line_index), tension, es, em)
    IF (es /= CD_MODEL_OK) THEN
      ErrStat = CD_SYSTEM_SOLVEFAIL
      ErrMsg = 'CableDyn_System: line tension query failed: '//TRIM(em)
      RETURN
    END IF
    ErrStat = CD_SYSTEM_OK
    ErrMsg = ''
  END SUBROUTINE CD_Get_System_Line_Tension

  SUBROUTINE CD_Get_System_Line_Stretch(system, line_index, stretch, ErrStat, ErrMsg)
    !! Copy the element stretches of one contained line: each element's current chord length
    !! minus its unstretched length (negative on a slack element).
    TYPE(CD_SystemType), INTENT(IN) :: system
    INTEGER, INTENT(IN) :: line_index
    REAL(wp), INTENT(OUT) :: stretch(:)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg

    INTEGER :: e, na, nb

    stretch = CD_ZERO
    CALL validate_line_index(system, line_index, ErrStat, ErrMsg)
    IF (ErrStat /= CD_SYSTEM_OK) RETURN
    ASSOCIATE (ln => system%lines(line_index))
      IF (SIZE(stretch) /= ln%n_elem) THEN
        CALL fail(ErrStat, ErrMsg, 'stretch output must have shape (n_elem)')
        RETURN
      END IF
      DO e = 1, ln%n_elem
        na = ln%elem_conn(1, e)
        nb = ln%elem_conn(2, e)
        stretch(e) = NORM2(ln%q(3*nb - 2:3*nb) - ln%q(3*na - 2:3*na)) - ln%l0(e)
      END DO
    END ASSOCIATE
  END SUBROUTINE CD_Get_System_Line_Stretch

  SUBROUTINE CD_Get_System_Line_Internal_Rates(system, line_index, ve_rate, syrope_rate, ErrStat, ErrMsg)
    !! The per-element constitutive-state rates of one contained line at its current state
    !! (CD_Get_Model_Internal_Rates).
    TYPE(CD_SystemType), INTENT(IN) :: system
    INTEGER, INTENT(IN) :: line_index
    REAL(wp), INTENT(OUT) :: ve_rate(:), syrope_rate(:)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg

    INTEGER :: es
    CHARACTER(1024) :: em

    ve_rate = CD_ZERO
    syrope_rate = CD_ZERO
    CALL validate_line_index(system, line_index, ErrStat, ErrMsg)
    IF (ErrStat /= CD_SYSTEM_OK) RETURN
    CALL CD_Get_Model_Internal_Rates(system%lines(line_index), ve_rate, syrope_rate, es, em)
    IF (es /= CD_MODEL_OK) THEN
      ErrStat = CD_SYSTEM_SOLVEFAIL
      ErrMsg = 'CableDyn_System: line internal-rate query failed: '//TRIM(em)
      RETURN
    END IF
    ErrStat = CD_SYSTEM_OK
    ErrMsg = ''
  END SUBROUTINE CD_Get_System_Line_Internal_Rates

  SUBROUTINE CD_Get_System_CoupledMotion(system, q_coupled, v_coupled, a_coupled, ErrStat, ErrMsg)
    !! Copy aggregate compact coupled motion, concatenated line by line.
    TYPE(CD_SystemType), INTENT(IN) :: system
    REAL(wp), INTENT(OUT) :: q_coupled(:), v_coupled(:), a_coupled(:)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg

    INTEGER :: i, lo, hi, nc, es, local_id, sys_id, dof, n_mapped
    REAL(wp), PARAMETER :: TOL = 1.0e-10_wp
    CHARACTER(1024) :: em

    q_coupled = CD_ZERO
    v_coupled = CD_ZERO
    a_coupled = CD_ZERO
    CALL validate_system_motion_shape(system, q_coupled, v_coupled, a_coupled, ErrStat, ErrMsg)
    IF (ErrStat /= CD_SYSTEM_OK) RETURN
    ! Each line's coupled state is read in place (its fixed DOFs, in CD_Get_Model_CoupledMotion
    ! order). A system DOF shared by several line ends is set by the first and must agree
    ! with the rest; "already set" is an earlier map entry with the same system DOF, so no
    ! per-call marker array is needed (the coupled-DOF count is small).
    lo = 1
    DO i = 1, system%n_lines
      nc = CD_Model_NCoupledDOF(system%lines(i), es, em)
      IF (es /= CD_MODEL_OK) THEN
        ErrStat = CD_SYSTEM_BADINPUT
        ErrMsg = 'CableDyn_System: line coupled-DOF query failed: '//TRIM(em)
        RETURN
      END IF
      hi = lo + nc - 1
      DO local_id = lo, hi
        dof = system%lines(i)%fixed_dofs(local_id - lo + 1)
        sys_id = system%coupled_dof_map(local_id)
        IF (mapped_before(local_id - 1, sys_id)) THEN
          IF (ABS(q_coupled(sys_id) - system%lines(i)%q(dof)) > TOL .OR. &
              ABS(v_coupled(sys_id) - system%lines(i)%v(dof)) > TOL .OR. &
              ABS(a_coupled(sys_id) - system%lines(i)%a(dof)) > TOL) THEN
            CALL fail(ErrStat, ErrMsg, 'mapped coupled DOF has inconsistent line motion state')
            RETURN
          END IF
        ELSE
          q_coupled(sys_id) = system%lines(i)%q(dof)
          v_coupled(sys_id) = system%lines(i)%v(dof)
          a_coupled(sys_id) = system%lines(i)%a(dof)
        END IF
      END DO
      lo = hi + 1
    END DO
    n_mapped = lo - 1
    ! Reserved (inactive-point) blocks have no line-end source: their authoritative
    ! state is the point store. Fill them so the compact vector is complete.
    IF (ALLOCATED(system%points) .AND. ALLOCATED(system%point_dof_base)) THEN
      DO i = 1, SIZE(system%points)
        lo = system%point_dof_base(i)
        IF (lo < 0) CYCLE
        IF (.NOT. mapped_before(n_mapped, lo + 1)) THEN
          q_coupled(lo + 1:lo + 3) = system%points(i)%q
          v_coupled(lo + 1:lo + 3) = system%points(i)%v
          a_coupled(lo + 1:lo + 3) = system%points(i)%a
        END IF
      END DO
    END IF

  CONTAINS

    LOGICAL FUNCTION mapped_before(last, target_id) RESULT(found)
      !! Whether one of the map entries 1..last points at system DOF target_id.
      INTEGER, INTENT(IN) :: last, target_id
      INTEGER :: k
      found = .FALSE.
      DO k = 1, last
        IF (system%coupled_dof_map(k) == target_id) THEN
          found = .TRUE.
          RETURN
        END IF
      END DO
    END FUNCTION mapped_before
  END SUBROUTINE CD_Get_System_CoupledMotion

  SUBROUTINE CD_Update_System_CoupledMotion(system, q_coupled, v_coupled, a_coupled, ErrStat, ErrMsg, &
                                            caller_owns_rollback)
    !! Update aggregate compact coupled motion, concatenated line by line. When
    !! caller_owns_rollback is true the caller must restore a full-state mirror on
    !! both success and failure; this routine deliberately skips its nested snapshot.
    TYPE(CD_SystemType), INTENT(INOUT) :: system
    REAL(wp), INTENT(IN) :: q_coupled(:), v_coupled(:), a_coupled(:)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    LOGICAL, INTENT(IN), OPTIONAL :: caller_owns_rollback

    INTEGER :: i, lo, hi, nc, es
    LOGICAL :: save_for_rollback
    CHARACTER(1024) :: em

    save_for_rollback = .TRUE.
    IF (PRESENT(caller_owns_rollback)) save_for_rollback = .NOT. caller_owns_rollback
    CALL validate_system_motion_shape(system, q_coupled, v_coupled, a_coupled, ErrStat, ErrMsg)
    IF (ErrStat /= CD_SYSTEM_OK) RETURN
    IF (.NOT. CD_All_Finite(q_coupled) .OR. .NOT. CD_All_Finite(v_coupled) .OR. &
        .NOT. CD_All_Finite(a_coupled)) THEN
      CALL fail(ErrStat, ErrMsg, 'aggregate coupled motion must be finite')
      RETURN
    END IF
    IF (save_for_rollback) THEN
      CALL save_line_states(system, ErrStat, ErrMsg)
      IF (ErrStat /= CD_SYSTEM_OK) RETURN
    END IF
    lo = 1
    DO i = 1, system%n_lines
      nc = CD_Model_NCoupledDOF(system%lines(i), es, em)
      IF (es /= CD_MODEL_OK) THEN
        IF (save_for_rollback) CALL restore_line_states(system)
        ErrStat = CD_SYSTEM_BADINPUT
        ErrMsg = 'CableDyn_System: line coupled-DOF query failed: '//TRIM(em)
        RETURN
      END IF
      hi = lo + nc - 1
      BLOCK
        REAL(wp) :: q_local(nc), v_local(nc), a_local(nc)
        CALL scatter_mapped_motion(system, lo, hi, q_coupled, v_coupled, a_coupled, q_local, v_local, a_local)
        CALL CD_Update_Model_CoupledMotion(system%lines(i), q_local, v_local, a_local, es, em)
        IF (es /= CD_MODEL_OK) THEN
          IF (save_for_rollback) CALL restore_line_states(system)
          ErrStat = CD_SYSTEM_SOLVEFAIL
          ErrMsg = 'CableDyn_System: line coupled-motion update failed: '//TRIM(em)
          RETURN
        END IF
      END BLOCK
      lo = hi + 1
    END DO
    ! Keep the point-state cache in sync with the line coupled state. A dynamic-point step
    ! treats system%points as the authoritative prescribed motion, so motion applied through
    ! this (line) path must be reflected there too -- otherwise the step would override a
    ! freshly line-applied Coupled/Fixed endpoint with the stale point cache.
    IF (ALLOCATED(system%points)) THEN
      DO i = 1, SIZE(system%points)
        lo = point_coupled_base(system, i)
        IF (lo < 0) CYCLE
        system%points(i)%q = q_coupled(lo + 1:lo + 3)
        system%points(i)%v = v_coupled(lo + 1:lo + 3)
        system%points(i)%a = a_coupled(lo + 1:lo + 3)
      END DO
    END IF
    ErrStat = CD_SYSTEM_OK
    ErrMsg = ''
  END SUBROUTINE CD_Update_System_CoupledMotion

  SUBROUTINE CD_Update_System_Point_States(system, q_coupled, v_coupled, a_coupled, ErrStat, ErrMsg)
    !! Store aggregate point motion on a point-initialized system.
    TYPE(CD_SystemType), INTENT(INOUT) :: system
    REAL(wp), INTENT(IN) :: q_coupled(:), v_coupled(:), a_coupled(:)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg

    INTEGER :: p, base

    CALL validate_system_motion_shape(system, q_coupled, v_coupled, a_coupled, ErrStat, ErrMsg)
    IF (ErrStat /= CD_SYSTEM_OK) RETURN
    IF (.NOT. CD_All_Finite(q_coupled) .OR. .NOT. CD_All_Finite(v_coupled) .OR. &
        .NOT. CD_All_Finite(a_coupled)) THEN
      CALL fail(ErrStat, ErrMsg, 'aggregate point motion must be finite')
      RETURN
    END IF
    IF (.NOT. ALLOCATED(system%points)) THEN
      CALL fail(ErrStat, ErrMsg, 'point state update requires a point-initialized system')
      RETURN
    END IF
    DO p = 1, SIZE(system%points)
      base = point_coupled_base(system, p)
      IF (base < 0) THEN
        IF (system%points(p)%point_type == CD_POINT_FREE .OR. system%points(p)%point_type == CD_POINT_CONNECT) THEN
          CALL fail(ErrStat, ErrMsg, 'Free/Connect point state update requires a bound point')
          RETURN
        END IF
        CYCLE
      END IF
    END DO
    DO p = 1, SIZE(system%points)
      base = point_coupled_base(system, p)
      IF (base < 0) CYCLE
      system%points(p)%q = q_coupled(base + 1:base + 3)
      system%points(p)%v = v_coupled(base + 1:base + 3)
      system%points(p)%a = a_coupled(base + 1:base + 3)
    END DO
    ErrStat = CD_SYSTEM_OK
    ErrMsg = ''
  END SUBROUTINE CD_Update_System_Point_States

  RECURSIVE SUBROUTINE CD_Step_System(system, dt, q_coupled, v_coupled, a_coupled, converged, stalled, n_iter, &
                                      ErrStat, ErrMsg, subdiv_depth)
    !! Advance every contained line by one dynamic step using aggregate compact
    !! coupled motion as the prescribed endpoint motion. Shared point DOFs are
    !! scattered to each bound line before stepping, and line states are rolled
    !! back if any line solve fails.
    !!
    !! ADAPTIVE SUBDIVISION: an implicit step can stall the line-search under stiff
    !! dynamic drag even at a benign state, which in a long coupled run of many
    !! steps would otherwise eventually abort the whole run. A
    !! stalled step almost always converges at half dt -- the smaller state change sits
    !! inside the Newton basin -- so on a soft non-convergence the step rolls back and
    !! retries as TWO half-steps of the linearly-interpolated prescribed motion,
    !! recursing to a depth floor. The common (converged) case is untouched, so the
    !! large-dt speed of the implicit integrator is preserved; only the rare hard step
    !! subdivides. `subdiv_depth` is the internal recursion counter (callers omit it).
    !!
    !! The fallback is TRANSPARENT: either the halves complete the FULL interval
    !! converged, or the entry state is restored exactly and the plain full-dt step is
    !! re-run at the depth floor -- the committed state and flags are then bit-identical
    !! to the no-fallback behavior (a stalled line's best t+dt attempt with the
    !! prescribed DOFs pinned at t+dt), so a partially-subdivided mid-interval state can
    !! never leak to a caller that records/tolerates convergence misses. The frame keeps
    !! its own t snapshot because the recursive halves reuse the lines' shared rollback
    !! buffers.
    TYPE(CD_SystemType), INTENT(INOUT) :: system
    REAL(wp), INTENT(IN) :: dt
    REAL(wp), INTENT(IN) :: q_coupled(:), v_coupled(:), a_coupled(:)
    LOGICAL, INTENT(OUT) :: converged, stalled
    INTEGER, INTENT(OUT) :: n_iter, ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    INTEGER, INTENT(IN), OPTIONAL :: subdiv_depth

    INTEGER, PARAMETER :: MAX_SUBDIV = 6   ! floor dt/64: resolves any benign line-search stall
    INTEGER :: i, j, lo, hi, nc, es, line_dof, sys_dof, depth, iter2, ntot, nve, nsy, lo_ve, lo_sy, ne, nfr, lo_fr
    INTEGER :: n_team, nel, lo_el
    LOGICAL :: conv2, stall2
    CHARACTER(1024) :: em
    REAL(wp), ALLOCATABLE :: q0(:), v0(:), a0(:), qm(:), vm(:), am(:), qs(:), vs(:), as(:)
    REAL(wp), ALLOCATABLE :: dl1s(:), slows(:), tmaxs(:), frs(:, :), hmaxs(:), l0cs(:), l0dcs(:), vivs(:)
    TYPE(CD_SubstepStats), ALLOCATABLE :: subs(:)

    converged = .FALSE.
    stalled = .FALSE.
    n_iter = 0
    depth = 0
    IF (PRESENT(subdiv_depth)) depth = subdiv_depth
    IF (.NOT. CD_Is_Finite(dt) .OR. dt <= CD_ZERO) THEN
      CALL fail(ErrStat, ErrMsg, 'dt must be finite and positive')
      RETURN
    END IF
    CALL validate_system_motion_shape(system, q_coupled, v_coupled, a_coupled, ErrStat, ErrMsg)
    IF (ErrStat /= CD_SYSTEM_OK) RETURN
    IF (.NOT. CD_All_Finite(q_coupled) .OR. .NOT. CD_All_Finite(v_coupled) .OR. &
        .NOT. CD_All_Finite(a_coupled)) THEN
      CALL fail(ErrStat, ErrMsg, 'aggregate coupled motion must be finite')
      RETURN
    END IF

    ! MoorDyn's VIV averaging window counts nominal steps: latch it before any subdivision
    IF (depth == 0) THEN
      DO i = 1, system%n_lines
        CALL CD_Latch_Model_VIV_Window(system%lines(i), dt)
      END DO
    END IF
    CALL save_line_states(system, ErrStat, ErrMsg)
    IF (ErrStat /= CD_SYSTEM_OK) RETURN
    converged = .TRUE.
    IF (.NOT. (ALLOCATED(system%line_off) .AND. ALLOCATED(system%line_stat) .AND. &
               ALLOCATED(system%line_iter) .AND. ALLOCATED(system%line_converged) .AND. &
               ALLOCATED(system%line_stalled) .AND. ALLOCATED(system%line_msg))) THEN
      CALL restore_failed_step(system, CD_MODEL_SOLVEFAIL, 'per-line step workspace is not initialized', &
                               converged, stalled, n_iter, ErrStat, ErrMsg)
      RETURN
    END IF
    ! Stage every prescribed boundary serially. The coupled map may alias shared
    ! points, but each destination is a different line-owned workspace.
    DO i = 1, system%n_lines
      lo = system%line_off(i)
      hi = system%line_off(i + 1) - 1
      nc = hi - lo + 1
      IF (.NOT. (ALLOCATED(system%lines(i)%q_prescribed_work) .AND. &
                 ALLOCATED(system%lines(i)%v_prescribed_work) .AND. &
                 ALLOCATED(system%lines(i)%a_prescribed_work))) THEN
        CALL restore_failed_step(system, CD_MODEL_SOLVEFAIL, 'line prescribed-motion workspace is not initialized', &
                                 converged, stalled, n_iter, ErrStat, ErrMsg)
        RETURN
      END IF
      system%lines(i)%q_prescribed_work = system%lines(i)%q
      system%lines(i)%v_prescribed_work = system%lines(i)%v
      system%lines(i)%a_prescribed_work = system%lines(i)%a
      DO j = 1, nc
        line_dof = system%lines(i)%fixed_dofs(j)
        sys_dof = system%coupled_dof_map(lo + j - 1)
        system%lines(i)%q_prescribed_work(line_dof) = q_coupled(sys_dof)
        system%lines(i)%v_prescribed_work(line_dof) = v_coupled(sys_dof)
        system%lines(i)%a_prescribed_work(line_dof) = a_coupled(sys_dof)
      END DO
    END DO

    ! Line models own disjoint state and Newton workspaces. Workers stage results;
    ! the following serial pass selects the first error and reduces flags in deck order.
    n_team = line_team_size(system)
    IF (n_team > 1) THEN
      !$OMP PARALLEL DEFAULT(SHARED) PRIVATE(i) NUM_THREADS(n_team)
      CALL CD_Fatal_Thread_Init() ! this thread can report its own stack overflow
      ! DYNAMIC: a line that is sub-stepped (CD_Step_Model) costs several of its plain steps, so the
      ! lines take unequal times; each line's result does not depend on the thread that steps it
      !$OMP DO SCHEDULE(DYNAMIC)
      DO i = 1, system%n_lines
        CALL step_line(i)
      END DO
      !$OMP END DO
      !$OMP END PARALLEL
    ELSE
      ! one thread: the same loop without entering a parallel region
      CALL CD_Fatal_Thread_Init()
      DO i = 1, system%n_lines
        CALL step_line(i)
      END DO
    END IF
    DO i = 1, system%n_lines
      IF (system%line_stat(i) /= CD_MODEL_OK) THEN
        CALL restore_failed_step(system, system%line_stat(i), 'line step failed: '//TRIM(system%line_msg(i)), &
                                 converged, stalled, n_iter, &
                                 ErrStat, ErrMsg)
        RETURN
      END IF
      converged = converged .AND. system%line_converged(i)
      stalled = stalled .OR. system%line_stalled(i)
      n_iter = MAX(n_iter, system%line_iter(i))
    END DO

    ! A soft stall (a line did not converge, but no hard solve error): roll back to t and
    ! retry as two interpolated half-steps, deeper if a half-step also stalls. See the
    ! TRANSPARENT-fallback contract in the header: this frame keeps its own flat snapshot
    ! of the t state (the recursive halves overwrite the lines' shared rollback buffers),
    ! and on ANY failure to complete the full interval converged it restores that snapshot
    ! -- so a mid-interval state can never leak.
    IF (.NOT. converged .AND. depth < MAX_SUBDIV) THEN
      ! the system's own count, outside the lines' parallel region: one thread steps a system
      system%n_fallback_entries = system%n_fallback_entries + 1
      ! Capture the coupled motion at the START of the interval only on the rare subdivision
      ! path. The common converged path must not heap-allocate just to prepare an unused retry.
      ALLOCATE (q0(SIZE(q_coupled)), v0(SIZE(q_coupled)), a0(SIZE(q_coupled)))
      q0 = q_coupled; v0 = v_coupled; a0 = a_coupled
      lo = 1
      DO i = 1, system%n_lines
        nc = CD_Model_NCoupledDOF(system%lines(i), es, em)
        IF (es /= CD_MODEL_OK) THEN
          CALL restore_failed_step(system, es, 'line coupled-DOF query failed during subdivision retry: '//TRIM(em), &
                                   converged, stalled, n_iter, ErrStat, ErrMsg)
          RETURN
        END IF
        DO j = 1, nc
          line_dof = system%lines(i)%fixed_dofs(j)
          sys_dof = system%coupled_dof_map(lo + j - 1)
          q0(sys_dof) = system%lines(i)%q_rollback(line_dof)
          v0(sys_dof) = system%lines(i)%v_rollback(line_dof)
          a0(sys_dof) = system%lines(i)%a_rollback(line_dof)
        END DO
        lo = lo + nc
      END DO
      CALL restore_line_states(system)
      ! The frame snapshot covers every state a line step commits: the kinematics, the
      ! viscoelastic / Syrope history variables and the lengths and rates the committed state
      ! was reached with (active line control: a converged first half commits the new
      ! lengths, so a restore without them would re-run the full step unblended).
      ntot = 0
      nve = 0
      nsy = 0
      nfr = 0
      nel = 0
      DO i = 1, system%n_lines
        ntot = ntot + SIZE(system%lines(i)%q)
        nel = nel + SIZE(system%lines(i)%l0_c)
        IF (system%lines(i)%has_viscoelastic) nve = nve + SIZE(system%lines(i)%ve_dl_1)
        IF (system%lines(i)%has_syrope) nsy = nsy + SIZE(system%lines(i)%syrope_slow)
        IF (CD_Model_Has_Friction(system%lines(i))) nfr = nfr + SIZE(system%lines(i)%fr_anchor, 2)
      END DO
      ALLOCATE (qs(ntot), vs(ntot), as(ntot), dl1s(nve), slows(nsy), tmaxs(nsy), frs(2, nfr), &
                hmaxs(system%n_lines), subs(system%n_lines), l0cs(nel), l0dcs(nel), vivs(ntot))
      vivs = CD_ZERO
      lo = 1
      lo_ve = 1
      lo_sy = 1
      lo_fr = 1
      lo_el = 1
      DO i = 1, system%n_lines
        hi = lo + SIZE(system%lines(i)%q) - 1
        qs(lo:hi) = system%lines(i)%q
        vs(lo:hi) = system%lines(i)%v
        as(lo:hi) = system%lines(i)%a
        ! the run audit's largest solver step and the sub-stepping diagnostics restore with the
        ! states, so the halves of a fallback that does not complete leave no trace
        hmaxs(i) = system%lines(i)%audit_hmax
        subs(i) = system%lines(i)%sub_stats
        IF (system%lines(i)%has_viv) CALL pack_viv(system%lines(i), vivs(lo:hi))
        lo = hi + 1
        ne = SIZE(system%lines(i)%l0_c)
        l0cs(lo_el:lo_el + ne - 1) = system%lines(i)%l0_c
        l0dcs(lo_el:lo_el + ne - 1) = system%lines(i)%l0_dot_c
        lo_el = lo_el + ne
        IF (CD_Model_Has_Friction(system%lines(i))) THEN
          ne = SIZE(system%lines(i)%fr_anchor, 2)
          frs(:, lo_fr:lo_fr + ne - 1) = system%lines(i)%fr_anchor
          lo_fr = lo_fr + ne
        END IF
        IF (system%lines(i)%has_viscoelastic) THEN
          ne = SIZE(system%lines(i)%ve_dl_1)
          dl1s(lo_ve:lo_ve + ne - 1) = system%lines(i)%ve_dl_1
          lo_ve = lo_ve + ne
        END IF
        IF (system%lines(i)%has_syrope) THEN
          ne = SIZE(system%lines(i)%syrope_slow)
          slows(lo_sy:lo_sy + ne - 1) = system%lines(i)%syrope_slow
          tmaxs(lo_sy:lo_sy + ne - 1) = system%lines(i)%syrope_tmax
          lo_sy = lo_sy + ne
        END IF
      END DO
      ALLOCATE (qm(SIZE(q_coupled)), vm(SIZE(q_coupled)), am(SIZE(q_coupled)))
      qm = 0.5_wp*(q0 + q_coupled)
      vm = 0.5_wp*(v0 + v_coupled)
      am = 0.5_wp*(a0 + a_coupled)
      CALL CD_Step_System(system, 0.5_wp*dt, qm, vm, am, converged, stalled, n_iter, ErrStat, ErrMsg, depth + 1)
      IF (converged .AND. ErrStat == CD_SYSTEM_OK) THEN
        CALL CD_Step_System(system, 0.5_wp*dt, q_coupled, v_coupled, a_coupled, conv2, stall2, iter2, &
                            ErrStat, ErrMsg, depth + 1)
        converged = converged .AND. conv2
        stalled = stalled .OR. stall2
        n_iter = MAX(n_iter, iter2)
      END IF
      IF (.NOT. (converged .AND. ErrStat == CD_SYSTEM_OK)) THEN
        ! The fallback could not complete the interval: restore the entry state exactly
        ! (a hard error inside a half already rolled back only to THAT half's start).
        lo = 1
        lo_ve = 1
        lo_sy = 1
        lo_fr = 1
        lo_el = 1
        DO i = 1, system%n_lines
          hi = lo + SIZE(system%lines(i)%q) - 1
          system%lines(i)%q = qs(lo:hi)
          system%lines(i)%v = vs(lo:hi)
          system%lines(i)%a = as(lo:hi)
          system%lines(i)%audit_hmax = hmaxs(i)
          system%lines(i)%sub_stats = subs(i)
          IF (system%lines(i)%has_viv) CALL unpack_viv(system%lines(i), vivs(lo:hi))
          lo = hi + 1
          ne = SIZE(system%lines(i)%l0_c)
          system%lines(i)%l0_c = l0cs(lo_el:lo_el + ne - 1)
          system%lines(i)%l0_dot_c = l0dcs(lo_el:lo_el + ne - 1)
          lo_el = lo_el + ne
          IF (CD_Model_Has_Friction(system%lines(i))) THEN
            ne = SIZE(system%lines(i)%fr_anchor, 2)
            system%lines(i)%fr_anchor = frs(:, lo_fr:lo_fr + ne - 1)
            lo_fr = lo_fr + ne
          END IF
          IF (system%lines(i)%has_viscoelastic) THEN
            ne = SIZE(system%lines(i)%ve_dl_1)
            system%lines(i)%ve_dl_1 = dl1s(lo_ve:lo_ve + ne - 1)
            lo_ve = lo_ve + ne
          END IF
          IF (system%lines(i)%has_syrope) THEN
            ne = SIZE(system%lines(i)%syrope_slow)
            system%lines(i)%syrope_slow = slows(lo_sy:lo_sy + ne - 1)
            system%lines(i)%syrope_tmax = tmaxs(lo_sy:lo_sy + ne - 1)
            lo_sy = lo_sy + ne
          END IF
        END DO
        ! A hard error is reported at the restored t state, matching the plain step's
        ! restore_failed_step contract.
        IF (ErrStat /= CD_SYSTEM_OK) RETURN
        ! Soft failure at the depth floor: re-run the plain full-dt step (the floor depth
        ! suppresses further subdivision) so the committed best-effort t+dt state and the
        ! converged/stalled/n_iter flags are bit-identical to the no-fallback behavior.
        CALL CD_Step_System(system, dt, q_coupled, v_coupled, a_coupled, converged, stalled, n_iter, &
                            ErrStat, ErrMsg, MAX_SUBDIV)
        RETURN
      END IF
    END IF
    ErrStat = CD_SYSTEM_OK
    ErrMsg = ''

  CONTAINS

    SUBROUTINE step_line(il)
      !! Step line il with its staged prescribed motion. The halves of a stall recovery
      !! (0 < depth < MAX_SUBDIV) take their steps as given, as the rungs of
      !! CD_Step_Model_Recovering do: no rotation- and snap-resolved sub-steps of sub-steps. The
      !! plain full-dt rerun at the depth floor (depth = MAX_SUBDIV) steps every line as the
      !! nominal step (depth 0) does, so its result is that of the step without the fallback; the
      !! junction step (JUNCTION_NO_SUBDIV = MAX_SUBDIV) likewise, its armed lines being taken as
      !! given by CD_Step_Model itself.
      INTEGER, INTENT(IN) :: il
      CALL CD_Step_Model(system%lines(il), dt, system%line_converged(il), system%line_stalled(il), &
                         system%line_iter(il), system%line_stat(il), system%line_msg(il), &
                         prescribed_q=system%lines(il)%q_prescribed_work, &
                         prescribed_v=system%lines(il)%v_prescribed_work, &
                         prescribed_a=system%lines(il)%a_prescribed_work, &
                         as_given=depth > 0 .AND. depth < MAX_SUBDIV)
    END SUBROUTINE step_line
  END SUBROUTINE CD_Step_System

  SUBROUTINE CD_Step_System_Junction(system, dt, q_coupled, v_coupled, a_coupled, active, warm, loads, kmat, &
                                     converged, stalled, n_iter, ErrStat, ErrMsg, refresh, load_abs, levels, &
                                     level_dofs)
    !! One line step of the monolithic junction scheme: every line is stepped (no subdivision)
    !! with the trial end motion (q, v, a at t_{n+1}) of the coupled DOFs, and returns, summed
    !! over the lines per coupled DOF, the alpha-level end loads (the force the lines exert on
    !! the points, loads = -R_E) and the condensed dynamic end tangent kmat = dR_E/dq_{n+1}
    !! (free line DOFs eliminated) over the junction DOFs flagged in active. warm re-solves the
    !! same step from the previous solve (the caller rewinds the lines first with
    !! CD_System_Junction_Rewind). A step that does not converge returns converged = .FALSE.
    !! with the lines at their best attempt; the caller rewinds.
    TYPE(CD_SystemType), INTENT(INOUT) :: system
    REAL(wp), INTENT(IN) :: dt
    REAL(wp), INTENT(IN) :: q_coupled(:), v_coupled(:), a_coupled(:)
    LOGICAL, INTENT(IN) :: active(:), warm
    REAL(wp), INTENT(OUT) :: loads(:), kmat(:, :)
    LOGICAL, INTENT(OUT) :: converged, stalled
    INTEGER, INTENT(OUT) :: n_iter, ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    !! refresh = .FALSE. lets every line keep a valid condensed tangent of an earlier solve
    LOGICAL, INTENT(IN), OPTIONAL :: refresh
    !! load_abs: per coupled DOF, the sum of the magnitudes of the line reactions (the force
    !! scale of a junction whose line loads cancel)
    REAL(wp), INTENT(OUT), OPTIONAL :: load_abs(:)
    !! levels = [beta, gamma, alpha_m] of the objects driving the coupled DOFs (their Newmark and
    !! inertia level at the line ends, CD_Set_Model_EndQuery); absent: the lines' own
    REAL(wp), INTENT(IN), OPTIONAL :: levels(3)
    !! level_dofs (per coupled DOF): the coupled DOFs that take levels (all when absent)
    LOGICAL, INTENT(IN), OPTIONAL :: level_dofs(:)
    INTEGER :: i, j, k, lo, nc, nf
    LOGICAL :: valid, fresh
    LOGICAL, ALLOCATABLE :: act(:), lev(:), armed(:)
    REAL(wp), ALLOCATABLE :: r(:), kl(:, :)

    loads = CD_ZERO
    kmat = CD_ZERO
    IF (PRESENT(load_abs)) load_abs = CD_ZERO
    converged = .FALSE.
    stalled = .FALSE.
    n_iter = 0
    ErrStat = CD_SYSTEM_OK
    ErrMsg = ''
    IF (SIZE(active) /= system%n_system_coupled_dof .OR. SIZE(loads) /= system%n_system_coupled_dof .OR. &
        SIZE(kmat, 1) /= system%n_system_coupled_dof .OR. SIZE(kmat, 2) /= system%n_system_coupled_dof) THEN
      CALL fail(ErrStat, ErrMsg, 'junction step: active/loads/kmat must match the system coupled DOFs')
      RETURN
    END IF
    fresh = .TRUE.
    IF (PRESENT(refresh)) fresh = refresh
    ! A line with no active junction DOF (both ends on fixed or anchored points) adds nothing to
    ! the junction loads and tangent: its end query stays unarmed, so CD_Step_Model sub-steps
    ! it as on any other route (its loads at the inactive DOFs are not returned). Every other
    ! line is armed and taken as given.
    ALLOCATE (armed(system%n_lines))
    DO i = 1, system%n_lines
      lo = system%line_off(i)
      nc = system%line_off(i + 1) - lo
      nf = SIZE(system%lines(i)%fixed_dofs)
      ALLOCATE (act(nf), lev(nf))
      act = .FALSE.
      lev = .TRUE.
      DO j = 1, MIN(nc, nf)
        act(j) = active(system%coupled_dof_map(lo + j - 1))
        IF (PRESENT(level_dofs)) lev(j) = level_dofs(system%coupled_dof_map(lo + j - 1))
      END DO
      armed(i) = ANY(act)
      IF (.NOT. armed(i)) THEN
        CALL CD_Set_Model_EndQuery(system%lines(i), .FALSE.)
      ELSE IF (PRESENT(levels)) THEN
        CALL CD_Set_Model_EndQuery(system%lines(i), .TRUE., act, warm, fresh, levels, lev)
      ELSE
        CALL CD_Set_Model_EndQuery(system%lines(i), .TRUE., act, warm, fresh)
      END IF
      DEALLOCATE (act, lev)
    END DO
    CALL CD_Step_System(system, dt, q_coupled, v_coupled, a_coupled, converged, stalled, n_iter, ErrStat, ErrMsg, &
                        JUNCTION_NO_SUBDIV)
    IF (ErrStat == CD_SYSTEM_OK .AND. converged) THEN
      DO i = 1, system%n_lines
        IF (.NOT. armed(i)) CYCLE
        lo = system%line_off(i)
        nc = system%line_off(i + 1) - lo
        nf = SIZE(system%lines(i)%fixed_dofs)
        ALLOCATE (r(nf), kl(nf, nf))
        CALL CD_Get_Model_EndQuery(system%lines(i), r, kl, valid)
        IF (.NOT. valid) converged = .FALSE.
        DO j = 1, MIN(nc, nf)
          loads(system%coupled_dof_map(lo + j - 1)) = loads(system%coupled_dof_map(lo + j - 1)) - r(j)
          IF (PRESENT(load_abs)) load_abs(system%coupled_dof_map(lo + j - 1)) = &
            load_abs(system%coupled_dof_map(lo + j - 1)) + ABS(r(j))
          DO k = 1, MIN(nc, nf)
            kmat(system%coupled_dof_map(lo + j - 1), system%coupled_dof_map(lo + k - 1)) = &
              kmat(system%coupled_dof_map(lo + j - 1), system%coupled_dof_map(lo + k - 1)) + kl(j, k)
          END DO
        END DO
        DEALLOCATE (r, kl)
      END DO
    END IF
    DO i = 1, system%n_lines
      CALL CD_Set_Model_EndQuery(system%lines(i), .FALSE.)
    END DO
  END SUBROUTINE CD_Step_System_Junction

  SUBROUTINE CD_System_Junction_Rewind(system)
    !! Return every line to the entry state of the last CD_Step_System call (its rollback
    !! snapshot), so the junction scheme can re-solve the same step with new end motion.
    TYPE(CD_SystemType), INTENT(INOUT) :: system
    CALL restore_line_states(system)
  END SUBROUTINE CD_System_Junction_Rewind

  SUBROUTINE CD_System_Point_Environment(point, point_velocity, force, effective_mass, ErrStat, ErrMsg)
    !! The lumped Morison load and effective mass (point mass plus added mass) of a Free/Connect
    !! point at the given state (point%q selects the wet/dry branch), as the dynamic-point step
    !! applies them.
    TYPE(CD_SystemPointType), INTENT(IN) :: point
    REAL(wp), INTENT(IN) :: point_velocity(3)
    REAL(wp), INTENT(OUT) :: force(3), effective_mass
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    CALL point_environment_force(point, point_velocity, force, effective_mass, ErrStat, ErrMsg)
  END SUBROUTINE CD_System_Point_Environment

  SUBROUTINE CD_System_Point_Seabed(system, point_index, q, v, in_contact, force, jac_q, jac_v, ErrStat, ErrMsg)
    !! Seabed contact load of system point point_index at position q and velocity v: the line
    !! nodes' normal contact law (CD_Model_Seabed_Point_Load) with the point's own stiffness
    !! seabed_k and damping seabed_c, against the floor of the first bound line that has a
    !! seabed, else of any line of the system (every line of a deck shares the deck's floor).
    !! jac_q = -d(force)/dq and jac_v = -d(force)/dv. in_contact is .FALSE., with every output
    !! exactly zero, for a point without a footprint, in a system without a seabed, or clear of
    !! the floor.
    TYPE(CD_SystemType), INTENT(IN) :: system
    INTEGER, INTENT(IN) :: point_index
    REAL(wp), INTENT(IN) :: q(3), v(3)
    LOGICAL, INTENT(OUT) :: in_contact
    REAL(wp), INTENT(OUT) :: force(3), jac_q(3, 3), jac_v(3, 3)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    INTEGER :: k, li, es
    CHARACTER(160) :: em

    in_contact = .FALSE.
    force = CD_ZERO
    jac_q = CD_ZERO
    jac_v = CD_ZERO
    ErrStat = CD_SYSTEM_OK
    ErrMsg = ''
    IF (.NOT. ALLOCATED(system%points) .OR. .NOT. ALLOCATED(system%bindings)) RETURN
    IF (point_index < 1 .OR. point_index > SIZE(system%points)) RETURN
    IF (.NOT. (system%points(point_index)%seabed_k > CD_ZERO .OR. system%points(point_index)%seabed_c > CD_ZERO)) &
      RETURN
    IF (.NOT. ALLOCATED(system%lines)) RETURN
    ! the floor of a bound line, or of any line of the system for a point whose lines have all
    ! been detached (a line failure): a clump left without lines still rests on the seabed
    li = 0
    DO k = 1, SIZE(system%bindings)
      IF (system%bindings(k)%point_id /= system%points(point_index)%id) CYCLE
      IF (system%bindings(k)%line_index < 1 .OR. system%bindings(k)%line_index > SIZE(system%lines)) CYCLE
      IF (.NOT. system%lines(system%bindings(k)%line_index)%has_seabed) CYCLE
      li = system%bindings(k)%line_index
      EXIT
    END DO
    IF (li == 0) THEN
      DO k = 1, SIZE(system%lines)
        IF (.NOT. system%lines(k)%has_seabed) CYCLE
        li = k
        EXIT
      END DO
    END IF
    IF (li == 0) RETURN
    CALL CD_Model_Seabed_Point_Load(system%lines(li), q, v, system%points(point_index)%seabed_k, &
                                    system%points(point_index)%seabed_c, in_contact, force, jac_q, jac_v, es, em)
    IF (es /= CD_MODEL_OK) THEN
      in_contact = .FALSE.
      force = CD_ZERO
      jac_q = CD_ZERO
      jac_v = CD_ZERO
      WRITE (ErrMsg, '(A,I0,A)') 'CableDyn_System: seabed contact of point ', system%points(point_index)%id, &
        ' failed: '//TRIM(em)
      ErrStat = system_status_from_model(es)
    END IF
  END SUBROUTINE CD_System_Point_Seabed

  INTEGER FUNCTION CD_System_Point_Base(system, point_index) RESULT(base)
    !! Zero-based coupled-DOF offset of system point point_index (-1 when unbound).
    TYPE(CD_SystemType), INTENT(IN) :: system
    INTEGER, INTENT(IN) :: point_index
    base = point_coupled_base(system, point_index)
  END FUNCTION CD_System_Point_Base

  SUBROUTINE CD_Step_System_DynamicPoints(system, dt, converged, stalled, n_iter, ErrStat, ErrMsg, integrate)
    !! Advance Free/Connect points from summed endpoint loads, then step all
    !! attached lines with the updated point kinematics: explicit point
    !! integration around the implicit line step. Fixed/Coupled points remain prescribed.
    TYPE(CD_SystemType), INTENT(INOUT) :: system
    REAL(wp), INTENT(IN) :: dt
    LOGICAL, INTENT(OUT) :: converged, stalled
    INTEGER, INTENT(OUT) :: n_iter, ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    !! integrate (per system point): the points integrated here; every other point is prescribed
    !! by its stored state (for a caller that drives some Free points itself, such as Rigid6
    !! body attachments). Absent: the Free/Connect points.
    LOGICAL, INTENT(IN), OPTIONAL :: integrate(:)

    INTEGER :: p, base, es, k
    REAL(wp) :: ma_blk(3, 3), k_blk(3, 3), c_blk(3, 3), rhs3(3), kv_nbr(3)
    REAL(wp) :: sea_f(3), sea_k(3, 3), sea_c(3, 3)
    LOGICAL :: solve_ok, sea_contact
    LOGICAL, ALLOCATABLE :: integ(:)
    CHARACTER(1024) :: em

    converged = .FALSE.
    stalled = .FALSE.
    n_iter = 0
    IF (.NOT. system%initialized) THEN
      ErrStat = CD_SYSTEM_NOT_INITIALIZED
      ErrMsg = 'CableDyn_System: system is not initialized'
      RETURN
    END IF
    IF (.NOT. ALLOCATED(system%points)) THEN
      CALL fail(ErrStat, ErrMsg, 'dynamic-point step requires a point-initialized system')
      RETURN
    END IF
    IF (.NOT. CD_Is_Finite(dt) .OR. dt <= CD_ZERO) THEN
      CALL fail(ErrStat, ErrMsg, 'dt must be finite and positive')
      RETURN
    END IF
    ALLOCATE (integ(SIZE(system%points)))
    IF (PRESENT(integrate)) THEN
      IF (SIZE(integrate) /= SIZE(system%points)) THEN
        CALL fail(ErrStat, ErrMsg, 'dynamic-point step: integrate needs one entry per system point')
        RETURN
      END IF
      integ = integrate
    ELSE
      integ = system%points%point_type == CD_POINT_FREE .OR. system%points%point_type == CD_POINT_CONNECT
    END IF

    IF (.NOT. (ALLOCATED(system%q_work) .AND. ALLOCATED(system%v_work) .AND. &
               ALLOCATED(system%a_work) .AND. ALLOCATED(system%load_work) .AND. &
               ALLOCATED(system%point_force_work) .AND. ALLOCATED(system%point_mass_work) .AND. &
               ALLOCATED(system%point_rollback))) THEN
      CALL fail(ErrStat, ErrMsg, 'dynamic-point step requires initialized system workspace')
      RETURN
    END IF
    system%point_rollback = system%points
    ! Snapshot the line states up front so every failure path below (via
    ! restore_failed_dynamic_points) can roll the lines back to this step's entry state,
    ! including a failure after the prescribed-motion scatter.
    CALL save_line_states(system, es, em)
    IF (es /= CD_SYSTEM_OK) THEN
      system%points = system%point_rollback
      ErrStat = es
      ErrMsg = em
      RETURN
    END IF
    system%point_force_work = CD_ZERO
    system%point_mass_work = CD_ZERO
    CALL CD_Get_System_CoupledMotion(system, system%q_work, system%v_work, system%a_work, es, em)
    IF (es /= CD_SYSTEM_OK) THEN
      CALL restore_failed_dynamic_points(system, system%point_rollback, es, em, ErrStat, ErrMsg)
      RETURN
    END IF
    ! Override the prescribed (Coupled/Fixed) coupled DOFs with the host motion stored in
    ! system%points and scatter it back into the lines, so CD_Calc_System_CoupledLoads and the
    ! line step below carry THIS step's prescribed motion rather than the lines' previous-step
    ! endpoints. Free/Connect endpoints are integrated here, not prescribed, so they keep the
    ! value just read from the lines and are left untouched.
    DO p = 1, SIZE(system%points)
      IF (.NOT. system%points(p)%active) CYCLE
      base = point_coupled_base(system, p)
      IF (base < 0) CYCLE
      IF (integ(p)) CYCLE
      system%q_work(base + 1:base + 3) = system%points(p)%q
      system%v_work(base + 1:base + 3) = system%points(p)%v
      system%a_work(base + 1:base + 3) = system%points(p)%a
    END DO
    CALL CD_Update_System_CoupledMotion(system, system%q_work, system%v_work, system%a_work, es, em)
    IF (es /= CD_SYSTEM_OK) THEN
      CALL restore_failed_dynamic_points(system, system%point_rollback, es, em, ErrStat, ErrMsg)
      RETURN
    END IF
    CALL CD_Calc_System_CoupledLoads(system, system%load_work, es, em)
    IF (es /= CD_SYSTEM_OK) THEN
      CALL restore_failed_dynamic_points(system, system%point_rollback, es, em, ErrStat, ErrMsg)
      RETURN
    END IF

    ! The prescribed-motion scatter is undone just before the line step below: the
    ! Free/Connect integration first reads the attached end-node added-mass blocks at the
    ! SAME line configuration the summed loads were evaluated at.

    DO p = 1, SIZE(system%points)
      IF (.NOT. system%points(p)%active) CYCLE
      IF (integ(p)) THEN
        base = point_coupled_base(system, p)
        IF (base < 0) THEN
          CALL restore_failed_dynamic_points( &
            system, system%point_rollback, CD_SYSTEM_BADINPUT, &
            'CableDyn_System: Free/Connect point dynamic step requires a bound point', &
            ErrStat, ErrMsg)
          RETURN
        END IF
        IF (.NOT. (CD_Is_Finite(system%points(p)%mass) .AND. system%points(p)%mass >= CD_ZERO .AND. &
                   CD_Is_Finite(system%points(p)%line_mass_diag) .AND. &
                   system%points(p)%mass + system%points(p)%line_mass_diag > CD_ZERO)) THEN
          CALL restore_failed_dynamic_points( &
            system, system%point_rollback, CD_SYSTEM_BADINPUT, &
            'CableDyn_System: Free/Connect point dynamic step requires finite non-negative point mass '// &
            'with positive total (point + attached line end-node) mass', &
            ErrStat, ErrMsg)
          RETURN
        END IF
        CALL point_environment_force(system%points(p), system%v_work(base + 1:base + 3), &
                                     system%point_force_work(:, p), system%point_mass_work(p), ErrStat, ErrMsg)
        IF (ErrStat /= CD_SYSTEM_OK) THEN
          es = ErrStat
          em = ErrMsg
          CALL restore_failed_dynamic_points(system, system%point_rollback, es, em, ErrStat, ErrMsg)
          RETURN
        END IF
      END IF
    END DO

    DO p = 1, SIZE(system%points)
      IF (.NOT. system%points(p)%active) CYCLE
      base = point_coupled_base(system, p)
      IF (integ(p)) THEN
        ! Linearly implicit point update. The summed coupled load L is the exact reaction
        ! at the step-start line state with the lagged endpoint acceleration a_lag. The
        ! attached end nodes' OWN blocks are advanced implicitly:
        !   M_e = line_mass_diag*I + Ma_cc   (structural diagonal + Morison added-mass self block),
        !   K_e, C_e                         (end-element elastic tangent and axial-damping self blocks),
        ! with implicit-Euler kinematics v+ = v + dt*a+, q+ = q + dt*v+ (so q+ - q =
        ! dt*v + dt^2*a+ and v+ - v = dt*a+), and each end element's other node carried
        ! along at its step-start velocity v_o (the cross block -K_e), giving
        !   (m_eff*I + M_e + dt*C_e + dt^2*K_e) a+ = L + F + F_env + M_e*a_lag
        !                                            - dt*sum K_e (v - v_o).
        ! Springing against v alone (the neighbours held in place) brakes the point every
        ! step on a stiff chain, whose end segment then moves with the point: a chain
        ! through Free points lagged the body it hangs from.
        ! Moving M_e implicitly removes the lagged-inertia amplification of a light point
        ! under large attached added mass (independent of dt); K_e and C_e remove the
        ! explicit end-segment stiffness/damping limit dt < 2/sqrt(k/m). The neighbour
        ! cross terms (m/6, added-mass and stiffness coupling to the first interior node)
        ! stay at the step-start state inside L; the dissipative implicit-Euler point
        ! kinematics keep that one-step lag from exciting the stiff end-segment mode.
        CALL point_line_end_blocks(system, p, ma_blk, k_blk, c_blk, kv_nbr, es, em)
        IF (es /= CD_SYSTEM_OK) THEN
          CALL restore_failed_dynamic_points(system, system%point_rollback, es, em, ErrStat, ErrMsg)
          RETURN
        END IF
        DO k = 1, 3
          ma_blk(k, k) = ma_blk(k, k) + system%points(p)%line_mass_diag
        END DO
        rhs3 = system%load_work(base + 1:base + 3) + system%points(p)%force + system%point_force_work(:, p) + &
               MATMUL(ma_blk, system%a_work(base + 1:base + 3)) - &
               dt*(MATMUL(k_blk, system%v_work(base + 1:base + 3)) - kv_nbr)
        ma_blk = ma_blk + dt*c_blk + dt*dt*k_blk
        ! The point's own seabed contact, linearised about the step start like the end
        ! blocks: F(q+, v+) = F - K (dt v + dt^2 a+) - C dt a+ (K = -dF/dq, C = -dF/dv), so
        ! a light point on a stiff footprint does not bounce. Nothing is added off the floor.
        CALL CD_System_Point_Seabed(system, p, system%q_work(base + 1:base + 3), system%v_work(base + 1:base + 3), &
                                    sea_contact, sea_f, sea_k, sea_c, es, em)
        IF (es /= CD_SYSTEM_OK) THEN
          CALL restore_failed_dynamic_points(system, system%point_rollback, es, em, ErrStat, ErrMsg)
          RETURN
        END IF
        IF (sea_contact) THEN
          rhs3 = rhs3 + sea_f - dt*MATMUL(sea_k, system%v_work(base + 1:base + 3))
          ma_blk = ma_blk + dt*sea_c + dt*dt*sea_k
        END IF
        DO k = 1, 3
          ma_blk(k, k) = ma_blk(k, k) + system%point_mass_work(p)
        END DO
        CALL solve_spd3(ma_blk, rhs3, system%points(p)%a, solve_ok)
        IF (solve_ok) THEN
          system%points(p)%v = system%v_work(base + 1:base + 3) + dt*system%points(p)%a
          system%points(p)%q = system%q_work(base + 1:base + 3) + dt*system%points(p)%v
          solve_ok = CD_All_Finite(system%points(p)%q) .AND. CD_All_Finite(system%points(p)%v)
        END IF
        IF (.NOT. solve_ok) THEN
          WRITE (em, '(A,I0,A)') 'CableDyn_System: Free/Connect point ', system%points(p)%id, &
            ' update failed: singular effective mass or non-finite kinematics'
          CALL restore_failed_dynamic_points(system, system%point_rollback, CD_SYSTEM_SOLVEFAIL, em, &
                                             ErrStat, ErrMsg)
          RETURN
        END IF
        system%q_work(base + 1:base + 3) = system%points(p)%q
        system%v_work(base + 1:base + 3) = system%points(p)%v
        system%a_work(base + 1:base + 3) = system%points(p)%a
      ELSE
        IF (base >= 0) THEN
          system%points(p)%q = system%q_work(base + 1:base + 3)
          system%points(p)%v = system%v_work(base + 1:base + 3)
          system%points(p)%a = system%a_work(base + 1:base + 3)
        END IF
      END IF
    END DO

    ! Undo the prescribed-motion scatter now that the endpoint loads and end-node blocks are
    ! read. The explicit Free/Connect integration above does not write the line state, and
    ! CD_Step_System re-applies the (free-point-integrated) q_work itself. Restoring to the
    ! step-entry snapshot means CD_Step_System takes ITS rollback snapshot from the entry
    ! state, so a line-step failure rolls the lines back consistently with the point rollback
    ! instead of leaving them at the prescribed-motion scatter.
    CALL restore_line_states(system)

    CALL CD_Step_System(system, dt, system%q_work, system%v_work, system%a_work, converged, stalled, n_iter, &
                        ErrStat, ErrMsg)
    IF (ErrStat /= CD_SYSTEM_OK) system%points = system%point_rollback
  END SUBROUTINE CD_Step_System_DynamicPoints

  SUBROUTINE point_line_end_blocks(system, point_index, ma_block, k_block, c_block, kv_neighbour, ErrStat, ErrMsg)
    !! Sum the attached end nodes' Morison added-mass self blocks over every line end
    !! bound to one point, together with the end-element stiffness and axial-damping
    !! self blocks and the stiffness-weighted neighbour velocity sum K_e v_o, at the
    !! lines' current configuration.
    TYPE(CD_SystemType), INTENT(IN) :: system
    INTEGER, INTENT(IN) :: point_index
    REAL(wp), INTENT(OUT) :: ma_block(3, 3), k_block(3, 3), c_block(3, 3), kv_neighbour(3)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    INTEGER :: k, es
    REAL(wp) :: blk(3, 3), kb(3, 3), cb(3, 3), kv(3)
    CHARACTER(1024) :: em
    ErrStat = CD_SYSTEM_OK
    ErrMsg = ''
    ma_block = CD_ZERO
    k_block = CD_ZERO
    c_block = CD_ZERO
    kv_neighbour = CD_ZERO
    IF (.NOT. ALLOCATED(system%bindings)) RETURN
    DO k = 1, SIZE(system%bindings)
      IF (system%bindings(k)%point_id /= system%points(point_index)%id) CYCLE
      CALL CD_Get_Model_EndNodeAddedMass(system%lines(system%bindings(k)%line_index), &
                                         system%bindings(k)%line_end, blk, es, em)
      IF (es == CD_MODEL_OK) CALL CD_Get_Model_EndNodeTangent(system%lines(system%bindings(k)%line_index), &
                                                              system%bindings(k)%line_end, kb, cb, es, em, kv)
      IF (es /= CD_MODEL_OK) THEN
        CALL fail(ErrStat, ErrMsg, 'end-node implicit blocks failed: '//TRIM(em))
        ma_block = CD_ZERO
        k_block = CD_ZERO
        c_block = CD_ZERO
        kv_neighbour = CD_ZERO
        RETURN
      END IF
      ma_block = ma_block + blk
      k_block = k_block + kb
      c_block = c_block + cb
      kv_neighbour = kv_neighbour + kv
    END DO
  END SUBROUTINE point_line_end_blocks

  PURE SUBROUTINE solve_spd3(A, b, x, ok)
    !! Solve a 3x3 symmetric positive-definite system by Cholesky factorization. ok is
    !! false (x zeroed) when a pivot is not positive or the solution is non-finite.
    REAL(wp), INTENT(IN) :: A(3, 3), b(3)
    REAL(wp), INTENT(OUT) :: x(3)
    LOGICAL, INTENT(OUT) :: ok
    REAL(wp) :: L(3, 3), y(3), d
    INTEGER :: i, j
    x = CD_ZERO
    y = CD_ZERO
    L = CD_ZERO
    ok = .FALSE.
    DO j = 1, 3
      d = A(j, j) - SUM(L(j, 1:j - 1)**2)
      IF (.NOT. (CD_Is_Finite(d) .AND. d > CD_ZERO)) RETURN
      L(j, j) = SQRT(d)
      DO i = j + 1, 3
        L(i, j) = (A(i, j) - SUM(L(i, 1:j - 1)*L(j, 1:j - 1)))/L(j, j)
      END DO
    END DO
    DO i = 1, 3
      y(i) = (b(i) - SUM(L(i, 1:i - 1)*y(1:i - 1)))/L(i, i)
    END DO
    DO i = 3, 1, -1
      x(i) = (y(i) - SUM(L(i + 1:3, i)*x(i + 1:3)))/L(i, i)
    END DO
    ok = CD_All_Finite(x)
    IF (.NOT. ok) x = CD_ZERO
  END SUBROUTINE solve_spd3

  SUBROUTINE CD_Update_System_Line_SegmentLength(system, line_index, elem, l0_new, l0_dot, ErrStat, ErrMsg, &
                                                 restored)
    !! Active line control at the system level: update one element's unstretched
    !! length/rate on a contained line (CD_Update_Model_SegmentLength does the model
    !! work) and RECOMPUTE the end-node consistent-mass diagonal shares of every
    !! point bound to that line -- the implicit share a Free/Connect point carries
    !! (see the massless-point step) reads rho_a*l0/3, so a length change on an end
    !! element moves it. restored = .TRUE. marks the length and rate as the committed
    !! state's (a checkpoint restart re-applying the restored command).
    TYPE(CD_SystemType), INTENT(INOUT) :: system
    INTEGER, INTENT(IN) :: line_index, elem
    REAL(wp), INTENT(IN) :: l0_new, l0_dot
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    LOGICAL, INTENT(IN), OPTIONAL :: restored

    INTEGER :: k, i, kb, es
    REAL(wp) :: md
    CHARACTER(1024) :: em

    CALL validate_line_index(system, line_index, ErrStat, ErrMsg)
    IF (ErrStat /= CD_SYSTEM_OK) RETURN
    ! Validate every end-node mass-diagonal query the recompute below will issue
    ! BEFORE the model mutates: the query's failure modes are structural (slot and
    ! initialization), not length-dependent, so a successful model update is always
    ! followed by a successful recompute and the update stays atomic.
    IF (ALLOCATED(system%points) .AND. ALLOCATED(system%bindings)) THEN
      DO k = 1, SIZE(system%bindings)
        IF (system%bindings(k)%line_index /= line_index) CYCLE
        i = find_point_index(system%points, system%bindings(k)%point_id)
        IF (i < 1) CYCLE
        IF (system%points(i)%point_type /= CD_POINT_FREE .AND. &
            system%points(i)%point_type /= CD_POINT_CONNECT) CYCLE
        DO kb = 1, SIZE(system%bindings)
          IF (system%bindings(kb)%point_id /= system%points(i)%id) CYCLE
          CALL CD_Get_Model_EndNodeMassDiag(system%lines(system%bindings(kb)%line_index), &
                                            system%bindings(kb)%line_end, md, es, em)
          IF (es /= CD_MODEL_OK) THEN
            CALL fail(ErrStat, ErrMsg, 'end-node mass-diagonal recompute failed: '//TRIM(em))
            RETURN
          END IF
        END DO
      END DO
    END IF
    CALL CD_Update_Model_SegmentLength(system%lines(line_index), elem, l0_new, l0_dot, es, em, restored=restored)
    IF (es /= CD_MODEL_OK) THEN
      CALL fail(ErrStat, ErrMsg, 'segment-length update failed: '//TRIM(em))
      RETURN
    END IF
    IF (.NOT. (ALLOCATED(system%points) .AND. ALLOCATED(system%bindings))) RETURN
    DO k = 1, SIZE(system%bindings)
      IF (system%bindings(k)%line_index /= line_index) CYCLE
      i = find_point_index(system%points, system%bindings(k)%point_id)
      IF (i < 1) CYCLE
      IF (system%points(i)%point_type /= CD_POINT_FREE .AND. &
          system%points(i)%point_type /= CD_POINT_CONNECT) CYCLE
      CALL recompute_point_line_mass_diag(system, i, ErrStat, ErrMsg)
      IF (ErrStat /= CD_SYSTEM_OK) RETURN
    END DO
  END SUBROUTINE CD_Update_System_Line_SegmentLength

  SUBROUTINE CD_Save_System_Line_Control(system, line_index, saved, ErrStat, ErrMsg)
    !! Save what CD_Update_System_Line_SegmentLength writes on one contained line
    !! (CD_Save_Model_Control), for CD_Restore_System_Line_Control.
    TYPE(CD_SystemType), INTENT(IN) :: system
    INTEGER, INTENT(IN) :: line_index
    TYPE(CD_ModelControlSaveType), INTENT(INOUT) :: saved
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    CALL validate_line_index(system, line_index, ErrStat, ErrMsg)
    IF (ErrStat /= CD_SYSTEM_OK) RETURN
    CALL CD_Save_Model_Control(system%lines(line_index), saved)
  END SUBROUTINE CD_Save_System_Line_Control

  SUBROUTINE CD_Restore_System_Line_Control(system, line_index, saved, ErrStat, ErrMsg)
    !! Take one contained line back to what CD_Save_System_Line_Control saved, bit for bit,
    !! and re-accumulate the end-node mass-diagonal shares of the Free/Connect points bound to
    !! it from the restored lengths (the accumulation the update and initialisation perform).
    TYPE(CD_SystemType), INTENT(INOUT) :: system
    INTEGER, INTENT(IN) :: line_index
    TYPE(CD_ModelControlSaveType), INTENT(IN) :: saved
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    INTEGER :: k, i, es
    CHARACTER(240) :: em
    CALL validate_line_index(system, line_index, ErrStat, ErrMsg)
    IF (ErrStat /= CD_SYSTEM_OK) RETURN
    CALL CD_Restore_Model_Control(system%lines(line_index), saved, es, em)
    IF (es /= CD_MODEL_OK) THEN
      CALL fail(ErrStat, ErrMsg, TRIM(em))
      RETURN
    END IF
    IF (.NOT. (ALLOCATED(system%points) .AND. ALLOCATED(system%bindings))) RETURN
    DO k = 1, SIZE(system%bindings)
      IF (system%bindings(k)%line_index /= line_index) CYCLE
      i = find_point_index(system%points, system%bindings(k)%point_id)
      IF (i < 1) CYCLE
      IF (system%points(i)%point_type /= CD_POINT_FREE .AND. &
          system%points(i)%point_type /= CD_POINT_CONNECT) CYCLE
      CALL recompute_point_line_mass_diag(system, i, ErrStat, ErrMsg)
      IF (ErrStat /= CD_SYSTEM_OK) RETURN
    END DO
  END SUBROUTINE CD_Restore_System_Line_Control

  SUBROUTINE recompute_point_line_mass_diag(system, point_index, ErrStat, ErrMsg)
    !! Re-accumulate one point's attached end-node consistent-mass diagonal share
    !! from its CURRENT bindings (the same accumulation init performs).
    TYPE(CD_SystemType), INTENT(INOUT) :: system
    INTEGER, INTENT(IN) :: point_index
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    INTEGER :: k, es
    REAL(wp) :: md
    CHARACTER(1024) :: em
    ErrStat = CD_SYSTEM_OK
    ErrMsg = ''
    system%points(point_index)%line_mass_diag = CD_ZERO
    DO k = 1, SIZE(system%bindings)
      IF (system%bindings(k)%point_id /= system%points(point_index)%id) CYCLE
      CALL CD_Get_Model_EndNodeMassDiag(system%lines(system%bindings(k)%line_index), &
                                        system%bindings(k)%line_end, md, es, em)
      IF (es /= CD_MODEL_OK) THEN
        CALL fail(ErrStat, ErrMsg, 'end-node mass-diagonal recompute failed: '//TRIM(em))
        RETURN
      END IF
      system%points(point_index)%line_mass_diag = system%points(point_index)%line_mass_diag + md
    END DO
  END SUBROUTINE recompute_point_line_mass_diag

  SUBROUTINE CD_Detach_System_LineEnds(system, fail_point_id, line_indices, reserve_point_id, ErrStat, ErrMsg)
    !! Line-failure detach (the MoorDyn DetachLines semantics on the reserve-point
    !! pre-allocation): move the listed lines' ends bound to fail_point_id onto the
    !! inactive reserve point, activate it at the failing point's committed
    !! kinematics, and rewire the exchange map entries for exactly those line-end
    !! slots. Every OTHER point's coupled block is init-frozen (point_dof_base), so
    !! the exchange layout, mirror extents, and checkpoint layout are unchanged.
    !! The end-node consistent-mass diagonal shares of both points are recomputed
    !! from the rewired bindings.
    TYPE(CD_SystemType), INTENT(INOUT) :: system
    INTEGER, INTENT(IN) :: fail_point_id
    INTEGER, INTENT(IN) :: line_indices(:)
    INTEGER, INTENT(IN) :: reserve_point_id
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg

    INTEGER :: i, k, pf, pr, es, local_base, e, nmoved
    REAL(wp) :: md
    CHARACTER(1024) :: em

    ErrStat = CD_SYSTEM_OK
    ErrMsg = ''
    IF (.NOT. system%initialized) THEN
      ErrStat = CD_SYSTEM_NOT_INITIALIZED
      ErrMsg = 'CableDyn_System: system is not initialized'
      RETURN
    END IF
    IF (.NOT. (ALLOCATED(system%points) .AND. ALLOCATED(system%bindings) .AND. &
               ALLOCATED(system%point_dof_base) .AND. ALLOCATED(system%coupled_dof_map))) THEN
      CALL fail(ErrStat, ErrMsg, 'detach requires a point-initialized system with frozen DOF bases')
      RETURN
    END IF
    IF (SIZE(line_indices) < 1) THEN
      CALL fail(ErrStat, ErrMsg, 'detach requires at least one line index')
      RETURN
    END IF
    pf = find_point_index(system%points, fail_point_id)
    pr = find_point_index(system%points, reserve_point_id)
    IF (pf < 1 .OR. pr < 1) THEN
      CALL fail(ErrStat, ErrMsg, 'detach references an unknown point id')
      RETURN
    END IF
    IF (system%points(pr)%active .OR. system%points(pr)%point_type /= CD_POINT_FREE) THEN
      CALL fail(ErrStat, ErrMsg, 'detach target must be an INACTIVE reserve Free point')
      RETURN
    END IF
    IF (.NOT. system%points(pf)%active) THEN
      CALL fail(ErrStat, ErrMsg, 'detach source point is inactive')
      RETURN
    END IF
    IF (system%point_dof_base(pr) < 0) THEN
      CALL fail(ErrStat, ErrMsg, 'reserve point has no frozen coupled block')
      RETURN
    END IF
    DO i = 1, SIZE(line_indices)
      IF (line_indices(i) < 1 .OR. line_indices(i) > system%n_lines) THEN
        CALL fail(ErrStat, ErrMsg, 'detach line index is outside the system line range')
        RETURN
      END IF
    END DO

    ! Rewire: every binding of a listed line held by the failing point moves to the
    ! reserve point; the exchange map entries for those line-end slots follow.
    nmoved = 0
    DO k = 1, SIZE(system%bindings)
      IF (system%bindings(k)%point_id /= fail_point_id) CYCLE
      IF (ALL(line_indices /= system%bindings(k)%line_index)) CYCLE
      system%bindings(k)%point_id = reserve_point_id
      local_base = 6*(system%bindings(k)%line_index - 1) + 3*(system%bindings(k)%line_end - 1)
      DO e = 1, 3
        system%coupled_dof_map(local_base + e) = system%point_dof_base(pr) + e
      END DO
      nmoved = nmoved + 1
    END DO
    IF (nmoved < 1) THEN
      CALL fail(ErrStat, ErrMsg, 'no listed line end is bound to the failing point')
      RETURN
    END IF

    ! Activate the reserve at the failing point's committed kinematics (the MoorDyn
    ! DetachLines convention: the freed end starts exactly where it was).
    system%points(pr)%q = system%points(pf)%q
    system%points(pr)%v = system%points(pf)%v
    system%points(pr)%a = system%points(pf)%a
    system%points(pr)%active = .TRUE.

    ! Recompute both points' attached end-node mass-diagonal shares from the
    ! rewired bindings (the same accumulation init performs).
    system%points(pf)%line_mass_diag = CD_ZERO
    system%points(pr)%line_mass_diag = CD_ZERO
    nmoved = 0
    DO k = 1, SIZE(system%bindings)
      i = find_point_index(system%points, system%bindings(k)%point_id)
      IF (i == pf) nmoved = nmoved + 1
      IF (i /= pf .AND. i /= pr) CYCLE
      CALL CD_Get_Model_EndNodeMassDiag(system%lines(system%bindings(k)%line_index), &
                                        system%bindings(k)%line_end, md, es, em)
      IF (es /= CD_MODEL_OK) THEN
        CALL fail(ErrStat, ErrMsg, 'end-node mass-diagonal recompute failed: '//TRIM(em))
        RETURN
      END IF
      system%points(i)%line_mass_diag = system%points(i)%line_mass_diag + md
    END DO
    ! A source point stripped of ALL its lines with no mass of its own has nothing
    ! left to integrate (total effective mass 0 would fail the step's mass guard):
    ! deactivate it. A heavy point (a clump) stays active and falls ballistically --
    ! its block gathers from the point store like any line-unreferenced block.
    IF (nmoved == 0 .AND. system%points(pf)%point_type /= CD_POINT_FIXED .AND. &
        system%points(pf)%point_type /= CD_POINT_COUPLED) THEN
      IF (.NOT. (system%points(pf)%mass + system%points(pf)%line_mass_diag > CD_ZERO)) &
        system%points(pf)%active = .FALSE.
    END IF
  END SUBROUTINE CD_Detach_System_LineEnds

  SUBROUTINE CD_Calc_System_CoupledLoads(system, coupled_loads, ErrStat, ErrMsg)
    !! Return aggregate compact coupled loads, concatenated line by line.
    TYPE(CD_SystemType), INTENT(INOUT) :: system
    REAL(wp), INTENT(OUT) :: coupled_loads(:)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg

    INTEGER :: i, lo, hi, es, n_team
    CHARACTER(1024) :: em

    ErrStat = CD_SYSTEM_OK
    ErrMsg = ''
    coupled_loads = CD_ZERO
    IF (.NOT. system%initialized) THEN
      ErrStat = CD_SYSTEM_NOT_INITIALIZED
      ErrMsg = 'CableDyn_System: system is not initialized'
      RETURN
    END IF
    IF (SIZE(coupled_loads) /= CD_System_NCoupledDOF(system, es, em)) THEN
      CALL fail(ErrStat, ErrMsg, 'coupled_loads output must have shape (n_system_coupled_dof)')
      RETURN
    END IF
    IF (.NOT. (ALLOCATED(system%line_off) .AND. ALLOCATED(system%line_stat) .AND. &
               ALLOCATED(system%line_msg) .AND. ALLOCATED(system%line_load_work))) THEN
      CALL fail(ErrStat, ErrMsg, 'per-line output workspace is not initialized')
      RETURN
    END IF
    n_team = line_team_size(system)
    IF (n_team > 1) THEN
      !$OMP PARALLEL DEFAULT(SHARED) PRIVATE(i) NUM_THREADS(n_team)
      CALL CD_Fatal_Thread_Init() ! this thread can report its own stack overflow
      !$OMP DO SCHEDULE(STATIC)
      DO i = 1, system%n_lines
        CALL line_coupled_loads(i)
      END DO
      !$OMP END DO
      !$OMP END PARALLEL
    ELSE
      ! one thread: the same loop without entering a parallel region (whose team setup costs
      ! more than a short line's loads)
      CALL CD_Fatal_Thread_Init()
      DO i = 1, system%n_lines
        CALL line_coupled_loads(i)
      END DO
    END IF
    DO i = 1, system%n_lines
      IF (system%line_stat(i) /= CD_MODEL_OK) THEN
        ErrStat = CD_SYSTEM_SOLVEFAIL
        ErrMsg = 'CableDyn_System: line coupled-load calculation failed: '//TRIM(system%line_msg(i))
        RETURN
      END IF
      lo = system%line_off(i)
      hi = system%line_off(i + 1) - 1
      CALL accumulate_mapped_loads(system, lo, hi, system%line_load_work(lo:hi), coupled_loads)
    END DO

  CONTAINS

    SUBROUTINE line_coupled_loads(il)
      !! The coupled loads of line il into its slice of the per-line workspace.
      INTEGER, INTENT(IN) :: il
      INTEGER :: l_lo, l_hi
      l_lo = system%line_off(il)
      l_hi = system%line_off(il + 1) - 1
      CALL CD_Calc_Model_CoupledLoads(system%lines(il), system%line_load_work(l_lo:l_hi), &
                                      system%line_stat(il), system%line_msg(il))
    END SUBROUTINE line_coupled_loads
  END SUBROUTINE CD_Calc_System_CoupledLoads

  INTEGER FUNCTION line_team_size(system) RESULT(n_team)
    !! Thread count for the per-line OpenMP loops: one thread per line, capped at
    !! OMP_LINES_MAX_THREADS and the host limit, when the lines' combined DOFs reach
    !! OMP_LINES_MIN_DOF; otherwise 1 (the loop then runs serially). Lines are
    !! independent, so results are identical for every team size.
    TYPE(CD_SystemType), INTENT(IN) :: system
    INTEGER :: i, total_dof

    n_team = 1
    IF (system%n_lines < 2) RETURN
    total_dof = 0
    DO i = 1, system%n_lines
      total_dof = total_dof + system%lines(i)%n_dof
    END DO
    IF (total_dof < OMP_LINES_MIN_DOF) RETURN
!$  n_team = MIN(system%n_lines, OMP_LINES_MAX_THREADS, omp_get_max_threads())
  END FUNCTION line_team_size

  SUBROUTINE CD_Calc_System_CoupledKinematicDerivatives(system, dload_dq, dload_dv, ErrStat, ErrMsg)
    !! Return aggregate reduced coupled-load derivatives with respect to compact
    !! prescribed coupled positions and velocities.
    TYPE(CD_SystemType), INTENT(INOUT) :: system
    REAL(wp), INTENT(OUT) :: dload_dq(:, :), dload_dv(:, :)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg

    INTEGER :: i, j, k, lo, hi, nc, es, row, col
    CHARACTER(1024) :: em

    ErrStat = CD_SYSTEM_OK
    ErrMsg = ''
    dload_dq = CD_ZERO
    dload_dv = CD_ZERO
    IF (.NOT. system%initialized) THEN
      ErrStat = CD_SYSTEM_NOT_INITIALIZED
      ErrMsg = 'CableDyn_System: system is not initialized'
      RETURN
    END IF
    IF (SIZE(dload_dq, 1) /= system%n_system_coupled_dof .OR. &
        SIZE(dload_dq, 2) /= system%n_system_coupled_dof .OR. &
        SIZE(dload_dv, 1) /= system%n_system_coupled_dof .OR. &
        SIZE(dload_dv, 2) /= system%n_system_coupled_dof) THEN
      CALL fail(ErrStat, ErrMsg, &
                'dload_dq/dload_dv outputs must have shape (n_system_coupled_dof, n_system_coupled_dof)')
      RETURN
    END IF
    lo = 1
    DO i = 1, system%n_lines
      nc = CD_Model_NCoupledDOF(system%lines(i), es, em)
      IF (es /= CD_MODEL_OK) THEN
        ErrStat = CD_SYSTEM_SOLVEFAIL
        ErrMsg = 'CableDyn_System: line coupled DOF count failed: '//TRIM(em)
        RETURN
      END IF
      hi = lo + nc - 1
      BLOCK
        REAL(wp) :: line_dq(nc, nc), line_dv(nc, nc)
        CALL CD_Calc_Model_CoupledKinematicDerivatives(system%lines(i), line_dq, line_dv, es, em)
        IF (es /= CD_MODEL_OK) THEN
          ErrStat = CD_SYSTEM_SOLVEFAIL
          ErrMsg = 'CableDyn_System: line kinematic derivative failed: '//TRIM(em)
          RETURN
        END IF
        DO j = 1, nc
          row = system%coupled_dof_map(lo + j - 1)
          DO k = 1, nc
            col = system%coupled_dof_map(lo + k - 1)
            dload_dq(row, col) = dload_dq(row, col) + line_dq(j, k)
            dload_dv(row, col) = dload_dv(row, col) + line_dv(j, k)
          END DO
        END DO
      END BLOCK
      lo = hi + 1
    END DO
  END SUBROUTINE CD_Calc_System_CoupledKinematicDerivatives

  SUBROUTINE CD_Calc_System_CoupledAccelDerivative(system, dload_da, ErrStat, ErrMsg, frozen_interior)
    !! Return the aggregate analytic coupled-load derivative with respect to
    !! compact prescribed coupled accelerations. By default the line interiors'
    !! accelerations follow the coupled ones (the condensed derivative of a step);
    !! frozen_interior = .TRUE. holds them (-M_cc of every line,
    !! CD_Calc_Model_CoupledEndMass): the response of CD_Calc_System_CoupledLoads when
    !! only the coupled motion changes, as in an output probe.
    TYPE(CD_SystemType), INTENT(INOUT) :: system
    REAL(wp), INTENT(OUT) :: dload_da(:, :)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    LOGICAL, INTENT(IN), OPTIONAL :: frozen_interior

    INTEGER :: i, j, k, lo, hi, nc, es, row, col
    LOGICAL :: frozen
    CHARACTER(1024) :: em

    ErrStat = CD_SYSTEM_OK
    ErrMsg = ''
    dload_da = CD_ZERO
    frozen = .FALSE.
    IF (PRESENT(frozen_interior)) frozen = frozen_interior
    IF (.NOT. system%initialized) THEN
      ErrStat = CD_SYSTEM_NOT_INITIALIZED
      ErrMsg = 'CableDyn_System: system is not initialized'
      RETURN
    END IF
    IF (SIZE(dload_da, 1) /= system%n_system_coupled_dof .OR. &
        SIZE(dload_da, 2) /= system%n_system_coupled_dof) THEN
      CALL fail(ErrStat, ErrMsg, 'dload_da output must have shape (n_system_coupled_dof, n_system_coupled_dof)')
      RETURN
    END IF
    lo = 1
    DO i = 1, system%n_lines
      nc = CD_Model_NCoupledDOF(system%lines(i), es, em)
      IF (es /= CD_MODEL_OK) THEN
        ErrStat = CD_SYSTEM_SOLVEFAIL
        ErrMsg = 'CableDyn_System: line coupled DOF count failed: '//TRIM(em)
        RETURN
      END IF
      hi = lo + nc - 1
      IF (nc > 0 .AND. frozen) THEN
        BLOCK
          REAL(wp) :: m_cc(nc, nc)
          CALL CD_Calc_Model_CoupledEndMass(system%lines(i), m_cc, es, em)
          IF (es /= CD_MODEL_OK) THEN
            ErrStat = CD_SYSTEM_SOLVEFAIL
            ErrMsg = 'CableDyn_System: line coupled end mass failed: '//TRIM(em)
            RETURN
          END IF
          DO j = 1, nc
            row = system%coupled_dof_map(lo + j - 1)
            DO k = 1, nc
              col = system%coupled_dof_map(lo + k - 1)
              dload_da(row, col) = dload_da(row, col) - m_cc(j, k)
            END DO
          END DO
        END BLOCK
      ELSE IF (nc > 0) THEN
        ! the line's derivative stays in its own workspace (ad_result) and is summed from there
        CALL CD_Update_Model_CoupledAccelDerivative(system%lines(i), es, em)
        IF (es /= CD_MODEL_OK) THEN
          ErrStat = CD_SYSTEM_SOLVEFAIL
          ErrMsg = 'CableDyn_System: line acceleration derivative failed: '//TRIM(em)
          RETURN
        END IF
        DO j = 1, nc
          row = system%coupled_dof_map(lo + j - 1)
          DO k = 1, nc
            col = system%coupled_dof_map(lo + k - 1)
            dload_da(row, col) = dload_da(row, col) + system%lines(i)%dynamic_workspace%ad_result(j, k)
          END DO
        END DO
      END IF
      lo = hi + 1
    END DO
  END SUBROUTINE CD_Calc_System_CoupledAccelDerivative

  SUBROUTINE CD_Recompute_System_Acceleration(system, ErrStat, ErrMsg)
    !! Recompute acceleration for every contained line from its current state.
    TYPE(CD_SystemType), INTENT(INOUT) :: system
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg

    INTEGER :: i, es
    CHARACTER(1024) :: em

    ErrStat = CD_SYSTEM_OK
    ErrMsg = ''
    IF (.NOT. system%initialized) THEN
      ErrStat = CD_SYSTEM_NOT_INITIALIZED
      ErrMsg = 'CableDyn_System: system is not initialized'
      RETURN
    END IF
    CALL save_line_states(system, ErrStat, ErrMsg)
    IF (ErrStat /= CD_SYSTEM_OK) RETURN
    DO i = 1, system%n_lines
      CALL CD_Recompute_Model_Acceleration(system%lines(i), es, em)
      IF (es /= CD_MODEL_OK) THEN
        CALL restore_line_states(system)
        ErrStat = CD_SYSTEM_SOLVEFAIL
        ErrMsg = 'CableDyn_System: line acceleration recompute failed: '//TRIM(em)
        RETURN
      END IF
    END DO
  END SUBROUTINE CD_Recompute_System_Acceleration

  SUBROUTINE CD_Update_System_Line_External_Loads(system, line_index, f_ext, ErrStat, ErrMsg)
    !! Replace the full external load vector for one contained line.
    TYPE(CD_SystemType), INTENT(INOUT) :: system
    INTEGER, INTENT(IN) :: line_index
    REAL(wp), INTENT(IN) :: f_ext(:)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg

    INTEGER :: es
    CHARACTER(1024) :: em

    CALL validate_line_index(system, line_index, ErrStat, ErrMsg)
    IF (ErrStat /= CD_SYSTEM_OK) RETURN
    CALL CD_Update_Model_External_Loads(system%lines(line_index), f_ext, es, em)
    IF (es /= CD_MODEL_OK) THEN
      SELECT CASE (es)
      CASE (CD_MODEL_NOT_INITIALIZED)
        ErrStat = CD_SYSTEM_NOT_INITIALIZED
      CASE (CD_MODEL_BADINPUT)
        ErrStat = CD_SYSTEM_BADINPUT
      CASE DEFAULT
        ErrStat = CD_SYSTEM_SOLVEFAIL
      END SELECT
      ErrMsg = 'CableDyn_System: line external-load update failed: '//TRIM(em)
      RETURN
    END IF
  END SUBROUTINE CD_Update_System_Line_External_Loads

  SUBROUTINE CD_Update_System_Point_Fluid_Fields(system, fluid_velocity, fluid_acceleration, waterline_z, &
                                                 fluid_density, ErrStat, ErrMsg)
    !! Replace lumped point fluid kinematics used by Free/Connect point hydro.
    TYPE(CD_SystemType), INTENT(INOUT) :: system
    REAL(wp), INTENT(IN) :: fluid_velocity(:, :), fluid_acceleration(:, :), waterline_z(:), fluid_density
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg

    INTEGER :: p

    ErrStat = CD_SYSTEM_OK
    ErrMsg = ''
    IF (.NOT. system%initialized) THEN
      ErrStat = CD_SYSTEM_NOT_INITIALIZED
      ErrMsg = 'CableDyn_System: system is not initialized'
      RETURN
    END IF
    IF (.NOT. ALLOCATED(system%points)) THEN
      CALL fail(ErrStat, ErrMsg, 'point fluid update requires a point-initialized system')
      RETURN
    END IF
    IF (SIZE(fluid_velocity, 1) /= 3 .OR. SIZE(fluid_acceleration, 1) /= 3 .OR. &
        SIZE(fluid_velocity, 2) /= SIZE(system%points) .OR. &
        SIZE(fluid_acceleration, 2) /= SIZE(system%points) .OR. &
        SIZE(waterline_z) /= SIZE(system%points)) THEN
      CALL fail(ErrStat, ErrMsg, 'point fluid fields must have shapes velocity(3,npoint), '// &
                'acceleration(3,npoint), z(npoint)')
      RETURN
    END IF
    IF (.NOT. (CD_Is_Finite(fluid_density) .AND. fluid_density >= CD_ZERO)) THEN
      CALL fail(ErrStat, ErrMsg, 'point fluid density must be finite and non-negative')
      RETURN
    END IF
    DO p = 1, SIZE(system%points)
      IF (.NOT. (CD_All_Finite(fluid_velocity(:, p)) .AND. &
                 CD_All_Finite(fluid_acceleration(:, p)) .AND. &
                 CD_Is_Finite(waterline_z(p)))) THEN
        CALL fail(ErrStat, ErrMsg, 'point fluid fields must be finite')
        RETURN
      END IF
    END DO
    DO p = 1, SIZE(system%points)
      system%points(p)%fluid_velocity = fluid_velocity(:, p)
      system%points(p)%fluid_acceleration = fluid_acceleration(:, p)
      system%points(p)%waterline_z = waterline_z(p)
      system%points(p)%fluid_density = fluid_density
    END DO
  END SUBROUTINE CD_Update_System_Point_Fluid_Fields

  SUBROUTINE CD_Update_System_Line_Hydro_Fields(system, line_index, ErrStat, ErrMsg, &
                                                fluid_velocity, fluid_acceleration, drag_waterline_z, &
                                                fk_waterline_z, added_mass_waterline_z, buoyancy_waterline_z)
    !! Refresh ONE contained line's nodal ambient-fluid fields (velocity, acceleration,
    !! and the wetting waterlines) -- the per-step boundary a coupled host uses to drive
    !! externally sampled wave kinematics (e.g. the OpenFAST SeaState WaveField) into the
    !! line hydro. Delegates to CD_Update_Model_Hydro_Fields, so each field requires its
    !! hydro block configured at initialization (the external_fluid deck build does
    !! exactly that); an unconfigured field fails closed with the model's message.
    TYPE(CD_SystemType), INTENT(INOUT) :: system
    INTEGER, INTENT(IN) :: line_index
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    REAL(wp), INTENT(IN), OPTIONAL :: fluid_velocity(:, :)
    REAL(wp), INTENT(IN), OPTIONAL :: fluid_acceleration(:, :)
    REAL(wp), INTENT(IN), OPTIONAL :: drag_waterline_z(:)
    REAL(wp), INTENT(IN), OPTIONAL :: fk_waterline_z(:)
    REAL(wp), INTENT(IN), OPTIONAL :: added_mass_waterline_z(:)
    REAL(wp), INTENT(IN), OPTIONAL :: buoyancy_waterline_z(:)

    INTEGER :: es
    CHARACTER(1024) :: em

    CALL validate_line_index(system, line_index, ErrStat, ErrMsg)
    IF (ErrStat /= CD_SYSTEM_OK) RETURN
    CALL CD_Update_Model_Hydro_Fields(system%lines(line_index), es, em, &
                                      fluid_velocity=fluid_velocity, fluid_acceleration=fluid_acceleration, &
                                      drag_waterline_z=drag_waterline_z, fk_waterline_z=fk_waterline_z, &
                                      added_mass_waterline_z=added_mass_waterline_z, &
                                      buoyancy_waterline_z=buoyancy_waterline_z)
    IF (es /= CD_MODEL_OK) THEN
      ErrStat = MERGE(CD_SYSTEM_BADINPUT, CD_SYSTEM_SOLVEFAIL, es == CD_MODEL_BADINPUT)
      ErrMsg = 'CableDyn_System: line hydro-field update failed: '//TRIM(em)
      RETURN
    END IF
    ErrStat = CD_SYSTEM_OK
    ErrMsg = ''
  END SUBROUTINE CD_Update_System_Line_Hydro_Fields

  SUBROUTINE CD_Update_System_Line_Interior_State(system, line_index, q_interior, v_interior, ErrStat, ErrMsg, &
                                                  a_interior)
    !! Overwrite ONE contained line's interior-node state (endpoints untouched) -- the
    !! checkpoint-restart reload boundary (see CD_Update_Model_Interior_State). The
    !! caller re-prescribes coupled endpoints from the host mesh; a_interior reloads the
    !! committed generalised-alpha acceleration exactly (omit it only if a
    !! CD_Recompute_System_Acceleration re-derivation is acceptable).
    TYPE(CD_SystemType), INTENT(INOUT) :: system
    INTEGER, INTENT(IN) :: line_index
    REAL(wp), INTENT(IN) :: q_interior(:), v_interior(:)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    REAL(wp), INTENT(IN), OPTIONAL :: a_interior(:)

    INTEGER :: es
    CHARACTER(1024) :: em

    CALL validate_line_index(system, line_index, ErrStat, ErrMsg)
    IF (ErrStat /= CD_SYSTEM_OK) RETURN
    CALL CD_Update_Model_Interior_State(system%lines(line_index), q_interior, v_interior, es, em, &
                                        a_interior=a_interior)
    IF (es /= CD_MODEL_OK) THEN
      ErrStat = MERGE(CD_SYSTEM_BADINPUT, CD_SYSTEM_SOLVEFAIL, es == CD_MODEL_BADINPUT)
      ErrMsg = 'CableDyn_System: line interior-state update failed: '//TRIM(em)
      RETURN
    END IF
    ErrStat = CD_SYSTEM_OK
    ErrMsg = ''
  END SUBROUTINE CD_Update_System_Line_Interior_State

  LOGICAL FUNCTION CD_System_Is_Initialized(system) RESULT(is_initialized)
    !! Query-only helper for shells and tests.
    TYPE(CD_SystemType), INTENT(IN) :: system
    is_initialized = system%initialized
  END FUNCTION CD_System_Is_Initialized

  LOGICAL FUNCTION CD_System_Has_DynamicPoints(system, ErrStat, ErrMsg) RESULT(has_dynamic)
    !! Query whether the initialized system owns any Free/Connect points.
    TYPE(CD_SystemType), INTENT(IN) :: system
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg

    INTEGER :: p

    has_dynamic = .FALSE.
    IF (.NOT. system%initialized) THEN
      ErrStat = CD_SYSTEM_NOT_INITIALIZED
      ErrMsg = 'CableDyn_System: system is not initialized'
      RETURN
    END IF
    IF (ALLOCATED(system%points)) THEN
      DO p = 1, SIZE(system%points)
        IF (system%points(p)%point_type == CD_POINT_FREE .OR. system%points(p)%point_type == CD_POINT_CONNECT) THEN
          has_dynamic = .TRUE.
          EXIT
        END IF
      END DO
    END IF
    ErrStat = CD_SYSTEM_OK
    ErrMsg = ''
  END FUNCTION CD_System_Has_DynamicPoints

  INTEGER FUNCTION query_line_int(system, line_index, query, ErrStat, ErrMsg) RESULT(n)
    TYPE(CD_SystemType), INTENT(IN) :: system
    INTEGER, INTENT(IN) :: line_index
    INTERFACE
      INTEGER FUNCTION query(model, ErrStat, ErrMsg) RESULT(value)
        IMPORT :: CD_ModelType
        TYPE(CD_ModelType), INTENT(IN) :: model
        INTEGER, INTENT(OUT) :: ErrStat
        CHARACTER(*), INTENT(OUT) :: ErrMsg
      END FUNCTION query
    END INTERFACE
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg

    INTEGER :: es
    CHARACTER(1024) :: em

    n = 0
    CALL validate_line_index(system, line_index, ErrStat, ErrMsg)
    IF (ErrStat /= CD_SYSTEM_OK) RETURN
    n = query(system%lines(line_index), es, em)
    IF (es /= CD_MODEL_OK) THEN
      ErrStat = CD_SYSTEM_SOLVEFAIL
      ErrMsg = 'CableDyn_System: line query failed: '//TRIM(em)
      n = 0
      RETURN
    END IF
    ErrStat = CD_SYSTEM_OK
    ErrMsg = ''
  END FUNCTION query_line_int

  SUBROUTINE validate_system_motion_shape(system, q_coupled, v_coupled, a_coupled, ErrStat, ErrMsg)
    TYPE(CD_SystemType), INTENT(IN) :: system
    REAL(wp), INTENT(IN) :: q_coupled(:), v_coupled(:), a_coupled(:)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg

    INTEGER :: n, es
    CHARACTER(1024) :: em

    ErrStat = CD_SYSTEM_OK
    ErrMsg = ''
    IF (.NOT. system%initialized) THEN
      ErrStat = CD_SYSTEM_NOT_INITIALIZED
      ErrMsg = 'CableDyn_System: system is not initialized'
      RETURN
    END IF
    n = CD_System_NCoupledDOF(system, es, em)
    IF (es /= CD_SYSTEM_OK) THEN
      ErrStat = es
      ErrMsg = em
      RETURN
    END IF
    IF (SIZE(q_coupled) /= n .OR. SIZE(v_coupled) /= n .OR. SIZE(a_coupled) /= n) THEN
      CALL fail(ErrStat, ErrMsg, 'aggregate coupled motion must have shape (n_system_coupled_dof)')
    END IF
  END SUBROUTINE validate_system_motion_shape

  SUBROUTINE validate_coupled_map(coupled_dof_map, n_local, ErrStat, ErrMsg)
    !! Validate local-line coupled DOF to compact system exchange DOF map.
    INTEGER, INTENT(IN) :: coupled_dof_map(:), n_local
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg

    INTEGER :: i, istat, n_system
    LOGICAL, ALLOCATABLE :: seen(:)

    ErrStat = CD_SYSTEM_OK
    ErrMsg = ''
    IF (SIZE(coupled_dof_map) /= n_local) THEN
      CALL fail(ErrStat, ErrMsg, 'coupled_dof_map must have shape (n_local_coupled_dof)')
      RETURN
    END IF
    IF (ANY(coupled_dof_map < 1)) THEN
      CALL fail(ErrStat, ErrMsg, 'coupled_dof_map entries must be positive')
      RETURN
    END IF
    IF (n_local == 0) RETURN
    n_system = MAXVAL(coupled_dof_map)
    ALLOCATE (seen(n_system), STAT=istat)
    IF (istat /= 0) THEN
      CALL alloc_fail(ErrStat, ErrMsg, 'coupled-map validation')
      RETURN
    END IF
    seen = .FALSE.
    DO i = 1, n_local
      seen(coupled_dof_map(i)) = .TRUE.
    END DO
    IF (.NOT. ALL(seen)) THEN
      CALL fail(ErrStat, ErrMsg, 'coupled_dof_map must use compact ids without gaps')
    END IF
  END SUBROUTINE validate_coupled_map

  SUBROUTINE CD_Get_System_PointBlocks(system, block_point_index, ErrStat, ErrMsg)
    !! For each 3-DOF block of the system coupled vector, return the index into the
    !! system's points array of the point that owns it. Block ownership reads the
    !! INIT-FROZEN per-point DOF bases (point_dof_base) so a rewired binding (line
    !! failures) cannot move any block. A system initialized without points
    !! (CD_Init_System_From_Models) returns an unallocated array: every coupled
    !! block belongs to the caller.
    TYPE(CD_SystemType), INTENT(IN) :: system
    INTEGER, ALLOCATABLE, INTENT(OUT) :: block_point_index(:)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg

    INTEGER :: i, pidx, nb, istat

    ErrStat = CD_SYSTEM_OK
    ErrMsg = ''
    IF (.NOT. CD_System_Is_Initialized(system)) THEN
      ErrStat = CD_SYSTEM_NOT_INITIALIZED
      ErrMsg = 'CableDyn_System: system is not initialized'
      RETURN
    END IF
    IF (.NOT. ALLOCATED(system%points)) RETURN
    IF (ALLOCATED(system%point_dof_base)) THEN
      nb = system%n_system_coupled_dof/3
      ALLOCATE (block_point_index(nb), STAT=istat)
      IF (istat /= 0) THEN
        CALL alloc_fail(ErrStat, ErrMsg, 'point-block index array')
        RETURN
      END IF
      block_point_index = 0
      DO i = 1, SIZE(system%point_dof_base)
        IF (system%point_dof_base(i) < 0) CYCLE
        pidx = system%point_dof_base(i)/3 + 1
        IF (pidx < 1 .OR. pidx > nb .OR. MOD(system%point_dof_base(i), 3) /= 0) THEN
          CALL fail(ErrStat, ErrMsg, 'stored point DOF base does not tile the coupled vector')
          RETURN
        END IF
        block_point_index(pidx) = i
      END DO
      IF (ANY(block_point_index < 1)) THEN
        CALL fail(ErrStat, ErrMsg, 'point-block reconstruction does not tile the coupled vector')
        RETURN
      END IF
      RETURN
    END IF
    ! Every point-initialized system carries the store (CD_Init_System_From_Points).
    CALL fail(ErrStat, ErrMsg, 'the point DOF store of a point-initialized system is missing')
  END SUBROUTINE CD_Get_System_PointBlocks

  SUBROUTINE build_point_coupled_map(models, points, bindings, map, point_base_out, ErrStat, ErrMsg)
    TYPE(CD_ModelType), INTENT(IN) :: models(:)
    TYPE(CD_SystemPointType), INTENT(IN) :: points(:)
    TYPE(CD_LineEndpointBinding), INTENT(IN) :: bindings(:)
    INTEGER, ALLOCATABLE, INTENT(OUT) :: map(:)
    INTEGER, ALLOCATABLE, INTENT(OUT) :: point_base_out(:)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg

    INTEGER :: i, e, pidx, nc, es, istat, n_local, n_points_coupled
    INTEGER :: point_dof_base, local_base
    INTEGER, ALLOCATABLE :: point_base(:)
    LOGICAL, ALLOCATABLE :: bound(:, :), point_bound(:)
    CHARACTER(1024) :: em

    ErrStat = CD_SYSTEM_OK
    ErrMsg = ''
    IF (SIZE(models) < 1) THEN
      CALL fail(ErrStat, ErrMsg, 'point-based system requires at least one line model')
      RETURN
    END IF
    IF (SIZE(points) < 1) THEN
      CALL fail(ErrStat, ErrMsg, 'point-based system requires at least one point')
      RETURN
    END IF
    CALL validate_points(points, ErrStat, ErrMsg)
    IF (ErrStat /= CD_SYSTEM_OK) RETURN
    n_local = 0
    DO i = 1, SIZE(models)
      IF (.NOT. CD_Model_Is_Initialized(models(i))) THEN
        CALL fail(ErrStat, ErrMsg, 'all line models must be initialized')
        RETURN
      END IF
      nc = CD_Model_NCoupledDOF(models(i), es, em)
      IF (es /= CD_MODEL_OK .OR. nc /= 6) THEN
        CALL fail(ErrStat, ErrMsg, 'point bindings currently require two coupled endpoint triples per line')
        RETURN
      END IF
      n_local = n_local + nc
    END DO
    ALLOCATE (map(n_local), bound(2, SIZE(models)), point_bound(SIZE(points)), point_base(SIZE(points)), STAT=istat)
    IF (istat /= 0) THEN
      CALL alloc_fail(ErrStat, ErrMsg, 'point-map construction')
      RETURN
    END IF
    map = 0
    bound = .FALSE.
    point_bound = .FALSE.
    point_base = -1
    DO i = 1, SIZE(bindings)
      IF (bindings(i)%line_index < 1 .OR. bindings(i)%line_index > SIZE(models)) THEN
        CALL fail(ErrStat, ErrMsg, 'binding line_index is outside the model range')
        RETURN
      END IF
      IF (bindings(i)%line_end /= CD_LINE_END_A .AND. bindings(i)%line_end /= CD_LINE_END_B) THEN
        CALL fail(ErrStat, ErrMsg, 'binding line_end must be CD_LINE_END_A or CD_LINE_END_B')
        RETURN
      END IF
      pidx = find_point_index(points, bindings(i)%point_id)
      IF (pidx == 0) THEN
        CALL fail(ErrStat, ErrMsg, 'binding references an unknown point id')
        RETURN
      END IF
      IF (bound(bindings(i)%line_end, bindings(i)%line_index)) THEN
        CALL fail(ErrStat, ErrMsg, 'duplicate binding for one line endpoint')
        RETURN
      END IF
      point_bound(pidx) = .TRUE.
      bound(bindings(i)%line_end, bindings(i)%line_index) = .TRUE.
    END DO
    IF (.NOT. ALL(bound)) THEN
      CALL fail(ErrStat, ErrMsg, 'each line must bind both endpoints')
      RETURN
    END IF
    ! Two passes: BOUND points take the low compact blocks (the map must tile
    ! 1..3*n_bound without gaps for validate_coupled_map), then reserve (inactive)
    ! points take the blocks ABOVE -- regardless of where the caller placed them
    ! in the points array, so input/ID ordering never breaks a failure-capable init.
    n_points_coupled = 0
    DO i = 1, SIZE(points)
      IF (is_supported_point_type(points(i)%point_type)) THEN
        IF (.NOT. points(i)%active) THEN
          ! Reserve (inactive) points: line-failure pre-allocation. They must be
          ! unbound Free points; they still receive a coupled block (second pass)
          ! so the exchange layout never changes when a detach activates them.
          IF (points(i)%point_type /= CD_POINT_FREE) THEN
            CALL fail(ErrStat, ErrMsg, 'inactive reserve points must be Free points')
            RETURN
          END IF
          IF (point_bound(i)) THEN
            CALL fail(ErrStat, ErrMsg, 'inactive reserve points must not be bound to a line endpoint')
            RETURN
          END IF
          CYCLE
        END IF
        IF (.NOT. point_bound(i) .AND. &
            (points(i)%point_type == CD_POINT_FREE .OR. points(i)%point_type == CD_POINT_CONNECT)) THEN
          CALL fail(ErrStat, ErrMsg, 'Free/Connect points must be bound to a line endpoint')
          RETURN
        END IF
        IF (point_bound(i)) THEN
          n_points_coupled = n_points_coupled + 1
          point_base(i) = 3*(n_points_coupled - 1)
        END IF
      END IF
    END DO
    DO i = 1, SIZE(points)
      IF (is_supported_point_type(points(i)%point_type) .AND. .NOT. points(i)%active) THEN
        n_points_coupled = n_points_coupled + 1
        point_base(i) = 3*(n_points_coupled - 1)
      END IF
    END DO
    DO i = 1, SIZE(bindings)
      pidx = find_point_index(points, bindings(i)%point_id)
      point_dof_base = point_base(pidx)
      local_base = 6*(bindings(i)%line_index - 1) + 3*(bindings(i)%line_end - 1)
      DO e = 1, 3
        map(local_base + e) = point_dof_base + e
      END DO
    END DO
    ! Reserved (inactive) blocks sit at the top of the numbering and are not
    ! referenced by any line-end slot; the map itself must still tile the bound
    ! blocks compactly from 1.
    IF (ANY(map < 1) .OR. MAXVAL(map) > 3*n_points_coupled) THEN
      CALL fail(ErrStat, ErrMsg, 'point-based map construction failed')
      RETURN
    END IF
    CALL validate_coupled_map(map, n_local, ErrStat, ErrMsg)
    IF (ErrStat /= CD_SYSTEM_OK) RETURN
    ALLOCATE (point_base_out(SIZE(points)), STAT=istat)
    IF (istat /= 0) THEN
      CALL alloc_fail(ErrStat, ErrMsg, 'point-base storage')
      RETURN
    END IF
    point_base_out = point_base
  END SUBROUTINE build_point_coupled_map

  SUBROUTINE validate_points(points, ErrStat, ErrMsg)
    TYPE(CD_SystemPointType), INTENT(IN) :: points(:)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg

    INTEGER :: i, j

    ErrStat = CD_SYSTEM_OK
    ErrMsg = ''
    DO i = 1, SIZE(points)
      IF (points(i)%id < 1) THEN
        CALL fail(ErrStat, ErrMsg, 'point ids must be positive')
        RETURN
      END IF
      IF (.NOT. is_supported_point_type(points(i)%point_type)) THEN
        CALL fail(ErrStat, ErrMsg, 'point_type must be Fixed, Coupled, Free, or Connect')
        RETURN
      END IF
      IF (.NOT. (CD_All_Finite(points(i)%q) .AND. CD_All_Finite(points(i)%v) .AND. &
                 CD_All_Finite(points(i)%a) .AND. CD_All_Finite(points(i)%force) .AND. &
                 CD_Is_Finite(points(i)%mass) .AND. &
                 CD_Is_Finite(points(i)%volume) .AND. CD_Is_Finite(points(i)%cda) .AND. &
                 CD_Is_Finite(points(i)%ca) .AND. CD_Is_Finite(points(i)%seabed_k) .AND. &
                 CD_Is_Finite(points(i)%seabed_c))) THEN
        CALL fail(ErrStat, ErrMsg, 'point state and load properties must be finite')
        RETURN
      END IF
      ! Non-negative, not strictly positive: a massless Free/Connect point bound to
      ! lines advances on the attached end-node consistent-mass diagonal share
      ! (MoorDyn's zero-mass junction pattern); the dynamic step fails closed if the
      ! TOTAL (point + attached end-node) mass is not positive.
      IF ((points(i)%point_type == CD_POINT_FREE .OR. points(i)%point_type == CD_POINT_CONNECT) .AND. &
          points(i)%mass < CD_ZERO) THEN
        CALL fail(ErrStat, ErrMsg, 'Free/Connect points require non-negative mass')
        RETURN
      END IF
      IF (points(i)%volume < CD_ZERO .OR. points(i)%cda < CD_ZERO .OR. points(i)%ca < CD_ZERO) THEN
        CALL fail(ErrStat, ErrMsg, 'point volume, CdA, and Ca must be non-negative')
        RETURN
      END IF
      IF (points(i)%seabed_k < CD_ZERO .OR. points(i)%seabed_c < CD_ZERO) THEN
        CALL fail(ErrStat, ErrMsg, 'point seabed contact stiffness and damping must be non-negative')
        RETURN
      END IF
      DO j = i + 1, SIZE(points)
        IF (points(j)%id == points(i)%id) THEN
          CALL fail(ErrStat, ErrMsg, 'point ids must be unique')
          RETURN
        END IF
      END DO
    END DO
  END SUBROUTINE validate_points

  LOGICAL FUNCTION is_supported_point_type(point_type) RESULT(ok)
    INTEGER, INTENT(IN) :: point_type
    ok = point_type == CD_POINT_FIXED .OR. point_type == CD_POINT_COUPLED .OR. &
         point_type == CD_POINT_FREE .OR. point_type == CD_POINT_CONNECT
  END FUNCTION is_supported_point_type

  INTEGER FUNCTION find_point_index(points, point_id) RESULT(idx)
    TYPE(CD_SystemPointType), INTENT(IN) :: points(:)
    INTEGER, INTENT(IN) :: point_id
    INTEGER :: i

    idx = 0
    DO i = 1, SIZE(points)
      IF (points(i)%id == point_id) THEN
        idx = i
        RETURN
      END IF
    END DO
  END FUNCTION find_point_index

  INTEGER FUNCTION point_coupled_base(system, point_index) RESULT(base)
    !! Return the zero-based compact exchange offset for a bound point, or -1
    !! for output-only held points that are intentionally not part of the map.
    TYPE(CD_SystemType), INTENT(IN) :: system
    INTEGER, INTENT(IN) :: point_index

    base = -1
    ! The init-frozen store is authoritative: a rewired binding (line failures)
    ! must not move any point's block. Every point-initialized system carries it.
    IF (ALLOCATED(system%point_dof_base)) THEN
      IF (point_index >= 1 .AND. point_index <= SIZE(system%point_dof_base)) &
        base = system%point_dof_base(point_index)
    END IF
  END FUNCTION point_coupled_base

  SUBROUTINE scatter_mapped_motion(system, lo, hi, q_system, v_system, a_system, q_local, v_local, a_local)
    TYPE(CD_SystemType), INTENT(IN) :: system
    INTEGER, INTENT(IN) :: lo, hi
    REAL(wp), INTENT(IN) :: q_system(:), v_system(:), a_system(:)
    REAL(wp), INTENT(OUT) :: q_local(:), v_local(:), a_local(:)

    INTEGER :: j, local_id, system_id

    DO local_id = lo, hi
      j = local_id - lo + 1
      system_id = system%coupled_dof_map(local_id)
      q_local(j) = q_system(system_id)
      v_local(j) = v_system(system_id)
      a_local(j) = a_system(system_id)
    END DO
  END SUBROUTINE scatter_mapped_motion

  SUBROUTINE accumulate_mapped_loads(system, lo, hi, line_loads, system_loads)
    TYPE(CD_SystemType), INTENT(IN) :: system
    INTEGER, INTENT(IN) :: lo, hi
    REAL(wp), INTENT(IN) :: line_loads(:)
    REAL(wp), INTENT(INOUT) :: system_loads(:)

    INTEGER :: j, local_id, system_id

    DO local_id = lo, hi
      j = local_id - lo + 1
      system_id = system%coupled_dof_map(local_id)
      system_loads(system_id) = system_loads(system_id) + line_loads(j)
    END DO
  END SUBROUTINE accumulate_mapped_loads

  SUBROUTINE validate_line_index(system, line_index, ErrStat, ErrMsg)
    TYPE(CD_SystemType), INTENT(IN) :: system
    INTEGER, INTENT(IN) :: line_index
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg

    ErrStat = CD_SYSTEM_OK
    ErrMsg = ''
    IF (.NOT. system%initialized) THEN
      ErrStat = CD_SYSTEM_NOT_INITIALIZED
      ErrMsg = 'CableDyn_System: system is not initialized'
      RETURN
    END IF
    IF (line_index < 1 .OR. line_index > system%n_lines) THEN
      CALL fail(ErrStat, ErrMsg, 'line_index is outside the system line range')
    END IF
  END SUBROUTINE validate_line_index

  SUBROUTINE point_environment_force(point, point_velocity, force, effective_mass, ErrStat, ErrMsg)
    !! Lumped Morison point load for Free/Connect objects below the waterline.
    TYPE(CD_SystemPointType), INTENT(IN) :: point
    REAL(wp), INTENT(IN) :: point_velocity(3)
    REAL(wp), INTENT(OUT) :: force(3), effective_mass
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg

    REAL(wp) :: rel(3), rel_speed, added_mass

    ErrStat = CD_SYSTEM_OK
    ErrMsg = ''
    force = CD_ZERO
    effective_mass = point%mass
    ! Non-negative (not strictly positive): the caller's denominator is the TOTAL
    ! effective mass including the attached lines' end-node diagonal share, so a
    ! massless point with attached lines is valid here; the step guards the total.
    IF (.NOT. (CD_Is_Finite(point%mass) .AND. point%mass >= CD_ZERO)) THEN
      CALL fail(ErrStat, ErrMsg, 'point hydro requires finite non-negative point mass')
      RETURN
    END IF
    IF (.NOT. (CD_All_Finite(point_velocity) .AND. CD_All_Finite(point%fluid_velocity) .AND. &
               CD_All_Finite(point%fluid_acceleration) .AND. CD_Is_Finite(point%waterline_z) .AND. &
               CD_Is_Finite(point%fluid_density) .AND. CD_Is_Finite(point%volume) .AND. &
               CD_Is_Finite(point%cda) .AND. CD_Is_Finite(point%ca))) THEN
      CALL fail(ErrStat, ErrMsg, 'point hydro fields must be finite')
      RETURN
    END IF
    IF (point%fluid_density < CD_ZERO .OR. point%volume < CD_ZERO .OR. point%cda < CD_ZERO .OR. point%ca < CD_ZERO) THEN
      CALL fail(ErrStat, ErrMsg, 'point hydro rho, volume, CdA, and Ca must be non-negative')
      RETURN
    END IF
    IF (point%q(3) > point%waterline_z .OR. point%fluid_density <= CD_ZERO) RETURN

    rel = point%fluid_velocity - point_velocity
    rel_speed = SQRT(SUM(rel*rel))
    force = 0.5_wp*point%fluid_density*point%cda*rel_speed*rel + &
            point%fluid_density*point%volume*(1.0_wp + point%ca)*point%fluid_acceleration
    added_mass = point%fluid_density*point%volume*point%ca
    effective_mass = point%mass + added_mass
  END SUBROUTINE point_environment_force

  SUBROUTINE save_line_states(system, ErrStat, ErrMsg)
    TYPE(CD_SystemType), INTENT(INOUT) :: system
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    INTEGER :: i

    ErrStat = CD_SYSTEM_OK
    ErrMsg = ''
    DO i = 1, system%n_lines
      IF (.NOT. (ALLOCATED(system%lines(i)%q_rollback) .AND. ALLOCATED(system%lines(i)%v_rollback) .AND. &
                 ALLOCATED(system%lines(i)%a_rollback))) THEN
        CALL fail(ErrStat, ErrMsg, 'line rollback workspace is not initialized')
        RETURN
      END IF
      system%lines(i)%q_rollback = system%lines(i)%q
      system%lines(i)%v_rollback = system%lines(i)%v
      system%lines(i)%a_rollback = system%lines(i)%a
      ! the run audit's largest solver step rolls back too: a rolled-back (stalled) full step
      ! must not count when its halves are what the line commits
      system%lines(i)%audit_hmax_rollback = system%lines(i)%audit_hmax
      ! the sub-stepping diagnostics likewise: a rolled-back step is not counted
      system%lines(i)%sub_stats_rollback = system%lines(i)%sub_stats
      ! the committed lengths and rates (active line control) advance with a step too
      system%lines(i)%l0_c_rollback = system%lines(i)%l0_c
      system%lines(i)%l0_dot_c_rollback = system%lines(i)%l0_dot_c
      ! the viscoelastic dl_1 state advances with every committed line step, so
      ! it must roll back with q/v/a (a line that stepped can be rolled back
      ! when a sibling line or the coupled point solve fails)
      IF (system%lines(i)%has_viscoelastic) &
        system%lines(i)%ve_dl_1_rollback = system%lines(i)%ve_dl_1
      ! the Syrope slow-strain and running-max states likewise advance every
      ! committed step and must roll back with q/v/a
      IF (system%lines(i)%has_syrope) THEN
        system%lines(i)%syrope_slow_rollback = system%lines(i)%syrope_slow
        system%lines(i)%syrope_tmax_rollback = system%lines(i)%syrope_tmax
      END IF
      ! the stick-slip friction anchors move with every committed step too
      IF (CD_Model_Has_Friction(system%lines(i))) &
        system%lines(i)%fr_anchor_rollback = system%lines(i)%fr_anchor
      ! the VIV shedding phase and cross-flow mean squares advance every committed step
      IF (system%lines(i)%has_viv) THEN
        system%lines(i)%viv_phi_rollback = system%lines(i)%viv_phi
        system%lines(i)%viv_ms_rollback = system%lines(i)%viv_ms
      END IF
    END DO
  END SUBROUTINE save_line_states

  SUBROUTINE restore_line_states(system)
    TYPE(CD_SystemType), INTENT(INOUT) :: system
    INTEGER :: i

    DO i = 1, system%n_lines
      IF (.NOT. (ALLOCATED(system%lines(i)%q_rollback) .AND. ALLOCATED(system%lines(i)%v_rollback) .AND. &
                 ALLOCATED(system%lines(i)%a_rollback))) CYCLE
      system%lines(i)%q = system%lines(i)%q_rollback
      system%lines(i)%v = system%lines(i)%v_rollback
      system%lines(i)%a = system%lines(i)%a_rollback
      system%lines(i)%audit_hmax = system%lines(i)%audit_hmax_rollback
      system%lines(i)%sub_stats = system%lines(i)%sub_stats_rollback
      system%lines(i)%l0_c = system%lines(i)%l0_c_rollback
      system%lines(i)%l0_dot_c = system%lines(i)%l0_dot_c_rollback
      IF (system%lines(i)%has_viscoelastic) &
        system%lines(i)%ve_dl_1 = system%lines(i)%ve_dl_1_rollback
      IF (system%lines(i)%has_syrope) THEN
        system%lines(i)%syrope_slow = system%lines(i)%syrope_slow_rollback
        system%lines(i)%syrope_tmax = system%lines(i)%syrope_tmax_rollback
      END IF
      IF (CD_Model_Has_Friction(system%lines(i))) &
        system%lines(i)%fr_anchor = system%lines(i)%fr_anchor_rollback
      IF (system%lines(i)%has_viv) THEN
        system%lines(i)%viv_phi = system%lines(i)%viv_phi_rollback
        system%lines(i)%viv_ms = system%lines(i)%viv_ms_rollback
        system%lines(i)%viv_phi_eval = system%lines(i)%viv_phi
      END IF
    END DO
  END SUBROUTINE restore_line_states

  PURE SUBROUTINE pack_viv(line, buf)
    !! A line's committed VIV state as 3 reals per node: the phases, then the two mean
    !! squares per node (the size of the line's q).
    TYPE(CD_ModelType), INTENT(IN) :: line
    REAL(wp), INTENT(OUT) :: buf(:)
    INTEGER :: nn
    nn = SIZE(line%viv_phi)
    buf(1:nn) = line%viv_phi
    buf(nn + 1:3*nn) = RESHAPE(line%viv_ms, [2*nn])
  END SUBROUTINE pack_viv

  PURE SUBROUTINE unpack_viv(line, buf)
    !! Inverse of pack_viv; the in-step phase returns to the committed one.
    TYPE(CD_ModelType), INTENT(INOUT) :: line
    REAL(wp), INTENT(IN) :: buf(:)
    INTEGER :: nn
    nn = SIZE(line%viv_phi)
    line%viv_phi = buf(1:nn)
    line%viv_ms = RESHAPE(buf(nn + 1:3*nn), [2, nn])
    line%viv_phi_eval = line%viv_phi
  END SUBROUTINE unpack_viv

  SUBROUTINE restore_failed_step(system, failed_stat, msg, converged, stalled, n_iter, ErrStat, ErrMsg)
    TYPE(CD_SystemType), INTENT(INOUT) :: system
    INTEGER, INTENT(IN) :: failed_stat
    CHARACTER(*), INTENT(IN) :: msg
    LOGICAL, INTENT(OUT) :: converged, stalled
    INTEGER, INTENT(OUT) :: n_iter
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg

    CALL restore_line_states(system)
    converged = .FALSE.
    stalled = .FALSE.
    n_iter = 0
    ErrStat = system_status_from_model(failed_stat)
    ErrMsg = 'CableDyn_System: '//TRIM(msg)
  END SUBROUTINE restore_failed_step

  PURE INTEGER FUNCTION system_status_from_model(model_stat) RESULT(system_stat)
    !! Map a per-line model status onto the system namespace at a failed-step rollback, preserving a
    !! propagated allocation failure as CD_SYSTEM_ALLOCFAIL; every other line failure is a solve
    !! failure at the system level.
    INTEGER, INTENT(IN) :: model_stat
    IF (model_stat == CD_MODEL_ALLOCFAIL) THEN
      system_stat = CD_SYSTEM_ALLOCFAIL
    ELSE
      system_stat = CD_SYSTEM_SOLVEFAIL
    END IF
  END FUNCTION system_status_from_model

  SUBROUTINE restore_failed_dynamic_points(system, old_points, failed_stat, failed_msg, ErrStat, ErrMsg)
    TYPE(CD_SystemType), INTENT(INOUT) :: system
    TYPE(CD_SystemPointType), INTENT(IN) :: old_points(:)
    INTEGER, INTENT(IN) :: failed_stat
    CHARACTER(*), INTENT(IN) :: failed_msg
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg

    ! Roll the lines back to the pre-scatter snapshot taken by the dynamic-point step's
    ! CD_Update_System_CoupledMotion, so a failure after the prescribed-motion scatter does
    ! not leave the lines advanced while the points are restored.
    CALL restore_line_states(system)
    system%points = old_points
    ErrStat = failed_stat
    ErrMsg = failed_msg
  END SUBROUTINE restore_failed_dynamic_points

  SUBROUTINE fail(ErrStat, ErrMsg, msg)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    CHARACTER(*), INTENT(IN) :: msg
    ErrStat = CD_SYSTEM_BADINPUT
    ErrMsg = 'CableDyn_System: '//msg
  END SUBROUTINE fail

  SUBROUTINE alloc_fail(ErrStat, ErrMsg, context)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    CHARACTER(*), INTENT(IN) :: context

    ErrStat = CD_SYSTEM_ALLOCFAIL
    ErrMsg = 'CableDyn_System: '//TRIM(context)//' allocation failed'
  END SUBROUTINE alloc_fail

  SUBROUTINE CD_System_Snapshot(system, ErrStat, ErrMsg)
    !! Capture the committed system state (every line's q/v/a/f_ext + every point) into
    !! the system-owned snapshot buffers (see the type note: the aggregate
    !! stage-then-commit contract). Buffers allocate on first use and are reused.
    TYPE(CD_SystemType), INTENT(INOUT) :: system
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    INTEGER :: i, lo, hi, ntot
    ErrStat = CD_SYSTEM_OK
    ErrMsg = ''
    IF (.NOT. system%initialized) THEN
      ErrStat = CD_SYSTEM_NOT_INITIALIZED
      ErrMsg = 'CableDyn_System: system is not initialized'
      RETURN
    END IF
    ntot = 0
    DO i = 1, system%n_lines
      ntot = ntot + SIZE(system%lines(i)%q)
    END DO
    IF (.NOT. ALLOCATED(system%snap_q)) THEN
      ALLOCATE (system%snap_q(ntot), system%snap_v(ntot), system%snap_a(ntot), &
                system%snap_fext(ntot))
      ! a model-only system (CD_Init_System_From_Models) carries no points array at
      ! all -- snapshot points only where they exist
      IF (ALLOCATED(system%points)) ALLOCATE (system%snap_points(SIZE(system%points)))
      IF (ALLOCATED(system%bindings)) ALLOCATE (system%snap_bindings(SIZE(system%bindings)))
      IF (ALLOCATED(system%coupled_dof_map)) ALLOCATE (system%snap_map(SIZE(system%coupled_dof_map)))
      BLOCK
        INTEGER :: netot
        netot = 0
        DO i = 1, system%n_lines
          netot = netot + SIZE(system%lines(i)%l0)
        END DO
        ALLOCATE (system%snap_l0(netot), system%snap_l0_dot(netot), system%snap_fbase(ntot), &
                  system%snap_l0_c(netot), system%snap_l0_dot_c(netot), &
                  system%snap_ve_dl_1(netot), system%snap_syrope_slow(netot), &
                  system%snap_syrope_tmax(netot), system%snap_fr_anchor(ntot), system%snap_viv(ntot))
      END BLOCK
    END IF
    lo = 1
    DO i = 1, system%n_lines
      hi = lo + SIZE(system%lines(i)%q) - 1
      system%snap_q(lo:hi) = system%lines(i)%q
      system%snap_v(lo:hi) = system%lines(i)%v
      system%snap_a(lo:hi) = system%lines(i)%a
      system%snap_fext(lo:hi) = system%lines(i)%f_ext
      ! friction anchors in the first two thirds of the line's own slice
      IF (CD_Model_Has_Friction(system%lines(i))) &
        system%snap_fr_anchor(lo:lo + 2*SIZE(system%lines(i)%fr_anchor, 2) - 1) = &
        RESHAPE(system%lines(i)%fr_anchor, [2*SIZE(system%lines(i)%fr_anchor, 2)])
      IF (system%lines(i)%has_viv) CALL pack_viv(system%lines(i), system%snap_viv(lo:hi))
      lo = hi + 1
    END DO
    IF (.NOT. ALLOCATED(system%snap_sub)) ALLOCATE (system%snap_sub(system%n_lines))
    DO i = 1, system%n_lines
      system%snap_sub(i) = system%lines(i)%sub_stats
    END DO
    IF (ALLOCATED(system%points)) system%snap_points = system%points
    IF (ALLOCATED(system%bindings)) system%snap_bindings = system%bindings
    IF (ALLOCATED(system%coupled_dof_map)) system%snap_map = system%coupled_dof_map
    BLOCK
      INTEGER :: le, he, ne_i
      le = 1
      lo = 1
      system%snap_fbase = CD_ZERO
      system%snap_ve_dl_1 = CD_ZERO
      system%snap_syrope_slow = CD_ZERO
      system%snap_syrope_tmax = CD_ZERO
      DO i = 1, system%n_lines
        ne_i = SIZE(system%lines(i)%l0)
        he = le + ne_i - 1
        system%snap_l0(le:he) = system%lines(i)%l0
        system%snap_l0_dot(le:he) = system%lines(i)%l0_dot
        system%snap_l0_c(le:he) = system%lines(i)%l0_c
        system%snap_l0_dot_c(le:he) = system%lines(i)%l0_dot_c
        IF (system%lines(i)%has_viscoelastic) &
          system%snap_ve_dl_1(le:he) = system%lines(i)%ve_dl_1
        IF (system%lines(i)%has_syrope) THEN
          system%snap_syrope_slow(le:he) = system%lines(i)%syrope_slow
          system%snap_syrope_tmax(le:he) = system%lines(i)%syrope_tmax
        END IF
        hi = lo + SIZE(system%lines(i)%q) - 1
        IF (ALLOCATED(system%lines(i)%f_ext_dist_base)) &
          system%snap_fbase(lo:hi) = system%lines(i)%f_ext_dist_base
        le = he + 1
        lo = hi + 1
      END DO
    END BLOCK
    system%snap_valid = .TRUE.
  END SUBROUTINE CD_System_Snapshot

  SUBROUTINE CD_System_Restore(system, ErrStat, ErrMsg)
    !! Restore the committed system state from the last CD_System_Snapshot. Fails closed
    !! if no valid snapshot exists.
    TYPE(CD_SystemType), INTENT(INOUT) :: system
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    INTEGER :: i, lo, hi
    ErrStat = CD_SYSTEM_OK
    ErrMsg = ''
    IF (.NOT. system%initialized) THEN
      ErrStat = CD_SYSTEM_NOT_INITIALIZED
      ErrMsg = 'CableDyn_System: system is not initialized'
      RETURN
    END IF
    IF (.NOT. system%snap_valid) THEN
      ErrStat = CD_SYSTEM_BADINPUT
      ErrMsg = 'CableDyn_System: restore has no valid snapshot'
      RETURN
    END IF
    lo = 1
    DO i = 1, system%n_lines
      hi = lo + SIZE(system%lines(i)%q) - 1
      system%lines(i)%q = system%snap_q(lo:hi)
      system%lines(i)%v = system%snap_v(lo:hi)
      system%lines(i)%a = system%snap_a(lo:hi)
      system%lines(i)%f_ext = system%snap_fext(lo:hi)
      IF (CD_Model_Has_Friction(system%lines(i))) &
        system%lines(i)%fr_anchor = RESHAPE(system%snap_fr_anchor(lo:lo + 2*SIZE(system%lines(i)%fr_anchor, 2) - 1), &
                                            [2, SIZE(system%lines(i)%fr_anchor, 2)])
      IF (system%lines(i)%has_viv) CALL unpack_viv(system%lines(i), system%snap_viv(lo:hi))
      lo = hi + 1
    END DO
    IF (ALLOCATED(system%snap_sub)) THEN
      DO i = 1, system%n_lines
        system%lines(i)%sub_stats = system%snap_sub(i)
      END DO
    END IF
    IF (ALLOCATED(system%snap_points)) system%points = system%snap_points
    ! Roll the detach topology back with the states: a failure fired after the
    ! snapshot un-fires (its row will re-trigger on the re-advance).
    IF (ALLOCATED(system%snap_bindings)) system%bindings = system%snap_bindings
    IF (ALLOCATED(system%snap_map)) system%coupled_dof_map = system%snap_map
    ! Roll the LENGTH-derived state back too (active line control): restore l0 and
    ! l0_dot, rebuild the mass and any recompute-capable seabed coefficients from
    ! the restored lengths, and restore the distributed-load remainder. A line
    ! whose lengths never moved skips the rebuilds (bit-inert on control-free runs).
    IF (ALLOCATED(system%snap_l0)) THEN
      BLOCK
        INTEGER :: le, he, ne_i, es2
        CHARACTER(1024) :: em2
        le = 1
        lo = 1
        DO i = 1, system%n_lines
          ne_i = SIZE(system%lines(i)%l0)
          he = le + ne_i - 1
          hi = lo + SIZE(system%lines(i)%q) - 1
          system%lines(i)%l0_dot = system%snap_l0_dot(le:he)
          system%lines(i)%l0_c = system%snap_l0_c(le:he)
          system%lines(i)%l0_dot_c = system%snap_l0_dot_c(le:he)
          IF (system%lines(i)%has_viscoelastic) &
            system%lines(i)%ve_dl_1 = system%snap_ve_dl_1(le:he)
          IF (system%lines(i)%has_syrope) THEN
            system%lines(i)%syrope_slow = system%snap_syrope_slow(le:he)
            system%lines(i)%syrope_tmax = system%snap_syrope_tmax(le:he)
          END IF
          IF (ALLOCATED(system%lines(i)%f_ext_dist_base)) &
            system%lines(i)%f_ext_dist_base = system%snap_fbase(lo:hi)
          IF (MAXVAL(ABS(system%lines(i)%l0 - system%snap_l0(le:he))) > CD_ZERO) THEN
            ! The consistent mass follows l0 implicitly (the step rebuilds its mass band when the
            ! lengths change); only the length-dependent seabed coefficients need a rebuild.
            system%lines(i)%l0 = system%snap_l0(le:he)
            IF (system%lines(i)%has_seabed .AND. system%lines(i)%has_seabed_recompute) THEN
              CALL CD_Nodal_Seabed_Stiffness(system%lines(i)%seabed_kbot, &
                                             system%lines(i)%seabed_diameter_elem, system%lines(i)%l0, &
                                             system%lines(i)%seabed_kn, es2, em2)
              IF (es2 /= 0) THEN
                CALL fail(ErrStat, ErrMsg, 'restore: seabed rebuild failed: '//TRIM(em2))
                RETURN
              END IF
              IF (ALLOCATED(system%lines(i)%seabed_cn)) &
                system%lines(i)%seabed_cn = system%lines(i)%seabed_kn*system%lines(i)%seabed_cn_over_kn
            END IF
          END IF
          le = he + 1
          lo = hi + 1
        END DO
      END BLOCK
    END IF
  END SUBROUTINE CD_System_Restore

  SUBROUTINE CD_Get_System_Substep_Counts(system, calls, events, max_used, capped, fallbacks)
    !! The rotation- and snap-resolved sub-stepping diagnostics of the EI=0 lines
    !! (CD_Get_Model_Substep_Counts) summed over the lines (max_used: the largest count).
    TYPE(CD_SystemType), INTENT(IN) :: system
    INTEGER(int64), INTENT(OUT) :: calls, events, capped, fallbacks
    INTEGER, INTENT(OUT) :: max_used
    INTEGER(int64) :: c, e, k, f
    INTEGER :: i, m
    calls = 0; events = 0; max_used = 1; capped = 0; fallbacks = 0
    IF (.NOT. ALLOCATED(system%lines)) RETURN
    DO i = 1, SIZE(system%lines)
      CALL CD_Get_Model_Substep_Counts(system%lines(i), c, e, m, k, f)
      calls = calls + c
      events = events + e
      max_used = MAX(max_used, m)
      capped = capped + k
      fallbacks = fallbacks + f
    END DO
  END SUBROUTINE CD_Get_System_Substep_Counts

  PURE FUNCTION CD_System_Fallback_Count(system) RESULT(n)
    !! Subdivision-retry entries of system since its initialisation or the last
    !! CD_System_Fallback_Reset (see CD_SystemType%n_fallback_entries).
    TYPE(CD_SystemType), INTENT(IN) :: system
    INTEGER :: n
    n = system%n_fallback_entries
  END FUNCTION CD_System_Fallback_Count

  SUBROUTINE CD_System_Fallback_Reset(system)
    !! Zero the subdivision-retry tripwire of system (start of a measured window).
    TYPE(CD_SystemType), INTENT(INOUT) :: system
    system%n_fallback_entries = 0
  END SUBROUTINE CD_System_Fallback_Reset

END MODULE CableDyn_System
