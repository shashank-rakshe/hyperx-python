! File: tests/test_body_rod_physics.f90
! SPDX-License-Identifier: Apache-2.0
! Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
PROGRAM test_body_rod_physics
  !! Physics gate for the standalone rigid-body models (Rigid6 bodies and rigid rods) run
  !! through the public `.dat` -> `.out` deck workflow:
  !!   1. a submerged Rigid6 body is drag-damped in still water: `current none` and an explicit
  !!      zero current give the same body motion, and CdA > 0 damps the decay;
  !!   2. rod added mass is directional and rotational: the heave and pitch natural periods of a
  !!      tethered horizontal rod and the axial heave period of a tethered vertical rod match the
  !!      analytical values built from Ca (normal), CaAx (axial) and Ca*rhoW*A*L^3/12 (pitch);
  !!      ROD TYPES columns 6-7 are MoorDyn's CdEnd CaEnd (end added mass sets the axial period,
  !!      end drag damps it) and a legacy CdAx/CaAx header in columns 6-7 is rejected;
  !!   3. rod seabed contact is distributed with kBot/cBot per unit contact area: a heavy rod
  !!      settles flat with penetration W_sub/(kBot*d*L) (plus the attached line-end nodes);
  !!   4. a free rod keeps its seabed contact on a bathymetryFile deck that also carries a
  !!      prescribed rod (motionFile): WtrDpth + motion, bathymetry + motion and bathymetry
  !!      without motion give the same free-rod trajectory;
  !!   5. a moored Rigid6 buoy and a moored rod spar in storm seas converge in dt: the
  !!      fairlead-tension std and peak agree within 3 % between dtM = 0.05 s and 0.0125 s, and
  !!      a rod released out of balance at dtM = 0.1 s (sub-stepped) follows the dtM = 0.005 s
  !!      fairlead-tension transient within 2 %;
  !!   6. free bodies and rods start at their static equilibrium (calm water and current): no
  !!      drift or ringing, and TMax = 0 reports the same initial condition; poor deck poses (a
  !!      buoy on an overstretched line, bodies and rods displaced and turned) reach the same
  !!      stable equilibrium, never an unstable one. The rigs of 1-4
  !!      release a body from its deck pose (bodyIC deck).
  !!   7. a rod carried horizontally (drifting, or turning about its pin) onto a bathymetry step
  !!      up is sub-stepped for the contact it reaches within a step.
  !!   8. a floating rod is sub-stepped for its waterplane stiffness, and a rod held by seabed
  !!      friction holds still at a coarse step (the friction damper is implicit).
  USE CableDyn_Precision, ONLY: wp
  USE CableDyn_DeckDriver, ONLY: CD_Run_Deck_Driver, CD_Deck_Equilibrium_Jacobian_Check, CD_DECKDRV_OK
  USE, INTRINSIC :: IEEE_ARITHMETIC, ONLY: IEEE_IS_FINITE
  IMPLICIT NONE

  REAL(wp), PARAMETER :: PI = 3.14159265358979323846_wp
  REAL(wp), PARAMETER :: RHO_W = 1025.0_wp, GRAV = 9.80665_wp
  INTEGER :: nfail

  nfail = 0
  CALL check_rigid6_still_water_drag()
  CALL check_rod_added_mass_periods()
  CALL check_rod_end_coefficients()
  CALL check_floating_can()
  CALL check_cg_pendulum()
  CALL check_rod_distributed_seabed_contact()
  CALL check_prescribed_rod_bathymetry_contact()
  CALL check_storm_dt_convergence()
  CALL check_rod_release_substep_accuracy()
  CALL check_monolithic_large_dt()
  CALL check_monolithic_energy()
  CALL check_equilibrium_jacobian()
  CALL check_equilibrium_seed_robustness()
  CALL check_static_body_start()
  CALL check_bathymetry_reach_substep()
  CALL check_floating_rod_substep()
  CALL check_rod_friction_hold()
  IF (nfail > 0) THEN
    WRITE (*, '(A,I0,A)') 'FAIL: ', nfail, ' body/rod physics check(s) failed'
    ERROR STOP 1
  END IF
  WRITE (*, '(A)') 'PASS: rigid body / rod physics (still-water drag, added mass, seabed contact, bathymetry, '// &
    'storm dt convergence, large-dt monolithic step, energy, static start)'

CONTAINS

  INCLUDE 'nan_max_abs.inc'

  SUBROUTINE require(cond, label)
    LOGICAL, INTENT(IN) :: cond
    CHARACTER(*), INTENT(IN) :: label
    IF (.NOT. cond) THEN
      WRITE (*, '(A,A)') 'MISMATCH: ', TRIM(label)
      nfail = nfail + 1
    END IF
  END SUBROUTINE require

  SUBROUTINE run_deck(path, root, ok)
    !! Run one deck through the public driver entry point and require a converged run.
    CHARACTER(*), INTENT(IN) :: path, root
    LOGICAL, INTENT(OUT) :: ok
    LOGICAL :: conv
    INTEGER :: es
    CHARACTER(512) :: em

    CALL CD_Run_Deck_Driver(path, root, conv, es, em)
    ok = es == CD_DECKDRV_OK .AND. conv
    CALL require(ok, 'deck '//TRIM(path)//' converged: '//TRIM(em))
  END SUBROUTINE run_deck

  SUBROUTINE read_out(path, ncol, dat, ok, min_rows)
    !! Read every data row (time + ncol - 1 channels) of a driver `.out` file into dat(ncol, nrow);
    !! at least min_rows rows (default 2) are required.
    CHARACTER(*), INTENT(IN) :: path
    INTEGER, INTENT(IN) :: ncol
    REAL(wp), ALLOCATABLE, INTENT(OUT) :: dat(:, :)
    LOGICAL, INTENT(OUT) :: ok
    INTEGER, INTENT(IN), OPTIONAL :: min_rows
    INTEGER :: u, ios, nrow, i, nmin
    CHARACTER(1024) :: buf

    ok = .FALSE.
    nmin = 2
    IF (PRESENT(min_rows)) nmin = min_rows
    OPEN (NEWUNIT=u, FILE=path, STATUS='OLD', ACTION='READ', IOSTAT=ios)
    IF (ios /= 0) THEN
      CALL require(.FALSE., 'open '//TRIM(path))
      RETURN
    END IF
    nrow = 0
    DO
      READ (u, '(A)', IOSTAT=ios) buf
      IF (ios /= 0) EXIT
      nrow = nrow + 1
    END DO
    nrow = nrow - 2
    IF (nrow < nmin) THEN
      CLOSE (u)
      CALL require(.FALSE., 'enough rows in '//TRIM(path))
      RETURN
    END IF
    ALLOCATE (dat(ncol, nrow))
    REWIND (u)
    READ (u, '(A)') buf
    READ (u, '(A)') buf
    DO i = 1, nrow
      READ (u, *, IOSTAT=ios) dat(:, i)
      IF (ios /= 0) THEN
        CLOSE (u)
        CALL require(.FALSE., 'parse row of '//TRIM(path))
        RETURN
      END IF
    END DO
    CLOSE (u)
    ok = ALL(IEEE_IS_FINITE(dat))
    CALL require(ok, 'finite rows in '//TRIM(path))
  END SUBROUTINE read_out

  REAL(wp) FUNCTION mean_crossing_period(t, x) RESULT(period)
    !! Oscillation period from the upward crossings of x about its time mean (linear
    !! interpolation between samples); -1 when fewer than three crossings are found.
    REAL(wp), INTENT(IN) :: t(:), x(:)
    REAL(wp) :: xm, t_first, t_last, tc
    INTEGER :: i, ncross

    xm = SUM(x)/REAL(SIZE(x), wp)
    ncross = 0
    t_first = 0.0_wp
    t_last = 0.0_wp
    DO i = 1, SIZE(x) - 1
      IF (x(i) - xm < 0.0_wp .AND. x(i + 1) - xm >= 0.0_wp) THEN
        tc = t(i) - (x(i) - xm)*(t(i + 1) - t(i))/(x(i + 1) - x(i))
        IF (ncross == 0) t_first = tc
        t_last = tc
        ncross = ncross + 1
      END IF
    END DO
    period = -1.0_wp
    IF (ncross >= 3) period = (t_last - t_first)/REAL(ncross - 1, wp)
  END FUNCTION mean_crossing_period

  ! ------------------------------------------------------------------------------------------
  ! 1. Rigid6 still-water drag
  ! ------------------------------------------------------------------------------------------

  SUBROUTINE write_rigid6_deck(path, cda, current)
    !! Submerged net-buoyant Rigid6 buoy on three taut legs, released 1 m off its equilibrium.
    CHARACTER(*), INTENT(IN) :: path, current
    REAL(wp), INTENT(IN) :: cda
    INTEGER :: u, ios

    OPEN (NEWUNIT=u, FILE=path, STATUS='REPLACE', ACTION='WRITE', IOSTAT=ios)
    CALL require(ios == 0, 'create '//path)
    IF (ios /= 0) RETURN
    WRITE (u, '(A)') 'Rigid6 still-water decay'
    WRITE (u, '(A)') '--- LINE TYPES ---'
    WRITE (u, '(A)') 'Name Diam Mass EA BA EI Cdn Cdt Can Cat'
    WRITE (u, '(A)') '(-) (m) (kg/m) (N) (-) (Nm2) (-) (-) (-) (-)'
    WRITE (u, '(A)') 'poly 0.12 15.0 5.0e7 -1.0 0.0 1.2 0.2 1.0 0.0'
    WRITE (u, '(A)') '--- BODIES ---'
    WRITE (u, '(A)') 'ID Type X Y Z Roll Pitch Yaw Mass Vol C33 C44 C55 CdA Ca Ixx Iyy Izz'
    WRITE (u, '(A)') '(-) (-) (m) (m) (m) (deg) (deg) (deg) (kg) (m3) (N/m) (Nm) (Nm) (m2) (-) (kgm2) (kgm2) (kgm2)'
    WRITE (u, '(A,F0.3,A)') '1 Rigid6 1.0 0.0 -20.0 0.0 0.0 0.0 2.0e4 40.0 0.0 0.0 0.0 ', cda, &
      ' 0.5 3.5e4 3.5e4 3.5e4'
    WRITE (u, '(A)') '--- POINTS ---'
    WRITE (u, '(A)') 'ID Type X Y Z Mass Vol CdA Ca'
    WRITE (u, '(A)') '(-) (-) (m) (m) (m) (kg) (m3) (m2) (-)'
    WRITE (u, '(A)') '1 Body1 1.5 0.0 -2.0 0 0 0 0'
    WRITE (u, '(A)') '2 Body1 -0.75 1.299 -2.0 0 0 0 0'
    WRITE (u, '(A)') '3 Body1 -0.75 -1.299 -2.0 0 0 0 0'
    WRITE (u, '(A)') '4 Fixed 40.0 0.0 -100.0 0 0 0 0'
    WRITE (u, '(A)') '5 Fixed -20.0 34.641 -100.0 0 0 0 0'
    WRITE (u, '(A)') '6 Fixed -20.0 -34.641 -100.0 0 0 0 0'
    WRITE (u, '(A)') '--- LINES ---'
    WRITE (u, '(A)') 'ID NodeA NodeB Outputs'
    WRITE (u, '(A)') '(-) (-) (-) (-)'
    WRITE (u, '(A)') '1 1 4 -'
    WRITE (u, '(A)') '2 2 5 -'
    WRITE (u, '(A)') '3 3 6 -'
    WRITE (u, '(A)') '--- SECTIONS ---'
    WRITE (u, '(A)') 'LineID LineType Length NumSegs'
    WRITE (u, '(A)') '(-) (-) (m) (-)'
    WRITE (u, '(A)') '1 poly 86.85 20'
    WRITE (u, '(A)') '2 poly 86.85 20'
    WRITE (u, '(A)') '3 poly 86.85 20'
    WRITE (u, '(A)') '--- OPTIONS ---'
    WRITE (u, '(A)') 'deck bodyIC'
    WRITE (u, '(A)') '9.80665 g'
    WRITE (u, '(A)') '1025.0 rhoW'
    WRITE (u, '(A)') '100.0 WtrDpth'
    WRITE (u, '(A)') '0.01 dtM'
    WRITE (u, '(A)') '10.0 TMax'
    WRITE (u, '(A)') current//' current'
    WRITE (u, '(A)') '--- OUTPUTS ---'
    WRITE (u, '(A)') 'Point1px Point1py Point1pz'
    WRITE (u, '(A)') '--- end ---'
    CLOSE (u)
  END SUBROUTINE write_rigid6_deck

  SUBROUTINE check_rigid6_still_water_drag()
    REAL(wp), ALLOCATABLE :: d_none(:, :), d_zero(:, :), d_nodrag(:, :)
    LOGICAL :: ok1, ok2, ok3
    REAL(wp) :: max_dpos, p2p_drag, p2p_nodrag

    CALL write_rigid6_deck('body_rod_r6_none.dat', 40.0_wp, 'none')
    CALL write_rigid6_deck('body_rod_r6_zero.dat', 40.0_wp, 'uniform 0.0 0.0 0.0')
    CALL write_rigid6_deck('body_rod_r6_nodrag.dat', 0.0_wp, 'none')
    CALL run_deck('body_rod_r6_none.dat', 'body_rod_r6_none', ok1)
    CALL run_deck('body_rod_r6_zero.dat', 'body_rod_r6_zero', ok2)
    CALL run_deck('body_rod_r6_nodrag.dat', 'body_rod_r6_nodrag', ok3)
    IF (.NOT. (ok1 .AND. ok2 .AND. ok3)) RETURN
    CALL read_out('body_rod_r6_none.out', 4, d_none, ok1)
    CALL read_out('body_rod_r6_zero.out', 4, d_zero, ok2)
    CALL read_out('body_rod_r6_nodrag.out', 4, d_nodrag, ok3)
    IF (.NOT. (ok1 .AND. ok2 .AND. ok3)) RETURN
    CALL require(SIZE(d_none, 2) == SIZE(d_zero, 2), 'Rigid6 none/zero-current runs have equal length')
    IF (SIZE(d_none, 2) /= SIZE(d_zero, 2)) RETURN
    ! The body drag is identical in both runs; the remaining difference is the O(dt) line-side
    ! acceleration refresh of an explicit (zero) current, far below the 0.1 m-scale drift the
    ! missing still-water body drag produced.
    max_dpos = nan_max_abs(d_none(2:4, :) - d_zero(2:4, :))
    WRITE (*, '(A,ES12.4,A)') 'Rigid6 still water: max |position(none) - position(zero current)| = ', max_dpos, ' m'
    CALL require(max_dpos < 2.0e-3_wp, 'Rigid6 still-water drag matches an explicit zero current')
    p2p_drag = MAXVAL(d_none(2, :), MASK=d_none(1, :) >= 5.0_wp) - &
               MINVAL(d_none(2, :), MASK=d_none(1, :) >= 5.0_wp)
    p2p_nodrag = MAXVAL(d_nodrag(2, :), MASK=d_nodrag(1, :) >= 5.0_wp) - &
                 MINVAL(d_nodrag(2, :), MASK=d_nodrag(1, :) >= 5.0_wp)
    WRITE (*, '(A,2ES12.4)') 'Rigid6 still water: late surge peak-to-peak CdA=40 / CdA=0 = ', p2p_drag, p2p_nodrag
    CALL require(p2p_drag < 0.95_wp*p2p_nodrag, 'Rigid6 CdA damps the still-water decay')
  END SUBROUTINE check_rigid6_still_water_drag

  ! ------------------------------------------------------------------------------------------
  ! 2. Rod added mass: natural periods
  ! ------------------------------------------------------------------------------------------

  SUBROUTINE write_rod_tether_header(u, title)
    !! Light, undamped, drag-free tethers and a drag-free buoyant rod (d = 0.5 m, 100 kg/m,
    !! Ca = 1.0, CaAx = 0.3), so the free motion is set by the tether stiffness and the inertia.
    INTEGER, INTENT(IN) :: u
    CHARACTER(*), INTENT(IN) :: title
    WRITE (u, '(A)') title
    WRITE (u, '(A)') '--- LINE TYPES ---'
    WRITE (u, '(A)') 'Name Diam Mass EA BA EI Cdn Cdt Can Cat'
    WRITE (u, '(A)') '(-) (m) (kg/m) (N) (-) (Nm2) (-) (-) (-) (-)'
    WRITE (u, '(A)') 'teth 0.02 1.0 1.0e6 0.0 0.0 0.0 0.0 0.0 0.0'
    WRITE (u, '(A)') '--- ROD TYPES ---'
    WRITE (u, '(A)') 'Name Diam Mass Cd Ca CdEnd CaEnd CdAx CaAx'
    WRITE (u, '(A)') '(-) (m) (kg/m) (-) (-) (-) (-) (-) (-)'
    WRITE (u, '(A)') 'cyl 0.5 100.0 0.0 1.0 0.0 0.0 0.0 0.3'
    WRITE (u, '(A)') '--- RODS ---'
    WRITE (u, '(A)') 'ID RodType Type XA YA ZA XB YB ZB NumSegs Outputs'
    WRITE (u, '(A)') '(-) (-) (-) (m) (m) (m) (m) (m) (m) (-) (-)'
  END SUBROUTINE write_rod_tether_header

  SUBROUTINE write_rod_tether_footer(u)
    INTEGER, INTENT(IN) :: u
    WRITE (u, '(A)') '--- SECTIONS ---'
    WRITE (u, '(A)') 'LineID LineType Length NumSegs'
    WRITE (u, '(A)') '(-) (-) (m) (-)'
    WRITE (u, '(A)') '1 teth 10.0 1'
    WRITE (u, '(A)') '2 teth 10.0 1'
    WRITE (u, '(A)') '--- OPTIONS ---'
    WRITE (u, '(A)') 'deck bodyIC'
    WRITE (u, '(A)') '9.80665 g'
    WRITE (u, '(A)') '1025.0 rhoW'
    WRITE (u, '(A)') '50.0 WtrDpth'
    WRITE (u, '(A)') '0.002 dtM'
    WRITE (u, '(A)') '8.0 TMax'
    WRITE (u, '(A)') '--- OUTPUTS ---'
    WRITE (u, '(A)') 'Point1pz Point2pz'
    WRITE (u, '(A)') '--- end ---'
  END SUBROUTINE write_rod_tether_footer

  SUBROUTINE write_rod_period_decks()
    !! Horizontal rod (z = -20) on two vertical 10 m tethers with unequal pre-stretch (heave and
    !! pitch both excited); vertical rod (-25..-15) between a bottom and a top tether (axial heave).
    INTEGER :: u, ios

    OPEN (NEWUNIT=u, FILE='body_rod_hperiod.dat', STATUS='REPLACE', ACTION='WRITE', IOSTAT=ios)
    CALL require(ios == 0, 'create body_rod_hperiod.dat')
    IF (ios /= 0) RETURN
    CALL write_rod_tether_header(u, 'Horizontal tethered rod: heave and pitch periods')
    WRITE (u, '(A)') '1 cyl Free 0.0 0.0 -20.0 10.0 0.0 -20.0 1 -'
    WRITE (u, '(A)') '--- POINTS ---'
    WRITE (u, '(A)') 'ID Type X Y Z Mass Vol CdA Ca'
    WRITE (u, '(A)') '(-) (-) (m) (m) (m) (kg) (m3) (m2) (-)'
    WRITE (u, '(A)') '1 Rod1A 0.0 0.0 -20.0 0 0 0 0'
    WRITE (u, '(A)') '2 Rod1B 10.0 0.0 -20.0 0 0 0 0'
    WRITE (u, '(A)') '3 Fixed 0.0 0.0 -30.045 0 0 0 0'
    WRITE (u, '(A)') '4 Fixed 10.0 0.0 -30.015 0 0 0 0'
    WRITE (u, '(A)') '--- LINES ---'
    WRITE (u, '(A)') 'ID NodeA NodeB Outputs'
    WRITE (u, '(A)') '(-) (-) (-) (-)'
    WRITE (u, '(A)') '1 1 3 -'
    WRITE (u, '(A)') '2 2 4 -'
    CALL write_rod_tether_footer(u)
    CLOSE (u)

    OPEN (NEWUNIT=u, FILE='body_rod_vperiod.dat', STATUS='REPLACE', ACTION='WRITE', IOSTAT=ios)
    CALL require(ios == 0, 'create body_rod_vperiod.dat')
    IF (ios /= 0) RETURN
    CALL write_rod_tether_header(u, 'Vertical tethered rod: axial heave period')
    WRITE (u, '(A)') '1 cyl Free 0.0 0.0 -25.0 0.0 0.0 -15.0 1 -'
    WRITE (u, '(A)') '--- POINTS ---'
    WRITE (u, '(A)') 'ID Type X Y Z Mass Vol CdA Ca'
    WRITE (u, '(A)') '(-) (-) (m) (m) (m) (kg) (m3) (m2) (-)'
    WRITE (u, '(A)') '1 Rod1A 0.0 0.0 -25.0 0 0 0 0'
    WRITE (u, '(A)') '2 Rod1B 0.0 0.0 -15.0 0 0 0 0'
    WRITE (u, '(A)') '3 Fixed 0.0 0.0 -35.10 0 0 0 0'
    WRITE (u, '(A)') '4 Fixed 0.0 0.0 -4.98 0 0 0 0'
    WRITE (u, '(A)') '--- LINES ---'
    WRITE (u, '(A)') 'ID NodeA NodeB Outputs'
    WRITE (u, '(A)') '(-) (-) (-) (-)'
    WRITE (u, '(A)') '1 1 3 -'
    WRITE (u, '(A)') '2 2 4 -'
    CALL write_rod_tether_footer(u)
    CLOSE (u)
  END SUBROUTINE write_rod_period_decks

  SUBROUTINE check_rod_added_mass_periods()
    !! Analytical periods: two tethers of k = EA/L0 = 1e5 N/m each; each one-segment tether
    !! lumps half its mass (5 kg) on the rod end node. Rod: L = 10 m, A = pi d^2/4,
    !! m = 1000 kg, displaced mass m_d = rhoW*A*L.
    !!   horizontal heave (normal):  M = m + Ca m_d + 10,        T = 2 pi sqrt(M/(2k))
    !!   horizontal pitch:           I = m (3 r^2 + L^2)/12 + Ca rhoW A L^3/12 + 2*5*(L/2)^2,
    !!                               T = 2 pi sqrt(I/(2 k (L/2)^2))
    !!   vertical heave (axial):     M = m + CaAx m_d + 10,      T = 2 pi sqrt(M/(2k))
    REAL(wp), PARAMETER :: L = 10.0_wp, DIAM = 0.5_wp, MASS = 1000.0_wp, K = 1.0e5_wp
    REAL(wp), PARAMETER :: CA = 1.0_wp, CA_AX = 0.3_wp, TETHER_NODE_MASS = 5.0_wp
    REAL(wp), PARAMETER :: PERIOD_RTOL = 0.01_wp
    REAL(wp), ALLOCATABLE :: dh(:, :), dv(:, :)
    REAL(wp) :: area, m_d, t_heave, t_pitch, t_axial, i_pitch, got
    LOGICAL :: ok1, ok2

    area = 0.25_wp*PI*DIAM**2
    m_d = RHO_W*area*L
    t_heave = 2.0_wp*PI*SQRT((MASS + CA*m_d + 2.0_wp*TETHER_NODE_MASS)/(2.0_wp*K))
    i_pitch = MASS*(3.0_wp*(0.5_wp*DIAM)**2 + L**2)/12.0_wp + CA*RHO_W*area*L**3/12.0_wp + &
              2.0_wp*TETHER_NODE_MASS*(0.5_wp*L)**2
    t_pitch = 2.0_wp*PI*SQRT(i_pitch/(2.0_wp*K*(0.5_wp*L)**2))
    t_axial = 2.0_wp*PI*SQRT((MASS + CA_AX*m_d + 2.0_wp*TETHER_NODE_MASS)/(2.0_wp*K))

    CALL write_rod_period_decks()
    CALL run_deck('body_rod_hperiod.dat', 'body_rod_hperiod', ok1)
    CALL run_deck('body_rod_vperiod.dat', 'body_rod_vperiod', ok2)
    IF (.NOT. (ok1 .AND. ok2)) RETURN
    CALL read_out('body_rod_hperiod.out', 3, dh, ok1)
    CALL read_out('body_rod_vperiod.out', 3, dv, ok2)
    IF (.NOT. (ok1 .AND. ok2)) RETURN

    got = mean_crossing_period(dh(1, :), 0.5_wp*(dh(2, :) + dh(3, :)))
    WRITE (*, '(A,2F10.5)') 'rod horizontal heave period got/analytical [s]: ', got, t_heave
    CALL require(ABS(got - t_heave) <= PERIOD_RTOL*t_heave, 'rod normal (Ca) heave period')
    got = mean_crossing_period(dh(1, :), (dh(3, :) - dh(2, :))/L)
    WRITE (*, '(A,2F10.5)') 'rod pitch period got/analytical [s]: ', got, t_pitch
    CALL require(ABS(got - t_pitch) <= PERIOD_RTOL*t_pitch, 'rod pitch period includes rotational added mass')
    got = mean_crossing_period(dv(1, :), dv(2, :))
    WRITE (*, '(A,2F10.5)') 'rod vertical (axial) heave period got/analytical [s]: ', got, t_axial
    CALL require(ABS(got - t_axial) <= PERIOD_RTOL*t_axial, 'rod axial (CaAx) heave period')
  END SUBROUTINE check_rod_added_mass_periods

  SUBROUTINE write_rod_end_deck(path, header, units, row)
    !! The vertical tethered rod of write_rod_period_decks with a caller-chosen ROD TYPES header,
    !! units row and data row (empty header/units: the row is omitted).
    CHARACTER(*), INTENT(IN) :: path, header, units, row
    INTEGER :: u, ios

    OPEN (NEWUNIT=u, FILE=path, STATUS='REPLACE', ACTION='WRITE', IOSTAT=ios)
    CALL require(ios == 0, 'create '//path)
    IF (ios /= 0) RETURN
    WRITE (u, '(A)') 'Vertical tethered rod: ROD TYPES end coefficients'
    WRITE (u, '(A)') '--- LINE TYPES ---'
    WRITE (u, '(A)') 'Name Diam Mass EA BA EI Cdn Cdt Can Cat'
    WRITE (u, '(A)') '(-) (m) (kg/m) (N) (-) (Nm2) (-) (-) (-) (-)'
    WRITE (u, '(A)') 'teth 0.02 1.0 1.0e6 0.0 0.0 0.0 0.0 0.0 0.0'
    WRITE (u, '(A)') '--- ROD TYPES ---'
    IF (LEN(header) > 0) WRITE (u, '(A)') header
    IF (LEN(units) > 0) WRITE (u, '(A)') units
    WRITE (u, '(A)') row
    WRITE (u, '(A)') '--- RODS ---'
    WRITE (u, '(A)') 'ID RodType Type XA YA ZA XB YB ZB NumSegs Outputs'
    WRITE (u, '(A)') '(-) (-) (-) (m) (m) (m) (m) (m) (m) (-) (-)'
    WRITE (u, '(A)') '1 cyl Free 0.0 0.0 -25.0 0.0 0.0 -15.0 1 -'
    WRITE (u, '(A)') '--- POINTS ---'
    WRITE (u, '(A)') 'ID Type X Y Z Mass Vol CdA Ca'
    WRITE (u, '(A)') '(-) (-) (m) (m) (m) (kg) (m3) (m2) (-)'
    WRITE (u, '(A)') '1 Rod1A 0.0 0.0 -25.0 0 0 0 0'
    WRITE (u, '(A)') '2 Rod1B 0.0 0.0 -15.0 0 0 0 0'
    WRITE (u, '(A)') '3 Fixed 0.0 0.0 -35.10 0 0 0 0'
    WRITE (u, '(A)') '4 Fixed 0.0 0.0 -4.98 0 0 0 0'
    WRITE (u, '(A)') '--- LINES ---'
    WRITE (u, '(A)') 'ID NodeA NodeB Outputs'
    WRITE (u, '(A)') '(-) (-) (-) (-)'
    WRITE (u, '(A)') '1 1 3 -'
    WRITE (u, '(A)') '2 2 4 -'
    CALL write_rod_tether_footer(u)
    CLOSE (u)
  END SUBROUTINE write_rod_end_deck

  SUBROUTINE check_rod_end_coefficients()
    !! ROD TYPES columns 6-7 are MoorDyn's CdEnd CaEnd, columns 8-9 the optional CableDyn axial
    !! side coefficients CdAx CaAx:
    !!   * the axial heave period of the vertical tethered rod with CaEnd = 3 (CaAx = 0) matches
    !!     M = m + 2 rhoW CaEnd V_end + 10, V_end = (2/3) pi (d/2)^3 (end added mass at both ends);
    !!   * a MoorDyn header, no header at all, and the 9-column row give the same motion;
    !!   * CdEnd = 40 damps the axial motion (axial end drag);
    !!   * a legacy header naming CdAx/CaAx in columns 6-7 is rejected with the migration text.
    REAL(wp), PARAMETER :: DIAM = 0.5_wp, MASS = 1000.0_wp, K = 1.0e5_wp
    REAL(wp), PARAMETER :: CA_END = 3.0_wp, TETHER_NODE_MASS = 5.0_wp, PERIOD_RTOL = 0.01_wp
    CHARACTER(*), PARAMETER :: HDR7 = 'Name Diam Mass Cd Ca CdEnd CaEnd'
    CHARACTER(*), PARAMETER :: HDR9 = 'Name Diam Mass Cd Ca CdEnd CaEnd CdAx CaAx'
    CHARACTER(*), PARAMETER :: UNITS7 = '(-) (m) (kg/m) (-) (-) (-) (-)'
    CHARACTER(*), PARAMETER :: UNITS9 = '(-) (m) (kg/m) (-) (-) (-) (-) (-) (-)'
    REAL(wp), ALLOCATABLE :: d7(:, :), dnone(:, :), d9(:, :), ddrag(:, :)
    REAL(wp) :: v_end, t_axial, got, amp_free, amp_drag
    LOGICAL :: ok1, ok2, ok3, ok4, conv
    INTEGER :: es
    CHARACTER(1024) :: em

    v_end = (2.0_wp/3.0_wp)*PI*(0.5_wp*DIAM)**3
    t_axial = 2.0_wp*PI*SQRT((MASS + 2.0_wp*RHO_W*CA_END*v_end + 2.0_wp*TETHER_NODE_MASS)/(2.0_wp*K))
    CALL write_rod_end_deck('body_rod_end7.dat', HDR7, UNITS7, 'cyl 0.5 100.0 0.0 1.0 0.0 3.0')
    CALL write_rod_end_deck('body_rod_endnohdr.dat', '', '', 'cyl 0.5 100.0 0.0 1.0 0.0 3.0')
    CALL write_rod_end_deck('body_rod_end9.dat', HDR9, UNITS9, 'cyl 0.5 100.0 0.0 1.0 0.0 3.0 0.0 0.0')
    CALL write_rod_end_deck('body_rod_enddrag.dat', HDR7, UNITS7, 'cyl 0.5 100.0 0.0 1.0 40.0 3.0')
    CALL run_deck('body_rod_end7.dat', 'body_rod_end7', ok1)
    CALL run_deck('body_rod_endnohdr.dat', 'body_rod_endnohdr', ok2)
    CALL run_deck('body_rod_end9.dat', 'body_rod_end9', ok3)
    CALL run_deck('body_rod_enddrag.dat', 'body_rod_enddrag', ok4)
    IF (ok1 .AND. ok2 .AND. ok3 .AND. ok4) THEN
      CALL read_out('body_rod_end7.out', 3, d7, ok1)
      CALL read_out('body_rod_endnohdr.out', 3, dnone, ok2)
      CALL read_out('body_rod_end9.out', 3, d9, ok3)
      CALL read_out('body_rod_enddrag.out', 3, ddrag, ok4)
    END IF
    IF (ok1 .AND. ok2 .AND. ok3 .AND. ok4) THEN
      got = mean_crossing_period(d7(1, :), d7(2, :))
      WRITE (*, '(A,2F10.5)') 'rod vertical heave period with CaEnd got/analytical [s]: ', got, t_axial
      CALL require(ABS(got - t_axial) <= PERIOD_RTOL*t_axial, 'rod end added mass (CaEnd) heave period')
      CALL require(SIZE(dnone, 2) == SIZE(d7, 2) .AND. SIZE(d9, 2) == SIZE(d7, 2), &
                   'ROD TYPES header variants give equal-length runs')
      IF (SIZE(dnone, 2) == SIZE(d7, 2) .AND. SIZE(d9, 2) == SIZE(d7, 2)) THEN
        CALL require(nan_max_abs(dnone - d7) <= 0.0_wp, 'ROD TYPES without a header reads columns 6-7 as CdEnd CaEnd')
        CALL require(nan_max_abs(d9 - d7) <= 0.0_wp, '9-column ROD TYPES row equals the 7-column MoorDyn row')
      END IF
      amp_free = MAXVAL(ABS(d7(2, :) - SUM(d7(2, :))/SIZE(d7, 2)), MASK=d7(1, :) >= 6.0_wp)
      amp_drag = MAXVAL(ABS(ddrag(2, :) - SUM(ddrag(2, :))/SIZE(ddrag, 2)), MASK=ddrag(1, :) >= 6.0_wp)
      WRITE (*, '(A,2ES12.4)') 'rod late axial amplitude CdEnd = 0 / 40 [m]: ', amp_free, amp_drag
      CALL require(amp_drag < 0.8_wp*amp_free, 'rod axial end drag (CdEnd) damps the heave motion')
    END IF

    CALL write_rod_end_deck('body_rod_endlegacy.dat', 'Name Diam Mass Cd Ca CdAx CaAx', UNITS7, &
                            'cyl 0.5 100.0 0.0 1.0 0.0 3.0')
    CALL CD_Run_Deck_Driver('body_rod_endlegacy.dat', 'body_rod_endlegacy', conv, es, em)
    CALL require(es /= CD_DECKDRV_OK .AND. INDEX(em, 'CdEnd CaEnd CdAx CaAx') > 0 .AND. &
                 INDEX(em, 'columns 6-7') > 0, 'legacy ROD TYPES header (CdAx CaAx in columns 6-7) is rejected '// &
                 'with the migration message: '//TRIM(em))
  END SUBROUTINE check_rod_end_coefficients

  SUBROUTINE write_floating_can(path, caend, body_ic, z_a)
    !! A squat floating can (rod d = 10 m, L = 6 m, 1407.3 kg/m: draft 4.2 m, GM = 0.59 m) on two
    !! nearly weightless slack lines, End A at z = z_a.
    CHARACTER(*), INTENT(IN) :: path, body_ic
    REAL(wp), INTENT(IN) :: caend, z_a
    INTEGER :: u, ios

    OPEN (NEWUNIT=u, FILE=path, STATUS='REPLACE', ACTION='WRITE', IOSTAT=ios)
    CALL require(ios == 0, 'create '//path)
    IF (ios /= 0) RETURN
    WRITE (u, '(A)') 'Floating can: draft and heave period'
    WRITE (u, '(A)') '--- LINE TYPES ---'
    WRITE (u, '(A)') 'Name Diam Mass EA BA EI Cdn Cdt Can Cat'
    WRITE (u, '(A)') '(-) (m) (kg/m) (N) (-) (Nm2) (-) (-) (-) (-)'
    WRITE (u, '(A)') 'thread 0.001 0.001 1.0e3 0.0 0.0 0.0 0.0 0.0 0.0'
    WRITE (u, '(A)') '--- ROD TYPES ---'
    WRITE (u, '(A)') 'Name Diam Mass Cd Ca CdEnd CaEnd'
    WRITE (u, '(A)') '(-) (m) (kg/m) (-) (-) (-) (-)'
    WRITE (u, '(A,F0.3)') 'can 10.0 56353.0 0.0 1.0 0.0 ', caend
    WRITE (u, '(A)') '--- RODS ---'
    WRITE (u, '(A)') 'ID RodType Type XA YA ZA XB YB ZB NumSegs Outputs'
    WRITE (u, '(A)') '(-) (-) (-) (m) (m) (m) (m) (m) (m) (-) (-)'
    WRITE (u, '(A,F0.4,A,F0.4,A)') '1 can Free 0.0 0.0 ', z_a, ' 0.0 0.0 ', z_a + 6.0_wp, ' 6 -'
    WRITE (u, '(A)') '--- POINTS ---'
    WRITE (u, '(A)') 'ID Type X Y Z Mass Vol CdA Ca'
    WRITE (u, '(A)') '(-) (-) (m) (m) (m) (kg) (m3) (m2) (-)'
    WRITE (u, '(A)') '1 Rod1A 0.0 0.0 0.0 0 0 0 0'
    WRITE (u, '(A)') '2 Rod1B 0.0 0.0 0.0 0 0 0 0'
    WRITE (u, '(A)') '3 Fixed 5.0 0.0 -50.0 0 0 0 0'
    WRITE (u, '(A)') '4 Fixed -5.0 0.0 -50.0 0 0 0 0'
    WRITE (u, '(A)') '--- LINES ---'
    WRITE (u, '(A)') 'ID NodeA NodeB Outputs'
    WRITE (u, '(A)') '(-) (-) (-) (-)'
    WRITE (u, '(A)') '1 1 3 -'
    WRITE (u, '(A)') '2 2 4 -'
    WRITE (u, '(A)') '--- SECTIONS ---'
    WRITE (u, '(A)') 'LineID LineType Length NumSegs'
    WRITE (u, '(A)') '(-) (-) (m) (-)'
    WRITE (u, '(A)') '1 thread 60.0 10'
    WRITE (u, '(A)') '2 thread 66.0 10'
    WRITE (u, '(A)') '--- OPTIONS ---'
    WRITE (u, '(A)') body_ic//' bodyIC'
    WRITE (u, '(A)') '9.80665 g'
    WRITE (u, '(A)') '1025.0 rhoW'
    WRITE (u, '(A)') '50.0 WtrDpth'
    WRITE (u, '(A)') '0.02 dtM'
    WRITE (u, '(A)') '20.0 TMax'
    WRITE (u, '(A)') '--- OUTPUTS ---'
    WRITE (u, '(A)') 'Point1pz Point2pz'
    WRITE (u, '(A)') '--- end ---'
    CLOSE (u)
  END SUBROUTINE write_floating_can

  SUBROUTINE check_floating_can()
    !! A surface-piercing rod floats at the draft rho A draft = m (line weight < 1e-5 m of draft)
    !! from the static initial condition, and heaves with omega^2 = rhoW g A/(m + a33), where
    !! a33 = rhoW CaEnd (2/3) pi r^3 is the end added mass of the submerged End A only.
    REAL(wp), PARAMETER :: DIAM = 10.0_wp, MASS_PER_L = 56353.0_wp, L = 6.0_wp
    REAL(wp), ALLOCATABLE :: d(:, :)
    REAL(wp) :: area, draft, m, a33, t_ref, got, caend
    LOGICAL :: ok
    INTEGER :: k

    area = 0.25_wp*PI*DIAM**2
    m = MASS_PER_L*L
    draft = m/(RHO_W*area)
    CALL write_floating_can('body_rod_can_static.dat', 0.0_wp, 'static', -3.0_wp)
    CALL run_deck('body_rod_can_static.dat', 'body_rod_can_static', ok)
    IF (ok) CALL read_out('body_rod_can_static.out', 3, d, ok)
    IF (ok) THEN
      WRITE (*, '(A,2F12.6)') 'floating can draft got/analytic [m]: ', -d(2, 1), draft
      CALL require(ABS(-d(2, 1) - draft) <= 1.0e-4_wp, 'floating can static draft rho A draft = m')
      CALL require(nan_max_abs(d(2, :) - d(2, 1)) <= 1.0e-4_wp, 'floating can holds its static draft')
    END IF
    DO k = 1, 2
      caend = 0.6_wp*REAL(k - 1, wp)
      a33 = RHO_W*caend*(2.0_wp/3.0_wp)*PI*(0.5_wp*DIAM)**3
      t_ref = 2.0_wp*PI*SQRT((m + a33)/(RHO_W*GRAV*area))
      CALL write_floating_can('body_rod_can_heave.dat', caend, 'deck', -draft - 0.2_wp)
      CALL run_deck('body_rod_can_heave.dat', 'body_rod_can_heave', ok)
      IF (ok) CALL read_out('body_rod_can_heave.out', 3, d, ok)
      IF (.NOT. ok) CYCLE
      got = mean_crossing_period(d(1, :), d(2, :))
      WRITE (*, '(A,F4.1,A,2F10.5)') 'floating can heave period CaEnd = ', caend, ' got/analytic [s]: ', got, t_ref
      CALL require(ABS(got - t_ref) <= 0.01_wp*t_ref, 'floating can heave period sqrt(rho g A/(m + a33))')
    END DO
  END SUBROUTINE check_floating_can

  SUBROUTINE write_cg_pendulum(path, cg, pitch_deg, body_ic, marker_len)
    !! A 1000 kg Rigid6 body without volume or hydrodynamic coefficients (MoorDyn 14-column row,
    !! CG offset cg, I = 100 kg m^2 about the CG) hung by its reference point from a tripod of
    !! short stiff lines (a fixed pivot); Body1 point 2 marks the CG, joined to the reference
    !! point by an almost weightless slack marker line (both ends on the body: no net load).
    CHARACTER(*), INTENT(IN) :: path, cg, body_ic
    REAL(wp), INTENT(IN) :: pitch_deg, marker_len
    INTEGER :: u, ios

    OPEN (NEWUNIT=u, FILE=path, STATUS='REPLACE', ACTION='WRITE', IOSTAT=ios)
    CALL require(ios == 0, 'create '//path)
    IF (ios /= 0) RETURN
    WRITE (u, '(A)') 'Rigid6 compound pendulum with a CG offset'
    WRITE (u, '(A)') '--- LINE TYPES ---'
    WRITE (u, '(A)') 'Name Diam Mass EA BA EI Cdn Cdt Can Cat'
    WRITE (u, '(A)') '(-) (m) (kg/m) (N) (-) (Nm2) (-) (-) (-) (-)'
    WRITE (u, '(A)') 'rod 0.001 0.01 1.0e9 0.0 0.0 0.0 0.0 0.0 0.0'
    WRITE (u, '(A)') 'marker 0.00001 0.000001 1.0 0.0 0.0 0.0 0.0 0.0 0.0'
    WRITE (u, '(A)') '--- BODIES ---'
    WRITE (u, '(A)') 'ID Attachment X0 Y0 Z0 r0 p0 y0 Mass CG* I* Volume CdA* Ca*'
    WRITE (u, '(A)') '(#) (-) (m) (m) (m) (deg) (deg) (deg) (kg) (m) (kg-m^2) (m^3) (m^2) (-)'
    WRITE (u, '(A,F0.4,A,A,A)') '1 Free 0 0 -10 0 ', pitch_deg, ' 0 1000 ', cg, ' 100 0 0 0'
    WRITE (u, '(A)') '--- POINTS ---'
    WRITE (u, '(A)') 'ID Type X Y Z Mass Vol CdA Ca'
    WRITE (u, '(A)') '(-) (-) (m) (m) (m) (kg) (m3) (m2) (-)'
    WRITE (u, '(A)') '1 Body1 0.0 0.0 0.0 0 0 0 0'
    WRITE (u, '(A,A,A)') '2 Body1 ', TRIM(bar_to_space(cg)), ' 0 0 0 0'
    WRITE (u, '(A)') '3 Fixed 0.5 0.0 -9.5 0 0 0 0'
    WRITE (u, '(A)') '4 Fixed -0.25 0.4330127019 -9.5 0 0 0 0'
    WRITE (u, '(A)') '5 Fixed -0.25 -0.4330127019 -9.5 0 0 0 0'
    WRITE (u, '(A)') '--- LINES ---'
    WRITE (u, '(A)') 'ID NodeA NodeB Outputs'
    WRITE (u, '(A)') '(-) (-) (-) (-)'
    WRITE (u, '(A)') '1 1 3 -'
    WRITE (u, '(A)') '2 2 1 -'
    WRITE (u, '(A)') '3 1 4 -'
    WRITE (u, '(A)') '4 1 5 -'
    WRITE (u, '(A)') '--- SECTIONS ---'
    WRITE (u, '(A)') 'LineID LineType Length NumSegs'
    WRITE (u, '(A)') '(-) (-) (m) (-)'
    WRITE (u, '(A)') '1 rod 0.70710351 1'
    WRITE (u, '(A)') '3 rod 0.70710351 1'
    WRITE (u, '(A)') '4 rod 0.70710351 1'
    WRITE (u, '(A,F0.6,A)') '2 marker ', marker_len, ' 1'
    WRITE (u, '(A)') '--- OPTIONS ---'
    WRITE (u, '(A)') body_ic//' bodyIC'
    WRITE (u, '(A)') '9.80665 g'
    WRITE (u, '(A)') '1025.0 rhoW'
    WRITE (u, '(A)') '50.0 WtrDpth'
    WRITE (u, '(A)') '0.005 dtM'
    WRITE (u, '(A)') '15.0 TMax'
    WRITE (u, '(A)') '--- OUTPUTS ---'
    WRITE (u, '(A)') 'Point1px Point1pz Point2px Point2pz'
    WRITE (u, '(A)') '--- end ---'
    CLOSE (u)
  END SUBROUTINE write_cg_pendulum

  FUNCTION bar_to_space(s) RESULT(t)
    CHARACTER(*), INTENT(IN) :: s
    CHARACTER(LEN(s)) :: t
    INTEGER :: k
    t = s
    DO k = 1, LEN(t)
      IF (t(k:k) == '|') t(k:k) = ' '
    END DO
  END FUNCTION bar_to_space

  SUBROUTINE check_cg_pendulum()
    !! The weight acts at the centre of gravity: hung by its reference point, a body with the CG
    !! 1 m aside and 2 m below settles with the CG under the pivot (static tilt atan(1/2)), and a
    !! body with the CG 2 m below swings with the compound-pendulum period
    !! 2 pi sqrt((I_cg + m d^2)/(m g d)) (1 + theta0^2/16 at amplitude theta0).
    REAL(wp), ALLOCATABLE :: d(:, :)
    REAL(wp) :: t_ref, got, th0
    LOGICAL :: ok

    CALL write_cg_pendulum('body_rod_cg_static.dat', '1|0|-2', 0.0_wp, 'static', SQRT(5.0_wp))
    CALL run_deck('body_rod_cg_static.dat', 'body_rod_cg_static', ok)
    IF (ok) CALL read_out('body_rod_cg_static.out', 5, d, ok)
    IF (ok) THEN
      WRITE (*, '(A,2ES12.4)') 'CG-offset static: CG horizontal offset from the pivot [m], tilt error [rad]: ', &
        d(4, 1) - d(2, 1), ATAN2(d(4, 1) - d(2, 1), d(3, 1) - d(5, 1))
      CALL require(ABS(ATAN2(d(4, 1) - d(2, 1), d(3, 1) - d(5, 1))) <= 1.0e-8_wp, &
                   'CG-offset body settles with its CG under the pivot (static tilt to 1e-8 rad)')
    END IF
    th0 = 5.0_wp*PI/180.0_wp
    t_ref = 2.0_wp*PI*SQRT((100.0_wp + 1000.0_wp*4.0_wp)/(1000.0_wp*GRAV*2.0_wp))*(1.0_wp + th0*th0/16.0_wp)
    CALL write_cg_pendulum('body_rod_cg_swing.dat', '0|0|-2', 5.0_wp, 'deck', 2.0_wp)
    CALL run_deck('body_rod_cg_swing.dat', 'body_rod_cg_swing', ok)
    IF (ok) CALL read_out('body_rod_cg_swing.out', 5, d, ok)
    IF (ok) THEN
      got = mean_crossing_period(d(1, :), d(4, :) - d(2, :))
      WRITE (*, '(A,2F10.5)') 'CG-offset compound pendulum period got/analytic [s]: ', got, t_ref
      CALL require(ABS(got - t_ref) <= 0.005_wp*t_ref, 'CG-offset compound pendulum period')
    END IF
  END SUBROUTINE check_cg_pendulum

  ! ------------------------------------------------------------------------------------------
  ! 3. Rod distributed seabed contact
  ! ------------------------------------------------------------------------------------------

  SUBROUTINE check_rod_distributed_seabed_contact()
    !! A heavy rod (d = 0.5 m, 500 kg/m, L = 10 m) released slightly tilted just above a flat
    !! bed settles flat. Its submerged weight is carried by kBot*d*L plus the seabed springs of
    !! the two attached line-end nodes, all per unit contact area. A line-end node's tributary
    !! length is at most one segment (kBot*d_line*L0_seg), so the penetration is bracketed by
    !! W_sub/(kBot*(d*L + 2*d_line*L0_seg)) and W_sub/(kBot*d*L).
    REAL(wp), PARAMETER :: KBOT = 1.0e5_wp, DIAM = 0.5_wp, L = 10.0_wp, MASS_PER_L = 500.0_wp
    REAL(wp), PARAMETER :: LINE_DIAM = 0.02_wp, LINE_SEG = 5.0_wp
    REAL(wp), ALLOCATABLE :: d(:, :)
    REAL(wp) :: w_sub, pen_lo, pen_hi, pen_a, pen_b
    INTEGER :: u, ios, n
    LOGICAL :: ok

    OPEN (NEWUNIT=u, FILE='body_rod_bed.dat', STATUS='REPLACE', ACTION='WRITE', IOSTAT=ios)
    CALL require(ios == 0, 'create body_rod_bed.dat')
    IF (ios /= 0) RETURN
    WRITE (u, '(A)') 'Heavy rod settling onto a flat seabed'
    WRITE (u, '(A)') '--- LINE TYPES ---'
    WRITE (u, '(A)') 'Name Diam Mass EA BA EI Cdn Cdt Can Cat'
    WRITE (u, '(A)') '(-) (m) (kg/m) (N) (-) (Nm2) (-) (-) (-) (-)'
    WRITE (u, '(A)') 'teth 0.02 1.0 1.0e6 0.0 0.0 0.0 0.0 0.0 0.0'
    WRITE (u, '(A)') '--- ROD TYPES ---'
    WRITE (u, '(A)') 'Name Diam Mass Cd Ca CdEnd CaEnd CdAx CaAx'
    WRITE (u, '(A)') '(-) (m) (kg/m) (-) (-) (-) (-) (-) (-)'
    WRITE (u, '(A)') 'cyl 0.5 500.0 1.0 1.0 0.0 0.0 0.2 0.3'
    WRITE (u, '(A)') '--- RODS ---'
    WRITE (u, '(A)') 'ID RodType Type XA YA ZA XB YB ZB NumSegs Outputs'
    WRITE (u, '(A)') '(-) (-) (-) (m) (m) (m) (m) (m) (m) (-) (-)'
    WRITE (u, '(A)') '1 cyl Free 0.0 0.0 -49.9 10.0 0.0 -50.0 1 -'
    WRITE (u, '(A)') '--- POINTS ---'
    WRITE (u, '(A)') 'ID Type X Y Z Mass Vol CdA Ca'
    WRITE (u, '(A)') '(-) (-) (m) (m) (m) (kg) (m3) (m2) (-)'
    WRITE (u, '(A)') '1 Rod1A 0.0 0.0 -49.9 0 0 0 0'
    WRITE (u, '(A)') '2 Rod1B 10.0 0.0 -50.0 0 0 0 0'
    WRITE (u, '(A)') '3 Fixed -20.02 0.0 -50.0 0 0 0 0'
    WRITE (u, '(A)') '4 Fixed 30.02 0.0 -50.0 0 0 0 0'
    WRITE (u, '(A)') '--- LINES ---'
    WRITE (u, '(A)') 'ID NodeA NodeB Outputs'
    WRITE (u, '(A)') '(-) (-) (-) (-)'
    WRITE (u, '(A)') '1 1 3 -'
    WRITE (u, '(A)') '2 2 4 -'
    WRITE (u, '(A)') '--- SECTIONS ---'
    WRITE (u, '(A)') 'LineID LineType Length NumSegs'
    WRITE (u, '(A)') '(-) (-) (m) (-)'
    WRITE (u, '(A)') '1 teth 20.0 4'
    WRITE (u, '(A)') '2 teth 20.0 4'
    WRITE (u, '(A)') '--- OPTIONS ---'
    WRITE (u, '(A)') '9.80665 g'
    WRITE (u, '(A)') '1025.0 rhoW'
    WRITE (u, '(A)') '50.0 WtrDpth'
    WRITE (u, '(A)') '1.0e5 kBot'
    WRITE (u, '(A)') '1.0e4 cBot'
    WRITE (u, '(A)') '0.005 dtM'
    WRITE (u, '(A)') '10.0 TMax'
    WRITE (u, '(A)') '--- OUTPUTS ---'
    WRITE (u, '(A)') 'Point1pz Point2pz'
    WRITE (u, '(A)') '--- end ---'
    CLOSE (u)
    CALL run_deck('body_rod_bed.dat', 'body_rod_bed', ok)
    IF (.NOT. ok) RETURN
    CALL read_out('body_rod_bed.out', 3, d, ok)
    IF (.NOT. ok) RETURN
    n = SIZE(d, 2)
    w_sub = (MASS_PER_L - RHO_W*0.25_wp*PI*DIAM**2)*L*GRAV
    pen_lo = w_sub/(KBOT*(DIAM*L + 2.0_wp*LINE_DIAM*LINE_SEG))
    pen_hi = w_sub/(KBOT*DIAM*L)
    pen_a = -50.0_wp - d(2, n)
    pen_b = -50.0_wp - d(3, n)
    WRITE (*, '(A,4ES13.5)') 'rod on seabed: penetration A/B and bracket [m]: ', pen_a, pen_b, pen_lo, pen_hi
    CALL require(pen_a >= 0.999_wp*pen_lo .AND. pen_a <= 1.001_wp*pen_hi, &
                 'rod seabed penetration uses kBot per unit contact area (kBot*d*L)')
    CALL require(ABS(pen_a - pen_b) <= 1.0e-3_wp*pen_hi, &
                 'distributed rod contact moments settle the rod flat on the bed')
  END SUBROUTINE check_rod_distributed_seabed_contact

  ! ------------------------------------------------------------------------------------------
  ! 4. Prescribed rod + bathymetry: the free rod keeps its seabed contact
  ! ------------------------------------------------------------------------------------------

  SUBROUTINE write_rod_bathy_deck(path, seabed_row, rod2_type, motion_row)
    !! Heavy free rod (Rod 1) released 1 m above a 50 m bed next to a second rod (Rod 2) that is
    !! either prescribed (Coupled + motionFile) or Fixed. seabed_row selects WtrDpth or
    !! bathymetryFile; motion_row is the motionFile OPTIONS row or blank.
    CHARACTER(*), INTENT(IN) :: path, seabed_row, rod2_type, motion_row
    INTEGER :: u, ios

    OPEN (NEWUNIT=u, FILE=path, STATUS='REPLACE', ACTION='WRITE', IOSTAT=ios)
    CALL require(ios == 0, 'create '//path)
    IF (ios /= 0) RETURN
    WRITE (u, '(A)') 'Free heavy rod settling onto the seabed next to a second rod'
    WRITE (u, '(A)') '--- LINE TYPES ---'
    WRITE (u, '(A)') 'Name Diam Mass EA BA EI Cdn Cdt Can Cat'
    WRITE (u, '(A)') '(-) (m) (kg/m) (N) (-) (Nm2) (-) (-) (-) (-)'
    WRITE (u, '(A)') 'poly 0.10 10.0 2.0e7 -1.0 0.0 1.2 0.2 1.0 0.0'
    WRITE (u, '(A)') '--- ROD TYPES ---'
    WRITE (u, '(A)') 'Name Diam Mass Cd Ca CdEnd CaEnd CdAx CaAx'
    WRITE (u, '(A)') '(-) (m) (kg/m) (-) (-) (-) (-) (-) (-)'
    WRITE (u, '(A)') 'heavy 0.5 3000.0 0.8 1.0 0.0 0.0 0.2 0.0'
    WRITE (u, '(A)') '--- RODS ---'
    WRITE (u, '(A)') 'ID RodType Type XA YA ZA XB YB ZB NumSegs Outputs'
    WRITE (u, '(A)') '(-) (-) (-) (m) (m) (m) (m) (m) (m) (-) (-)'
    WRITE (u, '(A)') '1 heavy Free 0.0 0.0 -49.0 10.0 0.0 -49.0 1 -'
    WRITE (u, '(A)') '2 heavy '//rod2_type//' 0.0 50.0 -30.0 10.0 50.0 -30.0 1 -'
    WRITE (u, '(A)') '--- POINTS ---'
    WRITE (u, '(A)') 'ID Type X Y Z Mass Vol CdA Ca'
    WRITE (u, '(A)') '(-) (-) (m) (m) (m) (kg) (m3) (m2) (-)'
    WRITE (u, '(A)') '1 Rod1A 0.0 0.0 -49.0 0 0 0 0'
    WRITE (u, '(A)') '2 Rod1B 10.0 0.0 -49.0 0 0 0 0'
    WRITE (u, '(A)') '3 Rod2A 0.0 50.0 -30.0 0 0 0 0'
    WRITE (u, '(A)') '4 Rod2B 10.0 50.0 -30.0 0 0 0 0'
    WRITE (u, '(A)') '5 Fixed -20.0 0.0 -50.0 0 0 0 0'
    WRITE (u, '(A)') '6 Fixed 30.0 0.0 -50.0 0 0 0 0'
    WRITE (u, '(A)') '7 Fixed -20.0 50.0 -50.0 0 0 0 0'
    WRITE (u, '(A)') '8 Fixed 30.0 50.0 -50.0 0 0 0 0'
    WRITE (u, '(A)') '--- LINES ---'
    WRITE (u, '(A)') 'ID NodeA NodeB Outputs'
    WRITE (u, '(A)') '(-) (-) (-) (-)'
    WRITE (u, '(A)') '1 1 5 -'
    WRITE (u, '(A)') '2 2 6 -'
    WRITE (u, '(A)') '3 3 7 -'
    WRITE (u, '(A)') '4 4 8 -'
    WRITE (u, '(A)') '--- SECTIONS ---'
    WRITE (u, '(A)') 'LineID LineType Length NumSegs'
    WRITE (u, '(A)') '(-) (-) (m) (-)'
    WRITE (u, '(A)') '1 poly 20.0 10'
    WRITE (u, '(A)') '2 poly 20.0 10'
    WRITE (u, '(A)') '3 poly 28.2 10'
    WRITE (u, '(A)') '4 poly 28.2 10'
    WRITE (u, '(A)') '--- OPTIONS ---'
    WRITE (u, '(A)') 'deck bodyIC'
    WRITE (u, '(A)') '9.80665 g'
    WRITE (u, '(A)') '1025.0 rhoW'
    WRITE (u, '(A)') seabed_row
    WRITE (u, '(A)') '1.0e5 kBot'
    WRITE (u, '(A)') '1.0e4 cBot'
    WRITE (u, '(A)') '0.01 dtM'
    WRITE (u, '(A)') '2.0 TMax'
    IF (LEN_TRIM(motion_row) > 0) WRITE (u, '(A)') motion_row
    WRITE (u, '(A)') '--- OUTPUTS ---'
    WRITE (u, '(A)') 'Point1pz Point2pz'
    WRITE (u, '(A)') '--- end ---'
    CLOSE (u)
  END SUBROUTINE write_rod_bathy_deck

  SUBROUTINE check_prescribed_rod_bathymetry_contact()
    REAL(wp), ALLOCATABLE :: da(:, :), db(:, :), dc(:, :)
    INTEGER :: u, ios, it, ip
    REAL(wp) :: t
    LOGICAL :: ok1, ok2, ok3
    REAL(wp), PARAMETER :: PX(4) = [0.0_wp, 10.0_wp, 0.0_wp, 10.0_wp]
    REAL(wp), PARAMETER :: PY(4) = [0.0_wp, 0.0_wp, 50.0_wp, 50.0_wp]
    REAL(wp), PARAMETER :: PZ(4) = [-49.0_wp, -49.0_wp, -30.0_wp, -30.0_wp]

    ! Flat 50 m structured bathymetry covering the deck.
    OPEN (NEWUNIT=u, FILE='body_rod_bathy50.xyz', STATUS='REPLACE', ACTION='WRITE', IOSTAT=ios)
    CALL require(ios == 0, 'create body_rod_bathy50.xyz')
    IF (ios /= 0) RETURN
    WRITE (u, '(A)') '-100.0 -100.0 50.0'
    WRITE (u, '(A)') '100.0 -100.0 50.0'
    WRITE (u, '(A)') '-100.0 100.0 50.0'
    WRITE (u, '(A)') '100.0 100.0 50.0'
    CLOSE (u)
    ! Stationary prescribed motion for every rod end point on the dtM grid.
    OPEN (NEWUNIT=u, FILE='body_rod_motion.txt', STATUS='REPLACE', ACTION='WRITE', IOSTAT=ios)
    CALL require(ios == 0, 'create body_rod_motion.txt')
    IF (ios /= 0) RETURN
    WRITE (u, '(A)') '# time id x y z vx vy vz ax ay az'
    DO it = 0, 200
      t = 0.01_wp*REAL(it, wp)
      DO ip = 1, 4
        WRITE (u, '(F0.2,1X,I0,3(1X,F0.2),A)') t, ip, PX(ip), PY(ip), PZ(ip), ' 0 0 0 0 0 0'
      END DO
    END DO
    CLOSE (u)
    CALL write_rod_bathy_deck('body_rod_bathy_a.dat', '50.0 WtrDpth', 'Coupled', 'body_rod_motion.txt motionFile')
    CALL write_rod_bathy_deck('body_rod_bathy_b.dat', 'body_rod_bathy50.xyz bathymetryFile', 'Coupled', &
                              'body_rod_motion.txt motionFile')
    ! a motionFile deck keeps the staggered scheme: the Fixed-rod twin selects it too, so the three
    ! runs differ only in the seabed representation
    CALL write_rod_bathy_deck('body_rod_bathy_c.dat', 'body_rod_bathy50.xyz bathymetryFile', 'Fixed', &
                              'staggered bodyScheme')
    CALL run_deck('body_rod_bathy_a.dat', 'body_rod_bathy_a', ok1)
    CALL run_deck('body_rod_bathy_b.dat', 'body_rod_bathy_b', ok2)
    CALL run_deck('body_rod_bathy_c.dat', 'body_rod_bathy_c', ok3)
    IF (.NOT. (ok1 .AND. ok2 .AND. ok3)) RETURN
    CALL read_out('body_rod_bathy_a.out', 3, da, ok1)
    CALL read_out('body_rod_bathy_b.out', 3, db, ok2)
    CALL read_out('body_rod_bathy_c.out', 3, dc, ok3)
    IF (.NOT. (ok1 .AND. ok2 .AND. ok3)) RETURN
    CALL require(SIZE(da, 2) == SIZE(db, 2) .AND. SIZE(db, 2) == SIZE(dc, 2), &
                 'rod bathymetry cases have equal length')
    IF (.NOT. (SIZE(da, 2) == SIZE(db, 2) .AND. SIZE(db, 2) == SIZE(dc, 2))) RETURN
    WRITE (*, '(A,3F12.6)') 'free rod End A final z (WtrDpth+motion / bathy+motion / bathy fixed): ', &
      da(2, SIZE(da, 2)), db(2, SIZE(db, 2)), dc(2, SIZE(dc, 2))
    CALL require(nan_max_abs(db(2:3, :) - da(2:3, :)) <= 1.0e-9_wp, &
                 'prescribed-rod deck: bathymetryFile contact matches WtrDpth contact')
    CALL require(nan_max_abs(db(2:3, :) - dc(2:3, :)) <= 1.0e-9_wp, &
                 'bathymetryFile rod contact is the same with and without a motionFile')
    ! The rod lands at ~0.6 s, stays above -51.5 m and rebounds by more than 0.5 m; a rod that
    ! has lost its seabed contact sinks below -53 m onto its lines.
    CALL require(db(2, SIZE(db, 2)) > MINVAL(db(2, :)) + 0.5_wp .AND. MINVAL(db(2, :)) > -51.5_wp, &
                 'free rod rebounds from the bathymetry seabed')
  END SUBROUTINE check_prescribed_rod_bathymetry_contact

  ! ------------------------------------------------------------------------------------------
  ! 5. Storm-sea dt convergence of Rigid6 and rod moorings
  ! ------------------------------------------------------------------------------------------

  SUBROUTINE write_storm_deck(path, body, sea, dtm, tmax, release, pose, extra, undamped)
    !! The examples/rigid6_buoy.dat (body = 'rigid6') or examples/rod_moored_spar.dat
    !! (body = 'rod') mooring in a storm sea: sea = 'js14' (JONSWAP Hs 14 m, Tp 16 s, gamma 2,
    !! 30 deg, with a 1.5/0.5 m/s current) or 'airy12' (Airy 12 m, 14 s), or without waves:
    !! 'cur' (the 1.5/0.5 m/s current only), 'cur05' (0.5 m/s in +X) or 'calm'. 40 s (or tmax)
    !! at dtM = dtm; release = .TRUE. starts the body from its deck pose (bodyIC deck). pose
    !! replaces the deck pose: Rigid6 X Y Z Roll Pitch Yaw, or the rod's end A and end B. extra
    !! appends one OPTIONS row; undamped (Rigid6 only) removes every drag and damping term (line
    !! BA and Cd, body CdA, seabed damping).
    CHARACTER(*), INTENT(IN) :: path, body, sea
    REAL(wp), INTENT(IN) :: dtm
    REAL(wp), INTENT(IN), OPTIONAL :: tmax, pose(6)
    LOGICAL, INTENT(IN), OPTIONAL :: release, undamped
    CHARACTER(*), INTENT(IN), OPTIONAL :: extra
    LOGICAL :: nodamp
    REAL(wp) :: ps(6)
    INTEGER :: u, ios

    nodamp = .FALSE.
    IF (PRESENT(undamped)) nodamp = undamped
    OPEN (NEWUNIT=u, FILE=path, STATUS='REPLACE', ACTION='WRITE', IOSTAT=ios)
    CALL require(ios == 0, 'create '//path)
    IF (ios /= 0) RETURN
    WRITE (u, '(A)') 'Storm-sea dt convergence'
    WRITE (u, '(A)') '--- LINE TYPES ---'
    WRITE (u, '(A)') 'Name Diam Mass EA BA EI Cdn Cdt Can Cat'
    WRITE (u, '(A)') '(-) (m) (kg/m) (N) (-) (Nm2) (-) (-) (-) (-)'
    IF (body == 'rigid6') THEN
      IF (nodamp) THEN
        WRITE (u, '(A)') 'poly 0.12 15.0 5.0e7 0.0 0.0 0.0 0.0 1.0 0.0'
      ELSE
        WRITE (u, '(A)') 'poly 0.12 15.0 5.0e7 -1.0 0.0 1.2 0.2 1.0 0.0'
      END IF
      WRITE (u, '(A)') '--- BODIES ---'
      WRITE (u, '(A)') 'ID Type X Y Z Roll Pitch Yaw Mass Vol C33 C44 C55 CdA Ca Ixx Iyy Izz'
      WRITE (u, '(A)') '(-) (-) (m) (m) (m) (deg) (deg) (deg) (kg) (m3) (N/m) (Nm) (Nm) (m2) (-) (kgm2) (kgm2) (kgm2)'
      ps = [0.0_wp, 0.0_wp, -20.0_wp, 0.0_wp, 0.0_wp, 0.0_wp]
      IF (PRESENT(pose)) ps = pose
      IF (nodamp) THEN
        WRITE (u, '(A,6(1X,ES24.16),A)') '1 Rigid6', ps, ' 2.0e4 40.0 0.0 0.0 0.0 0.0 0.5 3.5e4 3.5e4 3.5e4'
      ELSE
        WRITE (u, '(A,6(1X,ES24.16),A)') '1 Rigid6', ps, ' 2.0e4 40.0 0.0 0.0 0.0 8.0 0.5 3.5e4 3.5e4 3.5e4'
      END IF
      WRITE (u, '(A)') '--- POINTS ---'
      WRITE (u, '(A)') 'ID Type X Y Z Mass Vol CdA Ca'
      WRITE (u, '(A)') '(-) (-) (m) (m) (m) (kg) (m3) (m2) (-)'
      WRITE (u, '(A)') '1 Body1 1.5 0.0 -2.0 0 0 0 0'
      WRITE (u, '(A)') '2 Body1 -0.75 1.299 -2.0 0 0 0 0'
      WRITE (u, '(A)') '3 Body1 -0.75 -1.299 -2.0 0 0 0 0'
      WRITE (u, '(A)') '4 Fixed 40.0 0.0 -100.0 0 0 0 0'
      WRITE (u, '(A)') '5 Fixed -20.0 34.641 -100.0 0 0 0 0'
      WRITE (u, '(A)') '6 Fixed -20.0 -34.641 -100.0 0 0 0 0'
      WRITE (u, '(A)') '--- LINES ---'
      WRITE (u, '(A)') 'ID NodeA NodeB Outputs'
      WRITE (u, '(A)') '(-) (-) (-) (-)'
      WRITE (u, '(A)') '1 1 4 -'
      WRITE (u, '(A)') '2 2 5 -'
      WRITE (u, '(A)') '3 3 6 -'
      WRITE (u, '(A)') '--- SECTIONS ---'
      WRITE (u, '(A)') 'LineID LineType Length NumSegs'
      WRITE (u, '(A)') '(-) (-) (m) (-)'
      WRITE (u, '(A)') '1 poly 86.85 20'
      WRITE (u, '(A)') '2 poly 86.85 20'
      WRITE (u, '(A)') '3 poly 86.85 20'
      WRITE (u, '(A)') '--- OPTIONS ---'
      WRITE (u, '(A)') '100.0 WtrDpth'
    ELSE
      WRITE (u, '(A)') 'poly 0.10 10.0 2.0e7 -1.0 0.0 1.2 0.2 1.0 0.0'
      WRITE (u, '(A)') '--- ROD TYPES ---'
      WRITE (u, '(A)') 'Name Diam Mass Cd Ca CdEnd CaEnd CdAx CaAx'
      WRITE (u, '(A)') '(-) (m) (kg/m) (-) (-) (-) (-) (-) (-)'
      WRITE (u, '(A)') 'spar 1.0 300.0 0.8 1.0 0.0 0.0 0.2 0.0'
      WRITE (u, '(A)') '--- RODS ---'
      WRITE (u, '(A)') 'ID RodType Type XA YA ZA XB YB ZB NumSegs Outputs'
      WRITE (u, '(A)') '(-) (-) (-) (m) (m) (m) (m) (m) (m) (-) (-)'
      ps = [0.0_wp, 0.0_wp, -30.0_wp, 0.0_wp, 0.0_wp, -20.0_wp]
      IF (PRESENT(pose)) ps = pose
      WRITE (u, '(A,6(1X,ES24.16),A)') '1 spar Free', ps, ' 1 -'
      WRITE (u, '(A)') '--- POINTS ---'
      WRITE (u, '(A)') 'ID Type X Y Z Mass Vol CdA Ca'
      WRITE (u, '(A)') '(-) (-) (m) (m) (m) (kg) (m3) (m2) (-)'
      WRITE (u, '(A,3(1X,ES24.16),A)') '1 Rod1A', ps(1:3), ' 0 0 0 0'
      WRITE (u, '(A,3(1X,ES24.16),A)') '2 Rod1B', ps(4:6), ' 0 0 0 0'
      WRITE (u, '(A)') '3 Fixed 25.0 0.0 -50.0 0 0 0 0'
      WRITE (u, '(A)') '4 Fixed -25.0 0.0 -50.0 0 0 0 0'
      WRITE (u, '(A)') '5 Fixed 0.0 30.0 -50.0 0 0 0 0'
      WRITE (u, '(A)') '6 Fixed 0.0 -30.0 -50.0 0 0 0 0'
      WRITE (u, '(A)') '--- LINES ---'
      WRITE (u, '(A)') 'ID NodeA NodeB Outputs'
      WRITE (u, '(A)') '(-) (-) (-) (-)'
      WRITE (u, '(A)') '1 1 3 -'
      WRITE (u, '(A)') '2 1 4 -'
      WRITE (u, '(A)') '3 2 5 -'
      WRITE (u, '(A)') '4 2 6 -'
      WRITE (u, '(A)') '--- SECTIONS ---'
      WRITE (u, '(A)') 'LineID LineType Length NumSegs'
      WRITE (u, '(A)') '(-) (-) (m) (-)'
      WRITE (u, '(A)') '1 poly 31.95 16'
      WRITE (u, '(A)') '2 poly 31.95 16'
      WRITE (u, '(A)') '3 poly 42.40 20'
      WRITE (u, '(A)') '4 poly 42.40 20'
      WRITE (u, '(A)') '--- OPTIONS ---'
      WRITE (u, '(A)') '50.0 WtrDpth'
    END IF
    WRITE (u, '(A)') '9.80665 g'
    WRITE (u, '(A)') '1025.0 rhoW'
    WRITE (u, '(A)') '1.0e5 kBot'
    IF (nodamp) THEN
      WRITE (u, '(A)') '0.0 cBot'
    ELSE
      WRITE (u, '(A)') '1.0e4 cBot'
    END IF
    WRITE (u, '(ES12.5,A)') dtm, ' dtM'
    IF (PRESENT(tmax)) THEN
      WRITE (u, '(ES12.5,A)') tmax, ' TMax'
    ELSE
      WRITE (u, '(A)') '40.0 TMax'
    END IF
    IF (PRESENT(release)) THEN
      IF (release) WRITE (u, '(A)') 'deck bodyIC'
    END IF
    IF (sea == 'js14') THEN
      WRITE (u, '(A)') 'jonswap 14 16 2 30 waves'
      WRITE (u, '(A)') 'uniform 1.5 0.5 0 current'
    ELSE IF (sea == 'airy12') THEN
      WRITE (u, '(A)') 'airy 12 14 0 waves'
    ELSE IF (sea == 'cur') THEN
      WRITE (u, '(A)') 'uniform 1.5 0.5 0 current'
    ELSE IF (sea == 'cur05') THEN
      WRITE (u, '(A)') 'uniform 0.5 0 0 current'
    END IF
    IF (PRESENT(extra)) WRITE (u, '(A)') TRIM(extra)
    WRITE (u, '(A)') '--- OUTPUTS ---'
    WRITE (u, '(A)') 'FairTen1 FairTen2 FairTen3'
    WRITE (u, '(A)') '--- end ---'
    CLOSE (u)
  END SUBROUTINE write_storm_deck

  SUBROUTINE storm_stats(path, stats, ok)
    !! Standard deviation and peak of FairTen1..3 over t >= 10 s: stats(1:3) std, stats(4:6) peak.
    CHARACTER(*), INTENT(IN) :: path
    REAL(wp), INTENT(OUT) :: stats(6)
    LOGICAL, INTENT(OUT) :: ok
    REAL(wp), ALLOCATABLE :: d(:, :)
    LOGICAL, ALLOCATABLE :: late(:)
    REAL(wp) :: mean
    INTEGER :: k, n

    stats = 0.0_wp
    CALL read_out(path, 4, d, ok)
    IF (.NOT. ok) RETURN
    late = d(1, :) >= 10.0_wp
    n = COUNT(late)
    ok = n > 10
    IF (.NOT. ok) RETURN
    DO k = 1, 3
      mean = SUM(d(k + 1, :), MASK=late)/REAL(n, wp)
      stats(k) = SQRT(SUM((d(k + 1, :) - mean)**2, MASK=late)/REAL(n, wp))
      stats(3 + k) = MAXVAL(d(k + 1, :), MASK=late)
    END DO
  END SUBROUTINE storm_stats

  SUBROUTINE check_storm_dt_convergence()
    !! A moored Rigid6 buoy and a moored rod spar in storm seas (the cases that exposed a
    !! dt-dependent damping of the body response, a Rigid6 blow-up at dt = 0.025 s and a
    !! misreported singular rod mass): the fairlead-tension standard deviation and peak must
    !! agree within 3 % between dtM = 0.05 s and 0.0125 s (and, for the Airy case that blew up,
    !! at 0.025 s), i.e. the coupled body-line march converges in dt instead of carrying a
    !! step-size-dependent numerical damping.
    CHARACTER(6), PARAMETER :: BODIES(3) = ['rigid6', 'rigid6', 'rod   ']
    CHARACTER(6), PARAMETER :: SEAS(3) = ['js14  ', 'airy12', 'js14  ']
    REAL(wp), PARAMETER :: DTS(3) = [0.05_wp, 0.025_wp, 0.0125_wp]
    REAL(wp) :: stats(6, 3), rel
    INTEGER :: ic, idt, k
    LOGICAL :: ok, all_ok
    CHARACTER(64) :: root

    stats = 0.0_wp
    DO ic = 1, SIZE(BODIES)
      all_ok = .TRUE.
      DO idt = 1, SIZE(DTS)
        ! the 0.025 s run is only the Airy blow-up regression
        IF (idt == 2 .AND. TRIM(SEAS(ic)) /= 'airy12') CYCLE
        WRITE (root, '(A,A,A,A,A,I0)') 'body_rod_storm_', TRIM(BODIES(ic)), '_', TRIM(SEAS(ic)), '_dt', &
          NINT(1.0e4_wp*DTS(idt))
        CALL write_storm_deck(TRIM(root)//'.dat', TRIM(BODIES(ic)), TRIM(SEAS(ic)), DTS(idt))
        CALL run_deck(TRIM(root)//'.dat', TRIM(root), ok)
        IF (ok) CALL storm_stats(TRIM(root)//'.out', stats(:, idt), ok)
        all_ok = all_ok .AND. ok
      END DO
      IF (.NOT. all_ok) CYCLE
      DO idt = 1, 2
        IF (idt == 2 .AND. TRIM(SEAS(ic)) /= 'airy12') CYCLE
        DO k = 1, 6
          rel = ABS(stats(k, idt) - stats(k, 3))/MAX(stats(k, 3), 1.0_wp)
          WRITE (*, '(A,A,A,A,A,F6.4,A,I0,A,ES11.4,A,ES11.4)') 'storm ', TRIM(BODIES(ic)), ' ', TRIM(SEAS(ic)), &
            ' dt ', DTS(idt), ' stat ', k, ': ', stats(k, idt), ' vs dt 0.0125: ', stats(k, 3)
          CALL require(rel < 0.03_wp, 'storm-sea '//TRIM(BODIES(ic))//' '//TRIM(SEAS(ic))// &
                       ' fairlead-tension std/peak converge in dt')
        END DO
      END DO
    END DO
  END SUBROUTINE check_storm_dt_convergence

  SUBROUTINE check_rod_release_substep_accuracy()
    !! The rod spar released from its deck pose (23 kN out of balance) in a 0.5 m/s current, at
    !! dtM = 0.1 s, where each coupled step of the staggered scheme (bodyScheme staggered) is
    !! sub-stepped for the body-mooring mode, against the same release at dtM = 0.005 s (no
    !! sub-stepping). The fairlead tensions of the lower legs
    !! (lines 1-2) must follow the reference transient within 2 % of their peak over the first
    !! 10 s. Line 3 is not scored: its end snaps at t ~ 0.3 s and its error is set by the line's
    !! own step (8 % at dtM = 0.02 s without sub-stepping), not by the body coupling.
    REAL(wp), PARAMETER :: DT_COARSE = 0.1_wp, DT_REF = 0.005_wp, T_END = 10.0_wp
    REAL(wp), ALLOCATABLE :: dc(:, :), dr(:, :)
    REAL(wp) :: err(2)
    INTEGER :: i, j, k
    LOGICAL :: ok, ok_ref

    CALL write_storm_deck('body_rod_release_dt1000.dat', 'rod', 'cur05', DT_COARSE, tmax=T_END, release=.TRUE., &
                          extra='staggered bodyScheme')
    CALL write_storm_deck('body_rod_release_dt50.dat', 'rod', 'cur05', DT_REF, tmax=T_END, release=.TRUE., &
                          extra='staggered bodyScheme')
    CALL run_deck('body_rod_release_dt1000.dat', 'body_rod_release_dt1000', ok)
    CALL run_deck('body_rod_release_dt50.dat', 'body_rod_release_dt50', ok_ref)
    IF (ok) CALL read_out('body_rod_release_dt1000.out', 4, dc, ok, min_rows=90)
    IF (ok_ref) CALL read_out('body_rod_release_dt50.out', 4, dr, ok_ref, min_rows=1900)
    CALL require(ok .AND. ok_ref, 'rod release: both runs complete')
    IF (.NOT. (ok .AND. ok_ref)) RETURN
    err = 0.0_wp
    DO i = 1, SIZE(dc, 2)
      ! the reference row at the same time (the coarse times are multiples of DT_REF)
      j = NINT(dc(1, i)/DT_REF) + 1
      IF (j < 1 .OR. j > SIZE(dr, 2)) CYCLE
      IF (ABS(dr(1, j) - dc(1, i)) > 1.0e-6_wp) CYCLE
      DO k = 1, 2
        err(k) = MAX(err(k), ABS(dc(k + 1, i) - dr(k + 1, j)))
      END DO
    END DO
    DO k = 1, 2
      err(k) = err(k)/nan_max_abs(dr(k + 1, :))
      WRITE (*, '(A,I0,A,ES10.3)') 'rod release dt 0.1 vs 0.005: FairTen', k, ' transient error = ', err(k)
    END DO
    CALL require(ALL(err < 0.02_wp), 'rod release: sub-stepped dt 0.1 s fairlead transient within 2 % of dt 0.005 s')
  END SUBROUTINE check_rod_release_substep_accuracy

  ! ------------------------------------------------------------------------------------------
  SUBROUTINE check_monolithic_large_dt()
    !! The monolithic scheme (default bodyScheme) needs no sub-stepping for stability: the moored
    !! Rigid6 buoy and the rod spar, released out of balance in a 0.5 m/s current, run at dtM =
    !! 0.1 s and 0.5 s to completion with finite, bounded fairlead tensions (peak within 1.5x of
    !! the dtM = 0.005 s run). Accuracy is then set by dtM against the body-mooring mode; the
    !! bodySubstep accuracy option resolves it (omega dt <= 0.3) and keeps the spar's dtM = 0.1 s
    !! fairlead transient within 5 % of the reference.
    CHARACTER(6), PARAMETER :: BODIES(2) = ['rigid6', 'rod   ']
    REAL(wp), PARAMETER :: DTS(2) = [0.1_wp, 0.5_wp], DT_REF = 0.005_wp, T_END = 10.0_wp
    REAL(wp), ALLOCATABLE :: dc(:, :), dr(:, :)
    REAL(wp) :: peak, err
    INTEGER :: ib, idt, i, j, k
    LOGICAL :: ok, ok_ref
    CHARACTER(64) :: root

    DO ib = 1, SIZE(BODIES)
      root = 'body_rod_mono_'//TRIM(BODIES(ib))//'_ref'
      CALL write_storm_deck(TRIM(root)//'.dat', TRIM(BODIES(ib)), 'cur05', DT_REF, tmax=T_END, release=.TRUE.)
      CALL run_deck(TRIM(root)//'.dat', TRIM(root), ok_ref)
      IF (ok_ref) CALL read_out(TRIM(root)//'.out', 4, dr, ok_ref, min_rows=1900)
      CALL require(ok_ref, 'monolithic '//TRIM(BODIES(ib))//' release: reference run completes')
      IF (.NOT. ok_ref) CYCLE
      DO idt = 1, SIZE(DTS)
        WRITE (root, '(A,A,A,I0)') 'body_rod_mono_', TRIM(BODIES(ib)), '_dt', NINT(1000.0_wp*DTS(idt))
        CALL write_storm_deck(TRIM(root)//'.dat', TRIM(BODIES(ib)), 'cur05', DTS(idt), tmax=T_END, release=.TRUE.)
        CALL run_deck(TRIM(root)//'.dat', TRIM(root), ok)
        IF (ok) CALL read_out(TRIM(root)//'.out', 4, dc, ok, min_rows=NINT(T_END/DTS(idt)))
        CALL require(ok, 'monolithic '//TRIM(root)//': completes without sub-stepping')
        IF (.NOT. ok) CYCLE
        peak = nan_max_abs(dc(2:4, :))
        WRITE (*, '(A,A,A,F5.2,A,ES10.3,A,ES10.3,A)') 'monolithic ', TRIM(BODIES(ib)), ' release dt ', DTS(idt), &
          ': peak FairTen ', peak, ' (dt 0.005: ', nan_max_abs(dr(2:4, :)), ')'
        CALL require(ALL(IEEE_IS_FINITE(dc)) .AND. peak <= 1.5_wp*nan_max_abs(dr(2:4, :)), &
                     'monolithic '//TRIM(root)//': finite, bounded fairlead tensions')
      END DO
    END DO
    ! bodySubstep accuracy on the spar at dtM = 0.1 s
    CALL write_storm_deck('body_rod_mono_rod_acc.dat', 'rod', 'cur05', 0.1_wp, tmax=T_END, release=.TRUE., &
                          extra='accuracy bodySubstep')
    CALL run_deck('body_rod_mono_rod_acc.dat', 'body_rod_mono_rod_acc', ok)
    IF (ok) CALL read_out('body_rod_mono_rod_acc.out', 4, dc, ok, min_rows=90)
    CALL read_out('body_rod_mono_rod_ref.out', 4, dr, ok_ref, min_rows=1900)
    CALL require(ok .AND. ok_ref, 'monolithic rod release with bodySubstep accuracy completes')
    IF (.NOT. (ok .AND. ok_ref)) RETURN
    err = 0.0_wp
    DO k = 1, 2
      peak = 0.0_wp
      DO i = 1, SIZE(dc, 2)
        j = NINT(dc(1, i)/DT_REF) + 1
        IF (j < 1 .OR. j > SIZE(dr, 2)) CYCLE
        IF (ABS(dr(1, j) - dc(1, i)) > 1.0e-6_wp) CYCLE
        peak = MAX(peak, ABS(dc(k + 1, i) - dr(k + 1, j)))
      END DO
      err = MAX(err, peak/nan_max_abs(dr(k + 1, :)))
    END DO
    WRITE (*, '(A,ES10.3)') 'monolithic rod release dt 0.1 with bodySubstep accuracy: FairTen1-2 error = ', err
    CALL require(err < 0.05_wp, 'monolithic rod release: bodySubstep accuracy keeps the transient within 5 %')
  END SUBROUTINE check_monolithic_large_dt

  SUBROUTINE check_monolithic_energy()
    !! Undamped moored Rigid6 buoy (no drag, no line damping, no seabed damping, still water)
    !! released 0.3 m off its equilibrium: with rhoInf = 1 the monolithic generalised-alpha step adds
    !! no energy (the fairlead-tension swing over the last 15 s of a 60 s run is at most that of
    !! the first 15 s) and with rhoInf = 0.4 its numerical dissipation only removes energy.
    REAL(wp), ALLOCATABLE :: d(:, :)
    REAL(wp) :: early, late
    LOGICAL :: ok
    INTEGER :: ir, n
    CHARACTER(8), PARAMETER :: RHOS(2) = ['1.0     ', '0.4     ']
    CHARACTER(64) :: root

    DO ir = 1, SIZE(RHOS)
      root = 'body_rod_energy_rho'//TRIM(RHOS(ir))
      CALL write_storm_deck(TRIM(root)//'.dat', 'rigid6', 'calm', 0.05_wp, tmax=60.0_wp, release=.TRUE., &
                            pose=[0.3_wp, 0.0_wp, -20.0_wp, 0.0_wp, 0.0_wp, 0.0_wp], &
                            extra=TRIM(RHOS(ir))//' rhoInf', undamped=.TRUE.)
      CALL run_deck(TRIM(root)//'.dat', TRIM(root), ok)
      IF (ok) CALL read_out(TRIM(root)//'.out', 4, d, ok, min_rows=1000)
      CALL require(ok, TRIM(root)//': undamped release completes')
      IF (.NOT. ok) CYCLE
      n = SIZE(d, 2)
      early = MAXVAL(d(2, 1:n/4)) - MINVAL(d(2, 1:n/4))
      late = MAXVAL(d(2, 3*n/4:n)) - MINVAL(d(2, 3*n/4:n))
      WRITE (*, '(A,A,A,ES12.5,A,ES12.5)') 'undamped buoy rhoInf ', TRIM(RHOS(ir)), &
        ': FairTen1 swing first 15 s ', early, ', last 15 s ', late
      CALL require(late <= early*(1.0_wp + 1.0e-3_wp), TRIM(root)//': no energy growth')
    END DO
  END SUBROUTINE check_monolithic_energy

  ! ------------------------------------------------------------------------------------------
  ! 6. Bodies and rods start at their static equilibrium
  ! ------------------------------------------------------------------------------------------

  SUBROUTINE check_static_body_start()
    !! The same moorings in calm water and in a steady current (no waves): the body / rod is
    !! placed at its static equilibrium before the march (the rod deck pose is 23 kN out of
    !! balance), so the fairlead tensions stay at their t = 0 values for the whole 40 s run
    !! (no drift and no ringing), and a TMax = 0 run reports the same initial state.
    CHARACTER(6), PARAMETER :: BODIES(4) = ['rigid6', 'rigid6', 'rod   ', 'rod   ']
    CHARACTER(4), PARAMETER :: SEAS(4) = ['calm', 'cur ', 'calm', 'cur ']
    REAL(wp), ALLOCATABLE :: d(:, :), d0(:, :)
    REAL(wp) :: dev
    INTEGER :: ic, k, u, ios
    LOGICAL :: ok
    CHARACTER(64) :: root
    CHARACTER(256) :: row

    DO ic = 1, SIZE(BODIES)
      root = 'body_rod_eq_'//TRIM(BODIES(ic))//'_'//TRIM(SEAS(ic))
      CALL write_storm_deck(TRIM(root)//'.dat', TRIM(BODIES(ic)), TRIM(SEAS(ic)), 0.05_wp)
      CALL run_deck(TRIM(root)//'.dat', TRIM(root), ok)
      IF (ok) CALL read_out(TRIM(root)//'.out', 4, d, ok)
      IF (.NOT. ok) CYCLE
      dev = 0.0_wp
      DO k = 1, 3
        dev = MAX(dev, nan_max_abs(d(k + 1, :) - d(k + 1, 1))/MAX(ABS(d(k + 1, 1)), 1.0_wp))
      END DO
      WRITE (*, '(A,A,A,A,A,ES10.3)') 'static start ', TRIM(BODIES(ic)), ' ', TRIM(SEAS(ic)), &
        ': max relative FairTen change over 40 s = ', dev
      CALL require(dev < 1.0e-6_wp, 'static start '//TRIM(BODIES(ic))//' '//TRIM(SEAS(ic))// &
                   ': the body starts at rest in equilibrium')
      ! the TMax = 0 route reports the same initial condition
      OPEN (NEWUNIT=u, FILE=TRIM(root)//'.dat', STATUS='OLD', ACTION='READ', IOSTAT=ios)
      IF (ios /= 0) CYCLE
      OPEN (NEWUNIT=k, FILE=TRIM(root)//'_t0.dat', STATUS='REPLACE', ACTION='WRITE', IOSTAT=ios)
      DO
        READ (u, '(A)', IOSTAT=ios) row
        IF (ios /= 0) EXIT
        IF (TRIM(row) == '40.0 TMax') row = '0.0 TMax'
        WRITE (k, '(A)') TRIM(row)
      END DO
      CLOSE (u)
      CLOSE (k)
      CALL run_deck(TRIM(root)//'_t0.dat', TRIM(root)//'_t0', ok)
      IF (ok) CALL read_out(TRIM(root)//'_t0.out', 4, d0, ok, min_rows=1)
      IF (ok) CALL require(nan_max_abs(d0(:, 1) - d(:, 1)) <= 1.0e-9_wp*nan_max_abs(d(:, 1)), &
                           'static start '//TRIM(BODIES(ic))//' '//TRIM(SEAS(ic))//': TMax = 0 gives the same IC')
    END DO
  END SUBROUTINE check_static_body_start

  SUBROUTINE check_equilibrium_jacobian()
    !! The static-equilibrium Newton uses an analytic Jacobian (the condensed end stiffness of
    !! every attached line plus the objects' own terms); it must match a central-difference
    !! Jacobian of the full residual (each column re-solving the lines) at the deck state, for a
    !! Rigid6 buoy, a rod spar, and a Connect point system.
    CHARACTER(64) :: decks(3)
    LOGICAL :: pts_only(3)
    REAL(wp) :: err
    INTEGER :: ic, es
    CHARACTER(512) :: em

    CALL write_storm_deck('body_rod_jac_rigid6.dat', 'rigid6', 'calm', 0.05_wp)
    CALL write_storm_deck('body_rod_jac_rod.dat', 'rod', 'calm', 0.05_wp)
    CALL write_connect_deck('body_rod_jac_connect.dat')
    decks = [CHARACTER(64) :: 'body_rod_jac_rigid6.dat', 'body_rod_jac_rod.dat', 'body_rod_jac_connect.dat']
    pts_only = [.FALSE., .FALSE., .TRUE.]
    DO ic = 1, SIZE(decks)
      CALL CD_Deck_Equilibrium_Jacobian_Check(TRIM(decks(ic)), err, es, em, points_only=pts_only(ic))
      WRITE (*, '(A,A,A,ES10.3)') 'equilibrium Jacobian ', TRIM(decks(ic)), ': analytic vs FD relative error = ', err
      CALL require(es == 0 .AND. err >= 0.0_wp .AND. err < 1.0e-5_wp, &
                   'analytic equilibrium Jacobian matches FD ('//TRIM(decks(ic))//'): '//TRIM(em))
    END DO
  END SUBROUTINE check_equilibrium_jacobian

  SUBROUTINE check_equilibrium_seed_robustness()
    !! The static equilibrium from poor deck poses: a buoyant Free point on one taut line seeded
    !! laterally offset with the line overstretched (it must swing up over its anchor along the
    !! stiff line), and the Rigid6 buoy and rod spar seeded displaced and turned by up to 30 deg.
    !! Each run must converge to the same equilibrium as the deck-pose run (the buoy right above
    !! its anchor; the same fairlead tensions), never to an unstable one: a Rigid6 buoy yawed
    !! 180 deg against its legs either reaches the stable equilibrium or stops naming the
    !! unstable balance.
    REAL(wp), PARAMETER :: BUOY_SEEDS(3, 3) = RESHAPE([-8.688_wp, 2.940_wp, -38.983_wp, &
                                                       -10.969_wp, 10.423_wp, -37.087_wp, &
                                                       7.868_wp, -14.937_wp, -46.638_wp], [3, 3])
    REAL(wp), PARAMETER :: BODY_SEEDS(6, 3) = RESHAPE([10.199_wp, 13.340_wp, -20.777_wp, 9.849_wp, -26.360_wp, &
                                                       12.090_wp, 5.286_wp, -13.380_wp, -8.014_wp, 16.798_wp, &
                                                       22.471_wp, 17.872_wp, -14.162_wp, -6.617_wp, -27.225_wp, &
                                                       11.551_wp, 27.391_wp, -3.166_wp], [6, 3])
    REAL(wp), PARAMETER :: ROD_SEEDS(6, 3) = RESHAPE([1.748_wp, -6.307_wp, -32.321_wp, 2.749_wp, -9.924_wp, &
                                                      -23.053_wp, 7.331_wp, -6.343_wp, -37.688_wp, 9.508_wp, &
                                                      -11.141_wp, -29.189_wp, -2.115_wp, 7.088_wp, -30.372_wp, &
                                                      -1.503_wp, 7.046_wp, -20.391_wp], [6, 3])
    REAL(wp), ALLOCATABLE :: d(:, :), d0(:, :)
    REAL(wp) :: pose(6), zeq
    INTEGER :: ic, ib, es
    LOGICAL :: ok, conv
    CHARACTER(64) :: root
    CHARACTER(6) :: bname
    CHARACTER(512) :: em

    ! the buoy: 49.796 m line of EA 4.26e8 N from an anchor at z = -92.114 m, 17.8 t net buoyancy
    zeq = -42.2994_wp
    DO ic = 1, SIZE(BUOY_SEEDS, 2)
      WRITE (root, '(A,I0)') 'body_rod_seed_buoy', ic
      CALL write_free_buoy_deck(TRIM(root)//'.dat', BUOY_SEEDS(:, ic))
      CALL run_deck(TRIM(root)//'.dat', TRIM(root), ok)
      IF (ok) CALL read_out(TRIM(root)//'.out', 6, d, ok, min_rows=1)
      IF (.NOT. ok) CYCLE
      WRITE (*, '(A,I0,A,3F10.4)') 'seed robustness: buoy seed ', ic, ' equilibrium ', d(4:6, 1)
      CALL require(ABS(d(4, 1)) < 1.0e-4_wp .AND. ABS(d(5, 1)) < 1.0e-4_wp .AND. ABS(d(6, 1) - zeq) < 1.0e-3_wp, &
                   'seed robustness: the buoy swings up over its anchor')
    END DO
    ! the Rigid6 buoy (calm) and the rod spar (0.5 m/s current)
    DO ib = 1, 2
      bname = 'rigid6'
      IF (ib == 2) bname = 'rod'
      root = 'body_rod_seed_'//TRIM(bname)//'_0'
      CALL write_storm_deck(TRIM(root)//'.dat', TRIM(bname), MERGE('calm ', 'cur05', ib == 1), 0.05_wp, tmax=0.0_wp)
      CALL run_deck(TRIM(root)//'.dat', TRIM(root), ok)
      IF (ok) CALL read_out(TRIM(root)//'.out', 4, d0, ok, min_rows=1)
      IF (.NOT. ok) CYCLE
      DO ic = 1, 3
        IF (ib == 1) THEN
          pose = BODY_SEEDS(:, ic)
        ELSE
          ! the rod keeps its 10 m length
          pose = ROD_SEEDS(:, ic)
          pose(4:6) = pose(1:3) + 10.0_wp*(pose(4:6) - pose(1:3))/NORM2(pose(4:6) - pose(1:3))
        END IF
        WRITE (root, '(A,A,A,I0)') 'body_rod_seed_', TRIM(bname), '_', ic
        CALL write_storm_deck(TRIM(root)//'.dat', TRIM(bname), MERGE('calm ', 'cur05', ib == 1), 0.05_wp, &
                              tmax=0.0_wp, pose=pose)
        CALL run_deck(TRIM(root)//'.dat', TRIM(root), ok)
        IF (ok) CALL read_out(TRIM(root)//'.out', 4, d, ok, min_rows=1)
        IF (.NOT. ok) CYCLE
        WRITE (*, '(A,A,A,I0,A,3ES13.5)') 'seed robustness: ', TRIM(bname), ' seed ', ic, ' FairTen ', d(2:4, 1)
        CALL require(nan_max_abs(d(2:4, 1) - d0(2:4, 1)) <= 1.0e-5_wp*nan_max_abs(d0(2:4, 1)), &
                     'seed robustness: '//TRIM(bname)//' reaches the deck-pose equilibrium')
      END DO
      ! yawed 180 deg against its legs: the stable equilibrium or a named unstable balance
      IF (ib == 1) THEN
        CALL write_storm_deck('body_rod_seed_yaw180.dat', 'rigid6', 'calm', 0.05_wp, tmax=0.0_wp, &
                              pose=[0.0_wp, 0.0_wp, -20.0_wp, 0.0_wp, 0.0_wp, 180.0_wp])
        CALL CD_Run_Deck_Driver('body_rod_seed_yaw180.dat', 'body_rod_seed_yaw180', conv, es, em)
        IF (es == CD_DECKDRV_OK) THEN
          CALL read_out('body_rod_seed_yaw180.out', 4, d, ok, min_rows=1)
          CALL require(ok, 'seed robustness: yaw 180 output')
          IF (ok) CALL require(nan_max_abs(d(2:4, 1) - d0(2:4, 1)) <= 1.0e-5_wp*nan_max_abs(d0(2:4, 1)), &
                               'seed robustness: yaw 180 converges only to the stable equilibrium')
          WRITE (*, '(A)') 'seed robustness: yaw 180 reached the stable equilibrium'
        ELSE
          WRITE (*, '(A,A)') 'seed robustness: yaw 180 stops: ', TRIM(em)
          CALL require(INDEX(em, 'unstable') > 0, 'seed robustness: yaw 180 stops naming the unstable balance')
        END IF
      END IF
    END DO
  END SUBROUTINE check_equilibrium_seed_robustness

  SUBROUTINE write_free_buoy_deck(path, seed)
    !! A buoyant Free point (2 t, 19.34 m3) on one stiff 49.8 m line from an anchor 92.1 m deep,
    !! seeded at seed.
    CHARACTER(*), INTENT(IN) :: path
    REAL(wp), INTENT(IN) :: seed(3)
    INTEGER :: u, ios
    OPEN (NEWUNIT=u, FILE=path, STATUS='REPLACE', ACTION='WRITE', IOSTAT=ios)
    CALL require(ios == 0, 'create '//path)
    IF (ios /= 0) RETURN
    WRITE (u, '(A)') 'Free buoy on one taut line'
    WRITE (u, '(A)') '--- LINE TYPES ---'
    WRITE (u, '(A)') 'Name Diam Mass EA BA EI Cdn Cdt Can Cat'
    WRITE (u, '(A)') '(-) (m) (kg/m) (N) (-) (Nm2) (-) (-) (-) (-)'
    WRITE (u, '(A)') 'T1 0.12717 99.332 4.2627908971e+08 -1.0 0.0 1.37 0.64 1.0 0.0'
    WRITE (u, '(A)') '--- POINTS ---'
    WRITE (u, '(A)') 'ID Type X Y Z Mass Vol CdA Ca'
    WRITE (u, '(A)') '(-) (-) (m) (m) (m) (kg) (m3) (m2) (-)'
    WRITE (u, '(A)') '1 Fixed 0.0 0.0 -92.11361628471701 0 0 0 0'
    WRITE (u, '(A,3(1X,ES24.16),A)') '2 Free', seed, ' 2000.0 19.339847654482497 0 0'
    WRITE (u, '(A)') '--- LINES ---'
    WRITE (u, '(A)') 'ID NodeA NodeB Outputs'
    WRITE (u, '(A)') '(-) (-) (-) (-)'
    WRITE (u, '(A)') '1 1 2 -'
    WRITE (u, '(A)') '--- SECTIONS ---'
    WRITE (u, '(A)') 'LineID LineType Length NumSegs'
    WRITE (u, '(A)') '(-) (-) (m) (-)'
    WRITE (u, '(A)') '1 T1 49.79629675655391 25'
    WRITE (u, '(A)') '--- OPTIONS ---'
    WRITE (u, '(A)') '92.11361628471701 WtrDpth'
    WRITE (u, '(A)') '0.01 dtM'
    WRITE (u, '(A)') '0.0 TMax'
    WRITE (u, '(A)') '--- OUTPUTS ---'
    WRITE (u, '(A)') 'FairTen1 AnchTen1 Point2px Point2py Point2pz'
    WRITE (u, '(A)') '--- end ---'
    CLOSE (u)
  END SUBROUTINE write_free_buoy_deck

  SUBROUTINE write_connect_deck(path)
    !! Two chain legs meeting at a heavy Connect point hung from a fairlead: the anchor leg
    !! partly grounded on a flat seabed.
    CHARACTER(*), INTENT(IN) :: path
    INTEGER :: u, ios
    OPEN (NEWUNIT=u, FILE=path, STATUS='REPLACE', ACTION='WRITE', IOSTAT=ios)
    CALL require(ios == 0, 'create '//path)
    IF (ios /= 0) RETURN
    WRITE (u, '(A)') 'Connect point'
    WRITE (u, '(A)') '--- LINE TYPES ---'
    WRITE (u, '(A)') 'Name Diam Mass EA BA EI Cdn Cdt Can Cat'
    WRITE (u, '(A)') '(-) (m) (kg/m) (N) (-) (Nm2) (-) (-) (-) (-)'
    WRITE (u, '(A)') 'chain 0.2 200.0 1.0e9 -1.0 0.0 1.37 0.64 1.0 0.0'
    WRITE (u, '(A)') '--- POINTS ---'
    WRITE (u, '(A)') 'ID Type X Y Z Mass Vol CdA Ca'
    WRITE (u, '(A)') '(-) (-) (m) (m) (m) (kg) (m3) (m2) (-)'
    WRITE (u, '(A)') '1 Coupled 0.0 0.0 -10.0 0 0 0 0'
    WRITE (u, '(A)') '2 Connect 150.0 0.0 -80.0 5000 0.5 0 0'
    WRITE (u, '(A)') '3 Fixed 400.0 0.0 -100.0 0 0 0 0'
    WRITE (u, '(A)') '--- LINES ---'
    WRITE (u, '(A)') 'ID NodeA NodeB Outputs'
    WRITE (u, '(A)') '(-) (-) (-) (-)'
    WRITE (u, '(A)') '1 1 2 -'
    WRITE (u, '(A)') '2 2 3 -'
    WRITE (u, '(A)') '--- SECTIONS ---'
    WRITE (u, '(A)') 'LineID LineType Length NumSegs'
    WRITE (u, '(A)') '(-) (-) (m) (-)'
    WRITE (u, '(A)') '1 chain 170.0 40'
    WRITE (u, '(A)') '2 chain 280.0 40'
    WRITE (u, '(A)') '--- OPTIONS ---'
    WRITE (u, '(A)') '9.80665 g'
    WRITE (u, '(A)') '1025.0 rhoW'
    WRITE (u, '(A)') '100.0 WtrDpth'
    WRITE (u, '(A)') '3.0e6 kBot'
    WRITE (u, '(A)') '0.05 dtM'
    WRITE (u, '(A)') '0.05 TMax'
    WRITE (u, '(A)') '--- OUTPUTS ---'
    WRITE (u, '(A)') 'FairTen1'
    WRITE (u, '(A)') '--- end ---'
    CLOSE (u)
  END SUBROUTINE write_connect_deck

  ! ------------------------------------------------------------------------------------------
  ! 7. Contact reach over a bathymetry step
  ! ------------------------------------------------------------------------------------------

  REAL(wp) FUNCTION step_floor(x) RESULT(z)
    !! The seabed of write_step_bathy: z = -10 m up to x = X0, a linear ramp to -9.2 m at
    !! x = X0 + 0.8 (a 45 degree slope), and -9.2 m beyond.
    REAL(wp), INTENT(IN) :: x
    REAL(wp), PARAMETER :: X0 = 0.3_wp
    z = -10.0_wp + 0.8_wp*MIN(1.0_wp, MAX(0.0_wp, (x - X0)/0.8_wp))
  END FUNCTION step_floor

  SUBROUTINE write_step_bathy(path)
    CHARACTER(*), INTENT(IN) :: path
    INTEGER :: u
    OPEN (NEWUNIT=u, FILE=path, STATUS='REPLACE', ACTION='WRITE')
    WRITE (u, '(A)') '-20.0 -20.0 10.0'
    WRITE (u, '(A)') '0.3 -20.0 10.0'
    WRITE (u, '(A)') '1.1 -20.0 9.2'
    WRITE (u, '(A)') '20.0 -20.0 9.2'
    WRITE (u, '(A)') '-20.0 20.0 10.0'
    WRITE (u, '(A)') '0.3 20.0 10.0'
    WRITE (u, '(A)') '1.1 20.0 9.2'
    WRITE (u, '(A)') '20.0 20.0 9.2'
    CLOSE (u)
  END SUBROUTINE write_step_bathy

  SUBROUTINE write_reach_deck(path, rod_type, x_a, dt)
    !! A neutrally buoyant 2 m rod (D = 0.2 m, Cd = 1.2, Ca = 1) along y with its axis 0.5 m above
    !! the 10 m bed of write_step_bathy, on a deck without lines, carried towards the 0.8 m step
    !! up by a 2 m/s current along x: a Free rod at x = x_a drifts over it; a Pinned rod
    !! (End A at the origin) weathervanes about its pin and sweeps its stations into it.
    CHARACTER(*), INTENT(IN) :: path, rod_type
    REAL(wp), INTENT(IN) :: x_a, dt
    INTEGER :: u
    OPEN (NEWUNIT=u, FILE=path, STATUS='REPLACE', ACTION='WRITE')
    WRITE (u, '(A)') 'Rod carried over a bathymetry step by a current'
    WRITE (u, '(A)') '--- ROD TYPES ---'
    WRITE (u, '(A)') 'Name Diam Mass Cd Ca CdEnd CaEnd'
    WRITE (u, '(A)') '(-) (m) (kg/m) (-) (-) (-) (-)'
    WRITE (u, '(A,ES24.16,A)') 'float 0.2 ', RHO_W*0.25_wp*PI*0.2_wp**2, ' 1.2 1.0 0 0'
    WRITE (u, '(A)') '--- RODS ---'
    WRITE (u, '(A)') 'ID RodType Attachment XA YA ZA XB YB ZB NumSegs Outputs'
    WRITE (u, '(A)') '(-) (-) (-) (m) (m) (m) (m) (m) (m) (-) (-)'
    WRITE (u, '(A,A,A,ES24.16,A,ES24.16,A)') '1 float ', rod_type, ' ', x_a, ' 0 -9.5 ', x_a, ' 2 -9.5 4 -'
    WRITE (u, '(A)') '--- OPTIONS ---'
    WRITE (u, '(A)') '9.80665 g'
    WRITE (u, '(A)') '1025.0 rhoW'
    WRITE (u, '(A)') 'reach_step.xyz bathymetryFile'
    WRITE (u, '(A)') '1.0e7 kBot'
    WRITE (u, '(A)') 'uniform 2.0 0 0 current'
    WRITE (u, '(A)') 'deck bodyIC'
    WRITE (u, '(ES22.14,A)') dt, ' dtM'
    WRITE (u, '(A)') '4.0 TMax'
    WRITE (u, '(A)') '--- OUTPUTS ---'
    WRITE (u, '(A)') 'Rod1N0Px Rod1N0Pz Rod1N2Px Rod1N2Pz Rod1N4Px Rod1N4Pz'
    WRITE (u, '(A)') '--- end ---'
    CLOSE (u)
  END SUBROUTINE write_reach_deck

  SUBROUTINE check_bathymetry_reach_substep()
    !! The contact reach must look along the station's whole path over the step. A neutrally
    !! buoyant rod 0.5 m above a 10 m bed, carried by a 2 m/s current towards an 0.8 m step up (a
    !! 45 degree ramp), meets the higher bed only by moving horizontally: (1) a Free rod drifting
    !! over the step, (2) a Pinned rod turning about its pin (its stations move horizontally,
    !! with no vertical velocity and an acceleration towards the pin). At dtM = 0.2 s the bed
    !! below each station is out of vertical reach (0.5 m against g dt^2/2 = 0.2 m plus the
    !! radius), so only the horizontal reach dt |v + w x s| + dt^2 (|a| + |alpha x s| +
    !! |w|^2 |s| + g)/2 and the highest floor within it bring the contact springs (kBot 1e7)
    !! into the sub-step estimate before a station is driven into the ramp. The run must stay
    !! finite, keep every output node out of the bed (at most 8 cm below the floor under it, the
    !! penalty set against the drag that presses the rod onto the slope)
    !! and below z = -8 m, and end within 0.2 m of a run at dtM = 0.05 s (the rod meets a 45
    !! degree slope at about 2 m/s). With the vertical reach and the floor under each station
    !! alone, the Free rod ends 3 m from the dtM = 0.05 s run and the Pinned rod sinks 14 cm into
    !! the slope and is thrown up to z = -7.7 m.
    REAL(wp), ALLOCATABLE :: dc(:, :), df(:, :)
    REAL(wp) :: worst, zmax, err
    INTEGER :: kase, i, j
    LOGICAL :: ok
    CHARACTER(8) :: kind

    CALL write_step_bathy('reach_step.xyz')
    DO kase = 1, 2
      IF (kase == 1) THEN
        kind = 'Free'
        CALL write_reach_deck('reach_c.dat', 'Free', -3.0_wp, 0.2_wp)
        CALL write_reach_deck('reach_f.dat', 'Free', -3.0_wp, 0.05_wp)
      ELSE
        kind = 'Pinned'
        CALL write_reach_deck('reach_c.dat', 'Pinned', 0.0_wp, 0.2_wp)
        CALL write_reach_deck('reach_f.dat', 'Pinned', 0.0_wp, 0.05_wp)
      END IF
      CALL run_deck('reach_c.dat', 'reach_c', ok)
      IF (.NOT. ok) CYCLE
      CALL read_out('reach_c.out', 7, dc, ok)
      IF (.NOT. ok) CYCLE
      CALL run_deck('reach_f.dat', 'reach_f', ok)
      IF (.NOT. ok) CYCLE
      CALL read_out('reach_f.out', 7, df, ok)
      IF (.NOT. ok) CYCLE
      worst = HUGE(1.0_wp)
      zmax = -HUGE(1.0_wp)
      DO i = 1, SIZE(dc, 2)
        DO j = 2, 6, 2
          worst = MIN(worst, dc(j + 1, i) - step_floor(dc(j, i)))
          zmax = MAX(zmax, dc(j + 1, i))
        END DO
      END DO
      err = nan_max_abs(dc(2:7, SIZE(dc, 2)) - df(2:7, SIZE(df, 2)))
      WRITE (*, '(A,A,A,F8.4,A,F8.4,A,F8.4,A,ES10.3)') 'rod over a bathymetry step (', TRIM(kind), &
        '): end x ', dc(6, SIZE(dc, 2)), ' m; least clearance ', worst, ' m; highest node ', zmax, &
        ' m; end vs dtM/4 ', err
      CALL require(ALL(IEEE_IS_FINITE(dc)), 'reach: '//TRIM(kind)//' run finite')
      CALL require(dc(6, SIZE(dc, 2)) > 0.6_wp, 'reach: '//TRIM(kind)//' rod carried over the step')
      CALL require(worst >= -0.08_wp .AND. zmax <= -8.0_wp, 'reach: '//TRIM(kind)//' rod kept out of the bed')
      CALL require(err <= 0.2_wp, 'reach: '//TRIM(kind)//' ends as the dtM/4 run')
    END DO
  END SUBROUTINE check_bathymetry_reach_substep

  ! ------------------------------------------------------------------------------------------
  ! 8. A floating rod and a rod held by seabed friction at a coarse step
  ! ------------------------------------------------------------------------------------------

  SUBROUTINE check_floating_rod_substep()
    !! A horizontal 1 m rod (D = 0.05 m, no drag or added mass) floating half submerged on a deck
    !! without lines, released 5 mm below its waterline: its waterplane rhoW g D L against its
    !! mass rhoW pi D^2 L/8 gives omega^2 = 8 g/(pi D), about 500 rad^2/s^2, so a 0.1 s step
    !! (omega dt = 2.2) is beyond the explicit limit. The waterplane stiffness of the sub-step
    !! estimate must keep the undamped heave within its release amplitude over 3 s.
    REAL(wp), ALLOCATABLE :: dat(:, :)
    REAL(wp) :: amp
    INTEGER :: u
    LOGICAL :: ok
    OPEN (NEWUNIT=u, FILE='float_rod.dat', STATUS='REPLACE', ACTION='WRITE')
    WRITE (u, '(A)') 'Floating horizontal rod released below its waterline'
    WRITE (u, '(A)') '--- ROD TYPES ---'
    WRITE (u, '(A)') 'Name Diam Mass Cd Ca CdEnd CaEnd'
    WRITE (u, '(A)') '(-) (m) (kg/m) (-) (-) (-) (-)'
    WRITE (u, '(A,ES24.16,A)') 'stick 0.05 ', RHO_W*PI*0.05_wp**2/8.0_wp, ' 0 0 0 0'
    WRITE (u, '(A)') '--- RODS ---'
    WRITE (u, '(A)') 'ID RodType Attachment XA YA ZA XB YB ZB NumSegs Outputs'
    WRITE (u, '(A)') '(-) (-) (-) (m) (m) (m) (m) (m) (m) (-) (-)'
    WRITE (u, '(A)') '1 stick Free 0 0 -0.005 1 0 -0.005 4 -'
    WRITE (u, '(A)') '--- OPTIONS ---'
    WRITE (u, '(A)') '9.80665 g'
    WRITE (u, '(A)') '1025.0 rhoW'
    WRITE (u, '(A)') '50 WtrDpth'
    WRITE (u, '(A)') 'deck bodyIC'
    WRITE (u, '(A)') '0.1 dtM'
    WRITE (u, '(A)') '3.0 TMax'
    WRITE (u, '(A)') '--- OUTPUTS ---'
    WRITE (u, '(A)') 'Rod1N2Pz'
    WRITE (u, '(A)') '--- end ---'
    CLOSE (u)
    CALL run_deck('float_rod.dat', 'float_rod', ok)
    IF (.NOT. ok) RETURN
    CALL read_out('float_rod.out', 2, dat, ok)
    IF (.NOT. ok) RETURN
    amp = nan_max_abs(dat(2, :))
    WRITE (*, '(A,ES10.3,A)') 'floating rod at a 0.1 s step: max |heave| ', amp, ' m (released at 5.0e-3 m)'
    CALL require(amp <= 5.5e-3_wp, 'floating rod: the heave stays within its release (waterplane sub-steps)')
  END SUBROUTINE check_floating_rod_substep

  SUBROUTINE check_rod_friction_hold()
    !! A heavy rod (D = 0.2 m, 50 kg/m) lying on a frictional bed (mu = 0.5, kBot 1e5) in a
    !! 0.3 m/s cross current, on a deck without lines at dtM = 0.1 s: the drag (about 11 N/m)
    !! is far below mu N (about 87 N/m), so the rod holds. The regularised friction is a damper
    !! mu N/vreg (vreg = 1e-3 m/s); applied explicitly it would flip the friction by mu N each
    !! step. Implicit, the rod must hold still after the first second (|End A velocity| below
    !! 5e-3 m/s) and its net cross load (drag less friction, Rod1Fy) stay below 5 % of mu N L.
    REAL(wp), ALLOCATABLE :: dat(:, :)
    REAL(wp) :: vmax, fmax, mun
    INTEGER :: u, i
    LOGICAL :: ok
    OPEN (NEWUNIT=u, FILE='fric_rod.dat', STATUS='REPLACE', ACTION='WRITE')
    WRITE (u, '(A)') 'Heavy rod held by seabed friction in a cross current'
    WRITE (u, '(A)') '--- ROD TYPES ---'
    WRITE (u, '(A)') 'Name Diam Mass Cd Ca CdEnd CaEnd'
    WRITE (u, '(A)') '(-) (m) (kg/m) (-) (-) (-) (-)'
    WRITE (u, '(A)') 'bar 0.2 50 1.2 1.0 0 0'
    WRITE (u, '(A)') '--- RODS ---'
    WRITE (u, '(A)') 'ID RodType Attachment XA YA ZA XB YB ZB NumSegs Outputs'
    WRITE (u, '(A)') '(-) (-) (-) (m) (m) (m) (m) (m) (m) (-) (-)'
    WRITE (u, '(A)') '1 bar Free 0 0 -20 1 0 -20 4 -'
    WRITE (u, '(A)') '--- OPTIONS ---'
    WRITE (u, '(A)') '9.80665 g'
    WRITE (u, '(A)') '1025.0 rhoW'
    WRITE (u, '(A)') '20 WtrDpth'
    WRITE (u, '(A)') '1.0e5 kBot'
    WRITE (u, '(A)') '0.5 frictionMu'
    WRITE (u, '(A)') 'uniform 0 0.3 0 current'
    WRITE (u, '(A)') 'deck bodyIC'
    WRITE (u, '(A)') '0.1 dtM'
    WRITE (u, '(A)') '4.0 TMax'
    WRITE (u, '(A)') '--- OUTPUTS ---'
    WRITE (u, '(A)') 'Rod1Vy Rod1Fy'
    WRITE (u, '(A)') '--- end ---'
    CLOSE (u)
    CALL run_deck('fric_rod.dat', 'fric_rod', ok)
    IF (.NOT. ok) RETURN
    CALL read_out('fric_rod.out', 3, dat, ok)
    IF (.NOT. ok) RETURN
    mun = 0.5_wp*(50.0_wp - RHO_W*0.25_wp*PI*0.2_wp**2)*GRAV
    vmax = 0.0_wp
    fmax = 0.0_wp
    DO i = 1, SIZE(dat, 2)
      IF (dat(1, i) < 1.0_wp) CYCLE
      vmax = MAX(vmax, ABS(dat(2, i)))
      fmax = MAX(fmax, ABS(dat(3, i)))
    END DO
    WRITE (*, '(A,ES10.3,A,ES10.3,A,ES10.3,A)') 'rod held by friction at a 0.1 s step: max |v| ', vmax, &
      ' m/s; max |net cross load| ', fmax, ' N against mu N L ', mun, ' N'
    CALL require(vmax <= 5.0e-3_wp, 'friction: the rod holds still (implicit friction damper)')
    CALL require(fmax <= 0.05_wp*mun, 'friction: the net cross load stays balanced')
  END SUBROUTINE check_rod_friction_hold

END PROGRAM test_body_rod_physics
