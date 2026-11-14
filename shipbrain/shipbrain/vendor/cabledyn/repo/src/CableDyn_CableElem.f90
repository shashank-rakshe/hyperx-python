! File: src/CableDyn_CableElem.f90
! SPDX-License-Identifier: Apache-2.0
! Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
MODULE CableDyn_CableElem
  !! Positions-only EI=0 cable (truss) limit element: the smallest geometrically
  !! exact line piece and the foundation of the positions-only cable path.
  !!
  !! A two-node element carries only axial strain energy and its exact geometric
  !! tangent (the cable limit of the rod). Per element, with node
  !! positions r_a, r_b in R^3 and unstretched length L0:
  !!
  !!   delta = r_b - r_a,   ell = |delta|,   t = delta / ell   (unit tangent)
  !!   eps   = ell / L0 - 1                                     (axial strain)
  !!   T     = EA * eps                                         (tension; clamped >= 0
  !!                                                             when tension_only)
  !!   fint  = [ -T t ; +T t ]                                  (6x1 internal force)
  !!   Kt    = [[ B, -B ], [ -B, B ]],
  !!     B   = (EA/L0)(t t^T) + (T/ell)(I - t t^T)              (material + geometric)
  !!
  !! In tension_only mode a compressed element (eps < 0) carries zero tension AND
  !! zero material tangent, so the tangent stays consistent with the force.
  !!
  !! Sign convention: positive tension = the element under tensile axial force
  !! (eps > 0), pulling each node toward the other.
  USE CableDyn_Precision, ONLY: wp, CD_ZERO, CD_ONE, CD_All_Finite, CD_Is_Finite
  IMPLICIT NONE
  PRIVATE

  PUBLIC :: CD_Compute_Cable_Element

CONTAINS

  SUBROUTINE CD_Compute_Cable_Element(nodes, ea, l0, tension_only, Kt, fint, &
                                      tension, ErrStat, ErrMsg)
    !! Compute the 6x6 tangent stiffness, 6x1 internal force, and scalar tension
    !! of one EI=0 cable element from its two node positions.
    REAL(wp), INTENT(IN)  :: nodes(6)      !! [r_a(3), r_b(3)] nodal positions
    REAL(wp), INTENT(IN)  :: ea            !! axial stiffness EA (> 0)
    REAL(wp), INTENT(IN)  :: l0            !! unstretched element length (> 0)
    LOGICAL, INTENT(IN)  :: tension_only  !! clamp compression to zero force + tangent
    REAL(wp), INTENT(OUT) :: Kt(6, 6)      !! tangent stiffness
    REAL(wp), INTENT(OUT) :: fint(6)       !! internal force
    REAL(wp), INTENT(OUT) :: tension       !! axial tension (clamped if tension_only)
    INTEGER, INTENT(OUT) :: ErrStat       !! 0 = success, 1 = invalid input
    CHARACTER(*), INTENT(OUT) :: ErrMsg

    REAL(wp) :: delta(3), ell, direction(3), strain, material
    REAL(wp) :: nn(3, 3), block(3, 3), eye(3, 3)
    INTEGER  :: i, j

    Kt = CD_ZERO
    fint = CD_ZERO
    tension = CD_ZERO
    ErrStat = 0
    ErrMsg = ''

    IF (.NOT. CD_All_Finite(nodes)) THEN
      ErrStat = 1
      ErrMsg = 'CD_Compute_Cable_Element: node coordinates must be finite'
      RETURN
    END IF
    ! IEEE_IS_FINITE rejects +/-Inf and NaN: a bare `ea > 0` accepts +Inf (Inf > 0
    ! is true), which would then leak Inf/NaN into Kt/fint while reporting success.
    ! EA = 0 is a DELIBERATE construction (the model's dynamic assembly masks the
    ! elastic stiffness of viscoelastic elements, whose tension comes from the
    ! series-Kelvin load contributor instead): force, tangent, and tension are exactly zero.
    IF (.NOT. (CD_Is_Finite(ea) .AND. ea >= CD_ZERO)) THEN
      ErrStat = 1
      ErrMsg = 'CD_Compute_Cable_Element: EA must be finite and non-negative'
      RETURN
    END IF
    IF (.NOT. (CD_Is_Finite(l0) .AND. l0 > CD_ZERO)) THEN
      ErrStat = 1
      ErrMsg = 'CD_Compute_Cable_Element: L0 must be finite and positive'
      RETURN
    END IF

    delta = nodes(4:6) - nodes(1:3)
    ell = NORM2(delta)
    ! ell is finite given finite nodes, except for an overflow at the float64 ceiling;
    ! the finite guard keeps that from passing as a valid (Inf) length.
    IF (.NOT. (CD_Is_Finite(ell) .AND. ell > CD_ZERO)) THEN
      ErrStat = 1
      ErrMsg = 'CD_Compute_Cable_Element: element collapsed to zero or non-finite length'
      RETURN
    END IF

    direction = delta/ell
    strain = ell/l0 - CD_ONE
    tension = ea*strain
    material = ea/l0

    IF (tension_only .AND. strain < CD_ZERO) THEN
      ! Compressed tension-only element: no force, and the material tangent is
      ! d/deps of max(0, EA eps) = 0 for eps < 0, so drop it too (keeps Kt
      ! consistent with fint).
      tension = CD_ZERO
      material = CD_ZERO
    END IF

    ! outer product t t^T and the 3x3 identity
    eye = CD_ZERO
    DO i = 1, 3
      eye(i, i) = CD_ONE
      DO j = 1, 3
        nn(i, j) = direction(i)*direction(j)
      END DO
    END DO

    ! B = (EA/L0)(t t^T) + (T/ell)(I - t t^T)
    block = material*nn + (tension/ell)*(eye - nn)

    ! Kt = [[B, -B], [-B, B]]
    Kt(1:3, 1:3) = block
    Kt(1:3, 4:6) = -block
    Kt(4:6, 1:3) = -block
    Kt(4:6, 4:6) = block

    ! fint = [-T t; +T t]
    fint(1:3) = -tension*direction
    fint(4:6) = tension*direction

  END SUBROUTINE CD_Compute_Cable_Element

END MODULE CableDyn_CableElem
