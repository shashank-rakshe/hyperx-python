! SPDX-License-Identifier: Apache-2.0
! Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
PROGRAM test_line_values
  !! CableDyn_GetLineValues evaluates a line at once; every value must be the bit pattern of the
  !! output channel of its node, whatever the route. Each deck runs twice, at the static start and
  !! after a few moving steps, so velocity and acceleration are not zero:
  !!
  !! * through the C API, every value at a deck node against CableDyn_EvalChannel (the row of deck
  !!   node J comes from CD_C_LINE_DECK_NODE), on the point and the aggregate routes;
  !! * on the aggregate, every value at every node of the final mesh, including the nodes a
  !!   refinement added, against CD_Eval_Aggregate_Channel with mesh_node = .TRUE.
  !!
  !! The set: a cable on +x (no frame heading), with a heading, just below +x (the signed azimuth
  !! range), on -x, OutputRecovery element, a bend stiffener under both recoveries, restrained in
  !! torsion with a rolling host, beside an EI = 0 line, EI = 0 lines alone, a mesh the static solve
  !! refines, and decks with bodies or rods. A state with a NaN then fails at the same value on
  !! both paths.
  !!
  !! Lines on headings on both sides of +x, EI = 0 alone and beside cables, must report the azimuth
  !! range of their deck chord (doc/outputs.rst) through the line values, the channels, the
  !! aggregate's channels (the OpenFAST shell's) and its initialisation summary.
  !!
  !! usage: test_line_values <coarse lazy-wave deck>
  USE, INTRINSIC :: ISO_C_BINDING, ONLY: C_BOOL, C_CHAR, C_DOUBLE, C_INT, C_LOC, C_NULL_PTR, C_PTR
  USE, INTRINSIC :: ISO_FORTRAN_ENV, ONLY: INT64
  USE, INTRINSIC :: IEEE_ARITHMETIC, ONLY: IEEE_IS_NAN, IEEE_QUIET_NAN, IEEE_VALUE
  USE CableDyn_Precision, ONLY: wp
  USE CableDyn_CAPI, ONLY: CableDyn_Create, CableDyn_Close, CableDyn_InitDeck, CableDyn_InitDeckRotating, &
                           CableDyn_Step, CableDyn_GetCoupledMotion, CableDyn_GetLastError, CableDyn_EvalChannel, &
                           CableDyn_GetLineValues, CableDyn_GetObjectInfo, CableDyn_NCoupledDOF, CableDyn_NObjects, &
                           CableDyn_UpdateRotations
  USE CableDyn_DeckDriver, ONLY: CD_Deck_Query_dtM, CD_DECKDRV_OK, CD_Eval_Aggregate_Channel, &
                                 CD_Eval_Aggregate_Line_Values
  USE CableDyn_OpenFAST_Aggregate, ONLY: CD_AGG_ModuleType, CD_AGG_End, CD_AGG_EvalChannel, CD_AGG_GetInitLine, &
                                         CD_AGG_GetMovingPointMesh, CD_AGG_Init_From_Deck, CD_AGG_NMovingPoints, &
                                         CD_AGG_NumChannels, CD_AGG_OK, CD_AGG_Step_Moving
  USE CableDyn_System, ONLY: CD_System_Line_NDOF
  IMPLICIT NONE

  INTEGER, PARAMETER :: NSTEPS = 4, N_QUANTITY = 8
  INTEGER(C_INT), PARAMETER :: LINE_KIND = 1_C_INT, DECK_NODE = 10_C_INT
  INTEGER, PARAMETER :: QUANTITY(N_QUANTITY) = [1, 2, 4, 3, 5, 6, 7, 8]
  REAL(wp), PARAMETER :: SWAY = 0.05_wp, RATE = 4.0_wp, ROLL = 0.02_wp, PI = 4.0_wp*ATAN(1.0_wp)
  ! Line headings [deg]: within 45 deg of +x on either side, just outside it, and elsewhere.
  REAL(wp), PARAMETER :: HEADINGS(12) = [-46.0_wp, -44.0_wp, -30.0_wp, -10.0_wp, -1.0_wp, 1.0_wp, 10.0_wp, 30.0_wp, &
                                         44.0_wp, 46.0_wp, 180.0_wp, 270.0_wp]
  INTEGER :: nfail
  INTEGER(INT64) :: n_capi, n_mesh, n_added
  CHARACTER(1024) :: arg

  nfail = 0
  n_capi = 0
  n_mesh = 0
  n_added = 0
  IF (COMMAND_ARGUMENT_COUNT() /= 1) ERROR STOP 'usage: test_line_values <coarse lazy-wave deck>'

  CALL write_cable_deck('lv_plain.dat', 0.0_wp)
  CALL check_deck('lv_plain.dat')
  CALL write_cable_deck('lv_heading.dat', 40.0_wp)
  CALL check_deck('lv_heading.dat', corrupt=.TRUE.)
  CALL write_cable_deck('lv_signed.dat', 340.0_wp)
  CALL check_deck('lv_signed.dat')
  CALL write_cable_deck('lv_reversed.dat', 180.0_wp)
  CALL check_deck('lv_reversed.dat')
  CALL write_cable_deck('lv_element.dat', 130.0_wp, element_recovery=.TRUE.)
  CALL check_deck('lv_element.dat', corrupt=.TRUE.)
  CALL write_cable_deck('lv_stiffener.dat', 250.0_wp, stiffener=.TRUE.)
  CALL check_deck('lv_stiffener.dat')
  CALL write_cable_deck('lv_stiffener_element.dat', 310.0_wp, stiffener=.TRUE., element_recovery=.TRUE.)
  CALL check_deck('lv_stiffener_element.dat')
  CALL write_cable_deck('lv_torsion.dat', 40.0_wp, torsion=.TRUE.)
  CALL check_deck('lv_torsion.dat', rotating=.TRUE.)
  CALL write_cable_deck('lv_torsion_element.dat', 220.0_wp, torsion=.TRUE., element_recovery=.TRUE.)
  CALL check_deck('lv_torsion_element.dat', rotating=.TRUE.)
  CALL write_cable_deck('lv_mixed.dat', 40.0_wp, chain=.TRUE.)
  CALL check_deck('lv_mixed.dat')
  CALL write_chain_deck('lv_chains.dat')
  CALL check_deck('lv_chains.dat', corrupt=.TRUE.)
  CALL GET_COMMAND_ARGUMENT(1, arg)
  CALL write_refined_deck(TRIM(arg), 'lv_refined.dat')
  CALL check_deck('lv_refined.dat', refined=.TRUE.)
  CALL write_object_deck('lv_body.dat', body=.TRUE.)
  CALL check_deck('lv_body.dat')
  CALL write_object_deck('lv_rod.dat', body=.FALSE.)
  CALL check_deck('lv_rod.dat')
  CALL write_heading_deck('lv_range_chains.dat', cables=.FALSE.)
  CALL check_deck('lv_range_chains.dat')
  CALL check_azimuth_range('lv_range_chains.dat')
  CALL write_heading_deck('lv_range_mixed.dat', cables=.TRUE.)
  CALL check_deck('lv_range_mixed.dat')
  CALL check_azimuth_range('lv_range_mixed.dat')

  WRITE (*, '(A,I0,A,I0,A,I0,A)') 'compared ', n_capi, ' values with CableDyn_EvalChannel and ', n_mesh, &
    ' with the mesh-node channels (', n_added, ' at added nodes)'
  CALL require(n_capi > 10000 .AND. n_mesh > n_capi .AND. n_added > 0, 'the set reaches every route')
  IF (nfail > 0) THEN
    WRITE (*, '(A,I0,A)') 'FAIL: ', nfail, ' assertion(s) failed'
    ERROR STOP 1
  END IF
  WRITE (*, '(A)') 'PASS: the whole-line values are the channels bit for bit'

CONTAINS

  SUBROUTINE require(cond, msg)
    LOGICAL, INTENT(IN) :: cond
    CHARACTER(*), INTENT(IN) :: msg
    IF (cond) RETURN
    nfail = nfail + 1
    WRITE (*, '(2A)') 'FAIL: ', msg
  END SUBROUTINE require

  LOGICAL FUNCTION same_bits(a, b) RESULT(same)
    !! The same bit pattern, or both NaN (a NaN's sign and payload carry no value).
    REAL(wp), INTENT(IN) :: a, b
    same = TRANSFER(a, 0_INT64) == TRANSFER(b, 0_INT64)
    IF (.NOT. same) same = IEEE_IS_NAN(a) .AND. IEEE_IS_NAN(b)
  END FUNCTION same_bits

  PURE FUNCTION text(i) RESULT(s)
    INTEGER, INTENT(IN) :: i
    CHARACTER(:), ALLOCATABLE :: s
    CHARACTER(16) :: b
    WRITE (b, '(I0)') i
    s = TRIM(b)
  END FUNCTION text

  PURE INTEGER FUNCTION width(kind) RESULT(n)
    INTEGER, INTENT(IN) :: kind
    n = MERGE(3, 1, kind == 1 .OR. kind == 2 .OR. kind == 4)
  END FUNCTION width

  PURE FUNCTION token(kind, line_id, node, comp) RESULT(s)
    !! The channel of a quantity at a node, component comp of a vector.
    INTEGER, INTENT(IN) :: kind, line_id, node, comp
    CHARACTER(:), ALLOCATABLE :: s, stem
    CHARACTER(1), PARAMETER :: xyz(3) = ['x', 'y', 'z']
    stem = text(line_id)//'N'//text(node)
    SELECT CASE (kind)
    CASE (1)
      s = 'L'//stem//'p'//xyz(comp)
    CASE (2)
      s = 'L'//stem//'v'//xyz(comp)
    CASE (4)
      s = 'L'//stem//'a'//xyz(comp)
    CASE (3)
      s = 'Ten'//stem
    CASE (5)
      s = 'Curv'//stem
    CASE (6)
      s = 'BendMom'//stem
    CASE (7)
      s = 'L'//stem//'Dec'
    CASE DEFAULT
      s = 'L'//stem//'Azi'
    END SELECT
  END FUNCTION token

  SUBROUTINE check_deck(path, rotating, refined, corrupt)
    CHARACTER(*), INTENT(IN) :: path
    LOGICAL, INTENT(IN), OPTIONAL :: rotating, refined, corrupt
    LOGICAL :: rot
    REAL(wp) :: dt
    LOGICAL :: has_dt
    INTEGER :: es
    CHARACTER(512) :: em

    rot = .FALSE.
    IF (PRESENT(rotating)) rot = rotating
    CALL CD_Deck_Query_dtM(path, dt, has_dt, es, em)
    CALL require(es == CD_DECKDRV_OK .AND. has_dt, path//': dtM: '//TRIM(em))
    IF (es /= CD_DECKDRV_OK .OR. .NOT. has_dt) RETURN
    CALL check_capi(path, dt, rot, refined)
    CALL check_aggregate(path, dt, rot, corrupt)
  END SUBROUTINE check_deck

  SUBROUTINE check_capi(path, dt, rot, refined)
    CHARACTER(*), INTENT(IN) :: path
    REAL(wp), INTENT(IN) :: dt
    LOGICAL, INTENT(IN) :: rot
    LOGICAL, INTENT(IN), OPTIONAL :: refined
    TYPE(C_PTR) :: h
    INTEGER(C_INT) :: es, n, n_iter
    LOGICAL(C_BOOL) :: conv, stall
    CHARACTER(C_CHAR), TARGET :: c_path(1024), msg(512)
    REAL(C_DOUBLE), ALLOCATABLE, TARGET :: q0(:), q(:), v(:), a(:), dcm(:), om(:), al(:)
    INTEGER :: k, s, j
    REAL(wp) :: t, phi

    c_path = ' '
    DO k = 1, LEN(path)
      c_path(k) = path(k:k)
    END DO
    CALL CableDyn_Create(h, es)
    IF (rot) THEN
      CALL CableDyn_InitDeckRotating(h, C_LOC(c_path), INT(LEN(path), C_INT), C_NULL_PTR, 0_C_INT, es)
    ELSE
      CALL CableDyn_InitDeck(h, C_LOC(c_path), INT(LEN(path), C_INT), es)
    END IF
    CALL CableDyn_GetLastError(h, C_LOC(msg), INT(SIZE(msg), C_INT))
    CALL require(es == 0_C_INT, path//': init: '//last_error(msg))
    IF (es /= 0_C_INT) THEN
      CALL CableDyn_Close(h, es)
      RETURN
    END IF
    CALL compare_capi(h, path//' at rest', refined)
    n = CableDyn_NCoupledDOF(h, es)
    IF (n > 0_C_INT) THEN
      ALLOCATE (q0(n), q(n), v(n), a(n), dcm(3*n), om(n), al(n))
      CALL CableDyn_GetCoupledMotion(h, C_LOC(q0), C_LOC(v), C_LOC(a), n, es)
      DO s = 1, NSTEPS
        t = dt*REAL(s, wp)
        q = q0
        v = 0.0_C_DOUBLE
        a = 0.0_C_DOUBLE
        q(1:n:3) = q0(1:n:3) + SWAY*SIN(RATE*t)
        v(1:n:3) = SWAY*RATE*COS(RATE*t)
        a(1:n:3) = -SWAY*RATE**2*SIN(RATE*t)
        IF (rot) THEN
          phi = ROLL*REAL(s, wp)/REAL(NSTEPS, wp)
          om = 0.0_C_DOUBLE
          al = 0.0_C_DOUBLE
          om(1:n:3) = ROLL/(REAL(NSTEPS, wp)*dt)
          DO j = 0, INT(n)/3 - 1
            dcm(9*j + 1:9*j + 9) = RESHAPE(TRANSPOSE(roll_dcm(phi)), [9])
          END DO
          CALL CableDyn_UpdateRotations(h, C_LOC(dcm), C_LOC(om), C_LOC(al), n/3_C_INT, es)
          CALL require(es == 0_C_INT, path//': rotations')
        END IF
        CALL CableDyn_Step(h, REAL(dt, C_DOUBLE), C_LOC(q), C_LOC(v), C_LOC(a), n, conv, stall, n_iter, es)
        CALL CableDyn_GetLastError(h, C_LOC(msg), INT(SIZE(msg), C_INT))
        CALL require(es == 0_C_INT, path//': step: '//last_error(msg))
        IF (es /= 0_C_INT) EXIT
      END DO
      CALL compare_capi(h, path//' stepped')
    END IF
    CALL CableDyn_Close(h, es)
  END SUBROUTINE check_capi

  FUNCTION last_error(msg) RESULT(s)
    CHARACTER(C_CHAR), INTENT(IN) :: msg(:)
    CHARACTER(:), ALLOCATABLE :: s
    INTEGER :: k
    s = ''
    DO k = 1, SIZE(msg)
      IF (IACHAR(msg(k)) == 0) EXIT
      s = s//msg(k)
    END DO
  END FUNCTION last_error

  PURE FUNCTION roll_dcm(phi) RESULT(r)
    !! The global-to-body DCM of a roll phi about +x.
    REAL(wp), INTENT(IN) :: phi
    REAL(wp) :: r(3, 3)
    r = RESHAPE([1.0_wp, 0.0_wp, 0.0_wp, 0.0_wp, COS(phi), -SIN(phi), 0.0_wp, SIN(phi), COS(phi)], [3, 3])
  END FUNCTION roll_dcm

  SUBROUTINE compare_capi(h, label, refined)
    !! Every value at a deck node of every line against its channel.
    TYPE(C_PTR), INTENT(IN) :: h
    CHARACTER(*), INTENT(IN) :: label
    LOGICAL, INTENT(IN), OPTIONAL :: refined
    INTEGER(C_INT) :: es, n_lines, il, id, nn, sub
    REAL(C_DOUBLE), ALLOCATABLE, TARGET :: vals(:), deck(:)
    REAL(C_DOUBLE) :: val
    CHARACTER(C_CHAR), TARGET :: tok(64)
    CHARACTER(:), ALLOCATABLE :: name
    INTEGER :: iq, w, node, c, j, k, bad, n_added_here

    n_lines = CableDyn_NObjects(h, LINE_KIND, es)
    CALL require(es == 0_C_INT .AND. n_lines > 0_C_INT, label//': lines')
    n_added_here = 0
    DO il = 0_C_INT, n_lines - 1_C_INT
      CALL CableDyn_GetObjectInfo(h, LINE_KIND, il, id, nn, sub, es)
      CALL require(es == 0_C_INT, label//': line info')
      IF (ALLOCATED(deck)) DEALLOCATE (deck)
      ALLOCATE (deck(nn))
      CALL CableDyn_GetLineValues(h, il, DECK_NODE, C_LOC(deck), nn, es)
      CALL require(es == 0_C_INT, label//': deck nodes')
      n_added_here = n_added_here + COUNT(NINT(deck) == 0)
      DO iq = 1, N_QUANTITY
        w = width(QUANTITY(iq))
        IF (ALLOCATED(vals)) DEALLOCATE (vals)
        ALLOCATE (vals(w*nn))
        CALL CableDyn_GetLineValues(h, il, INT(QUANTITY(iq), C_INT), C_LOC(vals), INT(w*nn, C_INT), es)
        CALL require(es == 0_C_INT, label//': line values')
        IF (es /= 0_C_INT) CYCLE
        bad = 0
        DO node = 1, INT(nn)
          j = NINT(deck(node))
          IF (j == 0) CYCLE
          DO c = 1, w
            name = token(QUANTITY(iq), INT(id), j, c)
            DO k = 1, LEN(name)
              tok(k) = name(k:k)
            END DO
            CALL CableDyn_EvalChannel(h, C_LOC(tok), INT(LEN(name), C_INT), val, es)
            n_capi = n_capi + 1
            IF (es /= 0_C_INT) THEN
              bad = bad + 1
            ELSE IF (.NOT. same_bits(vals(w*(node - 1) + c), val)) THEN
              bad = bad + 1
              IF (bad == 1) WRITE (*, '(A,1X,A,2ES25.16)') label, name, vals(w*(node - 1) + c), val
            END IF
          END DO
        END DO
        CALL require(bad == 0, label//': quantity '//text(QUANTITY(iq))//' of line '//text(INT(id))//': '// &
                     text(bad)//' values differ from their channels')
      END DO
    END DO
    IF (PRESENT(refined)) CALL require(n_added_here > 0, label//': the static solve refines the mesh')
    ! the entry's own checks
    CALL CableDyn_GetLineValues(h, n_lines, 1_C_INT, C_LOC(deck), 3_C_INT, es)
    CALL require(es /= 0_C_INT, label//': an index past the lines is rejected')
    CALL CableDyn_GetLineValues(h, -1_C_INT, 1_C_INT, C_LOC(deck), 3_C_INT, es)
    CALL require(es /= 0_C_INT, label//': a negative index is rejected')
  END SUBROUTINE compare_capi

  SUBROUTINE check_aggregate(path, dt, rot, corrupt)
    CHARACTER(*), INTENT(IN) :: path
    REAL(wp), INTENT(IN) :: dt
    LOGICAL, INTENT(IN) :: rot
    LOGICAL, INTENT(IN), OPTIONAL :: corrupt
    TYPE(CD_AGG_ModuleType) :: agg
    INTEGER :: es, n, s, nit, id, k
    LOGICAL :: cv, st, bad_state
    REAL(wp) :: t, phi
    REAL(wp), ALLOCATABLE :: p0(:, :), p(:, :), pv(:, :), pa(:, :), pl(:, :), dcm(:, :, :), om(:, :), al(:, :)
    CHARACTER(512) :: em

    IF (rot) THEN
      CALL CD_AGG_Init_From_Deck(agg, path, dt, es, em, host_orientation=.TRUE.)
    ELSE
      CALL CD_AGG_Init_From_Deck(agg, path, dt, es, em)
    END IF
    CALL require(es == CD_AGG_OK, path//': aggregate: '//TRIM(em))
    IF (es /= CD_AGG_OK) RETURN
    CALL compare_mesh(agg, path//' at rest')
    n = CD_AGG_NMovingPoints(agg, es, em)
    IF (n > 0) THEN
      ALLOCATE (p0(3, n), p(3, n), pv(3, n), pa(3, n), pl(3, n), dcm(3, 3, n), om(3, n), al(3, n))
      CALL CD_AGG_GetMovingPointMesh(agg, p0, pv, pa, pl, es, em)
      DO s = 1, NSTEPS
        t = dt*REAL(s, wp)
        p = p0
        pv = 0.0_wp
        pa = 0.0_wp
        p(1, :) = p0(1, :) + SWAY*SIN(RATE*t)
        pv(1, :) = SWAY*RATE*COS(RATE*t)
        pa(1, :) = -SWAY*RATE**2*SIN(RATE*t)
        IF (rot) THEN
          phi = ROLL*REAL(s, wp)/REAL(NSTEPS, wp)
          om = 0.0_wp
          al = 0.0_wp
          om(1, :) = ROLL/(REAL(NSTEPS, wp)*dt)
          DO k = 1, n
            dcm(:, :, k) = roll_dcm(phi)
          END DO
          CALL CD_AGG_Step_Moving(agg, dt, p, pv, pa, cv, st, nit, es, em, t_committed=t, orientation=dcm, &
                                  angular_velocity=om, angular_acceleration=al)
        ELSE
          CALL CD_AGG_Step_Moving(agg, dt, p, pv, pa, cv, st, nit, es, em, t_committed=t)
        END IF
        CALL require(es == CD_AGG_OK, path//': aggregate step: '//TRIM(em))
        IF (es /= CD_AGG_OK) EXIT
      END DO
      CALL compare_mesh(agg, path//' stepped')
    END IF
    bad_state = .FALSE.
    IF (PRESENT(corrupt)) bad_state = corrupt
    IF (bad_state) THEN
      ! a NaN at mid-line: both paths give the same values up to the same first failure
      DO id = 1, SIZE(agg%line_obj_index)
        k = agg%line_obj_index(id)
        IF (k < 1) CYCLE
        IF (agg%line_is_cable(id)) THEN
          agg%cables(k)%line%q(6*(agg%cables(k)%line%nn/2) + 1) = IEEE_VALUE(t, IEEE_QUIET_NAN)
        ELSE
          agg%sys%fast%system%lines(k)%q(3*(SIZE(agg%sys%fast%system%lines(k)%q)/6) + 1) = &
            IEEE_VALUE(t, IEEE_QUIET_NAN)
        END IF
      END DO
      CALL compare_mesh(agg, path//' with a NaN', failing=.TRUE.)
    END IF
    CALL CD_AGG_End(agg, es, em)
  END SUBROUTINE check_aggregate

  SUBROUTINE compare_mesh(agg, label, failing)
    !! Every value at every node of the final mesh against the channel of that mesh node.
    TYPE(CD_AGG_ModuleType), INTENT(INOUT) :: agg
    CHARACTER(*), INTENT(IN) :: label
    LOGICAL, INTENT(IN), OPTIONAL :: failing
    REAL(wp), ALLOCATABLE :: vals(:), work(:)
    REAL(wp) :: val
    INTEGER :: id, obj, nn, iq, w, n_done, es, es_ch, node, c, i, bad
    CHARACTER(512) :: em, em_ch
    CHARACTER(:), ALLOCATABLE :: name
    LOGICAL :: allow_failure

    allow_failure = .FALSE.
    IF (PRESENT(failing)) allow_failure = failing
    DO id = 1, SIZE(agg%line_obj_index)
      obj = agg%line_obj_index(id)
      IF (obj < 1) CYCLE
      IF (agg%line_is_cable(id)) THEN
        nn = agg%cables(obj)%line%nn
        IF (ALLOCATED(agg%cables(obj)%deck_node)) n_added = n_added + nn - SIZE(agg%cables(obj)%deck_node)
      ELSE
        nn = CD_System_Line_NDOF(agg%sys%fast%system, obj, es, em)/3
      END IF
      IF (ALLOCATED(work)) DEALLOCATE (work)
      ALLOCATE (work(nn))
      DO iq = 1, N_QUANTITY
        w = width(QUANTITY(iq))
        IF (ALLOCATED(vals)) DEALLOCATE (vals)
        ALLOCATE (vals(w*nn))
        CALL CD_Eval_Aggregate_Line_Values(id, QUANTITY(iq), agg%has_sys, agg%sys%fast%system, agg%cables, &
                                           agg%line_is_cable, agg%line_obj_index, vals, work, n_done, es, em)
        IF (.NOT. allow_failure) CALL require(es == CD_DECKDRV_OK .AND. n_done == w*nn, label//': '//TRIM(em))
        bad = 0
        DO i = 1, MIN(n_done + 1, w*nn)
          node = (i - 1)/w + 1
          c = i - w*(node - 1)
          name = token(QUANTITY(iq), id, node, c)
          CALL CD_Eval_Aggregate_Channel(name, agg%has_sys, agg%sys%fast%system, agg%cables, agg%line_is_cable, &
                                         agg%line_obj_index, val, es_ch, em_ch, mesh_node=.TRUE.)
          IF (i > n_done) THEN
            ! the first value the line evaluation did not reach: the channel fails there too
            IF (es_ch == CD_DECKDRV_OK .OR. es == CD_DECKDRV_OK) bad = bad + 1
          ELSE
            n_mesh = n_mesh + 1
            IF (es_ch /= CD_DECKDRV_OK) THEN
              bad = bad + 1
            ELSE IF (.NOT. same_bits(vals(i), val)) THEN
              bad = bad + 1
              IF (bad == 1) WRITE (*, '(A,1X,A,2ES25.16)') label, name, vals(i), val
            END IF
          END IF
        END DO
        CALL require(bad == 0, label//': quantity '//text(QUANTITY(iq))//' of line '//text(id)//': '//text(bad)// &
                     ' values differ from the mesh-node channels')
      END DO
      ! a bad code or size is refused, with nothing written
      CALL CD_Eval_Aggregate_Line_Values(id, 9, agg%has_sys, agg%sys%fast%system, agg%cables, agg%line_is_cable, &
                                         agg%line_obj_index, vals, work, n_done, es, em)
      CALL require(es /= CD_DECKDRV_OK .AND. n_done == 0, label//': a code past the node channels is refused')
      CALL CD_Eval_Aggregate_Line_Values(id, 3, agg%has_sys, agg%sys%fast%system, agg%cables, agg%line_is_cable, &
                                         agg%line_obj_index, vals(1:nn - 1), work, n_done, es, em)
      CALL require(es /= CD_DECKDRV_OK .AND. n_done == 0, label//': a wrongly sized output is refused')
    END DO
  END SUBROUTINE compare_mesh

  PURE REAL(wp) FUNCTION range_azimuth(heading) RESULT(azimuth)
    !! The azimuth [deg] of a line on heading in its range: (-180, 180] within 45 deg of +x,
    !! otherwise [0, 360).
    REAL(wp), INTENT(IN) :: heading
    azimuth = heading
    IF (ABS(heading) > 45.0_wp) azimuth = MODULO(heading, 360.0_wp)
  END FUNCTION range_azimuth

  SUBROUTINE check_azimuth_range(path)
    !! Line 2 k of the deck runs on HEADINGS(k), in its vertical plane, at the static start.
    CHARACTER(*), INTENT(IN) :: path
    REAL(wp), PARAMETER :: TOL = 1.0e-6_wp
    TYPE(C_PTR) :: h
    TYPE(CD_AGG_ModuleType) :: agg
    INTEGER(C_INT) :: es, n_lines, il, id, nn, sub
    CHARACTER(C_CHAR), TARGET :: c_path(1024)
    REAL(C_DOUBLE), ALLOCATABLE, TARGET :: azi(:)
    REAL(wp) :: val, tension, force(3), inclination, declination, azimuth
    INTEGER :: k, n, line_id, ies
    CHARACTER(512) :: em

    c_path = ' '
    DO k = 1, LEN(path)
      c_path(k) = path(k:k)
    END DO
    CALL CableDyn_Create(h, es)
    CALL CableDyn_InitDeck(h, C_LOC(c_path), INT(LEN(path), C_INT), es)
    CALL require(es == 0_C_INT, path//': range: init')
    n_lines = CableDyn_NObjects(h, LINE_KIND, es)
    CALL require(n_lines == SIZE(HEADINGS), path//': range: line count')
    DO il = 0_C_INT, n_lines - 1_C_INT
      CALL CableDyn_GetObjectInfo(h, LINE_KIND, il, id, nn, sub, es)
      IF (ALLOCATED(azi)) DEALLOCATE (azi)
      ALLOCATE (azi(nn))
      CALL CableDyn_GetLineValues(h, il, 8_C_INT, C_LOC(azi), nn, es)
      CALL require(es == 0_C_INT .AND. MAXVAL(ABS(azi - range_azimuth(HEADINGS(id/2)))) <= TOL, &
                   path//': range: the azimuths of line '//text(INT(id))//' read through the C API')
    END DO
    CALL CableDyn_Close(h, es)

    CALL CD_AGG_Init_From_Deck(agg, path, 0.02_wp, ies, em)
    CALL require(ies == CD_AGG_OK, path//': range: aggregate: '//TRIM(em))
    IF (ies /= CD_AGG_OK) RETURN
    n = CD_AGG_NumChannels(agg)
    CALL require(n == SIZE(HEADINGS), path//': range: channel count')
    DO k = 1, n
      CALL CD_AGG_EvalChannel(agg, k, val, ies, em)
      CALL require(ies == CD_AGG_OK .AND. ABS(val - range_azimuth(HEADINGS(k))) <= TOL, &
                   path//': range: aggregate channel of line '//text(2*k))
      CALL CD_AGG_GetInitLine(agg, k, line_id, tension, force, inclination, declination, azimuth, ies, em)
      CALL require(ies == CD_AGG_OK .AND. ABS(azimuth - range_azimuth(HEADINGS(line_id/2))) <= TOL, &
                   path//': range: initialisation summary of line '//text(line_id))
    END DO
    CALL CD_AGG_End(agg, ies, em)
  END SUBROUTINE check_azimuth_range

  SUBROUTINE write_heading_deck(path, cables)
    !! Line 2 k from its own coupled point to its own anchor on HEADINGS(k): an EI = 0 chain, or
    !! with cables every second line a finite-EI cable.
    CHARACTER(*), INTENT(IN) :: path
    LOGICAL, INTENT(IN) :: cables
    REAL(wp) :: cx, sy, reach
    INTEGER :: u, k
    LOGICAL :: cable

    OPEN (NEWUNIT=u, FILE=path, STATUS='REPLACE', ACTION='WRITE')
    WRITE (u, '(A)') 'Line values against the channels, lines on both sides of +x'
    WRITE (u, '(A)') '--- LINE TYPES ---'
    WRITE (u, '(A)') 'Name Diam Mass EA BA EI Cdn Cdt Can Cat'
    WRITE (u, '(A)') '(-) (m) (kg/m) (N) (-) (Nm2) (-) (-) (-) (-)'
    WRITE (u, '(A)') 'cable 0.16 36.7 4.69e8 -1.0 1.99e4 1.2 0.1 1.0 0.0'
    WRITE (u, '(A)') 'chain 0.10 150.0 8.0e8 -1.0 0.0 1.2 0.4 1.0 0.5'
    WRITE (u, '(A)') '--- POINTS ---'
    WRITE (u, '(A)') 'ID Type X Y Z'
    WRITE (u, '(A)') '(-) (-) (m) (m) (m)'
    DO k = 1, SIZE(HEADINGS)
      cable = cables .AND. MOD(k, 2) == 0
      reach = MERGE(70.0_wp, 240.0_wp, cable)
      cx = COS(HEADINGS(k)*PI/180.0_wp)
      sy = SIN(HEADINGS(k)*PI/180.0_wp)
      WRITE (u, '(I0,A,2(1X,ES23.15),A)') 2*k - 1, ' Coupled', 5.0_wp*cx, 5.0_wp*sy, ' -10.0'
      WRITE (u, '(I0,A,2(1X,ES23.15),A)') 2*k, ' Fixed', (5.0_wp + reach)*cx, (5.0_wp + reach)*sy, ' -60.0'
    END DO
    WRITE (u, '(A)') '--- LINES ---'
    WRITE (u, '(A)') 'ID NodeA NodeB Outputs'
    WRITE (u, '(A)') '(-) (-) (-) (-)'
    DO k = 1, SIZE(HEADINGS)
      WRITE (u, '(I0,1X,I0,1X,I0,A)') 2*k, 2*k - 1, 2*k, ' -'
    END DO
    WRITE (u, '(A)') '--- SECTIONS ---'
    WRITE (u, '(A)') 'LineID LineType Length NumSegs'
    WRITE (u, '(A)') '(-) (-) (m) (-)'
    DO k = 1, SIZE(HEADINGS)
      IF (cables .AND. MOD(k, 2) == 0) THEN
        WRITE (u, '(I0,A)') 2*k, ' cable 100.0 20'
      ELSE
        WRITE (u, '(I0,A)') 2*k, ' chain 260.0 13'
      END IF
    END DO
    WRITE (u, '(A)') '--- OPTIONS ---'
    WRITE (u, '(A)') '9.80665 g'
    WRITE (u, '(A)') '1025.0 rhoW'
    WRITE (u, '(A)') '60.0 WtrDpth'
    WRITE (u, '(A)') '1.0e6 kBot'
    WRITE (u, '(A)') '1.0e5 cBot'
    WRITE (u, '(A)') '0.02 dtM'
    WRITE (u, '(A)') '0.0 TMax'
    WRITE (u, '(A)') '--- OUTPUTS ---'
    DO k = 1, SIZE(HEADINGS)
      WRITE (u, '(A,I0,A)') 'L', 2*k, 'N1Azi'
    END DO
    WRITE (u, '(A)') '--- END ---'
    CLOSE (u)
  END SUBROUTINE write_heading_deck

  SUBROUTINE write_cable_deck(path, heading, element_recovery, stiffener, torsion, chain)
    !! A 100 m finite-EI cable from a coupled point at z = -10 to an anchor 70 m away along
    !! heading [deg], at z = -60. Line ids are not consecutive. torsion restrains a level cable at
    !! z = -50 (both ends Rigid); chain adds an EI = 0 line from a second coupled point, heading
    !! just below +x (the signed azimuth range).
    CHARACTER(*), INTENT(IN) :: path
    REAL(wp), INTENT(IN) :: heading
    LOGICAL, INTENT(IN), OPTIONAL :: element_recovery, stiffener, torsion, chain
    LOGICAL :: rec, stf, tor, chn
    REAL(wp) :: cx, sy
    INTEGER :: u

    rec = .FALSE.
    IF (PRESENT(element_recovery)) rec = element_recovery
    stf = .FALSE.
    IF (PRESENT(stiffener)) stf = stiffener
    tor = .FALSE.
    IF (PRESENT(torsion)) tor = torsion
    chn = .FALSE.
    IF (PRESENT(chain)) chn = chain
    cx = COS(heading*PI/180.0_wp)
    sy = SIN(heading*PI/180.0_wp)
    OPEN (NEWUNIT=u, FILE=path, STATUS='REPLACE', ACTION='WRITE')
    WRITE (u, '(A)') 'Line values against the channels'
    WRITE (u, '(A)') '--- LINE TYPES ---'
    WRITE (u, '(A)') 'Name Diam Mass EA BA EI GAs GJ Irt Irn Cdn Cdt Can Cat'
    WRITE (u, '(A)') '(-) (m) (kg/m) (N) (-) (Nm2) (N) (Nm2) (kgm) (kgm) (-) (-) (-) (-)'
    WRITE (u, '(A)') 'cable 0.16 36.7 4.69e8 -1.0 1.99e4 9.02e7 5.0e4 0.0587 0.1174 1.2 0.1 1.0 0.0'
    WRITE (u, '(A)') 'chain 0.10 150.0 8.0e8 0.0 0.0 0 0 0 0 1.2 0.4 1.0 0.5'
    WRITE (u, '(A)') '--- POINTS ---'
    WRITE (u, '(A)') 'ID Type X Y Z'
    WRITE (u, '(A)') '(-) (-) (m) (m) (m)'
    IF (tor) THEN
      WRITE (u, '(A)') '1 Coupled 0.0 0.0 -50.0'
      WRITE (u, '(A,2(1X,ES23.15),A)') '2 Fixed', 99.5_wp*cx, 99.5_wp*sy, ' -50.0'
    ELSE
      WRITE (u, '(A)') '1 Coupled 0.0 0.0 -10.0'
      WRITE (u, '(A,2(1X,ES23.15),A)') '2 Fixed', 70.0_wp*cx, 70.0_wp*sy, ' -60.0'
    END IF
    IF (chn) THEN
      WRITE (u, '(A)') '3 Coupled -20.0 5.0 -10.0'
      WRITE (u, '(A)') '4 Fixed 200.0 -30.0 -60.0'
    END IF
    WRITE (u, '(A)') '--- LINES ---'
    WRITE (u, '(A)') 'ID NodeA NodeB Outputs'
    WRITE (u, '(A)') '(-) (-) (-) (-)'
    WRITE (u, '(A)') '3 1 2 -'
    IF (chn) WRITE (u, '(A)') '6 3 4 -'
    WRITE (u, '(A)') '--- SECTIONS ---'
    WRITE (u, '(A)') 'LineID LineType Length NumSegs'
    WRITE (u, '(A)') '(-) (-) (m) (-)'
    WRITE (u, '(A)') '3 cable 100.0 40'
    IF (chn) WRITE (u, '(A)') '6 chain 240.0 24'
    IF (stf) THEN
      WRITE (u, '(A)') '--- STIFFENERS ---'
      WRITE (u, '(A)') 'LineID End Length RootOD TipOD InnerD E Density'
      WRITE (u, '(A)') '(-) (-) (m) (m) (m) (m) (Pa) (kg/m^3)'
      WRITE (u, '(A)') '3 A 0.5 0.45 0.45 0.17 5.0e7 1150'
      WRITE (u, '(A)') '3 A 6.5 0.45 0.18 0.17 5.0e7 1150'
    END IF
    IF (tor) THEN
      WRITE (u, '(A)') '--- END CONNECTIONS ---'
      WRITE (u, '(A)') 'LineID End Stiffness EzX EzY EzZ TorsStiffness NxX NxY NxZ Pretwist'
      WRITE (u, '(A)') '(-) (-) (N-m/rad) (-) (-) (-) (N-m/rad) (-) (-) (-) (deg)'
      WRITE (u, '(A,2(1X,ES23.15),A,2(1X,ES23.15),A)') '3 A Rigid', cx, sy, ' 0 Rigid', -sy, cx, ' 0 0'
      WRITE (u, '(A,2(1X,ES23.15),A,2(1X,ES23.15),A)') '3 B Rigid', cx, sy, ' 0 Rigid', -sy, cx, ' 0 0'
    END IF
    WRITE (u, '(A)') '--- OPTIONS ---'
    WRITE (u, '(A)') '9.80665 g'
    WRITE (u, '(A)') '1025.0 rhoW'
    WRITE (u, '(A)') '60.0 WtrDpth'
    WRITE (u, '(A)') '1.0e5 kBot'
    WRITE (u, '(A)') '1.0e4 cBot'
    WRITE (u, '(A)') '0.02 dtM'
    WRITE (u, '(A)') '0.0 TMax'
    IF (rec) WRITE (u, '(A)') 'element OutputRecovery'
    WRITE (u, '(A)') '--- OUTPUTS ---'
    WRITE (u, '(A)') 'FairTen3'
    WRITE (u, '(A)') '--- END ---'
    CLOSE (u)
  END SUBROUTINE write_cable_deck

  SUBROUTINE write_chain_deck(path)
    !! EI = 0 lines alone (the point route), on three headings.
    CHARACTER(*), INTENT(IN) :: path
    INTEGER :: u
    OPEN (NEWUNIT=u, FILE=path, STATUS='REPLACE', ACTION='WRITE')
    WRITE (u, '(A)') 'Line values against the channels, EI = 0 lines'
    WRITE (u, '(A)') '--- LINE TYPES ---'
    WRITE (u, '(A)') 'Name Diam Mass EA BA EI Cdn Cdt Can Cat'
    WRITE (u, '(A)') '(-) (m) (kg/m) (N) (-) (Nm2) (-) (-) (-) (-)'
    WRITE (u, '(A)') 'chain 0.10 150.0 8.0e8 -1.0 0.0 1.2 0.4 1.0 0.5'
    WRITE (u, '(A)') '--- POINTS ---'
    WRITE (u, '(A)') 'ID Type X Y Z'
    WRITE (u, '(A)') '(-) (-) (m) (m) (m)'
    WRITE (u, '(A)') '1 Coupled 0.0 0.0 -10.0'
    WRITE (u, '(A)') '2 Fixed 240.0 -40.0 -60.0'
    WRITE (u, '(A)') '3 Fixed -240.0 -40.0 -60.0'
    WRITE (u, '(A)') '4 Fixed -30.0 240.0 -60.0'
    WRITE (u, '(A)') '--- LINES ---'
    WRITE (u, '(A)') 'ID NodeA NodeB Outputs'
    WRITE (u, '(A)') '(-) (-) (-) (-)'
    WRITE (u, '(A)') '2 1 2 -'
    WRITE (u, '(A)') '5 1 3 -'
    WRITE (u, '(A)') '9 1 4 -'
    WRITE (u, '(A)') '--- SECTIONS ---'
    WRITE (u, '(A)') 'LineID LineType Length NumSegs'
    WRITE (u, '(A)') '(-) (-) (m) (-)'
    WRITE (u, '(A)') '2 chain 260.0 26'
    WRITE (u, '(A)') '5 chain 260.0 20'
    WRITE (u, '(A)') '9 chain 260.0 13'
    WRITE (u, '(A)') '--- OPTIONS ---'
    WRITE (u, '(A)') '9.80665 g'
    WRITE (u, '(A)') '1025.0 rhoW'
    WRITE (u, '(A)') '60.0 WtrDpth'
    WRITE (u, '(A)') '1.0e6 kBot'
    WRITE (u, '(A)') '1.0e5 cBot'
    WRITE (u, '(A)') '0.02 dtM'
    WRITE (u, '(A)') '0.0 TMax'
    WRITE (u, '(A)') '--- OUTPUTS ---'
    WRITE (u, '(A)') 'FairTen2'
    WRITE (u, '(A)') '--- END ---'
    CLOSE (u)
  END SUBROUTINE write_chain_deck

  SUBROUTINE write_object_deck(path, body)
    !! EI = 0 lines on a coupled Rigid6 body, or on a free rod, between an anchor and a coupled
    !! point in still water (the aggregate route with a body or rod runtime).
    CHARACTER(*), INTENT(IN) :: path
    LOGICAL, INTENT(IN) :: body
    INTEGER :: u
    OPEN (NEWUNIT=u, FILE=path, STATUS='REPLACE', ACTION='WRITE')
    WRITE (u, '(A)') 'Line values against the channels, a body or a rod'
    WRITE (u, '(A)') '--- LINE TYPES ---'
    WRITE (u, '(A)') 'Name Diam Mass EA BA EI Cdn Cdt Can Cat'
    WRITE (u, '(A)') '(-) (m) (kg/m) (N) (-) (Nm2) (-) (-) (-) (-)'
    WRITE (u, '(A)') 'line 0.10 80.0 1.0e5 0.0 0.0 1.0 0.0 1.0 0.0'
    IF (body) THEN
      WRITE (u, '(A)') '--- BODIES ---'
      WRITE (u, '(A)') 'ID Type X Y Z Rot1 Rot2 Rot3 Mass Vol C33 C44 C55 CdA Ca Ixx Iyy Izz'
      WRITE (u, '(A)') '(-) (-) (m) (m) (m) (deg) (deg) (deg) (kg) (m3) (N/m) (Nm/rad) (Nm/rad) (m2) (-) '// &
        '(kgm2) (kgm2) (kgm2)'
      WRITE (u, '(A)') '1 Rigid6 0.0 0.0 -4.0 0.0 0.0 0.0 100.0 0.05 0.0 100.0 100.0 0.0 0.0 20.0 20.0 20.0'
    ELSE
      WRITE (u, '(A)') '--- ROD TYPES ---'
      WRITE (u, '(A)') 'Name Diam Mass Cd Ca CdEnd CaEnd'
      WRITE (u, '(A)') '(-) (m) (kg/m) (-) (-) (-) (-)'
      WRITE (u, '(A)') 'rodmat 0.20 50.0 1.0 1.0 0.0 0.0'
      WRITE (u, '(A)') '--- RODS ---'
      WRITE (u, '(A)') 'ID RodType Type XA YA ZA XB YB ZB NumSegs Outputs'
      WRITE (u, '(A)') '(-) (-) (-) (m) (m) (m) (m) (m) (m) (-) (-)'
      WRITE (u, '(A)') '1 rodmat Free 0.0 0.0 -4.0 0.0 0.0 -2.0 2 -'
    END IF
    WRITE (u, '(A)') '--- POINTS ---'
    WRITE (u, '(A)') 'ID Type X Y Z Mass Vol CdA Ca'
    WRITE (u, '(A)') '(-) (-) (m) (m) (m) (kg) (m3) (m2) (-)'
    WRITE (u, '(A)') '1 Fixed 2.0 0.0 -5.0 0.0 0.0 0.0 0.0'
    IF (body) THEN
      WRITE (u, '(A)') '2 Body1 0.0 0.0 0.0 0.0 0.0 0.0 0.0'
      WRITE (u, '(A)') '3 Body1 0.0 0.0 0.0 0.0 0.0 0.0 0.0'
    ELSE
      WRITE (u, '(A)') '2 Rod1A 0.0 0.0 -4.0 0.0 0.0 0.0 0.0'
      WRITE (u, '(A)') '3 Rod1B 0.0 0.0 -2.0 0.0 0.0 0.0 0.0'
    END IF
    WRITE (u, '(A)') '4 Coupled 0.0 0.0 -1.0 0.0 0.0 0.0 0.0'
    WRITE (u, '(A)') '--- LINES ---'
    WRITE (u, '(A)') 'ID NodeA NodeB Outputs'
    WRITE (u, '(A)') '(-) (-) (-) (-)'
    WRITE (u, '(A)') '1 2 1 -'
    WRITE (u, '(A)') '2 3 4 -'
    WRITE (u, '(A)') '--- SECTIONS ---'
    WRITE (u, '(A)') 'LineID LineType Length NumSegs'
    WRITE (u, '(A)') '(-) (-) (m) (-)'
    WRITE (u, '(A)') '1 line 3.5 3'
    WRITE (u, '(A)') '2 line 3.2 3'
    WRITE (u, '(A)') '--- OPTIONS ---'
    WRITE (u, '(A)') '9.80665 g'
    WRITE (u, '(A)') '1025.0 rhoW'
    WRITE (u, '(A)') '10.0 WtrDpth'
    WRITE (u, '(A)') '1.0e5 kBot'
    WRITE (u, '(A)') '0.005 dtM'
    WRITE (u, '(A)') '0.0 TMax'
    WRITE (u, '(A)') '--- OUTPUTS ---'
    WRITE (u, '(A)') 'FairTen1'
    WRITE (u, '(A)') '--- END ---'
    CLOSE (u)
  END SUBROUTINE write_object_deck

  SUBROUTINE write_refined_deck(source, path)
    !! The coarse lazy-wave deck with its top section cut from 20 to 4 elements: the deck mesh
    !! cannot resolve the curvature of the equilibrium and the static solve refines it.
    CHARACTER(*), INTENT(IN) :: source, path
    CHARACTER(512) :: row
    INTEGER :: u, w, ios
    LOGICAL :: found

    found = .FALSE.
    OPEN (NEWUNIT=u, FILE=source, STATUS='OLD', ACTION='READ')
    OPEN (NEWUNIT=w, FILE=path, STATUS='REPLACE', ACTION='WRITE')
    DO
      READ (u, '(A)', IOSTAT=ios) row
      IF (ios /= 0) EXIT
      IF (TRIM(row) == '4 bare 80.0 20') THEN
        row = '4 bare 80.0 4'
        found = .TRUE.
      END IF
      WRITE (w, '(A)') TRIM(row)
    END DO
    CLOSE (u)
    CLOSE (w)
    CALL require(found, 'the coarse deck has its top section')
  END SUBROUTINE write_refined_deck

END PROGRAM test_line_values
