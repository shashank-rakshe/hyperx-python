! File: src/CableDyn_SO3.f90
! SPDX-License-Identifier: Apache-2.0
! Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
MODULE CableDyn_SO3
  !! SO(3) primitives for the geometrically-exact Cosserat element and the
  !! finite-rotation dynamic update (the SO(3) primitives + the material tangent
  !! map T), with a small-angle threshold (|theta|^2 < 1e-12) and Taylor branches
  !! that keep every map smooth and accurate to round-off near theta = 0.
  !!
  !! Conventions (global frame, rotation-vector chart |theta| < pi):
  !!   hat(v)        -- skew-symmetric matrix with hat(v).a = v x a
  !!   exp_so3(t)    -- Rodrigues exponential so(3) -> SO(3)
  !!   log_so3(R)    -- inverse exponential SO(3) -> so(3), |theta| in [0, pi]
  !!   t_material(t) -- RIGHT Jacobian J_r = I - c1 K + c2 K^2 (the material
  !!                    tangential transform used in the curvature strain;
  !!                    distinct from the LEFT Jacobian dexp_so3 = J_l)
  USE CableDyn_Precision, ONLY: wp
  IMPLICIT NONE
  PRIVATE
  PUBLIC :: CD_Hat, CD_Exp_SO3, CD_Log_SO3, CD_T_Material, CD_Dexp_SO3, CD_Dexp_Inv_SO3
  PUBLIC :: CD_T_Material_Dir, CD_Dexp_Dir_SO3, CD_Compose_Rotvec, CD_T_Material_Dir2

  REAL(wp), PARAMETER :: SMALL_ANGLE_SQ = 1.0e-12_wp   ! small-angle switch of the series
  ! Wider switch for the directional-derivative coefficient series. The closed forms of
  ! dc1_ds (~t^4), dc2_ds (~t^5), d2c1 (~t^6) and d2c2 (~t^7) cancel their numerators down
  ! to the leading order, so they lose precision for 1e-6 < |theta| < ~0.1 -- well above
  ! SMALL_ANGLE_SQ. A 4-term series is accurate to ~1e-13 below this threshold while the
  ! closed forms are already clean (~1e-10) above it, closing that band.
  REAL(wp), PARAMETER :: DERIV_TAYLOR_SQ = 0.0625_wp   ! |theta| < 0.25
  REAL(wp), PARAMETER :: PI = 3.14159265358979323846_wp

CONTAINS

  PURE FUNCTION CD_Hat(v) RESULT(K)
    !! Skew-symmetric 3x3 from a 3-vector: K.a = v x a.
    REAL(wp), INTENT(IN) :: v(3)
    REAL(wp) :: K(3, 3)
    K(1, 1) = 0.0_wp; K(1, 2) = -v(3); K(1, 3) = v(2)
    K(2, 1) = v(3); K(2, 2) = 0.0_wp; K(2, 3) = -v(1)
    K(3, 1) = -v(2); K(3, 2) = v(1); K(3, 3) = 0.0_wp
  END FUNCTION CD_Hat

  PURE FUNCTION CD_Exp_SO3(theta) RESULT(R)
    !! Rodrigues exponential map. R = I + a K + b K^2 with
    !!   a = sin|t|/|t|,  b = (1-cos|t|)/|t|^2,
    !! and the Taylor branch a = 1 - t2/6, b = 1/2 - t2/24 for |t|^2 < 1e-12.
    REAL(wp), INTENT(IN) :: theta(3)
    REAL(wp) :: R(3, 3), K(3, 3), K2(3, 3), th2, th, a, b
    INTEGER :: i
    th2 = DOT_PRODUCT(theta, theta)
    K = CD_Hat(theta)
    K2 = MATMUL(K, K)
    IF (th2 < SMALL_ANGLE_SQ) THEN
      a = 1.0_wp - th2/6.0_wp
      b = 0.5_wp - th2/24.0_wp
    ELSE
      th = SQRT(th2)
      a = SIN(th)/th
      b = (1.0_wp - COS(th))/th2
    END IF
    R = a*K + b*K2
    DO i = 1, 3
      R(i, i) = R(i, i) + 1.0_wp
    END DO
  END FUNCTION CD_Exp_SO3

  PURE FUNCTION CD_T_Material(theta) RESULT(T)
    !! RIGHT Jacobian J_r = I - c1 K + c2 K^2 with
    !!   c1 = (1-cos|t|)/|t|^2,  c2 = (|t|-sin|t|)/|t|^3,
    !! Taylor branch c1 = 1/2 - t2/24, c2 = 1/6 - t2/120 for |t|^2 < 1e-12.
    REAL(wp), INTENT(IN) :: theta(3)
    REAL(wp) :: T(3, 3), K(3, 3), K2(3, 3), th2, th, c1, c2
    INTEGER :: i
    th2 = DOT_PRODUCT(theta, theta)
    K = CD_Hat(theta)
    K2 = MATMUL(K, K)
    IF (th2 < SMALL_ANGLE_SQ) THEN
      c1 = 0.5_wp - th2/24.0_wp
      c2 = 1.0_wp/6.0_wp - th2/120.0_wp
    ELSE
      th = SQRT(th2)
      c1 = (1.0_wp - COS(th))/th2
      c2 = (th - SIN(th))/(th2*th)
    END IF
    T = -c1*K + c2*K2
    DO i = 1, 3
      T(i, i) = T(i, i) + 1.0_wp
    END DO
  END FUNCTION CD_T_Material

  PURE FUNCTION CD_Dexp_SO3(theta) RESULT(T)
    !! LEFT Jacobian J_l = I + c1 K + c2 K^2 (= T_material^T), the forward
    !! tangential operator: a small additive rotation-vector increment dq maps to
    !! the spatial spin delta_omega = J_l(theta) . dq that, composed on the left
    !! via compose_rotvec, reproduces the additive change theta -> theta + dq to
    !! first order (same c1, c2 as CD_T_Material, with +c1 K; tests/test_so3.f90).
    REAL(wp), INTENT(IN) :: theta(3)
    REAL(wp) :: T(3, 3), K(3, 3), K2(3, 3), th2, th, c1, c2
    INTEGER :: i
    th2 = DOT_PRODUCT(theta, theta)
    K = CD_Hat(theta)
    K2 = MATMUL(K, K)
    IF (th2 < SMALL_ANGLE_SQ) THEN
      c1 = 0.5_wp - th2/24.0_wp
      c2 = 1.0_wp/6.0_wp - th2/120.0_wp
    ELSE
      th = SQRT(th2)
      c1 = (1.0_wp - COS(th))/th2
      c2 = (th - SIN(th))/(th2*th)
    END IF
    T = c1*K + c2*K2
    DO i = 1, 3
      T(i, i) = T(i, i) + 1.0_wp
    END DO
  END FUNCTION CD_Dexp_SO3

  PURE FUNCTION CD_Dexp_Inv_SO3(theta) RESULT(T)
    !! Inverse LEFT Jacobian J_l^{-1}. Maps a spatial perturbation delta in
    !! exp(delta) exp(theta) to the additive rotation-vector variation dtheta.
    REAL(wp), INTENT(IN) :: theta(3)
    REAL(wp) :: T(3, 3), K(3, 3), K2(3, 3), th2, th, a
    INTEGER :: i
    th2 = DOT_PRODUCT(theta, theta)
    K = CD_Hat(theta)
    K2 = MATMUL(K, K)
    IF (th2 < SMALL_ANGLE_SQ) THEN
      a = 1.0_wp/12.0_wp + th2/720.0_wp
    ELSE
      th = SQRT(th2)
      a = 1.0_wp/th2 - (1.0_wp + COS(th))/(2.0_wp*th*SIN(th))
    END IF
    T = -0.5_wp*K + a*K2
    DO i = 1, 3
      T(i, i) = T(i, i) + 1.0_wp
    END DO
  END FUNCTION CD_Dexp_Inv_SO3

  PURE FUNCTION CD_T_Material_Dir(theta, direction) RESULT(DT)
    !! Directional derivative D[J_r(theta)] . direction, where
    !! CD_T_Material is the RIGHT Jacobian J_r = I - c1 K + c2 K^2.
    REAL(wp), INTENT(IN) :: theta(3), direction(3)
    REAL(wp) :: DT(3, 3), K(3, 3), U(3, 3), K2(3, 3), th2, th, dth2, s2, s3
    REAL(wp) :: c1, c2, dc1_ds, dc2_ds, dc1, dc2
    th2 = DOT_PRODUCT(theta, theta)
    dth2 = 2.0_wp*DOT_PRODUCT(theta, direction)
    K = CD_Hat(theta)
    U = CD_Hat(direction)
    K2 = MATMUL(K, K)
    ! 4-term series below DERIV_TAYLOR_SQ; the dc1_ds (~t^4) / dc2_ds (~t^5) closed forms
    ! cancel their numerators and lose precision above SMALL_ANGLE_SQ but below ~0.1.
    IF (th2 < DERIV_TAYLOR_SQ) THEN
      s2 = th2*th2; s3 = s2*th2
      c1 = 0.5_wp - th2/24.0_wp + s2/720.0_wp - s3/40320.0_wp
      c2 = 1.0_wp/6.0_wp - th2/120.0_wp + s2/5040.0_wp - s3/362880.0_wp
      dc1_ds = -1.0_wp/24.0_wp + th2/360.0_wp - s2/13440.0_wp + s3/907200.0_wp
      dc2_ds = -1.0_wp/120.0_wp + th2/2520.0_wp - s2/120960.0_wp + s3/9979200.0_wp
    ELSE
      th = SQRT(th2)
      c1 = (1.0_wp - COS(th))/th2
      c2 = (th - SIN(th))/(th2*th)
      dc1_ds = (0.5_wp*th*SIN(th) - (1.0_wp - COS(th)))/(th2*th2)
      dc2_ds = ((1.0_wp - COS(th))*th - 3.0_wp*(th - SIN(th)))/(2.0_wp*th**5)
    END IF
    dc1 = dc1_ds*dth2
    dc2 = dc2_ds*dth2
    DT = -dc1*K - c1*U + dc2*K2 + c2*(MATMUL(U, K) + MATMUL(K, U))
  END FUNCTION CD_T_Material_Dir

  PURE FUNCTION CD_T_Material_Dir2(theta, dir_a, dir_b) RESULT(D2T)
    !! Second directional derivative of the RIGHT Jacobian J_r = CD_T_Material:
    !!   D2T = d/dtheta[ D[J_r](theta) . dir_a ] . dir_b = d2 J_r(theta)[dir_a, dir_b].
    !! Differentiates CD_T_Material_Dir's coefficient/matrix structure once more in
    !! theta. Needs the second derivatives of c1, c2 w.r.t. s = |theta|^2:
    !!   d2c1 = (s cos t - 5 t sin t + 8 - 8 cos t)/(4 t^6),  small: 1/360 - s/6720
    !!   d2c2 = (s sin t + 7 t cos t + 8 t - 15 sin t)/(4 t^7), small: 1/2520 - s/60480
    !! (t = |theta|). Symmetric in dir_a <-> dir_b (mixed partials of J_r commute).
    !!
    !! Small-angle branch: the closed forms above cancel their numerators from O(t)
    !! down to O(t^7) (d2c2) / O(t^6) (d2c1), so they lose all precision for small but
    !! nonzero t -- much worse than the t^2/t^4 cancellation of the lower-order
    !! coefficients. A 4-term series with the wider threshold DERIV_TAYLOR_SQ (|theta| <
    !! 0.25) keeps every coefficient accurate to ~1e-13 below the switch while the
    !! closed forms are already clean (~1e-10) above it. (The narrow SMALL_ANGLE_SQ
    !! used elsewhere would expose the cancellation band 1e-6 < |theta| < 0.1.)
    REAL(wp), INTENT(IN) :: theta(3), dir_a(3), dir_b(3)
    REAL(wp) :: D2T(3, 3), K(3, 3), Ua(3, 3), Vb(3, 3), K2(3, 3)
    REAL(wp) :: th2, th, s2, s3, c2, dc1_ds, dc2_ds, d2c1, d2c2
    REAL(wp) :: sa, sb, sab, dc1, dc2, ddc1, ddc2, dc1b, dc2b
    th2 = DOT_PRODUCT(theta, theta)
    K = CD_Hat(theta)
    Ua = CD_Hat(dir_a)
    Vb = CD_Hat(dir_b)
    K2 = MATMUL(K, K)
    IF (th2 < DERIV_TAYLOR_SQ) THEN
      s2 = th2*th2; s3 = s2*th2
      c2 = 1.0_wp/6.0_wp - th2/120.0_wp + s2/5040.0_wp - s3/362880.0_wp
      dc1_ds = -1.0_wp/24.0_wp + th2/360.0_wp - s2/13440.0_wp + s3/907200.0_wp
      dc2_ds = -1.0_wp/120.0_wp + th2/2520.0_wp - s2/120960.0_wp + s3/9979200.0_wp
      d2c1 = 1.0_wp/360.0_wp - th2/6720.0_wp + s2/302400.0_wp - s3/23950080.0_wp
      d2c2 = 1.0_wp/2520.0_wp - th2/60480.0_wp + s2/3326400.0_wp - s3/311351040.0_wp
    ELSE
      th = SQRT(th2)
      c2 = (th - SIN(th))/(th2*th)
      dc1_ds = (0.5_wp*th*SIN(th) - (1.0_wp - COS(th)))/(th2*th2)
      dc2_ds = ((1.0_wp - COS(th))*th - 3.0_wp*(th - SIN(th)))/(2.0_wp*th**5)
      d2c1 = (th2*COS(th) - 5.0_wp*th*SIN(th) + 8.0_wp - 8.0_wp*COS(th))/(4.0_wp*th**6)
      d2c2 = (th2*SIN(th) + 7.0_wp*th*COS(th) + 8.0_wp*th - 15.0_wp*SIN(th))/(4.0_wp*th**7)
    END IF
    sa = 2.0_wp*DOT_PRODUCT(theta, dir_a)   ! d(|theta|^2) in direction a
    sb = 2.0_wp*DOT_PRODUCT(theta, dir_b)   ! d(|theta|^2) in direction b
    sab = 2.0_wp*DOT_PRODUCT(dir_a, dir_b)  ! d^2(|theta|^2)[a,b]
    dc1 = dc1_ds*sa                         ! delta_a c1 (as used inside CD_T_Material_Dir)
    dc2 = dc2_ds*sa
    ddc1 = d2c1*sb*sa + dc1_ds*sab          ! delta_b(delta_a c1)
    ddc2 = d2c2*sb*sa + dc2_ds*sab
    dc1b = dc1_ds*sb                        ! delta_b c1
    dc2b = dc2_ds*sb
    D2T = -ddc1*K - dc1*Vb - dc1b*Ua + ddc2*K2 + dc2*(MATMUL(Vb, K) + MATMUL(K, Vb)) &
          + dc2b*(MATMUL(Ua, K) + MATMUL(K, Ua)) + c2*(MATMUL(Ua, Vb) + MATMUL(Vb, Ua))
  END FUNCTION CD_T_Material_Dir2

  PURE FUNCTION CD_Dexp_Dir_SO3(theta, direction) RESULT(DT)
    !! Directional derivative D[J_l(theta)] . direction. Since J_l = J_r^T,
    !! this is the transpose of CD_T_Material_Dir for the same direction.
    REAL(wp), INTENT(IN) :: theta(3), direction(3)
    REAL(wp) :: DT(3, 3)
    DT = TRANSPOSE(CD_T_Material_Dir(theta, direction))
  END FUNCTION CD_Dexp_Dir_SO3

  PURE FUNCTION CD_Compose_Rotvec(theta_old, dtheta) RESULT(theta_new)
    !! Multiplicative SO(3) composition: theta_new = log(exp(dtheta) exp(theta_old)),
    !! i.e. apply the spatial spin dtheta on the left of the rotation theta_old.
    REAL(wp), INTENT(IN) :: theta_old(3), dtheta(3)
    REAL(wp) :: theta_new(3), R_d(3, 3), R_old(3, 3), R_comp(3, 3)
    R_d = CD_Exp_SO3(dtheta)
    R_old = CD_Exp_SO3(theta_old)
    R_comp = MATMUL(R_d, R_old)
    theta_new = CD_Log_SO3(R_comp)
  END FUNCTION CD_Compose_Rotvec

  PURE FUNCTION CD_Log_SO3(R) RESULT(theta)
    !! Inverse exponential, |theta| in [0, pi]. Three branches matching the
    !! reference: small-angle Taylor (theta < 1e-6), near-pi eigenvector axis
    !! (theta > pi - 1e-6), and the regular axis = (R - R^T)/(2 sin theta).
    REAL(wp), INTENT(IN) :: R(3, 3)
    REAL(wp) :: theta(3), tr, cos_th, th, v(3), S(3, 3), axis(3), nrm, inv
    INTEGER :: i, idx, sign_idx
    tr = R(1, 1) + R(2, 2) + R(3, 3)
    cos_th = 0.5_wp*(tr - 1.0_wp)
    cos_th = MAX(-1.0_wp, MIN(1.0_wp, cos_th))     ! absorb identity round-off
    th = ACOS(cos_th)
    v = [R(3, 2) - R(2, 3), R(1, 3) - R(3, 1), R(2, 1) - R(1, 2)]
    IF (th < 1.0e-6_wp) THEN
      theta = 0.5_wp*v                              ! first-order theta_hat = (R - R^T)/2
      RETURN
    END IF
    IF (th > PI - 1.0e-6_wp) THEN
      ! near-pi: axis = unit eigenvector of (R + I)/2 = u u^T, dominant column
      S = 0.5_wp*R
      DO i = 1, 3
        S(i, i) = S(i, i) + 0.5_wp
      END DO
      idx = 1
      IF (S(2, 2) > S(idx, idx)) idx = 2
      IF (S(3, 3) > S(idx, idx)) idx = 3
      axis = S(:, idx)
      nrm = SQRT(DOT_PRODUCT(axis, axis))
      axis = axis/nrm
      ! sign: the off-diagonal-difference vector v = 2 sin(th) axis (sin > 0 on (0,pi))
      sign_idx = 1
      IF (ABS(axis(2)) > ABS(axis(sign_idx))) sign_idx = 2
      IF (ABS(axis(3)) > ABS(axis(sign_idx))) sign_idx = 3
      IF (v(sign_idx)*axis(sign_idx) < 0.0_wp) axis = -axis
      theta = th*axis
      RETURN
    END IF
    inv = 1.0_wp/(2.0_wp*SIN(th))                   ! regular branch
    theta = th*inv*v
  END FUNCTION CD_Log_SO3

END MODULE CableDyn_SO3
