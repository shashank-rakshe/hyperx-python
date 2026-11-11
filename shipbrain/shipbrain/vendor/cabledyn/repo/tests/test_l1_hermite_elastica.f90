! File: tests/test_l1_hermite_elastica.f90
! SPDX-License-Identifier: Apache-2.0
! Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
PROGRAM test_l1_hermite_elastica
  !! L1-4 large-deflection elastica on the PRODUCTION cubic-Hermite bending-cable path. A vertical
  !! cantilever (clamped at the base: r AND m fixed, tangent +z), tip transverse point load
  !! P = alpha^2 EI / L^2 applied through the generalized nodal-load vector, solved from the
  !! STRAIGHT seed with an OUTER load ramp (0.25/0.5/0.75/1.0 of P, warm-started). The ramp lives
  !! in the test because the solver's internal continuation scales EI and f_nodal by the SAME
  !! factor, which leaves the load parameter alpha^2 = P L^2 / EI -- and hence the deflected
  !! shape -- invariant: for a pure tip-load case it provides no geometric easing by construction.
  !! Tip position (x, z)/L vs the inextensional planar elastica (Bisshopp & Drucker 1945)
  !! at alpha^2 in {0.5, 1.0, 2.0} (theta_tip up to ~pi/4); EA = 1e6 EI/L^2 keeps the axial
  !! stretch (P/EA <= 2e-6) far below the 1e-3 gate. Reference tip positions are the
  !! elastica values (Bisshopp & Drucker 1945 elliptic integrals).
  USE CableDyn_Precision, ONLY: wp
  USE CableDyn_HermiteCableStatic, ONLY: CD_HermiteCable_Static_Solve, CD_HCSTAT_OK
  IMPLICIT NONE

  REAL(wp), PARAMETER :: L = 1.0_wp, EA = 1.0e8_wp, EI = 1.0e2_wp
  INTEGER, PARAMETER :: NE = 32
  REAL(wp), PARAMETER :: GATE = 1.0e-3_wp
  REAL(wp), PARAMETER :: RAMP(4) = [0.25_wp, 0.5_wp, 0.75_wp, 1.0_wp]
  INTEGER :: nfail

  nfail = 0
  ! alpha^2, x_tip/L, z_tip/L (elastica reference)
  CALL run_case(0.5_wp, 0.16214357565840026_wp, 0.984081037528981_wp)
  CALL run_case(1.0_wp, 0.30172077380023266_wp, 0.9435667637170584_wp)
  CALL run_case(2.0_wp, 0.4934574803964408_wp, 0.8393582791746794_wp)

  IF (nfail > 0) THEN
    WRITE (*, '(A,I0,A)') 'FAIL: ', nfail, ' assertion(s) failed'
    ERROR STOP 1
  END IF
  WRITE (*, '(A)') 'PASS: L1-4 cubic-Hermite cantilever matches the planar elastica'

CONTAINS

  SUBROUTINE run_case(alpha_sq, x_ref_norm, z_ref_norm)
    REAL(wp), INTENT(IN) :: alpha_sq, x_ref_norm, z_ref_norm
    INTEGER :: nn, i, k, es, iters, itot, ir
    REAL(wp) :: le, res, p_load, ex, ez
    REAL(wp), ALLOCATABLE :: l0(:), EAv(:), EIv(:), wv(:), seed(:), q(:), curv(:), fnod(:)
    INTEGER, ALLOCATABLE :: fixed(:)
    CHARACTER(300) :: em
    nn = NE + 1
    le = L/REAL(NE, wp)
    ALLOCATE (l0(NE), EAv(NE), EIv(NE), wv(NE), seed(6*nn), q(6*nn), curv(nn), fnod(6*nn))
    l0 = le; EAv = EA; EIv = EI; wv = 0.0_wp
    seed = 0.0_wp
    DO i = 1, nn
      seed(6*(i - 1) + 3) = REAL(i - 1, wp)*le    ! r_z: vertical rod, base at the origin
      seed(6*(i - 1) + 6) = 1.0_wp                ! m_z unit tangent (+z)
    END DO
    p_load = alpha_sq*EI/L**2
    ! clamp the base (r1 + m1); planar x-z (r_y, m_y everywhere); tip free
    ALLOCATE (fixed(6 + 2*(nn - 1)))
    fixed(1:6) = [1, 2, 3, 4, 5, 6]
    k = 6
    DO i = 2, nn
      fixed(k + 1) = 6*(i - 1) + 2; fixed(k + 2) = 6*(i - 1) + 5; k = k + 2
    END DO
    ! outer load ramp, warm-started (see header for why it is not the internal continuation)
    itot = 0
    DO ir = 1, SIZE(RAMP)
      fnod = 0.0_wp
      fnod(6*(nn - 1) + 1) = RAMP(ir)*p_load      ! tip transverse load, +x
      ! tol respects the EA-scaled assembly round-off floor (EA = 1e8 puts it near 1e-7
      ! relative); the residual-induced tip error at 1e-6 is ~7e-7 L, three orders under the gate.
      CALL CD_HermiteCable_Static_Solve(l0, EAv, EIv, wv, seed, fixed, -1.0e3_wp, 0.0_wp, &
                                        1, 150, 1.0e-6_wp, 0.7_wp, q, curv, res, iters, es, em, &
                                        f_nodal=fnod)
      CALL require(es == CD_HCSTAT_OK, 'elastica ramp stage converged: '//TRIM(em))
      IF (es /= CD_HCSTAT_OK) RETURN
      seed = q                                    ! warm start for the next load fraction
      itot = itot + iters
    END DO
    ex = ABS(q(6*(nn - 1) + 1)/L - x_ref_norm)
    ez = ABS(q(6*(nn - 1) + 3)/L - z_ref_norm)
    WRITE (*, '(A,F4.1,A,ES11.4,A,ES11.4,A,I0,A)') 'L1-4 alpha^2=', alpha_sq, &
      '  |x_tip/L - ref| = ', ex, '  |z_tip/L - ref| = ', ez, '   (', itot, ' iters)'
    CALL require(ex < GATE .AND. ez < GATE, 'tip position within 1e-3 of the elastica')
  END SUBROUTINE run_case

  SUBROUTINE require(cond, label)
    LOGICAL, INTENT(IN) :: cond
    CHARACTER(*), INTENT(IN) :: label
    IF (.NOT. cond) THEN
      WRITE (*, '(A,A)') 'MISMATCH: ', label
      nfail = nfail + 1
    END IF
  END SUBROUTINE require

END PROGRAM test_l1_hermite_elastica
