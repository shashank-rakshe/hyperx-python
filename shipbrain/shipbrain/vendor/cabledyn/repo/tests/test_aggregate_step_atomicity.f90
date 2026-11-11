! File: tests/test_aggregate_step_atomicity.f90
! SPDX-License-Identifier: Apache-2.0
! Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
PROGRAM test_aggregate_step_atomicity
  !! A coupled step on a Rigid6 deck that the post-step plausibility guard rejects (a line
  !! stretched beyond maxStrain) is rolled back as a whole: the body returns to its
  !! step-start state together with the lines, and a retry of the same interval with an
  !! admissible motion gives the result of an aggregate that never saw the rejected step.
  !! Through the C API the rejected step reports converged = stalled = false, n_iter = 0,
  !! and CableDyn_EvalChannel reads a NUL-terminated token from a longer caller buffer.
  USE, INTRINSIC :: ISO_C_BINDING, ONLY: C_BOOL, C_CHAR, C_DOUBLE, C_INT, C_LOC, C_PTR
  USE CableDyn_Precision, ONLY: wp
  USE CableDyn_OpenFAST_Aggregate, ONLY: CD_AGG_ModuleType, CD_AGG_Init_From_Deck, CD_AGG_Step_Moving, &
                                         CD_AGG_CalcOutput, CD_AGG_GetMovingPointMesh, CD_AGG_End, &
                                         CD_AGG_Rigid6_MirrorSize, CD_AGG_Get_Rigid6_States, CD_AGG_OK
  USE CableDyn_CAPI, ONLY: CableDyn_Create, CableDyn_Close, CableDyn_InitDeck, CableDyn_Step, &
                           CableDyn_GetCoupledMotion, CableDyn_GetLastError, CableDyn_EvalChannel
  IMPLICIT NONE

  REAL(wp), PARAMETER :: DT = 0.005_wp, LIFT = 0.3_wp
  CHARACTER(*), PARAMETER :: DECK = 'agg_atomic_rigid6.dat'
  INTEGER :: nfail
  ! Program-scope (static) aggregates: the stepped one and a reference that never sees the
  ! rejected step.
  TYPE(CD_AGG_ModuleType) :: agg, ref

  nfail = 0
  CALL write_deck(DECK)
  CALL case_aggregate_rollback()
  CALL case_capi_failure_flags()
  IF (nfail > 0) THEN
    WRITE (*, '(A,I0,A)') 'FAIL: ', nfail, ' assertion(s) failed'
    ERROR STOP 1
  END IF
  WRITE (*, '(A)') 'PASS: a rejected coupled Rigid6 step is rolled back as a whole'

CONTAINS

  INCLUDE 'nan_max_abs.inc'

  SUBROUTINE case_aggregate_rollback()
    REAL(wp) :: r0(3, 1), v0(3, 1), a0(3, 1), l0(3, 1), rl(3, 1), pa(3, 1), la(3, 1), pr(3, 1), lr(3, 1)
    REAL(wp), ALLOCATABLE :: b0(:), b1(:), ba(:), br(:)
    LOGICAL :: conv, stall
    INTEGER :: es, nit, nb
    CHARACTER(512) :: em

    CALL CD_AGG_Init_From_Deck(agg, DECK, DT, es, em)
    CALL require(es == CD_AGG_OK, 'aggregate: init: '//TRIM(em))
    IF (es /= CD_AGG_OK) RETURN
    CALL CD_AGG_Init_From_Deck(ref, DECK, DT, es, em)
    CALL require(es == CD_AGG_OK, 'aggregate: reference init: '//TRIM(em))
    IF (es /= CD_AGG_OK) RETURN
    CALL CD_AGG_GetMovingPointMesh(agg, r0, v0, a0, l0, es, em)
    v0 = 0.0_wp
    a0 = 0.0_wp
    nb = CD_AGG_Rigid6_MirrorSize(agg)
    CALL require(nb > 0, 'aggregate: the deck carries a Rigid6 body')
    ALLOCATE (b0(nb), b1(nb), ba(nb), br(nb))
    CALL CD_AGG_Get_Rigid6_States(agg, b0, es, em)

    ! Lift the fairlead abruptly: the line to the body stretches beyond maxStrain.
    rl = r0
    rl(3, 1) = r0(3, 1) + LIFT
    CALL CD_AGG_Step_Moving(agg, DT, rl, v0, a0, conv, stall, nit, es, em, t_committed=DT)
    CALL require(es /= CD_AGG_OK, 'aggregate: the over-stretching step is rejected')
    CALL require(INDEX(em, 'maxStrain') > 0, 'aggregate: rejected by the plausibility guard: '//TRIM(em))
    CALL CD_AGG_Get_Rigid6_States(agg, b1, es, em)
    CALL require(nan_max_abs(b1 - b0) <= 0.0_wp, 'aggregate: the body is back at its step-start state')

    ! Retry with the fairlead held: identical to an aggregate that never saw the rejected step.
    CALL CD_AGG_Step_Moving(agg, DT, r0, v0, a0, conv, stall, nit, es, em, t_committed=DT)
    CALL require(es == CD_AGG_OK, 'aggregate: retry: '//TRIM(em))
    CALL CD_AGG_Step_Moving(ref, DT, r0, v0, a0, conv, stall, nit, es, em, t_committed=DT)
    CALL require(es == CD_AGG_OK, 'aggregate: reference step: '//TRIM(em))
    CALL CD_AGG_CalcOutput(agg, es, em)
    CALL CD_AGG_GetMovingPointMesh(agg, pa, v0, a0, la, es, em)
    CALL CD_AGG_CalcOutput(ref, es, em)
    CALL CD_AGG_GetMovingPointMesh(ref, pr, v0, a0, lr, es, em)
    v0 = 0.0_wp
    a0 = 0.0_wp
    CALL CD_AGG_Get_Rigid6_States(agg, ba, es, em)
    CALL CD_AGG_Get_Rigid6_States(ref, br, es, em)
    CALL require(nan_max_abs(ba - br) <= 0.0_wp, 'aggregate: retried body state equals the reference')
    CALL require(nan_max_abs(la - lr) <= 0.0_wp, 'aggregate: retried fairlead load equals the reference')
    CALL CD_AGG_End(agg, es, em)
    CALL CD_AGG_End(ref, es, em)
  END SUBROUTINE case_aggregate_rollback

  SUBROUTINE case_capi_failure_flags()
    TYPE(C_PTR) :: handle
    CHARACTER(KIND=C_CHAR), TARGET :: c_path(LEN(DECK)), msg(1024), tok(100)
    REAL(C_DOUBLE) :: val
    CHARACTER(*), PARAMETER :: CHANNEL = 'FairTen2'
    REAL(C_DOUBLE), TARGET :: q(3), v(3), a(3)
    LOGICAL(C_BOOL) :: conv, stall
    INTEGER(C_INT) :: es, nit
    INTEGER :: i
    DO i = 1, LEN(DECK)
      c_path(i) = DECK(i:i)
    END DO
    CALL CableDyn_Create(handle, es)
    CALL require(es == 0_C_INT, 'c-api: create')
    CALL CableDyn_InitDeck(handle, C_LOC(c_path), INT(LEN(DECK), C_INT), es)
    CALL CableDyn_GetLastError(handle, C_LOC(msg), INT(SIZE(msg), C_INT))
    CALL require(es == 0_C_INT, 'c-api: init: '//c_text(msg))
    IF (es /= 0_C_INT) RETURN
    CALL CableDyn_GetCoupledMotion(handle, C_LOC(q), C_LOC(v), C_LOC(a), 3_C_INT, es)
    CALL require(es == 0_C_INT, 'c-api: coupled motion')
    ! A 100-character buffer holding "FairTen2" and a NUL: the buffer length is not the
    ! token length.
    tok = ACHAR(0)
    DO i = 1, 8
      tok(i) = CHANNEL(i:i)
    END DO
    CALL CableDyn_EvalChannel(handle, C_LOC(tok), INT(SIZE(tok), C_INT), val, es)
    CALL CableDyn_GetLastError(handle, C_LOC(msg), INT(SIZE(msg), C_INT))
    CALL require(es == 0_C_INT .AND. val > 0.0_C_DOUBLE, 'c-api: channel token from a longer buffer: '//c_text(msg))
    tok = 'x'
    CALL CableDyn_EvalChannel(handle, C_LOC(tok), INT(SIZE(tok), C_INT), val, es)
    CALL require(es /= 0_C_INT, 'c-api: a token longer than 64 characters is rejected')
    v = 0.0_C_DOUBLE
    a = 0.0_C_DOUBLE
    q(3) = q(3) + REAL(LIFT, C_DOUBLE)
    conv = .TRUE._C_BOOL
    stall = .TRUE._C_BOOL
    nit = 7_C_INT
    CALL CableDyn_Step(handle, REAL(DT, C_DOUBLE), C_LOC(q), C_LOC(v), C_LOC(a), 3_C_INT, conv, stall, nit, es)
    CALL CableDyn_GetLastError(handle, C_LOC(msg), INT(SIZE(msg), C_INT))
    CALL require(es /= 0_C_INT .AND. INDEX(c_text(msg), 'maxStrain') > 0, 'c-api: the over-stretching step fails')
    CALL require(.NOT. LOGICAL(conv) .AND. .NOT. LOGICAL(stall) .AND. nit == 0_C_INT, &
                 'c-api: a failed step reports converged = stalled = false and n_iter = 0')
    CALL CableDyn_Close(handle, es)
  END SUBROUTINE case_capi_failure_flags

  SUBROUTINE write_deck(path)
    !! A submerged Rigid6 body hung between a Fixed anchor and a Coupled fairlead by two chain
    !! lines in still water, with a 5 % maxStrain plausibility bound (the static strain is about 3.5 %).
    CHARACTER(*), INTENT(IN) :: path
    INTEGER :: u
    OPEN (NEWUNIT=u, FILE=path, STATUS='REPLACE', ACTION='WRITE')
    WRITE (u, '(A)') 'coupled rigid6 body deck'
    WRITE (u, '(A)') '--- LINE TYPES ---'
    WRITE (u, '(A)') 'Name Diam Mass EA BA EI Cdn Cdt Can Cat'
    WRITE (u, '(A)') '(-) (m) (kg/m) (N) (-) (Nm2) (-) (-) (-) (-)'
    WRITE (u, '(A)') 'line 0.10 80.0 1.0e5 0.0 0.0 1.0 0.0 1.0 0.0'
    WRITE (u, '(A)') '--- BODIES ---'
    WRITE (u, '(A)') 'ID Type X Y Z Rot1 Rot2 Rot3 Mass Vol C33 C44 C55 CdA Ca Ixx Iyy Izz'
    WRITE (u, '(A)') '(-) (-) (m) (m) (m) (deg) (deg) (deg) (kg) (m3) (N/m) (Nm/rad) (Nm/rad) (m2) (-) '// &
      '(kgm2) (kgm2) (kgm2)'
    WRITE (u, '(A)') '1 Rigid6 0.0 0.0 -4.0 0.0 0.0 0.0 100.0 0.05 0.0 100.0 100.0 0.0 0.0 20.0 20.0 20.0'
    WRITE (u, '(A)') '--- POINTS ---'
    WRITE (u, '(A)') 'ID Type X Y Z Mass Vol CdA Ca'
    WRITE (u, '(A)') '(-) (-) (m) (m) (m) (kg) (m3) (m2) (-)'
    WRITE (u, '(A)') '1 Fixed 2.0 0.0 -5.0 0.0 0.0 0.0 0.0'
    WRITE (u, '(A)') '2 Body1 0.0 0.0 0.0 0.0 0.0 0.0 0.0'
    WRITE (u, '(A)') '3 Coupled 0.0 0.0 -1.0 0.0 0.0 0.0 0.0'
    WRITE (u, '(A)') '--- LINES ---'
    WRITE (u, '(A)') 'ID NodeA NodeB Outputs'
    WRITE (u, '(A)') '(-) (-) (-) (-)'
    WRITE (u, '(A)') '1 2 1 -'
    WRITE (u, '(A)') '2 3 2 -'
    WRITE (u, '(A)') '--- SECTIONS ---'
    WRITE (u, '(A)') 'LineID LineType Length NumSegs'
    WRITE (u, '(A)') '(-) (-) (m) (-)'
    WRITE (u, '(A)') '1 line 2.5 3'
    WRITE (u, '(A)') '2 line 2.95 3'
    WRITE (u, '(A)') '--- OPTIONS ---'
    WRITE (u, '(A)') '9.80665 g'
    WRITE (u, '(A)') '1025.0 rhoW'
    WRITE (u, '(A)') '10.0 WtrDpth'
    WRITE (u, '(A)') '1.0e5 kBot'
    WRITE (u, '(A)') '0.05 maxStrain'
    WRITE (u, '(A)') '0.005 dtM'
    WRITE (u, '(A)') '1.0 TMax'
    WRITE (u, '(A)') '--- OUTPUTS ---'
    WRITE (u, '(A)') 'FairTen2'
    WRITE (u, '(A)') '--- end ---'
    CLOSE (u)
  END SUBROUTINE write_deck

  FUNCTION c_text(buf) RESULT(txt)
    CHARACTER(KIND=C_CHAR), INTENT(IN) :: buf(:)
    CHARACTER(:), ALLOCATABLE :: txt
    INTEGER :: i
    txt = ''
    DO i = 1, SIZE(buf)
      IF (buf(i) == ACHAR(0)) EXIT
      txt = txt//buf(i)
    END DO
  END FUNCTION c_text

  SUBROUTINE require(cond, label)
    LOGICAL, INTENT(IN) :: cond
    CHARACTER(*), INTENT(IN) :: label
    IF (.NOT. cond) THEN
      WRITE (*, '(A,A,A)') 'MISMATCH [', label, ']: condition false'
      nfail = nfail + 1
    END IF
  END SUBROUTINE require

END PROGRAM test_aggregate_step_atomicity
