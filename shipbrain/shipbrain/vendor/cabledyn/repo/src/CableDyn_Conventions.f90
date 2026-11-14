! File: src/CableDyn_Conventions.f90
! SPDX-License-Identifier: Apache-2.0
! Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
!
MODULE CableDyn_Conventions
  !! Shared CableDyn input/output conventions, in code (doc/conventions.rst is the
  !! canonical prose). Codifies the direction and orientation rules so every deck
  !! parser and coupling shell resolves them identically:
  !!
  !!   - CD_Direction_Vector  : (azimuth, declination) [deg] -> unit vector.
  !!   - CD_LineEnd_Rotation  : line-end / constraint attitude, intrinsic z-y'-z''
  !!                            (azimuth / declination / gamma) [deg] -> R in SO(3).
  !!   - CD_Body_Rotation     : 6D-body attitude, intrinsic x-y'-z''
  !!                            (rotation1 / 2 / 3) [deg] -> R in SO(3).
  !!   - CD_CHANNEL_FMT, CD_NATIVE_CHANNEL_FMT : the channel-value formats of the
  !!                            time-series files (three-digit exponent).
  !!
  !! These are the OrcaFlex 11.5 conventions (frames right-handed, GZ up; azimuth
  !! +GX->+GY; declination from +GZ). The two Euler sequences are deliberately
  !! distinct (the common modelling trap) -- see doc/conventions.rst, *Orientation angles*.
  !! Rotations are built from CD_Exp_SO3 so the result matches the core's
  !! multiplicative SO(3) rotation convention exactly.
  USE CableDyn_Precision, ONLY: wp
  USE CableDyn_SO3, ONLY: CD_Exp_SO3
  IMPLICIT NONE
  PRIVATE
  PUBLIC :: CD_Direction_Vector, CD_LineEnd_Rotation, CD_Body_Rotation
  PUBLIC :: CD_Deg2Rad, CD_Rad2Deg
  PUBLIC :: CD_CHANNEL_FMT, CD_NATIVE_CHANNEL_FMT

  ! One TAB-separated channel value of a time-series row: the standalone .out files (8
  ! significant digits) and OpenFAST's native <root>.CD.out (7). The exponent field has three
  ! digits: with two, a magnitude below 1e-99 or at 1e100 and above (the round-off noise of a
  ! component that is zero, such as the y position of a line in the x-z plane) fills the field
  ! with asterisks, and without a stated width the exponent letter is dropped.
  CHARACTER(*), PARAMETER :: CD_CHANNEL_FMT = '(A,ES15.7E3)'
  CHARACTER(*), PARAMETER :: CD_NATIVE_CHANNEL_FMT = '(A,ES15.6E3)'

  REAL(wp), PARAMETER :: CD_PI = 3.14159265358979323846_wp
  REAL(wp), PARAMETER :: CD_RAD_PER_DEG = CD_PI/180.0_wp

CONTAINS

  PURE FUNCTION CD_Deg2Rad(deg) RESULT(rad)
    !! Degrees -> radians.
    REAL(wp), INTENT(IN) :: deg
    REAL(wp) :: rad
    rad = deg*CD_RAD_PER_DEG
  END FUNCTION CD_Deg2Rad

  PURE FUNCTION CD_Rad2Deg(rad) RESULT(deg)
    !! Radians -> degrees.
    REAL(wp), INTENT(IN) :: rad
    REAL(wp) :: deg
    deg = rad/CD_RAD_PER_DEG
  END FUNCTION CD_Rad2Deg

  PURE FUNCTION CD_Direction_Vector(azimuth_deg, declination_deg) RESULT(v)
    !! Unit vector from azimuth + declination (degrees), OrcaFlex convention:
    !! azimuth A measured in the horizontal plane from +GX toward +GY; declination
    !! D measured from +GZ (0 deg = up, 90 deg = horizontal, 180 deg = down). Returns
    !! v = (sinD cosA, sinD sinA, cosD); |v| = 1.
    REAL(wp), INTENT(IN) :: azimuth_deg, declination_deg
    REAL(wp) :: v(3)
    REAL(wp) :: a, d
    a = CD_Deg2Rad(azimuth_deg)
    d = CD_Deg2Rad(declination_deg)
    v = [SIN(d)*COS(a), SIN(d)*SIN(a), COS(d)]
  END FUNCTION CD_Direction_Vector

  PURE FUNCTION CD_LineEnd_Rotation(azimuth_deg, declination_deg, gamma_deg) RESULT(R)
    !! Line-end / constraint / wing attitude: intrinsic z-y'-z'' Euler sequence
    !! R = Rz(azimuth) . Ry(declination) . Rz(gamma). Azimuth + declination orient
    !! the end tangent (column 3 of R equals CD_Direction_Vector(azimuth, declination)
    !! for any gamma); gamma twists the section about that tangent. Distinct from the
    !! 6D-body sequence (CD_Body_Rotation).
    REAL(wp), INTENT(IN) :: azimuth_deg, declination_deg, gamma_deg
    REAL(wp) :: R(3, 3), A(3, 3), B(3, 3), C(3, 3), AB(3, 3)
    A = rot_z(CD_Deg2Rad(azimuth_deg))
    B = rot_y(CD_Deg2Rad(declination_deg))
    C = rot_z(CD_Deg2Rad(gamma_deg))
    AB = MATMUL(A, B)
    R = MATMUL(AB, C)
  END FUNCTION CD_LineEnd_Rotation

  PURE FUNCTION CD_Body_Rotation(rot1_deg, rot2_deg, rot3_deg) RESULT(R)
    !! 6D-buoy / rigid-body attitude: intrinsic x-y'-z'' Euler sequence
    !! R = Rx(rotation1) . Ry(rotation2) . Rz(rotation3) about the body axes.
    !! Distinct from the line-end z-y'-z'' sequence (CD_LineEnd_Rotation).
    REAL(wp), INTENT(IN) :: rot1_deg, rot2_deg, rot3_deg
    REAL(wp) :: R(3, 3), A(3, 3), B(3, 3), C(3, 3), AB(3, 3)
    A = rot_x(CD_Deg2Rad(rot1_deg))
    B = rot_y(CD_Deg2Rad(rot2_deg))
    C = rot_z(CD_Deg2Rad(rot3_deg))
    AB = MATMUL(A, B)
    R = MATMUL(AB, C)
  END FUNCTION CD_Body_Rotation

  ! --- elementary axis rotations, built from the core SO(3) exponential so they
  !     share the solver's right-handed rotation convention exactly ---

  PURE FUNCTION rot_x(a) RESULT(R)
    REAL(wp), INTENT(IN) :: a
    REAL(wp) :: R(3, 3)
    R = CD_Exp_SO3([a, 0.0_wp, 0.0_wp])
  END FUNCTION rot_x

  PURE FUNCTION rot_y(a) RESULT(R)
    REAL(wp), INTENT(IN) :: a
    REAL(wp) :: R(3, 3)
    R = CD_Exp_SO3([0.0_wp, a, 0.0_wp])
  END FUNCTION rot_y

  PURE FUNCTION rot_z(a) RESULT(R)
    REAL(wp), INTENT(IN) :: a
    REAL(wp) :: R(3, 3)
    R = CD_Exp_SO3([0.0_wp, 0.0_wp, a])
  END FUNCTION rot_z

END MODULE CableDyn_Conventions
