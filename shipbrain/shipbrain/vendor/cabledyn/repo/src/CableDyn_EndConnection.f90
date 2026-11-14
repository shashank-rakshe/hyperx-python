! File: src/CableDyn_EndConnection.f90
! SPDX-License-Identifier: Apache-2.0
! Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University

MODULE CableDyn_EndConnection
  !! Linear, isotropic end-bending spring for a cubic-Hermite cable tangent.
  !!
  !! The potential U = k theta**2/2 depends only on the direction of the
  !! endpoint tangent m.  Its magnitude, which carries axial stretch in the
  !! Hermite formulation, remains free.  The routines return the potential
  !! gradient and its consistent tangent for assembly in a residual written
  !! as internal minus external generalized force.
  !!
  !! This module implements the finite-stiffness constitutive law.  A pinned
  !! connection is the exact k = 0 limit.  A rigid connection is a kinematic
  !! constraint and must not be approximated by passing a very large or
  !! infinite stiffness to this module.
  USE CableDyn_Precision, ONLY: wp, CD_All_Finite, CD_Is_Finite
  IMPLICIT NONE
  PRIVATE

  PUBLIC :: CD_EndConn_Angle
  PUBLIC :: CD_EndConn_Basis
  PUBLIC :: CD_EndConn_Energy
  PUBLIC :: CD_EndConn_Project
  PUBLIC :: CD_EndConn_Reaction_Moment
  PUBLIC :: CD_EndConn_Spring
  PUBLIC :: CD_ENDCONN_OK, CD_ENDCONN_BADINPUT
  PUBLIC :: CD_ENDCONN_PINNED, CD_ENDCONN_FINITE, CD_ENDCONN_RIGID

  INTEGER, PARAMETER :: CD_ENDCONN_OK = 0
  INTEGER, PARAMETER :: CD_ENDCONN_BADINPUT = 1

  INTEGER, PARAMETER :: CD_ENDCONN_PINNED = 0
  INTEGER, PARAMETER :: CD_ENDCONN_FINITE = 1
  INTEGER, PARAMETER :: CD_ENDCONN_RIGID = 2

  REAL(wp), PARAMETER :: ZERO = 0.0_wp
  REAL(wp), PARAMETER :: ONE = 1.0_wp
  REAL(wp), PARAMETER :: SMALL_ANGLE = 1.0e-3_wp
  REAL(wp), PARAMETER :: MIN_NORM = SQRT(TINY(ONE))
  REAL(wp), PARAMETER :: ANTIPODE_TOL = 16.0_wp*SQRT(EPSILON(ONE))

CONTAINS

  PURE SUBROUTINE CD_EndConn_Basis(d0, basis, ErrStat, ErrMsg)
    !! Construct a deterministic right-handed orthonormal basis whose first
    !! column is the prescribed tangent direction.  The other two columns
    !! span the constrained transverse plane used by an exact rigid end.
    REAL(wp), INTENT(IN) :: d0(3)
    REAL(wp), INTENT(OUT) :: basis(3, 3)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg

    REAL(wp) :: d(3), seed(3), n
    INTEGER :: imin

    basis = ZERO
    ErrStat = CD_ENDCONN_OK
    ErrMsg = ''
    IF (.NOT. CD_All_Finite(d0)) THEN
      CALL fail(ErrStat, ErrMsg, 'preferred direction must be finite')
      RETURN
    END IF
    n = SQRT(DOT_PRODUCT(d0, d0))
    IF (.NOT. CD_Is_Finite(n) .OR. n <= MIN_NORM) THEN
      CALL fail(ErrStat, ErrMsg, 'preferred direction must have non-zero finite magnitude')
      RETURN
    END IF
    d = d0/n

    ! Use the coordinate direction least aligned with d.  Gram-Schmidt then
    ! retains at least sqrt(2/3) norm, avoiding a fragile near-parallel cross
    ! product while making the basis reproducible across calls.
    imin = MINLOC(ABS(d), DIM=1)
    seed = ZERO
    seed(imin) = ONE
    basis(:, 1) = d
    basis(:, 2) = seed - DOT_PRODUCT(seed, d)*d
    n = SQRT(DOT_PRODUCT(basis(:, 2), basis(:, 2)))
    basis(:, 2) = basis(:, 2)/n
    basis(:, 3) = [d(2)*basis(3, 2) - d(3)*basis(2, 2), &
                   d(3)*basis(1, 2) - d(1)*basis(3, 2), &
                   d(1)*basis(2, 2) - d(2)*basis(1, 2)]
  END SUBROUTINE CD_EndConn_Basis

  PURE SUBROUTINE CD_EndConn_Project(m, d0, projected, ErrStat, ErrMsg)
    !! Project a Hermite endpoint tangent onto the positive prescribed ray.
    !! Its magnitude is retained, so the rigid direction constraint does not
    !! clamp the axial-stretch degree of freedom carried by |m|.
    REAL(wp), INTENT(IN) :: m(3), d0(3)
    REAL(wp), INTENT(OUT) :: projected(3)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg

    REAL(wp) :: basis(3, 3), n

    projected = ZERO
    CALL CD_EndConn_Basis(d0, basis, ErrStat, ErrMsg)
    IF (ErrStat /= CD_ENDCONN_OK) RETURN
    IF (.NOT. CD_All_Finite(m)) THEN
      CALL fail(ErrStat, ErrMsg, 'endpoint tangent must be finite')
      RETURN
    END IF
    n = SQRT(DOT_PRODUCT(m, m))
    IF (.NOT. CD_Is_Finite(n) .OR. n <= MIN_NORM) THEN
      CALL fail(ErrStat, ErrMsg, 'endpoint tangent must have non-zero finite magnitude')
      RETURN
    END IF
    projected = n*basis(:, 1)
  END SUBROUTINE CD_EndConn_Project

  PURE SUBROUTINE CD_EndConn_Angle(m, d0, theta, c, s, n, d, p, ErrStat, ErrMsg)
    !! Return the angle between tangent m and preferred direction d0.
    !! d0 is normalized internally.  At the antipode the bend plane and the
    !! derivative of theta are not unique, so that state is rejected.
    REAL(wp), INTENT(IN) :: m(3), d0(3)
    REAL(wp), INTENT(OUT) :: theta, c, s, n, d(3), p(3)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg

    REAL(wp) :: d0_norm, d0_unit(3)

    CALL clear_outputs(theta, c, s, n, d, p, ErrStat, ErrMsg)

    IF (.NOT. CD_All_Finite(m)) THEN
      CALL fail(ErrStat, ErrMsg, 'endpoint tangent must be finite')
      RETURN
    END IF
    IF (.NOT. CD_All_Finite(d0)) THEN
      CALL fail(ErrStat, ErrMsg, 'preferred direction must be finite')
      RETURN
    END IF

    n = SQRT(DOT_PRODUCT(m, m))
    IF (.NOT. CD_Is_Finite(n) .OR. n <= MIN_NORM) THEN
      CALL fail(ErrStat, ErrMsg, 'endpoint tangent must have non-zero finite magnitude')
      RETURN
    END IF
    d0_norm = SQRT(DOT_PRODUCT(d0, d0))
    IF (.NOT. CD_Is_Finite(d0_norm) .OR. d0_norm <= MIN_NORM) THEN
      CALL fail(ErrStat, ErrMsg, 'preferred direction must have non-zero finite magnitude')
      RETURN
    END IF

    d = m/n
    d0_unit = d0/d0_norm
    c = MAX(-ONE, MIN(ONE, DOT_PRODUCT(d, d0_unit)))
    p = d0_unit - c*d

    ! Re-project after subtractive cancellation.  This preserves the exact
    ! no-axial-work property f_m.d = 0 close to the preferred direction.
    p = p - DOT_PRODUCT(p, d)*d
    s = SQRT(MAX(ZERO, DOT_PRODUCT(p, p)))

    IF (c < ZERO .AND. s <= ANTIPODE_TOL) THEN
      CALL fail(ErrStat, ErrMsg, &
                'endpoint tangent is antiparallel to the preferred direction; the bend plane is undefined')
      RETURN
    END IF

    theta = ATAN2(s, c)
  END SUBROUTINE CD_EndConn_Angle

  PURE SUBROUTINE CD_EndConn_Energy(m, d0, k_rot, energy, ErrStat, ErrMsg)
    !! Return U = k theta**2/2 for a finite linear end-bending spring.
    REAL(wp), INTENT(IN) :: m(3), d0(3), k_rot
    REAL(wp), INTENT(OUT) :: energy
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg

    REAL(wp) :: theta, c, s, n, d(3), p(3)

    energy = ZERO
    ErrStat = CD_ENDCONN_OK
    ErrMsg = ''
    CALL validate_stiffness(k_rot, ErrStat, ErrMsg)
    IF (ErrStat /= CD_ENDCONN_OK .OR. k_rot <= ZERO) RETURN

    CALL CD_EndConn_Angle(m, d0, theta, c, s, n, d, p, ErrStat, ErrMsg)
    IF (ErrStat /= CD_ENDCONN_OK) RETURN
    energy = 0.5_wp*k_rot*theta*theta
  END SUBROUTINE CD_EndConn_Energy

  PURE SUBROUTINE CD_EndConn_Spring(m, d0, k_rot, f_m, k_mm, ErrStat, ErrMsg)
    !! Return dU/dm and d2U/dm2 for a finite linear end-bending spring.
    REAL(wp), INTENT(IN) :: m(3), d0(3), k_rot
    REAL(wp), INTENT(OUT) :: f_m(3), k_mm(3, 3)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg

    REAL(wp) :: theta, c, s, n, d(3), p(3)
    REAL(wp) :: aa, ap_over_s, inv_n2, t2, t4
    INTEGER :: i, j

    f_m = ZERO
    k_mm = ZERO
    ErrStat = CD_ENDCONN_OK
    ErrMsg = ''
    CALL validate_stiffness(k_rot, ErrStat, ErrMsg)
    IF (ErrStat /= CD_ENDCONN_OK .OR. k_rot <= ZERO) RETURN

    CALL CD_EndConn_Angle(m, d0, theta, c, s, n, d, p, ErrStat, ErrMsg)
    IF (ErrStat /= CD_ENDCONN_OK) RETURN

    ! A = k theta/sin(theta), and (dA/dtheta)/sin(theta).  Series
    ! branches avoid cancellation at the normal, lightly bent state.
    IF (theta < SMALL_ANGLE) THEN
      t2 = theta*theta
      t4 = t2*t2
      aa = k_rot*(ONE + t2/6.0_wp + 7.0_wp*t4/360.0_wp)
      ap_over_s = k_rot*(ONE/3.0_wp + 2.0_wp*t2/15.0_wp + &
                         2.0_wp*t4/63.0_wp)
    ELSE
      aa = k_rot*theta/s
      ap_over_s = k_rot*(s - theta*c)/(s*s*s)
    END IF

    inv_n2 = ONE/(n*n)
    f_m = -(aa/n)*p

    DO j = 1, 3
      DO i = 1, 3
        k_mm(i, j) = inv_n2*( &
                     aa*(p(i)*d(j) + d(i)*p(j)) + &
                     aa*c*(MERGE(ONE, ZERO, i == j) - d(i)*d(j)) + &
                     ap_over_s*p(i)*p(j))
      END DO
    END DO
  END SUBROUTINE CD_EndConn_Spring

  PURE SUBROUTINE CD_EndConn_Reaction_Moment(m, f_m, moment, ErrStat, ErrMsg)
    !! Return the moment exerted by the cable on the supporting body.
    !! If f_m = dU/dm is assembled as an internal residual, virtual work gives
    !! the equal-and-opposite support reaction as m cross f_m.
    REAL(wp), INTENT(IN) :: m(3), f_m(3)
    REAL(wp), INTENT(OUT) :: moment(3)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg

    moment = ZERO
    ErrStat = CD_ENDCONN_OK
    ErrMsg = ''
    IF (.NOT. CD_All_Finite(m) .OR. .NOT. CD_All_Finite(f_m)) THEN
      CALL fail(ErrStat, ErrMsg, 'tangent and generalized force must be finite')
      RETURN
    END IF
    moment(1) = m(2)*f_m(3) - m(3)*f_m(2)
    moment(2) = m(3)*f_m(1) - m(1)*f_m(3)
    moment(3) = m(1)*f_m(2) - m(2)*f_m(1)
  END SUBROUTINE CD_EndConn_Reaction_Moment

  PURE SUBROUTINE validate_stiffness(k_rot, ErrStat, ErrMsg)
    REAL(wp), INTENT(IN) :: k_rot
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg

    ErrStat = CD_ENDCONN_OK
    ErrMsg = ''
    IF (.NOT. CD_Is_Finite(k_rot)) THEN
      CALL fail(ErrStat, ErrMsg, &
                'rotational stiffness must be finite; use a kinematic constraint for a rigid connection')
    ELSE IF (k_rot < ZERO) THEN
      CALL fail(ErrStat, ErrMsg, 'rotational stiffness must be non-negative')
    END IF
  END SUBROUTINE validate_stiffness

  PURE SUBROUTINE clear_outputs(theta, c, s, n, d, p, ErrStat, ErrMsg)
    REAL(wp), INTENT(OUT) :: theta, c, s, n, d(3), p(3)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg

    theta = ZERO
    c = ONE
    s = ZERO
    n = ZERO
    d = ZERO
    p = ZERO
    ErrStat = CD_ENDCONN_OK
    ErrMsg = ''
  END SUBROUTINE clear_outputs

  PURE SUBROUTINE fail(ErrStat, ErrMsg, msg)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    CHARACTER(*), INTENT(IN) :: msg

    ErrStat = CD_ENDCONN_BADINPUT
    ErrMsg = 'CableDyn_EndConnection: '//msg
  END SUBROUTINE fail

END MODULE CableDyn_EndConnection
