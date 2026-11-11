! File: tests/test_l4_lazywave_coupled.f90
! SPDX-License-Identifier: Apache-2.0
! Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
PROGRAM test_l4_lazywave_coupled
  !! L4-1c: the Lozon (2025) lazy-wave power cables under a realistic COUPLED FOWT
  !! hang-off motion, scored against OrcaFlex 11.6c at all three depths (80 m Gulf of Mexico,
  !! 200 m Gulf of Maine, 800 m Humboldt). This upgrades the L3-6 dynamic gate's single
  !! synthetic 3 m / 12 s heave to the actual multi-frequency surge+heave motion the cable
  !! hang-off experiences in a coupled floating-wind simulation.
  !!
  !! PROTOCOL. A coupled OpenFAST run (IEA-15MW VolturnUS-S UMaine, CompMooring = 5, an
  !! operational irregular sea) produces the platform 6-DOF response; the cable hang-off point
  !! (a fixed offset on the platform) moves rigidly with it, and its fluctuating translation is
  !! FFT-reduced to the dominant N harmonics committed in `lozon_coupled_harmonics.dat`
  !! (period, surge amplitude/phase, heave amplitude/phase; cos convention). BOTH codes are then
  !! driven by that IDENTICAL analytic motion -- OrcaFlex on a driver vessel
  !! (validation/scripts/orcaflex_lazywave_coupled_reference.py, HarmonicMotion surge+heave), CableDyn on the
  !! hang-off node's x and z DOFs -- so the comparison isolates the cable model under a shared,
  !! realistic excitation. The platform hydro/RAOs are HydroDyn's, identical on both sides, and
  !! never enter the comparison (which is why the depth-specific platform hydrodynamics are not
  !! needed here: only the cable and its prescribed hang-off motion are).
  !!
  !! The suspended-span model, sections, hydro, static solve and scoring are the L3-6 dynamic
  !! gate's, verbatim, at every depth (bare 0.16 m / 36.7 kg/m / EA 469 MN / EI 19.9 kN m^2;
  !! no bend stiffener; buoyant sections per Lozon; Cdn 1.2 / Cdt 0.1 / Can 1.0;
  !! touchdown pinned; interior arc 3-97%). The motion is ramped in over T_RAMP with a smooth
  !! half-cosine so the cable starts from its static equilibrium without a step; both codes apply
  !! the identical full harmonic in the scored window, which is placed well clear of the ramp and
  !! the startup transient.
  USE CableDyn_Precision, ONLY: wp
  USE CableDyn_HermiteCableStatic, ONLY: CD_HermiteCable_Static_Solve, CD_HCSTAT_OK
  USE CableDyn_HermiteCableDynamic, ONLY: CD_HermiteCableDynType, CD_HermiteCable_Dyn_Init, &
                                          CD_HermiteCable_Dyn_Set_Drag, CD_HermiteCable_Dyn_Set_AddedMass, &
                                          CD_HermiteCable_Dyn_Step, CD_HermiteCable_Dyn_Curvature_Exact, &
                                          CD_HermiteCable_Dyn_End, CD_HCDYN_OK
  IMPLICIT NONE

  REAL(wp), PARAMETER :: RHOW = 1025.0_wp, GACC = 9.80665_wp, PI = 3.141592653589793_wp
  REAL(wp), PARAMETER :: EA = 4.69e8_wp, EI_FULL = 1.99e4_wp
  REAL(wp), PARAMETER :: BAREM = 36.7_wp, BARED = 0.16_wp
  REAL(wp), PARAMETER :: ZSITE = -14.0_wp
  ! integration + scored window (must match the OrcaFlex coupled reference tool)
  REAL(wp), PARAMETER :: DT = 0.05_wp
  REAL(wp), PARAMETER :: T_RAMP = 60.0_wp, T_END = 200.0_wp, T_SCORE = 100.0_wp

  ! shared coupled-motion harmonics (read from lozon_coupled_harmonics.dat at startup). The table's
  ! mean hang-off offset (hxmean, hzmean) is the quasi-static drift; it is reported but NOT applied
  ! -- the harmonics are the FLUCTUATION about the solved static hang-off, so the cable oscillates
  ! about its own static equilibrium exactly as the L3-6 heave gate does.
  INTEGER :: nharm
  REAL(wp) :: hxmean, hzmean
  REAL(wp), ALLOCATABLE :: hper(:), hsa(:), hsp(:), hha(:), hhp(:)

  INTEGER, PARAMETER :: NSITE = 3
  CHARACTER(32) :: seeds(NSITE)
  CHARACTER(6) :: names(NSITE) = [CHARACTER(6) :: '80m', '200m', '800m']
  REAL(wp) :: ltops(NSITE) = [68.114_wp, 171.978_wp, 372.449_wp]
  REAL(wp) :: lbuoys(NSITE) = [50.0_wp, 60.0_wp, 400.0_wp]
  REAL(wp) :: bmass(NSITE) = [59.53_wp, 60.85_wp, 59.17_wp]
  REAL(wp) :: bods(NSITE) = [0.29_wp, 0.30_wp, 0.29_wp]
  INTEGER :: strides(NSITE) = [2, 1, 1]
  LOGICAL :: meshseq(NSITE) = [.FALSE., .FALSE., .TRUE.]

  ! OrcaFlex 11.6d coupled-motion references (validation/scripts/orcaflex_lazywave_coupled_reference.py, the
  ! committed harmonic table, seg 0.75 m, implicit dt 0.05 s, window [100, 200] s). Both codes are
  ! driven by the SAME table, so with the OrcaFlex phase-lag sign corrected the hang-off
  ! trajectories are bit-identical (surge/heave cross-correlation 1.0000) and the residual is the
  ! pure cable-model difference.
  REAL(wp) :: rkstat(NSITE) = [0.09643_wp, 0.08310_wp, 0.02639_wp]
  REAL(wp) :: rkdyn(NSITE) = [0.10415_wp, 0.08789_wp, 0.02834_wp]
  REAL(wp) :: rampl(NSITE) = [1.0801_wp, 1.0577_wp, 1.0740_wp]
  REAL(wp) :: rtmean(NSITE) = [9.3028_wp, 25.1341_wp, 57.7226_wp]
  REAL(wp) :: rtmin(NSITE) = [8.7172_wp, 23.6987_wp, 54.3463_wp]
  REAL(wp) :: rtmax(NSITE) = [9.7774_wp, 26.2673_wp, 60.4771_wp]
  ! per-site gates. Observed (this build): kstat 0.29/0.26/1.01%, kdyn 0.23/0.35/1.02%,
  ! ampl 0.06/0.09/0.01%, tension mean/min/max <0.7%. The 800 m curvature cells carry the ~1%
  ! mesh offset of the 3.84 m mesh vs the matched-span reference (the same offset the static and
  ! the L3-6 dynamic gate carry); the amplification (which cancels the mesh bias) matches to 0.01%.
  REAL(wp) :: g_kstat(NSITE) = [0.02_wp, 0.02_wp, 0.03_wp]
  REAL(wp) :: g_kdyn(NSITE) = [0.02_wp, 0.02_wp, 0.03_wp]
  REAL(wp) :: g_ampl(NSITE) = [0.02_wp, 0.02_wp, 0.02_wp]
  REAL(wp) :: g_tmean(NSITE) = [0.015_wp, 0.015_wp, 0.015_wp]
  REAL(wp) :: g_tmax(NSITE) = [0.015_wp, 0.015_wp, 0.015_wp]
  REAL(wp) :: g_tmin(NSITE) = [0.02_wp, 0.02_wp, 0.02_wp]

  INTEGER :: isite, nfail, nskip

  nfail = 0
  nskip = 0
  seeds(1) = 'gomex80_lazywave_seed.xyz'
  seeds(2) = 'gomaine200_lazywave_seed.xyz'
  seeds(3) = 'humboldt_lazywave_seed.xyz'

  CALL read_harmonics('lozon_coupled_harmonics.dat')
  WRITE (*, '(A,I0,A)') 'L4-1c: coupled-motion lazy-wave parity vs OrcaFlex (', nharm, ' harmonics)'
  WRITE (*, '(A,F8.4,A,F8.4,A)') '  table mean hang-off offset (', hxmean, ',', hzmean, &
    ') m [quasi-static drift, reported not applied]'

  DO isite = 1, NSITE
    CALL run_site(isite)
  END DO

  IF (nskip > 0) WRITE (*, '(A,I0,A)') 'NOTE: ', nskip, ' cell(s) intentionally not gated (see SKIP lines above)'
  IF (nfail > 0) THEN
    WRITE (*, '(A,I0,A)') 'FAIL: ', nfail, ' assertion(s) failed'
    ERROR STOP 1
  END IF
  WRITE (*, '(A)') 'PASS: L4-1c coupled-motion lazy-wave parity vs OrcaFlex at 80/200/800 m'

CONTAINS

  SUBROUTINE read_harmonics(fname)
    CHARACTER(*), INTENT(IN) :: fname
    INTEGER :: u, ios, i
    CHARACTER(300) :: line
    OPEN (NEWUNIT=u, FILE=TRIM(fname), STATUS='OLD', ACTION='READ', IOSTAT=ios)
    IF (ios /= 0) THEN
      WRITE (*, '(A)') 'FAIL: cannot open '//TRIM(fname); ERROR STOP 1
    END IF
    ! skip comment lines (#), read: nharm xmean zmean, then nharm rows
    DO
      READ (u, '(A)', IOSTAT=ios) line
      IF (ios /= 0) THEN
        WRITE (*, '(A)') 'FAIL: malformed harmonic table'; ERROR STOP 1
      END IF
      IF (LEN_TRIM(line) == 0) CYCLE
      IF (line(1:1) == '#') CYCLE
      READ (line, *) nharm, hxmean, hzmean
      EXIT
    END DO
    ALLOCATE (hper(nharm), hsa(nharm), hsp(nharm), hha(nharm), hhp(nharm))
    i = 0
    DO WHILE (i < nharm)
      READ (u, '(A)', IOSTAT=ios) line
      IF (ios /= 0) THEN
        WRITE (*, '(A)') 'FAIL: harmonic table truncated'; ERROR STOP 1
      END IF
      IF (LEN_TRIM(line) == 0) CYCLE
      IF (line(1:1) == '#') CYCLE
      i = i + 1
      READ (line, *) hper(i), hsa(i), hsp(i), hha(i), hhp(i)
    END DO
    CLOSE (u)
  END SUBROUTINE read_harmonics

  SUBROUTINE hangoff_motion(t, x0, z0, xt, zt, vxt, vzt, axt, azt)
    !! Ramped N-harmonic surge+heave hang-off motion (cos convention, matching OrcaFlex's
    !! HarmonicMotion), with a smooth half-cosine ramp over [0, T_RAMP] so the cable starts from
    !! its static equilibrium with zero initial velocity and no step. Returns position, velocity
    !! and acceleration of the hang-off x and z about the static hang-off (x0, z0).
    REAL(wp), INTENT(IN) :: t, x0, z0
    REAL(wp), INTENT(OUT) :: xt, zt, vxt, vzt, axt, azt
    REAL(wp) :: r, rp, rpp, sx, sxp, sxpp, sz, szp, szpp, om, ph, c, s, arg
    INTEGER :: k
    IF (t < T_RAMP) THEN
      arg = PI*t/T_RAMP
      r = 0.5_wp*(1.0_wp - COS(arg))
      rp = 0.5_wp*(PI/T_RAMP)*SIN(arg)
      rpp = 0.5_wp*(PI/T_RAMP)**2*COS(arg)
    ELSE
      r = 1.0_wp; rp = 0.0_wp; rpp = 0.0_wp
    END IF
    sx = 0.0_wp; sxp = 0.0_wp; sxpp = 0.0_wp
    sz = 0.0_wp; szp = 0.0_wp; szpp = 0.0_wp
    DO k = 1, nharm
      om = 2.0_wp*PI/hper(k)
      ! surge
      ph = hsp(k)*PI/180.0_wp
      c = COS(om*t + ph); s = SIN(om*t + ph)
      sx = sx + hsa(k)*c; sxp = sxp - hsa(k)*om*s; sxpp = sxpp - hsa(k)*om*om*c
      ! heave
      ph = hhp(k)*PI/180.0_wp
      c = COS(om*t + ph); s = SIN(om*t + ph)
      sz = sz + hha(k)*c; szp = szp - hha(k)*om*s; szpp = szpp - hha(k)*om*om*c
    END DO
    ! x(t) = x0 + r*sx ; product rule for v, a
    xt = x0 + r*sx
    vxt = rp*sx + r*sxp
    axt = rpp*sx + 2.0_wp*rp*sxp + r*sxpp
    zt = z0 + r*sz
    vzt = rp*sz + r*szp
    azt = rpp*sz + 2.0_wp*rp*szp + r*szpp
  END SUBROUTINE hangoff_motion

  SUBROUTINE run_site(is)
    INTEGER, INTENT(IN) :: is
    REAL(wp) :: buoy_w, bare_w, Lsus, l0e, a_mid, dum, res, kstat, kdyn_max, ampl
    REAL(wp) :: x0, z0, t, tension, tmean, tmin, tmax, arc_i, mnorm
    REAL(wp) :: xt, zt, vxt, vzt, axt, azt
    INTEGER :: nnf, nn, ne, i, e, u, ios, es, iters, nfix, isamp, s, nstep, nsc, stride
    REAL(wp), ALLOCATABLE :: posf(:, :), pos(:, :), seed(:), q_static(:), l0(:), EAv(:), EIv(:)
    REAL(wp), ALLOCATABLE :: w(:), rhoa(:), curv(:), cdyn(:), tv(:)
    REAL(wp), ALLOCATABLE :: hdiam(:), hcdn(:), hcdt(:), hcan(:), hcat(:)
    INTEGER, ALLOCATABLE :: fixed(:), pdof(:)
    REAL(wp) :: pq(2), pv(2), pa(2)
    TYPE(CD_HermiteCableDynType) :: model
    CHARACTER(300) :: em

    stride = strides(is)
    bare_w = (BAREM - RHOW*0.25_wp*PI*BARED**2)*GACC
    buoy_w = (bmass(is) - RHOW*0.25_wp*PI*bods(is)**2)*GACC

    OPEN (NEWUNIT=u, FILE=TRIM(seeds(is)), STATUS='OLD', ACTION='READ', IOSTAT=ios)
    IF (ios /= 0) THEN
      WRITE (*, '(A)') 'FAIL: cannot open '//TRIM(seeds(is)); ERROR STOP 1
    END IF
    READ (u, *) nnf, Lsus
    READ (u, *) dum, dum
    ALLOCATE (posf(3, nnf))
    DO i = 1, nnf
      READ (u, *) posf(1, i), posf(2, i), posf(3, i)
    END DO
    CLOSE (u)
    nn = (nnf - 1)/stride + 1
    IF (MOD(nnf - 1, stride) /= 0) nn = nn + 1
    ALLOCATE (pos(3, nn))
    isamp = 0
    DO i = 1, nnf, stride
      isamp = isamp + 1; pos(:, isamp) = posf(:, i)
    END DO
    IF (isamp < nn) pos(:, nn) = posf(:, nnf)
    pos(3, :) = pos(3, :) + ZSITE

    ne = nn - 1
    l0e = Lsus/REAL(ne, wp)
    ALLOCATE (seed(6*nn), q_static(6*nn), l0(ne), EAv(ne), EIv(ne), w(ne), rhoa(ne))
    ALLOCATE (curv(nn), cdyn(nn), tv(3), fixed(6 + 2*nn), pdof(2))
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
    ALLOCATE (hdiam(ne), hcdn(ne), hcdt(ne), hcan(ne), hcat(ne))
    DO e = 1, ne
      l0(e) = l0e; EAv(e) = EA
      a_mid = REAL(e, wp)*l0e - 0.5_wp*l0e
      EIv(e) = EI_FULL
      IF (a_mid > ltops(is) .AND. a_mid <= ltops(is) + lbuoys(is)) THEN
        w(e) = buoy_w; rhoa(e) = bmass(is); hdiam(e) = bods(is)
      ELSE
        w(e) = bare_w; rhoa(e) = BAREM; hdiam(e) = BARED
      END IF
    END DO
    hcdn = 1.2_wp; hcdt = 0.1_wp; hcan = 1.0_wp; hcat = 0.0_wp
    nfix = 0
    DO i = 1, 3; nfix = nfix + 1; fixed(nfix) = i; END DO
    DO i = 1, 3; nfix = nfix + 1; fixed(nfix) = 6*(nn - 1) + i; END DO
    DO i = 1, nn
      nfix = nfix + 1; fixed(nfix) = 6*(i - 1) + 2
      nfix = nfix + 1; fixed(nfix) = 6*(i - 1) + 5
    END DO

    IF (meshseq(is)) THEN
      CALL mesh_sequenced_seed(is, posf, Lsus, seed, es, em)
      CALL require(es == CD_HCSTAT_OK, TRIM(names(is))//' coarse-mesh seeding solve converged: '//TRIM(em))
      IF (es /= CD_HCSTAT_OK) RETURN
    END IF
    CALL CD_HermiteCable_Static_Solve(l0, EAv, EIv, w, seed, fixed(1:nfix), -2000.0_wp, 0.0_wp, &
                                      8, 80, 1.0e-6_wp, 0.7_wp, q_static, curv, res, iters, es, em)
    CALL require(es == CD_HCSTAT_OK, TRIM(names(is))//' static lazy-wave solve converged: '//TRIM(em))
    IF (es /= CD_HCSTAT_OK) RETURN
    kstat = 0.0_wp
    DO i = 1, nn
      arc_i = REAL(i - 1, wp)*l0e
      IF (arc_i >= 0.03_wp*Lsus .AND. arc_i <= 0.97_wp*Lsus) kstat = MAX(kstat, curv(i))
    END DO
    WRITE (*, '(A,A6,A,F8.5,A,F8.5,A,F6.2,A)') '  [', names(is), '] static peak curvature = ', kstat, &
      '   OrcaFlex ', rkstat(is), '   err ', err_pct(kstat, rkstat(is)), '%'

    ! --- dynamic: drag + added mass, N-harmonic coupled hang-off motion (surge + heave) ---
    CALL CD_HermiteCable_Dyn_Init(model, l0, EAv, EIv, rhoa, w, q_static, fixed(1:nfix), &
                                  -2000.0_wp, 0.0_wp, 0.5_wp, es, em)
    CALL require(es == CD_HCDYN_OK, TRIM(names(is))//' dynamic init: '//TRIM(em))
    IF (es /= CD_HCDYN_OK) RETURN
    CALL CD_HermiteCable_Dyn_Set_Drag(model, RHOW, hdiam, hcdn, hcdt, 0.0_wp, [0.0_wp, 0.0_wp, 0.0_wp], es, em)
    CALL require(es == CD_HCDYN_OK, TRIM(names(is))//' drag config: '//TRIM(em))
    CALL CD_HermiteCable_Dyn_Set_AddedMass(model, RHOW, hdiam, hcan, hcat, 0.0_wp, es, em)
    CALL require(es == CD_HCDYN_OK, TRIM(names(is))//' added-mass config: '//TRIM(em))

    x0 = q_static(1); z0 = q_static(3)
    pdof(1) = 1; pdof(2) = 3           ! hang-off node 1: x (surge) and z (heave)
    kdyn_max = 0.0_wp
    tmean = 0.0_wp; tmin = HUGE(1.0_wp); tmax = -HUGE(1.0_wp); nsc = 0
    nstep = NINT(T_END/DT)
    t = 0.0_wp
    DO s = 1, nstep
      t = t + DT
      CALL hangoff_motion(t, x0, z0, xt, zt, vxt, vzt, axt, azt)
      pq(1) = xt; pq(2) = zt
      pv(1) = vxt; pv(2) = vzt
      pa(1) = axt; pa(2) = azt
      CALL CD_HermiteCable_Dyn_Step(model, DT, 100, 1.0e-4_wp, es, em, &
                                    pres_dofs=pdof, pres_q=pq, pres_v=pv, pres_a=pa)
      IF (es /= CD_HCDYN_OK) THEN
        CALL require(.FALSE., TRIM(names(is))//' dynamic step stalled: '//TRIM(em)); EXIT
      END IF
      IF (t >= T_SCORE) THEN
        CALL CD_HermiteCable_Dyn_Curvature_Exact(model, cdyn, es, em)
        DO i = 1, nn
          arc_i = REAL(i - 1, wp)*l0e
          IF (arc_i >= 0.03_wp*Lsus .AND. arc_i <= 0.97_wp*Lsus) kdyn_max = MAX(kdyn_max, cdyn(i))
        END DO
        mnorm = SQRT(model%q(4)**2 + model%q(5)**2 + model%q(6)**2)
        tension = EA*(mnorm - 1.0_wp)/1000.0_wp
        tmean = tmean + tension; nsc = nsc + 1
        tmin = MIN(tmin, tension); tmax = MAX(tmax, tension)
      END IF
    END DO
    CALL require(es == CD_HCDYN_OK, TRIM(names(is))//' all dynamic steps converged')
    IF (es /= CD_HCDYN_OK) THEN
      CALL CD_HermiteCable_Dyn_End(model); RETURN
    END IF
    tmean = tmean/REAL(MAX(nsc, 1), wp)
    ampl = kdyn_max/MAX(kstat, TINY(1.0_wp))

    WRITE (*, '(A,A6,A,F8.5,A,F8.5,A,F6.2,A)') '  [', names(is), '] dynamic max curvature = ', kdyn_max, &
      '   OrcaFlex ', rkdyn(is), '   err ', err_pct(kdyn_max, rkdyn(is)), '%'
    WRITE (*, '(A,A6,A,F7.4,A,F7.4,A,F6.2,A)') '  [', names(is), '] amplification         = ', ampl, &
      '   OrcaFlex ', rampl(is), '   err ', err_pct(ampl, rampl(is)), '%'
    WRITE (*, '(A,A6,A,F9.4,A,F9.4,A,F6.2,A)') '  [', names(is), '] hang-off tension mean = ', tmean, &
      '   OrcaFlex ', rtmean(is), '   err ', err_pct(tmean, rtmean(is)), '%'
    WRITE (*, '(A,A6,A,F9.4,A,F9.4,A)') '  [', names(is), '] hang-off tension min/max = ', tmin, ' / ', tmax
    WRITE (*, '(A,F9.4,A,F9.4,A)') '           OrcaFlex                 = ', rtmin(is), ' / ', rtmax(is), ' kN'
    FLUSH (6)

    CALL require_gated(kstat, rkstat(is), g_kstat(is), TRIM(names(is))//' static peak curvature within gate')
    CALL require_gated(kdyn_max, rkdyn(is), g_kdyn(is), TRIM(names(is))//' dynamic max curvature within gate')
    CALL require_gated(ampl, rampl(is), g_ampl(is), TRIM(names(is))//' dynamic amplification within gate')
    CALL require_gated(tmean, rtmean(is), g_tmean(is), TRIM(names(is))//' hang-off mean tension within gate')
    CALL require_gated(tmax, rtmax(is), g_tmax(is), TRIM(names(is))//' hang-off max tension within gate')
    CALL require_gated(tmin, rtmin(is), g_tmin(is), TRIM(names(is))//' hang-off min tension within gate')

    CALL CD_HermiteCable_Dyn_End(model)
  END SUBROUTINE run_site

  SUBROUTINE mesh_sequenced_seed(is, posf, Ls, seed_out, es, em)
    INTEGER, INTENT(IN) :: is
    REAL(wp), INTENT(IN) :: posf(:, :)
    REAL(wp), INTENT(IN) :: Ls
    REAL(wp), INTENT(OUT) :: seed_out(:)
    INTEGER, INTENT(OUT) :: es
    CHARACTER(*), INTENT(OUT) :: em
    INTEGER :: nnf, nnc, nec, i, e, nfixc, iters_c
    REAL(wp) :: lec, a_mid, res_c, bw, bu, r1(3), r2(3), m1(3), m2(3), tv(3)
    REAL(wp), ALLOCATABLE :: seedc(:), qc(:), l0c(:), EAc(:), EIc(:), wc(:), curvc(:)
    INTEGER, ALLOCATABLE :: fixedc(:)
    nnf = SIZE(posf, 2)
    nnc = (nnf - 1)/2 + 1
    nec = nnc - 1
    lec = Ls/REAL(nec, wp)
    bw = (BAREM - RHOW*0.25_wp*PI*BARED**2)*GACC
    bu = (bmass(is) - RHOW*0.25_wp*PI*bods(is)**2)*GACC
    ALLOCATE (seedc(6*nnc), qc(6*nnc), l0c(nec), EAc(nec), EIc(nec), wc(nec), curvc(nnc))
    ALLOCATE (fixedc(6 + 2*nnc))
    seedc = 0.0_wp
    DO i = 1, nnc
      seedc(6*(i - 1) + 1:6*(i - 1) + 3) = posf(:, 2*i - 1)
      seedc(6*(i - 1) + 3) = seedc(6*(i - 1) + 3) + ZSITE
      IF (i < nnc) THEN
        tv = posf(:, 2*i + 1) - posf(:, 2*i - 1)
      ELSE
        tv = posf(:, 2*i - 1) - posf(:, 2*i - 3)
      END IF
      tv = tv/SQRT(SUM(tv**2))
      seedc(6*(i - 1) + 4:6*(i - 1) + 6) = tv
    END DO
    DO e = 1, nec
      l0c(e) = lec; EAc(e) = EA
      a_mid = REAL(e, wp)*lec - 0.5_wp*lec
      EIc(e) = EI_FULL
      IF (a_mid > ltops(is) .AND. a_mid <= ltops(is) + lbuoys(is)) THEN
        wc(e) = bu
      ELSE
        wc(e) = bw
      END IF
    END DO
    nfixc = 0
    DO i = 1, 3; nfixc = nfixc + 1; fixedc(nfixc) = i; END DO
    DO i = 1, 3; nfixc = nfixc + 1; fixedc(nfixc) = 6*(nnc - 1) + i; END DO
    DO i = 1, nnc
      nfixc = nfixc + 1; fixedc(nfixc) = 6*(i - 1) + 2
      nfixc = nfixc + 1; fixedc(nfixc) = 6*(i - 1) + 5
    END DO
    CALL CD_HermiteCable_Static_Solve(l0c, EAc, EIc, wc, seedc, fixedc(1:nfixc), -2000.0_wp, 0.0_wp, &
                                      8, 80, 1.0e-6_wp, 0.7_wp, qc, curvc, res_c, iters_c, es, em)
    IF (es /= CD_HCSTAT_OK) RETURN
    DO e = 1, nec
      r1 = qc(6*(e - 1) + 1:6*(e - 1) + 3); m1 = qc(6*(e - 1) + 4:6*(e - 1) + 6)
      r2 = qc(6*e + 1:6*e + 3); m2 = qc(6*e + 4:6*e + 6)
      seed_out(6*(2*e - 2) + 1:6*(2*e - 2) + 3) = r1
      seed_out(6*(2*e - 2) + 4:6*(2*e - 2) + 6) = m1
      seed_out(6*(2*e - 1) + 1:6*(2*e - 1) + 3) = 0.5_wp*(r1 + r2) + lec*(m1 - m2)/8.0_wp
      seed_out(6*(2*e - 1) + 4:6*(2*e - 1) + 6) = 1.5_wp*(r2 - r1)/lec - 0.25_wp*(m1 + m2)
    END DO
    seed_out(6*(2*nec) + 1:6*(2*nec) + 3) = qc(6*nec + 1:6*nec + 3)
    seed_out(6*(2*nec) + 4:6*(2*nec) + 6) = qc(6*nec + 4:6*nec + 6)
  END SUBROUTINE mesh_sequenced_seed

  REAL(wp) FUNCTION err_pct(val, ref) RESULT(p)
    !! Relative error in percent, for REPORTING. Fail-closed: a non-positive (uncommitted)
    !! reference returns a huge value, so `err_pct(...) < gate` is FALSE, never a silent pass.
    REAL(wp), INTENT(IN) :: val, ref
    IF (ref > 0.0_wp) THEN
      p = 100.0_wp*ABS(val - ref)/ref
    ELSE
      p = HUGE(1.0_wp)
    END IF
  END FUNCTION err_pct

  SUBROUTINE require(cond, label)
    LOGICAL, INTENT(IN) :: cond
    CHARACTER(*), INTENT(IN) :: label
    IF (.NOT. cond) THEN
      WRITE (*, '(A,A,A)') 'MISMATCH [', TRIM(label), ']: condition false'
      nfail = nfail + 1
    END IF
  END SUBROUTINE require

  SUBROUTINE require_gated(val, ref, gate, label)
    !! Score val against ref at fractional tolerance `gate`, FAIL-CLOSED: a non-positive gate
    !! is a COUNTED, PRINTED skip (an intentionally un-scored cell -- never a silent absence),
    !! and an active gate against a non-positive reference is a mismatch (never a silent pass).
    REAL(wp), INTENT(IN) :: val, ref, gate
    CHARACTER(*), INTENT(IN) :: label
    IF (gate <= 0.0_wp) THEN
      WRITE (*, '(A,A,A)') '  SKIP [', TRIM(label), ']: cell not gated (gate <= 0)'
      nskip = nskip + 1
    ELSE IF (ref <= 0.0_wp) THEN
      WRITE (*, '(A,A,A)') 'MISMATCH [', TRIM(label), ']: gate active but reference non-positive'
      nfail = nfail + 1
    ELSE
      CALL require(err_pct(val, ref) < 100.0_wp*gate, label)
    END IF
  END SUBROUTINE require_gated

END PROGRAM test_l4_lazywave_coupled
