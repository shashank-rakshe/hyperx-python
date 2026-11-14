! File: tests/test_l3_lazywave_3d_dynamic.f90
! SPDX-License-Identifier: Apache-2.0
! Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
PROGRAM test_l3_lazywave_3d_dynamic
  !! L3-6e: OUT-OF-PLANE (3D) dynamic lazy-wave parity vs OrcaFlex 11.6d. Every other
  !! committed dynamic lazy-wave gate is planar (x-z, the y DOFs pinned as protocol);
  !! this gate frees them and drives the SAME matched 80 m suspended span with an
  !! elliptical hang-off WHIRL:
  !!
  !!     z(t) = -14 + 3.0 sin(2 pi t / 12)     (the committed heave)
  !!     y(t) =   r(t) 1.5 cos(2 pi t / 12)    (half-amplitude sway, 90 deg lead)
  !!
  !! where r(t) = (1 - cos(pi t / 12))/2 for t <= 12 s, else 1: the rest-consistent
  !! half-cosine amplitude ramp (the committed snap-gate pattern). The sway component is
  !! at max DISPLACEMENT at t = 0 (cos phase), so an unramped start would demand a 1.5 m
  !! jump from the y = 0 static; OrcaFlex's build-up stage ramps its harmonics the same
  !! way, and the ramp is protocol-benign for every scored channel (all are steady-window
  !! extrema/means starting 2 ramp lengths after t = 0).
  !!
  !! exercising out-of-plane bending of the arch, transverse drag, and the span's
  !! y-restoring stiffness. The static IC is the committed PLANAR equilibrium (y = 0 is
  !! an exact equilibrium of the planar load set, so the y-freed dynamic init is
  !! consistent by symmetry); the whole out-of-plane response is dynamic. The COMMON
  !! drive phase is protocol-benign (all scored channels are extrema/means over an exact
  !! whole number of steady periods, hence phase-shift-invariant -- the committed
  !! read-back convention); the protocol-defining quantity is the 90 deg RELATIVE y-z
  !! phase, verified in the reference by harmonic-fit read-back (89.995 deg).
  !!
  !! OrcaFlex reference: validation/scripts/orcaflex_lazywave_3d_reference.py (seg 0.75 m, implicit
  !! dt 0.025 s, still water, matched hydro Cdn 1.2 / Cdz 0.1 / Can 1.0; drive read back
  !! by true-LSQ harmonic fit; reference's own dt-halving convergence quoted in-tool).
  !! Scored on the steady window t in [24, 60] s at dt = 0.025 s: dynamic max curvature
  !! (interior 3-97% arc), out-of-plane Y envelope max/min over the interior, Y envelope
  !! at two arc probes (the buoyant-arch crest and the sag bend), and hang-off tension
  !! EA(|m|-1) mean/min/max.
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
  REAL(wp), PARAMETER :: BMASS = 59.53_wp, BOD = 0.29_wp
  REAL(wp), PARAMETER :: LTOP = 68.114_wp, LBUOY = 50.0_wp
  REAL(wp), PARAMETER :: ZSITE = -14.0_wp
  REAL(wp), PARAMETER :: HAMP = 3.0_wp, SAMP = 1.5_wp, PER = 12.0_wp, DT = 0.025_wp
  ! scored on [36, 72]: the sway ramp occupies [0, 12], so full amplitude holds for 24 s
  ! before the window opens -- the same settle length as the OrcaFlex reference (whose
  ! build-up ramp ends 24 s before ITS window at [24, 60]); both windows are exactly
  ! three steady periods, so the absolute offset is protocol-benign.
  REAL(wp), PARAMETER :: T_END = 72.0_wp, T_SCORE = 36.0_wp
  ! Match the 0.75 m external discretisation.  The former stride-2 mesh left the
  ! minimum hang-off tension at the acceptance boundary even though the other
  ! response measures were converged.
  INTEGER, PARAMETER :: STRIDE = 1
  ! arc probes, measured from the hang-off: the buoyant-arch crest (mid-buoy) and the
  ! sag bend (the static-curvature peak region of the committed heave-only gate)
  REAL(wp), PARAMETER :: ARC_CREST = 93.1_wp, ARC_SAG = 50.0_wp

  ! OrcaFlex 11.6d references (validation/scripts/orcaflex_lazywave_3d_reference.py, dt 0.025 s, seg
  ! 0.75 m; the reference's own dt-halving moves scored channels <= 0.443%, worst on the
  ! smallest probe value). Y envelopes are SIGNED (the crest stays y > 0 through the
  ! whirl); envelope cells gate ABSOLUTE differences (5 cm) because the probes span two
  ! orders of magnitude (0.02 .. 1.4 m).
  REAL(wp), PARAMETER :: REF_KDYN = 0.10237_wp
  REAL(wp), PARAMETER :: REF_YHI = 1.3922_wp, REF_YLO = -1.2575_wp
  REAL(wp), PARAMETER :: REF_YCREST_HI = 0.1751_wp, REF_YCREST_LO = 0.0210_wp
  REAL(wp), PARAMETER :: REF_YSAG_HI = 0.6298_wp, REF_YSAG_LO = -0.2210_wp
  REAL(wp), PARAMETER :: REF_TMEAN = 9.3295_wp, REF_TMIN = 5.5566_wp, REF_TMAX = 13.0880_wp

  INTEGER :: nnf, nn, ne, i, e, u, ios, es, iters, nfix, isamp, s, nstep, nsc, nfail, steps_done
  INTEGER :: i_crest, i_sag
  REAL(wp) :: Lsus, l0e, a_mid, dum, res, bare_w, buoy_w, t, zt, yt, arc_i, mnorm, tension
  REAL(wp) :: kdyn, y_hi, y_lo, yc_hi, yc_lo, ys_hi, ys_lo, tmean, tmin, tmax, kstat
  REAL(wp), ALLOCATABLE :: posf(:, :), pos(:, :), seed(:), q_static(:), l0(:), EAv(:), EIv(:)
  REAL(wp), ALLOCATABLE :: w(:), rhoa(:), curv(:), cdyn(:), tv(:)
  REAL(wp), ALLOCATABLE :: hdiam(:), hcdn(:), hcdt(:), hcan(:), hcat(:)
  INTEGER, ALLOCATABLE :: fixed(:), fixed3d(:)
  INTEGER :: pdof(2)
  REAL(wp) :: pq(2), pv(2), pa(2), om
  TYPE(CD_HermiteCableDynType) :: model
  CHARACTER(300) :: em

  nfail = 0
  om = 2.0_wp*PI/PER
  bare_w = (BAREM - RHOW*0.25_wp*PI*BARED**2)*GACC
  buoy_w = (BMASS - RHOW*0.25_wp*PI*BOD**2)*GACC

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
  ALLOCATE (curv(nn), cdyn(nn), tv(3), fixed(6 + 2*nn), fixed3d(6))
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

  ! planar static constraint set (the committed heave-only pattern)
  nfix = 0
  DO i = 1, 3; nfix = nfix + 1; fixed(nfix) = i; END DO
  DO i = 1, 3; nfix = nfix + 1; fixed(nfix) = 6*(nn - 1) + i; END DO
  DO i = 1, nn
    nfix = nfix + 1; fixed(nfix) = 6*(i - 1) + 2
    nfix = nfix + 1; fixed(nfix) = 6*(i - 1) + 5
  END DO

  ! --- planar static equilibrium (y = 0 exactly; consistent 3D IC by symmetry) ---
  CALL CD_HermiteCable_Static_Solve(l0, EAv, EIv, w, seed, fixed(1:nfix), -2000.0_wp, 0.0_wp, &
                                    8, 80, 1.0e-6_wp, 0.7_wp, q_static, curv, res, iters, es, em)
  CALL require(es == CD_HCSTAT_OK, 'planar static lazy-wave solve converged: '//TRIM(em))
  IF (es /= CD_HCSTAT_OK) CALL bail()
  kstat = 0.0_wp
  DO i = 1, nn
    arc_i = REAL(i - 1, wp)*l0e
    IF (arc_i >= 0.03_wp*Lsus .AND. arc_i <= 0.97_wp*Lsus) kstat = MAX(kstat, curv(i))
  END DO
  WRITE (*, '(A,F8.5)') 'L3-6E planar static peak curvature = ', kstat

  ! --- 3D dynamics: only the END TRANSLATIONS constrained; node-1 y,z prescribed ---
  fixed3d(1:3) = [1, 2, 3]
  fixed3d(4:6) = [6*(nn - 1) + 1, 6*(nn - 1) + 2, 6*(nn - 1) + 3]
  CALL CD_HermiteCable_Dyn_Init(model, l0, EAv, EIv, rhoa, w, q_static, fixed3d, &
                                -2000.0_wp, 0.0_wp, 0.5_wp, es, em)
  CALL require(es == CD_HCDYN_OK, '3D dynamic init: '//TRIM(em))
  IF (es /= CD_HCDYN_OK) CALL bail()
  CALL CD_HermiteCable_Dyn_Set_Drag(model, RHOW, hdiam, hcdn, hcdt, 0.0_wp, &
                                    [0.0_wp, 0.0_wp, 0.0_wp], es, em)
  CALL require(es == CD_HCDYN_OK, 'drag config: '//TRIM(em))
  CALL CD_HermiteCable_Dyn_Set_AddedMass(model, RHOW, hdiam, hcan, hcat, 0.0_wp, es, em)
  CALL require(es == CD_HCDYN_OK, 'added-mass config: '//TRIM(em))

  i_crest = probe_node(ARC_CREST)
  i_sag = probe_node(ARC_SAG)
  pdof = [2, 3]
  kdyn = 0.0_wp
  y_hi = -HUGE(1.0_wp); y_lo = HUGE(1.0_wp)
  yc_hi = -HUGE(1.0_wp); yc_lo = HUGE(1.0_wp)
  ys_hi = -HUGE(1.0_wp); ys_lo = HUGE(1.0_wp)
  tmean = 0.0_wp; tmin = HUGE(1.0_wp); tmax = -HUGE(1.0_wp); nsc = 0
  nstep = NINT(T_END/DT)
  steps_done = 0
  t = 0.0_wp
  DO s = 1, nstep
    t = t + DT
    zt = q_static(3) + HAMP*SIN(om*t)
    BLOCK
      REAL(wp) :: r, rd, rdd, cw, sw
      IF (t <= PER) THEN
        r = 0.5_wp*(1.0_wp - COS(PI*t/PER))
        rd = 0.5_wp*(PI/PER)*SIN(PI*t/PER)
        rdd = 0.5_wp*(PI/PER)**2*COS(PI*t/PER)
      ELSE
        r = 1.0_wp; rd = 0.0_wp; rdd = 0.0_wp
      END IF
      cw = COS(om*t); sw = SIN(om*t)
      yt = SAMP*r*cw
      pq = [yt, zt]
      pv = [SAMP*(rd*cw - r*om*sw), HAMP*om*cw]
      pa = [SAMP*(rdd*cw - 2.0_wp*rd*om*sw - r*om*om*cw), -HAMP*om*om*sw]
    END BLOCK
    CALL CD_HermiteCable_Dyn_Step(model, DT, 100, 1.0e-4_wp, es, em, &
                                  pres_dofs=pdof, pres_q=pq, pres_v=pv, pres_a=pa)
    IF (es /= CD_HCDYN_OK) THEN
      ! require(.FALSE.) registers the failure (nfail > 0 fails the gate even though
      ! scoring continues on partial statistics); the completeness assertion after the
      ! loop makes the early exit unmissable in its own right.
      CALL require(.FALSE., '3D dynamic step converged: '//TRIM(em)); EXIT
    END IF
    steps_done = steps_done + 1
    IF (t >= T_SCORE) THEN
      CALL CD_HermiteCable_Dyn_Curvature_Exact(model, cdyn, es, em)
      DO i = 1, nn
        arc_i = REAL(i - 1, wp)*l0e
        IF (arc_i >= 0.03_wp*Lsus .AND. arc_i <= 0.97_wp*Lsus) THEN
          kdyn = MAX(kdyn, cdyn(i))
          y_hi = MAX(y_hi, model%q(6*(i - 1) + 2))
          y_lo = MIN(y_lo, model%q(6*(i - 1) + 2))
        END IF
      END DO
      yc_hi = MAX(yc_hi, model%q(6*(i_crest - 1) + 2)); yc_lo = MIN(yc_lo, model%q(6*(i_crest - 1) + 2))
      ys_hi = MAX(ys_hi, model%q(6*(i_sag - 1) + 2)); ys_lo = MIN(ys_lo, model%q(6*(i_sag - 1) + 2))
      mnorm = SQRT(model%q(4)**2 + model%q(5)**2 + model%q(6)**2)
      tension = EA*(mnorm - 1.0_wp)/1000.0_wp
      tmean = tmean + tension; nsc = nsc + 1
      tmin = MIN(tmin, tension); tmax = MAX(tmax, tension)
    END IF
  END DO
  CALL CD_HermiteCable_Dyn_End(model)
  tmean = tmean/REAL(MAX(nsc, 1), wp)
  ! completeness: the scored statistics are only meaningful over the FULL window
  CALL require(steps_done == nstep, '3D dynamic solve completed the full 72 s window (no early exit)')

  WRITE (*, '(A,F8.5)') 'L3-6E dynamic max curvature (3D) = ', kdyn
  WRITE (*, '(A,F8.4,A,F8.4,A)') 'L3-6E out-of-plane Y interior env = ', y_lo, ' .. ', y_hi, ' m'
  WRITE (*, '(A,F8.4,A,F8.4,A,F6.1,A)') 'L3-6E Y @ arch crest = ', yc_lo, ' .. ', yc_hi, &
    ' m  (arc ', REAL(i_crest - 1, wp)*l0e, ' m)'
  WRITE (*, '(A,F8.4,A,F8.4,A,F6.1,A)') 'L3-6E Y @ sag bend   = ', ys_lo, ' .. ', ys_hi, &
    ' m  (arc ', REAL(i_sag - 1, wp)*l0e, ' m)'
  WRITE (*, '(A,F9.4,A,F9.4,A,F9.4,A)') 'L3-6E hang-off tension mean/min/max = ', tmean, ' /', tmin, ' /', tmax, ' kN'

  IF (REF_KDYN > 0.0_wp) THEN
    CALL require(ABS(kdyn - REF_KDYN)/REF_KDYN < 0.03_wp, '3D dynamic max curvature within 3% of OrcaFlex')
    CALL require(ABS(y_hi - REF_YHI) < 0.05_wp, 'interior Y max within 5 cm of OrcaFlex')
    CALL require(ABS(y_lo - REF_YLO) < 0.05_wp, 'interior Y min within 5 cm of OrcaFlex')
    CALL require(ABS(yc_hi - REF_YCREST_HI) < 0.05_wp, 'arch-crest Y max within 5 cm of OrcaFlex')
    CALL require(ABS(yc_lo - REF_YCREST_LO) < 0.05_wp, 'arch-crest Y min within 5 cm of OrcaFlex')
    CALL require(ABS(ys_hi - REF_YSAG_HI) < 0.05_wp, 'sag-bend Y max within 5 cm of OrcaFlex')
    CALL require(ABS(ys_lo - REF_YSAG_LO) < 0.05_wp, 'sag-bend Y min within 5 cm of OrcaFlex')
    CALL require(ABS(tmean - REF_TMEAN)/REF_TMEAN < 0.02_wp, 'tension mean within 2% of OrcaFlex')
    CALL require(ABS(tmin - REF_TMIN)/REF_TMIN < 0.03_wp, 'tension min within 3% of OrcaFlex')
    CALL require(ABS(tmax - REF_TMAX)/REF_TMAX < 0.02_wp, 'tension max within 2% of OrcaFlex')
    ! what this row checks: a genuinely three-dimensional response (out-of-plane excursions
    ! comparable to the sway drive), not a planar solution with a rigid y-offset
    CALL require(y_hi > 0.5_wp .AND. y_lo < -0.5_wp, 'out-of-plane response is O(1 m) both ways')
  ELSE
    WRITE (*, '(A)') 'FAIL: L3-6E reference scalars not committed -- gate cannot pass unscored'
    ERROR STOP 1
  END IF

  IF (nfail > 0) THEN
    WRITE (*, '(A,I0,A)') 'FAIL: ', nfail, ' assertion(s) failed'
    ERROR STOP 1
  END IF
  WRITE (*, '(A)') 'PASS: L3-6e out-of-plane 3D dynamic lazy-wave (80 m whirl vs OrcaFlex)'

CONTAINS

  SUBROUTINE bail()
    WRITE (*, '(A)') 'FAIL: setup failed'
    ERROR STOP 1
  END SUBROUTINE bail

  INTEGER FUNCTION probe_node(arc) RESULT(k)
    !! Node index nearest the requested arc from the hang-off.
    REAL(wp), INTENT(IN) :: arc
    k = 1 + NINT(arc/l0e)
    k = MAX(1, MIN(nn, k))
  END FUNCTION probe_node

  SUBROUTINE require(cond, label)
    LOGICAL, INTENT(IN) :: cond
    CHARACTER(*), INTENT(IN) :: label
    IF (.NOT. cond) THEN
      WRITE (*, '(A,A)') 'MISMATCH: ', label
      nfail = nfail + 1
    END IF
  END SUBROUTINE require

END PROGRAM test_l3_lazywave_3d_dynamic
