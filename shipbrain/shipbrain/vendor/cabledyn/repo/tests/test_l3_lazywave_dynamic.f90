! File: tests/test_l3_lazywave_dynamic.f90
! SPDX-License-Identifier: Apache-2.0
! Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
PROGRAM test_l3_lazywave_dynamic
  !! L3 DYNAMIC lazy-wave parity vs OrcaFlex 11.6d at ALL THREE Lozon (2025) depths -- 80 m Gulf
  !! of Mexico, 200 m Gulf of Maine, 800 m Humboldt -- under ONE protocol (the multi-depth dynamic
  !! demonstration). Solver-to-solver parity of the SAME mathematical problem (the matched
  !! suspended span), not a re-idealisation of the installed cable:
  !!
  !!   * each cable's suspended span (arc from the committed shooter seed), site frame: hang-off
  !!     (0, 0, -14), touchdown PINNED at the static touchdown point; free surface z = 0; no
  !!     seabed contact (the touchdown is pinned);
  !!   * sections along arc per Lozon Tables 3/4/11/16/21 (bare 0.16 m / 36.7 kg/m / EA 469 MN /
  !!     EI 19.9 kN m^2; buoyant sections 0.29-0.30 m / 59.17-60.85 kg/m per site);
  !!   * hydro matched: Cdn = 1.2, Cdt = 0.1 (skin pi*d convention), Can = 1.0, Cat = 0; still
  !!     water, no waves (heave-only keeps the reference clean; see the diagnosis note below);
  !!   * drive: hang-off harmonic heave, amplitude 3 m, period 12 s -- the SAME drive at every
  !!     depth; dt = 0.05 s; scored on the steady window t in [24, 60] s (last three periods);
  !!   * the configuration blend of generalised alpha (alpha_force_blend False) with the Newton
  !!     tolerance 1e-4, the method and settings of the committed record. The environment
  !!     variable CD_L3_FORCE_BLEND=1 runs the default force blend with the same settings (ctest
  !!     l3_lazywave_dynamic_force_blend): at this loose tolerance the force blend relies on its
  !!     one-correction polish of the accepted state (without it the 80 m minimum drifted by
  !!     0.75 % between periods and the mean was 0.59 % from OrcaFlex).
  !!
  !! OrcaFlex references (OrcFxAPI 11.6d, validation/scripts/orcaflex_lazywave_dynamic_reference.py, seg
  !! 0.75 m, implicit dt 0.05 s, STILL WATER, interior arc 3-97%). No bend stiffener or
  !! other local hang-off accessory is included. Reference scalars
  !! are committed per site in the SITE TABLES below with that tool as provenance.
  !!
  !! CableDyn runs the Hermite dynamic path on the committed seed meshes: stride 2 for 80 m
  !! (1.12 m elements), stride 1 for 200/800 m (1.09 / 3.84 m -- the 200 m dynamics at stride 2
  !! creeps in the Newton line search near the buoyant-arch transition, and the deep sag bend
  !! needs the full seed resolution anyway; the 800 m static-curvature cells carry the ~1%
  !! offset of the 3.84 m mesh vs the matched-span reference -- the fine meshes flatten at
  !! ~0.0264 with ~0.15% non-monotone spread per l3_lazywave_refinement). Stride 3 falls
  !! into a kinked local equilibrium of the buoyancy
  !! continuation on the 80 m geometry and is not used. Curvature is scored over the same
  !! interior 3-97% arc window.
  !!
  !! Tension swing: CableDyn and OrcaFlex both match the closed-form axial-drag arbiter
  !! (hermite_axial_drag_arbiter: a bottom-free vertical hanging line heaved at the top,
  !! T_top = L [w + m a + 1/2 rho pi d Cd_t |v| v]) to within 0.03 % of the swing, so both apply
  !! the same skin (pi d) drag convention. The OrcaFlex references are still-water runs (a fresh
  !! OrcaFlex model carries a default wave train, which the reference tool removes); with them
  !! every 80 m cell agrees to <= 0.3 % and the tension ranges are gated tightly.
  USE CableDyn_Precision, ONLY: wp
  USE CableDyn_HermiteCableStatic, ONLY: CD_HermiteCable_Static_Solve, &
                                         CD_HermiteCable_Resolution_Metrics, &
                                         CD_HermiteCable_Refine_Mesh, CD_HermiteResolutionType, &
                                         CD_HC_HKAPPA_TARGET, CD_HCSTAT_OK
  USE CableDyn_HermiteCable, ONLY: CD_HermiteCable_Peak_Curvature, &
                                   CD_HermiteCable_Axial_Resultant_Range, CD_HCABLE_OK
  USE CableDyn_HermiteCableDynamic, ONLY: CD_HermiteCableDynType, CD_HermiteCable_Dyn_Init, &
                                          CD_HermiteCable_Dyn_Set_ForceBlend, &
                                          CD_HermiteCable_Dyn_Set_Drag, CD_HermiteCable_Dyn_Set_AddedMass, &
                                          CD_HermiteCable_Dyn_Step, CD_HermiteCable_Dyn_Step_Recovering, &
                                          CD_HermiteCable_Dyn_Get_Recovery_Diagnostics, &
                                          CD_HermiteCable_Dyn_Curvature_Exact, &
                                          CD_HermiteCable_Dyn_End, CD_HCDYN_OK
  IMPLICIT NONE

  REAL(wp), PARAMETER :: RHOW = 1025.0_wp, GACC = 9.80665_wp, PI = 3.141592653589793_wp
  REAL(wp), PARAMETER :: EA = 4.69e8_wp, EI_FULL = 1.99e4_wp
  REAL(wp), PARAMETER :: BAREM = 36.7_wp, BARED = 0.16_wp
  REAL(wp), PARAMETER :: ZSITE = -14.0_wp                     ! hang-off depth (site frame shift)
  ! drive + integration (one protocol, every depth)
  REAL(wp), PARAMETER :: AMP = 3.0_wp, PER = 12.0_wp, DT = 0.05_wp
  ! Generalised-alpha blend and Newton tolerance of the dynamic runs (see the header).
  LOGICAL :: force_blend = .FALSE.
  REAL(wp) :: step_tol = 1.0e-4_wp
  REAL(wp), PARAMETER :: T_END = 60.0_wp, T_SCORE = 24.0_wp

  ! --- SITE TABLES (mirroring the l3_lazywave_curvature constants) ---
  INTEGER, PARAMETER :: NSITE = 3
  CHARACTER(32) :: seeds(NSITE)
  CHARACTER(6) :: names(NSITE) = [CHARACTER(6) :: '80m', '200m', '800m']
  REAL(wp) :: ltops(NSITE) = [68.114_wp, 171.978_wp, 372.449_wp]  ! upper bare-cable arc extent
  REAL(wp) :: lbuoys(NSITE) = [50.0_wp, 60.0_wp, 400.0_wp]        ! buoyant section arc extent
  REAL(wp) :: bmass(NSITE) = [59.53_wp, 60.85_wp, 59.17_wp]       ! buoyant mass/length (kg/m)
  REAL(wp) :: bods(NSITE) = [0.29_wp, 0.30_wp, 0.29_wp]           ! buoyant diameter (m)
  INTEGER :: strides(NSITE) = [2, 1, 1]                           ! seed coarsening per site
  LOGICAL :: meshseq(NSITE) = [.FALSE., .FALSE., .TRUE.]          ! coarse-first static seeding (800 m)
  ! OrcaFlex 11.6d reference values (see header; committed from the provenance tool)
  REAL(wp) :: rkstat(NSITE) = [0.09643_wp, 0.08310_wp, 0.02639_wp]
  REAL(wp) :: rkdyn(NSITE) = [0.10279_wp, 0.08823_wp, 0.03881_wp]
  REAL(wp) :: rampl(NSITE) = [1.0659_wp, 1.0616_wp, 1.4707_wp]
  REAL(wp) :: rtmean(NSITE) = [9.3210_wp, 25.1560_wp, 57.7876_wp]
  REAL(wp) :: rtmin(NSITE) = [5.6342_wp, 14.8934_wp, 33.2413_wp]
  REAL(wp) :: rtmax(NSITE) = [13.0806_wp, 35.5169_wp, 82.9632_wp]
  ! MoorDyn-F v2.3.8 reference values (validation/scripts/moordyn_lazywave_dynamic_reference.py: the
  ! matched span at MoorDyn's NATIVE Lozon design meshes -- 2.6 m at 80 m, 5.7/3 m at
  ! 200 m, 18.6/13.3 m at 800 m -- coupled-point hang-off, same drive/hydro protocol,
  ! dtM 0.0005 RK4; five reference checks enforced in the script: toolchain
  ! reproduction, pinned settings, dtM-halving <= 0.0004% measured, drive read back to
  ! < 0.5 mm, and IC SETTLEMENT -- MoorDyn's "static" is dynamic relaxation terminated
  ! by a TENSION criterion, and tension settles much faster than geometry: the
  ! community-typical threshIC 1e-3 leaves the 800 m sag-bend static ~32% high and its
  ! transient bleeds into the scored window; the references relax to threshIC 1e-5 and
  ! are settlement-VERIFIED, which moved the 800 m cells materially and the tensions
  ! only in the 4th digit). The L3-6b third-code dynamic comparison.
  REAL(wp) :: mkdyn(NSITE) = [0.102269_wp, 0.086493_wp, 0.027623_wp]
  REAL(wp) :: mampl(NSITE) = [1.0646_wp, 1.0734_wp, 1.1442_wp]
  REAL(wp) :: mtmean(NSITE) = [9.3292_wp, 25.1767_wp, 57.7942_wp]
  REAL(wp) :: mtmin(NSITE) = [5.6174_wp, 14.8722_wp, 33.0371_wp]
  REAL(wp) :: mtmax(NSITE) = [13.1071_wp, 35.4912_wp, 82.9681_wp]
  ! Tension parity CableDyn-vs-MoorDyn-F is gated TIGHT at every depth (the three codes
  ! agree on the load path; tension is discretization-robust). Curvature is gated ONLY
  ! where MoorDyn's native mesh resolves the sag bend (80 m, 2%); at 200/800 m the
  ! curvature cells document the MECHANISM (tangent-difference recovery on the
  ! CFL-chained native mesh), and every number below is SAME-LOCATION and SETTLED:
  ! MoorDyn's 800 m peak (static and dynamic) sits at arc 353.8 m from the hang-off --
  ! the sag bend itself, where the implicit codes report theirs -- and its peak node
  ! PARTICIPATES in the heave cycle (the curvature swings each period); what the native
  ! mesh does not represent is the amplification half of the cycle. The observed
  ! difference in the settled native-mesh dynamic peak grows with depth as the mesh
  ! coarsens: ~0.3% at 80 m (2.6 m mesh), -2.0% at 200 m (5.7 m), -28.8% at 800 m
  ! (18.6 m); at 800 m the native-mesh amplification is 1.14 and both implicit codes
  ! give 1.47. The AMPLIFICATION RATIO is used because it largely cancels the
  ! tangent-difference readout bias common to a node's static and dynamic curvature
  ! (an absolute-curvature comparison would depend on the recovery convention);
  ! the amplification is dtM-stable to <= 0.0004% at both meshes. The mesh-ECONOMICS
  ! attribution (under-resolution, not a formulation limit) is DEMONSTRATED by the
  ! refinement control in the provenance tool's archive: refining the same 800 m
  ! problem 2x/4x moves the settled dynamic peak toward the implicit value at the
  ! measured wall-clock cost quoted in VALIDATION.md; at resolved meshes (80 m) the
  ! amplifications agree to 0.12%.
  REAL(wp) :: g_mtension(NSITE) = [0.015_wp, 0.015_wp, 0.015_wp]
  REAL(wp) :: g_mkdyn(NSITE) = [0.02_wp, -1.0_wp, -1.0_wp]      ! <0 = mechanism cell, not gated
  ! per-site gates. 80 m: the committed tight cells (observed <=0.3%). 200 m: same bands
  ! (observed <=0.29% at full seed resolution). 800 m: the curvature statics carry the
  ! documented ~1% mesh offset of the 3.84 m mesh vs the matched-span reference
  ! (l3_lazywave_refinement: fine meshes flatten at ~0.0264, ~0.15% non-monotone
  ! spread), so kstat/ampl gate at 3%; the dynamic
  ! max and tensions are observed <=0.15% and gate tight.
  REAL(wp) :: g_kstat(NSITE) = [0.02_wp, 0.02_wp, 0.03_wp]
  REAL(wp) :: g_kdyn(NSITE) = [0.015_wp, 0.02_wp, 0.015_wp]
  REAL(wp) :: g_ampl(NSITE) = [0.015_wp, 0.015_wp, 0.03_wp]
  REAL(wp) :: g_tmean(NSITE) = [0.01_wp, 0.01_wp, 0.01_wp]
  REAL(wp) :: g_tmax(NSITE) = [0.01_wp, 0.01_wp, 0.01_wp]
  REAL(wp) :: g_tmin(NSITE) = [0.015_wp, 0.015_wp, 0.015_wp]

  INTEGER :: isite, nfail, nskip, uevid, ios_evid
  CHARACTER(500) :: evidence_path

  BLOCK
    CHARACTER(8) :: flag
    INTEGER :: flag_len
    CALL GET_ENVIRONMENT_VARIABLE('CD_L3_FORCE_BLEND', flag, flag_len)
    IF (flag_len > 0) THEN
      IF (flag(1:1) == '1') THEN
        force_blend = .TRUE.
        WRITE (*, '(A)') '  generalised alpha: force blend'
      END IF
    END IF
  END BLOCK
  nfail = 0
  nskip = 0
  seeds(1) = 'gomex80_lazywave_seed.xyz'
  seeds(2) = 'gomaine200_lazywave_seed.xyz'
  seeds(3) = 'humboldt_lazywave_seed.xyz'

  uevid = -1
  evidence_path = ''
  CALL GET_COMMAND_ARGUMENT(1, evidence_path)
  IF (LEN_TRIM(evidence_path) > 0) THEN
    OPEN (NEWUNIT=uevid, FILE=TRIM(evidence_path), STATUS='REPLACE', ACTION='WRITE', IOSTAT=ios_evid)
    IF (ios_evid /= 0) THEN
      WRITE (*, '(A)') 'FAIL: cannot open evidence output '//TRIM(evidence_path)
      ERROR STOP 1
    END IF
    WRITE (uevid, '(A)') 'record,site,quantity,index,time_s,element_count,arc_m,value'
  END IF

  DO isite = 1, NSITE
    CALL run_site(isite)
  END DO

  IF (uevid /= -1) CLOSE (uevid)

  IF (nskip > 0) WRITE (*, '(A,I0,A)') 'NOTE: ', nskip, ' cell(s) intentionally not gated (see SKIP lines above)'
  IF (nfail > 0) THEN
    WRITE (*, '(A,I0,A)') 'FAIL: ', nfail, ' assertion(s) failed'
    ERROR STOP 1
  END IF
  WRITE (*, '(A)') 'PASS: L3 dynamic lazy-wave parity vs OrcaFlex at 80/200/800 m (matched spans, heave-only)'

CONTAINS

  SUBROUTINE run_site(is)
    INTEGER, INTENT(IN) :: is
    REAL(wp) :: buoy_w, bare_w, Lsus, l0e, a_mid, dum, res, kstat, kdyn_max, ampl
    REAL(wp) :: z0, t, zt, vt, at, tension, tmean, tmin, tmax, arc_i, mnorm
    REAL(wp) :: qr(12), element_peak, element_xi, peak_arc, kstat_arc, kdyn_arc, step_res, best_time
    REAL(wp) :: element_min_axial, element_min_xi, element_max_axial, element_max_xi
    REAL(wp) :: dynamic_min_axial, dynamic_min_time, dynamic_min_xi, step_peak
    REAL(wp) :: refined_peak, refined_arc, refined_static_peak, refined_static_arc
    REAL(wp) :: refined_tmean, refined_tmin, refined_tmax, refined_min_axial
    REAL(wp) :: comparison_static_peak, comparison_static_arc, comparison_dynamic_peak, comparison_dynamic_arc
    REAL(wp) :: production_hop_ratio, production_end_ratio
    INTEGER :: production_ne, production_recoveries, production_free_unknowns
    REAL(wp) :: cycle_peak(3), cycle_tsum(3), cycle_tmin(3), cycle_tmax(3), cycle_tmean(3)
    REAL(wp) :: static_history(80), step_history(100), best_history(100)
    INTEGER :: nnf, nn, ne, i, e, u, ios, es, iters, nfix, isamp, s, nstep, nsc, stride
    INTEGER :: cycle_index, cycle_count(3), dynamic_min_element
    INTEGER :: static_count, step_count, best_count, step_iters
    REAL(wp), ALLOCATABLE :: posf(:, :), pos(:, :), seed(:), q_static(:), l0(:), EAv(:), EIv(:)
    REAL(wp), ALLOCATABLE :: w(:), rhoa(:), curv(:), cdyn(:), tv(:), cprof(:)
    REAL(wp), ALLOCATABLE :: hdiam(:), hcdn(:), hcdt(:), hcan(:), hcat(:)
    INTEGER, ALLOCATABLE :: fixed(:), pdof(:)
    REAL(wp) :: pq(1), pv(1), pa(1)
    TYPE(CD_HermiteCableDynType) :: model
    TYPE(CD_HermiteResolutionType) :: resolution
    CHARACTER(300) :: em

    stride = strides(is)
    bare_w = (BAREM - RHOW*0.25_wp*PI*BARED**2)*GACC
    buoy_w = (bmass(is) - RHOW*0.25_wp*PI*bods(is)**2)*GACC

    ! --- committed suspended-span seed, coarsened, shifted to the site frame (z - 14) ---
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
    pos(3, :) = pos(3, :) + ZSITE                     ! site frame: hang-off z = -14

    ne = nn - 1
    l0e = Lsus/REAL(ne, wp)
    ALLOCATE (seed(6*nn), q_static(6*nn), l0(ne), EAv(ne), EIv(ne), w(ne), rhoa(ne))
    ALLOCATE (curv(nn), cdyn(nn), cprof(nn), tv(3), fixed(6 + 2*nn), pdof(1))
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

    ! --- static equilibrium (buoyancy continuation) + static peak curvature (interior arc) ---
    ! The deep 800 m case is MESH-SEQUENCED (the documented fine-mesh practice for net-buoyant
    ! arches): the full-resolution cold polyline seed sits on the knife edge of the kink basin,
    ! and which side it falls on can flip with round-off-level solver changes (observed when the
    ! banded Newton replaced the dense one: same physics, different pivoting order). Solving the
    ! half-resolution mesh first and refining its CONVERGED arch through the Hermite interpolant
    ! anchors the full-resolution solve on the smooth branch deterministically.
    IF (meshseq(is)) THEN
      CALL mesh_sequenced_seed(is, posf, Lsus, seed, es, em)
      CALL require(es == CD_HCSTAT_OK, TRIM(names(is))//' coarse-mesh seeding solve converged: '//TRIM(em))
      IF (es /= CD_HCSTAT_OK) RETURN
    END IF
    CALL CD_HermiteCable_Static_Solve(l0, EAv, EIv, w, seed, fixed(1:nfix), -2000.0_wp, 0.0_wp, &
                                      8, 80, 1.0e-6_wp, 0.7_wp, q_static, curv, res, iters, es, em, &
                                      residual_history=static_history, history_count=static_count)
    CALL require(es == CD_HCSTAT_OK, TRIM(names(is))//' static lazy-wave solve converged: '//TRIM(em))
    IF (es /= CD_HCSTAT_OK) RETURN
    CALL CD_HermiteCable_Resolution_Metrics(l0, q_static, -2000.0_wp, 0.0_wp, &
                                            CD_HC_HKAPPA_TARGET, resolution, es, em, EA=EAv, EI=EIv)
    CALL require(es == CD_HCSTAT_OK, TRIM(names(is))//' boundary-layer resolution evaluated: '//TRIM(em))
    IF (es /= CD_HCSTAT_OK) RETURN
    kstat = 0.0_wp; kstat_arc = 0.0_wp
    DO e = 1, ne
      qr(1:6) = q_static(6*(e - 1) + 1:6*e)
      qr(7:12) = q_static(6*e + 1:6*(e + 1))
      CALL CD_HermiteCable_Peak_Curvature(qr, l0(e), element_peak, element_xi, es, em)
      CALL require(es == CD_HCABLE_OK, TRIM(names(is))//' continuous static curvature extraction')
      IF (es /= CD_HCABLE_OK) RETURN
      peak_arc = (REAL(e - 1, wp) + element_xi)*l0e
      IF (peak_arc >= 0.03_wp*Lsus .AND. peak_arc <= 0.97_wp*Lsus) THEN
        IF (element_peak > kstat) THEN
          kstat = element_peak
          kstat_arc = peak_arc
        END IF
      END IF
    END DO
    WRITE (*, '(A,A6,A,F8.5,A,F8.5,A,F6.2,A)') '  [', names(is), '] static peak curvature = ', kstat, &
      '   OrcaFlex ', rkstat(is), '   err ', err_pct(kstat, rkstat(is)), '%'

    ! --- dynamic: drag + added mass, hang-off heave, scored window t in [24, 60] s ---
    CALL CD_HermiteCable_Dyn_Init(model, l0, EAv, EIv, rhoa, w, q_static, fixed(1:nfix), &
                                  -2000.0_wp, 0.0_wp, 0.5_wp, es, em)
    CALL require(es == CD_HCDYN_OK, TRIM(names(is))//' dynamic init: '//TRIM(em))
    IF (es /= CD_HCDYN_OK) RETURN
    CALL CD_HermiteCable_Dyn_Set_Drag(model, RHOW, hdiam, hcdn, hcdt, 0.0_wp, [0.0_wp, 0.0_wp, 0.0_wp], es, em)
    CALL require(es == CD_HCDYN_OK, TRIM(names(is))//' drag config: '//TRIM(em))
    CALL CD_HermiteCable_Dyn_Set_AddedMass(model, RHOW, hdiam, hcan, hcat, 0.0_wp, es, em)
    CALL require(es == CD_HCDYN_OK, TRIM(names(is))//' added-mass config: '//TRIM(em))
    CALL CD_HermiteCable_Dyn_Set_ForceBlend(model, force_blend, es, em)
    CALL require(es == CD_HCDYN_OK, TRIM(names(is))//' configuration blend: '//TRIM(em))

    z0 = q_static(3)
    pdof(1) = 3
    kdyn_max = 0.0_wp; cprof = 0.0_wp; kdyn_arc = 0.0_wp
    dynamic_min_axial = HUGE(1.0_wp)
    dynamic_min_time = 0.0_wp; dynamic_min_xi = 0.0_wp; dynamic_min_element = 0
    cycle_peak = 0.0_wp; cycle_tsum = 0.0_wp
    cycle_tmin = HUGE(1.0_wp); cycle_tmax = -HUGE(1.0_wp); cycle_count = 0
    best_history = 0.0_wp; best_count = 0; best_time = 0.0_wp
    tmean = 0.0_wp; tmin = HUGE(1.0_wp); tmax = -HUGE(1.0_wp); nsc = 0
    nstep = NINT(T_END/DT)
    t = 0.0_wp
    DO s = 1, nstep
      t = t + DT
      zt = z0 + AMP*SIN(2.0_wp*PI*t/PER)
      vt = AMP*(2.0_wp*PI/PER)*COS(2.0_wp*PI*t/PER)
      at = -AMP*(2.0_wp*PI/PER)**2*SIN(2.0_wp*PI*t/PER)
      pq(1) = zt; pv(1) = vt; pa(1) = at
      CALL CD_HermiteCable_Dyn_Step(model, DT, 100, step_tol, es, em, &
                                    iters_out=step_iters, res_out=step_res, &
                                    pres_dofs=pdof, pres_q=pq, pres_v=pv, pres_a=pa, &
                                    residual_history=step_history, history_count=step_count)
      IF (es /= CD_HCDYN_OK) THEN
        CALL require(.FALSE., TRIM(names(is))//' dynamic step stalled: '//TRIM(em)); EXIT
      END IF
      ! Retain the most demanding solve inside the scored stationary window. The
      ! prescribed harmonic starts from a static state at non-zero imposed velocity,
      ! so the initial kinematic start is deliberately excluded from convergence evidence.
      IF (t >= T_SCORE .AND. step_count > best_count) THEN
        best_count = step_count
        best_time = t
        best_history = step_history
      END IF
      IF (t >= T_SCORE) THEN
        cycle_index = MIN(3, MAX(1, INT((t - T_SCORE + 1.0e-9_wp)/PER) + 1))
        step_peak = 0.0_wp
        CALL CD_HermiteCable_Dyn_Curvature_Exact(model, cdyn, es, em)
        DO e = 1, ne
          qr(1:6) = model%q(6*(e - 1) + 1:6*e)
          qr(7:12) = model%q(6*e + 1:6*(e + 1))
          CALL CD_HermiteCable_Peak_Curvature(qr, l0(e), element_peak, element_xi, es, em)
          IF (es /= CD_HCABLE_OK) EXIT
          peak_arc = (REAL(e - 1, wp) + element_xi)*l0e
          IF (peak_arc >= 0.03_wp*Lsus .AND. peak_arc <= 0.97_wp*Lsus) THEN
            step_peak = MAX(step_peak, element_peak)
            IF (element_peak > kdyn_max) THEN
              kdyn_max = element_peak
              kdyn_arc = peak_arc
            END IF
          END IF
          CALL CD_HermiteCable_Axial_Resultant_Range(qr, l0(e), EAv(e), &
                                                     element_min_axial, element_min_xi, &
                                                     element_max_axial, element_max_xi, es, em)
          IF (es /= CD_HCABLE_OK) EXIT
          IF (element_min_axial < dynamic_min_axial) THEN
            dynamic_min_axial = element_min_axial
            dynamic_min_time = t
            dynamic_min_element = e
            dynamic_min_xi = element_min_xi
          END IF
        END DO
        IF (es /= CD_HCABLE_OK) THEN
          CALL require(.FALSE., TRIM(names(is))//' continuous dynamic curvature extraction: '//TRIM(em))
          EXIT
        END IF
        DO i = 1, nn
          arc_i = REAL(i - 1, wp)*l0e
          cprof(i) = MAX(cprof(i), cdyn(i))
        END DO
        ! hang-off wall tension from the node-1 material tangent: T = EA (|m| - 1)
        mnorm = SQRT(model%q(4)**2 + model%q(5)**2 + model%q(6)**2)
        tension = EA*(mnorm - 1.0_wp)/1000.0_wp        ! kN
        tmean = tmean + tension; nsc = nsc + 1
        tmin = MIN(tmin, tension); tmax = MAX(tmax, tension)
        cycle_peak(cycle_index) = MAX(cycle_peak(cycle_index), step_peak)
        cycle_tsum(cycle_index) = cycle_tsum(cycle_index) + tension
        cycle_tmin(cycle_index) = MIN(cycle_tmin(cycle_index), tension)
        cycle_tmax(cycle_index) = MAX(cycle_tmax(cycle_index), tension)
        cycle_count(cycle_index) = cycle_count(cycle_index) + 1
      END IF
    END DO
    CALL require(es == CD_HCDYN_OK, TRIM(names(is))//' all dynamic steps converged')
    IF (es /= CD_HCDYN_OK) THEN
      CALL CD_HermiteCable_Dyn_End(model)
      RETURN
    END IF
    tmean = tmean/REAL(MAX(nsc, 1), wp)
    DO i = 1, 3
      cycle_tmean(i) = cycle_tsum(i)/REAL(MAX(cycle_count(i), 1), wp)
    END DO
    ampl = kdyn_max/MAX(kstat, TINY(1.0_wp))

    ! Preserve the initial point in the refinement sequence.  Reported response
    ! quantities come from the first refined mesh that satisfies all production checks.
    comparison_static_peak = kstat; comparison_static_arc = kstat_arc
    comparison_dynamic_peak = kdyn_max; comparison_dynamic_arc = kdyn_arc
    CALL CD_HermiteCable_Dyn_End(model)
    CALL run_dynamic_refinement(is, l0, q_static, EAv, EIv, w, rhoa, hdiam, hcdn, hcdt, hcan, hcat, &
                                fixed(1:nfix), Lsus, kdyn_max, kdyn_arc, refined_peak, refined_arc, &
                                refined_static_peak, refined_static_arc, refined_tmean, refined_tmin, &
                                refined_tmax, refined_min_axial, cycle_peak, cycle_tmean, cycle_tmin, &
                                cycle_tmax, production_hop_ratio, production_end_ratio, production_ne, &
                                production_free_unknowns, production_recoveries)
    WRITE (*, '(A,A6,A,F10.4,A,I0,A,F7.4,A,F8.3,A)') '  [', names(is), &
      '] comparison-mesh minimum axial = ', dynamic_min_axial/1000.0_wp, ' kN at element ', &
      dynamic_min_element, ', xi=', dynamic_min_xi, ', t=', dynamic_min_time, ' s'
    kstat = refined_static_peak; kstat_arc = refined_static_arc
    kdyn_max = refined_peak; kdyn_arc = refined_arc
    tmean = refined_tmean; tmin = refined_tmin; tmax = refined_tmax
    resolution%hop_boundary_ratio = production_hop_ratio
    resolution%end_boundary_ratio = production_end_ratio
    ampl = kdyn_max/MAX(kstat, TINY(1.0_wp))

    WRITE (*, '(A,A6,A,F8.5,A,F8.5,A,F6.2,A)') '  [', names(is), '] dynamic max curvature = ', kdyn_max, &
      '   OrcaFlex ', rkdyn(is), '   err ', err_pct(kdyn_max, rkdyn(is)), '%'
    WRITE (*, '(A,A6,A,F9.3,A,F9.3,A)') '  [', names(is), '] peak arc static/dynamic = ', &
      kstat_arc, ' / ', kdyn_arc, ' m from HOP'
    WRITE (*, '(A,A6,A,F7.3,A,F7.3)') '  [', names(is), '] h/sqrt(EI/T), HOP/end = ', &
      resolution%hop_boundary_ratio, ' / ', resolution%end_boundary_ratio
    WRITE (*, '(A,A6,A,F7.4,A,F7.4,A,F6.2,A)') '  [', names(is), '] amplification         = ', ampl, &
      '   OrcaFlex ', rampl(is), '   err ', err_pct(ampl, rampl(is)), '%'
    WRITE (*, '(A,A6,A,F9.4,A,F9.4,A,F6.2,A)') '  [', names(is), '] hang-off tension mean = ', tmean, &
      '   OrcaFlex ', rtmean(is), '   err ', err_pct(tmean, rtmean(is)), '%'
    WRITE (*, '(A,A6,A,F9.4,A,F9.4,A)') '  [', names(is), '] hang-off tension min/max = ', tmin, ' / ', tmax
    WRITE (*, '(A,F9.4,A,F9.4,A)') '           OrcaFlex                 = ', rtmin(is), ' / ', rtmax(is), ' kN'
    WRITE (*, '(A,A6,A,3F10.6)') '  [', names(is), '] cycle peak curvature 3/4/5 = ', cycle_peak
    WRITE (*, '(A,A6,A,3F10.5,A)') '  [', names(is), '] cycle mean tension 3/4/5   = ', cycle_tmean, ' kN'
    WRITE (*, '(A,A6,A,F10.4,A)') '  [', names(is), '] production-mesh minimum axial resultant = ', &
      refined_min_axial/1000.0_wp, ' kN'
    WRITE (*, '(A,A6,A,I0,A,I0)') '  [', names(is), '] production mesh elements/recovered intervals = ', &
      production_ne, ' / ', production_recoveries
    FLUSH (6)

    IF (uevid /= -1) THEN
      WRITE (uevid, '(A,I0,A,F12.5,A,ES18.10)') &
        'mesh_refinement,'//TRIM(names(is))//',static_peak_curvature,0,0,', ne, ',', &
        comparison_static_arc, ',', comparison_static_peak
      WRITE (uevid, '(A,I0,A,F12.5,A,ES18.10)') &
        'mesh_refinement,'//TRIM(names(is))//',dynamic_peak_curvature,0,0,', ne, ',', &
        comparison_dynamic_arc, ',', comparison_dynamic_peak
      WRITE (uevid, '(A,I0,A,I0)') &
        'mesh_refinement,'//TRIM(names(is))//',free_unknown_count,0,0,', ne, ',0,', 6*nn - nfix
      WRITE (uevid, '(A,I0,A,ES18.10)') &
        'mesh_refinement,'//TRIM(names(is))//',minimum_axial_resultant_kN,0,0,', ne, ',0,', &
        dynamic_min_axial/1000.0_wp
      WRITE (uevid, '(3A,I0,A,F12.5,A,ES18.10)') 'summary,', TRIM(names(is)), &
        ',static_peak_curvature,0,0,', production_ne, ',', kstat_arc, ',', kstat
      WRITE (uevid, '(3A,I0,A,F12.5,A,ES18.10)') 'summary,', TRIM(names(is)), &
        ',dynamic_peak_curvature,0,0,', production_ne, ',', kdyn_arc, ',', kdyn_max
      WRITE (uevid, '(3A,I0,A,I0)') 'summary,', TRIM(names(is)), &
        ',free_unknown_count,0,0,', production_ne, ',0,', production_free_unknowns
      WRITE (uevid, '(3A,I0,A,ES18.10)') 'summary,', TRIM(names(is)), &
        ',hop_boundary_ratio,0,0,', production_ne, ',0,', resolution%hop_boundary_ratio
      WRITE (uevid, '(3A,I0,A,ES18.10)') 'summary,', TRIM(names(is)), &
        ',end_boundary_ratio,0,0,', production_ne, ',0,', resolution%end_boundary_ratio
      WRITE (uevid, '(3A,I0,A,ES18.10)') 'summary,', TRIM(names(is)), &
        ',rho_infinity,0,0,', production_ne, ',0,', 0.5_wp
      WRITE (uevid, '(3A,I0,A,ES18.10)') 'summary,', TRIM(names(is)), &
        ',hop_tension_mean_kN,0,0,', production_ne, ',0,', tmean
      WRITE (uevid, '(3A,I0,A,ES18.10)') 'summary,', TRIM(names(is)), &
        ',hop_tension_min_kN,0,0,', production_ne, ',0,', tmin
      WRITE (uevid, '(3A,I0,A,ES18.10)') 'summary,', TRIM(names(is)), &
        ',hop_tension_max_kN,0,0,', production_ne, ',0,', tmax
      WRITE (uevid, '(3A,I0,A,ES18.10)') 'summary,', TRIM(names(is)), &
        ',minimum_axial_resultant_kN,0,0,', production_ne, ',0,', refined_min_axial/1000.0_wp
      WRITE (uevid, '(3A,I0,A,I0)') 'summary,', TRIM(names(is)), &
        ',recovered_interval_count,0,0,', production_ne, ',0,', production_recoveries
      DO i = 1, 3
        WRITE (uevid, '(3A,I0,A,F12.5,A,I0,A,ES18.10)') 'cycle,', TRIM(names(is)), &
          ',peak_curvature,', i + 2, ',', T_SCORE + REAL(i, wp)*PER, ',', production_ne, ',0,', cycle_peak(i)
        WRITE (uevid, '(3A,I0,A,F12.5,A,I0,A,ES18.10)') 'cycle,', TRIM(names(is)), &
          ',hop_tension_mean_kN,', i + 2, ',', T_SCORE + REAL(i, wp)*PER, ',', production_ne, ',0,', cycle_tmean(i)
        WRITE (uevid, '(3A,I0,A,F12.5,A,I0,A,ES18.10)') 'cycle,', TRIM(names(is)), &
          ',hop_tension_min_kN,', i + 2, ',', T_SCORE + REAL(i, wp)*PER, ',', production_ne, ',0,', cycle_tmin(i)
        WRITE (uevid, '(3A,I0,A,F12.5,A,I0,A,ES18.10)') 'cycle,', TRIM(names(is)), &
          ',hop_tension_max_kN,', i + 2, ',', T_SCORE + REAL(i, wp)*PER, ',', production_ne, ',0,', cycle_tmax(i)
      END DO
      DO i = 1, static_count
        WRITE (uevid, '(3A,I0,A,ES18.10)') 'newton_static,', TRIM(names(is)), &
          ',scaled_residual,', i, ',0,,,', static_history(i)
      END DO
      DO i = 1, best_count
        WRITE (uevid, '(3A,I0,A,F12.5,A,ES18.10)') 'newton_dynamic,', TRIM(names(is)), &
          ',scaled_residual,', i, ',', best_time, ',,,', best_history(i)
      END DO
    END IF

    ! Gates (80 m: the committed tight cells; 200/800 m: calibrated bands, with the 800 m
    ! static-curvature cells carrying the documented ~1% gate-mesh offset vs the matched-span
    ! reference).
    CALL require_gated(kstat, rkstat(is), g_kstat(is), TRIM(names(is))//' static peak curvature within gate')
    CALL require_gated(kdyn_max, rkdyn(is), g_kdyn(is), TRIM(names(is))//' dynamic max curvature within gate')
    CALL require_gated(ampl, rampl(is), g_ampl(is), TRIM(names(is))//' dynamic amplification within gate')
    CALL require_gated(tmean, rtmean(is), g_tmean(is), TRIM(names(is))//' hang-off mean tension within gate')
    CALL require_gated(tmax, rtmax(is), g_tmax(is), TRIM(names(is))//' hang-off max tension within gate')
    CALL require_gated(tmin, rtmin(is), g_tmin(is), TRIM(names(is))//' hang-off min tension within gate')
    CALL require(err_pct(cycle_peak(3), cycle_peak(2)) < 0.5_wp, &
                 TRIM(names(is))//' final two cycle peak curvatures agree within 0.5%')
    CALL require(err_pct(cycle_tmean(3), cycle_tmean(2)) < 0.2_wp, &
                 TRIM(names(is))//' final two cycle mean tensions agree within 0.2%')
    CALL require(err_pct(cycle_tmin(3), cycle_tmin(2)) < 0.5_wp .AND. &
                 err_pct(cycle_tmax(3), cycle_tmax(2)) < 0.5_wp, &
                 TRIM(names(is))//' final two cycle tension extrema agree within 0.5%')
    CALL require(refined_min_axial >= 0.0_wp, &
                 TRIM(names(is))//' scored dynamics remain strictly tensile')

    ! --- L3-6b: the MoorDyn-F third-code comparison (same protocol, MoorDyn native mesh) ---
    WRITE (*, '(A,A6,A,F9.4,A,F9.4,A,F9.4,A)') '  [', names(is), '] MoorDyn-F tension m/mn/mx = ', &
      mtmean(is), ' /', mtmin(is), ' /', mtmax(is), ' kN'
    WRITE (*, '(A,A6,A,F6.2,A,F6.2,A,F6.2,A)') '  [', names(is), '] CableDyn-vs-MoorDyn-F     = ', &
      err_pct(tmean, mtmean(is)), '% /', err_pct(tmin, mtmin(is)), '% /', err_pct(tmax, mtmax(is)), '%'
    CALL require_gated(tmean, mtmean(is), g_mtension(is), TRIM(names(is))//' mean tension within the MoorDyn-F band')
    CALL require_gated(tmin, mtmin(is), g_mtension(is), TRIM(names(is))//' min tension within the MoorDyn-F band')
    CALL require_gated(tmax, mtmax(is), g_mtension(is), TRIM(names(is))//' max tension within the MoorDyn-F band')
    IF (g_mkdyn(is) > 0.0_wp) THEN
      WRITE (*, '(A,A6,A,F8.5,A,F6.2,A)') '  [', names(is), '] MoorDyn-F dyn curvature   = ', &
        mkdyn(is), '   CableDyn err ', err_pct(kdyn_max, mkdyn(is)), '%'
      CALL require(err_pct(kdyn_max, mkdyn(is)) < 100.0_wp*g_mkdyn(is), &
                   TRIM(names(is))//' dynamic curvature within the MoorDyn-F band (resolved mesh)')
    ELSE
      ! mechanism cells: MoorDyn's native mesh does not resolve the sag bend here -- the
      ! curvature comparison is intentionally not gated (counted below); the 800 m contrast
      ! is instead enforced by the hard mechanism gate at is == 3.
      WRITE (*, '(A,A6,A,F8.5,A,F7.4,A)') '  [', names(is), '] MoorDyn-F dyn curvature   = ', &
        mkdyn(is), '   amplification ', mampl(is), '   (native-mesh mechanism cell, not gated)'
      nskip = nskip + 1
    END IF
    IF (is == 3) THEN
      ! At 800 m the drive produces a ~1.47x dynamic curvature amplification in the
      ! OrcaFlex reference (rampl); CableDyn's own amplification must stay in that regime.
      ! (The MoorDyn-F native-mesh values mampl/mkdyn are committed reference data and are
      ! reported above, not asserted here.)
      CALL require(ampl > 1.40_wp, '800m dynamic curvature amplification above 1.40 (OrcaFlex 1.47)')
    END IF

  END SUBROUTINE run_site

  SUBROUTINE run_dynamic_refinement(is, l0_base, q_base, ea_base, ei_base, w_base, rhoa_base, &
                                    diam_base, cdn_base, cdt_base, can_base, cat_base, &
                                    fixed_base, Lsus, peak_base, arc_base, peak_final, arc_final, &
                                    static_peak_final, static_arc_final, tmean_final, tmin_final, &
                                    tmax_final, minimum_axial_final, cycle_peak_final, cycle_tmean_final, &
                                    cycle_tmin_final, cycle_tmax_final, hop_ratio_final, end_ratio_final, &
                                    production_ne, production_free_unknowns, production_recoveries)
    !! CableDyn mesh sequence for each prescribed-motion
    !! problem. Each level is a section-preserving Hermite prolongation of the
    !! converged coarser equilibrium followed by a full-load static polish. Dynamic
    !! peaks are continuous element maxima, not nodal samples.
    INTEGER, INTENT(IN) :: is
    REAL(wp), INTENT(IN) :: l0_base(:), q_base(:), ea_base(:), ei_base(:), w_base(:), rhoa_base(:)
    REAL(wp), INTENT(IN) :: diam_base(:), cdn_base(:), cdt_base(:), can_base(:), cat_base(:)
    INTEGER, INTENT(IN) :: fixed_base(:)
    REAL(wp), INTENT(IN) :: Lsus, peak_base, arc_base
    REAL(wp), INTENT(OUT) :: peak_final, arc_final, static_peak_final, static_arc_final
    REAL(wp), INTENT(OUT) :: tmean_final, tmin_final, tmax_final, minimum_axial_final
    REAL(wp), INTENT(OUT) :: cycle_peak_final(3), cycle_tmean_final(3)
    REAL(wp), INTENT(OUT) :: cycle_tmin_final(3), cycle_tmax_final(3)
    REAL(wp), INTENT(OUT) :: hop_ratio_final, end_ratio_final
    INTEGER, INTENT(OUT) :: production_ne, production_free_unknowns, production_recoveries
    REAL(wp), ALLOCATABLE :: l0c(:), qc(:), eac(:), eic(:), wc(:), rhoac(:)
    REAL(wp), ALLOCATABLE :: diamc(:), cdnc(:), cdtc(:), canc(:), catc(:)
    REAL(wp), ALLOCATABLE :: l0r(:), seedr(:), qr(:), ear(:), eir(:), wr(:), rhoar(:), curvr(:)
    REAL(wp), ALLOCATABLE :: diamr(:), cdnr(:), cdtr(:), canr(:), catr(:)
    REAL(wp), ALLOCATABLE :: dynamic_profile(:)
    INTEGER, ALLOCATABLE :: fixedc(:), fixedr(:)
    REAL(wp) :: peak_prev, arc_prev, peak_now, arc_now, static_peak, static_arc, res
    REAL(wp) :: tmean, tmin, tmax, minimum_axial, relative_peak_change, location_limit
    REAL(wp) :: cycle_peak(3), cycle_tmean(3), cycle_tmin(3), cycle_tmax(3), arc_station
    INTEGER :: level, es, iters, e, recoveries, profile_unit, node
    LOGICAL :: accepted
    TYPE(CD_HermiteResolutionType) :: refined_resolution
    CHARACTER(300) :: em

    ALLOCATE (l0c(SIZE(l0_base)), qc(SIZE(q_base)), eac(SIZE(ea_base)), eic(SIZE(ei_base)))
    ALLOCATE (wc(SIZE(w_base)), rhoac(SIZE(rhoa_base)), diamc(SIZE(diam_base)))
    ALLOCATE (cdnc(SIZE(cdn_base)), cdtc(SIZE(cdt_base)), canc(SIZE(can_base)), catc(SIZE(cat_base)))
    ALLOCATE (fixedc(SIZE(fixed_base)))
    l0c = l0_base; qc = q_base; eac = ea_base; eic = ei_base; wc = w_base; rhoac = rhoa_base
    diamc = diam_base; cdnc = cdn_base; cdtc = cdt_base; canc = can_base; catc = cat_base
    fixedc = fixed_base
    peak_prev = peak_base; arc_prev = arc_base
    peak_final = peak_base; arc_final = arc_base
    static_peak_final = 0.0_wp; static_arc_final = 0.0_wp
    tmean_final = 0.0_wp; tmin_final = 0.0_wp; tmax_final = 0.0_wp
    cycle_peak_final = 0.0_wp; cycle_tmean_final = 0.0_wp
    cycle_tmin_final = 0.0_wp; cycle_tmax_final = 0.0_wp
    minimum_axial_final = HUGE(1.0_wp)
    hop_ratio_final = HUGE(1.0_wp); end_ratio_final = HUGE(1.0_wp)
    production_ne = 0; production_free_unknowns = 0; production_recoveries = 0; accepted = .FALSE.
    minimum_axial = HUGE(1.0_wp)

    DO level = 1, 2
      CALL CD_HermiteCable_Refine_Mesh(l0c, qc, fixedc, 2, l0r, seedr, fixedr, es, em, inherit_dofs=[2, 5])
      CALL require(es == CD_HCSTAT_OK, TRIM(names(is))//' dynamic refinement prolongation: '//TRIM(em))
      IF (es /= CD_HCSTAT_OK) RETURN
      ALLOCATE (ear(SIZE(l0r)), eir(SIZE(l0r)), wr(SIZE(l0r)), rhoar(SIZE(l0r)))
      ALLOCATE (diamr(SIZE(l0r)), cdnr(SIZE(l0r)), cdtr(SIZE(l0r)), canr(SIZE(l0r)), catr(SIZE(l0r)))
      DO e = 1, SIZE(l0c)
        ear(2*e - 1:2*e) = eac(e); eir(2*e - 1:2*e) = eic(e); wr(2*e - 1:2*e) = wc(e)
        rhoar(2*e - 1:2*e) = rhoac(e); diamr(2*e - 1:2*e) = diamc(e)
        cdnr(2*e - 1:2*e) = cdnc(e); cdtr(2*e - 1:2*e) = cdtc(e)
        canr(2*e - 1:2*e) = canc(e); catr(2*e - 1:2*e) = catc(e)
      END DO
      ALLOCATE (qr(SIZE(seedr)), curvr(SIZE(l0r) + 1))
      ALLOCATE (dynamic_profile(SIZE(l0r) + 1))
      CALL CD_HermiteCable_Static_Solve(l0r, ear, eir, wr, seedr, fixedr, -2000.0_wp, 0.0_wp, &
                                        1, 160, 1.0e-6_wp, 0.7_wp, qr, curvr, res, iters, es, em, &
                                        n_buoy_steps=1)
      CALL require(es == CD_HCSTAT_OK, TRIM(names(is))//' refined static polish: '//TRIM(em))
      IF (es /= CD_HCSTAT_OK) RETURN
      CALL continuous_peak(l0r, qr, Lsus, static_peak, static_arc, es, em)
      CALL require(es == CD_HCABLE_OK, TRIM(names(is))//' refined static continuous peak: '//TRIM(em))
      IF (es /= CD_HCABLE_OK) RETURN
      CALL CD_HermiteCable_Resolution_Metrics(l0r, qr, -2000.0_wp, 0.0_wp, &
                                              CD_HC_HKAPPA_TARGET, refined_resolution, es, em, &
                                              EA=ear, EI=eir)
      CALL require(es == CD_HCSTAT_OK, TRIM(names(is))//' refined boundary-layer resolution: '//TRIM(em))
      IF (es /= CD_HCSTAT_OK) RETURN
      minimum_axial = HUGE(1.0_wp)
      CALL refined_dynamic_response(l0r, qr, ear, eir, wr, rhoar, diamr, cdnr, cdtr, canr, catr, &
                                    fixedr, Lsus, peak_now, arc_now, tmean, tmin, tmax, minimum_axial, &
                                    cycle_peak, cycle_tmean, cycle_tmin, cycle_tmax, dynamic_profile, &
                                    recoveries, es, em)
      CALL require(es == CD_HCDYN_OK, TRIM(names(is))//' refined dynamic response: '//TRIM(em))
      IF (es /= CD_HCDYN_OK) RETURN

      WRITE (*, '(3A,I0,A,F10.7,A,F9.3,A,F8.4,A,I0,A,F10.4,A)') '  [', TRIM(names(is)), &
        '] CableDyn mesh ne=', SIZE(l0r), &
        ' dynamic peak=', peak_now, ' /m at ', arc_now, ' m, move ', &
        100.0_wp*ABS(peak_now - peak_prev)/peak_now, '%, recovered intervals=', recoveries, &
        ', minimum axial=', minimum_axial/1000.0_wp, ' kN'
      IF (uevid /= -1) THEN
        WRITE (uevid, '(A,I0,A,F12.5,A,ES18.10)') &
          'mesh_refinement,'//TRIM(names(is))//',static_peak_curvature,0,0,', SIZE(l0r), ',', static_arc, ',', &
          static_peak
        WRITE (uevid, '(A,I0,A,F12.5,A,ES18.10)') &
          'mesh_refinement,'//TRIM(names(is))//',dynamic_peak_curvature,0,0,', SIZE(l0r), ',', arc_now, ',', peak_now
        WRITE (uevid, '(A,I0,A,I0)') &
          'mesh_refinement,'//TRIM(names(is))//',free_unknown_count,0,0,', SIZE(l0r), ',0,', &
          6*(SIZE(l0r) + 1) - SIZE(fixedr)
        WRITE (uevid, '(A,I0,A,ES18.10)') &
          'mesh_refinement,'//TRIM(names(is))//',hop_tension_mean_kN,0,0,', SIZE(l0r), ',0,', tmean
        WRITE (uevid, '(A,I0,A,ES18.10)') &
          'mesh_refinement,'//TRIM(names(is))//',hop_tension_min_kN,0,0,', SIZE(l0r), ',0,', tmin
        WRITE (uevid, '(A,I0,A,ES18.10)') &
          'mesh_refinement,'//TRIM(names(is))//',hop_tension_max_kN,0,0,', SIZE(l0r), ',0,', tmax
        WRITE (uevid, '(A,I0,A,I0)') &
          'mesh_refinement,'//TRIM(names(is))//',recovered_interval_count,0,0,', SIZE(l0r), ',0,', recoveries
        WRITE (uevid, '(A,I0,A,ES18.10)') &
          'mesh_refinement,'//TRIM(names(is))//',minimum_axial_resultant_kN,0,0,', SIZE(l0r), ',0,', &
          minimum_axial/1000.0_wp
      END IF

      relative_peak_change = ABS(peak_now - peak_prev)/peak_now
      location_limit = 1.01_wp*SUM(l0r)/REAL(SIZE(l0r), wp)
      peak_final = peak_now; arc_final = arc_now
      static_peak_final = static_peak; static_arc_final = static_arc
      tmean_final = tmean; tmin_final = tmin; tmax_final = tmax
      cycle_peak_final = cycle_peak; cycle_tmean_final = cycle_tmean
      cycle_tmin_final = cycle_tmin; cycle_tmax_final = cycle_tmax
      minimum_axial_final = minimum_axial
      hop_ratio_final = refined_resolution%hop_boundary_ratio
      end_ratio_final = refined_resolution%end_boundary_ratio
      production_ne = SIZE(l0r)
      production_free_unknowns = 6*(SIZE(l0r) + 1) - SIZE(fixedr)
      production_recoveries = recoveries

      ! Use the first section-preserving refinement that resolves the peak and
      ! remains tensile throughout the scored response.  This avoids presenting
      ! an over-refined mesh whose nominal step is repeatedly subdivided.
      IF (relative_peak_change < 0.002_wp .AND. &
          ABS(arc_now - arc_prev) <= location_limit .AND. &
          minimum_axial >= 0.0_wp .AND. recoveries <= NINT(0.01_wp*T_END/DT)) THEN
        accepted = .TRUE.
        ! Retain every production-mesh station.  Continuous maxima are reported
        ! separately, so the plotted nodal envelope cannot define the headline value.
        ! the force-blend ctest variant runs concurrently: it writes its own file
        BLOCK
          INTEGER :: ios_p
          OPEN (NEWUNIT=profile_unit, FILE='lfig_cabledyn_'//TRIM(names(is))// &
                TRIM(MERGE('_force_blend', '            ', force_blend))//'.csv', &
                STATUS='REPLACE', ACTION='WRITE', IOSTAT=ios_p)
          CALL require(ios_p == 0, 'write the curvature profile of '//TRIM(names(is)))
          IF (ios_p == 0) THEN
            WRITE (profile_unit, '(A)') 'arc_m,k_static,k_dynwin_max'
            arc_station = 0.0_wp
            DO node = 1, SIZE(l0r) + 1
              WRITE (profile_unit, '(ES16.8,A,ES16.8,A,ES16.8)') &
                arc_station, ',', curvr(node), ',', dynamic_profile(node)
              IF (node <= SIZE(l0r)) arc_station = arc_station + l0r(node)
            END DO
            CLOSE (profile_unit)
          END IF
        END BLOCK
        EXIT
      END IF

      peak_prev = peak_now; arc_prev = arc_now
      CALL MOVE_ALLOC(l0r, l0c); CALL MOVE_ALLOC(qr, qc); CALL MOVE_ALLOC(fixedr, fixedc)
      CALL MOVE_ALLOC(ear, eac); CALL MOVE_ALLOC(eir, eic); CALL MOVE_ALLOC(wr, wc)
      CALL MOVE_ALLOC(rhoar, rhoac); CALL MOVE_ALLOC(diamr, diamc); CALL MOVE_ALLOC(cdnr, cdnc)
      CALL MOVE_ALLOC(cdtr, cdtc); CALL MOVE_ALLOC(canr, canc); CALL MOVE_ALLOC(catr, catc)
      DEALLOCATE (seedr, curvr, dynamic_profile)
    END DO

    CALL require(accepted, TRIM(names(is))// &
                 ' production mesh is curvature-converged, tensile, and uses recovery in at most 1% of intervals')
    CALL require(ABS(peak_final - peak_base)/peak_final < 0.02_wp, &
                 TRIM(names(is))//' CableDyn dynamic peak changes by less than 2% from comparison to production mesh')
    CALL require(ABS(arc_final - arc_base) < 2.0_wp*SUM(l0_base)/REAL(SIZE(l0_base), wp), &
                 TRIM(names(is))//' CableDyn dynamic peak location remains within two comparison-mesh elements')
  END SUBROUTINE run_dynamic_refinement

  SUBROUTINE refined_dynamic_response(l0, q0, eav, eiv, w, rhoa, diam, cdn, cdt, can, cat, fixed, &
                                      Lsus, peak, peak_arc, tmean, tmin, tmax, minimum_axial, cycle_peak, &
                                      cycle_tmean, cycle_tmin, cycle_tmax, curvature_profile, recoveries, es, em)
    REAL(wp), INTENT(IN) :: l0(:), q0(:), eav(:), eiv(:), w(:), rhoa(:), diam(:), cdn(:), cdt(:), can(:), cat(:)
    INTEGER, INTENT(IN) :: fixed(:)
    REAL(wp), INTENT(IN) :: Lsus
    REAL(wp), INTENT(OUT) :: peak, peak_arc, tmean, tmin, tmax, minimum_axial
    REAL(wp), INTENT(OUT) :: cycle_peak(3), cycle_tmean(3), cycle_tmin(3), cycle_tmax(3)
    REAL(wp), INTENT(OUT) :: curvature_profile(:)
    INTEGER, INTENT(OUT) :: recoveries
    INTEGER, INTENT(OUT) :: es
    CHARACTER(*), INTENT(OUT) :: em
    TYPE(CD_HermiteCableDynType) :: dyn
    REAL(wp) :: t, z0, zt, vt, at, pq(1), pv(1), pa(1), k, arc, mnorm, tension, axial_now
    REAL(wp) :: cycle_tsum(3), nodal_curvature(SIZE(l0) + 1)
    INTEGER :: pdof(1), step, nscore, cycle_count(3), cycle_index, recovery_max_used

    CALL CD_HermiteCable_Dyn_Init(dyn, l0, eav, eiv, rhoa, w, q0, fixed, -2000.0_wp, 0.0_wp, 0.5_wp, es, em)
    IF (es /= CD_HCDYN_OK) RETURN
    CALL CD_HermiteCable_Dyn_Set_Drag(dyn, RHOW, diam, cdn, cdt, 0.0_wp, [0.0_wp, 0.0_wp, 0.0_wp], es, em)
    IF (es /= CD_HCDYN_OK) THEN; CALL CD_HermiteCable_Dyn_End(dyn); RETURN; END IF
    CALL CD_HermiteCable_Dyn_Set_AddedMass(dyn, RHOW, diam, can, cat, 0.0_wp, es, em)
    IF (es /= CD_HCDYN_OK) THEN; CALL CD_HermiteCable_Dyn_End(dyn); RETURN; END IF
    CALL CD_HermiteCable_Dyn_Set_ForceBlend(dyn, force_blend, es, em)
    IF (es /= CD_HCDYN_OK) THEN; CALL CD_HermiteCable_Dyn_End(dyn); RETURN; END IF
    z0 = q0(3); pdof = [3]
    peak = 0.0_wp; peak_arc = 0.0_wp; tmean = 0.0_wp; minimum_axial = HUGE(1.0_wp)
    tmin = HUGE(1.0_wp); tmax = -HUGE(1.0_wp); nscore = 0
    curvature_profile = 0.0_wp; cycle_peak = 0.0_wp; cycle_tsum = 0.0_wp
    cycle_tmin = HUGE(1.0_wp); cycle_tmax = -HUGE(1.0_wp); cycle_count = 0
    DO step = 1, NINT(T_END/DT)
      t = REAL(step, wp)*DT
      zt = z0 + AMP*SIN(2.0_wp*PI*t/PER)
      vt = AMP*(2.0_wp*PI/PER)*COS(2.0_wp*PI*t/PER)
      at = -AMP*(2.0_wp*PI/PER)**2*SIN(2.0_wp*PI*t/PER)
      pq = [zt]; pv = [vt]; pa = [at]
      CALL CD_HermiteCable_Dyn_Step_Recovering(dyn, DT, 200, step_tol, es, em, &
                                               pres_dofs=pdof, pres_q=pq, pres_v=pv, pres_a=pa)
      IF (es /= CD_HCDYN_OK) THEN; CALL CD_HermiteCable_Dyn_End(dyn); RETURN; END IF
      IF (t >= T_SCORE) THEN
        cycle_index = MIN(3, MAX(1, INT((t - T_SCORE + 1.0e-9_wp)/PER) + 1))
        CALL continuous_peak(l0, dyn%q, Lsus, k, arc, es, em)
        IF (es /= CD_HCABLE_OK) THEN; CALL CD_HermiteCable_Dyn_End(dyn); RETURN; END IF
        CALL continuous_axial_minimum(l0, dyn%q, eav, axial_now, es, em)
        IF (es /= CD_HCABLE_OK) THEN; CALL CD_HermiteCable_Dyn_End(dyn); RETURN; END IF
        minimum_axial = MIN(minimum_axial, axial_now)
        IF (k > peak) THEN; peak = k; peak_arc = arc; END IF
        cycle_peak(cycle_index) = MAX(cycle_peak(cycle_index), k)
        CALL CD_HermiteCable_Dyn_Curvature_Exact(dyn, nodal_curvature, es, em)
        IF (es /= CD_HCDYN_OK) THEN; CALL CD_HermiteCable_Dyn_End(dyn); RETURN; END IF
        curvature_profile = MAX(curvature_profile, nodal_curvature)
        mnorm = NORM2(dyn%q(4:6)); tension = EA*(mnorm - 1.0_wp)/1000.0_wp
        tmean = tmean + tension; tmin = MIN(tmin, tension); tmax = MAX(tmax, tension)
        cycle_tsum(cycle_index) = cycle_tsum(cycle_index) + tension
        cycle_tmin(cycle_index) = MIN(cycle_tmin(cycle_index), tension)
        cycle_tmax(cycle_index) = MAX(cycle_tmax(cycle_index), tension)
        cycle_count(cycle_index) = cycle_count(cycle_index) + 1
        nscore = nscore + 1
      END IF
    END DO
    tmean = tmean/REAL(MAX(1, nscore), wp)
    DO cycle_index = 1, 3
      cycle_tmean(cycle_index) = cycle_tsum(cycle_index)/REAL(MAX(1, cycle_count(cycle_index)), wp)
    END DO
    ! the model's own count of intervals recovered by substeps
    CALL CD_HermiteCable_Dyn_Get_Recovery_Diagnostics(dyn, recoveries, recovery_max_used, es, em)
    CALL CD_HermiteCable_Dyn_End(dyn)
  END SUBROUTINE refined_dynamic_response

  SUBROUTINE continuous_peak(l0, q, Lsus, peak, peak_arc, es, em)
    REAL(wp), INTENT(IN) :: l0(:), q(:), Lsus
    REAL(wp), INTENT(OUT) :: peak, peak_arc
    INTEGER, INTENT(OUT) :: es
    CHARACTER(*), INTENT(OUT) :: em
    REAL(wp) :: qe(12), ke, xi, arc0
    INTEGER :: e
    peak = 0.0_wp; peak_arc = 0.0_wp; arc0 = 0.0_wp; es = CD_HCABLE_OK; em = ''
    DO e = 1, SIZE(l0)
      qe(1:6) = q(6*(e - 1) + 1:6*e); qe(7:12) = q(6*e + 1:6*(e + 1))
      CALL CD_HermiteCable_Peak_Curvature(qe, l0(e), ke, xi, es, em)
      IF (es /= CD_HCABLE_OK) RETURN
      IF (arc0 + xi*l0(e) >= 0.03_wp*Lsus .AND. arc0 + xi*l0(e) <= 0.97_wp*Lsus) THEN
        IF (ke > peak) THEN; peak = ke; peak_arc = arc0 + xi*l0(e); END IF
      END IF
      arc0 = arc0 + l0(e)
    END DO
  END SUBROUTINE continuous_peak

  SUBROUTINE continuous_axial_minimum(l0, q, eav, minimum_axial, es, em)
    REAL(wp), INTENT(IN) :: l0(:), q(:), eav(:)
    REAL(wp), INTENT(OUT) :: minimum_axial
    INTEGER, INTENT(OUT) :: es
    CHARACTER(*), INTENT(OUT) :: em
    REAL(wp) :: qe(12), nmin, umin, nmax, umax
    INTEGER :: e
    minimum_axial = HUGE(1.0_wp); es = CD_HCABLE_OK; em = ''
    DO e = 1, SIZE(l0)
      qe(1:6) = q(6*(e - 1) + 1:6*e); qe(7:12) = q(6*e + 1:6*(e + 1))
      CALL CD_HermiteCable_Axial_Resultant_Range(qe, l0(e), eav(e), nmin, umin, nmax, umax, es, em)
      IF (es /= CD_HCABLE_OK) RETURN
      minimum_axial = MIN(minimum_axial, nmin)
    END DO
  END SUBROUTINE continuous_axial_minimum

  SUBROUTINE mesh_sequenced_seed(is, posf, Ls, seed_out, es, em)
    !! Solve the site's static equilibrium on the HALF-resolution mesh (stride 2 of the full
    !! polyline), then refine the converged [r, m] to the full mesh through the Hermite
    !! interpolant (r_mid = (r1+r2)/2 + le (m1 - m2)/8, m_mid = 1.5 (r2 - r1)/le - (m1 + m2)/4)
    !! -- the mesh-sequencing continuation of l3_lazywave_refinement, reused as the seed here.
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
    ! Refine the converged coarse solution onto the full mesh (element midpoints).
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
    !! Gate scoring should route through require_gated (which also counts disabled cells).
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

END PROGRAM test_l3_lazywave_dynamic
