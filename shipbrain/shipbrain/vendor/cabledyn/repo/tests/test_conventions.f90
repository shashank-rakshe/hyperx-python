! File: tests/test_conventions.f90
! SPDX-License-Identifier: Apache-2.0
! Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
PROGRAM test_conventions
  !! Verifies the shared CableDyn convention helpers (CableDyn_Conventions) against
  !! the OrcaFlex 11.5 rules frozen in doc/conventions.rst sections 7-8:
  !!   - direction vector from azimuth/declination (cardinal directions + |v|=1);
  !!   - line-end attitude is the intrinsic z-y'-z'' sequence, and its tangent
  !!     (column 3) equals the direction vector for any gamma;
  !!   - 6D-body attitude is the intrinsic x-y'-z'' sequence (a DIFFERENT sequence);
  !!   - both rotations are proper (R^T R = I, det = +1);
  !!   - deg/rad round-trip.
  USE CableDyn_Precision, ONLY: wp
  USE CableDyn_Conventions, ONLY: CD_Direction_Vector, CD_LineEnd_Rotation, &
                                  CD_Body_Rotation, CD_Deg2Rad, CD_Rad2Deg
  IMPLICIT NONE

  REAL(wp), PARAMETER :: TOL = 1.0e-12_wp
  INTEGER :: nfail
  REAL(wp) :: v(3), R(3, 3), Rb(3, 3)
  nfail = 0

  ! --- direction vector: cardinal directions (azimuth +GX->+GY, declination from +GZ) ---
  CALL check_vec(CD_Direction_Vector(0.0_wp, 90.0_wp), [1.0_wp, 0.0_wp, 0.0_wp], 'dir az0 dec90 = +GX')
  CALL check_vec(CD_Direction_Vector(90.0_wp, 90.0_wp), [0.0_wp, 1.0_wp, 0.0_wp], 'dir az90 dec90 = +GY')
  CALL check_vec(CD_Direction_Vector(0.0_wp, 0.0_wp), [0.0_wp, 0.0_wp, 1.0_wp], 'dir dec0 = +GZ (up)')
  CALL check_vec(CD_Direction_Vector(0.0_wp, 180.0_wp), [0.0_wp, 0.0_wp, -1.0_wp], 'dir dec180 = -GZ (down)')
  CALL check_vec(CD_Direction_Vector(180.0_wp, 90.0_wp), [-1.0_wp, 0.0_wp, 0.0_wp], 'dir az180 dec90 = -GX')
  ! arbitrary direction is a unit vector
  v = CD_Direction_Vector(37.0_wp, 53.0_wp)
  CALL require(ABS(NORM2(v) - 1.0_wp) < TOL, 'dir |v| = 1')

  ! --- line-end attitude: intrinsic z-y'-z'' ---
  ! column 3 (the end tangent) equals the direction vector, independent of gamma (the twist).
  R = CD_LineEnd_Rotation(37.0_wp, 53.0_wp, 0.0_wp)
  CALL check_vec(R(:, 3), CD_Direction_Vector(37.0_wp, 53.0_wp), 'line-end tangent = dir (gamma 0)')
  R = CD_LineEnd_Rotation(37.0_wp, 53.0_wp, 64.0_wp)
  CALL check_vec(R(:, 3), CD_Direction_Vector(37.0_wp, 53.0_wp), 'line-end tangent = dir (gamma 64)')
  ! a pure-azimuth, horizontal end points its tangent along +GY
  R = CD_LineEnd_Rotation(90.0_wp, 90.0_wp, 0.0_wp)
  CALL check_vec(R(:, 3), [0.0_wp, 1.0_wp, 0.0_wp], 'line-end az90 dec90 tangent = +GY')
  CALL check_proper(R, 'line-end is proper rotation')
  CALL check_proper(CD_LineEnd_Rotation(11.0_wp, 200.0_wp, -45.0_wp), 'line-end proper (general)')

  ! --- 6D-body attitude: intrinsic x-y'-z'' (a DIFFERENT sequence) ---
  ! Rx(90): +GY -> +GZ
  R = CD_Body_Rotation(90.0_wp, 0.0_wp, 0.0_wp)
  CALL check_vec(MATMUL(R, [0.0_wp, 1.0_wp, 0.0_wp]), [0.0_wp, 0.0_wp, 1.0_wp], 'body rot1=90 maps +GY->+GZ')
  ! Rz(90): +GX -> +GY
  R = CD_Body_Rotation(0.0_wp, 0.0_wp, 90.0_wp)
  CALL check_vec(MATMUL(R, [1.0_wp, 0.0_wp, 0.0_wp]), [0.0_wp, 1.0_wp, 0.0_wp], 'body rot3=90 maps +GX->+GY')
  CALL check_proper(CD_Body_Rotation(30.0_wp, 40.0_wp, 50.0_wp), 'body is proper rotation')

  ! the two sequences are genuinely distinct: same angles, different rotation
  R = CD_LineEnd_Rotation(30.0_wp, 40.0_wp, 50.0_wp)
  Rb = CD_Body_Rotation(30.0_wp, 40.0_wp, 50.0_wp)
  CALL require(nan_max_abs(R - Rb) > 1.0e-3_wp, 'line-end and body sequences differ')

  ! --- degree/radian round-trip ---
  CALL require(ABS(CD_Rad2Deg(CD_Deg2Rad(123.456_wp)) - 123.456_wp) < TOL, 'deg<->rad round-trip')
  CALL require(ABS(CD_Deg2Rad(180.0_wp) - 3.14159265358979323846_wp) < TOL, 'deg2rad(180) = pi')

  IF (nfail > 0) THEN
    WRITE (*, '(A,I0,A)') 'FAIL: ', nfail, ' assertion(s) failed'
    ERROR STOP 1
  END IF
  WRITE (*, '(A)') 'PASS: CableDyn convention helpers match doc/conventions.rst (OrcaFlex 11.5)'

CONTAINS

  INCLUDE 'nan_max_abs.inc'

  SUBROUTINE check_vec(got, want_vec, label)
    REAL(wp), INTENT(IN) :: got(3), want_vec(3)
    CHARACTER(*), INTENT(IN) :: label
    CALL require(nan_max_abs(got - want_vec) < TOL, label)
  END SUBROUTINE check_vec

  SUBROUTINE check_proper(R, label)
    !! A proper rotation: R^T R = I and det(R) = +1.
    REAL(wp), INTENT(IN) :: R(3, 3)
    CHARACTER(*), INTENT(IN) :: label
    REAL(wp) :: RtR(3, 3), det
    INTEGER :: k
    RtR = MATMUL(TRANSPOSE(R), R)
    DO k = 1, 3
      RtR(k, k) = RtR(k, k) - 1.0_wp
    END DO
    det = R(1, 1)*(R(2, 2)*R(3, 3) - R(2, 3)*R(3, 2)) &
          - R(1, 2)*(R(2, 1)*R(3, 3) - R(2, 3)*R(3, 1)) &
          + R(1, 3)*(R(2, 1)*R(3, 2) - R(2, 2)*R(3, 1))
    CALL require(nan_max_abs(RtR) < TOL .AND. ABS(det - 1.0_wp) < TOL, label)
  END SUBROUTINE check_proper

  SUBROUTINE require(cond, label)
    LOGICAL, INTENT(IN) :: cond
    CHARACTER(*), INTENT(IN) :: label
    IF (.NOT. cond) THEN
      WRITE (*, '(A,A,A)') 'MISMATCH [', label, ']: condition false'
      nfail = nfail + 1
    END IF
  END SUBROUTINE require

END PROGRAM test_conventions
