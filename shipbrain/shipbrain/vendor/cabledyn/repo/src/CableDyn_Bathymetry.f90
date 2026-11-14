! File: src/CableDyn_Bathymetry.f90
! SPDX-License-Identifier: Apache-2.0
! Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
MODULE CableDyn_Bathymetry
  !! Structured 3D bathymetry service for production seabed contact and local
  !! water-depth queries. The grid stores positive water depth below still-water
  !! level at monotone x/y coordinates; the seabed elevation is z_floor = -depth.
  !! Queries clamp to the nearest grid edge outside the supplied domain and use
  !! bilinear interpolation inside each cell, with the creases of that surface along the
  !! interior grid lines rounded to C2 within a narrow band (crease_blend): a node resting
  !! in a valley or pit of the grid then meets a continuous normal, and has an
  !! equilibrium there. Outside the bands, and wherever the grid has no crease, the
  !! surface is exactly bilinear. Contact is a frictionless penalty force along the
  !! local upward surface normal at the normal penetration; its tangent holds the
  !! surface gradient fixed over the node (the twist of a bilinear cell is omitted). In a
  !! crease band the force is the gradient of the penalty potential of the normal
  !! penetration and its tangent that potential's Hessian (CD_Seabed_Normal_Contact).
  USE CableDyn_Precision, ONLY: wp, CD_ZERO, CD_All_Finite, CD_Is_Finite
  USE CableDyn_SeabedContact, ONLY: CD_Seabed_Normal_Contact
  IMPLICIT NONE
  PRIVATE

  PUBLIC :: CD_BathymetryType
  PUBLIC :: CD_Init_Bathymetry
  PUBLIC :: CD_End_Bathymetry
  PUBLIC :: CD_Bathymetry_Is_Initialized
  PUBLIC :: CD_Bathymetry_Depth
  PUBLIC :: CD_Bathymetry_Floor
  PUBLIC :: CD_Bathymetry_Floor_Gradient
  PUBLIC :: CD_Bathymetry_Grid_Floor
  PUBLIC :: CD_Bathymetry_Max_Floor
  PUBLIC :: CD_Bathymetry_Rotate_Curvature
  PUBLIC :: CD_Bathymetry_Seabed_Load
  INTEGER, PARAMETER, PUBLIC :: CD_BATHY_OK = 0, CD_BATHY_BADINPUT = 1, CD_BATHY_ALLOCFAIL = 2
  ! Crease rounding (see crease_blend): band half-width as a fraction of the smaller grid
  ! spacing next to the line, and the smallest surface change [m] a crease must make to be
  ! rounded (below it the grid is treated as uncreased there: an exactly planar grid stays
  ! exactly bilinear; the rounding errors of a plane written to two or three decimals are
  ! creases above it and are rounded by a fraction of a millimetre).
  REAL(wp), PARAMETER, PUBLIC :: CD_BATHY_CREASE_FRACTION = 0.05_wp
  REAL(wp), PARAMETER, PUBLIC :: CD_BATHY_CREASE_MIN_HEIGHT = 1.0e-6_wp

  TYPE :: CD_BathymetryType
    INTEGER :: nx = 0, ny = 0
    REAL(wp), ALLOCATABLE :: x(:)
    REAL(wp), ALLOCATABLE :: y(:)
    REAL(wp), ALLOCATABLE :: depth(:, :)
    REAL(wp) :: average_depth = CD_ZERO
    REAL(wp) :: minimum_depth = CD_ZERO
  END TYPE CD_BathymetryType

CONTAINS

  SUBROUTINE CD_Init_Bathymetry(bathy, x, y, depth, ErrStat, ErrMsg)
    !! Initialize a validated structured bathymetry grid.
    TYPE(CD_BathymetryType), INTENT(INOUT) :: bathy
    REAL(wp), INTENT(IN) :: x(:)
    REAL(wp), INTENT(IN) :: y(:)
    REAL(wp), INTENT(IN) :: depth(:, :)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg

    TYPE(CD_BathymetryType) :: next_bathy
    INTEGER :: i, istat

    ErrStat = CD_BATHY_OK
    ErrMsg = ''

    IF (SIZE(x) < 2 .OR. SIZE(y) < 2) THEN
      CALL fail(ErrStat, ErrMsg, 'bathymetry x/y grids need at least two points')
      RETURN
    END IF
    IF (SIZE(depth, 1) /= SIZE(x) .OR. SIZE(depth, 2) /= SIZE(y)) THEN
      CALL fail(ErrStat, ErrMsg, 'bathymetry depth must have shape (nx, ny)')
      RETURN
    END IF
    IF (.NOT. (CD_All_Finite(x) .AND. CD_All_Finite(y) .AND. CD_All_Finite(depth))) THEN
      CALL fail(ErrStat, ErrMsg, 'bathymetry coordinates and depths must be finite')
      RETURN
    END IF
    DO i = 2, SIZE(x)
      IF (x(i) <= x(i - 1)) THEN
        CALL fail(ErrStat, ErrMsg, 'bathymetry x grid must be strictly increasing')
        RETURN
      END IF
    END DO
    DO i = 2, SIZE(y)
      IF (y(i) <= y(i - 1)) THEN
        CALL fail(ErrStat, ErrMsg, 'bathymetry y grid must be strictly increasing')
        RETURN
      END IF
    END DO
    IF (ANY(depth <= CD_ZERO)) THEN
      CALL fail(ErrStat, ErrMsg, 'bathymetry depth entries must be positive')
      RETURN
    END IF

    next_bathy%nx = SIZE(x)
    next_bathy%ny = SIZE(y)
    ALLOCATE (next_bathy%x(next_bathy%nx), next_bathy%y(next_bathy%ny), &
              next_bathy%depth(next_bathy%nx, next_bathy%ny), STAT=istat)
    IF (istat /= 0) THEN
      ErrStat = CD_BATHY_ALLOCFAIL
      ErrMsg = 'CableDyn_Bathymetry: bathymetry grid allocation failed'
      RETURN
    END IF
    next_bathy%x = x
    next_bathy%y = y
    next_bathy%depth = depth
    next_bathy%average_depth = SUM(depth)/REAL(SIZE(depth), wp)
    next_bathy%minimum_depth = MINVAL(depth)

    CALL CD_End_Bathymetry(bathy)
    bathy%nx = next_bathy%nx
    bathy%ny = next_bathy%ny
    bathy%average_depth = next_bathy%average_depth
    bathy%minimum_depth = next_bathy%minimum_depth
    CALL MOVE_ALLOC(next_bathy%x, bathy%x)
    CALL MOVE_ALLOC(next_bathy%y, bathy%y)
    CALL MOVE_ALLOC(next_bathy%depth, bathy%depth)
  END SUBROUTINE CD_Init_Bathymetry

  SUBROUTINE CD_End_Bathymetry(bathy)
    !! Release grid storage and reset metadata.
    TYPE(CD_BathymetryType), INTENT(INOUT) :: bathy

    IF (ALLOCATED(bathy%x)) DEALLOCATE (bathy%x)
    IF (ALLOCATED(bathy%y)) DEALLOCATE (bathy%y)
    IF (ALLOCATED(bathy%depth)) DEALLOCATE (bathy%depth)
    bathy%nx = 0
    bathy%ny = 0
    bathy%average_depth = CD_ZERO
    bathy%minimum_depth = CD_ZERO
  END SUBROUTINE CD_End_Bathymetry

  LOGICAL FUNCTION CD_Bathymetry_Is_Initialized(bathy) RESULT(ok)
    !! True when the bathymetry object owns a complete validated grid.
    TYPE(CD_BathymetryType), INTENT(IN) :: bathy

    ok = bathy%nx >= 2 .AND. bathy%ny >= 2 .AND. ALLOCATED(bathy%x) .AND. &
         ALLOCATED(bathy%y) .AND. ALLOCATED(bathy%depth)
  END FUNCTION CD_Bathymetry_Is_Initialized

  SUBROUTINE CD_Bathymetry_Depth(bathy, xq, yq, depth, ErrStat, ErrMsg)
    !! Return positive water depth at a horizontal location.
    TYPE(CD_BathymetryType), INTENT(IN) :: bathy
    REAL(wp), INTENT(IN) :: xq, yq
    REAL(wp), INTENT(OUT) :: depth
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg

    REAL(wp) :: floor, dfdx, dfdy

    CALL floor_eval(bathy, xq, yq, floor, dfdx, dfdy, ErrStat, ErrMsg)
    IF (ErrStat /= CD_BATHY_OK) THEN
      depth = CD_ZERO
      RETURN
    END IF
    depth = -floor
  END SUBROUTINE CD_Bathymetry_Depth

  SUBROUTINE CD_Bathymetry_Floor(bathy, xq, yq, z_floor, ErrStat, ErrMsg)
    !! Return seabed elevation z_floor at a horizontal location.
    TYPE(CD_BathymetryType), INTENT(IN) :: bathy
    REAL(wp), INTENT(IN) :: xq, yq
    REAL(wp), INTENT(OUT) :: z_floor
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg

    REAL(wp) :: dfdx, dfdy

    CALL floor_eval(bathy, xq, yq, z_floor, dfdx, dfdy, ErrStat, ErrMsg)
  END SUBROUTINE CD_Bathymetry_Floor

  SUBROUTINE CD_Bathymetry_Grid_Floor(bathy, xq, yq, z_floor, ErrStat, ErrMsg)
    !! Seabed elevation of the grid itself at a horizontal location: the bilinear
    !! interpolation of the tabulated depths, without the crease rounding of
    !! CD_Bathymetry_Floor. For checking an input point against the surveyed depths only
    !! (a point at the tabulated depth of a creased grid node lies on this surface, within
    !! a fraction of the band width of the rounded one); every contact, gradient and output
    !! query uses CD_Bathymetry_Floor.
    TYPE(CD_BathymetryType), INTENT(IN) :: bathy
    REAL(wp), INTENT(IN) :: xq, yq
    REAL(wp), INTENT(OUT) :: z_floor
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    REAL(wp) :: dfdx, dfdy
    CALL floor_eval(bathy, xq, yq, z_floor, dfdx, dfdy, ErrStat, ErrMsg, rounded=.FALSE.)
  END SUBROUTINE CD_Bathymetry_Grid_Floor

  SUBROUTINE CD_Bathymetry_Max_Floor(bathy, x_lo, x_hi, y_lo, y_hi, z_max, ErrStat, ErrMsg)
    !! An upper bound of the seabed elevation (CD_Bathymetry_Floor) over the horizontal box
    !! [x_lo, x_hi] x [y_lo, y_hi]: the highest grid node of the cells the box overlaps (the
    !! bilinear surface of a cell lies within its node range, and outside the grid the floor
    !! is clamped to its edge cells), raised by CD_BATHY_CREASE_FRACTION times the node range
    !! of those cells widened by one node on every side, which bounds the crease rounding (it
    !! moves the surface by at most |J| delta/6 per direction, below a thirtieth of the node
    !! range for both directions together). The rounding band of a grid line reaches into the
    !! cells on both sides and its slope jump J depends on the nodes one beyond them, so a box
    !! inside a flat cell next to a crease takes the crease's rise from the widened range.
    TYPE(CD_BathymetryType), INTENT(IN) :: bathy
    REAL(wp), INTENT(IN) :: x_lo, x_hi, y_lo, y_hi
    REAL(wp), INTENT(OUT) :: z_max
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    INTEGER :: i0, i1, j0, j1, iw0, iw1, jw0, jw1
    REAL(wp) :: t, z_min
    LOGICAL :: clamped

    z_max = CD_ZERO
    ErrStat = CD_BATHY_OK
    ErrMsg = ''
    IF (.NOT. CD_Bathymetry_Is_Initialized(bathy)) THEN
      CALL fail(ErrStat, ErrMsg, 'bathymetry object is not initialized')
      RETURN
    END IF
    IF (.NOT. (CD_All_Finite([x_lo, x_hi, y_lo, y_hi]) .AND. x_lo <= x_hi .AND. y_lo <= y_hi)) THEN
      CALL fail(ErrStat, ErrMsg, 'bathymetry box bounds must be finite and ordered')
      RETURN
    END IF
    CALL locate_axis(bathy%x, x_lo, i0, t, clamped)
    CALL locate_axis(bathy%x, x_hi, i1, t, clamped)
    CALL locate_axis(bathy%y, y_lo, j0, t, clamped)
    CALL locate_axis(bathy%y, y_hi, j1, t, clamped)
    z_max = -MINVAL(bathy%depth(i0:i1 + 1, j0:j1 + 1))
    ! the crease allowance: the node range of the cells widened by one node on every side
    iw0 = MAX(1, i0 - 1); iw1 = MIN(SIZE(bathy%x), i1 + 2)
    jw0 = MAX(1, j0 - 1); jw1 = MIN(SIZE(bathy%y), j1 + 2)
    z_min = -MAXVAL(bathy%depth(iw0:iw1, jw0:jw1))
    z_max = z_max + CD_BATHY_CREASE_FRACTION*(-MINVAL(bathy%depth(iw0:iw1, jw0:jw1)) - z_min)
  END SUBROUTINE CD_Bathymetry_Max_Floor

  SUBROUTINE CD_Bathymetry_Floor_Gradient(bathy, xq, yq, z_floor, dfdx, dfdy, ErrStat, ErrMsg, crease_curvature)
    !! Return seabed elevation and horizontal gradients dz_floor/dx, dz_floor/dy.
    !! crease_curvature (optional): the second derivatives (z_xx, z_xy, z_yy) of the crease
    !! rounding at the point (zero outside the crease bands), for a contact tangent that
    !! follows the rounded surface; the twist of the bilinear cells is not included.
    TYPE(CD_BathymetryType), INTENT(IN) :: bathy
    REAL(wp), INTENT(IN) :: xq, yq
    REAL(wp), INTENT(OUT) :: z_floor, dfdx, dfdy
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    REAL(wp), INTENT(OUT), OPTIONAL :: crease_curvature(3)

    CALL floor_eval(bathy, xq, yq, z_floor, dfdx, dfdy, ErrStat, ErrMsg, curvature=crease_curvature)
  END SUBROUTINE CD_Bathymetry_Floor_Gradient

  PURE FUNCTION CD_Bathymetry_Rotate_Curvature(curv_g, cs) RESULT(curv_l)
    !! Surface curvature (z_xx, z_xy, z_yy) of the global frame expressed in a frame turned
    !! by the angle of cs = (cos, sin) about z (global x = cos xl - sin yl, y = sin xl +
    !! cos yl): H_l = R^T H_g R, as the gradient turns to g_l = R^T g_g.
    REAL(wp), INTENT(IN) :: curv_g(3), cs(2)
    REAL(wp) :: curv_l(3)
    REAL(wp) :: hg(2, 2), r(2, 2), hl(2, 2)
    hg = RESHAPE([curv_g(1), curv_g(2), curv_g(2), curv_g(3)], [2, 2])
    r = RESHAPE([cs(1), cs(2), -cs(2), cs(1)], [2, 2])
    hl = MATMUL(TRANSPOSE(r), MATMUL(hg, r))
    curv_l = [hl(1, 1), 0.5_wp*(hl(1, 2) + hl(2, 1)), hl(2, 2)]
  END FUNCTION CD_Bathymetry_Rotate_Curvature

  SUBROUTINE CD_Bathymetry_Seabed_Load(bathy, nodes, k_n, f, k_resid, ErrStat, ErrMsg)
    !! Variable-elevation penalty contact against the bathymetry surface.
    !! For node i, g_i = z_floor(x_i,y_i) - z_i is the vertical penetration. The contact
    !! is frictionless: the force acts along the local upward surface normal with the
    !! shared C1 touchdown law evaluated at the normal penetration (CD_Seabed_Normal_Contact;
    !! exactly the vertical law on a level patch). The residual tangent is the node's
    !! -d(force)/dq block, F' n n^T; in a crease band the force and tangent follow the
    !! rounded surface (the gradient and Hessian of the penalty potential there).
    TYPE(CD_BathymetryType), INTENT(IN) :: bathy
    REAL(wp), INTENT(IN) :: nodes(:, :)
    REAL(wp), INTENT(IN) :: k_n(:)
    REAL(wp), INTENT(OUT) :: f(:)
    REAL(wp), INTENT(OUT) :: k_resid(:, :)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg

    INTEGER :: n_nodes, i, ix, iz
    REAL(wp) :: z_floor, dfdx, dfdy, gap, fvec(3), jac(3, 3), curv(3)

    f = CD_ZERO
    k_resid = CD_ZERO
    ErrStat = CD_BATHY_OK
    ErrMsg = ''
    IF (.NOT. CD_Bathymetry_Is_Initialized(bathy)) THEN
      CALL fail(ErrStat, ErrMsg, 'bathymetry object is not initialized')
      RETURN
    END IF
    IF (SIZE(nodes, 1) /= 3) THEN
      CALL fail(ErrStat, ErrMsg, 'nodes must have shape (3, n_nodes)')
      RETURN
    END IF
    n_nodes = SIZE(nodes, 2)
    IF (SIZE(k_n) /= n_nodes) THEN
      CALL fail(ErrStat, ErrMsg, 'k_n must have shape (n_nodes)')
      RETURN
    END IF
    IF (SIZE(f) /= 3*n_nodes .OR. SIZE(k_resid, 1) /= 3*n_nodes .OR. SIZE(k_resid, 2) /= 3*n_nodes) THEN
      CALL fail(ErrStat, ErrMsg, 'f / k_resid shapes inconsistent with nodes')
      RETURN
    END IF
    IF (.NOT. CD_All_Finite(nodes)) THEN
      CALL fail(ErrStat, ErrMsg, 'node coordinates must be finite')
      RETURN
    END IF
    IF (.NOT. CD_All_Finite(k_n) .OR. ANY(k_n <= CD_ZERO)) THEN
      CALL fail(ErrStat, ErrMsg, 'k_n must be finite and positive')
      RETURN
    END IF

    DO i = 1, n_nodes
      CALL floor_eval(bathy, nodes(1, i), nodes(2, i), z_floor, dfdx, dfdy, ErrStat, ErrMsg, curvature=curv)
      IF (ErrStat /= CD_BATHY_OK) RETURN
      gap = z_floor - nodes(3, i)
      ix = 3*i - 2
      iz = ix + 2
      CALL CD_Seabed_Normal_Contact(gap, dfdx, dfdy, k_n(i), fvec, jac, curvature=curv)
      f(ix:iz) = fvec
      k_resid(ix:iz, ix:iz) = jac
    END DO
  END SUBROUTINE CD_Bathymetry_Seabed_Load

  SUBROUTINE floor_eval(bathy, xq, yq, z_floor, dfdx, dfdy, ErrStat, ErrMsg, rounded, curvature)
    !! The seabed surface and its gradient: bilinear in each cell, its creases rounded
    !! (crease_blend) unless rounded is .FALSE. (CD_Bathymetry_Grid_Floor).
    TYPE(CD_BathymetryType), INTENT(IN) :: bathy
    REAL(wp), INTENT(IN) :: xq, yq
    REAL(wp), INTENT(OUT) :: z_floor, dfdx, dfdy
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    LOGICAL, INTENT(IN), OPTIONAL :: rounded
    REAL(wp), INTENT(OUT), OPTIONAL :: curvature(3)

    INTEGER :: ix, iy
    REAL(wp) :: tx, ty
    REAL(wp) :: f00, f10, f01, f11, dx, dy
    LOGICAL :: clamp_x, clamp_y

    z_floor = CD_ZERO
    dfdx = CD_ZERO
    dfdy = CD_ZERO
    IF (PRESENT(curvature)) curvature = CD_ZERO
    ErrStat = CD_BATHY_OK
    ErrMsg = ''
    IF (.NOT. CD_Bathymetry_Is_Initialized(bathy)) THEN
      CALL fail(ErrStat, ErrMsg, 'bathymetry object is not initialized')
      RETURN
    END IF
    IF (.NOT. (CD_Is_Finite(xq) .AND. CD_Is_Finite(yq))) THEN
      CALL fail(ErrStat, ErrMsg, 'bathymetry query coordinates must be finite')
      RETURN
    END IF

    CALL locate_axis(bathy%x, xq, ix, tx, clamp_x)
    CALL locate_axis(bathy%y, yq, iy, ty, clamp_y)
    dx = bathy%x(ix + 1) - bathy%x(ix)
    dy = bathy%y(iy + 1) - bathy%y(iy)
    f00 = -bathy%depth(ix, iy)
    f10 = -bathy%depth(ix + 1, iy)
    f01 = -bathy%depth(ix, iy + 1)
    f11 = -bathy%depth(ix + 1, iy + 1)

    z_floor = (1.0_wp - tx)*(1.0_wp - ty)*f00 + tx*(1.0_wp - ty)*f10 + &
              (1.0_wp - tx)*ty*f01 + tx*ty*f11
    IF (.NOT. clamp_x) dfdx = ((1.0_wp - ty)*(f10 - f00) + ty*(f11 - f01))/dx
    IF (.NOT. clamp_y) dfdy = ((1.0_wp - tx)*(f01 - f00) + tx*(f11 - f10))/dy
    IF (PRESENT(rounded)) THEN
      IF (.NOT. rounded) RETURN
    END IF
    IF (bathy%nx > 2 .OR. bathy%ny > 2) &
      CALL crease_blend(bathy, xq, yq, ix, iy, tx, ty, clamp_x, clamp_y, z_floor, dfdx, dfdy, curvature)
  END SUBROUTINE floor_eval

  SUBROUTINE crease_blend(bathy, xq, yq, ix, iy, tx, ty, clamp_x, clamp_y, z_floor, dfdx, dfdy, curvature)
    !! Rounding of the creases of the bilinear surface (see the module header). The
    !! surface is the tensor product of the two axes' piecewise-linear interpolants; each
    !! interpolant has a slope jump J_k at an interior grid line k, which is rounded within
    !! the band |u| < delta_k (u the distance from the line, delta_k =
    !! CD_BATHY_CREASE_FRACTION times the smaller adjacent spacing) by adding J_k h(u), with
    !! h(u) = (delta_k - |u|)^3/(6 delta_k^2): h'(0+) - h'(0-) = -1 cancels the slope jump,
    !! and h, h' and h'' vanish at |u| = delta_k, so the rounded interpolant is C2 (its
    !! curvature J (delta - |u|)/delta^2 has the sign of the jump: a valley stays convex).
    !! Applied in both directions, the surface is f + h_x J_x(y) + h_y (J_y(x) + h_x M),
    !! with J_x(y) the jumps of the grid rows across the x line interpolated linearly in y,
    !! J_y(x) likewise, and M the mixed second difference of the grid at the crossing of
    !! the two lines (the jump of J_x across the y line). It is the tensor product of C2
    !! interpolants, so its height, gradient and curvature are continuous everywhere
    !! within the grid; it equals the bilinear surface outside the bands and moves it by
    !! at most |J| delta/6. A jump that would
    !! move the surface by less than CD_BATHY_CREASE_MIN_HEIGHT (a plane rounded to the
    !! digits of its file) counts as none, so a planar grid and every patch without a
    !! crease are exactly bilinear. The grid edges are not rounded (outside the grid the
    !! surface is held level).
    !! curvature (optional): (z_xx, z_xy, z_yy) of the rounding terms; left unchanged
    !! (zero) outside the bands.
    TYPE(CD_BathymetryType), INTENT(IN) :: bathy
    REAL(wp), INTENT(IN) :: xq, yq, tx, ty
    INTEGER, INTENT(IN) :: ix, iy
    LOGICAL, INTENT(IN) :: clamp_x, clamp_y
    REAL(wp), INTENT(INOUT) :: z_floor, dfdx, dfdy
    REAL(wp), INTENT(INOUT), OPTIONAL :: curvature(3)
    INTEGER :: kx, ky
    REAL(wp) :: u, v, dlx, dly, hx, hxp, hxpp, hy, hyp, hypp, jx0, jx1, jy0, jy1, jxm, jxc, jxn, mxy
    REAL(wp) :: jx, jxp, jy, jyp, c
    LOGICAL :: on_x, on_y, on_m

    kx = 0
    ky = 0
    u = CD_ZERO
    v = CD_ZERO
    dlx = CD_ZERO
    dly = CD_ZERO
    IF (.NOT. clamp_x) CALL crease_band(bathy%x, ix, xq, kx, u, dlx)
    IF (.NOT. clamp_y) CALL crease_band(bathy%y, iy, yq, ky, v, dly)
    IF (kx == 0 .AND. ky == 0) RETURN
    hx = CD_ZERO
    hxp = CD_ZERO
    hxpp = CD_ZERO
    jx0 = CD_ZERO
    jx1 = CD_ZERO
    on_x = .FALSE.
    on_m = .FALSE.
    IF (kx > 0) THEN
      CALL crease_fillet(u, dlx, kx == ix, hx, hxp, hxpp)
      CALL x_jump(bathy, kx, iy, dlx, jx0, on_x)
      CALL x_jump(bathy, kx, iy + 1, dlx, jx1, on_m)
      on_x = on_x .OR. on_m
    END IF
    hy = CD_ZERO
    hyp = CD_ZERO
    hypp = CD_ZERO
    jy0 = CD_ZERO
    jy1 = CD_ZERO
    on_y = .FALSE.
    mxy = CD_ZERO
    on_m = .FALSE.
    IF (ky > 0) THEN
      CALL crease_fillet(v, dly, ky == iy, hy, hyp, hypp)
      CALL y_jump(bathy, ix, ky, dly, jy0, on_y)
      CALL y_jump(bathy, ix + 1, ky, dly, jy1, on_m)
      on_y = on_y .OR. on_m
      on_m = .FALSE.
      IF (kx > 0) THEN
        ! the jump of J_x across the y line: its rows ky-1, ky and ky+1
        CALL x_jump(bathy, kx, ky - 1, dlx, jxm, on_m)
        CALL x_jump(bathy, kx, ky, dlx, jxc, on_m)
        CALL x_jump(bathy, kx, ky + 1, dlx, jxn, on_m)
        mxy = (jxn - jxc)/(bathy%y(ky + 1) - bathy%y(ky)) - (jxc - jxm)/(bathy%y(ky) - bathy%y(ky - 1))
        on_m = ABS(mxy)*dlx*dly/36.0_wp > CD_BATHY_CREASE_MIN_HEIGHT
        IF (.NOT. on_m) mxy = CD_ZERO
      END IF
    END IF
    IF (on_x) THEN
      jx = (1.0_wp - ty)*jx0 + ty*jx1
      jxp = CD_ZERO
      IF (.NOT. clamp_y) jxp = (jx1 - jx0)/(bathy%y(iy + 1) - bathy%y(iy))
      z_floor = z_floor + hx*jx
      dfdx = dfdx + hxp*jx
      dfdy = dfdy + hx*jxp
      IF (PRESENT(curvature)) THEN
        curvature(1) = curvature(1) + hxpp*jx
        curvature(2) = curvature(2) + hxp*jxp
      END IF
    END IF
    IF (on_y .OR. on_m) THEN
      jy = (1.0_wp - tx)*jy0 + tx*jy1
      jyp = CD_ZERO
      IF (.NOT. clamp_x) jyp = (jy1 - jy0)/(bathy%x(ix + 1) - bathy%x(ix))
      c = jy + hx*mxy
      z_floor = z_floor + hy*c
      dfdx = dfdx + hy*(jyp + hxp*mxy)
      dfdy = dfdy + hyp*c
      IF (PRESENT(curvature)) THEN
        curvature(1) = curvature(1) + hy*hxpp*mxy
        curvature(2) = curvature(2) + hyp*(jyp + hxp*mxy)
        curvature(3) = curvature(3) + hypp*c
      END IF
    END IF
  END SUBROUTINE crease_blend

  PURE SUBROUTINE crease_band(axis, i0, q, k, u, dl)
    !! The interior grid line k whose crease band |q - axis(k)| < dl holds q (0: none), for
    !! q in the cell [axis(i0), axis(i0+1)]; u = q - axis(k).
    REAL(wp), INTENT(IN) :: axis(:), q
    INTEGER, INTENT(IN) :: i0
    INTEGER, INTENT(OUT) :: k
    REAL(wp), INTENT(OUT) :: u, dl
    k = 0
    u = CD_ZERO
    dl = CD_ZERO
    IF (i0 > 1) THEN
      dl = CD_BATHY_CREASE_FRACTION*MIN(axis(i0) - axis(i0 - 1), axis(i0 + 1) - axis(i0))
      u = q - axis(i0)
      IF (u < dl) THEN
        k = i0
        RETURN
      END IF
    END IF
    IF (i0 + 1 < SIZE(axis)) THEN
      dl = CD_BATHY_CREASE_FRACTION*MIN(axis(i0 + 1) - axis(i0), axis(i0 + 2) - axis(i0 + 1))
      u = q - axis(i0 + 1)
      IF (-u < dl) THEN
        k = i0 + 1
        RETURN
      END IF
    END IF
    u = CD_ZERO
    dl = CD_ZERO
  END SUBROUTINE crease_band

  PURE SUBROUTINE crease_fillet(u, dl, after, h, hp, hpp)
    !! h(u) = (dl - |u|)^3/(6 dl^2) and its first and second derivatives; after: the query
    !! cell lies after the line (u >= 0), so that at u = 0 the first derivative is the
    !! one-sided value of that cell.
    REAL(wp), INTENT(IN) :: u, dl
    LOGICAL, INTENT(IN) :: after
    REAL(wp), INTENT(OUT) :: h, hp, hpp
    REAL(wp) :: r
    r = dl - ABS(u)
    h = r**3/(6.0_wp*dl*dl)
    hp = r*r/(2.0_wp*dl*dl)
    IF (after) hp = -hp
    hpp = r/(dl*dl)
  END SUBROUTINE crease_fillet

  PURE SUBROUTINE x_jump(bathy, k, j, dl, jump, active)
    !! Slope jump of grid row j across the interior x line k (right slope less left
    !! slope of z_floor = -depth); zero, and active unchanged, when the fillet of width dl
    !! would move the surface by no more than CD_BATHY_CREASE_MIN_HEIGHT. active is set otherwise.
    TYPE(CD_BathymetryType), INTENT(IN) :: bathy
    INTEGER, INTENT(IN) :: k, j
    REAL(wp), INTENT(IN) :: dl
    REAL(wp), INTENT(OUT) :: jump
    LOGICAL, INTENT(INOUT) :: active
    jump = (bathy%depth(k, j) - bathy%depth(k + 1, j))/(bathy%x(k + 1) - bathy%x(k)) - &
           (bathy%depth(k - 1, j) - bathy%depth(k, j))/(bathy%x(k) - bathy%x(k - 1))
    IF (ABS(jump)*dl/6.0_wp > CD_BATHY_CREASE_MIN_HEIGHT) THEN
      active = .TRUE.
    ELSE
      jump = CD_ZERO
    END IF
  END SUBROUTINE x_jump

  PURE SUBROUTINE y_jump(bathy, i, k, dl, jump, active)
    !! Slope jump of grid column i across the interior y line k (see x_jump).
    TYPE(CD_BathymetryType), INTENT(IN) :: bathy
    INTEGER, INTENT(IN) :: i, k
    REAL(wp), INTENT(IN) :: dl
    REAL(wp), INTENT(OUT) :: jump
    LOGICAL, INTENT(INOUT) :: active
    jump = (bathy%depth(i, k) - bathy%depth(i, k + 1))/(bathy%y(k + 1) - bathy%y(k)) - &
           (bathy%depth(i, k - 1) - bathy%depth(i, k))/(bathy%y(k) - bathy%y(k - 1))
    IF (ABS(jump)*dl/6.0_wp > CD_BATHY_CREASE_MIN_HEIGHT) THEN
      active = .TRUE.
    ELSE
      jump = CD_ZERO
    END IF
  END SUBROUTINE y_jump

  SUBROUTINE locate_axis(axis, q, i0, t, clamped)
    REAL(wp), INTENT(IN) :: axis(:), q
    INTEGER, INTENT(OUT) :: i0
    REAL(wp), INTENT(OUT) :: t
    LOGICAL, INTENT(OUT) :: clamped

    INTEGER :: i, n

    n = SIZE(axis)
    clamped = .FALSE.
    IF (q <= axis(1)) THEN
      i0 = 1
      t = CD_ZERO
      clamped = q < axis(1)
      RETURN
    END IF
    IF (q >= axis(n)) THEN
      i0 = n - 1
      t = 1.0_wp
      clamped = q > axis(n)
      RETURN
    END IF
    DO i = 1, n - 1
      IF (q >= axis(i) .AND. q <= axis(i + 1)) THEN
        i0 = i
        t = (q - axis(i))/(axis(i + 1) - axis(i))
        RETURN
      END IF
    END DO

    i0 = n - 1
    t = 1.0_wp
    clamped = .TRUE.
  END SUBROUTINE locate_axis

  SUBROUTINE fail(ErrStat, ErrMsg, msg)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    CHARACTER(*), INTENT(IN) :: msg

    ErrStat = CD_BATHY_BADINPUT
    ErrMsg = 'CableDyn_Bathymetry: '//msg
  END SUBROUTINE fail

END MODULE CableDyn_Bathymetry
