! File: tests/test_torsion_deck.f90
! SPDX-License-Identifier: Apache-2.0
! Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
!> Deck-level gates of condensed torsion (END CONNECTIONS columns TorsStiffness NxX NxY NxZ
!> [Pretwist], the standalone static route, the Torq/Twist channels and the body torque):
!>  1. pure torsion of a straight neutral line clamped at two Fixed points, two turns of
!>     pretwist: Torq = GJ Phi / L at every node, Twist<L> = 720 deg, Twist<L>N<J> linear from
!>     End A; torsional end springs add their compliance;
!>  2. backward compatibility: the same deck with Free torsion columns (any normal), or with one
!>     end restrained only on a 10-column LINE TYPES row (no GJ, so its torsion is not solved),
!>     writes the same .out bytes as the 6-column rows; Rigid, Infinity, Inf and a quoted
!>     "Rigid" are one restraint;
!>  3. a pretwist sweep to three turns on a sagging clamped line: the torque grows in equal
!>     steps (no 2 pi slip) and Twist<L> follows the pretwist;
!>  4. body torque return: a massive Rigid6 body (attitude rolled, pitched and yawed) holding a
!>     twisted straight taut line: the connection moment is M_t along the line axis (1e-8), the body
!>     net wrench equals the line end loads (output precision), and the sign follows the end
!>     that is twisted;
!>  5. body static equilibrium: a moored body whose clamped cable is twisted rolls against the
!>     torque and its static net moment vanishes;
!>  6. named errors for malformed rows, missing GJ, an EI = 0 line, a channel on an unrestrained
!>     line, the configuration blend in a dynamic run, roll-column misuse, the coupled entries;
!>  7. dynamics driven at End A: a motionFile roll column (a step) and a vessel rolling about the
!>     line axis give Twist<L> = -roll and the quasi-static torque at every step;
!>  8. a body rolling about a twisted line oscillates at sqrt(GJ / (L I)), the connection moment
!>     being the torque along the line axis at every step;
!>  9. static body/cable torsion coupling with no yaw restoring and with a yaw stiffness of the
!>     order of GJ/L: the passes converge and the body moment balances to 1e-8;
!> 10. gate 8 with a bending-pinned End A on the turning body (torsion restrained, the
!>     semi-tangential end): the same torsional pendulum and connection moment;
!> 11. gate 8 from rest at Omega dt = 2 and 5: the body roll follows the closed form of the
!>     march's trapezoidal body integrator at every step (unconditionally stable).
PROGRAM test_torsion_deck
  USE CableDyn_Precision, ONLY: wp
  USE CableDyn_Conventions, ONLY: CD_Body_Rotation
  USE CableDyn_DeckDriver, ONLY: CD_Run_Deck_Driver, CD_DECKDRV_OK, CD_Multibody_Probe_Arm, CD_Multibody_Probe_Get, &
                                 CD_Init_Deck_Aggregate, CD_DeckAggregateType, CD_End_Deck_Aggregate, &
                                 CD_Init_Deck_HermiteCable, CD_Channel_Unit
  USE CableDyn_OpenFAST_HermiteFMF, ONLY: CD_HFMF_ModuleType, CD_HFMF_End
  USE, INTRINSIC :: IEEE_ARITHMETIC, ONLY: IEEE_IS_FINITE
  IMPLICIT NONE

  REAL(wp), PARAMETER :: PI = 3.14159265358979323846_wp, RHOW = 1025.0_wp
  INTEGER :: n_fail = 0, only
  CHARACTER(160) :: neutral_type
  CHARACTER(16) :: arg
  CHARACTER(8) :: no_rows(0)

  ! neutral 0.2 m section: mass = rhoW pi d^2 / 4; EA 1e7, EI 1e6, GAs 1e8, GJ 5e4, Irn 1e-12 (the
  ! massless-line torsion these gates check, down to the coarse-step pendulum's trapezoidal closed
  ! form: the nodal twist's limit of a negligible polar inertia, whose inertia
  ! test_nodal_twist_dynamic gates)
  WRITE (neutral_type, '(A,ES24.16,A)') 'cab 0.2 ', RHOW*0.25_wp*PI*0.04_wp, &
    ' 1.0e7 0.0 1.0e6 1.0e8 5.0e4 1.0 1.0e-12 0.0 0.0 0.0 0.0'

  ! optional argument: run only gate 1..9 (diagnostics)
  only = 0
  IF (COMMAND_ARGUMENT_COUNT() > 0) THEN
    CALL GET_COMMAND_ARGUMENT(1, arg)
    READ (arg, *) only
  END IF
  IF (only == 0 .OR. only == 1) CALL check_pure_torsion()
  IF (only == 0 .OR. only == 2) CALL check_backward_compatible()
  IF (only == 0 .OR. only == 2) CALL check_rigid_keywords()
  IF (only == 0 .OR. only == 3) CALL check_sweep()
  IF (only == 0 .OR. only == 4) CALL check_body_torque()
  IF (only == 0 .OR. only == 5) CALL check_body_statics()
  IF (only == 0 .OR. only == 6) CALL check_errors()
  IF (only == 0 .OR. only == 7) CALL check_dynamic_roll()
  IF (only == 0 .OR. only == 8) CALL check_body_roll_dynamics('Rigid')
  IF (only == 0 .OR. only == 10) CALL check_body_roll_dynamics('Pinned')
  IF (only == 0 .OR. only == 9) CALL check_body_yaw_statics()
  IF (only == 0 .OR. only == 11) CALL check_body_roll_large_step(2.0_wp)
  IF (only == 0 .OR. only == 11) CALL check_body_roll_large_step(5.0_wp)
  IF (n_fail > 0) THEN
    WRITE (*, '(A,I0,A)') 'FAIL: ', n_fail, ' torsion deck gate(s) failed'
    ERROR STOP 1
  END IF
  WRITE (*, '(A)') 'PASS: torsion deck columns, statics, dynamics, channels, body torque and refusals'

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

  SUBROUTINE write_deck(path, types, bodies, points, lines, sections, endconns, options, outs)
    CHARACTER(*), INTENT(IN) :: path
    CHARACTER(*), INTENT(IN) :: types(:), bodies(:), points(:), lines(:), sections(:), endconns(:), options(:), &
                                outs(:)
    INTEGER :: u, i
    OPEN (NEWUNIT=u, FILE=path, STATUS='REPLACE', ACTION='WRITE')
    WRITE (u, '(A)') 'torsion deck gate'
    WRITE (u, '(A)') '--- LINE TYPES ---'
    IF (INDEX(types(1), 'TEN') > 0) THEN
      WRITE (u, '(A)') 'Name Diam Mass EA BA EI Cdn Cdt Can Cat'
      WRITE (u, '(A)') '(-) (m) (kg/m) (N) (-) (Nm2) (-) (-) (-) (-)'
    ELSE
      WRITE (u, '(A)') 'Name Diam Mass EA BA EI GAs GJ Irt Irn Cdn Cdt Can Cat'
      WRITE (u, '(A)') '(-) (m) (kg/m) (N) (-) (Nm2) (N) (Nm2) (kgm) (kgm) (-) (-) (-) (-)'
    END IF
    DO i = 1, SIZE(types)
      IF (INDEX(types(i), 'TEN') > 0) THEN
        WRITE (u, '(A)') TRIM(types(i) (1:INDEX(types(i), 'TEN') - 1))
      ELSE
        WRITE (u, '(A)') TRIM(types(i))
      END IF
    END DO
    IF (SIZE(bodies) > 0) THEN
      WRITE (u, '(A)') '--- BODIES ---'
      WRITE (u, '(A)') 'ID Type X Y Z Roll Pitch Yaw Mass Vol C33 C44 C55 CdA Ca Ixx Iyy Izz'
      WRITE (u, '(A)') '(-) (-) (m) (m) (m) (deg) (deg) (deg) (kg) (m3) (N/m) (Nm) (Nm) (m2) (-) (kgm2) (kgm2) (kgm2)'
      DO i = 1, SIZE(bodies)
        WRITE (u, '(A)') TRIM(bodies(i))
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
    DO i = 1, SIZE(lines)
      WRITE (u, '(A)') TRIM(lines(i))
    END DO
    WRITE (u, '(A)') '--- SECTIONS ---'
    WRITE (u, '(A)') 'LineID LineType Length NumSegs'
    WRITE (u, '(A)') '(-) (-) (m) (-)'
    DO i = 1, SIZE(sections)
      WRITE (u, '(A)') TRIM(sections(i))
    END DO
    IF (SIZE(endconns) > 0) THEN
      WRITE (u, '(A)') '--- END CONNECTIONS ---'
      WRITE (u, '(A)') 'LineID End Stiffness EzX EzY EzZ TorsStiffness NxX NxY NxZ Pretwist'
      WRITE (u, '(A)') '(-) (-) (N-m/rad) (-) (-) (-) (N-m/rad) (-) (-) (-) (deg)'
      DO i = 1, SIZE(endconns)
        WRITE (u, '(A)') TRIM(endconns(i))
      END DO
    END IF
    WRITE (u, '(A)') '--- OPTIONS ---'
    WRITE (u, '(A)') '9.80665 g'
    WRITE (u, '(A)') '1025.0 rhoW'
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

  FUNCTION cross(a, b) RESULT(c)
    REAL(wp), INTENT(IN) :: a(3), b(3)
    REAL(wp) :: c(3)
    c = [a(2)*b(3) - a(3)*b(2), a(3)*b(1) - a(1)*b(3), a(1)*b(2) - a(2)*b(1)]
  END FUNCTION cross

  ! ------------------------------------------------------------------------------------------
  SUBROUTINE straight_deck(path, conn_a, conn_b, outs, types)
    !! A 100 m neutral line along +x between two Fixed points, 40 elements, TMax 0.
    CHARACTER(*), INTENT(IN) :: path, conn_a, conn_b, outs(:)
    CHARACTER(*), INTENT(IN), OPTIONAL :: types(:)
    CHARACTER(160) :: trow(1)
    CHARACTER(96) :: ec(2)
    trow(1) = neutral_type
    IF (PRESENT(types)) trow(1) = types(1)
    ec(1) = '1 A '//conn_a
    ec(2) = '1 B '//conn_b
    CALL write_deck(path, trow, no_rows, &
                    [CHARACTER(48) :: '1 Coupled 0.0 0.0 -50.0 0 0 0 0', '2 Fixed 100.0 0.0 -50.0 0 0 0 0'], &
                    [CHARACTER(16) :: '1 1 2 -'], [CHARACTER(24) :: '1 cab 100.0 40'], ec, &
                    [CHARACTER(24) :: '0.1 dtM', '0.0 TMax'], outs)
  END SUBROUTINE straight_deck

  SUBROUTINE check_pure_torsion()
    CHARACTER(16), PARAMETER :: OUTS(8) = [CHARACTER(16) :: 'Torq1N1', 'Torq1N21', 'Torq1N41', 'Twist1N1', &
                                                                         'Twist1N21', 'Twist1N41', 'Twist1', 'FairTen1']
    REAL(wp) :: v(9), m_ref, c
    LOGICAL :: ok
    CHARACTER(512) :: em
    INTEGER :: isp
    DO isp = 0, 1
      IF (isp == 0) THEN
        CALL straight_deck('tdeck_pure.dat', 'Rigid 1 0 0 Rigid 0 0 1 0', 'Rigid 1 0 0 Rigid 0 0 1 720', OUTS)
        c = 100.0_wp/5.0e4_wp
      ELSE
        CALL straight_deck('tdeck_pure.dat', 'Rigid 1 0 0 1.0e5 0 0 1 0', 'Rigid 1 0 0 1.0e5 0 0 1 720', OUTS)
        c = 100.0_wp/5.0e4_wp + 2.0e-5_wp
      END IF
      CALL run_deck('tdeck_pure.dat', 'tdeck_pure', ok, em)
      CALL require(ok, 'pure torsion deck runs: '//TRIM(em))
      IF (.NOT. ok) CYCLE
      CALL read_row('tdeck_pure.out', 0, v, ok)
      CALL require(ok, 'pure torsion output readable')
      m_ref = 4.0_wp*PI/c
      WRITE (*, '(A,I0,A,3ES15.7,A,ES15.7,A,4F10.4)') 'deck pure torsion (springs ', isp, '): Torq ', v(2:4), &
        ' ref ', m_ref, '; Twist N1/N21/N41/total ', v(5:8)
      CALL require(nan_max_abs(v(2:4) - m_ref) <= 1.0e-6_wp*m_ref, 'Torq = GJ Phi / C at every node')
      CALL require(ABS(v(8) - 720.0_wp) <= 1.0e-5_wp, 'Twist<L> = 720 deg')
      CALL require(ABS(v(5)) <= 1.0e-9_wp, 'Twist<L>N1 = 0 at End A')
      CALL require(ABS(v(7) - m_ref*100.0_wp/5.0e4_wp*180.0_wp/PI) <= 1.0e-5_wp, 'Twist<L>N41 = M L / GJ')
      CALL require(ABS(v(6) - 0.5_wp*v(7)) <= 1.0e-5_wp, 'Twist<L>N<J> linear along a uniform line')
    END DO
  END SUBROUTINE check_pure_torsion

  SUBROUTINE check_backward_compatible()
    !! 6-column rows (bending connections only) vs the same with Free torsion columns, and
    !! with one end restrained in torsion: identical .out files.
    CHARACTER(16), PARAMETER :: OUTS(4) = [CHARACTER(16) :: 'FairTen1', 'AnchTen1', 'BendMom1N1', 'Curv1N20']
    CHARACTER(160) :: t10(1)
    LOGICAL :: ok
    CHARACTER(512) :: em
    ! a sagging line so that the bending ends matter; 10-column type row (no GJ)
    t10(1) = 'cab 0.2 60.0 1.0e9 0.0 1.0e5 0.0 0.0 0.0 0.0TEN'
    CALL straight_deck('tdeck_bc0.dat', 'Rigid 1 0 -0.3', 'Rigid 1 0 0.3', OUTS, t10)
    CALL run_deck('tdeck_bc0.dat', 'tdeck_bc0', ok, em)
    CALL require(ok, 'six-column deck runs: '//TRIM(em))
    CALL straight_deck('tdeck_bc1.dat', 'Rigid 1 0 -0.3 Free 0 1 0', 'Rigid 1 0 0.3 Free 0 1 0 45', OUTS, t10)
    CALL run_deck('tdeck_bc1.dat', 'tdeck_bc1', ok, em)
    CALL require(ok, 'Free torsion columns run: '//TRIM(em))
    CALL require(same_file('tdeck_bc0.out', 'tdeck_bc1.out'), 'Free torsion columns: identical .out')
    CALL straight_deck('tdeck_bc2.dat', 'Rigid 1 0 -0.3 Rigid 0 1 0', 'Rigid 1 0 0.3 Free 0 1 0 45', OUTS, t10)
    CALL run_deck('tdeck_bc2.dat', 'tdeck_bc2', ok, em)
    CALL require(ok, 'one-end torsion runs: '//TRIM(em))
    CALL require(same_file('tdeck_bc0.out', 'tdeck_bc2.out'), 'one restrained end: identical .out')
    CALL require(same_file('tdeck_bc0.static.out', 'tdeck_bc2.static.out'), 'one restrained end: identical profile')
    ! a Free end has no torsion frame: a zero normal, or one along Ez, is not checked
    CALL straight_deck('tdeck_bc3.dat', 'Rigid 1 0 -0.3 Free 0 0 0', 'Rigid 1 0 0.3 Zero 1 0 0.3 45', OUTS, t10)
    CALL run_deck('tdeck_bc3.dat', 'tdeck_bc3', ok, em)
    CALL require(ok, 'Free torsion columns with an unused normal run: '//TRIM(em))
    CALL require(same_file('tdeck_bc0.out', 'tdeck_bc3.out'), 'Free torsion columns, unused normal: identical .out')
  END SUBROUTINE check_backward_compatible

  SUBROUTINE check_rigid_keywords()
    !! The TorsStiffness spellings Rigid, Infinity, Inf and a quoted "Rigid" are the same
    !! restraint: the pure-torsion deck writes the same .out with each.
    CHARACTER(16), PARAMETER :: OUTS(2) = [CHARACTER(16) :: 'Torq1N1', 'Twist1']
    CHARACTER(12), PARAMETER :: WORDS(3) = [CHARACTER(12) :: 'Infinity', 'Inf', '"Rigid"']
    LOGICAL :: ok
    CHARACTER(512) :: em
    INTEGER :: k
    CALL straight_deck('tdeck_kw0.dat', 'Rigid 1 0 0 Rigid 0 0 1 0', 'Rigid 1 0 0 Rigid 0 0 1 720', OUTS)
    CALL run_deck('tdeck_kw0.dat', 'tdeck_kw0', ok, em)
    CALL require(ok, 'keyword reference deck runs: '//TRIM(em))
    DO k = 1, SIZE(WORDS)
      CALL straight_deck('tdeck_kw1.dat', 'Rigid 1 0 0 '//TRIM(WORDS(k))//' 0 0 1 0', &
                         'Rigid 1 0 0 '//TRIM(WORDS(k))//' 0 0 1 720', OUTS)
      CALL run_deck('tdeck_kw1.dat', 'tdeck_kw1', ok, em)
      CALL require(ok, 'TorsStiffness '//TRIM(WORDS(k))//' is accepted: '//TRIM(em))
      CALL require(same_file('tdeck_kw0.out', 'tdeck_kw1.out'), 'TorsStiffness '//TRIM(WORDS(k))//' = Rigid')
    END DO
  END SUBROUTINE check_rigid_keywords

  SUBROUTINE check_sweep()
    !! Sagging heavy line (EI 1e4, GJ 1e4) clamped at both ends; pretwist 0..1080 deg in 90 deg
    !! steps (separate runs, each from the untwisted state).
    REAL(wp) :: v(4), tq(0:12), tw(0:12), dstep
    LOGICAL :: ok
    CHARACTER(512) :: em
    CHARACTER(96) :: cb
    CHARACTER(160) :: trow(1)
    INTEGER :: k
    trow(1) = 'cab 0.2 60.0 1.0e9 0.0 1.0e4 1.0e8 1.0e4 1.0 1.0 0.0 0.0 0.0 0.0'
    DO k = 0, 12
      WRITE (cb, '(A,F8.1)') 'Rigid 1 0 0.4 Rigid 0 1 0 ', 90.0_wp*k
      CALL straight_deck('tdeck_sweep.dat', 'Rigid 1 0 -0.4 Rigid 0 1 0 0', TRIM(cb), &
                         [CHARACTER(16) :: 'Torq1N1', 'Torq1N21', 'Twist1'], trow)
      CALL run_deck('tdeck_sweep.dat', 'tdeck_sweep', ok, em)
      CALL require(ok, 'sweep deck runs: '//TRIM(em))
      IF (.NOT. ok) RETURN
      CALL read_row('tdeck_sweep.out', 0, v, ok)
      tq(k) = v(2)
      tw(k) = v(4)
      CALL require(ABS(v(2) - v(3)) <= 1.0e-6_wp*MAX(1.0_wp, ABS(v(2))), 'sweep: torque uniform along the line')
    END DO
    dstep = (tq(12) - tq(0))/12.0_wp
    WRITE (*, '(A,ES12.5,A,ES12.5,A,F10.3,A)') 'deck sweep: torque step ', dstep, ' N m (max deviation ', &
      MAXVAL(ABS(tq(1:12) - tq(0:11) - dstep)), '), Twist1 at 3 turns ', tw(12), ' deg'
    CALL require(dstep > 0.0_wp, 'sweep: torque grows with the pretwist')
    CALL require(MAXVAL(ABS(tq(1:12) - tq(0:11) - dstep)) <= 0.05_wp*dstep, 'sweep: equal torque steps, no slip')
    CALL require(ABS(tw(12) - 1080.0_wp) <= 0.01_wp*1080.0_wp, 'sweep: Twist<L> follows the pretwist')
  END SUBROUTINE check_sweep

  ! ------------------------------------------------------------------------------------------
  SUBROUTINE body_deck(path, rot, pre_a, pre_b, outs)
    !! Massive neutral Rigid6 body (attitude rot) holding a 20 m neutral line, stretched by 1e-4,
    !! from its point off (body frame) along dglob = rot dbody to a Fixed anchor; both ends Rigid
    !! in bending and torsion, normals nbody (body) / rot nbody (anchor).
    CHARACTER(*), INTENT(IN) :: path, outs(:)
    REAL(wp), INTENT(IN) :: rot(3)
    REAL(wp), INTENT(IN) :: pre_a, pre_b
    REAL(wp), PARAMETER :: MB = 1.0e9_wp
    REAL(wp) :: r(3, 3), dbody(3), nbody(3), off(3), ra(3), anchor(3), dg(3), ng(3)
    CHARACTER(256) :: brow, pa, pb, ca, cb
    r = CD_Body_Rotation(rot(1), rot(2), rot(3))
    dbody = [0.8_wp, 0.0_wp, -0.6_wp]
    nbody = [0.0_wp, 1.0_wp, 0.0_wp]
    off = [1.5_wp, 0.5_wp, -0.5_wp]
    ra = [0.0_wp, 0.0_wp, -60.0_wp] + MATMUL(r, off)
    dg = MATMUL(r, dbody)
    ng = MATMUL(r, nbody)
    anchor = ra + 20.002_wp*dg
    WRITE (brow, '(A,3F8.2,A,ES24.16,A,ES24.16,A)') '1 Rigid6 0 0 -60 ', rot, ' ', MB, ' ', MB/RHOW, &
      ' 0 0 0 0 0 1.0e12 1.0e12 1.0e12'
    WRITE (pa, '(A,3ES24.16,A)') '1 Body1 ', off, ' 0 0 0 0'
    WRITE (pb, '(A,3ES24.16,A)') '2 Fixed ', anchor, ' 0 0 0 0'
    WRITE (ca, '(A,3ES24.16,A,3ES24.16,F9.2)') '1 A Rigid ', dbody, ' Rigid ', nbody, pre_a
    WRITE (cb, '(A,3ES24.16,A,3ES24.16,F9.2)') '1 B Rigid ', dg, ' Rigid ', ng, pre_b
    CALL write_deck(path, [neutral_type], [brow], [pa, pb], [CHARACTER(16) :: '1 1 2 -'], &
                    [CHARACTER(24) :: '1 cab 20.0 20'], [ca, cb], &
                    [CHARACTER(24) :: '200.0 WtrDpth', 'moordyn bodyWetting', '0.01 dtM', '0.0 TMax', 'deck bodyIC'], &
                    outs)
  END SUBROUTINE body_deck

  SUBROUTINE check_body_torque()
    CHARACTER(12), PARAMETER :: OUTS(7) = [CHARACTER(12) :: 'Body1Fx', 'Body1Fy', 'Body1Fz', 'Body1Mx', 'Body1My', &
                                                                                                   'Body1Mz', 'Torq1N1']
    REAL(wp), PARAMETER :: ROT(3) = [10.0_wp, -20.0_wp, 35.0_wp]
    REAL(wp), ALLOCATABLE :: rec(:, :)
    REAL(wp) :: r(3, 3), dg(3), off(3), m_ref, ma(3), fa(3), wrench(8), mnet(3), e_axis, ew
    LOGICAL :: ok
    CHARACTER(512) :: em
    INTEGER :: isign
    r = CD_Body_Rotation(ROT(1), ROT(2), ROT(3))
    dg = MATMUL(r, [0.8_wp, 0.0_wp, -0.6_wp])
    off = [1.5_wp, 0.5_wp, -0.5_wp]
    DO isign = 1, -1, -2
      ! +: one turn at End B (Phi = +2 pi); -: one turn at End A (Phi = -2 pi)
      IF (isign == 1) THEN
        CALL body_deck('tdeck_body.dat', ROT, 0.0_wp, 360.0_wp, OUTS)
      ELSE
        CALL body_deck('tdeck_body.dat', ROT, 360.0_wp, 0.0_wp, OUTS)
      END IF
      m_ref = isign*5.0e4_wp*2.0_wp*PI/20.0_wp
      CALL CD_Multibody_Probe_Arm([0.0_wp, 0.0_wp, 0.0_wp], [0.0_wp, 0.0_wp, 0.0_wp])
      CALL run_deck('tdeck_body.dat', 'tdeck_body', ok, em)
      CALL CD_Multibody_Probe_Get(rec)
      ok = ok .AND. ALLOCATED(rec)
      CALL require(ok, 'body torque deck runs and is probed: '//TRIM(em))
      IF (.NOT. ok) RETURN
      ma = rec(24:26, 0)
      fa = rec(27:29, 0)
      e_axis = NORM2(ma - m_ref*dg)/ABS(m_ref)
      CALL read_row('tdeck_body.out', 0, wrench, ok)
      CALL require(ok, 'body torque output readable')
      mnet = cross(MATMUL(r, off), fa) + ma
      ew = nan_max_abs([NORM2(wrench(2:4) - fa)/MAX(NORM2(fa), ABS(m_ref)/20.0_wp), &
                        NORM2(wrench(5:7) - mnet)/NORM2(mnet)])
      WRITE (*, '(A,I2,A,3ES14.6,A,ES10.3,A,ES10.3,A,ES14.6)') 'body torque (sign', isign, '): moment ', ma, &
        ' axis error ', e_axis, ', net wrench vs line loads ', ew, ', Torq ', wrench(8)
      CALL require(e_axis <= 1.0e-8_wp, 'body: connection moment = M_t along the line axis (1e-8)')
      CALL require(ew <= 1.0e-6_wp, 'body: net wrench equals the line end loads (output precision)')
      CALL require(ABS(wrench(8) - m_ref) <= 1.0e-6_wp*ABS(m_ref), 'body: Torq channel = M_t')
      CALL require(NORM2(fa - DOT_PRODUCT(fa, dg)*dg) <= 1.0e-6_wp*NORM2(fa), &
                   'body: the straight twisted line pulls along its axis only')
    END DO
  END SUBROUTINE check_body_torque

  SUBROUTINE moored_deck(path, pretwist)
    !! A buoyant body (C44 = C55 = 2e6 N m/rad) on three EI = 0 legs, with a finite-EI cable
    !! clamped at its keel point (End A) and at an anchor on the seabed (End B), twisted by
    !! pretwist at End B; bodyIC static, TMax 0.
    CHARACTER(*), INTENT(IN) :: path
    REAL(wp), INTENT(IN) :: pretwist
    CHARACTER(96) :: ca, cb
    ca = '4 A Rigid -0.7071067811865476 0.0 -0.7071067811865476 Rigid 0.0 1.0 0.0 0'
    WRITE (cb, '(A,F8.1)') '4 B Rigid -1.0 0.0 0.0 Rigid 0.0 1.0 0.0 ', pretwist
    CALL write_deck(path, [CHARACTER(96) :: 'poly 0.12 15.0 5.0e7 -1.0 0.0 1.0e6 1.0 1.0 1.0 1.2 0.2 1.0 0.0', &
                           'cab 0.2 60.0 5.0e8 -1.0 2.0e4 1.0e8 1.0e4 1.0 1.0 1.2 0.0 1.0 0.0'], &
                    [CHARACTER(96) :: '1 Rigid6 0 0 -20 0 0 0 2.0e4 40.0 0.0 2.0e6 2.0e6 8.0 0.5 3.5e4 3.5e4 3.5e4'], &
                    [CHARACTER(48) :: '1 Body1 1.5 0.0 -2.0 0 0 0 0', '2 Body1 -0.75 1.299 -2.0 0 0 0 0', &
                     '3 Body1 -0.75 -1.299 -2.0 0 0 0 0', '4 Fixed 40.0 0.0 -100.0 0 0 0 0', &
                     '5 Fixed -20.0 34.641 -100.0 0 0 0 0', '6 Fixed -20.0 -34.641 -100.0 0 0 0 0', &
                     '7 Body1 0.0 0.0 -3.0 0 0 0 0', '8 Fixed -40.0 0.0 -100.0 0 0 0 0'], &
                    [CHARACTER(16) :: '1 1 4 -', '2 2 5 -', '3 3 6 -', '4 7 8 -'], &
                    [CHARACTER(24) :: '1 poly 86.85 20', '2 poly 86.85 20', '3 poly 86.85 20', '4 cab 100.0 50'], &
                    [CHARACTER(96) :: ca, cb], &
                    [CHARACTER(24) :: '100.0 WtrDpth', '1.0e5 kBot', '1.0e4 cBot', '0.05 dtM', '0.0 TMax', &
                     'static bodyIC'], &
                    [CHARACTER(12) :: 'Body1Rx', 'Body1Ry', 'Body1Rz', 'Body1Mx', 'Body1My', 'Body1Mz', 'Torq4N1'])
  END SUBROUTINE moored_deck

  SUBROUTINE check_body_statics()
    REAL(wp) :: v0(8), v1(8)
    LOGICAL :: ok, ok1
    CHARACTER(512) :: em
    CALL moored_deck('tdeck_moor0.dat', 0.0_wp)
    CALL run_deck('tdeck_moor0.dat', 'tdeck_moor0', ok, em)
    CALL require(ok, 'moored untwisted deck runs: '//TRIM(em))
    CALL moored_deck('tdeck_moor1.dat', 720.0_wp)
    CALL run_deck('tdeck_moor1.dat', 'tdeck_moor1', ok1, em)
    CALL require(ok1, 'moored twisted deck runs: '//TRIM(em))
    IF (.NOT. (ok .AND. ok1)) RETURN
    CALL read_row('tdeck_moor0.out', 0, v0, ok)
    CALL read_row('tdeck_moor1.out', 0, v1, ok1)
    CALL require(ok .AND. ok1, 'moored outputs readable')
    WRITE (*, '(A,3F11.6,A,3F11.6,A,3ES11.3,A,ES12.5)') 'moored body: attitude untwisted ', v0(2:4), &
      ' deg, twisted ', v1(2:4), ' deg; static net moment ', v1(5:7), ' N m; Torq ', v1(8)
    CALL require(v1(8) > 1.0e3_wp, 'moored: the twisted cable carries torque')
    CALL require(nan_max_abs(v1(2:4) - v0(2:4)) > 1.0e-3_wp, 'moored: the torque turns the body in statics')
    CALL require(nan_max_abs(v1(5:7)) <= 1.0e-4_wp*v1(8), 'moored: the static body moment balances the torque')
  END SUBROUTINE check_body_statics

  ! ------------------------------------------------------------------------------------------
  SUBROUTINE roll_deck(path, opt_motion, point_a)
    !! The straight 100 m neutral line of straight_deck, End A on point_a (Coupled or Vessel),
    !! both ends clamped and restrained in torsion with no pretwist, dynamic: dtM 0.05, TMax 0.5.
    CHARACTER(*), INTENT(IN) :: path, opt_motion, point_a
    CHARACTER(48) :: prow(2)
    prow(1) = '1 '//point_a//' 0.0 0.0 -50.0 0 0 0 0'
    prow(2) = '2 Fixed 100.0 0.0 -50.0 0 0 0 0'
    CALL write_deck(path, [neutral_type], no_rows, prow, &
                    [CHARACTER(16) :: '1 1 2 r'], [CHARACTER(24) :: '1 cab 100.0 40'], &
                    [CHARACTER(96) :: '1 A Rigid 1 0 0 Rigid 0 0 1 0', '1 B Rigid 1 0 0 Rigid 0 0 1 0'], &
                    [CHARACTER(48) :: '0.05 dtM', '0.5 TMax', opt_motion], &
                    [CHARACTER(16) :: 'Torq1N1', 'Torq1N41', 'Twist1'])
  END SUBROUTINE roll_deck

  SUBROUTINE check_dynamic_roll()
    !! 7a. motionFile roll column: End A rolls 30 deg about Ez at t = 0.05 s (a step): from that
    !!     first step on, Twist1 = -30 deg and Torq = GJ Twist / L at both ends (quasi-static
    !!     torsion: no torsional inertia, the torque follows the roll at once).
    !! 7b. vesselMotion: the vessel rolls about the line axis at 60 deg/s: the End A frame turns
    !!     with it and Twist1 = -roll(t), Torq = GJ Twist / L at every step (a frame rotation and
    !!     an imposed roll of the same end are the same twist).
    REAL(wp), PARAMETER :: GJ = 5.0e4_wp, L = 100.0_wp
    REAL(wp) :: v(4), roll, werr_a, werr_b, terr
    LOGICAL :: ok
    CHARACTER(512) :: em
    INTEGER :: u, k
    ! 7a
    OPEN (NEWUNIT=u, FILE='tdeck_roll_motion.txt', STATUS='REPLACE', ACTION='WRITE')
    DO k = 0, 10
      roll = MERGE(0.0_wp, 30.0_wp, k == 0)
      WRITE (u, '(F6.2,A,F6.1)') 0.05_wp*k, ' 1 0.0 0.0 -50.0 0 0 0 0 0 0 ', roll
    END DO
    CLOSE (u)
    CALL roll_deck('tdeck_roll_a.dat', 'tdeck_roll_motion.txt motionFile', 'Coupled')
    CALL run_deck('tdeck_roll_a.dat', 'tdeck_roll_a', ok, em)
    CALL require(ok, '7a: the motionFile roll deck runs: '//TRIM(em))
    werr_a = 0.0_wp
    terr = 0.0_wp
    DO k = 0, 10
      CALL read_row('tdeck_roll_a.out', k, v, ok)
      CALL require(ok, '7a: output row readable')
      IF (.NOT. ok) EXIT
      roll = MERGE(0.0_wp, 30.0_wp, k == 0)
      werr_a = nan_max_abs([werr_a, ABS(v(4) + roll)])
      terr = nan_max_abs([terr, ABS(v(2) - GJ*(-roll*PI/180.0_wp)/L), ABS(v(3) - v(2))])
    END DO
    WRITE (*, '(A,ES10.3,A,ES10.3,A)') 'roll column (step): Twist1 error ', werr_a, ' deg, torque error ', terr, ' N m'
    CALL require(werr_a <= 1.0e-6_wp, '7a: Twist1 = -roll from the first step on')
    CALL require(terr <= 1.0e-6_wp*GJ, '7a: Torq = GJ Twist / L at both ends at every step (quasi-static)')
    CALL check_roll_range('tdeck_roll_a.Line1.range.out', GJ*(-30.0_wp*PI/180.0_wp)/L)
    ! 7b
    OPEN (NEWUNIT=u, FILE='tdeck_roll_vessel.txt', STATUS='REPLACE', ACTION='WRITE')
    DO k = 0, 10
      WRITE (u, '(F6.2,A,F10.4,A,ES24.16,A)') 0.05_wp*k, ' 0 0 -50 ', 60.0_wp*0.05_wp*k, ' 0 0 0 0 0 ', &
        60.0_wp*PI/180.0_wp, ' 0 0 0 0 0 0 0 0'
    END DO
    CLOSE (u)
    CALL roll_deck('tdeck_roll_b.dat', 'tdeck_roll_vessel.txt vesselMotion', 'Vessel')
    CALL insert_option('tdeck_roll_b.dat', '0|0|-50 vesselRef')
    CALL run_deck('tdeck_roll_b.dat', 'tdeck_roll_b', ok, em)
    CALL require(ok, '7b: the vessel-roll deck runs: '//TRIM(em))
    werr_b = 0.0_wp
    terr = 0.0_wp
    DO k = 0, 10
      CALL read_row('tdeck_roll_b.out', k, v, ok)
      CALL require(ok, '7b: output row readable')
      IF (.NOT. ok) EXIT
      roll = 60.0_wp*0.05_wp*k
      werr_b = nan_max_abs([werr_b, ABS(v(4) + roll)])
      terr = nan_max_abs([terr, ABS(v(2) - GJ*(v(4)*PI/180.0_wp)/L)])
    END DO
    WRITE (*, '(A,ES10.3,A,ES10.3,A)') 'vessel roll: Twist1 error ', werr_b, ' deg, torque error ', terr, ' N m'
    CALL require(werr_b <= 1.0e-6_wp, '7b: the End A frame turns with the vessel: Twist1 = -roll(t)')
    CALL require(terr <= 1.0e-6_wp*GJ, '7b: Torq = GJ Twist / L under vessel roll')
  END SUBROUTINE check_dynamic_roll

  SUBROUTINE check_roll_range(path, m_step)
    !! 7c. The range graph of a torsional line carries the torque and twist envelopes: over the
    !!     roll step, Torque spans [m_step, 0] at every node and the twist from End A spans
    !!     [-30, 0] deg at End B and is 0 at End A.
    CHARACTER(*), INTENT(IN) :: path
    REAL(wp), INTENT(IN) :: m_step
    CHARACTER(2048) :: head
    CHARACTER(64) :: names(40)
    REAL(wp) :: row(40)
    INTEGER :: u, ios, k, ncol, itq, itw, nrow
    LOGICAL :: ok
    ok = .FALSE.
    OPEN (NEWUNIT=u, FILE=path, STATUS='OLD', ACTION='READ', IOSTAT=ios)
    CALL require(ios == 0, '7c: the range file of the torsional line exists')
    IF (ios /= 0) RETURN
    READ (u, '(A)') head
    READ (u, '(A)') head
    ncol = 0
    names = ''
    READ (head, *, IOSTAT=ios) names
    DO k = 1, SIZE(names)
      IF (LEN_TRIM(names(k)) > 0) ncol = k
    END DO
    itq = 0
    itw = 0
    DO k = 1, ncol
      IF (TRIM(names(k)) == 'TorqueMin') itq = k
      IF (TRIM(names(k)) == 'TwistMin') itw = k
    END DO
    CALL require(itq > 0 .AND. itw > 0, '7c: the range file has Torque and Twist columns')
    IF (itq == 0 .OR. itw == 0) THEN
      CLOSE (u)
      RETURN
    END IF
    READ (u, '(A)') head
    nrow = 0
    DO
      READ (u, *, IOSTAT=ios) row(1:ncol)
      IF (ios /= 0) EXIT
      nrow = nrow + 1
      ok = ABS(row(itq) - m_step) <= 1.0e-6_wp*ABS(m_step) .AND. ABS(row(itq + 1)) <= 1.0e-6_wp*ABS(m_step)
      CALL require(ok, '7c: Torque envelope [M_step, 0] at every node')
      IF (nrow == 1) CALL require(ABS(row(itw)) + ABS(row(itw + 1)) <= 1.0e-9_wp, '7c: no twist at End A')
      IF (nrow == 41) CALL require(ABS(row(itw) + 30.0_wp) <= 1.0e-6_wp .AND. ABS(row(itw + 1)) <= 1.0e-9_wp, &
                                   '7c: twist envelope [-30, 0] deg at End B')
    END DO
    CLOSE (u)
    CALL require(nrow == 41, '7c: one range row per node')
    WRITE (*, '(A,I0,A)') 'roll range graph: ', nrow, ' nodes with Torque and Twist envelopes'
  END SUBROUTINE check_roll_range

  SUBROUTINE insert_option(path, row)
    !! Insert an OPTIONS row (just after the section header) of a deck written by write_deck.
    CHARACTER(*), INTENT(IN) :: path, row
    CHARACTER(512), ALLOCATABLE :: lines(:)   ! the deck text on the heap, not the stack
    INTEGER :: u, n, ios, k
    ALLOCATE (lines(400))
    OPEN (NEWUNIT=u, FILE=path, STATUS='OLD', ACTION='READ')
    n = 0
    DO
      READ (u, '(A)', IOSTAT=ios) lines(n + 1)
      IF (ios /= 0) EXIT
      n = n + 1
    END DO
    CLOSE (u)
    OPEN (NEWUNIT=u, FILE=path, STATUS='REPLACE', ACTION='WRITE')
    DO k = 1, n
      WRITE (u, '(A)') TRIM(lines(k))
      IF (INDEX(lines(k), '--- OPTIONS ---') > 0) WRITE (u, '(A)') TRIM(row)
    END DO
    CLOSE (u)
  END SUBROUTINE insert_option

  ! ------------------------------------------------------------------------------------------
  SUBROUTINE check_body_roll_dynamics(bend)
    !! 8. A Rigid6 body (translation massive, rotational inertia I) holding a straight, taut line
    !!    twisted by one turn at its reference point, released with a small roll rate w0 about the
    !!    line axis: the line's torsion is the only roll stiffness, k = GJ/L, and nothing else holds
    !!    the twist, so the body is a torsional pendulum about the untwisted state: the torque is
    !!    M0 cos(Omega t) - sqrt(k I) w0 sin(Omega t), Omega = sqrt(k / I) (no torsional inertia in
    !!    the line), while the body turns through two turns and back; at every step the connection
    !!    moment on the body is the torque along the line axis. bend is End A's bending
    !!    connection: Rigid (gate 8) or Pinned (gate 10; the torsion frame still turns with the body).
    CHARACTER(*), INTENT(IN) :: bend
    REAL(wp), PARAMETER :: MB = 1.0e9_wp, IB = 1.0e3_wp, GJ = 5.0e4_wp, LN = 20.0_wp, W0 = 0.05_wp
    INTEGER, PARAMETER :: NSTEP = 400
    REAL(wp), ALLOCATABLE :: rec(:, :)
    REAL(wp) :: dg(3), anchor(3), v(2), m0, omega, amp, t, err_axis, err_wave, mt, dk(3), rk(3, 3), kt
    CHARACTER(256) :: brow, pb, cb, ca
    CHARACTER(64) :: root
    LOGICAL :: ok
    CHARACTER(512) :: em
    INTEGER :: k
    root = 'tdeck_broll_'//bend
    ca = '1 A '//bend//' 0.8 0 -0.6 Rigid 0 1 0 0'
    dg = [0.8_wp, 0.0_wp, -0.6_wp]
    anchor = [0.0_wp, 0.0_wp, -60.0_wp] + (LN*1.0001_wp)*dg
    WRITE (brow, '(A,ES24.16,A,ES24.16,A,3ES12.4)') '1 Rigid6 0 0 -60 0 0 0 ', MB, ' ', MB/RHOW, &
      ' 0 0 0 0 0 ', IB, IB, IB
    WRITE (pb, '(A,3ES24.16,A)') '2 Fixed ', anchor, ' 0 0 0 0'
    WRITE (cb, '(A,3ES24.16,A)') '1 B Rigid ', dg, ' Rigid 0 1 0 360'
    CALL write_deck(TRIM(root)//'.dat', [neutral_type], [brow], &
                    [CHARACTER(96) :: '1 Body1 0 0 0 0 0 0 0', pb], [CHARACTER(16) :: '1 1 2 -'], &
                    [CHARACTER(24) :: '1 cab 20.0 20'], &
                    [ca, cb], &
                    [CHARACTER(24) :: '200.0 WtrDpth', 'moordyn bodyWetting', '0.01 dtM', '4.0 TMax', 'deck bodyIC'], &
                    [CHARACTER(12) :: 'Torq1N1'])
    CALL CD_Multibody_Probe_Arm([0.0_wp, 0.0_wp, 0.0_wp], W0*dg)
    CALL run_deck(TRIM(root)//'.dat', TRIM(root), ok, em)
    CALL CD_Multibody_Probe_Get(rec)
    ok = ok .AND. ALLOCATED(rec)
    CALL require(ok, '8/10: the rolling-body deck ('//bend//' End A) runs and is probed: '//TRIM(em))
    IF (.NOT. ok) RETURN
    kt = GJ/LN
    m0 = kt*2.0_wp*PI
    omega = SQRT(kt/IB)
    amp = SQRT(kt*IB)*W0
    err_axis = 0.0_wp
    err_wave = 0.0_wp
    DO k = 0, NSTEP
      CALL read_row(TRIM(root)//'.out', k, v, ok)
      IF (.NOT. ok) EXIT
      t = v(1)
      mt = v(2)
      rk = RESHAPE(rec(8:16, k), [3, 3])
      dk = MATMUL(rk, dg)
      err_axis = nan_max_abs([err_axis, NORM2(rec(24:26, k) - mt*dk)/m0])
      err_wave = nan_max_abs([err_wave, ABS(mt - (m0*COS(omega*t) - amp*SIN(omega*t)))/m0])
    END DO
    CALL require(ok, '8/10: all output rows readable')
    WRITE (*, '(A,A,A,ES10.3,A,ES10.3,A,F8.4,A)') 'body roll dynamics (', bend, ' End A): moment-axis error ', &
      err_axis, ', torque vs M0 cos(Omega t) - sqrt(k I) w0 sin(Omega t) ', err_wave, ' of M0 (Omega = ', omega, &
      ' rad/s)'
    CALL require(err_axis <= 1.0e-6_wp, '8/10: the connection moment on the body is the torque along the axis')
    CALL require(err_wave <= 1.0e-2_wp, '8/10: the body swings as a torsional pendulum at sqrt(GJ/(L I))')
  END SUBROUTINE check_body_roll_dynamics

  ! ------------------------------------------------------------------------------------------
  SUBROUTINE check_body_roll_large_step(wdt)
    !! 11. Gate 8's torsional pendulum stepped coarsely, Omega dt = wdt (2 and 5): a Rigid6 body
    !!     (translation massive, rotational inertia I = k (dt/wdt)^2) starts at rest on a straight
    !!     line twisted by 30 deg. The monolithic march carries the body inertia with am = af,
    !!     beta = 1/4, gamma = 1/2, which on the linear pendulum is the trapezoidal rule whatever
    !!     the dissipation: unconditionally stable, x_{n+1} with the closed form below and
    !!     bounded within [0, 60] deg. At these steps the body turns by up to 56 deg per step,
    !!     so the junction must converge the moment balance to the rotation (not to the body
    !!     weight) and keep each trial turn inside the torsion step limit.
    REAL(wp), INTENT(IN) :: wdt
    REAL(wp), PARAMETER :: MB = 1.0e9_wp, GJ = 5.0e4_wp, LN = 20.0_wp, DT = 0.01_wp, XEQ = 30.0_wp
    INTEGER, PARAMETER :: NSTEP = 20
    REAL(wp), ALLOCATABLE :: rec(:, :)
    REAL(wp) :: dg(3), anchor(3), kt, ib, x, v, a, xp, a1, err, rk(3, 3), w(3), ang, s, th
    CHARACTER(256) :: brow, pb, cb, ca
    CHARACTER(24) :: opt_dt, opt_t
    CHARACTER(64) :: root
    LOGICAL :: ok
    CHARACTER(512) :: em
    INTEGER :: k
    WRITE (root, '(A,I0)') 'tdeck_bigstep_', NINT(wdt)
    kt = GJ/LN
    ib = kt*(DT/wdt)**2
    dg = [0.8_wp, 0.0_wp, -0.6_wp]
    anchor = [0.0_wp, 0.0_wp, -60.0_wp] + (LN*1.0001_wp)*dg
    WRITE (brow, '(A,ES24.16,A,ES24.16,A,3ES24.16)') '1 Rigid6 0 0 -60 0 0 0 ', MB, ' ', MB/RHOW, &
      ' 0 0 0 0 0 ', ib, ib, ib
    WRITE (pb, '(A,3ES24.16,A)') '2 Fixed ', anchor, ' 0 0 0 0'
    ca = '1 A Rigid 0.8 0 -0.6 Rigid 0 1 0 0'
    WRITE (cb, '(A,3ES24.16,A)') '1 B Rigid ', dg, ' Rigid 0 1 0 30'
    WRITE (opt_dt, '(ES12.5,A)') DT, ' dtM'
    WRITE (opt_t, '(ES12.5,A)') NSTEP*DT, ' TMax'
    CALL write_deck(TRIM(root)//'.dat', [neutral_type], [brow], &
                    [CHARACTER(96) :: '1 Body1 0 0 0 0 0 0 0', pb], [CHARACTER(16) :: '1 1 2 -'], &
                    [CHARACTER(24) :: '1 cab 20.0 20'], [ca, cb], &
                    [CHARACTER(24) :: '200.0 WtrDpth', 'moordyn bodyWetting', opt_dt, opt_t, 'deck bodyIC'], &
                    [CHARACTER(12) :: 'Torq1N1'])
    CALL CD_Multibody_Probe_Arm([0.0_wp, 0.0_wp, 0.0_wp], [0.0_wp, 0.0_wp, 0.0_wp])
    CALL run_deck(TRIM(root)//'.dat', TRIM(root), ok, em)
    CALL CD_Multibody_Probe_Get(rec)
    ok = ok .AND. ALLOCATED(rec)
    CALL require(ok, '11: the coarse-step rolling-body deck runs and is probed: '//TRIM(em))
    IF (.NOT. ok) RETURN
    ok = UBOUND(rec, 2) >= NSTEP
    CALL require(ok, '11: every step is recorded')
    IF (.NOT. ok) RETURN
    ! the march's own closed form in steps of dt (h = 1): a = wdt^2 (XEQ - x), from rest
    x = 0.0_wp
    v = 0.0_wp
    a = wdt*wdt*XEQ
    err = 0.0_wp
    DO k = 1, NSTEP
      xp = x + v + 0.25_wp*a
      a1 = wdt*wdt*(XEQ - xp)/(1.0_wp + 0.25_wp*wdt*wdt)
      x = xp + 0.25_wp*a1
      v = v + 0.5_wp*(a + a1)
      a = a1
      rk = RESHAPE(rec(8:16, k), [3, 3])
      ang = ACOS(MAX(-1.0_wp, MIN(1.0_wp, 0.5_wp*(rk(1, 1) + rk(2, 2) + rk(3, 3) - 1.0_wp))))
      w = [rk(3, 2) - rk(2, 3), rk(1, 3) - rk(3, 1), rk(2, 1) - rk(1, 2)]
      s = NORM2(w)
      th = 0.0_wp
      IF (s > 1.0e-12_wp) th = DOT_PRODUCT(w/s, dg)*ang*180.0_wp/PI
      err = nan_max_abs([err, th - x])
    END DO
    WRITE (*, '(A,F4.1,A,ES10.3,A)') 'coarse-step body roll (Omega dt = ', wdt, &
      '): largest body roll error against the trapezoidal closed form ', err, ' deg'
    CALL require(err <= 1.0e-4_wp, '11: the coarse-step torsional pendulum follows the march''s closed form')
  END SUBROUTINE check_body_roll_large_step

  ! ------------------------------------------------------------------------------------------
  SUBROUTINE yaw_deck(path, legs)
    !! A buoyant Rigid6 body (no yaw restoring) held down by a vertical twisted finite-EI cable
    !! clamped at its keel and at an anchor below, both ends restrained in torsion with 90 deg
    !! of pretwist at the anchor, TMax 0, bodyIC static; legs > 0 adds two vertical EI = 0 legs
    !! at +-legs m from the keel (yaw stiffness ~ 2 T legs**2 / L).
    CHARACTER(*), INTENT(IN) :: path
    REAL(wp), INTENT(IN) :: legs
    CHARACTER(64) :: pts(6)
    CHARACTER(16) :: lns(3)
    CHARACTER(24) :: secs(3)
    INTEGER :: np
    pts(1) = '1 Body1 0.0 0.0 -2.0 0 0 0 0'
    pts(2) = '2 Fixed 0.0 0.0 -100.0 0 0 0 0'
    lns(1) = '1 1 2 -'
    secs(1) = '1 cab 77.97 40'
    np = 2
    IF (legs > 0.0_wp) THEN
      WRITE (pts(3), '(A,F6.2,A)') '3 Body1 ', legs, ' 0.0 -2.0 0 0 0 0'
      WRITE (pts(4), '(A,F6.2,A)') '4 Body1 ', -legs, ' 0.0 -2.0 0 0 0 0'
      WRITE (pts(5), '(A,F6.2,A)') '5 Fixed ', legs, ' 0.0 -100.0 0 0 0 0'
      WRITE (pts(6), '(A,F6.2,A)') '6 Fixed ', -legs, ' 0.0 -100.0 0 0 0 0'
      lns(2) = '2 3 5 -'
      lns(3) = '3 4 6 -'
      secs(2) = '2 poly 77.9 20'
      secs(3) = '3 poly 77.9 20'
      np = 6
    END IF
    CALL write_deck(path, [CHARACTER(96) :: 'poly 0.12 15.0 5.0e7 -1.0 0.0 1.0e6 1.0 1.0 1.0 1.2 0.2 1.0 0.0', &
                           'cab 0.2 60.0 5.0e8 -1.0 2.0e4 1.0e8 1.0e4 1.0 1.0 1.2 0.0 1.0 0.0'], &
                    [CHARACTER(96) :: '1 Rigid6 0 0 -20 0 0 0 2.0e4 40.0 0.0 2.0e6 2.0e6 8.0 0.5 3.5e4 3.5e4 3.5e4'], &
                    pts(1:np), lns(1:np/2), secs(1:np/2), &
                    [CHARACTER(96) :: '1 A Rigid 0 0 -1 Rigid 1 0 0 0', '1 B Rigid 0 0 -1 Rigid 1 0 0 90'], &
                    [CHARACTER(24) :: '100.0 WtrDpth', '1.0e5 kBot', '1.0e4 cBot', '0.05 dtM', '0.0 TMax', &
                     'static bodyIC'], &
                    [CHARACTER(12) :: 'Body1Rz', 'Body1Mx', 'Body1My', 'Body1Mz', 'Torq1N1', 'Twist1'])
  END SUBROUTINE yaw_deck

  SUBROUTINE check_body_yaw_statics()
    !! 9. Static body/cable torsion coupling for any ratio of the body's own restoring to GJ/L:
    !!    (a) no yaw restoring at all (0 << GJ/L): the body yaws until the cable carries no torque;
    !!    (b) two legs whose yaw stiffness is of the order of GJ/L: the twist is shared. In both the
    !!    passes converge, Twist1 = 90 deg + body yaw (a straight vertical line: the yaw turns the
    !!    End A frame about the line), and the static net moment on the body vanishes to 1e-8 of
    !!    the untwisted torque GJ (pi/2) / L.
    REAL(wp), PARAMETER :: M_REF = 1.0e4_wp*0.5_wp*PI/78.0_wp
    REAL(wp) :: v(7), share
    LOGICAL :: ok
    CHARACTER(512) :: em
    INTEGER :: icase
    DO icase = 1, 2
      IF (icase == 1) THEN
        CALL yaw_deck('tdeck_yaw.dat', 0.0_wp)
      ELSE
        CALL yaw_deck('tdeck_yaw.dat', 0.3_wp)
      END IF
      CALL run_deck('tdeck_yaw.dat', 'tdeck_yaw', ok, em)
      CALL require(ok, '9: the yawing-body deck runs: '//TRIM(em))
      IF (.NOT. ok) CYCLE
      CALL read_row('tdeck_yaw.out', 0, v, ok)
      CALL require(ok, '9: output readable')
      share = v(7)/90.0_wp
      WRITE (*, '(A,I0,A,F10.5,A,F10.5,A,ES10.3,A,ES11.3,A,F7.4)') 'body yaw statics (', icase, '): yaw ', v(2), &
        ' deg, Twist1 ', v(7), ' deg, |net moment| ', NORM2(v(3:5))/M_REF, ' of GJ Phi/L, Torq ', v(6), &
        ', cable share of the twist ', share
      CALL require(ABS(v(7) - (90.0_wp + v(2))) <= 1.0e-5_wp, '9: Twist1 = 90 deg + body yaw')
      CALL require(NORM2(v(3:5)) <= 1.0e-8_wp*M_REF, '9: static net moment on the body vanishes (1e-8)')
      IF (icase == 1) THEN
        CALL require(ABS(v(6)) <= 1.0e-8_wp*M_REF, '9a: without yaw restoring the cable ends untwisted')
      ELSE
        CALL require(share > 0.1_wp .AND. share < 0.9_wp, '9b: legs and cable share the twist (comparable stiffness)')
      END IF
    END DO
  END SUBROUTINE check_body_yaw_statics

  ! ------------------------------------------------------------------------------------------
  SUBROUTINE expect_error(label, path, root, needle)
    CHARACTER(*), INTENT(IN) :: label, path, root, needle
    LOGICAL :: ok
    CHARACTER(512) :: em
    CALL run_deck(path, root, ok, em)
    CALL require(.NOT. ok .AND. INDEX(em, needle) > 0, label//' (got: '//TRIM(em)//')')
  END SUBROUTINE expect_error

  SUBROUTINE check_one_end_two_moving()
    !! One restrained end on a line with two moving ends (Coupled to Free, dynamic) is not solved
    !! in torsion (it is noted): the one-end row gets exactly the verdict of the six-column rows,
    !! not the torsion rule "two moving ends".
    LOGICAL :: ok0, ok1
    CHARACTER(512) :: em0, em1
    CHARACTER(48), PARAMETER :: PTS(2) = [CHARACTER(48) :: '1 Coupled 0.0 0.0 -50.0 0 0 0 0', &
                                                                                     '2 Free 100.0 0.0 -50.0 100 0 0 0']
    CALL write_deck('tdeck_om0.dat', [neutral_type], no_rows, PTS, [CHARACTER(16) :: '1 1 2 -'], &
                    [CHARACTER(24) :: '1 cab 100.0 40'], [CHARACTER(96) :: '1 A Pinned 1 0 0', '1 B Pinned 1 0 0'], &
                    [CHARACTER(24) :: '0.1 dtM', '1.0 TMax'], [CHARACTER(16) :: 'FairTen1'])
    CALL write_deck('tdeck_om1.dat', [neutral_type], no_rows, PTS, [CHARACTER(16) :: '1 1 2 -'], &
                    [CHARACTER(24) :: '1 cab 100.0 40'], &
                    [CHARACTER(96) :: '1 A Pinned 1 0 0 Free 0 0 1 0', '1 B Pinned 1 0 0 Rigid 0 0 1 0'], &
                    [CHARACTER(24) :: '0.1 dtM', '1.0 TMax'], [CHARACTER(16) :: 'FairTen1'])
    CALL run_deck('tdeck_om0.dat', 'tdeck_om0', ok0, em0)
    CALL run_deck('tdeck_om1.dat', 'tdeck_om1', ok1, em1)
    CALL require((ok0 .EQV. ok1) .AND. TRIM(em0) == TRIM(em1) .AND. INDEX(em1, 'two moving ends') == 0, &
                 'one restrained end on a line with two moving ends: the six-column verdict (got: '//TRIM(em1)//')')
  END SUBROUTINE check_one_end_two_moving

  SUBROUTINE roll_error_deck(path, roll0, every_row)
    !! The roll deck with a motionFile whose roll column starts at roll0 deg and, unless
    !! every_row, is missing on the last row.
    CHARACTER(*), INTENT(IN) :: path
    REAL(wp), INTENT(IN) :: roll0
    LOGICAL, INTENT(IN) :: every_row
    INTEGER :: u, k
    OPEN (NEWUNIT=u, FILE=path//'.motion', STATUS='REPLACE', ACTION='WRITE')
    DO k = 0, 10
      IF (k == 10 .AND. .NOT. every_row) THEN
        WRITE (u, '(F6.2,A)') 0.05_wp*k, ' 1 0.0 0.0 -50.0 0 0 0 0 0 0'
      ELSE
        WRITE (u, '(F6.2,A,F6.1)') 0.05_wp*k, ' 1 0.0 0.0 -50.0 0 0 0 0 0 0 ', MERGE(roll0, 10.0_wp, k == 0)
      END IF
    END DO
    CLOSE (u)
    CALL roll_deck(path, path//'.motion motionFile', 'Coupled')
  END SUBROUTINE roll_error_deck

  SUBROUTINE check_errors()
    CHARACTER(16), PARAMETER :: OUTS(1) = [CHARACTER(16) :: 'Torq1N1']
    CHARACTER(160) :: t10(1), tei0(1)
    TYPE(CD_DeckAggregateType) :: agg
    TYPE(CD_HFMF_ModuleType) :: cab
    INTEGER :: es, node
    CHARACTER(512) :: em
    CALL straight_deck('tdeck_e1.dat', 'Rigid 1 0 0 Rigid 0 0', 'Rigid 1 0 0 Rigid 0 0 1 720', OUTS)
    CALL expect_error('a 9-column row is named', 'tdeck_e1.dat', 'tdeck_e1', 'or 10 or 11 with the torsion columns')
    CALL straight_deck('tdeck_e2.dat', 'Rigid 1 0 0 Stiff 0 0 1 0', 'Rigid 1 0 0 Rigid 0 0 1 720', OUTS)
    CALL expect_error('a bad TorsStiffness token is named', 'tdeck_e2.dat', 'tdeck_e2', 'torsional stiffness')
    CALL expect_error('a bad TorsStiffness names its line, end and value', 'tdeck_e2.dat', 'tdeck_e2', &
                      '(line 1 End A: "Stiff")')
    CALL straight_deck('tdeck_e3.dat', 'Rigid 1 0 0 -1.0 0 0 1 0', 'Rigid 1 0 0 Rigid 0 0 1 720', OUTS)
    CALL expect_error('a negative torsional stiffness is named', 'tdeck_e3.dat', 'tdeck_e3', 'torsional stiffness')
    CALL straight_deck('tdeck_e4.dat', 'Rigid 1 0 0 Rigid 0 0 0 0', 'Rigid 1 0 0 Rigid 0 0 1 720', OUTS)
    CALL expect_error('a null reference normal is named', 'tdeck_e4.dat', 'tdeck_e4', 'must be non-zero')
    CALL expect_error('a null reference normal names its line and end', 'tdeck_e4.dat', 'tdeck_e4', &
                      '(line 1 End A: Nx = ')
    CALL straight_deck('tdeck_e5.dat', 'Rigid 1 0 0 Rigid 2 0 0 0', 'Rigid 1 0 0 Rigid 0 0 1 720', OUTS)
    CALL expect_error('a normal along Ez is named', 'tdeck_e5.dat', 'tdeck_e5', 'must not be parallel')
    CALL expect_error('a normal along Ez names its line and end', 'tdeck_e5.dat', 'tdeck_e5', '(line 1 End A: Nx = ')
    CALL straight_deck('tdeck_e6.dat', 'Rigid 1 0 0 Rigid 0 NaN 1 0', 'Rigid 1 0 0 Rigid 0 0 1 720', OUTS)
    CALL expect_error('a non-finite normal is named', 'tdeck_e6.dat', 'tdeck_e6', 'is not a finite number')
    ! an imposed twist above 1000 turns (a units slip) stops at the deck check, naming the line
    ! and the value in degrees, instead of ramping the statics through millions of stages
    CALL straight_deck('tdeck_e16.dat', 'Rigid 1 0 0 Rigid 0 0 1 -1.0e5', 'Rigid 1 0 0 Rigid 0 0 1 3.0e5', OUTS)
    CALL expect_error('an imposed twist above 1000 turns is named', 'tdeck_e16.dat', 'tdeck_e16', &
                      'line 1: the imposed twist Pretwist(B) - Pretwist(A) = 4.00000E+05 deg exceeds 1000 turns')
    ! a twist far beyond the buckling onset: the failed stage is named once, with its line
    t10(1) = 'cab 0.2 32.2013246 1.0e7 0.0 1.0e6 1.0e8 5.0e4 1.0 1.0e-9 0.0 0.0 0.0 0.0'
    CALL straight_deck('tdeck_e15.dat', 'Rigid 1 0 0 Rigid 0 0 1 0', 'Rigid 1 0 0 Rigid 0 0 1 36000', OUTS, t10)
    CALL expect_error('a failed torsion stage is named without a doubled prefix', 'tdeck_e15.dat', 'tdeck_e15', &
                      'CableDyn_DeckDriver: line 1: finite-EI torsion static solve failed')
    CALL check_one_end_two_moving()
    t10(1) = 'cab 0.2 32.2 1.0e9 0.0 1.0e6 0.0 0.0 0.0 0.0TEN'
    CALL straight_deck('tdeck_e7.dat', 'Rigid 1 0 0 Rigid 0 0 1 0', 'Rigid 1 0 0 Rigid 0 0 1 720', OUTS, t10)
    CALL expect_error('a torsional line without GJ is named', 'tdeck_e7.dat', 'tdeck_e7', 'must give an explicit GJ')
    tei0(1) = 'cab 0.2 60.0 1.0e9 0.0 0.0 0.0 0.0 0.0 0.0TEN'
    CALL straight_deck('tdeck_e8.dat', 'Pinned 1 0 0 Rigid 0 0 1 0', 'Pinned 1 0 0 Free 0 0 1 0', &
                       [CHARACTER(16) :: 'FairTen1'], tei0)
    CALL expect_error('torsion on an EI = 0 line is named', 'tdeck_e8.dat', 'tdeck_e8', 'require a finite-EI line')
    ! (a line restrained at one end only is solved in torsion: test_torsion_one_end)
    CALL straight_deck('tdeck_e9.dat', 'Rigid 1 0 0 Free 0 0 1 0', 'Rigid 1 0 0 Free 0 0 1 720', OUTS)
    CALL expect_error('a torque channel on a line without torsion is named', 'tdeck_e9.dat', 'tdeck_e9', &
                      'carries no torque')
    CALL write_deck('tdeck_e10.dat', [neutral_type], no_rows, &
                    [CHARACTER(48) :: '1 Coupled 0.0 0.0 -50.0 0 0 0 0', '2 Fixed 100.0 0.0 -50.0 0 0 0 0'], &
                    [CHARACTER(16) :: '1 1 2 -'], [CHARACTER(24) :: '1 cab 100.0 40'], &
                    [CHARACTER(96) :: '1 A Rigid 1 0 0 Rigid 0 0 1 0', '1 B Rigid 1 0 0 Rigid 0 0 1 90'], &
                    [CHARACTER(32) :: '0.1 dtM', '1.0 TMax', 'False alpha_force_blend'], OUTS)
    CALL expect_error('the configuration blend is refused with torsion', 'tdeck_e10.dat', 'tdeck_e10', &
                      'force-blended generalised-alpha')
    CALL roll_error_deck('tdeck_e13.dat', 5.0_wp, .TRUE.)
    CALL expect_error('a roll not starting from 0 is named', 'tdeck_e13.dat', 'tdeck_e13', 'must be 0 at t = 0')
    CALL roll_error_deck('tdeck_e14.dat', 0.0_wp, .FALSE.)
    CALL expect_error('a roll column on some rows only is named', 'tdeck_e14.dat', 'tdeck_e14', 'on some rows only')
    CALL write_deck('tdeck_e11.dat', [neutral_type], no_rows, &
                    [CHARACTER(48) :: '1 Coupled 0.0 0.0 -50.0 0 0 0 0', '2 Fixed 100.0 0.0 -50.0 0 0 0 0'], &
                    [CHARACTER(16) :: '1 1 2 -'], [CHARACTER(24) :: '1 cab 100.0 40'], &
                    [CHARACTER(96) :: '1 A Rigid 1 0 0 Rigid 0 0 1 0', '1 B Rigid 1 0 0 Rigid 0 0 1 90'], &
                    [CHARACTER(24) :: '0.1 dtM', '0.0 TMax', '3 nModes'], OUTS)
    ! modal analysis of a line restrained in torsion carries the twist (test_modal_torsion)
    BLOCK
      LOGICAL :: ok_m
      CHARACTER(512) :: em_m, header
      INTEGER :: u_m, ios_m
      CALL run_deck('tdeck_e11.dat', 'tdeck_e11', ok_m, em_m)
      CALL require(ok_m, 'modal analysis with torsion runs (got: '//TRIM(em_m)//')')
      header = ''
      OPEN (NEWUNIT=u_m, FILE='tdeck_e11.modes.out', STATUS='OLD', ACTION='READ', IOSTAT=ios_m)
      IF (ios_m == 0) THEN
        READ (u_m, '(A)', IOSTAT=ios_m) header
        READ (u_m, '(A)', IOSTAT=ios_m) header
        READ (u_m, '(A)', IOSTAT=ios_m) header
        CLOSE (u_m)
      END IF
      CALL require(INDEX(header, 'PolarShare') > 0, 'the modes of a line with torsion carry the twist columns')
    END BLOCK
    ! coupled entries
    CALL write_deck('tdeck_e12.dat', [neutral_type], no_rows, &
                    [CHARACTER(48) :: '1 Coupled 0.0 0.0 -50.0 0 0 0 0', '2 Fixed 100.0 0.0 -50.0 0 0 0 0'], &
                    [CHARACTER(16) :: '1 1 2 -'], [CHARACTER(24) :: '1 cab 100.0 40'], &
                    [CHARACTER(96) :: '1 A Rigid 1 0 0 Rigid 0 0 1 0', '1 B Rigid 1 0 0 Rigid 0 0 1 90'], &
                    [CHARACTER(24) :: '0.1 dtM'], [CHARACTER(16) :: 'FairTen1'])
    ! a caller that does not pass the fairlead orientation (the C API) is refused by name; one
    ! that does (the OpenFAST and FAST.Farm shells, the standalone mixed route) builds the line
    ! with its torsion
    CALL CD_Init_Deck_Aggregate('tdeck_e12.dat', 0.1_wp, agg, es, em)
    CALL require(es /= CD_DECKDRV_OK .AND. INDEX(em, 'needs a host that turns its fairlead frame') > 0, &
                 'an aggregate caller without orientations refuses torsion by name (got: '//TRIM(em)//')')
    CALL CD_End_Deck_Aggregate(agg)
    CALL CD_Init_Deck_HermiteCable('tdeck_e12.dat', 0.1_wp, cab, node, es, em)
    CALL require(es /= CD_DECKDRV_OK .AND. INDEX(em, 'needs a host that turns its fairlead frame') > 0, &
                 'a single-cable caller without orientations refuses torsion by name (got: '//TRIM(em)//')')
    CALL CD_HFMF_End(cab)
    CALL CD_Init_Deck_Aggregate('tdeck_e12.dat', 0.1_wp, agg, es, em, host_orientation=.TRUE.)
    CALL require(es == CD_DECKDRV_OK, 'an orientation-passing host builds the coupled torsion line (got: '// &
                 TRIM(em)//')')
    CALL CD_End_Deck_Aggregate(agg)
    CALL CD_Init_Deck_HermiteCable('tdeck_e12.dat', 0.1_wp, cab, node, es, em, host_orientation=.TRUE.)
    CALL require(es == CD_DECKDRV_OK, 'an orientation-passing host builds the single coupled torsion cable '// &
                 '(got: '//TRIM(em)//')')
    CALL require(cab%line%torsion%active, 'the single coupled cable carries its torsion')
    CALL CD_HFMF_End(cab)
    ! a coupled run is always dynamic: the configuration blend is refused with torsion
    CALL write_deck('tdeck_e15.dat', [neutral_type], no_rows, &
                    [CHARACTER(48) :: '1 Coupled 0.0 0.0 -50.0 0 0 0 0', '2 Fixed 100.0 0.0 -50.0 0 0 0 0'], &
                    [CHARACTER(16) :: '1 1 2 -'], [CHARACTER(24) :: '1 cab 100.0 40'], &
                    [CHARACTER(96) :: '1 A Rigid 1 0 0 Rigid 0 0 1 0', '1 B Rigid 1 0 0 Rigid 0 0 1 90'], &
                    [CHARACTER(32) :: '0.1 dtM', 'False alpha_force_blend'], [CHARACTER(16) :: 'FairTen1'])
    CALL CD_Init_Deck_Aggregate('tdeck_e15.dat', 0.1_wp, agg, es, em, host_orientation=.TRUE.)
    CALL require(es /= CD_DECKDRV_OK .AND. INDEX(em, 'force-blended generalised-alpha') > 0, &
                 'the coupled aggregate refuses torsion with the configuration blend (got: '//TRIM(em)//')')
    CALL CD_End_Deck_Aggregate(agg)
    CALL CD_Init_Deck_HermiteCable('tdeck_e15.dat', 0.1_wp, cab, node, es, em, host_orientation=.TRUE.)
    CALL require(es /= CD_DECKDRV_OK .AND. INDEX(em, 'force-blended generalised-alpha') > 0, &
                 'the coupled single cable refuses torsion with the configuration blend (got: '//TRIM(em)//')')
    CALL CD_HFMF_End(cab)
    CALL check_scope_refusals()
    ! the channel units of the torsion channels, as the range files label them
    CALL require(TRIM(CD_Channel_Unit('Torq1N1')) == '(N.m)', 'Torq<L>N<J> unit is (N.m) (got '// &
                 TRIM(CD_Channel_Unit('Torq1N1'))//')')
    CALL require(TRIM(CD_Channel_Unit('Twist1N3')) == '(deg)', 'Twist<L>N<J> unit is (deg)')
    CALL require(TRIM(CD_Channel_Unit('Twist12')) == '(deg)', 'Twist<L> unit is (deg)')
  END SUBROUTINE check_errors

  SUBROUTINE write_lines(path, rows)
    CHARACTER(*), INTENT(IN) :: path, rows(:)
    INTEGER :: u, i
    OPEN (NEWUNIT=u, FILE=path, STATUS='REPLACE', ACTION='WRITE')
    DO i = 1, SIZE(rows)
      WRITE (u, '(A)') TRIM(rows(i))
    END DO
    CLOSE (u)
  END SUBROUTINE write_lines

  SUBROUTINE check_scope_refusals()
    !! 6 (continued). Torsion outside its scope stops by name: End A on a pinned rod (a Fixed rod
    !! end is supported, test_rod_end_torsion) and End A on a Point3 body; a torsional line
    !! carrying ATTACHMENTS solves (test_torsion_attachments).
    CHARACTER(120) :: tail(9), ty(4)
    ty(1) = '--- LINE TYPES ---'
    ty(2) = 'Name Diam Mass EA BA EI GAs GJ Irt Irn Cdn Cdt Can Cat'
    ty(3) = '(-) (m) (kg/m) (N) (-) (Nm2) (N) (Nm2) (kgm) (kgm) (-) (-) (-) (-)'
    ty(4) = 'cab 0.2 60.0 1.0e9 0.0 1.0e5 1.0e8 1.0e4 1.0 1.0 1.2 0.0 1.0 0.0'
    tail(1) = '--- SECTIONS ---'
    tail(2) = 'LineID LineType Length NumSegs'
    tail(3) = '(-) (-) (m) (-)'
    tail(4) = '1 cab 100.0 40'
    tail(5) = '--- OPTIONS ---'
    tail(6) = '0.1 dtM'
    tail(7) = '1.0 TMax'
    tail(8) = '--- OUTPUTS ---'
    tail(9) = '--- END ---'
    ! End A on a rod end
    CALL write_lines('tdeck_s1.dat', [CHARACTER(120) :: 'torsion scope', ty, '--- ROD TYPES ---', &
                                      'Name Diam Mass Cd Ca CdEnd CaEnd', '(-) (m) (kg/m) (-) (-) (-) (-)', &
                                      'arm 0.6 400.0 1.0 1.0 0.0 0.0', '--- RODS ---', &
                                      'ID RodType Attachment XA YA ZA XB YB ZB NumSegs Outputs', &
                                    '(-) (-) (-) (m) (m) (m) (m) (m) (m) (-) (-)', '1 arm Pinned 0 0 -40 0 0 -50 4 -', &
                          '--- POINTS ---', 'ID Type X Y Z Mass Vol CdA Ca', '(-) (-) (m) (m) (m) (kg) (m3) (m2) (-)', &
                      '2 Fixed 100.0 0.0 -50.0 0 0 0 0', '--- LINES ---', 'ID NodeA NodeB Outputs', '(-) (-) (-) (-)', &
                                      '1 R1B 2 -', tail(1:4), '--- END CONNECTIONS ---', &
                                      'LineID End Stiffness EzX EzY EzZ TorsStiffness NxX NxY NxZ Pretwist', &
                        '(-) (-) (N-m/rad) (-) (-) (-) (N-m/rad) (-) (-) (-) (deg)', '1 A Rigid 0 0 -1 Rigid 1 0 0 0', &
                                      '1 B Rigid 1 0 0 Rigid 0 0 1 0', tail(5:9)])
    CALL expect_error('a torsional end on a pinned rod is named', 'tdeck_s1.dat', 'tdeck_s1', &
                      'on the end of ROD 1 (pinned) is not supported')
    ! End A on a Point3 body
    CALL write_lines('tdeck_s2.dat', [CHARACTER(120) :: 'torsion scope', ty, '--- BODIES ---', &
                                      'ID Type X Y Z Roll Pitch Yaw Mass Vol C33 C44 C55 CdA Ca', &
                                      '(-) (-) (m) (m) (m) (deg) (deg) (deg) (kg) (m3) (N/m) (Nm) (Nm) (m2) (-)', &
                                      '1 Point3 0 0 -50 0 0 0 1000.0 1.0 0 0 0 0 0', &
                          '--- POINTS ---', 'ID Type X Y Z Mass Vol CdA Ca', '(-) (-) (m) (m) (m) (kg) (m3) (m2) (-)', &
                                      '1 Body1 0 0 0 0 0 0 0', '2 Fixed 100.0 0.0 -50.0 0 0 0 0', '--- LINES ---', &
                         'ID NodeA NodeB Outputs', '(-) (-) (-) (-)', '1 1 2 -', tail(1:4), '--- END CONNECTIONS ---', &
                                      'LineID End Stiffness EzX EzY EzZ TorsStiffness NxX NxY NxZ Pretwist', &
                        '(-) (-) (N-m/rad) (-) (-) (-) (N-m/rad) (-) (-) (-) (deg)', '1 A Pinned 1 0 0 Rigid 0 0 1 0', &
                                      '1 B Rigid 1 0 0 Rigid 0 0 1 0', tail(5:9)])
    CALL expect_error('a torsional end on a Point3 body is named', 'tdeck_s2.dat', 'tdeck_s2', 'needs a Rigid6 body')
    ! a torsional line with ATTACHMENTS
    CALL write_lines('tdeck_s3.dat', [CHARACTER(120) :: 'torsion scope', ty, '--- POINTS ---', &
                                      'ID Type X Y Z Mass Vol CdA Ca', '(-) (-) (m) (m) (m) (kg) (m3) (m2) (-)', &
                                '1 Coupled 0.0 0.0 -50.0 0 0 0 0', '2 Fixed 100.0 0.0 -50.0 0 0 0 0', '--- LINES ---', &
                             'ID NodeA NodeB Outputs', '(-) (-) (-) (-)', '1 1 2 -', tail(1:4), '--- ATTACHMENTS ---', &
                      'LineID ArcLength Mass Volume CdA Ca', '(-) (m) (kg) (m3) (m2) (-)', '1 50.0 100.0 0.1 0.1 1.0', &
                     '--- END CONNECTIONS ---', 'LineID End Stiffness EzX EzY EzZ TorsStiffness NxX NxY NxZ Pretwist', &
                         '(-) (-) (N-m/rad) (-) (-) (-) (N-m/rad) (-) (-) (-) (deg)', '1 A Rigid 1 0 0 Rigid 0 0 1 0', &
                                      '1 B Rigid 1 0 0 Rigid 0 0 1 0', tail(5:9)])
    BLOCK
      LOGICAL :: ok
      CHARACTER(512) :: em
      CALL run_deck('tdeck_s3.dat', 'tdeck_s3', ok, em)
      CALL require(ok, 'a torsional line with ATTACHMENTS solves (got: '//TRIM(em)//')')
    END BLOCK
  END SUBROUTINE check_scope_refusals

END PROGRAM test_torsion_deck
