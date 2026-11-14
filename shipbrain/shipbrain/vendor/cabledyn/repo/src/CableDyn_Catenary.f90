! File: src/CableDyn_Catenary.f90
! SPDX-License-Identifier: Apache-2.0
! Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
MODULE CableDyn_Catenary
  !! Independent analytical catenary initial guess for the positions-only EI=0
  !! cable path -- the robust static-initialisation seed that, with the load
  !! continuation in CableDyn_Static, lets the grounded / slack regimes converge
  !! without a hand-supplied shape. Positions only (the EI=0 state carries no
  !! rotations).
  !!
  !! The construction is per segment, so each element carries its own axial
  !! stiffness EA and signed submerged weight (positive = downward, negative =
  !! buoyant). A buoyant segment flips the integrated vertical tension and so can
  !! build a lazy-wave turning point. The seed is the exact elastic catenary in the
  !! vertical plane through the endpoints, on a frictionless planar seabed
  !! z_b(x) = z_bed + m x (by default the horizontal plane through the anchor).
  !!
  !! Anchor on the seabed: two endpoint equations close two unknowns, the horizontal
  !! tension H and one complementarity coordinate s. For s >= 0 the line has a
  !! grounded run of reference length s along the seabed and lifts off tangent to
  !! it; for s < 0 nothing is grounded and the anchor tangent is steeper than the bed
  !! by the uplift -s*w_ref >= 0. The branches meet continuously at s = 0, so one
  !! bounded Levenberg-Marquardt solve in (ln H, s) selects the physical branch
  !! (a grounded run exists exactly when the lift-off uplift is zero).
  !! Anchor above the seabed: the fully suspended span is exact when it clears the
  !! bed; otherwise the line descends to a tangent touchdown, runs along the bed and
  !! lifts off, closed by (ln H, descent length, grounded length) against the two
  !! endpoint equations and the touchdown height. A line hung in mid-water leaves the
  !! anchor uplift free in sign and grounds nothing. A vertical span (zero horizontal
  !! offset) is solved in closed form. No external optimiser is used.
  !!
  !! The closed forms are those of the classical extensible elastic catenary.
  USE CableDyn_Precision, ONLY: wp, CD_ZERO, CD_ONE, CD_All_Finite, CD_Is_Finite
  IMPLICIT NONE
  PRIVATE
  PUBLIC :: CD_Catenary_Seed
  ! ErrStat: 0 ok; 1 invalid input; 2 geometry admits no in-plane catenary seed;
  ! 3 the endpoint closure did not converge.
  INTEGER, PARAMETER, PUBLIC :: CD_CAT_OK = 0
  INTEGER, PARAMETER, PUBLIC :: CD_CAT_BADINPUT = 1
  INTEGER, PARAMETER, PUBLIC :: CD_CAT_NOSEED = 2
  INTEGER, PARAMETER, PUBLIC :: CD_CAT_NOCONVERGE = 3

  ! Closure modes: a free-sign suspended span, the complementarity closure with the
  ! anchor on the bed, and the touched closure of an anchor above the bed.
  INTEGER, PARAMETER :: MODE_FREE = 1, MODE_BED = 2, MODE_TOUCH = 3
  ! Finite residual returned for an inadmissible parameter set (a slack grounded run);
  ! the Levenberg-Marquardt acceptance test then rejects the step.
  REAL(wp), PARAMETER :: BAD_RESIDUAL = 1.0e6_wp

  TYPE :: cat_problem
    !! One endpoint-closure problem in the local anchor frame (x along the horizontal
    !! span, z up, anchor at the origin).
    REAL(wp), ALLOCATABLE :: l(:), ea(:), w(:)
    REAL(wp) :: hspan = CD_ZERO, rise = CD_ZERO, scale = CD_ONE, total = CD_ZERO
    REAL(wp) :: wref = CD_ONE, h_ref = CD_ONE, total_weight = CD_ZERO
    REAL(wp) :: z0 = CD_ZERO, slope = CD_ZERO, cth = CD_ONE, sth = CD_ZERO
    INTEGER :: mode = MODE_BED
  END TYPE cat_problem

CONTAINS

  SUBROUTINE CD_Catenary_Seed(anchor, fairlead, lengths, ea, weight, positions, &
                              horizontal_tension, grounded_length, ErrStat, ErrMsg, suspended, &
                              seabed_z, seabed_slope)
    !! Build the elastic-catenary positions-only seed. anchor/fairlead are the fixed
    !! endpoints; lengths/ea/weight are per element (n_elem). positions is the flat
    !! (3 n_nodes) seed [x1,y1,z1, x2,...] with node 1 at the anchor and node n at the
    !! fairlead, in the vertical plane through both. The seed is the exact extensible
    !! catenary on a frictionless planar seabed:
    !!   * anchor on the bed: a grounded run of length grounded_length lifting off
    !!     tangent to the bed, or (grounded_length = 0) a fully suspended span whose
    !!     anchor tangent is at or above the bed;
    !!   * anchor above the bed: the suspended span when it clears the bed, otherwise a
    !!     descent to a tangent touchdown, a grounded run and the ascent;
    !!   * taut spans (length at or below the chord) are the stretched suspended
    !!     solution; a vertical span is the stretched hanging line.
    !! horizontal_tension is H of the fairlead-side span. On a planar bed a line with no
    !! buoyant section is a convex curve between the chord and the bed, so it is no longer
    !! than the path down from the anchor to the bed, along the bed to below the fairlead
    !! and up to it (hspan + rise + twice the anchor height above a flat bed); a longer
    !! line cannot lie in the vertical plane and returns CD_CAT_NOSEED, and so does a
    !! vertical span longer than its rise. Callers fall back to their own seed then.
    !!
    !! suspended (default .FALSE.): no seabed supports the line (a line hung between two
    !!   points in mid-water). The anchor uplift is free in sign; the seed may dip below
    !!   the anchor and may end below it. seabed_z/seabed_slope are then ignored.
    !! seabed_z (optional): seabed height below the anchor [m, global z]. Default: the
    !!   anchor height (anchor resting on the bed). A value above the anchor is clamped
    !!   to the anchor (an anchor embedded in the bed is seeded as resting on it).
    !! seabed_slope (optional): seabed gradient dz/dx along the horizontal direction from
    !!   anchor to fairlead [-]. Default 0 (flat). The bed is the plane
    !!   z = seabed_z + seabed_slope*x through the vertical plane of the line.
    !! Without a seabed the fairlead may lie anywhere; with one it must lie above the bed
    !! (for the default bed, above the anchor).
    REAL(wp), INTENT(IN)  :: anchor(3), fairlead(3)
    REAL(wp), INTENT(IN)  :: lengths(:), ea(:), weight(:)
    REAL(wp), INTENT(OUT) :: positions(:)
    REAL(wp), INTENT(OUT) :: horizontal_tension, grounded_length
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    LOGICAL, INTENT(IN), OPTIONAL :: suspended
    REAL(wp), INTENT(IN), OPTIONAL :: seabed_z, seabed_slope

    TYPE(cat_problem) :: prob
    INTEGER  :: n_elem, n_nodes, i
    REAL(wp) :: hdelta(2), hdir(2), hspan, rise, total_length, scale, h_a, slope, l_fold
    REAL(wp) :: h_asc, h_desc, v_a, s_d, g, x_td, z_td, x_end, z_end, endpoint_err
    REAL(wp) :: p2(2), p3(3), chord, t_straight, arc
    REAL(wp), ALLOCATABLE :: xloc(:), zloc(:)
    LOGICAL  :: ok, hang, any_buoyant, elevated, valid, flat, weightless

    ErrStat = CD_CAT_OK
    ErrMsg = ''
    horizontal_tension = CD_ZERO
    grounded_length = CD_ZERO
    positions = CD_ZERO
    n_elem = SIZE(lengths)
    n_nodes = n_elem + 1

    ! --- fail closed on invalid inputs ---
    IF (n_elem < 1) THEN
      ErrStat = CD_CAT_BADINPUT; ErrMsg = 'CD_Catenary_Seed: need at least one element'; RETURN
    END IF
    IF (SIZE(ea) /= n_elem .OR. SIZE(weight) /= n_elem) THEN
      ErrStat = CD_CAT_BADINPUT; ErrMsg = 'CD_Catenary_Seed: ea/weight must have length n_elem'; RETURN
    END IF
    IF (SIZE(positions) /= 3*n_nodes) THEN
      ErrStat = CD_CAT_BADINPUT; ErrMsg = 'CD_Catenary_Seed: positions must be (3 n_nodes)'; RETURN
    END IF
    IF (.NOT. CD_All_Finite(anchor) .OR. .NOT. CD_All_Finite(fairlead) .OR. &
        .NOT. CD_All_Finite(lengths) .OR. .NOT. CD_All_Finite(ea) .OR. &
        .NOT. CD_All_Finite(weight)) THEN
      ErrStat = CD_CAT_BADINPUT; ErrMsg = 'CD_Catenary_Seed: inputs must be finite'; RETURN
    END IF
    IF (ANY(lengths <= CD_ZERO) .OR. ANY(ea <= CD_ZERO)) THEN
      ErrStat = CD_CAT_BADINPUT; ErrMsg = 'CD_Catenary_Seed: lengths and EA must be positive'; RETURN
    END IF
    h_a = CD_ZERO
    IF (PRESENT(seabed_z)) THEN
      IF (.NOT. CD_Is_Finite(seabed_z)) THEN
        ErrStat = CD_CAT_BADINPUT; ErrMsg = 'CD_Catenary_Seed: seabed_z must be finite'; RETURN
      END IF
      h_a = MAX(anchor(3) - seabed_z, CD_ZERO)
    END IF
    slope = CD_ZERO
    IF (PRESENT(seabed_slope)) THEN
      IF (.NOT. CD_Is_Finite(seabed_slope)) THEN
        ErrStat = CD_CAT_BADINPUT; ErrMsg = 'CD_Catenary_Seed: seabed_slope must be finite'; RETURN
      END IF
      slope = seabed_slope
    END IF

    hdelta = fairlead(1:2) - anchor(1:2)
    hspan = SQRT(DOT_PRODUCT(hdelta, hdelta))
    rise = fairlead(3) - anchor(3)
    total_length = SUM(lengths)
    hang = .FALSE.
    IF (PRESENT(suspended)) hang = suspended
    IF (hang) THEN
      h_a = CD_ZERO
      slope = CD_ZERO
    END IF
    IF (.NOT. hang .AND. rise <= -h_a + slope*hspan) THEN
      ErrStat = CD_CAT_BADINPUT
      ErrMsg = 'CD_Catenary_Seed: fairlead must sit above the seabed (the anchor level by default)'
      RETURN
    END IF
    scale = MAX(hspan, ABS(rise), CD_ONE)
    elevated = h_a > 1.0e-9_wp*scale
    flat = .NOT. (ABS(slope) > CD_ZERO)
    any_buoyant = ANY(weight < CD_ZERO)
    ALLOCATE (xloc(n_nodes), zloc(n_nodes))
    hdir = [CD_ONE, CD_ZERO]

    ! A neutrally buoyant line (mass per length equal to the displaced mass) carries a
    ! round-off weight whose sign depends on the platform; below 1e-12 of the axial
    ! stiffness it cannot shape the line, and the weight-scaled closure is ill-posed.
    weightless = SUM(ABS(weight)*lengths) <= 1.0e-12_wp*MINVAL(ea)
    IF (weightless .AND. total_length > HYPOT(hspan, rise)) THEN
      ! A weightless line is straight in every equilibrium; a slack one has no shape.
      ErrStat = CD_CAT_NOSEED
      ErrMsg = 'CD_Catenary_Seed: a weightless line longer than its chord has no catenary seed'
      RETURN
    END IF
    IF (hspan <= 1.0e-12_wp*scale) THEN
      ! --- vertical span: H = 0, closed-form stretched hanging line ---
      CALL vertical_line(lengths, ea, weight, rise, zloc, v_a, ok)
      IF (.NOT. ok) THEN
        ErrStat = CD_CAT_NOSEED
        ErrMsg = 'CD_Catenary_Seed: a vertical span longer than its rise has no in-plane seed'
        RETURN
      END IF
      xloc = CD_ZERO
    ELSE IF (weightless) THEN
      ! --- weightless taut line: straight along the chord, uniform tension ---
      hdir = hdelta/hspan
      chord = HYPOT(hspan, rise)
      t_straight = (chord - total_length)/SUM(lengths/ea)
      arc = CD_ZERO
      xloc(1) = CD_ZERO
      zloc(1) = CD_ZERO
      DO i = 1, n_elem
        arc = arc + lengths(i)*(CD_ONE + t_straight/ea(i))
        xloc(i + 1) = arc/chord*hspan
        zloc(i + 1) = arc/chord*rise
      END DO
      horizontal_tension = t_straight*hspan/chord
      grounded_length = CD_ZERO
    ELSE
      hdir = hdelta/hspan
      ! With non-negative weight the line is a convex curve z(x) above the bed and below
      ! the chord, inside the quadrilateral anchor / bed below the anchor / bed below the
      ! fairlead / fairlead; its length is at most that of the path down, along the bed and
      ! up (the perimeter of a convex set is below that of any convex set containing it).
      ! On a flat bed the bound is hspan + rise + 2*h_a.
      IF (.NOT. hang .AND. .NOT. any_buoyant) THEN
        IF (flat) THEN
          l_fold = hspan + rise + 2.0_wp*h_a
        ELSE
          l_fold = h_a + hspan*SQRT(CD_ONE + slope*slope) + (rise + h_a - slope*hspan)
        END IF
        IF (total_length >= l_fold) THEN
          ErrStat = CD_CAT_NOSEED
          ErrMsg = 'CD_Catenary_Seed: line longer than the path along the seabed and up to the fairlead '// &
                   'cannot lie in the vertical plane'
          RETURN
        END IF
      END IF

      prob%l = lengths
      prob%ea = ea
      prob%w = weight
      prob%hspan = hspan
      prob%rise = rise
      prob%scale = scale
      prob%total = total_length
      prob%total_weight = SUM(weight*lengths)
      ! Scales: the mean absolute weight defines the uplift coordinate -s*wref.
      prob%wref = MAX(SUM(ABS(weight)*lengths)/total_length, TINY(CD_ONE)**0.25_wp)
      prob%h_ref = MAX(prob%wref*total_length, TINY(CD_ONE)**0.25_wp)
      prob%z0 = -h_a
      prob%slope = slope
      prob%cth = CD_ONE/SQRT(CD_ONE + slope*slope)
      prob%sth = slope*prob%cth

      ok = .FALSE.
      IF (hang) THEN
        prob%mode = MODE_FREE
        CALL solve_two(prob, p2, ok)
      ELSE IF (.NOT. elevated) THEN
        prob%mode = MODE_BED
        CALL solve_two(prob, p2, ok)
        IF (.NOT. ok .AND. any_buoyant) THEN
          ! A buoyant composite can have no complementary solution (its anchor would have
          ! to pull down into the bed). Close it as a suspended span with a free-sign uplift.
          prob%mode = MODE_FREE
          CALL solve_two(prob, p2, ok)
        END IF
      ELSE
        ! The suspended span is the exact solution when it clears the bed.
        prob%mode = MODE_FREE
        CALL solve_two(prob, p2, ok)
        IF (ok) THEN
          CALL decode_unknowns(prob, p2, h_asc, h_desc, v_a, s_d, g, valid)
          CALL integrate_path(prob, h_asc, h_desc, v_a, s_d, g, x_end, z_end, x_td, z_td, xloc, zloc)
          ok = ALL(zloc - (prob%z0 + slope*xloc) >= -1.0e-9_wp*scale)
        END IF
        IF (.NOT. ok) THEN
          prob%mode = MODE_TOUCH
          CALL solve_three(prob, p3, ok)
        END IF
        IF (.NOT. ok) THEN
          ! Last resort: ground the line at the anchor level (exact as the height -> 0).
          prob%mode = MODE_BED
          prob%z0 = CD_ZERO
          CALL solve_two(prob, p2, ok)
        END IF
      END IF
      IF (.NOT. ok) THEN
        ErrStat = CD_CAT_NOCONVERGE
        ErrMsg = 'CD_Catenary_Seed: endpoint closure did not converge'
        RETURN
      END IF
      IF (prob%mode == MODE_TOUCH) THEN
        CALL decode_unknowns(prob, p3, h_asc, h_desc, v_a, s_d, g, valid)
      ELSE
        CALL decode_unknowns(prob, p2, h_asc, h_desc, v_a, s_d, g, valid)
      END IF
      CALL integrate_path(prob, h_asc, h_desc, v_a, s_d, g, x_end, z_end, x_td, z_td, xloc, zloc)
      horizontal_tension = h_asc
      grounded_length = g
    END IF
    endpoint_err = HYPOT(xloc(n_nodes) - hspan, zloc(n_nodes) - rise)
    IF (.NOT. CD_Is_Finite(endpoint_err) .OR. endpoint_err > 1.0e-7_wp*scale) THEN
      ErrStat = CD_CAT_NOCONVERGE
      ErrMsg = 'CD_Catenary_Seed: endpoint closure did not reach the fairlead'
      horizontal_tension = CD_ZERO
      grounded_length = CD_ZERO
      RETURN
    END IF

    ! --- globalise into the vertical plane through anchor->fairlead ---
    DO i = 1, n_nodes
      positions(3*i - 2) = anchor(1) + xloc(i)*hdir(1)
      positions(3*i - 1) = anchor(2) + xloc(i)*hdir(2)
      positions(3*i) = anchor(3) + zloc(i)
    END DO
    ! pin the endpoints exactly (the integration closes them to < 1e-7 scale)
    positions(1:3) = anchor
    positions(3*n_nodes - 2:3*n_nodes) = fairlead
  END SUBROUTINE CD_Catenary_Seed

  SUBROUTINE solve_two(prob, p, ok)
    !! Close a MODE_FREE or MODE_BED problem in p = (ln H, s) from a deterministic list of
    !! starts: the classical inextensible seed when it exists, a log-spaced H ladder with
    !! the straight-chord anchor uplift and with a zero-uplift start, and the chord-strain
    !! estimate of a taut span.
    TYPE(cat_problem), INTENT(IN) :: prob
    REAL(wp), INTENT(OUT) :: p(2)
    LOGICAL, INTENT(OUT) :: ok
    REAL(wp) :: starts(2, 24), lo(2), hi(2), tension_seed, grounded_seed, h_trial, v_trial, chord
    INTEGER  :: nstart, istart, k
    LOGICAL  :: inext_ok

    lo = [LOG(prob%h_ref) - 60.0_wp, -1.0e12_wp*prob%total]
    IF (prob%mode == MODE_FREE) THEN
      hi = [LOG(prob%h_ref) + 60.0_wp, 1.0e12_wp*prob%total]
    ELSE
      hi = [LOG(prob%h_ref) + 60.0_wp, prob%total*(CD_ONE - 1.0e-10_wp)]
    END IF
    nstart = 0
    inext_ok = .FALSE.
    IF (prob%rise - prob%z0 > CD_ZERO) &
      CALL inextensible_seed(prob%hspan, prob%rise - prob%z0, prob%total, prob%w, tension_seed, &
                             grounded_seed, inext_ok)
    IF (inext_ok) THEN
      IF (tension_seed > CD_ZERO) THEN
        nstart = nstart + 1
        starts(:, nstart) = [LOG(tension_seed), MERGE(CD_ZERO, grounded_seed, prob%mode == MODE_FREE)]
      END IF
    END IF
    DO k = -6, 2
      h_trial = prob%h_ref*10.0_wp**k
      v_trial = h_trial*prob%rise/prob%hspan - 0.5_wp*prob%total_weight
      nstart = nstart + 1
      starts(:, nstart) = [LOG(h_trial), -(v_trial - h_trial*prob%slope)/prob%wref]
      nstart = nstart + 1
      starts(:, nstart) = [LOG(h_trial), CD_ZERO]
    END DO
    chord = HYPOT(prob%hspan, prob%rise)
    h_trial = MINVAL(prob%ea)*MAX(chord/prob%total - CD_ONE, 1.0e-6_wp)*prob%hspan/chord
    nstart = nstart + 1
    starts(:, nstart) = [LOG(h_trial), &
                         -(h_trial*(prob%rise/prob%hspan - prob%slope) - 0.5_wp*prob%total_weight)/prob%wref]

    ok = .FALSE.
    DO istart = 1, nstart
      p = MIN(MAX(starts(:, istart), lo), hi)
      CALL close_endpoint(prob, p, lo, hi, ok)
      IF (ok) RETURN
    END DO
  END SUBROUTINE solve_two

  SUBROUTINE solve_three(prob, p, ok)
    !! Close a MODE_TOUCH problem in p = (ln H, descent length, grounded length). Starts
    !! come from the same line grounded at the bed level under the anchor (its H and
    !! grounded length) and from an H ladder, with the descent length of an inextensible
    !! catenary branch falling h_a to its vertex, sqrt(h_a^2 + 2 h_a H/w).
    !! The grounded base problem is prob itself with its mode, rise and bed height changed
    !! for that one solve and restored straight after (no copy of the per-element arrays).
    TYPE(cat_problem), INTENT(INOUT) :: prob
    REAL(wp), INTENT(OUT) :: p(3)
    LOGICAL, INTENT(OUT) :: ok
    REAL(wp) :: starts(3, 24), lo(3), hi(3), pb(2), h_trial, h_a, s_d0, saved_rise, saved_z0
    INTEGER  :: nstart, istart, k, saved_mode
    LOGICAL  :: base_ok

    h_a = -prob%z0
    lo = [LOG(prob%h_ref) - 60.0_wp, CD_ZERO, CD_ZERO]
    hi = [LOG(prob%h_ref) + 60.0_wp, prob%total, prob%total]
    nstart = 0
    saved_mode = prob%mode
    saved_rise = prob%rise
    saved_z0 = prob%z0
    prob%mode = MODE_BED
    prob%rise = saved_rise + h_a
    prob%z0 = CD_ZERO
    CALL solve_two(prob, pb, base_ok)
    prob%mode = saved_mode
    prob%rise = saved_rise
    prob%z0 = saved_z0
    IF (base_ok) THEN
      h_trial = EXP(pb(1))
      s_d0 = MIN(SQRT(h_a*h_a + 2.0_wp*h_a*h_trial/prob%wref), 0.5_wp*prob%total)
      nstart = nstart + 1
      starts(:, nstart) = [pb(1), s_d0, MAX(pb(2) - s_d0, CD_ZERO)]
      nstart = nstart + 1
      starts(:, nstart) = [pb(1), s_d0, CD_ZERO]
    END IF
    DO k = -6, 2
      h_trial = prob%h_ref*10.0_wp**k
      s_d0 = MIN(SQRT(h_a*h_a + 2.0_wp*h_a*h_trial/prob%wref), 0.5_wp*prob%total)
      nstart = nstart + 1
      starts(:, nstart) = [LOG(h_trial), s_d0, 0.25_wp*prob%total]
      nstart = nstart + 1
      starts(:, nstart) = [LOG(h_trial), s_d0, CD_ZERO]
    END DO

    ok = .FALSE.
    DO istart = 1, nstart
      p = MIN(MAX(starts(:, istart), lo), hi)
      CALL close_endpoint(prob, p, lo, hi, ok)
      IF (ok) RETURN
    END DO
  END SUBROUTINE solve_three

  SUBROUTINE inextensible_seed(hspan, rise, total_length, weight, tension_seed, grounded_seed, ok)
    !! Horizontal-tension and grounded-length seeds from the classical inextensible
    !! catenary: solve (sinh u - u)/(cosh u - 1) = excess_ratio for u by bisection
    !! (the left side rises monotonically from 0 to 1), then a = rise/(cosh u - 1).
    REAL(wp), INTENT(IN)  :: hspan, rise, total_length, weight(:)
    REAL(wp), INTENT(OUT) :: tension_seed, grounded_seed
    LOGICAL, INTENT(OUT) :: ok
    REAL(wp) :: excess, ulo, uhi, umid, flo, fmid, a, suspended
    INTEGER  :: it
    tension_seed = CD_ZERO; grounded_seed = CD_ZERO; ok = .FALSE.
    excess = (total_length - hspan)/rise
    IF (.NOT. (excess > CD_ZERO .AND. excess < CD_ONE)) RETURN
    ulo = 1.0e-9_wp
    uhi = 50.0_wp
    umid = ulo
    flo = catenary_excess(ulo) - excess
    IF (flo*(catenary_excess(uhi) - excess) > CD_ZERO) RETURN   ! no sign change in the bracket
    DO it = 1, 200
      umid = 0.5_wp*(ulo + uhi)
      fmid = catenary_excess(umid) - excess
      IF (ABS(fmid) < 1.0e-14_wp .OR. (uhi - ulo) < 1.0e-14_wp) EXIT
      IF (flo*fmid <= CD_ZERO) THEN
        uhi = umid
      ELSE
        ulo = umid; flo = fmid
      END IF
    END DO
    a = rise/(COSH(umid) - CD_ONE)
    suspended = a*SINH(umid)
    grounded_seed = total_length - suspended
    tension_seed = (SUM(ABS(weight))/REAL(SIZE(weight), wp))*a
    ok = CD_Is_Finite(tension_seed) .AND. CD_Is_Finite(grounded_seed)
  END SUBROUTINE inextensible_seed

  PURE REAL(wp) FUNCTION catenary_excess(u) RESULT(f)
    !! (sinh u - u)/(cosh u - 1), with a small-u Taylor branch to avoid cancellation.
    REAL(wp), INTENT(IN) :: u
    IF (ABS(u) < 1.0e-4_wp) THEN
      f = u/3.0_wp*(CD_ONE - u*u/30.0_wp)
    ELSE
      f = (SINH(u) - u)/(COSH(u) - CD_ONE)
    END IF
  END FUNCTION catenary_excess

  PURE REAL(wp) FUNCTION weight_between(prob, a, b) RESULT(total)
    !! Submerged weight carried by the reference arc [a, b].
    TYPE(cat_problem), INTENT(IN) :: prob
    REAL(wp), INTENT(IN) :: a, b
    REAL(wp) :: s0, s1
    INTEGER  :: e
    total = CD_ZERO
    s0 = CD_ZERO
    DO e = 1, SIZE(prob%l)
      s1 = s0 + prob%l(e)
      total = total + prob%w(e)*MAX(MIN(s1, b) - MAX(s0, a), CD_ZERO)
      s0 = s1
    END DO
  END FUNCTION weight_between

  SUBROUTINE decode_unknowns(prob, p, h_asc, h_desc, v_a, s_d, g, valid)
    !! Map the closure unknowns to the line state: H of the ascent (fairlead-side) span,
    !! H of the descent span, the anchor vertical tension, the descent and grounded lengths.
    !!  MODE_FREE : p = (ln H, s); V_a = -s*wref, nothing grounded.
    !!  MODE_BED  : p = (ln H, s); s >= 0 grounds a run of length s from the anchor
    !!              (lift-off tangent to the bed), s < 0 lifts the anchor tangent above
    !!              the bed by -s*wref.
    !!  MODE_TOUCH: p = (ln H, s_d, g); descent of length s_d ending tangent on the bed,
    !!              grounded run g, ascent.
    !! A grounded run on a slope changes the tension by w sin(theta) per length
    !! (frictionless bed); valid = .FALSE. when the run would be slack at its lower end.
    TYPE(cat_problem), INTENT(IN) :: prob
    REAL(wp), INTENT(IN)  :: p(:)
    REAL(wp), INTENT(OUT) :: h_asc, h_desc, v_a, s_d, g
    LOGICAL, INTENT(OUT)  :: valid
    REAL(wp) :: t_td
    h_asc = EXP(p(1))
    h_desc = h_asc
    v_a = CD_ZERO
    s_d = CD_ZERO
    g = CD_ZERO
    valid = .TRUE.
    SELECT CASE (prob%mode)
    CASE (MODE_FREE)
      v_a = -p(2)*prob%wref
    CASE (MODE_BED)
      IF (p(2) >= CD_ZERO) THEN
        g = MIN(p(2), prob%total)
        t_td = h_asc/prob%cth - prob%sth*weight_between(prob, CD_ZERO, g)
        h_desc = t_td*prob%cth
        v_a = h_desc*prob%slope
        valid = t_td > CD_ZERO
      ELSE
        v_a = h_asc*prob%slope - p(2)*prob%wref
      END IF
    CASE DEFAULT
      s_d = MIN(MAX(p(2), CD_ZERO), prob%total)
      g = MIN(MAX(p(3), CD_ZERO), prob%total - s_d)
      t_td = h_asc/prob%cth - prob%sth*weight_between(prob, s_d, s_d + g)
      h_desc = t_td*prob%cth
      v_a = h_desc*prob%slope - weight_between(prob, CD_ZERO, s_d)
      valid = t_td > CD_ZERO
    END SELECT
  END SUBROUTINE decode_unknowns

  SUBROUTINE integrate_path(prob, h_asc, h_desc, v_a, s_d, g, x_end, z_end, x_td, z_td, x, z)
    !! Integrate the extensible line element by element over three reference-arc pieces:
    !! [0, s_d) suspended with horizontal tension h_desc from the anchor uplift v_a,
    !! [s_d, s_d + g) grounded along the bed (tension h_desc/cos(theta) at s_d, changing
    !! by w sin(theta) per length), and [s_d + g, L] suspended with h_asc, starting
    !! tangent to the bed after contact (V = h_asc*slope) or from v_a without contact.
    !! (x_td, z_td) is the end of the descent (the anchor when s_d = 0), (x_end, z_end)
    !! the far end; the nodal positions x, z are stored only when requested.
    TYPE(cat_problem), INTENT(IN) :: prob
    REAL(wp), INTENT(IN)  :: h_asc, h_desc, v_a, s_d, g
    REAL(wp), INTENT(OUT) :: x_end, z_end, x_td, z_td
    REAL(wp), INTENT(OUT), OPTIONAL :: x(:), z(:)
    INTEGER  :: e
    REAL(wp) :: a, b, xe, ze, len1, len2, len3, v1, v3, t2, t_next, v_next, xs, zs, ext
    LOGICAL  :: store

    store = PRESENT(x) .AND. PRESENT(z)
    IF (store) THEN
      x(1) = CD_ZERO
      z(1) = CD_ZERO
    END IF
    xe = CD_ZERO
    ze = CD_ZERO
    x_td = CD_ZERO
    z_td = CD_ZERO
    v1 = v_a
    t2 = h_desc/prob%cth
    IF (s_d + g > CD_ZERO) THEN
      v3 = h_asc*prob%slope
    ELSE
      v3 = v_a
    END IF
    a = CD_ZERO
    DO e = 1, SIZE(prob%l)
      b = a + prob%l(e)
      len1 = MAX(MIN(b, s_d) - a, CD_ZERO)
      IF (len1 > CD_ZERO) THEN
        v_next = v1 + prob%w(e)*len1
        CALL integrate_suspended_span(h_desc, v1, v_next, len1, prob%w(e), prob%ea(e), xs, zs)
        xe = xe + xs
        ze = ze + zs
        v1 = v_next
        IF (b >= s_d) THEN
          x_td = xe
          z_td = ze
        END IF
      END IF
      len2 = MAX(MIN(b, s_d + g) - MAX(a, s_d), CD_ZERO)
      IF (len2 > CD_ZERO) THEN
        t_next = t2 + prob%sth*prob%w(e)*len2
        ext = len2 + len2*(t2 + t_next)/(2.0_wp*prob%ea(e))
        xe = xe + prob%cth*ext
        ze = ze + prob%sth*ext
        t2 = t_next
      END IF
      len3 = MAX(b - MAX(a, s_d + g), CD_ZERO)
      IF (len3 > CD_ZERO) THEN
        v_next = v3 + prob%w(e)*len3
        CALL integrate_suspended_span(h_asc, v3, v_next, len3, prob%w(e), prob%ea(e), xs, zs)
        xe = xe + xs
        ze = ze + zs
        v3 = v_next
      END IF
      IF (store) THEN
        x(e + 1) = xe
        z(e + 1) = ze
      END IF
      a = b
    END DO
    x_end = xe
    z_end = ze
  END SUBROUTINE integrate_path

  PURE SUBROUTINE integrate_suspended_span(h_tension, v_start, v_end, ref_length, weight, ea, x_step, z_step)
    !! One suspended segment, closed-form, allowing signed weight (buoyant -> the
    !! vertical tension can change sign across the segment, building a turning point).
    !! The classical forms (H/w)(asinh(Ve/H) - asinh(Vs/H)) and (T_e - T_s)/w cancel
    !! catastrophically as |w| L / max(H, |V|) -> 0. They are evaluated here without any
    !! division by w: with Ve - Vs = w L,
    !!   z_step = L (Vs + Ve)/(2 EA) + L (Vs + Ve)/(T_s + T_e),
    !!   x_step = H L/EA + L * [asinh(ve) - asinh(vs)]/(ve - vs),   v = V/H,
    !! where the divided difference of asinh is formed from the cancellation-free identity
    !! asinh(a) - asinh(b) = asinh((a - b)(a + b)/(a sqrt(1 + b^2) + b sqrt(1 + a^2))) when a and
    !! b share a sign. Both reduce continuously to the straight segment at w = 0.
    REAL(wp), INTENT(IN)  :: h_tension, v_start, v_end, ref_length, weight, ea
    REAL(wp), INTENT(OUT) :: x_step, z_step
    REAL(wp) :: t_s, t_e, a, b, d, den, y, ratio
    t_s = HYPOT(h_tension, v_start)
    t_e = HYPOT(h_tension, v_end)
    z_step = ref_length*(v_start + v_end)/(2.0_wp*ea) + ref_length*(v_start + v_end)/(t_s + t_e)
    a = v_end/h_tension
    b = v_start/h_tension
    d = weight*ref_length/h_tension
    IF (a*b > CD_ZERO) THEN
      den = a*SQRT(CD_ONE + b*b) + b*SQRT(CD_ONE + a*a)
      y = d*(a + b)/den
      IF (ABS(y) < 1.0e-8_wp) THEN
        ratio = CD_ONE - y*y/6.0_wp
      ELSE
        ratio = ASINH(y)/y
      END IF
      ratio = ratio*(a + b)/den
    ELSE IF (ABS(d) > CD_ZERO) THEN
      ! Opposite signs (a turning point inside): the difference does not cancel.
      ratio = (ASINH(a) - ASINH(b))/d
    ELSE
      ratio = CD_ONE/SQRT(CD_ONE + b*b)
    END IF
    x_step = h_tension*ref_length/ea + ref_length*ratio
  END SUBROUTINE integrate_suspended_span

  SUBROUTINE vertical_line(lengths, ea, weight, rise, z, v_anchor, ok)
    !! Vertical span (H = 0): the line hangs straight, with tension |V| and
    !! V(s) = V_a + cumulative weight. It must not fold, so V keeps the sign of the rise
    !! along the whole line; then dz = (sign(V) + V/EA) ds and the endpoint condition is
    !! linear in the anchor tension V_a.
    REAL(wp), INTENT(IN)  :: lengths(:), ea(:), weight(:), rise
    REAL(wp), INTENT(OUT) :: z(:), v_anchor
    LOGICAL, INTENT(OUT)  :: ok
    REAL(wp) :: sgn, cum(SIZE(lengths) + 1), compliance, offset
    INTEGER  :: e, n
    n = SIZE(lengths)
    sgn = SIGN(CD_ONE, rise)
    cum(1) = CD_ZERO
    DO e = 1, n
      cum(e + 1) = cum(e) + weight(e)*lengths(e)
    END DO
    compliance = SUM(lengths/ea)
    offset = CD_ZERO
    DO e = 1, n
      offset = offset + lengths(e)*(cum(e) + cum(e + 1))/(2.0_wp*ea(e))
    END DO
    v_anchor = (rise - sgn*SUM(lengths) - offset)/compliance
    ok = CD_Is_Finite(v_anchor) .AND. ALL(sgn*(v_anchor + cum) > CD_ZERO)
    z(1) = CD_ZERO
    DO e = 1, n
      z(e + 1) = z(e) + sgn*lengths(e) + lengths(e)*(2.0_wp*v_anchor + cum(e) + cum(e + 1))/(2.0_wp*ea(e))
    END DO
  END SUBROUTINE vertical_line

  SUBROUTINE endpoint_residual(prob, p, r)
    !! Endpoint-closure residuals scaled by the geometry: fairlead x and z misfit, and for
    !! MODE_TOUCH the height of the touchdown point above the bed.
    TYPE(cat_problem), INTENT(IN) :: prob
    REAL(wp), INTENT(IN)  :: p(:)
    REAL(wp), INTENT(OUT) :: r(:)
    REAL(wp) :: h_asc, h_desc, v_a, s_d, g, x_td, z_td, x_end, z_end
    LOGICAL  :: valid
    CALL decode_unknowns(prob, p, h_asc, h_desc, v_a, s_d, g, valid)
    IF (.NOT. valid) THEN
      r = BAD_RESIDUAL
      RETURN
    END IF
    CALL integrate_path(prob, h_asc, h_desc, v_a, s_d, g, x_end, z_end, x_td, z_td)
    r(1) = (x_end - prob%hspan)/prob%scale
    r(2) = (z_end - prob%rise)/prob%scale
    IF (SIZE(r) > 2) r(3) = (z_td - (prob%z0 + prob%slope*x_td))/prob%scale
  END SUBROUTINE endpoint_residual

  SUBROUTINE close_endpoint(prob, p, lo, hi, ok)
    !! Bound-projected Levenberg-Marquardt on the endpoint residuals (2 or 3 unknowns,
    !! the first always ln H, which keeps H positive across the many decades between a
    !! slack and a taut span). Branch switches are continuous but only piecewise smooth,
    !! so a step is accepted only when it lowers the residual norm (mu relaxed), otherwise
    !! mu is raised. The Jacobian is central finite differences; every trial is clamped
    !! to [lo, hi] and one step changes H by at most a factor e^2.
    TYPE(cat_problem), INTENT(IN) :: prob
    REAL(wp), INTENT(INOUT) :: p(:)
    REAL(wp), INTENT(IN)  :: lo(:), hi(:)
    LOGICAL, INTENT(OUT) :: ok
    REAL(wp) :: r(SIZE(p)), rtrial(SIZE(p)), jac(SIZE(p), SIZE(p)), pj(SIZE(p)), rp(SIZE(p)), rm(SIZE(p))
    REAL(wp) :: dp(SIZE(p)), ptrial(SIZE(p)), a(SIZE(p), SIZE(p)), g(SIZE(p)), hstep(SIZE(p))
    REAL(wp) :: nrm, nrm_trial, mu
    INTEGER  :: it, j, inner, n
    LOGICAL  :: stepped, solved
    ! TOL is the round-off floor of the scaled residual; ACCEPT_TOL keeps the caller's
    ! endpoint_err < 1e-7*scale gate with margin when descent stalls at that floor.
    REAL(wp), PARAMETER :: TOL = 1.0e-13_wp, ACCEPT_TOL = 1.0e-8_wp
    ok = .FALSE.
    n = SIZE(p)
    CALL endpoint_residual(prob, p, r)
    nrm = NORM2(r)
    IF (.NOT. CD_Is_Finite(nrm)) RETURN
    mu = 1.0e-3_wp
    DO it = 1, 300
      IF (nrm < TOL) THEN
        ok = .TRUE.; RETURN
      END IF
      hstep(1) = 1.0e-7_wp
      DO j = 2, n
        hstep(j) = 1.0e-7_wp*MAX(ABS(p(j)), 1.0e-3_wp*prob%total)
      END DO
      DO j = 1, n
        pj = p; pj(j) = p(j) + hstep(j)
        CALL endpoint_residual(prob, pj, rp)
        pj = p; pj(j) = p(j) - hstep(j)
        CALL endpoint_residual(prob, pj, rm)
        jac(:, j) = (rp - rm)/(2.0_wp*hstep(j))
      END DO
      IF (.NOT. CD_All_Finite(jac)) EXIT
      a = MATMUL(TRANSPOSE(jac), jac)
      g = MATMUL(TRANSPOSE(jac), r)
      stepped = .FALSE.
      DO inner = 1, 60
        CALL lm_step(a, mu, g, dp, solved)
        IF (solved) THEN
          IF (ABS(dp(1)) > 2.0_wp) dp = dp*(2.0_wp/ABS(dp(1)))
          ptrial = MIN(MAX(p + dp, lo), hi)
          CALL endpoint_residual(prob, ptrial, rtrial)
          nrm_trial = NORM2(rtrial)
          IF (CD_Is_Finite(nrm_trial) .AND. nrm_trial < nrm) THEN
            mu = MAX(mu*0.3_wp, 1.0e-15_wp)
            stepped = .TRUE.
            EXIT
          END IF
        END IF
        mu = mu*4.0_wp
        IF (mu > 1.0e20_wp) EXIT
      END DO
      IF (.NOT. stepped) EXIT
      p = ptrial
      r = rtrial
      nrm = nrm_trial
    END DO
    ok = (nrm < ACCEPT_TOL)
  END SUBROUTINE close_endpoint

  PURE SUBROUTINE lm_step(a, mu, g, dp, solved)
    !! Solve the small Levenberg-Marquardt normal equations with Marquardt diagonal
    !! scaling, (A + mu * diag(A)) dp = -g, which is invariant to the very different
    !! scales of the unknowns, by Gaussian elimination with partial pivoting. A small
    !! floor relative to the largest diagonal keeps a low-sensitivity direction damped.
    REAL(wp), INTENT(IN)  :: a(:, :), mu, g(:)
    REAL(wp), INTENT(OUT) :: dp(:)
    LOGICAL, INTENT(OUT)  :: solved
    REAL(wp) :: m(SIZE(g), SIZE(g)), rhs(SIZE(g)), dfloor, factor, row(SIZE(g)), tmp
    INTEGER  :: k, i, piv, n
    n = SIZE(g)
    dfloor = CD_ZERO
    DO k = 1, n
      dfloor = MAX(dfloor, a(k, k))
    END DO
    dfloor = 1.0e-12_wp*dfloor
    m = a
    DO k = 1, n
      m(k, k) = a(k, k) + mu*MAX(a(k, k), dfloor)
    END DO
    rhs = -g
    dp = CD_ZERO
    solved = .FALSE.
    DO k = 1, n
      piv = k - 1 + MAXLOC(ABS(m(k:n, k)), DIM=1)
      IF (.NOT. (ABS(m(piv, k)) > CD_ZERO)) RETURN
      IF (piv /= k) THEN
        row = m(k, :); m(k, :) = m(piv, :); m(piv, :) = row
        tmp = rhs(k); rhs(k) = rhs(piv); rhs(piv) = tmp
      END IF
      DO i = k + 1, n
        factor = m(i, k)/m(k, k)
        m(i, k:n) = m(i, k:n) - factor*m(k, k:n)
        rhs(i) = rhs(i) - factor*rhs(k)
      END DO
    END DO
    DO k = n, 1, -1
      dp(k) = (rhs(k) - DOT_PRODUCT(m(k, k + 1:n), dp(k + 1:n)))/m(k, k)
    END DO
    solved = CD_All_Finite(dp)
  END SUBROUTINE lm_step

END MODULE CableDyn_Catenary
