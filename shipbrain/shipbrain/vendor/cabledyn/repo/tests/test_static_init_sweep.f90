! File: tests/test_static_init_sweep.f90
! SPDX-License-Identifier: Apache-2.0
! Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
PROGRAM test_static_init_sweep
  !! STATIC-INITIALIZATION STRESS SWEEP: release-hardness gate for the mesh-sequenced
  !! static entry (CD_HermiteCable_Static_Solve_Sequenced) -- the production initialization
  !! path -- across the full parameter space a user can throw at it, from TRIVIAL seeds.
  !!
  !! The committed lazy-wave gates certify specific reference cases (Lozon 80/200/800 m);
  !! a green gate set certifies only the cases IN the set. This gate is the initialization
  !! MATRIX: every case is built parametrically (no committed seed files, no shooter seeds)
  !! and solved with the production settings (n_cont = 8, max_iter = 60, tol = 1e-6,
  !! damping = 0.7, n_levels = 4), exactly the "robust automatic statics from a trivial
  !! seed" claim.
  !!
  !! THE WELL-POSEDNESS LAW this sweep discovered and now encodes: with end B anchored
  !! on a FRICTIONLESS bed, a smooth planar equilibrium exists only while the rest
  !! length stays below the L-shape bound L < h_a + x_ah (vertical drop + full ground
  !! run). Beyond it the surplus length has nowhere to go -- it must wad/fold somewhere
  !! on the bed, so folded shapes ARE the physics, not a solver defect. The slack axis
  !! therefore runs up to 0.97x the bound (the hardest WELL-POSED cases), and a separate
  !! family (g) crosses the bound deliberately with a weaker promise: no silent garbage
  !! (a clean error, or a finite bounded-curvature wad -- never NaN, never curvature
  !! orders beyond the contact scale).
  !!
  !! Axes (~120 deterministic cases):
  !!   depth d          50 / 100 / 200 / 400 / 800 m           (seabed at z = -d)
  !!   slackness sigma  L_total/chord in {1.03, 1.10, 1.25, 0.97 x L-shape bound}
  !!   buoyancy ratio B buoyant-section net lift / bare weight in {0, 0.8, 1.5, 2.5}
  !!                    (B = 0 => a plain all-bare catenary; touchdown length follows
  !!                    from sigma and B rather than being prescribed)
  !!   EA               5e7 / 4.69e8 / 2e9 N,  EI  5e2 / 1.99e4 / 2e5 N m^2
  !!   seabed kn        1e4 / 1e5 / 3e6 N/m^2
  !!   span ratio chi   anchor offset x_a = chi*d in {0.6, 1.0, 1.7} (endpoint slope)
  !!   buoyant fraction f_b in {0.29, 0.40} of total length starting at arc 0.28 L
  !! plus hand-picked stress corners combining the extremes and the beyond-bound
  !! family (g).
  !!
  !! Trivial seed: CD_HermiteCable_Trivial_Seed -- the LIBRARY builder taking nothing but
  !! endpoints + rest lengths + seabed (no analytic catenary, no committed seed files, no
  !! per-case tuning). Its isometry contract is load-bearing: a seed whose arc is shorter
  !! than L_total (a bed-clamped bowed chord, for example) starts from an EA-amplified
  !! compressive state that can buckle into folded local equilibria or Newton stalls.
  !! Seeding is part of the initialization problem, so
  !! the builder is part of the library and this gate certifies builder + solver together.
  !!
  !! Acceptance per case (fail-closed, failing parameters printed for reproduction):
  !!   (1) solver returns OK;
  !!   (2) all states finite;
  !!   (3) KINK DETECTOR: max nodal turn-angle-per-element curv*l0_local <= 0.7 rad.
  !!       A resolved smooth equilibrium sits well below (the mesh is sized l0 ~ L/64
  !!       .. 5.5 m so physical arches give curv*l0 ~ 0.15); a folded/kinked branch
  !!       concentrates an O(pi) turn at one node, curv*l0 ~ 2-3. This is the measurable
  !!       version of "reached the smooth branch, not a kinked local equilibrium".
  !!   (4) penetration consistent with the penalty: min z >= -d - (10 |w|_max / kn + 1 mm).
  !! An expected-fail list records the known limitations of this kernel from the trivial
  !! seed (four low-EI lazy waves; the deck route solves them, see the list below); an
  !! XFAIL case that PASSES is counted and reported, so a fix is seen, and a case off the
  !! list that fails fails the gate.
  USE, INTRINSIC :: IEEE_ARITHMETIC, ONLY: IEEE_IS_FINITE
  USE CableDyn_Precision, ONLY: wp
  USE CableDyn_HermiteCableStatic, ONLY: CD_HermiteCable_Static_Solve_Sequenced, &
                                         CD_HermiteCable_Trivial_Seed, CD_HCSTAT_OK
  IMPLICIT NONE

  ! production solve settings (mirror the committed lazy-wave gates)
  INTEGER, PARAMETER :: N_CONT = 8, MAX_ITER = 60, N_LEVELS = 4
  REAL(wp), PARAMETER :: TOL = 1.0e-6_wp, DAMPING = 0.7_wp
  REAL(wp), PARAMETER :: KINK_GATE = 0.7_wp     ! rad of turn per element (see header)
  REAL(wp), PARAMETER :: WAD_KL = 5.0_wp        ! family g: a physical bed-wad hairpins at
  !                                               ~pi per element (measured 2.8-3.7); a
  !                                               numerical cusp sits orders beyond
  !                                               (measured 1e6-1e8)
  REAL(wp), PARAMETER :: BARE_W = 158.0_wp      ! N/m net submerged weight of the bare cable
  REAL(wp), PARAMETER :: F1 = 0.28_wp           ! arc fraction where the buoyant section starts
  ! base point (the Humboldt-class cable) the one-factor axes vary around
  REAL(wp), PARAMETER :: EA0 = 4.69e8_wp, EI0 = 1.99e4_wp, KN0 = 1.0e5_wp
  REAL(wp), PARAMETER :: CHI0 = 1.0_wp, FB0 = 0.29_wp

  INTEGER, PARAMETER :: MAXC = 200
  REAL(wp) :: p_d(MAXC), p_sig(MAXC), p_B(MAXC), p_EA(MAXC), p_EI(MAXC)
  REAL(wp) :: p_kn(MAXC), p_chi(MAXC), p_fb(MAXC)
  CHARACTER(1) :: p_fam(MAXC)
  LOGICAL :: p_xf(MAXC)
  INTEGER :: ncase, i, j, k, m, n_pass, n_fail, n_xfail, n_xpass, only_case, ios_arg
  LOGICAL :: ok
  CHARACTER(32) :: arg
  REAL(wp) :: dg(5), sg(4), bg(4), eag(2), eig(2), kng(2), chig(2)

  ncase = 0
  n_pass = 0; n_fail = 0; n_xfail = 0; n_xpass = 0

  ! ---- (a) depth x slackness x buoyancy grid at the base cable: 5*4*4 = 80 ----
  ! (sigma <= 0 is the near-bound sentinel: add_case resolves it to 0.97x the L-shape
  ! bound for the case's depth/span -- the hardest well-posed slackness)
  dg = [50.0_wp, 100.0_wp, 200.0_wp, 400.0_wp, 800.0_wp]
  sg = [1.03_wp, 1.10_wp, 1.25_wp, -1.0_wp]
  bg = [0.0_wp, 0.8_wp, 1.5_wp, 2.5_wp]
  DO i = 1, 5
    DO j = 1, 4
      DO k = 1, 4
        CALL add_case('a', dg(i), sg(j), bg(k), EA0, EI0, KN0, CHI0, FB0)
      END DO
    END DO
  END DO

  ! ---- (b) stiffness corners EA x EI at 2 depths (sigma 1.25, B 1.5): 2*2*2 + 2*2 = 12 ----
  eag = [5.0e7_wp, 2.0e9_wp]
  eig = [5.0e2_wp, 2.0e5_wp]
  DO i = 1, 2
    DO j = 1, 2
      DO k = 1, 2
        CALL add_case('b', MERGE(100.0_wp, 800.0_wp, i == 1), 1.25_wp, 1.5_wp, &
                      eag(j), eig(k), KN0, CHI0, FB0)
      END DO
    END DO
    DO k = 1, 2   ! EI extremes at base EA
      CALL add_case('b', MERGE(100.0_wp, 800.0_wp, i == 1), 1.25_wp, 1.5_wp, &
                    EA0, eig(k), KN0, CHI0, FB0)
    END DO
  END DO

  ! ---- (c) seabed stiffness extremes x slackness at 2 depths (B 1.5): 2*2*2 = 8 ----
  kng = [1.0e4_wp, 3.0e6_wp]
  DO i = 1, 2
    DO j = 1, 2
      DO k = 1, 2
        CALL add_case('c', MERGE(100.0_wp, 800.0_wp, i == 1), MERGE(1.25_wp, -1.0_wp, j == 1), &
                      1.5_wp, EA0, EI0, kng(k), CHI0, FB0)
      END DO
    END DO
  END DO

  ! ---- (d) span ratio (endpoint slope) x slackness at 2 depths (B 1.5): 2*2*2 = 8 ----
  chig = [0.6_wp, 1.7_wp]
  DO i = 1, 2
    DO j = 1, 2
      DO k = 1, 2
        CALL add_case('d', MERGE(100.0_wp, 800.0_wp, i == 1), MERGE(1.10_wp, -1.0_wp, j == 1), &
                      1.5_wp, EA0, EI0, KN0, chig(k), FB0)
      END DO
    END DO
  END DO

  ! ---- (e) large buoyant fraction at 2 depths x 2 buoyancy ratios (sigma 1.25): 4 ----
  DO i = 1, 2
    DO k = 1, 2
      CALL add_case('e', MERGE(100.0_wp, 800.0_wp, i == 1), 1.25_wp, &
                    MERGE(0.8_wp, 2.5_wp, k == 1), EA0, EI0, KN0, CHI0, 0.40_wp)
    END DO
  END DO

  ! ---- (f) stress corners (extremes combined): 6 ----
  CALL add_case('f', 50.0_wp, -1.0_wp, 2.5_wp, EA0, 5.0e2_wp, KN0, CHI0, FB0)     ! floppy + very buoyant + shallow
  CALL add_case('f', 800.0_wp, 1.03_wp, 2.5_wp, EA0, 2.0e5_wp, KN0, CHI0, FB0)    ! near-taut with strong arch demand
  ! hard bed + floppy + long ground run:
  CALL add_case('f', 800.0_wp, -1.0_wp, 2.5_wp, EA0, 5.0e2_wp, 3.0e6_wp, CHI0, FB0)
  CALL add_case('f', 50.0_wp, 1.03_wp, 0.0_wp, 2.0e9_wp, 2.0e5_wp, KN0, 1.7_wp, FB0) ! taut stiff shallow-angle
  CALL add_case('f', 100.0_wp, -1.0_wp, 0.0_wp, EA0, EI0, 1.0e4_wp, 0.6_wp, FB0)  ! steep heavy catenary, soft bed
  CALL add_case('f', 200.0_wp, 1.25_wp, 2.5_wp, EA0, 5.0e2_wp, KN0, CHI0, 0.40_wp) ! big buoyant fraction, floppy

  ! ---- (g) BEYOND the L-shape bound (sigma = 1.06x bound, sentinel -2): the ill-posed
  ! class where surplus length must wad on the frictionless bed. Weaker promise gated:
  ! a clean error, or a finite wad with curvature bounded by the contact scale --
  ! never NaN, never a silent numerical cusp. 2 depths x {catenary, lazy-wave}: 4 ----
  DO i = 1, 2
    CALL add_case('g', MERGE(50.0_wp, 400.0_wp, i == 1), -2.0_wp, 0.0_wp, EA0, EI0, KN0, CHI0, FB0)
    CALL add_case('g', MERGE(50.0_wp, 400.0_wp, i == 1), -2.0_wp, 1.5_wp, EA0, EI0, KN0, CHI0, FB0)
  END DO

  ! ---- KNOWN-FAIL SET (measured on the full matrix sweep with every OpenBLAS kernel;
  ! parameter-matched fail-closed: a matrix edit that orphans an entry is rejected. A solver
  ! improvement that flips one to PASS is reported without failing the suite. These four
  ! low-EI lazy waves reach, from the trivial seed on this kernel alone, a residual-converged
  ! kinked state (a Z of a few elements in mid-water) that the production h*kappa safety gate
  ! rejects, so none can silently enter dynamics. A deck never takes this combination for a
  ! line with a buoyant section: the deck route seeds it as a lazy wave, starts from the
  ! EI = 0 catenary, and refines a kinked state locally. That route solves all four, and the
  ! formerly listed 800 m EA = 5e7 N case, on both cable_statics routes, to within 2.4e-4 of
  ! an independent EI = 0 catenary where the arch stays submerged: cable_statics_matrix gates
  ! them (entries SIS_*).
  CALL mark_xfail('b', 800.0_wp, 1.25_wp, 1.5_wp, 2.0e9_wp, 5.0e2_wp, KN0, CHI0, FB0)  ! [wad]
  CALL mark_xfail('b', 800.0_wp, 1.25_wp, 1.5_wp, EA0, 5.0e2_wp, KN0, CHI0, FB0)       ! [unresolved]
  CALL mark_xfail('f', 800.0_wp, -1.0_wp, 2.5_wp, EA0, 5.0e2_wp, 3.0e6_wp, CHI0, FB0)  ! [wad]
  CALL mark_xfail('f', 200.0_wp, 1.25_wp, 2.5_wp, EA0, 5.0e2_wp, KN0, CHI0, 0.40_wp)   ! [wad]

  ! reproduction hook: `test_static_init_sweep <case>` runs that case alone and dumps its
  ! seed + converged geometry to sweep_case_<case>.csv (never used by the ctest gate)
  only_case = 0
  CALL GET_COMMAND_ARGUMENT(1, arg, STATUS=ios_arg)
  IF (ios_arg == 0 .AND. LEN_TRIM(arg) > 0) READ (arg, *, IOSTAT=ios_arg) only_case

  ! the builder must be ENDPOINT-ORDER AGNOSTIC: the repository's finite-EI line
  ! convention runs anchor -> fairlead (grounded end FIRST), while the matrix below
  ! calls fairlead-first -- both orders of the same physical rig must produce
  ! mirror-identical seeds (regression for the grounded-end-A construction)
  CALL case_builder_order_agnostic()
  IF (n_fail > 0) THEN
    WRITE (*, '(A)') 'FAIL: static-initialization stress sweep (builder order regression)'
    ERROR STOP 1
  END IF

  WRITE (*, '(A,I0,A)') 'SWEEP: ', ncase, ' cases'
  DO m = 1, ncase
    IF (only_case > 0 .AND. m /= only_case) CYCLE
    CALL run_case(m, ok)
    IF (ok .AND. .NOT. p_xf(m)) THEN
      n_pass = n_pass + 1
    ELSE IF (ok .AND. p_xf(m)) THEN
      n_xpass = n_xpass + 1
    ELSE IF (.NOT. ok .AND. p_xf(m)) THEN
      n_xfail = n_xfail + 1
    ELSE
      n_fail = n_fail + 1
    END IF
  END DO

  WRITE (*, '(A,I0,A,I0,A,I0,A,I0)') 'SWEEP SUMMARY: pass ', n_pass, '  fail ', n_fail, &
    '  xfail ', n_xfail, '  unexpected-pass ', n_xpass
  IF (n_fail > 0) THEN
    WRITE (*, '(A)') 'FAIL: static-initialization stress sweep'
    ERROR STOP 1
  END IF
  WRITE (*, '(A)') 'PASS: static-initialization stress sweep'

CONTAINS

  INCLUDE 'nan_max_abs.inc'

  SUBROUTINE case_builder_order_agnostic()
    !! Regression for the grounded-end-A seed construction: a slack installed rig
    !! built fairlead-first and anchor-first must give
    !! MIRROR-IDENTICAL seeds -- positions reversed node-for-node, tangents negated --
    !! and the anchor-first order must select the grounded construction (its minimum z
    !! reaches the bed) instead of failing as a bed-crossing suspended bow.
    INTEGER, PARAMETER :: NEO = 64
    REAL(wp) :: l0o(NEO), l0r(NEO), sfb(6*(NEO + 1)), saf(6*(NEO + 1))
    REAL(wp) :: pf(3), pa(3), Lo, err_p, err_m, minz
    INTEGER :: i, j, es
    CHARACTER(512) :: em
    pf = [0.0_wp, 0.0_wp, -2.0_wp]
    pa = [100.0_wp, 0.0_wp, -100.0_wp]
    Lo = 1.25_wp*SQRT(SUM((pa - pf)**2))
    l0o = Lo/REAL(NEO, wp)
    l0r = l0o
    CALL CD_HermiteCable_Trivial_Seed(pf, pa, l0o, -100.0_wp, sfb, es, em)
    IF (es /= CD_HCSTAT_OK) THEN
      WRITE (*, '(A)') 'FAIL: builder fairlead-first: '//TRIM(em)
      n_fail = n_fail + 1
      RETURN
    END IF
    CALL CD_HermiteCable_Trivial_Seed(pa, pf, l0r, -100.0_wp, saf, es, em)
    IF (es /= CD_HCSTAT_OK) THEN
      WRITE (*, '(A)') 'FAIL: builder anchor-first (grounded end A): '//TRIM(em)
      n_fail = n_fail + 1
      RETURN
    END IF
    err_p = 0.0_wp; err_m = 0.0_wp; minz = HUGE(1.0_wp)
    DO i = 1, NEO + 1
      j = NEO + 2 - i
      err_p = MAX(err_p, nan_max_abs(saf(6*i - 5:6*i - 3) - sfb(6*j - 5:6*j - 3)))
      err_m = MAX(err_m, nan_max_abs(saf(6*i - 2:6*i) + sfb(6*j - 2:6*j)))
      minz = MIN(minz, saf(6*i - 3))
    END DO
    IF (.NOT. (err_p <= 1.0e-9_wp*Lo .AND. err_m <= 1.0e-9_wp)) THEN
      WRITE (*, '(A,2ES10.2)') 'FAIL: builder orders not mirror-identical: ', err_p, err_m
      n_fail = n_fail + 1
      RETURN
    END IF
    IF (.NOT. (minz <= -100.0_wp + 1.0e-3_wp)) THEN
      WRITE (*, '(A,F8.3)') 'FAIL: anchor-first seed never reaches the bed: min z = ', minz
      n_fail = n_fail + 1
      RETURN
    END IF
    WRITE (*, '(A)') 'ok:   builder is endpoint-order agnostic (mirror-identical grounded seeds)'

    ! taut stretch gauge: a shorter-than-chord line is laid uniformly stretched, so the
    ! consistent material tangent is |m| = chord/SUM(l0) at EVERY node (m = dr/ds) --
    ! a unit gauge there would seed spurious tangent residuals on a no-load taut cable
    l0o = 0.995_wp*SQRT(SUM((pa - pf)**2))/REAL(NEO, wp)
    CALL CD_HermiteCable_Trivial_Seed(pf, pa, l0o, -100.0_wp, sfb, es, em)
    IF (es /= CD_HCSTAT_OK) THEN
      WRITE (*, '(A)') 'FAIL: builder taut: '//TRIM(em)
      n_fail = n_fail + 1
      RETURN
    END IF
    err_m = 0.0_wp
    DO i = 1, NEO + 1
      err_m = MAX(err_m, ABS(SQRT(SUM(sfb(6*i - 2:6*i)**2)) - 1.0_wp/0.995_wp))
    END DO
    IF (.NOT. (err_m <= 1.0e-9_wp)) THEN
      WRITE (*, '(A,ES10.2)') 'FAIL: taut tangents not at the chord/L stretch gauge: ', err_m
      n_fail = n_fail + 1
      RETURN
    END IF
    WRITE (*, '(A)') 'ok:   taut seed tangents carry the chord/L stretch gauge'

    ! fully grounded slack (both endpoints on the bed): the seed must build (the
    ! prologue accepts bed-level endpoints, so a later internal rejection would break
    ! the contract) as a laid-cable S meandering IN the bed plane -- on the bed to
    ! round-off, with the surplus in a lateral bow
    pf = [0.0_wp, 0.0_wp, -100.0_wp]
    l0o = 1.20_wp*100.0_wp/REAL(NEO, wp)
    CALL CD_HermiteCable_Trivial_Seed(pf, pa, l0o, -100.0_wp, sfb, es, em)
    IF (es /= CD_HCSTAT_OK) THEN
      WRITE (*, '(A)') 'FAIL: builder fully-grounded slack: '//TRIM(em)
      n_fail = n_fail + 1
      RETURN
    END IF
    err_p = 0.0_wp; err_m = 0.0_wp
    DO i = 1, NEO + 1
      err_p = MAX(err_p, ABS(sfb(6*i - 3) + 100.0_wp))       ! on the bed
      err_m = MAX(err_m, ABS(sfb(6*i - 4)))                  ! lateral meander amplitude
    END DO
    IF (.NOT. (err_p <= 1.0e-9_wp*120.0_wp .AND. err_m > 1.0_wp)) THEN
      WRITE (*, '(A,2ES10.2)') 'FAIL: fully-grounded seed not an in-bed laid S: ', err_p, err_m
      n_fail = n_fail + 1
      RETURN
    END IF
    WRITE (*, '(A)') 'ok:   fully-grounded slack seed lies on the bed as a laid-cable S'
  END SUBROUTINE case_builder_order_agnostic

  SUBROUTINE mark_xfail(fam, d, sig, B, EA, EI, kn, chi, fb)
    !! Flag one existing case as a known failure. The sig sentinel convention matches
    !! add_case (it is resolved the same way before matching). Fail-closed: exactly one
    !! case must match, else the known-fail list has drifted from the matrix.
    CHARACTER(1), INTENT(IN) :: fam
    REAL(wp), INTENT(IN) :: d, sig, B, EA, EI, kn, chi, fb
    REAL(wp) :: h_a, x_ah, sig_r
    INTEGER :: ic, nmatch
    h_a = 0.98_wp*d
    x_ah = chi*d
    sig_r = sig
    IF (sig > -1.5_wp .AND. sig <= 0.0_wp) sig_r = 0.97_wp*(h_a + x_ah)/SQRT(h_a**2 + x_ah**2)
    IF (sig <= -1.5_wp) sig_r = 1.06_wp*(h_a + x_ah)/SQRT(h_a**2 + x_ah**2)
    nmatch = 0
    DO ic = 1, ncase
      ! same-literal provenance on both sides: zero-tolerance difference matches exactly
      ! without a REAL == comparison
      IF (p_fam(ic) == fam .AND. ABS(p_d(ic) - d) <= 0.0_wp .AND. &
          ABS(p_sig(ic) - sig_r) < 1.0e-12_wp .AND. ABS(p_B(ic) - B) <= 0.0_wp .AND. &
          ABS(p_EA(ic) - EA) <= 0.0_wp .AND. ABS(p_EI(ic) - EI) <= 0.0_wp .AND. &
          ABS(p_kn(ic) - kn) <= 0.0_wp .AND. ABS(p_chi(ic) - chi) <= 0.0_wp .AND. &
          ABS(p_fb(ic) - fb) <= 0.0_wp) THEN
        p_xf(ic) = .TRUE.
        nmatch = nmatch + 1
      END IF
    END DO
    IF (nmatch /= 1) THEN
      WRITE (*, '(A,I0,A,A1,A,F5.0)') 'FAIL: known-fail entry matches ', nmatch, &
        ' cases (family ', fam, ', d=', d
      ERROR STOP 1
    END IF
  END SUBROUTINE mark_xfail

  SUBROUTINE add_case(fam, d, sig, B, EA, EI, kn, chi, fb)
    !! sig <= 0 is a sentinel resolved against the case's L-shape bound
    !! sigma_bound = (h_a + x_ah)/chord: -1 -> 0.97x (hardest well-posed),
    !! -2 -> 1.06x (deliberately beyond, family g's ill-posed class).
    CHARACTER(1), INTENT(IN) :: fam
    REAL(wp), INTENT(IN) :: d, sig, B, EA, EI, kn, chi, fb
    REAL(wp) :: h_a, x_ah, sig_bound, sig_r
    IF (ncase >= MAXC) ERROR STOP 'case table overflow'
    ncase = ncase + 1
    h_a = 0.98_wp*d
    x_ah = chi*d
    sig_bound = (h_a + x_ah)/SQRT(h_a**2 + x_ah**2)
    sig_r = sig
    IF (sig > -1.5_wp .AND. sig <= 0.0_wp) sig_r = 0.97_wp*sig_bound
    IF (sig <= -1.5_wp) sig_r = 1.06_wp*sig_bound
    p_fam(ncase) = fam
    p_d(ncase) = d; p_sig(ncase) = sig_r; p_B(ncase) = B
    p_EA(ncase) = EA; p_EI(ncase) = EI; p_kn(ncase) = kn
    p_chi(ncase) = chi; p_fb(ncase) = fb
    p_xf(ncase) = .FALSE.
  END SUBROUTINE add_case

  SUBROUTINE run_case(ic, ok)
    !! Build the parametric rig + trivial seed, run the sequenced production solve, apply
    !! the acceptance battery. One printed line per case; failures carry the reproduction
    !! parameters.
    INTEGER, INTENT(IN) :: ic
    LOGICAL, INTENT(OUT) :: ok
    REAL(wp) :: d, sig, B, EA, EI, kn, chi, fb
    REAL(wp) :: zf, xa, za, chord, Ltot, buoy_w, a_mid, acc, branch_mesh_limit
    REAL(wp) :: res, kl, klmax, pen_bound, minz, wmax
    REAL(wp), ALLOCATABLE :: l0(:), EAv(:), EIv(:), w(:), seed(:), q(:), curv(:)
    INTEGER, ALLOCATABLE :: fixed(:)
    INTEGER :: ne, nn, e, i, nfx, ibl(N_LEVELS), es, nlev, klarg, coarse_ne, next_ne
    CHARACTER(512) :: em
    CHARACTER(4) :: verdict

    d = p_d(ic); sig = p_sig(ic); B = p_B(ic); EA = p_EA(ic)
    EI = p_EI(ic); kn = p_kn(ic); chi = p_chi(ic); fb = p_fb(ic)

    ! geometry: fairlead just below the surface, anchor on the bed at x = chi*d
    zf = -0.02_wp*d
    xa = chi*d; za = -d
    chord = SQRT(xa**2 + (za - zf)**2)
    Ltot = sig*chord

    ! mesh: uniform, ~L/40 chunks of 8 elements, in [64, 256] (divisible by 2^(N_LEVELS-1))
    ne = 8*NINT(Ltot/40.0_wp)
    ne = MAX(64, MIN(256, ne))
    nn = ne + 1
    ! ladder depth by bending resolution: coarsen only while the coarse level keeps
    ! >= 24 elements AND its element length stays within 3.2 bending lengths.
    ! This is a branch-selection homotopy limit, not the accepted final-mesh
    ! accuracy: every result returns to the exact caller mesh and passes h*kappa.
    ! lambda = (EI/|w|)^(1/3). The cap contains the committed 89-element
    ! installed-cable ladder (~3.1 lambda). The deck route may try one
    ! independently bounded deeper level only after this primary route fails.
    branch_mesh_limit = 3.2_wp*(EI/BARE_W)**(1.0_wp/3.0_wp)
    nlev = 1
    coarse_ne = ne
    DO WHILE (nlev < N_LEVELS)
      next_ne = coarse_ne - coarse_ne/3
      IF (next_ne >= coarse_ne .OR. next_ne < 24) EXIT
      IF (Ltot/REAL(next_ne, wp) > branch_mesh_limit) EXIT
      nlev = nlev + 1
      coarse_ne = next_ne
    END DO
    ALLOCATE (l0(ne), EAv(ne), EIv(ne), w(ne), seed(6*nn), q(6*nn), curv(nn), fixed(6 + 2*nn))
    l0 = Ltot/REAL(ne, wp)
    buoy_w = -B*BARE_W
    acc = 0.0_wp
    DO e = 1, ne
      a_mid = acc + 0.5_wp*l0(e)
      acc = acc + l0(e)
      EAv(e) = EA; EIv(e) = EI
      IF (B > 0.0_wp .AND. a_mid > F1*Ltot .AND. a_mid <= (F1 + fb)*Ltot) THEN
        w(e) = buoy_w
      ELSE
        w(e) = BARE_W
      END IF
    END DO

    ! trivial seed from the LIBRARY builder (isometric by construction; the endpoints and
    ! rest lengths are its only inputs -- the productized "user gives geometry, library
    ! gives the seed" contract this sweep certifies)
    CALL CD_HermiteCable_Trivial_Seed([0.0_wp, 0.0_wp, zf], [xa, 0.0_wp, za], l0, -d, &
                                      seed, es, em)
    IF (es /= CD_HCSTAT_OK) THEN
      ok = .FALSE.
      WRITE (*, '(A,I3,1X,A1,A)') 'SWEEP ', ic, p_fam(ic), ' seed builder FAILED'
      WRITE (*, '(A,I0,2A)') '  seed: ErrStat=', es, ' ', TRIM(em)
      RETURN
    END IF

    ! planar pins (y + m_y every node) + endpoint positions
    nfx = 0
    DO i = 1, 3; nfx = nfx + 1; fixed(nfx) = i; END DO
    DO i = 1, 3; nfx = nfx + 1; fixed(nfx) = 6*(nn - 1) + i; END DO
    DO i = 1, nn
      nfx = nfx + 1; fixed(nfx) = 6*(i - 1) + 2
      nfx = nfx + 1; fixed(nfx) = 6*(i - 1) + 5
    END DO

    ibl = 0
    CALL CD_HermiteCable_Static_Solve_Sequenced(l0, EAv, EIv, w, seed, fixed(1:nfx), &
                                                -d, kn, N_CONT, MAX_ITER, TOL, DAMPING, &
                                                nlev, q, curv, res, ibl(1:nlev), es, em)

    ok = (es == CD_HCSTAT_OK)
    klmax = -1.0_wp; minz = HUGE(1.0_wp); klarg = 0
    IF (ok) ok = ALL(IEEE_IS_FINITE(q))
    IF (ok) THEN
      DO i = 1, nn
        kl = curv(i)*0.5_wp*(l0(MAX(i - 1, 1)) + l0(MIN(i, ne)))
        IF (kl > klmax) THEN
          klmax = kl; klarg = i
        END IF
        minz = MIN(minz, q(6*i - 3))
      END DO
      wmax = nan_max_abs(w)
      ! well-posed families: penetration consistent with per-length weight over the
      ! penalty. Family g: a wad presses with bending-scale contact force, so the
      ! weight-scaled bound does not apply -- gate only a 5%-of-depth sanity ceiling.
      pen_bound = MERGE(0.05_wp*d, 10.0_wp*wmax/kn + 1.0e-3_wp, p_fam(ic) == 'g')
      IF (klmax > MERGE(WAD_KL, KINK_GATE, p_fam(ic) == 'g')) ok = .FALSE.
      IF (minz < -d - pen_bound) ok = .FALSE.
    ELSE IF (p_fam(ic) == 'g' .AND. es /= CD_HCSTAT_OK .AND. LEN_TRIM(em) > 0) THEN
      ! beyond the L-shape bound a clean diagnosed failure honours the class promise
      ! (no silent garbage) -- see the header
      ok = .TRUE.
    END IF

    IF (ok) THEN
      verdict = 'PASS'
    ELSE IF (p_xf(ic)) THEN
      verdict = 'XFAI'
    ELSE
      verdict = 'FAIL'
    END IF
    WRITE (*, '(A,I3,1X,A1,A,F5.0,A,F5.2,A,F4.1,A,ES8.1,A,ES8.1,A,ES8.1,A,F4.1,A,F5.2,A,I3,A,I4,'// &
           'A,ES9.2,A,ES9.2,A,F5.2,1X,A)') &
      'SWEEP ', ic, p_fam(ic), ' d=', d, ' sig=', sig, ' B=', B, ' EA=', EA, ' EI=', EI, &
      ' kn=', kn, ' chi=', chi, ' fb=', fb, ' ne=', ne, ' it=', SUM(ibl), ' res=', res, &
      ' kl=', klmax, ' s/L=', REAL(klarg - 1, wp)/REAL(ne, wp), verdict
    IF (.NOT. ok .AND. es /= CD_HCSTAT_OK) WRITE (*, '(A,I0,2A)') '  solver: ErrStat=', es, ' ', TRIM(em)
    IF (only_case == ic) CALL dump_case(ic, nn, seed, q, curv)
  END SUBROUTINE run_case

  SUBROUTINE dump_case(ic, nn, seed, q, curv)
    !! Reproduction dump for the single-case hook: seed + converged state per node.
    INTEGER, INTENT(IN) :: ic, nn
    REAL(wp), INTENT(IN) :: seed(:), q(:), curv(:)
    INTEGER :: u, i
    CHARACTER(64) :: fn
    WRITE (fn, '(A,I0,A)') 'sweep_case_', ic, '.csv'
    OPEN (NEWUNIT=u, FILE=TRIM(fn), STATUS='REPLACE', ACTION='WRITE')
    WRITE (u, '(A)') 'node,seed_x,seed_z,x,y,z,mx,my,mz,curv'
    DO i = 1, nn
      WRITE (u, '(I0,9(A,ES16.8))') i, ',', seed(6*i - 5), ',', seed(6*i - 3), &
        ',', q(6*i - 5), ',', q(6*i - 4), ',', q(6*i - 3), &
        ',', q(6*i - 2), ',', q(6*i - 1), ',', q(6*i), ',', curv(i)
    END DO
    CLOSE (u)
    WRITE (*, '(2A)') '  dumped ', TRIM(fn)
  END SUBROUTINE dump_case

END PROGRAM test_static_init_sweep
