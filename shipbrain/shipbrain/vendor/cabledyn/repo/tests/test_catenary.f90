! File: tests/test_catenary.f90
! SPDX-License-Identifier: Apache-2.0
! Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
PROGRAM test_catenary
  !! reference-parity check for the analytical catenary seed (CableDyn_Catenary,
  !! CD_Catenary_Seed) against independently computed seed values. Two
  !! cases (EA = 1e6, anchor [0,0,0], fairlead [3,0,1.5], 4 unit elements):
  !!   * grounded -- all-positive weight [50,50,50,50] (part laid on the seabed),
  !!   * buoyseg  -- a mildly buoyant top segment [50,50,50,-5] (signed-weight path),
  !! with reference H / grounded length / node positions captured from the reference.
  !! Plus the fail-closed contract (bad shapes, non-finite, non-positive, fairlead
  !! below the anchor, and a geometry that admits no grounded-catenary seed).
  USE CableDyn_Precision, ONLY: wp
  USE CableDyn_Catenary, ONLY: CD_Catenary_Seed, CD_CAT_OK, CD_CAT_BADINPUT, &
                               CD_CAT_NOSEED
  USE, INTRINSIC :: IEEE_ARITHMETIC, ONLY: IEEE_VALUE, IEEE_QUIET_NAN, IEEE_IS_FINITE
  IMPLICIT NONE

  INTEGER :: nfail
  REAL(wp), PARAMETER :: PTOL = 1.0e-6_wp     ! node-position parity
  REAL(wp), PARAMETER :: HTOL = 1.0e-3_wp     ! H / grounded-length parity (~17 and ~2.2)
  nfail = 0

  CALL case_grounded()
  CALL case_buoyant_segment()
  CALL case_lazy_wave()
  CALL case_buoyant_large_liftoff()
  CALL case_fail_closed()
  CALL case_exact_sweep()
  CALL case_suspended_exact()
  CALL case_vertical()
  CALL case_near_neutral_continuity()
  CALL case_neutral_taut()
  CALL case_elevated_anchor()
  CALL case_sloped_bed()

  IF (nfail > 0) THEN
    WRITE (*, '(A,I0,A)') 'FAIL: ', nfail, ' assertion(s) failed'
    ERROR STOP 1
  END IF
  WRITE (*, '(A)') 'PASS: CableDyn_Catenary seed matches the independent reference values'

CONTAINS

  SUBROUTINE case_neutral_taut()
    !! A neutrally buoyant taut line (the clamped-cable energy deck) carries a round-off
    !! weight whose sign depends on the platform. Zero, tiny positive and tiny negative
    !! weights must all seed the straight chord with the closed-form uniform tension.
    INTEGER, PARAMETER :: n = 20
    REAL(wp) :: lens(n), eav(n), wv(n), pos(3*(n + 1)), h, gl, chord, t_exact, dev
    REAL(wp) :: wtiny(3) = [0.0_wp, 3.0e-14_wp, -3.0e-14_wp]
    INTEGER  :: k, es, node
    CHARACTER(160) :: em
    lens = 1.0_wp; eav = 1.0e6_wp
    chord = 20.1_wp
    t_exact = (chord - 20.0_wp)/SUM(lens/eav)
    DO k = 1, 3
      wv = wtiny(k)
      CALL CD_Catenary_Seed([1.0_wp, 0.0_wp, -50.0_wp], [21.1_wp, 0.0_wp, -50.0_wp], lens, eav, wv, &
                            pos, h, gl, es, em, seabed_z=-200.0_wp)
      CALL require(es == CD_CAT_OK, 'neutral-taut:seed-ok')
      IF (es /= CD_CAT_OK) CYCLE
      CALL require(ABS(h - t_exact) <= 1.0e-10_wp*t_exact .AND. .NOT. (ABS(gl) > 0.0_wp), &
                   'neutral-taut:uniform-tension')
      dev = 0.0_wp
      DO node = 1, n + 1
        dev = MAX(dev, ABS(pos(3*node - 1)), ABS(pos(3*node) + 50.0_wp))
      END DO
      CALL require(dev < 1.0e-12_wp, 'neutral-taut:straight-chord')
      CALL require(ABS(pos(3*n + 1) - 21.1_wp) < 1.0e-12_wp, 'neutral-taut:endpoint-closed')
    END DO
  END SUBROUTINE case_neutral_taut

  INCLUDE 'nan_max_abs.inc'

  SUBROUTINE case_grounded()
    REAL(wp) :: anchor(3), fairlead(3), lengths(4), ea(4), weight(4), pos(15), h, gl
    INTEGER  :: es, i
    CHARACTER(160) :: em
    REAL(wp), PARAMETER :: want(15) = [ &
                           0.0000000000_wp, 0.0_wp, 0.0000000000_wp, &
                           1.0000170935_wp, 0.0_wp, 0.0000000000_wp, &
                           2.0000341870_wp, 0.0_wp, 0.0000000000_wp, &
                           2.7363474925_wp, 0.0_wp, 0.5371349579_wp, &
                           3.0000000000_wp, 0.0_wp, 1.5000000000_wp]
    anchor = [0.0_wp, 0.0_wp, 0.0_wp]
    fairlead = [3.0_wp, 0.0_wp, 1.5_wp]
    lengths = [1.0_wp, 1.0_wp, 1.0_wp, 1.0_wp]
    ea = 1.0e6_wp
    weight = [50.0_wp, 50.0_wp, 50.0_wp, 50.0_wp]
    CALL CD_Catenary_Seed(anchor, fairlead, lengths, ea, weight, pos, h, gl, es, em)
    CALL require(es == CD_CAT_OK, 'grounded:ErrStat')
    CALL require(ABS(h - 17.09350831_wp) < HTOL, 'grounded:H')
    CALL require(ABS(gl - 2.19000549_wp) < HTOL, 'grounded:grounded-length')
    DO i = 1, 15
      CALL expect(pos(i), want(i), 'grounded:position')
    END DO
  END SUBROUTINE case_grounded

  SUBROUTINE case_buoyant_segment()
    REAL(wp) :: anchor(3), fairlead(3), lengths(4), ea(4), weight(4), pos(15), h, gl
    INTEGER  :: es, i
    CHARACTER(160) :: em
    REAL(wp), PARAMETER :: want(15) = [ &
                           0.0000000000_wp, 0.0_wp, 0.0000000000_wp, &
                           1.0000115985_wp, 0.0_wp, 0.0000000000_wp, &
                           2.0000231970_wp, 0.0_wp, 0.0000000000_wp, &
                           2.6861159138_wp, 0.0_wp, 0.5505789224_wp, &
                           3.0000000000_wp, 0.0_wp, 1.5000000000_wp]
    anchor = [0.0_wp, 0.0_wp, 0.0_wp]
    fairlead = [3.0_wp, 0.0_wp, 1.5_wp]
    lengths = [1.0_wp, 1.0_wp, 1.0_wp, 1.0_wp]
    ea = 1.0e6_wp
    weight = [50.0_wp, 50.0_wp, 50.0_wp, -5.0_wp]    ! mild buoyant top segment (signed-weight path)
    CALL CD_Catenary_Seed(anchor, fairlead, lengths, ea, weight, pos, h, gl, es, em)
    CALL require(es == CD_CAT_OK, 'buoyseg:ErrStat')
    ! the endpoint is closed exactly (hard constraint) and the grounded portion is
    ! present; a buoyant segment exercises the signed-weight integration
    CALL require(ABS(pos(13) - 3.0_wp) < 1.0e-6_wp .AND. ABS(pos(15) - 1.5_wp) < 1.0e-6_wp, &
                 'buoyseg:endpoint-closed')
    CALL require(gl > 0.0_wp .AND. gl < SUM(lengths), 'buoyseg:has-grounded-and-suspended')
    CALL require(h > 0.0_wp .AND. h < 100.0_wp, 'buoyseg:H-sane')
    ! Interior shape is only SEED-accurate: the buoyant lift-off vertical tension is
    ! pinned by a tiny Tikhonov term, so the interior node is weakly determined
    ! (solver-path-dependent) -- match the reference to a seed-level tolerance, not the
    ! 1e-6 used for the well-posed (tangent-lift-off) grounded case.
    DO i = 1, 15
      CALL require(ABS(pos(i) - want(i)) < 1.0e-2_wp, 'buoyseg:position-seed-level')
    END DO
  END SUBROUTINE case_buoyant_segment

  SUBROUTINE case_lazy_wave()
    !! The documented lazy-wave seed (a grounded catenary that must build a
    !! buoyant turning point):
    !! 14x10 m, buoyant middle segments, anchor (91,0,-80) -> fairlead (0,0,0).
    !! The Marquardt-scaled closure must converge it (it must not fail closed),
    !! close the endpoint, and build a buoyant turning point (a z-slope sign change).
    REAL(wp) :: anchor(3), fairlead(3), lengths(14), ea(14), weight(14), pos(45), h, gl
    REAL(wp) :: slope(14)
    INTEGER  :: es, i
    LOGICAL  :: turns
    CHARACTER(160) :: em
    anchor = [91.0_wp, 0.0_wp, -80.0_wp]
    fairlead = [0.0_wp, 0.0_wp, 0.0_wp]
    lengths = 10.0_wp
    ea(1:5) = 1.0e8_wp
    ea(6:13) = 8.0e7_wp
    ea(14) = 1.2e8_wp
    weight(1:5) = 900.0_wp
    weight(6:13) = -1000.0_wp
    weight(14) = 950.0_wp
    CALL CD_Catenary_Seed(anchor, fairlead, lengths, ea, weight, pos, h, gl, es, em)
    CALL require(es == CD_CAT_OK, 'lazywave:converged-not-failed-closed')
    CALL require(ABS(pos(1) - 91.0_wp) < 1.0e-6_wp .AND. ABS(pos(3) + 80.0_wp) < 1.0e-6_wp, 'lazywave:anchor')
    CALL require(ABS(pos(43)) < 1.0e-5_wp .AND. ABS(pos(45)) < 1.0e-5_wp, 'lazywave:fairlead-closed')
    ! Complementarity: this net-buoyant line has no grounded run with zero lift-off
    ! tension; the exact seed lifts off at the anchor (upward first element) and never
    ! dips below the seabed through the anchor.
    CALL require(gl >= 0.0_wp .AND. gl < SUM(lengths), 'lazywave:grounded-length-range')
    CALL require(gl > 0.0_wp .OR. pos(6) > pos(3), 'lazywave:anchor-uplift-when-ungrounded')
    CALL require(MINVAL(pos(3::3)) >= -80.0_wp - 1.0e-9_wp, 'lazywave:no-seabed-penetration')
    CALL require(h > 0.0_wp .AND. h < 1.0e6_wp, 'lazywave:H-sane')
    ! buoyant turning point: some consecutive interior z-slopes have opposite signs
    DO i = 1, 14
      slope(i) = pos(3*(i + 1)) - pos(3*i)
    END DO
    turns = .FALSE.
    DO i = 1, 12
      IF (slope(i)*slope(i + 1) < 0.0_wp) turns = .TRUE.
    END DO
    CALL require(turns, 'lazywave:buoyant-turning-point')
  END SUBROUTINE case_lazy_wave

  SUBROUTINE case_buoyant_large_liftoff()
    !! Regression for the acceptance-on-endpoint-norm fix: a strongly
    !! buoyant line whose closure needs a large lift-off V, so the Tikhonov term
    !! r(3) = 1e-8 V / tension_seed (~2.6e-7) exceeds ACCEPT_TOL even though the
    !! fairlead is closed (~1e-11). Gating on the full residual norm would fail this
    !! valid seed closed; gating on the endpoint norm accepts it. Mirrors the
    !! exact example (3 equal elements, hspan 45.0993, rise 50.7453, total 57.9071,
    !! weights [66.2, -48.7, -17.6], EA 1e6).
    REAL(wp) :: anchor(3), fairlead(3), lengths(3), ea(3), weight(3), pos(12), h, gl
    INTEGER  :: es
    CHARACTER(160) :: em
    anchor = [0.0_wp, 0.0_wp, 0.0_wp]
    fairlead = [45.0993_wp, 0.0_wp, 50.7453_wp]
    lengths = 57.9071_wp/3.0_wp
    ea = 1.0e6_wp
    weight = [66.2_wp, -48.7_wp, -17.6_wp]
    CALL CD_Catenary_Seed(anchor, fairlead, lengths, ea, weight, pos, h, gl, es, em)
    ! Regression: this must remain accepted; the large-vertical-span case is valid.
    ! Tikhonov r(3) dominated the full residual norm) -- accept on the endpoint norm
    CALL require(es == CD_CAT_OK, 'largeV:converged-not-failed-closed')
    CALL require(ABS(pos(10) - 45.0993_wp) < 1.0e-5_wp .AND. ABS(pos(12) - 50.7453_wp) < 1.0e-5_wp, &
                 'largeV:endpoint-closed')
    CALL require(ALL(IEEE_IS_FINITE(pos)) .AND. h > 0.0_wp, 'largeV:finite-seed')
  END SUBROUTINE case_buoyant_large_liftoff

  SUBROUTINE case_fail_closed()
    REAL(wp) :: anchor(3), fairlead(3), lengths(4), ea(4), weight(4), pos(15), h, gl
    REAL(wp) :: ea3(3), nan
    INTEGER  :: es
    CHARACTER(160) :: em
    anchor = [0.0_wp, 0.0_wp, 0.0_wp]
    fairlead = [3.0_wp, 0.0_wp, 1.5_wp]
    lengths = [1.0_wp, 1.0_wp, 1.0_wp, 1.0_wp]
    ea = 1.0e6_wp
    weight = [50.0_wp, 50.0_wp, 50.0_wp, 50.0_wp]
    nan = IEEE_VALUE(1.0_wp, IEEE_QUIET_NAN)
    ! ea wrong length
    ea3 = 1.0e6_wp
    CALL CD_Catenary_Seed(anchor, fairlead, lengths, ea3, weight, pos, h, gl, es, em)
    CALL require(es == CD_CAT_BADINPUT, 'fail:ea-wrong-length')
    ! non-finite weight
    CALL CD_Catenary_Seed(anchor, fairlead, lengths, ea, [50.0_wp, nan, 50.0_wp, 50.0_wp], pos, h, gl, es, em)
    CALL require(es == CD_CAT_BADINPUT, 'fail:non-finite')
    ! non-positive length
    CALL CD_Catenary_Seed(anchor, fairlead, [1.0_wp, 0.0_wp, 1.0_wp, 1.0_wp], ea, weight, pos, h, gl, es, em)
    CALL require(es == CD_CAT_BADINPUT, 'fail:non-positive-length')
    ! fairlead below the anchor (no rise)
    CALL CD_Catenary_Seed(anchor, [3.0_wp, 0.0_wp, -1.0_wp], lengths, ea, weight, pos, h, gl, es, em)
    CALL require(es == CD_CAT_BADINPUT, 'fail:fairlead-below-anchor')
    ! taut: total length < horizontal span -> the stretched suspended span (no grounding)
    CALL CD_Catenary_Seed(anchor, [10.0_wp, 0.0_wp, 1.5_wp], lengths, ea, weight, pos, h, gl, es, em)
    CALL require(es == CD_CAT_OK .AND. .NOT. (gl > 0.0_wp) .AND. h > 0.0_wp, 'taut:stretched-suspended-seed')
    CALL require(ABS(pos(13) - 10.0_wp) < 1.0e-9_wp .AND. ABS(pos(15) - 1.5_wp) < 1.0e-9_wp, &
                 'taut:endpoint-closed')
    ! too slack: longer than hspan + rise -> cannot lie in the vertical plane on the seabed
    CALL CD_Catenary_Seed(anchor, fairlead, [3.0_wp, 3.0_wp, 3.0_wp, 3.0_wp], ea, weight, pos, h, gl, es, em)
    CALL require(es == CD_CAT_NOSEED, 'fail:no-seed-slack')
    ! non-finite seabed arguments
    CALL CD_Catenary_Seed(anchor, fairlead, lengths, ea, weight, pos, h, gl, es, em, seabed_z=nan)
    CALL require(es == CD_CAT_BADINPUT, 'fail:non-finite-seabed')
    ! fairlead below a sloped bed
    CALL CD_Catenary_Seed(anchor, fairlead, lengths, ea, weight, pos, h, gl, es, em, seabed_slope=1.0_wp)
    CALL require(es == CD_CAT_BADINPUT, 'fail:fairlead-below-sloped-bed')
  END SUBROUTINE case_fail_closed

  SUBROUTINE case_exact_sweep()
    !! Grounded-anchor seeds against the exact extensible catenary on a frictionless flat
    !! bed (independent closed forms): a grounded run with zero lift-off vertical tension
    !! when one exists, otherwise a fully suspended span with anchor uplift Va >= 0. The
    !! sweep crosses the grounded/uplift switch and the taut (L <= chord) regime.
    INTEGER, PARAMETER :: n = 40
    REAL(wp) :: xs(3) = [400.0_wp, 405.0_wp, 410.0_wp], ls(4) = [405.0_wp, 420.0_wp, 470.0_wp, 495.0_wp]
    REAL(wp) :: eas(2) = [1.0e7_wp, 1.0e9_wp]
    REAL(wp) :: lens(n), eav(n), wv(n), pos(3*(n + 1)), h, gl, prm(6), p(2), err, x, z, s
    INTEGER  :: i, j, k, es, node
    LOGICAL  :: ok
    CHARACTER(160) :: em
    DO i = 1, 3
      DO j = 1, 4
        DO k = 1, 2
          lens = ls(j)/REAL(n, wp); eav = eas(k); wv = 1000.0_wp
          CALL CD_Catenary_Seed([0.0_wp, 0.0_wp, -100.0_wp], [xs(i), 0.0_wp, 0.0_wp], lens, eav, wv, &
                                pos, h, gl, es, em)
          CALL require(es == CD_CAT_OK, 'sweep:seed-ok')
          IF (es /= CD_CAT_OK) CYCLE
          prm = [xs(i), 100.0_wp, ls(j), eas(k), 1000.0_wp, 0.0_wp]
          IF (gl > 0.0_wp) THEN
            p = [h, gl]
            CALL ref_newton(1, p, prm, ok)
            CALL require(ok .AND. p(2) > 0.0_wp .AND. p(2) < ls(j), 'sweep:exact-grounded-root')
          ELSE
            ! Start the anchor vertical force from the straight-chord estimate H*Z/X - wL/2.
            p = [h, MAX(0.0_wp, h*100.0_wp/xs(i) - 0.5_wp*1000.0_wp*ls(j))]
            CALL ref_newton(2, p, prm, ok)
            CALL require(ok .AND. p(2) >= -1.0e-9_wp*1000.0_wp*ls(j), 'sweep:exact-uplift-nonnegative')
          END IF
          CALL require(ABS(h - p(1)) <= 1.0e-8_wp*p(1), 'sweep:H-exact')
          err = 0.0_wp
          DO node = 1, n + 1
            s = REAL(node - 1, wp)*ls(j)/REAL(n, wp)
            CALL ref_point(MERGE(1, 2, gl > 0.0_wp), p, prm, s, x, z)
            err = MAX(err, HYPOT(pos(3*node - 2) - x, pos(3*node) - (z - 100.0_wp)))
          END DO
          CALL require(err < 1.0e-6_wp, 'sweep:nodes-on-exact-catenary')
          CALL require(MINVAL(pos(3::3)) >= -100.0_wp - 1.0e-9_wp, 'sweep:no-seabed-penetration')
          IF (.NOT. ok .OR. ABS(h - p(1)) > 1.0e-8_wp*p(1) .OR. .NOT. (err < 1.0e-6_wp)) &
            WRITE (*, '(A,3I2,3ES24.16)') 'sweep case (i, j, k), seed H, reference H, node error:', &
            i, j, k, h, p(1), err
        END DO
      END DO
    END DO
    ! A line longer than hspan + rise cannot lie in the plane on the bed.
    lens = 520.0_wp/REAL(n, wp); eav = 1.0e9_wp; wv = 1000.0_wp
    CALL CD_Catenary_Seed([0.0_wp, 0.0_wp, -100.0_wp], [400.0_wp, 0.0_wp, 0.0_wp], lens, eav, wv, &
                          pos, h, gl, es, em)
    CALL require(es == CD_CAT_NOSEED, 'sweep:too-long-noseed')
  END SUBROUTINE case_exact_sweep

  SUBROUTINE case_suspended_exact()
    !! Mid-water (suspended) seeds against the exact suspended catenary: anchor below,
    !! level with and above the fairlead, buoyant, near-vertical and taut spans.
    INTEGER, PARAMETER :: n = 30, ncase = 8
    REAL(wp) :: cx(ncase) = [200.0_wp, 200.0_wp, 100.0_wp, 200.0_wp, 200.0_wp, 1.0_wp, 1.0e-3_wp, 200.0_wp]
    REAL(wp) :: cz(ncase) = [50.0_wp, 0.0_wp, -150.0_wp, 50.0_wp, -50.0_wp, 100.0_wp, 100.0_wp, 50.0_wp]
    REAL(wp) :: cl(ncase) = [260.0_wp, 260.0_wp, 260.0_wp, 260.0_wp, 260.0_wp, 150.0_wp, 150.0_wp, 205.0_wp]
    REAL(wp) :: cw(ncase) = [800.0_wp, 800.0_wp, 800.0_wp, -300.0_wp, -300.0_wp, 800.0_wp, 800.0_wp, 800.0_wp]
    REAL(wp) :: lens(n), eav(n), wv(n), pos(3*(n + 1)), h, gl, prm(6), p(2), err, x, z, s
    INTEGER  :: c, es, node
    LOGICAL  :: ok
    CHARACTER(160) :: em
    DO c = 1, ncase
      lens = cl(c)/REAL(n, wp); eav = 1.0e8_wp; wv = cw(c)
      CALL CD_Catenary_Seed([0.0_wp, 0.0_wp, 0.0_wp], [cx(c), 0.0_wp, cz(c)], lens, eav, wv, pos, h, gl, &
                            es, em, suspended=.TRUE.)
      CALL require(es == CD_CAT_OK .AND. .NOT. (gl > 0.0_wp), 'suspended:seed-ok')
      IF (es /= CD_CAT_OK) CYCLE
      prm = [cx(c), cz(c), cl(c), 1.0e8_wp, cw(c), 0.0_wp]
      p = [h, 0.0_wp]
      CALL ref_newton(2, p, prm, ok)
      ! The near-vertical spans resolve H only to the reference solve's tolerance on a
      ! millimetre span; the node positions below are the sharp check.
      CALL require(ok .AND. ABS(h - p(1)) <= 1.0e-5_wp*p(1), 'suspended:H-exact')
      err = 0.0_wp
      DO node = 1, n + 1
        s = REAL(node - 1, wp)*cl(c)/REAL(n, wp)
        CALL ref_point(2, p, prm, s, x, z)
        err = MAX(err, HYPOT(pos(3*node - 2) - x, pos(3*node) - z))
      END DO
      CALL require(err < 1.0e-6_wp, 'suspended:nodes-on-exact-catenary')
    END DO
  END SUBROUTINE case_suspended_exact

  SUBROUTINE case_vertical()
    !! Zero horizontal span: the stretched straight hanging line (closed form), and a
    !! slack vertical span that has no in-plane seed.
    INTEGER, PARAMETER :: n = 10
    REAL(wp) :: lens(n), eav(n), wv(n), pos(3*(n + 1)), h, gl, va, s, zex, err
    INTEGER  :: es, node
    CHARACTER(160) :: em
    lens = 99.9_wp/REAL(n, wp); eav = 1.0e8_wp; wv = 100.0_wp
    CALL CD_Catenary_Seed([5.0_wp, 0.0_wp, 0.0_wp], [5.0_wp, 0.0_wp, 100.0_wp], lens, eav, wv, pos, h, gl, es, em)
    CALL require(es == CD_CAT_OK .AND. .NOT. (h > 0.0_wp) .AND. .NOT. (gl > 0.0_wp), 'vertical:taut-seed-ok')
    va = (100.0_wp - 99.9_wp - 100.0_wp*99.9_wp**2/(2.0_wp*1.0e8_wp))*1.0e8_wp/99.9_wp
    err = 0.0_wp
    DO node = 1, n + 1
      s = REAL(node - 1, wp)*99.9_wp/REAL(n, wp)
      zex = s + (va*s + 0.5_wp*100.0_wp*s*s)/1.0e8_wp
      err = MAX(err, ABS(pos(3*node) - zex), ABS(pos(3*node - 2) - 5.0_wp))
    END DO
    CALL require(va > 0.0_wp .AND. err < 1.0e-9_wp, 'vertical:closed-form-nodes')
    ! Compression at the anchor (the weight stretches the line past its rise) folds it.
    eav = 1.0e6_wp
    CALL CD_Catenary_Seed([5.0_wp, 0.0_wp, 0.0_wp], [5.0_wp, 0.0_wp, 100.0_wp], lens, eav, wv, pos, h, gl, es, em)
    CALL require(es == CD_CAT_NOSEED, 'vertical:self-weight-overstretch-noseed')
    eav = 1.0e8_wp
    lens = 110.0_wp/REAL(n, wp)
    CALL CD_Catenary_Seed([5.0_wp, 0.0_wp, 0.0_wp], [5.0_wp, 0.0_wp, 100.0_wp], lens, eav, wv, pos, h, gl, es, em)
    CALL require(es == CD_CAT_NOSEED, 'vertical:slack-noseed')
    lens = 49.9_wp/REAL(n, wp)
    CALL CD_Catenary_Seed([0.0_wp, 0.0_wp, 0.0_wp], [0.0_wp, 0.0_wp, -50.0_wp], lens, eav, wv, pos, h, gl, es, em, &
                          suspended=.TRUE.)
    CALL require(es == CD_CAT_OK .AND. ALL(pos(6::3) < pos(3:3*n:3)), 'vertical:hanging-down-seed')
  END SUBROUTINE case_vertical

  SUBROUTINE case_near_neutral_continuity()
    !! A near-neutral section must give seeds continuous in its weight down to exactly
    !! zero (no cancellation in the closed forms, no absolute weight switch).
    INTEGER, PARAMETER :: n = 45
    REAL(wp) :: lens(n), eav(n), wv(n), pos0(3*(n + 1)), pos1(3*(n + 1)), h, gl
    INTEGER  :: es0, es1
    CHARACTER(160) :: em
    lens = 10.0_wp; eav = 1.0e9_wp
    wv = 1000.0_wp; wv(11:30) = 0.0_wp
    CALL CD_Catenary_Seed([0.0_wp, 0.0_wp, -150.0_wp], [380.0_wp, 0.0_wp, 0.0_wp], lens, eav, wv, pos0, h, gl, &
                          es0, em)
    wv(11:30) = 1.0e-12_wp
    CALL CD_Catenary_Seed([0.0_wp, 0.0_wp, -150.0_wp], [380.0_wp, 0.0_wp, 0.0_wp], lens, eav, wv, pos1, h, gl, &
                          es1, em)
    CALL require(es0 == CD_CAT_OK .AND. es1 == CD_CAT_OK, 'neutral:seeds-ok')
    CALL require(nan_max_abs(pos1 - pos0) < 1.0e-8_wp, 'neutral:continuous-to-zero-weight')
  END SUBROUTINE case_near_neutral_continuity

  SUBROUTINE case_elevated_anchor()
    !! Anchor above a flat bed (seabed_z): the seed must not penetrate the bed. 1 mm of
    !! elevation reproduces the on-bed seed; 20 m of elevation is the exact three-part
    !! line (descent to a tangent touchdown, grounded run, ascent); a short line clears
    !! the bed as a fully suspended span.
    INTEGER, PARAMETER :: n = 52
    REAL(wp), PARAMETER :: w = (286.56_wp - 1025.0_wp*0.25_wp*3.14159265358979324_wp*0.216_wp**2)*9.80665_wp
    REAL(wp) :: lens(n), eav(n), wv(n), pos(3*(n + 1)), pos_bed(3*(n + 1)), h, gl, h_bed, gl_bed
    REAL(wp) :: prm(6), p3(3)
    INTEGER  :: es
    LOGICAL  :: ok
    CHARACTER(160) :: em
    lens = 520.0_wp/REAL(n, wp); eav = 1.2297600e9_wp; wv = w
    CALL CD_Catenary_Seed([450.0_wp, 0.0_wp, -100.0_wp], [0.0_wp, 0.0_wp, -10.0_wp], lens, eav, wv, pos_bed, &
                          h_bed, gl_bed, es, em)
    CALL require(es == CD_CAT_OK .AND. gl_bed > 0.0_wp, 'elevated:on-bed-reference')
    CALL CD_Catenary_Seed([450.0_wp, 0.0_wp, -99.999_wp], [0.0_wp, 0.0_wp, -10.0_wp], lens, eav, wv, pos, h, gl, &
                          es, em, seabed_z=-100.0_wp)
    CALL require(es == CD_CAT_OK .AND. gl > 0.0_wp, 'elevated-1mm:grounded-seed')
    CALL require(ABS(h - h_bed) < 1.0e-3_wp*h_bed .AND. nan_max_abs(pos - pos_bed) < 0.2_wp, &
                 'elevated-1mm:matches-on-bed-seed')
    CALL require(MINVAL(pos(3::3)) >= -100.0_wp - 1.0e-9_wp, 'elevated-1mm:no-penetration')
    ! 20 m elevation against the independent three-part closed form
    CALL CD_Catenary_Seed([450.0_wp, 0.0_wp, -80.0_wp], [0.0_wp, 0.0_wp, -10.0_wp], lens, eav, wv, pos, h, gl, &
                          es, em, seabed_z=-100.0_wp)
    CALL require(es == CD_CAT_OK .AND. gl > 0.0_wp, 'elevated-20m:touchdown-seed')
    CALL require(MINVAL(pos(3::3)) >= -100.0_wp - 1.0e-9_wp, 'elevated-20m:no-penetration')
    prm = [450.0_wp, 70.0_wp, 520.0_wp, 1.2297600e9_wp, w, 20.0_wp]
    p3 = [h, SQRT(400.0_wp + 40.0_wp*h/w), gl]
    CALL ref_newton3(p3, prm, ok)
    CALL require(ok .AND. ABS(h - p3(1)) < 1.0e-8_wp*p3(1) .AND. ABS(gl - p3(3)) < 1.0e-6_wp, &
                 'elevated-20m:exact-three-part-line')
    ! A short line hung from the elevated anchor clears the bed.
    lens = 460.0_wp/REAL(n, wp)
    CALL CD_Catenary_Seed([450.0_wp, 0.0_wp, -80.0_wp], [0.0_wp, 0.0_wp, -10.0_wp], lens, eav, wv, pos, h, gl, &
                          es, em, seabed_z=-100.0_wp)
    CALL require(es == CD_CAT_OK .AND. .NOT. (gl > 0.0_wp) .AND. MINVAL(pos(3::3)) > -100.0_wp, &
                 'elevated-20m:suspended-clears-bed')
  END SUBROUTINE case_elevated_anchor

  SUBROUTINE case_sloped_bed()
    !! Anchor on a planar sloped bed (seabed_slope): the grounded run follows the slope
    !! with the frictionless tension change w*sin(theta) per length and lifts off tangent
    !! to it. Checked against the independent closed form, for +/-0.5 degree slopes (from
    !! about 0.8 degrees up-slope this line's grounded run would be slack at the anchor,
    !! which has no equilibrium on a frictionless bed).
    INTEGER, PARAMETER :: n = 52
    REAL(wp) :: lens(n), eav(n), wv(n), pos(3*(n + 1)), h, gl, m, prm(6), p(2), s
    REAL(wp) :: slopes(2)
    INTEGER  :: es, k, node
    LOGICAL  :: ok
    CHARACTER(160) :: em
    slopes = [TAN(0.5_wp*3.14159265358979324_wp/180.0_wp), -TAN(0.5_wp*3.14159265358979324_wp/180.0_wp)]
    lens = 520.0_wp/REAL(n, wp); eav = 1.2e9_wp; wv = 2400.0_wp
    DO k = 1, 2
      m = slopes(k)
      CALL CD_Catenary_Seed([0.0_wp, 0.0_wp, -100.0_wp], [450.0_wp, 0.0_wp, -10.0_wp], lens, eav, wv, pos, h, gl, &
                            es, em, seabed_slope=m)
      CALL require(es == CD_CAT_OK .AND. gl > 0.0_wp, 'slope:grounded-seed')
      IF (es /= CD_CAT_OK) CYCLE
      prm = [450.0_wp, 90.0_wp, 520.0_wp, 1.2e9_wp, 2400.0_wp, m]
      p = [h, gl]
      CALL ref_newton(4, p, prm, ok)
      CALL require(ok .AND. ABS(h - p(1)) < 1.0e-8_wp*p(1) .AND. ABS(gl - p(2)) < 1.0e-6_wp, &
                   'slope:exact-grounded-run')
      DO node = 1, n + 1
        s = REAL(node - 1, wp)*520.0_wp/REAL(n, wp)
        CALL require(pos(3*node) >= -100.0_wp + m*pos(3*node - 2) - 1.0e-9_wp, 'slope:no-penetration')
        IF (s <= gl) CALL require(ABS(pos(3*node) - (-100.0_wp + m*pos(3*node - 2))) < 1.0e-9_wp, &
                                  'slope:grounded-nodes-on-bed')
      END DO
    END DO
    ! A heavy line is a convex curve between the chord and the bed: on a 0.1 up-slope it
    ! cannot be longer than the path along the bed and up to the fairlead,
    ! 450*SQRT(1.01) + (90 - 45) = 497.24 m. A longer line has no in-plane seed; a shorter
    ! one is not refused by the bound.
    lens = 520.0_wp/REAL(n, wp)
    CALL CD_Catenary_Seed([0.0_wp, 0.0_wp, -100.0_wp], [450.0_wp, 0.0_wp, -10.0_wp], lens, eav, wv, pos, h, gl, &
                          es, em, seabed_slope=0.1_wp)
    CALL require(es == CD_CAT_NOSEED, 'slope:too-long-for-the-bed-path-noseed')
    lens = 495.0_wp/REAL(n, wp)
    CALL CD_Catenary_Seed([0.0_wp, 0.0_wp, -100.0_wp], [450.0_wp, 0.0_wp, -10.0_wp], lens, eav, wv, pos, h, gl, &
                          es, em, seabed_slope=0.1_wp)
    CALL require(es /= CD_CAT_NOSEED, 'slope:within-the-bed-path-not-refused')
    ! down-slope the bed path is longer (450*SQRT(1.01) + 90 + 45 = 587.24 m)
    lens = 520.0_wp/REAL(n, wp)
    CALL CD_Catenary_Seed([0.0_wp, 0.0_wp, -100.0_wp], [450.0_wp, 0.0_wp, -10.0_wp], lens, eav, wv, pos, h, gl, &
                          es, em, seabed_slope=-0.1_wp)
    CALL require(es /= CD_CAT_NOSEED, 'slope:down-slope-bed-path-not-refused')
  END SUBROUTINE case_sloped_bed

  SUBROUTINE ref_residual(kind, p, prm, r)
    !! Independent closed-form endpoint equations (anchor at the origin). prm = [X, Z, L,
    !! EA, w, extra]. kind 1: flat grounded (H, g); 2: suspended (H, Va); 4: grounded on a
    !! slope extra = dz/dx (H at lift-off, g).
    INTEGER, INTENT(IN)   :: kind
    REAL(wp), INTENT(IN)  :: p(2), prm(6)
    REAL(wp), INTENT(OUT) :: r(2)
    REAL(wp) :: x, z
    CALL ref_point(kind, p, prm, prm(3), x, z)
    r = [x - prm(1), z - prm(2)]
  END SUBROUTINE ref_residual

  SUBROUTINE ref_point(kind, p, prm, s, x, z)
    !! Exact position at reference arc s for the closed forms of ref_residual.
    INTEGER, INTENT(IN)   :: kind
    REAL(wp), INTENT(IN)  :: p(2), prm(6), s
    REAL(wp), INTENT(OUT) :: x, z
    REAL(wp) :: hh, ea, w, g, sig, v0, v1, c, sn, ta, tl, ext
    hh = p(1); ea = prm(4); w = prm(5)
    SELECT CASE (kind)
    CASE (1)
      g = p(2)
      IF (s <= g) THEN
        x = s*(1.0_wp + hh/ea); z = 0.0_wp
      ELSE
        sig = s - g
        x = g*(1.0_wp + hh/ea) + hh*sig/ea + hh/w*ASINH(w*sig/hh)
        z = w*sig*sig/(2.0_wp*ea) + (HYPOT(hh, w*sig) - hh)/w
      END IF
    CASE (2)
      v0 = p(2); v1 = v0 + w*s
      x = hh*s/ea + hh/w*(ASINH(v1/hh) - ASINH(v0/hh))
      z = (v1*v1 - v0*v0)/(2.0_wp*w*ea) + (HYPOT(hh, v1) - HYPOT(hh, v0))/w
    CASE DEFAULT
      g = p(2)
      c = 1.0_wp/SQRT(1.0_wp + prm(6)**2); sn = prm(6)*c
      tl = hh/c
      ta = tl - w*sn*g
      IF (s <= g) THEN
        ext = s + s*(2.0_wp*ta + w*sn*s)/(2.0_wp*ea)
        x = c*ext; z = sn*ext
      ELSE
        ext = g + g*(ta + tl)/(2.0_wp*ea)
        sig = s - g
        v0 = hh*prm(6); v1 = v0 + w*sig
        x = c*ext + hh*sig/ea + hh/w*(ASINH(v1/hh) - ASINH(v0/hh))
        z = sn*ext + (v1*v1 - v0*v0)/(2.0_wp*w*ea) + (HYPOT(hh, v1) - HYPOT(hh, v0))/w
      END IF
    END SELECT
  END SUBROUTINE ref_point

  SUBROUTINE ref_newton(kind, p, prm, ok)
    !! Damped Newton with a forward-difference Jacobian on ref_residual.
    INTEGER, INTENT(IN)     :: kind
    REAL(wp), INTENT(INOUT) :: p(2)
    REAL(wp), INTENT(IN)    :: prm(6)
    LOGICAL, INTENT(OUT)    :: ok
    REAL(wp) :: r(2), rp(2), jac(2, 2), pp(2), dp(2), det, lam, nrm, tol
    INTEGER  :: it, c
    tol = 1.0e-11_wp*MAX(prm(1), ABS(prm(2)), 1.0_wp)
    ok = .FALSE.
    DO it = 1, 200
      CALL ref_residual(kind, p, prm, r)
      nrm = nan_max_abs(r)
      IF (nrm < tol) THEN
        ok = .TRUE.; RETURN
      END IF
      DO c = 1, 2
        ! Both unknowns of the suspended form are forces: a difference step scaled to the
        ! anchor vertical force alone (zero at the start) is lost in round-off against H.
        pp = p
        IF (kind == 2) THEN
          pp(c) = pp(c) + 1.0e-7_wp*MAX(1.0_wp, ABS(p(1)), ABS(p(2)))
        ELSE
          pp(c) = pp(c) + 1.0e-7_wp*MAX(1.0_wp, ABS(p(c)))
        END IF
        CALL ref_residual(kind, pp, prm, rp)
        jac(:, c) = (rp - r)/(pp(c) - p(c))
      END DO
      det = jac(1, 1)*jac(2, 2) - jac(1, 2)*jac(2, 1)
      dp = -[jac(2, 2)*r(1) - jac(1, 2)*r(2), -jac(2, 1)*r(1) + jac(1, 1)*r(2)]/det
      lam = 1.0_wp
      DO WHILE (p(1) + lam*dp(1) <= 0.0_wp .AND. lam > 1.0e-6_wp)
        lam = 0.5_wp*lam
      END DO
      ! Accept only a step that reduces the residual.
      DO WHILE (lam > 1.0e-6_wp)
        CALL ref_residual(kind, p + lam*dp, prm, rp)
        IF (nan_max_abs(rp) < nrm) EXIT
        lam = 0.5_wp*lam
      END DO
      p = p + lam*dp
      ! A step at round-off has converged even when the residual floor of the closed forms
      ! (which varies with the platform's libm) sits just above tol.
      IF (ALL(ABS(lam*dp) <= 1.0e-13_wp*MAX(1.0_wp, ABS(p)))) THEN
        CALL ref_residual(kind, p, prm, r)
        ok = nan_max_abs(r) < 1.0e3_wp*tol
        RETURN
      END IF
    END DO
  END SUBROUTINE ref_newton

  SUBROUTINE ref_newton3(p, prm, ok)
    !! Three-part line from an anchor at height prm(6) above a flat bed: descent of length
    !! p(2) to a vertex on the bed, grounded run p(3), ascent; unknown H = p(1). Residuals:
    !! horizontal span, fairlead height above the anchor, and descent height.
    REAL(wp), INTENT(INOUT) :: p(3)
    REAL(wp), INTENT(IN)    :: prm(6)
    LOGICAL, INTENT(OUT)    :: ok
    REAL(wp) :: r(3), rp(3), jac(3, 3), pp(3), dp(3), tol, d
    INTEGER  :: it, c
    tol = 1.0e-11_wp*MAX(prm(1), ABS(prm(2)), 1.0_wp)
    ok = .FALSE.
    DO it = 1, 200
      CALL ref_res3(p, prm, r)
      IF (nan_max_abs(r) < tol) THEN
        ok = .TRUE.; RETURN
      END IF
      DO c = 1, 3
        pp = p; pp(c) = pp(c) + 1.0e-7_wp*MAX(1.0_wp, ABS(p(c)))
        CALL ref_res3(pp, prm, rp)
        jac(:, c) = (rp - r)/(pp(c) - p(c))
      END DO
      d = det3(jac)
      dp(1) = det3(RESHAPE([-r, jac(:, 2), jac(:, 3)], [3, 3]))/d
      dp(2) = det3(RESHAPE([jac(:, 1), -r, jac(:, 3)], [3, 3]))/d
      dp(3) = det3(RESHAPE([jac(:, 1), jac(:, 2), -r], [3, 3]))/d
      p = p + dp
    END DO
  END SUBROUTINE ref_newton3

  SUBROUTINE ref_res3(q, prm, rr)
    !! Residuals of ref_newton3 (flat bed, uniform line, anchor height prm(6) above it).
    REAL(wp), INTENT(IN)  :: q(3), prm(6)
    REAL(wp), INTENT(OUT) :: rr(3)
    REAL(wp) :: hh, ea, w, sd, g, su, xd, hd, xu, zu
    hh = q(1); sd = q(2); g = q(3); ea = prm(4); w = prm(5)
    su = prm(3) - sd - g
    xd = hh/w*ASINH(w*sd/hh) + hh*sd/ea
    hd = (HYPOT(hh, w*sd) - hh)/w + w*sd*sd/(2.0_wp*ea)
    xu = hh/w*ASINH(w*su/hh) + hh*su/ea
    zu = (HYPOT(hh, w*su) - hh)/w + w*su*su/(2.0_wp*ea)
    rr = [xd + g*(1.0_wp + hh/ea) + xu - prm(1), zu - prm(6) - prm(2), hd - prm(6)]
  END SUBROUTINE ref_res3

  PURE REAL(wp) FUNCTION det3(a)
    REAL(wp), INTENT(IN) :: a(3, 3)
    det3 = a(1, 1)*(a(2, 2)*a(3, 3) - a(2, 3)*a(3, 2)) - a(1, 2)*(a(2, 1)*a(3, 3) - a(2, 3)*a(3, 1)) + &
           a(1, 3)*(a(2, 1)*a(3, 2) - a(2, 2)*a(3, 1))
  END FUNCTION det3

  SUBROUTINE expect(got, want, label)
    REAL(wp), INTENT(IN) :: got, want
    CHARACTER(*), INTENT(IN) :: label
    IF (.NOT. (ABS(got - want) <= PTOL)) THEN
      WRITE (*, '(A,A,A,ES22.14,A,ES22.14)') 'MISMATCH [', label, ']: got ', got, ' want ', want
      nfail = nfail + 1
    END IF
  END SUBROUTINE expect

  SUBROUTINE require(cond, label)
    LOGICAL, INTENT(IN) :: cond
    CHARACTER(*), INTENT(IN) :: label
    IF (.NOT. cond) THEN
      WRITE (*, '(A,A,A)') 'MISMATCH [', label, ']: condition false'
      nfail = nfail + 1
    END IF
  END SUBROUTINE require

END PROGRAM test_catenary
