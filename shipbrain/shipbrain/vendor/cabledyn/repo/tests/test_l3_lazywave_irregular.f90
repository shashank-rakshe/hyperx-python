! File: tests/test_l3_lazywave_irregular.f90
! SPDX-License-Identifier: Apache-2.0
! Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
PROGRAM test_l3_lazywave_irregular
  !! L3-6c: IRREGULAR-SEA (JONSWAP) dynamic lazy-wave parity vs OrcaFlex 11.6d -- the
  !! COMPONENT-MATCHED deterministic protocol. The sea is CableDyn's own reproducible JONSWAP
  !! realisation: CD_JONSWAP_Random_Components (the synthesis behind the deck's jonswap waves
  !! row) with Hs 2.0 m / Tp 12.0 s / gamma 3.3, WaveSeed 12345 and 80 components (random
  !! frequency within each of 80 equal bins over 0.2-5 omega_p, random phase, amplitudes
  !! scaled to Hs exactly), direction 0, taken as eta = sum a_i cos(k_i x - omega_i t + ph_i).
  !! validation/scripts/orcaflex_lazywave_irregular_reference.py reproduces the same table
  !! (components()), feeds it to OrcaFlex as user-specified components, checks that OrcaFlex realised exactly
  !! these components and reconstructs OrcaFlex's surface elevation from them (< 1e-6 m at
  !! two probe points); this gate feeds the table to CD_HermiteCable_Dyn_Set_Irregular_Waves --
  !! one wave realisation, two codes, no stochastic seed ambiguity. The table's check sums
  !! (TABLE_CSUM / TABLE_SSUM, printed by the script) tie the committed OrcaFlex summary
  !! values to this exact sea. Both codes use Wheeler stretching (OrcaFlex pinned to it;
  !! CableDyn's component kernel applies ONE Wheeler mapping of the total elevation, the
  !! same convention).
  !!
  !! Model: the matched 80 m suspended span at stride 2 (the committed heave-gate rig),
  !! hang-off FIXED at (0, 0, -14) -- no vessel: the response is PURELY wave-driven,
  !! separating the irregular-sea physics from the committed heave-driven rows. Still
  !! water statics; no seabed in reach; matched hydro (Cdn 1.2 / Cdt 0.1 / Can 1.0).
  !! The shared wave-kinematics depth is 81 m (1 m of clearance keeps the pinned
  !! touchdown node off the OrcaFlex seabed; moves 12 s kinematics ~0.05%).
  !!
  !! TIME BASE: an irregular sea is NOT window-shift-invariant (unlike the periodic
  !! heave drives), and the component phases are defined w.r.t. OrcaFlex's simulation
  !! time (t = 0 at the end of its wave-ramp build-up). CableDyn's clock IS that time:
  !! its cold start at t = 0 stands where OrcaFlex finishes ramping the same sea in, both
  !! codes get 24 s of settle, and the scored window [24, 144] s (120 s = 10 Tp) is the
  !! identical interval of the identical realisation, sampled at the same dt = 0.05 s.
  USE CableDyn_Precision, ONLY: wp
  USE CableDyn_Hydro, ONLY: CD_JONSWAP_Random_Components, CD_HYDRO_OK
  USE CableDyn_HermiteCableStatic, ONLY: CD_HermiteCable_Static_Solve, CD_HCSTAT_OK
  USE CableDyn_HermiteCableDynamic, ONLY: CD_HermiteCableDynType, CD_HermiteCable_Dyn_Init, &
                                          CD_HermiteCable_Dyn_Set_Drag, CD_HermiteCable_Dyn_Set_AddedMass, &
                                          CD_HermiteCable_Dyn_Set_Irregular_Waves, &
                                          CD_HermiteCable_Dyn_Step, CD_HermiteCable_Dyn_Curvature_Exact, &
                                          CD_HermiteCable_Dyn_End, CD_HCDYN_OK
  IMPLICIT NONE

  REAL(wp), PARAMETER :: RHOW = 1025.0_wp, GACC = 9.80665_wp, PI = 3.141592653589793_wp
  REAL(wp), PARAMETER :: EA = 4.69e8_wp, EI_FULL = 1.99e4_wp
  REAL(wp), PARAMETER :: BAREM = 36.7_wp, BARED = 0.16_wp
  REAL(wp), PARAMETER :: BMASS = 59.53_wp, BOD = 0.29_wp
  REAL(wp), PARAMETER :: LTOP = 68.114_wp, LBUOY = 50.0_wp
  REAL(wp), PARAMETER :: ZSITE = -14.0_wp
  REAL(wp), PARAMETER :: WVDEPTH = 81.0_wp, WVDIR = 0.0_wp
  REAL(wp), PARAMETER :: DT = 0.05_wp, T_END = 144.0_wp, T_SCORE = 24.0_wp
  INTEGER, PARAMETER :: STRIDE = 2
  ! the seeded sea (reproduced by the OrcaFlex reference script's components())
  REAL(wp), PARAMETER :: HS = 2.0_wp, TP = 12.0_wp, GAMMA = 3.3_wp
  INTEGER, PARAMETER :: NCOMP = 80, WAVE_SEED = 12345
  REAL(wp), PARAMETER :: TABLE_CSUM = -0.449595945684_wp, TABLE_SSUM = 0.341783951854_wp

  ! OrcaFlex 11.6d references (validation/scripts/orcaflex_lazywave_irregular_reference.py; the
  ! reference's own dt-halving moves scored channels 0.012%, OrcaFlex realises the table
  ! exactly, its elevation reconstruction closes to 3.9e-14 m, and Wheeler stretching is read
  ! back). Observed agreement: dyn curvature 0.21%, tensions <= 0.23%, the wave-driven parts
  ! (dynamic curvature above static, tension range) 1.0% and 2.1%; halving the normal drag
  ! moves the curvature rise 24% and fails the gate.
  REAL(wp), PARAMETER :: REF_KSTAT = 0.09643_wp, REF_KDYN = 0.10254_wp
  REAL(wp), PARAMETER :: REF_TMEAN = 9.3072_wp, REF_TMIN = 9.2253_wp, REF_TMAX = 9.3876_wp
  ! Article mode (second argument = a component table file, one count line then
  ! "amplitude_m period_s phase_deg" rows): the journal article drove both codes with OrcaFlex's
  ! own JONSWAP realisation (seed 12345, 60 components requested, 78 realised), which is not
  ! redistributed; licence holders regenerate it with the reference script's --orcaflex-jonswap
  ! option. Its check sums and the OrcaFlex summary values scored in the article:
  REAL(wp), PARAMETER :: ART_CSUM = 0.270469908007_wp, ART_SSUM = 0.537034708668_wp
  REAL(wp), PARAMETER :: ART_KDYN = 0.10119_wp
  REAL(wp), PARAMETER :: ART_TMEAN = 9.3074_wp, ART_TMIN = 9.2173_wp, ART_TMAX = 9.3995_wp

  INTEGER :: nnf, nn, ne, i, e, u, ios, es, iters, nfix, isamp, s, nstep, nsc, nfail
  INTEGER :: output_unit, output_ios
  INTEGER :: steps_done
  REAL(wp) :: Lsus, l0e, a_mid, dum, res, bare_w, buoy_w, t, arc_i, mnorm, tension
  REAL(wp) :: kstat, kdyn, tmean, tmin, tmax
  REAL(wp), ALLOCATABLE :: posf(:, :), pos(:, :), seed(:), q_static(:), l0(:), EAv(:), EIv(:)
  REAL(wp), ALLOCATABLE :: w(:), rhoa(:), curv(:), cdyn(:), tv(:)
  REAL(wp), ALLOCATABLE :: hdiam(:), hcdn(:), hcdt(:), hcan(:), hcat(:)
  REAL(wp), ALLOCATABLE :: wamp(:), wper(:), wph(:)
  INTEGER, ALLOCATABLE :: fixed(:)
  TYPE(CD_HermiteCableDynType) :: model
  CHARACTER(300) :: em
  CHARACTER(500) :: output_path, table_path
  REAL(wp) :: rk_stat, rk_dyn, rt_mean, rt_min, rt_max
  INTEGER :: ncomp_in

  nfail = 0
  output_unit = -1; output_path = ''
  CALL GET_COMMAND_ARGUMENT(1, output_path)
  IF (LEN_TRIM(output_path) > 0) THEN
    OPEN (NEWUNIT=output_unit, FILE=TRIM(output_path), STATUS='REPLACE', ACTION='WRITE', IOSTAT=output_ios)
    IF (output_ios /= 0) ERROR STOP 'cannot open irregular-wave comparison output'
    WRITE (output_unit, '(A)') &
      'model dynamic_curvature_per_m hop_mean_kN hop_min_kN hop_max_kN curvature_difference_pct '// &
      'hop_mean_difference_pct hop_min_difference_pct hop_max_difference_pct'
  END IF
  bare_w = (BAREM - RHOW*0.25_wp*PI*BARED**2)*GACC
  buoy_w = (BMASS - RHOW*0.25_wp*PI*BOD**2)*GACC

  table_path = ''
  CALL GET_COMMAND_ARGUMENT(2, table_path)
  rk_stat = REF_KSTAT
  IF (LEN_TRIM(table_path) == 0) THEN
    ! --- the documented JONSWAP realisation (one sea, two codes) ---
    ALLOCATE (wamp(NCOMP), wper(NCOMP), wph(NCOMP))
    CALL jonswap_components(wamp, wper, wph)
    CALL require(ABS(4.0_wp*SQRT(0.5_wp*SUM(wamp**2)) - HS) < 1.0e-12_wp, 'component sea has Hs = 2.0 m')
    CALL require(ABS(SUM(wamp*COS(wph*PI/180.0_wp)) - TABLE_CSUM) < 1.0e-9_wp .AND. &
                 ABS(SUM(wamp*SIN(wph*PI/180.0_wp)) - TABLE_SSUM) < 1.0e-9_wp, &
                 'component table matches the one the OrcaFlex reference was run with')
    rk_dyn = REF_KDYN; rt_mean = REF_TMEAN; rt_min = REF_TMIN; rt_max = REF_TMAX
  ELSE
    ! --- article mode: OrcaFlex's own realisation, read from the given table ---
    OPEN (NEWUNIT=u, FILE=TRIM(table_path), STATUS='OLD', ACTION='READ', IOSTAT=ios)
    IF (ios /= 0) THEN
      WRITE (*, '(A,A)') 'FAIL: cannot open component table ', TRIM(table_path); ERROR STOP 1
    END IF
    READ (u, *, IOSTAT=ios) ncomp_in
    IF (ios /= 0 .OR. ncomp_in < 1) THEN
      WRITE (*, '(A)') 'FAIL: bad component count'; ERROR STOP 1
    END IF
    ALLOCATE (wamp(ncomp_in), wper(ncomp_in), wph(ncomp_in))
    DO i = 1, ncomp_in
      READ (u, *, IOSTAT=ios) wamp(i), wper(i), wph(i)
      IF (ios /= 0) THEN
        WRITE (*, '(A)') 'FAIL: bad component row'; ERROR STOP 1
      END IF
    END DO
    CLOSE (u)
    CALL require(ABS(SUM(wamp*COS(wph*PI/180.0_wp)) - ART_CSUM) < 1.0e-9_wp .AND. &
                 ABS(SUM(wamp*SIN(wph*PI/180.0_wp)) - ART_SSUM) < 1.0e-9_wp, &
                 'component table is the article''s OrcaFlex realisation')
    rk_dyn = ART_KDYN; rt_mean = ART_TMEAN; rt_min = ART_TMIN; rt_max = ART_TMAX
  END IF

  ! --- committed 80 m suspended-span seed, stride-2, site frame ---
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
  nn = (nnf - 1)/STRIDE + 1
  IF (MOD(nnf - 1, STRIDE) /= 0) nn = nn + 1
  ALLOCATE (pos(3, nn))
  isamp = 0
  DO i = 1, nnf, STRIDE
    isamp = isamp + 1; pos(:, isamp) = posf(:, i)
  END DO
  IF (isamp < nn) pos(:, nn) = posf(:, nnf)
  pos(3, :) = pos(3, :) + ZSITE

  ne = nn - 1
  l0e = Lsus/REAL(ne, wp)
  ALLOCATE (seed(6*nn), q_static(6*nn), l0(ne), EAv(ne), EIv(ne), w(ne), rhoa(ne))
  ALLOCATE (curv(nn), cdyn(nn), tv(3), fixed(6 + 2*nn))
  ALLOCATE (hdiam(ne), hcdn(ne), hcdt(ne), hcan(ne), hcat(ne))
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
  DO e = 1, ne
    l0(e) = l0e; EAv(e) = EA
    a_mid = REAL(e, wp)*l0e - 0.5_wp*l0e
    EIv(e) = EI_FULL
    IF (a_mid > LTOP .AND. a_mid <= LTOP + LBUOY) THEN
      w(e) = buoy_w; rhoa(e) = BMASS; hdiam(e) = BOD
    ELSE
      w(e) = bare_w; rhoa(e) = BAREM; hdiam(e) = BARED
    END IF
  END DO
  hcdn = 1.2_wp; hcdt = 0.1_wp; hcan = 1.0_wp; hcat = 0.0_wp

  ! planar constraint set (the committed pattern; direction-0 waves are planar) with
  ! BOTH ends fully pinned -- the hang-off is fixed, nothing is prescribed in Step
  nfix = 0
  DO i = 1, 3; nfix = nfix + 1; fixed(nfix) = i; END DO
  DO i = 1, 3; nfix = nfix + 1; fixed(nfix) = 6*(nn - 1) + i; END DO
  DO i = 1, nn
    nfix = nfix + 1; fixed(nfix) = 6*(i - 1) + 2
    nfix = nfix + 1; fixed(nfix) = 6*(i - 1) + 5
  END DO

  ! --- still-water static equilibrium ---
  CALL CD_HermiteCable_Static_Solve(l0, EAv, EIv, w, seed, fixed(1:nfix), -2000.0_wp, 0.0_wp, &
                                    8, 80, 1.0e-6_wp, 0.7_wp, q_static, curv, res, iters, es, em)
  CALL require(es == CD_HCSTAT_OK, 'still-water static solve converged: '//TRIM(em))
  IF (es /= CD_HCSTAT_OK) CALL bail()
  kstat = 0.0_wp
  DO i = 1, nn
    arc_i = REAL(i - 1, wp)*l0e
    IF (arc_i >= 0.03_wp*Lsus .AND. arc_i <= 0.97_wp*Lsus) kstat = MAX(kstat, curv(i))
  END DO
  WRITE (*, '(A,F8.5,A,I0,A)') 'L3-6C static peak curvature = ', kstat, &
    '   (component table: ', SIZE(wamp), ' components)'

  ! --- dynamics: drag + added mass + the component sea; NOTHING prescribed ---
  CALL CD_HermiteCable_Dyn_Init(model, l0, EAv, EIv, rhoa, w, q_static, fixed(1:nfix), &
                                -2000.0_wp, 0.0_wp, 0.5_wp, es, em)
  CALL require(es == CD_HCDYN_OK, 'dynamic init: '//TRIM(em))
  IF (es /= CD_HCDYN_OK) CALL bail()
  CALL CD_HermiteCable_Dyn_Set_Drag(model, RHOW, hdiam, hcdn, hcdt, 0.0_wp, &
                                    [0.0_wp, 0.0_wp, 0.0_wp], es, em)
  CALL require(es == CD_HCDYN_OK, 'drag config: '//TRIM(em))
  CALL CD_HermiteCable_Dyn_Set_AddedMass(model, RHOW, hdiam, hcan, hcat, 0.0_wp, es, em)
  CALL require(es == CD_HCDYN_OK, 'added-mass config: '//TRIM(em))
  CALL CD_HermiteCable_Dyn_Set_Irregular_Waves(model, wamp, wper, wph, WVDIR, WVDEPTH, GACC, es, em)
  CALL require(es == CD_HCDYN_OK, 'component sea config: '//TRIM(em))
  IF (es /= CD_HCDYN_OK) CALL bail()

  kdyn = 0.0_wp
  tmean = 0.0_wp; tmin = HUGE(1.0_wp); tmax = -HUGE(1.0_wp); nsc = 0
  nstep = NINT(T_END/DT)
  steps_done = 0
  t = 0.0_wp
  DO s = 1, nstep
    t = t + DT
    CALL CD_HermiteCable_Dyn_Step(model, DT, 100, 1.0e-4_wp, es, em)
    IF (es /= CD_HCDYN_OK) THEN
      ! require(.FALSE.) registers the failure; the completeness assertion after the
      ! loop makes the early exit unmissable in its own right.
      CALL require(.FALSE., 'wave-driven step converged: '//TRIM(em)); EXIT
    END IF
    steps_done = steps_done + 1
    IF (t >= T_SCORE) THEN
      CALL CD_HermiteCable_Dyn_Curvature_Exact(model, cdyn, es, em)
      DO i = 1, nn
        arc_i = REAL(i - 1, wp)*l0e
        IF (arc_i >= 0.03_wp*Lsus .AND. arc_i <= 0.97_wp*Lsus) kdyn = MAX(kdyn, cdyn(i))
      END DO
      mnorm = SQRT(model%q(4)**2 + model%q(5)**2 + model%q(6)**2)
      tension = EA*(mnorm - 1.0_wp)/1000.0_wp
      tmean = tmean + tension; nsc = nsc + 1
      tmin = MIN(tmin, tension); tmax = MAX(tmax, tension)
    END IF
  END DO
  CALL CD_HermiteCable_Dyn_End(model)
  tmean = tmean/REAL(MAX(nsc, 1), wp)
  ! completeness: the scored statistics are only meaningful over the FULL window
  CALL require(steps_done == nstep, 'wave-driven solve completed the full 144 s (no early exit)')

  WRITE (*, '(A,F8.5)') 'L3-6C dynamic max curvature = ', kdyn
  WRITE (*, '(A,F9.4,A,F9.4,A,F9.4,A)') 'L3-6C hang-off tension mean/min/max = ', tmean, ' /', tmin, ' /', tmax, ' kN'
  IF (output_unit /= -1) THEN
    WRITE (output_unit, '(A,8(1X,ES16.8))') 'CableDyn', kdyn, tmean, tmin, tmax, &
      100.0_wp*ABS(kdyn - rk_dyn)/rk_dyn, &
      100.0_wp*ABS(tmean - rt_mean)/rt_mean, &
      100.0_wp*ABS(tmin - rt_min)/rt_min, &
      100.0_wp*ABS(tmax - rt_max)/rt_max
    WRITE (output_unit, '(A,8(1X,ES16.8))') 'OrcaFlex', rk_dyn, rt_mean, rt_min, rt_max, &
      0.0_wp, 0.0_wp, 0.0_wp, 0.0_wp
    CLOSE (output_unit)
  END IF

  IF (rk_dyn > 0.0_wp) THEN
    CALL require(ABS(kdyn - rk_dyn)/rk_dyn < 0.02_wp, 'dynamic max curvature within 2% of OrcaFlex')
    CALL require(ABS(tmean - rt_mean)/rt_mean < 0.01_wp, 'tension mean within 1% of OrcaFlex')
    CALL require(ABS(tmin - rt_min)/rt_min < 0.01_wp, 'tension min within 1% of OrcaFlex')
    CALL require(ABS(tmax - rt_max)/rt_max < 0.01_wp, 'tension max within 1% of OrcaFlex')
    ! what this row checks: the sea actually works the cable (a dead configuration would
    ! trivially "agree" on statics-dominated channels)
    CALL require(kdyn > 1.02_wp*kstat, 'the component sea produces a dynamic curvature response')
    ! the wave-driven parts themselves, which the absolute gates above see only as a small
    ! fraction of the static level: the curvature rise above static within 15% and the
    ! tension range within 10% of OrcaFlex's
    CALL require(ABS((kdyn - kstat) - (rk_dyn - rk_stat))/(rk_dyn - rk_stat) < 0.15_wp, &
                 'dynamic curvature rise above static within 15% of OrcaFlex')
    CALL require(ABS((tmax - tmin) - (rt_max - rt_min))/(rt_max - rt_min) < 0.10_wp, &
                 'hang-off tension range within 10% of OrcaFlex')
  ELSE
    WRITE (*, '(A)') 'FAIL: L3-6C reference scalars not committed -- gate cannot pass unscored'
    ERROR STOP 1
  END IF

  IF (nfail > 0) THEN
    WRITE (*, '(A,I0,A)') 'FAIL: ', nfail, ' assertion(s) failed'
    ERROR STOP 1
  END IF
  WRITE (*, '(A)') 'PASS: L3-6c irregular-sea dynamic lazy-wave (component-matched JONSWAP vs OrcaFlex)'

CONTAINS

  SUBROUTINE jonswap_components(amp, per, ph)
    !! CableDyn's seeded JONSWAP realisation as (amplitude m, period s, phase lag deg) for the
    !! sea eta = sum a_i cos(k_i x - omega_i t + ph_i): CD_JONSWAP_Random_Components with
    !! HS, TP, GAMMA, WAVE_SEED at the shared kinematics depth.
    REAL(wp), INTENT(OUT) :: amp(:), per(:), ph(:)
    REAL(wp) :: omega(SIZE(amp)), wavek(SIZE(amp))
    INTEGER :: jes
    CHARACTER(200) :: jem
    CALL CD_JONSWAP_Random_Components(HS, TP, GAMMA, WVDEPTH, GACC, WAVE_SEED, omega, wavek, amp, ph, jes, jem)
    IF (jes /= CD_HYDRO_OK) THEN
      WRITE (*, '(A,A)') 'FAIL: JONSWAP synthesis: ', TRIM(jem); ERROR STOP 1
    END IF
    per = 2.0_wp*PI/omega
    ph = ph*180.0_wp/PI
  END SUBROUTINE jonswap_components

  SUBROUTINE bail()
    WRITE (*, '(A)') 'FAIL: setup failed'
    ERROR STOP 1
  END SUBROUTINE bail

  SUBROUTINE require(cond, label)
    LOGICAL, INTENT(IN) :: cond
    CHARACTER(*), INTENT(IN) :: label
    IF (.NOT. cond) THEN
      WRITE (*, '(A,A)') 'MISMATCH: ', label
      nfail = nfail + 1
    END IF
  END SUBROUTINE require

END PROGRAM test_l3_lazywave_irregular
