! File: src/CableDyn_StreamWave.f90
! SPDX-License-Identifier: Apache-2.0
! Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
MODULE CableDyn_StreamWave
  !! Regular nonlinear waves by the stream-function (Fourier) method of Rienecker and Fenton
  !! (Dean's stream-function theory solved numerically). In the frame moving with the wave
  !! celerity c, with Y measured up from the bed (depth d) and X = x - c t,
  !!   psi(X, Y) = -U Y + sum_{j=1..N} B_j sinh(j k Y)/cosh(j k d) cos(j k X),
  !! and the unknowns k, the surface elevations eta_m at X_m = m pi/(N k) (m = 0 crest ..
  !! N trough), B_1..B_N, U, Q and R satisfy on the surface
  !!   psi(X_m, d + eta_m) = -Q          (kinematic condition, N + 1 equations)
  !!   |grad psi|^2/2 + g eta_m = R      (dynamic condition, N + 1 equations)
  !! with a zero mean level, eta_0 - eta_N = H, and k U T = 2 pi (zero Eulerian mean current,
  !! Stokes' first definition of the celerity, c = U). The system is solved by Newton's method
  !! in units of d and g, stepping the height up from a linear wave. Fixed-frame kinematics:
  !!   u = sum j k B_j cosh(j k Y)/cosh(j k d) cos(j k X),  w = sum j k B_j sinh(...)/cosh(...) sin(j k X),
  !! local accelerations du/dt = -c du/dX, dw/dt = -c dw/dX, the surface elevation from the
  !! cosine series of the eta_m, and the dynamic pressure per unit density
  !! p/rho + g z = R - |grad psi|^2/2 (z from the mean level). The field is exact up to the
  !! free surface, so no stretching applies; points above the surface see zero kinematics.
  USE CableDyn_Precision, ONLY: wp, CD_ZERO, CD_ONE, CD_Is_Finite
  USE CableDyn_Hydro, ONLY: CD_Solve_Dispersion_Wavenumber, CD_HYDRO_OK
  IMPLICIT NONE
  PRIVATE

  INTEGER, PARAMETER, PUBLIC :: CD_STREAM_OK = 0, CD_STREAM_BADINPUT = 1, CD_STREAM_NOCONVERGE = 2
  INTEGER, PARAMETER, PUBLIC :: CD_STREAM_DEFAULT_ORDER = 20, CD_STREAM_MAX_ORDER = 60
  REAL(wp), PARAMETER :: PI = 3.141592653589793238462643383279502884197_wp
  REAL(wp), PARAMETER :: DEG2RAD = PI/180.0_wp

  TYPE, PUBLIC :: CD_StreamWaveType
    LOGICAL :: ready = .FALSE.
    INTEGER :: n = 0
    REAL(wp) :: height = CD_ZERO, period = CD_ZERO, depth = CD_ZERO, gravity = CD_ZERO
    REAL(wp) :: direction = CD_ZERO, cosb = CD_ONE, sinb = CD_ZERO
    ! dimensional solution: wavenumber, celerity (= U), Bernoulli constant R, Q
    REAL(wp) :: k = CD_ZERO, c = CD_ZERO, r = CD_ZERO, q = CD_ZERO
    REAL(wp), ALLOCATABLE :: b(:)        ! B_1..B_N [m^2/s]
    REAL(wp), ALLOCATABLE :: e(:)        ! surface cosine coefficients E_0..E_N [m]
    REAL(wp), ALLOCATABLE :: eta_nodes(:) ! eta_0..eta_N [m]
  END TYPE CD_StreamWaveType

  PUBLIC :: CD_Stream_Solve, CD_Stream_Kinematics, CD_Stream_Elevation

CONTAINS

  SUBROUTINE CD_Stream_Solve(wave, height, period, depth, gravity, direction_deg, order, ErrStat, ErrMsg)
    !! Solve the stream-function wave of height H and period T in depth d with `order`
    !! Fourier terms (0 selects CD_STREAM_DEFAULT_ORDER).
    TYPE(CD_StreamWaveType), INTENT(INOUT) :: wave
    REAL(wp), INTENT(IN) :: height, period, depth, gravity, direction_deg
    INTEGER, INTENT(IN) :: order
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    INTEGER :: n, nu, nsteps, istep, it, j, m
    REAL(wp), ALLOCATABLE :: z(:), zprev(:), zprev2(:), res(:), jac(:, :), dz(:), zt(:), rt(:)
    REAL(wp) :: hs, ts, k0, omega, h_step, rnorm, a, h, ch
    LOGICAL :: ok
    CHARACTER(1024) :: em

    ErrStat = CD_STREAM_OK
    ErrMsg = ''
    wave%ready = .FALSE.
    IF (.NOT. (CD_Is_Finite(height) .AND. height > CD_ZERO .AND. CD_Is_Finite(period) .AND. period > CD_ZERO .AND. &
               CD_Is_Finite(depth) .AND. depth > CD_ZERO .AND. CD_Is_Finite(gravity) .AND. gravity > CD_ZERO .AND. &
               CD_Is_Finite(direction_deg))) THEN
      CALL fail('stream wave needs finite positive height, period, depth and gravity and a finite direction')
      RETURN
    END IF
    n = order
    IF (n == 0) n = CD_STREAM_DEFAULT_ORDER
    IF (n < 2 .OR. n > CD_STREAM_MAX_ORDER) THEN
      CALL fail('StreamOrder must be 0 (default) or in [2, 60]')
      RETURN
    END IF
    ! units of depth and gravity
    hs = height/depth
    ts = period*SQRT(gravity/depth)
    omega = 2.0_wp*PI/ts
    CALL CD_Solve_Dispersion_Wavenumber(omega, CD_ONE, CD_ONE, k0, ErrStat, em)
    IF (ErrStat /= CD_HYDRO_OK) THEN
      CALL fail('linear dispersion: '//TRIM(em))
      RETURN
    END IF
    ! a wave higher than ~0.78 d (solitary limit) or steeper than 0.142 L breaks
    IF (hs > 0.8_wp .OR. hs*k0/(2.0_wp*PI) > 0.142_wp) THEN
      CALL fail('the stream-function wave is beyond the breaking limit (H/d > 0.8 or H/L > 0.142)')
      RETURN
    END IF
    nu = 2*n + 5
    ALLOCATE (z(nu), zprev(nu), zprev2(nu), res(nu), jac(nu, nu), dz(nu), zt(nu), rt(nu))
    ! height stepping from a linear wave
    nsteps = MAX(4, CEILING(40.0_wp*hs*k0/(2.0_wp*PI)/0.1_wp))
    nsteps = MIN(nsteps, 40)
    DO istep = 1, nsteps
      h_step = hs*REAL(istep, wp)/REAL(nsteps, wp)
      IF (istep == 1) THEN
        a = 0.5_wp*h_step
        z = CD_ZERO
        z(1) = k0
        DO m = 0, n
          z(2 + m) = a*COS(REAL(m, wp)*PI/REAL(n, wp))
        END DO
        z(n + 3) = a*(omega/k0)/TANH(k0)
        z(2*n + 3) = omega/k0
        z(2*n + 4) = z(2*n + 3)
        z(2*n + 5) = 0.5_wp*z(2*n + 3)**2
      ELSE IF (istep == 2) THEN
        ! the wave-amplitude unknowns scale with the height; k, U, Q, R stay
        z = zprev
        z(2:2*n + 2) = 2.0_wp*zprev(2:2*n + 2)
      ELSE
        z = 2.0_wp*zprev - zprev2
      END IF
      ok = .FALSE.
      DO it = 1, 60
        CALL residual(z, n, h_step, ts, res)
        rnorm = MAXVAL(ABS(res))
        IF (.NOT. CD_Is_Finite(rnorm)) EXIT
        IF (rnorm < 1.0e-12_wp) THEN
          ok = .TRUE.
          EXIT
        END IF
        ! forward-difference Jacobian
        DO j = 1, nu
          zt = z
          h = 1.0e-7_wp*MAX(1.0e-3_wp, ABS(z(j)))
          zt(j) = zt(j) + h
          CALL residual(zt, n, h_step, ts, rt)
          jac(:, j) = (rt - res)/h
        END DO
        dz = -res
        CALL gauss_solve(jac, dz, ok)
        IF (.NOT. ok) EXIT
        ok = .FALSE.
        ! damped update: halve until the residual decreases
        ch = CD_ONE
        DO j = 1, 20
          zt = z + ch*dz
          CALL residual(zt, n, h_step, ts, rt)
          IF (CD_Is_Finite(MAXVAL(ABS(rt))) .AND. MAXVAL(ABS(rt)) < rnorm) EXIT
          ch = 0.5_wp*ch
        END DO
        z = zt
      END DO
      IF (.NOT. ok) THEN
        ErrStat = CD_STREAM_NOCONVERGE
        ErrMsg = 'CableDyn_StreamWave: the stream-function wave did not converge; the wave may be too '// &
                 'steep for the order, or beyond breaking'
        RETURN
      END IF
      IF (z(1) <= CD_ZERO) THEN
        ErrStat = CD_STREAM_NOCONVERGE
        ErrMsg = 'CableDyn_StreamWave: the stream-function solution has a non-positive wavenumber'
        RETURN
      END IF
      zprev2 = zprev
      zprev = z
    END DO
    ! dimensional solution
    wave%n = n
    wave%height = height
    wave%period = period
    wave%depth = depth
    wave%gravity = gravity
    wave%direction = direction_deg
    wave%cosb = COS(direction_deg*DEG2RAD)
    wave%sinb = SIN(direction_deg*DEG2RAD)
    wave%k = z(1)/depth
    wave%c = z(2*n + 3)*SQRT(gravity*depth)
    wave%q = z(2*n + 4)*depth*SQRT(gravity*depth)
    wave%r = z(2*n + 5)*gravity*depth
    IF (ALLOCATED(wave%b)) DEALLOCATE (wave%b, wave%e, wave%eta_nodes)
    ALLOCATE (wave%b(n), wave%e(0:n), wave%eta_nodes(0:n))
    wave%b = z(n + 3:2*n + 2)*depth*SQRT(gravity*depth)
    wave%eta_nodes = z(2:n + 2)*depth
    DO j = 0, n
      wave%e(j) = CD_ZERO
      DO m = 0, n
        wave%e(j) = wave%e(j) + MERGE(0.5_wp, CD_ONE, m == 0 .OR. m == n)*wave%eta_nodes(m)* &
                    COS(REAL(j*m, wp)*PI/REAL(n, wp))
      END DO
      wave%e(j) = wave%e(j)*MERGE(CD_ONE, 2.0_wp, j == 0 .OR. j == n)/REAL(n, wp)
    END DO
    wave%ready = .TRUE.

  CONTAINS

    SUBROUTINE fail(msg)
      CHARACTER(*), INTENT(IN) :: msg
      ErrStat = CD_STREAM_BADINPUT
      ErrMsg = 'CableDyn_StreamWave: '//msg
    END SUBROUTINE fail
  END SUBROUTINE CD_Stream_Solve

  PURE SUBROUTINE ratios(jk, y, d, ch, sh)
    !! cosh(jk y)/cosh(jk d) and sinh(jk y)/cosh(jk d) without overflow (y <= ~2 d).
    REAL(wp), INTENT(IN) :: jk, y, d
    REAL(wp), INTENT(OUT) :: ch, sh
    REAL(wp) :: e1, e2, den
    e1 = EXP(jk*(y - d))
    e2 = EXP(-jk*(y + d))
    den = CD_ONE + EXP(-2.0_wp*jk*d)
    ch = (e1 + e2)/den
    sh = (e1 - e2)/den
  END SUBROUTINE ratios

  PURE SUBROUTINE residual(z, n, hs, ts, res)
    !! Rienecker-Fenton equations in units of d and g (see the module header).
    REAL(wp), INTENT(IN) :: z(:), hs, ts
    INTEGER, INTENT(IN) :: n
    REAL(wp), INTENT(OUT) :: res(:)
    INTEGER :: m, j
    REAL(wp) :: k, u, q, r, eta, y, psi, uu, ww, ch, sh, jk, cs, sn, mean

    k = z(1)
    u = z(2*n + 3)
    q = z(2*n + 4)
    r = z(2*n + 5)
    DO m = 0, n
      ! collocation at X_m = m pi/(n k): the angle j k X_m is j m pi/n
      eta = z(2 + m)
      y = CD_ONE + eta
      psi = -u*y
      uu = -u
      ww = CD_ZERO
      DO j = 1, n
        jk = REAL(j, wp)*k
        CALL ratios(jk, y, CD_ONE, ch, sh)
        cs = COS(REAL(j*m, wp)*PI/REAL(n, wp))
        sn = SIN(REAL(j*m, wp)*PI/REAL(n, wp))
        psi = psi + z(n + 2 + j)*sh*cs
        uu = uu + jk*z(n + 2 + j)*ch*cs
        ww = ww + jk*z(n + 2 + j)*sh*sn
      END DO
      res(1 + m) = psi + q
      res(n + 2 + m) = 0.5_wp*(uu*uu + ww*ww) + eta - r
    END DO
    mean = 0.5_wp*(z(2) + z(n + 2))
    DO m = 1, n - 1
      mean = mean + z(2 + m)
    END DO
    res(2*n + 3) = mean/REAL(n, wp)
    res(2*n + 4) = z(2) - z(n + 2) - hs
    res(2*n + 5) = k*u*ts - 2.0_wp*PI
  END SUBROUTINE residual

  SUBROUTINE gauss_solve(a, b, ok)
    !! Solve a x = b by Gaussian elimination with partial pivoting (b overwritten by x).
    REAL(wp), INTENT(INOUT) :: a(:, :), b(:)
    LOGICAL, INTENT(OUT) :: ok
    INTEGER :: n, i, j, p
    REAL(wp) :: f, tmp(SIZE(b))
    n = SIZE(b)
    ok = .FALSE.
    DO i = 1, n
      p = i - 1 + MAXLOC(ABS(a(i:n, i)), 1)
      IF (.NOT. (ABS(a(p, i)) > CD_ZERO)) RETURN
      IF (p /= i) THEN
        tmp = a(i, :)
        a(i, :) = a(p, :)
        a(p, :) = tmp
        f = b(i)
        b(i) = b(p)
        b(p) = f
      END IF
      DO j = i + 1, n
        f = a(j, i)/a(i, i)
        a(j, i:n) = a(j, i:n) - f*a(i, i:n)
        b(j) = b(j) - f*b(i)
      END DO
    END DO
    DO i = n, 1, -1
      b(i) = (b(i) - DOT_PRODUCT(a(i, i + 1:n), b(i + 1:n)))/a(i, i)
    END DO
    ok = ALL(CD_Is_Finite(b))
  END SUBROUTINE gauss_solve

  PURE REAL(wp) FUNCTION CD_Stream_Elevation(wave, xw) RESULT(eta)
    !! Surface elevation [m] at the moving-frame abscissa xw = x_along - c t.
    TYPE(CD_StreamWaveType), INTENT(IN) :: wave
    REAL(wp), INTENT(IN) :: xw
    INTEGER :: j
    eta = CD_ZERO
    DO j = 0, wave%n
      eta = eta + wave%e(j)*COS(REAL(j, wp)*wave%k*xw)
    END DO
  END FUNCTION CD_Stream_Elevation

  SUBROUTINE CD_Stream_Kinematics(wave, x, y, z, t, scale, eta, velocity, acceleration, ErrStat, ErrMsg, pdyn)
    !! Fixed-frame kinematics of the stream-function wave at (x, y, z, t), z from the mean
    !! level; scale multiplies every output (the start-up ramp) and the surface against which
    !! the point is tested. Points above the (scaled) surface get zero kinematics.
    TYPE(CD_StreamWaveType), INTENT(IN) :: wave
    REAL(wp), INTENT(IN) :: x, y, z, t, scale
    REAL(wp), INTENT(OUT) :: eta, velocity(3), acceleration(3)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    REAL(wp), INTENT(OUT), OPTIONAL :: pdyn
    INTEGER :: j
    REAL(wp) :: xw, yb, uh, w, du, dw, jk, ch, sh, cs, sn, um

    eta = CD_ZERO
    velocity = CD_ZERO
    acceleration = CD_ZERO
    IF (PRESENT(pdyn)) pdyn = CD_ZERO
    ErrStat = CD_STREAM_OK
    ErrMsg = ''
    IF (.NOT. wave%ready) THEN
      ErrStat = CD_STREAM_BADINPUT
      ErrMsg = 'CableDyn_StreamWave: kinematics requested before the wave was solved'
      RETURN
    END IF
    xw = x*wave%cosb + y*wave%sinb - wave%c*t
    eta = scale*CD_Stream_Elevation(wave, xw)
    IF (z > eta) RETURN
    yb = MAX(z, -wave%depth) + wave%depth
    uh = CD_ZERO
    w = CD_ZERO
    du = CD_ZERO
    dw = CD_ZERO
    DO j = 1, wave%n
      jk = REAL(j, wp)*wave%k
      CALL ratios(jk, yb, wave%depth, ch, sh)
      cs = COS(jk*xw)
      sn = SIN(jk*xw)
      uh = uh + jk*wave%b(j)*ch*cs
      w = w + jk*wave%b(j)*sh*sn
      du = du + jk*jk*wave%b(j)*ch*sn
      dw = dw - jk*jk*wave%b(j)*sh*cs
    END DO
    velocity = scale*[uh*wave%cosb, uh*wave%sinb, w]
    acceleration = scale*wave%c*[du*wave%cosb, du*wave%sinb, dw]
    IF (PRESENT(pdyn)) THEN
      um = uh - wave%c
      pdyn = scale*(wave%r - 0.5_wp*(um*um + w*w))
    END IF
  END SUBROUTINE CD_Stream_Kinematics

END MODULE CableDyn_StreamWave
