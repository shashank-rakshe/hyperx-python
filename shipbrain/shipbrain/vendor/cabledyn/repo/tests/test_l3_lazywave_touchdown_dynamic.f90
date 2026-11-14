! File: tests/test_l3_lazywave_touchdown_dynamic.f90
! SPDX-License-Identifier: Apache-2.0
! Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
PROGRAM test_l3_lazywave_touchdown_dynamic
  !! L3-6d: MOVING-TOUCHDOWN dynamic lazy-wave parity vs OrcaFlex 11.6c -- the unpinned
  !! successor to the pinned-touchdown L3-6 protocol. The INSTALLED Lozon 80 m
  !! Gulf-of-Mexico cable -- hang-off (5, 0, -14) driven by the 3 m / 12 s heave,
  !! lazy-wave arch, touchdown on the REAL penalty seabed at -80 m, grounded run, anchor
  !! fixed at (125, 0, -80) -- so the touchdown point migrates along the bed every heave
  !! cycle: the dynamic contact regime the pinned protocol excludes, and the first
  !! committed exercise of the Hermite dynamic path's seabed contact.
  !!
  !! Like-for-like contact: CableDyn's penalty seabed kn = 1e5*d N/m per unit length
  !! equals OrcaFlex's default elastic seabed (100 kN/m/m^2) times the contact width;
  !! the OrcaFlex reference (validation/scripts/orcaflex_lazywave_touchdown_dynamic.py, seg 0.75 m,
  !! implicit dt 0.05 s, still water) zeroes seabed friction to match CableDyn's
  !! frictionless contact.
  !!
  !! Static IC by the production MESH-SEQUENCED solve (44 -> 88 -> 176 elements,
  !! CD_HermiteCable_Static_Solve_Sequenced) on the composite seed: the committed 80 m
  !! span polyline extended by a straight grounded run to the anchor. Robustness note:
  !! at this site the grounded run's rest arc (36.1 m) is 13.9% SHORT of the seed chord
  !! (41.1 m, span touchdown -> anchor), so the cold seed carries ~14% axial strain over
  !! the grounded elements -- the coarse-first ladder still selects the smooth installed
  !! branch (the true equilibrium shifts the touchdown ~6.4 m anchor-ward of the
  !! pinned-span seed's touchdown), converging in ~490 coarse + 9 + 5 polish iterations.
  !!
  !! Scored on the steady window t in [24, 60] s at dt = 0.05 s: static peak curvature
  !! and static TDP arc; dynamic max curvature (interior 3-97% arc); TDP-REGION dynamic
  !! curvature (arc +/- 25 m about the static TDP); hang-off tension EA(|m|-1)
  !! mean/min/max; TDP arc excursion (min/max of the first-contact arc).
  USE CableDyn_Precision, ONLY: wp
  USE CableDyn_HermiteCableStatic, ONLY: CD_HermiteCable_Static_Solve_Sequenced, CD_HCSTAT_OK
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
  REAL(wp), PARAMETER :: LTOT = 170.215_wp                  ! 5 + 63.114 + 50 + 52.101
  REAL(wp), PARAMETER :: SEABED = -80.0_wp, KN = 1.0e5_wp*BARED
  REAL(wp), PARAMETER :: HOX = 5.0_wp, HOZ = -14.0_wp, ANCX = 125.0_wp
  REAL(wp), PARAMETER :: AMP = 3.0_wp, PER = 12.0_wp, DT = 0.05_wp
  REAL(wp), PARAMETER :: T_END = 60.0_wp, T_SCORE = 24.0_wp
  REAL(wp), PARAMETER :: CONTACT_TOL = 0.05_wp, TDP_KWIN = 25.0_wp
  INTEGER, PARAMETER :: NE = 176, NLEV = 3                  ! 44 -> 88 -> 176 sequenced

  ! OrcaFlex 11.6c references (validation/scripts/orcaflex_lazywave_touchdown_dynamic.py, installed
  ! 80 m, seg 0.75 m, implicit dt 0.05 s; reference's own dt-halving convergence 0.010%).
  ! OrcaFlex grounds the line CENTRELINE at bed + OD/2 (its TDP arcs carry that
  ! convention); CableDyn's penalty seabed grounds the centreline at the plane, so the
  ! static TDP locations may differ by the contact-geometry offset (~1-2 m at the
  ! touchdown grazing angle) on top of both probes' ~1 m arc quantisation.
  REAL(wp), PARAMETER :: REF_KSTAT = 0.09676_wp, REF_KDYN = 0.10321_wp, REF_KTDP = 0.08451_wp
  REAL(wp), PARAMETER :: REF_TMEAN = 9.3321_wp, REF_TMIN = 5.6513_wp, REF_TMAX = 13.0876_wp
  REAL(wp), PARAMETER :: REF_TDPLO = 134.48_wp, REF_TDPHI = 137.48_wp, REF_TDPSTAT = 135.48_wp

  INTEGER :: nn, i, e, u, ios, es, nfix, s, nstep, nnsp, ibl(NLEV), nsc, steps_done
  REAL(wp) :: l0e, a_mid, res, Lsus, dum, t, zt, vt, at, z0
  REAL(wp) :: kstat, kdyn, ktdp_dyn, tdp_static, tdp_lo, tdp_hi, arc_i, mnorm, tension
  REAL(wp) :: tmean, tmin, tmax
  REAL(wp), ALLOCATABLE :: posf(:, :), seed(:), q_static(:), l0(:), EAv(:), EIv(:), w(:)
  REAL(wp), ALLOCATABLE :: rhoa(:), curv(:), cdyn(:), hdiam(:), hcdn(:), hcdt(:), hcan(:), hcat(:)
  INTEGER, ALLOCATABLE :: fixed(:)
  INTEGER :: pdof(1), nfail
  REAL(wp) :: pq(1), pv(1), pa(1)
  TYPE(CD_HermiteCableDynType) :: model
  CHARACTER(300) :: em

  nfail = 0
  nn = NE + 1
  l0e = LTOT/REAL(NE, wp)

  ! --- committed 80 m span seed (site frame), extended by the straight grounded run ---
  OPEN (NEWUNIT=u, FILE='gomex80_lazywave_seed.xyz', STATUS='OLD', ACTION='READ', IOSTAT=ios)
  IF (ios /= 0) THEN
    WRITE (*, '(A)') 'FAIL: cannot open gomex80_lazywave_seed.xyz'; ERROR STOP 1
  END IF
  READ (u, *) nnsp, Lsus
  READ (u, *) dum, dum
  ALLOCATE (posf(3, nnsp))
  DO i = 1, nnsp
    READ (u, *) posf(1, i), posf(2, i), posf(3, i)
    posf(1, i) = posf(1, i) + HOX
    posf(3, i) = posf(3, i) + HOZ
  END DO
  CLOSE (u)

  ALLOCATE (seed(6*nn), q_static(6*nn), l0(NE), EAv(NE), EIv(NE), w(NE), rhoa(NE))
  ALLOCATE (curv(nn), cdyn(nn), fixed(6 + 2*nn))
  ALLOCATE (hdiam(NE), hcdn(NE), hcdt(NE), hcan(NE), hcat(NE))
  seed = 0.0_wp
  DO i = 1, nn
    arc_i = REAL(i - 1, wp)*l0e
    CALL seed_point(arc_i, seed(6*(i - 1) + 1:6*(i - 1) + 3))
  END DO
  DO i = 1, nn
    BLOCK
      REAL(wp) :: tv(3)
      IF (i < nn) THEN
        tv = seed(6*i + 1:6*i + 3) - seed(6*(i - 1) + 1:6*(i - 1) + 3)
      ELSE
        tv = seed(6*(i - 1) + 1:6*(i - 1) + 3) - seed(6*(i - 2) + 1:6*(i - 2) + 3)
      END IF
      tv = tv/SQRT(SUM(tv**2))
      seed(6*(i - 1) + 4:6*(i - 1) + 6) = tv
    END BLOCK
  END DO
  DO e = 1, NE
    l0(e) = l0e; EAv(e) = EA
    a_mid = REAL(e, wp)*l0e - 0.5_wp*l0e
    EIv(e) = EI_FULL
    IF (a_mid > LTOP .AND. a_mid <= LTOP + LBUOY) THEN
      w(e) = (BMASS - RHOW*0.25_wp*PI*BOD**2)*GACC
      rhoa(e) = BMASS; hdiam(e) = BOD
    ELSE
      w(e) = (BAREM - RHOW*0.25_wp*PI*BARED**2)*GACC
      rhoa(e) = BAREM; hdiam(e) = BARED
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

  ! --- installed static equilibrium by the production sequenced solve ---
  CALL CD_HermiteCable_Static_Solve_Sequenced(l0, EAv, EIv, w, seed, fixed(1:nfix), SEABED, KN, &
                                              8, 120, 1.0e-6_wp, 0.7_wp, NLEV, q_static, curv, &
                                              res, ibl, es, em)
  CALL require(es == CD_HCSTAT_OK, 'installed static (sequenced) converged: '//TRIM(em))
  IF (es /= CD_HCSTAT_OK) CALL bail()
  WRITE (*, '(A,3I6)') 'L3-6D static iterations by level = ', ibl
  kstat = 0.0_wp
  DO i = 1, nn
    arc_i = REAL(i - 1, wp)*l0e
    IF (arc_i >= 0.03_wp*LTOT .AND. arc_i <= 0.97_wp*LTOT) kstat = MAX(kstat, curv(i))
  END DO
  tdp_static = first_contact_arc(q_static)
  WRITE (*, '(A,F8.5,A,F8.2,A)') 'L3-6D static peak curvature = ', kstat, &
    '   static TDP arc = ', tdp_static, ' m'

  ! --- dynamics: drag + added mass + live seabed contact, hang-off heave ---
  CALL CD_HermiteCable_Dyn_Init(model, l0, EAv, EIv, rhoa, w, q_static, fixed(1:nfix), &
                                SEABED, KN, 0.5_wp, es, em)
  CALL require(es == CD_HCDYN_OK, 'dynamic init: '//TRIM(em))
  IF (es /= CD_HCDYN_OK) CALL bail()
  CALL CD_HermiteCable_Dyn_Set_Drag(model, RHOW, hdiam, hcdn, hcdt, 0.0_wp, &
                                    [0.0_wp, 0.0_wp, 0.0_wp], es, em)
  CALL require(es == CD_HCDYN_OK, 'drag config: '//TRIM(em))
  CALL CD_HermiteCable_Dyn_Set_AddedMass(model, RHOW, hdiam, hcan, hcat, 0.0_wp, es, em)
  CALL require(es == CD_HCDYN_OK, 'added-mass config: '//TRIM(em))

  z0 = q_static(3)
  pdof(1) = 3
  kdyn = 0.0_wp; ktdp_dyn = 0.0_wp
  tdp_lo = HUGE(1.0_wp); tdp_hi = -HUGE(1.0_wp)
  tmean = 0.0_wp; tmin = HUGE(1.0_wp); tmax = -HUGE(1.0_wp); nsc = 0
  nstep = NINT(T_END/DT)
  steps_done = 0
  t = 0.0_wp
  DO s = 1, nstep
    t = t + DT
    zt = z0 + AMP*SIN(2.0_wp*PI*t/PER)
    vt = AMP*(2.0_wp*PI/PER)*COS(2.0_wp*PI*t/PER)
    at = -AMP*(2.0_wp*PI/PER)**2*SIN(2.0_wp*PI*t/PER)
    pq(1) = zt; pv(1) = vt; pa(1) = at
    CALL CD_HermiteCable_Dyn_Step(model, DT, 100, 1.0e-4_wp, es, em, &
                                  pres_dofs=pdof, pres_q=pq, pres_v=pv, pres_a=pa)
    IF (es /= CD_HCDYN_OK) THEN
      ! require(.FALSE.) registers the failure (nfail > 0 fails the gate even though
      ! scoring continues on partial statistics); the completeness assertion after the
      ! loop makes the early exit unmissable in its own right.
      CALL require(.FALSE., 'dynamic step converged: '//TRIM(em)); EXIT
    END IF
    steps_done = steps_done + 1
    IF (t >= T_SCORE) THEN
      CALL CD_HermiteCable_Dyn_Curvature_Exact(model, cdyn, es, em)
      DO i = 1, nn
        arc_i = REAL(i - 1, wp)*l0e
        IF (arc_i >= 0.03_wp*LTOT .AND. arc_i <= 0.97_wp*LTOT) kdyn = MAX(kdyn, cdyn(i))
        IF (ABS(arc_i - tdp_static) <= TDP_KWIN) ktdp_dyn = MAX(ktdp_dyn, cdyn(i))
      END DO
      BLOCK
        REAL(wp) :: tdp
        tdp = first_contact_arc(model%q)
        tdp_lo = MIN(tdp_lo, tdp); tdp_hi = MAX(tdp_hi, tdp)
      END BLOCK
      mnorm = SQRT(model%q(4)**2 + model%q(5)**2 + model%q(6)**2)
      tension = EA*(mnorm - 1.0_wp)/1000.0_wp
      tmean = tmean + tension; nsc = nsc + 1
      tmin = MIN(tmin, tension); tmax = MAX(tmax, tension)
    END IF
  END DO
  CALL CD_HermiteCable_Dyn_End(model)
  tmean = tmean/REAL(MAX(nsc, 1), wp)
  ! completeness: the scored statistics are only meaningful over the FULL window
  CALL require(steps_done == nstep, 'dynamic solve completed the full 60 s window (no early exit)')

  WRITE (*, '(A,F8.5,A,F8.5)') 'L3-6D dynamic max curvature = ', kdyn, '   TDP-region dyn curv = ', ktdp_dyn
  WRITE (*, '(A,F9.4,A,F9.4,A,F9.4,A)') 'L3-6D hang-off tension mean/min/max = ', tmean, ' /', tmin, ' /', tmax, ' kN'
  WRITE (*, '(A,F8.2,A,F8.2,A,F6.2,A)') 'L3-6D TDP excursion = ', tdp_lo, ' .. ', tdp_hi, &
    ' m  (range ', tdp_hi - tdp_lo, ' m)'

  ! Gates vs the OrcaFlex reference (a missing reference fails the gate below).
  IF (REF_KSTAT > 0.0_wp) THEN
    CALL require(ABS(kstat - REF_KSTAT)/REF_KSTAT < 0.03_wp, 'static peak curvature within 3% of OrcaFlex')
    CALL require(ABS(kdyn - REF_KDYN)/REF_KDYN < 0.03_wp, 'dynamic max curvature within 3% of OrcaFlex')
    CALL require(ABS(ktdp_dyn - REF_KTDP)/REF_KTDP < 0.05_wp, 'TDP-region curvature within 5% of OrcaFlex')
    CALL require(ABS(tmean - REF_TMEAN)/REF_TMEAN < 0.02_wp, 'tension mean within 2% of OrcaFlex')
    CALL require(ABS(tmin - REF_TMIN)/REF_TMIN < 0.03_wp, 'tension min within 3% of OrcaFlex')
    CALL require(ABS(tmax - REF_TMAX)/REF_TMAX < 0.02_wp, 'tension max within 2% of OrcaFlex')
    ! excursion bounds: observed 0.05 m (lower) and 1.1 m (upper) from OrcaFlex; each probe is
    ! quantised to ~1 m of arc (OrcaFlex grid 1 m, CableDyn node spacing ~0.97 m)
    CALL require(ABS(tdp_lo - REF_TDPLO) < 1.5_wp, 'TDP excursion lower bound within 1.5 m of OrcaFlex')
    CALL require(ABS(tdp_hi - REF_TDPHI) < 1.5_wp, 'TDP excursion upper bound within 1.5 m of OrcaFlex')
    ! static touchdown location (observed 0.08 m); gated at 1.5 m to absorb the ~1 m arc
    ! quantisation and the bed+OD/2-vs-plane contact-convention offset noted above.
    CALL require(ABS(tdp_static - REF_TDPSTAT) < 1.5_wp, 'static TDP arc within 1.5 m of OrcaFlex')
    ! what this row checks: the touchdown point demonstrably MIGRATES (more than one node
    ! quantum), and the migration RANGE agrees within the two probes' arc quantisation
    ! (OrcaFlex grid 1 m, CableDyn node spacing ~0.97 m).
    CALL require(tdp_hi - tdp_lo > 1.0_wp, 'touchdown point migrates (> 1 m excursion range)')
    CALL require(ABS((tdp_hi - tdp_lo) - (REF_TDPHI - REF_TDPLO)) < 1.5_wp, &
                 'TDP excursion range within 1.5 m of OrcaFlex (observed 1.1 m)')
  ELSE
    WRITE (*, '(A)') 'FAIL: L3-6D reference scalars not committed (REF_KSTAT <= 0) -- gate cannot pass unscored'
    ERROR STOP 1
  END IF

  IF (nfail > 0) THEN
    WRITE (*, '(A,I0,A)') 'FAIL: ', nfail, ' assertion(s) failed'
    ERROR STOP 1
  END IF
  WRITE (*, '(A)') 'PASS: L3-6d moving-touchdown dynamic lazy-wave (installed 80 m vs OrcaFlex)'

CONTAINS

  SUBROUTINE bail()
    WRITE (*, '(A)') 'FAIL: setup failed'
    ERROR STOP 1
  END SUBROUTINE bail

  SUBROUTINE seed_point(arc, p)
    !! Composite installed seed: the committed span polyline for arc <= Lsus, then the
    !! straight grounded run to the anchor.
    REAL(wp), INTENT(IN) :: arc
    REAL(wp), INTENT(OUT) :: p(3)
    REAL(wp) :: ds, tt, frac
    INTEGER :: k
    ds = Lsus/REAL(nnsp - 1, wp)
    IF (arc <= Lsus) THEN
      k = MIN(INT(arc/ds) + 1, nnsp - 1)
      tt = (arc - REAL(k - 1, wp)*ds)/ds
      p = (1.0_wp - tt)*posf(:, k) + tt*posf(:, k + 1)
    ELSE
      frac = (arc - Lsus)/(LTOT - Lsus)
      p(1) = posf(1, nnsp) + frac*(ANCX - posf(1, nnsp))
      p(2) = 0.0_wp
      p(3) = SEABED
    END IF
  END SUBROUTINE seed_point

  REAL(wp) FUNCTION first_contact_arc(q) RESULT(tdp)
    !! Arc (from the hang-off) of the first node in seabed contact (z within CONTACT_TOL
    !! of the bed or below it).
    REAL(wp), INTENT(IN) :: q(:)
    INTEGER :: i2
    tdp = LTOT
    DO i2 = 1, nn
      IF (q(6*(i2 - 1) + 3) <= SEABED + CONTACT_TOL) THEN
        tdp = REAL(i2 - 1, wp)*l0e
        RETURN
      END IF
    END DO
  END FUNCTION first_contact_arc

  SUBROUTINE require(cond, label)
    LOGICAL, INTENT(IN) :: cond
    CHARACTER(*), INTENT(IN) :: label
    IF (.NOT. cond) THEN
      WRITE (*, '(A,A)') 'MISMATCH: ', label
      nfail = nfail + 1
    END IF
  END SUBROUTINE require

END PROGRAM test_l3_lazywave_touchdown_dynamic
