! File: src/CableDyn_Cosserat.f90
! SPDX-License-Identifier: Apache-2.0
! Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
MODULE CableDyn_Cosserat
  !! Geometrically-exact Cosserat rod element (Simo 1985; Simo & Vu-Quoc 1986) of the
  !! secondary (non-production) Cosserat path. 2-node, 6-DOF/node, with the
  !! nodal DOFs the absolute current positions and rotation vectors
  !!   q = [r1(3), theta1(3), r2(3), theta2(3)]   (global frame).
  !!
  !! The module provides:
  !!   * CD_Reference_Frame  -- Lam0, L0 from the reference node positions.
  !!   * CD_Cosserat_Strains -- material strains (Gamma, Kappa) at a Gauss point
  !!                            via the Jelenic & Crisfield objective relative-
  !!                            rotation interpolation.
  !!   * the closed-form internal force and tangent stiffness, with forward-mode AD
  !!     (CableDyn_AD) kept as the test oracle; the consistent mass is in
  !!     CableDyn_CosseratDynamic.
  !!
  !! Material strain measures at arc-length parameter xi in [-1, 1] (Simo 1985
  !! eq. 4.8b, 4.13), with linear-Lagrange shape functions N and the J&C
  !! interpolated relative rotation theta_rel = N2 * log(Lam1^T Lam2):
  !!   tangent       = (r2 - r1) / L0
  !!   Lam_g         = Lam1 . exp(theta_rel)
  !!   Gamma         = Lam0^T (Lam_g^T tangent) - E3
  !!   dtheta_rel/ds = theta_rel_2 / L0
  !!   Kappa         = Lam0^T (T_material(theta_rel) . dtheta_rel/ds)
  USE CableDyn_Precision, ONLY: wp, CD_All_Finite, CD_Is_Finite
  USE CableDyn_SO3, ONLY: CD_Hat, CD_Exp_SO3, CD_Log_SO3, CD_T_Material, CD_Dexp_SO3, &
                          CD_Dexp_Inv_SO3, CD_T_Material_Dir, CD_Dexp_Dir_SO3, CD_T_Material_Dir2
  USE CableDyn_AD, ONLY: Dual1, Dual2, AD_NV, AD1_Var, AD1_Const, AD_Var, AD_Const, &
                         OPERATOR(+), OPERATOR(-), OPERATOR(*), OPERATOR(/), &
                         AD1_Sqrt, AD1_Sin, AD1_Cos, AD1_Atan2, AD_Sqrt, AD_Sin, AD_Cos, AD_Atan2
  IMPLICIT NONE
  PRIVATE
  PUBLIC :: CD_Reference_Frame, CD_Cosserat_Strains
  PUBLIC :: CD_Cosserat_Internal_Force, CD_Cosserat_Force_Tangent
  PUBLIC :: CD_Cosserat_Internal_Force_AD_Oracle, CD_Cosserat_Force_Tangent_AD_Oracle
  PUBLIC :: CD_Cosserat_Element_Energy, CD_Cosserat_Validate_Rotation_State

  REAL(wp), PARAMETER :: PI = 3.14159265358979323846_wp
  REAL(wp), PARAMETER :: E3(3) = [0.0_wp, 0.0_wp, 1.0_wp]
  REAL(wp), PARAMETER :: SMALL_ANGLE_SQ = 1.0e-12_wp   ! small-angle switch of the log map
  REAL(wp), PARAMETER :: INV_SQRT3 = 0.57735026918962576450914878050196_wp

  ! 2-point Gauss on [-1, 1] for axial + curvature; 1-point (reduced) for shear.
  REAL(wp), PARAMETER :: GAUSS2_XI(2) = [-INV_SQRT3, INV_SQRT3]
  REAL(wp), PARAMETER :: GAUSS2_W(2) = [1.0_wp, 1.0_wp]

  ! Per-element xi-independent SO(3) quantities (depend only on the nodal rotations,
  ! not on the Gauss point). Built once per public tangent/force entry by
  ! build_rot_cache and threaded through the analytical evaluators so the trig-heavy
  ! Exp/Log/dexp are not recomputed at every Gauss point and sub-block. Cached values
  ! are bit-identical to recomputing them, so the assembled tangent is unchanged.
  TYPE :: rot_cache_t
    REAL(wp) :: Lam1(3, 3), Lam2(3, 3), psi(3)
    REAL(wp) :: J1(3, 3), J2(3, 3), Jpsi_inv(3, 3)
  END TYPE rot_cache_t

CONTAINS

  PURE SUBROUTINE CD_Reference_Frame(r1_ref, r2_ref, Lam0, L0)
    !! Reference rotation Lam0 (constant along the element) aligning the local
    !! d3 axis with (r2_ref - r1_ref) along the shortest S^2 geodesic, and the
    !! reference length L0 = |r2_ref - r1_ref|, including the d3 = -E3 flip
    !! (axis = e1, angle = pi).
    !!
    !! CONTRACT: this low-level PURE primitive carries no ErrStat; the fail-closed
    !! boundary is the public solve path (CD_Assemble_Cosserat_* / the solver), which
    !! rejects zero-length / non-finite reference spans before reaching here. It is
    !! nonetheless NaN-safe: coincident reference points (a zero-length span) return a
    !! DEFINED degenerate frame (Lam0 = I, L0 = 0) instead of NaN, and the L0 = 0 the
    !! caller then sees is rejected by the upstream L0 > 0 validation.
    REAL(wp), INTENT(IN) :: r1_ref(3), r2_ref(3)
    REAL(wp), INTENT(OUT) :: Lam0(3, 3), L0
    REAL(wp) :: d(3), d3(3), axis(3), cos_a, axis_norm_sq, angle, rot_vec(3)
    d = r2_ref - r1_ref
    L0 = SQRT(DOT_PRODUCT(d, d))
    IF (L0 <= 0.0_wp) THEN                          ! coincident points: defined, no NaN
      L0 = 0.0_wp
      Lam0 = CD_Exp_SO3([0.0_wp, 0.0_wp, 0.0_wp])
      RETURN
    END IF
    d3 = d/L0
    cos_a = d3(3)                                  ! E3 . d3
    axis = [-d3(2), d3(1), 0.0_wp]                 ! E3 x d3
    axis_norm_sq = DOT_PRODUCT(axis, axis)
    IF (cos_a < -1.0_wp + 1.0e-12_wp) THEN
      rot_vec = [PI, 0.0_wp, 0.0_wp]               ! d3 = -E3: any axis perp to E3
    ELSE IF (axis_norm_sq < 1.0e-30_wp) THEN
      rot_vec = 0.0_wp                             ! d3 = +E3: Lam0 = I
    ELSE
      angle = ACOS(MAX(-1.0_wp, MIN(1.0_wp, cos_a)))
      rot_vec = (axis/SQRT(axis_norm_sq))*angle
    END IF
    Lam0 = CD_Exp_SO3(rot_vec)
  END SUBROUTINE CD_Reference_Frame

  PURE SUBROUTINE CD_Cosserat_Strains(q, Lam0, L0, xi, Gamma, Kappa)
    !! Material strains (Gamma, Kappa) at one Gauss point xi, from the nodal
    !! state q and the element reference frame (Lam0, L0), from the interpolated
    !! centreline and rotation fields.
    !!
    !! PRECONDITION: L0 > 0 and q finite (this low-level PURE primitive divides by
    !! L0 and carries no ErrStat). The fail-closed public entry point is
    !! CD_Cosserat_Force_Tangent / the assembler / the solver, which validate the
    !! geometry and reject the degenerate cases before reaching here.
    REAL(wp), INTENT(IN) :: q(12), Lam0(3, 3), L0, xi
    REAL(wp), INTENT(OUT) :: Gamma(3), Kappa(3)
    REAL(wp) :: r1(3), th1(3), r2(3), th2(3)
    REAL(wp) :: Lam1(3, 3), Lam2(3, 3), theta_rel_2(3), theta_rel(3)
    REAL(wp) :: tangent(3), Lam_g(3, 3), dtheta_rel_ds(3), n2
    r1 = q(1:3); th1 = q(4:6); r2 = q(7:9); th2 = q(10:12)
    Lam1 = CD_Exp_SO3(th1)
    Lam2 = CD_Exp_SO3(th2)
    theta_rel_2 = CD_Log_SO3(MATMUL(TRANSPOSE(Lam1), Lam2))
    n2 = 0.5_wp*(1.0_wp + xi)                      ! shape function at node 2
    theta_rel = n2*theta_rel_2
    tangent = (r2 - r1)/L0                          ! (dN1 r1 + dN2 r2)/jacobian
    Lam_g = MATMUL(Lam1, CD_Exp_SO3(theta_rel))
    Gamma = MATMUL(TRANSPOSE(Lam0), MATMUL(TRANSPOSE(Lam_g), tangent)) - E3
    dtheta_rel_ds = theta_rel_2/L0                  ! dN2 theta_rel_2 / jacobian
    Kappa = MATMUL(TRANSPOSE(Lam0), MATMUL(CD_T_Material(theta_rel), dtheta_rel_ds))
  END SUBROUTINE CD_Cosserat_Strains

  SUBROUTINE CD_Cosserat_Validate_Rotation_State(q, ErrStat, ErrMsg)
    !! Shared element-domain validity of the two nodal rotation vectors in a 12-DOF
    !! element state q (rotation triplets q(4:6), q(10:12)): each must lie strictly
    !! inside the unique |theta| < pi exponential chart, and their relative rotation
    !! Exp(theta_a)^T Exp(theta_b) must not sit in the ACTUAL log-singular window of
    !! the AD log map (skew norm |v|^2 < SMALL_ANGLE_SQ AND cos_phi < 0, i.e. within
    !! ~5e-7 rad of pi, where the AD log map fails). A merely
    !! large-but-sub-singular relative rotation stays evaluable and is NOT
    !! rejected. The force, tangent, and energy paths all defer to this one routine
    !! so they enforce identical element-domain contracts (no path can silently
    !! accept a state another rejects). PRECONDITION: q finite (checked by callers).
    REAL(wp), INTENT(IN) :: q(12)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    REAL(wp) :: Rrel(3, 3), v_rel(3), vns_rel, cos_phi
    ErrStat = 0
    ErrMsg = ''
    IF (DOT_PRODUCT(q(4:6), q(4:6)) >= PI*PI .OR. DOT_PRODUCT(q(10:12), q(10:12)) >= PI*PI) THEN
      ErrStat = 1
      ErrMsg = 'nodal rotation vector outside the |theta| < pi chart'
      RETURN
    END IF
    Rrel = MATMUL(TRANSPOSE(CD_Exp_SO3(q(4:6))), CD_Exp_SO3(q(10:12)))
    v_rel = [Rrel(3, 2) - Rrel(2, 3), Rrel(1, 3) - Rrel(3, 1), Rrel(2, 1) - Rrel(1, 2)]
    vns_rel = DOT_PRODUCT(v_rel, v_rel)
    cos_phi = 0.5_wp*(Rrel(1, 1) + Rrel(2, 2) + Rrel(3, 3) - 1.0_wp)
    IF (vns_rel < SMALL_ANGLE_SQ .AND. cos_phi < 0.0_wp) THEN
      ErrStat = 1
      ErrMsg = 'nodal relative rotation too close to pi (log singular)'
      RETURN
    END IF
  END SUBROUTINE CD_Cosserat_Validate_Rotation_State

  PURE FUNCTION CD_Cosserat_Element_Energy(q, ea, gas, ei, gj, Lam0, L0, reduced_shear) RESULT(U)
    !! Element strain energy U(q) = sum_g w J [1/2 EA Gamma3^2 + 1/2 EI(K1^2+K2^2)
    !! + 1/2 GJ K3^2] + reduced-shear 1/2 GAs(Gamma1^2 + Gamma2^2). The real-valued
    !! energy (the value CD_Cosserat_Force_Tangent differentiates), for the L1-8
    !! mechanical-energy diagnostic. Same quadrature as the force/tangent.
    !! PRECONDITION: L0 > 0, q finite (validated by the public solve/energy path).
    REAL(wp), INTENT(IN) :: q(12), ea, gas, ei, gj, Lam0(3, 3), L0
    LOGICAL, INTENT(IN) :: reduced_shear
    REAL(wp) :: U, jac, G(3), K(3)
    TYPE(rot_cache_t) :: ctx
    INTEGER :: gp
    jac = 0.5_wp*L0
    U = 0.0_wp
    ctx = build_rot_cache(q)
    DO gp = 1, 2
      CALL cached_strains(ctx, q, Lam0, L0, GAUSS2_XI(gp), G, K)
      U = U + GAUSS2_W(gp)*jac*(0.5_wp*ea*G(3)**2 &
                                + 0.5_wp*ei*(K(1)**2 + K(2)**2) + 0.5_wp*gj*K(3)**2)
    END DO
    IF (reduced_shear) THEN
      CALL cached_strains(ctx, q, Lam0, L0, 0.0_wp, G, K)
      U = U + 2.0_wp*jac*(0.5_wp*gas*(G(1)**2 + G(2)**2))
    ELSE
      DO gp = 1, 2
        CALL cached_strains(ctx, q, Lam0, L0, GAUSS2_XI(gp), G, K)
        U = U + GAUSS2_W(gp)*jac*(0.5_wp*gas*(G(1)**2 + G(2)**2))
      END DO
    END IF
  END FUNCTION CD_Cosserat_Element_Energy

  SUBROUTINE CD_Cosserat_Internal_Force(q, ea, gas, ei, gj, Lam0, L0, reduced_shear, &
                                        fint, ErrStat, ErrMsg)
    !! Internal force fint = dU/dq of the geometrically-exact element, evaluated
    !! from the closed-form material strain-displacement operator
    !! fint = int (B_Gamma^T n + B_Kappa^T m) ds. This is the production
    !! residual path: no AD objects are allocated, and the single shared
    !! validate_force_inputs contract remains the only element-domain gate.
    REAL(wp), INTENT(IN) :: q(12), ea, gas, ei, gj, Lam0(3, 3), L0
    LOGICAL, INTENT(IN) :: reduced_shear
    REAL(wp), INTENT(OUT) :: fint(12)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    ErrStat = 0
    ErrMsg = ''
    fint = 0.0_wp
    CALL validate_force_inputs(q, ea, gas, ei, gj, Lam0, L0, ErrStat, ErrMsg)
    IF (ErrStat /= 0) RETURN
    CALL analytic_internal_force_eval(build_rot_cache(q), q, ea, gas, ei, gj, Lam0, L0, reduced_shear, fint)
  END SUBROUTINE CD_Cosserat_Internal_Force

  SUBROUTINE CD_Cosserat_Force_Tangent(q, ea, gas, ei, gj, Lam0, L0, reduced_shear, &
                                       fint, Kt, ErrStat, ErrMsg)
    !! Internal force fint = dU/dq and tangent Kt = d(fint)/dq of the
    !! geometrically-exact element, where the strain energy is
    !!   U = sum_g2 w J [1/2 EA Gamma3^2 + 1/2 EI (K1^2+K2^2) + 1/2 GJ K3^2]
    !!     + sum_gs w J [1/2 GAs (Gamma1^2 + Gamma2^2)]
    !! (gs = 1-point reduced Gauss for the transverse-shear strains when
    !! reduced_shear, else the full 2-point rule). Fully closed form: fint = B^T s and
    !! Kt = K_material (B^T C B) + K_geometric (translational/coupling + the rotation
    !! SO(3) Hessian). CD_Cosserat_Force_Tangent_AD_Oracle is retained as the Dual2
    !! parity reference (test_cosserat_force gates this path against it to ~1e-12).
    REAL(wp), INTENT(IN) :: q(12), ea, gas, ei, gj, Lam0(3, 3), L0
    LOGICAL, INTENT(IN) :: reduced_shear
    REAL(wp), INTENT(OUT) :: fint(12), Kt(12, 12)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    TYPE(rot_cache_t) :: ctx
    ErrStat = 0
    ErrMsg = ''
    fint = 0.0_wp
    Kt = 0.0_wp
    CALL validate_force_inputs(q, ea, gas, ei, gj, Lam0, L0, ErrStat, ErrMsg)
    IF (ErrStat /= 0) RETURN
    ctx = build_rot_cache(q)   ! xi-independent SO(3) quantities, shared by both evaluators
    CALL analytic_internal_force_eval(ctx, q, ea, gas, ei, gj, Lam0, L0, reduced_shear, fint)
    CALL analytic_force_tangent_eval(ctx, q, ea, gas, ei, gj, Lam0, L0, reduced_shear, Kt)
  END SUBROUTINE CD_Cosserat_Force_Tangent

  SUBROUTINE CD_Cosserat_Internal_Force_AD_Oracle(q, ea, gas, ei, gj, Lam0, L0, reduced_shear, &
                                                  fint, ErrStat, ErrMsg)
    !! First-order AD internal-force reference retained for regression. The
    !! production residual uses analytic_internal_force_eval; this path proves it
    !! still differentiates the exact same scalar energy and quadrature.
    REAL(wp), INTENT(IN) :: q(12), ea, gas, ei, gj, Lam0(3, 3), L0
    LOGICAL, INTENT(IN) :: reduced_shear
    REAL(wp), INTENT(OUT) :: fint(12)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    TYPE(Dual1) :: qd(12), U, dens, G(3), K(3)
    REAL(wp) :: jac, w
    INTEGER :: dof, gp
    ErrStat = 0
    ErrMsg = ''
    fint = 0.0_wp
    CALL validate_force_inputs(q, ea, gas, ei, gj, Lam0, L0, ErrStat, ErrMsg)
    IF (ErrStat /= 0) RETURN
    DO dof = 1, 12
      qd(dof) = AD1_Var(q(dof), dof)
    END DO
    jac = 0.5_wp*L0
    U = AD1_Const(0.0_wp)
    DO gp = 1, 2
      w = GAUSS2_W(gp)
      CALL d1_strains(qd, Lam0, L0, GAUSS2_XI(gp), G, K)
      dens = (0.5_wp*ea)*(G(3)*G(3)) &
             + (0.5_wp*ei)*(K(1)*K(1) + K(2)*K(2)) &
             + (0.5_wp*gj)*(K(3)*K(3))
      U = U + (w*jac)*dens
    END DO
    IF (reduced_shear) THEN
      CALL d1_strains(qd, Lam0, L0, 0.0_wp, G, K)
      dens = (0.5_wp*gas)*(G(1)*G(1) + G(2)*G(2))
      U = U + (2.0_wp*jac)*dens
    ELSE
      DO gp = 1, 2
        w = GAUSS2_W(gp)
        CALL d1_strains(qd, Lam0, L0, GAUSS2_XI(gp), G, K)
        dens = (0.5_wp*gas)*(G(1)*G(1) + G(2)*G(2))
        U = U + (w*jac)*dens
      END DO
    END IF
    fint = U%g
  END SUBROUTINE CD_Cosserat_Internal_Force_AD_Oracle

  SUBROUTINE CD_Cosserat_Force_Tangent_AD_Oracle(q, ea, gas, ei, gj, Lam0, L0, reduced_shear, &
                                                 fint, Kt, ErrStat, ErrMsg)
    !! Second-order AD force/tangent oracle kept beside the closed-form element for the
    !! tests.
    REAL(wp), INTENT(IN) :: q(12), ea, gas, ei, gj, Lam0(3, 3), L0
    LOGICAL, INTENT(IN) :: reduced_shear
    REAL(wp), INTENT(OUT) :: fint(12), Kt(12, 12)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    TYPE(Dual2) :: qd(12), U, dens, G(3), K(3)
    REAL(wp) :: jac, w
    INTEGER :: dof, gp
    ErrStat = 0
    ErrMsg = ''
    fint = 0.0_wp
    Kt = 0.0_wp
    CALL validate_force_inputs(q, ea, gas, ei, gj, Lam0, L0, ErrStat, ErrMsg)
    IF (ErrStat /= 0) RETURN
    DO dof = 1, 12
      qd(dof) = AD_Var(q(dof), dof)
    END DO
    jac = 0.5_wp*L0
    U = AD_Const(0.0_wp)
    DO gp = 1, 2
      w = GAUSS2_W(gp)
      CALL d_strains(qd, Lam0, L0, GAUSS2_XI(gp), G, K)
      dens = (0.5_wp*ea)*(G(3)*G(3)) &
             + (0.5_wp*ei)*(K(1)*K(1) + K(2)*K(2)) &
             + (0.5_wp*gj)*(K(3)*K(3))
      U = U + (w*jac)*dens
    END DO
    IF (reduced_shear) THEN
      CALL d_strains(qd, Lam0, L0, 0.0_wp, G, K)
      dens = (0.5_wp*gas)*(G(1)*G(1) + G(2)*G(2))
      U = U + (2.0_wp*jac)*dens
    ELSE
      DO gp = 1, 2
        w = GAUSS2_W(gp)
        CALL d_strains(qd, Lam0, L0, GAUSS2_XI(gp), G, K)
        dens = (0.5_wp*gas)*(G(1)*G(1) + G(2)*G(2))
        U = U + (w*jac)*dens
      END DO
    END IF
    fint = U%g
    Kt = U%h
  END SUBROUTINE CD_Cosserat_Force_Tangent_AD_Oracle

  PURE FUNCTION build_rot_cache(q) RESULT(ctx)
    !! Compute the xi-independent SO(3) quantities once for an element state.
    REAL(wp), INTENT(IN) :: q(12)
    TYPE(rot_cache_t) :: ctx
    REAL(wp) :: th1(3), th2(3)
    th1 = q(4:6); th2 = q(10:12)
    ctx%Lam1 = CD_Exp_SO3(th1)
    ctx%Lam2 = CD_Exp_SO3(th2)
    ctx%psi = CD_Log_SO3(MATMUL(TRANSPOSE(ctx%Lam1), ctx%Lam2))
    ctx%J1 = CD_Dexp_SO3(th1)
    ctx%J2 = CD_Dexp_SO3(th2)
    ctx%Jpsi_inv = CD_Dexp_Inv_SO3(ctx%psi)
  END FUNCTION build_rot_cache

  PURE SUBROUTINE cached_strains(ctx, q, Lam0, L0, xi, Gamma, Kappa)
    !! Material strains at one Gauss point using the cache -- identical to
    !! CD_Cosserat_Strains but sourcing the xi-independent Lam1 and theta_rel_2 (= psi)
    !! from ctx instead of recomputing Exp(th1)/Exp(th2)/Log. Bit-identical to
    !! CD_Cosserat_Strains; used by the geometric-tangent stress stations so no
    !! Gauss point in the analytical tangent recomputes the trig-heavy SO(3) setup.
    TYPE(rot_cache_t), INTENT(IN) :: ctx
    REAL(wp), INTENT(IN) :: q(12), Lam0(3, 3), L0, xi
    REAL(wp), INTENT(OUT) :: Gamma(3), Kappa(3)
    REAL(wp) :: theta_rel(3), tangent(3), Lam1(3, 3), Rrel(3, 3), Lam_g(3, 3), Tmat(3, 3)
    REAL(wp) :: dtheta_rel_ds(3), vtmp(3), A0(3, 3), n2
    n2 = 0.5_wp*(1.0_wp + xi)
    theta_rel = n2*ctx%psi
    tangent = (q(7:9) - q(1:3))/L0
    A0 = TRANSPOSE(Lam0)
    Lam1 = ctx%Lam1
    Rrel = CD_Exp_SO3(theta_rel)
    Lam_g = MATMUL(Lam1, Rrel)
    vtmp = MATMUL(TRANSPOSE(Lam_g), tangent)
    Gamma = MATMUL(A0, vtmp) - E3
    dtheta_rel_ds = ctx%psi/L0
    Tmat = CD_T_Material(theta_rel)
    vtmp = MATMUL(Tmat, dtheta_rel_ds)
    Kappa = MATMUL(A0, vtmp)
  END SUBROUTINE cached_strains

  PURE SUBROUTINE analytic_internal_force_eval(ctx, q, ea, gas, ei, gj, Lam0, L0, reduced_shear, fint)
    !! Closed-form B^T stress resultant assembly. Inputs are assumed validated by
    !! the public wrapper; this low-level evaluator is intentionally allocation-
    !! free and has no ErrStat branch for hot residual and tangent differencing.
    TYPE(rot_cache_t), INTENT(IN) :: ctx
    REAL(wp), INTENT(IN) :: q(12), ea, gas, ei, gj, Lam0(3, 3), L0
    LOGICAL, INTENT(IN) :: reduced_shear
    REAL(wp), INTENT(OUT) :: fint(12)
    REAL(wp) :: jac, G(3), K(3), Bg(3, 12), Bk(3, 12), n(3), m(3)
    INTEGER :: gp
    jac = 0.5_wp*L0
    fint = 0.0_wp
    DO gp = 1, 2
      CALL analytic_b_operator(ctx, q, Lam0, L0, GAUSS2_XI(gp), G, K, Bg, Bk)
      n = [0.0_wp, 0.0_wp, ea*G(3)]
      m = [ei*K(1), ei*K(2), gj*K(3)]
      fint = fint + GAUSS2_W(gp)*jac*(MATMUL(TRANSPOSE(Bg), n) + MATMUL(TRANSPOSE(Bk), m))
    END DO
    IF (reduced_shear) THEN
      CALL analytic_b_operator(ctx, q, Lam0, L0, 0.0_wp, G, K, Bg, Bk)
      n = [gas*G(1), gas*G(2), 0.0_wp]
      fint = fint + 2.0_wp*jac*MATMUL(TRANSPOSE(Bg), n)
    ELSE
      DO gp = 1, 2
        CALL analytic_b_operator(ctx, q, Lam0, L0, GAUSS2_XI(gp), G, K, Bg, Bk)
        n = [gas*G(1), gas*G(2), 0.0_wp]
        fint = fint + GAUSS2_W(gp)*jac*MATMUL(TRANSPOSE(Bg), n)
      END DO
    END IF
  END SUBROUTINE analytic_internal_force_eval

  PURE SUBROUTINE analytic_translational_tangent_eval(ctx, q, ea, gas, Lam0, L0, reduced_shear, Kt)
    !! Exact analytical tangent columns for translational DOFs. With rotational
    !! DOFs held fixed, Kappa is position-independent. The position columns are
    !! B^T C_Gamma B_r plus the geometric dB_r/dx : n term in rotational force
    !! rows; the symmetric rows are mirrored from those columns. The rotation-rotation
    !! block is formed by the closed-form SO(3) tangent.
    TYPE(rot_cache_t), INTENT(IN) :: ctx
    REAL(wp), INTENT(IN) :: q(12), ea, gas, Lam0(3, 3), L0
    LOGICAL, INTENT(IN) :: reduced_shear
    REAL(wp), INTENT(INOUT) :: Kt(12, 12)
    INTEGER, PARAMETER :: TIDX(6) = [1, 2, 3, 7, 8, 9]
    REAL(wp) :: Kpos(12, 6), G(3), K(3), Bg(3, 12), Bk(3, 12), Cg(3, 3), n(3), jac
    INTEGER :: gp, i, j

    jac = 0.5_wp*L0
    Kpos = 0.0_wp
    Cg = 0.0_wp
    Cg(3, 3) = ea
    DO gp = 1, 2
      CALL analytic_b_operator(ctx, q, Lam0, L0, GAUSS2_XI(gp), G, K, Bg, Bk)
      n = MATMUL(Cg, G)
      Kpos = Kpos + GAUSS2_W(gp)*jac*(MATMUL(TRANSPOSE(Bg), MATMUL(Cg, Bg(:, TIDX))) + &
                                      analytic_position_geometric_columns(ctx, Lam0, L0, GAUSS2_XI(gp), n))
    END DO

    Cg = 0.0_wp
    Cg(1, 1) = gas
    Cg(2, 2) = gas
    IF (reduced_shear) THEN
      CALL analytic_b_operator(ctx, q, Lam0, L0, 0.0_wp, G, K, Bg, Bk)
      n = MATMUL(Cg, G)
      Kpos = Kpos + 2.0_wp*jac*(MATMUL(TRANSPOSE(Bg), MATMUL(Cg, Bg(:, TIDX))) + &
                                analytic_position_geometric_columns(ctx, Lam0, L0, 0.0_wp, n))
    ELSE
      DO gp = 1, 2
        CALL analytic_b_operator(ctx, q, Lam0, L0, GAUSS2_XI(gp), G, K, Bg, Bk)
        n = MATMUL(Cg, G)
        Kpos = Kpos + GAUSS2_W(gp)*jac*(MATMUL(TRANSPOSE(Bg), MATMUL(Cg, Bg(:, TIDX))) + &
                                        analytic_position_geometric_columns(ctx, Lam0, L0, GAUSS2_XI(gp), n))
      END DO
    END IF

    DO j = 1, SIZE(TIDX)
      DO i = 1, 12
        Kt(i, TIDX(j)) = Kpos(i, j)
        Kt(TIDX(j), i) = Kpos(i, j)
      END DO
    END DO
  END SUBROUTINE analytic_translational_tangent_eval

  PURE SUBROUTINE analytic_rotation_geo(ctx, q, Lam0, L0, xi, nstress, mstress, Kblk)
    !! Rotation-rotation GEOMETRIC tangent at one Gauss point, combining both stress
    !! resultants in a single pass over the SO(3) second variation:
    !!   Kblk(c,d) = nstress . d2(Gamma)/dtheta_c dtheta_d  (axial/shear)
    !!             + mstress . d2(Kappa)/dtheta_c dtheta_d  (bending/twist)
    !! over the six rotation DOFs RID = [4,5,6,10,11,12]. The shared SO(3) setup and the
    !! per-(c,d) angular chain (dpsi/ddpsi via CD_Dexp_Dir_SO3 and d(dexp_inv) =
    !! -Jinv dJ Jinv) are computed once and reused by both contributions. The
    !! xi-independent Lam1/Lam2/psi/J1/J2/Jpsi_inv come from the cache. With
    !! Gamma = A0 hat(dmat) omat and Kappa = A0 T(phi)(psi/L0); the kappa term adds the
    !! second directional derivative of T_material (CD_T_Material_Dir2). Both blocks are
    !! symmetric by construction (Hessian); the AD-oracle harness verifies the assembly.
    !! When mstress is zero (e.g. the shear-only reduced point) the kappa work is skipped.
    TYPE(rot_cache_t), INTENT(IN) :: ctx
    REAL(wp), INTENT(IN) :: q(12), Lam0(3, 3), L0, xi, nstress(3), mstress(3)
    REAL(wp), INTENT(OUT) :: Kblk(6, 6)
    REAL(wp) :: th1(3), th2(3), Lam1(3, 3), Lam1T(3, 3), psi(3)
    REAL(wp) :: phi(3), Rphi(3, 3), Rg(3, 3), RgT(3, 3), t(3), dmat(3), hat_dmat(3, 3)
    REAL(wp) :: J1(3, 3), J2(3, 3), Jpsi_inv(3, 3), Jphi(3, 3), Tphi(3, 3), n2, inv_l0, nn(3), mm(3)
    REAL(wp) :: p1(3, 6), p2(3, 6), w1(3, 6), w2(3, 6), eta(3, 6), dpsi(3, 6), dphi(3, 6)
    REAL(wp) :: wg(3, 6), omat(3, 6), Jphi_dphi(3, 6), Tdir_dphi(3, 3, 6), Lam1Jphi(3, 3), psi_l(3)
    REAL(wp) :: dJ1(3, 3), dJ2(3, 3), dJpi(3, 3), dJphi(3, 3), dLam1(3, 3), Lam1dJphi(3, 3)
    REAL(wp) :: hatw1d(3, 3), ddmat(3)
    REAL(wp) :: dw1(3), dw2(3), deta(3), ddpsi(3), ddphi(3), dwg(3), domat(3), brk_g(3), brk_k(3)
    LOGICAL :: do_kappa
    INTEGER :: k, c, d

    inv_l0 = 1.0_wp/L0
    do_kappa = MAXVAL(ABS(mstress)) > 0.0_wp
    th1 = q(4:6); th2 = q(10:12)
    Lam1 = ctx%Lam1; Lam1T = TRANSPOSE(Lam1); psi = ctx%psi
    J1 = ctx%J1; J2 = ctx%J2; Jpsi_inv = ctx%Jpsi_inv
    n2 = 0.5_wp*(1.0_wp + xi); phi = n2*psi; Rphi = CD_Exp_SO3(phi)
    Rg = MATMUL(Lam1, Rphi); RgT = TRANSPOSE(Rg)
    t = (q(7:9) - q(1:3))/L0; dmat = MATMUL(RgT, t); hat_dmat = CD_Hat(dmat)
    Jphi = CD_Dexp_SO3(phi)
    Tphi = CD_T_Material(phi); Lam1Jphi = MATMUL(Lam1, Jphi); psi_l = psi*inv_l0
    nn = MATMUL(Lam0, nstress); mm = MATMUL(Lam0, mstress)
    ! per rotation DOF: p1/p2 select node-1/node-2 axis perturbations (k=1..3 -> node 1
    ! axes, k=4..6 -> node 2 axes); split index ranges keep the writes provably in bounds.
    p1 = 0.0_wp; p2 = 0.0_wp
    DO k = 1, 3
      p1(k, k) = 1.0_wp
      p2(k, k + 3) = 1.0_wp
    END DO
    ! first-order angular quantities per rotation DOF (mirrors analytic_b_operator);
    ! Jphi_dphi and Tdir_dphi are single-index, hoisted out of the (c,d) double loop.
    DO k = 1, 6
      w1(:, k) = MATMUL(J1, p1(:, k)); w2(:, k) = MATMUL(J2, p2(:, k))
      eta(:, k) = MATMUL(Lam1T, w2(:, k) - w1(:, k))
      dpsi(:, k) = MATMUL(Jpsi_inv, eta(:, k)); dphi(:, k) = n2*dpsi(:, k)
      Jphi_dphi(:, k) = MATMUL(Jphi, dphi(:, k))
      wg(:, k) = w1(:, k) + MATMUL(Lam1, Jphi_dphi(:, k))
      omat(:, k) = MATMUL(RgT, wg(:, k))
    END DO
    IF (do_kappa) THEN
      DO k = 1, 6
        Tdir_dphi(:, :, k) = CD_T_Material_Dir(phi, dphi(:, k))
      END DO
    END IF
    Kblk = 0.0_wp
    DO d = 1, 6
      dJ1 = CD_Dexp_Dir_SO3(th1, p1(:, d)); dJ2 = CD_Dexp_Dir_SO3(th2, p2(:, d))
      dJpi = -MATMUL(Jpsi_inv, MATMUL(CD_Dexp_Dir_SO3(psi, dpsi(:, d)), Jpsi_inv))
      dJphi = CD_Dexp_Dir_SO3(phi, dphi(:, d)); Lam1dJphi = MATMUL(Lam1, dJphi)
      hatw1d = CD_Hat(w1(:, d)); dLam1 = MATMUL(hatw1d, Lam1)
      ddmat = MATMUL(hat_dmat, omat(:, d))
      DO c = 1, 6
        ! shared second-order angular chain (Gamma and Kappa both consume ddpsi/ddphi)
        dw1 = MATMUL(dJ1, p1(:, c)); dw2 = MATMUL(dJ2, p2(:, c))
        deta = MATMUL(-MATMUL(Lam1T, hatw1d), w2(:, c) - w1(:, c)) + MATMUL(Lam1T, dw2 - dw1)
        ddpsi = MATMUL(dJpi, eta(:, c)) + MATMUL(Jpsi_inv, deta)
        ddphi = n2*ddpsi
        ! Gamma (axial/shear) second variation
        dwg = dw1 + MATMUL(dLam1, Jphi_dphi(:, c)) + MATMUL(Lam1dJphi, dphi(:, c)) &
              + MATMUL(Lam1Jphi, ddphi)
        domat = -MATMUL(CD_Hat(omat(:, d)), omat(:, c)) + MATMUL(RgT, dwg)
        brk_g = MATMUL(CD_Hat(ddmat), omat(:, c)) + MATMUL(hat_dmat, domat)
        Kblk(c, d) = DOT_PRODUCT(nn, brk_g)
        ! Kappa (bending/twist) second variation
        IF (do_kappa) THEN
          brk_k = MATMUL(CD_T_Material_Dir2(phi, dphi(:, c), dphi(:, d)) &
                         + CD_T_Material_Dir(phi, ddphi), psi_l) &
                  + MATMUL(Tdir_dphi(:, :, c), dpsi(:, d)*inv_l0) &
                  + MATMUL(Tdir_dphi(:, :, d), dpsi(:, c)*inv_l0) &
                  + MATMUL(Tphi, ddpsi*inv_l0)
          Kblk(c, d) = Kblk(c, d) + DOT_PRODUCT(mm, brk_k)
        END IF
      END DO
    END DO
  END SUBROUTINE analytic_rotation_geo

  PURE SUBROUTINE analytic_force_tangent_eval(ctx, q, ea, gas, ei, gj, Lam0, L0, reduced_shear, Kt)
    !! Assemble the closed-form 12x12 tangent: the translational rows/cols (material +
    !! geometric), the rotation-rotation MATERIAL block B^T C B, and the full rotation-
    !! rotation GEOMETRIC block -- the Gamma (axial/shear) second variation n . d2 Gamma/
    !! dtheta^2 and the kappa (moment) second variation m . d2 Kappa/dtheta^2. Matches the
    !! Dual2 AD oracle to the exact-block floor on the complete 12x12.
    TYPE(rot_cache_t), INTENT(IN) :: ctx
    REAL(wp), INTENT(IN) :: q(12), ea, gas, ei, gj, Lam0(3, 3), L0
    LOGICAL, INTENT(IN) :: reduced_shear
    REAL(wp), INTENT(OUT) :: Kt(12, 12)
    INTEGER, PARAMETER :: RIDX(6) = [4, 5, 6, 10, 11, 12]
    REAL(wp), PARAMETER :: ZERO3(3) = [0.0_wp, 0.0_wp, 0.0_wp]
    REAL(wp) :: G(3), K(3), Bg(3, 12), Bk(3, 12), Cg_ax(3, 3), Cg_sh(3, 3), Ck(3, 3)
    REAL(wp) :: Mrr(6, 6), Ggeo(6, 6), Kgg(6, 6), n_ax(3), n_sh(3), m_mo(3), jac
    INTEGER :: gp, i, j

    jac = 0.5_wp*L0
    Kt = 0.0_wp
    CALL analytic_translational_tangent_eval(ctx, q, ea, gas, Lam0, L0, reduced_shear, Kt)

    ! rotation-rotation MATERIAL block: B^T C B restricted to the rotation DOFs, with
    ! the same quadrature split the energy/force use (axial + bending/torsion at the
    ! two Gauss points; transverse shear reduced to xi=0 when reduced_shear).
    Cg_ax = 0.0_wp; Cg_ax(3, 3) = ea
    Ck = 0.0_wp; Ck(1, 1) = ei; Ck(2, 2) = ei; Ck(3, 3) = gj
    Cg_sh = 0.0_wp; Cg_sh(1, 1) = gas; Cg_sh(2, 2) = gas
    Mrr = 0.0_wp
    DO gp = 1, 2
      CALL analytic_b_operator(ctx, q, Lam0, L0, GAUSS2_XI(gp), G, K, Bg, Bk)
      Mrr = Mrr + GAUSS2_W(gp)*jac*(MATMUL(TRANSPOSE(Bg(:, RIDX)), MATMUL(Cg_ax, Bg(:, RIDX))) &
                                    + MATMUL(TRANSPOSE(Bk(:, RIDX)), MATMUL(Ck, Bk(:, RIDX))))
    END DO
    IF (reduced_shear) THEN
      CALL analytic_b_operator(ctx, q, Lam0, L0, 0.0_wp, G, K, Bg, Bk)
      Mrr = Mrr + 2.0_wp*jac*MATMUL(TRANSPOSE(Bg(:, RIDX)), MATMUL(Cg_sh, Bg(:, RIDX)))
    ELSE
      DO gp = 1, 2
        CALL analytic_b_operator(ctx, q, Lam0, L0, GAUSS2_XI(gp), G, K, Bg, Bk)
        Mrr = Mrr + GAUSS2_W(gp)*jac*MATMUL(TRANSPOSE(Bg(:, RIDX)), MATMUL(Cg_sh, Bg(:, RIDX)))
      END DO
    END IF
    ! rotation-rotation GEOMETRIC block. Gamma part: n . d2(Gamma)/dtheta^2, axial
    ! stress n3 = ea*Gamma3 at the two Gauss points and transverse-shear n1,n2 =
    ! gas*Gamma1,2 reduced to xi=0 (or full). Kappa part: m . d2(Kappa)/dtheta^2 with
    ! moment m = (ei*K1, ei*K2, gj*K3) at the two Gauss points -- the same split as
    ! B^T C B.
    Ggeo = 0.0_wp
    DO gp = 1, 2
      CALL cached_strains(ctx, q, Lam0, L0, GAUSS2_XI(gp), G, K)
      n_ax = [0.0_wp, 0.0_wp, ea*G(3)]
      m_mo = [ei*K(1), ei*K(2), gj*K(3)]
      CALL analytic_rotation_geo(ctx, q, Lam0, L0, GAUSS2_XI(gp), n_ax, m_mo, Kgg)
      Ggeo = Ggeo + GAUSS2_W(gp)*jac*Kgg
    END DO
    IF (reduced_shear) THEN
      CALL cached_strains(ctx, q, Lam0, L0, 0.0_wp, G, K)
      n_sh = [gas*G(1), gas*G(2), 0.0_wp]
      CALL analytic_rotation_geo(ctx, q, Lam0, L0, 0.0_wp, n_sh, ZERO3, Kgg)
      Ggeo = Ggeo + 2.0_wp*jac*Kgg
    ELSE
      DO gp = 1, 2
        CALL cached_strains(ctx, q, Lam0, L0, GAUSS2_XI(gp), G, K)
        n_sh = [gas*G(1), gas*G(2), 0.0_wp]
        CALL analytic_rotation_geo(ctx, q, Lam0, L0, GAUSS2_XI(gp), n_sh, ZERO3, Kgg)
        Ggeo = Ggeo + GAUSS2_W(gp)*jac*Kgg
      END DO
    END IF
    DO j = 1, 6
      DO i = 1, 6
        Kt(RIDX(i), RIDX(j)) = Kt(RIDX(i), RIDX(j)) + Mrr(i, j) + Ggeo(i, j)
      END DO
    END DO
  END SUBROUTINE analytic_force_tangent_eval

  PURE FUNCTION analytic_position_geometric_columns(ctx, Lam0, L0, xi, n) RESULT(Kgeo)
    !! Geometric dB/dx:n contribution for the six position columns. Only rows
    !! associated with nodal rotations are nonzero because translational B_r is
    !! constant in position.
    TYPE(rot_cache_t), INTENT(IN) :: ctx
    REAL(wp), INTENT(IN) :: Lam0(3, 3), L0, xi, n(3)
    REAL(wp) :: Kgeo(12, 6)
    INTEGER, PARAMETER :: TIDX(6) = [1, 2, 3, 7, 8, 9]
    REAL(wp) :: Rg(3, 3), omat_cols(3, 12), A0(3, 3), dr(3), ddmat(3), dBg(3)
    INTEGER :: pc, row, axis

    Kgeo = 0.0_wp
    A0 = TRANSPOSE(Lam0)
    CALL analytic_rotation_column_omat(ctx, xi, Rg, omat_cols)
    DO pc = 1, SIZE(TIDX)
      dr = 0.0_wp
      IF (pc <= 3) THEN
        axis = pc
        dr(axis) = -1.0_wp/L0
      ELSE
        axis = pc - 3
        dr(axis) = 1.0_wp/L0
      END IF
      ddmat = MATMUL(TRANSPOSE(Rg), dr)
      DO row = 4, 6
        dBg = MATMUL(A0, MATMUL(CD_Hat(ddmat), omat_cols(:, row)))
        Kgeo(row, pc) = DOT_PRODUCT(dBg, n)
      END DO
      DO row = 10, 12
        dBg = MATMUL(A0, MATMUL(CD_Hat(ddmat), omat_cols(:, row)))
        Kgeo(row, pc) = DOT_PRODUCT(dBg, n)
      END DO
    END DO
  END FUNCTION analytic_position_geometric_columns

  PURE SUBROUTINE analytic_rotation_column_omat(ctx, xi, Rg, omat_cols)
    !! Angular-rate vectors omat = R_g^T delta-omega_g used by the analytical
    !! B-operator for each rotational column. The xi-independent Lam1/Lam2/psi/J1/
    !! J2/Jpsi_inv come from the cache; only the xi-dependent phi/Rphi/Rg/Jphi are
    !! computed here.
    TYPE(rot_cache_t), INTENT(IN) :: ctx
    REAL(wp), INTENT(IN) :: xi
    REAL(wp), INTENT(OUT) :: Rg(3, 3), omat_cols(3, 12)
    REAL(wp) :: phi(3), Rphi(3, 3), n2, Jphi(3, 3)
    REAL(wp) :: dq(3), w1(3), w2(3), eta(3), dpsi(3), dphi(3), wg(3)
    INTEGER :: col, idx

    n2 = 0.5_wp*(1.0_wp + xi)
    phi = n2*ctx%psi
    Rphi = CD_Exp_SO3(phi)
    Rg = MATMUL(ctx%Lam1, Rphi)
    Jphi = CD_Dexp_SO3(phi)
    omat_cols = 0.0_wp
    DO col = 4, 12
      IF (col > 6 .AND. col < 10) CYCLE
      w1 = 0.0_wp
      w2 = 0.0_wp
      SELECT CASE (col)
      CASE (4:6)
        idx = col - 3
        dq = 0.0_wp; dq(idx) = 1.0_wp
        w1 = MATMUL(ctx%J1, dq)
      CASE (10:12)
        idx = col - 9
        dq = 0.0_wp; dq(idx) = 1.0_wp
        w2 = MATMUL(ctx%J2, dq)
      END SELECT
      eta = MATMUL(TRANSPOSE(ctx%Lam1), w2 - w1)
      dpsi = MATMUL(ctx%Jpsi_inv, eta)
      dphi = n2*dpsi
      wg = w1 + MATMUL(ctx%Lam1, MATMUL(Jphi, dphi))
      omat_cols(:, col) = MATMUL(TRANSPOSE(Rg), wg)
    END DO
  END SUBROUTINE analytic_rotation_column_omat

  PURE SUBROUTINE analytic_b_operator(ctx, q, Lam0, L0, xi, Gamma, Kappa, Bg, Bk)
    !! Material-form strain-displacement operators for the Jelenic-Crisfield
    !! interpolation, differentiated with respect to the additive rotation-vector
    !! DOFs used by the solver and the AD reference. The xi-independent Lam1/Lam2/
    !! psi/J1/J2/Jpsi_inv come from the cache; only phi/Rphi/Rg/Tphi/Jphi are
    !! xi-dependent and computed here.
    TYPE(rot_cache_t), INTENT(IN) :: ctx
    REAL(wp), INTENT(IN) :: q(12), Lam0(3, 3), L0, xi
    REAL(wp), INTENT(OUT) :: Gamma(3), Kappa(3), Bg(3, 12), Bk(3, 12)
    REAL(wp) :: r1(3), r2(3), Lam1(3, 3), phi(3), Rphi(3, 3), Rg(3, 3), t(3), dmat(3), inv_l0, n2
    REAL(wp) :: psi(3), A0(3, 3), J1(3, 3), J2(3, 3), Jpsi_inv(3, 3), Jphi(3, 3), Tphi(3, 3)
    REAL(wp) :: dq(3), dr(3), w1(3), w2(3), eta(3), dpsi(3), dphi(3), wg(3), omat(3)
    REAL(wp) :: dpos(3), dgamma(3), dkappa(3), dTmat(3, 3)
    INTEGER :: col, idx
    r1 = q(1:3); r2 = q(7:9)
    inv_l0 = 1.0_wp/L0
    n2 = 0.5_wp*(1.0_wp + xi)
    Lam1 = ctx%Lam1
    psi = ctx%psi
    J1 = ctx%J1
    J2 = ctx%J2
    Jpsi_inv = ctx%Jpsi_inv
    phi = n2*psi
    Rphi = CD_Exp_SO3(phi)
    Rg = MATMUL(Lam1, Rphi)
    t = (r2 - r1)*inv_l0
    A0 = TRANSPOSE(Lam0)
    dmat = MATMUL(TRANSPOSE(Rg), t)
    Gamma = MATMUL(A0, dmat) - E3
    Tphi = CD_T_Material(phi)
    Kappa = MATMUL(A0, MATMUL(Tphi, psi*inv_l0))
    Jphi = CD_Dexp_SO3(phi)
    Bg = 0.0_wp
    Bk = 0.0_wp
    DO col = 1, 12
      dr = 0.0_wp
      w1 = 0.0_wp
      w2 = 0.0_wp
      SELECT CASE (col)
      CASE (1:3)
        idx = col
        dr(idx) = -inv_l0
      CASE (4:6)
        idx = col - 3
        dq = 0.0_wp; dq(idx) = 1.0_wp
        w1 = MATMUL(J1, dq)
      CASE (7:9)
        idx = col - 6
        dr(idx) = inv_l0
      CASE (10:12)
        idx = col - 9
        dq = 0.0_wp; dq(idx) = 1.0_wp
        w2 = MATMUL(J2, dq)
      END SELECT
      dpos = dr
      eta = MATMUL(TRANSPOSE(Lam1), w2 - w1)
      dpsi = MATMUL(Jpsi_inv, eta)
      dphi = n2*dpsi
      wg = w1 + MATMUL(Lam1, MATMUL(Jphi, dphi))
      omat = MATMUL(TRANSPOSE(Rg), wg)
      dgamma = MATMUL(A0, MATMUL(TRANSPOSE(Rg), dpos) + MATMUL(CD_Hat(dmat), omat))
      dTmat = CD_T_Material_Dir(phi, dphi)
      dkappa = MATMUL(A0, MATMUL(dTmat, psi*inv_l0) + MATMUL(Tphi, dpsi*inv_l0))
      Bg(:, col) = dgamma
      Bk(:, col) = dkappa
    END DO
  END SUBROUTINE analytic_b_operator

  ! =========================================================================
  ! Differentiated kinematics. Dual1 is the residual-only force path; Dual2 is
  ! the tangent path. Both mirror CD_Cosserat_Strains exactly, with the relative-
  ! rotation log in its atan2 form (d_log_so3).
  ! =========================================================================

  SUBROUTINE validate_force_inputs(q, ea, gas, ei, gj, Lam0, L0, ErrStat, ErrMsg)
    !! Shared fail-closed validation for both force-only and force+tangent AD
    !! element paths. The AD pass divides by L0 and assumes a unique rotation-vector
    !! chart; reject invalid states before any NaN/Inf can leak into outputs.
    REAL(wp), INTENT(IN) :: q(12), ea, gas, ei, gj, Lam0(3, 3), L0
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    ErrStat = 0
    ErrMsg = ''
    IF (.NOT. (ea > 0.0_wp .AND. gas > 0.0_wp .AND. ei > 0.0_wp .AND. gj > 0.0_wp) .OR. &
        .NOT. (CD_Is_Finite(ea) .AND. CD_Is_Finite(gas) .AND. CD_Is_Finite(ei) &
               .AND. CD_Is_Finite(gj))) THEN
      ErrStat = 1; ErrMsg = 'CD_Cosserat element: EA/GAs/EI/GJ must be finite and positive'
      RETURN
    END IF
    IF (.NOT. (L0 > 0.0_wp) .OR. .NOT. CD_Is_Finite(L0)) THEN
      ErrStat = 1; ErrMsg = 'CD_Cosserat element: L0 must be finite and positive'
      RETURN
    END IF
    IF (.NOT. CD_All_Finite(q) .OR. .NOT. CD_All_Finite(Lam0)) THEN
      ErrStat = 1; ErrMsg = 'CD_Cosserat element: q / Lam0 contain non-finite values'
      RETURN
    END IF
    ! rotation-state contract (|theta| < pi chart + non-log-singular relative
    ! rotation) -- the single shared validator, so the force-only, force+tangent,
    ! and energy paths all enforce the identical element-domain contract
    CALL CD_Cosserat_Validate_Rotation_State(q, ErrStat, ErrMsg)
    IF (ErrStat /= 0) ErrMsg = 'CD_Cosserat element: '//TRIM(ErrMsg)
  END SUBROUTINE validate_force_inputs

  PURE SUBROUTINE d1_strains(qd, Lam0, L0, xi, Gamma, Kappa)
    TYPE(Dual1), INTENT(IN) :: qd(12)
    REAL(wp), INTENT(IN) :: Lam0(3, 3), L0, xi
    TYPE(Dual1), INTENT(OUT) :: Gamma(3), Kappa(3)
    TYPE(Dual1) :: Lam1(3, 3), Lam2(3, 3), Lam_g(3, 3)
    TYPE(Dual1) :: theta_rel_2(3), theta_rel(3), tangent(3), dthds(3), tmp(3)
    REAL(wp) :: n2, inv_l0
    INTEGER :: k
    n2 = 0.5_wp*(1.0_wp + xi)
    inv_l0 = 1.0_wp/L0
    Lam1 = d1_exp_so3(qd(4:6))
    Lam2 = d1_exp_so3(qd(10:12))
    theta_rel_2 = d1_log_so3(d1_matmul(d1_transpose(Lam1), Lam2))
    DO k = 1, 3
      theta_rel(k) = n2*theta_rel_2(k)
      tangent(k) = (qd(6 + k) - qd(k))*inv_l0
      dthds(k) = theta_rel_2(k)*inv_l0
    END DO
    Lam_g = d1_matmul(Lam1, d1_exp_so3(theta_rel))
    tmp = d1_matvec(d1_transpose(Lam_g), tangent)
    Gamma = d1_matvec_r(TRANSPOSE(Lam0), tmp)
    Gamma(3) = Gamma(3) - 1.0_wp
    tmp = d1_matvec(d1_t_material(theta_rel), dthds)
    Kappa = d1_matvec_r(TRANSPOSE(Lam0), tmp)
  END SUBROUTINE d1_strains

  PURE FUNCTION d1_hat(v) RESULT(K)
    TYPE(Dual1), INTENT(IN) :: v(3)
    TYPE(Dual1) :: K(3, 3)
    K(1, 1) = AD1_Const(0.0_wp); K(1, 2) = AD1_Const(0.0_wp) - v(3); K(1, 3) = v(2)
    K(2, 1) = v(3); K(2, 2) = AD1_Const(0.0_wp); K(2, 3) = AD1_Const(0.0_wp) - v(1)
    K(3, 1) = AD1_Const(0.0_wp) - v(2); K(3, 2) = v(1); K(3, 3) = AD1_Const(0.0_wp)
  END FUNCTION d1_hat

  PURE FUNCTION d1_transpose(A) RESULT(B)
    TYPE(Dual1), INTENT(IN) :: A(3, 3)
    TYPE(Dual1) :: B(3, 3)
    INTEGER :: i, j
    DO j = 1, 3
      DO i = 1, 3
        B(i, j) = A(j, i)
      END DO
    END DO
  END FUNCTION d1_transpose

  PURE FUNCTION d1_matmul(A, B) RESULT(C)
    TYPE(Dual1), INTENT(IN) :: A(3, 3), B(3, 3)
    TYPE(Dual1) :: C(3, 3), acc
    INTEGER :: i, j, k
    DO j = 1, 3
      DO i = 1, 3
        acc = A(i, 1)*B(1, j)
        DO k = 2, 3
          acc = acc + A(i, k)*B(k, j)
        END DO
        C(i, j) = acc
      END DO
    END DO
  END FUNCTION d1_matmul

  PURE FUNCTION d1_matvec(A, x) RESULT(y)
    TYPE(Dual1), INTENT(IN) :: A(3, 3), x(3)
    TYPE(Dual1) :: y(3), acc
    INTEGER :: i, k
    DO i = 1, 3
      acc = A(i, 1)*x(1)
      DO k = 2, 3
        acc = acc + A(i, k)*x(k)
      END DO
      y(i) = acc
    END DO
  END FUNCTION d1_matvec

  PURE FUNCTION d1_matvec_r(A, x) RESULT(y)
    REAL(wp), INTENT(IN) :: A(3, 3)
    TYPE(Dual1), INTENT(IN) :: x(3)
    TYPE(Dual1) :: y(3), acc
    INTEGER :: i, k
    DO i = 1, 3
      acc = A(i, 1)*x(1)
      DO k = 2, 3
        acc = acc + A(i, k)*x(k)
      END DO
      y(i) = acc
    END DO
  END FUNCTION d1_matvec_r

  PURE FUNCTION d1_scale(s, A) RESULT(C)
    TYPE(Dual1), INTENT(IN) :: s, A(3, 3)
    TYPE(Dual1) :: C(3, 3)
    INTEGER :: i, j
    DO j = 1, 3
      DO i = 1, 3
        C(i, j) = s*A(i, j)
      END DO
    END DO
  END FUNCTION d1_scale

  PURE FUNCTION d1_exp_so3(theta) RESULT(R)
    TYPE(Dual1), INTENT(IN) :: theta(3)
    TYPE(Dual1) :: R(3, 3), Kmat(3, 3), K2(3, 3), th2, th, a, b
    INTEGER :: i
    th2 = theta(1)*theta(1) + theta(2)*theta(2) + theta(3)*theta(3)
    Kmat = d1_hat(theta)
    K2 = d1_matmul(Kmat, Kmat)
    IF (th2%v < SMALL_ANGLE_SQ) THEN
      a = AD1_Const(1.0_wp) - th2/6.0_wp
      b = AD1_Const(0.5_wp) - th2/24.0_wp
    ELSE
      th = AD1_Sqrt(th2)
      a = AD1_Sin(th)/th
      b = (AD1_Const(1.0_wp) - AD1_Cos(th))/th2
    END IF
    R = d1_add(d1_scale(a, Kmat), d1_scale(b, K2))
    DO i = 1, 3
      R(i, i) = R(i, i) + 1.0_wp
    END DO
  END FUNCTION d1_exp_so3

  PURE FUNCTION d1_t_material(theta) RESULT(T)
    TYPE(Dual1), INTENT(IN) :: theta(3)
    TYPE(Dual1) :: T(3, 3), Kmat(3, 3), K2(3, 3), th2, th, c1, c2
    INTEGER :: i
    th2 = theta(1)*theta(1) + theta(2)*theta(2) + theta(3)*theta(3)
    Kmat = d1_hat(theta)
    K2 = d1_matmul(Kmat, Kmat)
    IF (th2%v < SMALL_ANGLE_SQ) THEN
      c1 = AD1_Const(0.5_wp) - th2/24.0_wp
      c2 = AD1_Const(1.0_wp/6.0_wp) - th2/120.0_wp
    ELSE
      th = AD1_Sqrt(th2)
      c1 = (AD1_Const(1.0_wp) - AD1_Cos(th))/th2
      c2 = (th - AD1_Sin(th))/(th2*th)
    END IF
    T = d1_add(d1_scale(AD1_Const(0.0_wp) - c1, Kmat), d1_scale(c2, K2))
    DO i = 1, 3
      T(i, i) = T(i, i) + 1.0_wp
    END DO
  END FUNCTION d1_t_material

  PURE FUNCTION d1_log_so3(R) RESULT(theta)
    TYPE(Dual1), INTENT(IN) :: R(3, 3)
    TYPE(Dual1) :: theta(3), v(3), vns, trace, factor, safe
    INTEGER :: k
    v(1) = R(3, 2) - R(2, 3)
    v(2) = R(1, 3) - R(3, 1)
    v(3) = R(2, 1) - R(1, 2)
    vns = v(1)*v(1) + v(2)*v(2) + v(3)*v(3)
    trace = R(1, 1) + R(2, 2) + R(3, 3)
    IF (vns%v < SMALL_ANGLE_SQ .AND. trace%v > 1.0_wp) THEN
      factor = AD1_Const(0.5_wp) + vns/48.0_wp
    ELSE
      safe = AD1_Sqrt(vns)
      factor = AD1_Atan2(safe, trace - 1.0_wp)/safe
    END IF
    DO k = 1, 3
      theta(k) = factor*v(k)
    END DO
  END FUNCTION d1_log_so3

  PURE FUNCTION d1_add(A, B) RESULT(C)
    TYPE(Dual1), INTENT(IN) :: A(3, 3), B(3, 3)
    TYPE(Dual1) :: C(3, 3)
    INTEGER :: i, j
    DO j = 1, 3
      DO i = 1, 3
        C(i, j) = A(i, j) + B(i, j)
      END DO
    END DO
  END FUNCTION d1_add

  PURE SUBROUTINE d_strains(qd, Lam0, L0, xi, Gamma, Kappa)
    TYPE(Dual2), INTENT(IN) :: qd(12)
    REAL(wp), INTENT(IN) :: Lam0(3, 3), L0, xi
    TYPE(Dual2), INTENT(OUT) :: Gamma(3), Kappa(3)
    TYPE(Dual2) :: Lam1(3, 3), Lam2(3, 3), Lam_g(3, 3)
    TYPE(Dual2) :: theta_rel_2(3), theta_rel(3), tangent(3), dthds(3), tmp(3)
    REAL(wp) :: n2, inv_l0
    INTEGER :: k
    n2 = 0.5_wp*(1.0_wp + xi)
    inv_l0 = 1.0_wp/L0
    Lam1 = d_exp_so3(qd(4:6))
    Lam2 = d_exp_so3(qd(10:12))
    theta_rel_2 = d_log_so3(d_matmul(d_transpose(Lam1), Lam2))
    DO k = 1, 3
      theta_rel(k) = n2*theta_rel_2(k)
      tangent(k) = (qd(6 + k) - qd(k))*inv_l0
      dthds(k) = theta_rel_2(k)*inv_l0
    END DO
    Lam_g = d_matmul(Lam1, d_exp_so3(theta_rel))
    tmp = d_matvec(d_transpose(Lam_g), tangent)
    Gamma = d_matvec_r(TRANSPOSE(Lam0), tmp)
    Gamma(3) = Gamma(3) - 1.0_wp
    tmp = d_matvec(d_t_material(theta_rel), dthds)
    Kappa = d_matvec_r(TRANSPOSE(Lam0), tmp)
  END SUBROUTINE d_strains

  PURE FUNCTION d_hat(v) RESULT(K)
    TYPE(Dual2), INTENT(IN) :: v(3)
    TYPE(Dual2) :: K(3, 3)
    K(1, 1) = AD_Const(0.0_wp); K(1, 2) = AD_Const(0.0_wp) - v(3); K(1, 3) = v(2)
    K(2, 1) = v(3); K(2, 2) = AD_Const(0.0_wp); K(2, 3) = AD_Const(0.0_wp) - v(1)
    K(3, 1) = AD_Const(0.0_wp) - v(2); K(3, 2) = v(1); K(3, 3) = AD_Const(0.0_wp)
  END FUNCTION d_hat

  PURE FUNCTION d_transpose(A) RESULT(B)
    TYPE(Dual2), INTENT(IN) :: A(3, 3)
    TYPE(Dual2) :: B(3, 3)
    INTEGER :: i, j
    DO j = 1, 3
      DO i = 1, 3
        B(i, j) = A(j, i)
      END DO
    END DO
  END FUNCTION d_transpose

  PURE FUNCTION d_matmul(A, B) RESULT(C)
    TYPE(Dual2), INTENT(IN) :: A(3, 3), B(3, 3)
    TYPE(Dual2) :: C(3, 3), acc
    INTEGER :: i, j, k
    DO j = 1, 3
      DO i = 1, 3
        acc = A(i, 1)*B(1, j)
        DO k = 2, 3
          acc = acc + A(i, k)*B(k, j)
        END DO
        C(i, j) = acc
      END DO
    END DO
  END FUNCTION d_matmul

  PURE FUNCTION d_matvec(A, x) RESULT(y)
    TYPE(Dual2), INTENT(IN) :: A(3, 3), x(3)
    TYPE(Dual2) :: y(3), acc
    INTEGER :: i, k
    DO i = 1, 3
      acc = A(i, 1)*x(1)
      DO k = 2, 3
        acc = acc + A(i, k)*x(k)
      END DO
      y(i) = acc
    END DO
  END FUNCTION d_matvec

  PURE FUNCTION d_matvec_r(A, x) RESULT(y)
    !! real 3x3 matrix times a Dual2 3-vector.
    REAL(wp), INTENT(IN) :: A(3, 3)
    TYPE(Dual2), INTENT(IN) :: x(3)
    TYPE(Dual2) :: y(3), acc
    INTEGER :: i, k
    DO i = 1, 3
      acc = A(i, 1)*x(1)
      DO k = 2, 3
        acc = acc + A(i, k)*x(k)
      END DO
      y(i) = acc
    END DO
  END FUNCTION d_matvec_r

  PURE FUNCTION d_scale(s, A) RESULT(C)
    !! Dual2 scalar times a Dual2 3x3 matrix.
    TYPE(Dual2), INTENT(IN) :: s, A(3, 3)
    TYPE(Dual2) :: C(3, 3)
    INTEGER :: i, j
    DO j = 1, 3
      DO i = 1, 3
        C(i, j) = s*A(i, j)
      END DO
    END DO
  END FUNCTION d_scale

  PURE FUNCTION d_exp_so3(theta) RESULT(R)
    TYPE(Dual2), INTENT(IN) :: theta(3)
    TYPE(Dual2) :: R(3, 3), Kmat(3, 3), K2(3, 3), th2, th, a, b
    INTEGER :: i
    th2 = theta(1)*theta(1) + theta(2)*theta(2) + theta(3)*theta(3)
    Kmat = d_hat(theta)
    K2 = d_matmul(Kmat, Kmat)
    IF (th2%v < SMALL_ANGLE_SQ) THEN
      a = AD_Const(1.0_wp) - th2/6.0_wp
      b = AD_Const(0.5_wp) - th2/24.0_wp
    ELSE
      th = AD_Sqrt(th2)
      a = AD_Sin(th)/th
      b = (AD_Const(1.0_wp) - AD_Cos(th))/th2
    END IF
    R = d_add(d_scale(a, Kmat), d_scale(b, K2))
    DO i = 1, 3
      R(i, i) = R(i, i) + 1.0_wp
    END DO
  END FUNCTION d_exp_so3

  PURE FUNCTION d_t_material(theta) RESULT(T)
    TYPE(Dual2), INTENT(IN) :: theta(3)
    TYPE(Dual2) :: T(3, 3), Kmat(3, 3), K2(3, 3), th2, th, c1, c2
    INTEGER :: i
    th2 = theta(1)*theta(1) + theta(2)*theta(2) + theta(3)*theta(3)
    Kmat = d_hat(theta)
    K2 = d_matmul(Kmat, Kmat)
    IF (th2%v < SMALL_ANGLE_SQ) THEN
      c1 = AD_Const(0.5_wp) - th2/24.0_wp
      c2 = AD_Const(1.0_wp/6.0_wp) - th2/120.0_wp
    ELSE
      th = AD_Sqrt(th2)
      c1 = (AD_Const(1.0_wp) - AD_Cos(th))/th2
      c2 = (th - AD_Sin(th))/(th2*th)
    END IF
    T = d_add(d_scale(AD_Const(0.0_wp) - c1, Kmat), d_scale(c2, K2))
    DO i = 1, 3
      T(i, i) = T(i, i) + 1.0_wp
    END DO
  END FUNCTION d_t_material

  PURE FUNCTION d_log_so3(R) RESULT(theta)
    !! Inverse exponential in its atan2 form:
    !!   v       = axial(R - R^T)
    !!   factor  = atan2(sqrt(|v|^2), trace-1) / sqrt(|v|^2)   (regular)
    !!   factor  = 1/2 + |v|^2/48                              (small-angle)
    !!   theta   = factor * v
    !! The small-angle Taylor form is selected only near the identity (trace > 1);
    !! near pi the regular atan2 branch carries the correct magnitude. The
    !! genuinely singular near-pi case (where the log map fails) is
    !! rejected up front by CD_Cosserat_Force_Tangent, so this map is only
    !! evaluated for relative rotations safely below the chart boundary.
    TYPE(Dual2), INTENT(IN) :: R(3, 3)
    TYPE(Dual2) :: theta(3), v(3), vns, trace, factor, safe
    INTEGER :: k
    v(1) = R(3, 2) - R(2, 3)
    v(2) = R(1, 3) - R(3, 1)
    v(3) = R(2, 1) - R(1, 2)
    vns = v(1)*v(1) + v(2)*v(2) + v(3)*v(3)
    trace = R(1, 1) + R(2, 2) + R(3, 3)
    ! The small-angle Taylor branch is valid only near the IDENTITY (trace ~ 3).
    ! Near pi the skew vector v is ALSO tiny (sin(pi)=0), so guarding on |v| alone
    ! would wrongly select the Taylor form and return theta ~ v/2 ~ 0 for a 180
    ! deg rotation; the trace > 1 (cos_phi > 0) guard restricts Taylor to the
    ! near-identity regime and routes near-pi to the regular atan2 branch (which
    ! carries the correct magnitude ~pi). CD_Cosserat_Force_Tangent rejects the
    ! genuinely singular near-pi case up front, so the regular branch is only ever
    ! evaluated safely away from the exact singularity.
    IF (vns%v < SMALL_ANGLE_SQ .AND. trace%v > 1.0_wp) THEN
      factor = AD_Const(0.5_wp) + vns/48.0_wp
    ELSE
      safe = AD_Sqrt(vns)
      factor = AD_Atan2(safe, trace - 1.0_wp)/safe
    END IF
    DO k = 1, 3
      theta(k) = factor*v(k)
    END DO
  END FUNCTION d_log_so3

  PURE FUNCTION d_add(A, B) RESULT(C)
    TYPE(Dual2), INTENT(IN) :: A(3, 3), B(3, 3)
    TYPE(Dual2) :: C(3, 3)
    INTEGER :: i, j
    DO j = 1, 3
      DO i = 1, 3
        C(i, j) = A(i, j) + B(i, j)
      END DO
    END DO
  END FUNCTION d_add

END MODULE CableDyn_Cosserat
