! File: tests/test_c_api.f90
! SPDX-License-Identifier: Apache-2.0
! Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
PROGRAM test_c_api
  !! ABI smoke gate for CableDyn_CAPI. This verifies the opaque C handle
  !! lifecycle, raw-array line initialization, coupled update/step/output calls,
  !! and fail-closed queries.
  USE, INTRINSIC :: ISO_C_BINDING, ONLY: C_BOOL, C_CHAR, C_DOUBLE, C_INT, C_LOC, C_NULL_CHAR, C_NULL_PTR, C_PTR, &
                                                                            C_ASSOCIATED
  USE CableDyn_CAPI, ONLY: CableDyn_Create, CableDyn_Close, CableDyn_IsInitialized, &
                           CableDyn_InitDeck, CableDyn_InitLine, CableDyn_InitLines, CableDyn_UpdateStates, &
                           CableDyn_UpdatePointFluidFields, CableDyn_Step, CableDyn_CalcOutput, &
                           CableDyn_CalcOutputDerivatives, CableDyn_GetCoupledMotion, CableDyn_GetLastError, &
                           CableDyn_GetVersion, &
                           CableDyn_GetVersionString, CableDyn_NCoupledDOF, CableDyn_NPoints, CableDyn_NLines, &
                           CableDyn_SaveState, CableDyn_RestoreState
  USE CableDyn_Precision, ONLY: wp
  USE CableDyn_OpenFAST_Aggregate, ONLY: CD_AGG_ModuleType, CD_AGG_Init_From_Deck, CD_AGG_Step_Moving, &
                                         CD_AGG_CalcOutput, CD_AGG_GetMovingPointMesh, CD_AGG_End, CD_AGG_OK
  IMPLICIT NONE

  INTEGER :: nfail
  nfail = 0

  CALL case_version()
  CALL case_lifecycle()
  CALL case_deck_init()
  CALL case_deck_dynamic_point_fluid()
  CALL case_deck_current_in_time()
  CALL case_deck_range_flag()
  CALL case_deck_bodies_rods()
  CALL case_init_update_output_step()
  CALL case_multiline_shared_map()
  CALL case_multiline_no_fixed_null_ptr()
  CALL case_zero_coupled_null_exchange()
  CALL case_single_line_oversize_rejects_before_slicing()
  CALL case_multiline_oversize_rejects_before_slicing()
  CALL case_null_queries()
  CALL case_bad_handle_rejected()
  CALL case_stale_double_close_copied_handle()

  IF (nfail > 0) THEN
    WRITE (*, '(A,I0,A)') 'FAIL: ', nfail, ' assertion(s) failed'
    ERROR STOP 1
  END IF
  WRITE (*, '(A)') 'PASS: CableDyn C API lifecycle'

CONTAINS

  INCLUDE 'nan_max_abs.inc'

  SUBROUTINE case_version()
    INTEGER(C_INT) :: major, minor, patch, abi_version
    CHARACTER(KIND=C_CHAR), TARGET :: msg(80)

    major = -1_C_INT
    minor = -1_C_INT
    patch = -1_C_INT
    abi_version = -1_C_INT
    msg = 'x'
    CALL CableDyn_GetVersion(major, minor, patch, abi_version)
    CALL require(major == 0_C_INT .AND. minor == 4_C_INT .AND. patch == 2_C_INT .AND. abi_version == 1_C_INT, &
                 'c-api-version:tuple')
    CALL CableDyn_GetVersionString(C_LOC(msg), INT(SIZE(msg), C_INT))
    CALL require(INDEX(c_text(msg), 'CableDyn') == 1 .AND. INDEX(c_text(msg), 'C-ABI 1') > 0, &
                 'c-api-version:string')
    CALL CableDyn_GetVersionString(C_NULL_PTR, INT(SIZE(msg), C_INT))
    CALL CableDyn_GetVersionString(C_LOC(msg), 0_C_INT)
  END SUBROUTINE case_version

  SUBROUTINE case_lifecycle()
    TYPE(C_PTR) :: handle
    INTEGER(C_INT) :: es, n
    LOGICAL(C_BOOL) :: ready

    CALL CableDyn_Create(handle, es)
    CALL require(es == 0_C_INT .AND. C_ASSOCIATED(handle), 'c-api:create')
    ready = CableDyn_IsInitialized(handle)
    CALL require(.NOT. LOGICAL(ready), 'c-api:new-handle-uninitialized')
    n = CableDyn_NCoupledDOF(handle, es)
    CALL require(n == 0_C_INT .AND. es == 5_C_INT, 'c-api:ncoupled-uninitialized')
    n = CableDyn_NLines(handle, es)
    CALL require(n == 0_C_INT .AND. es == 5_C_INT, 'c-api:nlines-uninitialized')
    CALL CableDyn_Close(handle, es)
    CALL require(es == 0_C_INT .AND. .NOT. C_ASSOCIATED(handle), 'c-api:close')
  END SUBROUTINE case_lifecycle

  SUBROUTINE case_deck_init()
    CHARACTER(*), PARAMETER :: DECK_PATH = 'capi_deck.dat'
    CHARACTER(*), PARAMETER :: BAD_DECK_PATH = 'capi_bad_deck.dat'
    CHARACTER(KIND=C_CHAR), TARGET :: c_path(LEN(DECK_PATH))
    CHARACTER(KIND=C_CHAR), TARGET :: c_bad_path(LEN(BAD_DECK_PATH))
    TYPE(C_PTR) :: handle
    INTEGER(C_INT) :: es, n
    LOGICAL(C_BOOL) :: ready
    CHARACTER(KIND=C_CHAR), TARGET :: msg(160)
    INTEGER :: i

    CALL write_capi_deck(DECK_PATH)
    CALL write_bad_capi_deck(BAD_DECK_PATH)
    DO i = 1, LEN(DECK_PATH)
      c_path(i) = DECK_PATH(i:i)
    END DO
    DO i = 1, LEN(BAD_DECK_PATH)
      c_bad_path(i) = BAD_DECK_PATH(i:i)
    END DO
    CALL CableDyn_Create(handle, es)
    CALL require(es == 0_C_INT .AND. C_ASSOCIATED(handle), 'c-api-deck:create')
    CALL CableDyn_InitDeck(handle, C_NULL_PTR, INT(LEN(DECK_PATH), C_INT), es)
    CALL require(es == 3_C_INT, 'c-api-deck:null-path-reject')
    CALL CableDyn_GetLastError(handle, C_LOC(msg), INT(SIZE(msg), C_INT))
    CALL require(INDEX(c_text(msg), 'deck path pointer') > 0, 'c-api-deck:null-path-message')
    CALL CableDyn_InitDeck(handle, C_LOC(c_path), 0_C_INT, es)
    CALL require(es == 3_C_INT, 'c-api-deck:empty-path-reject')
    CALL CableDyn_GetLastError(handle, C_LOC(msg), INT(SIZE(msg), C_INT))
    CALL require(INDEX(c_text(msg), 'deck path pointer') > 0, 'c-api-deck:empty-path-message')
    CALL CableDyn_InitDeck(handle, C_LOC(c_path), INT(LEN(DECK_PATH), C_INT), es)
    ready = CableDyn_IsInitialized(handle)
    CALL require(es == 0_C_INT .AND. LOGICAL(ready), 'c-api-deck:init')
    CALL CableDyn_GetLastError(handle, C_LOC(msg), INT(SIZE(msg), C_INT))
    CALL require(LEN_TRIM(c_text(msg)) == 0, 'c-api-deck:success-clears-message')
    n = CableDyn_NLines(handle, es)
    CALL require(es == 0_C_INT .AND. n == 1_C_INT, 'c-api-deck:nlines')
    n = CableDyn_NCoupledDOF(handle, es)
    CALL require(es == 0_C_INT .AND. n == 6_C_INT, 'c-api-deck:ncoupled')
    n = CableDyn_NPoints(handle, es)
    CALL require(es == 0_C_INT .AND. n == 2_C_INT, 'c-api-deck:npoints')
    CALL CableDyn_InitDeck(handle, C_LOC(c_bad_path), INT(LEN(BAD_DECK_PATH), C_INT), es)
    ready = CableDyn_IsInitialized(handle)
    CALL require(es == 3_C_INT .AND. LOGICAL(ready), 'c-api-deck:bad-reinit-preserves-handle')
    n = CableDyn_NLines(handle, es)
    CALL require(es == 0_C_INT .AND. n == 1_C_INT, 'c-api-deck:bad-reinit-preserves-nlines')
    n = CableDyn_NCoupledDOF(handle, es)
    CALL require(es == 0_C_INT .AND. n == 6_C_INT, 'c-api-deck:bad-reinit-preserves-ncoupled')
    CALL CableDyn_Close(handle, es)
    CALL require(es == 0_C_INT .AND. .NOT. C_ASSOCIATED(handle), 'c-api-deck:close')
  END SUBROUTINE case_deck_init

  SUBROUTINE case_deck_dynamic_point_fluid()
    CHARACTER(*), PARAMETER :: DECK_PATH = 'capi_connect_deck.dat'
    CHARACTER(KIND=C_CHAR), TARGET :: c_path(LEN(DECK_PATH))
    TYPE(C_PTR) :: ref_handle, hydro_handle
    INTEGER(C_INT) :: es, n, n_iter
    REAL(C_DOUBLE), TARGET :: q(9), v(9), a(9), qref(9), vref(9), aref(9), qhyd(9), vhyd(9), ahyd(9)
    REAL(C_DOUBLE), TARGET :: fluid_velocity(9), fluid_acceleration(9), waterline_z(3)
    CHARACTER(KIND=C_CHAR), TARGET :: msg(200)
    LOGICAL(C_BOOL) :: converged, stalled
    INTEGER :: i

    CALL write_capi_connect_deck(DECK_PATH)
    DO i = 1, LEN(DECK_PATH)
      c_path(i) = DECK_PATH(i:i)
    END DO
    CALL CableDyn_Create(ref_handle, es)
    CALL require(es == 0_C_INT .AND. C_ASSOCIATED(ref_handle), 'c-api-deck-fluid:create-ref')
    CALL CableDyn_Create(hydro_handle, es)
    CALL require(es == 0_C_INT .AND. C_ASSOCIATED(hydro_handle), 'c-api-deck-fluid:create-hydro')
    CALL CableDyn_InitDeck(ref_handle, C_LOC(c_path), INT(LEN(DECK_PATH), C_INT), es)
    CALL require(es == 0_C_INT, 'c-api-deck-fluid:init-ref')
    CALL CableDyn_InitDeck(hydro_handle, C_LOC(c_path), INT(LEN(DECK_PATH), C_INT), es)
    CALL require(es == 0_C_INT, 'c-api-deck-fluid:init-hydro')
    n = CableDyn_NCoupledDOF(hydro_handle, es)
    CALL require(es == 0_C_INT .AND. n == 9_C_INT, 'c-api-deck-fluid:ncoupled')

    fluid_velocity = 0.0_C_DOUBLE
    fluid_acceleration = 0.0_C_DOUBLE
    waterline_z = 0.0_C_DOUBLE
    CALL CableDyn_UpdatePointFluidFields(hydro_handle, C_LOC(fluid_velocity), C_LOC(fluid_acceleration), &
                                         C_LOC(waterline_z), 2_C_INT, 1000.0_C_DOUBLE, es)
    CALL require(es == 3_C_INT, 'c-api-deck-fluid:reject-bad-point-count')
    CALL CableDyn_GetLastError(hydro_handle, C_LOC(msg), INT(SIZE(msg), C_INT))
    CALL require(INDEX(c_text(msg), 'point count') > 0, 'c-api-deck-fluid:bad-count-message')
    CALL CableDyn_UpdatePointFluidFields(hydro_handle, C_NULL_PTR, C_LOC(fluid_acceleration), C_LOC(waterline_z), &
                                         3_C_INT, 1000.0_C_DOUBLE, es)
    CALL require(es == 3_C_INT, 'c-api-deck-fluid:reject-null-field')

    fluid_velocity(4) = 1.0_C_DOUBLE
    fluid_acceleration(6) = 0.5_C_DOUBLE
    CALL CableDyn_UpdatePointFluidFields(hydro_handle, C_LOC(fluid_velocity), C_LOC(fluid_acceleration), &
                                         C_LOC(waterline_z), 3_C_INT, 1000.0_C_DOUBLE, es)
    CALL require(es == 0_C_INT, 'c-api-deck-fluid:update-fields')

    q = [0.0_C_DOUBLE, 0.0_C_DOUBLE, -0.5_C_DOUBLE, 1.0_C_DOUBLE, 0.0_C_DOUBLE, -0.5_C_DOUBLE, &
         2.0_C_DOUBLE, 0.0_C_DOUBLE, -0.5_C_DOUBLE]
    v = 0.0_C_DOUBLE
    a = 0.0_C_DOUBLE
    CALL CableDyn_Step(ref_handle, 0.005_C_DOUBLE, C_LOC(q), C_LOC(v), C_LOC(a), 9_C_INT, &
                       converged, stalled, n_iter, es)
    CALL require(es == 0_C_INT .AND. LOGICAL(converged) .AND. .NOT. LOGICAL(stalled), &
                 'c-api-deck-fluid:step-ref')
    CALL CableDyn_GetCoupledMotion(ref_handle, C_LOC(qref), C_LOC(vref), C_LOC(aref), 9_C_INT, es)
    CALL require(es == 0_C_INT, 'c-api-deck-fluid:get-ref')
    CALL CableDyn_Step(hydro_handle, 0.005_C_DOUBLE, C_LOC(q), C_LOC(v), C_LOC(a), 9_C_INT, &
                       converged, stalled, n_iter, es)
    CALL require(es == 0_C_INT .AND. LOGICAL(converged) .AND. .NOT. LOGICAL(stalled), &
                 'c-api-deck-fluid:step-hydro')
    CALL CableDyn_GetCoupledMotion(hydro_handle, C_LOC(qhyd), C_LOC(vhyd), C_LOC(ahyd), 9_C_INT, es)
    CALL require(es == 0_C_INT, 'c-api-deck-fluid:get-hydro')
    CALL require(ahyd(4) > aref(4) .AND. vhyd(4) > vref(4), 'c-api-deck-fluid:drag-accelerates-connect')
    CALL require(ahyd(6) > aref(6) .AND. vhyd(6) > vref(6), 'c-api-deck-fluid:fk-accelerates-connect')

    CALL CableDyn_Close(ref_handle, es)
    CALL require(es == 0_C_INT .AND. .NOT. C_ASSOCIATED(ref_handle), 'c-api-deck-fluid:close-ref')
    CALL CableDyn_Close(hydro_handle, es)
    CALL require(es == 0_C_INT .AND. .NOT. C_ASSOCIATED(hydro_handle), 'c-api-deck-fluid:close-hydro')
  END SUBROUTINE case_deck_dynamic_point_fluid

  SUBROUTINE case_deck_current_in_time()
    !! The C ABI has no simulation clock: a deck current that varies in time (MoorDyn-C
    !! Currents 2) is refused, as deck waves are, rather than held at its t = 0 value; the same
    !! table constant in time is the steady field the ABI applies, as Currents 1.
    CHARACTER(*), PARAMETER :: DECK_PATH = 'capi_currents2_deck.dat'
    CHARACTER(KIND=C_CHAR), TARGET :: c_path(LEN(DECK_PATH))
    CHARACTER(KIND=C_CHAR), TARGET :: msg(300)
    TYPE(C_PTR) :: handle
    INTEGER(C_INT) :: es
    INTEGER :: i

    DO i = 1, LEN(DECK_PATH)
      c_path(i) = DECK_PATH(i:i)
    END DO
    CALL write_capi_currents_deck(DECK_PATH, '0.2 0.2 0.0 0.0')
    CALL CableDyn_Create(handle, es)
    CALL require(es == 0_C_INT .AND. C_ASSOCIATED(handle), 'c-api-currents2:create')
    CALL CableDyn_InitDeck(handle, C_LOC(c_path), INT(LEN(DECK_PATH), C_INT), es)
    CALL require(es == 3_C_INT, 'c-api-currents2:varying-in-time-rejected')
    CALL CableDyn_GetLastError(handle, C_LOC(msg), INT(SIZE(msg), C_INT))
    CALL require(INDEX(c_text(msg), 'no simulation clock') > 0 .AND. INDEX(c_text(msg), 'Currents 2') > 0, &
                 'c-api-currents2:varying-in-time-message')
    CALL write_capi_currents_deck(DECK_PATH, '0.1 0.1 0.0 0.0')
    CALL CableDyn_InitDeck(handle, C_LOC(c_path), INT(LEN(DECK_PATH), C_INT), es)
    CALL require(es == 0_C_INT, 'c-api-currents2:constant-in-time-applied')
    CALL CableDyn_Close(handle, es)
    CALL require(es == 0_C_INT .AND. .NOT. C_ASSOCIATED(handle), 'c-api-currents2:close')
  END SUBROUTINE case_deck_current_in_time

  SUBROUTINE case_deck_range_flag()
    !! The C ABI writes no result files: the LINES range-graph flag is refused by name, not
    !! accepted and left without a file.
    CHARACTER(*), PARAMETER :: DECK_PATH = 'capi_range_flag_deck.dat'
    CHARACTER(KIND=C_CHAR), TARGET :: c_path(LEN(DECK_PATH))
    CHARACTER(KIND=C_CHAR), TARGET :: msg(300)
    TYPE(C_PTR) :: handle
    INTEGER(C_INT) :: es
    INTEGER :: i

    DO i = 1, LEN(DECK_PATH)
      c_path(i) = DECK_PATH(i:i)
    END DO
    CALL write_capi_currents_deck(DECK_PATH, '0.1 0.1 0.0 0.0', line_outputs='r')
    CALL CableDyn_Create(handle, es)
    CALL require(es == 0_C_INT .AND. C_ASSOCIATED(handle), 'c-api-range-flag:create')
    CALL CableDyn_InitDeck(handle, C_LOC(c_path), INT(LEN(DECK_PATH), C_INT), es)
    CALL require(es == 3_C_INT, 'c-api-range-flag:rejected')
    CALL CableDyn_GetLastError(handle, C_LOC(msg), INT(SIZE(msg), C_INT))
    CALL require(INDEX(c_text(msg), 'flag r') > 0 .AND. INDEX(c_text(msg), 'C API') > 0, 'c-api-range-flag:message')
    CALL CableDyn_Close(handle, es)
    CALL require(es == 0_C_INT .AND. .NOT. C_ASSOCIATED(handle), 'c-api-range-flag:close')
  END SUBROUTINE case_deck_range_flag

  SUBROUTINE write_capi_currents_deck(path, row_later, line_outputs)
    !! The smoke deck with Currents 2 and its current_profile_dynamic.txt: x velocities
    !! 0.1 m/s at the two depths at t = 0 and the given row at t = 5 s. line_outputs gives the
    !! LINES Outputs flags.
    CHARACTER(*), INTENT(IN) :: path, row_later
    CHARACTER(*), INTENT(IN), OPTIONAL :: line_outputs
    INTEGER :: u, ios
    CHARACTER(8) :: flags

    flags = '-'
    IF (PRESENT(line_outputs)) flags = line_outputs

    OPEN (NEWUNIT=u, FILE='current_profile_dynamic.txt', STATUS='REPLACE', ACTION='WRITE', IOSTAT=ios)
    CALL require(ios == 0, 'c-api-currents2:create-table')
    IF (ios /= 0) RETURN
    WRITE (u, '(A)') 'MoorDyn dynamic currents'
    WRITE (u, '(A)') 'header'
    WRITE (u, '(A)') ''
    WRITE (u, '(A)') ''
    WRITE (u, '(A)') '-5.0 0.0'
    WRITE (u, '(A)') 't ux uy'
    WRITE (u, '(A)') '0.0 0.1 0.1 0.0 0.0'
    WRITE (u, '(A)') '5.0 '//row_later
    CLOSE (u)
    OPEN (NEWUNIT=u, FILE=path, STATUS='REPLACE', ACTION='WRITE', IOSTAT=ios)
    CALL require(ios == 0, 'c-api-currents2:create-file')
    IF (ios /= 0) RETURN
    WRITE (u, '(A)') 'C API deck with a MoorDyn-C current table'
    WRITE (u, '(A)') '--- LINE TYPES ---'
    WRITE (u, '(A)') 'Name Diam Mass EA BA EI Cdn Cdt Can Cat'
    WRITE (u, '(A)') '(-) (m) (kg/m) (N) (-) (Nm2) (-) (-) (-) (-)'
    WRITE (u, '(A)') 'line 0.10 80.0 1.0e5 0.0 0.0 1.0 0.0 1.0 0.0'
    WRITE (u, '(A)') '--- POINTS ---'
    WRITE (u, '(A)') 'ID Type X Y Z'
    WRITE (u, '(A)') '(-) (-) (m) (m) (m)'
    WRITE (u, '(A)') '1 Fixed 0.0 0.0 -1.0'
    WRITE (u, '(A)') '2 Coupled 0.8 0.0 -1.0'
    WRITE (u, '(A)') '--- LINES ---'
    WRITE (u, '(A)') 'ID NodeA NodeB Outputs'
    WRITE (u, '(A)') '(-) (-) (-) (-)'
    WRITE (u, '(A)') '1 2 1 '//TRIM(flags)
    WRITE (u, '(A)') '--- SECTIONS ---'
    WRITE (u, '(A)') 'LineID LineType Length NumSegs'
    WRITE (u, '(A)') '(-) (-) (m) (-)'
    WRITE (u, '(A)') '1 line 1.0 4'
    WRITE (u, '(A)') '--- OPTIONS ---'
    WRITE (u, '(A)') '9.80665 g'
    WRITE (u, '(A)') '1025.0 rhoW'
    WRITE (u, '(A)') '5.0 WtrDpth'
    WRITE (u, '(A)') '0.01 dtM'
    WRITE (u, '(A)') '1.0 TMax'
    WRITE (u, '(A)') '2 Currents'
    WRITE (u, '(A)') '--- OUTPUTS ---'
    WRITE (u, '(A)') 'FairTen1 AnchTen1'
    WRITE (u, '(A)') '--- end ---'
    CLOSE (u)
  END SUBROUTINE write_capi_currents_deck

  SUBROUTINE case_init_update_output_step()
    TYPE(C_PTR) :: handle
    INTEGER(C_INT), TARGET :: elem_conn(2), fixed_dofs(6)
    INTEGER(C_INT) :: es, n, n_iter
    REAL(C_DOUBLE), TARGET :: q0(6), v0(6), l0(1), ea(1), rho_a(1)
    REAL(C_DOUBLE), TARGET :: q(6), v(6), a(6), q_out(6), v_out(6), a_out(6), loads(6)
    REAL(C_DOUBLE), TARGET :: jq(36), jv(36), ja(36), madd(36)
    CHARACTER(KIND=C_CHAR), TARGET :: msg(160)
    LOGICAL(C_BOOL) :: ready, converged, stalled

    CALL CableDyn_Create(handle, es)
    CALL require(es == 0_C_INT .AND. C_ASSOCIATED(handle), 'c-api2:create')
    elem_conn = [1_C_INT, 2_C_INT]
    fixed_dofs = [1_C_INT, 2_C_INT, 3_C_INT, 4_C_INT, 5_C_INT, 6_C_INT]
    q0 = [0.0_C_DOUBLE, 0.0_C_DOUBLE, 0.0_C_DOUBLE, 1.0_C_DOUBLE, 0.0_C_DOUBLE, 0.0_C_DOUBLE]
    v0 = 0.0_C_DOUBLE
    l0 = [1.0_C_DOUBLE]
    ea = [100.0_C_DOUBLE]
    rho_a = [5.0_C_DOUBLE]
    CALL CableDyn_InitLine(handle, 2_C_INT, 1_C_INT, C_LOC(q0), C_LOC(v0), C_LOC(elem_conn), C_LOC(l0), &
                           C_LOC(ea), C_LOC(rho_a), C_LOC(fixed_dofs), 6_C_INT, 1_C_INT, &
                           0.8_C_DOUBLE, es)
    CALL require(es == 0_C_INT, 'c-api2:init-line')
    ready = CableDyn_IsInitialized(handle)
    CALL require(LOGICAL(ready), 'c-api2:initialized')
    n = CableDyn_NLines(handle, es)
    CALL require(es == 0_C_INT .AND. n == 1_C_INT, 'c-api2:nlines')
    n = CableDyn_NCoupledDOF(handle, es)
    CALL require(es == 0_C_INT .AND. n == 6_C_INT, 'c-api2:ncoupled')

    q = [0.0_C_DOUBLE, 0.0_C_DOUBLE, 0.0_C_DOUBLE, 1.2_C_DOUBLE, 0.0_C_DOUBLE, 0.0_C_DOUBLE]
    v = 0.0_C_DOUBLE
    a = 0.0_C_DOUBLE
    CALL CableDyn_UpdateStates(handle, C_LOC(q), C_LOC(v), C_LOC(a), 5_C_INT, es)
    CALL require(es == 3_C_INT, 'c-api2:update-size-reject')
    CALL CableDyn_GetLastError(handle, C_LOC(msg), INT(SIZE(msg), C_INT))
    CALL require(INDEX(c_text(msg), 'coupled DOF count') > 0, 'c-api2:update-size-message')
    CALL CableDyn_CalcOutput(handle, C_LOC(loads), 5_C_INT, es)
    CALL require(es == 3_C_INT, 'c-api2:output-size-reject')
    CALL CableDyn_GetCoupledMotion(handle, C_LOC(q_out), C_LOC(v_out), C_LOC(a_out), 5_C_INT, es)
    CALL require(es == 3_C_INT, 'c-api2:get-motion-size-reject')
    CALL CableDyn_UpdateStates(handle, C_LOC(q), C_LOC(v), C_LOC(a), 6_C_INT, es)
    CALL require(es == 0_C_INT, 'c-api2:update')
    CALL CableDyn_GetLastError(handle, C_LOC(msg), INT(SIZE(msg), C_INT))
    CALL require(LEN_TRIM(c_text(msg)) == 0, 'c-api2:update-success-clears-message')
    CALL CableDyn_GetCoupledMotion(handle, C_LOC(q_out), C_LOC(v_out), C_LOC(a_out), 6_C_INT, es)
    CALL require(es == 0_C_INT .AND. nan_max_abs(q_out - q) < 1.0e-12_C_DOUBLE, 'c-api2:get-motion')
    CALL CableDyn_CalcOutput(handle, C_LOC(loads), 6_C_INT, es)
    CALL require(es == 0_C_INT, 'c-api2:output')
    CALL require(ABS(loads(1) - 20.0_C_DOUBLE) < 1.0e-10_C_DOUBLE, 'c-api2:left-load')
    CALL require(ABS(loads(4) + 20.0_C_DOUBLE) < 1.0e-10_C_DOUBLE, 'c-api2:right-load')
    l0 = [-1.0_C_DOUBLE]
    CALL CableDyn_InitLine(handle, 2_C_INT, 1_C_INT, C_LOC(q0), C_LOC(v0), C_LOC(elem_conn), C_LOC(l0), &
                           C_LOC(ea), C_LOC(rho_a), C_LOC(fixed_dofs), 6_C_INT, 1_C_INT, &
                           0.8_C_DOUBLE, es)
    ready = CableDyn_IsInitialized(handle)
    CALL require(es == 3_C_INT .AND. LOGICAL(ready), 'c-api2:bad-reinit-preserves-handle')
    CALL CableDyn_GetLastError(handle, C_LOC(msg), INT(SIZE(msg), C_INT))
    CALL require(INDEX(c_text(msg), 'CableDyn_InitLine') > 0, 'c-api2:bad-reinit-message')
    n = CableDyn_NCoupledDOF(handle, es)
    CALL require(es == 0_C_INT .AND. n == 6_C_INT, 'c-api2:bad-reinit-preserves-ncoupled')
    CALL CableDyn_CalcOutput(handle, C_LOC(loads), 6_C_INT, es)
    CALL require(es == 0_C_INT .AND. ABS(loads(1) - 20.0_C_DOUBLE) < 1.0e-10_C_DOUBLE, &
                 'c-api2:bad-reinit-preserves-output')
    l0 = [1.0_C_DOUBLE]
    CALL CableDyn_CalcOutputDerivatives(handle, C_LOC(q), C_LOC(v), C_LOC(a), 6_C_INT, 1.0e-6_C_DOUBLE, &
                                        C_LOC(loads), C_LOC(jq), C_LOC(jv), C_LOC(ja), C_LOC(madd), es)
    CALL require(es == 0_C_INT, 'c-api2:derivatives')
    CALL require(ABS(jq(1 + (4 - 1)*6) - 100.0_C_DOUBLE) < 1.0e-5_C_DOUBLE, 'c-api2:jq-left-x2')
    CALL require(ABS(jq(4 + (4 - 1)*6) + 100.0_C_DOUBLE) < 1.0e-5_C_DOUBLE, 'c-api2:jq-right-x2')
    CALL require(nan_max_abs(jv) < 1.0e-8_C_DOUBLE, 'c-api2:jv-zero')
    CALL require(nan_max_abs(ja) > 1.0e-8_C_DOUBLE, 'c-api2:ja-present')
    CALL require(nan_max_abs(madd + ja) < 1.0e-8_C_DOUBLE, 'c-api2:madd-is-negative-ja')
    loads = 99.0_C_DOUBLE
    jq = 99.0_C_DOUBLE
    jv = 99.0_C_DOUBLE
    ja = 99.0_C_DOUBLE
    madd = 99.0_C_DOUBLE
    CALL CableDyn_CalcOutputDerivatives(handle, C_LOC(q), C_LOC(v), C_LOC(a), 6_C_INT, -1.0_C_DOUBLE, &
                                        C_LOC(loads), C_LOC(jq), C_LOC(jv), C_LOC(ja), C_LOC(madd), es)
    CALL require(es == 3_C_INT, 'c-api2:derivatives-fail-status')
    CALL require(nan_max_abs(loads) < 1.0e-12_C_DOUBLE, 'c-api2:derivatives-fail-zeroes-loads')
    CALL require(nan_max_abs(jq) < 1.0e-12_C_DOUBLE, 'c-api2:derivatives-fail-zeroes-jq')
    CALL require(nan_max_abs(jv) < 1.0e-12_C_DOUBLE, 'c-api2:derivatives-fail-zeroes-jv')
    CALL require(nan_max_abs(ja) < 1.0e-12_C_DOUBLE, 'c-api2:derivatives-fail-zeroes-ja')
    CALL require(nan_max_abs(madd) < 1.0e-12_C_DOUBLE, 'c-api2:derivatives-fail-zeroes-madd')

    q(4) = 1.1_C_DOUBLE
    CALL CableDyn_Step(handle, 0.01_C_DOUBLE, C_LOC(q), C_LOC(v), C_LOC(a), 6_C_INT, &
                       converged, stalled, n_iter, es)
    CALL require(es == 0_C_INT .AND. LOGICAL(converged) .AND. .NOT. LOGICAL(stalled), 'c-api2:step')
    CALL CableDyn_GetCoupledMotion(handle, C_LOC(q_out), C_LOC(v_out), C_LOC(a_out), 6_C_INT, es)
    CALL require(es == 0_C_INT .AND. ABS(q_out(4) - q(4)) < 1.0e-12_C_DOUBLE, 'c-api2:step-motion')
    CALL CableDyn_Close(handle, es)
    CALL require(es == 0_C_INT .AND. .NOT. C_ASSOCIATED(handle), 'c-api2:close')
  END SUBROUTINE case_init_update_output_step

  SUBROUTINE case_multiline_shared_map()
    TYPE(C_PTR) :: handle
    INTEGER(C_INT), TARGET :: n_nodes(2), n_elem(2), n_fixed(2), elem_conn(4), fixed_dofs(12), coupled_map(12)
    INTEGER(C_INT) :: es, n
    REAL(C_DOUBLE), TARGET :: q0(12), v0(12), l0(2), ea(2), rho_a(2), q(9), v(9), a(9), loads(9)
    CHARACTER(KIND=C_CHAR), TARGET :: msg(200)
    LOGICAL(C_BOOL) :: ready

    CALL CableDyn_Create(handle, es)
    CALL require(es == 0_C_INT .AND. C_ASSOCIATED(handle), 'c-api3:create')
    n_nodes = [2_C_INT, 2_C_INT]
    n_elem = [1_C_INT, 1_C_INT]
    n_fixed = [6_C_INT, 6_C_INT]
    elem_conn = [1_C_INT, 2_C_INT, 1_C_INT, 2_C_INT]
    fixed_dofs = [1_C_INT, 2_C_INT, 3_C_INT, 4_C_INT, 5_C_INT, 6_C_INT, &
                  1_C_INT, 2_C_INT, 3_C_INT, 4_C_INT, 5_C_INT, 6_C_INT]
    coupled_map = [1_C_INT, 2_C_INT, 3_C_INT, 4_C_INT, 5_C_INT, 6_C_INT, &
                   4_C_INT, 5_C_INT, 6_C_INT, 7_C_INT, 8_C_INT, 9_C_INT]
    q0 = [0.0_C_DOUBLE, 0.0_C_DOUBLE, 0.0_C_DOUBLE, 1.0_C_DOUBLE, 0.0_C_DOUBLE, 0.0_C_DOUBLE, &
          1.0_C_DOUBLE, 0.0_C_DOUBLE, 0.0_C_DOUBLE, 2.0_C_DOUBLE, 0.0_C_DOUBLE, 0.0_C_DOUBLE]
    v0 = 0.0_C_DOUBLE
    l0 = [1.0_C_DOUBLE, 1.0_C_DOUBLE]
    ea = [100.0_C_DOUBLE, 100.0_C_DOUBLE]
    rho_a = [5.0_C_DOUBLE, 5.0_C_DOUBLE]
    CALL CableDyn_InitLines(handle, 2_C_INT, C_LOC(n_nodes), C_LOC(n_elem), C_LOC(n_fixed), C_LOC(q0), &
                            C_LOC(v0), C_LOC(elem_conn), C_LOC(l0), C_LOC(ea), C_LOC(rho_a), &
                            C_LOC(fixed_dofs), C_LOC(coupled_map), 9_C_INT, 1_C_INT, 0.8_C_DOUBLE, es)
    CALL require(es == 3_C_INT, 'c-api3:bad-map-length-reject')
    CALL CableDyn_InitLines(handle, 2_C_INT, C_LOC(n_nodes), C_LOC(n_elem), C_LOC(n_fixed), C_LOC(q0), &
                            C_LOC(v0), C_LOC(elem_conn), C_LOC(l0), C_LOC(ea), C_LOC(rho_a), &
                            C_LOC(fixed_dofs), C_LOC(coupled_map), 12_C_INT, 1_C_INT, 0.8_C_DOUBLE, es)
    CALL require(es == 0_C_INT, 'c-api3:init-lines')
    n = CableDyn_NLines(handle, es)
    CALL require(es == 0_C_INT .AND. n == 2_C_INT, 'c-api3:nlines')
    n = CableDyn_NCoupledDOF(handle, es)
    CALL require(es == 0_C_INT .AND. n == 9_C_INT, 'c-api3:ncoupled')

    q = [0.0_C_DOUBLE, 0.0_C_DOUBLE, 0.0_C_DOUBLE, 1.2_C_DOUBLE, 0.0_C_DOUBLE, 0.0_C_DOUBLE, &
         2.4_C_DOUBLE, 0.0_C_DOUBLE, 0.0_C_DOUBLE]
    v = 0.0_C_DOUBLE
    a = 0.0_C_DOUBLE
    CALL CableDyn_UpdateStates(handle, C_LOC(q), C_LOC(v), C_LOC(a), 9_C_INT, es)
    CALL require(es == 0_C_INT, 'c-api3:update')
    CALL CableDyn_CalcOutput(handle, C_LOC(loads), 9_C_INT, es)
    CALL require(es == 0_C_INT, 'c-api3:loads')
    CALL require(ABS(loads(1) - 20.0_C_DOUBLE) < 1.0e-10_C_DOUBLE, 'c-api3:left-load')
    CALL require(ABS(loads(4)) < 1.0e-10_C_DOUBLE, 'c-api3:shared-summed-load')
    CALL require(ABS(loads(7) + 20.0_C_DOUBLE) < 1.0e-10_C_DOUBLE, 'c-api3:right-load')
    coupled_map = [1_C_INT, 2_C_INT, 3_C_INT, 4_C_INT, 5_C_INT, 6_C_INT, &
                   4_C_INT, 5_C_INT, 6_C_INT, 7_C_INT, 8_C_INT, 10_C_INT]
    CALL CableDyn_InitLines(handle, 2_C_INT, C_LOC(n_nodes), C_LOC(n_elem), C_LOC(n_fixed), C_LOC(q0), &
                            C_LOC(v0), C_LOC(elem_conn), C_LOC(l0), C_LOC(ea), C_LOC(rho_a), &
                            C_LOC(fixed_dofs), C_LOC(coupled_map), 12_C_INT, 1_C_INT, 0.8_C_DOUBLE, es)
    ready = CableDyn_IsInitialized(handle)
    CALL require(es == 3_C_INT .AND. LOGICAL(ready), 'c-api3:bad-map-reinit-preserves-handle')
    CALL CableDyn_GetLastError(handle, C_LOC(msg), INT(SIZE(msg), C_INT))
    CALL require(INDEX(c_text(msg), 'CableDyn_InitLines') > 0 .AND. INDEX(c_text(msg), 'compact') > 0, &
                 'c-api3:bad-map-reinit-message')
    n = CableDyn_NCoupledDOF(handle, es)
    CALL require(es == 0_C_INT .AND. n == 9_C_INT, 'c-api3:bad-map-reinit-preserves-ncoupled')
    CALL CableDyn_CalcOutput(handle, C_LOC(loads), 9_C_INT, es)
    CALL require(es == 0_C_INT .AND. ABS(loads(4)) < 1.0e-10_C_DOUBLE, &
                 'c-api3:bad-map-reinit-preserves-output')
    CALL CableDyn_Close(handle, es)
    CALL require(es == 0_C_INT .AND. .NOT. C_ASSOCIATED(handle), 'c-api3:close')
  END SUBROUTINE case_multiline_shared_map

  SUBROUTINE case_multiline_no_fixed_null_ptr()
    TYPE(C_PTR) :: handle
    INTEGER(C_INT), TARGET :: n_nodes(2), n_elem(2), n_fixed(2), elem_conn(4)
    INTEGER(C_INT) :: es, n
    REAL(C_DOUBLE), TARGET :: q0(12), v0(12), l0(2), ea(2), rho_a(2)
    LOGICAL(C_BOOL) :: ready

    CALL CableDyn_Create(handle, es)
    CALL require(es == 0_C_INT .AND. C_ASSOCIATED(handle), 'c-api4:create')
    n_nodes = [2_C_INT, 2_C_INT]
    n_elem = [1_C_INT, 1_C_INT]
    n_fixed = [0_C_INT, 0_C_INT]
    elem_conn = [1_C_INT, 2_C_INT, 1_C_INT, 2_C_INT]
    q0 = [0.0_C_DOUBLE, 0.0_C_DOUBLE, 0.0_C_DOUBLE, 1.0_C_DOUBLE, 0.0_C_DOUBLE, 0.0_C_DOUBLE, &
          1.0_C_DOUBLE, 0.0_C_DOUBLE, 0.0_C_DOUBLE, 2.0_C_DOUBLE, 0.0_C_DOUBLE, 0.0_C_DOUBLE]
    v0 = 0.0_C_DOUBLE
    l0 = [1.0_C_DOUBLE, 1.0_C_DOUBLE]
    ea = [100.0_C_DOUBLE, 100.0_C_DOUBLE]
    rho_a = [5.0_C_DOUBLE, 5.0_C_DOUBLE]
    CALL CableDyn_InitLines(handle, 2_C_INT, C_LOC(n_nodes), C_LOC(n_elem), C_LOC(n_fixed), C_LOC(q0), &
                            C_LOC(v0), C_LOC(elem_conn), C_LOC(l0), C_LOC(ea), C_LOC(rho_a), &
                            C_NULL_PTR, C_NULL_PTR, 0_C_INT, 1_C_INT, 0.8_C_DOUBLE, es)
    ready = CableDyn_IsInitialized(handle)
    CALL require(es == 0_C_INT .AND. LOGICAL(ready), 'c-api4:init-lines-no-fixed-null')
    n = CableDyn_NLines(handle, es)
    CALL require(es == 0_C_INT .AND. n == 2_C_INT, 'c-api4:nlines')
    CALL CableDyn_Close(handle, es)
    CALL require(es == 0_C_INT .AND. .NOT. C_ASSOCIATED(handle), 'c-api4:close')
  END SUBROUTINE case_multiline_no_fixed_null_ptr

  SUBROUTINE case_zero_coupled_null_exchange()
    TYPE(C_PTR) :: handle
    INTEGER(C_INT), TARGET :: elem_conn(2)
    INTEGER(C_INT) :: es, n, n_iter
    REAL(C_DOUBLE), TARGET :: q0(6), v0(6), l0(1), ea(1), rho_a(1)
    LOGICAL(C_BOOL) :: converged, stalled

    CALL CableDyn_Create(handle, es)
    CALL require(es == 0_C_INT .AND. C_ASSOCIATED(handle), 'c-api-zero:create')
    elem_conn = [1_C_INT, 2_C_INT]
    q0 = [0.0_C_DOUBLE, 0.0_C_DOUBLE, 0.0_C_DOUBLE, 1.0_C_DOUBLE, 0.0_C_DOUBLE, 0.0_C_DOUBLE]
    v0 = 0.0_C_DOUBLE
    l0 = [1.0_C_DOUBLE]
    ea = [100.0_C_DOUBLE]
    rho_a = [5.0_C_DOUBLE]
    CALL CableDyn_InitLine(handle, 2_C_INT, 1_C_INT, C_LOC(q0), C_LOC(v0), C_LOC(elem_conn), C_LOC(l0), &
                           C_LOC(ea), C_LOC(rho_a), C_NULL_PTR, 0_C_INT, 1_C_INT, 0.8_C_DOUBLE, es)
    CALL require(es == 0_C_INT, 'c-api-zero:init-free-line')
    n = CableDyn_NCoupledDOF(handle, es)
    CALL require(es == 0_C_INT .AND. n == 0_C_INT, 'c-api-zero:ncoupled')
    CALL CableDyn_UpdateStates(handle, C_NULL_PTR, C_NULL_PTR, C_NULL_PTR, 0_C_INT, es)
    CALL require(es == 0_C_INT, 'c-api-zero:update-null')
    CALL CableDyn_CalcOutput(handle, C_NULL_PTR, 0_C_INT, es)
    CALL require(es == 0_C_INT, 'c-api-zero:output-null')
    CALL CableDyn_GetCoupledMotion(handle, C_NULL_PTR, C_NULL_PTR, C_NULL_PTR, 0_C_INT, es)
    CALL require(es == 0_C_INT, 'c-api-zero:get-null')
    CALL CableDyn_CalcOutputDerivatives(handle, C_NULL_PTR, C_NULL_PTR, C_NULL_PTR, 0_C_INT, 1.0e-6_C_DOUBLE, &
                                        C_NULL_PTR, C_NULL_PTR, C_NULL_PTR, C_NULL_PTR, C_NULL_PTR, es)
    CALL require(es == 0_C_INT, 'c-api-zero:derivatives-null')
    CALL CableDyn_Step(handle, 0.01_C_DOUBLE, C_NULL_PTR, C_NULL_PTR, C_NULL_PTR, 0_C_INT, &
                       converged, stalled, n_iter, es)
    CALL require(es == 0_C_INT .AND. LOGICAL(converged), 'c-api-zero:step-null')
    CALL CableDyn_Close(handle, es)
    CALL require(es == 0_C_INT .AND. .NOT. C_ASSOCIATED(handle), 'c-api-zero:close')
  END SUBROUTINE case_zero_coupled_null_exchange

  SUBROUTINE case_single_line_oversize_rejects_before_slicing()
    !! Single-line initializer must reject impossible sizes before forming
    !! C_F_POINTER shapes such as [3*n_nodes].
    TYPE(C_PTR) :: handle
    INTEGER(C_INT) :: max_count
    INTEGER(C_INT) :: es

    CALL CableDyn_Create(handle, es)
    CALL require(es == 0_C_INT .AND. C_ASSOCIATED(handle), 'c-api-single-oversize:create')
    max_count = HUGE(max_count)
    CALL CableDyn_InitLine(handle, max_count/3_C_INT + 1_C_INT, 1_C_INT, C_NULL_PTR, C_NULL_PTR, C_NULL_PTR, &
                           C_NULL_PTR, C_NULL_PTR, C_NULL_PTR, C_NULL_PTR, 0_C_INT, 1_C_INT, 0.8_C_DOUBLE, es)
    CALL require(es == 3_C_INT, 'c-api-single-oversize:reject')
    CALL CableDyn_Close(handle, es)
    CALL require(es == 0_C_INT .AND. .NOT. C_ASSOCIATED(handle), 'c-api-single-oversize:close')
  END SUBROUTINE case_single_line_oversize_rejects_before_slicing

  SUBROUTINE case_multiline_oversize_rejects_before_slicing()
    !! The C initializer must reject impossible aggregate sizes before forming
    !! q/v/connectivity slices or converting INT64 offsets back to default INTEGER.
    TYPE(C_PTR) :: handle
    INTEGER(C_INT), TARGET :: n_nodes(1), n_elem(1), n_fixed(1)
    INTEGER(C_INT) :: max_count
    INTEGER(C_INT) :: es

    CALL CableDyn_Create(handle, es)
    CALL require(es == 0_C_INT .AND. C_ASSOCIATED(handle), 'c-api5:create')
    max_count = HUGE(max_count)
    n_nodes = [max_count/3_C_INT + 1_C_INT]
    n_elem = [1_C_INT]
    n_fixed = [0_C_INT]
    CALL CableDyn_InitLines(handle, 1_C_INT, C_LOC(n_nodes), C_LOC(n_elem), C_LOC(n_fixed), &
                            C_NULL_PTR, C_NULL_PTR, C_NULL_PTR, C_NULL_PTR, C_NULL_PTR, C_NULL_PTR, &
                            C_NULL_PTR, C_NULL_PTR, 0_C_INT, 1_C_INT, 0.8_C_DOUBLE, es)
    CALL require(es == 3_C_INT, 'c-api5:oversize-reject')
    CALL CableDyn_Close(handle, es)
    CALL require(es == 0_C_INT .AND. .NOT. C_ASSOCIATED(handle), 'c-api5:close')
  END SUBROUTINE case_multiline_oversize_rejects_before_slicing

  SUBROUTINE case_null_queries()
    TYPE(C_PTR) :: handle
    INTEGER(C_INT) :: es, n

    handle = C_NULL_PTR
    n = CableDyn_NCoupledDOF(handle, es)
    CALL require(n == 0_C_INT .AND. es /= 0_C_INT, 'c-api:null-ncoupled')
    CALL CableDyn_Close(handle, es)
    CALL require(es == 0_C_INT, 'c-api:null-close')
  END SUBROUTINE case_null_queries

  SUBROUTINE case_bad_handle_rejected()
    !! A non-null pointer this module never created must be rejected by every public
    !! entry point WITHOUT being dereferenced or freed (the registry rejects it before
    !! any C_F_POINTER). `foreign` is a stack TARGET: if Close freed it or any call
    !! dereferenced it, the run would corrupt/crash, so reaching the asserts proves no
    !! deref happened, and the final check confirms the foreign memory was untouched.
    INTEGER, TARGET :: foreign
    TYPE(C_PTR) :: bad
    INTEGER(C_INT) :: es, n
    LOGICAL(C_BOOL) :: ready
    CHARACTER(KIND=C_CHAR), TARGET :: msg(64)

    foreign = 12345
    bad = C_LOC(foreign)
    ready = CableDyn_IsInitialized(bad)
    CALL require(.NOT. LOGICAL(ready), 'c-api:bad-handle-isinit')
    n = CableDyn_NCoupledDOF(bad, es)
    CALL require(n == 0_C_INT .AND. es == 1_C_INT, 'c-api:bad-handle-ncoupled')
    n = CableDyn_NPoints(bad, es)
    CALL require(n == 0_C_INT .AND. es == 1_C_INT, 'c-api:bad-handle-npoints')
    n = CableDyn_NLines(bad, es)
    CALL require(n == 0_C_INT .AND. es == 1_C_INT, 'c-api:bad-handle-nlines')
    msg = 'x'
    CALL CableDyn_GetLastError(bad, C_LOC(msg), INT(SIZE(msg), C_INT))
    CALL require(INDEX(c_text(msg), 'bad handle') > 0, 'c-api:bad-handle-lasterror')
    CALL CableDyn_Close(bad, es)
    CALL require(es == 1_C_INT .AND. C_ASSOCIATED(bad), 'c-api:bad-handle-close-noop')
    CALL require(foreign == 12345, 'c-api:bad-handle-memory-untouched')
  END SUBROUTINE case_bad_handle_rejected

  SUBROUTINE case_stale_double_close_copied_handle()
    !! After Close the original pointer is nulled and de-registered. A copy taken
    !! before Close is stale: every entry point must reject it (registry miss) and
    !! Close must NOT double-free it. Double-closing the original (now null) is an
    !! idempotent no-op. Reaching the end without a crash is the double-free gate.
    TYPE(C_PTR) :: handle, copy
    INTEGER(C_INT) :: es, n
    LOGICAL(C_BOOL) :: ready

    CALL CableDyn_Create(handle, es)
    CALL require(es == 0_C_INT .AND. C_ASSOCIATED(handle), 'c-api:stale:create')
    copy = handle                               ! alias the same target
    CALL CableDyn_Close(handle, es)             ! frees + de-registers + nulls handle
    CALL require(es == 0_C_INT .AND. .NOT. C_ASSOCIATED(handle), 'c-api:stale:close')
    CALL CableDyn_Close(handle, es)             ! double-close on null: idempotent OK
    CALL require(es == 0_C_INT, 'c-api:stale:double-close-null-ok')
    ready = CableDyn_IsInitialized(copy)        ! stale copy: rejected, not dereferenced
    CALL require(.NOT. LOGICAL(ready), 'c-api:stale:copy-isinit')
    n = CableDyn_NCoupledDOF(copy, es)
    CALL require(n == 0_C_INT .AND. es == 1_C_INT, 'c-api:stale:copy-ncoupled')
    CALL CableDyn_Close(copy, es)               ! must NOT double-free the stale copy
    CALL require(es == 1_C_INT, 'c-api:stale:copy-close-rejected')
  END SUBROUTINE case_stale_double_close_copied_handle

  SUBROUTINE case_deck_bodies_rods()
    !! A deck with a free rod (and one with a free Rigid6 body, and one with a Pinned rod)
    !! initializes through the aggregate: the coupled DOFs are its Coupled points, the step is the
    !! deck dtM, and 20 driven steps reproduce CD_AGG driven directly bit-for-bit (loads and
    !! coupled motion), also across a SaveState / three trial steps / RestoreState rewind half
    !! way. A mismatched dt, load derivatives and point fluid fields fail closed by name; a
    !! Coupled rod (a 6-DOF host node), a CoupledPinned rod (a host-driven pin) and a
    !! CoupledPinned body (a host-driven reference point) are rejected by the standalone deck rules.
    CHARACTER(*), PARAMETER :: ROD_DECK = 'capi_rod_deck.dat', BODY_DECK = 'capi_body_deck.dat', &
                               HOST_DECK = 'capi_hostrod_deck.dat', PIN_DECK = 'capi_pinrod_deck.dat', &
                               HOST_PIN_DECK = 'capi_hostpin_deck.dat', PIN_BODY_DECK = 'capi_pinbody_deck.dat'
    CHARACTER(KIND=C_CHAR), TARGET :: c_path(64)
    CHARACTER(KIND=C_CHAR), TARGET :: msg(300)
    TYPE(C_PTR) :: handle
    TYPE(CD_AGG_ModuleType), SAVE :: agg
    INTEGER(C_INT) :: es, n, n_iter
    INTEGER :: ideck, i, s, ies, nit
    REAL(C_DOUBLE), TARGET :: q(3), v(3), a(3), f(3), qo(3), vo(3), ao(3), jac(9)
    REAL(wp) :: p(3, 1), pv(3, 1), pa(3, 1), pl(3, 1), maxdiff
    LOGICAL(C_BOOL) :: converged, stalled
    LOGICAL :: cv, st
    CHARACTER(64) :: path
    CHARACTER(512) :: em

    CALL write_capi_object_deck(ROD_DECK, 1)
    CALL write_capi_object_deck(BODY_DECK, 2)
    CALL write_capi_object_deck(HOST_DECK, 3)
    CALL write_capi_object_deck(PIN_DECK, 4)
    CALL write_capi_object_deck(HOST_PIN_DECK, 5)
    CALL write_capi_object_deck(PIN_BODY_DECK, 6)
    DO ideck = 1, 3
      SELECT CASE (ideck)
      CASE (1)
        path = ROD_DECK
      CASE (2)
        path = BODY_DECK
      CASE DEFAULT
        path = PIN_DECK
      END SELECT
      c_path = C_NULL_CHAR
      DO i = 1, LEN_TRIM(path)
        c_path(i) = path(i:i)
      END DO
      CALL CableDyn_Create(handle, es)
      CALL CableDyn_InitDeck(handle, C_LOC(c_path), INT(LEN_TRIM(path), C_INT), es)
      CALL CableDyn_GetLastError(handle, C_LOC(msg), INT(SIZE(msg), C_INT))
      CALL require(es == 0_C_INT, 'c-api-objects:init '//TRIM(path)//': '//TRIM(c_text(msg)))
      IF (es /= 0_C_INT) THEN
        CALL CableDyn_Close(handle, es)
        CYCLE
      END IF
      CALL require(LOGICAL(CableDyn_IsInitialized(handle)), 'c-api-objects:initialized')
      n = CableDyn_NCoupledDOF(handle, es)
      CALL require(es == 0_C_INT .AND. n == 3_C_INT, 'c-api-objects:one-coupled-point')
      CALL require(CableDyn_NLines(handle, es) == 2_C_INT, 'c-api-objects:two-lines')
      CALL CD_AGG_Init_From_Deck(agg, TRIM(path), 0.005_wp, ies, em)
      CALL require(ies == CD_AGG_OK, 'c-api-objects:aggregate-init: '//TRIM(em))
      CALL CableDyn_GetCoupledMotion(handle, C_LOC(qo), C_LOC(vo), C_LOC(ao), 3_C_INT, es)
      q = qo
      v = 0.0_C_DOUBLE
      a = 0.0_C_DOUBLE
      maxdiff = 0.0_wp
      DO s = 1, 20
        IF (s == 11) THEN
          ! An outer-corrector rewind half way: save, take three trial steps with another motion,
          ! restore. The march must go on bit for bit with the directly driven aggregate.
          CALL CableDyn_SaveState(handle, es)
          CALL require(es == 0_C_INT, 'c-api-objects:save')
          DO i = 1, 3
            q(1) = qo(1) - 0.1_C_DOUBLE*REAL(i, C_DOUBLE)
            v(1) = -0.2_C_DOUBLE
            CALL CableDyn_Step(handle, 0.005_C_DOUBLE, C_LOC(q), C_LOC(v), C_LOC(a), 3_C_INT, converged, &
                               stalled, n_iter, es)
            CALL require(es == 0_C_INT, 'c-api-objects:trial-step')
          END DO
          CALL CableDyn_RestoreState(handle, es)
          CALL require(es == 0_C_INT, 'c-api-objects:restore')
        END IF
        q(1) = qo(1) + 0.05_C_DOUBLE*SIN(0.5_C_DOUBLE*REAL(s, C_DOUBLE))
        v(1) = 0.025_C_DOUBLE*COS(0.5_C_DOUBLE*REAL(s, C_DOUBLE))
        CALL CableDyn_Step(handle, 0.005_C_DOUBLE, C_LOC(q), C_LOC(v), C_LOC(a), 3_C_INT, converged, stalled, &
                           n_iter, es)
        CALL require(es == 0_C_INT .AND. LOGICAL(converged), 'c-api-objects:step')
        CALL CableDyn_CalcOutput(handle, C_LOC(f), 3_C_INT, es)
        p(:, 1) = REAL(q, wp)
        pv(:, 1) = REAL(v, wp)
        pa(:, 1) = REAL(a, wp)
        CALL CD_AGG_Step_Moving(agg, 0.005_wp, p, pv, pa, cv, st, nit, ies, em, t_committed=0.005_wp*REAL(s, wp))
        CALL CD_AGG_CalcOutput(agg, ies, em)
        CALL CD_AGG_GetMovingPointMesh(agg, p, pv, pa, pl, ies, em)
        maxdiff = MAX(maxdiff, nan_max_abs(REAL(f, wp) - pl(:, 1)))
      END DO
      CALL require(nan_max_abs(f) > 0.0_C_DOUBLE, 'c-api-objects:loads-nonzero')
      CALL require(maxdiff <= 0.0_wp, 'c-api-objects:loads-equal-aggregate-bit-for-bit')
      CALL CableDyn_GetCoupledMotion(handle, C_LOC(qo), C_LOC(vo), C_LOC(ao), 3_C_INT, es)
      CALL require(es == 0_C_INT .AND. nan_max_abs(qo - q) <= 0.0_C_DOUBLE, 'c-api-objects:coupled-motion')
      ! fixed step, no derivatives, no point fluid on this route
      CALL CableDyn_Step(handle, 0.01_C_DOUBLE, C_LOC(q), C_LOC(v), C_LOC(a), 3_C_INT, converged, stalled, &
                         n_iter, es)
      CALL require(es == 3_C_INT, 'c-api-objects:dt-must-match-dtM')
      CALL CableDyn_CalcOutputDerivatives(handle, C_LOC(q), C_LOC(v), C_LOC(a), 3_C_INT, 0.0_C_DOUBLE, C_LOC(f), &
                                          C_LOC(jac), C_LOC(jac), C_LOC(jac), C_LOC(jac), es)
      CALL CableDyn_GetLastError(handle, C_LOC(msg), INT(SIZE(msg), C_INT))
      CALL require(es == 3_C_INT .AND. INDEX(c_text(msg), 'BODIES or RODS') > 0, 'c-api-objects:no-derivatives')
      CALL CableDyn_UpdatePointFluidFields(handle, C_LOC(jac), C_LOC(jac), C_LOC(jac), 1_C_INT, &
                                           1025.0_C_DOUBLE, es)
      CALL require(es == 3_C_INT, 'c-api-objects:no-point-fluid')
      CALL CD_AGG_End(agg, ies, em)
      CALL CableDyn_Close(handle, es)
      CALL require(es == 0_C_INT, 'c-api-objects:close')
    END DO
    ! a Coupled (6-DOF host) rod is outside the translational C ABI
    path = HOST_DECK
    c_path = C_NULL_CHAR
    DO i = 1, LEN_TRIM(path)
      c_path(i) = path(i:i)
    END DO
    CALL CableDyn_Create(handle, es)
    CALL CableDyn_InitDeck(handle, C_LOC(c_path), INT(LEN_TRIM(path), C_INT), es)
    CALL CableDyn_GetLastError(handle, C_LOC(msg), INT(SIZE(msg), C_INT))
    CALL require(es == 3_C_INT .AND. INDEX(c_text(msg), 'Coupled/Vessel ROD') > 0, 'c-api-objects:host-rod-rejected')
    CALL CableDyn_Close(handle, es)
    ! so is a CoupledPinned rod, whose pin a coupled host moves
    path = HOST_PIN_DECK
    c_path = C_NULL_CHAR
    DO i = 1, LEN_TRIM(path)
      c_path(i) = path(i:i)
    END DO
    CALL CableDyn_Create(handle, es)
    CALL CableDyn_InitDeck(handle, C_LOC(c_path), INT(LEN_TRIM(path), C_INT), es)
    CALL CableDyn_GetLastError(handle, C_LOC(msg), INT(SIZE(msg), C_INT))
    CALL require(es == 3_C_INT .AND. INDEX(c_text(msg), 'requires a coupled host') > 0, &
                 'c-api-objects:host-pinned-rod-rejected')
    CALL CableDyn_Close(handle, es)
    ! and a CoupledPinned body, whose reference point a coupled host moves
    path = PIN_BODY_DECK
    c_path = C_NULL_CHAR
    DO i = 1, LEN_TRIM(path)
      c_path(i) = path(i:i)
    END DO
    CALL CableDyn_Create(handle, es)
    CALL CableDyn_InitDeck(handle, C_LOC(c_path), INT(LEN_TRIM(path), C_INT), es)
    CALL CableDyn_GetLastError(handle, C_LOC(msg), INT(SIZE(msg), C_INT))
    CALL require(es == 3_C_INT .AND. INDEX(c_text(msg), 'BODY requires a coupled host') > 0, &
                 'c-api-objects:host-pinned-body-rejected')
    CALL CableDyn_Close(handle, es)
  END SUBROUTINE case_deck_bodies_rods

  SUBROUTINE write_capi_object_deck(path, kind)
    !! kind 1: a submerged free rod between a Fixed anchor and a Coupled fairlead; kind 2: the same
    !! with a free Rigid6 body; kind 3: a Coupled rod (a 6-DOF host node); kind 4: a Pinned rod
    !! (End A on a fixed pin); kind 5: a CoupledPinned rod (its pin a host node); kind 6: the
    !! body of kind 2 as a CoupledPinned body (its reference point a host node).
    CHARACTER(*), INTENT(IN) :: path
    INTEGER, INTENT(IN) :: kind
    INTEGER :: u
    OPEN (NEWUNIT=u, FILE=path, STATUS='REPLACE', ACTION='WRITE')
    WRITE (u, '(A)') 'C API body/rod deck'
    WRITE (u, '(A)') '--- LINE TYPES ---'
    WRITE (u, '(A)') 'Name Diam Mass EA BA EI Cdn Cdt Can Cat'
    WRITE (u, '(A)') '(-) (m) (kg/m) (N) (-) (Nm2) (-) (-) (-) (-)'
    WRITE (u, '(A)') 'line 0.10 80.0 1.0e5 0.0 0.0 1.0 0.0 1.0 0.0'
    IF (kind == 2 .OR. kind == 6) THEN
      WRITE (u, '(A)') '--- BODIES ---'
      WRITE (u, '(A)') 'ID Type X Y Z Rot1 Rot2 Rot3 Mass Vol C33 C44 C55 CdA Ca Ixx Iyy Izz'
      WRITE (u, '(A)') '(-) (-) (m) (m) (m) (deg) (deg) (deg) (kg) (m3) (N/m) (Nm/rad) (Nm/rad) (m2) (-) '// &
        '(kgm2) (kgm2) (kgm2)'
      IF (kind == 2) THEN
        WRITE (u, '(A)') '1 Rigid6 0.0 0.0 -4.0 0.0 0.0 0.0 100.0 0.05 0.0 100.0 100.0 0.0 0.0 20.0 20.0 20.0'
      ELSE
        WRITE (u, '(A)') '1 CoupledPinned 0.0 0.0 -4.0 0.0 0.0 0.0 100.0 0.05 0.0 0.0 0.0 0.0 0.0 20.0 20.0 20.0'
      END IF
    ELSE
      WRITE (u, '(A)') '--- ROD TYPES ---'
      WRITE (u, '(A)') 'Name Diam Mass Cd Ca CdEnd CaEnd'
      WRITE (u, '(A)') '(-) (m) (kg/m) (-) (-) (-) (-)'
      WRITE (u, '(A)') 'rodmat 0.20 50.0 1.0 1.0 0.0 0.0'
      WRITE (u, '(A)') '--- RODS ---'
      WRITE (u, '(A)') 'ID RodType Type XA YA ZA XB YB ZB NumSegs Outputs'
      WRITE (u, '(A)') '(-) (-) (-) (m) (m) (m) (m) (m) (m) (-) (-)'
      SELECT CASE (kind)
      CASE (1)
        WRITE (u, '(A)') '1 rodmat Free 0.0 0.0 -4.0 0.0 0.0 -2.0 2 -'
      CASE (3)
        WRITE (u, '(A)') '1 rodmat Coupled 0.0 0.0 -4.0 0.0 0.0 -2.0 2 -'
      CASE (4)
        WRITE (u, '(A)') '1 rodmat Pinned 0.0 0.0 -4.0 0.0 0.0 -2.0 2 -'
      CASE DEFAULT
        WRITE (u, '(A)') '1 rodmat CoupledPinned 0.0 0.0 -4.0 0.0 0.0 -2.0 2 -'
      END SELECT
    END IF
    WRITE (u, '(A)') '--- POINTS ---'
    WRITE (u, '(A)') 'ID Type X Y Z Mass Vol CdA Ca'
    WRITE (u, '(A)') '(-) (-) (m) (m) (m) (kg) (m3) (m2) (-)'
    WRITE (u, '(A)') '1 Fixed 2.0 0.0 -5.0 0.0 0.0 0.0 0.0'
    IF (kind == 2 .OR. kind == 6) THEN
      WRITE (u, '(A)') '2 Body1 0.0 0.0 0.0 0.0 0.0 0.0 0.0'
      WRITE (u, '(A)') '3 Coupled 0.0 0.0 -1.0 0.0 0.0 0.0 0.0'
    ELSE
      WRITE (u, '(A)') '2 Rod1A 0.0 0.0 -4.0 0.0 0.0 0.0 0.0'
      WRITE (u, '(A)') '3 Rod1B 0.0 0.0 -2.0 0.0 0.0 0.0 0.0'
      WRITE (u, '(A)') '4 Coupled 0.0 0.0 -1.0 0.0 0.0 0.0 0.0'
    END IF
    WRITE (u, '(A)') '--- LINES ---'
    WRITE (u, '(A)') 'ID NodeA NodeB Outputs'
    WRITE (u, '(A)') '(-) (-) (-) (-)'
    WRITE (u, '(A)') '1 2 1 -'
    IF (kind == 2 .OR. kind == 6) THEN
      WRITE (u, '(A)') '2 3 2 -'
    ELSE
      WRITE (u, '(A)') '2 3 4 -'
    END IF
    WRITE (u, '(A)') '--- SECTIONS ---'
    WRITE (u, '(A)') 'LineID LineType Length NumSegs'
    WRITE (u, '(A)') '(-) (-) (m) (-)'
    IF (kind == 2 .OR. kind == 6) THEN
      WRITE (u, '(A)') '1 line 2.5 3'
      WRITE (u, '(A)') '2 line 2.95 3'
    ELSE
      WRITE (u, '(A)') '1 line 3.5 3'
      WRITE (u, '(A)') '2 line 1.2 2'
    END IF
    WRITE (u, '(A)') '--- OPTIONS ---'
    WRITE (u, '(A)') '9.80665 g'
    WRITE (u, '(A)') '1025.0 rhoW'
    WRITE (u, '(A)') '10.0 WtrDpth'
    WRITE (u, '(A)') '1.0e5 kBot'
    WRITE (u, '(A)') '0.005 dtM'
    WRITE (u, '(A)') '1.0 TMax'
    ! the rod pinned at its lower end has no stable static balance: start from the deck pose
    IF (kind == 4) WRITE (u, '(A)') 'deck bodyIC'
    WRITE (u, '(A)') '--- end ---'
    CLOSE (u)
  END SUBROUTINE write_capi_object_deck

  SUBROUTINE require(cond, label)
    LOGICAL, INTENT(IN) :: cond
    CHARACTER(*), INTENT(IN) :: label
    IF (.NOT. cond) THEN
      WRITE (*, '(A,A,A)') 'MISMATCH [', TRIM(label), ']: condition false'
      nfail = nfail + 1
    END IF
  END SUBROUTINE require

  FUNCTION c_text(buffer) RESULT(text)
    CHARACTER(KIND=C_CHAR), INTENT(IN) :: buffer(:)
    CHARACTER(LEN=SIZE(buffer)) :: text

    INTEGER :: i

    text = ''
    DO i = 1, SIZE(buffer)
      IF (buffer(i) == C_NULL_CHAR) EXIT
      text(i:i) = buffer(i)
    END DO
  END FUNCTION c_text

  SUBROUTINE write_capi_deck(path)
    CHARACTER(*), INTENT(IN) :: path
    INTEGER :: u, ios

    OPEN (NEWUNIT=u, FILE=path, STATUS='REPLACE', ACTION='WRITE', IOSTAT=ios)
    CALL require(ios == 0, 'c-api-deck:create-file')
    IF (ios /= 0) RETURN
    WRITE (u, '(A)') 'C API deck init smoke'
    WRITE (u, '(A)') '--- LINE TYPES ---'
    WRITE (u, '(A)') 'Name Diam Mass EA BA EI Cdn Cdt Can Cat'
    WRITE (u, '(A)') '(-) (m) (kg/m) (N) (-) (Nm2) (-) (-) (-) (-)'
    WRITE (u, '(A)') 'line 0.10 80.0 1.0e5 0.0 0.0 1.0 0.0 1.0 0.0'
    WRITE (u, '(A)') '--- POINTS ---'
    WRITE (u, '(A)') 'ID Type X Y Z'
    WRITE (u, '(A)') '(-) (-) (m) (m) (m)'
    WRITE (u, '(A)') '1 Fixed 0.0 0.0 -1.0'
    WRITE (u, '(A)') '2 Coupled 0.8 0.0 -1.0'
    WRITE (u, '(A)') '--- LINES ---'
    WRITE (u, '(A)') 'ID NodeA NodeB Outputs'
    WRITE (u, '(A)') '(-) (-) (-) (-)'
    WRITE (u, '(A)') '1 2 1 -'
    WRITE (u, '(A)') '--- SECTIONS ---'
    WRITE (u, '(A)') 'LineID LineType Length NumSegs'
    WRITE (u, '(A)') '(-) (-) (m) (-)'
    WRITE (u, '(A)') '1 line 1.0 1'
    WRITE (u, '(A)') '--- OPTIONS ---'
    WRITE (u, '(A)') '9.80665 g'
    WRITE (u, '(A)') '1025.0 rhoW'
    WRITE (u, '(A)') '5.0 WtrDpth'
    WRITE (u, '(A)') '--- OUTPUTS ---'
    WRITE (u, '(A)') 'FairTen1 AnchTen1'
    WRITE (u, '(A)') '--- end ---'
    CLOSE (u)
  END SUBROUTINE write_capi_deck

  SUBROUTINE write_bad_capi_deck(path)
    CHARACTER(*), INTENT(IN) :: path
    INTEGER :: u, ios

    OPEN (NEWUNIT=u, FILE=path, STATUS='REPLACE', ACTION='WRITE', IOSTAT=ios)
    CALL require(ios == 0, 'c-api-bad-deck:create-file')
    IF (ios /= 0) RETURN
    WRITE (u, '(A)') 'bad deck'
    WRITE (u, '(A)') '--- POINTS ---'
    WRITE (u, '(A)') 'ID Type X Y Z'
    WRITE (u, '(A)') '1 Fixed 0.0 0.0 0.0'
    CLOSE (u)
  END SUBROUTINE write_bad_capi_deck

  SUBROUTINE write_capi_connect_deck(path)
    CHARACTER(*), INTENT(IN) :: path
    INTEGER :: u, ios

    OPEN (NEWUNIT=u, FILE=path, STATUS='REPLACE', ACTION='WRITE', IOSTAT=ios)
    CALL require(ios == 0, 'c-api-connect-deck:create-file')
    IF (ios /= 0) RETURN
    WRITE (u, '(A)') 'C API dynamic Connect deck'
    WRITE (u, '(A)') '--- LINE TYPES ---'
    WRITE (u, '(A)') 'Name Diam Mass EA BA EI Cdn Cdt Can Cat'
    WRITE (u, '(A)') '(-) (m) (kg/m) (N) (-) (Nm2) (-) (-) (-) (-)'
    WRITE (u, '(A)') 'line 0.10 80.0 1.0e5 0.0 0.0 1.0 0.0 1.0 0.0'
    WRITE (u, '(A)') '--- POINTS ---'
    WRITE (u, '(A)') 'ID Type X Y Z Mass Vol CdA Ca'
    WRITE (u, '(A)') '(-) (-) (m) (m) (m) (kg) (m3) (m2) (-)'
    WRITE (u, '(A)') '1 Fixed 0.0 0.0 -0.5 0.0 0.0 0.0 0.0'
    WRITE (u, '(A)') '2 Connect 1.0 0.0 -0.5 20.0 0.0195121951 2.0 1.0'
    WRITE (u, '(A)') '3 Fixed 2.0 0.0 -0.5 0.0 0.0 0.0 0.0'
    WRITE (u, '(A)') '--- LINES ---'
    WRITE (u, '(A)') 'ID NodeA NodeB Outputs'
    WRITE (u, '(A)') '(-) (-) (-) (-)'
    WRITE (u, '(A)') '1 2 1 -'
    WRITE (u, '(A)') '2 2 3 -'
    WRITE (u, '(A)') '--- SECTIONS ---'
    WRITE (u, '(A)') 'LineID LineType Length NumSegs'
    WRITE (u, '(A)') '(-) (-) (m) (-)'
    WRITE (u, '(A)') '1 line 1.0 1'
    WRITE (u, '(A)') '2 line 1.0 1'
    WRITE (u, '(A)') '--- OPTIONS ---'
    WRITE (u, '(A)') '9.80665 g'
    WRITE (u, '(A)') '1025.0 rhoW'
    WRITE (u, '(A)') '10.0 WtrDpth'
    WRITE (u, '(A)') '1.0e5 kBot'
    WRITE (u, '(A)') '0.005 dtM'
    WRITE (u, '(A)') '0.01 TMax'
    WRITE (u, '(A)') '--- OUTPUTS ---'
    WRITE (u, '(A)') 'FairTen1 FairTen2'
    WRITE (u, '(A)') '--- end ---'
    CLOSE (u)
  END SUBROUTINE write_capi_connect_deck

END PROGRAM test_c_api
