! File: src/CableDyn_HermiteCable.f90
! SPDX-License-Identifier: Apache-2.0
! Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
MODULE CableDyn_HermiteCable
  !! Cubic-Hermite bending-cable element for finite-EI power-cable and lazy-wave lines.
  !!
  !! This is a POSITION + MATERIAL-TANGENT element: each node carries
  !!   [r(3), m(3)],   m = dr/ds  (dimensional material tangent handle),
  !! so an element has 12 DOFs and the centreline r(s) is the cubic-Hermite
  !! interpolant of the two nodal (r, m) pairs. There are NO rotation DOFs, hence
  !! no |theta| < pi rotation chart and no rotational-vs-axial conditioning split --
  !! the rotation-chart, small-EI conditioning and linear-Lagrange limits of a
  !! two-node Cosserat element do not arise.
  !!
  !! The stored strain energy is the inextensible-bending + axial form
  !!   U = integral_0^L ( 1/2 EA eps^2 + 1/2 EI kappa^2 ) ds,
  !! with the parametrisation-invariant measures
  !!   eps    = |dr/ds| - 1                          (axial stretch)
  !!   kappa  = |r_s x r_ss| / |r_s|^3               (centreline curvature).
  !! The internal force fint = dU/dq and tangent Kt = d^2U/dq^2 are formed in
  !! CLOSED FORM. Per Gauss point the energy density is f(a, b) with a = dr/ds and
  !! b = d^2r/ds^2, each a constant-coefficient linear map of the 12 element DOFs; the
  !! 6-vector gradient and 6x6 Hessian of f in (a, b) are written analytically and
  !! chained to the 12 DOFs by those constant maps. Kt is symmetric (enforced to
  !! round-off) and reproduces the finite difference of fint. The closed form agrees with
  !! second-order automatic differentiation of the same strain energy to round-off, at a
  !! fraction of the cost.
  !!
  !! Reference for the Hermite bending element: standard C1 cubic-Hermite beam
  !! interpolation; the curvature energy uses the exact large-deflection curvature
  !! measure (not the linearised second-derivative approximation), evaluated per Gauss
  !! point on the deformed centreline.
  USE CableDyn_Precision, ONLY: wp, CD_ZERO, CD_ONE, CD_All_Finite, CD_Is_Finite
  IMPLICIT NONE
  PRIVATE

  PUBLIC :: CD_HermiteCable_Element
  PUBLIC :: CD_HermiteCable_Curvature
  PUBLIC :: CD_HermiteCable_Peak_Curvature
  PUBLIC :: CD_HermiteCable_Axial_Resultant
  PUBLIC :: CD_HermiteCable_Axial_Resultant_Range
  PUBLIC :: CD_HermiteCable_Axial_Strain_Lower_Bound
  PUBLIC :: CD_HermiteCable_Mass
  PUBLIC :: CD_HermiteCable_Shapes
  PUBLIC :: CD_HermiteCable_Gauss_Rule
  PUBLIC :: CD_HermiteCable_Dry_Buoyancy
  INTEGER, PARAMETER, PUBLIC :: CD_HCABLE_OK = 0, CD_HCABLE_BADINPUT = 1

  INTEGER, PARAMETER :: NG = 4                       !! default Gauss points per element
  INTEGER, PARAMETER :: MAX_NG = 6                   !! largest supported research quadrature
  REAL(wp), PARAMETER :: GEOM_TOL = 1.0e-12_wp

CONTAINS

  SUBROUTINE CD_HermiteCable_Element(qr, L, EA, EI, Eout, fint, Kt, ErrStat, ErrMsg, symmetric_half, tangent_only, &
                                     axial_quadrature_order, bending_quadrature_order)
    !! Public element evaluation with independently selectable axial and bending
    !! Gauss orders.  Four-point integration remains the production default.  Equal
    !! orders use one combined pass.  Unequal orders sum two variationally consistent
    !! passes, which provides selective integration for locking and oscillation studies.
    REAL(wp), INTENT(IN) :: qr(12), L, EA, EI
    REAL(wp), INTENT(OUT) :: Eout, fint(12)
    REAL(wp), INTENT(OUT), OPTIONAL :: Kt(12, 12)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    LOGICAL, INTENT(IN), OPTIONAL :: symmetric_half
    LOGICAL, INTENT(IN), OPTIONAL :: tangent_only
    INTEGER, INTENT(IN), OPTIONAL :: axial_quadrature_order, bending_quadrature_order

    REAL(wp) :: energy_axial, energy_bending, force_axial(12), force_bending(12)
    REAL(wp) :: tangent_axial(12, 12), tangent_bending(12, 12)
    INTEGER :: axial_order, bending_order, es
    CHARACTER(200) :: em
    LOGICAL :: half_tangent, only_tangent

    axial_order = NG
    bending_order = NG
    half_tangent = .FALSE.
    only_tangent = .FALSE.
    IF (PRESENT(axial_quadrature_order)) axial_order = axial_quadrature_order
    IF (PRESENT(bending_quadrature_order)) bending_order = bending_quadrature_order
    IF (PRESENT(symmetric_half)) half_tangent = symmetric_half
    IF (PRESENT(tangent_only)) only_tangent = tangent_only
    IF (axial_order < 1 .OR. axial_order > MAX_NG .OR. &
        bending_order < 1 .OR. bending_order > MAX_NG) THEN
      ErrStat = CD_HCABLE_BADINPUT
      ErrMsg = 'CD_HermiteCable_Element: quadrature orders must lie in [1,6]'
      Eout = CD_ZERO
      fint = CD_ZERO
      IF (PRESENT(Kt)) Kt = CD_ZERO
      RETURN
    END IF

    IF (axial_order == bending_order .OR. ABS(EA) <= CD_ZERO .OR. ABS(EI) <= CD_ZERO) THEN
      IF (ABS(EA) <= CD_ZERO) axial_order = bending_order
      IF (ABS(EI) <= CD_ZERO) bending_order = axial_order
      IF (PRESENT(Kt)) THEN
        CALL hermite_element_integrated(qr, L, EA, EI, axial_order, Eout, fint, Kt, ErrStat, ErrMsg, &
                                        half_tangent, only_tangent)
      ELSE
        CALL hermite_element_integrated(qr, L, EA, EI, axial_order, Eout, fint, ErrStat=ErrStat, &
                                        ErrMsg=ErrMsg, symmetric_half=half_tangent, tangent_only=only_tangent)
      END IF
      RETURN
    END IF

    IF (PRESENT(Kt)) THEN
      CALL hermite_element_integrated(qr, L, EA, CD_ZERO, axial_order, energy_axial, force_axial, tangent_axial, &
                                      es, em, half_tangent, only_tangent)
      IF (es /= CD_HCABLE_OK) THEN
        ErrStat = es; ErrMsg = em; Eout = CD_ZERO; fint = CD_ZERO; Kt = CD_ZERO; RETURN
      END IF
      CALL hermite_element_integrated(qr, L, CD_ZERO, EI, bending_order, energy_bending, force_bending, &
                                      tangent_bending, es, em, half_tangent, only_tangent)
      IF (es /= CD_HCABLE_OK) THEN
        ErrStat = es; ErrMsg = em; Eout = CD_ZERO; fint = CD_ZERO; Kt = CD_ZERO; RETURN
      END IF
      Kt = tangent_axial + tangent_bending
    ELSE
      CALL hermite_element_integrated(qr, L, EA, CD_ZERO, axial_order, energy_axial, force_axial, &
                                      ErrStat=es, ErrMsg=em, symmetric_half=half_tangent, &
                                      tangent_only=only_tangent)
      IF (es /= CD_HCABLE_OK) THEN
        ErrStat = es; ErrMsg = em; Eout = CD_ZERO; fint = CD_ZERO; RETURN
      END IF
      CALL hermite_element_integrated(qr, L, CD_ZERO, EI, bending_order, energy_bending, force_bending, &
                                      ErrStat=es, ErrMsg=em, symmetric_half=half_tangent, &
                                      tangent_only=only_tangent)
      IF (es /= CD_HCABLE_OK) THEN
        ErrStat = es; ErrMsg = em; Eout = CD_ZERO; fint = CD_ZERO; RETURN
      END IF
    END IF
    Eout = energy_axial + energy_bending
    fint = force_axial + force_bending
    ErrStat = CD_HCABLE_OK
    ErrMsg = ''
  END SUBROUTINE CD_HermiteCable_Element

  SUBROUTINE hermite_element_integrated(qr, L, EA, EI, quadrature_order, Eout, fint, Kt, ErrStat, ErrMsg, &
                                        symmetric_half, tangent_only)
    !! Element strain energy, internal force (dU/dq) and tangent (d^2U/dq^2) for the
    !! cubic-Hermite bending-cable element, via closed-form analytical differentiation
    !! of the strain energy. Computes the exact gradient and Hessian (agreeing with
    !! second-order AD to floating-point round-off), about an order of magnitude faster
    !! per element (the FD gate in test_hermite_cable pins
    !! both fint and Kt to central differences of the energy across strain regimes).
    !!
    !! Kt is OPTIONAL: a residual-only evaluation (a dynamic line-search trial, which
    !! never solves with a tangent) omits it and skips the Hessian blocks and the 12-DOF
    !! chain -- the dominant share of the element cost. Energy and fint are unchanged.
    !! A tangent-only caller may set tangent_only=.TRUE. to skip the energy/force
    !! accumulation; Kt is unchanged and the unused Eout/fint outputs are defined as zero.
    !!
    !! qr = [r1(3), m1(3), r2(3), m2(3)] : nodal positions and material tangents.
    !! L                                 : element unstretched (reference) length > 0.
    !! EA, EI                            : axial and bending stiffness (>= 0).
    REAL(wp), INTENT(IN) :: qr(12), L, EA, EI
    INTEGER, INTENT(IN) :: quadrature_order
    REAL(wp), INTENT(OUT) :: Eout, fint(12)
    REAL(wp), INTENT(OUT), OPTIONAL :: Kt(12, 12)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    LOGICAL, INTENT(IN), OPTIONAL :: symmetric_half
    LOGICAL, INTENT(IN), OPTIONAL :: tangent_only

    REAL(wp) :: gp(MAX_NG), gw(MAX_NG), H(4), dH(4), ddH(4)
    REAL(wp) :: invL, invL2, wgL, b1(4), b2(4)
    REAL(wp) :: av(3), bv(3), cr(3), s2, sp, spi, spi3, epsx, Nn, Dsix, invD, invD2, invD3
    REAL(wp) :: dNv(6), dD3(3), gkap2(6), g6(6), H6(6, 6)
    REAL(wp) :: cA, cB, b2n, adb, hd, fN, cD2, cND2, cND3, caxd, w11, w12, w21, w22
    INTEGER :: qg, c, dd, k, m, i, j, ic, jc
    LOGICAL :: want_kt, half_kt, kt_only
    INTEGER, PARAMETER :: sd(4) = [0, 3, 6, 9]

    ErrStat = CD_HCABLE_OK
    ErrMsg = ''
    Eout = CD_ZERO
    fint = CD_ZERO
    want_kt = PRESENT(Kt)
    half_kt = .FALSE.
    kt_only = .FALSE.
    IF (PRESENT(symmetric_half)) half_kt = symmetric_half
    IF (PRESENT(tangent_only)) kt_only = tangent_only
    IF (want_kt) Kt = CD_ZERO

    IF (kt_only .AND. .NOT. want_kt) THEN
      CALL fail('tangent_only requires Kt'); RETURN
    END IF

    IF (.NOT. CD_All_Finite(qr) .OR. .NOT. CD_Is_Finite(L) .OR. &
        .NOT. CD_Is_Finite(EA) .OR. .NOT. CD_Is_Finite(EI)) THEN
      CALL fail('inputs must be finite'); RETURN
    END IF
    IF (L <= GEOM_TOL) THEN
      CALL fail('element length must be positive'); RETURN
    END IF
    IF (EA < CD_ZERO .OR. EI < CD_ZERO) THEN
      CALL fail('EA and EI must be non-negative'); RETURN
    END IF

    CALL CD_HermiteCable_Gauss_Rule(quadrature_order, gp, gw)
    invL = CD_ONE/L
    invL2 = invL*invL

    ! HOT KERNEL (unrolled). The generic intermediates (the sparse 3x6 Jcr, its Gram
    ! matrix, and the full 6x6 HNv/HDv) are replaced by their closed forms:
    !   dN/d(a,b) = 2 Jcr^T cr           = 2 [ b x cr ; cr x a ]
    !   Jcr^T Jcr =  [ |b|^2 I - b b^T ,  a b^T - (a.b) I ]
    !                [      (sym)      ,  |a|^2 I - a a^T ]
    ! and the dD/HD terms touch ONLY the a-rows/columns (D = |a|^6), so H6 is assembled
    ! directly by 3x3 blocks (bb carries the HN term alone; ba = ab^T exactly). The DOF
    ! chain hoists the four b1/b2 weights per (k,m) node pair. Same analytic derivatives,
    ! reassociated arithmetic (the FD gate in test_hermite_cable pins fint and Kt
    ! independently of the arithmetic form).
    DO qg = 1, quadrature_order
      CALL hermite_shapes(gp(qg), L, H, dH, ddH)
      ! a = dr/ds and b = d^2r/ds^2 are constant-coefficient linear maps of q:
      !   a(c) = sum_k b1(k) q_{sd(k)+c},  b(c) = sum_k b2(k) q_{sd(k)+c},  sd = [0,3,6,9].
      b1 = dH*invL
      b2 = ddH*invL2
      DO c = 1, 3
        av(c) = b1(1)*qr(sd(1) + c) + b1(2)*qr(sd(2) + c) + b1(3)*qr(sd(3) + c) + b1(4)*qr(sd(4) + c)
        bv(c) = b2(1)*qr(sd(1) + c) + b2(2)*qr(sd(2) + c) + b2(3)*qr(sd(3) + c) + b2(4)*qr(sd(4) + c)
      END DO
      wgL = gw(qg)*L

      ! Axial strain eps = |a| - 1, with the degenerate-centreline guard on |a|^2 itself
      ! (curvature is undefined at zero speed; the guard reuses the s2 the energy needs).
      s2 = av(1)*av(1) + av(2)*av(2) + av(3)*av(3)
      IF (s2 <= GEOM_TOL*GEOM_TOL) THEN
        CALL fail('degenerate centreline: |dr/ds| ~ 0 at a Gauss point'); RETURN
      END IF
      sp = SQRT(s2)                    ! |dr/ds| = 1 + eps; s2 > 0, so sqrt is smooth here
      spi = CD_ONE/sp
      spi3 = spi*spi*spi
      epsx = sp - CD_ONE

      ! Bending: cr = a x b, N = |cr|^2, D = |a|^6, kappa^2 = N/D. Using kappa^2 = N/D
      ! DIRECTLY (no sqrt) keeps the straight-state (cr = 0) limit smooth: gkap2 -> 0 and
      ! the curvature Hessian -> 2 Jcr^T Jcr / D, the finite curvature-energy tangent.
      cr(1) = av(2)*bv(3) - av(3)*bv(2)
      cr(2) = av(3)*bv(1) - av(1)*bv(3)
      cr(3) = av(1)*bv(2) - av(2)*bv(1)
      Nn = cr(1)*cr(1) + cr(2)*cr(2) + cr(3)*cr(3)
      Dsix = s2*s2*s2
      invD = CD_ONE/Dsix
      invD2 = invD*invD
      invD3 = invD2*invD

      ! First derivatives: dN(1:3) = 2 (b x cr), dN(4:6) = 2 (cr x a); dD(1:3) = 6 s2^2 a
      ! (the b-half of dD is zero). Gradient of kappa^2 = dN/D - N dD/D^2.
      dNv(1) = 2.0_wp*(bv(2)*cr(3) - bv(3)*cr(2))
      dNv(2) = 2.0_wp*(bv(3)*cr(1) - bv(1)*cr(3))
      dNv(3) = 2.0_wp*(bv(1)*cr(2) - bv(2)*cr(1))
      dNv(4) = 2.0_wp*(cr(2)*av(3) - cr(3)*av(2))
      dNv(5) = 2.0_wp*(cr(3)*av(1) - cr(1)*av(3))
      dNv(6) = 2.0_wp*(cr(1)*av(2) - cr(2)*av(1))
      dD3 = (6.0_wp*s2*s2)*av
      hd = Nn*invD2
      gkap2(1:3) = dNv(1:3)*invD - hd*dD3
      gkap2(4:6) = dNv(4:6)*invD

      cA = EA*wgL
      cB = 0.5_wp*EI*wgL
      IF (.NOT. kt_only) THEN
        g6 = cB*gkap2
        g6(1:3) = g6(1:3) + (EA*epsx*wgL*spi)*av

        Eout = Eout + (0.5_wp*EA*epsx*epsx + 0.5_wp*EI*Nn*invD)*wgL

        ! Chain the (a, b) gradient to the 12 element DOFs via the constant maps
        ! (row c of a = b1(k) at DOF sd(k)+c; row c of b = b2(k) at DOF sd(k)+c).
        DO k = 1, 4
          DO c = 1, 3
            ic = sd(k) + c
            fint(ic) = fint(ic) + b1(k)*g6(c) + b2(k)*g6(3 + c)
          END DO
        END DO
      END IF

      IF (.NOT. want_kt) CYCLE

      ! H6 by 3x3 blocks (fN = 2 cB / D multiplies the HN = 2 JtJ + 2 E_cr part):
      !   bb: fN (|a|^2 I - a a^T)                                    [only HN survives]
      !   ab: fN (a b^T - (a.b) I - skew(cr)) - cB/D^2 dD_i dN_(3+j);  ba = ab^T exactly
      !   aa: fN (|b|^2 I - b b^T) - cB/D^2 (dN_i dD_j + dD_i dN_j) - cB N/D^2 HD_aa
      !       + 2 cB N/D^3 dD_i dD_j + the axial block
      !   with HD_aa = 24 s2 a a^T + 6 s2^2 I  and  E_cr(i,j) = -skew(cr) as before.
      b2n = bv(1)*bv(1) + bv(2)*bv(2) + bv(3)*bv(3)
      adb = av(1)*bv(1) + av(2)*bv(2) + av(3)*bv(3)
      fN = 2.0_wp*cB*invD
      cD2 = cB*invD2
      cND2 = cB*hd                     ! = cB N / D^2
      cND3 = 2.0_wp*cB*Nn*invD3
      caxd = cA*epsx*spi               ! axial diagonal
      DO j = 1, 3
        DO i = 1, 3
          ! aa block + axial (top-left)
          H6(i, j) = fN*(-bv(i)*bv(j)) - cD2*(dNv(i)*dD3(j) + dD3(i)*dNv(j)) &
                     - cND2*(24.0_wp*s2*av(i)*av(j)) + cND3*dD3(i)*dD3(j) &
                     + cA*((spi*av(i))*(spi*av(j)) - epsx*av(i)*av(j)*spi3)
          ! bb block (bottom-right)
          H6(3 + i, 3 + j) = fN*(-av(i)*av(j))
        END DO
        H6(j, j) = H6(j, j) + fN*b2n - cND2*(6.0_wp*s2*s2) + caxd
        H6(3 + j, 3 + j) = H6(3 + j, 3 + j) + fN*s2
      END DO
      ! ab block (+ the -skew(cr) coupling), mirrored exactly into ba.
      H6(1, 4) = fN*(av(1)*bv(1) - adb) - cD2*dD3(1)*dNv(4)
      H6(1, 5) = fN*(av(1)*bv(2) + cr(3)) - cD2*dD3(1)*dNv(5)
      H6(1, 6) = fN*(av(1)*bv(3) - cr(2)) - cD2*dD3(1)*dNv(6)
      H6(2, 4) = fN*(av(2)*bv(1) - cr(3)) - cD2*dD3(2)*dNv(4)
      H6(2, 5) = fN*(av(2)*bv(2) - adb) - cD2*dD3(2)*dNv(5)
      H6(2, 6) = fN*(av(2)*bv(3) + cr(1)) - cD2*dD3(2)*dNv(6)
      H6(3, 4) = fN*(av(3)*bv(1) + cr(2)) - cD2*dD3(3)*dNv(4)
      H6(3, 5) = fN*(av(3)*bv(2) - cr(1)) - cD2*dD3(3)*dNv(5)
      H6(3, 6) = fN*(av(3)*bv(3) - adb) - cD2*dD3(3)*dNv(6)
      DO j = 1, 3
        DO i = 1, 3
          H6(3 + j, i) = H6(i, 3 + j)
        END DO
      END DO

      ! Chain the symmetric (a, b) Hessian to the 12 element DOFs. Form only the upper
      ! triangle: evaluating both analytically identical halves would nearly double the
      ! dominant 12x12 chain work. Mirroring once after quadrature preserves exact
      ! symmetry without redundant flops.
      DO m = 1, 4
        DO k = 1, 4
          ! a node block below the diagonal (k > m) holds only rows ic > jc: none in the upper triangle
          IF (half_kt .AND. k > m) CYCLE
          w11 = b1(k)*b1(m)
          w12 = b1(k)*b2(m)
          w21 = b2(k)*b1(m)
          w22 = b2(k)*b2(m)
          DO dd = 1, 3
            jc = sd(m) + dd
            DO c = 1, 3
              ic = sd(k) + c
              IF (.NOT. half_kt .OR. ic <= jc) THEN
                Kt(ic, jc) = Kt(ic, jc) + w11*H6(c, dd) + w12*H6(c, 3 + dd) &
                             + w21*H6(3 + c, dd) + w22*H6(3 + c, 3 + dd)
              END IF
            END DO
          END DO
        END DO
      END DO
    END DO

    IF (want_kt) THEN
      ! The dynamic hot path may request upper-triangle-only formation. Default callers
      ! get the two-triangle average, whose roundoff path is important to
      ! continuation-sensitive static initialization cases.
      DO j = 1, 12
        DO i = 1, j - 1
          IF (.NOT. half_kt) Kt(i, j) = 0.5_wp*(Kt(i, j) + Kt(j, i))
          Kt(j, i) = Kt(i, j)
        END DO
      END DO
      IF (.NOT. CD_All_Finite(Kt)) THEN
        CALL fail('non-finite fint/Kt (check element geometry)'); RETURN
      END IF
    END IF

    IF (.NOT. CD_All_Finite(fint)) THEN
      CALL fail('non-finite fint/Kt (check element geometry)'); RETURN
    END IF

  CONTAINS

    SUBROUTINE fail(msg)
      CHARACTER(*), INTENT(IN) :: msg
      ErrStat = CD_HCABLE_BADINPUT
      ErrMsg = 'CD_HermiteCable_Element: '//msg
      ! No partially accumulated quadrature leaves a failed evaluation.
      Eout = CD_ZERO
      fint = CD_ZERO
      IF (PRESENT(Kt)) Kt = CD_ZERO
    END SUBROUTINE fail

  END SUBROUTINE hermite_element_integrated

  SUBROUTINE CD_HermiteCable_Mass(rho_a, L, M, ErrStat, ErrMsg)
    !! Consistent (kinetic-energy) mass matrix of the cubic-Hermite bending-cable element.
    !!
    !! The kinetic energy is T = 1/2 integral_0^L rho_a (dr/dt . dr/dt) ds and each Cartesian
    !! component r_c(s) is the SAME cubic-Hermite interpolant of the nodal [r_c, m_c] pair used
    !! by CD_HermiteCable_Element, so M = rho_a integral_0^L N^T N ds is exact and CONSISTENT
    !! with the stiffness (no lumping). Because the three components are interpolated
    !! independently, M is block-diagonal per component: for each of x, y, z the four DOFs
    !! {r1_c, m1_c, r2_c, m2_c} share the classic 4x4 cubic-Hermite mass sub-matrix
    !!   M4(i,j) = rho_a integral_0^L H_i H_j ds.
    !! It is built from the SAME 4-point Gauss rule + hermite_shapes as the energy (the rule is
    !! exact for the degree-6 H_i H_j products), so the element carries no hand-transcribed
    !! magic constants. The m-DOF (material-tangent) rows/columns inherit the length scaling of
    !! the H shape functions, so M is symmetric positive-definite and the r-block row sums are the
    !! nodal tributary masses (rho_a L / 2 each).
    !!
    !! rho_a : mass per unit reference length (kg/m), >= 0.
    !! L     : element unstretched (reference) length > 0.
    REAL(wp), INTENT(IN) :: rho_a, L
    REAL(wp), INTENT(OUT) :: M(12, 12)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg

    REAL(wp) :: gp(MAX_NG), gw(MAX_NG), H(4), dH(4), ddH(4), M4(4, 4), jac
    INTEGER :: qg, i, j, c, gi, gj
    INTEGER, PARAMETER :: shape_dof(4) = [0, 3, 6, 9]   ! shape s -> local DOF offset (add component c)

    ErrStat = CD_HCABLE_OK
    ErrMsg = ''
    M = CD_ZERO

    IF (.NOT. CD_Is_Finite(rho_a) .OR. .NOT. CD_Is_Finite(L)) THEN
      ErrStat = CD_HCABLE_BADINPUT; ErrMsg = 'CD_HermiteCable_Mass: inputs must be finite'; RETURN
    END IF
    IF (L <= GEOM_TOL) THEN
      ErrStat = CD_HCABLE_BADINPUT; ErrMsg = 'CD_HermiteCable_Mass: element length must be positive'; RETURN
    END IF
    IF (rho_a < CD_ZERO) THEN
      ErrStat = CD_HCABLE_BADINPUT; ErrMsg = 'CD_HermiteCable_Mass: rho_a must be non-negative'; RETURN
    END IF

    ! 4x4 per-component sub-matrix: M4(i,j) = rho_a * integral H_i H_j ds, ds = L dxi.
    CALL CD_HermiteCable_Gauss_Rule(NG, gp, gw)
    M4 = CD_ZERO
    DO qg = 1, NG
      CALL hermite_shapes(gp(qg), L, H, dH, ddH)
      jac = rho_a*gw(qg)*L
      DO i = 1, 4
        DO j = 1, 4
          M4(i, j) = M4(i, j) + jac*H(i)*H(j)
        END DO
      END DO
    END DO

    ! Scatter the per-component block into the 12x12 element mass (DOF order [r1,m1,r2,m2]).
    DO c = 1, 3
      DO i = 1, 4
        gi = shape_dof(i) + c
        DO j = 1, 4
          gj = shape_dof(j) + c
          M(gi, gj) = M4(i, j)
        END DO
      END DO
    END DO
  END SUBROUTINE CD_HermiteCable_Mass

  SUBROUTINE CD_HermiteCable_Curvature(qr, L, u, curvature, ErrStat, ErrMsg, kvec)
    !! Parametrisation-invariant centreline curvature at station u in [0,1] for output. kvec, when
    !! asked for, is the curvature vector kappa n, toward the centre of curvature:
    !! (r' x r'') x r'/|r'|^4, whose length is the curvature.
    REAL(wp), INTENT(IN) :: qr(12), L, u
    REAL(wp), INTENT(OUT) :: curvature
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    REAL(wp), INTENT(OUT), OPTIONAL :: kvec(3)
    REAL(wp) :: H(4), dH(4), ddH(4), rp(3), rpp(3), cr(3), sp
    INTEGER :: k

    ErrStat = CD_HCABLE_OK
    ErrMsg = ''
    curvature = CD_ZERO
    IF (PRESENT(kvec)) kvec = CD_ZERO
    IF (.NOT. CD_All_Finite(qr) .OR. .NOT. CD_Is_Finite(L) .OR. .NOT. CD_Is_Finite(u)) THEN
      ErrStat = CD_HCABLE_BADINPUT; ErrMsg = 'CD_HermiteCable_Curvature: inputs must be finite'; RETURN
    END IF
    IF (L <= GEOM_TOL .OR. u < -GEOM_TOL .OR. u > CD_ONE + GEOM_TOL) THEN
      ErrStat = CD_HCABLE_BADINPUT; ErrMsg = 'CD_HermiteCable_Curvature: L>0 and u in [0,1] required'; RETURN
    END IF
    CALL hermite_shapes(u, L, H, dH, ddH)
    DO k = 1, 3
      rp(k) = (dH(1)*qr(k) + dH(2)*qr(3 + k) + dH(3)*qr(6 + k) + dH(4)*qr(9 + k))/L
      rpp(k) = (ddH(1)*qr(k) + ddH(2)*qr(3 + k) + ddH(3)*qr(6 + k) + ddH(4)*qr(9 + k))/(L*L)
    END DO
    sp = SQRT(rp(1)**2 + rp(2)**2 + rp(3)**2)
    IF (sp <= GEOM_TOL) THEN
      ErrStat = CD_HCABLE_BADINPUT; ErrMsg = 'CD_HermiteCable_Curvature: degenerate centreline'; RETURN
    END IF
    cr = [rp(2)*rpp(3) - rp(3)*rpp(2), rp(3)*rpp(1) - rp(1)*rpp(3), rp(1)*rpp(2) - rp(2)*rpp(1)]
    curvature = SQRT(cr(1)**2 + cr(2)**2 + cr(3)**2)/sp**3
    IF (PRESENT(kvec)) kvec = [cr(2)*rp(3) - cr(3)*rp(2), cr(3)*rp(1) - cr(1)*rp(3), cr(1)*rp(2) - cr(2)*rp(1)]/sp**4
  END SUBROUTINE CD_HermiteCable_Curvature

  SUBROUTINE CD_HermiteCable_Peak_Curvature(qr, L, curvature_peak, u_peak, ErrStat, ErrMsg)
    !! Maximum centreline curvature over the complete Hermite element.  The search
    !! covers every base interval to a guaranteed parameter spacing and continues
    !! adaptively where the rational curvature field departs from linear variation.
    !! Reporting this maximum avoids treating Gauss points or nodes as extrema.
    REAL(wp), INTENT(IN) :: qr(12), L
    REAL(wp), INTENT(OUT) :: curvature_peak, u_peak
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    INTEGER, PARAMETER :: NBASE = 16
    INTEGER, PARAMETER :: MINDEPTH = 5
    INTEGER, PARAMETER :: MAXDEPTH = 12
    REAL(wp), PARAMETER :: REFREL = 0.05_wp
    INTEGER :: i
    REAL(wp) :: ua, ub, ka, kb

    ErrStat = CD_HCABLE_OK
    ErrMsg = ''
    curvature_peak = CD_ZERO
    u_peak = CD_ZERO
    CALL curv_at(CD_ZERO, ka)
    IF (ErrStat /= CD_HCABLE_OK) RETURN
    CALL retain_peak(CD_ZERO, ka)
    DO i = 1, NBASE
      ua = REAL(i - 1, wp)/REAL(NBASE, wp)
      ub = REAL(i, wp)/REAL(NBASE, wp)
      CALL curv_at(ub, kb)
      IF (ErrStat /= CD_HCABLE_OK) RETURN
      CALL retain_peak(ub, kb)
      CALL refine(ua, ub, ka, kb, 0)
      IF (ErrStat /= CD_HCABLE_OK) RETURN
      ka = kb
    END DO

  CONTAINS

    SUBROUTINE curv_at(u, curvature)
      REAL(wp), INTENT(IN) :: u
      REAL(wp), INTENT(OUT) :: curvature
      INTEGER :: es
      CHARACTER(160) :: em
      CALL CD_HermiteCable_Curvature(qr, L, u, curvature, es, em)
      IF (es /= CD_HCABLE_OK) THEN
        ErrStat = es
        ErrMsg = 'CD_HermiteCable_Peak_Curvature: '//TRIM(em)
        curvature = CD_ZERO
      END IF
    END SUBROUTINE curv_at

    SUBROUTINE retain_peak(u, curvature)
      REAL(wp), INTENT(IN) :: u, curvature
      IF (curvature > curvature_peak) THEN
        curvature_peak = curvature
        u_peak = u
      END IF
    END SUBROUTINE retain_peak

    RECURSIVE SUBROUTINE refine(a, b, curvature_a, curvature_b, depth)
      REAL(wp), INTENT(IN) :: a, b, curvature_a, curvature_b
      INTEGER, INTENT(IN) :: depth
      REAL(wp) :: midpoint, curvature_mid, curvature_linear
      IF (ErrStat /= CD_HCABLE_OK) RETURN
      midpoint = 0.5_wp*(a + b)
      CALL curv_at(midpoint, curvature_mid)
      IF (ErrStat /= CD_HCABLE_OK) RETURN
      CALL retain_peak(midpoint, curvature_mid)
      curvature_linear = 0.5_wp*(curvature_a + curvature_b)
      IF (depth < MAXDEPTH .AND. &
          (depth < MINDEPTH .OR. &
           ABS(curvature_mid - curvature_linear) > &
           REFREL*MAX(curvature_mid, curvature_a, curvature_b))) THEN
        CALL refine(a, midpoint, curvature_a, curvature_mid, depth + 1)
        CALL refine(midpoint, b, curvature_mid, curvature_b, depth + 1)
      END IF
    END SUBROUTINE refine

  END SUBROUTINE CD_HermiteCable_Peak_Curvature

  SUBROUTINE CD_HermiteCable_Axial_Resultant(qr, L, EA, u, axial_resultant, ErrStat, ErrMsg)
    !! Signed constitutive axial resultant at station u.  Positive values denote
    !! tension and negative values denote compression in the bilateral material law.
    REAL(wp), INTENT(IN) :: qr(12), L, EA, u
    REAL(wp), INTENT(OUT) :: axial_resultant
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    REAL(wp) :: H(4), dH(4), ddH(4), rp(3), speed
    INTEGER :: c

    ErrStat = CD_HCABLE_OK
    ErrMsg = ''
    axial_resultant = CD_ZERO
    IF (.NOT. CD_All_Finite(qr) .OR. .NOT. CD_Is_Finite(L) .OR. &
        .NOT. CD_Is_Finite(EA) .OR. .NOT. CD_Is_Finite(u)) THEN
      ErrStat = CD_HCABLE_BADINPUT
      ErrMsg = 'CD_HermiteCable_Axial_Resultant: inputs must be finite'
      RETURN
    END IF
    IF (L <= GEOM_TOL .OR. EA < CD_ZERO .OR. u < -GEOM_TOL .OR. u > CD_ONE + GEOM_TOL) THEN
      ErrStat = CD_HCABLE_BADINPUT
      ErrMsg = 'CD_HermiteCable_Axial_Resultant: L>0, EA>=0 and u in [0,1] required'
      RETURN
    END IF
    CALL hermite_shapes(u, L, H, dH, ddH)
    DO c = 1, 3
      rp(c) = (dH(1)*qr(c) + dH(2)*qr(3 + c) + &
               dH(3)*qr(6 + c) + dH(4)*qr(9 + c))/L
    END DO
    speed = NORM2(rp)
    IF (speed <= GEOM_TOL) THEN
      ErrStat = CD_HCABLE_BADINPUT
      ErrMsg = 'CD_HermiteCable_Axial_Resultant: degenerate centreline'
      RETURN
    END IF
    axial_resultant = EA*(speed - CD_ONE)
  END SUBROUTINE CD_HermiteCable_Axial_Resultant

  SUBROUTINE CD_HermiteCable_Axial_Resultant_Range(qr, L, EA, minimum_resultant, minimum_u, &
                                                   maximum_resultant, maximum_u, ErrStat, ErrMsg)
    !! Element-wise extrema of the signed axial resultant, with their material
    !! positions.  The guaranteed subdivision prevents a narrow oscillation near a
    !! section interface from being hidden by node-only or Gauss-point sampling.
    REAL(wp), INTENT(IN) :: qr(12), L, EA
    REAL(wp), INTENT(OUT) :: minimum_resultant, minimum_u, maximum_resultant, maximum_u
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    INTEGER, PARAMETER :: NBASE = 16
    INTEGER, PARAMETER :: MINDEPTH = 5
    INTEGER, PARAMETER :: MAXDEPTH = 12
    REAL(wp), PARAMETER :: REFREL = 0.02_wp
    INTEGER :: i
    REAL(wp) :: ua, ub, na, nb

    ErrStat = CD_HCABLE_OK
    ErrMsg = ''
    minimum_resultant = HUGE(CD_ONE)
    maximum_resultant = -HUGE(CD_ONE)
    minimum_u = CD_ZERO
    maximum_u = CD_ZERO
    CALL resultant_at(CD_ZERO, na)
    IF (ErrStat /= CD_HCABLE_OK) RETURN
    CALL retain_extrema(CD_ZERO, na)
    DO i = 1, NBASE
      ua = REAL(i - 1, wp)/REAL(NBASE, wp)
      ub = REAL(i, wp)/REAL(NBASE, wp)
      CALL resultant_at(ub, nb)
      IF (ErrStat /= CD_HCABLE_OK) RETURN
      CALL retain_extrema(ub, nb)
      CALL refine(ua, ub, na, nb, 0)
      IF (ErrStat /= CD_HCABLE_OK) RETURN
      na = nb
    END DO

  CONTAINS

    SUBROUTINE resultant_at(u, resultant)
      REAL(wp), INTENT(IN) :: u
      REAL(wp), INTENT(OUT) :: resultant
      INTEGER :: es
      CHARACTER(160) :: em
      CALL CD_HermiteCable_Axial_Resultant(qr, L, EA, u, resultant, es, em)
      IF (es /= CD_HCABLE_OK) THEN
        ErrStat = es
        ErrMsg = 'CD_HermiteCable_Axial_Resultant_Range: '//TRIM(em)
        resultant = CD_ZERO
      END IF
    END SUBROUTINE resultant_at

    SUBROUTINE retain_extrema(u, resultant)
      REAL(wp), INTENT(IN) :: u, resultant
      IF (resultant < minimum_resultant) THEN
        minimum_resultant = resultant
        minimum_u = u
      END IF
      IF (resultant > maximum_resultant) THEN
        maximum_resultant = resultant
        maximum_u = u
      END IF
    END SUBROUTINE retain_extrema

    RECURSIVE SUBROUTINE refine(a, b, resultant_a, resultant_b, depth)
      REAL(wp), INTENT(IN) :: a, b, resultant_a, resultant_b
      INTEGER, INTENT(IN) :: depth
      REAL(wp) :: midpoint, resultant_mid, resultant_linear, scale
      IF (ErrStat /= CD_HCABLE_OK) RETURN
      midpoint = 0.5_wp*(a + b)
      CALL resultant_at(midpoint, resultant_mid)
      IF (ErrStat /= CD_HCABLE_OK) RETURN
      CALL retain_extrema(midpoint, resultant_mid)
      resultant_linear = 0.5_wp*(resultant_a + resultant_b)
      scale = MAX(CD_ONE, ABS(resultant_mid), ABS(resultant_a), ABS(resultant_b))
      IF (depth < MAXDEPTH .AND. &
          (depth < MINDEPTH .OR. ABS(resultant_mid - resultant_linear) > REFREL*scale)) THEN
        CALL refine(a, midpoint, resultant_a, resultant_mid, depth + 1)
        CALL refine(midpoint, b, resultant_mid, resultant_b, depth + 1)
      END IF
    END SUBROUTINE refine

  END SUBROUTINE CD_HermiteCable_Axial_Resultant_Range

  PURE FUNCTION CD_HermiteCable_Axial_Strain_Lower_Bound(qr, L) RESULT(strain_lb)
    !! Cheap lower bound of the axial strain |r'(u)| - 1 over u in [0,1], valid for every
    !! pointwise value CD_HermiteCable_Axial_Resultant returns (divided by EA). With
    !! t = u - 1/2 the centreline derivative is r' = A + B t + C t**2, so |r'|**2 is a quartic
    !! in t whose odd and indefinite terms are bounded on |t| <= 1/2. The bound is reduced by
    !! an allowance for the rounding of the coordinate differences in the pointwise formula.
    !! Returns -HUGE for non-finite or degenerate input, so a screen built on it never skips.
    REAL(wp), INTENT(IN) :: qr(12), L
    REAL(wp) :: strain_lb
    REAL(wp) :: d(3), a(3), b(3), c(3), p_lb, xmax
    strain_lb = -HUGE(CD_ONE)
    IF (.NOT. (CD_All_Finite(qr) .AND. CD_Is_Finite(L))) RETURN
    IF (L <= GEOM_TOL) RETURN
    d = (qr(7:9) - qr(1:3))/L
    a = 1.5_wp*d - 0.25_wp*(qr(4:6) + qr(10:12))
    b = qr(10:12) - qr(4:6)
    c = 3.0_wp*(qr(4:6) + qr(10:12)) - 6.0_wp*d
    p_lb = DOT_PRODUCT(a, a) - ABS(DOT_PRODUCT(a, b)) + &
           0.25_wp*MIN(CD_ZERO, DOT_PRODUCT(b, b) + 2.0_wp*DOT_PRODUCT(a, c)) - &
           0.25_wp*ABS(DOT_PRODUCT(b, c))
    IF (.NOT. CD_Is_Finite(p_lb) .OR. p_lb <= CD_ZERO) RETURN
    xmax = MAX(MAXVAL(ABS(qr(1:3))), MAXVAL(ABS(qr(7:9))))
    strain_lb = SQRT(p_lb) - CD_ONE - 1024.0_wp*EPSILON(CD_ONE)*(CD_ONE + xmax/L + MAXVAL(ABS(qr)))
  END FUNCTION CD_HermiteCable_Axial_Strain_Lower_Bound

  PURE SUBROUTINE CD_HermiteCable_Shapes(xi, L, H, dH)
    !! Public cubic-Hermite position basis H(4) and its xi-derivative dH(4) at xi in [0,1], for
    !! consistent distributed-load assembly (e.g. Morison drag) over the element shape functions.
    !! DOF order [r1, m1, r2, m2]; H(2), H(4) carry the length scale L of the material-tangent DOFs.
    REAL(wp), INTENT(IN) :: xi, L
    REAL(wp), INTENT(OUT) :: H(4), dH(4)
    REAL(wp) :: ddH(4)
    CALL hermite_shapes(xi, L, H, dH, ddH)
  END SUBROUTINE CD_HermiteCable_Shapes

  PURE SUBROUTINE hermite_shapes(xi, L, H, dH, ddH)
    !! Cubic-Hermite basis on xi in [0,1] with dimensional tangent handles (scale L).
    !! DOF order per node: [value, L*slope]; element order [r1, m1, r2, m2].
    REAL(wp), INTENT(IN) :: xi, L
    REAL(wp), INTENT(OUT) :: H(4), dH(4), ddH(4)
    REAL(wp) :: x, x2, x3
    x = xi; x2 = x*x; x3 = x2*x
    H = [CD_ONE - 3*x2 + 2*x3, L*(x - 2*x2 + x3), 3*x2 - 2*x3, L*(-x2 + x3)]
    dH = [-6*x + 6*x2, L*(CD_ONE - 4*x + 3*x2), 6*x - 6*x2, L*(-2*x + 3*x2)]
    ddH = [-6 + 12*x, L*(-4 + 6*x), 6 - 12*x, L*(-2 + 6*x)]
  END SUBROUTINE hermite_shapes

  PURE SUBROUTINE CD_HermiteCable_Gauss_Rule(order, gp, gw)
    !! Gauss-Legendre rules mapped to [0,1].  Orders up to six are exposed for
    !! integration-sensitivity studies while the production default remains four.
    INTEGER, INTENT(IN) :: order
    REAL(wp), INTENT(OUT) :: gp(MAX_NG), gw(MAX_NG)
    gp = CD_ZERO
    gw = CD_ZERO
    SELECT CASE (order)
    CASE (1)
      gp(1) = 0.5_wp
      gw(1) = CD_ONE
    CASE (2)
      gp(1:2) = 0.5_wp*[CD_ONE - 0.57735026918962576451_wp, &
                        CD_ONE + 0.57735026918962576451_wp]
      gw(1:2) = 0.5_wp
    CASE (3)
      gp(1:3) = 0.5_wp*[CD_ONE - 0.77459666924148337704_wp, CD_ONE, &
                        CD_ONE + 0.77459666924148337704_wp]
      gw(1:3) = 0.5_wp*[0.55555555555555555556_wp, 0.88888888888888888889_wp, &
                        0.55555555555555555556_wp]
    CASE (4)
      gp(1:4) = 0.5_wp*[CD_ONE - 0.86113631159405257522_wp, CD_ONE - 0.33998104358485626480_wp, &
                        CD_ONE + 0.33998104358485626480_wp, CD_ONE + 0.86113631159405257522_wp]
      gw(1:4) = 0.5_wp*[0.34785484513745385737_wp, 0.65214515486254614263_wp, &
                        0.65214515486254614263_wp, 0.34785484513745385737_wp]
    CASE (5)
      gp(1:5) = 0.5_wp*[CD_ONE - 0.90617984593866399280_wp, CD_ONE - 0.53846931010568309104_wp, &
                        CD_ONE, CD_ONE + 0.53846931010568309104_wp, CD_ONE + 0.90617984593866399280_wp]
      gw(1:5) = 0.5_wp*[0.23692688505618908751_wp, 0.47862867049936646804_wp, &
                        0.56888888888888888889_wp, 0.47862867049936646804_wp, &
                        0.23692688505618908751_wp]
    CASE (6)
      gp(1:6) = 0.5_wp*[CD_ONE - 0.93246951420315202781_wp, CD_ONE - 0.66120938646626451366_wp, &
                        CD_ONE - 0.23861918608319690863_wp, CD_ONE + 0.23861918608319690863_wp, &
                        CD_ONE + 0.66120938646626451366_wp, CD_ONE + 0.93246951420315202781_wp]
      gw(1:6) = 0.5_wp*[0.17132449237917034504_wp, 0.36076157304813860757_wp, &
                        0.46791393457269104739_wp, 0.46791393457269104739_wp, &
                        0.36076157304813860757_wp, 0.17132449237917034504_wp]
    END SELECT
  END SUBROUTINE CD_HermiteCable_Gauss_Rule

  PURE SUBROUTINE CD_HermiteCable_Dry_Buoyancy(qz, L, buoyancy, waterline_z, fz, kz, dry, energy, radius)
    !! Buoyancy recovery for the part of one cubic-Hermite element above a flat free surface.
    !! A Hermite line carries the SUBMERGED weight w = (rho_A - rho A) g, which assumes that the
    !! whole element displaces water. Above waterline_z nothing is displaced, so the buoyancy
    !! per reference length (buoyancy = rho g A) is restored as a downward load on the dry part.
    !!
    !! The height z(xi) is the cubic-Hermite interpolant of qz = [z1, m_z1, z2, m_z2] on
    !! xi = s/L in [0, 1]. Its waterline crossings are located by bisection on the monotone
    !! pieces between the critical points of the cubic, and the consistent generalized load is
    !! integrated in closed form over every dry interval:
    !!   fz(a) = buoyancy * L * integral_dry N_a(xi) dxi,   N = [H1, L H2, H3, L H4].
    !! fz is added to R = f_int - f_ext (a downward external load). A crossing xi_c moves at
    !! d xi_c / d q_b = -N_b(xi_c) / z'(xi_c), so the exact tangent is
    !!   kz(a, b) = buoyancy * L * sum_c N_a(xi_c) N_b(xi_c) / |z'(xi_c)|,
    !! symmetric positive semidefinite (the waterplane restoring stiffness). |z'| is floored at
    !! 1e-3 L so that a crossing nearly tangent to the surface keeps a finite tangent; the load
    !! remains exact. dry = .FALSE. reports a fully submerged element (fz = kz = 0).
    !! energy (optional): the load potential buoyancy * L * integral_dry (z - waterline_z) dxi,
    !! whose gradient is fz (the crossing terms vanish because the integrand is zero there).
    !!
    !! radius (optional, > 0): the section radius R. The displaced area then follows the
    !! partial immersion of the circular section: at centreline height g = z - waterline_z
    !! the dry fraction is phi(u) = 1 - (acos(u) - u sqrt(1 - u^2))/pi, u = g/R clipped to
    !! [-1, 1], so the load density buoyancy*phi(g) ramps C1 from zero (centre R below the
    !! surface) to the full buoyancy (R above it). Its potential density is Phi(g), the
    !! integral of phi from -R, equal to g above the band, so fully dry intervals keep the
    !! closed form above; band intervals are integrated by 8-point Gauss-Legendre (nodes
    !! clustered at band edges) with the tangent buoyancy * L * integral N_a N_b phi'(g).
    !! The restoring stiffness is then the waterplane stiffness of the section, finite for a
    !! line floating level at the surface, where the centreline law above has a step load.
    REAL(wp), INTENT(IN) :: qz(4), L, buoyancy, waterline_z
    REAL(wp), INTENT(OUT) :: fz(4), kz(4, 4)
    LOGICAL, INTENT(OUT) :: dry
    REAL(wp), INTENT(OUT), OPTIONAL :: energy
    REAL(wp), INTENT(IN), OPTIONAL :: radius
    REAL(wp) :: c(0:3), bez(4), brk(4), pts(12), crit(2), nb(4), pa(4), pb(4)
    REAL(wp) :: lo, hi, mid, g_lo, qa, qb, qc, disc, qq, slope, tmp, hw, level
    INTEGER :: nbrk, npts, ncrit, i, j, it, lev
    REAL(wp), PARAMETER :: GX(8) = [0.0198550717512319_wp, 0.1016667612931866_wp, &
                                    0.2372337950418355_wp, 0.4082826787521751_wp, &
                                    0.5917173212478249_wp, 0.7627662049581645_wp, &
                                    0.8983332387068134_wp, 0.9801449282487681_wp]
    REAL(wp), PARAMETER :: GW(8) = [0.0506142681451881_wp, 0.1111905172266872_wp, &
                                    0.1568533229389436_wp, 0.1813418916891810_wp, &
                                    0.1813418916891810_wp, 0.1568533229389436_wp, &
                                    0.1111905172266872_wp, 0.0506142681451881_wp]
    REAL(wp), PARAMETER :: PI_S = 3.14159265358979323846_wp
    REAL(wp) :: a, b, x, u, s1, phi, dphi, big_phi, gm, wq, e_acc, t
    LOGICAL :: edge_a, edge_b
    INTEGER :: k, m, ins

    fz = CD_ZERO
    kz = CD_ZERO
    dry = .FALSE.
    IF (PRESENT(energy)) energy = CD_ZERO
    IF (.NOT. (buoyancy > CD_ZERO)) RETURN
    hw = CD_ZERO
    IF (PRESENT(radius)) hw = MAX(radius, CD_ZERO)
    ! Bezier control heights bound the cubic (convex hull): all at or below the surface (the
    ! immersion band) means the element is wet, all above means it is dry along its whole
    ! length.
    bez = [qz(1), qz(1) + L*qz(2)/3.0_wp, qz(3) - L*qz(4)/3.0_wp, qz(3)] - waterline_z
    IF (MAXVAL(bez) <= -hw) RETURN
    dry = .TRUE.

    ! g(xi) = z(xi) - waterline_z in monomial form.
    c(0) = qz(1) - waterline_z
    c(1) = L*qz(2)
    c(2) = -3.0_wp*qz(1) - 2.0_wp*L*qz(2) + 3.0_wp*qz(3) - L*qz(4)
    c(3) = 2.0_wp*qz(1) + L*qz(2) - 2.0_wp*qz(3) + L*qz(4)
    IF (MINVAL(bez) > hw) THEN
      fz = buoyancy*L*[0.5_wp, L/12.0_wp, 0.5_wp, -L/12.0_wp]
      IF (PRESENT(energy)) energy = buoyancy*L*(gint(CD_ONE) - gint(CD_ZERO))
      RETURN
    END IF

    ! Critical points of g in (0, 1) split [0, 1] into monotone pieces (stable quadratic roots).
    ncrit = 0
    qa = 3.0_wp*c(3)
    qb = 2.0_wp*c(2)
    qc = c(1)
    IF (ABS(qa) > CD_ZERO) THEN
      disc = qb*qb - 4.0_wp*qa*qc
      IF (disc >= CD_ZERO) THEN
        qq = -0.5_wp*(qb + SIGN(SQRT(disc), qb))
        IF (ABS(qq) > CD_ZERO) THEN
          ncrit = 2
          crit(1) = qq/qa
          crit(2) = qc/qq
        ELSE
          ncrit = 1
          crit(1) = CD_ZERO
        END IF
      END IF
    ELSE IF (ABS(qb) > CD_ZERO) THEN
      ncrit = 1
      crit(1) = -qc/qb
    END IF
    IF (ncrit == 2) THEN
      IF (crit(2) < crit(1)) THEN
        tmp = crit(1); crit(1) = crit(2); crit(2) = tmp
      END IF
    END IF
    nbrk = 1
    brk(1) = CD_ZERO
    DO i = 1, ncrit
      IF (crit(i) > CD_ZERO .AND. crit(i) < CD_ONE) THEN
        nbrk = nbrk + 1
        brk(nbrk) = crit(i)
      END IF
    END DO
    nbrk = nbrk + 1
    brk(nbrk) = CD_ONE

    ! Finite-section law (radius present): split every monotone piece at its crossings of
    ! the band edges g = -R and g = +R, then integrate each sub-interval as dry (closed
    ! form), wet (nothing) or in-band (Gauss-Legendre on phi).
    IF (hw > CD_ZERO) THEN
      npts = 0
      DO i = 1, nbrk
        npts = npts + 1
        pts(npts) = brk(i)
      END DO
      DO i = 1, nbrk - 1
        DO lev = -1, 1, 2
          level = REAL(lev, wp)*hw
          lo = brk(i)
          hi = brk(i + 1)
          g_lo = gval(lo) - level
          IF ((g_lo > CD_ZERO) .EQV. (gval(hi) - level > CD_ZERO)) CYCLE
          DO it = 1, 200
            mid = 0.5_wp*(lo + hi)
            IF (mid <= lo .OR. mid >= hi) EXIT
            IF ((gval(mid) - level > CD_ZERO) .EQV. (g_lo > CD_ZERO)) THEN
              lo = mid
            ELSE
              hi = mid
            END IF
          END DO
          npts = npts + 1
          pts(npts) = 0.5_wp*(lo + hi)
        END DO
      END DO
      ! Insertion sort of the break points.
      DO k = 2, npts
        tmp = pts(k)
        ins = k - 1
        DO WHILE (ins >= 1)
          IF (pts(ins) <= tmp) EXIT
          pts(ins + 1) = pts(ins)
          ins = ins - 1
        END DO
        pts(ins + 1) = tmp
      END DO
      e_acc = CD_ZERO
      DO k = 1, npts - 1
        a = pts(k)
        b = pts(k + 1)
        IF (b <= a) CYCLE
        gm = gval(0.5_wp*(a + b))
        IF (gm <= -hw) CYCLE
        IF (gm >= hw) THEN
          pa = antiderivative(a)
          pb = antiderivative(b)
          fz = fz + (pb - pa)
          e_acc = e_acc + gint(b) - gint(a)
          CYCLE
        END IF
        ! phi' has a square-root edge where an interval ends on a band edge; a quadratic
        ! substitution clustering the nodes at such an end (smoothstep when both ends are
        ! edges) makes the integrand smooth, so the rule stays accurate for the load, the
        ! energy and the tangent. Interior ends (critical points, element ends) are plain.
        edge_a = ABS(ABS(gval(a)) - hw) <= 1.0e-9_wp*hw
        edge_b = ABS(ABS(gval(b)) - hw) <= 1.0e-9_wp*hw
        DO m = 1, 8
          t = GX(m)
          IF (edge_a .AND. edge_b) THEN
            x = a + (b - a)*t*t*(3.0_wp - 2.0_wp*t)
            wq = (b - a)*GW(m)*6.0_wp*t*(CD_ONE - t)
          ELSE IF (edge_a) THEN
            x = a + (b - a)*t*t
            wq = (b - a)*GW(m)*2.0_wp*t
          ELSE IF (edge_b) THEN
            x = b - (b - a)*(CD_ONE - t)**2
            wq = (b - a)*GW(m)*2.0_wp*(CD_ONE - t)
          ELSE
            x = a + (b - a)*t
            wq = (b - a)*GW(m)
          END IF
          u = MAX(-CD_ONE, MIN(CD_ONE, gval(x)/hw))
          s1 = SQRT(MAX(CD_ZERO, CD_ONE - u*u))
          phi = CD_ONE - (ACOS(u) - u*s1)/PI_S
          dphi = 2.0_wp*s1/(PI_S*hw)
          big_phi = hw*(u - (u*ACOS(u) - s1 + s1**3/3.0_wp)/PI_S)
          nb = [CD_ONE - x*x*(3.0_wp - 2.0_wp*x), L*x*(CD_ONE - x)**2, &
                x*x*(3.0_wp - 2.0_wp*x), L*x*x*(x - CD_ONE)]
          fz = fz + wq*phi*nb
          e_acc = e_acc + wq*big_phi
          DO j = 1, 4
            kz(:, j) = kz(:, j) + wq*dphi*nb*nb(j)
          END DO
        END DO
      END DO
      fz = buoyancy*L*fz
      kz = buoyancy*L*kz
      IF (PRESENT(energy)) energy = buoyancy*L*e_acc
      RETURN
    END IF

    ! Waterline crossings: one per monotone piece whose end heights straddle the surface
    ! (a height exactly at the surface counts as wet).
    npts = 1
    pts(1) = CD_ZERO
    DO i = 1, nbrk - 1
      lo = brk(i)
      hi = brk(i + 1)
      g_lo = gval(lo)
      IF ((g_lo > CD_ZERO) .EQV. (gval(hi) > CD_ZERO)) CYCLE
      DO it = 1, 200
        mid = 0.5_wp*(lo + hi)
        IF (mid <= lo .OR. mid >= hi) EXIT
        IF ((gval(mid) > CD_ZERO) .EQV. (g_lo > CD_ZERO)) THEN
          lo = mid
        ELSE
          hi = mid
        END IF
      END DO
      npts = npts + 1
      pts(npts) = 0.5_wp*(lo + hi)
    END DO
    npts = npts + 1
    pts(npts) = CD_ONE

    ! Closed-form integral of the shape functions over the dry sub-intervals.
    DO i = 1, npts - 1
      IF (pts(i + 1) <= pts(i)) CYCLE
      IF (gval(0.5_wp*(pts(i) + pts(i + 1))) <= CD_ZERO) CYCLE
      pa = antiderivative(pts(i))
      pb = antiderivative(pts(i + 1))
      fz = fz + (pb - pa)
      IF (PRESENT(energy)) energy = energy + gint(pts(i + 1)) - gint(pts(i))
    END DO
    fz = buoyancy*L*fz
    IF (PRESENT(energy)) energy = buoyancy*L*energy

    ! Crossing-motion tangent.
    DO i = 2, npts - 1
      mid = pts(i)
      slope = MAX(ABS(c(1) + mid*(2.0_wp*c(2) + mid*3.0_wp*c(3))), 1.0e-3_wp*L)
      nb = [CD_ONE - mid*mid*(3.0_wp - 2.0_wp*mid), L*mid*(CD_ONE - mid)**2, &
            mid*mid*(3.0_wp - 2.0_wp*mid), L*mid*mid*(mid - CD_ONE)]
      DO j = 1, 4
        kz(:, j) = kz(:, j) + nb*nb(j)/slope
      END DO
    END DO
    kz = buoyancy*L*kz

  CONTAINS

    PURE REAL(wp) FUNCTION gval(x)
      REAL(wp), INTENT(IN) :: x
      gval = c(0) + x*(c(1) + x*(c(2) + x*c(3)))
    END FUNCTION gval

    PURE REAL(wp) FUNCTION gint(x)
      !! Antiderivative of gval, vanishing at xi = 0.
      REAL(wp), INTENT(IN) :: x
      gint = x*(c(0) + x*(0.5_wp*c(1) + x*(c(2)/3.0_wp + 0.25_wp*x*c(3))))
    END FUNCTION gint

    PURE FUNCTION antiderivative(x) RESULT(p)
      !! Antiderivatives of [H1, L H2, H3, L H4] in xi, vanishing at xi = 0.
      REAL(wp), INTENT(IN) :: x
      REAL(wp) :: p(4), x2, x3, x4
      x2 = x*x
      x3 = x2*x
      x4 = x3*x
      p(1) = x - x3 + 0.5_wp*x4
      p(2) = L*(0.5_wp*x2 - 2.0_wp*x3/3.0_wp + 0.25_wp*x4)
      p(3) = x3 - 0.5_wp*x4
      p(4) = L*(-x3/3.0_wp + 0.25_wp*x4)
    END FUNCTION antiderivative

  END SUBROUTINE CD_HermiteCable_Dry_Buoyancy

END MODULE CableDyn_HermiteCable
