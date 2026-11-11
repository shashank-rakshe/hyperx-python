! File: tests/test_hermite_twist_kernel.f90
! SPDX-License-Identifier: Apache-2.0
! Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
PROGRAM test_hermite_twist_kernel
  !! Gates for the reference twist of the nodal-twist model (CD_HermiteTwist_Reference):
  !!   I  the solid-angle forms equal the direct composition of the smallest rotations for an
  !!      interior element, an element at a rigid End A, at a rigid End B, a one-element line
  !!      rigid at both ends, and the end links of an elastic end,
  !!   T  with the holonomy, the reference twist is the angle from the director carried along
  !!      the element (fine smallest-rotation transport of its tangent) to the next director,
  !!   F  gradient and Hessian against central differences, and the fixed-vertex gradient
  !!      against rotations of the fixed vertices,
  !!   G  the fold guard and the input checks fail closed.
  USE CableDyn_Precision, ONLY: wp
  USE CableDyn_HermiteTorsion, ONLY: CD_HermiteTwist_Reference, CD_HermiteTwist_Carry, CD_HermiteTwist_Angle, &
                                     CD_HTORS_OK, CD_HTORS_FOLD, CD_HTORS_BADINPUT
  IMPLICIT NONE

  INTEGER :: nfail
  REAL(wp) :: qe(12), el, a(3), d(3), b(3), c(3), u1n(3), u2n(3), dA(3), nA(3), dB(3), nB(3)

  nfail = 0
  CALL setup()
  CALL check_identities()
  CALL check_transport()
  CALL check_derivatives()
  CALL check_guards()
  IF (nfail > 0) THEN
    WRITE (*, '(A,I0,A)') 'FAIL: ', nfail, ' assertion(s) failed'
    ERROR STOP 1
  END IF
  WRITE (*, '(A)') 'PASS: nodal-twist reference twist matches the direct transports and its derivatives'

CONTAINS

  SUBROUTINE require(ok, label)
    LOGICAL, INTENT(IN) :: ok
    CHARACTER(*), INTENT(IN) :: label
    IF (.NOT. ok) THEN
      nfail = nfail + 1
      WRITE (*, '(A)') 'FAIL: '//label
    END IF
  END SUBROUTINE require

  FUNCTION unit(v) RESULT(w)
    REAL(wp), INTENT(IN) :: v(3)
    REAL(wp) :: w(3)
    w = v/NORM2(v)
  END FUNCTION unit

  FUNCTION perp(v, t) RESULT(w)
    !! unit part of v perpendicular to the unit t
    REAL(wp), INTENT(IN) :: v(3), t(3)
    REAL(wp) :: w(3)
    w = unit(v - DOT_PRODUCT(v, t)*t)
  END FUNCTION perp

  FUNCTION cross(x, y) RESULT(z)
    REAL(wp), INTENT(IN) :: x(3), y(3)
    REAL(wp) :: z(3)
    z = [x(2)*y(3) - x(3)*y(2), x(3)*y(1) - x(1)*y(3), x(1)*y(2) - x(2)*y(1)]
  END FUNCTION cross

  FUNCTION rotate(v, w) RESULT(r)
    !! exp(w) v (Rodrigues)
    REAL(wp), INTENT(IN) :: v(3), w(3)
    REAL(wp) :: r(3), th, k(3)
    th = NORM2(w)
    IF (th <= 0.0_wp) THEN
      r = v
      RETURN
    END IF
    k = w/th
    r = v*COS(th) + cross(k, v)*SIN(th) + k*DOT_PRODUCT(k, v)*(1.0_wp - COS(th))
  END FUNCTION rotate

  SUBROUTINE setup()
    !! A curved, stretched element and committed tangents a step away from its node tangents.
    el = 2.3_wp
    qe(1:3) = [0.1_wp, -0.2_wp, 0.05_wp]
    qe(4:6) = [0.95_wp, 0.25_wp, -0.12_wp]
    qe(7:9) = qe(1:3) + [2.1_wp, 0.9_wp, 0.4_wp]
    qe(10:12) = [0.72_wp, 0.55_wp, 0.38_wp]
    b = unit(qe(4:6))
    c = unit(qe(10:12))
    a = rotate(b, [0.03_wp, -0.07_wp, 0.05_wp])
    d = rotate(c, [-0.06_wp, 0.02_wp, 0.04_wp])
    u1n = perp([0.2_wp, 1.0_wp, -0.3_wp], a)
    u2n = perp([-0.4_wp, 0.3_wp, 1.0_wp], d)
    dA = rotate(b, [0.15_wp, 0.1_wp, -0.08_wp])
    nA = perp([0.0_wp, 0.3_wp, 1.0_wp], dA)
    dB = rotate(c, [-0.12_wp, 0.09_wp, 0.11_wp])
    nB = perp([1.0_wp, -0.2_wp, 0.1_wp], dB)
  END SUBROUTINE setup

  REAL(wp) FUNCTION ref(tri, tslot, tsign, hol) RESULT(v)
    REAL(wp), INTENT(IN) :: tri(:, :, :), tsign(:)
    INTEGER, INTENT(IN) :: tslot(:, :)
    LOGICAL, INTENT(IN) :: hol
    REAL(wp) :: g(12)
    INTEGER :: es
    CHARACTER(200) :: em
    CALL CD_HermiteTwist_Reference(qe, el, tri, tslot, tsign, v, g, es, em, holonomy=hol)
    CALL require(es == CD_HTORS_OK, 'reference evaluation: '//TRIM(em))
  END FUNCTION ref

  SUBROUTINE check_identities()
    REAL(wp) :: tri(3, 3, 2), direct, formula, cst, z(3)
    INTEGER :: slot(3, 2)
    CHARACTER(120) :: msg

    ! interior: beta = beta^n - Omega(a, b, c) - Omega(a, c, d)
    direct = CD_HermiteTwist_Angle(CD_HermiteTwist_Carry(b, c, CD_HermiteTwist_Carry(a, b, u1n)), &
                                   CD_HermiteTwist_Carry(d, c, u2n), c)
    cst = CD_HermiteTwist_Angle(CD_HermiteTwist_Carry(a, d, u1n), u2n, d)
    z = 0.0_wp
    tri(:, :, 1) = RESHAPE([a, z, z], [3, 3])
    tri(:, :, 2) = RESHAPE([a, z, d], [3, 3])
    slot(:, 1) = [0, 1, 2]
    slot(:, 2) = [0, 2, 0]
    formula = cst + ref(tri, slot, [-1.0_wp, -1.0_wp], .FALSE.)
    WRITE (msg, '(A,2ES12.4)') 'I interior element: direct vs formula ', direct, formula
    CALL require(ABS(direct - formula) < 1.0e-13_wp, msg)
    CALL require(ABS(direct - cst) > 1.0e-3_wp, 'I interior element: the step moves the reference twist')

    ! rigid End A: u_1 = G(dA -> b) nA; beta = angle(G(dA -> d) nA -> u2n) - Omega(dA, b, c) - Omega(dA, c, d)
    direct = CD_HermiteTwist_Angle(CD_HermiteTwist_Carry(b, c, CD_HermiteTwist_Carry(dA, b, nA)), &
                                   CD_HermiteTwist_Carry(d, c, u2n), c)
    cst = CD_HermiteTwist_Angle(CD_HermiteTwist_Carry(dA, d, nA), u2n, d)
    tri(:, :, 1) = RESHAPE([dA, z, z], [3, 3])
    tri(:, :, 2) = RESHAPE([dA, z, d], [3, 3])
    formula = cst + ref(tri, slot, [-1.0_wp, -1.0_wp], .FALSE.)
    WRITE (msg, '(A,2ES12.4)') 'I rigid End A element: direct vs formula ', direct, formula
    CALL require(ABS(direct - formula) < 1.0e-13_wp, msg)

    ! rigid End B: u_2 = G(dB -> c) nB; beta = angle(u1n -> G(dB -> a) nB) + Omega(dB, c, a) - Omega(a, b, c)
    direct = CD_HermiteTwist_Angle(CD_HermiteTwist_Carry(b, c, CD_HermiteTwist_Carry(a, b, u1n)), &
                                   CD_HermiteTwist_Carry(dB, c, nB), c)
    cst = CD_HermiteTwist_Angle(u1n, CD_HermiteTwist_Carry(dB, a, nB), a)
    tri(:, :, 1) = RESHAPE([dB, z, a], [3, 3])
    tri(:, :, 2) = RESHAPE([a, z, z], [3, 3])
    slot(:, 1) = [0, 2, 0]
    slot(:, 2) = [0, 1, 2]
    formula = cst + ref(tri, slot, [1.0_wp, -1.0_wp], .FALSE.)
    WRITE (msg, '(A,2ES12.4)') 'I rigid End B element: direct vs formula ', direct, formula
    CALL require(ABS(direct - formula) < 1.0e-13_wp, msg)

    ! one element rigid at both ends: beta = angle(nA -> G(dB -> dA) nB) + Omega(dB, c, dA) - Omega(dA, b, c)
    direct = CD_HermiteTwist_Angle(CD_HermiteTwist_Carry(b, c, CD_HermiteTwist_Carry(dA, b, nA)), &
                                   CD_HermiteTwist_Carry(dB, c, nB), c)
    cst = CD_HermiteTwist_Angle(nA, CD_HermiteTwist_Carry(dB, dA, nB), dA)
    tri(:, :, 1) = RESHAPE([dB, z, dA], [3, 3])
    tri(:, :, 2) = RESHAPE([dA, z, z], [3, 3])
    slot(:, 1) = [0, 2, 0]
    slot(:, 2) = [0, 1, 2]
    formula = cst + ref(tri, slot, [1.0_wp, -1.0_wp], .FALSE.)
    WRITE (msg, '(A,2ES12.4)') 'I rigid at both ends: direct vs formula ', direct, formula
    CALL require(ABS(direct - formula) < 1.0e-13_wp, msg)

    ! elastic End A link: psi = angle(u_1 -> G(dA -> b) nA) = angle(u1n -> G(dA -> a) nA) + Omega(dA, b, a)
    direct = CD_HermiteTwist_Angle(CD_HermiteTwist_Carry(a, b, u1n), CD_HermiteTwist_Carry(dA, b, nA), b)
    cst = CD_HermiteTwist_Angle(u1n, CD_HermiteTwist_Carry(dA, a, nA), a)
    tri(:, :, 1) = RESHAPE([dA, z, a], [3, 3])
    slot(:, 1) = [0, 1, 0]
    formula = cst + ref(tri(:, :, 1:1), slot(:, 1:1), [1.0_wp], .FALSE.)
    WRITE (msg, '(A,2ES12.4)') 'I elastic end link: direct vs formula ', direct, formula
    CALL require(ABS(direct - formula) < 1.0e-13_wp, msg)
  END SUBROUTINE check_identities

  SUBROUTINE check_transport()
    !! With the holonomy, value + beta^n is the angle from u_1 carried along the element's own
    !! tangent field to u_2 (both time-transported), here with u_1 = u1n, u_2 = u2n and a = b,
    !! d = c (no step).
    INTEGER, PARAMETER :: NSUB = 20000
    REAL(wp) :: tri(3, 3, 2), z(3), v(3), tp(3), tc(3), x, hh(4), direct, formula, cst, ua(3), ub(3)
    INTEGER :: slot(3, 2), k, es
    REAL(wp) :: g(12), val
    CHARACTER(200) :: em
    CHARACTER(120) :: msg
    z = 0.0_wp
    ua = perp(u1n, b)
    ub = perp(u2n, c)
    v = ua
    tp = b
    DO k = 1, NSUB
      x = REAL(k, wp)/REAL(NSUB, wp)
      hh = [-6.0_wp*x + 6.0_wp*x*x, el*(1.0_wp - 4.0_wp*x + 3.0_wp*x*x), 6.0_wp*x - 6.0_wp*x*x, &
            el*(-2.0_wp*x + 3.0_wp*x*x)]
      tc = unit(hh(1)*qe(1:3) + hh(2)*qe(4:6) + hh(3)*qe(7:9) + hh(4)*qe(10:12))
      IF (k == NSUB) tc = c
      v = CD_HermiteTwist_Carry(tp, tc, v)
      tp = tc
    END DO
    direct = CD_HermiteTwist_Angle(v, ub, c)
    cst = CD_HermiteTwist_Angle(CD_HermiteTwist_Carry(b, c, ua), ub, c)
    tri(:, :, 1) = RESHAPE([b, z, z], [3, 3])
    tri(:, :, 2) = RESHAPE([b, z, c], [3, 3])
    slot(:, 1) = [0, 1, 2]
    slot(:, 2) = [0, 2, 0]
    CALL CD_HermiteTwist_Reference(qe, el, tri, slot, [-1.0_wp, -1.0_wp], val, g, es, em, quadrature_order=6)
    CALL require(es == CD_HTORS_OK, 'T transport evaluation: '//TRIM(em))
    formula = cst + val
    WRITE (msg, '(A,2ES14.6)') 'T element transport: fine transport vs beta - h_e ', direct, formula
    CALL require(ABS(direct - formula) < 1.0e-6_wp, msg)
    CALL require(ABS(direct - cst) > 1.0e-3_wp, 'T the element holonomy is not negligible on this element')
  END SUBROUTINE check_transport

  SUBROUTINE check_derivatives()
    REAL(wp) :: tri(3, 3, 2), z(3), g(12), h(12, 12), gp(12), gm(12), fg(3, 3, 2), vp, vm, v0, eps
    REAL(wp) :: err_g, err_h, err_f, scale_g, scale_h, q0(12), w(3), x0(3), num
    INTEGER :: slot(3, 2), i, es, k, j
    CHARACTER(200) :: em
    CHARACTER(120) :: msg
    z = 0.0_wp
    tri(:, :, 1) = RESHAPE([a, z, z], [3, 3])
    tri(:, :, 2) = RESHAPE([a, z, d], [3, 3])
    slot(:, 1) = [0, 1, 2]
    slot(:, 2) = [0, 2, 0]
    q0 = qe
    CALL CD_HermiteTwist_Reference(qe, el, tri, slot, [-1.0_wp, -1.0_wp], v0, g, es, em, hess=h, fixed_grad=fg)
    CALL require(es == CD_HTORS_OK, 'F evaluation: '//TRIM(em))
    eps = 1.0e-6_wp
    err_g = 0.0_wp
    err_h = 0.0_wp
    scale_g = MAXVAL(ABS(g))
    scale_h = MAXVAL(ABS(h))
    DO i = 1, 12
      qe = q0
      qe(i) = q0(i) + eps
      CALL CD_HermiteTwist_Reference(qe, el, tri, slot, [-1.0_wp, -1.0_wp], vp, gp, es, em)
      qe(i) = q0(i) - eps
      CALL CD_HermiteTwist_Reference(qe, el, tri, slot, [-1.0_wp, -1.0_wp], vm, gm, es, em)
      err_g = MAX(err_g, ABS((vp - vm)/(2.0_wp*eps) - g(i)))
      err_h = MAX(err_h, MAXVAL(ABS((gp - gm)/(2.0_wp*eps) - h(:, i))))
    END DO
    qe = q0
    WRITE (msg, '(A,2ES10.2)') 'F gradient and Hessian relative errors ', err_g/scale_g, err_h/scale_h
    CALL require(err_g/scale_g < 1.0e-7_wp .AND. err_h/scale_h < 1.0e-6_wp, msg)
    CALL require(MAXVAL(ABS(h - TRANSPOSE(h))) < 1.0e-10_wp*scale_h, 'F the Hessian is symmetric')
    ! fixed vertices: rotate each by a small angle about a few axes
    err_f = 0.0_wp
    DO k = 1, 2
      DO j = 1, 3
        IF (slot(j, k) /= 0) CYCLE
        x0 = tri(:, j, k)
        DO i = 1, 3
          w = 0.0_wp
          w(i) = 1.0_wp
          tri(:, j, k) = rotate(x0, eps*w)
          CALL CD_HermiteTwist_Reference(qe, el, tri, slot, [-1.0_wp, -1.0_wp], vp, gp, es, em)
          tri(:, j, k) = rotate(x0, -eps*w)
          CALL CD_HermiteTwist_Reference(qe, el, tri, slot, [-1.0_wp, -1.0_wp], vm, gm, es, em)
          tri(:, j, k) = x0
          num = (vp - vm)/(2.0_wp*eps)
          err_f = MAX(err_f, ABS(num - DOT_PRODUCT(fg(:, j, k), cross(w, x0))))
        END DO
      END DO
    END DO
    WRITE (msg, '(A,ES10.2)') 'F fixed-vertex gradient error ', err_f
    CALL require(err_f < 1.0e-8_wp, msg)
  END SUBROUTINE check_derivatives

  SUBROUTINE check_guards()
    REAL(wp) :: tri(3, 3, 1), z(3), g(12), v
    INTEGER :: slot(3, 1), es
    CHARACTER(200) :: em
    z = 0.0_wp
    ! a committed tangent opposite to the node tangent: folded
    tri(:, :, 1) = RESHAPE([-b, z, z], [3, 3])
    slot(:, 1) = [0, 1, 2]
    CALL CD_HermiteTwist_Reference(qe, el, tri, slot, [1.0_wp], v, g, es, em)
    CALL require(es == CD_HTORS_FOLD, 'G a reversed tangent fails with the fold status')
    ! a non-unit fixed vertex
    tri(:, :, 1) = RESHAPE([2.0_wp*a, z, z], [3, 3])
    CALL CD_HermiteTwist_Reference(qe, el, tri, slot, [1.0_wp], v, g, es, em)
    CALL require(es == CD_HTORS_BADINPUT, 'G a non-unit fixed vertex is refused')
    ! a bad slot
    tri(:, :, 1) = RESHAPE([a, z, z], [3, 3])
    slot(:, 1) = [0, 3, 2]
    CALL CD_HermiteTwist_Reference(qe, el, tri, slot, [1.0_wp], v, g, es, em)
    CALL require(es == CD_HTORS_BADINPUT, 'G a vertex slot outside 0..2 is refused')
  END SUBROUTINE check_guards

END PROGRAM test_hermite_twist_kernel
