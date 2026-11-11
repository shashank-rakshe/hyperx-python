! File: tests/test_l3_lazywave_refinement.f90
! SPDX-License-Identifier: Apache-2.0
! Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
PROGRAM test_l3_lazywave_refinement
  !! L3-5 companion: MESH CONVERGENCE of the Humboldt 800 m lazy-wave peak sag-bend curvature
  !! on the cubic-Hermite path. The committed 240-element parity value (4.80% below the
  !! mesh-converged OrcaFlex 0.0280 1/m, gate `l3_lazywave_curvature`) is refined 480 -> 960
  !! elements by MESH-SEQUENCING CONTINUATION: each doubled mesh is seeded from the CONVERGED
  !! coarser solution sampled through the Hermite interpolant (element midpoints:
  !! r_mid = (r1+r2)/2 + le (m1 - m2)/8, m_mid = 1.5 (r2 - r1)/le - (m1 + m2)/4).
  !!
  !! Why mesh-sequencing: from the COLD analytic shooter seed at 960 elements the solver's
  !! internal buoyancy ramp lands on a KINKED local equilibrium (peak ~3.3 1/m), and a gentler
  !! outer buoyancy ramp stalls at the limp quarter-buoyancy intermediate; the smooth arch is
  !! reached reliably by warm-starting from the converged coarse mesh -- the documented
  !! fine-mesh practice for net-buoyant arches.
  !!
  !! Measured (2026-07-03): 240 -> 0.026656 (4.80%), 480 -> 0.026389 (5.75%),
  !! 960 -> 0.026376 (5.80%), 1920 -> ~0.02641 vs the parent gate's INSTALLED-CABLE
  !! reference; the 480 -> 960 drift is 0.05% and the 960 -> 1920 move is ~0.15% UPWARD --
  !! the three fine meshes span ~0.15% around 0.0264 and the sequence is NOT monotone
  !! (field convergence and ever-finer nodal peak SAMPLING compete at this level), so the
  !! honest statement is "flattened at ~0.15% spread around 0.0264", not a monotone drift.
  !! ATTRIBUTION: OrcaFlex
  !! solved on the MATCHED PINNED SPAN (the l3_lazywave_dynamic reference tool, seg 0.75 m)
  !! reads 0.02639 -- agreement to 0.05-0.15% at convergence -- so the ~5% offset above is the
  !! pinned-span-vs-installed-cable modelling delta at depth (the protocols coincide to <0.4%
  !! at 80/200 m), not a code difference; the three-code band stands (MoorDyn-F reads 0.0318
  !! on its native mesh, +13% above OrcaFlex). Gates: all refined solves converge, each stays
  !! within the parent gate's 8% band of the installed-cable reference, and both doubling
  !! moves (480 -> 960, 960 -> 1920) are < 0.5%. The 1920 level POLISHES the refined 960
  !! solution at full buoyancy (n_buoy_steps = 1: the seed is already the converged smooth
  !! arch). Every refined level is a full-load polish. Replaying the buoyancy ramp from a seed
  !! already on the installed branch can collapse the arch and select a different stationary
  !! configuration, which defeats the purpose of mesh sequencing.
  USE CableDyn_Precision, ONLY: wp
  USE CableDyn_HermiteCableStatic, ONLY: CD_HermiteCable_Static_Solve, CD_HCSTAT_OK
  IMPLICIT NONE

  REAL(wp), PARAMETER :: RHOW = 1025.0_wp, GACC = 9.80665_wp, PI = 3.141592653589793_wp
  REAL(wp), PARAMETER :: EA = 4.69e8_wp, EI_FULL = 1.99e4_wp
  REAL(wp), PARAMETER :: LTOP = 372.449_wp, LBUOY = 400.0_wp
  REAL(wp), PARAMETER :: BMASS = 59.17_wp, BOD = 0.29_wp
  REAL(wp), PARAMETER :: ORCA_REF = 0.0280_wp
  REAL(wp), PARAMETER :: BAND = 0.08_wp, DRIFT_GATE = 0.005_wp

  REAL(wp) :: bare_w, buoy_w, Lsus, dum, k480, k960, k1920
  REAL(wp), ALLOCATABLE :: pos0(:, :), pos(:, :), q480(:), q960(:), q1920(:)
  INTEGER :: nn0, u, i, ios, nfail

  nfail = 0
  bare_w = (36.7_wp - RHOW*0.25_wp*PI*0.16_wp**2)*GACC
  buoy_w = (BMASS - RHOW*0.25_wp*PI*BOD**2)*GACC

  OPEN (NEWUNIT=u, FILE='humboldt_lazywave_seed.xyz', STATUS='OLD', ACTION='READ', IOSTAT=ios)
  IF (ios /= 0) THEN
    WRITE (*, '(A)') 'FAIL: cannot open humboldt_lazywave_seed.xyz'
    ERROR STOP 1
  END IF
  READ (u, *) nn0, Lsus
  READ (u, *) dum, dum
  ALLOCATE (pos0(3, nn0))
  DO i = 1, nn0
    READ (u, *) pos0(1, i), pos0(2, i), pos0(3, i)
  END DO
  CLOSE (u)

  WRITE (*, '(A)') 'L3-5R Humboldt 800 m peak sag-bend curvature under mesh refinement (OrcaFlex 0.0280):'
  CALL subdivide(pos0, 2, pos)
  CALL solve_polyline_seed(pos, Lsus, k480, q480)
  CALL require(ALLOCATED(q480), '480-element solve converged')
  IF (.NOT. ALLOCATED(q480)) CALL bail()
  CALL solve_refined(q480, Lsus, .TRUE., k960, q960)
  CALL require(ALLOCATED(q960), '960-element mesh-sequenced solve converged')
  IF (.NOT. ALLOCATED(q960)) CALL bail()
  CALL solve_refined(q960, Lsus, .TRUE., k1920, q1920)
  CALL require(ALLOCATED(q1920), '1920-element mesh-sequenced polish converged')
  IF (.NOT. ALLOCATED(q1920)) CALL bail()

  WRITE (*, '(A,F6.2,A)') 'L3-5R 480 vs OrcaFlex:  ', 100.0_wp*ABS(k480 - ORCA_REF)/ORCA_REF, '%'
  WRITE (*, '(A,F6.2,A)') 'L3-5R 960 vs OrcaFlex:  ', 100.0_wp*ABS(k960 - ORCA_REF)/ORCA_REF, '%'
  WRITE (*, '(A,F6.2,A)') 'L3-5R 1920 vs OrcaFlex: ', 100.0_wp*ABS(k1920 - ORCA_REF)/ORCA_REF, '%'
  WRITE (*, '(A,ES10.3)') 'L3-5R 480 -> 960 peak move:  ', ABS(k480 - k960)/k960
  WRITE (*, '(A,ES10.3)') 'L3-5R 960 -> 1920 peak move: ', ABS(k960 - k1920)/k1920

  CALL require(ABS(k480 - ORCA_REF)/ORCA_REF < BAND, '480-element peak within the 8% OrcaFlex band')
  CALL require(ABS(k960 - ORCA_REF)/ORCA_REF < BAND, '960-element peak within the 8% OrcaFlex band')
  CALL require(ABS(k1920 - ORCA_REF)/ORCA_REF < BAND, '1920-element peak within the 8% OrcaFlex band')
  CALL require(ABS(k480 - k960)/k960 < DRIFT_GATE, 'peak flattened (480 -> 960 move < 0.5%)')
  CALL require(ABS(k960 - k1920)/k1920 < DRIFT_GATE, 'peak flattened (960 -> 1920 move < 0.5%)')

  IF (nfail > 0) THEN
    WRITE (*, '(A,I0,A)') 'FAIL: ', nfail, ' assertion(s) failed'
    ERROR STOP 1
  END IF
  WRITE (*, '(A)') 'PASS: Humboldt 800 m sag-bend curvature is mesh-converged inside the OrcaFlex band'

CONTAINS

  SUBROUTINE bail()
    WRITE (*, '(A)') 'FAIL: refinement solve did not converge'
    ERROR STOP 1
  END SUBROUTINE bail

  SUBROUTINE subdivide(p0, r, p)
    !! Insert r-1 equally spaced points on each chord of the seed polyline.
    REAL(wp), INTENT(IN) :: p0(:, :)
    INTEGER, INTENT(IN) :: r
    REAL(wp), ALLOCATABLE, INTENT(OUT) :: p(:, :)
    INTEGER :: n0, n, e, k, j
    REAL(wp) :: t
    n0 = SIZE(p0, 2)
    n = (n0 - 1)*r + 1
    ALLOCATE (p(3, n))
    k = 0
    DO e = 1, n0 - 1
      DO j = 0, r - 1
        t = REAL(j, wp)/REAL(r, wp)
        k = k + 1
        p(:, k) = (1.0_wp - t)*p0(:, e) + t*p0(:, e + 1)
      END DO
    END DO
    p(:, n) = p0(:, n0)
  END SUBROUTINE subdivide

  SUBROUTINE solve_polyline_seed(p, Ls, kmax, q_out)
    !! Seed [r, m] from a position polyline (normalized chords) and solve.
    REAL(wp), INTENT(IN) :: p(:, :)
    REAL(wp), INTENT(IN) :: Ls
    REAL(wp), INTENT(OUT) :: kmax
    REAL(wp), ALLOCATABLE, INTENT(OUT) :: q_out(:)
    INTEGER :: nn, i
    REAL(wp) :: tv(3)
    REAL(wp), ALLOCATABLE :: seed(:)
    nn = SIZE(p, 2)
    ALLOCATE (seed(6*nn))
    seed = 0.0_wp
    DO i = 1, nn
      seed(6*(i - 1) + 1:6*(i - 1) + 3) = p(:, i)
      IF (i < nn) THEN
        tv = p(:, i + 1) - p(:, i)
      ELSE
        tv = p(:, i) - p(:, i - 1)
      END IF
      tv = tv/SQRT(SUM(tv**2))
      seed(6*(i - 1) + 4:6*(i - 1) + 6) = tv
    END DO
    ! The stored 240-element profile is a converged full-load configuration.  The
    ! reconstructed tangents need equilibrium correction, but the physical loads must
    ! remain at their final values while that correction is made.
    CALL solve_seed(seed, Ls, .TRUE., kmax, q_out)
  END SUBROUTINE solve_polyline_seed

  SUBROUTINE solve_refined(qc, Ls, polish, kmax, q_out)
    !! Seed the doubled mesh from a CONVERGED coarse solution sampled through the
    !! Hermite interpolant at the element midpoints. With polish = .TRUE. the solve runs
    !! in fixed-point polish mode (single EI stage, n_buoy_steps = 1): the refined seed
    !! is already the smooth arch at full buoyancy.
    REAL(wp), INTENT(IN) :: qc(:)
    REAL(wp), INTENT(IN) :: Ls
    LOGICAL, INTENT(IN) :: polish
    REAL(wp), INTENT(OUT) :: kmax
    REAL(wp), ALLOCATABLE, INTENT(OUT) :: q_out(:)
    INTEGER :: nnc, nec, nn, e
    REAL(wp) :: lec, r1(3), r2(3), m1(3), m2(3)
    REAL(wp), ALLOCATABLE :: seed(:)
    nnc = SIZE(qc)/6
    nec = nnc - 1
    lec = Ls/REAL(nec, wp)
    nn = 2*nec + 1
    ALLOCATE (seed(6*nn))
    DO e = 1, nec
      r1 = qc(6*(e - 1) + 1:6*(e - 1) + 3); m1 = qc(6*(e - 1) + 4:6*(e - 1) + 6)
      r2 = qc(6*e + 1:6*e + 3); m2 = qc(6*e + 4:6*e + 6)
      seed(6*(2*e - 2) + 1:6*(2*e - 2) + 3) = r1
      seed(6*(2*e - 2) + 4:6*(2*e - 2) + 6) = m1
      seed(6*(2*e - 1) + 1:6*(2*e - 1) + 3) = 0.5_wp*(r1 + r2) + lec*(m1 - m2)/8.0_wp
      seed(6*(2*e - 1) + 4:6*(2*e - 1) + 6) = 1.5_wp*(r2 - r1)/lec - 0.25_wp*(m1 + m2)
    END DO
    seed(6*(nn - 1) + 1:6*(nn - 1) + 3) = qc(6*nec + 1:6*nec + 3)
    seed(6*(nn - 1) + 4:6*(nn - 1) + 6) = qc(6*nec + 4:6*nec + 6)
    CALL solve_seed(seed, Ls, polish, kmax, q_out)
  END SUBROUTINE solve_refined

  SUBROUTINE solve_seed(seed, Ls, polish, kmax, q_out)
    !! Same physical deck and solver settings as the l3_lazywave_curvature 800 m case
    !! (sections by arc, pinned ends, planar y, internal EI + buoyancy continuation);
    !! polish mode collapses the continuation to a single full-load fixed-point solve.
    REAL(wp), INTENT(IN) :: seed(:)
    REAL(wp), INTENT(IN) :: Ls
    LOGICAL, INTENT(IN) :: polish
    REAL(wp), INTENT(OUT) :: kmax
    REAL(wp), ALLOCATABLE, INTENT(OUT) :: q_out(:)
    INTEGER :: nn, ne, i, e, es, iters, nfix
    REAL(wp) :: l0e, a_mid, res, wall
    REAL(wp), ALLOCATABLE :: q(:), l0(:), EAv(:), EIv(:), w(:), curv(:)
    INTEGER, ALLOCATABLE :: fixed(:)
    CHARACTER(300) :: em
    INTEGER(8) :: t0, t1, rt
    kmax = 0.0_wp
    nn = SIZE(seed)/6
    ne = nn - 1
    l0e = Ls/REAL(ne, wp)
    ALLOCATE (q(6*nn), l0(ne), EAv(ne), EIv(ne), w(ne), curv(nn), fixed(6 + 2*nn))
    DO e = 1, ne
      l0(e) = l0e; EAv(e) = EA; EIv(e) = EI_FULL
      a_mid = REAL(e, wp)*l0e - 0.5_wp*l0e
      IF (a_mid > LTOP .AND. a_mid <= LTOP + LBUOY) THEN
        w(e) = buoy_w
      ELSE
        w(e) = bare_w
      END IF
    END DO
    nfix = 0
    DO i = 1, 3; nfix = nfix + 1; fixed(nfix) = i; END DO
    DO i = 1, 3; nfix = nfix + 1; fixed(nfix) = 6*(nn - 1) + i; END DO
    DO i = 1, nn
      nfix = nfix + 1; fixed(nfix) = 6*(i - 1) + 2
      nfix = nfix + 1; fixed(nfix) = 6*(i - 1) + 5
    END DO
    CALL SYSTEM_CLOCK(t0, rt)
    IF (polish) THEN
      CALL CD_HermiteCable_Static_Solve(l0, EAv, EIv, w, seed, fixed(1:nfix), -2000.0_wp, 0.0_wp, &
                                        1, 250, 1.0e-6_wp, 0.7_wp, q, curv, res, iters, es, em, &
                                        n_buoy_steps=1)
    ELSE
      CALL CD_HermiteCable_Static_Solve(l0, EAv, EIv, w, seed, fixed(1:nfix), -2000.0_wp, 0.0_wp, &
                                        8, 120, 1.0e-6_wp, 0.7_wp, q, curv, res, iters, es, em)
    END IF
    CALL SYSTEM_CLOCK(t1)
    wall = REAL(t1 - t0, wp)/REAL(rt, wp)
    IF (es /= CD_HCSTAT_OK) THEN
      WRITE (*, '(I5,A,A)') ne, '  FAILED: ', TRIM(em)
      RETURN
    END IF
    kmax = MAXVAL(curv)
    WRITE (*, '(A,I5,A,F6.3,A,F10.6,A,I5,A,F8.1,A)') 'L3-5R ne = ', ne, '  elem ', l0e, &
      ' m  peak ', kmax, ' /m   (', iters, ' iters, ', wall, ' s)'
    FLUSH (6)
    q_out = q
  END SUBROUTINE solve_seed

  SUBROUTINE require(cond, label)
    LOGICAL, INTENT(IN) :: cond
    CHARACTER(*), INTENT(IN) :: label
    IF (.NOT. cond) THEN
      WRITE (*, '(A,A)') 'MISMATCH: ', label
      nfail = nfail + 1
    END IF
  END SUBROUTINE require

END PROGRAM test_l3_lazywave_refinement
