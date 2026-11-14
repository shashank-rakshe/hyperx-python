! File: tests/test_rigid_kinematics.f90
! SPDX-License-Identifier: Apache-2.0
! Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
PROGRAM test_rigid_kinematics
  !! Unit checks for CableDyn_RigidKinematics, the OpenFAST-style rigid platform
  !! to fairlead-point motion/load transfer helper described in
  !! doc/coupling_boundary.md.
  USE CableDyn_Precision, ONLY: wp
  USE CableDyn_RigidKinematics, ONLY: CD_Rigid_Points_From_Body, CD_Rigid_Wrench_From_Point_Loads, &
                                      CD_Rigid_Advance_Constant_Acceleration, CD_RIGID_OK, CD_RIGID_BADINPUT
  USE CableDyn_SO3, ONLY: CD_Exp_SO3, CD_Log_SO3
  USE, INTRINSIC :: IEEE_ARITHMETIC, ONLY: IEEE_VALUE, IEEE_QUIET_NAN
  IMPLICIT NONE

  INTEGER :: nfail
  nfail = 0

  CALL case_translation_and_spin()
  CALL case_rotation_and_wrench()
  CALL case_finite_rotation_advance()
  CALL case_fail_closed()

  IF (nfail > 0) THEN
    WRITE (*, '(A,I0,A)') 'FAIL: ', nfail, ' assertion(s) failed'
    ERROR STOP 1
  END IF
  WRITE (*, '(A)') 'PASS: rigid platform/fairlead kinematic transfer'

CONTAINS

  INCLUDE 'nan_max_abs.inc'

  SUBROUTINE case_translation_and_spin()
    REAL(wp) :: bq(6), bv(6), ba(6), offsets(3, 2), q(6), v(6), a(6)
    INTEGER :: es
    CHARACTER(160) :: em

    bq = [10.0_wp, 20.0_wp, -5.0_wp, 0.0_wp, 0.0_wp, 0.0_wp]
    bv = [1.0_wp, 2.0_wp, 3.0_wp, 0.0_wp, 0.0_wp, 2.0_wp]
    ba = [0.1_wp, 0.2_wp, 0.3_wp, 0.0_wp, 1.0_wp, 0.0_wp]
    offsets(:, 1) = [2.0_wp, 0.0_wp, 0.0_wp]
    offsets(:, 2) = [0.0_wp, -1.0_wp, 0.0_wp]

    CALL CD_Rigid_Points_From_Body(bq, bv, ba, offsets, q, v, a, es, em)
    CALL require(es == CD_RIGID_OK, 'spin:ok')
    CALL require(nan_max_abs(q(1:3) - [12.0_wp, 20.0_wp, -5.0_wp]) < 1.0e-12_wp, 'spin:q1')
    CALL require(nan_max_abs(v(1:3) - [1.0_wp, 6.0_wp, 3.0_wp]) < 1.0e-12_wp, 'spin:v1')
    CALL require(nan_max_abs(a(1:3) - [-7.9_wp, 0.2_wp, -1.7_wp]) < 1.0e-12_wp, 'spin:a1')
    CALL require(nan_max_abs(q(4:6) - [10.0_wp, 19.0_wp, -5.0_wp]) < 1.0e-12_wp, 'spin:q2')
    CALL require(nan_max_abs(v(4:6) - [3.0_wp, 2.0_wp, 3.0_wp]) < 1.0e-12_wp, 'spin:v2')
  END SUBROUTINE case_translation_and_spin

  SUBROUTINE case_rotation_and_wrench()
    REAL(wp) :: bq(6), bv(6), ba(6), offsets(3, 2), q(6), v(6), a(6), loads(6), wrench(6)
    INTEGER :: es
    CHARACTER(160) :: em

    bq = [0.0_wp, 0.0_wp, 0.0_wp, 0.0_wp, 0.0_wp, 1.57079632679489661923_wp]
    bv = 0.0_wp
    ba = 0.0_wp
    offsets(:, 1) = [1.0_wp, 0.0_wp, 0.0_wp]
    offsets(:, 2) = [0.0_wp, 2.0_wp, 0.0_wp]
    CALL CD_Rigid_Points_From_Body(bq, bv, ba, offsets, q, v, a, es, em)
    CALL require(es == CD_RIGID_OK, 'rot:ok')
    CALL require(nan_max_abs(q(1:3) - [0.0_wp, 1.0_wp, 0.0_wp]) < 1.0e-12_wp, 'rot:q1')
    CALL require(nan_max_abs(q(4:6) - [-2.0_wp, 0.0_wp, 0.0_wp]) < 1.0e-12_wp, 'rot:q2')

    loads = [0.0_wp, 0.0_wp, 10.0_wp, 0.0_wp, 5.0_wp, 0.0_wp]
    CALL CD_Rigid_Wrench_From_Point_Loads(bq, offsets, loads, wrench, es, em)
    CALL require(es == CD_RIGID_OK, 'wrench:ok')
    CALL require(nan_max_abs(wrench(1:3) - [0.0_wp, 5.0_wp, 10.0_wp]) < 1.0e-12_wp, 'wrench:force')
    CALL require(nan_max_abs(wrench(4:6) - [10.0_wp, 0.0_wp, -10.0_wp]) < 1.0e-12_wp, 'wrench:moment')
  END SUBROUTINE case_rotation_and_wrench

  SUBROUTINE case_finite_rotation_advance()
    REAL(wp) :: pos(3), vel(3), rot(3, 3), omega(3), acc(3), alpha(3), rot_ref(3, 3), rtr(3, 3)
    REAL(wp) :: dt, total
    INTEGER :: i, es
    CHARACTER(160) :: em

    pos = [1.0_wp, -2.0_wp, 0.5_wp]
    vel = [0.4_wp, -0.2_wp, 0.1_wp]
    rot = eye3()
    omega = [0.0_wp, 0.0_wp, 3.0_wp]
    acc = [0.2_wp, 0.0_wp, -0.4_wp]
    alpha = 0.0_wp
    dt = 0.05_wp
    DO i = 1, 20
      CALL CD_Rigid_Advance_Constant_Acceleration(pos, vel, rot, omega, acc, alpha, dt, es, em)
      CALL require(es == CD_RIGID_OK, 'advance:ok')
    END DO
    total = 20.0_wp*dt
    rot_ref = CD_Exp_SO3([0.0_wp, 0.0_wp, 3.0_wp*total])
    rtr = MATMUL(TRANSPOSE(rot), rot)
    CALL require(nan_max_abs(rot - rot_ref) < 1.0e-12_wp, 'advance:finite-spin')
    CALL require(nan_max_abs(rtr - eye3()) < 1.0e-12_wp, 'advance:orthonormal')
    ! symplectic (semi-implicit) Euler: v first, then x with the new v, so N steps of a
    ! constant acceleration give x0 + v0*T + 0.5*a*T*T*(1 + 1/N)
    CALL require(nan_max_abs(pos - ([1.0_wp, -2.0_wp, 0.5_wp] + total*[0.4_wp, -0.2_wp, 0.1_wp] + &
                                    0.5_wp*total*total*(1.0_wp + 1.0_wp/20.0_wp)*acc)) < 1.0e-12_wp, &
                 'advance:translation')

    CALL CD_Rigid_Advance_Constant_Acceleration(pos, vel, rot, omega, acc, alpha, -dt, es, em)
    CALL require(es == CD_RIGID_BADINPUT, 'advance:negative-dt')
    CALL case_explicit_oscillator_stability()
  END SUBROUTINE case_finite_rotation_advance

  SUBROUTINE case_explicit_oscillator_stability()
    !! A body on a spring, advanced with the load evaluated at the start of each step (the
    !! partitioned body-line coupling). The update must not pump energy: the Taylor
    !! constant-acceleration step x += v*dt + a*dt^2/2, v += a*dt has |lambda|^2 =
    !! 1 + (w*dt)^2/2 and grows at ANY dt (a Rigid6 buoy grew at dtM = 0.02 s and diverged
    !! at 0.05 s); the symplectic update stays bounded for w*dt < 2, in rotation as well.
    REAL(wp) :: pos(3), vel(3), rot(3, 3), omega(3), acc(3), alpha(3), peak, peak_rot, theta(3)
    REAL(wp), PARAMETER :: W = 10.0_wp, DT = 0.05_wp
    INTEGER :: i, es
    CHARACTER(160) :: em

    pos = [1.0_wp, 0.0_wp, 0.0_wp]
    vel = 0.0_wp
    rot = CD_Exp_SO3([0.1_wp, 0.0_wp, 0.0_wp])
    omega = 0.0_wp
    peak = 0.0_wp
    peak_rot = 0.0_wp
    DO i = 1, 4000
      acc = -W*W*pos
      theta = CD_Log_SO3(rot)
      alpha = -W*W*theta
      CALL CD_Rigid_Advance_Constant_Acceleration(pos, vel, rot, omega, acc, alpha, DT, es, em)
      IF (es /= CD_RIGID_OK) EXIT
      peak = MAX(peak, ABS(pos(1)))
      peak_rot = MAX(peak_rot, NORM2(CD_Log_SO3(rot)))
    END DO
    CALL require(es == CD_RIGID_OK, 'oscillator:advance-ok')
    CALL require(peak < 1.2_wp .AND. peak_rot < 0.12_wp, 'oscillator:explicit body update does not pump energy')
  END SUBROUTINE case_explicit_oscillator_stability

  SUBROUTINE case_fail_closed()
    REAL(wp) :: bq(6), bv(6), ba(6), offsets(3, 1), q_bad(4), v_bad(3), a_bad(3), loads_bad(2), wrench(6)
    INTEGER :: es
    CHARACTER(160) :: em

    bq = 0.0_wp
    bv = 0.0_wp
    ba = 0.0_wp
    offsets = 0.0_wp
    q_bad = 9.0_wp
    v_bad = 9.0_wp
    a_bad = 9.0_wp
    CALL CD_Rigid_Points_From_Body(bq, bv, ba, offsets, q_bad, v_bad, a_bad, es, em)
    CALL require(es == CD_RIGID_BADINPUT, 'fail:shape')
    CALL require(nan_max_abs(q_bad) < TINY(1.0_wp) .AND. nan_max_abs(v_bad) < TINY(1.0_wp) .AND. &
                 nan_max_abs(a_bad) < TINY(1.0_wp), 'fail:shape-zeroed-outputs')
    CALL CD_Rigid_Wrench_From_Point_Loads(bq, offsets, loads_bad, wrench, es, em)
    CALL require(es == CD_RIGID_BADINPUT, 'fail:loads-shape')
    bq(1) = IEEE_VALUE(0.0_wp, IEEE_QUIET_NAN)
    CALL CD_Rigid_Wrench_From_Point_Loads(bq, offsets, [1.0_wp, 2.0_wp, 3.0_wp], wrench, es, em)
    CALL require(es == CD_RIGID_BADINPUT, 'fail:nonfinite')
  END SUBROUTINE case_fail_closed

  SUBROUTINE require(cond, label)
    LOGICAL, INTENT(IN) :: cond
    CHARACTER(*), INTENT(IN) :: label
    IF (.NOT. cond) THEN
      WRITE (*, '(A,A,A)') 'MISMATCH [', TRIM(label), ']: condition false'
      nfail = nfail + 1
    END IF
  END SUBROUTINE require

  PURE FUNCTION eye3() RESULT(I)
    REAL(wp) :: I(3, 3)
    I = 0.0_wp
    I(1, 1) = 1.0_wp
    I(2, 2) = 1.0_wp
    I(3, 3) = 1.0_wp
  END FUNCTION eye3

END PROGRAM test_rigid_kinematics
