! File: tests/test_vessel_motion.f90
! SPDX-License-Identifier: Apache-2.0
! Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
PROGRAM test_vessel_motion
  !! Gates for 6-DOF prescribed vessel motion (OPTIONS vesselMotion / vesselRAO / vesselRef)
  !! on the standalone cable route.
  !!   1. Euler kinematics: R = Rz Ry Rx is a rotation; the global angular velocity and
  !!      acceleration match finite differences of R and of w; the rigid point velocity and
  !!      acceleration (with w x (w x p) and al x p) match finite differences of the position.
  !!   2. RAO table: exact at table entries, linear (complex) interpolation between them,
  !!      lag phase convention, heading range and one-heading rules.
  !!   3. Irregular sea: the RAO response of a seeded JONSWAP sea carries each component with
  !!      amplitude a|RAO| and phase eps + P (projection), and its variance equals the
  !!      RAO-weighted spectral moment.
  !!   4. Deck, pinned hang-off: a pure-rotation vesselMotion run is BIT-FOR-BIT the run of the
  !!      equivalent translation-only motionFile of the fairlead; the quaternion form of the
  !!      record reproduces the Euler form to round-off.
  !!   5. Deck, clamped hang-off: the Rigid end direction turns with the vessel. Under a slow
  !!      vessel pitch about the fairlead the end moment (BendMom at End A) settles on the
  !!      static equilibrium with the rotated clamp direction, and its increment matches the
  !!      tensioned-beam boundary layer dM = dtheta sqrt(EI T).
  !!   6. Deck, vesselRAO: a regular Airy wave moves the fairlead as amplitude x RAO with the
  !!      lag phase against the wave elevation at the vessel reference point; a JONSWAP sea
  !!      moves it with the same component phases that drive the line kinematics.
  !!   7. Fail-closed option and file grammar.
  !!   8. Deck, vesselRAO in a spread sea: each spread component drives the vessel with its own
  !!      heading and phase; a nonlinear stream wave is rejected by name.
  !!   9. Deck, vesselRAO in a WaveKin 7 sea of rows with different directions referred to a point
  !!      (WaveRefX, WaveRefY): each row drives the vessel with its own heading, and its phase
  !!      from the position of the vessel relative to that point.
  USE CableDyn_Precision, ONLY: wp
  USE CableDyn_Vessel, ONLY: CD_VesselRAOType, CD_Vessel_Euler_DCM, CD_Vessel_Euler_Angular, &
                             CD_Vessel_Point_Kinematics, CD_Vessel_RAO_Set, CD_Vessel_RAO_Eval, &
                             CD_Vessel_RAO_Motion, CD_Vessel_Ramp, CD_VESSEL_OK
  USE CableDyn_Hydro, ONLY: CD_Solve_Dispersion_Wavenumber, CD_JONSWAP_Random_Components, CD_JONSWAP_COMPONENTS
  USE CableDyn_DeckDriver, ONLY: CD_Run_Deck_Driver, CD_DECKDRV_OK
  USE CableDyn_WaveSpectra, ONLY: CD_SeaType, CD_WaveTrainType, CD_TRAIN_JONSWAP, CD_Sea_Reset, CD_Sea_Add_Train, &
                                  CD_Sea_Synthesise
  IMPLICIT NONE

  REAL(wp), PARAMETER :: PI = 3.14159265358979323846_wp
  ! the driver's degree conversion, reproduced operation for operation
  REAL(wp), PARAMETER :: QUARTER_PI = 0.785398163397448309616_wp, D2R = QUARTER_PI/45.0_wp
  INTEGER :: nfail
  nfail = 0

  CALL case_euler_kinematics()
  CALL case_rao_table()
  CALL case_rao_irregular()
  CALL case_deck_pure_rotation()
  CALL case_deck_clamped_moment()
  CALL case_deck_rao_regular()
  CALL case_deck_rao_irregular()
  CALL case_deck_rao_spread()
  CALL case_deck_rao_wavekin7()
  CALL case_deck_rao_stream_rejected()
  CALL case_deck_rejections()

  IF (nfail > 0) THEN
    WRITE (*, '(A,I0,A)') 'FAIL: ', nfail, ' assertion(s) failed'
    ERROR STOP 1
  END IF
  WRITE (*, '(A)') 'PASS: 6-DOF vessel motion and RAO gates'

CONTAINS

  INCLUDE 'nan_max_abs.inc'

  SUBROUTINE require(cond, msg)
    LOGICAL, INTENT(IN) :: cond
    CHARACTER(*), INTENT(IN) :: msg
    IF (.NOT. cond) THEN
      nfail = nfail + 1
      WRITE (*, '(A)') 'FAIL: '//TRIM(msg)
    END IF
  END SUBROUTINE require

  SUBROUTINE smooth_angles(t, ang, rate, acc)
    !! A smooth three-axis Euler-angle history with its exact derivatives [rad].
    REAL(wp), INTENT(IN) :: t
    REAL(wp), INTENT(OUT) :: ang(3), rate(3), acc(3)
    REAL(wp), PARAMETER :: amp(3) = [0.3_wp, -0.2_wp, 0.5_wp], om(3) = [0.7_wp, 1.1_wp, 0.4_wp], &
                           ph(3) = [0.2_wp, 1.0_wp, -0.6_wp]
    ang = amp*SIN(om*t + ph)
    rate = amp*om*COS(om*t + ph)
    acc = -amp*om*om*SIN(om*t + ph)
  END SUBROUTINE smooth_angles

  SUBROUTINE case_euler_kinematics()
    REAL(wp) :: t, h, ang(3), rate(3), acc(3), r(3, 3), rp(3, 3), rm(3, 3), w(3), al(3), wp_(3), wm(3)
    REAL(wp) :: alp(3), alm(3), rdot(3, 3), skew(3, 3), wfd(3), alfd(3), rx(3, 3), ry(3, 3), rz(3, 3)
    REAL(wp) :: p(3), x(3), v(3), a(3), xp(3), vp(3), ap(3), xm(3), vm(3), am(3)
    t = 0.37_wp
    h = 1.0e-5_wp
    CALL smooth_angles(t, ang, rate, acc)
    r = CD_Vessel_Euler_DCM(ang)
    CALL require(nan_max_abs(MATMUL(TRANSPOSE(r), r) - identity()) < 1.0e-14_wp, 'euler: R is orthonormal')
    rx = RESHAPE([1.0_wp, 0.0_wp, 0.0_wp, 0.0_wp, COS(ang(1)), SIN(ang(1)), 0.0_wp, -SIN(ang(1)), COS(ang(1))], [3, 3])
    ry = RESHAPE([COS(ang(2)), 0.0_wp, -SIN(ang(2)), 0.0_wp, 1.0_wp, 0.0_wp, SIN(ang(2)), 0.0_wp, COS(ang(2))], [3, 3])
    rz = RESHAPE([COS(ang(3)), SIN(ang(3)), 0.0_wp, -SIN(ang(3)), COS(ang(3)), 0.0_wp, 0.0_wp, 0.0_wp, 1.0_wp], [3, 3])
    CALL require(nan_max_abs(r - MATMUL(rz, MATMUL(ry, rx))) < 1.0e-14_wp, 'euler: R = Rz(yaw) Ry(pitch) Rx(roll)')
    CALL CD_Vessel_Euler_Angular(ang, rate, acc, w, al)
    ! w from dR/dt R^T = skew(w)
    CALL smooth_angles(t + h, ang, rate, acc); rp = CD_Vessel_Euler_DCM(ang)
    CALL CD_Vessel_Euler_Angular(ang, rate, acc, wp_, alp)
    CALL smooth_angles(t - h, ang, rate, acc); rm = CD_Vessel_Euler_DCM(ang)
    CALL CD_Vessel_Euler_Angular(ang, rate, acc, wm, alm)
    rdot = (rp - rm)/(2.0_wp*h)
    skew = MATMUL(rdot, TRANSPOSE(r))
    wfd = [skew(3, 2), skew(1, 3), skew(2, 1)]
    CALL require(nan_max_abs(wfd - w) < 1.0e-8_wp, 'euler: global angular velocity matches dR/dt R^T')
    alfd = (wp_ - wm)/(2.0_wp*h)
    CALL require(nan_max_abs(alfd - al) < 1.0e-8_wp, 'euler: angular acceleration matches dw/dt')
    ! rigid point kinematics: translation r0(t) = [cos t, t^2, sin 2t]
    p = [3.0_wp, -1.5_wp, 2.0_wp]
    CALL point_at(t, p, x, v, a)
    CALL point_at(t + h, p, xp, vp, ap)
    CALL point_at(t - h, p, xm, vm, am)
    CALL require(nan_max_abs((xp - xm)/(2.0_wp*h) - v) < 1.0e-8_wp, 'point: velocity = dx/dt')
    CALL require(nan_max_abs((vp - vm)/(2.0_wp*h) - a) < 1.0e-7_wp, &
                 'point: acceleration = dv/dt (includes al x p and w x (w x p))')
    ! identity rotation: the point moves with the reference point exactly
    CALL CD_Vessel_Point_Kinematics([1.0_wp, 2.0_wp, 3.0_wp], [0.1_wp, 0.2_wp, 0.3_wp], [0.0_wp, 0.0_wp, -1.0_wp], &
                                    identity(), [0.0_wp, 0.0_wp, 0.0_wp], [0.0_wp, 0.0_wp, 0.0_wp], p, x, v, a)
    CALL require(nan_max_abs(x - [4.0_wp, 0.5_wp, 5.0_wp]) <= 0.0_wp .AND. &
                 nan_max_abs(v - [0.1_wp, 0.2_wp, 0.3_wp]) <= 0.0_wp .AND. &
                 nan_max_abs(a - [0.0_wp, 0.0_wp, -1.0_wp]) <= 0.0_wp, &
                 'point: zero rotation is a pure translation (exact)')
  END SUBROUTINE case_euler_kinematics

  SUBROUTINE point_at(tt, p, xx, vv, aa)
    !! A vessel point on the smooth rotation history with translation r0 = [cos t, t^2, sin 2t].
    REAL(wp), INTENT(IN) :: tt, p(3)
    REAL(wp), INTENT(OUT) :: xx(3), vv(3), aa(3)
    REAL(wp) :: an(3), ra(3), ac(3), om(3), alph(3), r0(3), v0(3), a0(3)
    CALL smooth_angles(tt, an, ra, ac)
    CALL CD_Vessel_Euler_Angular(an, ra, ac, om, alph)
    r0 = [COS(tt), tt*tt, SIN(2.0_wp*tt)]
    v0 = [-SIN(tt), 2.0_wp*tt, 2.0_wp*COS(2.0_wp*tt)]
    a0 = [-COS(tt), 2.0_wp, -4.0_wp*SIN(2.0_wp*tt)]
    CALL CD_Vessel_Point_Kinematics(r0, v0, a0, CD_Vessel_Euler_DCM(an), om, alph, p, xx, vv, aa)
  END SUBROUTINE point_at

  PURE FUNCTION identity() RESULT(m)
    REAL(wp) :: m(3, 3)
    m = 0.0_wp
    m(1, 1) = 1.0_wp; m(2, 2) = 1.0_wp; m(3, 3) = 1.0_wp
  END FUNCTION identity

  SUBROUTINE case_rao_table()
    TYPE(CD_VesselRAOType) :: rao, one
    REAL(wp) :: amp(6, 2, 2), ph(6, 2, 2), re6(6), im6(6), x6(6), v6(6), a6(6), tt, expect
    LOGICAL :: clamped
    INTEGER :: es
    CHARACTER(200) :: em
    amp = 0.0_wp; ph = 0.0_wp
    ! heave: 1.0 at 6 s and 0.5 at 10 s (heading 0); 2.0 and 1.0 at heading 90
    amp(3, :, 1) = [1.0_wp, 0.5_wp]; ph(3, :, 1) = [0.0_wp, 90.0_wp]
    amp(3, :, 2) = [2.0_wp, 1.0_wp]; ph(3, :, 2) = [0.0_wp, 90.0_wp]
    amp(5, :, :) = 2.0_wp; ph(5, :, :) = -45.0_wp   ! pitch 2 deg/m leading by 45 deg
    CALL CD_Vessel_RAO_Set(rao, [6.0_wp, 10.0_wp], [0.0_wp, 90.0_wp], amp, ph, es, em)
    CALL require(es == CD_VESSEL_OK, 'rao: table accepted: '//TRIM(em))
    CALL CD_Vessel_RAO_Eval(rao, 10.0_wp, 0.0_wp, re6, im6, clamped, es, em)
    CALL require(es == CD_VESSEL_OK .AND. .NOT. clamped, 'rao: evaluation at a table entry')
    CALL require(ABS(re6(3)) < 1.0e-15_wp .AND. ABS(im6(3) + 0.5_wp) < 1.0e-15_wp, &
                 'rao: amplitude 0.5 lagging 90 deg is 0.5 exp(-i pi/2)')
    CALL require(ABS(re6(5) - 2.0_wp*D2R*COS(PI/4.0_wp)) < 1.0e-15_wp .AND. &
                 ABS(im6(5) - 2.0_wp*D2R*SIN(PI/4.0_wp)) < 1.0e-15_wp, 'rao: rotations stored in rad/m')
    CALL CD_Vessel_RAO_Eval(rao, 8.0_wp, 45.0_wp, re6, im6, clamped, es, em)
    CALL require(es == CD_VESSEL_OK .AND. ABS(re6(3) - 0.5_wp*(0.5_wp*1.0_wp + 0.5_wp*2.0_wp)) < 1.0e-15_wp .AND. &
                 ABS(im6(3) + 0.5_wp*(0.5_wp*0.5_wp + 0.5_wp*1.0_wp)) < 1.0e-15_wp, &
                 'rao: bilinear interpolation of the complex RAO in period and heading')
    CALL CD_Vessel_RAO_Eval(rao, 20.0_wp, 0.0_wp, re6, im6, clamped, es, em)
    CALL require(es == CD_VESSEL_OK .AND. clamped .AND. ABS(im6(3) + 0.5_wp) < 1.0e-15_wp, &
                 'rao: a longer period takes the last tabulated period and reports it')
    CALL CD_Vessel_RAO_Eval(rao, 8.0_wp, 180.0_wp, re6, im6, clamped, es, em)
    CALL require(es /= CD_VESSEL_OK, 'rao: a heading outside the table range fails closed')
    CALL CD_Vessel_RAO_Eval(rao, 8.0_wp, 450.0_wp, re6, im6, clamped, es, em)
    CALL require(es == CD_VESSEL_OK .AND. ABS(re6(3) - 1.0_wp) < 1.0e-12_wp .AND. ABS(im6(3) + 0.5_wp) < 1.0e-12_wp, &
                 'rao: headings are taken modulo 360 deg')
    CALL CD_Vessel_RAO_Set(one, [8.0_wp], [30.0_wp], amp(:, 1:1, 1:1), ph(:, 1:1, 1:1), es, em)
    CALL CD_Vessel_RAO_Eval(one, 8.0_wp, 30.0_wp, re6, im6, clamped, es, em)
    CALL require(es == CD_VESSEL_OK, 'rao: one-heading table at its heading')
    CALL CD_Vessel_RAO_Eval(one, 8.0_wp, 31.0_wp, re6, im6, clamped, es, em)
    CALL require(es /= CD_VESSEL_OK, 'rao: one-heading table rejects another heading')
    CALL CD_Vessel_RAO_Set(one, [8.0_wp, 6.0_wp], [0.0_wp], amp(:, :, 1:1), ph(:, :, 1:1), es, em)
    CALL require(es /= CD_VESSEL_OK, 'rao: unsorted periods are rejected by the table setter')
    ! lag convention on one component: x = A a cos(w t - eps - P)
    CALL CD_Vessel_RAO_Eval(rao, 10.0_wp, 0.0_wp, re6, im6, clamped, es, em)
    tt = 3.3_wp
    CALL CD_Vessel_RAO_Motion(RESHAPE(re6, [6, 1]), RESHAPE(im6, [6, 1]), [2.0_wp*PI/10.0_wp], [1.5_wp], [0.4_wp], &
                              tt, 1.0_wp, 0.0_wp, 0.0_wp, x6, v6, a6)
    expect = 0.5_wp*1.5_wp*COS(2.0_wp*PI/10.0_wp*tt - 0.4_wp - PI/2.0_wp)
    CALL require(ABS(x6(3) - expect) < 1.0e-14_wp, 'rao: response lags the elevation by the RAO phase')
    expect = -0.5_wp*1.5_wp*(2.0_wp*PI/10.0_wp)*SIN(2.0_wp*PI/10.0_wp*tt - 0.4_wp - PI/2.0_wp)
    CALL require(ABS(v6(3) - expect) < 1.0e-14_wp, 'rao: exact response velocity')
  END SUBROUTINE case_rao_table

  SUBROUTINE case_rao_irregular()
    !! A frequency-dependent heave RAO on a seeded JONSWAP component set: projection of the
    !! response recovers every component's a|RAO| and phase; the long-record variance equals
    !! sum a^2 |RAO|^2 / 2, the RAO-weighted spectral moment of the discretised sea.
    INTEGER, PARAMETER :: NC = CD_JONSWAP_COMPONENTS, NPER = 40
    TYPE(CD_VesselRAOType) :: rao
    REAL(wp) :: om(NC), kk(NC), aa(NC), phs(NC), cre(6, NC), cim(6, NC), per(NPER), amp(6, NPER, 1), ph(6, NPER, 1)
    REAL(wp) :: x6(6), v6(6), a6(6), t, dt, var, m0, mean
    REAL(wp), ALLOCATABLE :: z(:)
    INTEGER :: es, i, n, nt
    LOGICAL :: clamped
    CHARACTER(200) :: em
    CALL CD_JONSWAP_Random_Components(4.0_wp, 10.0_wp, 3.3_wp, 200.0_wp, 9.80665_wp, 7, om, kk, aa, phs, es, em)
    CALL require(es == 0, 'irregular: JONSWAP components')
    DO i = 1, NPER
      per(i) = 1.0_wp + 1.0_wp*REAL(i - 1, wp)
    END DO
    amp = 0.0_wp; ph = 0.0_wp
    amp(3, :, 1) = 1.0_wp/(1.0_wp + (9.0_wp/per)**4)
    ph(3, :, 1) = 60.0_wp/(1.0_wp + (per/9.0_wp)**2)
    CALL CD_Vessel_RAO_Set(rao, per, [0.0_wp], amp, ph, es, em)
    m0 = 0.0_wp
    DO i = 1, NC
      CALL CD_Vessel_RAO_Eval(rao, 2.0_wp*PI/om(i), 0.0_wp, cre(:, i), cim(:, i), clamped, es, em)
      m0 = m0 + 0.5_wp*aa(i)**2*(cre(3, i)**2 + cim(3, i)**2)
    END DO
    dt = 0.25_wp
    nt = 400000
    ALLOCATE (z(nt))
    DO n = 1, nt
      t = REAL(n - 1, wp)*dt
      CALL CD_Vessel_RAO_Motion(cre, cim, om, aa, phs, t, 1.0_wp, 0.0_wp, 0.0_wp, x6, v6, a6)
      z(n) = x6(3)
    END DO
    mean = SUM(z)/REAL(nt, wp)
    var = SUM((z - mean)**2)/REAL(nt, wp)
    CALL require(ABS(var/m0 - 1.0_wp) < 0.02_wp, 'irregular: response variance = RAO-weighted spectral moment')
    ! projection on the most energetic component
    i = MAXLOC(aa**2*(cre(3, :)**2 + cim(3, :)**2), 1)
    BLOCK
      REAL(wp) :: c, s, amp_fit, ph_fit, expect_ph
      c = 0.0_wp; s = 0.0_wp
      DO n = 1, nt
        t = REAL(n - 1, wp)*dt
        c = c + z(n)*COS(om(i)*t - phs(i))
        s = s + z(n)*SIN(om(i)*t - phs(i))
      END DO
      c = 2.0_wp*c/REAL(nt, wp); s = 2.0_wp*s/REAL(nt, wp)
      amp_fit = SQRT(c*c + s*s)
      ph_fit = ATAN2(s, c)
      expect_ph = ATAN2(-cim(3, i), cre(3, i))   ! the lag P
      CALL require(ABS(amp_fit/(aa(i)*SQRT(cre(3, i)**2 + cim(3, i)**2)) - 1.0_wp) < 0.05_wp, &
                   'irregular: dominant component amplitude = a |RAO|')
      CALL require(ABS(ph_fit - expect_ph) < 0.05_wp, 'irregular: dominant component lags by the RAO phase')
    END BLOCK
  END SUBROUTINE case_rao_irregular

  ! ---------------------------------------------------------------- deck-level gates

  SUBROUTINE write_deck(path, options, endconn_row, top_segs)
    !! The lazy-wave power cable of the Hermite deck gates (anchor 0,0,-56; fairlead
    !! Coupled point 2 at 90,0,-14; bare/buoy/bare 40/50/55 m) with extra OPTIONS rows.
    CHARACTER(*), INTENT(IN) :: path
    CHARACTER(*), INTENT(IN) :: options(:)
    CHARACTER(*), INTENT(IN), OPTIONAL :: endconn_row
    INTEGER, INTENT(IN), OPTIONAL :: top_segs
    INTEGER :: u, i, nseg
    nseg = 13
    IF (PRESENT(top_segs)) nseg = top_segs
    OPEN (NEWUNIT=u, FILE=path, STATUS='REPLACE', ACTION='WRITE')
    WRITE (u, '(A)') 'finite-EI lazy-wave power cable on a moving vessel'
    WRITE (u, '(A)') '--- LINE TYPES ---'
    WRITE (u, '(A)') 'Name Diam Mass EA BA EI Cdn Cdt Can Cat'
    WRITE (u, '(A)') '(-) (m) (kg/m) (N) (-) (Nm2) (-) (-) (-) (-)'
    WRITE (u, '(A)') 'bare 0.16 36.70 4.69e8 0.0 1.99e4 1.2 0.1 1.0 0.0'
    WRITE (u, '(A)') 'buoy 0.29 59.53 4.69e8 0.0 1.99e4 1.2 0.1 1.0 0.0'
    WRITE (u, '(A)') '--- POINTS ---'
    WRITE (u, '(A)') 'ID Type X Y Z'
    WRITE (u, '(A)') '(-) (-) (m) (m) (m)'
    WRITE (u, '(A)') '1 Fixed 0.0 0.0 -56.0'
    WRITE (u, '(A)') '2 Coupled 90.0 0.0 -14.0'
    WRITE (u, '(A)') '--- LINES ---'
    WRITE (u, '(A)') 'ID NodeA NodeB Outputs'
    WRITE (u, '(A)') '(-) (-) (-) (-)'
    WRITE (u, '(A)') '1 2 1 -'
    WRITE (u, '(A)') '--- SECTIONS ---'
    WRITE (u, '(A)') 'LineID LineType Length NumSegs'
    WRITE (u, '(A)') '(-) (-) (m) (-)'
    WRITE (u, '(A,I0)') '1 bare 40.0 ', nseg
    WRITE (u, '(A)') '1 buoy 50.0 16'
    WRITE (u, '(A)') '1 bare 55.0 18'
    IF (PRESENT(endconn_row)) THEN
      WRITE (u, '(A)') '--- END CONNECTIONS ---'
      WRITE (u, '(A)') 'LineID End Stiffness EzX EzY EzZ'
      WRITE (u, '(A)') '(-) (-) (N-m/rad) (-) (-) (-)'
      WRITE (u, '(A)') TRIM(endconn_row)
    END IF
    WRITE (u, '(A)') '--- OPTIONS ---'
    WRITE (u, '(A)') '9.80665 g'
    WRITE (u, '(A)') '1025.0 rhoW'
    DO i = 1, SIZE(options)
      IF (LEN_TRIM(options(i)) > 0) WRITE (u, '(A)') TRIM(options(i))
    END DO
    WRITE (u, '(A)') '--- OUTPUTS ---'
    WRITE (u, '(A)') 'FairTen1'
    WRITE (u, '(A)') 'AnchTen1'
    WRITE (u, '(A)') 'BendMom1N1'
    WRITE (u, '(A)') 'Point2px'
    WRITE (u, '(A)') 'Point2py'
    WRITE (u, '(A)') 'Point2pz'
    WRITE (u, '(A)') 'L1N10px'
    WRITE (u, '(A)') 'L1N10pz'
    WRITE (u, '(A)') 'Curv1N2'
    WRITE (u, '(A)') 'END'
    WRITE (u, '(A)') '--- need this line ---'
    CLOSE (u)
  END SUBROUTINE write_deck

  SUBROUTINE pitch_history(t, theta0, period, th, thd, thdd)
    !! Smooth pitch start from rest: theta = theta0 (1 - cos(W t))/2 [deg, deg/s, deg/s2].
    REAL(wp), INTENT(IN) :: t, theta0, period
    REAL(wp), INTENT(OUT) :: th, thd, thdd
    REAL(wp) :: w
    w = 2.0_wp*PI/period
    th = 0.5_wp*theta0*(1.0_wp - COS(w*t))
    thd = 0.5_wp*theta0*w*SIN(w*t)
    thdd = 0.5_wp*theta0*w*w*COS(w*t)
  END SUBROUTINE pitch_history

  SUBROUTINE write_pitch_files(vessel_path, quat_path, motion_path, ref, dt, nstep, theta0, period, hold_after)
    !! Pure pitch about ref: the 19-value Euler record, the 20-value quaternion record, and
    !! the equivalent motionFile rows of the fairlead (point 2), all written round-trip exact.
    CHARACTER(*), INTENT(IN) :: vessel_path, quat_path, motion_path
    REAL(wp), INTENT(IN) :: ref(3), dt, theta0, period, hold_after
    INTEGER, INTENT(IN) :: nstep
    INTEGER :: uv, uq, um, n
    REAL(wp) :: t, th, thd, thdd, row(19), rot(3, 3), x(3), v(3), a(3), half
    CHARACTER(*), PARAMETER :: FMT19 = '(19(1X,ES24.16E3))', FMT20 = '(20(1X,ES24.16E3))', &
                               FMT11 = '(ES24.16E3,I3,9(1X,ES24.16E3))'
    OPEN (NEWUNIT=uv, FILE=vessel_path, STATUS='REPLACE', ACTION='WRITE')
    OPEN (NEWUNIT=uq, FILE=quat_path, STATUS='REPLACE', ACTION='WRITE')
    OPEN (NEWUNIT=um, FILE=motion_path, STATUS='REPLACE', ACTION='WRITE')
    WRITE (uv, '(A)') '# time x y z roll pitch yaw vx vy vz wx wy wz ax ay az alx aly alz'
    WRITE (uq, '(A)') '# time x y z q0 q1 q2 q3 vx vy vz wx wy wz ax ay az alx aly alz'
    WRITE (um, '(A)') '# time point x y z vx vy vz ax ay az'
    DO n = 0, nstep
      t = REAL(n, wp)*dt
      IF (t <= hold_after) THEN
        CALL pitch_history(t, theta0, period, th, thd, thdd)
      ELSE
        th = theta0; thd = 0.0_wp; thdd = 0.0_wp
      END IF
      row = 0.0_wp
      row(1) = t
      row(2:4) = ref
      row(6) = th
      row(12) = thd*D2R
      row(19) = thdd*D2R
      WRITE (uv, FMT19) row
      half = 0.5_wp*th*D2R
      WRITE (uq, FMT20) row(1:4), COS(half), 0.0_wp, SIN(half), 0.0_wp, row(8:19)
      ! the driver's arithmetic on the values it reads back
      rot = CD_Vessel_Euler_DCM(row(5:7)*D2R)
      CALL CD_Vessel_Point_Kinematics(row(2:4), row(8:10), row(14:16), rot, row(11:13), row(17:19), &
                                      [90.0_wp, 0.0_wp, -14.0_wp] - ref, x, v, a)
      WRITE (um, FMT11) t, 2, x, v, a
    END DO
    CLOSE (uv); CLOSE (uq); CLOSE (um)
  END SUBROUTINE write_pitch_files

  SUBROUTINE read_out(path, data, nrow, ncol)
    CHARACTER(*), INTENT(IN) :: path
    REAL(wp), ALLOCATABLE, INTENT(OUT) :: data(:, :)
    INTEGER, INTENT(OUT) :: nrow
    INTEGER, INTENT(IN) :: ncol
    INTEGER :: u, ios
    CHARACTER(4096) :: line
    REAL(wp) :: row(ncol)
    ALLOCATE (data(ncol, 200000))
    nrow = 0
    OPEN (NEWUNIT=u, FILE=path, STATUS='OLD', ACTION='READ', IOSTAT=ios)
    IF (ios /= 0) RETURN
    DO
      READ (u, '(A)', IOSTAT=ios) line
      IF (ios /= 0) EXIT
      IF (line(1:1) == '#' .OR. line(1:4) == 'Time') CYCLE
      READ (line, *, IOSTAT=ios) row
      IF (ios /= 0) CYCLE
      nrow = nrow + 1
      data(:, nrow) = row
    END DO
    CLOSE (u)
  END SUBROUTINE read_out

  LOGICAL FUNCTION same_text(p1, p2) RESULT(same)
    CHARACTER(*), INTENT(IN) :: p1, p2
    INTEGER :: u1, u2, i1, i2
    CHARACTER(4096) :: l1, l2
    same = .FALSE.
    OPEN (NEWUNIT=u1, FILE=p1, STATUS='OLD', ACTION='READ', IOSTAT=i1)
    OPEN (NEWUNIT=u2, FILE=p2, STATUS='OLD', ACTION='READ', IOSTAT=i2)
    IF (i1 /= 0 .OR. i2 /= 0) RETURN
    DO
      READ (u1, '(A)', IOSTAT=i1) l1
      READ (u2, '(A)', IOSTAT=i2) l2
      IF (i1 /= 0 .OR. i2 /= 0) EXIT
      IF (l1 /= l2) THEN
        CLOSE (u1); CLOSE (u2); RETURN
      END IF
    END DO
    same = i1 /= 0 .AND. i2 /= 0
    CLOSE (u1); CLOSE (u2)
  END FUNCTION same_text

  SUBROUTINE run(deck, root, ok, msg)
    CHARACTER(*), INTENT(IN) :: deck, root
    LOGICAL, INTENT(OUT) :: ok
    CHARACTER(*), INTENT(OUT) :: msg
    LOGICAL :: conv
    INTEGER :: es
    CALL CD_Run_Deck_Driver(deck, root, conv, es, msg)
    ok = es == CD_DECKDRV_OK .AND. conv
  END SUBROUTINE run

  SUBROUTINE case_deck_pure_rotation()
    CHARACTER(40) :: opts(4)
    CHARACTER(512) :: msg
    LOGICAL :: ok
    REAL(wp), ALLOCATABLE :: d1(:, :), d2(:, :)
    INTEGER :: n1, n2
    CALL write_pitch_files('vm_pitch_euler.txt', 'vm_pitch_quat.txt', 'vm_pitch_motion.txt', &
                           [80.0_wp, 0.0_wp, -10.0_wp], 0.05_wp, 100, 3.0_wp, 10.0_wp, 1.0e30_wp)
    opts(1) = '0.05 dtM'
    opts(2) = '5.0 TMax'
    ! pinned hang-off: the vessel record and the equivalent point rows give identical runs
    opts(3) = 'vm_pitch_euler.txt vesselMotion'
    opts(4) = '80.0|0.0|-10.0 vesselRef'
    CALL write_deck('vm_vessel.dat', opts)
    CALL run('vm_vessel.dat', 'vm_vessel', ok, msg)
    CALL require(ok, 'pure rotation: vesselMotion deck runs: '//TRIM(msg))
    opts(3) = 'vm_pitch_motion.txt motionFile'
    opts(4) = ''
    CALL write_deck('vm_points.dat', opts)
    CALL run('vm_points.dat', 'vm_points', ok, msg)
    CALL require(ok, 'pure rotation: motionFile deck runs: '//TRIM(msg))
    CALL require(same_text('vm_vessel.out', 'vm_points.out'), &
                 'pure rotation: pinned vesselMotion run is bit-for-bit the equivalent motionFile run')
    ! quaternion form of the same record: round-off
    opts(3) = 'vm_pitch_quat.txt vesselMotion'
    opts(4) = '80.0|0.0|-10.0 vesselRef'
    CALL write_deck('vm_quat.dat', opts)
    CALL run('vm_quat.dat', 'vm_quat', ok, msg)
    CALL require(ok, 'pure rotation: quaternion record runs: '//TRIM(msg))
    CALL read_out('vm_vessel.out', d1, n1, 10)
    CALL read_out('vm_quat.out', d2, n2, 10)
    CALL require(n1 == 101 .AND. n2 == n1, 'pure rotation: full records written')
    IF (n1 == n2 .AND. n1 > 0) THEN
      CALL require(nan_max_abs(d1(5:7, 1:n1) - d2(5:7, 1:n1)) < 1.0e-9_wp, &
                   'pure rotation: quaternion fairlead path = Euler fairlead path')
      CALL require(nan_max_abs(d1(2, 1:n1) - d2(2, 1:n1)) < 1.0e-6_wp*nan_max_abs(d1(2, 1:n1)), &
                   'pure rotation: quaternion fairlead tension = Euler fairlead tension to round-off')
      ! the fairlead did move: 3 deg about a point 10.8 m away
      CALL require(nan_max_abs(d1(5, 1:n1) - 90.0_wp) > 0.2_wp, 'pure rotation: the fairlead is carried')
    END IF
  END SUBROUTINE case_deck_pure_rotation

  SUBROUTINE case_deck_clamped_moment()
    !! Rigid (clamped) hang-off, vessel pitch about the fairlead itself (no translation).
    CHARACTER(40) :: opts(4)
    CHARACTER(120) :: row
    CHARACTER(512) :: msg
    LOGICAL :: ok
    REAL(wp), ALLOCATABLE :: dv(:, :), ds0(:, :), ds1(:, :), dp(:, :)
    INTEGER :: nv, n0, n1, np
    REAL(wp) :: d0(3), d1(3), th, m_dyn, m_s0, m_s1, t_top, dm_beam
    REAL(wp), PARAMETER :: THETA1 = 4.0_wp, EI = 1.99e4_wp
    d0 = [-0.24716_wp, 0.0_wp, -0.968975_wp]
    d0 = d0/NORM2(d0)
    th = THETA1*D2R
    ! pitch +theta about +y: R d0
    d1 = [COS(th)*d0(1) + SIN(th)*d0(3), d0(2), -SIN(th)*d0(1) + COS(th)*d0(3)]
    CALL write_pitch_files('vm_clamp_euler.txt', 'vm_clamp_quat.txt', 'vm_clamp_motion.txt', &
                           [90.0_wp, 0.0_wp, -14.0_wp], 0.05_wp, 900, THETA1, 30.0_wp, 15.0_wp)
    WRITE (row, '(A,3ES24.16)') '1 A Rigid ', d0
    opts(1) = '0.05 dtM'
    opts(2) = '45.0 TMax'
    opts(3) = 'vm_clamp_euler.txt vesselMotion'
    opts(4) = '90.0|0.0|-14.0 vesselRef'
    CALL write_deck('vm_clamp.dat', opts, endconn_row=row, top_segs=80)
    CALL run('vm_clamp.dat', 'vm_clamp', ok, msg)
    CALL require(ok, 'clamped: vessel pitch run completes: '//TRIM(msg))
    ! the same record as translation-only point rows: the clamp stays in global axes
    opts(3) = 'vm_clamp_motion.txt motionFile'
    opts(4) = ''
    CALL write_deck('vm_clamp_pts.dat', opts, endconn_row=row, top_segs=80)
    CALL run('vm_clamp_pts.dat', 'vm_clamp_pts', ok, msg)
    CALL require(ok, 'clamped: translation-only run completes: '//TRIM(msg))
    ! static references: clamp direction d0 and R d0
    opts(1) = '0.05 dtM'; opts(2) = '0.0 TMax'; opts(3) = ''; opts(4) = ''
    CALL write_deck('vm_clamp_s0.dat', opts, endconn_row=row, top_segs=80)
    CALL run('vm_clamp_s0.dat', 'vm_clamp_s0', ok, msg)
    CALL require(ok, 'clamped: static reference d0 solves: '//TRIM(msg))
    WRITE (row, '(A,3ES24.16)') '1 A Rigid ', d1
    CALL write_deck('vm_clamp_s1.dat', opts, endconn_row=row, top_segs=80)
    CALL run('vm_clamp_s1.dat', 'vm_clamp_s1', ok, msg)
    CALL require(ok, 'clamped: static reference R d0 solves: '//TRIM(msg))
    CALL read_out('vm_clamp.out', dv, nv, 10)
    CALL read_out('vm_clamp_pts.out', dp, np, 10)
    CALL read_out('vm_clamp_s0.out', ds0, n0, 10)
    CALL read_out('vm_clamp_s1.out', ds1, n1, 10)
    IF (nv /= 901 .OR. np /= 901 .OR. n0 < 1 .OR. n1 < 1) THEN
      CALL require(.FALSE., 'clamped: all records written')
      RETURN
    END IF
    m_s0 = ds0(4, 1); m_s1 = ds1(4, 1)
    m_dyn = SUM(dv(4, nv - 100:nv))/101.0_wp
    t_top = ds0(2, 1)
    dm_beam = th*SQRT(EI*t_top)
    WRITE (*, '(A,5ES14.6)') '  clamped: M_static(d0), M_static(Rd0), M_dyn(end), dM_beam, T_top = ', &
      m_s0, m_s1, m_dyn, dm_beam, t_top
    CALL require(ABS(dv(4, 1) - m_s0) < 1.0e-6_wp*MAX(1.0_wp, m_s0), &
                 'clamped: t = 0 end moment is the static end moment')
    CALL require(ABS(m_dyn - m_s1) < 0.03_wp*ABS(m_s1 - m_s0), &
                 'clamped: pitched vessel end moment settles on the static rotated-clamp equilibrium')
    CALL require(ABS(ABS(m_s1 - m_s0)/dm_beam - 1.0_wp) < 0.15_wp, &
                 'clamped: end-moment increment = dtheta sqrt(EI T) (tensioned-beam boundary layer)')
    CALL require(ABS(SUM(dp(4, np - 100:np))/101.0_wp - m_s0) < 0.03_wp*ABS(m_s1 - m_s0), &
                 'clamped: the translation-only record keeps the clamp in global axes (no moment change)')
  END SUBROUTINE case_deck_clamped_moment

  SUBROUTINE write_rao_file(path, period, amp6, ph6)
    CHARACTER(*), INTENT(IN) :: path
    REAL(wp), INTENT(IN) :: period(:), amp6(:, :), ph6(:, :)
    INTEGER :: u, i, k
    OPEN (NEWUNIT=u, FILE=path, STATUS='REPLACE', ACTION='WRITE')
    WRITE (u, '(A)') '# displacement RAOs: amplitude m/m or deg/m, phase lag deg'
    DO k = 1, 2
      WRITE (u, '(A,F6.1)') 'HEADING ', MERGE(-30.0_wp, 60.0_wp, k == 1)
      WRITE (u, '(A)') '# period sA sP wA wP hA hP rA rP pA pP yA yP'
      DO i = SIZE(period), 1, -1
        WRITE (u, '(13ES24.15E3)') period(i), amp6(1, i), ph6(1, i), amp6(2, i), ph6(2, i), &
          amp6(3, i), ph6(3, i), amp6(4, i), ph6(4, i), &
          amp6(5, i), ph6(5, i), amp6(6, i), ph6(6, i)
      END DO
    END DO
    CLOSE (u)
  END SUBROUTINE write_rao_file

  SUBROUTINE case_deck_rao_regular()
    !! Regular Airy wave (H 2 m, T 10 s, towards +x) and a vesselRAO table (two headings,
    !! periods 8/10/12 s): heave 0.8 m/m lagging 30 deg and pitch 1.5 deg/m lagging 100 deg at
    !! 10 s. The fairlead follows x = ref + R(pitch) p + heave with the elevation at the
    !! vessel reference point a cos(w t - k x_ref).
    CHARACTER(40) :: opts(7)
    CHARACTER(512) :: msg
    LOGICAL :: ok
    REAL(wp), ALLOCATABLE :: d(:, :)
    REAL(wp) :: amp6(6, 3), ph6(6, 3), k, w, t, a, heave, pitch, rot(3, 3), x(3), v(3), acc(3)
    REAL(wp) :: err, ref(3)
    INTEGER :: nr, n, es
    CHARACTER(200) :: em
    amp6 = 0.0_wp; ph6 = 0.0_wp
    amp6(3, :) = [0.5_wp, 0.8_wp, 0.9_wp]; ph6(3, :) = [10.0_wp, 30.0_wp, 50.0_wp]
    amp6(5, :) = [1.0_wp, 1.5_wp, 1.2_wp]; ph6(5, :) = [80.0_wp, 100.0_wp, 120.0_wp]
    CALL write_rao_file('vm_rao.txt', [8.0_wp, 10.0_wp, 12.0_wp], amp6, ph6)
    opts(1) = '0.05 dtM'
    opts(2) = '20.0 TMax'
    opts(3) = '60.0 WtrDpth'
    opts(4) = 'airy 2.0 10.0 0.0 waves'
    opts(5) = 'vm_rao.txt vesselRAO'
    opts(6) = '75.0|0.0|0.0 vesselRef'
    opts(7) = ''
    CALL write_deck('vm_rao.dat', opts)
    CALL run('vm_rao.dat', 'vm_rao', ok, msg)
    CALL require(ok, 'rao regular: deck runs: '//TRIM(msg))
    CALL read_out('vm_rao.out', d, nr, 10)
    CALL require(nr == 401, 'rao regular: full record written')
    IF (nr /= 401) RETURN
    w = 2.0_wp*PI/10.0_wp
    CALL CD_Solve_Dispersion_Wavenumber(w, 60.0_wp, 9.80665_wp, k, es, em)
    ref = [75.0_wp, 0.0_wp, 0.0_wp]
    a = 1.0_wp
    err = 0.0_wp
    DO n = 1, nr
      t = d(1, n)
      heave = 0.8_wp*a*COS(w*t - k*ref(1) - 30.0_wp*D2R)
      pitch = 1.5_wp*D2R*a*COS(w*t - k*ref(1) - 100.0_wp*D2R)
      rot = CD_Vessel_Euler_DCM([0.0_wp, pitch, 0.0_wp])
      CALL CD_Vessel_Point_Kinematics(ref + [0.0_wp, 0.0_wp, heave], [0.0_wp, 0.0_wp, 0.0_wp], &
                                      [0.0_wp, 0.0_wp, 0.0_wp], rot, [0.0_wp, 0.0_wp, 0.0_wp], &
                                      [0.0_wp, 0.0_wp, 0.0_wp], [90.0_wp, 0.0_wp, -14.0_wp] - ref, x, v, acc)
      err = MAX(err, nan_max_abs(d(5:7, n) - x))
    END DO
    WRITE (*, '(A,ES12.4)') '  rao regular: max fairlead position error [m] = ', err
    CALL require(err < 1.0e-5_wp, 'rao regular: fairlead = ref + amplitude x RAO with the lag phase against '// &
                 'the wave at the vessel reference point')
  END SUBROUTINE case_deck_rao_regular

  SUBROUTINE case_deck_rao_irregular()
    !! JONSWAP sea through a heave-only RAO (1 m/m, 0 deg at every period) with the fairlead
    !! directly below the reference point: the fairlead heave is the elevation of the SAME
    !! seeded components that drive the line kinematics, evaluated at the reference point.
    INTEGER, PARAMETER :: NC = CD_JONSWAP_COMPONENTS
    CHARACTER(40) :: opts(8)
    CHARACTER(512) :: msg
    LOGICAL :: ok
    REAL(wp), ALLOCATABLE :: d(:, :)
    REAL(wp) :: amp6(6, 2), ph6(6, 2), om(NC), kk(NC), aa(NC), phs(NC), t, eta, err, r, rd, rdd, cb, sb, xa
    INTEGER :: nr, n, i, es
    CHARACTER(200) :: em
    amp6 = 0.0_wp; ph6 = 0.0_wp
    amp6(3, :) = 1.0_wp
    CALL write_rao_file('vm_rao_irr.txt', [0.5_wp, 100.0_wp], amp6, ph6)
    opts(1) = '0.05 dtM'
    opts(2) = '20.0 TMax'
    opts(3) = '60.0 WtrDpth'
    opts(4) = 'jonswap 2.0 9.0 3.3 30.0 waves'
    opts(5) = '11 WaveSeed'
    opts(6) = 'vm_rao_irr.txt vesselRAO'
    opts(7) = '90.0|0.0|0.0 vesselRef'
    opts(8) = '6.0 rampTime'
    CALL write_deck('vm_rao_irr.dat', opts)
    CALL run('vm_rao_irr.dat', 'vm_rao_irr', ok, msg)
    CALL require(ok, 'rao irregular: deck runs: '//TRIM(msg))
    CALL read_out('vm_rao_irr.out', d, nr, 10)
    CALL require(nr == 401, 'rao irregular: full record written')
    IF (nr /= 401) RETURN
    CALL CD_JONSWAP_Random_Components(2.0_wp, 9.0_wp, 3.3_wp, 60.0_wp, 9.80665_wp, 11, om, kk, aa, phs, es, em)
    cb = COS(30.0_wp*D2R); sb = SIN(30.0_wp*D2R)
    xa = 90.0_wp*cb
    err = 0.0_wp
    DO n = 1, nr
      t = d(1, n)
      CALL CD_Vessel_Ramp(6.0_wp, t, r, rd, rdd)
      eta = 0.0_wp
      DO i = 1, NC
        eta = eta + aa(i)*COS(kk(i)*xa - om(i)*t + phs(i))
      END DO
      err = MAX(err, ABS(d(7, n) - (-14.0_wp + r*eta)))
    END DO
    WRITE (*, '(A,ES12.4)') '  rao irregular: max fairlead heave error vs ramped elevation [m] = ', err
    CALL require(err < 1.0e-5_wp, 'rao irregular: the vessel moves with the wave phases of the line kinematics')
    CALL require(nan_max_abs(d(7, :nr) + 14.0_wp) > 0.2_wp, 'rao irregular: the fairlead heaves')
  END SUBROUTINE case_deck_rao_irregular

  SUBROUTINE case_deck_rao_spread()
    !! A spread JONSWAP sea (cos-2s, s = 4) through a heave-only RAO defined over the full
    !! circle of headings: every component, whatever its own direction, moves the vessel,
    !! and the fairlead below the reference point heaves with the ramped elevation of the
    !! SAME spread components that drive the line kinematics.
    TYPE(CD_SeaType) :: sea
    TYPE(CD_WaveTrainType) :: train
    CHARACTER(40) :: opts(9)
    CHARACTER(512) :: msg
    LOGICAL :: ok
    REAL(wp), ALLOCATABLE :: d(:, :)
    REAL(wp) :: t, eta, err, r, rd, rdd, dmin, dmax
    INTEGER :: nr, n, i, es, u
    CHARACTER(200) :: em
    OPEN (NEWUNIT=u, FILE='vm_rao_spread.txt', STATUS='REPLACE', ACTION='WRITE')
    DO i = 1, 2
      WRITE (u, '(A,F7.1)') 'HEADING ', MERGE(-180.0_wp, 179.0_wp, i == 1)
      WRITE (u, '(A)') '0.5 0 0 0 0 1 0 0 0 0 0 0 0'
      WRITE (u, '(A)') '100 0 0 0 0 1 0 0 0 0 0 0 0'
    END DO
    CLOSE (u)
    opts(1) = '0.05 dtM'
    opts(2) = '20.0 TMax'
    opts(3) = '60.0 WtrDpth'
    opts(4) = 'jonswap 2.0 9.0 3.3 30.0 waves'
    opts(5) = '4 WaveSpreading'
    opts(6) = '11 WaveSeed'
    opts(7) = 'vm_rao_spread.txt vesselRAO'
    opts(8) = '90.0|0.0|0.0 vesselRef'
    opts(9) = '6.0 rampTime'
    CALL write_deck('vm_rao_spread.dat', opts)
    CALL run('vm_rao_spread.dat', 'vm_rao_spread', ok, msg)
    CALL require(ok, 'rao spread: deck runs: '//TRIM(msg))
    CALL read_out('vm_rao_spread.out', d, nr, 10)
    CALL require(nr == 401, 'rao spread: full record written')
    IF (nr /= 401) RETURN
    CALL CD_Sea_Reset(sea)
    train%kind = CD_TRAIN_JONSWAP
    train%height = 2.0_wp; train%period = 9.0_wp; train%gamma = 3.3_wp
    train%direction = 30.0_wp; train%spreading = 4.0_wp
    CALL CD_Sea_Add_Train(sea, train, es, em)
    CALL CD_Sea_Synthesise(sea, 60.0_wp, 9.80665_wp, 11, es, em)
    CALL require(es == 0 .AND. sea%n_comp > 200, 'rao spread: reference sea synthesised: '//TRIM(em))
    IF (es /= 0) RETURN
    dmin = 1.0e30_wp; dmax = -1.0e30_wp
    DO i = 1, sea%n_comp
      dmin = MIN(dmin, ATAN2(sea%sinb(i), sea%cosb(i))); dmax = MAX(dmax, ATAN2(sea%sinb(i), sea%cosb(i)))
    END DO
    err = 0.0_wp
    DO n = 1, nr
      t = d(1, n)
      CALL CD_Vessel_Ramp(6.0_wp, t, r, rd, rdd)
      eta = 0.0_wp
      DO i = 1, sea%n_comp
        eta = eta + sea%amplitude(i)*COS(sea%k(i)*(90.0_wp*sea%cosb(i)) - sea%omega(i)*t + sea%phase(i))
      END DO
      err = MAX(err, ABS(d(7, n) - (-14.0_wp + r*eta)))
    END DO
    WRITE (*, '(A,I0,A,2F8.2,A,ES12.4)') '  rao spread: ', sea%n_comp, ' components over headings ', &
      dmin/D2R, dmax/D2R, ' deg; max fairlead heave error [m] = ', err
    CALL require(dmax - dmin > 1.0_wp, 'rao spread: the sea is spread over headings')
    CALL require(err < 1.0e-5_wp, 'rao spread: every spread component drives the vessel with its own phase')
  END SUBROUTINE case_deck_rao_spread

  SUBROUTINE case_deck_rao_wavekin7()
    !! A heave-only RAO over the full circle of headings: the fairlead below the reference point
    !! heaves with the elevation of the file's rows there.
    INTEGER, PARAMETER :: NC = 3
    REAL(wp), PARAMETER :: W(NC) = [0.6_wp, 0.75_wp, 0.9_wp], RE(NC) = [0.5_wp, -0.2_wp, 0.3_wp]
    REAL(wp), PARAMETER :: IM(NC) = [0.1_wp, 0.4_wp, -0.25_wp], BETA(NC) = [0.65_wp, 2.9_wp, -2.2_wp]
    REAL(wp), PARAMETER :: X0 = 31.5_wp, Y0 = -12.0_wp
    CHARACTER(40) :: opts(9)
    CHARACTER(512) :: msg
    LOGICAL :: ok
    REAL(wp), ALLOCATABLE :: d(:, :)
    REAL(wp) :: kk(NC), t, eta, err, dist, r, rd, rdd
    INTEGER :: nr, n, i, es, u
    CHARACTER(200) :: em
    OPEN (NEWUNIT=u, FILE='vm_wk7/vm_rao.txt', STATUS='REPLACE', ACTION='WRITE')
    DO i = 1, 2
      WRITE (u, '(A,F7.1)') 'HEADING ', MERGE(-180.0_wp, 179.0_wp, i == 1)
      WRITE (u, '(A)') '0.5 0 0 0 0 1 0 0 0 0 0 0 0'
      WRITE (u, '(A)') '100 0 0 0 0 1 0 0 0 0 0 0 0'
    END DO
    CLOSE (u)
    OPEN (NEWUNIT=u, FILE='vm_wk7/wave_frequencies.txt', STATUS='REPLACE', ACTION='WRITE')
    WRITE (u, '(A)') '0.0 0.0 0.0 0.0'
    DO i = 1, NC
      WRITE (u, '(4ES24.16)') W(i), RE(i), IM(i), BETA(i)
    END DO
    CLOSE (u)
    opts(1) = '0.05 dtM'
    opts(2) = '20.0 TMax'
    opts(3) = '60.0 WtrDpth'
    opts(4) = '7 WaveKin'
    opts(5) = 'vm_rao.txt vesselRAO'
    opts(6) = '90.0|0.0|0.0 vesselRef'
    opts(7) = '31.5 WaveRefX'
    opts(8) = '-12.0 WaveRefY'
    opts(9) = '6.0 rampTime'
    CALL write_deck('vm_wk7/vm_wk7.dat', opts)
    CALL run('vm_wk7/vm_wk7.dat', 'vm_wk7/out', ok, msg)
    CALL require(ok, 'rao WaveKin 7: deck runs: '//TRIM(msg))
    CALL read_out('vm_wk7/out.out', d, nr, 10)
    CALL require(nr == 401, 'rao WaveKin 7: full record written')
    IF (nr /= 401) RETURN
    DO i = 1, NC
      CALL CD_Solve_Dispersion_Wavenumber(W(i), 60.0_wp, 9.80665_wp, kk(i), es, em)
      CALL require(es == 0, 'rao WaveKin 7: dispersion solve: '//TRIM(em))
    END DO
    err = 0.0_wp
    DO n = 1, nr
      t = d(1, n)
      CALL CD_Vessel_Ramp(6.0_wp, t, r, rd, rdd)
      eta = 0.0_wp
      DO i = 1, NC
        dist = (90.0_wp - X0)*COS(BETA(i)) + (0.0_wp - Y0)*SIN(BETA(i))
        eta = eta + SQRT(RE(i)**2 + IM(i)**2)*SIN(W(i)*t - kk(i)*dist + ATAN2(IM(i), RE(i)))
      END DO
      err = MAX(err, ABS(d(7, n) - (-14.0_wp + r*eta)))
    END DO
    WRITE (*, '(A,ES12.4)') '  rao WaveKin 7: max fairlead heave error [m] = ', err
    CALL require(err < 1.0e-5_wp, 'rao WaveKin 7: each row drives the vessel with its own heading and phase')
  END SUBROUTINE case_deck_rao_wavekin7

  SUBROUTINE case_deck_rao_stream_rejected()
    CHARACTER(40) :: opts(6)
    CHARACTER(512) :: msg
    LOGICAL :: ok
    opts(1) = '0.05 dtM'
    opts(2) = '1.0 TMax'
    opts(3) = '60.0 WtrDpth'
    opts(4) = 'stream 2.0 10.0 0.0 waves'
    opts(5) = 'vm_rao.txt vesselRAO'
    opts(6) = ''
    CALL write_deck('vm_bad_stream.dat', opts)
    CALL run('vm_bad_stream.dat', 'vm_bad_stream', ok, msg)
    CALL require(.NOT. ok .AND. INDEX(msg, 'stream-function') > 0, 'reject: vesselRAO on a stream wave: '// &
                 TRIM(msg))
  END SUBROUTINE case_deck_rao_stream_rejected

  SUBROUTINE case_deck_rejections()
    CHARACTER(40) :: opts(5)
    CHARACTER(512) :: msg
    LOGICAL :: ok
    INTEGER :: u
    opts(1) = '0.05 dtM'
    opts(2) = '1.0 TMax'
    opts(3) = 'vm_pitch_euler.txt vesselMotion'
    opts(4) = 'vm_pitch_motion.txt motionFile'
    opts(5) = ''
    CALL write_deck('vm_bad1.dat', opts)
    CALL run('vm_bad1.dat', 'vm_bad1', ok, msg)
    CALL require(.NOT. ok .AND. INDEX(msg, 'alternative') > 0, 'reject: motionFile with vesselMotion: '//TRIM(msg))
    opts(3) = 'vm_rao.txt vesselRAO'
    opts(4) = ''
    CALL write_deck('vm_bad2.dat', opts)
    CALL run('vm_bad2.dat', 'vm_bad2', ok, msg)
    CALL require(.NOT. ok .AND. INDEX(msg, 'waves') > 0, 'reject: vesselRAO without waves: '//TRIM(msg))
    opts(3) = 'vm_pitch_euler.txt vesselMotion'
    opts(4) = '1|2 vesselRef'
    CALL write_deck('vm_bad3.dat', opts)
    CALL run('vm_bad3.dat', 'vm_bad3', ok, msg)
    CALL require(.NOT. ok .AND. INDEX(msg, 'vesselRef') > 0, 'reject: two-value vesselRef: '//TRIM(msg))
    OPEN (NEWUNIT=u, FILE='vm_bad_rec.txt', STATUS='REPLACE', ACTION='WRITE')
    WRITE (u, '(A)') '0.0 80 0 -10 0 0 0 0 0 0 0 0 0 0 0 0 0 0'
    CLOSE (u)
    opts(3) = 'vm_bad_rec.txt vesselMotion'
    opts(4) = ''
    CALL write_deck('vm_bad4.dat', opts)
    CALL run('vm_bad4.dat', 'vm_bad4', ok, msg)
    CALL require(.NOT. ok .AND. INDEX(msg, '19 values') > 0, 'reject: an 18-value vessel row: '//TRIM(msg))
    OPEN (NEWUNIT=u, FILE='vm_bad_quat.txt', STATUS='REPLACE', ACTION='WRITE')
    WRITE (u, '(A)') '0.0 80 0 -10 0.9 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0'
    CLOSE (u)
    opts(3) = 'vm_bad_quat.txt vesselMotion'
    CALL write_deck('vm_bad5.dat', opts)
    CALL run('vm_bad5.dat', 'vm_bad5', ok, msg)
    CALL require(.NOT. ok .AND. INDEX(msg, 'unit norm') > 0, 'reject: a non-unit quaternion: '//TRIM(msg))
    OPEN (NEWUNIT=u, FILE='vm_bad_rao.txt', STATUS='REPLACE', ACTION='WRITE')
    WRITE (u, '(A)') 'HEADING 0'
    WRITE (u, '(A)') '10 0 0 0 0 1 0 0 0 0 0 0 0'
    WRITE (u, '(A)') 'HEADING 90'
    WRITE (u, '(A)') '12 0 0 0 0 1 0 0 0 0 0 0 0'
    CLOSE (u)
    opts(3) = 'vm_bad_rao.txt vesselRAO'
    opts(4) = '60.0 WtrDpth'
    opts(5) = 'airy 2.0 10.0 0.0 waves'
    CALL write_deck('vm_bad6.dat', opts)
    CALL run('vm_bad6.dat', 'vm_bad6', ok, msg)
    CALL require(.NOT. ok .AND. INDEX(msg, 'same periods') > 0, 'reject: RAO blocks with different periods: '// &
                 TRIM(msg))
  END SUBROUTINE case_deck_rejections

END PROGRAM test_vessel_motion
