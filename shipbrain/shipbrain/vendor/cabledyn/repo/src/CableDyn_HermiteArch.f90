! File: src/CableDyn_HermiteArch.f90
! SPDX-License-Identifier: Apache-2.0
! Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
MODULE CableDyn_HermiteArch
  !! Cubic-Hermite arch seeding for the lazy-wave route of the secondary Cosserat path:
  !! a smooth cubic-Hermite centreline between two line ends, converted to the 6-DOF
  !! Cosserat [position, rotation-vector] state used by CableDyn_FiniteEIModel and
  !! CableDyn_CosseratStatic.
  !! The formulation is the standard cubic Hermite interpolation with dimensional
  !! endpoint tangent handles. It does not solve equilibrium by itself; it builds a
  !! validated, chart-safe finite-EI initial state for the dedicated lazy-wave continuation.
  USE CableDyn_Precision, ONLY: wp, CD_ZERO, CD_ONE, CD_All_Finite, CD_Is_Finite
  IMPLICIT NONE
  PRIVATE

  PUBLIC :: CD_Hermite_Arch_Evaluate
  PUBLIC :: CD_FiniteEI_Hermite_Arch_Seed
  PUBLIC :: CD_FiniteEI_Hermite_Arch_Seed_LengthMatched
  PUBLIC :: CD_Hermite_Seed_Polyline_Length
  INTEGER, PARAMETER, PUBLIC :: CD_HARCH_OK = 0, CD_HARCH_BADINPUT = 1

  REAL(wp), PARAMETER :: PI = 3.14159265358979323846_wp
  REAL(wp), PARAMETER :: CHART_MARGIN = 1.0e-6_wp
  REAL(wp), PARAMETER :: GEOM_TOL = 1.0e-12_wp

CONTAINS

  SUBROUTINE CD_Hermite_Arch_Evaluate(p0, p1, t0, t1, handle0, handle1, u, &
                                      x, dx_du, d2x_du2, curvature, ErrStat, ErrMsg)
    !! Evaluate the dimensional cubic-Hermite arch at parametric station u in [0, 1].
    !!
    !! p0/p1 are endpoint positions, t0/t1 are endpoint tangent directions, and
    !! handle0/handle1 are dimensional tangent-handle lengths. The returned curvature
    !! is invariant to the u parametrisation: |x_u x x_uu| / |x_u|^3.
    REAL(wp), INTENT(IN) :: p0(3), p1(3), t0(3), t1(3)
    REAL(wp), INTENT(IN) :: handle0, handle1, u
    REAL(wp), INTENT(OUT) :: x(3), dx_du(3), d2x_du2(3), curvature
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg

    REAL(wp) :: t0u(3), t1u(3), m0(3), m1(3), uu, h00, h10, h01, h11
    REAL(wp) :: dh00, dh10, dh01, dh11, d2h00, d2h10, d2h01, d2h11
    REAL(wp) :: speed, cr(3)

    ErrStat = CD_HARCH_OK
    ErrMsg = ''
    x = CD_ZERO
    dx_du = CD_ZERO
    d2x_du2 = CD_ZERO
    curvature = CD_ZERO

    IF (.NOT. CD_All_Finite(p0) .OR. .NOT. CD_All_Finite(p1) .OR. &
        .NOT. CD_All_Finite(t0) .OR. .NOT. CD_All_Finite(t1) .OR. &
        .NOT. CD_Is_Finite(handle0) .OR. .NOT. CD_Is_Finite(handle1) .OR. &
        .NOT. CD_Is_Finite(u)) THEN
      CALL fail('inputs must be finite'); RETURN
    END IF
    IF (handle0 <= CD_ZERO .OR. handle1 <= CD_ZERO) THEN
      CALL fail('Hermite tangent handles must be positive'); RETURN
    END IF
    IF (u < -GEOM_TOL .OR. u > CD_ONE + GEOM_TOL) THEN
      CALL fail('parametric coordinate u must lie in [0, 1]'); RETURN
    END IF

    t0u = t0
    CALL normalize(t0u, ErrStat, ErrMsg)
    IF (ErrStat /= CD_HARCH_OK) THEN
      ErrMsg = 'CD_Hermite_Arch_Evaluate: degenerate t0'; RETURN
    END IF
    t1u = t1
    CALL normalize(t1u, ErrStat, ErrMsg)
    IF (ErrStat /= CD_HARCH_OK) THEN
      ErrMsg = 'CD_Hermite_Arch_Evaluate: degenerate t1'; RETURN
    END IF

    uu = MAX(CD_ZERO, MIN(CD_ONE, u))
    m0 = handle0*t0u
    m1 = handle1*t1u

    h00 = 2.0_wp*uu**3 - 3.0_wp*uu**2 + CD_ONE
    h10 = uu**3 - 2.0_wp*uu**2 + uu
    h01 = -2.0_wp*uu**3 + 3.0_wp*uu**2
    h11 = uu**3 - uu**2

    dh00 = 6.0_wp*uu**2 - 6.0_wp*uu
    dh10 = 3.0_wp*uu**2 - 4.0_wp*uu + CD_ONE
    dh01 = -6.0_wp*uu**2 + 6.0_wp*uu
    dh11 = 3.0_wp*uu**2 - 2.0_wp*uu

    d2h00 = 12.0_wp*uu - 6.0_wp
    d2h10 = 6.0_wp*uu - 4.0_wp
    d2h01 = -12.0_wp*uu + 6.0_wp
    d2h11 = 6.0_wp*uu - 2.0_wp

    x = h00*p0 + h10*m0 + h01*p1 + h11*m1
    dx_du = dh00*p0 + dh10*m0 + dh01*p1 + dh11*m1
    d2x_du2 = d2h00*p0 + d2h10*m0 + d2h01*p1 + d2h11*m1
    speed = norm3(dx_du)
    IF (speed <= GEOM_TOL) THEN
      CALL fail('Hermite arch has a stationary tangent'); RETURN
    END IF
    cr = cross3(dx_du, d2x_du2)
    curvature = norm3(cr)/(speed**3)

  CONTAINS

    SUBROUTINE fail(msg)
      CHARACTER(*), INTENT(IN) :: msg
      ErrStat = CD_HARCH_BADINPUT
      ErrMsg = 'CD_Hermite_Arch_Evaluate: '//msg
    END SUBROUTINE fail

  END SUBROUTINE CD_Hermite_Arch_Evaluate

  SUBROUTINE CD_FiniteEI_Hermite_Arch_Seed(end_a, end_b, tan_a, tan_b, l0, handle_scale, &
                                           q0, nodes_ref, arc, curvature, ErrStat, ErrMsg)
    !! Build a finite-EI Cosserat seed from a cubic-Hermite arch.
    !!
    !! q0 stores [position, rotation-vector] per node. Positions are sampled at
    !! cumulative unstretched-length fractions from l0. Rotations are the shortest
    !! chart-safe rotation vectors mapping the straight reference tangent to the local
    !! Hermite tangent. nodes_ref is a straight reference rod with the same arc stations.
    REAL(wp), INTENT(IN) :: end_a(3), end_b(3), tan_a(3), tan_b(3)
    REAL(wp), INTENT(IN) :: l0(:)
    REAL(wp), INTENT(IN) :: handle_scale
    REAL(wp), INTENT(OUT) :: q0(:)
    REAL(wp), INTENT(OUT) :: nodes_ref(:, :)
    REAL(wp), INTENT(OUT) :: arc(:), curvature(:)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg

    INTEGER :: n_elem, n_nodes, nd, base
    REAL(wp) :: total_l, chord_vec(3), ref_tan(3), chord_l, u, handle_l
    REAL(wp) :: x(3), dx_du(3), d2x_du2(3), local_tan(3), rotvec(3), kappa

    ErrStat = CD_HARCH_OK
    ErrMsg = ''
    q0 = CD_ZERO
    nodes_ref = CD_ZERO
    arc = CD_ZERO
    curvature = CD_ZERO

    n_elem = SIZE(l0)
    n_nodes = n_elem + 1
    IF (n_elem < 1) THEN
      CALL fail('l0 must contain at least one element'); RETURN
    END IF
    IF (SIZE(q0) /= 6*n_nodes .OR. SIZE(nodes_ref, 1) /= 3 .OR. SIZE(nodes_ref, 2) /= n_nodes .OR. &
        SIZE(arc) /= n_nodes .OR. SIZE(curvature) /= n_nodes) THEN
      CALL fail('q0, nodes_ref, arc, and curvature shapes are inconsistent with l0'); RETURN
    END IF
    IF (.NOT. CD_All_Finite(end_a) .OR. .NOT. CD_All_Finite(end_b) .OR. &
        .NOT. CD_All_Finite(tan_a) .OR. .NOT. CD_All_Finite(tan_b) .OR. &
        .NOT. CD_All_Finite(l0) .OR. .NOT. CD_Is_Finite(handle_scale)) THEN
      CALL fail('inputs must be finite'); RETURN
    END IF
    IF (ANY(l0 <= CD_ZERO)) THEN
      CALL fail('l0 must be strictly positive'); RETURN
    END IF
    IF (handle_scale <= CD_ZERO) THEN
      CALL fail('handle_scale must be strictly positive'); RETURN
    END IF

    total_l = SUM(l0)
    chord_vec = end_b - end_a
    chord_l = norm3(chord_vec)
    IF (chord_l <= GEOM_TOL) THEN
      CALL fail('endpoints must be distinct'); RETURN
    END IF
    ref_tan = chord_vec/chord_l
    handle_l = handle_scale*total_l

    DO nd = 2, n_nodes
      arc(nd) = arc(nd - 1) + l0(nd - 1)
    END DO

    DO nd = 1, n_nodes
      u = arc(nd)/total_l
      CALL CD_Hermite_Arch_Evaluate(end_a, end_b, tan_a, tan_b, handle_l, handle_l, u, &
                                    x, dx_du, d2x_du2, kappa, ErrStat, ErrMsg)
      IF (ErrStat /= CD_HARCH_OK) THEN
        ErrMsg = 'CD_FiniteEI_Hermite_Arch_Seed: '//TRIM(ErrMsg); RETURN
      END IF
      local_tan = dx_du
      CALL normalize(local_tan, ErrStat, ErrMsg)
      IF (ErrStat /= CD_HARCH_OK) THEN
        ErrMsg = 'CD_FiniteEI_Hermite_Arch_Seed: degenerate Hermite tangent'; RETURN
      END IF
      CALL shortest_arc_rotvec(ref_tan, local_tan, rotvec, ErrStat, ErrMsg)
      IF (ErrStat /= CD_HARCH_OK) THEN
        ErrMsg = 'CD_FiniteEI_Hermite_Arch_Seed: '//TRIM(ErrMsg); RETURN
      END IF

      nodes_ref(:, nd) = arc(nd)*ref_tan
      base = 6*(nd - 1)
      q0(base + 1:base + 3) = x
      q0(base + 4:base + 6) = rotvec
      curvature(nd) = kappa
    END DO

  CONTAINS

    SUBROUTINE fail(msg)
      CHARACTER(*), INTENT(IN) :: msg
      ErrStat = CD_HARCH_BADINPUT
      ErrMsg = 'CD_FiniteEI_Hermite_Arch_Seed: '//msg
    END SUBROUTINE fail

  END SUBROUTINE CD_FiniteEI_Hermite_Arch_Seed

  SUBROUTINE CD_FiniteEI_Hermite_Arch_Seed_LengthMatched(end_a, end_b, tan_a, tan_b, l0, &
                                                         q0, nodes_ref, arc, curvature, handle_scale, &
                                                         ErrStat, ErrMsg)
    !! Build a finite-EI Hermite arch seed whose sampled polyline length matches SUM(l0).
    !!
    !! The one-parameter solve scales both endpoint tangent handles by the same factor.
    !! It brackets by expanding the handle length, then bisects to a length tolerance
    !! tied to the total unstretched line length. The final seed is not shorter than the
    !! target length by more than that tolerance (1e-10 relative), avoiding an initial
    !! compressive lazy-wave state.
    REAL(wp), INTENT(IN) :: end_a(3), end_b(3), tan_a(3), tan_b(3)
    REAL(wp), INTENT(IN) :: l0(:)
    REAL(wp), INTENT(OUT) :: q0(:)
    REAL(wp), INTENT(OUT) :: nodes_ref(:, :)
    REAL(wp), INTENT(OUT) :: arc(:), curvature(:)
    REAL(wp), INTENT(OUT) :: handle_scale
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg

    REAL(wp), ALLOCATABLE :: q_trial(:), nodes_trial(:, :), arc_trial(:), curvature_trial(:)
    REAL(wp) :: total_l, lo, hi, mid, trial_len, tol
    INTEGER :: n_elem, n_nodes, iter, es
    CHARACTER(1024) :: em

    ErrStat = CD_HARCH_OK
    ErrMsg = ''
    handle_scale = CD_ZERO
    n_elem = SIZE(l0)
    n_nodes = n_elem + 1
    IF (n_elem < 1) THEN
      CALL fail('l0 must contain at least one element'); RETURN
    END IF
    IF (SIZE(q0) /= 6*n_nodes .OR. SIZE(nodes_ref, 1) /= 3 .OR. SIZE(nodes_ref, 2) /= n_nodes .OR. &
        SIZE(arc) /= n_nodes .OR. SIZE(curvature) /= n_nodes) THEN
      CALL fail('q0, nodes_ref, arc, and curvature shapes are inconsistent with l0'); RETURN
    END IF
    IF (.NOT. CD_All_Finite(l0) .OR. ANY(l0 <= CD_ZERO)) THEN
      CALL fail('l0 must be finite and strictly positive'); RETURN
    END IF

    total_l = SUM(l0)
    tol = 1.0e-10_wp*MAX(CD_ONE, total_l)
    ALLOCATE (q_trial(SIZE(q0)), nodes_trial(3, n_nodes), arc_trial(n_nodes), curvature_trial(n_nodes))

    lo = 0.05_wp
    hi = CD_ONE
    DO
      CALL CD_FiniteEI_Hermite_Arch_Seed(end_a, end_b, tan_a, tan_b, l0, hi, &
                                         q_trial, nodes_trial, arc_trial, curvature_trial, es, em)
      IF (es /= CD_HARCH_OK) EXIT
      CALL CD_Hermite_Seed_Polyline_Length(q_trial, trial_len, es, em)
      IF (es /= CD_HARCH_OK) EXIT
      IF (trial_len >= total_l .OR. hi >= 16.0_wp) EXIT
      hi = 1.5_wp*hi
    END DO
    IF (es /= CD_HARCH_OK) THEN
      CALL fail('Hermite seed failed during bracket search: '//TRIM(em)); RETURN
    END IF
    IF (trial_len < total_l - tol) THEN
      CALL fail('Hermite seed could not span the unstretched length'); RETURN
    END IF

    DO iter = 1, 48
      mid = 0.5_wp*(lo + hi)
      CALL CD_FiniteEI_Hermite_Arch_Seed(end_a, end_b, tan_a, tan_b, l0, mid, &
                                         q_trial, nodes_trial, arc_trial, curvature_trial, es, em)
      IF (es /= CD_HARCH_OK) THEN
        CALL fail('Hermite seed failed during handle search: '//TRIM(em)); RETURN
      END IF
      CALL CD_Hermite_Seed_Polyline_Length(q_trial, trial_len, es, em)
      IF (es /= CD_HARCH_OK) THEN
        CALL fail('Hermite length evaluation failed during handle search: '//TRIM(em)); RETURN
      END IF
      IF (ABS(trial_len - total_l) <= tol) THEN
        hi = mid
        EXIT
      END IF
      IF (trial_len < total_l) THEN
        lo = mid
      ELSE
        hi = mid
      END IF
    END DO

    CALL CD_FiniteEI_Hermite_Arch_Seed(end_a, end_b, tan_a, tan_b, l0, hi, q0, nodes_ref, arc, curvature, es, em)
    IF (es /= CD_HARCH_OK) THEN
      CALL fail('final Hermite seed failed: '//TRIM(em)); RETURN
    END IF
    CALL CD_Hermite_Seed_Polyline_Length(q0, trial_len, es, em)
    IF (es /= CD_HARCH_OK) THEN
      CALL fail('final Hermite length evaluation failed: '//TRIM(em)); RETURN
    END IF
    IF (trial_len < total_l - tol) THEN
      CALL fail('final Hermite seed is shorter than the unstretched length'); RETURN
    END IF
    handle_scale = hi

  CONTAINS

    SUBROUTINE fail(msg)
      CHARACTER(*), INTENT(IN) :: msg
      ErrStat = CD_HARCH_BADINPUT
      ErrMsg = 'CD_FiniteEI_Hermite_Arch_Seed_LengthMatched: '//msg
    END SUBROUTINE fail

  END SUBROUTINE CD_FiniteEI_Hermite_Arch_Seed_LengthMatched

  SUBROUTINE CD_Hermite_Seed_Polyline_Length(q_seed, length, ErrStat, ErrMsg)
    !! Measure the translational polyline length of a 6-DOF/node Cosserat seed.
    REAL(wp), INTENT(IN) :: q_seed(:)
    REAL(wp), INTENT(OUT) :: length
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg

    INTEGER :: n_nodes, nd
    REAL(wp) :: dr(3)

    ErrStat = CD_HARCH_OK
    ErrMsg = ''
    length = CD_ZERO
    IF (SIZE(q_seed) < 12 .OR. MOD(SIZE(q_seed), 6) /= 0) THEN
      CALL fail('q_seed must have shape 6*n_nodes with n_nodes >= 2'); RETURN
    END IF
    IF (.NOT. CD_All_Finite(q_seed)) THEN
      CALL fail('q_seed must be finite'); RETURN
    END IF
    n_nodes = SIZE(q_seed)/6
    DO nd = 1, n_nodes - 1
      dr = q_seed(6*nd + 1:6*nd + 3) - q_seed(6*nd - 5:6*nd - 3)
      length = length + norm3(dr)
    END DO

  CONTAINS

    SUBROUTINE fail(msg)
      CHARACTER(*), INTENT(IN) :: msg
      ErrStat = CD_HARCH_BADINPUT
      ErrMsg = 'CD_Hermite_Seed_Polyline_Length: '//msg
    END SUBROUTINE fail

  END SUBROUTINE CD_Hermite_Seed_Polyline_Length

  SUBROUTINE shortest_arc_rotvec(a, b, rotvec, ErrStat, ErrMsg)
    !! Shortest-arc rotation vector mapping unit vector a to unit vector b.
    REAL(wp), INTENT(IN) :: a(3), b(3)
    REAL(wp), INTENT(OUT) :: rotvec(3)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    REAL(wp) :: aa(3), bb(3), cr(3), sine, cosine, angle

    ErrStat = CD_HARCH_OK
    ErrMsg = ''
    rotvec = CD_ZERO
    aa = a
    bb = b
    CALL normalize(aa, ErrStat, ErrMsg)
    IF (ErrStat /= CD_HARCH_OK) THEN
      ErrMsg = 'degenerate source tangent'; RETURN
    END IF
    CALL normalize(bb, ErrStat, ErrMsg)
    IF (ErrStat /= CD_HARCH_OK) THEN
      ErrMsg = 'degenerate target tangent'; RETURN
    END IF

    cr = cross3(aa, bb)
    sine = norm3(cr)
    cosine = MAX(-CD_ONE, MIN(CD_ONE, DOT_PRODUCT(aa, bb)))
    IF (sine <= GEOM_TOL) THEN
      IF (cosine > CD_ZERO) THEN
        rotvec = CD_ZERO; RETURN
      END IF
      ErrStat = CD_HARCH_BADINPUT
      ErrMsg = 'reference tangent is antiparallel to a local Hermite tangent'
      RETURN
    END IF
    angle = ATAN2(sine, cosine)
    rotvec = (angle/sine)*cr
    IF (norm3(rotvec) >= PI - CHART_MARGIN) THEN
      ErrStat = CD_HARCH_BADINPUT
      ErrMsg = 'tangent alignment reached the |theta| < pi chart boundary'
    END IF
  END SUBROUTINE shortest_arc_rotvec

  SUBROUTINE normalize(v, ErrStat, ErrMsg)
    !! Normalize a 3-vector in place.
    REAL(wp), INTENT(INOUT) :: v(3)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    REAL(wp) :: nrm

    ErrStat = CD_HARCH_OK
    ErrMsg = ''
    nrm = norm3(v)
    IF (.NOT. CD_Is_Finite(nrm) .OR. nrm <= GEOM_TOL) THEN
      ErrStat = CD_HARCH_BADINPUT
      ErrMsg = 'cannot normalize a zero vector'
      RETURN
    END IF
    v = v/nrm
  END SUBROUTINE normalize

  PURE FUNCTION norm3(v) RESULT(nrm)
    !! Euclidean norm of a 3-vector.
    REAL(wp), INTENT(IN) :: v(3)
    REAL(wp) :: nrm
    nrm = SQRT(DOT_PRODUCT(v, v))
  END FUNCTION norm3

  PURE FUNCTION cross3(a, b) RESULT(c)
    !! Cross product of two 3-vectors.
    REAL(wp), INTENT(IN) :: a(3), b(3)
    REAL(wp) :: c(3)
    c = [a(2)*b(3) - a(3)*b(2), &
         a(3)*b(1) - a(1)*b(3), &
         a(1)*b(2) - a(2)*b(1)]
  END FUNCTION cross3

END MODULE CableDyn_HermiteArch
