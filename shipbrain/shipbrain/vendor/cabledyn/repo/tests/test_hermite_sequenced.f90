! File: tests/test_hermite_sequenced.f90
! SPDX-License-Identifier: Apache-2.0
! Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
PROGRAM test_hermite_sequenced
  !! Gate for the mesh-sequenced static entry (CD_HermiteCable_Static_Solve_Sequenced):
  !! the default fine-mesh solve architecture -- full continuation once on the coarsest
  !! mesh, cubic-Hermite prolongation + polish through a bounded nested hierarchy.
  !!
  !! Cases:
  !!   1. EQUIVALENCE on the Humboldt 800 m lazy-wave pinned span (the committed L3-5
  !!      rig, native 240 elements): the interface-preserving 3:2 hierarchy reproduces
  !!      the direct solve's peak sag-bend curvature and hang-off tension, and its
  !!      per-level iteration log records the complete deterministic cost, including
  !!      any rejected hierarchy used before a successful recovery path.
  !!   2. DETERMINISM: two identical sequenced calls return bit-identical states.
  !!   3. NET-HEAVY equivalence (no buoyancy ramp in play): a bending catenary solved
  !!      direct vs sequenced agrees the same way.
  !!   4. FIXED-VALUE ENFORCEMENT: a constraint at a node that exists only on the finest
  !!      mesh engages there and pins the CALLER's value exactly (the prolongated value
  !!      is overwritten before the polish).
  !!   5. BRANCH-PRESERVING FAILURE: an under-converged final caller mesh returns
  !!      NOCONVERGE even though intermediate meshes may use inexact seed readiness.
  !!   6. ARBITRARY MESH COUNTS: odd/prime element counts and unaligned section
  !!      interfaces use the same nested hierarchy and remain endpoint-order invariant.
  !!   7. NONUNIFORM PREFLIGHT: the reported coarse-cell limit is taken from the
  !!      hierarchy's actual groups, not the misleading global mean cell length.
  !!   8. FAIL-CLOSED: n_levels < 1, an over-coarsened hierarchy, wrong iters_by_level /
  !!      q_out sizes are rejected with CD_HCSTAT_BADINPUT before any solve runs.
  USE CableDyn_Precision, ONLY: wp
  USE CableDyn_HermiteCableStatic, ONLY: CD_HermiteCable_Static_Solve, &
                                         CD_HermiteCable_Static_Solve_Sequenced, &
                                         CD_HermiteCable_Sequence_Coarse_Max_Length, &
                                         CD_HermiteCable_Refine_Mesh, CD_HermiteCable_Prolong_Arc, &
                                         CD_HermiteCable_Trivial_Seed, &
                                         CD_HCSTAT_OK, CD_HCSTAT_BADINPUT, CD_HCSTAT_NOCONVERGE
  IMPLICIT NONE

  REAL(wp), PARAMETER :: RHOW = 1025.0_wp, GACC = 9.80665_wp, PI = 3.141592653589793_wp
  REAL(wp), PARAMETER :: EA_C = 4.69e8_wp, EI_C = 1.99e4_wp
  REAL(wp), PARAMETER :: LTOP = 372.449_wp, LBUOY = 400.0_wp
  REAL(wp), PARAMETER :: BMASS = 59.17_wp, BOD = 0.29_wp

  INTEGER :: nfail
  nfail = 0

  CALL case_lazywave_equivalence_and_determinism()
  CALL case_net_heavy_equivalence_and_pin()
  CALL case_nonuniform_split()
  CALL case_arbitrary_count_interfaces()
  CALL case_nonuniform_coarse_length_query()
  CALL case_hierarchy_failure_reports()
  CALL case_refine_mesh_constraints()
  CALL case_prolong_arc()
  CALL case_fail_closed()

  IF (nfail > 0) THEN
    WRITE (*, '(A,I0,A)') 'FAIL: ', nfail, ' assertion(s) failed'
    ERROR STOP 1
  END IF
  WRITE (*, '(A)') 'PASS: mesh-sequenced static solve (equivalence, determinism, constraints, fail-closed)'

CONTAINS

  INCLUDE 'nan_max_abs.inc'

  SUBROUTINE case_lazywave_equivalence_and_determinism()
    !! Humboldt 800 m pinned span, the committed L3-5 rig: direct vs sequenced.
    REAL(wp), ALLOCATABLE :: pos(:, :), seed(:), l0(:), EAv(:), EIv(:), w(:)
    REAL(wp), ALLOCATABLE :: qd(:), cd(:), qs(:), cs(:), qs2(:), cs2(:)
    INTEGER, ALLOCATABLE :: fixed(:)
    INTEGER :: u, ios, nn, ne, i, e, es, itd, nfix, ibl(3), ibl2(3)
    REAL(wp) :: Lsus, dum, l0e, a_mid, resd, ress, kd, ks, td, ts, buoy_w, bare_w, tv(3)
    CHARACTER(300) :: em

    bare_w = (36.7_wp - RHOW*0.25_wp*PI*0.16_wp**2)*GACC
    buoy_w = (BMASS - RHOW*0.25_wp*PI*BOD**2)*GACC

    OPEN (NEWUNIT=u, FILE='humboldt_lazywave_seed.xyz', STATUS='OLD', ACTION='READ', IOSTAT=ios)
    IF (ios /= 0) THEN
      WRITE (*, '(A)') 'FAIL: cannot open humboldt_lazywave_seed.xyz'; ERROR STOP 1
    END IF
    READ (u, *) nn, Lsus
    READ (u, *) dum, dum
    ALLOCATE (pos(3, nn))
    DO i = 1, nn
      READ (u, *) pos(1, i), pos(2, i), pos(3, i)
    END DO
    CLOSE (u)

    ne = nn - 1
    l0e = Lsus/REAL(ne, wp)
    ALLOCATE (seed(6*nn), l0(ne), EAv(ne), EIv(ne), w(ne), fixed(6 + 2*nn))
    ALLOCATE (qd(6*nn), cd(nn), qs(6*nn), cs(nn), qs2(6*nn), cs2(nn))

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
      l0(e) = l0e; EAv(e) = EA_C; EIv(e) = EI_C
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

    CALL CD_HermiteCable_Static_Solve(l0, EAv, EIv, w, seed, fixed(1:nfix), -2000.0_wp, 0.0_wp, &
                                      8, 60, 1.0e-6_wp, 0.7_wp, qd, cd, resd, itd, es, em)
    CALL require(es == CD_HCSTAT_OK, 'direct 800 m solve converged: '//TRIM(em))

    CALL CD_HermiteCable_Static_Solve_Sequenced(l0, EAv, EIv, w, seed, fixed(1:nfix), &
                                                -2000.0_wp, 0.0_wp, 8, 60, 1.0e-6_wp, 0.7_wp, &
                                                3, qs, cs, ress, ibl, es, em)
    CALL require(es == CD_HCSTAT_OK, 'sequenced 800 m solve converged: '//TRIM(em))

    kd = MAXVAL(cd); ks = MAXVAL(cs)
    td = EA_C*(SQRT(SUM(qd(4:6)**2)) - 1.0_wp)
    ts = EA_C*(SQRT(SUM(qs(4:6)**2)) - 1.0_wp)
    WRITE (*, '(A,F10.6,A,F10.6,A,ES9.2)') 'SEQ peak curvature direct = ', kd, &
      '   sequenced = ', ks, '   rel diff ', ABS(ks - kd)/kd
    WRITE (*, '(A,I5,A,3I5,A,I5)') 'SEQ iterations: direct = ', itd, &
      '   sequenced levels = ', ibl, '   total = ', SUM(ibl)
    CALL require(ABS(ks - kd)/kd < 1.0e-4_wp, 'sequenced peak curvature matches direct')
    CALL require(ABS(ts - td)/ABS(td) < 1.0e-4_wp, 'sequenced hang-off tension matches direct')
    CALL require(SUM(ibl) > 0 .AND. ALL(ibl >= 0), &
                 'sequenced hierarchy records all attempted nonlinear iterations')

    CALL CD_HermiteCable_Static_Solve_Sequenced(l0, EAv, EIv, w, seed, fixed(1:nfix), &
                                                -2000.0_wp, 0.0_wp, 8, 60, 1.0e-6_wp, 0.7_wp, &
                                                3, qs2, cs2, ress, ibl2, es, em)
    CALL require(es == CD_HCSTAT_OK, 'repeat sequenced solve converged')
    CALL require(nan_max_abs(qs2 - qs) <= 0.0_wp, 'sequenced solve is deterministic (bit-identical states)')
    CALL require(ALL(ibl2 == ibl), 'sequenced solve is deterministic (identical iteration log)')
  END SUBROUTINE case_lazywave_equivalence_and_determinism

  SUBROUTINE case_net_heavy_equivalence_and_pin()
    !! Bending catenary (net-heavy, both ends pinned, 16 elements): direct vs sequenced
    !! (4 -> 8 -> 16), plus a finest-mesh-only constraint pinned to the caller's value.
    INTEGER, PARAMETER :: NE_CAT = 16
    REAL(wp), PARAMETER :: LCAT = 100.0_wp, SPAN = 80.0_wp, WCAT = 500.0_wp
    REAL(wp) :: l0(NE_CAT), EAv(NE_CAT), EIv(NE_CAT), w(NE_CAT)
    REAL(wp) :: seed(6*(NE_CAT + 1)), qd(6*(NE_CAT + 1)), cd(NE_CAT + 1)
    REAL(wp) :: qs(6*(NE_CAT + 1)), cs(NE_CAT + 1)
    REAL(wp) :: resd, ress, sagd, sags, frac
    INTEGER :: fixed(7), i, es, itd, ibl(3), nnc
    CHARACTER(300) :: em

    nnc = NE_CAT + 1
    l0 = LCAT/REAL(NE_CAT, wp)
    EAv = 1.0e8_wp; EIv = 1.0e3_wp; w = WCAT
    ! Downward-bowed seed: the slack line (rest length 100 over an 80 m span) buckles
    ! from a perfectly straight compressed seed, so the bow selects the physical
    ! hanging branch. Depth from the parabolic slack estimate sqrt(3 L (L - S) / 8).
    seed = 0.0_wp
    DO i = 1, nnc
      frac = REAL(i - 1, wp)/REAL(NE_CAT, wp)
      seed(6*(i - 1) + 1) = SPAN*frac
      seed(6*(i - 1) + 3) = -4.0_wp*SQRT(3.0_wp*LCAT*(LCAT - SPAN)/8.0_wp)*frac*(1.0_wp - frac)
      seed(6*(i - 1) + 4) = 1.0_wp
    END DO
    ! endpoints pinned; node 2 (dropped on both coarse levels) y pinned to a nonzero value
    fixed(1:3) = [1, 2, 3]
    fixed(4:6) = [6*NE_CAT + 1, 6*NE_CAT + 2, 6*NE_CAT + 3]
    fixed(7) = 6*1 + 2                    ! node 2 r_y
    seed(fixed(7)) = 0.02_wp

    CALL CD_HermiteCable_Static_Solve(l0, EAv, EIv, w, seed, fixed, -1000.0_wp, 0.0_wp, &
                                      4, 60, 1.0e-6_wp, 0.7_wp, qd, cd, resd, itd, es, em)
    CALL require(es == CD_HCSTAT_OK, 'direct catenary solve converged: '//TRIM(em))

    CALL CD_HermiteCable_Static_Solve_Sequenced(l0, EAv, EIv, w, seed, fixed, -1000.0_wp, 0.0_wp, &
                                                4, 60, 1.0e-6_wp, 0.7_wp, 3, qs, cs, ress, ibl, es, em)
    CALL require(es == CD_HCSTAT_OK, 'sequenced catenary solve converged: '//TRIM(em))

    sagd = MINVAL(qd(3:6*nnc:6)); sags = MINVAL(qs(3:6*nnc:6))
    WRITE (*, '(A,F10.5,A,F10.5,A,3I4)') 'SEQ catenary sag direct = ', sagd, &
      '   sequenced = ', sags, '   levels ', ibl
    CALL require(ABS(sags - sagd)/ABS(sagd) < 1.0e-4_wp, 'sequenced catenary sag matches direct')
    CALL require(ABS(qs(fixed(7)) - 0.02_wp) <= 0.0_wp, 'finest-only constraint pins the caller value exactly')
    CALL require(ABS(qd(fixed(7)) - 0.02_wp) <= 0.0_wp, 'direct solve pins the same caller value')
  END SUBROUTINE case_net_heavy_equivalence_and_pin

  SUBROUTINE case_nonuniform_split()
    !! Non-uniform mesh (alternating 4 m / 8.5 m elements): every coarse element's two
    !! children have UNEQUAL rest lengths, so the prolongated node must sit at the actual
    !! split point xi = 0.32 of the parent interpolant, not its midpoint. Regression for
    !! the split-point evaluation: the sequenced solve must reproduce the direct solve on
    !! the same mesh.
    INTEGER, PARAMETER :: NE_NU = 16
    REAL(wp), PARAMETER :: SPAN = 80.0_wp, WCAT = 500.0_wp
    REAL(wp) :: l0(NE_NU), EAv(NE_NU), EIv(NE_NU), w(NE_NU)
    REAL(wp) :: seed(6*(NE_NU + 1)), qd(6*(NE_NU + 1)), cd(NE_NU + 1)
    REAL(wp) :: qs(6*(NE_NU + 1)), cs(NE_NU + 1)
    REAL(wp) :: resd, ress, sagd, sags, frac, arc, ltot
    INTEGER :: fixed(6), i, es, itd, ibl(2), nnc
    CHARACTER(300) :: em

    nnc = NE_NU + 1
    DO i = 1, NE_NU
      IF (MOD(i, 2) == 1) THEN
        l0(i) = 4.0_wp
      ELSE
        l0(i) = 8.5_wp
      END IF
    END DO
    ltot = SUM(l0)
    EAv = 1.0e8_wp; EIv = 1.0e3_wp; w = WCAT
    ! downward-bowed seed along the cumulative arc (same slack-branch selection as the
    ! uniform catenary case)
    seed = 0.0_wp
    arc = 0.0_wp
    DO i = 1, nnc
      frac = arc/ltot
      seed(6*(i - 1) + 1) = SPAN*frac
      seed(6*(i - 1) + 3) = -4.0_wp*SQRT(3.0_wp*ltot*(ltot - SPAN)/8.0_wp)*frac*(1.0_wp - frac)
      seed(6*(i - 1) + 4) = 1.0_wp
      IF (i <= NE_NU) arc = arc + l0(i)
    END DO
    fixed(1:3) = [1, 2, 3]
    fixed(4:6) = [6*NE_NU + 1, 6*NE_NU + 2, 6*NE_NU + 3]

    CALL CD_HermiteCable_Static_Solve(l0, EAv, EIv, w, seed, fixed, -1000.0_wp, 0.0_wp, &
                                      4, 60, 1.0e-6_wp, 0.7_wp, qd, cd, resd, itd, es, em)
    CALL require(es == CD_HCSTAT_OK, 'direct non-uniform catenary converged: '//TRIM(em))
    CALL CD_HermiteCable_Static_Solve_Sequenced(l0, EAv, EIv, w, seed, fixed, -1000.0_wp, 0.0_wp, &
                                                4, 60, 1.0e-6_wp, 0.7_wp, 2, qs, cs, ress, ibl, es, em)
    CALL require(es == CD_HCSTAT_OK, 'sequenced non-uniform catenary converged: '//TRIM(em))
    sagd = MINVAL(qd(3:6*nnc:6)); sags = MINVAL(qs(3:6*nnc:6))
    WRITE (*, '(A,F10.5,A,F10.5,A,2I4)') 'SEQ non-uniform sag direct = ', sagd, &
      '   sequenced = ', sags, '   levels ', ibl
    CALL require(ABS(sags - sagd)/ABS(sagd) < 1.0e-4_wp, &
                 'sequenced solve matches direct on the non-uniform (unequal-children) mesh')
  END SUBROUTINE case_nonuniform_split

  SUBROUTINE case_nonuniform_coarse_length_query()
    !! A single long cell embedded in many short cells makes the global proposed
    !! mean look safe. The hierarchy query must report the actual 30 m coarse cell
    !! so DeckDriver can refuse a bending-unresolved coarsening step.
    INTEGER, PARAMETER :: NE_QUERY = 64, TARGET_QUERY = 43, NE_SECT = 90
    REAL(wp) :: l0(NE_QUERY), EAv(NE_QUERY), EIv(NE_QUERY), w(NE_QUERY)
    REAL(wp) :: l0s(NE_SECT), EAs(NE_SECT), EIs(NE_SECT), ws(NE_SECT)
    REAL(wp) :: longest, global_mean
    INTEGER :: es, i, coarse_elements, middle_elements
    CHARACTER(300) :: em

    l0 = 1.0_wp
    l0(1) = 30.0_wp
    EAv = 1.0e8_wp
    EIv = 1.0e3_wp
    w = -100.0_wp
    global_mean = SUM(l0)/REAL(TARGET_QUERY, wp)
    CALL CD_HermiteCable_Sequence_Coarse_Max_Length(l0, EAv, EIv, w, 2, longest, es, em)
    CALL require(es == CD_HCSTAT_OK, 'nonuniform coarse-length query succeeds: '//TRIM(em))
    CALL require(ABS(longest - 30.0_wp) <= 0.0_wp, &
                 'nonuniform coarse-length query reports the actual longest group')
    CALL require(longest > 10.0_wp*global_mean, &
                 'actual coarse-cell length exposes risk hidden by the global mean')

    ! Thirty three-element material runs have a mandatory minimum of 30 groups.
    ! Independent per-run rounding would allocate only 30 of the requested 40 coarsest
    ! groups, followed by a 30 -> 60 (2:1) polish. Global integer apportionment must
    ! deliver the requested 40 -> 60 -> 90 hierarchy exactly.
    l0s = 1.0_wp
    EIs = 1.0e3_wp
    ws = -100.0_wp
    DO i = 1, NE_SECT
      EAs(i) = MERGE(1.0e8_wp, 2.0e8_wp, MOD((i - 1)/3, 2) == 0)
    END DO
    CALL CD_HermiteCable_Sequence_Coarse_Max_Length(l0s, EAs, EIs, ws, 3, longest, es, em, &
                                                    coarse_elements=coarse_elements)
    CALL require(es == CD_HCSTAT_OK .AND. coarse_elements == 40, &
                 'many-section hierarchy globally apportions 40 coarsest groups')
    CALL CD_HermiteCable_Sequence_Coarse_Max_Length(l0s, EAs, EIs, ws, 2, longest, es, em, &
                                                    coarse_elements=middle_elements)
    CALL require(es == CD_HCSTAT_OK .AND. middle_elements == 60, &
                 'many-section hierarchy globally apportions 60 middle groups')
  END SUBROUTINE case_nonuniform_coarse_length_query

  SUBROUTINE case_arbitrary_count_interfaces()
    !! A prime 131-element mesh must be accepted by n_levels=3 although 131 is not
    !! divisible by four. Its two section boundaries (after elements
    !! 47 and 89) are deliberately unaligned with the stride-4 hierarchy. They
    !! must survive coarsening, and reversing the endpoint/element order must
    !! reproduce the same physical equilibrium node-for-node.
    INTEGER, PARAMETER :: NEP = 131, NNP = NEP + 1
    REAL(wp), PARAMETER :: LTOT = 110.0_wp, SPAN = 92.0_wp
    REAL(wp) :: l0(NEP), EAv(NEP), EIv(NEP), w(NEP), seed(6*NNP)
    REAL(wp) :: qd(6*NNP), cd(NNP), qs(6*NNP), cs(NNP)
    REAL(wp) :: l0r(NEP), EAr(NEP), EIr(NEP), wr(NEP), seedr(6*NNP)
    REAL(wp) :: qsr(6*NNP), csr(NNP), resd, ress, resr, scale, pos_err, tan_err
    INTEGER :: fixed(6 + 2*NNP), i, j, nfix, es, itd, ibl(3), iblr(3)
    CHARACTER(300) :: em

    DO i = 1, NEP
      l0(i) = 0.7_wp + 0.075_wp*REAL(MOD(i - 1, 5), wp)
    END DO
    scale = LTOT/SUM(l0)
    l0 = scale*l0
    EAv(1:47) = 8.0e7_wp; EIv(1:47) = 2.0e3_wp; w(1:47) = 250.0_wp
    EAv(48:89) = 1.6e8_wp; EIv(48:89) = 2.0e4_wp; w(48:89) = 120.0_wp
    EAv(90:NEP) = 6.0e7_wp; EIv(90:NEP) = 5.0e3_wp; w(90:NEP) = 400.0_wp
    CALL CD_HermiteCable_Trivial_Seed([0.0_wp, 0.0_wp, 0.0_wp], &
                                      [SPAN, 0.0_wp, 0.0_wp], l0, -1000.0_wp, seed, es, em)
    CALL require(es == CD_HCSTAT_OK, 'prime/interface seed built: '//TRIM(em))
    IF (es /= CD_HCSTAT_OK) RETURN
    nfix = 0
    DO i = 1, 3; nfix = nfix + 1; fixed(nfix) = i; END DO
    DO i = 1, 3; nfix = nfix + 1; fixed(nfix) = 6*NEP + i; END DO
    DO i = 1, NNP
      nfix = nfix + 1; fixed(nfix) = 6*(i - 1) + 2
      nfix = nfix + 1; fixed(nfix) = 6*(i - 1) + 5
    END DO

    CALL CD_HermiteCable_Static_Solve(l0, EAv, EIv, w, seed, fixed(1:nfix), -1000.0_wp, 0.0_wp, &
                                      8, 120, 1.0e-7_wp, 0.7_wp, qd, cd, resd, itd, es, em)
    CALL require(es == CD_HCSTAT_OK, 'prime/interface direct solve converged: '//TRIM(em))
    CALL CD_HermiteCable_Static_Solve_Sequenced(l0, EAv, EIv, w, seed, fixed(1:nfix), &
                                                -1000.0_wp, 0.0_wp, 8, 120, 1.0e-7_wp, 0.7_wp, &
                                                3, qs, cs, ress, ibl, es, em)
    CALL require(es == CD_HCSTAT_OK, 'prime/interface sequenced solve converged: '//TRIM(em))
    IF (es /= CD_HCSTAT_OK) RETURN
    CALL require(nan_max_abs(qs(1:6*NNP:6) - qd(1:6*NNP:6))/SPAN < 1.0e-5_wp, &
                 'prime/interface sequence matches direct x geometry')
    CALL require(nan_max_abs(qs(3:6*NNP:6) - qd(3:6*NNP:6))/LTOT < 1.0e-5_wp, &
                 'prime/interface sequence matches direct z geometry')

    DO i = 1, NEP
      l0r(i) = l0(NEP - i + 1); EAr(i) = EAv(NEP - i + 1)
      EIr(i) = EIv(NEP - i + 1); wr(i) = w(NEP - i + 1)
    END DO
    CALL CD_HermiteCable_Trivial_Seed([SPAN, 0.0_wp, 0.0_wp], &
                                      [0.0_wp, 0.0_wp, 0.0_wp], l0r, -1000.0_wp, seedr, es, em)
    CALL require(es == CD_HCSTAT_OK, 'prime/interface reversed seed built')
    CALL CD_HermiteCable_Static_Solve_Sequenced(l0r, EAr, EIr, wr, seedr, fixed(1:nfix), &
                                                -1000.0_wp, 0.0_wp, 8, 120, 1.0e-7_wp, 0.7_wp, &
                                                3, qsr, csr, resr, iblr, es, em)
    CALL require(es == CD_HCSTAT_OK, 'prime/interface reversed solve converged: '//TRIM(em))
    IF (es /= CD_HCSTAT_OK) RETURN
    pos_err = 0.0_wp; tan_err = 0.0_wp
    DO i = 1, NNP
      j = NNP - i + 1
      pos_err = MAX(pos_err, nan_max_abs(qs(6*(i - 1) + 1:6*(i - 1) + 3) - &
                                         qsr(6*(j - 1) + 1:6*(j - 1) + 3)))
      tan_err = MAX(tan_err, nan_max_abs(qs(6*(i - 1) + 4:6*(i - 1) + 6) + &
                                         qsr(6*(j - 1) + 4:6*(j - 1) + 6)))
    END DO
    CALL require(pos_err/LTOT < 1.0e-5_wp, 'prime/interface endpoint reversal preserves positions')
    CALL require(tan_err < 1.0e-5_wp, 'prime/interface endpoint reversal negates tangents')
  END SUBROUTINE case_arbitrary_count_interfaces

  SUBROUTINE case_hierarchy_failure_reports()
    !! Start from an exactly converged coarse equilibrium, prolongate it once, and
    !! deliberately provide only one Newton iteration per attempted mesh. The public
    !! wrapper must exhaust its bounded primary/direct paths, report their work, and fail
    !! closed rather than applying the intermediate seed-readiness rule to the caller mesh.
    INTEGER, PARAMETER :: NEC = 8, NNC = NEC + 1
    REAL(wp), PARAMETER :: LTOT = 100.0_wp, SPAN = 80.0_wp
    REAL(wp) :: l0c(NEC), EAc(NEC), EIc(NEC), wc(NEC), seedc(6*NNC)
    REAL(wp) :: qc(6*NNC), curvc(NNC), frac, resc, resf
    REAL(wp), ALLOCATABLE :: l0f(:), seedf(:), EAf(:), EIf(:), wf(:), qf(:), curvf(:)
    INTEGER, ALLOCATABLE :: fixedc(:), fixedf(:)
    INTEGER :: nfix, i, es, itsc, ibl(2)
    CHARACTER(300) :: em

    l0c = LTOT/REAL(NEC, wp)
    EAc = 1.0e8_wp; EIc = 1.0e3_wp; wc = 500.0_wp
    seedc = 0.0_wp
    DO i = 1, NNC
      frac = REAL(i - 1, wp)/REAL(NEC, wp)
      seedc(6*(i - 1) + 1) = SPAN*frac
      seedc(6*(i - 1) + 3) = -4.0_wp*SQRT(3.0_wp*LTOT*(LTOT - SPAN)/8.0_wp)*frac*(1.0_wp - frac)
      seedc(6*(i - 1) + 4) = 1.0_wp
    END DO
    ALLOCATE (fixedc(6 + 2*NNC))
    nfix = 6
    fixedc(1:3) = [1, 2, 3]
    fixedc(4:6) = [6*NEC + 1, 6*NEC + 2, 6*NEC + 3]
    DO i = 1, NNC
      nfix = nfix + 1; fixedc(nfix) = 6*(i - 1) + 2
      nfix = nfix + 1; fixedc(nfix) = 6*(i - 1) + 5
    END DO

    CALL CD_HermiteCable_Static_Solve(l0c, EAc, EIc, wc, seedc, fixedc, -1000.0_wp, 0.0_wp, &
                                      1, 120, 1.0e-10_wp, 0.7_wp, qc, curvc, resc, itsc, es, em)
    CALL require(es == CD_HCSTAT_OK, 'branch failure: coarse reference converged')
    IF (es /= CD_HCSTAT_OK) RETURN
    CALL CD_HermiteCable_Refine_Mesh(l0c, qc, fixedc, 2, l0f, seedf, fixedf, es, em, &
                                     inherit_dofs=[2, 5])
    CALL require(es == CD_HCSTAT_OK, 'branch failure: coarse state prolonged')
    IF (es /= CD_HCSTAT_OK) RETURN
    ALLOCATE (EAf(SIZE(l0f)), EIf(SIZE(l0f)), wf(SIZE(l0f)), &
              qf(6*(SIZE(l0f) + 1)), curvf(SIZE(l0f) + 1))
    EAf = EAc(1); EIf = EIc(1); wf = wc(1)

    CALL CD_HermiteCable_Static_Solve_Sequenced(l0f, EAf, EIf, wf, seedf, fixedf, &
                                                -1000.0_wp, 0.0_wp, 1, 1, 1.0e-10_wp, 0.7_wp, &
                                                2, qf, curvf, resf, ibl, es, em)
    CALL require(es == CD_HCSTAT_NOCONVERGE, 'branch failure: failed fine polish reports NOCONVERGE')
    CALL require(SUM(ibl) >= 2, &
                 'branch failure: attempted hierarchy/direct work is visible in iteration accounting')
    CALL require(INDEX(em, '3:2 exact-interface') > 0 .AND. &
                 INDEX(em, 'direct fallback') > 0, &
                 'branch failure: diagnostic names the exhausted deterministic paths')
  END SUBROUTINE case_hierarchy_failure_reports

  SUBROUTINE case_refine_mesh_constraints()
    !! Adaptive refinement primitive: cubic-Hermite prolongation plus conservative
    !! constraint rebuild. Endpoint pins stay endpoints; planar constraints present on both
    !! neighbouring parent nodes are inherited by inserted nodes.
    REAL(wp) :: l0(2), q(18), x
    REAL(wp), ALLOCATABLE :: l0r(:), qr(:)
    INTEGER, ALLOCATABLE :: fxr(:)
    INTEGER :: fixed(12), fixed_single(6), i, es
    CHARACTER(300) :: em

    l0 = 1.0_wp
    q = 0.0_wp
    DO i = 1, 3
      q(6*(i - 1) + 1) = REAL(i - 1, wp)
      q(6*(i - 1) + 4) = 1.0_wp
    END DO
    ! endpoint positions, plus planar y / m_y at every parent node
    fixed = [1, 2, 3, 13, 14, 15, 2, 5, 8, 11, 14, 17]

    CALL CD_HermiteCable_Refine_Mesh(l0, q, fixed, 2, l0r, qr, fxr, es, em, inherit_dofs=[2, 5])
    CALL require(es == CD_HCSTAT_OK, 'refine mesh accepted a valid factor-2 request: '//TRIM(em))
    CALL require(SIZE(l0r) == 4 .AND. SIZE(qr) == 30, 'refine mesh doubled element and node counts')
    CALL require(nan_max_abs(l0r - 0.5_wp) <= 0.0_wp, 'refine mesh split lengths equally')
    DO i = 1, 5
      x = 0.5_wp*REAL(i - 1, wp)
      CALL require(ABS(qr(6*(i - 1) + 1) - x) < 1.0e-12_wp, 'refine mesh position interpolation')
      CALL require(ABS(qr(6*(i - 1) + 4) - 1.0_wp) < 1.0e-12_wp, 'refine mesh tangent interpolation')
      CALL require(has_fixed(fxr, 6*(i - 1) + 2), 'refine mesh keeps/inherits planar y constraints')
      CALL require(has_fixed(fxr, 6*(i - 1) + 5), 'refine mesh keeps/inherits planar my constraints')
    END DO
    CALL require(has_fixed(fxr, 1) .AND. has_fixed(fxr, 3), 'refine mesh keeps first endpoint pin')
    CALL require(has_fixed(fxr, 25) .AND. has_fixed(fxr, 27), 'refine mesh keeps last endpoint pin')
    CALL require(.NOT. has_fixed(fxr, 7) .AND. .NOT. has_fixed(fxr, 9), &
                 'refine mesh does not invent interior endpoint-style pins')

    fixed_single = [1, 2, 3, 7, 8, 9]
    CALL CD_HermiteCable_Refine_Mesh(l0(1:1), q(1:12), fixed_single, 2, l0r, qr, fxr, es, em)
    CALL require(es == CD_HCSTAT_OK, 'refine mesh accepts fixed-fixed single element')
    CALL require(.NOT. has_fixed(fxr, 7) .AND. .NOT. has_fixed(fxr, 8) .AND. .NOT. has_fixed(fxr, 9), &
                 'refine mesh does not infer endpoint pins onto inserted midpoint')

    CALL CD_HermiteCable_Refine_Mesh(l0, q, fixed, 3, l0r, qr, fxr, es, em)
    CALL require(es == CD_HCSTAT_BADINPUT, 'refine mesh rejects non-power-of-two scale')
    CALL CD_HermiteCable_Refine_Mesh(l0, q, fixed, 2, l0r, qr, fxr, es, em, inherit_dofs=[0])
    CALL require(es == CD_HCSTAT_BADINPUT, 'refine mesh rejects invalid inherit_dofs slot')
    CALL CD_HermiteCable_Refine_Mesh(l0, q(1:12), fixed, 2, l0r, qr, fxr, es, em)
    CALL require(es == CD_HCSTAT_BADINPUT, 'refine mesh rejects wrong q length')
    fixed(1) = 19
    CALL CD_HermiteCable_Refine_Mesh(l0, q, fixed, 2, l0r, qr, fxr, es, em)
    CALL require(es == CD_HCSTAT_BADINPUT, 'refine mesh rejects out-of-range fixed DOF')
  END SUBROUTINE case_refine_mesh_constraints

  SUBROUTINE case_prolong_arc()
    !! Arc-length prolongation between non-nested meshes: a cubic centreline r(s) is exact on
    !! any cubic-Hermite mesh, so carrying it from a 3-element to a 5-element mesh of other
    !! lengths reproduces r and dr/ds at every target node; meshes of different total
    !! length are refused.
    REAL(wp) :: l0c(3), l0f(5), qc(24), qf(36), s, r(3), t(3)
    INTEGER :: i, es
    CHARACTER(300) :: em
    l0c = [1.0_wp, 2.5_wp, 1.5_wp]
    l0f = [0.7_wp, 0.9_wp, 1.3_wp, 1.1_wp, 1.0_wp]
    DO i = 1, 4
      s = SUM(l0c(1:i - 1))
      CALL cubic(s, r, t)
      qc(6*(i - 1) + 1:6*i) = [r, t]
    END DO
    CALL CD_HermiteCable_Prolong_Arc(l0c, qc, l0f, qf, es, em)
    CALL require(es == CD_HCSTAT_OK, 'prolong arc accepts non-nested meshes: '//TRIM(em))
    DO i = 1, 6
      s = SUM(l0f(1:i - 1))
      CALL cubic(s, r, t)
      CALL require(nan_max_abs(qf(6*(i - 1) + 1:6*(i - 1) + 3) - r) < 1.0e-12_wp, 'prolong arc position')
      CALL require(nan_max_abs(qf(6*(i - 1) + 4:6*i) - t) < 1.0e-12_wp, 'prolong arc tangent')
    END DO
    l0f(5) = 1.5_wp
    CALL CD_HermiteCable_Prolong_Arc(l0c, qc, l0f, qf, es, em)
    CALL require(es == CD_HCSTAT_BADINPUT, 'prolong arc refuses meshes of different length')
  END SUBROUTINE case_prolong_arc

  PURE SUBROUTINE cubic(s, r, t)
    REAL(wp), INTENT(IN) :: s
    REAL(wp), INTENT(OUT) :: r(3), t(3)
    r = [s, 0.1_wp*s*s, 0.02_wp*s*s*s - 0.1_wp*s]
    t = [1.0_wp, 0.2_wp*s, 0.06_wp*s*s - 0.1_wp]
  END SUBROUTINE cubic

  SUBROUTINE case_fail_closed()
    !! Sequencing-specific validation rejects before any solve runs.
    USE, INTRINSIC :: IEEE_ARITHMETIC, ONLY: IEEE_VALUE, IEEE_QUIET_NAN
    INTEGER, PARAMETER :: NE_FC = 3      ! stride 4 would collapse 3 elements to one
    REAL(wp) :: l0(NE_FC), EAv(NE_FC), EIv(NE_FC), w(NE_FC)
    REAL(wp) :: seed(6*(NE_FC + 1)), q(6*(NE_FC + 1)), curv(NE_FC + 1), qbad(6*NE_FC)
    REAL(wp) :: res, frac, max_length, diameter(NE_FC)
    INTEGER :: fixed(6), ibl3(3), ibl2(2), i, es
    CHARACTER(300) :: em

    l0 = 10.0_wp; EAv = 1.0e8_wp; EIv = 1.0e3_wp; w = 500.0_wp
    seed = 0.0_wp
    DO i = 1, NE_FC + 1
      frac = REAL(i - 1, wp)/REAL(NE_FC, wp)
      seed(6*(i - 1) + 1) = 55.0_wp*frac
      seed(6*(i - 1) + 4) = 1.0_wp
    END DO
    fixed(1:3) = [1, 2, 3]
    fixed(4:6) = [6*NE_FC + 1, 6*NE_FC + 2, 6*NE_FC + 3]

    CALL CD_HermiteCable_Static_Solve_Sequenced(l0, EAv, EIv, w, seed, fixed, -1000.0_wp, 0.0_wp, &
                                                4, 60, 1.0e-6_wp, 0.7_wp, 0, q, curv, res, ibl3, es, em)
    CALL require(es == CD_HCSTAT_BADINPUT, 'n_levels = 0 rejected')

    CALL CD_HermiteCable_Static_Solve_Sequenced(l0, EAv, EIv, w, seed, fixed, -1000.0_wp, 0.0_wp, &
                                                4, 60, 1.0e-6_wp, 0.7_wp, 3, q, curv, res, ibl3, es, em)
    CALL require(es == CD_HCSTAT_BADINPUT, 'hierarchy leaving fewer than two coarse elements rejected')

    CALL CD_HermiteCable_Static_Solve_Sequenced(l0, EAv, EIv, w, seed, fixed, -1000.0_wp, 0.0_wp, &
                                                4, 60, 1.0e-6_wp, 0.7_wp, 3, q, curv, res, ibl2, es, em)
    CALL require(es == CD_HCSTAT_BADINPUT, 'wrong iters_by_level size rejected')

    CALL CD_HermiteCable_Static_Solve_Sequenced(l0, EAv, EIv, w, seed, fixed, -1000.0_wp, 0.0_wp, &
                                                4, 60, 1.0e-6_wp, 0.7_wp, 2, qbad, curv, res, ibl2, es, em)
    CALL require(es == CD_HCSTAT_BADINPUT, 'wrong q_out size rejected')
    ! property arrays shorter than l0 must be rejected BEFORE the coarsening indexes them
    CALL CD_HermiteCable_Static_Solve_Sequenced(l0, EAv(1:NE_FC - 1), EIv, w, seed, fixed, &
                                                -1000.0_wp, 0.0_wp, 4, 60, 1.0e-6_wp, 0.7_wp, &
                                                2, q, curv, res, ibl2, es, em)
    CALL require(es == CD_HCSTAT_BADINPUT, 'short property array rejected before coarsening')
    CALL CD_HermiteCable_Sequence_Coarse_Max_Length(l0, EAv, EIv, w, 0, max_length, es, em)
    CALL require(es == CD_HCSTAT_BADINPUT, 'coarse-length query rejects n_levels = 0')
    CALL CD_HermiteCable_Sequence_Coarse_Max_Length(l0, EAv(1:NE_FC - 1), EIv, w, 1, &
                                                    max_length, es, em)
    CALL require(es == CD_HCSTAT_BADINPUT, 'coarse-length query rejects mismatched properties')
    diameter = 0.1_wp
    diameter(2) = -0.1_wp
    CALL CD_HermiteCable_Sequence_Coarse_Max_Length(l0, EAv, EIv, w, 1, max_length, es, em, diameter)
    CALL require(es == CD_HCSTAT_BADINPUT, 'coarse-length query rejects invalid contact diameter')
    ! invalid VALUES must be rejected before the coarsening arithmetic consumes them: a
    ! negative length whose pair-sum stays positive would survive the per-level check
    BLOCK
      REAL(wp) :: l0bad(NE_FC), wbad(NE_FC)
      l0bad = l0; l0bad(1) = -1.0_wp; l0bad(2) = 21.0_wp   ! pair-sum 20 > 0
      CALL CD_HermiteCable_Static_Solve_Sequenced(l0bad, EAv, EIv, w, seed, fixed, &
                                                  -1000.0_wp, 0.0_wp, 4, 60, 1.0e-6_wp, 0.7_wp, &
                                                  2, q, curv, res, ibl2, es, em)
      CALL require(es == CD_HCSTAT_BADINPUT, 'negative element length rejected before coarsening')
      wbad = w; wbad(3) = IEEE_VALUE(1.0_wp, IEEE_QUIET_NAN)
      CALL CD_HermiteCable_Static_Solve_Sequenced(l0, EAv, EIv, wbad, seed, fixed, &
                                                  -1000.0_wp, 0.0_wp, 4, 60, 1.0e-6_wp, 0.7_wp, &
                                                  2, q, curv, res, ibl2, es, em)
      CALL require(es == CD_HCSTAT_BADINPUT, 'non-finite weight rejected before coarsening')
    END BLOCK
  END SUBROUTINE case_fail_closed

  LOGICAL FUNCTION has_fixed(fixed, dof)
    INTEGER, INTENT(IN) :: fixed(:), dof
    has_fixed = ANY(fixed == dof)
  END FUNCTION has_fixed

  SUBROUTINE require(cond, label)
    LOGICAL, INTENT(IN) :: cond
    CHARACTER(*), INTENT(IN) :: label
    IF (.NOT. cond) THEN
      WRITE (*, '(A,A)') 'MISMATCH: ', label
      nfail = nfail + 1
    END IF
  END SUBROUTINE require

END PROGRAM test_hermite_sequenced
