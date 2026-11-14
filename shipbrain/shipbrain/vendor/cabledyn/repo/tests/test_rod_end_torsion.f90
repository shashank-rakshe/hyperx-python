! File: tests/test_rod_end_torsion.f90
! SPDX-License-Identifier: Apache-2.0
! Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
!> A torsional END CONNECTION on a rod end (an I-tube or J-tube modelled as a rod): the End A
!> torsion frame is held by the rod and turns with its whole orientation, and the line's torque
!> returns to the rod about the line axis. Gates (multibody march, the route of every deck with
!> rods and finite-EI lines):
!>  1. a straight neutral line, stretched by 1e-4 and restrained in torsion, hung along the axis
!>     of an inclined Fixed rod (the J-tube; its frame is not the global one), with the reference
!>     normals given in global axes: two turns of pretwist give Torq = GJ Phi / L at every node,
!>     the same torque as the line hung from a Coupled point held still (a second route, the
!>     standalone finite-EI march) to the printed digits, and equal normals with equal pretwists
!>     give no torque (the End A normal is carried into the rod frame; taken in the rod frame instead it
!>     would twist the line by the roll of that frame); Rod<N>M about the rod's End A is the
!>     torque along the line axis, M_t a (the moment returned to the rod); a 1 s march keeps the
!>     torque; a bending-pinned, torsionally rigid End A carries the same torque; the deck written
!>     anchor first (MoorDyn's order, NodeA the anchor) is turned around and runs bit for bit;
!>  2. a rod fixed to a rolling Rigid6 body (RODS type Body<N>, the body attitude rolled,
!>     pitched and yawed), the line hung along the rod axis and pretwisted by 30 deg, the body
!>     released from rest: the body and its rod roll about the line axis as a torsional pendulum
!>     (Omega = sqrt(GJ / (L I)), I the body's roll inertia plus the rod's polar inertia), at every
!>     step the torque is GJ (Phi - theta) / L with theta the body's roll (quasi-static torsion),
!>     the moment returned to the body is the torque along the turned line axis, and the rod's
!>     Rod<N>M channel carries it (it left out the connection moment of a cable at the end of a
!>     body-fixed rod);
!>  3. named refusals: a Pinned, a Free and a Body<N>Pinned rod are axisymmetric with no roll
!>     angle and cannot hold the torque; a Coupled rod carries no finite-EI line on any route; the
!>     staggered body scheme, which drives a cable end by translation, refuses a torsional End A
!>     on a body-fixed rod even when its bending is pinned (it ran with the frame frozen); a line
!>     written anchor first onto a Pinned rod meets the Pinned rod's refusal (it read "two moving
!>     ends"), and a line between two Fixed rods is refused as one with End B on a rod end.
!>  4. with the other routes: the gate 1 line on the Fixed J-tube, with torque-tension coupling
!>     (GJ|K 5e4 N m2|4e5 N m) and restrained in torsion at the rod end only (End B free to twist),
!>     carries no torque and its free end turns with the 1e-4 stretch, Twist1 = -(K/GJ) dl, the
!>     same as from the held Coupled point; free at the rod end and restrained at the anchor
!>     instead, the same twist. The gate 1 line twisted two turns and carrying two clumps and a
!>     buoy (ATTACHMENTS, which bend it off the rod axis) gives the torque and twist of the same
!>     line from the held Coupled point to the printed digits.
!> The multibody march has no restart (checkpoint) path, so there is no restart gate.
PROGRAM test_rod_end_torsion
  USE CableDyn_Precision, ONLY: wp
  USE CableDyn_Conventions, ONLY: CD_Body_Rotation
  USE CableDyn_DeckDriver, ONLY: CD_Run_Deck_Driver, CD_DECKDRV_OK, CD_Multibody_Probe_Arm, CD_Multibody_Probe_Get
  USE, INTRINSIC :: IEEE_ARITHMETIC, ONLY: IEEE_IS_FINITE
  IMPLICIT NONE

  REAL(wp), PARAMETER :: PI = 3.14159265358979323846_wp, RHOW = 1025.0_wp, GJ = 5.0e4_wp
  INTEGER :: n_fail = 0
  CHARACTER(160) :: neutral_type, rod_type

  ! neutral 0.2 m section: EA 1e7, EI 1e6, GAs 1e8, GJ 5e4, Irn 1e-12 (massless torsion)
  WRITE (neutral_type, '(A,ES24.16,A)') 'cab 0.2 ', RHOW*0.25_wp*PI*0.04_wp, &
    ' 1.0e7 0.0 1.0e6 1.0e8 5.0e4 1.0 1.0e-12 0.0 0.0 0.0 0.0'
  ! neutral 0.2 m rod without hydrodynamic coefficients
  WRITE (rod_type, '(A,ES24.16,A)') 'arm 0.2 ', RHOW*0.25_wp*PI*0.04_wp, ' 0.0 0.0 0.0 0.0'

  CALL check_fixed_rod()
  CALL check_body_rod_roll()
  CALL check_refusals()
  CALL check_one_end_rod()
  CALL check_attachments_rod()
  IF (n_fail > 0) THEN
    WRITE (*, '(A,I0,A)') 'FAIL: ', n_fail, ' rod-end torsion gate(s) failed'
    ERROR STOP 1
  END IF
  WRITE (*, '(A)') 'PASS: rod-end torsion (Fixed rod, rod on a rolling body, refusals)'

CONTAINS

  INCLUDE 'nan_max_abs.inc'

  SUBROUTINE require(cond, msg)
    LOGICAL, INTENT(IN) :: cond
    CHARACTER(*), INTENT(IN) :: msg
    IF (.NOT. cond) THEN
      n_fail = n_fail + 1
      WRITE (*, '(A,A)') 'FAILED: ', msg
    END IF
  END SUBROUTINE require

  SUBROUTINE write_deck(path, bodies, rods, points, line, length_segs, endconns, options, outs, atts)
    !! A one-line deck: the neutral line type, optional BODIES and RODS rows (the arm rod type),
    !! POINTS, one LINES row, its SECTIONS row, optional ATTACHMENTS rows atts, END CONNECTIONS,
    !! OPTIONS (g, rhoW, WtrDpth 200 and the given rows) and OUTPUTS.
    CHARACTER(*), INTENT(IN) :: path, bodies(:), rods(:), points(:), line, length_segs, endconns(:), options(:), &
                                outs(:)
    CHARACTER(*), INTENT(IN), OPTIONAL :: atts(:)
    INTEGER :: u, i
    OPEN (NEWUNIT=u, FILE=path, STATUS='REPLACE', ACTION='WRITE')
    WRITE (u, '(A)') 'rod-end torsion gate'
    WRITE (u, '(A)') '--- LINE TYPES ---'
    WRITE (u, '(A)') 'Name Diam Mass EA BA EI GAs GJ Irt Irn Cdn Cdt Can Cat'
    WRITE (u, '(A)') '(-) (m) (kg/m) (N) (-) (Nm2) (N) (Nm2) (kgm) (kgm) (-) (-) (-) (-)'
    WRITE (u, '(A)') TRIM(neutral_type)
    IF (SIZE(bodies) > 0) THEN
      WRITE (u, '(A)') '--- BODIES ---'
      WRITE (u, '(A)') 'ID Type X Y Z Roll Pitch Yaw Mass Vol C33 C44 C55 CdA Ca Ixx Iyy Izz'
      WRITE (u, '(A)') '(-) (-) (m) (m) (m) (deg) (deg) (deg) (kg) (m3) (N/m) (Nm) (Nm) (m2) (-) (kgm2) (kgm2) (kgm2)'
      DO i = 1, SIZE(bodies)
        WRITE (u, '(A)') TRIM(bodies(i))
      END DO
    END IF
    IF (SIZE(rods) > 0) THEN
      WRITE (u, '(A)') '--- ROD TYPES ---'
      WRITE (u, '(A)') 'Name Diam Mass Cd Ca CdEnd CaEnd'
      WRITE (u, '(A)') '(-) (m) (kg/m) (-) (-) (-) (-)'
      WRITE (u, '(A)') TRIM(rod_type)
      WRITE (u, '(A)') '--- RODS ---'
      WRITE (u, '(A)') 'ID RodType Attachment XA YA ZA XB YB ZB NumSegs Outputs'
      WRITE (u, '(A)') '(-) (-) (-) (m) (m) (m) (m) (m) (m) (-) (-)'
      DO i = 1, SIZE(rods)
        WRITE (u, '(A)') TRIM(rods(i))
      END DO
    END IF
    WRITE (u, '(A)') '--- POINTS ---'
    WRITE (u, '(A)') 'ID Type X Y Z Mass Vol CdA Ca'
    WRITE (u, '(A)') '(-) (-) (m) (m) (m) (kg) (m3) (m2) (-)'
    DO i = 1, SIZE(points)
      WRITE (u, '(A)') TRIM(points(i))
    END DO
    WRITE (u, '(A)') '--- LINES ---'
    WRITE (u, '(A)') 'ID NodeA NodeB Outputs'
    WRITE (u, '(A)') '(-) (-) (-) (-)'
    WRITE (u, '(A)') TRIM(line)
    WRITE (u, '(A)') '--- SECTIONS ---'
    WRITE (u, '(A)') 'LineID LineType Length NumSegs'
    WRITE (u, '(A)') '(-) (-) (m) (-)'
    WRITE (u, '(A)') '1 cab '//TRIM(length_segs)
    IF (PRESENT(atts)) THEN
      WRITE (u, '(A)') '--- ATTACHMENTS ---'
      WRITE (u, '(A)') 'LineID ArcLength Mass Volume CdA Ca'
      WRITE (u, '(A)') '(-) (m) (kg) (m3) (m2) (-)'
      DO i = 1, SIZE(atts)
        WRITE (u, '(A)') TRIM(atts(i))
      END DO
    END IF
    WRITE (u, '(A)') '--- END CONNECTIONS ---'
    WRITE (u, '(A)') 'LineID End Stiffness EzX EzY EzZ TorsStiffness NxX NxY NxZ Pretwist'
    WRITE (u, '(A)') '(-) (-) (N-m/rad) (-) (-) (-) (N-m/rad) (-) (-) (-) (deg)'
    DO i = 1, SIZE(endconns)
      WRITE (u, '(A)') TRIM(endconns(i))
    END DO
    WRITE (u, '(A)') '--- OPTIONS ---'
    WRITE (u, '(A)') '9.80665 g'
    WRITE (u, '(A)') '1025.0 rhoW'
    WRITE (u, '(A)') '200.0 WtrDpth'
    DO i = 1, SIZE(options)
      WRITE (u, '(A)') TRIM(options(i))
    END DO
    WRITE (u, '(A)') '--- OUTPUTS ---'
    DO i = 1, SIZE(outs)
      WRITE (u, '(A)') TRIM(outs(i))
    END DO
    WRITE (u, '(A)') '--- END ---'
    CLOSE (u)
  END SUBROUTINE write_deck

  SUBROUTINE run_deck(path, root, ok, em_out)
    CHARACTER(*), INTENT(IN) :: path, root
    LOGICAL, INTENT(OUT) :: ok
    CHARACTER(*), INTENT(OUT) :: em_out
    LOGICAL :: conv
    INTEGER :: es
    CALL CD_Run_Deck_Driver(path, root, conv, es, em_out)
    ok = es == CD_DECKDRV_OK .AND. conv
  END SUBROUTINE run_deck

  SUBROUTINE read_row(path, row, vals, ok)
    !! Data row `row` (0 = first) of a driver .out file.
    CHARACTER(*), INTENT(IN) :: path
    INTEGER, INTENT(IN) :: row
    REAL(wp), INTENT(OUT) :: vals(:)
    LOGICAL, INTENT(OUT) :: ok
    INTEGER :: u, ios, i
    CHARACTER(2048) :: buf
    ok = .FALSE.
    vals = 0.0_wp
    OPEN (NEWUNIT=u, FILE=path, STATUS='OLD', ACTION='READ', IOSTAT=ios)
    IF (ios /= 0) RETURN
    READ (u, '(A)', IOSTAT=ios) buf
    READ (u, '(A)', IOSTAT=ios) buf
    DO i = 0, row
      READ (u, *, IOSTAT=ios) vals
      IF (ios /= 0) THEN
        CLOSE (u)
        RETURN
      END IF
    END DO
    CLOSE (u)
    ok = ALL(IEEE_IS_FINITE(vals))
  END SUBROUTINE read_row

  LOGICAL FUNCTION same_file(a, b) RESULT(same)
    !! Byte-identical text files.
    CHARACTER(*), INTENT(IN) :: a, b
    INTEGER :: ua, ub, ia, ib
    CHARACTER(4096) :: la, lb
    same = .FALSE.
    OPEN (NEWUNIT=ua, FILE=a, STATUS='OLD', ACTION='READ', IOSTAT=ia)
    IF (ia /= 0) RETURN
    OPEN (NEWUNIT=ub, FILE=b, STATUS='OLD', ACTION='READ', IOSTAT=ib)
    IF (ib /= 0) THEN
      CLOSE (ua)
      RETURN
    END IF
    DO
      READ (ua, '(A)', IOSTAT=ia) la
      READ (ub, '(A)', IOSTAT=ib) lb
      IF (ia /= 0 .OR. ib /= 0) EXIT
      IF (la /= lb) THEN
        CLOSE (ua)
        CLOSE (ub)
        RETURN
      END IF
    END DO
    same = ia /= 0 .AND. ib /= 0
    CLOSE (ua)
    CLOSE (ub)
  END FUNCTION same_file

  FUNCTION vec(v) RESULT(s)
    !! Three numbers at full precision for a deck row.
    REAL(wp), INTENT(IN) :: v(3)
    CHARACTER(80) :: s
    WRITE (s, '(3ES25.16E3)') v
  END FUNCTION vec

  ! ------------------------------------------------------------------------------------------
  SUBROUTINE check_fixed_rod()
    !! Gate 1. The rod runs 10 m from (0, 0, -30) along a = (0.48, 0.36, -0.8); the 100 m line
    !! hangs from its End B along a to an anchor 100.01 m away, both ends Rigid in bending and
    !! torsion with Ez = a and Nx = (0.6, -0.8, 0) (normal to a, global axes).
    CHARACTER(16), PARAMETER :: OUTS(6) = [CHARACTER(16) :: 'Torq1N1', 'Torq1N41', 'Twist1', 'Rod1Mx', 'Rod1My', &
                                                                                                   'Rod1Mz']
    REAL(wp), PARAMETER :: AX(3) = [0.48_wp, 0.36_wp, -0.8_wp], NX(3) = [0.6_wp, -0.8_wp, 0.0_wp]
    REAL(wp), PARAMETER :: LN = 100.0_wp
    REAL(wp) :: pa(3), pb(3), anchor(3), m_ref, v(7), vp(7), e_ref, e_route, e_zero, e_mom, e_dyn, e_pin
    CHARACTER(256) :: rrow, prow, arow, ca, cb
    LOGICAL :: ok
    CHARACTER(512) :: em
    INTEGER :: k
    pa = [0.0_wp, 0.0_wp, -30.0_wp]
    pb = pa + 10.0_wp*AX
    anchor = pb + (LN*1.0001_wp)*AX
    rrow = '1 arm Fixed '//TRIM(vec(pa))//' '//TRIM(vec(pb))//' 4 -'
    WRITE (arow, '(A,A,A)') '2 Fixed ', TRIM(vec(anchor)), ' 0 0 0 0'
    m_ref = GJ*4.0_wp*PI/LN
    ! (a) two turns between the ends, from a nonzero End A pretwist
    ca = '1 A Rigid '//TRIM(vec(AX))//' Rigid '//TRIM(vec(NX))//' 30'
    cb = '1 B Rigid '//TRIM(vec(AX))//' Rigid '//TRIM(vec(NX))//' 750'
    CALL write_deck('trod_fixed.dat', [CHARACTER(8) ::], [rrow], [arow], '1 R1B 2 -', '100.0 40', [ca, cb], &
                    [CHARACTER(16) :: '0.1 dtM', '0.0 TMax'], OUTS)
    CALL run_deck('trod_fixed.dat', 'trod_fixed', ok, em)
    CALL require(ok, '1: a torsional End A on a Fixed rod runs: '//TRIM(em))
    IF (.NOT. ok) RETURN
    CALL read_row('trod_fixed.out', 0, v, ok)
    CALL require(ok, '1: Fixed rod output readable')
    e_ref = nan_max_abs(v(2:3) - m_ref)/m_ref
    ! Rod1M about the rod's End A: the line pulls along the rod axis through End B, the neutral
    ! rod's weight and buoyancy cancel, so the moment is the connection moment M_t a
    e_mom = NORM2(v(5:7) - m_ref*AX)/m_ref
    ! (b) the same line hung from a Coupled point at the rod's End B, which the standalone finite-EI
    ! march (a second route; it takes no Fixed End A) holds still
    WRITE (prow, '(A,A,A)') '1 Coupled ', TRIM(vec(pb)), ' 0 0 0 0'
    CALL write_deck('trod_point.dat', [CHARACTER(8) ::], [CHARACTER(8) ::], [prow, arow], '1 1 2 -', '100.0 40', &
                    [ca, cb], [CHARACTER(16) :: '0.1 dtM', '0.0 TMax'], OUTS(1:3))
    CALL run_deck('trod_point.dat', 'trod_point', ok, em)
    CALL require(ok, '1: the same line from a held Coupled point runs: '//TRIM(em))
    e_route = 1.0_wp
    IF (ok) CALL read_row('trod_point.out', 0, vp(1:4), ok)
    IF (ok) e_route = nan_max_abs(v(2:4) - vp(2:4))/m_ref
    ! (c) equal normals and pretwists: no twist, whatever the roll of the rod frame
    ca = '1 A Rigid '//TRIM(vec(AX))//' Rigid '//TRIM(vec(NX))//' 45'
    cb = '1 B Rigid '//TRIM(vec(AX))//' Rigid '//TRIM(vec(NX))//' 45'
    CALL write_deck('trod_zero.dat', [CHARACTER(8) ::], [rrow], [arow], '1 R1B 2 -', '100.0 40', [ca, cb], &
                    [CHARACTER(16) :: '0.1 dtM', '0.0 TMax'], OUTS)
    CALL run_deck('trod_zero.dat', 'trod_zero', ok, em)
    CALL require(ok, '1: the untwisted rod-end line runs: '//TRIM(em))
    CALL read_row('trod_zero.out', 0, vp, ok)
    e_zero = nan_max_abs([vp(2:3), NORM2(vp(5:7))])/m_ref
    ! (d) a 1 s march holds the torque
    ca = '1 A Rigid '//TRIM(vec(AX))//' Rigid '//TRIM(vec(NX))//' 30'
    cb = '1 B Rigid '//TRIM(vec(AX))//' Rigid '//TRIM(vec(NX))//' 750'
    CALL write_deck('trod_dyn.dat', [CHARACTER(8) ::], [rrow], [arow], '1 R1B 2 -', '100.0 40', [ca, cb], &
                    [CHARACTER(16) :: '0.1 dtM', '1.0 TMax'], OUTS)
    CALL run_deck('trod_dyn.dat', 'trod_dyn', ok, em)
    CALL require(ok, '1: the Fixed rod march runs: '//TRIM(em))
    e_dyn = 0.0_wp
    DO k = 0, 10
      CALL read_row('trod_dyn.out', k, vp, ok)
      IF (.NOT. ok) EXIT
      e_dyn = nan_max_abs([e_dyn, nan_max_abs(vp(2:3) - m_ref)/m_ref, NORM2(vp(5:7) - m_ref*AX)/m_ref])
    END DO
    CALL require(ok, '1: every march row readable')
    ! (e) bending-pinned, torsionally rigid End A (the semi-tangential end): a straight line
    ! carries the same torque
    ca = '1 A Pinned '//TRIM(vec(AX))//' Rigid '//TRIM(vec(NX))//' 30'
    CALL write_deck('trod_pin.dat', [CHARACTER(8) ::], [rrow], [arow], '1 R1B 2 -', '100.0 40', [ca, cb], &
                    [CHARACTER(16) :: '0.1 dtM', '0.0 TMax'], OUTS)
    CALL run_deck('trod_pin.dat', 'trod_pin', ok, em)
    CALL require(ok, '1: the bending-pinned rod-end line runs: '//TRIM(em))
    CALL read_row('trod_pin.out', 0, vp, ok)
    e_pin = nan_max_abs(vp(2:3) - m_ref)/m_ref
    ! (f) the deck of (a) written anchor first (MoorDyn's order: NodeA the anchor, NodeB the rod
    ! end, each row's Ez from the anchor and its pretwist about it): the reader turns the line
    ! around, and the run is (a)'s bit for bit
    ca = '1 A Rigid '//TRIM(vec(-AX))//' Rigid '//TRIM(vec(NX))//' -750'
    cb = '1 B Rigid '//TRIM(vec(-AX))//' Rigid '//TRIM(vec(NX))//' -30'
    CALL write_deck('trod_af.dat', [CHARACTER(8) ::], [rrow], [arow], '1 2 R1B -', '100.0 40', [ca, cb], &
                    [CHARACTER(16) :: '0.1 dtM', '0.0 TMax'], OUTS)
    CALL run_deck('trod_af.dat', 'trod_af', ok, em)
    CALL require(ok, '1: the anchor-first line onto the Fixed rod runs: '//TRIM(em))
    CALL require(same_file('trod_fixed.out', 'trod_af.out'), '1: the anchor-first deck runs bit for bit as '// &
                 'the rod-first one')
    WRITE (*, '(A,2ES15.7,A,ES15.7,A,ES10.3,A,ES10.3,A,ES10.3,A,ES10.3,A,ES10.3,A,ES10.3,A,L1)') &
      'Fixed rod: Torq N1/N41 ', v(2:3), ' ref GJ Phi/L ', m_ref, ' (rel ', e_ref, '); vs a held Coupled point ', &
      e_route, '; untwisted ', e_zero, '; Rod1M - M a ', e_mom, '; 1 s march ', e_dyn, '; pinned bending ', e_pin, &
      '; anchor-first identical ', same_file('trod_fixed.out', 'trod_af.out')
    CALL require(e_ref <= 1.0e-7_wp, '1: Torq = GJ Phi / L on a Fixed rod end')
    CALL require(e_route <= 1.0e-7_wp, '1: the same torque and twist as from a held Coupled point')
    CALL require(e_zero <= 1.0e-7_wp, '1: equal normals and pretwists give no torque (normal in the rod frame)')
    CALL require(e_mom <= 1.0e-7_wp, '1: Rod<N>M is the torque along the line axis')
    CALL require(e_dyn <= 1.0e-7_wp, '1: the march holds the torque and the rod moment')
    CALL require(e_pin <= 1.0e-7_wp, '1: a bending-pinned torsional End A carries the same torque')
  END SUBROUTINE check_fixed_rod

  ! ------------------------------------------------------------------------------------------
  SUBROUTINE check_body_rod_roll()
    !! Gate 2. A Rigid6 body (attitude ROT, translation massive, roll inertia IB) carries a rod
    !! fixed to it from its reference point along dbody (10 m); the 20 m line hangs from the rod's
    !! End B along the rod axis dg = R dbody to an anchor, stretched by 1e-4, and is twisted by
    !! PHI at End B. Released from rest, the body rolls about dg: theta = PHI (1 - cos Omega t).
    REAL(wp), PARAMETER :: ROT(3) = [10.0_wp, -20.0_wp, 35.0_wp], MB = 1.0e9_wp, IB = 1.0e3_wp, LN = 20.0_wp
    REAL(wp), PARAMETER :: PHI_DEG = 30.0_wp, DT = 0.01_wp
    INTEGER, PARAMETER :: NSTEP = 400
    REAL(wp), ALLOCATABLE :: rec(:, :)
    REAL(wp) :: r0(3, 3), rk(3, 3), q(3, 3), dbody(3), nbody(3), dg(3), dk(3), pb(3), anchor(3), w(3), s, ang
    REAL(wp) :: kt, phi, ieff, omega, m0, theta, mt, v(5), e_torque, e_axis, e_rod, e_chan, e_wave, mrod
    CHARACTER(256) :: brow, rrow, arow, ca, cb
    LOGICAL :: ok
    CHARACTER(512) :: em
    INTEGER :: k
    r0 = CD_Body_Rotation(ROT(1), ROT(2), ROT(3))
    dbody = [0.0_wp, 0.6_wp, -0.8_wp]
    nbody = [1.0_wp, 0.0_wp, 0.0_wp]
    dg = MATMUL(r0, dbody)
    pb = [0.0_wp, 0.0_wp, -60.0_wp] + 10.0_wp*dg
    anchor = pb + (LN*1.0001_wp)*dg
    WRITE (brow, '(A,3F8.2,A,ES24.16,A,ES24.16,A,3ES12.4)') '1 Rigid6 0 0 -60 ', ROT, ' ', MB, ' ', MB/RHOW, &
      ' 0 0 0 0 0 ', IB, IB, IB
    rrow = '1 arm Body1 0 0 0 '//TRIM(vec(10.0_wp*dbody))//' 4 -'
    WRITE (arow, '(A,A,A)') '2 Fixed ', TRIM(vec(anchor)), ' 0 0 0 0'
    ca = '1 A Rigid '//TRIM(vec(dbody))//' Rigid '//TRIM(vec(nbody))//' 0'
    WRITE (cb, '(A,A,A,A,F8.2)') '1 B Rigid ', TRIM(vec(dg)), ' Rigid ', TRIM(vec(MATMUL(r0, nbody))), PHI_DEG
    CALL write_deck('trod_body.dat', [brow], [rrow], [arow], '1 R1B 2 -', '20.0 20', [ca, cb], &
                    [CHARACTER(24) :: 'moordyn bodyWetting', 'deck bodyIC', '0.01 dtM', '4.0 TMax'], &
                    [CHARACTER(12) :: 'Torq1N1', 'Rod1Mx', 'Rod1My', 'Rod1Mz'])
    CALL CD_Multibody_Probe_Arm([0.0_wp, 0.0_wp, 0.0_wp], [0.0_wp, 0.0_wp, 0.0_wp])
    CALL run_deck('trod_body.dat', 'trod_body', ok, em)
    CALL CD_Multibody_Probe_Get(rec)
    ok = ok .AND. ALLOCATED(rec)
    CALL require(ok, '2: the rod on a rolling body runs and is probed: '//TRIM(em))
    IF (.NOT. ok) RETURN
    ok = UBOUND(rec, 2) >= NSTEP
    CALL require(ok, '2: every step is recorded')
    IF (.NOT. ok) RETURN
    kt = GJ/LN
    phi = PHI_DEG*PI/180.0_wp
    m0 = kt*phi
    ! the roll inertia about dg: the body's and the rod's polar inertia m r^2 / 2 (the rod axis is
    ! the roll axis)
    mrod = RHOW*0.25_wp*PI*0.04_wp*10.0_wp
    ieff = IB + 0.5_wp*mrod*0.1_wp**2
    omega = SQRT(kt/ieff)
    e_torque = 0.0_wp
    e_axis = 0.0_wp
    e_rod = 0.0_wp
    e_chan = 0.0_wp
    e_wave = 0.0_wp
    DO k = 0, NSTEP
      CALL read_row('trod_body.out', k, v, ok)
      IF (.NOT. ok) EXIT
      rk = RESHAPE(rec(8:16, k), [3, 3])
      ! the body's roll since the start, about dg (axis-angle of R_k R_0^T)
      q = MATMUL(rk, TRANSPOSE(r0))
      ang = ACOS(MAX(-1.0_wp, MIN(1.0_wp, 0.5_wp*(q(1, 1) + q(2, 2) + q(3, 3) - 1.0_wp))))
      w = [q(3, 2) - q(2, 3), q(1, 3) - q(3, 1), q(2, 1) - q(1, 2)]
      s = NORM2(w)
      theta = 0.0_wp
      IF (s > 1.0e-12_wp) theta = SIGN(ang, DOT_PRODUCT(w, dg))
      dk = MATMUL(q, dg)
      ! the moment the line returns to the body (committed connection moment)
      mt = DOT_PRODUCT(rec(24:26, k), dk)
      e_torque = nan_max_abs([e_torque, ABS(mt - kt*(phi - theta))/m0])
      e_axis = nan_max_abs([e_axis, NORM2(rec(24:26, k) - mt*dk)/m0])
      e_rod = nan_max_abs([e_rod, NORM2(v(3:5) - rec(24:26, k))/m0])
      e_chan = nan_max_abs([e_chan, ABS(v(2) - mt)/m0])
      e_wave = nan_max_abs([e_wave, ABS(theta - phi*(1.0_wp - COS(omega*REAL(k, wp)*DT)))/phi])
    END DO
    CALL require(ok, '2: all output rows readable')
    WRITE (*, '(A,ES10.3,A,ES10.3,A,ES10.3,A,ES10.3,A,ES10.3,A,F8.4,A)') 'rod on a rolling body: torque vs '// &
      'GJ (Phi - theta)/L ', e_torque, ', moment off the line axis ', e_axis, ', Rod1M vs the returned moment ', &
      e_rod, ', Torq channel ', e_chan, ' (of GJ Phi/L); roll vs Phi (1 - cos Omega t) ', e_wave, ' of Phi (Omega = ', &
      omega, ' rad/s)'
    CALL require(e_torque <= 1.0e-6_wp, '2: the torque follows GJ (Phi - theta) / L quasi-statically')
    CALL require(e_axis <= 1.0e-6_wp, '2: the moment returned to the body is the torque along the line axis')
    CALL require(e_rod <= 1.0e-6_wp, '2: Rod<N>M of the body-fixed rod carries the connection moment')
    CALL require(e_chan <= 1.0e-6_wp, '2: Torq<L>N1 is the returned torque')
    CALL require(e_wave <= 1.0e-2_wp, '2: the body and rod swing as a torsional pendulum at sqrt(GJ/(L I))')
  END SUBROUTINE check_body_rod_roll

  ! ------------------------------------------------------------------------------------------
  SUBROUTINE check_refusals()
    !! Gate 3. A rod without a roll angle refuses the torsion by name; so does a Coupled rod.
    CHARACTER(256) :: brow
    CALL refused('Pinned', '1 arm Pinned 0 0 -30 0 0 -40 4 -', [CHARACTER(8) ::], &
                 'on the end of ROD 1 (pinned) is not supported: a free or pinned rod is axisymmetric')
    CALL refused('Free', '1 arm Free 0 0 -30 0 0 -40 4 -', [CHARACTER(8) ::], &
                 'on the end of ROD 1 (free) is not supported: a free or pinned rod is axisymmetric')
    brow = '1 Rigid6 0 0 -20 0 0 0 1.0e9 975609.75609756098 0 0 0 0 0 1.0e3 1.0e3 1.0e3'
    CALL refused('Body<N>Pinned', '1 arm Body1Pinned 0 0 -10 0 0 -20 4 -', [brow], &
                 'on the end of ROD 1 (body1pinned) is not supported: a free or pinned rod is axisymmetric')
    CALL refused('Coupled', '1 arm Coupled 0 0 -30 0 0 -40 4 -', [CHARACTER(8) ::], &
                 'on the end of Coupled/Vessel ROD 1 is not supported: no route of this build carries a finite-EI '// &
                 'line on a host-driven rod', 'trod_none.motion motionFile')
    ! the staggered body scheme drives a cable end by translation only: a torsional End A on a
    ! rod fixed to a body (here bending-pinned, which that scheme otherwise takes) is refused
    CALL refused('Body<N> (staggered)', '1 arm Body1 0 0 -10 0 0 -20 4 -', [brow], &
                 'or a torsional one on a body or rod needs bodyScheme monolithic', 'staggered bodyScheme', &
                 'Pinned')
    ! written anchor first onto a Pinned rod, the line is turned around and meets the rod's own
    ! refusal (not "two moving ends")
    CALL refused_rows('anchor-first Pinned', ['1 arm Pinned 0 0 -30 0 0 -40 4 -'], '1 2 R1B -', 1.0_wp, &
                      'on the end of ROD 1 (pinned) is not supported: a free or pinned rod is axisymmetric')
    ! a line between two Fixed rods (a J-tube to a J-tube): no torsion frame at End B's rod end
    CALL refused_rows('two Fixed', [CHARACTER(48) :: '1 arm Fixed 0 0 -30 0 0 -40 4 -', &
                                    '2 arm Fixed 0 0 -140.01 0 0 -150.01 4 -'], '1 R1B R2A -', -1.0_wp, &
                      'line 1: a torsional END CONNECTION on a rod end is not supported at End B')
  END SUBROUTINE check_refusals

  SUBROUTINE refused_rows(label, rod_rows, line_row, ez_z, needle)
    !! A vertical line between z = -40 and -140.01 twisted by 90 deg (Ez = (0, 0, ez_z) at both
    !! ends) on the given rods and LINES row (the Fixed point 2 at the bottom): the deck stops
    !! with the message needle.
    CHARACTER(*), INTENT(IN) :: label, rod_rows(:), line_row, needle
    REAL(wp), INTENT(IN) :: ez_z
    CHARACTER(256) :: ca, cb
    LOGICAL :: ok
    CHARACTER(512) :: em
    ca = '1 A Rigid '//TRIM(vec([0.0_wp, 0.0_wp, ez_z]))//' Rigid 1 0 0 0'
    cb = '1 B Rigid '//TRIM(vec([0.0_wp, 0.0_wp, ez_z]))//' Rigid 1 0 0 90'
    CALL write_deck('trod_ref.dat', [CHARACTER(8) ::], rod_rows, ['2 Fixed 0.0 0.0 -140.01 0 0 0 0'], line_row, &
                    '100.0 40', [ca, cb], [CHARACTER(32) :: '0.1 dtM', '1.0 TMax'], [CHARACTER(8) :: 'Torq1N1'])
    CALL run_deck('trod_ref.dat', 'trod_ref', ok, em)
    WRITE (*, '(A,A,A,A)') 'refusal on a ', label, ' rod line: ', TRIM(em)
    CALL require(.NOT. ok .AND. INDEX(em, needle) > 0, '3: a torsional line on a '//label//' rod is refused '// &
                 'by name (got: '//TRIM(em)//')')
  END SUBROUTINE refused_rows

  SUBROUTINE refused(label, rod_row, bodies, needle, extra, bend_a)
    !! A vertical rod (End B at z = -40, or the body rods' at -40 in global axes) holding a
    !! vertical line twisted by 90 deg: the deck stops with the message needle. extra: one more
    !! OPTIONS row; bend_a: End A's bending connection (default Rigid).
    CHARACTER(*), INTENT(IN) :: label, rod_row, bodies(:), needle
    CHARACTER(*), INTENT(IN), OPTIONAL :: extra, bend_a
    REAL(wp), PARAMETER :: AX(3) = [0.0_wp, 0.0_wp, -1.0_wp], NX(3) = [1.0_wp, 0.0_wp, 0.0_wp]
    CHARACTER(64), PARAMETER :: ROW_A = '2 Fixed 0.0 0.0 -140.01 0 0 0 0'
    CHARACTER(256) :: ca, cb
    LOGICAL :: ok
    CHARACTER(512) :: em
    ca = '1 A Rigid '//TRIM(vec(AX))//' Rigid '//TRIM(vec(NX))//' 0'
    IF (PRESENT(bend_a)) ca = '1 A '//bend_a//' '//TRIM(vec(AX))//' Rigid '//TRIM(vec(NX))//' 0'
    cb = '1 B Rigid '//TRIM(vec(AX))//' Rigid '//TRIM(vec(NX))//' 90'
    IF (PRESENT(extra)) THEN
      CALL write_deck('trod_ref.dat', bodies, [rod_row], [ROW_A], '1 R1B 2 -', '100.0 40', [ca, cb], &
                      [CHARACTER(32) :: '0.1 dtM', '1.0 TMax', 'deck bodyIC', extra], [CHARACTER(8) :: 'Torq1N1'])
    ELSE
      CALL write_deck('trod_ref.dat', bodies, [rod_row], [ROW_A], '1 R1B 2 -', '100.0 40', [ca, cb], &
                      [CHARACTER(32) :: '0.1 dtM', '1.0 TMax', 'deck bodyIC'], [CHARACTER(8) :: 'Torq1N1'])
    END IF
    CALL run_deck('trod_ref.dat', 'trod_ref', ok, em)
    WRITE (*, '(A,A,A,A)') 'refusal on a ', label, ' rod: ', TRIM(em)
    CALL require(.NOT. ok .AND. INDEX(em, needle) > 0, '3: a torsional End A on a '//label//' rod is refused '// &
                 'by name (got: '//TRIM(em)//')')
  END SUBROUTINE refused

  ! ------------------------------------------------------------------------------------------
  SUBROUTINE check_one_end_rod()
    !! Gate 4, one restrained end: the gate 1 J-tube line with GJ|K, free in torsion at one end.
    CHARACTER(16), PARAMETER :: OUTS(3) = [CHARACTER(16) :: 'Torq1N1', 'Torq1N41', 'Twist1']
    REAL(wp), PARAMETER :: AX(3) = [0.48_wp, 0.36_wp, -0.8_wp], NX(3) = [0.6_wp, -0.8_wp, 0.0_wp]
    REAL(wp), PARAMETER :: LN = 100.0_wp, KC = 4.0e5_wp
    CHARACTER(160) :: bare_type
    REAL(wp) :: pa(3), pb(3), anchor(3), tw_ref, v(4), vp(4), e_tw(2), e_m(2), e_route(2)
    CHARACTER(256) :: rrow, prow, arow, ca(2), cb(2)
    CHARACTER(24), PARAMETER :: LABEL(2) = [CHARACTER(24) :: 'End B free', 'End A (rod end) free']
    LOGICAL :: ok
    CHARACTER(512) :: em
    INTEGER :: iv
    bare_type = neutral_type
    WRITE (neutral_type, '(A,ES24.16,A)') 'cab 0.2 ', RHOW*0.25_wp*PI*0.04_wp, &
      ' 1.0e7 0.0 1.0e6 1.0e8 5.0e4|4.0e5 1.0 1.0e-12 0.0 0.0 0.0 0.0'
    pa = [0.0_wp, 0.0_wp, -30.0_wp]
    pb = pa + 10.0_wp*AX
    anchor = pb + (LN*1.0001_wp)*AX
    rrow = '1 arm Fixed '//TRIM(vec(pa))//' '//TRIM(vec(pb))//' 4 -'
    WRITE (arow, '(A,A,A)') '2 Fixed ', TRIM(vec(anchor)), ' 0 0 0 0'
    WRITE (prow, '(A,A,A)') '1 Coupled ', TRIM(vec(pb)), ' 0 0 0 0'
    ! the free end turns by the stretch's -(K/GJ) dl relative to the restrained one
    tw_ref = -(KC/GJ)*(LN*1.0e-4_wp)*180.0_wp/PI
    ca(1) = '1 A Rigid '//TRIM(vec(AX))//' Rigid '//TRIM(vec(NX))//' 30'
    cb(1) = '1 B Rigid '//TRIM(vec(AX))//' Free '//TRIM(vec(NX))//' 0'
    ca(2) = '1 A Rigid '//TRIM(vec(AX))//' Free '//TRIM(vec(NX))//' 0'
    cb(2) = '1 B Rigid '//TRIM(vec(AX))//' Rigid '//TRIM(vec(NX))//' 30'
    DO iv = 1, 2
      CALL write_deck('trod_oe.dat', [CHARACTER(8) ::], [rrow], [arow], '1 R1B 2 -', '100.0 40', [ca(iv), cb(iv)], &
                      [CHARACTER(16) :: '0.1 dtM', '0.0 TMax'], OUTS)
      CALL run_deck('trod_oe.dat', 'trod_oe', ok, em)
      CALL require(ok, '4: a line restrained at one end ('//TRIM(LABEL(iv))//') on a Fixed rod runs with its twist '// &
                   'channels: '//TRIM(em))
      e_tw(iv) = 1.0_wp
      e_m(iv) = 1.0_wp
      e_route(iv) = 1.0_wp
      IF (.NOT. ok) CYCLE
      CALL read_row('trod_oe.out', 0, v, ok)
      CALL require(ok, '4: one-end rod output readable')
      e_tw(iv) = ABS(v(4) - tw_ref)/ABS(tw_ref)
      ! against the torque K eps the coupling would give a section held from twisting
      e_m(iv) = nan_max_abs(v(2:3))/(KC*1.0e-4_wp)
      CALL write_deck('trod_oep.dat', [CHARACTER(8) ::], [CHARACTER(8) ::], [prow, arow], '1 1 2 -', '100.0 40', &
                      [ca(iv), cb(iv)], [CHARACTER(16) :: '0.1 dtM', '0.0 TMax'], OUTS)
      CALL run_deck('trod_oep.dat', 'trod_oep', ok, em)
      CALL require(ok, '4: the same line from a held Coupled point runs: '//TRIM(em))
      IF (ok) CALL read_row('trod_oep.out', 0, vp, ok)
      IF (ok) e_route(iv) = ABS(v(4) - vp(4))/ABS(tw_ref)
      WRITE (*, '(A,A,A,F12.7,A,F12.7,A,3ES10.3)') 'one end on a Fixed rod, ', TRIM(LABEL(iv)), ': Twist1 ', v(4), &
        ' deg (-(K/GJ) dl ', tw_ref, '); errors twist, |torque| / K eps, vs a held Coupled point ', e_tw(iv), &
        e_m(iv), e_route(iv)
    END DO
    neutral_type = bare_type
    CALL require(MAXVAL(e_tw) <= 1.0e-6_wp, '4: the free end turns by -(K/GJ) dl on a Fixed rod end')
    CALL require(MAXVAL(e_m) <= 1.0e-6_wp, '4: a line free at one end carries no torque on a Fixed rod end')
    CALL require(MAXVAL(e_route) <= 1.0e-6_wp, '4: the same twist as from a held Coupled point')
  END SUBROUTINE check_one_end_rod

  SUBROUTINE check_attachments_rod()
    !! Gate 4, ATTACHMENTS: the gate 1 line twisted two turns with two clumps and a buoy.
    CHARACTER(16), PARAMETER :: OUTS(3) = [CHARACTER(16) :: 'Torq1N1', 'Torq1N41', 'Twist1']
    REAL(wp), PARAMETER :: AX(3) = [0.48_wp, 0.36_wp, -0.8_wp], NX(3) = [0.6_wp, -0.8_wp, 0.0_wp]
    REAL(wp), PARAMETER :: LN = 100.0_wp
    CHARACTER(48), PARAMETER :: ATTS(3) = [CHARACTER(48) :: '1 25.0 500.0 0.1 0.0 0.0', '1 50.0 50.0 0.4 0.0 0.0', &
                                                                                            '1 75.0 300.0 0.05 0.0 0.0']
    REAL(wp) :: pa(3), pb(3), anchor(3), m_ref, v(4), vp(4), e_route
    CHARACTER(256) :: rrow, prow, arow, ca, cb
    LOGICAL :: ok
    CHARACTER(512) :: em
    pa = [0.0_wp, 0.0_wp, -30.0_wp]
    pb = pa + 10.0_wp*AX
    anchor = pb + (LN*1.0001_wp)*AX
    rrow = '1 arm Fixed '//TRIM(vec(pa))//' '//TRIM(vec(pb))//' 4 -'
    WRITE (arow, '(A,A,A)') '2 Fixed ', TRIM(vec(anchor)), ' 0 0 0 0'
    WRITE (prow, '(A,A,A)') '1 Coupled ', TRIM(vec(pb)), ' 0 0 0 0'
    m_ref = GJ*4.0_wp*PI/LN
    ca = '1 A Rigid '//TRIM(vec(AX))//' Rigid '//TRIM(vec(NX))//' 30'
    cb = '1 B Rigid '//TRIM(vec(AX))//' Rigid '//TRIM(vec(NX))//' 750'
    CALL write_deck('trod_att.dat', [CHARACTER(8) ::], [rrow], [arow], '1 R1B 2 -', '100.0 40', [ca, cb], &
                    [CHARACTER(16) :: '0.1 dtM', '0.0 TMax'], OUTS, atts=ATTS)
    CALL run_deck('trod_att.dat', 'trod_att', ok, em)
    CALL require(ok, '4: a rod-end line with ATTACHMENTS runs: '//TRIM(em))
    IF (.NOT. ok) RETURN
    CALL read_row('trod_att.out', 0, v, ok)
    CALL write_deck('trod_attp.dat', [CHARACTER(8) ::], [CHARACTER(8) ::], [prow, arow], '1 1 2 -', '100.0 40', &
                    [ca, cb], [CHARACTER(16) :: '0.1 dtM', '0.0 TMax'], OUTS, atts=ATTS)
    CALL run_deck('trod_attp.dat', 'trod_attp', ok, em)
    CALL require(ok, '4: the same line with ATTACHMENTS from a held Coupled point runs: '//TRIM(em))
    IF (.NOT. ok) RETURN
    CALL read_row('trod_attp.out', 0, vp, ok)
    e_route = nan_max_abs(v(2:4) - vp(2:4))/m_ref
    WRITE (*, '(A,3ES15.7,A,3ES15.7,A,ES10.3)') 'ATTACHMENTS on a Fixed rod line: Torq N1/N41, Twist1 ', v(2:4), &
      '; from a held Coupled point ', vp(2:4), '; difference / (GJ Phi/L) ', e_route
    CALL require(e_route <= 1.0e-7_wp, '4: the rod-end line with ATTACHMENTS has the held point''s torque and twist')
    CALL require(ABS(v(2)/m_ref - 1.0_wp) > 1.0e-6_wp, '4: the attachments bend the line (its torque is not GJ Phi/L)')
  END SUBROUTINE check_attachments_rod

END PROGRAM test_rod_end_torsion
