! File: tests/test_bathymetry.f90
! SPDX-License-Identifier: Apache-2.0
! Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
PROGRAM test_bathymetry
  !! Unit tests for the structured bathymetry service and variable-elevation
  !! seabed contact tangent. These tests are self-contained analytical checks:
  !! bilinear interpolation on a plane, edge clamping, fail-closed validation, and the
  !! C2 rounding of the creases of a non-planar grid.
  USE CableDyn_Precision, ONLY: wp
  USE CableDyn_Bathymetry, ONLY: CD_BathymetryType, CD_Init_Bathymetry, CD_End_Bathymetry, &
                                 CD_Bathymetry_Depth, CD_Bathymetry_Floor, CD_Bathymetry_Max_Floor, &
                                 CD_Bathymetry_Floor_Gradient, CD_Bathymetry_Seabed_Load, &
                                 CD_Bathymetry_Is_Initialized, CD_BATHY_OK, CD_BATHY_BADINPUT, &
                                 CD_Bathymetry_Grid_Floor, CD_Bathymetry_Rotate_Curvature, &
                                 CD_BATHY_CREASE_FRACTION
  USE CableDyn_SeabedContact, ONLY: CD_SEABED_CONTACT_BLEND
  USE CableDyn_Static, ONLY: CD_Static_As_Laid_Reference, CD_STATIC_OK, CD_Static_Line_Equilibrium, &
                             CableSolverConfig, CableCurrentLoad, CD_StaticLineReport
  USE, INTRINSIC :: IEEE_ARITHMETIC, ONLY: IEEE_VALUE, IEEE_QUIET_NAN
  IMPLICIT NONE

  INTEGER :: nfail
  nfail = 0

  CALL case_bilinear_depth_and_floor()
  CALL case_variable_seabed_contact_tangent()
  CALL case_variable_seabed_tangent_fd()
  CALL case_fail_closed_inputs()
  CALL case_crease_rounding_c2()
  CALL case_crease_rounding_planar_exact()
  CALL case_crease_contact_tangent_fd()
  CALL case_as_laid_tension_sink()
  CALL case_as_laid_seed_from_last()
  CALL case_max_floor_crease_band()

  IF (nfail > 0) THEN
    WRITE (*, '(A,I0,A)') 'FAIL: ', nfail, ' assertion(s) failed'
    ERROR STOP 1
  END IF
  WRITE (*, '(A)') 'PASS: CableDyn_Bathymetry'

CONTAINS

  INCLUDE 'nan_max_abs.inc'

  SUBROUTINE expect(got, want, label)
    REAL(wp), INTENT(IN) :: got, want
    CHARACTER(*), INTENT(IN) :: label
    REAL(wp), PARAMETER :: atol = 1.0e-10_wp, rtol = 1.0e-12_wp
    IF (.NOT. (ABS(got - want) <= atol + rtol*ABS(want))) THEN
      WRITE (*, '(A,A,A,ES23.15,A,ES23.15)') 'MISMATCH [', label, ']: got ', got, ' want ', want
      nfail = nfail + 1
    END IF
  END SUBROUTINE expect

  SUBROUTINE expect_es(es, want, label)
    INTEGER, INTENT(IN) :: es, want
    CHARACTER(*), INTENT(IN) :: label
    IF (es /= want) THEN
      WRITE (*, '(A,A,A,I0,A,I0)') 'MISMATCH [', label, ']: ErrStat ', es, ' want ', want
      nfail = nfail + 1
    END IF
  END SUBROUTINE expect_es

  SUBROUTINE expect_relaxed(got, want, label)
    REAL(wp), INTENT(IN) :: got, want
    CHARACTER(*), INTENT(IN) :: label
    REAL(wp), PARAMETER :: atol = 1.0e-5_wp, rtol = 1.0e-10_wp
    IF (.NOT. (ABS(got - want) <= atol + rtol*ABS(want))) THEN
      WRITE (*, '(A,A,A,ES23.15,A,ES23.15)') 'MISMATCH [', label, ']: got ', got, ' want ', want
      nfail = nfail + 1
    END IF
  END SUBROUTINE expect_relaxed

  SUBROUTINE require(cond, label)
    LOGICAL, INTENT(IN) :: cond
    CHARACTER(*), INTENT(IN) :: label
    IF (.NOT. cond) THEN
      WRITE (*, '(A,A)') 'MISMATCH [', label//']'
      nfail = nfail + 1
    END IF
  END SUBROUTINE require

  SUBROUTINE init_plane_bathy(bathy, es, em)
    TYPE(CD_BathymetryType), INTENT(OUT) :: bathy
    INTEGER, INTENT(OUT) :: es
    CHARACTER(*), INTENT(OUT) :: em

    REAL(wp) :: x(3), y(3), depth(3, 3)
    INTEGER :: i, j

    x = [0.0_wp, 10.0_wp, 20.0_wp]
    y = [0.0_wp, 5.0_wp, 15.0_wp]
    DO j = 1, SIZE(y)
      DO i = 1, SIZE(x)
        depth(i, j) = 100.0_wp + 0.2_wp*x(i) + 0.4_wp*y(j)
      END DO
    END DO
    CALL CD_Init_Bathymetry(bathy, x, y, depth, es, em)
  END SUBROUTINE init_plane_bathy

  SUBROUTINE case_bilinear_depth_and_floor()
    TYPE(CD_BathymetryType) :: bathy
    REAL(wp) :: depth, floor, dfdx, dfdy
    INTEGER :: es
    CHARACTER(160) :: em

    CALL init_plane_bathy(bathy, es, em)
    CALL expect_es(es, CD_BATHY_OK, 'init-plane')
    CALL require(CD_Bathymetry_Is_Initialized(bathy), 'is-initialized')
    CALL expect(bathy%average_depth, 104.66666666666666667_wp, 'average-depth')
    CALL expect(bathy%minimum_depth, 100.0_wp, 'minimum-depth')

    CALL CD_Bathymetry_Depth(bathy, 7.5_wp, 2.5_wp, depth, es, em)
    CALL expect_es(es, CD_BATHY_OK, 'depth-interior-es')
    CALL expect(depth, 102.5_wp, 'depth-interior')

    CALL CD_Bathymetry_Floor_Gradient(bathy, 7.5_wp, 2.5_wp, floor, dfdx, dfdy, es, em)
    CALL expect_es(es, CD_BATHY_OK, 'floor-gradient-es')
    CALL expect(floor, -102.5_wp, 'floor-interior')
    CALL expect(dfdx, -0.2_wp, 'floor-dfdx')
    CALL expect(dfdy, -0.4_wp, 'floor-dfdy')

    CALL CD_Bathymetry_Floor(bathy, -2.0_wp, 20.0_wp, floor, es, em)
    CALL expect_es(es, CD_BATHY_OK, 'floor-clamped-es')
    CALL expect(floor, -106.0_wp, 'floor-clamped-edge')
    CALL CD_Bathymetry_Floor_Gradient(bathy, -2.0_wp, 7.5_wp, floor, dfdx, dfdy, es, em)
    CALL expect(dfdx, 0.0_wp, 'floor-clamped-x-gradient')
    CALL expect(dfdy, -0.4_wp, 'floor-clamped-y-gradient')

    CALL CD_End_Bathymetry(bathy)
    CALL require(.NOT. CD_Bathymetry_Is_Initialized(bathy), 'end-resets')
  END SUBROUTINE case_bilinear_depth_and_floor

  SUBROUTINE case_variable_seabed_contact_tangent()
    TYPE(CD_BathymetryType) :: bathy
    REAL(wp) :: nodes(3, 3), kn(3), f(9), kres(9, 9)
    INTEGER :: es
    CHARACTER(160) :: em

    CALL init_plane_bathy(bathy, es, em)
    CALL expect_es(es, CD_BATHY_OK, 'contact:init')

    nodes(:, 1) = [7.5_wp, 2.5_wp, -103.0_wp]   ! 0.5 m penetration
    nodes(:, 2) = [7.5_wp, 2.5_wp, -102.5_wp]   ! exactly on floor
    nodes(:, 3) = [7.5_wp, 2.5_wp, -102.0_wp]   ! above floor
    kn = [1000.0_wp, 2000.0_wp, 3000.0_wp]

    ! Frictionless contact along the surface normal. The test plane has gradient
    ! (dz/dx, dz/dy) = (-0.2, -0.4), so the upward unit normal is n = (0.2, 0.4, 1)/s,
    ! s = sqrt(1.2); a vertical penetration g is a normal penetration g/s, the force is
    ! k (g/s) n and the residual tangent k n n^T.
    CALL CD_Bathymetry_Seabed_Load(bathy, nodes, kn, f, kres, es, em)
    CALL expect_es(es, CD_BATHY_OK, 'contact:load-es')
    CALL expect(f(3), 500.0_wp/1.2_wp, 'contact:penetrating-force')
    CALL expect(f(1), 0.2_wp*500.0_wp/1.2_wp, 'contact:penetrating-force-x')
    CALL expect(f(2), 0.4_wp*500.0_wp/1.2_wp, 'contact:penetrating-force-y')
    CALL expect(f(6), 500.0_wp*CD_SEABED_CONTACT_BLEND/SQRT(1.2_wp), 'contact:on-floor-force')
    CALL expect(f(9), 0.0_wp, 'contact:above-force')
    CALL expect(kres(3, 1), 200.0_wp/1.2_wp, 'contact:node1-dx-tangent')
    CALL expect(kres(3, 2), 400.0_wp/1.2_wp, 'contact:node1-dy-tangent')
    CALL expect(kres(3, 3), 1000.0_wp/1.2_wp, 'contact:node1-dz-tangent')
    CALL expect(kres(1, 1), 40.0_wp/1.2_wp, 'contact:node1-xx-tangent')
    CALL expect(kres(1, 2), 80.0_wp/1.2_wp, 'contact:node1-xy-tangent')
    CALL expect(kres(1, 3), 200.0_wp/1.2_wp, 'contact:node1-symmetric-tangent')
    CALL expect_relaxed(kres(6, 4), 200.0_wp/1.2_wp, 'contact:node2-dx-blend')
    CALL expect_relaxed(kres(6, 5), 400.0_wp/1.2_wp, 'contact:node2-dy-blend')
    CALL expect_relaxed(kres(6, 6), 1000.0_wp/1.2_wp, 'contact:node2-dz-blend')
    CALL expect(kres(9, 7), 0.0_wp, 'contact:node3-inactive-x')
    CALL expect(kres(9, 9), 0.0_wp, 'contact:node3-inactive-z')
    CALL expect(nan_max_abs(f(7:9)), 0.0_wp, 'contact:no-force-above-floor')

    ! half-way into the touchdown blend along the NORMAL (vertical offset s*blend/2)
    nodes(:, 1) = [7.5_wp, 2.5_wp, -102.5_wp - 0.5_wp*SQRT(1.2_wp)*CD_SEABED_CONTACT_BLEND]
    CALL CD_Bathymetry_Seabed_Load(bathy, nodes(:, 1:1), kn(1:1), f(1:3), kres(1:3, 1:3), es, em)
    CALL expect_es(es, CD_BATHY_OK, 'contact:blend-load-es')
    CALL expect_relaxed(f(3), 562.5_wp*CD_SEABED_CONTACT_BLEND/SQRT(1.2_wp), 'contact:blend-force')
    CALL expect_relaxed(kres(3, 1), 150.0_wp/1.2_wp, 'contact:blend-dx-tangent')
    CALL expect_relaxed(kres(3, 2), 300.0_wp/1.2_wp, 'contact:blend-dy-tangent')
    CALL expect_relaxed(kres(3, 3), 750.0_wp/1.2_wp, 'contact:blend-dz-tangent')

    CALL CD_End_Bathymetry(bathy)
  END SUBROUTINE case_variable_seabed_contact_tangent

  SUBROUTINE case_variable_seabed_tangent_fd()
    !! Independent FD gate for the variable-floor residual tangent:
    !! k_resid(:,j) = -d f_contact / d q_j on an active penetrating node.
    TYPE(CD_BathymetryType) :: bathy
    REAL(wp) :: nodes(3, 1), kn(1), f0(3), fp(3), fm(3), kres(3, 3), kbase(3, 3), fd_col(3), trial(3, 1)
    REAL(wp) :: h
    INTEGER :: es, j
    CHARACTER(160) :: em

    CALL init_plane_bathy(bathy, es, em)
    CALL expect_es(es, CD_BATHY_OK, 'fd:init')
    nodes(:, 1) = [7.5_wp, 2.5_wp, -103.0_wp]
    kn = [1000.0_wp]
    h = 1.0e-6_wp

    CALL CD_Bathymetry_Seabed_Load(bathy, nodes, kn, f0, kres, es, em)
    CALL expect_es(es, CD_BATHY_OK, 'fd:base-load')
    kbase = kres
    DO j = 1, 3
      trial = nodes
      trial(j, 1) = trial(j, 1) + h
      CALL CD_Bathymetry_Seabed_Load(bathy, trial, kn, fp, kres, es, em)
      CALL expect_es(es, CD_BATHY_OK, 'fd:plus-load')
      trial = nodes
      trial(j, 1) = trial(j, 1) - h
      CALL CD_Bathymetry_Seabed_Load(bathy, trial, kn, fm, kres, es, em)
      CALL expect_es(es, CD_BATHY_OK, 'fd:minus-load')
      fd_col = -(fp - fm)/(2.0_wp*h)
      CALL expect_vec_fd(kbase(:, j), fd_col, 'fd:variable-floor-kcol')
    END DO
    CALL expect(f0(3), 500.0_wp/1.2_wp, 'fd:base-force')
    CALL CD_End_Bathymetry(bathy)
  END SUBROUTINE case_variable_seabed_tangent_fd

  SUBROUTINE case_fail_closed_inputs()
    TYPE(CD_BathymetryType) :: bathy
    REAL(wp) :: x(3), y(2), depth(3, 2), d, f(6), k(6, 6), nodes(3, 2)
    INTEGER :: es
    CHARACTER(160) :: em

    x = [0.0_wp, 10.0_wp, 20.0_wp]
    y = [0.0_wp, 5.0_wp]
    depth = RESHAPE([100.0_wp, 102.0_wp, 104.0_wp, 101.0_wp, 103.0_wp, 105.0_wp], [3, 2])

    CALL CD_Bathymetry_Depth(bathy, 0.0_wp, 0.0_wp, d, es, em)
    CALL expect_es(es, CD_BATHY_BADINPUT, 'uninitialized-depth')

    CALL CD_Init_Bathymetry(bathy, [0.0_wp, 0.0_wp, 10.0_wp], y, depth, es, em)
    CALL expect_es(es, CD_BATHY_BADINPUT, 'duplicate-x')

    CALL CD_Init_Bathymetry(bathy, x, y, -depth, es, em)
    CALL expect_es(es, CD_BATHY_BADINPUT, 'negative-depth')

    depth(2, 1) = IEEE_VALUE(1.0_wp, IEEE_QUIET_NAN)
    CALL CD_Init_Bathymetry(bathy, x, y, depth, es, em)
    CALL expect_es(es, CD_BATHY_BADINPUT, 'nan-depth')

    depth = RESHAPE([100.0_wp, 102.0_wp, 104.0_wp, 101.0_wp, 103.0_wp, 105.0_wp], [3, 2])
    CALL CD_Init_Bathymetry(bathy, x, y, depth, es, em)
    CALL expect_es(es, CD_BATHY_OK, 'valid-after-failures')
    CALL CD_Bathymetry_Depth(bathy, 10.0_wp, 5.0_wp, d, es, em)
    CALL expect_es(es, CD_BATHY_OK, 'valid-before-bad-reinit-depth-es')
    CALL expect(d, 103.0_wp, 'valid-before-bad-reinit-depth')
    CALL CD_Init_Bathymetry(bathy, [0.0_wp, 0.0_wp, 10.0_wp], y, depth, es, em)
    CALL expect_es(es, CD_BATHY_BADINPUT, 'bad-reinit-preserves-grid-es')
    CALL require(CD_Bathymetry_Is_Initialized(bathy), 'bad-reinit-preserves-grid-init')
    CALL CD_Bathymetry_Depth(bathy, 10.0_wp, 5.0_wp, d, es, em)
    CALL expect_es(es, CD_BATHY_OK, 'bad-reinit-preserves-depth-es')
    CALL expect(d, 103.0_wp, 'bad-reinit-preserves-depth')

    nodes(:, 1) = [0.0_wp, 0.0_wp, -101.0_wp]
    nodes(:, 2) = [1.0_wp, 0.0_wp, -101.0_wp]
    CALL CD_Bathymetry_Seabed_Load(bathy, nodes, [100.0_wp], f, k, es, em)
    CALL expect_es(es, CD_BATHY_BADINPUT, 'bad-kn-size')
    CALL CD_Bathymetry_Seabed_Load(bathy, nodes, [100.0_wp, -1.0_wp], f, k, es, em)
    CALL expect_es(es, CD_BATHY_BADINPUT, 'bad-kn-value')

    nodes(1, 2) = IEEE_VALUE(1.0_wp, IEEE_QUIET_NAN)
    CALL CD_Bathymetry_Seabed_Load(bathy, nodes, [100.0_wp, 100.0_wp], f, k, es, em)
    CALL expect_es(es, CD_BATHY_BADINPUT, 'nan-node')

    CALL CD_End_Bathymetry(bathy)
  END SUBROUTINE case_fail_closed_inputs

  SUBROUTINE case_max_floor_crease_band()
    !! The maximum-floor bound covers the crease rounding of a neighbouring cell: a box inside a
    !! flat cell next to a crease (x = 0, 1, 2 with depths 100, 100, 90) lies in the rounding band
    !! of the crease at x = 1, where the floor rises above the flat cell's nodes.
    TYPE(CD_BathymetryType) :: bathy
    REAL(wp) :: z_floor, z_max, xq
    INTEGER :: es, k
    CHARACTER(160) :: em
    CALL CD_Init_Bathymetry(bathy, [0.0_wp, 1.0_wp, 2.0_wp], [0.0_wp, 1.0_wp], &
                            RESHAPE([100.0_wp, 100.0_wp, 90.0_wp, 100.0_wp, 100.0_wp, 90.0_wp], [3, 2]), es, em)
    CALL expect_es(es, CD_BATHY_OK, 'maxfloor:init')
    CALL CD_Bathymetry_Floor(bathy, 0.99_wp, 0.5_wp, z_floor, es, em)
    CALL require(es == CD_BATHY_OK .AND. z_floor > -100.0_wp, 'maxfloor:the crease rounding raises the flat cell')
    CALL CD_Bathymetry_Max_Floor(bathy, 0.989_wp, 0.991_wp, 0.49_wp, 0.51_wp, z_max, es, em)
CALL require(es == CD_BATHY_OK .AND. z_max >= z_floor, 'maxfloor:a box in the band of a neighbouring crease is bounded')
    ! the bound holds at every point of a box sweeping across both cells
    DO k = 0, 200
      xq = 0.01_wp*REAL(k, wp)
      CALL CD_Bathymetry_Floor(bathy, xq, 0.5_wp, z_floor, es, em)
      CALL CD_Bathymetry_Max_Floor(bathy, MAX(0.0_wp, xq - 1.0e-3_wp), MIN(2.0_wp, xq + 1.0e-3_wp), &
                                   0.49_wp, 0.51_wp, z_max, es, em)
      IF (.NOT. (z_max >= z_floor)) THEN
        CALL require(.FALSE., 'maxfloor:sweep bound fails')
        EXIT
      END IF
    END DO
    CALL CD_End_Bathymetry(bathy)
  END SUBROUTINE case_max_floor_crease_band

  SUBROUTINE init_creased_bathy(bathy)
    !! A non-planar grid with creases along every interior line (non-uniform spacing).
    TYPE(CD_BathymetryType), INTENT(OUT) :: bathy
    REAL(wp) :: x(5), y(4), depth(5, 4)
    INTEGER :: i, j, es
    CHARACTER(160) :: em
    x = [0.0_wp, 10.0_wp, 25.0_wp, 30.0_wp, 42.0_wp]
    y = [-5.0_wp, 8.0_wp, 20.0_wp, 26.0_wp]
    DO j = 1, SIZE(y)
      DO i = 1, SIZE(x)
        depth(i, j) = 100.0_wp + 2.0_wp*SIN(0.37_wp*x(i) + 0.11_wp*y(j)) + &
                      1.5_wp*COS(0.23_wp*y(j) - 0.05_wp*x(i)) + 0.1_wp*REAL(MOD(3*i + 5*j, 7), wp)
      END DO
    END DO
    CALL CD_Init_Bathymetry(bathy, x, y, depth, es, em)
    CALL expect_es(es, CD_BATHY_OK, 'crease:init')
  END SUBROUTINE init_creased_bathy

  SUBROUTINE floor_at(bathy, x, y, z, g)
    TYPE(CD_BathymetryType), INTENT(IN) :: bathy
    REAL(wp), INTENT(IN) :: x, y
    REAL(wp), INTENT(OUT) :: z, g(2)
    INTEGER :: es
    CHARACTER(160) :: em
    CALL CD_Bathymetry_Floor_Gradient(bathy, x, y, z, g(1), g(2), es, em)
    CALL expect_es(es, CD_BATHY_OK, 'crease:query')
  END SUBROUTINE floor_at

  SUBROUTINE case_crease_rounding_c2()
    !! The rounded surface is C2: height, gradient and the curvatures z_xx and z_yy are
    !! continuous across every interior grid line (at a crossing as well) and at the edges
    !! of the bands; the gradient is the derivative of the height and the curvature that
    !! of the gradient (central differences); outside the bands the surface is the
    !! bilinear one, bit for bit; inside a band it moves by at most a sixth of the slope
    !! jump times the band half-width.
    TYPE(CD_BathymetryType) :: bathy
    REAL(wp), PARAMETER :: EPS = 1.0e-9_wp, H = 1.0e-5_wp
    REAL(wp), PARAMETER :: LINES_X(3) = [10.0_wp, 25.0_wp, 30.0_wp], LINES_Y(2) = [8.0_wp, 20.0_wp]
    REAL(wp), PARAMETER :: ALONG_X(4) = [3.0_wp, 8.0_wp, 8.1_wp, 19.95_wp]
    REAL(wp), PARAMETER :: ALONG_Y(4) = [4.0_wp, 10.0_wp, 9.8_wp, 29.9_wp]
    REAL(wp) :: za, zb, ga(2), gb(2), zg, z, g(2), gp(2), gm(2), zp, zm, curv(3), delta, dz, ca(3), cb(3)
    REAL(wp) :: pts(2, 6), zpp, zpm, zmp, zmm, twist
    INTEGER :: k, j, es
    CHARACTER(160) :: em

    CALL init_creased_bathy(bathy)
    ! across the x lines, away from and at the crossings with the y lines
    DO k = 1, SIZE(LINES_X)
      DO j = 1, SIZE(ALONG_X)
        CALL CD_Bathymetry_Floor_Gradient(bathy, LINES_X(k) - EPS, ALONG_X(j), za, ga(1), ga(2), es, em, &
                                          crease_curvature=ca)
        CALL CD_Bathymetry_Floor_Gradient(bathy, LINES_X(k) + EPS, ALONG_X(j), zb, gb(1), gb(2), es, em, &
                                          crease_curvature=cb)
        CALL require(ABS(za - zb) <= 1.0e-8_wp, 'crease:x-line height continuous')
        CALL require(MAXVAL(ABS(ga - gb)) <= 1.0e-6_wp, 'crease:x-line gradient continuous')
        CALL require(ABS(ca(1) - cb(1)) <= 1.0e-5_wp .AND. ABS(ca(3) - cb(3)) <= 1.0e-5_wp, &
                     'crease:x-line curvature continuous')
      END DO
    END DO
    DO k = 1, SIZE(LINES_Y)
      DO j = 1, SIZE(ALONG_Y)
        CALL CD_Bathymetry_Floor_Gradient(bathy, ALONG_Y(j), LINES_Y(k) - EPS, za, ga(1), ga(2), es, em, &
                                          crease_curvature=ca)
        CALL CD_Bathymetry_Floor_Gradient(bathy, ALONG_Y(j), LINES_Y(k) + EPS, zb, gb(1), gb(2), es, em, &
                                          crease_curvature=cb)
        CALL require(ABS(za - zb) <= 1.0e-8_wp, 'crease:y-line height continuous')
        CALL require(MAXVAL(ABS(ga - gb)) <= 1.0e-6_wp, 'crease:y-line gradient continuous')
        CALL require(ABS(ca(1) - cb(1)) <= 1.0e-5_wp .AND. ABS(ca(3) - cb(3)) <= 1.0e-5_wp, &
                     'crease:y-line curvature continuous')
      END DO
    END DO
    ! at the band edge of the x line 25 (half-width 5 % of the smaller spacing, 5 m)
    delta = CD_BATHY_CREASE_FRACTION*5.0_wp
    CALL CD_Bathymetry_Floor_Gradient(bathy, 25.0_wp + delta - EPS, 3.0_wp, za, ga(1), ga(2), es, em, &
                                      crease_curvature=ca)
    CALL CD_Bathymetry_Floor_Gradient(bathy, 25.0_wp + delta + EPS, 3.0_wp, zb, gb(1), gb(2), es, em, &
                                      crease_curvature=cb)
    CALL require(ABS(za - zb) <= 1.0e-8_wp .AND. MAXVAL(ABS(ga - gb)) <= 1.0e-6_wp .AND. &
                 MAXVAL(ABS(ca - cb)) <= 1.0e-5_wp, 'crease:band edge C2')
    ! outside every band (and outside the grid): exactly the bilinear surface
    pts = RESHAPE([5.0_wp, 2.0_wp, 17.0_wp, 14.0_wp, 27.5_wp, 23.0_wp, 36.0_wp, 0.0_wp, -3.0_wp, 14.0_wp, &
                   50.0_wp, 30.0_wp], [2, 6])
    DO j = 1, SIZE(pts, 2)
      CALL floor_at(bathy, pts(1, j), pts(2, j), z, g)
      CALL CD_Bathymetry_Grid_Floor(bathy, pts(1, j), pts(2, j), zg, es, em)
      CALL require(z == zg, 'crease:outside the bands the surface is bilinear')
    END DO
    ! gradient and curvature against central differences inside bands and at crossings
    pts = RESHAPE([10.2_wp, 3.0_wp, 24.9_wp, 14.0_wp, 4.0_wp, 7.7_wp, 29.92_wp, 20.1_wp, 10.1_wp, 8.2_wp, &
                   25.05_wp, 19.97_wp], [2, 6])
    DO j = 1, SIZE(pts, 2)
      CALL CD_Bathymetry_Floor_Gradient(bathy, pts(1, j), pts(2, j), z, g(1), g(2), es, em, crease_curvature=curv)
      CALL floor_at(bathy, pts(1, j) + H, pts(2, j), zp, gp)
      CALL floor_at(bathy, pts(1, j) - H, pts(2, j), zm, gm)
      CALL require(ABS((zp - zm)/(2.0_wp*H) - g(1)) <= 1.0e-6_wp, 'crease:dz/dx')
      ! the rounding's curvature: the bilinear part of z_xx is zero within a cell
      CALL require(ABS((gp(1) - gm(1))/(2.0_wp*H) - curv(1)) <= 1.0e-4_wp*MAX(1.0_wp, ABS(curv(1))), &
                   'crease:z_xx')
      CALL floor_at(bathy, pts(1, j), pts(2, j) + H, zp, gp)
      CALL floor_at(bathy, pts(1, j), pts(2, j) - H, zm, gm)
      CALL require(ABS((zp - zm)/(2.0_wp*H) - g(2)) <= 1.0e-6_wp, 'crease:dz/dy')
      CALL require(ABS((gp(2) - gm(2))/(2.0_wp*H) - curv(3)) <= 1.0e-4_wp*MAX(1.0_wp, ABS(curv(3))), &
                   'crease:z_yy')
      ! z_xy of the rounding: the y-derivative of z_x less the twist of the bilinear cell,
      ! which the curvature leaves out (a four-point difference of the bilinear surface)
      CALL CD_Bathymetry_Grid_Floor(bathy, pts(1, j) + H, pts(2, j) + H, zpp, es, em)
      CALL CD_Bathymetry_Grid_Floor(bathy, pts(1, j) + H, pts(2, j) - H, zpm, es, em)
      CALL CD_Bathymetry_Grid_Floor(bathy, pts(1, j) - H, pts(2, j) + H, zmp, es, em)
      CALL CD_Bathymetry_Grid_Floor(bathy, pts(1, j) - H, pts(2, j) - H, zmm, es, em)
      twist = (zpp - zpm - zmp + zmm)/(4.0_wp*H*H)
      CALL require(ABS((gp(1) - gm(1))/(2.0_wp*H) - twist - curv(2)) <= 1.0e-4_wp*MAX(1.0_wp, ABS(curv(2))), &
                   'crease:z_xy')
      CALL CD_Bathymetry_Grid_Floor(bathy, pts(1, j), pts(2, j), zg, es, em)
      dz = ABS(z - zg)
      ! slope jumps below 1 here: a band of half-width <= 0.6 m moves the surface by < 0.1 m
      CALL require(dz > 0.0_wp .AND. dz <= 0.1_wp, 'crease:bounded rounding inside a band')
    END DO
    ! the turned curvature is the Hessian in the turned frame (90 degrees: xx <-> yy)
    curv = CD_Bathymetry_Rotate_Curvature([1.0_wp, 0.0_wp, 0.0_wp], [0.0_wp, 1.0_wp])
    CALL require(ABS(curv(1)) <= 1.0e-15_wp .AND. ABS(curv(2)) <= 1.0e-15_wp .AND. &
                 ABS(curv(3) - 1.0_wp) <= 1.0e-15_wp, 'crease:turned curvature')
    CALL CD_End_Bathymetry(bathy)
  END SUBROUTINE case_crease_rounding_c2

  SUBROUTINE case_crease_rounding_planar_exact()
    !! A planar grid has no crease: the surface and its gradient are the bilinear ones bit
    !! for bit everywhere, inside the bands too, also for a plane written to six decimals.
    TYPE(CD_BathymetryType) :: bathy
    REAL(wp) :: x(4), y(3), depth(4, 3), z, zg, g(2), curv(3), xq, yq
    INTEGER :: i, j, k, es
    CHARACTER(160) :: em
    x = [0.0_wp, 10.0_wp, 25.0_wp, 30.0_wp]
    y = [-5.0_wp, 8.0_wp, 20.0_wp]
    DO k = 1, 2
      DO j = 1, SIZE(y)
        DO i = 1, SIZE(x)
          depth(i, j) = 388.949782_wp + 0.0732_wp*x(i) - 0.0417_wp*y(j)
          IF (k == 2) depth(i, j) = ANINT(depth(i, j)*1.0e6_wp)/1.0e6_wp
        END DO
      END DO
      CALL CD_Init_Bathymetry(bathy, x, y, depth, es, em)
      CALL expect_es(es, CD_BATHY_OK, 'planar:init')
      DO j = 0, 40
        DO i = 0, 40
          xq = -1.0_wp + 32.0_wp*REAL(i, wp)/40.0_wp + 0.01_wp*REAL(MOD(j, 3), wp)
          yq = -6.0_wp + 27.0_wp*REAL(j, wp)/40.0_wp
          CALL CD_Bathymetry_Floor_Gradient(bathy, xq, yq, z, g(1), g(2), es, em, crease_curvature=curv)
          CALL CD_Bathymetry_Grid_Floor(bathy, xq, yq, zg, es, em)
          CALL require(z == zg .AND. ALL(curv == 0.0_wp), 'planar:bit-identical bilinear surface')
        END DO
      END DO
      ! on the lines themselves (inside every band)
      CALL CD_Bathymetry_Floor(bathy, 10.0_wp, 8.0_wp, z, es, em)
      CALL CD_Bathymetry_Grid_Floor(bathy, 10.0_wp, 8.0_wp, zg, es, em)
      CALL require(z == zg, 'planar:bit-identical at a crossing')
    END DO
    CALL CD_End_Bathymetry(bathy)
  END SUBROUTINE case_crease_rounding_planar_exact

  SUBROUTINE case_crease_contact_tangent_fd()
    !! In a band (at a crossing of two lines) the contact force is the gradient of the
    !! penalty potential of the rounded surface, and its residual tangent the Hessian:
    !! k_resid(:, j) = -d f/d q_j against central differences (to 1 % of the largest
    !! entry: the tangent leaves out the third derivatives of the surface, a term of the
    !! order of the force times the penetration times d(curvature)/dq), and symmetric.
    TYPE(CD_BathymetryType) :: bathy
    REAL(wp) :: nodes(3, 1), kn(1), f0(3), fp(3), fm(3), kres(3, 3), kbase(3, 3), fd_col(3), trial(3, 1), z
    REAL(wp) :: h
    INTEGER :: es, j
    CHARACTER(160) :: em
    CALL init_creased_bathy(bathy)
    CALL CD_Bathymetry_Floor(bathy, 10.1_wp, 8.15_wp, z, es, em)
    nodes(:, 1) = [10.1_wp, 8.15_wp, z - 0.05_wp]
    kn = [2.0e4_wp]
    h = 1.0e-6_wp
    CALL CD_Bathymetry_Seabed_Load(bathy, nodes, kn, f0, kres, es, em)
    CALL expect_es(es, CD_BATHY_OK, 'crease-fd:base')
    kbase = kres
    DO j = 1, 3
      trial = nodes
      trial(j, 1) = trial(j, 1) + h
      CALL CD_Bathymetry_Seabed_Load(bathy, trial, kn, fp, kres, es, em)
      trial = nodes
      trial(j, 1) = trial(j, 1) - h
      CALL CD_Bathymetry_Seabed_Load(bathy, trial, kn, fm, kres, es, em)
      fd_col = -(fp - fm)/(2.0_wp*h)
      CALL require(MAXVAL(ABS(kbase(:, j) - fd_col)) <= 1.0e-2_wp*MAXVAL(ABS(kbase)), 'crease-fd:kcol')
    END DO
    ! the node is in contact (the tangent above is not trivially zero)
    CALL require(ABS(f0(3)) > 0.0_wp, 'crease-fd:in contact')
    CALL require(MAXVAL(ABS(kbase - TRANSPOSE(kbase))) <= 1.0e-9_wp*MAXVAL(ABS(kbase)), 'crease-fd:symmetric')
    CALL CD_End_Bathymetry(bathy)
  END SUBROUTINE case_crease_contact_tangent_fd

  SUBROUTINE expect_vec_fd(got, want, label)
    REAL(wp), INTENT(IN) :: got(:), want(:)
    CHARACTER(*), INTENT(IN) :: label
    REAL(wp), PARAMETER :: atol = 2.0e-5_wp, rtol = 1.0e-9_wp
    INTEGER :: i

    DO i = 1, SIZE(got)
      IF (.NOT. (ABS(got(i) - want(i)) <= atol + rtol*ABS(want(i)))) THEN
        WRITE (*, '(A,A,A,ES23.15,A,ES23.15)') 'MISMATCH [', label, ']: got ', got(i), ' want ', want(i)
        nfail = nfail + 1
      END IF
    END DO
  END SUBROUTINE expect_vec_fd

  SUBROUTINE case_as_laid_tension_sink()
    !! The as-laid friction reference on a curved bathymetry (a Gaussian crest along x):
    !! with kn and no laid tension it is bit-identical to the reference without kn; with a
    !! laid tension T each interior node's normal penetration deepens by the load
    !! -T (t_out - t_in).n / kn (n the upward normal), which moves its reference horizontally
    !! by that over s = sqrt(1 + |grad z|^2) times the local gradient (checked against an independent evaluation on the unsunk path).
    TYPE(CD_BathymetryType) :: bathy
    INTEGER, PARAMETER :: NE = 20
    REAL(wp), PARAMETER :: T = 2.0e4_wp, KN = 1.0e4_wp, SINK = 0.01_wp
    REAL(wp) :: x(41), y(2), depth(41, 2), l0(NE), ea(NE), sk(NE + 1), kv(NE + 1)
    REAL(wp) :: r_nokn(2, NE + 1), r_kn(2, NE + 1), r_t(2, NE + 1), r_t0(2, NE + 1), r_t_nokn(2, NE + 1)
    REAL(wp) :: p(3, 3), g(2), nrm(3), tin(3), tout(3), extra, expect(2), worst
    INTEGER :: i, j, k, es
    CHARACTER(160) :: em

    DO i = 1, SIZE(x)
      x(i) = 5.0_wp*REAL(i - 1, wp)
      depth(i, :) = 100.0_wp - 10.0_wp*EXP(-((x(i) - 100.0_wp)/30.0_wp)**2)
    END DO
    y = [-20.0_wp, 20.0_wp]
    CALL CD_Init_Bathymetry(bathy, x, y, depth, es, em)
    CALL expect_es(es, CD_BATHY_OK, 'aslaid:init')
    l0 = 9.0_wp
    ea = 1.0e9_wp
    sk = SINK
    kv = KN
    CALL CD_Static_As_Laid_Reference([0.0_wp, 0.0_wp], 0.0_wp, l0, ea, 0.0_wp, r_nokn, es, em, bathymetry=bathy, &
                                     sink=sk)
    CALL expect_es(es, CD_STATIC_OK, 'aslaid:ref')
    CALL CD_Static_As_Laid_Reference([0.0_wp, 0.0_wp], 0.0_wp, l0, ea, 0.0_wp, r_kn, es, em, bathymetry=bathy, &
                                     sink=sk, kn=kv)
    CALL require(ALL(r_kn == r_nokn), 'aslaid:no tension, kn changes nothing')
    CALL CD_Static_As_Laid_Reference([0.0_wp, 0.0_wp], 0.0_wp, l0, ea, T, r_t, es, em, bathymetry=bathy, &
                                     sink=sk, kn=kv)
    CALL CD_Static_As_Laid_Reference([0.0_wp, 0.0_wp], 0.0_wp, l0, ea, T, r_t_nokn, es, em, bathymetry=bathy, &
                                     sink=sk)
    sk = 0.0_wp
    CALL CD_Static_As_Laid_Reference([0.0_wp, 0.0_wp], 0.0_wp, l0, ea, T, r_t0, es, em, bathymetry=bathy)
    worst = 0.0_wp
    DO j = 2, NE
      DO k = 1, 3
        CALL floor_at(bathy, r_t0(1, j + k - 2), r_t0(2, j + k - 2), p(3, k), g)
        p(1:2, k) = r_t0(:, j + k - 2)
        IF (k == 2) nrm = [-g(1), -g(2), 1.0_wp]/SQRT(1.0_wp + g(1)**2 + g(2)**2)
      END DO
      tin = (p(:, 2) - p(:, 1))/NORM2(p(:, 2) - p(:, 1))
      tout = (p(:, 3) - p(:, 2))/NORM2(p(:, 3) - p(:, 2))
      CALL floor_at(bathy, r_t0(1, j), r_t0(2, j), p(3, 2), g)
      extra = MAX(0.0_wp, SINK - T*DOT_PRODUCT(tout - tin, nrm)/(KN*SQRT(1.0_wp + g(1)**2 + g(2)**2)))
      expect = r_t0(:, j) + extra*g
      worst = MAX(worst, MAXVAL(ABS(r_t(:, j) - expect)))
    END DO
    CALL require(worst <= 1.0e-12_wp, 'aslaid:tension sink matches the turning force')
    ! the crest presses the laid line into the seabed: the references differ with tension
    CALL require(MAXVAL(ABS(r_t - r_t_nokn)) > 1.0e-6_wp, 'aslaid:tension sink active on a crest')
    CALL CD_End_Bathymetry(bathy)
  END SUBROUTINE case_as_laid_tension_sink

  SUBROUTINE case_as_laid_seed_from_last()
    !! The as-laid seed of the EI = 0 static equilibrium for a line whose last node is its lower
    !! end (a line without a Fixed anchor at node 1, e.g. a FAST.Farm shared line): its friction
    !! reference is laid from node n (as CD_Init_Line_Model lays it), and the seed must be laid
    !! from node n too, the mirror image of the seed of the same line numbered from its lower
    !! end. A grounded line (300 m, laid slack, mu = 0.5) is solved both ways, on a level floor
    !! and on a bathymetry rising toward the upper end: both take the as-laid seed and reach the
    !! same equilibrium, node for node mirrored.
    INTEGER, PARAMETER :: NE = 60, NN = NE + 1
    REAL(wp), PARAMETER :: L0E = 5.0_wp, EA = 1.0e9_wp, WPL = 1.0e3_wp, KNE = 5.0e4_wp, Z0 = -100.0_wp
    REAL(wp), PARAMETER :: SLOPE = 0.05_wp, MU = 0.5_wp
    TYPE(CD_BathymetryType) :: bathy
    TYPE(CableSolverConfig) :: cfg
    TYPE(CableCurrentLoad) :: fr_a, fr_b
    TYPE(CD_StaticLineReport) :: rep_a, rep_b
    INTEGER :: conn(2, NE), i, j, es, icase
    REAL(wp) :: l0(NE), ea_e(NE), w(NE), f_ext(3*NN), kn(NN), sink(NN), lo(3), up(3)
    REAL(wp) :: ref(2, NN), q_a(3*NN), q_b(3*NN), gx(21), gy(2), depth(21, 2), worst
    LOGICAL :: conv_a, conv_b
    CHARACTER(160) :: em
    CHARACTER(32) :: tag

    DO i = 1, NE
      conn(:, i) = [i, i + 1]
    END DO
    l0 = L0E
    ea_e = EA
    w = WPL
    f_ext = 0.0_wp
    kn = KNE
    DO i = 1, NE
      f_ext(3*i) = f_ext(3*i) - 0.5_wp*WPL*L0E
      f_ext(3*i + 3) = f_ext(3*i + 3) - 0.5_wp*WPL*L0E
    END DO
    kn(1) = 0.5_wp*KNE
    kn(NN) = 0.5_wp*KNE
    sink = MAX(-f_ext(3:3*NN:3), 0.0_wp)/kn
    DO i = 1, SIZE(gx)
      gx(i) = -50.0_wp + 20.0_wp*REAL(i - 1, wp)
      depth(i, :) = -(Z0 + SLOPE*gx(i))
    END DO
    gy = [-50.0_wp, 50.0_wp]
    CALL CD_Init_Bathymetry(bathy, gx, gy, depth, es, em)
    CALL expect_es(es, CD_BATHY_OK, 'laid-last:init')
    lo = [0.0_wp, 0.0_wp, Z0]
    up = [250.0_wp, 0.0_wp, -10.0_wp]
    DO icase = 1, 2
      tag = MERGE('laid-last:flat ', 'laid-last:slope', icase == 1)
      ! the reference laid from the lower end along +x (the default azimuth of either numbering)
      IF (icase == 1) THEN
        CALL CD_Static_As_Laid_Reference(lo(1:2), 0.0_wp, l0, ea_e, 0.0_wp, ref, es, em)
      ELSE
        CALL CD_Static_As_Laid_Reference(lo(1:2), 0.0_wp, l0, ea_e, 0.0_wp, ref, es, em, bathymetry=bathy, &
                                         sink=sink, kn=kn)
      END IF
      CALL expect_es(es, CD_STATIC_OK, TRIM(tag)//' reference')
      fr_a%drag = .FALSE.
      fr_a%friction_mu = MU
      fr_a%friction_as_laid = .TRUE.
      fr_a%friction_ref = ref
      fr_b = fr_a
      fr_b%friction_ref = ref(:, NN:1:-1)
      IF (icase == 1) THEN
        CALL CD_Static_Line_Equilibrium(lo, up, conn, l0, ea_e, w, f_ext, cfg, .TRUE., q_a, conv_a, rep_a, es, em, &
                                        seabed_z_floor=Z0, seabed_kn=kn, current=fr_a)
        CALL expect_es(es, CD_STATIC_OK, TRIM(tag)//' from node 1')
        CALL CD_Static_Line_Equilibrium(up, lo, conn, l0, ea_e, w, f_ext, cfg, .TRUE., q_b, conv_b, rep_b, es, em, &
                                        seabed_z_floor=Z0, seabed_kn=kn, current=fr_b)
      ELSE
        CALL CD_Static_Line_Equilibrium(lo, up, conn, l0, ea_e, w, f_ext, cfg, .TRUE., q_a, conv_a, rep_a, es, em, &
                                        seabed_kn=kn, bathymetry=bathy, current=fr_a)
        CALL expect_es(es, CD_STATIC_OK, TRIM(tag)//' from node 1')
        CALL CD_Static_Line_Equilibrium(up, lo, conn, l0, ea_e, w, f_ext, cfg, .TRUE., q_b, conv_b, rep_b, es, em, &
                                        seabed_kn=kn, bathymetry=bathy, current=fr_b)
      END IF
      CALL expect_es(es, CD_STATIC_OK, TRIM(tag)//' from node n')
      CALL require(conv_a .AND. conv_b, TRIM(tag)//' both numberings converge')
      CALL require(TRIM(rep_a%seed) == 'as-laid run', TRIM(tag)//' node 1 lower: as-laid seed ('// &
                   TRIM(rep_a%seed)//')')
      CALL require(TRIM(rep_b%seed) == 'as-laid run', TRIM(tag)//' node n lower: as-laid seed ('// &
                   TRIM(rep_b%seed)//')')
      worst = 0.0_wp
      DO i = 1, NN
        j = NN + 1 - i
        worst = MAX(worst, MAXVAL(ABS(q_b(3*i - 2:3*i) - q_a(3*j - 2:3*j))))
      END DO
      IF (.NOT. (worst <= 1.0e-6_wp)) WRITE (*, '(A,ES10.3,A)') '  '//TRIM(tag)//': mirror mismatch ', worst, ' m'
      CALL require(worst <= 1.0e-6_wp, TRIM(tag)//' the two numberings give the mirrored equilibrium')
      ! the run rests on the seabed where it was laid (its friction holds it there)
      CALL require(ABS(q_a(3*11) - (Z0 + MERGE(0.0_wp, SLOPE*q_a(3*11 - 2), icase == 1))) < 0.2_wp, &
                   TRIM(tag)//' node 11 rests on the seabed')
    END DO
    CALL CD_End_Bathymetry(bathy)
  END SUBROUTINE case_as_laid_seed_from_last

END PROGRAM test_bathymetry
