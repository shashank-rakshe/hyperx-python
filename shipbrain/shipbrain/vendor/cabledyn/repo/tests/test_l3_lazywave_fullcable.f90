! File: tests/test_l3_lazywave_fullcable.f90
! SPDX-License-Identifier: Apache-2.0
! Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
PROGRAM test_l3_lazywave_fullcable
  !! L3-5 CLOSURE CELL: the Humboldt 800 m lazy-wave cable solved as the FULL INSTALLED cable --
  !! fairlead (5, 0, -14), seabed anchor (805, 0, -800), grounded run on a penalty seabed --
  !! against the OrcaFlex installed-cable reference (validation/scripts/orcaflex_lozon_cables.py, seg 0.75 m,
  !! and re-verified with seabed friction zeroed: peak curvature 0.02802 1/m at the sag bend,
  !! hang-off tension 56.535 kN -- friction is measurably IRRELEVANT to this static, so the
  !! frictionless CableDyn comparison is like-for-like). The fourth corner of the
  !! pinned-span-vs-installed attribution: the matched pinned-span comparison agrees to 0.05%
  !! mesh-converged (l3_lazywave_refinement); this gate measures the installed protocol.
  !!
  !! Cable (Lozon Tables 16/21): sections hang-off -> anchor bare 372.449 m + buoyant 400 m
  !! (0.29 m / 59.17 kg/m) + bare 597.981 m; total 1370.43 m; bare 0.16 m / 36.7 kg/m /
  !! EA 469 MN / EI 19.9 kN m^2.
  !!
  !! SOLVE ARCHITECTURE -- MESH-SEQUENCING FROM COARSE (the iteration-count strategy): the
  !! full nonlinear work (buoyancy continuation, contact settlement, kink-basin selection)
  !! happens ONCE on an 89-element mesh where every Newton iteration costs ~1 ms and the
  !! smooth branch is easy to hold; each doubled level (178 / 356 / 712 elements) then starts
  !! at the prolongated answer (Hermite-interpolant midpoints) and only POLISHES at full
  !! buoyancy + full penalty (n_buoy_steps = 1). Direct fine-mesh attempts measurably fail
  !! here: a cold 357-element composite seed under the internal ramp folds at the touchdown,
  !! a no-bed-first penalty ramp folds the hanging grounded loop, and a span-first fine
  !! polish folds the arch (three kinked local equilibria, all recorded) -- the coarse level
  !! is where the branch is selected safely.
  !!
  !! The mesh carries span and ground element sizes exactly (span 60 * 2^k, ground 29 * 2^k
  !! elements) so prolongation preserves the block structure; sections and the peak scan use
  !! the cumulative arc. Penalty seabed kn = 1e5 * diameter per tributary length.
  !!
  !! Scored at the finest level: peak interior curvature (3-97% arc) and hang-off tension
  !! EA(|m|-1) vs OrcaFlex, the last-doubling peak drift (mesh stability), and the per-level
  !! iteration log (the tracked iteration budget). Intermediate prolongated levels may
  !! transiently localise their peak in the touchdown/contact region while the finer contact
  !! boundary layer settles (visible in the per-level log); only the finest level is scored
  !! and the drift gate compares the last doubling.
  USE CableDyn_Precision, ONLY: wp
  USE CableDyn_HermiteCableStatic, ONLY: CD_HermiteCable_Static_Solve, CD_HCSTAT_OK
  IMPLICIT NONE

  REAL(wp), PARAMETER :: RHOW = 1025.0_wp, GACC = 9.80665_wp, PI = 3.141592653589793_wp
  REAL(wp), PARAMETER :: EA = 4.69e8_wp, EI_FULL = 1.99e4_wp
  REAL(wp), PARAMETER :: LTOP = 372.449_wp, LBUOY = 400.0_wp
  REAL(wp), PARAMETER :: BMASS = 59.17_wp, BOD = 0.29_wp, BAREM = 36.7_wp, BARED = 0.16_wp
  REAL(wp), PARAMETER :: LTOT = 1370.43_wp
  REAL(wp), PARAMETER :: FAIR_X = 5.0_wp, FAIR_Z = -14.0_wp
  REAL(wp), PARAMETER :: ANCH_X = 805.0_wp, SEABED = -800.0_wp
  REAL(wp), PARAMETER :: KN = 1.0e5_wp*BARED
  INTEGER, PARAMETER :: NSP0 = 60, NGD0 = 29, NLEV = 4      ! 89 -> 178 -> 356 -> 712 elements
  ! OrcaFlex 11.6c installed-cable reference (friction-irrelevant; see header)
  REAL(wp), PARAMETER :: ORCA_KPEAK = 0.02802_wp, ORCA_THO = 56.535_wp
  REAL(wp), PARAMETER :: KGATE = 0.05_wp, TGATE = 0.05_wp, DRIFT_GATE = 0.02_wp
  INTEGER, PARAMETER :: ITER_BUDGET_POLISH = 120           ! per prolongated level

  REAL(wp) :: bare_w, buoy_w, Lsus, dum, kpeak(NLEV), t_ho(NLEV)
  REAL(wp), ALLOCATABLE :: span(:, :), q_lev(:), q_next(:)
  INTEGER :: nn_span, u, i, ios, nfail, lev, iters_lev(NLEV)

  nfail = 0
  bare_w = (BAREM - RHOW*0.25_wp*PI*BARED**2)*GACC
  buoy_w = (BMASS - RHOW*0.25_wp*PI*BOD**2)*GACC

  ! committed suspended-span shooter seed, shifted to the site frame (hang-off (5, -14))
  OPEN (NEWUNIT=u, FILE='humboldt_lazywave_seed.xyz', STATUS='OLD', ACTION='READ', IOSTAT=ios)
  IF (ios /= 0) THEN
    WRITE (*, '(A)') 'FAIL: cannot open humboldt_lazywave_seed.xyz'; ERROR STOP 1
  END IF
  READ (u, *) nn_span, Lsus
  READ (u, *) dum, dum
  ALLOCATE (span(3, nn_span))
  DO i = 1, nn_span
    READ (u, *) span(1, i), span(2, i), span(3, i)
    span(1, i) = span(1, i) + FAIR_X
    span(3, i) = span(3, i) + FAIR_Z
  END DO
  CLOSE (u)

  ! level 1: the full continuation on the coarse mesh; levels 2..NLEV: prolongate + polish
  CALL solve_level(1, q_lev, kpeak(1), t_ho(1), iters_lev(1))
  CALL require(ALLOCATED(q_lev), 'coarse installed solve converged')
  IF (.NOT. ALLOCATED(q_lev)) CALL bail()
  DO lev = 2, NLEV
    CALL solve_level(lev, q_next, kpeak(lev), t_ho(lev), iters_lev(lev), q_lev)
    CALL require(ALLOCATED(q_next), 'prolongated level converged')
    IF (.NOT. ALLOCATED(q_next)) CALL bail()
    CALL MOVE_ALLOC(q_next, q_lev)
  END DO

  WRITE (*, '(A,4F10.6)') 'L3-5I peak curvature by level = ', kpeak
  WRITE (*, '(A,4I6)') 'L3-5I iterations by level     = ', iters_lev
  WRITE (*, '(A,F9.6,A,F9.6,A,F6.2,A)') 'L3-5I finest peak curvature = ', kpeak(NLEV), &
    '   OrcaFlex installed ', ORCA_KPEAK, '   err ', 100.0_wp*ABS(kpeak(NLEV) - ORCA_KPEAK)/ORCA_KPEAK, '%'
  WRITE (*, '(A,F9.4,A,F9.4,A,F6.2,A)') 'L3-5I hang-off tension      = ', t_ho(NLEV), &
    '   OrcaFlex installed ', ORCA_THO, '   err ', 100.0_wp*ABS(t_ho(NLEV) - ORCA_THO)/ORCA_THO, '%'

  CALL require(ABS(kpeak(NLEV) - ORCA_KPEAK)/ORCA_KPEAK < KGATE, 'installed peak curvature within 5% of OrcaFlex')
  CALL require(ABS(t_ho(NLEV) - ORCA_THO)/ORCA_THO < TGATE, 'installed hang-off tension within 5% of OrcaFlex')
  CALL require(ABS(kpeak(NLEV - 1) - kpeak(NLEV))/kpeak(NLEV) < DRIFT_GATE, &
               'peak mesh-stable (last doubling drift < 2%)')
  DO lev = 2, NLEV
    CALL require(iters_lev(lev) <= ITER_BUDGET_POLISH, 'polish level within the iteration budget')
  END DO

  IF (nfail > 0) THEN
    WRITE (*, '(A,I0,A)') 'FAIL: ', nfail, ' assertion(s) failed'
    ERROR STOP 1
  END IF
  WRITE (*, '(A)') 'PASS: installed 800 m lazy-wave agrees with the OrcaFlex installed-cable reference'

CONTAINS

  SUBROUTINE bail()
    WRITE (*, '(A)') 'FAIL: installed solve did not converge'
    ERROR STOP 1
  END SUBROUTINE bail

  SUBROUTINE build_mesh(lev, ne, l0, EAv, EIv, w)
    !! Installed-cable mesh at level `lev`: span NSP0*2^(lev-1) elements of equal length,
    !! ground NGD0*2^(lev-1); sections mapped by cumulative arc midpoint.
    INTEGER, INTENT(IN) :: lev
    INTEGER, INTENT(OUT) :: ne
    REAL(wp), ALLOCATABLE, INTENT(OUT) :: l0(:), EAv(:), EIv(:), w(:)
    INTEGER :: nsp, ngd, e, sc
    REAL(wp) :: a_mid, acc
    sc = 2**(lev - 1)
    nsp = NSP0*sc
    ngd = NGD0*sc
    ne = nsp + ngd
    ALLOCATE (l0(ne), EAv(ne), EIv(ne), w(ne))
    l0(1:nsp) = Lsus/REAL(nsp, wp)
    l0(nsp + 1:ne) = (LTOT - Lsus)/REAL(ngd, wp)
    acc = 0.0_wp
    DO e = 1, ne
      a_mid = acc + 0.5_wp*l0(e)
      acc = acc + l0(e)
      EAv(e) = EA; EIv(e) = EI_FULL
      IF (a_mid > LTOP .AND. a_mid <= LTOP + LBUOY) THEN
        w(e) = buoy_w
      ELSE
        w(e) = bare_w
      END IF
    END DO
  END SUBROUTINE build_mesh

  SUBROUTINE solve_level(lev, q_out, kp, th, iters_out, q_coarse)
    !! Level 1: cold composite seed (span shape resampled + grounded run on the bed), FULL
    !! internal buoyancy continuation. Levels >= 2: Hermite-interpolant prolongation of the
    !! converged coarser solution, POLISH (n_buoy_steps = 1).
    INTEGER, INTENT(IN) :: lev
    REAL(wp), ALLOCATABLE, INTENT(OUT) :: q_out(:)
    REAL(wp), INTENT(OUT) :: kp, th
    INTEGER, INTENT(OUT) :: iters_out
    REAL(wp), INTENT(IN), OPTIONAL :: q_coarse(:)
    INTEGER :: ne, nn, i, es, iters, nfix, nec, kloc
    REAL(wp) :: res, mnorm, arc_i, tv(3), p(3)
    REAL(wp), ALLOCATABLE :: l0(:), EAv(:), EIv(:), w(:), seed(:), q(:), curv(:)
    REAL(wp), ALLOCATABLE :: l0c(:), dea(:), dei(:), dwc(:)
    INTEGER, ALLOCATABLE :: fixed(:)
    CHARACTER(300) :: em
    iters_out = 0
    CALL build_mesh(lev, ne, l0, EAv, EIv, w)
    nn = ne + 1
    ALLOCATE (seed(6*nn), q(6*nn), curv(nn), fixed(6 + 2*nn))

    IF (PRESENT(q_coarse)) THEN
      CALL build_mesh(lev - 1, nec, l0c, dea, dei, dwc)   ! coarse element lengths
      CALL prolongate(q_coarse, l0c, seed)
    ELSE
      ! cold composite seed: span shape sampled by arc + straight grounded run on the bed
      DO i = 1, nn
        arc_i = cum_arc(l0, i)
        CALL seed_point(arc_i, p)
        seed(6*(i - 1) + 1:6*(i - 1) + 3) = p
      END DO
      DO i = 1, nn
        IF (i < nn) THEN
          tv = seed(6*i + 1:6*i + 3) - seed(6*(i - 1) + 1:6*(i - 1) + 3)
        ELSE
          tv = seed(6*(i - 1) + 1:6*(i - 1) + 3) - seed(6*(i - 2) + 1:6*(i - 2) + 3)
        END IF
        tv = tv/SQRT(SUM(tv**2))
        seed(6*(i - 1) + 4:6*(i - 1) + 6) = tv
      END DO
    END IF

    nfix = 0
    DO i = 1, 3; nfix = nfix + 1; fixed(nfix) = i; END DO
    DO i = 1, 3; nfix = nfix + 1; fixed(nfix) = 6*(nn - 1) + i; END DO
    DO i = 1, nn
      nfix = nfix + 1; fixed(nfix) = 6*(i - 1) + 2
      nfix = nfix + 1; fixed(nfix) = 6*(i - 1) + 5
    END DO

    IF (PRESENT(q_coarse)) THEN
      CALL CD_HermiteCable_Static_Solve(l0, EAv, EIv, w, seed, fixed(1:nfix), SEABED, KN, &
                                        1, 250, 1.0e-6_wp, 0.7_wp, q, curv, res, iters, es, em, &
                                        n_buoy_steps=1)
    ELSE
      CALL CD_HermiteCable_Static_Solve(l0, EAv, EIv, w, seed, fixed(1:nfix), SEABED, KN, &
                                        8, 120, 1.0e-6_wp, 0.7_wp, q, curv, res, iters, es, em)
    END IF
    IF (es /= CD_HCSTAT_OK) THEN
      WRITE (*, '(A,I0,A,A)') 'L3-5I level ', lev, ' solve FAILED: ', TRIM(em)
      kp = 0.0_wp; th = 0.0_wp
      RETURN
    END IF
    iters_out = iters
    kp = 0.0_wp; kloc = 1
    DO i = 1, nn
      arc_i = cum_arc(l0, i)
      IF (arc_i >= 0.03_wp*LTOT .AND. arc_i <= 0.97_wp*LTOT) THEN
        IF (curv(i) > kp) THEN
          kp = curv(i); kloc = i
        END IF
      END IF
    END DO
    mnorm = SQRT(q(4)**2 + q(5)**2 + q(6)**2)
    th = EA*(mnorm - 1.0_wp)/1000.0_wp                 ! hang-off tension, kN
    WRITE (*, '(A,I0,A,I0,A,I0,A,F8.1,A)') 'L3-5I level ', lev, ': ne = ', ne, '   iters = ', iters, &
      '   peak at arc ', cum_arc(l0, kloc), ' m'
    FLUSH (6)
    q_out = q
  END SUBROUTINE solve_level

  SUBROUTINE prolongate(qc, l0c, seed)
    !! Hermite-interpolant refinement of a converged coarse solution: coarse nodes copied,
    !! new nodes at the coarse element midpoints (r/m from the cubic interpolant).
    REAL(wp), INTENT(IN) :: qc(:), l0c(:)
    REAL(wp), INTENT(OUT) :: seed(:)
    INTEGER :: nec, e, nnf
    REAL(wp) :: r1(3), r2(3), m1(3), m2(3)
    nec = SIZE(l0c)
    nnf = 2*nec + 1
    DO e = 1, nec
      r1 = qc(6*(e - 1) + 1:6*(e - 1) + 3); m1 = qc(6*(e - 1) + 4:6*(e - 1) + 6)
      r2 = qc(6*e + 1:6*e + 3); m2 = qc(6*e + 4:6*e + 6)
      seed(6*(2*e - 2) + 1:6*(2*e - 2) + 3) = r1
      seed(6*(2*e - 2) + 4:6*(2*e - 2) + 6) = m1
      seed(6*(2*e - 1) + 1:6*(2*e - 1) + 3) = 0.5_wp*(r1 + r2) + l0c(e)*(m1 - m2)/8.0_wp
      seed(6*(2*e - 1) + 4:6*(2*e - 1) + 6) = 1.5_wp*(r2 - r1)/l0c(e) - 0.25_wp*(m1 + m2)
    END DO
    seed(6*(nnf - 1) + 1:6*(nnf - 1) + 3) = qc(6*nec + 1:6*nec + 3)
    seed(6*(nnf - 1) + 4:6*(nnf - 1) + 6) = qc(6*nec + 4:6*nec + 6)
  END SUBROUTINE prolongate

  REAL(wp) FUNCTION cum_arc(l0, node) RESULT(a)
    !! Cumulative rest arc length at node index `node` (1-based; node 1 -> 0).
    REAL(wp), INTENT(IN) :: l0(:)
    INTEGER, INTENT(IN) :: node
    INTEGER :: e
    a = 0.0_wp
    DO e = 1, node - 1
      a = a + l0(e)
    END DO
  END FUNCTION cum_arc

  SUBROUTINE seed_point(arc, p)
    !! Composite seed position at arc `arc` from the hang-off: the shooter span (linear
    !! interpolation between its uniformly spaced nodes) for arc <= Lsus, then the straight
    !! grounded run from the span's touchdown to the anchor on the seabed.
    REAL(wp), INTENT(IN) :: arc
    REAL(wp), INTENT(OUT) :: p(3)
    REAL(wp) :: ds, t, frac
    INTEGER :: k
    ds = Lsus/REAL(nn_span - 1, wp)
    IF (arc <= Lsus) THEN
      k = MIN(INT(arc/ds) + 1, nn_span - 1)
      t = (arc - REAL(k - 1, wp)*ds)/ds
      p = (1.0_wp - t)*span(:, k) + t*span(:, k + 1)
    ELSE
      frac = (arc - Lsus)/(LTOT - Lsus)
      p(1) = span(1, nn_span) + frac*(ANCH_X - span(1, nn_span))
      p(2) = 0.0_wp
      p(3) = SEABED
    END IF
  END SUBROUTINE seed_point

  SUBROUTINE require(cond, label)
    LOGICAL, INTENT(IN) :: cond
    CHARACTER(*), INTENT(IN) :: label
    IF (.NOT. cond) THEN
      WRITE (*, '(A,A)') 'MISMATCH: ', label
      nfail = nfail + 1
    END IF
  END SUBROUTINE require

END PROGRAM test_l3_lazywave_fullcable
