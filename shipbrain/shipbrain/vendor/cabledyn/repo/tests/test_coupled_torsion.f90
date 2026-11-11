! File: tests/test_coupled_torsion.f90
! SPDX-License-Identifier: Apache-2.0
! Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
PROGRAM test_coupled_torsion
  !! Condensed torsion of a finite-EI line on the coupled OpenFAST route: the aggregate surface
  !! the OpenFAST and FAST.Farm shells drive, built with host_orientation. The line is the
  !! straight 100 m neutral line of test_torsion_deck (GJ 5e4 N m^2, both ends clamped and
  !! restrained in torsion, no pretwist), its End A on the platform fairlead (0, 0, -50) and
  !! End B on a fixed anchor. Rolling the platform by phi about the line axis (+x) twists the
  !! line by -phi: Twist1 = -phi and, with a negligible polar inertia (Irn 1e-9: the quasi-static
  !! limit of the nodal twist), Torq = GJ (-phi) / L.
  !!   1. feedthrough: a non-stepping update with a rolled orientation twists the end element
  !!      alone against the frozen interior (as the coupled end's translation stretches it):
  !!      Twist1 = -phi, Torq = GJ (-phi) / l_e at the fairlead and 0 at the anchor until the next
  !!      step, and the fairlead moment is that restoring torque about the line axis;
  !!   2. march: the platform rolls at 60 deg/s; every step gives Twist1 = -phi(t) and the
  !!      quasi-static torque (the coupled twin of the standalone vessel-roll gate), and the
  !!      single-cable entry driven with the same calls gives the same values bit for bit;
  !!   3. unwrapping: 1.5 turns of roll in 18 deg steps, with no 2 pi slip;
  !!   4. rewind: snapshot, step, restore and the same step again are bit-identical;
  !!   5. a non-stepping turn of more than pi/2 fails by name and leaves the state unchanged;
  !!   6. ptfm_init: an initial platform yaw over a vertical line hanging under the fairlead
  !!      (End A on the yaw axis) gives the static twist +yaw (a turn of -yaw about the line
  !!      direction A to B, -z);
  !!   7. restart: the shell's checkpoint recipe (rebuild, torsion mirror first, coupled
  !!      kinematics, full mirror) after 150 deg of roll continues bit-identically; without the
  !!      torsion mirror first the coupled update is refused (the pi/2 bound);
  !!   8. FAST.Farm: the vertical torsion line under Turbine2 with a farm_ptfm_init yaw gives
  !!      the static twist and follows that turbine's yaw.
  USE CableDyn_Precision, ONLY: wp
  USE CableDyn_DeckDriver, ONLY: CD_Init_Deck_HermiteCable, CD_DECKDRV_OK
  USE CableDyn_OpenFAST_Aggregate, ONLY: CD_AGG_ModuleType, CD_AGG_Init_From_Deck, CD_AGG_NMovingPoints, &
                                         CD_AGG_GetMovingPointMesh, CD_AGG_UpdateStates_Moving, &
                                         CD_AGG_Step_Moving, CD_AGG_CalcOutput, CD_AGG_Snapshot, CD_AGG_Restore, &
                                         CD_AGG_EvalChannel, CD_AGG_End, CD_AGG_OK
  USE CableDyn_OpenFAST_HermiteFMF, ONLY: CD_HFMF_ModuleType, CD_HFMF_UpdateStates, CD_HFMF_CalcOutput, &
                                          CD_HFMF_MirrorSize, CD_HFMF_PackMirror, CD_HFMF_UnpackMirror, &
                                          CD_HFMF_End, CD_HFMF_OK
  USE, INTRINSIC :: IEEE_ARITHMETIC, ONLY: IEEE_IS_FINITE
  IMPLICIT NONE

  REAL(wp), PARAMETER :: PI = 3.14159265358979323846_wp, RHOW = 1025.0_wp
  REAL(wp), PARAMETER :: GJ = 5.0e4_wp, L = 100.0_wp, DT = 0.05_wp, DEG = PI/180.0_wp
  INTEGER :: n_fail = 0
  CHARACTER(160) :: neutral_type

  ! neutral 0.2 m section: mass = rhoW pi d^2 / 4; EA 1e7, EI 1e6, GAs 1e8, GJ 5e4, Irn 1e-9 (the
  ! quasi-static torsion these gates check: the nodal twist's limit of a negligible polar inertia,
  ! whose inertia test_nodal_twist_dynamic gates)
  WRITE (neutral_type, '(A,ES24.16,A)') 'cab 0.2 ', RHOW*0.25_wp*PI*0.04_wp, &
    ' 1.0e7 0.0 1.0e6 1.0e8 5.0e4 1.0 1.0e-9 0.0 0.0 0.0 0.0'

  CALL check_feedthrough()
  CALL check_march()
  CALL check_unwrap()
  CALL check_rewind()
  CALL check_large_turn_refused()
  CALL check_ptfm_init()
  CALL check_restart()
  CALL check_farm()
  IF (n_fail > 0) THEN
    WRITE (*, '(A,I0,A)') 'FAIL: ', n_fail, ' coupled torsion check(s) failed'
    ERROR STOP 1
  END IF
  WRITE (*, '(A)') 'PASS: coupled torsion (feedthrough, march, unwrapping, rewind, refusal, PtfmInit, '// &
    'restart, FAST.Farm)'

CONTAINS

  INCLUDE 'nan_max_abs.inc'

  SUBROUTINE require(cond, msg)
    LOGICAL, INTENT(IN) :: cond
    CHARACTER(*), INTENT(IN) :: msg
    IF (.NOT. cond) THEN
      n_fail = n_fail + 1
      WRITE (*, '(A,A)') 'FAILED: ', msg
    END IF
  END SUBROUTINE require

  SUBROUTINE write_deck(path, point_a, vertical, anchor_x)
    !! The straight neutral torsion line, End A on point_a, outputs Torq1N1, Torq1N41, Twist1:
    !! along +x from (0, 0, -50) to (100, 0, -50), or with vertical from (0, 0, -20) down to
    !! (anchor_x, 0, -120.5) (anchor_x: the farm-global x of the turbine the line hangs under).
    !! The vertical line is held taut at 0.5 % strain: at zero tension its static solve has no
    !! catenary seed and its result depends on round-off (it failed with OpenBLAS's Prescott
    !! kernels).
    CHARACTER(*), INTENT(IN) :: path, point_a
    LOGICAL, INTENT(IN), OPTIONAL :: vertical
    REAL(wp), INTENT(IN), OPTIONAL :: anchor_x
    INTEGER :: u
    LOGICAL :: vert
    REAL(wp) :: ax
    CHARACTER(48) :: anchor
    vert = .FALSE.
    IF (PRESENT(vertical)) vert = vertical
    ax = 0.0_wp
    IF (PRESENT(anchor_x)) ax = anchor_x
    anchor = '2 Fixed 100.0 0.0 -50.0 0 0 0 0'
    IF (vert) WRITE (anchor, '(A,F8.1,A)') '2 Fixed ', ax, ' 0.0 -120.5 0 0 0 0'
    OPEN (NEWUNIT=u, FILE=path, STATUS='REPLACE', ACTION='WRITE')
    WRITE (u, '(A)') 'coupled torsion gate'
    WRITE (u, '(A)') '--- LINE TYPES ---'
    WRITE (u, '(A)') 'Name Diam Mass EA BA EI GAs GJ Irt Irn Cdn Cdt Can Cat'
    WRITE (u, '(A)') '(-) (m) (kg/m) (N) (-) (Nm2) (N) (Nm2) (kgm) (kgm) (-) (-) (-) (-)'
    WRITE (u, '(A)') TRIM(neutral_type)
    WRITE (u, '(A)') '--- POINTS ---'
    WRITE (u, '(A)') 'ID Type X Y Z Mass Vol CdA Ca'
    WRITE (u, '(A)') '(-) (-) (m) (m) (m) (kg) (m3) (m2) (-)'
    IF (vert) THEN
      WRITE (u, '(A)') '1 '//point_a//' 0.0 0.0 -20.0 0 0 0 0'
    ELSE
      WRITE (u, '(A)') '1 '//point_a//' 0.0 0.0 -50.0 0 0 0 0'
    END IF
    WRITE (u, '(A)') TRIM(anchor)
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
    IF (vert) THEN
      WRITE (u, '(A)') '1 A Rigid 0 0 -1 Rigid 1 0 0 0'
      WRITE (u, '(A)') '1 B Rigid 0 0 -1 Rigid 1 0 0 0'
    ELSE
      WRITE (u, '(A)') '1 A Rigid 1 0 0 Rigid 0 0 1 0'
      WRITE (u, '(A)') '1 B Rigid 1 0 0 Rigid 0 0 1 0'
    END IF
    WRITE (u, '(A)') '--- OPTIONS ---'
    WRITE (u, '(A)') '9.80665 g'
    WRITE (u, '(A)') '1025.0 rhoW'
    WRITE (u, '(A)') '0.05 dtM'
    WRITE (u, '(A)') '--- OUTPUTS ---'
    WRITE (u, '(A)') 'Torq1N1'
    WRITE (u, '(A)') 'Torq1N41'
    WRITE (u, '(A)') 'Twist1'
    WRITE (u, '(A)') '--- END ---'
    CLOSE (u)
  END SUBROUTINE write_deck

  FUNCTION roll_dcm(phi) RESULT(r)
    !! OpenFAST mesh orientation (global to local) of a roll phi about +x.
    REAL(wp), INTENT(IN) :: phi
    REAL(wp) :: r(3, 3)
    r = 0.0_wp
    r(1, 1) = 1.0_wp
    r(2, 2) = COS(phi)
    r(2, 3) = SIN(phi)
    r(3, 2) = -SIN(phi)
    r(3, 3) = COS(phi)
  END FUNCTION roll_dcm

  FUNCTION yaw_dcm(psi) RESULT(r)
    !! OpenFAST mesh orientation (global to local) of a yaw psi about +z.
    REAL(wp), INTENT(IN) :: psi
    REAL(wp) :: r(3, 3)
    r = 0.0_wp
    r(3, 3) = 1.0_wp
    r(1, 1) = COS(psi)
    r(1, 2) = SIN(psi)
    r(2, 1) = -SIN(psi)
    r(2, 2) = COS(psi)
  END FUNCTION yaw_dcm

  SUBROUTINE channels(agg, torq_a, torq_b, twist)
    TYPE(CD_AGG_ModuleType), INTENT(INOUT) :: agg
    REAL(wp), INTENT(OUT) :: torq_a, torq_b, twist
    INTEGER :: es
    CHARACTER(256) :: em
    CALL CD_AGG_EvalChannel(agg, 1, torq_a, es, em)
    CALL require(es == CD_AGG_OK, 'Torq1N1 evaluates: '//TRIM(em))
    CALL CD_AGG_EvalChannel(agg, 2, torq_b, es, em)
    CALL require(es == CD_AGG_OK, 'Torq1N41 evaluates: '//TRIM(em))
    CALL CD_AGG_EvalChannel(agg, 3, twist, es, em)
    CALL require(es == CD_AGG_OK, 'Twist1 evaluates: '//TRIM(em))
  END SUBROUTINE channels

  SUBROUTINE init_agg(agg, path, ok)
    TYPE(CD_AGG_ModuleType), INTENT(INOUT) :: agg
    CHARACTER(*), INTENT(IN) :: path
    LOGICAL, INTENT(OUT) :: ok
    INTEGER :: es, nmp
    CHARACTER(512) :: em
    CALL CD_AGG_Init_From_Deck(agg, path, DT, es, em, host_orientation=.TRUE.)
    ok = es == CD_AGG_OK
    CALL require(ok, 'coupled torsion deck builds on the aggregate: '//TRIM(em))
    IF (ok) THEN
      nmp = CD_AGG_NMovingPoints(agg, es, em)
      ok = agg%ncable == 1 .AND. nmp == 1
      CALL require(ok, 'the deck is one coupled cable with one moving point')
    END IF
  END SUBROUTINE init_agg

  ! ------------------------------------------------------------------------------------------
  SUBROUTINE check_feedthrough()
    TYPE(CD_AGG_ModuleType) :: agg
    REAL(wp) :: pos(3, 1), vel(3, 1), acc(3, 1), load(3, 1), moment(3, 1), orient(3, 3, 1)
    REAL(wp) :: ta, tb, tw, phi, m_ref
    INTEGER :: es
    LOGICAL :: ok
    CHARACTER(512) :: em
    CALL write_deck('ctors_feed.dat', 'Coupled')
    CALL init_agg(agg, 'ctors_feed.dat', ok)
    IF (.NOT. ok) RETURN
    CALL channels(agg, ta, tb, tw)
    CALL require(ABS(ta) <= 1.0e-6_wp .AND. ABS(tw) <= 1.0e-9_wp, '1: no pretwist, no torque at rest')
    CALL CD_AGG_GetMovingPointMesh(agg, pos, vel, acc, load, es, em, orientation=orient, moment=moment)
    phi = 20.0_wp*DEG
    orient(:, :, 1) = roll_dcm(phi)
    CALL CD_AGG_UpdateStates_Moving(agg, pos, vel, acc, es, em, orientation=orient)
    CALL require(es == CD_AGG_OK, '1: a rolled orientation is accepted: '//TRIM(em))
    CALL CD_AGG_CalcOutput(agg, es, em)
    CALL channels(agg, ta, tb, tw)
    ! the end element (of 40) takes the roll
    m_ref = GJ*(-phi)/(L/40.0_wp)
    WRITE (*, '(A,3ES15.7,A,ES15.7)') '1 feedthrough: Torq A/B, Twist ', ta, tb, tw, '; ref torque ', m_ref
    CALL require(ABS(tw + 20.0_wp) <= 1.0e-6_wp, '1: Twist1 = -roll')
    CALL require(ABS(ta - m_ref) <= 1.0e-6_wp*ABS(m_ref) .AND. ABS(tb) <= 1.0e-9_wp*ABS(m_ref), &
                 '1: Torq = GJ (-roll) / l_e at the fairlead, 0 at the anchor (the frozen interior)')
    CALL CD_AGG_GetMovingPointMesh(agg, pos, vel, acc, load, es, em, moment=moment)
    WRITE (*, '(A,3ES15.7)') '1 feedthrough: fairlead moment ', moment(:, 1)
    CALL require(ABS(ABS(moment(1, 1)) - ABS(m_ref)) <= 1.0e-6_wp*ABS(m_ref), &
                 '1: the fairlead moment about the line axis is the torque')
    CALL require(moment(1, 1)*phi < 0.0_wp, '1: the moment on the platform resists its roll')
    CALL require(MAX(ABS(moment(2, 1)), ABS(moment(3, 1))) <= 1.0e-6_wp*ABS(m_ref), &
                 '1: a straight line returns no bending moment')
    CALL CD_AGG_End(agg, es, em)
  END SUBROUTINE check_feedthrough

  ! ------------------------------------------------------------------------------------------
  SUBROUTINE check_march()
    !! 60 deg/s roll for 10 steps; the single-cable entry driven with the same calls must match.
    REAL(wp), PARAMETER :: RATE = 60.0_wp*DEG
    TYPE(CD_AGG_ModuleType) :: agg
    TYPE(CD_HFMF_ModuleType) :: cab
    REAL(wp) :: pos(3, 1), vel(3, 1), acc(3, 1), load(3, 1), moment(3, 1), orient(3, 3, 1)
    REAL(wp) :: omega(3, 1), alpha(3, 1), ta, tb, tw, phi, terr, werr, derr
    REAL(wp) :: f_cab(3), m_cab(3)
    INTEGER :: es, ni, k, node
    LOGICAL :: ok, cv, st
    CHARACTER(512) :: em
    CALL write_deck('ctors_march.dat', 'Coupled')
    CALL init_agg(agg, 'ctors_march.dat', ok)
    IF (.NOT. ok) RETURN
    CALL CD_Init_Deck_HermiteCable('ctors_march.dat', DT, cab, node, es, em, host_orientation=.TRUE.)
    CALL require(es == CD_DECKDRV_OK, '2: the single-cable entry builds: '//TRIM(em))
    IF (es /= CD_DECKDRV_OK) RETURN
    CALL CD_AGG_GetMovingPointMesh(agg, pos, vel, acc, load, es, em, orientation=orient)
    omega = 0.0_wp
    alpha = 0.0_wp
    omega(1, 1) = RATE
    terr = 0.0_wp
    werr = 0.0_wp
    derr = 0.0_wp
    DO k = 1, 10
      phi = RATE*DT*k
      orient(:, :, 1) = roll_dcm(phi)
      CALL CD_AGG_Step_Moving(agg, DT, pos, vel, acc, cv, st, ni, es, em, orientation=orient, &
                              angular_velocity=omega, angular_acceleration=alpha)
      CALL require(es == CD_AGG_OK .AND. cv, '2: rolling step converges: '//TRIM(em))
      IF (es /= CD_AGG_OK) EXIT
      CALL CD_AGG_CalcOutput(agg, es, em)
      CALL channels(agg, ta, tb, tw)
      werr = MAX(werr, ABS(tw + phi/DEG))
      terr = MAX(terr, ABS(ta - GJ*(-phi)/L), ABS(tb - ta))
      CALL CD_HFMF_UpdateStates(cab, pos(:, 1), vel(:, 1), acc(:, 1), es, em, u_orientation=orient(:, :, 1), &
                                u_angular_velocity=omega(:, 1), u_angular_acceleration=alpha(:, 1))
      CALL require(es == CD_HFMF_OK, '2: the single cable steps: '//TRIM(em))
      CALL CD_AGG_GetMovingPointMesh(agg, pos, vel, acc, load, es, em, moment=moment)
      CALL CD_HFMF_CalcOutput(cab, f_cab, es, em, y_moment=m_cab)
      derr = MAX(derr, nan_max_abs(agg%cables(1)%line%q - cab%line%q), nan_max_abs(load(:, 1) - f_cab), &
                 nan_max_abs(moment(:, 1) - m_cab), &
                 ABS(agg%cables(1)%line%torsion%theta - cab%line%torsion%theta))
    END DO
    WRITE (*, '(A,ES10.3,A,ES10.3,A,ES10.3)') '2 march: Twist1 error ', werr, ' deg, torque error ', terr, &
      ' N m; aggregate vs single cable ', derr
    CALL require(werr <= 1.0e-6_wp, '2: Twist1 = -roll(t) at every step')
    CALL require(terr <= 1.0e-6_wp*GJ, '2: Torq = GJ Twist / L at both ends at every step (quasi-static)')
    CALL require(derr <= 0.0_wp, '2: the aggregate column equals the single coupled cable bit for bit')
    CALL CD_HFMF_End(cab)
    CALL CD_AGG_End(agg, es, em)
  END SUBROUTINE check_march

  ! ------------------------------------------------------------------------------------------
  SUBROUTINE check_unwrap()
    !! 1.5 turns of roll in 18 deg steps (30 steps).
    TYPE(CD_AGG_ModuleType) :: agg
    REAL(wp) :: pos(3, 1), vel(3, 1), acc(3, 1), load(3, 1), orient(3, 3, 1), omega(3, 1), alpha(3, 1)
    REAL(wp) :: ta, tb, tw, phi, werr
    INTEGER :: es, ni, k
    LOGICAL :: ok, cv, st
    CHARACTER(512) :: em
    CALL write_deck('ctors_unwrap.dat', 'Coupled')
    CALL init_agg(agg, 'ctors_unwrap.dat', ok)
    IF (.NOT. ok) RETURN
    CALL CD_AGG_GetMovingPointMesh(agg, pos, vel, acc, load, es, em, orientation=orient)
    omega = 0.0_wp
    alpha = 0.0_wp
    omega(1, 1) = 18.0_wp*DEG/DT
    werr = 0.0_wp
    DO k = 1, 30
      phi = 18.0_wp*DEG*k
      orient(:, :, 1) = roll_dcm(phi)
      CALL CD_AGG_Step_Moving(agg, DT, pos, vel, acc, cv, st, ni, es, em, orientation=orient, &
                              angular_velocity=omega, angular_acceleration=alpha)
      CALL require(es == CD_AGG_OK .AND. cv, '3: 18 deg roll step converges: '//TRIM(em))
      IF (es /= CD_AGG_OK) EXIT
      CALL CD_AGG_CalcOutput(agg, es, em)
      CALL channels(agg, ta, tb, tw)
      werr = MAX(werr, ABS(tw + 18.0_wp*k), ABS(ta - GJ*(-phi)/L)/GJ)
    END DO
    WRITE (*, '(A,F9.3,A,ES10.3)') '3 unwrap: final Twist1 ', tw, ' deg (ref -540), max error ', werr
    CALL require(werr <= 1.0e-6_wp, '3: 1.5 turns of roll unwrap without a 2 pi slip')
    CALL CD_AGG_End(agg, es, em)
  END SUBROUTINE check_unwrap

  ! ------------------------------------------------------------------------------------------
  SUBROUTINE check_rewind()
    TYPE(CD_AGG_ModuleType) :: agg
    REAL(wp) :: pos(3, 1), vel(3, 1), acc(3, 1), load(3, 1), orient(3, 3, 1), omega(3, 1), alpha(3, 1)
    REAL(wp) :: moment(3, 1), m1(3), m2(3), th1, th2, tw1, tw2, ta, tb
    REAL(wp), ALLOCATABLE :: qa(:), qb(:)
    INTEGER :: es, ni
    LOGICAL :: ok, cv, st
    CHARACTER(512) :: em
    CALL write_deck('ctors_rewind.dat', 'Coupled')
    CALL init_agg(agg, 'ctors_rewind.dat', ok)
    IF (.NOT. ok) RETURN
    CALL CD_AGG_GetMovingPointMesh(agg, pos, vel, acc, load, es, em, orientation=orient)
    omega = 0.0_wp
    alpha = 0.0_wp
    omega(1, 1) = 30.0_wp*DEG/DT
    orient(:, :, 1) = roll_dcm(30.0_wp*DEG)
    CALL CD_AGG_Snapshot(agg, es, em)
    CALL require(es == CD_AGG_OK, '4: snapshot: '//TRIM(em))
    CALL CD_AGG_Step_Moving(agg, DT, pos, vel, acc, cv, st, ni, es, em, orientation=orient, &
                            angular_velocity=omega, angular_acceleration=alpha)
    CALL require(es == CD_AGG_OK .AND. cv, '4: first step: '//TRIM(em))
    CALL CD_AGG_CalcOutput(agg, es, em)
    CALL CD_AGG_GetMovingPointMesh(agg, pos, vel, acc, load, es, em, moment=moment)
    qa = agg%cables(1)%line%q
    m1 = moment(:, 1)
    th1 = agg%cables(1)%line%torsion%theta
    CALL channels(agg, ta, tb, tw1)
    CALL CD_AGG_Restore(agg, es, em)
    CALL require(es == CD_AGG_OK, '4: restore: '//TRIM(em))
    CALL require(ABS(agg%cables(1)%line%torsion%theta) <= 1.0e-12_wp, '4: restore rewinds the twist')
    CALL CD_AGG_Step_Moving(agg, DT, pos, vel, acc, cv, st, ni, es, em, orientation=orient, &
                            angular_velocity=omega, angular_acceleration=alpha)
    CALL require(es == CD_AGG_OK .AND. cv, '4: repeated step: '//TRIM(em))
    CALL CD_AGG_CalcOutput(agg, es, em)
    CALL CD_AGG_GetMovingPointMesh(agg, pos, vel, acc, load, es, em, moment=moment)
    qb = agg%cables(1)%line%q
    m2 = moment(:, 1)
    th2 = agg%cables(1)%line%torsion%theta
    CALL channels(agg, ta, tb, tw2)
    CALL require(nan_max_abs(qa - qb) <= 0.0_wp .AND. nan_max_abs(m1 - m2) <= 0.0_wp .AND. &
                 ABS(th1 - th2) <= 0.0_wp .AND. ABS(tw1 - tw2) <= 0.0_wp, &
                 '4: snapshot, step, restore, step is bit-identical (state, twist, torque moment)')
    CALL CD_AGG_End(agg, es, em)
  END SUBROUTINE check_rewind

  ! ------------------------------------------------------------------------------------------
  SUBROUTINE check_large_turn_refused()
    TYPE(CD_AGG_ModuleType) :: agg
    REAL(wp) :: pos(3, 1), vel(3, 1), acc(3, 1), load(3, 1), orient(3, 3, 1)
    REAL(wp) :: th0, ta, tb, tw
    REAL(wp), ALLOCATABLE :: q0(:)
    INTEGER :: es
    LOGICAL :: ok
    CHARACTER(512) :: em
    CALL write_deck('ctors_large.dat', 'Coupled')
    CALL init_agg(agg, 'ctors_large.dat', ok)
    IF (.NOT. ok) RETURN
    CALL CD_AGG_GetMovingPointMesh(agg, pos, vel, acc, load, es, em, orientation=orient)
    q0 = agg%cables(1)%line%q
    th0 = agg%cables(1)%line%torsion%theta
    orient(:, :, 1) = roll_dcm(100.0_wp*DEG)
    CALL CD_AGG_UpdateStates_Moving(agg, pos, vel, acc, es, em, orientation=orient)
    WRITE (*, '(A,A)') '5 large turn: ', TRIM(em)
    CALL require(es /= CD_AGG_OK .AND. INDEX(em, 'pi/2') > 0, '5: a 100 deg non-stepping turn is refused by name')
    CALL require(nan_max_abs(agg%cables(1)%line%q - q0) <= 0.0_wp .AND. &
                 ABS(agg%cables(1)%line%torsion%theta - th0) <= 0.0_wp, '5: the refused update changes no state')
    CALL channels(agg, ta, tb, tw)
    CALL require(ABS(tw) <= 1.0e-9_wp, '5: the twist is still zero after the refusal')
    CALL CD_AGG_End(agg, es, em)
  END SUBROUTINE check_large_turn_refused

  ! ------------------------------------------------------------------------------------------
  SUBROUTINE check_ptfm_init()
    !! ptfm_init yaws the platform about the vertical axis through the origin, which carries the
    !! vertical line's fairlead (0, 0, -20) onto itself: only its frame turns.
    TYPE(CD_AGG_ModuleType) :: agg
    REAL(wp) :: ta, tb, tw, psi
    INTEGER :: es
    CHARACTER(512) :: em
    psi = 15.0_wp*DEG
    CALL write_deck('ctors_ptfm.dat', 'Coupled', vertical=.TRUE.)
    CALL CD_AGG_Init_From_Deck(agg, 'ctors_ptfm.dat', DT, es, em, ptfm_init=[0.0_wp, 0.0_wp, 0.0_wp, 0.0_wp, &
                                                                             0.0_wp, psi], host_orientation=.TRUE.)
    CALL require(es == CD_AGG_OK, '6: the torsion deck builds at a yawed initial platform pose: '//TRIM(em))
    IF (es /= CD_AGG_OK) RETURN
    CALL channels(agg, ta, tb, tw)
    WRITE (*, '(A,F10.5,A,ES15.7,A,ES15.7)') '6 PtfmInit yaw 15 deg: Twist1 ', tw, ', Torq ', ta, '; ref ', &
      GJ*psi/L
    CALL require(ABS(tw - 15.0_wp) <= 1.0e-5_wp, '6: the static twist is +PtfmInit yaw')
    CALL require(ABS(ta - GJ*psi/L) <= 1.0e-5_wp*GJ*psi/L, '6: the static torque is GJ yaw / L')
    CALL CD_AGG_End(agg, es, em)
  END SUBROUTINE check_ptfm_init

  ! ------------------------------------------------------------------------------------------
  SUBROUTINE check_restart()
    !! Reference A rolls 150 deg in 15 deg steps, then 4 more steps. B is rebuilt from A's
    !! mirror at 150 deg with the shell's recipe and steps the same 4 steps.
    TYPE(CD_AGG_ModuleType) :: a, b
    REAL(wp) :: pos(3, 1), vel(3, 1), acc(3, 1), load(3, 1), orient(3, 3, 1), omega(3, 1), alpha(3, 1)
    REAL(wp) :: ta, tb, twa, twb, tqa, tqb, phi, t
    REAL(wp), ALLOCATABLE :: mirror(:)
    INTEGER :: es, ni, k, nm
    LOGICAL :: ok, cv, st, same
    CHARACTER(512) :: em
    CALL write_deck('ctors_restart.dat', 'Coupled')
    CALL init_agg(a, 'ctors_restart.dat', ok)
    IF (.NOT. ok) RETURN
    CALL CD_AGG_GetMovingPointMesh(a, pos, vel, acc, load, es, em, orientation=orient)
    omega = 0.0_wp
    alpha = 0.0_wp
    omega(1, 1) = 15.0_wp*DEG/DT
    DO k = 1, 10
      orient(:, :, 1) = roll_dcm(15.0_wp*DEG*k)
      CALL CD_AGG_Step_Moving(a, DT, pos, vel, acc, cv, st, ni, es, em, orientation=orient, &
                              angular_velocity=omega, angular_acceleration=alpha)
      CALL require(es == CD_AGG_OK .AND. cv, '7: reference roll step: '//TRIM(em))
      IF (es /= CD_AGG_OK) RETURN
    END DO
    t = DT*10
    nm = CD_HFMF_MirrorSize(a%cables(1))
    ALLOCATE (mirror(nm))
    CALL CD_HFMF_PackMirror(a%cables(1), mirror, es, em)
    CALL require(es == CD_HFMF_OK, '7: pack the checkpoint mirror: '//TRIM(em))
    ! the previous order (coupled kinematics before the mirror) is refused by the pi/2 bound
    CALL init_agg(b, 'ctors_restart.dat', ok)
    IF (.NOT. ok) RETURN
    CALL CD_AGG_UpdateStates_Moving(b, pos, vel, acc, es, em, orientation=orient, angular_velocity=omega, &
                                    angular_acceleration=alpha)
    CALL require(es /= CD_AGG_OK .AND. INDEX(em, 'pi/2') > 0, &
                 '7: kinematics at 150 deg before the torsion mirror are refused (the old rebuild order)')
    CALL CD_AGG_End(b, es, em)
    ! the shell's recipe: torsion mirror, coupled kinematics, full mirror
    CALL init_agg(b, 'ctors_restart.dat', ok)
    IF (.NOT. ok) RETURN
    CALL CD_HFMF_UnpackMirror(b%cables(1), mirror, t, es, em)
    CALL require(es == CD_HFMF_OK, '7: torsion mirror first: '//TRIM(em))
    CALL CD_AGG_UpdateStates_Moving(b, pos, vel, acc, es, em, orientation=orient, angular_velocity=omega, &
                                    angular_acceleration=alpha)
    CALL require(es == CD_AGG_OK, '7: coupled kinematics at the restart pose: '//TRIM(em))
    CALL CD_HFMF_UnpackMirror(b%cables(1), mirror, t, es, em)
    CALL require(es == CD_HFMF_OK, '7: full mirror: '//TRIM(em))
    same = .TRUE.
    DO k = 11, 14
      phi = 15.0_wp*DEG*k
      orient(:, :, 1) = roll_dcm(phi)
      CALL CD_AGG_Step_Moving(a, DT, pos, vel, acc, cv, st, ni, es, em, orientation=orient, &
                              angular_velocity=omega, angular_acceleration=alpha)
      CALL require(es == CD_AGG_OK .AND. cv, '7: reference continues: '//TRIM(em))
      CALL CD_AGG_Step_Moving(b, DT, pos, vel, acc, cv, st, ni, es, em, orientation=orient, &
                              angular_velocity=omega, angular_acceleration=alpha)
      CALL require(es == CD_AGG_OK .AND. cv, '7: restarted run continues: '//TRIM(em))
      CALL channels(a, tqa, ta, twa)
      CALL channels(b, tqb, tb, twb)
      same = same .AND. nan_max_abs(a%cables(1)%line%q - b%cables(1)%line%q) <= 0.0_wp .AND. &
             ABS(tqa - tqb) <= 0.0_wp .AND. ABS(twa - twb) <= 0.0_wp
    END DO
    WRITE (*, '(A,F10.4,A,F10.4)') '7 restart: Twist1 reference ', twa, ', restarted ', twb
    CALL require(same, '7: the restarted run continues bit-identically through the twist')
    CALL require(ABS(twa + 210.0_wp) <= 1.0e-6_wp, '7: the continued twist is -210 deg')
    CALL CD_AGG_End(a, es, em)
    CALL CD_AGG_End(b, es, em)
  END SUBROUTINE check_restart

  ! ------------------------------------------------------------------------------------------
  SUBROUTINE check_farm()
    !! Two turbines 500 m apart; the vertical torsion line hangs under Turbine2.
    TYPE(CD_AGG_ModuleType) :: agg
    REAL(wp) :: ref_pos(3, 2), farm_init(6, 2), ta, tb, tw, psi
    REAL(wp), ALLOCATABLE :: pos(:, :), vel(:, :), acc(:, :), load(:, :), orient(:, :, :)
    INTEGER :: es, ncp
    CHARACTER(512) :: em
    psi = 10.0_wp*DEG
    CALL write_deck('ctors_farm.dat', 'Turbine2', vertical=.TRUE., anchor_x=500.0_wp)
    ref_pos = 0.0_wp
    ref_pos(1, 2) = 500.0_wp
    farm_init = 0.0_wp
    farm_init(6, 2) = psi
    CALL CD_AGG_Init_From_Deck(agg, 'ctors_farm.dat', DT, es, em, n_turbines=2, turbine_ref_pos=ref_pos, &
                               farm_ptfm_init=farm_init, forbid_deck_ambient=.TRUE., host_orientation=.TRUE.)
    CALL require(es == CD_AGG_OK, '8: the farm deck with a torsion line on Turbine2 builds: '//TRIM(em))
    IF (es /= CD_AGG_OK) RETURN
    CALL channels(agg, ta, tb, tw)
    WRITE (*, '(A,F10.5,A,ES15.7)') '8 farm: Turbine2 yaw 10 deg: Twist1 ', tw, ', Torq ', ta
    CALL require(ABS(tw - 10.0_wp) <= 1.0e-5_wp, '8: the static twist is the yaw of Turbine2')
    CALL require(ABS(ta - GJ*psi/L) <= 1.0e-5_wp*GJ*psi/L, '8: the static torque is GJ yaw / L')
    ncp = CD_AGG_NMovingPoints(agg, es, em)
    ALLOCATE (pos(3, ncp), vel(3, ncp), acc(3, ncp), load(3, ncp), orient(3, 3, ncp))
    CALL CD_AGG_GetMovingPointMesh(agg, pos, vel, acc, load, es, em, orientation=orient)
    orient(:, :, ncp) = yaw_dcm(psi + 20.0_wp*DEG)
    CALL CD_AGG_UpdateStates_Moving(agg, pos, vel, acc, es, em, orientation=orient)
    CALL require(es == CD_AGG_OK, '8: Turbine2 turns its fairlead: '//TRIM(em))
    CALL channels(agg, ta, tb, tw)
    CALL require(ABS(tw - 30.0_wp) <= 1.0e-5_wp, '8: the twist follows Turbine2 to 30 deg')
    CALL CD_AGG_End(agg, es, em)
  END SUBROUTINE check_farm

END PROGRAM test_coupled_torsion
