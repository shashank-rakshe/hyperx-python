! File: src/CableDyn_WaveMath.f90
! SPDX-License-Identifier: Apache-2.0
! Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
MODULE CableDyn_WaveMath
  !! The sines, cosines and exponentials of the wave kinematics, evaluated in blocks, and the
  !! lanes that the sums over the components run in.
  !!
  !! An irregular sea sums, at every point and time, one phase cosine and sine and one depth
  !! exponential per component: thousands of transcendental evaluations per node and step. The
  !! intrinsic functions become one scalar library call per element where the compiler may not
  !! use its vector library (Intel ifx under /fp:precise, as every ifx build compiles), and the
  !! MinGW-w64 library of gfortran reduces large arguments in x87 precision (errors of 10^4 to
  !! 10^5 ulp at |x| ~ 10^4). Here each block is plain IEEE arithmetic that compilers vectorise
  !! under any value-safe floating-point model (a value-unsafe one may fold the rounding to an
  !! integer below; the build compiles this file value-safe with every compiler):
  !!
  !! * sine and cosine together, from ONE argument reduction (they are always needed in pairs):
  !!   theta = n pi/2 + r with n the integer nearest 2 theta/pi and
  !!   r = ((theta - n P1) - n P2) - n P3, the Cody-Waite reduction with pi/2 split in three
  !!   parts whose products with |n| < 2^20 are exact (P1 and P2 carry 33 bits); sin r and cos r
  !!   by near-minimax polynomials of degree 13 and 14 (|r| <= pi/4; the fit is within 2.1e-17
  !!   of sin r relative and 9e-19 of cos r); the quadrant n mod 4 selects and signs them;
  !! * exp(x) = 2^n exp(r) with n the integer nearest x/ln 2, r = (x - n L1) - n L2 (ln 2 in two
  !!   parts, |r| <= ln(2)/2), exp r by a near-minimax polynomial of degree 11 (within 1.7e-17
  !!   relative) and 2^n from its IEEE bits.
  !!
  !! n never leaves the floating-point registers: the rounding to an integer leaves it in the low
  !! bits of y + ROUNDER, whose bits give the quadrant and the exponent. A conversion to INTEGER
  !! keeps GNU Fortran from vectorising the loop (AVX2 has none to 64 bits), as does a MERGE on a
  !! floating-point comparison, so the signs are set on the bits too.
  !!
  !! Against quadruple precision (test_wave_math, and sweeps of 10^6 phases per decade) the
  !! results are within 3 ulp over |theta| <= 2^20 pi/2 (sine, cosine) and 2 ulp over
  !! -708 <= x <= 709 (exponential). Next to a zero of the sine or cosine, the double nearest
  !! n pi/2, the value is as small as theta's distance from the multiple (down to 6.2e-19) and the
  !! part of pi/2 below P1 + P2 + P3, 8.5e-32, adds |n| 8.5e-32 (at most 9e-26) to the error:
  !! up to 2.8e6 ulp of that tiny value, 4e-10 ulp of 1. A phase formed as k x - omega t + phi
  !! already carries a rounding error of |theta| ulp(1), far above both.
  !! Elements beyond the reduction (|theta| > 2^20 pi/2) or the normal range (x < -708,
  !! x > 709), and NaN, take the intrinsic, so a NaN argument gives NaN as the intrinsic does (the
  !! clamp to the range may turn it into a finite bound: Fortran leaves MIN and MAX of a NaN
  !! unspecified, and gfortran returns the other argument). The arrays are explicit-shape:
  !! inlined into a caller's loops, the blocks then still vectorise.
  USE CableDyn_Precision, ONLY: wp
  USE, INTRINSIC :: ISO_FORTRAN_ENV, ONLY: INT64
  IMPLICIT NONE
  PRIVATE

  PUBLIC :: CD_Wave_SinCos, CD_Wave_Exp, CD_Wave_Sum_Lanes

  ! interleaved partial sums of a wave kinematics sum: component i in lane
  ! MOD(i - 1, CD_WAVE_LANES) + 1. An element-by-element loop over the lanes vectorises under
  ! a value-safe model, where a running sum cannot, and keeps a fixed order of additions.
  INTEGER, PARAMETER, PUBLIC :: CD_WAVE_LANES = 64

  REAL(wp), PARAMETER :: TWO_OVER_PI = 0.63661977236758134308_wp
  ! pi/2 = P1 + P2 + P3 (+ 8.5e-32): P1 and P2 carry 33 significant bits (fdlibm's pio2_1, pio2_2)
  REAL(wp), PARAMETER :: P1 = 1.57079632673412561417e+00_wp
  REAL(wp), PARAMETER :: P2 = 6.07710050630396597660e-11_wp
  REAL(wp), PARAMETER :: P3 = 2.02226624871116645580e-21_wp
  REAL(wp), PARAMETER :: THETA_MAX = 1.6470993291652855e+06_wp   ! 2^20 pi/2
  REAL(wp), PARAMETER :: INV_LN2 = 1.44269504088896338700e+00_wp
  ! ln 2 = L1 + L2: L1 carries 32 significant bits (fdlibm's ln2_hi), so n L1 is exact for |n| < 2^21
  REAL(wp), PARAMETER :: L1 = 6.93147180369123816490e-01_wp
  REAL(wp), PARAMETER :: L2 = 1.90821492927058770002e-10_wp
  REAL(wp), PARAMETER :: X_LOW = -708.0_wp, X_HIGH = 709.0_wp
  ! (y + ROUNDER) - ROUNDER is y rounded to the nearest integer for |y| < 2^51, in plain IEEE
  ! arithmetic (ANINT can become a library call that blocks the vector loop)
  REAL(wp), PARAMETER :: ROUNDER = 6755399441055744.0_wp   ! 1.5 * 2^52
  ! sin r = r + r^3 S(r^2), cos r = 1 - r^2/2 + r^4 C(r^2) and exp r = 1 + r + r^2 E(r): the
  ! polynomials S, C and E, interpolated at the Chebyshev nodes of the reduced range
  REAL(wp), PARAMETER :: S0 = -0.16666666666666666_wp, S1 = 0.008333333333330901_wp, &
                         S2 = -0.00019841269836686008_wp, S3 = 2.7557316064986773e-06_wp, &
                         S4 = -2.505112403138208e-08_wp, S5 = 1.59175674789068e-10_wp
  REAL(wp), PARAMETER :: C0 = 0.041666666666666664_wp, C1 = -0.0013888888888887367_wp, &
                         C2 = 2.480158729872029e-05_wp, C3 = -2.7557317248229367e-07_wp, &
                         C4 = 2.0876141380294955e-09_wp, C5 = -1.1382280957702634e-11_wp
  REAL(wp), PARAMETER :: E0 = 0.5000000000000001_wp, E1 = 0.16666666666666669_wp, &
                         E2 = 0.04166666666662348_wp, E3 = 0.008333333333330011_wp, &
                         E4 = 0.0013888888917538296_wp, E5 = 0.00019841269863303223_wp, &
                         E6 = 2.4801520792572694e-05_wp, E7 = 2.75572680728901e-06_wp, &
                         E8 = 2.762032742826824e-07_wp, E9 = 2.5100569275813683e-08_wp
  INTEGER(INT64), PARAMETER :: SIGN_BIT = ISHFT(1_INT64, 63)

CONTAINS

  PURE SUBROUTINE CD_Wave_SinCos(n, theta, s, c)
    !! s = sin(theta), c = cos(theta) for the n elements (explicit-shape arrays, so that the
    !! loop vectorises wherever the call is inlined).
    INTEGER, INTENT(IN) :: n
    REAL(wp), INTENT(IN) :: theta(n)
    REAL(wp), INTENT(OUT) :: s(n), c(n)
    INTEGER :: i, n_far
    INTEGER(INT64) :: bits
    REAL(wp) :: th, y, fn, r, r2, r4, ps, pc, ss, cc

    DO i = 1, n
      th = MAX(-THETA_MAX, MIN(THETA_MAX, theta(i)))
      y = th*TWO_OVER_PI + ROUNDER
      fn = y - ROUNDER
      r = ((th - fn*P1) - fn*P2) - fn*P3
      r2 = r*r
      r4 = r2*r2
      ! Estrin's scheme: pairs of terms, for a shorter dependency chain than Horner's
      ps = r + (r*r2)*((S0 + r2*S1) + r4*((S2 + r2*S3) + r4*(S4 + r2*S5)))
      pc = (1.0_wp - 0.5_wp*r2) + r4*((C0 + r2*C1) + r4*((C2 + r2*C3) + r4*(C4 + r2*C5)))
      ! sin(-0) = -0: the sum above gives +0, and the sign of sin r is that of r
      ps = TRANSFER(IOR(TRANSFER(ps, 0_INT64), IAND(TRANSFER(r, 0_INT64), SIGN_BIT)), 0.0_wp)
      ! quadrant q = n mod 4: (sin, cos) = (ps, pc), (pc, -ps), (-ps, -pc), (-pc, ps)
      bits = TRANSFER(y, 0_INT64)
      ss = MERGE(pc, ps, BTEST(bits, 0))
      cc = MERGE(ps, pc, BTEST(bits, 0))
      s(i) = TRANSFER(IEOR(TRANSFER(ss, 0_INT64), IAND(ISHFT(bits, 62), SIGN_BIT)), 0.0_wp)
      c(i) = TRANSFER(IEOR(TRANSFER(cc, 0_INT64), IAND(ISHFT(bits + 1_INT64, 62), SIGN_BIT)), 0.0_wp)
    END DO
    ! beyond the reduction, or NaN (every comparison with a NaN is false)
    n_far = 0
    DO i = 1, n
      n_far = n_far + MERGE(0, 1, ABS(theta(i)) <= THETA_MAX)
    END DO
    IF (n_far == 0) RETURN
    DO i = 1, n
      IF (.NOT. (ABS(theta(i)) <= THETA_MAX)) THEN
        s(i) = SIN(theta(i))
        c(i) = COS(theta(i))
      END IF
    END DO
  END SUBROUTINE CD_Wave_SinCos

  PURE SUBROUTINE CD_Wave_Exp(n, x, e)
    !! e = exp(x) for the n elements (explicit-shape arrays, as CD_Wave_SinCos).
    INTEGER, INTENT(IN) :: n
    REAL(wp), INTENT(IN) :: x(n)
    REAL(wp), INTENT(OUT) :: e(n)
    INTEGER :: i, n_out
    REAL(wp) :: xc, y, fn, r, r2, r4, p

    DO i = 1, n
      xc = MAX(X_LOW, MIN(X_HIGH, x(i)))
      y = xc*INV_LN2 + ROUNDER
      fn = y - ROUNDER
      r = (xc - fn*L1) - fn*L2
      r2 = r*r
      r4 = r2*r2
      p = ((E0 + r*E1) + r2*(E2 + r*E3)) + r4*(((E4 + r*E5) + r2*(E6 + r*E7)) + r4*(E8 + r*E9))
      p = (1.0_wp + r) + r2*p
      ! times 2^m from its IEEE bits, m in [-1022, 1023] for the clamped argument: the low bits
      ! of y hold m, and the shift leaves its biased value in the exponent field (SCALE can
      ! become a library call per element)
      e(i) = p*TRANSFER(ISHFT(TRANSFER(y, 0_INT64) + 1023_INT64, 52), p)
    END DO
    ! outside the normal range, or NaN
    n_out = 0
    DO i = 1, n
      n_out = n_out + MERGE(0, 1, x(i) >= X_LOW .AND. x(i) <= X_HIGH)
    END DO
    IF (n_out == 0) RETURN
    DO i = 1, n
      IF (.NOT. (x(i) >= X_LOW .AND. x(i) <= X_HIGH)) e(i) = EXP(x(i))
    END DO
  END SUBROUTINE CD_Wave_Exp

  PURE FUNCTION CD_Wave_Sum_Lanes(lane, n) RESULT(total)
    !! The first n <= CD_WAVE_LANES lanes added up pairwise, in a fixed order.
    REAL(wp), INTENT(IN) :: lane(:)
    INTEGER, INTENT(IN) :: n
    REAL(wp) :: total, w(CD_WAVE_LANES)
    INTEGER :: h, j, m
    w(1:n) = lane(1:n)
    m = n
    DO WHILE (m > 1)
      h = m/2
      DO j = 1, h
        w(j) = w(j) + w(m - j + 1)
      END DO
      m = m - h
    END DO
    total = w(1)
  END FUNCTION CD_Wave_Sum_Lanes

END MODULE CableDyn_WaveMath
