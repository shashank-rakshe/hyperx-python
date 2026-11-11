! File: tests/test_l3_lazywave_curvature.f90
! SPDX-License-Identifier: Apache-2.0
! Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
PROGRAM test_l3_lazywave_curvature
  !! L3 finite-EI lazy-wave power-cable curvature parity across the THREE reference-platform
  !! dynamic cables of Lozon et al. (2025) -- the IEA-15 MW VolturnUS-S sited at three US water
  !! depths: 80 m (Gulf of Mexico), 200 m (Gulf of Maine), 800 m (Humboldt, deep). Each cable is
  !! a lazy-wave configuration -- bare / buoyant / bare sections hung between the seabed
  !! touchdown and the floating support. No bend stiffener or local hang-off accessory is included.
  !!
  !! CableDyn solves the finite-EI static equilibrium on the cubic-Hermite bending-cable element
  !! (CD_HermiteCable_Static_Solve): position + material-tangent DOFs, no rotation chart. The
  !! net-buoyant arch equilibrium is non-unique (a smooth buoyant arch alongside spurious kinked
  !! local equilibria), so the solver traces the smooth branch by BUOYANCY LOAD CONTINUATION
  !! (ramping the buoyant weight 0 -> target in warm-started steps), which makes the converged
  !! curvature deterministic and build-independent. The suspended-span seeds are committed analytic
  !! piecewise-catenary shapes (tests/data/<site>_lazywave_seed.xyz, from validation/scripts/lazywave_seed_shooter.f90).
  !!
  !! Scored quantity: the peak along-arc CENTRELINE CURVATURE at the sag bend -- the fatigue-critical
  !! differentiator that discrete-kink lumped-mass bending recovery under-resolves where curvature
  !! localises. Reference: OrcaFlex 11.6d mesh-converged
  !! peak curvature (seg 0.75 m). Section properties are physical (bare 0.16 m / 36.7 kg/m; buoyant
  !! 0.29-0.30 m / 59.17-60.85 kg/m -> net lift computed here, not tuned).
  !!
  !! The 80 m / 200 m suspended spans are well resolved (element length 0.56 / 1.09 m) and match
  !! OrcaFlex to <0.3 %; the 800 m lands at ~4.8 % on the 240-element budget vs THIS gate's
  !! INSTALLED-CABLE reference and is MESH-CONVERGED at ~0.0264 1/m (l3_lazywave_refinement,
  !! 480 -> 960 by mesh-sequencing, drift 0.05 %), agreeing with OrcaFlex solved on the MATCHED
  !! PINNED SPAN (0.02639, the dynamic-reference tool) to 0.05 % -- the ~5 % residual here is the
  !! pinned-span-vs-installed-cable modelling delta at depth (the protocols coincide to <0.4 % at
  !! 80/200 m), not a code difference; all three codes stay inside the same band (MoorDyn-F reads
  !! +13 % above OrcaFlex on its native mesh).
  USE CableDyn_Precision, ONLY: wp
  USE CableDyn_HermiteCableStatic, ONLY: CD_HermiteCable_Static_Solve, CD_HCSTAT_OK
  IMPLICIT NONE

  REAL(wp), PARAMETER :: RHOW = 1025.0_wp, GACC = 9.80665_wp, PI = 3.141592653589793_wp
  REAL(wp), PARAMETER :: EA = 4.69e8_wp, EI_FULL = 1.99e4_wp

  INTEGER, PARAMETER :: NSITE = 3
  CHARACTER(32) :: seeds(NSITE)   ! set below (long names split the array constructor awkwardly)
  CHARACTER(6) :: names(NSITE) = [CHARACTER(6) :: '80m', '200m', '800m']
  REAL(wp) :: ltops(NSITE) = [68.114_wp, 171.978_wp, 372.449_wp]   ! top-bare arc extent
  REAL(wp) :: lbuoys(NSITE) = [50.0_wp, 60.0_wp, 400.0_wp]         ! buoyant section arc extent
  REAL(wp) :: bmass(NSITE) = [59.53_wp, 60.85_wp, 59.17_wp]        ! buoyant mass/length (kg/m)
  REAL(wp) :: bods(NSITE) = [0.29_wp, 0.30_wp, 0.29_wp]            ! buoyant diameter (m)
  REAL(wp) :: refs(NSITE) = [0.0968_wp, 0.0831_wp, 0.0280_wp]      ! OrcaFlex 11.6d mesh-converged
  ! per-site tolerance: observed 0.08 % / 0.26 % / 4.8 % (see header); 1 % at the resolved
  ! 80 m and 200 m spans, 6 % at 800 m (the installed-cable vs matched-span modelling offset)
  REAL(wp) :: gates(NSITE) = [0.01_wp, 0.01_wp, 0.06_wp]

  REAL(wp) :: buoy_w, bare_w, Lsus, l0e, a_mid, dum, res, kmax, errfrac
  INTEGER :: nn, ne, i, e, u, ios, es, iters, nfix, kloc, isite, nfail
  REAL(wp), ALLOCATABLE :: pos(:, :), seed(:), q(:), l0(:), EAv(:), EIv(:), w(:), curv(:), tv(:)
  INTEGER, ALLOCATABLE :: fixed(:)
  CHARACTER(300) :: em

  nfail = 0
  seeds(1) = 'gomex80_lazywave_seed.xyz'
  seeds(2) = 'gomaine200_lazywave_seed.xyz'
  seeds(3) = 'humboldt_lazywave_seed.xyz'
  bare_w = (36.7_wp - RHOW*0.25_wp*PI*0.16_wp**2)*GACC             ! net-heavy bare cable (N/m)
  WRITE (*, '(A6,2X,A11,2X,A11,2X,A7,2X,A8)') 'site', 'CableDyn/m', 'OrcaFlex/m', 'err%', 'arc m'

  DO isite = 1, NSITE
    buoy_w = (bmass(isite) - RHOW*0.25_wp*PI*bods(isite)**2)*GACC  ! net-buoyant (< 0): the arch

    ! --- read the committed suspended-span seed (analytic piecewise-catenary shooter output) ---
    OPEN (NEWUNIT=u, FILE=TRIM(seeds(isite)), STATUS='OLD', ACTION='READ', IOSTAT=ios)
    IF (ios /= 0) THEN
      WRITE (*, '(A)') 'FAIL: cannot open '//TRIM(seeds(isite))
      ERROR STOP 1
    END IF
    READ (u, *) nn, Lsus
    READ (u, *) dum, dum
    IF (ALLOCATED(pos)) DEALLOCATE (pos)
    ALLOCATE (pos(3, nn))
    DO i = 1, nn
      READ (u, *) pos(1, i), pos(2, i), pos(3, i)
    END DO
    CLOSE (u)

    ne = nn - 1
    l0e = Lsus/REAL(ne, wp)
    IF (ALLOCATED(seed)) DEALLOCATE (seed, q, l0, EAv, EIv, w, curv, fixed, tv)
    ALLOCATE (seed(6*nn), q(6*nn), l0(ne), EAv(ne), EIv(ne), w(ne), curv(nn), fixed(6 + 2*nn), tv(3))

    ! seed: node positions from the shooter shape; tangents = normalized chord
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

    ! per-element properties: bare / buoyant / bare sections by arc from the hang-off
    DO e = 1, ne
      l0(e) = l0e; EAv(e) = EA
      a_mid = REAL(e, wp)*l0e - 0.5_wp*l0e
      EIv(e) = EI_FULL
      IF (a_mid > ltops(isite) .AND. a_mid <= ltops(isite) + lbuoys(isite)) THEN
        w(e) = buoy_w
      ELSE
        w(e) = bare_w
      END IF
    END DO

    ! fixed DOFs: hang-off r (node 1), touchdown r (node nn), planar (y translation + tangent) everywhere
    nfix = 0
    DO i = 1, 3; nfix = nfix + 1; fixed(nfix) = i; END DO
    DO i = 1, 3; nfix = nfix + 1; fixed(nfix) = 6*(nn - 1) + i; END DO
    DO i = 1, nn
      nfix = nfix + 1; fixed(nfix) = 6*(i - 1) + 2   ! r_y
      nfix = nfix + 1; fixed(nfix) = 6*(i - 1) + 5   ! m_y
    END DO

    ! The solver detects the net-buoyant sections and runs buoyancy load continuation internally
    ! to reach the smooth arch deterministically; n_cont here is the EI onset for the first step.
    CALL CD_HermiteCable_Static_Solve(l0, EAv, EIv, w, seed, fixed(1:nfix), -2000.0_wp, 0.0_wp, &
                                      8, 60, 1.0e-6_wp, 0.7_wp, q, curv, res, iters, es, em)
    kmax = 0.0_wp; kloc = 0
    DO i = 1, nn
      IF (curv(i) > kmax) THEN; kmax = curv(i); kloc = i; END IF
    END DO
    errfrac = ABS(kmax - refs(isite))/refs(isite)
    WRITE (*, '(A6,2X,F11.5,2X,F11.5,2X,F6.2,A,2X,F8.1)') TRIM(names(isite)), kmax, refs(isite), &
      100.0_wp*errfrac, '%', REAL(kloc - 1, wp)*l0e
    CALL require(es == CD_HCSTAT_OK, TRIM(names(isite))//' lazy-wave solve converged: '//TRIM(em))
    CALL require(errfrac < gates(isite), TRIM(names(isite))//' curvature within OrcaFlex tolerance')
  END DO

  IF (nfail > 0) THEN
    WRITE (*, '(A,I0,A)') 'FAIL: ', nfail, ' assertion(s) failed'
    ERROR STOP 1
  END IF
  WRITE (*, '(A)') 'PASS: finite-EI lazy-wave power-cable curvature parity, 80/200/800 m (Lozon 2025 vs OrcaFlex)'

CONTAINS

  SUBROUTINE require(cond, label)
    LOGICAL, INTENT(IN) :: cond
    CHARACTER(*), INTENT(IN) :: label
    IF (.NOT. cond) THEN
      WRITE (*, '(A,A)') 'MISMATCH: ', label
      nfail = nfail + 1
    END IF
  END SUBROUTINE require

END PROGRAM test_l3_lazywave_curvature
