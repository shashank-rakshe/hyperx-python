! File: tests/test_mixed_route_torsion.f90
! SPDX-License-Identifier: Apache-2.0
! Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
!> Torsion and prescribed motion on the standalone mixed route: a deck that mixes EI = 0 and
!> finite-EI lines without bodies, rods or Free/Connect points runs on the coupled aggregate,
!> marched by the standalone driver (the executable given as the first argument) through the
!> deck's motionFile or vesselMotion table.
!>  1. Vessel roll, pitch and heave from rest (vesselMotion) drive a sagging finite-EI line
!>     clamped (Rigid) at both ends and restrained in torsion (Pretwist 20 deg at End B), run
!>     alone on the standalone cubic-Hermite route and beside a moving EI = 0 chain on the mixed
!>     route. Torq, Twist and the mid-line node agree to the printed precision of the .out
!>     (8 digits), the fairlead and anchor tension, fairlead inclination and End A bend moment
!>     (the Rigid clamp turns with the vessel on both routes) to 5e-5 of their range: both step
!>     to the deck's Newton tolerance (1e-8), the coupled cables with a fresh factor every step,
!>     the standalone line with a carried factor. With the aggregate cables given the carried
!>     factor too the mixed route reproduces every channel of the standalone route to the
!>     printed precision. The same chain moved by a
!>     motionFile of the same point translations holds the frames: the End A bend moment and
!>     the twist then differ from the turning-vessel run (the rotation is not dropped).
!>  2. A motionFile surge with a roll column (End A rolls 20 deg about its director, from
!>     rest) gives the same agreement between the two routes.
!>  3. Quasi-static torsion of a straight neutral line on the mixed route, End A held, or rolled
!>     slowly about the line axis by a vessel or by the roll column: Twist1 = Pretwist - roll
!>     and Torq = GJ Twist / L at both ends at every step (1e-6 GJ).
!>  4. A non-zero roll column at the chain's point (no line restrained in torsion there) is
!>     refused by name on the mixed route.
!>  5. TMax = 0 with a motionFile whose first row is 2 cm off the deck fairlead: both routes write
!>     the t = 0 row at that installed row (the fairlead element takes the 2 cm against the
!>     static interior: FairTen 3.5 MN against 29 kN) and agree to the printed precision, and
!>     both write the .static.out of the static solve (fairlead x = 0) before it.
!>  6. Without the force blend a line restrained in torsion runs a static mixed deck (TMax = 0,
!>     no step) and its torque, as the single-line route, and a dynamic one stops by name; so
!>     does a line restrained at one end only (static: Torq/Twist channels, no torque at the
!>     free end), which the caller-driven parse must still resolve as a static run.
!>  7. ATTACHMENTS: the gate 2 line carrying three buoyancy modules (ATTACHMENTS, with drag and
!>     added mass), its torsion stage after the attachment polish on both routes, gives the gate 2
!>     agreement between the single-line route and the mixed route beside the chain.
!>  8. The gate 3 line between two moving points (End B on a Coupled point, its own aggregate
!>     column): the roll columns of both ends impose Phi = Pretwist(B) - Pretwist(A) - roll(A) -
!>     roll(B). Opposite rolls (a rigid roll of the line about its axis) keep Twist1 = 90 deg and
!>     equal rolls give 90 - 2 roll, with Torq = GJ Twist / L at both ends (1e-6 GJ); the same
!>     with End B's point listed first in POINTS (the moving columns follow the cables, End A
!>     columns then End B columns, not the POINTS order). Fails if the roll of a two-moving-end
!>     cable is dropped or an end's motion is read from another moving column.
!>  9. Run alone (second argument "turbines", ctest mixed_route_turbines): a TURBINES deck (two
!>     turbines, PtfmInit offsets and yaws, per-turbine motionFile records of heave and roll from
!>     rest) with a finite-EI cable between the turbines, clamped (Rigid) and restrained in torsion
!>     at both ends, and an EI = 0 chain from each turbine to an anchor. The driver runs it on the
!>     mixed route (it used to stop for want of a farm context) and the deck's cable alone on the
!>     standalone cubic-Hermite route and its chains alone on the standalone EI = 0 route, both of
!>     which consume the TURBINES rows. The chains' tensions agree to LOAD_TOL of their range; the
!>     cable's channels agree to the coupled cable's Newton controls (relative tolerance 5e-3; the
!>     standalone route given those controls writes the mixed run's cable byte for byte, about 1e-2
!>     of the range from its own). The aggregate library marched with the standalone controls, as
!>     in gate 1, reproduces the cable-only run's cable channels to the printed precision. Each
!>     turbine's yaw and roll turn the clamped end on it (End A on turbine 1, End B on turbine 2),
!>     so the end bend moments and the torque carry each end's own turbine. The torsion note of
!>     the cable-only run gives the line's total twist (Twist1 at t = 0, to 1e-5 of it), which the
!>     turbines' PtfmInit yaws turn away from the 30 deg Pretwist(B) - Pretwist(A) it also names.
PROGRAM test_mixed_route_torsion
  USE CableDyn_Precision, ONLY: wp
  USE CableDyn_OpenFAST_Aggregate, ONLY: CD_AGG_ModuleType, CD_AGG_Init_From_Deck, CD_AGG_NMovingPoints, &
                                         CD_AGG_GetMovingPointMesh, CD_AGG_UpdateStates_Moving, &
                                         CD_AGG_Step_Moving, CD_AGG_CalcOutput, CD_AGG_EvalChannel, &
                                         CD_AGG_NumChannels, CD_AGG_End, CD_AGG_MotionKinematics, &
                                         CD_AGG_Refresh_Accelerations, CD_AGG_HasMotion, CD_AGG_OK
  USE, INTRINSIC :: IEEE_ARITHMETIC, ONLY: IEEE_IS_FINITE
  IMPLICIT NONE

  REAL(wp), PARAMETER :: PI = 3.14159265358979323846_wp, D2R = PI/180.0_wp, RHOW = 1025.0_wp
  REAL(wp), PARAMETER :: DT = 0.05_wp, TMAX = 10.0_wp, PERIOD = 10.0_wp
  INTEGER, PARAMETER :: NSTEP = 200, MAXCOL = 32, MAXROW = 400
  ! gate 3: End A held, rolled by a vessel, rolled by the motionFile roll column
  INTEGER, PARAMETER :: QS_HELD = 0, QS_VESSEL = 1, QS_ROLL = 2
  CHARACTER(*), PARAMETER :: CAB_T = 'cab 0.2 60.0 4.0e8 0.0 1.0e4 1.0e8 1.0e4 1.0 1.0e-12 1.2 0.1 1.0 0.0'
  CHARACTER(*), PARAMETER :: CHAIN_T = 'chain 0.1 50.0 1.0e9 -1.0 0.0 0 0 0 0 1.37 0.64 1.0 0.0'
  ! channels compared to the printed precision, the loads to LOAD_TOL of their range, the
  ! out-of-plane node offset (about 1e-4 m) to POS_TOL
  CHARACTER(16), PARAMETER :: EXACT(5) = [CHARACTER(16) :: 'Torq1N1', 'Torq1N41', 'Twist1', 'L1N21px', 'L1N21pz']
  CHARACTER(16), PARAMETER :: LOADS(4) = [CHARACTER(16) :: 'FairTen1', 'AnchTen1', 'FairIncl1', 'BendMom1N1']
  ! the gate 1 and 2 channels of line 1 (the same in both decks) and the chain's
  CHARACTER(16), PARAMETER :: OUTS(10) = [LOADS, EXACT(1:3), [CHARACTER(16) :: 'L1N21px', 'L1N21py', 'L1N21pz']]
  CHARACTER(16), PARAMETER :: CHAIN_OUTS(2) = [CHARACTER(16) :: 'FairTen2', 'Point3pz']
  ! gate 9: the cable's end loads and bend moments (compared to LOAD_TOL), its torque, twist and
  ! mid node (to TURB_TOL), and the chains' tensions (to LOAD_TOL)
  CHARACTER(16), PARAMETER :: TURB_LOADS(4) = [CHARACTER(16) :: 'FairTen1', 'AnchTen1', 'BendMom1N1', 'BendMom1N41']
  CHARACTER(16), PARAMETER :: TURB_TWIST(4) = [CHARACTER(16) :: 'Torq1N1', 'Twist1', 'L1N21py', 'L1N21pz']
  CHARACTER(16), PARAMETER :: TURB_CABLE(8) = [TURB_LOADS, TURB_TWIST]
  CHARACTER(16), PARAMETER :: TURB_CHAINS(4) = [CHARACTER(16) :: 'FairTen2', 'AnchTen2', 'FairTen3', 'AnchTen3']
  ! gate 9: the driver's mixed run against the cable-only run (the coupled cable's Newton controls)
  REAL(wp), PARAMETER :: TURB_TOL = 5.0e-2_wp
  REAL(wp), PARAMETER :: LOAD_TOL = 5.0e-5_wp, POS_TOL = 1.0e-6_wp
  ! printed precision of ES15.7E3: half a unit in the 8th significant digit of each value, with a
  ! unit of the 8th digit of the channel's range for a value that crosses zero
  REAL(wp), PARAMETER :: PRINT_TOL = 6.0e-8_wp, PRINT_FLOOR = 1.0e-7_wp
  CHARACTER(1024) :: driver
  ! the run's gates: 1-8, or with the second argument "turbines" gate 9 alone
  CHARACTER(16) :: mode
  LOGICAL :: turbines_only
  CHARACTER(160) :: neutral_t
  INTEGER :: n_fail = 0

  IF (COMMAND_ARGUMENT_COUNT() < 1) ERROR STOP 'usage: test_mixed_route_torsion <CableDyn_driver executable>'
  CALL GET_COMMAND_ARGUMENT(1, driver)
  ! "turbines": gate 9 alone (its own ctest entry, mixed_route_turbines); the other gates otherwise
  turbines_only = .FALSE.
  IF (COMMAND_ARGUMENT_COUNT() >= 2) THEN
    CALL GET_COMMAND_ARGUMENT(2, mode)
    turbines_only = TRIM(mode) == 'turbines'
  END IF
  ! neutral 0.2 m section of test_torsion_deck: EA 1e7, EI 1e6, GAs 1e8, GJ 5e4, Irn 1e-12
  WRITE (neutral_t, '(A,ES24.16,A)') 'cab 0.2 ', RHOW*0.25_wp*PI*0.04_wp, &
    ' 1.0e7 0.0 1.0e6 1.0e8 5.0e4 1.0 1.0e-12 0.0 0.0 0.0 0.0'

  IF (turbines_only) THEN
    CALL check_turbines()
    IF (n_fail > 0) THEN
      WRITE (*, '(A,I0,A)') 'FAIL: ', n_fail, ' mixed-route TURBINES gate(s) failed'
      ERROR STOP 1
    END IF
    WRITE (*, '(A)') 'PASS: the standalone TURBINES deck of EI = 0 and finite-EI lines on the mixed route'
    STOP
  END IF
  CALL check_vessel_routes()
  CALL check_roll_routes()
  CALL check_quasi_static(QS_HELD)
  CALL check_quasi_static(QS_VESSEL)
  CALL check_quasi_static(QS_ROLL)
  CALL check_refusal()
  CALL check_static_row1()
  CALL check_static_blend()
  CALL check_attachment_routes()
  CALL check_two_moving_roll(-1.0_wp)
  CALL check_two_moving_roll(1.0_wp)
  CALL check_two_moving_roll(1.0_wp, b_first=.TRUE.)
  IF (n_fail > 0) THEN
    WRITE (*, '(A,I0,A)') 'FAIL: ', n_fail, ' mixed-route torsion gate(s) failed'
    ERROR STOP 1
  END IF
  WRITE (*, '(A)') 'PASS: torsion and prescribed motion on the standalone mixed route'

CONTAINS

  SUBROUTINE require(cond, msg)
    LOGICAL, INTENT(IN) :: cond
    CHARACTER(*), INTENT(IN) :: msg
    IF (.NOT. cond) THEN
      n_fail = n_fail + 1
      WRITE (*, '(A,A)') 'FAILED: ', msg
    END IF
  END SUBROUTINE require

  SUBROUTINE write_deck(path, types, points, lines, sections, endconns, options, outs, atts, turbs)
    CHARACTER(*), INTENT(IN) :: path, types(:), points(:), lines(:), sections(:), endconns(:), options(:), outs(:)
    ! ATTACHMENTS rows (none when absent)
    CHARACTER(*), INTENT(IN), OPTIONAL :: atts(:)
    ! TURBINES rows (none when absent)
    CHARACTER(*), INTENT(IN), OPTIONAL :: turbs(:)
    INTEGER :: u, i
    OPEN (NEWUNIT=u, FILE=path, STATUS='REPLACE', ACTION='WRITE')
    WRITE (u, '(A)') 'mixed-route torsion gate'
    WRITE (u, '(A)') '--- LINE TYPES ---'
    WRITE (u, '(A)') 'Name Diam Mass EA BA EI GAs GJ Irt Irn Cdn Cdt Can Cat'
    WRITE (u, '(A)') '(-) (m) (kg/m) (N) (-) (Nm2) (N) (Nm2) (kgm) (kgm) (-) (-) (-) (-)'
    DO i = 1, SIZE(types)
      WRITE (u, '(A)') TRIM(types(i))
    END DO
    WRITE (u, '(A)') '--- POINTS ---'
    WRITE (u, '(A)') 'ID Type X Y Z Mass Vol CdA Ca'
    WRITE (u, '(A)') '(-) (-) (m) (m) (m) (kg) (m3) (m2) (-)'
    DO i = 1, SIZE(points)
      WRITE (u, '(A)') TRIM(points(i))
    END DO
    IF (PRESENT(turbs)) THEN
      WRITE (u, '(A)') '--- TURBINES ---'
      WRITE (u, '(A)') 'J X0 Y0 Z0 PtfmSurge PtfmSway PtfmHeave PtfmRoll PtfmPitch PtfmYaw'
      DO i = 1, SIZE(turbs)
        WRITE (u, '(A)') TRIM(turbs(i))
      END DO
    END IF
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

  SUBROUTINE sag_deck(path, point_type, chain, options, tmax_row, atts)
    !! Gates 1 and 2: a 100 m finite-EI line from End A (0, 0, -50) on a point_type point to a
    !! Fixed End B (95, 0, -60), 40 elements, both ends Rigid in bending and in torsion
    !! (Pretwist 20 deg at End B); with chain, an EI = 0 chain from (0, 20, -50) on a second
    !! point_type point to a Fixed (0, 110, -100); atts: ATTACHMENTS rows of line 1.
    CHARACTER(*), INTENT(IN) :: path, point_type, options(:)
    LOGICAL, INTENT(IN) :: chain
    ! the TMax row (default 10 s)
    CHARACTER(*), INTENT(IN), OPTIONAL :: tmax_row
    CHARACTER(*), INTENT(IN), OPTIONAL :: atts(:)
    CHARACTER(48) :: points(4), tm
    CHARACTER(96) :: ec(2)
    ec(1) = '1 A Rigid 1 0 -0.1 Rigid 0 0 1 0'
    ec(2) = '1 B Rigid 1 0 0.1 Rigid 0 0 1 20'
    tm = '10.0 TMax'
    IF (PRESENT(tmax_row)) tm = tmax_row
    points(1) = '1 '//point_type//' 0.0 0.0 -50.0 0 0 0 0'
    points(2) = '2 Fixed 95.0 0.0 -60.0 0 0 0 0'
    points(3) = '3 '//point_type//' 0.0 20.0 -50.0 0 0 0 0'
    points(4) = '4 Fixed 0.0 110.0 -100.0 0 0 0 0'
    IF (PRESENT(atts)) THEN
      IF (chain) THEN
        CALL write_deck(path, [CHARACTER(96) :: CAB_T, CHAIN_T], points, [CHARACTER(16) :: '1 1 2 -', '2 3 4 -'], &
                        [CHARACTER(24) :: '1 cab 100.0 40', '2 chain 110.0 20'], EC, &
                        [CHARACTER(48) :: '200.0 WtrDpth', '0.05 dtM', tm, options], [OUTS, CHAIN_OUTS], atts)
      ELSE
        CALL write_deck(path, [CHARACTER(96) :: CAB_T], points(1:2), [CHARACTER(16) :: '1 1 2 -'], &
                        [CHARACTER(24) :: '1 cab 100.0 40'], EC, &
                        [CHARACTER(48) :: '200.0 WtrDpth', '0.05 dtM', tm, options], OUTS, atts)
      END IF
    ELSE IF (chain) THEN
      CALL write_deck(path, [CHARACTER(96) :: CAB_T, CHAIN_T], points, [CHARACTER(16) :: '1 1 2 -', '2 3 4 -'], &
                      [CHARACTER(24) :: '1 cab 100.0 40', '2 chain 110.0 20'], EC, &
                      [CHARACTER(48) :: '200.0 WtrDpth', '0.05 dtM', tm, options], [OUTS, CHAIN_OUTS])
    ELSE
      CALL write_deck(path, [CHARACTER(96) :: CAB_T], points(1:2), [CHARACTER(16) :: '1 1 2 -'], &
                      [CHARACTER(24) :: '1 cab 100.0 40'], EC, &
                      [CHARACTER(48) :: '200.0 WtrDpth', '0.05 dtM', tm, options], OUTS)
    END IF
  END SUBROUTINE sag_deck

  PURE SUBROUTINE smooth(amplitude, t, f, df, d2f)
    !! f = F (1 - cos w t) / 2 and its rates, w = 2 pi / PERIOD: a motion from rest.
    REAL(wp), INTENT(IN) :: amplitude, t
    REAL(wp), INTENT(OUT) :: f, df, d2f
    REAL(wp) :: w
    w = 2.0_wp*PI/PERIOD
    f = 0.5_wp*amplitude*(1.0_wp - COS(w*t))
    df = 0.5_wp*amplitude*w*SIN(w*t)
    d2f = 0.5_wp*amplitude*w*w*COS(w*t)
  END SUBROUTINE smooth

  SUBROUTINE vessel_state(t, r, v, a, rot, omega, alpha)
    !! The gate 1 vessel about its reference (0, 0, -50): heave 1 m, roll 20 deg and pitch 4 deg
    !! from rest, R = Ry(pitch) Rx(roll); the global angular velocity of these Euler rates is
    !! omega = Ry(pitch) (roll', 0, 0) + (0, pitch', 0), alpha its derivative.
    REAL(wp), INTENT(IN) :: t
    REAL(wp), INTENT(OUT) :: r(3), v(3), a(3), rot(3, 3), omega(3), alpha(3)
    REAL(wp) :: z, vz, az, ro, dro, d2ro, p, dp, d2p, cr, sr, cp, sp
    CALL smooth(1.0_wp, t, z, vz, az)
    CALL smooth(20.0_wp*D2R, t, ro, dro, d2ro)
    CALL smooth(4.0_wp*D2R, t, p, dp, d2p)
    r = [0.0_wp, 0.0_wp, -50.0_wp + z]
    v = [0.0_wp, 0.0_wp, vz]
    a = [0.0_wp, 0.0_wp, az]
    cr = COS(ro); sr = SIN(ro); cp = COS(p); sp = SIN(p)
    ! rot = Ry(p) Rx(ro), columns
    rot(:, 1) = [cp, 0.0_wp, -sp]
    rot(:, 2) = [sp*sr, cr, cp*sr]
    rot(:, 3) = [sp*cr, -sr, cp*cr]
    omega = [dro*cp, dp, -dro*sp]
    alpha = [d2ro*cp - dro*dp*sp, d2p, -d2ro*sp - dro*dp*cp]
  END SUBROUTINE vessel_state

  FUNCTION cross(x, y) RESULT(c)
    REAL(wp), INTENT(IN) :: x(3), y(3)
    REAL(wp) :: c(3)
    c = [x(2)*y(3) - x(3)*y(2), x(3)*y(1) - x(1)*y(3), x(1)*y(2) - x(2)*y(1)]
  END FUNCTION cross

  SUBROUTINE write_vessel_record(path)
    !! The gate 1 vessel as a vesselMotion record (time x y z roll pitch yaw vx vy vz wx wy wz ax ay
    !! az alx aly alz).
    CHARACTER(*), INTENT(IN) :: path
    REAL(wp) :: t, r(3), v(3), a(3), rot(3, 3), omega(3), alpha(3), ro, dro, d2ro, p, dp, d2p
    INTEGER :: u, k
    OPEN (NEWUNIT=u, FILE=path, STATUS='REPLACE', ACTION='WRITE')
    DO k = 0, NSTEP
      t = DT*k
      CALL vessel_state(t, r, v, a, rot, omega, alpha)
      CALL smooth(20.0_wp, t, ro, dro, d2ro)
      CALL smooth(4.0_wp, t, p, dp, d2p)
      WRITE (u, '(F8.3,18ES25.16E3)') t, r, ro, p, 0.0_wp, v, omega, a, alpha
    END DO
    CLOSE (u)
  END SUBROUTINE write_vessel_record

  SUBROUTINE write_vessel_points(path)
    !! The translations the gate 1 vessel gives points 1 and 3 (x = r + R p, v = v_r + w x R p,
    !! a = a_r + al x R p + w x (w x R p)) as motionFile rows without a roll column.
    CHARACTER(*), INTENT(IN) :: path
    REAL(wp) :: t, r(3), v(3), a(3), rot(3, 3), omega(3), alpha(3), rp(3)
    REAL(wp), PARAMETER :: P_LOCAL(3, 2) = RESHAPE([0.0_wp, 0.0_wp, 0.0_wp, 0.0_wp, 20.0_wp, 0.0_wp], [3, 2])
    INTEGER :: u, k, j
    OPEN (NEWUNIT=u, FILE=path, STATUS='REPLACE', ACTION='WRITE')
    DO k = 0, NSTEP
      t = DT*k
      CALL vessel_state(t, r, v, a, rot, omega, alpha)
      DO j = 1, 2
        rp = MATMUL(rot, P_LOCAL(:, j))
        WRITE (u, '(F8.3,I3,9ES25.16E3)') t, 2*j - 1, r + rp, v + cross(omega, rp), &
          a + cross(alpha, rp) + cross(omega, cross(omega, rp))
      END DO
    END DO
    CLOSE (u)
  END SUBROUTINE write_vessel_points

  SUBROUTINE write_roll_rows(path, with_chain_point)
    !! Gate 2 motionFile: point 1 surges 1 m and rolls 20 deg (roll column), from rest; point 3
    !! (with_chain_point) surges with it and gives no roll column.
    CHARACTER(*), INTENT(IN) :: path
    LOGICAL, INTENT(IN) :: with_chain_point
    REAL(wp) :: t, x, vx, ax, ro, dro, d2ro
    INTEGER :: u, k
    OPEN (NEWUNIT=u, FILE=path, STATUS='REPLACE', ACTION='WRITE')
    DO k = 0, NSTEP
      t = DT*k
      CALL smooth(1.0_wp, t, x, vx, ax)
      CALL smooth(20.0_wp, t, ro, dro, d2ro)
      WRITE (u, '(F8.3,A,ES25.16E3,A,ES25.16E3,A,ES25.16E3,A,ES25.16E3)') t, ' 1 ', x, ' 0 -50 ', vx, ' 0 0 ', ax, &
        ' 0 0 ', ro
      IF (with_chain_point) WRITE (u, '(F8.3,A,ES25.16E3,A,ES25.16E3,A,ES25.16E3,A)') t, ' 3 ', x, ' 20 -50 ', vx, &
        ' 0 0 ', ax, ' 0 0'
    END DO
    CLOSE (u)
  END SUBROUTINE write_roll_rows

  SUBROUTINE run_driver(deck, root, ok)
    !! Run the driver executable on a deck, its stdout and stderr to <root>.log.
    CHARACTER(*), INTENT(IN) :: deck, root
    LOGICAL, INTENT(OUT) :: ok
    INTEGER :: ex, cs
    CALL EXECUTE_COMMAND_LINE('"'//TRIM(driver)//'" '//deck//' '//root//' > '//root//'.log 2>&1', &
                              WAIT=.TRUE., EXITSTAT=ex, CMDSTAT=cs)
    ok = cs == 0 .AND. ex == 0
  END SUBROUTINE run_driver

  LOGICAL FUNCTION log_has(root, text) RESULT(found)
    CHARACTER(*), INTENT(IN) :: root, text
    CHARACTER(4096) :: line
    INTEGER :: u, ios
    found = .FALSE.
    OPEN (NEWUNIT=u, FILE=root//'.log', STATUS='OLD', ACTION='READ', IOSTAT=ios)
    IF (ios /= 0) RETURN
    DO
      READ (u, '(A)', IOSTAT=ios) line
      IF (ios /= 0) EXIT
      IF (INDEX(line, text) > 0) found = .TRUE.
    END DO
    CLOSE (u)
  END FUNCTION log_has

  REAL(wp) FUNCTION log_value(root, needle) RESULT(v)
    !! The number after needle on the first line of <root>.log that carries it (HUGE when none).
    CHARACTER(*), INTENT(IN) :: root, needle
    CHARACTER(4096) :: line
    INTEGER :: u, ios, k
    v = HUGE(1.0_wp)
    OPEN (NEWUNIT=u, FILE=root//'.log', STATUS='OLD', ACTION='READ', IOSTAT=ios)
    IF (ios /= 0) RETURN
    DO
      READ (u, '(A)', IOSTAT=ios) line
      IF (ios /= 0) EXIT
      k = INDEX(line, needle)
      IF (k > 0) THEN
        READ (line(k + LEN(needle):), *, IOSTAT=ios) v
        IF (ios /= 0) v = HUGE(1.0_wp)
        EXIT
      END IF
    END DO
    CLOSE (u)
  END FUNCTION log_value

  SUBROUTINE read_out(path, names, vals, nrow)
    !! The channel names and rows of a driver .out file (Time first).
    CHARACTER(*), INTENT(IN) :: path
    CHARACTER(32), INTENT(OUT) :: names(MAXCOL)
    REAL(wp), INTENT(OUT) :: vals(MAXROW, MAXCOL)
    INTEGER, INTENT(OUT) :: nrow
    CHARACTER(4096) :: buf
    INTEGER :: u, ios, ncol, k
    names = ''
    vals = 0.0_wp
    nrow = 0
    OPEN (NEWUNIT=u, FILE=path, STATUS='OLD', ACTION='READ', IOSTAT=ios)
    IF (ios /= 0) RETURN
    READ (u, '(A)', IOSTAT=ios) buf
    READ (u, '(A)', IOSTAT=ios) buf
    READ (buf, *, IOSTAT=ios) names
    ncol = 0
    DO k = 1, MAXCOL
      IF (LEN_TRIM(names(k)) > 0) ncol = k
    END DO
    DO
      IF (nrow == MAXROW) EXIT
      READ (u, *, IOSTAT=ios) vals(nrow + 1, 1:ncol)
      IF (ios /= 0) EXIT
      nrow = nrow + 1
    END DO
    CLOSE (u)
  END SUBROUTINE read_out

  INTEGER FUNCTION col_of(names, name) RESULT(c)
    CHARACTER(32), INTENT(IN) :: names(:)
    CHARACTER(*), INTENT(IN) :: name
    INTEGER :: k
    c = 0
    DO k = 1, SIZE(names)
      IF (TRIM(names(k)) == TRIM(name)) c = k
    END DO
  END FUNCTION col_of

  REAL(wp) FUNCTION range_error(a, b, n) RESULT(e)
    !! max |b - a| over the rows, relative to the range max |a|.
    REAL(wp), INTENT(IN) :: a(:), b(:)
    INTEGER, INTENT(IN) :: n
    e = MAXVAL(ABS(b(1:n) - a(1:n)))/MAX(MAXVAL(ABS(a(1:n))), TINY(1.0_wp))
    IF (.NOT. IEEE_IS_FINITE(e)) e = HUGE(1.0_wp)
  END FUNCTION range_error

  REAL(wp) FUNCTION print_error(a, b, n) RESULT(e)
    !! max over the rows of |b - a| in units of the printed precision of a (PRINT_TOL |a|, at least
    !! PRINT_FLOOR of the channel's range): <= 1 when b equals a to the digits printed.
    REAL(wp), INTENT(IN) :: a(:), b(:)
    INTEGER, INTENT(IN) :: n
    REAL(wp) :: scale
    INTEGER :: k
    scale = MAXVAL(ABS(a(1:n)))
    e = 0.0_wp
    DO k = 1, n
      e = MAX(e, ABS(b(k) - a(k))/MAX(PRINT_TOL*ABS(a(k)), PRINT_FLOOR*scale, TINY(1.0_wp)))
    END DO
    IF (.NOT. IEEE_IS_FINITE(e)) e = HUGE(1.0_wp)
  END FUNCTION print_error

  SUBROUTINE compare_routes(label, root_a, root_b)
    !! Gate 1/2 comparison of the standalone cubic-Hermite route (root_a.out) and the mixed route
    !! (root_b.out) over the channels of line 1.
    CHARACTER(*), INTENT(IN) :: label, root_a, root_b
    CHARACTER(32) :: na(MAXCOL), nb(MAXCOL)
    REAL(wp), ALLOCATABLE :: va(:, :), vb(:, :)
    INTEGER :: ra, rb, k, ca, cb
    REAL(wp) :: e, e_exact, e_loads
    ALLOCATE (va(MAXROW, MAXCOL), vb(MAXROW, MAXCOL))
    CALL read_out(root_a//'.out', na, va, ra)
    CALL read_out(root_b//'.out', nb, vb, rb)
    CALL require(ra == NSTEP + 1 .AND. rb == NSTEP + 1, label//': both routes write every row')
    IF (ra /= NSTEP + 1 .OR. rb /= NSTEP + 1) RETURN
    e_exact = 0.0_wp
    DO k = 1, SIZE(EXACT)
      ca = col_of(na, EXACT(k))
      cb = col_of(nb, EXACT(k))
      CALL require(ca > 0 .AND. cb > 0, label//': channel '//TRIM(EXACT(k))//' in both outputs')
      IF (ca == 0 .OR. cb == 0) CYCLE
      e = print_error(va(:, ca), vb(:, cb), ra)
      WRITE (*, '(A,A,A,ES10.3,A)') '  ', label, ': '//TRIM(EXACT(k))//' difference ', e, ' printed units'
      e_exact = MAX(e_exact, e)
    END DO
    e_loads = 0.0_wp
    DO k = 1, SIZE(LOADS)
      ca = col_of(na, LOADS(k))
      cb = col_of(nb, LOADS(k))
      CALL require(ca > 0 .AND. cb > 0, label//': channel '//TRIM(LOADS(k))//' in both outputs')
      IF (ca == 0 .OR. cb == 0) CYCLE
      e = range_error(va(:, ca), vb(:, cb), ra)
      WRITE (*, '(A,A,A,ES10.3,A)') '  ', label, ': '//TRIM(LOADS(k))//' difference ', e, ' of its range'
      e_loads = MAX(e_loads, e)
    END DO
    ca = col_of(na, 'L1N21py')
    cb = col_of(nb, 'L1N21py')
    e = HUGE(1.0_wp)
    IF (ca > 0 .AND. cb > 0) e = MAXVAL(ABS(vb(1:ra, cb) - va(1:ra, ca)))
    WRITE (*, '(A,A,A,ES10.3,A)') '  ', label, ': L1N21py difference ', e, ' m'
    CALL require(e_exact <= 2.0_wp, label//': torque, twist and node positions agree to the printed precision')
    CALL require(e_loads <= LOAD_TOL, label//': end loads and bend moment agree within the Newton tolerances')
    CALL require(e <= POS_TOL, label//': the out-of-plane node offset agrees within the Newton tolerances')
  END SUBROUTINE compare_routes

  SUBROUTINE march_library(deck, root_a, label)
    !! The mixed route's march (CableDyn_driver run_mixed_held_deck) through the aggregate library
    !! with every cable given the standalone route's Newton controls (the deck's dynamic tolerance
    !! 1e-8, 30 iterations, the carried factor): each channel of line 1 is compared at every
    !! step with the standalone route's output root_a.out to its printed precision.
    CHARACTER(*), INTENT(IN) :: deck, root_a, label
    TYPE(CD_AGG_ModuleType), ALLOCATABLE :: agg
    REAL(wp), ALLOCATABLE :: pos(:, :), vel(:, :), acc(:, :), load(:, :), orient(:, :, :), omega(:, :), alpha(:, :)
    REAL(wp), ALLOCATABLE :: roll(:), va(:, :), got(:, :)
    CHARACTER(32) :: na(MAXCOL)
    CHARACTER(2048) :: em
    INTEGER :: es, n, c, step, ra, k, ca, nch, n_iter
    LOGICAL :: turns, rolls, conv, stalled
    REAL(wp) :: worst, v
    ALLOCATE (agg, va(MAXROW, MAXCOL))
    CALL CD_AGG_Init_From_Deck(agg, deck, DT, es, em, forbid_deck_ambient=.TRUE., run_tmax=TMAX, &
                               host_orientation=.TRUE., prescribed_motion=.TRUE.)
    CALL require(es == CD_AGG_OK .AND. CD_AGG_HasMotion(agg), label//': the aggregate takes the deck motion: '// &
                 TRIM(em))
    IF (es /= CD_AGG_OK) RETURN
    DO c = 1, agg%ncable
      agg%cables(c)%tol = 1.0e-8_wp
      agg%cables(c)%max_iter = 30
      agg%cables(c)%line%tangent_reuse = .TRUE.
    END DO
    n = CD_AGG_NMovingPoints(agg, es, em)
    nch = CD_AGG_NumChannels(agg)
    ALLOCATE (pos(3, n), vel(3, n), acc(3, n), load(3, n), orient(3, 3, n), omega(3, n), alpha(3, n), roll(n), &
              got(NSTEP + 1, nch))
    CALL CD_AGG_GetMovingPointMesh(agg, pos, vel, acc, load, es, em)
    CALL CD_AGG_MotionKinematics(agg, 1, pos, vel, acc, orient, omega, alpha, roll, turns, rolls, es, em)
    IF (turns) THEN
      CALL CD_AGG_UpdateStates_Moving(agg, pos, vel, acc, es, em, orientation=orient, angular_velocity=omega, &
                                      angular_acceleration=alpha)
    ELSE
      CALL CD_AGG_UpdateStates_Moving(agg, pos, vel, acc, es, em)
    END IF
    IF (es == CD_AGG_OK) CALL CD_AGG_Refresh_Accelerations(agg, es, em)
    CALL require(es == CD_AGG_OK, label//': the first motion row installs: '//TRIM(em))
    DO step = 0, NSTEP
      IF (step > 0) THEN
        CALL CD_AGG_MotionKinematics(agg, step + 1, pos, vel, acc, orient, omega, alpha, roll, turns, rolls, es, em)
        IF (turns) THEN
          CALL CD_AGG_Step_Moving(agg, DT, pos, vel, acc, conv, stalled, n_iter, es, em, t_committed=DT*step, &
                                  orientation=orient, angular_velocity=omega, angular_acceleration=alpha)
        ELSE IF (rolls) THEN
          CALL CD_AGG_Step_Moving(agg, DT, pos, vel, acc, conv, stalled, n_iter, es, em, t_committed=DT*step, &
                                  roll=roll)
        ELSE
          CALL CD_AGG_Step_Moving(agg, DT, pos, vel, acc, conv, stalled, n_iter, es, em, t_committed=DT*step)
        END IF
        IF (es /= CD_AGG_OK .OR. .NOT. conv) THEN
          CALL require(.FALSE., label//': library march step: '//TRIM(em))
          EXIT
        END IF
      END IF
      CALL CD_AGG_CalcOutput(agg, es, em)
      DO k = 1, nch
        CALL CD_AGG_EvalChannel(agg, k, v, es, em)
        got(step + 1, k) = v
      END DO
    END DO
    CALL read_out(root_a//'.out', na, va, ra)
    worst = 0.0_wp
    IF (ra == NSTEP + 1) THEN
      DO k = 1, SIZE(OUTS)
        ca = col_of(na, OUTS(k))
        IF (ca > 0) worst = MAX(worst, print_error(va(:, ca), got(:, k), ra))
      END DO
    ELSE
      worst = HUGE(1.0_wp)
    END IF
    WRITE (*, '(A,A,A,ES10.3,A)') '  ', label, ': mixed route with the standalone Newton controls, largest '// &
      'difference ', worst, ' printed units'
    CALL require(worst <= 2.0_wp, label//': with the same Newton controls the mixed route reproduces the '// &
                 'standalone route')
    CALL CD_AGG_End(agg, es, em)
  END SUBROUTINE march_library

  SUBROUTINE check_vessel_routes()
    !! Gate 1.
    CHARACTER(32) :: nb(MAXCOL), nc(MAXCOL)
    REAL(wp), ALLOCATABLE :: vb(:, :), vc(:, :)
    INTEGER :: rb, rc
    LOGICAL :: ok
    REAL(wp) :: dm, dt_twist
    CHARACTER(48), PARAMETER :: VM(2) = [CHARACTER(48) :: 'tmrt_vessel.txt vesselMotion', '0|0|-50 vesselRef']
    CALL write_vessel_record('tmrt_vessel.txt')
    CALL sag_deck('tmrt_vessel_a.dat', 'Vessel', .FALSE., VM)
    CALL sag_deck('tmrt_vessel_b.dat', 'Vessel', .TRUE., VM)
    CALL run_driver('tmrt_vessel_a.dat', 'tmrt_vessel_a', ok)
    CALL require(ok, '1: the vessel deck runs on the standalone cubic-Hermite route')
    CALL run_driver('tmrt_vessel_b.dat', 'tmrt_vessel_b', ok)
    CALL require(ok, '1: the mixed vessel deck with a line restrained in torsion runs')
    CALL require(log_has('tmrt_vessel_b', 'mixed standalone aggregate'), '1: the mixed deck runs on the aggregate')
    CALL compare_routes('1 vessel', 'tmrt_vessel_a', 'tmrt_vessel_b')
    CALL march_library('tmrt_vessel_b.dat', 'tmrt_vessel_a', '1 vessel')
    ! the same point translations as a motionFile: the frames are held
    CALL write_vessel_points('tmrt_vessel_points.txt')
    CALL sag_deck('tmrt_vessel_c.dat', 'Coupled', .TRUE., [CHARACTER(48) :: 'tmrt_vessel_points.txt motionFile'])
    CALL run_driver('tmrt_vessel_c.dat', 'tmrt_vessel_c', ok)
    CALL require(ok, '1: the mixed deck of the vessel point translations runs')
    ALLOCATE (vb(MAXROW, MAXCOL), vc(MAXROW, MAXCOL))
    CALL read_out('tmrt_vessel_b.out', nb, vb, rb)
    CALL read_out('tmrt_vessel_c.out', nc, vc, rc)
    IF (rb == NSTEP + 1 .AND. rc == NSTEP + 1) THEN
      dm = range_error(vb(:, col_of(nb, 'BendMom1N1')), vc(:, col_of(nc, 'BendMom1N1')), rb)
      dt_twist = MAXVAL(ABS(vb(1:rb, col_of(nb, 'Twist1')) - vc(1:rc, col_of(nc, 'Twist1'))))
      WRITE (*, '(A,ES10.3,A,F8.3,A)') '  1 vessel: held frames change the End A bend moment by ', dm, &
        ' of its range and the twist by ', dt_twist, ' deg'
      CALL require(dm > 0.01_wp .AND. dt_twist > 10.0_wp, '1: the vessel rotation turns the end frames (a '// &
                   'motionFile of the same translations holds them)')
      ! the chain moves with the vessel
      CALL require(MAXVAL(vb(1:rb, col_of(nb, 'Point3pz'))) - MINVAL(vb(1:rb, col_of(nb, 'Point3pz'))) > 5.0_wp, &
                   '1: the chain point rolls with the vessel')
    ELSE
      CALL require(.FALSE., '1: the turning and the held-frame outputs are complete')
    END IF
  END SUBROUTINE check_vessel_routes

  SUBROUTINE check_roll_routes()
    !! Gate 2.
    LOGICAL :: ok
    CALL write_roll_rows('tmrt_roll_1.txt', .FALSE.)
    CALL write_roll_rows('tmrt_roll_2.txt', .TRUE.)
    CALL sag_deck('tmrt_roll_a.dat', 'Coupled', .FALSE., [CHARACTER(48) :: 'tmrt_roll_1.txt motionFile'])
    CALL sag_deck('tmrt_roll_b.dat', 'Coupled', .TRUE., [CHARACTER(48) :: 'tmrt_roll_2.txt motionFile'])
    CALL run_driver('tmrt_roll_a.dat', 'tmrt_roll_a', ok)
    CALL require(ok, '2: the roll-column deck runs on the standalone cubic-Hermite route')
    CALL run_driver('tmrt_roll_b.dat', 'tmrt_roll_b', ok)
    CALL require(ok, '2: the mixed roll-column deck runs')
    CALL compare_routes('2 roll column', 'tmrt_roll_a', 'tmrt_roll_b')
    CALL march_library('tmrt_roll_b.dat', 'tmrt_roll_a', '2 roll column')
  END SUBROUTINE check_roll_routes

  SUBROUTINE check_attachment_routes()
    !! Gate 7: the gate 2 decks with three buoyancy modules on line 1.
    LOGICAL :: ok
    CHARACTER(48), PARAMETER :: ATTS(3) = [CHARACTER(48) :: '1 40.0 100.0 0.5 0.5 1.0', '1 50.0 100.0 0.5 0.5 1.0', &
                                                                                             '1 60.0 100.0 0.5 0.5 1.0']
    CALL write_roll_rows('tmrt_att_1.txt', .FALSE.)
    CALL write_roll_rows('tmrt_att_2.txt', .TRUE.)
    CALL sag_deck('tmrt_att_a.dat', 'Coupled', .FALSE., [CHARACTER(48) :: 'tmrt_att_1.txt motionFile'], atts=ATTS)
    CALL sag_deck('tmrt_att_b.dat', 'Coupled', .TRUE., [CHARACTER(48) :: 'tmrt_att_2.txt motionFile'], atts=ATTS)
    CALL run_driver('tmrt_att_a.dat', 'tmrt_att_a', ok)
    CALL require(ok, '7: the roll-column deck with ATTACHMENTS runs on the standalone cubic-Hermite route')
    CALL run_driver('tmrt_att_b.dat', 'tmrt_att_b', ok)
    CALL require(ok, '7: the mixed roll-column deck with ATTACHMENTS runs')
    CALL require(log_has('tmrt_att_b', 'mixed standalone aggregate'), '7: the mixed deck runs on the aggregate')
    CALL compare_routes('7 attachments', 'tmrt_att_a', 'tmrt_att_b')
  END SUBROUTINE check_attachment_routes

  SUBROUTINE check_quasi_static(mode)
    !! Gate 3: the straight 100 m neutral line of test_torsion_deck from (0, 0, -50) to a Fixed
    !! (100, 0, -50), clamped and restrained at both ends (Pretwist 90 deg at End B), beside a
    !! chain from (0, 10, -50) to a Fixed (0, 100, -100); End A held (roll 0) or rolled about the
    !! line axis by up to 30 deg from rest over 10 s (dtM 0.1): Twist1 = 90 - roll,
    !! Torq = GJ Twist / L at both ends.
    INTEGER, INTENT(IN) :: mode
    REAL(wp), PARAMETER :: GJ = 5.0e4_wp, L = 100.0_wp
    CHARACTER(48) :: points(4)
    CHARACTER(48), ALLOCATABLE :: options(:)
    CHARACTER(32) :: names(MAXCOL)
    REAL(wp), ALLOCATABLE :: vals(:, :)
    REAL(wp) :: t, ro, dro, d2ro, werr, terr, twist
    INTEGER :: u, k, nrow
    LOGICAL :: ok
    CHARACTER(16) :: label
    REAL(wp) :: amplitude
    OPEN (NEWUNIT=u, FILE='tmrt_qs_motion.txt', STATUS='REPLACE', ACTION='WRITE')
    DO k = 0, 100
      t = 0.1_wp*k
      CALL smooth(30.0_wp, t, ro, dro, d2ro)
      IF (mode == QS_VESSEL) THEN
        WRITE (u, '(F8.3,A,ES25.16E3,A,ES25.16E3,A,ES25.16E3,A)') t, ' 0 0 -50 ', ro, ' 0 0 0 0 0 ', dro*D2R, &
          ' 0 0 0 0 0 ', d2ro*D2R, ' 0 0'
      ELSE IF (mode == QS_ROLL) THEN
        WRITE (u, '(F8.3,A,ES25.16E3)') t, ' 1 0 0 -50 0 0 0 0 0 0 ', ro
        WRITE (u, '(F8.3,A)') t, ' 3 0 10 -50 0 0 0 0 0 0'
      END IF
    END DO
    CLOSE (u)
    points(1) = '1 Coupled 0.0 0.0 -50.0 0 0 0 0'
    points(2) = '2 Fixed 100.0 0.0 -50.0 0 0 0 0'
    points(3) = '3 Coupled 0.0 10.0 -50.0 0 0 0 0'
    points(4) = '4 Fixed 0.0 100.0 -100.0 0 0 0 0'
    amplitude = 30.0_wp
    SELECT CASE (mode)
    CASE (QS_VESSEL)
      label = '3 vessel roll'
      points(1) = '1 Vessel 0.0 0.0 -50.0 0 0 0 0'
      points(3) = '3 Vessel 0.0 10.0 -50.0 0 0 0 0'
      options = [CHARACTER(48) :: '0.1 dtM', '10.0 TMax', 'tmrt_qs_motion.txt vesselMotion', '0|0|-50 vesselRef']
    CASE (QS_ROLL)
      label = '3 roll column'
      options = [CHARACTER(48) :: '0.1 dtM', '10.0 TMax', 'tmrt_qs_motion.txt motionFile']
    CASE DEFAULT
      label = '3 held'
      amplitude = 0.0_wp
      options = [CHARACTER(48) :: '0.1 dtM', '10.0 TMax']
    END SELECT
    CALL write_deck('tmrt_qs.dat', [CHARACTER(160) :: neutral_t, CHAIN_T], points, &
                    [CHARACTER(16) :: '1 1 2 -', '2 3 4 -'], [CHARACTER(24) :: '1 cab 100.0 40', '2 chain 110.0 20'], &
                    [CHARACTER(96) :: '1 A Rigid 1 0 0 Rigid 0 0 1 0', '1 B Rigid 1 0 0 Rigid 0 0 1 90'], &
                    options, [CHARACTER(16) :: 'Torq1N1', 'Torq1N41', 'Twist1', 'FairTen2'])
    CALL run_driver('tmrt_qs.dat', 'tmrt_qs', ok)
    CALL require(ok, TRIM(label)//': the mixed deck runs')
    ALLOCATE (vals(MAXROW, MAXCOL))
    CALL read_out('tmrt_qs.out', names, vals, nrow)
    CALL require(nrow == 101, TRIM(label)//': every row written')
    werr = 0.0_wp
    terr = 0.0_wp
    DO k = 1, nrow
      CALL smooth(amplitude, vals(k, 1), ro, dro, d2ro)
      twist = 90.0_wp - ro
      werr = MAX(werr, ABS(vals(k, col_of(names, 'Twist1')) - twist))
      terr = MAX(terr, ABS(vals(k, col_of(names, 'Torq1N1')) - GJ*twist*D2R/L), &
                 ABS(vals(k, col_of(names, 'Torq1N41')) - GJ*twist*D2R/L))
    END DO
    IF (nrow == 0) THEN
      werr = HUGE(1.0_wp)
      terr = HUGE(1.0_wp)
    END IF
    WRITE (*, '(A,A,ES10.3,A,ES10.3,A)') '  ', TRIM(label)//': Twist1 error ', werr, ' deg, torque error ', terr, &
      ' N m'
    CALL require(werr <= 1.0e-6_wp, TRIM(label)//': Twist1 = Pretwist - roll at every step')
    CALL require(terr <= 1.0e-6_wp*GJ, TRIM(label)//': Torq = GJ Twist / L at both ends at every step')
  END SUBROUTINE check_quasi_static

  SUBROUTINE check_two_moving_roll(sense, b_first)
    !! Gate 8: the gate 3 line with End B on the Coupled point 2 at (100, 0, -50), rolled with End
    !! A by the roll column, roll(B) = sense roll(A): Twist1 = 90 - (1 + sense) roll. b_first: the
    !! same line with the point ids of its ends exchanged (End B on point 1, End A on point 2), so
    !! End B's point comes first in POINTS.
    REAL(wp), INTENT(IN) :: sense
    LOGICAL, INTENT(IN), OPTIONAL :: b_first
    REAL(wp), PARAMETER :: GJ = 5.0e4_wp, L = 100.0_wp
    CHARACTER(48) :: points(4)
    CHARACTER(32) :: names(MAXCOL)
    REAL(wp), ALLOCATABLE :: vals(:, :)
    REAL(wp) :: t, ro, dro, d2ro, werr, terr, twist
    INTEGER :: u, k, nrow, pa, pb
    LOGICAL :: ok, bf
    CHARACTER(24) :: label
    CHARACTER(16) :: line1
    bf = .FALSE.
    IF (PRESENT(b_first)) bf = b_first
    label = MERGE('8 equal rolls   ', '8 opposite rolls', sense > 0.0_wp)
    IF (bf) label = '8 End B first'
    ! the point ids of End A and End B
    pa = MERGE(2, 1, bf)
    pb = 3 - pa
    OPEN (NEWUNIT=u, FILE='tmrt_two_motion.txt', STATUS='REPLACE', ACTION='WRITE')
    DO k = 0, 100
      t = 0.1_wp*k
      CALL smooth(15.0_wp, t, ro, dro, d2ro)
      WRITE (u, '(F8.3,1X,I0,A,ES25.16E3)') t, pa, ' 0 0 -50 0 0 0 0 0 0 ', ro
      WRITE (u, '(F8.3,1X,I0,A,ES25.16E3)') t, pb, ' 100 0 -50 0 0 0 0 0 0 ', sense*ro
      WRITE (u, '(F8.3,A)') t, ' 3 0 10 -50 0 0 0 0 0 0'
    END DO
    CLOSE (u)
    points(pa) = ACHAR(48 + pa)//' Coupled 0.0 0.0 -50.0 0 0 0 0'
    points(pb) = ACHAR(48 + pb)//' Coupled 100.0 0.0 -50.0 0 0 0 0'
    points(3) = '3 Coupled 0.0 10.0 -50.0 0 0 0 0'
    points(4) = '4 Fixed 0.0 100.0 -100.0 0 0 0 0'
    line1 = '1 '//ACHAR(48 + pa)//' '//ACHAR(48 + pb)//' -'
    CALL write_deck('tmrt_two.dat', [CHARACTER(160) :: neutral_t, CHAIN_T], points, &
                    [CHARACTER(16) :: line1, '2 3 4 -'], [CHARACTER(24) :: '1 cab 100.0 40', '2 chain 110.0 20'], &
                    [CHARACTER(96) :: '1 A Rigid 1 0 0 Rigid 0 0 1 0', '1 B Rigid 1 0 0 Rigid 0 0 1 90'], &
                    [CHARACTER(48) :: '0.1 dtM', '10.0 TMax', 'tmrt_two_motion.txt motionFile'], &
                    [CHARACTER(16) :: 'Torq1N1', 'Torq1N41', 'Twist1', 'FairTen2'])
    CALL run_driver('tmrt_two.dat', 'tmrt_two', ok)
    CALL require(ok, TRIM(label)//': the mixed deck with a line between two moving points runs')
    ALLOCATE (vals(MAXROW, MAXCOL))
    CALL read_out('tmrt_two.out', names, vals, nrow)
    CALL require(nrow == 101, TRIM(label)//': every row written')
    werr = 0.0_wp
    terr = 0.0_wp
    DO k = 1, nrow
      CALL smooth(15.0_wp, vals(k, 1), ro, dro, d2ro)
      twist = 90.0_wp - (1.0_wp + sense)*ro
      werr = MAX(werr, ABS(vals(k, col_of(names, 'Twist1')) - twist))
      terr = MAX(terr, ABS(vals(k, col_of(names, 'Torq1N1')) - GJ*twist*D2R/L), &
                 ABS(vals(k, col_of(names, 'Torq1N41')) - GJ*twist*D2R/L))
    END DO
    IF (nrow == 0) THEN
      werr = HUGE(1.0_wp)
      terr = HUGE(1.0_wp)
    END IF
    WRITE (*, '(A,A,ES10.3,A,ES10.3,A)') '  ', TRIM(label)//': Twist1 error ', werr, ' deg, torque error ', terr, &
      ' N m'
    CALL require(werr <= 1.0e-6_wp, TRIM(label)//': Twist1 = Pretwist - roll(A) - roll(B) at every step')
    CALL require(terr <= 1.0e-6_wp*GJ, TRIM(label)//': Torq = GJ Twist / L at both ends at every step')
  END SUBROUTINE check_two_moving_roll

  SUBROUTINE check_refusal()
    !! Gate 4.
    LOGICAL :: ok
    INTEGER :: u, k
    OPEN (NEWUNIT=u, FILE='tmrt_bad_roll.txt', STATUS='REPLACE', ACTION='WRITE')
    DO k = 0, NSTEP
      WRITE (u, '(F8.3,A,F6.2)') DT*k, ' 1 0 0 -50 0 0 0 0 0 0 ', 0.0_wp
      WRITE (u, '(F8.3,A,F6.2)') DT*k, ' 3 0 20 -50 0 0 0 0 0 0 ', MERGE(0.0_wp, 5.0_wp, k == 0)
    END DO
    CLOSE (u)
    CALL sag_deck('tmrt_bad.dat', 'Coupled', .TRUE., [CHARACTER(48) :: 'tmrt_bad_roll.txt motionFile'])
    CALL run_driver('tmrt_bad.dat', 'tmrt_bad', ok)
    CALL require(.NOT. ok, '4: a roll column at the chain point stops the run')
    CALL require(log_has('tmrt_bad', 'has a non-zero roll column'), '4: the roll column at the chain point is named')
  END SUBROUTINE check_refusal

  REAL(wp) FUNCTION static_fairlead(root, column) RESULT(x)
    !! Column `column` of line 1's End A (the first node row) in <root>.static.out (4: X, 7:
    !! tension).
    CHARACTER(*), INTENT(IN) :: root
    INTEGER, INTENT(IN) :: column
    CHARACTER(4096) :: buf
    REAL(wp) :: row(12)
    INTEGER :: u, ios, k
    x = HUGE(1.0_wp)
    OPEN (NEWUNIT=u, FILE=root//'.static.out', STATUS='OLD', ACTION='READ', IOSTAT=ios)
    IF (ios /= 0) RETURN
    DO k = 1, 3
      READ (u, '(A)', IOSTAT=ios) buf
    END DO
    READ (u, *, IOSTAT=ios) row
    IF (ios == 0) x = row(column)
    CLOSE (u)
  END FUNCTION static_fairlead

  SUBROUTINE check_static_row1()
    !! Gate 5.
    CHARACTER(32) :: na(MAXCOL), nb(MAXCOL)
    REAL(wp), ALLOCATABLE :: va(:, :), vb(:, :)
    INTEGER :: u, ra, rb, k, ca, cb
    LOGICAL :: ok
    REAL(wp) :: e, xa, xb, ta, tb
    DO k = 1, 2
      OPEN (NEWUNIT=u, FILE=MERGE('tmrt_t0_1.txt', 'tmrt_t0_2.txt', k == 1), STATUS='REPLACE', ACTION='WRITE')
      WRITE (u, '(A)') '0 1 0.02 0 -50 0 0 0 0 0 0'
      IF (k == 2) WRITE (u, '(A)') '0 3 0.02 20 -50 0 0 0 0 0 0'
      CLOSE (u)
    END DO
    CALL sag_deck('tmrt_t0_a.dat', 'Coupled', .FALSE., [CHARACTER(48) :: 'tmrt_t0_1.txt motionFile'], '0.0 TMax')
    CALL sag_deck('tmrt_t0_b.dat', 'Coupled', .TRUE., [CHARACTER(48) :: 'tmrt_t0_2.txt motionFile'], '0.0 TMax')
    CALL run_driver('tmrt_t0_a.dat', 'tmrt_t0_a', ok)
    CALL require(ok, '5: the TMax = 0 motion deck runs on the single-line route')
    CALL run_driver('tmrt_t0_b.dat', 'tmrt_t0_b', ok)
    CALL require(ok, '5: the TMax = 0 mixed motion deck runs')
    ALLOCATE (va(MAXROW, MAXCOL), vb(MAXROW, MAXCOL))
    CALL read_out('tmrt_t0_a.out', na, va, ra)
    CALL read_out('tmrt_t0_b.out', nb, vb, rb)
    CALL require(ra == 1 .AND. rb == 1, '5: one t = 0 row on each route')
    IF (ra /= 1 .OR. rb /= 1) RETURN
    e = 0.0_wp
    DO k = 1, SIZE(OUTS)
      ca = col_of(na, OUTS(k))
      cb = col_of(nb, OUTS(k))
      IF (ca == 0 .OR. cb == 0) THEN
        e = HUGE(1.0_wp)
      ELSE IF (TRIM(OUTS(k)) == 'L1N21py') THEN
        e = MAX(e, ABS(vb(1, cb) - va(1, ca))/POS_TOL)
      ELSE IF (ANY(LOADS == OUTS(k))) THEN
        e = MAX(e, ABS(vb(1, cb) - va(1, ca))/(LOAD_TOL*ABS(va(1, ca))))
      ELSE
        e = MAX(e, print_error(va(:, ca), vb(:, cb), 1)/2.0_wp)
      END IF
    END DO
    xa = static_fairlead('tmrt_t0_a', 4)
    xb = static_fairlead('tmrt_t0_b', 4)
    ta = static_fairlead('tmrt_t0_a', 7)
    tb = static_fairlead('tmrt_t0_b', 7)
    WRITE (*, '(A,ES10.3,A,2ES12.4,A)') '  5 TMax = 0, row 1 off by 2 cm: t = 0 rows agree to ', e, &
      ' of their tolerances; static fairlead x ', xa, xb, ' m'
    CALL require(e <= 1.0_wp, '5: both routes write the t = 0 row at the installed row 1')
    CALL require(va(1, col_of(na, 'FairTen1')) > 10.0_wp*ta .AND. vb(1, col_of(nb, 'FairTen1')) > 10.0_wp*tb, &
                 '5: the t = 0 row carries the installed row 1, not the static state')
    CALL require(ABS(xa) <= 1.0e-9_wp .AND. ABS(xb) <= 1.0e-9_wp, &
                 '5: both routes write the static configuration before row 1 moves the fairlead')
  END SUBROUTINE check_static_row1

  SUBROUTINE check_static_blend()
    !! Gate 6.
    REAL(wp), PARAMETER :: GJ = 5.0e4_wp, L = 100.0_wp
    CHARACTER(32) :: names(MAXCOL)
    REAL(wp), ALLOCATABLE :: vals(:, :)
    CHARACTER(48) :: points(4)
    INTEGER :: nrow
    LOGICAL :: ok
    REAL(wp) :: terr
    points(1) = '1 Coupled 0.0 0.0 -50.0 0 0 0 0'
    points(2) = '2 Fixed 100.0 0.0 -50.0 0 0 0 0'
    points(3) = '3 Coupled 0.0 10.0 -50.0 0 0 0 0'
    points(4) = '4 Fixed 0.0 100.0 -100.0 0 0 0 0'
    CALL write_deck('tmrt_blend_s.dat', [CHARACTER(160) :: neutral_t, CHAIN_T], points, &
                    [CHARACTER(16) :: '1 1 2 -', '2 3 4 -'], [CHARACTER(24) :: '1 cab 100.0 40', '2 chain 110.0 20'], &
                    [CHARACTER(96) :: '1 A Rigid 1 0 0 Rigid 0 0 1 0', '1 B Rigid 1 0 0 Rigid 0 0 1 90'], &
                    [CHARACTER(48) :: '0.1 dtM', '0.0 TMax', 'False alpha_force_blend'], &
                    [CHARACTER(16) :: 'Torq1N1', 'Twist1'])
    CALL run_driver('tmrt_blend_s.dat', 'tmrt_blend_s', ok)
    CALL require(ok, '6: a static mixed deck with torsion runs without the force blend')
    ALLOCATE (vals(MAXROW, MAXCOL))
    CALL read_out('tmrt_blend_s.out', names, vals, nrow)
    terr = HUGE(1.0_wp)
    IF (nrow == 1) terr = ABS(vals(1, col_of(names, 'Torq1N1')) - GJ*90.0_wp*D2R/L)
    WRITE (*, '(A,ES10.3,A)') '  6 static mixed deck without the force blend: torque error ', terr, ' N m'
    CALL require(terr <= 1.0e-6_wp*GJ, '6: the static torque is GJ Phi / L')
    CALL write_deck('tmrt_blend_d.dat', [CHARACTER(160) :: neutral_t, CHAIN_T], points, &
                    [CHARACTER(16) :: '1 1 2 -', '2 3 4 -'], [CHARACTER(24) :: '1 cab 100.0 40', '2 chain 110.0 20'], &
                    [CHARACTER(96) :: '1 A Rigid 1 0 0 Rigid 0 0 1 0', '1 B Rigid 1 0 0 Rigid 0 0 1 90'], &
                    [CHARACTER(48) :: '0.1 dtM', '1.0 TMax', 'False alpha_force_blend'], &
                    [CHARACTER(16) :: 'Torq1N1', 'Twist1'])
    CALL run_driver('tmrt_blend_d.dat', 'tmrt_blend_d', ok)
    CALL require(.NOT. ok, '6: a dynamic mixed deck with torsion and the configuration blend stops')
    CALL require(log_has('tmrt_blend_d', 'torsion in a dynamic run needs the force-blended'), &
                 '6: the configuration blend of a dynamic torsion run is named')
    ! one restrained end: the aggregate parses the deck caller-driven, so the static run must
    ! reach the one-end resolution, or the line is left unsolved in torsion and its channels
    ! refused; the free End B carries no torque
    CALL write_deck('tmrt_blend_s1.dat', [CHARACTER(160) :: neutral_t, CHAIN_T], points, &
                    [CHARACTER(16) :: '1 1 2 -', '2 3 4 -'], [CHARACTER(24) :: '1 cab 100.0 40', '2 chain 110.0 20'], &
                    [CHARACTER(96) :: '1 A Rigid 1 0 0 Rigid 0 0 1 0', '1 B Rigid 1 0 0 Free 0 0 1'], &
                    [CHARACTER(48) :: '0.1 dtM', '0.0 TMax', 'False alpha_force_blend'], &
                    [CHARACTER(16) :: 'Torq1N1', 'Twist1'])
    BLOCK
      INTEGER :: u, ios
      ! no output of an earlier run may stand in for this one
      OPEN (NEWUNIT=u, FILE='tmrt_blend_s1.out', STATUS='OLD', IOSTAT=ios)
      IF (ios == 0) CLOSE (u, STATUS='DELETE')
    END BLOCK
    CALL run_driver('tmrt_blend_s1.dat', 'tmrt_blend_s1', ok)
    CALL require(ok, '6: a static mixed deck with one restrained end runs without the force blend')
    terr = HUGE(1.0_wp)
    nrow = 0
    IF (ok) CALL read_out('tmrt_blend_s1.out', names, vals, nrow)
    IF (nrow == 1) terr = ABS(vals(1, col_of(names, 'Torq1N1')))
    WRITE (*, '(A,ES10.3,A)') '  6 static mixed deck, one restrained end: torque ', terr, ' N m'
    CALL require(terr <= 1.0e-6_wp*GJ*90.0_wp*D2R/L, '6: the free end of a static one-end line carries no torque')
    CALL write_deck('tmrt_blend_d1.dat', [CHARACTER(160) :: neutral_t, CHAIN_T], points, &
                    [CHARACTER(16) :: '1 1 2 -', '2 3 4 -'], [CHARACTER(24) :: '1 cab 100.0 40', '2 chain 110.0 20'], &
                    [CHARACTER(96) :: '1 A Rigid 1 0 0 Rigid 0 0 1 0', '1 B Rigid 1 0 0 Free 0 0 1'], &
                    [CHARACTER(48) :: '0.1 dtM', '1.0 TMax', 'False alpha_force_blend'], &
                    [CHARACTER(16) :: 'Torq1N1', 'Twist1'])
    CALL run_driver('tmrt_blend_d1.dat', 'tmrt_blend_d1', ok)
    CALL require(.NOT. ok, '6: a dynamic one-end torsion run with the configuration blend stops')
    CALL require(log_has('tmrt_blend_d1', 'torsion in a dynamic run needs the force-blended'), &
                 '6: the configuration blend of a dynamic one-end torsion run is named')
  END SUBROUTINE check_static_blend

  PURE SUBROUTINE smooth_start(amplitude, t, f, df, d2f)
    !! f = F (1 - cos w t)^2 / 4 and its rates, w = 2 pi / PERIOD: a motion from rest with no
    !! acceleration at t = 0 (f'' = F w^2 (sin^2 w t + (1 - cos w t) cos w t) / 2).
    REAL(wp), INTENT(IN) :: amplitude, t
    REAL(wp), INTENT(OUT) :: f, df, d2f
    REAL(wp) :: w, c, sn
    w = 2.0_wp*PI/PERIOD
    c = COS(w*t)
    sn = SIN(w*t)
    f = 0.25_wp*amplitude*(1.0_wp - c)**2
    df = 0.5_wp*amplitude*w*(1.0_wp - c)*sn
    d2f = 0.5_wp*amplitude*w*w*(sn*sn + (1.0_wp - c)*c)
  END SUBROUTINE smooth_start

  SUBROUTINE turbine_record(j, t, row)
    !! Gate 9: the motionFile record of turbine j at time t (time J x y z q0 q1 q2 q3 vx vy vz wx wy
    !! wz ax ay az alx aly alz). Turbine 1 at (0, 0, 0) with PtfmInit surge 2 m, heave -0.5 m and
    !! yaw 180 deg, turbine 2 at (300, 0, 0) with PtfmInit sway 1 m and yaw 5 deg; from rest, with
    !! no acceleration at t = 0 (smooth_start), each heaves 1 m (turbine 2: -0.8 m) and rolls 10 deg
    !! (turbine 2: -8 deg) about its own x axis:
    !! R = Rz(yaw) Rx(roll), the quaternion [cz cx, cz sx, sz sx, sz cx] of the half angles, the
    !! global angular velocity Rz(yaw) (roll', 0, 0) and acceleration Rz(yaw) (roll'', 0, 0).
    INTEGER, INTENT(IN) :: j
    REAL(wp), INTENT(IN) :: t
    REAL(wp), INTENT(OUT) :: row(21)
    REAL(wp) :: x0(3), yaw, zh, vz, az, ro, dro, d2ro, ex(3)
    IF (j == 1) THEN
      x0 = [2.0_wp, 0.0_wp, -0.5_wp]
      yaw = 180.0_wp*D2R
      CALL smooth_start(1.0_wp, t, zh, vz, az)
      CALL smooth_start(10.0_wp*D2R, t, ro, dro, d2ro)
    ELSE
      x0 = [300.0_wp, 1.0_wp, 0.0_wp]
      yaw = 5.0_wp*D2R
      CALL smooth_start(-0.8_wp, t, zh, vz, az)
      CALL smooth_start(-8.0_wp*D2R, t, ro, dro, d2ro)
    END IF
    ex = [COS(yaw), SIN(yaw), 0.0_wp]
    row = 0.0_wp
    row(1) = t
    row(2) = REAL(j, wp)
    row(3:5) = x0 + [0.0_wp, 0.0_wp, zh]
    row(6:9) = [COS(0.5_wp*yaw)*COS(0.5_wp*ro), COS(0.5_wp*yaw)*SIN(0.5_wp*ro), SIN(0.5_wp*yaw)*SIN(0.5_wp*ro), &
                SIN(0.5_wp*yaw)*COS(0.5_wp*ro)]
    row(10:12) = [0.0_wp, 0.0_wp, vz]
    row(13:15) = dro*ex
    row(16:18) = [0.0_wp, 0.0_wp, az]
    row(19:21) = d2ro*ex
  END SUBROUTINE turbine_record

  SUBROUTINE turbine_deck(path, cable, chains)
    !! Gate 9: the TURBINES deck (the turbines of turbine_record) with the finite-EI cable (line
    !! 1, 300 m, 40 elements) from point 1 on turbine 1 to point 2 on turbine 2, both clamped and
    !! restrained in torsion (Pretwist 30 deg at End B), and/or the chains 2 and 3 from points 3 (on
    !! turbine 1) and 5 (on turbine 2) to the anchors 4 and 6. Coordinates of a Turbine<J> point and
    !! its Ez and Nx are in its turbine's axes.
    CHARACTER(*), INTENT(IN) :: path
    LOGICAL, INTENT(IN) :: cable, chains
    CHARACTER(48) :: pts(6), opts(5)
    CHARACTER(96) :: turbs(2), ec(2)
    pts(1) = '1 Turbine1 -20.0 0.0 -15.0 0 0 0 0'
    pts(2) = '2 Turbine2 -20.0 0.0 -15.0 0 0 0 0'
    pts(3) = '3 Turbine1 20.0 0.0 -15.0 0 0 0 0'
    pts(4) = '4 Fixed -250.0 0.0 -200.0 0 0 0 0'
    pts(5) = '5 Turbine2 20.0 0.0 -15.0 0 0 0 0'
    pts(6) = '6 Fixed 550.0 0.0 -200.0 0 0 0 0'
    turbs(1) = '1 0.0 0.0 0.0 2.0 0.0 -0.5 0.0 0.0 180.0'
    turbs(2) = '2 300.0 0.0 0.0 0.0 1.0 0.0 0.0 0.0 5.0'
    ec(1) = '1 A Rigid -1 0 -0.4 Rigid 0 -1 0 0'
    ec(2) = '1 B Rigid 1 0 0.4 Rigid 0 1 0 30'
    opts = [CHARACTER(48) :: '200.0 WtrDpth', '0.05 dtM', '10.0 TMax', 'tmrt_turb.txt motionFile', '3.0e6 kBot']
    IF (cable .AND. chains) THEN
      CALL write_deck(path, [CHARACTER(96) :: CAB_T, CHAIN_T], pts, &
                      [CHARACTER(16) :: '1 1 2 -', '2 3 4 -', '3 5 6 -'], &
                      [CHARACTER(24) :: '1 cab 300.0 40', '2 chain 320.0 20', '3 chain 320.0 20'], ec, opts, &
                      [TURB_CABLE, TURB_CHAINS], turbs=turbs)
    ELSE IF (cable) THEN
      CALL write_deck(path, [CHARACTER(96) :: CAB_T], pts(1:2), [CHARACTER(16) :: '1 1 2 -'], &
                      [CHARACTER(24) :: '1 cab 300.0 40'], ec, opts, TURB_CABLE, turbs=turbs)
    ELSE
      CALL write_deck(path, [CHARACTER(96) :: CHAIN_T], pts(3:6), [CHARACTER(16) :: '2 3 4 -', '3 5 6 -'], &
                      [CHARACTER(24) :: '2 chain 320.0 20', '3 chain 320.0 20'], [CHARACTER(8) ::], opts, &
                      TURB_CHAINS, turbs=turbs)
    END IF
  END SUBROUTINE turbine_deck

  SUBROUTINE check_turbines()
    !! Gate 9.
    CHARACTER(32) :: nm(MAXCOL), nc(MAXCOL), nl(MAXCOL)
    REAL(wp), ALLOCATABLE :: vm(:, :), vc(:, :), vl(:, :)
    REAL(wp) :: row(21), e, e_turb, e_leg
    INTEGER :: u, k, j, rm, rc, rl, cm, cx
    LOGICAL :: ok
    OPEN (NEWUNIT=u, FILE='tmrt_turb.txt', STATUS='REPLACE', ACTION='WRITE')
    DO k = 0, NSTEP
      DO j = 1, 2
        CALL turbine_record(j, DT*k, row)
        WRITE (u, '(F8.3,I3,19ES25.16E3)') row(1), j, row(3:21)
      END DO
    END DO
    CLOSE (u)
    CALL turbine_deck('tmrt_turb_m.dat', .TRUE., .TRUE.)
    CALL turbine_deck('tmrt_turb_c.dat', .TRUE., .FALSE.)
    CALL turbine_deck('tmrt_turb_l.dat', .FALSE., .TRUE.)
    CALL run_driver('tmrt_turb_c.dat', 'tmrt_turb_c', ok)
    CALL require(ok, '9: the cable of the TURBINES deck runs on the standalone cubic-Hermite route')
    CALL run_driver('tmrt_turb_l.dat', 'tmrt_turb_l', ok)
    CALL require(ok, '9: the chains of the TURBINES deck run on the standalone EI = 0 route')
    CALL run_driver('tmrt_turb_m.dat', 'tmrt_turb_m', ok)
    CALL require(ok, '9: the TURBINES deck of the cable and the chains runs on the mixed route')
    CALL require(log_has('tmrt_turb_m', 'mixed standalone aggregate'), '9: the TURBINES deck runs on the aggregate')
    ALLOCATE (vm(MAXROW, MAXCOL), vc(MAXROW, MAXCOL), vl(MAXROW, MAXCOL))
    CALL read_out('tmrt_turb_m.out', nm, vm, rm)
    CALL read_out('tmrt_turb_c.out', nc, vc, rc)
    CALL read_out('tmrt_turb_l.out', nl, vl, rl)
    CALL require(rm == NSTEP + 1 .AND. rc == NSTEP + 1 .AND. rl == NSTEP + 1, '9: the three runs write every row')
    IF (rm /= NSTEP + 1 .OR. rc /= NSTEP + 1 .OR. rl /= NSTEP + 1) RETURN
    e_turb = 0.0_wp
    DO k = 1, SIZE(TURB_CABLE)
      cm = col_of(nm, TURB_CABLE(k))
      cx = col_of(nc, TURB_CABLE(k))
      CALL require(cm > 0 .AND. cx > 0, '9: channel '//TRIM(TURB_CABLE(k))//' in both outputs')
      IF (cm == 0 .OR. cx == 0) CYCLE
      e = range_error(vc(:, cx), vm(:, cm), rm)
      WRITE (*, '(A,A,A,ES10.3,A)') '  9 TURBINES driver: ', TRIM(TURB_CABLE(k)), ' difference ', e, &
        ' of its range (the coupled Newton controls)'
      e_turb = MAX(e_turb, e)
    END DO
    e_leg = 0.0_wp
    DO k = 1, SIZE(TURB_CHAINS)
      cm = col_of(nm, TURB_CHAINS(k))
      cx = col_of(nl, TURB_CHAINS(k))
      CALL require(cm > 0 .AND. cx > 0, '9: channel '//TRIM(TURB_CHAINS(k))//' in both outputs')
      IF (cm == 0 .OR. cx == 0) CYCLE
      e = range_error(vl(:, cx), vm(:, cm), rm)
      WRITE (*, '(A,A,A,ES10.3,A)') '  9 TURBINES driver: ', TRIM(TURB_CHAINS(k)), ' difference ', e, ' of its range'
      e_leg = MAX(e_leg, e)
    END DO
    CALL require(e_turb <= TURB_TOL, '9: the cable agrees with the cable-only deck within the coupled Newton controls')
    ! the torsion note: the total twist (Twist1), not the Pretwist difference alone
    BLOCK
      REAL(wp) :: tw_note, tw_out, pre_note
      tw_note = log_value('tmrt_turb_c', 'total twist Twist1 =')
      pre_note = log_value('tmrt_turb_c', 'Pretwist(B) - Pretwist(A) =')
      tw_out = vc(1, col_of(nc, 'Twist1'))
      WRITE (*, '(A,3F12.6,A)') '  9 TURBINES torsion note: total twist, Twist1 at t = 0, pretwist ', tw_note, &
        tw_out, pre_note, ' deg'
      CALL require(ABS(tw_note - tw_out) <= 1.0e-5_wp*ABS(tw_out), '9: the torsion note gives the total twist Twist1')
      CALL require(ABS(pre_note - 30.0_wp) <= 1.0e-9_wp .AND. ABS(tw_note - 30.0_wp) > 1.0_wp, &
                   '9: the note names the pretwist and a total twist that carries the end frames'' turn')
    END BLOCK
    CALL require(e_leg <= LOAD_TOL, '9: the chain tensions agree with the legs-only deck')
    CALL march_turbines(nc, vc, rc)
  END SUBROUTINE check_turbines

  SUBROUTINE march_turbines(nc, vc, rc)
    !! Gate 9: the mixed route's march of the TURBINES deck (deck_turbines, the driver's call)
    !! through the aggregate library, its cable given the standalone route's Newton controls (as
    !! march_library): every cable channel is compared at every step with the cable-only run's
    !! output (nc, vc, rc rows) to its printed precision.
    CHARACTER(32), INTENT(IN) :: nc(:)
    REAL(wp), INTENT(IN) :: vc(:, :)
    INTEGER, INTENT(IN) :: rc
    TYPE(CD_AGG_ModuleType), ALLOCATABLE :: agg
    REAL(wp), ALLOCATABLE :: pos(:, :), vel(:, :), acc(:, :), load(:, :), orient(:, :, :), omega(:, :), alpha(:, :)
    REAL(wp), ALLOCATABLE :: roll(:), got(:, :)
    CHARACTER(2048) :: em
    INTEGER :: es, n, c, step, k, cx, nch, n_iter
    LOGICAL :: turns, rolls, conv, stalled
    REAL(wp) :: worst, v
    ALLOCATE (agg)
    CALL CD_AGG_Init_From_Deck(agg, 'tmrt_turb_m.dat', DT, es, em, forbid_deck_ambient=.TRUE., run_tmax=TMAX, &
                               host_orientation=.TRUE., prescribed_motion=.TRUE., deck_turbines=.TRUE.)
    CALL require(es == CD_AGG_OK .AND. CD_AGG_HasMotion(agg), '9: the aggregate takes the TURBINES deck and its '// &
                 'records: '//TRIM(em))
    IF (es /= CD_AGG_OK) RETURN
    DO c = 1, agg%ncable
      agg%cables(c)%tol = 1.0e-8_wp
      agg%cables(c)%max_iter = 30
      agg%cables(c)%line%tangent_reuse = .TRUE.
    END DO
    n = CD_AGG_NMovingPoints(agg, es, em)
    nch = CD_AGG_NumChannels(agg)
    ALLOCATE (pos(3, n), vel(3, n), acc(3, n), load(3, n), orient(3, 3, n), omega(3, n), alpha(3, n), roll(n), &
              got(NSTEP + 1, nch))
    CALL CD_AGG_GetMovingPointMesh(agg, pos, vel, acc, load, es, em)
    CALL CD_AGG_MotionKinematics(agg, 1, pos, vel, acc, orient, omega, alpha, roll, turns, rolls, es, em)
    CALL require(turns, '9: the TURBINES records turn the moving columns')
    CALL CD_AGG_UpdateStates_Moving(agg, pos, vel, acc, es, em, orientation=orient, angular_velocity=omega, &
                                    angular_acceleration=alpha)
    IF (es == CD_AGG_OK) CALL CD_AGG_Refresh_Accelerations(agg, es, em)
    CALL require(es == CD_AGG_OK, '9: the first TURBINES records install: '//TRIM(em))
    DO step = 0, NSTEP
      IF (step > 0) THEN
        CALL CD_AGG_MotionKinematics(agg, step + 1, pos, vel, acc, orient, omega, alpha, roll, turns, rolls, es, em)
        CALL CD_AGG_Step_Moving(agg, DT, pos, vel, acc, conv, stalled, n_iter, es, em, t_committed=DT*step, &
                                orientation=orient, angular_velocity=omega, angular_acceleration=alpha)
        IF (es /= CD_AGG_OK .OR. .NOT. conv) THEN
          CALL require(.FALSE., '9: library march step: '//TRIM(em))
          EXIT
        END IF
      END IF
      CALL CD_AGG_CalcOutput(agg, es, em)
      DO k = 1, nch
        CALL CD_AGG_EvalChannel(agg, k, v, es, em)
        got(step + 1, k) = v
      END DO
    END DO
    ! the mixed deck's channels are TURB_CABLE then TURB_CHAINS, in OUTPUTS order
    worst = HUGE(1.0_wp)
    IF (rc == NSTEP + 1) THEN
      worst = 0.0_wp
      DO k = 1, SIZE(TURB_CABLE)
        cx = col_of(nc, TURB_CABLE(k))
        IF (cx > 0) THEN
          worst = MAX(worst, print_error(vc(:, cx), got(:, k), rc))
        ELSE
          worst = HUGE(1.0_wp)
        END IF
      END DO
    END IF
    WRITE (*, '(A,ES10.3,A)') '  9 TURBINES library march with the standalone Newton controls: largest cable '// &
      'difference ', worst, ' printed units'
    CALL require(worst <= 2.0_wp, '9: with the same Newton controls the mixed route reproduces the cable-only deck')
    CALL CD_AGG_End(agg, es, em)
  END SUBROUTINE march_turbines
END PROGRAM test_mixed_route_torsion
