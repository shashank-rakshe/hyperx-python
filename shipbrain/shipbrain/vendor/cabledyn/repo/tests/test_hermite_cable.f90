! File: tests/test_hermite_cable.f90
! SPDX-License-Identifier: Apache-2.0
! Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
PROGRAM test_hermite_cable
  !! Unit checks for the cubic-Hermite bending-cable element (position + material-
  !! tangent DOFs, closed-form analytical fint/Kt). These pin the element contract that
  !! the finite-EI lazy-wave path relies on:
  !!   A  circular-arc bending-energy patch test vs the analytical 1/2 EI kappa^2 L,
  !!   B  analytical fint == central-FD of the strain energy,
  !!   C  analytical Kt   == central-FD of fint,
  !!   R  fint AND Kt == central-FD to <1e-6 across a spread of regimes (pure axial
  !!      stretch, circular arc, skew 3D bent+stretched) -- the closed-form tangent is
  !!      gated across regimes, not one configuration,
  !!   D  Kt is symmetric (the closed form enforces it, so to round-off),
  !!   E  a straight unstretched element is a zero-energy, zero-force rest state,
  !!   F  a uniform axial stretch stores exactly 1/2 EA eps^2 L,
  !!   G  the curvature diagnostic reproduces the circular-arc 1/R,
  !!   H  degenerate / non-finite / bad-length inputs fail closed,
  !!   I  the consistent mass matrix matches the analytical cubic-Hermite form, is symmetric,
  !!      scatters a rigid translation to the exact total kinetic energy 1/2 rho_a L |v|^2,
  !!      is linear in rho_a, and fails closed on bad inputs (the finite-EI dynamics foundation).
  USE CableDyn_Precision, ONLY: wp
  USE CableDyn_HermiteCable, ONLY: CD_HCABLE_OK, CD_HermiteCable_Element, CD_HermiteCable_Curvature, &
                                   CD_HermiteCable_Peak_Curvature, CD_HermiteCable_Axial_Resultant, &
                                   CD_HermiteCable_Axial_Resultant_Range, CD_HermiteCable_Mass
  IMPLICIT NONE

  REAL(wp), PARAMETER :: EA = 1.0e6_wp, EI = 100.0_wp, L = 1.0_wp
  INTEGER :: nfail

  nfail = 0
  CALL check_arc_patch()
  CALL check_ad_vs_fd()
  CALL check_tangent_only()
  CALL check_quadrature_controls()
  CALL check_ad_vs_fd_regimes()
  CALL check_rest_state()
  CALL check_axial_stretch()
  CALL check_axial_resultant_range()
  CALL check_curvature_diagnostic()
  CALL check_continuous_curvature_peak()
  CALL check_input_rejection()
  CALL check_mass_matrix()

  IF (nfail > 0) THEN
    WRITE (*, '(A,I0,A)') 'FAIL: ', nfail, ' assertion(s) failed'
    ERROR STOP 1
  END IF
  WRITE (*, '(A)') 'PASS: cubic-Hermite bending-cable element is exact and robust'

CONTAINS

  INCLUDE 'nan_max_abs.inc'

  SUBROUTINE check_tangent_only()
    !! The dynamic Newton hot path requests only the tangent. Its shortcut must reproduce
    !! the full element tangent exactly while leaving the intentionally unused outputs defined.
    REAL(wp) :: q(12), Efull, Eonly, ffull(12), fonly(12), Kfull(12, 12), Konly(12, 12)
    INTEGER :: es
    CHARACTER(200) :: em
    q(1:3) = [0.0_wp, 0.0_wp, 0.0_wp]
    q(4:6) = [1.0_wp, 0.10_wp, -0.05_wp]
    q(7:9) = [1.03_wp, 0.12_wp, 0.07_wp]
    q(10:12) = [0.97_wp, -0.08_wp, 0.11_wp]
    CALL CD_HermiteCable_Element(q, L, EA, EI, Efull, ffull, Kfull, es, em, symmetric_half=.TRUE.)
    CALL require(es == CD_HCABLE_OK, 'full tangent-only reference accepted: '//TRIM(em))
    CALL CD_HermiteCable_Element(q, L, EA, EI, Eonly, fonly, Konly, es, em, &
                                 symmetric_half=.TRUE., tangent_only=.TRUE.)
    CALL require(es == CD_HCABLE_OK, 'tangent-only evaluation accepted: '//TRIM(em))
    CALL require(ALL(Konly == Kfull), 'tangent-only evaluation reproduces Kt exactly')
    CALL require(Eonly == 0.0_wp .AND. ALL(fonly == 0.0_wp), &
                 'tangent-only unused energy/force outputs remain defined')
  END SUBROUTINE check_tangent_only

  SUBROUTINE check_quadrature_controls()
    !! Equal-order and selective quadrature retain a consistent energy, gradient
    !! and tangent.  The selective result must equal the sum of independently
    !! integrated axial and bending energies, forces and tangents.
    REAL(wp) :: q(12), energy_default, energy_four, energy_selective, energy_axial, energy_bending
    REAL(wp) :: force_default(12), force_four(12), force_selective(12), force_axial(12), force_bending(12)
    REAL(wp) :: tangent_default(12, 12), tangent_four(12, 12), tangent_selective(12, 12), &
                tangent_axial(12, 12), tangent_bending(12, 12), gradient_fd(12), tangent_fd(12, 12)
    INTEGER :: es
    CHARACTER(200) :: em

    q(1:3) = [0.0_wp, 0.0_wp, 0.0_wp]
    q(4:6) = [1.0_wp, 0.10_wp, -0.05_wp]
    q(7:9) = [1.03_wp, 0.12_wp, 0.07_wp]
    q(10:12) = [0.97_wp, -0.08_wp, 0.11_wp]
    CALL CD_HermiteCable_Element(q, L, EA, EI, energy_default, force_default, tangent_default, es, em)
    CALL CD_HermiteCable_Element(q, L, EA, EI, energy_four, force_four, tangent_four, es, em, &
                                 axial_quadrature_order=4, bending_quadrature_order=4)
    CALL require(es == CD_HCABLE_OK, 'explicit four-point quadrature accepted: '//TRIM(em))
    CALL require(energy_four == energy_default .AND. ALL(force_four == force_default) .AND. &
                 ALL(tangent_four == tangent_default), 'explicit 4/4 quadrature reproduces the default exactly')

    CALL CD_HermiteCable_Element(q, L, EA, EI, energy_selective, force_selective, tangent_selective, es, em, &
                                 axial_quadrature_order=2, bending_quadrature_order=6)
    CALL require(es == CD_HCABLE_OK, 'selective 2/6 quadrature accepted: '//TRIM(em))
    CALL CD_HermiteCable_Element(q, L, EA, 0.0_wp, energy_axial, force_axial, tangent_axial, es, em, &
                                 axial_quadrature_order=2)
    CALL CD_HermiteCable_Element(q, L, 0.0_wp, EI, energy_bending, force_bending, tangent_bending, es, em, &
                                 bending_quadrature_order=6)
    CALL require(ABS(energy_selective - energy_axial - energy_bending) < 1.0e-12_wp*MAX(1.0_wp, energy_selective), &
                 'selective energy is the sum of axial and bending contributions')
    CALL require(nan_max_abs(force_selective - force_axial - force_bending) < &
                 1.0e-12_wp*MAX(1.0_wp, nan_max_abs(force_selective)), &
                 'selective force is the sum of axial and bending contributions')
    CALL require(nan_max_abs(tangent_selective - tangent_axial - tangent_bending) < &
                 1.0e-12_wp*MAX(1.0_wp, nan_max_abs(tangent_selective)), &
                 'selective tangent is the sum of axial and bending contributions')

    CALL fd_grad_quad(q, 2, 6, gradient_fd)
    CALL fd_hess_quad(q, 2, 6, tangent_fd)
    CALL require(nan_max_abs(force_selective - gradient_fd)/MAX(1.0_wp, nan_max_abs(gradient_fd)) < 1.0e-6_wp, &
                 'selective-quadrature force matches the energy gradient')
    CALL require(nan_max_abs(tangent_selective - tangent_fd)/MAX(1.0_wp, nan_max_abs(tangent_fd)) < 1.0e-6_wp, &
                 'selective-quadrature tangent matches the force derivative')

    CALL CD_HermiteCable_Element(q, L, EA, EI, energy_four, force_four, tangent_four, es, em, &
                                 axial_quadrature_order=0, bending_quadrature_order=7)
    CALL require(es /= CD_HCABLE_OK, 'quadrature orders outside [1,6] fail closed')
  END SUBROUTINE check_quadrature_controls

  SUBROUTINE check_arc_patch()
    !! Circular arc of radius R: bending energy must match 1/2 EI (1/R)^2 L (EA off).
    REAL(wp) :: R, kap0, th, q(12), Ev, fint(12), Kt(12, 12), Eth
    INTEGER :: es
    CHARACTER(200) :: em
    R = 5.0_wp; kap0 = 1.0_wp/R; th = L/R
    q(1:3) = [0.0_wp, 0.0_wp, 0.0_wp]
    q(4:6) = [1.0_wp, 0.0_wp, 0.0_wp]                       ! m1 = unit tangent at u=0
    q(7:9) = [R*SIN(th), R*(1.0_wp - COS(th)), 0.0_wp]
    q(10:12) = [COS(th), SIN(th), 0.0_wp]                   ! m2 = unit tangent at u=1
    CALL CD_HermiteCable_Element(q, L, 0.0_wp, EI, Ev, fint, Kt, es, em)
    CALL require(es == CD_HCABLE_OK, 'arc patch accepted: '//TRIM(em))
    Eth = 0.5_wp*EI*kap0**2*L
    CALL require(ABS(Ev - Eth)/Eth < 1.0e-3_wp, 'arc bending energy matches 1/2 EI kappa^2 L')
  END SUBROUTINE check_arc_patch

  SUBROUTINE check_ad_vs_fd()
    !! AD gradient/Hessian vs central finite differences of the (exact) energy value.
    REAL(wp) :: q(12), Ev, fint(12), Kt(12, 12), g_fd(12), K_fd(12, 12)
    REAL(wp) :: maxg, maxK, maxasym
    INTEGER :: i, j, es
    CHARACTER(200) :: em
    q(1:3) = [0.0_wp, 0.0_wp, 0.0_wp]
    q(4:6) = [1.0_wp, 0.05_wp, 0.0_wp]
    q(7:9) = [1.02_wp, 0.10_wp, 0.0_wp]
    q(10:12) = [0.98_wp, 0.12_wp, 0.0_wp]
    CALL CD_HermiteCable_Element(q, L, EA, EI, Ev, fint, Kt, es, em)
    CALL require(es == CD_HCABLE_OK, 'deformed element accepted: '//TRIM(em))
    CALL fd_grad(q, g_fd)
    CALL fd_hess(q, K_fd)
    maxg = nan_max_abs(fint - g_fd)/MAX(1.0_wp, nan_max_abs(g_fd))
    maxK = nan_max_abs(Kt - K_fd)/MAX(1.0_wp, nan_max_abs(K_fd))
    maxasym = 0.0_wp
    DO i = 1, 12
      DO j = 1, 12
        maxasym = MAX(maxasym, ABS(Kt(i, j) - Kt(j, i)))
      END DO
    END DO
    CALL require(maxg < 1.0e-5_wp, 'AD fint matches central-FD of energy')
    CALL require(maxK < 1.0e-5_wp, 'AD Kt matches central-FD of fint')
    CALL require(maxasym < 1.0e-8_wp, 'Kt is symmetric to round-off')
  END SUBROUTINE check_ad_vs_fd

  SUBROUTINE check_ad_vs_fd_regimes()
    !! Tighten the closed-form fint/Kt vs central-FD comparison to <1e-6 across a spread
    !! of regimes so the analytical tangent is gated across the whole strain space, not one
    !! configuration: (1) a pure axial stretch (straight, so the cr=0 bending branch where the
    !! curvature Hessian must stay finite), (2) a circular arc (pure bending), and (3) a skew
    !! 3D bent + stretched configuration (all six a-b components active, out of plane).
    REAL(wp) :: q(12), Ev, fint(12), Kt(12, 12), g_fd(12), K_fd(12, 12)
    REAL(wp) :: maxg, maxK, R, th
    INTEGER :: es, which
    CHARACTER(200) :: em
    CHARACTER(32) :: nm

    DO which = 1, 3
      SELECT CASE (which)
      CASE (1)
        nm = 'axial stretch (straight)'
        q(1:3) = [0.0_wp, 0.0_wp, 0.0_wp]
        q(4:6) = [1.02_wp, 0.0_wp, 0.0_wp]
        q(7:9) = [1.02_wp*L, 0.0_wp, 0.0_wp]
        q(10:12) = [1.02_wp, 0.0_wp, 0.0_wp]
      CASE (2)
        nm = 'circular arc (pure bending)'
        R = 5.0_wp; th = L/R
        q(1:3) = [0.0_wp, 0.0_wp, 0.0_wp]
        q(4:6) = [1.0_wp, 0.0_wp, 0.0_wp]
        q(7:9) = [R*SIN(th), R*(1.0_wp - COS(th)), 0.0_wp]
        q(10:12) = [COS(th), SIN(th), 0.0_wp]
      CASE DEFAULT
        nm = 'skew 3D bent + stretched'
        q(1:3) = [0.0_wp, 0.0_wp, 0.0_wp]
        q(4:6) = [1.0_wp, 0.10_wp, -0.05_wp]
        q(7:9) = [1.03_wp, 0.12_wp, 0.07_wp]
        q(10:12) = [0.97_wp, -0.08_wp, 0.11_wp]
      END SELECT
      CALL CD_HermiteCable_Element(q, L, EA, EI, Ev, fint, Kt, es, em)
      CALL require(es == CD_HCABLE_OK, 'regime accepted ['//TRIM(nm)//']: '//TRIM(em))
      CALL fd_grad(q, g_fd)
      CALL fd_hess(q, K_fd)
      maxg = nan_max_abs(fint - g_fd)/MAX(1.0_wp, nan_max_abs(g_fd))
      maxK = nan_max_abs(Kt - K_fd)/MAX(1.0_wp, nan_max_abs(K_fd))
      WRITE (*, '(A,A,A,ES10.3,A,ES10.3)') '  [regime] ', TRIM(nm), &
        '  fint-FD=', maxg, '  Kt-FD=', maxK
      CALL require(maxg < 1.0e-6_wp, 'analytical fint matches central-FD <1e-6 ['//TRIM(nm)//']')
      CALL require(maxK < 1.0e-6_wp, 'analytical Kt matches central-FD <1e-6 ['//TRIM(nm)//']')
    END DO
  END SUBROUTINE check_ad_vs_fd_regimes

  SUBROUTINE check_rest_state()
    !! A straight unstretched element stores no energy and exerts no internal force.
    REAL(wp) :: q(12), Ev, fint(12), Kt(12, 12)
    INTEGER :: es
    CHARACTER(200) :: em
    q(1:3) = [0.0_wp, 0.0_wp, 0.0_wp]
    q(4:6) = [1.0_wp, 0.0_wp, 0.0_wp]
    q(7:9) = [L, 0.0_wp, 0.0_wp]
    q(10:12) = [1.0_wp, 0.0_wp, 0.0_wp]
    CALL CD_HermiteCable_Element(q, L, EA, EI, Ev, fint, Kt, es, em)
    CALL require(es == CD_HCABLE_OK, 'rest state accepted: '//TRIM(em))
    CALL require(ABS(Ev) < 1.0e-16_wp, 'rest-state energy is zero')
    CALL require(nan_max_abs(fint) < 1.0e-9_wp, 'rest-state internal force is zero')
  END SUBROUTINE check_rest_state

  SUBROUTINE check_axial_stretch()
    !! Uniform axial stretch eps stores exactly 1/2 EA eps^2 L, no bending.
    REAL(wp) :: e, q(12), Ev, fint(12), Kt(12, 12), Eth, resultant
    INTEGER :: es
    CHARACTER(200) :: em
    e = 0.01_wp
    q(1:3) = [0.0_wp, 0.0_wp, 0.0_wp]
    q(4:6) = [1.0_wp + e, 0.0_wp, 0.0_wp]
    q(7:9) = [L*(1.0_wp + e), 0.0_wp, 0.0_wp]
    q(10:12) = [1.0_wp + e, 0.0_wp, 0.0_wp]
    CALL CD_HermiteCable_Element(q, L, EA, 0.0_wp, Ev, fint, Kt, es, em)
    CALL require(es == CD_HCABLE_OK, 'axial stretch accepted: '//TRIM(em))
    Eth = 0.5_wp*EA*e**2*L
    CALL require(ABS(Ev - Eth)/Eth < 1.0e-9_wp, 'axial energy is exactly 1/2 EA eps^2 L')
    CALL CD_HermiteCable_Axial_Resultant(q, L, EA, 0.37_wp, resultant, es, em)
    CALL require(es == CD_HCABLE_OK, 'axial-resultant query accepted: '//TRIM(em))
    CALL require(ABS(resultant - EA*e) < 1.0e-10_wp*EA, 'axial resultant is EA times signed strain')
  END SUBROUTINE check_axial_stretch

  SUBROUTINE check_axial_resultant_range()
    !! Extrema of a non-uniform Hermite axial field are checked against a dense
    !! independent station sweep, including their material positions.
    INTEGER, PARAMETER :: NSCAN = 20000
    REAL(wp) :: q(12), nmin, umin, nmax, umax, nscan_min, uscan_min, nscan_max, uscan_max, nval, u
    INTEGER :: es, i
    CHARACTER(200) :: em

    q(1:3) = [0.0_wp, 0.0_wp, 0.0_wp]
    q(4:6) = [0.72_wp, 0.24_wp, 0.0_wp]
    q(7:9) = [1.03_wp, 0.08_wp, 0.0_wp]
    q(10:12) = [1.31_wp, -0.17_wp, 0.0_wp]
    CALL CD_HermiteCable_Axial_Resultant_Range(q, L, EA, nmin, umin, nmax, umax, es, em)
    CALL require(es == CD_HCABLE_OK, 'axial-resultant range accepted: '//TRIM(em))

    nscan_min = HUGE(1.0_wp); nscan_max = -HUGE(1.0_wp)
    uscan_min = 0.0_wp; uscan_max = 0.0_wp
    DO i = 0, NSCAN
      u = REAL(i, wp)/REAL(NSCAN, wp)
      CALL CD_HermiteCable_Axial_Resultant(q, L, EA, u, nval, es, em)
      CALL require(es == CD_HCABLE_OK, 'axial-resultant sweep station accepted: '//TRIM(em))
      IF (nval < nscan_min) THEN
        nscan_min = nval; uscan_min = u
      END IF
      IF (nval > nscan_max) THEN
        nscan_max = nval; uscan_max = u
      END IF
    END DO
    CALL require(ABS(nmin - nscan_min)/MAX(1.0_wp, ABS(nscan_min)) < 2.0e-5_wp, &
                 'continuous minimum axial resultant agrees with dense sweep')
    CALL require(ABS(nmax - nscan_max)/MAX(1.0_wp, ABS(nscan_max)) < 2.0e-5_wp, &
                 'continuous maximum axial resultant agrees with dense sweep')
    CALL require(ABS(umin - uscan_min) < 2.0e-3_wp, 'minimum axial-resultant station agrees with dense sweep')
    CALL require(ABS(umax - uscan_max) < 2.0e-3_wp, 'maximum axial-resultant station agrees with dense sweep')
  END SUBROUTINE check_axial_resultant_range

  SUBROUTINE check_curvature_diagnostic()
    !! The curvature output at u=1/2 reproduces the circular-arc 1/R to the cubic-Hermite
    !! geometric-approximation floor. A cubic Hermite under-curves a circular arc at its
    !! peak by O(theta^2) (theta = arc half-angle); at R=5, L=1 (theta=0.1) this is ~0.17%.
    !! The energy patch test captures the same curvature to 0.1% because it integrates.
    REAL(wp) :: R, th, q(12), curv
    INTEGER :: es
    CHARACTER(200) :: em
    R = 5.0_wp; th = L/R
    q(1:3) = [0.0_wp, 0.0_wp, 0.0_wp]
    q(4:6) = [1.0_wp, 0.0_wp, 0.0_wp]
    q(7:9) = [R*SIN(th), R*(1.0_wp - COS(th)), 0.0_wp]
    q(10:12) = [COS(th), SIN(th), 0.0_wp]
    CALL CD_HermiteCable_Curvature(q, L, 0.5_wp, curv, es, em)
    CALL require(es == CD_HCABLE_OK, 'curvature diagnostic accepted: '//TRIM(em))
    WRITE (*, '(A,ES14.7,A,ES14.7,A,ES10.3)') '  [diag] curv(u=1/2)=', curv, '  1/R=', 1.0_wp/R, &
      '  rel=', ABS(curv - 1.0_wp/R)/(1.0_wp/R)
    CALL require(ABS(curv - 1.0_wp/R)/(1.0_wp/R) < 3.0e-3_wp, 'curvature reproduces 1/R')
  END SUBROUTINE check_curvature_diagnostic

  SUBROUTINE check_continuous_curvature_peak()
    !! The public peak query must locate an interior extremum rather than selecting
    !! a node or an integration station.  A fine independent sweep is the oracle.
    INTEGER, PARAMETER :: NSCAN = 20000
    REAL(wp) :: q(12), peak, u_peak, scan_peak, scan_u, curvature, u
    INTEGER :: es, i
    CHARACTER(200) :: em

    q(1:3) = [0.0_wp, 0.0_wp, 0.0_wp]
    q(4:6) = [1.0_wp, 0.70_wp, 0.0_wp]
    q(7:9) = [1.0_wp, 0.0_wp, 0.0_wp]
    q(10:12) = [0.35_wp, -0.90_wp, 0.0_wp]
    CALL CD_HermiteCable_Peak_Curvature(q, L, peak, u_peak, es, em)
    CALL require(es == CD_HCABLE_OK, 'continuous peak-curvature query accepted: '//TRIM(em))

    scan_peak = -1.0_wp
    scan_u = 0.0_wp
    DO i = 0, NSCAN
      u = REAL(i, wp)/REAL(NSCAN, wp)
      CALL CD_HermiteCable_Curvature(q, L, u, curvature, es, em)
      CALL require(es == CD_HCABLE_OK, 'curvature sweep station accepted: '//TRIM(em))
      IF (curvature > scan_peak) THEN
        scan_peak = curvature
        scan_u = u
      END IF
    END DO
    CALL require(u_peak > 0.0_wp .AND. u_peak < 1.0_wp, 'curvature maximum lies inside the element')
    CALL require(ABS(peak - scan_peak)/scan_peak < 2.0e-5_wp, &
                 'adaptive continuous maximum agrees with independent dense sweep')
    CALL require(ABS(u_peak - scan_u) < 2.0e-3_wp, 'continuous maximum station agrees with dense sweep')
  END SUBROUTINE check_continuous_curvature_peak

  SUBROUTINE check_input_rejection()
    !! Degenerate / non-finite / bad-length inputs must fail closed.
    REAL(wp) :: q(12), Ev, fint(12), Kt(12, 12), curv
    INTEGER :: es
    CHARACTER(200) :: em
    q = 0.0_wp
    q(4:6) = [1.0_wp, 0.0_wp, 0.0_wp]; q(7:9) = [L, 0.0_wp, 0.0_wp]; q(10:12) = [1.0_wp, 0.0_wp, 0.0_wp]
    CALL CD_HermiteCable_Element(q, -1.0_wp, EA, EI, Ev, fint, Kt, es, em)
    CALL require(es /= CD_HCABLE_OK, 'reject nonpositive element length')
    CALL CD_HermiteCable_Element(q, L, -1.0_wp, EI, Ev, fint, Kt, es, em)
    CALL require(es /= CD_HCABLE_OK, 'reject negative EA')
    q(1) = IEEE_BADVALUE()
    CALL CD_HermiteCable_Element(q, L, EA, EI, Ev, fint, Kt, es, em)
    CALL require(es /= CD_HCABLE_OK, 'reject non-finite DOF')
    q(1) = 0.0_wp
    CALL CD_HermiteCable_Curvature(q, L, 1.5_wp, curv, es, em)
    CALL require(es /= CD_HCABLE_OK, 'reject u outside [0,1] in curvature diagnostic')
  END SUBROUTINE check_input_rejection

  SUBROUTINE check_mass_matrix()
    !! The consistent mass matrix I: analytical cubic-Hermite form, symmetry, rigid-translation
    !! kinetic energy, linearity in rho_a, and fail-closed inputs.
    REAL(wp), PARAMETER :: RHOA = 7.3_wp, LM = 2.5_wp
    REAL(wp) :: M(12, 12), M2(12, 12), M4ref(4, 4), qdot(12), Tk, maxasym, maxerr
    INTEGER :: es, i, j, c, s1, s2, g1, g2
    INTEGER, PARAMETER :: sd(4) = [0, 3, 6, 9]
    CHARACTER(200) :: em

    CALL CD_HermiteCable_Mass(RHOA, LM, M, es, em)
    CALL require(es == CD_HCABLE_OK, 'mass matrix accepted: '//TRIM(em))

    ! Analytical cubic-Hermite consistent mass (per component), DOF order [r1, m1, r2, m2]:
    !   M4 = rho_a L / 420 * [[156, 22L, 54, -13L],[22L,4L^2,13L,-3L^2],
    !                         [54,13L,156,-22L],[-13L,-3L^2,-22L,4L^2]].
    M4ref = RESHAPE([156.0_wp, 22.0_wp*LM, 54.0_wp, -13.0_wp*LM, &
                     22.0_wp*LM, 4.0_wp*LM*LM, 13.0_wp*LM, -3.0_wp*LM*LM, &
                     54.0_wp, 13.0_wp*LM, 156.0_wp, -22.0_wp*LM, &
                     -13.0_wp*LM, -3.0_wp*LM*LM, -22.0_wp*LM, 4.0_wp*LM*LM], [4, 4])
    M4ref = M4ref*RHOA*LM/420.0_wp

    ! Compare the scattered per-component blocks against the analytical 4x4.
    maxerr = 0.0_wp
    DO c = 1, 3
      DO s1 = 1, 4
        g1 = sd(s1) + c
        DO s2 = 1, 4
          g2 = sd(s2) + c
          maxerr = MAX(maxerr, ABS(M(g1, g2) - M4ref(s1, s2)))
        END DO
      END DO
    END DO
    CALL require(maxerr/nan_max_abs(M4ref) < 1.0e-12_wp, 'mass block matches analytical cubic-Hermite M4')

    ! Symmetry (Gauss-assembled -> exact to round-off).
    maxasym = 0.0_wp
    DO i = 1, 12
      DO j = 1, 12
        maxasym = MAX(maxasym, ABS(M(i, j) - M(j, i)))
      END DO
    END DO
    CALL require(maxasym < 1.0e-12_wp, 'mass matrix is symmetric')

    ! Off-component coupling is exactly zero (components interpolate independently).
    CALL require(ABS(M(1, 2)) + ABS(M(1, 5)) + ABS(M(3, 4)) < 1.0e-15_wp, 'no cross-component mass coupling')

    ! Rigid translation v=(vx,vy,vz), tangents unchanged: T = 1/2 qdot^T M qdot = 1/2 rho_a L |v|^2.
    qdot = 0.0_wp
    qdot(1:3) = [0.4_wp, -0.9_wp, 1.7_wp]      ! node-1 r velocity
    qdot(7:9) = [0.4_wp, -0.9_wp, 1.7_wp]      ! node-2 r velocity (m-DOFs stay zero)
    Tk = 0.5_wp*DOT_PRODUCT(qdot, MATMUL(M, qdot))
    CALL require(ABS(Tk - 0.5_wp*RHOA*LM*(0.4_wp**2 + 0.9_wp**2 + 1.7_wp**2)) < 1.0e-10_wp, &
                 'rigid-translation kinetic energy is 1/2 rho_a L |v|^2')

    ! Positive-definiteness proxy: every diagonal entry is strictly positive (the analytical
    ! cubic-Hermite mass is SPD; combined with the exact-form match this pins PD).
    CALL require(MINVAL([(M(i, i), i=1, 12)]) > 0.0_wp, 'mass diagonal is strictly positive')

    ! Linearity in rho_a.
    CALL CD_HermiteCable_Mass(2.0_wp*RHOA, LM, M2, es, em)
    CALL require(nan_max_abs(M2 - 2.0_wp*M) < 1.0e-12_wp*nan_max_abs(M), 'mass is linear in rho_a')

    ! Fail-closed inputs.
    CALL CD_HermiteCable_Mass(-1.0_wp, LM, M, es, em)
    CALL require(es /= CD_HCABLE_OK, 'reject negative rho_a')
    CALL CD_HermiteCable_Mass(RHOA, -1.0_wp, M, es, em)
    CALL require(es /= CD_HCABLE_OK, 'reject nonpositive mass-element length')
    CALL CD_HermiteCable_Mass(IEEE_BADVALUE(), LM, M, es, em)
    CALL require(es /= CD_HCABLE_OK, 'reject non-finite rho_a')
  END SUBROUTINE check_mass_matrix

  ! ---- FD oracle over the (exact) energy value ----
  FUNCTION energy(q) RESULT(E)
    REAL(wp), INTENT(IN) :: q(12)
    REAL(wp) :: E, f(12), K(12, 12)
    INTEGER :: es
    CHARACTER(200) :: em
    CALL CD_HermiteCable_Element(q, L, EA, EI, E, f, K, es, em)
  END FUNCTION energy

  SUBROUTINE fd_grad(q, g)
    REAL(wp), INTENT(IN) :: q(12)
    REAL(wp), INTENT(OUT) :: g(12)
    REAL(wp) :: qp(12), h
    INTEGER :: a
    DO a = 1, 12
      h = 1.0e-7_wp*MAX(1.0_wp, ABS(q(a)))
      qp = q; qp(a) = q(a) + h; g(a) = energy(qp)
      qp(a) = q(a) - h; g(a) = (g(a) - energy(qp))/(2*h)
    END DO
  END SUBROUTINE fd_grad

  SUBROUTINE fd_hess(q, KK)
    !! Central FD of the EXACT AD gradient (fint) -- single differencing of an exact
    !! derivative, not double-FD of the energy (which would be ~1e-2 noisy).
    REAL(wp), INTENT(IN) :: q(12)
    REAL(wp), INTENT(OUT) :: KK(12, 12)
    REAL(wp) :: qp(12), Ep, fp(12), fm(12), Kd(12, 12), h
    INTEGER :: a, es
    CHARACTER(200) :: em
    DO a = 1, 12
      h = 1.0e-7_wp*MAX(1.0_wp, ABS(q(a)))
      qp = q; qp(a) = q(a) + h; CALL CD_HermiteCable_Element(qp, L, EA, EI, Ep, fp, Kd, es, em)
      qp = q; qp(a) = q(a) - h; CALL CD_HermiteCable_Element(qp, L, EA, EI, Ep, fm, Kd, es, em)
      KK(:, a) = (fp - fm)/(2*h)
    END DO
  END SUBROUTINE fd_hess

  SUBROUTINE fd_grad_quad(q, axial_order, bending_order, gradient)
    REAL(wp), INTENT(IN) :: q(12)
    INTEGER, INTENT(IN) :: axial_order, bending_order
    REAL(wp), INTENT(OUT) :: gradient(12)
    REAL(wp) :: qp(12), ep, eminus, force(12), tangent(12, 12), h
    INTEGER :: a, es
    CHARACTER(200) :: em
    DO a = 1, 12
      h = 1.0e-7_wp*MAX(1.0_wp, ABS(q(a)))
      qp = q; qp(a) = q(a) + h
      CALL CD_HermiteCable_Element(qp, L, EA, EI, ep, force, tangent, es, em, &
                                   axial_quadrature_order=axial_order, bending_quadrature_order=bending_order)
      qp(a) = q(a) - h
      CALL CD_HermiteCable_Element(qp, L, EA, EI, eminus, force, tangent, es, em, &
                                   axial_quadrature_order=axial_order, bending_quadrature_order=bending_order)
      gradient(a) = (ep - eminus)/(2.0_wp*h)
    END DO
  END SUBROUTINE fd_grad_quad

  SUBROUTINE fd_hess_quad(q, axial_order, bending_order, tangent_fd)
    REAL(wp), INTENT(IN) :: q(12)
    INTEGER, INTENT(IN) :: axial_order, bending_order
    REAL(wp), INTENT(OUT) :: tangent_fd(12, 12)
    REAL(wp) :: qp(12), energy, force_plus(12), force_minus(12), tangent(12, 12), h
    INTEGER :: a, es
    CHARACTER(200) :: em
    DO a = 1, 12
      h = 1.0e-7_wp*MAX(1.0_wp, ABS(q(a)))
      qp = q; qp(a) = q(a) + h
      CALL CD_HermiteCable_Element(qp, L, EA, EI, energy, force_plus, tangent, es, em, &
                                   axial_quadrature_order=axial_order, bending_quadrature_order=bending_order)
      qp = q; qp(a) = q(a) - h
      CALL CD_HermiteCable_Element(qp, L, EA, EI, energy, force_minus, tangent, es, em, &
                                   axial_quadrature_order=axial_order, bending_quadrature_order=bending_order)
      tangent_fd(:, a) = (force_plus - force_minus)/(2.0_wp*h)
    END DO
  END SUBROUTINE fd_hess_quad

  FUNCTION IEEE_BADVALUE() RESULT(x)
    USE, INTRINSIC :: IEEE_ARITHMETIC, ONLY: IEEE_VALUE, IEEE_QUIET_NAN
    REAL(wp) :: x
    x = IEEE_VALUE(1.0_wp, IEEE_QUIET_NAN)
  END FUNCTION IEEE_BADVALUE

  SUBROUTINE require(cond, label)
    LOGICAL, INTENT(IN) :: cond
    CHARACTER(*), INTENT(IN) :: label
    IF (.NOT. cond) THEN
      WRITE (*, '(A,A,A)') 'MISMATCH [', label, ']: condition false'
      nfail = nfail + 1
    END IF
  END SUBROUTINE require

END PROGRAM test_hermite_cable
