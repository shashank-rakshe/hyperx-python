! File: tests/test_lazywave_dynamics.f90
! SPDX-License-Identifier: Apache-2.0
! Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
PROGRAM test_lazywave_dynamics
  !! Finite-EI LAZY-WAVE cable DYNAMICS on the cubic-Hermite element -- the fatigue-critical
  !! culmination of the static lazy-wave work. It drives the Lozon et al. (2025) IEA-15 MW
  !! VolturnUS-S Gulf-of-Mexico 80 m lazy-wave power cable (bare / buoyant / bare, without a
  !! local hang-off accessory) as a genuine dynamic run:
  !!
  !!   1. Solve the finite-EI static lazy-wave equilibrium (CD_HermiteCable_Static_Solve, buoyancy
  !!      load continuation) on a coarsened mesh -- the buoyant arch, suspended span, and fixed
  !!      touchdown that the EI=0 Cosserat model cannot reach.
  !!   2. Seed the Hermite gen-alpha dynamic model (CableDyn_HermiteCableDynamic) with that
  !!      equilibrium and check it is a DYNAMIC FIXED POINT: with the hang-off held, the static
  !!      shape stays at rest (consistent static->dynamic seeding of a buoyant, contacting state).
  !!   3. Drive the HANG-OFF through a prescribed vertical heave (a moving fairlead) and confirm the
  !!      cable responds STABLY and BOUNDEDLY, with the sag-bend CURVATURE oscillating about its
  !!      static value -- the dynamic curvature that feeds a fatigue assessment, and the quantity a
  !!      discrete-kink lumped-mass recovery resolves only under CFL-expensive refinement.
  !!   4. FULL HYDRO (the production fatigue configuration): re-seed and drive a HARD 3 m heave --
  !!      the drive that runs away without damping -- with Morison drag + added mass + a regular
  !!      wave all active. The hydro set keeps the response bounded and every step converging, with
  !!      the sag-bend curvature oscillating in a tight band about its static value.
  !!
  !! The mesh is coarsened from the committed 240-element static seed to keep the dense-assembly
  !! dynamic solve fast; this is a dynamics-capability gate (stable, bounded, oscillating finite
  !! curvature), not the curvature-parity gate -- that is l3_lazywave_curvature on the full mesh.
  USE CableDyn_Precision, ONLY: wp
  USE CableDyn_HermiteCableStatic, ONLY: CD_HermiteCable_Static_Solve, CD_HCSTAT_OK
  USE CableDyn_HermiteCableDynamic, ONLY: CD_HermiteCableDynType, CD_HermiteCable_Dyn_Init, &
                                          CD_HermiteCable_Dyn_Set_Drag, CD_HermiteCable_Dyn_Set_AddedMass, &
                                          CD_HermiteCable_Dyn_Set_Waves, &
                                          CD_HermiteCable_Dyn_Step, CD_HermiteCable_Dyn_Curvature_Exact, &
                                          CD_HermiteCable_Dyn_End, CD_HCDYN_OK
  IMPLICIT NONE

  REAL(wp), PARAMETER :: RHOW = 1025.0_wp, GACC = 9.80665_wp, PI = 3.141592653589793_wp
  REAL(wp), PARAMETER :: EA = 4.69e8_wp, EI_FULL = 1.99e4_wp
  REAL(wp), PARAMETER :: LTOP = 68.114_wp, LBUOY = 50.0_wp
  REAL(wp), PARAMETER :: BMASS = 59.53_wp, BOD = 0.29_wp, BAREM = 36.7_wp, BARED = 0.16_wp
  INTEGER, PARAMETER :: STRIDE = 5              ! coarsen the 241-node seed to ~49 nodes

  REAL(wp) :: buoy_w, bare_w, Lsus, l0e, a_mid, dum, res, kstat, kdyn_max, kdyn_min
  REAL(wp) :: z0, amp, per, t, zt, vt, at, maxdrift, maxpos, k_now
  INTEGER :: nnf, nn, ne, i, e, u, ios, es, iters, nfix, isamp, s, nfail, nstep
  REAL(wp), ALLOCATABLE :: posf(:, :), pos(:, :), seed(:), q(:), l0(:), EAv(:), EIv(:), w(:), rhoa(:)
  REAL(wp), ALLOCATABLE :: curv(:), tv(:), q_static(:), cdyn(:)
  REAL(wp), ALLOCATABLE :: hdiam(:), hcdn(:), hcdt(:), hcan(:), hcat(:)
  INTEGER, ALLOCATABLE :: fixed(:), pdof(:)
  REAL(wp) :: pq(1), pv(1), pa(1)
  TYPE(CD_HermiteCableDynType) :: model
  CHARACTER(300) :: em

  nfail = 0
  bare_w = (BAREM - RHOW*0.25_wp*PI*BARED**2)*GACC   ! net-heavy bare cable (N/m)
  buoy_w = (BMASS - RHOW*0.25_wp*PI*BOD**2)*GACC     ! net-buoyant module (< 0): the arch

  ! --- read + coarsen the committed suspended-span seed ---
  OPEN (NEWUNIT=u, FILE='gomex80_lazywave_seed.xyz', STATUS='OLD', ACTION='READ', IOSTAT=ios)
  IF (ios /= 0) THEN
    WRITE (*, '(A)') 'FAIL: cannot open gomex80_lazywave_seed.xyz'; ERROR STOP 1
  END IF
  READ (u, *) nnf, Lsus
  READ (u, *) dum, dum
  ALLOCATE (posf(3, nnf))
  DO i = 1, nnf
    READ (u, *) posf(1, i), posf(2, i), posf(3, i)
  END DO
  CLOSE (u)

  ! strided subsample (always keep the last node so the touchdown anchor is exact)
  nn = (nnf - 1)/STRIDE + 1
  IF (MOD(nnf - 1, STRIDE) /= 0) nn = nn + 1
  ALLOCATE (pos(3, nn))
  isamp = 0
  DO i = 1, nnf, STRIDE
    isamp = isamp + 1; pos(:, isamp) = posf(:, i)
  END DO
  IF (isamp < nn) THEN
    pos(:, nn) = posf(:, nnf)                       ! ensure the true end node is present
  END IF

  ne = nn - 1
  l0e = Lsus/REAL(ne, wp)
  ALLOCATE (seed(6*nn), q(6*nn), q_static(6*nn), l0(ne), EAv(ne), EIv(ne), w(ne), rhoa(ne))
  ALLOCATE (curv(nn), cdyn(nn), tv(3), fixed(6 + 2*nn), pdof(1))

  ! seed: positions + chord tangents
  seed = 0.0_wp
  DO i = 1, nn
    seed(6*(i - 1) + 1:6*(i - 1) + 3) = pos(:, i)
    IF (i < nn) THEN
      tv = pos(:, i + 1) - pos(:, i)
    ELSE
      tv = pos(:, i) - pos(:, i - 1)
    END IF
    tv = tv/SQRT(SUM(tv**2))
    seed(6*(i - 1) + 4:6*(i - 1) + 6) = tv
  END DO

  ! per-element properties: sections by arc from the hang-off
  DO e = 1, ne
    l0(e) = l0e; EAv(e) = EA
    a_mid = REAL(e, wp)*l0e - 0.5_wp*l0e
    EIv(e) = EI_FULL
    IF (a_mid > LTOP .AND. a_mid <= LTOP + LBUOY) THEN
      w(e) = buoy_w; rhoa(e) = BMASS
    ELSE
      w(e) = bare_w; rhoa(e) = BAREM
    END IF
  END DO

  ! fixed DOFs: hang-off r (node 1), touchdown r (node nn), planar (r_y + m_y) everywhere
  nfix = 0
  DO i = 1, 3; nfix = nfix + 1; fixed(nfix) = i; END DO
  DO i = 1, 3; nfix = nfix + 1; fixed(nfix) = 6*(nn - 1) + i; END DO
  DO i = 1, nn
    nfix = nfix + 1; fixed(nfix) = 6*(i - 1) + 2
    nfix = nfix + 1; fixed(nfix) = 6*(i - 1) + 5
  END DO

  ! --- 1. static lazy-wave equilibrium (buoyancy continuation) ---
  CALL CD_HermiteCable_Static_Solve(l0, EAv, EIv, w, seed, fixed(1:nfix), -2000.0_wp, 0.0_wp, &
                                    8, 80, 1.0e-6_wp, 0.7_wp, q_static, curv, res, iters, es, em)
  CALL require(es == CD_HCSTAT_OK, 'coarse lazy-wave static solve converged: '//TRIM(em))
  kstat = MAXVAL(curv)
  WRITE (*, '(A,I0,A,F8.3,A,ES12.5)') '  [lazy-wave dyn] ne=', ne, '  l0e=', l0e, &
    ' m   static peak curvature=', kstat

  ! --- 2. seed the dynamic model; static equilibrium must be a fixed point ---
  CALL CD_HermiteCable_Dyn_Init(model, l0, EAv, EIv, rhoa, w, q_static, fixed(1:nfix), &
                                -2000.0_wp, 0.0_wp, 0.9_wp, es, em)
  CALL require(es == CD_HCDYN_OK, 'lazy-wave dynamic init: '//TRIM(em))
  CALL require(nan_max_abs(model%a) < 1.0e-2_wp, 'consistent seed: initial acceleration ~ 0')

  maxdrift = 0.0_wp
  DO s = 1, 10
    CALL CD_HermiteCable_Dyn_Step(model, 0.1_wp, 40, 1.0e-5_wp, es, em)
    IF (es /= CD_HCDYN_OK) THEN
      CALL require(.FALSE., 'fixed-point step: '//TRIM(em)); EXIT
    END IF
    maxdrift = MAX(maxdrift, nan_max_abs(model%q - q_static))
  END DO
  WRITE (*, '(A,ES12.5,A)') '  [lazy-wave dyn] fixed-point drift over 1 s held = ', maxdrift, ' m'
  ! observed ~6e-7 m over the second; 1e-4 m leaves a factor of ~200
  CALL require(maxdrift < 1.0e-4_wp, 'static lazy-wave equilibrium is a dynamic fixed point')

  ! --- 3. prescribed hang-off heave -> bounded, oscillating dynamic sag-bend curvature ---
  ! Re-seed (the fixed-point steps left a tiny residual motion) and drive node-1 r_z sinusoidally.
  ! rho_inf = 0.5 gives the standard gen-alpha high-frequency numerical damping that keeps the
  ! coarse-mesh spurious modes quiet; the structural/hydro drag that would damp the physical
  ! response is a follow-up, so the drive is kept gentle to stay in the bounded regime.
  CALL CD_HermiteCable_Dyn_End(model)
  CALL CD_HermiteCable_Dyn_Init(model, l0, EAv, EIv, rhoa, w, q_static, fixed(1:nfix), &
                                -2000.0_wp, 0.0_wp, 0.5_wp, es, em)
  CALL require(es == CD_HCDYN_OK, 're-init for heave drive: '//TRIM(em))

  z0 = q_static(3)                 ! hang-off r_z (global DOF 3)
  amp = 1.0_wp; per = 12.0_wp      ! 1 m gentle heave, 12 s period
  pdof(1) = 3
  kdyn_max = kstat; kdyn_min = kstat; maxpos = 0.0_wp
  nstep = 280                      ! ~1.17 heave periods at dt = 0.05 s (~16x the axial CFL)
  t = 0.0_wp
  DO s = 1, nstep
    t = t + 0.05_wp
    zt = z0 + amp*SIN(2.0_wp*PI*t/per)
    vt = amp*(2.0_wp*PI/per)*COS(2.0_wp*PI*t/per)
    at = -amp*(2.0_wp*PI/per)**2*SIN(2.0_wp*PI*t/per)
    pq(1) = zt; pv(1) = vt; pa(1) = at
    CALL CD_HermiteCable_Dyn_Step(model, 0.05_wp, 50, 1.0e-4_wp, es, em, &
                                  pres_dofs=pdof, pres_q=pq, pres_v=pv, pres_a=pa)
    IF (es /= CD_HCDYN_OK) THEN
      CALL require(.FALSE., 'heave-driven step stalled: '//TRIM(em)); EXIT
    END IF
    ! the geometric curvature, the quantity of the static reference kstat
    CALL CD_HermiteCable_Dyn_Curvature_Exact(model, cdyn, es, em)
    k_now = MAXVAL(cdyn)
    kdyn_max = MAX(kdyn_max, k_now); kdyn_min = MIN(kdyn_min, k_now)
    maxpos = MAX(maxpos, nan_max_abs(model%q - q_static))   ! max excursion from the static shape
  END DO
  WRITE (*, '(A,ES12.5,A,ES12.5,A,F6.2)') '  [lazy-wave dyn] dynamic peak curvature range = [', &
    kdyn_min, ', ', kdyn_max, ']  amplification x', kdyn_max/kstat
  WRITE (*, '(A,F8.3,A)') '  [lazy-wave dyn] max excursion from static shape = ', maxpos, ' m'

  CALL require(es == CD_HCDYN_OK, 'all heave-driven steps converged (stable dynamic lazy-wave)')
  CALL require((kdyn_max - kdyn_min)/kstat > 0.01_wp, 'sag-bend curvature oscillates under heave (dynamic curvature)')
  CALL require(kdyn_max < 5.0_wp*kstat, 'dynamic curvature stays bounded (no blow-up)')
  CALL require(maxpos < 10.0_wp*amp, 'cable excursion from static stays bounded under the heave drive')
  CALL CD_HermiteCable_Dyn_End(model)

  ! --- 4. FULL HYDRO: the production fatigue configuration -- Morison drag + added mass + a regular
  !        wave + a HARD 3 m hang-off heave (the amplitude that runs away without damping). The
  !        section-dependent hydro diameters follow the bare/buoyant layout; the wave rides the
  !        80 m Gulf-of-Mexico depth. This is the load set the dynamic lazy-wave (fatigue) V&V uses.
  CALL CD_HermiteCable_Dyn_Init(model, l0, EAv, EIv, rhoa, w, q_static, fixed(1:nfix), &
                                -2000.0_wp, 0.0_wp, 0.5_wp, es, em)
  CALL require(es == CD_HCDYN_OK, 'full-hydro re-init: '//TRIM(em))
  ALLOCATE (hdiam(ne), hcdn(ne), hcdt(ne), hcan(ne), hcat(ne))
  DO e = 1, ne
    a_mid = REAL(e, wp)*l0e - 0.5_wp*l0e
    IF (a_mid > LTOP .AND. a_mid <= LTOP + LBUOY) THEN
      hdiam(e) = BOD
    ELSE
      hdiam(e) = BARED
    END IF
  END DO
  hcdn = 1.2_wp; hcdt = 0.1_wp; hcan = 1.0_wp; hcat = 0.0_wp
  CALL CD_HermiteCable_Dyn_Set_Drag(model, RHOW, hdiam, hcdn, hcdt, 0.0_wp, [0.0_wp, 0.0_wp, 0.0_wp], es, em)
  CALL require(es == CD_HCDYN_OK, 'full-hydro drag: '//TRIM(em))
  CALL CD_HermiteCable_Dyn_Set_AddedMass(model, RHOW, hdiam, hcan, hcat, 0.0_wp, es, em)
  CALL require(es == CD_HCDYN_OK, 'full-hydro added mass: '//TRIM(em))
  CALL CD_HermiteCable_Dyn_Set_Waves(model, 2.0_wp, 8.0_wp, 0.0_wp, 80.0_wp, GACC, es, em)
  CALL require(es == CD_HCDYN_OK, 'full-hydro waves: '//TRIM(em))

  amp = 3.0_wp; per = 12.0_wp
  kdyn_max = kstat; kdyn_min = kstat; maxpos = 0.0_wp
  nstep = 360                      ! 18 s = 1.5 heave periods, dt = 0.05 s
  t = 0.0_wp
  DO s = 1, nstep
    t = t + 0.05_wp
    zt = z0 + amp*SIN(2.0_wp*PI*t/per)
    vt = amp*(2.0_wp*PI/per)*COS(2.0_wp*PI*t/per)
    at = -amp*(2.0_wp*PI/per)**2*SIN(2.0_wp*PI*t/per)
    pq(1) = zt; pv(1) = vt; pa(1) = at
    CALL CD_HermiteCable_Dyn_Step(model, 0.05_wp, 50, 1.0e-4_wp, es, em, &
                                  pres_dofs=pdof, pres_q=pq, pres_v=pv, pres_a=pa)
    IF (es /= CD_HCDYN_OK) THEN
      CALL require(.FALSE., 'full-hydro step stalled: '//TRIM(em)); EXIT
    END IF
    CALL CD_HermiteCable_Dyn_Curvature_Exact(model, cdyn, es, em)
    k_now = MAXVAL(cdyn)
    kdyn_max = MAX(kdyn_max, k_now); kdyn_min = MIN(kdyn_min, k_now)
    maxpos = MAX(maxpos, nan_max_abs(model%q - q_static))
  END DO
  WRITE (*, '(A,ES12.5,A,ES12.5,A,F6.2)') '  [lazy-wave FULL-HYDRO] curvature range = [', &
    kdyn_min, ', ', kdyn_max, ']  amplification x', kdyn_max/kstat
  WRITE (*, '(A,F8.3,A)') '  [lazy-wave FULL-HYDRO] max excursion from static = ', maxpos, ' m'
  ! Envelopes sized to the demonstrated production-fatigue response (1.07x amplification, excursion
  ! ~= the heave amplitude) with real margin -- NOT loose no-blow-up bounds: a response that drifted
  ! toward the undamped ~11.6x runaway or built up displacement must FAIL this gate.
  CALL require(es == CD_HCDYN_OK, 'all full-hydro steps converged (drag + added mass + waves + 3 m heave)')
  CALL require((kdyn_max - kdyn_min)/kstat > 0.01_wp, 'full-hydro sag-bend curvature oscillates')
  CALL require(kdyn_max < 1.5_wp*kstat, 'full-hydro curvature amplification stays in the fatigue band (<1.5x)')
  CALL require(kdyn_min > 0.7_wp*kstat, 'full-hydro curvature trough stays in the fatigue band (>0.7x)')
  CALL require(maxpos < 2.0_wp*amp, 'full-hydro excursion tracks the heave (no buildup; < 2x amplitude)')
  CALL CD_HermiteCable_Dyn_End(model)

  IF (nfail > 0) THEN
    WRITE (*, '(A,I0,A)') 'FAIL: ', nfail, ' assertion(s) failed'
    ERROR STOP 1
  END IF
  WRITE (*, '(A)') 'PASS: finite-EI lazy-wave dynamics -- static-seeded fixed point + stable heave-driven curvature'

CONTAINS

  INCLUDE 'nan_max_abs.inc'

  SUBROUTINE require(cond, label)
    LOGICAL, INTENT(IN) :: cond
    CHARACTER(*), INTENT(IN) :: label
    IF (.NOT. cond) THEN
      WRITE (*, '(A,A)') 'MISMATCH: ', label
      nfail = nfail + 1
    END IF
  END SUBROUTINE require

END PROGRAM test_lazywave_dynamics
