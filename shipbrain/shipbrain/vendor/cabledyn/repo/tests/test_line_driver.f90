! File: tests/test_line_driver.f90
! SPDX-License-Identifier: Apache-2.0
! Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
PROGRAM test_line_driver
  !! End-to-end test of the line-object (composite multi-section) static driver:
  !! write an OrcaFlex-style deck (line types + sections + endpoints), run
  !! CD_Run_Line_Static_Driver, read the CSV back, and assert a converged grounded
  !! composite line with the endpoints honoured and the free span sagging onto the
  !! seabed. Also checks the deck auto-detection (CD_Deck_Is_Line_Object) and the
  !! fail-closed deck paths. Exercises file -> parse -> build (CableDyn_Line) ->
  !! catenary seed -> load continuation -> CSV.
  USE CableDyn_Precision, ONLY: wp
  USE CableDyn_Driver, ONLY: CD_Run_Line_Static_Driver, CD_Deck_Is_Line_Object, &
                             CD_DRIVER_OK, CD_DRIVER_BADINPUT
  USE CableDyn_Catenary, ONLY: CD_Catenary_Seed, CD_CAT_OK
  IMPLICIT NONE

  INTEGER :: nfail
  nfail = 0

  CALL case_composite_deck_runs()
  CALL case_taut_no_seabed_runs()
  CALL case_auto_detection()
  CALL case_bad_deck_fails()

  IF (nfail > 0) THEN
    WRITE (*, '(A,I0,A)') 'FAIL: ', nfail, ' assertion(s) failed'
    ERROR STOP 1
  END IF
  WRITE (*, '(A)') 'PASS: CableDyn_Driver line-object deck solves a composite line end-to-end'

CONTAINS

  SUBROUTINE require(cond, label)
    LOGICAL, INTENT(IN) :: cond
    CHARACTER(*), INTENT(IN) :: label
    IF (.NOT. cond) THEN
      WRITE (*, '(A,A,A)') 'MISMATCH [', label, ']: condition false'
      nfail = nfail + 1
    END IF
  END SUBROUTINE require

  SUBROUTINE write_composite_deck(path)
    !! A chain + wire slack composite: anchor on the seabed, fairlead up and across,
    !! total 80 m over a ~69 m chord (slack -> part lies on the seabed). Different
    !! line types (multi-line-types) and different segment counts (mesh refinement).
    CHARACTER(*), INTENT(IN) :: path
    INTEGER :: u
    OPEN (NEWUNIT=u, FILE=path, STATUS='REPLACE', ACTION='WRITE')
    WRITE (u, '(A)') '# chain + wire composite slack line'
    WRITE (u, '(A)') 'gravity 9.81           ! m/s^2'
    WRITE (u, '(A)') 'rho_water 1025.0'
    WRITE (u, '(A)') 'tension_only F'
    WRITE (u, '(A)') 'seabed 0.0 1.0e5       ! z_floor  kn_base (per-area)'
    WRITE (u, '(A)') 'anchor 0.0 0.0 0.0'
    WRITE (u, '(A)') 'fairlead 60.0 0.0 35.0'
    WRITE (u, '(A)') 'line_types 2           ! EA  mass_per_len  diameter'
    WRITE (u, '(A)') '5.0e6 50.0 0.10        ! chain'
    WRITE (u, '(A)') '8.0e6 20.0 0.08        ! wire'
    WRITE (u, '(A)') 'sections 2             ! line_type  length  n_segments'
    WRITE (u, '(A)') '1 40.0 8               ! chain, coarse'
    WRITE (u, '(A)') '2 40.0 12              ! wire, finer'
    CLOSE (u)
  END SUBROUTINE write_composite_deck

  SUBROUTINE case_composite_deck_runs()
    CHARACTER(*), PARAMETER :: inp = 'line_deck.inp', out = 'line_deck.csv'
    LOGICAL  :: converged, conv_flag
    INTEGER  :: es, u, ios, idx, na, nb
    CHARACTER(256) :: em
    CHARACTER(512) :: line
    CHARACTER(16)  :: tag
    REAL(wp) :: x, y, z, t
    REAL(wp) :: x1, z1, xN, zN, zmin_interior, tmax
    INTEGER  :: n_nodes_seen, n_elem_seen
    conv_flag = .FALSE.
    x1 = 99.0_wp; z1 = 99.0_wp; xN = -99.0_wp; zN = -99.0_wp
    zmin_interior = 99.0_wp; tmax = 0.0_wp
    n_nodes_seen = 0; n_elem_seen = 0

    CALL write_composite_deck(inp)
    CALL CD_Run_Line_Static_Driver(inp, out, converged, es, em)
    CALL require(es == CD_DRIVER_OK, 'composite:ErrStat-OK')
    CALL require(converged, 'composite:converged')

    OPEN (NEWUNIT=u, FILE=out, STATUS='OLD', ACTION='READ', IOSTAT=ios)
    CALL require(ios == 0, 'composite:csv-opens')
    IF (ios /= 0) RETURN
    DO
      READ (u, '(A)', IOSTAT=ios) line
      IF (ios /= 0) EXIT
      IF (INDEX(line, 'converged=T') > 0) conv_flag = .TRUE.
      READ (line, *, IOSTAT=ios) tag
      IF (ios /= 0) CYCLE
      IF (TRIM(tag) == 'node') THEN
        READ (line, *, IOSTAT=ios) tag, idx, x, y, z
        IF (ios /= 0) CYCLE
        n_nodes_seen = n_nodes_seen + 1
        IF (idx == 1) THEN
          x1 = x; z1 = z
        END IF
        IF (idx == 21) THEN
          xN = x; zN = z
        END IF
        IF (idx > 1 .AND. idx < 21) zmin_interior = MIN(zmin_interior, z)
      ELSE IF (TRIM(tag) == 'elem') THEN
        READ (line, *, IOSTAT=ios) tag, idx, na, nb, t
        IF (ios /= 0) CYCLE
        n_elem_seen = n_elem_seen + 1
        tmax = MAX(tmax, t)
      END IF
    END DO
    CLOSE (u)

    CALL require(conv_flag, 'composite:csv-header-converged')
    CALL require(n_nodes_seen == 21, 'composite:csv-21-nodes')   ! 8 + 12 + 1
    CALL require(n_elem_seen == 20, 'composite:csv-20-elems')
    CALL require(ABS(x1) < 1.0e-9_wp .AND. ABS(z1) < 1.0e-9_wp, 'composite:anchor-pinned')
    CALL require(ABS(xN - 60.0_wp) < 1.0e-9_wp .AND. ABS(zN - 35.0_wp) < 1.0e-9_wp, 'composite:fairlead-pinned')
    CALL require(zmin_interior < 0.01_wp, 'composite:interior-touches-down')
    CALL require(zmin_interior > -0.1_wp, 'composite:no-through-seabed')
    CALL require(tmax > 1.0e3_wp, 'composite:suspended-span-carries-tension')
  END SUBROUTINE case_composite_deck_runs

  SUBROUTINE case_taut_no_seabed_runs()
    !! A suspended TAUT line with NO seabed: horizontal span hspan = 60 and total length
    !! L = 58 <= hspan, so no part can be grounded. The analytical seed is the stretched,
    !! fully suspended elastic catenary (grounded length 0); the line carries strong
    !! positive tension and the driver converges from that seed.
    CHARACTER(*), PARAMETER :: inp = 'line_taut.inp', out = 'line_taut.csv'
    LOGICAL  :: converged, conv_flag
    INTEGER  :: es, u, ios, idx, na, nb, n_neg, n_elem_seen
    CHARACTER(256) :: em
    CHARACTER(512) :: line
    CHARACTER(16)  :: tag
    REAL(wp) :: t
    REAL(wp) :: l0c(20), eac(20), wc(20), seedq(63), hh, ggl
    INTEGER  :: ces
    n_neg = 0; conv_flag = .FALSE.; n_elem_seen = 0

    ! Precondition: the taut geometry is seeded as the stretched suspended catenary.
    l0c = 58.0_wp/20.0_wp; eac = 5.0e7_wp; wc = 100.0_wp
    CALL CD_Catenary_Seed([0.0_wp, 0.0_wp, 5.0_wp], [60.0_wp, 0.0_wp, 15.0_wp], l0c, eac, wc, &
                          seedq, hh, ggl, ces, em)
    CALL require(ces == CD_CAT_OK .AND. .NOT. (ggl > 0.0_wp) .AND. hh > 0.0_wp, &
                 'taut:stretched-suspended-seed')

    OPEN (NEWUNIT=u, FILE=inp, STATUS='REPLACE', ACTION='WRITE')
    WRITE (u, '(A)') '# suspended taut line, no seabed, stretched suspended seed'
    WRITE (u, '(A)') 'gravity 9.81'
    WRITE (u, '(A)') 'rho_water 1025.0'
    WRITE (u, '(A)') 'tension_only F'
    WRITE (u, '(A)') 'anchor 0.0 0.0 5.0'       ! both ends suspended above the seabed
    WRITE (u, '(A)') 'fairlead 60.0 0.0 15.0'   ! hspan = 60, rise = 10
    WRITE (u, '(A)') 'line_types 1'
    WRITE (u, '(A)') '5.0e7 30.0 0.08'          ! stiff-ish wire
    WRITE (u, '(A)') 'sections 1'
    WRITE (u, '(A)') '1 58.0 20'                ! L = 58 <= hspan = 60: taut, fully suspended
    CLOSE (u)
    CALL CD_Run_Line_Static_Driver(inp, out, converged, es, em)
    CALL require(es == CD_DRIVER_OK, 'taut:ErrStat-OK')
    CALL require(converged, 'taut:converged')
    ! re-read: endpoints honoured, tensions positive (taut suspended line)
    OPEN (NEWUNIT=u, FILE=out, STATUS='OLD', ACTION='READ', IOSTAT=ios)
    CALL require(ios == 0, 'taut:csv-opens')
    IF (ios /= 0) RETURN
    DO
      READ (u, '(A)', IOSTAT=ios) line
      IF (ios /= 0) EXIT
      IF (INDEX(line, 'converged=T') > 0) conv_flag = .TRUE.
      READ (line, *, IOSTAT=ios) tag
      IF (ios /= 0) CYCLE
      IF (TRIM(tag) == 'elem') THEN
        READ (line, *, IOSTAT=ios) tag, idx, na, nb, t
        IF (ios /= 0) CYCLE
        n_elem_seen = n_elem_seen + 1
        IF (t < -1.0_wp) n_neg = n_neg + 1
      END IF
    END DO
    CLOSE (u)
    CALL require(conv_flag, 'taut:csv-header-converged')
    CALL require(n_elem_seen == 20, 'taut:csv-20-elems')
    CALL require(n_neg == 0, 'taut:no-compression')   ! taut line -> positive tension throughout
  END SUBROUTINE case_taut_no_seabed_runs

  SUBROUTINE case_auto_detection()
    !! A deck declaring `sections` is detected as a line object; an explicit
    !! nodes/elements deck is not.
    CHARACTER(*), PARAMETER :: linp = 'detect_line.inp', einp = 'detect_explicit.inp'
    LOGICAL :: is_line
    INTEGER :: es, u
    CHARACTER(256) :: em
    CALL write_composite_deck(linp)
    CALL CD_Deck_Is_Line_Object(linp, is_line, es, em)
    CALL require(es == CD_DRIVER_OK .AND. is_line, 'detect:line-deck-is-line')
    OPEN (NEWUNIT=u, FILE=einp, STATUS='REPLACE', ACTION='WRITE')
    WRITE (u, '(A)') 'gravity 9.81'
    WRITE (u, '(A)') 'nodes 2'
    WRITE (u, '(A)') '0.0 0.0 0.0'
    WRITE (u, '(A)') '1.0 0.0 0.0'
    WRITE (u, '(A)') 'elements 1'
    WRITE (u, '(A)') '1 2 0.9 1000.0 5.0 1.0e-4'
    WRITE (u, '(A)') 'fixed 6'
    WRITE (u, '(A)') '1 2 3 4 5 6'
    CLOSE (u)
    CALL CD_Deck_Is_Line_Object(einp, is_line, es, em)
    CALL require(es == CD_DRIVER_OK .AND. .NOT. is_line, 'detect:explicit-deck-not-line')
    ! a missing file fails closed
    CALL CD_Deck_Is_Line_Object('detect_missing.inp', is_line, es, em)
    CALL require(es == CD_DRIVER_BADINPUT, 'detect:missing-file')
  END SUBROUTINE case_auto_detection

  SUBROUTINE case_bad_deck_fails()
    !! A line-object deck missing a required block (here `anchor`) fails closed, as
    !! does an unknown keyword and a malformed section row.
    CHARACTER(*), PARAMETER :: inp = 'line_bad.inp', out = 'line_bad.csv'
    LOGICAL :: converged
    INTEGER :: es, u
    CHARACTER(256) :: em
    ! missing anchor
    OPEN (NEWUNIT=u, FILE=inp, STATUS='REPLACE', ACTION='WRITE')
    WRITE (u, '(A)') 'gravity 9.81'
    WRITE (u, '(A)') 'fairlead 60.0 0.0 35.0'
    WRITE (u, '(A)') 'line_types 1'
    WRITE (u, '(A)') '5.0e6 50.0 0.10'
    WRITE (u, '(A)') 'sections 1'
    WRITE (u, '(A)') '1 40.0 8'
    CLOSE (u)
    CALL CD_Run_Line_Static_Driver(inp, out, converged, es, em)
    CALL require(es == CD_DRIVER_BADINPUT, 'baddeck:missing-anchor')
    ! out-of-range section line_type index -> builder rejects -> BADINPUT
    OPEN (NEWUNIT=u, FILE=inp, STATUS='REPLACE', ACTION='WRITE')
    WRITE (u, '(A)') 'gravity 9.81'
    WRITE (u, '(A)') 'anchor 0.0 0.0 0.0'
    WRITE (u, '(A)') 'fairlead 60.0 0.0 35.0'
    WRITE (u, '(A)') 'line_types 1'
    WRITE (u, '(A)') '5.0e6 50.0 0.10'
    WRITE (u, '(A)') 'sections 1'
    WRITE (u, '(A)') '2 40.0 8'             ! references type 2 (only 1 defined)
    CLOSE (u)
    CALL CD_Run_Line_Static_Driver(inp, out, converged, es, em)
    CALL require(es == CD_DRIVER_BADINPUT, 'baddeck:bad-line-type-index')
    ! malformed section row (2 tokens, not 3)
    OPEN (NEWUNIT=u, FILE=inp, STATUS='REPLACE', ACTION='WRITE')
    WRITE (u, '(A)') 'gravity 9.81'
    WRITE (u, '(A)') 'anchor 0.0 0.0 0.0'
    WRITE (u, '(A)') 'fairlead 60.0 0.0 35.0'
    WRITE (u, '(A)') 'line_types 1'
    WRITE (u, '(A)') '5.0e6 50.0 0.10'
    WRITE (u, '(A)') 'sections 1'
    WRITE (u, '(A)') '1 40.0'               ! missing n_segments
    CLOSE (u)
    CALL CD_Run_Line_Static_Driver(inp, out, converged, es, em)
    CALL require(es == CD_DRIVER_BADINPUT, 'baddeck:malformed-section')
    ! an invalid static_solver policy (rel_tol = 0) fails closed at parse
    OPEN (NEWUNIT=u, FILE=inp, STATUS='REPLACE', ACTION='WRITE')
    WRITE (u, '(A)') 'gravity 9.81'
    WRITE (u, '(A)') 'anchor 0.0 0.0 0.0'
    WRITE (u, '(A)') 'fairlead 60.0 0.0 35.0'
    WRITE (u, '(A)') 'static_solver 0.0 1.0e-5 80 12'   ! rel_tol = 0
    WRITE (u, '(A)') 'line_types 1'
    WRITE (u, '(A)') '5.0e6 50.0 0.10'
    WRITE (u, '(A)') 'sections 1'
    WRITE (u, '(A)') '1 40.0 8'
    CLOSE (u)
    CALL CD_Run_Line_Static_Driver(inp, out, converged, es, em)
    CALL require(es == CD_DRIVER_BADINPUT, 'baddeck:bad-static-solver')
  END SUBROUTINE case_bad_deck_fails

END PROGRAM test_line_driver
