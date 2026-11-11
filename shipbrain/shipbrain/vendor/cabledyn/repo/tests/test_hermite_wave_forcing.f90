! File: tests/test_hermite_wave_forcing.f90
! SPDX-License-Identifier: Apache-2.0
! Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
PROGRAM test_hermite_wave_forcing
  !! Regular (Airy) WAVE FORCING on the finite-EI Hermite dynamic cable: the wave velocity feeds the
  !! drag's fluid field and the wave acceleration drives the Froude-Krylov + fluid-inertia load with
  !! the added-mass coefficients -- the forcing that turns the damped submerged cable into the
  !! dynamic (fatigue) response problem. Gates:
  !!   A  the FK element's translational load matches an independent fine-quadrature integral of the
  !!      analytic per-length FK force along the element (validates shapes, wet culling, and the
  !!      deformed-length measure),
  !!   B  the FK geometric tangent: for an element along y under a wave along x the field is uniform
  !!      along the element, so the y-DOF columns of fjq carry NO field-gradient contribution and
  !!      must match central FD exactly (the field gradient is the documented neglected term in the
  !!      other columns),
  !!   C  PHYSICS RUN: a neutrally buoyant submerged cable with drag + added mass under a regular
  !!      wave responds at the WAVE period (crossing-measured over two periods after a one-period
  !!      warmup), with bounded nonzero amplitude, every step converging, and the model clock
  !!      advancing by n dt,
  !!   D  fail-closed: Set_Waves pre-init / without any hydro config / bad height/period/depth /
  !!      mismatched drag-vs-added-mass waterlines; partial wave arguments to the drag element.
  USE CableDyn_Precision, ONLY: wp
  USE CableDyn_Hydro, ONLY: CD_Airy_Wave_Kinematics_Precomputed, CD_Solve_Dispersion_Wavenumber, CD_HYDRO_OK
  USE CableDyn_HermiteCableDynamic, ONLY: CD_HermiteCableDynType, CD_HermiteCable_Dyn_Init, &
                                          CD_HermiteCable_Dyn_Set_Drag, CD_HermiteCable_Dyn_Set_AddedMass, &
                                          CD_HermiteCable_Dyn_Set_Waves, CD_HermiteCable_Dyn_Step, &
                                          CD_HermiteCable_Dyn_End, CD_HermiteCable_FK_Element, &
                                          CD_HermiteCable_Drag_Element, CD_HCDYN_OK
  IMPLICIT NONE

  REAL(wp), PARAMETER :: PI = 3.14159265358979323846_wp, GRAV = 9.80665_wp
  REAL(wp), PARAMETER :: LB = 10.0_wp, RHOA = 5.0_wp, EI = 100.0_wp, EA = 1.0e5_wp
  REAL(wp), PARAMETER :: RHOW = 1025.0_wp, DIAM = 0.05_wp, CDN = 1.2_wp, CDT = 0.1_wp
  REAL(wp), PARAMETER :: CAN = 1.0_wp, CAT = 0.1_wp
  REAL(wp), PARAMETER :: WVH = 2.0_wp, WVT = 8.0_wp, WVDEP = 50.0_wp
  INTEGER, PARAMETER :: NE = 10
  INTEGER :: nfail

  nfail = 0
  CALL check_fk_element_quadrature()
  CALL check_fk_geometric_jacobian()
  CALL check_crest_wetting()
  CALL check_wave_response()
  CALL check_fail_closed()

  IF (nfail > 0) THEN
    WRITE (*, '(A,I0,A)') 'FAIL: ', nfail, ' assertion(s) failed'
    ERROR STOP 1
  END IF
  WRITE (*, '(A)') 'PASS: regular-wave forcing on the Hermite dynamic cable -- FK element + wave-period response'

CONTAINS

  INCLUDE 'nan_max_abs.inc'

  SUBROUTINE wave_omk(om, k)
    REAL(wp), INTENT(OUT) :: om, k
    INTEGER :: es
    CHARACTER(300) :: em
    om = 2.0_wp*PI/WVT
    CALL CD_Solve_Dispersion_Wavenumber(om, WVDEP, GRAV, k, es, em)
    CALL require(es == CD_HYDRO_OK, 'dispersion solve: '//TRIM(em))
  END SUBROUTINE wave_omk

  SUBROUTINE check_fk_element_quadrature()
    !! FK element vs an independent 400-point trapezoid integral of the analytic per-length FK force
    !! along a straight submerged element (deformed length = reference here).
    REAL(wp) :: qe(12), ffk(12), fjq(12, 12), om, k, tref
    REAL(wp) :: xi, rx(3), eta, uw(3), aw(3), fpl(3), fint(3), area, alpha, tang(3), net(3), h
    INTEGER :: es, i, n
    CHARACTER(300) :: em
    CALL wave_omk(om, k)
    area = 0.25_wp*PI*DIAM*DIAM
    tang = [1.0_wp, 0.0_wp, 0.0_wp]
    tref = 1.7_wp                          ! arbitrary phase
    ! straight element along x at z = -10 (fully submerged), length 3
    qe = [0.0_wp, 0.0_wp, -10.0_wp, 1.0_wp, 0.0_wp, 0.0_wp, 3.0_wp, 0.0_wp, -10.0_wp, 1.0_wp, 0.0_wp, 0.0_wp]
    CALL CD_HermiteCable_FK_Element(qe, 3.0_wp, 0.0_wp, RHOW, DIAM, CAN, CAT, &
                                    WVH, om, k, WVDEP, 0.0_wp, tref, ffk, fjq, es, em)
    CALL require(es == CD_HCDYN_OK, 'FK element accepted: '//TRIM(em))
    ! independent trapezoid integral of f_perlen(x) over the element
    n = 400
    fint = 0.0_wp
    h = 3.0_wp/REAL(n, wp)
    DO i = 0, n
      xi = REAL(i, wp)*h
      rx = [xi, 0.0_wp, -10.0_wp]
      CALL CD_Airy_Wave_Kinematics_Precomputed(rx(1), rx(2), rx(3), tref, WVH, om, k, WVDEP, 0.0_wp, &
                                               .TRUE., eta, uw, aw, es, em)
      alpha = DOT_PRODUCT(aw, tang)
      fpl = RHOW*area*((1.0_wp + CAN)*aw + (CAT - CAN)*alpha*tang)
      IF (i == 0 .OR. i == n) fpl = 0.5_wp*fpl
      fint = fint + h*fpl
    END DO
    ! element net translational force = sum of the r-DOF loads (shape functions partition unity)
    net = ffk(1:3) + ffk(7:9)
    WRITE (*, '(A,3ES12.4,A,3ES12.4)') '  [FK] element net = ', net, '   quadrature = ', fint
    CALL require(nan_max_abs(net - fint)/MAX(1.0e-30_wp, nan_max_abs(fint)) < 1.0e-3_wp, &
                 'FK element net force matches the independent per-length quadrature')
  END SUBROUTINE check_fk_element_quadrature

  SUBROUTINE check_fk_geometric_jacobian()
    !! For an element along y under a wave along x the field is uniform along the element, so the
    !! y-DOF columns of fjq (b = 2, 5, 8, 11) carry no field-gradient contribution and must match
    !! central FD of ffk exactly (the geometric tangent chain).
    REAL(wp) :: qe(12), qp(12), ffk(12), fjq(12, 12), fp(12), fm(12), dj(12, 12), om, k, tref, hstep, err
    INTEGER :: es, i, ycols(4), ic
    CHARACTER(300) :: em
    CALL wave_omk(om, k)
    tref = 0.9_wp
    ! gently curved element mostly along y at z ~ -10 so the tangent chain is non-trivial
    qe = [0.0_wp, 0.0_wp, -10.0_wp, 0.0_wp, 1.0_wp, 0.05_wp, &
          0.0_wp, 3.0_wp, -9.8_wp, 0.0_wp, 1.0_wp, 0.10_wp]
    CALL CD_HermiteCable_FK_Element(qe, 3.0_wp, 0.0_wp, RHOW, DIAM, CAN, CAT, &
                                    WVH, om, k, WVDEP, 0.0_wp, tref, ffk, fjq, es, em)
    CALL require(es == CD_HCDYN_OK, 'FK Jacobian element accepted: '//TRIM(em))
    ycols = [2, 5, 8, 11]
    err = 0.0_wp
    DO ic = 1, 4
      i = ycols(ic)
      hstep = 1.0e-6_wp*MAX(1.0_wp, ABS(qe(i)))
      qp = qe; qp(i) = qe(i) + hstep
      CALL CD_HermiteCable_FK_Element(qp, 3.0_wp, 0.0_wp, RHOW, DIAM, CAN, CAT, &
                                      WVH, om, k, WVDEP, 0.0_wp, tref, fp, dj, es, em)
      qp(i) = qe(i) - hstep
      CALL CD_HermiteCable_FK_Element(qp, 3.0_wp, 0.0_wp, RHOW, DIAM, CAN, CAT, &
                                      WVH, om, k, WVDEP, 0.0_wp, tref, fm, dj, es, em)
      err = MAX(err, nan_max_abs(fjq(:, i) - (fp - fm)/(2.0_wp*hstep)))
    END DO
    err = err/MAX(1.0_wp, nan_max_abs(fjq))
    WRITE (*, '(A,ES10.3)') '  [FK] geometric tangent (field-gradient-free columns) vs FD err = ', err
    CALL require(err < 1.0e-5_wp, 'FK geometric tangent matches central FD on gradient-free columns')
  END SUBROUTINE check_fk_geometric_jacobian

  SUBROUTINE check_crest_wetting()
    !! Wetting follows the INSTANTANEOUS free surface: an element just above still water carries the
    !! wave load under a crest (eta above it) and none under a trough (eta below it). H = 2 m gives
    !! amplitude 1 m; the element sits at z = +0.3.
    REAL(wp) :: qe(12), ffk(12), fjq(12, 12), om, k, t_crest, t_trough
    INTEGER :: es
    CHARACTER(300) :: em
    CALL wave_omk(om, k)
    ! straight element along y at x = 0, z = +0.3 (above SWL, below the +1 m crest)
    qe = [0.0_wp, 0.0_wp, 0.3_wp, 0.0_wp, 1.0_wp, 0.0_wp, 0.0_wp, 3.0_wp, 0.3_wp, 0.0_wp, 1.0_wp, 0.0_wp]
    t_crest = 0.0_wp                       ! eta(0, t=0) = +H/2 = +1
    t_trough = 0.5_wp*WVT                  ! eta(0, T/2) = -H/2 = -1
    CALL CD_HermiteCable_FK_Element(qe, 3.0_wp, 0.0_wp, RHOW, DIAM, CAN, CAT, &
                                    WVH, om, k, WVDEP, 0.0_wp, t_crest, ffk, fjq, es, em)
    CALL require(es == CD_HCDYN_OK, 'crest FK accepted: '//TRIM(em))
    CALL require(nan_max_abs(ffk) > 1.0e-6_wp, 'a point above SWL under a wave crest carries the FK load')
    CALL CD_HermiteCable_FK_Element(qe, 3.0_wp, 0.0_wp, RHOW, DIAM, CAN, CAT, &
                                    WVH, om, k, WVDEP, 0.0_wp, t_trough, ffk, fjq, es, em)
    CALL require(es == CD_HCDYN_OK, 'trough FK accepted: '//TRIM(em))
    CALL require(nan_max_abs(ffk) <= 0.0_wp, 'the same point under a trough is dry (zero FK load)')
  END SUBROUTINE check_crest_wetting

  SUBROUTINE check_wave_response()
    !! Neutrally buoyant submerged cable (pinned ends, planar x-z) with drag + added mass under a
    !! regular wave: the response is periodic AT THE WAVE PERIOD, bounded, nonzero; the clock
    !! advances by n dt; every step converges.
    TYPE(CD_HermiteCableDynType) :: m
    REAL(wp), ALLOCATABLE :: l0(:), EAv(:), EIv(:), rhoAv(:), wv(:), seed(:)
    INTEGER, ALLOCATABLE :: fx(:)
    REAL(wp), PARAMETER :: DT = 0.1_wp
    REAL(wp) :: dv(NE), cn(NE), ct(NE), caN_(NE), caT_(NE), cur(3)
    REAL(wp) :: z0, zc, zprev, tc(3), T_meas, zmin, zmax, t
    INTEGER :: es, s, nn, mid_dof, nstep, ncr
    CHARACTER(300) :: em
    nn = NE + 1
    mid_dof = 6*((nn + 1)/2 - 1) + 3
    CALL build_cable(l0, EAv, EIv, rhoAv, wv, seed, fx)
    CALL CD_HermiteCable_Dyn_Init(m, l0, EAv, EIv, rhoAv, wv, seed, fx, -WVDEP, 0.0_wp, 0.5_wp, es, em)
    CALL require(es == CD_HCDYN_OK, 'wave-response init: '//TRIM(em))
    dv = DIAM; cn = CDN; ct = CDT; caN_ = CAN; caT_ = CAT; cur = 0.0_wp
    CALL CD_HermiteCable_Dyn_Set_Drag(m, RHOW, dv, cn, ct, 0.0_wp, cur, es, em)
    CALL require(es == CD_HCDYN_OK, 'wave-response drag: '//TRIM(em))
    CALL CD_HermiteCable_Dyn_Set_AddedMass(m, RHOW, dv, caN_, caT_, 0.0_wp, es, em)
    CALL require(es == CD_HCDYN_OK, 'wave-response added mass: '//TRIM(em))
    CALL CD_HermiteCable_Dyn_Set_Waves(m, WVH, WVT, 0.0_wp, WVDEP, GRAV, es, em)
    CALL require(es == CD_HCDYN_OK, 'wave-response waves: '//TRIM(em))
    CALL require(nan_max_abs(m%a) > 1.0e-6_wp, 'waves induce a nonzero consistent acceleration at rest')

    z0 = m%q(mid_dof)
    zmin = 0.0_wp; zmax = 0.0_wp
    zprev = 0.0_wp; ncr = 0; tc = 0.0_wp; t = 0.0_wp
    nstep = NINT(3.2_wp*WVT/DT)                     ! ~1 period warmup + >2 periods measured
    DO s = 1, nstep
      CALL CD_HermiteCable_Dyn_Step(m, DT, 40, 1.0e-6_wp, es, em)
      IF (es /= CD_HCDYN_OK) THEN
        CALL require(.FALSE., 'wave-response step: '//TRIM(em)); EXIT
      END IF
      t = t + DT
      zc = m%q(mid_dof) - z0
      zmin = MIN(zmin, zc); zmax = MAX(zmax, zc)
      ! downward zero crossings of the displacement, after a one-period warmup
      IF (t > WVT .AND. zprev > 0.0_wp .AND. zc <= 0.0_wp .AND. ncr < 3) THEN
        ncr = ncr + 1
        tc(ncr) = (t - DT) + DT*zprev/(zprev - zc)
      END IF
      zprev = zc
    END DO
    CALL require(es == CD_HCDYN_OK, 'all wave-forced steps converged')
    CALL require(ABS(m%t - REAL(nstep, wp)*DT) < 1.0e-9_wp, 'model clock advances by n dt')
    CALL require(zmax - zmin > 1.0e-4_wp, 'the wave actually forces a nonzero response')
    CALL require(zmax - zmin < 2.0_wp*WVH, 'the response stays bounded (below 2H)')
    CALL require(ncr == 3, 'the response completes two measured periods')
    IF (ncr == 3) THEN
      T_meas = 0.5_wp*(tc(3) - tc(1))
      ! ES format: a fixed-point '0.00%' hides the actual residual the docs must quote
      WRITE (*, '(A,F8.4,A,F8.4,A,ES10.3,A)') '  [wave] response period = ', T_meas, ' s   wave T = ', WVT, &
        ' s   err = ', 100.0_wp*ABS(T_meas - WVT)/WVT, ' %'
      CALL require(ABS(T_meas - WVT)/WVT < 0.05_wp, 'the response is periodic at the wave period (<5%)')
    END IF
    CALL CD_HermiteCable_Dyn_End(m)
    DEALLOCATE (l0, EAv, EIv, rhoAv, wv, seed, fx)
  END SUBROUTINE check_wave_response

  SUBROUTINE build_cable(l0, EAv, EIv, rhoAv, wv, seed, fixed_dofs)
    !! Straight neutrally buoyant cable along x at z = -10 (depth 50), pinned ends, planar x-z.
    REAL(wp), ALLOCATABLE, INTENT(OUT) :: l0(:), EAv(:), EIv(:), rhoAv(:), wv(:), seed(:)
    INTEGER, ALLOCATABLE, INTENT(OUT) :: fixed_dofs(:)
    INTEGER :: nn, i, k
    REAL(wp) :: h
    nn = NE + 1
    h = LB/REAL(NE, wp)
    ALLOCATE (l0(NE), EAv(NE), EIv(NE), rhoAv(NE), wv(NE), seed(6*nn))
    l0 = h; EAv = EA; EIv = EI; rhoAv = RHOA; wv = 0.0_wp
    seed = 0.0_wp
    DO i = 1, nn
      seed(6*(i - 1) + 1) = REAL(i - 1, wp)*h
      seed(6*(i - 1) + 3) = -10.0_wp
      seed(6*(i - 1) + 4) = 1.0_wp
    END DO
    ALLOCATE (fixed_dofs(2*nn + 4))
    k = 0
    DO i = 1, nn
      fixed_dofs(k + 1) = 6*(i - 1) + 2; fixed_dofs(k + 2) = 6*(i - 1) + 5; k = k + 2
    END DO
    fixed_dofs(k + 1) = 1; fixed_dofs(k + 2) = 3
    fixed_dofs(k + 3) = 6*(nn - 1) + 1; fixed_dofs(k + 4) = 6*(nn - 1) + 3
  END SUBROUTINE build_cable

  SUBROUTINE check_fail_closed()
    !! Set_Waves and the wave-aware drag element fail closed on malformed configurations.
    TYPE(CD_HermiteCableDynType) :: m
    REAL(wp), ALLOCATABLE :: l0(:), EAv(:), EIv(:), rhoAv(:), wv(:), seed(:)
    INTEGER, ALLOCATABLE :: fx(:)
    REAL(wp) :: dv(NE), cn(NE), ct(NE), caN_(NE), caT_(NE), cur(3)
    REAL(wp) :: qe(12), ve(12), fd(12), jq(12, 12), jv(12, 12)
    INTEGER :: es
    CHARACTER(300) :: em
    ! pre-init
    CALL CD_HermiteCable_Dyn_Set_Waves(m, WVH, WVT, 0.0_wp, WVDEP, GRAV, es, em)
    CALL require(es /= CD_HCDYN_OK, 'reject Set_Waves on an uninitialised model')
    CALL build_cable(l0, EAv, EIv, rhoAv, wv, seed, fx)
    CALL CD_HermiteCable_Dyn_Init(m, l0, EAv, EIv, rhoAv, wv, seed, fx, -WVDEP, 0.0_wp, 0.9_wp, es, em)
    CALL require(es == CD_HCDYN_OK, 'init for wave fail-closed')
    ! no hydro config yet
    CALL CD_HermiteCable_Dyn_Set_Waves(m, WVH, WVT, 0.0_wp, WVDEP, GRAV, es, em)
    CALL require(es /= CD_HCDYN_OK, 'reject waves with neither drag nor added-mass config')
    dv = DIAM; cn = CDN; ct = CDT; caN_ = CAN; caT_ = CAT; cur = 0.0_wp
    CALL CD_HermiteCable_Dyn_Set_Drag(m, RHOW, dv, cn, ct, 0.0_wp, cur, es, em)
    CALL require(es == CD_HCDYN_OK, 'drag for wave fail-closed')
    ! bad wave parameters
    CALL CD_HermiteCable_Dyn_Set_Waves(m, -1.0_wp, WVT, 0.0_wp, WVDEP, GRAV, es, em)
    CALL require(es /= CD_HCDYN_OK, 'reject nonpositive wave height')
    CALL CD_HermiteCable_Dyn_Set_Waves(m, WVH, 0.0_wp, 0.0_wp, WVDEP, GRAV, es, em)
    CALL require(es /= CD_HCDYN_OK, 'reject nonpositive wave period')
    CALL CD_HermiteCable_Dyn_Set_Waves(m, WVH, WVT, 0.0_wp, -5.0_wp, GRAV, es, em)
    CALL require(es /= CD_HCDYN_OK, 'reject nonpositive depth')
    ! mismatched waterlines between drag and added mass (waves requested after both)
    CALL CD_HermiteCable_Dyn_Set_AddedMass(m, RHOW, dv, caN_, caT_, 1.0_wp, es, em)
    CALL require(es == CD_HCDYN_OK, 'added mass at a different waterline accepted standalone')
    CALL CD_HermiteCable_Dyn_Set_Waves(m, WVH, WVT, 0.0_wp, WVDEP, GRAV, es, em)
    CALL require(es /= CD_HCDYN_OK, 'reject waves when drag and added-mass waterlines disagree')
    ! REVERSED ORDER: align the added mass, enable waves, then try to re-configure a hydro piece at a
    ! different waterline -- the later setter must reject it too (one free surface).
    CALL CD_HermiteCable_Dyn_Set_AddedMass(m, RHOW, dv, caN_, caT_, 0.0_wp, es, em)
    CALL require(es == CD_HCDYN_OK, 'aligned added mass accepted')
    CALL CD_HermiteCable_Dyn_Set_Waves(m, WVH, WVT, 0.0_wp, WVDEP, GRAV, es, em)
    CALL require(es == CD_HCDYN_OK, 'waves accepted on aligned configs')
    CALL CD_HermiteCable_Dyn_Set_AddedMass(m, RHOW, dv, caN_, caT_, 2.0_wp, es, em)
    CALL require(es /= CD_HCDYN_OK, 'reject re-configuring added mass at a new waterline while waves are on')
    CALL CD_HermiteCable_Dyn_Set_Drag(m, RHOW, dv, cn, ct, 2.0_wp, cur, es, em)
    CALL require(es /= CD_HCDYN_OK, 'reject re-configuring drag at a new waterline while waves are on')
    CALL CD_HermiteCable_Dyn_End(m)
    DEALLOCATE (l0, EAv, EIv, rhoAv, wv, seed, fx)
    ! partial wave arguments to the public drag element
    qe = [0.0_wp, 0.0_wp, -10.0_wp, 1.0_wp, 0.0_wp, 0.0_wp, 3.0_wp, 0.0_wp, -10.0_wp, 1.0_wp, 0.0_wp, 0.0_wp]
    ve = 0.0_wp
    CALL CD_HermiteCable_Drag_Element(qe, ve, 3.0_wp, [0.0_wp, 0.0_wp, 0.0_wp], 0.0_wp, RHOW, DIAM, &
                                      CDN, CDT, fd, jq, jv, es, em, wv_h=WVH, wv_om=1.0_wp)
    CALL require(es /= CD_HCDYN_OK, 'drag element rejects a partial wave-argument set')
  END SUBROUTINE check_fail_closed

  SUBROUTINE require(cond, label)
    LOGICAL, INTENT(IN) :: cond
    CHARACTER(*), INTENT(IN) :: label
    IF (.NOT. cond) THEN
      WRITE (*, '(A,A,A)') 'MISMATCH [', label, ']: condition false'
      nfail = nfail + 1
    END IF
  END SUBROUTINE require

END PROGRAM test_hermite_wave_forcing
