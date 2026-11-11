! File: src/CableDyn_VIV.f90
! SPDX-License-Identifier: Apache-2.0
! Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
MODULE CableDyn_VIV
  !! Cross-flow vortex-induced vibration (VIV) of EI = 0 line nodes: the synchronisation
  !! model of Thorsen, Saevik and Larsen (J. Fluids Struct. 49, 2014, 135-148; 61, 2016,
  !! 1-19) in the form MoorDyn v2 implements it (LINE TYPES columns Cl dF cF; Davies et al.,
  !! J. Fluids Struct. 146, 2026, 104651). Pure node kernels; the model layer
  !! (CableDyn_Model) owns the phase state and the time integration.
  !!
  !! At an interior node with unit tangent q (the chord of its two neighbours), velocity r',
  !! acceleration r'' and ambient fluid velocity u:
  !!
  !!   v_r = u - r'              relative fluid velocity
  !!   v_n = v_r - (q.v_r) q     its component normal to the line, U = |v_n|
  !!   e   = q x v_n / U         cross-flow unit vector
  !!   y'  = r'.e ,  y'' = r''.e cross-flow velocity and acceleration of the node
  !!
  !! The cross-flow velocity phase is phi_y = atan2(-y''/rms(y''), y'/rms(y')) in [0, 2 pi),
  !! with running RMS values. The vortex-shedding (lift) phase phi obeys
  !!
  !!   d phi/dt = 2 pi f_hat U / D ,   f_hat = cF + dF sin(phi_y - phi)
  !!
  !! so the shedding frequency locks onto the cross-flow motion inside the non-dimensional
  !! synchronisation band cF +- dF, and the lift force on the node is
  !!
  !!   F = C cos(phi) U (q x v_n) ,   C = sum over the node's two elements of
  !!                                      (1/2 l0_e w_e) (1/2 rho D_e Cl_e)
  !!
  !! (w_e the submerged fraction of element e): per unit length 1/2 rho D Cl U^2 cos(phi)
  !! along e, exactly MoorDyn's Lf = 1/2 rho_w d |Vp| Cl cos(phi) (q x Vp) l_node.
  !!
  !! Load convention (CableDyn_Hydro, CD_Cable_Dynamic_Load_Proc): `force` is the external
  !! load; the Jacobians are residual contributions, -dF/d(node velocity) and
  !! -dF/d(neighbour positions) through the node tangent. The wetted-fraction factor in C is
  !! held at its current value in the Jacobians (it moves only for an element that crosses
  !! the waterline); the residual itself is exact.
  USE CableDyn_Precision, ONLY: wp, CD_ZERO, CD_ONE
  IMPLICIT NONE
  PRIVATE

  PUBLIC :: CD_VIV_Node_Lift
  PUBLIC :: CD_VIV_Lift_Per_Length
  PUBLIC :: CD_VIV_Crossflow_Motion
  PUBLIC :: CD_VIV_Crossflow_Along
  PUBLIC :: CD_VIV_Phase_Rate
  PUBLIC :: CD_VIV_Mean_Square
  PUBLIC :: CD_VIV_Wrap_Phase

  !> MoorDyn's running-RMS window in time steps (Line%n_m): each step updates the stored
  !> mean square as ((n_m - 1) old + new) / n_m.
  INTEGER, PARAMETER, PUBLIC :: CD_VIV_NM = 500
  !> MoorDyn's defaults of the synchronisation range dF and centre cF when a LINE TYPES row
  !> gives Cl only.
  REAL(wp), PARAMETER, PUBLIC :: CD_VIV_DEFAULT_DF = 0.08_wp
  REAL(wp), PARAMETER, PUBLIC :: CD_VIV_DEFAULT_CF = 0.18_wp
  REAL(wp), PARAMETER, PUBLIC :: CD_VIV_TWO_PI = 6.283185307179586476925286766559005768394_wp

  !> Chord below which a node tangent is undefined (a collapsed pair of neighbours).
  REAL(wp), PARAMETER :: TINY_CHORD = 1.0e-12_wp

CONTAINS

  PURE SUBROUTINE node_frame(r_prev, r_next, rd, u, q, chord, vr, vn, un, ok)
    !! Unit tangent from the neighbour chord and the normal relative velocity of a node.
    REAL(wp), INTENT(IN) :: r_prev(3), r_next(3), rd(3), u(3)
    REAL(wp), INTENT(OUT) :: q(3), chord, vr(3), vn(3), un
    LOGICAL, INTENT(OUT) :: ok
    REAL(wp) :: c(3)

    c = r_next - r_prev
    chord = SQRT(c(1)*c(1) + c(2)*c(2) + c(3)*c(3))
    ok = chord > TINY_CHORD
    IF (.NOT. ok) THEN
      q = CD_ZERO
      vr = CD_ZERO
      vn = CD_ZERO
      un = CD_ZERO
      RETURN
    END IF
    q = c/chord
    vr = u - rd
    vn = vr - (q(1)*vr(1) + q(2)*vr(2) + q(3)*vr(3))*q
    un = SQRT(vn(1)*vn(1) + vn(2)*vn(2) + vn(3)*vn(3))
  END SUBROUTINE node_frame

  PURE FUNCTION cross3(a, b) RESULT(c)
    REAL(wp), INTENT(IN) :: a(3), b(3)
    REAL(wp) :: c(3)
    c(1) = a(2)*b(3) - a(3)*b(2)
    c(2) = a(3)*b(1) - a(1)*b(3)
    c(3) = a(1)*b(2) - a(2)*b(1)
  END FUNCTION cross3

  PURE SUBROUTINE CD_VIV_Node_Lift(r_prev, r_next, rd, u, coef, phi, force, ok, jac_v, jac_prev, jac_next)
    !! Lift force on one node, F = coef cos(phi) U (q x v_n), and optionally its residual
    !! Jacobians (all three present or none): jac_v = -dF/dr', jac_prev = -dF/dr_prev,
    !! jac_next = -dF/dr_next. ok = .FALSE. (and F = 0) when the two neighbours coincide.
    REAL(wp), INTENT(IN) :: r_prev(3), r_next(3), rd(3), u(3), coef, phi
    REAL(wp), INTENT(OUT) :: force(3)
    LOGICAL, INTENT(OUT) :: ok
    REAL(wp), INTENT(OUT), OPTIONAL :: jac_v(3, 3), jac_prev(3, 3), jac_next(3, 3)
    REAL(wp) :: q(3), chord, vr(3), vn(3), un, w(3), s, alpha
    REAL(wp) :: dfdq(3, 3), dfdv(3, 3), proj(3, 3)
    INTEGER :: i, j

    force = CD_ZERO
    IF (PRESENT(jac_v)) THEN
      jac_v = CD_ZERO
      jac_prev = CD_ZERO
      jac_next = CD_ZERO
    END IF
    CALL node_frame(r_prev, r_next, rd, u, q, chord, vr, vn, un, ok)
    IF (.NOT. ok) RETURN
    s = coef*COS(phi)
    w = cross3(q, vn)
    force = (s*un)*w
    IF (.NOT. PRESENT(jac_v)) RETURN
    IF (.NOT. (un > CD_ZERO)) RETURN   ! F and its derivatives vanish with the normal flow
    ! w = q x v_n = q x v_r. dF/dv_r = s [w (x) v_n/U + U [q]x]; dr' enters v_r with a minus
    ! sign, so jac_v = -dF/dr' = +dF/dv_r.
    DO j = 1, 3
      DO i = 1, 3
        dfdv(i, j) = s*w(i)*vn(j)/un
      END DO
    END DO
    dfdv(1, 2) = dfdv(1, 2) - s*un*q(3)
    dfdv(1, 3) = dfdv(1, 3) + s*un*q(2)
    dfdv(2, 1) = dfdv(2, 1) + s*un*q(3)
    dfdv(2, 3) = dfdv(2, 3) - s*un*q(1)
    dfdv(3, 1) = dfdv(3, 1) - s*un*q(2)
    dfdv(3, 2) = dfdv(3, 2) + s*un*q(1)
    jac_v = dfdv
    ! dF/dq = s [-(alpha/U) w (x) v_r - U [v_r]x], alpha = q.v_r (U^2 = |v_r|^2 - alpha^2 and
    ! d(q x v_r)/dq = -[v_r]x), chained through dq/dr_next = (I - q q^T)/chord = -dq/dr_prev.
    alpha = q(1)*vr(1) + q(2)*vr(2) + q(3)*vr(3)
    DO j = 1, 3
      DO i = 1, 3
        dfdq(i, j) = -s*(alpha/un)*w(i)*vr(j)
      END DO
    END DO
    dfdq(1, 2) = dfdq(1, 2) + s*un*vr(3)
    dfdq(1, 3) = dfdq(1, 3) - s*un*vr(2)
    dfdq(2, 1) = dfdq(2, 1) - s*un*vr(3)
    dfdq(2, 3) = dfdq(2, 3) + s*un*vr(1)
    dfdq(3, 1) = dfdq(3, 1) + s*un*vr(2)
    dfdq(3, 2) = dfdq(3, 2) - s*un*vr(1)
    DO j = 1, 3
      DO i = 1, 3
        proj(i, j) = -q(i)*q(j)/chord
      END DO
      proj(j, j) = proj(j, j) + CD_ONE/chord
    END DO
    jac_next = -MATMUL(dfdq, proj)
    jac_prev = -jac_next
  END SUBROUTINE CD_VIV_Node_Lift

  PURE SUBROUTINE CD_VIV_Crossflow_Motion(r_prev, r_next, rd, rdd, u, yd, ydd, un, ok)
    !! Cross-flow velocity y' and acceleration y'' of a node along e = q x v_n / U, and the
    !! normal relative flow speed U. Both are zero when there is no normal flow (MoorDyn's
    !! normalisation of a zero vector).
    REAL(wp), INTENT(IN) :: r_prev(3), r_next(3), rd(3), rdd(3), u(3)
    REAL(wp), INTENT(OUT) :: yd, ydd, un
    LOGICAL, INTENT(OUT) :: ok
    REAL(wp) :: q(3), chord, vr(3), vn(3), e(3)

    yd = CD_ZERO
    ydd = CD_ZERO
    CALL node_frame(r_prev, r_next, rd, u, q, chord, vr, vn, un, ok)
    IF (.NOT. ok) RETURN
    IF (.NOT. (un > CD_ZERO)) RETURN
    e = cross3(q, vn)/un
    yd = rd(1)*e(1) + rd(2)*e(2) + rd(3)*e(3)
    ydd = rdd(1)*e(1) + rdd(2)*e(2) + rdd(3)*e(3)
  END SUBROUTINE CD_VIV_Crossflow_Motion

  PURE SUBROUTINE CD_VIV_Lift_Per_Length(urel, rp, k, f, ok, jrel, jtan)
    !! Lift per unit length of a cable centreline point (the finite-EI cable's Gauss points),
    !! f = k U (t x v_r), with k = 1/2 rho D Cl cos(phi), the unit tangent t = rp/|rp| of the raw
    !! centreline derivative rp = dr/dxi, the relative flow v_r = urel and its normal speed U.
    !! Optionally (both or neither) its Jacobians jrel = df/dv_r and jtan = df/drp, for chaining
    !! through the shape functions as the drag primitive is. ok = .FALSE. (and f = 0) for a
    !! degenerate centreline; f and its derivatives vanish with the normal flow.
    REAL(wp), INTENT(IN) :: urel(3), rp(3), k
    REAL(wp), INTENT(OUT) :: f(3)
    LOGICAL, INTENT(OUT) :: ok
    REAL(wp), INTENT(OUT), OPTIONAL :: jrel(3, 3), jtan(3, 3)
    REAL(wp) :: speed, t(3), alpha, vn(3), un, w(3), dfdt(3, 3), proj(3, 3)
    INTEGER :: i, j

    f = CD_ZERO
    IF (PRESENT(jrel)) THEN
      jrel = CD_ZERO
      jtan = CD_ZERO
    END IF
    speed = SQRT(rp(1)*rp(1) + rp(2)*rp(2) + rp(3)*rp(3))
    ok = speed > TINY_CHORD
    IF (.NOT. ok) RETURN
    t = rp/speed
    alpha = t(1)*urel(1) + t(2)*urel(2) + t(3)*urel(3)
    vn = urel - alpha*t
    un = SQRT(vn(1)*vn(1) + vn(2)*vn(2) + vn(3)*vn(3))
    w = cross3(t, urel)                ! = t x v_n
    f = (k*un)*w
    IF (.NOT. PRESENT(jrel)) RETURN
    IF (.NOT. (un > CD_ZERO)) RETURN
    ! df/dv_r = k [w (x) v_n/U + U [t]x]
    DO j = 1, 3
      DO i = 1, 3
        jrel(i, j) = k*w(i)*vn(j)/un
      END DO
    END DO
    jrel(1, 2) = jrel(1, 2) - k*un*t(3)
    jrel(1, 3) = jrel(1, 3) + k*un*t(2)
    jrel(2, 1) = jrel(2, 1) + k*un*t(3)
    jrel(2, 3) = jrel(2, 3) - k*un*t(1)
    jrel(3, 1) = jrel(3, 1) - k*un*t(2)
    jrel(3, 2) = jrel(3, 2) + k*un*t(1)
    ! df/dt = k [-(alpha/U) w (x) v_r - U [v_r]x], chained through dt/drp = (I - t t^T)/|rp|
    DO j = 1, 3
      DO i = 1, 3
        dfdt(i, j) = -k*(alpha/un)*w(i)*urel(j)
      END DO
    END DO
    dfdt(1, 2) = dfdt(1, 2) + k*un*urel(3)
    dfdt(1, 3) = dfdt(1, 3) - k*un*urel(2)
    dfdt(2, 1) = dfdt(2, 1) - k*un*urel(3)
    dfdt(2, 3) = dfdt(2, 3) + k*un*urel(1)
    dfdt(3, 1) = dfdt(3, 1) + k*un*urel(2)
    dfdt(3, 2) = dfdt(3, 2) - k*un*urel(1)
    DO j = 1, 3
      DO i = 1, 3
        proj(i, j) = -t(i)*t(j)/speed
      END DO
      proj(j, j) = proj(j, j) + CD_ONE/speed
    END DO
    jtan = MATMUL(dfdt, proj)
  END SUBROUTINE CD_VIV_Lift_Per_Length

  PURE SUBROUTINE CD_VIV_Crossflow_Along(tdir, rd, rdd, u, yd, ydd, un, ok)
    !! CD_VIV_Crossflow_Motion with the line tangent given directly (tdir, any length: the
    !! slope DOFs of a finite-EI node) instead of the chord of two neighbours.
    REAL(wp), INTENT(IN) :: tdir(3), rd(3), rdd(3), u(3)
    REAL(wp), INTENT(OUT) :: yd, ydd, un
    LOGICAL, INTENT(OUT) :: ok
    REAL(wp) :: speed, t(3), vr(3), vn(3), e(3)

    yd = CD_ZERO
    ydd = CD_ZERO
    un = CD_ZERO
    speed = SQRT(tdir(1)*tdir(1) + tdir(2)*tdir(2) + tdir(3)*tdir(3))
    ok = speed > TINY_CHORD
    IF (.NOT. ok) RETURN
    t = tdir/speed
    vr = u - rd
    vn = vr - (t(1)*vr(1) + t(2)*vr(2) + t(3)*vr(3))*t
    un = SQRT(vn(1)*vn(1) + vn(2)*vn(2) + vn(3)*vn(3))
    IF (.NOT. (un > CD_ZERO)) RETURN
    e = cross3(t, vn)/un
    yd = rd(1)*e(1) + rd(2)*e(2) + rd(3)*e(3)
    ydd = rdd(1)*e(1) + rdd(2)*e(2) + rdd(3)*e(3)
  END SUBROUTINE CD_VIV_Crossflow_Along

  ELEMENTAL REAL(wp) FUNCTION CD_VIV_Mean_Square(ms_old, sample, weight) RESULT(ms)
    !! One step of the running mean square, ms_old + weight (sample^2 - ms_old); weight =
    !! 1/n_m is MoorDyn's ((n_m - 1) old^2 + new^2)/n_m.
    REAL(wp), INTENT(IN) :: ms_old, sample, weight
    ms = ms_old + weight*(sample*sample - ms_old)
  END FUNCTION CD_VIV_Mean_Square

  PURE REAL(wp) FUNCTION CD_VIV_Phase_Rate(yd, ydd, ms_yd, ms_ydd, phi, un, diameter, cf, df, phi_rest) RESULT(rate)
    !! Rate of the vortex-shedding phase, d phi/dt = 2 pi (cF + dF sin(phi_y - phi)) U/D, with
    !! the cross-flow velocity phase phi_y from y', y'' normalised by their running RMS values
    !! (unnormalised while either mean square is still zero, as MoorDyn). A node with no
    !! cross-flow motion takes phi_y = phi_rest (default 0, MoorDyn's): pi on a line whose node
    !! tangent runs against MoorDyn's, which turns the cross-flow axis and so phi_y half a turn.
    REAL(wp), INTENT(IN) :: yd, ydd, ms_yd, ms_ydd, phi, un, diameter, cf, df
    REAL(wp), INTENT(IN), OPTIONAL :: phi_rest
    REAL(wp) :: phi_y

    IF (.NOT. (ABS(yd) > CD_ZERO .OR. ABS(ydd) > CD_ZERO)) THEN
      phi_y = CD_ZERO
      IF (PRESENT(phi_rest)) phi_y = phi_rest
    ELSE IF (ms_yd > CD_ZERO .AND. ms_ydd > CD_ZERO) THEN
      phi_y = ATAN2(-ydd/SQRT(ms_ydd), yd/SQRT(ms_yd))
    ELSE
      phi_y = ATAN2(-ydd, yd)
    END IF
    IF (phi_y < CD_ZERO) phi_y = phi_y + CD_VIV_TWO_PI
    rate = CD_VIV_TWO_PI*(cf + df*SIN(phi_y - phi))*un/diameter
  END FUNCTION CD_VIV_Phase_Rate

  ELEMENTAL REAL(wp) FUNCTION CD_VIV_Wrap_Phase(phi) RESULT(wrapped)
    !! The phase mapped to [0, 2 pi); the model only uses cos(phi) and sin(. - phi).
    REAL(wp), INTENT(IN) :: phi
    wrapped = MODULO(phi, CD_VIV_TWO_PI)
    ! a tiny negative phase can round to exactly 2 pi
    IF (wrapped >= CD_VIV_TWO_PI .OR. wrapped < CD_ZERO) wrapped = CD_ZERO
  END FUNCTION CD_VIV_Wrap_Phase

END MODULE CableDyn_VIV
