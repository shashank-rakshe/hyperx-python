! File: tests/test_hermite_strain_bound.f90
! SPDX-License-Identifier: Apache-2.0
! Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
PROGRAM test_hermite_strain_bound
  !! The cheap axial-strain lower bound that screens the dynamic tensile audit must never
  !! exceed any station value the dense audit samples, otherwise a screened element could
  !! hide a compression event:
  !!   A  bound <= sampled minimum of |r'| - 1 over many stretched, bent, skew 3-D elements
  !!      placed far from the origin (where coordinate rounding is largest),
  !!   B  the bound is tight for a straight, uniformly stretched element,
  !!   C  non-finite coordinates and a non-positive length return -HUGE (never screen).
  USE CableDyn_Precision, ONLY: wp
  USE CableDyn_HermiteCable, ONLY: CD_HCABLE_OK, CD_HermiteCable_Axial_Resultant_Range, &
                                   CD_HermiteCable_Axial_Strain_Lower_Bound
  USE, INTRINSIC :: IEEE_ARITHMETIC, ONLY: IEEE_VALUE, IEEE_QUIET_NAN
  IMPLICIT NONE

  INTEGER :: nfail, k, es, ncase
  INTEGER(KIND=8) :: seed
  REAL(wp) :: qr(12), L, lb, nmin, umin, nmax, umax, origin(3), dir(3), eps_axial, bend(3), twist(3)
  CHARACTER(200) :: em

  nfail = 0
  seed = 20260924_8
  ncase = 4000

  ! A: randomized elements; the dense sampler with EA = 1 returns the strain itself.
  DO k = 1, ncase
    L = 0.05_wp + 2.0_wp*urand()
    origin = 2000.0_wp*[urand(), urand(), -urand()]
    dir = [urand() - 0.5_wp, urand() - 0.5_wp, urand() - 0.5_wp]
    dir = dir/NORM2(dir)
    eps_axial = 2.0e-3_wp*(urand() - 0.5_wp)
    bend = 0.4_wp*[urand() - 0.5_wp, urand() - 0.5_wp, urand() - 0.5_wp]
    twist = 1.0e-3_wp*[urand() - 0.5_wp, urand() - 0.5_wp, urand() - 0.5_wp]
    qr(1:3) = origin
    qr(7:9) = origin + L*(1.0_wp + eps_axial)*dir
    qr(4:6) = (1.0_wp + eps_axial)*dir + bend + twist
    qr(10:12) = (1.0_wp + eps_axial)*dir - bend + 3.0_wp*twist
    lb = CD_HermiteCable_Axial_Strain_Lower_Bound(qr, L)
    CALL CD_HermiteCable_Axial_Resultant_Range(qr, L, 1.0_wp, nmin, umin, nmax, umax, es, em)
    IF (es /= CD_HCABLE_OK) THEN
      CALL report('A: dense sampler failed: '//TRIM(em))
    ELSE IF (.NOT. (lb <= nmin)) THEN
      CALL report('A: strain lower bound exceeds a sampled station value')
    END IF
  END DO

  ! B: straight uniform stretch: every station has the same strain.
  L = 0.25_wp
  origin = [1500.0_wp, -300.0_wp, -780.0_wp]
  dir = [0.6_wp, 0.0_wp, -0.8_wp]
  eps_axial = 3.0e-5_wp
  qr(1:3) = origin
  qr(7:9) = origin + L*(1.0_wp + eps_axial)*dir
  qr(4:6) = (1.0_wp + eps_axial)*dir
  qr(10:12) = qr(4:6)
  lb = CD_HermiteCable_Axial_Strain_Lower_Bound(qr, L)
  IF (.NOT. (lb <= eps_axial .AND. eps_axial - lb < 1.0e-8_wp)) CALL report('B: bound not tight for uniform stretch')

  ! C: fail-safe inputs.
  qr(5) = IEEE_VALUE(1.0_wp, IEEE_QUIET_NAN)
  IF (CD_HermiteCable_Axial_Strain_Lower_Bound(qr, L) > -HUGE(1.0_wp)) CALL report('C: NaN input screened')
  qr(5) = 0.0_wp
  IF (CD_HermiteCable_Axial_Strain_Lower_Bound(qr, 0.0_wp) > -HUGE(1.0_wp)) CALL report('C: zero length screened')

  IF (nfail > 0) THEN
    WRITE (*, '(A,I0,A)') 'FAIL: ', nfail, ' assertion(s) failed'
    ERROR STOP 1
  END IF
  WRITE (*, '(A,I0,A)') 'PASS: strain lower bound holds on ', ncase, ' randomized elements'

CONTAINS

  REAL(wp) FUNCTION urand()
    !! Deterministic Park-Miller generator in (0, 1): reproducible on every platform and
    !! free of integer overflow (the product stays below 2**46).
    seed = MOD(seed*16807_8, 2147483647_8)
    urand = REAL(seed, wp)/2147483647.0_wp
  END FUNCTION urand

  SUBROUTINE report(msg)
    CHARACTER(*), INTENT(IN) :: msg
    nfail = nfail + 1
    WRITE (*, '(A)') 'MISMATCH: '//msg
  END SUBROUTINE report

END PROGRAM test_hermite_strain_bound
