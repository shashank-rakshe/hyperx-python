! File: tests/test_hermite_added_mass.f90
! SPDX-License-Identifier: Apache-2.0
! Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
PROGRAM test_hermite_added_mass
  !! Morison ADDED MASS on the finite-EI Hermite dynamic cable -- the fluid inertia that shifts a
  !! submerged cable's natural frequencies down, which sets the dynamic (fatigue) response. Gates:
  !!   A  the consistent added-mass element reduces to the analytical cubic-Hermite consistent mass
  !!      per Cartesian component on a straight element (x block scaled by rho A Cat, transverse
  !!      blocks by rho A Can), is symmetric, and is zero for a dry element,
  !!   B  PRIMARY (physics) GATE: the submerged simply-supported beam's measured wet first-mode
  !!      frequency matches the classic added-mass shift
  !!         omega_wet = omega_dry sqrt(rho_a / (rho_a + rho_w A Can)),
  !!   C  a straight submerged beam at rest with added mass on is still an at-rest fixed point,
  !!   D  fail-closed configuration (pre-init, negative coefficients, wrong array length).
  USE CableDyn_Precision, ONLY: wp
  USE CableDyn_HermiteCable, ONLY: CD_HermiteCable_Mass
  USE CableDyn_HermiteCableDynamic, ONLY: CD_HermiteCableDynType, CD_HermiteCable_Dyn_Init, &
                                          CD_HermiteCable_Dyn_Set_AddedMass, CD_HermiteCable_Dyn_Step, &
                                          CD_HermiteCable_Dyn_End, CD_HermiteCable_AddedMass_Element, &
                                          CD_HCDYN_OK
  USE, INTRINSIC :: IEEE_EXCEPTIONS, ONLY: IEEE_USUAL, IEEE_GET_HALTING_MODE, IEEE_SET_HALTING_MODE, IEEE_SET_FLAG
  IMPLICIT NONE
  LOGICAL :: fp_halt(3)   ! saved IEEE halting modes around deliberately non-finite inputs

  REAL(wp), PARAMETER :: PI = 3.14159265358979323846_wp
  REAL(wp), PARAMETER :: LB = 10.0_wp, RHOA = 1.0_wp, EI = 100.0_wp, EA = 1.0e5_wp
  REAL(wp), PARAMETER :: RHOW = 1025.0_wp, DIAM = 0.05_wp, CAN = 1.0_wp, CAT = 0.1_wp, WL = 100.0_wp
  INTEGER, PARAMETER :: NE = 10
  INTEGER :: nfail

  nfail = 0
  CALL check_element_analytical()
  CALL check_wet_frequency_shift()
  CALL check_fixed_point_with_added_mass()
  CALL check_fail_closed()

  IF (nfail > 0) THEN
    WRITE (*, '(A,I0,A)') 'FAIL: ', nfail, ' assertion(s) failed'
    ERROR STOP 1
  END IF
  WRITE (*, '(A)') 'PASS: Morison added mass on the Hermite dynamic cable -- analytical element + wet frequency shift'

CONTAINS

  INCLUDE 'nan_max_abs.inc'

  SUBROUTINE build_beam(amp, l0, EAv, EIv, rhoAv, wv, seed, fixed_dofs)
    !! Straight submerged beam along x with a mode-1 transverse (z) seed; planar x-z BCs, m_x free.
    REAL(wp), INTENT(IN) :: amp
    REAL(wp), ALLOCATABLE, INTENT(OUT) :: l0(:), EAv(:), EIv(:), rhoAv(:), wv(:), seed(:)
    INTEGER, ALLOCATABLE, INTENT(OUT) :: fixed_dofs(:)
    INTEGER :: nn, i, k
    REAL(wp) :: h, xi
    nn = NE + 1
    h = LB/REAL(NE, wp)
    ALLOCATE (l0(NE), EAv(NE), EIv(NE), rhoAv(NE), wv(NE), seed(6*nn))
    l0 = h; EAv = EA; EIv = EI; rhoAv = RHOA; wv = 0.0_wp
    seed = 0.0_wp
    DO i = 1, nn
      xi = REAL(i - 1, wp)*h
      seed(6*(i - 1) + 1) = xi
      seed(6*(i - 1) + 3) = amp*SIN(PI*xi/LB)
      seed(6*(i - 1) + 4) = 1.0_wp
      seed(6*(i - 1) + 6) = amp*(PI/LB)*COS(PI*xi/LB)
    END DO
    ALLOCATE (fixed_dofs(2*nn + 4))
    k = 0
    DO i = 1, nn
      fixed_dofs(k + 1) = 6*(i - 1) + 2; fixed_dofs(k + 2) = 6*(i - 1) + 5; k = k + 2
    END DO
    fixed_dofs(k + 1) = 1; fixed_dofs(k + 2) = 3
    fixed_dofs(k + 3) = 6*(nn - 1) + 1; fixed_dofs(k + 4) = 6*(nn - 1) + 3
  END SUBROUTINE build_beam

  SUBROUTINE check_element_analytical()
    !! Straight submerged element along x: the tangent is x-hat everywhere, so the added mass is
    !! block-diagonal per component with the x block = the cubic-Hermite consistent mass at density
    !! rho A Cat and the y/z blocks at rho A Can. Also: symmetric; a dry element gives exactly zero.
    REAL(wp), PARAMETER :: LM = 2.5_wp
    REAL(wp) :: qe(12), Ma(12, 12), Mref_n(12, 12), Mref_t(12, 12), area, maxerr, maxasym
    INTEGER :: es, i, j, c, s1, s2, g1, g2
    INTEGER, PARAMETER :: sd(4) = [0, 3, 6, 9]
    CHARACTER(300) :: em
    area = 0.25_wp*PI*DIAM*DIAM
    ! Straight element of length LM along x: unit material tangents m = (1,0,0) (the H shapes carry
    ! the length scale), end node at x = LM.
    qe = [0.0_wp, 0.0_wp, 0.0_wp, 1.0_wp, 0.0_wp, 0.0_wp, LM, 0.0_wp, 0.0_wp, 1.0_wp, 0.0_wp, 0.0_wp]
    CALL CD_HermiteCable_AddedMass_Element(qe, LM, WL, RHOW, DIAM, CAN, CAT, Ma, es, em)
    CALL require(es == CD_HCDYN_OK, 'added-mass element accepted: '//TRIM(em))
    ! Reference blocks from the (gated) consistent structural mass at the equivalent densities.
    CALL CD_HermiteCable_Mass(RHOW*area*CAN, LM, Mref_n, es, em)
    CALL CD_HermiteCable_Mass(RHOW*area*CAT, LM, Mref_t, es, em)
    maxerr = 0.0_wp
    DO c = 1, 3
      DO s1 = 1, 4
        g1 = sd(s1) + c
        DO s2 = 1, 4
          g2 = sd(s2) + c
          IF (c == 1) THEN
            maxerr = MAX(maxerr, ABS(Ma(g1, g2) - Mref_t(g1, g2)))
          ELSE
            maxerr = MAX(maxerr, ABS(Ma(g1, g2) - Mref_n(g1, g2)))
          END IF
        END DO
      END DO
    END DO
    CALL require(maxerr/nan_max_abs(Mref_n) < 1.0e-12_wp, 'straight-element added mass matches the analytical blocks')
    maxasym = 0.0_wp
    DO i = 1, 12
      DO j = 1, 12
        maxasym = MAX(maxasym, ABS(Ma(i, j) - Ma(j, i)))
      END DO
    END DO
    CALL require(maxasym < 1.0e-12_wp, 'added-mass element is symmetric')
    ! Dry element (waterline far below): exactly zero.
    CALL CD_HermiteCable_AddedMass_Element(qe, LM, -100.0_wp, RHOW, DIAM, CAN, CAT, Ma, es, em)
    CALL require(es == CD_HCDYN_OK .AND. nan_max_abs(Ma) <= 0.0_wp, 'dry element carries zero added mass')
  END SUBROUTINE check_element_analytical

  SUBROUTINE check_wet_frequency_shift()
    !! PRIMARY GATE: the wet first-mode frequency of the submerged simply-supported beam matches
    !! omega_wet = omega_dry sqrt(rho_a/(rho_a + rho_w A Can)) -- measured crossing-to-crossing.
    TYPE(CD_HermiteCableDynType) :: m
    REAL(wp), ALLOCATABLE :: l0(:), EAv(:), EIv(:), rhoAv(:), wv(:), seed(:)
    INTEGER, ALLOCATABLE :: fx(:)
    REAL(wp), PARAMETER :: AMP = 1.0e-3_wp, DT = 0.02_wp
    REAL(wp) :: dv(NE), cn(NE), ct(NE)
    REAL(wp) :: omega_dry, T_wet_th, ma_perlen, tc(3), z_prev, z_cur, t, T_meas, relerr
    INTEGER :: es, s, mid_dof, nn, nsteps, ncr
    CHARACTER(300) :: em

    nn = NE + 1
    mid_dof = 6*((nn + 1)/2 - 1) + 3
    omega_dry = (PI/LB)**2*SQRT(EI/RHOA)
    ma_perlen = RHOW*0.25_wp*PI*DIAM*DIAM*CAN
    T_wet_th = (2.0_wp*PI/omega_dry)/SQRT(RHOA/(RHOA + ma_perlen))   ! T_wet = T_dry / ratio

    CALL build_beam(AMP, l0, EAv, EIv, rhoAv, wv, seed, fx)
    CALL CD_HermiteCable_Dyn_Init(m, l0, EAv, EIv, rhoAv, wv, seed, fx, 0.0_wp, 0.0_wp, 1.0_wp, es, em)
    CALL require(es == CD_HCDYN_OK, 'wet-frequency init: '//TRIM(em))
    dv = DIAM; cn = CAN; ct = CAT
    CALL CD_HermiteCable_Dyn_Set_AddedMass(m, RHOW, dv, cn, ct, WL, es, em)
    CALL require(es == CD_HCDYN_OK, 'added mass accepted: '//TRIM(em))

    z_prev = m%q(mid_dof)
    t = 0.0_wp; ncr = 0; tc = 0.0_wp
    nsteps = NINT(2.4_wp*T_wet_th/DT)
    DO s = 1, nsteps
      CALL CD_HermiteCable_Dyn_Step(m, DT, 30, 1.0e-8_wp, es, em)
      IF (es /= CD_HCDYN_OK) THEN
        CALL require(.FALSE., 'wet-frequency step: '//TRIM(em)); EXIT
      END IF
      z_cur = m%q(mid_dof)
      t = t + DT
      IF (z_prev > 0.0_wp .AND. z_cur <= 0.0_wp .AND. ncr < 3) THEN
        ncr = ncr + 1
        tc(ncr) = (t - DT) + DT*z_prev/(z_prev - z_cur)
      END IF
      z_prev = z_cur
    END DO
    CALL require(ncr == 3, 'midspan completes two wet periods')
    IF (ncr == 3) THEN
      T_meas = 0.5_wp*(tc(3) - tc(1))
      relerr = ABS(T_meas - T_wet_th)/T_wet_th
      WRITE (*, '(A,F10.6,A,F10.6,A,F7.3,A)') '  [added mass] measured T_wet = ', T_meas, &
        ' s   theory = ', T_wet_th, ' s   err = ', 100.0_wp*relerr, '%'
      CALL require(relerr < 0.005_wp, 'wet period matches omega_dry sqrt(m/(m+ma)) within 0.5%')
    END IF
    CALL CD_HermiteCable_Dyn_End(m)
    DEALLOCATE (l0, EAv, EIv, rhoAv, wv, seed, fx)
  END SUBROUTINE check_wet_frequency_shift

  SUBROUTINE check_fixed_point_with_added_mass()
    !! A straight submerged beam at rest stays at rest with added mass enabled.
    TYPE(CD_HermiteCableDynType) :: m
    REAL(wp), ALLOCATABLE :: l0(:), EAv(:), EIv(:), rhoAv(:), wv(:), seed(:)
    INTEGER, ALLOCATABLE :: fx(:)
    REAL(wp) :: dv(NE), cn(NE), ct(NE), maxv
    INTEGER :: es, s
    CHARACTER(300) :: em
    CALL build_beam(0.0_wp, l0, EAv, EIv, rhoAv, wv, seed, fx)
    CALL CD_HermiteCable_Dyn_Init(m, l0, EAv, EIv, rhoAv, wv, seed, fx, 0.0_wp, 0.0_wp, 0.9_wp, es, em)
    CALL require(es == CD_HCDYN_OK, 'fixed-point init: '//TRIM(em))
    dv = DIAM; cn = CAN; ct = CAT
    CALL CD_HermiteCable_Dyn_Set_AddedMass(m, RHOW, dv, cn, ct, WL, es, em)
    CALL require(es == CD_HCDYN_OK, 'fixed-point added mass: '//TRIM(em))
    CALL require(nan_max_abs(m%a) < 1.0e-8_wp, 'rest acceleration stays ~zero with added mass')
    maxv = 0.0_wp
    DO s = 1, 20
      CALL CD_HermiteCable_Dyn_Step(m, 0.05_wp, 30, 1.0e-9_wp, es, em)
      IF (es /= CD_HCDYN_OK) THEN
        CALL require(.FALSE., 'fixed-point step: '//TRIM(em)); EXIT
      END IF
      maxv = MAX(maxv, nan_max_abs(m%v))
    END DO
    CALL require(maxv < 1.0e-9_wp, 'at-rest fixed point preserved with added mass on')
    CALL CD_HermiteCable_Dyn_End(m)
    DEALLOCATE (l0, EAv, EIv, rhoAv, wv, seed, fx)
  END SUBROUTINE check_fixed_point_with_added_mass

  SUBROUTINE check_fail_closed()
    !! Bad added-mass configuration is rejected; the model state is untouched by rejected calls.
    TYPE(CD_HermiteCableDynType) :: m
    REAL(wp), ALLOCATABLE :: l0(:), EAv(:), EIv(:), rhoAv(:), wv(:), seed(:)
    INTEGER, ALLOCATABLE :: fx(:)
    REAL(wp) :: dv(NE), cn(NE), ct(NE)
    INTEGER :: es
    CHARACTER(300) :: em
    dv = DIAM; cn = CAN; ct = CAT
    CALL CD_HermiteCable_Dyn_Set_AddedMass(m, RHOW, dv, cn, ct, WL, es, em)
    CALL require(es /= CD_HCDYN_OK, 'reject Set_AddedMass on an uninitialised model')
    CALL build_beam(0.0_wp, l0, EAv, EIv, rhoAv, wv, seed, fx)
    CALL CD_HermiteCable_Dyn_Init(m, l0, EAv, EIv, rhoAv, wv, seed, fx, 0.0_wp, 0.0_wp, 0.9_wp, es, em)
    CALL require(es == CD_HCDYN_OK, 'init for added-mass fail-closed')
    CALL CD_HermiteCable_Dyn_Set_AddedMass(m, -1.0_wp, dv, cn, ct, WL, es, em)
    CALL require(es /= CD_HCDYN_OK, 'reject nonpositive rho_w')
    cn(1) = -0.5_wp
    CALL CD_HermiteCable_Dyn_Set_AddedMass(m, RHOW, dv, cn, ct, WL, es, em)
    CALL require(es /= CD_HCDYN_OK, 'reject negative Can')
    cn(1) = CAN
    CALL CD_HermiteCable_Dyn_Set_AddedMass(m, RHOW, dv(1:NE - 1), cn, ct, WL, es, em)
    CALL require(es /= CD_HCDYN_OK, 'reject wrong-length diam array')
    CALL require(.NOT. m%has_am, 'rejected configuration does not enable added mass')
    CALL CD_HermiteCable_Dyn_End(m)
    DEALLOCATE (l0, EAv, EIv, rhoAv, wv, seed, fx)
    ! The public element fails closed when a finite but huge density overflows the accumulation,
    ! instead of returning OK with a non-finite matrix.
    CALL check_overflow_element()
    CALL check_global_scatter_overflow()
  END SUBROUTINE check_fail_closed

  SUBROUTINE check_overflow_element()
    REAL(wp) :: qe(12), Ma(12, 12)
    INTEGER :: es
    CHARACTER(300) :: em
    qe = [0.0_wp, 0.0_wp, 0.0_wp, 1.0_wp, 0.0_wp, 0.0_wp, 1.0_wp, 0.0_wp, 0.0_wp, 1.0_wp, 0.0_wp, 0.0_wp]
    ! deliberately non-finite or overflowing input: must not halt a trapping build
    CALL IEEE_GET_HALTING_MODE(IEEE_USUAL, fp_halt)
    CALL IEEE_SET_HALTING_MODE(IEEE_USUAL, .FALSE.)
    CALL CD_HermiteCable_AddedMass_Element(qe, 1.0_wp, WL, 1.0e300_wp, 1.0e30_wp, CAN, CAT, Ma, es, em)
    CALL IEEE_SET_FLAG(IEEE_USUAL, .FALSE.)
    CALL IEEE_SET_HALTING_MODE(IEEE_USUAL, fp_halt)
    CALL require(es /= CD_HCDYN_OK, 'element fails closed on an overflowed added-mass accumulation')
  END SUBROUTINE check_overflow_element

  SUBROUTINE check_global_scatter_overflow()
    !! Each three-metre element matrix remains finite, but its two shared-node
    !! translational diagonal contributions overflow when scattered globally.
    INTEGER, PARAMETER :: NE_OV = 2, NN_OV = 3, NDOF_OV = 18
    TYPE(CD_HermiteCableDynType) :: m
    REAL(wp) :: l0(NE_OV), eav(NE_OV), eiv(NE_OV), rhoav(NE_OV), wv(NE_OV), seed(NDOF_OV)
    REAL(wp) :: diamv(NE_OV), can_v(NE_OV), cat_v(NE_OV), d_unit_area
    INTEGER :: fixed(NDOF_OV), es, i
    CHARACTER(300) :: em

    l0 = 3.0_wp
    eav = EA
    eiv = EI
    rhoav = 1.0_wp
    wv = 0.0_wp
    seed = 0.0_wp
    DO i = 1, NN_OV
      seed(6*i - 5) = 3.0_wp*REAL(i - 1, wp)
      seed(6*i - 2) = 1.0_wp
    END DO
    fixed = [(i, i=1, NDOF_OV)]
    CALL CD_HermiteCable_Dyn_Init(m, l0, eav, eiv, rhoav, wv, seed, fixed, &
                                  -100.0_wp, 0.0_wp, 0.9_wp, es, em)
    CALL require(es == CD_HCDYN_OK, 'global-overflow model init: '//TRIM(em))
    d_unit_area = SQRT(4.0_wp/PI)
    diamv = d_unit_area
    can_v = 1.0_wp
    cat_v = 1.0_wp
    ! deliberately non-finite or overflowing input: must not halt a trapping build
    CALL IEEE_GET_HALTING_MODE(IEEE_USUAL, fp_halt)
    CALL IEEE_SET_HALTING_MODE(IEEE_USUAL, .FALSE.)
    CALL CD_HermiteCable_Dyn_Set_AddedMass(m, 1.0e308_wp, diamv, can_v, cat_v, WL, es, em)
    CALL IEEE_SET_FLAG(IEEE_USUAL, .FALSE.)
    CALL IEEE_SET_HALTING_MODE(IEEE_USUAL, fp_halt)
    CALL require(es /= CD_HCDYN_OK .AND. INDEX(em, 'global added-mass matrix') > 0, &
                 'global scatter overflow fails closed at assembly')
    CALL require(.NOT. m%has_am, 'global scatter overflow rolls back added-mass configuration')
    CALL CD_HermiteCable_Dyn_End(m)
  END SUBROUTINE check_global_scatter_overflow

  SUBROUTINE require(cond, label)
    LOGICAL, INTENT(IN) :: cond
    CHARACTER(*), INTENT(IN) :: label
    IF (.NOT. cond) THEN
      WRITE (*, '(A,A,A)') 'MISMATCH [', label, ']: condition false'
      nfail = nfail + 1
    END IF
  END SUBROUTINE require

END PROGRAM test_hermite_added_mass
