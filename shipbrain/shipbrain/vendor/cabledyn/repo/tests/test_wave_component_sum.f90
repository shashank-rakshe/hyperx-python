! File: tests/test_wave_component_sum.f90
! SPDX-License-Identifier: Apache-2.0
! Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
PROGRAM test_wave_component_sum
  !! Gate for the fast sum of CD_Component_Wave_Kinematics against an independent reference, the
  !! direct sum of the same linear components in quadruple precision with the intrinsics, across
  !! wave heights (a calm sea to one near breaking in shallow water), depths (shallow, and deep
  !! enough for exp(-2 k depth) to underflow), record lengths (one component to more than the
  !! kernel's phase buffer) and points (near the surface, mid-depth, near and at the seabed, above
  !! still water, above the crest), with and without the tables and the amplitude scale:
  !!   1. elevation, velocity, acceleration and dynamic pressure within round-off of the reference:
  !!      8 ulp of the sum of the term magnitudes, plus the rounding of the double phases (root
  !!      sum of squares: they are independent) and, for the stretched depth, of the elevation;
  !!   2. the sum is a function of its arguments alone: the same call after others gives the same
  !!      bits, and so do the tables in any thread count (the sums keep a fixed order);
  !!   3. amplitude_scale equals a scaled table to round-off;
  !!   4. a short-crested table (a direction per component) equals the two long-crested tables it
  !!      is made of to round-off, for directions in every quadrant, one direction everywhere
  !!      equals the long-crested sum, and the stretched sum equals the unstretched one at the
  !!      stretched depth; half a table of cosines fails closed.
  USE, INTRINSIC :: ISO_FORTRAN_ENV, ONLY: INT64
  USE CableDyn_Precision, ONLY: wp
  USE CableDyn_Hydro, ONLY: CD_Component_Wave_Kinematics, CD_Solve_Dispersion_Wavenumber, CD_HYDRO_OK
  IMPLICIT NONE
  INTEGER, PARAMETER :: qp = SELECTED_REAL_KIND(30)
  REAL(wp), PARAMETER :: GRAV = 9.80665_wp, CUTOFF = 3.6_wp, DIRECTION = 25.0_wp
  REAL(qp), PARAMETER :: PI_Q = 3.14159265358979323846264338327950288_qp
  REAL(wp), PARAMETER :: PI = 3.141592653589793_wp
  INTEGER, PARAMETER :: NDEPTH = 4, NTABLE = 9, NHEIGHT = 3
  REAL(wp), PARAMETER :: DEPTHS(NDEPTH) = [8.0_wp, 60.0_wp, 400.0_wp, 3000.0_wp]
  ! significant heights; a sea steeper than 0.8 of the depth is left out
  REAL(wp), PARAMETER :: HEIGHTS(NHEIGHT) = [0.5_wp, 4.0_wp, 14.0_wp]
  ! component counts: below, at and above a lane block and the buffer, and 300 s to 9000 s records
  INTEGER, PARAMETER :: TABLES(NTABLE) = [1, 2, 63, 64, 65, 172, 2406, 4097, 5156]
  INTEGER :: nfail, id, ih, it
  REAL(wp) :: worst

  nfail = 0
  worst = 0.0_wp
  DO id = 1, NDEPTH
    DO ih = 1, NHEIGHT
      IF (HEIGHTS(ih) > 0.8_wp*DEPTHS(id)) CYCLE
      DO it = 1, NTABLE
        ! the longest tables at the depths that bracket the deep-water branch
        IF (TABLES(it) > 4096 .AND. (ih /= 2 .OR. (id /= 2 .AND. id /= 4))) CYCLE
        CALL check_sea(DEPTHS(id), HEIGHTS(ih), TABLES(it))
      END DO
    END DO
  END DO
  WRITE (*, '(A,F6.3)') '    largest error over its round-off bound: ', worst
  CALL check_pure()
  CALL check_short_crested()

  IF (nfail > 0) THEN
    WRITE (*, '(A,I0,A)') 'FAIL: ', nfail, ' assertion(s) failed'
    ERROR STOP 1
  END IF
  WRITE (*, '(A)') 'PASS: fast component sum against the quadruple-precision reference'

CONTAINS

  SUBROUTINE make_table(n, depth, hs, om, k, amp, ph, e2kd, tail)
    !! A record of n components up to CUTOFF: a peaked sea of significant height hs plus the
    !! leakage tail of a finite record, with spread phases.
    INTEGER, INTENT(IN) :: n
    REAL(wp), INTENT(IN) :: depth, hs
    REAL(wp), INTENT(OUT) :: om(n), k(n), amp(n), ph(n), e2kd(n), tail(3, n)
    REAL(wp) :: scale
    INTEGER :: i, es
    CHARACTER(200) :: em
    DO i = 1, n
      om(i) = CUTOFF*REAL(i, wp)/REAL(n, wp)
      amp(i) = EXP(-0.5_wp*((om(i) - 0.63_wp)/0.12_wp)**2) + 1.0e-2_wp/REAL(i, wp)
      ph(i) = MODULO(2.399963_wp*REAL(i, wp)**2, 2.0_wp*PI)
      CALL CD_Solve_Dispersion_Wavenumber(om(i), depth, GRAV, k(i), es, em)
      CALL require(es == CD_HYDRO_OK, 'dispersion solve: '//TRIM(em))
      e2kd(i) = EXP(-2.0_wp*(k(i)*depth))
    END DO
    ! hs = 4 sqrt(sum a^2/2)
    scale = hs/(4.0_wp*SQRT(0.5_wp*SUM(amp**2)))
    amp = scale*amp
    tail(:, n) = amp(n)*[om(n), om(n)**2, om(n)**2/k(n)]
    DO i = n - 1, 1, -1
      tail(:, i) = tail(:, i + 1) + amp(i)*[om(i), om(i)**2, om(i)**2/k(i)]
    END DO
  END SUBROUTINE make_table

  SUBROUTINE reference(x, y, z, t, depth, stretch, scl, om, k, amp, ph, eta, vel, acc, pdyn, tol_eta, tol_u, tol_a, &
                       tol_p, dry)
    !! The direct sum in quadruple precision, in the exponential form of the depth ratios (its
    !! range holds them at any depth here), and the round-off bounds of the double sum.
    REAL(wp), INTENT(IN) :: x, y, z, t, depth, scl, om(:), k(:), amp(:), ph(:)
    LOGICAL, INTENT(IN) :: stretch
    REAL(qp), INTENT(OUT) :: eta, vel(3), acc(3), pdyn, tol_eta, tol_u, tol_a, tol_p
    LOGICAL, INTENT(OUT) :: dry
    REAL(qp) :: cb, sb, xa, th(SIZE(om)), ci(SIZE(om)), si(SIZE(om)), a, w, ze, d, zq, e1, e2, e3, ch, sh, eps
    REAL(qp) :: mag_e, rss_e, mag(3), rss(3), grad(3), term
    INTEGER :: i

    eps = REAL(EPSILON(1.0_wp), qp)
    cb = COS(REAL(DIRECTION, qp)*PI_Q/180.0_qp)
    sb = SIN(REAL(DIRECTION, qp)*PI_Q/180.0_qp)
    xa = REAL(x, qp)*cb + REAL(y, qp)*sb
    eta = 0.0_qp
    mag_e = 0.0_qp
    rss_e = 0.0_qp
    DO i = 1, SIZE(om)
      th(i) = REAL(k(i), qp)*xa - REAL(om(i), qp)*REAL(t, qp) + REAL(ph(i), qp)
      ci(i) = COS(th(i))
      si(i) = SIN(th(i))
      a = REAL(scl, qp)*REAL(amp(i), qp)
      eta = eta + a*ci(i)
      mag_e = mag_e + a
      rss_e = rss_e + (a*(1.0_qp + ABS(th(i))))**2
    END DO
    tol_eta = 8.0_qp*eps*mag_e + 8.0_qp*eps*SQRT(rss_e)
    vel = 0.0_qp
    acc = 0.0_qp
    pdyn = 0.0_qp
    tol_u = 0.0_qp
    tol_a = 0.0_qp
    tol_p = 0.0_qp
    d = REAL(depth, qp)
    zq = REAL(z, qp)
    dry = stretch .AND. zq > eta
    IF (dry) RETURN
    ze = zq
    IF (stretch) ze = (zq - eta)*d/(d + eta)
    mag = 0.0_qp
    rss = 0.0_qp
    grad = 0.0_qp
    DO i = 1, SIZE(om)
      e1 = EXP(REAL(k(i), qp)*ze)
      e2 = EXP(-REAL(k(i), qp)*(ze + 2.0_qp*d))
      e3 = 1.0_qp - EXP(-2.0_qp*REAL(k(i), qp)*d)
      ch = (e1 + e2)/e3
      sh = (e1 - e2)/e3
      a = REAL(scl, qp)*REAL(amp(i), qp)
      w = a*REAL(om(i), qp)
      vel(1) = vel(1) + w*ch*ci(i)*cb
      vel(2) = vel(2) + w*ch*ci(i)*sb
      vel(3) = vel(3) + w*sh*si(i)
      term = w*ch
      mag(1) = mag(1) + term
      rss(1) = rss(1) + (term*(1.0_qp + ABS(th(i))))**2
      grad(1) = grad(1) + term*REAL(k(i), qp)
      w = w*REAL(om(i), qp)
      acc(1) = acc(1) + w*ch*si(i)*cb
      acc(2) = acc(2) + w*ch*si(i)*sb
      acc(3) = acc(3) - w*sh*ci(i)
      term = w*ch
      mag(2) = mag(2) + term
      rss(2) = rss(2) + (term*(1.0_qp + ABS(th(i))))**2
      grad(2) = grad(2) + term*REAL(k(i), qp)
      w = w/REAL(k(i), qp)
      pdyn = pdyn + w*ch*ci(i)
      term = w*ch
      mag(3) = mag(3) + term
      rss(3) = rss(3) + (term*(1.0_qp + ABS(th(i))))**2
      grad(3) = grad(3) + term*REAL(k(i), qp)
    END DO
    ! the double elevation moves the stretched depth by about its error, and the double exponent
    ! k z carries 1 ulp of its own: k |z| eps of each term
    tol_u = 8.0_qp*eps*(mag(1) + ABS(ze)*grad(1)) + 8.0_qp*eps*SQRT(rss(1))
    tol_a = 8.0_qp*eps*(mag(2) + ABS(ze)*grad(2)) + 8.0_qp*eps*SQRT(rss(2))
    tol_p = 8.0_qp*eps*(mag(3) + ABS(ze)*grad(3)) + 8.0_qp*eps*SQRT(rss(3))
    IF (stretch) THEN
      tol_u = tol_u + tol_eta*grad(1)
      tol_a = tol_a + tol_eta*grad(2)
      tol_p = tol_p + tol_eta*grad(3)
    END IF
  END SUBROUTINE reference

  SUBROUTINE check_sea(depth, hs, n)
    REAL(wp), INTENT(IN) :: depth, hs
    INTEGER, INTENT(IN) :: n
    INTEGER, PARAMETER :: NPOINT = 7
    REAL(wp) :: om(n), k(n), amp(n), ph(n), e2kd(n), tail(3, n)
    REAL(wp) :: zs(NPOINT), x, y, t, scl, eta, u(3), a(3), p, depth_eps
    REAL(qp) :: eta_q, u_q(3), a_q(3), p_q, tol_e, tol_u, tol_a, tol_p
    LOGICAL :: stretch(NPOINT), dry
    INTEGER :: ip, variant, es
    CHARACTER(200) :: em
    CHARACTER(120) :: label

    CALL make_table(n, depth, hs, om, k, amp, ph, e2kd, tail)
    depth_eps = 1.0e-3_wp*depth
    ! near the surface, mid-depth, deep, near the seabed, at it; above still water (stretched, so
    ! wet under a crest and dry above it), and a point above the surface that is not stretched
    zs = [-0.02_wp*depth, -0.3_wp*depth, -0.7_wp*depth, -depth + depth_eps, -depth, 0.3_wp*hs + 0.01_wp, 0.01_wp*depth]
    stretch = [.TRUE., .TRUE., .TRUE., .TRUE., .FALSE., .TRUE., .FALSE.]
    DO ip = 1, NPOINT
      x = 37.0_wp*REAL(ip, wp) - 120.0_wp
      y = 11.0_wp*REAL(ip, wp) - 30.0_wp
      t = 3600.0_wp + 173.3_wp*REAL(ip, wp)
      ! the table variants share the reference when they share the scale
      scl = MERGE(0.37_wp, 1.0_wp, MOD(ip, 2) == 0)
      CALL reference(x, y, zs(ip), t, depth, stretch(ip), scl, om, k, amp, ph, eta_q, u_q, a_q, p_q, tol_e, tol_u, &
                     tol_a, tol_p, dry)
      DO variant = 1, 3
        WRITE (label, '(A,F7.1,A,F5.1,A,I0,A,F9.3,A,I0)') 'depth ', depth, ' Hs ', hs, ' n ', n, ' z ', zs(ip), &
          ' variant ', variant
        SELECT CASE (variant)
        CASE (1)
          CALL CD_Component_Wave_Kinematics(x, y, zs(ip), t, depth, DIRECTION, stretch(ip), om, k, amp, ph, eta, u, a, &
                                            es, em, amplitude_scale=scl, pdyn=p)
        CASE (2)
          CALL CD_Component_Wave_Kinematics(x, y, zs(ip), t, depth, DIRECTION, stretch(ip), om, k, amp, ph, eta, u, a, &
                                            es, em, inputs_validated=.TRUE., amplitude_scale=scl, pdyn=p, exp_m2kd=e2kd)
        CASE (3)
          CALL CD_Component_Wave_Kinematics(x, y, zs(ip), t, depth, DIRECTION, stretch(ip), om, k, amp, ph, eta, u, a, &
                                            es, em, inputs_validated=.TRUE., amplitude_scale=scl, pdyn=p, &
                                            exp_m2kd=e2kd, tail_sums=tail)
        END SELECT
        CALL require(es == CD_HYDRO_OK, 'evaluated at '//TRIM(label)//': '//TRIM(em))
        CALL within(eta, eta_q, tol_e, 'elevation at '//TRIM(label))
        IF (dry) THEN
          CALL require(ALL(u == 0.0_wp) .AND. ALL(a == 0.0_wp) .AND. p == 0.0_wp, &
                       'dry above the crest at '//TRIM(label))
          CYCLE
        END IF
        CALL within(u(1), u_q(1), tol_u, 'velocity x at '//TRIM(label))
        CALL within(u(2), u_q(2), tol_u, 'velocity y at '//TRIM(label))
        CALL within(u(3), u_q(3), tol_u, 'velocity z at '//TRIM(label))
        CALL within(a(1), a_q(1), tol_a, 'acceleration x at '//TRIM(label))
        CALL within(a(2), a_q(2), tol_a, 'acceleration y at '//TRIM(label))
        CALL within(a(3), a_q(3), tol_a, 'acceleration z at '//TRIM(label))
        CALL within(p, p_q, tol_p, 'pressure at '//TRIM(label))
      END DO
    END DO
  END SUBROUTINE check_sea

  SUBROUTINE check_pure()
    !! Purity and thread independence over a table past the buffer, and the amplitude scale.
    INTEGER, PARAMETER :: N = 4200, NP = 64
    REAL(wp) :: om(N), k(N), amp(N), ph(N), e2kd(N), tail(3, N), amp_s(N)
    REAL(wp) :: pts(3, NP), one(7, NP), team(7, NP), eta, u(3), a(3), eta_s, u_s(3), a_s(3), tol
    INTEGER :: i, nthreads, es
    CHARACTER(200) :: em

    CALL make_table(N, 60.0_wp, 4.0_wp, om, k, amp, ph, e2kd, tail)
    DO i = 1, NP
      pts(:, i) = [3.1_wp*REAL(i, wp), -1.7_wp*REAL(i, wp), -0.9_wp*REAL(i, wp) - 0.2_wp]
    END DO
    DO i = 1, NP
      CALL sample(pts(:, i), 1234.5_wp, om, k, amp, ph, e2kd, tail, one(:, i))
    END DO
    ! the same call after others, and on a team of threads, gives the same bits
    DO nthreads = 1, 4
      team = 0.0_wp
      !$OMP PARALLEL DO NUM_THREADS(nthreads) DEFAULT(SHARED) PRIVATE(i) SCHEDULE(dynamic)
      DO i = NP, 1, -1
        CALL sample(pts(:, i), 1234.5_wp, om, k, amp, ph, e2kd, tail, team(:, i))
      END DO
      !$OMP END PARALLEL DO
      CALL require(ALL(TRANSFER(team, [0_INT64]) == TRANSFER(one, [0_INT64])), 'the sum depends on its arguments alone')
    END DO
    ! amplitude_scale against a scaled table
    amp_s = 0.37_wp*amp
    CALL CD_Component_Wave_Kinematics(5.0_wp, 2.0_wp, -3.0_wp, 700.0_wp, 60.0_wp, DIRECTION, .TRUE., om, k, amp, ph, &
                                      eta, u, a, es, em, amplitude_scale=0.37_wp)
    CALL require(es == CD_HYDRO_OK, 'scaled sum: '//TRIM(em))
    CALL CD_Component_Wave_Kinematics(5.0_wp, 2.0_wp, -3.0_wp, 700.0_wp, 60.0_wp, DIRECTION, .TRUE., om, k, amp_s, ph, &
                                      eta_s, u_s, a_s, es, em)
    CALL require(es == CD_HYDRO_OK, 'scaled table: '//TRIM(em))
    tol = 16.0_wp*EPSILON(1.0_wp)*SUM(amp_s*om*om)
    CALL require(ABS(eta - eta_s) <= tol .AND. MAXVAL(ABS(u - u_s)) <= tol .AND. MAXVAL(ABS(a - a_s)) <= tol, &
                 'amplitude_scale equals a scaled table to round-off')
  END SUBROUTINE check_pure

  SUBROUTINE check_short_crested()
    !! A table past the phase buffer in which every other component goes in direction a or b.
    INTEGER, PARAMETER :: N = 4200, NH = N/2, NPAIR = 5
    REAL(wp), PARAMETER :: PAIRS(2, NPAIR) = RESHAPE([0.0_wp, 90.0_wp, 37.5_wp, 127.0_wp, 200.0_wp, 311.3_wp, &
                                                      -45.0_wp, 233.3_wp, 180.0_wp, 271.0_wp], [2, NPAIR])
    REAL(wp), PARAMETER :: X = 41.0_wp, Y = -17.5_wp, T = 1234.5_wp, D = 60.0_wp
    REAL(wp) :: om(N), k(N), amp(N), ph(N), e2kd(N), tail(3, N), cb(N), sb(N), half(4, NH, 2)
    REAL(wp) :: e0, u0(3), a0(3), p0, e1, u1(3), a1(3), p1, e2, u2(3), a2(3), p2, tol, ze
    REAL(wp), PARAMETER :: ZS(3) = [-0.8_wp, -7.0_wp, -33.0_wp]
    INTEGER :: ip, iz, es
    CHARACTER(200) :: em

    CALL make_table(N, D, 4.0_wp, om, k, amp, ph, e2kd, tail)
    tol = 32.0_wp*EPSILON(1.0_wp)*SUM(amp*MAX(1.0_wp, om*om, om*om/k))
    DO iz = 1, 2
      half(1, :, iz) = om(iz:N:2)
      half(2, :, iz) = k(iz:N:2)
      half(3, :, iz) = amp(iz:N:2)
      half(4, :, iz) = ph(iz:N:2)
    END DO
    DO ip = 1, NPAIR
      cb(1:N:2) = COS(PAIRS(1, ip)*PI/180.0_wp)
      sb(1:N:2) = SIN(PAIRS(1, ip)*PI/180.0_wp)
      cb(2:N:2) = COS(PAIRS(2, ip)*PI/180.0_wp)
      sb(2:N:2) = SIN(PAIRS(2, ip)*PI/180.0_wp)
      DO iz = 1, SIZE(ZS)
        CALL CD_Component_Wave_Kinematics(X, Y, ZS(iz), T, D, 0.0_wp, .FALSE., om, k, amp, ph, e0, u0, a0, es, em, &
                                          pdyn=p0, exp_m2kd=e2kd, tail_sums=tail, comp_cos=cb, comp_sin=sb)
        CALL require(es == CD_HYDRO_OK, 'short-crested sum: '//TRIM(em))
        CALL long_crested(X, Y, ZS(iz), T, D, PAIRS(1, ip), half(:, :, 1), e1, u1, a1, p1, es, em)
        CALL require(es == CD_HYDRO_OK, 'first long-crested half: '//TRIM(em))
        CALL long_crested(X, Y, ZS(iz), T, D, PAIRS(2, ip), half(:, :, 2), e2, u2, a2, p2, es, em)
        CALL require(es == CD_HYDRO_OK, 'second long-crested half: '//TRIM(em))
        CALL require(ABS(e0 - e1 - e2) <= tol .AND. MAXVAL(ABS(u0 - u1 - u2)) <= tol .AND. &
                     MAXVAL(ABS(a0 - a1 - a2)) <= tol .AND. ABS(p0 - p1 - p2) <= tol, &
                     'a short-crested table is the sum of its long-crested halves')
        ! stretched: the sum at the stretched depth of the one total elevation
        CALL CD_Component_Wave_Kinematics(X, Y, ZS(iz), T, D, 0.0_wp, .TRUE., om, k, amp, ph, e1, u1, a1, es, em, &
                                          exp_m2kd=e2kd, tail_sums=tail, comp_cos=cb, comp_sin=sb)
        CALL require(es == CD_HYDRO_OK, 'stretched short-crested sum: '//TRIM(em))
        IF (ZS(iz) > e1) CYCLE   ! above this trough the point is dry
        ze = (ZS(iz) - e1)*D/(D + e1)
        CALL CD_Component_Wave_Kinematics(X, Y, ze, T, D, 0.0_wp, .FALSE., om, k, amp, ph, e2, u2, a2, es, em, &
                                          exp_m2kd=e2kd, comp_cos=cb, comp_sin=sb)
        CALL require(es == CD_HYDRO_OK, 'at the stretched depth: '//TRIM(em))
        CALL require(MAXVAL(ABS(u1 - u2)) <= tol .AND. MAXVAL(ABS(a1 - a2)) <= tol, &
                     'stretched short-crested sum at the depth of the total elevation')
      END DO
      ! one direction everywhere
      cb = COS(PAIRS(2, ip)*PI/180.0_wp)
      sb = SIN(PAIRS(2, ip)*PI/180.0_wp)
      CALL CD_Component_Wave_Kinematics(X, Y, -4.0_wp, T, D, 0.0_wp, .TRUE., om, k, amp, ph, e1, u1, a1, es, em, &
                                        comp_cos=cb, comp_sin=sb)
      CALL CD_Component_Wave_Kinematics(X, Y, -4.0_wp, T, D, PAIRS(2, ip), .TRUE., om, k, amp, ph, e2, u2, a2, es, em)
      CALL require(ABS(e1 - e2) <= tol .AND. MAXVAL(ABS(u1 - u2)) <= tol .AND. MAXVAL(ABS(a1 - a2)) <= tol, &
                   'one direction per component equals the long-crested sum')
    END DO
    CALL CD_Component_Wave_Kinematics(X, Y, -4.0_wp, T, D, 0.0_wp, .TRUE., om, k, amp, ph, e1, u1, a1, es, em, &
                                      comp_cos=cb)
    CALL require(es /= CD_HYDRO_OK, 'comp_cos without comp_sin fails closed')
    CALL CD_Component_Wave_Kinematics(X, Y, -4.0_wp, T, D, 0.0_wp, .TRUE., om, k, amp, ph, e1, u1, a1, es, em, &
                                      comp_cos=cb(1:NH), comp_sin=sb(1:NH))
    CALL require(es /= CD_HYDRO_OK, 'direction tables of the wrong length fail closed')
  END SUBROUTINE check_short_crested

  SUBROUTINE long_crested(x, y, z, t, depth, direction, table, eta, u, a, p, es, em)
    !! The unstretched sum of the table rows omega, k, amplitude and phase along one direction.
    REAL(wp), INTENT(IN) :: x, y, z, t, depth, direction, table(:, :)
    REAL(wp), INTENT(OUT) :: eta, u(3), a(3), p
    INTEGER, INTENT(OUT) :: es
    CHARACTER(*), INTENT(OUT) :: em
    REAL(wp) :: om(SIZE(table, 2)), k(SIZE(table, 2)), amp(SIZE(table, 2)), ph(SIZE(table, 2))
    om = table(1, :)
    k = table(2, :)
    amp = table(3, :)
    ph = table(4, :)
    CALL CD_Component_Wave_Kinematics(x, y, z, t, depth, direction, .FALSE., om, k, amp, ph, eta, u, a, es, em, pdyn=p)
  END SUBROUTINE long_crested

  SUBROUTINE sample(p, t, om, k, amp, ph, e2kd, tail, out)
    REAL(wp), INTENT(IN) :: p(3), t, om(:), k(:), amp(:), ph(:), e2kd(:), tail(:, :)
    REAL(wp), INTENT(OUT) :: out(7)
    REAL(wp) :: e, v(3), w(3)
    INTEGER :: st
    CHARACTER(200) :: msg
    CALL CD_Component_Wave_Kinematics(p(1), p(2), p(3), t, 60.0_wp, DIRECTION, .TRUE., om, k, amp, ph, e, v, w, st, &
                                      msg, inputs_validated=.TRUE., exp_m2kd=e2kd, tail_sums=tail)
    out = [e, v, w]
  END SUBROUTINE sample

  SUBROUTINE within(value, exact, tol, what)
    REAL(wp), INTENT(IN) :: value
    REAL(qp), INTENT(IN) :: exact, tol
    CHARACTER(*), INTENT(IN) :: what
    REAL(wp) :: ratio
    ! a sum below the double range underflows: the bound keeps a floor of the smallest normal
    ratio = REAL(ABS(REAL(value, qp) - exact)/(tol + REAL(TINY(1.0_wp), qp)), wp)
    worst = MAX(worst, ratio)
    CALL require(ratio <= 1.0_wp .AND. ratio == ratio, what)
  END SUBROUTINE within

  SUBROUTINE require(condition, what)
    LOGICAL, INTENT(IN) :: condition
    CHARACTER(*), INTENT(IN) :: what
    IF (.NOT. condition) THEN
      nfail = nfail + 1
      IF (nfail <= 40) WRITE (*, '(A)') '  FAILED: '//what
    END IF
  END SUBROUTINE require

END PROGRAM test_wave_component_sum
