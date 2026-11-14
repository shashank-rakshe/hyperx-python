! File: src/CableDyn_OpenFAST_Aggregate.f90
! SPDX-License-Identifier: Apache-2.0
! Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
MODULE CableDyn_OpenFAST_Aggregate
  !! Thin OpenFAST-facing facade that composes ONE deck's EI=0 mooring lines AND its
  !! finite-EI Hermite power cables behind the SAME FMF moving-point boundary the
  !! OpenFAST shell (CableDyn_OF) drives. It owns {0-or-1 CD_FMF (the EI=0 mooring
  !! system) + N CD_HFMF (one per finite-EI cable)} and exposes the CD_FMF-shaped
  !! lifecycle -- Init / NMovingPoints / GetMovingPointMesh / UpdateStates_Moving /
  !! Step_Moving / CalcOutput / End -- with the CD_FMF_* argument signatures EXACTLY, so
  !! the shell can drive the aggregate as a drop-in replacement for a bare CD_FMF.
  !!
  !! MOVING-POINT COLUMN MAP (positional): the aggregate's host-prescribed moving points
  !! run [ EI=0 system moving points | one fairlead per cable ]. Aggregate moving point
  !!   i in 1 .. ncp_sys            -> EI=0 system moving point i, and
  !!   i in ncp_sys+1 .. ncp_sys+ncable -> cable (i - ncp_sys)'s single coupled fairlead,
  !!   next nhost_rod columns               -> the k-th Coupled/Vessel ROD's End A (a 6-DOF host
  !!                                          node: orientation and angular rates in, force and
  !!                                          moment about End A out) or CoupledPinned ROD's pin
  !!                                          (translation in, force out, zero moment; the rod
  !!                                          turns about it on its own),
  !!   last nhost_body columns              -> the k-th Coupled/Vessel BODY's reference point
  !!                                          (6-DOF host node, force and moment about it) or
  !!                                          CoupledPinned BODY's reference point (translation
  !!                                          in, force out, zero moment; the body turns about
  !!                                          it on its own),
  !! with ncp_total = ncp_sys + ncable + nhost_rod + nhost_body. All facade arrays are shaped
  !! (3, ncp_total).
  !!
  !! LOADS-OUT CONTRACT: a cable's loads-out is its constraint reaction at the current
  !! coupled kinematics against the frozen interior (the FMF "loads after the step" /
  !! direct-feedthrough contract). CD_AGG_CalcOutput computes the EI=0 system loads; each
  !! cable's fairlead reaction is read on demand in CD_AGG_GetMovingPointMesh via
  !! CD_HFMF_CalcOutput at the cable's committed state. CD_AGG_UpdateStates_Moving transfers
  !! host kinematics WITHOUT advancing for BOTH the EI=0 system columns and each cable's
  !! coupled node (via CD_HFMF_SetCoupledKinematics), so a CalcOutput taken after a fairlead
  !! move -- but before the next Step -- reflects that move (the instantaneous feedthrough
  !! load), not the last committed step.
  !!
  !! FIXED-DT CONTRACT: the aggregate and its cables are fixed-step by design (the MoorDyn-F
  !! pattern) -- the coupling dt freezes at Init and CD_AGG_Step_Moving fails closed on a step
  !! dt that differs from it (a mismatched size would silently desync the cables, whose
  !! generalised-alpha step carries the Init dt, from the mooring columns).
  USE CableDyn_Precision, ONLY: wp, CD_ZERO, CD_ONE, CD_All_Finite, CD_MIN_TIME_STEP
  USE CableDyn_PathIO, ONLY: CD_Open_Write
  USE CableDyn_FatalReport, ONLY: CD_Fatal_Thread_Init
  USE, INTRINSIC :: ISO_FORTRAN_ENV, ONLY: int64
  USE CableDyn_Linalg, ONLY: CD_Blas_Runtime_Check, CD_LINALG_OK
  USE CableDyn_OpenFAST_FMF, ONLY: CD_FMF_ModuleType, CD_FMF_Init_From_System, CD_FMF_NMovingPoints, &
                                   CD_FMF_GetPointMesh, CD_FMF_UpdateStates, &
                                   CD_FMF_NDynamicPoints, CD_FMF_Refresh_PointMesh, &
                                   CD_FMF_GetMovingPointMesh, CD_FMF_UpdateStates_Moving, CD_FMF_Step_Moving, &
                                   CD_FMF_CalcOutput, CD_FMF_End, CD_FMF_OK, CD_FMF_BADINPUT, &
                                   CD_FMF_NOT_INITIALIZED, CD_FMF_ALLOCFAIL, CD_FMF_Snapshot, CD_FMF_Restore
  USE CableDyn_OpenFAST_HermiteFMF, ONLY: CD_HFMF_ModuleType, CD_HFMF_UpdateStates, CD_HFMF_CalcOutput, &
                                          CD_HFMF_PreflightCoupledKinematics, &
                                          CD_HFMF_SetCoupledKinematics, CD_HFMF_GetCoupledKinematics, &
                                          CD_HFMF_GetEndBKinematics, &
                                          CD_HFMF_End, CD_HFMF_OK, CD_HFMF_BADINPUT, &
                                          CD_HFMF_Snapshot, CD_HFMF_Restore, &
                                          CD_HFMF_Set_Held_Fluid, CD_HFMF_NNodes, CD_HFMF_GetNodePositions, &
                                          CD_HFMF_Set_SegmentLength, CD_HFMF_Refresh_Acceleration
  USE CableDyn_HermiteCableDynamic, ONLY: CD_HermiteCable_Dyn_Profile_Enabled, CD_HermiteCableControlSaveType, &
                                          CD_HermiteCable_Dyn_Save_Control, CD_HermiteCable_Dyn_Restore_Control, &
                                          CD_HCDYN_OK
  USE CableDyn_Model, ONLY: CD_ModelControlSaveType, CD_Recompute_Model_Acceleration, CD_MODEL_OK
  USE CableDyn_DeckDriver, ONLY: CD_DeckAggregateType, CD_Init_Deck_Aggregate, CD_End_Deck_Aggregate, &
                                 CD_DECKDRV_OK, CD_DECKDRV_BADINPUT, CD_Eval_Aggregate_Channel, &
                                 CD_Cable_Deck_Node, &
                                 CD_Channel_Unit, CD_DECK_NAMELEN, CD_LineInitSummary, &
                                 DeckFailure, DeckLine, DeckPoint, CD_Fire_Deck_Failures, &
                                 CD_Replay_Deck_Failures, CD_Check_System_Plausibility, &
                                 CD_Rigid6RuntimeType, CD_Step_Aggregate_Rigid6, CD_Rigid6_NBodies, &
                                 CD_Rigid6_Snapshot, CD_Rigid6_Restore, CD_Rigid6_End, &
                                 CD_Rigid6_MirrorSize, CD_Rigid6_Get_States, CD_Rigid6_Set_States, &
                                 CD_Rigid6_GetRefPositions, CD_Rigid6_SetHeldFluid, &
                                 CD_Rigid6_NHost, CD_Rigid6_SetHostKinematics, CD_Rigid6_GetHostKinematics, &
                                 CD_Rigid6_ScatterHostPoints, CD_Rigid6_HostWrench, CD_Rigid6_Stage, &
                                 CD_Rigid6_Unstage, &
                                 CD_RodRuntimeType, CD_Step_Aggregate_Rod, CD_Rod_NRods, CD_Rod_NStations, &
                                 CD_Rod_Snapshot, CD_Rod_Restore, CD_Rod_End, &
                                 CD_Rod_MirrorSize, CD_Rod_Get_States, CD_Rod_Set_States, CD_Rod_Apply_States, &
                                 CD_Rod_GetFluidPositions, CD_Rod_SetHeldFluid, &
                                 CD_Rod_NHost, CD_Rod_SetHostKinematics, CD_Rod_GetHostKinematics, &
                                 CD_Rod_ScatterHostPoints, CD_Rod_HostWrench, CD_Rod_Stage, CD_Rod_Unstage, &
                                 CD_Rigid6_StartAccelerations, CD_Rod_StartAccelerations, &
                                 CD_Deck_Range_Sample_Aggregate, CD_Deck_Range_Write, &
                                 CD_MotionRuntimeType, CD_Motion_Active, CD_Motion_NColumns, &
                                 CD_Motion_Has_Rotation, CD_Motion_Has_Roll, CD_Motion_Kinematics, &
                                 CD_Motion_Deck_Positions, CD_Motion_End, &
                                 CD_DeckCurrentRuntimeType, CD_Deck_Current_Active, &
                                 CD_Deck_Current_Sample_System, CD_Deck_Current_Sample_Cables, &
                                 CD_Deck_Current_End
  USE CableDyn_RangeOutput, ONLY: CD_RangeSet, CD_Range_End, CD_Range_Has_Graph, CD_Range_Mirror_Size, &
                                  CD_Range_Get_State, CD_Range_Set_State, CD_Range_Discard_Files, CD_RANGE_OK
  USE CableDyn_System, ONLY: CD_Get_System_Substep_Counts, CD_System_NLines, CD_System_Line_NDOF, &
                             CD_System_Fallback_Count, CD_System_Fallback_Reset, &
                             CD_Get_System_Line_State, &
                             CD_Update_System_Line_SegmentLength, CD_Save_System_Line_Control, &
                             CD_Restore_System_Line_Control, &
                             CD_Update_System_Line_Hydro_Fields, CD_SYSTEM_OK, &
                             CD_System_NHydroPoints, CD_Get_System_HydroPoint_Positions, &
                             CD_Set_System_HydroPoint_Fluid
  IMPLICIT NONE
  PRIVATE

  PUBLIC :: CD_AGG_ModuleType
  PUBLIC :: CD_AGG_Init_From_Deck
  PUBLIC :: CD_AGG_NMovingPoints
  PUBLIC :: CD_AGG_NDynamicPoints
  PUBLIC :: CD_AGG_HasRigid6
  PUBLIC :: CD_AGG_HasRod
  PUBLIC :: CD_AGG_HasPoint3
  PUBLIC :: CD_AGG_Fallback_Count, CD_AGG_Fallback_Reset
  PUBLIC :: CD_AGG_Rigid6_MirrorSize, CD_AGG_Get_Rigid6_States, CD_AGG_Set_Rigid6_States
  PUBLIC :: CD_AGG_Rod_MirrorSize, CD_AGG_Get_Rod_States, CD_AGG_Set_Rod_States
  PUBLIC :: CD_AGG_Refresh_PointMesh
  PUBLIC :: CD_AGG_GetMovingPointMesh
  PUBLIC :: CD_AGG_UpdateStates_Moving
  PUBLIC :: CD_AGG_Step_Moving
  PUBLIC :: CD_AGG_Snapshot
  PUBLIC :: CD_AGG_Restore
  PUBLIC :: CD_AGG_NTurbines
  PUBLIC :: CD_AGG_TurbineOfMoving
  PUBLIC :: CD_AGG_NFluidNodes
  PUBLIC :: CD_AGG_GetFluidNodePositions
  PUBLIC :: CD_AGG_SetFluidFields
  PUBLIC :: CD_AGG_CalcOutput
  PUBLIC :: CD_AGG_End
  PUBLIC :: CD_AGG_NFailures
  PUBLIC :: CD_AGG_Get_Substep_Counts
  PUBLIC :: CD_AGG_Get_Failure_Flags, CD_AGG_Set_Failure_Flags
  PUBLIC :: CD_AGG_NCtrlChans, CD_AGG_Apply_LineControl
  PUBLIC :: CD_AGG_IsInitialized
  ! The deck's own prescribed motion on the standalone mixed route (not a coupled-host surface)
  PUBLIC :: CD_AGG_HasMotion, CD_AGG_MotionKinematics, CD_AGG_Refresh_Accelerations
  ! OpenFAST CompMooring=5 output-channel surface (consumed by CableDyn_OF): the deck OUTPUTS
  ! channel count/header/unit for registration, and the per-channel evaluator for CalcOutput.
  PUBLIC :: CD_AGG_NumChannels
  PUBLIC :: CD_AGG_ChannelHeader
  PUBLIC :: CD_AGG_EvalChannel
  PUBLIC :: CD_AGG_WriteStaticProfile
  ! Range graphs of the LINES flag r: the standalone mixed route and the single-turbine OpenFAST
  ! module sample and write them; the accumulated state rides a host's checkpoint
  PUBLIC :: CD_AGG_Reopen_Start
  PUBLIC :: CD_AGG_Range_Sample, CD_AGG_Range_Write, CD_AGG_Range_Discard, CD_AGG_Range_Graphs, &
            CD_AGG_Range_MirrorSize, CD_AGG_Range_Get_State, CD_AGG_Range_Set_State
  PUBLIC :: CD_AGG_GetInitMetadata, CD_AGG_GetInitLine

  ! Status space mirrors CD_FMF_* (and the CD_HFMF_* / CD_DECKDRV_* subsets) so the facade
  ! maps a sub-module status onto the same integer meaning.
  INTEGER, PARAMETER, PUBLIC :: CD_AGG_OK = 0, CD_AGG_BADINPUT = 1, CD_AGG_SOLVEFAIL = 2, &
                                CD_AGG_NOT_INITIALIZED = 3, CD_AGG_ALLOCFAIL = 4
  ! cable_two_ends modes
  INTEGER, PARAMETER :: CABLE_PREFLIGHT = 1, CABLE_SET = 2, CABLE_STEP = 3

  TYPE :: CD_AGG_ModuleType
    !! Owner of the composed {EI=0 system + N Hermite cables} behind the FMF facade.
    TYPE(CD_FMF_ModuleType) :: sys                       ! EI=0 mooring system (valid iff has_sys)
    LOGICAL :: has_sys = .FALSE.
    TYPE(CD_HFMF_ModuleType), ALLOCATABLE :: cables(:)   ! one per finite-EI cable
    ! TRUE returns each finite-EI cable reaction to the host. FALSE leaves the
    ! cable march, environmental loading, and output channels active but zeros
    ! its moving-point load and moment for a controlled one-way comparison.
    LOGICAL :: cable_load_feedback = .TRUE.
    ! Deck OPTION predictLoads: the OpenFAST shell extrapolates the coupled loads between
    ! supercycled solves (TRUE) or holds the last solve's (FALSE)
    LOGICAL :: predict_loads = .TRUE.
    ! Deck OPTION maxStrain: the per-step plausibility bound on the EI=0 system lines.
    REAL(wp) :: max_strain = 0.5_wp
    INTEGER :: ncp_sys = 0                               ! moving points owned by sys
    INTEGER :: ncable = 0                                ! number of cables (= trailing moving points)
    ! Cables with a moving End B (a finite-EI line between two moving points): their count and,
    ! per cable, the moving column of End B (0 for a held End B). The End B columns follow the End
    ! A columns of all cables, in cable order (host rods and bodies, after them, never share a deck
    ! with a finite-EI cable).
    INTEGER :: ncable_b = 0
    INTEGER, ALLOCATABLE :: cable_col_b(:)
    INTEGER :: n_lines = 0, n_points = 0, n_sections = 0
    INTEGER :: n_ei0_lines = 0, n_finite_ei_lines = 0
    TYPE(CD_LineInitSummary), ALLOCATABLE :: init_lines(:)
    REAL(wp) :: dt = CD_ZERO                             ! coupling step, frozen at Init (fixed-dt contract)
    ! Full moving-surface scratch, sized (3, ncp_total) once at Init (no per-step allocation).
    REAL(wp), ALLOCATABLE :: mv_pos(:, :), mv_vel(:, :), mv_acc(:, :), mv_load(:, :), mv_moment(:, :)
    REAL(wp), ALLOCATABLE :: mv_omega(:, :), mv_alpha(:, :)
    REAL(wp), ALLOCATABLE :: mv_orient(:, :, :)
    ! The roll of each moving column of a step (CD_AGG_Step_Moving roll), and the static
    ! imposed twist Phi_0 = Pretwist(B) - Pretwist(A) of each cable restrained in torsion: the
    ! step's imposed twist is Phi_0 - roll.
    REAL(wp), ALLOCATABLE :: mv_roll(:)
    REAL(wp), ALLOCATABLE :: cable_phi0(:)
    ! The deck's own prescribed motion (standalone mixed route; inactive for a coupled host).
    TYPE(CD_MotionRuntimeType) :: motion
    ! The deck's own current (standalone mixed route, Init deck_current; inactive for a coupled
    ! host, which supplies its field through CD_AGG_SetFluidFields): sampled at every node of the
    ! EI = 0 lines and the cables at t = 0 by Init and CD_AGG_Refresh_Accelerations, and at
    ! t_committed before every step (sample_deck_current).
    TYPE(CD_DeckCurrentRuntimeType) :: current
    ! Per-cable status staging lets independent finite-EI cables advance concurrently while
    ! preserving deterministic, cable-order error reporting after the parallel region.
    INTEGER, ALLOCATABLE :: cable_stat(:)
    CHARACTER(1024), ALLOCATABLE :: cable_msg(:)
    ! Host-driven ambient-fluid surface over the EI=0 system's LINE NODES (the sampling
    ! points a coupled host feeds with wave kinematics): nfluid = total line-node count,
    ! fl_off(li) = the node offset of system line li in the flat (3, nfluid) arrays, and
    ! fl_q/v/a the max-line state scratch (sized once at Init; no per-step allocation).
    INTEGER :: nfluid = 0
    LOGICAL :: built_extfluid = .FALSE.   ! Init declared host-driven ambient fluid (external_fluid)
    LOGICAL :: host_wave_enabled = .FALSE.
    LOGICAL :: host_current_enabled = .FALSE.
    REAL(wp), ALLOCATABLE :: host_current_profile_z(:)
    REAL(wp), ALLOCATABLE :: host_current_profile_velocity(:, :)
    ! FAST.Farm: turbine count (0 = plain mode) and the driving turbine per moving slot
    INTEGER :: n_turbines = 0
    INTEGER, ALLOCATABLE :: turbine_of_moving(:)
    INTEGER :: fl_nlines = 0   ! leading fl_off blocks that are EI=0 system lines; then cables/bodies/rods
    INTEGER :: fl_nbody = 0    ! fl_off blocks that are Rigid6 body reference points (1 node each)
    INTEGER :: fl_nrod = 0     ! fl_off blocks that are rigid rods (NumSegs + 1 stations each)
    INTEGER :: fl_nhydropt = 0 ! trailing fl_off blocks that are hydro-active dynamic points (1 node each)
    REAL(wp) :: rho_water = CD_ZERO   ! ambient water density (for the hydro-point fluid contract)
    INTEGER, ALLOCATABLE :: fl_off(:)
    REAL(wp), ALLOCATABLE :: fl_q(:), fl_v(:), fl_a(:)
    ! Deck OUTPUTS channels for the OpenFAST WriteOutput surface (CompMooring=5). channels holds
    ! the validated tokens; chan_units the OrcaFlex unit per channel; line_is_cable / line_obj_index
    ! the deck-line-id -> object map (indexed by deck line id) so a channel resolves to an EI=0
    ! system line or a finite-EI cable. All left unallocated when the deck declares no OUTPUTS, so a
    ! channel-free deck drives exactly the pre-channel moving-point facade (NumChannels = 0).
    CHARACTER(CD_DECK_NAMELEN), ALLOCATABLE :: channels(:)
    CHARACTER(10), ALLOCATABLE :: chan_units(:)
    LOGICAL, ALLOCATABLE :: line_is_cable(:)
    INTEGER, ALLOCATABLE :: line_obj_index(:)
    ! deck point ids of each cable's End A and End B (Point<P>F channels)
    INTEGER, ALLOCATABLE :: cable_points(:, :)
    ! FAILURE runtime table (line failures on the coupled path): rows fire at the
    ! committed time the host threads into CD_AGG_Step_Moving. snap_failures joins
    ! the aggregate snapshot so a correction rewind un-fires rows with the detach
    ! topology (the system snapshot already carries bindings + map).
    TYPE(DeckFailure), ALLOCATABLE :: failures(:)
    TYPE(DeckLine), ALLOCATABLE :: fail_lines(:)
    TYPE(DeckPoint), ALLOCATABLE :: fail_points(:)
    TYPE(DeckFailure), ALLOCATABLE :: snap_failures(:)
    ! Active line control (CONTROL section): flattened channel -> (line, controlled
    ! element, base length) table. The controlled segment is the deck segment at the line's
    ! fairlead-side end (see CD_DeckAggregateType). A finite-EI row (ctrl_is_cable) holds
    ! the cable index, the first of the ctrl_nelem cable elements of that segment and its
    ! base length S; their base lengths sit at ctrl_span_l0(ctrl_span_off + 1:).
    INTEGER :: n_ctrl_chans = 0
    INTEGER, ALLOCATABLE :: ctrl_chan(:), ctrl_line(:), ctrl_elem(:), ctrl_nelem(:)
    REAL(wp), ALLOCATABLE :: ctrl_base_l0(:)
    ! the deck line's unstretched length and segment count, MoorDyn-F's UnstrLen and N
    REAL(wp), ALLOCATABLE :: ctrl_unstr_len(:)
    INTEGER, ALLOCATABLE :: ctrl_nsegs(:)
    ! per row, the object it changes as it was before the change (CD_AGG_Apply_LineControl)
    TYPE(CD_HermiteCableControlSaveType), ALLOCATABLE :: ctrl_cable_saved(:)
    TYPE(CD_ModelControlSaveType), ALLOCATABLE :: ctrl_line_saved(:)
    LOGICAL, ALLOCATABLE :: ctrl_is_cable(:)
    INTEGER, ALLOCATABLE :: ctrl_line_id(:), ctrl_span_off(:)
    REAL(wp), ALLOCATABLE :: ctrl_span_l0(:)
    ! Coupled Rigid6 bodies (pure EI=0 deck): the opaque runtime the facade marches over the
    ! EI=0 system each mooring step, in place of the plain moving step. has_rigid6 selects the
    ! body-march branch; the runtime's own snapshot buffer joins the aggregate snapshot/restore.
    ! Point3 buoys among the Free points of the EI=0 system (CD_AGG_HasPoint3).
    LOGICAL :: has_point3 = .FALSE.
    LOGICAL :: has_rigid6 = .FALSE.
    TYPE(CD_Rigid6RuntimeType) :: rigid6
    ! Coupled rigid RODS: the rod twin of the Rigid6 runtime above. has_rod selects the rod-march
    ! branch (mutually exclusive with has_rigid6); its snapshot buffer joins the aggregate snapshot.
    LOGICAL :: has_rod = .FALSE.
    TYPE(CD_RodRuntimeType) :: rod
    ! Range graphs (standalone mixed route, OpenFAST module) and the touchdown references of the TDP<L>
    ! channels, keyed by deck line id. The references are fixed at the converged initial
    ! state (a checkpoint rebuild re-derives the same state), so they carry no step state.
    TYPE(CD_RangeSet) :: ranges
    REAL(wp), ALLOCATABLE :: snap_range(:)   ! the accumulated range graphs at the last CD_AGG_Snapshot
    ! Coupled/Vessel and CoupledPinned rods: the trailing host nodes of the moving surface, and
    ! the full EI=0 coupled-block scratch (3, n_system_coupled_dof/3) their Rod<N>A/B points are
    ! overlaid on.
    INTEGER :: nhost_rod = 0
    INTEGER :: nhost_body = 0   ! Coupled/Vessel and CoupledPinned bodies: the trailing host nodes
    ! Body/rod marches: the host fairleads' t + dt motion as a flat coupled-DOF overlay
    ! (hf_mask marks the moving DOFs), passed into the march as the line step's end motion.
    LOGICAL, ALLOCATABLE :: hf_mask(:)
    REAL(wp), ALLOCATABLE :: hf_q(:), hf_v(:), hf_a(:)
    REAL(wp), ALLOCATABLE :: hb_pos(:, :), hb_vel(:, :), hb_acc(:, :), hb_load(:, :)
    ! The bodies and rods carry the accelerations of a committed step or of a restored state mirror;
    ! until then a transfer of the step-start host kinematics or new host fluid fields re-solve
    ! their start accelerations (start_object_accelerations), so the mirror carries them from
    ! t = 0, in the host's field. snap_objects_committed joins the aggregate snapshot.
    LOGICAL :: objects_committed = .FALSE.
    LOGICAL :: snap_objects_committed = .FALSE.
    LOGICAL :: initialized = .FALSE.
  END TYPE CD_AGG_ModuleType

CONTAINS

  SUBROUTINE CD_AGG_Init_From_Deck(self, deck_path, dt, ErrStat, ErrMsg, env_gravity, env_rho_water, env_wtrdpth, &
                                   ptfm_init, external_fluid, coupled_positions, &
                                   n_turbines, turbine_ref_pos, farm_ptfm_init, forbid_deck_ambient, run_tmax, &
                                   range_files, host_orientation, static_current, prescribed_motion, static_run, &
                                   deck_current, deck_turbines, static_deck_current, range_discard_root)
    !! Build the aggregate from ONE mixed deck: partition its lines into {EI=0 mooring}
    !! and {finite-EI cable}, wrap the mooring subset into a CD_FMF, and own one CD_HFMF
    !! per cable. Same signature philosophy as CD_FMF_Init_From_Deck (host environment
    !! optionals passed through). A pure-mooring deck yields ncable = 0 and a moving surface
    !! bit-for-bit identical to driving CD_FMF_Init_From_Deck directly.
    !! ptfm_init (optional, 6): initial platform displacement [surge..yaw]; every
    !! Coupled/Vessel deck point is rigid-transformed BEFORE any build or static solve,
    !! so the equilibrium is solved at the displaced pose (see CD_Init_Deck_Aggregate).
    !! external_fluid: the host prescribes per-node ambient fluid kinematics each step
    !! through CD_AGG_SetFluidFields; the EI=0 models are built wave-capable at zero
    !! fields (see CD_Init_Deck_Aggregate).
    TYPE(CD_AGG_ModuleType), INTENT(INOUT) :: self
    CHARACTER(*), INTENT(IN) :: deck_path
    REAL(wp), INTENT(IN) :: dt
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    REAL(wp), INTENT(IN), OPTIONAL :: env_gravity, env_rho_water, env_wtrdpth
    REAL(wp), INTENT(IN), OPTIONAL :: run_tmax
    REAL(wp), INTENT(IN), OPTIONAL :: ptfm_init(6)
    LOGICAL, INTENT(IN), OPTIONAL :: external_fluid
    ! coupled_positions (3, n_moving): explicit pre-static placement of the moving
    ! points in aggregate moving-set order (see CD_Init_Deck_Aggregate) -- the
    ! linearization probe's boundary: each init IS a static solve at those positions.
    REAL(wp), INTENT(IN), OPTIONAL :: coupled_positions(:, :)
    ! FAST.Farm mode: see CD_Init_Deck_Aggregate (Turbine<J> vocabulary; turbine-local
    ! deck coordinates transformed by farm_ptfm_init then shifted by turbine_ref_pos
    ! into the farm-global solve frame).
    INTEGER, INTENT(IN), OPTIONAL :: n_turbines
    REAL(wp), INTENT(IN), OPTIONAL :: turbine_ref_pos(:, :)
    REAL(wp), INTENT(IN), OPTIONAL :: farm_ptfm_init(:, :)
    ! forbid_deck_ambient: the caller evaluates no deck waves (and, without deck_current, no
    ! deck current), so reject a deck that declares them (see CD_Init_Deck_Aggregate).
    LOGICAL, INTENT(IN), OPTIONAL :: forbid_deck_ambient
    ! range_files: the caller samples and writes the range graphs of the LINES flag r (CD_AGG_Range_*)
    LOGICAL, INTENT(IN), OPTIONAL :: range_files
    ! range_discard_root: the output root of a run that starts here (see CD_Init_Deck_Aggregate)
    CHARACTER(*), INTENT(IN), OPTIONAL :: range_discard_root
    ! host_orientation: the caller passes the moving-point orientations with every update,
    ! which a finite-EI line restrained in torsion requires (see CD_Init_Deck_Aggregate)
    LOGICAL, INTENT(IN), OPTIONAL :: host_orientation
    ! static_current (4, n): the host's steady current (z, ux, uy, uz by ascending z) for the
    ! static solves only (see CD_Init_Deck_Aggregate)
    REAL(wp), INTENT(IN), OPTIONAL :: static_current(:, :)
    ! prescribed_motion: the caller marches the deck's own motionFile or vesselMotion table
    ! (CD_AGG_MotionKinematics; the standalone driver, see CD_Init_Deck_Aggregate)
    LOGICAL, INTENT(IN), OPTIONAL :: prescribed_motion
    ! static_run: the caller marches no step (the standalone TMax = 0 run; see
    ! CD_Init_Deck_Aggregate)
    LOGICAL, INTENT(IN), OPTIONAL :: static_run
    ! deck_current: the caller marches the deck's own current (the standalone driver; see
    ! CD_Init_Deck_Aggregate): every step samples it at the nodes, at its t_committed
    LOGICAL, INTENT(IN), OPTIONAL :: deck_current
    ! static_deck_current (with external_fluid): the deck's steady current sets the static start
    ! only and the dynamics take the host field alone (see CD_Init_Deck_Aggregate)
    LOGICAL, INTENT(IN), OPTIONAL :: static_deck_current
    ! deck_turbines: the standalone driver runs a TURBINES deck, whose TURBINES rows place the
    ! Turbine<J> points and whose per-turbine records move them (see CD_Init_Deck_Aggregate)
    LOGICAL, INTENT(IN), OPTIONAL :: deck_turbines

    ! Both bundles (about 70 KB together) are built on the heap: initialisation runs on the
    ! thread of the calling host, whose stack size CableDyn does not choose.
    TYPE(CD_AGG_ModuleType), ALLOCATABLE :: candidate
    TYPE(CD_DeckAggregateType), ALLOCATABLE :: parts
    INTEGER :: es, ncp_total, istat, ich
    ! Static mesh-sequencing diagnostics can report several independently attempted
    ! hierarchies. Preserve that context through the aggregate boundary so a user sees
    ! the failing level and resolution metric rather than a clipped generic prefix.
    CHARACTER(2048) :: em

    ErrStat = CD_AGG_OK
    ErrMsg = ''
    ! A LAPACK runtime that cannot be loaded (Windows GNU build) fails here with the load
    ! diagnostic rather than as a singular-system report from the first static solve.
    CALL CD_Blas_Runtime_Check('CableDyn_OpenFAST_Aggregate', es, em)
    IF (es /= CD_LINALG_OK) THEN
      ErrStat = CD_AGG_ALLOCFAIL
      ErrMsg = TRIM(em)
      RETURN
    END IF
    IF (.NOT. (dt > CD_ZERO)) THEN
      ErrStat = CD_AGG_BADINPUT
      ErrMsg = 'CableDyn_OpenFAST_Aggregate: dt must be positive'
      RETURN
    END IF
    IF (dt < CD_MIN_TIME_STEP) THEN
      ErrStat = CD_AGG_BADINPUT
      ErrMsg = 'CableDyn_OpenFAST_Aggregate: dt is below the smallest time step, 1e-100 s: the time '// &
               'integration divides by dt^2'
      RETURN
    END IF
    ALLOCATE (candidate, parts, STAT=istat)
    IF (istat /= 0) THEN
      ErrStat = CD_AGG_ALLOCFAIL
      ErrMsg = 'CableDyn_OpenFAST_Aggregate: cannot allocate the initialisation workspace'
      RETURN
    END IF
    CALL CD_Init_Deck_Aggregate(deck_path, dt, parts, es, em, env_gravity=env_gravity, &
                                env_rho_water=env_rho_water, env_wtrdpth=env_wtrdpth, &
                                ptfm_init=ptfm_init, external_fluid=external_fluid, &
                                coupled_positions=coupled_positions, n_turbines=n_turbines, &
                                turbine_ref_pos=turbine_ref_pos, farm_ptfm_init=farm_ptfm_init, &
                                forbid_deck_ambient=forbid_deck_ambient, run_tmax=run_tmax, &
                                range_files=range_files, host_orientation=host_orientation, &
                                static_current=static_current, prescribed_motion=prescribed_motion, &
                                static_run=static_run, deck_current=deck_current, &
                                deck_turbines=deck_turbines, static_deck_current=static_deck_current, &
                                range_discard_root=range_discard_root)
    IF (PRESENT(external_fluid)) THEN
      candidate%built_extfluid = external_fluid
    END IF
    candidate%host_wave_enabled = parts%host_wave_enabled
    candidate%host_current_enabled = parts%host_current_enabled
    candidate%cable_load_feedback = parts%cable_load_feedback
    candidate%predict_loads = parts%predict_loads
    candidate%max_strain = parts%max_strain
    IF (ALLOCATED(parts%host_current_profile_z)) THEN
      candidate%host_current_profile_z = parts%host_current_profile_z
      candidate%host_current_profile_velocity = parts%host_current_profile_velocity
    END IF
    candidate%n_turbines = parts%n_turbines
    candidate%n_lines = parts%n_lines
    candidate%n_points = parts%n_points
    candidate%n_sections = parts%n_sections
    candidate%n_ei0_lines = parts%n_ei0_lines
    candidate%n_finite_ei_lines = parts%n_finite_ei_lines
    IF (ALLOCATED(parts%init_lines)) CALL MOVE_ALLOC(parts%init_lines, candidate%init_lines)
    IF (ALLOCATED(parts%turbine_of_moving)) THEN
      candidate%turbine_of_moving = parts%turbine_of_moving
    END IF
    IF (es /= CD_DECKDRV_OK) THEN
      CALL map_deck_status(es, em, ErrStat, ErrMsg)
      CALL CD_End_Deck_Aggregate(parts)
      RETURN
    END IF
    ! FAILURE decks: take ownership of the runtime table; CD_AGG_Step_Moving fires
    ! the rows at the committed time the host threads in.
    IF (ALLOCATED(parts%failures)) THEN
      CALL MOVE_ALLOC(parts%failures, candidate%failures)
      candidate%fail_lines = parts%fail_lines
      candidate%fail_points = parts%fail_points
    END IF
    ! CONTROL decks: take ownership of the flattened line-control table.
    candidate%n_ctrl_chans = parts%n_ctrl_chans
    IF (ALLOCATED(parts%ctrl_chan)) THEN
      CALL MOVE_ALLOC(parts%ctrl_chan, candidate%ctrl_chan)
      CALL MOVE_ALLOC(parts%ctrl_line, candidate%ctrl_line)
      CALL MOVE_ALLOC(parts%ctrl_elem, candidate%ctrl_elem)
      CALL MOVE_ALLOC(parts%ctrl_nelem, candidate%ctrl_nelem)
      CALL MOVE_ALLOC(parts%ctrl_base_l0, candidate%ctrl_base_l0)
      CALL MOVE_ALLOC(parts%ctrl_unstr_len, candidate%ctrl_unstr_len)
      CALL MOVE_ALLOC(parts%ctrl_nsegs, candidate%ctrl_nsegs)
      CALL MOVE_ALLOC(parts%ctrl_is_cable, candidate%ctrl_is_cable)
      CALL MOVE_ALLOC(parts%ctrl_line_id, candidate%ctrl_line_id)
      CALL MOVE_ALLOC(parts%ctrl_span_off, candidate%ctrl_span_off)
      CALL MOVE_ALLOC(parts%ctrl_span_l0, candidate%ctrl_span_l0)
    END IF
    ! Coupled Rigid6 decks: take over the opaque body runtime (deep-copied by the intrinsic
    ! assignment; the deck bundle is released in CD_End_Deck_Aggregate below).
    candidate%has_rigid6 = parts%has_rigid6
    IF (parts%has_rigid6) candidate%rigid6 = parts%rigid6
    candidate%has_rod = parts%has_rod
    candidate%has_point3 = parts%has_point3
    IF (parts%has_rod) candidate%rod = parts%rod
    candidate%nhost_rod = 0
    IF (parts%has_rod) candidate%nhost_rod = CD_Rod_NHost(candidate%rod)
    candidate%nhost_body = 0
    IF (parts%has_rigid6) candidate%nhost_body = CD_Rigid6_NHost(candidate%rigid6)
    ! Wrap the EI=0 mooring system (if any) into a CD_FMF module. CD_FMF_Init_From_System
    ! deep-copies the system, so parts%sys is released below.
    candidate%has_sys = parts%has_sys
    candidate%rho_water = parts%rho_water
    IF (parts%has_sys) THEN
      CALL CD_FMF_Init_From_System(candidate%sys, parts%sys, dt, parts%gravity, parts%rho_water, es, em)
      IF (es /= CD_FMF_OK) THEN
        CALL map_fmf_status(es, em, ErrStat, ErrMsg)
        CALL CD_End_Deck_Aggregate(parts)
        CALL CD_AGG_End(candidate, es, em)
        RETURN
      END IF
      candidate%ncp_sys = CD_FMF_NMovingPoints(candidate%sys, es, em)
      IF (es /= CD_FMF_OK) THEN
        CALL map_fmf_status(es, em, ErrStat, ErrMsg)
        CALL CD_End_Deck_Aggregate(parts)
        CALL CD_AGG_End(candidate, es, em)
        RETURN
      END IF
      ! Viscoelastic (ElasticMod > 1) AND Syrope lines are both supported on the
      ! coupled facade: the glue checkpoint mirror carries their per-element history
      ! (viscoelastic dl_1; Syrope slow-spring strain + running-max tension) via
      ! CableDyn_OF pack_state_mirror / reload_interiors_ary. Syrope build sub-cases
      ! the standalone builder rejects (seabed/hydro, composite, finite-EI) fail
      ! closed upstream at the deck build, not at the facade.
    ELSE
      candidate%ncp_sys = 0
    END IF
    ! Take ownership of the built cables by MOVE (not copy): no double-free of the line
    ! workspace, and CD_End_Deck_Aggregate below then sees cables deallocated.
    IF (ALLOCATED(parts%cables)) THEN
      CALL MOVE_ALLOC(parts%cables, candidate%cables)
      candidate%ncable = SIZE(candidate%cables)
      ! A checkpoint restart (CD_HFMF_UnpackMirror) must reproduce the uninterrupted run, and
      ! a cable's carried step factor is not part of its mirror: the coupled cables factor
      ! fresh every step.
      DO ich = 1, candidate%ncable
        candidate%cables(ich)%line%tangent_reuse = .FALSE.
        candidate%cables(ich)%line%tr_valid = .FALSE.
      END DO
    ELSE
      candidate%ncable = 0
    END IF
    ALLOCATE (candidate%cable_col_b(candidate%ncable))
    candidate%cable_col_b = 0
    candidate%ncable_b = 0
    DO ich = 1, candidate%ncable
      IF (.NOT. candidate%cables(ich)%moving_b) CYCLE
      candidate%ncable_b = candidate%ncable_b + 1
      candidate%cable_col_b(ich) = candidate%ncp_sys + candidate%ncable + candidate%ncable_b
    END DO
    IF (candidate%ncable_b > 0 .AND. (candidate%nhost_rod > 0 .OR. candidate%nhost_body > 0)) THEN
      ErrStat = CD_AGG_BADINPUT
      ErrMsg = 'CableDyn_OpenFAST_Aggregate: a finite-EI cable with a moving End B does not share a deck with '// &
               'host-driven rods or bodies'
      CALL CD_End_Deck_Aggregate(parts)
      CALL CD_AGG_End(candidate, es, em)
      RETURN
    END IF
    ! Take the deck OUTPUTS channels + the deck-line-id -> object map (MOVE, then derive the unit
    ! label per channel). CD_Init_Deck_Aggregate populates these ONLY when the deck declares an
    ! OUTPUTS section; a channel-free deck leaves them unallocated, so this module reports
    ! NumChannels = 0 and the coupled run emits no CableDyn WriteOutput columns.
    IF (ALLOCATED(parts%channels)) THEN
      CALL MOVE_ALLOC(parts%channels, candidate%channels)
      ALLOCATE (candidate%chan_units(SIZE(candidate%channels)))
      DO ich = 1, SIZE(candidate%channels)
        candidate%chan_units(ich) = CD_Channel_Unit(candidate%channels(ich))
      END DO
    END IF
    IF (ALLOCATED(parts%line_is_cable)) CALL MOVE_ALLOC(parts%line_is_cable, candidate%line_is_cable)
    IF (ALLOCATED(parts%line_obj_index)) CALL MOVE_ALLOC(parts%line_obj_index, candidate%line_obj_index)
    candidate%ranges = parts%ranges
    candidate%motion = parts%motion
    candidate%current = parts%current
    IF (ALLOCATED(parts%cable_points)) THEN
      CALL MOVE_ALLOC(parts%cable_points, candidate%cable_points)
    ELSE
      ALLOCATE (candidate%cable_points(2, 0))
    END IF
    CALL CD_End_Deck_Aggregate(parts)
    ncp_total = ncp_all(candidate)
    IF ((candidate%has_rod .OR. candidate%has_rigid6) .AND. candidate%has_sys) THEN
      ich = candidate%sys%fast%system%n_system_coupled_dof
      ALLOCATE (candidate%hf_mask(ich), candidate%hf_q(ich), candidate%hf_v(ich), candidate%hf_a(ich), STAT=istat)
      IF (istat /= 0) THEN
        ErrStat = CD_AGG_ALLOCFAIL
        ErrMsg = 'CableDyn_OpenFAST_Aggregate: host fairlead overlay allocation failed'
        CALL CD_AGG_End(candidate, es, em)
        RETURN
      END IF
      candidate%hf_mask = .FALSE.
      candidate%hf_q = CD_ZERO
      candidate%hf_v = CD_ZERO
      candidate%hf_a = CD_ZERO
      DO ich = 1, SIZE(candidate%sys%moving_blocks)
        candidate%hf_mask(3*candidate%sys%moving_blocks(ich) - 2:3*candidate%sys%moving_blocks(ich)) = .TRUE.
      END DO
    END IF
    ! Host rod and body nodes append after the cables; outside farm mode they drive no turbine.
    IF (ncp_total > candidate%ncp_sys + candidate%ncable + candidate%ncable_b .AND. &
        ALLOCATED(candidate%turbine_of_moving)) THEN
      candidate%turbine_of_moving = [candidate%turbine_of_moving, &
                                     (0, ich=1, ncp_total - candidate%ncp_sys - candidate%ncable - candidate%ncable_b)]
    END IF
    IF (ncp_total > candidate%ncp_sys + candidate%ncable + candidate%ncable_b) THEN
      ich = fmf_nblocks(candidate%sys)
      ALLOCATE (candidate%hb_pos(3, ich), candidate%hb_vel(3, ich), candidate%hb_acc(3, ich), &
                candidate%hb_load(3, ich), STAT=istat)
      IF (istat /= 0) THEN
        ErrStat = CD_AGG_ALLOCFAIL
        ErrMsg = 'CableDyn_OpenFAST_Aggregate: host-rod block scratch allocation failed'
        CALL CD_AGG_End(candidate, es, em)
        RETURN
      END IF
    END IF
    ALLOCATE (candidate%mv_pos(3, ncp_total), candidate%mv_vel(3, ncp_total), candidate%mv_acc(3, ncp_total), &
              candidate%mv_load(3, ncp_total), candidate%mv_moment(3, ncp_total), &
              candidate%mv_omega(3, ncp_total), candidate%mv_alpha(3, ncp_total), &
              candidate%mv_orient(3, 3, ncp_total), candidate%mv_roll(ncp_total), &
              candidate%cable_phi0(candidate%ncable), STAT=istat)
    IF (istat /= 0) THEN
      ErrStat = CD_AGG_ALLOCFAIL
      ErrMsg = 'CableDyn_OpenFAST_Aggregate: moving-surface scratch allocation failed'
      CALL CD_AGG_End(candidate, es, em)
      RETURN
    END IF
    candidate%mv_roll = CD_ZERO
    candidate%cable_phi0 = CD_ZERO
    DO ich = 1, candidate%ncable
      IF (candidate%cables(ich)%line%torsion%active) candidate%cable_phi0(ich) = candidate%cables(ich)%line%torsion%phi
    END DO
    IF (candidate%ncable > 0) THEN
      ALLOCATE (candidate%cable_stat(candidate%ncable), candidate%cable_msg(candidate%ncable), STAT=istat)
      IF (istat /= 0) THEN
        ErrStat = CD_AGG_ALLOCFAIL
        ErrMsg = 'CableDyn_OpenFAST_Aggregate: cable status scratch allocation failed'
        CALL CD_AGG_End(candidate, es, em)
        RETURN
      END IF
      candidate%cable_stat = CD_HFMF_OK
      candidate%cable_msg = ''
    END IF
    ! Size the ambient-fluid sampling surface over the EI=0 system's line nodes (the
    ! per-line node offsets + the max-line state scratch). Computed for every build --
    ! the surface is queryable regardless; driving FIELDS into a build without the
    ! wave-capable hydro configuration fails closed at the model layer.
    CALL size_fluid_surface(candidate, ErrStat, ErrMsg)
    IF (ErrStat /= CD_AGG_OK) THEN
      CALL CD_AGG_End(candidate, es, em)
      RETURN
    END IF
    ! the bodies and rods start from their accelerations at the initial state, the host at rest in its
    ! Init pose (the first step's start; the state mirror then carries them from t = 0)
    CALL start_object_accelerations(candidate, ErrStat, ErrMsg)
    IF (ErrStat /= CD_AGG_OK) THEN
      CALL CD_AGG_End(candidate, es, em)
      RETURN
    END IF
    ! the deck's own current at t = 0 at the static state: the EI = 0 lines re-derive their start
    ! accelerations in it and the cables take it as their first held field, as the single-line
    ! routes' t = 0 samples do before their march
    IF (CD_Deck_Current_Active(candidate%current)) THEN
      CALL sample_deck_current(candidate, CD_ZERO, .TRUE., ErrStat, ErrMsg)
      IF (ErrStat /= CD_AGG_OK) THEN
        CALL CD_AGG_End(candidate, es, em)
        RETURN
      END IF
    END IF
    candidate%dt = dt                  ! freeze the coupling step for the fixed-dt Step_Moving guard
    candidate%initialized = .TRUE.
    IF (CD_Motion_Active(candidate%motion)) THEN
      CALL check_motion_columns(candidate, ErrStat, ErrMsg)
      IF (ErrStat /= CD_AGG_OK) THEN
        CALL CD_AGG_End(candidate, es, em)
        RETURN
      END IF
    END IF
    CALL CD_AGG_End(self, es, em)
    self = candidate
    CALL CD_AGG_End(candidate, es, em)
  END SUBROUTINE CD_AGG_Init_From_Deck

  PURE INTEGER FUNCTION CD_AGG_Fallback_Count(self) RESULT(n)
    !! Subdivision-retry entries of the EI = 0 system step since its initialisation or the
    !! last CD_AGG_Fallback_Reset (CD_System_Fallback_Count); 0 without an EI = 0 system.
    TYPE(CD_AGG_ModuleType), INTENT(IN) :: self
    n = 0
    IF (self%has_sys) n = CD_System_Fallback_Count(self%sys%fast%system)
  END FUNCTION CD_AGG_Fallback_Count

  SUBROUTINE CD_AGG_Fallback_Reset(self)
    !! Zero the subdivision-retry tripwire of the EI = 0 system (start of a measured window).
    TYPE(CD_AGG_ModuleType), INTENT(INOUT) :: self
    IF (self%has_sys) CALL CD_System_Fallback_Reset(self%sys%fast%system)
  END SUBROUTINE CD_AGG_Fallback_Reset

  INTEGER FUNCTION CD_AGG_NMovingPoints(self, ErrStat, ErrMsg) RESULT(n)
    !! Total host-prescribed (moving) points: the EI=0 system's moving points followed by
    !! one fairlead per cable.
    TYPE(CD_AGG_ModuleType), INTENT(IN) :: self
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg

    n = 0
    IF (.NOT. require_initialized(self, ErrStat, ErrMsg)) RETURN
    n = ncp_all(self)
  END FUNCTION CD_AGG_NMovingPoints

  INTEGER FUNCTION CD_AGG_NTurbines(self) RESULT(n)
    !! FAST.Farm turbine count the aggregate was built with (0 = plain mode).
    TYPE(CD_AGG_ModuleType), INTENT(IN) :: self
    n = 0
    IF (self%initialized) n = self%n_turbines
  END FUNCTION CD_AGG_NTurbines

  SUBROUTINE CD_AGG_TurbineOfMoving(self, turbine_of, ErrStat, ErrMsg)
    !! Per moving slot (aggregate moving-set order), the driving turbine (0 in plain
    !! mode) -- the map the OpenFAST shell uses to build per-turbine meshes over the
    !! flat moving surface.
    TYPE(CD_AGG_ModuleType), INTENT(IN) :: self
    INTEGER, INTENT(OUT) :: turbine_of(:)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    IF (.NOT. require_initialized(self, ErrStat, ErrMsg)) RETURN
    IF (.NOT. ALLOCATED(self%turbine_of_moving)) THEN
      ErrStat = CD_AGG_BADINPUT
      ErrMsg = 'CableDyn_OpenFAST_Aggregate: the turbine-of-moving map was not built'
      RETURN
    END IF
    IF (SIZE(turbine_of) /= SIZE(self%turbine_of_moving)) THEN
      ErrStat = CD_AGG_BADINPUT
      ErrMsg = 'CableDyn_OpenFAST_Aggregate: turbine_of must be sized n_moving'
      RETURN
    END IF
    turbine_of = self%turbine_of_moving
    ErrStat = CD_AGG_OK
    ErrMsg = ''
  END SUBROUTINE CD_AGG_TurbineOfMoving

  SUBROUTINE CD_AGG_GetMovingPointMesh(self, position, velocity, acceleration, load, ErrStat, ErrMsg, &
                                       orientation, moment, angular_velocity, angular_acceleration, cable_loads)
    !! Copy the moving-point state and loads out. System columns come from
    !! CD_FMF_GetMovingPointMesh; each cable column carries its coupled-node
    !! position/velocity/acceleration (committed state) and its fairlead reaction from
    !! CD_HFMF_CalcOutput. Arrays are shaped (3, ncp_total) in aggregate moving-set order.
    !!
    !! CACHE CONTRACT (explicit -- do not reintroduce glue-rate load probes): the cable
    !! fairlead reactions are computed ON DEMAND at the committed state on EVERY call;
    !! this routine holds no cache of its own. The intended cadence is ONE call per
    !! mooring step (after CD_AGG_Step_Moving + CD_AGG_CalcOutput). A supercycled caller
    !! running at a faster glue rate must hold its own committed-loads cache KEYED ON
    !! SOLVE COMMITS -- the OpenFAST CompMooring = 5 shell's last_solve_n pattern (a
    !! cache keyed on glue steps is bit-identical but saves nothing; calling this
    !! routine itself at the glue rate re-evaluates every cable reaction per call).
    TYPE(CD_AGG_ModuleType), INTENT(INOUT) :: self
    REAL(wp), INTENT(OUT) :: position(:, :), velocity(:, :), acceleration(:, :), load(:, :)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    REAL(wp), INTENT(OUT), OPTIONAL :: orientation(:, :, :), moment(:, :)
    REAL(wp), INTENT(OUT), OPTIONAL :: angular_velocity(:, :), angular_acceleration(:, :)
    ! .FALSE. skips the reactions of the finite-EI cables (one full residual assembly each) and
    ! returns their load and moment columns as zero: for a caller that wants only the
    ! kinematics, such as the OpenFAST CalcOutput saving the committed kinematics. The
    ! reactions write only the cable's scratch, so the other outputs are unchanged.
    LOGICAL, INTENT(IN), OPTIONAL :: cable_loads

    INTEGER :: c, col, colb, es
    REAL(wp) :: y_fair(3), y_b(3), m_a(3), m_b(3)
    LOGICAL :: want_cable_loads
    CHARACTER(1024) :: em

    want_cable_loads = .TRUE.
    IF (PRESENT(cable_loads)) want_cable_loads = cable_loads
    position = CD_ZERO
    velocity = CD_ZERO
    acceleration = CD_ZERO
    load = CD_ZERO
    IF (PRESENT(orientation)) orientation = CD_ZERO
    IF (PRESENT(moment)) moment = CD_ZERO
    IF (PRESENT(angular_velocity)) angular_velocity = CD_ZERO
    IF (PRESENT(angular_acceleration)) angular_acceleration = CD_ZERO
    IF (.NOT. require_initialized(self, ErrStat, ErrMsg)) RETURN
    IF (.NOT. (moving_cols_ok(position, self) .AND. moving_cols_ok(velocity, self) .AND. &
               moving_cols_ok(acceleration, self) .AND. moving_cols_ok(load, self))) THEN
      ErrStat = CD_AGG_BADINPUT
      ErrMsg = 'CableDyn_OpenFAST_Aggregate: moving-point arrays must be shaped (3, ncp_total)'
      RETURN
    END IF
    IF (PRESENT(orientation)) THEN
      IF (SIZE(orientation, 1) /= 3 .OR. SIZE(orientation, 2) /= 3 .OR. &
          SIZE(orientation, 3) /= ncp_all(self)) THEN
        ErrStat = CD_AGG_BADINPUT
        ErrMsg = 'CableDyn_OpenFAST_Aggregate: orientation must be shaped (3,3,ncp_total)'
        RETURN
      END IF
      DO col = 1, ncp_all(self)
        orientation(1, 1, col) = CD_ONE
        orientation(2, 2, col) = CD_ONE
        orientation(3, 3, col) = CD_ONE
      END DO
    END IF
    IF (PRESENT(moment)) THEN
      IF (.NOT. moving_cols_ok(moment, self)) THEN
        ErrStat = CD_AGG_BADINPUT
        ErrMsg = 'CableDyn_OpenFAST_Aggregate: moment must be shaped (3,ncp_total)'
        RETURN
      END IF
    END IF
    IF (PRESENT(angular_velocity) .NEQV. PRESENT(angular_acceleration)) THEN
      ErrStat = CD_AGG_BADINPUT
      ErrMsg = 'CableDyn_OpenFAST_Aggregate: angular velocity and acceleration outputs must be supplied together'
      RETURN
    END IF
    IF (PRESENT(angular_velocity)) THEN
      IF (.NOT. (moving_cols_ok(angular_velocity, self) .AND. moving_cols_ok(angular_acceleration, self))) THEN
        ErrStat = CD_AGG_BADINPUT
        ErrMsg = 'CableDyn_OpenFAST_Aggregate: angular kinematics must be shaped (3,ncp_total)'
        RETURN
      END IF
    END IF
    self%mv_omega = CD_ZERO
    self%mv_alpha = CD_ZERO
    self%mv_orient = CD_ZERO
    DO col = 1, ncp_all(self)
      self%mv_orient(1, 1, col) = CD_ONE
      self%mv_orient(2, 2, col) = CD_ONE
      self%mv_orient(3, 3, col) = CD_ONE
    END DO
    IF (self%has_sys) THEN
      CALL CD_FMF_GetMovingPointMesh(self%sys, self%mv_pos(:, 1:self%ncp_sys), self%mv_vel(:, 1:self%ncp_sys), &
                                     self%mv_acc(:, 1:self%ncp_sys), self%mv_load(:, 1:self%ncp_sys), es, em)
      IF (es /= CD_FMF_OK) THEN
        CALL map_fmf_status(es, em, ErrStat, ErrMsg)
        RETURN
      END IF
      position(:, 1:self%ncp_sys) = self%mv_pos(:, 1:self%ncp_sys)
      velocity(:, 1:self%ncp_sys) = self%mv_vel(:, 1:self%ncp_sys)
      acceleration(:, 1:self%ncp_sys) = self%mv_acc(:, 1:self%ncp_sys)
      load(:, 1:self%ncp_sys) = self%mv_load(:, 1:self%ncp_sys)
    END IF
    DO c = 1, self%ncable
      col = self%ncp_sys + c
      ! The getter returns the coupled node's kinematics in the GLOBAL frame (the cable
      ! may solve in a heading-rotated local frame; the HFMF boundary owns the rotation).
      CALL CD_HFMF_GetCoupledKinematics(self%cables(c), position(:, col), velocity(:, col), &
                                        acceleration(:, col), es, em, self%mv_orient(:, :, col), &
                                        self%mv_omega(:, col), self%mv_alpha(:, col))
      IF (es /= CD_HFMF_OK) THEN
        CALL map_hfmf_status(es, em, ErrStat, ErrMsg)
        RETURN
      END IF
      IF (self%cable_col_b(c) > 0) THEN
        ! a moving End B: its column carries node 1's kinematics and the load on End B's host,
        ! both ends' loads from one evaluation of the committed state
        colb = self%cable_col_b(c)
        CALL CD_HFMF_GetEndBKinematics(self%cables(c), position(:, colb), velocity(:, colb), &
                                       acceleration(:, colb), es, em, self%mv_orient(:, :, colb), &
                                       self%mv_omega(:, colb), self%mv_alpha(:, colb))
        IF (es /= CD_HFMF_OK) THEN
          CALL map_hfmf_status(es, em, ErrStat, ErrMsg)
          RETURN
        END IF
        IF (.NOT. want_cable_loads) CYCLE
        CALL CD_HFMF_CalcOutput(self%cables(c), y_fair, es, em, y_moment=m_a, y_end_b=y_b, y_moment_b=m_b)
        IF (es /= CD_HFMF_OK) THEN
          CALL map_hfmf_status(es, em, ErrStat, ErrMsg)
          RETURN
        END IF
        load(:, col) = y_fair
        load(:, colb) = y_b
        IF (PRESENT(moment)) THEN
          moment(:, col) = m_a
          moment(:, colb) = m_b
        END IF
        IF (.NOT. self%cable_load_feedback) THEN
          load(:, col) = CD_ZERO
          load(:, colb) = CD_ZERO
          IF (PRESENT(moment)) THEN
            moment(:, col) = CD_ZERO
            moment(:, colb) = CD_ZERO
          END IF
        END IF
        CYCLE
      END IF
      IF (.NOT. want_cable_loads) CYCLE
      IF (PRESENT(moment)) THEN
        CALL CD_HFMF_CalcOutput(self%cables(c), y_fair, es, em, moment(:, col))
      ELSE
        CALL CD_HFMF_CalcOutput(self%cables(c), y_fair, es, em)
      END IF
      IF (es /= CD_HFMF_OK) THEN
        CALL map_hfmf_status(es, em, ErrStat, ErrMsg)
        RETURN
      END IF
      load(:, col) = y_fair
      IF (.NOT. self%cable_load_feedback) THEN
        load(:, col) = CD_ZERO
        IF (PRESENT(moment)) moment(:, col) = CD_ZERO
      END IF
    END DO
    ! Host rod nodes: End A kinematics of each Coupled/Vessel rod and the wrench about End A
    ! from the system's current coupled-point loads (the CD_AGG_CalcOutput evaluation); the pin
    ! of a CoupledPinned rod and its force, with zero moment.
    IF (self%nhost_rod > 0) THEN
      CALL CD_FMF_GetPointMesh(self%sys, self%hb_pos, self%hb_vel, self%hb_acc, self%hb_load, es, em)
      IF (es /= CD_FMF_OK) THEN
        CALL map_fmf_status(es, em, ErrStat, ErrMsg)
        RETURN
      END IF
      DO c = 1, self%nhost_rod
        col = self%ncp_sys + self%ncable + self%ncable_b + c
        CALL CD_Rod_GetHostKinematics(self%rod, c, position(:, col), velocity(:, col), acceleration(:, col), &
                                      self%mv_orient(:, :, col), self%mv_omega(:, col), self%mv_alpha(:, col))
        CALL CD_Rod_HostWrench(self%sys%fast%system, self%rod, self%hb_load, c, load(:, col), y_fair, es, em)
        IF (es /= CD_DECKDRV_OK) THEN
          CALL map_deck_status(es, em, ErrStat, ErrMsg)
          RETURN
        END IF
        IF (PRESENT(moment)) moment(:, col) = y_fair
      END DO
    END IF
    ! Host body nodes: the reference-point kinematics and the wrench about it (a CoupledPinned
    ! body: its force, with zero moment).
    IF (self%nhost_body > 0) THEN
      CALL CD_FMF_GetPointMesh(self%sys, self%hb_pos, self%hb_vel, self%hb_acc, self%hb_load, es, em)
      IF (es /= CD_FMF_OK) THEN
        CALL map_fmf_status(es, em, ErrStat, ErrMsg)
        RETURN
      END IF
      DO c = 1, self%nhost_body
        col = self%ncp_sys + self%ncable + self%ncable_b + self%nhost_rod + c
        CALL CD_Rigid6_GetHostKinematics(self%rigid6, c, position(:, col), velocity(:, col), acceleration(:, col), &
                                         self%mv_orient(:, :, col), self%mv_omega(:, col), self%mv_alpha(:, col))
        CALL CD_Rigid6_HostWrench(self%sys%fast%system, self%rigid6, self%hb_load, c, load(:, col), y_fair, es, em)
        IF (es /= CD_DECKDRV_OK) THEN
          CALL map_deck_status(es, em, ErrStat, ErrMsg)
          RETURN
        END IF
        IF (PRESENT(moment)) moment(:, col) = y_fair
      END DO
    END IF
    IF (PRESENT(orientation)) orientation = self%mv_orient
    IF (PRESENT(angular_velocity)) THEN
      angular_velocity = self%mv_omega
      angular_acceleration = self%mv_alpha
    END IF
    ErrStat = CD_AGG_OK
    ErrMsg = ''
  END SUBROUTINE CD_AGG_GetMovingPointMesh

  SUBROUTINE CD_AGG_UpdateStates_Moving(self, position, velocity, acceleration, ErrStat, ErrMsg, output_probe, &
                                        orientation, angular_velocity, angular_acceleration)
    !! Transfer host kinematics for the moving points WITHOUT advancing. The EI=0 system columns
    !! route to CD_FMF_UpdateStates_Moving; each cable column's coupled node is written through
    !! CD_HFMF_SetCoupledKinematics (translation plus parent orientation/rates, interior and time frozen). The
    !! optional output-probe mode is reserved for an outer caller that owns and restores a complete
    !! state mirror on every success and failure path. Every cable column is preflighted before
    !! any subsystem is changed, so deterministic rejection is aggregate-atomic. Consequently, a
    !! CalcOutput taken after a fairlead move -- but before the next Step -- reflects that move:
    !! the cable's reaction is the instantaneous direct-feedthrough load (current coupled
    !! kinematics against the last committed interior shape), not the last committed step's load.
    TYPE(CD_AGG_ModuleType), INTENT(INOUT) :: self
    REAL(wp), INTENT(IN) :: position(:, :), velocity(:, :), acceleration(:, :)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    LOGICAL, INTENT(IN), OPTIONAL :: output_probe
    REAL(wp), INTENT(IN), OPTIONAL :: orientation(:, :, :)
    REAL(wp), INTENT(IN), OPTIONAL :: angular_velocity(:, :), angular_acceleration(:, :)

    INTEGER :: c, col, es
    REAL(wp) :: zero_angular(3)
    LOGICAL :: is_output_probe
    CHARACTER(1024) :: em

    IF (.NOT. require_initialized(self, ErrStat, ErrMsg)) RETURN
    zero_angular = CD_ZERO
    is_output_probe = .FALSE.
    IF (PRESENT(output_probe)) is_output_probe = output_probe
    IF (.NOT. (moving_cols_ok(position, self) .AND. moving_cols_ok(velocity, self) .AND. &
               moving_cols_ok(acceleration, self))) THEN
      ErrStat = CD_AGG_BADINPUT
      ErrMsg = 'CableDyn_OpenFAST_Aggregate: moving-point arrays must be shaped (3, ncp_total)'
      RETURN
    END IF
    IF (.NOT. moving_kinematics_finite(position, velocity, acceleration)) THEN
      ErrStat = CD_AGG_BADINPUT
      ErrMsg = 'CableDyn_OpenFAST_Aggregate: moving-point kinematics must be finite'
      RETURN
    END IF
    IF (PRESENT(orientation)) THEN
      IF (SIZE(orientation, 1) /= 3 .OR. SIZE(orientation, 2) /= 3 .OR. &
          SIZE(orientation, 3) /= ncp_all(self)) THEN
        ErrStat = CD_AGG_BADINPUT
        ErrMsg = 'CableDyn_OpenFAST_Aggregate: orientation must be shaped (3,3,ncp_total)'
        RETURN
      END IF
      IF (.NOT. orientations_ok(orientation)) THEN
        ErrStat = CD_AGG_BADINPUT
        ErrMsg = 'CableDyn_OpenFAST_Aggregate: orientation columns must be finite proper orthogonal DCMs'
        RETURN
      END IF
    END IF
    IF (PRESENT(angular_velocity) .NEQV. PRESENT(angular_acceleration)) THEN
      ErrStat = CD_AGG_BADINPUT
      ErrMsg = 'CableDyn_OpenFAST_Aggregate: angular velocity and acceleration must be supplied together'
      RETURN
    END IF
    IF (PRESENT(angular_velocity)) THEN
      IF (.NOT. (moving_cols_ok(angular_velocity, self) .AND. moving_cols_ok(angular_acceleration, self))) THEN
        ErrStat = CD_AGG_BADINPUT
        ErrMsg = 'CableDyn_OpenFAST_Aggregate: angular kinematics must be shaped (3,ncp_total)'
        RETURN
      END IF
      IF (.NOT. (CD_All_Finite(angular_velocity) .AND. CD_All_Finite(angular_acceleration))) THEN
        ErrStat = CD_AGG_BADINPUT
        ErrMsg = 'CableDyn_OpenFAST_Aggregate: angular kinematics must be finite'
        RETURN
      END IF
    END IF
    ! Preflight every cable before touching the EI=0 system or an earlier cable. This
    ! includes the exact-rigid shortest-rotation check, which is stricter than merely
    ! validating that each supplied orientation is a proper DCM.
    DO c = 1, self%ncable
      col = self%ncp_sys + c
      IF (self%cable_col_b(c) > 0) THEN
        CALL cable_two_ends(self%cables(c), col, self%cable_col_b(c), CABLE_PREFLIGHT, position, velocity, &
                            acceleration, es, em, orientation, &
                            angular_velocity, angular_acceleration)
      ELSE IF (PRESENT(orientation)) THEN
        IF (PRESENT(angular_velocity)) THEN
          CALL CD_HFMF_PreflightCoupledKinematics(self%cables(c), position(:, col), velocity(:, col), &
                                                  acceleration(:, col), es, em, orientation(:, :, col), &
                                                  angular_velocity(:, col), angular_acceleration(:, col))
        ELSE
          CALL CD_HFMF_PreflightCoupledKinematics(self%cables(c), position(:, col), velocity(:, col), &
                                                  acceleration(:, col), es, em, orientation(:, :, col), &
                                                  zero_angular, zero_angular)
        END IF
      ELSE
        IF (PRESENT(angular_velocity)) THEN
          CALL CD_HFMF_PreflightCoupledKinematics(self%cables(c), position(:, col), velocity(:, col), &
                                                  acceleration(:, col), es, em, &
                                                  u_angular_velocity=angular_velocity(:, col), &
                                                  u_angular_acceleration=angular_acceleration(:, col))
        ELSE
          CALL CD_HFMF_PreflightCoupledKinematics(self%cables(c), position(:, col), velocity(:, col), &
                                                  acceleration(:, col), es, em, &
                                                  u_angular_velocity=zero_angular, &
                                                  u_angular_acceleration=zero_angular)
        END IF
      END IF
      IF (es /= CD_HFMF_OK) THEN
        CALL map_hfmf_status(es, em, ErrStat, ErrMsg)
        RETURN
      END IF
    END DO
    self%mv_omega = CD_ZERO
    self%mv_alpha = CD_ZERO
    IF (PRESENT(angular_velocity)) THEN
      self%mv_omega = angular_velocity
      self%mv_alpha = angular_acceleration
    END IF
    IF (self%has_sys) THEN
      CALL CD_FMF_UpdateStates_Moving(self%sys, position(:, 1:self%ncp_sys), velocity(:, 1:self%ncp_sys), &
                                      acceleration(:, 1:self%ncp_sys), es, em, output_probe=is_output_probe)
      IF (es /= CD_FMF_OK) THEN
        CALL map_fmf_status(es, em, ErrStat, ErrMsg)
        RETURN
      END IF
    END IF
    IF (self%nhost_rod + self%nhost_body > 0) THEN
      ! a transfer without advancing: the host kinematics of the committed time, from which the
      ! next step of a CoupledPinned rod or body starts (an output probe is restored by its caller)
      IF (PRESENT(orientation)) THEN
        CALL set_host_objects(self, position, velocity, acceleration, ErrStat, ErrMsg, orientation=orientation, &
                              angular_velocity=self%mv_omega, angular_acceleration=self%mv_alpha, step_start=.TRUE.)
      ELSE
        CALL set_host_objects(self, position, velocity, acceleration, ErrStat, ErrMsg, &
                              angular_velocity=self%mv_omega, angular_acceleration=self%mv_alpha, step_start=.TRUE.)
      END IF
      IF (ErrStat /= CD_AGG_OK) RETURN
      CALL overlay_host_objects(self, is_output_probe, ErrStat, ErrMsg)
      IF (ErrStat /= CD_AGG_OK) RETURN
    END IF
    ! before the first step, a committed (non-probe) transfer of the step-start kinematics moves
    ! the start of the first step: the start accelerations follow it
    IF (.NOT. (is_output_probe .OR. self%objects_committed)) THEN
      CALL start_object_accelerations(self, ErrStat, ErrMsg)
      IF (ErrStat /= CD_AGG_OK) RETURN
    END IF
    DO c = 1, self%ncable
      col = self%ncp_sys + c
      IF (self%cable_col_b(c) > 0) THEN
        CALL cable_two_ends(self%cables(c), col, self%cable_col_b(c), CABLE_SET, position, velocity, &
                            acceleration, es, em, orientation, &
                            self%mv_omega, self%mv_alpha)
      ELSE IF (PRESENT(orientation)) THEN
        CALL CD_HFMF_SetCoupledKinematics(self%cables(c), position(:, col), velocity(:, col), &
                                          acceleration(:, col), es, em, orientation(:, :, col), &
                                          self%mv_omega(:, col), self%mv_alpha(:, col))
      ELSE
        CALL CD_HFMF_SetCoupledKinematics(self%cables(c), position(:, col), velocity(:, col), &
                                          acceleration(:, col), es, em, &
                                          u_angular_velocity=self%mv_omega(:, col), &
                                          u_angular_acceleration=self%mv_alpha(:, col))
      END IF
      IF (es /= CD_HFMF_OK) THEN
        CALL map_hfmf_status(es, em, ErrStat, ErrMsg)
        RETURN
      END IF
    END DO
    ErrStat = CD_AGG_OK
    ErrMsg = ''
  END SUBROUTINE CD_AGG_UpdateStates_Moving

  SUBROUTINE CD_AGG_Step_Moving(self, dt, position, velocity, acceleration, converged, stalled, n_iter, ErrStat, &
                                ErrMsg, t_committed, orientation, angular_velocity, angular_acceleration, roll)
    !! Advance every owned object one coupling step of dt with the moving points prescribed.
    !! The EI=0 system columns route to CD_FMF_Step_Moving; each cable's fairlead column
    !! routes to CD_HFMF_UpdateStates (the implicit prescribed-motion step). Aggregate
    !! convergence folds across all sub-steps: converged = AND, stalled = OR. n_iter reports
    !! the EI=0 system step's Newton count; the implicit cable steps do not expose an
    !! iteration count, and a diverged cable step is surfaced as converged=.FALSE.,
    !! stalled=.TRUE. plus a non-OK ErrStat (a hard solve failure, not a soft non-convergence).
    !!
    !! ATOMICITY CONTRACT (stage-then-commit): a failed step leaves the aggregate exactly
    !! at the step-start state, so retry/recovery/restart logic never sees partially
    !! advanced sub-objects. Each sub-object's own step is failure-atomic (the system by
    !! its transparent-fallback contract; the cable step commits q/v/a/t only on
    !! success), so a SINGLE-sub-object aggregate needs no staging and pays nothing --
    !! the production mooring-only path is untouched. With multiple sub-objects, every
    !! sub-object is snapshotted before any of them steps and ALL are restored if any
    !! sub-step fails (a later cable failure would otherwise strand the already-advanced
    !! system and earlier cables at t+dt).
    TYPE(CD_AGG_ModuleType), INTENT(INOUT) :: self
    REAL(wp), INTENT(IN) :: dt
    REAL(wp), INTENT(IN) :: position(:, :), velocity(:, :), acceleration(:, :)
    LOGICAL, INTENT(OUT) :: converged, stalled
    INTEGER, INTENT(OUT) :: n_iter, ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    ! Committed time AFTER this step (t + dt in the host's clock). REQUIRED when the
    ! deck declares FAILURE rows -- the trigger compares it against FailTime and the
    ! attachment tensions at the newly committed state, exactly the standalone march.
    REAL(wp), INTENT(IN), OPTIONAL :: t_committed
    REAL(wp), INTENT(IN), OPTIONAL :: orientation(:, :, :)
    REAL(wp), INTENT(IN), OPTIONAL :: angular_velocity(:, :), angular_acceleration(:, :)
    ! roll (ncp_total) [rad]: the roll of the line end frames at each moving point about their
    ! directors at t + dt, from the static state, right-handed about the tangent into the line
    ! (the standalone motionFile roll column). A cable restrained in torsion takes the imposed
    ! twist Phi = Phi_0 - roll of its column, Phi_0 = Pretwist(B) - Pretwist(A), as on the
    ! standalone cubic-Hermite route; the other columns carry no twist and ignore it. Without
    ! it the imposed twist is held.
    REAL(wp), INTENT(IN), OPTIONAL :: roll(:)

    INTEGER :: c, col, es, nsys, nsub
    LOGICAL :: csys, ssys, staged, use_roll
    REAL(wp) :: t_start
    CHARACTER(1024) :: em

    converged = .FALSE.
    stalled = .FALSE.
    n_iter = 0
    IF (.NOT. require_initialized(self, ErrStat, ErrMsg)) RETURN
    IF (.NOT. (dt > CD_ZERO)) THEN
      ErrStat = CD_AGG_BADINPUT
      ErrMsg = 'CableDyn_OpenFAST_Aggregate: step dt must be positive'
      RETURN
    END IF
    IF (dt < CD_MIN_TIME_STEP) THEN
      ErrStat = CD_AGG_BADINPUT
      ErrMsg = 'CableDyn_OpenFAST_Aggregate: dt is below the smallest time step, 1e-100 s: the time '// &
               'integration divides by dt^2'
      RETURN
    END IF
    ! Fixed-dt contract: the cables advance with the Init dt frozen into their gen-alpha step, so a
    ! step dt differing from it would desync the cable columns from the mooring columns. Fail closed
    ! rather than silently mis-integrate (self%dt > 0 is guaranteed by Init's dt validation).
    IF (ABS(dt - self%dt) > 1.0e-9_wp*self%dt) THEN
      ErrStat = CD_AGG_BADINPUT
      ErrMsg = 'CableDyn_OpenFAST_Aggregate: step dt must match the Init dt (fixed-dt aggregate)'
      RETURN
    END IF
    IF (ALLOCATED(self%failures) .AND. .NOT. PRESENT(t_committed)) THEN
      ErrStat = CD_AGG_BADINPUT
      ErrMsg = 'CableDyn_OpenFAST_Aggregate: a FAILURE deck requires the committed time (t_committed) '// &
               'threaded into every step'
      RETURN
    END IF
    ! a deck-owned current is sampled at the end-of-step time
    IF (CD_Deck_Current_Active(self%current) .AND. .NOT. PRESENT(t_committed)) THEN
      ErrStat = CD_AGG_BADINPUT
      ErrMsg = 'CableDyn_OpenFAST_Aggregate: a deck-owned current requires the committed time (t_committed) '// &
               'threaded into every step'
      RETURN
    END IF
    IF (.NOT. (moving_cols_ok(position, self) .AND. moving_cols_ok(velocity, self) .AND. &
               moving_cols_ok(acceleration, self))) THEN
      ErrStat = CD_AGG_BADINPUT
      ErrMsg = 'CableDyn_OpenFAST_Aggregate: moving-point arrays must be shaped (3, ncp_total)'
      RETURN
    END IF
    IF (.NOT. moving_kinematics_finite(position, velocity, acceleration)) THEN
      ErrStat = CD_AGG_BADINPUT
      ErrMsg = 'CableDyn_OpenFAST_Aggregate: moving-point kinematics must be finite'
      RETURN
    END IF
    IF (PRESENT(orientation)) THEN
      IF (SIZE(orientation, 1) /= 3 .OR. SIZE(orientation, 2) /= 3 .OR. &
          SIZE(orientation, 3) /= ncp_all(self)) THEN
        ErrStat = CD_AGG_BADINPUT
        ErrMsg = 'CableDyn_OpenFAST_Aggregate: orientation must be shaped (3,3,ncp_total)'
        RETURN
      END IF
      IF (.NOT. orientations_ok(orientation)) THEN
        ErrStat = CD_AGG_BADINPUT
        ErrMsg = 'CableDyn_OpenFAST_Aggregate: orientation columns must be finite proper orthogonal DCMs'
        RETURN
      END IF
    END IF
    IF (PRESENT(angular_velocity) .NEQV. PRESENT(angular_acceleration)) THEN
      ErrStat = CD_AGG_BADINPUT
      ErrMsg = 'CableDyn_OpenFAST_Aggregate: angular velocity and acceleration must be supplied together'
      RETURN
    END IF
    IF (PRESENT(angular_velocity)) THEN
      IF (.NOT. (moving_cols_ok(angular_velocity, self) .AND. moving_cols_ok(angular_acceleration, self))) THEN
        ErrStat = CD_AGG_BADINPUT
        ErrMsg = 'CableDyn_OpenFAST_Aggregate: angular kinematics must be shaped (3,ncp_total)'
        RETURN
      END IF
      IF (.NOT. (CD_All_Finite(angular_velocity) .AND. CD_All_Finite(angular_acceleration))) THEN
        ErrStat = CD_AGG_BADINPUT
        ErrMsg = 'CableDyn_OpenFAST_Aggregate: angular kinematics must be finite'
        RETURN
      END IF
    END IF
    use_roll = PRESENT(roll)
    IF (use_roll) THEN
      IF (SIZE(roll) /= ncp_all(self)) THEN
        ErrStat = CD_AGG_BADINPUT
        ErrMsg = 'CableDyn_OpenFAST_Aggregate: roll must be shaped (ncp_total)'
        RETURN
      END IF
      IF (.NOT. CD_All_Finite(roll)) THEN
        ErrStat = CD_AGG_BADINPUT
        ErrMsg = 'CableDyn_OpenFAST_Aggregate: roll must be finite'
        RETURN
      END IF
    END IF
    self%mv_omega = CD_ZERO
    self%mv_alpha = CD_ZERO
    IF (PRESENT(angular_velocity)) THEN
      self%mv_omega = angular_velocity
      self%mv_alpha = angular_acceleration
    END IF
    self%mv_roll = CD_ZERO
    IF (use_roll) self%mv_roll = roll
    ! The deck's own current over this step: u(x_j, t + dt) at every node x_j of the step-start
    ! state, held over the step on the EI = 0 lines and the cables, as the single-line EI = 0
    ! and cubic-Hermite marches sample it before their steps. It is an input of the step (a
    ! function of the committed state and the clock), so a rewound or restored step samples
    ! the same field again.
    IF (CD_Deck_Current_Active(self%current)) THEN
      CALL sample_deck_current(self, t_committed, .FALSE., ErrStat, ErrMsg)
      IF (ErrStat /= CD_AGG_OK) RETURN
    END IF
    ! stage: snapshot every sub-object before any of them steps (multi-object only; a
    ! single sub-object is already atomic -- the hot mooring-only path skips this).
    ! A Rigid6 deck is single-subobject (ncable == 0) yet still needs staging: its branch
    ! COMMITS the host fairleads into the system before the atomic body/line step (unlike
    ! CD_FMF_Step, which passes them as inputs), so a failed step's own rollback only reaches
    ! that post-commit state -- the pre-step snapshot restores the true step-start.
    nsub = self%ncable
    IF (self%has_sys) nsub = nsub + 1
    staged = nsub > 1 .OR. self%has_rigid6 .OR. self%has_rod
    IF (staged) THEN
      IF (self%has_sys) THEN
        CALL CD_FMF_Snapshot(self%sys, es, em)
        IF (es /= CD_FMF_OK) THEN
          CALL map_fmf_status(es, em, ErrStat, ErrMsg)
          RETURN
        END IF
      END IF
      DO c = 1, self%ncable
        CALL CD_HFMF_Snapshot(self%cables(c), es, em)
        IF (es /= CD_HFMF_OK) THEN
          CALL map_hfmf_status(es, em, ErrStat, ErrMsg)
          RETURN
        END IF
      END DO
    END IF
    converged = .TRUE.
    IF (self%has_rigid6) THEN
      ! Coupled Rigid6 branch (pure EI=0 deck, ncable == 0; staged == .TRUE. per above so the
      ! pre-step snapshot captured the true step-start). Transfer the host fairlead kinematics
      ! into the system's coupled input, then march the bodies over the system. step_rigid6_system
      ! reads the coupled motion (host fairleads + current body attachments), advances each body
      ! explicitly, drives its attachment Free points as PRESCRIBED motion, and steps the lines.
      ! On ANY failure the fairleads have already been committed (or the interior half-advanced),
      ! so undo_staged_step rewinds the system to the pre-step snapshot AND re-derives the mesh
      ! (the body was rolled back inside step_rigid6_system, or never touched on a pre-step fail).
      ! The host fairlead kinematics enter the line step as its prescribed t + dt end motion
      ! (host_fairlead_motion), while the line ends keep their committed step-start state -- the
      ! plain moving step's contract. Writing them into the line ends before the step would
      ! start the generalized-alpha step from the t + dt end state and corrupt the ends' history.
      CALL host_fairlead_motion(self, position, velocity, acceleration)
      ! The step-start bodies are staged before anything moves them: host-driven
      ! (Coupled/Vessel) bodies take the t+dt host kinematics before the march (CoupledPinned ones
      ! their t+dt node translation), and a check
      ! after a successful march (plausibility, FAILURE rows) can still reject the step, so
      ! every failure path below un-stages them together with the system rewind.
      CALL CD_Rigid6_Stage(self%rigid6)
      IF (self%nhost_body > 0) THEN
        IF (PRESENT(orientation)) THEN
          CALL set_host_objects(self, position, velocity, acceleration, ErrStat, ErrMsg, orientation=orientation, &
                                angular_velocity=self%mv_omega, angular_acceleration=self%mv_alpha)
        ELSE
          CALL set_host_objects(self, position, velocity, acceleration, ErrStat, ErrMsg, &
                                angular_velocity=self%mv_omega, angular_acceleration=self%mv_alpha)
        END IF
        IF (ErrStat /= CD_AGG_OK) THEN
          converged = .FALSE.
          CALL rewind_step()
          RETURN
        END IF
      END IF
      t_start = CD_ZERO
      IF (PRESENT(t_committed)) t_start = t_committed - dt
      CALL CD_Step_Aggregate_Rigid6(self%sys%fast%system, self%rigid6, t_start, dt, csys, ssys, nsys, es, em, &
                                    host_mask=self%hf_mask, host_q=self%hf_q, host_v=self%hf_v, host_a=self%hf_a, &
                                    interp_hosts=self%nhost_body > 0)
      IF (es /= CD_DECKDRV_OK) THEN
        converged = .FALSE.
        stalled = .TRUE.
        CALL map_deck_status(es, em, ErrStat, ErrMsg)
        CALL rewind_step()
        RETURN
      END IF
      converged = converged .AND. csys
      stalled = stalled .OR. ssys
      n_iter = MAX(n_iter, nsys)
      CALL CD_FMF_Refresh_PointMesh(self%sys, es, em)
      IF (es /= CD_FMF_OK) THEN
        converged = .FALSE.
        CALL map_fmf_status(es, em, ErrStat, ErrMsg)
        CALL rewind_step()
        RETURN
      END IF
    ELSE IF (self%has_rod) THEN
      ! Coupled ROD branch (the rod twin of the Rigid6 branch above; pure EI=0 deck, staged so the
      ! pre-step snapshot captured the true step-start). Transfer the host fairlead kinematics into
      ! the system's coupled input, then march the rods over the system. step_rod_system reads the
      ! coupled motion, advances each rod explicitly, drives its end attachment points as PRESCRIBED
      ! motion, and steps the lines. On ANY failure the fairleads have already been committed (or the
      ! interior half-advanced), so undo_staged_step rewinds the system to the pre-step snapshot and
      ! re-derives the mesh (the rod was rolled back inside step_rod_system, or never touched).
      ! The host fairleads enter the line step as prescribed t + dt end motion, as in the Rigid6
      ! branch.
      CALL host_fairlead_motion(self, position, velocity, acceleration)
      ! Host-driven (Coupled/Vessel) rods take the t+dt host kinematics before the march; the
      ! rod march then treats them as prescribed. The step-start rods are staged first (for
      ! every rod deck, as for the bodies above) so any failed step leaves them at the step start.
      CALL CD_Rod_Stage(self%rod)
      IF (self%nhost_rod > 0) THEN
        IF (PRESENT(orientation)) THEN
          CALL set_host_objects(self, position, velocity, acceleration, ErrStat, ErrMsg, orientation=orientation, &
                                angular_velocity=self%mv_omega, angular_acceleration=self%mv_alpha)
        ELSE
          CALL set_host_objects(self, position, velocity, acceleration, ErrStat, ErrMsg, &
                                angular_velocity=self%mv_omega, angular_acceleration=self%mv_alpha)
        END IF
        IF (ErrStat /= CD_AGG_OK) THEN
          converged = .FALSE.
          CALL rewind_step()
          RETURN
        END IF
      END IF
      t_start = CD_ZERO
      IF (PRESENT(t_committed)) t_start = t_committed - dt
      CALL CD_Step_Aggregate_Rod(self%sys%fast%system, self%rod, t_start, dt, csys, ssys, nsys, es, em, &
                                 host_mask=self%hf_mask, host_q=self%hf_q, host_v=self%hf_v, host_a=self%hf_a, &
                                 interp_hosts=self%nhost_rod > 0)
      IF (es /= CD_DECKDRV_OK) THEN
        converged = .FALSE.
        stalled = .TRUE.
        CALL map_deck_status(es, em, ErrStat, ErrMsg)
        CALL rewind_step()
        RETURN
      END IF
      converged = converged .AND. csys
      stalled = stalled .OR. ssys
      n_iter = MAX(n_iter, nsys)
      CALL CD_FMF_Refresh_PointMesh(self%sys, es, em)
      IF (es /= CD_FMF_OK) THEN
        converged = .FALSE.
        CALL map_fmf_status(es, em, ErrStat, ErrMsg)
        CALL rewind_step()
        RETURN
      END IF
    ELSE IF (self%has_sys) THEN
      CALL CD_FMF_Step_Moving(self%sys, dt, position(:, 1:self%ncp_sys), velocity(:, 1:self%ncp_sys), &
                              acceleration(:, 1:self%ncp_sys), csys, ssys, nsys, es, em)
      IF (es /= CD_FMF_OK) THEN
        ! The system's OWN states roll back on failure, but the FMF step transfers the
        ! failed t+dt kinematics into the facade point mesh BEFORE solving -- in the
        ! staged (multi-object) case restore everything so the mesh is re-derived from
        ! the committed states and the readers never see the failed kinematics.
        converged = .FALSE.
        CALL map_fmf_status(es, em, ErrStat, ErrMsg)
        IF (staged) CALL rewind_step()
        RETURN
      END IF
      converged = converged .AND. csys
      stalled = stalled .OR. ssys
      n_iter = MAX(n_iter, nsys)
    END IF
    IF (PRESENT(orientation)) THEN
      !$OMP PARALLEL DEFAULT(NONE) SHARED(self, position, velocity, acceleration, orientation, use_roll) &
      !$OMP   PRIVATE(c, col, es, em) &
      !$OMP   IF(self%ncable > 1 .AND. .NOT. CD_HermiteCable_Dyn_Profile_Enabled())
      CALL CD_Fatal_Thread_Init() ! this thread can report its own stack overflow
      !$OMP DO SCHEDULE(STATIC)
      DO c = 1, self%ncable
        col = self%ncp_sys + c
        IF (self%cable_col_b(c) > 0) THEN
          IF (use_roll .AND. self%cables(c)%line%torsion%active) THEN
            ! the roll of each moving end restrained in torsion: Phi_0 - roll(A) - roll(B)
            CALL cable_two_ends(self%cables(c), col, self%cable_col_b(c), CABLE_STEP, position, velocity, &
                                acceleration, es, em, orientation, self%mv_omega, self%mv_alpha, &
                                twist=self%cable_phi0(c) - self%mv_roll(col) - self%mv_roll(self%cable_col_b(c)))
          ELSE
            CALL cable_two_ends(self%cables(c), col, self%cable_col_b(c), CABLE_STEP, position, velocity, &
                                acceleration, es, em, orientation, &
                                self%mv_omega, self%mv_alpha)
          END IF
        ELSE
          CALL step_cable(self, c, position(:, col), velocity(:, col), acceleration(:, col), use_roll, es, em, &
                          orientation(:, :, col))
        END IF
        self%cable_stat(c) = es
        self%cable_msg(c) = em
      END DO
      !$OMP END DO
      !$OMP END PARALLEL
    ELSE
      !$OMP PARALLEL DEFAULT(NONE) SHARED(self, position, velocity, acceleration, use_roll) &
      !$OMP   PRIVATE(c, col, es, em) &
      !$OMP   IF(self%ncable > 1 .AND. .NOT. CD_HermiteCable_Dyn_Profile_Enabled())
      CALL CD_Fatal_Thread_Init() ! this thread can report its own stack overflow
      !$OMP DO SCHEDULE(STATIC)
      DO c = 1, self%ncable
        col = self%ncp_sys + c
        IF (self%cable_col_b(c) > 0) THEN
          IF (use_roll .AND. self%cables(c)%line%torsion%active) THEN
            CALL cable_two_ends(self%cables(c), col, self%cable_col_b(c), CABLE_STEP, position, velocity, &
                                acceleration, es, em, &
                                angular_velocity=self%mv_omega, angular_acceleration=self%mv_alpha, &
                                twist=self%cable_phi0(c) - self%mv_roll(col) - self%mv_roll(self%cable_col_b(c)))
          ELSE
            CALL cable_two_ends(self%cables(c), col, self%cable_col_b(c), CABLE_STEP, position, velocity, &
                                acceleration, es, em, &
                                angular_velocity=self%mv_omega, angular_acceleration=self%mv_alpha)
          END IF
        ELSE
          CALL step_cable(self, c, position(:, col), velocity(:, col), acceleration(:, col), use_roll, es, em)
        END IF
        self%cable_stat(c) = es
        self%cable_msg(c) = em
      END DO
      !$OMP END DO
      !$OMP END PARALLEL
    END IF
    DO c = 1, self%ncable
      IF (self%cable_stat(c) /= CD_HFMF_OK) THEN
        ! A diverged implicit cable step is a hard solve failure, not just a non-converged flag.
        converged = .FALSE.
        stalled = .TRUE.
        CALL map_hfmf_status(self%cable_stat(c), self%cable_msg(c), ErrStat, ErrMsg)
        IF (staged) CALL rewind_step()
        RETURN
      END IF
    END DO
    ! Plausibility guard on the committed EI=0 lines (non-finite state or an element
    ! stretched beyond maxStrain): a numerically exploding step must never be reported as
    ! converged to the host. Same bound and message as the standalone march.
    IF (self%has_sys) THEN
      t_start = CD_ZERO
      IF (PRESENT(t_committed)) t_start = t_committed
      CALL CD_Check_System_Plausibility(self%sys%fast%system, self%max_strain, t_start, es, em)
      IF (es /= CD_DECKDRV_OK) THEN
        converged = .FALSE.
        stalled = .TRUE.
        CALL map_deck_status(es, em, ErrStat, ErrMsg)
        IF (staged) CALL rewind_step()
        RETURN
      END IF
    END IF
    ! Fire FAILURE rows against the newly committed state (post-advance, the same
    ! placement as the standalone march). A trigger error is a hard failure; in the
    ! staged case rewind so the caller sees the step-start state.
    IF (ALLOCATED(self%failures) .AND. self%has_sys) THEN
      CALL CD_Fire_Deck_Failures(self%sys%fast%system, self%fail_lines, self%fail_points, &
                                 self%failures, t_committed, es, em)
      IF (es /= CD_DECKDRV_OK) THEN
        converged = .FALSE.
        CALL map_deck_status(es, em, ErrStat, ErrMsg)
        IF (staged) CALL rewind_step()
        RETURN
      END IF
      ! A fired detach rewires the system topology: re-derive the facade point mesh
      ! from the committed (post-detach) state so readers see consistent kinematics.
      CALL CD_FMF_Refresh_PointMesh(self%sys, es, em)
      IF (es /= CD_FMF_OK) THEN
        converged = .FALSE.
        CALL map_fmf_status(es, em, ErrStat, ErrMsg)
        IF (staged) CALL rewind_step()
        RETURN
      END IF
    END IF
    IF (self%has_rigid6 .OR. self%has_rod) self%objects_committed = .TRUE.
    ErrStat = CD_AGG_OK
    ErrMsg = ''

  CONTAINS

    SUBROUTINE rewind_step()
      !! Return the whole aggregate to the step start: the bodies and rods staged at the
      !! start of their branch, then every sub-object from the pre-step snapshot.
      IF (self%has_rigid6) CALL CD_Rigid6_Unstage(self%rigid6)
      IF (self%has_rod) CALL CD_Rod_Unstage(self%rod)
      CALL undo_staged_step(self, ErrMsg)
    END SUBROUTINE rewind_step
  END SUBROUTINE CD_AGG_Step_Moving

  SUBROUTINE step_cable(self, c, u_pos, u_vel, u_acc, use_roll, ErrStat, ErrMsg, u_orientation)
    !! One cable's implicit step to its column's t + dt kinematics (CD_HFMF_UpdateStates): the
    !! parent orientation when given, the column's angular rates, and with use_roll the imposed
    !! twist Phi_0 - roll of a cable restrained in torsion. Touches cable c alone, so the cables
    !! step concurrently.
    TYPE(CD_AGG_ModuleType), INTENT(INOUT) :: self
    INTEGER, INTENT(IN) :: c
    REAL(wp), INTENT(IN) :: u_pos(3), u_vel(3), u_acc(3)
    LOGICAL, INTENT(IN) :: use_roll
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    REAL(wp), INTENT(IN), OPTIONAL :: u_orientation(3, 3)
    INTEGER :: col
    REAL(wp) :: twist
    col = self%ncp_sys + c
    IF (use_roll .AND. self%cables(c)%line%torsion%active) THEN
      twist = self%cable_phi0(c) - self%mv_roll(col)
      IF (PRESENT(u_orientation)) THEN
        CALL CD_HFMF_UpdateStates(self%cables(c), u_pos, u_vel, u_acc, ErrStat, ErrMsg, u_orientation, &
                                  self%mv_omega(:, col), self%mv_alpha(:, col), u_twist=twist)
      ELSE
        CALL CD_HFMF_UpdateStates(self%cables(c), u_pos, u_vel, u_acc, ErrStat, ErrMsg, &
                                  u_angular_velocity=self%mv_omega(:, col), &
                                  u_angular_acceleration=self%mv_alpha(:, col), u_twist=twist)
      END IF
    ELSE IF (PRESENT(u_orientation)) THEN
      CALL CD_HFMF_UpdateStates(self%cables(c), u_pos, u_vel, u_acc, ErrStat, ErrMsg, u_orientation, &
                                self%mv_omega(:, col), self%mv_alpha(:, col))
    ELSE
      CALL CD_HFMF_UpdateStates(self%cables(c), u_pos, u_vel, u_acc, ErrStat, ErrMsg, &
                                u_angular_velocity=self%mv_omega(:, col), &
                                u_angular_acceleration=self%mv_alpha(:, col))
    END IF
  END SUBROUTINE step_cable

  LOGICAL FUNCTION CD_AGG_HasMotion(self) RESULT(has)
    !! The aggregate carries the deck's own prescribed motion (Init prescribed_motion).
    TYPE(CD_AGG_ModuleType), INTENT(IN) :: self
    has = self%initialized .AND. CD_Motion_Active(self%motion)
  END FUNCTION CD_AGG_HasMotion

  SUBROUTINE CD_AGG_MotionKinematics(self, time_index, position, velocity, acceleration, orientation, &
                                     angular_velocity, angular_acceleration, roll, has_rotation, has_roll, &
                                     ErrStat, ErrMsg)
    !! Grid row time_index (1 = t 0) of the deck's prescribed motion over the moving surface,
    !! shaped as CD_AGG_Step_Moving takes it: translations (3, ncp_total), the global-to-parent
    !! DCM (3, 3, ncp_total) with the global-axis angular velocity and acceleration (3,
    !! ncp_total), and the roll (ncp_total). has_rotation: a vesselMotion table, whose
    !! orientation and rates the step takes (the fairlead end connection and torsion frames
    !! turn with the vessel, as on the standalone cubic-Hermite route), or the per-turbine
    !! records of a TURBINES deck whose lines carry end frames (each column turns with its
    !! turbine); has_roll: a motionFile
    !! roll column the step takes as roll. Without them (motionFile point rows) the frames are
    !! held and the step takes the translations alone.
    TYPE(CD_AGG_ModuleType), INTENT(IN) :: self
    INTEGER, INTENT(IN) :: time_index
    REAL(wp), INTENT(OUT) :: position(:, :), velocity(:, :), acceleration(:, :)
    REAL(wp), INTENT(OUT) :: orientation(:, :, :), angular_velocity(:, :), angular_acceleration(:, :), roll(:)
    LOGICAL, INTENT(OUT) :: has_rotation, has_roll
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    INTEGER :: es
    CHARACTER(1024) :: em
    has_rotation = .FALSE.
    has_roll = .FALSE.
    IF (.NOT. require_initialized(self, ErrStat, ErrMsg)) RETURN
    IF (.NOT. CD_Motion_Active(self%motion)) THEN
      ErrStat = CD_AGG_BADINPUT
      ErrMsg = 'CableDyn_OpenFAST_Aggregate: the aggregate carries no prescribed motion'
      RETURN
    END IF
    CALL CD_Motion_Kinematics(self%motion, time_index, position, velocity, acceleration, orientation, &
                              angular_velocity, angular_acceleration, roll, es, em)
    IF (es /= CD_DECKDRV_OK) THEN
      CALL map_deck_status(es, em, ErrStat, ErrMsg)
      RETURN
    END IF
    has_rotation = CD_Motion_Has_Rotation(self%motion)
    has_roll = CD_Motion_Has_Roll(self%motion)
    ErrStat = CD_AGG_OK
    ErrMsg = ''
  END SUBROUTINE CD_AGG_MotionKinematics

  SUBROUTINE CD_AGG_Refresh_Accelerations(self, ErrStat, ErrMsg)
    !! Recompute every cable's free-node acceleration from its complete residual at the
    !! committed state, keeping the coupled node's prescribed acceleration
    !! (CD_HFMF_Refresh_Acceleration): after CD_AGG_UpdateStates_Moving installs the first row
    !! of a prescribed motion, so the first step does not start from the static acceleration
    !! (the standalone cubic-Hermite route's row-1 station). The EI = 0 system is unchanged,
    !! except under a deck-owned current: the row-1 station is t = 0, so the current is sampled
    !! again at t = 0 at the installed row (as the single-line routes sample it after installing
    !! row 1), an EI = 0 line whose field changed re-deriving its acceleration in it, before the
    !! cables' refresh.
    TYPE(CD_AGG_ModuleType), INTENT(INOUT) :: self
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    INTEGER :: c, es
    CHARACTER(1024) :: em
    IF (.NOT. require_initialized(self, ErrStat, ErrMsg)) RETURN
    IF (CD_Deck_Current_Active(self%current)) THEN
      CALL sample_deck_current(self, CD_ZERO, .TRUE., ErrStat, ErrMsg)
      IF (ErrStat /= CD_AGG_OK) RETURN
    END IF
    DO c = 1, self%ncable
      CALL CD_HFMF_Refresh_Acceleration(self%cables(c), es, em)
      IF (es /= CD_HFMF_OK) THEN
        CALL map_hfmf_status(es, em, ErrStat, ErrMsg)
        RETURN
      END IF
    END DO
    ErrStat = CD_AGG_OK
    ErrMsg = ''
  END SUBROUTINE CD_AGG_Refresh_Accelerations

  SUBROUTINE sample_deck_current(self, time, initial_condition, ErrStat, ErrMsg)
    !! The deck's own current at time over every node: the EI = 0 system's lines
    !! (CD_Deck_Current_Sample_System; initial_condition re-derives the acceleration of a line
    !! whose field changed) and the finite-EI cables (CD_Deck_Current_Sample_Cables).
    TYPE(CD_AGG_ModuleType), INTENT(INOUT) :: self
    REAL(wp), INTENT(IN) :: time
    LOGICAL, INTENT(IN) :: initial_condition
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    INTEGER :: es
    CHARACTER(1024) :: em
    ErrStat = CD_AGG_OK
    ErrMsg = ''
    IF (self%has_sys) THEN
      CALL CD_Deck_Current_Sample_System(self%current, self%sys%fast%system, time, es, em, &
                                         initial_condition=initial_condition)
      IF (es /= CD_DECKDRV_OK) THEN
        CALL map_deck_status(es, em, ErrStat, ErrMsg)
        RETURN
      END IF
    END IF
    IF (self%ncable > 0) THEN
      CALL CD_Deck_Current_Sample_Cables(self%current, self%cables, time, es, em)
      IF (es /= CD_DECKDRV_OK) CALL map_deck_status(es, em, ErrStat, ErrMsg)
    END IF
  END SUBROUTINE sample_deck_current

  SUBROUTINE check_motion_columns(self, ErrStat, ErrMsg)
    !! The prescribed-motion columns match the moving surface: one column per moving point, and
    !! each column's driving point at that moving point's static position (a column map that
    !! drifted from the aggregate's moving-set order would drive the wrong point).
    TYPE(CD_AGG_ModuleType), INTENT(INOUT) :: self
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    INTEGER :: es, col
    REAL(wp), ALLOCATABLE :: deck_pos(:, :)
    CHARACTER(1024) :: em
    IF (CD_Motion_NColumns(self%motion) /= ncp_all(self) .OR. self%nhost_rod + self%nhost_body > 0) THEN
      ErrStat = CD_AGG_BADINPUT
      ErrMsg = 'CableDyn_OpenFAST_Aggregate: the prescribed motion does not cover the moving surface'
      RETURN
    END IF
    CALL CD_AGG_GetMovingPointMesh(self, self%mv_pos, self%mv_vel, self%mv_acc, self%mv_load, ErrStat, ErrMsg, &
                                   cable_loads=.FALSE.)
    IF (ErrStat /= CD_AGG_OK) RETURN
    ALLOCATE (deck_pos(3, ncp_all(self)))
    CALL CD_Motion_Deck_Positions(self%motion, deck_pos, es, em)
    IF (es /= CD_DECKDRV_OK) THEN
      CALL map_deck_status(es, em, ErrStat, ErrMsg)
      RETURN
    END IF
    DO col = 1, ncp_all(self)
      IF (ANY(ABS(deck_pos(:, col) - self%mv_pos(:, col)) > 1.0e-9_wp*(CD_ONE + MAXVAL(ABS(deck_pos(:, col)))))) THEN
        ErrStat = CD_AGG_BADINPUT
        WRITE (ErrMsg, '(A,I0,A)') 'CableDyn_OpenFAST_Aggregate: the prescribed motion of moving point ', col, &
          ' is not keyed to that point'
        RETURN
      END IF
    END DO
    ErrStat = CD_AGG_OK
    ErrMsg = ''
  END SUBROUTINE check_motion_columns

  SUBROUTINE CD_AGG_Snapshot(self, ErrStat, ErrMsg)
    !! Capture the committed state of EVERY sub-object (system + all cables), any
    !! composition -- the caller-facing twin of the internal staged snapshot (which the
    !! single-sub-object hot path skips because a lone step is already atomic). The
    !! OpenFAST shell takes this snapshot at the START of every mooring advance so a glue
    !! correction iteration (a re-entered UpdateStates over the same interval) can rewind
    !! the completed step and re-advance with the corrected inputs. Overwrites any prior
    !! snapshot (idempotent; buffers are reused).
    TYPE(CD_AGG_ModuleType), INTENT(INOUT) :: self
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    INTEGER :: c, es
    CHARACTER(1024) :: em
    IF (.NOT. require_initialized(self, ErrStat, ErrMsg)) RETURN
    IF (self%has_sys) THEN
      CALL CD_FMF_Snapshot(self%sys, es, em)
      IF (es /= CD_FMF_OK) THEN
        CALL map_fmf_status(es, em, ErrStat, ErrMsg)
        RETURN
      END IF
    END IF
    DO c = 1, self%ncable
      CALL CD_HFMF_Snapshot(self%cables(c), es, em)
      IF (es /= CD_HFMF_OK) THEN
        CALL map_hfmf_status(es, em, ErrStat, ErrMsg)
        RETURN
      END IF
    END DO
    ! FAILURE rows join the snapshot: a rewind un-fires a row together with the
    ! detach topology (the system snapshot carries bindings + map), so the row
    ! re-triggers on the corrected re-advance.
    IF (ALLOCATED(self%failures)) self%snap_failures = self%failures
    ! The aggregate-held Rigid6 body states are NOT part of the system snapshot (which covers
    ! only sys%fast%system); capture them so a correction rewind un-advances the body too.
    IF (self%has_rigid6) CALL CD_Rigid6_Snapshot(self%rigid6)
    IF (self%has_rod) CALL CD_Rod_Snapshot(self%rod)
    ! a rewind to a state before the first step takes the start accelerations open again (new
    ! fluid fields re-solve them)
    self%snap_objects_committed = self%objects_committed
    ! the range graphs as of the step start: a rewind takes back the sample of the abandoned step
    IF (CD_Range_Has_Graph(self%ranges)) THEN
      IF (.NOT. ALLOCATED(self%snap_range)) ALLOCATE (self%snap_range(CD_Range_Mirror_Size(self%ranges)))
      CALL CD_Range_Get_State(self%ranges, self%snap_range)
    END IF
    ErrStat = CD_AGG_OK
    ErrMsg = ''
  END SUBROUTINE CD_AGG_Snapshot

  SUBROUTINE CD_AGG_Restore(self, ErrStat, ErrMsg)
    !! Restore every sub-object to the last CD_AGG_Snapshot and re-derive the facade
    !! state (the FMF restore refreshes its point mesh from the restored system; each
    !! cable restore rewinds q/v/a/t). Fails closed -- per sub-object -- when no valid
    !! snapshot exists. After a restore the aggregate is exactly at the snapshotted
    !! committed state: positions, loads, and a subsequent step are bit-identical to
    !! never having advanced.
    TYPE(CD_AGG_ModuleType), INTENT(INOUT) :: self
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    INTEGER :: c, es
    CHARACTER(1024) :: em
    IF (.NOT. require_initialized(self, ErrStat, ErrMsg)) RETURN
    IF (self%has_sys) THEN
      CALL CD_FMF_Restore(self%sys, es, em)
      IF (es /= CD_FMF_OK) THEN
        CALL map_fmf_status(es, em, ErrStat, ErrMsg)
        RETURN
      END IF
    END IF
    DO c = 1, self%ncable
      CALL CD_HFMF_Restore(self%cables(c), es, em)
      IF (es /= CD_HFMF_OK) THEN
        CALL map_hfmf_status(es, em, ErrStat, ErrMsg)
        RETURN
      END IF
    END DO
    IF (ALLOCATED(self%snap_failures)) self%failures = self%snap_failures
    IF (self%has_rigid6) CALL CD_Rigid6_Restore(self%rigid6)
    IF (self%has_rod) CALL CD_Rod_Restore(self%rod)
    self%objects_committed = self%snap_objects_committed
    IF (ALLOCATED(self%snap_range)) THEN
      CALL CD_Range_Set_State(self%ranges, self%snap_range, es, em)
      IF (es /= CD_RANGE_OK) THEN
        ErrStat = CD_AGG_BADINPUT
        ErrMsg = 'CableDyn_OpenFAST_Aggregate: '//TRIM(em)
        RETURN
      END IF
    END IF
    ErrStat = CD_AGG_OK
    ErrMsg = ''
  END SUBROUTINE CD_AGG_Restore

  SUBROUTINE undo_staged_step(self, ErrMsg)
    !! Restore every sub-object to the pre-step snapshot after a mid-aggregate failure
    !! (see the CD_AGG_Step_Moving atomicity contract). A restore failure here means the
    !! aggregate is genuinely corrupted -- it is appended to the step's error message so
    !! the caller sees BOTH the solve failure and the broken-invariant condition.
    TYPE(CD_AGG_ModuleType), INTENT(INOUT) :: self
    CHARACTER(*), INTENT(INOUT) :: ErrMsg
    INTEGER :: c, es
    CHARACTER(1024) :: em
    IF (self%has_sys) THEN
      CALL CD_FMF_Restore(self%sys, es, em)
      IF (es /= CD_FMF_OK) ErrMsg = TRIM(ErrMsg)//'; RESTORE FAILED (system): '//TRIM(em)
    END IF
    DO c = 1, self%ncable
      CALL CD_HFMF_Restore(self%cables(c), es, em)
      IF (es /= CD_HFMF_OK) ErrMsg = TRIM(ErrMsg)//'; RESTORE FAILED (cable): '//TRIM(em)
    END DO
    ! The Rigid6 body and rod states are not restored here: CD_Rigid6_Restore/CD_Rod_Restore
    ! reload the last CD_AGG_Snapshot (a correction-rewind snapshot, not this step's start).
    ! CD_AGG_Step_Moving un-stages them from its own step-start copy before calling this.
  END SUBROUTINE undo_staged_step

  SUBROUTINE size_fluid_surface(candidate, ErrStat, ErrMsg)
    !! Compute the ambient-fluid sampling layout over EVERY line node the aggregate
    !! owns -- the EI=0 system's line nodes first, then each finite-EI cable's nodes --
    !! as per-block offsets into the flat (3, nfluid) field arrays, plus the max-line
    !! state scratch (one allocation at Init; the per-step paths allocate nothing).
    TYPE(CD_AGG_ModuleType), INTENT(INOUT) :: candidate
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    INTEGER :: nl, li, ic, ib, ir, ip, nbody, nrod, nhydropt, ndof, nn, maxdof, nblk, es, istat
    CHARACTER(1024) :: em
    ErrStat = CD_AGG_OK
    ErrMsg = ''
    candidate%nfluid = 0
    candidate%fl_nlines = 0
    candidate%fl_nbody = 0
    candidate%fl_nrod = 0
    candidate%fl_nhydropt = 0
    nl = 0
    IF (candidate%has_sys) THEN
      nl = CD_System_NLines(candidate%sys%fast%system, es, em)
      IF (es /= CD_SYSTEM_OK) THEN
        ErrStat = CD_AGG_BADINPUT
        ErrMsg = 'CableDyn_OpenFAST_Aggregate: fluid-surface sizing: '//TRIM(em)
        RETURN
      END IF
    END IF
    ! The coupled fluid contract adds one fluid sampling node per Rigid6 body (its reference
    ! point) and one per hydro-active dynamic point (a buoy with Vol > 0 or CdA/Ca > 0), appended
    ! after the line and cable blocks so the host samples SeaState there too. A mooring with no body
    ! and no hydro buoy adds no nodes -- nfluid is bit-identical to the pre-contract build.
    nbody = 0
    IF (candidate%has_rigid6) nbody = CD_Rigid6_NBodies(candidate%rigid6)
    nrod = 0
    IF (candidate%has_rod) nrod = CD_Rod_NRods(candidate%rod)
    nhydropt = 0
    IF (candidate%has_sys) nhydropt = CD_System_NHydroPoints(candidate%sys%fast%system)
    nblk = nl + candidate%ncable + nbody + nrod + nhydropt
    IF (nblk == 0) RETURN
    ALLOCATE (candidate%fl_off(nblk + 1), STAT=istat)
    IF (istat /= 0) THEN
      ErrStat = CD_AGG_ALLOCFAIL
      ErrMsg = 'CableDyn_OpenFAST_Aggregate: fluid-surface offset allocation failed'
      RETURN
    END IF
    candidate%fl_off(1) = 0
    maxdof = 3   ! floor so the scratch exists even for a system-less aggregate
    DO li = 1, nl
      ndof = CD_System_Line_NDOF(candidate%sys%fast%system, li, es, em)
      IF (es /= CD_SYSTEM_OK) THEN
        ErrStat = CD_AGG_BADINPUT
        ErrMsg = 'CableDyn_OpenFAST_Aggregate: fluid-surface sizing: '//TRIM(em)
        RETURN
      END IF
      nn = ndof/3
      candidate%fl_off(li + 1) = candidate%fl_off(li) + nn
      maxdof = MAX(maxdof, ndof)
    END DO
    DO ic = 1, candidate%ncable
      nn = CD_HFMF_NNodes(candidate%cables(ic))
      candidate%fl_off(nl + ic + 1) = candidate%fl_off(nl + ic) + nn
    END DO
    ! Rigid6 body reference points: one fluid node each, appended after the cable blocks.
    DO ib = 1, nbody
      candidate%fl_off(nl + candidate%ncable + ib + 1) = candidate%fl_off(nl + candidate%ncable + ib) + 1
    END DO
    ! Rigid rods: one block per rod holding its NumSegs + 1 segment stations (End A to End B).
    DO ir = 1, nrod
      candidate%fl_off(nl + candidate%ncable + nbody + ir + 1) = &
        candidate%fl_off(nl + candidate%ncable + nbody + ir) + CD_Rod_NStations(candidate%rod, ir)
    END DO
    ! Hydro-active dynamic points (buoys carrying CdA/Ca): one fluid node each, after the bodies.
    DO ip = 1, nhydropt
      candidate%fl_off(nl + candidate%ncable + nbody + nrod + ip + 1) = &
        candidate%fl_off(nl + candidate%ncable + nbody + nrod + ip) + 1
    END DO
    candidate%fl_nlines = nl
    candidate%fl_nbody = nbody
    candidate%fl_nrod = nrod
    candidate%fl_nhydropt = nhydropt
    candidate%nfluid = candidate%fl_off(nblk + 1)
    ALLOCATE (candidate%fl_q(maxdof), candidate%fl_v(maxdof), candidate%fl_a(maxdof), STAT=istat)
    IF (istat /= 0) THEN
      ErrStat = CD_AGG_ALLOCFAIL
      ErrMsg = 'CableDyn_OpenFAST_Aggregate: fluid-surface scratch allocation failed'
    END IF
  END SUBROUTINE size_fluid_surface

  INTEGER FUNCTION CD_AGG_NFluidNodes(self, ErrStat, ErrMsg) RESULT(n)
    !! Total ambient-fluid sampling points: every node of every EI=0 system line, in
    !! system-line order (line li occupies columns fl_off(li)+1 .. fl_off(li+1) of the
    !! flat arrays). Zero for a system-less (pure-cable) aggregate.
    TYPE(CD_AGG_ModuleType), INTENT(IN) :: self
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    n = 0
    IF (.NOT. require_initialized(self, ErrStat, ErrMsg)) RETURN
    n = self%nfluid
    ErrStat = CD_AGG_OK
    ErrMsg = ''
  END FUNCTION CD_AGG_NFluidNodes

  SUBROUTINE CD_AGG_GetFluidNodePositions(self, xyz, ErrStat, ErrMsg)
    !! Current committed positions of every fluid sampling node, shaped (3, nfluid) --
    !! where the host samples its wave field this step.
    TYPE(CD_AGG_ModuleType), INTENT(INOUT) :: self
    REAL(wp), INTENT(OUT) :: xyz(:, :)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    INTEGER :: li, ndof, nn, i, es
    CHARACTER(1024) :: em
    xyz = CD_ZERO
    IF (.NOT. require_initialized(self, ErrStat, ErrMsg)) RETURN
    IF (SIZE(xyz, 1) /= 3 .OR. SIZE(xyz, 2) /= self%nfluid) THEN
      ErrStat = CD_AGG_BADINPUT
      ErrMsg = 'CableDyn_OpenFAST_Aggregate: fluid-node position array must be shaped (3, nfluid)'
      RETURN
    END IF
    IF (self%nfluid == 0) THEN
      ErrStat = CD_AGG_OK
      ErrMsg = ''
      RETURN
    END IF
    DO li = 1, self%fl_nlines
      ndof = 3*(self%fl_off(li + 1) - self%fl_off(li))
      CALL CD_Get_System_Line_State(self%sys%fast%system, li, self%fl_q(1:ndof), self%fl_v(1:ndof), &
                                    self%fl_a(1:ndof), es, em)
      IF (es /= CD_SYSTEM_OK) THEN
        ErrStat = CD_AGG_BADINPUT
        ErrMsg = 'CableDyn_OpenFAST_Aggregate: fluid-node position read: '//TRIM(em)
        RETURN
      END IF
      nn = self%fl_off(li + 1) - self%fl_off(li)
      DO i = 1, nn
        xyz(:, self%fl_off(li) + i) = self%fl_q(3*(i - 1) + 1:3*(i - 1) + 3)
      END DO
    END DO
    DO i = 1, self%ncable
      li = self%fl_nlines + i
      CALL CD_HFMF_GetNodePositions(self%cables(i), &
                                    xyz(:, self%fl_off(li) + 1:self%fl_off(li + 1)), es, em)
      IF (es /= CD_HFMF_OK) THEN
        CALL map_hfmf_status(es, em, ErrStat, ErrMsg)
        RETURN
      END IF
    END DO
    ! Rigid6 body reference points (the fl_nbody blocks after the cables, one node each) -- the
    ! host samples SeaState here for the coupled body fluid contract.
    IF (self%fl_nbody > 0) THEN
      li = self%fl_nlines + self%ncable
      CALL CD_Rigid6_GetRefPositions(self%rigid6, &
                                     xyz(:, self%fl_off(li + 1) + 1:self%fl_off(li + 1 + self%fl_nbody)), es, em)
      IF (es /= CD_DECKDRV_OK) THEN
        ErrStat = CD_AGG_BADINPUT
        ErrMsg = 'CableDyn_OpenFAST_Aggregate: body fluid-node positions: '//TRIM(em)
        RETURN
      END IF
    END IF
    ! The NumSegs + 1 segment stations of every rigid rod.
    IF (self%fl_nrod > 0) THEN
      li = self%fl_nlines + self%ncable + self%fl_nbody
      CALL CD_Rod_GetFluidPositions(self%rod, &
                                    xyz(:, self%fl_off(li + 1) + 1:self%fl_off(li + 1 + self%fl_nrod)), es, em)
      IF (es /= CD_DECKDRV_OK) THEN
        ErrStat = CD_AGG_BADINPUT
        ErrMsg = 'CableDyn_OpenFAST_Aggregate: rod fluid-node positions: '//TRIM(em)
        RETURN
      END IF
    END IF
    ! Hydro-active dynamic points (buoys), the trailing fl_nhydropt blocks, one node each.
    IF (self%fl_nhydropt > 0) THEN
      li = self%fl_nlines + self%ncable + self%fl_nbody + self%fl_nrod
      CALL CD_Get_System_HydroPoint_Positions(self%sys%fast%system, &
                                              xyz(:, self%fl_off(li + 1) + 1:self%nfluid), es, em)
      IF (es /= CD_SYSTEM_OK) THEN
        ErrStat = CD_AGG_BADINPUT
        ErrMsg = 'CableDyn_OpenFAST_Aggregate: hydro-point fluid-node positions: '//TRIM(em)
        RETURN
      END IF
    END IF
    ErrStat = CD_AGG_OK
    ErrMsg = ''
  END SUBROUTINE CD_AGG_GetFluidNodePositions

  SUBROUTINE CD_AGG_SetFluidFields(self, fluid_velocity, fluid_acceleration, waterline_z, ErrStat, ErrMsg, &
                                   dynamic_pressure, initial_condition)
    !! Prescribe the ambient fluid kinematics at every fluid sampling node for the NEXT
    !! advance: velocity + acceleration shaped (3, nfluid), the local free-surface
    !! elevation waterline_z shaped (nfluid) (drives the wetting of drag / FK / added
    !! mass / buoyancy). Requires the wave-capable hydro build (external_fluid at Init);
    !! a plain build fails closed HERE for both line families (cables always carry a
    !! drag configuration, so the model layer alone cannot catch them).
    !! dynamic_pressure (optional, Pa, shaped (nfluid)): the wave dynamic pressure at the nodes;
    !! the rod blocks use it for the end-cap pressure (other blocks ignore it).
    !! initial_condition (optional): the field at t = 0 of a host that starts its march in it:
    !! the EI = 0 lines re-derive their start acceleration, as a cable's first field does and
    !! as the standalone routes do at their t = 0 sample.
    !! Before the first committed step (and before a state mirror is restored) the integrated
    !! bodies and rods re-solve their start accelerations in the new fields: the accelerations
    !! solved at Init saw the zero fields of the build, and the first step starts from them.
    TYPE(CD_AGG_ModuleType), INTENT(INOUT) :: self
    REAL(wp), INTENT(IN) :: fluid_velocity(:, :), fluid_acceleration(:, :), waterline_z(:)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    REAL(wp), INTENT(IN), OPTIONAL :: dynamic_pressure(:)
    LOGICAL, INTENT(IN), OPTIONAL :: initial_condition
    INTEGER :: li, o1, o2, i, es
    LOGICAL :: at_start
    CHARACTER(1024) :: em
    IF (.NOT. require_initialized(self, ErrStat, ErrMsg)) RETURN
    at_start = .FALSE.
    IF (PRESENT(initial_condition)) at_start = initial_condition
    ! Uniform contract for BOTH line families: host fields are only accepted on a
    ! build that declared them. Cables always carry a drag/added-mass configuration,
    ! so without this gate a plain cable-only build would silently accept held fields
    ! nobody declared (the mooring path happens to fail closed at the model layer).
    IF (.NOT. self%built_extfluid) THEN
      ErrStat = CD_AGG_BADINPUT
      ErrMsg = 'CableDyn_OpenFAST_Aggregate: fluid fields require an external_fluid build '// &
               '(declare host-driven ambient fluid at Init)'
      RETURN
    END IF
    IF (SIZE(fluid_velocity, 1) /= 3 .OR. SIZE(fluid_velocity, 2) /= self%nfluid .OR. &
        SIZE(fluid_acceleration, 1) /= 3 .OR. SIZE(fluid_acceleration, 2) /= self%nfluid .OR. &
        SIZE(waterline_z) /= self%nfluid) THEN
      ErrStat = CD_AGG_BADINPUT
      ErrMsg = 'CableDyn_OpenFAST_Aggregate: fluid-field arrays must be shaped (3, nfluid) / (nfluid)'
      RETURN
    END IF
    IF (.NOT. (CD_All_Finite(fluid_velocity) .AND. CD_All_Finite(fluid_acceleration) .AND. &
               CD_All_Finite(waterline_z))) THEN
      ErrStat = CD_AGG_BADINPUT
      ErrMsg = 'CableDyn_OpenFAST_Aggregate: fluid fields must be finite'
      RETURN
    END IF
    IF (PRESENT(dynamic_pressure)) THEN
      IF (SIZE(dynamic_pressure) /= self%nfluid .OR. .NOT. CD_All_Finite(dynamic_pressure)) THEN
        ErrStat = CD_AGG_BADINPUT
        ErrMsg = 'CableDyn_OpenFAST_Aggregate: the dynamic pressure must be finite and shaped (nfluid)'
        RETURN
      END IF
      IF (self%fl_nrod > 0 .AND. .NOT. (self%rho_water > CD_ZERO)) THEN
        ErrStat = CD_AGG_BADINPUT
        ErrMsg = 'CableDyn_OpenFAST_Aggregate: the rod dynamic pressure needs a positive water density'
        RETURN
      END IF
    END IF
    IF (self%nfluid == 0) THEN
      ErrStat = CD_AGG_OK
      ErrMsg = ''
      RETURN
    END IF
    DO li = 1, self%fl_nlines
      o1 = self%fl_off(li) + 1
      o2 = self%fl_off(li + 1)
      CALL CD_Update_System_Line_Hydro_Fields(self%sys%fast%system, li, es, em, &
                                              fluid_velocity=fluid_velocity(:, o1:o2), &
                                              fluid_acceleration=fluid_acceleration(:, o1:o2), &
                                              drag_waterline_z=waterline_z(o1:o2), &
                                              fk_waterline_z=waterline_z(o1:o2), &
                                              added_mass_waterline_z=waterline_z(o1:o2), &
                                              buoyancy_waterline_z=waterline_z(o1:o2))
      IF (es /= CD_SYSTEM_OK) THEN
        ErrStat = CD_AGG_BADINPUT
        ErrMsg = 'CableDyn_OpenFAST_Aggregate: fluid-field update: '//TRIM(em)
        RETURN
      END IF
      IF (at_start) THEN
        CALL CD_Recompute_Model_Acceleration(self%sys%fast%system%lines(li), es, em)
        IF (es /= CD_MODEL_OK) THEN
          ErrStat = CD_AGG_BADINPUT
          ErrMsg = 'CableDyn_OpenFAST_Aggregate: start acceleration in the fluid field: '//TRIM(em)
          RETURN
        END IF
      END IF
    END DO
    ! finite-EI cables: the held-field mode (frozen over the step; the drag adds the
    ! nodal velocity, the Froude-Krylov forcing takes the nodal acceleration, the
    ! elevation drives the wetting)
    DO i = 1, self%ncable
      li = self%fl_nlines + i
      o1 = self%fl_off(li) + 1
      o2 = self%fl_off(li + 1)
      CALL CD_HFMF_Set_Held_Fluid(self%cables(i), fluid_velocity(:, o1:o2), &
                                  fluid_acceleration(:, o1:o2), waterline_z(o1:o2), es, em)
      IF (es /= CD_HFMF_OK) THEN
        CALL map_hfmf_status(es, em, ErrStat, ErrMsg)
        RETURN
      END IF
    END DO
    ! Rigid6 body reference points (fl_nbody nodes after the cables): hold the sampled field on
    ! each body so rigid6_environment_force takes its drag / Froude-Krylov / added-mass from it.
    IF (self%fl_nbody > 0) THEN
      li = self%fl_nlines + self%ncable
      o1 = self%fl_off(li + 1) + 1
      o2 = self%fl_off(li + 1 + self%fl_nbody)
      CALL CD_Rigid6_SetHeldFluid(self%rigid6, fluid_velocity(:, o1:o2), &
                                  fluid_acceleration(:, o1:o2), waterline_z(o1:o2), es, em)
      IF (es /= CD_DECKDRV_OK) THEN
        ErrStat = CD_AGG_BADINPUT
        ErrMsg = 'CableDyn_OpenFAST_Aggregate: body held-fluid update: '//TRIM(em)
        RETURN
      END IF
    END IF
    IF (self%fl_nrod > 0) THEN
      li = self%fl_nlines + self%ncable + self%fl_nbody
      o1 = self%fl_off(li + 1) + 1
      o2 = self%fl_off(li + 1 + self%fl_nrod)
      IF (PRESENT(dynamic_pressure)) THEN
        CALL CD_Rod_SetHeldFluid(self%rod, fluid_velocity(:, o1:o2), fluid_acceleration(:, o1:o2), &
                                 waterline_z(o1:o2), es, em, dynamic_pressure=dynamic_pressure(o1:o2)/self%rho_water)
      ELSE
        CALL CD_Rod_SetHeldFluid(self%rod, fluid_velocity(:, o1:o2), &
                                 fluid_acceleration(:, o1:o2), waterline_z(o1:o2), es, em)
      END IF
      IF (es /= CD_DECKDRV_OK) THEN
        ErrStat = CD_AGG_BADINPUT
        ErrMsg = 'CableDyn_OpenFAST_Aggregate: rod held-fluid update: '//TRIM(em)
        RETURN
      END IF
    END IF
    ! Hydro-active dynamic points (trailing fl_nhydropt nodes): set the sampled field on each
    ! buoy so point_environment_force takes its drag / Froude-Krylov / added-mass from it.
    IF (self%fl_nhydropt > 0) THEN
      li = self%fl_nlines + self%ncable + self%fl_nbody + self%fl_nrod
      o1 = self%fl_off(li + 1) + 1
      o2 = self%nfluid
      CALL CD_Set_System_HydroPoint_Fluid(self%sys%fast%system, fluid_velocity(:, o1:o2), &
                                          fluid_acceleration(:, o1:o2), waterline_z(o1:o2), &
                                          self%rho_water, es, em)
      IF (es /= CD_SYSTEM_OK) THEN
        ErrStat = CD_AGG_BADINPUT
        ErrMsg = 'CableDyn_OpenFAST_Aggregate: hydro-point fluid update: '//TRIM(em)
        RETURN
      END IF
    END IF
    ! the start of the first step: the bodies' and rods' accelerations in the host's field (the
    ! OpenFAST shell sets its t = 0 field at Init, before the output call and its mirror restore)
    IF (.NOT. self%objects_committed .AND. (self%has_rigid6 .OR. self%has_rod)) THEN
      CALL start_in_fluid_fields(self, ErrStat, ErrMsg)
      IF (ErrStat /= CD_AGG_OK) RETURN
    END IF
    ErrStat = CD_AGG_OK
    ErrMsg = ''
  END SUBROUTINE CD_AGG_SetFluidFields

  SUBROUTINE start_in_fluid_fields(self, ErrStat, ErrMsg)
    !! The start of the first step in new host fluid fields (CD_AGG_SetFluidFields before the first
    !! committed step): a committed transfer of the EI=0 system's present moving-point kinematics,
    !! which solves the line interior accelerations in the fields (the end-node loads on the
    !! objects carry their consistent inertia), then the bodies' and rods' start accelerations --
    !! the start a step-start transfer (CD_AGG_UpdateStates_Moving) gives in the same fields.
    TYPE(CD_AGG_ModuleType), INTENT(INOUT) :: self
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    REAL(wp), ALLOCATABLE :: pos(:, :), vel(:, :), acc(:, :), load(:, :)
    INTEGER :: n, es, stat
    CHARACTER(1024) :: em
    ErrStat = CD_AGG_OK
    ErrMsg = ''
    IF (.NOT. self%has_sys) RETURN
    n = CD_FMF_NMovingPoints(self%sys, es, em)
    IF (es /= CD_FMF_OK) THEN
      CALL map_fmf_status(es, em, ErrStat, ErrMsg)
      RETURN
    END IF
    ALLOCATE (pos(3, n), vel(3, n), acc(3, n), load(3, n), STAT=stat)
    IF (stat /= 0) THEN
      ErrStat = CD_AGG_ALLOCFAIL
      ErrMsg = 'CableDyn_OpenFAST_Aggregate: start-state workspace allocation failed'
      RETURN
    END IF
    CALL CD_FMF_GetMovingPointMesh(self%sys, pos, vel, acc, load, es, em)
    IF (es == CD_FMF_OK) CALL CD_FMF_UpdateStates_Moving(self%sys, pos, vel, acc, es, em)
    IF (es /= CD_FMF_OK) THEN
      CALL map_fmf_status(es, em, ErrStat, ErrMsg)
      RETURN
    END IF
    CALL start_object_accelerations(self, ErrStat, ErrMsg)
  END SUBROUTINE start_in_fluid_fields

  SUBROUTINE CD_AGG_CalcOutput(self, ErrStat, ErrMsg)
    !! Compute the EI=0 system loads at the current committed state (stored in the system's
    !! output/point mesh). Each cable's fairlead reaction is read on demand in
    !! CD_AGG_GetMovingPointMesh (the FMF "loads after the step" contract), so there is
    !! nothing to precompute here for the cable columns.
    TYPE(CD_AGG_ModuleType), INTENT(INOUT) :: self
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg

    INTEGER :: es
    CHARACTER(1024) :: em

    IF (.NOT. require_initialized(self, ErrStat, ErrMsg)) RETURN
    IF (self%has_sys) THEN
      CALL CD_FMF_CalcOutput(self%sys, es, em)
      IF (es /= CD_FMF_OK) THEN
        CALL map_fmf_status(es, em, ErrStat, ErrMsg)
        RETURN
      END IF
    END IF
    ErrStat = CD_AGG_OK
    ErrMsg = ''
  END SUBROUTINE CD_AGG_CalcOutput

  SUBROUTINE CD_AGG_Get_Failure_Flags(self, flags, ErrStat, ErrMsg)
    !! Fired flags per FAILURE row (checkpoint pack surface).
    TYPE(CD_AGG_ModuleType), INTENT(IN) :: self
    LOGICAL, INTENT(OUT) :: flags(:)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    INTEGER :: k
    ErrStat = CD_AGG_OK
    ErrMsg = ''
    IF (.NOT. ALLOCATED(self%failures) .OR. SIZE(flags) /= CD_AGG_NFailures(self)) THEN
      ErrStat = CD_AGG_BADINPUT
      ErrMsg = 'CableDyn_OpenFAST_Aggregate: failure-flag query needs one slot per FAILURE row'
      RETURN
    END IF
    DO k = 1, SIZE(flags)
      flags(k) = self%failures(k)%failed
    END DO
  END SUBROUTINE CD_AGG_Get_Failure_Flags

  SUBROUTINE CD_AGG_Set_Failure_Flags(self, flags, ErrStat, ErrMsg)
    !! Checkpoint-restore replay surface: bring a freshly initialized aggregate's
    !! failure topology up to the restored flags (detach replay, still-bound
    !! filtered) BEFORE the state blocks are restored, then re-derive the facade
    !! point mesh. Un-firing fails closed (a rebuild is the only way back).
    TYPE(CD_AGG_ModuleType), INTENT(INOUT) :: self
    LOGICAL, INTENT(IN) :: flags(:)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    INTEGER :: es
    CHARACTER(1024) :: em
    ErrStat = CD_AGG_OK
    ErrMsg = ''
    IF (.NOT. require_initialized(self, ErrStat, ErrMsg)) RETURN
    IF (.NOT. ALLOCATED(self%failures) .OR. SIZE(flags) /= CD_AGG_NFailures(self) .OR. .NOT. self%has_sys) THEN
      ErrStat = CD_AGG_BADINPUT
      ErrMsg = 'CableDyn_OpenFAST_Aggregate: failure-flag replay needs one flag per FAILURE row on a '// &
               'failure-capable aggregate'
      RETURN
    END IF
    CALL CD_Replay_Deck_Failures(self%sys%fast%system, self%fail_lines, self%fail_points, &
                                 self%failures, flags, es, em)
    IF (es /= CD_DECKDRV_OK) THEN
      CALL map_deck_status(es, em, ErrStat, ErrMsg)
      RETURN
    END IF
    CALL CD_FMF_Refresh_PointMesh(self%sys, es, em)
    IF (es /= CD_FMF_OK) CALL map_fmf_status(es, em, ErrStat, ErrMsg)
  END SUBROUTINE CD_AGG_Set_Failure_Flags

  INTEGER FUNCTION CD_AGG_NCtrlChans(self) RESULT(n)
    !! Highest CONTROL channel id the deck declares (the u%DeltaL allocation rule;
    !! 0 when the deck declares no CONTROL section).
    TYPE(CD_AGG_ModuleType), INTENT(IN) :: self
    n = self%n_ctrl_chans
  END FUNCTION CD_AGG_NCtrlChans

  SUBROUTINE CD_AGG_Apply_LineControl(self, delta_l, delta_l_dot, ErrStat, ErrMsg, restored)
    !! Apply the host's cable-control command BEFORE an advance to the deck segment at the
    !! fairlead-side end of each controlled line: the end on a host-driven point, else the
    !! written NodeB (MoorDyn's AttachB, its segment N). On an EI = 0 line that element's
    !! unstretched length becomes base + delta_l(chan) with rate delta_l_dot(chan) -- the
    !! MoorDyn convention. On a finite-EI cable every cable element of that segment (base
    !! length S) scales by (S + delta_l)/S, with rate delta_l_dot*l_e/S, so the segment takes
    !! the same length and rate.
    !! A command outside MoorDyn-F's bounds fails closed by channel and line, as MoorDyn-F
    !! stops the run there (ErrID_Fatal): with UnstrLen and N the deck line's unstretched
    !! length and segment count (summed over its sections), MoorDyn-F refuses
    !! DeltaL > UnstrLen/N and DeltaL < -0.5*UnstrLen/N (MoorDyn.f90, the active-tension
    !! bounds check), the same comparisons in the same precision, so a command MoorDyn-F
    !! accepts is accepted here. On a uniform line UnstrLen/N is the controlled segment's
    !! base length S. On a line of several sections the controlled segment can be shorter
    !! than UnstrLen/N/2, so a command within the bounds can still make it non-positive;
    !! that fails closed as well.
    !! Every row is checked before any line changes, and the objects the loop already
    !! changed are put back, bit for bit, if a later row fails after all (a capability the
    !! initialisation could not verify, an allocation): a refused command writes nothing.
    !! On both kinds the committed state keeps the lengths it was reached with until the
    !! next advance commits the new ones. restored = .TRUE. is the checkpoint-restart
    !! re-application of the command the committed state was reached with: the lengths
    !! become the committed ones at once.
    TYPE(CD_AGG_ModuleType), INTENT(INOUT) :: self
    REAL(wp), INTENT(IN) :: delta_l(:), delta_l_dot(:)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    LOGICAL, INTENT(IN), OPTIONAL :: restored

    INTEGER :: c, ch, es, nspan, k, nrow
    REAL(wp) :: lambda, mean_seg
    CHARACTER(1024) :: em
    CHARACTER(16) :: line_kind

    ErrStat = CD_AGG_OK
    ErrMsg = ''
    IF (.NOT. require_initialized(self, ErrStat, ErrMsg)) RETURN
    IF (.NOT. ALLOCATED(self%ctrl_chan)) RETURN
    IF (SIZE(delta_l) < self%n_ctrl_chans .OR. SIZE(delta_l_dot) < self%n_ctrl_chans) THEN
      ErrStat = CD_AGG_BADINPUT
      ErrMsg = 'CableDyn_OpenFAST_Aggregate: the control command must cover every declared channel'
      RETURN
    END IF
    IF (.NOT. (CD_All_Finite(delta_l) .AND. CD_All_Finite(delta_l_dot))) THEN
      ErrStat = CD_AGG_BADINPUT
      ErrMsg = 'CableDyn_OpenFAST_Aggregate: the control command must be finite'
      RETURN
    END IF
    nrow = SIZE(self%ctrl_chan)
    ! PREVALIDATE every row before mutating any line
    DO c = 1, nrow
      ch = self%ctrl_chan(c)
      IF (self%ctrl_is_cable(c)) THEN
        line_kind = 'finite-EI'
        IF (self%ctrl_line(c) < 1 .OR. self%ctrl_line(c) > self%ncable) THEN
          ErrStat = CD_AGG_BADINPUT
          ErrMsg = 'CableDyn_OpenFAST_Aggregate: line control addresses a cable the aggregate does not own'
          RETURN
        END IF
      ELSE
        line_kind = 'EI = 0'
        IF (.NOT. self%has_sys) THEN
          ErrStat = CD_AGG_BADINPUT
          ErrMsg = 'CableDyn_OpenFAST_Aggregate: line control requires the EI=0 system'
          RETURN
        END IF
      END IF
      ! MoorDyn-F's bounds, written as MoorDyn-F evaluates them
      mean_seg = self%ctrl_unstr_len(c)/REAL(self%ctrl_nsegs(c), wp)
      IF (delta_l(ch) > self%ctrl_unstr_len(c)/REAL(self%ctrl_nsegs(c), wp) .OR. &
          delta_l(ch) < -0.5_wp*self%ctrl_unstr_len(c)/REAL(self%ctrl_nsegs(c), wp)) THEN
        ErrStat = CD_AGG_BADINPUT
        WRITE (em, '(A,I0,A,ES12.5,A,I0,A,ES12.5,A)') 'CableDyn_OpenFAST_Aggregate: control channel ', ch, &
          ' commands DeltaL = ', delta_l(ch), ' m on '//TRIM(line_kind)//' line ', self%ctrl_line_id(c), &
          ', outside MoorDyn-F''s bounds -S/2 <= DeltaL <= S (S = UnstrLen/N = ', mean_seg, ' m)'
        ErrMsg = TRIM(em)
        RETURN
      END IF
      IF (.NOT. (self%ctrl_base_l0(c) + delta_l(ch) > CD_ZERO)) THEN
        ErrStat = CD_AGG_BADINPUT
        WRITE (em, '(A,I0,A,ES12.5,A,I0,A,ES12.5,A)') 'CableDyn_OpenFAST_Aggregate: control channel ', ch, &
          ' commands DeltaL = ', delta_l(ch), ' m on '//TRIM(line_kind)//' line ', self%ctrl_line_id(c), &
          ', which would make its controlled segment (', self%ctrl_base_l0(c), ' m long) non-positive'
        ErrMsg = TRIM(em)
        RETURN
      END IF
    END DO
    ! The objects each row changes, as they are before its change (kept from step to step,
    ! so the saves allocate once)
    IF (ALLOCATED(self%ctrl_cable_saved)) THEN
      IF (SIZE(self%ctrl_cable_saved) /= nrow) DEALLOCATE (self%ctrl_cable_saved, self%ctrl_line_saved)
    END IF
    IF (.NOT. ALLOCATED(self%ctrl_cable_saved)) ALLOCATE (self%ctrl_cable_saved(nrow), self%ctrl_line_saved(nrow))
    DO c = 1, nrow
      ch = self%ctrl_chan(c)
      IF (self%ctrl_is_cable(c)) THEN
        CALL CD_HermiteCable_Dyn_Save_Control(self%cables(self%ctrl_line(c))%line, self%ctrl_cable_saved(c))
        nspan = self%ctrl_nelem(c)
        BLOCK
          INTEGER :: elems(nspan)
          REAL(wp) :: l0_new(nspan), l0_rate(nspan), base
          lambda = (self%ctrl_base_l0(c) + delta_l(ch))/self%ctrl_base_l0(c)
          DO k = 1, nspan
            base = self%ctrl_span_l0(self%ctrl_span_off(c) + k)
            elems(k) = self%ctrl_elem(c) + k - 1
            l0_new(k) = base*lambda
            l0_rate(k) = delta_l_dot(ch)*base/self%ctrl_base_l0(c)
          END DO
          CALL CD_HFMF_Set_SegmentLength(self%cables(self%ctrl_line(c)), elems, l0_new, l0_rate, es, em, &
                                         restored=restored)
        END BLOCK
        IF (es /= CD_HFMF_OK) THEN
          CALL take_back(c - 1, 'CableDyn_OpenFAST_Aggregate: line-control update failed: '//TRIM(em))
          RETURN
        END IF
      ELSE
        CALL CD_Save_System_Line_Control(self%sys%fast%system, self%ctrl_line(c), self%ctrl_line_saved(c), es, em)
        IF (es == CD_SYSTEM_OK) &
          CALL CD_Update_System_Line_SegmentLength(self%sys%fast%system, self%ctrl_line(c), self%ctrl_elem(c), &
                                                   self%ctrl_base_l0(c) + delta_l(ch), delta_l_dot(ch), es, em, &
                                                   restored=restored)
        IF (es /= CD_SYSTEM_OK) THEN
          CALL take_back(c - 1, 'CableDyn_OpenFAST_Aggregate: line-control update failed: '//TRIM(em))
          RETURN
        END IF
      END IF
    END DO

  CONTAINS

    SUBROUTINE take_back(last, msg)
      !! A row failed after the rows 1..last were applied: put their objects back, the latest
      !! first (a line named in two rows ends at its state before the first), and report msg.
      INTEGER, INTENT(IN) :: last
      CHARACTER(*), INTENT(IN) :: msg
      INTEGER :: r, es2
      CHARACTER(1024) :: em2, em_undo
      em_undo = ''
      DO r = last, 1, -1
        IF (self%ctrl_is_cable(r)) THEN
          CALL CD_HermiteCable_Dyn_Restore_Control(self%cables(self%ctrl_line(r))%line, self%ctrl_cable_saved(r), &
                                                   es2, em2)
          IF (es2 /= CD_HCDYN_OK) em_undo = em2
        ELSE
          CALL CD_Restore_System_Line_Control(self%sys%fast%system, self%ctrl_line(r), self%ctrl_line_saved(r), &
                                              es2, em2)
          IF (es2 /= CD_SYSTEM_OK) em_undo = em2
        END IF
      END DO
      ErrStat = CD_AGG_BADINPUT
      IF (LEN_TRIM(em_undo) == 0) THEN
        ErrMsg = msg
      ELSE
        ErrMsg = msg//'; the lines it had already changed could not all be put back: '//TRIM(em_undo)
      END IF
    END SUBROUTINE take_back
  END SUBROUTINE CD_AGG_Apply_LineControl

  INTEGER FUNCTION CD_AGG_NFailures(self) RESULT(n)
    !! Number of FAILURE rows the aggregate carries (0 when the deck declares none).
    TYPE(CD_AGG_ModuleType), INTENT(IN) :: self
    n = 0
    IF (ALLOCATED(self%failures)) n = SIZE(self%failures)
  END FUNCTION CD_AGG_NFailures

  SUBROUTINE CD_AGG_Get_Substep_Counts(self, calls, events, max_used, capped, fallbacks)
    !! The rotation- and snap-resolved sub-stepping diagnostics of the EI=0 lines of the
    !! aggregate (CD_Get_System_Substep_Counts; all zero without EI=0 lines): line steps
    !! examined, solved in sub-steps (max_used the largest count), beyond ei0_substep_max, and
    !! kept the plain step's result after a sub-step failed.
    TYPE(CD_AGG_ModuleType), INTENT(IN) :: self
    INTEGER(int64), INTENT(OUT) :: calls, events, capped, fallbacks
    INTEGER, INTENT(OUT) :: max_used
    calls = 0; events = 0; max_used = 1; capped = 0; fallbacks = 0
    IF (self%has_sys) CALL CD_Get_System_Substep_Counts(self%sys%fast%system, calls, events, max_used, capped, &
                                                        fallbacks)
  END SUBROUTINE CD_AGG_Get_Substep_Counts

  SUBROUTINE CD_AGG_End(self, ErrStat, ErrMsg)
    !! Release all owned resources. Idempotent by design (CD_FMF_End / CD_HFMF_End are safe
    !! on uninitialized members).
    TYPE(CD_AGG_ModuleType), INTENT(INOUT) :: self
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg

    INTEGER :: c, es
    CHARACTER(1024) :: em

    CALL CD_FMF_End(self%sys, es, em)
    self%has_sys = .FALSE.
    IF (ALLOCATED(self%cables)) THEN
      DO c = 1, SIZE(self%cables)
        CALL CD_HFMF_End(self%cables(c))
      END DO
      DEALLOCATE (self%cables)
    END IF
    IF (ALLOCATED(self%mv_pos)) DEALLOCATE (self%mv_pos)
    IF (ALLOCATED(self%mv_vel)) DEALLOCATE (self%mv_vel)
    IF (ALLOCATED(self%mv_acc)) DEALLOCATE (self%mv_acc)
    IF (ALLOCATED(self%mv_load)) DEALLOCATE (self%mv_load)
    IF (ALLOCATED(self%mv_moment)) DEALLOCATE (self%mv_moment)
    IF (ALLOCATED(self%mv_orient)) DEALLOCATE (self%mv_orient)
    IF (ALLOCATED(self%mv_omega)) DEALLOCATE (self%mv_omega)
    IF (ALLOCATED(self%mv_alpha)) DEALLOCATE (self%mv_alpha)
    IF (ALLOCATED(self%mv_roll)) DEALLOCATE (self%mv_roll)
    IF (ALLOCATED(self%cable_phi0)) DEALLOCATE (self%cable_phi0)
    CALL CD_Motion_End(self%motion)
    CALL CD_Deck_Current_End(self%current)
    IF (ALLOCATED(self%cable_stat)) DEALLOCATE (self%cable_stat)
    IF (ALLOCATED(self%cable_msg)) DEALLOCATE (self%cable_msg)
    IF (ALLOCATED(self%channels)) DEALLOCATE (self%channels)
    IF (ALLOCATED(self%chan_units)) DEALLOCATE (self%chan_units)
    IF (ALLOCATED(self%line_is_cable)) DEALLOCATE (self%line_is_cable)
    IF (ALLOCATED(self%line_obj_index)) DEALLOCATE (self%line_obj_index)
    IF (ALLOCATED(self%cable_points)) DEALLOCATE (self%cable_points)
    IF (ALLOCATED(self%fl_off)) DEALLOCATE (self%fl_off)
    IF (ALLOCATED(self%fl_q)) DEALLOCATE (self%fl_q)
    IF (ALLOCATED(self%fl_v)) DEALLOCATE (self%fl_v)
    IF (ALLOCATED(self%fl_a)) DEALLOCATE (self%fl_a)
    self%nfluid = 0
    self%fl_nlines = 0
    self%fl_nbody = 0
    self%fl_nrod = 0
    self%fl_nhydropt = 0
    self%built_extfluid = .FALSE.
    self%host_wave_enabled = .FALSE.
    self%host_current_enabled = .FALSE.
    self%cable_load_feedback = .TRUE.
    self%max_strain = 0.5_wp
    IF (ALLOCATED(self%host_current_profile_z)) DEALLOCATE (self%host_current_profile_z)
    IF (ALLOCATED(self%host_current_profile_velocity)) DEALLOCATE (self%host_current_profile_velocity)
    self%ncp_sys = 0
    self%ncable = 0
    self%ncable_b = 0
    IF (ALLOCATED(self%cable_col_b)) DEALLOCATE (self%cable_col_b)
    self%n_lines = 0
    self%n_points = 0
    self%n_sections = 0
    self%n_ei0_lines = 0
    self%n_finite_ei_lines = 0
    IF (ALLOCATED(self%init_lines)) DEALLOCATE (self%init_lines)
    self%dt = CD_ZERO
    self%n_turbines = 0
    IF (ALLOCATED(self%turbine_of_moving)) DEALLOCATE (self%turbine_of_moving)
    IF (ALLOCATED(self%failures)) DEALLOCATE (self%failures)
    IF (ALLOCATED(self%fail_lines)) DEALLOCATE (self%fail_lines)
    IF (ALLOCATED(self%fail_points)) DEALLOCATE (self%fail_points)
    IF (ALLOCATED(self%snap_failures)) DEALLOCATE (self%snap_failures)
    self%n_ctrl_chans = 0
    IF (ALLOCATED(self%ctrl_chan)) DEALLOCATE (self%ctrl_chan)
    IF (ALLOCATED(self%ctrl_line)) DEALLOCATE (self%ctrl_line)
    IF (ALLOCATED(self%ctrl_elem)) DEALLOCATE (self%ctrl_elem)
    IF (ALLOCATED(self%ctrl_nelem)) DEALLOCATE (self%ctrl_nelem)
    IF (ALLOCATED(self%ctrl_base_l0)) DEALLOCATE (self%ctrl_base_l0)
    IF (ALLOCATED(self%ctrl_unstr_len)) DEALLOCATE (self%ctrl_unstr_len)
    IF (ALLOCATED(self%ctrl_nsegs)) DEALLOCATE (self%ctrl_nsegs)
    IF (ALLOCATED(self%ctrl_cable_saved)) DEALLOCATE (self%ctrl_cable_saved)
    IF (ALLOCATED(self%ctrl_line_saved)) DEALLOCATE (self%ctrl_line_saved)
    IF (ALLOCATED(self%ctrl_is_cable)) DEALLOCATE (self%ctrl_is_cable)
    IF (ALLOCATED(self%ctrl_line_id)) DEALLOCATE (self%ctrl_line_id)
    IF (ALLOCATED(self%ctrl_span_off)) DEALLOCATE (self%ctrl_span_off)
    IF (ALLOCATED(self%ctrl_span_l0)) DEALLOCATE (self%ctrl_span_l0)
    CALL CD_Rigid6_End(self%rigid6)
    self%has_rigid6 = .FALSE.
    CALL CD_Rod_End(self%rod)
    self%has_rod = .FALSE.
    self%has_point3 = .FALSE.
    CALL CD_Range_End(self%ranges)
    IF (ALLOCATED(self%snap_range)) DEALLOCATE (self%snap_range)
    self%nhost_rod = 0
    self%nhost_body = 0
    IF (ALLOCATED(self%hf_mask)) DEALLOCATE (self%hf_mask)
    IF (ALLOCATED(self%hf_q)) DEALLOCATE (self%hf_q)
    IF (ALLOCATED(self%hf_v)) DEALLOCATE (self%hf_v)
    IF (ALLOCATED(self%hf_a)) DEALLOCATE (self%hf_a)
    IF (ALLOCATED(self%hb_pos)) DEALLOCATE (self%hb_pos)
    IF (ALLOCATED(self%hb_vel)) DEALLOCATE (self%hb_vel)
    IF (ALLOCATED(self%hb_acc)) DEALLOCATE (self%hb_acc)
    IF (ALLOCATED(self%hb_load)) DEALLOCATE (self%hb_load)
    self%initialized = .FALSE.
    ErrStat = CD_AGG_OK
    ErrMsg = ''
  END SUBROUTINE CD_AGG_End

  LOGICAL FUNCTION CD_AGG_IsInitialized(self) RESULT(is_initialized)
    !! Query whether the facade owns an initialized composition.
    TYPE(CD_AGG_ModuleType), INTENT(IN) :: self

    is_initialized = self%initialized
  END FUNCTION CD_AGG_IsInitialized

  INTEGER FUNCTION CD_AGG_NumChannels(self) RESULT(n)
    !! Number of deck OUTPUTS channels this module emits to the OpenFAST WriteOutput surface
    !! (0 when the deck declares no OUTPUTS -- the coupled run then writes no CableDyn columns).
    TYPE(CD_AGG_ModuleType), INTENT(IN) :: self

    n = 0
    IF (self%initialized .AND. ALLOCATED(self%channels)) n = SIZE(self%channels)
  END FUNCTION CD_AGG_NumChannels

  SUBROUTINE CD_AGG_GetInitMetadata(self, n_lines, n_points, n_sections, n_ei0, n_finite_ei, ErrStat, ErrMsg)
    !! Return the parsed inventory behind the converged initialization report.
    TYPE(CD_AGG_ModuleType), INTENT(IN) :: self
    INTEGER, INTENT(OUT) :: n_lines, n_points, n_sections, n_ei0, n_finite_ei
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg

    n_lines = 0; n_points = 0; n_sections = 0; n_ei0 = 0; n_finite_ei = 0
    IF (.NOT. require_initialized(self, ErrStat, ErrMsg)) RETURN
    n_lines = self%n_lines
    n_points = self%n_points
    n_sections = self%n_sections
    n_ei0 = self%n_ei0_lines
    n_finite_ei = self%n_finite_ei_lines
    ErrStat = CD_AGG_OK
    ErrMsg = ''
  END SUBROUTINE CD_AGG_GetInitMetadata

  SUBROUTINE CD_AGG_GetInitLine(self, i, line_id, tension, force, inclination, declination, azimuth, ErrStat, ErrMsg, &
                                note)
    !! Return one line's unconditional converged-static fairlead result in deck order, and
    !! (optional note) its static-initialisation notes, one per text line: those of a finite-EI
    !! cable or the fold note of an EI = 0 line, the static strain note and the dtM advisory
    !! ('' if none).
    TYPE(CD_AGG_ModuleType), INTENT(IN) :: self
    INTEGER, INTENT(IN) :: i
    INTEGER, INTENT(OUT) :: line_id
    REAL(wp), INTENT(OUT) :: tension, force(3), inclination, declination, azimuth
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    CHARACTER(*), INTENT(OUT), OPTIONAL :: note
    LOGICAL :: in_range

    IF (PRESENT(note)) note = ''
    line_id = 0
    tension = CD_ZERO; force = CD_ZERO
    inclination = CD_ZERO; declination = CD_ZERO; azimuth = CD_ZERO
    IF (.NOT. require_initialized(self, ErrStat, ErrMsg)) RETURN
    ! Nested tests: Fortran does not short-circuit .OR., so SIZE must not be taken of
    ! an unallocated array.
    in_range = ALLOCATED(self%init_lines)
    IF (in_range) in_range = i >= 1 .AND. i <= SIZE(self%init_lines)
    IF (.NOT. in_range) THEN
      ErrStat = CD_AGG_BADINPUT
      ErrMsg = 'CableDyn_OpenFAST_Aggregate: initialization-report line index out of range'
      RETURN
    END IF
    line_id = self%init_lines(i)%line_id
    tension = self%init_lines(i)%fair_tension
    force = self%init_lines(i)%fair_force
    inclination = self%init_lines(i)%fair_inclination
    declination = self%init_lines(i)%fair_declination
    azimuth = self%init_lines(i)%fair_azimuth
    IF (PRESENT(note)) note = self%init_lines(i)%note
    ErrStat = CD_AGG_OK
    ErrMsg = ''
  END SUBROUTINE CD_AGG_GetInitLine

  SUBROUTINE CD_AGG_ChannelHeader(self, i, hdr, unt, ErrStat, ErrMsg)
    !! Header token and OrcaFlex unit label for channel i (1 .. CD_AGG_NumChannels), for the
    !! OpenFAST InitOut%WriteOutputHdr / WriteOutputUnt registration.
    TYPE(CD_AGG_ModuleType), INTENT(IN) :: self
    INTEGER, INTENT(IN) :: i
    CHARACTER(*), INTENT(OUT) :: hdr, unt
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg

    hdr = ''
    unt = ''
    IF (.NOT. require_initialized(self, ErrStat, ErrMsg)) RETURN
    IF (.NOT. ALLOCATED(self%channels) .OR. i < 1 .OR. i > CD_AGG_NumChannels(self)) THEN
      ErrStat = CD_AGG_BADINPUT
      ErrMsg = 'CableDyn_OpenFAST_Aggregate: channel index out of range'
      RETURN
    END IF
    ! The host header buffer (OpenFAST ChanLen on the coupled route) bounds the name:
    ! a truncated header could collide with another channel, so a longer name fails.
    IF (LEN_TRIM(self%channels(i)) > LEN(hdr) .OR. LEN_TRIM(self%chan_units(i)) > LEN(unt)) THEN
      BLOCK
        CHARACTER(16) :: n_name, n_host
        WRITE (n_name, '(I0)') LEN_TRIM(self%channels(i))
        WRITE (n_host, '(I0)') LEN(hdr)
        ErrStat = CD_AGG_BADINPUT
        ErrMsg = 'CableDyn_OpenFAST_Aggregate: OUTPUTS channel "'//TRIM(self%channels(i))//'" has '// &
                 TRIM(n_name)//' characters; the host output header holds at most '//TRIM(n_host)// &
                 '; shorten the channel name'
      END BLOCK
      RETURN
    END IF
    hdr = TRIM(self%channels(i))
    unt = TRIM(self%chan_units(i))
    ErrStat = CD_AGG_OK
    ErrMsg = ''
  END SUBROUTINE CD_AGG_ChannelHeader

  SUBROUTINE CD_AGG_EvalChannel(self, i, value, ErrStat, ErrMsg)
    !! Evaluate channel i (1 .. CD_AGG_NumChannels) against the built aggregate at its current
    !! committed state. Delegates to CD_Eval_Aggregate_Channel (the DeckDriver evaluator) so the
    !! module reports the SAME value the standalone driver computes for that channel on the same
    !! configuration. Resolve to the EI=0 system's line/point state or a finite-EI cable's state
    !! through the retained deck-line-id map.
    TYPE(CD_AGG_ModuleType), INTENT(INOUT) :: self
    INTEGER, INTENT(IN) :: i
    REAL(wp), INTENT(OUT) :: value
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg

    INTEGER :: es
    CHARACTER(1024) :: em

    value = CD_ZERO
    IF (.NOT. require_initialized(self, ErrStat, ErrMsg)) RETURN
    IF (.NOT. ALLOCATED(self%channels) .OR. i < 1 .OR. i > CD_AGG_NumChannels(self)) THEN
      ErrStat = CD_AGG_BADINPUT
      ErrMsg = 'CableDyn_OpenFAST_Aggregate: channel index out of range'
      RETURN
    END IF
    IF (self%has_rigid6) THEN
      CALL CD_Eval_Aggregate_Channel(self%channels(i), self%has_sys, self%sys%fast%system, self%cables, &
                                     self%line_is_cable, self%line_obj_index, value, es, em, &
                                     cable_points=self%cable_points, rigid_rt=self%rigid6, ranges=self%ranges)
    ELSE IF (self%has_rod) THEN
      CALL CD_Eval_Aggregate_Channel(self%channels(i), self%has_sys, self%sys%fast%system, self%cables, &
                                     self%line_is_cable, self%line_obj_index, value, es, em, &
                                     cable_points=self%cable_points, rod_rt=self%rod, ranges=self%ranges)
    ELSE
      CALL CD_Eval_Aggregate_Channel(self%channels(i), self%has_sys, self%sys%fast%system, self%cables, &
                                     self%line_is_cable, self%line_obj_index, value, es, em, &
                                     cable_points=self%cable_points, ranges=self%ranges)
    END IF
    CALL map_deck_status(es, em, ErrStat, ErrMsg)
  END SUBROUTINE CD_AGG_EvalChannel

  SUBROUTINE CD_AGG_Range_Sample(self, time, ErrStat, ErrMsg)
    !! Accumulate the range graphs (LINES flag r) at a committed output time: once per written
    !! row on the standalone mixed route, once per committed mooring step in the OpenFAST module.
    TYPE(CD_AGG_ModuleType), INTENT(INOUT) :: self
    REAL(wp), INTENT(IN) :: time
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    INTEGER :: es
    CHARACTER(1024) :: em

    IF (.NOT. require_initialized(self, ErrStat, ErrMsg)) RETURN
    IF (.NOT. self%ranges%active) RETURN
    IF (ALLOCATED(self%cables)) THEN
      CALL CD_Deck_Range_Sample_Aggregate(self%ranges, self%has_sys, self%sys%fast%system, self%cables, &
                                          self%line_is_cable, self%line_obj_index, time, es, em)
    ELSE
      BLOCK
        TYPE(CD_HFMF_ModuleType) :: no_cables(0)
        CALL CD_Deck_Range_Sample_Aggregate(self%ranges, self%has_sys, self%sys%fast%system, no_cables, &
                                            self%line_is_cable, self%line_obj_index, time, es, em)
      END BLOCK
    END IF
    CALL map_deck_status(es, em, ErrStat, ErrMsg)
  END SUBROUTINE CD_AGG_Range_Sample

  SUBROUTINE CD_AGG_Range_Write(self, root, ErrStat, ErrMsg)
    !! Write <root>.Line<L>.range.out for every line with the LINES flag r.
    TYPE(CD_AGG_ModuleType), INTENT(IN) :: self
    CHARACTER(*), INTENT(IN) :: root
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    INTEGER :: es
    CHARACTER(1024) :: em

    IF (.NOT. require_initialized(self, ErrStat, ErrMsg)) RETURN
    CALL CD_Deck_Range_Write(self%ranges, root, es, em)
    CALL map_deck_status(es, em, ErrStat, ErrMsg)
  END SUBROUTINE CD_AGG_Range_Write

  SUBROUTINE CD_AGG_Range_Discard(self, root, ErrStat, ErrMsg)
    !! Remove the <root>.Line<L>.range.out files an earlier run left (CD_Range_Discard_Files).
    TYPE(CD_AGG_ModuleType), INTENT(IN) :: self
    CHARACTER(*), INTENT(IN) :: root
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    INTEGER :: es
    CHARACTER(1024) :: em

    IF (.NOT. require_initialized(self, ErrStat, ErrMsg)) RETURN
    CALL CD_Range_Discard_Files(self%ranges, root, es, em)
    IF (es /= CD_RANGE_OK) THEN
      ErrStat = CD_AGG_BADINPUT
      ErrMsg = 'CableDyn_OpenFAST_Aggregate: '//TRIM(em)
    END IF
  END SUBROUTINE CD_AGG_Range_Discard

  LOGICAL FUNCTION CD_AGG_Range_Graphs(self) RESULT(yes)
    !! True when a line of the deck carries the LINES flag r; touchdown channels alone need no
    !! sampling, they are evaluated from the state.
    TYPE(CD_AGG_ModuleType), INTENT(IN) :: self
    yes = CD_Range_Has_Graph(self%ranges)
  END FUNCTION CD_AGG_Range_Graphs

  INTEGER FUNCTION CD_AGG_Range_MirrorSize(self) RESULT(n)
    !! Reals of the accumulated range graphs (checkpoint pack surface; 0 without a LINES flag r).
    TYPE(CD_AGG_ModuleType), INTENT(IN) :: self
    n = CD_Range_Mirror_Size(self%ranges)
  END FUNCTION CD_AGG_Range_MirrorSize

  SUBROUTINE CD_AGG_Range_Get_State(self, state, ErrStat, ErrMsg)
    !! The accumulated range graphs, CD_AGG_Range_MirrorSize reals (checkpoint pack surface).
    TYPE(CD_AGG_ModuleType), INTENT(IN) :: self
    REAL(wp), INTENT(OUT) :: state(:)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg

    IF (.NOT. require_initialized(self, ErrStat, ErrMsg)) RETURN
    IF (SIZE(state) /= CD_Range_Mirror_Size(self%ranges)) THEN
      ErrStat = CD_AGG_BADINPUT
      ErrMsg = 'CableDyn_OpenFAST_Aggregate: range-graph query needs CD_AGG_Range_MirrorSize slots'
      RETURN
    END IF
    CALL CD_Range_Get_State(self%ranges, state)
  END SUBROUTINE CD_AGG_Range_Get_State

  SUBROUTINE CD_AGG_Range_Set_State(self, state, ErrStat, ErrMsg)
    !! Reload the accumulated range graphs of CD_AGG_Range_Get_State (checkpoint restore surface).
    TYPE(CD_AGG_ModuleType), INTENT(INOUT) :: self
    REAL(wp), INTENT(IN) :: state(:)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    INTEGER :: es
    CHARACTER(1024) :: em

    IF (.NOT. require_initialized(self, ErrStat, ErrMsg)) RETURN
    CALL CD_Range_Set_State(self%ranges, state, es, em)
    IF (es /= CD_RANGE_OK) THEN
      ErrStat = CD_AGG_BADINPUT
      ErrMsg = 'CableDyn_OpenFAST_Aggregate: '//TRIM(em)
    END IF
  END SUBROUTINE CD_AGG_Range_Set_State

  SUBROUTINE CD_AGG_WriteStaticProfile(self, path, ErrStat, ErrMsg)
    !! Write the converged coupled initialization as an OrcaFlex-statics-style range table.
    !! This file is independent of the deck OUTPUTS selection: every line and every node is
    !! recorded in public End A -> End B order with deformed arc length, global coordinates,
    !! effective tension, curvature, bend moment, declination, signed inclination below the
    !! horizontal, and azimuth. The channel evaluator remains the single source of truth for
    !! every reported physical quantity, so standalone and coupled results share conventions.
    TYPE(CD_AGG_ModuleType), INTENT(INOUT) :: self
    CHARACTER(*), INTENT(IN) :: path
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg

    INTEGER :: unit, ios, line_id, object_index, nnode, node, ndof, es
    LOGICAL :: refined
    REAL(wp) :: s, xyz(3), xyz_prev(3), tension, curvature, bend_moment, declination, azimuth
    CHARACTER(CD_DECK_NAMELEN) :: ch
    CHARACTER(1024) :: em
    CHARACTER(1) :: tab

    ErrStat = CD_AGG_OK
    ErrMsg = ''
    IF (.NOT. require_initialized(self, ErrStat, ErrMsg)) RETURN
    IF (.NOT. ALLOCATED(self%line_obj_index) .OR. .NOT. ALLOCATED(self%line_is_cable)) THEN
      ErrStat = CD_AGG_BADINPUT
      ErrMsg = 'CableDyn_OpenFAST_Aggregate: line map unavailable for the static profile'
      RETURN
    END IF
    CALL CD_Open_Write(unit, TRIM(path), ios)
    IF (ios /= 0) THEN
      ErrStat = CD_AGG_BADINPUT
      ErrMsg = 'CableDyn_OpenFAST_Aggregate: cannot open static profile: '//TRIM(path)
      RETURN
    END IF

    tab = CHAR(9)
    ! A cable whose mesh the static solve refined lists every node of its final mesh; the DeckNode
    ! column then names the deck node of each row (0: a node the refinement added).
    refined = .FALSE.
    IF (ALLOCATED(self%cables)) THEN
      DO object_index = 1, SIZE(self%cables)
        refined = refined .OR. ALLOCATED(self%cables(object_index)%deck_node)
      END DO
    END IF
    WRITE (unit, '(A)') 'CableDyn coupled static configuration (deformed arc; public node order End A -> End B)'
    WRITE (unit, '(A)') 'LineID'//tab//'Node'//tab//'ArcLength'//tab//'X'//tab//'Y'//tab//'Z'//tab// &
      'Tension'//tab//'Curvature'//tab//'BendMoment'//tab//'Declination'//tab//'Inclination'//tab//'Azimuth'// &
      TRIM(MERGE(tab//'DeckNode', REPEAT(' ', 9), refined))
    WRITE (unit, '(A)') '(-)'//tab//'(-)'//tab//'(m)'//tab//'(m)'//tab//'(m)'//tab//'(m)'//tab// &
      '(N)'//tab//'(1/m)'//tab//'(N.m)'//tab//'(deg)'//tab//'(deg)'//tab//'(deg)'// &
      TRIM(MERGE(tab//'(-)', REPEAT(' ', 4), refined))

    DO line_id = 1, SIZE(self%line_obj_index)
      object_index = self%line_obj_index(line_id)
      IF (object_index < 1) CYCLE
      IF (self%line_is_cable(line_id)) THEN
        IF (object_index > self%ncable) THEN
          CALL profile_fail('cable line map index out of range')
          RETURN
        END IF
        nnode = CD_HFMF_NNodes(self%cables(object_index))
      ELSE
        IF (.NOT. self%has_sys) THEN
          CALL profile_fail('system line map exists without a system')
          RETURN
        END IF
        ndof = CD_System_Line_NDOF(self%sys%fast%system, object_index, es, em)
        IF (es /= CD_SYSTEM_OK .OR. MOD(ndof, 3) /= 0) THEN
          CALL profile_fail('system line size query failed: '//TRIM(em))
          RETURN
        END IF
        nnode = ndof/3
      END IF
      IF (nnode < 2) THEN
        CALL profile_fail('line has fewer than two output nodes')
        RETURN
      END IF

      s = CD_ZERO
      xyz_prev = CD_ZERO
      DO node = 1, nnode
        CALL eval_node('px', xyz(1)); IF (ErrStat /= CD_AGG_OK) RETURN
        CALL eval_node('py', xyz(2)); IF (ErrStat /= CD_AGG_OK) RETURN
        CALL eval_node('pz', xyz(3)); IF (ErrStat /= CD_AGG_OK) RETURN
        CALL eval_node('Ten', tension); IF (ErrStat /= CD_AGG_OK) RETURN
        CALL eval_node('Curv', curvature); IF (ErrStat /= CD_AGG_OK) RETURN
        CALL eval_node('BendMom', bend_moment); IF (ErrStat /= CD_AGG_OK) RETURN
        CALL eval_node('Dec', declination); IF (ErrStat /= CD_AGG_OK) RETURN
        CALL eval_node('Azi', azimuth); IF (ErrStat /= CD_AGG_OK) RETURN
        IF (node > 1) s = s + NORM2(xyz - xyz_prev)
        IF (refined) THEN
          WRITE (unit, '(I0,A,I0,10(A,ES15.7E3),A,I0)') line_id, tab, node, tab, s, tab, xyz(1), tab, xyz(2), &
            tab, xyz(3), tab, tension, tab, curvature, tab, bend_moment, tab, declination, &
            tab, declination - 90.0_wp, tab, azimuth, tab, profile_deck_node()
        ELSE
          WRITE (unit, '(I0,A,I0,10(A,ES15.7E3))') line_id, tab, node, tab, s, tab, xyz(1), tab, xyz(2), &
            tab, xyz(3), tab, tension, tab, curvature, tab, bend_moment, tab, declination, &
            tab, declination - 90.0_wp, tab, azimuth
        END IF
        xyz_prev = xyz
      END DO
    END DO
    CLOSE (unit)

  CONTAINS

    SUBROUTINE eval_node(kind, value)
      CHARACTER(*), INTENT(IN) :: kind
      REAL(wp), INTENT(OUT) :: value
      IF (kind == 'px' .OR. kind == 'py' .OR. kind == 'pz' .OR. kind == 'Dec' .OR. kind == 'Azi') THEN
        WRITE (ch, '(A,I0,A,I0,A)') 'L', line_id, 'N', node, kind
      ELSE
        WRITE (ch, '(A,I0,A,I0)') TRIM(kind), line_id, 'N', node
      END IF
      ! every node of the line's final mesh, also on a refined cable
      CALL CD_Eval_Aggregate_Channel(TRIM(ch), self%has_sys, self%sys%fast%system, self%cables, &
                                     self%line_is_cable, self%line_obj_index, value, es, em, mesh_node=.TRUE.)
      IF (es /= CD_DECKDRV_OK) CALL profile_fail('channel '//TRIM(ch)//' failed: '//TRIM(em))
    END SUBROUTINE eval_node

    INTEGER FUNCTION profile_deck_node() RESULT(deck_node)
      !! The deck node of the current row (an EI = 0 line is meshed as the deck).
      deck_node = node
      IF (self%line_is_cable(line_id)) deck_node = CD_Cable_Deck_Node(self%cables(object_index), node)
    END FUNCTION profile_deck_node

    SUBROUTINE profile_fail(message)
      CHARACTER(*), INTENT(IN) :: message
      ErrStat = CD_AGG_BADINPUT
      ErrMsg = 'CableDyn_OpenFAST_Aggregate: static profile: '//TRIM(message)
      CLOSE (unit, STATUS='DELETE')
    END SUBROUTINE profile_fail

  END SUBROUTINE CD_AGG_WriteStaticProfile

  LOGICAL FUNCTION require_initialized(self, ErrStat, ErrMsg) RESULT(ok)
    TYPE(CD_AGG_ModuleType), INTENT(IN) :: self
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg

    ok = self%initialized
    IF (ok) THEN
      ErrStat = CD_AGG_OK
      ErrMsg = ''
    ELSE
      ErrStat = CD_AGG_NOT_INITIALIZED
      ErrMsg = 'CableDyn_OpenFAST_Aggregate: module is not initialized'
    END IF
  END FUNCTION require_initialized

  LOGICAL FUNCTION moving_cols_ok(a, self) RESULT(ok)
    !! A moving-surface array must be shaped (3, ncp_total).
    REAL(wp), INTENT(IN) :: a(:, :)
    TYPE(CD_AGG_ModuleType), INTENT(IN) :: self

    ok = (SIZE(a, 1) == 3 .AND. SIZE(a, 2) == ncp_all(self))
  END FUNCTION moving_cols_ok

  SUBROUTINE host_fairlead_motion(self, position, velocity, acceleration)
    !! Scatter the system's moving columns (the host fairleads at t + dt) into the flat coupled-DOF
    !! overlay the body/rod marches pass to the line step.
    TYPE(CD_AGG_ModuleType), INTENT(INOUT) :: self
    REAL(wp), INTENT(IN) :: position(:, :), velocity(:, :), acceleration(:, :)
    INTEGER :: i, b
    IF (.NOT. ALLOCATED(self%hf_mask)) RETURN
    DO i = 1, self%ncp_sys
      b = self%sys%moving_blocks(i)
      self%hf_q(3*b - 2:3*b) = position(:, i)
      self%hf_v(3*b - 2:3*b) = velocity(:, i)
      self%hf_a(3*b - 2:3*b) = acceleration(:, i)
    END DO
  END SUBROUTINE host_fairlead_motion

  PURE INTEGER FUNCTION ncp_all(self) RESULT(n)
    !! Total moving columns: system moving points, cable fairleads, the moving End B of a cable
    !! between two moving points, host rod nodes, host body nodes.
    TYPE(CD_AGG_ModuleType), INTENT(IN) :: self
    n = self%ncp_sys + self%ncable + self%ncable_b + self%nhost_rod + self%nhost_body
  END FUNCTION ncp_all

  SUBROUTINE cable_two_ends(cable, ca, cb, mode, position, velocity, acceleration, es, em, orientation, &
                            angular_velocity, angular_acceleration, twist)
    !! The HFMF boundary call of a cable with a moving End B (CD_HFMF_Set_Moving_End_B): End A takes
    !! the moving column ca, End B column cb, each with its orientation and rates (the
    !! committed parent orientation and zero rates where the host passes none). mode CABLE_PREFLIGHT
    !! validates, CABLE_SET transfers without a step (direct feedthrough), CABLE_STEP advances,
    !! with twist the imposed twist of a cable restrained in torsion (the deck's roll columns).
    !! Touches only that cable (safe inside the cables' parallel loop).
    TYPE(CD_HFMF_ModuleType), INTENT(INOUT) :: cable
    INTEGER, INTENT(IN) :: ca, cb, mode
    REAL(wp), INTENT(IN) :: position(:, :), velocity(:, :), acceleration(:, :)
    INTEGER, INTENT(OUT) :: es
    CHARACTER(*), INTENT(OUT) :: em
    REAL(wp), INTENT(IN), OPTIONAL :: orientation(:, :, :)
    REAL(wp), INTENT(IN), OPTIONAL :: angular_velocity(:, :), angular_acceleration(:, :)
    REAL(wp), INTENT(IN), OPTIONAL :: twist
    REAL(wp) :: dcm_a(3, 3), dcm_b(3, 3), w_a(3), al_a(3), w_b(3), al_b(3)
    dcm_a = cable%parent_dcm
    dcm_b = cable%parent_dcm_b
    IF (PRESENT(orientation)) THEN
      dcm_a = orientation(:, :, ca)
      dcm_b = orientation(:, :, cb)
    END IF
    w_a = CD_ZERO
    al_a = CD_ZERO
    w_b = CD_ZERO
    al_b = CD_ZERO
    IF (PRESENT(angular_velocity) .AND. PRESENT(angular_acceleration)) THEN
      w_a = angular_velocity(:, ca)
      al_a = angular_acceleration(:, ca)
      w_b = angular_velocity(:, cb)
      al_b = angular_acceleration(:, cb)
    END IF
    SELECT CASE (mode)
    CASE (CABLE_PREFLIGHT)
      CALL CD_HFMF_PreflightCoupledKinematics(cable, position(:, ca), velocity(:, ca), acceleration(:, ca), &
                                              es, em, dcm_a, w_a, al_a, position(:, cb), velocity(:, cb), &
                                              acceleration(:, cb), dcm_b, w_b, al_b)
    CASE (CABLE_SET)
      CALL CD_HFMF_SetCoupledKinematics(cable, position(:, ca), velocity(:, ca), acceleration(:, ca), &
                                        es, em, dcm_a, w_a, al_a, position(:, cb), velocity(:, cb), &
                                        acceleration(:, cb), dcm_b, w_b, al_b)
    CASE DEFAULT
      CALL CD_HFMF_UpdateStates(cable, position(:, ca), velocity(:, ca), acceleration(:, ca), es, em, &
                                dcm_a, w_a, al_a, ub_pos=position(:, cb), ub_vel=velocity(:, cb), &
                                ub_acc=acceleration(:, cb), ub_orientation=dcm_b, ub_angular_velocity=w_b, &
                                ub_angular_acceleration=al_b, u_twist=twist)
    END SELECT
  END SUBROUTINE cable_two_ends

  INTEGER FUNCTION fmf_nblocks(sys) RESULT(n)
    !! Coupled 3-DOF blocks of the EI=0 system (the full point-mesh width).
    TYPE(CD_FMF_ModuleType), INTENT(IN) :: sys
    n = sys%fast%system%n_system_coupled_dof/3
  END FUNCTION fmf_nblocks

  SUBROUTINE overlay_host_objects(self, output_probe, ErrStat, ErrMsg)
    !! Transfer the Rod<N>A/B kinematics of the host-driven rods (already set on the rod
    !! runtime) into the EI=0 system WITHOUT advancing: the full coupled-block mesh with the
    !! rod blocks overwritten goes through CD_FMF_UpdateStates (the same transfer the moving
    !! columns use), so a CalcOutput after a platform move reflects the moved rod ends.
    TYPE(CD_AGG_ModuleType), INTENT(INOUT) :: self
    LOGICAL, INTENT(IN) :: output_probe
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    INTEGER :: es
    CHARACTER(1024) :: em
    ErrStat = CD_AGG_OK
    ErrMsg = ''
    IF (self%nhost_rod + self%nhost_body == 0 .OR. .NOT. self%has_sys) RETURN
    CALL CD_FMF_GetPointMesh(self%sys, self%hb_pos, self%hb_vel, self%hb_acc, self%hb_load, es, em)
    IF (es /= CD_FMF_OK) THEN
      CALL map_fmf_status(es, em, ErrStat, ErrMsg)
      RETURN
    END IF
    IF (self%nhost_rod > 0) &
      CALL CD_Rod_ScatterHostPoints(self%sys%fast%system, self%rod, self%hb_pos, self%hb_vel, self%hb_acc)
    IF (self%nhost_body > 0) &
      CALL CD_Rigid6_ScatterHostPoints(self%sys%fast%system, self%rigid6, self%hb_pos, self%hb_vel, self%hb_acc)
    CALL CD_FMF_UpdateStates(self%sys, self%hb_pos, self%hb_vel, self%hb_acc, es, em, output_probe=output_probe)
    IF (es /= CD_FMF_OK) CALL map_fmf_status(es, em, ErrStat, ErrMsg)
  END SUBROUTINE overlay_host_objects

  SUBROUTINE start_object_accelerations(self, ErrStat, ErrMsg)
    !! Solve the start accelerations of the integrated bodies and rods at the current state
    !! (CD_Rigid6_StartAccelerations, CD_Rod_StartAccelerations), in the held fluid fields: at
    !! Init and, before the first step, at a committed transfer of the step-start kinematics and
    !! at new host fluid fields (CD_AGG_SetFluidFields). The OpenFAST shell restores
    !! the state mirror after every CalcOutput, which marks the object accelerations committed;
    !! solved here, the mirror carries the start accelerations, and the first step starts from them
    !! instead of from zero.
    TYPE(CD_AGG_ModuleType), INTENT(INOUT) :: self
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    INTEGER :: es
    LOGICAL :: pin_b, pin_r
    CHARACTER(1024) :: em
    ErrStat = CD_AGG_OK
    ErrMsg = ''
    pin_b = .FALSE.
    pin_r = .FALSE.
    IF (.NOT. self%has_sys) RETURN
    IF (self%has_rigid6) THEN
      CALL CD_Rigid6_StartAccelerations(self%sys%fast%system, self%rigid6, es, em, pinned=pin_b)
      IF (es /= CD_DECKDRV_OK) THEN
        CALL map_deck_status(es, em, ErrStat, ErrMsg)
        RETURN
      END IF
    END IF
    IF (self%has_rod) THEN
      CALL CD_Rod_StartAccelerations(self%sys%fast%system, self%rod, es, em, pinned=pin_r)
      IF (es /= CD_DECKDRV_OK) THEN
        CALL map_deck_status(es, em, ErrStat, ErrMsg)
        RETURN
      END IF
    END IF
    ! the line ends on a CoupledPinned rod or body move with its solved acceleration (a mirror
    ! restore puts them there too, CD_AGG_Set_Rigid6_States, CD_AGG_Set_Rod_States), and the line
    ! interior accelerations follow them (a committed transfer); Coupled/Vessel objects keep the
    ! host's (Init) motion
    IF (.NOT. (pin_b .OR. pin_r)) RETURN
    CALL overlay_host_objects(self, .FALSE., ErrStat, ErrMsg)
    IF (ErrStat == CD_AGG_OK) CALL CD_FMF_Refresh_PointMesh(self%sys, ErrStat, ErrMsg)
  END SUBROUTINE start_object_accelerations

  SUBROUTINE set_host_objects(self, position, velocity, acceleration, ErrStat, ErrMsg, orientation, &
                              angular_velocity, angular_acceleration, step_start)
    !! Impose the host-rod and host-body columns (the trailing nhost_rod + nhost_body moving
    !! columns) on the rod and Rigid6 runtimes.
    !! step_start: a transfer that does not advance (CD_AGG_UpdateStates_Moving), whose host
    !! kinematics the next step of a CoupledPinned rod or body starts from
    !! (CD_Rod_SetHostKinematics, CD_Rigid6_SetHostKinematics).
    TYPE(CD_AGG_ModuleType), INTENT(INOUT) :: self
    REAL(wp), INTENT(IN) :: position(:, :), velocity(:, :), acceleration(:, :)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    REAL(wp), INTENT(IN), OPTIONAL :: orientation(:, :, :)
    REAL(wp), INTENT(IN), OPTIONAL :: angular_velocity(:, :), angular_acceleration(:, :)
    LOGICAL, INTENT(IN), OPTIONAL :: step_start
    INTEGER :: c0, c1, es
    LOGICAL :: at_start
    CHARACTER(1024) :: em
    ErrStat = CD_AGG_OK
    ErrMsg = ''
    at_start = .FALSE.
    IF (PRESENT(step_start)) at_start = step_start
    IF (self%nhost_body > 0) THEN
      c0 = self%ncp_sys + self%ncable + self%ncable_b + self%nhost_rod + 1
      c1 = ncp_all(self)
      IF (PRESENT(orientation)) THEN
        CALL CD_Rigid6_SetHostKinematics(self%rigid6, position(:, c0:c1), velocity(:, c0:c1), &
                                         acceleration(:, c0:c1), es, em, orientation(:, :, c0:c1), &
                                         angular_velocity(:, c0:c1), angular_acceleration(:, c0:c1), &
                                         step_start=at_start)
      ELSE
        CALL CD_Rigid6_SetHostKinematics(self%rigid6, position(:, c0:c1), velocity(:, c0:c1), &
                                         acceleration(:, c0:c1), es, em, &
                                         angular_velocity=angular_velocity(:, c0:c1), &
                                         angular_acceleration=angular_acceleration(:, c0:c1), step_start=at_start)
      END IF
      IF (es /= CD_DECKDRV_OK) THEN
        CALL map_deck_status(es, em, ErrStat, ErrMsg)
        RETURN
      END IF
    END IF
    IF (self%nhost_rod == 0) RETURN
    c0 = self%ncp_sys + self%ncable + self%ncable_b + 1
    c1 = self%ncp_sys + self%ncable + self%ncable_b + self%nhost_rod
    IF (PRESENT(orientation)) THEN
      IF (PRESENT(angular_velocity)) THEN
        CALL CD_Rod_SetHostKinematics(self%rod, position(:, c0:c1), velocity(:, c0:c1), acceleration(:, c0:c1), &
                                      es, em, orientation(:, :, c0:c1), angular_velocity(:, c0:c1), &
                                      angular_acceleration(:, c0:c1), step_start=at_start)
      ELSE
        CALL CD_Rod_SetHostKinematics(self%rod, position(:, c0:c1), velocity(:, c0:c1), acceleration(:, c0:c1), &
                                      es, em, orientation(:, :, c0:c1), step_start=at_start)
      END IF
    ELSE
      IF (PRESENT(angular_velocity)) THEN
        CALL CD_Rod_SetHostKinematics(self%rod, position(:, c0:c1), velocity(:, c0:c1), acceleration(:, c0:c1), &
                                      es, em, angular_velocity=angular_velocity(:, c0:c1), &
                                      angular_acceleration=angular_acceleration(:, c0:c1), step_start=at_start)
      ELSE
        CALL CD_Rod_SetHostKinematics(self%rod, position(:, c0:c1), velocity(:, c0:c1), acceleration(:, c0:c1), &
                                      es, em, step_start=at_start)
      END IF
    END IF
    IF (es /= CD_DECKDRV_OK) CALL map_deck_status(es, em, ErrStat, ErrMsg)
  END SUBROUTINE set_host_objects

  LOGICAL FUNCTION moving_kinematics_finite(position, velocity, acceleration) RESULT(ok)
    REAL(wp), INTENT(IN) :: position(:, :), velocity(:, :), acceleration(:, :)
    ok = CD_All_Finite(position) .AND. CD_All_Finite(velocity) .AND. &
         CD_All_Finite(acceleration)
  END FUNCTION moving_kinematics_finite

  LOGICAL FUNCTION orientations_ok(orientation) RESULT(ok)
    REAL(wp), INTENT(IN) :: orientation(:, :, :)
    REAL(wp) :: gram(3, 3), ident(3, 3), det
    INTEGER :: i
    ok = .FALSE.
    IF (SIZE(orientation, 1) /= 3 .OR. SIZE(orientation, 2) /= 3) RETURN
    IF (.NOT. CD_All_Finite(orientation)) RETURN
    ident = CD_ZERO
    ident(1, 1) = CD_ONE; ident(2, 2) = CD_ONE; ident(3, 3) = CD_ONE
    DO i = 1, SIZE(orientation, 3)
      gram = MATMUL(orientation(:, :, i), TRANSPOSE(orientation(:, :, i)))
      det = orientation(1, 1, i)*(orientation(2, 2, i)*orientation(3, 3, i) - &
                                  orientation(2, 3, i)*orientation(3, 2, i)) - &
            orientation(1, 2, i)*(orientation(2, 1, i)*orientation(3, 3, i) - &
                                  orientation(2, 3, i)*orientation(3, 1, i)) + &
            orientation(1, 3, i)*(orientation(2, 1, i)*orientation(3, 2, i) - &
                                  orientation(2, 2, i)*orientation(3, 1, i))
      IF (MAXVAL(ABS(gram - ident)) > 1.0e-8_wp .OR. ABS(det - CD_ONE) > 1.0e-8_wp) RETURN
    END DO
    ok = .TRUE.
  END FUNCTION orientations_ok

  SUBROUTINE map_fmf_status(fmf_es, fmf_em, ErrStat, ErrMsg)
    INTEGER, INTENT(IN) :: fmf_es
    CHARACTER(*), INTENT(IN) :: fmf_em
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg

    SELECT CASE (fmf_es)
    CASE (CD_FMF_OK)
      ErrStat = CD_AGG_OK
    CASE (CD_FMF_BADINPUT)
      ErrStat = CD_AGG_BADINPUT
    CASE (CD_FMF_NOT_INITIALIZED)
      ErrStat = CD_AGG_NOT_INITIALIZED
    CASE (CD_FMF_ALLOCFAIL)
      ErrStat = CD_AGG_ALLOCFAIL
    CASE DEFAULT
      ErrStat = CD_AGG_SOLVEFAIL
    END SELECT
    IF (ErrStat == CD_AGG_OK) THEN
      ErrMsg = ''
    ELSE
      ErrMsg = 'CableDyn_OpenFAST_Aggregate: '//TRIM(fmf_em)
    END IF
  END SUBROUTINE map_fmf_status

  SUBROUTINE map_hfmf_status(hf_es, hf_em, ErrStat, ErrMsg)
    INTEGER, INTENT(IN) :: hf_es
    CHARACTER(*), INTENT(IN) :: hf_em
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg

    SELECT CASE (hf_es)
    CASE (CD_HFMF_OK)
      ErrStat = CD_AGG_OK
    CASE (CD_HFMF_BADINPUT)
      ErrStat = CD_AGG_BADINPUT
    CASE DEFAULT
      ErrStat = CD_AGG_SOLVEFAIL
    END SELECT
    IF (ErrStat == CD_AGG_OK) THEN
      ErrMsg = ''
    ELSE
      ErrMsg = 'CableDyn_OpenFAST_Aggregate: '//TRIM(hf_em)
    END IF
  END SUBROUTINE map_hfmf_status

  SUBROUTINE map_deck_status(dk_es, dk_em, ErrStat, ErrMsg)
    INTEGER, INTENT(IN) :: dk_es
    CHARACTER(*), INTENT(IN) :: dk_em
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg

    SELECT CASE (dk_es)
    CASE (CD_DECKDRV_OK)
      ErrStat = CD_AGG_OK
    CASE (CD_DECKDRV_BADINPUT)
      ErrStat = CD_AGG_BADINPUT
    CASE DEFAULT
      ErrStat = CD_AGG_SOLVEFAIL
    END SELECT
    IF (ErrStat == CD_AGG_OK) THEN
      ErrMsg = ''
    ELSE
      ErrMsg = 'CableDyn_OpenFAST_Aggregate: '//TRIM(dk_em)
    END IF
  END SUBROUTINE map_deck_status

  SUBROUTINE CD_AGG_Refresh_PointMesh(self, ErrStat, ErrMsg)
    !! Re-derive the EI=0 system facade's point mesh from the current system state
    !! (see CD_FMF_Refresh_PointMesh). No-op without a system.
    TYPE(CD_AGG_ModuleType), INTENT(INOUT) :: self
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    ErrStat = CD_AGG_OK
    ErrMsg = ''
    IF (.NOT. self%has_sys) RETURN
    CALL CD_FMF_Refresh_PointMesh(self%sys, ErrStat, ErrMsg)
  END SUBROUTINE CD_AGG_Refresh_PointMesh

  INTEGER FUNCTION CD_AGG_NDynamicPoints(self) RESULT(n)
    !! Number of DYNAMIC (Free/Connect) points in the aggregate's EI=0 system --
    !! states the system integrates itself. 0 with no system or an uninitialized one.
    TYPE(CD_AGG_ModuleType), INTENT(IN) :: self
    n = 0
    IF (.NOT. self%has_sys) RETURN
    n = CD_FMF_NDynamicPoints(self%sys)
  END FUNCTION CD_AGG_NDynamicPoints

  LOGICAL FUNCTION CD_AGG_HasRigid6(self) RESULT(has)
    !! True iff the aggregate marches coupled Rigid6 bodies. 0 bodies (unpopulated runtime)
    !! reports .FALSE. The checkpoint-restart mirror pairs this with CD_AGG_Rigid6_MirrorSize +
    !! CD_AGG_Get/Set_Rigid6_States to carry the 6-DOF body state across a restart.
    TYPE(CD_AGG_ModuleType), INTENT(IN) :: self
    has = self%has_rigid6 .AND. CD_Rigid6_NBodies(self%rigid6) > 0
  END FUNCTION CD_AGG_HasRigid6

  LOGICAL FUNCTION CD_AGG_HasRod(self) RESULT(has)
    !! True iff the aggregate marches coupled rigid rods. 0 rods (unpopulated runtime) reports
    !! .FALSE. Marks the dynamic rod state carried by the OpenFAST x%states mirror.
    TYPE(CD_AGG_ModuleType), INTENT(IN) :: self
    has = self%has_rod .AND. CD_Rod_NRods(self%rod) > 0
  END FUNCTION CD_AGG_HasRod

  LOGICAL FUNCTION CD_AGG_HasPoint3(self) RESULT(has)
    !! True iff the deck has a Point3 buoy, which the EI=0 system steps as a Free point but
    !! the static solve does not place: it starts, and a static re-solve holds it, at its deck
    !! position.
    TYPE(CD_AGG_ModuleType), INTENT(IN) :: self
    has = self%has_point3
  END FUNCTION CD_AGG_HasPoint3

  INTEGER FUNCTION CD_AGG_Rigid6_MirrorSize(self) RESULT(n)
    !! Reals the checkpoint mirror must reserve for the aggregate's Rigid6 bodies (0 if none).
    TYPE(CD_AGG_ModuleType), INTENT(IN) :: self
    n = 0
    IF (self%has_rigid6) n = CD_Rigid6_MirrorSize(self%rigid6)
  END FUNCTION CD_AGG_Rigid6_MirrorSize

  SUBROUTINE CD_AGG_Get_Rigid6_States(self, states, ErrStat, ErrMsg)
    !! Pack the committed 6-DOF Rigid6 body state into the mirror slice (CD_AGG_Rigid6_MirrorSize).
    TYPE(CD_AGG_ModuleType), INTENT(IN) :: self
    REAL(wp), INTENT(OUT) :: states(:)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    ErrStat = CD_AGG_OK
    ErrMsg = ''
    IF (self%has_rigid6) CALL CD_Rigid6_Get_States(self%rigid6, states, ErrStat, ErrMsg)
  END SUBROUTINE CD_AGG_Get_Rigid6_States

  SUBROUTINE CD_AGG_Set_Rigid6_States(self, states, ErrStat, ErrMsg)
    !! Restore the 6-DOF Rigid6 body state from the mirror slice (fails closed on size/finite).
    TYPE(CD_AGG_ModuleType), INTENT(INOUT) :: self
    REAL(wp), INTENT(IN) :: states(:)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    ErrStat = CD_AGG_OK
    ErrMsg = ''
    IF (.NOT. self%has_rigid6) RETURN
    CALL CD_Rigid6_Set_States(self%rigid6, states, ErrStat, ErrMsg)
    IF (ErrStat /= CD_AGG_OK) RETURN
    self%objects_committed = .TRUE.
    IF (self%nhost_body == 0) RETURN
    ! Host-driven bodies: their Body<N> line ends follow the restored body state exactly.
    CALL overlay_host_objects(self, .TRUE., ErrStat, ErrMsg)
    IF (ErrStat == CD_AGG_OK) CALL CD_FMF_Refresh_PointMesh(self%sys, ErrStat, ErrMsg)
  END SUBROUTINE CD_AGG_Set_Rigid6_States

  INTEGER FUNCTION CD_AGG_Rod_MirrorSize(self) RESULT(n)
    TYPE(CD_AGG_ModuleType), INTENT(IN) :: self
    n = 0
    IF (self%has_rod) n = CD_Rod_MirrorSize(self%rod)
  END FUNCTION CD_AGG_Rod_MirrorSize

  SUBROUTINE CD_AGG_Get_Rod_States(self, states, ErrStat, ErrMsg)
    TYPE(CD_AGG_ModuleType), INTENT(IN) :: self
    REAL(wp), INTENT(OUT) :: states(:)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    ErrStat = CD_AGG_OK
    ErrMsg = ''
    IF (self%has_rod) CALL CD_Rod_Get_States(self%rod, states, ErrStat, ErrMsg)
  END SUBROUTINE CD_AGG_Get_Rod_States

  SUBROUTINE CD_AGG_Reopen_Start(self)
    !! Back to the start of the first step after a restored state mirror, which marks the object
    !! accelerations committed: a state from before the first commit keeps its start open, as the
    !! run it continues does, so the fluid fields of the first step re-solve them
    !! (objects_committed). Until then they stay those of the mirror.
    TYPE(CD_AGG_ModuleType), INTENT(INOUT) :: self
    self%objects_committed = .FALSE.
  END SUBROUTINE CD_AGG_Reopen_Start

  SUBROUTINE CD_AGG_Set_Rod_States(self, states, ErrStat, ErrMsg)
    !! Restore the rod state and immediately scatter its end-point kinematics
    !! into the EI=0 system used by restart-time output and the next advance.
    TYPE(CD_AGG_ModuleType), INTENT(INOUT) :: self
    REAL(wp), INTENT(IN) :: states(:)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    ErrStat = CD_AGG_OK
    ErrMsg = ''
    IF (.NOT. self%has_rod) RETURN
    CALL CD_Rod_Set_States(self%rod, states, ErrStat, ErrMsg)
    IF (ErrStat /= CD_AGG_OK) RETURN
    self%objects_committed = .TRUE.
    CALL CD_Rod_Apply_States(self%sys%fast%system, self%rod, ErrStat, ErrMsg)
    IF (ErrStat /= CD_AGG_OK) RETURN
    ! Host-driven rods: their Rod<N>A/B line ends follow the restored rod state exactly (an
    ! endpoint-only transfer), so a CalcOutput probe restore or a restart leaves no rounding of
    ! the host-kinematics round trip in the line ends.
    CALL overlay_host_objects(self, .TRUE., ErrStat, ErrMsg)
    IF (ErrStat == CD_AGG_OK) CALL CD_FMF_Refresh_PointMesh(self%sys, ErrStat, ErrMsg)
  END SUBROUTINE CD_AGG_Set_Rod_States

END MODULE CableDyn_OpenFAST_Aggregate
