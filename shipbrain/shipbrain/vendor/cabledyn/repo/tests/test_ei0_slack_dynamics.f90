! File: tests/test_ei0_slack_dynamics.f90
! SPDX-License-Identifier: Apache-2.0
! Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
PROGRAM test_ei0_slack_dynamics
  !! Tension-only (EI = 0) lines that go slack and snap taut, at the default rhoInf = 0.4:
  !!   1. A light, axially stiff cable (80 kg/m, EA 8e8 N, 115 x 2 m segments) under 3 m / 10 s
  !!      heave at dtM 0.1 s. The configuration-blended step reported 0.61 MN at the fairlead and
  !!      20 MN at the anchor; the force blend stays below 0.2 MN. This undamped EI = 0 deck has
  !!      no converged snap peak (it rises as dtM falls, to 0.32-0.46 MN at microsecond steps, as
  !!      single segments rattle); converged finite-EI runs give 0.093 MN at the fairlead and
  !!      0.057 MN at the anchor, so the bounds catch a spike or a lost snap, not a reference.
  !!   2. The same cable at dtM 0.01 s, where the force blend alone still fed a rattle of
  !!      single-step segment spikes (2.3 MN by 24 s) through the energy a release creates;
  !!      with the release cap every segment stays below 0.2 MN.
  !!   3. The shipped viscoelastic polyester (Es|Ed, Bs|Bd) under 15 m surge at dtM 0.1 s:
  !!      1.80 MN at the fairlead (2.69 MN configuration-blended), as at dtM 0.0025 s.
  !!   4. The run audit of the driver (stdout of the executable given as the first argument):
  !!      the configuration blend (False alpha_force_blend) of case 1 warns of a non-physical
  !!      tension spike and is not sub-stepped, the force blend does not warn; rhoInf above
  !!      0.95 prints its note; a 10 m sway at dtM 0.2 s prints the segment-turn advisory with
  !!      off ei0_substeps, and with the default auto is sub-stepped instead (reported; the turn
  !!      per solver step drops from about 6 deg to about 1.3 deg); the unresolved slack-to-taut
  !!      snaps of case 1 print the snap note.
  !!   5. The Newton tangent of the force-blended step against a central finite difference of its
  !!      residual (the step's probe_q hook), on a three-segment tension-only chain with one fixed
  !!      node: all segments taut at t_n and at the trial state (release cap inactive), a segment
  !!      taut at t_n and deeply slack at the trial state (cap active, its energy-gradient force
  !!      W_n/p on the projected shortening p and tangent), a segment slack at both states, and a
  !!      segment that turns by 45 degrees and ends slack (capped), taut at a tenth of its
  !!      tension (capped with the work of the end share) or taut at 3/4 of it (not capped);
  !!      each on the banded and the dense path. The residual is also checked against the closed
  !!      form. The blend of a segment that turns by 0 to 180 degrees within the step and ends
  !!      slack or taut returns at most its step-start strain energy W_n (up to 1100 W_n before
  !!      the cap took the projected shortening), one that keeps its direction and ends taut keeps
  !!      the plain force blend, and the force is continuous across the rest length.
  !!   6. The same chain with a segment whose tension-only law a load callback carries (ea = 0,
  !!      as the viscoelastic and Syrope segments of a line model): with its step-start tension
  !!      (start_tension) its release, deep or turning, is capped like an elastic one, closed
  !!      form and finite difference tangent; without it the segment keeps the plain force blend.
  !!      A damped law segment whose step-start tension is almost all damping at a vanishing
  !!      stretch: with its axial stiffness (start_stiffness) bounding the secant end tension,
  !!      the cap force varies with the end stretch at a slope of order that stiffness (a jump
  !!      with the unbounded secant), the blend keeps the stated energy bound, and the tangent
  !!      matches the finite difference. An elastic segment with a two-sided axial dashpot
  !!      (axial_damping) that extends at t_n and turns and releases within the step: the blend,
  !!      dashpot included, keeps the stated bound (W_n when it ends slack), a segment that keeps
  !!      its direction and ends taut keeps the plain force blend, the force is continuous at the
  !!      rest length and the band edge, and the tangent matches the finite difference.
  !!   7. The finite-difference tangent of the step with nonzero dynamic loads (a quadratic drag
  !!      and a cubic position load, plus a position-dependent added mass on the dense path), and
  !!      the closed form of the blended load (1 - alpha_f) f(q_{n+1}, v_{n+1}) + alpha_f f(q_n, v_n).
  !!   8. A warm re-solve of the same step (guess_armed, the junction coupling) reuses the
  !!      step-start force, load and release-cap data of the previous call: its solution equals a
  !!      cold solve bit for bit while the start data it is given are wrong (so they are not
  !!      read); after an unarmed call that fails before computing them, an armed call recomputes
  !!      them instead of reusing those of an older state.
  !!   9. A lightly damped viscoelastic version of the light cable at dtM 0.1 s (the cap on its
  !!      law segments) and a long taut Syrope line in 4 m surge that goes slack: no spike
  !!      warning, and peaks within the band of small-step references.
  !!  10. An elastic segment with an axial dashpot that is slack at t_n and whose ends separate
  !!      (or approach) there, then turn or reverse within the step: the kept dashpot share
  !!      returns at most the dashpot's one-step dissipation T_d,n |ldot_n| dt plus the end
  !!      share's credit (it returned many times that before the cap covered slack starts), a
  !!      slack segment with no step-start dashpot force keeps the plain blend, and the tangent
  !!      of a capped row matches the finite difference on the banded and the dense path.
  !!  11. A length change over the step (active line control) on the chain of case 5: the
  !!      step-start force and the release cap's step-start data at the lengths the step-start
  !!      state was reached with (start_l0), the inertia at the blended lengths (mass_l0); the
  !!      residual against the closed form and the tangent against the finite difference, also
  !!      for turning releases (the projected cap) and a haul-in whose end share alone returns more
  !!      than W_n; and, on the chain with a callback load, the dashpot share and the law bound of
  !!      the cap and the kept dashpot share of a segment slack at the step-start length (case 10)
  !!      under a length and rate change, against their closed forms.
  USE CableDyn_Precision, ONLY: wp
  USE CableDyn_DeckDriver, ONLY: CD_Run_Deck_Driver, CD_DECKDRV_OK
  USE CableDyn_Dynamic, ONLY: GenAlphaConfig, CD_CableGenAlphaWorkspace, CD_Cable_Gen_Alpha_Step, CD_DYN_OK
  IMPLICIT NONE

  REAL(wp), PARAMETER :: PI = 3.141592653589793238462643383279502884197_wp
  CHARACTER(*), PARAMETER :: CABLE = 'cable 0.2 80.0 8.0e8 0.0 0.0 1.2 0.1 1.0 0.0'
  CHARACTER(*), PARAMETER :: POLY_VE = 'poly_ve 0.1438 22.42 1.424e8|2.50e8 4.0e9|1.1e7 0.0 1.2 0.2 1.0 0.0'
  ! the light cable as a lightly damped viscoelastic line (Es|Ed, Bs|Bd)
  CHARACTER(*), PARAMETER :: CABLE_VE = 'cable 0.2 80.0 8.0e8|1.6e9 1.0e8|1.0e6 0.0 1.2 0.1 1.0 0.0'
  INTEGER :: nfail
  CHARACTER(1024) :: driver
  ! dynamic load of the chain cases 6 to 8 (host-associated by the load callbacks): nodal
  ! quadratic drag -cb_drag |v| v, nodal cubic load -cb_spring |q - cb_q0|^2 (q - cb_q0), the
  ! tension-only law (EA cb_ea_law, length cb_l0_law) of segment cb_law_elem (0: none), and the
  ! added mass cb_madd (1 + 0.3 z^2) per DOF of the dense path
  REAL(wp) :: cb_drag = 0.0_wp, cb_spring = 0.0_wp, cb_ea_law = 0.0_wp, cb_l0_law = 1.0_wp, cb_madd = 0.0_wp
  ! axial damping of the segment law, tension cb_ea_law (l/l0 - 1) + cb_ba_law (dl/dt)/l0
  REAL(wp) :: cb_ba_law = 0.0_wp
  ! a two-sided axial dashpot (BA cb_ba_dash, force cb_ba_dash (dl/dt)/l0 along the chord, as the
  ! line model's axial damping) on segment cb_dash_elem (0: none) of rest length cb_l0_dash
  REAL(wp) :: cb_ba_dash = 0.0_wp, cb_l0_dash = 1.0_wp
  ! the dashpot's unstretched-length rate (its force is then (BA/l0) (t . w - (l/l0) l0_dot) t)
  REAL(wp) :: cb_l0dot_dash = 0.0_wp
  INTEGER :: cb_dash_elem = 0
  REAL(wp) :: cb_q0(12) = 0.0_wp
  INTEGER :: cb_law_elem = 0

  nfail = 0
  driver = ''
  IF (COMMAND_ARGUMENT_COUNT() >= 1) CALL GET_COMMAND_ARGUMENT(1, driver)
  CALL case_tangent_consistency()
  CALL case_release_energy()
  CALL case_length_change_step()
  CALL case_length_change_cap_terms()
  CALL case_law_release_cap()
  CALL case_law_damped_release()
  CALL case_damped_elastic_release()
  CALL case_slack_dashpot_release()
  CALL case_load_share_tangent()
  CALL case_warm_resolve_reuse()
  CALL case_light_cable_coarse_step()
  CALL case_light_cable_release_cap()
  CALL case_viscoelastic_surge()
  IF (LEN_TRIM(driver) > 0) THEN
    CALL case_run_audit()
    CALL case_law_slack_runs()
  ELSE
    WRITE (*, '(A)') 'MISMATCH [audit: the driver executable is the first argument]'
    nfail = nfail + 1
  END IF

  IF (nfail > 0) THEN
    WRITE (*, '(A,I0,A)') 'FAIL: ', nfail, ' assertion(s) failed'
    ERROR STOP 1
  END IF
  WRITE (*, '(A)') 'PASS: EI = 0 slack-taut dynamics (force blend, release cap, run audit)'

CONTAINS

  SUBROUTINE require(cond, label)
    LOGICAL, INTENT(IN) :: cond
    CHARACTER(*), INTENT(IN) :: label
    IF (.NOT. cond) THEN
      WRITE (*, '(A)') 'MISMATCH ['//label//']'
      nfail = nfail + 1
    END IF
  END SUBROUTINE require

  SUBROUTINE write_motion(path, pid, x0, axis, amp, period, ramp, dt, tmax)
    !! Harmonic translation of one point, amp*r(t)*sin(w t), with the C2 quintic start-up
    !! ramp r over `ramp` seconds and its exact velocity and acceleration.
    CHARACTER(*), INTENT(IN) :: path
    INTEGER, INTENT(IN) :: pid, axis
    REAL(wp), INTENT(IN) :: x0(3), amp, period, ramp, dt, tmax
    INTEGER :: u, i, n
    REAL(wp) :: t, s, r, rd, rdd, w, p(3), v(3), a(3)
    OPEN (NEWUNIT=u, FILE=path, STATUS='REPLACE', ACTION='WRITE')
    WRITE (u, '(A)') '# time id x y z vx vy vz ax ay az'
    n = NINT(tmax/dt)
    w = 2.0_wp*PI/period
    DO i = 0, n
      t = REAL(i, wp)*dt
      s = MIN(t/ramp, 1.0_wp)
      r = 10.0_wp*s**3 - 15.0_wp*s**4 + 6.0_wp*s**5
      rd = 0.0_wp
      rdd = 0.0_wp
      IF (t < ramp) THEN
        rd = (30.0_wp*s**2 - 60.0_wp*s**3 + 30.0_wp*s**4)/ramp
        rdd = (60.0_wp*s - 180.0_wp*s**2 + 120.0_wp*s**3)/ramp**2
      END IF
      p = x0
      v = 0.0_wp
      a = 0.0_wp
      p(axis) = p(axis) + amp*r*SIN(w*t)
      v(axis) = amp*(rd*SIN(w*t) + r*w*COS(w*t))
      a(axis) = amp*(rdd*SIN(w*t) + 2.0_wp*rd*w*COS(w*t) - r*w*w*SIN(w*t))
      WRITE (u, '(ES17.10,1X,I0,9(1X,ES17.10))') t, pid, p, v, a
    END DO
    CLOSE (u)
  END SUBROUTINE write_motion

  SUBROUTINE write_deck(path, linetype, anchor, fairlead, length, nseg, depth, outputs, options)
    !! One line from a Coupled fairlead (point 1, End A) to a Fixed anchor (point 2).
    CHARACTER(*), INTENT(IN) :: path, linetype, outputs, options(:)
    REAL(wp), INTENT(IN) :: anchor(3), fairlead(3), length, depth
    INTEGER, INTENT(IN) :: nseg
    INTEGER :: u, i
    CHARACTER(32) :: name
    OPEN (NEWUNIT=u, FILE=path, STATUS='REPLACE', ACTION='WRITE')
    WRITE (u, '(A)') 'EI = 0 slack-taut dynamics regression deck'
    WRITE (u, '(A)') '--- LINE TYPES ---'
    WRITE (u, '(A)') 'Name Diam Mass EA BA EI Cdn Cdt Can Cat'
    WRITE (u, '(A)') '(-) (m) (kg/m) (N) (-) (Nm2) (-) (-) (-) (-)'
    WRITE (u, '(A)') TRIM(linetype)
    READ (linetype, *) name
    WRITE (u, '(A)') '--- POINTS ---'
    WRITE (u, '(A)') 'ID Type X Y Z Mass Vol CdA Ca'
    WRITE (u, '(A)') '(-) (-) (m) (m) (m) (kg) (m^3) (m^2) (-)'
    WRITE (u, '(A,3(1X,ES16.9),A)') '1 Coupled', fairlead, ' 0 0 0 0'
    WRITE (u, '(A,3(1X,ES16.9),A)') '2 Fixed', anchor, ' 0 0 0 0'
    WRITE (u, '(A)') '--- LINES ---'
    WRITE (u, '(A)') 'ID NodeA NodeB Outputs'
    WRITE (u, '(A)') '(-) (-) (-) (-)'
    WRITE (u, '(A,A)') '1 1 2 ', outputs
    WRITE (u, '(A)') '--- SECTIONS ---'
    WRITE (u, '(A)') 'LineID LineType Length NumSegs'
    WRITE (u, '(A)') '(-) (-) (m) (-)'
    WRITE (u, '(A,A,1X,ES16.9,1X,I0)') '1 ', TRIM(name), length, nseg
    WRITE (u, '(A)') '--- OPTIONS ---'
    WRITE (u, '(ES16.9,A)') depth, ' WtrDpth'
    DO i = 1, SIZE(options)
      IF (LEN_TRIM(options(i)) > 0) WRITE (u, '(A)') TRIM(options(i))
    END DO
    WRITE (u, '(A)') '--- OUTPUTS ---'
    WRITE (u, '(A)') 'FairTen1 AnchTen1'
    WRITE (u, '(A)') '--- end ---'
    CLOSE (u)
  END SUBROUTINE write_deck

  SUBROUTINE light_cable_deck(path, dt, tmax, extra, outputs)
    !! The light, axially stiff cable from the fairlead (5, 0, -14) to the anchor (205, 0, -80),
    !! 230 m in 115 segments, heaving 3 m at 10 s after a 10 s ramp.
    CHARACTER(*), INTENT(IN) :: path, extra, outputs
    REAL(wp), INTENT(IN) :: dt, tmax
    CHARACTER(64) :: opts(4)
    CALL write_motion('ei0slack_heave.txt', 1, [5.0_wp, 0.0_wp, -14.0_wp], 3, 3.0_wp, 10.0_wp, 10.0_wp, dt, tmax)
    WRITE (opts(1), '(ES14.7,A)') dt, ' dtM'
    WRITE (opts(2), '(ES14.7,A)') tmax, ' TMax'
    opts(3) = 'ei0slack_heave.txt motionFile'
    opts(4) = extra
    CALL write_deck(path, CABLE, [205.0_wp, 0.0_wp, -80.0_wp], [5.0_wp, 0.0_wp, -14.0_wp], 230.0_wp, 115, 80.0_wp, &
                    outputs, opts)
  END SUBROUTINE light_cable_deck

  SUBROUTINE read_out(path, data, nrow)
    !! Numeric rows of a driver output file (comment and header lines skipped).
    CHARACTER(*), INTENT(IN) :: path
    REAL(wp), ALLOCATABLE, INTENT(OUT) :: data(:, :)
    INTEGER, INTENT(OUT) :: nrow
    INTEGER :: u, ios, ncol, k
    CHARACTER(8192) :: line
    LOGICAL :: header_seen
    REAL(wp), ALLOCATABLE :: grow(:, :)
    nrow = 0
    ncol = 0
    header_seen = .FALSE.
    ALLOCATE (data(0, 0))
    OPEN (NEWUNIT=u, FILE=path, STATUS='OLD', ACTION='READ', IOSTAT=ios)
    IF (ios /= 0) RETURN
    DO
      READ (u, '(A)', IOSTAT=ios) line
      IF (ios /= 0) EXIT
      IF (line(1:1) == '#' .OR. LEN_TRIM(line) == 0) CYCLE
      IF (.NOT. header_seen) THEN
        header_seen = .TRUE.
        ncol = count_tokens(line)
        DEALLOCATE (data)
        ALLOCATE (data(ncol, 64))
        CYCLE
      END IF
      IF (nrow == SIZE(data, 2)) THEN
        ALLOCATE (grow(ncol, 2*SIZE(data, 2)))
        grow(:, 1:nrow) = data(:, 1:nrow)
        CALL MOVE_ALLOC(grow, data)
      END IF
      nrow = nrow + 1
      READ (line, *) (data(k, nrow), k=1, ncol)
    END DO
    CLOSE (u)
  END SUBROUTINE read_out

  INTEGER FUNCTION count_tokens(line) RESULT(n)
    CHARACTER(*), INTENT(IN) :: line
    INTEGER :: i
    LOGICAL :: inside
    n = 0
    inside = .FALSE.
    DO i = 1, LEN_TRIM(line)
      IF (line(i:i) == ' ' .OR. line(i:i) == CHAR(9)) THEN
        inside = .FALSE.
      ELSE IF (.NOT. inside) THEN
        inside = .TRUE.
        n = n + 1
      END IF
    END DO
  END FUNCTION count_tokens

  REAL(wp) FUNCTION column_max(path, first_col, last_col) RESULT(mx)
    !! Largest value of the columns first_col..last_col (last_col 0: through the last column).
    CHARACTER(*), INTENT(IN) :: path
    INTEGER, INTENT(IN) :: first_col, last_col
    REAL(wp), ALLOCATABLE :: d(:, :)
    INTEGER :: nrow, lc
    mx = -HUGE(1.0_wp)
    CALL read_out(path, d, nrow)
    IF (nrow < 1) RETURN
    lc = last_col
    IF (lc == 0) lc = SIZE(d, 1)
    mx = MAXVAL(d(first_col:lc, 1:nrow))
  END FUNCTION column_max

  LOGICAL FUNCTION file_contains(path, needle) RESULT(found)
    CHARACTER(*), INTENT(IN) :: path, needle
    INTEGER :: u, ios
    CHARACTER(4096) :: line
    found = .FALSE.
    OPEN (NEWUNIT=u, FILE=path, STATUS='OLD', ACTION='READ', IOSTAT=ios)
    IF (ios /= 0) RETURN
    DO
      READ (u, '(A)', IOSTAT=ios) line
      IF (ios /= 0) EXIT
      IF (INDEX(line, needle) > 0) THEN
        found = .TRUE.
        EXIT
      END IF
    END DO
    CLOSE (u)
  END FUNCTION file_contains

  REAL(wp) FUNCTION noted_turn(path) RESULT(turn)
    !! The turn (deg) of the run audit's segment-turn note in a driver log, 0 without the note.
    CHARACTER(*), INTENT(IN) :: path
    CHARACTER(*), PARAMETER :: KEY = 'a taut segment turned up to'
    INTEGER :: u, ios, i
    CHARACTER(4096) :: line
    turn = 0.0_wp
    OPEN (NEWUNIT=u, FILE=path, STATUS='OLD', ACTION='READ', IOSTAT=ios)
    IF (ios /= 0) RETURN
    DO
      READ (u, '(A)', IOSTAT=ios) line
      IF (ios /= 0) EXIT
      i = INDEX(line, KEY)
      IF (i > 0) THEN
        READ (line(i + LEN(KEY):), *, IOSTAT=ios) turn
        IF (ios /= 0) turn = -1.0_wp
        EXIT
      END IF
    END DO
    CLOSE (u)
  END FUNCTION noted_turn

  SUBROUTINE echo_tail(path, n)
    !! Print the last n lines of a log (the reason a driver run stopped).
    CHARACTER(*), INTENT(IN) :: path
    INTEGER, INTENT(IN) :: n
    CHARACTER(4096) :: ring(16), line
    INTEGER :: u, ios, k, m, i
    m = MIN(MAX(n, 1), SIZE(ring))
    k = 0
    OPEN (NEWUNIT=u, FILE=path, STATUS='OLD', ACTION='READ', IOSTAT=ios)
    IF (ios /= 0) RETURN
    DO
      READ (u, '(A)', IOSTAT=ios) line
      IF (ios /= 0) EXIT
      k = k + 1
      ring(MOD(k - 1, m) + 1) = line
    END DO
    CLOSE (u)
    WRITE (*, '(A)') '  --- end of '//path//':'
    DO i = MAX(1, k - m + 1), k
      WRITE (*, '(A)') '  '//TRIM(ring(MOD(i - 1, m) + 1))
    END DO
  END SUBROUTINE echo_tail

  SUBROUTINE run_driver_logged(deck, root, log, ok)
    !! Run the driver executable on a deck, its stdout and stderr to log.
    CHARACTER(*), INTENT(IN) :: deck, root, log
    LOGICAL, INTENT(OUT) :: ok
    INTEGER :: ex, cs
    CALL EXECUTE_COMMAND_LINE('"'//TRIM(driver)//'" '//deck//' '//root//' > '//log//' 2>&1', &
                              WAIT=.TRUE., EXITSTAT=ex, CMDSTAT=cs)
    ok = cs == 0 .AND. ex == 0
  END SUBROUTINE run_driver_logged

  SUBROUTINE zero_load(q, v, force, jac_q, jac_v, ErrStat, ErrMsg)
    !! No dynamic load; selects the dense (load_proc) path of the step.
    REAL(wp), INTENT(IN) :: q(:), v(:)
    REAL(wp), INTENT(OUT) :: force(:), jac_q(:, :), jac_v(:, :)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    force = 0.0_wp
    jac_q = 0.0_wp
    jac_v = 0.0_wp
    ErrStat = 0
    ErrMsg = ''
  END SUBROUTINE zero_load

  SUBROUTINE chain_nodes(dirs, strain, l0, q)
    !! Nodes of the chain from the fixed node at the origin: segment e runs along dirs(:, e)
    !! with the length l0(e)*(1 + strain(e)).
    REAL(wp), INTENT(IN) :: dirs(3, 3), strain(3), l0(3)
    REAL(wp), INTENT(OUT) :: q(12)
    INTEGER :: e
    q(1:3) = 0.0_wp
    DO e = 1, 3
      q(3*e + 1:3*e + 3) = q(3*e - 2:3*e) + dirs(:, e)/NORM2(dirs(:, e))*l0(e)*(1.0_wp + strain(e))
    END DO
  END SUBROUTINE chain_nodes

  SUBROUTINE blended_force(qn, q1, l0, ea, alpha_f, capped, f, l0s)
    !! Closed form of the blended internal force (1 - alpha_f) f(q1) + alpha_f f(qn) of the
    !! tension-only chain, with the release cap (capped) or without it: the retained share
    !! alpha_f T_n along the step-start chord t_n is at most
    !! (W_n + (1 - alpha_f) T^_1 p_1)/p, W_n = T_n e_n/2, with the projected shortening
    !! p = |d_n| - t_n . d_1 and p_1 = |d_1| - t_1 . d_n, so that the blend returns at most W_n
    !! (T^_1 = T_1 without a length change). l0s: the lengths of the step-start state (f(qn),
    !! T_n and e_n) when they differ from the lengths l0 at t_{n+1}; the cap's end-tension
    !! estimate is then the step-start secant times the end stretch, T^_1 = (T_n/e_n) e_1,
    !! and N is bounded below by zero.
    REAL(wp), INTENT(IN) :: qn(12), q1(12), l0(3), ea(3), alpha_f
    LOGICAL, INTENT(IN) :: capped
    REAL(wp), INTENT(OUT) :: f(12)
    REAL(wp), INTENT(IN), OPTIONAL :: l0s(3)
    INTEGER :: e
    REAL(wp) :: dn(3), d1(3), ln, l1, t0, t1, t1h, e0, e1, dg, p, p1, share(3), ls(3)
    ls = l0
    IF (PRESENT(l0s)) ls = l0s
    f = 0.0_wp
    DO e = 1, 3
      dn = qn(3*e + 1:3*e + 3) - qn(3*e - 2:3*e)
      d1 = q1(3*e + 1:3*e + 3) - q1(3*e - 2:3*e)
      ln = NORM2(dn)
      l1 = NORM2(d1)
      t0 = MAX(0.0_wp, ea(e)*(ln/ls(e) - 1.0_wp))
      t1 = MAX(0.0_wp, ea(e)*(l1/l0(e) - 1.0_wp))
      e0 = ln - ls(e)
      e1 = l1 - l0(e)
      dg = alpha_f*t0
      p = ln - DOT_PRODUCT(dn/ln, d1)
      p1 = l1 - DOT_PRODUCT(d1/l1, dn)
      t1h = t1
      IF (PRESENT(l0s) .AND. e0 > 0.0_wp) t1h = t0/e0*MAX(e1, 0.0_wp)
      IF (capped .AND. t0 > 0.0_wp .AND. p > 0.0_wp) &
        dg = MIN(dg, MAX(0.5_wp*t0*e0 + (1.0_wp - alpha_f)*t1h*p1, 0.0_wp)/p)
      share = (1.0_wp - alpha_f)*t1*d1/l1 + dg*dn/ln
      f(3*e - 2:3*e) = f(3*e - 2:3*e) - share
      f(3*e + 1:3*e + 3) = f(3*e + 1:3*e + 3) + share
    END DO
  END SUBROUTINE blended_force

  SUBROUTINE probe_step(qn, vn, an, q1, l0, ea, rho_a, dense, R, K, start_l0, mass_l0)
    !! Residual and effective tangent of the force-blended step at q1 (the probe_q hook);
    !! start_l0 and mass_l0 are passed on to the step (a length change over the step).
    REAL(wp), INTENT(IN) :: qn(12), vn(12), an(12), q1(12), l0(3), ea(3), rho_a(3)
    LOGICAL, INTENT(IN) :: dense
    REAL(wp), INTENT(OUT) :: R(12), K(9, 9)
    REAL(wp), INTENT(IN), OPTIONAL :: start_l0(3), mass_l0(3)
    INTEGER :: conn(2, 3), n_iter, es
    REAL(wp) :: qo(12), vo(12), ao(12)
    LOGICAL :: converged, stalled
    TYPE(GenAlphaConfig) :: cfg
    TYPE(CD_CableGenAlphaWorkspace) :: work
    CHARACTER(120) :: em
    conn = RESHAPE([1, 2, 2, 3, 3, 4], [2, 3])
    cfg%rho_inf = 0.4_wp
    IF (dense) THEN
      CALL CD_Cable_Gen_Alpha_Step(qn, vn, an, conn, l0, ea, rho_a, .TRUE., 0.0_wp*qn, [1, 2, 3], 0.05_wp, cfg, &
                                   qo, vo, ao, converged, stalled, n_iter, es, em, load_proc=zero_load, &
                                   workspace=work, probe_q=q1, probe_R=R, probe_K=K, start_l0=start_l0, &
                                   mass_l0=mass_l0)
    ELSE
      CALL CD_Cable_Gen_Alpha_Step(qn, vn, an, conn, l0, ea, rho_a, .TRUE., 0.0_wp*qn, [1, 2, 3], 0.05_wp, cfg, &
                                   qo, vo, ao, converged, stalled, n_iter, es, em, &
                                   workspace=work, probe_q=q1, probe_R=R, probe_K=K, start_l0=start_l0, &
                                   mass_l0=mass_l0)
    END IF
    IF (es /= CD_DYN_OK) THEN
      WRITE (*, '(A)') 'MISMATCH [tangent:probe '//TRIM(em)//']'
      nfail = nfail + 1
      R = 0.0_wp
      K = 0.0_wp
    END IF
  END SUBROUTINE probe_step

  SUBROUTINE tangent_config(label, strain_n, strain_1, expect_cap, dirs_trial)
    !! One configuration of the three-segment chain (node 1 fixed): segment strains at t_n and
    !! at the trial state of the step, t_n at rest but for a small velocity and acceleration.
    !! dirs_trial: the segment directions at the trial state (default: turned a few degrees).
    CHARACTER(*), INTENT(IN) :: label
    REAL(wp), INTENT(IN) :: strain_n(3), strain_1(3)
    LOGICAL, INTENT(IN) :: expect_cap
    REAL(wp), INTENT(IN), OPTIONAL :: dirs_trial(3, 3)
    REAL(wp), PARAMETER :: L0(3) = [1.0_wp, 1.2_wp, 0.8_wp], EA(3) = [1.0e6_wp, 1.5e6_wp, 0.8e6_wp]
    REAL(wp), PARAMETER :: DIRS_N(3, 3) = RESHAPE([1.0_wp, 0.2_wp, 0.1_wp, 0.3_wp, 1.0_wp, -0.2_wp, &
                                                   -0.2_wp, 0.4_wp, 1.0_wp], [3, 3])
    REAL(wp), PARAMETER :: DIRS_1(3, 3) = RESHAPE([1.0_wp, 0.27_wp, 0.04_wp, 0.36_wp, 1.0_wp, -0.12_wp, &
                                                   -0.12_wp, 0.46_wp, 1.0_wp], [3, 3])
    REAL(wp), PARAMETER :: H = 1.0e-6_wp, ALPHA_F = 0.4_wp/1.4_wp
    INTEGER :: p, j, free(9), i
    REAL(wp) :: qn(12), vn(12), an(12), q1(12), qp(12), rho_a(3), R(12), Rp(12), Rm(12), K(9, 9), Kfd(9, 9)
    REAL(wp) :: Kdump(9, 9), f_cap(12), f_raw(12), scale, err
    LOGICAL :: dense
    free = [(i + 3, i=1, 9)]
    CALL chain_nodes(DIRS_N, strain_n, L0, qn)
    IF (PRESENT(dirs_trial)) THEN
      CALL chain_nodes(dirs_trial, strain_1, L0, q1)
    ELSE
      CALL chain_nodes(DIRS_1, strain_1, L0, q1)
    END IF
    vn = 0.0_wp
    an = 0.0_wp
    DO i = 4, 12
      vn(i) = 0.01_wp*SIN(1.7_wp*REAL(i, wp))
      an(i) = 0.02_wp*COS(2.3_wp*REAL(i, wp))
    END DO
    ! the closed-form blended force: the residual of a nearly massless chain is the force
    rho_a = 1.0e-9_wp
    CALL probe_step(qn, 0.0_wp*vn, 0.0_wp*an, q1, L0, EA, rho_a, .FALSE., R, Kdump)
    CALL blended_force(qn, q1, L0, EA, ALPHA_F, .TRUE., f_cap)
    CALL blended_force(qn, q1, L0, EA, ALPHA_F, .FALSE., f_raw)
    scale = MAXVAL(ABS(f_raw))
    CALL require(MAXVAL(ABS(R(4:12) - f_cap(4:12))) < 1.0e-6_wp*scale, 'tangent:'//label//':residual-closed-form')
    IF (expect_cap) THEN
      CALL require(MAXVAL(ABS(f_cap - f_raw)) > 1.0e-2_wp*scale, 'tangent:'//label//':cap-active')
    ELSE
      CALL require(MAXVAL(ABS(f_cap - f_raw)) < 1.0e-12_wp*scale, 'tangent:'//label//':cap-inactive')
    END IF
    ! the tangent against the central difference of the residual, with inertia
    rho_a = [2.0_wp, 3.0_wp, 1.5_wp]
    DO p = 1, 2
      dense = p == 2
      CALL probe_step(qn, vn, an, q1, L0, EA, rho_a, dense, R, K)
      DO j = 1, 9
        qp = q1
        qp(free(j)) = q1(free(j)) + H
        CALL probe_step(qn, vn, an, qp, L0, EA, rho_a, dense, Rp, Kdump)
        qp(free(j)) = q1(free(j)) - H
        CALL probe_step(qn, vn, an, qp, L0, EA, rho_a, dense, Rm, Kdump)
        Kfd(:, j) = (Rp(4:12) - Rm(4:12))/(2.0_wp*H)
      END DO
      scale = MAXVAL(ABS(K))
      err = MAXVAL(ABS(K - Kfd))/scale
      WRITE (*, '(A,A,A,L1,A,ES9.2)') '  tangent ', label, ' dense=', dense, ': max |K - K_fd|/max|K| = ', err
      CALL require(err < 1.0e-8_wp, 'tangent:'//label//TRIM(MERGE(':dense ', ':banded', dense))//':fd-tangent')
    END DO
  END SUBROUTINE tangent_config

  SUBROUTINE case_tangent_consistency()
    ! segment 1 turned by 45 degrees from (1, 0.2, 0.1), the others as in DIRS_1
    REAL(wp), PARAMETER :: DIRS_TURN(3, 3) = RESHAPE([0.6_wp, 0.9_wp, 0.1_wp, 0.36_wp, 1.0_wp, -0.12_wp, &
                                                      -0.12_wp, 0.46_wp, 1.0_wp], [3, 3])
    ! (a) all segments taut at t_n and at the trial state: the cap is inactive
    CALL tangent_config('taut-taut', [0.010_wp, 0.020_wp, 0.010_wp], [0.020_wp, 0.015_wp, 0.020_wp], .FALSE.)
    ! (b) segment 1 taut at t_n and deeply slack at the trial state (release deeper than
    !     0.75 e_n, turned a few degrees): it carries the energy gradient W_n/p on its projected
    !     shortening p instead of alpha_f T_n
    CALL tangent_config('release-cap', [0.010_wp, 0.020_wp, 0.010_wp], [-0.050_wp, 0.015_wp, 0.020_wp], .TRUE.)
    ! (c) segment 2 slack at both states
    CALL tangent_config('slack-slack', [0.010_wp, -0.020_wp, 0.010_wp], [0.020_wp, -0.030_wp, 0.015_wp], .FALSE.)
    ! (d) segment 1 turns by 45 degrees and ends 0.05 % slack, a quarter of its stretch e_n
    !     below the rest length (the former cap on e_n - e_{n+1} left it uncapped), but shortens
    !     by about 150 e_n along its step-start chord: capped at W_n/p
    CALL tangent_config('turning-release', [0.002_wp, 0.020_wp, 0.010_wp], [-0.0005_wp, 0.015_wp, 0.020_wp], &
                        .TRUE., DIRS_TURN)
    ! (e) the same turn ending taut at a tenth of its step-start tension: capped with the work
    !     of the end share, (W_n + (1 - alpha_f) T_1 p_1)/p
    CALL tangent_config('turning-taut-release', [0.002_wp, 0.020_wp, 0.010_wp], [0.0002_wp, 0.015_wp, 0.020_wp], &
                        .TRUE., DIRS_TURN)
    ! (f) the same turn ending at 3/4 of its step-start tension: the force blend is kept
    CALL tangent_config('turning-taut', [0.002_wp, 0.020_wp, 0.010_wp], [0.0015_wp, 0.015_wp, 0.020_wp], &
                        .FALSE., DIRS_TURN)
  END SUBROUTINE case_tangent_consistency

  SUBROUTINE case_release_energy()
    !! Energy of the force blend over one step of a segment that turns while it releases: the
    !! end segment of the chain (l0 0.8 m, EA 0.8e6 N, stretch e_n = 0.8 mm, W_n = 0.32 J) turns
    !! by theta about an axis normal to its chord and ends at the strain s1, slack or taut, the
    !! rest of the chain held. The blended force on its free node returns the work
    !! W = -f . (x_{n+1} - x_n) to the motion; the retained share alone (slack end) or with the
    !! end share (taut end) must return at most W_n. Before the projected cap the 90 degree turn
    !! of a segment that ends 0.1 % slack returned 160 J.
    REAL(wp), PARAMETER :: L0(3) = [1.0_wp, 1.2_wp, 0.8_wp], EA(3) = [1.0e6_wp, 1.5e6_wp, 0.8e6_wp]
    REAL(wp), PARAMETER :: DIRS(3, 3) = RESHAPE([1.0_wp, 0.2_wp, 0.1_wp, 0.3_wp, 1.0_wp, -0.2_wp, &
                                                 -0.2_wp, 0.4_wp, 1.0_wp], [3, 3])
    REAL(wp), PARAMETER :: THETA(8) = [0.0_wp, 2.0_wp, 5.0_wp, 20.0_wp, 45.0_wp, 90.0_wp, 135.0_wp, 180.0_wp]
    REAL(wp), PARAMETER :: S1(11) = [-0.5_wp, -0.01_wp, -1.0e-3_wp, -1.0e-4_wp, -1.0e-12_wp, 1.0e-12_wp, &
                                     1.0e-4_wp, 2.0e-4_wp, 5.0e-4_wp, 1.0e-3_wp, 2.0e-3_wp]
    REAL(wp) :: qn(12), q1(12), z(12), R(12), Rm(12), K(9, 9), tn(3), u(3), dir(3), w0, wk, wmax, ratio, jump
    REAL(wp) :: f_raw(12), dev
    INTEGER :: i, j
    CALL chain_nodes(DIRS, [0.010_wp, 0.020_wp, 0.001_wp], L0, qn)
    z = 0.0_wp
    tn = (qn(10:12) - qn(7:9))/NORM2(qn(10:12) - qn(7:9))
    u = [tn(2), -tn(1), 0.0_wp]
    u = u/NORM2(u)
    w0 = 0.5_wp*(EA(3)*0.001_wp)*(L0(3)*0.001_wp)
    wmax = -HUGE(1.0_wp)
    DO i = 1, SIZE(THETA)
      DO j = 1, SIZE(S1)
        dir = COS(THETA(i)*PI/180.0_wp)*tn + SIN(THETA(i)*PI/180.0_wp)*u
        q1 = qn
        q1(10:12) = qn(7:9) + L0(3)*(1.0_wp + S1(j))*dir
        ! a nearly massless chain at rest at t_n: the residual is the blended force
        CALL probe_step(qn, z, z, q1, L0, EA, [1.0e-12_wp, 1.0e-12_wp, 1.0e-12_wp], .FALSE., R, K)
        wk = -DOT_PRODUCT(R(10:12), q1(10:12) - qn(10:12))
        wmax = MAX(wmax, wk/w0)
        IF (THETA(i) == 0.0_wp .AND. S1(j) > 0.0_wp) THEN
          ! a segment that keeps its direction and ends taut keeps the plain force blend
          CALL blended_force(qn, q1, L0, EA, 0.4_wp/1.4_wp, .FALSE., f_raw)
          dev = MAXVAL(ABS(R(10:12) - f_raw(10:12)))
          CALL require(dev < 1.0e-9_wp*EA(3)*0.001_wp, 'release-energy:taut-end-uncapped')
        END IF
        IF (.NOT. wk <= w0*(1.0_wp + 1.0e-9_wp)) THEN
          WRITE (*, '(A,F6.1,A,ES10.2,A,ES10.3,A,ES10.3,A)') '  release energy: theta ', THETA(i), ' s1 ', S1(j), &
            ': returned ', wk, ' J, W_n ', w0, ' J'
          CALL require(.FALSE., 'release-energy:bounded')
        END IF
      END DO
    END DO
    WRITE (*, '(A,ES10.3)') '  release energy: largest returned work / W_n over the turns = ', wmax
    ! the retained force is continuous where the end state crosses the rest length (turned 45 deg)
    dir = COS(PI/4.0_wp)*tn + SIN(PI/4.0_wp)*u
    q1 = qn
    q1(10:12) = qn(7:9) + L0(3)*(1.0_wp + 1.0e-12_wp)*dir
    CALL probe_step(qn, z, z, q1, L0, EA, [1.0e-12_wp, 1.0e-12_wp, 1.0e-12_wp], .FALSE., R, K)
    q1(10:12) = qn(7:9) + L0(3)*(1.0_wp - 1.0e-12_wp)*dir
    CALL probe_step(qn, z, z, q1, L0, EA, [1.0e-12_wp, 1.0e-12_wp, 1.0e-12_wp], .FALSE., Rm, K)
    jump = MAXVAL(ABS(R(10:12) - Rm(10:12)))
    ratio = jump/(EA(3)*0.001_wp)
    WRITE (*, '(A,ES10.3)') '  release energy: force jump across the rest length / T_n = ', ratio
    CALL require(ratio < 1.0e-6_wp, 'release-energy:continuous-at-rest-length')
  END SUBROUTINE case_release_energy

  SUBROUTINE case_length_change_step()
    !! A length change over the step (active line control): segment 1 paid out (0.97 to 1.0 m),
    !! segment 3 hauled in (0.83 to 0.8 m). The step-start force and the release cap's
    !! step-start tension and stretch take the lengths the step-start state was reached with
    !! (start_l0), the force at t_{n+1} and the cap's end stretch the new ones (l0), and the
    !! structural inertia the blended ones (mass_l0): residual against the closed form (force
    !! and inertia) and tangent against the central difference of the residual, with all
    !! segments taut, segment 1 released deeply (cap active), segment 1 turning by 45 degrees
    !! as it ends just slack (projected cap), the hauled-in segment 3 turning by about 50
    !! degrees and ending taut (capped with the end share at the secant estimate
    !! T^_1 = (T_n/e_n) e_1), and segment 3 shortening along its chord while it stretches
    !! against its new length (the end share alone returns more than W_n: kept force zero), on
    !! both paths.
    REAL(wp), PARAMETER :: L0(3) = [1.0_wp, 1.2_wp, 0.8_wp], L0S(3) = [0.97_wp, 1.2_wp, 0.83_wp]
    REAL(wp), PARAMETER :: EA(3) = [1.0e6_wp, 1.5e6_wp, 0.8e6_wp], RHO_A(3) = [2.0_wp, 3.0_wp, 1.5_wp]
    REAL(wp), PARAMETER :: DIRS_N(3, 3) = RESHAPE([1.0_wp, 0.2_wp, 0.1_wp, 0.3_wp, 1.0_wp, -0.2_wp, &
                                                   -0.2_wp, 0.4_wp, 1.0_wp], [3, 3])
    REAL(wp), PARAMETER :: DIRS_1(3, 3) = RESHAPE([1.0_wp, 0.27_wp, 0.04_wp, 0.36_wp, 1.0_wp, -0.12_wp, &
                                                   -0.12_wp, 0.46_wp, 1.0_wp], [3, 3])
    REAL(wp), PARAMETER :: H = 1.0e-6_wp, RHO = 0.4_wp, DT = 0.05_wp
    REAL(wp), PARAMETER :: ALPHA_F = RHO/(RHO + 1.0_wp), ALPHA_M = (2.0_wp*RHO - 1.0_wp)/(RHO + 1.0_wp)
    REAL(wp), PARAMETER :: BETA = 0.25_wp*(1.0_wp - ALPHA_M + ALPHA_F)**2
    REAL(wp), PARAMETER :: DIRS_T1(3, 3) = RESHAPE([0.6_wp, 0.9_wp, 0.1_wp, 0.36_wp, 1.0_wp, -0.12_wp, &
                                                    -0.12_wp, 0.46_wp, 1.0_wp], [3, 3])
    REAL(wp), PARAMETER :: DIRS_T3(3, 3) = RESHAPE([1.0_wp, 0.27_wp, 0.04_wp, 0.36_wp, 1.0_wp, -0.12_wp, &
                                                    0.6_wp, 1.2_wp, 0.4_wp], [3, 3])
    REAL(wp) :: dirs(3, 3, 5), strain_1(3, 5), qn(12), vn(12), an(12), q1(12), qp(12), lm(3), R(12), Rp(12), Rm(12)
    REAL(wp) :: K(9, 9), Kfd(9, 9), Kdump(9, 9), f_cap(12), f_new(12), f_raw(12), acc(12), inertia(12), m
    REAL(wp) :: scale, err
    INTEGER :: c, p, j, i, e, free(9)
    LOGICAL :: dense
    CHARACTER(16) :: label
    free = [(i + 3, i=1, 9)]
    lm = L0
    lm(1) = (1.0_wp - ALPHA_F)*L0(1) + ALPHA_F*L0S(1)
    lm(3) = (1.0_wp - ALPHA_F)*L0(3) + ALPHA_F*L0S(3)
    strain_1(:, 1) = [0.020_wp, 0.015_wp, 0.020_wp]
    strain_1(:, 2) = [-0.050_wp, 0.015_wp, 0.020_wp]
    strain_1(:, 3) = [-0.0005_wp, 0.015_wp, 0.020_wp]
    strain_1(:, 4) = [0.020_wp, 0.015_wp, 0.0002_wp]
    strain_1(:, 5) = [0.020_wp, 0.015_wp, 0.025_wp]
    dirs(:, :, 1) = DIRS_1
    dirs(:, :, 2) = DIRS_1
    dirs(:, :, 3) = DIRS_T1
    dirs(:, :, 4) = DIRS_T3
    dirs(:, :, 5) = DIRS_N
    vn = 0.0_wp
    an = 0.0_wp
    DO i = 4, 12
      vn(i) = 0.01_wp*SIN(1.7_wp*REAL(i, wp))
      an(i) = 0.02_wp*COS(2.3_wp*REAL(i, wp))
    END DO
    CALL chain_nodes(DIRS_N, [0.010_wp, 0.020_wp, 0.010_wp], L0S, qn)
    DO c = 1, 5
      SELECT CASE (c)
      CASE (1)
        label = 'taut-taut'
      CASE (2)
        label = 'release-cap'
      CASE (3)
        label = 'turning-release'
      CASE (4)
        label = 'haul-in-turning'
      CASE DEFAULT
        label = 'haul-in-negative'
      END SELECT
      CALL chain_nodes(dirs(:, :, c), strain_1(:, c), L0, q1)
      CALL blended_force(qn, q1, L0, EA, ALPHA_F, .TRUE., f_cap, l0s=L0S)
      CALL blended_force(qn, q1, L0, EA, ALPHA_F, .FALSE., f_raw, l0s=L0S)
      ! the same with the step-start force at the new lengths: what start_l0 must avoid
      CALL blended_force(qn, q1, L0, EA, ALPHA_F, .TRUE., f_new)
      scale = MAXVAL(ABS(f_raw))
      CALL require(MAXVAL(ABS(f_new - f_cap)) > 1.0e-2_wp*scale, 'lengths:'//TRIM(label)//':start-lengths-matter')
      IF (c >= 2) CALL require(MAXVAL(ABS(f_cap - f_raw)) > 1.0e-3_wp*scale, 'lengths:'//TRIM(label)//':cap-active')
      ! inertia M(mass_l0) a_alpha of the generalised-alpha relations, the fixed node held
      acc = 0.0_wp
      DO i = 4, 12
        acc(i) = (1.0_wp - ALPHA_M)*(q1(i) - qn(i) - DT*vn(i) - DT*DT*(0.5_wp - BETA)*an(i))/(BETA*DT*DT) + &
                 ALPHA_M*an(i)
      END DO
      inertia = 0.0_wp
      DO e = 1, 3
        m = RHO_A(e)*lm(e)/6.0_wp
        inertia(3*e - 2:3*e) = inertia(3*e - 2:3*e) + m*(2.0_wp*acc(3*e - 2:3*e) + acc(3*e + 1:3*e + 3))
        inertia(3*e + 1:3*e + 3) = inertia(3*e + 1:3*e + 3) + m*(acc(3*e - 2:3*e) + 2.0_wp*acc(3*e + 1:3*e + 3))
      END DO
      DO p = 1, 2
        dense = p == 2
        CALL probe_step(qn, vn, an, q1, L0, EA, RHO_A, dense, R, K, start_l0=L0S, mass_l0=lm)
        err = MAXVAL(ABS(R(4:12) - f_cap(4:12) - inertia(4:12)))/MAX(scale, MAXVAL(ABS(inertia)))
        WRITE (*, '(A,A,A,L1,A,ES9.2)') '  lengths ', TRIM(label), ' dense=', dense, ': residual vs closed form ', err
        CALL require(err < 1.0e-9_wp, 'lengths:'//TRIM(label)//TRIM(MERGE(':dense ', ':banded', dense))//':residual')
        DO j = 1, 9
          qp = q1
          qp(free(j)) = q1(free(j)) + H
          CALL probe_step(qn, vn, an, qp, L0, EA, RHO_A, dense, Rp, Kdump, start_l0=L0S, mass_l0=lm)
          qp(free(j)) = q1(free(j)) - H
          CALL probe_step(qn, vn, an, qp, L0, EA, RHO_A, dense, Rm, Kdump, start_l0=L0S, mass_l0=lm)
          Kfd(:, j) = (Rp(4:12) - Rm(4:12))/(2.0_wp*H)
        END DO
        err = MAXVAL(ABS(K - Kfd))/MAXVAL(ABS(K))
        WRITE (*, '(A,A,A,L1,A,ES9.2)') '  lengths ', TRIM(label), ' dense=', dense, ': max |K - K_fd|/max|K| = ', err
        CALL require(err < 1.0e-6_wp, 'lengths:'//TRIM(label)//TRIM(MERGE(':dense ', ':banded', dense))//':fd-tangent')
      END DO
    END DO
  END SUBROUTINE case_length_change_step

  SUBROUTINE case_light_cable_coarse_step()
    LOGICAL :: conv
    INTEGER :: es
    CHARACTER(512) :: em
    REAL(wp) :: fair, anch
    CALL light_cable_deck('ei0slack_coarse.dat', 0.1_wp, 40.0_wp, '', '-')
    CALL CD_Run_Deck_Driver('ei0slack_coarse.dat', 'ei0slack_coarse', conv, es, em)
    CALL require(es == CD_DECKDRV_OK .AND. conv, 'coarse:run '//TRIM(em))
    fair = column_max('ei0slack_coarse.out', 2, 2)
    anch = column_max('ei0slack_coarse.out', 3, 3)
    WRITE (*, '(A,ES10.3,A,ES10.3,A)') '  light cable, dtM 0.1 s: FairTen1 max ', fair, ' N, AnchTen1 max ', anch, ' N'
    CALL require(fair > 5.0e4_wp .AND. fair < 2.0e5_wp, 'coarse:fairlead-peak')
    CALL require(anch > 2.0e4_wp .AND. anch < 2.0e5_wp, 'coarse:anchor-peak')
  END SUBROUTINE case_light_cable_coarse_step

  SUBROUTINE case_light_cable_release_cap()
    LOGICAL :: conv
    INTEGER :: es
    CHARACTER(512) :: em
    REAL(wp) :: seg
    CALL light_cable_deck('ei0slack_release.dat', 0.01_wp, 24.0_wp, '', 't')
    CALL CD_Run_Deck_Driver('ei0slack_release.dat', 'ei0slack_release', conv, es, em)
    CALL require(es == CD_DECKDRV_OK .AND. conv, 'release:run '//TRIM(em))
    seg = column_max('ei0slack_release.Line1.t.out', 2, 0)
    WRITE (*, '(A,ES10.3,A)') '  light cable, dtM 0.01 s: largest segment tension ', seg, ' N'
    CALL require(seg > 5.0e4_wp .AND. seg < 2.0e5_wp, 'release:segment-peak')
  END SUBROUTINE case_light_cable_release_cap

  SUBROUTINE case_viscoelastic_surge()
    LOGICAL :: conv
    INTEGER :: es
    CHARACTER(512) :: em
    CHARACTER(64) :: opts(4)
    REAL(wp) :: fair
    CALL write_motion('ei0slack_surge.txt', 1, [58.0_wp, 0.0_wp, -14.0_wp], 1, 15.0_wp, 12.0_wp, 12.0_wp, &
                      0.1_wp, 48.0_wp)
    opts(1) = '0.1 dtM'
    opts(2) = '48.0 TMax'
    opts(3) = 'ei0slack_surge.txt motionFile'
    opts(4) = '3.0e6 kBot'
    CALL write_deck('ei0slack_ve.dat', POLY_VE, [700.0_wp, 0.0_wp, -200.0_wp], [58.0_wp, 0.0_wp, -14.0_wp], &
                    690.0_wp, 50, 200.0_wp, '-', opts)
    CALL CD_Run_Deck_Driver('ei0slack_ve.dat', 'ei0slack_ve', conv, es, em)
    CALL require(es == CD_DECKDRV_OK .AND. conv, 've:run '//TRIM(em))
    fair = column_max('ei0slack_ve.out', 2, 2)
    WRITE (*, '(A,ES10.3,A)') '  viscoelastic polyester, 15 m surge, dtM 0.1 s: FairTen1 max ', fair, ' N'
    CALL require(fair > 1.6e6_wp .AND. fair < 1.9e6_wp, 've:fairlead-peak')
  END SUBROUTINE case_viscoelastic_surge

  SUBROUTINE case_run_audit()
    LOGICAL :: ok
    REAL(wp) :: turn_off, turn_auto
    CHARACTER(64) :: opts(4)
    ! the configuration blend of case 1: its spikes are reported once, as a warning. Its
    ! non-physical spikes make the run chaotic: whether it completes or a later spike stops it
    ! fail-closed depends on round-off (it did both on Linux CI runners of the same commit), so
    ! only the warning, written at the first spike, is required of it
    CALL light_cable_deck('ei0slack_audit_cfg.dat', 0.1_wp, 40.0_wp, 'False alpha_force_blend', '-')
    CALL run_driver_logged('ei0slack_audit_cfg.dat', 'ei0slack_audit_cfg', 'ei0slack_audit_cfg.log', ok)
    IF (.NOT. ok) CALL echo_tail('ei0slack_audit_cfg.log', 6)
    CALL require(file_contains('ei0slack_audit_cfg.log', 'Warning: line 1: segment '), &
                 'audit:configuration-blend-spike-warned')
    CALL require(file_contains('ei0slack_audit_cfg.log', 'for a single step'), 'audit:spike-message')
    ! the default force blend: no spike warning
    CALL light_cable_deck('ei0slack_audit_fb.dat', 0.1_wp, 40.0_wp, '', '-')
    CALL run_driver_logged('ei0slack_audit_fb.dat', 'ei0slack_audit_fb', 'ei0slack_audit_fb.log', ok)
    IF (.NOT. ok) CALL echo_tail('ei0slack_audit_fb.log', 6)
    CALL require(ok, 'audit:force-blend-run')
    CALL require(.NOT. file_contains('ei0slack_audit_fb.log', 'Warning: line'), 'audit:force-blend-no-warning')
    ! snaps of the light cable (axial wave crossing a segment ~160 times per step) are noted. The
    ! 3 m heave above snaps only just past the initial tension, so whether a coarse step counts a
    ! snap there depends on round-off; a 6 m heave at 8 s snaps the line well past it
    CALL write_motion('ei0slack_snap.txt', 1, [5.0_wp, 0.0_wp, -14.0_wp], 3, 6.0_wp, 8.0_wp, 8.0_wp, &
                      0.1_wp, 40.0_wp)
    opts(1) = '0.1 dtM'
    opts(2) = '40.0 TMax'
    opts(3) = 'ei0slack_snap.txt motionFile'
    opts(4) = ''
    CALL write_deck('ei0slack_audit_snap.dat', CABLE, [205.0_wp, 0.0_wp, -80.0_wp], [5.0_wp, 0.0_wp, -14.0_wp], &
                    230.0_wp, 115, 80.0_wp, '-', opts)
    CALL run_driver_logged('ei0slack_audit_snap.dat', 'ei0slack_audit_snap', 'ei0slack_audit_snap.log', ok)
    IF (.NOT. ok) CALL echo_tail('ei0slack_audit_snap.log', 6)
    CALL require(ok, 'audit:snap-run')
    CALL require(file_contains('ei0slack_audit_snap.log', 'went from slack to taut above the initial tension'), &
                 'audit:snap-note')
    CALL require(file_contains('ei0slack_audit_snap.log', 'snap-load peaks are not resolved in time'), &
                 'audit:snap-note-text')
    CALL require(.NOT. file_contains('ei0slack_audit_fb.log', 'Note: rhoInf'), 'audit:default-rhoinf-no-note')
    ! rhoInf above 0.95
    CALL light_cable_deck('ei0slack_audit_rho.dat', 0.1_wp, 12.0_wp, '0.99 rhoInf', '-')
    CALL run_driver_logged('ei0slack_audit_rho.dat', 'ei0slack_audit_rho', 'ei0slack_audit_rho.log', ok)
    CALL require(ok, 'audit:rhoinf-run')
    CALL require(file_contains('ei0slack_audit_rho.log', 'Note: rhoInf = 0.990 leaves almost no numerical'), &
                 'audit:rhoinf-note')
    ! line nodes are numbered from 1 = End A, MoorDyn's from 0: noted when a run reports line nodes
    CALL require(.NOT. file_contains('ei0slack_audit_rho.log', 'line nodes are numbered from 1'), &
                 'audit:no-node-numbering-note')
    CALL light_cable_deck('ei0slack_audit_node.dat', 0.1_wp, 1.0_wp, '', 'p')
    CALL run_driver_logged('ei0slack_audit_node.dat', 'ei0slack_audit_node', 'ei0slack_audit_node.log', ok)
    CALL require(ok, 'audit:node-run')
    CALL require(file_contains('ei0slack_audit_node.log', 'Note: line nodes are numbered from 1 = End A'), &
                 'audit:node-numbering-note')
    ! a 10 m sway at dtM 0.2 s turns the segments by several degrees per step: taken as given
    ! (off ei0_substeps) the run notes the turn
    CALL write_motion('ei0slack_sway.txt', 1, [5.0_wp, 0.0_wp, -14.0_wp], 2, 10.0_wp, 10.0_wp, 10.0_wp, &
                      0.2_wp, 20.0_wp)
    opts(1) = '0.2 dtM'
    opts(2) = '20.0 TMax'
    opts(3) = 'ei0slack_sway.txt motionFile'
    opts(4) = 'off ei0_substeps'
    CALL write_deck('ei0slack_audit_sway.dat', CABLE, [205.0_wp, 0.0_wp, -80.0_wp], [5.0_wp, 0.0_wp, -14.0_wp], &
                    230.0_wp, 115, 80.0_wp, '-', opts)
    CALL run_driver_logged('ei0slack_audit_sway.dat', 'ei0slack_audit_sway', 'ei0slack_audit_sway.log', ok)
    CALL require(ok, 'audit:sway-run')
    CALL require(file_contains('ei0slack_audit_sway.log', 'Note: line 1: a taut segment turned up to'), &
                 'audit:segment-turn-note')
    CALL require(file_contains('ei0slack_audit_sway.log', 'set ei0_substeps auto'), 'audit:segment-turn-remedy')
    CALL require(.NOT. file_contains('ei0slack_audit_sway.log', 'Warning: line'), 'audit:sway-no-warning')
    ! the default (auto) sub-steps those steps: the run reports the sub-stepping, and the turn
    ! per solver step drops to about 1 deg (the steps recovered after a stall take their four
    ! sub-steps as given, so a note may remain for them): 1.27 deg against 6.21 deg taken as
    ! given (gfortran, Windows). A step left unresolved turns by the full step's turn, a
    ! recovered one by a quarter of it, so half the turn taken as given separates the two
    ! without depending on which steps round-off makes stall
    opts(4) = ''
    CALL write_deck('ei0slack_audit_sway_auto.dat', CABLE, [205.0_wp, 0.0_wp, -80.0_wp], &
                    [5.0_wp, 0.0_wp, -14.0_wp], 230.0_wp, 115, 80.0_wp, '-', opts)
    CALL run_driver_logged('ei0slack_audit_sway_auto.dat', 'ei0slack_audit_sway_auto', &
                           'ei0slack_audit_sway_auto.log', ok)
    CALL require(ok, 'audit:sway-auto-run')
    CALL require(file_contains('ei0slack_audit_sway_auto.log', 'ei0_substeps auto solved'), 'audit:substep-note')
    turn_off = noted_turn('ei0slack_audit_sway.log')
    turn_auto = noted_turn('ei0slack_audit_sway_auto.log')
    WRITE (*, '(A,F7.3,A,F7.3,A)') '  sway at dtM 0.2 s: largest turn per solver step ', turn_off, ' deg (off), ', &
      turn_auto, ' deg (auto)'
    CALL require(turn_off > 4.0_wp .AND. turn_auto >= 0.0_wp .AND. turn_auto < 0.5_wp*turn_off, &
                 'audit:sway-auto-resolved-turn')
    ! the configuration blend (paper mode) takes every step as given
    CALL require(.NOT. file_contains('ei0slack_audit_cfg.log', 'ei0_substeps auto solved'), &
                 'audit:configuration-blend-not-sub-stepped')
  END SUBROUTINE case_run_audit

  ! ------------------------------------------------------------------------------------------
  ! Chain cases 6 to 8: a load callback with drag, a position load and a segment law
  ! ------------------------------------------------------------------------------------------

  FUNCTION outer3(x, y) RESULT(m)
    REAL(wp), INTENT(IN) :: x(3), y(3)
    REAL(wp) :: m(3, 3)
    INTEGER :: i
    DO i = 1, 3
      m(:, i) = x*y(i)
    END DO
  END FUNCTION outer3

  SUBROUTINE chain_load(q, v, force, jac_q, jac_v)
    !! The chain load (see cb_drag) and its residual Jacobians -d(force)/dq, -d(force)/dv.
    REAL(wp), INTENT(IN) :: q(:), v(:)
    REAL(wp), INTENT(OUT) :: force(:), jac_q(:, :), jac_v(:, :)
    INTEGER :: n, i, a, b
    REAL(wp) :: d(3), w(3), dd, sp, c(3), ell, t(3), ten, kb(3, 3), eye(3, 3), kv(3, 3)
    force = 0.0_wp
    jac_q = 0.0_wp
    jac_v = 0.0_wp
    eye = 0.0_wp
    DO i = 1, 3
      eye(i, i) = 1.0_wp
    END DO
    DO n = 1, SIZE(q)/3
      d = q(3*n - 2:3*n) - cb_q0(3*n - 2:3*n)
      w = v(3*n - 2:3*n)
      dd = DOT_PRODUCT(d, d)
      sp = NORM2(w)
      force(3*n - 2:3*n) = -cb_drag*sp*w - cb_spring*dd*d
      jac_q(3*n - 2:3*n, 3*n - 2:3*n) = cb_spring*(dd*eye + 2.0_wp*outer3(d, d))
      IF (sp > 0.0_wp) jac_v(3*n - 2:3*n, 3*n - 2:3*n) = cb_drag*(sp*eye + outer3(w, w)/sp)
    END DO
    IF (cb_law_elem > 0) THEN
      ! the tension-only segment law: force T t on node a, -T t on node b
      a = cb_law_elem
      b = a + 1
      c = q(3*b - 2:3*b) - q(3*a - 2:3*a)
      ell = NORM2(c)
      t = c/ell
      w = v(3*b - 2:3*b) - v(3*a - 2:3*a)
      ten = cb_ea_law*(ell/cb_l0_law - 1.0_wp) + cb_ba_law*DOT_PRODUCT(t, w)/cb_l0_law
      IF (ten > 0.0_wp) THEN
        force(3*a - 2:3*a) = force(3*a - 2:3*a) + ten*t
        force(3*b - 2:3*b) = force(3*b - 2:3*b) - ten*t
        ! kb = d(force_a)/d(q_b), kv = d(force_a)/d(v_b)
        kb = (cb_ea_law/cb_l0_law)*outer3(t, t) + ten*(eye - outer3(t, t))/ell + &
             (cb_ba_law/cb_l0_law)*outer3(t, MATMUL(eye - outer3(t, t), w)/ell)
        kv = (cb_ba_law/cb_l0_law)*outer3(t, t)
        jac_q(3*a - 2:3*a, 3*a - 2:3*a) = jac_q(3*a - 2:3*a, 3*a - 2:3*a) + kb
        jac_q(3*a - 2:3*a, 3*b - 2:3*b) = jac_q(3*a - 2:3*a, 3*b - 2:3*b) - kb
        jac_q(3*b - 2:3*b, 3*a - 2:3*a) = jac_q(3*b - 2:3*b, 3*a - 2:3*a) - kb
        jac_q(3*b - 2:3*b, 3*b - 2:3*b) = jac_q(3*b - 2:3*b, 3*b - 2:3*b) + kb
        jac_v(3*a - 2:3*a, 3*a - 2:3*a) = jac_v(3*a - 2:3*a, 3*a - 2:3*a) + kv
        jac_v(3*a - 2:3*a, 3*b - 2:3*b) = jac_v(3*a - 2:3*a, 3*b - 2:3*b) - kv
        jac_v(3*b - 2:3*b, 3*a - 2:3*a) = jac_v(3*b - 2:3*b, 3*a - 2:3*a) - kv
        jac_v(3*b - 2:3*b, 3*b - 2:3*b) = jac_v(3*b - 2:3*b, 3*b - 2:3*b) + kv
      END IF
    END IF
    IF (cb_dash_elem > 0) THEN
      ! the dashpot: force (BA/l0) (t . w) t on node a, the opposite on node b, in both senses
      a = cb_dash_elem
      b = a + 1
      c = q(3*b - 2:3*b) - q(3*a - 2:3*a)
      ell = NORM2(c)
      t = c/ell
      w = v(3*b - 2:3*b) - v(3*a - 2:3*a)
      ten = cb_ba_dash*(DOT_PRODUCT(t, w) - ell*cb_l0dot_dash/cb_l0_dash)/cb_l0_dash
      force(3*a - 2:3*a) = force(3*a - 2:3*a) + ten*t
      force(3*b - 2:3*b) = force(3*b - 2:3*b) - ten*t
      kb = ten*(eye - outer3(t, t))/ell + (cb_ba_dash/cb_l0_dash)*outer3(t, MATMUL(eye - outer3(t, t), w)/ell) - &
           (cb_ba_dash*cb_l0dot_dash/cb_l0_dash**2)*outer3(t, t)
      kv = (cb_ba_dash/cb_l0_dash)*outer3(t, t)
      jac_q(3*a - 2:3*a, 3*a - 2:3*a) = jac_q(3*a - 2:3*a, 3*a - 2:3*a) + kb
      jac_q(3*a - 2:3*a, 3*b - 2:3*b) = jac_q(3*a - 2:3*a, 3*b - 2:3*b) - kb
      jac_q(3*b - 2:3*b, 3*a - 2:3*a) = jac_q(3*b - 2:3*b, 3*a - 2:3*a) - kb
      jac_q(3*b - 2:3*b, 3*b - 2:3*b) = jac_q(3*b - 2:3*b, 3*b - 2:3*b) + kb
      jac_v(3*a - 2:3*a, 3*a - 2:3*a) = jac_v(3*a - 2:3*a, 3*a - 2:3*a) + kv
      jac_v(3*a - 2:3*a, 3*b - 2:3*b) = jac_v(3*a - 2:3*a, 3*b - 2:3*b) - kv
      jac_v(3*b - 2:3*b, 3*a - 2:3*a) = jac_v(3*b - 2:3*b, 3*a - 2:3*a) - kv
      jac_v(3*b - 2:3*b, 3*b - 2:3*b) = jac_v(3*b - 2:3*b, 3*b - 2:3*b) + kv
    END IF
  END SUBROUTINE chain_load

  SUBROUTINE cb_load(q, v, force, jac_q, jac_v, ErrStat, ErrMsg)
    REAL(wp), INTENT(IN) :: q(:), v(:)
    REAL(wp), INTENT(OUT) :: force(:), jac_q(:, :), jac_v(:, :)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    CALL chain_load(q, v, force, jac_q, jac_v)
    ErrStat = 0
    ErrMsg = ''
  END SUBROUTINE cb_load

  SUBROUTINE cb_force(q, v, force, ErrStat, ErrMsg)
    REAL(wp), INTENT(IN) :: q(:), v(:)
    REAL(wp), INTENT(OUT) :: force(:)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    REAL(wp) :: jq(SIZE(q), SIZE(q)), jv(SIZE(q), SIZE(q))
    CALL chain_load(q, v, force, jq, jv)
    ErrStat = 0
    ErrMsg = ''
  END SUBROUTINE cb_force

  SUBROUTINE cb_load_band(q, v, free, kl, ku, force, jac_q_band, jac_v_band, ErrStat, ErrMsg)
    !! The chain load with its Jacobians in the reduced free/free band storage of the step.
    REAL(wp), INTENT(IN) :: q(:), v(:)
    INTEGER, INTENT(IN) :: free(:), kl, ku
    REAL(wp), INTENT(OUT) :: force(:), jac_q_band(:, :), jac_v_band(:, :)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    REAL(wp) :: jq(SIZE(q), SIZE(q)), jv(SIZE(q), SIZE(q))
    INTEGER :: i, j
    CALL chain_load(q, v, force, jq, jv)
    jac_q_band = 0.0_wp
    jac_v_band = 0.0_wp
    DO j = 1, SIZE(free)
      DO i = 1, SIZE(free)
        IF (i - j > kl .OR. j - i > ku) CYCLE
        jac_q_band(kl + ku + 1 + i - j, j) = jq(free(i), free(j))
        jac_v_band(kl + ku + 1 + i - j, j) = jv(free(i), free(j))
      END DO
    END DO
    ErrStat = 0
    ErrMsg = ''
  END SUBROUTINE cb_load_band

  SUBROUTINE cb_added_mass(q, accel, M_add, dMa_a_dq, ErrStat, ErrMsg)
    !! Position-dependent nodal added mass cb_madd (1 + 0.3 z^2) and d(M_add a)/dq.
    REAL(wp), INTENT(IN) :: q(:), accel(:)
    REAL(wp), INTENT(OUT) :: M_add(:, :), dMa_a_dq(:, :)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    INTEGER :: n, i
    M_add = 0.0_wp
    dMa_a_dq = 0.0_wp
    DO n = 1, SIZE(q)/3
      DO i = 3*n - 2, 3*n
        M_add(i, i) = cb_madd*(1.0_wp + 0.3_wp*q(3*n)**2)
        dMa_a_dq(i, 3*n) = cb_madd*0.6_wp*q(3*n)*accel(i)
      END DO
    END DO
    ErrStat = 0
    ErrMsg = ''
  END SUBROUTINE cb_added_mass

  SUBROUTINE probe_chain(qn, vn, an, q1, l0, ea, rho_a, banded, R, K, start_tension, start_stiffness, &
                         axial_damping, start_load, start_l0, axial_l0_rate, start_l0_rate)
    !! Residual and effective tangent at q1 of the force-blended step of the chain with the
    !! callback load: banded (load_band_proc + load_force_proc) or dense (load_proc, with the
    !! added mass when cb_madd > 0).
    REAL(wp), INTENT(IN) :: qn(12), vn(12), an(12), q1(12), l0(3), ea(3), rho_a(3)
    LOGICAL, INTENT(IN) :: banded
    REAL(wp), INTENT(OUT) :: R(12), K(9, 9)
    REAL(wp), INTENT(IN), OPTIONAL :: start_tension(:), start_stiffness(:), axial_damping(:)
    !! a length change over the step: the step-start load, lengths and rates, and the rates at
    !! t_{n+1} (passed on to the step)
    REAL(wp), INTENT(IN), OPTIONAL :: start_load(:), start_l0(:), axial_l0_rate(:), start_l0_rate(:)
    INTEGER :: conn(2, 3), n_iter, es
    REAL(wp) :: qo(12), vo(12), ao(12)
    LOGICAL :: converged, stalled
    TYPE(GenAlphaConfig) :: cfg
    TYPE(CD_CableGenAlphaWorkspace) :: work
    CHARACTER(120) :: em
    conn = RESHAPE([1, 2, 2, 3, 3, 4], [2, 3])
    cfg%rho_inf = 0.4_wp
    IF (banded) THEN
      CALL CD_Cable_Gen_Alpha_Step(qn, vn, an, conn, l0, ea, rho_a, .TRUE., 0.0_wp*qn, [1, 2, 3], 0.05_wp, cfg, &
                                   qo, vo, ao, converged, stalled, n_iter, es, em, load_band_proc=cb_load_band, &
                                   load_force_proc=cb_force, workspace=work, start_tension=start_tension, &
                                   start_stiffness=start_stiffness, axial_damping=axial_damping, &
                                   start_load=start_load, start_l0=start_l0, axial_l0_rate=axial_l0_rate, &
                                   start_l0_rate=start_l0_rate, probe_q=q1, probe_R=R, probe_K=K)
    ELSE IF (cb_madd > 0.0_wp) THEN
      CALL CD_Cable_Gen_Alpha_Step(qn, vn, an, conn, l0, ea, rho_a, .TRUE., 0.0_wp*qn, [1, 2, 3], 0.05_wp, cfg, &
                                   qo, vo, ao, converged, stalled, n_iter, es, em, load_proc=cb_load, &
                                   added_mass_proc=cb_added_mass, workspace=work, start_tension=start_tension, &
                                   start_stiffness=start_stiffness, axial_damping=axial_damping, &
                                   start_load=start_load, start_l0=start_l0, axial_l0_rate=axial_l0_rate, &
                                   start_l0_rate=start_l0_rate, probe_q=q1, probe_R=R, probe_K=K)
    ELSE
      CALL CD_Cable_Gen_Alpha_Step(qn, vn, an, conn, l0, ea, rho_a, .TRUE., 0.0_wp*qn, [1, 2, 3], 0.05_wp, cfg, &
                                   qo, vo, ao, converged, stalled, n_iter, es, em, load_proc=cb_load, &
                                   workspace=work, start_tension=start_tension, &
                                   start_stiffness=start_stiffness, axial_damping=axial_damping, &
                                   start_load=start_load, start_l0=start_l0, axial_l0_rate=axial_l0_rate, &
                                   start_l0_rate=start_l0_rate, probe_q=q1, probe_R=R, probe_K=K)
    END IF
    IF (es /= CD_DYN_OK) THEN
      WRITE (*, '(A)') 'MISMATCH [chain:probe '//TRIM(em)//']'
      nfail = nfail + 1
      R = 0.0_wp
      K = 0.0_wp
    END IF
  END SUBROUTINE probe_chain

  SUBROUTINE fd_tangent_check(label, qn, vn, an, q1, l0, ea, rho_a, banded, start_tension, start_stiffness, &
                              axial_damping, start_load, start_l0, axial_l0_rate, start_l0_rate)
    !! The step's tangent against the central difference of its residual.
    CHARACTER(*), INTENT(IN) :: label
    REAL(wp), INTENT(IN) :: qn(12), vn(12), an(12), q1(12), l0(3), ea(3), rho_a(3)
    LOGICAL, INTENT(IN) :: banded
    REAL(wp), INTENT(IN), OPTIONAL :: start_tension(:), start_stiffness(:), axial_damping(:)
    REAL(wp), INTENT(IN), OPTIONAL :: start_load(:), start_l0(:), axial_l0_rate(:), start_l0_rate(:)
    REAL(wp), PARAMETER :: H = 1.0e-6_wp
    INTEGER :: j
    REAL(wp) :: qp(12), R(12), Rp(12), Rm(12), K(9, 9), Kfd(9, 9), Kdump(9, 9), err
    CALL probe_chain(qn, vn, an, q1, l0, ea, rho_a, banded, R, K, start_tension, start_stiffness, axial_damping, &
                     start_load, start_l0, axial_l0_rate, start_l0_rate)
    DO j = 1, 9
      qp = q1
      qp(3 + j) = q1(3 + j) + H
      CALL probe_chain(qn, vn, an, qp, l0, ea, rho_a, banded, Rp, Kdump, start_tension, start_stiffness, &
                       axial_damping, start_load, start_l0, axial_l0_rate, start_l0_rate)
      qp(3 + j) = q1(3 + j) - H
      CALL probe_chain(qn, vn, an, qp, l0, ea, rho_a, banded, Rm, Kdump, start_tension, start_stiffness, &
                       axial_damping, start_load, start_l0, axial_l0_rate, start_l0_rate)
      Kfd(:, j) = (Rp(4:12) - Rm(4:12))/(2.0_wp*H)
    END DO
    err = MAXVAL(ABS(K - Kfd))/MAXVAL(ABS(K))
    WRITE (*, '(A,A,A,L1,A,ES9.2)') '  tangent ', label, ' banded=', banded, ': max |K - K_fd|/max|K| = ', err
    CALL require(err < 1.0e-8_wp, label//TRIM(MERGE(':banded', ':dense ', banded))//':fd-tangent')
  END SUBROUTINE fd_tangent_check

  SUBROUTINE chain_states(strain_n, strain_1, l0, qn, vn, an, q1, dirs_trial)
    !! The chain of case 5 at t_n and at the trial state, with a small velocity and
    !! acceleration at t_n (dirs_trial: the segment directions at the trial state).
    REAL(wp), INTENT(IN) :: strain_n(3), strain_1(3), l0(3)
    REAL(wp), INTENT(OUT) :: qn(12), vn(12), an(12), q1(12)
    REAL(wp), INTENT(IN), OPTIONAL :: dirs_trial(3, 3)
    REAL(wp), PARAMETER :: DIRS_N(3, 3) = RESHAPE([1.0_wp, 0.2_wp, 0.1_wp, 0.3_wp, 1.0_wp, -0.2_wp, &
                                                   -0.2_wp, 0.4_wp, 1.0_wp], [3, 3])
    REAL(wp), PARAMETER :: DIRS_1(3, 3) = RESHAPE([1.0_wp, 0.27_wp, 0.04_wp, 0.36_wp, 1.0_wp, -0.12_wp, &
                                                   -0.12_wp, 0.46_wp, 1.0_wp], [3, 3])
    INTEGER :: i
    CALL chain_nodes(DIRS_N, strain_n, l0, qn)
    IF (PRESENT(dirs_trial)) THEN
      CALL chain_nodes(dirs_trial, strain_1, l0, q1)
    ELSE
      CALL chain_nodes(DIRS_1, strain_1, l0, q1)
    END IF
    vn = 0.0_wp
    an = 0.0_wp
    DO i = 4, 12
      vn(i) = 0.01_wp*SIN(1.7_wp*REAL(i, wp))
      an(i) = 0.02_wp*COS(2.3_wp*REAL(i, wp))
    END DO
  END SUBROUTINE chain_states

  SUBROUTINE reset_chain_load()
    cb_drag = 0.0_wp
    cb_spring = 0.0_wp
    cb_ea_law = 0.0_wp
    cb_l0_law = 1.0_wp
    cb_madd = 0.0_wp
    cb_q0 = 0.0_wp
    cb_law_elem = 0
    cb_ba_law = 0.0_wp
    cb_ba_dash = 0.0_wp
    cb_l0_dash = 1.0_wp
    cb_l0dot_dash = 0.0_wp
    cb_dash_elem = 0
  END SUBROUTINE reset_chain_load

  SUBROUTINE case_law_release_cap()
    !! Segment 3 carries a tension-only law through the load callback (ea(3) = 0) and
    !! releases within the step: deeply, turning by about 50 degrees as it goes slack, and
    !! turning as it ends taut at a tenth of its step-start tension.
    REAL(wp), PARAMETER :: DIRS_TURN(3, 3) = RESHAPE([1.0_wp, 0.27_wp, 0.04_wp, 0.36_wp, 1.0_wp, -0.12_wp, &
                                                      0.6_wp, 0.4_wp, 0.6_wp], [3, 3])
    CALL law_cap_config('law-cap', [0.010_wp, 0.020_wp, 0.010_wp], [0.020_wp, 0.015_wp, -0.050_wp])
    CALL law_cap_config('law-cap-turning', [0.010_wp, 0.020_wp, 0.002_wp], [0.020_wp, 0.015_wp, -0.0005_wp], &
                        DIRS_TURN)
    CALL law_cap_config('law-cap-turning-taut', [0.010_wp, 0.020_wp, 0.002_wp], [0.020_wp, 0.015_wp, 0.0002_wp], &
                        DIRS_TURN)
  END SUBROUTINE case_law_release_cap

  SUBROUTINE case_law_damped_release()
    !! A law segment whose step-start tension is almost all damping: segment 3 (law EA 0.8e6 N,
    !! BA 2e5 N s) stretched by e_n = 0.8 um and lengthening at 0.05 m/s carries T_n = 1.25e4 N,
    !! a secant T_n/e_n = 1.6e10 N/m against its axial stiffness k_n = EA/l0 = 1e6 N/m. It turns
    !! by 45 degrees and ends at a stretch e_{n+1} from -0.1 to 1.9 mm. With start_stiffness the
    !! cap's force varies with e_{n+1} at a slope of order k_n; with the unbounded secant it
    !! switches over a band of width ~e_n, a jump at this resolution. The blend returns at most
    !! W_n + (1 - alpha_f)(T^_{n+1} - T_{n+1}) p_{n+1} (T^ the estimate k e_{n+1}, T_{n+1} the
    !! law's end tension), and the tangent matches the finite difference where the cap acts.
    REAL(wp), PARAMETER :: L0(3) = [1.0_wp, 1.2_wp, 0.8_wp], EA(3) = [1.0e6_wp, 1.5e6_wp, 0.0_wp]
    REAL(wp), PARAMETER :: DIRS(3, 3) = RESHAPE([1.0_wp, 0.2_wp, 0.1_wp, 0.3_wp, 1.0_wp, -0.2_wp, &
                                                 -0.2_wp, 0.4_wp, 1.0_wp], [3, 3])
    REAL(wp), PARAMETER :: EA_LAW = 0.8e6_wp, BA_LAW = 2.0e5_wp, ALPHA_F = 0.4_wp/1.4_wp
    REAL(wp), PARAMETER :: RHO_TINY(3) = [1.0e-12_wp, 1.0e-12_wp, 1.0e-12_wp]
    INTEGER, PARAMETER :: NG = 201
    REAL(wp) :: qn(12), vn(12), an(12), q1(12), sl(12), jq(12, 12), jv(12, 12), tn(3), u(3), dir(3)
    REAL(wp) :: Rk(12), Ru(12), Rp(12), K(9, 9), ck(3, NG), cu(3, NG), e1(NG), t0, e0, w0, kn, kc, de
    REAL(wp) :: d0(3), d1(3), l1, t1(3), p1, ten1, that, wk, bound, slope_k, slope_u, worst
    INTEGER :: i, nact
    CALL reset_chain_load()
    cb_law_elem = 3
    cb_ea_law = EA_LAW
    cb_l0_law = L0(3)
    cb_ba_law = BA_LAW
    CALL chain_nodes(DIRS, [0.010_wp, 0.020_wp, 1.0e-6_wp], L0, qn)
    d0 = qn(10:12) - qn(7:9)
    tn = d0/NORM2(d0)
    u = [tn(2), -tn(1), 0.0_wp]
    u = u/NORM2(u)
    vn = 0.0_wp
    vn(10:12) = 0.05_wp*tn
    an = 0.0_wp
    CALL chain_load(qn, vn, sl, jq, jv)
    t0 = DOT_PRODUCT(sl(7:9), tn)
    e0 = NORM2(d0) - L0(3)
    w0 = 0.5_wp*t0*e0
    kn = EA_LAW/L0(3)
    kc = MIN(t0/e0, kn)
    CALL require(t0 > 1.2e4_wp .AND. t0/e0 > 1.0e4_wp*kn, 'law-damped:damping-dominated-start')
    dir = COS(PI/4.0_wp)*tn + SIN(PI/4.0_wp)*u
    de = 2.0e-3_wp/REAL(NG - 1, wp)
    nact = 0
    worst = -HUGE(1.0_wp)
    DO i = 1, NG
      e1(i) = -1.0e-4_wp + REAL(i - 1, wp)*de
      q1 = qn
      q1(10:12) = qn(7:9) + (L0(3) + e1(i))*dir
      CALL probe_chain(qn, vn, an, q1, L0, EA, RHO_TINY, .TRUE., Rk, K, start_tension=[0.0_wp, 0.0_wp, t0], &
                       start_stiffness=[0.0_wp, 0.0_wp, kn])
      CALL probe_chain(qn, vn, an, q1, L0, EA, RHO_TINY, .TRUE., Ru, K, start_tension=[0.0_wp, 0.0_wp, t0])
      CALL probe_chain(qn, vn, an, q1, L0, EA, RHO_TINY, .TRUE., Rp, K)
      ck(:, i) = Rk(10:12) - Rp(10:12)
      cu(:, i) = Ru(10:12) - Rp(10:12)
      IF (NORM2(ck(:, i)) > 1.0e-6_wp*t0) nact = nact + 1
      ! the law's end tension from the plain blend at the free node: (1 - alpha_f) T_1 t_1 +
      ! alpha_f T_n t_n (the step-start law force), inertia negligible
      d1 = q1(10:12) - q1(7:9)
      l1 = NORM2(d1)
      t1 = d1/l1
      ten1 = (DOT_PRODUCT(Rp(10:12), t1) - ALPHA_F*t0*DOT_PRODUCT(tn, t1))/(1.0_wp - ALPHA_F)
      p1 = l1 - DOT_PRODUCT(t1, d0)
      that = kc*MAX(e1(i), 0.0_wp)
      wk = -DOT_PRODUCT(Rk(10:12), q1(10:12) - qn(10:12))
      bound = w0 + (1.0_wp - ALPHA_F)*(that - ten1)*p1
      worst = MAX(worst, wk - bound)
    END DO
    slope_k = 0.0_wp
    slope_u = 0.0_wp
    DO i = 1, NG - 1
      slope_k = MAX(slope_k, NORM2(ck(:, i + 1) - ck(:, i))/de)
      slope_u = MAX(slope_u, NORM2(cu(:, i + 1) - cu(:, i))/de)
    END DO
    WRITE (*, '(A,I0,A,ES10.3,A,ES10.3,A,ES10.3,A)') '  law damped release: cap active at ', nact, &
      ' stretches; largest slope of the cap force ', slope_k/kn, ' k_n (unbounded secant ', slope_u/kn, &
      ' k_n); work above the bound ', worst, ' J'
    CALL require(nact > NG/2, 'law-damped:cap-active')
    CALL require(slope_k < 3.0_wp*kn, 'law-damped:bounded-slope')
    CALL require(slope_u > 100.0_wp*kn, 'law-damped:unbounded-secant-jumps')
    CALL require(worst <= 1.0e-6_wp, 'law-damped:energy-bound')
    ! the tangent where the cap acts on a taut end state with the bounded secant (e_{n+1} = 0.8 mm)
    q1 = qn
    q1(10:12) = qn(7:9) + (L0(3) + 8.0e-4_wp)*dir
    CALL fd_tangent_check('law-damped', qn, vn, an, q1, L0, EA, [2.0_wp, 3.0_wp, 1.5_wp], .TRUE., &
                          start_tension=[0.0_wp, 0.0_wp, t0], start_stiffness=[0.0_wp, 0.0_wp, kn])
    CALL fd_tangent_check('law-damped', qn, vn, an, q1, L0, EA, [2.0_wp, 3.0_wp, 1.5_wp], .FALSE., &
                          start_tension=[0.0_wp, 0.0_wp, t0], start_stiffness=[0.0_wp, 0.0_wp, kn])
    CALL reset_chain_load()
  END SUBROUTINE case_law_damped_release

  SUBROUTINE case_damped_elastic_release()
    !! An elastic segment with a two-sided axial dashpot (BA 2e4 N s on the end segment, l0 0.8 m,
    !! EA 0.8e6 N, e_n = 0.8 mm, W_n = 0.32 J) that extends at t_n at 0.05, 0.5 or 2 m/s
    !! (dashpot tension 1.6 to 62 times the elastic one) and turns by 0 to 180 degrees within
    !! the step, ending slack or taut. Its kept dashpot share alone returned up to 7e4 W_n and
    !! the whole blend up to 2.8e3 W_n before the cap covered it. With axial_damping the blend
    !! returns at most W_n + (1 - phi) D (D the uncapped blended dashpot's work, phi the dashpot
    !! weight: 1 at and below l0, 0 above l0 + c e_n), more only by the end share's own excess
    !! when N < 0; at and below l0 that is W_n. A segment that keeps its direction and ends taut
    !! keeps the plain force blend, and the tangent matches the finite difference.
    REAL(wp), PARAMETER :: L0(3) = [1.0_wp, 1.2_wp, 0.8_wp], EA(3) = [1.0e6_wp, 1.5e6_wp, 0.8e6_wp]
    REAL(wp), PARAMETER :: DIRS(3, 3) = RESHAPE([1.0_wp, 0.2_wp, 0.1_wp, 0.3_wp, 1.0_wp, -0.2_wp, &
                                                 -0.2_wp, 0.4_wp, 1.0_wp], [3, 3])
    REAL(wp), PARAMETER :: THETA(8) = [0.0_wp, 2.0_wp, 5.0_wp, 20.0_wp, 45.0_wp, 90.0_wp, 135.0_wp, 180.0_wp]
    REAL(wp), PARAMETER :: S1(11) = [-0.5_wp, -0.01_wp, -1.0e-3_wp, -1.0e-4_wp, -1.0e-12_wp, 1.0e-12_wp, &
                                     1.0e-4_wp, 2.0e-4_wp, 5.0e-4_wp, 1.0e-3_wp, 2.0e-3_wp]
    REAL(wp), PARAMETER :: RATE(3) = [0.05_wp, 0.5_wp, 2.0_wp], DT = 0.05_wp, RHO = 0.4_wp, BA = 2.0e4_wp
    REAL(wp), PARAMETER :: RHO_TINY(3) = [1.0e-12_wp, 1.0e-12_wp, 1.0e-12_wp], AD(3) = [0.0_wp, 0.0_wp, BA]
    REAL(wp) :: qn(12), q1(12), vn(12), z(12), v1(12), R(12), Rp(12), K(9, 9), tn(3), u(3), dir(3)
    REAL(wp) :: d0(3), d1(3), t1(3), w0, t0, e0, wt, l1, e1, tel1, td0, td1, p, p1, am, af, beta, gamma, band
    REAL(wp) :: phi, dash, nn, excess, worst, slack_worst, unc_max, dev, uncapped
    INTEGER :: i, j, ir, nact, nneg
    CALL reset_chain_load()
    cb_dash_elem = 3
    cb_ba_dash = BA
    cb_l0_dash = L0(3)
    am = (2.0_wp*RHO - 1.0_wp)/(RHO + 1.0_wp)
    af = RHO/(RHO + 1.0_wp)
    beta = 0.25_wp*(1.0_wp - am + af)**2
    gamma = 0.5_wp - am + af
    band = af/(1.0_wp - af)
    CALL chain_nodes(DIRS, [0.010_wp, 0.020_wp, 0.001_wp], L0, qn)
    z = 0.0_wp
    d0 = qn(10:12) - qn(7:9)
    tn = d0/NORM2(d0)
    u = [tn(2), -tn(1), 0.0_wp]
    u = u/NORM2(u)
    e0 = NORM2(d0) - L0(3)
    t0 = EA(3)*e0/L0(3)
    w0 = 0.5_wp*t0*e0
    worst = -HUGE(1.0_wp)
    slack_worst = -HUGE(1.0_wp)
    unc_max = -HUGE(1.0_wp)
    nact = 0
    nneg = 0
    DO ir = 1, SIZE(RATE)
      vn = 0.0_wp
      vn(10:12) = RATE(ir)*tn
      td0 = BA*RATE(ir)/L0(3)
      DO i = 1, SIZE(THETA)
        DO j = 1, SIZE(S1)
          dir = COS(THETA(i)*PI/180.0_wp)*tn + SIN(THETA(i)*PI/180.0_wp)*u
          q1 = qn
          q1(10:12) = qn(7:9) + L0(3)*(1.0_wp + S1(j))*dir
          CALL probe_chain(qn, vn, z, q1, L0, EA, RHO_TINY, .TRUE., R, K, axial_damping=AD)
          CALL probe_chain(qn, vn, z, q1, L0, EA, RHO_TINY, .TRUE., Rp, K)
          ! the closed-form kinematics and forces of the end segment at the trial state
          v1 = gamma/(beta*DT)*(q1 - qn) + (1.0_wp - gamma/beta)*vn
          v1(1:3) = 0.0_wp
          d1 = q1(10:12) - q1(7:9)
          l1 = NORM2(d1)
          t1 = d1/l1
          e1 = l1 - L0(3)
          p = NORM2(d0) - DOT_PRODUCT(tn, d1)
          p1 = l1 - DOT_PRODUCT(t1, d0)
          tel1 = MAX(0.0_wp, EA(3)*e1/L0(3))
          td1 = BA*DOT_PRODUCT(t1, v1(10:12) - v1(7:9))/L0(3)
          phi = MIN(1.0_wp, MAX(0.0_wp, 1.0_wp - e1/(band*e0)))
          dash = af*td0*p - (1.0_wp - af)*td1*p1
          nn = w0 + (1.0_wp - af)*(tel1 + phi*td1)*p1
          wt = -DOT_PRODUCT(R(10:12), q1(10:12) - qn(10:12))
          uncapped = af*(t0 + td0)*p - (1.0_wp - af)*(tel1 + td1)*p1
          IF (MAXVAL(ABS(R(10:12) - Rp(10:12))) > 1.0e-9_wp*t0) nact = nact + 1
          IF (nn < 0.0_wp) nneg = nneg + 1
          excess = wt - (w0 + (1.0_wp - phi)*dash + MAX(-nn, 0.0_wp))
          worst = MAX(worst, excess/w0)
          IF (e1 <= 0.0_wp .AND. nn >= 0.0_wp) slack_worst = MAX(slack_worst, wt/w0)
          IF (e1 <= 0.0_wp) unc_max = MAX(unc_max, uncapped/w0)
          IF (THETA(i) == 0.0_wp .AND. S1(j) > 0.0_wp) THEN
            ! a segment that keeps its direction and ends taut: the cap stays inactive
            dev = MAXVAL(ABS(R(10:12) - Rp(10:12)))
            CALL require(dev < 1.0e-9_wp*t0, 'damped-release:taut-end-uncapped')
          END IF
        END DO
      END DO
    END DO
    WRITE (*, '(A,I0,A,I0,A,ES10.3,A,ES10.3,A,ES10.3)') '  damped release: cap active at ', nact, &
      ' rows (N < 0 at ', nneg, '); slack-end blend work / W_n ', slack_worst, &
      ' (uncapped ', unc_max, '); largest excess over the bound / W_n ', worst
    CALL require(unc_max > 10.0_wp, 'damped-release:uncapped-creates-energy')
    CALL require(slack_worst <= 1.0_wp + 1.0e-9_wp, 'damped-release:slack-end-bounded')
    CALL require(worst <= 1.0e-9_wp, 'damped-release:bound')
    ! the capped force is continuous where the end state crosses the rest length and the band
    ! edge l0 + c e_n (turning 5 degrees, extending at 0.5 m/s at t_n)
    vn = 0.0_wp
    vn(10:12) = 0.5_wp*tn
    dir = COS(5.0_wp*PI/180.0_wp)*tn + SIN(5.0_wp*PI/180.0_wp)*u
    DO i = 1, 2
      e1 = MERGE(0.0_wp, band*e0, i == 1)
      q1 = qn
      q1(10:12) = qn(7:9) + (L0(3) + e1 + 1.0e-12_wp)*dir
      CALL probe_chain(qn, vn, z, q1, L0, EA, RHO_TINY, .TRUE., R, K, axial_damping=AD)
      q1(10:12) = qn(7:9) + (L0(3) + e1 - 1.0e-12_wp)*dir
      CALL probe_chain(qn, vn, z, q1, L0, EA, RHO_TINY, .TRUE., Rp, K, axial_damping=AD)
      dev = MAXVAL(ABS(R(10:12) - Rp(10:12)))/(BA*0.5_wp/L0(3))
      WRITE (*, '(A,A,A,ES10.3)') '  damped release: force jump across the ', &
        TRIM(MERGE('rest length', 'band edge  ', i == 1)), ' / T_d,n = ', dev
      CALL require(dev < 1.0e-6_wp, 'damped-release:continuous')
    END DO
    ! the tangent where the cap acts: a slack end and a taut end in the band, turning 5 degrees
    q1 = qn
    q1(10:12) = qn(7:9) + L0(3)*(1.0_wp - 1.0e-4_wp)*dir
    CALL damped_tangent_case('damped-release-slack', qn, vn, q1, L0, EA, AD, t0)
    q1(10:12) = qn(7:9) + L0(3)*(1.0_wp + 1.0e-4_wp)*dir
    CALL damped_tangent_case('damped-release-band', qn, vn, q1, L0, EA, AD, t0)
    CALL reset_chain_load()
  END SUBROUTINE case_damped_elastic_release

  SUBROUTINE case_length_change_cap_terms()
    !! The release cap under a length change of the end segment (active line control), hauled
    !! in (0.82 to 0.8 m) and paid out (0.78 to 0.8 m), its rate changing too. Its step-start
    !! quantities take the step-start length and rate (start_l0, start_l0_rate): e_n, T_n, W_n,
    !! the secant T_n/e_n, the law stiffness k_n and the dashpot tension T_d,n; its end-state
    !! quantities the new ones: e_{n+1}, T^_{n+1} = min(T_n/e_n, k_n) e_{n+1}, T_d,n+1 and the
    !! dashpot weight phi (band l0 to l0 + c e_n). (a) An elastic segment with a two-sided
    !! dashpot turning by 5 and 45 degrees and ending slack, in the band or above it: the change
    !! the dashpot share makes to the cap against the closed form. (b) A damped law segment
    !! (ea = 0) with a damping-dominated start: the cap against the closed form with the
    !! bounded secant. (c) The elastic segment with a dashpot slack at the step-start length
    !! (e_n = -2 mm against l0_c; on the haul-in pass taut against the new length), extending at
    !! 0.5 m/s and turning by 5 to 135 degrees: the kept dashpot share against the closed form
    !! (W_d + N_d)/p, W_d = T_d,n^2 dt l0_c/BA with T_d,n at l0_c and l0_dot_c, N_d from
    !! T_d,n+1 at the new length and rate. The tangent against the finite difference on both
    !! paths.
    REAL(wp), PARAMETER :: L0(3) = [1.0_wp, 1.2_wp, 0.8_wp], EA(3) = [1.0e6_wp, 1.5e6_wp, 0.8e6_wp]
    REAL(wp), PARAMETER :: DIRS(3, 3) = RESHAPE([1.0_wp, 0.2_wp, 0.1_wp, 0.3_wp, 1.0_wp, -0.2_wp, &
                                                 -0.2_wp, 0.4_wp, 1.0_wp], [3, 3])
    REAL(wp), PARAMETER :: THETA(2) = [5.0_wp, 45.0_wp]
    REAL(wp), PARAMETER :: S1(6) = [-1.0e-3_wp, -1.0e-5_wp, 2.0e-4_wp, 6.0e-4_wp, 1.5e-3_wp, 3.0e-3_wp]
    REAL(wp), PARAMETER :: DT = 0.05_wp, RHO = 0.4_wp, BA = 2.0e4_wp, EA_LAW = 0.8e6_wp, BA_LAW = 2.0e5_wp
    REAL(wp), PARAMETER :: RHO_TINY(3) = [1.0e-12_wp, 1.0e-12_wp, 1.0e-12_wp]
    REAL(wp) :: ls3, rs, rn, ls(3), qn(12), vn(12), z(12), q1(12), v1(12), sl(12), jq(12, 12), jv(12, 12)
    REAL(wp) :: Ra(12), Rb(12), K(9, 9), tn(3), u(3), dir(3), d0(3), d1(3), t1(3), ln, l1, e0, e1, t0, w0
    REAL(wp) :: p, p1, k0, that, td0, td1, phi, kc, num, dg, du, dd, am, af, beta, gamma, band, err, worst
    REAL(wp) :: kn, wd, nd, best, qbest(12)
    REAL(wp), PARAMETER :: THETA_S(4) = [5.0_wp, 45.0_wp, 90.0_wp, 135.0_wp]
    REAL(wp), PARAMETER :: OFS_S(7) = [-0.02_wp, -0.003_wp, 0.0_wp, 0.003_wp, 0.02_wp, 0.1_wp, 0.3_wp]
    INTEGER :: ip, i, j, nact
    LOGICAL :: damped
    am = (2.0_wp*RHO - 1.0_wp)/(RHO + 1.0_wp)
    af = RHO/(RHO + 1.0_wp)
    beta = 0.25_wp*(1.0_wp - am + af)**2
    gamma = 0.5_wp - am + af
    band = af/(1.0_wp - af)
    z = 0.0_wp
    DO ip = 1, 2
      ! pass 1 hauls in, pass 2 pays out
      ls3 = MERGE(0.82_wp, 0.78_wp, ip == 1)
      rs = MERGE(-0.02_wp, 0.02_wp, ip == 1)
      rn = MERGE(-0.03_wp, 0.03_wp, ip == 1)
      ls = [L0(1), L0(2), ls3]
      ! (a) the elastic segment with a dashpot
      CALL reset_chain_load()
      cb_dash_elem = 3
      cb_ba_dash = BA
      CALL chain_nodes(DIRS, [0.010_wp, 0.020_wp, 0.001_wp], ls, qn)
      d0 = qn(10:12) - qn(7:9)
      ln = NORM2(d0)
      tn = d0/ln
      u = [tn(2), -tn(1), 0.0_wp]
      u = u/NORM2(u)
      vn = 0.0_wp
      vn(10:12) = 0.5_wp*tn
      ! the step-start load at the step-start length and rate, then the dashpot at the new ones
      cb_l0_dash = ls3
      cb_l0dot_dash = rs
      CALL chain_load(qn, vn, sl, jq, jv)
      cb_l0_dash = L0(3)
      cb_l0dot_dash = rn
      e0 = ln - ls3
      t0 = EA(3)*(ln/ls3 - 1.0_wp)
      w0 = 0.5_wp*t0*e0
      td0 = BA*(DOT_PRODUCT(tn, vn(10:12) - vn(7:9)) - ln*rs/ls3)/ls3
      worst = 0.0_wp
      nact = 0
      DO i = 1, SIZE(THETA)
        DO j = 1, SIZE(S1)
          dir = COS(THETA(i)*PI/180.0_wp)*tn + SIN(THETA(i)*PI/180.0_wp)*u
          q1 = qn
          q1(10:12) = qn(7:9) + L0(3)*(1.0_wp + S1(j))*dir
          CALL probe_chain(qn, vn, z, q1, L0, EA, RHO_TINY, .TRUE., Ra, K, axial_damping=[0.0_wp, 0.0_wp, BA], &
                           start_load=sl, start_l0=ls, axial_l0_rate=[0.0_wp, 0.0_wp, rn], &
                           start_l0_rate=[0.0_wp, 0.0_wp, rs])
          CALL probe_chain(qn, vn, z, q1, L0, EA, RHO_TINY, .TRUE., Rb, K, start_load=sl, start_l0=ls)
          ! the closed form of the two caps on the end segment
          v1 = gamma/(beta*DT)*(q1 - qn) + (1.0_wp - gamma/beta)*vn
          v1(1:3) = 0.0_wp
          d1 = q1(10:12) - q1(7:9)
          l1 = NORM2(d1)
          t1 = d1/l1
          e1 = l1 - L0(3)
          p = ln - DOT_PRODUCT(tn, d1)
          p1 = l1 - DOT_PRODUCT(t1, d0)
          k0 = t0/e0
          that = k0*MAX(e1, 0.0_wp)
          du = 0.0_wp
          IF (p > 0.0_wp) du = MIN(MAX(w0 + (1.0_wp - af)*that*p1, 0.0_wp)/p - af*t0, 0.0_wp)
          dd = du
          damped = l1 < L0(3) + band*e0
          IF (damped) THEN
            dd = 0.0_wp
            IF (p > 0.0_wp) THEN
              phi = MIN(1.0_wp, MAX(0.0_wp, 1.0_wp - e1/(band*e0)))
              td1 = BA*(DOT_PRODUCT(t1, v1(10:12) - v1(7:9)) - l1*rn/L0(3))/L0(3)
              num = w0 + (1.0_wp - af)*(that + phi*td1)*p1
              kc = t0 + phi*td0
              dg = MAX(num, 0.0_wp)/p
              dd = MIN(dg - af*kc, 0.0_wp)
            END IF
          END IF
          IF (ABS(dd - du) > 1.0e-6_wp*t0) nact = nact + 1
          err = MAX(MAXVAL(ABS(Ra(10:12) - Rb(10:12) - (dd - du)*tn)), MAXVAL(ABS(Ra(7:9) - Rb(7:9) + (dd - du)*tn)))
          worst = MAX(worst, err/(t0 + ABS(td0)))
        END DO
      END DO
      WRITE (*, '(A,I0,A,I0,A,ES10.3)') '  length change, pass ', ip, ': dashpot share of the cap active at ', nact, &
        ' states; largest deviation from the closed form / (T_n + |T_d,n|) ', worst
      CALL require(nact >= 2, 'lengths-cap:dashpot-share-active')
      CALL require(worst < 1.0e-9_wp, 'lengths-cap:dashpot-closed-form')
      dir = COS(THETA(1)*PI/180.0_wp)*tn + SIN(THETA(1)*PI/180.0_wp)*u
      q1 = qn
      q1(10:12) = qn(7:9) + L0(3)*(1.0_wp + 2.0e-4_wp)*dir
      DO i = 1, 2
        CALL fd_tangent_check('lengths-cap-dashpot', qn, vn, z, q1, L0, EA, [2.0_wp, 3.0_wp, 1.5_wp], i == 1, &
                              axial_damping=[0.0_wp, 0.0_wp, BA], start_load=sl, start_l0=ls, &
                              axial_l0_rate=[0.0_wp, 0.0_wp, rn], start_l0_rate=[0.0_wp, 0.0_wp, rs])
      END DO
      ! (c) the dashpot segment slack at the step-start length
      CALL reset_chain_load()
      cb_dash_elem = 3
      cb_ba_dash = BA
      CALL chain_nodes(DIRS, [0.010_wp, 0.020_wp, -2.0e-3_wp/ls3], ls, qn)
      d0 = qn(10:12) - qn(7:9)
      ln = NORM2(d0)
      tn = d0/ln
      u = [tn(2), -tn(1), 0.0_wp]
      u = u/NORM2(u)
      vn = 0.0_wp
      vn(10:12) = 0.5_wp*tn
      cb_l0_dash = ls3
      cb_l0dot_dash = rs
      CALL chain_load(qn, vn, sl, jq, jv)
      cb_l0_dash = L0(3)
      cb_l0dot_dash = rn
      CALL require(ln < ls3, 'lengths-cap:slack-start')
      td0 = BA*(DOT_PRODUCT(tn, vn(10:12) - vn(7:9)) - ln*rs/ls3)/ls3
      wd = td0*td0*DT*ls3/BA
      worst = 0.0_wp
      nact = 0
      best = 0.0_wp
      qbest = qn
      DO i = 1, SIZE(THETA_S)
        DO j = 1, SIZE(OFS_S)
          dir = COS(THETA_S(i)*PI/180.0_wp)*tn + SIN(THETA_S(i)*PI/180.0_wp)*u
          q1 = qn
          q1(10:12) = qn(7:9) + MAX(ln*COS(THETA_S(i)*PI/180.0_wp) + OFS_S(j), 0.05_wp*L0(3))*dir
          CALL probe_chain(qn, vn, z, q1, L0, EA, RHO_TINY, .TRUE., Ra, K, axial_damping=[0.0_wp, 0.0_wp, BA], &
                           start_load=sl, start_l0=ls, axial_l0_rate=[0.0_wp, 0.0_wp, rn], &
                           start_l0_rate=[0.0_wp, 0.0_wp, rs])
          CALL probe_chain(qn, vn, z, q1, L0, EA, RHO_TINY, .TRUE., Rb, K, start_load=sl, start_l0=ls)
          v1 = gamma/(beta*DT)*(q1 - qn) + (1.0_wp - gamma/beta)*vn
          v1(1:3) = 0.0_wp
          d1 = q1(10:12) - q1(7:9)
          l1 = NORM2(d1)
          t1 = d1/l1
          p = ln - DOT_PRODUCT(tn, d1)
          p1 = l1 - DOT_PRODUCT(t1, d0)
          td1 = BA*(DOT_PRODUCT(t1, v1(10:12) - v1(7:9)) - l1*rn/L0(3))/L0(3)
          nd = MAX((1.0_wp - af)*td1*p1, 0.0_wp)
          dd = 0.0_wp
          dg = 0.0_wp
          IF (td0*p > 0.0_wp) THEN
            dg = (wd + nd)/p
            IF (ABS(dg) < af*ABS(td0)) dd = dg - af*td0
          END IF
          IF (ABS(dd) > 1.0e-6_wp*ABS(td0)) nact = nact + 1
          IF (ABS(dd) > best .AND. ABS(dg) < 0.5_wp*af*ABS(td0) .AND. &
              ABS((1.0_wp - af)*td1*p1) > 0.1_wp*wd) THEN
            best = ABS(dd)
            qbest = q1
          END IF
          err = MAX(MAXVAL(ABS(Ra(10:12) - Rb(10:12) - dd*tn)), MAXVAL(ABS(Ra(7:9) - Rb(7:9) + dd*tn)))
          worst = MAX(worst, err/ABS(td0))
        END DO
      END DO
      WRITE (*, '(A,I0,A,I0,A,I0,A,ES10.3)') '  length change, pass ', ip, ': slack-start dashpot cap active at ', &
        nact, ' of ', SIZE(THETA_S)*SIZE(OFS_S), ' states; largest deviation from the closed form / |T_d,n| ', worst
      CALL require(nact >= 4 .AND. best > 0.0_wp, 'lengths-cap:slack-dashpot-active')
      CALL require(worst < 1.0e-9_wp, 'lengths-cap:slack-dashpot-closed-form')
      DO i = 1, 2
        CALL fd_tangent_check('lengths-cap-slack-dashpot', qn, vn, z, qbest, L0, EA, [2.0_wp, 3.0_wp, 1.5_wp], &
                              i == 1, axial_damping=[0.0_wp, 0.0_wp, BA], start_load=sl, start_l0=ls, &
                              axial_l0_rate=[0.0_wp, 0.0_wp, rn], start_l0_rate=[0.0_wp, 0.0_wp, rs])
      END DO
      ! (b) the damped law segment (ea = 0): T_n mostly damping at e_n = 1 um
      CALL reset_chain_load()
      cb_law_elem = 3
      cb_ea_law = EA_LAW
      cb_ba_law = BA_LAW
      CALL chain_nodes(DIRS, [0.010_wp, 0.020_wp, 1.0e-6_wp/ls3], ls, qn)
      d0 = qn(10:12) - qn(7:9)
      ln = NORM2(d0)
      tn = d0/ln
      u = [tn(2), -tn(1), 0.0_wp]
      u = u/NORM2(u)
      vn = 0.0_wp
      vn(10:12) = 0.05_wp*tn
      cb_l0_law = ls3
      CALL chain_load(qn, vn, sl, jq, jv)
      cb_l0_law = L0(3)
      t0 = DOT_PRODUCT(sl(7:9), tn)
      e0 = ln - ls3
      w0 = 0.5_wp*t0*e0
      kn = EA_LAW/ls3
      k0 = MIN(t0/e0, kn)
      CALL require(t0/e0 > 1.0e3_wp*kn, 'lengths-cap:law-damping-dominated-start')
      worst = 0.0_wp
      nact = 0
      dir = COS(PI/4.0_wp)*tn + SIN(PI/4.0_wp)*u
      DO j = 1, SIZE(S1)
        q1 = qn
        q1(10:12) = qn(7:9) + L0(3)*(1.0_wp + S1(j))*dir
        CALL probe_chain(qn, vn, z, q1, L0, [EA(1), EA(2), 0.0_wp], RHO_TINY, .TRUE., Ra, K, &
                         start_tension=[0.0_wp, 0.0_wp, t0], start_stiffness=[0.0_wp, 0.0_wp, kn], start_load=sl, &
                         start_l0=ls)
        CALL probe_chain(qn, vn, z, q1, L0, [EA(1), EA(2), 0.0_wp], RHO_TINY, .TRUE., Rb, K, start_load=sl, start_l0=ls)
        d1 = q1(10:12) - q1(7:9)
        l1 = NORM2(d1)
        t1 = d1/l1
        e1 = l1 - L0(3)
        p = ln - DOT_PRODUCT(tn, d1)
        p1 = l1 - DOT_PRODUCT(t1, d0)
        that = k0*MAX(e1, 0.0_wp)
        dd = 0.0_wp
        IF (p > 0.0_wp) dd = MIN(MAX(w0 + (1.0_wp - af)*that*p1, 0.0_wp)/p - af*t0, 0.0_wp)
        IF (ABS(dd) > 1.0e-6_wp*t0) nact = nact + 1
        err = MAX(MAXVAL(ABS(Ra(10:12) - Rb(10:12) - dd*tn)), MAXVAL(ABS(Ra(7:9) - Rb(7:9) + dd*tn)))
        worst = MAX(worst, err/t0)
      END DO
      WRITE (*, '(A,I0,A,I0,A,ES10.3)') '  length change, pass ', ip, ': law cap active at ', nact, &
        ' states; largest deviation from the closed form / T_n ', worst
      CALL require(nact >= 4, 'lengths-cap:law-active')
      CALL require(worst < 1.0e-9_wp, 'lengths-cap:law-closed-form')
      q1 = qn
      q1(10:12) = qn(7:9) + L0(3)*(1.0_wp + 6.0e-4_wp)*dir
      DO i = 1, 2
        CALL fd_tangent_check('lengths-cap-law', qn, vn, z, q1, L0, [EA(1), EA(2), 0.0_wp], [2.0_wp, 3.0_wp, 1.5_wp], &
                              i == 1, start_tension=[0.0_wp, 0.0_wp, t0], start_stiffness=[0.0_wp, 0.0_wp, kn], &
                              start_load=sl, start_l0=ls)
      END DO
    END DO
    CALL reset_chain_load()
  END SUBROUTINE case_length_change_cap_terms

  SUBROUTINE damped_tangent_case(label, qn, vn, q1, l0, ea, ad, t0)
    !! The damped chain of case_damped_elastic_release at one trial state where the cap acts:
    !! the cap is active, and the tangent matches the finite difference on both paths.
    CHARACTER(*), INTENT(IN) :: label
    REAL(wp), INTENT(IN) :: qn(12), vn(12), q1(12), l0(3), ea(3), ad(3), t0
    REAL(wp) :: Ra(12), Rb(12), Kd(9, 9), z(12)
    z = 0.0_wp
    CALL probe_chain(qn, vn, z, q1, l0, ea, [1.0e-12_wp, 1.0e-12_wp, 1.0e-12_wp], .TRUE., Ra, Kd, axial_damping=ad)
    CALL probe_chain(qn, vn, z, q1, l0, ea, [1.0e-12_wp, 1.0e-12_wp, 1.0e-12_wp], .TRUE., Rb, Kd)
    CALL require(MAXVAL(ABS(Ra(10:12) - Rb(10:12))) > 1.0e-2_wp*t0, label//':cap-active')
    CALL fd_tangent_check(label, qn, vn, z, q1, l0, ea, [2.0_wp, 3.0_wp, 1.5_wp], .TRUE., axial_damping=ad)
    CALL fd_tangent_check(label, qn, vn, z, q1, l0, ea, [2.0_wp, 3.0_wp, 1.5_wp], .FALSE., axial_damping=ad)
  END SUBROUTINE damped_tangent_case

  SUBROUTINE case_slack_dashpot_release()
    !! The dashpot segment of case_damped_elastic_release slack at t_n (e_n = -1.6 mm), its far
    !! end moving at +-0.05, 0.5 or 2 m/s along the chord (dashpot tension T_d,n = BA rate/l0, a
    !! compressive one for the negative rate), turning by 0 to 180 degrees within the step and
    !! ending slack or taut. The kept share alpha_f T_d,n t_n returns T_k p (T_k the kept
    !! tension the residual carries, p the projected shortening): at most
    !! W_d + N_d, W_d = T_d,n ldot_n dt the dashpot's one-step dissipation and
    !! N_d = max((1 - alpha_f) T_d,n+1 p_n+1, 0) the end share's credit. Without the cap (no
    !! axial_damping) it returns alpha_f T_d,n p, up to 46 times W_d + N_d on these rows (the cap
    !! acts where the end share does little work: turns that end near the projection of the
    !! step-start chord; a reversal along the chord feeds the end share's dashpot instead).
    !! A slack segment with no step-start dashpot
    !! force keeps the plain blend, and the tangent matches the finite difference where the
    !! cap acts.
    REAL(wp), PARAMETER :: L0(3) = [1.0_wp, 1.2_wp, 0.8_wp], EA(3) = [1.0e6_wp, 1.5e6_wp, 0.8e6_wp]
    REAL(wp), PARAMETER :: DIRS(3, 3) = RESHAPE([1.0_wp, 0.2_wp, 0.1_wp, 0.3_wp, 1.0_wp, -0.2_wp, &
                                                 -0.2_wp, 0.4_wp, 1.0_wp], [3, 3])
    REAL(wp), PARAMETER :: THETA(8) = [0.0_wp, 2.0_wp, 5.0_wp, 20.0_wp, 45.0_wp, 90.0_wp, 135.0_wp, 180.0_wp]
    REAL(wp), PARAMETER :: S1(9) = [-0.5_wp, -0.1_wp, -0.01_wp, -2.0e-3_wp, -1.0e-4_wp, 1.0e-4_wp, &
                                    1.0e-3_wp, 0.01_wp, 0.05_wp]
    REAL(wp), PARAMETER :: OFS(5) = [-0.02_wp, -0.003_wp, 0.0_wp, 0.003_wp, 0.02_wp]
    REAL(wp), PARAMETER :: RATE(4) = [0.05_wp, 0.5_wp, 2.0_wp, -0.5_wp], DT = 0.05_wp, RHO = 0.4_wp
    REAL(wp), PARAMETER :: BA = 2.0e4_wp, AD(3) = [0.0_wp, 0.0_wp, BA]
    REAL(wp), PARAMETER :: RHO_TINY(3) = [1.0e-12_wp, 1.0e-12_wp, 1.0e-12_wp]
    REAL(wp) :: qn(12), q1(12), vn(12), z(12), v1(12), R(12), Rp(12), K(9, 9), tn(3), u(3), dir(3)
    REAL(wp) :: d0(3), d1(3), t1(3), l1, td0, td1, p, p1, am, af, beta, gamma, wd, nd, tk, wk, wu
    REAL(wp) :: worst, unc_ratio, unc_excess, dev
    INTEGER :: i, j, ir, nact, nrow
    CALL reset_chain_load()
    cb_dash_elem = 3
    cb_ba_dash = BA
    cb_l0_dash = L0(3)
    am = (2.0_wp*RHO - 1.0_wp)/(RHO + 1.0_wp)
    af = RHO/(RHO + 1.0_wp)
    beta = 0.25_wp*(1.0_wp - am + af)**2
    gamma = 0.5_wp - am + af
    CALL chain_nodes(DIRS, [0.010_wp, 0.020_wp, -0.002_wp], L0, qn)
    z = 0.0_wp
    d0 = qn(10:12) - qn(7:9)
    tn = d0/NORM2(d0)
    u = [tn(2), -tn(1), 0.0_wp]
    u = u/NORM2(u)
    worst = -HUGE(1.0_wp)
    unc_ratio = 0.0_wp
    unc_excess = 0.0_wp
    nact = 0
    nrow = 0
    DO ir = 1, SIZE(RATE)
      vn = 0.0_wp
      vn(10:12) = RATE(ir)*tn
      td0 = BA*RATE(ir)/L0(3)
      wd = td0*RATE(ir)*DT
      DO i = 1, SIZE(THETA)
        DO j = 1, SIZE(S1) + SIZE(OFS)
          dir = COS(THETA(i)*PI/180.0_wp)*tn + SIN(THETA(i)*PI/180.0_wp)*u
          IF (j <= SIZE(S1)) THEN
            l1 = L0(3)*(1.0_wp + S1(j))
          ELSE
            ! the end near the projection of the step-start chord (p_n+1 ~ OFS): a turn whose
            ! end share does little work, where the cap acts
            l1 = MAX(NORM2(d0)*COS(THETA(i)*PI/180.0_wp) + OFS(j - SIZE(S1)), 0.05_wp*L0(3))
          END IF
          q1 = qn
          q1(10:12) = qn(7:9) + l1*dir
          CALL probe_chain(qn, vn, z, q1, L0, EA, RHO_TINY, .TRUE., R, K, axial_damping=AD)
          CALL probe_chain(qn, vn, z, q1, L0, EA, RHO_TINY, .TRUE., Rp, K)
          v1 = gamma/(beta*DT)*(q1 - qn) + (1.0_wp - gamma/beta)*vn
          v1(1:3) = 0.0_wp
          d1 = q1(10:12) - q1(7:9)
          l1 = NORM2(d1)
          t1 = d1/l1
          p = NORM2(d0) - DOT_PRODUCT(tn, d1)
          p1 = l1 - DOT_PRODUCT(t1, d0)
          td1 = BA*DOT_PRODUCT(t1, v1(10:12) - v1(7:9))/L0(3)
          nd = MAX((1.0_wp - af)*td1*p1, 0.0_wp)
          ! the kept tension: alpha_f T_d,n plus the cap's correction along t_n at node b
          tk = af*td0 + DOT_PRODUCT(R(10:12) - Rp(10:12), tn)
          wk = tk*p
          wu = af*td0*p
          nrow = nrow + 1
          IF (MAXVAL(ABS(R(10:12) - Rp(10:12))) > 1.0e-9_wp*ABS(td0)) nact = nact + 1
          worst = MAX(worst, (wk - (wd + nd))/wd)
          unc_ratio = MAX(unc_ratio, wu/(wd + nd))
          unc_excess = MAX(unc_excess, (wu - (wd + nd))/wd)
          IF (j > SIZE(S1)) CYCLE
          IF (THETA(i) == 0.0_wp .AND. S1(j)*RATE(ir) > 0.0_wp) THEN
            ! a segment that keeps its direction and moves on at its step-start sense: uncapped
            CALL require(MAXVAL(ABS(R(10:12) - Rp(10:12))) == 0.0_wp, 'slack-dashpot:same-sense-uncapped')
          END IF
        END DO
      END DO
    END DO
    WRITE (*, '(A,I0,A,I0,A,ES10.3,A,ES10.3,A,ES10.3)') '  slack dashpot: cap active at ', nact, ' of ', nrow, &
      ' rows; kept-share work over W_d + N_d, / W_d: ', worst, ' (uncapped ', unc_excess, &
      '; uncapped / (W_d + N_d) up to ', unc_ratio
    CALL require(nact >= 20, 'slack-dashpot:cap-active')
    CALL require(unc_ratio > 10.0_wp, 'slack-dashpot:uncapped-exceeds')
    CALL require(worst <= 1.0e-9_wp, 'slack-dashpot:bound')
    ! a slack segment with no step-start dashpot force (ends at rest along the chord) keeps the
    ! plain blend bit for bit, reversed or not
    vn = 0.0_wp
    vn(10:12) = 0.5_wp*u
    q1 = qn
    q1(10:12) = qn(7:9) - 0.9_wp*L0(3)*tn
    CALL probe_chain(qn, vn, z, q1, L0, EA, RHO_TINY, .TRUE., R, K, axial_damping=AD)
    CALL probe_chain(qn, vn, z, q1, L0, EA, RHO_TINY, .TRUE., Rp, K)
    dev = MAXVAL(ABS(R - Rp))
    CALL require(dev == 0.0_wp, 'slack-dashpot:no-start-dashpot-uncapped')
    ! the tangent where the cap acts: turning 60 degrees with the end at p_n+1 = 3 mm (end
    ! share pushing, no credit) and 20 mm (a positive credit), extending at 0.5 m/s at t_n
    vn = 0.0_wp
    vn(10:12) = 0.5_wp*tn
    dir = COS(PI/3.0_wp)*tn + SIN(PI/3.0_wp)*u
    q1 = qn
    q1(10:12) = qn(7:9) + (0.5_wp*NORM2(d0) + 3.0e-3_wp)*dir
    CALL slack_tangent_case('slack-dashpot-no-credit', qn, vn, q1, L0, EA, AD, BA*0.5_wp/L0(3))
    q1(10:12) = qn(7:9) + (0.5_wp*NORM2(d0) + 2.0e-2_wp)*dir
    CALL slack_tangent_case('slack-dashpot-credit', qn, vn, q1, L0, EA, AD, BA*0.5_wp/L0(3))
    CALL reset_chain_load()
  END SUBROUTINE case_slack_dashpot_release

  SUBROUTINE slack_tangent_case(label, qn, vn, q1, l0, ea, ad, td0)
    !! A capped row of case_slack_dashpot_release: the cap is active, and the tangent matches
    !! the finite difference on both paths.
    CHARACTER(*), INTENT(IN) :: label
    REAL(wp), INTENT(IN) :: qn(12), vn(12), q1(12), l0(3), ea(3), ad(3), td0
    REAL(wp) :: Ra(12), Rb(12), Kd(9, 9), z(12)
    z = 0.0_wp
    CALL probe_chain(qn, vn, z, q1, l0, ea, [1.0e-12_wp, 1.0e-12_wp, 1.0e-12_wp], .TRUE., Ra, Kd, axial_damping=ad)
    CALL probe_chain(qn, vn, z, q1, l0, ea, [1.0e-12_wp, 1.0e-12_wp, 1.0e-12_wp], .TRUE., Rb, Kd)
    CALL require(MAXVAL(ABS(Ra(10:12) - Rb(10:12))) > 1.0e-2_wp*ABS(td0), label//':cap-active')
    CALL fd_tangent_check(label, qn, vn, z, q1, l0, ea, [2.0_wp, 3.0_wp, 1.5_wp], .TRUE., axial_damping=ad)
    CALL fd_tangent_check(label, qn, vn, z, q1, l0, ea, [2.0_wp, 3.0_wp, 1.5_wp], .FALSE., axial_damping=ad)
  END SUBROUTINE slack_tangent_case

  SUBROUTINE law_cap_config(label, strain_n, strain_1, dirs_trial)
    CHARACTER(*), INTENT(IN) :: label
    REAL(wp), INTENT(IN) :: strain_n(3), strain_1(3)
    REAL(wp), INTENT(IN), OPTIONAL :: dirs_trial(3, 3)
    REAL(wp), PARAMETER :: L0(3) = [1.0_wp, 1.2_wp, 0.8_wp], EA(3) = [1.0e6_wp, 1.5e6_wp, 0.0_wp]
    REAL(wp), PARAMETER :: EA_LAW = 0.8e6_wp, ALPHA_F = 0.4_wp/1.4_wp
    REAL(wp) :: qn(12), vn(12), an(12), q1(12), R(12), Rnone(12), Rel(12), K(9, 9), f_cap(12), f_raw(12)
    REAL(wp) :: t0, scale
    INTEGER, PARAMETER :: I8 = SELECTED_INT_KIND(18)
    CALL reset_chain_load()
    cb_law_elem = 3
    cb_ea_law = EA_LAW
    cb_l0_law = L0(3)
    CALL chain_states(strain_n, strain_1, L0, qn, vn, an, q1, dirs_trial)
    t0 = EA_LAW*(NORM2(qn(10:12) - qn(7:9))/L0(3) - 1.0_wp)
    ! nearly massless chain at rest at t_n: the residual is the blended force
    CALL probe_chain(qn, 0.0_wp*vn, 0.0_wp*an, q1, L0, EA, [1.0e-9_wp, 1.0e-9_wp, 1.0e-9_wp], .TRUE., R, K, &
                     start_tension=[0.0_wp, 0.0_wp, t0])
    CALL probe_chain(qn, 0.0_wp*vn, 0.0_wp*an, q1, L0, EA, [1.0e-9_wp, 1.0e-9_wp, 1.0e-9_wp], .TRUE., Rnone, K)
    ! the entries of the elastic segments are ignored
    CALL probe_chain(qn, 0.0_wp*vn, 0.0_wp*an, q1, L0, EA, [1.0e-9_wp, 1.0e-9_wp, 1.0e-9_wp], .TRUE., Rel, K, &
                     start_tension=[99.0_wp, -5.0_wp, t0])
    CALL blended_force(qn, q1, L0, [EA(1), EA(2), EA_LAW], ALPHA_F, .TRUE., f_cap)
    CALL blended_force(qn, q1, L0, [EA(1), EA(2), EA_LAW], ALPHA_F, .FALSE., f_raw)
    scale = MAXVAL(ABS(f_raw))
    CALL require(MAXVAL(ABS(f_cap - f_raw)) > 1.0e-2_wp*scale, label//':cap-active')
    CALL require(MAXVAL(ABS(R(4:12) - f_cap(4:12))) < 1.0e-6_wp*scale, label//':residual-closed-form')
    CALL require(MAXVAL(ABS(Rnone(4:12) - f_raw(4:12))) < 1.0e-6_wp*scale, label//':no-start-tension-uncapped')
    CALL require(ALL(TRANSFER(Rel, [0_I8]) == TRANSFER(R, [0_I8])), label//':elastic-entries-ignored')
    ! the tangent with inertia, on both paths
    CALL fd_tangent_check(label, qn, vn, an, q1, L0, EA, [2.0_wp, 3.0_wp, 1.5_wp], .TRUE., &
                          start_tension=[0.0_wp, 0.0_wp, t0])
    CALL fd_tangent_check(label, qn, vn, an, q1, L0, EA, [2.0_wp, 3.0_wp, 1.5_wp], .FALSE., &
                          start_tension=[0.0_wp, 0.0_wp, t0])
    CALL reset_chain_load()
  END SUBROUTINE law_cap_config

  SUBROUTINE case_load_share_tangent()
    !! All segments elastic and taut; the callback load carries a quadratic drag and a cubic
    !! position load (and an added mass on the dense path).
    REAL(wp), PARAMETER :: L0(3) = [1.0_wp, 1.2_wp, 0.8_wp], EA(3) = [1.0e6_wp, 1.5e6_wp, 0.8e6_wp]
    REAL(wp), PARAMETER :: RHO = 0.4_wp, DT = 0.05_wp
    REAL(wp) :: qn(12), vn(12), an(12), q1(12), v1(12), R(12), K(9, 9), f_int(12), f1(12), fn0(12)
    REAL(wp) :: jq(12, 12), jv(12, 12), alpha_m, alpha_f, beta, gamma, scale, load_scale
    INTEGER :: i
    CALL reset_chain_load()
    CALL chain_states([0.010_wp, 0.020_wp, 0.010_wp], [0.020_wp, 0.015_wp, 0.020_wp], L0, qn, vn, an, q1)
    cb_drag = 2.0e4_wp
    cb_spring = 1.0e8_wp
    DO i = 1, 12
      cb_q0(i) = qn(i) + 0.05_wp*SIN(0.9_wp*REAL(i, wp))
    END DO
    alpha_m = (2.0_wp*RHO - 1.0_wp)/(RHO + 1.0_wp)
    alpha_f = RHO/(RHO + 1.0_wp)
    beta = 0.25_wp*(1.0_wp - alpha_m + alpha_f)**2
    gamma = 0.5_wp - alpha_m + alpha_f
    ! closed form, nearly massless chain at rest at t_n: v_{n+1} = gamma/(beta dt) (q1 - qn) at
    ! the free nodes, the fixed node held
    v1 = gamma/(beta*DT)*(q1 - qn)
    v1(1:3) = 0.0_wp
    CALL probe_chain(qn, 0.0_wp*vn, 0.0_wp*an, q1, L0, EA, [1.0e-9_wp, 1.0e-9_wp, 1.0e-9_wp], .TRUE., R, K)
    CALL blended_force(qn, q1, L0, EA, alpha_f, .TRUE., f_int)
    CALL chain_load(q1, v1, f1, jq, jv)
    CALL chain_load(qn, 0.0_wp*vn, fn0, jq, jv)
    scale = MAXVAL(ABS(f_int))
    load_scale = MAXVAL(ABS(f1(4:12)))
    CALL require(load_scale > 0.1_wp*scale, 'load-share:load-significant')
    CALL require(MAXVAL(ABS(R(4:12) - (f_int(4:12) - (1.0_wp - alpha_f)*f1(4:12) - alpha_f*fn0(4:12)))) < &
                 1.0e-6_wp*scale, 'load-share:residual-closed-form')
    ! the tangent with inertia: banded, and dense with the added mass
    CALL fd_tangent_check('load-share', qn, vn, an, q1, L0, EA, [2.0_wp, 3.0_wp, 1.5_wp], .TRUE.)
    cb_madd = 50.0_wp
    CALL fd_tangent_check('load-share+added-mass', qn, vn, an, q1, L0, EA, [2.0_wp, 3.0_wp, 1.5_wp], .FALSE.)
    CALL reset_chain_load()
  END SUBROUTINE case_load_share_tangent

  SUBROUTINE solve_chain(work, qn, vn, an, ends, dt, start_load, start_tension, q_out, v_out, a_out, n_iter, es)
    !! One banded step of the chain with node 1 prescribed at ends (at rest).
    TYPE(CD_CableGenAlphaWorkspace), INTENT(INOUT) :: work
    REAL(wp), INTENT(IN) :: qn(12), vn(12), an(12), ends(3), dt, start_load(12), start_tension(3)
    REAL(wp), INTENT(OUT) :: q_out(12), v_out(12), a_out(12)
    INTEGER, INTENT(OUT) :: n_iter, es
    REAL(wp), PARAMETER :: L0(3) = [1.0_wp, 1.2_wp, 0.8_wp], EA(3) = [1.0e6_wp, 1.5e6_wp, 0.0_wp]
    INTEGER :: conn(2, 3)
    REAL(wp) :: pq(12)
    LOGICAL :: converged, stalled
    TYPE(GenAlphaConfig) :: cfg
    CHARACTER(120) :: em
    conn = RESHAPE([1, 2, 2, 3, 3, 4], [2, 3])
    cfg%rho_inf = 0.4_wp
    pq = qn
    pq(1:3) = ends
    CALL CD_Cable_Gen_Alpha_Step(qn, vn, an, conn, L0, EA, [2.0_wp, 3.0_wp, 1.5_wp], .TRUE., 0.0_wp*qn, [1, 2, 3], &
                                 dt, cfg, q_out, v_out, a_out, converged, stalled, n_iter, es, em, &
                                 load_band_proc=cb_load_band, load_force_proc=cb_force, prescribed_q=pq, &
                                 prescribed_v=0.0_wp*qn, prescribed_a=0.0_wp*qn, workspace=work, &
                                 start_load=start_load, start_tension=start_tension)
    IF (es == CD_DYN_OK .AND. .NOT. converged) es = -1
  END SUBROUTINE solve_chain

  LOGICAL FUNCTION same_bits(x, y) RESULT(same)
    REAL(wp), INTENT(IN) :: x(:), y(:)
    INTEGER, PARAMETER :: I8 = SELECTED_INT_KIND(18)
    same = ALL(TRANSFER(x, [0_I8]) == TRANSFER(y, [0_I8]))
  END FUNCTION same_bits

  SUBROUTINE case_warm_resolve_reuse()
    !! A junction-style re-solve of the same step (guess_armed) from the same committed state
    !! with moved ends: the step-start data of the first call are reused.
    REAL(wp), PARAMETER :: L0(3) = [1.0_wp, 1.2_wp, 0.8_wp], EA_LAW = 0.8e6_wp, ALPHA_F = 0.4_wp/1.4_wp
    REAL(wp), PARAMETER :: DIRS(3, 3) = RESHAPE([1.0_wp, 0.2_wp, 0.1_wp, 0.3_wp, 1.0_wp, -0.2_wp, &
                                                 -0.2_wp, 0.4_wp, 1.0_wp], [3, 3])
    TYPE(CD_CableGenAlphaWorkspace) :: warm, cold, wrong, cold2
    REAL(wp) :: qn(12), vn(12), an(12), qn2(12), sl(12), sl2(12), ends_a(3), ends_b(3), u3(3)
    REAL(wp) :: qw(12), vw(12), aw(12), qc(12), vc(12), ac(12), qx(12), vx(12), ax(12), t0, t02, e0, e1
    REAL(wp) :: jq(12, 12), jv(12, 12)
    INTEGER :: itw, itc, itx, es
    CALL reset_chain_load()
    cb_law_elem = 3
    cb_ea_law = EA_LAW
    cb_l0_law = L0(3)
    cb_drag = 500.0_wp
    cb_spring = 1.0e6_wp
    CALL chain_nodes(DIRS, [0.010_wp, 0.020_wp, 0.010_wp], L0, qn)
    cb_q0 = qn
    ! node 4 runs toward node 3, so segment 3 (the law) releases deeply within the step
    u3 = (qn(10:12) - qn(7:9))/NORM2(qn(10:12) - qn(7:9))
    vn = 0.0_wp
    vn(10:12) = -1.5_wp*u3
    vn(4:6) = [0.05_wp, -0.02_wp, 0.01_wp]
    an = 0.0_wp
    ends_a = qn(1:3) + [0.01_wp, 0.0_wp, 0.0_wp]
    ends_b = qn(1:3) + [0.0_wp, 0.012_wp, -0.004_wp]
    CALL chain_load(qn, vn, sl, jq, jv)
    t0 = EA_LAW*0.010_wp
    ! first call (cold), then the armed re-solve given wrong start data, against a cold solve
    CALL solve_chain(warm, qn, vn, an, ends_a, 0.05_wp, sl, [0.0_wp, 0.0_wp, t0], qw, vw, aw, itw, es)
    CALL require(es == CD_DYN_OK, 'reuse:first-call')
    warm%guess_armed = .TRUE.
    CALL solve_chain(warm, qn, vn, an, ends_b, 0.05_wp, sl + 1.0e3_wp, [0.0_wp, 0.0_wp, 5.0_wp*t0], qw, vw, aw, &
                     itw, es)
    CALL require(es == CD_DYN_OK, 'reuse:warm-call')
    CALL solve_chain(cold, qn, vn, an, ends_b, 0.05_wp, sl, [0.0_wp, 0.0_wp, t0], qc, vc, ac, itc, es)
    CALL require(es == CD_DYN_OK, 'reuse:cold-call')
    CALL require(itw == itc .AND. same_bits(qw, qc) .AND. same_bits(vw, vc) .AND. same_bits(aw, ac), &
                 'reuse:warm-equals-cold-bitwise')
    ! the cap is active at the solution, and the wrong start data would change it
    e0 = NORM2(qn(10:12) - qn(7:9)) - L0(3)
    e1 = NORM2(qc(10:12) - qc(7:9)) - L0(3)
    CALL require(e0 - e1 > e0/(2.0_wp*ALPHA_F), 'reuse:cap-active')
    CALL solve_chain(wrong, qn, vn, an, ends_b, 0.05_wp, sl + 1.0e3_wp, [0.0_wp, 0.0_wp, 5.0_wp*t0], qx, vx, ax, &
                     itx, es)
    CALL require(es == CD_DYN_OK .AND. .NOT. same_bits(qx, qc), 'reuse:start-data-matter')
    ! an unarmed call that fails before computing its start data (dt < 0), then an armed call
    ! from another state: it must not reuse the start data of the first state
    qn2 = qn
    qn2(7:9) = qn2(7:9) + [0.003_wp, -0.002_wp, 0.001_wp]
    CALL chain_load(qn2, vn, sl2, jq, jv)
    t02 = EA_LAW*(NORM2(qn2(10:12) - qn2(7:9))/L0(3) - 1.0_wp)
    CALL solve_chain(warm, qn2, vn, an, ends_b, -1.0_wp, sl2, [0.0_wp, 0.0_wp, t02], qx, vx, ax, itx, es)
    CALL require(es /= CD_DYN_OK, 'reuse:early-failure')
    warm%guess_armed = .TRUE.
    CALL solve_chain(warm, qn2, vn, an, ends_b, 0.05_wp, sl2, [0.0_wp, 0.0_wp, t02], qw, vw, aw, itw, es)
    CALL require(es == CD_DYN_OK, 'reuse:armed-after-failure')
    CALL solve_chain(cold2, qn2, vn, an, ends_b, 0.05_wp, sl2, [0.0_wp, 0.0_wp, t02], qc, vc, ac, itc, es)
    CALL require(es == CD_DYN_OK .AND. itw == itc .AND. same_bits(qw, qc) .AND. same_bits(vw, vc) .AND. &
                 same_bits(aw, ac), 'reuse:no-stale-start-data')
    CALL reset_chain_load()
  END SUBROUTINE case_warm_resolve_reuse

  ! ------------------------------------------------------------------------------------------
  ! Case 9: viscoelastic and Syrope lines that go slack (driver runs)
  ! ------------------------------------------------------------------------------------------

  SUBROUTINE write_syrope_files()
    !! The settings and OWC table of the shipped Syrope example (examples/data/syrope).
    REAL(wp), PARAMETER :: OWC(2, 30) = RESHAPE([ &
                                                0.00000e+00_wp, 0.00000e+00_wp, 2.06897e-03_wp, 1.71768e+05_wp, &
                                                4.13793e-03_wp, 3.30952e+05_wp, 6.20690e-03_wp, 4.78788e+05_wp, &
                                                8.27586e-03_wp, 6.16510e+05_wp, 1.03448e-02_wp, 7.45355e+05_wp, &
                                                1.24138e-02_wp, 8.66556e+05_wp, 1.44828e-02_wp, 9.81351e+05_wp, &
                                                1.65517e-02_wp, 1.09097e+06_wp, 1.86207e-02_wp, 1.19666e+06_wp, &
                                                2.06897e-02_wp, 1.29964e+06_wp, 2.27586e-02_wp, 1.40116e+06_wp, &
                                                2.48276e-02_wp, 1.50245e+06_wp, 2.68966e-02_wp, 1.60474e+06_wp, &
                                                2.89655e-02_wp, 1.70927e+06_wp, 3.10345e-02_wp, 1.81728e+06_wp, &
                                                3.31034e-02_wp, 1.93000e+06_wp, 3.51724e-02_wp, 2.04866e+06_wp, &
                                                3.72414e-02_wp, 2.17450e+06_wp, 3.93103e-02_wp, 2.30876e+06_wp, &
                                                4.13793e-02_wp, 2.45267e+06_wp, 4.34483e-02_wp, 2.60747e+06_wp, &
                                                4.55172e-02_wp, 2.77439e+06_wp, 4.75862e-02_wp, 2.95467e+06_wp, &
                                                4.96552e-02_wp, 3.14954e+06_wp, 5.17241e-02_wp, 3.36024e+06_wp, &
                                                5.37931e-02_wp, 3.58800e+06_wp, 5.58621e-02_wp, 3.83406e+06_wp, &
                                               5.79310e-02_wp, 4.09965e+06_wp, 6.00000e-02_wp, 4.38601e+06_wp], [2, 30])
    INTEGER :: u, i
    OPEN (NEWUNIT=u, FILE='ei0slack_syrope_settings.dat', STATUS='REPLACE', ACTION='WRITE')
    WRITE (u, '(A)') 'ei0slack_syrope_owc.dat  OWC     - Original working-curve table file'
    WRITE (u, '(A)') 'EXP             WCType  - Working-curve formulation'
    WRITE (u, '(A)') '0.20            k1      - First working-curve shape parameter'
    WRITE (u, '(A)') '1.50            k2      - Second working-curve shape parameter'
    CLOSE (u)
    OPEN (NEWUNIT=u, FILE='ei0slack_syrope_owc.dat', STATUS='REPLACE', ACTION='WRITE')
    WRITE (u, '(A)') 'Strain      Tension'
    WRITE (u, '(A)') '(-)         (N)'
    DO i = 1, 30
      WRITE (u, '(ES13.5,1X,ES13.5)') OWC(1, i), OWC(2, i)
    END DO
    CLOSE (u)
  END SUBROUTINE write_syrope_files

  SUBROUTINE write_syrope_deck(path, dt, tmax)
    !! A 230 m Syrope polyester line (115 segments, 80 kg/m) taut from the fairlead
    !! (5, 0, -14) to the anchor (227, 0, -80), working curve of a 1 MN running maximum.
    CHARACTER(*), INTENT(IN) :: path
    REAL(wp), INTENT(IN) :: dt, tmax
    INTEGER :: u
    OPEN (NEWUNIT=u, FILE=path, STATUS='REPLACE', ACTION='WRITE')
    WRITE (u, '(A)') 'EI = 0 slack-taut dynamics regression deck (Syrope)'
    WRITE (u, '(A)') '--- LINE TYPES ---'
    WRITE (u, '(A)') 'Name Diam Mass EA BA EI Cdn Cdt Can Cat'
    WRITE (u, '(A)') '(-) (m) (kg/m) (N) (-) (Nm2) (-) (-) (-) (-)'
    WRITE (u, '(A)') 'rope 0.2 80.0 "SYROPE:ei0slack_syrope_settings.dat|1.53e8|23.12" 1.0e8|1.0e5 0.0 1.2 0.1 1.0 0.0'
    WRITE (u, '(A)') '--- POINTS ---'
    WRITE (u, '(A)') 'ID Type X Y Z Mass Vol CdA Ca'
    WRITE (u, '(A)') '(-) (-) (m) (m) (m) (kg) (m^3) (m^2) (-)'
    WRITE (u, '(A)') '1 Coupled 5.0 0.0 -14.0 0 0 0 0'
    WRITE (u, '(A)') '2 Fixed 227.0 0.0 -80.0 0 0 0 0'
    WRITE (u, '(A)') '--- LINES ---'
    WRITE (u, '(A)') 'ID NodeA NodeB Outputs'
    WRITE (u, '(A)') '(-) (-) (-) (-)'
    WRITE (u, '(A)') '1 1 2 t'
    WRITE (u, '(A)') '--- SYROPE IC ---'
    WRITE (u, '(A)') 'Line(s) Tmax0 Tmean0'
    WRITE (u, '(A)') '(-) (N) (N)'
    WRITE (u, '(A)') '1 1.0e6 5.0e5'
    WRITE (u, '(A)') '--- SECTIONS ---'
    WRITE (u, '(A)') 'LineID LineType Length NumSegs'
    WRITE (u, '(A)') '(-) (-) (m) (-)'
    WRITE (u, '(A)') '1 rope 230.0 115'
    WRITE (u, '(A)') '--- OPTIONS ---'
    WRITE (u, '(A)') '80.0 WtrDpth'
    WRITE (u, '(ES14.7,A)') dt, ' dtM'
    WRITE (u, '(ES14.7,A)') tmax, ' TMax'
    WRITE (u, '(A)') 'ei0slack_surge_syr.txt motionFile'
    WRITE (u, '(A)') '--- OUTPUTS ---'
    WRITE (u, '(A)') 'FairTen1 AnchTen1'
    WRITE (u, '(A)') '--- end ---'
    CLOSE (u)
  END SUBROUTINE write_syrope_deck

  REAL(wp) FUNCTION column_min(path, first_col, last_col) RESULT(mn)
    !! Smallest value of the columns first_col..last_col (last_col 0: through the last column).
    CHARACTER(*), INTENT(IN) :: path
    INTEGER, INTENT(IN) :: first_col, last_col
    REAL(wp), ALLOCATABLE :: d(:, :)
    INTEGER :: nrow, lc
    mn = HUGE(1.0_wp)
    CALL read_out(path, d, nrow)
    IF (nrow < 1) RETURN
    lc = last_col
    IF (lc == 0) lc = SIZE(d, 1)
    mn = MINVAL(d(first_col:lc, 1:nrow))
  END FUNCTION column_min

  SUBROUTINE case_law_slack_runs()
    LOGICAL :: ok
    CHARACTER(64) :: opts(4)
    REAL(wp) :: fair, anch, seg_min
    ! the light cable as a lightly damped viscoelastic line, 3 m heave at dtM 0.1 s: anchor
    ! 8.2e4 to 9.5e4 N and fairlead 0.97e5 to 1.02e5 N at dtM 0.5 to 2.5 ms; without the cap
    ! on its law segments 1.45e5 N at the anchor, both taking every step as given. At 0.1 s the
    ! anchor snap is not resolved in time (the run notes it), so its peak depends on round-off:
    ! 8.5e4 N with gfortran on Windows, other values on other platforms. The run takes every
    ! step as given (off ei0_substeps), as the 1.45e5 N without the cap was measured, so the
    ! upper bound checks the cap against that figure; the lower bound only asks that the snap
    ! reaches the anchor. The sub-steps of the default are checked on this law by test_syrope.
    CALL write_motion('ei0slack_heave_ve.txt', 1, [5.0_wp, 0.0_wp, -14.0_wp], 3, 3.0_wp, 10.0_wp, 10.0_wp, &
                      0.1_wp, 40.0_wp)
    opts(1) = '0.1 dtM'
    opts(2) = '40.0 TMax'
    opts(3) = 'ei0slack_heave_ve.txt motionFile'
    opts(4) = 'off ei0_substeps'
    CALL write_deck('ei0slack_ve_light.dat', CABLE_VE, [205.0_wp, 0.0_wp, -80.0_wp], [5.0_wp, 0.0_wp, -14.0_wp], &
                    230.0_wp, 115, 80.0_wp, 't', opts)
    CALL run_driver_logged('ei0slack_ve_light.dat', 'ei0slack_ve_light', 'ei0slack_ve_light.log', ok)
    CALL require(ok, 've-slack:run')
    fair = column_max('ei0slack_ve_light.out', 2, 2)
    anch = column_max('ei0slack_ve_light.out', 3, 3)
    seg_min = column_min('ei0slack_ve_light.Line1.t.out', 2, 0)
    WRITE (*, '(A,ES10.3,A,ES10.3,A,ES10.3,A)') '  viscoelastic light cable, dtM 0.1 s: FairTen1 max ', fair, &
      ' N, AnchTen1 max ', anch, ' N, smallest segment tension ', seg_min, ' N'
    CALL require(seg_min <= 0.0_wp, 've-slack:goes-slack')
    CALL require(anch > 4.0e4_wp .AND. anch < 1.0e5_wp, 've-slack:anchor-peak')
    CALL require(fair > 8.0e4_wp .AND. fair < 1.2e5_wp, 've-slack:fairlead-peak')
    CALL require(.NOT. file_contains('ei0slack_ve_light.log', 'Warning: line'), 've-slack:no-spike-warning')
    ! a taut Syrope line in 4 m surge that goes slack, dtM 0.1 s: fairlead 1.78 MN at dtM 1 and
    ! 2.5 ms; 1.81 MN with the default sub-steps, 1.64 MN taking every step as given and
    ! 1.67 MN with the configuration blend (gfortran, Windows). The bounds catch a spike or a
    ! lost snap, not the round-off-dependent peak of the unresolved snap
    CALL write_syrope_files()
    CALL write_motion('ei0slack_surge_syr.txt', 1, [5.0_wp, 0.0_wp, -14.0_wp], 1, 4.0_wp, 10.0_wp, 10.0_wp, &
                      0.1_wp, 40.0_wp)
    CALL write_syrope_deck('ei0slack_syrope.dat', 0.1_wp, 40.0_wp)
    CALL run_driver_logged('ei0slack_syrope.dat', 'ei0slack_syrope', 'ei0slack_syrope.log', ok)
    CALL require(ok, 'syrope-slack:run')
    fair = column_max('ei0slack_syrope.out', 2, 2)
    seg_min = column_min('ei0slack_syrope.Line1.t.out', 2, 0)
    WRITE (*, '(A,ES10.3,A,ES10.3,A)') '  Syrope line, 4 m surge, dtM 0.1 s: FairTen1 max ', fair, &
      ' N, smallest segment tension ', seg_min, ' N'
    CALL require(seg_min <= 0.0_wp, 'syrope-slack:goes-slack')
    CALL require(fair > 1.4e6_wp .AND. fair < 2.3e6_wp, 'syrope-slack:fairlead-peak')
    CALL require(.NOT. file_contains('ei0slack_syrope.log', 'Warning: line'), 'syrope-slack:no-spike-warning')
  END SUBROUTINE case_law_slack_runs

END PROGRAM test_ei0_slack_dynamics
