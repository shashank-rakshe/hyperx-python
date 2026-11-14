! File: src/CableDyn_CAPI.f90
! SPDX-License-Identifier: Apache-2.0
! Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
MODULE CableDyn_CAPI
  !! ISO C binding for CableDyn lifecycle ownership and coupled exchange.
  !!
  !! Its reference is doc/capi.rst (the C API reference): C callers receive
  !! an opaque handle that owns the OpenFAST-facing CableDyn module object. The
  !! ABI exposes deck and raw-array line initialization plus update/step/output calls.
  !! Raw-line initialization remains explicit, while deck initialization preserves
  !! the point-system object graph used by OpenFAST-facing integrations.
  USE, INTRINSIC :: ISO_C_BINDING, ONLY: C_BOOL, C_CHAR, C_DOUBLE, C_INT, C_NULL_CHAR, C_NULL_PTR, C_PTR, &
                                                                            C_ASSOCIATED, C_LOC, C_F_POINTER
  USE, INTRINSIC :: ISO_FORTRAN_ENV, ONLY: INT64, COMPILER_VERSION
  USE, INTRINSIC :: IEEE_ARITHMETIC, ONLY: IEEE_IS_FINITE
  USE CableDyn_DeckDriver, ONLY: CD_Init_Deck_System, CD_DECKDRV_OK, CD_DECKDRV_BADINPUT, CD_DECKDRV_SOLVEFAIL, &
                                 CD_DeckCurrentRuntimeType, CD_Deck_Current_Active, CD_Deck_Current_Sample_System, &
                                 CD_Deck_Query_dtM, CD_DECK_NAMELEN, CD_Eval_Aggregate_Channel, &
                                 CD_Eval_Aggregate_Segment_Tensions, CD_Eval_Aggregate_Line_Values, &
                                 CD_Rigid6_Inventory, CD_Rod_Inventory, CD_Channel_Token_Parses, CD_Cable_Deck_Node, &
                                 CD_Init_Notes_Start, CD_Init_Notes_Add, CD_Init_Notes_Take, CD_INIT_NOTE_LEN
  USE CableDyn_OpenFAST_Aggregate, ONLY: CD_AGG_ModuleType, CD_AGG_Init_From_Deck, CD_AGG_NMovingPoints, &
                                         CD_AGG_UpdateStates_Moving, CD_AGG_Step_Moving, CD_AGG_CalcOutput, &
                                         CD_AGG_GetMovingPointMesh, CD_AGG_End, CD_AGG_IsInitialized, CD_AGG_OK, &
                                         CD_AGG_BADINPUT, CD_AGG_NOT_INITIALIZED, CD_AGG_ALLOCFAIL, &
                                         CD_AGG_NFluidNodes, CD_AGG_GetFluidNodePositions, CD_AGG_SetFluidFields, &
                                         CD_AGG_GetInitMetadata, CD_AGG_GetInitLine
  USE CableDyn_Dynamic, ONLY: GenAlphaConfig
  USE CableDyn_Linalg, ONLY: CD_Blas_Runtime_Check, CD_LINALG_OK
  USE CableDyn_Model, ONLY: CD_ModelType, CD_Init_Model, CD_End_Model, CD_MODEL_OK, CD_MODEL_BADINPUT, &
                            CD_MODEL_SOLVEFAIL, CD_MODEL_ALLOCFAIL, CD_Update_Model_Hydro_Fields
  USE CableDyn_OpenFAST, ONLY: CD_FAST_ModuleType, CD_FAST_End, CD_FAST_Init_From_Models, &
                               CD_FAST_UpdateStates, CD_FAST_Step, CD_FAST_CalcOutput, &
                               CD_FAST_CalcOutputDerivatives, CD_FAST_GetCoupledMotion, CD_FAST_IsInitialized, &
                               CD_FAST_NCoupledDOF, CD_FAST_NPoints, CD_FAST_NLines, CD_FAST_OK, CD_FAST_BADINPUT, &
                               CD_FAST_NOT_INITIALIZED, CD_FAST_ALLOCFAIL, CD_FAST_UpdatePointFluidFields
  USE CableDyn_OpenFAST_HermiteFMF, ONLY: CD_HFMF_ModuleType, CD_HFMF_Section_Curvature, CD_HFMF_OK
  USE CableDyn_Precision, ONLY: wp, CD_ZERO, CD_ONE, CD_MIN_TIME_STEP
  USE CableDyn_System, ONLY: CD_SystemType, CD_System_Line_NDOF, CD_Get_System_PointBlocks, CD_SYSTEM_OK, &
                             CD_POINT_COUPLED
  IMPLICIT NONE
  PRIVATE

  PUBLIC :: CableDyn_Create
  PUBLIC :: CableDyn_Close
  PUBLIC :: CableDyn_InitDeck
  PUBLIC :: CableDyn_InitLine
  PUBLIC :: CableDyn_InitLines
  PUBLIC :: CableDyn_UpdateStates
  PUBLIC :: CableDyn_UpdatePointFluidFields
  PUBLIC :: CableDyn_Step
  PUBLIC :: CableDyn_CalcOutput
  PUBLIC :: CableDyn_CalcOutputDerivatives
  PUBLIC :: CableDyn_GetCoupledMotion
  PUBLIC :: CableDyn_GetLastError
  PUBLIC :: CableDyn_GetInitNotes
  PUBLIC :: CableDyn_GetVersion
  PUBLIC :: CableDyn_GetVersionString
  PUBLIC :: CableDyn_IsInitialized
  PUBLIC :: CableDyn_NCoupledDOF
  PUBLIC :: CableDyn_NPoints
  PUBLIC :: CableDyn_NLines
  PUBLIC :: CableDyn_GetAbiMinor
  PUBLIC :: CableDyn_NObjects
  PUBLIC :: CableDyn_GetObjectInfo
  PUBLIC :: CableDyn_GetLineValues
  PUBLIC :: CableDyn_GetPointState
  PUBLIC :: CableDyn_GetBodyState
  PUBLIC :: CableDyn_GetRodState
  PUBLIC :: CableDyn_EvalChannel
  PUBLIC :: CableDyn_InitDeckAt
  PUBLIC :: CableDyn_SaveState
  PUBLIC :: CableDyn_RestoreState
  PUBLIC :: CableDyn_GetCoupledLayout
  PUBLIC :: CableDyn_InitDeckRotating
  PUBLIC :: CableDyn_SetHostFluid
  PUBLIC :: CableDyn_NFluidNodes
  PUBLIC :: CableDyn_GetFluidNodePositions
  PUBLIC :: CableDyn_UpdateFluidFields
  PUBLIC :: CableDyn_UpdateRotations
  PUBLIC :: CableDyn_GetCoupledMoments

  INTEGER(C_INT), PARAMETER :: CD_C_OK = 0_C_INT
  INTEGER(C_INT), PARAMETER :: CD_C_BAD_HANDLE = 1_C_INT
  INTEGER(C_INT), PARAMETER :: CD_C_ALLOC_FAIL = 2_C_INT
  INTEGER(C_INT), PARAMETER :: CD_C_BAD_INPUT = 3_C_INT
  INTEGER(C_INT), PARAMETER :: CD_C_SOLVE_FAIL = 4_C_INT
  INTEGER(C_INT), PARAMETER :: CD_C_NOT_INITIALIZED = 5_C_INT
  INTEGER(C_INT), PARAMETER :: CD_C_VERSION_MAJOR = 0_C_INT
  INTEGER(C_INT), PARAMETER :: CD_C_VERSION_MINOR = 4_C_INT
  INTEGER(C_INT), PARAMETER :: CD_C_VERSION_PATCH = 2_C_INT
  INTEGER(C_INT), PARAMETER :: CD_C_ABI_VERSION = 1_C_INT
  CHARACTER(*), PARAMETER :: CD_C_VERSION_STRING = 'CableDyn 0.4.2 C-ABI 1'
  !> Minor extension level of ABI 1: 1 adds the in-process object queries, 2 the host-coupling
  !> calls (initialization at host positions, state save/restore, the coupled layout query), 3
  !> the host rotations (initialization for a host that turns its coupled points, their
  !> rotations, the coupled moments), 4 the host fluid field at the nodes of a deck.
  INTEGER(C_INT), PARAMETER :: CD_C_ABI_MINOR = 4_C_INT
  !> Object kinds of CableDyn_NObjects / CableDyn_GetObjectInfo.
  INTEGER(C_INT), PARAMETER :: CD_C_OBJ_LINE = 1_C_INT, CD_C_OBJ_POINT = 2_C_INT, CD_C_OBJ_BODY = 3_C_INT, &
                               CD_C_OBJ_ROD = 4_C_INT
  !> Line quantities of CableDyn_GetLineValues (the codes of the line-node output channels).
  INTEGER(C_INT), PARAMETER :: CD_C_LINE_POSITION = 1_C_INT, CD_C_LINE_VELOCITY = 2_C_INT, &
                               CD_C_LINE_TENSION = 3_C_INT, CD_C_LINE_ACCELERATION = 4_C_INT, &
                               CD_C_LINE_CURVATURE = 5_C_INT, CD_C_LINE_BEND_MOMENT = 6_C_INT, &
                               CD_C_LINE_DECLINATION = 7_C_INT, CD_C_LINE_AZIMUTH = 8_C_INT, &
                               CD_C_LINE_SEGMENT_TENSION = 9_C_INT, CD_C_LINE_DECK_NODE = 10_C_INT, &
                               CD_C_LINE_SECTION_CURVATURE = 11_C_INT
  !> Capacity of the per-handle diagnostic retained for CableDyn_GetLastError.
  INTEGER, PARAMETER :: CD_C_MSG_LEN = 4096

  ! Live-handle integrity. A handle is valid only if its C_PTR is in the registry of
  ! handles this module created and has not closed (so a foreign, stale, or
  ! double-closed pointer is rejected WITHOUT being dereferenced) AND the target's
  ! magic field is intact (defence in depth once the registry says the deref is safe).
  ! Concurrency: registry operations run under a process-local C11 atomic mutex, and Close uses a
  ! single atomic check-and-remove (registry_claim) so a concurrent Close of the same
  ! or a copied handle has exactly one winner that frees -- no double-free. This
  ! synchronization is independent of the optional OpenMP performance runtime, so handle
  ! lifecycle stays thread-safe in serial/non-OpenMP builds too. (Calling
  ! a query on a handle while another thread is Closing it is a use-after-free the caller
  ! must avoid, as with any handle API; the registry defends against stale/foreign/
  ! double-closed handles, not against racing a live handle against its own teardown.)
  ! Residual limitation: because the ABI hands back a raw C_PTR, a stale copy whose
  ! freed address is later reused by a new Create would alias the live handle and pass
  ! -- inherent to a pointer ABI; an opaque integer-id ABI would remove it.
  INTEGER(INT64), PARAMETER :: CD_C_HANDLE_MAGIC = 3400658189_INT64    ! 0xCAB1ED0D, a distinctive sentinel
  TYPE(C_PTR), ALLOCATABLE, SAVE :: g_handle_registry(:)
  INTEGER, SAVE :: g_handle_count = 0

  INTERFACE
    SUBROUTINE cabledyn_registry_lock() BIND(C, NAME='cabledyn_registry_lock')
    END SUBROUTINE cabledyn_registry_lock
    SUBROUTINE cabledyn_registry_unlock() BIND(C, NAME='cabledyn_registry_unlock')
    END SUBROUTINE cabledyn_registry_unlock
    ! Process-wide blocking lock around deck parsing and handle initialisation
    ! (src/cabledyn_mutex.c). The Fortran runtime's file and formatted I/O is not
    ! safe to run from several threads at once, so InitDeck/InitLine/InitLines hold
    ! it; Step and the other per-handle calls do no I/O on their success paths and
    ! do not take it.
    SUBROUTINE cabledyn_input_lock() BIND(C, NAME='cabledyn_input_lock')
    END SUBROUTINE cabledyn_input_lock
    SUBROUTINE cabledyn_input_unlock() BIND(C, NAME='cabledyn_input_unlock')
    END SUBROUTINE cabledyn_input_unlock
    ! Limits OpenBLAS to one thread once per process and, where CableDyn loads
    ! OpenBLAS at run time, loads it with that pool size (src/cabledyn_blas.c).
    ! Returns 0 on success, 1 when that OpenBLAS runtime could not be loaded.
    FUNCTION cabledyn_blas_threads_once() RESULT(failed) BIND(C, NAME='cabledyn_blas_threads_once')
      IMPORT :: C_INT
      INTEGER(C_INT) :: failed
    END FUNCTION cabledyn_blas_threads_once
  END INTERFACE

  TYPE :: CD_C_Handle
    INTEGER(INT64) :: magic = 0_INT64
    TYPE(CD_FAST_ModuleType) :: fast
    REAL(wp), ALLOCATABLE :: q_work(:)
    REAL(wp), ALLOCATABLE :: v_work(:)
    REAL(wp), ALLOCATABLE :: a_work(:)
    REAL(wp), ALLOCATABLE :: loads_work(:)
    REAL(wp), ALLOCATABLE :: jq_work(:, :)
    REAL(wp), ALLOCATABLE :: jv_work(:, :)
    REAL(wp), ALLOCATABLE :: ja_work(:, :)
    REAL(wp), ALLOCATABLE :: madd_work(:, :)
    REAL(wp), ALLOCATABLE :: fluid_velocity_work(:, :)
    REAL(wp), ALLOCATABLE :: fluid_acceleration_work(:, :)
    REAL(wp), ALLOCATABLE :: waterline_work(:)
    ! CableDyn_GetLineValues: one value per node of the longest line read so far.
    REAL(wp), ALLOCATABLE :: line_work(:)
    ! Decks with BODIES or RODS run on the coupled aggregate (use_agg): its moving points are the
    ! coupled DOFs, its step is the deck dtM (agg_dt), and agg_t is its committed time.
    LOGICAL :: use_agg = .FALSE.
    TYPE(CD_AGG_ModuleType) :: agg
    ! The point route's deck current (a steady field), sampled at the step-start node positions
    ! before every step, as the standalone point-system march samples it.
    TYPE(CD_DeckCurrentRuntimeType) :: pt_current
    REAL(wp) :: agg_dt = CD_ZERO, agg_t = CD_ZERO
    REAL(wp), ALLOCATABLE :: agg_pos(:, :), agg_vel(:, :), agg_acc(:, :), agg_load(:, :)
    ! A handle initialised by CableDyn_InitDeckRotating (host_rot): the host's rotation of each
    ! coupled block, set by CableDyn_UpdateRotations and passed with every update and step on the
    ! aggregate route (agg_dcm: OpenFAST's global-to-body DCM; agg_om, agg_al: the angular
    ! velocity and acceleration in global axes; identity and rest at the static start).
    ! agg_moment: the coupled moments' workspace of CableDyn_GetCoupledMoments.
    LOGICAL :: host_rot = .FALSE.
    ! CableDyn_SetHostFluid: the next deck initialization takes the host's fluid field; agg_host_fluid
    ! is what the live model was built with, and fluid_ready that it holds a field (the march
    ! refuses a step without one: the deck's declared water would silently be still).
    LOGICAL :: host_fluid = .FALSE., agg_host_fluid = .FALSE., fluid_ready = .FALSE.
    LOGICAL :: saved_fluid_ready = .FALSE.
    REAL(wp), ALLOCATABLE :: agg_dcm(:, :, :), agg_om(:, :), agg_al(:, :), agg_moment(:, :)
    ! Point-route line inventory for the object queries: the deck-line-id -> system-line map
    ! (pt_obj, 0 = no such line; pt_is_cable all .FALSE.) the shared channel evaluator resolves
    ! through, and an empty cable store to pass it. Raw-line handles number their lines 1..n.
    LOGICAL, ALLOCATABLE :: pt_is_cable(:)
    INTEGER, ALLOCATABLE :: pt_obj(:)
    TYPE(CD_HFMF_ModuleType), ALLOCATABLE :: no_cables(:)
    ! The single save slot of CableDyn_SaveState/RestoreState: a deep copy of the route's model
    ! object (the point system, or the aggregate on the heap) and the aggregate's committed time,
    ! valid (has_saved) from a SaveState until a successful initialization or a failed
    ! InitLine/InitLines on a handle whose live model is a point system (drop_point_save_on_failure);
    ! a failed InitDeck/InitDeckAt, or a failed InitLine/InitLines on an aggregate handle, keeps it.
    LOGICAL :: has_saved = .FALSE.
    TYPE(CD_FAST_ModuleType) :: saved_fast
    TYPE(CD_AGG_ModuleType), ALLOCATABLE :: saved_agg
    REAL(wp) :: saved_agg_t = CD_ZERO
    REAL(wp), ALLOCATABLE :: saved_dcm(:, :, :), saved_om(:, :), saved_al(:, :)
    CHARACTER(CD_C_MSG_LEN) :: last_error = ''
    ! The notes of the last initialisation (CableDyn_GetInitNotes), each ended by a new line.
    CHARACTER(:), ALLOCATABLE :: init_notes
  END TYPE CD_C_Handle

CONTAINS

  SUBROUTINE CableDyn_GetVersion(major, minor, patch, abi_version) BIND(C, NAME='CableDyn_GetVersion')
    !! Return the CableDyn C ABI version tuple.
    INTEGER(C_INT), INTENT(OUT) :: major, minor, patch, abi_version

    major = CD_C_VERSION_MAJOR
    minor = CD_C_VERSION_MINOR
    patch = CD_C_VERSION_PATCH
    abi_version = CD_C_ABI_VERSION
  END SUBROUTINE CableDyn_GetVersion

  SUBROUTINE CableDyn_GetVersionString(version_ptr, version_len) BIND(C, NAME='CableDyn_GetVersionString')
    !! Copy a null-terminated human-readable CableDyn C ABI version string.
    TYPE(C_PTR), VALUE :: version_ptr
    INTEGER(C_INT), VALUE :: version_len

    CHARACTER(KIND=C_CHAR), POINTER :: version_c(:)

    IF (version_len < 1_C_INT .OR. .NOT. C_ASSOCIATED(version_ptr)) RETURN
    CALL C_F_POINTER(version_ptr, version_c, [INT(version_len)])
    CALL copy_message_to_c(CD_C_VERSION_STRING, version_c)
  END SUBROUTINE CableDyn_GetVersionString

  SUBROUTINE CableDyn_Create(handle, err_stat) BIND(C, NAME='CableDyn_Create')
    !! Allocate a CableDyn C handle. The returned handle is uninitialized until
    !! CableDyn_InitDeck, CableDyn_InitLine, or CableDyn_InitLines succeeds.
    TYPE(C_PTR), INTENT(OUT) :: handle
    INTEGER(C_INT), INTENT(OUT) :: err_stat
    TYPE(CD_C_Handle), POINTER :: h
    INTEGER :: stat

    handle = C_NULL_PTR
    err_stat = CD_C_OK
    ! Every CableDyn solve is a small banded system: keep a linked OpenBLAS from
    ! starting one worker (and one committed work buffer) per logical CPU. A run-time
    ! loaded BLAS library that cannot be loaded is reported by the Init calls, which
    ! have a handle to carry the diagnostic (see blas_runtime_ready).
    stat = INT(cabledyn_blas_threads_once())
    ALLOCATE (h, STAT=stat)
    IF (stat /= 0) THEN
      err_stat = CD_C_ALLOC_FAIL
      RETURN
    END IF
    h%magic = CD_C_HANDLE_MAGIC
    h%last_error = ''
    handle = C_LOC(h)
    CALL registry_add(handle, stat)
    IF (stat /= 0) THEN
      DEALLOCATE (h)
      handle = C_NULL_PTR
      err_stat = CD_C_ALLOC_FAIL
    END IF
  END SUBROUTINE CableDyn_Create

  SUBROUTINE CableDyn_InitDeck(handle, deck_path_ptr, deck_path_len, err_stat) BIND(C, NAME='CableDyn_InitDeck')
    !! Initialize from a supported MoorDyn-style .dat deck. This routes through the
    !! production deck parser and static-IC builder, and therefore inherits its
    !! fail-closed feature subset. Deck initialisations are serialised process-wide:
    !! concurrent calls (on distinct handles) run one after another.
    TYPE(C_PTR), VALUE :: handle, deck_path_ptr
    INTEGER(C_INT), VALUE :: deck_path_len
    INTEGER(C_INT), INTENT(OUT) :: err_stat

    IF (.NOT. blas_runtime_ready(handle, 'CableDyn_InitDeck', err_stat)) RETURN
    CALL cabledyn_input_lock()
    CALL init_deck_serialised(handle, deck_path_ptr, deck_path_len, 'CableDyn_InitDeck', err_stat)
    CALL cabledyn_input_unlock()
  END SUBROUTINE CableDyn_InitDeck

  SUBROUTINE CableDyn_InitDeckAt(handle, deck_path_ptr, deck_path_len, q0_ptr, n_q0, err_stat) &
    BIND(C, NAME='CableDyn_InitDeckAt')
    !! CableDyn_InitDeck with the static solve at the host's positions of the coupled points:
    !! every line-bound Coupled/Vessel point starts at its entry of q0 instead of its deck
    !! coordinates, and the statics (lines, Free/Connect points, bodies and rods) are solved
    !! with those points held there, at rest. q0 is either the full coupled vector of the
    !! deck's route (n_q0 = CableDyn_NCoupledDOF after the call; the Fixed, Free and Connect
    !! blocks are not read) or the Coupled/Vessel blocks alone, in coupled-vector order. A
    !! deck without line-bound Coupled/Vessel points takes n_q0 = 0 (q0 may then be null).
    !! Serialised process-wide and transactional like CableDyn_InitDeck.
    TYPE(C_PTR), VALUE :: handle, deck_path_ptr, q0_ptr
    INTEGER(C_INT), VALUE :: deck_path_len, n_q0
    INTEGER(C_INT), INTENT(OUT) :: err_stat

    CALL init_deck_at(handle, deck_path_ptr, deck_path_len, q0_ptr, n_q0, 'CableDyn_InitDeckAt', .FALSE., err_stat)
  END SUBROUTINE CableDyn_InitDeckAt

  SUBROUTINE CableDyn_InitDeckRotating(handle, deck_path_ptr, deck_path_len, q0_ptr, n_q0, err_stat) &
    BIND(C, NAME='CableDyn_InitDeckRotating')
    !! CableDyn_InitDeckAt for a host that turns its coupled points: the handle takes each
    !! coupled block's rotation from CableDyn_UpdateRotations and passes it with every update and
    !! step, so a line restrained in torsion (END CONNECTIONS TorsStiffness) and a Rigid bending
    !! END CONNECTION turn with the host at their coupled end, as on the coupled OpenFAST route.
    !! The rotations start at identity (the deck's axes at the static start) and rest. n_q0 = 0
    !! solves the statics at the deck positions, as CableDyn_InitDeck. Serialised process-wide
    !! and transactional like CableDyn_InitDeck.
    TYPE(C_PTR), VALUE :: handle, deck_path_ptr, q0_ptr
    INTEGER(C_INT), VALUE :: deck_path_len, n_q0
    INTEGER(C_INT), INTENT(OUT) :: err_stat

    CALL init_deck_at(handle, deck_path_ptr, deck_path_len, q0_ptr, n_q0, 'CableDyn_InitDeckRotating', .TRUE., &
                      err_stat)
  END SUBROUTINE CableDyn_InitDeckRotating

  SUBROUTINE init_deck_at(handle, deck_path_ptr, deck_path_len, q0_ptr, n_q0, caller, rotating, err_stat)
    !! CableDyn_InitDeckAt / CableDyn_InitDeckRotating body: the host positions q0 (n_q0 = 0:
    !! none, the deck positions) and, with rotating, a handle that takes the host's rotations.
    TYPE(C_PTR), VALUE :: handle, deck_path_ptr, q0_ptr
    INTEGER(C_INT), VALUE :: deck_path_len, n_q0
    CHARACTER(*), INTENT(IN) :: caller
    LOGICAL, INTENT(IN) :: rotating
    INTEGER(C_INT), INTENT(OUT) :: err_stat
    TYPE(CD_C_Handle), POINTER :: h
    REAL(C_DOUBLE), POINTER :: q0_c(:)
    REAL(wp), ALLOCATABLE :: positions(:, :)
    INTEGER :: stat

    IF (.NOT. blas_runtime_ready(handle, caller, err_stat)) RETURN
    err_stat = validate_handle(handle, h)
    IF (err_stat /= CD_C_OK) RETURN
    IF (n_q0 < 0_C_INT .OR. MOD(n_q0, 3_C_INT) /= 0_C_INT) THEN
      CALL set_status(h, CD_C_BAD_INPUT, caller//': n_q0 must be a non-negative multiple of 3', err_stat)
      RETURN
    END IF
    IF (n_q0 > 0_C_INT .AND. .NOT. C_ASSOCIATED(q0_ptr)) THEN
      h%init_notes = ''
      CALL set_status(h, CD_C_BAD_INPUT, caller//': q0 pointer is null', err_stat)
      RETURN
    END IF
    IF (rotating .AND. n_q0 == 0_C_INT) THEN
      ! no host positions: the statics at the deck positions, as CableDyn_InitDeck
      CALL cabledyn_input_lock()
      CALL init_deck_serialised(handle, deck_path_ptr, deck_path_len, caller, err_stat, rotating=rotating)
      CALL cabledyn_input_unlock()
      RETURN
    END IF
    ALLOCATE (positions(3, INT(n_q0)/3), STAT=stat)
    IF (stat /= 0) THEN
      CALL set_status(h, CD_C_ALLOC_FAIL, caller//': q0 allocation failed', err_stat)
      RETURN
    END IF
    IF (n_q0 > 0_C_INT) THEN
      CALL C_F_POINTER(q0_ptr, q0_c, [INT(n_q0)])
      IF (.NOT. ALL(IEEE_IS_FINITE(q0_c))) THEN
        h%init_notes = ''
        CALL set_status(h, CD_C_BAD_INPUT, caller//': q0 must be finite', err_stat)
        RETURN
      END IF
      positions = RESHAPE(REAL(q0_c, wp), SHAPE(positions))
    END IF
    CALL cabledyn_input_lock()
    CALL init_deck_serialised(handle, deck_path_ptr, deck_path_len, caller, err_stat, positions, rotating)
    CALL cabledyn_input_unlock()
  END SUBROUTINE init_deck_at

  SUBROUTINE init_deck_serialised(handle, deck_path_ptr, deck_path_len, caller, err_stat, positions, rotating)
    !! init_deck_build with the notes of the attempt kept on the handle, on success or failure; the
    !! caller holds the process-wide input lock, which the capture of the notes relies on.
    TYPE(C_PTR), VALUE :: handle, deck_path_ptr
    INTEGER(C_INT), VALUE :: deck_path_len
    CHARACTER(*), INTENT(IN) :: caller
    INTEGER(C_INT), INTENT(OUT) :: err_stat
    REAL(wp), INTENT(IN), OPTIONAL :: positions(:, :)
    LOGICAL, INTENT(IN), OPTIONAL :: rotating
    TYPE(CD_C_Handle), POINTER :: h
    CHARACTER(:), ALLOCATABLE :: notes

    CALL CD_Init_Notes_Start()
    CALL init_deck_build(handle, deck_path_ptr, deck_path_len, caller, err_stat, positions, rotating)
    CALL CD_Init_Notes_Take(notes)
    IF (validate_handle(handle, h) == CD_C_OK) CALL MOVE_ALLOC(notes, h%init_notes)
  END SUBROUTINE init_deck_serialised

  SUBROUTINE init_deck_build(handle, deck_path_ptr, deck_path_len, caller, err_stat, positions, rotating)
    !! CableDyn_InitDeck / CableDyn_InitDeckAt / CableDyn_InitDeckRotating body. positions (3, n):
    !! the host positions of CableDyn_InitDeckAt; rotating: the handle takes the host's rotations
    !! (CableDyn_InitDeckRotating).
    TYPE(C_PTR), VALUE :: handle, deck_path_ptr
    INTEGER(C_INT), VALUE :: deck_path_len
    CHARACTER(*), INTENT(IN) :: caller
    INTEGER(C_INT), INTENT(OUT) :: err_stat
    REAL(wp), INTENT(IN), OPTIONAL :: positions(:, :)
    LOGICAL, INTENT(IN), OPTIONAL :: rotating

    TYPE(CD_C_Handle), POINTER :: h
    TYPE(CD_FAST_ModuleType) :: new_fast
    TYPE(CD_DeckCurrentRuntimeType) :: new_current
    CHARACTER(KIND=C_CHAR), POINTER :: path_c(:)
    CHARACTER(:), ALLOCATABLE :: deck_path
    INTEGER :: i, es, end_es, stat, n_objects, n_finite
    INTEGER, ALLOCATABLE :: line_ids(:)
    REAL(wp) :: dtm, gravity, rho_water
    LOGICAL :: has_dtm, rot
    CHARACTER(CD_C_MSG_LEN) :: em, end_em

    rot = .FALSE.
    IF (PRESENT(rotating)) rot = rotating
    err_stat = validate_handle(handle, h)
    IF (err_stat /= CD_C_OK) RETURN
    IF (deck_path_len < 1_C_INT .OR. .NOT. C_ASSOCIATED(deck_path_ptr)) THEN
      CALL set_status(h, CD_C_BAD_INPUT, caller//': deck path pointer is null or length is non-positive', err_stat)
      RETURN
    END IF
    CALL C_F_POINTER(deck_path_ptr, path_c, [INT(deck_path_len)])
    ALLOCATE (CHARACTER(LEN=INT(deck_path_len)) :: deck_path, STAT=stat)
    IF (stat /= 0) THEN
      CALL set_status(h, CD_C_ALLOC_FAIL, caller//': deck path allocation failed', err_stat)
      RETURN
    END IF
    DO i = 1, INT(deck_path_len)
      IF (path_c(i) == C_NULL_CHAR) THEN
        IF (i == 1) THEN
          CALL set_status(h, CD_C_BAD_INPUT, caller//': deck path is empty', err_stat)
          RETURN
        END IF
        deck_path = deck_path(:i - 1)
        EXIT
      END IF
      deck_path(i:i) = path_c(i)
    END DO
    ! A deck with BODIES or RODS (standalone rules: a motionFile-free deck with dtM) runs on the
    ! coupled aggregate; every other deck keeps the point-system route and its diagnostics.
    ! A deck with finite-EI lines likewise runs on the aggregate (its Hermite cables).
    ! With a host fluid field the deck is read as the aggregate reads it, a caller-driven deck, so
    ! the SEASTATE and WaveKinMod 2 water policies of a host reach it.
    CALL CD_Deck_Query_dtM(TRIM(deck_path), dtm, has_dtm, es, em, standalone_scan=.NOT. h%host_fluid, &
                           n_bodies_rods=n_objects, &
                           n_finite_ei=n_finite)
    IF (es == CD_DECKDRV_OK .AND. (n_objects > 0 .OR. n_finite > 0 .OR. h%host_fluid)) THEN
      CALL init_deck_aggregate(h, TRIM(deck_path), has_dtm, dtm, caller, rot, err_stat, positions)
      RETURN
    END IF
    ! An absent positions argument stays absent through the optional coupled_positions.
    CALL CD_Init_Deck_System(TRIM(deck_path), new_fast%system, dtm, gravity, rho_water, es, em, line_ids=line_ids, &
                             coupled_positions=positions, deck_current=new_current)
    IF (es /= CD_DECKDRV_OK) THEN
      CALL map_deck_status(es, err_stat)
      CALL store_status(h, err_stat, caller//': '//TRIM(em))
      CALL CD_FAST_End(new_fast, end_es, end_em)
      RETURN
    END IF
    IF (PRESENT(positions)) THEN
      CALL check_point_start(new_fast, positions, em)
      IF (LEN_TRIM(em) > 0) THEN
        CALL set_status(h, CD_C_BAD_INPUT, caller//': '//TRIM(em), err_stat)
        CALL CD_FAST_End(new_fast, end_es, end_em)
        RETURN
      END IF
    END IF
    CALL CD_FAST_End(h%fast, end_es, end_em)
    h%fast = new_fast
    h%pt_current = new_current
    CALL CD_FAST_End(new_fast, end_es, end_em)
    CALL drop_aggregate(h)
    CALL drop_saved_state(h)
    CALL set_point_line_map(h, line_ids)
    ! the point route's EI = 0 lines take no rotation (CableDyn_UpdateRotations checks and
    ! ignores it)
    h%host_rot = rot
    CALL store_status(h, CD_C_OK, '')
    err_stat = CD_C_OK
  END SUBROUTINE init_deck_build

  SUBROUTINE check_point_start(fast, positions, msg)
    !! Post-condition of CableDyn_InitDeckAt on the point route: every Coupled block of the new
    !! system starts at its host position (msg is blank when it does). positions holds either
    !! one column per coupled block or one per Coupled block (apply_point_system_positions).
    TYPE(CD_FAST_ModuleType), INTENT(IN) :: fast
    REAL(wp), INTENT(IN) :: positions(:, :)
    CHARACTER(*), INTENT(OUT) :: msg
    INTEGER, ALLOCATABLE :: blocks(:)
    REAL(wp), ALLOCATABLE :: q(:), v(:), a(:)
    INTEGER :: k, col, n, es, stat
    LOGICAL :: full
    CHARACTER(CD_C_MSG_LEN) :: em

    msg = ''
    n = CD_FAST_NCoupledDOF(fast, es, em)
    IF (es /= CD_FAST_OK) THEN
      msg = 'the coupled vector of the new model is unavailable: '//TRIM(em)
      RETURN
    END IF
    CALL CD_Get_System_PointBlocks(fast%system, blocks, es, em)
    IF (es /= CD_SYSTEM_OK .OR. .NOT. ALLOCATED(blocks)) THEN
      msg = 'the coupled layout of the new model is unavailable'
      RETURN
    END IF
    ALLOCATE (q(n), v(n), a(n), STAT=stat)
    IF (stat /= 0) THEN
      msg = 'workspace allocation failed'
      RETURN
    END IF
    CALL CD_FAST_GetCoupledMotion(fast, q, v, a, es, em)
    IF (es /= CD_FAST_OK) THEN
      msg = 'the coupled motion of the new model is unavailable: '//TRIM(em)
      RETURN
    END IF
    full = SIZE(positions, 2) == SIZE(blocks)
    col = 0
    DO k = 1, SIZE(blocks)
      IF (full) col = col + 1
      IF (fast%system%points(blocks(k))%point_type /= CD_POINT_COUPLED) CYCLE
      IF (.NOT. full) col = col + 1
      IF (.NOT. same_position(q(3*k - 2:3*k), positions(:, col))) THEN
        msg = 'coupled point '//TRIM(int_text(fast%system%points(blocks(k))%id))//' did not start at its '// &
              'position in q0'
        RETURN
      END IF
    END DO
  END SUBROUTINE check_point_start

  PURE LOGICAL FUNCTION same_position(x, y) RESULT(same)
    !! Two coupled-point positions agree to 1e-9 relative (1e-9 m below 1 m).
    REAL(wp), INTENT(IN) :: x(3), y(3)
    same = ALL(ABS(x - y) <= 1.0e-9_wp*MAX(1.0_wp, ABS(y)))
  END FUNCTION same_position

  SUBROUTINE init_deck_aggregate(h, deck_path, has_dtm, dtm, caller, rotating, err_stat, positions)
    !! Build a BODIES/RODS deck on the coupled aggregate (transactional: the handle keeps its
    !! previous model on failure). Coupled/Vessel rods and bodies are 6-DOF host nodes, which the
    !! translational C ABI cannot drive; the standalone deck rules already reject them without a
    !! motionFile, and the aggregate rejects a motionFile. positions (3, n_moving): the host
    !! positions of CableDyn_InitDeckAt, in the aggregate's coupled order. rotating: the host
    !! passes the coupled points' rotations (CableDyn_InitDeckRotating), which a line restrained
    !! in torsion needs; without it such a deck is refused.
    TYPE(CD_C_Handle), POINTER, INTENT(INOUT) :: h
    CHARACTER(*), INTENT(IN) :: deck_path
    LOGICAL, INTENT(IN) :: has_dtm
    REAL(wp), INTENT(IN) :: dtm
    CHARACTER(*), INTENT(IN) :: caller
    LOGICAL, INTENT(IN) :: rotating
    INTEGER(C_INT), INTENT(OUT) :: err_stat
    REAL(wp), INTENT(IN), OPTIONAL :: positions(:, :)
    ! On the heap: InitDeck runs on the host's thread, whose stack size the host chooses.
    TYPE(CD_AGG_ModuleType), ALLOCATABLE :: new_agg
    INTEGER :: es, nm, stat, k
    REAL(wp), ALLOCATABLE :: pos(:, :), vel(:, :), acc(:, :), load(:, :)
    REAL(wp), ALLOCATABLE :: dcm(:, :, :), om(:, :), al(:, :), moment(:, :)
    CHARACTER(CD_C_MSG_LEN) :: em

    IF (.NOT. (has_dtm .AND. dtm > CD_ZERO)) THEN
      CALL set_status(h, CD_C_BAD_INPUT, caller//': a deck with finite-EI lines, BODIES or RODS '// &
                      'needs dtM, the fixed step of CableDyn_Step', err_stat)
      RETURN
    END IF
    ALLOCATE (new_agg, STAT=stat)
    IF (stat /= 0) THEN
      CALL set_status(h, CD_C_ALLOC_FAIL, caller//': aggregate allocation failed', err_stat)
      RETURN
    END IF
    ! An absent positions argument stays absent through the optional coupled_positions.
    ! The deck's own current is marched here, unless the host supplies the field: then it sets
    ! the static start only.
    CALL CD_AGG_Init_From_Deck(new_agg, deck_path, dtm, es, em, coupled_positions=positions, &
                               host_orientation=rotating, external_fluid=h%host_fluid, &
                               deck_current=.NOT. h%host_fluid, static_deck_current=h%host_fluid)
    IF (es /= CD_AGG_OK) THEN
      CALL map_agg_status(es, err_stat)
      CALL store_status(h, err_stat, caller//': '//TRIM(em))
      CALL CD_AGG_End(new_agg, es, em)
      RETURN
    END IF
    nm = CD_AGG_NMovingPoints(new_agg, es, em)
    ! Allocate the new route's workspace before releasing the old route, so an
    ! allocation failure leaves the handle's previous model in place.
    ALLOCATE (pos(3, nm), vel(3, nm), acc(3, nm), load(3, nm), dcm(3, 3, nm), om(3, nm), al(3, nm), &
              moment(3, nm), STAT=stat)
    IF (stat /= 0) THEN
      CALL CD_AGG_End(new_agg, es, em)
      CALL set_status(h, CD_C_ALLOC_FAIL, caller//': aggregate workspace allocation failed', err_stat)
      RETURN
    END IF
    IF (PRESENT(positions)) THEN
      ! Post-condition: every moving point starts at its host position. A point that appears
      ! in two blocks (a fairlead shared by an EI=0 line and a finite-EI line) takes the
      ! position of its last block, so two different entries for it are rejected here.
      CALL CD_AGG_GetMovingPointMesh(new_agg, pos, vel, acc, load, es, em)
      IF (es == CD_AGG_OK .AND. SIZE(positions, 2) == nm) THEN
        DO k = 1, nm
          IF (.NOT. same_position(pos(:, k), positions(:, k))) THEN
            es = CD_AGG_BADINPUT
            em = 'coupled block '//TRIM(int_text(k - 1))//' did not start at its position in q0 (a point '// &
                 'listed in two blocks needs the same position in both)'
            EXIT
          END IF
        END DO
      ELSE IF (es == CD_AGG_OK) THEN
        es = CD_AGG_BADINPUT
        em = 'q0 does not match the coupled vector of the new model'
      END IF
      IF (es /= CD_AGG_OK) THEN
        CALL map_agg_status(es, err_stat)
        CALL store_status(h, err_stat, caller//': '//TRIM(em))
        CALL CD_AGG_End(new_agg, es, em)
        RETURN
      END IF
    END IF
    CALL add_aggregate_notes(new_agg)
    CALL CD_FAST_End(h%fast, es, em)
    CALL drop_point_current(h)
    CALL drop_aggregate(h)
    CALL drop_saved_state(h)
    CALL clear_c_workspace(h)
    CALL MOVE_ALLOC(pos, h%agg_pos)
    CALL MOVE_ALLOC(vel, h%agg_vel)
    CALL MOVE_ALLOC(acc, h%agg_acc)
    CALL MOVE_ALLOC(load, h%agg_load)
    dcm = CD_ZERO
    DO k = 1, nm
      dcm(1, 1, k) = CD_ONE
      dcm(2, 2, k) = CD_ONE
      dcm(3, 3, k) = CD_ONE
    END DO
    om = CD_ZERO
    al = CD_ZERO
    moment = CD_ZERO
    CALL MOVE_ALLOC(dcm, h%agg_dcm)
    CALL MOVE_ALLOC(om, h%agg_om)
    CALL MOVE_ALLOC(al, h%agg_al)
    CALL MOVE_ALLOC(moment, h%agg_moment)
    h%host_rot = rotating
    h%agg_host_fluid = h%host_fluid
    h%fluid_ready = .FALSE.
    CALL move_aggregate(new_agg, h%agg)
    CALL clear_point_line_map(h)
    h%use_agg = .TRUE.
    h%agg_dt = dtm
    h%agg_t = CD_ZERO
    CALL store_status(h, CD_C_OK, '')
    err_stat = CD_C_OK
  END SUBROUTINE init_deck_aggregate

  SUBROUTINE add_aggregate_notes(agg)
    !! The notes of the lines of a new aggregate, to the notes of its initialisation.
    TYPE(CD_AGG_ModuleType), INTENT(IN) :: agg
    INTEGER :: i, es, n_lines, n_points, n_sections, n_ei0, n_finite, line_id
    REAL(wp) :: tension, force(3), inclination, declination, azimuth
    CHARACTER(CD_C_MSG_LEN) :: em
    CHARACTER(CD_INIT_NOTE_LEN) :: note

    CALL CD_AGG_GetInitMetadata(agg, n_lines, n_points, n_sections, n_ei0, n_finite, es, em)
    IF (es == CD_AGG_OK) THEN
      DO i = 1, n_lines
        CALL CD_AGG_GetInitLine(agg, i, line_id, tension, force, inclination, declination, azimuth, es, em, note=note)
        IF (es /= CD_AGG_OK) EXIT
        CALL CD_Init_Notes_Add(note)
      END DO
    END IF
    IF (es /= CD_AGG_OK) CALL CD_Init_Notes_Add('the initialisation notes are incomplete: '//TRIM(em))
  END SUBROUTINE add_aggregate_notes

  SUBROUTINE move_aggregate(src, dst)
    !! Take over an initialized aggregate (deep copy, then release the source).
    TYPE(CD_AGG_ModuleType), INTENT(INOUT) :: src, dst
    INTEGER :: es
    CHARACTER(CD_C_MSG_LEN) :: em
    CALL copy_aggregate(src, dst)
    CALL CD_AGG_End(src, es, em)
  END SUBROUTINE move_aggregate

  SUBROUTINE copy_aggregate(src, dst)
    !! Replace dst by a deep copy of src: every allocatable component (each sub-model's state,
    !! histories, snapshot buffers and solver workspace) is copied, so the copy evolves
    !! exactly as src would. Dummy arguments, so the assignment needs no temporary.
    TYPE(CD_AGG_ModuleType), INTENT(IN) :: src
    TYPE(CD_AGG_ModuleType), INTENT(INOUT) :: dst
    INTEGER :: es
    CHARACTER(CD_C_MSG_LEN) :: em
    CALL CD_AGG_End(dst, es, em)
    dst = src
  END SUBROUTINE copy_aggregate

  SUBROUTINE copy_point_system(src, dst)
    !! The point-route twin of copy_aggregate.
    TYPE(CD_FAST_ModuleType), INTENT(IN) :: src
    TYPE(CD_FAST_ModuleType), INTENT(INOUT) :: dst
    INTEGER :: es
    CHARACTER(CD_C_MSG_LEN) :: em
    CALL CD_FAST_End(dst, es, em)
    dst = src
  END SUBROUTINE copy_point_system

  SUBROUTINE drop_saved_state(h)
    !! Discard the save slot (a new initialization replaces the model it belongs to).
    TYPE(CD_C_Handle), POINTER, INTENT(INOUT) :: h
    INTEGER :: es
    CHARACTER(CD_C_MSG_LEN) :: em
    IF (ALLOCATED(h%saved_agg)) THEN
      CALL CD_AGG_End(h%saved_agg, es, em)
      DEALLOCATE (h%saved_agg)
    END IF
    CALL CD_FAST_End(h%saved_fast, es, em)
    h%saved_agg_t = CD_ZERO
    IF (ALLOCATED(h%saved_dcm)) DEALLOCATE (h%saved_dcm, h%saved_om, h%saved_al)
    h%has_saved = .FALSE.
  END SUBROUTINE drop_saved_state

  SUBROUTINE drop_point_current(h)
    !! Forget the point route's deck current (a model built from raw lines or on the aggregate
    !! has none of its own).
    TYPE(CD_C_Handle), POINTER, INTENT(INOUT) :: h
    TYPE(CD_DeckCurrentRuntimeType) :: none
    h%pt_current = none
  END SUBROUTINE drop_point_current

  SUBROUTINE drop_aggregate(h)
    !! Release the aggregate route of a handle (another initialization replaces it).
    TYPE(CD_C_Handle), POINTER, INTENT(INOUT) :: h
    INTEGER :: es
    CHARACTER(CD_C_MSG_LEN) :: em
    IF (h%use_agg .OR. CD_AGG_IsInitialized(h%agg)) CALL CD_AGG_End(h%agg, es, em)
    h%use_agg = .FALSE.
    h%agg_dt = CD_ZERO
    h%agg_t = CD_ZERO
    IF (ALLOCATED(h%agg_pos)) DEALLOCATE (h%agg_pos, h%agg_vel, h%agg_acc, h%agg_load)
    IF (ALLOCATED(h%agg_dcm)) DEALLOCATE (h%agg_dcm, h%agg_om, h%agg_al, h%agg_moment)
    h%host_rot = .FALSE.
    h%agg_host_fluid = .FALSE.
    h%fluid_ready = .FALSE.
  END SUBROUTINE drop_aggregate

  SUBROUTINE map_agg_status(agg_stat, err_stat)
    INTEGER, INTENT(IN) :: agg_stat
    INTEGER(C_INT), INTENT(OUT) :: err_stat
    SELECT CASE (agg_stat)
    CASE (CD_AGG_OK)
      err_stat = CD_C_OK
    CASE (CD_AGG_BADINPUT)
      err_stat = CD_C_BAD_INPUT
    CASE (CD_AGG_NOT_INITIALIZED)
      err_stat = CD_C_NOT_INITIALIZED
    CASE (CD_AGG_ALLOCFAIL)
      err_stat = CD_C_ALLOC_FAIL
    CASE DEFAULT
      err_stat = CD_C_SOLVE_FAIL
    END SELECT
  END SUBROUTINE map_agg_status

  SUBROUTINE CableDyn_InitLine(handle, n_nodes, n_elem, q0_ptr, v0_ptr, elem_conn_ptr, l0_ptr, ea_ptr, rho_a_ptr, &
                               fixed_dofs_ptr, n_fixed, tension_only, rho_inf, err_stat) &
    BIND(C, NAME='CableDyn_InitLine')
    !! Initialize the handle from one already-meshed EI=0 line. Connectivity and
    !! fixed DOFs use CableDyn's 1-based Fortran numbering convention. Serialised
    !! process-wide with the other initialisation calls.
    TYPE(C_PTR), VALUE :: handle, q0_ptr, v0_ptr, elem_conn_ptr, l0_ptr, ea_ptr, rho_a_ptr, fixed_dofs_ptr
    INTEGER(C_INT), VALUE :: n_nodes, n_elem, n_fixed, tension_only
    REAL(C_DOUBLE), VALUE :: rho_inf
    INTEGER(C_INT), INTENT(OUT) :: err_stat

    IF (blas_runtime_ready(handle, 'CableDyn_InitLine', err_stat)) THEN
      CALL cabledyn_input_lock()
      CALL init_line_serialised(handle, n_nodes, n_elem, q0_ptr, v0_ptr, elem_conn_ptr, l0_ptr, ea_ptr, rho_a_ptr, &
                                fixed_dofs_ptr, n_fixed, tension_only, rho_inf, err_stat)
      CALL cabledyn_input_unlock()
    END IF
    CALL drop_point_save_on_failure(handle, err_stat)
  END SUBROUTINE CableDyn_InitLine

  SUBROUTINE drop_point_save_on_failure(handle, err_stat)
    !! After a failed CableDyn_InitLine/InitLines the save slot follows the live model. These
    !! calls rebuild the point system in place, so a handle whose live model is that point
    !! system must be initialized again and loses the state saved for it. On a handle whose live
    !! model is an aggregate (a deck with finite-EI lines, bodies or rods), the failure leaves
    !! the aggregate live (use_agg is cleared only on success) and the save with it.
    TYPE(C_PTR), VALUE :: handle
    INTEGER(C_INT), INTENT(IN) :: err_stat
    TYPE(CD_C_Handle), POINTER :: h
    IF (err_stat == CD_C_OK) RETURN
    IF (validate_handle(handle, h) /= CD_C_OK) RETURN
    IF (.NOT. h%use_agg) CALL drop_saved_state(h)
  END SUBROUTINE drop_point_save_on_failure

  SUBROUTINE init_line_serialised(handle, n_nodes, n_elem, q0_ptr, v0_ptr, elem_conn_ptr, l0_ptr, ea_ptr, &
                                  rho_a_ptr, fixed_dofs_ptr, n_fixed, tension_only, rho_inf, err_stat)
    !! CableDyn_InitLine body; the caller holds the process-wide input lock.
    TYPE(C_PTR), VALUE :: handle, q0_ptr, v0_ptr, elem_conn_ptr, l0_ptr, ea_ptr, rho_a_ptr, fixed_dofs_ptr
    INTEGER(C_INT), VALUE :: n_nodes, n_elem, n_fixed, tension_only
    REAL(C_DOUBLE), VALUE :: rho_inf
    INTEGER(C_INT), INTENT(OUT) :: err_stat

    TYPE(CD_C_Handle), POINTER :: h
    TYPE(CD_ModelType) :: model
    TYPE(GenAlphaConfig) :: cfg
    REAL(C_DOUBLE), POINTER :: q0_c(:), v0_c(:), l0_c(:), ea_c(:), rho_a_c(:)
    INTEGER(C_INT), POINTER :: elem_c(:), fixed_c(:)
    REAL(wp), ALLOCATABLE :: q0(:), v0(:), l0(:), ea(:), rho_a(:), f_ext(:)
    INTEGER, ALLOCATABLE :: elem_conn(:, :), fixed_dofs(:)
    INTEGER :: i, es, end_es, stat
    INTEGER(INT64) :: n_nodes_wide, n_elem_wide, n_fixed_wide, int_huge
    CHARACTER(CD_C_MSG_LEN) :: em, fast_em

    err_stat = validate_handle(handle, h)
    IF (err_stat /= CD_C_OK) RETURN
    h%init_notes = ''
    IF (n_nodes < 2_C_INT .OR. n_elem < 1_C_INT .OR. n_fixed < 0_C_INT) THEN
      CALL set_status(h, CD_C_BAD_INPUT, 'CableDyn_InitLine: invalid node, element, or fixed-DOF count', err_stat)
      RETURN
    END IF
    n_nodes_wide = INT(n_nodes, INT64)
    n_elem_wide = INT(n_elem, INT64)
    n_fixed_wide = INT(n_fixed, INT64)
    int_huge = INT(HUGE(i), INT64)
    IF (3_INT64*n_nodes_wide > int_huge .OR. 2_INT64*n_elem_wide > int_huge .OR. &
        n_fixed_wide > int_huge) THEN
      CALL set_status(h, CD_C_BAD_INPUT, 'CableDyn_InitLine: input sizes exceed supported Fortran array bounds', &
                      err_stat)
      RETURN
    END IF
    IF (.NOT. (C_ASSOCIATED(q0_ptr) .AND. C_ASSOCIATED(v0_ptr) .AND. C_ASSOCIATED(elem_conn_ptr) .AND. &
               C_ASSOCIATED(l0_ptr) .AND. C_ASSOCIATED(ea_ptr) .AND. C_ASSOCIATED(rho_a_ptr))) THEN
      CALL set_status(h, CD_C_BAD_INPUT, 'CableDyn_InitLine: required input pointer is null', err_stat)
      RETURN
    END IF
    IF (n_fixed > 0_C_INT .AND. .NOT. C_ASSOCIATED(fixed_dofs_ptr)) THEN
      CALL set_status(h, CD_C_BAD_INPUT, 'CableDyn_InitLine: fixed_dofs pointer is null with n_fixed > 0', err_stat)
      RETURN
    END IF

    CALL C_F_POINTER(q0_ptr, q0_c, [3*INT(n_nodes)])
    CALL C_F_POINTER(v0_ptr, v0_c, [3*INT(n_nodes)])
    CALL C_F_POINTER(elem_conn_ptr, elem_c, [2*INT(n_elem)])
    CALL C_F_POINTER(l0_ptr, l0_c, [INT(n_elem)])
    CALL C_F_POINTER(ea_ptr, ea_c, [INT(n_elem)])
    CALL C_F_POINTER(rho_a_ptr, rho_a_c, [INT(n_elem)])
    IF (n_fixed > 0_C_INT) CALL C_F_POINTER(fixed_dofs_ptr, fixed_c, [INT(n_fixed)])

    ALLOCATE (q0(3*INT(n_nodes)), v0(3*INT(n_nodes)), f_ext(3*INT(n_nodes)), &
              elem_conn(2, INT(n_elem)), l0(INT(n_elem)), ea(INT(n_elem)), rho_a(INT(n_elem)), &
              fixed_dofs(INT(n_fixed)), STAT=stat)
    IF (stat /= 0) THEN
      CALL set_status(h, CD_C_ALLOC_FAIL, 'CableDyn_InitLine: temporary input allocation failed', err_stat)
      RETURN
    END IF
    q0 = REAL(q0_c, wp)
    v0 = REAL(v0_c, wp)
    l0 = REAL(l0_c, wp)
    ea = REAL(ea_c, wp)
    rho_a = REAL(rho_a_c, wp)
    f_ext = CD_ZERO
    DO i = 1, INT(n_elem)
      elem_conn(:, i) = INT(elem_c(2*i - 1:2*i))
    END DO
    IF (n_fixed > 0_C_INT) fixed_dofs = INT(fixed_c)
    IF (.NOT. (rho_inf >= 0.0_C_DOUBLE .AND. rho_inf <= 1.0_C_DOUBLE)) THEN
      CALL set_status(h, CD_C_BAD_INPUT, 'CableDyn_InitLine: rho_inf must lie in [0, 1]', err_stat)
      RETURN
    END IF
    cfg%rho_inf = REAL(rho_inf, wp)

    CALL CD_Init_Model(model, q0, v0, elem_conn, l0, ea, rho_a, tension_only /= 0_C_INT, f_ext, fixed_dofs, &
                       cfg, es, em)
    IF (es /= CD_MODEL_OK) THEN
      CALL set_model_init_failure(h, 'CableDyn_InitLine', es, em, err_stat)
      CALL CD_End_Model(model, es, em)
      RETURN
    END IF
    CALL drop_point_current(h)
    CALL CD_FAST_Init_From_Models(h%fast, [model], es, fast_em)
    CALL CD_End_Model(model, end_es, em)
    CALL map_fast_status(es, err_stat)
    IF (err_stat == CD_C_OK) THEN
      CALL drop_aggregate(h)
      CALL drop_saved_state(h)
      CALL set_point_line_map(h, [1])
      CALL store_status(h, err_stat, '')
    ELSE
      CALL store_status(h, err_stat, 'CableDyn_InitLine: '//TRIM(fast_em))
    END IF
  END SUBROUTINE init_line_serialised

  SUBROUTINE CableDyn_InitLines(handle, n_lines, n_nodes_ptr, n_elem_ptr, n_fixed_ptr, q0_ptr, v0_ptr, &
                                elem_conn_ptr, l0_ptr, ea_ptr, rho_a_ptr, fixed_dofs_ptr, &
                                coupled_map_ptr, n_coupled_map, tension_only, rho_inf, err_stat) &
    BIND(C, NAME='CableDyn_InitLines')
    !! Initialize from multiple already-meshed EI=0 lines. Per-line arrays are
    !! concatenated in line order. Connectivity and fixed DOFs are local to each
    !! line and use 1-based Fortran numbering. `coupled_map_ptr` may be null when
    !! `n_coupled_map == 0`, in which case the local coupled DOFs are not shared.
    !! Serialised process-wide with the other initialisation calls.
    TYPE(C_PTR), VALUE :: handle, n_nodes_ptr, n_elem_ptr, n_fixed_ptr, q0_ptr, v0_ptr
    TYPE(C_PTR), VALUE :: elem_conn_ptr, l0_ptr, ea_ptr, rho_a_ptr, fixed_dofs_ptr, coupled_map_ptr
    INTEGER(C_INT), VALUE :: n_lines, n_coupled_map, tension_only
    REAL(C_DOUBLE), VALUE :: rho_inf
    INTEGER(C_INT), INTENT(OUT) :: err_stat

    IF (blas_runtime_ready(handle, 'CableDyn_InitLines', err_stat)) THEN
      CALL cabledyn_input_lock()
      CALL init_lines_serialised(handle, n_lines, n_nodes_ptr, n_elem_ptr, n_fixed_ptr, q0_ptr, v0_ptr, &
                                 elem_conn_ptr, l0_ptr, ea_ptr, rho_a_ptr, fixed_dofs_ptr, &
                                 coupled_map_ptr, n_coupled_map, tension_only, rho_inf, err_stat)
      CALL cabledyn_input_unlock()
    END IF
    CALL drop_point_save_on_failure(handle, err_stat)
  END SUBROUTINE CableDyn_InitLines

  SUBROUTINE init_lines_serialised(handle, n_lines, n_nodes_ptr, n_elem_ptr, n_fixed_ptr, q0_ptr, v0_ptr, &
                                   elem_conn_ptr, l0_ptr, ea_ptr, rho_a_ptr, fixed_dofs_ptr, &
                                   coupled_map_ptr, n_coupled_map, tension_only, rho_inf, err_stat)
    !! CableDyn_InitLines body; the caller holds the process-wide input lock.
    TYPE(C_PTR), VALUE :: handle, n_nodes_ptr, n_elem_ptr, n_fixed_ptr, q0_ptr, v0_ptr
    TYPE(C_PTR), VALUE :: elem_conn_ptr, l0_ptr, ea_ptr, rho_a_ptr, fixed_dofs_ptr, coupled_map_ptr
    INTEGER(C_INT), VALUE :: n_lines, n_coupled_map, tension_only
    REAL(C_DOUBLE), VALUE :: rho_inf
    INTEGER(C_INT), INTENT(OUT) :: err_stat

    TYPE(CD_C_Handle), POINTER :: h
    INTEGER(C_INT), POINTER :: n_nodes_c(:), n_elem_c(:), n_fixed_c(:), elem_c(:), fixed_c(:), map_c(:)
    INTEGER(C_INT), ALLOCATABLE :: empty_fixed(:)
    REAL(C_DOUBLE), POINTER :: q0_c(:), v0_c(:), l0_c(:), ea_c(:), rho_a_c(:)
    TYPE(CD_ModelType), ALLOCATABLE :: models(:)
    TYPE(GenAlphaConfig) :: cfg
    INTEGER, ALLOCATABLE :: coupled_map(:)
    INTEGER :: i, es, stat, total_nodes, total_elem, total_fixed
    INTEGER :: dof_lo, dof_hi, elem_lo, elem_hi, elem_pair_lo, elem_pair_hi, fixed_lo, fixed_hi
    INTEGER(INT64) :: total_nodes_wide, total_elem_wide, total_fixed_wide
    INTEGER(INT64) :: max_nodes_wide, max_elem_wide, max_fixed_wide
    INTEGER(INT64) :: dof_off, elem_off, fixed_off, local_nodes, local_elem, local_fixed, local_dof
    INTEGER(INT64) :: dof_stop, elem_stop, elem_pair_stop, fixed_stop, int_huge
    CHARACTER(CD_C_MSG_LEN) :: em

    NULLIFY (fixed_c, map_c)
    err_stat = validate_handle(handle, h)
    IF (err_stat /= CD_C_OK) RETURN
    h%init_notes = ''
    IF (n_lines < 1_C_INT .OR. .NOT. (C_ASSOCIATED(n_nodes_ptr) .AND. C_ASSOCIATED(n_elem_ptr) .AND. &
                                      C_ASSOCIATED(n_fixed_ptr))) THEN
      CALL set_status(h, CD_C_BAD_INPUT, 'CableDyn_InitLines: invalid line count or null count pointer', err_stat)
      RETURN
    END IF
    CALL C_F_POINTER(n_nodes_ptr, n_nodes_c, [INT(n_lines)])
    CALL C_F_POINTER(n_elem_ptr, n_elem_c, [INT(n_lines)])
    CALL C_F_POINTER(n_fixed_ptr, n_fixed_c, [INT(n_lines)])
    IF (ANY(n_nodes_c < 2_C_INT) .OR. ANY(n_elem_c < 1_C_INT) .OR. ANY(n_fixed_c < 0_C_INT)) THEN
      CALL set_status(h, CD_C_BAD_INPUT, 'CableDyn_InitLines: invalid per-line node, element, or fixed-DOF count', &
                      err_stat)
      RETURN
    END IF
    total_nodes_wide = SUM(INT(n_nodes_c, INT64))
    total_elem_wide = SUM(INT(n_elem_c, INT64))
    total_fixed_wide = SUM(INT(n_fixed_c, INT64))
    int_huge = INT(HUGE(total_nodes), INT64)
    max_nodes_wide = int_huge/3_INT64
    max_elem_wide = int_huge/2_INT64
    max_fixed_wide = int_huge
    IF (total_nodes_wide > max_nodes_wide .OR. total_elem_wide > max_elem_wide .OR. &
        total_fixed_wide > max_fixed_wide) THEN
      CALL set_status(h, CD_C_BAD_INPUT, 'CableDyn_InitLines: aggregate input sizes exceed supported bounds', &
                      err_stat)
      RETURN
    END IF
    total_nodes = INT(total_nodes_wide)
    total_elem = INT(total_elem_wide)
    total_fixed = INT(total_fixed_wide)
    IF (.NOT. (C_ASSOCIATED(q0_ptr) .AND. C_ASSOCIATED(v0_ptr) .AND. C_ASSOCIATED(elem_conn_ptr) .AND. &
               C_ASSOCIATED(l0_ptr) .AND. C_ASSOCIATED(ea_ptr) .AND. C_ASSOCIATED(rho_a_ptr))) THEN
      CALL set_status(h, CD_C_BAD_INPUT, 'CableDyn_InitLines: required input pointer is null', err_stat)
      RETURN
    END IF
    IF (total_fixed > 0 .AND. .NOT. C_ASSOCIATED(fixed_dofs_ptr)) THEN
      CALL set_status(h, CD_C_BAD_INPUT, 'CableDyn_InitLines: fixed_dofs pointer is null with fixed DOFs present', &
                      err_stat)
      RETURN
    END IF
    CALL C_F_POINTER(q0_ptr, q0_c, [3*total_nodes])
    CALL C_F_POINTER(v0_ptr, v0_c, [3*total_nodes])
    CALL C_F_POINTER(elem_conn_ptr, elem_c, [2*total_elem])
    CALL C_F_POINTER(l0_ptr, l0_c, [total_elem])
    CALL C_F_POINTER(ea_ptr, ea_c, [total_elem])
    CALL C_F_POINTER(rho_a_ptr, rho_a_c, [total_elem])
    IF (total_fixed > 0) CALL C_F_POINTER(fixed_dofs_ptr, fixed_c, [total_fixed])
    IF (n_coupled_map < 0_C_INT) THEN
      CALL set_status(h, CD_C_BAD_INPUT, 'CableDyn_InitLines: n_coupled_map must be non-negative', err_stat)
      RETURN
    END IF
    IF (n_coupled_map > 0_C_INT) THEN
      IF (.NOT. C_ASSOCIATED(coupled_map_ptr) .OR. &
          INT(n_coupled_map, INT64) /= 6_INT64*INT(n_lines, INT64)) THEN
        CALL set_status(h, CD_C_BAD_INPUT, &
                        'CableDyn_InitLines: coupled_map must have 6 entries per line when supplied', err_stat)
        RETURN
      END IF
      IF (ANY(n_fixed_c /= 6_C_INT)) THEN
        CALL set_status(h, CD_C_BAD_INPUT, &
                        'CableDyn_InitLines: shared coupled map requires six fixed DOFs per line', err_stat)
        RETURN
      END IF
      CALL C_F_POINTER(coupled_map_ptr, map_c, [INT(n_coupled_map)])
      ALLOCATE (coupled_map(INT(n_coupled_map)), STAT=stat)
      IF (stat /= 0) THEN
        CALL set_status(h, CD_C_ALLOC_FAIL, 'CableDyn_InitLines: coupled map allocation failed', err_stat)
        RETURN
      END IF
      coupled_map = INT(map_c)
    END IF

    ALLOCATE (models(INT(n_lines)), empty_fixed(0), STAT=stat)
    IF (stat /= 0) THEN
      CALL set_status(h, CD_C_ALLOC_FAIL, 'CableDyn_InitLines: model workspace allocation failed', err_stat)
      RETURN
    END IF
    IF (.NOT. (rho_inf >= 0.0_C_DOUBLE .AND. rho_inf <= 1.0_C_DOUBLE)) THEN
      CALL set_status(h, CD_C_BAD_INPUT, 'CableDyn_InitLines: rho_inf must lie in [0, 1]', err_stat)
      RETURN
    END IF
    cfg%rho_inf = REAL(rho_inf, wp)
    dof_off = 0_INT64
    elem_off = 0_INT64
    fixed_off = 0_INT64
    DO i = 1, INT(n_lines)
      local_nodes = INT(n_nodes_c(i), INT64)
      local_elem = INT(n_elem_c(i), INT64)
      local_fixed = INT(n_fixed_c(i), INT64)
      local_dof = 3_INT64*local_nodes
      dof_stop = dof_off + local_dof
      elem_stop = elem_off + local_elem
      elem_pair_stop = 2_INT64*elem_stop
      fixed_stop = fixed_off + local_fixed
      IF (dof_stop > int_huge .OR. elem_stop > int_huge .OR. elem_pair_stop > int_huge .OR. &
          fixed_stop > int_huge) THEN
        CALL set_status(h, CD_C_BAD_INPUT, 'CableDyn_InitLines: per-line slice exceeds supported bounds', err_stat)
        CALL end_temp_models(models)
        RETURN
      END IF
      dof_lo = INT(dof_off + 1_INT64)
      dof_hi = INT(dof_stop)
      elem_lo = INT(elem_off + 1_INT64)
      elem_hi = INT(elem_stop)
      elem_pair_lo = INT(2_INT64*elem_off + 1_INT64)
      elem_pair_hi = INT(elem_pair_stop)
      fixed_lo = INT(fixed_off + 1_INT64)
      fixed_hi = INT(fixed_stop)
      IF (n_fixed_c(i) > 0_C_INT) THEN
        CALL init_one_raw_model(models(i), q0_c(dof_lo:dof_hi), v0_c(dof_lo:dof_hi), &
                                elem_c(elem_pair_lo:elem_pair_hi), &
                                l0_c(elem_lo:elem_hi), ea_c(elem_lo:elem_hi), rho_a_c(elem_lo:elem_hi), &
                                fixed_c(fixed_lo:fixed_hi), &
                                tension_only /= 0_C_INT, cfg, es, em)
      ELSE
        CALL init_one_raw_model(models(i), q0_c(dof_lo:dof_hi), v0_c(dof_lo:dof_hi), &
                                elem_c(elem_pair_lo:elem_pair_hi), &
                                l0_c(elem_lo:elem_hi), ea_c(elem_lo:elem_hi), rho_a_c(elem_lo:elem_hi), &
                                empty_fixed, tension_only /= 0_C_INT, cfg, es, em)
      END IF
      IF (es /= CD_MODEL_OK) THEN
        CALL set_model_init_failure(h, 'CableDyn_InitLines', es, em, err_stat)
        CALL end_temp_models(models)
        RETURN
      END IF
      dof_off = dof_stop
      elem_off = elem_stop
      fixed_off = fixed_stop
    END DO
    CALL drop_point_current(h)
    IF (ALLOCATED(coupled_map)) THEN
      CALL CD_FAST_Init_From_Models(h%fast, models, es, em, coupled_dof_map=coupled_map)
    ELSE
      CALL CD_FAST_Init_From_Models(h%fast, models, es, em)
    END IF
    CALL end_temp_models(models)
    CALL map_fast_status(es, err_stat)
    IF (err_stat == CD_C_OK) THEN
      CALL drop_aggregate(h)
      CALL drop_saved_state(h)
      CALL set_point_line_map(h, [(i, i=1, INT(n_lines))])
      CALL store_status(h, err_stat, '')
    ELSE
      CALL store_status(h, err_stat, 'CableDyn_InitLines: '//TRIM(em))
    END IF
  END SUBROUTINE init_lines_serialised

  SUBROUTINE CableDyn_UpdateStates(handle, q_ptr, v_ptr, a_ptr, n_coupled_dof, err_stat) &
    BIND(C, NAME='CableDyn_UpdateStates')
    !! Update coupled kinematics without advancing time.
    TYPE(C_PTR), VALUE :: handle, q_ptr, v_ptr, a_ptr
    INTEGER(C_INT), VALUE :: n_coupled_dof
    INTEGER(C_INT), INTENT(OUT) :: err_stat
    TYPE(CD_C_Handle), POINTER :: h
    REAL(C_DOUBLE), POINTER :: q_c(:), v_c(:), a_c(:)
    INTEGER :: es
    CHARACTER(CD_C_MSG_LEN) :: em

    CALL coupled_inputs(handle, q_ptr, v_ptr, a_ptr, n_coupled_dof, h, q_c, v_c, a_c, err_stat)
    IF (err_stat /= CD_C_OK) RETURN
    IF (h%use_agg) THEN
      IF (n_coupled_dof > 0_C_INT) THEN
        h%agg_pos = RESHAPE(REAL(q_c, wp), SHAPE(h%agg_pos))
        h%agg_vel = RESHAPE(REAL(v_c, wp), SHAPE(h%agg_vel))
        h%agg_acc = RESHAPE(REAL(a_c, wp), SHAPE(h%agg_acc))
      END IF
      IF (h%host_rot) THEN
        CALL CD_AGG_UpdateStates_Moving(h%agg, h%agg_pos, h%agg_vel, h%agg_acc, es, em, orientation=h%agg_dcm, &
                                        angular_velocity=h%agg_om, angular_acceleration=h%agg_al)
      ELSE
        CALL CD_AGG_UpdateStates_Moving(h%agg, h%agg_pos, h%agg_vel, h%agg_acc, es, em)
      END IF
      CALL map_agg_status(es, err_stat)
      CALL store_status(h, err_stat, em)
      RETURN
    END IF
    CALL ensure_c_vector_workspace(h, INT(n_coupled_dof), need_load=.FALSE., err_stat=err_stat)
    IF (err_stat /= CD_C_OK) RETURN
    IF (n_coupled_dof > 0_C_INT) THEN
      h%q_work(1:INT(n_coupled_dof)) = REAL(q_c, wp)
      h%v_work(1:INT(n_coupled_dof)) = REAL(v_c, wp)
      h%a_work(1:INT(n_coupled_dof)) = REAL(a_c, wp)
    END IF
    CALL CD_FAST_UpdateStates(h%fast, h%q_work(1:INT(n_coupled_dof)), h%v_work(1:INT(n_coupled_dof)), &
                              h%a_work(1:INT(n_coupled_dof)), es, em)
    CALL map_fast_status(es, err_stat)
    CALL store_status(h, err_stat, em)
  END SUBROUTINE CableDyn_UpdateStates

  SUBROUTINE CableDyn_UpdatePointFluidFields(handle, fluid_velocity_ptr, fluid_acceleration_ptr, waterline_z_ptr, &
                                             n_point, fluid_density, err_stat) &
    BIND(C, NAME='CableDyn_UpdatePointFluidFields')
    !! Update externally supplied lumped point-fluid kinematics on a point-initialized handle.
    TYPE(C_PTR), VALUE :: handle, fluid_velocity_ptr, fluid_acceleration_ptr, waterline_z_ptr
    INTEGER(C_INT), VALUE :: n_point
    REAL(C_DOUBLE), VALUE :: fluid_density
    INTEGER(C_INT), INTENT(OUT) :: err_stat

    TYPE(CD_C_Handle), POINTER :: h
    REAL(C_DOUBLE), POINTER :: fluid_velocity_c(:), fluid_acceleration_c(:), waterline_z_c(:)
    INTEGER :: es, expected_point, p
    CHARACTER(CD_C_MSG_LEN) :: em

    err_stat = validate_handle(handle, h)
    IF (err_stat /= CD_C_OK) RETURN
    IF (h%use_agg) THEN
      CALL set_status(h, CD_C_BAD_INPUT, 'CableDyn_UpdatePointFluidFields: a deck with finite-EI lines, BODIES or '// &
                      'RODS runs on the coupled aggregate, which takes no point fluid fields; supply the '// &
                      'fluid at its nodes with CableDyn_SetHostFluid and CableDyn_UpdateFluidFields', err_stat)
      RETURN
    END IF
    IF (n_point < 0_C_INT) THEN
      CALL set_status(h, CD_C_BAD_INPUT, &
                      'CableDyn_UpdatePointFluidFields: point count must be non-negative', err_stat)
      RETURN
    END IF
    ! Size the fluid-field update by the stored point count, not the coupled-DOF count: a deck
    ! with unbound (output-only) Fixed/Coupled points has fewer coupled DOFs than stored points,
    ! and the system point fluid-field update requires one column per stored point.
    expected_point = CD_FAST_NPoints(h%fast, es, em)
    IF (es /= CD_FAST_OK) THEN
      CALL map_fast_status(es, err_stat)
      CALL store_status(h, err_stat, em)
      RETURN
    END IF
    IF (INT(n_point) /= expected_point) THEN
      CALL set_status(h, CD_C_BAD_INPUT, &
                      'CableDyn_UpdatePointFluidFields: point count does not match the system point count', err_stat)
      RETURN
    END IF
    IF (n_point > 0_C_INT .AND. &
        .NOT. (C_ASSOCIATED(fluid_velocity_ptr) .AND. C_ASSOCIATED(fluid_acceleration_ptr) .AND. &
               C_ASSOCIATED(waterline_z_ptr))) THEN
      CALL set_status(h, CD_C_BAD_INPUT, 'CableDyn_UpdatePointFluidFields: input pointer is null', err_stat)
      RETURN
    END IF

    CALL ensure_c_fluid_workspace(h, expected_point, err_stat)
    IF (err_stat /= CD_C_OK) RETURN
    IF (expected_point > 0) THEN
      CALL C_F_POINTER(fluid_velocity_ptr, fluid_velocity_c, [3*expected_point])
      CALL C_F_POINTER(fluid_acceleration_ptr, fluid_acceleration_c, [3*expected_point])
      CALL C_F_POINTER(waterline_z_ptr, waterline_z_c, [expected_point])
      DO p = 1, expected_point
        h%fluid_velocity_work(:, p) = REAL(fluid_velocity_c(3*p - 2:3*p), wp)
        h%fluid_acceleration_work(:, p) = REAL(fluid_acceleration_c(3*p - 2:3*p), wp)
      END DO
      h%waterline_work(1:expected_point) = REAL(waterline_z_c, wp)
    END IF
    CALL CD_FAST_UpdatePointFluidFields(h%fast, h%fluid_velocity_work(:, 1:expected_point), &
                                        h%fluid_acceleration_work(:, 1:expected_point), &
                                        h%waterline_work(1:expected_point), &
                                        REAL(fluid_density, wp), es, em)
    CALL map_fast_status(es, err_stat)
    CALL store_status(h, err_stat, em)
  END SUBROUTINE CableDyn_UpdatePointFluidFields

  SUBROUTINE CableDyn_SetHostFluid(handle, enable, err_stat) BIND(C, NAME='CableDyn_SetHostFluid')
    !! Choose, before a deck initialization, whether the host supplies the ambient fluid
    !! (nonzero) or the deck does (0, the default). It applies to every following CableDyn_InitDeck,
    !! CableDyn_InitDeckAt and CableDyn_InitDeckRotating of the handle. With it, the deck runs on
    !! the coupled aggregate whatever its lines; its waves are refused, a steady deck current sets
    !! the static start only, and CableDyn_UpdateFluidFields supplies the whole field of the march.
    TYPE(C_PTR), VALUE :: handle
    INTEGER(C_INT), VALUE :: enable
    INTEGER(C_INT), INTENT(OUT) :: err_stat
    TYPE(CD_C_Handle), POINTER :: h

    err_stat = validate_handle(handle, h)
    IF (err_stat /= CD_C_OK) RETURN
    h%host_fluid = enable /= 0_C_INT
    CALL store_status(h, CD_C_OK, '')
  END SUBROUTINE CableDyn_SetHostFluid

  FUNCTION CableDyn_NFluidNodes(handle, err_stat) RESULT(n) BIND(C, NAME='CableDyn_NFluidNodes')
    !! The number of nodes at which the host supplies the fluid field (every line node, then the
    !! bodies, rods and hydrodynamic points of the deck), or zero for a null or uninitialized
    !! handle and for a handle without a host fluid field.
    TYPE(C_PTR), VALUE :: handle
    INTEGER(C_INT), INTENT(OUT) :: err_stat
    INTEGER(C_INT) :: n
    TYPE(CD_C_Handle), POINTER :: h
    INTEGER :: es
    CHARACTER(CD_C_MSG_LEN) :: em

    n = 0_C_INT
    IF (.NOT. query_ready(handle, h, 'CableDyn_NFluidNodes', err_stat)) RETURN
    IF (h%agg_host_fluid) THEN
      n = INT(CD_AGG_NFluidNodes(h%agg, es, em), C_INT)
      CALL map_agg_status(es, err_stat)
      CALL store_status(h, err_stat, em)
    ELSE
      CALL store_status(h, CD_C_OK, '')
    END IF
  END FUNCTION CableDyn_NFluidNodes

  SUBROUTINE CableDyn_GetFluidNodePositions(handle, xyz_ptr, n_node, err_stat) &
    BIND(C, NAME='CableDyn_GetFluidNodePositions')
    !! The committed position of every fluid node (x, y, z triples, global axes): where the host
    !! evaluates the field of the coming step.
    TYPE(C_PTR), VALUE :: handle, xyz_ptr
    INTEGER(C_INT), VALUE :: n_node
    INTEGER(C_INT), INTENT(OUT) :: err_stat
    TYPE(CD_C_Handle), POINTER :: h
    REAL(C_DOUBLE), POINTER :: xyz_c(:)
    INTEGER :: es, n, p
    CHARACTER(CD_C_MSG_LEN) :: em

    IF (.NOT. host_fluid_call(handle, h, 'CableDyn_GetFluidNodePositions', n_node, n, err_stat)) RETURN
    IF (n == 0) THEN
      CALL store_status(h, CD_C_OK, '')
      RETURN
    END IF
    IF (.NOT. C_ASSOCIATED(xyz_ptr)) THEN
      CALL set_status(h, CD_C_BAD_INPUT, 'CableDyn_GetFluidNodePositions: output pointer is null', err_stat)
      RETURN
    END IF
    CALL ensure_c_fluid_workspace(h, n, err_stat)
    IF (err_stat /= CD_C_OK) RETURN
    CALL CD_AGG_GetFluidNodePositions(h%agg, h%fluid_velocity_work(:, 1:n), es, em)
    CALL map_agg_status(es, err_stat)
    CALL store_status(h, err_stat, em)
    IF (err_stat /= CD_C_OK) RETURN
    CALL C_F_POINTER(xyz_ptr, xyz_c, [3*n])
    DO p = 1, n
      xyz_c(3*p - 2:3*p) = REAL(h%fluid_velocity_work(:, p), C_DOUBLE)
    END DO
  END SUBROUTINE CableDyn_GetFluidNodePositions

  SUBROUTINE CableDyn_UpdateFluidFields(handle, fluid_velocity_ptr, fluid_acceleration_ptr, waterline_z_ptr, &
                                        dynamic_pressure_ptr, n_node, err_stat) &
    BIND(C, NAME='CableDyn_UpdateFluidFields')
    !! The ambient fluid at every fluid node (CableDyn_GetFluidNodePositions), held until the next
    !! call: velocity and acceleration as x, y, z triples in global axes, the free-surface
    !! elevation, and the wave dynamic pressure (may be NULL; rods use it for their end caps).
    !! The first call, before the first step, is the field at t = 0 and sets the start
    !! acceleration; later calls are the field of the coming step, the field at t + dt at the
    !! step-start positions. The density is the deck's.
    TYPE(C_PTR), VALUE :: handle, fluid_velocity_ptr, fluid_acceleration_ptr, waterline_z_ptr
    TYPE(C_PTR), VALUE :: dynamic_pressure_ptr
    INTEGER(C_INT), VALUE :: n_node
    INTEGER(C_INT), INTENT(OUT) :: err_stat
    TYPE(CD_C_Handle), POINTER :: h
    REAL(C_DOUBLE), POINTER :: velocity_c(:), acceleration_c(:), waterline_c(:), pressure_c(:)
    INTEGER :: es, n, p
    CHARACTER(CD_C_MSG_LEN) :: em

    IF (.NOT. host_fluid_call(handle, h, 'CableDyn_UpdateFluidFields', n_node, n, err_stat)) RETURN
    IF (n > 0 .AND. .NOT. (C_ASSOCIATED(fluid_velocity_ptr) .AND. C_ASSOCIATED(fluid_acceleration_ptr) .AND. &
                           C_ASSOCIATED(waterline_z_ptr))) THEN
      CALL set_status(h, CD_C_BAD_INPUT, 'CableDyn_UpdateFluidFields: input pointer is null', err_stat)
      RETURN
    END IF
    CALL ensure_c_fluid_workspace(h, n, err_stat)
    IF (err_stat /= CD_C_OK) RETURN
    IF (n > 0) THEN
      CALL C_F_POINTER(fluid_velocity_ptr, velocity_c, [3*n])
      CALL C_F_POINTER(fluid_acceleration_ptr, acceleration_c, [3*n])
      CALL C_F_POINTER(waterline_z_ptr, waterline_c, [n])
      DO p = 1, n
        h%fluid_velocity_work(:, p) = REAL(velocity_c(3*p - 2:3*p), wp)
        h%fluid_acceleration_work(:, p) = REAL(acceleration_c(3*p - 2:3*p), wp)
      END DO
      h%waterline_work(1:n) = REAL(waterline_c, wp)
    END IF
    IF (n > 0 .AND. C_ASSOCIATED(dynamic_pressure_ptr)) THEN
      CALL C_F_POINTER(dynamic_pressure_ptr, pressure_c, [n])
      CALL CD_AGG_SetFluidFields(h%agg, h%fluid_velocity_work(:, 1:n), h%fluid_acceleration_work(:, 1:n), &
                                 h%waterline_work(1:n), es, em, dynamic_pressure=REAL(pressure_c, wp), &
                                 initial_condition=.NOT. h%fluid_ready)
    ELSE
      CALL CD_AGG_SetFluidFields(h%agg, h%fluid_velocity_work(:, 1:n), h%fluid_acceleration_work(:, 1:n), &
                                 h%waterline_work(1:n), es, em, initial_condition=.NOT. h%fluid_ready)
    END IF
    CALL map_agg_status(es, err_stat)
    CALL store_status(h, err_stat, em)
    IF (err_stat == CD_C_OK) h%fluid_ready = .TRUE.
  END SUBROUTINE CableDyn_UpdateFluidFields

  LOGICAL FUNCTION host_fluid_call(handle, h, caller, n_node, n, err_stat) RESULT(ready)
    !! Validate a host fluid call: an initialized model built for a host field, with n_node equal
    !! to the fluid node count n.
    TYPE(C_PTR), VALUE :: handle
    TYPE(CD_C_Handle), POINTER, INTENT(OUT) :: h
    CHARACTER(*), INTENT(IN) :: caller
    INTEGER(C_INT), INTENT(IN) :: n_node
    INTEGER, INTENT(OUT) :: n
    INTEGER(C_INT), INTENT(OUT) :: err_stat
    INTEGER :: es
    CHARACTER(CD_C_MSG_LEN) :: em

    ready = .FALSE.
    n = 0
    IF (.NOT. query_ready(handle, h, caller, err_stat)) RETURN
    IF (.NOT. h%agg_host_fluid) THEN
      CALL set_status(h, CD_C_BAD_INPUT, caller//': the model takes no host fluid field: call '// &
                      'CableDyn_SetHostFluid before its deck initialization', err_stat)
      RETURN
    END IF
    n = CD_AGG_NFluidNodes(h%agg, es, em)
    IF (es /= CD_AGG_OK) THEN
      CALL map_agg_status(es, err_stat)
      CALL store_status(h, err_stat, em)
      RETURN
    END IF
    IF (INT(n_node) /= n) THEN
      CALL set_status(h, CD_C_BAD_INPUT, caller//': node count does not match CableDyn_NFluidNodes', err_stat)
      RETURN
    END IF
    ready = .TRUE.
  END FUNCTION host_fluid_call

  SUBROUTINE CableDyn_Step(handle, dt, q_ptr, v_ptr, a_ptr, n_coupled_dof, converged, stalled, n_iter, err_stat) &
    BIND(C, NAME='CableDyn_Step')
    !! Advance one coupled time step.
    TYPE(C_PTR), VALUE :: handle, q_ptr, v_ptr, a_ptr
    REAL(C_DOUBLE), VALUE :: dt
    INTEGER(C_INT), VALUE :: n_coupled_dof
    LOGICAL(C_BOOL), INTENT(OUT) :: converged, stalled
    INTEGER(C_INT), INTENT(OUT) :: n_iter, err_stat
    TYPE(CD_C_Handle), POINTER :: h
    REAL(C_DOUBLE), POINTER :: q_c(:), v_c(:), a_c(:)
    LOGICAL :: conv_f, stall_f, sampled
    INTEGER :: es, nit
    CHARACTER(CD_C_MSG_LEN) :: em
    ! the point route's drag fields before the step's current sample, put back by a step that
    ! does not commit
    TYPE :: held_fluid
      REAL(wp), ALLOCATABLE :: velocity(:, :), waterline(:)
    END TYPE held_fluid
    TYPE(held_fluid), ALLOCATABLE :: held(:)

    converged = .FALSE._C_BOOL
    stalled = .FALSE._C_BOOL
    n_iter = 0_C_INT
    CALL coupled_inputs(handle, q_ptr, v_ptr, a_ptr, n_coupled_dof, h, q_c, v_c, a_c, err_stat)
    IF (err_stat /= CD_C_OK) RETURN
    ! a positive step too small to integrate (NaN, Inf and dt <= 0 are named by the route)
    IF (dt > 0.0_C_DOUBLE .AND. dt < REAL(CD_MIN_TIME_STEP, C_DOUBLE)) THEN
      CALL set_status(h, CD_C_BAD_INPUT, 'CableDyn_Step: dt is below the smallest time step, 1e-100 s: '// &
                      'the time integration divides by dt^2', err_stat)
      RETURN
    END IF
    IF (h%use_agg) THEN
      IF (h%agg_host_fluid .AND. .NOT. h%fluid_ready) THEN
        CALL set_status(h, CD_C_BAD_INPUT, 'CableDyn_Step: the model takes a host fluid field: call '// &
                        'CableDyn_UpdateFluidFields before the first step', err_stat)
        RETURN
      END IF
      IF (n_coupled_dof > 0_C_INT) THEN
        h%agg_pos = RESHAPE(REAL(q_c, wp), SHAPE(h%agg_pos))
        h%agg_vel = RESHAPE(REAL(v_c, wp), SHAPE(h%agg_vel))
        h%agg_acc = RESHAPE(REAL(a_c, wp), SHAPE(h%agg_acc))
      END IF
      IF (h%host_rot) THEN
        CALL CD_AGG_Step_Moving(h%agg, REAL(dt, wp), h%agg_pos, h%agg_vel, h%agg_acc, conv_f, stall_f, nit, es, &
                                em, t_committed=h%agg_t + REAL(dt, wp), orientation=h%agg_dcm, &
                                angular_velocity=h%agg_om, angular_acceleration=h%agg_al)
      ELSE
        CALL CD_AGG_Step_Moving(h%agg, REAL(dt, wp), h%agg_pos, h%agg_vel, h%agg_acc, conv_f, stall_f, nit, es, &
                                em, t_committed=h%agg_t + REAL(dt, wp))
      END IF
      IF (es == CD_AGG_OK) h%agg_t = h%agg_t + REAL(dt, wp)
      converged = LOGICAL(conv_f, C_BOOL)
      stalled = LOGICAL(stall_f, C_BOOL)
      n_iter = INT(nit, C_INT)
      CALL map_agg_status(es, err_stat)
      CALL store_status(h, err_stat, em)
      CALL clear_failed_step_flags()
      RETURN
    END IF
    CALL ensure_c_vector_workspace(h, INT(n_coupled_dof), need_load=.FALSE., err_stat=err_stat)
    IF (err_stat /= CD_C_OK) RETURN
    IF (n_coupled_dof > 0_C_INT) THEN
      h%q_work(1:INT(n_coupled_dof)) = REAL(q_c, wp)
      h%v_work(1:INT(n_coupled_dof)) = REAL(v_c, wp)
      h%a_work(1:INT(n_coupled_dof)) = REAL(a_c, wp)
    END IF
    ! the deck's steady current at the step-start node positions, held over the step; a step
    ! that does not commit (refused input or a hard failure) puts back the fields it replaced,
    ! so the model's loads are those before the call
    sampled = CD_Deck_Current_Active(h%pt_current)
    IF (sampled) THEN
      CALL hold_point_fluid()
      CALL CD_Deck_Current_Sample_System(h%pt_current, h%fast%system, CD_ZERO, es, em)
      IF (es /= CD_DECKDRV_OK) THEN
        CALL restore_point_fluid()
        CALL set_status(h, CD_C_SOLVE_FAIL, 'CableDyn_Step: '//TRIM(em), err_stat)
        RETURN
      END IF
    END IF
    CALL CD_FAST_Step(h%fast, REAL(dt, wp), h%q_work(1:INT(n_coupled_dof)), h%v_work(1:INT(n_coupled_dof)), &
                      h%a_work(1:INT(n_coupled_dof)), conv_f, stall_f, nit, es, em)
    IF (sampled .AND. es /= CD_FAST_OK) CALL restore_point_fluid()
    converged = LOGICAL(conv_f, C_BOOL)
    stalled = LOGICAL(stall_f, C_BOOL)
    n_iter = INT(nit, C_INT)
    CALL map_fast_status(es, err_stat)
    CALL store_status(h, err_stat, em)
    CALL clear_failed_step_flags()

  CONTAINS

    SUBROUTINE hold_point_fluid()
      !! Keep each line's drag fluid velocity and waterline.
      INTEGER :: il
      ALLOCATE (held(SIZE(h%fast%system%lines)))
      DO il = 1, SIZE(held)
        IF (ALLOCATED(h%fast%system%lines(il)%fluid_velocity)) &
          held(il)%velocity = h%fast%system%lines(il)%fluid_velocity
        IF (ALLOCATED(h%fast%system%lines(il)%drag_waterline_z)) &
          held(il)%waterline = h%fast%system%lines(il)%drag_waterline_z
      END DO
    END SUBROUTINE hold_point_fluid

    SUBROUTINE restore_point_fluid()
      !! Put back the fields hold_point_fluid kept (the values the model held, so they pass the
      !! setter's checks).
      INTEGER :: il, es_r
      CHARACTER(CD_C_MSG_LEN) :: em_r
      IF (.NOT. ALLOCATED(held)) RETURN
      DO il = 1, SIZE(held)
        IF (ALLOCATED(held(il)%velocity) .AND. ALLOCATED(held(il)%waterline)) THEN
          CALL CD_Update_Model_Hydro_Fields(h%fast%system%lines(il), es_r, em_r, fluid_velocity=held(il)%velocity, &
                                            drag_waterline_z=held(il)%waterline)
        ELSE IF (ALLOCATED(held(il)%velocity)) THEN
          CALL CD_Update_Model_Hydro_Fields(h%fast%system%lines(il), es_r, em_r, fluid_velocity=held(il)%velocity)
        END IF
      END DO
    END SUBROUTINE restore_point_fluid

    SUBROUTINE clear_failed_step_flags()
      !! A step that did not commit reports converged = stalled = false and n_iter = 0 on
      !! every route (the documented hard-failure contract).
      IF (err_stat /= CD_C_OK) THEN
        converged = .FALSE._C_BOOL
        stalled = .FALSE._C_BOOL
        n_iter = 0_C_INT
      END IF
    END SUBROUTINE clear_failed_step_flags
  END SUBROUTINE CableDyn_Step

  SUBROUTINE CableDyn_CalcOutput(handle, loads_ptr, n_coupled_dof, err_stat) BIND(C, NAME='CableDyn_CalcOutput')
    !! Copy coupled reaction loads into a C-owned array.
    TYPE(C_PTR), VALUE :: handle, loads_ptr
    INTEGER(C_INT), VALUE :: n_coupled_dof
    INTEGER(C_INT), INTENT(OUT) :: err_stat
    TYPE(CD_C_Handle), POINTER :: h
    REAL(C_DOUBLE), POINTER :: loads_c(:)
    INTEGER :: es
    CHARACTER(CD_C_MSG_LEN) :: em

    err_stat = validate_handle(handle, h)
    IF (err_stat /= CD_C_OK) RETURN
    IF (.NOT. valid_coupled_dof_count(h, n_coupled_dof, err_stat)) RETURN
    IF (n_coupled_dof > 0_C_INT .AND. .NOT. C_ASSOCIATED(loads_ptr)) THEN
      CALL set_status(h, CD_C_BAD_INPUT, 'CableDyn_CalcOutput: coupled_loads pointer is null', err_stat)
      RETURN
    END IF
    CALL ensure_c_vector_workspace(h, INT(n_coupled_dof), need_load=.TRUE., err_stat=err_stat)
    IF (err_stat /= CD_C_OK) RETURN
    IF (n_coupled_dof > 0_C_INT) THEN
      CALL C_F_POINTER(loads_ptr, loads_c, [INT(n_coupled_dof)])
      loads_c = 0.0_C_DOUBLE
    END IF
    IF (h%use_agg) THEN
      CALL CD_AGG_CalcOutput(h%agg, es, em)
      IF (es == CD_AGG_OK) CALL CD_AGG_GetMovingPointMesh(h%agg, h%agg_pos, h%agg_vel, h%agg_acc, h%agg_load, es, em)
      IF (es == CD_AGG_OK .AND. n_coupled_dof > 0_C_INT) &
        loads_c = REAL(RESHAPE(h%agg_load, [INT(n_coupled_dof)]), C_DOUBLE)
      CALL map_agg_status(es, err_stat)
      CALL store_status(h, err_stat, em)
      RETURN
    END IF
    CALL CD_FAST_CalcOutput(h%fast, h%loads_work(1:INT(n_coupled_dof)), es, em)
    IF (es == CD_FAST_OK .AND. n_coupled_dof > 0_C_INT) &
      loads_c = REAL(h%loads_work(1:INT(n_coupled_dof)), C_DOUBLE)
    CALL map_fast_status(es, err_stat)
    CALL store_status(h, err_stat, em)
  END SUBROUTINE CableDyn_CalcOutput

  SUBROUTINE CableDyn_CalcOutputDerivatives(handle, q_ptr, v_ptr, a_ptr, n_coupled_dof, eps_fd, loads_ptr, &
                                            dload_dq_ptr, dload_dv_ptr, dload_da_ptr, added_mass_ptr, err_stat) &
    BIND(C, NAME='CableDyn_CalcOutputDerivatives')
    !! Return coupled loads plus reduced shell load derivatives for tight
    !! coupling. The q/v/a blocks are assembled at the Fortran model/system
    !! boundary; added mass is the negative acceleration derivative. Matrices are
    !! flat column-major arrays of size n*n.
    TYPE(C_PTR), VALUE :: handle, q_ptr, v_ptr, a_ptr, loads_ptr
    TYPE(C_PTR), VALUE :: dload_dq_ptr, dload_dv_ptr, dload_da_ptr, added_mass_ptr
    INTEGER(C_INT), VALUE :: n_coupled_dof
    REAL(C_DOUBLE), VALUE :: eps_fd
    INTEGER(C_INT), INTENT(OUT) :: err_stat
    TYPE(CD_C_Handle), POINTER :: h
    REAL(C_DOUBLE), POINTER :: q_c(:), v_c(:), a_c(:), loads_c(:)
    REAL(C_DOUBLE), POINTER :: jq_c(:), jv_c(:), ja_c(:), ma_c(:)
    INTEGER :: es, i, j, n
    CHARACTER(CD_C_MSG_LEN) :: em

    NULLIFY (q_c, v_c, a_c, loads_c, jq_c, jv_c, ja_c, ma_c)
    CALL coupled_inputs(handle, q_ptr, v_ptr, a_ptr, n_coupled_dof, h, q_c, v_c, a_c, err_stat)
    IF (err_stat /= CD_C_OK) RETURN
    IF (h%use_agg) THEN
      CALL set_status(h, CD_C_BAD_INPUT, 'CableDyn_CalcOutputDerivatives: a deck with finite-EI lines, BODIES or '// &
                      'RODS runs on the coupled aggregate, which has no load derivatives', err_stat)
      RETURN
    END IF
    IF (n_coupled_dof > 0_C_INT .AND. &
        .NOT. (C_ASSOCIATED(loads_ptr) .AND. C_ASSOCIATED(dload_dq_ptr) .AND. C_ASSOCIATED(dload_dv_ptr) .AND. &
               C_ASSOCIATED(dload_da_ptr) .AND. C_ASSOCIATED(added_mass_ptr))) THEN
      CALL set_status(h, CD_C_BAD_INPUT, 'CableDyn_CalcOutputDerivatives: output pointer is null', err_stat)
      RETURN
    END IF
    n = INT(n_coupled_dof)
    IF (n > 0) THEN
      ! Guard the flat n*n shapes in INT64 before forming them: a corrupted/huge
      ! n_coupled_dof would otherwise wrap the default-integer n*n and map the C
      ! buffers at the wrong size. Reject before any C_F_POINTER / workspace alloc.
      IF (INT(n, INT64)*INT(n, INT64) > INT(HUGE(n), INT64)) THEN
        CALL set_status(h, CD_C_BAD_INPUT, &
                        'CableDyn_CalcOutputDerivatives: n_coupled_dof too large; n*n overflows the buffer index', &
                        err_stat)
        RETURN
      END IF
      CALL C_F_POINTER(loads_ptr, loads_c, [n])
      CALL C_F_POINTER(dload_dq_ptr, jq_c, [n*n])
      CALL C_F_POINTER(dload_dv_ptr, jv_c, [n*n])
      CALL C_F_POINTER(dload_da_ptr, ja_c, [n*n])
      CALL C_F_POINTER(added_mass_ptr, ma_c, [n*n])
      loads_c = 0.0_C_DOUBLE
      jq_c = 0.0_C_DOUBLE
      jv_c = 0.0_C_DOUBLE
      ja_c = 0.0_C_DOUBLE
      ma_c = 0.0_C_DOUBLE
    END IF
    CALL ensure_c_derivative_workspace(h, n, err_stat)
    IF (err_stat /= CD_C_OK) RETURN
    IF (n > 0) THEN
      h%q_work(1:n) = REAL(q_c, wp)
      h%v_work(1:n) = REAL(v_c, wp)
      h%a_work(1:n) = REAL(a_c, wp)
    END IF
    CALL CD_FAST_CalcOutputDerivatives(h%fast, h%q_work(1:n), h%v_work(1:n), h%a_work(1:n), &
                                       REAL(eps_fd, wp), h%loads_work(1:n), h%jq_work(1:n, 1:n), &
                                       h%jv_work(1:n, 1:n), h%ja_work(1:n, 1:n), h%madd_work(1:n, 1:n), es, em)
    IF (es == CD_FAST_OK .AND. n > 0) THEN
      loads_c = REAL(h%loads_work(1:n), C_DOUBLE)
      DO j = 1, n
        DO i = 1, n
          jq_c(i + (j - 1)*n) = REAL(h%jq_work(i, j), C_DOUBLE)
          jv_c(i + (j - 1)*n) = REAL(h%jv_work(i, j), C_DOUBLE)
          ja_c(i + (j - 1)*n) = REAL(h%ja_work(i, j), C_DOUBLE)
          ma_c(i + (j - 1)*n) = REAL(h%madd_work(i, j), C_DOUBLE)
        END DO
      END DO
    END IF
    CALL map_fast_status(es, err_stat)
    CALL store_status(h, err_stat, em)
  END SUBROUTINE CableDyn_CalcOutputDerivatives

  SUBROUTINE CableDyn_GetCoupledMotion(handle, q_ptr, v_ptr, a_ptr, n_coupled_dof, err_stat) &
    BIND(C, NAME='CableDyn_GetCoupledMotion')
    !! Copy current coupled kinematics into C-owned arrays.
    TYPE(C_PTR), VALUE :: handle, q_ptr, v_ptr, a_ptr
    INTEGER(C_INT), VALUE :: n_coupled_dof
    INTEGER(C_INT), INTENT(OUT) :: err_stat
    TYPE(CD_C_Handle), POINTER :: h
    REAL(C_DOUBLE), POINTER :: q_c(:), v_c(:), a_c(:)
    INTEGER :: es
    CHARACTER(CD_C_MSG_LEN) :: em

    CALL coupled_outputs(handle, q_ptr, v_ptr, a_ptr, n_coupled_dof, h, q_c, v_c, a_c, err_stat)
    IF (err_stat /= CD_C_OK) RETURN
    IF (h%use_agg) THEN
      IF (n_coupled_dof > 0_C_INT) THEN
        q_c = 0.0_C_DOUBLE
        v_c = 0.0_C_DOUBLE
        a_c = 0.0_C_DOUBLE
      END IF
      CALL CD_AGG_GetMovingPointMesh(h%agg, h%agg_pos, h%agg_vel, h%agg_acc, h%agg_load, es, em)
      IF (es == CD_AGG_OK .AND. n_coupled_dof > 0_C_INT) THEN
        q_c = REAL(RESHAPE(h%agg_pos, [INT(n_coupled_dof)]), C_DOUBLE)
        v_c = REAL(RESHAPE(h%agg_vel, [INT(n_coupled_dof)]), C_DOUBLE)
        a_c = REAL(RESHAPE(h%agg_acc, [INT(n_coupled_dof)]), C_DOUBLE)
      END IF
      CALL map_agg_status(es, err_stat)
      CALL store_status(h, err_stat, em)
      RETURN
    END IF
    CALL ensure_c_vector_workspace(h, INT(n_coupled_dof), need_load=.FALSE., err_stat=err_stat)
    IF (err_stat /= CD_C_OK) RETURN
    IF (n_coupled_dof > 0_C_INT) THEN
      q_c = 0.0_C_DOUBLE
      v_c = 0.0_C_DOUBLE
      a_c = 0.0_C_DOUBLE
    END IF
    CALL CD_FAST_GetCoupledMotion(h%fast, h%q_work(1:INT(n_coupled_dof)), h%v_work(1:INT(n_coupled_dof)), &
                                  h%a_work(1:INT(n_coupled_dof)), es, em)
    IF (es == CD_FAST_OK .AND. n_coupled_dof > 0_C_INT) THEN
      q_c = REAL(h%q_work(1:INT(n_coupled_dof)), C_DOUBLE)
      v_c = REAL(h%v_work(1:INT(n_coupled_dof)), C_DOUBLE)
      a_c = REAL(h%a_work(1:INT(n_coupled_dof)), C_DOUBLE)
    END IF
    CALL map_fast_status(es, err_stat)
    CALL store_status(h, err_stat, em)
  END SUBROUTINE CableDyn_GetCoupledMotion

  SUBROUTINE CableDyn_GetLastError(handle, message_ptr, message_len) BIND(C, NAME='CableDyn_GetLastError')
    !! Copy the last diagnostic message stored on the opaque handle into a
    !! C-owned character buffer. The buffer is always null-terminated when
    !! `message_len > 0` and `message_ptr` is associated.
    TYPE(C_PTR), VALUE :: handle, message_ptr
    INTEGER(C_INT), VALUE :: message_len

    TYPE(CD_C_Handle), POINTER :: h
    CHARACTER(KIND=C_CHAR), POINTER :: message_c(:)
    CHARACTER(CD_C_MSG_LEN) :: msg

    IF (message_len < 1_C_INT .OR. .NOT. C_ASSOCIATED(message_ptr)) RETURN
    CALL C_F_POINTER(message_ptr, message_c, [INT(message_len)])
    message_c = C_NULL_CHAR
    IF (validate_handle(handle, h) /= CD_C_OK) THEN
      msg = 'CableDyn C API: bad handle'
    ELSE
      msg = h%last_error
    END IF
    CALL copy_message_to_c(TRIM(msg), message_c)
  END SUBROUTINE CableDyn_GetLastError

  FUNCTION CableDyn_GetInitNotes(handle, notes_ptr, notes_len) RESULT(needed) BIND(C, NAME='CableDyn_GetInitNotes')
    !! Copy the notes of the last deck initialisation on the handle, one per line, into a C-owned
    !! character buffer, under the conventions of CableDyn_GetLastError: always null-terminated
    !! when `notes_len > 0` and `notes_ptr` is associated, and truncated to notes_len - 1. Returns
    !! the length of the whole text without the terminator, so a null buffer asks for the size;
    !! -1 on a bad handle.
    TYPE(C_PTR), VALUE :: handle, notes_ptr
    INTEGER(C_INT), VALUE :: notes_len
    INTEGER(C_INT) :: needed

    TYPE(CD_C_Handle), POINTER :: h
    CHARACTER(KIND=C_CHAR), POINTER :: notes_c(:)
    LOGICAL :: has_buffer

    has_buffer = notes_len >= 1_C_INT .AND. C_ASSOCIATED(notes_ptr)
    IF (has_buffer) THEN
      CALL C_F_POINTER(notes_ptr, notes_c, [INT(notes_len)])
      notes_c = C_NULL_CHAR
    END IF
    needed = -1_C_INT
    IF (validate_handle(handle, h) /= CD_C_OK) RETURN
    needed = 0_C_INT
    IF (.NOT. ALLOCATED(h%init_notes)) RETURN
    needed = INT(LEN(h%init_notes), C_INT)
    IF (has_buffer) CALL copy_message_to_c(h%init_notes, notes_c)
  END FUNCTION CableDyn_GetInitNotes

  SUBROUTINE CableDyn_Close(handle, err_stat) BIND(C, NAME='CableDyn_Close')
    !! Release a CableDyn C handle. A null handle is an idempotent no-op
    !! (CD_C_OK). A non-null pointer that is not a live CableDyn handle (stale,
    !! double-closed, or foreign) is left untouched and reported CD_C_BAD_HANDLE --
    !! it is never dereferenced or deallocated. Only a validated live handle is
    !! de-registered, finalized, deallocated, and nulled.
    !!
    !! With GNU OpenMP (libgomp), closing a live handle also releases the OpenMP thread
    !! pool of the calling thread (outside a parallel region only; the next parallel
    !! region starts a new one). A pool left to the runtime is torn down when its host
    !! thread exits, and its threads then end detached: a process that exits while one
    !! of them is still ending can hang in the OpenMP runtime's exit handler (MinGW-w64
    !! libgomp with winpthreads). Joining the pool here means a host thread that closes
    !! its handles before it ends leaves no such thread behind. The Intel and LLVM
    !! runtime (libiomp5/libomp) pauses the whole process instead: one handle's Close
    !! then paused the OpenMP of every other handle and of the host, and the first
    !! parallel region of another thread deadlocked resuming it. Those runtimes are not
    !! paused here.
!$  USE OMP_LIB, ONLY: omp_pause_resource_all, omp_pause_soft
    TYPE(C_PTR), INTENT(INOUT) :: handle
    INTEGER(C_INT), INTENT(OUT) :: err_stat
    TYPE(CD_C_Handle), POINTER :: h
    INTEGER :: es
    CHARACTER(CD_C_MSG_LEN) :: em
!$  INTEGER :: omp_stat
    ! libgomp only (see above): COMPILER_VERSION names the compiler that built this unit
    LOGICAL, PARAMETER :: OMP_POOL_JOIN_ON_CLOSE = INDEX(COMPILER_VERSION(), 'GCC') > 0

    err_stat = CD_C_OK
    IF (.NOT. C_ASSOCIATED(handle)) RETURN
    ! Atomically claim ownership: exactly one concurrent Close of this (or a copied)
    ! handle removes it from the registry and proceeds; the rest get .FALSE. and must
    ! not free. A foreign/stale/double-closed pointer also fails the claim.
    IF (.NOT. registry_claim(handle)) THEN
      err_stat = CD_C_BAD_HANDLE
      RETURN
    END IF
    ! We now exclusively own the target: the registry guaranteed it was a live handle
    ! we created, and the claim removed it so no other Close can reach it.
    CALL C_F_POINTER(handle, h)
    h%magic = 0_INT64
    CALL CD_FAST_End(h%fast, es, em)
    CALL drop_aggregate(h)
    CALL drop_saved_state(h)
    CALL clear_c_workspace(h)
    DEALLOCATE (h)
    handle = C_NULL_PTR
    ! Nonzero inside an active parallel region, where the pool is left alone.
!$  IF (OMP_POOL_JOIN_ON_CLOSE) omp_stat = omp_pause_resource_all(omp_pause_soft)
  END SUBROUTINE CableDyn_Close

  FUNCTION CableDyn_IsInitialized(handle) RESULT(is_initialized) BIND(C, NAME='CableDyn_IsInitialized')
    !! Return whether the handle owns an initialized CableDyn module.
    TYPE(C_PTR), VALUE :: handle
    LOGICAL(C_BOOL) :: is_initialized
    TYPE(CD_C_Handle), POINTER :: h

    is_initialized = .FALSE._C_BOOL
    IF (validate_handle(handle, h) /= CD_C_OK) RETURN
    IF (h%use_agg) THEN
      is_initialized = LOGICAL(CD_AGG_IsInitialized(h%agg), C_BOOL)
    ELSE
      is_initialized = LOGICAL(CD_FAST_IsInitialized(h%fast), C_BOOL)
    END IF
  END FUNCTION CableDyn_IsInitialized

  FUNCTION CableDyn_NCoupledDOF(handle, err_stat) RESULT(n) BIND(C, NAME='CableDyn_NCoupledDOF')
    !! Return aggregate coupled DOF count, or zero for a null/uninitialized handle.
    TYPE(C_PTR), VALUE :: handle
    INTEGER(C_INT), INTENT(OUT) :: err_stat
    INTEGER(C_INT) :: n
    TYPE(CD_C_Handle), POINTER :: h
    INTEGER :: es
    CHARACTER(CD_C_MSG_LEN) :: em

    n = 0_C_INT
    err_stat = validate_handle(handle, h)
    IF (err_stat /= CD_C_OK) RETURN
    IF (h%use_agg) THEN
      n = INT(3*CD_AGG_NMovingPoints(h%agg, es, em), C_INT)
      CALL map_agg_status(es, err_stat)
      CALL store_status(h, err_stat, em)
      RETURN
    END IF
    n = INT(CD_FAST_NCoupledDOF(h%fast, es, em), C_INT)
    CALL map_fast_status(es, err_stat)
    CALL store_status(h, err_stat, em)
  END FUNCTION CableDyn_NCoupledDOF

  FUNCTION CableDyn_NPoints(handle, err_stat) RESULT(n) BIND(C, NAME='CableDyn_NPoints')
    !! Return the stored system point count, or zero for a null/uninitialized handle. This
    !! is the column count CableDyn_UpdatePointFluidFields expects, and can exceed
    !! CableDyn_NCoupledDOF/3 when the deck has unbound (output-only) Fixed/Coupled points.
    TYPE(C_PTR), VALUE :: handle
    INTEGER(C_INT), INTENT(OUT) :: err_stat
    INTEGER(C_INT) :: n
    TYPE(CD_C_Handle), POINTER :: h
    INTEGER :: es
    CHARACTER(CD_C_MSG_LEN) :: em

    n = 0_C_INT
    err_stat = validate_handle(handle, h)
    IF (err_stat /= CD_C_OK) RETURN
    IF (h%use_agg) THEN
      n = INT(h%agg%n_points, C_INT)
      CALL store_status(h, CD_C_OK, '')
      RETURN
    END IF
    n = INT(CD_FAST_NPoints(h%fast, es, em), C_INT)
    CALL map_fast_status(es, err_stat)
    CALL store_status(h, err_stat, em)
  END FUNCTION CableDyn_NPoints

  FUNCTION CableDyn_NLines(handle, err_stat) RESULT(n) BIND(C, NAME='CableDyn_NLines')
    !! Return owned line count, or zero for a null/uninitialized handle.
    TYPE(C_PTR), VALUE :: handle
    INTEGER(C_INT), INTENT(OUT) :: err_stat
    INTEGER(C_INT) :: n
    TYPE(CD_C_Handle), POINTER :: h
    INTEGER :: es
    CHARACTER(CD_C_MSG_LEN) :: em

    n = 0_C_INT
    err_stat = validate_handle(handle, h)
    IF (err_stat /= CD_C_OK) RETURN
    IF (h%use_agg) THEN
      n = INT(h%agg%n_lines, C_INT)
      CALL store_status(h, CD_C_OK, '')
      RETURN
    END IF
    n = INT(CD_FAST_NLines(h%fast, es, em), C_INT)
    CALL map_fast_status(es, err_stat)
    CALL store_status(h, err_stat, em)
  END FUNCTION CableDyn_NLines

  ! ---------------------------------------------------------------------------------------
  ! In-process object queries (C ABI 1, minor extension 1). Every value is read from the
  ! committed state through the evaluator the standalone driver's output channels use
  ! (CD_Eval_Aggregate_Channel) or through the state accessors its per-line files use, so a
  ! query reports the value the matching output channel reports at the same step. Object
  ! indices are 0-based positions in the handle's inventory; ids are deck ids.
  ! ---------------------------------------------------------------------------------------

  FUNCTION CableDyn_GetAbiMinor() RESULT(minor) BIND(C, NAME='CableDyn_GetAbiMinor')
    !! Minor extension level of C ABI 1 (1 = the object queries are present).
    INTEGER(C_INT) :: minor
    minor = CD_C_ABI_MINOR
  END FUNCTION CableDyn_GetAbiMinor

  FUNCTION CableDyn_NObjects(handle, kind, err_stat) RESULT(n) BIND(C, NAME='CableDyn_NObjects')
    !! Number of objects of one kind (CD_C_OBJ_LINE/POINT/BODY/ROD) in the handle's inventory.
    TYPE(C_PTR), VALUE :: handle
    INTEGER(C_INT), VALUE :: kind
    INTEGER(C_INT), INTENT(OUT) :: err_stat
    INTEGER(C_INT) :: n
    TYPE(CD_C_Handle), POINTER :: h
    INTEGER, ALLOCATABLE :: ids(:), nnodes(:), sub(:)

    n = 0_C_INT
    IF (.NOT. query_ready(handle, h, 'CableDyn_NObjects', err_stat)) RETURN
    CALL object_inventory(h, INT(kind), ids, nnodes, sub, err_stat)
    IF (err_stat /= CD_C_OK) RETURN
    n = INT(SIZE(ids), C_INT)
    CALL store_status(h, CD_C_OK, '')
  END FUNCTION CableDyn_NObjects

  SUBROUTINE CableDyn_GetObjectInfo(handle, kind, index, id, n_nodes, subtype, err_stat) &
    BIND(C, NAME='CableDyn_GetObjectInfo')
    !! Deck id, node count and subtype of object `index` (0-based) of one kind. Lines: node
    !! count, subtype 1 for a finite-EI (bending) line, 0 for EI=0. Points: 1 node, subtype the
    !! point kind (1 Fixed, 2 Coupled, 3 Free, 4 Connect). Bodies: 1 node, subtype 0. Rods:
    !! NumSegs + 1 nodes, subtype 0.
    TYPE(C_PTR), VALUE :: handle
    INTEGER(C_INT), VALUE :: kind, index
    INTEGER(C_INT), INTENT(OUT) :: id, n_nodes, subtype, err_stat
    TYPE(CD_C_Handle), POINTER :: h
    INTEGER, ALLOCATABLE :: ids(:), nnodes(:), sub(:)

    id = 0_C_INT
    n_nodes = 0_C_INT
    subtype = 0_C_INT
    IF (.NOT. query_ready(handle, h, 'CableDyn_GetObjectInfo', err_stat)) RETURN
    CALL object_inventory(h, INT(kind), ids, nnodes, sub, err_stat)
    IF (err_stat /= CD_C_OK) RETURN
    IF (index < 0_C_INT .OR. INT(index) >= SIZE(ids)) THEN
      CALL set_status(h, CD_C_BAD_INPUT, 'CableDyn_GetObjectInfo: object index out of range', err_stat)
      RETURN
    END IF
    id = INT(ids(index + 1), C_INT)
    n_nodes = INT(nnodes(index + 1), C_INT)
    subtype = INT(sub(index + 1), C_INT)
    CALL store_status(h, CD_C_OK, '')
  END SUBROUTINE CableDyn_GetObjectInfo

  SUBROUTINE CableDyn_GetLineValues(handle, index, quantity, out_ptr, n_out, err_stat) &
    BIND(C, NAME='CableDyn_GetLineValues')
    !! One quantity along line `index` (0-based) in public node order End A -> End B.
    !! quantity: CD_C_LINE_POSITION / VELOCITY / ACCELERATION (3 per node, xyz interleaved),
    !! TENSION / CURVATURE / BEND_MOMENT / DECLINATION / AZIMUTH (1 per node), or
    !! SEGMENT_TENSION (1 per segment), or DECK_NODE (1 per node: the deck node of each node of the
    !! line's final mesh, the J of the node channels; 0 for a node a refinement added), or
    !! SECTION_CURVATURE (2 per node, CurvX and CurvY interleaved; finite-EI lines). Every quantity
    !! covers every node of the final mesh. n_out must equal the value count exactly. The node
    !! channels are evaluated for the whole line at once (CD_Eval_Aggregate_Line_Values).
    TYPE(C_PTR), VALUE :: handle, out_ptr
    INTEGER(C_INT), VALUE :: index, quantity, n_out
    INTEGER(C_INT), INTENT(OUT) :: err_stat
    TYPE(CD_C_Handle), POINTER :: h
    REAL(C_DOUBLE), POINTER :: out_c(:)
    INTEGER :: nnode, nvals, line_id, node, es, n_done, bad
    CHARACTER(CD_C_MSG_LEN) :: em

    IF (.NOT. query_ready(handle, h, 'CableDyn_GetLineValues', err_stat)) RETURN
    CALL line_at_index(h, INT(index), line_id, nnode)
    IF (line_id < 1) THEN
      CALL set_status(h, CD_C_BAD_INPUT, 'CableDyn_GetLineValues: line index out of range', err_stat)
      RETURN
    END IF
    SELECT CASE (quantity)
    CASE (CD_C_LINE_POSITION, CD_C_LINE_VELOCITY, CD_C_LINE_ACCELERATION)
      nvals = 3*nnode
    CASE (CD_C_LINE_TENSION, CD_C_LINE_CURVATURE, CD_C_LINE_BEND_MOMENT, CD_C_LINE_DECLINATION, &
          CD_C_LINE_AZIMUTH, CD_C_LINE_DECK_NODE)
      nvals = nnode
    CASE (CD_C_LINE_SECTION_CURVATURE)
      nvals = 2*nnode
    CASE (CD_C_LINE_SEGMENT_TENSION)
      nvals = nnode - 1
    CASE DEFAULT
      CALL set_status(h, CD_C_BAD_INPUT, 'CableDyn_GetLineValues: unknown quantity code', err_stat)
      RETURN
    END SELECT
    IF (INT(n_out) /= nvals .OR. .NOT. C_ASSOCIATED(out_ptr)) THEN
      CALL set_status(h, CD_C_BAD_INPUT, 'CableDyn_GetLineValues: output buffer is null or its size does '// &
                      'not match the line', err_stat)
      RETURN
    END IF
    CALL C_F_POINTER(out_ptr, out_c, [nvals])

    IF (quantity == CD_C_LINE_DECK_NODE) THEN
      ! deck node of each mesh node: a refined finite-EI cable maps them; any other line is meshed
      ! as the deck
      DO node = 1, nnode
        out_c(node) = REAL(node, C_DOUBLE)
        IF (h%use_agg) THEN
          IF (h%agg%line_is_cable(line_id)) out_c(node) = &
            REAL(CD_Cable_Deck_Node(h%agg%cables(h%agg%line_obj_index(line_id)), node), C_DOUBLE)
        END IF
      END DO
      CALL store_status(h, CD_C_OK, '')
      RETURN
    END IF

    IF (quantity == CD_C_LINE_SECTION_CURVATURE) THEN
      ! one evaluation for the whole line, in internal node order (node nn is End A)
      IF (.NOT. h%use_agg) THEN
        CALL set_status(h, CD_C_BAD_INPUT, 'CableDyn_GetLineValues: the section curvature is defined on '// &
                        'finite-EI lines', err_stat)
        RETURN
      END IF
      IF (.NOT. h%agg%line_is_cable(line_id)) THEN
        CALL set_status(h, CD_C_BAD_INPUT, 'CableDyn_GetLineValues: the section curvature is defined on '// &
                        'finite-EI lines', err_stat)
        RETURN
      END IF
      BLOCK
        REAL(wp) :: kx(nnode), ky(nnode)
        CALL CD_HFMF_Section_Curvature(h%agg%cables(h%agg%line_obj_index(line_id)), kx, ky, es, em)
        IF (es /= CD_HFMF_OK) THEN
          CALL set_status(h, CD_C_SOLVE_FAIL, 'CableDyn_GetLineValues: '//TRIM(em), err_stat)
          RETURN
        END IF
        DO node = 1, nnode
          out_c(2*node - 1) = REAL(kx(nnode + 1 - node), C_DOUBLE)
          out_c(2*node) = REAL(ky(nnode + 1 - node), C_DOUBLE)
        END DO
      END BLOCK
      CALL store_status(h, CD_C_OK, '')
      RETURN
    END IF

    IF (quantity == CD_C_LINE_SEGMENT_TENSION) THEN
      BLOCK
        REAL(wp) :: ten(nvals)
        IF (h%use_agg) THEN
          CALL CD_Eval_Aggregate_Segment_Tensions(line_id, h%agg%has_sys, h%agg%sys%fast%system, h%agg%cables, &
                                                  h%agg%line_is_cable, h%agg%line_obj_index, ten, es, em)
        ELSE
          CALL CD_Eval_Aggregate_Segment_Tensions(line_id, .TRUE., h%fast%system, h%no_cables, h%pt_is_cable, &
                                                  h%pt_obj, ten, es, em)
        END IF
        CALL map_deck_status(es, err_stat)
        IF (err_stat /= CD_C_OK) THEN
          CALL store_status(h, err_stat, 'CableDyn_GetLineValues: '//TRIM(em))
          RETURN
        END IF
        out_c = REAL(ten, C_DOUBLE)
      END BLOCK
      CALL store_status(h, CD_C_OK, '')
      RETURN
    END IF

    ! the node channels, whose codes are the quantity codes
    IF (.NOT. line_work_ready(h, nnode)) THEN
      CALL set_status(h, CD_C_ALLOC_FAIL, 'CableDyn_GetLineValues: workspace allocation failed', err_stat)
      RETURN
    END IF
    IF (h%use_agg) THEN
      CALL CD_Eval_Aggregate_Line_Values(line_id, INT(quantity), h%agg%has_sys, h%agg%sys%fast%system, h%agg%cables, &
                                         h%agg%line_is_cable, h%agg%line_obj_index, out_c, h%line_work, n_done, es, em)
    ELSE
      CALL CD_Eval_Aggregate_Line_Values(line_id, INT(quantity), .TRUE., h%fast%system, h%no_cables, h%pt_is_cable, &
                                         h%pt_obj, out_c, h%line_work, n_done, es, em)
    END IF
    ! the first value that failed: its channel gives the status and the reason, as a token would
    bad = 0
    DO node = 1, n_done
      IF (.NOT. IEEE_IS_FINITE(out_c(node))) THEN
        bad = node
        EXIT
      END IF
    END DO
    IF (bad == 0 .AND. es /= CD_DECKDRV_OK) bad = n_done + 1
    IF (bad > 0) THEN
      CALL line_value_failure(h, line_id, quantity, bad, err_stat)
      IF (err_stat /= CD_C_OK) RETURN
      CALL map_deck_status(es, err_stat)
      IF (err_stat == CD_C_OK) err_stat = CD_C_SOLVE_FAIL
      CALL store_status(h, err_stat, 'CableDyn_GetLineValues: '//TRIM(em))
      RETURN
    END IF
    CALL store_status(h, CD_C_OK, '')
  END SUBROUTINE CableDyn_GetLineValues

  SUBROUTINE CableDyn_GetPointState(handle, index, pos_ptr, vel_ptr, force_ptr, err_stat) &
    BIND(C, NAME='CableDyn_GetPointState')
    !! Position, velocity and line force (the resultant of the forces the attached lines exert
    !! on it, the Point<P>F channels) of point `index` (0-based). Each output is 3 doubles; a
    !! null pointer skips that output.
    TYPE(C_PTR), VALUE :: handle, pos_ptr, vel_ptr, force_ptr
    INTEGER(C_INT), VALUE :: index
    INTEGER(C_INT), INTENT(OUT) :: err_stat
    TYPE(CD_C_Handle), POINTER :: h
    REAL(C_DOUBLE), POINTER :: out_c(:)
    INTEGER, ALLOCATABLE :: ids(:), nnodes(:), sub(:)
    INTEGER :: c, pidx
    REAL(wp) :: val
    CHARACTER(1), PARAMETER :: xyz(3) = ['x', 'y', 'z']

    IF (.NOT. query_ready(handle, h, 'CableDyn_GetPointState', err_stat)) RETURN
    CALL object_inventory(h, INT(CD_C_OBJ_POINT), ids, nnodes, sub, err_stat)
    IF (err_stat /= CD_C_OK) RETURN
    IF (index < 0_C_INT .OR. INT(index) >= SIZE(ids)) THEN
      CALL set_status(h, CD_C_BAD_INPUT, 'CableDyn_GetPointState: point index out of range', err_stat)
      RETURN
    END IF
    pidx = INT(index) + 1
    IF (C_ASSOCIATED(pos_ptr)) THEN
      CALL C_F_POINTER(pos_ptr, out_c, [3])
      DO c = 1, 3
        CALL eval_token(h, 'Point'//TRIM(int_text(ids(pidx)))//'p'//xyz(c), val, err_stat)
        IF (err_stat /= CD_C_OK) RETURN
        out_c(c) = REAL(val, C_DOUBLE)
      END DO
    END IF
    IF (C_ASSOCIATED(vel_ptr)) THEN
      CALL C_F_POINTER(vel_ptr, out_c, [3])
      IF (h%use_agg) THEN
        out_c = REAL(h%agg%sys%fast%system%points(pidx)%v, C_DOUBLE)
      ELSE
        out_c = REAL(h%fast%system%points(pidx)%v, C_DOUBLE)
      END IF
    END IF
    IF (C_ASSOCIATED(force_ptr)) THEN
      CALL C_F_POINTER(force_ptr, out_c, [3])
      DO c = 1, 3
        CALL eval_token(h, 'Point'//TRIM(int_text(ids(pidx)))//'F'//xyz(c), val, err_stat)
        IF (err_stat /= CD_C_OK) RETURN
        out_c(c) = REAL(val, C_DOUBLE)
      END DO
    END IF
    CALL store_status(h, CD_C_OK, '')
  END SUBROUTINE CableDyn_GetPointState

  SUBROUTINE CableDyn_GetBodyState(handle, index, pose_ptr, vel_ptr, acc_ptr, wrench_ptr, err_stat) &
    BIND(C, NAME='CableDyn_GetBodyState')
    !! Rigid6 body `index` (0-based), each output 6 doubles (a null pointer skips it): pose
    !! [x, y, z, rx, ry, rz] (reference point [m], x-y'-z'' Euler angles [deg]); velocity
    !! [vx, vy, vz, wx, wy, wz] ([m/s], [deg/s]); acceleration ([m/s^2], [deg/s^2]); net external
    !! wrench [Fx, Fy, Fz, Mx, My, Mz] about the reference point ([N], [N.m]) -- the Body<N>
    !! P/R, V/RV, A/RA and F/M channels.
    TYPE(C_PTR), VALUE :: handle, pose_ptr, vel_ptr, acc_ptr, wrench_ptr
    INTEGER(C_INT), VALUE :: index
    INTEGER(C_INT), INTENT(OUT) :: err_stat
    TYPE(CD_C_Handle), POINTER :: h
    INTEGER, ALLOCATABLE :: ids(:), nnodes(:), sub(:)
    CHARACTER(CD_DECK_NAMELEN) :: prefix

    IF (.NOT. query_ready(handle, h, 'CableDyn_GetBodyState', err_stat)) RETURN
    CALL object_inventory(h, INT(CD_C_OBJ_BODY), ids, nnodes, sub, err_stat)
    IF (err_stat /= CD_C_OK) RETURN
    IF (index < 0_C_INT .OR. INT(index) >= SIZE(ids)) THEN
      CALL set_status(h, CD_C_BAD_INPUT, 'CableDyn_GetBodyState: body index out of range', err_stat)
      RETURN
    END IF
    prefix = 'Body'//TRIM(int_text(ids(index + 1)))
    CALL eval_six(h, prefix, 'P', 'R', .TRUE., pose_ptr, err_stat)
    IF (err_stat /= CD_C_OK) RETURN
    CALL eval_six(h, prefix, 'V', 'RV', .TRUE., vel_ptr, err_stat)
    IF (err_stat /= CD_C_OK) RETURN
    CALL eval_six(h, prefix, 'A', 'RA', .TRUE., acc_ptr, err_stat)
    IF (err_stat /= CD_C_OK) RETURN
    CALL eval_six(h, prefix, 'F', 'M', .TRUE., wrench_ptr, err_stat)
    IF (err_stat /= CD_C_OK) RETURN
    CALL store_status(h, CD_C_OK, '')
  END SUBROUTINE CableDyn_GetBodyState

  SUBROUTINE CableDyn_GetRodState(handle, index, nodes_ptr, n_nodes, pose_ptr, vel_ptr, wrench_ptr, err_stat) &
    BIND(C, NAME='CableDyn_GetRodState')
    !! Rod `index` (0-based); a null pointer skips that output. nodes: node positions End A
    !! (node 0) -> End B (node NumSegs), 3 doubles per node (n_nodes = NumSegs + 1). pose:
    !! [x, y, z, rx, ry, 0], End A [m] and the roll/pitch of the axis from the vertical [deg].
    !! vel: End A [vx, vy, vz, wx, wy, wz] ([m/s], [deg/s]). wrench: net [Fx, Fy, Fz, Mx, My,
    !! Mz] about End A ([N], [N.m]) -- the Rod<N>N<k>P, P/R, V/RV and F/M channels.
    TYPE(C_PTR), VALUE :: handle, nodes_ptr, pose_ptr, vel_ptr, wrench_ptr
    INTEGER(C_INT), VALUE :: index, n_nodes
    INTEGER(C_INT), INTENT(OUT) :: err_stat
    TYPE(CD_C_Handle), POINTER :: h
    REAL(C_DOUBLE), POINTER :: out_c(:)
    INTEGER, ALLOCATABLE :: ids(:), nnodes(:), sub(:)
    INTEGER :: node, c
    REAL(wp) :: val
    CHARACTER(CD_DECK_NAMELEN) :: prefix
    CHARACTER(1), PARAMETER :: xyz(3) = ['x', 'y', 'z']

    IF (.NOT. query_ready(handle, h, 'CableDyn_GetRodState', err_stat)) RETURN
    CALL object_inventory(h, INT(CD_C_OBJ_ROD), ids, nnodes, sub, err_stat)
    IF (err_stat /= CD_C_OK) RETURN
    IF (index < 0_C_INT .OR. INT(index) >= SIZE(ids)) THEN
      CALL set_status(h, CD_C_BAD_INPUT, 'CableDyn_GetRodState: rod index out of range', err_stat)
      RETURN
    END IF
    prefix = 'Rod'//TRIM(int_text(ids(index + 1)))
    IF (C_ASSOCIATED(nodes_ptr)) THEN
      IF (INT(n_nodes) /= nnodes(index + 1)) THEN
        CALL set_status(h, CD_C_BAD_INPUT, 'CableDyn_GetRodState: n_nodes does not match the rod', err_stat)
        RETURN
      END IF
      CALL C_F_POINTER(nodes_ptr, out_c, [3*nnodes(index + 1)])
      DO node = 0, nnodes(index + 1) - 1
        DO c = 1, 3
          CALL eval_token(h, TRIM(prefix)//'N'//TRIM(int_text(node))//'P'//xyz(c), val, err_stat)
          IF (err_stat /= CD_C_OK) RETURN
          out_c(3*node + c) = REAL(val, C_DOUBLE)
        END DO
      END DO
    END IF
    CALL eval_six(h, prefix, 'P', 'R', .FALSE., pose_ptr, err_stat)
    IF (err_stat /= CD_C_OK) RETURN
    CALL eval_six(h, prefix, 'V', 'RV', .TRUE., vel_ptr, err_stat)
    IF (err_stat /= CD_C_OK) RETURN
    CALL eval_six(h, prefix, 'F', 'M', .TRUE., wrench_ptr, err_stat)
    IF (err_stat /= CD_C_OK) RETURN
    CALL store_status(h, CD_C_OK, '')
  END SUBROUTINE CableDyn_GetRodState

  SUBROUTINE CableDyn_EvalChannel(handle, token_ptr, token_len, value, err_stat) BIND(C, NAME='CableDyn_EvalChannel')
    !! Evaluate one OUTPUTS channel token (the deck OUTPUTS vocabulary, e.g. "FairTen1",
    !! "L2N5px", "Curv1N3", "Point4Fz", "Body1Pz", "Rod2TenA") at the committed state. A
    !! malformed token, an unknown object, or a channel family this handle cannot evaluate
    !! is CD_C_BAD_INPUT or CD_C_SOLVE_FAIL with the reason in CableDyn_GetLastError.
    !! token_len is the buffer length; an embedded NUL ends the token early. The token
    !! itself (up to the NUL) is at most 64 characters.
    TYPE(C_PTR), VALUE :: handle, token_ptr
    INTEGER(C_INT), VALUE :: token_len
    REAL(C_DOUBLE), INTENT(OUT) :: value
    INTEGER(C_INT), INTENT(OUT) :: err_stat
    TYPE(CD_C_Handle), POINTER :: h
    CHARACTER(KIND=C_CHAR), POINTER :: tok_c(:)
    CHARACTER(CD_DECK_NAMELEN) :: token
    INTEGER :: i, n
    REAL(wp) :: val

    value = 0.0_C_DOUBLE
    IF (.NOT. query_ready(handle, h, 'CableDyn_EvalChannel', err_stat)) RETURN
    IF (token_len < 1_C_INT .OR. .NOT. C_ASSOCIATED(token_ptr)) THEN
      CALL set_status(h, CD_C_BAD_INPUT, 'CableDyn_EvalChannel: token pointer is null or its length is '// &
                      'not positive', err_stat)
      RETURN
    END IF
    CALL C_F_POINTER(token_ptr, tok_c, [INT(token_len)])
    token = ''
    n = INT(token_len)
    DO i = 1, INT(token_len)
      IF (tok_c(i) == C_NULL_CHAR) THEN
        n = i - 1
        EXIT
      END IF
      IF (i > CD_DECK_NAMELEN) THEN
        CALL set_status(h, CD_C_BAD_INPUT, 'CableDyn_EvalChannel: the channel token is longer than 64 '// &
                        'characters', err_stat)
        RETURN
      END IF
      token(i:i) = tok_c(i)
    END DO
    IF (n < 1) THEN
      CALL set_status(h, CD_C_BAD_INPUT, 'CableDyn_EvalChannel: empty channel token', err_stat)
      RETURN
    END IF
    IF (.NOT. CD_Channel_Token_Parses(token(1:n))) THEN
      CALL set_status(h, CD_C_BAD_INPUT, 'CableDyn_EvalChannel: "'//token(1:n)// &
                      '" is not a supported output channel token', err_stat)
      RETURN
    END IF
    CALL eval_token(h, token(1:n), val, err_stat)
    IF (err_stat /= CD_C_OK) RETURN
    value = REAL(val, C_DOUBLE)
    CALL store_status(h, CD_C_OK, '')
  END SUBROUTINE CableDyn_EvalChannel

  ! ---------------------------------------------------------------------------------------
  ! Host coupling (C ABI 1, minor extension 2): CableDyn_InitDeckAt (above, with InitDeck),
  ! the one-slot state save/restore a host's outer correctors (PIMPLE, predictor-corrector)
  ! rewind with, and the owner of each block of the coupled vector.
  ! ---------------------------------------------------------------------------------------

  SUBROUTINE CableDyn_SaveState(handle, err_stat) BIND(C, NAME='CableDyn_SaveState')
    !! Save the whole model into the handle's single save slot, replacing any earlier save:
    !! every line, point, body and rod state with its solver history (viscoelastic, Syrope and
    !! friction states, the last converged step), the point fluid fields, and on the aggregate
    !! route the committed time, the host's rotations (CableDyn_UpdateRotations) and the host's
    !! fluid field (CableDyn_UpdateFluidFields). The slot
    !! holds a deep copy of the model object, independent of the step's own rollback buffers,
    !! so any number of steps may follow before the restore.
    !! A successful Init* call discards the slot; a failed InitDeck/InitDeckAt keeps it with the
    !! model, and a failed InitLine/InitLines discards it unless the handle's live model is an
    !! aggregate (drop_point_save_on_failure). Only the allocation of the aggregate slot itself
    !! returns CD_C_ALLOC_FAIL (the handle then holds no save); running out of memory inside
    !! the copy, an intrinsic assignment of allocatable components, aborts the process.
    TYPE(C_PTR), VALUE :: handle
    INTEGER(C_INT), INTENT(OUT) :: err_stat
    TYPE(CD_C_Handle), POINTER :: h
    INTEGER :: stat

    IF (.NOT. query_ready(handle, h, 'CableDyn_SaveState', err_stat)) RETURN
    ! the slot is invalid while it is overwritten, and stays so if its allocation fails
    h%has_saved = .FALSE.
    IF (h%use_agg) THEN
      IF (.NOT. ALLOCATED(h%saved_agg)) THEN
        ! On the heap, as the live aggregate: the host chooses this thread's stack size.
        ALLOCATE (h%saved_agg, STAT=stat)
        IF (stat /= 0) THEN
          CALL set_status(h, CD_C_ALLOC_FAIL, 'CableDyn_SaveState: save slot allocation failed', err_stat)
          RETURN
        END IF
      END IF
      CALL copy_aggregate(h%agg, h%saved_agg)
      h%saved_agg_t = h%agg_t
      h%saved_fluid_ready = h%fluid_ready
      ! the host's rotations are the inputs of the saved instant (CableDyn_UpdateRotations)
      IF (h%host_rot) THEN
        h%saved_dcm = h%agg_dcm
        h%saved_om = h%agg_om
        h%saved_al = h%agg_al
      END IF
    ELSE
      CALL copy_point_system(h%fast, h%saved_fast)
    END IF
    h%has_saved = .TRUE.
    CALL store_status(h, CD_C_OK, '')
    err_stat = CD_C_OK
  END SUBROUTINE CableDyn_SaveState

  SUBROUTINE CableDyn_RestoreState(handle, err_stat) BIND(C, NAME='CableDyn_RestoreState')
    !! Return the model to the last CableDyn_SaveState. The slot is kept, so one save serves any
    !! number of restores (one per outer corrector). A restore followed by a step is
    !! bit-identical to taking that step from the saved state without the intervening steps.
    TYPE(C_PTR), VALUE :: handle
    INTEGER(C_INT), INTENT(OUT) :: err_stat
    TYPE(CD_C_Handle), POINTER :: h

    IF (.NOT. query_ready(handle, h, 'CableDyn_RestoreState', err_stat)) RETURN
    IF (.NOT. h%has_saved) THEN
      CALL set_status(h, CD_C_BAD_INPUT, 'CableDyn_RestoreState: no state has been saved since the model was '// &
                      'initialized', err_stat)
      RETURN
    END IF
    IF (h%use_agg) THEN
      CALL copy_aggregate(h%saved_agg, h%agg)
      h%agg_t = h%saved_agg_t
      h%fluid_ready = h%saved_fluid_ready
      IF (h%host_rot) THEN
        h%agg_dcm = h%saved_dcm
        h%agg_om = h%saved_om
        h%agg_al = h%saved_al
      END IF
    ELSE
      CALL copy_point_system(h%saved_fast, h%fast)
    END IF
    CALL store_status(h, CD_C_OK, '')
    err_stat = CD_C_OK
  END SUBROUTINE CableDyn_RestoreState

  SUBROUTINE CableDyn_GetCoupledLayout(handle, point_id_ptr, point_type_ptr, n_block, err_stat) &
    BIND(C, NAME='CableDyn_GetCoupledLayout')
    !! The owner of each 3-DOF block of the coupled vector: block k (0-based, DOFs 3k .. 3k+2)
    !! moves deck point point_id[k], of type point_type[k] (1 Fixed, 2 Coupled/Vessel, 3 Free,
    !! 4 Connect). The host drives the type-2 blocks; the others take the values last returned
    !! by CableDyn_GetCoupledMotion. n_block must equal CableDyn_NCoupledDOF / 3; a null pointer
    !! skips that output. A raw-array handle has no deck points (its coupled vector is the
    !! caller's own fixed-DOF list) and is rejected with CD_C_BAD_INPUT.
    TYPE(C_PTR), VALUE :: handle, point_id_ptr, point_type_ptr
    INTEGER(C_INT), VALUE :: n_block
    INTEGER(C_INT), INTENT(OUT) :: err_stat
    TYPE(CD_C_Handle), POINTER :: h
    INTEGER(C_INT), POINTER :: out_c(:)
    INTEGER, ALLOCATABLE :: ids(:), types(:)

    IF (.NOT. query_ready(handle, h, 'CableDyn_GetCoupledLayout', err_stat)) RETURN
    CALL coupled_layout(h, ids, types, err_stat)
    IF (err_stat /= CD_C_OK) RETURN
    IF (INT(n_block) /= SIZE(ids)) THEN
      CALL set_status(h, CD_C_BAD_INPUT, 'CableDyn_GetCoupledLayout: n_block does not match '// &
                      'CableDyn_NCoupledDOF / 3', err_stat)
      RETURN
    END IF
    IF (SIZE(ids) > 0 .AND. C_ASSOCIATED(point_id_ptr)) THEN
      CALL C_F_POINTER(point_id_ptr, out_c, [SIZE(ids)])
      out_c = INT(ids, C_INT)
    END IF
    IF (SIZE(ids) > 0 .AND. C_ASSOCIATED(point_type_ptr)) THEN
      CALL C_F_POINTER(point_type_ptr, out_c, [SIZE(types)])
      out_c = INT(types, C_INT)
    END IF
    CALL store_status(h, CD_C_OK, '')
  END SUBROUTINE CableDyn_GetCoupledLayout

  ! ---------------------------------------------------------------------------------------
  ! Host rotations (C ABI 1, minor extension 3): CableDyn_InitDeckRotating (above, with
  ! InitDeckAt), the rotation of each coupled block, and the coupled moments.
  ! ---------------------------------------------------------------------------------------

  SUBROUTINE CableDyn_UpdateRotations(handle, dcm_ptr, omega_ptr, alpha_ptr, n_block, err_stat) &
    BIND(C, NAME='CableDyn_UpdateRotations')
    !! The host's rotation of each 3-DOF block k of the coupled vector, for the following
    !! CableDyn_UpdateStates and CableDyn_Step calls (kept until the next call): dcm[9k + 3i + j]
    !! = R_ij of the global-to-body DCM (row-major; rows are the body axes in global axes, the
    !! OpenFAST mesh orientation), omega[3k + i] and alpha[3k + i] the body's angular velocity
    !! and acceleration in global axes. The body is the host part the coupled point is fixed to,
    !! with its axes on the deck's axes at the static start (identity). A finite-EI line's
    !! host-driven end turns with it; the other blocks take no rotation (their entries are
    !! checked and not used). n_block must equal CableDyn_NCoupledDOF / 3. Only a handle
    !! initialised by CableDyn_InitDeckRotating takes rotations. The call is all or nothing: a
    !! rejected input (a DCM that is not finite and proper orthogonal to 1e-8, non-finite rates)
    !! leaves the rotations unchanged.
    TYPE(C_PTR), VALUE :: handle, dcm_ptr, omega_ptr, alpha_ptr
    INTEGER(C_INT), VALUE :: n_block
    INTEGER(C_INT), INTENT(OUT) :: err_stat
    TYPE(CD_C_Handle), POINTER :: h
    REAL(C_DOUBLE), POINTER :: dcm_c(:), om_c(:), al_c(:)
    REAL(wp) :: r(3, 3), gram(3, 3), det
    INTEGER :: n, k, i, j

    IF (.NOT. query_ready(handle, h, 'CableDyn_UpdateRotations', err_stat)) RETURN
    IF (.NOT. h%host_rot) THEN
      CALL set_status(h, CD_C_BAD_INPUT, 'CableDyn_UpdateRotations: the handle takes no rotations (initialise it '// &
                      'with CableDyn_InitDeckRotating)', err_stat)
      RETURN
    END IF
    IF (n_block < 0_C_INT .OR. 9_INT64*INT(n_block, INT64) > INT(HUGE(n_block), INT64)) THEN
      CALL set_status(h, CD_C_BAD_INPUT, 'CableDyn_UpdateRotations: n_block does not match '// &
                      'CableDyn_NCoupledDOF / 3', err_stat)
      RETURN
    END IF
    IF (.NOT. valid_coupled_dof_count(h, 3_C_INT*n_block, err_stat)) THEN
      IF (err_stat == CD_C_BAD_INPUT) CALL set_status(h, CD_C_BAD_INPUT, 'CableDyn_UpdateRotations: n_block '// &
                                                      'does not match CableDyn_NCoupledDOF / 3', err_stat)
      RETURN
    END IF
    n = INT(n_block)
    IF (n == 0) THEN
      CALL store_status(h, CD_C_OK, '')
      err_stat = CD_C_OK
      RETURN
    END IF
    IF (.NOT. (C_ASSOCIATED(dcm_ptr) .AND. C_ASSOCIATED(omega_ptr) .AND. C_ASSOCIATED(alpha_ptr))) THEN
      CALL set_status(h, CD_C_BAD_INPUT, 'CableDyn_UpdateRotations: input pointer is null', err_stat)
      RETURN
    END IF
    CALL C_F_POINTER(dcm_ptr, dcm_c, [9*n])
    CALL C_F_POINTER(omega_ptr, om_c, [3*n])
    CALL C_F_POINTER(alpha_ptr, al_c, [3*n])
    IF (.NOT. (ALL(IEEE_IS_FINITE(dcm_c)) .AND. ALL(IEEE_IS_FINITE(om_c)) .AND. ALL(IEEE_IS_FINITE(al_c)))) THEN
      CALL set_status(h, CD_C_BAD_INPUT, 'CableDyn_UpdateRotations: rotations must be finite', err_stat)
      RETURN
    END IF
    ! every block is checked before any is stored (the aggregate's own test of its orientations)
    DO k = 1, n
      DO i = 1, 3
        DO j = 1, 3
          r(i, j) = REAL(dcm_c(9*(k - 1) + 3*(i - 1) + j), wp)
        END DO
      END DO
      gram = MATMUL(r, TRANSPOSE(r))
      DO i = 1, 3
        gram(i, i) = gram(i, i) - CD_ONE
      END DO
      det = r(1, 1)*(r(2, 2)*r(3, 3) - r(2, 3)*r(3, 2)) - r(1, 2)*(r(2, 1)*r(3, 3) - r(2, 3)*r(3, 1)) + &
            r(1, 3)*(r(2, 1)*r(3, 2) - r(2, 2)*r(3, 1))
      IF (MAXVAL(ABS(gram)) > 1.0e-8_wp .OR. ABS(det - CD_ONE) > 1.0e-8_wp) THEN
        CALL set_status(h, CD_C_BAD_INPUT, 'CableDyn_UpdateRotations: the DCM of block '//TRIM(int_text(k - 1))// &
                        ' is not proper orthogonal', err_stat)
        RETURN
      END IF
    END DO
    IF (h%use_agg) THEN
      DO k = 1, n
        DO i = 1, 3
          DO j = 1, 3
            h%agg_dcm(i, j, k) = REAL(dcm_c(9*(k - 1) + 3*(i - 1) + j), wp)
          END DO
        END DO
        h%agg_om(:, k) = REAL(om_c(3*k - 2:3*k), wp)
        h%agg_al(:, k) = REAL(al_c(3*k - 2:3*k), wp)
      END DO
    END IF
    CALL store_status(h, CD_C_OK, '')
    err_stat = CD_C_OK
  END SUBROUTINE CableDyn_UpdateRotations

  SUBROUTINE CableDyn_GetCoupledMoments(handle, moments_ptr, n_coupled_dof, err_stat) &
    BIND(C, NAME='CableDyn_GetCoupledMoments')
    !! The moment each 3-DOF block of the coupled vector applies to the host, about the coupled
    !! point in global axes, at the state CableDyn_CalcOutput reports: a finite-EI line's
    !! torsional and bending reaction at its host-driven end (a line restrained in torsion, a
    !! Rigid or spring bending END CONNECTION), zero for the other blocks and on the point
    !! route. n_coupled_dof must equal CableDyn_NCoupledDOF.
    TYPE(C_PTR), VALUE :: handle, moments_ptr
    INTEGER(C_INT), VALUE :: n_coupled_dof
    INTEGER(C_INT), INTENT(OUT) :: err_stat
    TYPE(CD_C_Handle), POINTER :: h
    REAL(C_DOUBLE), POINTER :: moments_c(:)
    INTEGER :: es
    CHARACTER(CD_C_MSG_LEN) :: em

    IF (.NOT. query_ready(handle, h, 'CableDyn_GetCoupledMoments', err_stat)) RETURN
    IF (.NOT. valid_coupled_dof_count(h, n_coupled_dof, err_stat)) RETURN
    IF (n_coupled_dof == 0_C_INT) THEN
      CALL store_status(h, CD_C_OK, '')
      err_stat = CD_C_OK
      RETURN
    END IF
    IF (.NOT. C_ASSOCIATED(moments_ptr)) THEN
      CALL set_status(h, CD_C_BAD_INPUT, 'CableDyn_GetCoupledMoments: moments pointer is null', err_stat)
      RETURN
    END IF
    CALL C_F_POINTER(moments_ptr, moments_c, [INT(n_coupled_dof)])
    moments_c = 0.0_C_DOUBLE
    IF (.NOT. h%use_agg) THEN
      CALL store_status(h, CD_C_OK, '')
      err_stat = CD_C_OK
      RETURN
    END IF
    CALL CD_AGG_CalcOutput(h%agg, es, em)
    IF (es == CD_AGG_OK) CALL CD_AGG_GetMovingPointMesh(h%agg, h%agg_pos, h%agg_vel, h%agg_acc, h%agg_load, es, em, &
                                                        moment=h%agg_moment)
    IF (es == CD_AGG_OK) moments_c = REAL(RESHAPE(h%agg_moment, [INT(n_coupled_dof)]), C_DOUBLE)
    CALL map_agg_status(es, err_stat)
    CALL store_status(h, err_stat, em)
  END SUBROUTINE CableDyn_GetCoupledMoments

  SUBROUTINE coupled_layout(h, ids, types, err_stat)
    !! Deck point id and point type (the CD_POINT_* codes) of each coupled block. Point route:
    !! the line-bound points of every type in deck POINT order. Aggregate route: the moving
    !! points, i.e. the EI=0-bound Coupled/Vessel points in deck POINT order, then the fairlead
    !! (End A, which the coupled cable builder requires to be Coupled/Vessel) of each finite-EI
    !! line in deck LINE order, then the moving End B of each finite-EI line between two moving
    !! points, in deck LINE order (cable_col_b).
    TYPE(CD_C_Handle), POINTER, INTENT(INOUT) :: h
    INTEGER, ALLOCATABLE, INTENT(OUT) :: ids(:), types(:)
    INTEGER(C_INT), INTENT(OUT) :: err_stat
    INTEGER, ALLOCATABLE :: blocks(:)
    INTEGER :: es, i, k, nm, nsys
    CHARACTER(CD_C_MSG_LEN) :: em

    err_stat = CD_C_OK
    IF (.NOT. h%use_agg) THEN
      CALL CD_Get_System_PointBlocks(h%fast%system, blocks, es, em)
      IF (es /= CD_SYSTEM_OK) THEN
        CALL set_status(h, CD_C_SOLVE_FAIL, 'CableDyn_GetCoupledLayout: '//TRIM(em), err_stat)
        RETURN
      END IF
      IF (.NOT. ALLOCATED(blocks)) THEN
        CALL set_status(h, CD_C_BAD_INPUT, 'CableDyn_GetCoupledLayout: a handle initialized from raw arrays '// &
                        'has no deck points; its coupled vector is the caller''s fixed-DOF list', err_stat)
        RETURN
      END IF
      IF (ANY(blocks < 1)) THEN
        CALL set_status(h, CD_C_SOLVE_FAIL, 'CableDyn_GetCoupledLayout: a coupled block has no owning point', &
                        err_stat)
        RETURN
      END IF
      ALLOCATE (ids(SIZE(blocks)), types(SIZE(blocks)))
      ids = h%fast%system%points(blocks)%id
      types = h%fast%system%points(blocks)%point_type
      RETURN
    END IF
    nm = CD_AGG_NMovingPoints(h%agg, es, em)
    nsys = 0
    IF (h%agg%has_sys) nsys = h%agg%ncp_sys
    IF (es /= CD_AGG_OK .OR. nm /= nsys + h%agg%ncable + h%agg%ncable_b) THEN
      CALL set_status(h, CD_C_SOLVE_FAIL, 'CableDyn_GetCoupledLayout: the moving points of the model are not '// &
                      'its Coupled points and cable ends', err_stat)
      RETURN
    END IF
    ALLOCATE (ids(nm), types(nm))
    IF (nsys > 0) THEN
      CALL CD_Get_System_PointBlocks(h%agg%sys%fast%system, blocks, es, em)
      IF (es /= CD_SYSTEM_OK .OR. .NOT. ALLOCATED(blocks)) THEN
        CALL set_status(h, CD_C_SOLVE_FAIL, 'CableDyn_GetCoupledLayout: the system layout is unavailable', err_stat)
        RETURN
      END IF
      DO i = 1, nsys
        k = blocks(h%agg%sys%moving_blocks(i))
        ids(i) = h%agg%sys%fast%system%points(k)%id
        types(i) = h%agg%sys%fast%system%points(k)%point_type
      END DO
    END IF
    DO i = 1, h%agg%ncable
      ids(nsys + i) = h%agg%cable_points(1, i)
      types(nsys + i) = CD_POINT_COUPLED
      ! a line between two moving points: its End B has a block of its own
      IF (h%agg%cable_col_b(i) > 0) THEN
        ids(h%agg%cable_col_b(i)) = h%agg%cable_points(2, i)
        types(h%agg%cable_col_b(i)) = CD_POINT_COUPLED
      END IF
    END DO
  END SUBROUTINE coupled_layout

  LOGICAL FUNCTION query_ready(handle, h, caller, err_stat) RESULT(ready)
    !! Validate the handle of an object query and require an initialized model.
    TYPE(C_PTR), VALUE :: handle
    TYPE(CD_C_Handle), POINTER, INTENT(OUT) :: h
    CHARACTER(*), INTENT(IN) :: caller
    INTEGER(C_INT), INTENT(OUT) :: err_stat
    LOGICAL :: init

    ready = .FALSE.
    err_stat = validate_handle(handle, h)
    IF (err_stat /= CD_C_OK) RETURN
    IF (h%use_agg) THEN
      init = CD_AGG_IsInitialized(h%agg)
    ELSE
      init = CD_FAST_IsInitialized(h%fast)
    END IF
    IF (.NOT. init) THEN
      CALL set_status(h, CD_C_NOT_INITIALIZED, caller//': handle is not initialized', err_stat)
      RETURN
    END IF
    ready = .TRUE.
  END FUNCTION query_ready

  SUBROUTINE line_at_index(h, index, line_id, nnode)
    !! Deck id and node count of entry `index` (0-based) of the line inventory (ascending deck id,
    !! object_inventory's order) without building it; line_id = 0 when there is no such entry.
    TYPE(CD_C_Handle), POINTER, INTENT(INOUT) :: h
    INTEGER, INTENT(IN) :: index
    INTEGER, INTENT(OUT) :: line_id, nnode

    line_id = 0
    nnode = 0
    IF (h%use_agg) THEN
      CALL find_line(h%agg%line_is_cable, h%agg%line_obj_index)
    ELSE
      CALL find_line(h%pt_is_cable, h%pt_obj)
    END IF

  CONTAINS

    SUBROUTINE find_line(is_cable, obj_index)
      LOGICAL, ALLOCATABLE, INTENT(IN) :: is_cable(:)
      INTEGER, ALLOCATABLE, INTENT(IN) :: obj_index(:)
      INTEGER :: k, n
      IF (index < 0 .OR. .NOT. (ALLOCATED(obj_index) .AND. ALLOCATED(is_cable))) RETURN
      n = -1
      DO k = 1, SIZE(obj_index)
        IF (obj_index(k) < 1) CYCLE
        n = n + 1
        IF (n /= index) CYCLE
        line_id = k
        nnode = line_node_count(h, is_cable(k), obj_index(k))
        RETURN
      END DO
    END SUBROUTINE find_line
  END SUBROUTINE line_at_index

  INTEGER FUNCTION line_node_count(h, is_cable, obj) RESULT(nnode)
    !! Node count of a line of the handle's model: cable or system line obj.
    TYPE(CD_C_Handle), POINTER, INTENT(INOUT) :: h
    LOGICAL, INTENT(IN) :: is_cable
    INTEGER, INTENT(IN) :: obj
    INTEGER :: es
    CHARACTER(CD_C_MSG_LEN) :: em

    IF (is_cable) THEN
      nnode = h%agg%cables(obj)%line%nn
    ELSE IF (h%use_agg) THEN
      nnode = CD_System_Line_NDOF(h%agg%sys%fast%system, obj, es, em)/3
    ELSE
      nnode = CD_System_Line_NDOF(h%fast%system, obj, es, em)/3
    END IF
  END FUNCTION line_node_count

  LOGICAL FUNCTION line_work_ready(h, nnode) RESULT(ready)
    !! Make the handle's line workspace hold nnode values; it only ever grows.
    TYPE(CD_C_Handle), POINTER, INTENT(INOUT) :: h
    INTEGER, INTENT(IN) :: nnode
    INTEGER :: ios

    ready = .TRUE.
    IF (ALLOCATED(h%line_work)) THEN
      IF (SIZE(h%line_work) >= nnode) RETURN
      DEALLOCATE (h%line_work)
    END IF
    ALLOCATE (h%line_work(nnode), STAT=ios)
    ready = ios == 0
  END FUNCTION line_work_ready

  SUBROUTINE line_value_failure(h, line_id, quantity, value_index, err_stat)
    !! Evaluate value value_index (1-based, in the array of CableDyn_GetLineValues) through its
    !! channel, which sets the status and the message of a failed or non-finite node value.
    TYPE(CD_C_Handle), POINTER, INTENT(INOUT) :: h
    INTEGER, INTENT(IN) :: line_id, value_index
    INTEGER(C_INT), INTENT(IN) :: quantity
    INTEGER(C_INT), INTENT(OUT) :: err_stat
    INTEGER :: node, c
    REAL(wp) :: val
    CHARACTER(CD_DECK_NAMELEN) :: token, stem
    CHARACTER(1), PARAMETER :: xyz(3) = ['x', 'y', 'z']

    node = value_index
    c = 1
    IF (quantity == CD_C_LINE_POSITION .OR. quantity == CD_C_LINE_VELOCITY .OR. &
        quantity == CD_C_LINE_ACCELERATION) THEN
      node = (value_index - 1)/3 + 1
      c = value_index - 3*(node - 1)
    END IF
    stem = TRIM(int_text(line_id))//'N'//TRIM(int_text(node))
    SELECT CASE (quantity)
    CASE (CD_C_LINE_POSITION)
      token = 'L'//TRIM(stem)//'p'//xyz(c)
    CASE (CD_C_LINE_VELOCITY)
      token = 'L'//TRIM(stem)//'v'//xyz(c)
    CASE (CD_C_LINE_ACCELERATION)
      token = 'L'//TRIM(stem)//'a'//xyz(c)
    CASE (CD_C_LINE_TENSION)
      token = 'Ten'//TRIM(stem)
    CASE (CD_C_LINE_CURVATURE)
      token = 'Curv'//TRIM(stem)
    CASE (CD_C_LINE_BEND_MOMENT)
      token = 'BendMom'//TRIM(stem)
    CASE (CD_C_LINE_DECLINATION)
      token = 'L'//TRIM(stem)//'Dec'
    CASE DEFAULT
      token = 'L'//TRIM(stem)//'Azi'
    END SELECT
    CALL eval_token(h, token, val, err_stat, mesh_node=.TRUE.)
  END SUBROUTINE line_value_failure

  SUBROUTINE object_inventory(h, kind, ids, nnodes, sub, err_stat)
    !! The handle's objects of one kind: deck ids, node counts and subtypes. Lines are listed in
    !! ascending deck id, points in system order, bodies and rods in runtime order.
    TYPE(CD_C_Handle), POINTER, INTENT(INOUT) :: h
    INTEGER, INTENT(IN) :: kind
    INTEGER, ALLOCATABLE, INTENT(OUT) :: ids(:), nnodes(:), sub(:)
    INTEGER(C_INT), INTENT(OUT) :: err_stat
    INTEGER, ALLOCATABLE :: body_ids(:), rod_ids(:), rod_nsegs(:)

    err_stat = CD_C_OK
    SELECT CASE (kind)
    CASE (CD_C_OBJ_LINE)
      IF (h%use_agg) THEN
        CALL collect_lines(h%agg%line_is_cable, h%agg%line_obj_index)
      ELSE
        CALL collect_lines(h%pt_is_cable, h%pt_obj)
      END IF
    CASE (CD_C_OBJ_POINT)
      IF (.NOT. h%use_agg) THEN
        CALL collect_points(h%fast%system)
      ELSE IF (h%agg%has_sys) THEN
        CALL collect_points(h%agg%sys%fast%system)
      ELSE
        ALLOCATE (ids(0), nnodes(0), sub(0))
      END IF
    CASE (CD_C_OBJ_BODY)
      IF (h%use_agg .AND. h%agg%has_rigid6) THEN
        CALL CD_Rigid6_Inventory(h%agg%rigid6, body_ids, rod_ids, rod_nsegs)
        CALL MOVE_ALLOC(body_ids, ids)
      ELSE
        ALLOCATE (ids(0))
      END IF
      ALLOCATE (nnodes(SIZE(ids)), sub(SIZE(ids)))
      nnodes = 1
      sub = 0
    CASE (CD_C_OBJ_ROD)
      IF (h%use_agg .AND. h%agg%has_rigid6) THEN
        CALL CD_Rigid6_Inventory(h%agg%rigid6, body_ids, ids, rod_nsegs)
      ELSE IF (h%use_agg .AND. h%agg%has_rod) THEN
        CALL CD_Rod_Inventory(h%agg%rod, ids, rod_nsegs)
      ELSE
        ALLOCATE (ids(0), rod_nsegs(0))
      END IF
      ALLOCATE (nnodes(SIZE(ids)), sub(SIZE(ids)))
      nnodes = rod_nsegs + 1
      sub = 0
    CASE DEFAULT
      ALLOCATE (ids(0), nnodes(0), sub(0))
      CALL set_status(h, CD_C_BAD_INPUT, 'CableDyn C API: unknown object kind', err_stat)
    END SELECT

  CONTAINS

    SUBROUTINE collect_lines(is_cable, obj_index)
      LOGICAL, ALLOCATABLE, INTENT(IN) :: is_cable(:)
      INTEGER, ALLOCATABLE, INTENT(IN) :: obj_index(:)
      INTEGER :: k, n, obj
      IF (.NOT. (ALLOCATED(obj_index) .AND. ALLOCATED(is_cable))) THEN
        ALLOCATE (ids(0), nnodes(0), sub(0))
        RETURN
      END IF
      n = COUNT(obj_index > 0)
      ALLOCATE (ids(n), nnodes(n), sub(n))
      n = 0
      DO k = 1, SIZE(obj_index)
        obj = obj_index(k)
        IF (obj < 1) CYCLE
        n = n + 1
        ids(n) = k
        sub(n) = MERGE(1, 0, is_cable(k))
        nnodes(n) = line_node_count(h, is_cable(k), obj)
      END DO
    END SUBROUTINE collect_lines

    SUBROUTINE collect_points(system)
      TYPE(CD_SystemType), INTENT(IN) :: system
      INTEGER :: n
      IF (.NOT. ALLOCATED(system%points)) THEN
        ALLOCATE (ids(0), nnodes(0), sub(0))
        RETURN
      END IF
      n = SIZE(system%points)
      ALLOCATE (ids(n), nnodes(n), sub(n))
      ids = system%points(:)%id
      nnodes = 1
      sub = system%points(:)%point_type
    END SUBROUTINE collect_points
  END SUBROUTINE object_inventory

  SUBROUTINE eval_token(h, token, val, err_stat, mesh_node)
    !! Evaluate one channel token on the handle's model (aggregate or point route). A node token
    !! names a deck node; mesh_node = .TRUE. reads it as a node of the line's final mesh instead
    !! (CableDyn_GetLineValues lists every mesh node of a refined finite-EI line).
    TYPE(CD_C_Handle), POINTER, INTENT(INOUT) :: h
    CHARACTER(*), INTENT(IN) :: token
    REAL(wp), INTENT(OUT) :: val
    INTEGER(C_INT), INTENT(OUT) :: err_stat
    LOGICAL, INTENT(IN), OPTIONAL :: mesh_node
    INTEGER :: es
    CHARACTER(CD_C_MSG_LEN) :: em

    val = 0.0_wp
    IF (h%use_agg) THEN
      IF (h%agg%has_rigid6) THEN
        CALL CD_Eval_Aggregate_Channel(token, h%agg%has_sys, h%agg%sys%fast%system, h%agg%cables, &
                                       h%agg%line_is_cable, h%agg%line_obj_index, val, es, em, &
                                       cable_points=h%agg%cable_points, rigid_rt=h%agg%rigid6, ranges=h%agg%ranges, &
                                       mesh_node=mesh_node)
      ELSE IF (h%agg%has_rod) THEN
        CALL CD_Eval_Aggregate_Channel(token, h%agg%has_sys, h%agg%sys%fast%system, h%agg%cables, &
                                       h%agg%line_is_cable, h%agg%line_obj_index, val, es, em, &
                                       cable_points=h%agg%cable_points, rod_rt=h%agg%rod, ranges=h%agg%ranges, &
                                       mesh_node=mesh_node)
      ELSE
        CALL CD_Eval_Aggregate_Channel(token, h%agg%has_sys, h%agg%sys%fast%system, h%agg%cables, &
                                       h%agg%line_is_cable, h%agg%line_obj_index, val, es, em, &
                                       cable_points=h%agg%cable_points, ranges=h%agg%ranges, &
                                       mesh_node=mesh_node)
      END IF
    ELSE
      IF (.NOT. (ALLOCATED(h%pt_obj) .AND. ALLOCATED(h%pt_is_cable))) THEN
        CALL set_status(h, CD_C_NOT_INITIALIZED, 'CableDyn C API: the handle has no line inventory', err_stat)
        RETURN
      END IF
      CALL CD_Eval_Aggregate_Channel(token, .TRUE., h%fast%system, h%no_cables, h%pt_is_cable, h%pt_obj, &
                                     val, es, em)
    END IF
    CALL map_deck_status(es, err_stat)
    IF (err_stat /= CD_C_OK) THEN
      CALL store_status(h, err_stat, TRIM(em))
    ELSE IF (.NOT. IEEE_IS_FINITE(val)) THEN
      CALL set_status(h, CD_C_SOLVE_FAIL, 'CableDyn C API: channel "'//TRIM(token)//'" is not finite', err_stat)
    END IF
  END SUBROUTINE eval_token

  SUBROUTINE eval_six(h, prefix, lin, ang, has_third_angle, out_ptr, err_stat)
    !! Fill a 6-vector [<lin>x, <lin>y, <lin>z, <ang>x, <ang>y, <ang>z] of object channels; a null
    !! pointer is a no-op. has_third_angle = .FALSE. (a rod's R, which has no yaw) sets the sixth
    !! entry to zero.
    TYPE(CD_C_Handle), POINTER, INTENT(INOUT) :: h
    CHARACTER(*), INTENT(IN) :: prefix, lin, ang
    LOGICAL, INTENT(IN) :: has_third_angle
    TYPE(C_PTR), VALUE :: out_ptr
    INTEGER(C_INT), INTENT(OUT) :: err_stat
    REAL(C_DOUBLE), POINTER :: out_c(:)
    CHARACTER(1), PARAMETER :: xyz(3) = ['x', 'y', 'z']
    INTEGER :: c
    REAL(wp) :: val

    err_stat = CD_C_OK
    IF (.NOT. C_ASSOCIATED(out_ptr)) RETURN
    CALL C_F_POINTER(out_ptr, out_c, [6])
    out_c = 0.0_C_DOUBLE
    DO c = 1, 3
      CALL eval_token(h, TRIM(prefix)//lin//xyz(c), val, err_stat)
      IF (err_stat /= CD_C_OK) RETURN
      out_c(c) = REAL(val, C_DOUBLE)
    END DO
    DO c = 1, 3
      IF (c == 3 .AND. .NOT. has_third_angle) EXIT
      CALL eval_token(h, TRIM(prefix)//ang//xyz(c), val, err_stat)
      IF (err_stat /= CD_C_OK) RETURN
      out_c(3 + c) = REAL(val, C_DOUBLE)
    END DO
  END SUBROUTINE eval_six

  SUBROUTINE set_point_line_map(h, line_ids)
    !! Record the point route's line inventory: the deck-line-id -> system-line map (system
    !! line k carries deck id line_ids(k)) the shared channel evaluator resolves tokens through.
    TYPE(CD_C_Handle), POINTER, INTENT(INOUT) :: h
    INTEGER, INTENT(IN) :: line_ids(:)
    INTEGER :: k, maxid

    CALL clear_point_line_map(h)
    maxid = 1
    IF (SIZE(line_ids) > 0) maxid = MAX(1, MAXVAL(line_ids))
    ALLOCATE (h%pt_is_cable(maxid), h%pt_obj(maxid))
    h%pt_is_cable = .FALSE.
    h%pt_obj = 0
    DO k = 1, SIZE(line_ids)
      IF (line_ids(k) >= 1) h%pt_obj(line_ids(k)) = k
    END DO
  END SUBROUTINE set_point_line_map

  SUBROUTINE clear_point_line_map(h)
    TYPE(CD_C_Handle), POINTER, INTENT(INOUT) :: h
    IF (ALLOCATED(h%pt_is_cable)) DEALLOCATE (h%pt_is_cable)
    IF (ALLOCATED(h%pt_obj)) DEALLOCATE (h%pt_obj)
  END SUBROUTINE clear_point_line_map

  PURE FUNCTION int_text(i) RESULT(s)
    !! Decimal text of a non-negative id (no formatted I/O: the queries stay I/O-free).
    INTEGER, INTENT(IN) :: i
    CHARACTER(12) :: s
    INTEGER :: v, k
    CHARACTER(12) :: rev

    s = ''
    rev = ''
    v = MAX(0, i)
    k = 0
    DO
      k = k + 1
      rev(k:k) = ACHAR(IACHAR('0') + MOD(v, 10))
      v = v/10
      IF (v == 0 .OR. k == 12) EXIT
    END DO
    DO v = 1, k
      s(v:v) = rev(k - v + 1:k - v + 1)
    END DO
  END FUNCTION int_text

  INTEGER(C_INT) FUNCTION validate_handle(handle, h) RESULT(err_stat)
    !! The single handle validator used by every public entry point. A handle is
    !! accepted ONLY if (1) it is non-null, (2) it is in the live-handle registry --
    !! so a foreign, stale, or double-closed pointer is rejected before any
    !! dereference -- and (3) the target's magic word is intact. On any failure h is
    !! nullified and CD_C_BAD_HANDLE is returned.
    TYPE(C_PTR), VALUE :: handle
    TYPE(CD_C_Handle), POINTER, INTENT(OUT) :: h

    h => NULL()
    err_stat = CD_C_BAD_HANDLE
    IF (.NOT. C_ASSOCIATED(handle)) RETURN
    IF (.NOT. registry_contains(handle)) RETURN
    CALL C_F_POINTER(handle, h)
    IF (h%magic /= CD_C_HANDLE_MAGIC) THEN
      h => NULL()
      RETURN
    END IF
    err_stat = CD_C_OK
  END FUNCTION validate_handle

  SUBROUTINE registry_add(p, stat)
    !! Register a freshly created handle pointer as live. Grows the registry as
    !! needed. stat /= 0 only on an allocation failure.
    TYPE(C_PTR), INTENT(IN) :: p
    INTEGER, INTENT(OUT) :: stat
    TYPE(C_PTR), ALLOCATABLE :: tmp(:)
    stat = 0
    CALL cabledyn_registry_lock()
    IF (.NOT. ALLOCATED(g_handle_registry)) ALLOCATE (g_handle_registry(8), STAT=stat)
    IF (stat == 0) THEN
      IF (g_handle_count == SIZE(g_handle_registry)) THEN
        ALLOCATE (tmp(2*SIZE(g_handle_registry)), STAT=stat)
        IF (stat == 0) THEN
          tmp(1:g_handle_count) = g_handle_registry(1:g_handle_count)
          CALL MOVE_ALLOC(tmp, g_handle_registry)
        END IF
      END IF
    END IF
    IF (stat == 0) THEN
      g_handle_count = g_handle_count + 1
      g_handle_registry(g_handle_count) = p
    END IF
    CALL cabledyn_registry_unlock()
  END SUBROUTINE registry_add

  LOGICAL FUNCTION registry_contains(p) RESULT(found)
    !! True iff p is a currently live handle pointer. Pure lookup; no dereference.
    TYPE(C_PTR), INTENT(IN) :: p
    INTEGER :: i
    found = .FALSE.
    CALL cabledyn_registry_lock()
    IF (ALLOCATED(g_handle_registry)) THEN
      DO i = 1, g_handle_count
        IF (C_ASSOCIATED(g_handle_registry(i), p)) THEN
          found = .TRUE.
          EXIT
        END IF
      END DO
    END IF
    CALL cabledyn_registry_unlock()
  END FUNCTION registry_contains

  LOGICAL FUNCTION registry_claim(p) RESULT(claimed)
    !! Atomically check-and-remove p from the live-handle registry (swap-with-last),
    !! all inside one critical region. Returns .TRUE. to exactly ONE caller -- the one
    !! that removed it -- and .FALSE. to every other (foreign/stale/already-claimed).
    !! This is what makes Close's validate -> remove -> free safe against a concurrent
    !! Close of the same or a copied handle: only the winning claim frees the target,
    !! so there is no double-free window between validation and removal.
    TYPE(C_PTR), INTENT(IN) :: p
    INTEGER :: i
    claimed = .FALSE.
    CALL cabledyn_registry_lock()
    DO i = 1, g_handle_count
      IF (C_ASSOCIATED(g_handle_registry(i), p)) THEN
        g_handle_registry(i) = g_handle_registry(g_handle_count)
        g_handle_count = g_handle_count - 1
        claimed = .TRUE.
        EXIT
      END IF
    END DO
    CALL cabledyn_registry_unlock()
  END FUNCTION registry_claim

  SUBROUTINE coupled_inputs(handle, q_ptr, v_ptr, a_ptr, n_coupled_dof, h, q_c, v_c, a_c, err_stat)
    TYPE(C_PTR), VALUE :: handle, q_ptr, v_ptr, a_ptr
    INTEGER(C_INT), VALUE :: n_coupled_dof
    TYPE(CD_C_Handle), POINTER, INTENT(OUT) :: h
    REAL(C_DOUBLE), POINTER, INTENT(OUT) :: q_c(:), v_c(:), a_c(:)
    INTEGER(C_INT), INTENT(OUT) :: err_stat

    CALL coupled_outputs(handle, q_ptr, v_ptr, a_ptr, n_coupled_dof, h, q_c, v_c, a_c, err_stat)
  END SUBROUTINE coupled_inputs

  SUBROUTINE coupled_outputs(handle, q_ptr, v_ptr, a_ptr, n_coupled_dof, h, q_c, v_c, a_c, err_stat)
    TYPE(C_PTR), VALUE :: handle, q_ptr, v_ptr, a_ptr
    INTEGER(C_INT), VALUE :: n_coupled_dof
    TYPE(CD_C_Handle), POINTER, INTENT(OUT) :: h
    REAL(C_DOUBLE), POINTER, INTENT(OUT) :: q_c(:), v_c(:), a_c(:)
    INTEGER(C_INT), INTENT(OUT) :: err_stat

    err_stat = validate_handle(handle, h)
    IF (err_stat /= CD_C_OK) RETURN
    IF (.NOT. valid_coupled_dof_count(h, n_coupled_dof, err_stat)) RETURN
    IF (n_coupled_dof > 0_C_INT .AND. &
        .NOT. (C_ASSOCIATED(q_ptr) .AND. C_ASSOCIATED(v_ptr) .AND. C_ASSOCIATED(a_ptr))) THEN
      CALL set_status(h, CD_C_BAD_INPUT, 'CableDyn C API: coupled kinematics pointer is null', err_stat)
      RETURN
    END IF
    IF (n_coupled_dof > 0_C_INT) THEN
      CALL C_F_POINTER(q_ptr, q_c, [INT(n_coupled_dof)])
      CALL C_F_POINTER(v_ptr, v_c, [INT(n_coupled_dof)])
      CALL C_F_POINTER(a_ptr, a_c, [INT(n_coupled_dof)])
    END IF
  END SUBROUTINE coupled_outputs

  SUBROUTINE map_fast_status(fast_stat, err_stat)
    INTEGER, INTENT(IN) :: fast_stat
    INTEGER(C_INT), INTENT(OUT) :: err_stat

    SELECT CASE (fast_stat)
    CASE (CD_FAST_OK)
      err_stat = CD_C_OK
    CASE (CD_FAST_BADINPUT)
      err_stat = CD_C_BAD_INPUT
    CASE (CD_FAST_NOT_INITIALIZED)
      err_stat = CD_C_NOT_INITIALIZED
    CASE (CD_FAST_ALLOCFAIL)
      err_stat = CD_C_ALLOC_FAIL
    CASE DEFAULT
      err_stat = CD_C_SOLVE_FAIL
    END SELECT
  END SUBROUTINE map_fast_status

  SUBROUTINE map_deck_status(deck_stat, err_stat)
    INTEGER, INTENT(IN) :: deck_stat
    INTEGER(C_INT), INTENT(OUT) :: err_stat

    SELECT CASE (deck_stat)
    CASE (CD_DECKDRV_OK)
      err_stat = CD_C_OK
    CASE (CD_DECKDRV_BADINPUT)
      err_stat = CD_C_BAD_INPUT
    CASE (CD_DECKDRV_SOLVEFAIL)
      err_stat = CD_C_SOLVE_FAIL
    CASE DEFAULT
      err_stat = CD_C_SOLVE_FAIL
    END SELECT
  END SUBROUTINE map_deck_status

  SUBROUTINE set_model_init_failure(h, context, model_stat, model_msg, err_stat)
    TYPE(CD_C_Handle), POINTER, INTENT(INOUT) :: h
    CHARACTER(*), INTENT(IN) :: context
    INTEGER, INTENT(IN) :: model_stat
    CHARACTER(*), INTENT(IN) :: model_msg
    INTEGER(C_INT), INTENT(OUT) :: err_stat

    INTEGER(C_INT) :: c_stat

    SELECT CASE (model_stat)
    CASE (CD_MODEL_BADINPUT)
      c_stat = CD_C_BAD_INPUT
    CASE (CD_MODEL_ALLOCFAIL)
      c_stat = CD_C_ALLOC_FAIL
    CASE DEFAULT
      c_stat = CD_C_SOLVE_FAIL
    END SELECT
    CALL set_status(h, c_stat, TRIM(context)//': '//TRIM(model_msg), err_stat)
  END SUBROUTINE set_model_init_failure

  LOGICAL FUNCTION valid_coupled_dof_count(h, n_coupled_dof, err_stat) RESULT(ok)
    TYPE(CD_C_Handle), POINTER, INTENT(INOUT) :: h
    INTEGER(C_INT), VALUE :: n_coupled_dof
    INTEGER(C_INT), INTENT(OUT) :: err_stat

    INTEGER :: es, expected
    CHARACTER(CD_C_MSG_LEN) :: em

    ok = .FALSE.
    IF (n_coupled_dof < 0_C_INT) THEN
      CALL set_status(h, CD_C_BAD_INPUT, 'CableDyn C API: coupled DOF count must be non-negative', err_stat)
      RETURN
    END IF
    IF (h%use_agg) THEN
      expected = 3*CD_AGG_NMovingPoints(h%agg, es, em)
      IF (es /= CD_AGG_OK) THEN
        CALL map_agg_status(es, err_stat)
        CALL store_status(h, err_stat, em)
        RETURN
      END IF
    ELSE
      expected = CD_FAST_NCoupledDOF(h%fast, es, em)
      IF (es /= CD_FAST_OK) THEN
        CALL map_fast_status(es, err_stat)
        CALL store_status(h, err_stat, em)
        RETURN
      END IF
    END IF
    IF (INT(n_coupled_dof) /= expected) THEN
      err_stat = CD_C_BAD_INPUT
      CALL store_status(h, err_stat, 'CableDyn C API: coupled DOF count does not match initialized handle')
      RETURN
    END IF
    err_stat = CD_C_OK
    CALL store_status(h, err_stat, '')
    ok = .TRUE.
  END FUNCTION valid_coupled_dof_count

  SUBROUTINE ensure_c_vector_workspace(h, n, need_load, err_stat)
    TYPE(CD_C_Handle), POINTER, INTENT(INOUT) :: h
    INTEGER, INTENT(IN) :: n
    LOGICAL, INTENT(IN) :: need_load
    INTEGER(C_INT), INTENT(OUT) :: err_stat

    INTEGER :: stat
    LOGICAL :: need_q_workspace, need_load_workspace

    err_stat = CD_C_OK
    IF (n < 0) THEN
      CALL set_status(h, CD_C_BAD_INPUT, 'CableDyn C API: workspace size must be non-negative', err_stat)
      RETURN
    END IF
    need_q_workspace = .NOT. ALLOCATED(h%q_work)
    IF (.NOT. need_q_workspace) need_q_workspace = SIZE(h%q_work) < n
    IF (need_q_workspace) THEN
      CALL clear_c_vector_workspace(h)
      ALLOCATE (h%q_work(n), STAT=stat)
      IF (stat /= 0) THEN
        CALL fail_c_workspace_allocation(h, err_stat)
        RETURN
      END IF
      ALLOCATE (h%v_work(n), STAT=stat)
      IF (stat /= 0) THEN
        CALL fail_c_workspace_allocation(h, err_stat)
        RETURN
      END IF
      ALLOCATE (h%a_work(n), STAT=stat)
      IF (stat /= 0) THEN
        CALL fail_c_workspace_allocation(h, err_stat)
        RETURN
      END IF
    END IF
    IF (n > 0) THEN
      h%q_work(1:n) = CD_ZERO
      h%v_work(1:n) = CD_ZERO
      h%a_work(1:n) = CD_ZERO
    END IF
    IF (need_load) THEN
      need_load_workspace = .NOT. ALLOCATED(h%loads_work)
      IF (.NOT. need_load_workspace) need_load_workspace = SIZE(h%loads_work) < n
      IF (need_load_workspace) THEN
        IF (ALLOCATED(h%loads_work)) DEALLOCATE (h%loads_work)
        ALLOCATE (h%loads_work(n), STAT=stat)
        IF (stat /= 0) THEN
          CALL fail_c_workspace_allocation(h, err_stat)
          RETURN
        END IF
      END IF
      IF (n > 0) h%loads_work(1:n) = CD_ZERO
    END IF
  END SUBROUTINE ensure_c_vector_workspace

  SUBROUTINE ensure_c_derivative_workspace(h, n, err_stat)
    TYPE(CD_C_Handle), POINTER, INTENT(INOUT) :: h
    INTEGER, INTENT(IN) :: n
    INTEGER(C_INT), INTENT(OUT) :: err_stat

    INTEGER :: stat
    LOGICAL :: need_derivative_workspace

    CALL ensure_c_vector_workspace(h, n, need_load=.TRUE., err_stat=err_stat)
    IF (err_stat /= CD_C_OK) RETURN
    need_derivative_workspace = .NOT. ALLOCATED(h%jq_work)
    IF (.NOT. need_derivative_workspace) THEN
      need_derivative_workspace = SIZE(h%jq_work, 1) < n .OR. SIZE(h%jq_work, 2) < n
    END IF
    IF (need_derivative_workspace) THEN
      CALL clear_c_derivative_workspace(h)
      ALLOCATE (h%jq_work(n, n), STAT=stat)
      IF (stat /= 0) THEN
        CALL fail_c_workspace_allocation(h, err_stat)
        RETURN
      END IF
      ALLOCATE (h%jv_work(n, n), STAT=stat)
      IF (stat /= 0) THEN
        CALL fail_c_workspace_allocation(h, err_stat)
        RETURN
      END IF
      ALLOCATE (h%ja_work(n, n), STAT=stat)
      IF (stat /= 0) THEN
        CALL fail_c_workspace_allocation(h, err_stat)
        RETURN
      END IF
      ALLOCATE (h%madd_work(n, n), STAT=stat)
      IF (stat /= 0) THEN
        CALL fail_c_workspace_allocation(h, err_stat)
        RETURN
      END IF
    END IF
    IF (n > 0) THEN
      h%jq_work(1:n, 1:n) = CD_ZERO
      h%jv_work(1:n, 1:n) = CD_ZERO
      h%ja_work(1:n, 1:n) = CD_ZERO
      h%madd_work(1:n, 1:n) = CD_ZERO
    END IF
  END SUBROUTINE ensure_c_derivative_workspace

  SUBROUTINE ensure_c_fluid_workspace(h, n_point, err_stat)
    TYPE(CD_C_Handle), POINTER, INTENT(INOUT) :: h
    INTEGER, INTENT(IN) :: n_point
    INTEGER(C_INT), INTENT(OUT) :: err_stat

    INTEGER :: stat
    LOGICAL :: need_fluid_workspace

    err_stat = CD_C_OK
    IF (n_point < 0) THEN
      CALL set_status(h, CD_C_BAD_INPUT, 'CableDyn C API: point workspace size must be non-negative', err_stat)
      RETURN
    END IF
    need_fluid_workspace = .NOT. ALLOCATED(h%fluid_velocity_work)
    IF (.NOT. need_fluid_workspace) need_fluid_workspace = SIZE(h%fluid_velocity_work, 2) < n_point
    IF (need_fluid_workspace) THEN
      CALL clear_c_fluid_workspace(h)
      ALLOCATE (h%fluid_velocity_work(3, n_point), STAT=stat)
      IF (stat /= 0) THEN
        CALL fail_c_workspace_allocation(h, err_stat)
        RETURN
      END IF
      ALLOCATE (h%fluid_acceleration_work(3, n_point), STAT=stat)
      IF (stat /= 0) THEN
        CALL fail_c_workspace_allocation(h, err_stat)
        RETURN
      END IF
      ALLOCATE (h%waterline_work(n_point), STAT=stat)
      IF (stat /= 0) THEN
        CALL fail_c_workspace_allocation(h, err_stat)
        RETURN
      END IF
    END IF
    IF (n_point > 0) THEN
      h%fluid_velocity_work(:, 1:n_point) = CD_ZERO
      h%fluid_acceleration_work(:, 1:n_point) = CD_ZERO
      h%waterline_work(1:n_point) = CD_ZERO
    END IF
  END SUBROUTINE ensure_c_fluid_workspace

  SUBROUTINE fail_c_workspace_allocation(h, err_stat)
    TYPE(CD_C_Handle), POINTER, INTENT(INOUT) :: h
    INTEGER(C_INT), INTENT(OUT) :: err_stat

    CALL clear_c_workspace(h)
    CALL set_status(h, CD_C_ALLOC_FAIL, 'CableDyn C API: workspace allocation failed', err_stat)
  END SUBROUTINE fail_c_workspace_allocation

  SUBROUTINE clear_c_workspace(h)
    TYPE(CD_C_Handle), POINTER, INTENT(INOUT) :: h

    CALL clear_c_vector_workspace(h)
    CALL clear_c_derivative_workspace(h)
    CALL clear_c_fluid_workspace(h)
  END SUBROUTINE clear_c_workspace

  SUBROUTINE clear_c_vector_workspace(h)
    TYPE(CD_C_Handle), POINTER, INTENT(INOUT) :: h

    IF (ALLOCATED(h%q_work)) DEALLOCATE (h%q_work)
    IF (ALLOCATED(h%v_work)) DEALLOCATE (h%v_work)
    IF (ALLOCATED(h%a_work)) DEALLOCATE (h%a_work)
    IF (ALLOCATED(h%loads_work)) DEALLOCATE (h%loads_work)
  END SUBROUTINE clear_c_vector_workspace

  SUBROUTINE clear_c_derivative_workspace(h)
    TYPE(CD_C_Handle), POINTER, INTENT(INOUT) :: h

    IF (ALLOCATED(h%jq_work)) DEALLOCATE (h%jq_work)
    IF (ALLOCATED(h%jv_work)) DEALLOCATE (h%jv_work)
    IF (ALLOCATED(h%ja_work)) DEALLOCATE (h%ja_work)
    IF (ALLOCATED(h%madd_work)) DEALLOCATE (h%madd_work)
  END SUBROUTINE clear_c_derivative_workspace

  SUBROUTINE clear_c_fluid_workspace(h)
    TYPE(CD_C_Handle), POINTER, INTENT(INOUT) :: h

    IF (ALLOCATED(h%fluid_velocity_work)) DEALLOCATE (h%fluid_velocity_work)
    IF (ALLOCATED(h%fluid_acceleration_work)) DEALLOCATE (h%fluid_acceleration_work)
    IF (ALLOCATED(h%waterline_work)) DEALLOCATE (h%waterline_work)
  END SUBROUTINE clear_c_fluid_workspace

  LOGICAL FUNCTION blas_runtime_ready(handle, caller, err_stat) RESULT(ready)
    !! Model initialisation gate for the LAPACK runtime: false, with CD_C_ALLOC_FAIL and
    !! the load diagnostic (library, locations tried, load error) stored on the handle,
    !! when the run-time loaded OpenBLAS is unavailable; false with the validation
    !! status for a bad handle. True otherwise, with err_stat untouched.
    TYPE(C_PTR), VALUE :: handle
    CHARACTER(*), INTENT(IN) :: caller
    INTEGER(C_INT), INTENT(INOUT) :: err_stat

    TYPE(CD_C_Handle), POINTER :: h
    INTEGER :: es
    INTEGER(C_INT) :: vs
    CHARACTER(CD_C_MSG_LEN) :: em

    ready = .FALSE.
    vs = validate_handle(handle, h)
    IF (vs /= CD_C_OK) THEN
      err_stat = vs
      RETURN
    END IF
    CALL CD_Blas_Runtime_Check(caller, es, em)
    IF (es /= CD_LINALG_OK) THEN
      CALL set_status(h, CD_C_ALLOC_FAIL, TRIM(em), err_stat)
      RETURN
    END IF
    ready = .TRUE.
  END FUNCTION blas_runtime_ready

  SUBROUTINE set_status(h, stat, msg, err_stat)
    TYPE(CD_C_Handle), POINTER, INTENT(INOUT) :: h
    INTEGER(C_INT), INTENT(IN) :: stat
    CHARACTER(*), INTENT(IN) :: msg
    INTEGER(C_INT), INTENT(OUT) :: err_stat

    err_stat = stat
    CALL store_status(h, stat, msg)
  END SUBROUTINE set_status

  SUBROUTINE store_status(h, stat, msg)
    TYPE(CD_C_Handle), POINTER, INTENT(INOUT) :: h
    INTEGER(C_INT), INTENT(IN) :: stat
    CHARACTER(*), INTENT(IN) :: msg

    IF (stat == CD_C_OK) THEN
      h%last_error = ''
    ELSE IF (LEN_TRIM(msg) > 0) THEN
      h%last_error = TRIM(msg)
    ELSE
      h%last_error = default_status_message(stat)
    END IF
  END SUBROUTINE store_status

  FUNCTION default_status_message(stat) RESULT(msg)
    INTEGER(C_INT), INTENT(IN) :: stat
    CHARACTER(CD_C_MSG_LEN) :: msg

    SELECT CASE (stat)
    CASE (CD_C_BAD_HANDLE)
      msg = 'CableDyn C API: bad handle'
    CASE (CD_C_ALLOC_FAIL)
      msg = 'CableDyn C API: allocation failed'
    CASE (CD_C_BAD_INPUT)
      msg = 'CableDyn C API: bad input'
    CASE (CD_C_SOLVE_FAIL)
      msg = 'CableDyn C API: solve failed'
    CASE (CD_C_NOT_INITIALIZED)
      msg = 'CableDyn C API: handle is not initialized'
    CASE DEFAULT
      msg = ''
    END SELECT
  END FUNCTION default_status_message

  SUBROUTINE copy_message_to_c(msg, buffer)
    CHARACTER(*), INTENT(IN) :: msg
    CHARACTER(KIND=C_CHAR), INTENT(INOUT) :: buffer(:)

    INTEGER :: i, ncopy

    IF (SIZE(buffer) < 1) RETURN
    buffer = C_NULL_CHAR
    ncopy = MIN(LEN_TRIM(msg), SIZE(buffer) - 1)
    DO i = 1, ncopy
      buffer(i) = msg(i:i)
    END DO
    buffer(ncopy + 1) = C_NULL_CHAR
  END SUBROUTINE copy_message_to_c

  SUBROUTINE init_one_raw_model(model, q0_c, v0_c, elem_c, l0_c, ea_c, rho_a_c, fixed_c, tension_only, cfg, &
                                ErrStat, ErrMsg)
    TYPE(CD_ModelType), INTENT(INOUT) :: model
    REAL(C_DOUBLE), INTENT(IN) :: q0_c(:), v0_c(:), l0_c(:), ea_c(:), rho_a_c(:)
    INTEGER(C_INT), INTENT(IN) :: elem_c(:), fixed_c(:)
    LOGICAL, INTENT(IN) :: tension_only
    TYPE(GenAlphaConfig), INTENT(IN) :: cfg
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg

    REAL(wp), ALLOCATABLE :: q0(:), v0(:), l0(:), ea(:), rho_a(:), f_ext(:)
    INTEGER, ALLOCATABLE :: elem_conn(:, :), fixed_dofs(:)
    INTEGER :: e, n_elem, stat

    n_elem = SIZE(l0_c)
    ALLOCATE (q0(SIZE(q0_c)), v0(SIZE(v0_c)), f_ext(SIZE(q0_c)), &
              l0(n_elem), ea(n_elem), rho_a(n_elem), elem_conn(2, n_elem), fixed_dofs(SIZE(fixed_c)), STAT=stat)
    IF (stat /= 0) THEN
      ErrStat = CD_MODEL_ALLOCFAIL
      ErrMsg = 'CableDyn_CAPI: raw-model temporary allocation failed'
      RETURN
    END IF
    q0 = REAL(q0_c, wp)
    v0 = REAL(v0_c, wp)
    l0 = REAL(l0_c, wp)
    ea = REAL(ea_c, wp)
    rho_a = REAL(rho_a_c, wp)
    f_ext = CD_ZERO
    DO e = 1, n_elem
      elem_conn(:, e) = INT(elem_c(2*e - 1:2*e))
    END DO
    fixed_dofs = INT(fixed_c)
    CALL CD_Init_Model(model, q0, v0, elem_conn, l0, ea, rho_a, tension_only, f_ext, fixed_dofs, cfg, &
                       ErrStat, ErrMsg)
  END SUBROUTINE init_one_raw_model

  SUBROUTINE end_temp_models(models)
    TYPE(CD_ModelType), INTENT(INOUT) :: models(:)
    INTEGER :: i, es
    CHARACTER(1024) :: em

    DO i = 1, SIZE(models)
      CALL CD_End_Model(models(i), es, em)
    END DO
  END SUBROUTINE end_temp_models

END MODULE CableDyn_CAPI
