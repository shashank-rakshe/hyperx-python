! File: src/CableDyn_RigidKinematics.f90
! SPDX-License-Identifier: Apache-2.0
! Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
MODULE CableDyn_RigidKinematics
  !! Rigid-body coupling helpers for OpenFAST-style platform/fairlead exchange.
  !!
  !! This module corresponds to doc/coupling_boundary.md: a host supplies a
  !! 6-DOF platform pose/rate/acceleration and CableDyn consumes point kinematics
  !! at fairlead offsets. The inverse load map sums point reactions back to a
  !! platform force/moment wrench. Rotations use the same SO(3) exponential-map
  !! convention as the core.
  USE CableDyn_Precision, ONLY: wp, CD_ZERO, CD_All_Finite, CD_Is_Finite
  USE CableDyn_SO3, ONLY: CD_Exp_SO3
  IMPLICIT NONE
  PRIVATE

  PUBLIC :: CD_Rigid_Points_From_Body
  PUBLIC :: CD_Rigid_Wrench_From_Point_Loads
  PUBLIC :: CD_Rigid_Advance_Constant_Acceleration
  PUBLIC :: CD_Rigid_Advance_Newmark

  INTEGER, PARAMETER, PUBLIC :: CD_RIGID_OK = 0
  INTEGER, PARAMETER, PUBLIC :: CD_RIGID_BADINPUT = 1
  !> Newmark parameters of the free rigid-body (rod / Rigid6) update: central difference
  REAL(wp), PARAMETER, PUBLIC :: CD_RIGID_NEWMARK_GAMMA = 0.5_wp
  REAL(wp), PARAMETER, PUBLIC :: CD_RIGID_NEWMARK_BETA = 0.0_wp

CONTAINS

  SUBROUTINE CD_Rigid_Points_From_Body(body_q, body_v, body_a, offsets_body, q_points, v_points, a_points, &
                                       ErrStat, ErrMsg)
    !! Map a body 6-DOF state to point kinematics at body-frame offsets.
    !!
    !! body_q = [r, theta], body_v = [v, omega], body_a = [a, alpha], where theta
    !! is a rotation vector and omega/alpha are spatial angular velocity and
    !! acceleration. For offset ell in the body frame:
    !!   x = r + R(theta) ell
    !!   v = v_body + omega x R ell
    !!   a = a_body + alpha x R ell + omega x (omega x R ell)
    REAL(wp), INTENT(IN) :: body_q(6), body_v(6), body_a(6)
    REAL(wp), INTENT(IN) :: offsets_body(:, :)
    REAL(wp), INTENT(OUT) :: q_points(:), v_points(:), a_points(:)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg

    INTEGER :: n, i, base
    REAL(wp) :: R(3, 3), arm(3), om(3), al(3)

    q_points = CD_ZERO
    v_points = CD_ZERO
    a_points = CD_ZERO
    CALL validate_point_arrays(body_q, body_v, body_a, offsets_body, q_points, v_points, a_points, ErrStat, ErrMsg)
    IF (ErrStat /= CD_RIGID_OK) RETURN
    n = SIZE(offsets_body, 2)
    R = CD_Exp_SO3(body_q(4:6))
    om = body_v(4:6)
    al = body_a(4:6)
    DO i = 1, n
      base = 3*i - 2
      arm = MATMUL(R, offsets_body(:, i))
      q_points(base:base + 2) = body_q(1:3) + arm
      v_points(base:base + 2) = body_v(1:3) + cross(om, arm)
      a_points(base:base + 2) = body_a(1:3) + cross(al, arm) + cross(om, cross(om, arm))
    END DO
  END SUBROUTINE CD_Rigid_Points_From_Body

  SUBROUTINE CD_Rigid_Wrench_From_Point_Loads(body_q, offsets_body, point_loads, body_wrench, ErrStat, ErrMsg)
    !! Sum point loads into a body-frame coupling wrench in global components.
    !!
    !! For each point reaction F_i applied at global arm R(theta) ell_i, the body
    !! reaction is [sum F_i, sum arm_i x F_i].
    REAL(wp), INTENT(IN) :: body_q(6)
    REAL(wp), INTENT(IN) :: offsets_body(:, :)
    REAL(wp), INTENT(IN) :: point_loads(:)
    REAL(wp), INTENT(OUT) :: body_wrench(6)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg

    INTEGER :: n, i, base
    REAL(wp) :: R(3, 3), arm(3), force(3)

    body_wrench = CD_ZERO
    ErrStat = CD_RIGID_OK
    ErrMsg = ''
    IF (SIZE(offsets_body, 1) /= 3) THEN
      CALL fail(ErrStat, ErrMsg, 'CD_Rigid_Wrench_From_Point_Loads: offsets_body must have shape (3,n)')
      RETURN
    END IF
    n = SIZE(offsets_body, 2)
    IF (SIZE(point_loads) /= 3*n) THEN
      CALL fail(ErrStat, ErrMsg, 'CD_Rigid_Wrench_From_Point_Loads: point_loads must have length 3*n')
      RETURN
    END IF
    IF (.NOT. (CD_All_Finite(body_q) .AND. CD_All_Finite(offsets_body) .AND. &
               CD_All_Finite(point_loads))) THEN
      CALL fail(ErrStat, ErrMsg, 'CD_Rigid_Wrench_From_Point_Loads: inputs must be finite')
      RETURN
    END IF
    R = CD_Exp_SO3(body_q(4:6))
    DO i = 1, n
      base = 3*i - 2
      arm = MATMUL(R, offsets_body(:, i))
      force = point_loads(base:base + 2)
      body_wrench(1:3) = body_wrench(1:3) + force
      body_wrench(4:6) = body_wrench(4:6) + cross(arm, force)
    END DO
  END SUBROUTINE CD_Rigid_Wrench_From_Point_Loads

  SUBROUTINE CD_Rigid_Advance_Constant_Acceleration(r, v, rot_mat, omega, acc, alpha, dt, ErrStat, ErrMsg)
    !! Advance a free rigid state over one step with the spatial translational and
    !! angular accelerations held from the start of the step, by the symplectic
    !! (semi-implicit) Euler update:
    !!   v_{n+1} = v_n + dt*a_n,             r_{n+1} = r_n + dt*v_{n+1}
    !!   omega_{n+1} = omega_n + dt*alpha_n,  R_{n+1} = exp(dt*omega_{n+1}) R_n
    !! Rotation is updated on SO(3), not by accumulating Euler parameters. The loads
    !! come from the start of the step (partitioned body-line coupling), so the update
    !! must not pump energy: the Taylor step r += dt*v + dt^2*a/2, v += dt*a amplifies an
    !! undamped mode by |lambda|^2 = 1 + (w*dt)^2/2 per step at any dt, while this update
    !! is neutrally stable for w*dt < 2. (Deck Rigid6 bodies and rods use
    !! CD_Rigid_Advance_Newmark.)
    REAL(wp), INTENT(INOUT) :: r(3), v(3), rot_mat(3, 3), omega(3)
    REAL(wp), INTENT(IN) :: acc(3), alpha(3), dt
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg

    REAL(wp) :: delta_theta(3), exp_rot(3, 3), rot_new(3, 3)

    ErrStat = CD_RIGID_OK
    ErrMsg = ''
    IF (.NOT. (CD_Is_Finite(dt) .AND. dt >= CD_ZERO .AND. CD_All_Finite(r) .AND. &
               CD_All_Finite(v) .AND. CD_All_Finite(rot_mat) .AND. &
               CD_All_Finite(omega) .AND. CD_All_Finite(acc) .AND. &
               CD_All_Finite(alpha))) THEN
      CALL fail(ErrStat, ErrMsg, 'CD_Rigid_Advance_Constant_Acceleration: inputs must be finite with dt >= 0')
      RETURN
    END IF

    v = v + dt*acc
    r = r + dt*v
    omega = omega + dt*alpha
    delta_theta = dt*omega
    ! through fixed-size locals: the product must not overwrite its own operand
    exp_rot = CD_Exp_SO3(delta_theta)
    rot_new = MATMUL(exp_rot, rot_mat)
    rot_mat = rot_new
  END SUBROUTINE CD_Rigid_Advance_Constant_Acceleration

  SUBROUTINE CD_Rigid_Advance_Newmark(r, v, rot_mat, omega, acc_old, alpha_old, acc, alpha, dt, gamma, beta, &
                                      ErrStat, ErrMsg)
    !! Advance a free rigid state over one step by the Newmark update with the start-of-step
    !! accelerations (acc_old, alpha_old) and the end-of-step accelerations (acc, alpha):
    !!   r_{n+1} = r_n + dt*v_n + dt^2*((1/2 - beta)*a_n + beta*a_{n+1})
    !!   v_{n+1} = v_n + dt*((1 - gamma)*a_n + gamma*a_{n+1})
    !! and the same map for the spatial rotation increment theta (R_{n+1} = exp(theta) R_n) and
    !! omega. gamma = 1/2 is second-order accurate and free of numerical damping, so a resolved
    !! response does not depend on dt through an artificial dissipation of order omega*dt;
    !! beta = 0 (central difference) makes the position explicit, which the deck driver's
    !! staggered body-line coupling uses so the lines are solved at the body's final position.
    REAL(wp), INTENT(INOUT) :: r(3), v(3), rot_mat(3, 3), omega(3)
    REAL(wp), INTENT(IN) :: acc_old(3), alpha_old(3), acc(3), alpha(3), dt, gamma, beta
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg

    REAL(wp) :: delta_theta(3), exp_rot(3, 3), rot_new(3, 3)

    ErrStat = CD_RIGID_OK
    ErrMsg = ''
    IF (.NOT. (CD_Is_Finite(dt) .AND. dt >= CD_ZERO .AND. CD_Is_Finite(gamma) .AND. &
               CD_Is_Finite(beta) .AND. CD_All_Finite(r) .AND. CD_All_Finite(v) .AND. &
               CD_All_Finite(rot_mat) .AND. CD_All_Finite(omega) .AND. &
               CD_All_Finite(acc_old) .AND. CD_All_Finite(alpha_old) .AND. &
               CD_All_Finite(acc) .AND. CD_All_Finite(alpha))) THEN
      CALL fail(ErrStat, ErrMsg, 'CD_Rigid_Advance_Newmark: inputs must be finite with dt >= 0')
      RETURN
    END IF

    r = r + dt*v + dt*dt*((0.5_wp - beta)*acc_old + beta*acc)
    v = v + dt*((1.0_wp - gamma)*acc_old + gamma*acc)
    delta_theta = dt*omega + dt*dt*((0.5_wp - beta)*alpha_old + beta*alpha)
    omega = omega + dt*((1.0_wp - gamma)*alpha_old + gamma*alpha)
    ! through fixed-size locals: the product must not overwrite its own operand
    exp_rot = CD_Exp_SO3(delta_theta)
    rot_new = MATMUL(exp_rot, rot_mat)
    rot_mat = rot_new
  END SUBROUTINE CD_Rigid_Advance_Newmark

  SUBROUTINE validate_point_arrays(body_q, body_v, body_a, offsets_body, q_points, v_points, a_points, ErrStat, ErrMsg)
    REAL(wp), INTENT(IN) :: body_q(6), body_v(6), body_a(6)
    REAL(wp), INTENT(IN) :: offsets_body(:, :)
    REAL(wp), INTENT(IN) :: q_points(:), v_points(:), a_points(:)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg

    INTEGER :: n

    ErrStat = CD_RIGID_OK
    ErrMsg = ''
    IF (SIZE(offsets_body, 1) /= 3) THEN
      CALL fail(ErrStat, ErrMsg, 'CD_Rigid_Points_From_Body: offsets_body must have shape (3,n)')
      RETURN
    END IF
    n = SIZE(offsets_body, 2)
    IF (SIZE(q_points) /= 3*n .OR. SIZE(v_points) /= 3*n .OR. SIZE(a_points) /= 3*n) THEN
      CALL fail(ErrStat, ErrMsg, 'CD_Rigid_Points_From_Body: point arrays must each have length 3*n')
      RETURN
    END IF
    IF (.NOT. (CD_All_Finite(body_q) .AND. CD_All_Finite(body_v) .AND. &
               CD_All_Finite(body_a) .AND. CD_All_Finite(offsets_body))) THEN
      CALL fail(ErrStat, ErrMsg, 'CD_Rigid_Points_From_Body: inputs must be finite')
      RETURN
    END IF
  END SUBROUTINE validate_point_arrays

  PURE FUNCTION cross(a, b) RESULT(c)
    REAL(wp), INTENT(IN) :: a(3), b(3)
    REAL(wp) :: c(3)
    c = [a(2)*b(3) - a(3)*b(2), a(3)*b(1) - a(1)*b(3), a(1)*b(2) - a(2)*b(1)]
  END FUNCTION cross

  SUBROUTINE fail(ErrStat, ErrMsg, msg)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    CHARACTER(*), INTENT(IN) :: msg
    ErrStat = CD_RIGID_BADINPUT
    ErrMsg = 'CableDyn_RigidKinematics: '//msg
  END SUBROUTINE fail

END MODULE CableDyn_RigidKinematics
