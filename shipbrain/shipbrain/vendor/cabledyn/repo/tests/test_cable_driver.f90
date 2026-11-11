! File: tests/test_cable_driver.f90
! SPDX-License-Identifier: Apache-2.0
! Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
PROGRAM test_cable_driver
  !! End-to-end test of CD_Run_Static_Driver: write a tiny input file describing a
  !! pre-stretched (taut) 5-node line fixed at both ends, run the driver, read the
  !! CSV back, and assert a physically sane symmetric catenary sag with positive
  !! element tensions. This exercises the whole file -> parse -> solve -> CSV path.
  USE CableDyn_Precision, ONLY: wp
  USE CableDyn_Driver, ONLY: CD_Run_Static_Driver, CD_DRIVER_OK, CD_DRIVER_BADINPUT
  IMPLICIT NONE

  INTEGER :: nfail
  nfail = 0

  CALL case_taut_bar_runs()
  CALL case_inline_comments_ok()
  CALL case_bad_input_fails()

  IF (nfail > 0) THEN
    WRITE (*, '(A,I0,A)') 'FAIL: ', nfail, ' assertion(s) failed'
    ERROR STOP 1
  END IF
  WRITE (*, '(A)') 'PASS: CableDyn_Driver solves a static line end-to-end'

CONTAINS

  SUBROUTINE require(cond, label)
    LOGICAL, INTENT(IN) :: cond
    CHARACTER(*), INTENT(IN) :: label
    IF (.NOT. cond) THEN
      WRITE (*, '(A,A,A)') 'MISMATCH [', label, ']: condition false'
      nfail = nfail + 1
    END IF
  END SUBROUTINE require

  SUBROUTINE write_input(path)
    !! A span-4 taut bar: 5 nodes along x, 4 elements (L0 = 0.9 -> ~11% stretch),
    !! both ends fully fixed, under self-weight (tiny diameter -> buoyancy ~ 0).
    CHARACTER(*), INTENT(IN) :: path
    INTEGER :: u, i
    OPEN (NEWUNIT=u, FILE=path, STATUS='REPLACE', ACTION='WRITE')
    WRITE (u, '(A)') '# taut bar under self-weight'
    WRITE (u, '(A)') 'gravity 10.0'
    WRITE (u, '(A)') 'rho_water 1.0'
    WRITE (u, '(A)') 'tension_only F'
    WRITE (u, '(A)') 'nodes 5'
    DO i = 1, 5
      WRITE (u, '(I0,A)') i - 1, ' 0.0 0.0'    ! x=0..4, y=z=0
    END DO
    WRITE (u, '(A)') 'elements 4'
    DO i = 1, 4
      ! a b L0 EA mass_per_len diameter ; mass=5, g=10 -> w ~ 50 N/m (diam tiny)
      WRITE (u, '(I0,A,I0,A)') i, ' ', i + 1, ' 0.9 1000.0 5.0 1.0e-4'
    END DO
    WRITE (u, '(A)') 'fixed 6'
    WRITE (u, '(A)') '1 2 3 13 14 15'         ! node 1 and node 5 fully fixed
    CLOSE (u)
  END SUBROUTINE write_input

  SUBROUTINE case_taut_bar_runs()
    CHARACTER(*), PARAMETER :: inp = 'driver_taut.inp', out = 'driver_taut.csv'
    LOGICAL  :: converged, conv_flag
    INTEGER  :: es, u, ios, idx, na, nb
    CHARACTER(256) :: em
    CHARACTER(512) :: line
    CHARACTER(16)  :: tag
    REAL(wp) :: x, y, z, t
    REAL(wp) :: zmid, z2, z4, z1, z5
    INTEGER  :: n_nodes_seen, n_elem_seen, n_neg_tension
    zmid = 0.0_wp; z2 = 0.0_wp; z4 = 0.0_wp; z1 = 99.0_wp; z5 = 99.0_wp
    n_nodes_seen = 0; n_elem_seen = 0; n_neg_tension = 0; conv_flag = .FALSE.

    CALL write_input(inp)
    CALL CD_Run_Static_Driver(inp, out, converged, es, em)
    CALL require(es == CD_DRIVER_OK, 'taut:ErrStat-OK')
    CALL require(converged, 'taut:converged')

    ! re-read the CSV and check the physics
    OPEN (NEWUNIT=u, FILE=out, STATUS='OLD', ACTION='READ', IOSTAT=ios)
    CALL require(ios == 0, 'taut:csv-opens')
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
        IF (idx == 1) z1 = z
        IF (idx == 2) z2 = z
        IF (idx == 3) zmid = z
        IF (idx == 4) z4 = z
        IF (idx == 5) z5 = z
      ELSE IF (TRIM(tag) == 'elem') THEN
        READ (line, *, IOSTAT=ios) tag, idx, na, nb, t
        IF (ios /= 0) CYCLE
        n_elem_seen = n_elem_seen + 1
        IF (t <= 0.0_wp) n_neg_tension = n_neg_tension + 1
      END IF
    END DO
    CLOSE (u)

    CALL require(conv_flag, 'taut:csv-header-converged')
    CALL require(n_nodes_seen == 5, 'taut:csv-5-nodes')
    CALL require(n_elem_seen == 4, 'taut:csv-4-elems')
    CALL require(ABS(z1) < 1.0e-12_wp .AND. ABS(z5) < 1.0e-12_wp, 'taut:ends-fixed-at-z0')
    CALL require(zmid < -1.0e-4_wp, 'taut:mid-sags-down')
    CALL require(zmid < z2 .AND. zmid < z4, 'taut:mid-is-lowest')
    CALL require(ABS(z2 - z4) < 1.0e-9_wp, 'taut:symmetric-sag')
    CALL require(n_neg_tension == 0, 'taut:all-tensions-positive')
  END SUBROUTINE case_taut_bar_runs

  SUBROUTINE case_inline_comments_ok()
    !! The documented inline-comment styles -- whole-line and trailing `#` or `!` --
    !! are stripped before tokenising, so an annotated deck (like the module's own
    !! sample) parses and solves rather than being rejected for "extra" tokens.
    CHARACTER(*), PARAMETER :: inp = 'driver_comments.inp', out = 'driver_comments.csv'
    LOGICAL  :: converged
    INTEGER  :: es, u, i
    CHARACTER(256) :: em
    OPEN (NEWUNIT=u, FILE=inp, STATUS='REPLACE', ACTION='WRITE')
    WRITE (u, '(A)') '# whole-line hash comment'
    WRITE (u, '(A)') 'gravity 10.0            ! m/s^2'
    WRITE (u, '(A)') 'tension_only F          # resist compression'
    WRITE (u, '(A)') 'nodes 3                 ! x y z follow'
    DO i = 1, 3
      WRITE (u, '(I0,A)') i - 1, ' 0.0 0.0'
    END DO
    WRITE (u, '(A)') 'elements 2              ! a b L0 EA mass diam'
    WRITE (u, '(A)') '1 2 0.9 1000.0 5.0 1.0e-4   ! section 1'
    WRITE (u, '(A)') '2 3 0.9 1000.0 5.0 1.0e-4   # section 2'
    WRITE (u, '(A)') 'fixed 6                 ! both ends'
    WRITE (u, '(A)') '1 2 3 7 8 9'
    CLOSE (u)
    CALL CD_Run_Static_Driver(inp, out, converged, es, em)
    CALL require(es == CD_DRIVER_OK, 'comments:ErrStat-OK')
    CALL require(converged, 'comments:converged')
  END SUBROUTINE case_inline_comments_ok

  SUBROUTINE case_bad_input_fails()
    !! A missing input file and an unknown keyword each fail closed with BADINPUT.
    CHARACTER(*), PARAMETER :: missing = 'driver_does_not_exist.inp'
    CHARACTER(*), PARAMETER :: badkw = 'driver_badkw.inp', out = 'driver_badkw.csv'
    LOGICAL  :: converged
    INTEGER  :: es, u
    CHARACTER(256) :: em
    CALL CD_Run_Static_Driver(missing, 'unused.csv', converged, es, em)
    CALL require(es == CD_DRIVER_BADINPUT, 'bad:missing-file')
    OPEN (NEWUNIT=u, FILE=badkw, STATUS='REPLACE', ACTION='WRITE')
    WRITE (u, '(A)') 'gravity 9.81'
    WRITE (u, '(A)') 'frobnicate 3'        ! unknown keyword
    CLOSE (u)
    CALL CD_Run_Static_Driver(badkw, out, converged, es, em)
    CALL require(es == CD_DRIVER_BADINPUT, 'bad:unknown-keyword')
    ! an unrecognised tension_only token must fail closed, not silently run as F
    OPEN (NEWUNIT=u, FILE=badkw, STATUS='REPLACE', ACTION='WRITE')
    WRITE (u, '(A)') 'gravity 9.81'
    WRITE (u, '(A)') 'tension_only maybe'   ! not T/F/true/false
    CLOSE (u)
    CALL CD_Run_Static_Driver(badkw, out, converged, es, em)
    CALL require(es == CD_DRIVER_BADINPUT, 'bad:tension_only-token')
    ! a fixed-DOF line with MORE values than the declared count must fail closed
    ! (silently dropping the extras would discard boundary conditions)
    OPEN (NEWUNIT=u, FILE=badkw, STATUS='REPLACE', ACTION='WRITE')
    WRITE (u, '(A)') 'gravity 9.81'
    WRITE (u, '(A)') 'nodes 2'
    WRITE (u, '(A)') '0.0 0.0 0.0'
    WRITE (u, '(A)') '1.0 0.0 0.0'
    WRITE (u, '(A)') 'elements 1'
    WRITE (u, '(A)') '1 2 0.9 1000.0 5.0 1.0e-4'
    WRITE (u, '(A)') 'fixed 3'           ! declares 3 ...
    WRITE (u, '(A)') '1 2 3 4 5 6'       ! ... but lists 6
    CLOSE (u)
    CALL CD_Run_Static_Driver(badkw, out, converged, es, em)
    CALL require(es == CD_DRIVER_BADINPUT, 'bad:fixed-count-mismatch')
    ! a trailing field on a fixed-shape record (here a 7th token on an element
    ! line) must fail closed too -- the parser requires exactly the expected
    ! token count on every line, not just a lenient prefix
    OPEN (NEWUNIT=u, FILE=badkw, STATUS='REPLACE', ACTION='WRITE')
    WRITE (u, '(A)') 'gravity 9.81'
    WRITE (u, '(A)') 'nodes 2'
    WRITE (u, '(A)') '0.0 0.0 0.0'
    WRITE (u, '(A)') '1.0 0.0 0.0'
    WRITE (u, '(A)') 'elements 1'
    WRITE (u, '(A)') '1 2 0.9 1000.0 5.0 1.0e-4 99'   ! 7 tokens (trailing 99)
    WRITE (u, '(A)') 'fixed 6'
    WRITE (u, '(A)') '1 2 3 4 5 6'
    CLOSE (u)
    CALL CD_Run_Static_Driver(badkw, out, converged, es, em)
    CALL require(es == CD_DRIVER_BADINPUT, 'bad:element-trailing-field')
  END SUBROUTINE case_bad_input_fails

END PROGRAM test_cable_driver
