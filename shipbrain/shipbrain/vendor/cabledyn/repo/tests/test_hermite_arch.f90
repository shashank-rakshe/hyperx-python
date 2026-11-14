! File: tests/test_hermite_arch.f90
! SPDX-License-Identifier: Apache-2.0
! Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
PROGRAM test_hermite_arch
  !! Unit checks for the finite-EI cubic-Hermite arch seed. These tests pin the
  !! Tier-1 lazy-wave geometry contract: straight-line exactness, smooth arch lift,
  !! tangent-aligned Cosserat rotations, curvature diagnostics, and fail-closed input
  !! validation before the seed is used by equilibrium continuation.
  USE CableDyn_Precision, ONLY: wp
  USE CableDyn_HermiteArch, ONLY: CD_HARCH_OK, CD_FiniteEI_Hermite_Arch_Seed, &
                                  CD_FiniteEI_Hermite_Arch_Seed_LengthMatched, &
                                  CD_Hermite_Arch_Evaluate, CD_Hermite_Seed_Polyline_Length
  IMPLICIT NONE

  INTEGER, PARAMETER :: NE = 4, NN = NE + 1, NDOF = 6*NN
  REAL(wp), PARAMETER :: TOL = 1.0e-11_wp
  INTEGER :: nfail

  nfail = 0
  CALL check_straight_line_exactness()
  CALL check_lazy_wave_arch_seed()
  CALL check_endpoint_derivatives()
  CALL check_length_matched_seed()
  CALL check_input_rejection()

  IF (nfail > 0) THEN
    WRITE (*, '(A,I0,A)') 'FAIL: ', nfail, ' assertion(s) failed'
    ERROR STOP 1
  END IF
  WRITE (*, '(A)') 'PASS: cubic-Hermite finite-EI arch seed is robust'

CONTAINS

  INCLUDE 'nan_max_abs.inc'

  SUBROUTINE check_straight_line_exactness()
    !! A straight Hermite arch with unit horizontal tangents must be exactly collinear.
    REAL(wp) :: p0(3), p1(3), t0(3), t1(3), l0(NE)
    REAL(wp) :: q0(NDOF), nodes_ref(3, NN), arc(NN), curvature(NN), expected_x
    INTEGER :: nd, es
    CHARACTER(200) :: em

    p0 = [0.0_wp, 0.0_wp, -10.0_wp]
    p1 = [20.0_wp, 0.0_wp, -10.0_wp]
    t0 = [1.0_wp, 0.0_wp, 0.0_wp]
    t1 = [1.0_wp, 0.0_wp, 0.0_wp]
    l0 = 5.0_wp

    CALL CD_FiniteEI_Hermite_Arch_Seed(p0, p1, t0, t1, l0, 1.0_wp, q0, nodes_ref, arc, curvature, es, em)
    CALL require(es == CD_HARCH_OK, 'straight seed accepted: '//TRIM(em))
    DO nd = 1, NN
      expected_x = 5.0_wp*REAL(nd - 1, wp)
      CALL require(ABS(q0(6*nd - 5) - expected_x) < TOL, 'straight x station')
      CALL require(ABS(q0(6*nd - 4)) < TOL .AND. ABS(q0(6*nd - 3) + 10.0_wp) < TOL, &
                   'straight y/z station')
      CALL require(nan_max_abs(q0(6*nd - 2:6*nd)) < TOL, 'straight rotation is zero')
      CALL require(ABS(nodes_ref(1, nd) - expected_x) < TOL .AND. nan_max_abs(nodes_ref(2:3, nd)) < TOL, &
                   'straight reference station')
      CALL require(ABS(curvature(nd)) < TOL, 'straight curvature is zero')
    END DO
  END SUBROUTINE check_straight_line_exactness

  SUBROUTINE check_lazy_wave_arch_seed()
    !! A symmetric up/down tangent pair produces a lifted lazy-wave arch with finite curvature.
    REAL(wp) :: p0(3), p1(3), t0(3), t1(3), l0(NE)
    REAL(wp) :: q0(NDOF), nodes_ref(3, NN), arc(NN), curvature(NN)
    REAL(wp) :: x(3), dx(3), d2x(3), kappa, z_mid
    INTEGER :: es
    CHARACTER(200) :: em

    p0 = [0.0_wp, 0.0_wp, -40.0_wp]
    p1 = [20.0_wp, 0.0_wp, -40.0_wp]
    t0 = [1.0_wp, 0.0_wp, 1.0_wp]
    t1 = [1.0_wp, 0.0_wp, -1.0_wp]
    l0 = 6.0_wp

    CALL CD_FiniteEI_Hermite_Arch_Seed(p0, p1, t0, t1, l0, 1.0_wp, q0, nodes_ref, arc, curvature, es, em)
    CALL require(es == CD_HARCH_OK, 'lazy-wave seed accepted: '//TRIM(em))
    z_mid = q0(6*3 - 3)
    CALL require(z_mid > p0(3) + 4.0_wp, 'lazy-wave arch lifts above endpoints')
    CALL require(ABS(q0(1) - p0(1)) < TOL .AND. ABS(q0(3) - p0(3)) < TOL, 'End A position preserved')
    CALL require(ABS(q0(NDOF - 5) - p1(1)) < TOL .AND. ABS(q0(NDOF - 3) - p1(3)) < TOL, &
                 'End B position preserved')
    CALL require(nan_max_abs(q0(4:6)) > 0.1_wp .AND. nan_max_abs(q0(4:6)) < 1.0_wp, &
                 'End A rotation is finite and in chart')
    CALL require(nan_max_abs(q0(NDOF - 2:NDOF)) > 0.1_wp .AND. nan_max_abs(q0(NDOF - 2:NDOF)) < 1.0_wp, &
                 'End B rotation is finite and in chart')
    CALL require(ALL(curvature >= -TOL) .AND. MAXVAL(curvature) > 1.0e-3_wp, 'lazy-wave curvature is finite')
    CALL require(ABS(nodes_ref(1, NN) - SUM(l0)) < TOL .AND. nan_max_abs(nodes_ref(2:3, NN)) < TOL, &
                 'lazy-wave reference rod uses unstretched arc length')

    CALL CD_Hermite_Arch_Evaluate(p0, p1, t0, t1, SUM(l0), SUM(l0), 0.5_wp, x, dx, d2x, kappa, es, em)
    CALL require(es == CD_HARCH_OK, 'midpoint evaluate accepted')
    CALL require(ABS(x(1) - 10.0_wp) < TOL .AND. ABS(x(2)) < TOL, 'midpoint symmetry')
    CALL require(ABS(dx(3)) < TOL, 'midpoint tangent is horizontal by symmetry')
    CALL require(kappa > 1.0e-3_wp, 'midpoint curvature positive')
  END SUBROUTINE check_lazy_wave_arch_seed

  SUBROUTINE check_endpoint_derivatives()
    !! Hermite endpoint derivatives must match the supplied dimensional handles.
    REAL(wp) :: p0(3), p1(3), t0(3), t1(3), x(3), dx(3), d2x(3), kappa
    REAL(wp) :: h0, h1, t0u(3), t1u(3)
    INTEGER :: es
    CHARACTER(200) :: em

    p0 = [1.0_wp, -2.0_wp, -30.0_wp]
    p1 = [18.0_wp, 2.0_wp, -36.0_wp]
    t0 = [1.0_wp, 0.2_wp, 0.8_wp]
    t1 = [0.5_wp, -0.1_wp, -1.0_wp]
    h0 = 14.0_wp
    h1 = 9.0_wp
    t0u = t0/SQRT(DOT_PRODUCT(t0, t0))
    t1u = t1/SQRT(DOT_PRODUCT(t1, t1))

    CALL CD_Hermite_Arch_Evaluate(p0, p1, t0, t1, h0, h1, 0.0_wp, x, dx, d2x, kappa, es, em)
    CALL require(es == CD_HARCH_OK, 'endpoint derivative u=0 accepted')
    CALL require(nan_max_abs(x - p0) < TOL, 'Hermite endpoint A position exact')
    CALL require(nan_max_abs(dx - h0*t0u) < TOL, 'Hermite endpoint A tangent handle exact')
    CALL CD_Hermite_Arch_Evaluate(p0, p1, t0, t1, h0, h1, 1.0_wp, x, dx, d2x, kappa, es, em)
    CALL require(es == CD_HARCH_OK, 'endpoint derivative u=1 accepted')
    CALL require(nan_max_abs(x - p1) < TOL, 'Hermite endpoint B position exact')
    CALL require(nan_max_abs(dx - h1*t1u) < TOL, 'Hermite endpoint B tangent handle exact')
  END SUBROUTINE check_endpoint_derivatives

  SUBROUTINE check_length_matched_seed()
    !! The production lazy-wave helper must not initialize a shorter-than-rest arch.
    REAL(wp) :: p0(3), p1(3), t0(3), t1(3), l0(NE)
    REAL(wp) :: q0(NDOF), nodes_ref(3, NN), arc(NN), curvature(NN), handle_scale, seed_len
    INTEGER :: es
    CHARACTER(200) :: em

    p0 = [0.0_wp, 0.0_wp, -80.0_wp]
    p1 = [40.0_wp, 0.0_wp, -20.0_wp]
    t0 = [1.0_wp, 0.0_wp, 1.0_wp]
    t1 = [1.0_wp, 0.0_wp, -1.0_wp]
    l0 = 22.5_wp

    CALL CD_FiniteEI_Hermite_Arch_Seed_LengthMatched(p0, p1, t0, t1, l0, q0, nodes_ref, arc, curvature, &
                                                     handle_scale, es, em)
    CALL require(es == CD_HARCH_OK, 'length-matched seed accepted: '//TRIM(em))
    CALL require(handle_scale > 0.0_wp, 'length-matched handle scale positive')
    CALL CD_Hermite_Seed_Polyline_Length(q0, seed_len, es, em)
    CALL require(es == CD_HARCH_OK, 'length-matched seed length query accepted')
    CALL require(seed_len >= SUM(l0)*(1.0_wp - 1.0e-10_wp), 'length-matched seed not shorter than rest length')
    CALL require(ABS(seed_len - SUM(l0))/SUM(l0) < 1.0e-9_wp, 'length-matched seed close to rest length')
    CALL require(MAXVAL(curvature) > 1.0e-4_wp, 'length-matched lazy-wave curvature positive')
  END SUBROUTINE check_length_matched_seed

  SUBROUTINE check_input_rejection()
    !! Degenerate inputs must fail closed without producing a seed.
    REAL(wp) :: p0(3), p1(3), t0(3), t1(3), l0(NE)
    REAL(wp) :: q0(NDOF), nodes_ref(3, NN), arc(NN), curvature(NN)
    REAL(wp) :: x(3), dx(3), d2x(3), kappa
    INTEGER :: es
    CHARACTER(200) :: em

    p0 = [0.0_wp, 0.0_wp, 0.0_wp]
    p1 = [10.0_wp, 0.0_wp, 0.0_wp]
    t0 = [1.0_wp, 0.0_wp, 0.0_wp]
    t1 = [1.0_wp, 0.0_wp, 0.0_wp]
    l0 = 2.5_wp

    CALL CD_FiniteEI_Hermite_Arch_Seed(p0, p0, t0, t1, l0, 1.0_wp, q0, nodes_ref, arc, curvature, es, em)
    CALL require(es /= CD_HARCH_OK, 'reject coincident endpoints')
    CALL CD_FiniteEI_Hermite_Arch_Seed(p0, p1, [0.0_wp, 0.0_wp, 0.0_wp], t1, l0, 1.0_wp, q0, nodes_ref, &
                                       arc, curvature, es, em)
    CALL require(es /= CD_HARCH_OK, 'reject zero End A tangent')
    l0(2) = -1.0_wp
    CALL CD_FiniteEI_Hermite_Arch_Seed(p0, p1, t0, t1, l0, 1.0_wp, q0, nodes_ref, arc, curvature, es, em)
    CALL require(es /= CD_HARCH_OK, 'reject nonpositive element length')
    l0 = 2.5_wp
    CALL CD_Hermite_Arch_Evaluate(p0, p1, t0, t1, SUM(l0), SUM(l0), 1.25_wp, x, dx, d2x, kappa, es, em)
    CALL require(es /= CD_HARCH_OK, 'reject u outside unit interval')
    CALL CD_Hermite_Seed_Polyline_Length(q0(1:11), kappa, es, em)
    CALL require(es /= CD_HARCH_OK, 'reject malformed seed length input')
  END SUBROUTINE check_input_rejection

  SUBROUTINE require(cond, label)
    !! Record assertion failures without stopping at the first mismatch.
    LOGICAL, INTENT(IN) :: cond
    CHARACTER(*), INTENT(IN) :: label
    IF (.NOT. cond) THEN
      WRITE (*, '(A,A,A)') 'MISMATCH [', label, ']: condition false'
      nfail = nfail + 1
    END IF
  END SUBROUTINE require

END PROGRAM test_hermite_arch
