! File: src/CableDyn_Vessel.f90
! SPDX-License-Identifier: Apache-2.0
! Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
MODULE CableDyn_Vessel
  !! Rigid-body vessel kinematics for standalone prescribed motion.
  !!
  !! A vessel is a rigid body with a reference point r (the rotation centre and RAO
  !! origin) and a rotation R that maps vessel axes to global axes. The vessel axes
  !! coincide with the global axes at the reference pose. A point fixed to the vessel
  !! at the vessel-frame offset p moves as
  !!
  !!   x = r + R p,   v = dr/dt + w x (R p),   a = d2r/dt2 + al x (R p) + w x (w x (R p)),
  !!
  !! with w and al the angular velocity and acceleration in GLOBAL axes.
  !!
  !! Euler angles (roll phi, pitch theta, yaw psi) follow the OrcaFlex vessel convention:
  !! R = Rz(psi) Ry(theta) Rx(phi), right-handed rotations about the vessel x (roll),
  !! y (pitch) and z (yaw) axes, applied yaw, then pitch about the yawed y axis, then
  !! roll about the final x axis.
  !!
  !! Displacement RAOs (CD_VesselRAOType) give, per degree of freedom j, an amplitude
  !! A_j [m/m or deg/m] and a phase LAG P_j [deg] relative to the wave crest at the RAO
  !! origin: a wave component whose elevation at the RAO origin is a cos(omega t - eps)
  !! drives x_j = A_j a cos(omega t - eps - P_j). The complex RAO A_j exp(-i P_j) is
  !! interpolated linearly in wave period and in relative heading (its real and
  !! imaginary parts), so phase wrap-around never enters the interpolation.
  USE CableDyn_Precision, ONLY: wp, CD_ZERO, CD_ONE, CD_All_Finite, CD_Is_Finite
  IMPLICIT NONE
  PRIVATE

  PUBLIC :: CD_VesselRAOType
  PUBLIC :: CD_Vessel_Euler_DCM
  PUBLIC :: CD_Vessel_Euler_Angular
  PUBLIC :: CD_Vessel_Point_Kinematics
  PUBLIC :: CD_Vessel_RAO_Set
  PUBLIC :: CD_Vessel_RAO_Eval
  PUBLIC :: CD_Vessel_RAO_Motion
  PUBLIC :: CD_Vessel_Ramp
  PUBLIC :: CD_VESSEL_OK, CD_VESSEL_BADINPUT

  INTEGER, PARAMETER :: CD_VESSEL_OK = 0, CD_VESSEL_BADINPUT = 1
  REAL(wp), PARAMETER :: PI = 3.14159265358979323846_wp
  REAL(wp), PARAMETER :: DEG2RAD = PI/180.0_wp

  TYPE :: CD_VesselRAOType
    !! Displacement RAO table: nper wave periods (ascending) x nhead relative headings
    !! (ascending, within one 360 deg turn of the first). re/im hold the complex RAO
    !! A exp(-i P) per DOF [surge, sway, heave in m/m; roll, pitch, yaw in rad/m].
    INTEGER :: nper = 0, nhead = 0
    REAL(wp), ALLOCATABLE :: period(:), heading(:)
    REAL(wp), ALLOCATABLE :: re(:, :, :), im(:, :, :)
  END TYPE CD_VesselRAOType

CONTAINS

  PURE FUNCTION CD_Vessel_Euler_DCM(angles) RESULT(r)
    !! R = Rz(yaw) Ry(pitch) Rx(roll) for angles = [roll, pitch, yaw] in radians
    !! (vessel-to-global rotation).
    REAL(wp), INTENT(IN) :: angles(3)
    REAL(wp) :: r(3, 3)
    REAL(wp) :: cr, sr, cp, sp, cy, sy
    cr = COS(angles(1)); sr = SIN(angles(1))
    cp = COS(angles(2)); sp = SIN(angles(2))
    cy = COS(angles(3)); sy = SIN(angles(3))
    r(1, :) = [cy*cp, cy*sp*sr - sy*cr, cy*sp*cr + sy*sr]
    r(2, :) = [sy*cp, sy*sp*sr + cy*cr, sy*sp*cr - cy*sr]
    r(3, :) = [-sp, cp*sr, cp*cr]
  END FUNCTION CD_Vessel_Euler_DCM

  PURE SUBROUTINE CD_Vessel_Euler_Angular(angles, rates, accels, omega, alpha)
    !! Global-axis angular velocity and acceleration of R = Rz(psi) Ry(theta) Rx(phi)
    !! from the Euler angles, their rates and their second derivatives [rad, rad/s, rad/s2]:
    !!   w  = psi' ez + theta' ey1 + phi' ex2,
    !!   al = psi'' ez + theta'' ey1 + phi'' ex2 + theta' (psi' ez x ey1) + phi' (w1 x ex2),
    !! with ey1 = Rz ey, ex2 = Rz Ry ex and w1 = psi' ez + theta' ey1.
    REAL(wp), INTENT(IN) :: angles(3), rates(3), accels(3)
    REAL(wp), INTENT(OUT) :: omega(3), alpha(3)
    REAL(wp) :: ez(3), ey1(3), ex2(3), w1(3)
    REAL(wp) :: cp, sp, cy, sy
    cp = COS(angles(2)); sp = SIN(angles(2))
    cy = COS(angles(3)); sy = SIN(angles(3))
    ez = [CD_ZERO, CD_ZERO, CD_ONE]
    ey1 = [-sy, cy, CD_ZERO]
    ex2 = [cy*cp, sy*cp, -sp]
    w1 = rates(3)*ez + rates(2)*ey1
    omega = w1 + rates(1)*ex2
    alpha = accels(3)*ez + accels(2)*ey1 + accels(1)*ex2 + rates(2)*cross(rates(3)*ez, ey1) + &
            rates(1)*cross(w1, ex2)
  END SUBROUTINE CD_Vessel_Euler_Angular

  PURE SUBROUTINE CD_Vessel_Point_Kinematics(r, v, a, rot, omega, alpha, p_local, x, xv, xa)
    !! Position, velocity and acceleration of the vessel-fixed point at offset p_local.
    REAL(wp), INTENT(IN) :: r(3), v(3), a(3), rot(3, 3), omega(3), alpha(3), p_local(3)
    REAL(wp), INTENT(OUT) :: x(3), xv(3), xa(3)
    REAL(wp) :: rp(3)
    rp = MATMUL(rot, p_local)
    x = r + rp
    xv = v + cross(omega, rp)
    xa = a + cross(alpha, rp) + cross(omega, cross(omega, rp))
  END SUBROUTINE CD_Vessel_Point_Kinematics

  PURE SUBROUTINE CD_Vessel_Ramp(ramp_time, time, r, rd, rdd)
    !! Half-cosine start-up ramp r(t) = (1 - cos(pi t/T))/2 on [0, T] (the deck wave
    !! ramp) with its first and second time derivatives; T <= 0 disables it (r = 1).
    REAL(wp), INTENT(IN) :: ramp_time, time
    REAL(wp), INTENT(OUT) :: r, rd, rdd
    REAL(wp) :: arg
    r = CD_ONE; rd = CD_ZERO; rdd = CD_ZERO
    IF (.NOT. (ramp_time > CD_ZERO) .OR. time >= ramp_time) RETURN
    IF (time <= CD_ZERO) THEN
      r = CD_ZERO
      RETURN
    END IF
    arg = PI*time/ramp_time
    r = 0.5_wp*(CD_ONE - COS(arg))
    rd = 0.5_wp*(PI/ramp_time)*SIN(arg)
    rdd = 0.5_wp*(PI/ramp_time)**2*COS(arg)
  END SUBROUTINE CD_Vessel_Ramp

  SUBROUTINE CD_Vessel_RAO_Set(rao, period, heading, amplitude, phase_deg, ErrStat, ErrMsg)
    !! Validate and store a displacement RAO table. period(nper) [s] and heading(nhead)
    !! [deg] must be strictly ascending (headings within one turn); amplitude and
    !! phase_deg are (6, nper, nhead): amplitudes in m/m (surge, sway, heave) and deg/m
    !! (roll, pitch, yaw), phases as lags in degrees.
    TYPE(CD_VesselRAOType), INTENT(OUT) :: rao
    REAL(wp), INTENT(IN) :: period(:), heading(:), amplitude(:, :, :), phase_deg(:, :, :)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    INTEGER :: np, nh, i, j
    ErrStat = CD_VESSEL_OK; ErrMsg = ''
    np = SIZE(period); nh = SIZE(heading)
    IF (np < 1 .OR. nh < 1) THEN
      ErrStat = CD_VESSEL_BADINPUT; ErrMsg = 'RAO table needs at least one period and one heading'; RETURN
    END IF
    IF (SIZE(amplitude, 1) /= 6 .OR. SIZE(amplitude, 2) /= np .OR. SIZE(amplitude, 3) /= nh .OR. &
        ANY(SHAPE(phase_deg) /= SHAPE(amplitude))) THEN
      ErrStat = CD_VESSEL_BADINPUT; ErrMsg = 'RAO amplitude/phase arrays must be (6, nperiod, nheading)'; RETURN
    END IF
    IF (.NOT. (CD_All_Finite(period) .AND. CD_All_Finite(heading) .AND. CD_All_Finite(RESHAPE(amplitude, [6*np*nh])) &
               .AND. CD_All_Finite(RESHAPE(phase_deg, [6*np*nh])))) THEN
      ErrStat = CD_VESSEL_BADINPUT; ErrMsg = 'RAO table values must be finite'; RETURN
    END IF
    IF (ANY(period <= CD_ZERO)) THEN
      ErrStat = CD_VESSEL_BADINPUT; ErrMsg = 'RAO periods must be positive'; RETURN
    END IF
    IF (ANY(amplitude < CD_ZERO)) THEN
      ErrStat = CD_VESSEL_BADINPUT; ErrMsg = 'RAO amplitudes must be non-negative'; RETURN
    END IF
    DO i = 2, np
      IF (.NOT. period(i) > period(i - 1)) THEN
        ErrStat = CD_VESSEL_BADINPUT; ErrMsg = 'RAO periods must be strictly ascending'; RETURN
      END IF
    END DO
    DO j = 2, nh
      IF (.NOT. heading(j) > heading(j - 1)) THEN
        ErrStat = CD_VESSEL_BADINPUT; ErrMsg = 'RAO headings must be strictly ascending'; RETURN
      END IF
    END DO
    IF (heading(nh) - heading(1) >= 360.0_wp) THEN
      ErrStat = CD_VESSEL_BADINPUT; ErrMsg = 'RAO headings must lie within one 360 deg turn'; RETURN
    END IF
    rao%nper = np; rao%nhead = nh
    ALLOCATE (rao%period(np), rao%heading(nh), rao%re(6, np, nh), rao%im(6, np, nh))
    rao%period = period
    rao%heading = heading
    DO j = 1, nh
      DO i = 1, np
        rao%re(:, i, j) = amplitude(:, i, j)*COS(phase_deg(:, i, j)*DEG2RAD)
        rao%im(:, i, j) = -amplitude(:, i, j)*SIN(phase_deg(:, i, j)*DEG2RAD)
        rao%re(4:6, i, j) = rao%re(4:6, i, j)*DEG2RAD
        rao%im(4:6, i, j) = rao%im(4:6, i, j)*DEG2RAD
      END DO
    END DO
  END SUBROUTINE CD_Vessel_RAO_Set

  SUBROUTINE CD_Vessel_RAO_Eval(rao, period, heading_deg, re6, im6, clamped, ErrStat, ErrMsg)
    !! Complex RAO (per DOF, rotations in rad/m) at one wave period [s] and relative
    !! heading [deg]. Linear in period and heading; a period outside the table takes the
    !! nearest tabulated period's value (clamped = .TRUE.). The heading, taken modulo
    !! 360 deg, must lie within the tabulated heading range; a one-heading table
    !! requires that heading exactly (within 1e-9 deg).
    TYPE(CD_VesselRAOType), INTENT(IN) :: rao
    REAL(wp), INTENT(IN) :: period, heading_deg
    REAL(wp), INTENT(OUT) :: re6(6), im6(6)
    LOGICAL, INTENT(OUT) :: clamped
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    INTEGER :: ip, ih
    REAL(wp) :: fp, fh, h, tol
    REAL(wp) :: re_lo(6), re_hi(6), im_lo(6), im_hi(6)
    ErrStat = CD_VESSEL_OK; ErrMsg = ''
    re6 = CD_ZERO; im6 = CD_ZERO; clamped = .FALSE.
    IF (rao%nper < 1 .OR. rao%nhead < 1) THEN
      ErrStat = CD_VESSEL_BADINPUT; ErrMsg = 'RAO table is empty'; RETURN
    END IF
    IF (.NOT. (CD_Is_Finite(period) .AND. period > CD_ZERO .AND. CD_Is_Finite(heading_deg))) THEN
      ErrStat = CD_VESSEL_BADINPUT; ErrMsg = 'RAO evaluation needs a finite positive period and finite heading'
      RETURN
    END IF
    tol = 1.0e-9_wp
    h = rao%heading(1) + MODULO(heading_deg - rao%heading(1), 360.0_wp)
    IF (h > rao%heading(rao%nhead) + tol .AND. ABS(h - 360.0_wp - rao%heading(1)) <= tol) h = rao%heading(1)
    IF (rao%nhead == 1) THEN
      IF (ABS(h - rao%heading(1)) > tol) THEN
        ErrStat = CD_VESSEL_BADINPUT
        ErrMsg = 'relative wave heading is not in the one-heading RAO table'
        RETURN
      END IF
      ih = 1; fh = CD_ZERO
    ELSE
      IF (h > rao%heading(rao%nhead) + tol) THEN
        ErrStat = CD_VESSEL_BADINPUT
        ErrMsg = 'relative wave heading lies outside the RAO table heading range'
        RETURN
      END IF
      h = MIN(h, rao%heading(rao%nhead))
      ih = 1
      DO WHILE (ih < rao%nhead - 1 .AND. h > rao%heading(ih + 1))
        ih = ih + 1
      END DO
      fh = (h - rao%heading(ih))/(rao%heading(ih + 1) - rao%heading(ih))
      fh = MIN(MAX(fh, CD_ZERO), CD_ONE)
    END IF
    IF (period <= rao%period(1)) THEN
      ip = 1; fp = CD_ZERO
      clamped = period < rao%period(1)
    ELSE IF (period >= rao%period(rao%nper)) THEN
      ip = MAX(1, rao%nper - 1); fp = MERGE(CD_ONE, CD_ZERO, rao%nper > 1)
      clamped = period > rao%period(rao%nper)
    ELSE
      ip = 1
      DO WHILE (period > rao%period(ip + 1))
        ip = ip + 1
      END DO
      fp = (period - rao%period(ip))/(rao%period(ip + 1) - rao%period(ip))
    END IF
    CALL period_interp(ih, re_lo, im_lo)
    IF (rao%nhead > 1) THEN
      CALL period_interp(ih + 1, re_hi, im_hi)
      re6 = (CD_ONE - fh)*re_lo + fh*re_hi
      im6 = (CD_ONE - fh)*im_lo + fh*im_hi
    ELSE
      re6 = re_lo
      im6 = im_lo
    END IF
  CONTAINS
    SUBROUTINE period_interp(jh, rr, ii)
      INTEGER, INTENT(IN) :: jh
      REAL(wp), INTENT(OUT) :: rr(6), ii(6)
      IF (rao%nper == 1) THEN
        rr = rao%re(:, 1, jh); ii = rao%im(:, 1, jh)
      ELSE
        rr = (CD_ONE - fp)*rao%re(:, ip, jh) + fp*rao%re(:, ip + 1, jh)
        ii = (CD_ONE - fp)*rao%im(:, ip, jh) + fp*rao%im(:, ip + 1, jh)
      END IF
    END SUBROUTINE period_interp
  END SUBROUTINE CD_Vessel_RAO_Eval

  PURE SUBROUTINE CD_Vessel_RAO_Motion(re, im, omega, amp, eps, time, ramp, ramp_d, ramp_dd, x6, v6, a6)
    !! 6-DOF RAO response to a component sea. Component i has frequency omega(i),
    !! amplitude amp(i) and elevation amp(i) cos(omega(i) t - eps(i)) at the RAO origin;
    !! re/im(6, i) is its complex RAO. The response is multiplied by the start-up ramp r(t)
    !! (ramp, ramp_d, ramp_dd = r, dr/dt, d2r/dt2), and v6/a6 are the exact time
    !! derivatives of x6 = r(t) sum_i amp(i) Re[RAO_i exp(i(omega(i) t - eps(i)))].
    REAL(wp), INTENT(IN) :: re(:, :), im(:, :), omega(:), amp(:), eps(:), time, ramp, ramp_d, ramp_dd
    REAL(wp), INTENT(OUT) :: x6(6), v6(6), a6(6)
    INTEGER :: i
    REAL(wp) :: th, c, s, s6(6), sd6(6), sdd6(6)
    s6 = CD_ZERO; sd6 = CD_ZERO; sdd6 = CD_ZERO
    DO i = 1, SIZE(omega)
      th = omega(i)*time - eps(i)
      c = COS(th); s = SIN(th)
      s6 = s6 + amp(i)*(re(:, i)*c - im(:, i)*s)
      sd6 = sd6 - (amp(i)*omega(i))*(re(:, i)*s + im(:, i)*c)
      sdd6 = sdd6 - (amp(i)*omega(i)*omega(i))*(re(:, i)*c - im(:, i)*s)
    END DO
    x6 = ramp*s6
    v6 = ramp_d*s6 + ramp*sd6
    a6 = ramp_dd*s6 + 2.0_wp*ramp_d*sd6 + ramp*sdd6
  END SUBROUTINE CD_Vessel_RAO_Motion

  PURE FUNCTION cross(a, b) RESULT(c)
    REAL(wp), INTENT(IN) :: a(3), b(3)
    REAL(wp) :: c(3)
    c = [a(2)*b(3) - a(3)*b(2), a(3)*b(1) - a(1)*b(3), a(1)*b(2) - a(2)*b(1)]
  END FUNCTION cross

END MODULE CableDyn_Vessel
