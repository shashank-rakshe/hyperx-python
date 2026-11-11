! File: tests/test_l1_hermite_bending_patch.f90
! SPDX-License-Identifier: Apache-2.0
! Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
PROGRAM test_l1_hermite_bending_patch
  !! L1-2 bending patch on the PRODUCTION cubic-Hermite bending-cable element. Two parts:
  !!
  !! (a) AXIAL PATCH (machine precision): a uniformly stretched straight element stores exactly
  !!     1/2 EA eps^2 L -- constant strain lies inside the cubic's function space, so the quadrature
  !!     is exact and the energy matches to round-off (<1e-12 rel).
  !! (b) BENDING PATCH (refinement-exact): a circular arc of constant curvature kappa = 1/R. Constant
  !!     EXACT curvature |r' x r''|/|r'|^3 is NOT in the cubic's space, so the honest patch statement
  !!     is convergence: the total bending energy of the arc-interpolated mesh converges to
  !!     1/2 EI kappa^2 L_arc with observed order >= 3.5, reaching <1e-6 relative on the finest mesh.
  !!     (A rotation-DOF element can represent constant material curvature exactly; the
  !!     position-based element trades that for chart-free robustness -- the convergence-order gate
  !!     is the equivalent patch statement, and L1-10 measures the solve-level order.)
  USE CableDyn_Precision, ONLY: wp
  USE CableDyn_HermiteCable, ONLY: CD_HermiteCable_Element, CD_HCABLE_OK
  IMPLICIT NONE

  REAL(wp), PARAMETER :: EA = 1.0e6_wp, EI = 100.0_wp
  REAL(wp), PARAMETER :: R = 5.0_wp, ARC = 2.0_wp          ! arc length 2 m at radius 5 (theta = 0.4)
  INTEGER, PARAMETER :: NMESH = 4, MESHES(NMESH) = [4, 8, 16, 32]
  REAL(wp) :: errs(NMESH), hs(NMESH), order_fin, e_axial, eps
  INTEGER :: im, nfail

  nfail = 0

  ! (a) axial patch: exact at machine precision
  eps = 0.01_wp
  CALL axial_patch(eps, e_axial)
  WRITE (*, '(A,ES10.3)') 'L1-2a axial-patch energy rel err = ', e_axial
  CALL require(e_axial < 1.0e-12_wp, 'axial patch exact to round-off')

  ! (b) bending patch under refinement
  DO im = 1, NMESH
    CALL arc_energy_error(MESHES(im), errs(im))
    hs(im) = ARC/REAL(MESHES(im), wp)
  END DO
  order_fin = LOG(errs(NMESH - 1)/errs(NMESH))/LOG(hs(NMESH - 1)/hs(NMESH))
  WRITE (*, '(A)') 'L1-2b arc bending-energy rel error vs 1/2 EI kappa^2 L:'
  DO im = 1, NMESH
    WRITE (*, '(A,I3,A,ES11.4)') '   ne = ', MESHES(im), '   err = ', errs(im)
  END DO
  WRITE (*, '(A,F6.2)') 'L1-2b finest-interval observed order = ', order_fin
  CALL require(errs(NMESH) < 1.0e-6_wp, 'finest-mesh bending energy < 1e-6 relative')
  CALL require(order_fin >= 3.5_wp, 'bending-energy convergence order >= 3.5')

  IF (nfail > 0) THEN
    WRITE (*, '(A,I0,A)') 'FAIL: ', nfail, ' assertion(s) failed'
    ERROR STOP 1
  END IF
  WRITE (*, '(A)') 'PASS: L1-2 bending/axial patch on the cubic-Hermite element'

CONTAINS

  SUBROUTINE axial_patch(e, relerr)
    REAL(wp), INTENT(IN) :: e
    REAL(wp), INTENT(OUT) :: relerr
    REAL(wp) :: q(12), Ev, f(12), Kt(12, 12), Eth
    INTEGER :: es
    CHARACTER(200) :: em
    q = 0.0_wp
    q(4) = 1.0_wp + e                      ! m1_x
    q(7) = (1.0_wp + e)*1.0_wp             ! r2_x for L = 1
    q(10) = 1.0_wp + e                     ! m2_x
    CALL CD_HermiteCable_Element(q, 1.0_wp, EA, 0.0_wp, Ev, f, Kt, es, em)
    Eth = 0.5_wp*EA*e*e*1.0_wp
    relerr = ABS(Ev - Eth)/Eth
  END SUBROUTINE axial_patch

  SUBROUTINE arc_energy_error(ne, relerr)
    !! Total bending energy of a circular arc interpolated node-exactly (positions + unit tangents
    !! ON the arc), vs 1/2 EI kappa^2 * ARC.
    INTEGER, INTENT(IN) :: ne
    REAL(wp), INTENT(OUT) :: relerr
    REAL(wp) :: q(12), Ev, f(12), Kt(12, 12), le, th0, th1, Etot, Eth
    INTEGER :: e, es
    CHARACTER(200) :: em
    le = ARC/REAL(ne, wp)
    Etot = 0.0_wp
    DO e = 1, ne
      th0 = REAL(e - 1, wp)*le/R
      th1 = REAL(e, wp)*le/R
      q(1:3) = [R*SIN(th0), 0.0_wp, R*(1.0_wp - COS(th0))]
      q(4:6) = [COS(th0), 0.0_wp, SIN(th0)]
      q(7:9) = [R*SIN(th1), 0.0_wp, R*(1.0_wp - COS(th1))]
      q(10:12) = [COS(th1), 0.0_wp, SIN(th1)]
      CALL CD_HermiteCable_Element(q, le, 0.0_wp, EI, Ev, f, Kt, es, em)
      IF (es /= CD_HCABLE_OK) THEN
        relerr = HUGE(1.0_wp); RETURN
      END IF
      Etot = Etot + Ev
    END DO
    Eth = 0.5_wp*EI*(1.0_wp/R)**2*ARC
    relerr = ABS(Etot - Eth)/Eth
  END SUBROUTINE arc_energy_error

  SUBROUTINE require(cond, label)
    LOGICAL, INTENT(IN) :: cond
    CHARACTER(*), INTENT(IN) :: label
    IF (.NOT. cond) THEN
      WRITE (*, '(A,A)') 'MISMATCH: ', label
      nfail = nfail + 1
    END IF
  END SUBROUTINE require

END PROGRAM test_l1_hermite_bending_patch
