! File: tests/test_hermite_cable_dynamic.f90
! SPDX-License-Identifier: Apache-2.0
! Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
PROGRAM test_hermite_cable_dynamic
  !! Finite-EI DYNAMICS validation for the cubic-Hermite bending-cable line
  !! (CableDyn_HermiteCableDynamic). The generalised-alpha integrator advances the wall-free
  !! Hermite element in time; these gates pin the dynamic contract the lazy-wave fatigue track
  !! relies on:
  !!   A  at-rest fixed point -- a straight beam at equilibrium stays at rest under stepping,
  !!   B  PRIMARY GATE: simply-supported Euler-Bernoulli bending free-vibration first-mode
  !!      frequency matches the closed form omega_1 = (pi/L)^2 sqrt(EI / rho_a),
  !!   C  energy conservation -- with rho_inf = 1 (trapezoidal, no algorithmic damping) the total
  !!      mechanical energy of a small free vibration drifts negligibly over many periods,
  !!   D  fail-closed on an uninitialised model / bad dt / bad rho_inf.
  !!
  !! The beam lies along x; motion is planar in x-z. The out-of-plane DOFs (r_y, m_y) are fixed at
  !! every node; the two ends are pinned in translation (r_x, r_y, r_z fixed, tangents free ->
  !! moment-free simple supports). The axial handle m_x and the interior r_x are LEFT FREE: the
  !! physical unit tangent is dr/ds = (sqrt(1-w'^2), 0, w'), so m_x must relax below 1 as the beam
  !! bends -- clamping m_x = 1 over-constrains inextensibility and stiffens bending by a constant
  !! (mesh-independent) factor. With m_x free the small-amplitude response is the classic
  !! Euler-Bernoulli first mode omega_1 = (pi/L)^2 sqrt(EI/rho_a).
  USE CableDyn_Precision, ONLY: wp
  USE CableDyn_HermiteCableDynamic, ONLY: CD_HermiteCableDynType, CD_HermiteCable_Dyn_Init, &
                                          CD_HermiteCable_Dyn_Step, CD_HermiteCable_Dyn_Energy, &
                                          CD_HermiteCable_Dyn_End, CD_HCDYN_OK, CD_HCDYN_NOCONVERGE, &
                                          CD_HCDYN_BADINPUT, &
                                          CD_HermiteCable_Dyn_Set_ModifiedNewton, &
                                          CD_HermiteCable_Dyn_Set_Tensile_Safety, &
                                          CD_HermiteCable_Dyn_Set_Tensile_Monitor, &
                                          CD_HermiteCable_Dyn_Get_Tensile_Diagnostics, &
                                          CD_HermiteCable_Dyn_Get_Recovery_Diagnostics, &
                                          CD_HCDYN_TENSILE_WARN, &
                                          CD_HermiteCable_Dyn_Set_Contact, &
                                          CD_HermiteCable_Dyn_Recompute_Acceleration, &
                                          CD_HermiteCable_Dyn_Set_AdaptiveNewton, &
                                          CD_HermiteCable_Dyn_Step_Recovering, &
                                          CD_HermiteCable_Dyn_Recovery_Count, CD_HermiteCable_Dyn_Recovery_Reset, &
                                          CD_HermiteCable_Dyn_Reset_Profile, &
                                          CD_HermiteCable_Dyn_Disable_Profile, &
                                          CD_HermiteCable_Dyn_Profile_Enabled, &
                                          CD_HermiteCable_Dyn_Get_Profile, CD_HermiteCable_Dyn_Set_Drag
  USE CableDyn_HermiteCable, ONLY: CD_HermiteCable_Dry_Buoyancy
  IMPLICIT NONE

  REAL(wp), PARAMETER :: PI = 3.14159265358979323846_wp
  REAL(wp), PARAMETER :: LB = 10.0_wp        ! beam length
  INTEGER, PARAMETER :: NE = 10              ! elements
  REAL(wp), PARAMETER :: RHOA = 1.0_wp       ! mass per unit length
  REAL(wp), PARAMETER :: EI = 100.0_wp       ! bending stiffness
  REAL(wp), PARAMETER :: EA = 1.0e5_wp       ! axial: 1000x EI so axial modes sit well above mode 1
  INTEGER :: nfail

  nfail = 0
  CALL check_profile_toggle()
  CALL check_residual_history()
  CALL check_fixed_point()
  CALL check_bending_frequency()
  CALL check_energy_conservation()
  CALL check_fail_closed()
  CALL check_tensile_safety()
  CALL check_contact_configuration()
  CALL check_prescribe_then_release()
  CALL check_modified_newton()
  CALL check_adaptive_newton()
  CALL check_recovering_step()
  CALL check_dry_buoyancy_element()
  CALL check_dry_free_fall()
  CALL check_rigid_translation_gate()

  IF (nfail > 0) THEN
    WRITE (*, '(A,I0,A)') 'FAIL: ', nfail, ' assertion(s) failed'
    ERROR STOP 1
  END IF
  WRITE (*, '(A)') 'PASS: finite-EI Hermite dynamics (gen-alpha) is a fixed point, EB-accurate, and energy-stable'

CONTAINS

  INCLUDE 'nan_max_abs.inc'

  SUBROUTINE check_dry_buoyancy_element()
    !! Dry-part buoyancy recovery of one cubic-Hermite element: fully wet -> zero, fully dry
    !! -> the consistent uniform load, straddling -> the closed-form dry-interval integral
    !! (checked against brute-force midpoint quadrature) with a tangent that matches the
    !! central finite difference of the load (the waterline-crossing derivative).
    REAL(wp), PARAMETER :: L = 3.0_wp, B = 250.0_wp, WL = 0.4_wp
    REAL(wp) :: qz(4, 4), fz(4), kz(4, 4), fp(4), fm(4), kfd(4, 4), kdum(4, 4), fq(4), dq, xi, z, nb(4), kscale
    INTEGER :: c, j, k, nq
    LOGICAL :: dry
    ! [z1, m_z1, z2, m_z2]: one crossing rising, one falling, two crossings (sagging arch
    ! through the surface), and a steep crossing.
    qz(:, 1) = [-1.0_wp, 0.5_wp, 1.2_wp, 0.9_wp]
    qz(:, 2) = [1.5_wp, -0.2_wp, -0.8_wp, -1.1_wp]
    qz(:, 3) = [0.9_wp, -1.4_wp, 1.0_wp, 1.6_wp]
    qz(:, 4) = [-1.3_wp, 1.0_wp, 1.6_wp, 0.95_wp]
    CALL CD_HermiteCable_Dry_Buoyancy([-5.0_wp, 0.0_wp, -5.0_wp, 0.0_wp], L, B, WL, fz, kz, dry)
    CALL require(.NOT. dry .AND. nan_max_abs(fz) <= 0.0_wp .AND. nan_max_abs(kz) <= 0.0_wp, &
                 'dry buoyancy: submerged element carries nothing')
    CALL CD_HermiteCable_Dry_Buoyancy([5.0_wp, 0.1_wp, 6.0_wp, -0.2_wp], L, B, WL, fz, kz, dry)
    CALL require(dry .AND. nan_max_abs(fz - B*L*[0.5_wp, L/12.0_wp, 0.5_wp, -L/12.0_wp]) < 1.0e-12_wp*B*L*L &
                 .AND. nan_max_abs(kz) <= 0.0_wp, 'dry buoyancy: dry element carries the consistent load')
    DO c = 1, 4
      CALL CD_HermiteCable_Dry_Buoyancy(qz(:, c), L, B, WL, fz, kz, dry)
      CALL require(dry, 'dry buoyancy: straddling element is active')
      ! brute-force dry integral
      nq = 200000
      fq = 0.0_wp
      DO j = 1, nq
        xi = (REAL(j, wp) - 0.5_wp)/REAL(nq, wp)
        nb = [1.0_wp - xi*xi*(3.0_wp - 2.0_wp*xi), L*xi*(1.0_wp - xi)**2, xi*xi*(3.0_wp - 2.0_wp*xi), &
              L*xi*xi*(xi - 1.0_wp)]
        z = DOT_PRODUCT(nb, qz(:, c))
        IF (z > WL) fq = fq + nb/REAL(nq, wp)
      END DO
      fq = B*L*fq
      ! Midpoint quadrature of the discontinuous integrand is accurate to ~1/nq.
      CALL require(nan_max_abs(fz - fq) < 1.0e-5_wp*B*L*L, 'dry buoyancy: exact dry-interval integral')
      dq = 1.0e-7_wp
      DO k = 1, 4
        CALL CD_HermiteCable_Dry_Buoyancy(qz(:, c) + dq*unit4(k), L, B, WL, fp, kdum, dry)
        CALL CD_HermiteCable_Dry_Buoyancy(qz(:, c) - dq*unit4(k), L, B, WL, fm, kdum, dry)
        kfd(:, k) = (fp - fm)/(2.0_wp*dq)
      END DO
      kscale = nan_max_abs(kz)
      CALL require(kscale > 0.0_wp .AND. nan_max_abs(kz - kfd) < 1.0e-6_wp*kscale, &
                   'dry buoyancy: crossing tangent matches the finite difference')
      CALL require(nan_max_abs(kz - TRANSPOSE(kz)) <= 1.0e-14_wp*kscale, 'dry buoyancy: tangent symmetric')
    END DO
    CALL check_section_law()
  END SUBROUTINE check_dry_buoyancy_element

  SUBROUTINE check_section_law()
    !! Finite-section waterline law (radius present): the load integrates the partial-immersion
    !! dry fraction of the circular section (brute force), is the gradient of the returned
    !! energy, has a tangent matching the finite difference of the load, and reduces to the
    !! submerged/dry limits outside the band. A level element floating in the band has a
    !! finite waterplane stiffness buoyancy*L*2/(pi R)*integral N N at the centreline.
    REAL(wp), PARAMETER :: L = 3.0_wp, B = 250.0_wp, WL = 0.4_wp, RAD = 0.3_wp, PI_T = 3.14159265358979324_wp
    REAL(wp) :: qz(4, 5), fz(4), kz(4, 4), fp(4), fm(4), kfd(4, 4), kdum(4, 4), fq(4), ep, em, e0, dq, xi, u, &
                nb(4), kscale, s1
    INTEGER :: c, j, k, nq
    LOGICAL :: dry
    qz(:, 1) = [-1.0_wp, 0.5_wp, 1.2_wp, 0.9_wp]
    qz(:, 2) = [1.5_wp, -0.2_wp, -0.8_wp, -1.1_wp]
    qz(:, 3) = [0.9_wp, -1.4_wp, 1.0_wp, 1.6_wp]
    qz(:, 4) = [-1.3_wp, 1.0_wp, 1.6_wp, 0.95_wp]
    qz(:, 5) = [WL + 0.1_wp, 0.0_wp, WL - 0.05_wp, 0.01_wp]
    CALL CD_HermiteCable_Dry_Buoyancy([WL - RAD - 1.0e-3_wp, 0.0_wp, WL - RAD - 1.0e-3_wp, 0.0_wp], L, B, WL, fz, kz, &
                                      dry, radius=RAD)
    CALL require(.NOT. dry .AND. nan_max_abs(fz) <= 0.0_wp, 'section law: element below the band carries nothing')
    CALL CD_HermiteCable_Dry_Buoyancy([WL + RAD + 1.0e-3_wp, 0.0_wp, WL + RAD + 1.0e-3_wp, 0.0_wp], L, B, WL, fz, kz, &
                                      dry, radius=RAD)
    CALL require(dry .AND. nan_max_abs(fz - B*L*[0.5_wp, L/12.0_wp, 0.5_wp, -L/12.0_wp]) < 1.0e-12_wp*B*L*L &
                 .AND. nan_max_abs(kz) <= 0.0_wp, 'section law: element above the band carries the full load')
    DO c = 1, 5
      CALL CD_HermiteCable_Dry_Buoyancy(qz(:, c), L, B, WL, fz, kz, dry, energy=e0, radius=RAD)
      CALL require(dry, 'section law: element in the band is active')
      nq = 200000
      fq = 0.0_wp
      DO j = 1, nq
        xi = (REAL(j, wp) - 0.5_wp)/REAL(nq, wp)
        nb = [1.0_wp - xi*xi*(3.0_wp - 2.0_wp*xi), L*xi*(1.0_wp - xi)**2, xi*xi*(3.0_wp - 2.0_wp*xi), &
              L*xi*xi*(xi - 1.0_wp)]
        u = MAX(-1.0_wp, MIN(1.0_wp, (DOT_PRODUCT(nb, qz(:, c)) - WL)/RAD))
        s1 = SQRT(1.0_wp - u*u)
        fq = fq + nb*(1.0_wp - (ACOS(u) - u*s1)/PI_T)/REAL(nq, wp)
      END DO
      fq = B*L*fq
      CALL require(nan_max_abs(fz - fq) < 1.0e-5_wp*B*L*L, 'section law: partial-immersion integral')
      dq = 1.0e-6_wp
      DO k = 1, 4
        CALL CD_HermiteCable_Dry_Buoyancy(qz(:, c) + dq*unit4(k), L, B, WL, fp, kdum, dry, energy=ep, radius=RAD)
        CALL CD_HermiteCable_Dry_Buoyancy(qz(:, c) - dq*unit4(k), L, B, WL, fm, kdum, dry, energy=em, radius=RAD)
        kfd(:, k) = (fp - fm)/(2.0_wp*dq)
        CALL require(ABS((ep - em)/(2.0_wp*dq) - fz(k)) < 1.0e-6_wp*B*L*L, 'section law: load is the energy gradient')
      END DO
      kscale = nan_max_abs(kz)
      CALL require(kscale > 0.0_wp .AND. nan_max_abs(kz - kfd) < 1.0e-6_wp*kscale, &
                   'section law: tangent matches the finite difference')
      CALL require(nan_max_abs(kz - TRANSPOSE(kz)) <= 1.0e-14_wp*kscale, 'section law: tangent symmetric')
    END DO
  END SUBROUTINE check_section_law

  PURE FUNCTION unit4(k) RESULT(u)
    INTEGER, INTENT(IN) :: k
    REAL(wp) :: u(4)
    u = 0.0_wp
    u(k) = 1.0_wp
  END FUNCTION unit4

  SUBROUTINE check_dry_free_fall()
    !! A cable entirely above the free surface falls at -g: the submerged weight w of the
    !! model is completed by the buoyancy it does not have in air. Half-submerged, the
    !! weight changes only on the dry part. No constraints and no drag coefficients, so the
    !! exact motion is uniform free fall, which generalised-alpha integrates exactly.
    INTEGER, PARAMETER :: N = 8, NN = N + 1
    REAL(wp), PARAMETER :: G = 9.80665_wp, RHOW = 1025.0_wp, D = 0.2_wp, MPL = 80.0_wp
    TYPE(CD_HermiteCableDynType) :: m
    REAL(wp) :: l0(N), EAv(N), EIv(N), rhoAv(N), wv(N), seed(6*NN), diam(N), cd0(N), t, zerr, verr
    INTEGER :: es, i, s
    INTEGER, ALLOCATABLE :: nofix(:)
    CHARACTER(300) :: em
    l0 = 2.0_wp; EAv = 1.0e7_wp; EIv = 1.0e3_wp; rhoAv = MPL; diam = D; cd0 = 0.0_wp
    wv = (MPL - RHOW*0.25_wp*PI*D*D)*G
    seed = 0.0_wp
    DO i = 1, NN
      seed(6*i - 5) = 2.0_wp*REAL(i - 1, wp)
      seed(6*i - 3) = 30.0_wp
      seed(6*i - 2) = 1.0_wp
    END DO
    ALLOCATE (nofix(0))
    CALL CD_HermiteCable_Dyn_Init(m, l0, EAv, EIv, rhoAv, wv, seed, nofix, -1.0e4_wp, 0.0_wp, 0.8_wp, es, em)
    CALL require(es == CD_HCDYN_OK, 'dry free fall init: '//TRIM(em))
    CALL CD_HermiteCable_Dyn_Set_Drag(m, RHOW, diam, cd0, cd0, 0.0_wp, [0.0_wp, 0.0_wp, 0.0_wp], es, em, gravity=G)
    CALL require(es == CD_HCDYN_OK, 'dry free fall drag config: '//TRIM(em))
    CALL require(nan_max_abs(m%a(3::6) + G) < 1.0e-9_wp, 'dry cable starts at -g (buoyancy of the dry part removed)')
    t = 0.0_wp
    DO s = 1, 10
      CALL CD_HermiteCable_Dyn_Step(m, 0.05_wp, 20, 1.0e-10_wp, es, em)
      CALL require(es == CD_HCDYN_OK, 'dry free fall step: '//TRIM(em))
      t = t + 0.05_wp
    END DO
    zerr = nan_max_abs(m%q(3::6) - (30.0_wp - 0.5_wp*G*t*t))
    verr = nan_max_abs(m%v(3::6) + G*t)
    CALL require(zerr < 1.0e-8_wp .AND. verr < 1.0e-8_wp, 'dry cable falls freely at -g')
    CALL CD_HermiteCable_Dyn_End(m)
    ! A submerged cable accelerates at w/(m + added mass) < g; here without added mass w/m.
    seed(3::6) = -30.0_wp
    CALL CD_HermiteCable_Dyn_Init(m, l0, EAv, EIv, rhoAv, wv, seed, nofix, -1.0e4_wp, 0.0_wp, 0.8_wp, es, em)
    CALL CD_HermiteCable_Dyn_Set_Drag(m, RHOW, diam, cd0, cd0, 0.0_wp, [0.0_wp, 0.0_wp, 0.0_wp], es, em, gravity=G)
    CALL require(nan_max_abs(m%a(3::6) + wv(1)/MPL) < 1.0e-9_wp, 'submerged cable accelerates at w/m')
    CALL CD_HermiteCable_Dyn_End(m)
  END SUBROUTINE check_dry_free_fall

  SUBROUTINE check_rigid_translation_gate()
    !! The temporal quality gate measures deformation, not displacement: a weightless
    !! straight line translated rigidly by its prescribed end (the exact solution) is
    !! integrated by the full step without substep recovery even when one step moves every
    !! node by half an element length.
    INTEGER, PARAMETER :: N = 10, NN = N + 1
    TYPE(CD_HermiteCableDynType) :: m
    REAL(wp) :: l0(N), EAv(N), EIv(N), rhoAv(N), wv(N), seed(6*NN), u, t, dev
    REAL(wp), PARAMETER :: SPEEDS(2) = [2.1_wp, 5.0_wp], DTR = 0.1_wp
    INTEGER :: es, i, k, s, nev, nmax
    CHARACTER(300) :: em
    l0 = 1.0_wp; EAv = 1.0e8_wp; EIv = 1.0e3_wp; rhoAv = 50.0_wp; wv = 0.0_wp
    DO k = 1, 2
      u = SPEEDS(k)
      seed = 0.0_wp
      DO i = 1, NN
        seed(6*i - 3) = -REAL(i - 1, wp)
        seed(6*i) = -1.0_wp
      END DO
      CALL CD_HermiteCable_Dyn_Init(m, l0, EAv, EIv, rhoAv, wv, seed, [1, 2, 3], -1.0e4_wp, 0.0_wp, 0.8_wp, es, em)
      CALL require(es == CD_HCDYN_OK, 'rigid translation init: '//TRIM(em))
      m%v(1::6) = u
      m%a = 0.0_wp
      t = 0.0_wp
      DO s = 1, 20
        t = t + DTR
        CALL CD_HermiteCable_Dyn_Step_Recovering(m, DTR, 30, 1.0e-8_wp, es, em, pres_dofs=[1, 2, 3], &
                                                 pres_q=[u*t, 0.0_wp, 0.0_wp], pres_v=[u, 0.0_wp, 0.0_wp], &
                                                 pres_a=[0.0_wp, 0.0_wp, 0.0_wp])
        CALL require(es == CD_HCDYN_OK, 'rigid translation step: '//TRIM(em))
      END DO
      CALL CD_HermiteCable_Dyn_Get_Recovery_Diagnostics(m, nev, nmax, es, em)
      dev = MAX(nan_max_abs(m%q(1::6) - u*t), nan_max_abs(m%q(3::6) - seed(3::6)))
      CALL require(es == CD_HCDYN_OK .AND. nev == 0, 'rigid translation needs no substep recovery')
      CALL require(dev < 1.0e-10_wp, 'rigid translation is integrated exactly')
      CALL CD_HermiteCable_Dyn_End(m)
    END DO
  END SUBROUTINE check_rigid_translation_gate

  SUBROUTINE check_residual_history()
    TYPE(CD_HermiteCableDynType) :: m
    REAL(wp), ALLOCATABLE :: l0(:), EAv(:), EIv(:), rhoAv(:), wv(:), seed(:)
    REAL(wp) :: history(30), final_residual
    INTEGER, ALLOCATABLE :: fx(:)
    INTEGER :: es, count, iterations
    CHARACTER(300) :: em

    CALL build_beam(0.01_wp, l0, EAv, EIv, rhoAv, wv, seed, fx)
    CALL CD_HermiteCable_Dyn_Init(m, l0, EAv, EIv, rhoAv, wv, seed, fx, &
                                  0.0_wp, 0.0_wp, 0.9_wp, es, em)
    CALL require(es == CD_HCDYN_OK, 'residual history init: '//TRIM(em))
    CALL CD_HermiteCable_Dyn_Step(m, 0.001_wp, 30, 1.0e-8_wp, es, em, &
                                  iters_out=iterations, res_out=final_residual, &
                                  residual_history=history, history_count=count)
    CALL require(es == CD_HCDYN_OK, 'residual history step: '//TRIM(em))
    CALL require(count >= 1 .AND. count <= 30, 'residual history count is bounded')
    CALL require(history(count) < 1.0e-8_wp .AND. final_residual < 1.0e-8_wp, &
                 'residual history records the converged iterate')
    CALL require(history(1) >= history(count), 'residual history contracts overall')
    CALL CD_HermiteCable_Dyn_End(m)
  END SUBROUTINE check_residual_history

  SUBROUTINE check_contact_configuration()
    !! Installing the production nodal contact law must immediately refresh the
    !! consistent acceleration, while malformed replacement data fails before it can
    !! disturb the committed configuration.
    TYPE(CD_HermiteCableDynType), ALLOCATABLE :: m   ! see DEVELOPMENT.md (gfortran 16 -Wuninitialized)
    REAL(wp), ALLOCATABLE :: l0(:), EAv(:), EIv(:), rhoAv(:), wv(:), seed(:), kn(:), cn(:), a_before(:)
    INTEGER, ALLOCATABLE :: fx(:)
    INTEGER :: es, i
    CHARACTER(300) :: em

    ALLOCATE (m)
    CALL build_beam(0.0_wp, l0, EAv, EIv, rhoAv, wv, seed, fx)
    DO i = 1, NE + 1
      seed(6*(i - 1) + 3) = -0.01_wp
    END DO
    CALL CD_HermiteCable_Dyn_Init(m, l0, EAv, EIv, rhoAv, wv, seed, fx, 0.0_wp, 0.0_wp, 0.9_wp, es, em)
    CALL require(es == CD_HCDYN_OK, 'contact configuration init: '//TRIM(em))
    ALLOCATE (kn(NE + 1), cn(NE + 1))
    kn = 1.0e4_wp; cn = 10.0_wp
    CALL CD_HermiteCable_Dyn_Set_Contact(m, kn, cn, 0.2_wp, es, em)
    CALL require(es == CD_HCDYN_OK, 'contact configuration accepted: '//TRIM(em))
    CALL require(MAXVAL(m%a(3:6*(NE + 1):6)) > 0.0_wp, &
                 'penetrating free nodes receive upward consistent acceleration')
    a_before = m%a
    CALL CD_HermiteCable_Dyn_Set_Contact(m, kn(1:NE), cn, 0.2_wp, es, em)
    CALL require(es == CD_HCDYN_BADINPUT, 'contact configuration rejects a short nodal table')
    CALL require(nan_max_abs(m%a - a_before) <= TINY(1.0_wp), &
                 'rejected contact replacement preserves acceleration exactly')
    CALL CD_HermiteCable_Dyn_Recompute_Acceleration(m, es, em, pres_dofs=fx(1:1))
    CALL require(es == CD_HCDYN_BADINPUT, 'acceleration refresh rejects a partial prescription')
    CALL require(nan_max_abs(m%a - a_before) <= TINY(1.0_wp), &
                 'partial acceleration prescription preserves acceleration exactly')
    CALL CD_HermiteCable_Dyn_Recompute_Acceleration(m, es, em, pres_dofs=[4], pres_a=[1.0_wp])
    CALL require(es == CD_HCDYN_BADINPUT, 'acceleration refresh rejects a prescribed free DOF')
    CALL require(nan_max_abs(m%a - a_before) <= TINY(1.0_wp), &
                 'free-DOF acceleration prescription preserves acceleration exactly')
    CALL CD_HermiteCable_Dyn_Recompute_Acceleration(m, es, em, &
                                                    pres_dofs=[fx(1), fx(1)], pres_a=[1.0_wp, 1.0_wp])
    CALL require(es == CD_HCDYN_BADINPUT, 'acceleration refresh rejects duplicate prescribed DOFs')
    CALL require(nan_max_abs(m%a - a_before) <= TINY(1.0_wp), &
                 'duplicate acceleration prescription preserves acceleration exactly')
    CALL CD_HermiteCable_Dyn_End(m)
  END SUBROUTINE check_contact_configuration

  SUBROUTINE check_profile_toggle()
    !! Library clients can run multiple cases in one process. Pin the public reset /
    !! disable contract so a diagnostic run cannot impose timing overhead or serial
    !! scheduling on a later ordinary run.
    CALL CD_HermiteCable_Dyn_Reset_Profile()
    CALL require(CD_HermiteCable_Dyn_Profile_Enabled(), 'profile reset arms diagnostics')
    CALL CD_HermiteCable_Dyn_Disable_Profile()
    CALL require(.NOT. CD_HermiteCable_Dyn_Profile_Enabled(), 'profile disable disarms diagnostics')
  END SUBROUTINE check_profile_toggle

  SUBROUTINE build_beam(amp, l0, EAv, EIv, rhoAv, wv, seed, fixed_dofs)
    !! Build the per-element arrays, a mode-1 seed of amplitude amp, and the EB fixed-DOF set.
    REAL(wp), INTENT(IN) :: amp
    REAL(wp), ALLOCATABLE, INTENT(OUT) :: l0(:), EAv(:), EIv(:), rhoAv(:), wv(:), seed(:)
    INTEGER, ALLOCATABLE, INTENT(OUT) :: fixed_dofs(:)
    INTEGER :: nn, i, k
    REAL(wp) :: h, xi, zi, dzi
    nn = NE + 1
    h = LB/REAL(NE, wp)
    ALLOCATE (l0(NE), EAv(NE), EIv(NE), rhoAv(NE), wv(NE), seed(6*nn))
    l0 = h; EAv = EA; EIv = EI; rhoAv = RHOA; wv = 0.0_wp
    seed = 0.0_wp
    DO i = 1, nn
      xi = REAL(i - 1, wp)*h
      zi = amp*SIN(PI*xi/LB)
      dzi = amp*(PI/LB)*COS(PI*xi/LB)     ! dz/ds ~ dz/dx for small amp
      seed(6*(i - 1) + 1) = xi            ! r_x
      seed(6*(i - 1) + 2) = 0.0_wp        ! r_y
      seed(6*(i - 1) + 3) = zi            ! r_z
      seed(6*(i - 1) + 4) = 1.0_wp        ! m_x (unit tangent)
      seed(6*(i - 1) + 5) = 0.0_wp        ! m_y
      seed(6*(i - 1) + 6) = dzi           ! m_z
    END DO
    ! Planar x-z motion: fix r_y, m_y at every node. Pin both ends fully in translation
    ! (r_x, r_z). Leave m_x and the interior r_x FREE so the tangent can relax as the beam bends.
    ALLOCATE (fixed_dofs(2*nn + 4))
    k = 0
    DO i = 1, nn
      fixed_dofs(k + 1) = 6*(i - 1) + 2   ! r_y
      fixed_dofs(k + 2) = 6*(i - 1) + 5   ! m_y
      k = k + 2
    END DO
    fixed_dofs(k + 1) = 6*(1 - 1) + 1     ! r_x at node 1
    fixed_dofs(k + 2) = 6*(1 - 1) + 3     ! r_z at node 1
    fixed_dofs(k + 3) = 6*(nn - 1) + 1    ! r_x at node nn
    fixed_dofs(k + 4) = 6*(nn - 1) + 3    ! r_z at node nn
  END SUBROUTINE build_beam

  SUBROUTINE check_fixed_point()
    !! A straight beam (amp = 0) at equilibrium must remain at rest under stepping.
    TYPE(CD_HermiteCableDynType) :: m
    REAL(wp), ALLOCATABLE :: l0(:), EAv(:), EIv(:), rhoAv(:), wv(:), seed(:)
    INTEGER, ALLOCATABLE :: fx(:)
    REAL(wp) :: maxv, maxdq
    INTEGER :: es, s
    CHARACTER(300) :: em
    CALL build_beam(0.0_wp, l0, EAv, EIv, rhoAv, wv, seed, fx)
    CALL CD_HermiteCable_Dyn_Init(m, l0, EAv, EIv, rhoAv, wv, seed, fx, 0.0_wp, 0.0_wp, 0.9_wp, es, em)
    CALL require(es == CD_HCDYN_OK, 'fixed-point init: '//TRIM(em))
    maxv = 0.0_wp; maxdq = 0.0_wp
    DO s = 1, 50
      CALL CD_HermiteCable_Dyn_Step(m, 0.05_wp, 20, 1.0e-8_wp, es, em)
      IF (es /= CD_HCDYN_OK) THEN
        CALL require(.FALSE., 'fixed-point step: '//TRIM(em)); EXIT
      END IF
      maxv = MAX(maxv, nan_max_abs(m%v))
      maxdq = MAX(maxdq, nan_max_abs(m%q - seed))
    END DO
    CALL require(maxv < 1.0e-8_wp, 'straight rest state has zero velocity under stepping')
    CALL require(maxdq < 1.0e-8_wp, 'straight rest state does not drift')
    CALL CD_HermiteCable_Dyn_End(m)
    DEALLOCATE (l0, EAv, EIv, rhoAv, wv, seed, fx)
  END SUBROUTINE check_fixed_point

  SUBROUTINE check_bending_frequency()
    !! PRIMARY GATE: simply-supported bending free-vibration first-mode period vs the closed form.
    TYPE(CD_HermiteCableDynType) :: m
    REAL(wp), ALLOCATABLE :: l0(:), EAv(:), EIv(:), rhoAv(:), wv(:), seed(:)
    INTEGER, ALLOCATABLE :: fx(:)
    REAL(wp), PARAMETER :: AMP = 1.0e-3_wp, DT = 0.02_wp
    REAL(wp) :: omega1, T1, tc(3), z_prev, z_cur, t, T_meas, f_meas, f_exact, relerr
    INTEGER :: es, s, mid_dof, nn, nsteps, ncr
    CHARACTER(300) :: em

    nn = NE + 1
    mid_dof = 6*((nn + 1)/2 - 1) + 3        ! r_z at the midspan node (nn odd -> exact centre)
    omega1 = (PI/LB)**2*SQRT(EI/RHOA)
    T1 = 2.0_wp*PI/omega1

    CALL build_beam(AMP, l0, EAv, EIv, rhoAv, wv, seed, fx)
    CALL CD_HermiteCable_Dyn_Init(m, l0, EAv, EIv, rhoAv, wv, seed, fx, 0.0_wp, 0.0_wp, 1.0_wp, es, em)
    CALL require(es == CD_HCDYN_OK, 'frequency init: '//TRIM(em))

    ! z_mid(t) = AMP cos(omega t) (+ tiny higher-mode content). Time the DOWNWARD zero crossings;
    ! the period is measured crossing-to-crossing (T = (t_cross3 - t_cross1)/2) so the t=0 transient
    ! is never multiplied up and the small higher-mode contamination averages over two full periods.
    z_prev = m%q(mid_dof)
    t = 0.0_wp; ncr = 0; tc = 0.0_wp
    nsteps = NINT(2.4_wp*T1/DT)             ! two full periods plus the leading quarter period
    DO s = 1, nsteps
      CALL CD_HermiteCable_Dyn_Step(m, DT, 30, 1.0e-8_wp, es, em)
      IF (es /= CD_HCDYN_OK) THEN
        CALL require(.FALSE., 'frequency step: '//TRIM(em)); EXIT
      END IF
      z_cur = m%q(mid_dof)
      t = t + DT
      IF (z_prev > 0.0_wp .AND. z_cur <= 0.0_wp .AND. ncr < 3) THEN
        ncr = ncr + 1
        tc(ncr) = (t - DT) + DT*z_prev/(z_prev - z_cur)   ! linear interpolation of the crossing
      END IF
      z_prev = z_cur
    END DO
    CALL require(ncr == 3, 'midspan completes two full periods (three downward crossings)')

    IF (ncr == 3) THEN
      T_meas = 0.5_wp*(tc(3) - tc(1))
      f_meas = 1.0_wp/T_meas
      f_exact = 1.0_wp/T1
      relerr = ABS(f_meas - f_exact)/f_exact
      WRITE (*, '(A,F10.6,A,F10.6,A,F7.3,A)') '  [EB freq] measured T1 = ', T_meas, ' s   exact = ', T1, &
        ' s   err = ', 100.0_wp*relerr, '%'
      CALL require(relerr < 0.001_wp, 'first-mode frequency within 0.1% of (pi/L)^2 sqrt(EI/rho_a)')
    END IF
    CALL CD_HermiteCable_Dyn_End(m)
    DEALLOCATE (l0, EAv, EIv, rhoAv, wv, seed, fx)
  END SUBROUTINE check_bending_frequency

  SUBROUTINE check_energy_conservation()
    !! With rho_inf = 1 (no algorithmic damping) total mechanical energy of a small free
    !! vibration is conserved to a small drift over a couple of periods.
    TYPE(CD_HermiteCableDynType) :: m
    REAL(wp), ALLOCATABLE :: l0(:), EAv(:), EIv(:), rhoAv(:), wv(:), seed(:)
    INTEGER, ALLOCATABLE :: fx(:)
    REAL(wp), PARAMETER :: AMP = 1.0e-3_wp, DT = 0.02_wp
    REAL(wp) :: ke, se, E0, Emax, Emin, drift
    INTEGER :: es, s
    CHARACTER(300) :: em
    CALL build_beam(AMP, l0, EAv, EIv, rhoAv, wv, seed, fx)
    CALL CD_HermiteCable_Dyn_Init(m, l0, EAv, EIv, rhoAv, wv, seed, fx, 0.0_wp, 0.0_wp, 1.0_wp, es, em)
    CALL require(es == CD_HCDYN_OK, 'energy init: '//TRIM(em))
    CALL CD_HermiteCable_Dyn_Energy(m, ke, se, es, em)
    E0 = ke + se; Emax = E0; Emin = E0
    DO s = 1, 700                          ! ~2.2 periods at T1 ~ 6.37 s, dt = 0.02 s
      CALL CD_HermiteCable_Dyn_Step(m, DT, 30, 1.0e-8_wp, es, em)
      IF (es /= CD_HCDYN_OK) THEN
        CALL require(.FALSE., 'energy step: '//TRIM(em)); EXIT
      END IF
      CALL CD_HermiteCable_Dyn_Energy(m, ke, se, es, em)
      Emax = MAX(Emax, ke + se); Emin = MIN(Emin, ke + se)
    END DO
    drift = (Emax - Emin)/E0
    ! ES format: a fixed-point '0.000%' hides the actual residual the docs must quote
    WRITE (*, '(A,ES12.5,A,ES10.3,A)') '  [energy] E0 = ', E0, '   peak-to-peak drift = ', 100.0_wp*drift, ' %'
    ! observed peak-to-peak drift ~5e-8 of E0; the bound leaves three orders of magnitude
    CALL require(drift < 1.0e-4_wp, 'total mechanical energy conserved to <0.01% (rho_inf=1)')
    CALL CD_HermiteCable_Dyn_End(m)
    DEALLOCATE (l0, EAv, EIv, rhoAv, wv, seed, fx)
  END SUBROUTINE check_energy_conservation

  SUBROUTINE check_fail_closed()
    !! Uninitialised model / bad dt / bad rho_inf must fail closed.
    TYPE(CD_HermiteCableDynType) :: m
    REAL(wp), ALLOCATABLE :: l0(:), EAv(:), EIv(:), rhoAv(:), wv(:), seed(:), empty_real(:)
    INTEGER, ALLOCATABLE :: fx(:), empty_dofs(:)
    INTEGER :: es
    CHARACTER(300) :: em
    ! Step before init.
    CALL CD_HermiteCable_Dyn_Step(m, 0.01_wp, 10, 1.0e-9_wp, es, em)
    CALL require(es /= CD_HCDYN_OK, 'reject stepping an uninitialised model')
    CALL CD_HermiteCable_Dyn_Set_Tensile_Safety(m, .TRUE., es, em)
    CALL require(es == CD_HCDYN_BADINPUT, 'reject tensile safety before initialisation')
    ! Bad rho_inf at init.
    CALL build_beam(0.0_wp, l0, EAv, EIv, rhoAv, wv, seed, fx)
    CALL CD_HermiteCable_Dyn_Init(m, l0, EAv, EIv, rhoAv, wv, seed, fx, 0.0_wp, 0.0_wp, 1.5_wp, es, em)
    CALL require(es /= CD_HCDYN_OK, 'reject rho_inf > 1')
    ! Massless model rejected (would give a singular initial-acceleration solve).
    CALL CD_HermiteCable_Dyn_Init(m, l0, EAv, EIv, 0.0_wp*rhoAv, wv, seed, fx, &
                                  0.0_wp, 0.0_wp, 0.9_wp, es, em)
    CALL require(es /= CD_HCDYN_OK, 'reject an all-massless dynamic model')
    ! Good init, then exercise the step-level rejections.
    CALL CD_HermiteCable_Dyn_Init(m, l0, EAv, EIv, rhoAv, wv, seed, fx, 0.0_wp, 0.0_wp, 0.9_wp, es, em)
    CALL require(es == CD_HCDYN_OK, 'valid init for step-rejection checks')
    ALLOCATE (empty_dofs(0), empty_real(0))
    CALL CD_HermiteCable_Dyn_Step(m, 0.01_wp, 10, 1.0e-9_wp, es, em, &
                                  pres_dofs=empty_dofs, pres_q=empty_real, &
                                  pres_v=empty_real, pres_a=empty_real)
    CALL require(es == CD_HCDYN_BADINPUT, 'reject an empty prescribed-motion set')
    CALL CD_HermiteCable_Dyn_Step_Recovering(m, 0.01_wp, 10, 1.0e-9_wp, es, em, &
                                             pres_dofs=empty_dofs, pres_q=empty_real, &
                                             pres_v=empty_real, pres_a=empty_real)
    CALL require(es == CD_HCDYN_BADINPUT, 'recovering step rejects an empty prescribed-motion set')
    DEALLOCATE (empty_dofs, empty_real)
    CALL CD_HermiteCable_Dyn_Step_Recovering(m, 0.01_wp, 10, 1.0e-9_wp, es, em, max_substeps=3)
    CALL require(es == CD_HCDYN_BADINPUT, 'reject a recovery cap below four substeps')
    CALL CD_HermiteCable_Dyn_Set_Tensile_Safety(m, .TRUE., es, em)
    CALL require(es == CD_HCDYN_OK .AND. m%require_tensile, 'enable committed-step tensile safety')
    CALL CD_HermiteCable_Dyn_Step(m, -0.01_wp, 10, 1.0e-9_wp, es, em)
    CALL require(es /= CD_HCDYN_OK, 'reject nonpositive dt')
    ! Prescribed motion: partial arguments (pres_dofs without pres_v/pres_a) rejected.
    CALL CD_HermiteCable_Dyn_Step(m, 0.01_wp, 10, 1.0e-9_wp, es, em, pres_dofs=[3], pres_q=[0.0_wp])
    CALL require(es /= CD_HCDYN_OK, 'reject prescribed motion missing pres_v/pres_a')
    ! Prescribed motion: q/v/a supplied but pres_dofs omitted must NOT silently run as held.
    CALL CD_HermiteCable_Dyn_Step(m, 0.01_wp, 10, 1.0e-9_wp, es, em, &
                                  pres_q=[0.0_wp], pres_v=[0.0_wp], pres_a=[0.0_wp])
    CALL require(es /= CD_HCDYN_OK, 'reject prescribed q/v/a with pres_dofs omitted')
    ! Prescribed motion: array-size mismatch rejected.
    CALL CD_HermiteCable_Dyn_Step(m, 0.01_wp, 10, 1.0e-9_wp, es, em, &
                                  pres_dofs=[3], pres_q=[0.0_wp, 0.0_wp], pres_v=[0.0_wp], pres_a=[0.0_wp])
    CALL require(es /= CD_HCDYN_OK, 'reject prescribed q/v/a size mismatch')
    ! Prescribed motion: a FREE DOF (not in fixed_dofs) cannot be prescribed. Node-2 r_z (DOF 9) is free.
    CALL CD_HermiteCable_Dyn_Step(m, 0.01_wp, 10, 1.0e-9_wp, es, em, &
                                  pres_dofs=[9], pres_q=[0.0_wp], pres_v=[0.0_wp], pres_a=[0.0_wp])
    CALL require(es /= CD_HCDYN_OK, 'reject prescribing a free (non-fixed) DOF')
    CALL CD_HermiteCable_Dyn_End(m)
    DEALLOCATE (l0, EAv, EIv, rhoAv, wv, seed, fx)
  END SUBROUTINE check_fail_closed

  SUBROUTINE check_tensile_safety()
    !! A uniformly shortened, straight element chain is a legitimate bilateral
    !! finite-element state but not a legitimate tensile cable state.  Confirm
    !! that the optional qualification rejects it before state commitment.
    TYPE(CD_HermiteCableDynType) :: m
    REAL(wp), ALLOCATABLE :: l0(:), EAv(:), EIv(:), rhoAv(:), wv(:), seed(:), q_before(:)
    INTEGER, ALLOCATABLE :: fx(:)
    INTEGER :: es, event_count, worst_element, n_before
    REAL(wp) :: worst_force, worst_threshold, worst_xi, worst_time
    CHARACTER(300) :: em

    CALL build_beam(0.0_wp, l0, EAv, EIv, rhoAv, wv, seed, fx)
    seed(1:SIZE(seed):6) = 0.99_wp*seed(1:SIZE(seed):6)
    seed(4:SIZE(seed):6) = 0.99_wp
    CALL CD_HermiteCable_Dyn_Init(m, l0, EAv, EIv, rhoAv, wv, seed, fx, &
                                  0.0_wp, 0.0_wp, 0.9_wp, es, em)
    CALL require(es == CD_HCDYN_OK, 'compressed-state tensile-safety init: '//TRIM(em))
    CALL CD_HermiteCable_Dyn_Set_Tensile_Safety(m, .TRUE., es, em)
    CALL require(es == CD_HCDYN_OK, 'compressed-state tensile-safety enable: '//TRIM(em))
    ALLOCATE (q_before(SIZE(m%q))); q_before = m%q
    CALL CD_HermiteCable_Dyn_Step(m, 0.01_wp, 20, 1.0e-9_wp, es, em)
    CALL require(es == CD_HCDYN_NOCONVERGE, 'tensile safety rejects a continuously compressed state')
    CALL require(INDEX(em, 'axial compression') > 0, 'tensile-safety diagnostic identifies axial compression')
    CALL require(nan_max_abs(m%q - q_before) <= TINY(1.0_wp), &
                 'rejected tensile-safety step does not commit its candidate state')
    n_before = recovered_intervals(m)
    CALL CD_HermiteCable_Dyn_Step_Recovering(m, 0.01_wp, 20, 1.0e-9_wp, es, em)
    CALL require(es == CD_HCDYN_NOCONVERGE, 'recovering step preserves tensile-safety rejection')
    CALL require(INDEX(em, 'tensile qualification failed') > 0 .AND. INDEX(em, 'diverged') == 0, &
                 'recovering step reports spatial qualification rather than temporal divergence')
    CALL require(recovered_intervals(m) == n_before, &
                 'tensile-safety rejection does not attempt temporal subdivision')
    CALL require(nan_max_abs(m%q - q_before) <= TINY(1.0_wp), &
                 'recovering tensile-safety rejection preserves the committed state')
    CALL CD_HermiteCable_Dyn_Set_Tensile_Monitor(m, CD_HCDYN_TENSILE_WARN, es, em)
    CALL require(es == CD_HCDYN_OK, 'enable non-fatal tensile monitor: '//TRIM(em))
    CALL CD_HermiteCable_Dyn_Step(m, 0.01_wp, 20, 1.0e-9_wp, es, em)
    CALL require(es == CD_HCDYN_OK, 'tensile monitor commits a resolved compression event: '//TRIM(em))
    CALL CD_HermiteCable_Dyn_Get_Tensile_Diagnostics(m, event_count, worst_force, worst_threshold, &
                                                     worst_element, worst_xi, worst_time, es, em)
    CALL require(es == CD_HCDYN_OK .AND. event_count == 1, &
                 'tensile monitor counts the accepted compressed step')
    CALL require(worst_force < -worst_threshold .AND. worst_element > 0 .AND. &
                 worst_xi >= 0.0_wp .AND. worst_xi <= 1.0_wp, &
                 'tensile monitor reports the worst force, threshold, element, and xi')
    CALL require(worst_time > 0.0_wp .AND. worst_time <= m%t, &
                 'tensile monitor reports the accepted event time')
    CALL CD_HermiteCable_Dyn_Set_Tensile_Monitor(m, CD_HCDYN_TENSILE_WARN, es, em, &
                                                 strain_tolerance=2.0e-2_wp)
    CALL require(es == CD_HCDYN_OK, 'configure engineering tensile tolerance: '//TRIM(em))
    CALL CD_HermiteCable_Dyn_Step(m, 0.01_wp, 20, 1.0e-9_wp, es, em)
    CALL require(es == CD_HCDYN_OK, 'custom tensile tolerance step: '//TRIM(em))
    CALL CD_HermiteCable_Dyn_Get_Tensile_Diagnostics(m, event_count, worst_force, worst_threshold, &
                                                     worst_element, worst_xi, worst_time, es, em)
    CALL require(event_count == 0, 'custom tensile tolerance suppresses only sub-threshold events')
    CALL CD_HermiteCable_Dyn_End(m)
    DEALLOCATE (l0, EAv, EIv, rhoAv, wv, seed, fx, q_before)
  END SUBROUTINE check_tensile_safety

  SUBROUTINE check_prescribe_then_release()
    !! Regression for the held-vs-prescribed boundary fix: a fixed DOF driven by pres_* and then
    !! RELEASED (omitted from pres_dofs) must be held at rest at its last position, not keep drifting
    !! at its last prescribed velocity. Drive one pinned end's r_z at a constant velocity, release it
    !! while that velocity is non-zero, then confirm it stops and stays put.
    TYPE(CD_HermiteCableDynType) :: m
    REAL(wp), ALLOCATABLE :: l0(:), EAv(:), EIv(:), rhoAv(:), wv(:), seed(:)
    INTEGER, ALLOCATABLE :: fx(:)
    REAL(wp), PARAMETER :: DT = 0.05_wp, VEL = 0.01_wp
    REAL(wp) :: z_held, t
    INTEGER :: es, s, pd(1)
    REAL(wp) :: pq(1), pv(1), pa(1)
    CHARACTER(300) :: em
    CALL build_beam(0.0_wp, l0, EAv, EIv, rhoAv, wv, seed, fx)
    CALL CD_HermiteCable_Dyn_Init(m, l0, EAv, EIv, rhoAv, wv, seed, fx, 0.0_wp, 0.0_wp, 0.9_wp, es, em)
    CALL require(es == CD_HCDYN_OK, 'prescribe-release init: '//TRIM(em))
    pd(1) = 3                              ! node-1 r_z (a pinned end, in fixed_dofs)
    ! Drive it at a constant upward velocity for 4 steps (leaves v_n = VEL, a non-zero rate).
    DO s = 1, 4
      t = REAL(s, wp)*DT
      pq(1) = VEL*t; pv(1) = VEL; pa(1) = 0.0_wp
      CALL CD_HermiteCable_Dyn_Step(m, DT, 40, 1.0e-8_wp, es, em, &
                                    pres_dofs=pd, pres_q=pq, pres_v=pv, pres_a=pa)
      CALL require(es == CD_HCDYN_OK, 'prescribe-release drive step: '//TRIM(em))
    END DO
    z_held = m%q(3)
    ! Release: step with NO prescribed motion; the end must be held, not drift at VEL.
    DO s = 1, 6
      CALL CD_HermiteCable_Dyn_Step(m, DT, 40, 1.0e-8_wp, es, em)
      CALL require(es == CD_HCDYN_OK, 'prescribe-release held step: '//TRIM(em))
    END DO
    CALL require(ABS(m%q(3) - z_held) < 1.0e-10_wp, 'released fixed DOF is held at its last position')
    CALL require(ABS(m%v(3)) < 1.0e-10_wp, 'released fixed DOF velocity returns to zero (no drift)')
    CALL CD_HermiteCable_Dyn_End(m)
    DEALLOCATE (l0, EAv, EIv, rhoAv, wv, seed, fx)
  END SUBROUTINE check_prescribe_then_release

  SUBROUTINE check_modified_newton()
    !! Modified Newton (within-step tangent reuse, contraction-gated): on a vigorously
    !! vibrating beam at a TIGHT tolerance, the reuse variant must (a) converge every
    !! step, (b) land on the full-Newton trajectory (both variants satisfy the same
    !! committed tolerance, so their states agree to the tolerance's precision -- gated
    !! well above round-off, far below the response), (c) MECHANISM: assemble strictly
    !! fewer tangents than full Newton for the same run, and (d) fail closed on an
    !! uninitialised model. The default-off path is covered by every other gate in this
    !! program (the flag defaults false).
    TYPE(CD_HermiteCableDynType) :: mfull, mmn
    REAL(wp), ALLOCATABLE :: l0(:), EAv(:), EIv(:), rhoAv(:), wv(:), seed(:)
    INTEGER, ALLOCATABLE :: fx(:)
    REAL(wp) :: dt, maxdq, tf, tr, te, ts, ta
    INTEGER :: es, s, nsf, nrf, nvf, naf, nlf, ntan_full, ntan_mn
    CHARACTER(300) :: em
    REAL(wp), PARAMETER :: TOLN = 1.0e-9_wp
    INTEGER, PARAMETER :: NSTEP = 60

    CALL build_beam(0.5_wp, l0, EAv, EIv, rhoAv, wv, seed, fx)
    dt = 0.02_wp

    ! fail-closed: the setter rejects an uninitialised model
    CALL CD_HermiteCable_Dyn_Set_ModifiedNewton(mmn, .TRUE., es, em)
    CALL require(es /= CD_HCDYN_OK, 'mn: setter fails closed on an uninitialised model')

    CALL CD_HermiteCable_Dyn_Init(mfull, l0, EAv, EIv, rhoAv, wv, seed, fx, 0.0_wp, 0.0_wp, 0.9_wp, es, em)
    CALL require(es == CD_HCDYN_OK, 'mn: full init: '//TRIM(em))
    CALL CD_HermiteCable_Dyn_Init(mmn, l0, EAv, EIv, rhoAv, wv, seed, fx, 0.0_wp, 0.0_wp, 0.9_wp, es, em)
    CALL require(es == CD_HCDYN_OK, 'mn: mn init: '//TRIM(em))
    CALL CD_HermiteCable_Dyn_Set_ModifiedNewton(mmn, .TRUE., es, em)
    CALL require(es == CD_HCDYN_OK, 'mn: setter: '//TRIM(em))

    CALL CD_HermiteCable_Dyn_Reset_Profile()
    DO s = 1, NSTEP
      CALL CD_HermiteCable_Dyn_Step(mfull, dt, 60, TOLN, es, em)
      CALL require(es == CD_HCDYN_OK, 'mn: full-Newton step: '//TRIM(em))
    END DO
    CALL CD_HermiteCable_Dyn_Get_Profile(nsf, nrf, nvf, naf, nlf, tf, tr, te, ts, ta, n_tan=ntan_full)

    CALL CD_HermiteCable_Dyn_Reset_Profile()
    DO s = 1, NSTEP
      CALL CD_HermiteCable_Dyn_Step(mmn, dt, 60, TOLN, es, em)
      CALL require(es == CD_HCDYN_OK, 'mn: reuse step: '//TRIM(em))
    END DO
    CALL CD_HermiteCable_Dyn_Get_Profile(nsf, nrf, nvf, naf, nlf, tf, tr, te, ts, ta, n_tan=ntan_mn)

    maxdq = nan_max_abs(mfull%q - mmn%q)
    CALL require(maxdq < 1.0e-6_wp, 'mn: trajectory matches full Newton at tight tolerance')
    CALL require(ntan_mn < ntan_full, 'mn: strictly fewer tangent assemblies than full Newton')

    CALL CD_HermiteCable_Dyn_End(mfull)
    CALL CD_HermiteCable_Dyn_End(mmn)
    DEALLOCATE (l0, EAv, EIv, rhoAv, wv, seed, fx)
  END SUBROUTINE check_modified_newton

  SUBROUTINE check_adaptive_newton()
    !! Adaptive modified Newton: full Newton during the warmup, then latch tangent reuse ON
    !! for the rest of the run iff the warmup averaged more than `threshold` iters/step.
    !! Verify (a) fail-closed on an uninitialised model + bad params; (b) a HIGH threshold
    !! never activates -> bit-identical to full Newton, same tangent-assembly count; (c) a LOW
    !! threshold activates after the warmup -> strictly fewer tangent assemblies, trajectory
    !! matching full Newton to tight tolerance.
    TYPE(CD_HermiteCableDynType) :: mfull, mhi, meq, mlo, mprobe
    REAL(wp), ALLOCATABLE :: l0(:), EAv(:), EIv(:), rhoAv(:), wv(:), seed(:)
    INTEGER, ALLOCATABLE :: fx(:)
    REAL(wp) :: dt, tf, tr, te, ts, ta, threshold_eq
    INTEGER :: es, s, nsf, nrf, nvf, naf, nlf, ntan_full, ntan_hi, ntan_eq, ntan_lo
    INTEGER :: nsolve_warm
    CHARACTER(300) :: em
    REAL(wp), PARAMETER :: TOLN = 1.0e-9_wp
    INTEGER, PARAMETER :: NSTEP = 40, WARM = 4

    CALL build_beam(0.5_wp, l0, EAv, EIv, rhoAv, wv, seed, fx)
    dt = 0.02_wp

    ! fail-closed: the setter rejects an uninitialised model
    CALL CD_HermiteCable_Dyn_Set_AdaptiveNewton(mhi, .TRUE., es, em)
    CALL require(es /= CD_HCDYN_OK, 'adapt: setter fails closed on an uninitialised model')

    CALL CD_HermiteCable_Dyn_Init(mfull, l0, EAv, EIv, rhoAv, wv, seed, fx, 0.0_wp, 0.0_wp, 0.9_wp, es, em)
    CALL require(es == CD_HCDYN_OK, 'adapt: full init: '//TRIM(em))
    CALL CD_HermiteCable_Dyn_Init(mhi, l0, EAv, EIv, rhoAv, wv, seed, fx, 0.0_wp, 0.0_wp, 0.9_wp, es, em)
    CALL require(es == CD_HCDYN_OK, 'adapt: hi init: '//TRIM(em))
    CALL CD_HermiteCable_Dyn_Init(meq, l0, EAv, EIv, rhoAv, wv, seed, fx, 0.0_wp, 0.0_wp, 0.9_wp, es, em)
    CALL require(es == CD_HCDYN_OK, 'adapt: eq init: '//TRIM(em))
    CALL CD_HermiteCable_Dyn_Init(mlo, l0, EAv, EIv, rhoAv, wv, seed, fx, 0.0_wp, 0.0_wp, 0.9_wp, es, em)
    CALL require(es == CD_HCDYN_OK, 'adapt: lo init: '//TRIM(em))
    CALL CD_HermiteCable_Dyn_Init(mprobe, l0, EAv, EIv, rhoAv, wv, seed, fx, 0.0_wp, 0.0_wp, 0.9_wp, es, em)
    CALL require(es == CD_HCDYN_OK, 'adapt: probe init: '//TRIM(em))

    ! fail-closed on bad parameters
    CALL CD_HermiteCable_Dyn_Set_AdaptiveNewton(mhi, .TRUE., es, em, warmup=0)
    CALL require(es /= CD_HCDYN_OK, 'adapt: warmup < 1 fails closed')
    CALL CD_HermiteCable_Dyn_Set_AdaptiveNewton(mhi, .TRUE., es, em, threshold=-1.0_wp)
    CALL require(es /= CD_HCDYN_OK, 'adapt: threshold <= 0 fails closed')

    CALL CD_HermiteCable_Dyn_Reset_Profile()
    DO s = 1, WARM
      CALL CD_HermiteCable_Dyn_Step(mprobe, dt, 60, TOLN, es, em)
      CALL require(es == CD_HCDYN_OK, 'adapt: probe step: '//TRIM(em))
    END DO
    CALL CD_HermiteCable_Dyn_Get_Profile(nsf, nrf, nsolve_warm, naf, nlf, tf, tr, te, ts, ta)
    CALL require(nsolve_warm > 0, 'adapt: probe counted warmup solves')
    threshold_eq = REAL(nsolve_warm, wp)/REAL(WARM, wp)
    CALL CD_HermiteCable_Dyn_End(mprobe)

    ! HIGH threshold: the warmup can never exceed it, so adaptive stays full Newton
    CALL CD_HermiteCable_Dyn_Set_AdaptiveNewton(mhi, .TRUE., es, em, warmup=WARM, threshold=1.0e6_wp)
    CALL require(es == CD_HCDYN_OK, 'adapt: hi setter: '//TRIM(em))
    ! EQUAL threshold: the policy is strictly greater-than. This pins the warmup
    ! counter to actual linear solves; an off-by-one loop counter would enable reuse.
    CALL CD_HermiteCable_Dyn_Set_AdaptiveNewton(meq, .TRUE., es, em, warmup=WARM, threshold=threshold_eq)
    CALL require(es == CD_HCDYN_OK, 'adapt: eq setter: '//TRIM(em))
    ! LOW threshold: any warmup that performs at least one solve/step activates reuse afterwards.
    CALL CD_HermiteCable_Dyn_Set_AdaptiveNewton(mlo, .TRUE., es, em, warmup=WARM, threshold=0.5_wp)
    CALL require(es == CD_HCDYN_OK, 'adapt: lo setter: '//TRIM(em))

    CALL CD_HermiteCable_Dyn_Reset_Profile()
    DO s = 1, NSTEP
      CALL CD_HermiteCable_Dyn_Step(mfull, dt, 60, TOLN, es, em)
      CALL require(es == CD_HCDYN_OK, 'adapt: full step: '//TRIM(em))
    END DO
    CALL CD_HermiteCable_Dyn_Get_Profile(nsf, nrf, nvf, naf, nlf, tf, tr, te, ts, ta, n_tan=ntan_full)

    CALL CD_HermiteCable_Dyn_Reset_Profile()
    DO s = 1, NSTEP
      CALL CD_HermiteCable_Dyn_Step(mhi, dt, 60, TOLN, es, em)
      CALL require(es == CD_HCDYN_OK, 'adapt: hi step: '//TRIM(em))
    END DO
    CALL CD_HermiteCable_Dyn_Get_Profile(nsf, nrf, nvf, naf, nlf, tf, tr, te, ts, ta, n_tan=ntan_hi)

    CALL CD_HermiteCable_Dyn_Reset_Profile()
    DO s = 1, NSTEP
      CALL CD_HermiteCable_Dyn_Step(meq, dt, 60, TOLN, es, em)
      CALL require(es == CD_HCDYN_OK, 'adapt: eq step: '//TRIM(em))
    END DO
    CALL CD_HermiteCable_Dyn_Get_Profile(nsf, nrf, nvf, naf, nlf, tf, tr, te, ts, ta, n_tan=ntan_eq)

    CALL CD_HermiteCable_Dyn_Reset_Profile()
    DO s = 1, NSTEP
      CALL CD_HermiteCable_Dyn_Step(mlo, dt, 60, TOLN, es, em)
      CALL require(es == CD_HCDYN_OK, 'adapt: lo step: '//TRIM(em))
    END DO
    CALL CD_HermiteCable_Dyn_Get_Profile(nsf, nrf, nvf, naf, nlf, tf, tr, te, ts, ta, n_tan=ntan_lo)

    CALL require(nan_max_abs(mfull%q - mhi%q) <= 0.0_wp, 'adapt: hi threshold is bit-identical to full Newton')
    CALL require(ntan_hi == ntan_full, 'adapt: hi threshold assembles the tangent every iteration (full)')
    CALL require(nan_max_abs(mfull%q - meq%q) <= 0.0_wp, 'adapt: equal threshold is bit-identical to full Newton')
    CALL require(ntan_eq == ntan_full, 'adapt: equal threshold does not activate tangent reuse')
    CALL require(nan_max_abs(mfull%q - mlo%q) < 1.0e-6_wp, 'adapt: lo threshold trajectory matches full Newton')
    CALL require(ntan_lo < ntan_full, 'adapt: lo threshold reuses the tangent after warmup (fewer assemblies)')

    CALL CD_HermiteCable_Dyn_End(mfull)
    CALL CD_HermiteCable_Dyn_End(mhi)
    CALL CD_HermiteCable_Dyn_End(meq)
    CALL CD_HermiteCable_Dyn_End(mlo)
    DEALLOCATE (l0, EAv, EIv, rhoAv, wv, seed, fx)
  END SUBROUTINE check_adaptive_newton

  SUBROUTINE check_recovering_step()
    !! The adaptive-substep recovery wrapper CD_HermiteCable_Dyn_Step_Recovering -- the wave-loaded
    !! finite-EI analogue of the EI=0 system's subdivision fallback. Three contracts:
    !!  (1) COMMON PATH: on a converging interval it is BIT-IDENTICAL to CD_HermiteCable_Dyn_Step and
    !!      does not trip the recovery counter (zero overhead, zero behaviour change on the hot path).
    !!  (2) RECOVERY: on an interval that genuinely DIVERGES at the full step (verified here -- the
    !!      plain step returns NOCONVERGE from the same state) the wrapper substeps internally, lands
    !!      at exactly the same t+dt with the prescribed boundary on its target, and increments the count.
    !!  (3) ACCEPTED-STATE QUALITY: a Newton-converged but mesh-under-resolved displacement is
    !!      rejected by the temporal gate and recovered through subdivision.
    !!  (4) the count accessor + reset behave.
    TYPE(CD_HermiteCableDynType) :: m1, m2, mp, mr, mq, mrq, mk, mm, mf, mfg_probe, mfg, mn, mu
    REAL(wp), ALLOCATABLE :: l0(:), EAv(:), EIv(:), rhoAv(:), wv(:), seed(:)
    INTEGER, ALLOCATABLE :: fx(:)
    REAL(wp), PARAMETER :: DTC = 0.05_wp        ! converging step for the identity check
    REAL(wp), PARAMETER :: DTV = 1.0_wp         ! one hard interval for the recovery check
    REAL(wp), PARAMETER :: ZJUMP = -6.0_wp      ! 6 m single-step deflection of the 10 m beam
    INTEGER, PARAMETER :: MAXIT_HARD = 4        ! iteration budget the full jump exceeds but each substep meets
    INTEGER :: es, s, pd(1), pd_fail(1), n0, recovery_events, recovery_max_used
    REAL(wp) :: pq(1), pv(1), pa(1), qf(1), vf(1), af(1), qk(1), vk(1), ak(1)
    CHARACTER(300) :: em

    ! --- (1) common-path identity: plain vs recovering on a converging driven step ---
    CALL build_beam(0.0_wp, l0, EAv, EIv, rhoAv, wv, seed, fx)
    CALL CD_HermiteCable_Dyn_Init(m1, l0, EAv, EIv, rhoAv, wv, seed, fx, 0.0_wp, 0.0_wp, 0.9_wp, es, em)
    CALL require(es == CD_HCDYN_OK, 'recovering identity init m1: '//TRIM(em))
    CALL CD_HermiteCable_Dyn_Init(m2, l0, EAv, EIv, rhoAv, wv, seed, fx, 0.0_wp, 0.0_wp, 0.9_wp, es, em)
    CALL require(es == CD_HCDYN_OK, 'recovering identity init m2: '//TRIM(em))
    pd(1) = 3
    DO s = 1, 5
      pq(1) = 0.002_wp*REAL(s, wp); pv(1) = 0.002_wp/DTC; pa(1) = 0.0_wp
      CALL CD_HermiteCable_Dyn_Step(m1, DTC, 40, 1.0e-9_wp, es, em, &
                                    pres_dofs=pd, pres_q=pq, pres_v=pv, pres_a=pa)
      CALL require(es == CD_HCDYN_OK, 'recovering identity plain step: '//TRIM(em))
      CALL CD_HermiteCable_Dyn_Step_Recovering(m2, DTC, 40, 1.0e-9_wp, es, em, &
                                               pres_dofs=pd, pres_q=pq, pres_v=pv, pres_a=pa)
      CALL require(es == CD_HCDYN_OK, 'recovering identity wrapper step: '//TRIM(em))
    END DO
    CALL require(nan_max_abs(m1%q - m2%q) <= 0.0_wp, 'recovering wrapper q bit-identical on a converging step')
    CALL require(nan_max_abs(m1%v - m2%v) <= 0.0_wp, 'recovering wrapper v bit-identical on a converging step')
    CALL require(nan_max_abs(m1%a - m2%a) <= 0.0_wp, 'recovering wrapper a bit-identical on a converging step')
    CALL require(recovered_intervals(m2) == 0, 'no recovery on converging steps (count stays 0)')
    CALL CD_HermiteCable_Dyn_End(m1)
    CALL CD_HermiteCable_Dyn_End(m2)

    ! --- (2) recovery: a violent single interval that diverges at the full step ---
    CALL CD_HermiteCable_Dyn_Init(mp, l0, EAv, EIv, rhoAv, wv, seed, fx, 0.0_wp, 0.0_wp, 0.9_wp, es, em)
    CALL require(es == CD_HCDYN_OK, 'recovering probe init: '//TRIM(em))
    CALL CD_HermiteCable_Dyn_Init(mr, l0, EAv, EIv, rhoAv, wv, seed, fx, 0.0_wp, 0.0_wp, 0.9_wp, es, em)
    CALL require(es == CD_HCDYN_OK, 'recovering target init: '//TRIM(em))
    pq(1) = ZJUMP; pv(1) = ZJUMP/DTV; pa(1) = 0.0_wp
    ! Probe: the plain full step must genuinely FAIL on this interval. A big single-step deflection
    ! under a tight iteration budget MAXIT_HARD needs more Newton iterations than the budget allows
    ! (NOCONVERGE), while each dt/n substep is a small increment that meets the same budget -- so the
    ! substep ladder is exactly what turns the failure into a success. (If this ever passes, the case
    ! became too easy: lower MAXIT_HARD or raise |ZJUMP|.)
    CALL CD_HermiteCable_Dyn_Step(mp, DTV, MAXIT_HARD, 1.0e-6_wp, es, em, &
                                  pres_dofs=pd, pres_q=pq, pres_v=pv, pres_a=pa)
    CALL require(es == CD_HCDYN_NOCONVERGE, 'recovery probe: plain full step diverges on the hard interval')
    ! Wrapper on the same interval + same budget: substeps and completes, landing at t+dt on target.
    ! the armed step profile counts the recovered interval too (process-wide, with its reset)
    CALL CD_HermiteCable_Dyn_Reset_Profile()
    CALL CD_HermiteCable_Dyn_Recovery_Reset()
    n0 = recovered_intervals(mr)
    CALL CD_HermiteCable_Dyn_Step_Recovering(mr, DTV, MAXIT_HARD, 1.0e-6_wp, es, em, &
                                             pres_dofs=pd, pres_q=pq, pres_v=pv, pres_a=pa)
    CALL require(es == CD_HCDYN_OK, 'recovery: wrapper completes the violent interval via substepping: '//TRIM(em))
    CALL require(recovered_intervals(mr) == n0 + 1, 'recovery: the substep tripwire incremented')
    CALL require(CD_HermiteCable_Dyn_Recovery_Count() == 1, 'recovery: the armed profile counts the interval')
    CALL require(ABS(mr%q(3) - ZJUMP) < 1.0e-10_wp, 'recovery: prescribed boundary landed exactly on target')
    CALL require(ABS(mr%t - DTV) < 1.0e-9_wp, 'recovery: cable landed at t+dt (fixed-dt aggregate contract)')
    CALL CD_HermiteCable_Dyn_Recovery_Reset()
    CALL require(CD_HermiteCable_Dyn_Recovery_Count() == 0, 'recovery tripwire zero after reset')
    CALL CD_HermiteCable_Dyn_Disable_Profile()

    ! --- (3) a converged full step can still be temporally under-resolved ---
    CALL CD_HermiteCable_Dyn_Init(mq, l0, EAv, EIv, rhoAv, wv, seed, fx, 0.0_wp, 0.0_wp, 0.9_wp, es, em)
    CALL require(es == CD_HCDYN_OK, 'quality-gate probe init: '//TRIM(em))
    CALL CD_HermiteCable_Dyn_Init(mrq, l0, EAv, EIv, rhoAv, wv, seed, fx, 0.0_wp, 0.0_wp, 0.9_wp, es, em)
    CALL require(es == CD_HCDYN_OK, 'quality-gate recovery init: '//TRIM(em))
    CALL CD_HermiteCable_Dyn_Step(mq, DTV, 40, 1.0e-6_wp, es, em, &
                                  pres_dofs=pd, pres_q=pq, pres_v=pv, pres_a=pa)
    CALL require(es == CD_HCDYN_OK, 'quality-gate probe: full step is Newton-converged')
    CALL CD_HermiteCable_Dyn_Step_Recovering(mrq, DTV, 40, 1.0e-6_wp, es, em, &
                                             pres_dofs=pd, pres_q=pq, pres_v=pv, pres_a=pa)
    CALL require(es == CD_HCDYN_OK, 'quality-gate recovery: under-resolved step subdivides: '//TRIM(em))
    CALL require(recovered_intervals(mrq) == 1, &
                 'quality-gate recovery: converged but under-resolved interval counted')
    CALL require(ABS(mrq%q(3) - ZJUMP) < 1.0e-10_wp, 'quality-gate recovery lands on prescribed target')
    CALL CD_HermiteCable_Dyn_End(mq)
    CALL CD_HermiteCable_Dyn_End(mrq)

    ! Recovery interpolation must be one C2 trajectory. Compare a quality-gate recovery limited
    ! to four substeps with the same four ordinary steps driven by an independently evaluated
    ! quintic position and its exact time derivatives. Independent linear q/v/a ramps do not pass
    ! this state-equivalence check.
    CALL CD_HermiteCable_Dyn_Init(mk, l0, EAv, EIv, rhoAv, wv, seed, fx, 0.0_wp, 0.0_wp, 0.9_wp, es, em)
    CALL require(es == CD_HCDYN_OK, 'quintic recovery init: '//TRIM(em))
    CALL CD_HermiteCable_Dyn_Init(mm, l0, EAv, EIv, rhoAv, wv, seed, fx, 0.0_wp, 0.0_wp, 0.9_wp, es, em)
    CALL require(es == CD_HCDYN_OK, 'quintic manual init: '//TRIM(em))
    ! A 2 m end deflection of the 10 m beam in one interval turns the end tangents past the
    ! temporal gate's limit, while each quarter step is resolved (the gate measures
    ! deformation, so a smaller, nearly rigid rotation of the beam is accepted whole).
    pq = [-2.0_wp]; pv = [0.3_wp]; pa = [0.1_wp]
    CALL CD_HermiteCable_Dyn_Step_Recovering(mk, DTV, 40, 1.0e-6_wp, es, em, &
                                             pres_dofs=pd, pres_q=pq, pres_v=pv, pres_a=pa, &
                                             max_substeps=4)
    CALL require(es == CD_HCDYN_OK, 'quintic recovery completes on four substeps: '//TRIM(em))
    CALL require(recovered_intervals(mk) == 1, 'quintic comparison exercised recovery')
    CALL CD_HermiteCable_Dyn_Get_Recovery_Diagnostics(mk, recovery_events, recovery_max_used, es, em)
    CALL require(es == CD_HCDYN_OK .AND. recovery_events == 1 .AND. recovery_max_used == 4, &
                 'recovery diagnostics report the committed interval and winning rung')
    DO s = 1, 4
      CALL test_quintic_state([0.0_wp], [0.0_wp], [0.0_wp], pq, pv, pa, DTV, &
                              REAL(s, wp)/4.0_wp, qk, vk, ak)
      CALL CD_HermiteCable_Dyn_Step(mm, DTV/4.0_wp, 40, 1.0e-6_wp, es, em, &
                                    pres_dofs=pd, pres_q=qk, pres_v=vk, pres_a=ak)
      CALL require(es == CD_HCDYN_OK, 'manual quintic comparison step: '//TRIM(em))
    END DO
    CALL require(nan_max_abs(mk%q - mm%q) < 1.0e-11_wp, 'recovery follows the quintic q trajectory')
    CALL require(nan_max_abs(mk%v - mm%v) < 1.0e-11_wp, 'recovery follows the derivative v trajectory')
    CALL require(nan_max_abs(mk%a - mm%a) < 1.0e-10_wp, 'recovery follows the derivative a trajectory')
    CALL CD_HermiteCable_Dyn_End(mk)
    CALL CD_HermiteCable_Dyn_End(mm)

    ! A true NOCONVERGE must restore the committed model state, not ws_vn/ws_an: Step prepares
    ! those workspaces by zeroing fixed DOFs that are not prescribed in the current interval.
    CALL CD_HermiteCable_Dyn_Init(mf, l0, EAv, EIv, rhoAv, wv, seed, fx, 0.0_wp, 0.0_wp, 0.9_wp, es, em)
    CALL require(es == CD_HCDYN_OK, 'failure-atomic released-boundary init: '//TRIM(em))
    mf%v(5) = 2.0_wp; mf%a(5) = 3.0_wp
    pd_fail = [3]; qf = [ZJUMP]; vf = [ZJUMP/DTV]; af = [0.0_wp]
    CALL CD_HermiteCable_Dyn_Step_Recovering(mf, DTV, 1, 1.0e-30_wp, es, em, &
                                             pres_dofs=pd_fail, pres_q=qf, pres_v=vf, pres_a=af)
    CALL require(es == CD_HCDYN_NOCONVERGE, 'failure-atomic probe exhausts every recovery rung')
    CALL require(ABS(mf%v(5) - 2.0_wp) <= 0.0_wp .AND. ABS(mf%a(5) - 3.0_wp) <= 0.0_wp, &
                 'failure-atomic recovery preserves released boundary v/a')
    CALL CD_HermiteCable_Dyn_End(mf)

    ! Exercise the other rollback entrance explicitly: a full step can converge, be rejected by the
    ! temporal quality gate, and then exhaust every subdivision because even dt/256 rotates the
    ! prescribed tangent by more than the mesh-aware limit. Its final failure must restore the same
    ! pre-call fixed-DOF history as the genuine-Newton-failure path above.
    CALL CD_HermiteCable_Dyn_Init(mfg_probe, l0, EAv, EIv, rhoAv, wv, seed, fx, &
                                  0.0_wp, 0.0_wp, 0.9_wp, es, em)
    CALL require(es == CD_HCDYN_OK, 'quality-failure probe init: '//TRIM(em))
    CALL CD_HermiteCable_Dyn_Init(mfg, l0, EAv, EIv, rhoAv, wv, seed, fx, 0.0_wp, 0.0_wp, 0.9_wp, es, em)
    CALL require(es == CD_HCDYN_OK, 'quality-failure recovery init: '//TRIM(em))
    pd_fail = [5]; qf = [1.0e6_wp]; vf = [1.0e6_wp/DTV]; af = [0.0_wp]
    CALL CD_HermiteCable_Dyn_Step(mfg_probe, DTV, 40, 1.0e-6_wp, es, em, &
                                  pres_dofs=pd_fail, pres_q=qf, pres_v=vf, pres_a=af)
    CALL require(es == CD_HCDYN_OK, 'quality-failure probe full step is Newton-converged: '//TRIM(em))
    mfg%v(2) = 4.0_wp; mfg%a(2) = 5.0_wp
    CALL CD_HermiteCable_Dyn_Step_Recovering(mfg, DTV, 40, 1.0e-6_wp, es, em, &
                                             pres_dofs=pd_fail, pres_q=qf, pres_v=vf, pres_a=af)
    CALL require(es == CD_HCDYN_NOCONVERGE, 'quality-failure probe exhausts the temporal recovery ladder')
    CALL require(ABS(mfg%v(2) - 4.0_wp) <= 0.0_wp .AND. ABS(mfg%a(2) - 5.0_wp) <= 0.0_wp, &
                 'quality-gate failure restores the exact pre-call fixed-DOF v/a')
    CALL CD_HermiteCable_Dyn_End(mfg_probe)
    CALL CD_HermiteCable_Dyn_End(mfg)

    ! The public wrapper must reject a default-constructed model before accessing persistent
    ! recovery workspace (the plain Step routine has the same fail-closed API contract).
    CALL CD_HermiteCable_Dyn_Step_Recovering(mu, DTV, MAXIT_HARD, 1.0e-6_wp, es, em)
    CALL require(es == CD_HCDYN_BADINPUT, 'recovering wrapper rejects an uninitialised model')

    ! --- (4) reject a partial prescribed-motion set at the wrapper (mirrors the inner step) ---
    ! Passing pres_dofs + pres_q but omitting pres_v/pres_a must fail as bad input, not silently run
    ! the boundary as held.
    CALL CD_HermiteCable_Dyn_Step_Recovering(mp, DTV, MAXIT_HARD, 1.0e-6_wp, es, em, pres_dofs=pd, pres_q=pq)
    CALL require(es == CD_HCDYN_BADINPUT, 'recovering wrapper rejects a partial prescribed-motion set')

    ! --- (4) adaptive-Newton counters survive the subdivision rewind ---
    ! With adaptive Newton enabled, every successful inner step bumps na_steps_done. A recovery that
    ! rewinds failed rungs must reset those counters too, so the committed na_steps_done reflects only
    ! the winning rung (<= its substep count), never the sum over the failed rungs it tried first.
    CALL CD_HermiteCable_Dyn_Init(mn, l0, EAv, EIv, rhoAv, wv, seed, fx, 0.0_wp, 0.0_wp, 0.9_wp, es, em)
    CALL require(es == CD_HCDYN_OK, 'recovery adaptive-Newton init: '//TRIM(em))
    CALL CD_HermiteCable_Dyn_Set_AdaptiveNewton(mn, .TRUE., es, em, warmup=1000, threshold=5.0_wp)
    CALL require(es == CD_HCDYN_OK, 'recovery adaptive-Newton enable: '//TRIM(em))
    pq(1) = ZJUMP; pv(1) = ZJUMP/DTV; pa(1) = 0.0_wp
    CALL CD_HermiteCable_Dyn_Step_Recovering(mn, DTV, MAXIT_HARD, 1.0e-6_wp, es, em, &
                                             pres_dofs=pd, pres_q=pq, pres_v=pv, pres_a=pa)
    CALL require(es == CD_HCDYN_OK, 'recovery adaptive-Newton: wrapper completes the hard interval')
    CALL require(mn%na_steps_done <= 1024, 'recovery adaptive-Newton: na_steps_done not inflated by failed rungs')

    CALL CD_HermiteCable_Dyn_End(mp)
    CALL CD_HermiteCable_Dyn_End(mr)
    CALL CD_HermiteCable_Dyn_End(mn)
    DEALLOCATE (l0, EAv, EIv, rhoAv, wv, seed, fx)
  END SUBROUTINE check_recovering_step

  SUBROUTINE test_quintic_state(q0, v0, a0, q1, v1, a1, duration, u, q, v, a)
    !! Independent test oracle for the C2 endpoint trajectory used by recovery.
    REAL(wp), INTENT(IN) :: q0(:), v0(:), a0(:), q1(:), v1(:), a1(:), duration, u
    REAL(wp), INTENT(OUT) :: q(:), v(:), a(:)
    REAL(wp) :: u2, u3, u4, u5, t2
    u2 = u*u; u3 = u2*u; u4 = u3*u; u5 = u4*u; t2 = duration*duration
    q = (1.0_wp - 10.0_wp*u3 + 15.0_wp*u4 - 6.0_wp*u5)*q0 + &
        (u - 6.0_wp*u3 + 8.0_wp*u4 - 3.0_wp*u5)*duration*v0 + &
        0.5_wp*(u2 - 3.0_wp*u3 + 3.0_wp*u4 - u5)*t2*a0 + &
        (10.0_wp*u3 - 15.0_wp*u4 + 6.0_wp*u5)*q1 + &
        (-4.0_wp*u3 + 7.0_wp*u4 - 3.0_wp*u5)*duration*v1 + &
        0.5_wp*(u3 - 2.0_wp*u4 + u5)*t2*a1
    v = (-30.0_wp*u2 + 60.0_wp*u3 - 30.0_wp*u4)*q0/duration + &
        (1.0_wp - 18.0_wp*u2 + 32.0_wp*u3 - 15.0_wp*u4)*v0 + &
        (u - 4.5_wp*u2 + 6.0_wp*u3 - 2.5_wp*u4)*duration*a0 + &
        (30.0_wp*u2 - 60.0_wp*u3 + 30.0_wp*u4)*q1/duration + &
        (-12.0_wp*u2 + 28.0_wp*u3 - 15.0_wp*u4)*v1 + &
        (1.5_wp*u2 - 4.0_wp*u3 + 2.5_wp*u4)*duration*a1
    a = (-60.0_wp*u + 180.0_wp*u2 - 120.0_wp*u3)*q0/t2 + &
        (-36.0_wp*u + 96.0_wp*u2 - 60.0_wp*u3)*v0/duration + &
        (1.0_wp - 9.0_wp*u + 18.0_wp*u2 - 10.0_wp*u3)*a0 + &
        (60.0_wp*u - 180.0_wp*u2 + 120.0_wp*u3)*q1/t2 + &
        (-24.0_wp*u + 84.0_wp*u2 - 60.0_wp*u3)*v1/duration + &
        (3.0_wp*u - 12.0_wp*u2 + 10.0_wp*u3)*a1
  END SUBROUTINE test_quintic_state

  INTEGER FUNCTION recovered_intervals(model) RESULT(n)
    !! The intervals the model completed by internal substeps (its recovery diagnostics).
    TYPE(CD_HermiteCableDynType), INTENT(IN) :: model
    INTEGER :: max_used, es
    CHARACTER(256) :: em
    CALL CD_HermiteCable_Dyn_Get_Recovery_Diagnostics(model, n, max_used, es, em)
  END FUNCTION recovered_intervals

  SUBROUTINE require(cond, label)
    LOGICAL, INTENT(IN) :: cond
    CHARACTER(*), INTENT(IN) :: label
    IF (.NOT. cond) THEN
      WRITE (*, '(A,A,A)') 'MISMATCH [', label, ']: condition false'
      nfail = nfail + 1
    END IF
  END SUBROUTINE require

END PROGRAM test_hermite_cable_dynamic
