! File: tests/test_two_moving_ends.f90
! SPDX-License-Identifier: Apache-2.0
! Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
PROGRAM test_two_moving_ends
  !! Gates of a finite-EI (cubic-Hermite) line with two moving ends: End B a second host-driven end
  !! of the cable (CD_HFMF_Set_Moving_End_B), a line between two moving points. Before this route the
  !! decks below were refused (End B had to be Fixed, except a Turbine<J> shared line, which ran on
  !! a separate compatibility solver) and the boundary had no End B input.
  !!   Z  zero motion: a line between a driven Coupled End A and a Coupled End B whose motionFile rows
  !!      hold it at its deck position writes the .out, line, element and static files of the same
  !!      line with a Fixed End B byte for byte; so does the pair without a motionFile (both held),
  !!      and the modal analysis (OPTION nModes: the modes hold both ends) writes the same modes file;
  !!      also with the chord at a 37 deg heading (the cable solves in a frame turned about +z, so a
  !!      held End B read back in global axes is the rotated committed position);
  !!   S  symmetry: a symmetric suspended cable whose two ends move mirror-symmetrically (apart and up)
  !!      stays mirror symmetric -- node positions and the two end loads -- to round-off at every step;
  !!   G  rigid translation (Galilean invariance, no fluid drag): both ends translating at one constant
  !!      velocity v, the line started with that velocity, reproduce the held line shifted by v t:
  !!      positions and both end loads to round-off, so the tension does not change.
  !!      Round-off of the end loads: the axial force carries EA times the round-off of the element
  !!      strain, about EA eps L/h = 1e-5 N on this 8e8 N line (1e-9 of its tension), hence the 1e-8
  !!      relative bound of S and G;
  !!   R  reversal: a line driven at its End B equals the same line written in reverse and driven at
  !!      its End A (the established End A boundary): the end tensions agree to the solver tolerances;
  !!   C  restart: with both ends moving, a run restored from a snapshot, and a cable rebuilt from the
  !!      deck and reloaded from the checkpoint mirror, continue bit-identically;
  !! END CONNECTIONS and torsion at a moving End B (its connection direction and torsion frame are
  !! held by End B's own parent and turn with it):
  !!   ZT zero motion: a straight line clamped and twisted 90 deg between a surging, rolling End A and a
  !!      held Coupled End B writes the files of the same line with a Fixed End B byte for byte;
  !!   TS both end frames rolled by the same angle about the line (a vessel rolling about the axis of a
  !!      twisted line between two of its points): the torque does not change;
  !!   TO opposite rolls of the two end frames (the motionFile roll column of both ends, each about its
  !!      inward tangent; and two parent orientations rolled by +phi and -phi): the torque changes by
  !!      GJ (2 phi) / L;
  !!   B  bending reversal: a line with elastic or clamped connections, driven at End B by a parent that
  !!      translates and turns, equals the same line written in reverse and driven at its End A by the
  !!      same parent motion (the established End A boundary): end forces and connection moments;
  !!   CT restart with torsion, the nodal twist and both end frames turning: snapshot and mirror
  !!      rebuild continue bit-identically;
  !! the coupled aggregate (OpenFAST, FAST.Farm, the C API), one moving column per end:
  !!   F  FAST.Farm: a line shared by two turbines takes its End A from turbine 1's column and its End B
  !!      from turbine 2's (the turbine map), and, driven by prescribed turbine motions, reports the
  !!      end tensions of the standalone TURBINES deck run with the same motions (solver tolerances);
  !!   FT the torsional line between two host-driven columns, each turned by its own host orientation:
  !!      equal rolls keep the torque, opposite rolls change it by GJ (2 phi) / L;
  !!   FP a standalone TURBINES deck whose turbines start yawed (PtfmInit) reads each end's Ez and Nx
  !!      in its turbine's axes, as FAST.Farm does: the clamped, twisted line between the two turbines
  !!      reports the FAST.Farm aggregate's tensions, torque and end curvature (solver tolerances);
  !!   FR the same line with the turbines rolling (motionFile TURBINES rows with their quaternions):
  !!      both end frames turn with their turbines, standalone as in the FAST.Farm aggregate.
  USE CableDyn_Precision, ONLY: wp
  USE CableDyn_DeckDriver, ONLY: CD_Run_Deck_Driver, CD_Init_Deck_HermiteCable, CD_DECKDRV_OK
  USE CableDyn_OpenFAST_Aggregate, ONLY: CD_AGG_ModuleType, CD_AGG_Init_From_Deck, CD_AGG_Step_Moving, &
                                         CD_AGG_NMovingPoints, CD_AGG_TurbineOfMoving, CD_AGG_NumChannels, &
                                         CD_AGG_EvalChannel, CD_AGG_GetMovingPointMesh, CD_AGG_End, CD_AGG_OK
  USE CableDyn_OpenFAST_HermiteFMF, ONLY: CD_HFMF_ModuleType, CD_HFMF_UpdateStates, CD_HFMF_CalcOutput, &
                                          CD_HFMF_GetNodePositions, CD_HFMF_GetCoupledKinematics, &
                                          CD_HFMF_GetEndBKinematics, CD_HFMF_Snapshot, CD_HFMF_Restore, &
                                          CD_HFMF_MirrorSize, CD_HFMF_PackMirror, CD_HFMF_UnpackMirror, &
                                          CD_HFMF_End, CD_HFMF_OK
  USE, INTRINSIC :: IEEE_ARITHMETIC, ONLY: IEEE_IS_FINITE
  IMPLICIT NONE

  REAL(wp), PARAMETER :: PI = 3.14159265358979323846_wp
  REAL(wp), PARAMETER :: DT = 0.05_wp, SPAN = 80.0_wp, ZE = -20.0_wp
  INTEGER :: nfail = 0

  CALL check_zero_motion()
  CALL check_symmetry()
  CALL check_rigid_translation()
  CALL check_reversal()
  CALL check_restart()
  CALL check_zero_motion_torsion()
  CALL check_same_roll()
  CALL check_opposite_roll()
  CALL check_bending_reversal('finite')
  CALL check_bending_reversal('clamped')
  CALL check_torsion_restart()
  CALL check_farm_shared_line()
  CALL check_aggregate_torsion()
  CALL check_farm_ptfm_parity()
  CALL check_farm_rotation_parity()

  IF (nfail > 0) THEN
    WRITE (*, '(A,I0,A)') 'FAIL: ', nfail, ' assertion(s) failed'
    ERROR STOP 1
  END IF
  WRITE (*, '(A)') 'PASS: two moving ends gates'

CONTAINS

  INCLUDE 'nan_max_abs.inc'

  SUBROUTINE require(cond, label)
    LOGICAL, INTENT(IN) :: cond
    CHARACTER(*), INTENT(IN) :: label
    IF (cond) RETURN
    nfail = nfail + 1
    WRITE (*, '(A)') 'FAIL: '//TRIM(label)
  END SUBROUTINE require

  SUBROUTINE write_deck(path, type_b, motion, tmax, cd, pa, pb, flags, extra)
    !! A 100 m finite-EI line between POINT 1 (End A, Coupled) at pa and POINT 2 (End B, type_b) at
    !! pb, 40 elements, no seabed; cd the normal and tangential drag coefficient; motion a motionFile
    !! path or blank; flags the LINES Outputs flags; extra an OPTIONS row.
    CHARACTER(*), INTENT(IN) :: path, type_b, motion, flags
    REAL(wp), INTENT(IN) :: tmax, cd, pa(3), pb(3)
    CHARACTER(*), INTENT(IN), OPTIONAL :: extra
    INTEGER :: u
    OPEN (NEWUNIT=u, FILE=path, STATUS='REPLACE', ACTION='WRITE')
    WRITE (u, '(A)') 'two moving ends gate'
    WRITE (u, '(A)') '--- LINE TYPES ---'
    WRITE (u, '(A)') 'Name Diam Mass EA BA EI Cdn Cdt Can Cat'
    WRITE (u, '(A)') '(-) (m) (kg/m) (N) (-) (Nm2) (-) (-) (-) (-)'
    WRITE (u, '(A,F4.2,A,F4.2,A)') 'pcable 0.20 60 8.0e8 0.0 2.0e4 ', cd, ' ', cd, ' 1.0 0.0'
    WRITE (u, '(A)') '--- POINTS ---'
    WRITE (u, '(A)') 'ID Type X Y Z Mass Vol CdA Ca'
    WRITE (u, '(A)') '(-) (-) (m) (m) (m) (kg) (m3) (m2) (-)'
    WRITE (u, '(A,3(1X,F8.3),A)') '1 Coupled', pa, ' 0 0 0 0'
    WRITE (u, '(A,3(1X,F8.3),A)') '2 '//type_b, pb, ' 0 0 0 0'
    WRITE (u, '(A)') '--- LINES ---'
    WRITE (u, '(A)') 'ID NodeA NodeB Outputs'
    WRITE (u, '(A)') '(-) (-) (-) (-)'
    WRITE (u, '(A)') '1 1 2 '//flags
    WRITE (u, '(A)') '--- SECTIONS ---'
    WRITE (u, '(A)') 'LineID LineType Length NumSegs'
    WRITE (u, '(A)') '(-) (-) (m) (-)'
    WRITE (u, '(A)') '1 pcable 100.0 40'
    WRITE (u, '(A)') '--- OPTIONS ---'
    WRITE (u, '(A)') '9.80665 g'
    WRITE (u, '(A)') '1025.0 rhoW'
    WRITE (u, '(F6.3,A)') DT, ' dtM'
    WRITE (u, '(F7.3,A)') tmax, ' TMax'
    IF (LEN_TRIM(motion) > 0) WRITE (u, '(A)') TRIM(motion)//' motionFile'
    IF (PRESENT(extra)) WRITE (u, '(A)') extra
    WRITE (u, '(A)') '--- OUTPUTS ---'
    WRITE (u, '(A)') 'FairTen1 AnchTen1 Point1px Point1pz Point2px Point2pz'
    WRITE (u, '(A)') '--- END ---'
    CLOSE (u)
  END SUBROUTINE write_deck

  SUBROUTINE write_heading_deck(path, type_b, with_motion)
    !! A 360 m slack cable from (0, 0, -14) to (239.589104, 180.544538, -20) (a 300 m span at a
    !! 36.99 deg heading) on an 80 m seabed, 20 s; with_motion: End A surges 3 m by motionFile rows
    !! that hold a Coupled End B at its deck position.
    CHARACTER(*), INTENT(IN) :: path, type_b
    LOGICAL, INTENT(IN) :: with_motion
    INTEGER :: u, k
    REAL(wp) :: t, x, v, a
    IF (with_motion) THEN
      OPEN (NEWUNIT=u, FILE='tme_zero_h_'//type_b//'.txt', STATUS='REPLACE', ACTION='WRITE')
      DO k = 0, 400
        t = REAL(k, wp)*DT
        CALL ramp(t, 3.0_wp, x, v, a)
        WRITE (u, '(F10.5,A,9(1X,ES24.16))') t, ' 1', x, 0.0_wp, -14.0_wp, v, 0.0_wp, 0.0_wp, a, 0.0_wp, 0.0_wp
        IF (type_b == 'Coupled') WRITE (u, '(F10.5,A)') t, ' 2 239.589104 180.544538 -20.0 0 0 0 0 0 0'
      END DO
      CLOSE (u)
    END IF
    OPEN (NEWUNIT=u, FILE=path, STATUS='REPLACE', ACTION='WRITE')
    WRITE (u, '(A)') 'two moving ends heading gate'
    WRITE (u, '(A)') '--- LINE TYPES ---'
    WRITE (u, '(A)') 'Name Diam Mass EA BA EI Cdn Cdt Can Cat'
    WRITE (u, '(A)') '(-) (m) (kg/m) (N) (-) (Nm2) (-) (-) (-) (-)'
    WRITE (u, '(A)') 'bare 0.160 36.70 4.69e8 0.0 1.99e4 1.2 0.1 1.0 0.0'
    WRITE (u, '(A)') '--- POINTS ---'
    WRITE (u, '(A)') 'ID Type X Y Z'
    WRITE (u, '(A)') '(-) (-) (m) (m) (m)'
    WRITE (u, '(A)') '1 Coupled 0.0 0.0 -14.0'
    WRITE (u, '(A)') '2 '//type_b//' 239.589104 180.544538 -20.0'
    WRITE (u, '(A)') '--- LINES ---'
    WRITE (u, '(A)') 'ID NodeA NodeB Outputs'
    WRITE (u, '(A)') '(-) (-) (-) (-)'
    WRITE (u, '(A)') '1 1 2 -'
    WRITE (u, '(A)') '--- SECTIONS ---'
    WRITE (u, '(A)') 'LineID LineType Length NumSegs'
    WRITE (u, '(A)') '(-) (-) (m) (-)'
    WRITE (u, '(A)') '1 bare 360.0 72'
    WRITE (u, '(A)') '--- OPTIONS ---'
    WRITE (u, '(A)') '9.80665 g'
    WRITE (u, '(A)') '1025.0 rhoW'
    WRITE (u, '(A)') '80.0 WtrDpth'
    WRITE (u, '(A)') '1.0e5 kBot'
    WRITE (u, '(A)') '1.0e4 cBot'
    WRITE (u, '(A)') '0.05 dtM'
    WRITE (u, '(A)') '20.0 TMax'
    IF (with_motion) WRITE (u, '(A)') 'tme_zero_h_'//type_b//'.txt motionFile'
    WRITE (u, '(A)') '--- OUTPUTS ---'
    WRITE (u, '(A)') 'FairTen1 AnchTen1 AnchFz1 Point1Fx Point2Fx'
    WRITE (u, '(A)') '--- END ---'
    CLOSE (u)
  END SUBROUTINE write_heading_deck

  SUBROUTINE ramp(t, amp, x, v, a)
    !! amp (1 - cos(w t)) / 2 with w = 2 pi / 8 s: from rest (x = v = 0 at t = 0).
    REAL(wp), INTENT(IN) :: t, amp
    REAL(wp), INTENT(OUT) :: x, v, a
    REAL(wp), PARAMETER :: W = 2.0_wp*PI/8.0_wp
    x = 0.5_wp*amp*(1.0_wp - COS(W*t))
    v = 0.5_wp*amp*W*SIN(W*t)
    a = 0.5_wp*amp*W*W*COS(W*t)
  END SUBROUTINE ramp

  SUBROUTINE write_motion(path, nstep, sa, sb, with_b, pb)
    !! motionFile rows: point 1 at (0, 0, ZE) + surge sa ramp, point 2 at (SPAN, 0, ZE) (or pb) + surge
    !! sb ramp (written when with_b).
    CHARACTER(*), INTENT(IN) :: path
    INTEGER, INTENT(IN) :: nstep
    REAL(wp), INTENT(IN) :: sa, sb
    LOGICAL, INTENT(IN) :: with_b
    REAL(wp), INTENT(IN), OPTIONAL :: pb(3)
    INTEGER :: u, k
    REAL(wp) :: t, x, v, a, b(3)
    b = [SPAN, 0.0_wp, ZE]
    IF (PRESENT(pb)) b = pb
    OPEN (NEWUNIT=u, FILE=path, STATUS='REPLACE', ACTION='WRITE')
    DO k = 0, nstep
      t = REAL(k, wp)*DT
      CALL ramp(t, sa, x, v, a)
      WRITE (u, '(F10.5,A,9(1X,ES24.16))') t, ' 1', x, 0.0_wp, ZE, v, 0.0_wp, 0.0_wp, a, 0.0_wp, 0.0_wp
      IF (with_b) THEN
        CALL ramp(t, sb, x, v, a)
        WRITE (u, '(F10.5,A,9(1X,ES24.16))') t, ' 2', b(1) + x, b(2), b(3), v, 0.0_wp, 0.0_wp, a, 0.0_wp, 0.0_wp
      END IF
    END DO
    CLOSE (u)
  END SUBROUTINE write_motion

  SUBROUTINE run_deck(path, root, ok, em)
    CHARACTER(*), INTENT(IN) :: path, root
    LOGICAL, INTENT(OUT) :: ok
    CHARACTER(*), INTENT(OUT) :: em
    LOGICAL :: conv
    INTEGER :: es
    CALL CD_Run_Deck_Driver(path, root, conv, es, em)
    ok = es == CD_DECKDRV_OK .AND. conv
  END SUBROUTINE run_deck

  LOGICAL FUNCTION same_file(a, b) RESULT(same)
    !! Byte-identical text files (line by line, the same number of lines).
    CHARACTER(*), INTENT(IN) :: a, b
    INTEGER :: ua, ub, ia, ib
    CHARACTER(16384) :: la, lb
    same = .FALSE.
    OPEN (NEWUNIT=ua, FILE=a, STATUS='OLD', ACTION='READ', IOSTAT=ia)
    IF (ia /= 0) RETURN
    OPEN (NEWUNIT=ub, FILE=b, STATUS='OLD', ACTION='READ', IOSTAT=ib)
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
    same = ia /= 0 .AND. ib /= 0
    CLOSE (ua)
    CLOSE (ub)
  END FUNCTION same_file

  SUBROUTINE read_rows(path, vals, nrow, ok)
    !! Every data row of a driver .out file (two header lines) into vals(:, 1:nrow).
    CHARACTER(*), INTENT(IN) :: path
    REAL(wp), INTENT(OUT) :: vals(:, :)
    INTEGER, INTENT(OUT) :: nrow
    LOGICAL, INTENT(OUT) :: ok
    INTEGER :: u, ios
    CHARACTER(512) :: buf
    nrow = 0
    vals = 0.0_wp
    ok = .FALSE.
    OPEN (NEWUNIT=u, FILE=path, STATUS='OLD', ACTION='READ', IOSTAT=ios)
    IF (ios /= 0) RETURN
    READ (u, '(A)', IOSTAT=ios) buf
    READ (u, '(A)', IOSTAT=ios) buf
    DO WHILE (nrow < SIZE(vals, 2))
      READ (u, *, IOSTAT=ios) vals(:, nrow + 1)
      IF (ios /= 0) EXIT
      nrow = nrow + 1
    END DO
    CLOSE (u)
    ok = nrow > 0 .AND. ALL(IEEE_IS_FINITE(vals(:, 1:nrow)))
  END SUBROUTINE read_rows

  ! ------------------------------------------------------------------------------------------
  SUBROUTINE check_zero_motion()
    !! Z. A Coupled End B held by its motionFile rows (or by the absence of a motionFile) is the
    !!    Fixed End B: every output file byte for byte, while End A surges 2 m.
    INTEGER, PARAMETER :: NSTEP = 120
    CHARACTER(16), PARAMETER :: SFX(5) = [CHARACTER(16) :: '.out', '.Line1.p.out', '.Line1.t.out', &
                                                                                         '.static.out', '.elements.out']
    LOGICAL :: ok, same
    CHARACTER(1024) :: em
    INTEGER :: k
    CALL write_motion('tme_zero_a.txt', NSTEP, 2.0_wp, 0.0_wp, .FALSE.)
    CALL write_motion('tme_zero_ab.txt', NSTEP, 2.0_wp, 0.0_wp, .TRUE.)
    CALL write_deck('tme_zero_fixed.dat', 'Fixed', 'tme_zero_a.txt', NSTEP*DT, 1.0_wp, [0.0_wp, 0.0_wp, ZE], &
                    [SPAN, 0.0_wp, ZE], 'pt')
    CALL write_deck('tme_zero_moving.dat', 'Coupled', 'tme_zero_ab.txt', NSTEP*DT, 1.0_wp, [0.0_wp, 0.0_wp, ZE], &
                    [SPAN, 0.0_wp, ZE], 'pt')
    CALL run_deck('tme_zero_fixed.dat', 'tme_zero_fixed', ok, em)
    CALL require(ok, 'Z: the Fixed End B deck runs: '//TRIM(em))
    CALL run_deck('tme_zero_moving.dat', 'tme_zero_moving', ok, em)
    CALL require(ok, 'Z: the deck with a Coupled End B held by its motion rows runs: '//TRIM(em))
    same = .TRUE.
    DO k = 1, SIZE(SFX)
      IF (.NOT. same_file('tme_zero_fixed'//TRIM(SFX(k)), 'tme_zero_moving'//TRIM(SFX(k)))) THEN
        same = .FALSE.
        WRITE (*, '(A)') '  differs: '//TRIM(SFX(k))
      END IF
    END DO
    WRITE (*, '(A,L1)') 'zero motion, motionFile: Fixed and held Coupled End B byte-identical: ', same
    CALL require(same, 'Z: a Coupled End B held at rest writes the Fixed End B files byte for byte')
    ! no motionFile: both Coupled ends are held at their deck positions
    CALL write_deck('tme_zero_fixed0.dat', 'Fixed', '', 1.0_wp, 1.0_wp, [0.0_wp, 0.0_wp, ZE], [SPAN, 0.0_wp, ZE], &
                    '-')
    CALL write_deck('tme_zero_moving0.dat', 'Coupled', '', 1.0_wp, 1.0_wp, [0.0_wp, 0.0_wp, ZE], &
                    [SPAN, 0.0_wp, ZE], '-')
    CALL run_deck('tme_zero_fixed0.dat', 'tme_zero_fixed0', ok, em)
    CALL require(ok, 'Z: the Fixed End B deck without motion runs: '//TRIM(em))
    CALL run_deck('tme_zero_moving0.dat', 'tme_zero_moving0', ok, em)
    CALL require(ok, 'Z: the Coupled End B deck without motion runs: '//TRIM(em))
    same = same_file('tme_zero_fixed0.out', 'tme_zero_moving0.out')
    WRITE (*, '(A,L1)') 'zero motion, no motionFile: byte-identical: ', same
    CALL require(same, 'Z: without a motionFile a Coupled End B is held as a Fixed one, byte for byte')
    ! the modal analysis holds both ends: a Coupled End B is the Fixed End B there too
    CALL write_deck('tme_zero_fixedm.dat', 'Fixed', '', 0.0_wp, 1.0_wp, [0.0_wp, 0.0_wp, ZE], [SPAN, 0.0_wp, ZE], &
                    '-', '6 nModes')
    CALL write_deck('tme_zero_movingm.dat', 'Coupled', '', 0.0_wp, 1.0_wp, [0.0_wp, 0.0_wp, ZE], &
                    [SPAN, 0.0_wp, ZE], '-', '6 nModes')
    CALL run_deck('tme_zero_fixedm.dat', 'tme_zero_fixedm', ok, em)
    CALL require(ok, 'Z: the modal deck with a Fixed End B runs: '//TRIM(em))
    CALL run_deck('tme_zero_movingm.dat', 'tme_zero_movingm', ok, em)
    CALL require(ok, 'Z: the modal deck with a Coupled End B runs: '//TRIM(em))
    same = same_file('tme_zero_fixedm.modes.out', 'tme_zero_movingm.modes.out')
    WRITE (*, '(A,L1)') 'zero motion, nModes: modes files byte-identical: ', same
    CALL require(same, 'Z: the modes of a line with a Coupled End B are those with a Fixed End B')
    ! a 37 deg chord heading: a 360 m slack cable over a 300 m span touching down on an 80 m seabed,
    ! 20 s held (End B read back in global axes and stepped at rest), and with End A surging
    BLOCK
      INTEGER :: ih
      DO ih = 1, 2
        CALL write_heading_deck('tme_zero_fixedh.dat', 'Fixed', ih == 2)
        CALL write_heading_deck('tme_zero_movingh.dat', 'Coupled', ih == 2)
        CALL run_deck('tme_zero_fixedh.dat', 'tme_zero_fixedh', ok, em)
        CALL require(ok, 'Z: the 37 deg Fixed End B deck runs: '//TRIM(em))
        CALL run_deck('tme_zero_movingh.dat', 'tme_zero_movingh', ok, em)
        CALL require(ok, 'Z: the 37 deg held Coupled End B deck runs: '//TRIM(em))
        same = same_file('tme_zero_fixedh.out', 'tme_zero_movingh.out')
        WRITE (*, '(A,A,A,L1)') 'zero motion at a 37 deg heading (', MERGE('no motionFile', 'motionFile   ', ih == 1), &
          '): byte-identical: ', same
        CALL require(same, 'Z: at a 37 deg heading a held Coupled End B is the Fixed End B, byte for byte')
      END DO
    END BLOCK
  END SUBROUTINE check_zero_motion

  ! ------------------------------------------------------------------------------------------
  SUBROUTINE build(cable, path, ok)
    !! A cable with two host-driven ends from a deck (CD_Init_Deck_HermiteCable moving_end_b).
    TYPE(CD_HFMF_ModuleType), INTENT(INOUT) :: cable
    CHARACTER(*), INTENT(IN) :: path
    LOGICAL, INTENT(OUT) :: ok
    INTEGER :: cn, es
    CHARACTER(1024) :: em
    CALL CD_Init_Deck_HermiteCable(path, DT, cable, cn, es, em, moving_end_b=.TRUE.)
    ok = es == CD_DECKDRV_OK
    CALL require(ok, 'the two-moving-end cable builds from '//TRIM(path)//': '//TRIM(em))
    IF (ok) THEN
      ok = cable%moving_b
      CALL require(ok, 'the cable built from '//TRIM(path)//' has a moving End B')
    END IF
  END SUBROUTINE build

  SUBROUTINE check_symmetry()
    !! S. The line of the decks above hangs symmetrically between (0, 0, -20) and (80, 0, -20). Both
    !!    ends move apart by 2 m each and rise 1 m: x_A = -d(t), x_B = 80 + d(t), z = -20 + h(t). The
    !!    mirror x -> 80 - x with the node order reversed (internal node k <-> nn + 1 - k) maps the
    !!    problem onto itself, so x_k + x_(nn+1-k) = 80, z_k = z_(nn+1-k), y = 0, and the End B load is
    !!    the mirror image of the End A load (Fx_B = -Fx_A, Fz_B = Fz_A) at every step.
    INTEGER, PARAMETER :: NSTEP = 160
    TYPE(CD_HFMF_ModuleType), ALLOCATABLE :: cab
    REAL(wp), ALLOCATABLE :: xyz(:, :)
    REAL(wp) :: t, d, vd, ad, h, vh, ah, fa(3), fb(3), ex, ez, ey, ef, fscale
    INTEGER :: s, k, nn, es
    LOGICAL :: ok
    CHARACTER(1024) :: em
    ALLOCATE (cab)
    CALL write_deck('tme_sym.dat', 'Coupled', '', NSTEP*DT, 1.0_wp, [0.0_wp, 0.0_wp, ZE], [SPAN, 0.0_wp, ZE], '-')
    CALL build(cab, 'tme_sym.dat', ok)
    IF (.NOT. ok) RETURN
    nn = cab%line%nn
    ALLOCATE (xyz(3, nn))
    ex = 0.0_wp; ez = 0.0_wp; ey = 0.0_wp; ef = 0.0_wp; fscale = 0.0_wp
    DO s = 0, NSTEP
      IF (s > 0) THEN
        t = REAL(s, wp)*DT
        CALL ramp(t, 2.0_wp, d, vd, ad)
        CALL ramp(t, 1.0_wp, h, vh, ah)
        CALL CD_HFMF_UpdateStates(cab, [-d, 0.0_wp, ZE + h], [-vd, 0.0_wp, vh], [-ad, 0.0_wp, ah], es, em, &
                                  ub_pos=[SPAN + d, 0.0_wp, ZE + h], ub_vel=[vd, 0.0_wp, vh], ub_acc=[ad, 0.0_wp, ah])
        CALL require(es == CD_HFMF_OK, 'S: the symmetric step converges: '//TRIM(em))
        IF (es /= CD_HFMF_OK) EXIT
      END IF
      CALL CD_HFMF_GetNodePositions(cab, xyz, es, em)
      CALL CD_HFMF_CalcOutput(cab, fa, es, em, y_end_b=fb)
      CALL require(es == CD_HFMF_OK, 'S: the end loads evaluate: '//TRIM(em))
      DO k = 1, nn
        ex = nan_max_abs([ex, ABS(xyz(1, k) + xyz(1, nn + 1 - k) - SPAN)])
        ez = nan_max_abs([ez, ABS(xyz(3, k) - xyz(3, nn + 1 - k))])
        ey = nan_max_abs([ey, ABS(xyz(2, k))])
      END DO
      ef = nan_max_abs([ef, ABS(fa(1) + fb(1)), ABS(fa(3) - fb(3)), ABS(fa(2)), ABS(fb(2))])
      fscale = MAX(fscale, NORM2(fa))
    END DO
    WRITE (*, '(A,3ES10.2,A,ES10.2,A,ES10.3,A)') 'symmetry: mirror error x, z, y ', ex, ez, ey, ' m; end loads ', &
      ef, ' N (of ', fscale, ' N)'
    CALL require(ex <= 1.0e-9_wp .AND. ez <= 1.0e-9_wp .AND. ey <= 1.0e-12_wp, &
                 'S: the node positions stay mirror symmetric to round-off')
    CALL require(ef <= 1.0e-8_wp*fscale, 'S: the End B load is the mirror image of the End A load')
    CALL CD_HFMF_End(cab)
  END SUBROUTINE check_symmetry

  ! ------------------------------------------------------------------------------------------
  SUBROUTINE check_rigid_translation()
    !! G. Without drag (Cd = 0) the cable's equations are Galilean invariant (inertia, added mass,
    !!    elasticity and weight see no constant velocity; the water is at rest and no free surface or
    !!    seabed is reached), so a line moving at the constant velocity v with both ends prescribed at
    !!    q_0 + v t, v, 0 is the held line shifted by v t. The generalised-alpha step integrates the
    !!    rigid motion exactly; the two runs differ by round-off only (positions and both end loads).
    INTEGER, PARAMETER :: NSTEP = 100
    REAL(wp), PARAMETER :: V0(3) = [1.3_wp, -0.7_wp, 0.4_wp]
    TYPE(CD_HFMF_ModuleType), ALLOCATABLE :: held, moving
    REAL(wp), ALLOCATABLE :: xh(:, :), xm(:, :)
    REAL(wp) :: qa(3), qb(3), va(3), aa(3), t, fa_h(3), fb_h(3), fa_m(3), fb_m(3), ep, ef, fscale, dten
    INTEGER :: s, k, nn, es
    LOGICAL :: ok
    CHARACTER(1024) :: em
    ALLOCATE (held, moving)
    CALL write_deck('tme_gal.dat', 'Coupled', '', NSTEP*DT, 0.0_wp, [0.0_wp, 0.0_wp, ZE], [SPAN, 0.0_wp, ZE], '-')
    CALL build(held, 'tme_gal.dat', ok)
    IF (.NOT. ok) RETURN
    CALL build(moving, 'tme_gal.dat', ok)
    IF (.NOT. ok) RETURN
    nn = held%line%nn
    ALLOCATE (xh(3, nn), xm(3, nn))
    CALL CD_HFMF_GetCoupledKinematics(held, qa, va, aa, es, em)
    CALL CD_HFMF_GetEndBKinematics(held, qb, va, aa, es, em)
    ! the moving line starts with the rigid velocity v at every node (translations; tangents at rest)
    DO k = 1, nn
      moving%line%v(6*k - 5:6*k - 3) = V0
    END DO
    ep = 0.0_wp; ef = 0.0_wp; fscale = 0.0_wp; dten = 0.0_wp
    DO s = 1, NSTEP
      t = REAL(s, wp)*DT
      CALL CD_HFMF_UpdateStates(held, qa, [0.0_wp, 0.0_wp, 0.0_wp], [0.0_wp, 0.0_wp, 0.0_wp], es, em, &
                                ub_pos=qb, ub_vel=[0.0_wp, 0.0_wp, 0.0_wp], ub_acc=[0.0_wp, 0.0_wp, 0.0_wp])
      CALL require(es == CD_HFMF_OK, 'G: the held step converges: '//TRIM(em))
      CALL CD_HFMF_UpdateStates(moving, qa + V0*t, V0, [0.0_wp, 0.0_wp, 0.0_wp], es, em, &
                                ub_pos=qb + V0*t, ub_vel=V0, ub_acc=[0.0_wp, 0.0_wp, 0.0_wp])
      CALL require(es == CD_HFMF_OK, 'G: the translating step converges: '//TRIM(em))
      IF (es /= CD_HFMF_OK) EXIT
      CALL CD_HFMF_GetNodePositions(held, xh, es, em)
      CALL CD_HFMF_GetNodePositions(moving, xm, es, em)
      DO k = 1, nn
        ep = nan_max_abs([ep, MAXVAL(ABS(xm(:, k) - V0*t - xh(:, k)))])
      END DO
      CALL CD_HFMF_CalcOutput(held, fa_h, es, em, y_end_b=fb_h)
      CALL CD_HFMF_CalcOutput(moving, fa_m, es, em, y_end_b=fb_m)
      ef = nan_max_abs([ef, MAXVAL(ABS(fa_m - fa_h)), MAXVAL(ABS(fb_m - fb_h))])
      dten = nan_max_abs([dten, ABS(NORM2(fa_m) - NORM2(fa_h))])
      fscale = MAX(fscale, NORM2(fa_h))
    END DO
    WRITE (*, '(A,ES10.2,A,ES10.2,A,ES10.2,A,ES10.3,A)') 'rigid translation: position error ', ep, &
      ' m, end-load error ', ef, ' N, tension change ', dten, ' N (of ', fscale, ' N)'
    CALL require(ep <= 1.0e-9_wp, 'G: the translating line is the held line shifted by v t')
    CALL require(ef <= 1.0e-8_wp*fscale, 'G: both end loads are unchanged by the rigid translation')
    CALL CD_HFMF_End(held)
    CALL CD_HFMF_End(moving)
  END SUBROUTINE check_rigid_translation

  ! ------------------------------------------------------------------------------------------
  SUBROUTINE check_reversal()
    !! R. Deck 1: End A (point 1, x = 0) held, End B (point 2, x = 80) surging 3 m -- the line driven
    !!    at its End B. Deck 2: the same line written in reverse, End A = point 2 surging, End B =
    !!    point 1 Fixed -- driven at its End A. The physical problem is one; the two decks run it on
    !!    reversed meshes, so the end tensions agree to the static and Newton tolerances:
    !!    AnchTen of deck 1 = FairTen of deck 2 and FairTen of deck 1 = AnchTen of deck 2.
    INTEGER, PARAMETER :: NSTEP = 160, NCOL = 7
    REAL(wp) :: r1(NCOL, NSTEP + 1), r2(NCOL, NSTEP + 1), err, scale
    INTEGER :: n1, n2, u, k
    LOGICAL :: ok
    CHARACTER(1024) :: em
    REAL(wp) :: t, x, v, a
    ! deck 1: motion rows, point 1 still, point 2 surging
    OPEN (NEWUNIT=u, FILE='tme_rev1.txt', STATUS='REPLACE', ACTION='WRITE')
    DO k = 0, NSTEP
      t = REAL(k, wp)*DT
      CALL ramp(t, 3.0_wp, x, v, a)
      WRITE (u, '(F10.5,A,9(1X,ES24.16))') t, ' 1', 0.0_wp, 0.0_wp, ZE, 0.0_wp, 0.0_wp, 0.0_wp, 0.0_wp, 0.0_wp, &
        0.0_wp
      WRITE (u, '(F10.5,A,9(1X,ES24.16))') t, ' 2', SPAN + x, 0.0_wp, ZE, v, 0.0_wp, 0.0_wp, a, 0.0_wp, 0.0_wp
    END DO
    CLOSE (u)
    CALL write_deck('tme_rev1.dat', 'Coupled', 'tme_rev1.txt', NSTEP*DT, 1.0_wp, [0.0_wp, 0.0_wp, ZE], &
                    [SPAN, 0.0_wp, ZE], '-')
    ! deck 2: End A = point 1 at x = 80 surging, End B = point 2 Fixed at x = 0
    OPEN (NEWUNIT=u, FILE='tme_rev2.txt', STATUS='REPLACE', ACTION='WRITE')
    DO k = 0, NSTEP
      t = REAL(k, wp)*DT
      CALL ramp(t, 3.0_wp, x, v, a)
      WRITE (u, '(F10.5,A,9(1X,ES24.16))') t, ' 1', SPAN + x, 0.0_wp, ZE, v, 0.0_wp, 0.0_wp, a, 0.0_wp, 0.0_wp
    END DO
    CLOSE (u)
    CALL write_deck('tme_rev2.dat', 'Fixed', 'tme_rev2.txt', NSTEP*DT, 1.0_wp, [SPAN, 0.0_wp, ZE], &
                    [0.0_wp, 0.0_wp, ZE], '-')
    CALL run_deck('tme_rev1.dat', 'tme_rev1', ok, em)
    CALL require(ok, 'R: the line driven at End B runs: '//TRIM(em))
    CALL run_deck('tme_rev2.dat', 'tme_rev2', ok, em)
    CALL require(ok, 'R: the reversed line driven at End A runs: '//TRIM(em))
    CALL read_rows('tme_rev1.out', r1, n1, ok)
    CALL require(ok .AND. n1 == NSTEP + 1, 'R: deck 1 output readable')
    CALL read_rows('tme_rev2.out', r2, n2, ok)
    CALL require(ok .AND. n2 == NSTEP + 1, 'R: deck 2 output readable')
    IF (n1 /= NSTEP + 1 .OR. n2 /= NSTEP + 1) RETURN
    err = MAXVAL(ABS(r1(3, :) - r2(2, :)))
    err = MAX(err, MAXVAL(ABS(r1(2, :) - r2(3, :))))
    scale = MAXVAL(ABS(r1(2:3, :)))
    WRITE (*, '(A,ES10.3,A,ES10.3,A)') 'reversal: end tension difference ', err, ' N (of ', scale, ' N)'
    ! the moving point's position is reported from the motion table on both decks
    CALL require(MAXVAL(ABS(r1(6, :) - r2(4, :))) <= 1.0e-6_wp, 'R: the driven point moves alike in both decks')
    CALL require(err <= 1.0e-5_wp*scale, 'R: the line driven at End B equals the reversed line driven at End A')
  END SUBROUTINE check_reversal

  ! ------------------------------------------------------------------------------------------
  SUBROUTINE drive_both(cab, s, es, em)
    !! Step s of the restart march: End A surges 2 m and End B heaves 1.5 m from rest.
    TYPE(CD_HFMF_ModuleType), INTENT(INOUT) :: cab
    INTEGER, INTENT(IN) :: s
    INTEGER, INTENT(OUT) :: es
    CHARACTER(*), INTENT(OUT) :: em
    REAL(wp) :: t, x, v, a, z, vz, az
    t = REAL(s, wp)*DT
    CALL ramp(t, 2.0_wp, x, v, a)
    CALL ramp(t, 1.5_wp, z, vz, az)
    CALL CD_HFMF_UpdateStates(cab, [x, 0.0_wp, ZE], [v, 0.0_wp, 0.0_wp], [a, 0.0_wp, 0.0_wp], es, em, &
                              ub_pos=[SPAN, 0.0_wp, ZE + z], ub_vel=[0.0_wp, 0.0_wp, vz], ub_acc=[0.0_wp, 0.0_wp, az])
  END SUBROUTINE drive_both

  SUBROUTINE check_restart()
    !! C. Run 40 steps with both ends moving; at step 20 take a snapshot and the checkpoint mirror.
    !!    (1) Restore the snapshot and re-run steps 21..40: bit-identical state and end loads. (2) Build
    !!    a fresh cable from the deck, reload the mirror at t_20 and run steps 21..40: bit-identical.
    !!    The carried step factor is not part of the mirror, so the cables factor fresh every step, as
    !!    the coupled aggregate's do.
    INTEGER, PARAMETER :: NSPLIT = 20, NEND = 40
    TYPE(CD_HFMF_ModuleType), ALLOCATABLE :: cab, fresh
    REAL(wp), ALLOCATABLE :: buf(:), q_ref(:), v_ref(:), a_ref(:)
    REAL(wp) :: fa_ref(3), fb_ref(3), fa(3), fb(3)
    INTEGER :: s, es
    LOGICAL :: ok, same_snap, same_mirror
    CHARACTER(1024) :: em
    ALLOCATE (cab, fresh)
    CALL write_deck('tme_rst.dat', 'Coupled', '', NEND*DT, 1.0_wp, [0.0_wp, 0.0_wp, ZE], [SPAN, 0.0_wp, ZE], '-')
    CALL build(cab, 'tme_rst.dat', ok)
    IF (.NOT. ok) RETURN
    cab%line%tangent_reuse = .FALSE.
    cab%line%tr_valid = .FALSE.
    DO s = 1, NEND
      IF (s == NSPLIT + 1) THEN
        CALL CD_HFMF_Snapshot(cab, es, em)
        CALL require(es == CD_HFMF_OK, 'C: snapshot: '//TRIM(em))
        ALLOCATE (buf(CD_HFMF_MirrorSize(cab)))
        CALL CD_HFMF_PackMirror(cab, buf, es, em)
        CALL require(es == CD_HFMF_OK, 'C: pack mirror: '//TRIM(em))
      END IF
      CALL drive_both(cab, s, es, em)
      CALL require(es == CD_HFMF_OK, 'C: the reference step converges: '//TRIM(em))
      IF (es /= CD_HFMF_OK) RETURN
    END DO
    q_ref = cab%line%q
    v_ref = cab%line%v
    a_ref = cab%line%a
    CALL CD_HFMF_CalcOutput(cab, fa_ref, es, em, y_end_b=fb_ref)
    ! (1) snapshot restore
    CALL CD_HFMF_Restore(cab, es, em)
    CALL require(es == CD_HFMF_OK, 'C: restore: '//TRIM(em))
    DO s = NSPLIT + 1, NEND
      CALL drive_both(cab, s, es, em)
      IF (es /= CD_HFMF_OK) EXIT
    END DO
    CALL CD_HFMF_CalcOutput(cab, fa, es, em, y_end_b=fb)
    same_snap = ALL(cab%line%q == q_ref) .AND. ALL(cab%line%v == v_ref) .AND. ALL(cab%line%a == a_ref) .AND. &
                ALL(fa == fa_ref) .AND. ALL(fb == fb_ref)
    ! (2) mirror reload into a cable rebuilt from the deck
    CALL build(fresh, 'tme_rst.dat', ok)
    IF (.NOT. ok) RETURN
    fresh%line%tangent_reuse = .FALSE.
    fresh%line%tr_valid = .FALSE.
    CALL CD_HFMF_UnpackMirror(fresh, buf, REAL(NSPLIT, wp)*DT, es, em)
    CALL require(es == CD_HFMF_OK, 'C: unpack mirror: '//TRIM(em))
    DO s = NSPLIT + 1, NEND
      CALL drive_both(fresh, s, es, em)
      IF (es /= CD_HFMF_OK) EXIT
    END DO
    CALL CD_HFMF_CalcOutput(fresh, fa, es, em, y_end_b=fb)
    same_mirror = ALL(fresh%line%q == q_ref) .AND. ALL(fresh%line%v == v_ref) .AND. &
                  ALL(fresh%line%a == a_ref) .AND. ALL(fa == fa_ref) .AND. ALL(fb == fb_ref)
    WRITE (*, '(A,L1,A,L1)') 'restart with two moving ends: snapshot bit-identical ', same_snap, &
      ', mirror rebuild bit-identical ', same_mirror
    CALL require(same_snap, 'C: a snapshot restore continues bit-identically')
    CALL require(same_mirror, 'C: a mirror reload into a rebuilt cable continues bit-identically')
    CALL CD_HFMF_End(cab)
    CALL CD_HFMF_End(fresh)
  END SUBROUTINE check_restart

  ! ------------------------------------------------------------------------------------------
  ! END CONNECTIONS and torsion at a moving End B
  ! ------------------------------------------------------------------------------------------
  SUBROUTINE write_tdeck(path, pa, ta, pb, tb, conn_a, conn_b, options, outs, irn)
    !! A straight 100 m neutral torsion line (EA 1e7, EI 1e6, GJ 5e4 N m^2, 40 elements) between
    !! POINT 1 (End A, type ta) at pa and POINT 2 (End B, type tb) at pb, with END CONNECTIONS rows
    !! conn_a, conn_b; irn the polar inertia per length of the LINE TYPES row.
    CHARACTER(*), INTENT(IN) :: path, ta, tb, conn_a, conn_b, options(:), outs
    REAL(wp), INTENT(IN) :: pa(3), pb(3), irn
    INTEGER :: u, i
    OPEN (NEWUNIT=u, FILE=path, STATUS='REPLACE', ACTION='WRITE')
    WRITE (u, '(A)') 'two moving ends torsion gate'
    WRITE (u, '(A)') '--- LINE TYPES ---'
    WRITE (u, '(A)') 'Name Diam Mass EA BA EI GAs GJ Irt Irn Cdn Cdt Can Cat'
    WRITE (u, '(A)') '(-) (m) (kg/m) (N) (Nm2) (N) (Nm2) (kgm) (kgm) (-) (-) (-) (-)'
    WRITE (u, '(A,ES24.16,A,ES12.5,A)') 'cab 0.2 ', 1025.0_wp*0.25_wp*PI*0.04_wp, ' 1.0e7 0.0 1.0e6 1.0e8 5.0e4 1.0 ', &
      irn, ' 0.0 0.0 0.0 0.0'
    WRITE (u, '(A)') '--- POINTS ---'
    WRITE (u, '(A)') 'ID Type X Y Z Mass Vol CdA Ca'
    WRITE (u, '(A)') '(-) (-) (m) (m) (m) (kg) (m3) (m2) (-)'
    WRITE (u, '(A,3(1X,F9.3),A)') '1 '//ta, pa, ' 0 0 0 0'
    WRITE (u, '(A,3(1X,F9.3),A)') '2 '//tb, pb, ' 0 0 0 0'
    WRITE (u, '(A)') '--- LINES ---'
    WRITE (u, '(A)') 'ID NodeA NodeB Outputs'
    WRITE (u, '(A)') '(-) (-) (-) (-)'
    WRITE (u, '(A)') '1 1 2 -'
    WRITE (u, '(A)') '--- SECTIONS ---'
    WRITE (u, '(A)') 'LineID LineType Length NumSegs'
    WRITE (u, '(A)') '(-) (-) (m) (-)'
    WRITE (u, '(A)') '1 cab 100.0 40'
    WRITE (u, '(A)') '--- END CONNECTIONS ---'
    WRITE (u, '(A)') 'LineID End Stiffness EzX EzY EzZ TorsStiffness NxX NxY NxZ Pretwist'
    WRITE (u, '(A)') '(-) (-) (N-m/rad) (-) (-) (-) (N-m/rad) (-) (-) (-) (deg)'
    WRITE (u, '(A)') '1 A '//conn_a
    WRITE (u, '(A)') '1 B '//conn_b
    WRITE (u, '(A)') '--- OPTIONS ---'
    WRITE (u, '(A)') '9.80665 g'
    WRITE (u, '(A)') '1025.0 rhoW'
    DO i = 1, SIZE(options)
      IF (LEN_TRIM(options(i)) > 0) WRITE (u, '(A)') TRIM(options(i))
    END DO
    WRITE (u, '(A)') '--- OUTPUTS ---'
    WRITE (u, '(A)') outs
    WRITE (u, '(A)') '--- END ---'
    CLOSE (u)
  END SUBROUTINE write_tdeck

  SUBROUTINE check_zero_motion_torsion()
    !! ZT. End A (x = 0) surges 1 m and rolls 20 deg (the motionFile roll column); End B at x = 100 is
    !!     Fixed, or Coupled with motion rows that hold it at rest. Both ends clamped along the line and
    !!     restrained in torsion, End B pretwisted 90 deg: the .out files are byte-identical.
    INTEGER, PARAMETER :: NSTEP = 40
    REAL(wp), PARAMETER :: DTT = 0.05_wp
    INTEGER :: u, k
    REAL(wp) :: t, x, v, a
    LOGICAL :: ok, same
    CHARACTER(1024) :: em
    CHARACTER(40) :: opt(3)
    OPEN (NEWUNIT=u, FILE='tme_zt_a.txt', STATUS='REPLACE', ACTION='WRITE')
    DO k = 0, NSTEP
      t = REAL(k, wp)*DTT
      CALL ramp(t, 1.0_wp, x, v, a)
      WRITE (u, '(F10.5,A,9(1X,ES24.16),1X,ES24.16)') t, ' 1', x, 0.0_wp, -50.0_wp, v, 0.0_wp, 0.0_wp, a, 0.0_wp, &
        0.0_wp, 20.0_wp*(1.0_wp - COS(PI*t/(NSTEP*DTT)))/2.0_wp
    END DO
    CLOSE (u)
    OPEN (NEWUNIT=u, FILE='tme_zt_ab.txt', STATUS='REPLACE', ACTION='WRITE')
    DO k = 0, NSTEP
      t = REAL(k, wp)*DTT
      CALL ramp(t, 1.0_wp, x, v, a)
      WRITE (u, '(F10.5,A,9(1X,ES24.16),1X,ES24.16)') t, ' 1', x, 0.0_wp, -50.0_wp, v, 0.0_wp, 0.0_wp, a, 0.0_wp, &
        0.0_wp, 20.0_wp*(1.0_wp - COS(PI*t/(NSTEP*DTT)))/2.0_wp
      WRITE (u, '(F10.5,A,10(1X,ES24.16))') t, ' 2', 100.0_wp, 0.0_wp, -50.0_wp, 0.0_wp, 0.0_wp, 0.0_wp, 0.0_wp, &
        0.0_wp, 0.0_wp, 0.0_wp
    END DO
    CLOSE (u)
    opt(1) = '0.05 dtM'
    WRITE (opt(2), '(F6.3,A)') NSTEP*DTT, ' TMax'
    opt(3) = 'tme_zt_a.txt motionFile'
    CALL write_tdeck('tme_zt_fixed.dat', [0.0_wp, 0.0_wp, -50.0_wp], 'Coupled', [100.0_wp, 0.0_wp, -50.0_wp], 'Fixed', &
                     'Rigid 1 0 0 Rigid 0 0 1 0', 'Rigid 1 0 0 Rigid 0 0 1 90', opt, &
                     'FairTen1 AnchTen1 Torq1N1 Torq1N41 Twist1', 1.0e-12_wp)
    opt(3) = 'tme_zt_ab.txt motionFile'
    CALL write_tdeck('tme_zt_moving.dat', [0.0_wp, 0.0_wp, -50.0_wp], 'Coupled', [100.0_wp, 0.0_wp, -50.0_wp], &
                     'Coupled', 'Rigid 1 0 0 Rigid 0 0 1 0', 'Rigid 1 0 0 Rigid 0 0 1 90', opt, &
                     'FairTen1 AnchTen1 Torq1N1 Torq1N41 Twist1', 1.0e-12_wp)
    CALL run_deck('tme_zt_fixed.dat', 'tme_zt_fixed', ok, em)
    CALL require(ok, 'ZT: the clamped, twisted line with a Fixed End B runs: '//TRIM(em))
    CALL run_deck('tme_zt_moving.dat', 'tme_zt_moving', ok, em)
    CALL require(ok, 'ZT: the clamped, twisted line with a held Coupled End B runs: '//TRIM(em))
    same = same_file('tme_zt_fixed.out', 'tme_zt_moving.out')
    IF (.NOT. same_file('tme_zt_fixed.static.out', 'tme_zt_moving.static.out')) same = .FALSE.
    WRITE (*, '(A,L1)') 'zero motion with END CONNECTIONS and torsion: byte-identical: ', same
    CALL require(same, 'ZT: a held Coupled End B with a clamped, torsional connection is the Fixed one, byte for byte')
  END SUBROUTINE check_zero_motion_torsion

  SUBROUTINE check_same_roll()
    !! TS. A vessel rolls at 30 deg/s about the axis of the line, both line ends on it (Vessel points
    !!     on the roll axis, vesselRef on the axis): both end frames turn by the same angle, the line
    !!     turns with them about its own axis, and the torque stays GJ Phi / L with Phi = 90 deg.
    INTEGER, PARAMETER :: NSTEP = 20, NCOL = 6
    REAL(wp), PARAMETER :: GJ = 5.0e4_wp, L = 100.0_wp, RATE = 30.0_wp
    REAL(wp) :: rows(NCOL, NSTEP + 1), m_ref, err, twist_err
    INTEGER :: u, k, n
    LOGICAL :: ok
    CHARACTER(1024) :: em
    CHARACTER(40) :: opt(4)
    OPEN (NEWUNIT=u, FILE='tme_ts_vessel.txt', STATUS='REPLACE', ACTION='WRITE')
    DO k = 0, NSTEP
      WRITE (u, '(F6.2,A,F10.4,A,ES24.16,A)') 0.05_wp*k, ' 0 0 -50 ', RATE*0.05_wp*k, ' 0 0 0 0 0 ', &
        RATE*PI/180.0_wp, ' 0 0 0 0 0 0 0 0'
    END DO
    CLOSE (u)
    opt(1) = '0.05 dtM'
    WRITE (opt(2), '(F6.3,A)') NSTEP*0.05_wp, ' TMax'
    opt(3) = 'tme_ts_vessel.txt vesselMotion'
    opt(4) = '0|0|-50 vesselRef'
    CALL write_tdeck('tme_ts.dat', [0.0_wp, 0.0_wp, -50.0_wp], 'Vessel', [100.0_wp, 0.0_wp, -50.0_wp], 'Vessel', &
          'Rigid 1 0 0 Rigid 0 0 1 0', 'Rigid 1 0 0 Rigid 0 0 1 90', opt, 'Torq1N1 Torq1N41 Twist1 FairTen1 AnchTen1', &
                     1.0e-12_wp)
    CALL run_deck('tme_ts.dat', 'tme_ts', ok, em)
    CALL require(ok, 'TS: the twisted line between two points of a rolling vessel runs: '//TRIM(em))
    CALL read_rows('tme_ts.out', rows, n, ok)
    CALL require(ok .AND. n == NSTEP + 1, 'TS: output readable')
    IF (.NOT. ok) RETURN
    m_ref = GJ*(0.5_wp*PI)/L
    err = 0.0_wp
    twist_err = 0.0_wp
    DO k = 1, n
      err = nan_max_abs([err, ABS(rows(2, k) - m_ref), ABS(rows(3, k) - m_ref)])
      twist_err = nan_max_abs([twist_err, ABS(rows(4, k) - 90.0_wp)])
    END DO
    WRITE (*, '(A,F8.1,A,ES10.3,A,ES10.3,A,ES10.3,A)') 'same roll of both end frames: vessel roll up to ', &
      RATE*NSTEP*0.05_wp, ' deg, torque error ', err, ' N m (of ', m_ref, ' N m), twist error ', twist_err, ' deg'
    CALL require(err <= 1.0e-6_wp*m_ref, 'TS: both end frames rolled by the same angle keep the torque')
    CALL require(twist_err <= 1.0e-6_wp, 'TS: and the twist')
  END SUBROUTINE check_same_roll

  SUBROUTINE check_opposite_roll()
    !! TO. (1) Deck: both ends Coupled, rolled by the motionFile roll column phi(t) at each end (each
    !!     about its inward tangent, so the two frames turn in opposite senses about the line):
    !!     Phi = Pretwist(B) - Pretwist(A) - 2 phi, Torq = GJ (Phi0 - 2 phi) / L at every step.
    !!     (2) Library: the same line with both ends' parent orientations rolled about the line axis by
    !!     +phi (End A) and -phi (End B): the torque changes by GJ (2 phi) / L; by +phi and +phi it does
    !!     not change.
    INTEGER, PARAMETER :: NSTEP = 20, NCOL = 4
    REAL(wp), PARAMETER :: GJ = 5.0e4_wp, L = 100.0_wp, PHI_MAX = 45.0_wp
    REAL(wp) :: rows(NCOL, NSTEP + 1), err, phi, m_ref, m0, mt, ms, fa(3), ma(3), fb(3), mb(3), err_o, err_s
    INTEGER :: u, k, n, cn, es
    LOGICAL :: ok
    CHARACTER(1024) :: em
    CHARACTER(40) :: opt(3)
    TYPE(CD_HFMF_ModuleType), ALLOCATABLE :: opp, same
    OPEN (NEWUNIT=u, FILE='tme_to_roll.txt', STATUS='REPLACE', ACTION='WRITE')
    DO k = 0, NSTEP
      phi = PHI_MAX*REAL(k, wp)/REAL(NSTEP, wp)
      WRITE (u, '(F10.5,A,10(1X,ES24.16))') 0.05_wp*k, ' 1', 0.0_wp, 0.0_wp, -50.0_wp, 0.0_wp, 0.0_wp, 0.0_wp, &
        0.0_wp, 0.0_wp, 0.0_wp, phi
      WRITE (u, '(F10.5,A,10(1X,ES24.16))') 0.05_wp*k, ' 2', 100.0_wp, 0.0_wp, -50.0_wp, 0.0_wp, 0.0_wp, 0.0_wp, &
        0.0_wp, 0.0_wp, 0.0_wp, phi
    END DO
    CLOSE (u)
    opt(1) = '0.05 dtM'
    WRITE (opt(2), '(F6.3,A)') NSTEP*0.05_wp, ' TMax'
    opt(3) = 'tme_to_roll.txt motionFile'
    CALL write_tdeck('tme_to.dat', [0.0_wp, 0.0_wp, -50.0_wp], 'Coupled', [100.0_wp, 0.0_wp, -50.0_wp], 'Coupled', &
                     'Rigid 1 0 0 Rigid 0 0 1 0', 'Rigid 1 0 0 Rigid 0 0 1 90', opt, 'Torq1N1 Torq1N41 Twist1', &
                     1.0e-12_wp)
    CALL run_deck('tme_to.dat', 'tme_to', ok, em)
    CALL require(ok, 'TO: the twisted line rolled at both ends runs: '//TRIM(em))
    CALL read_rows('tme_to.out', rows, n, ok)
    CALL require(ok .AND. n == NSTEP + 1, 'TO: output readable')
    err = 0.0_wp
    IF (ok) THEN
      DO k = 1, n
        phi = PHI_MAX*REAL(k - 1, wp)/REAL(NSTEP, wp)*PI/180.0_wp
        m_ref = GJ*(0.5_wp*PI - 2.0_wp*phi)/L
        err = nan_max_abs([err, ABS(rows(2, k) - m_ref), ABS(rows(3, k) - m_ref)])
      END DO
    END IF
    WRITE (*, '(A,F6.1,A,ES10.3,A)') 'opposite rolls (roll columns, up to ', PHI_MAX, &
      ' deg each): torque error against GJ (Phi0 - 2 phi) / L ', err, ' N m'
    CALL require(err <= 1.0e-6_wp*GJ, 'TO: opposite rolls of the end frames change the torque by GJ (2 phi) / L')
    ! (2) library: parent orientations of the two ends
    ALLOCATE (opp, same)
    opt(3) = ''
    CALL write_tdeck('tme_to_lib.dat', [0.0_wp, 0.0_wp, -50.0_wp], 'Coupled', [100.0_wp, 0.0_wp, -50.0_wp], 'Coupled', &
                     'Rigid 1 0 0 Rigid 0 0 1 0', 'Rigid 1 0 0 Rigid 0 0 1 90', opt, 'FairTen1', 1.0e-12_wp)
    CALL CD_Init_Deck_HermiteCable('tme_to_lib.dat', 0.05_wp, opp, cn, es, em, host_orientation=.TRUE., &
                                   moving_end_b=.TRUE.)
    CALL require(es == CD_DECKDRV_OK, 'TO: library cable builds: '//TRIM(em))
    IF (es /= CD_DECKDRV_OK) RETURN
    CALL CD_Init_Deck_HermiteCable('tme_to_lib.dat', 0.05_wp, same, cn, es, em, host_orientation=.TRUE., &
                                   moving_end_b=.TRUE.)
    m0 = opp%line%torsion%torque
    err_o = 0.0_wp
    err_s = 0.0_wp
    DO k = 1, NSTEP
      phi = PHI_MAX*REAL(k, wp)/REAL(NSTEP, wp)*PI/180.0_wp
      CALL CD_HFMF_UpdateStates(opp, [0.0_wp, 0.0_wp, -50.0_wp], [0.0_wp, 0.0_wp, 0.0_wp], [0.0_wp, 0.0_wp, 0.0_wp], &
                                es, em, u_orientation=roll_x(phi), ub_pos=[100.0_wp, 0.0_wp, -50.0_wp], &
                                ub_vel=[0.0_wp, 0.0_wp, 0.0_wp], ub_acc=[0.0_wp, 0.0_wp, 0.0_wp], &
                                ub_orientation=roll_x(-phi))
      CALL require(es == CD_HFMF_OK, 'TO: opposite-roll step: '//TRIM(em))
      CALL CD_HFMF_UpdateStates(same, [0.0_wp, 0.0_wp, -50.0_wp], [0.0_wp, 0.0_wp, 0.0_wp], [0.0_wp, 0.0_wp, 0.0_wp], &
                                es, em, u_orientation=roll_x(phi), ub_pos=[100.0_wp, 0.0_wp, -50.0_wp], &
                                ub_vel=[0.0_wp, 0.0_wp, 0.0_wp], ub_acc=[0.0_wp, 0.0_wp, 0.0_wp], &
                                ub_orientation=roll_x(phi))
      CALL require(es == CD_HFMF_OK, 'TO: same-roll step: '//TRIM(em))
      mt = opp%line%torsion%torque
      ms = same%line%torsion%torque
      ! a parent rolled by +phi about +x turns End A's frame by +phi about the line (A -> B), End B's
      ! by -phi: the relative roll of End B against End A, Phi, falls by 2 phi
      err_o = nan_max_abs([err_o, ABS((mt - m0) + GJ*2.0_wp*phi/L)])
      err_s = nan_max_abs([err_s, ABS(ms - m0)])
    END DO
    ! the torque returns to the two parents as equal and opposite moments about the line (the
    ! same-roll line, which keeps its torque M = GJ Phi0 / L)
    CALL CD_HFMF_CalcOutput(same, fa, es, em, y_moment=ma, y_end_b=fb, y_moment_b=mb)
    WRITE (*, '(A,ES10.3,A,ES10.3,A,ES12.5,A,2ES13.5)') 'library rolls: opposite error ', err_o, ' N m, same error ', &
      err_s, ' N m (torque ', m0, ' N m); end moments about x ', ma(1), mb(1)
    CALL require(err_o <= 1.0e-6_wp*GJ, 'TO: parents rolled by +phi and -phi change the torque by GJ (2 phi) / L')
    CALL require(err_s <= 1.0e-6_wp*GJ, 'TO: parents rolled by the same angle keep the torque')
    CALL require(ABS(ma(1) + mb(1)) <= 1.0e-6_wp*ABS(ms) .AND. ABS(ABS(ma(1)) - ABS(ms)) <= 1.0e-6_wp*ABS(ms), &
                 'TO: the two parents carry the torque as equal and opposite moments about the line')
    CALL CD_HFMF_End(opp)
    CALL CD_HFMF_End(same)
  END SUBROUTINE check_opposite_roll

  FUNCTION roll_x(psi) RESULT(r)
    !! Global-to-parent DCM of a parent rolled by psi about +x (the transpose of the rotation).
    REAL(wp), INTENT(IN) :: psi
    REAL(wp) :: r(3, 3)
    r = 0.0_wp
    r(1, 1) = 1.0_wp
    r(2, 2) = COS(psi)
    r(3, 3) = COS(psi)
    r(2, 3) = SIN(psi)
    r(3, 2) = -SIN(psi)
  END FUNCTION roll_x

  FUNCTION turn_dcm(t) RESULT(r)
    !! Global-to-parent DCM of a parent turned by yaw 0.15 sin(w t) about z, then pitch 0.1 (1 - cos(w t))
    !! about y (w = 2 pi / 8 s): R = Rz Ry, DCM = R^T.
    REAL(wp), INTENT(IN) :: t
    REAL(wp) :: r(3, 3), rz(3, 3), ry(3, 3), yaw, pitch
    REAL(wp), PARAMETER :: W = 2.0_wp*PI/8.0_wp
    yaw = 0.15_wp*SIN(W*t)
    pitch = 0.1_wp*(1.0_wp - COS(W*t))
    rz = RESHAPE([COS(yaw), SIN(yaw), 0.0_wp, -SIN(yaw), COS(yaw), 0.0_wp, 0.0_wp, 0.0_wp, 1.0_wp], [3, 3])
    ry = RESHAPE([COS(pitch), 0.0_wp, -SIN(pitch), 0.0_wp, 1.0_wp, 0.0_wp, SIN(pitch), 0.0_wp, COS(pitch)], [3, 3])
    r = TRANSPOSE(MATMUL(rz, ry))
  END FUNCTION turn_dcm

  SUBROUTINE turn_rates(t, w_g, al_g)
    !! Angular velocity and acceleration (global axes) of turn_dcm: R = Rz(yaw) Ry(pitch),
    !! w = yaw' e_z + pitch' Rz e_y, al = yaw'' e_z + pitch'' Rz e_y + yaw' pitch' e_z x (Rz e_y).
    REAL(wp), INTENT(IN) :: t
    REAL(wp), INTENT(OUT) :: w_g(3), al_g(3)
    REAL(wp), PARAMETER :: W = 2.0_wp*PI/8.0_wp
    REAL(wp) :: yaw, yd, ydd, pd, pdd, ey(3)
    yaw = 0.15_wp*SIN(W*t)
    yd = 0.15_wp*W*COS(W*t)
    ydd = -0.15_wp*W*W*SIN(W*t)
    pd = 0.1_wp*W*SIN(W*t)
    pdd = 0.1_wp*W*W*COS(W*t)
    ey = [-SIN(yaw), COS(yaw), 0.0_wp]
    w_g = [0.0_wp, 0.0_wp, yd] + pd*ey
    al_g = [0.0_wp, 0.0_wp, ydd] + pdd*ey + yd*pd*[-COS(yaw), -SIN(yaw), 0.0_wp]
  END SUBROUTINE turn_rates

  SUBROUTINE check_bending_reversal(kind)
    !! B. Cable 1: End A (x = 0) held, End B (x = 80) on a parent that surges 2 m from rest and turns
    !!    (yaw and pitch); its End B connection direction and moment turn with that parent. Cable 2:
    !!    the same line written in reverse (End A = the parent's point, End B Fixed at x = 0, Ez reversed),
    !!    driven at End A by the same parent motion. End B's force and connection moment of cable 1
    !!    equal End A's of cable 2, and the held ends' alike, to the Newton tolerance (1e-9 here).
    CHARACTER(*), INTENT(IN) :: kind
    INTEGER, PARAMETER :: NSTEP = 120
    TYPE(CD_HFMF_ModuleType), ALLOCATABLE :: c1, c2
    REAL(wp) :: t, x, v, a, w_g(3), al_g(3), dcm(3, 3), f1a(3), m1a(3), f1b(3), m1b(3), f2a(3), m2a(3), f2b(3), m2b(3)
    REAL(wp) :: ef, em_, fs, ms
    INTEGER :: s, cn, es
    CHARACTER(1024) :: em
    CHARACTER(48) :: ca, cb, ca2, cb2
    ALLOCATE (c1, c2)
    IF (kind == 'clamped') THEN
      ca = 'Rigid 0.6 0 -0.8'
      cb = 'Rigid 0.6 0 0.8'
      ca2 = 'Rigid -0.6 0 -0.8'
      cb2 = 'Rigid -0.6 0 0.8'
    ELSE
      ca = '2.0e5 0.6 0 -0.8'
      cb = '2.0e5 0.6 0 0.8'
      ca2 = '2.0e5 -0.6 0 -0.8'
      cb2 = '2.0e5 -0.6 0 0.8'
    END IF
    CALL write_cdeck('tme_b1.dat', [0.0_wp, 0.0_wp, ZE], 'Coupled', [SPAN, 0.0_wp, ZE], 'Coupled', ca, cb)
    CALL write_cdeck('tme_b2.dat', [SPAN, 0.0_wp, ZE], 'Coupled', [0.0_wp, 0.0_wp, ZE], 'Fixed', ca2, cb2)
    CALL CD_Init_Deck_HermiteCable('tme_b1.dat', DT, c1, cn, es, em, host_orientation=.TRUE., moving_end_b=.TRUE.)
    CALL require(es == CD_DECKDRV_OK, 'B: cable 1 builds: '//TRIM(em))
    IF (es /= CD_DECKDRV_OK) RETURN
    CALL CD_Init_Deck_HermiteCable('tme_b2.dat', DT, c2, cn, es, em, host_orientation=.TRUE.)
    CALL require(es == CD_DECKDRV_OK, 'B: cable 2 builds: '//TRIM(em))
    IF (es /= CD_DECKDRV_OK) RETURN
    c1%tol = 1.0e-9_wp
    c2%tol = 1.0e-9_wp
    ef = 0.0_wp; em_ = 0.0_wp; fs = 0.0_wp; ms = 0.0_wp
    DO s = 1, NSTEP
      t = REAL(s, wp)*DT
      CALL ramp(t, 2.0_wp, x, v, a)
      dcm = turn_dcm(t)
      CALL turn_rates(t, w_g, al_g)
      CALL CD_HFMF_UpdateStates(c1, [0.0_wp, 0.0_wp, ZE], [0.0_wp, 0.0_wp, 0.0_wp], [0.0_wp, 0.0_wp, 0.0_wp], es, em, &
                                ub_pos=[SPAN + x, 0.0_wp, ZE], ub_vel=[v, 0.0_wp, 0.0_wp], ub_acc=[a, 0.0_wp, 0.0_wp], &
                                ub_orientation=dcm, ub_angular_velocity=w_g, ub_angular_acceleration=al_g)
      CALL require(es == CD_HFMF_OK, 'B: cable 1 step ('//kind//'): '//TRIM(em))
      IF (es /= CD_HFMF_OK) EXIT
      CALL CD_HFMF_UpdateStates(c2, [SPAN + x, 0.0_wp, ZE], [v, 0.0_wp, 0.0_wp], [a, 0.0_wp, 0.0_wp], es, em, &
                                u_orientation=dcm, u_angular_velocity=w_g, u_angular_acceleration=al_g)
      CALL require(es == CD_HFMF_OK, 'B: cable 2 step ('//kind//'): '//TRIM(em))
      IF (es /= CD_HFMF_OK) EXIT
      CALL CD_HFMF_CalcOutput(c1, f1a, es, em, y_moment=m1a, y_end_b=f1b, y_moment_b=m1b)
      CALL CD_HFMF_CalcOutput(c2, f2a, es, em, y_moment=m2a, y_end_b=f2b, y_moment_b=m2b)
      ef = nan_max_abs([ef, MAXVAL(ABS(f1b - f2a)), MAXVAL(ABS(f1a - f2b))])
      em_ = nan_max_abs([em_, MAXVAL(ABS(m1b - m2a)), MAXVAL(ABS(m1a - m2b))])
      fs = MAX(fs, NORM2(f2a))
      ms = MAX(ms, NORM2(m2a), NORM2(m2b))
    END DO
    WRITE (*, '(A,A,A,ES10.3,A,ES10.3,A,ES10.3,A,ES10.3,A)') 'bending reversal (', kind, '): end force difference ', &
      ef, ' N (of ', fs, ' N), connection moment difference ', em_, ' N m (of ', ms, ' N m)'
 CALL require(ef <= 1.0e-6_wp*fs, 'B ('//kind//'): End B forces of the line driven at End B equal the reversed line''s')
    CALL require(em_ <= 1.0e-6_wp*MAX(ms, 1.0_wp), 'B ('//kind//'): and the connection moments')
    CALL require(ms > 1.0e2_wp, 'B ('//kind//'): the turning parent loads its connection (a moment above 100 N m)')
    CALL CD_HFMF_End(c1)
    CALL CD_HFMF_End(c2)
  END SUBROUTINE check_bending_reversal

  SUBROUTINE write_cdeck(path, pa, ta, pb, tb, conn_a, conn_b)
    !! The suspended 100 m line of write_deck (no drag) with END CONNECTIONS (bending only).
    CHARACTER(*), INTENT(IN) :: path, ta, tb, conn_a, conn_b
    REAL(wp), INTENT(IN) :: pa(3), pb(3)
    INTEGER :: u
    OPEN (NEWUNIT=u, FILE=path, STATUS='REPLACE', ACTION='WRITE')
    WRITE (u, '(A)') 'two moving ends bending gate'
    WRITE (u, '(A)') '--- LINE TYPES ---'
    WRITE (u, '(A)') 'Name Diam Mass EA BA EI Cdn Cdt Can Cat'
    WRITE (u, '(A)') '(-) (m) (kg/m) (N) (-) (Nm2) (-) (-) (-) (-)'
    WRITE (u, '(A)') 'pcable 0.20 60 8.0e8 0.0 2.0e4 0.0 0.0 1.0 0.0'
    WRITE (u, '(A)') '--- POINTS ---'
    WRITE (u, '(A)') 'ID Type X Y Z Mass Vol CdA Ca'
    WRITE (u, '(A)') '(-) (-) (m) (m) (m) (kg) (m3) (m2) (-)'
    WRITE (u, '(A,3(1X,F8.3),A)') '1 '//ta, pa, ' 0 0 0 0'
    WRITE (u, '(A,3(1X,F8.3),A)') '2 '//tb, pb, ' 0 0 0 0'
    WRITE (u, '(A)') '--- LINES ---'
    WRITE (u, '(A)') 'ID NodeA NodeB Outputs'
    WRITE (u, '(A)') '(-) (-) (-) (-)'
    WRITE (u, '(A)') '1 1 2 -'
    WRITE (u, '(A)') '--- SECTIONS ---'
    WRITE (u, '(A)') 'LineID LineType Length NumSegs'
    WRITE (u, '(A)') '(-) (-) (m) (-)'
    WRITE (u, '(A)') '1 pcable 100.0 40'
    WRITE (u, '(A)') '--- END CONNECTIONS ---'
    WRITE (u, '(A)') 'LineID End Stiffness EzX EzY EzZ'
    WRITE (u, '(A)') '(-) (-) (N-m/rad) (-) (-) (-)'
    WRITE (u, '(A)') '1 A '//conn_a
    WRITE (u, '(A)') '1 B '//conn_b
    WRITE (u, '(A)') '--- OPTIONS ---'
    WRITE (u, '(A)') '9.80665 g'
    WRITE (u, '(A)') '1025.0 rhoW'
    WRITE (u, '(F6.3,A)') DT, ' dtM'
    WRITE (u, '(A)') '6.0 TMax'
    WRITE (u, '(A)') '--- OUTPUTS ---'
    WRITE (u, '(A)') 'FairTen1'
    WRITE (u, '(A)') '--- END ---'
    CLOSE (u)
  END SUBROUTINE write_cdeck

  SUBROUTINE drive_torsion(cab, s, es, em)
    !! Step s of the torsion restart march: End A rolls by 0.6 (1 - cos) rad and surges; End B's parent
    !! rolls the other way and heaves (both frames turning).
    TYPE(CD_HFMF_ModuleType), INTENT(INOUT) :: cab
    INTEGER, INTENT(IN) :: s
    INTEGER, INTENT(OUT) :: es
    CHARACTER(*), INTENT(OUT) :: em
    REAL(wp) :: t, x, v, a, r, rd, rdd
    t = REAL(s, wp)*0.02_wp
    CALL ramp(t, 0.5_wp, x, v, a)
    CALL ramp(t, 0.6_wp, r, rd, rdd)
    CALL CD_HFMF_UpdateStates(cab, [x, 0.0_wp, -50.0_wp], [v, 0.0_wp, 0.0_wp], [a, 0.0_wp, 0.0_wp], es, em, &
                              u_orientation=roll_x(r), u_angular_velocity=[rd, 0.0_wp, 0.0_wp], &
                              u_angular_acceleration=[rdd, 0.0_wp, 0.0_wp], &
                              ub_pos=[100.0_wp, 0.0_wp, -50.0_wp + x], ub_vel=[0.0_wp, 0.0_wp, v], &
                              ub_acc=[0.0_wp, 0.0_wp, a], ub_orientation=roll_x(-r), &
                              ub_angular_velocity=[-rd, 0.0_wp, 0.0_wp], ub_angular_acceleration=[-rdd, 0.0_wp, 0.0_wp])
  END SUBROUTINE drive_torsion

  SUBROUTINE check_torsion_restart()
    !! CT. The clamped, twisted straight line with a real polar inertia (Irn = 2 kg m, the nodal twist)
    !!     driven at both ends, both frames turning: snapshot restore and mirror rebuild at step 30 of 60
    !!     continue bit-identically (state, twist state and both end loads).
    INTEGER, PARAMETER :: NSPLIT = 30, NEND = 60
    TYPE(CD_HFMF_ModuleType), ALLOCATABLE :: cab, fresh
    REAL(wp), ALLOCATABLE :: buf(:), q_ref(:), v_ref(:), tw_ref(:)
    REAL(wp) :: fa_ref(3), fb_ref(3), ma_ref(3), mb_ref(3), fa(3), fb(3), ma(3), mb(3)
    INTEGER :: s, es, cn
    LOGICAL :: same_snap, same_mirror
    CHARACTER(1024) :: em
    CHARACTER(40) :: opt(2)
    ALLOCATE (cab, fresh)
    opt(1) = '0.02 dtM'
    opt(2) = '1.2 TMax'
    CALL write_tdeck('tme_ct.dat', [0.0_wp, 0.0_wp, -50.0_wp], 'Coupled', [100.0_wp, 0.0_wp, -50.0_wp], 'Coupled', &
                     'Rigid 1 0 0 Rigid 0 0 1 0', 'Rigid 1 0 0 Rigid 0 0 1 90', opt, 'FairTen1', 2.0_wp)
    CALL CD_Init_Deck_HermiteCable('tme_ct.dat', 0.02_wp, cab, cn, es, em, host_orientation=.TRUE., moving_end_b=.TRUE.)
    CALL require(es == CD_DECKDRV_OK, 'CT: cable builds: '//TRIM(em))
    IF (es /= CD_DECKDRV_OK) RETURN
    CALL require(cab%line%tw_active, 'CT: the cable carries the nodal twist')
    cab%line%tangent_reuse = .FALSE.
    cab%line%tr_valid = .FALSE.
    DO s = 1, NEND
      IF (s == NSPLIT + 1) THEN
        CALL CD_HFMF_Snapshot(cab, es, em)
        ALLOCATE (buf(CD_HFMF_MirrorSize(cab)))
        CALL CD_HFMF_PackMirror(cab, buf, es, em)
        CALL require(es == CD_HFMF_OK, 'CT: pack mirror: '//TRIM(em))
      END IF
      CALL drive_torsion(cab, s, es, em)
      CALL require(es == CD_HFMF_OK, 'CT: reference step: '//TRIM(em))
      IF (es /= CD_HFMF_OK) RETURN
    END DO
    q_ref = cab%line%q
    v_ref = cab%line%v
    tw_ref = cab%line%tw_phi
    CALL CD_HFMF_CalcOutput(cab, fa_ref, es, em, y_moment=ma_ref, y_end_b=fb_ref, y_moment_b=mb_ref)
    CALL CD_HFMF_Restore(cab, es, em)
    DO s = NSPLIT + 1, NEND
      CALL drive_torsion(cab, s, es, em)
      IF (es /= CD_HFMF_OK) EXIT
    END DO
    CALL CD_HFMF_CalcOutput(cab, fa, es, em, y_moment=ma, y_end_b=fb, y_moment_b=mb)
    same_snap = ALL(cab%line%q == q_ref) .AND. ALL(cab%line%v == v_ref) .AND. ALL(cab%line%tw_phi == tw_ref) .AND. &
                ALL(fa == fa_ref) .AND. ALL(fb == fb_ref) .AND. ALL(ma == ma_ref) .AND. ALL(mb == mb_ref)
    CALL CD_Init_Deck_HermiteCable('tme_ct.dat', 0.02_wp, fresh, cn, es, em, host_orientation=.TRUE., &
                                   moving_end_b=.TRUE.)
    fresh%line%tangent_reuse = .FALSE.
    fresh%line%tr_valid = .FALSE.
    CALL CD_HFMF_UnpackMirror(fresh, buf, REAL(NSPLIT, wp)*0.02_wp, es, em)
    CALL require(es == CD_HFMF_OK, 'CT: unpack mirror: '//TRIM(em))
    DO s = NSPLIT + 1, NEND
      CALL drive_torsion(fresh, s, es, em)
      IF (es /= CD_HFMF_OK) EXIT
    END DO
    CALL CD_HFMF_CalcOutput(fresh, fa, es, em, y_moment=ma, y_end_b=fb, y_moment_b=mb)
    same_mirror = ALL(fresh%line%q == q_ref) .AND. ALL(fresh%line%v == v_ref) .AND. ALL(fresh%line%tw_phi == tw_ref) &
                  .AND. ALL(fa == fa_ref) .AND. ALL(fb == fb_ref) .AND. ALL(ma == ma_ref) .AND. ALL(mb == mb_ref)
    WRITE (*, '(A,L1,A,L1,A,ES12.5,A)') 'restart with torsion, both frames turning: snapshot ', same_snap, &
      ', mirror rebuild ', same_mirror, ' (torque ', cab%line%torsion%torque, ' N m)'
    CALL require(same_snap, 'CT: snapshot restore continues bit-identically')
    CALL require(same_mirror, 'CT: mirror rebuild continues bit-identically')
    CALL CD_HFMF_End(cab)
    CALL CD_HFMF_End(fresh)
  END SUBROUTINE check_torsion_restart

  ! ------------------------------------------------------------------------------------------
  ! the coupled aggregate
  ! ------------------------------------------------------------------------------------------
  SUBROUTINE write_farm_deck(path, motion, tmax)
    !! The suspended line of write_deck shared by two turbines: TURBINES 1 at the origin and 2 at
    !! x = 80, the line between their fairleads (0, 0, -20) in turbine axes; motion a motionFile or
    !! blank.
    CHARACTER(*), INTENT(IN) :: path, motion
    REAL(wp), INTENT(IN) :: tmax
    INTEGER :: u
    OPEN (NEWUNIT=u, FILE=path, STATUS='REPLACE', ACTION='WRITE')
    WRITE (u, '(A)') 'two moving ends farm gate'
    WRITE (u, '(A)') '--- LINE TYPES ---'
    WRITE (u, '(A)') 'Name Diam Mass EA BA EI Cdn Cdt Can Cat'
    WRITE (u, '(A)') '(-) (m) (kg/m) (N) (-) (Nm2) (-) (-) (-) (-)'
    WRITE (u, '(A)') 'pcable 0.20 60 8.0e8 0.0 2.0e4 1.0 0.0 1.0 0.0'
    WRITE (u, '(A)') '--- TURBINES ---'
    WRITE (u, '(A)') 'J X0 Y0 Z0'
    WRITE (u, '(A)') '(-) (m) (m) (m)'
    WRITE (u, '(A)') '1 0 0 0'
    WRITE (u, '(A)') '2 80 0 0'
    WRITE (u, '(A)') '--- POINTS ---'
    WRITE (u, '(A)') 'ID Type X Y Z Mass Vol CdA Ca'
    WRITE (u, '(A)') '(-) (-) (m) (m) (m) (kg) (m3) (m2) (-)'
    WRITE (u, '(A)') '1 Turbine1 0 0 -20 0 0 0 0'
    WRITE (u, '(A)') '2 Turbine2 0 0 -20 0 0 0 0'
    WRITE (u, '(A)') '--- LINES ---'
    WRITE (u, '(A)') 'ID NodeA NodeB Outputs'
    WRITE (u, '(A)') '(-) (-) (-) (-)'
    WRITE (u, '(A)') '1 1 2 -'
    WRITE (u, '(A)') '--- SECTIONS ---'
    WRITE (u, '(A)') 'LineID LineType Length NumSegs'
    WRITE (u, '(A)') '(-) (-) (m) (-)'
    WRITE (u, '(A)') '1 pcable 100.0 40'
    WRITE (u, '(A)') '--- OPTIONS ---'
    WRITE (u, '(A)') '9.80665 g'
    WRITE (u, '(A)') '1025.0 rhoW'
    WRITE (u, '(F6.3,A)') DT, ' dtM'
    WRITE (u, '(F7.3,A)') tmax, ' TMax'
    IF (LEN_TRIM(motion) > 0) WRITE (u, '(A)') TRIM(motion)//' motionFile'
    WRITE (u, '(A)') '--- OUTPUTS ---'
    WRITE (u, '(A)') 'FairTen1 AnchTen1'
    WRITE (u, '(A)') '--- END ---'
    CLOSE (u)
  END SUBROUTINE write_farm_deck

  SUBROUTINE ramp0(t, amp, x, v, a)
    !! amp (1 - cos(w t))^2 / 4 with w = 2 pi / 8 s: from rest with zero acceleration at t = 0, so a
    !! host that starts from the static state (no first-row acceleration) sees the same motion.
    REAL(wp), INTENT(IN) :: t, amp
    REAL(wp), INTENT(OUT) :: x, v, a
    REAL(wp), PARAMETER :: W = 2.0_wp*PI/8.0_wp
    x = 0.25_wp*amp*(1.0_wp - COS(W*t))**2
    v = 0.5_wp*amp*W*(1.0_wp - COS(W*t))*SIN(W*t)
    a = 0.5_wp*amp*W*W*(SIN(W*t)**2 + (1.0_wp - COS(W*t))*COS(W*t))
  END SUBROUTINE ramp0

  SUBROUTINE turbine_motion(j, t, x, v, a)
    !! Prescribed rigid motion of turbine j (no rotation): turbine 1 surges 2 m, turbine 2 sways
    !! 1.5 m and heaves 1 m, each from rest (ramp0); x is the turbine reference point.
    INTEGER, INTENT(IN) :: j
    REAL(wp), INTENT(IN) :: t
    REAL(wp), INTENT(OUT) :: x(3), v(3), a(3)
    REAL(wp) :: s, sv, sa, h, hv, ha
    x = 0.0_wp; v = 0.0_wp; a = 0.0_wp
    IF (j == 1) THEN
      CALL ramp0(t, 2.0_wp, s, sv, sa)
      x(1) = s; v(1) = sv; a(1) = sa
    ELSE
      CALL ramp0(t, 1.5_wp, s, sv, sa)
      CALL ramp0(t, 1.0_wp, h, hv, ha)
      x = [SPAN, s, h]; v = [0.0_wp, sv, hv]; a = [0.0_wp, sa, ha]
    END IF
  END SUBROUTINE turbine_motion

  SUBROUTINE check_farm_shared_line()
    !! F. The standalone TURBINES deck (motionFile turbine rows) and the FAST.Farm aggregate (n_turbines
    !!    = 2, the same reference positions) of one shared line, driven by the same turbine motions.
    !!    The aggregate maps its two moving columns to turbines 1 and 2; FairTen and AnchTen agree to
    !!    the solver tolerances (the standalone route solves its statics to 1e-8 and the aggregate's
    !!    to 1e-6; both step to 1e-8 here) at every step.
    INTEGER, PARAMETER :: NSTEP = 160, NCOL = 3
    TYPE(CD_AGG_ModuleType), ALLOCATABLE :: agg
    REAL(wp) :: rows(NCOL, NSTEP + 1), pos(3, 2), vel(3, 2), acc(3, 2), x(3), v(3), a(3), t, fa, fb, err, scale
    INTEGER :: u, k, j, n, es, nit, turb(2)
    LOGICAL :: ok, conv, stalled
    CHARACTER(1024) :: em
    OPEN (NEWUNIT=u, FILE='tme_farm.txt', STATUS='REPLACE', ACTION='WRITE')
    DO k = 0, NSTEP
      t = REAL(k, wp)*DT
      DO j = 1, 2
        CALL turbine_motion(j, t, x, v, a)
        WRITE (u, '(F10.5,1X,I0,3(1X,ES24.16),A,3(1X,ES24.16),A,3(1X,ES24.16),A)') t, j, x, ' 1 0 0 0', v, &
          ' 0 0 0', a, ' 0 0 0'
      END DO
    END DO
    CLOSE (u)
    CALL write_farm_deck('tme_farm_sa.dat', 'tme_farm.txt', NSTEP*DT)
    CALL run_deck('tme_farm_sa.dat', 'tme_farm_sa', ok, em)
    CALL require(ok, 'F: the standalone TURBINES deck runs: '//TRIM(em))
    CALL read_rows('tme_farm_sa.out', rows, n, ok)
    CALL require(ok .AND. n == NSTEP + 1, 'F: standalone output readable')
    IF (.NOT. ok) RETURN
    ALLOCATE (agg)
    CALL write_farm_deck('tme_farm_agg.dat', '', NSTEP*DT)
    CALL CD_AGG_Init_From_Deck(agg, 'tme_farm_agg.dat', DT, es, em, n_turbines=2, &
                               turbine_ref_pos=RESHAPE([0.0_wp, 0.0_wp, 0.0_wp, SPAN, 0.0_wp, 0.0_wp], [3, 2]), &
                               forbid_deck_ambient=.TRUE.)
    CALL require(es == CD_AGG_OK, 'F: the FAST.Farm aggregate builds the shared line: '//TRIM(em))
    IF (es /= CD_AGG_OK) RETURN
    CALL require(CD_AGG_NMovingPoints(agg, es, em) == 2, 'F: two moving columns, one per end')
    CALL CD_AGG_TurbineOfMoving(agg, turb, es, em)
    CALL require(es == CD_AGG_OK .AND. turb(1) == 1 .AND. turb(2) == 2, &
                 'F: End A is driven by turbine 1 and End B by turbine 2')
    agg%cables(1)%tol = 1.0e-8_wp
    agg%cables(1)%max_iter = 30
    err = 0.0_wp
    scale = MAXVAL(ABS(rows(2:3, 1:n)))
    DO k = 0, NSTEP
      IF (k > 0) THEN
        t = REAL(k, wp)*DT
        DO j = 1, 2
          CALL turbine_motion(j, t, x, v, a)
          pos(:, j) = x + [0.0_wp, 0.0_wp, ZE]
          vel(:, j) = v
          acc(:, j) = a
        END DO
        CALL CD_AGG_Step_Moving(agg, DT, pos, vel, acc, conv, stalled, nit, es, em, t_committed=t)
        CALL require(es == CD_AGG_OK, 'F: aggregate step: '//TRIM(em))
        IF (es /= CD_AGG_OK) EXIT
      END IF
      CALL CD_AGG_EvalChannel(agg, 1, fa, es, em)
      CALL CD_AGG_EvalChannel(agg, 2, fb, es, em)
      IF (k == 0) WRITE (*, '(A,2ES16.8,A,2ES16.8)') '  static FairTen, AnchTen: aggregate ', fa, fb, &
        ' standalone ', rows(2:3, 1)
      err = nan_max_abs([err, ABS(fa - rows(2, k + 1)), ABS(fb - rows(3, k + 1))])
    END DO
    WRITE (*, '(A,ES10.3,A,ES10.3,A)') 'FAST.Farm shared line: aggregate vs standalone end tensions ', err, &
      ' N (of ', scale, ' N)'
    CALL require(err <= 1.0e-6_wp*scale, 'F: the aggregate reports the standalone route''s end tensions')
    CALL CD_AGG_End(agg, es, em)
  END SUBROUTINE check_farm_shared_line

  SUBROUTINE check_aggregate_torsion()
    !! FT. The clamped line twisted 90 deg between two Coupled points of the aggregate (host
    !!     orientations): the host rolls column 1 by +phi and column 2 by -phi about the line (End B
    !!     frame against End A's: the twist falls by 2 phi), or both by +phi (a rigid roll).
    INTEGER, PARAMETER :: NSTEP = 10
    REAL(wp), PARAMETER :: GJ = 5.0e4_wp, L = 100.0_wp, PHI_MAX = 30.0_wp
    TYPE(CD_AGG_ModuleType), ALLOCATABLE :: agg
    REAL(wp) :: pos(3, 2), zero3(3, 2), ori(3, 3, 2), phi, m0, mt, err(2)
    INTEGER :: k, es, nit, isame
    LOGICAL :: conv, stalled
    CHARACTER(1024) :: em
    CHARACTER(40) :: opt(2)
    opt(1) = '0.05 dtM'
    opt(2) = '0.5 TMax'
    CALL write_tdeck('tme_aggt.dat', [0.0_wp, 0.0_wp, -50.0_wp], 'Coupled', [100.0_wp, 0.0_wp, -50.0_wp], 'Coupled', &
                     'Rigid 1 0 0 Rigid 0 0 1 0', 'Rigid 1 0 0 Rigid 0 0 1 90', opt, 'Torq1N1', 1.0e-12_wp)
    pos(:, 1) = [0.0_wp, 0.0_wp, -50.0_wp]
    pos(:, 2) = [100.0_wp, 0.0_wp, -50.0_wp]
    zero3 = 0.0_wp
    err = 0.0_wp
    DO isame = 1, 2
      ALLOCATE (agg)
      CALL CD_AGG_Init_From_Deck(agg, 'tme_aggt.dat', 0.05_wp, es, em, host_orientation=.TRUE.)
      CALL require(es == CD_AGG_OK, 'FT: the aggregate builds the twisted line: '//TRIM(em))
      IF (es /= CD_AGG_OK) RETURN
      m0 = agg%cables(1)%line%torsion%torque
      DO k = 1, NSTEP
        phi = PHI_MAX*REAL(k, wp)/REAL(NSTEP, wp)*PI/180.0_wp
        ori(:, :, 1) = roll_x(phi)
        ori(:, :, 2) = roll_x(MERGE(phi, -phi, isame == 2))
        CALL CD_AGG_Step_Moving(agg, 0.05_wp, pos, zero3, zero3, conv, stalled, nit, es, em, &
                                t_committed=0.05_wp*k, orientation=ori, angular_velocity=zero3, &
                                angular_acceleration=zero3)
        CALL require(es == CD_AGG_OK, 'FT: aggregate step: '//TRIM(em))
        IF (es /= CD_AGG_OK) EXIT
        mt = agg%cables(1)%line%torsion%torque
        IF (isame == 1) THEN
          err(1) = nan_max_abs([err(1), ABS((mt - m0) + GJ*2.0_wp*phi/L)])
        ELSE
          err(2) = nan_max_abs([err(2), ABS(mt - m0)])
        END IF
      END DO
      CALL CD_AGG_End(agg, es, em)
      DEALLOCATE (agg)
    END DO
    WRITE (*, '(A,ES10.3,A,ES10.3,A,ES12.5,A)') 'aggregate host rolls: opposite error ', err(1), ' N m, same error ', &
      err(2), ' N m (torque ', m0, ' N m)'
    CALL require(err(1) <= 1.0e-6_wp*GJ, 'FT: opposite host rolls change the torque by GJ (2 phi) / L')
    CALL require(err(2) <= 1.0e-6_wp*GJ, 'FT: equal host rolls keep the torque')
  END SUBROUTINE check_aggregate_torsion

  SUBROUTINE write_farm_tdeck(path, ptfm, motion, tmax)
    !! The clamped straight torsion line of write_tdeck between two turbines 100 m apart, End A on
    !! Turbine1 and End B on Turbine2 at (0, 0, -50) in turbine axes; ptfm: write the TURBINES PtfmInit
    !! columns (turbine 1 yawed +15 deg, turbine 2 -8 deg).
    CHARACTER(*), INTENT(IN) :: path, motion
    LOGICAL, INTENT(IN) :: ptfm
    REAL(wp), INTENT(IN) :: tmax
    INTEGER :: u
    OPEN (NEWUNIT=u, FILE=path, STATUS='REPLACE', ACTION='WRITE')
    WRITE (u, '(A)') 'two moving ends farm torsion gate'
    WRITE (u, '(A)') '--- LINE TYPES ---'
    WRITE (u, '(A)') 'Name Diam Mass EA BA EI GAs GJ Irt Irn Cdn Cdt Can Cat'
    WRITE (u, '(A)') '(-) (m) (kg/m) (N) (Nm2) (N) (Nm2) (kgm) (kgm) (-) (-) (-) (-)'
    WRITE (u, '(A,ES24.16,A)') 'cab 0.2 ', 1025.0_wp*0.25_wp*PI*0.04_wp, &
      ' 1.0e7 0.0 1.0e6 1.0e8 5.0e4 1.0 1.0e-12 0.0 0.0 0.0 0.0'
    WRITE (u, '(A)') '--- TURBINES ---'
    IF (ptfm) THEN
      WRITE (u, '(A)') 'J X0 Y0 Z0 PtfmSurge PtfmSway PtfmHeave PtfmRoll PtfmPitch PtfmYaw'
      WRITE (u, '(A)') '1 0 0 0 0 0 0 0 0 15'
      WRITE (u, '(A)') '2 100 0 0 0 0 0 0 0 -8'
    ELSE
      WRITE (u, '(A)') 'J X0 Y0 Z0'
      WRITE (u, '(A)') '1 0 0 0'
      WRITE (u, '(A)') '2 100 0 0'
    END IF
    WRITE (u, '(A)') '--- POINTS ---'
    WRITE (u, '(A)') 'ID Type X Y Z Mass Vol CdA Ca'
    WRITE (u, '(A)') '(-) (-) (m) (m) (m) (kg) (m3) (m2) (-)'
    WRITE (u, '(A)') '1 Turbine1 0 0 -50 0 0 0 0'
    WRITE (u, '(A)') '2 Turbine2 0 0 -50 0 0 0 0'
    WRITE (u, '(A)') '--- LINES ---'
    WRITE (u, '(A)') 'ID NodeA NodeB Outputs'
    WRITE (u, '(A)') '(-) (-) (-) (-)'
    WRITE (u, '(A)') '1 1 2 -'
    WRITE (u, '(A)') '--- SECTIONS ---'
    WRITE (u, '(A)') 'LineID LineType Length NumSegs'
    WRITE (u, '(A)') '(-) (-) (m) (-)'
    WRITE (u, '(A)') '1 cab 100.0 40'
    WRITE (u, '(A)') '--- END CONNECTIONS ---'
    WRITE (u, '(A)') 'LineID End Stiffness EzX EzY EzZ TorsStiffness NxX NxY NxZ Pretwist'
    WRITE (u, '(A)') '(-) (-) (N-m/rad) (-) (-) (-) (N-m/rad) (-) (-) (-) (deg)'
    WRITE (u, '(A)') '1 A Rigid 1 0 0 Rigid 0 0 1 0'
    WRITE (u, '(A)') '1 B Rigid 1 0 0 Rigid 0 0 1 90'
    WRITE (u, '(A)') '--- OPTIONS ---'
    WRITE (u, '(A)') '9.80665 g'
    WRITE (u, '(A)') '1025.0 rhoW'
    WRITE (u, '(A)') '0.05 dtM'
    WRITE (u, '(F7.3,A)') tmax, ' TMax'
    IF (LEN_TRIM(motion) > 0) WRITE (u, '(A)') TRIM(motion)//' motionFile'
    WRITE (u, '(A)') '--- OUTPUTS ---'
    WRITE (u, '(A)') 'FairTen1 AnchTen1 Torq1N1 Torq1N41 Curv1N2 Curv1N40'
    WRITE (u, '(A)') '--- END ---'
    CLOSE (u)
  END SUBROUTINE write_farm_tdeck

  SUBROUTINE check_farm_ptfm_parity()
    !! FP. Turbines yawed by PtfmInit (+15 and -8 deg about their reference points, which carry the
    !!     fairleads on their z axes, so the ends do not move but their frames turn): the clamped line,
    !!     twisted 90 deg, is bent at both ends by the turned Ez and twisted by the turned Nx. The
    !!     standalone run (held, 10 steps) and the FAST.Farm aggregate (farm_ptfm_init, the host
    !!     passing each turbine's orientation) agree in every channel at every step.
    INTEGER, PARAMETER :: NSTEP = 10, NCOL = 7
    REAL(wp) :: rows(NCOL, NSTEP + 1), pos(3, 2), zero3(3, 2), ori(3, 3, 2), v, err, scale, yaw(2)
    TYPE(CD_AGG_ModuleType), ALLOCATABLE :: agg
    INTEGER :: n, k, ic, es, nit
    LOGICAL :: ok, conv, stalled
    CHARACTER(1024) :: em
    CALL write_farm_tdeck('tme_fp_sa.dat', .TRUE., '', NSTEP*0.05_wp)
    CALL run_deck('tme_fp_sa.dat', 'tme_fp_sa', ok, em)
    CALL require(ok, 'FP: the standalone TURBINES torsion deck runs: '//TRIM(em))
    CALL read_rows('tme_fp_sa.out', rows, n, ok)
    CALL require(ok .AND. n == NSTEP + 1, 'FP: standalone output readable')
    IF (.NOT. ok) RETURN
    yaw = [15.0_wp, -8.0_wp]*PI/180.0_wp
    ALLOCATE (agg)
    CALL write_farm_tdeck('tme_fp_agg.dat', .FALSE., '', NSTEP*0.05_wp)
    CALL CD_AGG_Init_From_Deck(agg, 'tme_fp_agg.dat', 0.05_wp, es, em, n_turbines=2, &
                               turbine_ref_pos=RESHAPE([0.0_wp, 0.0_wp, 0.0_wp, 100.0_wp, 0.0_wp, 0.0_wp], [3, 2]), &
                               farm_ptfm_init=RESHAPE([0.0_wp, 0.0_wp, 0.0_wp, 0.0_wp, 0.0_wp, yaw(1), &
                                                       0.0_wp, 0.0_wp, 0.0_wp, 0.0_wp, 0.0_wp, yaw(2)], [6, 2]), &
                               forbid_deck_ambient=.TRUE., host_orientation=.TRUE.)
    CALL require(es == CD_AGG_OK, 'FP: the FAST.Farm aggregate builds: '//TRIM(em))
    IF (es /= CD_AGG_OK) RETURN
    agg%cables(1)%tol = 1.0e-8_wp
    agg%cables(1)%max_iter = 30
    pos(:, 1) = [0.0_wp, 0.0_wp, -50.0_wp]
    pos(:, 2) = [100.0_wp, 0.0_wp, -50.0_wp]
    zero3 = 0.0_wp
    DO k = 1, 2
      ori(:, :, k) = RESHAPE([COS(yaw(k)), -SIN(yaw(k)), 0.0_wp, SIN(yaw(k)), COS(yaw(k)), 0.0_wp, &
                              0.0_wp, 0.0_wp, 1.0_wp], [3, 3])
    END DO
    err = 0.0_wp
    scale = 0.0_wp
    DO k = 0, NSTEP
      IF (k > 0) THEN
        CALL CD_AGG_Step_Moving(agg, 0.05_wp, pos, zero3, zero3, conv, stalled, nit, es, em, t_committed=0.05_wp*k, &
                                orientation=ori, angular_velocity=zero3, angular_acceleration=zero3)
        CALL require(es == CD_AGG_OK, 'FP: aggregate step: '//TRIM(em))
        IF (es /= CD_AGG_OK) EXIT
      END IF
      DO ic = 1, NCOL - 1
        CALL CD_AGG_EvalChannel(agg, ic, v, es, em)
        err = nan_max_abs([err, ABS(v - rows(ic + 1, k + 1))/MAX(1.0_wp, ABS(rows(ic + 1, k + 1)))])
        scale = MAX(scale, ABS(rows(ic + 1, k + 1)))
      END DO
    END DO
    WRITE (*, '(A,ES10.3,A,4ES12.4)') 'FAST.Farm vs standalone, yawed turbines, torsion: largest relative channel '// &
      'difference ', err, '; standalone t = 0: FairTen, AnchTen, Torq ', rows(2:4, 1), rows(6, 1)
    CALL require(err <= 1.0e-5_wp, 'FP: the standalone TURBINES deck reads its end frames in the turbines'' axes')
    CALL CD_AGG_End(agg, es, em)
  END SUBROUTINE check_farm_ptfm_parity

  SUBROUTINE turbine_pose(j, t, x, v, a, r, w, al)
    !! Turbine j of FR: reference (0, 0, 0) or (100, 0, 0), rotation R = Rz(yaw_j) Rx(+-phi(t)) with
    !! yaw +15 / -8 deg (the PtfmInit) and phi a 10 deg roll over 1 s from rest with zero initial
    !! acceleration (as a host starting from the static state sees it); x, v, a the motion
    !! of the fairlead (0, 0, -50) in turbine axes, r the rotation, w and al its global angular
    !! velocity and acceleration (w = phi' Rz e_x).
    INTEGER, INTENT(IN) :: j
    REAL(wp), INTENT(IN) :: t
    REAL(wp), INTENT(OUT) :: x(3), v(3), a(3), r(3, 3), w(3), al(3)
    REAL(wp) :: yaw, sg, phi, pd, pdd, rz(3, 3), rx(3, 3), p(3), ax(3)
    REAL(wp), PARAMETER :: WR = PI
    yaw = MERGE(15.0_wp, -8.0_wp, j == 1)*PI/180.0_wp
    sg = MERGE(1.0_wp, -1.0_wp, j == 1)
    ! 10 deg (1 - cos)^2 / 4 with w = pi: phi(1 s) = 10 deg, phi'(0) = phi''(0) = 0
    phi = sg*0.25_wp*(10.0_wp*PI/180.0_wp)*(1.0_wp - COS(WR*t))**2
    pd = sg*0.5_wp*(10.0_wp*PI/180.0_wp)*WR*(1.0_wp - COS(WR*t))*SIN(WR*t)
    pdd = sg*0.5_wp*(10.0_wp*PI/180.0_wp)*WR*WR*(SIN(WR*t)**2 + (1.0_wp - COS(WR*t))*COS(WR*t))
    rz = RESHAPE([COS(yaw), SIN(yaw), 0.0_wp, -SIN(yaw), COS(yaw), 0.0_wp, 0.0_wp, 0.0_wp, 1.0_wp], [3, 3])
    rx = RESHAPE([1.0_wp, 0.0_wp, 0.0_wp, 0.0_wp, COS(phi), SIN(phi), 0.0_wp, -SIN(phi), COS(phi)], [3, 3])
    r = MATMUL(rz, rx)
    ax = [COS(yaw), SIN(yaw), 0.0_wp]
    w = pd*ax
    al = pdd*ax
    p = MATMUL(r, [0.0_wp, 0.0_wp, -50.0_wp])
    x = MERGE(0.0_wp, 100.0_wp, j == 1)*[1.0_wp, 0.0_wp, 0.0_wp] + p
    v = [w(2)*p(3) - w(3)*p(2), w(3)*p(1) - w(1)*p(3), w(1)*p(2) - w(2)*p(1)]
    a = [al(2)*p(3) - al(3)*p(2), al(3)*p(1) - al(1)*p(3), al(1)*p(2) - al(2)*p(1)] + &
        [w(2)*v(3) - w(3)*v(2), w(3)*v(1) - w(1)*v(3), w(1)*v(2) - w(2)*v(1)]
  END SUBROUTINE turbine_pose

  SUBROUTINE check_farm_rotation_parity()
    !! FR. The turbines of FP roll their fairleads by +-10 deg about their (yawed) x axes: the TURBINES
    !!     rows give each turbine's quaternion, which turns its end's connection and torsion frames;
    !!     the FAST.Farm aggregate takes the same rotations as host orientations. Every channel
    !!     agrees at every step, and the twist changes (the two frames turn oppositely).
    INTEGER, PARAMETER :: NSTEP = 20, NCOL = 7
    REAL(wp) :: rows(NCOL, NSTEP + 1), pos(3, 2), vel(3, 2), acc(3, 2), ori(3, 3, 2), om(3, 2), al(3, 2)
    REAL(wp) :: x(3), v(3), a(3), r(3, 3), w(3), aa(3), tt, val, err, yaw(2), q(4), trq0
    TYPE(CD_AGG_ModuleType), ALLOCATABLE :: agg
    INTEGER :: n, k, j, ic, es, nit, u
    LOGICAL :: ok, conv, stalled
    CHARACTER(1024) :: em
    OPEN (NEWUNIT=u, FILE='tme_fr.txt', STATUS='REPLACE', ACTION='WRITE')
    DO k = 0, NSTEP
      tt = REAL(k, wp)*0.05_wp
      DO j = 1, 2
        CALL turbine_pose(j, tt, x, v, a, r, w, aa)
        ! the row's quaternion of R = Rz(yaw) Rx(phi)
        q = rot_quaternion(r)
        WRITE (u, '(F10.5,1X,I0,3(1X,ES24.16),4(1X,ES24.16),12(1X,ES24.16))') tt, j, &
          MERGE(0.0_wp, 100.0_wp, j == 1), 0.0_wp, 0.0_wp, q, 0.0_wp, 0.0_wp, 0.0_wp, w, 0.0_wp, 0.0_wp, 0.0_wp, aa
      END DO
    END DO
    CLOSE (u)
    CALL write_farm_tdeck('tme_fr_sa.dat', .TRUE., 'tme_fr.txt', NSTEP*0.05_wp)
    CALL run_deck('tme_fr_sa.dat', 'tme_fr_sa', ok, em)
    CALL require(ok, 'FR: the rolling TURBINES deck runs: '//TRIM(em))
    CALL read_rows('tme_fr_sa.out', rows, n, ok)
    CALL require(ok .AND. n == NSTEP + 1, 'FR: standalone output readable')
    IF (.NOT. ok) RETURN
    yaw = [15.0_wp, -8.0_wp]*PI/180.0_wp
    ALLOCATE (agg)
    CALL write_farm_tdeck('tme_fr_agg.dat', .FALSE., '', NSTEP*0.05_wp)
    CALL CD_AGG_Init_From_Deck(agg, 'tme_fr_agg.dat', 0.05_wp, es, em, n_turbines=2, &
                               turbine_ref_pos=RESHAPE([0.0_wp, 0.0_wp, 0.0_wp, 100.0_wp, 0.0_wp, 0.0_wp], [3, 2]), &
                               farm_ptfm_init=RESHAPE([0.0_wp, 0.0_wp, 0.0_wp, 0.0_wp, 0.0_wp, yaw(1), &
                                                       0.0_wp, 0.0_wp, 0.0_wp, 0.0_wp, 0.0_wp, yaw(2)], [6, 2]), &
                               forbid_deck_ambient=.TRUE., host_orientation=.TRUE.)
    CALL require(es == CD_AGG_OK, 'FR: the FAST.Farm aggregate builds: '//TRIM(em))
    IF (es /= CD_AGG_OK) RETURN
    agg%cables(1)%tol = 1.0e-8_wp
    agg%cables(1)%max_iter = 30
    err = 0.0_wp
    trq0 = rows(4, 1)
    DO k = 0, NSTEP
      IF (k > 0) THEN
        tt = REAL(k, wp)*0.05_wp
        DO j = 1, 2
          CALL turbine_pose(j, tt, pos(:, j), vel(:, j), acc(:, j), r, om(:, j), al(:, j))
          ori(:, :, j) = TRANSPOSE(r)
        END DO
        CALL CD_AGG_Step_Moving(agg, 0.05_wp, pos, vel, acc, conv, stalled, nit, es, em, t_committed=tt, &
                                orientation=ori, angular_velocity=om, angular_acceleration=al)
        CALL require(es == CD_AGG_OK, 'FR: aggregate step: '//TRIM(em))
        IF (es /= CD_AGG_OK) EXIT
      END IF
      DO ic = 1, NCOL - 1
        CALL CD_AGG_EvalChannel(agg, ic, val, es, em)
        err = nan_max_abs([err, ABS(val - rows(ic + 1, k + 1))/MAX(1.0_wp, ABS(rows(ic + 1, k + 1)))])
      END DO
    END DO
    WRITE (*, '(A,ES10.3,A,ES12.5,A,ES12.5,A)') 'FAST.Farm vs standalone, rolling turbines: largest relative '// &
      'channel difference ', err, '; Torq1N1 ', trq0, ' -> ', rows(4, n), ' N m'
    CALL require(err <= 1.0e-5_wp, 'FR: TURBINES rows turn both end frames as the FAST.Farm host does')
    CALL require(ABS(rows(4, n) - trq0) > 1.0e-2_wp*ABS(trq0), 'FR: the turbines'' rolls twist the line')
    CALL CD_AGG_End(agg, es, em)
  END SUBROUTINE check_farm_rotation_parity

  FUNCTION rot_quaternion(r) RESULT(q)
    !! Unit quaternion (q0, q1, q2, q3) of a proper rotation matrix (Shepperd's method, q0 >= 0).
    REAL(wp), INTENT(IN) :: r(3, 3)
    REAL(wp) :: q(4), tr, s
    tr = r(1, 1) + r(2, 2) + r(3, 3)
    IF (tr > 0.0_wp) THEN
      s = 0.5_wp/SQRT(tr + 1.0_wp)
      q = [0.25_wp/s, (r(3, 2) - r(2, 3))*s, (r(1, 3) - r(3, 1))*s, (r(2, 1) - r(1, 2))*s]
    ELSE IF (r(1, 1) > r(2, 2) .AND. r(1, 1) > r(3, 3)) THEN
      s = 2.0_wp*SQRT(1.0_wp + r(1, 1) - r(2, 2) - r(3, 3))
      q = [(r(3, 2) - r(2, 3))/s, 0.25_wp*s, (r(1, 2) + r(2, 1))/s, (r(1, 3) + r(3, 1))/s]
    ELSE IF (r(2, 2) > r(3, 3)) THEN
      s = 2.0_wp*SQRT(1.0_wp + r(2, 2) - r(1, 1) - r(3, 3))
      q = [(r(1, 3) - r(3, 1))/s, (r(1, 2) + r(2, 1))/s, 0.25_wp*s, (r(2, 3) + r(3, 2))/s]
    ELSE
      s = 2.0_wp*SQRT(1.0_wp + r(3, 3) - r(1, 1) - r(2, 2))
      q = [(r(2, 1) - r(1, 2))/s, (r(1, 3) + r(3, 1))/s, (r(2, 3) + r(3, 2))/s, 0.25_wp*s]
    END IF
    IF (q(1) < 0.0_wp) q = -q
  END FUNCTION rot_quaternion

END PROGRAM test_two_moving_ends
