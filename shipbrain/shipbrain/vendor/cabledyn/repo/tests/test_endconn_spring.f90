! File: tests/test_endconn_spring.f90
! SPDX-License-Identifier: Apache-2.0
! Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
PROGRAM test_endconn_spring
  !! Unit gates for the linear isotropic rotational end connection
  !! (CableDyn_EndConnection). The spring is a configuration-dependent generalized
  !! load, so its correctness rests on four independent properties, each checked
  !! here rather than inferred from a system-level result:
  !!
  !!   1. PINNED LIMIT      k = 0 returns exactly zero force and tangent, so an
  !!                        omitted end connection cannot perturb any existing deck.
  !!   2. STRETCH FREEDOM   f . d == 0 identically. The Hermite tangent magnitude
  !!                        carries axial stretch; a connection stiffness that leaked
  !!                        into it would reproduce the documented inextensibility
  !!                        over-constraint (test_hermite_cable_dynamic.f90). This is
  !!                        the property the whole formulation exists to guarantee.
  !!   3. ENERGY CONSISTENCY  f == dU/dm by central differences of U = 0.5 k theta^2.
  !!   4. TANGENT CONSISTENCY K == df/dm by central differences of f, and K symmetric
  !!                        (it is the Hessian of a potential).
  !!
  !! Checked across deflection angles spanning the small-angle series branch
  !! (theta < 1e-3), the closed-form branch, and large deflection, and at tangent
  !! magnitudes away from unity so the 1/n and 1/n^2 scalings are exercised.
  USE CableDyn_Precision, ONLY: wp
  USE CableDyn_EndConnection, ONLY: CD_EndConn_Spring, CD_EndConn_Energy, CD_EndConn_Angle, &
                                    CD_EndConn_Reaction_Moment, CD_EndConn_Basis, CD_EndConn_Project, &
                                    CD_ENDCONN_OK
  USE, INTRINSIC :: IEEE_ARITHMETIC, ONLY: IEEE_VALUE, IEEE_QUIET_NAN, IEEE_POSITIVE_INF
  IMPLICIT NONE

  REAL(wp), PARAMETER :: KROT = 3.7e4_wp          ! N m/rad
  INTEGER :: nfail
  nfail = 0

  CALL check_pinned_limit()
  CALL check_zero_deflection_tangent()
  CALL sweep_angles()
  CALL check_direction_scaling()
  CALL check_rigid_geometry()
  CALL check_invalid_inputs()

  IF (nfail > 0) THEN
    WRITE (*, '(A,I0,A)') 'FAIL: ', nfail, ' assertion(s) failed'
    ERROR STOP 1
  END IF
  WRITE (*, '(A)') 'PASS: end-connection spring force, tangent, symmetry and stretch freedom'

CONTAINS

  INCLUDE 'nan_max_abs.inc'

  SUBROUTINE fail_if(bad, what, got, want)
    LOGICAL, INTENT(IN) :: bad
    CHARACTER(*), INTENT(IN) :: what
    REAL(wp), INTENT(IN), OPTIONAL :: got, want
    IF (.NOT. bad) RETURN
    nfail = nfail + 1
    IF (PRESENT(got) .AND. PRESENT(want)) THEN
      WRITE (*, '(A,A,A,ES13.6,A,ES13.6)') 'FAIL: ', what, '  got=', got, ' want<=', want
    ELSE
      WRITE (*, '(A,A)') 'FAIL: ', what
    END IF
  END SUBROUTINE fail_if

  FUNCTION unit3(v) RESULT(u)
    REAL(wp), INTENT(IN) :: v(3)
    REAL(wp) :: u(3)
    u = v/SQRT(DOT_PRODUCT(v, v))
  END FUNCTION unit3

  SUBROUTINE check_pinned_limit()
    !! k = 0 is the default for every existing deck: it must be bit-exact zero.
    REAL(wp) :: m(3), d0(3), f(3), k(3, 3)
    INTEGER :: es
    CHARACTER(200) :: em
    m = [0.3_wp, -0.7_wp, 1.2_wp]
    d0 = unit3([0.1_wp, 0.2_wp, 1.0_wp])
    CALL CD_EndConn_Spring(m, d0, 0.0_wp, f, k, es, em)
    CALL fail_if(es /= CD_ENDCONN_OK, 'pinned limit: call must succeed')
    CALL fail_if(ANY(f /= 0.0_wp), 'pinned limit: force must be exactly zero')
    CALL fail_if(ANY(k /= 0.0_wp), 'pinned limit: tangent must be exactly zero')
  END SUBROUTINE check_pinned_limit

  SUBROUTINE check_zero_deflection_tangent()
    !! At theta = 0 the tangent must collapse to (k/n^2)(I - d(x)d): transverse only,
    !! nothing along d. This is the analytic statement that stretch is left free.
    REAL(wp) :: m(3), d0(3), f(3), k(3, 3), d(3), want(3, 3), n
    INTEGER :: i, j, es
    CHARACTER(200) :: em
    m = [0.6_wp, -0.2_wp, 1.5_wp]*1.37_wp        ! |m| /= 1 on purpose
    d0 = unit3(m)                                 ! perfectly aligned -> theta = 0
    n = SQRT(DOT_PRODUCT(m, m))
    d = m/n
    CALL CD_EndConn_Spring(m, d0, KROT, f, k, es, em)
    CALL fail_if(es /= CD_ENDCONN_OK, 'aligned: call must succeed')
    CALL fail_if(nan_max_abs(f) > 1.0e-12_wp, 'aligned: force must vanish', nan_max_abs(f), 1.0e-12_wp)
    DO j = 1, 3
      DO i = 1, 3
        want(i, j) = (KROT/(n*n))*(MERGE(1.0_wp, 0.0_wp, i == j) - d(i)*d(j))
      END DO
    END DO
    CALL fail_if(nan_max_abs(k - want) > 1.0e-9_wp*KROT, &
                 'aligned: tangent must equal (k/n^2)(I-d(x)d)', nan_max_abs(k - want), 1.0e-9_wp*KROT)
    ! and it must annihilate d: no stiffness along the stretch direction
    CALL fail_if(nan_max_abs(MATMUL(k, d)) > 1.0e-9_wp*KROT, &
                 'aligned: tangent must annihilate d (stretch free)', nan_max_abs(MATMUL(k, d)), 1.0e-9_wp*KROT)
  END SUBROUTINE check_zero_deflection_tangent

  SUBROUTINE sweep_angles()
    REAL(wp), PARAMETER :: ANGLES(7) = [1.0e-7_wp, 1.0e-5_wp, 1.0e-3_wp, 0.05_wp, &
                                        0.4_wp, 1.2_wp, 2.5_wp]
    REAL(wp), PARAMETER :: MAGS(3) = [0.85_wp, 1.0_wp, 1.4_wp]
    INTEGER :: ia, im
    DO im = 1, SIZE(MAGS)
      DO ia = 1, SIZE(ANGLES)
        CALL check_one(ANGLES(ia), MAGS(im))
      END DO
    END DO
  END SUBROUTINE sweep_angles

  SUBROUTINE check_one(theta_target, mag)
    !! Build m at a known deflection from d0, then check every property.
    REAL(wp), INTENT(IN) :: theta_target, mag
    REAL(wp) :: d0(3), axis(3), d(3), m(3), f(3), k(3, 3)
    REAL(wp) :: theta, c, s, n, dd(3), p(3), fd(3), kfd(3, 3)
    REAL(wp) :: rel, scale
    INTEGER :: i, es
    CHARACTER(200) :: em
    REAL(wp) :: moment(3), moment_want(3)

    d0 = unit3([0.2_wp, -0.3_wp, 0.9_wp])
    ! an axis perpendicular to d0, so rotating d0 about it gives exactly theta_target
    axis = unit3([-d0(2), d0(1), 0.0_wp])
    d = COS(theta_target)*d0 + SIN(theta_target)*cross(axis, d0)
    m = mag*d

    CALL CD_EndConn_Spring(m, d0, KROT, f, k, es, em)
    CALL fail_if(es /= CD_ENDCONN_OK, 'spring evaluation must succeed')
    IF (es /= CD_ENDCONN_OK) RETURN
    CALL CD_EndConn_Angle(m, d0, theta, c, s, n, dd, p, es, em)
    CALL fail_if(es /= CD_ENDCONN_OK, 'angle evaluation must succeed')
    IF (es /= CD_ENDCONN_OK) RETURN

    ! (a) the geometry helper must recover the intended angle
    CALL fail_if(ABS(theta - theta_target) > 1.0e-10_wp*MAX(1.0_wp, theta_target), &
                 'angle recovery', ABS(theta - theta_target), 1.0e-10_wp*MAX(1.0_wp, theta_target))

    ! (b) STRETCH FREEDOM: f . d == 0 to round-off, at every angle and magnitude
    scale = MAX(nan_max_abs(f), TINY(1.0_wp))
    CALL fail_if(ABS(DOT_PRODUCT(f, dd))/scale > 1.0e-12_wp, &
                 'stretch freedom f.d == 0', ABS(DOT_PRODUCT(f, dd))/scale, 1.0e-12_wp)

    ! (c) magnitude of the generalized force is k*theta/n
    CALL fail_if(ABS(SQRT(DOT_PRODUCT(f, f)) - KROT*theta/n) > 1.0e-9_wp*KROT*MAX(theta, 1.0e-7_wp), &
                 'force magnitude k*theta/n')

    ! (d) ENERGY CONSISTENCY: f == dU/dm by central differences
    CALL fd_energy_gradient(m, d0, fd)
    rel = nan_max_abs(f - fd)/MAX(nan_max_abs(fd), 1.0e-30_wp)
    CALL fail_if(rel > 2.0e-6_wp, 'force vs dU/dm (central difference)', rel, 2.0e-6_wp)

    ! (e) TANGENT CONSISTENCY: K == df/dm by central differences
    CALL fd_force_jacobian(m, d0, kfd)
    rel = nan_max_abs(k - kfd)/MAX(nan_max_abs(kfd), 1.0e-30_wp)
    CALL fail_if(rel > 5.0e-6_wp, 'tangent vs df/dm (central difference)', rel, 5.0e-6_wp)

    ! (f) SYMMETRY: K is the Hessian of a potential
    rel = 0.0_wp
    DO i = 1, 3
      rel = MAX(rel, nan_max_abs(k(i, :) - k(:, i)))
    END DO
    CALL fail_if(rel > 1.0e-9_wp*MAX(nan_max_abs(k), 1.0e-30_wp), 'tangent symmetry', rel, 0.0_wp)

    ! (g) support reaction moment: magnitude k theta and direction
    !     -(k theta/sin(theta)) d cross d0.
    CALL CD_EndConn_Reaction_Moment(m, f, moment, es, em)
    CALL fail_if(es /= CD_ENDCONN_OK, 'reaction-moment evaluation must succeed')
    moment_want = -(KROT*theta/s)*cross(dd, d0)
    rel = nan_max_abs(moment - moment_want)/MAX(KROT*theta, 1.0e-30_wp)
    CALL fail_if(rel > 1.0e-9_wp, 'support reaction moment', rel, 1.0e-9_wp)
  END SUBROUTINE check_one

  SUBROUTINE check_direction_scaling()
    !! Preferred directions are geometric directions, not magnitude-bearing vectors.
    REAL(wp) :: m(3), d0(3), f1(3), f2(3), k1(3, 3), k2(3, 3)
    INTEGER :: es1, es2
    CHARACTER(200) :: em
    m = [0.7_wp, -0.4_wp, 1.2_wp]
    d0 = [0.3_wp, 0.2_wp, 0.9_wp]
    CALL CD_EndConn_Spring(m, d0, KROT, f1, k1, es1, em)
    CALL CD_EndConn_Spring(m, 7.3_wp*d0, KROT, f2, k2, es2, em)
    CALL fail_if(es1 /= CD_ENDCONN_OK .OR. es2 /= CD_ENDCONN_OK, &
                 'direction scaling: both calls must succeed')
    CALL fail_if(nan_max_abs(f1 - f2) > 2.0e-12_wp*KROT, &
                 'direction scaling: force must be invariant')
    CALL fail_if(nan_max_abs(k1 - k2) > 2.0e-12_wp*KROT, &
                 'direction scaling: tangent must be invariant')
  END SUBROUTINE check_direction_scaling

  SUBROUTINE check_rigid_geometry()
    !! The exact-rigid implementation eliminates the two transverse tangent
    !! coordinates in this basis.  Check the geometric primitive independently
    !! of both nonlinear solvers, including directions close to coordinate axes.
    REAL(wp), PARAMETER :: DIRS(3, 6) = RESHAPE([ &
                                                1.0_wp, 0.0_wp, 0.0_wp, &
                                                0.0_wp, -1.0_wp, 0.0_wp, &
                                                0.0_wp, 0.0_wp, 1.0_wp, &
                                                1.0_wp, 2.0_wp, -3.0_wp, &
                                                1.0e-14_wp, 1.0_wp, -2.0e-14_wp, &
                                                -0.41_wp, 0.73_wp, 0.19_wp], [3, 6])
    REAL(wp) :: basis(3, 3), gram(3, 3), identity(3, 3), d(3)
    REAL(wp) :: m(3), projected(3), mag, handedness
    INTEGER :: i, idir, es
    CHARACTER(200) :: em

    identity = 0.0_wp
    DO i = 1, 3
      identity(i, i) = 1.0_wp
    END DO
    m = [0.37_wp, -1.21_wp, 0.83_wp]
    mag = SQRT(DOT_PRODUCT(m, m))

    DO idir = 1, SIZE(DIRS, 2)
      d = unit3(DIRS(:, idir))
      CALL CD_EndConn_Basis(DIRS(:, idir), basis, es, em)
      CALL fail_if(es /= CD_ENDCONN_OK, 'rigid basis: valid direction must succeed')
      IF (es /= CD_ENDCONN_OK) CYCLE
      gram = MATMUL(TRANSPOSE(basis), basis)
      CALL fail_if(nan_max_abs(gram - identity) > 32.0_wp*EPSILON(1.0_wp), &
                   'rigid basis: columns must be orthonormal', &
                   nan_max_abs(gram - identity), 32.0_wp*EPSILON(1.0_wp))
      CALL fail_if(nan_max_abs(basis(:, 1) - d) > 8.0_wp*EPSILON(1.0_wp), &
                   'rigid basis: first column must equal normalized direction')
      handedness = DOT_PRODUCT(cross(basis(:, 1), basis(:, 2)), basis(:, 3))
      CALL fail_if(ABS(handedness - 1.0_wp) > 32.0_wp*EPSILON(1.0_wp), &
                   'rigid basis: basis must be right handed', &
                   ABS(handedness - 1.0_wp), 32.0_wp*EPSILON(1.0_wp))

      CALL CD_EndConn_Project(m, DIRS(:, idir), projected, es, em)
      CALL fail_if(es /= CD_ENDCONN_OK, 'rigid projection: valid state must succeed')
      IF (es /= CD_ENDCONN_OK) CYCLE
      CALL fail_if(ABS(SQRT(DOT_PRODUCT(projected, projected)) - mag) > 16.0_wp*EPSILON(1.0_wp)*mag, &
                   'rigid projection: tangent magnitude must be preserved')
      CALL fail_if(nan_max_abs(projected/mag - d) > 16.0_wp*EPSILON(1.0_wp), &
                   'rigid projection: tangent must lie on positive prescribed ray')
    END DO

    CALL CD_EndConn_Basis([0.0_wp, 0.0_wp, 0.0_wp], basis, es, em)
    CALL fail_if(es == CD_ENDCONN_OK, 'rigid basis: null direction must be rejected')
    CALL CD_EndConn_Project([0.0_wp, 0.0_wp, 0.0_wp], [1.0_wp, 0.0_wp, 0.0_wp], projected, es, em)
    CALL fail_if(es == CD_ENDCONN_OK, 'rigid projection: null tangent must be rejected')
  END SUBROUTINE check_rigid_geometry

  SUBROUTINE check_invalid_inputs()
    !! Invalid constitutive states fail closed instead of returning zeros or NaNs.
    REAL(wp) :: m(3), d0(3), f(3), k(3, 3), theta, c, s, n, d(3), p(3)
    REAL(wp) :: nanv, infv
    INTEGER :: es
    CHARACTER(200) :: em
    m = [1.0_wp, 0.0_wp, 0.0_wp]
    d0 = [1.0_wp, 0.0_wp, 0.0_wp]
    nanv = IEEE_VALUE(0.0_wp, IEEE_QUIET_NAN)
    infv = IEEE_VALUE(0.0_wp, IEEE_POSITIVE_INF)

    CALL CD_EndConn_Spring(m, d0, -1.0_wp, f, k, es, em)
    CALL fail_if(es == CD_ENDCONN_OK, 'negative stiffness must be rejected')
    CALL CD_EndConn_Spring(m, d0, infv, f, k, es, em)
    CALL fail_if(es == CD_ENDCONN_OK, 'infinite stiffness must be rejected')
    CALL CD_EndConn_Spring([0.0_wp, 0.0_wp, 0.0_wp], d0, KROT, f, k, es, em)
    CALL fail_if(es == CD_ENDCONN_OK, 'zero tangent must be rejected')
    CALL CD_EndConn_Spring(m, [0.0_wp, 0.0_wp, 0.0_wp], KROT, f, k, es, em)
    CALL fail_if(es == CD_ENDCONN_OK, 'zero preferred direction must be rejected')
    CALL CD_EndConn_Spring(m, [nanv, 0.0_wp, 0.0_wp], KROT, f, k, es, em)
    CALL fail_if(es == CD_ENDCONN_OK, 'non-finite preferred direction must be rejected')
    CALL CD_EndConn_Basis([nanv, 0.0_wp, 0.0_wp], k, es, em)
    CALL fail_if(es == CD_ENDCONN_OK, 'rigid basis: non-finite direction must be rejected')
    CALL CD_EndConn_Project([nanv, 0.0_wp, 0.0_wp], d0, d, es, em)
    CALL fail_if(es == CD_ENDCONN_OK, 'rigid projection: non-finite tangent must be rejected')
    CALL CD_EndConn_Angle(-m, d0, theta, c, s, n, d, p, es, em)
    CALL fail_if(es == CD_ENDCONN_OK, 'antiparallel state must be rejected')
  END SUBROUTINE check_invalid_inputs

  FUNCTION cross(a, b) RESULT(c)
    REAL(wp), INTENT(IN) :: a(3), b(3)
    REAL(wp) :: c(3)
    c = [a(2)*b(3) - a(3)*b(2), a(3)*b(1) - a(1)*b(3), a(1)*b(2) - a(2)*b(1)]
  END FUNCTION cross

  SUBROUTINE fd_energy_gradient(m, d0, g)
    REAL(wp), INTENT(IN) :: m(3), d0(3)
    REAL(wp), INTENT(OUT) :: g(3)
    REAL(wp) :: mp(3), h, ep, eminus
    INTEGER :: i, es
    CHARACTER(200) :: em
    DO i = 1, 3
      h = 1.0e-6_wp*MAX(ABS(m(i)), 1.0e-3_wp)
      mp = m; mp(i) = m(i) + h
      CALL CD_EndConn_Energy(mp, d0, KROT, ep, es, em)
      IF (es /= CD_ENDCONN_OK) ERROR STOP 'finite-difference energy evaluation failed'
      mp = m; mp(i) = m(i) - h
      CALL CD_EndConn_Energy(mp, d0, KROT, eminus, es, em)
      IF (es /= CD_ENDCONN_OK) ERROR STOP 'finite-difference energy evaluation failed'
      g(i) = (ep - eminus)/(2.0_wp*h)
    END DO
  END SUBROUTINE fd_energy_gradient

  SUBROUTINE fd_force_jacobian(m, d0, jac)
    REAL(wp), INTENT(IN) :: m(3), d0(3)
    REAL(wp), INTENT(OUT) :: jac(3, 3)
    REAL(wp) :: mp(3), fp(3), fm(3), kdum(3, 3), h
    INTEGER :: j, es
    CHARACTER(200) :: em
    DO j = 1, 3
      h = 1.0e-6_wp*MAX(ABS(m(j)), 1.0e-3_wp)
      mp = m; mp(j) = m(j) + h
      CALL CD_EndConn_Spring(mp, d0, KROT, fp, kdum, es, em)
      IF (es /= CD_ENDCONN_OK) ERROR STOP 'finite-difference spring evaluation failed'
      mp = m; mp(j) = m(j) - h
      CALL CD_EndConn_Spring(mp, d0, KROT, fm, kdum, es, em)
      IF (es /= CD_ENDCONN_OK) ERROR STOP 'finite-difference spring evaluation failed'
      jac(:, j) = (fp - fm)/(2.0_wp*h)
    END DO
  END SUBROUTINE fd_force_jacobian

END PROGRAM test_endconn_spring
