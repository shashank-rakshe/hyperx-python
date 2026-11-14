! File: tests/test_flagship_compression_note.f90
! SPDX-License-Identifier: Apache-2.0
! Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
PROGRAM test_flagship_compression_note
  !! The maintained IEA-15 MW mixed example initialises without a compression or mesh note.
  !! Its lazy-wave cable (line 4) rests on the nodal penalty seabed: the contact reaction at
  !! the touchdown node kinks the line, so the pointwise axial resultant dips below zero at
  !! every mesh and single element means next to the kink can be slightly negative. The line
  !! in equilibrium is tensile: the 3-element smoothed element-mean axial force stays
  !! positive, and that is the quantity the static note is gated on.
  !!
  !! The node Tension channel Ten4N<j> (static profile, standalone and coupled outputs) is
  !! the effective tension recovered from nodal equilibrium; at the ends the end force. On the
  !! suspended part it is checked here against the statics of the free body between the node
  !! and the fairlead: the fairlead force less the submerged weight of the elements in between,
  !! projected on the nodal tangent. It stays within the end tensions instead of the pointwise
  !! spikes at the touchdown.
  !!
  !! The chains' negative BA, a damping ratio per segment, carries the axial-damping note only.
  !!
  !! A deck whose finite-EI elements are shorter than sqrt(EI/EA) (the conditioning limit
  !! of the static Newton system) carries the fine-mesh note; the flagship does not.
  !!
  !! A weightless finite-EI line longer than its span, solved by weight continuation, returns
  !! the note that its bow was chosen downward to the aggregate caller, which prints nothing.
  USE CableDyn_Precision, ONLY: wp
  USE CableDyn_OpenFAST_Aggregate, ONLY: CD_AGG_ModuleType, CD_AGG_Init_From_Deck, CD_AGG_End, CD_AGG_OK
  USE CableDyn_HermiteCableStatic, ONLY: CD_HermiteCable_Branch_Audit, CD_HermiteBranchAuditType, CD_HCSTAT_OK
  USE CableDyn_HermiteCable, ONLY: CD_HermiteCable_Axial_Resultant
  USE CableDyn_DeckDriver, ONLY: CD_Eval_Aggregate_Channel
  USE CableDyn_HermiteCableDynamic, ONLY: CD_HermiteCable_Dyn_End_Force, CD_HCDYN_OK
  IMPLICIT NONE

  TYPE(CD_AGG_ModuleType) :: agg
  TYPE(CD_HermiteBranchAuditType) :: au
  CHARACTER(1024) :: deck
  CHARACTER(512) :: em
  INTEGER :: es, i, nfail, nn, j, inode, k
  REAL(wp), ALLOCATABLE :: ten(:), emean(:)
  REAL(wp) :: qe(12), ng, expect, dev_max, t_end, fair(3), sec(3), tan_j(3)
  INTEGER :: first_free, n_checked
  CHARACTER(32) :: ch
  REAL(wp), PARAMETER :: G3X(3) = [0.5_wp - 0.5_wp*SQRT(0.6_wp), 0.5_wp, 0.5_wp + 0.5_wp*SQRT(0.6_wp)]
  REAL(wp), PARAMETER :: G3W(3) = [5.0_wp/18.0_wp, 8.0_wp/18.0_wp, 5.0_wp/18.0_wp]

  nfail = 0
  IF (COMMAND_ARGUMENT_COUNT() < 1) THEN
    WRITE (*, '(A)') 'FAIL: flagship example deck path argument required'
    ERROR STOP 1
  END IF
  CALL GET_COMMAND_ARGUMENT(1, deck)
  CALL CD_AGG_Init_From_Deck(agg, TRIM(deck), 0.025_wp, es, em)
  CALL check(es == CD_AGG_OK, 'flagship aggregate init: '//TRIM(em))
  IF (es /= CD_AGG_OK) ERROR STOP 1

  CALL check(ALLOCATED(agg%init_lines), 'per-line init summaries are recorded')
  IF (ALLOCATED(agg%init_lines)) THEN
    CALL check(SIZE(agg%init_lines) == 4, 'three chains and one power cable')
    DO i = 1, SIZE(agg%init_lines)
      IF (LEN_TRIM(agg%init_lines(i)%note) > 0) WRITE (*, '(A,I0,2A)') '  line ', agg%init_lines(i)%line_id, &
        ' note: ', TRIM(agg%init_lines(i)%note)
      ! the chains' negative BA is a damping ratio per segment: only that note of the run
      CALL check(only_damping_note(agg%init_lines(i)%note), 'no static-initialisation note on any line')
    END DO
  END IF

  CALL check(ALLOCATED(agg%cables) .AND. SIZE(agg%cables) == 1, 'one finite-EI power cable is built')
  IF (ALLOCATED(agg%cables)) THEN
    ASSOCIATE (ln => agg%cables(1)%line)
      CALL CD_HermiteCable_Branch_Audit(ln%l0, ln%q, ln%EA, au, es, em)
      CALL check(es == CD_HCSTAT_OK, 'branch audit evaluated: '//TRIM(em))
      WRITE (*, '(A,3ES12.4)') '  pointwise min, element-mean min, smoothed min [N]: ', au%axial_min, &
        au%mean_axial_min, au%smoothed_axial_min
      ! The contact-transition dip is present ...
      CALL check(au%axial_min < 0.0_wp, 'pointwise axial resultant dips at the contact kink')
      ! ... confined to isolated elements between tensile neighbours ...
      CALL check(au%smoothed_axial_min > 0.0_wp .AND. .NOT. au%smoothed_compressed, &
                 'smoothed element-mean axial force is tensile along the whole cable')
      ! ... which the neighbour-weighted mean lifts above zero.
      CALL check(au%smoothed_axial_min > au%mean_axial_min, 'smoothing lifts the isolated element dip')

      ! Node Tension channel = segment tension (internal order: node 1 anchor, nn fairlead;
      ! public node j = internal node nn - j + 1).
      nn = ln%ne + 1
      ALLOCATE (ten(nn), emean(ln%ne))
      DO j = 1, ln%ne
        qe(1:6) = ln%q(6*j - 5:6*j); qe(7:12) = ln%q(6*j + 1:6*j + 6)
        emean(j) = 0.0_wp
        DO k = 1, 3
          CALL CD_HermiteCable_Axial_Resultant(qe, ln%l0(j), ln%EA(j), G3X(k), ng, es, em)
          emean(j) = emean(j) + G3W(k)*ng
        END DO
      END DO
      WRITE (*, '(A,2ES12.4)') '  element-mean axial force min, max [N]: ', MINVAL(emean), MAXVAL(emean)
      DO j = 1, nn
        WRITE (ch, '(A,I0)') 'Ten4N', j
        CALL CD_Eval_Aggregate_Channel(TRIM(ch), agg%has_sys, agg%sys%fast%system, agg%cables, &
                                       agg%line_is_cable, agg%line_obj_index, ten(j), es, em)
        IF (es /= 0) CALL check(.FALSE., 'node Tension channel '//TRIM(ch)//': '//TRIM(em))
      END DO
      ! Suspended run next to the fairlead (internal nodes first_free .. nn): no node from
      ! first_free - 1 on touches the seabed (1 cm clearance), so the only loads between an
      ! interior node and the fairlead, and in the element before it, are the consistent
      ! submerged weights of the elements (the reaction of a grounded node is spread over its
      ! tributary length, into the element after it).
      first_free = 2
      DO k = nn, 1, -1
        IF (ln%q(6*(k - 1) + 3) <= ln%seabed_z + 0.01_wp) THEN
          first_free = k + 2
          EXIT
        END IF
      END DO
      CALL CD_HermiteCable_Dyn_End_Force(ln, nn, fair, es, em)
      CALL check(es == CD_HCDYN_OK, 'fairlead end force evaluated: '//TRIM(em))
      sec = -fair                      ! force of the fairlead on the line
      dev_max = 0.0_wp
      n_checked = 0
      DO inode = nn - 1, first_free, -1
        sec(3) = sec(3) - ln%w(inode)*ln%l0(inode)
        tan_j = ln%q(6*(inode - 1) + 4:6*(inode - 1) + 6)
        expect = DOT_PRODUCT(sec, tan_j)/NORM2(tan_j)
        dev_max = MAX(dev_max, ABS(ten(nn - inode + 1) - expect))
        n_checked = n_checked + 1
      END DO
      t_end = MAX(ten(1), ten(nn))
      WRITE (*, '(A,3ES12.4)') '  node Tension min, max, max end tension [N]: ', MINVAL(ten), MAXVAL(ten), t_end
      WRITE (*, '(A,I0,A,ES12.4)') '  suspended nodes checked against the free-body statics: ', n_checked, &
        '; largest difference [N]: ', dev_max
      CALL check(n_checked > 40, 'the suspended run spans the sag and hog bends')
      ! The initialised state keeps a consistent acceleration of order 1e-4 m/s^2, whose inertia
      ! the recovery includes and the free-body statics leave out (0.03 N here): 1e-5 of the
      ! end tension bounds it; the element-mean axial force dips to -1.98 kN at the touchdown.
      CALL check(dev_max <= 1.0e-5_wp*t_end, 'interior node Tension is the free-body effective tension')
      CALL check(MINVAL(ten) > -0.1_wp*MAXVAL(ten), 'node Tension carries no compression beyond a tenth of the peak')
      CALL check(MAXVAL(ten) <= 1.001_wp*t_end, 'node Tension peaks at the line end, not at the touchdown')
    END ASSOCIATE
  END IF

  CALL CD_AGG_End(agg, es, em)

  CALL case_fine_mesh_note()
  CALL case_weightless_bow_note()

  IF (nfail > 0) THEN
    WRITE (*, '(A,I0,A)') 'FAIL: ', nfail, ' flagship compression-note check(s) failed'
    ERROR STOP 1
  END IF
  WRITE (*, '(A)') 'PASS: flagship example initialises without a compression note'

CONTAINS

  SUBROUTINE case_fine_mesh_note()
    !! A 2 m stiff member, EA 1e6 N and EI 1e4 N m^2 (sqrt(EI/EA) = 0.1 m), meshed at 0.05 m.
    TYPE(CD_AGG_ModuleType), SAVE :: small
    INTEGER :: u, es_s
    CHARACTER(512) :: em_s
    OPEN (NEWUNIT=u, FILE='fine_mesh_note.dat', STATUS='REPLACE', ACTION='WRITE')
    WRITE (u, '(A)') 'short stiff finite-EI member meshed below sqrt(EI/EA)'
    WRITE (u, '(A)') '--- LINE TYPES ---'
    WRITE (u, '(A)') 'Name Diam Mass EA BA EI Cdn Cdt Can Cat'
    WRITE (u, '(A)') '(-) (m) (kg/m) (N) (-) (Nm2) (-) (-) (-) (-)'
    WRITE (u, '(A)') 'rod 0.05 5.0 1.0e6 0.0 1.0e4 1.2 0.1 1.0 0.0'
    WRITE (u, '(A)') '--- POINTS ---'
    WRITE (u, '(A)') 'ID Type X Y Z'
    WRITE (u, '(A)') '(-) (-) (m) (m) (m)'
    WRITE (u, '(A)') '1 Fixed 0.0 0.0 -10.0'
    WRITE (u, '(A)') '2 Coupled 1.5 0.0 -9.5'
    WRITE (u, '(A)') '--- LINES ---'
    WRITE (u, '(A)') 'ID NodeA NodeB Outputs'
    WRITE (u, '(A)') '(-) (-) (-) (-)'
    WRITE (u, '(A)') '1 2 1 -'
    WRITE (u, '(A)') '--- SECTIONS ---'
    WRITE (u, '(A)') 'LineID LineType Length NumSegs'
    WRITE (u, '(A)') '(-) (-) (m) (-)'
    WRITE (u, '(A)') '1 rod 2.0 40'
    WRITE (u, '(A)') '--- OPTIONS ---'
    WRITE (u, '(A)') '9.80665 g'
    WRITE (u, '(A)') '1025.0 rhoW'
    WRITE (u, '(A)') '--- need this line ---'
    CLOSE (u)
    CALL CD_AGG_Init_From_Deck(small, 'fine_mesh_note.dat', 0.025_wp, es_s, em_s)
    CALL check(es_s == CD_AGG_OK, 'short stiff member initialises: '//TRIM(em_s))
    IF (es_s /= CD_AGG_OK) RETURN
    IF (ALLOCATED(small%init_lines)) THEN
      WRITE (*, '(2A)') '  note: ', TRIM(small%init_lines(1)%note)
      CALL check(INDEX(small%init_lines(1)%note, 'sqrt(EI/EA)') > 0 .AND. &
                 INDEX(small%init_lines(1)%note, 'at least  1.00E-01 m') > 0, &
                 'elements below sqrt(EI/EA) carry the fine-mesh note with the minimum length')
    ELSE
      CALL check(.FALSE., 'short stiff member records its init summary')
    END IF
    CALL CD_AGG_End(small, es_s, em_s)
  END SUBROUTINE case_fine_mesh_note

  SUBROUTINE case_weightless_bow_note()
    !! A neutrally buoyant 120 m line, EI 1e4 N m^2, pinned 113 m apart (the elastica of
    !! tests/test_light_slack_statics.py).
    TYPE(CD_AGG_ModuleType), SAVE :: light
    INTEGER :: u, es_l
    CHARACTER(512) :: em_l
    OPEN (NEWUNIT=u, FILE='weightless_bow_note.dat', STATUS='REPLACE', ACTION='WRITE')
    WRITE (u, '(A)') 'weightless finite-EI line longer than its span'
    WRITE (u, '(A)') '--- LINE TYPES ---'
    WRITE (u, '(A)') 'Name Diam Mass EA BA EI Cdn Cdt Can Cat'
    WRITE (u, '(A)') '(-) (m) (kg/m) (N) (-) (Nm2) (-) (-) (-) (-)'
    WRITE (u, '(A)') 'light 0.2 32.2013247 1.0e8 -1 1.0e4 1.2 0.1 1.0 0.0'
    WRITE (u, '(A)') '--- POINTS ---'
    WRITE (u, '(A)') 'ID Type X Y Z'
    WRITE (u, '(A)') '(-) (-) (m) (m) (m)'
    WRITE (u, '(A)') '1 Coupled 0.0 0.0 -20.0'
    WRITE (u, '(A)') '2 Fixed 80.0 0.0 -100.0'
    WRITE (u, '(A)') '--- LINES ---'
    WRITE (u, '(A)') 'ID NodeA NodeB Outputs'
    WRITE (u, '(A)') '(-) (-) (-) (-)'
    WRITE (u, '(A)') '1 1 2 -'
    WRITE (u, '(A)') '--- SECTIONS ---'
    WRITE (u, '(A)') 'LineID LineType Length NumSegs'
    WRITE (u, '(A)') '(-) (-) (m) (-)'
    WRITE (u, '(A)') '1 light 120.0 120'
    WRITE (u, '(A)') '--- OPTIONS ---'
    WRITE (u, '(A)') '9.80665 g'
    WRITE (u, '(A)') '1025.0 rhoW'
    WRITE (u, '(A)') '200.0 WtrDpth'
    WRITE (u, '(A)') '--- need this line ---'
    CLOSE (u)
    CALL CD_AGG_Init_From_Deck(light, 'weightless_bow_note.dat', 0.025_wp, es_l, em_l)
    CALL check(es_l == CD_AGG_OK, 'weightless line initialises in the aggregate: '//TRIM(em_l))
    IF (es_l /= CD_AGG_OK) RETURN
    IF (ALLOCATED(light%init_lines)) THEN
      WRITE (*, '(2A)') '  note: ', TRIM(light%init_lines(1)%note)
      CALL check(INDEX(light%init_lines(1)%note, 'is weightless and longer than its span') > 0 .AND. &
                 INDEX(light%init_lines(1)%note, 'bowed downward') > 0, &
                 'the aggregate caller receives the weightless-bow note')
    ELSE
      CALL check(.FALSE., 'weightless line records its init summary')
    END IF
    CALL CD_AGG_End(light, es_l, em_l)
  END SUBROUTINE case_weightless_bow_note

  LOGICAL FUNCTION only_damping_note(note) RESULT(ok)
    !! Every line of note is the axial-damping note of a negative BA (axial_damping_note).
    CHARACTER(*), INTENT(IN) :: note
    INTEGER :: a, b, n
    ok = .TRUE.
    n = LEN_TRIM(note)
    a = 1
    DO WHILE (a <= n)
      b = INDEX(note(a:n), NEW_LINE('a'))
      IF (b == 0) b = n - a + 2
      IF (INDEX(note(a:a + b - 2), 'its negative BA is a damping ratio per segment') == 0) ok = .FALSE.
      a = a + b
    END DO
  END FUNCTION only_damping_note

  SUBROUTINE check(ok, label)
    LOGICAL, INTENT(IN) :: ok
    CHARACTER(*), INTENT(IN) :: label
    IF (ok) THEN
      WRITE (*, '(2A)') '  ok   ', label
    ELSE
      WRITE (*, '(2A)') '  FAIL ', label
      nfail = nfail + 1
    END IF
  END SUBROUTINE check

END PROGRAM test_flagship_compression_note
