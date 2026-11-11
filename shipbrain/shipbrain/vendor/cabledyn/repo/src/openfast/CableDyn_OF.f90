!**********************************************************************************************************************************
! SPDX-License-Identifier: Apache-2.0
! LICENSING
! Copyright (C) 2026 Jae Hoon Seo, SMI Lab, Inha University
!
! Licensed under the Apache License, Version 2.0 (the "License");
! you may not use this file except in compliance with the License.
! You may obtain a copy of the License at
!
!     http://www.apache.org/licenses/LICENSE-2.0
!
! Unless required by applicable law or agreed to in writing, software
! distributed under the License is distributed on an "AS IS" BASIS,
! WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
! See the License for the specific language governing permissions and
! limitations under the License.
!**********************************************************************************************************************************
MODULE CableDyn
   !! CableDyn: a first-class mooring and cable-dynamics module for OpenFAST
   !! (CompMooring = 5). CableDyn is an independent module, not a MoorDyn variant: the
   !! input file is CableDyn's, the line object follows the OrcaFlex model strictly
   !! (a LINE runs End A -> End B through ordered SECTIONS, each with its own line
   !! type, length, and mesh), the initial condition is a true Newton static
   !! equilibrium (no dynamic relaxation, no relaxation tuning), and time stepping
   !! is implicit generalised-alpha on the banded production core (one implicit
   !! step per coupling step; the module never changes the glue's DT). The deck's
   !! OPTIONS section carries CableDyn's own static- and dynamic-solver settings.
   !! Output channels follow the OrcaFlex vocabulary: the deck OUTPUTS list flows to the
   !! OpenFAST WriteOutput surface (per-line and per-node tensions, curvature, bend moment,
   !! the fairlead/anchor angle, node positions/velocities/accelerations) for both the EI=0
   !! mooring lines and the finite-EI cables.
   !!
   !! Exports the FAST-modularization-framework surface the glue couples against
   !! (CD_Init / CD_UpdateStates / CD_CalcOutput / CD_CalcContStateDeriv / CD_End + the
   !! four Jacobian routines) over the registry-generated CableDyn_Types.
   !!
   !! Coexists with stock MoorDyn in one binary: CompMooring = 3 selects MoorDyn,
   !! CompMooring = 5 selects this module (an A/B comparison is a one-digit switch).
   !! For migration, decks written in the MoorDyn v2 format also parse: each stock
   !! construct is routed into the corresponding CableDyn feature (bodies and rods,
   !! viscoelastic and Syrope ropes, line failures, active tension through the CONTROL
   !! section, SeaState water kinematics), or, where CableDyn has no counterpart (for
   !! example a rotational body drag area), fails closed with a named error. A CoupledPinned
   !! rod or body is a coupling-mesh node like a Coupled rod or body but takes only the
   !! translation of its node and returns force with zero moment: it turns about the node on
   !! its own.
   !!
   !! Supported coupled surface (each verified against stock MoorDyn or a named gate):
   !! Fixed/Coupled(Vessel) points, EI=0 mooring lines (BA damping + the Morison set),
   !! finite-EI power cables, penalty seabed, nonzero initial platform displacement
   !! (PtfmInit), the module's own mooring step (supercycling + zero-order-hold loads),
   !! glue step retries (snapshot-rewind re-advance at any dtM/DT), SeaState
   !! wave/current kinematics sampled at the line nodes (single-turbine only; see the
   !! farm scope at the use_extf guard), range graphs of the LINES flag r (single-turbine
   !! only: <root>.Line<L>.range.out, sampled at every committed mooring step, written at the
   !! end of a run the host reports complete), checkpoint restart (rebuild from the packed
   !! deck + state mirror, accepted on committed mooring-interval boundaries),
   !! linearization with the line dynamics (as MoorDyn-F: the continuous states are the
   !! EI=0 lines' interior-node positions and the finite-EI cables' free DOFs, positions
   !! and tangents, and the free twist angles of a cable restrained in torsion, then their
   !! velocities, and the rope models' constitutive states; A, B, C and D by central
   !! differences of lin_eval, the accelerations and state rates evaluated at the perturbed
   !! state; the coupled-point orientation turns a torsion end frame and the fairlead moment
   !! carries the torque; Free/Connect points, VIV lines, bodies, rods, Point3 buoys, CONTROL
   !! and rigid cable ends fail closed), and
   !! FAST.Farm farm-level moorings (FarmSize > 0: Turbine<J> decks,
   !! per-turbine coupled meshes, shared lines; still-water hydro; farm restart and
   !! farm linearization fail closed with named messages). Checkpoint restart re-parses a
   !! temporary copy of the deck, written next to the
   !! MooringFile (so its side files resolve as in the original run) and removed after
   !! use.
   !!
   !! State handling: the authoritative states live in the module-level instance
   !! (keyed by m%CDInst); x%states carries the mirror (per EI=0 mooring line the
   !! MoorDyn-layout interior-node velocities then positions, then per finite-EI cable
   !! its free-DOF velocities then positions) so checkpoint packing, correction-
   !! iteration rewind, and the ModVars x-variable metadata are framework-conformant.

   USE CableDyn_Types
   USE NWTC_Library
   USE CableDyn_Precision, ONLY: wp
   USE CableDyn_PathIO, ONLY: CD_Path_Openable
   USE CableDyn_Conventions, ONLY: CD_NATIVE_CHANNEL_FMT
   USE CableDyn_Hydro, ONLY: CD_Current_Profile_Velocity, CD_SeaState_Steady_Current, CD_HYDRO_OK
   USE CableDyn_DeckDriver, ONLY: CD_Deck_Query_dtM, CD_DECKDRV_OK, CD_Is_Line_Node_Channel, &
                                  CD_LINE_NODE_NUMBERING_NOTE, CD_INIT_NOTE_LEN
   USE CableDyn_OpenFAST_Aggregate, ONLY: CD_AGG_ModuleType, CD_AGG_Init_From_Deck, CD_AGG_UpdateStates_Moving, &
                                          CD_AGG_Step_Moving, CD_AGG_CalcOutput, CD_AGG_GetMovingPointMesh, &
                                          CD_AGG_Snapshot, CD_AGG_Restore, &
                                          CD_AGG_NMovingPoints, CD_AGG_NDynamicPoints, CD_AGG_Refresh_PointMesh, &
                                          CD_AGG_NFailures, CD_AGG_Get_Substep_Counts, &
                                          CD_AGG_HasRigid6, CD_AGG_HasRod, CD_AGG_HasPoint3, &
                                          CD_AGG_Rigid6_MirrorSize, CD_AGG_Get_Rigid6_States, &
                                          CD_AGG_Set_Rigid6_States, &
                                          CD_AGG_Rod_MirrorSize, CD_AGG_Get_Rod_States, CD_AGG_Set_Rod_States, &
                                          CD_AGG_NCtrlChans, CD_AGG_Apply_LineControl, &
                                          CD_AGG_Get_Failure_Flags, CD_AGG_Set_Failure_Flags, CD_AGG_End, &
                                          CD_AGG_IsInitialized, CD_AGG_OK, &
                                          CD_AGG_NTurbines, CD_AGG_TurbineOfMoving, &
                                          CD_AGG_NFluidNodes, CD_AGG_GetFluidNodePositions, CD_AGG_SetFluidFields, &
                                          CD_AGG_NumChannels, CD_AGG_ChannelHeader, CD_AGG_EvalChannel, &
                                          CD_AGG_GetInitMetadata, CD_AGG_GetInitLine, &
                                          CD_AGG_WriteStaticProfile, CD_AGG_Range_Graphs, CD_AGG_Range_Sample, &
                                          CD_AGG_Range_Write, CD_AGG_Range_MirrorSize, CD_AGG_Reopen_Start, &
                                          CD_AGG_Range_Get_State, CD_AGG_Range_Set_State
   USE CableDyn_OpenFAST_HermiteFMF, ONLY: CD_HFMF_MirrorSize, CD_HFMF_PackMirror, CD_HFMF_UnpackMirror, &
                                           CD_HFMF_FrictionMirrorSize, CD_HFMF_BoundaryMirrorSize, &
                                           CD_HFMF_ForceMirrorSize, CD_HFMF_TorsionMirrorSize, CD_HFMF_VIVMirrorSize, &
                                           CD_HFMF_Refresh_Acceleration, CD_HFMF_OK, &
                                           CD_HFMF_Twist_Lin_Count, CD_HFMF_Twist_Lin_Slots, &
                                           CD_HFMF_Set_Twist_Frame_Rates
   USE CableDyn_HermiteCableDynamic, ONLY: CD_HermiteCable_Dyn_Reset_Profile, &
                                            CD_HermiteCable_Dyn_Disable_Profile, &
                                            CD_HermiteCable_Dyn_Get_Profile, &
                                            CD_HermiteCable_Dyn_Get_Assembly_Profile, HC_ASM_NSEC, HC_ASM_KEYS, &
                                            CD_HermiteCable_Dyn_Recovery_Count, &
                                            CD_HermiteCable_Dyn_Recovery_Reset
   USE CableDyn_LoadPredictor, ONLY: CD_Predictor_Ready, CD_Predictor_Fraction, CD_Predict_Loads
   USE CableDyn_Profile, ONLY: CD_Profile_Arm, CD_Profile_Disarm, CD_Profile_Kernels, CD_PROF_K_RESIDUAL, &
                               CD_PROF_K_TANGENT, CD_PROF_K_FACTOR, CD_PROF_K_SOLVE, CD_PROF_NKERNEL
   USE CableDyn_System, ONLY: CD_Get_System_Line_Stretch, CD_Get_System_Line_Internal_Rates
   USE CableDyn_EndConnection, ONLY: CD_ENDCONN_RIGID
   USE CableDyn_System, ONLY: CD_System_NLines, CD_System_Line_NDOF, CD_System_Line_NElem, &
                              CD_Get_System_DynamicPoint_States, CD_Set_System_DynamicPoint_States, &
                              CD_System_NSystemCoupledDOF, CD_Get_System_CoupledMotion, &
                              CD_Update_System_CoupledMotion, &
                              CD_Get_System_Line_State, CD_Update_System_Line_Interior_State, &
                              CD_System_Line_Has_Viscoelastic, CD_Get_System_Line_VE_Dl1, &
                              CD_Set_System_Line_VE_Dl1, &
                              CD_System_Line_Has_Syrope, CD_Get_System_Line_Syrope_State, &
                              CD_Set_System_Line_Syrope_State, &
                              CD_System_Line_VIV_MirrorSize, CD_Get_System_Line_VIV_State, &
                              CD_Set_System_Line_VIV_State, &
                              CD_System_Line_Has_Friction, CD_Get_System_Line_Friction_Anchors, &
                              CD_Set_System_Line_Friction_Anchors, &
                              CD_Recompute_System_Acceleration, CD_SYSTEM_OK
   USE SeaSt_WaveField, ONLY: WaveField_GetNodeWaveKin
   USE SeaSt_WaveField_Types, ONLY: WaveMod_None
   USE IfW_FlowField_Types, ONLY: Grid3D_FieldType

   IMPLICIT NONE

   PRIVATE

   ! Depth fraction above which the deepest interval of the SeaState grid is noted at initialisation
   ! (note_seastate_deep_interval).
   REAL(wp), PARAMETER :: SEASTATE_DEEP_INTERVAL = 0.05_wp

   ! the kinds of first-order linearization state (lin_state_map)
   INTEGER(IntKi), PARAMETER :: LIN1_VE = 1, LIN1_SYROPE = 2

   TYPE(ProgDesc), PARAMETER :: CableDyn_ProgDesc = ProgDesc( 'CableDyn', 'v0.4.2', '2026-11-09' )
   INTERFACE
      ! 1 when the CableDyn core targets x86-64-v3 (CABLEDYN_TARGET_AVX2) and carries the
      ! start-up processor check of src/cabledyn_cpu_guard.c; the reference also keeps that
      ! check in a static link of the core into the OpenFAST executable
      FUNCTION cd_cpu_guard_armed() BIND(C, name='cabledyn_cpu_guard_armed') RESULT(armed)
         USE, INTRINSIC :: ISO_C_BINDING, ONLY: C_INT
         INTEGER(C_INT) :: armed
      END FUNCTION cd_cpu_guard_armed
   END INTERFACE

   !> Module-level instance registry: the CableDyn solver objects cannot live inside the
   !> registry-generated types, so each initialized module holds an integer handle
   !> (m%CDInst) into this PRIVATE table. A handle that does not refer to an ACTIVE
   !> entry (e.g. after a checkpoint restore in a fresh process) fails closed.
   TYPE :: CD_OF_Instance
      TYPE(CD_AGG_ModuleType) :: agg
      INTEGER(IntKi)          :: ncp     = 0        ! number of coupled points (mesh nodes)
      INTEGER(IntKi)          :: nlines  = 0
      INTEGER(IntKi)          :: last_n  = -1       ! last completed glue step number (correction detection)
      INTEGER(IntKi)          :: last_solve_n = -1  ! glue-step index of the last actual mooring solve
      ! CableDyn's OWN time step (supercycling): the implicit mooring solve advances at
      ! dt_moor = nsuper * (glue DT), ONE step per nsuper glue steps, instead of being
      ! chained to the turbine's small DT. The deck's OPTIONS dtM sets it (clamped to at
      ! least the glue DT); absent a deck dtM the mooring solves every glue step. Between
      ! mooring solves CD_CalcOutput returns the last committed load state, extrapolated from
      ! the solve before it (deck OPTION predictLoads, the default) or held; feeding
      ! instantaneous endpoints into a lagged mooring interior creates artificial stiff-EA
      ! load chatter.
      INTEGER(IntKi)          :: nsuper  = 1        ! glue steps per mooring step
      REAL(wp)                :: dt_moor = 0.0_wp   ! the mooring step frozen into the aggregate
      LOGICAL                 :: active  = .FALSE.
      ! Persistent marching-path workspace (3, ncp): CD_UpdateStates and CD_CalcOutput run
      ! every glue step of a long simulation, so their kinematics/load scratch must not be
      ! heap-allocated per call. Grow-only: allocated on first use, reused thereafter.
      REAL(wp), ALLOCATABLE   :: ws_pos(:,:), ws_vel(:,:), ws_acc(:,:), ws_fld(:,:), ws_moment(:,:)
      REAL(wp), ALLOCATABLE   :: ws_omega(:,:), ws_alpha(:,:)
      REAL(wp), ALLOCATABLE   :: ws_orient(:,:,:)
      ! the coupled loads (3, ncp) and deck channels of the last lin_eval, in double precision:
      ! the linearization Jacobians difference these (pack_lin_outputs), not the ReKi output
      ! mesh, which a single-precision OpenFAST build (the Visual Studio Release configuration)
      ! rounds to 7 digits, too few for loads of order 1e6 N over a 1 um step
      REAL(wp), ALLOCATABLE   :: lin_fld(:,:), lin_moment(:,:), lin_chan(:)
      ! saved committed coupled kinematics for the state-const CalcOutput at nsuper = 1
      ! (save -> transfer u -> evaluate -> restore; see CD_CalcOutput)
      REAL(wp), ALLOCATABLE   :: sv_pos(:,:), sv_vel(:,:), sv_acc(:,:), sv_orient(:,:,:)
      REAL(wp), ALLOCATABLE   :: sv_omega(:,:), sv_alpha(:,:)
      ! Supercycled-CalcOutput cache: between mooring steps the committed state does not
      ! change, so held loads/channels are recomputed only after a new solve commit.
      LOGICAL                 :: loads_cached = .FALSE.
      INTEGER(IntKi)          :: loads_at_n = -1
      REAL(wp), ALLOCATABLE   :: ws_chan(:)
      ! Load predictor (nsuper > 1 with predictLoads; CableDyn_LoadPredictor): the coupled
      ! loads and moments of the committed solve before the last and its time (pred_t < 0:
      ! none), shifted in by CD_UpdateStates when a mooring step starts and mirrored into the
      ! OtherState for restarts; ws_pfld/ws_pmom hold the extrapolated loads CalcOutput serves.
      REAL(wp), ALLOCATABLE   :: pred_fld(:,:), pred_mom(:,:), ws_pfld(:,:), ws_pmom(:,:)
      REAL(DbKi)              :: pred_t = -1.0_DbKi
      ! Persistent interpolated-input container: CD_UpdateStates interpolates the coupled
      ! kinematics to the mooring interval end; the mesh copy is built ONCE and reused
      ! (ExtrapInterp overwrites the fields in place), never created/destroyed per step.
      TYPE(CD_InputType)      :: u_interp
      LOGICAL                 :: u_interp_ready = .FALSE.
      ! State-mirror packing scratch (pack_state_mirror runs once per actual mooring step;
      ! as locals its grow-only guards were dead logic -- automatic deallocation on return
      ! made every call re-allocate). Grow-only across calls here.
      REAL(wp), ALLOCATABLE   :: ws_qL(:), ws_vL(:), ws_aL(:), ws_cbuf(:)
      ! committed-state mirror captured before a state-const CalcOutput transfer;
      ! restored after (the boundary-only restore recomputes interior accelerations,
      ! which are gen-alpha COMMITTED values, not (q, v)-derivable)
      REAL(R8Ki), ALLOCATABLE :: ws_msave(:)
      ! Linearization with the line dynamics (lin_state_map): for every state, its position,
      ! velocity and acceleration slots in the x%states mirror, and the mirror save/work
      ! buffers of lin_eval
      LOGICAL                 :: lin_states = .FALSE.
      INTEGER(IntKi), ALLOCATABLE :: lin_pos(:), lin_vel(:), lin_acc(:)
      ! the first-order linearization states, the per-element constitutive states of the
      ! EI = 0 lines: mirror slot, line, element and kind (LIN1_VE: the viscoelastic slow-branch
      ! stretch dl_1; LIN1_SYROPE: the Syrope slow strain)
      INTEGER(IntKi), ALLOCATABLE :: lin1_slot(:), lin1_line(:), lin1_elem(:), lin1_kind(:)
      REAL(R8Ki), ALLOCATABLE :: ws_lsave(:), ws_lwork(:)
      ! FAST.Farm: turbine count (0 = plain single-turbine mode), the driving turbine
      ! per flat aggregate moving slot, that slot's node index within its turbine's
      ! mesh, the farm-layout reference offsets, and the per-turbine PtfmInit.
      INTEGER(IntKi)          :: nT = 0
      INTEGER(IntKi), ALLOCATABLE :: tmap(:), node_of_slot(:)
      REAL(R8Ki), ALLOCATABLE :: farm_ref(:,:), farm_ptfm(:,:)
      ! CableDyn-owned committed-step record. Unlike OpenFAST WriteOutput (sampled on the
      ! host DT_Out clock and therefore repeated under supercycling), this writes exactly
      ! one row per committed dtM solve. A correction re-evaluation overwrites the last row.
      ! FAST.Farm keeps its established <RootName>.out name; a single-turbine run writes
      ! <OpenFASTRoot>.CD.out. native_un < 0 means no deck time-history channels.
      INTEGER(IntKi)          :: native_un = -1
      INTEGER(IntKi)          :: native_wrote_n = -123456789
      REAL(DbKi)              :: native_wrote_t = 0.0_DbKi
      LOGICAL                 :: native_pending = .FALSE.
      CHARACTER(1024)         :: native_root = ''
      ! Range graphs (LINES flag r): sampled by the aggregate once per committed mooring step
      ! (sample_range); ws_range is the double-precision transfer buffer to the OtherState
      ! mirror, which a checkpoint packs and a correction iteration's state copy rewinds.
      LOGICAL                 :: range_on = .FALSE.
      LOGICAL                 :: range_sampled = .FALSE.   ! this instance has sampled (not a checkpoint alone)
      REAL(wp), ALLOCATABLE   :: ws_range(:)
      ! SeaState ambient-fluid sampling (host-driven wave/current kinematics): when the
      ! glue's WaveField declares waves or a current, the aggregate is built wave-capable
      ! (external_fluid) and every mooring advance samples the field at the line nodes'
      ! committed positions -- velocity, acceleration, and the local surface elevation --
      ! and prescribes them for the step (a per-mooring-step zero-order hold, the same
      ! weak-coupling cadence the loads-out side documents). Workspaces sized at Init.
      LOGICAL                 :: use_extfluid = .FALSE.
      INTEGER(IntKi)          :: nfluid = 0
      REAL(wp), ALLOCATABLE   :: fx_xyz(:,:), fx_vel(:,:), fx_acc(:,:), fx_wl(:), fx_pd(:)
      ! TRUE once the warning that sampling nodes lie outside the SeaState wave-kinematics
      ! grid has been issued: one warning per run (check_wavefield_grid).
      LOGICAL                 :: grid_warned = .FALSE.
      LOGICAL                 :: curr_grid_warned = .FALSE.   !< the dynamic current-field grid check has warned
      ! CHECKPOINT-RESTART identity: serial is the generation stamp minted at
      ! Init/rebuild and mirrored into other%restart_serial; t_commit is the time of the
      ! last committed mooring advance, mirrored into other%t_commit. A restored
      ! OtherState that does not match the live instance (stamp mismatch = fresh
      ! process; live clock AHEAD of the restored clock = same-process rewind) triggers
      ! rebuild_from_checkpoint.
      INTEGER(IntKi)          :: serial = 0
      REAL(DbKi)              :: t_commit = -1.0_DbKi
      ! t_commit_prev: the commit the last advance started from, which a glue retry of that step
      ! restores (step_retry). t_run_end: the last time the run has committed, later than
      ! t_commit after a restore of an operating point; rewound marks that state, in which the
      ! rows and the range samples past t_commit stand until the run takes another step.
      REAL(DbKi)              :: t_commit_prev = -1.0_DbKi
      REAL(DbKi)              :: t_run_end = -1.0_DbKi
      LOGICAL                 :: rewound = .FALSE.
      ! restored_unserved: a rebuilt, supercycled instance whose committed loads have not been
      ! evaluated yet (serve_committed_loads)
      LOGICAL                 :: restored_unserved = .FALSE.
      ! Opt-in end-to-end profiler. CABLEDYN_PROFILE=1 arms these counters and
      ! the existing detailed Hermite profiler; ordinary production runs pay no
      ! SYSTEM_CLOCK overhead. Times are accumulated only for successful calls.
      LOGICAL                 :: prof_enabled = .FALSE.
      INTEGER(IntKi)          :: prof_n_update = 0, prof_n_solve = 0
      INTEGER(IntKi)          :: prof_n_calcout = 0, prof_n_fresh = 0, prof_n_wave = 0
      REAL(wp)                :: prof_t_init = 0.0_wp, prof_t_update = 0.0_wp
      REAL(wp)                :: prof_t_wave = 0.0_wp, prof_t_step = 0.0_wp
      REAL(wp)                :: prof_t_calcout = 0.0_wp, prof_t_loads = 0.0_wp
      REAL(wp)                :: prof_t_native = 0.0_wp
      ! parts of calcout_s (the overlay and restore of the current kinematics, at nsuper = 1, and
      ! the channels of a fresh evaluation) and of wave_s (the SeaState node queries with the
      ! current decomposition, the grid checks, the hand-over of the fields to the aggregate)
      REAL(wp)                :: prof_t_overlay = 0.0_wp, prof_t_channels = 0.0_wp
      REAL(wp)                :: prof_t_restore = 0.0_wp
      REAL(wp)                :: prof_t_wave_kin = 0.0_wp, prof_t_wave_check = 0.0_wp
      REAL(wp)                :: prof_t_wave_set = 0.0_wp
   END TYPE CD_OF_Instance

   TYPE(CD_OF_Instance), ALLOCATABLE, SAVE :: Inst(:)
   INTEGER(IntKi), SAVE :: g_serial = 0   ! monotonic generation counter (Init/rebuild mints)

   PUBLIC :: CD_Init
   PUBLIC :: CD_UpdateStates
   PUBLIC :: CD_CalcOutput
   PUBLIC :: CD_CalcContStateDeriv
   PUBLIC :: CD_End
   PUBLIC :: CD_JacobianPContState
   PUBLIC :: CD_JacobianPInput
   PUBLIC :: CD_JacobianPDiscState
   PUBLIC :: CD_JacobianPConstrState

CONTAINS

!----------------------------------------------------------------------------------------------------------------------------------
   SUBROUTINE open_native_outputs( id, root, t_start, ErrStat, ErrMsg, write_profile )
      !! Create a self-contained CableDyn result set at the current committed state.
      !! A checkpoint rebuild must first release or adopt any process-local owner of
      !! the same path through restore_native_outputs. write_profile = .FALSE. keeps a
      !! static profile the caller has already written (CD_Init writes it at the
      !! equilibrium, before the host kinematics are seeded).
      INTEGER(IntKi),       INTENT(IN)    :: id
      CHARACTER(*),        INTENT(IN)    :: root
      REAL(DbKi),           INTENT(IN)    :: t_start
      INTEGER(IntKi),       INTENT(OUT)   :: ErrStat
      CHARACTER(*),         INTENT(OUT)   :: ErrMsg
      LOGICAL, OPTIONAL,    INTENT(IN)    :: write_profile

      character(*), parameter :: RoutineName = 'CableDyn:open_native_outputs'
      INTEGER(IntKi)          :: es, un, ic, nch, owner, ios
      CHARACTER(ErrMsgLen)          :: em, iomsg
      CHARACTER(ChanLen)      :: hdr, unt
      REAL(wp)                :: value
      LOGICAL                 :: write_static

      ErrStat = ErrID_None
      ErrMsg = ''
      IF (id < 1_IntKi .OR. .NOT. ALLOCATED(Inst) .OR. id > SIZE(Inst)) THEN
         CALL SetErrStat( ErrID_Fatal, 'Invalid solver-instance handle for native output.', &
                          ErrStat, ErrMsg, RoutineName )
         RETURN
      END IF
      IF (Inst(id)%native_un > 0) CLOSE (Inst(id)%native_un)
      Inst(id)%native_un = -1_IntKi
      Inst(id)%native_wrote_n = -123456789_IntKi
      Inst(id)%native_wrote_t = MAX(t_start, 0.0_DbKi)
      Inst(id)%native_pending = .FALSE.
      Inst(id)%native_root = TRIM(root)

      write_static = .TRUE.
      IF (PRESENT(write_profile)) write_static = write_profile
      IF (write_static) THEN
         CALL CD_AGG_WriteStaticProfile( Inst(id)%agg, TRIM(root)//'.static.out', es, em )
         IF (es /= CD_AGG_OK) THEN
            CALL SetErrStat( ErrID_Fatal, TRIM(em), ErrStat, ErrMsg, RoutineName )
            RETURN
         END IF
      END IF

      nch = CD_AGG_NumChannels(Inst(id)%agg)
      IF (nch <= 0) RETURN
      ! MoorDyn numbers line nodes from N0, CableDyn from N1: say so as the standalone driver does
      DO ic = 1, nch
         CALL CD_AGG_ChannelHeader(Inst(id)%agg, ic, hdr, unt, es, em)
         IF (es /= CD_AGG_OK) EXIT
         IF (.NOT. CD_Is_Line_Node_Channel(hdr)) CYCLE
         CALL WrScr( '   Note: '//CD_LINE_NODE_NUMBERING_NOTE//'.' )
         EXIT
      END DO
      ! One run-level path has one owner. A rebuilt state must adopt the existing
      ! unit through restore_native_outputs rather than attempting a second OPEN.
      DO owner = 1, SIZE(Inst)
         IF (owner == id) CYCLE
         IF (Inst(owner)%active .AND. Inst(owner)%native_un > 0 .AND. &
             TRIM(Inst(owner)%native_root) == TRIM(root)) THEN
            CALL SetErrStat( ErrID_Fatal, 'Native output path "'//TRIM(root)//'.out" is already owned '// &
                             'by another live CableDyn instance.', ErrStat, ErrMsg, RoutineName )
            RETURN
         END IF
      END DO
      CALL GetNewUnit(un)
      ! Read/write access is deliberate. The glue can restore a registered state
      ! after a row has been committed, in which case restore_native_outputs must
      ! BACKSPACE and replace the abandoned row. OpenFOutFile opens write-only and
      ! therefore makes that standard record-positioning operation fail on gfortran.
      iomsg = ''
      ! CD_Path_Openable: a failing OPEN of a long name ends the ifx run-time (CableDyn_PathIO)
      IF (CD_Path_Openable(TRIM(root)//'.out', .TRUE.)) THEN
         OPEN (un, FILE=TRIM(root)//'.out', STATUS='REPLACE', FORM='FORMATTED', &
               ACTION='READWRITE', POSITION='REWIND', IOSTAT=ios, IOMSG=iomsg)
      ELSE
         ios = 1
         iomsg = 'The file cannot be created or written.'
      END IF
      IF (ios /= 0) THEN
         CALL SetErrStat( ErrID_Fatal, 'Cannot open native output file "'//TRIM(root)// &
                          '.out" for transactional read/write access. '//TRIM(iomsg), &
                          ErrStat, ErrMsg, RoutineName )
         RETURN
      END IF

      WRITE (un, '(A)', ADVANCE='NO') 'Time'
      DO ic = 1, nch
         CALL CD_AGG_ChannelHeader(Inst(id)%agg, ic, hdr, unt, es, em)
         IF (es /= CD_AGG_OK) THEN
            CLOSE (un, STATUS='DELETE')
            CALL SetErrStat( ErrID_Fatal, TRIM(em), ErrStat, ErrMsg, RoutineName )
            RETURN
         END IF
         WRITE (un, '(A)', ADVANCE='NO') CHAR(9)//TRIM(hdr)
      END DO
      WRITE (un, '(A)') ''
      WRITE (un, '(A)', ADVANCE='NO') '(s)'
      DO ic = 1, nch
         CALL CD_AGG_ChannelHeader(Inst(id)%agg, ic, hdr, unt, es, em)
         IF (es /= CD_AGG_OK) THEN
            CLOSE (un, STATUS='DELETE')
            CALL SetErrStat( ErrID_Fatal, TRIM(em), ErrStat, ErrMsg, RoutineName )
            RETURN
         END IF
         WRITE (un, '(A)', ADVANCE='NO') CHAR(9)//TRIM(unt)
      END DO
      WRITE (un, '(A)') ''
      WRITE (un, '(ES25.16E3)', ADVANCE='NO') MAX(t_start, 0.0_DbKi)
      DO ic = 1, nch
         CALL CD_AGG_EvalChannel(Inst(id)%agg, ic, value, es, em)
         IF (es /= CD_AGG_OK) THEN
            CLOSE (un, STATUS='DELETE')
            CALL SetErrStat( ErrID_Fatal, 'Initial committed-step channel record: '//TRIM(em), &
                             ErrStat, ErrMsg, RoutineName )
            RETURN
         END IF
         WRITE (un, CD_NATIVE_CHANNEL_FMT, ADVANCE='NO') CHAR(9), value
      END DO
      WRITE (un, '(A)') ''
      FLUSH (un)
      Inst(id)%native_un = un
      ! At initialization no glue step has advanced. A rebuilt output begins at the
      ! checkpoint state and the next solve receives a non-negative glue-step index.
      Inst(id)%native_wrote_n = -1_IntKi
      Inst(id)%native_wrote_t = MAX(t_start, 0.0_DbKi)
   END SUBROUTINE open_native_outputs

!----------------------------------------------------------------------------------------------------------------------------------
   SUBROUTINE restore_native_outputs( id, old_id, root, t_start, restart_serial, ErrStat, ErrMsg )
      !! Transfer the run-level native history from a superseded in-process solver instance to
      !! its checkpoint reconstruction: the restore of an operating point (CalcSteady) keeps the
      !! rows of the run, and only a later step abandons those past the restored commit
      !! (resume_after_rewind). A fresh-process restart has no live owner and creates a new
      !! history. Neither route writes the static profile: the state here is the checkpoint's,
      !! not the static equilibrium that file records.
      INTEGER(IntKi), INTENT(IN)  :: id, old_id, restart_serial
      CHARACTER(*),   INTENT(IN)  :: root
      REAL(DbKi),      INTENT(IN)  :: t_start
      INTEGER(IntKi), INTENT(OUT) :: ErrStat
      CHARACTER(*),   INTENT(OUT) :: ErrMsg

      character(*), parameter :: RoutineName = 'CableDyn:restore_native_outputs'
      INTEGER(IntKi)          :: ios
      LOGICAL                 :: live_owner, same_history

      ErrStat = ErrID_None
      ErrMsg = ''
      live_owner = .FALSE.
      same_history = .FALSE.
      IF (ALLOCATED(Inst)) THEN
         IF (old_id >= 1_IntKi .AND. old_id <= SIZE(Inst)) THEN
            live_owner = Inst(old_id)%active .AND. Inst(old_id)%native_un > 0 .AND. &
                         TRIM(Inst(old_id)%native_root) == TRIM(root)
            same_history = live_owner .AND. Inst(old_id)%serial == restart_serial
         END IF
      END IF
      IF (.NOT. live_owner) THEN
         CALL open_native_outputs( id, root, t_start, ErrStat, ErrMsg, write_profile=.FALSE. )
         RETURN
      END IF

      ! A fresh-process restart first passes through CD_Init, which creates a
      ! provisional t=0 stream. The restored generation stamp differs, so release
      ! that stream and recreate it at the checkpoint. It must not be treated as a
      ! same-process restore because it contains no pre-checkpoint history.
      IF (.NOT. same_history) THEN
         CLOSE (Inst(old_id)%native_un, IOSTAT=ios)
         IF (ios /= 0) THEN
            CALL SetErrStat( ErrID_Fatal, 'Could not release the provisional native-output stream during restart.', &
                             ErrStat, ErrMsg, RoutineName )
            RETURN
         END IF
         Inst(old_id)%native_un = -1_IntKi
         Inst(old_id)%native_root = ''
         Inst(old_id)%native_wrote_n = -123456789_IntKi
         Inst(old_id)%native_wrote_t = 0.0_DbKi
         Inst(old_id)%native_pending = .FALSE.
         CALL open_native_outputs( id, root, t_start, ErrStat, ErrMsg, write_profile=.FALSE. )
         RETURN
      END IF

      Inst(id)%native_un = Inst(old_id)%native_un
      Inst(id)%native_root = Inst(old_id)%native_root
      Inst(id)%native_wrote_t = Inst(old_id)%native_wrote_t
      Inst(id)%native_wrote_n = Inst(old_id)%native_wrote_n
      Inst(id)%native_pending = .FALSE.

      Inst(old_id)%native_un = -1_IntKi
      Inst(old_id)%native_root = ''
      Inst(old_id)%native_wrote_n = -123456789_IntKi
      Inst(old_id)%native_wrote_t = 0.0_DbKi
      Inst(old_id)%native_pending = .FALSE.
   END SUBROUTINE restore_native_outputs

   SUBROUTINE resume_after_rewind( inst_e, other, ErrStat, ErrMsg )
      !! The run takes a step from a restored state that lies before its last commit: the rows
      !! and the range samples past the restored commit now belong to an abandoned branch.
      TYPE(CD_OF_Instance),     INTENT(INOUT) :: inst_e
      TYPE(CD_OtherStateType),  INTENT(IN   ) :: other
      INTEGER(IntKi),           INTENT(  OUT) :: ErrStat
      CHARACTER(*),             INTENT(  OUT) :: ErrMsg

      character(*), parameter :: RoutineName = 'CableDyn:resume_after_rewind'
      INTEGER(IntKi)          :: ntrim, k, ios
      REAL(DbKi)              :: delta, tol

      ErrStat = ErrID_None
      ErrMsg = ''
      inst_e%rewound = .FALSE.
      inst_e%t_run_end = inst_e%t_commit
      IF (inst_e%range_on) THEN
         CALL restore_range_state( inst_e, other, ErrStat, ErrMsg )
         IF (ErrStat >= AbortErrLev) RETURN
      END IF
      IF (inst_e%native_un <= 0_IntKi) RETURN
      tol = 1.0E-7_DbKi*MAX(1.0_DbKi, ABS(inst_e%t_commit), ABS(inst_e%native_wrote_t))
      delta = MAX(inst_e%native_wrote_t - inst_e%t_commit, 0.0_DbKi)
      ntrim = NINT(delta/REAL(inst_e%dt_moor, DbKi), IntKi)
      IF (ABS(delta - REAL(ntrim, DbKi)*REAL(inst_e%dt_moor, DbKi)) > tol) THEN
         CALL SetErrStat( ErrID_Fatal, 'The native-history rewind is not an integer number of CableDyn steps.', &
                          ErrStat, ErrMsg, RoutineName )
         RETURN
      END IF
      DO k = 1, ntrim
         BACKSPACE (inst_e%native_un, IOSTAT=ios)
         IF (ios /= 0) THEN
            CALL SetErrStat( ErrID_Fatal, 'Could not remove abandoned native-output record '// &
                             TRIM(Num2LStr(k))//' of '//TRIM(Num2LStr(ntrim))//' while rewinding from t = '// &
                             TRIM(Num2LStr(inst_e%native_wrote_t))//' s to t = '// &
                             TRIM(Num2LStr(inst_e%t_commit))//' s.', ErrStat, ErrMsg, RoutineName )
            RETURN
         END IF
      END DO
      IF (ntrim > 0_IntKi) THEN
         ENDFILE (inst_e%native_un, IOSTAT=ios)
         IF (ios == 0) BACKSPACE (inst_e%native_un, IOSTAT=ios)
         IF (ios /= 0) THEN
            CALL SetErrStat( ErrID_Fatal, 'Could not truncate the abandoned native-output branch.', &
                             ErrStat, ErrMsg, RoutineName )
            RETURN
         END IF
      END IF
      inst_e%native_wrote_n = -123456789_IntKi
      inst_e%native_wrote_t = inst_e%t_commit
   END SUBROUTINE resume_after_rewind

!----------------------------------------------------------------------------------------------------------------------------------
   SUBROUTINE CD_Init(InitInp, u, p, x, xd, z, other, y, m, DTcoupling, InitOut, ErrStat, ErrMsg)
      TYPE(CD_InitInputType),       INTENT(IN   )  :: InitInp
      TYPE(CD_InputType),           INTENT(  OUT)  :: u
      TYPE(CD_ParameterType),       INTENT(  OUT)  :: p
      TYPE(CD_ContinuousStateType), INTENT(  OUT)  :: x
      TYPE(CD_DiscreteStateType),   INTENT(  OUT)  :: xd
      TYPE(CD_ConstraintStateType), INTENT(  OUT)  :: z
      TYPE(CD_OtherStateType),      INTENT(  OUT)  :: other
      TYPE(CD_OutputType),          INTENT(  OUT)  :: y
      TYPE(CD_MiscVarType),         INTENT(  OUT)  :: m
      REAL(DbKi),                   INTENT(INOUT)  :: DTcoupling
      TYPE(CD_InitOutputType),      INTENT(  OUT)  :: InitOut
      INTEGER(IntKi),               INTENT(  OUT)  :: ErrStat
      CHARACTER(*),                 INTENT(  OUT)  :: ErrMsg

      character(*), parameter   :: RoutineName = 'CD_Init'
      INTEGER(IntKi)            :: ErrStat2, es
      CHARACTER(ErrMsgLen)      :: ErrMsg2
      CHARACTER(ErrMsgLen)            :: em
      INTEGER(IntKi)            :: id, ncp, nlines, il, i, ndofl, nstates, ic, nch, nsuper, nglue
      INTEGER(IntKi)            :: nreportlines, npoints, nsections, nei0, nfinite, line_id
      INTEGER(IntKi)            :: clock_count, nT, prof_c0, prof_c1, prof_rate
      LOGICAL                   :: farm_has_ptfm, profile_requested
      REAL(wp), ALLOCATABLE     :: pos(:,:), vel(:,:), acc(:,:), fld(:,:)
      REAL(R8Ki)                :: OrientIdent(3,3)
      REAL(R8Ki)                :: OrMatInit(3,3), ptfm6(6), refpos(3)
      REAL(wp)                  :: cval, dtC, deck_dtm, dt_moor
      REAL(wp)                  :: fair_ten, fair_force(3), fair_incl, fair_decl, fair_azi, force_incl
      LOGICAL                   :: has_dtm, has_ptfm, use_extf
      ! the coupling step's name on the console: the glue DT, or FAST.Farm's DT_Mooring
      CHARACTER(24)             :: dtc_name, dtc_short
      ! the deck's WaterKin policy takes SeaState waves or current (host_seastate), or a
      ! WaterKin current table (host_table); neither is still water
      LOGICAL                   :: host_seastate, host_table
      CHARACTER(16)             :: host_kin
      REAL(wp), ALLOCATABLE     :: static_cur(:,:)   ! the host's steady current for the static start
      CHARACTER(ChanLen)        :: chan_hdr, chan_unt
      CHARACTER(1024)           :: native_root
      CHARACTER(CD_INIT_NOTE_LEN) :: init_note
      INTEGER(IntKi)            :: note_at, note_end

      ErrStat = ErrID_None
      ErrMsg  = ''
      host_seastate = .FALSE.
      profile_requested = profile_environment_requested()
      IF (profile_requested) THEN
         CALL SYSTEM_CLOCK(prof_c0, prof_rate)
      ELSE
         ! Disarm before any static/dynamic initialization work. This also covers an
         ! initialization that later fails and never reaches the live-instance setup.
         CALL CD_HermiteCable_Dyn_Disable_Profile()
         CALL CD_Profile_Disarm()
      END IF

      ! ------------------------------------------------------------------------------
      ! The CableDyn identity, announced at OpenFAST initialization the way every
      ! OpenFAST module does (DispNVD one-line version banner, then WrScr identity
      ! lines; cf. MoorDyn.f90 Init). DispCopyrightLicense is deliberately NOT used --
      ! it hard-codes the NREL/Envision copyright, whereas CableDyn is (C) SMI Lab,
      ! Inha University under Apache-2.0. InitOut%Ver feeds the glue summary file.
      ! ------------------------------------------------------------------------------
      CALL DispNVD( CableDyn_ProgDesc )
      InitOut%Ver = CableDyn_ProgDesc
      CALL WrScr( '   CableDyn: geometrically exact finite-element statics and dynamics of mooring lines '// &
                  'and dynamic power cables.' )
      CALL WrScr( '   Author Prof. Jae Hoon Seo, Inha University.  License Apache-2.0.' )
      CALL WrScr( '   CompMooring = 5: mooring and dynamic power-cable loads are computed by CableDyn,' )
      CALL WrScr( '   an OpenFAST mooring module alongside MoorDyn (CompMooring = 3) in this binary.' )
      IF (cd_cpu_guard_armed() /= 0) CALL WrScr( '   CableDyn build: x86-64-v3 (AVX2).' )

      ! ------------------------------------------------------------------------------
      ! Scope guards (named fail-closed messages; see the module header)
      ! ------------------------------------------------------------------------------
      IF (InitInp%FarmSize > 0 .AND. InitInp%Linearize) THEN
         CALL SetErrStat( ErrID_Fatal, 'CableDyn mooring module: linearization in FAST.Farm mode is '// &
                          'not supported (linearize single-turbine cases).', ErrStat, ErrMsg, RoutineName )
         RETURN
      END IF
      ! Linearize registers the line states (CD_InitVars, lin_state_map) and differentiates the
      ! line dynamics (lin_eval); the objects whose states are not linearization states are
      ! rejected after deck construction below.
      IF (.NOT. InitInp%UsePrimaryInputFile) THEN
         CALL SetErrStat( ErrID_Fatal, 'CableDyn mooring module: passed-in primary input data is not '// &
                          'supported; provide the MoorDyn-format deck as a file.', ErrStat, ErrMsg, RoutineName )
         RETURN
      END IF
      ! Initial platform displacement (PtfmInit): the deck's Coupled/Vessel points are
      ! rigid-transformed BEFORE the build, so the true-Newton static equilibrium is
      ! solved at the DISPLACED pose -- correct by construction, never an implicit step
      ! from the undisplaced statics. Mirrors MoorDyn-F's convention exactly: the ZYX
      ! (3-2-1) DCM applied transposed, mesh reference positions kept at the UNDISPLACED
      ! deck coordinates, and the initial displacement carried in TranslationDisp (the
      ! glue's motion mapping anchors on reference positions).
      ptfm6 = 0.0_R8Ki
      nT = MAX(0_IntKi, InitInp%FarmSize)
      IF (nT > 0) THEN
         ! FAST.Farm: per-turbine PtfmInit + farm-layout reference offsets are consumed
         ! below through the aggregate's farm mode; the single-turbine ptfm path is off.
         IF (.NOT. ALLOCATED(InitInp%TurbineRefPos)) THEN
            CALL SetErrStat( ErrID_Fatal, 'CableDyn mooring module: FAST.Farm mode needs '// &
                             'TurbineRefPos(3, FarmSize).', ErrStat, ErrMsg, RoutineName )
            RETURN
         END IF
         IF (SIZE(InitInp%TurbineRefPos, 1) /= 3 .OR. SIZE(InitInp%TurbineRefPos, 2) /= nT) THEN
            CALL SetErrStat( ErrID_Fatal, 'CableDyn mooring module: TurbineRefPos must be shaped '// &
                             '(3, FarmSize).', ErrStat, ErrMsg, RoutineName )
            RETURN
         END IF
      ELSE IF (ALLOCATED(InitInp%PtfmInit)) THEN
         ! SIZE > 0 first: MAXVAL of a zero-size array is -HUGE (well-defined but obscure);
         ! an empty allocation reads explicitly as "no displacement declared".
         IF (SIZE(InitInp%PtfmInit, 1) >= 6 .AND. SIZE(InitInp%PtfmInit, 2) >= 1) THEN
            ptfm6 = REAL(InitInp%PtfmInit(1:6, 1), R8Ki)
         END IF
      END IF
      has_ptfm = MAXVAL(ABS(ptfm6)) > 0.0_R8Ki
      IF (has_ptfm) THEN
         WRITE (em, '(A,6(1X,ES24.16))') '   CableDyn initial platform pose [x y z roll pitch yaw]:', ptfm6
         CALL WrScr(TRIM(em))
      END IF

      ! Keep a packable copy of the deck in the parameters so a checkpoint carries it.
      CALL ProcessComFile( InitInp%FileName, p%DeckCopy, ErrStat2, ErrMsg2 )
      CALL SetErrStat( ErrStat2, ErrMsg2, ErrStat, ErrMsg, RoutineName )
      IF (ErrStat >= AbortErrLev) RETURN

      ! ------------------------------------------------------------------------------
      ! Build the CableDyn system from the deck: parse, feature-gate (the deck layer
      ! carries its own named rejections), TRUE Newton static equilibrium, models.
      ! ------------------------------------------------------------------------------
      id = new_instance()

      ! ------------------------------------------------------------------------------
      ! CableDyn's OWN time step. The implicit generalised-alpha solve can remain stable at a
      ! large mooring step, but stability does not establish time-domain or fatigue accuracy,
      ! and the loads held between solves reach the platform about dtM/2 late (a negative
      ! damping of about the mooring stiffness times dtM/2). The default therefore solves
      ! every glue step; a deck may advance at dt_moor = nsuper * DT (one implicit step per
      ! nsuper glue steps): the deck's OPTIONS dtM is the author's intent (rounded down to an
      ! integer multiple of the glue DT and clamped to at least one glue step -- a
      ! MoorDyn-migrated deck's explicit-RK4 dtM like 0.001 s does not transfer to an
      ! implicit solver). The CableDyn-owned .CD.out records only committed dtM rows;
      ! OpenFAST's assembled output still receives zero-order-held module channels at DT_Out.
      ! Between coarse mooring steps, CD_CalcOutput returns the last committed mooring load
      ! state as a zero-order hold; injecting instantaneous
      ! endpoint motion into a lagged line interior creates nonphysical stiff-EA chatter.
      ! ------------------------------------------------------------------------------
      dtC = REAL(DTcoupling, wp)
      ! In FAST.Farm the coupling step is the farm's mooring step DT_Mooring, not a turbine's DT.
      IF (nT > 0_IntKi) THEN
         dtc_name = 'FAST.Farm DT_Mooring'
         dtc_short = 'DT_Mooring'
      ELSE
         dtc_name = 'glue DT'
         dtc_short = 'DT'
      END IF
      CALL CD_Deck_Query_dtM( TRIM(InitInp%FileName), deck_dtm, has_dtm, es, em, &
                              env_gravity=REAL(InitInp%g, wp), env_rho_water=REAL(InitInp%rhoW, wp), &
                              env_wtrdpth=REAL(InitInp%WtrDepth, wp) )
      IF (es /= CD_DECKDRV_OK) THEN
         CALL SetErrStat( ErrID_Fatal, 'CableDyn mooring module: '//TRIM(em), ErrStat, ErrMsg, RoutineName )
         RETURN
      END IF
      IF (has_dtm) THEN
         ! Like MoorDyn-F (which shortens dtM so a whole number of its steps fills the
         ! coupling interval), an inexact deck dtM is only ever refined, never coarsened:
         ! use the largest multiple of the glue DT that does not exceed it, and say so as
         ! a WARNING stating both values. A dtM below DT is clamped to one glue step (the
         ! documented implicit-solver floor for MoorDyn-migrated explicit dtM values).
         nsuper = MAX(1_IntKi, FLOOR(deck_dtm/dtC*(1.0_wp + 1.0e-6_wp), IntKi))
         IF (deck_dtm < dtC*(1.0_wp - 1.0e-6_wp)) THEN
            CALL WrScr( '   CableDyn: deck dtM = '//TRIM(Num2LStr(deck_dtm))//' s is below the '// &
                        TRIM(dtc_name)//' = '//TRIM(Num2LStr(dtC))//' s; the implicit mooring step uses dtM = '// &
                        TRIM(dtc_short)//'.' )
         ELSE IF (ABS(REAL(nsuper, wp)*dtC - deck_dtm) > 1.0e-6_wp*MAX(dtC, deck_dtm)) THEN
            CALL SetErrStat( ErrID_Warn, 'CableDyn mooring module: deck dtM = '//TRIM(Num2LStr(deck_dtm))// &
                             ' s is not an integer multiple of the '//TRIM(dtc_name)//' = '//TRIM(Num2LStr(dtC))// &
                             ' s; using dtM = '//TRIM(Num2LStr(REAL(nsuper, wp)*dtC))//' s ('// &
                             TRIM(Num2LStr(nsuper))//' x '//TRIM(dtc_short)//'), the largest multiple not '// &
                             'exceeding the requested step. Set dtM to a multiple of '//TRIM(dtc_short)// &
                             ' to silence this warning.', ErrStat, ErrMsg, RoutineName )
            CALL WrScr( '   WARNING: CableDyn deck dtM = '//TRIM(Num2LStr(deck_dtm))//' s changed to '// &
                        TRIM(Num2LStr(REAL(nsuper, wp)*dtC))//' s ('//TRIM(Num2LStr(nsuper))// &
                        ' x '//TRIM(dtc_name)//' = '//TRIM(Num2LStr(dtC))//' s).' )
         END IF
      ELSE
         nsuper = 1_IntKi
      END IF
      dt_moor = REAL(nsuper, wp)*dtC
      CALL WrScr( '   CableDyn time step dtM = '//TRIM(Num2LStr(dt_moor))//' s ('//TRIM(Num2LStr(nsuper))// &
                  ' x '//TRIM(dtc_name)//TRIM(MERGE('; deck dtM   ', '; the default', has_dtm))//')' )
      ! The run must END on a mooring boundary: with supercycling, a trailing partial
      ! interval would take only skipped glue steps, leaving the committed mooring state --
      ! and the held (zero-order-hold) loads -- up to dtM stale at TMax, silently. Fail
      ! closed at Init with the fix named rather than finish on a stale state.
      IF (nsuper > 1_IntKi) THEN
         nglue = NINT(REAL(InitInp%Tmax, wp)/dtC, IntKi)
         IF (ABS(REAL(nglue, wp)*dtC - REAL(InitInp%Tmax, wp)) > 1.0e-6_wp*MAX(dtC, REAL(InitInp%Tmax, wp)) .OR. &
             MOD(nglue, nsuper) /= 0_IntKi) THEN
            CALL SetErrStat( ErrID_Fatal, 'CableDyn mooring module: TMax = '//TRIM(Num2LStr(InitInp%Tmax))// &
                             ' s is not a whole number of CableDyn steps (dtM = '//TRIM(Num2LStr(dt_moor))// &
                             ' s = '//TRIM(Num2LStr(nsuper))//' x '//TRIM(dtc_short)//'): the run would end '// &
                             'inside a mooring '// &
                             'interval with the committed state up to dtM stale. Choose TMax as a multiple '// &
                             'of dtM, or set the deck OPTIONS dtM accordingly.', ErrStat, ErrMsg, RoutineName )
            RETURN
         END IF
      END IF

      ! SeaState ambient fluid: when the glue hands a WaveField carrying waves or a
      ! current, the mooring receives it -- the aggregate is built WAVE-CAPABLE
      ! (external_fluid: the full drag/FK/added-mass/wetting hydro configuration at zero
      ! initial fields) and every mooring advance samples the field at the line nodes.
      ! A still-water field (WaveMod 0, no current) keeps the plain build, bit-for-bit.
      !
      ! FARM SCOPE: farm-level mooring runs in still water. The only WaveField reachable
      ! at the farm level is turbine 1's TURBINE-LOCAL field, whose spatial grid (SeaState
      ! X/Y_HalfWidth, typically ~100 m) does not cover a multi-kilometre farm mooring
      ! span -- sampling it beyond the grid returns clamped, nonphysical kinematics.
      ! Stock farm-level MoorDyn behaves the same way in practice (it holds the field
      ! pointer but samples nothing unless its deck declares WaterKin). Farm-wide wave
      ! kinematics on shared moorings needs a farm-domain field and is deferred with the
      ! scope stated here rather than silently wrong at the grid edge.
      use_extf = .FALSE.
      IF (ASSOCIATED(InitInp%WaveField) .AND. nT == 0_IntKi) THEN
         ! hasCurrField covers a dynamically-populated current field (e.g. an
         ! InflowWind-driven MHK current) that carries no CurrMod declaration --
         ! without it such a run would silently leave the mooring in still water.
         use_extf = wavefield_is_ambient( InitInp%WaveField )
         IF (use_extf) THEN
            ! the mooring water column must be the SeaState one (MoorDyn's own guard set)
            IF (ABS(InitInp%WaveField%WtrDpth - InitInp%WtrDepth) > 1.0E-3_ReKi) THEN
               CALL SetErrStat( ErrID_Fatal, 'CableDyn mooring module: SeaState water depth ('// &
                                TRIM(Num2LStr(InitInp%WaveField%WtrDpth))//' m) does not match the mooring '// &
                                'water depth ('//TRIM(Num2LStr(InitInp%WtrDepth))//' m).', ErrStat, ErrMsg, &
                                RoutineName )
               RETURN
            END IF
         END IF
      END IF

      ! The host owns the environment: gravity, water density, and depth override
      ! whatever the deck declares (MoorDyn-faithful coupled behavior).
      ! CableDyn-owned result files. Single-turbine names use p%RootName =
      ! <OpenFASTRoot>.CD; FAST.Farm preserves its established FarmCD root.
      IF (nT > 0) THEN
         native_root = TRIM(InitInp%RootName)
      ELSE
         native_root = TRIM(InitInp%RootName)//'.CD'
      END IF
      CALL WrScr( '  Parsing CableDyn input file: '//TRIM(InitInp%FileName) )
      IF (nT > 0) THEN
         ! an allocated-but-empty/too-small PtfmInit means "no initial displacement"
         ! (the single-turbine path above treats that case as absent); the aggregate
         ! requires a PRESENT farm array to be exactly (6, n_turbines), so gate the
         ! pass-through on shape and omit the optional otherwise
         farm_has_ptfm = .FALSE.
         IF (ALLOCATED(InitInp%PtfmInit)) THEN
            farm_has_ptfm = SIZE(InitInp%PtfmInit, 1) >= 6 .AND. SIZE(InitInp%PtfmInit, 2) >= nT
         END IF
         ! forbid_deck_ambient: farm scope is STILL WATER (see the use_extf guard above),
         ! and that must hold against the deck too -- a deck-declared waves/current OPTION
         ! would silently self-drive ambient forcing the documented scope excludes.
         IF (farm_has_ptfm) THEN
            CALL CD_AGG_Init_From_Deck( Inst(id)%agg, TRIM(InitInp%FileName), dt_moor, es, em, &
                                        env_gravity=REAL(InitInp%g, wp), env_rho_water=REAL(InitInp%rhoW, wp), &
                                        env_wtrdpth=REAL(InitInp%WtrDepth, wp), external_fluid=use_extf, &
                                        n_turbines=nT, &
                                        turbine_ref_pos=REAL(InitInp%TurbineRefPos, wp), &
                                        farm_ptfm_init=REAL(InitInp%PtfmInit(1:6, 1:nT), wp), &
                                        forbid_deck_ambient=.TRUE., run_tmax=REAL(InitInp%Tmax, wp), &
                                        host_orientation=.TRUE. )
         ELSE
            CALL CD_AGG_Init_From_Deck( Inst(id)%agg, TRIM(InitInp%FileName), dt_moor, es, em, &
                                        env_gravity=REAL(InitInp%g, wp), env_rho_water=REAL(InitInp%rhoW, wp), &
                                        env_wtrdpth=REAL(InitInp%WtrDepth, wp), external_fluid=use_extf, &
                                        n_turbines=nT, &
                                        turbine_ref_pos=REAL(InitInp%TurbineRefPos, wp), &
                                        forbid_deck_ambient=.TRUE., run_tmax=REAL(InitInp%Tmax, wp), &
                                        host_orientation=.TRUE. )
         END IF
      ELSE
         ! the static start in the host's steady current (seastate_static_current)
         IF (use_extf) THEN
            CALL seastate_static_current( InitInp%WaveField, static_cur, ErrStat2, ErrMsg2 )
            CALL SetErrStat( ErrStat2, ErrMsg2, ErrStat, ErrMsg, RoutineName )
            IF (ErrStat >= AbortErrLev) RETURN
            IF (InitInp%WaveField%Current_InitInput%CurrMod /= 0_IntKi .AND. &
                InitInp%WaveField%Current_InitInput%CurrMod /= 1_IntKi .OR. InitInp%WaveField%hasCurrField) &
               CALL WrScr( '   Note: CableDyn starts from its still-water statics: of the SeaState currents only '// &
                           'CurrMod 1 enters the static start; this current acts from t = 0.' )
         END IF
         CALL CD_AGG_Init_From_Deck( Inst(id)%agg, TRIM(InitInp%FileName), dt_moor, es, em, &
                                     env_gravity=REAL(InitInp%g, wp), env_rho_water=REAL(InitInp%rhoW, wp), &
                                     env_wtrdpth=REAL(InitInp%WtrDepth, wp), ptfm_init=REAL(ptfm6, wp), &
                                     external_fluid=use_extf, run_tmax=REAL(InitInp%Tmax, wp), &
                                     host_orientation=.TRUE., static_current=static_cur, range_files=.TRUE., &
                                     range_discard_root=TRIM(native_root) )
      END IF
      IF (es /= CD_AGG_OK) THEN
         ! The slot stays inactive (it is activated only after full success, below), so this and
         ! every other early-return error path leaves it reusable by the next new_instance() --
         ! no explicit per-path release needed.
         CALL SetErrStat( ErrID_Fatal, 'CableDyn mooring module: '//TRIM(em), ErrStat, ErrMsg, RoutineName )
         RETURN
      END IF
      ! Rigid6 bodies and rods carry their own degrees of freedom, which are not linearization
      ! states (the states are the line and cable DOFs): the linearization would hold them
      ! where they are and omit their compliance. Fail closed until body-state linearization
      ! exists.
      IF (InitInp%Linearize .AND. (CD_AGG_HasRigid6( Inst(id)%agg ) .OR. CD_AGG_HasRod( Inst(id)%agg ))) THEN
         CALL SetErrStat( ErrID_Fatal, 'CableDyn mooring module: formal OpenFAST linearization '// &
                          'with Rigid6 bodies or RODs is not supported; their states are not '// &
                          'linearization states (linearize a deck without BODIES/RODS).', &
                          ErrStat, ErrMsg, RoutineName )
         RETURN
      END IF
      ! A Point3 buoy steps as a Free point with its own state, which is not a linearization
      ! state either.
      IF (InitInp%Linearize .AND. CD_AGG_HasPoint3( Inst(id)%agg )) THEN
         CALL SetErrStat( ErrID_Fatal, 'CableDyn mooring module: formal OpenFAST linearization '// &
                          'with Point3 buoys is not supported; their states are not linearization '// &
                          'states.', ErrStat, ErrMsg, RoutineName )
         RETURN
      END IF
      ! A Free/Connect point steps with its own state through the implicit point-line coupling;
      ! the linearization states are the line and cable DOFs only, so the point would be held
      ! where it is and its compliance omitted.
      ! A line with VIV oscillates about a lock-in limit cycle, not about an equilibrium, and its
      ! shedding phase and running mean squares are not linearization states either.
      IF (InitInp%Linearize) THEN
         DO il = 1, Inst(id)%nlines
            IF (CD_System_Line_VIV_MirrorSize( Inst(id)%agg%sys%fast%system, il ) > 0) THEN
               CALL SetErrStat( ErrID_Fatal, 'CableDyn mooring module: formal OpenFAST linearization '// &
                                'of a line with VIV (LINE TYPES Cl > 0) is not supported; set Cl = 0 to '// &
                                'linearize.', ErrStat, ErrMsg, RoutineName )
               RETURN
            END IF
         END DO
         DO ic = 1, Inst(id)%agg%ncable
            IF (Inst(id)%agg%cables(ic)%line%has_viv) THEN
               CALL SetErrStat( ErrID_Fatal, 'CableDyn mooring module: formal OpenFAST linearization '// &
                                'of a cable with VIV (LINE TYPES Cl > 0) is not supported; set Cl = 0 to '// &
                                'linearize.', ErrStat, ErrMsg, RoutineName )
               RETURN
            END IF
         END DO
      END IF
      IF (InitInp%Linearize .AND. CD_AGG_NDynamicPoints( Inst(id)%agg ) > 0) THEN
         CALL SetErrStat( ErrID_Fatal, 'CableDyn mooring module: formal OpenFAST linearization '// &
                          'with Free or Connect points is not supported; their states are not '// &
                          'linearization states (attach the lines to Fixed or Coupled points to '// &
                          'linearize).', ErrStat, ErrMsg, RoutineName )
         RETURN
      END IF
      IF (InitInp%Linearize .AND. Inst(id)%agg%ncable > 0) THEN
         DO ic = 1, Inst(id)%agg%ncable
            ! a rigid end connection holds the end tangent on the parent's direction, so only
            ! its axial part is a degree of freedom, which the global-component states cannot
            ! carry
            IF (ANY(Inst(id)%agg%cables(ic)%line%endconn_mode == CD_ENDCONN_RIGID)) THEN
               CALL SetErrStat( ErrID_Fatal, 'CableDyn mooring module: formal OpenFAST linearization '// &
                                'of a cable with a rigid end connection is not supported (use a '// &
                                'finite rotational stiffness in END CONNECTIONS to linearize).', &
                                ErrStat, ErrMsg, RoutineName )
               RETURN
            END IF
            ! (a line restrained in torsion linearises: its free twist angles and their rates
            ! are states, lin_state_map, and the coupled-point orientation of the input turns its
            ! End A frame; a condensed torsion's torque follows q and the frames, see lin_eval)
            ! a finite-EI line between two moving points has a second host-driven end, whose input
            ! column the linearization does not perturb yet
            IF (Inst(id)%agg%cables(ic)%moving_b) THEN
               CALL SetErrStat( ErrID_Fatal, 'CableDyn mooring module: formal OpenFAST linearization '// &
                                'of a finite-EI line with two moving ends is not supported (anchor its '// &
                                'End B on a Fixed point to linearize).', ErrStat, ErrMsg, RoutineName )
               RETURN
            END IF
         END DO
      END IF
      CALL CD_AGG_GetInitMetadata( Inst(id)%agg, nreportlines, npoints, nsections, nei0, nfinite, es, em )
      IF (es /= CD_AGG_OK) THEN
         CALL SetErrStat( ErrID_Fatal, 'CableDyn mooring module: '//TRIM(em), ErrStat, ErrMsg, RoutineName )
         RETURN
      END IF
      Inst(id)%nsuper = nsuper
      Inst(id)%dt_moor = dt_moor
      Inst(id)%use_extfluid = use_extf
      IF (nsuper > 1_IntKi) THEN
         IF (Inst(id)%agg%predict_loads) THEN
            CALL WrScr( '   CableDyn: between dtM solves the coupled loads are extrapolated from the last two '// &
                        'solves (OPTIONS predictLoads); the output channels and the .CD.out record the committed '// &
                        'samples. Verify dtM convergence for fatigue, snap, contact, or local cable-response '// &
                        'calculations; omit dtM or set it to DT for glue-rate solves.' )
         ELSE
            CALL WrScr( '   CableDyn: coupled loads are held between dtM solves (OPTIONS predictLoads False) and '// &
                        'reach the platform about dtM/2 late, which matters for stiff (taut or tension-leg) '// &
                        'moorings and for tension statistics; the separate .CD.out records committed CableDyn '// &
                        'samples only. Verify dtM convergence for fatigue, snap, contact, or local cable-response '// &
                        'calculations; omit dtM or set it to DT for glue-rate solves.' )
         END IF
      END IF
      ! The static profile records the converged static equilibrium, the state the
      ! initialization summary reports, so it is written before the SeaState kinematics
      ! are seeded below: they act from t = 0 and enter the t = 0 output row only.
      CALL CD_AGG_WriteStaticProfile( Inst(id)%agg, TRIM(native_root)//'.static.out', es, em )
      IF (es /= CD_AGG_OK) THEN
         CALL SetErrStat( ErrID_Fatal, 'CableDyn mooring module: '//TRIM(em), ErrStat, ErrMsg, RoutineName )
         RETURN
      END IF
      IF (use_extf) THEN
         ! the WaveField pointer + sampling workspaces (sized once; no per-step allocation)
         p%WaveField => InitInp%WaveField
         Inst(id)%nfluid = CD_AGG_NFluidNodes( Inst(id)%agg, es, em )
         IF (es /= CD_AGG_OK) THEN
            CALL SetErrStat( ErrID_Fatal, 'CableDyn mooring module: '//TRIM(em), ErrStat, ErrMsg, RoutineName )
            RETURN
         END IF
         ALLOCATE (Inst(id)%fx_xyz(3, Inst(id)%nfluid), Inst(id)%fx_vel(3, Inst(id)%nfluid), &
                   Inst(id)%fx_acc(3, Inst(id)%nfluid), Inst(id)%fx_wl(Inst(id)%nfluid), &
                   Inst(id)%fx_pd(Inst(id)%nfluid), STAT=ErrStat2)
         IF (ErrStat2 /= 0) THEN
            CALL SetErrStat( ErrID_Fatal, 'Could not allocate the ambient-fluid sampling workspace.', &
                             ErrStat, ErrMsg, RoutineName )
            RETURN
         END IF
         ! Say what the lines take, as the deck's WaterKin policy decides it (sample_wavefield): an
         ! explicit WaterKin file may take no SeaState component (WaveKinMod 0, CurrentMod 0), and its
         ! CurrentMod 1 table gives the current itself.
         host_seastate = Inst(id)%agg%host_wave_enabled .OR. Inst(id)%agg%host_current_enabled
         host_table = ALLOCATED(Inst(id)%agg%host_current_profile_z)
         IF (Inst(id)%agg%host_wave_enabled .AND. Inst(id)%agg%host_current_enabled) THEN
            host_kin = 'wave/current'
         ELSE IF (Inst(id)%agg%host_wave_enabled) THEN
            host_kin = 'wave'
         ELSE
            host_kin = 'current'
         END IF
         IF (host_seastate .AND. host_table) THEN
            CALL WrScr( '   CableDyn: SeaState '//TRIM(host_kin)//' kinematics drive the mooring hydro ('// &
                        TRIM(Num2LStr(Inst(id)%nfluid))//' sampling nodes, refreshed every mooring step); '// &
                        'the WaterKin current table gives the current.' )
         ELSE IF (host_seastate) THEN
            CALL WrScr( '   CableDyn: SeaState '//TRIM(host_kin)//' kinematics drive the mooring hydro ('// &
                        TRIM(Num2LStr(Inst(id)%nfluid))//' sampling nodes, refreshed every mooring step).' )
         ELSE IF (host_table) THEN
            CALL WrScr( '   CableDyn: the WaterKin current table gives the mooring lines their current; '// &
                        'no SeaState kinematics are sampled (WaterKin WaveKinMod 0).' )
         ELSE
            CALL WrScr( '   CableDyn: the WaterKin file takes no SeaState waves or current (WaveKinMod 0, '// &
                        'CurrentMod 0): the mooring lines are in still water.' )
         END IF
         ! Seed the held fields at t = 0 (the static-IC positions): with supercycling
         ! (nsuper > 1) the first mooring advance happens only at the END of the first
         ! interval, and every CalcOutput before it would otherwise serve loads from the
         ! wave-capable-at-ZERO-fields build -- a still-water start under a declared sea
         ! state. Seeding after the static solve matches the stock-MoorDyn convention:
         ! the IC is the still-water equilibrium, wave kinematics act from t = 0.
         CALL sample_wavefield( Inst(id), p, m, 0.0_DbKi, ErrStat2, ErrMsg2, at_init=.TRUE. )
         IF (ErrStat2 < AbortErrLev) CALL save_held_fluid( Inst(id), other )
         CALL SetErrStat( ErrStat2, ErrMsg2, ErrStat, ErrMsg, RoutineName )
         IF (ErrStat >= AbortErrLev) RETURN
         CALL note_seastate_deep_interval( Inst(id), InitInp%WaveField )
      END IF

      ! The coupling mesh carries ONLY the host-prescribed (Coupled/Vessel) points.
      ! Fixed anchors stay inside the solver's boundary set, held at their initial
      ! positions -- they must never receive platform motion or return loads to it.
      ncp = CD_AGG_NMovingPoints( Inst(id)%agg, es, em )
      IF (es /= CD_AGG_OK) THEN
         CALL SetErrStat( ErrID_Fatal, 'CableDyn mooring module: '//TRIM(em), ErrStat, ErrMsg, RoutineName ); RETURN
      END IF
      IF (Inst(id)%agg%has_sys) THEN
         nlines = CD_System_NLines( Inst(id)%agg%sys%fast%system, es, em )
         IF (es /= CD_SYSTEM_OK) THEN
            CALL SetErrStat( ErrID_Fatal, 'CableDyn mooring module: '//TRIM(em), ErrStat, ErrMsg, RoutineName ); RETURN
         END IF
      ELSE
         nlines = 0                          ! pure finite-EI-cable deck: no EI=0 mooring system
      END IF
      IF (ncp < 1) THEN
         CALL SetErrStat( ErrID_Fatal, 'CableDyn mooring module: the deck declares no Coupled/Vessel '// &
                          'points; a mooring module needs at least one coupled fairlead.', &
                          ErrStat, ErrMsg, RoutineName )
         RETURN
      END IF
      Inst(id)%ncp    = ncp
      Inst(id)%nlines = nlines

      ! ------------------------------------------------------------------------------
      ! Parameters (glue-visible bookkeeping only; the physics lives in the instance)
      ! ------------------------------------------------------------------------------
      p%RootName    = TRIM(InitInp%RootName)//'.CD'
      ! The MooringFile folder: checkpoint restart and linearization write their temporary
      ! deck copy there, so deck-relative side files resolve as in the original run.
      CALL GetPath( InitInp%FileName, p%PriPath )
      ! 0 for a single turbine, FarmSize under FAST.Farm (the checkpoint rebuild guard).
      p%nTurbines   = nT
      p%nLines      = nlines
      p%NumOuts     = 0
      p%g           = InitInp%g
      p%rhoW        = InitInp%rhoW
      p%WtrDpth     = InitInp%WtrDepth
      p%dtM0        = REAL(dt_moor, DbKi)
      p%dtCoupling  = REAL(DTcoupling, DbKi)
      p%PtfmInit    = REAL(ptfm6, ReKi)   ! the rebuild reapplies the displaced-start geometry
      p%Tmax        = InitInp%Tmax
      p%Linearize   = InitInp%Linearize
      ! DTcoupling itself is deliberately left untouched (SubSteps = 1 in MV_AddModule).
      ! The module provides no visualization meshes: say so when the glue asks for them
      ! (WrVTK > 0) instead of leaving the mooring silently absent from the VTK output.
      IF (InitInp%VisMeshes) CALL WrScr( '   CableDyn: visualization meshes are not provided; the mooring '// &
                                         'lines and points are not written to the VTK output.' )

      ! ------------------------------------------------------------------------------
      ! Input/output meshes: one point mesh over the coupled points (all six motion
      ! fields), plus the Force/Moment sibling for the returned loads.
      ! ------------------------------------------------------------------------------
      ALLOCATE (pos(3, ncp), vel(3, ncp), acc(3, ncp), fld(3, ncp), STAT=ErrStat2)
      IF (ErrStat2 /= 0) THEN
         CALL SetErrStat( ErrID_Fatal, 'Could not allocate coupled-point work arrays.', ErrStat, ErrMsg, RoutineName )
         RETURN
      END IF
      CALL CD_AGG_GetMovingPointMesh( Inst(id)%agg, pos, vel, acc, fld, es, em )
      IF (es /= CD_AGG_OK) THEN
         CALL SetErrStat( ErrID_Fatal, 'CableDyn mooring module: '//TRIM(em), ErrStat, ErrMsg, RoutineName ); RETURN
      END IF
      ! Pre-allocate the instance's persistent marching workspace here (ncp is final): the
      ! supercycled CalcOutput path reads state through these WITHOUT a mesh_to_arrays call,
      ! so they must exist before the first marching call, not grow on first use.
      ALLOCATE (Inst(id)%ws_pos(3, ncp), Inst(id)%ws_vel(3, ncp), Inst(id)%ws_acc(3, ncp), &
                Inst(id)%ws_fld(3, ncp), Inst(id)%ws_moment(3, ncp), Inst(id)%ws_orient(3, 3, ncp), &
                Inst(id)%ws_omega(3, ncp), Inst(id)%ws_alpha(3, ncp), &
                Inst(id)%sv_pos(3, ncp), Inst(id)%sv_vel(3, ncp), Inst(id)%sv_acc(3, ncp), &
                Inst(id)%sv_orient(3, 3, ncp), Inst(id)%sv_omega(3, ncp), Inst(id)%sv_alpha(3, ncp), STAT=ErrStat2)
      IF (ErrStat2 /= 0) THEN
         CALL SetErrStat( ErrID_Fatal, 'Could not allocate the marching workspace.', ErrStat, ErrMsg, RoutineName )
         RETURN
      END IF
      IF (nT > 0) THEN
         ! FAST.Farm: one mesh pair per turbine over the flat aggregate moving surface;
         ! deck coupled coordinates are TURBINE-LOCAL (mesh reference positions), the
         ! per-turbine PtfmInit is carried in TranslationDisp, and the farm-layout
         ! reference offset is applied at the transfer boundary (MoorDyn's
         ! Position + TranslationDisp + TurbineRefPos convention).
         CALL build_farm_meshes( Inst(id), u, y, InitInp, nT, ncp, pos, ErrStat2, ErrMsg2 )
         CALL SetErrStat( ErrStat2, ErrMsg2, ErrStat, ErrMsg, RoutineName )
         IF (ErrStat >= AbortErrLev) RETURN
      ELSE

      ALLOCATE (u%CoupledKinematics(1), y%CoupledLoads(1), STAT=ErrStat2)
      IF (ErrStat2 /= 0) THEN
         CALL SetErrStat( ErrID_Fatal, 'Could not allocate mesh containers.', ErrStat, ErrMsg, RoutineName )
         RETURN
      END IF

      CALL MeshCreate( BlankMesh=u%CoupledKinematics(1), IOS=COMPONENT_INPUT, Nnodes=ncp, &
                       TranslationDisp=.TRUE., Orientation=.TRUE., TranslationVel=.TRUE., &
                       RotationVel=.TRUE., TranslationAcc=.TRUE., RotationAcc=.TRUE., &
                       ErrStat=ErrStat2, ErrMess=ErrMsg2 )
      CALL SetErrStat( ErrStat2, ErrMsg2, ErrStat, ErrMsg, RoutineName )
      IF (ErrStat >= AbortErrLev) RETURN

      ! Mesh reference positions are the UNDISPLACED deck coordinates (the motion
      ! mapping anchors its lever arms on Position); the aggregate returns the coupled
      ! points at the DISPLACED, statics-solved pose, so with PtfmInit active the
      ! reference is recovered by the exact inverse rigid transform
      ! rRef = M (p - r) (p = r + M^T rRef), and the initial displacement p - rRef is
      ! carried in TranslationDisp -- MoorDyn-F's convention.
      IF (has_ptfm) THEN
         OrMatInit = EulerConstructZYX( ptfm6(4:6) )
      END IF
      CALL Eye( OrientIdent, ErrStat2, ErrMsg2 )
      DO i = 1, ncp
         IF (has_ptfm) THEN
            refpos = MATMUL( OrMatInit, REAL(pos(:, i), R8Ki) - ptfm6(1:3) )
         ELSE
            refpos = REAL(pos(:, i), R8Ki)
         END IF
         CALL MeshPositionNode( u%CoupledKinematics(1), i, REAL(refpos, ReKi), ErrStat2, ErrMsg2, &
                                Orient=OrientIdent )
         CALL SetErrStat( ErrStat2, ErrMsg2, ErrStat, ErrMsg, RoutineName )
         CALL MeshConstructElement( u%CoupledKinematics(1), ELEMENT_POINT, ErrStat2, ErrMsg2, i )
         CALL SetErrStat( ErrStat2, ErrMsg2, ErrStat, ErrMsg, RoutineName )
      END DO
      CALL MeshCommit( u%CoupledKinematics(1), ErrStat2, ErrMsg2 )
      CALL SetErrStat( ErrStat2, ErrMsg2, ErrStat, ErrMsg, RoutineName )
      IF (ErrStat >= AbortErrLev) RETURN

      u%CoupledKinematics(1)%TranslationDisp = 0.0_ReKi
      u%CoupledKinematics(1)%TranslationVel  = 0.0_ReKi
      u%CoupledKinematics(1)%RotationVel     = 0.0_ReKi
      u%CoupledKinematics(1)%TranslationAcc  = 0.0_ReKi
      u%CoupledKinematics(1)%RotationAcc     = 0.0_ReKi
      IF (has_ptfm) THEN
         DO i = 1, ncp
            u%CoupledKinematics(1)%TranslationDisp(:, i) = REAL(pos(:, i), ReKi) &
               - u%CoupledKinematics(1)%Position(:, i)
            u%CoupledKinematics(1)%Orientation(:, :, i) = REAL(OrMatInit, ReKi)
         END DO
      END IF

      ! Active line control (CONTROL section): allocate the per-channel command
      ! inputs (zero = no control, bit-identical to an uncontrolled deck) and tell
      ! the glue which channels a line actually requested (CableCChanRqst drives
      ! the ServoDyn cable-control hookup, the MoorDyn convention).
      IF (CD_AGG_NCtrlChans( Inst(id)%agg ) > 0) THEN
         BLOCK
            INTEGER(IntKi) :: nchc, jc
            nchc = CD_AGG_NCtrlChans( Inst(id)%agg )
            ALLOCATE (u%DeltaL(nchc), u%DeltaLdot(nchc), InitOut%CableCChanRqst(nchc), STAT=ErrStat2)
            IF (ErrStat2 /= 0) THEN
               CALL SetErrStat( ErrID_Fatal, 'Could not allocate the line-control channel inputs.', &
                                ErrStat, ErrMsg, RoutineName ); RETURN
            END IF
            IF (InitInp%Linearize) THEN
               CALL SetErrStat( ErrID_Fatal, 'CableDyn mooring module: linearization with a CONTROL '// &
                                'section is not supported (the DeltaL input variables are not '// &
                                'registered); linearize an uncontrolled deck.', ErrStat, ErrMsg, RoutineName )
               RETURN
            END IF
            u%DeltaL = 0.0_ReKi
            u%DeltaLdot = 0.0_ReKi
            InitOut%CableCChanRqst = .FALSE.
            DO jc = 1, SIZE(Inst(id)%agg%ctrl_chan)
               InitOut%CableCChanRqst(Inst(id)%agg%ctrl_chan(jc)) = .TRUE.
            END DO
         END BLOCK
      END IF

      CALL MeshCopy( SrcMesh=u%CoupledKinematics(1), DestMesh=y%CoupledLoads(1), CtrlCode=MESH_SIBLING, &
                     IOS=COMPONENT_OUTPUT, Force=.TRUE., Moment=.TRUE., ErrStat=ErrStat2, ErrMess=ErrMsg2 )
      CALL SetErrStat( ErrStat2, ErrMsg2, ErrStat, ErrMsg, RoutineName )
      IF (ErrStat >= AbortErrLev) RETURN
      y%CoupledLoads(1)%Force  = 0.0_ReKi
      y%CoupledLoads(1)%Moment = 0.0_ReKi

      END IF   ! nT == 0 (plain single-turbine mesh path, bit-for-bit)

      ! ------------------------------------------------------------------------------
      ! Framework states: the MoorDyn-layout mirror (interior-node velocities then
      ! positions per line) + trivial xd/z/other.
      ! ------------------------------------------------------------------------------
      ALLOCATE (m%LineStateIs1(nlines), m%LineStateIsN(nlines), STAT=ErrStat2)
      IF (ErrStat2 /= 0) THEN
         CALL SetErrStat( ErrID_Fatal, 'Could not allocate line-state index arrays.', ErrStat, ErrMsg, RoutineName )
         RETURN
      END IF
      ! Coupled Rigid6 bodies are marched by the aggregate (CD_AGG_Step_Moving); their 6-DOF body
      ! state (pose/rates, CD_AGG_Rigid6_MirrorSize reals) is carried in the x%states checkpoint
      ! mirror below -- appended after the finite-EI cable block, following the same pattern. The body
      ! drives its attachment Free points, so restoring the 6-DOF state on restart makes the points
      ! consistent (they are re-derived from the restored pose on the next advance).
      nstates = 0
      DO il = 1, nlines
         ndofl = CD_System_Line_NDOF( Inst(id)%agg%sys%fast%system, il, es, em )
         IF (es /= CD_SYSTEM_OK) THEN
            CALL SetErrStat( ErrID_Fatal, 'CableDyn mooring module: '//TRIM(em), ErrStat, ErrMsg, RoutineName ); RETURN
         END IF
         m%LineStateIs1(il) = nstates + 1
         nstates = nstates + 3*(ndofl - 6)          ! interior nodes only: [rd, r, rdd]
         ! a viscoelastic line appends its per-element dl_1 history (the series-Kelvin internal
         ! strain a restart cannot re-derive from q/v) after the interior block; this
         ! stays inside the line's LineStateIs1..IsN span (see pack_state_mirror)
         IF (CD_System_Line_Has_Viscoelastic( Inst(id)%agg%sys%fast%system, il )) THEN
            nstates = nstates + CD_System_Line_NElem( Inst(id)%agg%sys%fast%system, il, es, em )
            IF (es /= CD_SYSTEM_OK) THEN
               CALL SetErrStat( ErrID_Fatal, 'CableDyn mooring module: '//TRIM(em), ErrStat, ErrMsg, RoutineName )
               RETURN
            END IF
         END IF
         ! a Syrope line appends TWO per-element blocks after the interior: the
         ! slow-spring static strain then the running-maximum tension (neither
         ! re-derivable from q/v). A line is viscoelastic OR Syrope, never both.
         IF (CD_System_Line_Has_Syrope( Inst(id)%agg%sys%fast%system, il )) THEN
            nstates = nstates + 2*CD_System_Line_NElem( Inst(id)%agg%sys%fast%system, il, es, em )
            IF (es /= CD_SYSTEM_OK) THEN
               CALL SetErrStat( ErrID_Fatal, 'CableDyn mooring module: '//TRIM(em), ErrStat, ErrMsg, RoutineName )
               RETURN
            END IF
         END IF
         ! a line with cross-flow VIV ends its span with the VIV state (the shedding phase and
         ! the two running mean squares per node, then the averaging time)
         nstates = nstates + CD_System_Line_VIV_MirrorSize( Inst(id)%agg%sys%fast%system, il )
         m%LineStateIsN(il) = nstates
      END DO
      ! finite-EI cables append their free-DOF [v_free; q_free; a_free] mirror after the mooring block
      DO ic = 1, Inst(id)%agg%ncable
         nstates = nstates + CD_HFMF_MirrorSize( Inst(id)%agg%cables(ic) )
      END DO
      ! coupled Rigid6 bodies append their 6-DOF body-state mirror after the cable block (0 if none)
      nstates = nstates + CD_AGG_Rigid6_MirrorSize( Inst(id)%agg )
      ! coupled rigid rods append the equivalent committed rigid-state mirror.
      nstates = nstates + CD_AGG_Rod_MirrorSize( Inst(id)%agg )
      ! EI=0 mooring lines on a frictional seabed append their stick-slip friction anchors,
      ! (x, y) per node, line by line (committed state a restart cannot re-derive)
      nstates = nstates + line_friction_mirror_size( Inst(id) )
      ! dynamic (Free/Connect) points append TWO trailing blocks: the compact
      ! coupled-motion vector [q; v; a] and the per-point [v; q; a] store.
      !
      ! INVARIANT (why one triple per shared point suffices): "two line ends bound to
      ! one point with different committed endpoint accelerations" is not a reachable
      ! committed state -- the dynamic-point step writes exactly one value per point
      ! into every bound endpoint each advance, and gather_mapped_motion FAILS CLOSED
      ! (1e-10) if any bound ends ever disagree. The same gather runs inside every
      ! normal step, so a state violating the invariant cannot even advance, let alone
      ! be packed. The vector's real payload is the COMMITTED boundary kinematics: the
      ! vessel-end kinematics the last advance committed differ in the last bits from the
      ! glue's input at that time (the advance used an extrapolated one), and on a point
      ! deck that round-off is amplified through the
      ! explicit-point window. A finite-EI cable carries its committed boundary in its own
      ! mirror block (CD_HFMF_BoundaryMirrorSize).
      IF (Inst(id)%agg%has_sys) THEN
         ! the committed boundary kinematics [q; v; a] of the EI=0 lines' coupled endpoints:
         ! the rebuild moves them to the committed input, then reloads them from here
         nstates = nstates + 3*CD_System_NSystemCoupledDOF( Inst(id)%agg%sys%fast%system )
      END IF
      IF (CD_AGG_NDynamicPoints( Inst(id)%agg ) > 0 .AND. Inst(id)%agg%has_sys) THEN
         nstates = nstates + 9*CD_AGG_NDynamicPoints( Inst(id)%agg )
         ! FAILURE rows: one fired flag per row at the mirror tail (0/1). A failure
         ! deck always carries dynamic points (its reserves are Free points), so this
         ! block lives inside the dynamic-point mirror gate.
         nstates = nstates + CD_AGG_NFailures( Inst(id)%agg )
      END IF
      m%Nx    = nstates
      m%Nxtra = nstates
      ALLOCATE (x%states(MAX(nstates, 1)), STAT=ErrStat2)
      IF (ErrStat2 /= 0) THEN
         CALL SetErrStat( ErrID_Fatal, 'Could not allocate the state mirror.', ErrStat, ErrMsg, RoutineName )
         RETURN
      END IF
      x%states = 0.0_DbKi
      CALL pack_state_mirror( Inst(id), m, x, ErrStat2, ErrMsg2 )
      CALL SetErrStat( ErrStat2, ErrMsg2, ErrStat, ErrMsg, RoutineName )
      IF (ErrStat >= AbortErrLev) RETURN

      xd%dummy    = 0.0_SiKi
      z%dummy     = 0.0_SiKi
      IF (g_serial == 0_IntKi) THEN
         ! first mint in this process: salt from the wall clock so a fresh process can
         ! never reproduce another process's serials (a -restart process would otherwise
         ! mint the same small integers the checkpointed run saved)
         CALL SYSTEM_CLOCK( COUNT=clock_count )
         g_serial = INT(MOD(ABS(clock_count), 8388608_IntKi), IntKi)*128_IntKi
      END IF
      g_serial = g_serial + 1_IntKi
      Inst(id)%serial = g_serial
      Inst(id)%t_commit = 0.0_DbKi          ! committed at the static IC (t = 0)
      Inst(id)%t_commit_prev = 0.0_DbKi
      Inst(id)%t_run_end = 0.0_DbKi
      other%restart_serial = g_serial
      other%t_commit = Inst(id)%t_commit
      other%pred_t = -1.0_DbKi   ! no previous commit yet (load predictor)
      ! what the state at t = 0 stands on, for a checkpoint written before the first commit
      CALL CD_AGG_GetMovingPointMesh( Inst(id)%agg, Inst(id)%sv_pos, Inst(id)%sv_vel, Inst(id)%sv_acc, &
                                      Inst(id)%ws_fld, es, em, orientation=Inst(id)%sv_orient, &
                                      angular_velocity=Inst(id)%sv_omega, angular_acceleration=Inst(id)%sv_alpha, &
                                      cable_loads=.FALSE. )
      IF (es /= CD_AGG_OK) THEN
         CALL SetErrStat( ErrID_Fatal, 'CableDyn mooring module: '//TRIM(em), ErrStat, ErrMsg, RoutineName ); RETURN
      END IF
      CALL save_commit_input( Inst(id), other, Inst(id)%sv_pos, Inst(id)%sv_vel, Inst(id)%sv_acc, &
                              Inst(id)%sv_orient, Inst(id)%sv_omega, Inst(id)%sv_alpha, u )

      ! ------------------------------------------------------------------------------
      ! Output channels: the deck OUTPUTS list in the OrcaFlex vocabulary, emitted through
      ! the OpenFAST WriteOutput surface (per-line tensions, curvature, fairlead angle, ...).
      ! The channels were validated when the aggregate was built (parse_deck routes each
      ! OUTPUTS token through check_channel against the deck lines/points and rejects an
      ! unknown token or an out-of-range line node with a named fatal). Here we size the
      ! framework arrays, label every channel with its header token + OrcaFlex unit, and
      ! evaluate each once at the static equilibrium -- which also confirms the whole eval
      ! path resolves (a channel the parser admits but the eval cannot serve, e.g. a Point
      ! channel with no mooring system, fails closed HERE rather than at the first output
      ! step). A deck with no OUTPUTS gives nch = 0, size-zero arrays, and behaviour
      ! byte-identical to the pre-channel module (p%NumOuts = 0, no CableDyn columns).
      ! ------------------------------------------------------------------------------
      nch = CD_AGG_NumChannels( Inst(id)%agg )
      p%NumOuts = nch
      ALLOCATE (y%WriteOutput(nch), InitOut%WriteOutputHdr(nch), InitOut%WriteOutputUnt(nch), &
                Inst(id)%ws_chan(nch), STAT=ErrStat2)
      IF (ErrStat2 /= 0) THEN
         CALL SetErrStat( ErrID_Fatal, 'Could not allocate the output channel arrays.', &
                          ErrStat, ErrMsg, RoutineName )
         RETURN
      END IF
      DO ic = 1, nch
         CALL CD_AGG_ChannelHeader( Inst(id)%agg, ic, chan_hdr, chan_unt, es, em )
         IF (es /= CD_AGG_OK) THEN
            CALL SetErrStat( ErrID_Fatal, 'CableDyn mooring module: '//TRIM(em), ErrStat, ErrMsg, RoutineName ); RETURN
         END IF
         InitOut%WriteOutputHdr(ic) = chan_hdr
         InitOut%WriteOutputUnt(ic) = chan_unt
         CALL CD_AGG_EvalChannel( Inst(id)%agg, ic, cval, es, em )
         IF (es /= CD_AGG_OK) THEN
            CALL SetErrStat( ErrID_Fatal, 'CableDyn mooring module: output channel "'//TRIM(chan_hdr)// &
                             '" could not be evaluated at the static equilibrium: '//TRIM(em), &
                             ErrStat, ErrMsg, RoutineName ); RETURN
         END IF
         y%WriteOutput(ic) = REAL(cval, ReKi)
      END DO

      CALL CD_InitVars( InitOut%Vars, u, p, x, y, m, Inst(id), InitInp%Linearize, ErrStat2, ErrMsg2 )
      CALL SetErrStat( ErrStat2, ErrMsg2, ErrStat, ErrMsg, RoutineName )
      IF (ErrStat >= AbortErrLev) RETURN
      IF (InitInp%Linearize) THEN
         CALL lin_state_map( Inst(id), m, ErrStat2, ErrMsg2 )
         CALL SetErrStat( ErrStat2, ErrMsg2, ErrStat, ErrMsg, RoutineName )
         IF (ErrStat >= AbortErrLev) RETURN
      END IF

      ! The time history contains the selected deck channels and is therefore opened only
      ! when nch > 0. The static profile, unconditional and covering every line node
      ! regardless of OUTPUTS selection, was written at the equilibrium above.
      CALL open_native_outputs( id, TRIM(native_root), 0.0_DbKi, ErrStat2, ErrMsg2, write_profile=.FALSE. )
      CALL SetErrStat( ErrStat2, ErrMsg2, ErrStat, ErrMsg, RoutineName )
      IF (ErrStat >= AbortErrLev) RETURN

      ! Range graphs (LINES flag r): the first sample is the state of the t = 0 output row. The
      ! files of an earlier run went when the deck was parsed: this run writes its own only when
      ! it completes.
      Inst(id)%range_on = CD_AGG_Range_Graphs( Inst(id)%agg )
      IF (Inst(id)%range_on) THEN
         CALL sample_range( Inst(id), other, 0.0_DbKi, ErrStat2, ErrMsg2 )
         CALL SetErrStat( ErrStat2, ErrMsg2, ErrStat, ErrMsg, RoutineName )
         IF (ErrStat >= AbortErrLev) RETURN
      END IF

      IF (profile_requested) THEN
         CALL SYSTEM_CLOCK(prof_c1)
         CALL reset_instance_profile( id, .TRUE., &
                                      REAL(prof_c1 - prof_c0, wp)/REAL(prof_rate, wp), .TRUE. )
         CALL WrScr( '    CableDyn profiler armed by CABLEDYN_PROFILE.' )
      ELSE
         CALL reset_instance_profile( id, .FALSE., 0.0_wp, .TRUE. )
      END IF

      CALL WrScr( '   Created CableDyn model: '//TRIM(Num2LStr(nreportlines))//' line object(s), '// &
                  TRIM(Num2LStr(npoints))//' point(s), '//TRIM(Num2LStr(nsections))//' section(s) [EI=0: '// &
                  TRIM(Num2LStr(nei0))//', finite-EI: '//TRIM(Num2LStr(nfinite))//'].' )
      CALL WrScr( '   Initial conditions: Newton static equilibrium with load continuation completed.' )
      IF (use_extf .AND. host_seastate) THEN
         ! The equilibrium is solved at zero SeaState fields and the SeaState kinematics act
         ! from t = 0, so the t = 0 outputs below differ from these equilibrium values by
         ! the hydrodynamic load of the t = 0 kinematics on the line end nodes (none when the
         ! WaterKin policy takes no SeaState component).
         CALL WrScr( '   Line results below are at this equilibrium; SeaState kinematics act from t = 0.' )
      END IF
      CALL WrScr( '   Fairlead convention: force is on End A toward End B; inclinations are signed below horizontal.' )
      DO il = 1, nreportlines
         CALL CD_AGG_GetInitLine( Inst(id)%agg, il, line_id, fair_ten, fair_force, fair_incl, fair_decl, &
                                  fair_azi, es, em, note=init_note )
         IF (es /= CD_AGG_OK) THEN
            CALL SetErrStat( ErrID_Fatal, 'CableDyn mooring module: '//TRIM(em), ErrStat, ErrMsg, RoutineName )
            RETURN
         END IF
         CALL WrScr( '   Line '//TRIM(Num2LStr(line_id))//' fairlead effective tension: '// &
                     TRIM(Num2LStr(REAL(fair_ten, DbKi)))//' N' )
         ! The force carries the end node's share of the line load (and, finite-EI, the end
         ! shear), so its angle differs slightly from the line tangent's: both are printed.
         force_incl = ATAN2(-fair_force(3), NORM2(fair_force(1:2)))*REAL(R2D_D, wp)
         CALL WrScr( '      force [Fx, Fy, Fz]: ['//TRIM(Num2LStr(REAL(fair_force(1), DbKi)))//', '// &
                     TRIM(Num2LStr(REAL(fair_force(2), DbKi)))//', '// &
                     TRIM(Num2LStr(REAL(fair_force(3), DbKi)))//'] N, inclination='// &
                     TRIM(Num2LStr(REAL(force_incl, DbKi)))//' deg' )
         CALL WrScr( '      line tangent: inclination='//TRIM(Num2LStr(REAL(fair_incl, DbKi)))// &
                     ' deg, declination='//TRIM(Num2LStr(REAL(fair_decl, DbKi)))// &
                     ' deg, azimuth='//TRIM(Num2LStr(REAL(fair_azi, DbKi)))//' deg' )
         ! The line's static-initialisation notes (a folded EI = 0 layout, the notes of a
         ! finite-EI cable), one per text line, as the standalone driver prints them.
         note_at = 1
         DO WHILE (LEN_TRIM(init_note(note_at:)) > 0)
            note_end = INDEX(init_note(note_at:), NEW_LINE('a'))
            IF (note_end == 0) THEN
               CALL WrScr( '   Note: '//TRIM(init_note(note_at:))//'.' )
               EXIT
            END IF
            CALL WrScr( '   Note: '//init_note(note_at:note_at + note_end - 2)//'.' )
            note_at = note_at + note_end
         END DO
      END DO
      CALL WrScr( '  CableDyn initialization completed.' )

      ! Initialization fully succeeded: bind the handle and activate the slot together. Until this
      ! point the slot was reserved but inactive, so any early-return error path above (including a
      ! failed report query) leaves it reusable rather than leaking a half-built active instance.
      ! Crucially m%CDInst is also left at its INTENT(OUT) default (0) on those failure paths, so a
      ! later init can reuse this slot without a failed module record aliasing the new instance id.
      m%CDInst        = id
      Inst(id)%active = .TRUE.

      ! In a single-turbine OpenFAST run, expose the converged t = 0 result immediately.
      ! These are the same values already placed in y%WriteOutput for the first host
      ! output row; printing them here makes a direct executable smoke test useful even
      ! before the user opens the OpenFAST .out/.outb file. FAST.Farm is excluded to
      ! avoid repeating a potentially long channel list for every turbine instance; its
      ! static row is written to <RootName>.FarmCD.out above.
      IF (nT == 0) THEN
         IF (nch > 0) THEN
            IF (use_extf) THEN
               CALL WrScr( '    Requested CableDyn OUTPUTS at t = 0 s (equilibrium pose, SeaState kinematics '// &
                           'at t = 0):' )
            ELSE
               CALL WrScr( '    Requested CableDyn OUTPUTS at t = 0 s (static equilibrium):' )
            END IF
            DO ic = 1, nch
               CALL WrScr( '      '//TRIM(InitOut%WriteOutputHdr(ic))//' = '// &
                           TRIM(Num2LStr(REAL(y%WriteOutput(ic), DbKi)))//' '// &
                           TRIM(InitOut%WriteOutputUnt(ic)) )
            END DO
            CALL WrScr( '    These values are also the t = 0 CableDyn columns in the OpenFAST output file.' )
         ELSE
            CALL WrScr( '    CableDyn: no deck OUTPUTS requested; no CableDyn result columns will be written.' )
         END IF
      END IF

   END SUBROUTINE CD_Init

!----------------------------------------------------------------------------------------------------------------------------------
   LOGICAL FUNCTION instance_matches( m, other ) RESULT(ok)
      !! TRUE iff m%CDInst refers to a live instance whose identity matches the
      !! (possibly checkpoint-restored) OtherState: same generation stamp AND a
      !! committed clock no further ahead than the restored one. A fresh process fails
      !! the stamp; a same-process rewind fails the clock; both route to
      !! rebuild_from_checkpoint.
      TYPE(CD_MiscVarType),    INTENT(IN) :: m
      TYPE(CD_OtherStateType), INTENT(IN) :: other
      ok = .FALSE.
      IF (.NOT. ALLOCATED(Inst)) RETURN
      IF (m%CDInst < 1 .OR. m%CDInst > SIZE(Inst)) RETURN
      IF (.NOT. Inst(m%CDInst)%active) RETURN
      IF (Inst(m%CDInst)%serial /= other%restart_serial) RETURN
      ! EQUALITY, not merely not-ahead: a fresh instance (t_commit = 0) must never be
      ! mistaken for a checkpointed one, even if the process-local serial collides.
      IF (ABS(Inst(m%CDInst)%t_commit - other%t_commit) > 1.0E-9_DbKi*MAX(1.0_DbKi, ABS(other%t_commit))) RETURN
      ok = .TRUE.
   END FUNCTION instance_matches

   LOGICAL FUNCTION step_retry( m, other, n ) RESULT(retry)
      !! TRUE when the glue runs the mooring step n again: the solver's correction loop copies
      !! the states of the step's start back over the predicted ones before each pass, so the
      !! OtherState then stands at the commit that step started from, while the instance has
      !! advanced from it. The aggregate's step-start snapshot rewinds that exactly, at any
      !! dtM/DT; the time of the retried call lies inside the mooring interval, not on a commit.
      TYPE(CD_MiscVarType),    INTENT(IN) :: m
      TYPE(CD_OtherStateType), INTENT(IN) :: other
      INTEGER(IntKi),          INTENT(IN) :: n
      retry = .FALSE.
      IF (.NOT. ALLOCATED(Inst)) RETURN
      IF (m%CDInst < 1 .OR. m%CDInst > SIZE(Inst)) RETURN
      IF (.NOT. Inst(m%CDInst)%active) RETURN
      IF (Inst(m%CDInst)%serial /= other%restart_serial) RETURN
      IF (n /= Inst(m%CDInst)%last_n .OR. n /= Inst(m%CDInst)%last_solve_n) RETURN
      retry = ABS(Inst(m%CDInst)%t_commit_prev - other%t_commit) <= 1.0E-9_DbKi*MAX(1.0_DbKi, ABS(other%t_commit))
   END FUNCTION step_retry

   SUBROUTINE rebuild_from_checkpoint( t, u1, p, x, other, m, ErrStat, ErrMsg )
      !! CHECKPOINT-RESTART: rebuild the module's internal solver instance from the
      !! registry-packed data alone -- the deck copy in p, the state mirror in x, the
      !! coupled mesh in u -- exactly the data an `openfast -restart` run unpacks. The
      !! deck is re-parsed and the static build re-run (structure, meshes, hydro
      !! configuration), then the committed dynamic state is overlaid: coupled endpoint
      !! kinematics and line-control command as the last commit was reached with them
      !! (other%commit_input), line interiors from the mirror (the EI=0 mirror is
      !! MoorDyn-layout [rd; r; rdd]), and each cable's [v; q; a] free-DOF mirror, all at the
      !! clock of that commit. The restart time t can lie anywhere in the mooring step that
      !! follows the commit: between commits nothing of the solver moves, and the input of the
      !! coming solve is the glue's, so a run restarted there goes on as the uninterrupted one.
      REAL(DbKi),                   INTENT(IN   ) :: t
      TYPE(CD_InputType),           INTENT(IN   ) :: u1
      TYPE(CD_ParameterType),       INTENT(IN   ) :: p
      TYPE(CD_ContinuousStateType), INTENT(IN   ) :: x
      TYPE(CD_OtherStateType),      INTENT(IN   ) :: other
      TYPE(CD_MiscVarType),         INTENT(INOUT) :: m
      INTEGER(IntKi),               INTENT(  OUT) :: ErrStat
      CHARACTER(*),                 INTENT(  OUT) :: ErrMsg

      character(*), parameter   :: RoutineName = 'CableDyn:rebuild_from_checkpoint'
      CHARACTER(2100)           :: rst_deck
      INTEGER(IntKi)            :: id, old_id, stale_id, i, es, ncp, nlines, il, ndofl, nin, k, ic, csz, koff
      LOGICAL                   :: use_extf, profile_requested, preserve_profile, same_run
      REAL(wp), ALLOCATABLE     :: static_cur(:,:)   ! the host's steady current for the static start
      LOGICAL                   :: restored   ! held fluid fields restored from the checkpoint
      CHARACTER(ErrMsgLen)            :: em
      INTEGER(IntKi)            :: ErrStat2
      CHARACTER(ErrMsgLen)      :: ErrMsg2

      ErrStat = ErrID_None
      ErrMsg  = ''
      IF (p%nTurbines > 0_IntKi) THEN
         ! FAST.Farm restart follows FAST.Farm's own checkpoint protocol, which CableDyn does not implement.
         CALL SetErrStat( ErrID_Fatal, 'CableDyn mooring module: checkpoint restart in FAST.Farm '// &
                          'mode is not supported.', ErrStat, ErrMsg, RoutineName )
         RETURN
      END IF
      IF (p%DeckCopy%NumLines < 1) THEN
         CALL SetErrStat( ErrID_Fatal, 'CableDyn mooring module: checkpoint rebuild requested but the '// &
                          'parameters carry no deck copy.', ErrStat, ErrMsg, RoutineName )
         RETURN
      END IF

      ! The state of a run at t is its last commit, at most one mooring step back: a restored
      ! time and commit further apart are not a state of this run. Fail closed.
      IF (t < other%t_commit - 1.0E-6_DbKi*MAX(1.0_DbKi, ABS(other%t_commit)) .OR. &
          t > other%t_commit + p%dtM0 - p%dtCoupling + 1.0E-6_DbKi*MAX(1.0_DbKi, ABS(other%t_commit))) THEN
         CALL SetErrStat( ErrID_Fatal, 'CableDyn mooring module: the restored state at t = '// &
                          TRIM(Num2LStr(t))//' s has its last commit at '//TRIM(Num2LStr(other%t_commit))// &
                          ' s, outside the mooring step dtM = '//TRIM(Num2LStr(p%dtM0))//' s before it.', &
                          ErrStat, ErrMsg, RoutineName )
         RETURN
      END IF

      ! the deck copy back to disk (the parser's input boundary is a file), in the
      ! MooringFile folder so deck-relative side files resolve as in the original run
      CALL write_deck_copy( p, '.rst.dat', rst_deck, ErrStat2, ErrMsg2 )
      CALL SetErrStat( ErrStat2, ErrMsg2, ErrStat, ErrMsg, RoutineName )
      IF (ErrStat >= AbortErrLev) RETURN

      ! Profiling is opt-in per host run, while the Hermite profiler is process-global.
      ! A same-process rewind should retain its accumulated diagnostics. A fresh
      ! restart (or a host that removed CABLEDYN_PROFILE between sequential cases)
      ! must explicitly arm/reset or disarm the global timer before rebuilding.
      old_id = m%CDInst
      profile_requested = profile_environment_requested()
      preserve_profile = .FALSE.
      IF (ALLOCATED(Inst)) THEN
         IF (old_id >= 1_IntKi .AND. old_id <= SIZE(Inst)) THEN
            IF (Inst(old_id)%active) THEN
               preserve_profile = Inst(old_id)%prof_enabled .AND. profile_requested .AND. &
                                  Inst(old_id)%serial == other%restart_serial
            END IF
         END IF
      END IF
      id = new_instance()
      IF (preserve_profile) THEN
         CALL copy_instance_profile( id, old_id )
      ELSE
         CALL reset_instance_profile( id, profile_requested, 0.0_wp, .TRUE. )
      END IF
      use_extf = .FALSE.
      IF (ASSOCIATED(p%WaveField)) use_extf = wavefield_is_ambient( p%WaveField )
      ! the rebuild solves the same static start as the run it continues (the restored state
      ! then replaces it; a static-shape-driven mesh refinement must match)
      IF (use_extf) THEN
         CALL seastate_static_current( p%WaveField, static_cur, ErrStat2, ErrMsg2 )
         CALL SetErrStat( ErrStat2, ErrMsg2, ErrStat, ErrMsg, RoutineName )
         IF (ErrStat >= AbortErrLev) RETURN
      END IF
      CALL CD_AGG_Init_From_Deck( Inst(id)%agg, TRIM(rst_deck), REAL(p%dtM0, wp), es, em, &
                                  env_gravity=REAL(p%g, wp), env_rho_water=REAL(p%rhoW, wp), &
                                  env_wtrdpth=REAL(p%WtrDpth, wp), external_fluid=use_extf, &
                                  ptfm_init=REAL(p%PtfmInit, wp), run_tmax=REAL(p%Tmax, wp), &
                                  host_orientation=.TRUE., static_current=static_cur, range_files=.TRUE. )
      CALL delete_file( rst_deck )
      IF (es /= CD_AGG_OK) THEN
         CALL SetErrStat( ErrID_Fatal, 'CableDyn mooring module: checkpoint rebuild: '//TRIM(em), &
                          ErrStat, ErrMsg, RoutineName )
         RETURN
      END IF

      ! structural consistency with the restored registry data (a different deck or a
      ! corrupted checkpoint must fail closed, not silently mis-map states)
      ncp = CD_AGG_NMovingPoints( Inst(id)%agg, es, em )
      IF (es /= CD_AGG_OK .OR. ncp /= u1%CoupledKinematics(1)%Nnodes) THEN
         CALL SetErrStat( ErrID_Fatal, 'CableDyn mooring module: checkpoint rebuild: the rebuilt deck '// &
                          'has a different coupled-point count than the restored mesh.', ErrStat, ErrMsg, RoutineName )
         RETURN
      END IF
      IF (Inst(id)%agg%has_sys) THEN
         nlines = CD_System_NLines( Inst(id)%agg%sys%fast%system, es, em )
      ELSE
         nlines = 0
      END IF
      IF (nlines /= p%nLines) THEN
         CALL SetErrStat( ErrID_Fatal, 'CableDyn mooring module: checkpoint rebuild: the rebuilt deck '// &
                          'has a different line count than the restored parameters.', ErrStat, ErrMsg, RoutineName )
         RETURN
      END IF
      ! Dynamic (Free/Connect) point states ride two trailing mirror blocks: the compact
      ! coupled-motion vector (the committed endpoint/boundary kinematics -- the vessel
      ! ends' committed accelerations differ at round-off from the glue's input at that
      ! time, which a point deck amplifies) and the per-point store. A deck whose layout
      ! changed since the checkpoint fails closed on the mirror-extent checks.

      Inst(id)%ncp    = ncp
      Inst(id)%nlines = nlines
      Inst(id)%nsuper = MAX(1_IntKi, NINT(p%dtM0/p%dtCoupling, IntKi))
      Inst(id)%dt_moor = REAL(p%dtM0, wp)
      ALLOCATE (Inst(id)%ws_pos(3, ncp), Inst(id)%ws_vel(3, ncp), Inst(id)%ws_acc(3, ncp), &
                Inst(id)%ws_fld(3, ncp), Inst(id)%ws_moment(3, ncp), Inst(id)%ws_orient(3, 3, ncp), &
                Inst(id)%ws_omega(3, ncp), Inst(id)%ws_alpha(3, ncp), &
                Inst(id)%sv_pos(3, ncp), Inst(id)%sv_vel(3, ncp), Inst(id)%sv_acc(3, ncp), &
                Inst(id)%sv_orient(3, 3, ncp), Inst(id)%sv_omega(3, ncp), Inst(id)%sv_alpha(3, ncp), STAT=ErrStat2)
      IF (ErrStat2 /= 0) THEN
         CALL SetErrStat( ErrID_Fatal, 'Could not allocate the marching workspace (rebuild).', &
                          ErrStat, ErrMsg, RoutineName )
         RETURN
      END IF
      Inst(id)%use_extfluid = use_extf
      IF (use_extf) THEN
         Inst(id)%nfluid = CD_AGG_NFluidNodes( Inst(id)%agg, es, em )
         ALLOCATE (Inst(id)%fx_xyz(3, Inst(id)%nfluid), Inst(id)%fx_vel(3, Inst(id)%nfluid), &
                   Inst(id)%fx_acc(3, Inst(id)%nfluid), Inst(id)%fx_wl(Inst(id)%nfluid), &
                   Inst(id)%fx_pd(Inst(id)%nfluid), STAT=ErrStat2)
         IF (ErrStat2 /= 0) THEN
            CALL SetErrStat( ErrID_Fatal, 'Could not allocate the ambient-fluid workspace (rebuild).', &
                             ErrStat, ErrMsg, RoutineName )
            RETURN
         END IF
      END IF
      ! the WriteOutput channel buffer (CalcOutput evaluates the deck channels into it
      ! every reporting step; Init sizes it from the aggregate's channel count)
      IF (CD_AGG_NumChannels(Inst(id)%agg) > 0) THEN
         ALLOCATE (Inst(id)%ws_chan(CD_AGG_NumChannels(Inst(id)%agg)), STAT=ErrStat2)
         IF (ErrStat2 /= 0) THEN
            CALL SetErrStat( ErrID_Fatal, 'Could not allocate the channel workspace (rebuild).', &
                             ErrStat, ErrMsg, RoutineName )
            RETURN
         END IF
      END IF

      ! overlay the committed dynamic state: coupled endpoints as the last commit took them...
      CALL restore_commit_kinematics( Inst(id), other, ErrStat2, ErrMsg2 )
      CALL SetErrStat( ErrStat2, ErrMsg2, ErrStat, ErrMsg, RoutineName )
      IF (ErrStat >= AbortErrLev) RETURN
      ! a cable restrained in torsion first takes its committed state: moving its fairlead
      ! frame from the static pose to the restart pose is bounded (pi/2) against the twist
      ! it had at the checkpoint, not at t = 0
      CALL reload_cable_mirrors( Inst(id), m, x%states, REAL(other%t_commit, wp), .TRUE., koff, ErrStat2, ErrMsg2 )
      CALL SetErrStat( ErrStat2, ErrMsg2, ErrStat, ErrMsg, RoutineName )
      IF (ErrStat >= AbortErrLev) RETURN
      CALL CD_AGG_UpdateStates_Moving( Inst(id)%agg, Inst(id)%ws_pos, Inst(id)%ws_vel, Inst(id)%ws_acc, es, em, &
                                       orientation=Inst(id)%ws_orient, angular_velocity=Inst(id)%ws_omega, &
                                       angular_acceleration=Inst(id)%ws_alpha )
      IF (es /= CD_AGG_OK) THEN
         CALL SetErrStat( ErrID_Fatal, 'CableDyn mooring module: checkpoint rebuild: '//TRIM(em), &
                          ErrStat, ErrMsg, RoutineName )
         RETURN
      END IF
      ! Active line control: the rebuild re-initialized at the BASE segment lengths;
      ! apply the restored command HERE, on the rebuild transition itself, so every
      ! entry that can trigger a rebuild (UpdateStates -- including its supercycle
      ! early-return substeps -- and CalcOutput) resumes at the checkpointed lengths.
      ! The restored command is the one the committed state was reached with, so the
      ! lengths are re-applied as committed (the next advance blends them into its
      ! generalised-alpha terms exactly as the uninterrupted run does). It runs before the
      ! line interiors and cable mirrors reload below, which bring back the committed state
      ! of the uninterrupted run, a cable's committed force included.
      IF (ALLOCATED(u1%DeltaL)) THEN
         k = 24_IntKi*ncp
         ic = SIZE(u1%DeltaL)
         IF (SIZE(other%commit_input) /= k + 2_IntKi*ic) THEN
            CALL SetErrStat( ErrID_Fatal, 'CableDyn mooring module: checkpoint rebuild: the committed '// &
                             'line-control command does not match the control channels.', &
                             ErrStat, ErrMsg, RoutineName )
            RETURN
         END IF
         CALL CD_AGG_Apply_LineControl( Inst(id)%agg, REAL(other%commit_input(k + 1:k + ic), wp), &
                                        REAL(other%commit_input(k + ic + 1:k + 2_IntKi*ic), wp), es, em, &
                                        restored=.TRUE. )
         IF (es /= CD_AGG_OK) THEN
            CALL SetErrStat( ErrID_Fatal, 'CableDyn mooring module: line-control apply after the '// &
                             'checkpoint rebuild failed: '//TRIM(em), ErrStat, ErrMsg, RoutineName )
            RETURN
         END IF
      END IF
      ! ...line interiors + cable free-DOF mirrors, exactly (committed accelerations
      ! reload from the mirror -- shared helper with the state-const CalcOutput)
      CALL reload_interiors_ary( Inst(id), m, x%states, REAL(other%t_commit, wp), ErrStat2, ErrMsg2 )
      CALL SetErrStat( ErrStat2, ErrMsg2, ErrStat, ErrMsg, RoutineName )
      IF (ErrStat >= AbortErrLev) RETURN

      ! restore the ambient-fluid fields the reference's committed state carried. The last
      ! pre-checkpoint solve sampled the WaveField at ITS interval end (= the last commit) at
      ! the node positions of its START, and held them: the checkpoint carries them, and with
      ! supercycling they act on the loads served until the next solve. Init saves the first
      ! fields, so a checkpoint of an instance that takes host fluid always carries them;
      ! re-sampling at the restored, end-of-step positions remains only as a defensive
      ! fallback (it matches only at dtM = DT, where the next solve re-samples before any load
      ! is served). Without either the first post-restart load evaluations would see still
      ! water and ring for a few steps. (OpenFAST checkpoints are not versioned: one written by
      ! an earlier CableDyn, without these fields, cannot be restarted with this one.)
      Inst(id)%active = .TRUE.       ! sample_wavefield reads through the live instance
      IF (use_extf) THEN
         CALL restore_held_fluid( Inst(id), other, restored, ErrStat2, ErrMsg2 )
         IF (ErrStat2 < AbortErrLev .AND. .NOT. restored) &
            CALL sample_wavefield( Inst(id), p, m, other%t_commit, ErrStat2, ErrMsg2 )
         CALL SetErrStat( ErrStat2, ErrMsg2, ErrStat, ErrMsg, RoutineName )
         IF (ErrStat >= AbortErrLev) THEN
            CALL release_instance( id )
            RETURN
         END IF
      END IF
      ! A restart inside the first mooring step: no commit yet, so the bodies and rods are still
      ! at their start, and the fluid fields of the first step re-solve their accelerations. At
      ! dtM = DT there is no such state: the CalcOutput at t = 0 restores the mirror, which
      ! closes the start.
      IF (Inst(id)%nsuper > 1_IntKi .AND. other%t_commit <= 0.0_DbKi) CALL CD_AGG_Reopen_Start( Inst(id)%agg )
      ! The same run restoring one of its own states (CalcSteady's operating points) keeps what
      ! it has committed, the range samples too, until it steps on from there
      ! (resume_after_rewind). A checkpoint in a new process continues from the restored
      ! OtherState, which holds the range graphs through other%t_commit.
      same_run = .FALSE.
      IF (old_id >= 1_IntKi .AND. old_id <= SIZE(Inst) .AND. old_id /= id) &
         same_run = Inst(old_id)%active .AND. Inst(old_id)%serial == other%restart_serial
      Inst(id)%t_run_end = other%t_commit
      IF (same_run) THEN
         Inst(id)%t_run_end = MAX(Inst(old_id)%t_run_end, other%t_commit)
         Inst(id)%rewound = Inst(id)%t_run_end > other%t_commit + 1.0E-9_DbKi*MAX(1.0_DbKi, ABS(other%t_commit))
      END IF
      Inst(id)%range_on = CD_AGG_Range_Graphs( Inst(id)%agg )
      IF (Inst(id)%range_on) THEN
         IF (same_run) THEN
            Inst(id)%range_sampled = Inst(old_id)%range_sampled
            ALLOCATE (Inst(id)%ws_range(CD_AGG_Range_MirrorSize( Inst(id)%agg )))
            CALL CD_AGG_Range_Get_State( Inst(old_id)%agg, Inst(id)%ws_range, es, em )
            IF (es == CD_AGG_OK) CALL CD_AGG_Range_Set_State( Inst(id)%agg, Inst(id)%ws_range, es, em )
            IF (es /= CD_AGG_OK) CALL SetErrStat( ErrID_Fatal, 'CableDyn mooring module: range graphs of the '// &
                                                  'restored run: '//TRIM(em), ErrStat, ErrMsg, RoutineName )
         ELSE
            CALL restore_range_state( Inst(id), other, ErrStat2, ErrMsg2 )
            CALL SetErrStat( ErrStat2, ErrMsg2, ErrStat, ErrMsg, RoutineName )
         END IF
         IF (ErrStat >= AbortErrLev) THEN
            CALL release_instance( id )
            RETURN
         END IF
      END IF
      ! A linearizing run keeps its state map: CalcSteady rewinds to the operating point through
      ! this rebuild, and a restart may linearize later.
      IF (p%Linearize) THEN
         CALL lin_state_map( Inst(id), m, ErrStat2, ErrMsg2 )
         CALL SetErrStat( ErrStat2, ErrMsg2, ErrStat, ErrMsg, RoutineName )
         IF (ErrStat >= AbortErrLev) THEN
            CALL release_instance( id )
            RETURN
         END IF
      END IF
      ! A fresh-process restart first passes through CD_Init, whose provisional instance
      ! owns the output stream of the same root; the checkpointed m%CDInst need not be
      ! that slot. Find it so its stream is released and the slot freed with old_id.
      stale_id = 0_IntKi
      DO k = 1, SIZE(Inst)
         IF (k == id .OR. k == old_id) CYCLE
         IF (Inst(k)%active .AND. Inst(k)%native_un > 0 .AND. &
             TRIM(Inst(k)%native_root) == TRIM(p%RootName)) THEN
            stale_id = k
            EXIT
         END IF
      END DO
      IF (stale_id > 0_IntKi) THEN
         CLOSE (Inst(stale_id)%native_un)
         Inst(stale_id)%native_un = -1_IntKi
         Inst(stale_id)%native_root = ''
      END IF
      ! A same-process replacement adopts the run-level stream from its predecessor, rows and
      ! all. A fresh-process restart has no live unit and starts a new result file at the
      ! checkpoint state, matching the normal OpenFAST restart-output policy.
      CALL restore_native_outputs( id, old_id, TRIM(p%RootName), other%t_commit, other%restart_serial, &
                                   ErrStat2, ErrMsg2 )
      CALL SetErrStat( ErrStat2, ErrMsg2, ErrStat, ErrMsg, RoutineName )
      IF (ErrStat >= AbortErrLev) THEN
         CALL release_instance( id )
         RETURN
      END IF
      ! The rebuilt instance supersedes the one the checkpoint replaced (and the provisional
      ! instance of a fresh process): release their aggregates and workspaces.
      IF (old_id >= 1_IntKi .AND. old_id <= SIZE(Inst) .AND. old_id /= id) CALL release_instance( old_id )
      IF (stale_id > 0_IntKi) CALL release_instance( stale_id )
      ! adopt the restored identity (the OtherState is authoritative across the restart)
      Inst(id)%serial = other%restart_serial
      Inst(id)%t_commit = other%t_commit
      Inst(id)%t_commit_prev = other%t_commit
      Inst(id)%last_n = -1_IntKi
      Inst(id)%last_solve_n = -1_IntKi
      Inst(id)%loads_cached = .FALSE.
      Inst(id)%restored_unserved = Inst(id)%nsuper > 1_IntKi
      ! the load predictor's previous commit (shift_predictor_loads)
      Inst(id)%pred_t = other%pred_t
      IF (Inst(id)%pred_t >= 0.0_DbKi) THEN
         IF (ALLOCATED(other%pred_loads)) THEN
            IF (SIZE(other%pred_loads) == 6*ncp) THEN
               Inst(id)%pred_fld = RESHAPE(REAL(other%pred_loads(1:3*ncp), wp), [3, ncp])
               Inst(id)%pred_mom = RESHAPE(REAL(other%pred_loads(3*ncp + 1:6*ncp), wp), [3, ncp])
            ELSE
               Inst(id)%pred_t = -1.0_DbKi
            END IF
         ELSE
            Inst(id)%pred_t = -1.0_DbKi
         END IF
      END IF
      m%CDInst = id
      CALL WrScr( '   CableDyn: rebuilt the solver instance from the checkpoint at t = '// &
                  TRIM(Num2LStr(t))//' s ('//TRIM(Num2LStr(ncp))//' coupled points, '// &
                  TRIM(Num2LStr(nlines))//' mooring lines, '// &
                  TRIM(Num2LStr(Inst(id)%agg%ncable))//' cables).' )
   END SUBROUTINE rebuild_from_checkpoint

   SUBROUTINE CD_UpdateStates( t, n, u, t_array, p, x, xd, z, other, m, ErrStat, ErrMsg)
      REAL(DbKi)                      , INTENT(IN   ) :: t
      INTEGER(IntKi)                  , INTENT(IN   ) :: n
      TYPE(CD_InputType)              , INTENT(INOUT) :: u(:)
      REAL(DbKi)                      , INTENT(IN   ) :: t_array(:)
      TYPE(CD_ParameterType)          , INTENT(INOUT) :: p
      TYPE(CD_ContinuousStateType)    , INTENT(INOUT) :: x
      TYPE(CD_DiscreteStateType)      , INTENT(INOUT) :: xd
      TYPE(CD_ConstraintStateType)    , INTENT(INOUT) :: z
      TYPE(CD_OtherStateType)         , INTENT(INOUT) :: other
      TYPE(CD_MiscVarType)            , INTENT(INOUT) :: m
      INTEGER(IntKi)                  , INTENT(  OUT) :: ErrStat
      CHARACTER(*)                    , INTENT(  OUT) :: ErrMsg

      character(*), parameter   :: RoutineName = 'CD_UpdateStates'
      INTEGER(IntKi)            :: ErrStat2, es, id, niter
      INTEGER(IntKi)            :: prof_c0, prof_c1, prof_rate, prof_phase0
      CHARACTER(ErrMsgLen)      :: ErrMsg2
      CHARACTER(ErrMsgLen)            :: em
      LOGICAL                   :: conv, stalled

      ErrStat = ErrID_None
      ErrMsg  = ''
      ! CHECKPOINT-RESTART: a restored OtherState that does not match the live instance
      ! (fresh process, or a same-process rewind) rebuilds the solver from p + x + other.
      IF (.NOT. (step_retry(m, other, n) .OR. instance_matches(m, other))) THEN
         CALL rebuild_from_checkpoint( t, u(1), p, x, other, m, ErrStat2, ErrMsg2 )
         CALL SetErrStat( ErrStat2, ErrMsg2, ErrStat, ErrMsg, RoutineName )
         IF (ErrStat >= AbortErrLev) RETURN
      END IF
      id = m%CDInst
      IF (Inst(id)%rewound) THEN
         CALL resume_after_rewind( Inst(id), other, ErrStat2, ErrMsg2 )
         CALL SetErrStat( ErrStat2, ErrMsg2, ErrStat, ErrMsg, RoutineName )
         IF (ErrStat >= AbortErrLev) RETURN
      END IF
      IF (Inst(id)%prof_enabled) THEN
         CALL SYSTEM_CLOCK(prof_c0, prof_rate)
         Inst(id)%prof_n_update = Inst(id)%prof_n_update + 1_IntKi
      END IF

      ! Correction iterations: the glue re-runs UpdateStates over the SAME interval with
      ! corrected inputs when its solver retries a step. A re-entry over a glue step where nothing
      ! was advanced (an intermediate supercycle call) is a no-op; a re-entry over a COMPLETED
      ! mooring step rewinds the aggregate to the snapshot taken at that step's start and
      ! falls through to re-advance with the corrected inputs -- exactly the
      ! copy-states-back semantics a registry-state module gets from the glue, expressed
      ! on the module's internal state. The glue's copy has taken the OtherState back with the
      ! states, so what the first pass mirrored there and does not repeat is mirrored again:
      ! the load predictor, shifted once per mooring step.
      IF (n == Inst(id)%last_n) THEN
         IF (Inst(id)%last_solve_n /= n) THEN
            IF (Inst(id)%prof_enabled) THEN
               CALL SYSTEM_CLOCK(prof_c1)
               Inst(id)%prof_t_update = Inst(id)%prof_t_update + &
                  REAL(prof_c1 - prof_c0, wp)/REAL(prof_rate, wp)
            END IF
            RETURN
         END IF
         CALL CD_AGG_Restore( Inst(id)%agg, es, em )
         IF (es /= CD_AGG_OK) THEN
            CALL SetErrStat( ErrID_Fatal, 'CableDyn mooring module: correction-iteration rewind failed: '// &
                             TRIM(em), ErrStat, ErrMsg, RoutineName )
            RETURN
         END IF
         Inst(id)%t_commit = Inst(id)%t_commit_prev
         other%t_commit = Inst(id)%t_commit
         CALL mirror_predictor_loads( Inst(id), other )
      END IF

      ! Supercycling (CableDyn's own dtM): the mooring interval [.., (n+1)*DT] completes only
      ! on every nsuper-th glue step; an intermediate call records the glue step and returns
      ! without an implicit solve. CD_CalcOutput serves the last committed load state between
      ! mooring solves.
      IF (MOD(n + 1_IntKi, Inst(id)%nsuper) /= 0_IntKi) THEN
         Inst(id)%last_n = n
         IF (Inst(id)%prof_enabled) THEN
            CALL SYSTEM_CLOCK(prof_c1)
            Inst(id)%prof_t_update = Inst(id)%prof_t_update + &
               REAL(prof_c1 - prof_c0, wp)/REAL(prof_rate, wp)
         END IF
         RETURN
      END IF

      ! Interpolate the input to the END of the coupling interval (= the end of the mooring
      ! interval on this stepping call): the implicit step prescribes the coupled-point
      ! kinematics at t + dt. The interpolation container is built ONCE (a full mesh copy)
      ! and reused for the rest of the run -- ExtrapInterp overwrites its fields in place --
      ! so the stepping path never creates/destroys a mesh.
      IF (.NOT. Inst(id)%u_interp_ready) THEN
         CALL CD_CopyInput( u(1), Inst(id)%u_interp, MESH_NEWCOPY, ErrStat2, ErrMsg2 )
         CALL SetErrStat( ErrStat2, ErrMsg2, ErrStat, ErrMsg, RoutineName )
         IF (ErrStat >= AbortErrLev) RETURN
         Inst(id)%u_interp_ready = .TRUE.
      END IF
      CALL CD_Input_ExtrapInterp( u, t_array, Inst(id)%u_interp, t + p%dtCoupling, ErrStat2, ErrMsg2 )
      CALL SetErrStat( ErrStat2, ErrMsg2, ErrStat, ErrMsg, RoutineName )
      IF (ErrStat < AbortErrLev) THEN

         IF (Inst(id)%nT > 0) THEN
            CALL farm_gather_kinematics( Inst(id), Inst(id)%u_interp, ErrStat2, ErrMsg2 )
         ELSE
            CALL mesh_to_arrays( Inst(id)%u_interp%CoupledKinematics(1), Inst(id)%ncp, Inst(id)%ws_pos, &
                                 Inst(id)%ws_vel, Inst(id)%ws_acc, Inst(id)%ws_orient, Inst(id)%ws_omega, &
                                 Inst(id)%ws_alpha, ErrStat2, ErrMsg2 )
         END IF
         CALL SetErrStat( ErrStat2, ErrMsg2, ErrStat, ErrMsg, RoutineName )
         IF (ErrStat < AbortErrLev) THEN
            IF (Inst(id)%restored_unserved) THEN
               CALL serve_committed_loads( Inst(id), ErrStat2, ErrMsg2 )
               CALL SetErrStat( ErrStat2, ErrMsg2, ErrStat, ErrMsg, RoutineName )
               IF (ErrStat >= AbortErrLev) RETURN
            END IF
            ! Load predictor: a new mooring step (not a correction re-entry over the same n)
            ! makes the loads served since the last commit the previous ones.
            IF (Inst(id)%nsuper > 1_IntKi .AND. Inst(id)%agg%predict_loads .AND. &
                Inst(id)%last_solve_n /= n) CALL shift_predictor_loads( Inst(id), other )
            ! Snapshot the step-start state before advancing: a later correction re-entry
            ! over this same n restores it and re-advances. Idempotent (buffers reused),
            ! and on the corrected re-advance it re-captures the SAME restored state.
            CALL CD_AGG_Snapshot( Inst(id)%agg, es, em )
            IF (es /= CD_AGG_OK) THEN
               CALL SetErrStat( ErrID_Fatal, 'CableDyn mooring module: step-start snapshot failed: '// &
                                TRIM(em), ErrStat, ErrMsg, RoutineName )
               RETURN
            END IF
            ! SeaState ambient fluid: sample the WaveField at the line nodes' committed
            ! positions, at the END of this mooring interval (where the implicit step
            ! prescribes the boundary), and hold the fields over the step. The advance
            ! runs on the LAST glue substep of the interval, so the interval end is
            ! t + p%dtCoupling -- the SAME time the coupled-kinematics interpolation
            ! above uses (t + dt_moor from here would sit almost a full mooring step in
            ! the future under supercycling, phase-shifting the wave kinematics).
            ! Runs AFTER the snapshot: a correction re-entry restores the step-start
            ! state and re-samples at the same committed positions.
            IF (Inst(id)%use_extfluid) THEN
               IF (Inst(id)%prof_enabled) CALL SYSTEM_CLOCK(prof_phase0)
               CALL sample_wavefield( Inst(id), p, m, t + p%dtCoupling, ErrStat2, ErrMsg2 )
               IF (ErrStat2 < AbortErrLev) CALL save_held_fluid( Inst(id), other )
               IF (Inst(id)%prof_enabled) THEN
                  CALL SYSTEM_CLOCK(prof_c1)
                  Inst(id)%prof_n_wave = Inst(id)%prof_n_wave + 1_IntKi
                  Inst(id)%prof_t_wave = Inst(id)%prof_t_wave + &
                     REAL(prof_c1 - prof_phase0, wp)/REAL(prof_rate, wp)
               END IF
               CALL SetErrStat( ErrStat2, ErrMsg2, ErrStat, ErrMsg, RoutineName )
               IF (ErrStat >= AbortErrLev) RETURN
            END IF
            ! Active line control: apply the interpolated DeltaL/DeltaLdot command to
            ! the controlled segments (EI=0 line segments and finite-EI cable spans)
            ! BEFORE the advance (the MoorDyn placement).
            ! Runs AFTER the snapshot so a correction re-entry restores the
            ! step-start lengths and re-applies the corrected command.
            IF (ALLOCATED(Inst(id)%u_interp%DeltaL)) THEN
               CALL CD_AGG_Apply_LineControl( Inst(id)%agg, REAL(Inst(id)%u_interp%DeltaL, wp), &
                                              REAL(Inst(id)%u_interp%DeltaLdot, wp), es, em )
               IF (es /= CD_AGG_OK) THEN
                  CALL SetErrStat( ErrID_Fatal, 'CableDyn mooring module: line-control apply failed: '// &
                                   TRIM(em), ErrStat, ErrMsg, RoutineName )
                  RETURN
               END IF
            END IF
            IF (Inst(id)%prof_enabled) CALL SYSTEM_CLOCK(prof_phase0)
            CALL CD_AGG_Step_Moving( Inst(id)%agg, Inst(id)%dt_moor, Inst(id)%ws_pos, Inst(id)%ws_vel, &
                                     Inst(id)%ws_acc, conv, stalled, niter, es, em, &
                                     t_committed=REAL(t + p%dtCoupling, wp), orientation=Inst(id)%ws_orient, &
                                     angular_velocity=Inst(id)%ws_omega, angular_acceleration=Inst(id)%ws_alpha )
            IF (Inst(id)%prof_enabled) THEN
               CALL SYSTEM_CLOCK(prof_c1)
               Inst(id)%prof_n_solve = Inst(id)%prof_n_solve + 1_IntKi
               Inst(id)%prof_t_step = Inst(id)%prof_t_step + &
                  REAL(prof_c1 - prof_phase0, wp)/REAL(prof_rate, wp)
            END IF
            IF (es /= CD_AGG_OK .OR. .NOT. conv) THEN
               CALL SetErrStat( ErrID_Fatal, 'CableDyn mooring module: implicit step did not converge at t = '// &
                                TRIM(Num2LStr(t))//' s: '//TRIM(em), ErrStat, ErrMsg, RoutineName )
            ELSE
               Inst(id)%last_n = n
               Inst(id)%last_solve_n = n
               ! The committed state changed: a served ZOH cache keyed on last_solve_n
               ! alone would go stale on a correction re-advance at the SAME n, so the
               ! cache is invalidated on every successful advance (bit-identical for the
               ! normal path -- last_solve_n moved anyway -- and correct for corrections).
               Inst(id)%loads_cached = .FALSE.
               Inst(id)%native_pending = Inst(id)%native_un > 0_IntKi
               ! commit the restart clock: the state now committed corresponds to the END
               ! of this mooring interval. The advance runs on the LAST glue substep, so
               ! the interval end is t + dtCoupling (t + dt_moor from here overshoots by
               ! dt_moor - DT under supercycling -- the same arithmetic as the WaveField
               ! sampling time).
               Inst(id)%t_commit_prev = Inst(id)%t_commit
               Inst(id)%t_commit = t + p%dtCoupling
               Inst(id)%t_run_end = Inst(id)%t_commit
               other%t_commit = Inst(id)%t_commit
               CALL save_commit_input( Inst(id), other, Inst(id)%ws_pos, Inst(id)%ws_vel, Inst(id)%ws_acc, &
                                       Inst(id)%ws_orient, Inst(id)%ws_omega, Inst(id)%ws_alpha, Inst(id)%u_interp )
               CALL pack_state_mirror( Inst(id), m, x, ErrStat2, ErrMsg2 )
               CALL SetErrStat( ErrStat2, ErrMsg2, ErrStat, ErrMsg, RoutineName )
               ! one range-graph sample per commit, here where the OtherState can carry it: a
               ! correction re-advance takes the sample back with the step (CD_AGG_Restore, or
               ! the glue's state copy and the rebuild), an intermediate supercycle call never
               ! gets here, and CalcOutput's probes of off-step inputs are not commits
               IF (Inst(id)%range_on .AND. ErrStat < AbortErrLev) THEN
                  CALL sample_range( Inst(id), other, Inst(id)%t_commit, ErrStat2, ErrMsg2 )
                  CALL SetErrStat( ErrStat2, ErrMsg2, ErrStat, ErrMsg, RoutineName )
               END IF
            END IF
         END IF

      END IF

      IF (Inst(id)%prof_enabled) THEN
         CALL SYSTEM_CLOCK(prof_c1)
         Inst(id)%prof_t_update = Inst(id)%prof_t_update + &
            REAL(prof_c1 - prof_c0, wp)/REAL(prof_rate, wp)
      END IF

   END SUBROUTINE CD_UpdateStates

!----------------------------------------------------------------------------------------------------------------------------------
   SUBROUTINE sample_wavefield( inst_e, p, m, t_sample, ErrStat, ErrMsg, at_init )
      !! Sample the SeaState WaveField at every mooring line node's committed position --
      !! fluid velocity (waves + current), fluid acceleration, and the local free-surface
      !! elevation -- and prescribe them to the aggregate for the coming advance. Nodes
      !! are forced in-water for kinematics (forceNodeInWater = .TRUE., the MoorDyn
      !! convention: the WETTING is decided by CableDyn's own waterline machinery from
      !! the sampled elevation, not by the sampler).
      TYPE(CD_OF_Instance),     INTENT(INOUT) :: inst_e
      TYPE(CD_ParameterType),   INTENT(IN   ) :: p
      TYPE(CD_MiscVarType),     INTENT(INOUT) :: m
      REAL(DbKi),               INTENT(IN   ) :: t_sample
      INTEGER(IntKi),           INTENT(  OUT) :: ErrStat
      CHARACTER(*),             INTENT(  OUT) :: ErrMsg
      LOGICAL, OPTIONAL,        INTENT(IN   ) :: at_init   !< the Init seeding call (see check_wavefield_grid)

      character(*), parameter   :: RoutineName = 'sample_wavefield'
      INTEGER(IntKi)            :: i, l, es, nodeInWater, n_current_nodes
      INTEGER(IntKi)            :: prof_c0, prof_c1, prof_rate
      LOGICAL                   :: init_call, timed
      REAL(SiKi)                :: zeta1, zeta2, zeta, pdyn, fv(3), fa(3), famcf(3)
      REAL(SiKi)                :: wave_zeta1, wave_zeta2, wave_zeta, wave_pdyn
      REAL(SiKi)                :: wave_fv(3), wave_fa(3), wave_famcf(3)
      REAL(wp)                  :: profile_fv(3), steady_fv_wp(3), grid_z
      REAL(SiKi)                :: steady_fv(3), grid_fv(3), grid_weight
      ! the SeaState free-surface elevation as sampled at each node (kept also when the host
      ! waves are off and fx_wl takes the still-water level): SeaState's Wheeler stretching
      ! interpolates the current at the depth mapped with it. Only the grid check reads it, so
      ! it exists only until that check has warned.
      REAL(wp), ALLOCATABLE     :: wl_sampled(:)
      CHARACTER(ErrMsgLen)      :: em
      INTEGER(IntKi)            :: ErrStat2
      CHARACTER(ErrMsgLen)      :: ErrMsg2

      ErrStat = ErrID_None
      ErrMsg  = ''
      init_call = .FALSE.
      IF (PRESENT(at_init)) init_call = at_init
      ! the parts of wave_s, timed like it outside the Init seeding call (a checkpoint restart
      ! re-sampling once is counted in the parts only)
      timed = inst_e%prof_enabled .AND. .NOT. init_call
      IF (.NOT. ASSOCIATED(p%WaveField)) THEN
         CALL SetErrStat( ErrID_Fatal, 'CableDyn mooring module: the WaveField pointer is null but '// &
                          'SeaState kinematics were requested at Init.', ErrStat, ErrMsg, RoutineName )
         RETURN
      END IF
      CALL CD_AGG_GetFluidNodePositions( inst_e%agg, inst_e%fx_xyz, es, em )
      IF (es /= CD_AGG_OK) THEN
         CALL SetErrStat( ErrID_Fatal, 'CableDyn mooring module: '//TRIM(em), ErrStat, ErrMsg, RoutineName )
         RETURN
      END IF
      ! SeaState measures its wave field and grid from the still-water level, and its node
      ! queries take SWL-relative positions; the mooring samples it at positions relative to the
      ! mean sea level, which coincide only for MSL2SWL = 0. Checked here, where the deck's
      ! WaterKin policy has decided whether SeaState is queried at all.
      IF ((inst_e%agg%host_wave_enabled .OR. inst_e%agg%host_current_enabled) .AND. &
          ABS(p%WaveField%MSL2SWL) > 0.0_ReKi) THEN
         CALL SetErrStat( ErrID_Fatal, 'CableDyn mooring module: SeaState MSL2SWL = '// &
                          TRIM(Num2LStr(p%WaveField%MSL2SWL))//' m is not supported with host waves or '// &
                          'current: the mooring samples SeaState at positions relative to the mean sea '// &
                          'level. Set MSL2SWL = 0, or take the waves and current from the deck (WaterKin).', &
                          ErrStat, ErrMsg, RoutineName )
         RETURN
      END IF
      IF ((inst_e%agg%host_wave_enabled .NEQV. inst_e%agg%host_current_enabled) .AND. &
          p%WaveField%Current_InitInput%CurrMod == 2_IntKi) THEN
         CALL SetErrStat( ErrID_Fatal, 'CableDyn mooring module: WaterKin requests separate host wave/current '// &
                          'modes, but SeaState CurrMod 2 is a private user current and cannot be decomposed.', &
                          ErrStat, ErrMsg, RoutineName )
         RETURN
      END IF
      IF (.NOT. inst_e%grid_warned) ALLOCATE (wl_sampled(inst_e%nfluid))
      IF (timed) CALL SYSTEM_CLOCK(prof_c0, prof_rate)
      DO i = 1, inst_e%nfluid
         IF (.NOT. inst_e%agg%host_wave_enabled .AND. .NOT. inst_e%agg%host_current_enabled) THEN
            ! An explicit WaterKin file may disable both host components even
            ! though the turbine owns a SeaState field. Do not sample it at all.
            fv = 0.0_SiKi
            fa = 0.0_SiKi
            zeta = 0.0_SiKi
            nodeInWater = 0_IntKi
         ELSE
            CALL WaveField_GetNodeWaveKin( p%WaveField, m%WaveField_m, t_sample, &
                                           REAL(inst_e%fx_xyz(:, i), ReKi), .TRUE., &
                                           inst_e%agg%host_current_enabled, nodeInWater, &
                                           zeta1, zeta2, zeta, pdyn, fv, fa, famcf, ErrStat2, ErrMsg2 )
            CALL SetErrStat( ErrStat2, ErrMsg2, ErrStat, ErrMsg, RoutineName )
            IF (ErrStat >= AbortErrLev) RETURN
         END IF
         IF (ALLOCATED(wl_sampled)) wl_sampled(i) = REAL(zeta, wp)
         steady_fv = 0.0_SiKi
         IF (nodeInWater /= 0_IntKi .AND. &
             (.NOT. inst_e%agg%host_wave_enabled .OR. .NOT. inst_e%agg%host_current_enabled)) THEN
            ! Reconstruct the current exactly where WaveField_GetNodeWaveKin
            ! samples it. For vertical/extrapolation stretching above SWL that
            ! is the single z=0 value. SeaState deliberately does NOT add
            ! PCurrV/Pz to PWaveVel0 (see Waves.f90), so the extrapolation term
            ! is wave-only and must not be subtracted as steady current here.
            ! Below SWL and for Wheeler stretching, retain the same four
            ! vertical grid nodes and interpolation weights as the sampler.
            n_current_nodes = 4
            IF (p%WaveField%WaveStMod < 3_IntKi .AND. inst_e%fx_xyz(3, i) > 0.0_wp) &
               n_current_nodes = 1
            DO l = 1, n_current_nodes
               IF (n_current_nodes == 1) THEN
                  grid_z = 0.0_wp
                  grid_weight = 1.0_SiKi
               ELSE
                  grid_z = REAL(p%WaveField%GridDepth, wp)* &
                           (SIN(REAL(p%WaveField%VolGridParams%pZero(4) + &
                                     m%WaveField_m%Indx(l, 4)*p%WaveField%VolGridParams%delta(4), wp)) - 1.0_wp)
                  grid_weight = SUM(m%WaveField_m%N4D(:, :, :, l))
               END IF
               CALL CD_SeaState_Steady_Current(grid_z, REAL(p%WaveField%EffWtrDpth, wp), &
                    INT(p%WaveField%Current_InitInput%CurrMod), &
                    REAL(p%WaveField%Current_InitInput%CurrSSV0, wp), &
                    REAL(p%WaveField%Current_InitInput%CurrSSDir, wp), &
                    REAL(p%WaveField%Current_InitInput%CurrNSRef, wp), &
                    REAL(p%WaveField%Current_InitInput%CurrNSV0, wp), &
                    REAL(p%WaveField%Current_InitInput%CurrNSDir, wp), &
                    REAL(p%WaveField%Current_InitInput%CurrDIV, wp), &
                    REAL(p%WaveField%Current_InitInput%CurrDIDir, wp), steady_fv_wp, es, em)
               IF (es /= CD_HYDRO_OK) THEN
                  CALL SetErrStat( ErrID_Fatal, 'CableDyn mooring module: SeaState current decomposition: '// &
                                   TRIM(em), ErrStat, ErrMsg, RoutineName )
                  RETURN
               END IF
               grid_fv = REAL(steady_fv_wp, SiKi)
               steady_fv = steady_fv + grid_weight*grid_fv
            END DO
         END IF
         IF (.NOT. inst_e%agg%host_wave_enabled .AND. inst_e%agg%host_current_enabled) THEN
            ! The second sample contains waves plus the built-in steady current;
            ! subtract both, then restore the analytically reconstructed steady
            ! current. The remainder from the first sample is dynamic current.
            CALL WaveField_GetNodeWaveKin( p%WaveField, m%WaveField_m, t_sample, &
                                           REAL(inst_e%fx_xyz(:, i), ReKi), .TRUE., .FALSE., nodeInWater, &
                                           wave_zeta1, wave_zeta2, wave_zeta, wave_pdyn, wave_fv, wave_fa, &
                                           wave_famcf, ErrStat2, ErrMsg2 )
            CALL SetErrStat( ErrStat2, ErrMsg2, ErrStat, ErrMsg, RoutineName )
            IF (ErrStat >= AbortErrLev) RETURN
            fv = fv - wave_fv + steady_fv
            fa = fa - wave_fa
            zeta = 0.0_SiKi
         ELSE IF (.NOT. inst_e%agg%host_current_enabled) THEN
            ! fetchDynCurrent does not gate SeaState's built-in steady current.
            fv = fv - steady_fv
         END IF
         IF (ALLOCATED(inst_e%agg%host_current_profile_z)) THEN
            CALL CD_Current_Profile_Velocity(REAL(inst_e%fx_xyz(3, i), wp), &
                                             inst_e%agg%host_current_profile_z, &
                                             inst_e%agg%host_current_profile_velocity, &
                                             profile_fv, es, em)
            IF (es /= CD_HYDRO_OK) THEN
               CALL SetErrStat( ErrID_Fatal, 'CableDyn mooring module: host-wave/file-current profile: '// &
                                TRIM(em), ErrStat, ErrMsg, RoutineName )
               RETURN
            END IF
            fv = fv + REAL(profile_fv, SiKi)
         END IF
         inst_e%fx_vel(:, i) = REAL(fv, wp)
         inst_e%fx_acc(:, i) = REAL(fa, wp)
         inst_e%fx_wl(i) = REAL(zeta, wp)
         ! the wave dynamic pressure (Pa) for the rod end caps: waves only, zero when the host
         ! wave component is disabled
         inst_e%fx_pd(i) = 0.0_wp
         IF (inst_e%agg%host_wave_enabled) inst_e%fx_pd(i) = REAL(pdyn, wp)
      END DO
      IF (timed) THEN
         CALL SYSTEM_CLOCK(prof_c1)
         inst_e%prof_t_wave_kin = inst_e%prof_t_wave_kin + REAL(prof_c1 - prof_c0, wp)/REAL(prof_rate, wp)
         prof_c0 = prof_c1
      END IF
      ! Grid coverage: checked on the positions just sampled (with their free-surface
      ! elevations), at Init (the static equilibrium) and then every mooring step until the one
      ! warning has been issued.
      IF (.NOT. inst_e%grid_warned) THEN
         CALL check_wavefield_grid( inst_e, p%WaveField, t_sample, init_call, wl_sampled, ErrStat2, ErrMsg2 )
         CALL SetErrStat( ErrStat2, ErrMsg2, ErrStat, ErrMsg, RoutineName )
      END IF
      IF (.NOT. inst_e%curr_grid_warned) CALL check_current_field_grid( inst_e, p%WaveField, t_sample )
      IF (timed) THEN
         CALL SYSTEM_CLOCK(prof_c1)
         inst_e%prof_t_wave_check = inst_e%prof_t_wave_check + REAL(prof_c1 - prof_c0, wp)/REAL(prof_rate, wp)
         prof_c0 = prof_c1
      END IF
      CALL CD_AGG_SetFluidFields( inst_e%agg, inst_e%fx_vel, inst_e%fx_acc, inst_e%fx_wl, es, em, &
                                  dynamic_pressure=inst_e%fx_pd )
      IF (timed) THEN
         CALL SYSTEM_CLOCK(prof_c1)
         inst_e%prof_t_wave_set = inst_e%prof_t_wave_set + REAL(prof_c1 - prof_c0, wp)/REAL(prof_rate, wp)
      END IF
      IF (es /= CD_AGG_OK) THEN
         CALL SetErrStat( ErrID_Fatal, 'CableDyn mooring module: '//TRIM(em), ErrStat, ErrMsg, RoutineName )
      END IF
   END SUBROUTINE sample_wavefield

!----------------------------------------------------------------------------------------------------------------------------------
   SUBROUTINE check_wavefield_grid( inst_e, wf, t_sample, at_init, wl_sampled, ErrStat, ErrMsg )
      !! Warn, once per run, when sampling nodes lie outside the SeaState wave-kinematics grid.
      !! The volume grid spans X_HalfWidth and Y_HalfWidth about the origin of the global frame
      !! the nodes are sampled in (FAST.Farm runs in still water and never samples) and Z_Depth
      !! below the SWL. Beyond it SeaState clamps the position to the grid boundary (GridInterp
      !! SetIndex horizontally, the depth mapping of WaveField_Interp_Setup4D vertically), so
      !! the node receives the kinematics of the nearest boundary point -- out of phase
      !! horizontally, too strong below Z_Depth. SeaState's own clamping notice is generic, names
      !! no node, and is issued once, at the Init sample, where the glue drops it. The extents are
      !! read from the WaveField's volume-grid parameters, i.e. exactly the grid the sampler
      !! interpolates. Excursions below 1 % of the boundary grid spacing are ignored. Below a
      !! grid that reaches the seabed (Z_Depth = WtrDpth + MSL2SWL, the SeaState maximum) a node
      !! is in the seabed and the seabed kinematics are the right ones. SeaState's current is
      !! uniform in x and y, so the horizontal check applies to waves only.
      !!
      !! Only nodes in the water are checked: a node above the free surface carries no fluid
      !! load whatever kinematics it is given, so a suspended cable or jumper above the water
      !! outside the grid is no error. A node is in the water at or below the free-surface
      !! elevation just sampled for it (fx_wl; the still-water level when the host waves are
      !! off), which decides its wetting in CableDyn, and, without wave stretching
      !! (WaveStMod = 0), at or below the still-water level too, above which SeaState gives a
      !! node zero kinematics without reading the grid. Called after the nodes' sampling, on the
      !! positions just sampled. Cost: a few comparisons per node per mooring step until the
      !! warning. at_init marks the Init call, at the static equilibrium (t = 0).
      !!
      !! The message states first that it is given once, so that a caller's message buffer that
      !! cuts its tail keeps that; the farthest-node details are left out if the message would not
      !! fit the remaining length of ErrMsg.
      TYPE(CD_OF_Instance),      INTENT(INOUT) :: inst_e
      TYPE(SeaSt_WaveFieldType), INTENT(IN   ) :: wf
      REAL(DbKi),                INTENT(IN   ) :: t_sample
      LOGICAL,                   INTENT(IN   ) :: at_init
      REAL(wp),                  INTENT(IN   ) :: wl_sampled(:)   !< SeaState elevation as sampled per node
      INTEGER(IntKi),            INTENT(  OUT) :: ErrStat
      CHARACTER(*),              INTENT(  OUT) :: ErrMsg

      character(*), parameter   :: RoutineName = 'check_wavefield_grid'
      LOGICAL                   :: waves, grid_current, check_xy(2), check_z, outside
      INTEGER(IntKi)            :: i, k, nout, nin, nwet, room
      REAL(wp)                  :: lo(2), hi(2), tol(2), zbot, tol_z, ex, ex_max(3), at_max(3), surface
      REAL(wp)                  :: zq, dep
      CHARACTER(11)             :: inp(3), res(3)
      CHARACTER(1024)           :: farthest, enlarge, refine
      CHARACTER(:), ALLOCATABLE :: head, msg

      ErrStat = ErrID_None
      ErrMsg  = ''
      waves = inst_e%agg%host_wave_enabled .AND. wf%WaveMod /= WaveMod_None
      grid_current = inst_e%agg%host_current_enabled .AND. wf%Current_InitInput%CurrMod /= 0_IntKi
      IF (.NOT. (waves .OR. grid_current)) RETURN
      DO k = 1, 2
         check_xy(k) = waves .AND. wf%VolGridParams%n(k + 1) > 1_IntKi
         lo(k)  = REAL(wf%VolGridParams%pZero(k + 1), wp)
         hi(k)  = lo(k) + REAL(wf%VolGridParams%n(k + 1) - 1_IntKi, wp)*REAL(wf%VolGridParams%delta(k + 1), wp)
         tol(k) = 0.01_wp*REAL(wf%VolGridParams%delta(k + 1), wp)
      END DO
      ! the vertical grid is cosine-spaced in delta(4); its bottom interval is Z_Depth*sin(delta(4))
      zbot  = -REAL(wf%GridDepth, wp)
      tol_z = 0.01_wp*REAL(wf%GridDepth, wp)*SIN(REAL(wf%VolGridParams%delta(4), wp))
      check_z = wf%VolGridParams%n(4) > 1_IntKi .AND. &
                REAL(wf%GridDepth, wp) < REAL(wf%EffWtrDpth, wp) - tol_z
      IF (.NOT. (ANY(check_xy) .OR. check_z)) RETURN

      nout   = 0_IntKi
      nwet   = 0_IntKi
      ex_max = 0.0_wp
      at_max = 0.0_wp
      DO i = 1, inst_e%nfluid
         ! nodes above the free surface carry no fluid load (see above)
         surface = inst_e%fx_wl(i)
         IF (wf%WaveStMod == 0_IntKi) surface = MIN(surface, 0.0_wp)
         IF (inst_e%fx_xyz(3, i) > surface) CYCLE
         nwet = nwet + 1_IntKi
         outside = .FALSE.
         DO k = 1, 2
            IF (.NOT. check_xy(k)) CYCLE
            ex = MAX(lo(k) - inst_e%fx_xyz(k, i), inst_e%fx_xyz(k, i) - hi(k))
            IF (ex > tol(k)) THEN
               outside = .TRUE.
               IF (ex > ex_max(k)) THEN
                  ex_max(k) = ex
                  at_max(k) = inst_e%fx_xyz(k, i)
               END IF
            END IF
         END DO
         IF (check_z) THEN
            ! SeaState interpolates at the node depth, or under Wheeler stretching (WaveStMod 3) at
            ! the depth mapped linearly from [-EffWtrDpth, wave elevation] to [-EffWtrDpth, 0] with
            ! the elevation it sampled -- also for the current of a current-only host mode, whose
            ! fx_wl is the still-water level
            zq = inst_e%fx_xyz(3, i)
            IF (wf%WaveMod /= WaveMod_None .AND. wf%WaveStMod == 3_IntKi) THEN
               dep = REAL(wf%EffWtrDpth, wp)
               IF (dep + wl_sampled(i) > 0.0_wp) zq = MIN(dep*(dep + zq)/(dep + wl_sampled(i)) - dep, 0.0_wp)
            END IF
            ex = zbot - zq
            IF (ex > tol_z) THEN
               outside = .TRUE.
               IF (ex > ex_max(3)) THEN
                  ex_max(3) = ex
                  at_max(3) = inst_e%fx_xyz(3, i)
               END IF
            END IF
         END IF
         IF (outside) nout = nout + 1_IntKi
      END DO
      IF (nout == 0_IntKi) RETURN

      ! the farthest node per direction, and the SeaState inputs that would cover it
      nin = 0_IntKi
      farthest = ''
      IF (ex_max(1) > 0.0_wp) THEN
         farthest = TRIM(farthest)//'; x = '//TRIM(Num2LStr(at_max(1)))//' m (grid |x| <= X_HalfWidth = '// &
                    TRIM(Num2LStr(0.5_wp*(hi(1) - lo(1))))//' m)'
         nin = nin + 1_IntKi
         inp(nin) = 'X_HalfWidth'
         res(nin) = 'NX'
      END IF
      IF (ex_max(2) > 0.0_wp) THEN
         farthest = TRIM(farthest)//'; y = '//TRIM(Num2LStr(at_max(2)))//' m (grid |y| <= Y_HalfWidth = '// &
                    TRIM(Num2LStr(0.5_wp*(hi(2) - lo(2))))//' m)'
         nin = nin + 1_IntKi
         inp(nin) = 'Y_HalfWidth'
         res(nin) = 'NY'
      END IF
      IF (ex_max(3) > 0.0_wp) THEN
         farthest = TRIM(farthest)//'; z = '//TRIM(Num2LStr(at_max(3)))//' m (grid z >= -Z_Depth = '// &
                    TRIM(Num2LStr(zbot))//' m)'
         nin = nin + 1_IntKi
         inp(nin) = 'Z_Depth'
         res(nin) = 'NZ'
      END IF
      enlarge = TRIM(inp(1))
      refine  = TRIM(res(1))
      DO k = 2, nin
         IF (k == nin) THEN
            enlarge = TRIM(enlarge)//' and '//TRIM(inp(k))
            refine  = TRIM(refine)//' and '//TRIM(res(k))
         ELSE
            enlarge = TRIM(enlarge)//', '//TRIM(inp(k))
            refine  = TRIM(refine)//', '//TRIM(res(k))
         END IF
      END DO
      IF (ex_max(3) > 0.0_wp) enlarge = TRIM(enlarge)//' (Z_Depth at most WtrDpth + MSL2SWL, its default)'

      inst_e%grid_warned = .TRUE.
      head = 'CableDyn mooring module: '//TRIM(Num2LStr(nout))//' of the '//TRIM(Num2LStr(nwet))// &
             ' CableDyn sampling nodes in the water lie outside the SeaState wave-kinematics grid at t = '// &
             TRIM(Num2LStr(t_sample))//' s (warned once). SeaState clamps them to the grid boundary, so '// &
             'their fluid kinematics and loads are not physical.'
      msg = head//' Farthest: '//TRIM(farthest(3:))//'. In the SeaState input file enlarge '//TRIM(enlarge)// &
            ' to cover the lines with margin for their motion, and raise '//TRIM(refine)// &
            ' to keep the grid spacing.'
      ! SetErrStat appends the message to ErrMsg after a line break and the routine name
      room = LEN(ErrMsg) - LEN_TRIM(ErrMsg) - LEN(RoutineName) - 2
      IF (LEN(msg) > room) msg = head//' Enlarge '//TRIM(enlarge)//' in the SeaState input file.'
      CALL SetErrStat( ErrID_Warn, msg, ErrStat, ErrMsg, RoutineName )
      ! The OpenFAST glue does not print module initialization warnings (FAST_InitializeAll_T
      ! passes its status on to FAST_InitMappings, which resets it), so the Init check also
      ! writes the warning to the screen, as the deck dtM warning does. A warning raised
      ! during the time march reaches the screen through the glue's error check.
      IF (at_init) CALL WrScr( '   WARNING: '//msg )
   END SUBROUTINE check_wavefield_grid

   SUBROUTINE note_seastate_deep_interval( inst_e, wf )
      !! Say at initialisation, once per run (a restart rebuilds without passing here), when the
      !! deepest interval of the SeaState depth grid is coarse and a line lies in it. The levels
      !! are z_k = Z_Depth*(sin(k*delta) - 1) with delta = pi/(2*(NZ - 1)): the grid is finest at
      !! the surface and coarsest at the bottom, where the interval H = Z_Depth*sin(delta) is
      !! pi/2 times the uniform spacing. Inside H the field is interpolated linearly down to the
      !! seabed. For the 1/7-power current of CurrMod 1 that is up to 62 % of the value at the top
      !! of the interval low, whatever H is, so H alone sets how much of the column carries the
      !! difference: the depth integral of the current lacks 3/7*(H/D)^(8/7) of its value, 1.4 %
      !! at the threshold H = 5 % of the depth (NZ >= 33 stays below it) and 3.5 % at NZ = 15. A
      !! grid short of the seabed has the out-of-grid warning of check_wavefield_grid instead.
      !! Reads the grid and the node positions and writes to the screen only.
      TYPE(CD_OF_Instance),      INTENT(IN) :: inst_e
      TYPE(SeaSt_WaveFieldType), INTENT(IN) :: wf
      REAL(wp), PARAMETER :: HALF_PI = 2.0_wp*ATAN(1.0_wp)
      LOGICAL  :: waves, grid_current
      INTEGER(IntKi) :: nz, nodes
      REAL(wp) :: depth, interval

      waves = inst_e%agg%host_wave_enabled .AND. wf%WaveMod /= WaveMod_None
      grid_current = inst_e%agg%host_current_enabled .AND. wf%Current_InitInput%CurrMod /= 0_IntKi
      nz = wf%VolGridParams%n(4)
      IF (.NOT. (waves .OR. grid_current) .OR. nz < 2_IntKi) RETURN
      depth = REAL(wf%GridDepth, wp)
      interval = depth*SIN(REAL(wf%VolGridParams%delta(4), wp))
      IF (depth < REAL(wf%EffWtrDpth, wp) - 0.01_wp*interval) RETURN
      IF (interval <= SEASTATE_DEEP_INTERVAL*depth) RETURN
      nodes = COUNT(inst_e%fx_xyz(3, 1:inst_e%nfluid) < interval - depth)
      IF (nodes == 0_IntKi) RETURN
      CALL WrScr( '   Note: the deepest interval of the SeaState depth grid is '//TRIM(Num2LStr(interval))// &
                  ' m (NZ = '//TRIM(Num2LStr(nz))//', Z_Depth = '//TRIM(Num2LStr(depth))//' m), over '// &
                  TRIM(Num2LStr(NINT(100.0_wp*SEASTATE_DEEP_INTERVAL)))//' % of the depth, and '// &
                  TRIM(Num2LStr(nodes))//' of the '//TRIM(Num2LStr(inst_e%nfluid))// &
                  ' CableDyn sampling nodes lie in it. The field is linear there, so near the seabed '// &
                  'it differs from a deck depth table. More depth levels refine it: NZ = '// &
                  TRIM(Num2LStr(1_IntKi + CEILING(HALF_PI/ASIN(SEASTATE_DEEP_INTERVAL), IntKi)))// &
                  ' or more in the SeaState input file.' )
   END SUBROUTINE note_seastate_deep_interval

   SUBROUTINE check_current_field_grid( inst_e, wf, t_sample )
      !! A dynamically populated current field (an InflowWind-driven MHK current, hasCurrField) is
      !! not read on the SeaState grid: InflowWind reads it on its own field at the node position
      !! shifted up by the water depth (the field's z = 0 is the seabed). For a gridded (Grid3D)
      !! field, warn once when submerged sampling nodes lie outside its vertical extent
      !! [GridBase, GridBase + 2 ZHWid] or its lateral half-width YHWid (in the field's frame,
      !! rotated about its reference position when the box is rotated), where InflowWind
      !! extrapolates or stops. Other field types have no extent to check.
      TYPE(CD_OF_Instance),      INTENT(INOUT) :: inst_e
      TYPE(SeaSt_WaveFieldType), INTENT(IN   ) :: wf
      REAL(DbKi),                INTENT(IN   ) :: t_sample
      INTEGER(IntKi) :: i, nout
      REAL(wp)       :: zlo, zhi, yhw, dep, tol, pos(3), rel(3), yw, zw, surface, ez, ey
      CHARACTER(1024):: msg

      IF (.NOT. (inst_e%agg%host_current_enabled .AND. wf%hasCurrField)) RETURN
      IF (wf%CurrField%FieldType /= Grid3D_FieldType) RETURN
      dep = REAL(wf%EffWtrDpth, wp)
      zlo = REAL(wf%CurrField%Grid3D%GridBase, wp)
      zhi = zlo + 2.0_wp*REAL(wf%CurrField%Grid3D%ZHWid, wp)
      yhw = REAL(wf%CurrField%Grid3D%YHWid, wp)
      tol = 1.0E-6_wp*MAX(1.0_wp, dep)
      nout = 0_IntKi
      ez = 0.0_wp
      ey = 0.0_wp
      DO i = 1, inst_e%nfluid
         surface = MIN(inst_e%fx_wl(i), 0.0_wp)
         IF (inst_e%fx_xyz(3, i) > MAX(inst_e%fx_wl(i), surface)) CYCLE
         pos = [inst_e%fx_xyz(1, i), inst_e%fx_xyz(2, i), inst_e%fx_xyz(3, i) + dep]
         IF (wf%CurrField%RotateWindBox) THEN
            rel = MATMUL(REAL(wf%CurrField%RotToWind, wp), pos - REAL(wf%CurrField%RefPosition, wp)) + &
                  REAL(wf%CurrField%RefPosition, wp)
         ELSE
            rel = pos
         END IF
         yw = rel(2)
         zw = rel(3)
         IF (zw < zlo - tol .OR. zw > zhi + tol .OR. ABS(yw) > yhw + tol) THEN
            nout = nout + 1_IntKi
            ez = MAX(ez, zlo - zw, zw - zhi)
            ey = MAX(ey, ABS(yw) - yhw)
         END IF
      END DO
      IF (nout == 0_IntKi) RETURN
      inst_e%curr_grid_warned = .TRUE.
      WRITE (msg, '(A,I0,A,ES10.3,A,ES10.3,A,ES10.3,A,ES10.3,A,ES10.3,A,ES10.3,A)') &
         'CableDyn mooring module: ', nout, ' submerged CableDyn sampling node(s) lie outside the '// &
         'InflowWind current-field grid at t = ', REAL(t_sample, wp), ' s (warned once): the field covers '// &
         'z = ', zlo, ' to ', zhi, ' m above the seabed and |y| <= ', yhw, ' m; the farthest node is ', &
         MAX(ez, 0.0_wp), ' m outside in z and ', MAX(ey, 0.0_wp), &
         ' m in y. InflowWind extrapolates or stops there; enlarge the current-field grid to cover the lines.'
      CALL WrScr( TRIM(msg) )
   END SUBROUTINE check_current_field_grid

!----------------------------------------------------------------------------------------------------------------------------------
   SUBROUTINE CD_CalcOutput( t, u, p, x, xd, z, other, y, m, ErrStat, ErrMsg )
      REAL(DbKi)                     , INTENT(IN   ) :: t
      TYPE( CD_InputType )           , INTENT(IN   ) :: u
      TYPE( CD_ParameterType )       , INTENT(IN   ) :: p
      TYPE( CD_ContinuousStateType ) , INTENT(IN   ) :: x
      TYPE( CD_DiscreteStateType )   , INTENT(IN   ) :: xd
      TYPE( CD_ConstraintStateType ) , INTENT(IN   ) :: z
      TYPE( CD_OtherStateType )      , INTENT(IN   ) :: other
      TYPE( CD_OutputType )          , INTENT(INOUT) :: y
      TYPE(CD_MiscVarType)           , INTENT(INOUT) :: m
      INTEGER(IntKi)                 , INTENT(INOUT) :: ErrStat
      CHARACTER(*)                   , INTENT(INOUT) :: ErrMsg

      character(*), parameter   :: RoutineName = 'CD_CalcOutput'
      INTEGER(IntKi)            :: ErrStat2, es, id, i
      INTEGER(IntKi)            :: prof_c0, prof_c1, prof_rate, prof_phase0
      CHARACTER(ErrMsgLen)      :: ErrMsg2
      CHARACTER(ErrMsgLen)            :: em
      REAL(wp)                  :: cval
      REAL(wp)                  :: tau_pred   ! load predictor: fraction of the mooring step elapsed
      LOGICAL                   :: fresh, state_overlaid

      ! Report this call's OWN status: clear at entry (ErrStat is INTENT(INOUT) and
      ! every SetErrStat below only ACCUMULATES, so on the all-success path an
      ! uninitialised incoming status would survive -- the FD-Jacobian probe passes
      ! its own uninitialised locals here). Mirrors every other CD_* entry point.
      ErrStat = ErrID_None
      ErrMsg  = ''

      ! CHECKPOINT-RESTART: the glue's first post-restore call can be CalcOutput, so this
      ! entry also rebuilds a non-matching instance (OtherState is INTENT(IN) here; the
      ! rebuild ADOPTS its identity without writing it).
      IF (.NOT. instance_matches(m, other)) THEN
         CALL rebuild_from_checkpoint( t, u, p, x, other, m, ErrStat2, ErrMsg2 )
         CALL SetErrStat( ErrStat2, ErrMsg2, ErrStat, ErrMsg, RoutineName )
         IF (ErrStat >= AbortErrLev) RETURN
         ! (active line control is re-applied INSIDE rebuild_from_checkpoint, so
         ! this entry -- like every rebuild entry -- resumes at the checkpointed
         ! lengths; between advances CalcOutput stays state-const with the
         ! committed lengths, the supercycled zero-order-hold semantics)
      END IF
      id = m%CDInst
      IF (Inst(id)%prof_enabled) THEN
         CALL SYSTEM_CLOCK(prof_c0, prof_rate)
         Inst(id)%prof_n_calcout = Inst(id)%prof_n_calcout + 1_IntKi
      END IF
      state_overlaid = .FALSE.

      ! Evaluate the loads the mooring exerts on the coupling points. At nsuper = 1 (the
      ! mooring stepping at the glue rate) the CURRENT coupled kinematics are transferred
      ! first, so the loads carry the instantaneous direct feedthrough -- the original
      ! behavior, bit-for-bit. With SUPERCYCLING (nsuper > 1) the loads are instead the
      ! LAST COMMITTED mooring step's (a zero-order hold): transferring the instantaneous
      ! endpoint against the lagged interior would ring the stiff EA elastic feedthrough
      ! with a per-glue-step tension sawtooth, whereas the held loads lag by at most
      ! dt_moor. All scratch is the instance's persistent workspace.
      IF (Inst(id)%nsuper == 1_IntKi) THEN
         ! Gather the caller input before touching the aggregate.
         IF (Inst(id)%nT > 0) THEN
            CALL farm_gather_kinematics( Inst(id), u, ErrStat2, ErrMsg2 )
         ELSE
            CALL mesh_to_arrays( u%CoupledKinematics(1), Inst(id)%ncp, Inst(id)%ws_pos, Inst(id)%ws_vel, &
                                 Inst(id)%ws_acc, Inst(id)%ws_orient, Inst(id)%ws_omega, Inst(id)%ws_alpha, &
                                 ErrStat2, ErrMsg2 )
         END IF
         CALL SetErrStat( ErrStat2, ErrMsg2, ErrStat, ErrMsg, RoutineName )
         IF (ErrStat >= AbortErrLev) RETURN
         fresh = .TRUE.
         ! At the glue rate, every call re-evaluates with the current kinematics
         ! transferred -- and then RESTORED. CalcOutput must be state-const: the glue
         ! calls it out-of-band with off-step inputs (checkpoint packing, extra output
         ! evaluations, probes), and committing those boundary kinematics would move the
         ! module's committed state. Save the committed coupled kinematics, transfer,
         ! evaluate, restore: the direct-feedthrough loads keep their semantics and the
         ! committed state is untouched on exit. The save needs only the kinematics: the
         ! cable reactions (a full cable assembly each) are skipped, and ws_fld is overwritten
         ! by the loads evaluated below.
         CALL CD_AGG_GetMovingPointMesh( Inst(id)%agg, Inst(id)%sv_pos, Inst(id)%sv_vel, Inst(id)%sv_acc, &
                                         Inst(id)%ws_fld, es, em, orientation=Inst(id)%sv_orient, &
                                         angular_velocity=Inst(id)%sv_omega, angular_acceleration=Inst(id)%sv_alpha, &
                                         cable_loads=.FALSE. )
         IF (es /= CD_AGG_OK) THEN
            CALL SetErrStat( ErrID_Fatal, 'CableDyn mooring module: '//TRIM(em), ErrStat, ErrMsg, RoutineName ); RETURN
         END IF
         ! ... and the FULL committed state. The output-probe overlay below changes only
         ! prescribed endpoints; the mirror remains the final authority for every
         ! committed generalized-alpha interior value.
         IF (.NOT. ALLOCATED(Inst(id)%ws_msave)) THEN
            ALLOCATE (Inst(id)%ws_msave(m%Nx), STAT=ErrStat2)
            IF (ErrStat2 /= 0) THEN
               CALL SetErrStat( ErrID_Fatal, 'Could not allocate the CalcOutput state mirror.', &
                                ErrStat, ErrMsg, RoutineName )
               RETURN
            END IF
         END IF
         CALL pack_state_mirror_ary( Inst(id), m, Inst(id)%ws_msave, ErrStat2, ErrMsg2 )
         CALL SetErrStat( ErrStat2, ErrMsg2, ErrStat, ErrMsg, RoutineName )
         IF (ErrStat >= AbortErrLev) RETURN
         state_overlaid = .TRUE. ! cleanup is required even if an output probe fails part-way
         CALL CD_AGG_UpdateStates_Moving( Inst(id)%agg, Inst(id)%ws_pos, Inst(id)%ws_vel, Inst(id)%ws_acc, es, em, &
                                          output_probe=.TRUE., orientation=Inst(id)%ws_orient, &
                                          angular_velocity=Inst(id)%ws_omega, angular_acceleration=Inst(id)%ws_alpha )
         IF (es /= CD_AGG_OK) THEN
            CALL SetErrStat( ErrID_Fatal, 'CableDyn mooring module: '//TRIM(em), ErrStat, ErrMsg, RoutineName )
            CALL restore_calcoutput_probe( Inst(id), m, ErrStat2, ErrMsg2 )
            CALL SetErrStat( ErrStat2, ErrMsg2, ErrStat, ErrMsg, RoutineName )
            RETURN
         END IF
         IF (Inst(id)%prof_enabled) THEN
            CALL SYSTEM_CLOCK(prof_c1)
            Inst(id)%prof_t_overlay = Inst(id)%prof_t_overlay + REAL(prof_c1 - prof_c0, wp)/REAL(prof_rate, wp)
         END IF
      ELSE
         ! Supercycled: the committed state changes only when a mooring step completes, so the
         ! held loads/channels are re-evaluated only then (serving the cache is bit-identical
         ! to re-evaluating the unchanged state, at 1/nsuper of the evaluations).
         fresh = (.NOT. Inst(id)%loads_cached) .OR. (Inst(id)%loads_at_n /= Inst(id)%last_solve_n)
      END IF

      IF (fresh) THEN
         IF (Inst(id)%prof_enabled) THEN
            Inst(id)%prof_n_fresh = Inst(id)%prof_n_fresh + 1_IntKi
            CALL SYSTEM_CLOCK(prof_phase0)
         END IF
         CALL CD_AGG_CalcOutput( Inst(id)%agg, es, em )
         IF (es /= CD_AGG_OK) THEN
            IF (Inst(id)%prof_enabled) THEN
               CALL SYSTEM_CLOCK(prof_c1)
               Inst(id)%prof_t_loads = Inst(id)%prof_t_loads + &
                  REAL(prof_c1 - prof_phase0, wp)/REAL(prof_rate, wp)
            END IF
            CALL SetErrStat( ErrID_Fatal, 'CableDyn mooring module: '//TRIM(em), ErrStat, ErrMsg, RoutineName )
            IF (state_overlaid) THEN
               CALL restore_calcoutput_probe( Inst(id), m, ErrStat2, ErrMsg2 )
               CALL SetErrStat( ErrStat2, ErrMsg2, ErrStat, ErrMsg, RoutineName )
            END IF
            RETURN
         END IF
         CALL CD_AGG_GetMovingPointMesh( Inst(id)%agg, Inst(id)%ws_pos, Inst(id)%ws_vel, Inst(id)%ws_acc, &
                                         Inst(id)%ws_fld, es, em, orientation=Inst(id)%ws_orient, &
                                         moment=Inst(id)%ws_moment, angular_velocity=Inst(id)%ws_omega, &
                                         angular_acceleration=Inst(id)%ws_alpha )
         ! The aggregate CalcOutput above recovers EI=0 loads; finite-EI fairlead reactions are
         ! evaluated on demand by GetMovingPointMesh. Stop the phase timer only after both halves
         ! so mixed-run load recovery is not misattributed to the enclosing CalcOutput time.
         IF (Inst(id)%prof_enabled) THEN
            CALL SYSTEM_CLOCK(prof_c1)
            Inst(id)%prof_t_loads = Inst(id)%prof_t_loads + &
               REAL(prof_c1 - prof_phase0, wp)/REAL(prof_rate, wp)
         END IF
         IF (es /= CD_AGG_OK) THEN
            CALL SetErrStat( ErrID_Fatal, 'CableDyn mooring module: '//TRIM(em), ErrStat, ErrMsg, RoutineName )
            IF (state_overlaid) THEN
               CALL restore_calcoutput_probe( Inst(id), m, ErrStat2, ErrMsg2 )
               CALL SetErrStat( ErrStat2, ErrMsg2, ErrStat, ErrMsg, RoutineName )
            END IF
            RETURN
         END IF
         ! Deck OUTPUTS channels are evaluated at the same aggregate state as the returned
         ! loads: with supercycling the last committed zero-order-hold mooring state, at
         ! nsuper = 1 the state including the current coupled kinematics.
         IF (Inst(id)%prof_enabled) CALL SYSTEM_CLOCK(prof_phase0)
         DO i = 1, p%NumOuts
            CALL CD_AGG_EvalChannel( Inst(id)%agg, i, cval, es, em )
            IF (es /= CD_AGG_OK) THEN
               CALL SetErrStat( ErrID_Fatal, 'CableDyn mooring module: output channel evaluation failed: '// &
                                TRIM(em), ErrStat, ErrMsg, RoutineName )
               IF (state_overlaid) THEN
                  CALL restore_calcoutput_probe( Inst(id), m, ErrStat2, ErrMsg2 )
                  CALL SetErrStat( ErrStat2, ErrMsg2, ErrStat, ErrMsg, RoutineName )
               END IF
               RETURN
            END IF
            Inst(id)%ws_chan(i) = cval
         END DO
         IF (Inst(id)%prof_enabled) THEN
            CALL SYSTEM_CLOCK(prof_c1)
            Inst(id)%prof_t_channels = Inst(id)%prof_t_channels + &
               REAL(prof_c1 - prof_phase0, wp)/REAL(prof_rate, wp)
         END IF
         Inst(id)%loads_cached = .TRUE.
         Inst(id)%loads_at_n = Inst(id)%last_solve_n
         Inst(id)%restored_unserved = .FALSE.
      END IF

      ! restore the committed coupled kinematics saved above (state-const CalcOutput),
      ! then reload the interiors from the captured mirror: the boundary transfer just
      ! re-derived interior accelerations, and only the mirror carries the committed
      ! gen-alpha values.
      IF (state_overlaid) THEN
         IF (Inst(id)%prof_enabled) CALL SYSTEM_CLOCK(prof_phase0)
         CALL restore_calcoutput_probe( Inst(id), m, ErrStat2, ErrMsg2 )
         IF (Inst(id)%prof_enabled) THEN
            CALL SYSTEM_CLOCK(prof_c1)
            Inst(id)%prof_t_restore = Inst(id)%prof_t_restore + &
               REAL(prof_c1 - prof_phase0, wp)/REAL(prof_rate, wp)
         END IF
         CALL SetErrStat( ErrStat2, ErrMsg2, ErrStat, ErrMsg, RoutineName )
         IF (ErrStat >= AbortErrLev) RETURN
      END IF

      ! CableDyn-owned channel recording: one row per COMMITTED mooring advance, stamped with
      ! the commit time and evaluated HERE -- after the committed-state restore -- because
      ! at nsuper = 1 the fresh branch above intentionally evaluates ws_chan at the
      ! caller's CURRENT input (the documented instantaneous feedthrough an out-of-band
      ! probe/extra CalcOutput may drive with transient kinematics). The row must carry
      ! the committed state the stamp names, so its channels re-evaluate against the
      ! restored aggregate (at nsuper > 1 the committed state is live anyway and the
      ! re-evaluation is identical). Keyed on last_solve_n: exactly one row per advance,
      ! whichever call after it comes first; the t = 0 static row was written at Init.
      ! If a glue correction re-advances the same n, BACKSPACE replaces the provisional
      ! last record with the corrected committed result rather than duplicating the time.
      IF (Inst(id)%native_un > 0 .AND. Inst(id)%native_pending .AND. Inst(id)%last_solve_n >= 0_IntKi) THEN
         IF (Inst(id)%prof_enabled) CALL SYSTEM_CLOCK(prof_phase0)
         IF (Inst(id)%last_solve_n == Inst(id)%native_wrote_n) BACKSPACE (Inst(id)%native_un)
         WRITE (Inst(id)%native_un, '(ES25.16E3)', ADVANCE='NO') MAX(Inst(id)%t_commit, 0.0_DbKi)
         DO i = 1, p%NumOuts
            CALL CD_AGG_EvalChannel( Inst(id)%agg, i, cval, es, em )
            IF (es /= CD_AGG_OK) THEN
               CALL SetErrStat( ErrID_Fatal, 'CableDyn mooring module: committed-step channel record: '//TRIM(em), &
                                ErrStat, ErrMsg, RoutineName ); RETURN
            END IF
            WRITE (Inst(id)%native_un, CD_NATIVE_CHANNEL_FMT, ADVANCE='NO') CHAR(9), cval
         END DO
         WRITE (Inst(id)%native_un, '(A)') ''
         ! keep the record readable during the run (and intact after a crash)
         FLUSH (Inst(id)%native_un)
         Inst(id)%native_wrote_n = Inst(id)%last_solve_n
         Inst(id)%native_wrote_t = MAX(Inst(id)%t_commit, 0.0_DbKi)
         Inst(id)%native_pending = .FALSE.
         IF (Inst(id)%prof_enabled) THEN
            CALL SYSTEM_CLOCK(prof_c1)
            Inst(id)%prof_t_native = Inst(id)%prof_t_native + &
               REAL(prof_c1 - prof_phase0, wp)/REAL(prof_rate, wp)
         END IF
      END IF

      IF (Inst(id)%nT > 0) THEN
         DO i = 1, Inst(id)%nT
            y%CoupledLoads(i)%Force  = 0.0_ReKi
            y%CoupledLoads(i)%Moment = 0.0_ReKi
         END DO
         DO i = 1, Inst(id)%ncp
            y%CoupledLoads(Inst(id)%tmap(i))%Force(:, Inst(id)%node_of_slot(i)) = &
               REAL(Inst(id)%ws_fld(:, i), ReKi)
            y%CoupledLoads(Inst(id)%tmap(i))%Moment(:, Inst(id)%node_of_slot(i)) = &
               REAL(Inst(id)%ws_moment(:, i), ReKi)
         END DO
      ELSE
      DO i = 1, Inst(id)%ncp
         y%CoupledLoads(1)%Force(:, i) = REAL(Inst(id)%ws_fld(:, i), ReKi)
         y%CoupledLoads(1)%Moment(:, i) = REAL(Inst(id)%ws_moment(:, i), ReKi)
      END DO
      END IF
      ! Load predictor (supercycled, predictLoads): the committed loads extrapolated from the
      ! solve before, at the fraction of the mooring step elapsed (CableDyn_LoadPredictor). The
      ! output channels keep the committed samples.
      IF (Inst(id)%nsuper > 1_IntKi .AND. Inst(id)%agg%predict_loads) THEN
         IF (CD_Predictor_Ready(REAL(Inst(id)%t_commit, wp), REAL(Inst(id)%pred_t, wp), Inst(id)%dt_moor)) THEN
            IF (.NOT. ALLOCATED(Inst(id)%ws_pfld)) &
               ALLOCATE (Inst(id)%ws_pfld(3, Inst(id)%ncp), Inst(id)%ws_pmom(3, Inst(id)%ncp))
            tau_pred = CD_Predictor_Fraction(REAL(t, wp), REAL(Inst(id)%t_commit, wp), Inst(id)%dt_moor)
            CALL CD_Predict_Loads(Inst(id)%ws_fld, Inst(id)%pred_fld, tau_pred, Inst(id)%ws_pfld)
            CALL CD_Predict_Loads(Inst(id)%ws_moment, Inst(id)%pred_mom, tau_pred, Inst(id)%ws_pmom)
            IF (Inst(id)%nT > 0) THEN
               DO i = 1, Inst(id)%ncp
                  y%CoupledLoads(Inst(id)%tmap(i))%Force(:, Inst(id)%node_of_slot(i)) = &
                     REAL(Inst(id)%ws_pfld(:, i), ReKi)
                  y%CoupledLoads(Inst(id)%tmap(i))%Moment(:, Inst(id)%node_of_slot(i)) = &
                     REAL(Inst(id)%ws_pmom(:, i), ReKi)
               END DO
            ELSE
               DO i = 1, Inst(id)%ncp
                  y%CoupledLoads(1)%Force(:, i) = REAL(Inst(id)%ws_pfld(:, i), ReKi)
                  y%CoupledLoads(1)%Moment(:, i) = REAL(Inst(id)%ws_pmom(:, i), ReKi)
               END DO
            END IF
         END IF
      END IF
      DO i = 1, p%NumOuts
         y%WriteOutput(i) = REAL(Inst(id)%ws_chan(i), ReKi)
      END DO

      IF (Inst(id)%prof_enabled) THEN
         CALL SYSTEM_CLOCK(prof_c1)
         Inst(id)%prof_t_calcout = Inst(id)%prof_t_calcout + &
            REAL(prof_c1 - prof_c0, wp)/REAL(prof_rate, wp)
      END IF

   END SUBROUTINE CD_CalcOutput

!----------------------------------------------------------------------------------------------------------------------------------
   SUBROUTINE save_held_fluid( inst_e, other )
      !! Mirror the held ambient-fluid fields of the committed step (fx_vel, fx_acc, fx_wl,
      !! fx_pd, as last handed to the aggregate by sample_wavefield) into the OtherState, so a
      !! restart serves its loads from the same fields (restore_held_fluid).
      TYPE(CD_OF_Instance),     INTENT(IN   ) :: inst_e
      TYPE(CD_OtherStateType),  INTENT(INOUT) :: other
      INTEGER(IntKi) :: nf
      nf = inst_e%nfluid
      IF (ALLOCATED(other%fluid_held)) THEN
         IF (SIZE(other%fluid_held) /= 8*nf) DEALLOCATE (other%fluid_held)
      END IF
      IF (.NOT. ALLOCATED(other%fluid_held)) ALLOCATE (other%fluid_held(8*nf))
      other%fluid_held(1:3*nf) = RESHAPE(REAL(inst_e%fx_vel, DbKi), [3*nf])
      other%fluid_held(3*nf + 1:6*nf) = RESHAPE(REAL(inst_e%fx_acc, DbKi), [3*nf])
      other%fluid_held(6*nf + 1:7*nf) = REAL(inst_e%fx_wl, DbKi)
      other%fluid_held(7*nf + 1:8*nf) = REAL(inst_e%fx_pd, DbKi)
   END SUBROUTINE save_held_fluid

   SUBROUTINE restore_held_fluid( inst_e, other, restored, ErrStat, ErrMsg )
      !! Hand the held ambient-fluid fields of a checkpoint (save_held_fluid) back to the
      !! aggregate; restored is .FALSE. when the checkpoint does not carry them for this
      !! instance's fluid nodes.
      TYPE(CD_OF_Instance),     INTENT(INOUT) :: inst_e
      TYPE(CD_OtherStateType),  INTENT(IN   ) :: other
      LOGICAL,                  INTENT(  OUT) :: restored
      INTEGER(IntKi),           INTENT(  OUT) :: ErrStat
      CHARACTER(*),             INTENT(  OUT) :: ErrMsg
      INTEGER(IntKi) :: nf, es
      CHARACTER(ErrMsgLen) :: em
      ErrStat = ErrID_None
      ErrMsg = ''
      restored = .FALSE.
      nf = inst_e%nfluid
      IF (.NOT. ALLOCATED(other%fluid_held)) RETURN
      IF (SIZE(other%fluid_held) /= 8*nf) RETURN
      inst_e%fx_vel = RESHAPE(REAL(other%fluid_held(1:3*nf), wp), [3, nf])
      inst_e%fx_acc = RESHAPE(REAL(other%fluid_held(3*nf + 1:6*nf), wp), [3, nf])
      inst_e%fx_wl = REAL(other%fluid_held(6*nf + 1:7*nf), wp)
      inst_e%fx_pd = REAL(other%fluid_held(7*nf + 1:8*nf), wp)
      CALL CD_AGG_SetFluidFields( inst_e%agg, inst_e%fx_vel, inst_e%fx_acc, inst_e%fx_wl, es, em, &
                                  dynamic_pressure=inst_e%fx_pd )
      IF (es /= CD_AGG_OK) THEN
         ErrStat = ErrID_Fatal
         ErrMsg = 'CableDyn mooring module: restoring the held fluid fields: '//TRIM(em)
         RETURN
      END IF
      restored = .TRUE.
   END SUBROUTINE restore_held_fluid

   SUBROUTINE sample_range( inst_e, other, t_sample, ErrStat, ErrMsg )
      !! Add the committed state at t_sample to the range graphs and mirror them into the
      !! OtherState, so a checkpoint carries them. The samples are the aggregate's own double
      !! precision node values, whatever the precision of the host's outputs (ReKi).
      TYPE(CD_OF_Instance),     INTENT(INOUT) :: inst_e
      TYPE(CD_OtherStateType),  INTENT(INOUT) :: other
      REAL(DbKi),               INTENT(IN   ) :: t_sample
      INTEGER(IntKi),           INTENT(  OUT) :: ErrStat
      CHARACTER(*),             INTENT(  OUT) :: ErrMsg
      INTEGER(IntKi) :: es, nr
      CHARACTER(ErrMsgLen) :: em
      ErrStat = ErrID_None
      ErrMsg = ''
      CALL CD_AGG_Range_Sample( inst_e%agg, REAL(t_sample, wp), es, em )
      nr = CD_AGG_Range_MirrorSize( inst_e%agg )
      IF (.NOT. ALLOCATED(inst_e%ws_range)) ALLOCATE (inst_e%ws_range(nr))
      IF (es == CD_AGG_OK) CALL CD_AGG_Range_Get_State( inst_e%agg, inst_e%ws_range, es, em )
      IF (es /= CD_AGG_OK) THEN
         ErrStat = ErrID_Fatal
         ErrMsg = 'CableDyn mooring module: range-graph sample at t = '//TRIM(Num2LStr(t_sample))//' s: '//TRIM(em)
         RETURN
      END IF
      IF (ALLOCATED(other%range_state)) THEN
         IF (SIZE(other%range_state) /= nr) DEALLOCATE (other%range_state)
      END IF
      IF (.NOT. ALLOCATED(other%range_state)) ALLOCATE (other%range_state(nr))
      other%range_state = REAL(inst_e%ws_range, DbKi)
      inst_e%range_sampled = .TRUE.
   END SUBROUTINE sample_range

   SUBROUTINE restore_range_state( inst_e, other, ErrStat, ErrMsg )
      !! Hand the range graphs of a checkpoint (sample_range) back to the rebuilt aggregate. A
      !! checkpoint without them for these lines fails by name: continuing would write a range
      !! graph that silently misses the run before the restart.
      TYPE(CD_OF_Instance),     INTENT(INOUT) :: inst_e
      TYPE(CD_OtherStateType),  INTENT(IN   ) :: other
      INTEGER(IntKi),           INTENT(  OUT) :: ErrStat
      CHARACTER(*),             INTENT(  OUT) :: ErrMsg
      INTEGER(IntKi) :: es
      CHARACTER(ErrMsgLen) :: em
      ErrStat = ErrID_None
      ErrMsg = ''
      es = CD_AGG_OK
      IF (ALLOCATED(other%range_state)) THEN
         CALL CD_AGG_Range_Set_State( inst_e%agg, REAL(other%range_state, wp), es, em )
      ELSE
         es = ErrID_Fatal
         em = 'the checkpoint carries no range graphs'
      END IF
      IF (es /= CD_AGG_OK) THEN
         ErrStat = ErrID_Fatal
         ErrMsg = 'CableDyn mooring module: checkpoint rebuild of the range graphs (LINES flag r): '//TRIM(em)
      END IF
   END SUBROUTINE restore_range_state

   SUBROUTINE shift_predictor_loads( inst_e, other )
      !! The load predictor's previous commit when a new mooring step starts: the loads served
      !! since the last commit, when CalcOutput evaluated them there (its committed loads), and
      !! that commit's time; none otherwise. Mirrored into the OtherState, so a restart
      !! continues the extrapolation from the same two commits.
      TYPE(CD_OF_Instance),     INTENT(INOUT) :: inst_e
      TYPE(CD_OtherStateType),  INTENT(INOUT) :: other
      IF (inst_e%loads_cached .AND. inst_e%loads_at_n == inst_e%last_solve_n) THEN
         inst_e%pred_fld = inst_e%ws_fld
         inst_e%pred_mom = inst_e%ws_moment
         inst_e%pred_t = inst_e%t_commit
      ELSE
         inst_e%pred_t = -1.0_DbKi
      END IF
      CALL mirror_predictor_loads( inst_e, other )
   END SUBROUTINE shift_predictor_loads

   SUBROUTINE mirror_predictor_loads( inst_e, other )
      !! The load predictor's previous commit, as the instance holds it, into the OtherState.
      TYPE(CD_OF_Instance),     INTENT(IN   ) :: inst_e
      TYPE(CD_OtherStateType),  INTENT(INOUT) :: other
      INTEGER(IntKi) :: nl
      other%pred_t = inst_e%pred_t
      IF (inst_e%pred_t < 0.0_DbKi) RETURN
      nl = 3_IntKi*inst_e%ncp
      IF (ALLOCATED(other%pred_loads)) THEN
         IF (SIZE(other%pred_loads) /= 2*nl) DEALLOCATE (other%pred_loads)
      END IF
      IF (.NOT. ALLOCATED(other%pred_loads)) ALLOCATE (other%pred_loads(2*nl))
      other%pred_loads(1:nl) = RESHAPE(REAL(inst_e%pred_fld, DbKi), [nl])
      other%pred_loads(nl + 1:2*nl) = RESHAPE(REAL(inst_e%pred_mom, DbKi), [nl])
   END SUBROUTINE mirror_predictor_loads

   SUBROUTINE save_commit_input( inst_e, other, pos, vel, acc, orient, omega, alpha, u_ctrl )
      !! What the state now committed was reached with, into the OtherState: the coupled
      !! kinematics [position; velocity; acceleration; orientation; angular velocity; angular
      !! acceleration] and the line-control command [DeltaL; DeltaLdot] of u_ctrl. The glue's
      !! input moves on between commits, so a restart inside the mooring step that follows
      !! rebuilds from this, not from the input at its own time.
      TYPE(CD_OF_Instance),     INTENT(IN   ) :: inst_e
      TYPE(CD_OtherStateType),  INTENT(INOUT) :: other
      REAL(wp),                 INTENT(IN   ) :: pos(:,:), vel(:,:), acc(:,:), orient(:,:,:), omega(:,:), alpha(:,:)
      TYPE(CD_InputType),       INTENT(IN   ) :: u_ctrl
      INTEGER(IntKi) :: n3, nc, k
      n3 = 3_IntKi*inst_e%ncp
      nc = 0_IntKi
      IF (ALLOCATED(u_ctrl%DeltaL)) nc = SIZE(u_ctrl%DeltaL)
      IF (ALLOCATED(other%commit_input)) THEN
         IF (SIZE(other%commit_input) /= 8_IntKi*n3 + 2_IntKi*nc) DEALLOCATE (other%commit_input)
      END IF
      IF (.NOT. ALLOCATED(other%commit_input)) ALLOCATE (other%commit_input(8_IntKi*n3 + 2_IntKi*nc))
      other%commit_input(1:n3) = RESHAPE(REAL(pos, DbKi), [n3])
      other%commit_input(n3 + 1:2*n3) = RESHAPE(REAL(vel, DbKi), [n3])
      other%commit_input(2*n3 + 1:3*n3) = RESHAPE(REAL(acc, DbKi), [n3])
      other%commit_input(3*n3 + 1:6*n3) = RESHAPE(REAL(orient, DbKi), [3*n3])
      other%commit_input(6*n3 + 1:7*n3) = RESHAPE(REAL(omega, DbKi), [n3])
      other%commit_input(7*n3 + 1:8*n3) = RESHAPE(REAL(alpha, DbKi), [n3])
      IF (nc > 0_IntKi) THEN
         k = 8_IntKi*n3
         other%commit_input(k + 1:k + nc) = REAL(u_ctrl%DeltaL, DbKi)
         other%commit_input(k + nc + 1:k + 2_IntKi*nc) = REAL(u_ctrl%DeltaLdot, DbKi)
      END IF
   END SUBROUTINE save_commit_input

   SUBROUTINE restore_commit_kinematics( inst_e, other, ErrStat, ErrMsg )
      !! The coupled kinematics of the last commit (save_commit_input) into the workspace.
      TYPE(CD_OF_Instance),     INTENT(INOUT) :: inst_e
      TYPE(CD_OtherStateType),  INTENT(IN   ) :: other
      INTEGER(IntKi),           INTENT(  OUT) :: ErrStat
      CHARACTER(*),             INTENT(  OUT) :: ErrMsg
      INTEGER(IntKi) :: ncp, n3
      ErrStat = ErrID_None
      ErrMsg = ''
      ncp = inst_e%ncp
      n3 = 3_IntKi*ncp
      IF (.NOT. ALLOCATED(other%commit_input)) THEN
         ErrStat = ErrID_Fatal
         ErrMsg = 'CableDyn mooring module: checkpoint rebuild: the checkpoint carries no committed input.'
         RETURN
      END IF
      IF (SIZE(other%commit_input) < 8_IntKi*n3) THEN
         ErrStat = ErrID_Fatal
         ErrMsg = 'CableDyn mooring module: checkpoint rebuild: the committed input does not match the coupled points.'
         RETURN
      END IF
      inst_e%ws_pos = RESHAPE(REAL(other%commit_input(1:n3), wp), [3, ncp])
      inst_e%ws_vel = RESHAPE(REAL(other%commit_input(n3 + 1:2*n3), wp), [3, ncp])
      inst_e%ws_acc = RESHAPE(REAL(other%commit_input(2*n3 + 1:3*n3), wp), [3, ncp])
      inst_e%ws_orient = RESHAPE(REAL(other%commit_input(3*n3 + 1:6*n3), wp), [3, 3, ncp])
      inst_e%ws_omega = RESHAPE(REAL(other%commit_input(6*n3 + 1:7*n3), wp), [3, ncp])
      inst_e%ws_alpha = RESHAPE(REAL(other%commit_input(7*n3 + 1:8*n3), wp), [3, ncp])
   END SUBROUTINE restore_commit_kinematics

   SUBROUTINE serve_committed_loads( inst_e, ErrStat, ErrMsg )
      !! A rebuild on the last glue step of a mooring interval reaches the solve with no
      !! CalcOutput since the commit, though the uninterrupted run evaluated the committed loads
      !! there and the load predictor shifts them. They are evaluated here, as CalcOutput does;
      !! the channels are not needed, as the advance that follows invalidates the cache.
      TYPE(CD_OF_Instance),     INTENT(INOUT) :: inst_e
      INTEGER(IntKi),           INTENT(  OUT) :: ErrStat
      CHARACTER(*),             INTENT(  OUT) :: ErrMsg
      INTEGER(IntKi) :: es
      CHARACTER(ErrMsgLen) :: em
      ErrStat = ErrID_None
      ErrMsg = ''
      CALL CD_AGG_CalcOutput( inst_e%agg, es, em )
      IF (es == CD_AGG_OK) &
         CALL CD_AGG_GetMovingPointMesh( inst_e%agg, inst_e%sv_pos, inst_e%sv_vel, inst_e%sv_acc, inst_e%ws_fld, &
                                         es, em, orientation=inst_e%sv_orient, moment=inst_e%ws_moment, &
                                         angular_velocity=inst_e%sv_omega, angular_acceleration=inst_e%sv_alpha )
      IF (es /= CD_AGG_OK) THEN
         ErrStat = ErrID_Fatal
         ErrMsg = 'CableDyn mooring module: committed loads of the restored state: '//TRIM(em)
         RETURN
      END IF
      inst_e%loads_cached = .TRUE.
      inst_e%loads_at_n = inst_e%last_solve_n
      inst_e%restored_unserved = .FALSE.
   END SUBROUTINE serve_committed_loads

   SUBROUTINE restore_calcoutput_probe( inst_e, m, ErrStat, ErrMsg )
      !! Restore every state surface after the output-probe
      !! overlay. This is used on both success and every post-overlay error exit.
      TYPE(CD_OF_Instance), INTENT(INOUT) :: inst_e
      TYPE(CD_MiscVarType), INTENT(INOUT) :: m
      INTEGER(IntKi), INTENT(OUT) :: ErrStat
      CHARACTER(*), INTENT(OUT) :: ErrMsg
      INTEGER(IntKi) :: es, ErrStat2
      CHARACTER(ErrMsgLen) :: em
      CHARACTER(ErrMsgLen) :: ErrMsg2

      ErrStat = ErrID_None
      ErrMsg = ''
      CALL CD_AGG_UpdateStates_Moving( inst_e%agg, inst_e%sv_pos, inst_e%sv_vel, inst_e%sv_acc, es, em, &
                                       output_probe=.TRUE., orientation=inst_e%sv_orient, &
                                       angular_velocity=inst_e%sv_omega, angular_acceleration=inst_e%sv_alpha )
      IF (es /= CD_AGG_OK) THEN
         CALL SetErrStat( ErrID_Fatal, 'CableDyn CalcOutput endpoint restore failed: '//TRIM(em), &
                          ErrStat, ErrMsg, 'restore_calcoutput_probe' )
      END IF
      CALL reload_interiors_ary( inst_e, m, inst_e%ws_msave, &
                                 REAL(MAX(inst_e%t_commit, 0.0_DbKi), wp), ErrStat2, ErrMsg2 )
      CALL SetErrStat( ErrStat2, ErrMsg2, ErrStat, ErrMsg, 'restore_calcoutput_probe' )
   END SUBROUTINE restore_calcoutput_probe

!----------------------------------------------------------------------------------------------------------------------------------
   SUBROUTINE CD_CalcContStateDeriv( t, u, p, x, xd, z, other, m, dxdt, ErrStat, ErrMsg )
      REAL(DbKi),                         INTENT(IN )    :: t
      TYPE(CD_InputType),                 INTENT(IN )    :: u
      TYPE(CD_ParameterType),             INTENT(IN )    :: p
      TYPE(CD_ContinuousStateType),       INTENT(IN )    :: x
      TYPE(CD_DiscreteStateType),         INTENT(IN )    :: xd
      TYPE(CD_ConstraintStateType),       INTENT(IN )    :: z
      TYPE(CD_OtherStateType),            INTENT(IN )    :: other
      TYPE(CD_MiscVarType),               INTENT(INOUT)  :: m
      TYPE(CD_ContinuousStateType),       INTENT(INOUT)  :: dxdt
      INTEGER(IntKi),                     INTENT( OUT)   :: ErrStat
      CHARACTER(*),                       INTENT( OUT)   :: ErrMsg

      character(*), parameter :: RoutineName = 'CD_CalcContStateDeriv'
      INTEGER(IntKi)          :: ErrStat2
      CHARACTER(ErrMsgLen)    :: ErrMsg2

      ErrStat = ErrID_None
      ErrMsg  = ''
      ! Only the linearization/GetOP paths reach this routine (the module marches implicitly
      ! through UpdateStates): dx/dt of the linearization states (lin_eval).
      IF (.NOT. Inst(m%CDInst)%lin_states) THEN
         CALL SetErrStat( ErrID_Fatal, 'CableDyn mooring module: continuous-state derivatives exist only '// &
                          'for a linearization run (Linearize = True).', ErrStat, ErrMsg, RoutineName )
         RETURN
      END IF
      CALL lin_eval( m%CDInst, p, m, u, x, ErrStat2, ErrMsg2, dxdt=dxdt )
      CALL SetErrStat( ErrStat2, ErrMsg2, ErrStat, ErrMsg, RoutineName )
   END SUBROUTINE CD_CalcContStateDeriv

!----------------------------------------------------------------------------------------------------------------------------------
   SUBROUTINE lin_state_map( inst_e, m, ErrStat, ErrMsg )
      !! The x%states mirror slots of the linearization states (CD_InitVars under Linearize): for
      !! every interior DOF of an EI = 0 line, every free DOF of a finite-EI cable and every free
      !! twist angle of a cable restrained in torsion, the slot of its position, of its velocity
      !! and of its acceleration (lin_pos, lin_vel, lin_acc), and the mirror buffers of lin_eval.
      TYPE(CD_OF_Instance), INTENT(INOUT) :: inst_e
      TYPE(CD_MiscVarType), INTENT(IN)    :: m
      INTEGER(IntKi),       INTENT(OUT)   :: ErrStat
      CHARACTER(*),         INTENT(OUT)   :: ErrMsg
      INTEGER(IntKi) :: il, ic, ndofl, nin, nf, csz, koff, n, k, j, es, n1, k1, kind, ntw
      CHARACTER(ErrMsgLen) :: em
      LOGICAL, ALLOCATABLE :: mask(:)
      INTEGER, ALLOCATABLE :: tw_p(:), tw_r(:), tw_a(:), tw_n(:)

      ErrStat = ErrID_None
      ErrMsg  = ''
      n = 0
      DO il = 1, inst_e%nlines
         ndofl = CD_System_Line_NDOF( inst_e%agg%sys%fast%system, il, es, em )
         IF (es /= CD_SYSTEM_OK) THEN
            CALL SetErrStat( ErrID_Fatal, TRIM(em), ErrStat, ErrMsg, 'lin_state_map' ); RETURN
         END IF
         n = n + ndofl - 6
      END DO
      DO ic = 1, inst_e%agg%ncable
         IF (CD_HFMF_MirrorSize( inst_e%agg%cables(ic) ) <= 0) CYCLE
         n = n + COUNT(inst_e%agg%cables(ic)%line%freemask) + CD_HFMF_Twist_Lin_Count( inst_e%agg%cables(ic) )
      END DO
      ! the constitutive states: every viscoelastic and Syrope element, the per-element tail
      ! after the line's interior block (as pack_state_mirror)
      n1 = 0
      DO il = 1, inst_e%nlines
         n1 = n1 + COUNT(lin1_element(il, LIN1_VE)) + COUNT(lin1_element(il, LIN1_SYROPE))
      END DO
      IF (ALLOCATED(inst_e%lin1_slot)) DEALLOCATE (inst_e%lin1_slot, inst_e%lin1_line, inst_e%lin1_elem, &
                                                   inst_e%lin1_kind)
      ALLOCATE (inst_e%lin1_slot(n1), inst_e%lin1_line(n1), inst_e%lin1_elem(n1), inst_e%lin1_kind(n1), STAT=es)
      IF (es /= 0) THEN
         CALL SetErrStat( ErrID_Fatal, 'Could not allocate the linearization state map.', ErrStat, ErrMsg, &
                          'lin_state_map' ); RETURN
      END IF
      k1 = 0
      DO il = 1, inst_e%nlines
         nin = CD_System_Line_NDOF( inst_e%agg%sys%fast%system, il, es, em ) - 6
         DO kind = LIN1_VE, LIN1_SYROPE
            mask = lin1_element(il, kind)
            DO j = 1, SIZE(mask)
               IF (.NOT. mask(j)) CYCLE
               k1 = k1 + 1
               inst_e%lin1_slot(k1) = m%LineStateIs1(il) + 3*nin + j - 1
               inst_e%lin1_line(k1) = il
               inst_e%lin1_elem(k1) = j
               inst_e%lin1_kind(k1) = kind
            END DO
         END DO
      END DO
      IF (ALLOCATED(inst_e%lin_pos)) DEALLOCATE (inst_e%lin_pos, inst_e%lin_vel, inst_e%lin_acc)
      IF (ALLOCATED(inst_e%ws_lsave)) DEALLOCATE (inst_e%ws_lsave, inst_e%ws_lwork)
      ALLOCATE (inst_e%lin_pos(n), inst_e%lin_vel(n), inst_e%lin_acc(n), inst_e%ws_lsave(m%Nx), &
                inst_e%ws_lwork(m%Nx), STAT=es)
      IF (es /= 0) THEN
         CALL SetErrStat( ErrID_Fatal, 'Could not allocate the linearization state map.', ErrStat, ErrMsg, &
                          'lin_state_map' ); RETURN
      END IF
      ! a mooring line's interior block is [v; r; a], 3 (N - 1) each, at LineStateIs1
      k = 0
      DO il = 1, inst_e%nlines
         ndofl = CD_System_Line_NDOF( inst_e%agg%sys%fast%system, il, es, em )
         nin = ndofl - 6
         DO j = 0, nin - 1
            k = k + 1
            inst_e%lin_vel(k) = m%LineStateIs1(il) + j
            inst_e%lin_pos(k) = m%LineStateIs1(il) + nin + j
            inst_e%lin_acc(k) = m%LineStateIs1(il) + 2*nin + j
         END DO
      END DO
      ! a cable's mirror starts [v_free; q_free; a_free], after the mooring block
      koff = 0
      IF (inst_e%nlines > 0) koff = m%LineStateIsN(inst_e%nlines)
      DO ic = 1, inst_e%agg%ncable
         csz = CD_HFMF_MirrorSize( inst_e%agg%cables(ic) )
         IF (csz <= 0) CYCLE
         nf = COUNT(inst_e%agg%cables(ic)%line%freemask)
         DO j = 1, nf
            k = k + 1
            inst_e%lin_vel(k) = koff + j
            inst_e%lin_pos(k) = koff + nf + j
            inst_e%lin_acc(k) = koff + 2*nf + j
         END DO
         koff = koff + csz
      END DO
      ! the nodal twist of a cable restrained in torsion: each free node's angle phi, its rate and
      ! its acceleration, in the cable's torsion tail (CD_HFMF_Twist_Lin_Slots)
      koff = 0
      IF (inst_e%nlines > 0) koff = m%LineStateIsN(inst_e%nlines)
      DO ic = 1, inst_e%agg%ncable
         csz = CD_HFMF_MirrorSize( inst_e%agg%cables(ic) )
         IF (csz <= 0) CYCLE
         ntw = CD_HFMF_Twist_Lin_Count( inst_e%agg%cables(ic) )
         IF (ntw > 0) THEN
            ALLOCATE (tw_p(ntw), tw_r(ntw), tw_a(ntw), tw_n(ntw))
            CALL CD_HFMF_Twist_Lin_Slots( inst_e%agg%cables(ic), tw_p, tw_r, tw_a, tw_n, es, em )
            IF (es /= CD_HFMF_OK) THEN
               CALL SetErrStat( ErrID_Fatal, 'CableDyn mooring module: cable '//TRIM(Num2LStr(ic))//': '// &
                                TRIM(em), ErrStat, ErrMsg, 'lin_state_map' ); RETURN
            END IF
            DO j = 1, ntw
               k = k + 1
               inst_e%lin_pos(k) = koff + tw_p(j)
               inst_e%lin_vel(k) = koff + tw_r(j)
               inst_e%lin_acc(k) = koff + tw_a(j)
            END DO
            DEALLOCATE (tw_p, tw_r, tw_a, tw_n)
         END IF
         koff = koff + csz
      END DO
      inst_e%lin_states = .TRUE.

   CONTAINS

      FUNCTION lin1_element(il_, kind_) RESULT(msk)
         !! The elements of line il_ carrying a constitutive state of kind kind_.
         INTEGER(IntKi), INTENT(IN) :: il_, kind_
         LOGICAL, ALLOCATABLE :: msk(:)
         msk = lin1_mask( inst_e, il_, kind_ )
      END FUNCTION lin1_element
   END SUBROUTINE lin_state_map

   FUNCTION lin1_mask( inst_, il, kind ) RESULT(msk)
      !! The elements of EI = 0 line il that carry a first-order linearization state of the kind:
      !! viscoelastic (ElasticMod 2/3) elements for LIN1_VE, Syrope elements for LIN1_SYROPE.
      TYPE(CD_OF_Instance), INTENT(IN) :: inst_
      INTEGER(IntKi),       INTENT(IN) :: il, kind
      LOGICAL, ALLOCATABLE :: msk(:)
      ASSOCIATE (ln => inst_%agg%sys%fast%system%lines(il))
         ALLOCATE (msk(ln%n_elem))
         msk = .FALSE.
         IF (kind == LIN1_VE .AND. ln%has_viscoelastic) msk = ln%ve_mode /= 0
         IF (kind == LIN1_SYROPE .AND. ln%has_syrope) msk = ln%syrope_is
      END ASSOCIATE
   END FUNCTION lin1_mask

   SUBROUTINE lin_disp_step( inst_, dx, ErrStat, ErrMsg )
      !! The coupled-point displacement step of the linearization, as MoorDyn-F's: half the
      !! smallest positive element stretch of the EI = 0 lines, at most dx on entry. A larger
      !! step would slacken a tension-only element on one side of the central difference (a
      !! taut chain stretches about a centimetre per element) and halve its stiffness.
      TYPE(CD_OF_Instance),  INTENT(IN)    :: inst_
      REAL(R8Ki),            INTENT(INOUT) :: dx
      INTEGER(IntKi),        INTENT(OUT)   :: ErrStat
      CHARACTER(*),          INTENT(OUT)   :: ErrMsg

      INTEGER(IntKi)        :: il, ne, es
      CHARACTER(ErrMsgLen)  :: em
      REAL(wp), ALLOCATABLE :: stretch(:)

      ErrStat = ErrID_None
      ErrMsg  = ''
      DO il = 1, inst_%nlines
         ne = CD_System_Line_NElem( inst_%agg%sys%fast%system, il, es, em )
         IF (es == CD_SYSTEM_OK) THEN
            ALLOCATE (stretch(ne))
            CALL CD_Get_System_Line_Stretch( inst_%agg%sys%fast%system, il, stretch, es, em )
         END IF
         IF (es /= CD_SYSTEM_OK) THEN
            CALL SetErrStat( ErrID_Fatal, 'CableDyn mooring module: line '//TRIM(Num2LStr(il))//': '// &
                             TRIM(em), ErrStat, ErrMsg, 'CableDyn:lin_disp_step' ); RETURN
         END IF
         IF (ANY(stretch > 0.0_wp)) dx = MIN(dx, 0.5_R8Ki*REAL(MINVAL(stretch, MASK=stretch > 0.0_wp), R8Ki))
         DEALLOCATE (stretch)
      END DO
   END SUBROUTINE lin_disp_step

!----------------------------------------------------------------------------------------------------------------------------------
   SUBROUTINE lin_eval( id, p, m, u, x_in, ErrStat, ErrMsg, dxdt, y_out )
      !! The linearization surface at the state x_in and input u: the line interiors and cable
      !! free DOFs take x_in's positions and velocities, the coupled points u's kinematics, and the
      !! accelerations are solved from them without a time step. dxdt gets dx/dt of the
      !! linearization states (each position slot its velocity, each velocity slot its
      !! acceleration; the other slots 0); y_out the loads on the coupled points and the deck
      !! channels at that state. The committed state is restored on exit.
      INTEGER(IntKi),                 INTENT(IN   ) :: id
      TYPE(CD_ParameterType),         INTENT(IN   ) :: p
      TYPE(CD_MiscVarType),           INTENT(INOUT) :: m
      TYPE(CD_InputType),             INTENT(IN   ) :: u
      TYPE(CD_ContinuousStateType),   INTENT(IN   ) :: x_in
      INTEGER(IntKi),                 INTENT(  OUT) :: ErrStat
      CHARACTER(*),                   INTENT(  OUT) :: ErrMsg
      TYPE(CD_ContinuousStateType),   INTENT(INOUT), OPTIONAL :: dxdt
      TYPE(CD_OutputType),            INTENT(INOUT), OPTIONAL :: y_out

      character(*), parameter :: RoutineName = 'CableDyn:lin_eval'
      INTEGER(IntKi)          :: ErrStat2, es, i, ic, il, ne, k
      REAL(wp), ALLOCATABLE   :: ve_rate(:), syr_rate(:)
      CHARACTER(ErrMsgLen)    :: ErrMsg2, em
      REAL(wp)                :: cval, t_clock

      ErrStat = ErrID_None
      ErrMsg  = ''
      t_clock = REAL(MAX(Inst(id)%t_commit, 0.0_DbKi), wp)
      ! the committed state: the coupled kinematics and the whole mirror
      CALL CD_AGG_GetMovingPointMesh( Inst(id)%agg, Inst(id)%sv_pos, Inst(id)%sv_vel, Inst(id)%sv_acc, &
                                      Inst(id)%ws_fld, es, em, orientation=Inst(id)%sv_orient, &
                                      angular_velocity=Inst(id)%sv_omega, angular_acceleration=Inst(id)%sv_alpha, &
                                      cable_loads=.FALSE. )
      IF (es /= CD_AGG_OK) THEN
         CALL SetErrStat( ErrID_Fatal, 'CableDyn mooring module: '//TRIM(em), ErrStat, ErrMsg, RoutineName ); RETURN
      END IF
      CALL pack_state_mirror_ary( Inst(id), m, Inst(id)%ws_lsave, ErrStat2, ErrMsg2 )
      CALL SetErrStat( ErrStat2, ErrMsg2, ErrStat, ErrMsg, RoutineName )
      IF (ErrStat >= AbortErrLev) RETURN
      ! the state: x_in's positions and velocities in the committed mirror
      Inst(id)%ws_lwork = Inst(id)%ws_lsave
      Inst(id)%ws_lwork(Inst(id)%lin_pos) = x_in%states(Inst(id)%lin_pos)
      Inst(id)%ws_lwork(Inst(id)%lin_vel) = x_in%states(Inst(id)%lin_vel)
      Inst(id)%ws_lwork(Inst(id)%lin1_slot) = x_in%states(Inst(id)%lin1_slot)
      CALL reload_interiors_ary( Inst(id), m, Inst(id)%ws_lwork, t_clock, ErrStat2, ErrMsg2 )
      CALL SetErrStat( ErrStat2, ErrMsg2, ErrStat, ErrMsg, RoutineName )
      IF (ErrStat >= AbortErrLev) THEN
         CALL restore; RETURN
      END IF
      ! the input: the coupled points move to u, and the accelerations follow (the EI = 0 lines
      ! in the non-probe update, the cables by their refresh). The orientation of a cable's
      ! coupled point turns its parent-attached torsion end frame (CD_HFMF_SetCoupledKinematics):
      ! the condensed torque (Phi - Theta)/C and a nodal twist's end element are then evaluated
      ! with the turned frame, and the frame takes the point's angular velocity and acceleration
      ! (CD_HFMF_Set_Twist_Frame_Rates: the torsional damping and the held section's inertia)
      CALL mesh_to_arrays( u%CoupledKinematics(1), Inst(id)%ncp, Inst(id)%ws_pos, Inst(id)%ws_vel, &
                           Inst(id)%ws_acc, Inst(id)%ws_orient, Inst(id)%ws_omega, Inst(id)%ws_alpha, &
                           ErrStat2, ErrMsg2 )
      CALL SetErrStat( ErrStat2, ErrMsg2, ErrStat, ErrMsg, RoutineName )
      IF (ErrStat >= AbortErrLev) THEN
         CALL restore; RETURN
      END IF
      CALL CD_AGG_UpdateStates_Moving( Inst(id)%agg, Inst(id)%ws_pos, Inst(id)%ws_vel, Inst(id)%ws_acc, es, em, &
                                       output_probe=.FALSE., orientation=Inst(id)%ws_orient, &
                                       angular_velocity=Inst(id)%ws_omega, angular_acceleration=Inst(id)%ws_alpha )
      IF (es /= CD_AGG_OK) THEN
         CALL SetErrStat( ErrID_Fatal, 'CableDyn mooring module: '//TRIM(em), ErrStat, ErrMsg, RoutineName )
         CALL restore; RETURN
      END IF
      ! (The operating-point outputs of the .lin file come from CD_CalcOutput, which keeps the
      ! committed state's accelerations and the end-frame rates of its last step's turn; at a
      ! settled operating point, such as the still-water start the documentation prescribes,
      ! they are those of this surface, and the matrices are differences of this surface alone.)
      DO ic = 1, Inst(id)%agg%ncable
         CALL CD_HFMF_Set_Twist_Frame_Rates( Inst(id)%agg%cables(ic), es, em )
         IF (es /= CD_HFMF_OK) THEN
            CALL SetErrStat( ErrID_Fatal, 'CableDyn mooring module: cable '//TRIM(Num2LStr(ic))// &
                             ' torsion end-frame rates: '//TRIM(em), ErrStat, ErrMsg, RoutineName )
            CALL restore; RETURN
         END IF
         CALL CD_HFMF_Refresh_Acceleration( Inst(id)%agg%cables(ic), es, em )
         IF (es /= CD_HFMF_OK) THEN
            CALL SetErrStat( ErrID_Fatal, 'CableDyn mooring module: cable '//TRIM(Num2LStr(ic))// &
                             ' acceleration: '//TRIM(em), ErrStat, ErrMsg, RoutineName )
            CALL restore; RETURN
         END IF
      END DO
      IF (PRESENT(dxdt)) THEN
         CALL pack_state_mirror_ary( Inst(id), m, Inst(id)%ws_lwork, ErrStat2, ErrMsg2 )
         CALL SetErrStat( ErrStat2, ErrMsg2, ErrStat, ErrMsg, RoutineName )
         IF (ErrStat >= AbortErrLev) THEN
            CALL restore; RETURN
         END IF
         dxdt%states = 0.0_R8Ki
         dxdt%states(Inst(id)%lin_pos) = Inst(id)%ws_lwork(Inst(id)%lin_vel)
         dxdt%states(Inst(id)%lin_vel) = Inst(id)%ws_lwork(Inst(id)%lin_acc)
         ! the constitutive states' rates at this state (the instantaneous element laws)
         DO il = 1, Inst(id)%nlines
            IF (.NOT. ANY(Inst(id)%lin1_line == il)) CYCLE
            ne = CD_System_Line_NElem( Inst(id)%agg%sys%fast%system, il, es, em )
            ALLOCATE (ve_rate(ne), syr_rate(ne))
            CALL CD_Get_System_Line_Internal_Rates( Inst(id)%agg%sys%fast%system, il, ve_rate, syr_rate, es, em )
            IF (es /= CD_SYSTEM_OK) THEN
               CALL SetErrStat( ErrID_Fatal, 'CableDyn mooring module: '//TRIM(em), ErrStat, ErrMsg, RoutineName )
               CALL restore; RETURN
            END IF
            DO k = 1, SIZE(Inst(id)%lin1_slot)
               IF (Inst(id)%lin1_line(k) /= il) CYCLE
               IF (Inst(id)%lin1_kind(k) == LIN1_VE) THEN
                  dxdt%states(Inst(id)%lin1_slot(k)) = REAL(ve_rate(Inst(id)%lin1_elem(k)), R8Ki)
               ELSE
                  dxdt%states(Inst(id)%lin1_slot(k)) = REAL(syr_rate(Inst(id)%lin1_elem(k)), R8Ki)
               END IF
            END DO
            DEALLOCATE (ve_rate, syr_rate)
         END DO
      END IF
      IF (PRESENT(y_out)) THEN
         CALL CD_AGG_CalcOutput( Inst(id)%agg, es, em )
         IF (es == CD_AGG_OK) CALL CD_AGG_GetMovingPointMesh( Inst(id)%agg, Inst(id)%ws_pos, Inst(id)%ws_vel, &
                                                              Inst(id)%ws_acc, Inst(id)%ws_fld, es, em, &
                                                              orientation=Inst(id)%ws_orient, &
                                                              moment=Inst(id)%ws_moment, &
                                                              angular_velocity=Inst(id)%ws_omega, &
                                                              angular_acceleration=Inst(id)%ws_alpha )
         IF (es /= CD_AGG_OK) THEN
            CALL SetErrStat( ErrID_Fatal, 'CableDyn mooring module: '//TRIM(em), ErrStat, ErrMsg, RoutineName )
            CALL restore; RETURN
         END IF
         IF (ALLOCATED(Inst(id)%lin_fld)) THEN
            IF (SIZE(Inst(id)%lin_fld, 2) /= Inst(id)%ncp .OR. SIZE(Inst(id)%lin_chan) /= p%NumOuts) &
               DEALLOCATE (Inst(id)%lin_fld, Inst(id)%lin_moment, Inst(id)%lin_chan)
         END IF
         IF (.NOT. ALLOCATED(Inst(id)%lin_fld)) &
            ALLOCATE (Inst(id)%lin_fld(3, Inst(id)%ncp), Inst(id)%lin_moment(3, Inst(id)%ncp), &
                      Inst(id)%lin_chan(p%NumOuts))
         DO i = 1, Inst(id)%ncp
            y_out%CoupledLoads(1)%Force(:, i) = REAL(Inst(id)%ws_fld(:, i), ReKi)
            y_out%CoupledLoads(1)%Moment(:, i) = REAL(Inst(id)%ws_moment(:, i), ReKi)
            Inst(id)%lin_fld(:, i) = Inst(id)%ws_fld(:, i)
            Inst(id)%lin_moment(:, i) = Inst(id)%ws_moment(:, i)
         END DO
         DO i = 1, p%NumOuts
            CALL CD_AGG_EvalChannel( Inst(id)%agg, i, cval, es, em )
            IF (es /= CD_AGG_OK) THEN
               CALL SetErrStat( ErrID_Fatal, 'CableDyn mooring module: output channel evaluation failed: '// &
                                TRIM(em), ErrStat, ErrMsg, RoutineName )
               CALL restore; RETURN
            END IF
            y_out%WriteOutput(i) = REAL(cval, ReKi)
            Inst(id)%lin_chan(i) = cval
         END DO
      END IF
      CALL restore

   CONTAINS

      SUBROUTINE restore()
         !! The committed coupled kinematics and mirror back; the held loads are re-evaluated.
         CALL CD_AGG_UpdateStates_Moving( Inst(id)%agg, Inst(id)%sv_pos, Inst(id)%sv_vel, Inst(id)%sv_acc, es, em, &
                                          output_probe=.TRUE., orientation=Inst(id)%sv_orient, &
                                          angular_velocity=Inst(id)%sv_omega, angular_acceleration=Inst(id)%sv_alpha )
         IF (es /= CD_AGG_OK) CALL SetErrStat( ErrID_Fatal, 'CableDyn linearization restore failed: '//TRIM(em), &
                                               ErrStat, ErrMsg, RoutineName )
         CALL reload_interiors_ary( Inst(id), m, Inst(id)%ws_lsave, t_clock, ErrStat2, ErrMsg2 )
         CALL SetErrStat( ErrStat2, ErrMsg2, ErrStat, ErrMsg, RoutineName )
         Inst(id)%loads_cached = .FALSE.
      END SUBROUTINE restore
   END SUBROUTINE lin_eval

   SUBROUTINE pack_lin_outputs( id, Vars, y_lin, ValAry )
      !! The outputs of the last lin_eval packed as CD_VarsPackOutput packs y_lin, with the
      !! coupled loads and the deck channels taken from lin_eval's double-precision copies: the
      !! central differences of the loads over a 1 um position step resolve the stiffness of a
      !! fairlead carrying a few MN in every build, the single-precision one included, where
      !! the ReKi mesh carries 7 digits (the stiffness of the IEA-15 MW UMaine chains read 3.2e3
      !! instead of 7.7e4 N/m in surge). The other outputs (visualisation meshes) keep y_lin's.
      INTEGER(IntKi),         INTENT(IN   ) :: id
      TYPE(ModVarsType),      INTENT(IN   ) :: Vars
      TYPE(CD_OutputType),    INTENT(IN   ) :: y_lin
      REAL(R8Ki),             INTENT(INOUT) :: ValAry(:)
      INTEGER(IntKi)                        :: i, n
      CALL CD_VarsPackOutput( Vars, y_lin, ValAry )
      IF (.NOT. ALLOCATED(Inst(id)%lin_fld)) RETURN
      DO i = 1, SIZE(Vars%y)
         n = Vars%y(i)%iLoc(2) - Vars%y(i)%iLoc(1) + 1
         SELECT CASE (Vars%y(i)%DL%Num)
         CASE (CD_y_CoupledLoads)
            IF (Vars%y(i)%DL%i1 /= 1 .OR. n /= SIZE(Inst(id)%lin_fld)) CYCLE
            IF (Vars%y(i)%Field == FieldForce) THEN
               ValAry(Vars%y(i)%iLoc(1):Vars%y(i)%iLoc(2)) = PACK(REAL(Inst(id)%lin_fld, R8Ki), .TRUE.)
            ELSE IF (Vars%y(i)%Field == FieldMoment) THEN
               ValAry(Vars%y(i)%iLoc(1):Vars%y(i)%iLoc(2)) = PACK(REAL(Inst(id)%lin_moment, R8Ki), .TRUE.)
            END IF
         CASE (CD_y_WriteOutput)
            IF (Vars%y(i)%iLB < 1 .OR. Vars%y(i)%iUB > SIZE(Inst(id)%lin_chan) .OR. &
                n /= Vars%y(i)%iUB - Vars%y(i)%iLB + 1) CYCLE
            ValAry(Vars%y(i)%iLoc(1):Vars%y(i)%iLoc(2)) = REAL(Inst(id)%lin_chan(Vars%y(i)%iLB:Vars%y(i)%iUB), R8Ki)
         END SELECT
      END DO
   END SUBROUTINE pack_lin_outputs

!----------------------------------------------------------------------------------------------------------------------------------
   SUBROUTINE CD_End(u, p, x, xd, z, other, y, m, ErrStat , ErrMsg)
      USE, INTRINSIC :: ISO_FORTRAN_ENV, ONLY: int64
      TYPE(CD_InputType) ,            INTENT(INOUT) :: u
      TYPE(CD_ParameterType) ,        INTENT(INOUT) :: p
      TYPE(CD_ContinuousStateType) ,  INTENT(INOUT) :: x
      TYPE(CD_DiscreteStateType) ,    INTENT(INOUT) :: xd
      TYPE(CD_ConstraintStateType) ,  INTENT(INOUT) :: z
      TYPE(CD_OtherStateType) ,       INTENT(INOUT) :: other
      TYPE(CD_OutputType) ,           INTENT(INOUT) :: y
      TYPE(CD_MiscVarType),           INTENT(INOUT) :: m
      INTEGER(IntKi),                 INTENT(  OUT) :: ErrStat
      CHARACTER(*),                   INTENT(  OUT) :: ErrMsg

      character(*), parameter :: RoutineName = 'CD_End'
      INTEGER(IntKi)          :: ErrStat2
      INTEGER                 :: hn_step, hn_resid, hn_solve, hn_am, hn_alloc, hn_tan, hn_factor, hn_correct
      INTEGER(int64)          :: sb_calls, sb_events, sb_capped, sb_fallbacks
      INTEGER(int64)          :: k_calls(CD_PROF_NKERNEL)
      REAL(wp)                :: k_seconds(CD_PROF_NKERNEL), ht_factor
      CHARACTER(24)           :: k_txt(CD_PROF_NKERNEL)
      REAL(wp)                :: ht_asm(HC_ASM_NSEC)
      CHARACTER(:), ALLOCATABLE :: asm_txt
      INTEGER                 :: k_i
      INTEGER                 :: sb_max, sb_ios
      INTEGER(IntKi)          :: range_es
      CHARACTER(ErrMsgLen)    :: range_em
      CHARACTER(24)           :: sb_txt(5)
      REAL(wp)                :: ht_step, ht_resid, ht_eff, ht_solve, ht_am, ht_tan
      CHARACTER(ErrMsgLen)    :: ErrMsg2

      ErrStat = ErrID_None
      ErrMsg  = ''

      IF (ALLOCATED(Inst)) THEN
         IF (m%CDInst >= 1 .AND. m%CDInst <= SIZE(Inst)) THEN
            IF (Inst(m%CDInst)%active) THEN
               ! The range graphs cover the whole run, so a run that ended on an error writes none
               ! (as the standalone driver, which writes them on completion). The glue comes here
               ! after an abort too, so the host says which it was (m%HostComplete): a run can also
               ! complete before TMax, on CalcSteady or at FAST.Farm's last whole DT_Low. A process
               ! that only restored a checkpoint and stepped nothing (-VTKLin) leaves the file as it is.
               IF (Inst(m%CDInst)%range_on) THEN
                  IF (.NOT. m%HostComplete) THEN
                     CALL WrScr( '   CableDyn: the run stopped on an error at t = '// &
                                 TRIM(Num2LStr(Inst(m%CDInst)%t_commit))//' s: no range graph is written.' )
                  ELSE IF (Inst(m%CDInst)%range_sampled) THEN
                     CALL CD_AGG_Range_Write( Inst(m%CDInst)%agg, TRIM(p%RootName), range_es, range_em )
                     IF (range_es /= CD_AGG_OK) CALL SetErrStat( ErrID_Fatal, 'CableDyn mooring module: '// &
                                                                 TRIM(range_em), ErrStat, ErrMsg, RoutineName )
                  END IF
               END IF
               ! the rotation- and snap-resolved sub-steps of the EI=0 lines (ei0_substeps), as the
               ! standalone driver reports them
               CALL CD_AGG_Get_Substep_Counts( Inst(m%CDInst)%agg, sb_calls, sb_events, sb_max, sb_capped, &
                                               sb_fallbacks )
               IF (sb_events > 0 .OR. sb_fallbacks > 0) THEN
                  ! 64-bit counts, written here (Num2LStr takes the default integer kind)
                  WRITE (sb_txt(1), '(I0)', IOSTAT=sb_ios) sb_events
                  WRITE (sb_txt(2), '(I0)', IOSTAT=sb_ios) sb_calls
                  WRITE (sb_txt(3), '(I0)', IOSTAT=sb_ios) sb_max
                  WRITE (sb_txt(4), '(I0)', IOSTAT=sb_ios) sb_capped
                  WRITE (sb_txt(5), '(I0)', IOSTAT=sb_ios) sb_fallbacks
                  CALL WrScr( '   CableDyn: ei0_substeps auto solved '//TRIM(sb_txt(1))//' of the '// &
                              TRIM(sb_txt(2))//' EI = 0 line step(s) it examined in sub-steps (at most '// &
                              TRIM(sb_txt(3))//' sub-steps per step); '//TRIM(sb_txt(4))// &
                              ' needed more than ei0_substep_max; '//TRIM(sb_txt(5))// &
                              ' kept the whole step after a sub-step did not converge.' )
               END IF
               IF (Inst(m%CDInst)%prof_enabled) THEN
                  CALL WrScr( '    CableDyn profile: init_s='// &
                              TRIM(Num2LStr(REAL(Inst(m%CDInst)%prof_t_init, DbKi)))// &
                              ' update_s='//TRIM(Num2LStr(REAL(Inst(m%CDInst)%prof_t_update, DbKi)))// &
                              ' wave_s='//TRIM(Num2LStr(REAL(Inst(m%CDInst)%prof_t_wave, DbKi)))// &
                              ' step_s='//TRIM(Num2LStr(REAL(Inst(m%CDInst)%prof_t_step, DbKi))) )
                  CALL WrScr( '    CableDyn profile: calcout_s='// &
                              TRIM(Num2LStr(REAL(Inst(m%CDInst)%prof_t_calcout, DbKi)))// &
                              ' loads_s='//TRIM(Num2LStr(REAL(Inst(m%CDInst)%prof_t_loads, DbKi)))// &
                              ' native_io_s='//TRIM(Num2LStr(REAL(Inst(m%CDInst)%prof_t_native, DbKi))) )
                  CALL WrScr( '    CableDyn profile parts: overlay_s='// &
                              TRIM(Num2LStr(REAL(Inst(m%CDInst)%prof_t_overlay, DbKi)))// &
                              ' channels_s='//TRIM(Num2LStr(REAL(Inst(m%CDInst)%prof_t_channels, DbKi)))// &
                              ' restore_s='//TRIM(Num2LStr(REAL(Inst(m%CDInst)%prof_t_restore, DbKi)))// &
                              ' wave_kin_s='//TRIM(Num2LStr(REAL(Inst(m%CDInst)%prof_t_wave_kin, DbKi)))// &
                              ' wave_check_s='//TRIM(Num2LStr(REAL(Inst(m%CDInst)%prof_t_wave_check, DbKi)))// &
                              ' wave_set_s='//TRIM(Num2LStr(REAL(Inst(m%CDInst)%prof_t_wave_set, DbKi))) )
                  CALL WrScr( '    CableDyn profile counts: update='// &
                              TRIM(Num2LStr(Inst(m%CDInst)%prof_n_update))// &
                              ' solve='//TRIM(Num2LStr(Inst(m%CDInst)%prof_n_solve))// &
                              ' wave='//TRIM(Num2LStr(Inst(m%CDInst)%prof_n_wave))// &
                              ' calcout='//TRIM(Num2LStr(Inst(m%CDInst)%prof_n_calcout))// &
                              ' fresh='//TRIM(Num2LStr(Inst(m%CDInst)%prof_n_fresh)) )
                  ! the kernels of the EI = 0 line steps (summed over the lines)
                  CALL CD_Profile_Kernels(k_calls, k_seconds)
                  IF (SUM(k_calls) > 0_int64) THEN
                     DO k_i = 1, CD_PROF_NKERNEL
                        WRITE (k_txt(k_i), '(I0)', IOSTAT=sb_ios) k_calls(k_i)
                     END DO
                     CALL WrScr( '    CableDyn EI = 0 profile: residual_s='// &
                                 TRIM(Num2LStr(REAL(k_seconds(CD_PROF_K_RESIDUAL), DbKi)))// &
                                 ' tangent_s='//TRIM(Num2LStr(REAL(k_seconds(CD_PROF_K_TANGENT), DbKi)))// &
                                 ' factor_s='//TRIM(Num2LStr(REAL(k_seconds(CD_PROF_K_FACTOR), DbKi)))// &
                                 ' backsolve_s='//TRIM(Num2LStr(REAL(k_seconds(CD_PROF_K_SOLVE), DbKi))) )
                     CALL WrScr( '    CableDyn EI = 0 counts: residual='//TRIM(k_txt(CD_PROF_K_RESIDUAL))// &
                                 ' tangent='//TRIM(k_txt(CD_PROF_K_TANGENT))// &
                                 ' factor='//TRIM(k_txt(CD_PROF_K_FACTOR))// &
                                 ' backsolve='//TRIM(k_txt(CD_PROF_K_SOLVE)) )
                  END IF
                  IF (Inst(m%CDInst)%agg%ncable > 0) THEN
                     CALL CD_HermiteCable_Dyn_Get_Profile(hn_step, hn_resid, hn_solve, hn_am, hn_alloc, &
                                                          ht_step, ht_resid, ht_eff, ht_solve, ht_am, &
                                                          hn_tan, ht_tan, hn_factor, ht_factor, hn_correct)
                     CALL WrScr( '    CableDyn Hermite profile: step_s='//TRIM(Num2LStr(REAL(ht_step, DbKi)))// &
                                 ' residual_s='//TRIM(Num2LStr(REAL(ht_resid, DbKi)))// &
                                 ' tangent_s='//TRIM(Num2LStr(REAL(ht_tan, DbKi)))// &
                                 ' effective_s='//TRIM(Num2LStr(REAL(ht_eff, DbKi)))// &
                                 ' factor_s='//TRIM(Num2LStr(REAL(ht_factor, DbKi)))// &
                                 ' backsolve_s='//TRIM(Num2LStr(REAL(ht_solve, DbKi)))// &
                                 ' added_mass_s='//TRIM(Num2LStr(REAL(ht_am, DbKi))) )
                     CALL WrScr( '    CableDyn Hermite counts: step='//TRIM(Num2LStr(hn_step))// &
                                 ' residual='//TRIM(Num2LStr(hn_resid))// &
                                 ' tangent='//TRIM(Num2LStr(hn_tan))// &
                                 ' factor='//TRIM(Num2LStr(hn_factor))// &
                                 ' solve='//TRIM(Num2LStr(hn_solve))// &
                                 ' correction='//TRIM(Num2LStr(hn_correct))// &
                                 ' added_mass='//TRIM(Num2LStr(hn_am))// &
                                 ' alloc='//TRIM(Num2LStr(hn_alloc)) )
                     CALL WrScr( '    CableDyn Hermite recoveries: intervals='// &
                                 TRIM(Num2LStr(CD_HermiteCable_Dyn_Recovery_Count())) )
                     ! the residual and tangent assemblies split into their sections
                     CALL CD_HermiteCable_Dyn_Get_Assembly_Profile(ht_asm)
                     asm_txt = '    CableDyn Hermite assembly:'
                     DO k_i = 1, HC_ASM_NSEC
                        asm_txt = asm_txt//' '//TRIM(HC_ASM_KEYS(k_i))//'_s='// &
                                  TRIM(Num2LStr(REAL(ht_asm(k_i), DbKi)))
                     END DO
                     CALL WrScr( asm_txt )
                  END IF
               END IF
               ! Propagate a teardown failure as SEVERE (not fatal): the glue's End path
               ! aggregates statuses and continues cleanup; swallowing it would hide it.
               CALL release_instance( m%CDInst, ErrStat2, ErrMsg2 )
               IF (ErrStat2 /= ErrID_None) CALL SetErrStat( ErrID_Severe, TRIM(ErrMsg2), ErrStat, ErrMsg, RoutineName )
            END IF
         END IF
      END IF

      ! Framework cleanup of everything the registry types allocated.
      CALL CD_DestroyInput( u, ErrStat2, ErrMsg2 )
      CALL SetErrStat(ErrStat2, ErrMsg2, ErrStat, ErrMsg, RoutineName)
      CALL CD_DestroyParam( p, ErrStat2, ErrMsg2 )
      CALL SetErrStat(ErrStat2, ErrMsg2, ErrStat, ErrMsg, RoutineName)
      CALL CD_DestroyContState( x, ErrStat2, ErrMsg2 )
      CALL SetErrStat(ErrStat2, ErrMsg2, ErrStat, ErrMsg, RoutineName)
      CALL CD_DestroyDiscState( xd, ErrStat2, ErrMsg2 )
      CALL SetErrStat(ErrStat2, ErrMsg2, ErrStat, ErrMsg, RoutineName)
      CALL CD_DestroyConstrState( z, ErrStat2, ErrMsg2 )
      CALL SetErrStat(ErrStat2, ErrMsg2, ErrStat, ErrMsg, RoutineName)
      CALL CD_DestroyOtherState( other, ErrStat2, ErrMsg2 )
      CALL SetErrStat(ErrStat2, ErrMsg2, ErrStat, ErrMsg, RoutineName)
      CALL CD_DestroyOutput( y, ErrStat2, ErrMsg2 )
      CALL SetErrStat(ErrStat2, ErrMsg2, ErrStat, ErrMsg, RoutineName)
      CALL CD_DestroyMisc( m, ErrStat2, ErrMsg2 )
      CALL SetErrStat(ErrStat2, ErrMsg2, ErrStat, ErrMsg, RoutineName)
   END SUBROUTINE CD_End

!----------------------------------------------------------------------------------------------------------------------------------
   SUBROUTINE CD_JacobianPInput(Vars, t, u, p, x, xd, z, OtherState, y, m, ErrStat, ErrMsg, dYdu, dXdu, dXddu, dZdu)
      TYPE(ModVarsType),                  INTENT(IN   ) :: Vars
      REAL(DbKi),                         INTENT(IN   ) :: t
      TYPE(CD_InputType),                 INTENT(INOUT) :: u
      TYPE(CD_ParameterType),             INTENT(IN   ) :: p
      TYPE(CD_ContinuousStateType),       INTENT(IN   ) :: x
      TYPE(CD_DiscreteStateType),         INTENT(IN   ) :: xd
      TYPE(CD_ConstraintStateType),       INTENT(IN   ) :: z
      TYPE(CD_OtherStateType),            INTENT(IN   ) :: OtherState
      TYPE(CD_OutputType),                INTENT(INOUT) :: y
      TYPE(CD_MiscVarType),               INTENT(INOUT) :: m
      INTEGER(IntKi),                     INTENT(  OUT) :: ErrStat
      CHARACTER(*),                       INTENT(  OUT) :: ErrMsg
      REAL(R8Ki), ALLOCATABLE, OPTIONAL,  INTENT(INOUT) :: dYdu(:,:)
      REAL(R8Ki), ALLOCATABLE, OPTIONAL,  INTENT(INOUT) :: dXdu(:,:)
      REAL(R8Ki), ALLOCATABLE, OPTIONAL,  INTENT(INOUT) :: dXddu(:,:)
      REAL(R8Ki), ALLOCATABLE, OPTIONAL,  INTENT(INOUT) :: dZdu(:,:)

      character(*), parameter :: RoutineName = 'CD_JacobianPInput'
      INTEGER(IntKi)          :: ErrStat2, i, j, iCol
      CHARACTER(ErrMsgLen)    :: ErrMsg2

      ErrStat = ErrID_None
      ErrMsg  = ''
      ! The Failed() idiom merges these locals into ErrStat; seed them clean so a
      ! probe never reads a stale/uninitialised status (belt-and-suspenders with the
      ! CD_CalcOutput entry-clear).
      ErrStat2 = ErrID_None
      ErrMsg2  = ''

      ! Get OP values here (the FD reference point)
      CALL CD_CalcOutput( t, u, p, x, xd, z, OtherState, y, m, ErrStat2, ErrMsg2 ); IF (Failed()) RETURN

      ! Linearization with the line dynamics: the partial derivatives at the fixed state x, by
      ! central differences of lin_eval, as MoorDyn-F's of its CalcOutput and
      ! CalcContStateDeriv (dXdu only when the glue asks for it: a deck without line states
      ! has none).
      IF (Inst(m%CDInst)%lin_states) THEN
         IF (PRESENT(dYdu)) THEN
            IF (.NOT. ALLOCATED(dYdu)) THEN
               CALL AllocAry( dYdu, m%Jac%Ny, m%Jac%Nu, 'dYdu', ErrStat2, ErrMsg2 ); IF (Failed()) RETURN
            END IF
            dYdu = 0.0_R8Ki
         END IF
         IF (PRESENT(dXdu)) THEN
            IF (.NOT. ALLOCATED(dXdu)) THEN
               CALL AllocAry( dXdu, m%Jac%Nx, m%Jac%Nu, 'dXdu', ErrStat2, ErrMsg2 ); IF (Failed()) RETURN
            END IF
            dXdu = 0.0_R8Ki
         END IF
         CALL CD_CopyInput( u, m%u_perturb, MESH_UPDATECOPY, ErrStat2, ErrMsg2 ); IF (Failed()) RETURN
         CALL CD_VarsPackInput( Vars, u, m%Jac%u )
         DO i = 1, SIZE(Vars%u)
            DO j = 1, Vars%u(i)%Num
               iCol = Vars%u(i)%iLoc(1) + j - 1
               CALL MV_Perturb( Vars%u(i), j, 1, m%Jac%u, m%Jac%u_perturb )
               CALL CD_VarsUnpackInput( Vars, m%Jac%u_perturb, m%u_perturb )
               CALL lin_eval( m%CDInst, p, m, m%u_perturb, x, ErrStat2, ErrMsg2, dxdt=m%dxdt_lin, y_out=m%y_lin )
               IF (Failed()) RETURN
               CALL pack_lin_outputs( m%CDInst, Vars, m%y_lin, m%Jac%y_pos )
               CALL CD_VarsPackContStateDeriv( Vars, m%dxdt_lin, m%Jac%x_pos )
               CALL MV_Perturb( Vars%u(i), j, -1, m%Jac%u, m%Jac%u_perturb )
               CALL CD_VarsUnpackInput( Vars, m%Jac%u_perturb, m%u_perturb )
               CALL lin_eval( m%CDInst, p, m, m%u_perturb, x, ErrStat2, ErrMsg2, dxdt=m%dxdt_lin, y_out=m%y_lin )
               IF (Failed()) RETURN
               CALL pack_lin_outputs( m%CDInst, Vars, m%y_lin, m%Jac%y_neg )
               CALL CD_VarsPackContStateDeriv( Vars, m%dxdt_lin, m%Jac%x_neg )
               IF (PRESENT(dYdu)) CALL MV_ComputeCentralDiff( Vars%y, Vars%u(i)%Perturb, m%Jac%y_pos, m%Jac%y_neg, &
                                                              dYdu(:, iCol) )
               IF (PRESENT(dXdu)) dXdu(:, iCol) = (m%Jac%x_pos - m%Jac%x_neg)/(2.0_R8Ki*Vars%u(i)%Perturb)
            END DO
         END DO
         ! the outputs at the operating point again (the glue reads y after this call)
         CALL CD_CalcOutput( t, u, p, x, xd, z, OtherState, y, m, ErrStat2, ErrMsg2 ); IF (Failed()) RETURN
         IF (PRESENT(dXddu)) THEN
            IF (ALLOCATED(dXddu)) DEALLOCATE (dXddu)
         END IF
         IF (PRESENT(dZdu)) THEN
            IF (ALLOCATED(dZdu)) DEALLOCATE (dZdu)
         END IF
         RETURN
      END IF

      ! The runtime input/output solve of a nonlinear run: the PARTIAL derivative g_u at the
      ! fixed internal state, as stock MoorDyn's runtime Jacobian. Perturb the current input,
      ! evaluate CalcOutput with the same x/xd/z/other, and central-difference the packed
      ! outputs; CD_CalcOutput's probe overlay restores the authoritative CableDyn state after
      ! every evaluation. (Re-equilibrating the line for these probes would give a total
      ! quasi-static derivative instead, which can make the runtime Jacobian rank deficient.)
      IF (PRESENT(dYdu)) THEN
         IF (.NOT. ALLOCATED(dYdu)) THEN
            CALL AllocAry( dYdu, m%Jac%Ny, m%Jac%Nu, 'dYdu', ErrStat2, ErrMsg2 ); IF (Failed()) RETURN
         END IF
         dYdu = 0.0_R8Ki
         CALL CD_CopyInput( u, m%u_perturb, MESH_UPDATECOPY, ErrStat2, ErrMsg2 ); IF (Failed()) RETURN
         CALL CD_VarsPackInput( Vars, u, m%Jac%u )
         DO i = 1, SIZE(Vars%u)
            DO j = 1, Vars%u(i)%Num
               iCol = Vars%u(i)%iLoc(1) + j - 1
               CALL MV_Perturb( Vars%u(i), j, 1, m%Jac%u, m%Jac%u_perturb )
               CALL CD_VarsUnpackInput( Vars, m%Jac%u_perturb, m%u_perturb )
               CALL CD_CalcOutput( t, m%u_perturb, p, x, xd, z, OtherState, m%y_lin, m, ErrStat2, ErrMsg2 )
               IF (Failed()) RETURN
               CALL CD_VarsPackOutput( Vars, m%y_lin, m%Jac%y_pos )

               CALL MV_Perturb( Vars%u(i), j, -1, m%Jac%u, m%Jac%u_perturb )
               CALL CD_VarsUnpackInput( Vars, m%Jac%u_perturb, m%u_perturb )
               CALL CD_CalcOutput( t, m%u_perturb, p, x, xd, z, OtherState, m%y_lin, m, ErrStat2, ErrMsg2 )
               IF (Failed()) RETURN
               CALL CD_VarsPackOutput( Vars, m%y_lin, m%Jac%y_neg )

               CALL MV_ComputeCentralDiff( Vars%y, Vars%u(i)%Perturb, m%Jac%y_pos, m%Jac%y_neg, &
                                           dYdu(:, iCol) )
            END DO
         END DO
         ! The final negative probe leaves only output/cache workspaces at the perturbed
         ! input (the authoritative structural state was already restored). Re-evaluate the
         ! operating point so the callback is observationally neutral to the next glue
         ! evaluation as well as state neutral.
         CALL CD_CalcOutput( t, u, p, x, xd, z, OtherState, y, m, ErrStat2, ErrMsg2 )
         IF (Failed()) RETURN
      END IF

      ! dX/du of the implicit march exists only for a linearization run (the line-state
      ! branch above): fail loudly, never zero-fill.
      IF (PRESENT(dXdu)) THEN
         CALL SetErrStat( ErrID_Fatal, 'CableDyn mooring module: dXdu exists only for a linearization '// &
                          'run (Linearize = True).', ErrStat, ErrMsg, RoutineName )
         RETURN
      END IF

      IF (PRESENT(dXddu)) THEN
         IF (ALLOCATED(dXddu)) DEALLOCATE (dXddu)
      END IF
      IF (PRESENT(dZdu)) THEN
         IF (ALLOCATED(dZdu)) DEALLOCATE (dZdu)
      END IF

   CONTAINS
      LOGICAL FUNCTION Failed()
         CALL SetErrStat( ErrStat2, ErrMsg2, ErrStat, ErrMsg, RoutineName )
         Failed = ErrStat >= AbortErrLev
      END FUNCTION Failed
   END SUBROUTINE CD_JacobianPInput


!----------------------------------------------------------------------------------------------------------------------------------
   SUBROUTINE CD_JacobianPContState(Vars, t, u, p, x, xd, z, OtherState, y, m, ErrStat, ErrMsg, dYdx, dXdx, dXddx, dZdx)
      TYPE(ModVarsType),                  INTENT(IN   ) :: Vars
      REAL(DbKi),                         INTENT(IN   ) :: t
      TYPE(CD_InputType),                 INTENT(INOUT) :: u
      TYPE(CD_ParameterType),             INTENT(IN   ) :: p
      TYPE(CD_ContinuousStateType),       INTENT(INOUT) :: x
      TYPE(CD_DiscreteStateType),         INTENT(IN   ) :: xd
      TYPE(CD_ConstraintStateType),       INTENT(IN   ) :: z
      TYPE(CD_OtherStateType),            INTENT(IN   ) :: OtherState
      TYPE(CD_OutputType),                INTENT(INOUT) :: y
      TYPE(CD_MiscVarType),               INTENT(INOUT) :: m
      INTEGER(IntKi),                     INTENT(  OUT) :: ErrStat
      CHARACTER(*),                       INTENT(  OUT) :: ErrMsg
      REAL(R8Ki), ALLOCATABLE, OPTIONAL,  INTENT(INOUT) :: dYdx(:,:)
      REAL(R8Ki), ALLOCATABLE, OPTIONAL,  INTENT(INOUT) :: dXdx(:,:)
      REAL(R8Ki), ALLOCATABLE, OPTIONAL,  INTENT(INOUT) :: dXddx(:,:)
      REAL(R8Ki), ALLOCATABLE, OPTIONAL,  INTENT(INOUT) :: dZdx(:,:)

      character(*), parameter :: RoutineName = 'CD_JacobianPContState'

      INTEGER(IntKi)          :: ErrStat2, i, j, iCol
      CHARACTER(ErrMsgLen)    :: ErrMsg2

      ErrStat = ErrID_None
      ErrMsg  = ''
      ErrStat2 = ErrID_None
      ErrMsg2  = ''
      ! Linearization with the line dynamics: dYdx and dXdx by central differences of lin_eval
      ! over the registered states, as MoorDyn-F's
      IF (Inst(m%CDInst)%lin_states) THEN
         IF (PRESENT(dYdx)) THEN
            IF (.NOT. ALLOCATED(dYdx)) THEN
               CALL AllocAry( dYdx, m%Jac%Ny, m%Jac%Nx, 'dYdx', ErrStat2, ErrMsg2 )
               CALL SetErrStat( ErrStat2, ErrMsg2, ErrStat, ErrMsg, RoutineName )
               IF (ErrStat >= AbortErrLev) RETURN
            END IF
            dYdx = 0.0_R8Ki
         END IF
         IF (PRESENT(dXdx)) THEN
            IF (.NOT. ALLOCATED(dXdx)) THEN
               CALL AllocAry( dXdx, m%Jac%Nx, m%Jac%Nx, 'dXdx', ErrStat2, ErrMsg2 )
               CALL SetErrStat( ErrStat2, ErrMsg2, ErrStat, ErrMsg, RoutineName )
               IF (ErrStat >= AbortErrLev) RETURN
            END IF
            dXdx = 0.0_R8Ki
         END IF
         CALL CD_CopyContState( x, m%x_perturb, MESH_UPDATECOPY, ErrStat2, ErrMsg2 )
         CALL SetErrStat( ErrStat2, ErrMsg2, ErrStat, ErrMsg, RoutineName )
         IF (ErrStat >= AbortErrLev) RETURN
         CALL CD_VarsPackContState( Vars, x, m%Jac%x )
         DO i = 1, SIZE(Vars%x)
            DO j = 1, Vars%x(i)%Num
               iCol = Vars%x(i)%iLoc(1) + j - 1
               CALL MV_Perturb( Vars%x(i), j, 1, m%Jac%x, m%Jac%x_perturb )
               CALL CD_VarsUnpackContState( Vars, m%Jac%x_perturb, m%x_perturb )
               CALL lin_eval( m%CDInst, p, m, u, m%x_perturb, ErrStat2, ErrMsg2, dxdt=m%dxdt_lin, y_out=m%y_lin )
               CALL SetErrStat( ErrStat2, ErrMsg2, ErrStat, ErrMsg, RoutineName )
               IF (ErrStat >= AbortErrLev) RETURN
               CALL pack_lin_outputs( m%CDInst, Vars, m%y_lin, m%Jac%y_pos )
               CALL CD_VarsPackContStateDeriv( Vars, m%dxdt_lin, m%Jac%x_pos )
               CALL MV_Perturb( Vars%x(i), j, -1, m%Jac%x, m%Jac%x_perturb )
               CALL CD_VarsUnpackContState( Vars, m%Jac%x_perturb, m%x_perturb )
               CALL lin_eval( m%CDInst, p, m, u, m%x_perturb, ErrStat2, ErrMsg2, dxdt=m%dxdt_lin, y_out=m%y_lin )
               CALL SetErrStat( ErrStat2, ErrMsg2, ErrStat, ErrMsg, RoutineName )
               IF (ErrStat >= AbortErrLev) RETURN
               CALL pack_lin_outputs( m%CDInst, Vars, m%y_lin, m%Jac%y_neg )
               CALL CD_VarsPackContStateDeriv( Vars, m%dxdt_lin, m%Jac%x_neg )
               IF (PRESENT(dYdx)) CALL MV_ComputeCentralDiff( Vars%y, Vars%x(i)%Perturb, m%Jac%y_pos, m%Jac%y_neg, &
                                                              dYdx(:, iCol) )
               IF (PRESENT(dXdx)) dXdx(:, iCol) = (m%Jac%x_pos - m%Jac%x_neg)/(2.0_R8Ki*Vars%x(i)%Perturb)
            END DO
         END DO
         IF (PRESENT(dXddx)) THEN
            IF (ALLOCATED(dXddx)) DEALLOCATE (dXddx)
         END IF
         IF (PRESENT(dZdx)) THEN
            IF (ALLOCATED(dZdx)) DEALLOCATE (dZdx)
         END IF
         RETURN
      END IF
      ! Outside a linearization run the implicit march has no x' = f(x, u) surface to
      ! differentiate: fail loudly rather than fabricate one.
      IF (m%Jac%Nx > 0) THEN
         CALL SetErrStat( ErrID_Fatal, 'CableDyn mooring module: state Jacobians exist only for a '// &
                          'linearization run (Linearize = True).', ErrStat, ErrMsg, RoutineName )
         RETURN
      END IF
      IF (PRESENT(dYdx)) THEN
         IF (.NOT. ALLOCATED(dYdx)) THEN
            CALL AllocAry( dYdx, m%Jac%Ny, m%Jac%Nx, 'dYdx', ErrStat2, ErrMsg2 )
            CALL SetErrStat( ErrStat2, ErrMsg2, ErrStat, ErrMsg, RoutineName )
            IF (ErrStat >= AbortErrLev) RETURN
         END IF
      END IF
      IF (PRESENT(dXdx)) THEN
         IF (.NOT. ALLOCATED(dXdx)) THEN
            CALL AllocAry( dXdx, m%Jac%Nx, m%Jac%Nx, 'dXdx', ErrStat2, ErrMsg2 )
            CALL SetErrStat( ErrStat2, ErrMsg2, ErrStat, ErrMsg, RoutineName )
            IF (ErrStat >= AbortErrLev) RETURN
         END IF
      END IF
      IF (PRESENT(dXddx)) THEN
         IF (ALLOCATED(dXddx)) DEALLOCATE (dXddx)
      END IF
      IF (PRESENT(dZdx)) THEN
         IF (ALLOCATED(dZdx)) DEALLOCATE (dZdx)
      END IF
   END SUBROUTINE CD_JacobianPContState

!----------------------------------------------------------------------------------------------------------------------------------
   SUBROUTINE CD_JacobianPDiscState( t, u, p, x, xd, z, OtherState, y, m, ErrStat, ErrMsg, dYdxd, dXdxd, dXddxd, dZdxd )
      REAL(DbKi),                         INTENT(IN   ) :: t
      TYPE(CD_InputType),                 INTENT(INOUT) :: u
      TYPE(CD_ParameterType),             INTENT(IN   ) :: p
      TYPE(CD_ContinuousStateType),       INTENT(IN   ) :: x
      TYPE(CD_DiscreteStateType),         INTENT(IN   ) :: xd
      TYPE(CD_ConstraintStateType),       INTENT(IN   ) :: z
      TYPE(CD_OtherStateType),            INTENT(IN   ) :: OtherState
      TYPE(CD_OutputType),                INTENT(INOUT) :: y
      TYPE(CD_MiscVarType),               INTENT(INOUT) :: m
      INTEGER(IntKi),                     INTENT(  OUT) :: ErrStat
      CHARACTER(*),                       INTENT(  OUT) :: ErrMsg
      REAL(R8Ki), ALLOCATABLE, OPTIONAL,  INTENT(INOUT) :: dYdxd(:,:)
      REAL(R8Ki), ALLOCATABLE, OPTIONAL,  INTENT(INOUT) :: dXdxd(:,:)
      REAL(R8Ki), ALLOCATABLE, OPTIONAL,  INTENT(INOUT) :: dXddxd(:,:)
      REAL(R8Ki), ALLOCATABLE, OPTIONAL,  INTENT(INOUT) :: dZdxd(:,:)

      ! No discrete states (matches stock: a no-op).
      ErrStat = ErrID_None
      ErrMsg  = ''
   END SUBROUTINE CD_JacobianPDiscState

!----------------------------------------------------------------------------------------------------------------------------------
   SUBROUTINE CD_JacobianPConstrState( t, u, p, x, xd, z, OtherState, y, m, ErrStat, ErrMsg, dYdz, dXdz, dXddz, dZdz )
      REAL(DbKi),                         INTENT(IN   ) :: t
      TYPE(CD_InputType),                 INTENT(INOUT) :: u
      TYPE(CD_ParameterType),             INTENT(IN   ) :: p
      TYPE(CD_ContinuousStateType),       INTENT(IN   ) :: x
      TYPE(CD_DiscreteStateType),         INTENT(IN   ) :: xd
      TYPE(CD_ConstraintStateType),       INTENT(IN   ) :: z
      TYPE(CD_OtherStateType),            INTENT(IN   ) :: OtherState
      TYPE(CD_OutputType),                INTENT(INOUT) :: y
      TYPE(CD_MiscVarType),               INTENT(INOUT) :: m
      INTEGER(IntKi),                     INTENT(  OUT) :: ErrStat
      CHARACTER(*),                       INTENT(  OUT) :: ErrMsg
      REAL(R8Ki), ALLOCATABLE, OPTIONAL,  INTENT(INOUT) :: dYdz(:,:)
      REAL(R8Ki), ALLOCATABLE, OPTIONAL,  INTENT(INOUT) :: dXdz(:,:)
      REAL(R8Ki), ALLOCATABLE, OPTIONAL,  INTENT(INOUT) :: dXddz(:,:)
      REAL(R8Ki), ALLOCATABLE, OPTIONAL,  INTENT(INOUT) :: dZdz(:,:)

      ! No constraint states (matches stock: a no-op).
      ErrStat = ErrID_None
      ErrMsg  = ''
   END SUBROUTINE CD_JacobianPConstrState

!----------------------------------------------------------------------------------------------------------------------------------
!  Private helpers
!----------------------------------------------------------------------------------------------------------------------------------

   !> Register the module variables (the ModVars surface MV_AddModule consumes):
   !> u = the coupled-kinematics mesh; y = the coupled-loads mesh; x = the line
   !> interior-node velocity/position mirror in the MoorDyn framework ordering
   !> (all velocities registered after all positions).
   SUBROUTINE CD_InitVars(Vars, u, p, x, y, m, inst_, Linearize, ErrStat, ErrMsg)
      TYPE(ModVarsType),               INTENT(OUT)    :: Vars
      TYPE(CD_InputType),              INTENT(INOUT)  :: u
      TYPE(CD_ParameterType),          INTENT(INOUT)  :: p
      TYPE(CD_ContinuousStateType),    INTENT(INOUT)  :: x
      TYPE(CD_OutputType),             INTENT(INOUT)  :: y
      TYPE(CD_MiscVarType),            INTENT(INOUT)  :: m
      TYPE(CD_OF_Instance),            INTENT(IN)     :: inst_
      LOGICAL,                         INTENT(IN)     :: Linearize
      INTEGER(IntKi),                  INTENT(OUT)    :: ErrStat
      CHARACTER(*),                    INTENT(OUT)    :: ErrMsg

      character(*), parameter   :: RoutineName = 'CD_InitVars'
      INTEGER(IntKi)            :: ErrStat2, es
      CHARACTER(ErrMsgLen)      :: ErrMsg2
      CHARACTER(ErrMsgLen)            :: em
      INTEGER(IntKi)            :: il, i, j, N, ndofl, nin, ic, csz, nf, koff, nve
      CHARACTER(32)             :: LinStr
      CHARACTER(ChanLen)        :: whdr, wunt
      INTEGER(IntKi)            :: ivT
      CHARACTER(LinChanLen), ALLOCATABLE :: WrOutLinNames(:)
      CHARACTER(LinChanLen), ALLOCATABLE :: CblLinVel(:), CblLinPos(:), CblLinAcc(:)
      character(20), parameter  :: TransDispSuffix(*) = [' Px, m', ' Py, m', ' Pz, m']
      character(20), parameter  :: TransVelSuffix(*)  = [' Vx, m/s', ' Vy, m/s', ' Vz, m/s']
      ! a finite-EI cable node's tangent m = dr/ds and its rate (linearization states)
      character(20), parameter  :: TangentSuffix(*)     = [' Tx, -', ' Ty, -', ' Tz, -']
      character(20), parameter  :: TangentRateSuffix(*) = [' dTx, 1/s', ' dTy, 1/s', ' dTz, 1/s']
      ! central-difference steps of the linearization states. Positions, tangents and the
      ! coupled-point displacements take 1 um (a tangent step moves an element by about its
      ! length times the step): far inside the seabed penetration of a light cable (a few
      ! tenths of a millimetre) and any element's slack, either of which a millimetre step
      ! would cross on one side of the difference, and still some ten digits above round-off.
      ! The velocity step is MoorDyn-F's 0.1 m/s: quadratic drag has no slope at rest, so the
      ! difference over +-0.1 m/s is the drag's equivalent linear damping at that velocity
      ! amplitude (a smaller step leaves the line modes all but undamped); a cable's tangent
      ! rate takes the same amplitude over its mean element length.
      REAL(R8Ki), PARAMETER     :: LIN_DX = 1.0E-6_R8Ki, LIN_DV = 0.1_R8Ki
      REAL(R8Ki), PARAMETER     :: LIN_DT = 1.0E-6_R8Ki
      ! the constitutive states: a viscoelastic slow-branch stretch (m) takes the position step,
      ! a Syrope slow strain the strain of a micrometre over a metre
      REAL(R8Ki), PARAMETER     :: LIN_DSLOW = 1.0E-6_R8Ki
      ! the nodal twist: at a fixed configuration the element twist phi_{e+1} - phi_e + rho_e(q)
      ! (with GJ|K, + (K/GJ)(l_e - l0), which the angles do not change) and so the torques and
      ! their forces M_e drho_e/dq on the cable are affine in the angles; the coupling of the
      ! angles to the configuration (rho_e, the stretch) is not, and the angle takes the
      ! position step's 1e-6 rad, as the r and m it is differenced with. A rate enters only the
      ! linear torsional damping, so any rate step is exact up to round-off: 0.01 rad/s
      REAL(R8Ki), PARAMETER     :: LIN_DPHI = 1.0E-6_R8Ki, LIN_DW = 1.0E-2_R8Ki
      ! the coupled-point rotation step of a linearization run: a rotation moves no node, so
      ! neither contact nor slack constrains it, and the turn of a torsion end frame about axes
      ! across its director (a solid angle) or of an end connection's direction is nonlinear:
      ! 1e-4 rad keeps the central difference's O(h^2) error near 1e-9 and the difference of the
      ! moments and accelerations some eight digits above round-off. In a Linearize run every
      ! input Jacobian goes through lin_eval with this step, the glue's time-domain
      ! input-output solves before the linearization times included; a run without
      ! Linearize keeps 0.1 rad
      REAL(R8Ki), PARAMETER     :: LIN_DROT = 1.0E-4_R8Ki
      LOGICAL, ALLOCATABLE      :: lin1m(:)
      INTEGER(IntKi)            :: kind1, ntw
      INTEGER, ALLOCATABLE      :: tw_p(:), tw_r(:), tw_a(:), tw_n(:)
      INTEGER(IntKi)            :: ipass, nnc, inode, ikind, i0, nrun, icomp, k
      ! the position step of the line states and the coupled-point displacement step of the
      ! inputs under linearization (lin_disp_step), and a cable's tangent-rate step
      REAL(R8Ki)                :: dx_pos, dx_u, dtr, dx_rot

      ErrStat = ErrID_None
      ErrMsg  = ''
      dx_u = 0.05_R8Ki
      dx_rot = 0.1_R8Ki
      IF (Linearize) THEN
         dx_rot = LIN_DROT
         dx_u = LIN_DX
         CALL lin_disp_step( inst_, dx_u, ErrStat2, ErrMsg2 )
         CALL SetErrStat( ErrStat2, ErrMsg2, ErrStat, ErrMsg, RoutineName )
         IF (ErrStat >= AbortErrLev) RETURN
      END IF
      dx_pos = dx_u

      IF (Linearize) THEN
         ! Linearization with the line dynamics, as MoorDyn-F: the continuous states are the
         ! positions of every EI = 0 line's interior nodes and of every finite-EI cable's free
         ! DOFs (node positions r and tangents m = dr/ds) and the free twist angles phi of a
         ! cable restrained in torsion, then their velocities, held in the x%states mirror slots
         ! (lin_state_map), and the per-element constitutive states of the
         ! viscoelastic and Syrope ropes as first-order states. The acceleration and the other
         ! mirror blocks are not registered: the glue would take every registered x as a state.
         ALLOCATE (Vars%x(0), STAT=ErrStat2)
         IF (ErrStat2 /= 0) THEN
            CALL SetErrStat( ErrID_Fatal, 'Could not allocate Vars%x.', ErrStat, ErrMsg, RoutineName ); RETURN
         END IF
         DO ipass = 1, 2   ! the positions, then the velocities
            DO il = 1, inst_%nlines
               ndofl = CD_System_Line_NDOF( inst_%agg%sys%fast%system, il, es, em )
               IF (es /= CD_SYSTEM_OK) THEN
                  CALL SetErrStat( ErrID_Fatal, TRIM(em), ErrStat, ErrMsg, RoutineName ); RETURN
               END IF
               N = ndofl/3 - 1
               DO i = 0, N - 2
                  LinStr = 'Line '//TRIM(Num2LStr(il))//' node '//TRIM(Num2LStr(i + 1))
                  IF (ipass == 1) THEN
                     CALL MV_AddVar( Vars%x, LinStr, FieldTransDisp, DatLoc(CD_x_states), &
                                     iAry=m%LineStateIs1(il) + 3*(N - 1) + 3*i, Num=3, Flags=VF_DerivOrder2, &
                                     Perturb=dx_pos, LinNames=[(TRIM(LinStr)//TransDispSuffix(j), j=1, 3)] )
                  ELSE
                     CALL MV_AddVar( Vars%x, LinStr, FieldTransVel, DatLoc(CD_x_states), &
                                     iAry=m%LineStateIs1(il) + 3*i, Num=3, Flags=VF_DerivOrder2, &
                                     Perturb=LIN_DV, LinNames=[(TRIM(LinStr)//TransVelSuffix(j), j=1, 3)] )
                  END IF
               END DO
            END DO
            koff = 0
            IF (inst_%nlines > 0) koff = m%LineStateIsN(inst_%nlines)
            DO ic = 1, inst_%agg%ncable
               csz = CD_HFMF_MirrorSize( inst_%agg%cables(ic) )
               IF (csz <= 0) CYCLE
               nf = COUNT(inst_%agg%cables(ic)%line%freemask)
               ndofl = inst_%agg%cables(ic)%line%ndof
               nnc = inst_%agg%cables(ic)%line%nn
               dtr = LIN_DV*REAL(inst_%agg%cables(ic)%line%ne, R8Ki)/REAL(SUM(inst_%agg%cables(ic)%line%l0), R8Ki)
               k = 0
               i = 1
               DO WHILE (i <= ndofl)
                  IF (.NOT. inst_%agg%cables(ic)%line%freemask(i)) THEN
                     i = i + 1
                     CYCLE
                  END IF
                  ! a run of free DOFs of one node and one kind: the position r (DOFs 1-3 of the
                  ! node) or the tangent m (4-6); the node is named End A first, as the channels
                  inode = (i - 1)/6 + 1
                  ikind = MERGE(1, 2, MOD(i - 1, 6) < 3)
                  i0 = i
                  DO WHILE (i <= ndofl)
                     IF (.NOT. inst_%agg%cables(ic)%line%freemask(i)) EXIT
                     IF ((i - 1)/6 + 1 /= inode .OR. MERGE(1, 2, MOD(i - 1, 6) < 3) /= ikind) EXIT
                     i = i + 1
                  END DO
                  nrun = i - i0
                  LinStr = 'Cable '//TRIM(Num2LStr(ic))//' node '//TRIM(Num2LStr(nnc + 1 - inode))
                  ALLOCATE (CblLinPos(nrun), STAT=ErrStat2)
                  IF (ErrStat2 /= 0) THEN
                     CALL SetErrStat( ErrID_Fatal, 'Could not allocate cable lin-name work array.', &
                                      ErrStat, ErrMsg, RoutineName ); RETURN
                  END IF
                  DO j = 1, nrun
                     icomp = MOD(i0 + j - 2, 3) + 1
                     IF (ikind == 1 .AND. ipass == 1) THEN
                        CblLinPos(j) = TRIM(LinStr)//TransDispSuffix(icomp)
                     ELSE IF (ikind == 1) THEN
                        CblLinPos(j) = TRIM(LinStr)//TransVelSuffix(icomp)
                     ELSE IF (ipass == 1) THEN
                        CblLinPos(j) = TRIM(LinStr)//TangentSuffix(icomp)
                     ELSE
                        CblLinPos(j) = TRIM(LinStr)//TangentRateSuffix(icomp)
                     END IF
                  END DO
                  IF (ipass == 1) THEN
                     IF (ikind == 1 .AND. nrun == 3) THEN
                        CALL MV_AddVar( Vars%x, LinStr, FieldTransDisp, DatLoc(CD_x_states), &
                                        iAry=koff + nf + k + 1, Num=nrun, Flags=VF_DerivOrder2, &
                                        Perturb=dx_pos, LinNames=CblLinPos )
                     ELSE
                        CALL MV_AddVar( Vars%x, LinStr, FieldScalar, DatLoc(CD_x_states), &
                                        iAry=koff + nf + k + 1, Num=nrun, Flags=VF_DerivOrder2, DerivOrder=0, &
                                        Perturb=MERGE(dx_pos, LIN_DT, ikind == 1), LinNames=CblLinPos )
                     END IF
                  ELSE
                     IF (ikind == 1 .AND. nrun == 3) THEN
                        CALL MV_AddVar( Vars%x, LinStr, FieldTransVel, DatLoc(CD_x_states), &
                                        iAry=koff + k + 1, Num=nrun, Flags=VF_DerivOrder2, &
                                        Perturb=LIN_DV, LinNames=CblLinPos )
                     ELSE
                        CALL MV_AddVar( Vars%x, LinStr, FieldScalar, DatLoc(CD_x_states), &
                                        iAry=koff + k + 1, Num=nrun, Flags=VF_DerivOrder2, DerivOrder=1, &
                                        Perturb=MERGE(LIN_DV, dtr, ikind == 1), LinNames=CblLinPos )
                     END IF
                  END IF
                  DEALLOCATE (CblLinPos)
                  k = k + nrun
               END DO
               koff = koff + csz
            END DO
            ! the nodal twist of every cable restrained in torsion, after the cables' r and m:
            ! the angles phi of its free nodes (every node but a torsionally rigid end), then in
            ! the second pass their rates, one consecutive run per cable (CD_HFMF_Twist_Lin_Slots)
            koff = 0
            IF (inst_%nlines > 0) koff = m%LineStateIsN(inst_%nlines)
            DO ic = 1, inst_%agg%ncable
               csz = CD_HFMF_MirrorSize( inst_%agg%cables(ic) )
               IF (csz <= 0) CYCLE
               ntw = CD_HFMF_Twist_Lin_Count( inst_%agg%cables(ic) )
               IF (ntw > 0) THEN
                  nnc = inst_%agg%cables(ic)%line%nn
                  ALLOCATE (tw_p(ntw), tw_r(ntw), tw_a(ntw), tw_n(ntw), CblLinPos(ntw), STAT=ErrStat2)
                  IF (ErrStat2 /= 0) THEN
                     CALL SetErrStat( ErrID_Fatal, 'Could not allocate cable twist lin-name work arrays.', &
                                      ErrStat, ErrMsg, RoutineName ); RETURN
                  END IF
                  CALL CD_HFMF_Twist_Lin_Slots( inst_%agg%cables(ic), tw_p, tw_r, tw_a, tw_n, es, em )
                  IF (es /= CD_HFMF_OK) THEN
                     CALL SetErrStat( ErrID_Fatal, 'CableDyn mooring module: cable '//TRIM(Num2LStr(ic))// &
                                      ': '//TRIM(em), ErrStat, ErrMsg, RoutineName ); RETURN
                  END IF
                  ! one variable per cable and kind needs one consecutive run of mirror slots
                  IF (tw_p(ntw) - tw_p(1) /= ntw - 1 .OR. tw_r(ntw) - tw_r(1) /= ntw - 1) THEN
                     CALL SetErrStat( ErrID_Fatal, 'CableDyn mooring module: cable '//TRIM(Num2LStr(ic))// &
                                      ': the free twist angles are not consecutive in the state mirror.', &
                                      ErrStat, ErrMsg, RoutineName ); RETURN
                  END IF
                  ! the node named End A first, as the channels and the cable's r and m states
                  DO j = 1, ntw
                     LinStr = 'Cable '//TRIM(Num2LStr(ic))//' node '//TRIM(Num2LStr(nnc + 1 - tw_n(j)))
                     IF (ipass == 1) THEN
                        CblLinPos(j) = TRIM(LinStr)//' twist, rad'
                     ELSE
                        CblLinPos(j) = TRIM(LinStr)//' twist rate, rad/s'
                     END IF
                  END DO
                  LinStr = 'Cable '//TRIM(Num2LStr(ic))//' twist'
                  IF (ipass == 1) THEN
                     CALL MV_AddVar( Vars%x, LinStr, FieldScalar, DatLoc(CD_x_states), &
                                     iAry=koff + tw_p(1), Num=ntw, Flags=VF_DerivOrder2, DerivOrder=0, &
                                     Perturb=LIN_DPHI, LinNames=CblLinPos )
                  ELSE
                     CALL MV_AddVar( Vars%x, TRIM(LinStr)//' rate', FieldScalar, DatLoc(CD_x_states), &
                                     iAry=koff + tw_r(1), Num=ntw, Flags=VF_DerivOrder2, DerivOrder=1, &
                                     Perturb=LIN_DW, LinNames=CblLinPos )
                  END IF
                  DEALLOCATE (tw_p, tw_r, tw_a, tw_n, CblLinPos)
               END IF
               koff = koff + csz
            END DO
         END DO
         ! the per-element constitutive states of the EI = 0 lines, first-order states: the
         ! viscoelastic slow-branch stretch dl_1 and the Syrope slow strain (the Syrope running
         ! maximum is a load history, held as the operating point's)
         DO il = 1, inst_%nlines
            ndofl = CD_System_Line_NDOF( inst_%agg%sys%fast%system, il, es, em )
            nin = ndofl - 6
            DO kind1 = LIN1_VE, LIN1_SYROPE
               lin1m = lin1_mask( inst_, il, kind1 )
               DO j = 1, SIZE(lin1m)
                  IF (.NOT. lin1m(j)) CYCLE
                  LinStr = 'Line '//TRIM(Num2LStr(il))//' segment '//TRIM(Num2LStr(j))
                  IF (kind1 == LIN1_VE) THEN
                     CALL MV_AddVar( Vars%x, LinStr, FieldScalar, DatLoc(CD_x_states), &
                                     iAry=m%LineStateIs1(il) + 3*nin + j - 1, Num=1, Flags=VF_DerivOrder1, &
                                     Perturb=LIN_DX, LinNames=[TRIM(LinStr)//' dl1, m'] )
                  ELSE
                     CALL MV_AddVar( Vars%x, LinStr, FieldScalar, DatLoc(CD_x_states), &
                                     iAry=m%LineStateIs1(il) + 3*nin + j - 1, Num=1, Flags=VF_DerivOrder1, &
                                     Perturb=LIN_DSLOW, LinNames=[TRIM(LinStr)//' slow strain, -'] )
                  END IF
               END DO
            END DO
         END DO
      ELSE

      ! position states (interior line nodes; the mirror layout stores [rd, r] per
      ! line, so positions start at LineStateIs1 + 3*(N-1)).
      ! NB the inline LinNames constructors below are SAFE: each element is TRIM(LinStr) (a
      ! fixed scalar) concatenated with a PARAMETER-array suffix element -- no function call
      ! inside the constructor. The heap-corruption class this file guards against (see the
      ! finite-EI cable block and the WriteOutput block, both built via explicit loops) is
      ! specifically an implied-do character array constructor whose element expression calls
      ! a function that performs internal I/O (Num2LStr does a WRITE); those must be pre-built.
      DO il = 1, inst_%nlines
         ndofl = CD_System_Line_NDOF( inst_%agg%sys%fast%system, il, es, em )
         IF (es /= CD_SYSTEM_OK) THEN
            CALL SetErrStat( ErrID_Fatal, TRIM(em), ErrStat, ErrMsg, RoutineName ); RETURN
         END IF
         N = ndofl/3 - 1                       ! number of segments
         DO i = 0, N - 2
            LinStr = 'Line '//TRIM(Num2LStr(il))//' node '//TRIM(Num2LStr(i + 1))
            CALL MV_AddVar( Vars%x, LinStr, FieldTransDisp, DatLoc(CD_x_states), &
                            iAry=m%LineStateIs1(il) + 3*(N - 1) + 3*i, &
                            Num=3, Flags=VF_DerivOrder2, Perturb=0.05_R8Ki, &
                            LinNames=[(TRIM(LinStr)//TransDispSuffix(j), j=1, 3)] )
         END DO
      END DO

      ! velocity states
      DO il = 1, inst_%nlines
         ndofl = CD_System_Line_NDOF( inst_%agg%sys%fast%system, il, es, em )
         IF (es /= CD_SYSTEM_OK) THEN
            CALL SetErrStat( ErrID_Fatal, TRIM(em), ErrStat, ErrMsg, RoutineName ); RETURN
         END IF
         N = ndofl/3 - 1
         DO i = 0, N - 2
            LinStr = 'Line '//TRIM(Num2LStr(il))//' node '//TRIM(Num2LStr(i + 1))
            CALL MV_AddVar( Vars%x, LinStr, FieldTransVel, DatLoc(CD_x_states), &
                            iAry=m%LineStateIs1(il) + 3*i, &
                            Num=3, Flags=VF_DerivOrder2, Perturb=0.1_R8Ki, &
                            LinNames=[(TRIM(LinStr)//TransVelSuffix(j), j=1, 3)] )
         END DO
      END DO

      ! acceleration states: the third mirror block per line reloads the committed
      ! generalised-alpha acceleration on checkpoint restart. Registered as ONE generic
      ! (FieldScalar) coverage block per line -- acceleration is not a linearization
      ! field, and the linearization registers no x variables; the goal is that Vars%x
      ! covers the WHOLE mirror so the framework pack/unpack sizing stays consistent
      ! (the Init-time size assertion below enforces exactly that).
      DO il = 1, inst_%nlines
         ndofl = CD_System_Line_NDOF( inst_%agg%sys%fast%system, il, es, em )
         IF (es /= CD_SYSTEM_OK) THEN
            CALL SetErrStat( ErrID_Fatal, TRIM(em), ErrStat, ErrMsg, RoutineName ); RETURN
         END IF
         nin = ndofl - 6
         LinStr = 'Line '//TRIM(Num2LStr(il))
         ALLOCATE (CblLinVel(nin), STAT=ErrStat2)
         IF (ErrStat2 /= 0) THEN
            CALL SetErrStat( ErrID_Fatal, 'Could not allocate line accel lin-name work array.', &
                             ErrStat, ErrMsg, RoutineName ); RETURN
         END IF
         DO j = 1, nin
            CblLinVel(j) = TRIM(LinStr)//' interior accel '//TRIM(Num2LStr(j))
         END DO
         CALL MV_AddVar( Vars%x, TRIM(LinStr)//' interior accel', FieldScalar, DatLoc(CD_x_states), &
                         iAry=m%LineStateIs1(il) + 2*nin, Num=nin, Perturb=0.1_R8Ki, &
                         LinNames=CblLinVel )
         DEALLOCATE (CblLinVel)
      END DO

      ! viscoelastic dl_1 states: the per-element series-Kelvin internal strain appended after the
      ! interior [rd; r; rdd] block for a viscoelastic line (mirror offset LineStateIs1 +
      ! 3*nin). Registered as a generic FieldScalar coverage block (not a linearization
      ! field) so Vars%x covers the WHOLE mirror -- the Init-time Vars%Nx == m%Nx assertion.
      DO il = 1, inst_%nlines
         IF (.NOT. CD_System_Line_Has_Viscoelastic( inst_%agg%sys%fast%system, il )) CYCLE
         ndofl = CD_System_Line_NDOF( inst_%agg%sys%fast%system, il, es, em )
         IF (es /= CD_SYSTEM_OK) THEN
            CALL SetErrStat( ErrID_Fatal, TRIM(em), ErrStat, ErrMsg, RoutineName ); RETURN
         END IF
         nin = ndofl - 6
         nve = CD_System_Line_NElem( inst_%agg%sys%fast%system, il, es, em )
         IF (es /= CD_SYSTEM_OK) THEN
            CALL SetErrStat( ErrID_Fatal, TRIM(em), ErrStat, ErrMsg, RoutineName ); RETURN
         END IF
         LinStr = 'Line '//TRIM(Num2LStr(il))
         ALLOCATE (CblLinVel(nve), STAT=ErrStat2)
         IF (ErrStat2 /= 0) THEN
            CALL SetErrStat( ErrID_Fatal, 'Could not allocate line dl_1 lin-name work array.', &
                             ErrStat, ErrMsg, RoutineName ); RETURN
         END IF
         DO j = 1, nve
            CblLinVel(j) = TRIM(LinStr)//' viscoelastic dl_1 '//TRIM(Num2LStr(j))
         END DO
         CALL MV_AddVar( Vars%x, TRIM(LinStr)//' viscoelastic dl_1', FieldScalar, DatLoc(CD_x_states), &
                         iAry=m%LineStateIs1(il) + 3*nin, Num=nve, Perturb=0.1_R8Ki, &
                         LinNames=CblLinVel )
         DEALLOCATE (CblLinVel)
      END DO

      ! Syrope states: two per-element blocks (slow-spring static strain then running-
      ! maximum tension) appended after the interior block for a Syrope line (mirror
      ! offset LineStateIs1 + 3*nin; a line is viscoelastic OR Syrope, never both).
      ! Registered as a generic FieldScalar coverage block so Vars%x covers the WHOLE
      ! mirror -- the Init-time Vars%Nx == m%Nx assertion.
      DO il = 1, inst_%nlines
         IF (.NOT. CD_System_Line_Has_Syrope( inst_%agg%sys%fast%system, il )) CYCLE
         ndofl = CD_System_Line_NDOF( inst_%agg%sys%fast%system, il, es, em )
         IF (es /= CD_SYSTEM_OK) THEN
            CALL SetErrStat( ErrID_Fatal, TRIM(em), ErrStat, ErrMsg, RoutineName ); RETURN
         END IF
         nin = ndofl - 6
         nve = CD_System_Line_NElem( inst_%agg%sys%fast%system, il, es, em )
         IF (es /= CD_SYSTEM_OK) THEN
            CALL SetErrStat( ErrID_Fatal, TRIM(em), ErrStat, ErrMsg, RoutineName ); RETURN
         END IF
         LinStr = 'Line '//TRIM(Num2LStr(il))
         ALLOCATE (CblLinVel(2*nve), STAT=ErrStat2)
         IF (ErrStat2 /= 0) THEN
            CALL SetErrStat( ErrID_Fatal, 'Could not allocate line Syrope lin-name work array.', &
                             ErrStat, ErrMsg, RoutineName ); RETURN
         END IF
         DO j = 1, nve
            CblLinVel(j)       = TRIM(LinStr)//' Syrope slow '//TRIM(Num2LStr(j))
            CblLinVel(nve + j) = TRIM(LinStr)//' Syrope tmax '//TRIM(Num2LStr(j))
         END DO
         CALL MV_AddVar( Vars%x, TRIM(LinStr)//' Syrope state', FieldScalar, DatLoc(CD_x_states), &
                         iAry=m%LineStateIs1(il) + 3*nin, Num=2*nve, Perturb=0.1_R8Ki, &
                         LinNames=CblLinVel )
         DEALLOCATE (CblLinVel)
      END DO

      ! VIV states: the shedding phase and running mean squares per node and the averaging
      ! time, the last block of a VIV line's span. Coverage-only, like the Syrope block.
      DO il = 1, inst_%nlines
         nve = CD_System_Line_VIV_MirrorSize( inst_%agg%sys%fast%system, il )
         IF (nve <= 0) CYCLE
         LinStr = 'Line '//TRIM(Num2LStr(il))
         ALLOCATE (CblLinVel(nve), STAT=ErrStat2)
         IF (ErrStat2 /= 0) THEN
            CALL SetErrStat( ErrID_Fatal, 'Could not allocate line VIV lin-name work array.', &
                             ErrStat, ErrMsg, RoutineName ); RETURN
         END IF
         DO j = 1, nve
            CblLinVel(j) = TRIM(LinStr)//' VIV state '//TRIM(Num2LStr(j))
         END DO
         CALL MV_AddVar( Vars%x, TRIM(LinStr)//' VIV state', FieldScalar, DatLoc(CD_x_states), &
                         iAry=m%LineStateIsN(il) - nve + 1, Num=nve, Perturb=0.1_R8Ki, &
                         LinNames=CblLinVel )
         DEALLOCATE (CblLinVel)
      END DO

      ! finite-EI cable states: pack_state_mirror appends the free-DOF mirror
      ! [v_free; q_free] of each cable AFTER the EI=0 mooring block, at the x%states
      ! offset koff = LineStateIsN(nlines) (0 when there are no mooring lines). Register
      ! the SAME index range here so Vars%x covers the WHOLE mirror (the appended cable
      ! slots were previously invisible to the framework pack/unpack). The free DOFs of
      ! a cable mix a node translation r and tangent m -- they are NOT per-node
      ! 3-vectors -- so each cable contributes two GENERIC (FieldScalar) blocks, a
      ! velocity half then a position half, each sized to the free-DOF count. This is
      ! a size/index mirror (the linearization registers no x variables), so the
      ! goal is index coverage, not a physically-typed linearization surface.
      koff = 0
      IF (inst_%nlines > 0) koff = m%LineStateIsN(inst_%nlines)
      DO ic = 1, inst_%agg%ncable
         csz = CD_HFMF_MirrorSize( inst_%agg%cables(ic) )
         IF (csz <= 0) CYCLE                 ! uninitialised cable contributes no states
         ! free DOFs; mirror = [v_free; q_free; a_free] then the friction anchors, the
         ! committed boundary, the force-blend state, the VIV state and the torsion state (if any)
         nf = (csz - CD_HFMF_FrictionMirrorSize( inst_%agg%cables(ic) ) - &
               CD_HFMF_BoundaryMirrorSize( inst_%agg%cables(ic) ) - &
               CD_HFMF_ForceMirrorSize( inst_%agg%cables(ic) ) - &
               CD_HFMF_VIVMirrorSize( inst_%agg%cables(ic) ) - &
               CD_HFMF_TorsionMirrorSize( inst_%agg%cables(ic) ))/3
         LinStr = 'Cable '//TRIM(Num2LStr(ic))
         ! Build the per-DOF linearization names in an explicit pre-allocated loop, NOT an
         ! inline implied-do array constructor: an impure function (Num2LStr) evaluated inside
         ! a character array constructor mismanages compiler temporaries and corrupts the heap.
         ! This is the SAME failure class fixed for the WriteOutput var below -- fix the class,
         ! not the instance (the WriteOutput fix missed these two cable-var instances).
         ALLOCATE (CblLinVel(nf), CblLinPos(nf), CblLinAcc(nf), STAT=ErrStat2)
         IF (ErrStat2 /= 0) THEN
            CALL SetErrStat( ErrID_Fatal, 'Could not allocate cable lin-name work arrays.', &
                             ErrStat, ErrMsg, RoutineName ); RETURN
         END IF
         DO j = 1, nf
            CblLinVel(j) = TRIM(LinStr)//' free-DOF vel '//TRIM(Num2LStr(j))
            CblLinPos(j) = TRIM(LinStr)//' free-DOF pos '//TRIM(Num2LStr(j))
            CblLinAcc(j) = TRIM(LinStr)//' free-DOF accel '//TRIM(Num2LStr(j))
         END DO
         ! velocity block -> x%states(koff+1 : koff+nf)
         CALL MV_AddVar( Vars%x, TRIM(LinStr)//' free-DOF vel', FieldScalar, DatLoc(CD_x_states), &
                         iAry=koff + 1, Num=nf, Flags=VF_DerivOrder2, DerivOrder=1, Perturb=0.1_R8Ki, &
                         LinNames=CblLinVel )
         ! position block -> x%states(koff+nf+1 : koff+2*nf)
         CALL MV_AddVar( Vars%x, TRIM(LinStr)//' free-DOF pos', FieldScalar, DatLoc(CD_x_states), &
                         iAry=koff + nf + 1, Num=nf, Flags=VF_DerivOrder2, DerivOrder=0, Perturb=0.05_R8Ki, &
                         LinNames=CblLinPos )
         ! acceleration block -> x%states(koff+2*nf+1 : koff+3*nf): the committed
         ! gen-alpha acceleration, carried for exact checkpoint restart (coverage-only,
         ! like the mooring interior-accel block above)
         CALL MV_AddVar( Vars%x, TRIM(LinStr)//' free-DOF accel', FieldScalar, DatLoc(CD_x_states), &
                         iAry=koff + 2*nf + 1, Num=nf, Perturb=0.1_R8Ki, &
                         LinNames=CblLinAcc )
         DEALLOCATE (CblLinVel, CblLinPos, CblLinAcc)
         ! stick-slip friction anchors (x, y per node), the force-blend committed force
         ! (flag + force), the VIV state and the torsion state (Theta, Phi, end frames) after
         ! the acceleration block: coverage-only, like the acceleration block
         IF (csz > 3*nf) THEN
            ALLOCATE (CblLinVel(csz - 3*nf), STAT=ErrStat2)
            IF (ErrStat2 /= 0) THEN
               CALL SetErrStat( ErrID_Fatal, 'Could not allocate cable state lin-name work array.', &
                                ErrStat, ErrMsg, RoutineName ); RETURN
            END IF
            DO j = 1, csz - 3*nf
               CblLinVel(j) = TRIM(LinStr)//' integrator state '//TRIM(Num2LStr(j))
            END DO
            CALL MV_AddVar( Vars%x, TRIM(LinStr)//' integrator state', FieldScalar, DatLoc(CD_x_states), &
                            iAry=koff + 3*nf + 1, Num=csz - 3*nf, Perturb=0.1_R8Ki, LinNames=CblLinVel )
            DEALLOCATE (CblLinVel)
         END IF
         koff = koff + csz
      END DO

      ! coupled Rigid6 6-DOF body state: coverage-only registration after the cable blocks (Vars%Nx
      ! must equal the mirror size m%Nx). Names built in a pre-allocated loop, NOT an implied-do with
      ! an impure Num2LStr inside an array constructor (that corrupts compiler temporaries -- the heap
      ! class fixed for the cable/WriteOutput vars).
      IF (CD_AGG_HasRigid6( inst_%agg )) THEN
         BLOCK
            INTEGER(IntKi) :: r6sz, j2
            r6sz = CD_AGG_Rigid6_MirrorSize( inst_%agg )
            IF (r6sz > 0) THEN
               ALLOCATE (CblLinVel(r6sz), STAT=ErrStat2)
               IF (ErrStat2 /= 0) THEN
                  CALL SetErrStat( ErrID_Fatal, 'Could not allocate Rigid6 lin-name work array.', &
                                   ErrStat, ErrMsg, RoutineName ); RETURN
               END IF
               DO j2 = 1, r6sz
                  CblLinVel(j2) = 'Rigid6 body-state '//TRIM(Num2LStr(j2))
               END DO
               CALL MV_AddVar( Vars%x, 'Rigid6 body-state', FieldScalar, DatLoc(CD_x_states), &
                               iAry=koff + 1, Num=r6sz, Perturb=0.1_R8Ki, LinNames=CblLinVel )
               DEALLOCATE (CblLinVel)
               koff = koff + r6sz
            END IF
         END BLOCK
      END IF

      IF (CD_AGG_HasRod( inst_%agg )) THEN
         BLOCK
            INTEGER(IntKi) :: rdsz, j2
            rdsz = CD_AGG_Rod_MirrorSize( inst_%agg )
            IF (rdsz > 0) THEN
               ALLOCATE (CblLinVel(rdsz), STAT=ErrStat2)
               IF (ErrStat2 /= 0) THEN
                  CALL SetErrStat( ErrID_Fatal, 'Could not allocate rigid-rod lin-name work array.', &
                                   ErrStat, ErrMsg, RoutineName ); RETURN
               END IF
               DO j2 = 1, rdsz
                  CblLinVel(j2) = 'Rigid rod state '//TRIM(Num2LStr(j2))
               END DO
               CALL MV_AddVar( Vars%x, 'Rigid rod state', FieldScalar, DatLoc(CD_x_states), &
                               iAry=koff + 1, Num=rdsz, Perturb=0.1_R8Ki, LinNames=CblLinVel )
               DEALLOCATE (CblLinVel)
               koff = koff + rdsz
            END IF
         END BLOCK
      END IF

      ! EI=0 line stick-slip friction anchors: coverage-only registration after the rod block.
      BLOCK
         INTEGER(IntKi) :: frsz, j2
         frsz = line_friction_mirror_size( inst_ )
         IF (frsz > 0) THEN
            ALLOCATE (CblLinVel(frsz), STAT=ErrStat2)
            IF (ErrStat2 /= 0) THEN
               CALL SetErrStat( ErrID_Fatal, 'Could not allocate line friction lin-name work array.', &
                                ErrStat, ErrMsg, RoutineName ); RETURN
            END IF
            DO j2 = 1, frsz
               CblLinVel(j2) = 'Line friction anchor '//TRIM(Num2LStr(j2))
            END DO
            CALL MV_AddVar( Vars%x, 'Line friction anchor', FieldScalar, DatLoc(CD_x_states), &
                            iAry=koff + 1, Num=frsz, Perturb=0.1_R8Ki, LinNames=CblLinVel )
            DEALLOCATE (CblLinVel)
            koff = koff + frsz
         END IF
      END BLOCK

      ! the compact coupled-motion vector [q; v; a] (per-LINE-END slots) of every deck with
      ! EI=0 lines, then block 2 of dynamic (Free/Connect) points. Coverage-only
      ! registration like every trailing block -- Vars%Nx must equal the mirror size m%Nx.
      IF (inst_%agg%has_sys) THEN
         BLOCK
            INTEGER(IntKi) :: ncd2
            ncd2 = CD_System_NSystemCoupledDOF( inst_%agg%sys%fast%system )
            ALLOCATE (CblLinVel(ncd2), CblLinPos(ncd2), CblLinAcc(ncd2), STAT=ErrStat2)
            IF (ErrStat2 /= 0) THEN
               CALL SetErrStat( ErrID_Fatal, 'Could not allocate coupled-vector lin-name work arrays.', &
                                ErrStat, ErrMsg, RoutineName ); RETURN
            END IF
            DO j = 1, ncd2
               CblLinPos(j) = 'CoupledVec pos '//TRIM(Num2LStr(j))
               CblLinVel(j) = 'CoupledVec vel '//TRIM(Num2LStr(j))
               CblLinAcc(j) = 'CoupledVec accel '//TRIM(Num2LStr(j))
            END DO
            CALL MV_AddVar( Vars%x, 'CoupledVec pos', FieldScalar, DatLoc(CD_x_states), &
                            iAry=koff + 1, Num=ncd2, Perturb=0.05_R8Ki, LinNames=CblLinPos )
            CALL MV_AddVar( Vars%x, 'CoupledVec vel', FieldScalar, DatLoc(CD_x_states), &
                            iAry=koff + ncd2 + 1, Num=ncd2, Perturb=0.1_R8Ki, LinNames=CblLinVel )
            CALL MV_AddVar( Vars%x, 'CoupledVec accel', FieldScalar, DatLoc(CD_x_states), &
                            iAry=koff + 2*ncd2 + 1, Num=ncd2, Perturb=0.1_R8Ki, LinNames=CblLinAcc )
            DEALLOCATE (CblLinVel, CblLinPos, CblLinAcc)
            koff = koff + 3*ncd2
         END BLOCK
      END IF
      ! dynamic (Free/Connect) points, block 2: the trailing per-point [v; q; a] mirror block.
      ! Coverage-only index registration (like the accel blocks above) so Vars%Nx equals
      ! the mirror size m%Nx -- without it the drift check below kills EVERY dynamic-
      ! point deck at Init, not just restarts. LinNames use the same explicit
      ! pre-allocated loop as the cable blocks (the impure-function-in-array-constructor
      ! heap-corruption class).
      DO j = 1, CD_AGG_NDynamicPoints( inst_%agg )
         LinStr = 'DynPoint '//TRIM(Num2LStr(j))
         ALLOCATE (CblLinVel(3), CblLinPos(3), CblLinAcc(3), STAT=ErrStat2)
         IF (ErrStat2 /= 0) THEN
            CALL SetErrStat( ErrID_Fatal, 'Could not allocate dynamic-point lin-name work arrays.', &
                             ErrStat, ErrMsg, RoutineName ); RETURN
         END IF
         DO ic = 1, 3
            CblLinVel(ic) = TRIM(LinStr)//' vel '//TRIM(Num2LStr(ic))
            CblLinPos(ic) = TRIM(LinStr)//' pos '//TRIM(Num2LStr(ic))
            CblLinAcc(ic) = TRIM(LinStr)//' accel '//TRIM(Num2LStr(ic))
         END DO
         CALL MV_AddVar( Vars%x, TRIM(LinStr)//' vel', FieldScalar, DatLoc(CD_x_states), &
                         iAry=koff + 1, Num=3, Flags=VF_DerivOrder2, DerivOrder=1, Perturb=0.1_R8Ki, &
                         LinNames=CblLinVel )
         CALL MV_AddVar( Vars%x, TRIM(LinStr)//' pos', FieldScalar, DatLoc(CD_x_states), &
                         iAry=koff + 4, Num=3, Flags=VF_DerivOrder2, DerivOrder=0, Perturb=0.05_R8Ki, &
                         LinNames=CblLinPos )
         CALL MV_AddVar( Vars%x, TRIM(LinStr)//' accel', FieldScalar, DatLoc(CD_x_states), &
                         iAry=koff + 7, Num=3, Perturb=0.1_R8Ki, &
                         LinNames=CblLinAcc )
         DEALLOCATE (CblLinVel, CblLinPos, CblLinAcc)
         koff = koff + 9
      END DO
      ! FAILURE fired flags: coverage-only registration of the mirror tail (0/1 per
      ! row) so Vars%Nx equals m%Nx -- the drift-guard class. Same explicit
      ! pre-allocated LinNames loop as every block above.
      IF (CD_AGG_NFailures( inst_%agg ) > 0) THEN
         BLOCK
            INTEGER(IntKi) :: nfl2
            nfl2 = CD_AGG_NFailures( inst_%agg )
            ALLOCATE (CblLinPos(nfl2), STAT=ErrStat2)
            IF (ErrStat2 /= 0) THEN
               CALL SetErrStat( ErrID_Fatal, 'Could not allocate failure-flag lin-name work array.', &
                                ErrStat, ErrMsg, RoutineName ); RETURN
            END IF
            DO j = 1, nfl2
               CblLinPos(j) = 'FailFlag '//TRIM(Num2LStr(j))
            END DO
            CALL MV_AddVar( Vars%x, 'FailFlag', FieldScalar, DatLoc(CD_x_states), &
                            iAry=koff + 1, Num=nfl2, Perturb=0.1_R8Ki, &
                            LinNames=CblLinPos )
            DEALLOCATE (CblLinPos)
            koff = koff + nfl2
         END BLOCK
      END IF

      END IF   ! .NOT. Linearize (the x-variable registration)

      ! input variables: the coupled-kinematics mesh
      ALLOCATE (Vars%u(0), STAT=ErrStat2)
      IF (ErrStat2 /= 0) THEN
         CALL SetErrStat( ErrID_Fatal, 'Could not allocate Vars%u.', ErrStat, ErrMsg, RoutineName ); RETURN
      END IF
      ! one mesh variable per turbine (FAST.Farm); plain mode is the 1-mesh case
      DO ivT = 1, MAX(1, inst_%nT)
         CALL MV_AddMeshVar( Vars%u, "CoupledKinematics", MotionFields, &
                             DatLoc(CD_u_CoupledKinematics, ivT), &
                             Mesh=u%CoupledKinematics(ivT), &
                             Perturbs=[dx_u, &        ! FieldTransDisp
                                       dx_rot, &      ! FieldOrientation
                                       0.1_R8Ki, &    ! FieldTransVel
                                       0.1_R8Ki, &    ! FieldAngularVel
                                       0.1_R8Ki, &    ! FieldTransAcc
                                       0.1_R8Ki] )    ! FieldAngularAcc
      END DO

      ! output variables: the coupled-loads mesh, then the WriteOutput channels
      ALLOCATE (Vars%y(0), STAT=ErrStat2)
      IF (ErrStat2 /= 0) THEN
         CALL SetErrStat( ErrID_Fatal, 'Could not allocate Vars%y.', ErrStat, ErrMsg, RoutineName ); RETURN
      END IF
      DO ivT = 1, MAX(1, inst_%nT)
         CALL MV_AddMeshVar( Vars%y, "CoupledLoads", LoadFields, &
                             DatLoc(CD_y_CoupledLoads, ivT), &
                             Mesh=y%CoupledLoads(ivT) )
      END DO

      ! WriteOutput channels (the OrcaFlex-vocabulary deck OUTPUTS), registered as a scalar
      ! array so linearization / visualization see them -- the same y-variable MoorDyn adds for
      ! its WriteOutput. Registered ONLY when the deck declares channels, so a channel-free deck
      ! keeps Vars%y carrying just the loads mesh (byte-identical to the pre-channel module) and
      ! MV_InitVarsJac counts no extra y-slots. The linearization names ("Header, Unit") are built
      ! into an explicit array first (the aggregate owns the header/unit; InitOut is out of scope).
      IF (p%NumOuts > 0) THEN
         ALLOCATE (WrOutLinNames(p%NumOuts), STAT=ErrStat2)
         IF (ErrStat2 /= 0) THEN
            CALL SetErrStat( ErrID_Fatal, 'Could not allocate WriteOutput lin-name work array.', &
                             ErrStat, ErrMsg, RoutineName ); RETURN
         END IF
         DO j = 1, p%NumOuts
            CALL CD_AGG_ChannelHeader( inst_%agg, j, whdr, wunt, es, em )
            WrOutLinNames(j) = TRIM(whdr)//', '//TRIM(wunt)
         END DO
         CALL MV_AddVar( Vars%y, "WriteOutput", FieldScalar, DatLoc(CD_y_WriteOutput), &
                         Flags=VF_WriteOut, Num=p%NumOuts, LinNames=WrOutLinNames )
         DEALLOCATE (WrOutLinNames)
      END IF

      ! finalize the variable metadata + the Jacobian workspace in m%Jac
      CALL MV_InitVarsJac( Vars, m%Jac, Linearize, ErrStat2, ErrMsg2 )
      CALL SetErrStat( ErrStat2, ErrMsg2, ErrStat, ErrMsg, RoutineName )
      IF (ErrStat >= AbortErrLev) RETURN

      ! Self-consistency guard: the registered continuous-state variables MUST cover
      ! EXACTLY the state mirror x%states(1:m%Nx) that pack_state_mirror writes.
      ! MV_InitVarsJac has set Vars%Nx = sum(Vars%x%Num); if a future change grows the
      ! mirror (a new state block) without a matching MV_AddVar here (or shrinks it),
      ! the packed x-variable size and m%Nx drift apart -- fail LOUDLY at init instead
      ! of silently leaving mirror slots invisible to pack/unpack/checkpoint.
      IF (.NOT. Linearize .AND. Vars%Nx /= m%Nx) THEN
         CALL SetErrStat( ErrID_Fatal, 'CableDyn mooring module: the registered continuous-state '// &
                          'variable size ('//TRIM(Num2LStr(Vars%Nx))//') does not equal the state '// &
                          'mirror size m%Nx ('//TRIM(Num2LStr(m%Nx))//'); the ModVars x-registration '// &
                          'and the pack_state_mirror layout have drifted apart.', ErrStat, ErrMsg, RoutineName )
         RETURN
      END IF

      ! linearization workspaces used by the FD Jacobian
      CALL CD_CopyInput( u, m%u_perturb, MESH_NEWCOPY, ErrStat2, ErrMsg2 )
      CALL SetErrStat( ErrStat2, ErrMsg2, ErrStat, ErrMsg, RoutineName )
      CALL CD_CopyOutput( y, m%y_lin, MESH_NEWCOPY, ErrStat2, ErrMsg2 )
      CALL SetErrStat( ErrStat2, ErrMsg2, ErrStat, ErrMsg, RoutineName )
      CALL CD_CopyContState( x, m%x_perturb, MESH_NEWCOPY, ErrStat2, ErrMsg2 )
      CALL SetErrStat( ErrStat2, ErrMsg2, ErrStat, ErrMsg, RoutineName )
      CALL CD_CopyContState( x, m%dxdt_lin, MESH_NEWCOPY, ErrStat2, ErrMsg2 )
      CALL SetErrStat( ErrStat2, ErrMsg2, ErrStat, ErrMsg, RoutineName )

   END SUBROUTINE CD_InitVars

   SUBROUTINE reload_interiors_ary(inst_, m, states, t_clock, ErrStat, ErrMsg)
      !! Reload the committed solver state from a mirror array (the checkpoint
      !! x%states layout): interior [rd; r; rdd] per mooring line -- the acceleration
      !! block restores the gen-alpha COMMITTED acceleration exactly (a re-derivation
      !! would move the first restored load evaluation) -- and each cable's
      !! [v; q; a] free-DOF mirror. Shared by the checkpoint rebuild and the
      !! state-const CalcOutput restore.
      TYPE(CD_OF_Instance),         INTENT(INOUT) :: inst_
      TYPE(CD_MiscVarType),         INTENT(IN)    :: m
      REAL(R8Ki),                   INTENT(IN)    :: states(:)
      REAL(wp),                     INTENT(IN)    :: t_clock
      INTEGER(IntKi),               INTENT(OUT)   :: ErrStat
      CHARACTER(*),                 INTENT(OUT)   :: ErrMsg

      character(*), parameter :: RoutineName = 'CableDyn:reload_interiors'
      INTEGER(IntKi)          :: es, il, ndofl, nin, k, ic, csz, koff, npd, ncd, nfl, nve
      CHARACTER(ErrMsgLen)          :: em

      ErrStat = ErrID_None
      ErrMsg  = ''
      DO il = 1, inst_%nlines
         ndofl = CD_System_Line_NDOF( inst_%agg%sys%fast%system, il, es, em )
         IF (es /= CD_SYSTEM_OK) THEN
            CALL SetErrStat( ErrID_Fatal, TRIM(em), ErrStat, ErrMsg, RoutineName ); RETURN
         END IF
         nin = ndofl - 6
         k = m%LineStateIs1(il)
         ! a one-segment line (NumSegs = 1, n_dof = 6) has NO interior DOFs: nothing
         ! to reload for the interior, and the model-level interior update rightly
         ! rejects zero-length arrays -- guard the interior block, but STILL reload a
         ! viscoelastic dl_1 tail below (a 1-segment line has one element with dl_1)
         IF (nin > 0) THEN
            IF (k + 3*nin - 1 > SIZE(states)) THEN
               CALL SetErrStat( ErrID_Fatal, 'CableDyn mooring module: line '//TRIM(Num2LStr(il))// &
                                ' state-mirror extent does not match the mesh.', ErrStat, ErrMsg, RoutineName )
               RETURN
            END IF
            IF (ALLOCATED(inst_%ws_qL)) THEN
               IF (SIZE(inst_%ws_qL) < nin) DEALLOCATE (inst_%ws_qL, inst_%ws_vL, inst_%ws_aL)
            END IF
            IF (.NOT. ALLOCATED(inst_%ws_qL)) ALLOCATE (inst_%ws_qL(ndofl), inst_%ws_vL(ndofl), inst_%ws_aL(ndofl))
            inst_%ws_vL(1:nin) = REAL(states(k:k + nin - 1), wp)
            inst_%ws_qL(1:nin) = REAL(states(k + nin:k + 2*nin - 1), wp)
            inst_%ws_aL(1:nin) = REAL(states(k + 2*nin:k + 3*nin - 1), wp)
            CALL CD_Update_System_Line_Interior_State( inst_%agg%sys%fast%system, il, &
                                                       inst_%ws_qL(1:nin), inst_%ws_vL(1:nin), es, em, &
                                                       a_interior=inst_%ws_aL(1:nin) )
            IF (es /= CD_SYSTEM_OK) THEN
               CALL SetErrStat( ErrID_Fatal, TRIM(em), ErrStat, ErrMsg, RoutineName ); RETURN
            END IF
         END IF
         ! viscoelastic dl_1 reload: the per-element tail packed after the interior block
         ! (mirrors pack_state_mirror; independent of nin so 1-segment lines restore too)
         IF (CD_System_Line_Has_Viscoelastic( inst_%agg%sys%fast%system, il )) THEN
            nve = CD_System_Line_NElem( inst_%agg%sys%fast%system, il, es, em )
            IF (es /= CD_SYSTEM_OK) THEN
               CALL SetErrStat( ErrID_Fatal, TRIM(em), ErrStat, ErrMsg, RoutineName ); RETURN
            END IF
            IF (k + 3*nin + nve - 1 > SIZE(states)) THEN
               CALL SetErrStat( ErrID_Fatal, 'CableDyn mooring module: line '//TRIM(Num2LStr(il))// &
                                ' viscoelastic dl_1 mirror extends past the state vector.', &
                                ErrStat, ErrMsg, RoutineName )
               RETURN
            END IF
            BLOCK
               REAL(wp) :: dl1(nve)
               dl1 = REAL(states(k + 3*nin:k + 3*nin + nve - 1), wp)
               CALL CD_Set_System_Line_VE_Dl1( inst_%agg%sys%fast%system, il, dl1, es, em )
               IF (es /= CD_SYSTEM_OK) THEN
                  CALL SetErrStat( ErrID_Fatal, TRIM(em), ErrStat, ErrMsg, RoutineName ); RETURN
               END IF
            END BLOCK
         END IF
         ! Syrope state reload: two per-element tail blocks (slow then tmax) after the
         ! interior block (mirrors pack_state_mirror; independent of nin)
         IF (CD_System_Line_Has_Syrope( inst_%agg%sys%fast%system, il )) THEN
            nve = CD_System_Line_NElem( inst_%agg%sys%fast%system, il, es, em )
            IF (es /= CD_SYSTEM_OK) THEN
               CALL SetErrStat( ErrID_Fatal, TRIM(em), ErrStat, ErrMsg, RoutineName ); RETURN
            END IF
            IF (k + 3*nin + 2*nve - 1 > SIZE(states)) THEN
               CALL SetErrStat( ErrID_Fatal, 'CableDyn mooring module: line '//TRIM(Num2LStr(il))// &
                                ' Syrope state mirror extends past the state vector.', ErrStat, ErrMsg, RoutineName )
               RETURN
            END IF
            BLOCK
               REAL(wp) :: slw(nve), tmx(nve)
               slw = REAL(states(k + 3*nin:k + 3*nin + nve - 1), wp)
               tmx = REAL(states(k + 3*nin + nve:k + 3*nin + 2*nve - 1), wp)
               CALL CD_Set_System_Line_Syrope_State( inst_%agg%sys%fast%system, il, slw, tmx, es, em )
               IF (es /= CD_SYSTEM_OK) THEN
                  CALL SetErrStat( ErrID_Fatal, TRIM(em), ErrStat, ErrMsg, RoutineName ); RETURN
               END IF
            END BLOCK
         END IF
         ! VIV state reload: the last block of the line's span (mirrors pack_state_mirror)
         nve = CD_System_Line_VIV_MirrorSize( inst_%agg%sys%fast%system, il )
         IF (nve > 0) THEN
            IF (m%LineStateIsN(il) > SIZE(states)) THEN
               CALL SetErrStat( ErrID_Fatal, 'CableDyn mooring module: line '//TRIM(Num2LStr(il))// &
                                ' VIV state mirror extends past the state vector.', ErrStat, ErrMsg, RoutineName )
               RETURN
            END IF
            BLOCK
               REAL(wp) :: vbuf(nve)
               vbuf = REAL(states(m%LineStateIsN(il) - nve + 1:m%LineStateIsN(il)), wp)
               CALL CD_Set_System_Line_VIV_State( inst_%agg%sys%fast%system, il, vbuf, es, em )
               IF (es /= CD_SYSTEM_OK) THEN
                  CALL SetErrStat( ErrID_Fatal, TRIM(em), ErrStat, ErrMsg, RoutineName ); RETURN
               END IF
            END BLOCK
         END IF
      END DO
      CALL reload_cable_mirrors( inst_, m, states, t_clock, .FALSE., koff, ErrStat, ErrMsg )
      IF (ErrStat >= AbortErrLev) RETURN
      ! coupled Rigid6 6-DOF body state: restore after the cable block, before the dynamic points
      ! (the body drives its attachment points, so the restored pose re-derives them next advance)
      IF (CD_AGG_HasRigid6( inst_%agg )) THEN
         csz = CD_AGG_Rigid6_MirrorSize( inst_%agg )
         IF (csz > 0) THEN
            IF (koff + csz > SIZE(states)) THEN
               CALL SetErrStat( ErrID_Fatal, 'CableDyn mooring module: the Rigid6 body-state mirror '// &
                                'extends past the state vector.', ErrStat, ErrMsg, RoutineName ); RETURN
            END IF
            IF (ALLOCATED(inst_%ws_cbuf)) THEN
               IF (SIZE(inst_%ws_cbuf) < csz) DEALLOCATE (inst_%ws_cbuf)
            END IF
            IF (.NOT. ALLOCATED(inst_%ws_cbuf)) ALLOCATE (inst_%ws_cbuf(csz))
            inst_%ws_cbuf(1:csz) = REAL(states(koff + 1:koff + csz), wp)
            CALL CD_AGG_Set_Rigid6_States( inst_%agg, inst_%ws_cbuf(1:csz), es, em )
            IF (es /= CD_AGG_OK) THEN
               CALL SetErrStat( ErrID_Fatal, TRIM(em), ErrStat, ErrMsg, RoutineName ); RETURN
            END IF
            koff = koff + csz
         END IF
      END IF
      ! Coupled rigid-rod committed state follows the Rigid6 block. Set scatters
      ! Rod<N>A/B kinematics immediately, keeping restart-time output consistent.
      IF (CD_AGG_HasRod( inst_%agg )) THEN
         csz = CD_AGG_Rod_MirrorSize( inst_%agg )
         IF (csz > 0) THEN
            IF (koff + csz > SIZE(states)) THEN
               CALL SetErrStat( ErrID_Fatal, 'CableDyn mooring module: the rigid-rod state mirror '// &
                                'extends past the state vector.', ErrStat, ErrMsg, RoutineName ); RETURN
            END IF
            IF (ALLOCATED(inst_%ws_cbuf)) THEN
               IF (SIZE(inst_%ws_cbuf) < csz) DEALLOCATE (inst_%ws_cbuf)
            END IF
            IF (.NOT. ALLOCATED(inst_%ws_cbuf)) ALLOCATE (inst_%ws_cbuf(csz))
            inst_%ws_cbuf(1:csz) = REAL(states(koff + 1:koff + csz), wp)
            CALL CD_AGG_Set_Rod_States( inst_%agg, inst_%ws_cbuf(1:csz), es, em )
            IF (es /= CD_AGG_OK) THEN
               CALL SetErrStat( ErrID_Fatal, TRIM(em), ErrStat, ErrMsg, RoutineName ); RETURN
            END IF
            koff = koff + csz
         END IF
      END IF
      ! EI=0 line stick-slip friction anchors, line by line after the rod block
      IF (line_friction_mirror_size( inst_ ) > 0) THEN
         DO il = 1, inst_%nlines
            IF (.NOT. CD_System_Line_Has_Friction( inst_%agg%sys%fast%system, il )) CYCLE
            ndofl = CD_System_Line_NDOF( inst_%agg%sys%fast%system, il, es, em )
            IF (es /= CD_SYSTEM_OK) THEN
               CALL SetErrStat( ErrID_Fatal, TRIM(em), ErrStat, ErrMsg, RoutineName ); RETURN
            END IF
            csz = 2*(ndofl/3)
            IF (koff + csz > SIZE(states)) THEN
               CALL SetErrStat( ErrID_Fatal, 'CableDyn mooring module: line '//TRIM(Num2LStr(il))// &
                                ' friction-anchor mirror extends past the state vector.', ErrStat, ErrMsg, RoutineName )
               RETURN
            END IF
            BLOCK
               REAL(wp) :: anch(2, ndofl/3)
               anch = RESHAPE(REAL(states(koff + 1:koff + csz), wp), [2, ndofl/3])
               CALL CD_Set_System_Line_Friction_Anchors( inst_%agg%sys%fast%system, il, anch, es, em )
               IF (es /= CD_SYSTEM_OK) THEN
                  CALL SetErrStat( ErrID_Fatal, TRIM(em), ErrStat, ErrMsg, RoutineName ); RETURN
               END IF
            END BLOCK
            koff = koff + csz
         END DO
      END IF
      ! dynamic (Free/Connect) points: the per-point store FIRST (its self-sufficient
      ! scatter positions the point slots), then the compact coupled-motion vector LAST
      ! -- the CHECKPOINTED ENDPOINT TRUTH must win on every coupled slot, so it is
      ! applied after any store scatter could touch them (at pack time store and vector
      ! point slots are bit-equal by the step's commit contract, but the reload order
      ! guarantees the vector's values regardless).
      npd = 9*CD_AGG_NDynamicPoints( inst_%agg )
      IF (npd == 0 .AND. inst_%agg%has_sys) THEN
         ! no dynamic points: restore the committed boundary kinematics
         ncd = CD_System_NSystemCoupledDOF( inst_%agg%sys%fast%system )
         IF (koff + 3*ncd > SIZE(states)) THEN
            CALL SetErrStat( ErrID_Fatal, 'CableDyn mooring module: the coupled-motion mirror extends '// &
                             'past the state vector.', ErrStat, ErrMsg, RoutineName ); RETURN
         END IF
         IF (ALLOCATED(inst_%ws_cbuf)) THEN
            IF (SIZE(inst_%ws_cbuf) < 3*ncd) DEALLOCATE (inst_%ws_cbuf)
         END IF
         IF (.NOT. ALLOCATED(inst_%ws_cbuf)) ALLOCATE (inst_%ws_cbuf(3*ncd))
         inst_%ws_cbuf(1:3*ncd) = REAL(states(koff + 1:koff + 3*ncd), wp)
         CALL CD_Update_System_CoupledMotion( inst_%agg%sys%fast%system, inst_%ws_cbuf(1:ncd), &
                                              inst_%ws_cbuf(ncd + 1:2*ncd), inst_%ws_cbuf(2*ncd + 1:3*ncd), es, em )
         IF (es /= CD_SYSTEM_OK) THEN
            CALL SetErrStat( ErrID_Fatal, TRIM(em), ErrStat, ErrMsg, RoutineName ); RETURN
         END IF
         koff = koff + 3*ncd
      END IF
      IF (npd > 0 .AND. inst_%agg%has_sys) THEN
         ncd = CD_System_NSystemCoupledDOF( inst_%agg%sys%fast%system )
         nfl = CD_AGG_NFailures( inst_%agg )
         IF (koff + 3*ncd + npd + nfl > SIZE(states)) THEN
            CALL SetErrStat( ErrID_Fatal, 'CableDyn mooring module: the dynamic-point mirror extends '// &
                             'past the state vector.', ErrStat, ErrMsg, RoutineName ); RETURN
         END IF
         ! FAILURE flags replay FIRST (they live at the mirror tail): the detach
         ! topology must match the checkpointed exchange layout BEFORE any state
         ! block is written -- the restored vector/store were packed on the
         ! post-detach system, and writing them through a pre-detach map would put
         ! committed values on the wrong slots.
         IF (nfl > 0) THEN
            BLOCK
               LOGICAL :: flg(nfl)
               flg = states(koff + 3*ncd + npd + 1:koff + 3*ncd + npd + nfl) > 0.5_DbKi
               CALL CD_AGG_Set_Failure_Flags( inst_%agg, flg, es, em )
               IF (es /= CD_AGG_OK) THEN
                  CALL SetErrStat( ErrID_Fatal, TRIM(em), ErrStat, ErrMsg, RoutineName ); RETURN
               END IF
            END BLOCK
         END IF
         IF (ALLOCATED(inst_%ws_cbuf)) THEN
            IF (SIZE(inst_%ws_cbuf) < MAX(3*ncd, npd)) DEALLOCATE (inst_%ws_cbuf)
         END IF
         IF (.NOT. ALLOCATED(inst_%ws_cbuf)) ALLOCATE (inst_%ws_cbuf(MAX(3*ncd, npd)))
         inst_%ws_cbuf(1:npd) = REAL(states(koff + 3*ncd + 1:koff + 3*ncd + npd), wp)
         CALL CD_Set_System_DynamicPoint_States( inst_%agg%sys%fast%system, inst_%ws_cbuf(1:npd), es, em )
         IF (es /= CD_SYSTEM_OK) THEN
            CALL SetErrStat( ErrID_Fatal, TRIM(em), ErrStat, ErrMsg, RoutineName ); RETURN
         END IF
         inst_%ws_cbuf(1:3*ncd) = REAL(states(koff + 1:koff + 3*ncd), wp)
         CALL CD_Update_System_CoupledMotion( inst_%agg%sys%fast%system, inst_%ws_cbuf(1:ncd), &
                                              inst_%ws_cbuf(ncd + 1:2*ncd), inst_%ws_cbuf(2*ncd + 1:3*ncd), es, em )
         IF (es /= CD_SYSTEM_OK) THEN
            CALL SetErrStat( ErrID_Fatal, TRIM(em), ErrStat, ErrMsg, RoutineName ); RETURN
         END IF
         ! the FMF facade's point mesh caches the coupled surface; the moving-step path
         ! seeds from it, so re-derive it from the just-restored system state (else the
         ! next step would feed pre-restore Free/Connect values back into the system)
         CALL CD_AGG_Refresh_PointMesh( inst_%agg, es, em )
         IF (es /= CD_AGG_OK) THEN
            CALL SetErrStat( ErrID_Fatal, TRIM(em), ErrStat, ErrMsg, RoutineName ); RETURN
         END IF
      END IF
   END SUBROUTINE reload_interiors_ary

   SUBROUTINE reload_cable_mirrors(inst_, m, states, t_clock, torsion_only, koff, ErrStat, ErrMsg)
      !! Unpack each cable's [v; q; a] free-DOF mirror (with its torsion tail) from the
      !! checkpoint x%states layout. koff returns the offset past the cable block. With
      !! torsion_only, only the cables restrained in torsion are unpacked: the checkpoint
      !! rebuild restores their committed twist before it moves the fairlead to the restart
      !! pose, whose preflight bounds the twist change against that committed value.
      TYPE(CD_OF_Instance),         INTENT(INOUT) :: inst_
      TYPE(CD_MiscVarType),         INTENT(IN)    :: m
      REAL(R8Ki),                   INTENT(IN)    :: states(:)
      REAL(wp),                     INTENT(IN)    :: t_clock
      LOGICAL,                      INTENT(IN)    :: torsion_only
      INTEGER(IntKi),               INTENT(OUT)   :: koff
      INTEGER(IntKi),               INTENT(OUT)   :: ErrStat
      CHARACTER(*),                 INTENT(OUT)   :: ErrMsg

      character(*), parameter :: RoutineName = 'CableDyn:reload_cable_mirrors'
      INTEGER(IntKi)          :: es, ic, csz
      CHARACTER(ErrMsgLen)          :: em

      ErrStat = ErrID_None
      ErrMsg  = ''
      koff = 0
      IF (inst_%nlines > 0) koff = m%LineStateIsN(inst_%nlines)
      DO ic = 1, inst_%agg%ncable
         csz = CD_HFMF_MirrorSize( inst_%agg%cables(ic) )
         IF (csz <= 0) CYCLE
         IF (koff + csz > SIZE(states)) THEN
            CALL SetErrStat( ErrID_Fatal, 'CableDyn mooring module: cable '//TRIM(Num2LStr(ic))// &
                             ' mirror extends past the state vector.', ErrStat, ErrMsg, RoutineName )
            RETURN
         END IF
         IF (torsion_only .AND. .NOT. inst_%agg%cables(ic)%line%torsion%active) THEN
            koff = koff + csz
            CYCLE
         END IF
         IF (ALLOCATED(inst_%ws_cbuf)) THEN
            IF (SIZE(inst_%ws_cbuf) /= csz) DEALLOCATE (inst_%ws_cbuf)
         END IF
         IF (.NOT. ALLOCATED(inst_%ws_cbuf)) ALLOCATE (inst_%ws_cbuf(csz))
         inst_%ws_cbuf = REAL(states(koff + 1:koff + csz), wp)
         CALL CD_HFMF_UnpackMirror( inst_%agg%cables(ic), inst_%ws_cbuf, t_clock, es, em )
         IF (es /= CD_HFMF_OK) THEN
            CALL SetErrStat( ErrID_Fatal, TRIM(em), ErrStat, ErrMsg, RoutineName ); RETURN
         END IF
         koff = koff + csz
      END DO
   END SUBROUTINE reload_cable_mirrors

   SUBROUTINE pack_state_mirror(inst_, m, x, ErrStat, ErrMsg)
      TYPE(CD_OF_Instance),         INTENT(INOUT) :: inst_
      TYPE(CD_MiscVarType),         INTENT(IN)    :: m
      TYPE(CD_ContinuousStateType), INTENT(INOUT) :: x
      INTEGER(IntKi),               INTENT(OUT)   :: ErrStat
      CHARACTER(*),                 INTENT(OUT)   :: ErrMsg
      CALL pack_state_mirror_ary(inst_, m, x%states, ErrStat, ErrMsg)
   END SUBROUTINE pack_state_mirror

   INTEGER(IntKi) FUNCTION line_friction_mirror_size(inst_) RESULT(n)
      !! Mirror slots of the EI=0 lines' stick-slip friction anchors: (x, y) per node of
      !! every line on a frictional seabed (0 without such lines).
      TYPE(CD_OF_Instance), INTENT(IN) :: inst_
      INTEGER(IntKi) :: il, es
      CHARACTER(ErrMsgLen) :: em
      n = 0
      IF (.NOT. inst_%agg%has_sys) RETURN
      DO il = 1, inst_%nlines
         IF (.NOT. CD_System_Line_Has_Friction( inst_%agg%sys%fast%system, il )) CYCLE
         n = n + 2*(CD_System_Line_NDOF( inst_%agg%sys%fast%system, il, es, em )/3)
      END DO
   END FUNCTION line_friction_mirror_size

   !> Copy the instance states into the framework mirror x%states: per EI=0 mooring
   !> line, the interior-node velocities then the interior-node positions (the MoorDyn
   !> layout; end nodes are excluded -- they are prescribed or fixed); then, after the
   !> mooring block, each finite-EI cable contributes its free-DOF velocities then
   !> positions [v_free; q_free]. The module stays self-authoritative: it reloads its
   !> state from the mirror only on a checkpoint rebuild or the state-const CalcOutput
   !> restore (reload_interiors_ary).
   SUBROUTINE pack_state_mirror_ary(inst_, m, states, ErrStat, ErrMsg)
      !! Pack the committed solver state (interior [rd; r; rdd] per mooring line,
      !! [v; q; a] free DOFs per cable) into the given mirror array -- the checkpoint
      !! x%states layout. Also used by the state-const CalcOutput to capture the
      !! committed state before an out-of-band transfer.
      TYPE(CD_OF_Instance),         INTENT(INOUT) :: inst_
      TYPE(CD_MiscVarType),         INTENT(IN)    :: m
      REAL(R8Ki),                   INTENT(INOUT) :: states(:)
      INTEGER(IntKi),               INTENT(OUT)   :: ErrStat
      CHARACTER(*),                 INTENT(OUT)   :: ErrMsg

      character(*), parameter :: RoutineName = 'CableDyn:pack_state_mirror'
      INTEGER(IntKi)          :: es, il, ndofl, nin, k, ic, csz, koff, npd, ncd, nfl, nve
      CHARACTER(ErrMsgLen)          :: em

      ErrStat = ErrID_None
      ErrMsg  = ''
      DO il = 1, inst_%nlines
         ndofl = CD_System_Line_NDOF( inst_%agg%sys%fast%system, il, es, em )
         IF (es /= CD_SYSTEM_OK) THEN
            CALL SetErrStat( ErrID_Fatal, TRIM(em), ErrStat, ErrMsg, RoutineName ); RETURN
         END IF
         ! grow-only INSTANCE scratch: this routine runs once per mooring step, so the
         ! buffers must persist across calls (as locals they re-allocated every call).
         IF (ALLOCATED(inst_%ws_qL)) THEN
            IF (SIZE(inst_%ws_qL) /= ndofl) DEALLOCATE (inst_%ws_qL, inst_%ws_vL, inst_%ws_aL)
         END IF
         IF (.NOT. ALLOCATED(inst_%ws_qL)) ALLOCATE (inst_%ws_qL(ndofl), inst_%ws_vL(ndofl), inst_%ws_aL(ndofl))
         CALL CD_Get_System_Line_State( inst_%agg%sys%fast%system, il, inst_%ws_qL, inst_%ws_vL, inst_%ws_aL, es, em )
         IF (es /= CD_SYSTEM_OK) THEN
            CALL SetErrStat( ErrID_Fatal, TRIM(em), ErrStat, ErrMsg, RoutineName ); RETURN
         END IF
         nin = ndofl - 6                       ! interior DOFs (drop both end nodes)
         k = m%LineStateIs1(il)
         states(k:k + nin - 1)           = REAL(inst_%ws_vL(4:ndofl - 3), DbKi)
         states(k + nin:k + 2*nin - 1)   = REAL(inst_%ws_qL(4:ndofl - 3), DbKi)
         ! the committed gen-alpha acceleration: carried so a checkpoint restart reloads
         ! the integrator state EXACTLY (re-deriving it moves the first restored loads)
         states(k + 2*nin:k + 3*nin - 1) = REAL(inst_%ws_aL(4:ndofl - 3), DbKi)
         ! viscoelastic dl_1 history: the per-element tail of this line's block, sized
         ! to match the Init nstates layout (LineStateIs1..IsN spans it)
         IF (CD_System_Line_Has_Viscoelastic( inst_%agg%sys%fast%system, il )) THEN
            nve = CD_System_Line_NElem( inst_%agg%sys%fast%system, il, es, em )
            IF (es /= CD_SYSTEM_OK) THEN
               CALL SetErrStat( ErrID_Fatal, TRIM(em), ErrStat, ErrMsg, RoutineName ); RETURN
            END IF
            BLOCK
               REAL(wp) :: dl1(nve)
               CALL CD_Get_System_Line_VE_Dl1( inst_%agg%sys%fast%system, il, dl1, es, em )
               IF (es /= CD_SYSTEM_OK) THEN
                  CALL SetErrStat( ErrID_Fatal, TRIM(em), ErrStat, ErrMsg, RoutineName ); RETURN
               END IF
               states(k + 3*nin:k + 3*nin + nve - 1) = REAL(dl1, DbKi)
            END BLOCK
         END IF
         ! Syrope state: two per-element tail blocks (slow then tmax), sized to match
         ! the Init nstates layout (LineStateIs1..IsN spans it)
         IF (CD_System_Line_Has_Syrope( inst_%agg%sys%fast%system, il )) THEN
            nve = CD_System_Line_NElem( inst_%agg%sys%fast%system, il, es, em )
            IF (es /= CD_SYSTEM_OK) THEN
               CALL SetErrStat( ErrID_Fatal, TRIM(em), ErrStat, ErrMsg, RoutineName ); RETURN
            END IF
            BLOCK
               REAL(wp) :: slw(nve), tmx(nve)
               CALL CD_Get_System_Line_Syrope_State( inst_%agg%sys%fast%system, il, slw, tmx, es, em )
               IF (es /= CD_SYSTEM_OK) THEN
                  CALL SetErrStat( ErrID_Fatal, TRIM(em), ErrStat, ErrMsg, RoutineName ); RETURN
               END IF
               states(k + 3*nin:k + 3*nin + nve - 1)             = REAL(slw, DbKi)
               states(k + 3*nin + nve:k + 3*nin + 2*nve - 1)     = REAL(tmx, DbKi)
            END BLOCK
         END IF
         ! VIV state: the last block of the line's span
         nve = CD_System_Line_VIV_MirrorSize( inst_%agg%sys%fast%system, il )
         IF (nve > 0) THEN
            BLOCK
               REAL(wp) :: vbuf(nve)
               CALL CD_Get_System_Line_VIV_State( inst_%agg%sys%fast%system, il, vbuf, es, em )
               IF (es /= CD_SYSTEM_OK) THEN
                  CALL SetErrStat( ErrID_Fatal, TRIM(em), ErrStat, ErrMsg, RoutineName ); RETURN
               END IF
               states(m%LineStateIsN(il) - nve + 1:m%LineStateIsN(il)) = REAL(vbuf, DbKi)
            END BLOCK
         END IF
      END DO
      ! finite-EI cables: append per-cable free-DOF [v_free; q_free; a_free] after the mooring block
      koff = 0
      IF (inst_%nlines > 0) koff = m%LineStateIsN(inst_%nlines)
      DO ic = 1, inst_%agg%ncable
         csz = CD_HFMF_MirrorSize( inst_%agg%cables(ic) )
         IF (csz <= 0) CYCLE
         IF (ALLOCATED(inst_%ws_cbuf)) THEN
            IF (SIZE(inst_%ws_cbuf) /= csz) DEALLOCATE (inst_%ws_cbuf)
         END IF
         IF (.NOT. ALLOCATED(inst_%ws_cbuf)) ALLOCATE (inst_%ws_cbuf(csz))
         CALL CD_HFMF_PackMirror( inst_%agg%cables(ic), inst_%ws_cbuf, es, em )
         IF (es /= 0) THEN
            CALL SetErrStat( ErrID_Fatal, TRIM(em), ErrStat, ErrMsg, RoutineName ); RETURN
         END IF
         states(koff + 1:koff + csz) = REAL(inst_%ws_cbuf, DbKi)
         koff = koff + csz
      END DO
      ! coupled Rigid6 6-DOF body state: pack after the cable block (koff carries the running offset)
      IF (CD_AGG_HasRigid6( inst_%agg )) THEN
         csz = CD_AGG_Rigid6_MirrorSize( inst_%agg )
         IF (csz > 0) THEN
            IF (ALLOCATED(inst_%ws_cbuf)) THEN
               IF (SIZE(inst_%ws_cbuf) < csz) DEALLOCATE (inst_%ws_cbuf)
            END IF
            IF (.NOT. ALLOCATED(inst_%ws_cbuf)) ALLOCATE (inst_%ws_cbuf(csz))
            CALL CD_AGG_Get_Rigid6_States( inst_%agg, inst_%ws_cbuf(1:csz), es, em )
            IF (es /= CD_AGG_OK) THEN
               CALL SetErrStat( ErrID_Fatal, TRIM(em), ErrStat, ErrMsg, RoutineName ); RETURN
            END IF
            states(koff + 1:koff + csz) = REAL(inst_%ws_cbuf(1:csz), DbKi)
            koff = koff + csz
         END IF
      END IF
      IF (CD_AGG_HasRod( inst_%agg )) THEN
         csz = CD_AGG_Rod_MirrorSize( inst_%agg )
         IF (csz > 0) THEN
            IF (ALLOCATED(inst_%ws_cbuf)) THEN
               IF (SIZE(inst_%ws_cbuf) < csz) DEALLOCATE (inst_%ws_cbuf)
            END IF
            IF (.NOT. ALLOCATED(inst_%ws_cbuf)) ALLOCATE (inst_%ws_cbuf(csz))
            CALL CD_AGG_Get_Rod_States( inst_%agg, inst_%ws_cbuf(1:csz), es, em )
            IF (es /= CD_AGG_OK) THEN
               CALL SetErrStat( ErrID_Fatal, TRIM(em), ErrStat, ErrMsg, RoutineName ); RETURN
            END IF
            states(koff + 1:koff + csz) = REAL(inst_%ws_cbuf(1:csz), DbKi)
            koff = koff + csz
         END IF
      END IF
      ! EI=0 line stick-slip friction anchors, line by line after the rod block
      IF (line_friction_mirror_size( inst_ ) > 0) THEN
         DO il = 1, inst_%nlines
            IF (.NOT. CD_System_Line_Has_Friction( inst_%agg%sys%fast%system, il )) CYCLE
            ndofl = CD_System_Line_NDOF( inst_%agg%sys%fast%system, il, es, em )
            IF (es /= CD_SYSTEM_OK) THEN
               CALL SetErrStat( ErrID_Fatal, TRIM(em), ErrStat, ErrMsg, RoutineName ); RETURN
            END IF
            csz = 2*(ndofl/3)
            BLOCK
               REAL(wp) :: anch(2, ndofl/3)
               CALL CD_Get_System_Line_Friction_Anchors( inst_%agg%sys%fast%system, il, anch, es, em )
               IF (es /= CD_SYSTEM_OK) THEN
                  CALL SetErrStat( ErrID_Fatal, TRIM(em), ErrStat, ErrMsg, RoutineName ); RETURN
               END IF
               states(koff + 1:koff + csz) = REAL(RESHAPE(anch, [csz]), DbKi)
            END BLOCK
            koff = koff + csz
         END DO
      END IF
      ! dynamic (Free/Connect) points: the compact coupled-motion vector [q; v; a]
      ! (the committed boundary/endpoint kinematics -- see the sizing comment at Init),
      ! then the per-point store
      npd = 9*CD_AGG_NDynamicPoints( inst_%agg )
      IF (npd == 0 .AND. inst_%agg%has_sys) THEN
         ! no dynamic points: the committed boundary kinematics alone
         ncd = CD_System_NSystemCoupledDOF( inst_%agg%sys%fast%system )
         IF (koff + 3*ncd > SIZE(states)) THEN
            CALL SetErrStat( ErrID_Fatal, 'CableDyn mooring module: the coupled-motion mirror extends '// &
                             'past the state vector.', ErrStat, ErrMsg, RoutineName ); RETURN
         END IF
         IF (ALLOCATED(inst_%ws_cbuf)) THEN
            IF (SIZE(inst_%ws_cbuf) < 3*ncd) DEALLOCATE (inst_%ws_cbuf)
         END IF
         IF (.NOT. ALLOCATED(inst_%ws_cbuf)) ALLOCATE (inst_%ws_cbuf(3*ncd))
         CALL CD_Get_System_CoupledMotion( inst_%agg%sys%fast%system, inst_%ws_cbuf(1:ncd), &
                                           inst_%ws_cbuf(ncd + 1:2*ncd), inst_%ws_cbuf(2*ncd + 1:3*ncd), es, em )
         IF (es /= CD_SYSTEM_OK) THEN
            CALL SetErrStat( ErrID_Fatal, TRIM(em), ErrStat, ErrMsg, RoutineName ); RETURN
         END IF
         states(koff + 1:koff + 3*ncd) = REAL(inst_%ws_cbuf(1:3*ncd), DbKi)
         koff = koff + 3*ncd
      END IF
      IF (npd > 0 .AND. inst_%agg%has_sys) THEN
         ncd = CD_System_NSystemCoupledDOF( inst_%agg%sys%fast%system )
         IF (koff + 3*ncd + npd > SIZE(states)) THEN
            CALL SetErrStat( ErrID_Fatal, 'CableDyn mooring module: the dynamic-point mirror extends '// &
                             'past the state vector.', ErrStat, ErrMsg, RoutineName ); RETURN
         END IF
         IF (ALLOCATED(inst_%ws_cbuf)) THEN
            IF (SIZE(inst_%ws_cbuf) < MAX(3*ncd, npd)) DEALLOCATE (inst_%ws_cbuf)
         END IF
         IF (.NOT. ALLOCATED(inst_%ws_cbuf)) ALLOCATE (inst_%ws_cbuf(MAX(3*ncd, npd)))
         CALL CD_Get_System_CoupledMotion( inst_%agg%sys%fast%system, inst_%ws_cbuf(1:ncd), &
                                           inst_%ws_cbuf(ncd + 1:2*ncd), inst_%ws_cbuf(2*ncd + 1:3*ncd), es, em )
         IF (es /= CD_SYSTEM_OK) THEN
            CALL SetErrStat( ErrID_Fatal, TRIM(em), ErrStat, ErrMsg, RoutineName ); RETURN
         END IF
         states(koff + 1:koff + 3*ncd) = REAL(inst_%ws_cbuf(1:3*ncd), DbKi)
         koff = koff + 3*ncd
         CALL CD_Get_System_DynamicPoint_States( inst_%agg%sys%fast%system, inst_%ws_cbuf(1:npd), es, em )
         IF (es /= CD_SYSTEM_OK) THEN
            CALL SetErrStat( ErrID_Fatal, TRIM(em), ErrStat, ErrMsg, RoutineName ); RETURN
         END IF
         states(koff + 1:koff + npd) = REAL(inst_%ws_cbuf(1:npd), DbKi)
         koff = koff + npd
         ! FAILURE fired flags at the mirror tail (0/1 per row)
         nfl = CD_AGG_NFailures( inst_%agg )
         IF (nfl > 0) THEN
            IF (koff + nfl > SIZE(states)) THEN
               CALL SetErrStat( ErrID_Fatal, 'CableDyn mooring module: the failure-flag mirror extends '// &
                                'past the state vector.', ErrStat, ErrMsg, RoutineName ); RETURN
            END IF
            BLOCK
               LOGICAL :: flg(nfl)
               CALL CD_AGG_Get_Failure_Flags( inst_%agg, flg, es, em )
               IF (es /= CD_AGG_OK) THEN
                  CALL SetErrStat( ErrID_Fatal, TRIM(em), ErrStat, ErrMsg, RoutineName ); RETURN
               END IF
               states(koff + 1:koff + nfl) = MERGE(1.0_DbKi, 0.0_DbKi, flg)
            END BLOCK
         END IF
      END IF
   END SUBROUTINE pack_state_mirror_ary

   SUBROUTINE build_farm_meshes( inst_e, u, y, InitInp, nT, ncp, pos, ErrStat, ErrMsg )
      !! FAST.Farm mesh construction: one CoupledKinematics/CoupledLoads pair per
      !! turbine over the flat aggregate moving surface. Records the turbine map,
      !! each slot's node index within its turbine's mesh, the farm reference
      !! offsets, and the per-turbine PtfmInit. Mesh reference positions are the
      !! UNDISPLACED TURBINE-LOCAL deck coordinates (recovered by the exact inverse
      !! rigid transform from the displaced farm-global aggregate positions), with
      !! the initial displacement carried in TranslationDisp -- MoorDyn's convention.
      TYPE(CD_OF_Instance),     INTENT(INOUT) :: inst_e
      TYPE(CD_InputType),       INTENT(INOUT) :: u
      TYPE(CD_OutputType),      INTENT(INOUT) :: y
      TYPE(CD_InitInputType),   INTENT(IN   ) :: InitInp
      INTEGER(IntKi),           INTENT(IN   ) :: nT, ncp
      REAL(wp),                 INTENT(IN   ) :: pos(:,:)
      INTEGER(IntKi),           INTENT(  OUT) :: ErrStat
      CHARACTER(*),             INTENT(  OUT) :: ErrMsg

      character(*), parameter   :: RoutineName = 'CableDyn:build_farm_meshes'
      INTEGER(IntKi)            :: es, s, J, k, nk, ErrStat2
      CHARACTER(ErrMsgLen)            :: em
      CHARACTER(ErrMsgLen)      :: ErrMsg2
      REAL(R8Ki)                :: OrMatJ(3,3), OrientIdent(3,3), refp(3), ptfmJ(6), ploc(3)
      LOGICAL                   :: hasp

      ErrStat = ErrID_None
      ErrMsg  = ''
      inst_e%nT = nT
      ALLOCATE (inst_e%tmap(ncp), inst_e%node_of_slot(ncp), inst_e%farm_ref(3, nT), &
                inst_e%farm_ptfm(6, nT), STAT=ErrStat2)
      IF (ErrStat2 /= 0) THEN
         CALL SetErrStat( ErrID_Fatal, 'Could not allocate the farm maps.', ErrStat, ErrMsg, RoutineName )
         RETURN
      END IF
      CALL CD_AGG_TurbineOfMoving( inst_e%agg, inst_e%tmap, es, em )
      IF (es /= CD_AGG_OK) THEN
         CALL SetErrStat( ErrID_Fatal, 'CableDyn mooring module: '//TRIM(em), ErrStat, ErrMsg, RoutineName )
         RETURN
      END IF
      IF (ANY(inst_e%tmap < 1) .OR. ANY(inst_e%tmap > nT)) THEN
         CALL SetErrStat( ErrID_Fatal, 'CableDyn mooring module: the farm turbine map carries a slot '// &
                          'outside 1..FarmSize.', ErrStat, ErrMsg, RoutineName )
         RETURN
      END IF
      inst_e%farm_ref = REAL(InitInp%TurbineRefPos, R8Ki)
      inst_e%farm_ptfm = 0.0_R8Ki
      hasp = ALLOCATED(InitInp%PtfmInit)
      IF (hasp) THEN
         IF (SIZE(InitInp%PtfmInit, 1) >= 6 .AND. SIZE(InitInp%PtfmInit, 2) >= nT) THEN
            inst_e%farm_ptfm = REAL(InitInp%PtfmInit(1:6, 1:nT), R8Ki)
         END IF
      END IF
      DO J = 1, nT
         k = 0
         DO s = 1, ncp
            IF (inst_e%tmap(s) == J) THEN
               k = k + 1
               inst_e%node_of_slot(s) = k
            END IF
         END DO
      END DO

      ALLOCATE (u%CoupledKinematics(nT), y%CoupledLoads(nT), STAT=ErrStat2)
      IF (ErrStat2 /= 0) THEN
         CALL SetErrStat( ErrID_Fatal, 'Could not allocate the farm mesh containers.', ErrStat, ErrMsg, RoutineName )
         RETURN
      END IF
      CALL Eye( OrientIdent, ErrStat2, ErrMsg2 )
      DO J = 1, nT
         nk = COUNT(inst_e%tmap == J)
         CALL MeshCreate( BlankMesh=u%CoupledKinematics(J), IOS=COMPONENT_INPUT, Nnodes=MAX(nk, 1), &
                          TranslationDisp=.TRUE., Orientation=.TRUE., TranslationVel=.TRUE., &
                          RotationVel=.TRUE., TranslationAcc=.TRUE., RotationAcc=.TRUE., &
                          ErrStat=ErrStat2, ErrMess=ErrMsg2 )
         CALL SetErrStat( ErrStat2, ErrMsg2, ErrStat, ErrMsg, RoutineName )
         IF (ErrStat >= AbortErrLev) RETURN
         ptfmJ = inst_e%farm_ptfm(:, J)
         OrMatJ = EulerConstructZYX( ptfmJ(4:6) )
         DO s = 1, ncp
            IF (inst_e%tmap(s) /= J) CYCLE
            ! farm-global aggregate position -> turbine-local displaced -> undisplaced
            ploc = REAL(pos(:, s), R8Ki) - inst_e%farm_ref(:, J)
            refp = MATMUL( OrMatJ, ploc - ptfmJ(1:3) )
            CALL MeshPositionNode( u%CoupledKinematics(J), inst_e%node_of_slot(s), REAL(refp, ReKi), &
                                   ErrStat2, ErrMsg2, Orient=OrientIdent )
            CALL SetErrStat( ErrStat2, ErrMsg2, ErrStat, ErrMsg, RoutineName )
            CALL MeshConstructElement( u%CoupledKinematics(J), ELEMENT_POINT, ErrStat2, ErrMsg2, &
                                       inst_e%node_of_slot(s) )
            CALL SetErrStat( ErrStat2, ErrMsg2, ErrStat, ErrMsg, RoutineName )
         END DO
         IF (nk == 0) THEN
            ! a turbine with no moored objects still needs a committed 1-node mesh so the
            ! farm glue's per-turbine mappings stay well-formed; it carries zero loads
            CALL MeshPositionNode( u%CoupledKinematics(J), 1, REAL(inst_e%farm_ref(:, J), ReKi), &
                                   ErrStat2, ErrMsg2, Orient=OrientIdent )
            CALL SetErrStat( ErrStat2, ErrMsg2, ErrStat, ErrMsg, RoutineName )
            CALL MeshConstructElement( u%CoupledKinematics(J), ELEMENT_POINT, ErrStat2, ErrMsg2, 1 )
            CALL SetErrStat( ErrStat2, ErrMsg2, ErrStat, ErrMsg, RoutineName )
         END IF
         CALL MeshCommit( u%CoupledKinematics(J), ErrStat2, ErrMsg2 )
         CALL SetErrStat( ErrStat2, ErrMsg2, ErrStat, ErrMsg, RoutineName )
         IF (ErrStat >= AbortErrLev) RETURN
         u%CoupledKinematics(J)%TranslationDisp = 0.0_ReKi
         u%CoupledKinematics(J)%TranslationVel  = 0.0_ReKi
         u%CoupledKinematics(J)%RotationVel     = 0.0_ReKi
         u%CoupledKinematics(J)%TranslationAcc  = 0.0_ReKi
         u%CoupledKinematics(J)%RotationAcc     = 0.0_ReKi
         DO k = 1, MAX(nk, 1)
            u%CoupledKinematics(J)%Orientation(:, :, k) = REAL(OrMatJ, ReKi)
         END DO
         DO s = 1, ncp
            IF (inst_e%tmap(s) /= J) CYCLE
            u%CoupledKinematics(J)%TranslationDisp(:, inst_e%node_of_slot(s)) = &
               REAL(REAL(pos(:, s), R8Ki) - inst_e%farm_ref(:, J), ReKi) - &
               u%CoupledKinematics(J)%Position(:, inst_e%node_of_slot(s))
         END DO
         CALL MeshCopy( SrcMesh=u%CoupledKinematics(J), DestMesh=y%CoupledLoads(J), CtrlCode=MESH_SIBLING, &
                        IOS=COMPONENT_OUTPUT, Force=.TRUE., Moment=.TRUE., ErrStat=ErrStat2, ErrMess=ErrMsg2 )
         CALL SetErrStat( ErrStat2, ErrMsg2, ErrStat, ErrMsg, RoutineName )
         IF (ErrStat >= AbortErrLev) RETURN
         y%CoupledLoads(J)%Force  = 0.0_ReKi
         y%CoupledLoads(J)%Moment = 0.0_ReKi
      END DO
   END SUBROUTINE build_farm_meshes

   SUBROUTINE farm_gather_kinematics(inst_e, u, ErrStat, ErrMsg)
      !! FAST.Farm gather: every turbine's mesh into the flat aggregate arrays,
      !! farm-global (Position + TranslationDisp + TurbineRefPos -- MoorDyn's exact
      !! boundary convention). Fills the instance ws_pos/ws_vel/ws_acc.
      TYPE(CD_OF_Instance),  INTENT(INOUT) :: inst_e
      TYPE(CD_InputType),    INTENT(IN)    :: u
      INTEGER(IntKi),        INTENT(OUT)   :: ErrStat
      CHARACTER(*),          INTENT(OUT)   :: ErrMsg

      INTEGER(IntKi) :: s, J, k

      ErrStat = ErrID_None
      ErrMsg  = ''
      IF (SIZE(u%CoupledKinematics) < inst_e%nT) THEN
         ErrStat = ErrID_Fatal
         ErrMsg  = 'CableDyn:farm_gather: the input carries fewer meshes than FarmSize.'
         RETURN
      END IF
      DO s = 1, inst_e%ncp
         J = inst_e%tmap(s)
         k = inst_e%node_of_slot(s)
         inst_e%ws_pos(:, s) = REAL(u%CoupledKinematics(J)%Position(:, k), wp) + &
                               REAL(u%CoupledKinematics(J)%TranslationDisp(:, k), wp) + &
                               REAL(inst_e%farm_ref(:, J), wp)
         inst_e%ws_vel(:, s) = REAL(u%CoupledKinematics(J)%TranslationVel(:, k), wp)
         inst_e%ws_acc(:, s) = REAL(u%CoupledKinematics(J)%TranslationAcc(:, k), wp)
         inst_e%ws_orient(:, :, s) = REAL(u%CoupledKinematics(J)%Orientation(:, :, k), wp)
         inst_e%ws_omega(:, s) = REAL(u%CoupledKinematics(J)%RotationVel(:, k), wp)
         inst_e%ws_alpha(:, s) = REAL(u%CoupledKinematics(J)%RotationAcc(:, k), wp)
      END DO
   END SUBROUTINE farm_gather_kinematics

   !> Extract absolute coupled-point kinematics from the mesh: position = reference
   !> Position + TranslationDisp (single-turbine: TurbineRefPos = 0). GROW-ONLY on the
   !> passed workspace: the marching path (UpdateStates/CalcOutput, every glue step of a
   !> long run) hands in the instance's persistent ws_* arrays, so the allocation happens
   !> once and the per-step cost is the copy alone.
   SUBROUTINE mesh_to_arrays(mesh, ncp, pos, vel, acc, orient, omega, alpha, ErrStat, ErrMsg)
      TYPE(MeshType),        INTENT(IN)    :: mesh
      INTEGER(IntKi),        INTENT(IN)    :: ncp
      REAL(wp), ALLOCATABLE, INTENT(INOUT) :: pos(:,:), vel(:,:), acc(:,:)
      REAL(wp), ALLOCATABLE, INTENT(INOUT) :: orient(:,:,:)
      REAL(wp), ALLOCATABLE, INTENT(INOUT) :: omega(:,:), alpha(:,:)
      INTEGER(IntKi),        INTENT(OUT)   :: ErrStat
      CHARACTER(*),          INTENT(OUT)   :: ErrMsg

      INTEGER(IntKi) :: i, ErrStat2

      ErrStat = ErrID_None
      ErrMsg  = ''
      IF (ALLOCATED(pos)) THEN
         IF (SIZE(pos, 2) /= ncp) DEALLOCATE (pos, vel, acc, orient, omega, alpha)
      END IF
      IF (.NOT. ALLOCATED(pos)) THEN
         ALLOCATE (pos(3, ncp), vel(3, ncp), acc(3, ncp), orient(3, 3, ncp), &
                   omega(3, ncp), alpha(3, ncp), STAT=ErrStat2)
         IF (ErrStat2 /= 0) THEN
            ErrStat = ErrID_Fatal
            ErrMsg  = 'CableDyn:mesh_to_arrays: could not allocate kinematics arrays.'
            RETURN
         END IF
      END IF
      DO i = 1, ncp
         pos(:, i) = REAL(mesh%Position(:, i), wp) + REAL(mesh%TranslationDisp(:, i), wp)
         vel(:, i) = REAL(mesh%TranslationVel(:, i), wp)
         acc(:, i) = REAL(mesh%TranslationAcc(:, i), wp)
         orient(:, :, i) = REAL(mesh%Orientation(:, :, i), wp)
         omega(:, i) = REAL(mesh%RotationVel(:, i), wp)
         alpha(:, i) = REAL(mesh%RotationAcc(:, i), wp)
      END DO
   END SUBROUTINE mesh_to_arrays

   !> Release an instance slot: end its aggregate, destroy its interpolation input, free
   !> its workspaces, close its native output stream and mark it inactive (reusable).
   !> Status and message are optional so rebuild error paths can release silently.
   SUBROUTINE release_instance( k, ErrStat, ErrMsg )
      INTEGER(IntKi),           INTENT(IN)  :: k
      INTEGER(IntKi), OPTIONAL, INTENT(OUT) :: ErrStat
      CHARACTER(*),   OPTIONAL, INTENT(OUT) :: ErrMsg
      INTEGER(IntKi)       :: es, ErrStat2
      CHARACTER(ErrMsgLen)       :: em
      CHARACTER(ErrMsgLen) :: ErrMsg2
      IF (PRESENT(ErrStat)) ErrStat = ErrID_None
      IF (PRESENT(ErrMsg)) ErrMsg = ''
      IF (.NOT. ALLOCATED(Inst)) RETURN
      IF (k < 1_IntKi .OR. k > SIZE(Inst)) RETURN
      IF (CD_AGG_IsInitialized( Inst(k)%agg )) THEN
         CALL CD_AGG_End( Inst(k)%agg, es, em )
         IF (es /= CD_AGG_OK) THEN
            IF (PRESENT(ErrStat)) ErrStat = ErrID_Severe
            IF (PRESENT(ErrMsg)) ErrMsg = 'CableDyn mooring module: '//TRIM(em)
         END IF
      END IF
      ! The persistent interpolation container owns a full mesh copy; destroy it
      ! through the registry (mesh components are not plain allocatables).
      IF (Inst(k)%u_interp_ready) THEN
         CALL CD_DestroyInput( Inst(k)%u_interp, ErrStat2, ErrMsg2 )
         Inst(k)%u_interp_ready = .FALSE.
      END IF
      IF (ALLOCATED(Inst(k)%fx_xyz)) DEALLOCATE (Inst(k)%fx_xyz, Inst(k)%fx_vel, Inst(k)%fx_acc, &
                                                 Inst(k)%fx_wl, Inst(k)%fx_pd)
      Inst(k)%use_extfluid = .FALSE.
      Inst(k)%nfluid = 0
      Inst(k)%grid_warned = .FALSE.
      Inst(k)%curr_grid_warned = .FALSE.
      ! close the CableDyn-owned committed-step record (flushes the final rows)
      IF (Inst(k)%native_un > 0) THEN
         CLOSE (Inst(k)%native_un)
         Inst(k)%native_un = -1_IntKi
      END IF
      Inst(k)%native_root = ''
      Inst(k)%native_wrote_n = -123456789_IntKi
      Inst(k)%native_wrote_t = 0.0_DbKi
      Inst(k)%native_pending = .FALSE.
      Inst(k)%active = .FALSE.
   END SUBROUTINE release_instance

   !> TRUE when a SeaState wave field carries ambient kinematics for the mooring: waves,
   !> a declared current, or a dynamically populated current field (an MHK current
   !> driven by InflowWind carries no CurrMod declaration).
   LOGICAL FUNCTION wavefield_is_ambient( wf ) RESULT(ambient)
      TYPE(SeaSt_WaveFieldType), INTENT(IN) :: wf
      ambient = wf%WaveMod /= WaveMod_None .OR. wf%Current_InitInput%CurrMod /= 0_IntKi .OR. wf%hasCurrField
   END FUNCTION wavefield_is_ambient

   !> The host's steady current for the static start (CD_AGG_Init_From_Deck static_current):
   !> SeaState's CurrMod 1 current (CD_SeaState_Steady_Current) at the levels of its vertical
   !> wave grid, z ascending. SeaState interpolates between those levels in its own stretched
   !> coordinate, the profile linearly in z: the start takes the run's current at the levels
   !> and very nearly between them. Left unallocated -- a still-water start -- without a
   !> nonzero CurrMod 1 current; a CurrMod 2 current or an InflowWind current field is known
   !> only through the run's samples (CD_Init notes it).
   SUBROUTINE seastate_static_current( wf, prof, ErrStat, ErrMsg )
      TYPE(SeaSt_WaveFieldType), INTENT(IN   ) :: wf
      REAL(wp), ALLOCATABLE,     INTENT(  OUT) :: prof(:,:)
      INTEGER(IntKi),            INTENT(  OUT) :: ErrStat
      CHARACTER(*),              INTENT(  OUT) :: ErrMsg
      INTEGER(IntKi)  :: k, nz, m, es
      REAL(wp)        :: zk, v(3)
      CHARACTER(1024) :: em
      ErrStat = ErrID_None
      ErrMsg  = ''
      IF (wf%Current_InitInput%CurrMod /= 1_IntKi) RETURN
      nz = wf%VolGridParams%n(4)
      IF (nz < 2) RETURN
      ALLOCATE (prof(4, nz))
      m = 0
      DO k = 0, nz - 1
         zk = REAL(wf%GridDepth, wp)*(SIN(REAL(wf%VolGridParams%pZero(4) + k*wf%VolGridParams%delta(4), wp)) - 1.0_wp)
         IF (m > 0) THEN
            IF (.NOT. zk > prof(1, m)) CYCLE
         END IF
         CALL CD_SeaState_Steady_Current(zk, REAL(wf%EffWtrDpth, wp), 1, &
              REAL(wf%Current_InitInput%CurrSSV0, wp), REAL(wf%Current_InitInput%CurrSSDir, wp), &
              REAL(wf%Current_InitInput%CurrNSRef, wp), REAL(wf%Current_InitInput%CurrNSV0, wp), &
              REAL(wf%Current_InitInput%CurrNSDir, wp), REAL(wf%Current_InitInput%CurrDIV, wp), &
              REAL(wf%Current_InitInput%CurrDIDir, wp), v, es, em)
         IF (es /= CD_HYDRO_OK) THEN
            ErrStat = ErrID_Fatal
            ErrMsg  = 'CableDyn mooring module: SeaState current for the static start: '//TRIM(em)
            DEALLOCATE (prof)
            RETURN
         END IF
         m = m + 1
         prof(:, m) = [zk, v]
      END DO
      IF (m < 2 .OR. .NOT. ANY(ABS(prof(2:4, 1:m)) > 0.0_wp)) THEN
         DEALLOCATE (prof)
         RETURN
      END IF
      prof = prof(:, 1:m)
   END SUBROUTINE seastate_static_current

   !> Write the packed deck copy to <MooringFile folder>/<output root name><suffix>, the
   !> file the checkpoint rebuild and the linearization probes re-parse. In the MooringFile
   !> folder, deck-relative side files (bathymetry, WaterKin, Syrope tables) resolve as in
   !> the original run. The caller removes it after use (delete_file).
   SUBROUTINE write_deck_copy( p, suffix, path, ErrStat, ErrMsg )
      TYPE(CD_ParameterType), INTENT(IN)  :: p
      CHARACTER(*),           INTENT(IN)  :: suffix
      CHARACTER(*),           INTENT(OUT) :: path
      INTEGER(IntKi),         INTENT(OUT) :: ErrStat
      CHARACTER(*),           INTENT(OUT) :: ErrMsg
      INTEGER(IntKi) :: un, i, cut
      cut = MAX(INDEX(p%RootName, '/', BACK=.TRUE.), INDEX(p%RootName, '\', BACK=.TRUE.))
      path = TRIM(p%PriPath)//TRIM(p%RootName(cut + 1:))//suffix
      CALL GetNewUnit( un )
      CALL OpenFOutFile( un, TRIM(path), ErrStat, ErrMsg )
      IF (ErrStat >= AbortErrLev) RETURN
      DO i = 1, p%DeckCopy%NumLines
         WRITE (un, '(A)') TRIM(p%DeckCopy%Lines(i))
      END DO
      CLOSE (un)
   END SUBROUTINE write_deck_copy

   !> Remove a temporary file (silently: a failed removal leaves only a stale copy).
   SUBROUTINE delete_file( path )
      CHARACTER(*), INTENT(IN) :: path
      INTEGER(IntKi) :: un, ios
      IF (.NOT. CD_Path_Openable(TRIM(path), .FALSE.)) RETURN   ! no OPEN that fails (CableDyn_PathIO)
      CALL GetNewUnit( un )
      OPEN (un, FILE=TRIM(path), STATUS='OLD', IOSTAT=ios)
      IF (ios == 0) CLOSE (un, STATUS='DELETE', IOSTAT=ios)
   END SUBROUTINE delete_file

   !> Reserve a slot in the module-level instance registry, left INACTIVE. CD_Init marks it
   !> active only once initialization fully succeeds; a failed init returns early on any of its
   !> many error paths, so leaving the slot inactive means the NEXT new_instance() reuses it
   !> (rather than accumulating half-built active slots). Reuse resets the slot, which also
   !> auto-deallocates any partial fmf left by a prior failed init on that slot.
   INTEGER(IntKi) FUNCTION new_instance() RESULT(id)
      TYPE(CD_OF_Instance), ALLOCATABLE :: tmp(:)
      TYPE(CD_OF_Instance) :: empty
      INTEGER(IntKi) :: i

      IF (.NOT. ALLOCATED(Inst)) ALLOCATE (Inst(0))
      DO i = 1, SIZE(Inst)
         IF (.NOT. Inst(i)%active) THEN
            ! Intrinsic assignment from a default-initialized object resets every
            ! component and deallocates partial failed-init storage.  Do not use a
            ! structure constructor here: several nested aggregate workspaces have
            ! PRIVATE components, which makes that constructor nonconforming and is
            ! correctly rejected by Intel Fortran even though gfortran accepts it.
            Inst(i) = empty
            id = i
            RETURN
         END IF
      END DO
      ALLOCATE (tmp(SIZE(Inst) + 1))
      tmp(1:SIZE(Inst)) = Inst
      CALL MOVE_ALLOC(tmp, Inst)
      id = SIZE(Inst)                     ! new slot is default-initialized (active = .FALSE.)
   END FUNCTION new_instance

   LOGICAL FUNCTION profile_environment_requested() RESULT(requested)
      CHARACTER(32) :: value
      INTEGER :: stat

      value = ''
      CALL GET_ENVIRONMENT_VARIABLE('CABLEDYN_PROFILE', value, STATUS=stat)
      requested = stat == 0 .AND. LEN_TRIM(value) > 0 .AND. TRIM(value) /= '0'
   END FUNCTION profile_environment_requested

   SUBROUTINE reset_instance_profile( id, enabled, init_seconds, reset_global )
      INTEGER(IntKi), INTENT(IN) :: id
      LOGICAL, INTENT(IN) :: enabled, reset_global
      REAL(wp), INTENT(IN) :: init_seconds

      Inst(id)%prof_enabled = enabled
      Inst(id)%prof_n_update = 0_IntKi
      Inst(id)%prof_n_solve = 0_IntKi
      Inst(id)%prof_n_calcout = 0_IntKi
      Inst(id)%prof_n_fresh = 0_IntKi
      Inst(id)%prof_n_wave = 0_IntKi
      Inst(id)%prof_t_init = init_seconds
      Inst(id)%prof_t_update = 0.0_wp
      Inst(id)%prof_t_wave = 0.0_wp
      Inst(id)%prof_t_step = 0.0_wp
      Inst(id)%prof_t_calcout = 0.0_wp
      Inst(id)%prof_t_loads = 0.0_wp
      Inst(id)%prof_t_native = 0.0_wp
      Inst(id)%prof_t_overlay = 0.0_wp
      Inst(id)%prof_t_channels = 0.0_wp
      Inst(id)%prof_t_restore = 0.0_wp
      Inst(id)%prof_t_wave_kin = 0.0_wp
      Inst(id)%prof_t_wave_check = 0.0_wp
      Inst(id)%prof_t_wave_set = 0.0_wp
      IF (reset_global) THEN
         CALL CD_HermiteCable_Dyn_Recovery_Reset()
         IF (enabled) THEN
            CALL CD_HermiteCable_Dyn_Reset_Profile()
            ! the EI = 0 line-step kernels (CableDyn_Profile, process-global like the above)
            CALL CD_Profile_Arm()
         ELSE
            CALL CD_HermiteCable_Dyn_Disable_Profile()
            CALL CD_Profile_Disarm()
         END IF
      END IF
   END SUBROUTINE reset_instance_profile

   SUBROUTINE copy_instance_profile( destination, source )
      INTEGER(IntKi), INTENT(IN) :: destination, source

      Inst(destination)%prof_enabled = Inst(source)%prof_enabled
      Inst(destination)%prof_n_update = Inst(source)%prof_n_update
      Inst(destination)%prof_n_solve = Inst(source)%prof_n_solve
      Inst(destination)%prof_n_calcout = Inst(source)%prof_n_calcout
      Inst(destination)%prof_n_fresh = Inst(source)%prof_n_fresh
      Inst(destination)%prof_n_wave = Inst(source)%prof_n_wave
      Inst(destination)%prof_t_init = Inst(source)%prof_t_init
      Inst(destination)%prof_t_update = Inst(source)%prof_t_update
      Inst(destination)%prof_t_wave = Inst(source)%prof_t_wave
      Inst(destination)%prof_t_step = Inst(source)%prof_t_step
      Inst(destination)%prof_t_calcout = Inst(source)%prof_t_calcout
      Inst(destination)%prof_t_loads = Inst(source)%prof_t_loads
      Inst(destination)%prof_t_native = Inst(source)%prof_t_native
      Inst(destination)%prof_t_overlay = Inst(source)%prof_t_overlay
      Inst(destination)%prof_t_channels = Inst(source)%prof_t_channels
      Inst(destination)%prof_t_restore = Inst(source)%prof_t_restore
      Inst(destination)%prof_t_wave_kin = Inst(source)%prof_t_wave_kin
      Inst(destination)%prof_t_wave_check = Inst(source)%prof_t_wave_check
      Inst(destination)%prof_t_wave_set = Inst(source)%prof_t_wave_set
   END SUBROUTINE copy_instance_profile

   !> Validate an instance handle (fails closed on 0 / stale handles, e.g. after a
   !> checkpoint restore in a fresh process, which does not rebuild the solver instance).
   LOGICAL FUNCTION valid_instance(id, ErrStat, ErrMsg, caller) RESULT(ok)
      INTEGER(IntKi), INTENT(IN)    :: id
      INTEGER(IntKi), INTENT(INOUT) :: ErrStat
      CHARACTER(*),   INTENT(INOUT) :: ErrMsg
      CHARACTER(*),   INTENT(IN)    :: caller

      ok = .FALSE.
      IF (ALLOCATED(Inst)) THEN
         IF (id >= 1 .AND. id <= SIZE(Inst)) THEN
            IF (Inst(id)%active) THEN
               ok = .TRUE.
               RETURN
            END IF
         END IF
      END IF
      CALL SetErrStat( ErrID_Fatal, 'CableDyn mooring module: no active solver instance for this module '// &
                       'data (restoring a checkpoint in a new process does not rebuild the solver; '// &
                       'restart the simulation from its input files).', ErrStat, ErrMsg, caller )
   END FUNCTION valid_instance

END MODULE CableDyn
