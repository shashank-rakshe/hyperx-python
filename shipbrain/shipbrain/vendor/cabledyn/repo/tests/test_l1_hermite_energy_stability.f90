! File: tests/test_l1_hermite_energy_stability.f90
! SPDX-License-Identifier: Apache-2.0
! Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
PROGRAM test_l1_hermite_energy_stability
  !! L1-8 long-run energy stability of the generalised-alpha integrator on the PRODUCTION
  !! cubic-Hermite bending-cable path. A simply-supported beam free vibration is run for 60
  !! first-mode periods at the production high-frequency-dissipative setting rho_inf = 0.8:
  !!
  !!  (a) NO GROWTH: every per-period PEAK of the total mechanical energy stays at or below the
  !!      initial energy (within 1e-6 sampling slack -- the peak of each period is read from
  !!      discrete samples, so it wobbles by O((2 omega dt)^2/8) of the intra-period energy
  !!      oscillation, which is far larger than the true per-period algorithmic loss);
  !!  (b) MONOTONE ON AVERAGE: the mean energy over the last five periods does not exceed the
  !!      mean over the first five (integer-period means average the intra-period oscillation
  !!      out, so this is robust where a peak-to-peak monotonicity test would alias);
  !!  (c) NEAR-CONSERVATION at rho_inf = 1 (trapezoidal, no algorithmic damping): the
  !!      peak-to-peak energy band over 10 periods stays under 0.5% at dt = T1/500.
  !!
  !! (a) + (b) assert the gen-alpha contract that matters for production runs -- algorithmic
  !! dissipation only, never injection -- without over-asserting the closed-form decay-rate
  !! envelope (a discrete-mode analysis, not reproduced here).
  USE CableDyn_Precision, ONLY: wp
  USE CableDyn_HermiteCableDynamic, ONLY: CD_HermiteCableDynType, CD_HermiteCable_Dyn_Init, &
                                          CD_HermiteCable_Dyn_Step, CD_HermiteCable_Dyn_Energy, &
                                          CD_HermiteCable_Dyn_End, CD_HCDYN_OK
  IMPLICIT NONE

  REAL(wp), PARAMETER :: PI = 3.14159265358979323846_wp
  REAL(wp), PARAMETER :: LB = 10.0_wp, RHOA = 1.0_wp, EI = 100.0_wp, EA = 1.0e5_wp
  INTEGER, PARAMETER :: NE = 10, NN = NE + 1
  REAL(wp), PARAMETER :: AMP = 1.0e-3_wp
  INTEGER, PARAMETER :: NPER = 60, SPP = 200        ! periods and steps per period (rho_inf = 0.8)
  INTEGER :: nfail

  nfail = 0
  CALL check_dissipative_run()
  CALL check_conservative_run()

  IF (nfail > 0) THEN
    WRITE (*, '(A,I0,A)') 'FAIL: ', nfail, ' assertion(s) failed'
    ERROR STOP 1
  END IF
  WRITE (*, '(A)') 'PASS: L1-8 gen-alpha energy is non-growing (rho_inf=0.8) and near-conserved (rho_inf=1)'

CONTAINS

  SUBROUTINE check_dissipative_run()
    TYPE(CD_HermiteCableDynType) :: m
    REAL(wp), ALLOCATABLE :: l0(:), EAv(:), EIv(:), rhoAv(:), wv(:), seed(:)
    INTEGER, ALLOCATABLE :: fx(:)
    REAL(wp) :: T1, dt, ke, se, E0, peaks(NPER), mean_first, mean_last, esum
    INTEGER :: es, p, s
    CHARACTER(300) :: em
    T1 = 2.0_wp*PI/((PI/LB)**2*SQRT(EI/RHOA))
    dt = T1/REAL(SPP, wp)
    CALL build_beam(AMP, l0, EAv, EIv, rhoAv, wv, seed, fx)
    CALL CD_HermiteCable_Dyn_Init(m, l0, EAv, EIv, rhoAv, wv, seed, fx, 0.0_wp, 0.0_wp, 0.8_wp, es, em)
    CALL require(es == CD_HCDYN_OK, 'dissipative init: '//TRIM(em))
    CALL CD_HermiteCable_Dyn_Energy(m, ke, se, es, em)
    E0 = ke + se
    mean_first = 0.0_wp; mean_last = 0.0_wp
    DO p = 1, NPER
      peaks(p) = 0.0_wp; esum = 0.0_wp
      DO s = 1, SPP
        CALL CD_HermiteCable_Dyn_Step(m, dt, 30, 1.0e-9_wp, es, em)
        IF (es /= CD_HCDYN_OK) THEN
          CALL require(.FALSE., 'dissipative step: '//TRIM(em)); RETURN
        END IF
        CALL CD_HermiteCable_Dyn_Energy(m, ke, se, es, em)
        peaks(p) = MAX(peaks(p), ke + se)
        esum = esum + ke + se
      END DO
      IF (p <= 5) mean_first = mean_first + esum/REAL(SPP, wp)
      IF (p > NPER - 5) mean_last = mean_last + esum/REAL(SPP, wp)
    END DO
    CALL CD_HermiteCable_Dyn_End(m)
    mean_first = mean_first/5.0_wp; mean_last = mean_last/5.0_wp
    WRITE (*, '(A,ES12.5,A,ES12.5,A,ES12.5)') 'L1-8 rho_inf=0.8: E0 = ', E0, &
      '   max per-period peak = ', MAXVAL(peaks), '   min = ', MINVAL(peaks)
    WRITE (*, '(A,ES12.5,A,ES12.5,A,ES10.3)') 'L1-8 mean E, periods 1-5 = ', mean_first, &
      '   periods 56-60 = ', mean_last, '   drop = ', (mean_first - mean_last)/E0
    CALL require(MAXVAL(peaks) <= E0*(1.0_wp + 1.0e-6_wp), &
                 'no per-period energy peak exceeds the initial energy (60 T)')
    CALL require(mean_last <= mean_first*(1.0_wp + 1.0e-9_wp), &
                 'mean energy over the last 5 periods does not exceed the first 5')
  END SUBROUTINE check_dissipative_run

  SUBROUTINE check_conservative_run()
    TYPE(CD_HermiteCableDynType) :: m
    REAL(wp), ALLOCATABLE :: l0(:), EAv(:), EIv(:), rhoAv(:), wv(:), seed(:)
    INTEGER, ALLOCATABLE :: fx(:)
    REAL(wp) :: T1, dt, ke, se, E0, Emax, Emin
    INTEGER :: es, s, nsteps
    CHARACTER(300) :: em
    T1 = 2.0_wp*PI/((PI/LB)**2*SQRT(EI/RHOA))
    dt = T1/500.0_wp
    CALL build_beam(AMP, l0, EAv, EIv, rhoAv, wv, seed, fx)
    CALL CD_HermiteCable_Dyn_Init(m, l0, EAv, EIv, rhoAv, wv, seed, fx, 0.0_wp, 0.0_wp, 1.0_wp, es, em)
    CALL require(es == CD_HCDYN_OK, 'conservative init: '//TRIM(em))
    CALL CD_HermiteCable_Dyn_Energy(m, ke, se, es, em)
    E0 = ke + se; Emax = E0; Emin = E0
    nsteps = 10*500
    DO s = 1, nsteps
      CALL CD_HermiteCable_Dyn_Step(m, dt, 30, 1.0e-9_wp, es, em)
      IF (es /= CD_HCDYN_OK) THEN
        CALL require(.FALSE., 'conservative step: '//TRIM(em)); RETURN
      END IF
      CALL CD_HermiteCable_Dyn_Energy(m, ke, se, es, em)
      Emax = MAX(Emax, ke + se); Emin = MIN(Emin, ke + se)
    END DO
    CALL CD_HermiteCable_Dyn_End(m)
    WRITE (*, '(A,ES12.5,A,ES10.3)') 'L1-8 rho_inf=1.0: E0 = ', E0, &
      '   peak-to-peak band over 10 T = ', (Emax - Emin)/E0
    CALL require((Emax - Emin)/E0 < 5.0e-3_wp, 'trapezoidal energy band < 0.5% over 10 periods')
  END SUBROUTINE check_conservative_run

  SUBROUTINE build_beam(amp, l0, EAv, EIv, rhoAv, wv, seed, fixed_dofs)
    !! Per-element arrays, a mode-1 seed of amplitude amp, and the simply-supported DOF set.
    REAL(wp), INTENT(IN) :: amp
    REAL(wp), ALLOCATABLE, INTENT(OUT) :: l0(:), EAv(:), EIv(:), rhoAv(:), wv(:), seed(:)
    INTEGER, ALLOCATABLE, INTENT(OUT) :: fixed_dofs(:)
    INTEGER :: i, k
    REAL(wp) :: hx, xi
    hx = LB/REAL(NE, wp)
    ALLOCATE (l0(NE), EAv(NE), EIv(NE), rhoAv(NE), wv(NE), seed(6*NN))
    l0 = hx; EAv = EA; EIv = EI; rhoAv = RHOA; wv = 0.0_wp
    seed = 0.0_wp
    DO i = 1, NN
      xi = REAL(i - 1, wp)*hx
      seed(6*(i - 1) + 1) = xi                              ! r_x
      seed(6*(i - 1) + 3) = amp*SIN(PI*xi/LB)               ! r_z
      seed(6*(i - 1) + 4) = 1.0_wp                          ! m_x
      seed(6*(i - 1) + 6) = amp*(PI/LB)*COS(PI*xi/LB)       ! m_z ~ dz/ds
    END DO
    ! planar x-z (r_y, m_y everywhere); both ends pinned in translation; tangents free
    ALLOCATE (fixed_dofs(2*NN + 4))
    k = 0
    DO i = 1, NN
      fixed_dofs(k + 1) = 6*(i - 1) + 2; fixed_dofs(k + 2) = 6*(i - 1) + 5; k = k + 2
    END DO
    fixed_dofs(k + 1) = 1; fixed_dofs(k + 2) = 3
    fixed_dofs(k + 3) = 6*(NN - 1) + 1; fixed_dofs(k + 4) = 6*(NN - 1) + 3
  END SUBROUTINE build_beam

  SUBROUTINE require(cond, label)
    LOGICAL, INTENT(IN) :: cond
    CHARACTER(*), INTENT(IN) :: label
    IF (.NOT. cond) THEN
      WRITE (*, '(A,A)') 'MISMATCH: ', label
      nfail = nfail + 1
    END IF
  END SUBROUTINE require

END PROGRAM test_l1_hermite_energy_stability
