! File: src/CableDyn_AD.f90
! SPDX-License-Identifier: Apache-2.0
! Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
MODULE CableDyn_AD
  !! Forward-mode second-order automatic differentiation (a "hyperdual" scalar)
  !! over the 12 element DOFs, used by the secondary Cosserat path and the test suite
  !! to obtain the Cosserat element's internal force fint = dU/dq and tangent
  !! Kt = d^2 U/dq^2 from the
  !! strain energy U(q) by exact forward-mode differentiation (no finite
  !! differences), so the finite-EI element tangent is consistent with its
  !! internal force to round-off.
  !!
  !! A Dual1 scalar carries (value, grad(NV)) for force-only residual work. A
  !! Dual2 scalar carries (value, grad(NV), hess(NV, NV)) for tangent work. Seeding
  !! variable i with grad = e_i makes every derived energy's grad its internal
  !! force; Dual2 also carries the consistent tangent. The chain rule for the
  !! operations the strain energy needs (+, -, *, /, sqrt, sin, cos, atan2, acos) is
  !! implemented exactly; matrix/vector algebra is built from these scalar
  !! operators.
  !!
  !! The closed-form Cosserat element keeps this engine as its reference derivative in
  !! the tests.
  USE CableDyn_Precision, ONLY: wp
  IMPLICIT NONE
  PRIVATE

  INTEGER, PARAMETER, PUBLIC :: AD_NV = 12        !! element DOF count (seed dimension)

  TYPE, PUBLIC :: Dual1
    REAL(wp) :: v = 0.0_wp                         !! value
    REAL(wp) :: g(AD_NV) = 0.0_wp                  !! gradient d/dq
  END TYPE Dual1

  TYPE, PUBLIC :: Dual2
    REAL(wp) :: v = 0.0_wp                         !! value
    REAL(wp) :: g(AD_NV) = 0.0_wp                  !! gradient d/dq
    REAL(wp) :: h(AD_NV, AD_NV) = 0.0_wp           !! Hessian d^2/dq^2
  END TYPE Dual2

  PUBLIC :: AD1_Const, AD1_Var, AD1_Sqrt, AD1_Sin, AD1_Cos, AD1_Atan2
  PUBLIC :: AD_Const, AD_Var, OPERATOR(+), OPERATOR(-), OPERATOR(*), OPERATOR(/)
  PUBLIC :: AD_Sqrt, AD_Sin, AD_Cos, AD_Acos, AD_Atan2

  INTERFACE OPERATOR(+)
    MODULE PROCEDURE ad1_add, ad1_add_rd, ad1_add_dr, ad_add, ad_add_rd, ad_add_dr
  END INTERFACE
  INTERFACE OPERATOR(-)
    MODULE PROCEDURE ad1_sub, ad1_sub_rd, ad1_sub_dr, ad1_neg, ad_sub, ad_sub_rd, ad_sub_dr, ad_neg
  END INTERFACE
  INTERFACE OPERATOR(*)
    MODULE PROCEDURE ad1_mul, ad1_mul_rd, ad1_mul_dr, ad_mul, ad_mul_rd, ad_mul_dr
  END INTERFACE
  INTERFACE OPERATOR(/)
    MODULE PROCEDURE ad1_div, ad1_div_dr, ad1_div_rd, ad_div, ad_div_dr, ad_div_rd
  END INTERFACE

CONTAINS

  PURE FUNCTION AD1_Const(value) RESULT(d)
    !! A first-order constant: value with zero derivative.
    REAL(wp), INTENT(IN) :: value
    TYPE(Dual1) :: d
    d%v = value
    d%g = 0.0_wp
  END FUNCTION AD1_Const

  PURE FUNCTION AD1_Var(value, i) RESULT(d)
    !! First-order independent variable i: value seeded with grad = e_i.
    REAL(wp), INTENT(IN) :: value
    INTEGER, INTENT(IN) :: i
    TYPE(Dual1) :: d
    d%v = value
    d%g = 0.0_wp
    d%g(i) = 1.0_wp
  END FUNCTION AD1_Var

  PURE FUNCTION ad1_add(a, b) RESULT(c)
    TYPE(Dual1), INTENT(IN) :: a, b
    TYPE(Dual1) :: c
    c%v = a%v + b%v
    c%g = a%g + b%g
  END FUNCTION ad1_add

  PURE FUNCTION ad1_add_rd(r, a) RESULT(c)
    REAL(wp), INTENT(IN) :: r
    TYPE(Dual1), INTENT(IN) :: a
    TYPE(Dual1) :: c
    c = a
    c%v = a%v + r
  END FUNCTION ad1_add_rd

  PURE FUNCTION ad1_add_dr(a, r) RESULT(c)
    TYPE(Dual1), INTENT(IN) :: a
    REAL(wp), INTENT(IN) :: r
    TYPE(Dual1) :: c
    c = a
    c%v = a%v + r
  END FUNCTION ad1_add_dr

  PURE FUNCTION ad1_sub(a, b) RESULT(c)
    TYPE(Dual1), INTENT(IN) :: a, b
    TYPE(Dual1) :: c
    c%v = a%v - b%v
    c%g = a%g - b%g
  END FUNCTION ad1_sub

  PURE FUNCTION ad1_sub_dr(a, r) RESULT(c)
    TYPE(Dual1), INTENT(IN) :: a
    REAL(wp), INTENT(IN) :: r
    TYPE(Dual1) :: c
    c = a
    c%v = a%v - r
  END FUNCTION ad1_sub_dr

  PURE FUNCTION ad1_sub_rd(r, a) RESULT(c)
    REAL(wp), INTENT(IN) :: r
    TYPE(Dual1), INTENT(IN) :: a
    TYPE(Dual1) :: c
    c%v = r - a%v
    c%g = -a%g
  END FUNCTION ad1_sub_rd

  PURE FUNCTION ad1_neg(a) RESULT(c)
    TYPE(Dual1), INTENT(IN) :: a
    TYPE(Dual1) :: c
    c%v = -a%v
    c%g = -a%g
  END FUNCTION ad1_neg

  PURE FUNCTION ad1_mul(a, b) RESULT(c)
    TYPE(Dual1), INTENT(IN) :: a, b
    TYPE(Dual1) :: c
    c%v = a%v*b%v
    c%g = a%v*b%g + b%v*a%g
  END FUNCTION ad1_mul

  PURE FUNCTION ad1_mul_rd(r, a) RESULT(c)
    REAL(wp), INTENT(IN) :: r
    TYPE(Dual1), INTENT(IN) :: a
    TYPE(Dual1) :: c
    c%v = r*a%v
    c%g = r*a%g
  END FUNCTION ad1_mul_rd

  PURE FUNCTION ad1_mul_dr(a, r) RESULT(c)
    TYPE(Dual1), INTENT(IN) :: a
    REAL(wp), INTENT(IN) :: r
    TYPE(Dual1) :: c
    c = ad1_mul_rd(r, a)
  END FUNCTION ad1_mul_dr

  PURE FUNCTION ad1_recip(a) RESULT(c)
    TYPE(Dual1), INTENT(IN) :: a
    TYPE(Dual1) :: c
    REAL(wp) :: f, df
    f = 1.0_wp/a%v
    df = -f*f
    c = unary1(a, f, df)
  END FUNCTION ad1_recip

  PURE FUNCTION ad1_div(a, b) RESULT(c)
    TYPE(Dual1), INTENT(IN) :: a, b
    TYPE(Dual1) :: c
    c = ad1_mul(a, ad1_recip(b))
  END FUNCTION ad1_div

  PURE FUNCTION ad1_div_dr(a, r) RESULT(c)
    TYPE(Dual1), INTENT(IN) :: a
    REAL(wp), INTENT(IN) :: r
    TYPE(Dual1) :: c
    c = ad1_mul_rd(1.0_wp/r, a)
  END FUNCTION ad1_div_dr

  PURE FUNCTION ad1_div_rd(r, a) RESULT(c)
    REAL(wp), INTENT(IN) :: r
    TYPE(Dual1), INTENT(IN) :: a
    TYPE(Dual1) :: c
    c = ad1_mul_rd(r, ad1_recip(a))
  END FUNCTION ad1_div_rd

  PURE FUNCTION unary1(a, f, df) RESULT(c)
    TYPE(Dual1), INTENT(IN) :: a
    REAL(wp), INTENT(IN) :: f, df
    TYPE(Dual1) :: c
    c%v = f
    c%g = df*a%g
  END FUNCTION unary1

  PURE FUNCTION AD1_Sqrt(a) RESULT(c)
    TYPE(Dual1), INTENT(IN) :: a
    TYPE(Dual1) :: c
    REAL(wp) :: s
    s = SQRT(a%v)
    c = unary1(a, s, 0.5_wp/s)
  END FUNCTION AD1_Sqrt

  PURE FUNCTION AD1_Sin(a) RESULT(c)
    TYPE(Dual1), INTENT(IN) :: a
    TYPE(Dual1) :: c
    c = unary1(a, SIN(a%v), COS(a%v))
  END FUNCTION AD1_Sin

  PURE FUNCTION AD1_Cos(a) RESULT(c)
    TYPE(Dual1), INTENT(IN) :: a
    TYPE(Dual1) :: c
    c = unary1(a, COS(a%v), -SIN(a%v))
  END FUNCTION AD1_Cos

  PURE FUNCTION AD1_Atan2(y, x) RESULT(c)
    TYPE(Dual1), INTENT(IN) :: y, x
    TYPE(Dual1) :: c
    REAL(wp) :: xv, yv, r2, dphidx, dphidy
    xv = x%v; yv = y%v
    r2 = xv*xv + yv*yv
    c%v = ATAN2(yv, xv)
    dphidx = -yv/r2
    dphidy = xv/r2
    c%g = dphidx*x%g + dphidy*y%g
  END FUNCTION AD1_Atan2

  PURE FUNCTION AD_Const(value) RESULT(d)
    !! A constant: value with zero derivatives.
    REAL(wp), INTENT(IN) :: value
    TYPE(Dual2) :: d
    d%v = value
    d%g = 0.0_wp
    d%h = 0.0_wp
  END FUNCTION AD_Const

  PURE FUNCTION AD_Var(value, i) RESULT(d)
    !! Independent variable i: value seeded with grad = e_i, hess = 0.
    REAL(wp), INTENT(IN) :: value
    INTEGER, INTENT(IN) :: i
    TYPE(Dual2) :: d
    d%v = value
    d%g = 0.0_wp
    d%g(i) = 1.0_wp
    d%h = 0.0_wp
  END FUNCTION AD_Var

  ! -------------------------------------------------------------------------
  ! Addition / subtraction (linear -> derivatives add)
  ! -------------------------------------------------------------------------
  PURE FUNCTION ad_add(a, b) RESULT(c)
    TYPE(Dual2), INTENT(IN) :: a, b
    TYPE(Dual2) :: c
    c%v = a%v + b%v
    c%g = a%g + b%g
    c%h = a%h + b%h
  END FUNCTION ad_add

  PURE FUNCTION ad_add_rd(r, a) RESULT(c)
    REAL(wp), INTENT(IN) :: r
    TYPE(Dual2), INTENT(IN) :: a
    TYPE(Dual2) :: c
    c = a
    c%v = a%v + r
  END FUNCTION ad_add_rd

  PURE FUNCTION ad_add_dr(a, r) RESULT(c)
    TYPE(Dual2), INTENT(IN) :: a
    REAL(wp), INTENT(IN) :: r
    TYPE(Dual2) :: c
    c = a
    c%v = a%v + r
  END FUNCTION ad_add_dr

  PURE FUNCTION ad_sub(a, b) RESULT(c)
    TYPE(Dual2), INTENT(IN) :: a, b
    TYPE(Dual2) :: c
    c%v = a%v - b%v
    c%g = a%g - b%g
    c%h = a%h - b%h
  END FUNCTION ad_sub

  PURE FUNCTION ad_sub_dr(a, r) RESULT(c)
    TYPE(Dual2), INTENT(IN) :: a
    REAL(wp), INTENT(IN) :: r
    TYPE(Dual2) :: c
    c = a
    c%v = a%v - r
  END FUNCTION ad_sub_dr

  PURE FUNCTION ad_sub_rd(r, a) RESULT(c)
    REAL(wp), INTENT(IN) :: r
    TYPE(Dual2), INTENT(IN) :: a
    TYPE(Dual2) :: c
    c%v = r - a%v
    c%g = -a%g
    c%h = -a%h
  END FUNCTION ad_sub_rd

  PURE FUNCTION ad_neg(a) RESULT(c)
    TYPE(Dual2), INTENT(IN) :: a
    TYPE(Dual2) :: c
    c%v = -a%v
    c%g = -a%g
    c%h = -a%h
  END FUNCTION ad_neg

  ! -------------------------------------------------------------------------
  ! Multiplication: (ab)'' = a'' b + 2 a' b' + a b''  (product rule, 2nd order)
  ! -------------------------------------------------------------------------
  PURE FUNCTION ad_mul(a, b) RESULT(c)
    TYPE(Dual2), INTENT(IN) :: a, b
    TYPE(Dual2) :: c
    INTEGER :: i, j
    c%v = a%v*b%v
    c%g = a%v*b%g + b%v*a%g
    DO j = 1, AD_NV
      DO i = 1, AD_NV
        c%h(i, j) = a%v*b%h(i, j) + b%v*a%h(i, j) + a%g(i)*b%g(j) + a%g(j)*b%g(i)
      END DO
    END DO
  END FUNCTION ad_mul

  PURE FUNCTION ad_mul_rd(r, a) RESULT(c)
    REAL(wp), INTENT(IN) :: r
    TYPE(Dual2), INTENT(IN) :: a
    TYPE(Dual2) :: c
    c%v = r*a%v
    c%g = r*a%g
    c%h = r*a%h
  END FUNCTION ad_mul_rd

  PURE FUNCTION ad_mul_dr(a, r) RESULT(c)
    TYPE(Dual2), INTENT(IN) :: a
    REAL(wp), INTENT(IN) :: r
    TYPE(Dual2) :: c
    c = ad_mul_rd(r, a)
  END FUNCTION ad_mul_dr

  ! -------------------------------------------------------------------------
  ! Division a/b = a * (1/b); reciprocal via the unary chain rule with
  ! f(x) = 1/x, f' = -1/x^2, f'' = 2/x^3.
  ! -------------------------------------------------------------------------
  PURE FUNCTION ad_recip(a) RESULT(c)
    TYPE(Dual2), INTENT(IN) :: a
    TYPE(Dual2) :: c
    REAL(wp) :: f, df, d2f
    f = 1.0_wp/a%v
    df = -f*f
    d2f = 2.0_wp*f*f*f
    c = unary(a, f, df, d2f)
  END FUNCTION ad_recip

  PURE FUNCTION ad_div(a, b) RESULT(c)
    TYPE(Dual2), INTENT(IN) :: a, b
    TYPE(Dual2) :: c
    c = ad_mul(a, ad_recip(b))
  END FUNCTION ad_div

  PURE FUNCTION ad_div_dr(a, r) RESULT(c)
    TYPE(Dual2), INTENT(IN) :: a
    REAL(wp), INTENT(IN) :: r
    TYPE(Dual2) :: c
    c = ad_mul_rd(1.0_wp/r, a)
  END FUNCTION ad_div_dr

  PURE FUNCTION ad_div_rd(r, a) RESULT(c)
    REAL(wp), INTENT(IN) :: r
    TYPE(Dual2), INTENT(IN) :: a
    TYPE(Dual2) :: c
    c = ad_mul_rd(r, ad_recip(a))
  END FUNCTION ad_div_rd

  ! -------------------------------------------------------------------------
  ! Generic unary chain rule: c = f(a) given f, f'(a.v), f''(a.v).
  !   c.v = f
  !   c.g = f' a.g
  !   c.h = f' a.h + f'' (a.g outer a.g)
  ! -------------------------------------------------------------------------
  PURE FUNCTION unary(a, f, df, d2f) RESULT(c)
    TYPE(Dual2), INTENT(IN) :: a
    REAL(wp), INTENT(IN) :: f, df, d2f
    TYPE(Dual2) :: c
    INTEGER :: i, j
    c%v = f
    c%g = df*a%g
    DO j = 1, AD_NV
      DO i = 1, AD_NV
        c%h(i, j) = df*a%h(i, j) + d2f*a%g(i)*a%g(j)
      END DO
    END DO
  END FUNCTION unary

  PURE FUNCTION AD_Sqrt(a) RESULT(c)
    TYPE(Dual2), INTENT(IN) :: a
    TYPE(Dual2) :: c
    REAL(wp) :: s
    s = SQRT(a%v)
    c = unary(a, s, 0.5_wp/s, -0.25_wp/(s*a%v))
  END FUNCTION AD_Sqrt

  PURE FUNCTION AD_Sin(a) RESULT(c)
    TYPE(Dual2), INTENT(IN) :: a
    TYPE(Dual2) :: c
    c = unary(a, SIN(a%v), COS(a%v), -SIN(a%v))
  END FUNCTION AD_Sin

  PURE FUNCTION AD_Cos(a) RESULT(c)
    TYPE(Dual2), INTENT(IN) :: a
    TYPE(Dual2) :: c
    c = unary(a, COS(a%v), -SIN(a%v), -COS(a%v))
  END FUNCTION AD_Cos

  PURE FUNCTION AD_Acos(a) RESULT(c)
    !! d/dx acos = -1/sqrt(1-x^2); d^2/dx^2 = -x/(1-x^2)^(3/2).
    TYPE(Dual2), INTENT(IN) :: a
    TYPE(Dual2) :: c
    REAL(wp) :: x, omx2, root
    x = a%v
    omx2 = 1.0_wp - x*x
    root = SQRT(omx2)
    c = unary(a, ACOS(x), -1.0_wp/root, -x/(omx2*root))
  END FUNCTION AD_Acos

  PURE FUNCTION AD_Atan2(y, x) RESULT(c)
    !! Two-argument arctangent phi = atan2(y, x). With r2 = x^2 + y^2,
    !!   dphi = (x dy - y dx)/r2,
    !! a smooth function of (x, y) away from the origin; the second-order
    !! chain rule is applied through the intermediate g = y/x style ratio by
    !! composing first derivatives directly (Hessian assembled from the exact
    !! partials below).
    TYPE(Dual2), INTENT(IN) :: y, x
    TYPE(Dual2) :: c
    REAL(wp) :: xv, yv, r2, r4
    REAL(wp) :: dphidx, dphidy, dxx, dyy, dxy
    INTEGER :: i, j
    xv = x%v; yv = y%v
    r2 = xv*xv + yv*yv
    r4 = r2*r2
    c%v = ATAN2(yv, xv)
    dphidx = -yv/r2
    dphidy = xv/r2
    ! second partials of atan2 wrt its two arguments
    dxx = 2.0_wp*xv*yv/r4
    dyy = -2.0_wp*xv*yv/r4
    dxy = (yv*yv - xv*xv)/r4
    c%g = dphidx*x%g + dphidy*y%g
    DO j = 1, AD_NV
      DO i = 1, AD_NV
        c%h(i, j) = dphidx*x%h(i, j) + dphidy*y%h(i, j) &
                    + dxx*x%g(i)*x%g(j) + dyy*y%g(i)*y%g(j) &
                    + dxy*(x%g(i)*y%g(j) + y%g(i)*x%g(j))
      END DO
    END DO
  END FUNCTION AD_Atan2

END MODULE CableDyn_AD
