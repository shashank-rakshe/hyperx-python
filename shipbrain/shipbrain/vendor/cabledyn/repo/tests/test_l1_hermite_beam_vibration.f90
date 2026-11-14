! File: tests/test_l1_hermite_beam_vibration.f90
! SPDX-License-Identifier: Apache-2.0
! Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
PROGRAM test_l1_hermite_beam_vibration
  !! L1-6 Euler-Bernoulli bending free-vibration on the PRODUCTION cubic-Hermite bending-cable
  !! path (generalised-alpha dynamics). A simply-supported beam -- the natural boundary condition
  !! for a position-based element: pinned translations, free material tangents = exactly
  !! moment-free ends -- is released from a small first-mode shape and the measured first-mode
  !! period is gated against the closed form omega_1 = (pi/L)^2 sqrt(EI / rho_a) at < 0.1%.
  !! rho_inf = 1 (no algorithmic damping) and dt = T1/500 keep the temporal dispersion
  !! ((omega dt)^2/12 ~ 1.3e-5) an order below the gate; ne = 16 puts the spatial (Kt, M) pencil
  !! bias far below it. The period is measured crossing-to-crossing over two full periods so the
  !! t = 0 transient is never multiplied up. The axial handle m_x and interior r_x are LEFT FREE:
  !! the physical unit tangent is dr/ds = (sqrt(1 - w'^2), 0, w'), so m_x must relax below 1 as
  !! the beam bends; clamping it over-constrains inextensibility and stiffens bending.
  USE CableDyn_Precision, ONLY: wp
  USE CableDyn_HermiteCableDynamic, ONLY: CD_HermiteCableDynType, CD_HermiteCable_Dyn_Init, &
                                          CD_HermiteCable_Dyn_Step, CD_HermiteCable_Dyn_End, &
                                          CD_HCDYN_OK
  IMPLICIT NONE

  REAL(wp), PARAMETER :: PI = 3.14159265358979323846_wp
  REAL(wp), PARAMETER :: LB = 10.0_wp, RHOA = 1.0_wp, EI = 100.0_wp, EA = 1.0e5_wp
  INTEGER, PARAMETER :: NE = 16, NN = NE + 1
  REAL(wp), PARAMETER :: AMP = 1.0e-3_wp
  REAL(wp), PARAMETER :: GATE = 1.0e-3_wp

  TYPE(CD_HermiteCableDynType) :: m
  REAL(wp), ALLOCATABLE :: l0(:), EAv(:), EIv(:), rhoAv(:), wv(:), seed(:)
  INTEGER, ALLOCATABLE :: fx(:)
  REAL(wp) :: omega1, T1, dt, tc(3), z_prev, z_cur, t, T_meas, relerr
  INTEGER :: es, s, mid_dof, nsteps, ncr, nfail
  CHARACTER(300) :: em

  nfail = 0
  omega1 = (PI/LB)**2*SQRT(EI/RHOA)
  T1 = 2.0_wp*PI/omega1
  dt = T1/500.0_wp
  mid_dof = 6*((NN + 1)/2 - 1) + 3            ! r_z at the midspan node (NN odd -> exact centre)

  CALL build_beam(AMP, l0, EAv, EIv, rhoAv, wv, seed, fx)
  CALL CD_HermiteCable_Dyn_Init(m, l0, EAv, EIv, rhoAv, wv, seed, fx, 0.0_wp, 0.0_wp, 1.0_wp, es, em)
  CALL require(es == CD_HCDYN_OK, 'init: '//TRIM(em))

  ! z_mid(t) = AMP cos(omega_1 t) + tiny higher-mode content. Time three downward zero
  ! crossings; T = (t_cross3 - t_cross1)/2.
  z_prev = m%q(mid_dof)
  t = 0.0_wp; ncr = 0; tc = 0.0_wp
  nsteps = NINT(2.4_wp*T1/dt)
  DO s = 1, nsteps
    CALL CD_HermiteCable_Dyn_Step(m, dt, 30, 1.0e-9_wp, es, em)
    IF (es /= CD_HCDYN_OK) THEN
      CALL require(.FALSE., 'step: '//TRIM(em)); EXIT
    END IF
    z_cur = m%q(mid_dof)
    t = t + dt
    IF (z_prev > 0.0_wp .AND. z_cur <= 0.0_wp .AND. ncr < 3) THEN
      ncr = ncr + 1
      tc(ncr) = (t - dt) + dt*z_prev/(z_prev - z_cur)
    END IF
    z_prev = z_cur
  END DO
  CALL require(ncr == 3, 'midspan completes two full periods (three downward crossings)')

  IF (ncr == 3) THEN
    T_meas = 0.5_wp*(tc(3) - tc(1))
    relerr = ABS(T_meas - T1)/T1
    WRITE (*, '(A,F10.6,A,F10.6,A,ES10.3)') 'L1-6 measured T1 = ', T_meas, ' s   exact = ', T1, &
      ' s   rel err = ', relerr
    CALL require(relerr < GATE, 'first-mode period within 0.1% of (pi/L)^2 sqrt(EI/rho_a)')
  END IF
  CALL CD_HermiteCable_Dyn_End(m)

  IF (nfail > 0) THEN
    WRITE (*, '(A,I0,A)') 'FAIL: ', nfail, ' assertion(s) failed'
    ERROR STOP 1
  END IF
  WRITE (*, '(A)') 'PASS: L1-6 Euler beam first-mode vibration on the cubic-Hermite path'

CONTAINS

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

END PROGRAM test_l1_hermite_beam_vibration
