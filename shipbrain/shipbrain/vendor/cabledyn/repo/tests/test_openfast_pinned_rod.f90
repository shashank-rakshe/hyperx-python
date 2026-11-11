! File: tests/test_openfast_pinned_rod.f90
! SPDX-License-Identifier: Apache-2.0
! Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
PROGRAM test_openfast_pinned_rod
  !! Pinned and CoupledPinned rods on the OpenFAST CompMooring = 5 aggregate (the coupled rod
  !! march turning a rod about a fixed pin or about a pin the host moves). Gates:
  !!   1) a dry Pinned rod released at 30 degrees swings with the compound-pendulum period of
  !!      the complete elliptic integral (1e-3 at dt = T/100) and End A stays at the pin;
  !!   2) a CoupledPinned rod whose host node is held reproduces the Pinned rod (1e-12), returns
  !!      zero moment, and its host force is the analytic pin reaction of the swinging rod;
  !!   3) under a constant host acceleration a the rod swings about the mean angle atan(a/g)
  !!      with the period of the effective gravity sqrt(g^2 + a^2);
  !!   4) a harmonic pin motion reproduces the linear base-excitation solution, converging at
  !!      second order in dt;
  !!   5) a rod held by stiff tethers sub-cycles a coarse coupling step it could not take
  !!      explicitly and matches a run at the sub-step size; the host orientation and angular
  !!      rates are ignored;
  !!   6) snapshot / step / restore / step is bit-identical;
  !!   7) an output probe returns -M_eff a_p for a pin acceleration a_p (the re-solved rotation),
  !!      does not depend on the end acceleration the attached lines' loads were evaluated with,
  !!      and leaves the state bit-identical once restored;
  !!   8) a fresh instance overlaid with the checkpoint state (host kinematics, line interiors,
  !!      rod states, committed line-end motion) returns the same loads before the next step and
  !!      continues bit-identically;
  !!   9) PtfmInit moves the pin with the platform and the static initial condition balances the
  !!      rod about it;
  !!  10) a CoupledPinned rod outside a coupled host is refused by name;
  !!  11) the rod march needs no staged copy of the step-start rods (the rod carries its
  !!      step-start pin): a step without one is bit-identical;
  !!  12) only a Pinned or CoupledPinned rod may leave an end without a line or POINT row;
  !!  13) a short Pinned rod without a line (dry and hanging, or buoyant and upright) sub-cycles
  !!      a coupling step beyond the explicit limit of its own swing and keeps its period;
  !!  14) a CoupledPinned rod whose pin crosses the free surface within one coupling step
  !!      (submerged to dry, or dry to submerged) sub-cycles it for the stiffer of its wet states;
  !!  15) a Pinned rod whose far end rests on a stiff seabed, and a Free rod lying on it, sub-cycle
  !!      the contact mode of a large coupling step and stay at rest on the bed.
  USE CableDyn_Precision, ONLY: wp
  USE CableDyn_DeckDriver, ONLY: CD_Run_Deck_Driver, CD_DECKDRV_OK, CD_Rod_SetHostKinematics, CD_Step_Aggregate_Rod
  USE CableDyn_OpenFAST_Aggregate, ONLY: CD_AGG_ModuleType, CD_AGG_Init_From_Deck, CD_AGG_NMovingPoints, &
                                         CD_AGG_GetMovingPointMesh, CD_AGG_UpdateStates_Moving, &
                                         CD_AGG_Step_Moving, CD_AGG_CalcOutput, CD_AGG_Snapshot, CD_AGG_Restore, &
                                         CD_AGG_End, CD_AGG_OK, CD_AGG_EvalChannel, CD_AGG_NumChannels, &
                                         CD_AGG_Rod_MirrorSize, CD_AGG_Get_Rod_States, CD_AGG_Set_Rod_States, &
                                         CD_AGG_HasRod
  USE CableDyn_System, ONLY: CD_System_NLines, CD_System_Line_NDOF, CD_Get_System_Line_State, &
                             CD_Update_System_Line_Interior_State, CD_SYSTEM_OK, CD_System_NSystemCoupledDOF, &
                             CD_Get_System_CoupledMotion, CD_Update_System_CoupledMotion, CD_Calc_System_CoupledLoads
  USE, INTRINSIC :: IEEE_ARITHMETIC, ONLY: IEEE_IS_FINITE
  IMPLICIT NONE
  REAL(wp), PARAMETER :: PI = 3.141592653589793_wp, G = 9.80665_wp
  ! the dry pendulum: L = 10 m, D = 0.2 m, 50 kg/m, pinned at z = 20 m (above the water)
  REAL(wp), PARAMETER :: LP = 10.0_wp, DP = 0.2_wp, MP = 500.0_wp, ZPIN = 20.0_wp
  INTEGER :: nfail

  nfail = 0
  CALL case_pendulum_and_held_host()
  CALL case_constant_acceleration()
  CALL case_harmonic_base_excitation()
  CALL case_substep_and_state()
  CALL case_probe()
  CALL case_ptfm_static()
  CALL case_standalone_refusal()
  CALL case_unstaged_step()
  CALL case_bare_rod_ends()
  CALL case_lineless_swing_substep()
  CALL case_surface_crossing_pin()
  CALL case_seabed_contact_substep()
  IF (nfail > 0) THEN
    WRITE (*, '(A,I0,A)') 'FAIL: ', nfail, ' assertion(s) failed'
    ERROR STOP 1
  END IF
  WRITE (*, '(A)') 'PASS: Pinned and CoupledPinned rods on the coupled aggregate'

CONTAINS

  INCLUDE 'nan_max_abs.inc'

  SUBROUTINE require(cond, msg)
    LOGICAL, INTENT(IN) :: cond
    CHARACTER(*), INTENT(IN) :: msg
    IF (.NOT. cond) THEN
      WRITE (*, '(A)') 'MISMATCH: '//msg
      nfail = nfail + 1
    END IF
  END SUBROUTINE require

  ! --------------------------------------------------------------------------------------------- !
  ! decks                                                                                         !
  ! --------------------------------------------------------------------------------------------- !

  SUBROUTINE write_pendulum_deck(path, rod_type, theta_deg, standalone, nsegs)
    !! A dry rod (no drag, no added mass) pinned at End A at (0, 0, 20), above the water, released
    !! at theta_deg from the vertical in the x-z plane, deck pose (bodyIC deck); no line touches
    !! it. An independent Coupled fairlead with its own line keeps a mooring system in the deck.
    !! standalone adds the dtM/TMax clock of a standalone run; nsegs replaces NumSegs 4.
    CHARACTER(*), INTENT(IN) :: path, rod_type
    REAL(wp), INTENT(IN) :: theta_deg
    LOGICAL, INTENT(IN), OPTIONAL :: standalone
    INTEGER, INTENT(IN), OPTIONAL :: nsegs
    REAL(wp) :: th, xb, zb
    INTEGER :: u, ns
    ns = 4
    IF (PRESENT(nsegs)) ns = nsegs
    th = theta_deg*PI/180.0_wp
    xb = LP*SIN(th)
    zb = ZPIN - LP*COS(th)
    OPEN (NEWUNIT=u, FILE=path, STATUS='REPLACE', ACTION='WRITE')
    WRITE (u, '(A)') 'pinned rod pendulum on the coupled aggregate'
    WRITE (u, '(A)') '--- LINE TYPES ---'
    WRITE (u, '(A)') 'Name Diam Mass EA BA EI Cdn Cdt Can Cat'
    WRITE (u, '(A)') '(-) (m) (kg/m) (N) (-) (Nm2) (-) (-) (-) (-)'
    WRITE (u, '(A)') 'line 0.10 80.0 1.0e6 0.0 0.0 1.0 0.0 1.0 0.0'
    WRITE (u, '(A)') '--- ROD TYPES ---'
    WRITE (u, '(A)') 'Name Diam Mass Cd Ca CdEnd CaEnd'
    WRITE (u, '(A)') '(-) (m) (kg/m) (-) (-) (-) (-)'
    WRITE (u, '(A)') 'pend 0.2 50 0 0 0 0'
    WRITE (u, '(A)') '--- RODS ---'
    WRITE (u, '(A)') 'ID RodType Type XA YA ZA XB YB ZB NumSegs Outputs'
    WRITE (u, '(A)') '(-) (-) (-) (m) (m) (m) (m) (m) (m) (-) (-)'
    WRITE (u, '(A,A,A,ES24.16,A,ES24.16,A,I0,A)') '1 pend ', rod_type, ' 0 0 20 ', xb, ' 0 ', zb, ' ', ns, ' -'
    WRITE (u, '(A)') '--- POINTS ---'
    WRITE (u, '(A)') 'ID Type X Y Z Mass Vol CdA Ca'
    WRITE (u, '(A)') '(-) (-) (m) (m) (m) (kg) (m3) (m2) (-)'
    WRITE (u, '(A)') '1 Coupled 0.0 30.0 -1.0 0 0 0 0'
    WRITE (u, '(A)') '2 Fixed 6.0 30.0 -8.0 0 0 0 0'
    WRITE (u, '(A)') '--- LINES ---'
    WRITE (u, '(A)') 'ID NodeA NodeB Outputs'
    WRITE (u, '(A)') '(-) (-) (-) (-)'
    WRITE (u, '(A)') '1 1 2 -'
    WRITE (u, '(A)') '--- SECTIONS ---'
    WRITE (u, '(A)') 'LineID LineType Length NumSegs'
    WRITE (u, '(A)') '(-) (-) (m) (-)'
    WRITE (u, '(A)') '1 line 9.5 6'
    WRITE (u, '(A)') '--- OPTIONS ---'
    WRITE (u, '(A)') '9.80665 g'
    WRITE (u, '(A)') '1025.0 rhoW'
    WRITE (u, '(A)') '10.0 WtrDpth'
    WRITE (u, '(A)') '1.0e5 kBot'
    WRITE (u, '(A)') 'deck bodyIC'
    IF (PRESENT(standalone)) THEN
      IF (standalone) THEN
        WRITE (u, '(A)') '0.01 dtM'
        WRITE (u, '(A)') '0.1 TMax'
      END IF
    END IF
    WRITE (u, '(A)') '--- end ---'
    CLOSE (u)
  END SUBROUTINE write_pendulum_deck

  SUBROUTINE write_short_pendulum_deck(path, mass_pm, zpin, upright, theta_deg, rod_type)
    !! A 1 m Pinned rod (rod_type replaces Pinned; D = 0.2 m, mass_pm kg/m, no drag or added
    !! mass) pinned at End A at (0, 0, zpin) and released at theta_deg in the x-z plane from the
    !! downward vertical (from the upward one with upright), deck pose; no line touches it. The
    !! fairlead line of write_pendulum_deck keeps a mooring system in the deck.
    CHARACTER(*), INTENT(IN) :: path
    REAL(wp), INTENT(IN) :: mass_pm, zpin, theta_deg
    LOGICAL, INTENT(IN) :: upright
    CHARACTER(*), INTENT(IN), OPTIONAL :: rod_type
    CHARACTER(16) :: rt
    REAL(wp) :: th, xb, zb
    INTEGER :: u
    rt = 'Pinned'
    IF (PRESENT(rod_type)) rt = rod_type
    th = theta_deg*PI/180.0_wp
    xb = SIN(th)
    zb = zpin - COS(th)
    IF (upright) zb = zpin + COS(th)
    OPEN (NEWUNIT=u, FILE=path, STATUS='REPLACE', ACTION='WRITE')
    WRITE (u, '(A)') 'short pinned rod pendulum on the coupled aggregate'
    WRITE (u, '(A)') '--- LINE TYPES ---'
    WRITE (u, '(A)') 'Name Diam Mass EA BA EI Cdn Cdt Can Cat'
    WRITE (u, '(A)') '(-) (m) (kg/m) (N) (-) (Nm2) (-) (-) (-) (-)'
    WRITE (u, '(A)') 'line 0.10 80.0 1.0e6 0.0 0.0 1.0 0.0 1.0 0.0'
    WRITE (u, '(A)') '--- ROD TYPES ---'
    WRITE (u, '(A)') 'Name Diam Mass Cd Ca CdEnd CaEnd'
    WRITE (u, '(A)') '(-) (m) (kg/m) (-) (-) (-) (-)'
    WRITE (u, '(A,ES24.16,A)') 'pend 0.2 ', mass_pm, ' 0 0 0 0'
    WRITE (u, '(A)') '--- RODS ---'
    WRITE (u, '(A)') 'ID RodType Type XA YA ZA XB YB ZB NumSegs Outputs'
    WRITE (u, '(A)') '(-) (-) (-) (m) (m) (m) (m) (m) (m) (-) (-)'
    WRITE (u, '(A,ES24.16,A,ES24.16,A,ES24.16,A)') '1 pend '//TRIM(rt)//' 0 0 ', zpin, ' ', xb, ' 0 ', zb, ' 4 -'
    WRITE (u, '(A)') '--- POINTS ---'
    WRITE (u, '(A)') 'ID Type X Y Z Mass Vol CdA Ca'
    WRITE (u, '(A)') '(-) (-) (m) (m) (m) (kg) (m3) (m2) (-)'
    WRITE (u, '(A)') '1 Coupled 0.0 30.0 -1.0 0 0 0 0'
    WRITE (u, '(A)') '2 Fixed 6.0 30.0 -8.0 0 0 0 0'
    WRITE (u, '(A)') '--- LINES ---'
    WRITE (u, '(A)') 'ID NodeA NodeB Outputs'
    WRITE (u, '(A)') '(-) (-) (-) (-)'
    WRITE (u, '(A)') '1 1 2 -'
    WRITE (u, '(A)') '--- SECTIONS ---'
    WRITE (u, '(A)') 'LineID LineType Length NumSegs'
    WRITE (u, '(A)') '(-) (-) (m) (-)'
    WRITE (u, '(A)') '1 line 9.5 6'
    WRITE (u, '(A)') '--- OPTIONS ---'
    WRITE (u, '(A)') '9.80665 g'
    WRITE (u, '(A)') '1025.0 rhoW'
    WRITE (u, '(A)') '30.0 WtrDpth'
    WRITE (u, '(A)') '1.0e5 kBot'
    WRITE (u, '(A)') 'deck bodyIC'
    WRITE (u, '(A)') '--- end ---'
    CLOSE (u)
  END SUBROUTINE write_short_pendulum_deck

  SUBROUTINE write_tethered_deck(path, rod_type, body_ic)
    !! A submerged rod (2 m, 0.2 m diameter, Cd = Ca = 1) hanging from End A at (0, 0, -10), held
    !! at End B by two horizontal tethers to anchors at x = +/-10 m (EA 2e5 N, 0.5 % pretension):
    !! the rotation about y meets their axial stiffness, a stiff mode of about 27 rad/s. End A
    !! carries no line and has no Rod1A POINT row, which the coupled route does not need. An
    !! independent Coupled fairlead with its own line comes first in the moving surface. The
    !! deck asks for the rod's net load about End A (Rod1F/Rod1M).
    CHARACTER(*), INTENT(IN) :: path, rod_type, body_ic
    INTEGER :: u
    OPEN (NEWUNIT=u, FILE=path, STATUS='REPLACE', ACTION='WRITE')
    WRITE (u, '(A)') 'tethered pinned rod on the coupled aggregate'
    WRITE (u, '(A)') '--- LINE TYPES ---'
    WRITE (u, '(A)') 'Name Diam Mass EA BA EI Cdn Cdt Can Cat'
    WRITE (u, '(A)') '(-) (m) (kg/m) (N) (-) (Nm2) (-) (-) (-) (-)'
    WRITE (u, '(A)') 'line 0.10 80.0 1.0e6 0.0 0.0 1.0 0.0 1.0 0.0'
    WRITE (u, '(A)') 'tether 0.05 4.0 2.0e5 0.0 0.0 1.0 0.0 1.0 0.0'
    WRITE (u, '(A)') '--- ROD TYPES ---'
    WRITE (u, '(A)') 'Name Diam Mass Cd Ca CdEnd CaEnd'
    WRITE (u, '(A)') '(-) (m) (kg/m) (-) (-) (-) (-)'
    WRITE (u, '(A)') 'arm 0.2 50 1.0 1.0 0.0 0.0'
    WRITE (u, '(A)') '--- RODS ---'
    WRITE (u, '(A)') 'ID RodType Type XA YA ZA XB YB ZB NumSegs Outputs'
    WRITE (u, '(A)') '(-) (-) (-) (m) (m) (m) (m) (m) (m) (-) (-)'
    WRITE (u, '(A)') '1 arm '//rod_type//' 0 0 -10 0 0 -12 4 -'
    WRITE (u, '(A)') '--- POINTS ---'
    WRITE (u, '(A)') 'ID Type X Y Z Mass Vol CdA Ca'
    WRITE (u, '(A)') '(-) (-) (m) (m) (m) (kg) (m3) (m2) (-)'
    WRITE (u, '(A)') '1 Coupled 0.0 30.0 -1.0 0 0 0 0'
    WRITE (u, '(A)') '2 Fixed 6.0 30.0 -8.0 0 0 0 0'
    WRITE (u, '(A)') '3 Fixed 10.0 0 -12 0 0 0 0'
    WRITE (u, '(A)') '4 Fixed -10.0 0 -12 0 0 0 0'
    WRITE (u, '(A)') '--- LINES ---'
    WRITE (u, '(A)') 'ID NodeA NodeB Outputs'
    WRITE (u, '(A)') '(-) (-) (-) (-)'
    WRITE (u, '(A)') '1 1 2 -'
    WRITE (u, '(A)') '2 R1B 3 -'
    WRITE (u, '(A)') '3 R1B 4 -'
    WRITE (u, '(A)') '--- SECTIONS ---'
    WRITE (u, '(A)') 'LineID LineType Length NumSegs'
    WRITE (u, '(A)') '(-) (-) (m) (-)'
    WRITE (u, '(A)') '1 line 9.5 6'
    WRITE (u, '(A)') '2 tether 9.95 10'
    WRITE (u, '(A)') '3 tether 9.95 10'
    WRITE (u, '(A)') '--- OPTIONS ---'
    WRITE (u, '(A)') '9.80665 g'
    WRITE (u, '(A)') '1025.0 rhoW'
    WRITE (u, '(A)') '20.0 WtrDpth'
    WRITE (u, '(A)') '1.0e5 kBot'
    WRITE (u, '(A)') body_ic//' bodyIC'
    WRITE (u, '(A)') '--- OUTPUTS ---'
    WRITE (u, '(A)') 'Rod1Fx'
    WRITE (u, '(A)') 'Rod1Fy'
    WRITE (u, '(A)') 'Rod1Fz'
    WRITE (u, '(A)') 'Rod1Mx'
    WRITE (u, '(A)') 'Rod1My'
    WRITE (u, '(A)') 'Rod1Mz'
    WRITE (u, '(A)') '--- end ---'
    CLOSE (u)
  END SUBROUTINE write_tethered_deck

  ! --------------------------------------------------------------------------------------------- !
  ! helpers                                                                                       !
  ! --------------------------------------------------------------------------------------------- !

  REAL(wp) FUNCTION rod_angle(s) RESULT(th)
    !! Angle of the rod axis (End A -> End B) from the downward vertical, positive towards +x.
    REAL(wp), INTENT(IN) :: s(:)
    th = ATAN2(s(16), -s(18))
  END FUNCTION rod_angle

  REAL(wp) FUNCTION ellip_k(k) RESULT(kk)
    !! Complete elliptic integral of the first kind by the arithmetic-geometric mean.
    REAL(wp), INTENT(IN) :: k
    REAL(wp) :: a, b, c
    INTEGER :: i
    a = 1.0_wp
    b = SQRT(1.0_wp - k*k)
    DO i = 1, 30
      c = 0.5_wp*(a + b)
      b = SQRT(a*b)
      a = c
    END DO
    kk = PI/(2.0_wp*a)
  END FUNCTION ellip_k

  SUBROUTINE crossings(t, x, xm, period, mean)
    !! Mean period between the up-crossings of x through xm and the mean of x over those whole
    !! periods (trapezoidal); period = -1 with fewer than three crossings.
    REAL(wp), INTENT(IN) :: t(:), x(:), xm
    REAL(wp), INTENT(OUT) :: period, mean
    REAL(wp) :: tc, t0, t1, area
    INTEGER :: i, n, i0, i1
    n = 0
    t0 = 0.0_wp
    t1 = 0.0_wp
    i0 = 0
    i1 = 0
    DO i = 1, SIZE(x) - 1
      IF (x(i) - xm < 0.0_wp .AND. x(i + 1) - xm >= 0.0_wp) THEN
        tc = t(i) + (xm - x(i))*(t(i + 1) - t(i))/(x(i + 1) - x(i))
        IF (n == 0) THEN
          t0 = tc
          i0 = i
        END IF
        t1 = tc
        i1 = i
        n = n + 1
      END IF
    END DO
    period = -1.0_wp
    mean = 0.0_wp
    IF (n < 3) RETURN
    period = (t1 - t0)/REAL(n - 1, wp)
    ! the crossing value xm closes both ends of the window
    area = 0.5_wp*(xm + x(i0 + 1))*(t(i0 + 1) - t0) + 0.5_wp*(x(i1) + xm)*(t1 - t(i1))
    DO i = i0 + 1, i1 - 1
      area = area + 0.5_wp*(x(i) + x(i + 1))*(t(i + 1) - t(i))
    END DO
    mean = area/(t1 - t0)
  END SUBROUTINE crossings

  FUNCTION pin_inertia(s) RESULT(ip)
    !! Inertia tensor of the dry pendulum rod about its pin (End A), global axes.
    REAL(wp), INTENT(IN) :: s(:)
    REAL(wp) :: ip(3, 3), rot(3, 3), ib(3, 3), arm(3)
    INTEGER :: k
    rot = RESHAPE(s(16:24), [3, 3])
    ib = 0.0_wp
    ib(1, 1) = 0.5_wp*MP*(0.5_wp*DP)**2
    ib(2, 2) = MP*(3.0_wp*(0.5_wp*DP)**2 + LP*LP)/12.0_wp
    ib(3, 3) = ib(2, 2)
    arm = 0.5_wp*LP*rot(:, 1)
    ip = MATMUL(rot, MATMUL(ib, TRANSPOSE(rot)))
    DO k = 1, 3
      ip(k, k) = ip(k, k) + MP*DOT_PRODUCT(arm, arm)
    END DO
    ip = ip - MP*SPREAD(arm, 2, 3)*SPREAD(arm, 1, 3)
  END FUNCTION pin_inertia

  FUNCTION solve3(a, b) RESULT(x)
    !! x = a^-1 b by Cramer's rule (a 3x3, well conditioned here).
    REAL(wp), INTENT(IN) :: a(3, 3), b(3)
    REAL(wp) :: x(3), d, c(3, 3)
    INTEGER :: k
    d = det3(a)
    DO k = 1, 3
      c = a
      c(:, k) = b
      x(k) = det3(c)/d
    END DO
  END FUNCTION solve3

  PURE REAL(wp) FUNCTION det3(m) RESULT(d)
    REAL(wp), INTENT(IN) :: m(3, 3)
    d = m(1, 1)*(m(2, 2)*m(3, 3) - m(2, 3)*m(3, 2)) - m(1, 2)*(m(2, 1)*m(3, 3) - m(2, 3)*m(3, 1)) + &
        m(1, 3)*(m(2, 1)*m(3, 2) - m(2, 2)*m(3, 1))
  END FUNCTION det3

  PURE FUNCTION cross(x, y) RESULT(z)
    REAL(wp), INTENT(IN) :: x(3), y(3)
    REAL(wp) :: z(3)
    z = [x(2)*y(3) - x(3)*y(2), x(3)*y(1) - x(1)*y(3), x(1)*y(2) - x(2)*y(1)]
  END FUNCTION cross

  FUNCTION pin_reaction(s, a_pin) RESULT(f)
    !! The force a dry rod exerts on its pin at state s (rod mirror) for a pin acceleration
    !! a_pin: Euler's equation about the pin, I_p alpha + w x (I_p w) = r x m (g - a_pin), then
    !! f = m g - m (a_pin + alpha x r + w x (w x r)), g = (0, 0, -9.80665).
    REAL(wp), INTENT(IN) :: s(:), a_pin(3)
    REAL(wp) :: f(3), ip(3, 3), arm(3), w(3), alpha(3), gv(3)
    ip = pin_inertia(s)
    arm = 0.5_wp*LP*s(16:18)
    w = s(10:12)
    gv = [0.0_wp, 0.0_wp, -G]
    alpha = solve3(ip, cross(arm, MP*(gv - a_pin)) - cross(w, MATMUL(ip, w)))
    f = MP*gv - MP*(a_pin + cross(alpha, arm) + cross(w, cross(w, arm)))
  END FUNCTION pin_reaction

  SUBROUTINE march(agg, dt, nstep, host, ang, t, ok, s_end, force)
    !! March nstep coupling steps, the last moving column (the rod's pin when present) driven by
    !! host(t) = [position, velocity, acceleration] and every other column held at its initial
    !! position; ang(0:nstep) the rod angle, t the times. Before the first step the host
    !! kinematics at t = 0 are transferred (the start of the run, as the coupled shell does).
    TYPE(CD_AGG_ModuleType), INTENT(INOUT) :: agg
    REAL(wp), INTENT(IN) :: dt
    INTEGER, INTENT(IN) :: nstep
    INTERFACE
      FUNCTION host(time) RESULT(k)
        IMPORT :: wp
        REAL(wp), INTENT(IN) :: time
        REAL(wp) :: k(9)
      END FUNCTION host
    END INTERFACE
    REAL(wp), INTENT(OUT) :: ang(0:nstep), t(0:nstep)
    LOGICAL, INTENT(OUT) :: ok
    REAL(wp), INTENT(OUT), OPTIONAL :: s_end(24), force(3, 0:nstep)
    REAL(wp), ALLOCATABLE :: p(:, :), v(:, :), a(:, :), f(:, :), p0(:, :), s(:)
    REAL(wp) :: k(9)
    INTEGER :: n, es, it, step
    LOGICAL :: cv, st
    CHARACTER(512) :: em

    ok = .FALSE.
    n = CD_AGG_NMovingPoints(agg, es, em)
    ALLOCATE (p(3, n), v(3, n), a(3, n), f(3, n), p0(3, n), s(CD_AGG_Rod_MirrorSize(agg)))
    CALL CD_AGG_GetMovingPointMesh(agg, p0, v, a, f, es, em)
    v = 0.0_wp
    a = 0.0_wp
    p = p0
    k = host(0.0_wp)
    p(:, n) = p0(:, n) + k(1:3)
    v(:, n) = k(4:6)
    a(:, n) = k(7:9)
    CALL CD_AGG_UpdateStates_Moving(agg, p, v, a, es, em)
    CALL require(es == CD_AGG_OK, 'march:start-transfer: '//TRIM(em))
    IF (es /= CD_AGG_OK) RETURN
    CALL CD_AGG_Get_Rod_States(agg, s, es, em)
    ang(0) = rod_angle(s)
    t(0) = 0.0_wp
    IF (PRESENT(force)) THEN
      CALL CD_AGG_CalcOutput(agg, es, em)
      CALL CD_AGG_GetMovingPointMesh(agg, p, v, a, f, es, em)
      force(:, 0) = f(:, n)
    END IF
    DO step = 1, nstep
      t(step) = REAL(step, wp)*dt
      k = host(t(step))
      p = p0
      v = 0.0_wp
      a = 0.0_wp
      p(:, n) = p0(:, n) + k(1:3)
      v(:, n) = k(4:6)
      a(:, n) = k(7:9)
      CALL CD_AGG_Step_Moving(agg, dt, p, v, a, cv, st, it, es, em, t_committed=t(step))
      CALL require(es == CD_AGG_OK .AND. cv, 'march:step: '//TRIM(em))
      IF (es /= CD_AGG_OK) RETURN
      CALL CD_AGG_Get_Rod_States(agg, s, es, em)
      ang(step) = rod_angle(s)
      IF (PRESENT(force)) THEN
        CALL CD_AGG_CalcOutput(agg, es, em)
        CALL CD_AGG_GetMovingPointMesh(agg, p, v, a, f, es, em)
        force(:, step) = f(:, n)
      END IF
    END DO
    IF (PRESENT(s_end)) s_end = s
    ok = ALL(IEEE_IS_FINITE(ang))
  END SUBROUTINE march

  ! --------------------------------------------------------------------------------------------- !
  ! 1-2: the fixed-pin pendulum and the held host                                                 !
  ! --------------------------------------------------------------------------------------------- !

  SUBROUTINE case_pendulum_and_held_host()
    TYPE(CD_AGG_ModuleType) :: pinned, held
    REAL(wp), PARAMETER :: TH0 = 30.0_wp
    REAL(wp), ALLOCATABLE :: p(:, :), v(:, :), a(:, :), f(:, :), mo(:, :), p0(:, :)
    REAL(wp), ALLOCATABLE :: ang(:), t(:)
    REAL(wp) :: s1(24), s2(24), ia, t_ref, dt, period, mean, err_state, err_pin, err_force, fref(3), pin(3)
    INTEGER :: es, n, nstep, step, it
    LOGICAL :: cv, st
    CHARACTER(512) :: em

    ia = MP*(LP*LP/3.0_wp + DP*DP/16.0_wp)
    t_ref = 4.0_wp*SQRT(ia/(MP*G*0.5_wp*LP))*ellip_k(SIN(0.5_wp*TH0*PI/180.0_wp))
    dt = t_ref/100.0_wp
    nstep = 500
    CALL write_pendulum_deck('pinrod_pendulum.dat', 'Pinned', TH0)
    CALL write_pendulum_deck('pinrod_pendulum_held.dat', 'CoupledPinned', TH0)
    CALL CD_AGG_Init_From_Deck(pinned, 'pinrod_pendulum.dat', dt, es, em)
    CALL require(es == CD_AGG_OK, 'pendulum:init: '//TRIM(em))
    IF (es /= CD_AGG_OK) RETURN
    CALL CD_AGG_Init_From_Deck(held, 'pinrod_pendulum_held.dat', dt, es, em)
    CALL require(es == CD_AGG_OK, 'held:init: '//TRIM(em))
    IF (es /= CD_AGG_OK) RETURN
    n = CD_AGG_NMovingPoints(pinned, es, em)
    CALL require(CD_AGG_HasRod(pinned) .AND. n == 1, &
                 'pendulum:a Pinned rod adds no host node')
    n = CD_AGG_NMovingPoints(held, es, em)
    CALL require(n == 2, 'held:one host node for the CoupledPinned rod after the fairlead')
    IF (n /= 2) RETURN
    ALLOCATE (p(3, 2), v(3, 2), a(3, 2), f(3, 2), mo(3, 2), p0(3, 2), ang(0:nstep), t(0:nstep))
    CALL CD_AGG_GetMovingPointMesh(held, p0, v, a, f, es, em)
    CALL require(nan_max_abs(p0(:, 2) - [0.0_wp, 0.0_wp, ZPIN]) <= 1.0e-13_wp, 'held:host node at End A')
    p = p0
    v = 0.0_wp
    a = 0.0_wp
    CALL CD_AGG_Get_Rod_States(pinned, s1, es, em)
    ang(0) = rod_angle(s1)
    t(0) = 0.0_wp
    err_state = 0.0_wp
    err_pin = 0.0_wp
    err_force = 0.0_wp
    pin = [0.0_wp, 0.0_wp, ZPIN]
    DO step = 0, nstep
      IF (step > 0) THEN
        CALL CD_AGG_Step_Moving(pinned, dt, p(:, 1:1), v(:, 1:1), a(:, 1:1), cv, st, it, es, em, &
                                t_committed=REAL(step, wp)*dt)
        CALL require(es == CD_AGG_OK .AND. cv, 'pendulum:step: '//TRIM(em))
        IF (es /= CD_AGG_OK) RETURN
        CALL CD_AGG_Step_Moving(held, dt, p, v, a, cv, st, it, es, em, t_committed=REAL(step, wp)*dt)
        CALL require(es == CD_AGG_OK .AND. cv, 'held:step: '//TRIM(em))
        IF (es /= CD_AGG_OK) RETURN
      END IF
      CALL CD_AGG_Get_Rod_States(pinned, s1, es, em)
      CALL CD_AGG_Get_Rod_States(held, s2, es, em)
      t(step) = REAL(step, wp)*dt
      ang(step) = rod_angle(s1)
      err_pin = MAX(err_pin, nan_max_abs(s1(1:3) - 0.5_wp*LP*s1(16:18) - pin))
      err_state = MAX(err_state, nan_max_abs(s2 - s1)/MAX(1.0_wp, nan_max_abs(s1)))
      CALL CD_AGG_CalcOutput(held, es, em)
      CALL CD_AGG_GetMovingPointMesh(held, p, v, a, f, es, em, moment=mo)
      CALL require(es == CD_AGG_OK, 'held:mesh: '//TRIM(em))
      CALL require(nan_max_abs(mo(:, 2)) <= 0.0_wp, 'held:host moment is zero')
      fref = pin_reaction(s2, [0.0_wp, 0.0_wp, 0.0_wp])
      err_force = MAX(err_force, nan_max_abs(f(:, 2) - fref)/(MP*G))
      p = p0
      v = 0.0_wp
      a = 0.0_wp
    END DO
    CALL crossings(t, ang, 0.0_wp, period, mean)
    WRITE (*, '(A,2F12.6,A,ES10.3)') 'coupled Pinned pendulum period got/analytic [s]: ', period, t_ref, &
      '; rel. error ', ABS(period - t_ref)/t_ref
    WRITE (*, '(A,ES10.3,A,ES10.3,A,ES10.3)') 'max |End A - pin| [m] ', err_pin, &
      '; held CoupledPinned vs Pinned state ', err_state, '; host force vs pin reaction / mg ', err_force
    CALL require(ABS(period - t_ref) <= 1.0e-3_wp*t_ref, 'pendulum:period (elliptic integral)')
    CALL require(err_pin <= 1.0e-12_wp, 'pendulum:End A stays at the pin')
    CALL require(err_state <= 1.0e-12_wp, 'held:CoupledPinned with the host held equals Pinned')
    CALL require(err_force <= 1.0e-10_wp, 'held:host force is the analytic pin reaction')
    CALL CD_AGG_End(pinned, es, em)
    CALL CD_AGG_End(held, es, em)
  END SUBROUTINE case_pendulum_and_held_host

  ! --------------------------------------------------------------------------------------------- !
  ! 3: constant host acceleration                                                                 !
  ! --------------------------------------------------------------------------------------------- !

  FUNCTION host_const(time) RESULT(k)
    !! The pin accelerating uniformly along +x from rest: a = 2 m/s^2.
    REAL(wp), INTENT(IN) :: time
    REAL(wp) :: k(9)
    REAL(wp), PARAMETER :: AX = 2.0_wp
    k = 0.0_wp
    k(1) = 0.5_wp*AX*time*time
    k(4) = AX*time
    k(7) = AX
  END FUNCTION host_const

  SUBROUTINE case_constant_acceleration()
    !! In the frame of a pin accelerating at a along x the rod is a pendulum in the effective
    !! gravity (-a, 0, -g): it swings about theta_eq = -atan(a/g) (trailing) with the period
    !! 4 sqrt(I_p/(m h g_eff)) K(sin(delta/2)), g_eff = sqrt(g^2 + a^2), for an amplitude delta.
    TYPE(CD_AGG_ModuleType) :: agg
    REAL(wp), PARAMETER :: AX = 2.0_wp, DELTA = 5.0_wp
    REAL(wp), ALLOCATABLE :: ang(:), t(:)
    REAL(wp) :: ia, th_eq, geff, t_ref, dt, period, mean
    INTEGER :: es, nstep
    LOGICAL :: ok
    CHARACTER(512) :: em

    th_eq = -ATAN(AX/G)
    geff = SQRT(G*G + AX*AX)
    ia = MP*(LP*LP/3.0_wp + DP*DP/16.0_wp)
    t_ref = 4.0_wp*SQRT(ia/(MP*geff*0.5_wp*LP))*ellip_k(SIN(0.5_wp*DELTA*PI/180.0_wp))
    dt = t_ref/100.0_wp
    nstep = 500
    CALL write_pendulum_deck('pinrod_accel.dat', 'CoupledPinned', th_eq*180.0_wp/PI + DELTA)
    CALL CD_AGG_Init_From_Deck(agg, 'pinrod_accel.dat', dt, es, em)
    CALL require(es == CD_AGG_OK, 'accel:init: '//TRIM(em))
    IF (es /= CD_AGG_OK) RETURN
    ALLOCATE (ang(0:nstep), t(0:nstep))
    CALL march(agg, dt, nstep, host_const, ang, t, ok)
    CALL require(ok, 'accel:march finite')
    IF (.NOT. ok) RETURN
    CALL crossings(t, ang, th_eq, period, mean)
    WRITE (*, '(A,2F12.6,A,2F10.6)') 'constant pin acceleration: period got/analytic [s] ', period, t_ref, &
      '; mean angle got/atan(a/g) [rad] ', mean, th_eq
    CALL require(ABS(period - t_ref) <= 1.0e-3_wp*t_ref, 'accel:period with g_eff')
    CALL require(ABS(mean - th_eq) <= 1.0e-4_wp, 'accel:mean angle -atan(a/g)')
    CALL CD_AGG_End(agg, es, em)
  END SUBROUTINE case_constant_acceleration

  ! --------------------------------------------------------------------------------------------- !
  ! 4: harmonic base excitation                                                                   !
  ! --------------------------------------------------------------------------------------------- !

  FUNCTION host_harm(time) RESULT(k)
    !! x_p = X (1 - cos W t): the pin starts at rest, X = 0.05 m, W = 0.6 w0.
    REAL(wp), INTENT(IN) :: time
    REAL(wp) :: k(9), w
    REAL(wp), PARAMETER :: X = 0.05_wp
    w = 0.6_wp*omega0()
    k = 0.0_wp
    k(1) = X*(1.0_wp - COS(w*time))
    k(4) = X*w*SIN(w*time)
    k(7) = X*w*w*COS(w*time)
  END FUNCTION host_harm

  REAL(wp) FUNCTION omega0() RESULT(w0)
    !! Small-amplitude natural frequency of the dry pendulum about its pin.
    w0 = SQRT(MP*G*0.5_wp*LP/(MP*(LP*LP/3.0_wp + DP*DP/16.0_wp)))
  END FUNCTION omega0

  SUBROUTINE case_harmonic_base_excitation()
    !! Linear base excitation of the pendulum from rest, theta'' + w0^2 theta = -(m h/I_p) a_p(t):
    !! theta = -(m h/I_p) X W^2 (cos W t - cos w0 t)/(w0^2 - W^2). The amplitude is about 0.01
    !! rad, so the neglected sin/cos terms stay near 1e-4 of it; three natural periods at
    !! dt = T0/100 and T0/200 must converge at second order to below 2e-3 of the amplitude.
    TYPE(CD_AGG_ModuleType) :: agg
    REAL(wp), ALLOCATABLE :: ang(:), t(:), ref(:)
    REAL(wp) :: w0, w, kap, dt, err(2), amp
    INTEGER :: es, nstep, ires, i
    LOGICAL :: ok
    CHARACTER(512) :: em

    w0 = omega0()
    w = 0.6_wp*w0
    kap = MP*0.5_wp*LP/(MP*(LP*LP/3.0_wp + DP*DP/16.0_wp))
    CALL write_pendulum_deck('pinrod_harm.dat', 'CoupledPinned', 0.0_wp)
    DO ires = 1, 2
      nstep = 300*ires
      dt = 2.0_wp*PI/w0/REAL(100*ires, wp)
      CALL CD_AGG_Init_From_Deck(agg, 'pinrod_harm.dat', dt, es, em)
      CALL require(es == CD_AGG_OK, 'harm:init: '//TRIM(em))
      IF (es /= CD_AGG_OK) RETURN
      ALLOCATE (ang(0:nstep), t(0:nstep), ref(0:nstep))
      CALL march(agg, dt, nstep, host_harm, ang, t, ok)
      CALL require(ok, 'harm:march finite')
      IF (.NOT. ok) RETURN
      DO i = 0, nstep
        ref(i) = -kap*0.05_wp*w*w*(COS(w*t(i)) - COS(w0*t(i)))/(w0*w0 - w*w)
      END DO
      amp = nan_max_abs(ref)
      err(ires) = nan_max_abs(ang - ref)/amp
      DEALLOCATE (ang, t, ref)
      CALL CD_AGG_End(agg, es, em)
    END DO
    WRITE (*, '(A,ES10.3,A,2ES10.3,A,F6.2)') 'harmonic pin motion: amplitude ', amp, &
      ' rad; rel. error dt = T0/100, T0/200: ', err, '; ratio ', err(1)/err(2)
    CALL require(err(2) <= 2.0e-3_wp, 'harm:linear base-excitation solution')
    CALL require(err(1)/err(2) > 3.0_wp, 'harm:second-order convergence')
  END SUBROUTINE case_harmonic_base_excitation

  ! --------------------------------------------------------------------------------------------- !
  ! 5-6, 8: sub-stepping, snapshot / restore, restart overlay                                     !
  ! --------------------------------------------------------------------------------------------- !

  FUNCTION host_surge(time) RESULT(k)
    !! x_p = X (1 - cos W t), X = 0.2 m, a 5 s period.
    REAL(wp), INTENT(IN) :: time
    REAL(wp) :: k(9), w
    REAL(wp), PARAMETER :: X = 0.2_wp
    w = 2.0_wp*PI/5.0_wp
    k = 0.0_wp
    k(1) = X*(1.0_wp - COS(w*time))
    k(4) = X*w*SIN(w*time)
    k(7) = X*w*w*COS(w*time)
  END FUNCTION host_surge

  FUNCTION host_drift(time) RESULT(k)
    !! The pin drifting along +x at a constant 0.05 m/s from t = 0.
    REAL(wp), INTENT(IN) :: time
    REAL(wp) :: k(9)
    k = 0.0_wp
    k(1) = 0.05_wp*time
    k(4) = 0.05_wp
  END FUNCTION host_drift

  SUBROUTINE case_substep_and_state()
    !! The tethered rod's stiff mode (about 27 rad/s) makes omega dt about 2.7 at a 0.1 s
    !! coupling step, beyond the explicit limit of 2: the march must sub-cycle it (7 sub-steps).
    !! Against a run at the sub-step size: a pin drifting at constant velocity, which the linear
    !! interpolation of the host motion inside a step represents exactly, gives the same rod
    !! motion and pin force; a harmonic surge gives the same rod motion within 1 % (the
    !! interpolated pin path deviates by a dt^2 a/8 that the stiff tethers turn into a few N).
    !! On the coarse run: host orientation and angular rates are ignored for the pin node;
    !! snapshot/step/restore/step and the restart overlay are bit-identical.
    TYPE(CD_AGG_ModuleType) :: coarse, fine, turned, agg_b
    REAL(wp), PARAMETER :: DTC = 0.1_wp
    INTEGER, PARAMETER :: NSUB = 7, NC = 60
    REAL(wp), ALLOCATABLE :: angc(:), tc(:), angf(:), tf(:), fc(:, :), ff(:, :)
    REAL(wp), ALLOCATABLE :: p(:, :), v(:, :), a(:, :), f(:, :), fb(:, :), mo(:, :), mb(:, :), p0(:, :)
    REAL(wp), ALLOCATABLE :: orr(:, :, :), w(:, :), al(:, :), lq(:), lv(:), la(:), rs(:), rs2(:)
    REAL(wp), ALLOCATABLE :: cq(:), cvv(:), ca(:)
    REAL(wp) :: err_ang, err_f, amp, famp, k(9), th, err
    INTEGER :: es, i, n, step, it, nl, il, ndof, kind, ncd
    LOGICAL :: ok, cv, st
    CHARACTER(512) :: em

    CALL write_tethered_deck('pinrod_tether.dat', 'CoupledPinned', 'deck')
    ALLOCATE (angc(0:NC), tc(0:NC), angf(0:NC*NSUB), tf(0:NC*NSUB), fc(3, 0:NC), ff(3, 0:NC*NSUB))
    DO kind = 1, 2
      CALL CD_AGG_Init_From_Deck(coarse, 'pinrod_tether.dat', DTC, es, em)
      CALL require(es == CD_AGG_OK, 'substep:coarse-init: '//TRIM(em))
      IF (es /= CD_AGG_OK) RETURN
      CALL CD_AGG_Init_From_Deck(fine, 'pinrod_tether.dat', DTC/REAL(NSUB, wp), es, em)
      CALL require(es == CD_AGG_OK, 'substep:fine-init: '//TRIM(em))
      IF (es /= CD_AGG_OK) RETURN
      IF (kind == 1) THEN
        CALL march(coarse, DTC, NC, host_drift, angc, tc, ok, force=fc)
        CALL require(ok, 'substep:coarse march finite (the stiff mode is sub-cycled)')
        CALL march(fine, DTC/REAL(NSUB, wp), NC*NSUB, host_drift, angf, tf, ok, force=ff)
      ELSE
        CALL march(coarse, DTC, NC, host_surge, angc, tc, ok, force=fc)
        CALL require(ok, 'substep:coarse march finite (the stiff mode is sub-cycled)')
        CALL march(fine, DTC/REAL(NSUB, wp), NC*NSUB, host_surge, angf, tf, ok, force=ff)
      END IF
      CALL require(ok, 'substep:fine march finite')
      IF (.NOT. ok) RETURN
      err_ang = 0.0_wp
      err_f = 0.0_wp
      DO i = 0, NC
        err_ang = MAX(err_ang, ABS(angc(i) - angf(NSUB*i)))
        err_f = MAX(err_f, nan_max_abs(fc(:, i) - ff(:, NSUB*i)))
      END DO
      amp = nan_max_abs(angf)
      famp = nan_max_abs(ff)
      WRITE (*, '(A,I0,A,ES10.3,A,ES10.3,A,ES10.3,A,ES10.3)') 'sub-cycled coarse step vs sub-step run (', kind, &
        '): angle ', err_ang, ' of ', amp, ' rad; pin force ', err_f, ' of ', famp
      CALL require(amp > 0.05_wp, 'substep:the pin motion turns the rod')
      IF (kind == 1) THEN
        CALL require(err_ang <= 1.0e-8_wp*amp .AND. err_f <= 1.0e-8_wp*famp, &
                     'substep:drifting pin: coarse equals fine')
        CALL CD_AGG_End(coarse, es, em)
      ELSE
        CALL require(err_ang <= 1.0e-2_wp*amp, 'substep:surge: coarse equals fine (angle)')
      END IF
      CALL CD_AGG_End(fine, es, em)
    END DO

    ! the host orientation and angular rates do not reach a CoupledPinned rod
    n = CD_AGG_NMovingPoints(coarse, es, em)
    ALLOCATE (p(3, n), v(3, n), a(3, n), f(3, n), fb(3, n), mo(3, n), mb(3, n), p0(3, n))
    ALLOCATE (orr(3, 3, n), w(3, n), al(3, n), rs(CD_AGG_Rod_MirrorSize(coarse)), rs2(CD_AGG_Rod_MirrorSize(coarse)))
    CALL CD_AGG_Init_From_Deck(turned, 'pinrod_tether.dat', DTC, es, em)
    CALL CD_AGG_GetMovingPointMesh(turned, p0, v, a, f, es, em)
    CALL CD_AGG_Init_From_Deck(fine, 'pinrod_tether.dat', DTC, es, em)
    err = 0.0_wp
    DO step = 0, 20
      k = host_surge(REAL(step, wp)*DTC)
      p = p0
      v = 0.0_wp
      a = 0.0_wp
      p(:, n) = p0(:, n) + k(1:3)
      v(:, n) = k(4:6)
      a(:, n) = k(7:9)
      th = 0.3_wp*SIN(REAL(step, wp))
      orr = 0.0_wp
      DO i = 1, n
        orr(1, 1, i) = 1.0_wp
        orr(2, 2, i) = 1.0_wp
        orr(3, 3, i) = 1.0_wp
      END DO
      orr(1, 1, n) = COS(th)
      orr(1, 3, n) = -SIN(th)
      orr(3, 1, n) = SIN(th)
      orr(3, 3, n) = COS(th)
      w = 0.0_wp
      al = 0.0_wp
      w(2, n) = 0.3_wp*COS(REAL(step, wp))
      al(2, n) = -0.3_wp*SIN(REAL(step, wp))
      IF (step == 0) THEN
        CALL CD_AGG_UpdateStates_Moving(turned, p, v, a, es, em, orientation=orr, angular_velocity=w, &
                                        angular_acceleration=al)
        CALL CD_AGG_UpdateStates_Moving(fine, p, v, a, es, em)
      ELSE
        CALL CD_AGG_Step_Moving(turned, DTC, p, v, a, cv, st, it, es, em, t_committed=REAL(step, wp)*DTC, &
                                orientation=orr, angular_velocity=w, angular_acceleration=al)
        CALL require(es == CD_AGG_OK, 'orient:turned step: '//TRIM(em))
        CALL CD_AGG_Step_Moving(fine, DTC, p, v, a, cv, st, it, es, em, t_committed=REAL(step, wp)*DTC)
      END IF
      CALL CD_AGG_Get_Rod_States(turned, rs, es, em)
      CALL CD_AGG_Get_Rod_States(fine, rs2, es, em)
      err = MAX(err, nan_max_abs(rs - rs2))
    END DO
    CALL require(err <= 0.0_wp, 'orient:host orientation and rates ignored by the pinned rod')
    CALL CD_AGG_End(turned, es, em)
    CALL CD_AGG_End(fine, es, em)

    ! snapshot -> step A -> restore -> step B reproduces step A
    k = host_surge(REAL(NC + 1, wp)*DTC)
    p = p0
    v = 0.0_wp
    a = 0.0_wp
    p(:, n) = p0(:, n) + k(1:3)
    v(:, n) = k(4:6)
    a(:, n) = k(7:9)
    CALL CD_AGG_Snapshot(coarse, es, em)
    CALL CD_AGG_Step_Moving(coarse, DTC, p, v, a, cv, st, it, es, em, t_committed=REAL(NC + 1, wp)*DTC)
    CALL CD_AGG_CalcOutput(coarse, es, em)
    CALL CD_AGG_GetMovingPointMesh(coarse, p, v, a, fb, es, em, moment=mb)
    CALL CD_AGG_Get_Rod_States(coarse, rs, es, em)
    CALL CD_AGG_Restore(coarse, es, em)
    p = p0
    v = 0.0_wp
    a = 0.0_wp
    p(:, n) = p0(:, n) + k(1:3)
    v(:, n) = k(4:6)
    a(:, n) = k(7:9)
    CALL CD_AGG_Step_Moving(coarse, DTC, p, v, a, cv, st, it, es, em, t_committed=REAL(NC + 1, wp)*DTC)
    CALL CD_AGG_CalcOutput(coarse, es, em)
    CALL CD_AGG_GetMovingPointMesh(coarse, p, v, a, f, es, em, moment=mo)
    CALL CD_AGG_Get_Rod_States(coarse, rs2, es, em)
    CALL require(nan_max_abs(f - fb) <= 0.0_wp .AND. nan_max_abs(mo - mb) <= 0.0_wp .AND. &
                 nan_max_abs(rs - rs2) <= 0.0_wp, 'state:snapshot-step-restore-step bit-identical')
   CALL require(nan_max_abs(mo(:, n)) <= 0.0_wp .AND. nan_max_abs(f(:, n)) > 0.0_wp, 'state:force only at the pin node')

    ! restart: a fresh instance takes the host kinematics, the line interiors and the rod states
    CALL CD_AGG_Init_From_Deck(agg_b, 'pinrod_tether.dat', DTC, es, em)
    CALL require(es == CD_AGG_OK, 'restart:init: '//TRIM(em))
    IF (es /= CD_AGG_OK) RETURN
    CALL CD_AGG_UpdateStates_Moving(agg_b, p, v, a, es, em)
    CALL require(es == CD_AGG_OK, 'restart:host: '//TRIM(em))
    nl = CD_System_NLines(coarse%sys%fast%system, es, em)
    DO il = 1, nl
      ndof = CD_System_Line_NDOF(coarse%sys%fast%system, il, es, em)
      ALLOCATE (lq(ndof), lv(ndof), la(ndof))
      CALL CD_Get_System_Line_State(coarse%sys%fast%system, il, lq, lv, la, es, em)
      CALL CD_Update_System_Line_Interior_State(agg_b%sys%fast%system, il, lq(4:ndof - 3), lv(4:ndof - 3), es, em, &
                                                a_interior=la(4:ndof - 3))
      CALL require(es == CD_SYSTEM_OK, 'restart:interior: '//TRIM(em))
      DEALLOCATE (lq, lv, la)
    END DO
    CALL CD_AGG_Get_Rod_States(coarse, rs, es, em)
    CALL CD_AGG_Set_Rod_States(agg_b, rs, es, em)
    CALL require(es == CD_AGG_OK, 'restart:rod states: '//TRIM(em))
    ! the committed line-end motion closes the mirror (the shell restores it last)
    ncd = CD_System_NSystemCoupledDOF(coarse%sys%fast%system)
    ALLOCATE (cq(ncd), cvv(ncd), ca(ncd))
    CALL CD_Get_System_CoupledMotion(coarse%sys%fast%system, cq, cvv, ca, es, em)
    CALL CD_Update_System_CoupledMotion(agg_b%sys%fast%system, cq, cvv, ca, es, em)
    CALL require(es == CD_SYSTEM_OK, 'restart:coupled motion: '//TRIM(em))
    ! between steps (a supercycled host evaluates the restored state before the next step) the
    ! pin force depends on the mirrored rod state only, not on the host pin it was stepped with
    CALL CD_AGG_CalcOutput(coarse, es, em)
    CALL CD_AGG_GetMovingPointMesh(coarse, p, v, a, f, es, em, moment=mo)
    CALL CD_AGG_CalcOutput(agg_b, es, em)
    CALL CD_AGG_GetMovingPointMesh(agg_b, p, v, a, fb, es, em, moment=mb)
    WRITE (*, '(A,ES10.3)') 'CoupledPinned restart overlay: |pin force difference| before the next step = ', &
      nan_max_abs(f - fb)
    CALL require(nan_max_abs(f - fb) <= 0.0_wp .AND. nan_max_abs(mo - mb) <= 0.0_wp, &
                 'restart:bit-identical loads of the restored state before the next step')
    err = 0.0_wp
    DO step = NC + 2, NC + 30
      k = host_surge(REAL(step, wp)*DTC)
      p = p0
      v = 0.0_wp
      a = 0.0_wp
      p(:, n) = p0(:, n) + k(1:3)
      v(:, n) = k(4:6)
      a(:, n) = k(7:9)
      CALL CD_AGG_Step_Moving(coarse, DTC, p, v, a, cv, st, it, es, em, t_committed=REAL(step, wp)*DTC)
      CALL CD_AGG_Step_Moving(agg_b, DTC, p, v, a, cv, st, it, es, em, t_committed=REAL(step, wp)*DTC)
      CALL require(es == CD_AGG_OK, 'restart:march: '//TRIM(em))
      CALL CD_AGG_CalcOutput(coarse, es, em)
      CALL CD_AGG_GetMovingPointMesh(coarse, p, v, a, f, es, em, moment=mo)
      CALL CD_AGG_CalcOutput(agg_b, es, em)
      CALL CD_AGG_GetMovingPointMesh(agg_b, p, v, a, fb, es, em, moment=mb)
      err = MAX(err, nan_max_abs(f - fb), nan_max_abs(mo - mb))
    END DO
    CALL CD_AGG_Get_Rod_States(coarse, rs, es, em)
    CALL CD_AGG_Get_Rod_States(agg_b, rs2, es, em)
    WRITE (*, '(A,ES10.3)') 'CoupledPinned restart overlay: max |load difference| over 29 steps = ', err
    CALL require(err <= 0.0_wp .AND. nan_max_abs(rs - rs2) <= 0.0_wp, 'restart:bit-identical continuation')
    CALL CD_AGG_End(agg_b, es, em)
    CALL CD_AGG_End(coarse, es, em)
  END SUBROUTINE case_substep_and_state

  ! --------------------------------------------------------------------------------------------- !
  ! 7: the output probe                                                                           !
  ! --------------------------------------------------------------------------------------------- !

  SUBROUTINE case_probe()
    !! On the hanging dry pendulum at rest, a probe pin acceleration a_p along x returns the
    !! rest force plus -M_eff a_p with M_eff = m I_c/I_p (the rotation re-solved at a_p; the
    !! committed angular acceleration would give -m a_p). On the tethered rod mid-swing, a
    !! probe (pin moved, accelerated) restored as the coupled shell restores it (saved host
    !! kinematics, line interiors, rod states, committed line-end motion) leaves the
    !! continuation bit-identical to a twin that was never probed.
    TYPE(CD_AGG_ModuleType) :: agg, twin
    REAL(wp), ALLOCATABLE :: p(:, :), v(:, :), a(:, :), f(:, :), f0(:, :), mo(:, :), p0(:, :)
    REAL(wp), ALLOCATABLE :: sp(:, :), sv(:, :), sa(:, :), so(:, :, :), sw(:, :), sal(:, :)
    REAL(wp), ALLOCATABLE :: lq(:, :), lv(:, :), la(:, :), rs(:), rs2(:), fb(:, :), mb(:, :)
    REAL(wp), ALLOCATABLE :: cq(:), cvv(:), ca(:), q2(:), v2(:), a2(:), l1(:), l2(:)
    REAL(wp) :: ic, ip, ap, k(9), err, endb(3)
    INTEGER :: es, n, step, it, nl, il, ndof, maxdof, ncd, ib
    LOGICAL :: cv, st
    CHARACTER(512) :: em

    CALL write_pendulum_deck('pinrod_probe.dat', 'CoupledPinned', 0.0_wp)
    CALL CD_AGG_Init_From_Deck(agg, 'pinrod_probe.dat', 0.01_wp, es, em)
    CALL require(es == CD_AGG_OK, 'probe:init: '//TRIM(em))
    IF (es /= CD_AGG_OK) RETURN
    n = CD_AGG_NMovingPoints(agg, es, em)
    ALLOCATE (p(3, n), v(3, n), a(3, n), f(3, n), f0(3, n), mo(3, n), p0(3, n))
    CALL CD_AGG_CalcOutput(agg, es, em)
    CALL CD_AGG_GetMovingPointMesh(agg, p0, v, a, f0, es, em)
    ap = 1.5_wp
    p = p0
    v = 0.0_wp
    a = 0.0_wp
    a(1, n) = ap
    CALL CD_AGG_UpdateStates_Moving(agg, p, v, a, es, em, output_probe=.TRUE.)
    CALL CD_AGG_CalcOutput(agg, es, em)
    CALL CD_AGG_GetMovingPointMesh(agg, p, v, a, f, es, em, moment=mo)
    ic = MP*(3.0_wp*(0.5_wp*DP)**2 + LP*LP)/12.0_wp
    ip = ic + MP*(0.5_wp*LP)**2
    WRITE (*, '(A,F10.4,A,F10.4,A,F10.4)') 'probe pin acceleration: dF_x got ', f(1, n) - f0(1, n), &
      ' N; -m (I_c/I_p) a_p ', -MP*ic/ip*ap, ' N; -m a_p ', -MP*ap
    CALL require(ABS(f(1, n) - f0(1, n) + MP*ic/ip*ap) <= 1.0e-10_wp*MP*G, 'probe:-M_eff a_p (re-solved rotation)')
    CALL require(nan_max_abs(f(2:3, n) - f0(2:3, n)) <= 1.0e-10_wp*MP*G .AND. nan_max_abs(mo(:, n)) <= 0.0_wp, &
                 'probe:no other force change, zero moment')
    CALL CD_AGG_End(agg, es, em)

    ! state-const probe on the tethered rod
    CALL write_tethered_deck('pinrod_probe_tether.dat', 'CoupledPinned', 'deck')
    CALL CD_AGG_Init_From_Deck(agg, 'pinrod_probe_tether.dat', 0.02_wp, es, em)
    CALL CD_AGG_Init_From_Deck(twin, 'pinrod_probe_tether.dat', 0.02_wp, es, em)
    CALL require(es == CD_AGG_OK, 'probe:tether init: '//TRIM(em))
    IF (es /= CD_AGG_OK) RETURN
    DEALLOCATE (p, v, a, f, mo, p0)
    n = CD_AGG_NMovingPoints(agg, es, em)
    ALLOCATE (p(3, n), v(3, n), a(3, n), f(3, n), mo(3, n), p0(3, n), fb(3, n), mb(3, n))
    ALLOCATE (sp(3, n), sv(3, n), sa(3, n), so(3, 3, n), sw(3, n), sal(3, n))
    ALLOCATE (rs(CD_AGG_Rod_MirrorSize(agg)), rs2(CD_AGG_Rod_MirrorSize(agg)))
    CALL CD_AGG_GetMovingPointMesh(agg, p0, v, a, f, es, em)
    err = 0.0_wp
    DO step = 1, 40
      k = host_surge(REAL(step, wp)*0.02_wp)
      p = p0
      v = 0.0_wp
      a = 0.0_wp
      p(:, n) = p0(:, n) + k(1:3)
      v(:, n) = k(4:6)
      a(:, n) = k(7:9)
      CALL CD_AGG_Step_Moving(agg, 0.02_wp, p, v, a, cv, st, it, es, em, t_committed=REAL(step, wp)*0.02_wp)
      CALL CD_AGG_Step_Moving(twin, 0.02_wp, p, v, a, cv, st, it, es, em, t_committed=REAL(step, wp)*0.02_wp)
      CALL require(es == CD_AGG_OK, 'probe:march: '//TRIM(em))
      IF (step /= 20) CYCLE
      ! the shell's probe: save the committed host kinematics and the state mirror, overlay, evaluate
      CALL CD_AGG_GetMovingPointMesh(agg, sp, sv, sa, f, es, em, orientation=so, angular_velocity=sw, &
                                     angular_acceleration=sal)
      CALL CD_AGG_Get_Rod_States(agg, rs, es, em)
      nl = CD_System_NLines(agg%sys%fast%system, es, em)
      maxdof = 0
      DO il = 1, nl
        maxdof = MAX(maxdof, CD_System_Line_NDOF(agg%sys%fast%system, il, es, em))
      END DO
      ALLOCATE (lq(maxdof, nl), lv(maxdof, nl), la(maxdof, nl))
      DO il = 1, nl
        ndof = CD_System_Line_NDOF(agg%sys%fast%system, il, es, em)
        CALL CD_Get_System_Line_State(agg%sys%fast%system, il, lq(1:ndof, il), lv(1:ndof, il), la(1:ndof, il), es, em)
      END DO
      ncd = CD_System_NSystemCoupledDOF(agg%sys%fast%system)
      ALLOCATE (cq(ncd), cvv(ncd), ca(ncd))
      CALL CD_Get_System_CoupledMotion(agg%sys%fast%system, cq, cvv, ca, es, em)
      p(1, n) = p(1, n) + 0.3_wp
      a(1, n) = a(1, n) + 4.0_wp
      v(1, n) = v(1, n) - 0.5_wp
      CALL CD_AGG_UpdateStates_Moving(agg, p, v, a, es, em, output_probe=.TRUE.)
      CALL require(es == CD_AGG_OK, 'probe:overlay: '//TRIM(em))
      CALL CD_AGG_CalcOutput(agg, es, em)
      CALL CD_AGG_GetMovingPointMesh(agg, p, v, a, f, es, em, moment=mo)
      CALL require(ALL(IEEE_IS_FINITE(f)) .AND. nan_max_abs(mo(:, n)) <= 0.0_wp, 'probe:finite force, zero moment')
      ! The tethers load End B with their end-node inertia at the end acceleration the system
      ! holds (the probe pin with the committed rotation). Give that end another acceleration:
      ! its line load changes, the pin force does not (the inertia is moved to the re-solved
      ! rotation exactly).
      CALL CD_AGG_Get_Rod_States(agg, rs2, es, em)
      endb = rs2(1:3) + rs2(16:18)
      ALLOCATE (q2(ncd), v2(ncd), a2(ncd), l1(ncd), l2(ncd))
      CALL CD_Get_System_CoupledMotion(agg%sys%fast%system, q2, v2, a2, es, em)
      ib = 0
      DO il = 1, ncd/3
        IF (nan_max_abs(q2(3*il - 2:3*il) - endb) <= 1.0e-9_wp) ib = il
      END DO
      CALL require(ib > 0, 'probe:End B is a coupled point of the line system')
      IF (ib > 0) THEN
        CALL CD_Calc_System_CoupledLoads(agg%sys%fast%system, l1, es, em)
        a2(3*ib - 2:3*ib) = a2(3*ib - 2:3*ib) + [3.0_wp, -2.0_wp, 1.0_wp]
        CALL CD_Update_System_CoupledMotion(agg%sys%fast%system, q2, v2, a2, es, em)
        CALL require(es == CD_SYSTEM_OK, 'probe:end acceleration: '//TRIM(em))
        CALL CD_Calc_System_CoupledLoads(agg%sys%fast%system, l2, es, em)
        CALL CD_AGG_CalcOutput(agg, es, em)
        CALL CD_AGG_GetMovingPointMesh(agg, p, v, a, fb, es, em, moment=mb)
        WRITE (*, '(A,ES10.3,A,ES10.3,A)') 'probe with another End B acceleration: line load change ', &
          nan_max_abs(l2(3*ib - 2:3*ib) - l1(3*ib - 2:3*ib)), ' N, pin force change ', &
          nan_max_abs(fb(:, n) - f(:, n)), ' N'
        CALL require(nan_max_abs(l2(3*ib - 2:3*ib) - l1(3*ib - 2:3*ib)) > 1.0_wp, &
                     'probe:the End B line load carries the end acceleration')
        CALL require(nan_max_abs(fb(:, n) - f(:, n)) <= 1.0e-9_wp*nan_max_abs(f(:, n)) .AND. &
                     nan_max_abs(mb(:, n)) <= 0.0_wp, 'probe:pin force independent of the held end acceleration')
      END IF
      DEALLOCATE (q2, v2, a2, l1, l2)
      CALL CD_AGG_UpdateStates_Moving(agg, sp, sv, sa, es, em, output_probe=.TRUE., orientation=so, &
                                      angular_velocity=sw, angular_acceleration=sal)
      DO il = 1, nl
        ndof = CD_System_Line_NDOF(agg%sys%fast%system, il, es, em)
        CALL CD_Update_System_Line_Interior_State(agg%sys%fast%system, il, lq(4:ndof - 3, il), lv(4:ndof - 3, il), &
                                                  es, em, a_interior=la(4:ndof - 3, il))
      END DO
      CALL CD_AGG_Set_Rod_States(agg, rs, es, em)
      CALL require(es == CD_AGG_OK, 'probe:restore: '//TRIM(em))
      CALL CD_Update_System_CoupledMotion(agg%sys%fast%system, cq, cvv, ca, es, em)
      CALL require(es == CD_SYSTEM_OK, 'probe:coupled motion: '//TRIM(em))
      CALL CD_AGG_Get_Rod_States(agg, rs2, es, em)
      CALL require(nan_max_abs(rs2 - rs) <= 0.0_wp, 'probe:rod state restored bit-identically')
    END DO
    ! continuation after the probe: compare the steps 21-40 (already marched) at the end state
    CALL CD_AGG_CalcOutput(agg, es, em)
    CALL CD_AGG_GetMovingPointMesh(agg, p, v, a, f, es, em, moment=mo)
    CALL CD_AGG_CalcOutput(twin, es, em)
    CALL CD_AGG_GetMovingPointMesh(twin, p, v, a, fb, es, em, moment=mb)
    CALL CD_AGG_Get_Rod_States(agg, rs, es, em)
    CALL CD_AGG_Get_Rod_States(twin, rs2, es, em)
    CALL require(nan_max_abs(f - fb) <= 0.0_wp .AND. nan_max_abs(mo - mb) <= 0.0_wp .AND. &
                 nan_max_abs(rs - rs2) <= 0.0_wp, 'probe:state-const (probed run equals the twin bit for bit)')
    CALL CD_AGG_End(agg, es, em)
    CALL CD_AGG_End(twin, es, em)
  END SUBROUTINE case_probe

  ! --------------------------------------------------------------------------------------------- !
  ! 9: PtfmInit and the static initial condition                                                  !
  ! --------------------------------------------------------------------------------------------- !

  SUBROUTINE case_ptfm_static()
    !! PtfmInit (surge 1 m, sway 0.5 m, yaw 10 deg) moves the pin and the rod rigidly with the
    !! platform before the static solve, which then turns the rod about its pin against the
    !! now unequal tethers: the pin is the displaced End A, the rod's net moment about it
    !! vanishes, the host node carries the rod's net force and no moment, and the rod starts
    !! at rest.
    TYPE(CD_AGG_ModuleType) :: agg
    REAL(wp), ALLOCATABLE :: p(:, :), v(:, :), a(:, :), f(:, :), mo(:, :)
    REAL(wp) :: ptfm(6), dcm(3, 3), pin(3), s(24), ch(6), cz, sz, tilt, fsc
    INTEGER :: es, n, i
    CHARACTER(512) :: em

    CALL write_tethered_deck('pinrod_ptfm.dat', 'CoupledPinned', 'static')
    ptfm = [1.0_wp, 0.5_wp, 0.0_wp, 0.0_wp, 0.0_wp, 10.0_wp*PI/180.0_wp]
    CALL CD_AGG_Init_From_Deck(agg, 'pinrod_ptfm.dat', 0.02_wp, es, em, ptfm_init=ptfm)
    CALL require(es == CD_AGG_OK, 'ptfm:init: '//TRIM(em))
    IF (es /= CD_AGG_OK) RETURN
    n = CD_AGG_NMovingPoints(agg, es, em)
    ALLOCATE (p(3, n), v(3, n), a(3, n), f(3, n), mo(3, n))
    cz = COS(ptfm(6))
    sz = SIN(ptfm(6))
    dcm = 0.0_wp
    dcm(1, 1) = cz
    dcm(1, 2) = sz
    dcm(2, 1) = -sz
    dcm(2, 2) = cz
    dcm(3, 3) = 1.0_wp
    pin = ptfm(1:3) + MATMUL(TRANSPOSE(dcm), [0.0_wp, 0.0_wp, -10.0_wp])
    CALL CD_AGG_CalcOutput(agg, es, em)
    CALL CD_AGG_GetMovingPointMesh(agg, p, v, a, f, es, em, moment=mo)
    CALL CD_AGG_Get_Rod_States(agg, s, es, em)
    DO i = 1, 6
      CALL CD_AGG_EvalChannel(agg, i, ch(i), es, em)
    END DO
    tilt = ACOS(MIN(1.0_wp, -s(18)))
    fsc = nan_max_abs(ch(1:3))
    WRITE (*, '(A,ES10.3,A,F8.4,A,ES10.3,A,ES10.3)') 'PtfmInit + static IC: |pin - displaced End A| ', &
      nan_max_abs(p(:, n) - pin), '; rod tilt ', tilt, ' rad; |Rod1M| ', nan_max_abs(ch(4:6)), &
      ' N m; |host force - Rod1F| ', nan_max_abs(f(:, n) - ch(1:3))
    CALL require(nan_max_abs(p(:, n) - pin) <= 1.0e-12_wp, 'ptfm:pin at the displaced End A')
    CALL require(nan_max_abs(s(1:3) - 1.0_wp*s(16:18) - pin) <= 1.0e-12_wp, 'ptfm:rod End A on the pin')
    CALL require(tilt > 1.0e-3_wp, 'ptfm:the static solve turned the rod')
    CALL require(nan_max_abs(ch(4:6)) <= 1.0e-6_wp*fsc*2.0_wp, 'ptfm:net moment about the pin vanishes')
    CALL require(nan_max_abs(f(:, n) - ch(1:3)) <= 1.0e-8_wp*fsc .AND. nan_max_abs(mo(:, n)) <= 0.0_wp, &
                 'ptfm:host force is the net rod load, no moment')
    CALL CD_AGG_End(agg, es, em)
  END SUBROUTINE case_ptfm_static

  ! --------------------------------------------------------------------------------------------- !
  ! 11-12: a step without the staged rods, and rod ends without a point                           !
  ! --------------------------------------------------------------------------------------------- !

  SUBROUTINE case_unstaged_step()
    !! The rod march of a CoupledPinned rod needs no staged copy of the step-start rods: the rod
    !! state carries its step-start pin. One instance marches through CD_AGG_Step_Moving (which
    !! stages the rods and passes them on); its twin takes the t + dt pin through
    !! CD_Rod_SetHostKinematics and steps with CD_Step_Aggregate_Rod alone (no staged rods, no
    !! host overlay: the independent fairlead stays where the start transfer put it). Over the
    !! first step (the start-acceleration solve with the pin at its step-start pose) and the
    !! sub-cycled steps after it (the pin interpolated from its step start), the two are
    !! bit-identical under a harmonic pin surge, whose acceleration differs between step start
    !! and end.
    TYPE(CD_AGG_ModuleType) :: staged, bare
    REAL(wp), PARAMETER :: DTC = 0.1_wp
    REAL(wp), ALLOCATABLE :: p(:, :), v(:, :), a(:, :), f(:, :), p0(:, :), rs(:), rs2(:)
    REAL(wp), ALLOCATABLE :: cq(:), cvv(:), ca(:), cq2(:), cvv2(:), ca2(:)
    REAL(wp) :: k(9), err, t
    INTEGER :: es, n, step, it, ncd
    LOGICAL :: cv, st
    CHARACTER(512) :: em

    CALL write_tethered_deck('pinrod_unstaged.dat', 'CoupledPinned', 'deck')
    CALL CD_AGG_Init_From_Deck(staged, 'pinrod_unstaged.dat', DTC, es, em)
    CALL require(es == CD_AGG_OK, 'unstaged:init: '//TRIM(em))
    IF (es /= CD_AGG_OK) RETURN
    CALL CD_AGG_Init_From_Deck(bare, 'pinrod_unstaged.dat', DTC, es, em)
    n = CD_AGG_NMovingPoints(staged, es, em)
    ALLOCATE (p(3, n), v(3, n), a(3, n), f(3, n), p0(3, n))
    ALLOCATE (rs(CD_AGG_Rod_MirrorSize(staged)), rs2(CD_AGG_Rod_MirrorSize(staged)))
    ncd = CD_System_NSystemCoupledDOF(staged%sys%fast%system)
    ALLOCATE (cq(ncd), cvv(ncd), ca(ncd), cq2(ncd), cvv2(ncd), ca2(ncd))
    CALL CD_AGG_GetMovingPointMesh(staged, p0, v, a, f, es, em)
    err = 0.0_wp
    DO step = 0, 20
      t = REAL(step, wp)*DTC
      k = host_surge(t)
      p = p0
      v = 0.0_wp
      a = 0.0_wp
      p(:, n) = p0(:, n) + k(1:3)
      v(:, n) = k(4:6)
      a(:, n) = k(7:9)
      IF (step == 0) THEN
        CALL CD_AGG_UpdateStates_Moving(staged, p, v, a, es, em)
        CALL CD_AGG_UpdateStates_Moving(bare, p, v, a, es, em)
        CALL require(es == CD_AGG_OK, 'unstaged:start transfer: '//TRIM(em))
        CYCLE
      END IF
      CALL CD_AGG_Step_Moving(staged, DTC, p, v, a, cv, st, it, es, em, t_committed=t)
      CALL require(es == CD_AGG_OK, 'unstaged:staged step: '//TRIM(em))
      CALL CD_Rod_SetHostKinematics(bare%rod, p(:, n:n), v(:, n:n), a(:, n:n), es, em)
      CALL require(es == CD_DECKDRV_OK, 'unstaged:pin transfer: '//TRIM(em))
      CALL CD_Step_Aggregate_Rod(bare%sys%fast%system, bare%rod, t - DTC, DTC, cv, st, it, es, em)
      CALL require(es == CD_DECKDRV_OK, 'unstaged:bare step: '//TRIM(em))
      IF (es /= CD_DECKDRV_OK) EXIT
      CALL CD_AGG_Get_Rod_States(staged, rs, es, em)
      CALL CD_AGG_Get_Rod_States(bare, rs2, es, em)
      CALL CD_Get_System_CoupledMotion(staged%sys%fast%system, cq, cvv, ca, es, em)
      CALL CD_Get_System_CoupledMotion(bare%sys%fast%system, cq2, cvv2, ca2, es, em)
      err = MAX(err, nan_max_abs(rs - rs2), nan_max_abs(cq - cq2), nan_max_abs(cvv - cvv2), nan_max_abs(ca - ca2))
    END DO
    WRITE (*, '(A,ES10.3,A,ES10.3,A)') 'CoupledPinned step without staged rods: max |state difference| = ', err, &
      ' (rod turned ', ABS(rod_angle(rs)), ' rad)'
    CALL require(err <= 0.0_wp, 'unstaged:the step-start pin needs no staged rods (bit-identical)')
    CALL require(ABS(rod_angle(rs)) > 1.0e-3_wp, 'unstaged:the pin motion turns the rod')
    CALL CD_AGG_End(staged, es, em)
    CALL CD_AGG_End(bare, es, em)
  END SUBROUTINE case_unstaged_step

  ! --------------------------------------------------------------------------------------------- !
  ! 13: a pinned rod without a line sub-cycles its own swing                                      !
  ! --------------------------------------------------------------------------------------------- !

  FUNCTION host_rest(time) RESULT(k)
    !! A host node held at its initial position.
    REAL(wp), INTENT(IN) :: time
    REAL(wp) :: k(9)
    k = 0.0_wp*time
  END FUNCTION host_rest

  SUBROUTINE case_lineless_swing_substep()
    !! A 1 m Pinned rod that carries no line, released at 30 degrees: (1) dry, hanging from a pin
    !! above the water, omega0^2 = m g (L/2)/I_p, about 14.6 rad^2/s^2; (2) submerged and buoyant
    !! (10 kg/m against 32.2 kg/m of displaced water), standing up from a pin at z = -15 m (out of
    !! the surface's reach),
    !! omega0^2 = (B - W)(L/2)/I_p, about 32.4 rad^2/s^2. At a 0.6 s coupling step omega0 dt is
    !! 2.29 and 3.42, beyond the explicit limit of 2, and the sub-step estimate (the swing
    !! stiffness |W d_g - B d_b| over the inertia about the pin) asks for 6 and 9 sub-steps
    !! (omega0 dt/0.4 = 5.73 and 8.54). The coarse run must equal a run at that sub-step size at
    !! every coupling step (so it took those sub-steps; taking each step whole, it departs by
    !! radians and turns over), stay within its release angle, and swing
    !! with the elliptic-integral period of the compound pendulum to the accuracy of
    !! omega0 dt_sub, about 0.38 (a central-difference period error near (omega dt)^2/24 = 0.6 %).
    TYPE(CD_AGG_ModuleType) :: coarse, fine
    REAL(wp), PARAMETER :: DTC = 0.6_wp, TH0 = 30.0_wp, ZW = -15.0_wp
    INTEGER, PARAMETER :: NC = 30, NSUBS(2) = [6, 9]
    REAL(wp), ALLOCATABLE :: angc(:), tc(:), angf(:), tf(:)
    REAL(wp) :: mpm, ip, kswing, t_ref, period, mean, err_ang, amp, rel
    INTEGER :: es, i, kase, nsub
    LOGICAL :: ok
    CHARACTER(512) :: em

    DO kase = 1, 2
      nsub = NSUBS(kase)
      IF (kase == 1) THEN
        mpm = 50.0_wp
        CALL write_short_pendulum_deck('pinrod_short.dat', mpm, ZPIN, .FALSE., TH0)
        kswing = mpm*G*0.5_wp
      ELSE
        mpm = 10.0_wp
        CALL write_short_pendulum_deck('pinrod_short.dat', mpm, ZW, .TRUE., TH0)
        kswing = (1025.0_wp*0.25_wp*PI*DP*DP - mpm)*G*0.5_wp
      END IF
      ip = mpm*(1.0_wp/3.0_wp + DP*DP/16.0_wp)
      t_ref = 4.0_wp*SQRT(ip/kswing)*ellip_k(SIN(0.5_wp*TH0*PI/180.0_wp))
      CALL CD_AGG_Init_From_Deck(coarse, 'pinrod_short.dat', DTC, es, em)
      CALL require(es == CD_AGG_OK, 'lineless:coarse-init: '//TRIM(em))
      IF (es /= CD_AGG_OK) RETURN
      CALL CD_AGG_Init_From_Deck(fine, 'pinrod_short.dat', DTC/REAL(nsub, wp), es, em)
      CALL require(es == CD_AGG_OK, 'lineless:fine-init: '//TRIM(em))
      IF (es /= CD_AGG_OK) RETURN
      ALLOCATE (angc(0:NC), tc(0:NC), angf(0:NC*nsub), tf(0:NC*nsub))
      CALL march(coarse, DTC, NC, host_rest, angc, tc, ok)
      CALL require(ok, 'lineless:coarse march finite (the swing is sub-cycled)')
      CALL march(fine, DTC/REAL(nsub, wp), NC*nsub, host_rest, angf, tf, ok)
      CALL require(ok, 'lineless:fine march finite')
      IF (.NOT. ok) RETURN
      ! rod_angle is measured from the downward vertical: the upright rod's angle from the
      ! upward one is pi - rod_angle, wrapped to (-pi, pi]
      IF (kase == 2) THEN
        angc = MODULO(2.0_wp*PI - angc, 2.0_wp*PI) - PI
        angf = MODULO(2.0_wp*PI - angf, 2.0_wp*PI) - PI
      END IF
      err_ang = 0.0_wp
      DO i = 0, NC
        err_ang = MAX(err_ang, ABS(angc(i) - angf(nsub*i)))
      END DO
      amp = MAX(nan_max_abs(angc), nan_max_abs(angf))
      CALL crossings(tf, angf, 0.0_wp, period, mean)
      rel = ABS(period - t_ref)/t_ref
      WRITE (*, '(A,I0,A,ES10.3,A,F8.5,A,2F10.6,A,ES10.3)') 'lineless pinned swing (', kase, &
        '): coarse vs sub-step run ', err_ang, ' rad; max angle/release ', amp/(TH0*PI/180.0_wp), &
        '; period got/analytic [s] ', period, t_ref, '; rel. error ', rel
      CALL require(err_ang <= 1.0e-8_wp*amp, 'lineless:coarse step equals its sub-step run')
      CALL require(amp <= 1.02_wp*TH0*PI/180.0_wp, 'lineless:the swing stays within its release angle')
      CALL require(rel <= 1.5e-2_wp, 'lineless:period (elliptic integral)')
      DEALLOCATE (angc, tc, angf, tf)
      CALL CD_AGG_End(coarse, es, em)
      CALL CD_AGG_End(fine, es, em)
    END DO
  END SUBROUTINE case_lineless_swing_substep

  ! --------------------------------------------------------------------------------------------- !
  ! 14: a host pin crossing the free surface within one coupling step                             !
  ! --------------------------------------------------------------------------------------------- !

  FUNCTION host_rise(time) RESULT(k)
    !! The pin rising at a constant 12 m/s from t = 0.
    REAL(wp), INTENT(IN) :: time
    REAL(wp) :: k(9)
    k = 0.0_wp
    k(3) = 12.0_wp*time
    k(6) = 12.0_wp
  END FUNCTION host_rise

  FUNCTION host_sink(time) RESULT(k)
    !! The pin sinking at a constant 2 m/s from t = 0.
    REAL(wp), INTENT(IN) :: time
    REAL(wp) :: k(9)
    k = 0.0_wp
    k(3) = -2.0_wp*time
    k(6) = -2.0_wp
  END FUNCTION host_sink

  SUBROUTINE case_surface_crossing_pin()
    !! A 1 m CoupledPinned rod without a line whose host pin crosses the free surface in one
    !! coupling step at constant velocity, which the linear interpolation of the pin inside the
    !! step represents exactly. The march sizes its sub-steps after the host has placed the pin at
    !! the end of the step, so the swing estimate must also take the step-start wetting:
    !!   (1) a light rod (1 kg/m against 32.2 kg/m of displaced water) standing up from a pin at
    !!       z = -1.1 m that rises at 12 m/s, fully submerged at the start of a 0.1 s step and dry
    !!       at its end: omega^2 = (B - W)(L/2)/I_p = 456 rad^2/s^2 at the start (omega dt = 2.13,
    !!       beyond the explicit limit of 2) but 14.6 at the end, which alone asks for one
    !!       sub-step; the start wetting asks for 6 (omega dt/0.4 = 5.34);
    !!   (2) a rod just heavier than water (33 kg/m) hanging from a pin at z = 1 m that sinks at
    !!       2 m/s, dry at the start of a 0.6 s step and submerged at its end: 14.6 rad^2/s^2 at the
    !!       start (omega dt = 2.29) against 0.354 at the end; the start asks for 6 (5.73).
    !! The crossing step must stay within 5e-3 rad and 1 % of the rod state of a run at a sixtieth
    !! of the step (the wetting along the step is bounded by its two ends; near the surface the
    !! waterplane term of the estimate adds sub-steps beyond these).
    TYPE(CD_AGG_ModuleType) :: coarse, fine
    INTEGER, PARAMETER :: NSUB = 60
    REAL(wp) :: angc(0:1), tc(0:1), angf(0:NSUB), tf(0:NSUB), sc(24), sf(24), dtc, err_ang, err_s
    INTEGER :: es, kase
    LOGICAL :: ok
    CHARACTER(512) :: em

    DO kase = 1, 2
      IF (kase == 1) THEN
        dtc = 0.1_wp
        CALL write_short_pendulum_deck('pinrod_cross.dat', 1.0_wp, -1.1_wp, .TRUE., 10.0_wp, 'CoupledPinned')
      ELSE
        dtc = 0.6_wp
        CALL write_short_pendulum_deck('pinrod_cross.dat', 33.0_wp, 1.0_wp, .FALSE., 30.0_wp, 'CoupledPinned')
      END IF
      CALL CD_AGG_Init_From_Deck(coarse, 'pinrod_cross.dat', dtc, es, em)
      CALL require(es == CD_AGG_OK, 'cross:coarse-init: '//TRIM(em))
      IF (es /= CD_AGG_OK) RETURN
      CALL CD_AGG_Init_From_Deck(fine, 'pinrod_cross.dat', dtc/REAL(NSUB, wp), es, em)
      CALL require(es == CD_AGG_OK, 'cross:fine-init: '//TRIM(em))
      IF (es /= CD_AGG_OK) RETURN
      IF (kase == 1) THEN
        CALL march(coarse, dtc, 1, host_rise, angc, tc, ok, s_end=sc)
        CALL require(ok, 'cross:coarse march finite')
        CALL march(fine, dtc/REAL(NSUB, wp), NSUB, host_rise, angf, tf, ok, s_end=sf)
      ELSE
        CALL march(coarse, dtc, 1, host_sink, angc, tc, ok, s_end=sc)
        CALL require(ok, 'cross:coarse march finite')
        CALL march(fine, dtc/REAL(NSUB, wp), NSUB, host_sink, angf, tf, ok, s_end=sf)
      END IF
      CALL require(ok, 'cross:fine march finite')
      IF (.NOT. ok) RETURN
      err_ang = ABS(angc(1) - angf(NSUB))
      err_s = nan_max_abs(sc - sf)/MAX(1.0_wp, nan_max_abs(sf))
      WRITE (*, '(A,I0,A,ES10.3,A,F9.5,A,ES10.3)') 'surface-crossing pin (', kase, &
        '): crossing step vs dt/60 run: angle ', err_ang, ' of ', angf(NSUB), ' rad; rod state ', err_s
      CALL require(err_ang <= 5.0e-3_wp .AND. err_s <= 1.0e-2_wp, 'cross:crossing step follows the fine run')
      CALL CD_AGG_End(coarse, es, em)
      CALL CD_AGG_End(fine, es, em)
    END DO
  END SUBROUTINE case_surface_crossing_pin

  ! --------------------------------------------------------------------------------------------- !
  ! 15: seabed contact at a large coupling step                                                   !
  ! --------------------------------------------------------------------------------------------- !

  SUBROUTINE write_seabed_rod_deck(path, rod_type)
    !! A rod (D = 0.2 m, 50 kg/m, no drag or added mass) on a stiff seabed at z = -10 m (kBot
    !! 1e7 N/m^3): a 1 m Pinned rod from a pin at (0, 0, -9.5) whose End B rests on the bed at
    !! 30 degrees below the horizontal, or a 2 m Free rod lying on the bed from x = 0 to 2, held
    !! by two lightly taut tethers to anchors 1 m above the bed. The fairlead line of
    !! write_pendulum_deck keeps a mooring system in the deck.
    CHARACTER(*), INTENT(IN) :: path, rod_type
    INTEGER :: u
    OPEN (NEWUNIT=u, FILE=path, STATUS='REPLACE', ACTION='WRITE')
    WRITE (u, '(A)') 'rod on a stiff seabed on the coupled aggregate'
    WRITE (u, '(A)') '--- LINE TYPES ---'
    WRITE (u, '(A)') 'Name Diam Mass EA BA EI Cdn Cdt Can Cat'
    WRITE (u, '(A)') '(-) (m) (kg/m) (N) (-) (Nm2) (-) (-) (-) (-)'
    WRITE (u, '(A)') 'line 0.10 80.0 1.0e6 0.0 0.0 1.0 0.0 1.0 0.0'
    WRITE (u, '(A)') 'tether 0.05 4.0 2.0e5 0.0 0.0 1.0 0.0 1.0 0.0'
    WRITE (u, '(A)') '--- ROD TYPES ---'
    WRITE (u, '(A)') 'Name Diam Mass Cd Ca CdEnd CaEnd'
    WRITE (u, '(A)') '(-) (m) (kg/m) (-) (-) (-) (-)'
    WRITE (u, '(A)') 'bar 0.2 50 0 0 0 0'
    WRITE (u, '(A)') '--- RODS ---'
    WRITE (u, '(A)') 'ID RodType Type XA YA ZA XB YB ZB NumSegs Outputs'
    WRITE (u, '(A)') '(-) (-) (-) (m) (m) (m) (m) (m) (m) (-) (-)'
    IF (rod_type == 'Free') THEN
      WRITE (u, '(A)') '1 bar Free 0 0 -10 2 0 -10 4 -'
    ELSE
      WRITE (u, '(A,ES24.16,A)') '1 bar Pinned 0 0 -9.5 ', SQRT(0.75_wp), ' 0 -10 4 -'
    END IF
    WRITE (u, '(A)') '--- POINTS ---'
    WRITE (u, '(A)') 'ID Type X Y Z Mass Vol CdA Ca'
    WRITE (u, '(A)') '(-) (-) (m) (m) (m) (kg) (m3) (m2) (-)'
    WRITE (u, '(A)') '1 Coupled 0.0 30.0 -1.0 0 0 0 0'
    WRITE (u, '(A)') '2 Fixed 6.0 30.0 -8.0 0 0 0 0'
    IF (rod_type == 'Free') THEN
      WRITE (u, '(A)') '3 Fixed -5.0 0 -9 0 0 0 0'
      WRITE (u, '(A)') '4 Fixed 7.0 0 -9 0 0 0 0'
    END IF
    WRITE (u, '(A)') '--- LINES ---'
    WRITE (u, '(A)') 'ID NodeA NodeB Outputs'
    WRITE (u, '(A)') '(-) (-) (-) (-)'
    WRITE (u, '(A)') '1 1 2 -'
    IF (rod_type == 'Free') THEN
      WRITE (u, '(A)') '2 R1A 3 -'
      WRITE (u, '(A)') '3 R1B 4 -'
    END IF
    WRITE (u, '(A)') '--- SECTIONS ---'
    WRITE (u, '(A)') 'LineID LineType Length NumSegs'
    WRITE (u, '(A)') '(-) (-) (m) (-)'
    WRITE (u, '(A)') '1 line 9.5 6'
    IF (rod_type == 'Free') THEN
      WRITE (u, '(A)') '2 tether 5.09 10'
      WRITE (u, '(A)') '3 tether 5.09 10'
    END IF
    WRITE (u, '(A)') '--- OPTIONS ---'
    WRITE (u, '(A)') '9.80665 g'
    WRITE (u, '(A)') '1025.0 rhoW'
    WRITE (u, '(A)') '10.0 WtrDpth'
    WRITE (u, '(A)') '1.0e7 kBot'
    WRITE (u, '(A)') 'deck bodyIC'
    WRITE (u, '(A)') '--- end ---'
    CLOSE (u)
  END SUBROUTINE write_seabed_rod_deck

  SUBROUTINE case_seabed_contact_substep()
    !! The contact springs kBot d dl of the rod stations on the bed are far stiffer than the rod's
    !! other restoring: (1) the Pinned rod's End B station alone, 5e4 N/m at 0.87 m horizontally
    !! from the pin, gives omega^2 about 2e3 rad^2/s^2 about the pin (omega dt about 4.7 at a
    !! 0.1 s step; the stations within reach of the bed over the step ask for 34 to 36
    !! sub-steps) against 5 from its submerged weight; (2) the Free rod's 21 stations, 4e6 N/m in
    !! all on 100 kg, give omega^2 about 4e4 in heave (omega dt about 10 at a 0.05 s step, 26
    !! sub-steps) against about 800 from its tethers (4 sub-steps). The march must sub-cycle the
    !! contact mode: over 5 s each rod stays at rest on the bed (its static settlement is below
    !! 2 mm) and ends where a run at a tenth of the step ends; with the sub-steps of its other
    !! restoring alone it is thrown off the bed.
    TYPE(CD_AGG_ModuleType) :: coarse, fine
    REAL(wp), ALLOCATABLE :: angc(:), tc(:), angf(:), tf(:)
    REAL(wp) :: sc(24), sf(24), dtc, dev, err_end
    INTEGER :: es, kase, nc
    LOGICAL :: ok
    CHARACTER(512) :: em
    CHARACTER(8) :: kind

    DO kase = 1, 2
      IF (kase == 1) THEN
        kind = 'Pinned'
        dtc = 0.1_wp
      ELSE
        kind = 'Free'
        dtc = 0.05_wp
      END IF
      nc = NINT(5.0_wp/dtc)
      CALL write_seabed_rod_deck('pinrod_seabed.dat', TRIM(kind))
      CALL CD_AGG_Init_From_Deck(coarse, 'pinrod_seabed.dat', dtc, es, em)
      CALL require(es == CD_AGG_OK, 'seabed:coarse-init: '//TRIM(em))
      IF (es /= CD_AGG_OK) RETURN
      CALL CD_AGG_Init_From_Deck(fine, 'pinrod_seabed.dat', 0.1_wp*dtc, es, em)
      CALL require(es == CD_AGG_OK, 'seabed:fine-init: '//TRIM(em))
      IF (es /= CD_AGG_OK) RETURN
      ALLOCATE (angc(0:nc), tc(0:nc), angf(0:10*nc), tf(0:10*nc))
      CALL march(coarse, dtc, nc, host_rest, angc, tc, ok, s_end=sc)
      CALL require(ok, 'seabed:'//TRIM(kind)//' coarse march finite (the contact mode is sub-cycled)')
      IF (.NOT. ok) RETURN
      CALL march(fine, 0.1_wp*dtc, 10*nc, host_rest, angf, tf, ok, s_end=sf)
      CALL require(ok, 'seabed:'//TRIM(kind)//' fine march finite')
      IF (.NOT. ok) RETURN
      dev = nan_max_abs(angc - angc(0))
      err_end = MAX(ABS(angc(nc) - angf(10*nc)), nan_max_abs(sc(1:3) - sf(1:3)))
      WRITE (*, '(A,A,A,ES10.3,A,ES10.3,A,ES10.3)') 'rod on a stiff seabed (', TRIM(kind), &
        '): max angle change ', dev, ' rad; centre depth ', sc(3), '; end state vs dt/10 ', err_end
      CALL require(dev <= 1.0e-2_wp .AND. ABS(sc(3) - MERGE(-9.75_wp, -10.0_wp, kase == 1)) <= 1.0e-2_wp, &
                   'seabed:'//TRIM(kind)//' rod stays at rest on the bed')
      CALL require(err_end <= 1.0e-4_wp, 'seabed:'//TRIM(kind)//' ends as the dt/10 run')
      DEALLOCATE (angc, tc, angf, tf)
      CALL CD_AGG_End(coarse, es, em)
      CALL CD_AGG_End(fine, es, em)
    END DO
  END SUBROUTINE case_seabed_contact_substep

  SUBROUTINE case_bare_rod_ends()
    !! On the coupled route only a Pinned or CoupledPinned rod may leave an end without a line or
    !! Rod<N>A/B POINT row (its pin holds it): the tethered deck, whose rod carries no line at End
    !! A, initialises with a Pinned or CoupledPinned rod and is refused with a Free or Coupled
    !! one, as before this release.
    TYPE(CD_AGG_ModuleType) :: agg
    CHARACTER(16), PARAMETER :: KINDS(4) = [CHARACTER(16) :: 'Pinned', 'CoupledPinned', 'Free', 'Coupled']
    INTEGER :: es, i
    CHARACTER(512) :: em
    DO i = 1, 4
      CALL write_tethered_deck('pinrod_bare.dat', TRIM(KINDS(i)), 'deck')
      CALL CD_AGG_Init_From_Deck(agg, 'pinrod_bare.dat', 0.02_wp, es, em)
      IF (i <= 2) THEN
        CALL require(es == CD_AGG_OK, 'bare-end:'//TRIM(KINDS(i))//' rod accepted: '//TRIM(em))
      ELSE
        CALL require(es /= CD_AGG_OK .AND. INDEX(em, 'requires Rod<N>A and Rod<N>B points') > 0 .AND. &
                     INDEX(em, 'Rod1A') > 0, 'bare-end:'//TRIM(KINDS(i))//' rod refused: '//TRIM(em))
      END IF
      CALL CD_AGG_End(agg, es, em)
    END DO
  END SUBROUTINE case_bare_rod_ends

  ! --------------------------------------------------------------------------------------------- !
  ! 10: no coupled host                                                                           !
  ! --------------------------------------------------------------------------------------------- !

  SUBROUTINE case_standalone_refusal()
    !! The standalone driver has no host to move the pin: a CoupledPinned (or VesselPinned) rod
    !! is refused by name, including a zero-length one.
    LOGICAL :: conv
    INTEGER :: es, ns
    CHARACTER(512) :: em
    DO ns = 0, 4, 4
      CALL write_pendulum_deck('pinrod_standalone.dat', 'VesselPinned', 10.0_wp, standalone=.TRUE., nsegs=ns)
      CALL CD_Run_Deck_Driver('pinrod_standalone.dat', 'pinrod_standalone', conv, es, em)
      CALL require(es /= CD_DECKDRV_OK .AND. INDEX(em, 'requires a coupled host') > 0, &
                   'standalone:CoupledPinned refused by name: '//TRIM(em))
    END DO
  END SUBROUTINE case_standalone_refusal

END PROGRAM test_openfast_pinned_rod
