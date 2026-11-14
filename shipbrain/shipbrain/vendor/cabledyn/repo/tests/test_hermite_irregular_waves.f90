! File: tests/test_hermite_irregular_waves.f90
! SPDX-License-Identifier: Apache-2.0
! Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
PROGRAM test_hermite_irregular_waves
  !! Unit battery for the COMPONENT (irregular) wave path: the general component-table
  !! kinematics kernel (CD_Component_Wave_Kinematics) and its wiring into the Hermite
  !! dynamic model (CD_HermiteCable_Dyn_Set_Irregular_Waves).
  !!
  !!   1. KERNEL SUPERPOSITION (stretch off): an n-component evaluation equals the sum of
  !!      the n single-component evaluations exactly (linear kinematics are additive when
  !!      every component is evaluated at the same fixed z).
  !!   2. KERNEL TOTAL-ETA WHEELER: with stretching on, the kernel equals the sum of the
  !!      single-component evaluations at the MANUALLY Wheeler-mapped depth
  !!      z_eval = (z - eta_total) d / (d + eta_total) with stretching off -- i.e. ONE
  !!      mapping against the total elevation (the OrcaFlex irregular convention), not
  !!      per-component mappings.
  !!   3. SINGLE-COMPONENT REDUCTION: one component at phase 0 with amplitude H/2
  !!      reproduces the regular Airy kernel bit-for-bit.
  !!   4. MODEL EQUIVALENCE: a dynamic model driven under Set_Irregular_Waves with the
  !!      one-component table equals the same model under Set_Waves(H, T) --
  !!      trajectories compared step by step over two periods.
  !!   5. DISPLACEMENT: configuring the component field over a regular field (and the
  !!      reverse) leaves exactly the LAST configuration active (trajectory equality
  !!      with a fresh single-configuration model).
  !!   6. FAIL-CLOSED battery on the new entry point (length mismatch, empty table,
  !!      all-zero amplitudes, bad period/phase/depth/gravity, missing hydro config).
  !!   7. IRREGULAR SMOKE: a 12-component JONSWAP-like table on a hanging cable runs
  !!      bounded with every step converged (waves break the at-rest fixed point).
  !!   8. TAIL SUMS: on a 1500-component table of a 600 s record (the components of a WaterKin
  !!      elevation file), the kernel with tail_sums gives the same elevation bit for bit and
  !!      velocity, acceleration and dynamic pressure within round-off of the full sums, from
  !!      the surface to the seabed; above still water (stretching off) it sums every component.
  USE, INTRINSIC :: IEEE_ARITHMETIC, ONLY: IEEE_VALUE, IEEE_QUIET_NAN
  USE, INTRINSIC :: ISO_FORTRAN_ENV, ONLY: INT64
  USE CableDyn_Precision, ONLY: wp
  USE CableDyn_Hydro, ONLY: CD_Airy_Wave_Kinematics_Precomputed, CD_Component_Wave_Kinematics, &
                            CD_Solve_Dispersion_Wavenumber, CD_HYDRO_OK
  USE CableDyn_HermiteCableDynamic, ONLY: CD_HermiteCableDynType, CD_HermiteCable_Dyn_Init, &
                                          CD_HermiteCable_Dyn_Set_Drag, CD_HermiteCable_Dyn_Set_AddedMass, &
                                          CD_HermiteCable_Dyn_Set_Waves, CD_HermiteCable_Dyn_Set_Irregular_Waves, &
                                          CD_HermiteCable_Dyn_Step, CD_HermiteCable_Dyn_End, CD_HCDYN_OK
  IMPLICIT NONE

  REAL(wp), PARAMETER :: PI = 3.141592653589793_wp
  REAL(wp), PARAMETER :: GRAV = 9.80665_wp, DEPTH = 60.0_wp, RHOW = 1025.0_wp
  INTEGER :: nfail

  nfail = 0
  CALL kernel_superposition()
  CALL kernel_total_eta_wheeler()
  CALL kernel_profile_underflow()
  CALL kernel_single_component_reduction()
  CALL model_single_component_equivalence()
  CALL model_displacement()
  CALL fail_closed_battery()
  CALL irregular_smoke()
  CALL kernel_tail_sums()

  IF (nfail > 0) THEN
    WRITE (*, '(A,I0,A)') 'FAIL: ', nfail, ' assertion(s) failed'
    ERROR STOP 1
  END IF
  WRITE (*, '(A)') 'PASS: Hermite component (irregular) wave path unit battery'

CONTAINS

  INCLUDE 'nan_max_abs.inc'

  SUBROUTINE make_table(n, amp, per, ph)
    !! Deterministic multi-component table spread around a 10 s peak.
    INTEGER, INTENT(IN) :: n
    REAL(wp), INTENT(OUT) :: amp(n), per(n), ph(n)
    INTEGER :: i
    DO i = 1, n
      per(i) = 6.0_wp + 10.0_wp*REAL(i - 1, wp)/REAL(MAX(n - 1, 1), wp)     ! 6..16 s
      amp(i) = 0.4_wp*EXP(-0.5_wp*((per(i) - 10.0_wp)/3.0_wp)**2)           ! peaked at 10 s
      ph(i) = 137.0_wp*REAL(i, wp)                                          ! spread phases (deg)
    END DO
  END SUBROUTINE make_table

  SUBROUTINE disperse(per, k)
    REAL(wp), INTENT(IN) :: per(:)
    REAL(wp), INTENT(OUT) :: k(SIZE(per))
    INTEGER :: i, es
    CHARACTER(200) :: em
    DO i = 1, SIZE(per)
      CALL CD_Solve_Dispersion_Wavenumber(2.0_wp*PI/per(i), DEPTH, GRAV, k(i), es, em)
      CALL require(es == CD_HYDRO_OK, 'dispersion solve: '//TRIM(em))
    END DO
  END SUBROUTINE disperse

  SUBROUTINE kernel_superposition()
    INTEGER, PARAMETER :: N = 5
    REAL(wp) :: amp(N), per(N), phd(N), om(N), k(N), ph(N)
    REAL(wp) :: eta, u(3), a(3), eta1, u1(3), a1(3), etas, us(3), as_(3)
    REAL(wp) :: eta_fast, u_fast(3), a_fast(3), e2kd(N)
    INTEGER :: i, es
    CHARACTER(200) :: em
    CALL make_table(N, amp, per, phd)
    om = 2.0_wp*PI/per
    CALL disperse(per, k)
    ph = phd*PI/180.0_wp
    CALL CD_Component_Wave_Kinematics(3.7_wp, -1.2_wp, -8.0_wp, 41.3_wp, DEPTH, 25.0_wp, .FALSE., &
                                      om, k, amp, ph, eta, u, a, es, em)
    CALL require(es == CD_HYDRO_OK, 'superposition: n-component eval: '//TRIM(em))
    CALL CD_Component_Wave_Kinematics(3.7_wp, -1.2_wp, -8.0_wp, 41.3_wp, DEPTH, 25.0_wp, .FALSE., &
                                      om, k, amp, ph, eta_fast, u_fast, a_fast, es, em, inputs_validated=.TRUE.)
    CALL require(es == CD_HYDRO_OK, 'superposition: prevalidated eval: '//TRIM(em))
    CALL require(TRANSFER(eta_fast, 0_INT64) == TRANSFER(eta, 0_INT64) .AND. &
                 ALL(TRANSFER(u_fast, [0_INT64, 0_INT64, 0_INT64]) == &
                     TRANSFER(u, [0_INT64, 0_INT64, 0_INT64])) .AND. &
                 ALL(TRANSFER(a_fast, [0_INT64, 0_INT64, 0_INT64]) == &
                     TRANSFER(a, [0_INT64, 0_INT64, 0_INT64])), &
                 'superposition: prevalidated path is bit-identical')
    ! The caller's exp(-2 k depth) table replaces the per-call exponential bit for bit.
    DO i = 1, N
      e2kd(i) = EXP(-2.0_wp*(k(i)*DEPTH))
    END DO
    CALL CD_Component_Wave_Kinematics(3.7_wp, -1.2_wp, -8.0_wp, 41.3_wp, DEPTH, 25.0_wp, .FALSE., &
                                      om, k, amp, ph, eta_fast, u_fast, a_fast, es, em, exp_m2kd=e2kd)
    CALL require(es == CD_HYDRO_OK, 'superposition: exp table eval: '//TRIM(em))
    CALL require(TRANSFER(eta_fast, 0_INT64) == TRANSFER(eta, 0_INT64) .AND. &
                 ALL(TRANSFER(u_fast, [0_INT64, 0_INT64, 0_INT64]) == &
                     TRANSFER(u, [0_INT64, 0_INT64, 0_INT64])) .AND. &
                 ALL(TRANSFER(a_fast, [0_INT64, 0_INT64, 0_INT64]) == &
                     TRANSFER(a, [0_INT64, 0_INT64, 0_INT64])), &
                 'superposition: exp(-2kd) table path is bit-identical')
    CALL CD_Component_Wave_Kinematics(3.7_wp, -1.2_wp, -8.0_wp, 41.3_wp, DEPTH, 25.0_wp, .FALSE., &
                                      om, k, amp, ph, eta_fast, u_fast, a_fast, es, em, exp_m2kd=e2kd(1:N - 1))
    CALL require(es /= CD_HYDRO_OK, 'superposition: a short exp table fails closed')
    etas = 0.0_wp; us = 0.0_wp; as_ = 0.0_wp
    DO i = 1, N
      CALL CD_Component_Wave_Kinematics(3.7_wp, -1.2_wp, -8.0_wp, 41.3_wp, DEPTH, 25.0_wp, .FALSE., &
                                        om(i:i), k(i:i), amp(i:i), ph(i:i), eta1, u1, a1, es, em)
      CALL require(es == CD_HYDRO_OK, 'superposition: single-component eval')
      etas = etas + eta1; us = us + u1; as_ = as_ + a1
    END DO
    CALL require(ABS(eta - etas) <= 1.0e-14_wp*MAX(1.0_wp, ABS(eta)), 'superposition: eta additive')
    CALL require(ALL(ABS(u - us) <= 1.0e-13_wp) .AND. ALL(ABS(a - as_) <= 1.0e-13_wp), &
                 'superposition: kinematics additive (fixed z, stretch off)')
  END SUBROUTINE kernel_superposition

  SUBROUTINE kernel_profile_underflow()
    !! When exp(-2kd) underflows near the seabed, the lower exponential
    !! exp(-(kz+2kd)) can remain representable and must not be discarded.
    REAL(wp) :: om(1), k(1), amp(1), ph(1), eta, u(3), a(3), expected
    INTEGER :: es
    CHARACTER(200) :: em
    om = 1.0_wp; k = 400.0_wp; amp = 1.0_wp; ph = 0.0_wp
    CALL CD_Component_Wave_Kinematics(0.0_wp, 0.0_wp, -1.0_wp, 0.0_wp, 1.0_wp, 0.0_wp, .FALSE., &
                                      om, k, amp, ph, eta, u, a, es, em)
    expected = 2.0_wp*EXP(-400.0_wp)
    CALL require(es == CD_HYDRO_OK, 'profile underflow: finite evaluation: '//TRIM(em))
    CALL require(ABS(u(1) - expected) <= 1.0e-12_wp*expected, &
                 'profile underflow: representable lower exponential retained')
    CALL require(ABS(a(3)) <= TINY(1.0_wp), 'profile underflow: seabed sinh ratio remains zero')
  END SUBROUTINE kernel_profile_underflow

  SUBROUTINE kernel_tail_sums()
    INTEGER, PARAMETER :: N = 1500, NZ = 7
    ! (z, stretch): near the surface, mid-depth, deep, near and at the seabed; above still water
    REAL(wp), PARAMETER :: ZS(NZ) = [-0.5_wp, -5.0_wp, -20.0_wp, -45.0_wp, -59.999_wp, -60.0_wp, 0.3_wp]
    LOGICAL, PARAMETER :: STRETCH(NZ) = [.TRUE., .TRUE., .TRUE., .FALSE., .TRUE., .FALSE., .FALSE.]
    REAL(wp) :: om(N), k(N), amp(N), ph(N), tail(3, N), e2kd(N), w(3)
    REAL(wp) :: eta0, u0(3), a0(3), p0, eta1, u1(3), a1(3), p1, mag(3), ratio, ze
    INTEGER :: i, iz, es
    CHARACTER(200) :: em
    ! omega_i = i 2 pi/600 s up to 2 Hz: a peaked sea plus the leakage tail of a finite record
    DO i = 1, N
      om(i) = REAL(i, wp)*2.0_wp*PI/600.0_wp
      amp(i) = 0.3_wp*EXP(-0.5_wp*((om(i) - 0.63_wp)/0.12_wp)**2) + 1.0e-3_wp/REAL(i, wp)
      ph(i) = MODULO(2.399963_wp*REAL(i, wp)**2, 2.0_wp*PI)
      CALL CD_Solve_Dispersion_Wavenumber(om(i), DEPTH, GRAV, k(i), es, em)
      CALL require(es == CD_HYDRO_OK, 'tail sums: dispersion solve: '//TRIM(em))
      e2kd(i) = EXP(-2.0_wp*(k(i)*DEPTH))
    END DO
    tail(:, N) = amp(N)*[om(N), om(N)**2, om(N)**2/k(N)]
    DO i = N - 1, 1, -1
      tail(:, i) = tail(:, i + 1) + amp(i)*[om(i), om(i)**2, om(i)**2/k(i)]
    END DO
    DO iz = 1, NZ
      CALL CD_Component_Wave_Kinematics(12.0_wp, 3.0_wp, ZS(iz), 333.3_wp, DEPTH, 20.0_wp, STRETCH(iz), &
                                        om, k, amp, ph, eta0, u0, a0, es, em, inputs_validated=.TRUE., &
                                        pdyn=p0, exp_m2kd=e2kd)
      CALL require(es == CD_HYDRO_OK, 'tail sums: full sum: '//TRIM(em))
      CALL CD_Component_Wave_Kinematics(12.0_wp, 3.0_wp, ZS(iz), 333.3_wp, DEPTH, 20.0_wp, STRETCH(iz), &
                                        om, k, amp, ph, eta1, u1, a1, es, em, inputs_validated=.TRUE., &
                                        pdyn=p1, exp_m2kd=e2kd, tail_sums=tail)
      CALL require(es == CD_HYDRO_OK, 'tail sums: bounded sum: '//TRIM(em))
      CALL require(TRANSFER(eta1, 0_INT64) == TRANSFER(eta0, 0_INT64), 'tail sums: the elevation sums every component')
      IF (ZS(iz) > 0.0_wp) THEN
        CALL require(ALL(TRANSFER([u1, a1, p1], [0_INT64]) == TRANSFER([u0, a0, p0], [0_INT64])), &
                     'tail sums: above still water every component is summed')
        CYCLE
      END IF
      ! the magnitudes summed: a omega, a omega^2 and a omega^2/k times the cosh ratio
      ze = ZS(iz)
      IF (STRETCH(iz)) ze = (ZS(iz) - eta0)*DEPTH/(DEPTH + eta0)
      mag = 0.0_wp
      DO i = 1, N
        ratio = (EXP(k(i)*ze) + EXP(-k(i)*(ze + 2.0_wp*DEPTH)))/(1.0_wp - e2kd(i))
        w = amp(i)*[om(i), om(i)**2, om(i)**2/k(i)]
        mag = mag + w*ratio
      END DO
      CALL require(MAXVAL(ABS(u1 - u0)) <= 4.0_wp*EPSILON(1.0_wp)*mag(1) .AND. &
                   MAXVAL(ABS(a1 - a0)) <= 4.0_wp*EPSILON(1.0_wp)*mag(2) .AND. &
                   ABS(p1 - p0) <= 4.0_wp*EPSILON(1.0_wp)*mag(3), &
                   'tail sums: velocity, acceleration and pressure within round-off at z = '//fmt_z(ZS(iz)))
    END DO
    CALL CD_Component_Wave_Kinematics(12.0_wp, 3.0_wp, -5.0_wp, 333.3_wp, DEPTH, 20.0_wp, .TRUE., &
                                      om, k, amp, ph, eta1, u1, a1, es, em, tail_sums=tail(1:2, :))
    CALL require(es /= CD_HYDRO_OK, 'tail sums: a mis-shaped table fails closed')
  END SUBROUTINE kernel_tail_sums

  CHARACTER(16) FUNCTION fmt_z(z)
    REAL(wp), INTENT(IN) :: z
    WRITE (fmt_z, '(F0.3)') z
  END FUNCTION fmt_z

  SUBROUTINE kernel_total_eta_wheeler()
    INTEGER, PARAMETER :: N = 4
    REAL(wp) :: amp(N), per(N), phd(N), om(N), k(N), ph(N)
    REAL(wp) :: eta, u(3), a(3), eta1, u1(3), a1(3), z_eval, us(3), as_(3), z
    INTEGER :: i, es
    CHARACTER(200) :: em
    CALL make_table(N, amp, per, phd)
    om = 2.0_wp*PI/per
    CALL disperse(per, k)
    ph = phd*PI/180.0_wp
    z = -3.0_wp
    CALL CD_Component_Wave_Kinematics(0.0_wp, 0.0_wp, z, 7.9_wp, DEPTH, 0.0_wp, .TRUE., &
                                      om, k, amp, ph, eta, u, a, es, em)
    CALL require(es == CD_HYDRO_OK, 'total-eta Wheeler: stretched eval: '//TRIM(em))
    ! ONE mapping against the TOTAL eta, applied to every component
    z_eval = (z - eta)*DEPTH/(DEPTH + eta)
    us = 0.0_wp; as_ = 0.0_wp
    DO i = 1, N
      CALL CD_Component_Wave_Kinematics(0.0_wp, 0.0_wp, z_eval, 7.9_wp, DEPTH, 0.0_wp, .FALSE., &
                                        om(i:i), k(i:i), amp(i:i), ph(i:i), eta1, u1, a1, es, em)
      us = us + u1; as_ = as_ + a1
    END DO
    CALL require(ALL(ABS(u - us) <= 1.0e-13_wp) .AND. ALL(ABS(a - as_) <= 1.0e-13_wp), &
                 'total-eta Wheeler: one mapping of the total elevation, not per-component')
  END SUBROUTINE kernel_total_eta_wheeler

  SUBROUTINE kernel_single_component_reduction()
    REAL(wp), PARAMETER :: H = 2.6_wp, T = 9.0_wp
    REAL(wp) :: om(1), k(1), amp(1), ph(1)
    REAL(wp) :: eta_c, u_c(3), a_c(3), eta_a, u_a(3), a_a(3)
    INTEGER :: es
    CHARACTER(200) :: em
    om(1) = 2.0_wp*PI/T
    CALL CD_Solve_Dispersion_Wavenumber(om(1), DEPTH, GRAV, k(1), es, em)
    amp(1) = 0.5_wp*H
    ph(1) = 0.0_wp
    CALL CD_Component_Wave_Kinematics(5.1_wp, 2.2_wp, -6.5_wp, 13.4_wp, DEPTH, 205.0_wp, .TRUE., &
                                      om, k, amp, ph, eta_c, u_c, a_c, es, em)
    CALL require(es == CD_HYDRO_OK, 'reduction: component eval: '//TRIM(em))
    CALL CD_Airy_Wave_Kinematics_Precomputed(5.1_wp, 2.2_wp, -6.5_wp, 13.4_wp, H, om(1), k(1), &
                                             DEPTH, 205.0_wp, .TRUE., eta_a, u_a, a_a, es, em)
    CALL require(es == CD_HYDRO_OK, 'reduction: Airy eval')
    CALL require(ABS(eta_c - eta_a) <= 0.0_wp .AND. nan_max_abs(u_c - u_a) <= 0.0_wp .AND. &
                 nan_max_abs(a_c - a_a) <= 0.0_wp, &
                 'reduction: one component at phase 0 == the regular Airy kernel bit-for-bit')
  END SUBROUTINE kernel_single_component_reduction

  SUBROUTINE build_hanging_cable(model)
    !! A 10-element vertical hanging cable below the surface, both hydro configs on.
    TYPE(CD_HermiteCableDynType), INTENT(OUT) :: model
    INTEGER, PARAMETER :: NE = 10
    REAL(wp) :: l0(NE), EAv(NE), EIv(NE), rhoa(NE), w(NE), seed(6*(NE + 1))
    REAL(wp) :: hd(NE), c1(NE), c2(NE)
    INTEGER :: i, es, fixed(3)
    CHARACTER(300) :: em
    l0 = 2.0_wp; EAv = 1.0e7_wp; EIv = 5.0e3_wp; rhoa = 20.0_wp; w = 120.0_wp
    seed = 0.0_wp
    DO i = 1, NE + 1
      seed(6*(i - 1) + 1) = 0.0_wp
      seed(6*(i - 1) + 3) = -5.0_wp - 2.0_wp*REAL(i - 1, wp)
      seed(6*(i - 1) + 4) = 0.0_wp; seed(6*(i - 1) + 6) = -1.0_wp
    END DO
    fixed = [1, 2, 3]
    CALL CD_HermiteCable_Dyn_Init(model, l0, EAv, EIv, rhoa, w, seed, fixed, &
                                  -2000.0_wp, 0.0_wp, 0.8_wp, es, em)
    CALL require(es == CD_HCDYN_OK, 'hanging cable init: '//TRIM(em))
    hd = 0.15_wp; c1 = 1.2_wp; c2 = 0.1_wp
    CALL CD_HermiteCable_Dyn_Set_Drag(model, RHOW, hd, c1, c2, 0.0_wp, &
                                      [0.0_wp, 0.0_wp, 0.0_wp], es, em)
    CALL require(es == CD_HCDYN_OK, 'hanging cable drag: '//TRIM(em))
    c1 = 1.0_wp; c2 = 0.0_wp
    CALL CD_HermiteCable_Dyn_Set_AddedMass(model, RHOW, hd, c1, c2, 0.0_wp, es, em)
    CALL require(es == CD_HCDYN_OK, 'hanging cable added mass: '//TRIM(em))
  END SUBROUTINE build_hanging_cable

  SUBROUTINE run_steps(model, nstep, qout)
    TYPE(CD_HermiteCableDynType), INTENT(INOUT) :: model
    INTEGER, INTENT(IN) :: nstep
    REAL(wp), INTENT(OUT) :: qout(:)
    INTEGER :: s, es
    CHARACTER(300) :: em
    DO s = 1, nstep
      CALL CD_HermiteCable_Dyn_Step(model, 0.05_wp, 60, 1.0e-6_wp, es, em)
      CALL require(es == CD_HCDYN_OK, 'wave-driven step converged: '//TRIM(em))
      IF (es /= CD_HCDYN_OK) RETURN
    END DO
    qout = model%q
  END SUBROUTINE run_steps

  SUBROUTINE model_single_component_equivalence()
    REAL(wp), PARAMETER :: H = 1.8_wp, T = 8.0_wp
    TYPE(CD_HermiteCableDynType) :: ma, mb
    REAL(wp) :: qa(66), qb(66)
    INTEGER :: es
    CHARACTER(300) :: em
    CALL build_hanging_cable(ma)
    CALL CD_HermiteCable_Dyn_Set_Waves(ma, H, T, 30.0_wp, DEPTH, GRAV, es, em)
    CALL require(es == CD_HCDYN_OK, 'equivalence: Set_Waves: '//TRIM(em))
    CALL run_steps(ma, 320, qa)      ! two periods at dt = 0.05
    CALL CD_HermiteCable_Dyn_End(ma)
    CALL build_hanging_cable(mb)
    CALL CD_HermiteCable_Dyn_Set_Irregular_Waves(mb, [0.5_wp*H], [T], [0.0_wp], 30.0_wp, &
                                                 DEPTH, GRAV, es, em)
    CALL require(es == CD_HCDYN_OK, 'equivalence: Set_Irregular_Waves: '//TRIM(em))
    CALL run_steps(mb, 320, qb)
    CALL CD_HermiteCable_Dyn_End(mb)
    CALL require(nan_max_abs(qa - qb) <= 0.0_wp, 'equivalence: one-component table == regular '// &
                 'wave, bit-for-bit trajectory over two periods')
  END SUBROUTINE model_single_component_equivalence

  SUBROUTINE model_displacement()
    REAL(wp), PARAMETER :: H = 1.8_wp, T = 8.0_wp
    TYPE(CD_HermiteCableDynType) :: ma, mb
    REAL(wp) :: qa(66), qb(66), amp3(3), per3(3), ph3(3)
    INTEGER :: es
    CHARACTER(300) :: em
    amp3 = [0.3_wp, 0.5_wp, 0.2_wp]; per3 = [7.0_wp, 10.0_wp, 13.0_wp]
    ph3 = [10.0_wp, 120.0_wp, 260.0_wp]
    ! regular configured FIRST, then displaced by the component table
    CALL build_hanging_cable(ma)
    CALL CD_HermiteCable_Dyn_Set_Waves(ma, H, T, 0.0_wp, DEPTH, GRAV, es, em)
    CALL require(es == CD_HCDYN_OK, 'displacement: Set_Waves first')
    CALL CD_HermiteCable_Dyn_Set_Irregular_Waves(ma, amp3, per3, ph3, 0.0_wp, DEPTH, GRAV, es, em)
    CALL require(es == CD_HCDYN_OK, 'displacement: component over regular')
    CALL run_steps(ma, 100, qa)
    CALL CD_HermiteCable_Dyn_End(ma)
    ! the same component field configured directly
    CALL build_hanging_cable(mb)
    CALL CD_HermiteCable_Dyn_Set_Irregular_Waves(mb, amp3, per3, ph3, 0.0_wp, DEPTH, GRAV, es, em)
    CALL require(es == CD_HCDYN_OK, 'displacement: component direct')
    CALL run_steps(mb, 100, qb)
    CALL CD_HermiteCable_Dyn_End(mb)
    CALL require(nan_max_abs(qa - qb) <= 0.0_wp, 'displacement: component-over-regular == component-direct')
    ! and the reverse: regular displaces component
    CALL build_hanging_cable(ma)
    CALL CD_HermiteCable_Dyn_Set_Irregular_Waves(ma, amp3, per3, ph3, 0.0_wp, DEPTH, GRAV, es, em)
    CALL require(es == CD_HCDYN_OK, 'displacement: component first')
    CALL CD_HermiteCable_Dyn_Set_Waves(ma, H, T, 0.0_wp, DEPTH, GRAV, es, em)
    CALL require(es == CD_HCDYN_OK, 'displacement: regular over component')
    CALL run_steps(ma, 100, qa)
    CALL CD_HermiteCable_Dyn_End(ma)
    CALL build_hanging_cable(mb)
    CALL CD_HermiteCable_Dyn_Set_Waves(mb, H, T, 0.0_wp, DEPTH, GRAV, es, em)
    CALL require(es == CD_HCDYN_OK, 'displacement: regular direct')
    CALL run_steps(mb, 100, qb)
    CALL CD_HermiteCable_Dyn_End(mb)
    CALL require(nan_max_abs(qa - qb) <= 0.0_wp, 'displacement: regular-over-component == regular-direct')
  END SUBROUTINE model_displacement

  SUBROUTINE fail_closed_battery()
    TYPE(CD_HermiteCableDynType) :: m
    REAL(wp) :: nanv
    INTEGER :: es
    CHARACTER(300) :: em
    nanv = IEEE_VALUE(1.0_wp, IEEE_QUIET_NAN)
    CALL build_hanging_cable(m)
    CALL CD_HermiteCable_Dyn_Set_Irregular_Waves(m, [0.5_wp, 0.4_wp], [8.0_wp], [0.0_wp, 0.0_wp], &
                                                 0.0_wp, DEPTH, GRAV, es, em)
    CALL require(es /= CD_HCDYN_OK, 'fail-closed: length mismatch rejected')
    CALL CD_HermiteCable_Dyn_Set_Irregular_Waves(m, [REAL(wp) ::], [REAL(wp) ::], [REAL(wp) ::], &
                                                 0.0_wp, DEPTH, GRAV, es, em)
    CALL require(es /= CD_HCDYN_OK, 'fail-closed: empty table rejected')
    CALL CD_HermiteCable_Dyn_Set_Irregular_Waves(m, [0.0_wp, 0.0_wp], [8.0_wp, 9.0_wp], &
                                                 [0.0_wp, 0.0_wp], 0.0_wp, DEPTH, GRAV, es, em)
    CALL require(es /= CD_HCDYN_OK, 'fail-closed: all-zero amplitudes rejected')
    CALL CD_HermiteCable_Dyn_Set_Irregular_Waves(m, [0.5_wp], [-8.0_wp], [0.0_wp], &
                                                 0.0_wp, DEPTH, GRAV, es, em)
    CALL require(es /= CD_HCDYN_OK, 'fail-closed: negative period rejected')
    CALL CD_HermiteCable_Dyn_Set_Irregular_Waves(m, [0.5_wp], [8.0_wp], [nanv], &
                                                 0.0_wp, DEPTH, GRAV, es, em)
    CALL require(es /= CD_HCDYN_OK, 'fail-closed: non-finite phase rejected')
    CALL CD_HermiteCable_Dyn_Set_Irregular_Waves(m, [0.5_wp], [8.0_wp], [0.0_wp], &
                                                 0.0_wp, -DEPTH, GRAV, es, em)
    CALL require(es /= CD_HCDYN_OK, 'fail-closed: negative depth rejected')
    CALL CD_HermiteCable_Dyn_Set_Irregular_Waves(m, [0.5_wp], [8.0_wp], [0.0_wp], &
                                                 0.0_wp, DEPTH, -GRAV, es, em)
    CALL require(es /= CD_HCDYN_OK, 'fail-closed: negative gravity rejected')
    CALL CD_HermiteCable_Dyn_End(m)
    ! no hydro config at all -> waves must be rejected
    BLOCK
      INTEGER, PARAMETER :: NE = 4
      REAL(wp) :: l0(NE), EAv(NE), EIv(NE), rhoa(NE), w(NE), seed(6*(NE + 1))
      INTEGER :: i, fixed(3)
      l0 = 2.0_wp; EAv = 1.0e7_wp; EIv = 5.0e3_wp; rhoa = 20.0_wp; w = 120.0_wp
      seed = 0.0_wp
      DO i = 1, NE + 1
        seed(6*(i - 1) + 3) = -5.0_wp - 2.0_wp*REAL(i - 1, wp)
        seed(6*(i - 1) + 6) = -1.0_wp
      END DO
      fixed = [1, 2, 3]
      CALL CD_HermiteCable_Dyn_Init(m, l0, EAv, EIv, rhoa, w, seed, fixed, &
                                    -2000.0_wp, 0.0_wp, 0.8_wp, es, em)
      CALL require(es == CD_HCDYN_OK, 'fail-closed: bare init')
      CALL CD_HermiteCable_Dyn_Set_Irregular_Waves(m, [0.5_wp], [8.0_wp], [0.0_wp], &
                                                   0.0_wp, DEPTH, GRAV, es, em)
      CALL require(es /= CD_HCDYN_OK, 'fail-closed: component waves without any hydro config rejected')
      CALL CD_HermiteCable_Dyn_End(m)
    END BLOCK
  END SUBROUTINE fail_closed_battery

  SUBROUTINE irregular_smoke()
    INTEGER, PARAMETER :: N = 12
    TYPE(CD_HermiteCableDynType), ALLOCATABLE :: m   ! see DEVELOPMENT.md (gfortran 16 -Wuninitialized)
    REAL(wp) :: amp(N), per(N), ph(N), q0(66), qend(66)
    INTEGER :: es
    CHARACTER(300) :: em
    ALLOCATE (m)
    CALL make_table(N, amp, per, ph)
    CALL build_hanging_cable(m)
    q0 = m%q
    CALL CD_HermiteCable_Dyn_Set_Irregular_Waves(m, amp, per, ph, 15.0_wp, DEPTH, GRAV, es, em)
    CALL require(es == CD_HCDYN_OK, 'smoke: Set_Irregular_Waves: '//TRIM(em))
    CALL run_steps(m, 400, qend)     ! 20 s of a genuinely irregular sea
    CALL require(ALL(ABS(qend - q0) < 50.0_wp), 'smoke: bounded response under the component sea')
    CALL require(ANY(ABS(qend - q0) > 1.0e-4_wp), 'smoke: the component sea actually forces the cable')
    CALL CD_HermiteCable_Dyn_End(m)
  END SUBROUTINE irregular_smoke

  SUBROUTINE require(cond, label)
    LOGICAL, INTENT(IN) :: cond
    CHARACTER(*), INTENT(IN) :: label
    IF (.NOT. cond) THEN
      WRITE (*, '(A,A)') 'MISMATCH: ', label
      nfail = nfail + 1
    END IF
  END SUBROUTINE require

END PROGRAM test_hermite_irregular_waves
