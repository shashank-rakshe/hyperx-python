! File: tests/test_openfast_pinned_body.f90
! SPDX-License-Identifier: Apache-2.0
! Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
PROGRAM test_openfast_pinned_body
  !! CoupledPinned/VesselPinned BODIES on the OpenFAST CompMooring = 5 aggregate (MoorDyn-F's coupled
  !! pinned body: the host prescribes the translation of the body reference point and takes its
  !! force; the body's rotation about it is integrated). Gates:
  !!   1) a dry compound pendulum (CG 2 m below the node, a line attached at the node) whose node is
  !!      held swings with the period of the complete elliptic integral (1e-3 at dt = T/100), its
  !!      reference point stays on the node, the node moment is zero and the node force is the
  !!      analytic pin reaction plus the line force at the node (1e-10 of m g);
  !!   2) under a constant node acceleration a it swings about -atan(a/g) with the period of the
  !!      effective gravity sqrt(g^2 + a^2);
  !!   3) a second route: a body with the mass, CG and inertia of a CoupledPinned ROD, carrying the
  !!      rod's End B line at the same arm, follows the rod (axis, angular velocity and node force)
  !!      under a harmonic node surge to 1e-9;
  !!   4) a body on four symmetric lines whose node heaves does not turn (|omega| <= 1e-12 rad/s)
  !!      and its node force is the sum of the line forces plus weight, buoyancy and the
  !!      translational inertia (m + rhoW V Ca) a (1e-10);
  !!   5) an output probe returns -m (I_cg/I_p) a_p for a node acceleration a_p (the re-solved
  !!      rotation) besides the change of the line force at the node, with zero moment;
  !!   6) snapshot / step / restore / step is bit-identical, a probe restored as the shell
  !!      restores it leaves the march bit-identical, and a fresh instance overlaid with the
  !!      checkpoint state returns the same loads before the next step and continues bit for bit;
  !!   7) PtfmInit moves the node and turns the body with the platform, and the static initial
  !!      condition balances the moment about the node (1e-6);
  !!   8) a body held by stiff tethers sub-cycles a coarse coupling step it could not take
  !!      explicitly and matches a run at the sub-step size; the node orientation and angular
  !!      rates are ignored;
  !!   9) beside a Coupled body (a 6-DOF host node, deck BODY order) the pinned body keeps its own
  !!      motion: the same as alone to 1e-12;
  !!  10) the OpenFAST shell's order (a state-mirror restore after the output call at t = 0, before
  !!      the first step) starts every integrated object from its solved start acceleration: the
  !!      pinned body (line at the node, and at an arm), a Free Rigid6 body, and Free, Pinned and
  !!      CoupledPinned rods march bit for bit as without the restore;
  !!  11) a CoupledPinned body outside a coupled host, without inertia, or under the linearisation
  !!      probe (coupled_positions) is refused by name, and so is MoorDyn-F's inertialF 0 (CableDyn
  !!      always returns the inertia; inertialF 1 is accepted);
  !!  12) in a host fluid field (a current and a fluid acceleration at every node) a Free Rigid6 body
  !!      and a Free rod start from their accelerations in that field: after CD_AGG_SetFluidFields
  !!      the body's start acceleration differs from the still-water one by the drag over the
  !!      effective mass, 0.5 rhoW CdA |U| U / (m + rhoW V Ca) (1e-5: the lines' end-node mass is
  !!      left out), and the first steps of
  !!      SetFluidFields then Step, of the shell's order (the t = 0 field at Init, the output call
  !!      and its mirror restore, the field again before the step) and of a correction rewind to
  !!      before the first step are those of a run whose start accelerations are solved in the
  !!      field at a step-start transfer, bit for bit, and differ from the still-water start.
  USE CableDyn_Precision, ONLY: wp
  USE CableDyn_DeckDriver, ONLY: CD_Run_Deck_Driver, CD_DECKDRV_OK
  USE CableDyn_OpenFAST_Aggregate, ONLY: CD_AGG_ModuleType, CD_AGG_Init_From_Deck, CD_AGG_NMovingPoints, &
                                         CD_AGG_GetMovingPointMesh, CD_AGG_UpdateStates_Moving, &
                                         CD_AGG_Step_Moving, CD_AGG_CalcOutput, CD_AGG_Snapshot, CD_AGG_Restore, &
                                         CD_AGG_End, CD_AGG_OK, CD_AGG_HasRigid6, CD_AGG_HasRod, &
                                         CD_AGG_Rigid6_MirrorSize, CD_AGG_Get_Rigid6_States, &
                                         CD_AGG_Set_Rigid6_States, CD_AGG_Rod_MirrorSize, CD_AGG_Get_Rod_States, &
                                         CD_AGG_Set_Rod_States, CD_AGG_NFluidNodes, CD_AGG_SetFluidFields
  USE CableDyn_System, ONLY: CD_System_NLines, CD_System_Line_NDOF, CD_Get_System_Line_State, &
                             CD_Update_System_Line_Interior_State, CD_SYSTEM_OK, CD_System_NSystemCoupledDOF, &
                             CD_Get_System_CoupledMotion, CD_Update_System_CoupledMotion, CD_Calc_System_CoupledLoads
  USE, INTRINSIC :: IEEE_ARITHMETIC, ONLY: IEEE_IS_FINITE
  IMPLICIT NONE
  REAL(wp), PARAMETER :: PI = 3.141592653589793_wp, G = 9.80665_wp, RHO = 1025.0_wp
  ! the dry compound pendulum: mass MB, CG HCG below the node at z = ZPIN, Iyy about the CG
  REAL(wp), PARAMETER :: MB = 1000.0_wp, HCG = 2.0_wp, IYY = 500.0_wp, ZPIN = 20.0_wp
  ! the arm of the second route: a 4 m rod, 0.3 m diameter, 75 kg/m, pinned at z = 5 m, 20 deg
  REAL(wp), PARAMETER :: LA = 4.0_wp, DA = 0.3_wp, MA = 300.0_wp, ZA = 5.0_wp, THA = 20.0_wp
  ! the Free body of gate 12: mass, volume, CdA and Ca
  REAL(wp), PARAMETER :: FB_M = 5000.0_wp, FB_V = 4.0_wp, FB_CDA = 6.0_wp, FB_CA = 0.8_wp
  ! gate 12's host field (a current and a fluid acceleration), coupling step and step count
  REAL(wp), PARAMETER :: FS_U(3) = [0.8_wp, 0.3_wp, 0.0_wp], FS_A(3) = [0.2_wp, 0.0_wp, 0.1_wp], FS_DT = 0.01_wp
  INTEGER, PARAMETER :: FS_NSTEP = 5
  INTEGER :: nfail

  nfail = 0
  CALL case_pendulum_held()
  CALL case_constant_acceleration()
  CALL case_rod_second_route()
  CALL case_symmetric_heave()
  CALL case_probe()
  CALL case_state()
  CALL case_ptfm_static()
  CALL case_substep()
  CALL case_mixed_hosts()
  CALL case_shell_start()
  CALL case_refusals()
  CALL case_fluid_start('pinbody_fluid_body.dat', .FALSE.)
  CALL case_fluid_start('pinbody_fluid_rod.dat', .TRUE.)
  IF (nfail > 0) THEN
    WRITE (*, '(A,I0,A)') 'FAIL: ', nfail, ' assertion(s) failed'
    ERROR STOP 1
  END IF
  WRITE (*, '(A)') 'PASS: CoupledPinned bodies on the coupled aggregate'

CONTAINS

  INCLUDE 'nan_max_abs.inc'

  SUBROUTINE require(cond, msg)
    LOGICAL, INTENT(IN) :: cond
    CHARACTER(*), INTENT(IN) :: msg
    IF (.NOT. cond) THEN
      WRITE (*, '(A)') 'MISMATCH: '//msg
      nfail = nfail + 1
    END IF
  END SUBROUTINE require

  ! --------------------------------------------------------------------------------------------- !
  ! decks                                                                                         !
  ! --------------------------------------------------------------------------------------------- !

  SUBROUTINE write_header(u, title)
    INTEGER, INTENT(IN) :: u
    CHARACTER(*), INTENT(IN) :: title
    WRITE (u, '(A)') title
    WRITE (u, '(A)') '--- LINE TYPES ---'
    WRITE (u, '(A)') 'Name Diam Mass EA BA EI Cdn Cdt Can Cat'
    WRITE (u, '(A)') '(-) (m) (kg/m) (N) (-) (Nm2) (-) (-) (-) (-)'
    WRITE (u, '(A)') 'line 0.10 80.0 1.0e6 0.0 0.0 1.0 0.0 1.0 0.0'
    WRITE (u, '(A)') 'tether 0.05 4.0 2.0e5 0.0 0.0 1.0 0.0 1.0 0.0'
  END SUBROUTINE write_header

  SUBROUTINE write_md_body(u, attachment, pos, rot_deg, mass, cg, inertia, vol)
    !! A MoorDyn v2 14-column BODIES section with one body (no drag, no added mass).
    INTEGER, INTENT(IN) :: u
    CHARACTER(*), INTENT(IN) :: attachment
    REAL(wp), INTENT(IN) :: pos(3), rot_deg(3), mass, cg(3), inertia(3), vol
    WRITE (u, '(A)') '--- BODIES ---'
    WRITE (u, '(A)') 'ID Attachment X0 Y0 Z0 r0 p0 y0 Mass CG* I* Volume CdA* Ca*'
    WRITE (u, '(A)') '(#) (word) (m) (m) (m) (deg) (deg) (deg) (kg) (m) (kg-m^2) (m^3) (m^2) (-)'
    WRITE (u, '(A)') '1 '//attachment//' '//num(pos(1))//' '//num(pos(2))//' '//num(pos(3))//' '// &
      num(rot_deg(1))//' '//num(rot_deg(2))//' '//num(rot_deg(3))//' '//num(mass)//' '//bar3(cg)//' '// &
      bar3(inertia)//' '//num(vol)//' 0 0'
  END SUBROUTINE write_md_body

  FUNCTION num(x) RESULT(s)
    !! A real as a token without blanks (14 digits: a bar list of three stays within a deck token).
    REAL(wp), INTENT(IN) :: x
    CHARACTER(:), ALLOCATABLE :: s
    CHARACTER(32) :: buf
    WRITE (buf, '(ES20.13)') x
    s = TRIM(ADJUSTL(buf))
  END FUNCTION num

  FUNCTION bar3(x) RESULT(s)
    !! A MoorDyn bar list x1|x2|x3.
    REAL(wp), INTENT(IN) :: x(3)
    CHARACTER(:), ALLOCATABLE :: s
    s = num(x(1))//'|'//num(x(2))//'|'//num(x(3))
  END FUNCTION bar3

  SUBROUTINE write_options(u, depth, body_ic, extra)
    INTEGER, INTENT(IN) :: u
    REAL(wp), INTENT(IN) :: depth
    CHARACTER(*), INTENT(IN) :: body_ic
    CHARACTER(*), INTENT(IN), OPTIONAL :: extra
    WRITE (u, '(A)') '--- OPTIONS ---'
    WRITE (u, '(A)') '9.80665 g'
    WRITE (u, '(A)') '1025.0 rhoW'
    WRITE (u, '(F8.2,A)') depth, ' WtrDpth'
    WRITE (u, '(A)') '1.0e5 kBot'
    WRITE (u, '(A)') body_ic//' bodyIC'
    IF (PRESENT(extra)) WRITE (u, '(A)') extra
    WRITE (u, '(A)') '--- end ---'
  END SUBROUTINE write_options

  SUBROUTINE write_pendulum_deck(path, phi_deg, standalone)
    !! A dry CoupledPinned body (MB kg, CG HCG below the reference point in the body frame, Iyy
    !! about the CG) whose node is at (0, 0, ZPIN), above the water, released with its CG at phi_deg
    !! from the downward vertical towards +x (deck pose, bodyIC deck). A line hangs from a Body1
    !! point at the node to a Coupled point: it loads the node, but has no arm about it.
    !! standalone adds the dtM/TMax clock of a standalone run.
    CHARACTER(*), INTENT(IN) :: path
    REAL(wp), INTENT(IN) :: phi_deg
    LOGICAL, INTENT(IN), OPTIONAL :: standalone
    INTEGER :: u
    OPEN (NEWUNIT=u, FILE=path, STATUS='REPLACE', ACTION='WRITE')
    CALL write_header(u, 'CoupledPinned body pendulum on the coupled aggregate')
    ! R = Ry(p) carries the body -z axis to (-sin p, 0, -cos p): p = -phi
    CALL write_md_body(u, 'CoupledPinned', [0.0_wp, 0.0_wp, ZPIN], [0.0_wp, -phi_deg, 0.0_wp], MB, &
                       [0.0_wp, 0.0_wp, -HCG], [IYY, IYY, IYY], 0.0_wp)
    WRITE (u, '(A)') '--- POINTS ---'
    WRITE (u, '(A)') 'ID Type X Y Z Mass Vol CdA Ca'
    WRITE (u, '(A)') '(-) (-) (m) (m) (m) (kg) (m3) (m2) (-)'
    WRITE (u, '(A)') '1 Body1 0.0 0.0 0.0 0 0 0 0'
    WRITE (u, '(A)') '2 Coupled 4.0 0.0 12.0 0 0 0 0'
    WRITE (u, '(A)') '--- LINES ---'
    WRITE (u, '(A)') 'ID NodeA NodeB Outputs'
    WRITE (u, '(A)') '(-) (-) (-) (-)'
    WRITE (u, '(A)') '1 1 2 -'
    WRITE (u, '(A)') '--- SECTIONS ---'
    WRITE (u, '(A)') 'LineID LineType Length NumSegs'
    WRITE (u, '(A)') '(-) (-) (m) (-)'
    WRITE (u, '(A)') '1 line 9.5 6'
    IF (PRESENT(standalone)) THEN
      CALL write_options(u, 10.0_wp, 'deck', '0.01 dtM'//NEW_LINE('a')//'0.1 TMax')
    ELSE
      CALL write_options(u, 10.0_wp, 'deck')
    END IF
    CLOSE (u)
  END SUBROUTINE write_pendulum_deck

  SUBROUTINE write_arm_deck(path, as_rod, body_ic, rod_type)
    !! The arm of the second route, pinned at (0, 0, ZA) and hanging at THA from the downward
    !! vertical towards +x, above the water: as_rod a CoupledPinned ROD (LA long, DA diameter, MA kg,
    !! no drag or added mass), else a CoupledPinned BODY with the rod's mass, its CG at the rod
    !! centre and the rod's inertia about it (body x axis along the rod). A slack line runs from
    !! End B (the body point at LA along x) to an anchor at (30, 0, -20) and pulls the arm round.
    !! rod_type replaces CoupledPinned for the rod; a Free rod takes a second line from End A to an
    !! anchor at (-30, 0, -20).
    CHARACTER(*), INTENT(IN) :: path, body_ic
    LOGICAL, INTENT(IN) :: as_rod
    CHARACTER(*), INTENT(IN), OPTIONAL :: rod_type
    REAL(wp) :: th, xb, zb, r, i1, i2
    INTEGER :: u
    CHARACTER(16) :: rt
    rt = 'CoupledPinned'
    IF (PRESENT(rod_type)) rt = rod_type
    th = THA*PI/180.0_wp
    xb = LA*SIN(th)
    zb = ZA - LA*COS(th)
    r = 0.5_wp*DA
    i1 = 0.5_wp*MA*r*r
    i2 = MA*(3.0_wp*r*r + LA*LA)/12.0_wp
    OPEN (NEWUNIT=u, FILE=path, STATUS='REPLACE', ACTION='WRITE')
    CALL write_header(u, 'CoupledPinned arm on the coupled aggregate')
    IF (as_rod) THEN
      WRITE (u, '(A)') '--- ROD TYPES ---'
      WRITE (u, '(A)') 'Name Diam Mass Cd Ca CdEnd CaEnd'
      WRITE (u, '(A)') '(-) (m) (kg/m) (-) (-) (-) (-)'
      WRITE (u, '(A,ES24.16,1X,ES24.16,A)') 'arm ', DA, MA/LA, ' 0 0 0 0'
      WRITE (u, '(A)') '--- RODS ---'
      WRITE (u, '(A)') 'ID RodType Type XA YA ZA XB YB ZB NumSegs Outputs'
      WRITE (u, '(A)') '(-) (-) (-) (m) (m) (m) (m) (m) (m) (-) (-)'
      WRITE (u, '(A,ES24.16,A,ES24.16,A,ES24.16,A)') '1 arm '//TRIM(rt)//' 0 0 ', ZA, ' ', xb, ' 0 ', zb, ' 4 -'
    ELSE
      ! R = Ry(p) carries the body x axis to (cos p, 0, -sin p) = (sin th, 0, -cos th): p = 90 - th
      CALL write_md_body(u, 'CoupledPinned', [0.0_wp, 0.0_wp, ZA], [0.0_wp, 90.0_wp - THA, 0.0_wp], MA, &
                         [0.5_wp*LA, 0.0_wp, 0.0_wp], [i1, i2, i2], 0.0_wp)
    END IF
    WRITE (u, '(A)') '--- POINTS ---'
    WRITE (u, '(A)') 'ID Type X Y Z Mass Vol CdA Ca'
    WRITE (u, '(A)') '(-) (-) (m) (m) (m) (kg) (m3) (m2) (-)'
    WRITE (u, '(A)') '1 Fixed 30.0 0.0 -20.0 0 0 0 0'
    IF (.NOT. as_rod) WRITE (u, '(A,ES24.16,A)') '2 Body1 ', LA, ' 0.0 0.0 0 0 0 0'
    IF (TRIM(rt) == 'Free') WRITE (u, '(A)') '3 Fixed -30.0 0.0 -20.0 0 0 0 0'
    WRITE (u, '(A)') '--- LINES ---'
    WRITE (u, '(A)') 'ID NodeA NodeB Outputs'
    WRITE (u, '(A)') '(-) (-) (-) (-)'
    IF (as_rod) THEN
      WRITE (u, '(A)') '1 R1B 1 -'
      IF (TRIM(rt) == 'Free') WRITE (u, '(A)') '2 R1A 3 -'
    ELSE
      WRITE (u, '(A)') '1 2 1 -'
    END IF
    WRITE (u, '(A)') '--- SECTIONS ---'
    WRITE (u, '(A)') 'LineID LineType Length NumSegs'
    WRITE (u, '(A)') '(-) (-) (m) (-)'
    WRITE (u, '(A)') '1 line 40.0 20'
    IF (TRIM(rt) == 'Free') WRITE (u, '(A)') '2 line 38.0 20'
    CALL write_options(u, 20.0_wp, body_ic)
    CLOSE (u)
  END SUBROUTINE write_arm_deck

  SUBROUTINE write_symmetric_deck(path, free_body)
    !! A submerged VesselPinned body (18-column row: 200 kg, 0.1 m^3, Ca 0.5, inertia 50 kg m^2,
    !! CG at the reference point) at (0, 0, -5) on four identical lines from (+-3, 0, 0) and
    !! (0, +-3, 0) in the body frame to anchors 40 m out on the 50 m seabed. free_body: a Free
    !! Rigid6 body instead, started 1 m above the pose, pitched 10 deg (out of balance).
    CHARACTER(*), INTENT(IN) :: path
    LOGICAL, INTENT(IN), OPTIONAL :: free_body
    INTEGER :: u
    LOGICAL :: fb
    fb = .FALSE.
    IF (PRESENT(free_body)) fb = free_body
    OPEN (NEWUNIT=u, FILE=path, STATUS='REPLACE', ACTION='WRITE')
    CALL write_header(u, 'symmetric VesselPinned body on the coupled aggregate')
    WRITE (u, '(A)') '--- BODIES ---'
    WRITE (u, '(A)') 'ID Type X Y Z Rot1 Rot2 Rot3 Mass Vol C33 C44 C55 CdA Ca Ixx Iyy Izz'
    WRITE (u, '(A)') '(-) (-) (m) (m) (m) (deg) (deg) (deg) (kg) (m3) (N/m) (Nm/rad) (Nm/rad) (m2) (-) '// &
      '(kgm2) (kgm2) (kgm2)'
    IF (fb) THEN
      WRITE (u, '(A)') '1 Rigid6 0.0 0.0 -4.0 0.0 10.0 0.0 200.0 0.1 0.0 0.0 0.0 0.0 0.5 50.0 50.0 50.0'
    ELSE
      WRITE (u, '(A)') '1 VesselPinned 0.0 0.0 -5.0 0.0 0.0 0.0 200.0 0.1 0.0 0.0 0.0 0.0 0.5 50.0 50.0 50.0'
    END IF
    WRITE (u, '(A)') '--- POINTS ---'
    WRITE (u, '(A)') 'ID Type X Y Z Mass Vol CdA Ca'
    WRITE (u, '(A)') '(-) (-) (m) (m) (m) (kg) (m3) (m2) (-)'
    WRITE (u, '(A)') '1 Body1 3.0 0.0 0.0 0 0 0 0'
    WRITE (u, '(A)') '2 Body1 -3.0 0.0 0.0 0 0 0 0'
    WRITE (u, '(A)') '3 Body1 0.0 3.0 0.0 0 0 0 0'
    WRITE (u, '(A)') '4 Body1 0.0 -3.0 0.0 0 0 0 0'
    WRITE (u, '(A)') '5 Fixed 40.0 0.0 -50.0 0 0 0 0'
    WRITE (u, '(A)') '6 Fixed -40.0 0.0 -50.0 0 0 0 0'
    WRITE (u, '(A)') '7 Fixed 0.0 40.0 -50.0 0 0 0 0'
    WRITE (u, '(A)') '8 Fixed 0.0 -40.0 -50.0 0 0 0 0'
    WRITE (u, '(A)') '--- LINES ---'
    WRITE (u, '(A)') 'ID NodeA NodeB Outputs'
    WRITE (u, '(A)') '(-) (-) (-) (-)'
    WRITE (u, '(A)') '1 1 5 -'
    WRITE (u, '(A)') '2 2 6 -'
    WRITE (u, '(A)') '3 3 7 -'
    WRITE (u, '(A)') '4 4 8 -'
    WRITE (u, '(A)') '--- SECTIONS ---'
    WRITE (u, '(A)') 'LineID LineType Length NumSegs'
    WRITE (u, '(A)') '(-) (-) (m) (-)'
    WRITE (u, '(A)') '1 line 62.0 12'
    WRITE (u, '(A)') '2 line 62.0 12'
    WRITE (u, '(A)') '3 line 62.0 12'
    WRITE (u, '(A)') '4 line 62.0 12'
    CALL write_options(u, 50.0_wp, 'deck')
    CLOSE (u)
  END SUBROUTINE write_symmetric_deck

  SUBROUTINE write_tethered_deck(path, body_ic)
    !! A submerged CoupledPinned body (100 kg, 0.0628 m^3, inertia 10 kg m^2, CG 1 m below the
    !! reference point) at (0, 0, -10), held at its Body1 point 2 m below the node by two horizontal
    !! tethers to anchors at x = +-10 m (EA 2e5 N, 0.5 % pretension): the rotation about y meets
    !! their axial stiffness, a mode of about 38 rad/s. body_ic: the bodyIC option.
    CHARACTER(*), INTENT(IN) :: path, body_ic
    INTEGER :: u
    OPEN (NEWUNIT=u, FILE=path, STATUS='REPLACE', ACTION='WRITE')
    CALL write_header(u, 'tethered CoupledPinned body on the coupled aggregate')
    CALL write_md_body(u, 'CoupledPinned', [0.0_wp, 0.0_wp, -10.0_wp], [0.0_wp, 0.0_wp, 0.0_wp], 100.0_wp, &
                       [0.0_wp, 0.0_wp, -1.0_wp], [10.0_wp, 10.0_wp, 10.0_wp], 0.0628_wp)
    WRITE (u, '(A)') '--- POINTS ---'
    WRITE (u, '(A)') 'ID Type X Y Z Mass Vol CdA Ca'
    WRITE (u, '(A)') '(-) (-) (m) (m) (m) (kg) (m3) (m2) (-)'
    WRITE (u, '(A)') '1 Body1 0.0 0.0 -2.0 0 0 0 0'
    WRITE (u, '(A)') '2 Fixed 10.0 0.0 -12.0 0 0 0 0'
    WRITE (u, '(A)') '3 Fixed -10.0 0.0 -12.0 0 0 0 0'
    WRITE (u, '(A)') '--- LINES ---'
    WRITE (u, '(A)') 'ID NodeA NodeB Outputs'
    WRITE (u, '(A)') '(-) (-) (-) (-)'
    WRITE (u, '(A)') '1 1 2 -'
    WRITE (u, '(A)') '2 1 3 -'
    WRITE (u, '(A)') '--- SECTIONS ---'
    WRITE (u, '(A)') 'LineID LineType Length NumSegs'
    WRITE (u, '(A)') '(-) (-) (m) (-)'
    WRITE (u, '(A)') '1 tether 9.95 10'
    WRITE (u, '(A)') '2 tether 9.95 10'
    CALL write_options(u, 20.0_wp, body_ic)
    CLOSE (u)
  END SUBROUTINE write_tethered_deck

  ! --------------------------------------------------------------------------------------------- !
  ! helpers                                                                                       !
  ! --------------------------------------------------------------------------------------------- !

  REAL(wp) FUNCTION body_angle(s) RESULT(th)
    !! Angle of the pendulum's CG direction (the body -z axis) from the downward vertical,
    !! positive towards +x: atan2(-R13, R33) for the mirror s (R column-major at 16:24).
    REAL(wp), INTENT(IN) :: s(:)
    th = ATAN2(-s(22), s(24))
  END FUNCTION body_angle

  REAL(wp) FUNCTION ellip_k(k) RESULT(kk)
    !! Complete elliptic integral of the first kind by the arithmetic-geometric mean.
    REAL(wp), INTENT(IN) :: k
    REAL(wp) :: a, b, c
    INTEGER :: i
    a = 1.0_wp
    b = SQRT(1.0_wp - k*k)
    DO i = 1, 30
      c = 0.5_wp*(a + b)
      b = SQRT(a*b)
      a = c
    END DO
    kk = PI/(2.0_wp*a)
  END FUNCTION ellip_k

  SUBROUTINE crossings(t, x, xm, period, mean)
    !! Mean period between the up-crossings of x through xm and the mean of x over those whole
    !! periods (trapezoidal); period = -1 with fewer than three crossings.
    REAL(wp), INTENT(IN) :: t(:), x(:), xm
    REAL(wp), INTENT(OUT) :: period, mean
    REAL(wp) :: tc, t0, t1, area
    INTEGER :: i, n, i0, i1
    n = 0
    t0 = 0.0_wp
    t1 = 0.0_wp
    i0 = 0
    i1 = 0
    DO i = 1, SIZE(x) - 1
      IF (x(i) - xm < 0.0_wp .AND. x(i + 1) - xm >= 0.0_wp) THEN
        tc = t(i) + (xm - x(i))*(t(i + 1) - t(i))/(x(i + 1) - x(i))
        IF (n == 0) THEN
          t0 = tc
          i0 = i
        END IF
        t1 = tc
        i1 = i
        n = n + 1
      END IF
    END DO
    period = -1.0_wp
    mean = 0.0_wp
    IF (n < 3) RETURN
    period = (t1 - t0)/REAL(n - 1, wp)
    area = 0.5_wp*(xm + x(i0 + 1))*(t(i0 + 1) - t0) + 0.5_wp*(x(i1) + xm)*(t1 - t(i1))
    DO i = i0 + 1, i1 - 1
      area = area + 0.5_wp*(x(i) + x(i + 1))*(t(i + 1) - t(i))
    END DO
    mean = area/(t1 - t0)
  END SUBROUTINE crossings

  FUNCTION solve3(a, b) RESULT(x)
    !! x = a^-1 b by Cramer's rule (a 3x3, well conditioned here).
    REAL(wp), INTENT(IN) :: a(3, 3), b(3)
    REAL(wp) :: x(3), d, c(3, 3)
    INTEGER :: k
    d = det3(a)
    DO k = 1, 3
      c = a
      c(:, k) = b
      x(k) = det3(c)/d
    END DO
  END FUNCTION solve3

  PURE REAL(wp) FUNCTION det3(m) RESULT(d)
    REAL(wp), INTENT(IN) :: m(3, 3)
    d = m(1, 1)*(m(2, 2)*m(3, 3) - m(2, 3)*m(3, 2)) - m(1, 2)*(m(2, 1)*m(3, 3) - m(2, 3)*m(3, 1)) + &
        m(1, 3)*(m(2, 1)*m(3, 2) - m(2, 2)*m(3, 1))
  END FUNCTION det3

  PURE FUNCTION cross(x, y) RESULT(z)
    REAL(wp), INTENT(IN) :: x(3), y(3)
    REAL(wp) :: z(3)
    z = [x(2)*y(3) - x(3)*y(2), x(3)*y(1) - x(1)*y(3), x(1)*y(2) - x(2)*y(1)]
  END FUNCTION cross

  PURE FUNCTION skew(a) RESULT(s)
    REAL(wp), INTENT(IN) :: a(3)
    REAL(wp) :: s(3, 3)
    s(1, :) = [0.0_wp, -a(3), a(2)]
    s(2, :) = [a(3), 0.0_wp, -a(1)]
    s(3, :) = [-a(2), a(1), 0.0_wp]
  END FUNCTION skew

  FUNCTION pendulum_reaction(s, a_pin) RESULT(f)
    !! The force the dry pendulum body exerts on its node at state s (body mirror) for a node
    !! acceleration a_pin: Euler's equation about the node, I_p alpha + w x (I_p w) = c x m (g - a_pin)
    !! with I_p = R J R^T - m [c]x [c]x, then f = m g - m (a_pin + alpha x c + w x (w x c)).
    REAL(wp), INTENT(IN) :: s(:), a_pin(3)
    REAL(wp) :: f(3), rot(3, 3), ip(3, 3), c(3), w(3), alpha(3), gv(3)
    INTEGER :: k
    rot = RESHAPE(s(16:24), [3, 3])
    ip = 0.0_wp
    DO k = 1, 3
      ip(k, k) = IYY
    END DO
    c = -HCG*rot(:, 3)
    ip = MATMUL(rot, MATMUL(ip, TRANSPOSE(rot))) - MB*MATMUL(skew(c), skew(c))
    w = s(10:12)
    gv = [0.0_wp, 0.0_wp, -G]
    alpha = solve3(ip, cross(c, MB*(gv - a_pin)) - cross(w, MATMUL(ip, w)))
    f = MB*gv - MB*(a_pin + cross(alpha, c) + cross(w, cross(w, c)))
  END FUNCTION pendulum_reaction

  INTEGER FUNCTION coupled_block(agg, x) RESULT(ib)
    !! The coupled 3-DOF block of the line system whose committed position is x (0: none).
    TYPE(CD_AGG_ModuleType), INTENT(INOUT) :: agg
    REAL(wp), INTENT(IN) :: x(3)
    REAL(wp), ALLOCATABLE :: q(:), v(:), a(:)
    INTEGER :: ncd, k, es
    CHARACTER(512) :: em
    ncd = CD_System_NSystemCoupledDOF(agg%sys%fast%system)
    ALLOCATE (q(ncd), v(ncd), a(ncd))
    CALL CD_Get_System_CoupledMotion(agg%sys%fast%system, q, v, a, es, em)
    ib = 0
    DO k = 1, ncd/3
      IF (nan_max_abs(q(3*k - 2:3*k) - x) <= 1.0e-9_wp) ib = k
    END DO
  END FUNCTION coupled_block

  FUNCTION line_loads(agg) RESULT(l)
    !! The line loads on the coupled points of the line system (CD_Calc_System_CoupledLoads).
    TYPE(CD_AGG_ModuleType), INTENT(INOUT) :: agg
    REAL(wp), ALLOCATABLE :: l(:)
    INTEGER :: es
    CHARACTER(512) :: em
    ALLOCATE (l(CD_System_NSystemCoupledDOF(agg%sys%fast%system)))
    CALL CD_Calc_System_CoupledLoads(agg%sys%fast%system, l, es, em)
    CALL require(es == CD_SYSTEM_OK, 'line loads: '//TRIM(em))
  END FUNCTION line_loads

  SUBROUTINE march(agg, dt, nstep, host, ang, t, ok, force, states)
    !! March nstep coupling steps with every moving column translated rigidly by host(t) =
    !! [displacement, velocity, acceleration] from its initial position; ang(0:nstep) the pendulum
    !! angle (body_angle), t the times. Before the first step the host kinematics at t = 0 are
    !! transferred (the start of the run, as the coupled shell does). force: the node force (the
    !! last column) after each step; states: the body mirror after each step.
    TYPE(CD_AGG_ModuleType), INTENT(INOUT) :: agg
    REAL(wp), INTENT(IN) :: dt
    INTEGER, INTENT(IN) :: nstep
    INTERFACE
      FUNCTION host(time) RESULT(k)
        IMPORT :: wp
        REAL(wp), INTENT(IN) :: time
        REAL(wp) :: k(9)
      END FUNCTION host
    END INTERFACE
    REAL(wp), INTENT(OUT) :: ang(0:nstep), t(0:nstep)
    LOGICAL, INTENT(OUT) :: ok
    REAL(wp), INTENT(OUT), OPTIONAL :: force(3, 0:nstep), states(24, 0:nstep)
    REAL(wp), ALLOCATABLE :: p(:, :), v(:, :), a(:, :), f(:, :), p0(:, :), s(:)
    INTEGER :: n, es, it, step
    LOGICAL :: cv, st
    CHARACTER(512) :: em

    ok = .FALSE.
    n = CD_AGG_NMovingPoints(agg, es, em)
    ALLOCATE (p(3, n), v(3, n), a(3, n), f(3, n), p0(3, n), s(CD_AGG_Rigid6_MirrorSize(agg)))
    CALL CD_AGG_GetMovingPointMesh(agg, p0, v, a, f, es, em)
    DO step = 0, nstep
      t(step) = REAL(step, wp)*dt
      CALL host_columns(host(t(step)), p0, p, v, a)
      IF (step == 0) THEN
        CALL CD_AGG_UpdateStates_Moving(agg, p, v, a, es, em)
        CALL require(es == CD_AGG_OK, 'march:start-transfer: '//TRIM(em))
      ELSE
        CALL CD_AGG_Step_Moving(agg, dt, p, v, a, cv, st, it, es, em, t_committed=t(step))
        CALL require(es == CD_AGG_OK .AND. cv, 'march:step: '//TRIM(em))
      END IF
      IF (es /= CD_AGG_OK) RETURN
      CALL CD_AGG_Get_Rigid6_States(agg, s, es, em)
      ang(step) = body_angle(s)
      IF (PRESENT(states)) states(:, step) = s
      IF (PRESENT(force)) THEN
        CALL CD_AGG_CalcOutput(agg, es, em)
        CALL CD_AGG_GetMovingPointMesh(agg, p, v, a, f, es, em)
        force(:, step) = f(:, n)
      END IF
    END DO
    ok = ALL(IEEE_IS_FINITE(ang))
  END SUBROUTINE march

  SUBROUTINE host_columns(k, p0, p, v, a)
    !! Every moving column translated rigidly by k = [displacement, velocity, acceleration].
    REAL(wp), INTENT(IN) :: k(9), p0(:, :)
    REAL(wp), INTENT(OUT) :: p(:, :), v(:, :), a(:, :)
    INTEGER :: i
    DO i = 1, SIZE(p0, 2)
      p(:, i) = p0(:, i) + k(1:3)
      v(:, i) = k(4:6)
      a(:, i) = k(7:9)
    END DO
  END SUBROUTINE host_columns

  FUNCTION host_const(time) RESULT(k)
    !! The node accelerating uniformly along +x from rest: a = 2 m/s^2.
    REAL(wp), INTENT(IN) :: time
    REAL(wp) :: k(9)
    REAL(wp), PARAMETER :: AX = 2.0_wp
    k = 0.0_wp
    k(1) = 0.5_wp*AX*time*time
    k(4) = AX*time
    k(7) = AX
  END FUNCTION host_const

  FUNCTION host_surge(time) RESULT(k)
    !! x_p = X (1 - cos W t), X = 0.2 m, a 5 s period.
    REAL(wp), INTENT(IN) :: time
    REAL(wp) :: k(9), w
    REAL(wp), PARAMETER :: X = 0.2_wp
    w = 2.0_wp*PI/5.0_wp
    k = 0.0_wp
    k(1) = X*(1.0_wp - COS(w*time))
    k(4) = X*w*SIN(w*time)
    k(7) = X*w*w*COS(w*time)
  END FUNCTION host_surge

  FUNCTION host_heave(time) RESULT(k)
    !! z_p = Z sin W t, Z = 0.5 m, a 6 s period.
    REAL(wp), INTENT(IN) :: time
    REAL(wp) :: k(9), w
    REAL(wp), PARAMETER :: Z = 0.5_wp
    w = 2.0_wp*PI/6.0_wp
    k = 0.0_wp
    k(3) = Z*SIN(w*time)
    k(6) = Z*w*COS(w*time)
    k(9) = -Z*w*w*SIN(w*time)
  END FUNCTION host_heave

  FUNCTION host_drift(time) RESULT(k)
    !! The node drifting along +x at a constant 0.05 m/s from t = 0.
    REAL(wp), INTENT(IN) :: time
    REAL(wp) :: k(9)
    k = 0.0_wp
    k(1) = 0.05_wp*time
    k(4) = 0.05_wp
  END FUNCTION host_drift

  ! --------------------------------------------------------------------------------------------- !
  ! 1: the held compound pendulum                                                                 !
  ! --------------------------------------------------------------------------------------------- !

  SUBROUTINE case_pendulum_held()
    TYPE(CD_AGG_ModuleType) :: agg
    REAL(wp), PARAMETER :: TH0 = 30.0_wp
    INTEGER, PARAMETER :: NSTEP = 500
    REAL(wp), ALLOCATABLE :: p(:, :), v(:, :), a(:, :), f(:, :), mo(:, :), p0(:, :), l(:)
    REAL(wp) :: ang(0:NSTEP), t(0:NSTEP), s(24), ip, t_ref, dt, period, mean, err_pin, err_force, fref(3)
    INTEGER :: es, n, step, it, ib
    LOGICAL :: cv, st
    CHARACTER(512) :: em

    ip = IYY + MB*HCG*HCG
    t_ref = 4.0_wp*SQRT(ip/(MB*G*HCG))*ellip_k(SIN(0.5_wp*TH0*PI/180.0_wp))
    dt = t_ref/100.0_wp
    CALL write_pendulum_deck('pinbody_pendulum.dat', TH0)
    CALL CD_AGG_Init_From_Deck(agg, 'pinbody_pendulum.dat', dt, es, em)
    CALL require(es == CD_AGG_OK, 'pendulum:init: '//TRIM(em))
    IF (es /= CD_AGG_OK) RETURN
    n = CD_AGG_NMovingPoints(agg, es, em)
    CALL require(CD_AGG_HasRigid6(agg) .AND. n == 2, 'pendulum:one host node for the body after the fairlead')
    IF (n /= 2) RETURN
    ALLOCATE (p(3, n), v(3, n), a(3, n), f(3, n), mo(3, n), p0(3, n))
    CALL CD_AGG_GetMovingPointMesh(agg, p0, v, a, f, es, em)
    CALL require(nan_max_abs(p0(:, 2) - [0.0_wp, 0.0_wp, ZPIN]) <= 0.0_wp, 'pendulum:host node at the reference point')
    ib = coupled_block(agg, [0.0_wp, 0.0_wp, ZPIN])
    CALL require(ib > 0, 'pendulum:the node line end is a coupled point')
    IF (ib == 0) RETURN
    p = p0
    v = 0.0_wp
    a = 0.0_wp
    err_pin = 0.0_wp
    err_force = 0.0_wp
    DO step = 0, NSTEP
      IF (step > 0) THEN
        CALL CD_AGG_Step_Moving(agg, dt, p, v, a, cv, st, it, es, em, t_committed=REAL(step, wp)*dt)
        CALL require(es == CD_AGG_OK .AND. cv, 'pendulum:step: '//TRIM(em))
        IF (es /= CD_AGG_OK) RETURN
      END IF
      CALL CD_AGG_Get_Rigid6_States(agg, s, es, em)
      t(step) = REAL(step, wp)*dt
      ang(step) = body_angle(s)
      err_pin = MAX(err_pin, nan_max_abs(s(1:3) - [0.0_wp, 0.0_wp, ZPIN]), nan_max_abs(s(4:9)))
      CALL CD_AGG_CalcOutput(agg, es, em)
      CALL CD_AGG_GetMovingPointMesh(agg, p, v, a, f, es, em, moment=mo)
      CALL require(es == CD_AGG_OK, 'pendulum:mesh: '//TRIM(em))
      CALL require(nan_max_abs(mo(:, 2)) <= 0.0_wp, 'pendulum:node moment is zero')
      l = line_loads(agg)
      fref = pendulum_reaction(s, [0.0_wp, 0.0_wp, 0.0_wp]) + l(3*ib - 2:3*ib)
      err_force = MAX(err_force, nan_max_abs(f(:, 2) - fref)/(MB*G))
      p = p0
      v = 0.0_wp
      a = 0.0_wp
    END DO
    CALL crossings(t, ang, 0.0_wp, period, mean)
    WRITE (*, '(A,2F12.6,A,ES10.3)') 'CoupledPinned body pendulum period got/analytic [s]: ', period, t_ref, &
      '; rel. error ', ABS(period - t_ref)/t_ref
    WRITE (*, '(A,ES10.3,A,ES10.3)') 'max |reference point motion off the held node| ', err_pin, &
      '; node force vs pin reaction + line force / mg ', err_force
    CALL require(ABS(period - t_ref) <= 1.0e-3_wp*t_ref, 'pendulum:period (elliptic integral)')
    CALL require(err_pin <= 0.0_wp, 'pendulum:the reference point stays on the held node')
    CALL require(err_force <= 1.0e-10_wp, 'pendulum:node force is the pin reaction plus the line force')
    CALL CD_AGG_End(agg, es, em)
  END SUBROUTINE case_pendulum_held

  ! --------------------------------------------------------------------------------------------- !
  ! 2: constant node acceleration                                                                 !
  ! --------------------------------------------------------------------------------------------- !

  SUBROUTINE case_constant_acceleration()
    !! In the frame of a node accelerating at a along x the body is a pendulum in the effective
    !! gravity (-a, 0, -g): it swings about phi_eq = -atan(a/g) (trailing) with the period
    !! 4 sqrt(I_p/(m h g_eff)) K(sin(delta/2)), g_eff = sqrt(g^2 + a^2), for an amplitude delta.
    !! The line at the node moves with it (its Coupled end takes the same translation).
    TYPE(CD_AGG_ModuleType) :: agg
    REAL(wp), PARAMETER :: AX = 2.0_wp, DELTA = 5.0_wp
    INTEGER, PARAMETER :: NSTEP = 500
    REAL(wp) :: ang(0:NSTEP), t(0:NSTEP), ip, th_eq, geff, t_ref, dt, period, mean
    INTEGER :: es
    LOGICAL :: ok
    CHARACTER(512) :: em

    th_eq = -ATAN(AX/G)
    geff = SQRT(G*G + AX*AX)
    ip = IYY + MB*HCG*HCG
    t_ref = 4.0_wp*SQRT(ip/(MB*geff*HCG))*ellip_k(SIN(0.5_wp*DELTA*PI/180.0_wp))
    dt = t_ref/100.0_wp
    CALL write_pendulum_deck('pinbody_accel.dat', th_eq*180.0_wp/PI + DELTA)
    CALL CD_AGG_Init_From_Deck(agg, 'pinbody_accel.dat', dt, es, em)
    CALL require(es == CD_AGG_OK, 'accel:init: '//TRIM(em))
    IF (es /= CD_AGG_OK) RETURN
    CALL march(agg, dt, NSTEP, host_const, ang, t, ok)
    CALL require(ok, 'accel:march finite')
    IF (.NOT. ok) RETURN
    CALL crossings(t, ang, th_eq, period, mean)
    WRITE (*, '(A,2F12.6,A,2F10.6)') 'constant node acceleration: period got/analytic [s] ', period, t_ref, &
      '; mean angle got/-atan(a/g) [rad] ', mean, th_eq
    CALL require(ABS(period - t_ref) <= 1.0e-3_wp*t_ref, 'accel:period with g_eff')
    CALL require(ABS(mean - th_eq) <= 1.0e-4_wp, 'accel:mean angle -atan(a/g)')
    CALL CD_AGG_End(agg, es, em)
  END SUBROUTINE case_constant_acceleration

  ! --------------------------------------------------------------------------------------------- !
  ! 3: the second route, a CoupledPinned rod                                                      !
  ! --------------------------------------------------------------------------------------------- !

  SUBROUTINE case_rod_second_route()
    !! The body with the rod's mass, CG and inertia, its line at the rod's End B, follows the
    !! CoupledPinned rod (an independent route: the rod's pinned solve about End A with its mass at
    !! the centre, against the body's CG coupling blocks about its reference point) under a
    !! harmonic node surge: same axis, angular velocity and node force to 1e-9.
    TYPE(CD_AGG_ModuleType) :: rod, body
    REAL(wp), PARAMETER :: DT = 0.01_wp
    INTEGER, PARAMETER :: NSTEP = 600
    REAL(wp), ALLOCATABLE :: p(:, :), v(:, :), a(:, :), f(:, :), p0(:, :), pr0(:, :), fr(:, :)
    REAL(wp) :: sr(24), sb(24), k(9), err_axis, err_w, err_f, famp, wamp, turn
    INTEGER :: es, n, nr, step, it
    LOGICAL :: cv, st
    CHARACTER(512) :: em

    CALL write_arm_deck('pinbody_arm_rod.dat', .TRUE., 'deck')
    CALL write_arm_deck('pinbody_arm_body.dat', .FALSE., 'deck')
    CALL CD_AGG_Init_From_Deck(rod, 'pinbody_arm_rod.dat', DT, es, em)
    CALL require(es == CD_AGG_OK, 'route:rod init: '//TRIM(em))
    IF (es /= CD_AGG_OK) RETURN
    CALL CD_AGG_Init_From_Deck(body, 'pinbody_arm_body.dat', DT, es, em)
    CALL require(es == CD_AGG_OK, 'route:body init: '//TRIM(em))
    IF (es /= CD_AGG_OK) RETURN
    CALL require(CD_AGG_HasRod(rod) .AND. CD_AGG_HasRigid6(body), 'route:a rod deck and a body deck')
    n = CD_AGG_NMovingPoints(body, es, em)
    nr = CD_AGG_NMovingPoints(rod, es, em)
    CALL require(n == 1 .AND. nr == 1, 'route:one host node each')
    IF (n /= 1 .OR. nr /= 1) RETURN
    ALLOCATE (p(3, 1), v(3, 1), a(3, 1), f(3, 1), p0(3, 1), pr0(3, 1), fr(3, 1))
    CALL CD_AGG_GetMovingPointMesh(body, p0, v, a, f, es, em)
    CALL CD_AGG_GetMovingPointMesh(rod, pr0, v, a, fr, es, em)
    CALL require(nan_max_abs(p0 - pr0) <= 1.0e-14_wp, 'route:the same node')
    err_axis = 0.0_wp
    err_w = 0.0_wp
    err_f = 0.0_wp
    famp = 0.0_wp
    wamp = 0.0_wp
    turn = 0.0_wp
    DO step = 0, NSTEP
      k = host_surge(REAL(step, wp)*DT)
      CALL host_columns(k, p0, p, v, a)
      IF (step == 0) THEN
        CALL CD_AGG_UpdateStates_Moving(body, p, v, a, es, em)
        CALL CD_AGG_UpdateStates_Moving(rod, p, v, a, es, em)
      ELSE
        CALL CD_AGG_Step_Moving(body, DT, p, v, a, cv, st, it, es, em, t_committed=REAL(step, wp)*DT)
        CALL require(es == CD_AGG_OK .AND. cv, 'route:body step: '//TRIM(em))
        IF (es /= CD_AGG_OK) RETURN
        CALL CD_AGG_Step_Moving(rod, DT, p, v, a, cv, st, it, es, em, t_committed=REAL(step, wp)*DT)
        CALL require(es == CD_AGG_OK .AND. cv, 'route:rod step: '//TRIM(em))
        IF (es /= CD_AGG_OK) RETURN
      END IF
      CALL CD_AGG_Get_Rigid6_States(body, sb, es, em)
      CALL CD_AGG_Get_Rod_States(rod, sr, es, em)
      CALL CD_AGG_CalcOutput(body, es, em)
      CALL CD_AGG_GetMovingPointMesh(body, p, v, a, f, es, em)
      CALL CD_AGG_CalcOutput(rod, es, em)
      CALL CD_AGG_GetMovingPointMesh(rod, p, v, a, fr, es, em)
      err_axis = MAX(err_axis, nan_max_abs(sb(16:18) - sr(16:18)))
      err_w = MAX(err_w, nan_max_abs(sb(10:12) - sr(10:12)))
      err_f = MAX(err_f, nan_max_abs(f(:, 1) - fr(:, 1)))
      famp = MAX(famp, nan_max_abs(fr(:, 1)))
      wamp = MAX(wamp, nan_max_abs(sr(10:12)))
      turn = MAX(turn, ABS(ATAN2(sr(16), -sr(18)) - THA*PI/180.0_wp))
    END DO
    WRITE (*, '(A,ES10.3,A,ES10.3,A,ES10.3,A,ES10.3,A,F8.4,A)') 'body vs CoupledPinned rod: axis ', err_axis, &
      '; omega ', err_w, ' of ', wamp, ' rad/s; node force ', err_f/famp, ' rel. (arm turned ', turn, ' rad)'
    CALL require(turn > 0.05_wp, 'route:the line and the surge turn the arm')
    CALL require(err_axis <= 1.0e-9_wp .AND. err_w <= 1.0e-9_wp*wamp .AND. err_f <= 1.0e-9_wp*famp, &
                 'route:the body follows the CoupledPinned rod')
    CALL CD_AGG_End(rod, es, em)
    CALL CD_AGG_End(body, es, em)
  END SUBROUTINE case_rod_second_route

  ! --------------------------------------------------------------------------------------------- !
  ! 4: symmetric mooring under heave                                                              !
  ! --------------------------------------------------------------------------------------------- !

  SUBROUTINE case_symmetric_heave()
    !! Four identical lines at 90 deg about a body with its CG at the node: a heaving node gives
    !! no moment, so the body keeps its pose (|omega| and the turn below 1e-12), and the node force
    !! is the line force sum plus the net weight and the translational inertia, rhoW g V - m g
    !! along z less (m + rhoW V Ca) a.
    TYPE(CD_AGG_ModuleType) :: agg
    REAL(wp), PARAMETER :: DT = 0.02_wp, M = 200.0_wp, VOL = 0.1_wp, CA = 0.5_wp
    INTEGER, PARAMETER :: NSTEP = 300
    REAL(wp), ALLOCATABLE :: p(:, :), v(:, :), a(:, :), f(:, :), mo(:, :), p0(:, :), l(:)
    REAL(wp) :: s(24), k(9), fref(3), err_w, err_turn, err_f, famp, lamp
    INTEGER :: es, n, step, it, ip, ib(4)
    REAL(wp), PARAMETER :: ARMS(3, 4) = RESHAPE([3.0_wp, 0.0_wp, 0.0_wp, -3.0_wp, 0.0_wp, 0.0_wp, &
                                                 0.0_wp, 3.0_wp, 0.0_wp, 0.0_wp, -3.0_wp, 0.0_wp], [3, 4])
    LOGICAL :: cv, st
    CHARACTER(512) :: em

    CALL write_symmetric_deck('pinbody_sym.dat')
    CALL CD_AGG_Init_From_Deck(agg, 'pinbody_sym.dat', DT, es, em, external_fluid=.TRUE.)
    CALL require(es == CD_AGG_OK, 'sym:init: '//TRIM(em))
    IF (es /= CD_AGG_OK) RETURN
    n = CD_AGG_NMovingPoints(agg, es, em)
    CALL require(n == 1, 'sym:one host node (the VesselPinned body)')
    IF (n /= 1) RETURN
    ALLOCATE (p(3, n), v(3, n), a(3, n), f(3, n), mo(3, n), p0(3, n))
    CALL CD_AGG_GetMovingPointMesh(agg, p0, v, a, f, es, em)
    err_w = 0.0_wp
    err_turn = 0.0_wp
    err_f = 0.0_wp
    famp = 0.0_wp
    lamp = 0.0_wp
    DO step = 0, NSTEP
      k = host_heave(REAL(step, wp)*DT)
      CALL host_columns(k, p0, p, v, a)
      IF (step == 0) THEN
        CALL CD_AGG_UpdateStates_Moving(agg, p, v, a, es, em)
      ELSE
        CALL CD_AGG_Step_Moving(agg, DT, p, v, a, cv, st, it, es, em, t_committed=REAL(step, wp)*DT)
        CALL require(es == CD_AGG_OK .AND. cv, 'sym:step: '//TRIM(em))
      END IF
      IF (es /= CD_AGG_OK) RETURN
      CALL CD_AGG_Get_Rigid6_States(agg, s, es, em)
      err_w = MAX(err_w, nan_max_abs(s(10:12)))
      err_turn = MAX(err_turn, nan_max_abs(s(16:24) - [1.0_wp, 0.0_wp, 0.0_wp, 0.0_wp, 1.0_wp, 0.0_wp, &
                                                       0.0_wp, 0.0_wp, 1.0_wp]))
      CALL CD_AGG_CalcOutput(agg, es, em)
      CALL CD_AGG_GetMovingPointMesh(agg, p, v, a, f, es, em, moment=mo)
      l = line_loads(agg)
      fref = [0.0_wp, 0.0_wp, (RHO*VOL - M)*G] - (M + RHO*VOL*CA)*k(7:9)
      DO ip = 1, 4
        IF (step == 0) THEN
          ib(ip) = coupled_block(agg, p0(:, 1) + ARMS(:, ip))
          CALL require(ib(ip) > 0, 'sym:the line ends are coupled points')
          IF (ib(ip) == 0) RETURN
        END IF
        fref = fref + l(3*ib(ip) - 2:3*ib(ip))
        lamp = MAX(lamp, nan_max_abs(l(3*ib(ip) - 2:3*ib(ip))))
      END DO
      err_f = MAX(err_f, nan_max_abs(f(:, 1) - fref))
      famp = MAX(famp, nan_max_abs(f(:, 1)))
      CALL require(nan_max_abs(mo(:, 1)) <= 0.0_wp, 'sym:zero node moment')
    END DO
    WRITE (*, '(A,ES10.3,A,ES10.3,A,ES10.3,A,ES10.3,A)') 'symmetric heave: max |omega| ', err_w, &
      ' rad/s, max |R - I| ', err_turn, '; |node force - (line sum + weight, buoyancy, inertia)| ', &
      err_f/famp, ' rel. (line force ', lamp, ' N)'
    CALL require(err_w <= 1.0e-12_wp .AND. err_turn <= 1.0e-12_wp, 'sym:the body does not turn')
    CALL require(err_f <= 1.0e-10_wp*famp, 'sym:node force is the line sum plus the body load')
    CALL CD_AGG_End(agg, es, em)
  END SUBROUTINE case_symmetric_heave

  ! --------------------------------------------------------------------------------------------- !
  ! 5: the output probe                                                                           !
  ! --------------------------------------------------------------------------------------------- !

  SUBROUTINE case_probe()
    !! On the hanging dry pendulum at rest, a probe node acceleration a_p along x returns the rest
    !! force plus -M_eff a_p, M_eff = m I_cg/I_p (the rotation re-solved at a_p; the committed
    !! angular acceleration would give -m a_p), besides the change of the line force at the node.
    TYPE(CD_AGG_ModuleType) :: agg
    REAL(wp), ALLOCATABLE :: p(:, :), v(:, :), a(:, :), f(:, :), f0(:, :), mo(:, :), p0(:, :), l0(:), l1(:)
    REAL(wp) :: ap, ip, df, dl
    INTEGER :: es, n, ib
    CHARACTER(512) :: em

    CALL write_pendulum_deck('pinbody_probe.dat', 0.0_wp)
    CALL CD_AGG_Init_From_Deck(agg, 'pinbody_probe.dat', 0.01_wp, es, em)
    CALL require(es == CD_AGG_OK, 'probe:init: '//TRIM(em))
    IF (es /= CD_AGG_OK) RETURN
    n = CD_AGG_NMovingPoints(agg, es, em)
    ALLOCATE (p(3, n), v(3, n), a(3, n), f(3, n), f0(3, n), mo(3, n), p0(3, n))
    CALL CD_AGG_CalcOutput(agg, es, em)
    CALL CD_AGG_GetMovingPointMesh(agg, p0, v, a, f0, es, em)
    ib = coupled_block(agg, p0(:, n))
    l0 = line_loads(agg)
    ap = 1.5_wp
    p = p0
    v = 0.0_wp
    a = 0.0_wp
    a(1, n) = ap
    CALL CD_AGG_UpdateStates_Moving(agg, p, v, a, es, em, output_probe=.TRUE.)
    CALL CD_AGG_CalcOutput(agg, es, em)
    CALL CD_AGG_GetMovingPointMesh(agg, p, v, a, f, es, em, moment=mo)
    l1 = line_loads(agg)
    ip = IYY + MB*HCG*HCG
    df = f(1, n) - f0(1, n)
    dl = l1(3*ib - 2) - l0(3*ib - 2)
    WRITE (*, '(A,F11.4,A,F11.4,A,F11.4,A,F11.4)') 'probe node acceleration: dF_x got ', df, ' N (line ', dl, &
      ' N); body part ', df - dl, ' N; -m (I_cg/I_p) a_p ', -MB*IYY/ip*ap
    CALL require(ib > 0 .AND. ABS(dl) > 1.0_wp, 'probe:the node line carries the node acceleration')
    CALL require(ABS(df - dl + MB*IYY/ip*ap) <= 1.0e-10_wp*MB*G, 'probe:-M_eff a_p (re-solved rotation)')
    CALL require(nan_max_abs(f(2:3, n) - f0(2:3, n) - (l1(3*ib - 1:3*ib) - l0(3*ib - 1:3*ib))) <= 1.0e-10_wp*MB*G &
                 .AND. nan_max_abs(mo(:, n)) <= 0.0_wp, 'probe:no other force change, zero moment')
    CALL CD_AGG_End(agg, es, em)
  END SUBROUTINE case_probe

  ! --------------------------------------------------------------------------------------------- !
  ! 6: snapshot / restore, probe restore and the restart overlay                                  !
  ! --------------------------------------------------------------------------------------------- !

  SUBROUTINE overlay_state(src, dst, p, v, a, so, sw, sal)
    !! What the coupled shell restores, src -> dst: the host kinematics, the line interiors, the
    !! body states and finally the committed line-end motion.
    TYPE(CD_AGG_ModuleType), INTENT(INOUT) :: src, dst
    REAL(wp), INTENT(IN) :: p(:, :), v(:, :), a(:, :)
    REAL(wp), INTENT(IN), OPTIONAL :: so(:, :, :), sw(:, :), sal(:, :)
    REAL(wp), ALLOCATABLE :: lq(:), lv(:), la(:), bs(:), cq(:), cvv(:), ca(:)
    INTEGER :: es, nl, il, ndof, ncd
    CHARACTER(512) :: em
    IF (PRESENT(so)) THEN
      CALL CD_AGG_UpdateStates_Moving(dst, p, v, a, es, em, output_probe=.TRUE., orientation=so, &
                                      angular_velocity=sw, angular_acceleration=sal)
    ELSE
      CALL CD_AGG_UpdateStates_Moving(dst, p, v, a, es, em)
    END IF
    CALL require(es == CD_AGG_OK, 'overlay:host: '//TRIM(em))
    nl = CD_System_NLines(src%sys%fast%system, es, em)
    DO il = 1, nl
      ndof = CD_System_Line_NDOF(src%sys%fast%system, il, es, em)
      ALLOCATE (lq(ndof), lv(ndof), la(ndof))
      CALL CD_Get_System_Line_State(src%sys%fast%system, il, lq, lv, la, es, em)
      CALL CD_Update_System_Line_Interior_State(dst%sys%fast%system, il, lq(4:ndof - 3), lv(4:ndof - 3), es, em, &
                                                a_interior=la(4:ndof - 3))
      CALL require(es == CD_SYSTEM_OK, 'overlay:interior: '//TRIM(em))
      DEALLOCATE (lq, lv, la)
    END DO
    ALLOCATE (bs(CD_AGG_Rigid6_MirrorSize(src)))
    CALL CD_AGG_Get_Rigid6_States(src, bs, es, em)
    CALL CD_AGG_Set_Rigid6_States(dst, bs, es, em)
    CALL require(es == CD_AGG_OK, 'overlay:body states: '//TRIM(em))
    ncd = CD_System_NSystemCoupledDOF(src%sys%fast%system)
    ALLOCATE (cq(ncd), cvv(ncd), ca(ncd))
    CALL CD_Get_System_CoupledMotion(src%sys%fast%system, cq, cvv, ca, es, em)
    CALL CD_Update_System_CoupledMotion(dst%sys%fast%system, cq, cvv, ca, es, em)
    CALL require(es == CD_SYSTEM_OK, 'overlay:coupled motion: '//TRIM(em))
  END SUBROUTINE overlay_state

  SUBROUTINE case_state()
    !! On the arm body under the harmonic surge: snapshot / step / restore / step is bit-identical;
    !! a probe (node moved, accelerated) restored as the shell restores it leaves the march
    !! bit-identical to a twin that was never probed; a fresh instance overlaid with the checkpoint
    !! state returns the same loads before the next step and continues bit for bit.
    TYPE(CD_AGG_ModuleType) :: agg, twin, agg_b
    REAL(wp), PARAMETER :: DT = 0.02_wp
    REAL(wp), ALLOCATABLE :: p(:, :), v(:, :), a(:, :), f(:, :), fb(:, :), mo(:, :), mb(:, :), p0(:, :)
    REAL(wp), ALLOCATABLE :: sp(:, :), sv(:, :), sa(:, :), so(:, :, :), sw(:, :), sal(:, :)
    REAL(wp) :: bs(24), bs2(24), k(9), err
    INTEGER :: es, n, step, it
    LOGICAL :: cv, st
    CHARACTER(512) :: em

    CALL write_arm_deck('pinbody_state.dat', .FALSE., 'deck')
    CALL CD_AGG_Init_From_Deck(agg, 'pinbody_state.dat', DT, es, em)
    CALL CD_AGG_Init_From_Deck(twin, 'pinbody_state.dat', DT, es, em)
    CALL require(es == CD_AGG_OK, 'state:init: '//TRIM(em))
    IF (es /= CD_AGG_OK) RETURN
    n = CD_AGG_NMovingPoints(agg, es, em)
    ALLOCATE (p(3, n), v(3, n), a(3, n), f(3, n), fb(3, n), mo(3, n), mb(3, n), p0(3, n))
    ALLOCATE (sp(3, n), sv(3, n), sa(3, n), so(3, 3, n), sw(3, n), sal(3, n))
    CALL CD_AGG_GetMovingPointMesh(agg, p0, v, a, f, es, em)
    DO step = 0, 40
      CALL host_columns(host_surge(REAL(step, wp)*DT), p0, p, v, a)
      IF (step == 0) THEN
        CALL CD_AGG_UpdateStates_Moving(agg, p, v, a, es, em)
        CALL CD_AGG_UpdateStates_Moving(twin, p, v, a, es, em)
        CYCLE
      END IF
      CALL CD_AGG_Step_Moving(agg, DT, p, v, a, cv, st, it, es, em, t_committed=REAL(step, wp)*DT)
      CALL CD_AGG_Step_Moving(twin, DT, p, v, a, cv, st, it, es, em, t_committed=REAL(step, wp)*DT)
      CALL require(es == CD_AGG_OK, 'state:march: '//TRIM(em))
      IF (es /= CD_AGG_OK) RETURN
      IF (step /= 20) CYCLE
      ! the shell's probe: save the committed host kinematics and the state, probe, restore
      CALL CD_AGG_GetMovingPointMesh(agg, sp, sv, sa, f, es, em, orientation=so, angular_velocity=sw, &
                                     angular_acceleration=sal)
      CALL CD_AGG_Snapshot(twin, es, em)
      p(1, n) = p(1, n) + 0.3_wp
      a(1, n) = a(1, n) + 4.0_wp
      v(1, n) = v(1, n) - 0.5_wp
      CALL CD_AGG_UpdateStates_Moving(agg, p, v, a, es, em, output_probe=.TRUE.)
      CALL CD_AGG_CalcOutput(agg, es, em)
      CALL CD_AGG_GetMovingPointMesh(agg, p, v, a, f, es, em, moment=mo)
      CALL require(ALL(IEEE_IS_FINITE(f)) .AND. nan_max_abs(mo(:, n)) <= 0.0_wp, 'state:probe force, zero moment')
      CALL overlay_state(twin, agg, sp, sv, sa, so, sw, sal)
      CALL CD_AGG_Get_Rigid6_States(agg, bs, es, em)
      CALL CD_AGG_Get_Rigid6_States(twin, bs2, es, em)
      CALL require(nan_max_abs(bs - bs2) <= 0.0_wp, 'state:probe restored the body state')
    END DO
    CALL CD_AGG_Get_Rigid6_States(agg, bs, es, em)
    CALL CD_AGG_Get_Rigid6_States(twin, bs2, es, em)
    CALL require(nan_max_abs(bs - bs2) <= 0.0_wp, 'state:probed run equals the twin bit for bit')
    ! snapshot -> step A -> restore -> step B reproduces step A
    k = host_surge(41.0_wp*DT)
    CALL host_columns(k, p0, p, v, a)
    CALL CD_AGG_Snapshot(agg, es, em)
    CALL CD_AGG_Step_Moving(agg, DT, p, v, a, cv, st, it, es, em, t_committed=41.0_wp*DT)
    CALL CD_AGG_CalcOutput(agg, es, em)
    CALL CD_AGG_GetMovingPointMesh(agg, sp, sv, sa, fb, es, em, moment=mb)
    CALL CD_AGG_Get_Rigid6_States(agg, bs, es, em)
    CALL CD_AGG_Restore(agg, es, em)
    CALL CD_AGG_Step_Moving(agg, DT, p, v, a, cv, st, it, es, em, t_committed=41.0_wp*DT)
    CALL CD_AGG_CalcOutput(agg, es, em)
    CALL CD_AGG_GetMovingPointMesh(agg, sp, sv, sa, f, es, em, moment=mo)
    CALL CD_AGG_Get_Rigid6_States(agg, bs2, es, em)
    CALL require(nan_max_abs(f - fb) <= 0.0_wp .AND. nan_max_abs(mo - mb) <= 0.0_wp .AND. &
                 nan_max_abs(bs - bs2) <= 0.0_wp, 'state:snapshot-step-restore-step bit-identical')
    CALL require(nan_max_abs(mo(:, n)) <= 0.0_wp .AND. nan_max_abs(f(:, n)) > 0.0_wp, 'state:force only at the node')
    ! restart: a fresh instance takes the host kinematics, the line interiors and the body states
    CALL CD_AGG_Init_From_Deck(agg_b, 'pinbody_state.dat', DT, es, em)
    CALL require(es == CD_AGG_OK, 'restart:init: '//TRIM(em))
    IF (es /= CD_AGG_OK) RETURN
    CALL overlay_state(agg, agg_b, p, v, a)
    CALL CD_AGG_CalcOutput(agg, es, em)
    CALL CD_AGG_GetMovingPointMesh(agg, sp, sv, sa, f, es, em, moment=mo)
    CALL CD_AGG_CalcOutput(agg_b, es, em)
    CALL CD_AGG_GetMovingPointMesh(agg_b, sp, sv, sa, fb, es, em, moment=mb)
    WRITE (*, '(A,ES10.3)') 'CoupledPinned body restart overlay: |node force difference| before the next step = ', &
      nan_max_abs(f - fb)
    CALL require(nan_max_abs(f - fb) <= 0.0_wp .AND. nan_max_abs(mo - mb) <= 0.0_wp, &
                 'restart:bit-identical loads of the restored state before the next step')
    err = 0.0_wp
    DO step = 42, 70
      CALL host_columns(host_surge(REAL(step, wp)*DT), p0, p, v, a)
      CALL CD_AGG_Step_Moving(agg, DT, p, v, a, cv, st, it, es, em, t_committed=REAL(step, wp)*DT)
      CALL CD_AGG_Step_Moving(agg_b, DT, p, v, a, cv, st, it, es, em, t_committed=REAL(step, wp)*DT)
      CALL require(es == CD_AGG_OK, 'restart:march: '//TRIM(em))
      CALL CD_AGG_CalcOutput(agg, es, em)
      CALL CD_AGG_GetMovingPointMesh(agg, sp, sv, sa, f, es, em, moment=mo)
      CALL CD_AGG_CalcOutput(agg_b, es, em)
      CALL CD_AGG_GetMovingPointMesh(agg_b, sp, sv, sa, fb, es, em, moment=mb)
      err = MAX(err, nan_max_abs(f - fb), nan_max_abs(mo - mb))
    END DO
    CALL CD_AGG_Get_Rigid6_States(agg, bs, es, em)
    CALL CD_AGG_Get_Rigid6_States(agg_b, bs2, es, em)
    WRITE (*, '(A,ES10.3,A,ES10.3)') 'CoupledPinned body restart overlay: max |load difference| over 29 steps = ', &
      err, '; body state ', nan_max_abs(bs - bs2)
    CALL require(err <= 0.0_wp .AND. nan_max_abs(bs - bs2) <= 0.0_wp, 'restart:bit-identical continuation')
    CALL CD_AGG_End(agg_b, es, em)
    CALL CD_AGG_End(agg, es, em)
    CALL CD_AGG_End(twin, es, em)
  END SUBROUTINE case_state

  ! --------------------------------------------------------------------------------------------- !
  ! 7: PtfmInit and the static initial condition                                                  !
  ! --------------------------------------------------------------------------------------------- !

  SUBROUTINE case_ptfm_static()
    !! PtfmInit (surge 1 m, sway 0.5 m, yaw 10 deg) moves the node and turns the tethered body with
    !! the platform (deck pose: the body frame is M^T R0); with bodyIC static the body is then
    !! turned about the displaced node, held, against the now unequal tethers until the moment
    !! about the node of its weight, buoyancy and tethers vanishes. Its CG and both tethers lie on
    !! one body axis through the node, so the spin about that axis is neutral.
    TYPE(CD_AGG_ModuleType) :: agg
    REAL(wp), ALLOCATABLE :: p(:, :), v(:, :), a(:, :), f(:, :), mo(:, :), l(:)
    REAL(wp) :: ptfm(6), dcm(3, 3), node(3), s(24), rot(3, 3), mom(3), c(3), arm(3), fsc, tilt
    INTEGER :: es, n, ib, ic
    CHARACTER(512) :: em

    ptfm = [1.0_wp, 0.5_wp, 0.0_wp, 0.0_wp, 0.0_wp, 10.0_wp*PI/180.0_wp]
    dcm = 0.0_wp
    dcm(1, 1) = COS(ptfm(6))
    dcm(1, 2) = SIN(ptfm(6))
    dcm(2, 1) = -SIN(ptfm(6))
    dcm(2, 2) = COS(ptfm(6))
    dcm(3, 3) = 1.0_wp
    node = ptfm(1:3) + MATMUL(TRANSPOSE(dcm), [0.0_wp, 0.0_wp, -10.0_wp])
    DO ic = 1, 2
      IF (ic == 1) THEN
        CALL write_tethered_deck('pinbody_ptfm.dat', 'deck')
      ELSE
        CALL write_tethered_deck('pinbody_ptfm.dat', 'static')
      END IF
      CALL CD_AGG_Init_From_Deck(agg, 'pinbody_ptfm.dat', 0.02_wp, es, em, ptfm_init=ptfm)
      CALL require(es == CD_AGG_OK, 'ptfm:init: '//TRIM(em))
      IF (es /= CD_AGG_OK) RETURN
      n = CD_AGG_NMovingPoints(agg, es, em)
      IF (.NOT. ALLOCATED(p)) ALLOCATE (p(3, n), v(3, n), a(3, n), f(3, n), mo(3, n))
      CALL CD_AGG_CalcOutput(agg, es, em)
      CALL CD_AGG_GetMovingPointMesh(agg, p, v, a, f, es, em, moment=mo)
      CALL CD_AGG_Get_Rigid6_States(agg, s, es, em)
      rot = RESHAPE(s(16:24), [3, 3])
      CALL require(nan_max_abs(p(:, n) - node) <= 1.0e-12_wp .AND. nan_max_abs(s(1:3) - node) <= 1.0e-12_wp, &
                   'ptfm:node and reference point at the displaced pin')
      IF (ic == 1) THEN
        WRITE (*, '(A,ES10.3,A,ES10.3)') 'PtfmInit, deck pose: |node - displaced pin| ', nan_max_abs(p(:, n) - node), &
          '; |R - M^T R0| ', nan_max_abs(rot - TRANSPOSE(dcm))
        CALL require(nan_max_abs(rot - TRANSPOSE(dcm)) <= 1.0e-12_wp, 'ptfm:the body turns with the platform')
      ELSE
        arm = -2.0_wp*rot(:, 3)
        c = -1.0_wp*rot(:, 3)
        ib = coupled_block(agg, s(1:3) + arm)
        CALL require(ib > 0, 'ptfm:the tether end is a coupled point')
        IF (ib == 0) RETURN
        l = line_loads(agg)
        mom = cross(c, [0.0_wp, 0.0_wp, (RHO*0.0628_wp - 100.0_wp)*G]) + cross(arm, l(3*ib - 2:3*ib))
        fsc = 2.0_wp*MAX(100.0_wp*G, nan_max_abs(l(3*ib - 2:3*ib)))
        tilt = ACOS(MIN(1.0_wp, rot(3, 3)))
        WRITE (*, '(A,F8.4,A,ES10.3,A,ES10.3)') 'PtfmInit + static IC: body tilted ', tilt, &
          ' rad; |moment about the node| / (arm max(mg, |f|)) ', nan_max_abs(mom)/fsc, '; |omega| ', &
          nan_max_abs(s(10:12))
        CALL require(tilt > 1.0e-3_wp, 'ptfm:the static solve turned the body')
        CALL require(nan_max_abs(mom) <= 1.0e-6_wp*fsc, 'ptfm:net moment about the node vanishes')
      END IF
      CALL require(nan_max_abs(mo(:, n)) <= 0.0_wp, 'ptfm:no node moment')
      CALL CD_AGG_End(agg, es, em)
    END DO
  END SUBROUTINE case_ptfm_static

  ! --------------------------------------------------------------------------------------------- !
  ! 8: sub-stepping and the ignored node rotation                                                 !
  ! --------------------------------------------------------------------------------------------- !

  SUBROUTINE case_substep()
    !! The tethered body's stiff mode (about 38 rad/s) makes omega dt about 3.8 at a 0.1 s
    !! coupling step, beyond the explicit limit of 2: the march must sub-cycle it. Against a run at
    !! the sub-step size, a node drifting at constant velocity (which the linear interpolation of
    !! the node motion inside a step represents exactly) gives the same body motion and node force.
    !! The node orientation and angular rates do not reach the body.
    TYPE(CD_AGG_ModuleType) :: coarse, fine, turned
    REAL(wp), PARAMETER :: DTC = 0.1_wp
    INTEGER, PARAMETER :: NSUB = 10, NC = 40
    REAL(wp), ALLOCATABLE :: angc(:), tc(:), angf(:), tf(:), fc(:, :), ff(:, :), sc(:, :), sf(:, :)
    REAL(wp), ALLOCATABLE :: p(:, :), v(:, :), a(:, :), f(:, :), p0(:, :), orr(:, :, :), w(:, :), al(:, :)
    REAL(wp) :: err_s, err_f, famp, samp, bs(24), bs2(24), th, err
    INTEGER :: es, i, n, step, it
    LOGICAL :: ok, cv, st
    CHARACTER(512) :: em

    CALL write_tethered_deck('pinbody_tether.dat', 'deck')
    ALLOCATE (angc(0:NC), tc(0:NC), angf(0:NC*NSUB), tf(0:NC*NSUB), fc(3, 0:NC), ff(3, 0:NC*NSUB))
    ALLOCATE (sc(24, 0:NC), sf(24, 0:NC*NSUB))
    CALL CD_AGG_Init_From_Deck(coarse, 'pinbody_tether.dat', DTC, es, em)
    CALL require(es == CD_AGG_OK, 'substep:coarse-init: '//TRIM(em))
    IF (es /= CD_AGG_OK) RETURN
    CALL CD_AGG_Init_From_Deck(fine, 'pinbody_tether.dat', DTC/REAL(NSUB, wp), es, em)
    CALL require(es == CD_AGG_OK, 'substep:fine-init: '//TRIM(em))
    IF (es /= CD_AGG_OK) RETURN
    CALL march(coarse, DTC, NC, host_drift, angc, tc, ok, force=fc, states=sc)
    CALL require(ok, 'substep:coarse march finite (the stiff mode is sub-cycled)')
    CALL march(fine, DTC/REAL(NSUB, wp), NC*NSUB, host_drift, angf, tf, ok, force=ff, states=sf)
    CALL require(ok, 'substep:fine march finite')
    IF (.NOT. ok) RETURN
    err_s = 0.0_wp
    err_f = 0.0_wp
    DO i = 0, NC
      err_s = MAX(err_s, nan_max_abs(sc(10:24, i) - sf(10:24, NSUB*i)))
      err_f = MAX(err_f, nan_max_abs(fc(:, i) - ff(:, NSUB*i)))
    END DO
    famp = nan_max_abs(ff)
    samp = nan_max_abs(sf(10:12, :))
    WRITE (*, '(A,ES10.3,A,ES10.3,A,ES10.3,A,ES10.3)') 'sub-cycled coarse step vs sub-step run: rotation state ', &
      err_s, ' (|omega| up to ', samp, '); node force ', err_f, ' of ', famp
    CALL require(samp > 1.0e-3_wp, 'substep:the drift turns the body')
    CALL require(err_s <= 1.0e-8_wp*MAX(1.0_wp, samp) .AND. err_f <= 1.0e-8_wp*famp, &
                 'substep:drifting node: coarse equals fine')
    CALL CD_AGG_End(fine, es, em)
    CALL CD_AGG_End(coarse, es, em)

    ! the node orientation and angular rates do not reach a CoupledPinned body
    CALL CD_AGG_Init_From_Deck(turned, 'pinbody_tether.dat', DTC, es, em)
    CALL CD_AGG_Init_From_Deck(fine, 'pinbody_tether.dat', DTC, es, em)
    n = CD_AGG_NMovingPoints(turned, es, em)
    ALLOCATE (p(3, n), v(3, n), a(3, n), f(3, n), p0(3, n), orr(3, 3, n), w(3, n), al(3, n))
    CALL CD_AGG_GetMovingPointMesh(turned, p0, v, a, f, es, em)
    err = 0.0_wp
    DO step = 0, 20
      CALL host_columns(host_surge(REAL(step, wp)*DTC), p0, p, v, a)
      th = 0.3_wp*SIN(REAL(step, wp))
      orr = 0.0_wp
      DO i = 1, n
        orr(1, 1, i) = COS(th)
        orr(1, 3, i) = -SIN(th)
        orr(2, 2, i) = 1.0_wp
        orr(3, 1, i) = SIN(th)
        orr(3, 3, i) = COS(th)
      END DO
      w = 0.0_wp
      al = 0.0_wp
      w(2, :) = 0.3_wp*COS(REAL(step, wp))
      al(2, :) = -0.3_wp*SIN(REAL(step, wp))
      IF (step == 0) THEN
        CALL CD_AGG_UpdateStates_Moving(turned, p, v, a, es, em, orientation=orr, angular_velocity=w, &
                                        angular_acceleration=al)
        CALL CD_AGG_UpdateStates_Moving(fine, p, v, a, es, em)
      ELSE
        CALL CD_AGG_Step_Moving(turned, DTC, p, v, a, cv, st, it, es, em, t_committed=REAL(step, wp)*DTC, &
                                orientation=orr, angular_velocity=w, angular_acceleration=al)
        CALL require(es == CD_AGG_OK, 'orient:turned step: '//TRIM(em))
        CALL CD_AGG_Step_Moving(fine, DTC, p, v, a, cv, st, it, es, em, t_committed=REAL(step, wp)*DTC)
      END IF
      CALL CD_AGG_Get_Rigid6_States(turned, bs, es, em)
      CALL CD_AGG_Get_Rigid6_States(fine, bs2, es, em)
      err = MAX(err, nan_max_abs(bs - bs2))
    END DO
    CALL require(err <= 0.0_wp, 'orient:node orientation and rates ignored by the pinned body')
    CALL CD_AGG_End(turned, es, em)
    CALL CD_AGG_End(fine, es, em)
  END SUBROUTINE case_substep

  ! --------------------------------------------------------------------------------------------- !
  ! 9: beside a Coupled body                                                                      !
  ! --------------------------------------------------------------------------------------------- !

  SUBROUTINE case_mixed_hosts()
    !! The pendulum deck with a Coupled body (body 2, at (0, 10, -2), on its own line) added after
    !! it: the host nodes follow the deck BODY order (the pinned body's node, then the Coupled
    !! body's 6-DOF node), and with every node held the pendulum swings as it does alone (its lines
    !! are independent of the Coupled body's) while the Coupled body returns a finite wrench.
    TYPE(CD_AGG_ModuleType) :: alone, mixed
    REAL(wp), PARAMETER :: DT = 0.01_wp
    REAL(wp), ALLOCATABLE :: p(:, :), v(:, :), a(:, :), f(:, :), mo(:, :), pa(:, :), fa(:, :)
    REAL(wp) :: sa(24), sm(48), err
    CHARACTER(512) :: rows(200), line
    INTEGER :: es, n, na, step, it, u, ios, nr, i
    LOGICAL :: cv, st
    CHARACTER(512) :: em

    CALL write_pendulum_deck('pinbody_alone.dat', 25.0_wp)
    nr = 0
    OPEN (NEWUNIT=u, FILE='pinbody_alone.dat', STATUS='OLD', ACTION='READ')
    DO
      READ (u, '(A)', IOSTAT=ios) line
      IF (ios /= 0) EXIT
      nr = nr + 1
      rows(nr) = line
    END DO
    CLOSE (u)
    OPEN (NEWUNIT=u, FILE='pinbody_mixed.dat', STATUS='REPLACE', ACTION='WRITE')
    DO i = 1, nr
      WRITE (u, '(A)') TRIM(rows(i))
      IF (INDEX(rows(i), '1 CoupledPinned') == 1) &
        WRITE (u, '(A)') '2 Coupled 0.0 10.0 -2.0 0.0 0.0 0.0 200.0 0.0|0.0|0.0 30.0 0.1 0.0 0.0'
      IF (INDEX(rows(i), '2 Coupled 4.0') == 1) THEN
        WRITE (u, '(A)') '3 Body2 1.0 0.0 0.0 0 0 0 0'
        WRITE (u, '(A)') '4 Fixed 8.0 10.0 -8.0 0 0 0 0'
      END IF
      IF (TRIM(rows(i)) == '1 1 2 -') WRITE (u, '(A)') '2 3 4 -'
      IF (TRIM(rows(i)) == '1 line 9.5 6') WRITE (u, '(A)') '2 line 9.5 6'
    END DO
    CLOSE (u)
    CALL CD_AGG_Init_From_Deck(alone, 'pinbody_alone.dat', DT, es, em)
    CALL CD_AGG_Init_From_Deck(mixed, 'pinbody_mixed.dat', DT, es, em)
    CALL require(es == CD_AGG_OK, 'mixed:init: '//TRIM(em))
    IF (es /= CD_AGG_OK) RETURN
    n = CD_AGG_NMovingPoints(mixed, es, em)
    na = CD_AGG_NMovingPoints(alone, es, em)
    CALL require(n == 3 .AND. na == 2 .AND. CD_AGG_Rigid6_MirrorSize(mixed) == 48, 'mixed:layout')
    IF (n /= 3) RETURN
    ALLOCATE (p(3, n), v(3, n), a(3, n), f(3, n), mo(3, n), pa(3, na), fa(3, na))
    CALL CD_AGG_GetMovingPointMesh(mixed, p, v, a, f, es, em)
    CALL CD_AGG_GetMovingPointMesh(alone, pa, v(:, 1:na), a(:, 1:na), fa, es, em)
    CALL require(nan_max_abs(p(:, 2) - [0.0_wp, 0.0_wp, ZPIN]) <= 0.0_wp .AND. &
                 nan_max_abs(p(:, 3) - [0.0_wp, 10.0_wp, -2.0_wp]) <= 0.0_wp, 'mixed:host nodes in deck BODY order')
    v = 0.0_wp
    a = 0.0_wp
    err = 0.0_wp
    DO step = 1, 300
      CALL CD_AGG_Step_Moving(mixed, DT, p, v, a, cv, st, it, es, em, t_committed=REAL(step, wp)*DT)
      CALL require(es == CD_AGG_OK .AND. cv, 'mixed:step: '//TRIM(em))
      IF (es /= CD_AGG_OK) RETURN
      CALL CD_AGG_Step_Moving(alone, DT, pa, v(:, 1:na), a(:, 1:na), cv, st, it, es, em, &
                              t_committed=REAL(step, wp)*DT)
      CALL CD_AGG_Get_Rigid6_States(mixed, sm, es, em)
      CALL CD_AGG_Get_Rigid6_States(alone, sa, es, em)
      err = MAX(err, nan_max_abs(sm(1:24) - sa))
    END DO
    CALL CD_AGG_CalcOutput(mixed, es, em)
    CALL CD_AGG_GetMovingPointMesh(mixed, p, v, a, f, es, em, moment=mo)
    WRITE (*, '(A,ES10.3,A,ES10.3)') 'beside a Coupled body: pendulum state vs alone ', err, &
      '; Coupled body moment ', nan_max_abs(mo(:, 3))
    CALL require(err <= 1.0e-12_wp, 'mixed:the pinned body moves as alone')
    CALL require(ALL(IEEE_IS_FINITE(f)) .AND. nan_max_abs(mo(:, 3)) > 0.0_wp .AND. nan_max_abs(mo(:, 2)) <= 0.0_wp, &
                 'mixed:a moment at the Coupled node only')
    CALL CD_AGG_End(alone, es, em)
    CALL CD_AGG_End(mixed, es, em)
  END SUBROUTINE case_mixed_hosts

  ! --------------------------------------------------------------------------------------------- !
  ! 10: the shell's state-mirror restore before the first step                                    !
  ! --------------------------------------------------------------------------------------------- !

  SUBROUTINE case_shell_start()
    !! The OpenFAST shell evaluates its outputs at t = 0 before the first step and restores the
    !! state mirror afterwards, which marks every object's acceleration committed. The mirror must
    !! then already carry the start accelerations (solved at Init): with every node held, each deck
    !! (out of balance at its deck pose) marches bit for bit with and without that restore.
    CHARACTER(32) :: deck(6)
    INTEGER :: k
    CALL write_pendulum_deck('pinbody_shell1.dat', 30.0_wp)
    CALL write_symmetric_deck('pinbody_shell2.dat', free_body=.TRUE.)
    CALL write_arm_deck('pinbody_shell3.dat', .TRUE., 'deck', rod_type='Free')
    CALL write_arm_deck('pinbody_shell4.dat', .TRUE., 'deck', rod_type='Pinned')
    CALL write_arm_deck('pinbody_shell5.dat', .TRUE., 'deck')
    CALL write_arm_deck('pinbody_shell6.dat', .FALSE., 'deck')
    deck = ['pinbody_shell1.dat', 'pinbody_shell2.dat', 'pinbody_shell3.dat', 'pinbody_shell4.dat', &
            'pinbody_shell5.dat', 'pinbody_shell6.dat']
    DO k = 1, 6
      CALL shell_start_one(TRIM(deck(k)), k >= 3 .AND. k <= 5, k == 2)
    END DO
  END SUBROUTINE case_shell_start

  SUBROUTINE shell_start_one(path, rod, extf)
      !! One deck of case_shell_start: rod selects the rod mirror, extf the host fluid field.
    CHARACTER(*), INTENT(IN) :: path
    LOGICAL, INTENT(IN) :: rod, extf
    REAL(wp), PARAMETER :: DT = 0.01_wp
    TYPE(CD_AGG_ModuleType) :: direct, shell
    REAL(wp), ALLOCATABLE :: p(:, :), v(:, :), a(:, :), f(:, :), ms(:), s1(:), s2(:)
    REAL(wp) :: err, amp, w0
    INTEGER :: es, n, step, it, nm
    LOGICAL :: cv, st
    CHARACTER(512) :: em
    CALL CD_AGG_Init_From_Deck(direct, path, DT, es, em, external_fluid=extf)
    CALL CD_AGG_Init_From_Deck(shell, path, DT, es, em, external_fluid=extf)
    CALL require(es == CD_AGG_OK, 'shell-start:init '//path//': '//TRIM(em))
    IF (es /= CD_AGG_OK) RETURN
    n = CD_AGG_NMovingPoints(shell, es, em)
    IF (rod) THEN
      nm = CD_AGG_Rod_MirrorSize(shell)
    ELSE
      nm = CD_AGG_Rigid6_MirrorSize(shell)
    END IF
    ALLOCATE (p(3, n), v(3, n), a(3, n), f(3, n), ms(nm), s1(nm), s2(nm))
    ! the shell's output call at t = 0: evaluate, then restore the state mirror
    CALL CD_AGG_CalcOutput(shell, es, em)
    CALL CD_AGG_GetMovingPointMesh(shell, p, v, a, f, es, em)
    IF (rod) THEN
      CALL CD_AGG_Get_Rod_States(shell, ms, es, em)
      CALL CD_AGG_Set_Rod_States(shell, ms, es, em)
    ELSE
      CALL CD_AGG_Get_Rigid6_States(shell, ms, es, em)
      CALL CD_AGG_Set_Rigid6_States(shell, ms, es, em)
    END IF
    CALL require(es == CD_AGG_OK, 'shell-start:mirror '//path//': '//TRIM(em))
    v = 0.0_wp
    a = 0.0_wp
    err = 0.0_wp
    amp = 0.0_wp
    w0 = 0.0_wp
    DO step = 1, 100
      CALL CD_AGG_Step_Moving(direct, DT, p, v, a, cv, st, it, es, em, t_committed=REAL(step, wp)*DT)
      CALL CD_AGG_Step_Moving(shell, DT, p, v, a, cv, st, it, es, em, t_committed=REAL(step, wp)*DT)
      CALL require(es == CD_AGG_OK, 'shell-start:step '//path//': '//TRIM(em))
      IF (es /= CD_AGG_OK) RETURN
      IF (rod) THEN
        CALL CD_AGG_Get_Rod_States(direct, s1, es, em)
        CALL CD_AGG_Get_Rod_States(shell, s2, es, em)
      ELSE
        CALL CD_AGG_Get_Rigid6_States(direct, s1, es, em)
        CALL CD_AGG_Get_Rigid6_States(shell, s2, es, em)
      END IF
      IF (step == 1) w0 = MAXVAL(ABS([s1(4:6), s1(10:12)]))
      err = MAX(err, nan_max_abs(s1 - s2))
      amp = MAX(amp, nan_max_abs(s1))
    END DO
    WRITE (*, '(A,A,A,ES10.3,A,ES10.3)') 'shell order (mirror restore at t = 0), ', path, &
      ': |state difference| ', err, '; first-step velocity ', w0
    CALL require(w0 > 0.0_wp, 'shell-start:the deck starts out of balance '//path)
    CALL require(err <= 0.0_wp, 'shell-start:the restore keeps the start acceleration '//path)
    CALL CD_AGG_End(direct, es, em)
    CALL CD_AGG_End(shell, es, em)
  END SUBROUTINE shell_start_one

  ! --------------------------------------------------------------------------------------------- !
  ! 11: refusals                                                                                   !
  ! --------------------------------------------------------------------------------------------- !

  SUBROUTINE case_refusals()
    TYPE(CD_AGG_ModuleType) :: agg
    REAL(wp) :: cp(3, 2)
    INTEGER :: es
    LOGICAL :: conv
    CHARACTER(1024) :: em

    ! a standalone deck has no host to move the node
    CALL write_pendulum_deck('pinbody_standalone.dat', 10.0_wp, standalone=.TRUE.)
    CALL CD_Run_Deck_Driver('pinbody_standalone.dat', 'pinbody_standalone', conv, es, em)
    CALL require(es /= CD_DECKDRV_OK .AND. INDEX(em, 'CoupledPinned/VesselPinned BODY requires a coupled host') > 0, &
                 'refusal:standalone: '//TRIM(em))
    ! the linearisation probe holds every body
    CALL write_pendulum_deck('pinbody_probe_pos.dat', 0.0_wp)
    cp(:, 1) = [4.0_wp, 0.0_wp, 12.0_wp]
    cp(:, 2) = [0.0_wp, 0.0_wp, ZPIN]
    CALL CD_AGG_Init_From_Deck(agg, 'pinbody_probe_pos.dat', 0.01_wp, es, em, coupled_positions=cp)
    CALL require(es /= CD_AGG_OK .AND. INDEX(em, 'Coupled/Vessel or CoupledPinned BODIES') > 0, &
                 'refusal:coupled_positions: '//TRIM(em))
    CALL CD_AGG_End(agg, es, em)
    ! its rotation is integrated: the inertias must be positive
    CALL write_symmetric_deck('pinbody_noinertia.dat')
    CALL write_zero_inertia('pinbody_noinertia.dat')
    CALL CD_AGG_Init_From_Deck(agg, 'pinbody_noinertia.dat', 0.01_wp, es, em, external_fluid=.TRUE.)
    CALL require(es /= CD_AGG_OK .AND. INDEX(em, 'requires Ixx/Iyy/Izz > 0') > 0, 'refusal:inertia: '//TRIM(em))
    CALL CD_AGG_End(agg, es, em)
    ! MoorDyn-F's inertialF: CableDyn always returns the inertia (inertialF 1, accepted); 0 and 2
    ! are refused by name
    CALL write_pendulum_deck('pinbody_inertialf.dat', 0.0_wp)
    CALL add_option_row('pinbody_inertialf.dat', '1 inertialF')
    CALL CD_AGG_Init_From_Deck(agg, 'pinbody_inertialf.dat', 0.01_wp, es, em)
    CALL require(es == CD_AGG_OK, 'refusal:inertialF 1 is accepted: '//TRIM(em))
    CALL CD_AGG_End(agg, es, em)
    CALL write_pendulum_deck('pinbody_inertialf.dat', 0.0_wp)
    CALL add_option_row('pinbody_inertialf.dat', '0 inertialF')
    CALL CD_AGG_Init_From_Deck(agg, 'pinbody_inertialf.dat', 0.01_wp, es, em)
    CALL require(es /= CD_AGG_OK .AND. INDEX(em, 'inertialF 0 (MoorDyn-F''s default') > 0, &
                 'refusal:inertialF 0: '//TRIM(em))
    CALL CD_AGG_End(agg, es, em)
  END SUBROUTINE case_refusals

  SUBROUTINE add_option_row(path, row)
    !! Insert an OPTIONS row before the end marker of a deck.
    CHARACTER(*), INTENT(IN) :: path, row
    CHARACTER(512) :: rows(200), line
    INTEGER :: u, ios, n, i
    n = 0
    OPEN (NEWUNIT=u, FILE=path, STATUS='OLD', ACTION='READ')
    DO
      READ (u, '(A)', IOSTAT=ios) line
      IF (ios /= 0) EXIT
      n = n + 1
      rows(n) = line
    END DO
    CLOSE (u)
    OPEN (NEWUNIT=u, FILE=path, STATUS='REPLACE', ACTION='WRITE')
    DO i = 1, n
      IF (TRIM(rows(i)) == '--- end ---') WRITE (u, '(A)') row
      WRITE (u, '(A)') TRIM(rows(i))
    END DO
    CLOSE (u)
  END SUBROUTINE add_option_row

  SUBROUTINE write_zero_inertia(path)
    !! The symmetric deck with a 15-column BODIES row (no inertias) for its VesselPinned body.
    CHARACTER(*), INTENT(IN) :: path
    CHARACTER(512), ALLOCATABLE :: rows(:)
    CHARACTER(512) :: line
    INTEGER :: u, ios, n, i
    ALLOCATE (rows(200))
    n = 0
    OPEN (NEWUNIT=u, FILE=path, STATUS='OLD', ACTION='READ')
    DO
      READ (u, '(A)', IOSTAT=ios) line
      IF (ios /= 0) EXIT
      n = n + 1
      rows(n) = line
      IF (INDEX(line, '1 VesselPinned') == 1) rows(n) = '1 VesselPinned 0.0 0.0 -5.0 0.0 0.0 0.0 200.0 0.1 0.0 0.0 '// &
                                                        '0.0 0.0 0.5'
    END DO
    CLOSE (u)
    OPEN (NEWUNIT=u, FILE=path, STATUS='REPLACE', ACTION='WRITE')
    DO i = 1, n
      WRITE (u, '(A)') TRIM(rows(i))
    END DO
    CLOSE (u)
  END SUBROUTINE write_zero_inertia

  ! --------------------------------------------------------------------------------------------- !
  ! 12: start accelerations in the host's fluid field                                             !
  ! --------------------------------------------------------------------------------------------- !

  SUBROUTINE write_fluid_deck(path, rod)
    !! A submerged Free object on two taut, nearly massless lines (0.01 kg/m, EA 1e5 N) without
    !! hydrodynamic coefficients (their end forces neither see the field nor add inertia) to
    !! anchors at x = +-40 m on the 50 m seabed: rod a horizontal
    !! Free rod (6 m, 0.5 m diameter, 200 kg/m, Cd 1.2, Ca 1) at z = -20 m, else a Free Rigid6
    !! body (5000 kg, 4 m^3, CdA 6 m^2, Ca 0.8, CG at the reference point) there with its line
    !! points 3 m out along x. Released at its deck pose (out of balance).
    CHARACTER(*), INTENT(IN) :: path
    LOGICAL, INTENT(IN) :: rod
    INTEGER :: u
    OPEN (NEWUNIT=u, FILE=path, STATUS='REPLACE', ACTION='WRITE')
    WRITE (u, '(A)') 'Free object in a host fluid field'
    WRITE (u, '(A)') '--- LINE TYPES ---'
    WRITE (u, '(A)') 'Name Diam Mass EA BA EI Cdn Cdt Can Cat'
    WRITE (u, '(A)') '(-) (m) (kg/m) (N) (-) (Nm2) (-) (-) (-) (-)'
    WRITE (u, '(A)') 'dry 0.002 0.01 1.0e5 0.0 0.0 0.0 0.0 0.0 0.0'
    IF (rod) THEN
      WRITE (u, '(A)') '--- ROD TYPES ---'
      WRITE (u, '(A)') 'Name Diam Mass Cd Ca CdEnd CaEnd'
      WRITE (u, '(A)') '(-) (m) (kg/m) (-) (-) (-) (-)'
      WRITE (u, '(A)') 'arm 0.5 200.0 1.2 1.0 0 0'
      WRITE (u, '(A)') '--- RODS ---'
      WRITE (u, '(A)') 'ID RodType Type XA YA ZA XB YB ZB NumSegs Outputs'
      WRITE (u, '(A)') '(-) (-) (-) (m) (m) (m) (m) (m) (m) (-) (-)'
      WRITE (u, '(A)') '1 arm Free -3.0 0.0 -20.0 3.0 0.0 -20.0 6 -'
    ELSE
      WRITE (u, '(A)') '--- BODIES ---'
      WRITE (u, '(A)') 'ID Type X Y Z Rot1 Rot2 Rot3 Mass Vol C33 C44 C55 CdA Ca Ixx Iyy Izz'
      WRITE (u, '(A)') '(-) (-) (m) (m) (m) (deg) (deg) (deg) (kg) (m3) (N/m) (Nm/rad) (Nm/rad) (m2) (-) '// &
        '(kgm2) (kgm2) (kgm2)'
      WRITE (u, '(A,ES24.16,1X,ES24.16,A,ES24.16,1X,ES24.16,A)') '1 Rigid6 0.0 0.0 -20.0 0.0 0.0 0.0 ', FB_M, &
        FB_V, ' 0.0 0.0 0.0 ', FB_CDA, FB_CA, ' 1.0e4 1.0e4 1.0e4'
    END IF
    WRITE (u, '(A)') '--- POINTS ---'
    WRITE (u, '(A)') 'ID Type X Y Z Mass Vol CdA Ca'
    WRITE (u, '(A)') '(-) (-) (m) (m) (m) (kg) (m3) (m2) (-)'
    IF (.NOT. rod) THEN
      WRITE (u, '(A)') '1 Body1 3.0 0.0 0.0 0 0 0 0'
      WRITE (u, '(A)') '2 Body1 -3.0 0.0 0.0 0 0 0 0'
    END IF
    WRITE (u, '(A)') '3 Fixed 40.0 0.0 -50.0 0 0 0 0'
    WRITE (u, '(A)') '4 Fixed -40.0 0.0 -50.0 0 0 0 0'
    WRITE (u, '(A)') '--- LINES ---'
    WRITE (u, '(A)') 'ID NodeA NodeB Outputs'
    WRITE (u, '(A)') '(-) (-) (-) (-)'
    IF (rod) THEN
      WRITE (u, '(A)') '1 R1B 3 -'
      WRITE (u, '(A)') '2 R1A 4 -'
    ELSE
      WRITE (u, '(A)') '1 1 3 -'
      WRITE (u, '(A)') '2 2 4 -'
    END IF
    WRITE (u, '(A)') '--- SECTIONS ---'
    WRITE (u, '(A)') 'LineID LineType Length NumSegs'
    WRITE (u, '(A)') '(-) (-) (m) (-)'
    WRITE (u, '(A)') '1 dry 47.0 10'
    WRITE (u, '(A)') '2 dry 47.0 10'
    CALL write_options(u, 50.0_wp, 'deck')
    CLOSE (u)
  END SUBROUTINE write_fluid_deck

  SUBROUTINE set_field(agg, u_c, a_c)
    !! The uniform host field u_c, a_c at every fluid node, the free surface at z = 0.
    TYPE(CD_AGG_ModuleType), INTENT(INOUT) :: agg
    REAL(wp), INTENT(IN) :: u_c(3), a_c(3)
    REAL(wp), ALLOCATABLE :: uf(:, :), af(:, :), wz(:)
    INTEGER :: nf, es, i
    CHARACTER(512) :: em
    nf = CD_AGG_NFluidNodes(agg, es, em)
    ALLOCATE (uf(3, nf), af(3, nf), wz(nf))
    DO i = 1, nf
      uf(:, i) = u_c
      af(:, i) = a_c
    END DO
    wz = 0.0_wp
    CALL CD_AGG_SetFluidFields(agg, uf, af, wz, es, em)
    CALL require(es == CD_AGG_OK, 'fluid-start:the host field is accepted: '//TRIM(em))
  END SUBROUTINE set_field

  SUBROUTINE get_mirror(agg, rod, s)
    TYPE(CD_AGG_ModuleType), INTENT(INOUT) :: agg
    LOGICAL, INTENT(IN) :: rod
    REAL(wp), INTENT(OUT) :: s(:)
    INTEGER :: es
    CHARACTER(512) :: em
    IF (rod) THEN
      CALL CD_AGG_Get_Rod_States(agg, s, es, em)
    ELSE
      CALL CD_AGG_Get_Rigid6_States(agg, s, es, em)
    END IF
  END SUBROUTINE get_mirror

  SUBROUTINE case_fluid_start(path, rod)
    !! Gate 12 for one deck (rod: the Free rod, else the Free Rigid6 body). Every run in the field
    !! holds FS_U, FS_A and takes FS_NSTEP steps; the mirror after them is compared.
    CHARACTER(*), INTENT(IN) :: path
    LOGICAL, INTENT(IN) :: rod
    TYPE(CD_AGG_ModuleType) :: still, direct, oracle, shell, rewound, drag_only
    REAL(wp), ALLOCATABLE :: p(:, :), v(:, :), a(:, :), f(:, :)
    REAL(wp) :: s_still(24), s_dir(24), s_or(24), s_sh(24), s_rw(24)
    REAL(wp) :: s0(24), s1(24), da(3), da_o(3), ms(24), err_drag
    INTEGER :: es, n, it
    LOGICAL :: cv, st
    CHARACTER(512) :: em

    CALL write_fluid_deck(path, rod)
    CALL CD_AGG_Init_From_Deck(still, path, FS_DT, es, em, external_fluid=.TRUE.)
    CALL require(es == CD_AGG_OK, 'fluid-start:init '//path//': '//TRIM(em))
    IF (es /= CD_AGG_OK) RETURN
    CALL CD_AGG_Init_From_Deck(direct, path, FS_DT, es, em, external_fluid=.TRUE.)
    CALL CD_AGG_Init_From_Deck(oracle, path, FS_DT, es, em, external_fluid=.TRUE.)
    CALL CD_AGG_Init_From_Deck(shell, path, FS_DT, es, em, external_fluid=.TRUE.)
    CALL CD_AGG_Init_From_Deck(rewound, path, FS_DT, es, em, external_fluid=.TRUE.)
    n = CD_AGG_NMovingPoints(still, es, em)
    CALL require(n == 0, 'fluid-start:no host node '//path)
    ALLOCATE (p(3, n), v(3, n), a(3, n), f(3, n))
    p = 0.0_wp
    v = 0.0_wp
    a = 0.0_wp
    ! the body: the start acceleration in a current over the still-water one, against the drag
    IF (.NOT. rod) THEN
      CALL CD_AGG_Init_From_Deck(drag_only, path, FS_DT, es, em, external_fluid=.TRUE.)
      CALL get_mirror(drag_only, rod, s0)
      CALL set_field(drag_only, FS_U, [0.0_wp, 0.0_wp, 0.0_wp])
      CALL get_mirror(drag_only, rod, s1)
      da = s1(7:9) - s0(7:9)
      da_o = 0.5_wp*RHO*FB_CDA*NORM2(FS_U)*FS_U/(FB_M + RHO*FB_V*FB_CA)
      err_drag = NORM2(da - da_o)/NORM2(da_o)
      WRITE (*, '(A,3ES14.6,A,ES10.3)') 'start acceleration in a current, Free body: change ', da, &
        ' m/s^2, against the drag over the effective mass ', err_drag
      CALL require(err_drag <= 1.0e-5_wp, 'fluid-start:the body starts from its acceleration in the current')
      CALL require(MAXVAL(ABS(s1(13:15) - s0(13:15))) <= 1.0e-12_wp*MAX(1.0_wp, MAXVAL(ABS(s0(13:15)))), &
                   'fluid-start:the drag at the reference point turns nothing')
      CALL CD_AGG_End(drag_only, es, em)
    END IF
    ! still water
    CALL march_in_field(still, .FALSE., path, p, v, a)
    CALL get_mirror(still, rod, s_still)
    ! the host's field, then the steps
    CALL set_field(direct, FS_U, FS_A)
    CALL march_in_field(direct, .FALSE., path, p, v, a)
    CALL get_mirror(direct, rod, s_dir)
    ! the oracle: the field, then a committed step-start transfer solves the start accelerations
    CALL set_field(oracle, FS_U, FS_A)
    CALL CD_AGG_UpdateStates_Moving(oracle, p, v, a, es, em)
    CALL require(es == CD_AGG_OK, 'fluid-start:step-start transfer: '//TRIM(em))
    CALL march_in_field(oracle, .FALSE., path, p, v, a)
    CALL get_mirror(oracle, rod, s_or)
    ! the OpenFAST shell: the t = 0 field at Init, the output call and its mirror restore, the
    ! field of the step's end before the step
    CALL set_field(shell, FS_U, FS_A)
    CALL CD_AGG_CalcOutput(shell, es, em)
    CALL CD_AGG_GetMovingPointMesh(shell, p, v, a, f, es, em)
    CALL get_mirror(shell, rod, ms)
    IF (rod) THEN
      CALL CD_AGG_Set_Rod_States(shell, ms, es, em)
    ELSE
      CALL CD_AGG_Set_Rigid6_States(shell, ms, es, em)
    END IF
    CALL require(es == CD_AGG_OK, 'fluid-start:mirror restore: '//TRIM(em))
    CALL march_in_field(shell, .TRUE., path, p, v, a)
    CALL get_mirror(shell, rod, s_sh)
    ! a correction rewind of the first step to the snapshot before it, then the field and the steps
    ! again
    CALL CD_AGG_Snapshot(rewound, es, em)
    CALL set_field(rewound, FS_U, FS_A)
    CALL CD_AGG_Step_Moving(rewound, FS_DT, p, v, a, cv, st, it, es, em, t_committed=FS_DT)
    CALL require(es == CD_AGG_OK .AND. cv, 'fluid-start:first step before the rewind: '//TRIM(em))
    CALL CD_AGG_Restore(rewound, es, em)
    CALL require(es == CD_AGG_OK, 'fluid-start:rewind: '//TRIM(em))
    CALL set_field(rewound, FS_U, FS_A)
    CALL march_in_field(rewound, .FALSE., path, p, v, a)
    CALL get_mirror(rewound, rod, s_rw)
    WRITE (*, '(A,A,A,ES10.3,A,3ES10.3)') 'start in the host field, ', path, ': field vs still water ', &
      nan_max_abs(s_dir - s_still), '; vs the transfer-solved start: direct, shell order, rewind ', &
      nan_max_abs(s_dir - s_or), nan_max_abs(s_sh - s_or), nan_max_abs(s_rw - s_or)
    CALL require(nan_max_abs(s_dir - s_still) > 1.0e-6_wp, 'fluid-start:the field changes the first steps '//path)
    CALL require(nan_max_abs(s_dir - s_or) <= 0.0_wp, &
                 'fluid-start:SetFluidFields then Step starts from the accelerations in the field '//path)
    CALL require(nan_max_abs(s_sh - s_or) <= 0.0_wp, 'fluid-start:the shell order starts from them '//path)
    CALL require(nan_max_abs(s_rw - s_or) <= 0.0_wp, 'fluid-start:a rewind before the first step too '//path)
    CALL CD_AGG_End(still, es, em)
    CALL CD_AGG_End(direct, es, em)
    CALL CD_AGG_End(oracle, es, em)
    CALL CD_AGG_End(shell, es, em)
    CALL CD_AGG_End(rewound, es, em)
  END SUBROUTINE case_fluid_start

  SUBROUTINE march_in_field(agg, refresh, path, p, v, a)
    !! FS_NSTEP steps of gate 12 with the host node set (p, v, a) held; refresh sets the field
    !! again before each step, as the shell samples it at every step's end.
    TYPE(CD_AGG_ModuleType), INTENT(INOUT) :: agg
    LOGICAL, INTENT(IN) :: refresh
    CHARACTER(*), INTENT(IN) :: path
    REAL(wp), INTENT(IN) :: p(:, :), v(:, :), a(:, :)
    INTEGER :: step, it, es
    LOGICAL :: cv, st
    CHARACTER(512) :: em
    DO step = 1, FS_NSTEP
      IF (refresh) CALL set_field(agg, FS_U, FS_A)
      CALL CD_AGG_Step_Moving(agg, FS_DT, p, v, a, cv, st, it, es, em, t_committed=REAL(step, wp)*FS_DT)
      CALL require(es == CD_AGG_OK .AND. cv, 'fluid-start:step '//path//': '//TRIM(em))
      IF (es /= CD_AGG_OK) RETURN
    END DO
  END SUBROUTINE march_in_field

END PROGRAM test_openfast_pinned_body
