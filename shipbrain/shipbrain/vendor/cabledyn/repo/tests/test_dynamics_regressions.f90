! File: tests/test_dynamics_regressions.f90
! SPDX-License-Identifier: Apache-2.0
! Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
PROGRAM test_dynamics_regressions
  !! Standalone-driver dynamics regressions:
  !!   1. Refreshing the held fluid field must not reset the generalized-alpha algorithmic
  !!      acceleration: a physically null current ("uniform 0 0 0") is bit-identical to no
  !!      current on the line-model and the Rigid6 point-system paths, and a grounded
  !!      polyester leg under surge and a chain under a steep wave plus current stay
  !!      physical (these blew up to 1e8-1e12 N while reporting convergence).
  !!   2. The per-step plausibility guard stops a run whose element strain exceeds
  !!      maxStrain with exit status SOLVEFAIL and a named message.
  !!   3. A viscoelastic line driven slack runs to completion at dt 0.05 and 0.01 with
  !!      matching statistics and no compressive tension.
  !!   4. JONSWAP seas: the same WaveSeed reproduces the sea, a different seed changes it,
  !!      the synthesis recovers Hs, keeps one jittered component per bin, and does not
  !!      repeat with the equally spaced comb period.
  !!   5. rampTime starts the waves from still water.
  USE CableDyn_Precision, ONLY: wp
  USE CableDyn_DeckDriver, ONLY: CD_Run_Deck_Driver, CD_DECKDRV_OK, CD_DECKDRV_SOLVEFAIL
  USE CableDyn_Hydro, ONLY: CD_JONSWAP_Random_Components, CD_Component_Wave_Kinematics, CD_HYDRO_OK
  IMPLICIT NONE

  REAL(wp), PARAMETER :: PI = 3.141592653589793238462643383279502884197_wp
  INTEGER :: nfail

  nfail = 0
  CALL case_null_current_identity_models()
  CALL case_null_current_identity_rigid6()
  CALL case_chain_wave_current_stable()
  CALL case_plausibility_guard()
  CALL case_viscoelastic_slack_dt()
  CALL case_jonswap_synthesis()
  CALL case_jonswap_seed_decks()
  CALL case_wave_ramp()

  IF (nfail > 0) THEN
    WRITE (*, '(A,I0,A)') 'FAIL: ', nfail, ' assertion(s) failed'
    ERROR STOP 1
  END IF
  WRITE (*, '(A)') 'PASS: dynamics regressions (fluid refresh, plausibility guard, slack rope, seas, ramp)'

CONTAINS

  INCLUDE 'nan_max_abs.inc'

  SUBROUTINE require(cond, label)
    LOGICAL, INTENT(IN) :: cond
    CHARACTER(*), INTENT(IN) :: label
    IF (.NOT. cond) THEN
      WRITE (*, '(A)') 'MISMATCH ['//label//']'
      nfail = nfail + 1
    END IF
  END SUBROUTINE require

  ! ------------------------------------------------------------------ decks and motion

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

  SUBROUTINE write_single_line_deck(path, linetype, anchor, fairlead, length, nseg, depth, kbot, options)
    !! One line from a Coupled fairlead (point 2) to a Fixed anchor (point 1).
    CHARACTER(*), INTENT(IN) :: path, linetype, options(:)
    REAL(wp), INTENT(IN) :: anchor(3), fairlead(3), length, depth, kbot
    INTEGER, INTENT(IN) :: nseg
    INTEGER :: u, i
    CHARACTER(32) :: name
    OPEN (NEWUNIT=u, FILE=path, STATUS='REPLACE', ACTION='WRITE')
    WRITE (u, '(A)') 'dynamics regression deck'
    WRITE (u, '(A)') '--- LINE TYPES ---'
    WRITE (u, '(A)') 'Name Diam Mass EA BA EI Cdn Cdt Can Cat'
    WRITE (u, '(A)') '(-) (m) (kg/m) (N) (-) (Nm2) (-) (-) (-) (-)'
    WRITE (u, '(A)') TRIM(linetype)
    READ (linetype, *) name
    WRITE (u, '(A)') '--- POINTS ---'
    WRITE (u, '(A)') 'ID Type X Y Z Mass Vol CdA Ca'
    WRITE (u, '(A)') '(-) (-) (m) (m) (m) (kg) (m^3) (m^2) (-)'
    WRITE (u, '(A,3(1X,ES16.9),A)') '1 Fixed', anchor, ' 0 0 0 0'
    WRITE (u, '(A,3(1X,ES16.9),A)') '2 Coupled', fairlead, ' 0 0 0 0'
    WRITE (u, '(A)') '--- LINES ---'
    WRITE (u, '(A)') 'ID NodeA NodeB Outputs'
    WRITE (u, '(A)') '(-) (-) (-) (-)'
    WRITE (u, '(A)') '1 2 1 -'
    WRITE (u, '(A)') '--- SECTIONS ---'
    WRITE (u, '(A)') 'LineID LineType Length NumSegs'
    WRITE (u, '(A)') '(-) (-) (m) (-)'
    WRITE (u, '(A,A,1X,ES16.9,1X,I0)') '1 ', TRIM(name), length, nseg
    WRITE (u, '(A)') '--- OPTIONS ---'
    WRITE (u, '(A)') '9.80665 g'
    WRITE (u, '(A)') '1025.0 rhoW'
    WRITE (u, '(ES16.9,A)') depth, ' WtrDpth'
    WRITE (u, '(ES16.9,A)') kbot, ' kBot'
    WRITE (u, '(A)') '1.0e4 cBot'
    DO i = 1, SIZE(options)
      IF (LEN_TRIM(options(i)) > 0) WRITE (u, '(A)') TRIM(options(i))
    END DO
    WRITE (u, '(A)') '--- OUTPUTS ---'
    WRITE (u, '(A)') 'FairTen1 AnchTen1'
    WRITE (u, '(A)') '--- end ---'
    CLOSE (u)
  END SUBROUTINE write_single_line_deck

  SUBROUTINE write_poly_deck(path, motion, extra)
    !! A polyester leg (690 m, 50 segments, 200 m water, stiff kBot) under surge.
    CHARACTER(*), INTENT(IN) :: path, motion, extra
    CHARACTER(64) :: opts(5)
    opts(1) = '0.05 dtM'
    opts(2) = '12.0 TMax'
    opts(3) = TRIM(motion)//' motionFile'
    opts(4) = extra
    opts(5) = ''
    CALL write_single_line_deck(path, 'polyester 0.1438 22.42 1.42e8 -1.0 0.0 1.2 0.2 1.0 0.0', &
                                [700.0_wp, 0.0_wp, -200.0_wp], [58.0_wp, 0.0_wp, -14.0_wp], 690.0_wp, 50, &
                                200.0_wp, 3.0e6_wp, opts)
  END SUBROUTINE write_poly_deck

  SUBROUTINE write_chain_deck(path, dt, tmax, extra1, extra2)
    !! The WD0050 grounded chain (410 m, 41 segments) held at the fairlead.
    CHARACTER(*), INTENT(IN) :: path, extra1, extra2
    REAL(wp), INTENT(IN) :: dt, tmax
    CHARACTER(64) :: opts(4)
    WRITE (opts(1), '(ES14.7,A)') dt, ' dtM'
    WRITE (opts(2), '(ES14.7,A)') tmax, ' TMax'
    opts(3) = extra1
    opts(4) = extra2
    CALL write_single_line_deck(path, 'chain 0.252 390.0 1.674e9 -1.0 0.0 1.37 0.64 1.0 0.0', &
                                [400.0_wp, 0.0_wp, -50.0_wp], [0.0_wp, 0.0_wp, -5.0_wp], 410.0_wp, 41, &
                                50.0_wp, 1.0e5_wp, opts)
  END SUBROUTINE write_chain_deck

  SUBROUTINE write_rigid6_deck(path, current)
    !! Submerged Rigid6 buoy on three taut polyester legs (examples/rigid6_buoy.dat, 3 s).
    CHARACTER(*), INTENT(IN) :: path, current
    INTEGER :: u
    OPEN (NEWUNIT=u, FILE=path, STATUS='REPLACE', ACTION='WRITE')
    WRITE (u, '(A)') 'Rigid6 buoy null-current regression'
    WRITE (u, '(A)') '--- LINE TYPES ---'
    WRITE (u, '(A)') 'Name Diam Mass EA BA EI Cdn Cdt Can Cat'
    WRITE (u, '(A)') '(-) (m) (kg/m) (N) (-) (Nm2) (-) (-) (-) (-)'
    WRITE (u, '(A)') 'poly 0.12 15.0 5.0e7 -1.0 0.0 1.2 0.2 1.0 0.0'
    WRITE (u, '(A)') '--- BODIES ---'
    WRITE (u, '(A)') 'ID Type X Y Z Roll Pitch Yaw Mass Vol C33 C44 C55 CdA Ca Ixx Iyy Izz'
    WRITE (u, '(A)') '(-) (-) (m) (m) (m) (deg) (deg) (deg) (kg) (m3) (N/m) (Nm/rad) (Nm/rad) (m2) (-) '// &
      '(kgm2) (kgm2) (kgm2)'
    WRITE (u, '(A)') '1 Rigid6 0.0 0.0 -20.0 0.0 0.0 0.0 2.0e4 40.0 0.0 0.0 0.0 8.0 0.5 3.5e4 3.5e4 3.5e4'
    WRITE (u, '(A)') '--- POINTS ---'
    WRITE (u, '(A)') 'ID Type X Y Z Mass Vol CdA Ca'
    WRITE (u, '(A)') '(-) (-) (m) (m) (m) (kg) (m^3) (m^2) (-)'
    WRITE (u, '(A)') '1 Body1 1.5 0.0 -2.0 0 0 0 0'
    WRITE (u, '(A)') '2 Body1 -0.75 1.299 -2.0 0 0 0 0'
    WRITE (u, '(A)') '3 Body1 -0.75 -1.299 -2.0 0 0 0 0'
    WRITE (u, '(A)') '4 Fixed 40.0 0.0 -100.0 0 0 0 0'
    WRITE (u, '(A)') '5 Fixed -20.0 34.641 -100.0 0 0 0 0'
    WRITE (u, '(A)') '6 Fixed -20.0 -34.641 -100.0 0 0 0 0'
    WRITE (u, '(A)') '--- LINES ---'
    WRITE (u, '(A)') 'ID NodeA NodeB Outputs'
    WRITE (u, '(A)') '(-) (-) (-) (-)'
    WRITE (u, '(A)') '1 1 4 -'
    WRITE (u, '(A)') '2 2 5 -'
    WRITE (u, '(A)') '3 3 6 -'
    WRITE (u, '(A)') '--- SECTIONS ---'
    WRITE (u, '(A)') 'LineID LineType Length NumSegs'
    WRITE (u, '(A)') '(-) (-) (m) (-)'
    WRITE (u, '(A)') '1 poly 86.85 20'
    WRITE (u, '(A)') '2 poly 86.85 20'
    WRITE (u, '(A)') '3 poly 86.85 20'
    WRITE (u, '(A)') '--- OPTIONS ---'
    WRITE (u, '(A)') '9.80665 g'
    WRITE (u, '(A)') '1025.0 rhoW'
    WRITE (u, '(A)') '100.0 WtrDpth'
    WRITE (u, '(A)') '0.01 dtM'
    WRITE (u, '(A)') '3.0 TMax'
    WRITE (u, '(A)') TRIM(current)//' current'
    WRITE (u, '(A)') '--- OUTPUTS ---'
    WRITE (u, '(A)') 'FairTen1 FairTen2 AnchTen1 Point1px Point1py Point1pz'
    WRITE (u, '(A)') '--- end ---'
    CLOSE (u)
  END SUBROUTINE write_rigid6_deck

  SUBROUTINE write_ve_deck(path, dt, motion)
    !! The shipped viscoelastic polyester type (Es|Ed, Bs|Bd) on the same polyester leg.
    CHARACTER(*), INTENT(IN) :: path, motion
    REAL(wp), INTENT(IN) :: dt
    CHARACTER(64) :: opts(3)
    WRITE (opts(1), '(ES14.7,A)') dt, ' dtM'
    opts(2) = '30.0 TMax'
    opts(3) = TRIM(motion)//' motionFile'
    CALL write_single_line_deck(path, 'poly_ve 0.1438 22.42 1.424e8|2.50e8 4.0e9|1.1e7 0.0 1.2 0.2 1.0 0.0', &
                                [700.0_wp, 0.0_wp, -200.0_wp], [58.0_wp, 0.0_wp, -14.0_wp], 690.0_wp, 50, &
                                200.0_wp, 3.0e6_wp, opts)
  END SUBROUTINE write_ve_deck

  ! ------------------------------------------------------------------ output helpers

  SUBROUTINE read_out(path, data, nrow)
    !! Numeric rows of a driver .out file (comment and header lines skipped).
    CHARACTER(*), INTENT(IN) :: path
    REAL(wp), ALLOCATABLE, INTENT(OUT) :: data(:, :)
    INTEGER, INTENT(OUT) :: nrow
    INTEGER :: u, ios, ncol, k
    CHARACTER(4096) :: line
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

  LOGICAL FUNCTION files_identical(path_a, path_b) RESULT(same)
    !! Line-by-line textual identity of two output files (bit-identical printed state).
    CHARACTER(*), INTENT(IN) :: path_a, path_b
    INTEGER :: ua, ub, ia, ib
    CHARACTER(4096) :: la, lb
    same = .FALSE.
    OPEN (NEWUNIT=ua, FILE=path_a, STATUS='OLD', ACTION='READ', IOSTAT=ia)
    IF (ia /= 0) RETURN
    OPEN (NEWUNIT=ub, FILE=path_b, STATUS='OLD', ACTION='READ', IOSTAT=ib)
    IF (ib /= 0) THEN
      CLOSE (ua)
      RETURN
    END IF
    DO
      READ (ua, '(A)', IOSTAT=ia) la
      READ (ub, '(A)', IOSTAT=ib) lb
      IF (ia /= 0 .OR. ib /= 0) EXIT
      IF (la /= lb) THEN
        CLOSE (ua)
        CLOSE (ub)
        RETURN
      END IF
    END DO
    same = (ia /= 0 .AND. ib /= 0)
    CLOSE (ua)
    CLOSE (ub)
  END FUNCTION files_identical

  ! ------------------------------------------------------------------ cases

  SUBROUTINE case_null_current_identity_models()
    LOGICAL :: conv
    INTEGER :: es, nrow
    CHARACTER(512) :: em
    REAL(wp), ALLOCATABLE :: d(:, :)
    CALL write_motion('dynreg_poly_motion.txt', 2, [58.0_wp, 0.0_wp, -14.0_wp], 1, 8.0_wp, 12.0_wp, 12.0_wp, &
                      0.05_wp, 12.0_wp)
    CALL write_poly_deck('dynreg_poly_none.dat', 'dynreg_poly_motion.txt', 'none current')
    CALL write_poly_deck('dynreg_poly_zero.dat', 'dynreg_poly_motion.txt', 'uniform 0 0 0 current')
    CALL CD_Run_Deck_Driver('dynreg_poly_none.dat', 'dynreg_poly_none', conv, es, em)
    CALL require(es == CD_DECKDRV_OK .AND. conv, 'null-current:none-runs: '//TRIM(em))
    CALL CD_Run_Deck_Driver('dynreg_poly_zero.dat', 'dynreg_poly_zero', conv, es, em)
    CALL require(es == CD_DECKDRV_OK .AND. conv, 'null-current:zero-runs: '//TRIM(em))
    CALL require(files_identical('dynreg_poly_none.out', 'dynreg_poly_zero.out'), &
                 'null-current:models-bit-identical')
    CALL read_out('dynreg_poly_zero.out', d, nrow)
    CALL require(nrow == 241, 'null-current:rows')
    IF (nrow > 0) CALL require(MAXVAL(d(2:3, 1:nrow)) < 1.0e6_wp .AND. MINVAL(d(2:3, 1:nrow)) >= 0.0_wp, &
                               'null-current:grounded-poly-surge-physical')
  END SUBROUTINE case_null_current_identity_models

  SUBROUTINE case_null_current_identity_rigid6()
    LOGICAL :: conv
    INTEGER :: es
    CHARACTER(512) :: em
    CALL write_rigid6_deck('dynreg_r6_none.dat', 'none')
    CALL write_rigid6_deck('dynreg_r6_zero.dat', 'uniform 0.0 0.0 0.0')
    CALL CD_Run_Deck_Driver('dynreg_r6_none.dat', 'dynreg_r6_none', conv, es, em)
    CALL require(es == CD_DECKDRV_OK .AND. conv, 'null-current:r6-none-runs: '//TRIM(em))
    CALL CD_Run_Deck_Driver('dynreg_r6_zero.dat', 'dynreg_r6_zero', conv, es, em)
    CALL require(es == CD_DECKDRV_OK .AND. conv, 'null-current:r6-zero-runs: '//TRIM(em))
    CALL require(files_identical('dynreg_r6_none.out', 'dynreg_r6_zero.out'), 'null-current:rigid6-bit-identical')
  END SUBROUTINE case_null_current_identity_rigid6

  SUBROUTINE case_chain_wave_current_stable()
    !! Grounded chain under a steep 22.6 m / 20 s Airy wave plus a 1 m/s current at dt 0.05
    !! (a case that previously diverged): the held-fairlead tension stays near its ~1 MN static
    !! level.
    LOGICAL :: conv
    INTEGER :: es, nrow
    CHARACTER(512) :: em
    REAL(wp), ALLOCATABLE :: d(:, :)
    CALL write_chain_deck('dynreg_chain_wave.dat', 0.05_wp, 8.0_wp, 'airy 22.58 20 0 waves', &
                          'uniform 1.0 0 0 current')
    CALL CD_Run_Deck_Driver('dynreg_chain_wave.dat', 'dynreg_chain_wave', conv, es, em)
    CALL require(es == CD_DECKDRV_OK .AND. conv, 'chain-wave:runs: '//TRIM(em))
    CALL read_out('dynreg_chain_wave.out', d, nrow)
    CALL require(nrow == 161, 'chain-wave:rows')
    IF (nrow > 0) CALL require(MAXVAL(d(2:3, 1:nrow)) < 3.0e6_wp, 'chain-wave:tension-physical')
  END SUBROUTINE case_chain_wave_current_stable

  SUBROUTINE case_plausibility_guard()
    !! A strain bound below the run's real strain must stop it: exit status SOLVEFAIL,
    !! not converged, message naming the guard, line, and quantity.
    LOGICAL :: conv
    INTEGER :: es
    CHARACTER(512) :: em
    CALL write_poly_deck('dynreg_guard.dat', 'dynreg_poly_motion.txt', '1.0e-6 maxStrain')
    CALL CD_Run_Deck_Driver('dynreg_guard.dat', 'dynreg_guard', conv, es, em)
    CALL require(es == CD_DECKDRV_SOLVEFAIL .AND. .NOT. conv, 'guard:fires')
    CALL require(INDEX(em, 'plausibility guard') > 0 .AND. INDEX(em, 'line 1') > 0 .AND. &
                 INDEX(em, 'maxStrain') > 0, 'guard:message: '//TRIM(em))
    CALL write_poly_deck('dynreg_guard_off.dat', 'dynreg_poly_motion.txt', '0 maxStrain')
    CALL CD_Run_Deck_Driver('dynreg_guard_off.dat', 'dynreg_guard_off', conv, es, em)
    CALL require(es == CD_DECKDRV_OK .AND. conv, 'guard:zero-disables: '//TRIM(em))
  END SUBROUTINE case_plausibility_guard

  SUBROUTINE case_viscoelastic_slack_dt()
    !! 4 m / 12 s heave drives segments of the Es|Ed, Bs|Bd polyester
    !! slack. Both steps must complete, the tension never goes compressive, and the
    !! statistics agree across a five-fold step change.
    LOGICAL :: conv
    INTEGER :: es, n1, n2, k
    CHARACTER(512) :: em
    REAL(wp), ALLOCATABLE :: d1(:, :), d2(:, :)
    REAL(wp) :: mean1, mean2
    ! slack line: FairTen (the line-end force) falls to the end node's lumped submerged weight
    ! w*l0/2 of the 690 m / 50-segment poly_ve leg (1 % margin)
    REAL(wp), PARAMETER :: slack_end_force = 1.01_wp*0.5_wp*(22.42_wp - 1025.0_wp*0.25_wp*3.141592653589793_wp* &
                                                             0.1438_wp**2)*9.80665_wp*690.0_wp/50.0_wp
    CALL write_motion('dynreg_ve_m005.txt', 2, [58.0_wp, 0.0_wp, -14.0_wp], 3, 4.0_wp, 12.0_wp, 12.0_wp, &
                      0.05_wp, 30.0_wp)
    CALL write_motion('dynreg_ve_m001.txt', 2, [58.0_wp, 0.0_wp, -14.0_wp], 3, 4.0_wp, 12.0_wp, 12.0_wp, &
                      0.01_wp, 30.0_wp)
    CALL write_ve_deck('dynreg_ve_005.dat', 0.05_wp, 'dynreg_ve_m005.txt')
    CALL write_ve_deck('dynreg_ve_001.dat', 0.01_wp, 'dynreg_ve_m001.txt')
    CALL CD_Run_Deck_Driver('dynreg_ve_005.dat', 'dynreg_ve_005', conv, es, em)
    CALL require(es == CD_DECKDRV_OK .AND. conv, 've-slack:dt0.05-completes: '//TRIM(em))
    CALL CD_Run_Deck_Driver('dynreg_ve_001.dat', 'dynreg_ve_001', conv, es, em)
    CALL require(es == CD_DECKDRV_OK .AND. conv, 've-slack:dt0.01-completes: '//TRIM(em))
    CALL read_out('dynreg_ve_005.out', d1, n1)
    CALL read_out('dynreg_ve_001.out', d2, n2)
    CALL require(n1 == 601 .AND. n2 == 3001, 've-slack:rows')
    IF (n1 /= 601 .OR. n2 /= 3001) RETURN
    ! (only the n1/n2 rows read are defined; read_out's storage grows by doubling)
    CALL require(MINVAL(d1(2, 1:n1)) >= 0.0_wp .AND. MINVAL(d2(2, 1:n2)) >= 0.0_wp, 've-slack:tension-only')
    CALL require(MINVAL(d2(2, 1:n2)) <= slack_end_force, 've-slack:case-reaches-slack')
    CALL require(ABS(MAXVAL(d1(2, 1:n1)) - MAXVAL(d2(2, 1:n2))) < 0.02_wp*MAXVAL(d2(2, 1:n2)), &
                 've-slack:max-agrees')
    mean1 = SUM(d1(2, 241:601))/361.0_wp
    mean2 = 0.0_wp
    DO k = 1201, 3001, 5
      mean2 = mean2 + d2(2, k)
    END DO
    mean2 = mean2/361.0_wp
    CALL require(ABS(mean1 - mean2) < 0.02_wp*mean2, 've-slack:mean-agrees')
  END SUBROUTINE case_viscoelastic_slack_dt

  SUBROUTINE case_jonswap_synthesis()
    INTEGER, PARAMETER :: NC = 200
    REAL(wp) :: om(NC), kk(NC), amp(NC), ph(NC), om2(NC), kk2(NC), amp2(NC), ph2(NC)
    REAL(wp) :: omega_p, domega, lo, eta0, eta1, vel(3), acc(3), m0, dmax
    INTEGER :: es, i
    CHARACTER(200) :: em
    CALL CD_JONSWAP_Random_Components(6.0_wp, 12.0_wp, 3.3_wp, 200.0_wp, 9.80665_wp, 7, om, kk, amp, ph, es, em)
    CALL require(es == CD_HYDRO_OK, 'jonswap:synthesis-ok: '//TRIM(em))
    m0 = 0.5_wp*SUM(amp**2)
    CALL require(ABS(4.0_wp*SQRT(m0) - 6.0_wp) < 1.0e-12_wp, 'jonswap:hs-recovered')
    omega_p = 2.0_wp*PI/12.0_wp
    domega = 4.8_wp*omega_p/REAL(NC, wp)
    dmax = 0.0_wp
    DO i = 1, NC
      lo = 0.2_wp*omega_p + REAL(i - 1, wp)*domega
      CALL require(om(i) > lo .AND. om(i) < lo + domega, 'jonswap:one-component-per-bin')
      CALL require(ph(i) >= 0.0_wp .AND. ph(i) < 2.0_wp*PI, 'jonswap:phase-range')
    END DO
    DO i = 2, NC
      dmax = MAX(dmax, ABS((om(i) - om(i - 1)) - domega))
    END DO
    CALL require(dmax > 0.1_wp*domega, 'jonswap:frequencies-not-equally-spaced')
    CALL CD_JONSWAP_Random_Components(6.0_wp, 12.0_wp, 3.3_wp, 200.0_wp, 9.80665_wp, 7, om2, kk2, amp2, ph2, &
                                      es, em)
    CALL require(ALL(ABS(om2 - om) <= 0.0_wp) .AND. ALL(ABS(ph2 - ph) <= 0.0_wp), 'jonswap:same-seed-same-sea')
    CALL CD_JONSWAP_Random_Components(6.0_wp, 12.0_wp, 3.3_wp, 200.0_wp, 9.80665_wp, 8, om2, kk2, amp2, ph2, &
                                      es, em)
    CALL require(nan_max_abs(ph2 - ph) > 1.0_wp, 'jonswap:other-seed-other-sea')
    CALL CD_JONSWAP_Random_Components(6.0_wp, 12.0_wp, 3.3_wp, 200.0_wp, 9.80665_wp, 0, om2, kk2, amp2, ph2, &
                                      es, em)
    CALL require(es /= CD_HYDRO_OK, 'jonswap:seed-zero-rejected')
    ! no repetition with the period of an equally spaced comb of the same bin width
    CALL CD_Component_Wave_Kinematics(0.0_wp, 0.0_wp, 0.0_wp, 100.0_wp, 200.0_wp, 0.0_wp, .FALSE., om, kk, amp, ph, &
                                      eta0, vel, acc, es, em)
    CALL CD_Component_Wave_Kinematics(0.0_wp, 0.0_wp, 0.0_wp, 100.0_wp + 2.0_wp*PI/domega, 200.0_wp, 0.0_wp, &
                                      .FALSE., om, kk, amp, ph, eta1, vel, acc, es, em)
    CALL require(ABS(eta1 - eta0) > 0.05_wp*6.0_wp, 'jonswap:no-comb-period-repeat')
  END SUBROUTINE case_jonswap_synthesis

  SUBROUTINE case_jonswap_seed_decks()
    LOGICAL :: conv
    INTEGER :: es
    CHARACTER(512) :: em
    CALL write_chain_deck('dynreg_js_a.dat', 0.05_wp, 6.0_wp, 'jonswap 4.0 8.0 3.3 0.0 waves', '')
    CALL write_chain_deck('dynreg_js_b.dat', 0.05_wp, 6.0_wp, 'jonswap 4.0 8.0 3.3 0.0 waves', '1 WaveSeed')
    CALL write_chain_deck('dynreg_js_c.dat', 0.05_wp, 6.0_wp, 'jonswap 4.0 8.0 3.3 0.0 waves', '2 WaveSeed')
    CALL CD_Run_Deck_Driver('dynreg_js_a.dat', 'dynreg_js_a', conv, es, em)
    CALL require(es == CD_DECKDRV_OK .AND. conv, 'wave-seed:default-runs: '//TRIM(em))
    CALL CD_Run_Deck_Driver('dynreg_js_b.dat', 'dynreg_js_b', conv, es, em)
    CALL require(es == CD_DECKDRV_OK .AND. conv, 'wave-seed:seed1-runs: '//TRIM(em))
    CALL CD_Run_Deck_Driver('dynreg_js_c.dat', 'dynreg_js_c', conv, es, em)
    CALL require(es == CD_DECKDRV_OK .AND. conv, 'wave-seed:seed2-runs: '//TRIM(em))
    CALL require(files_identical('dynreg_js_a.out', 'dynreg_js_b.out'), 'wave-seed:default-is-seed-1')
    CALL require(.NOT. files_identical('dynreg_js_a.out', 'dynreg_js_c.out'), 'wave-seed:seed-2-differs')
    CALL write_chain_deck('dynreg_js_bad.dat', 0.05_wp, 6.0_wp, 'jonswap 4.0 8.0 3.3 0.0 waves', '0 WaveSeed')
    CALL CD_Run_Deck_Driver('dynreg_js_bad.dat', 'dynreg_js_bad', conv, es, em)
    CALL require(es /= CD_DECKDRV_OK, 'wave-seed:zero-rejected')
  END SUBROUTINE case_jonswap_seed_decks

  SUBROUTINE case_wave_ramp()
    !! With rampTime the first steps see (nearly) still water, so the held-fairlead tension
    !! departs from its static value far less than with the full wave switched on at t = 0;
    !! the t = 0 row is the still-water row in both cases.
    LOGICAL :: conv
    INTEGER :: es, na, nb, nc
    CHARACTER(512) :: em
    REAL(wp), ALLOCATABLE :: da(:, :), db(:, :), dc(:, :)
    REAL(wp) :: dev_ramp, dev_full
    CALL write_chain_deck('dynreg_ramp_off.dat', 0.05_wp, 2.0_wp, 'airy 6.0 8.0 0.0 waves', '')
    CALL write_chain_deck('dynreg_ramp_on.dat', 0.05_wp, 2.0_wp, 'airy 6.0 8.0 0.0 waves', '16.0 rampTime')
    CALL write_chain_deck('dynreg_ramp_calm.dat', 0.05_wp, 2.0_wp, 'none waves', '')
    CALL CD_Run_Deck_Driver('dynreg_ramp_off.dat', 'dynreg_ramp_off', conv, es, em)
    CALL require(es == CD_DECKDRV_OK .AND. conv, 'ramp:off-runs: '//TRIM(em))
    CALL CD_Run_Deck_Driver('dynreg_ramp_on.dat', 'dynreg_ramp_on', conv, es, em)
    CALL require(es == CD_DECKDRV_OK .AND. conv, 'ramp:on-runs: '//TRIM(em))
    CALL CD_Run_Deck_Driver('dynreg_ramp_calm.dat', 'dynreg_ramp_calm', conv, es, em)
    CALL require(es == CD_DECKDRV_OK .AND. conv, 'ramp:calm-runs: '//TRIM(em))
    CALL read_out('dynreg_ramp_off.out', da, na)
    CALL read_out('dynreg_ramp_on.out', db, nb)
    CALL read_out('dynreg_ramp_calm.out', dc, nc)
    CALL require(na == 41 .AND. nb == 41 .AND. nc == 41, 'ramp:rows')
    IF (na /= 41 .OR. nb /= 41 .OR. nc /= 41) RETURN
    CALL require(ABS(db(2, 1) - dc(2, 1)) <= 1.0e-9_wp*ABS(dc(2, 1)), 'ramp:t0-is-still-water')
    dev_full = nan_max_abs(da(2, 1:41) - dc(2, 1:41))
    dev_ramp = nan_max_abs(db(2, 1:41) - dc(2, 1:41))
    CALL require(dev_full > 0.0_wp .AND. dev_ramp < 0.1_wp*dev_full, 'ramp:starts-from-still-water')
  END SUBROUTINE case_wave_ramp

END PROGRAM test_dynamics_regressions
