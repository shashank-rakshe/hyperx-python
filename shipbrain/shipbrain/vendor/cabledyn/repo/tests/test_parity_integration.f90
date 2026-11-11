! File: tests/test_parity_integration.f90
! SPDX-License-Identifier: Apache-2.0
! Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
PROGRAM test_parity_integration
  !! Gates where the MoorDyn-parity features meet: CoupledPinned bodies, active line control of
  !! viscoelastic and Syrope segments, the MoorDyn-C Currents 2 and 5 fields, and ATTACHMENTS on a
  !! line restrained in torsion.
  !!   1. A CoupledPinned body in a Currents 2 or Currents 5 deck: the coupled aggregate (the
  !!      OpenFAST CompMooring = 5 route, with and without the host fluid field) refuses the deck
  !!      for its current files, by the aggregate's water-kinematics rule (the host supplies the
  !!      water kinematics there), while the same deck without them initialises; the standalone
  !!      driver refuses it for the body (no host moves its node).
  !!   2. CONTROL on a viscoelastic (ElasticMod 2) and on a Syrope segment of a taut rope in a
  !!      cross-flow the host prescribes (external_fluid fields at every node, and its steady
  !!      current for the static start): with a zero command a still run keeps the static start;
  !!      after a pay-out (viscoelastic, the static law is history free) or a haul-in (Syrope,
  !!      onto the original working curve, which the static start also takes) and a hold, the
  !!      line rests where the static start of the deck with that segment longer or shorter
  !!      lies in the same current (a second route: the static solver against the controlled
  !!      march). The rope's cross-flow deflection is printed: the current is not negligible.
  !!   3. The lazy wave of test_torsion_attachments (25 buoyancy modules with drag, one turn of
  !!      pretwist, the nodal twist), turned by 30 deg about z and moved off the origin, in a
  !!      Currents 5 grid sheared in x, y and z: the twisted discrete static start (the attachment
  !!      drag fixed point after the polish samples the grid at the modules' global positions) is
  !!      an equilibrium of the march, which samples the grid at the nodes: a still 10 s run keeps
  !!      the fairlead tension, both end torques and the twist. A grid that varies in depth only
  !!      gives the start of the same field as a Currents 1 profile (a second source of the field).
  USE CableDyn_Precision, ONLY: wp
  USE CableDyn_DeckDriver, ONLY: CD_Run_Deck_Driver, CD_DECKDRV_OK
  USE CableDyn_OpenFAST_Aggregate, ONLY: CD_AGG_ModuleType, CD_AGG_Init_From_Deck, CD_AGG_GetMovingPointMesh, &
                                         CD_AGG_Step_Moving, CD_AGG_Apply_LineControl, CD_AGG_NFluidNodes, &
                                         CD_AGG_SetFluidFields, CD_AGG_End, CD_AGG_OK
  USE CableDyn_System, ONLY: CD_System_Line_NElem, CD_Get_System_Line_Tension
  USE, INTRINSIC :: IEEE_ARITHMETIC, ONLY: IEEE_IS_FINITE
  IMPLICIT NONE

  REAL(wp), PARAMETER :: PI = 3.14159265358979323846_wp, DT = 0.05_wp
  INTEGER :: n_fail = 0
  CHARACTER(512) :: lazy_wave

  IF (COMMAND_ARGUMENT_COUNT() /= 1) THEN
    WRITE (*, '(A)') 'usage: test_parity_integration <lazy_wave_torsion_attachments.dat>'
    ERROR STOP 2
  END IF
  CALL GET_COMMAND_ARGUMENT(1, lazy_wave)
  CALL case_pinned_body_currents(2)
  CALL case_pinned_body_currents(5)
  CALL case_control_host_current('viscoelastic', 100.4_wp, 0.6_wp, 0.3_wp)
  CALL case_control_host_current('syrope', 102.0_wp, 1.0_wp, -0.2_wp)
  CALL case_attachments_grid()
  IF (n_fail > 0) THEN
    WRITE (*, '(A,I0,A)') 'FAIL: ', n_fail, ' integration check(s) failed'
    ERROR STOP 1
  END IF
  WRITE (*, '(A)') 'PASS: CoupledPinned bodies, line control and attachments with currents'

CONTAINS

  SUBROUTINE require(cond, msg)
    LOGICAL, INTENT(IN) :: cond
    CHARACTER(*), INTENT(IN) :: msg
    IF (.NOT. cond) THEN
      n_fail = n_fail + 1
      WRITE (*, '(A,A)') 'FAILED: ', msg
    END IF
  END SUBROUTINE require

  FUNCTION num(x) RESULT(s)
    !! A real as a deck token without blanks.
    REAL(wp), INTENT(IN) :: x
    CHARACTER(:), ALLOCATABLE :: s
    CHARACTER(32) :: buf
    WRITE (buf, '(ES23.15)') x
    s = TRIM(ADJUSTL(buf))
  END FUNCTION num

  ! --------------------------------------------------------------------------------------------- !
  ! 1. a CoupledPinned body in a Currents 2/5 deck                                                 !
  ! --------------------------------------------------------------------------------------------- !

  SUBROUTINE write_pinned_body_deck(path, currents, standalone)
    !! A CoupledPinned body (1000 kg, CG 2 m below its reference point at (0, 0, -5), inertias
    !! 500 kg m^2, no drag or added mass) carrying a line from a Body1 point at its node to a Coupled point, with the
    !! MoorDyn-C Currents mode currents (0: none) and, standalone, the dtM/TMax clock.
    CHARACTER(*), INTENT(IN) :: path
    INTEGER, INTENT(IN) :: currents
    LOGICAL, INTENT(IN) :: standalone
    INTEGER :: u
    OPEN (NEWUNIT=u, FILE=path, STATUS='REPLACE', ACTION='WRITE')
    WRITE (u, '(A)') 'CoupledPinned body in a MoorDyn-C current field'
    WRITE (u, '(A)') '--- LINE TYPES ---'
    WRITE (u, '(A)') 'Name Diam Mass EA BA EI Cdn Cdt Can Cat'
    WRITE (u, '(A)') '(-) (m) (kg/m) (N) (-) (Nm2) (-) (-) (-) (-)'
    WRITE (u, '(A)') 'line 0.10 80.0 1.0e6 0.0 0.0 1.0 0.0 1.0 0.0'
    WRITE (u, '(A)') '--- BODIES ---'
    WRITE (u, '(A)') 'ID Attachment X0 Y0 Z0 r0 p0 y0 Mass CG* I* Volume CdA* Ca*'
    WRITE (u, '(A)') '(#) (word) (m) (m) (m) (deg) (deg) (deg) (kg) (m) (kg-m^2) (m^3) (m^2) (-)'
    WRITE (u, '(A)') '1 CoupledPinned 0.0 0.0 -5.0 0.0 0.0 0.0 1000.0 0.0|0.0|-2.0 500.0|500.0|500.0 0.5 0.0 0.0'
    WRITE (u, '(A)') '--- POINTS ---'
    WRITE (u, '(A)') 'ID Type X Y Z Mass Vol CdA Ca'
    WRITE (u, '(A)') '(-) (-) (m) (m) (m) (kg) (m3) (m2) (-)'
    WRITE (u, '(A)') '1 Body1 0.0 0.0 0.0 0 0 0 0'
    WRITE (u, '(A)') '2 Coupled 4.0 0.0 -13.0 0 0 0 0'
    WRITE (u, '(A)') '--- LINES ---'
    WRITE (u, '(A)') 'ID NodeA NodeB Outputs'
    WRITE (u, '(A)') '(-) (-) (-) (-)'
    WRITE (u, '(A)') '1 1 2 -'
    WRITE (u, '(A)') '--- SECTIONS ---'
    WRITE (u, '(A)') 'LineID LineType Length NumSegs'
    WRITE (u, '(A)') '(-) (-) (m) (-)'
    WRITE (u, '(A)') '1 line 9.5 6'
    WRITE (u, '(A)') '--- OPTIONS ---'
    WRITE (u, '(A)') '9.80665 g'
    WRITE (u, '(A)') '1025.0 rhoW'
    WRITE (u, '(A)') '50.0 WtrDpth'
    WRITE (u, '(A)') 'deck bodyIC'
    IF (currents > 0) WRITE (u, '(I0,A)') currents, ' Currents'
    IF (standalone) THEN
      WRITE (u, '(A)') '0.01 dtM'
      WRITE (u, '(A)') '0.1 TMax'
    END IF
    WRITE (u, '(A)') '--- end ---'
    CLOSE (u)
  END SUBROUTINE write_pinned_body_deck

  SUBROUTINE write_current_files()
    !! A Currents 2 depth profile in time and a Currents 5 grid (2 x 2 x 2 x 2), both varying in
    !! time, beside the decks.
    INTEGER :: u, ix, iy, iz, it
    REAL(wp), PARAMETER :: XS(2) = [-20.0_wp, 20.0_wp], YS(2) = [-20.0_wp, 20.0_wp], ZS(2) = [-50.0_wp, 0.0_wp], &
                           TS(2) = [0.0_wp, 10.0_wp]
    OPEN (NEWUNIT=u, FILE='current_profile_dynamic.txt', STATUS='REPLACE', ACTION='WRITE')
    WRITE (u, '(A)') 'Currents 2 profile in time'
    WRITE (u, '(A)') 'depths on line 5, then t ux(z)'
    WRITE (u, '(A)') '-'
    WRITE (u, '(A)') '-'
    WRITE (u, '(A)') '-50.0 0.0'
    WRITE (u, '(A)') 't ux'
    WRITE (u, '(A)') '0.0 0.2 0.4'
    WRITE (u, '(A)') '10.0 0.3 0.6'
    CLOSE (u)
    OPEN (NEWUNIT=u, FILE='current_profile_4d.txt', STATUS='REPLACE', ACTION='WRITE')
    WRITE (u, '(A)') '2 2 2 2'
    WRITE (u, '(A)') '-20.0 20.0'
    WRITE (u, '(A)') '-20.0 20.0'
    WRITE (u, '(A)') '-50.0 0.0'
    WRITE (u, '(A)') '0.0 10.0'
    WRITE (u, '(A)') 'x y z t ux uy uz'
    DO ix = 1, 2
      DO iy = 1, 2
        DO iz = 1, 2
          DO it = 1, 2
            WRITE (u, '(7(A,1X))') num(XS(ix)), num(YS(iy)), num(ZS(iz)), num(TS(it)), &
              num(0.2_wp + 0.01_wp*XS(ix) + 0.1_wp*REAL(it - 1, wp)), num(0.005_wp*YS(iy)), num(0.0_wp)
          END DO
        END DO
      END DO
    END DO
    CLOSE (u)
  END SUBROUTINE write_current_files

  SUBROUTINE case_pinned_body_currents(currents)
    INTEGER, INTENT(IN) :: currents
    TYPE(CD_AGG_ModuleType) :: agg
    INTEGER :: es
    LOGICAL :: conv
    CHARACTER(2048) :: em
    CHARACTER(16) :: tag
    WRITE (tag, '(A,I0)') 'Currents ', currents
    CALL write_current_files()
    ! the deck without the current files is a valid coupled deck
    CALL write_pinned_body_deck('pint_pin_none.dat', 0, .FALSE.)
    CALL CD_AGG_Init_From_Deck(agg, 'pint_pin_none.dat', 0.01_wp, es, em)
    CALL require(es == CD_AGG_OK, '1 '//TRIM(tag)//': the CoupledPinned body deck without currents initialises: '// &
                 TRIM(em))
    CALL CD_AGG_End(agg, es, em)
    CALL write_pinned_body_deck('pint_pin.dat', currents, .FALSE.)
    CALL CD_AGG_Init_From_Deck(agg, 'pint_pin.dat', 0.01_wp, es, em)
    WRITE (*, '(A)') '1 '//TRIM(tag)//', coupled aggregate: '//TRIM(em)
    CALL require(es /= CD_AGG_OK .AND. INDEX(em, 'Currents 1/2/5 files are not supported on the aggregate route') > 0 &
                 .AND. INDEX(em, 'coupled runs take water kinematics from the host') > 0, &
                 '1 '//TRIM(tag)//': the coupled aggregate refuses the current files of a CoupledPinned body deck')
    CALL CD_AGG_End(agg, es, em)
    ! as the OpenFAST shell builds it, with the host's fluid field
    CALL CD_AGG_Init_From_Deck(agg, 'pint_pin.dat', 0.01_wp, es, em, external_fluid=.TRUE.)
    CALL require(es /= CD_AGG_OK .AND. INDEX(em, 'Currents 1/2/5 files are not supported on the aggregate route') > 0, &
                 '1 '//TRIM(tag)//': the coupled aggregate with the host field refuses them too: '//TRIM(em))
    CALL CD_AGG_End(agg, es, em)
    CALL write_pinned_body_deck('pint_pin_sa.dat', currents, .TRUE.)
    CALL CD_Run_Deck_Driver('pint_pin_sa.dat', 'pint_pin_sa', conv, es, em)
    WRITE (*, '(A)') '1 '//TRIM(tag)//', standalone driver: '//TRIM(em)
    CALL require(es /= CD_DECKDRV_OK .AND. INDEX(em, 'CoupledPinned/VesselPinned BODY requires a coupled host') > 0, &
                 '1 '//TRIM(tag)//': the standalone driver refuses the CoupledPinned body')
  END SUBROUTINE case_pinned_body_currents

  ! --------------------------------------------------------------------------------------------- !
  ! 2. CONTROL on a viscoelastic or Syrope segment in the host's current                           !
  ! --------------------------------------------------------------------------------------------- !

  SUBROUTINE write_rope_deck(path, kind, span, l_first, control)
    !! A taut rope between a Coupled fairlead at (0, 0, -100) and a Fixed anchor span away at the
    !! same depth, written fairlead first (the controlled end at NodeA): a first segment of
    !! l_first and nine of 10 m. kind viscoelastic: Es|Ed = 1e8|3e8 N, Bs|Bd = 1e6|1e5 N s; kind
    !! syrope: the polyester of test_syrope_control (OWC table, LINEAR working curve, k1 = 0.5).
    !! Both are nearly neutrally buoyant (0.05 kg/m above the displaced water's), Cdn = 1.2.
    CHARACTER(*), INTENT(IN) :: path, kind
    REAL(wp), INTENT(IN) :: span, l_first
    LOGICAL, INTENT(IN) :: control
    INTEGER :: u
    OPEN (NEWUNIT=u, FILE=path, STATUS='REPLACE', ACTION='WRITE')
    WRITE (u, '(A)') 'Controlled rope in a host cross-flow ('//kind//')'
    WRITE (u, '(A)') '--- LINE TYPES ---'
    WRITE (u, '(A)') 'Name Diam Mass EA BA EI Cdn Cdt Can Cat'
    WRITE (u, '(A)') '(-) (m) (kg/m) (N) (-) (Nm2) (-) (-) (-) (-)'
    IF (kind == 'syrope') THEN
      WRITE (u, '(A)') 'rope 0.1438 16.70 "SYROPE:pint_settings.dat|1.53e8|23.12" 1.0e6|1.0e5 0.0 1.2 0.2 1.0 0.0'
    ELSE
      WRITE (u, '(A)') 'rope 0.1438 16.70 1.0e8|3.0e8 1.0e6|1.0e5 0.0 1.2 0.2 1.0 0.0'
    END IF
    WRITE (u, '(A)') '--- POINTS ---'
    WRITE (u, '(A)') 'ID Type X Y Z Mass Vol CdA Ca'
    WRITE (u, '(A)') '(-) (-) (m) (m) (m) (kg) (m3) (m2) (-)'
    WRITE (u, '(A)') '1 Coupled 0.0 0.0 -100.0 0 0 0 0'
    WRITE (u, '(A)') '2 Fixed '//num(span)//' 0.0 -100.0 0 0 0 0'
    WRITE (u, '(A)') '--- LINES ---'
    WRITE (u, '(A)') 'ID NodeA NodeB Outputs'
    WRITE (u, '(A)') '(-) (-) (-) (-)'
    WRITE (u, '(A)') '1 1 2 -'
    WRITE (u, '(A)') '--- SECTIONS ---'
    WRITE (u, '(A)') 'LineID LineType Length NumSegs'
    WRITE (u, '(A)') '(-) (-) (m) (-)'
    WRITE (u, '(A)') '1 rope '//num(l_first)//' 1'
    WRITE (u, '(A)') '1 rope 90.0 9'
    IF (control) THEN
      WRITE (u, '(A)') '--- CONTROL ---'
      WRITE (u, '(A)') 'ChannelID Lines'
      WRITE (u, '(A)') '(-) (-)'
      WRITE (u, '(A)') '1 1'
    END IF
    WRITE (u, '(A)') '--- OPTIONS ---'
    WRITE (u, '(A)') '9.80665 g'
    WRITE (u, '(A)') '1025.0 rhoW'
    WRITE (u, '(A)') '200.0 WtrDpth'
    WRITE (u, '(A)') '--- OUTPUTS ---'
    WRITE (u, '(A)') 'FairTen1'
    WRITE (u, '(A)') '--- end ---'
    CLOSE (u)
  END SUBROUTINE write_rope_deck

  SUBROUTINE write_syrope_files()
    !! The OWC table of test_syrope_control (the shipped data/syrope/syrope_owc.dat) and its
    !! settings file.
    INTEGER :: u, k
    REAL(wp), PARAMETER :: OWC_EPS(30) = [ &
                           0.00000e+00_wp, 2.06897e-03_wp, 4.13793e-03_wp, 6.20690e-03_wp, 8.27586e-03_wp, &
                           1.03448e-02_wp, 1.24138e-02_wp, 1.44828e-02_wp, 1.65517e-02_wp, 1.86207e-02_wp, &
                           2.06897e-02_wp, 2.27586e-02_wp, 2.48276e-02_wp, 2.68966e-02_wp, 2.89655e-02_wp, &
                           3.10345e-02_wp, 3.31034e-02_wp, 3.51724e-02_wp, 3.72414e-02_wp, 3.93103e-02_wp, &
                           4.13793e-02_wp, 4.34483e-02_wp, 4.55172e-02_wp, 4.75862e-02_wp, 4.96552e-02_wp, &
                           5.17241e-02_wp, 5.37931e-02_wp, 5.58621e-02_wp, 5.79310e-02_wp, 6.00000e-02_wp]
    REAL(wp), PARAMETER :: OWC_TEN(30) = [ &
                           0.00000e+00_wp, 1.71768e+05_wp, 3.30952e+05_wp, 4.78788e+05_wp, 6.16510e+05_wp, &
                           7.45355e+05_wp, 8.66556e+05_wp, 9.81351e+05_wp, 1.09097e+06_wp, 1.19666e+06_wp, &
                           1.29964e+06_wp, 1.40116e+06_wp, 1.50245e+06_wp, 1.60474e+06_wp, 1.70927e+06_wp, &
                           1.81728e+06_wp, 1.93000e+06_wp, 2.04866e+06_wp, 2.17450e+06_wp, 2.30876e+06_wp, &
                           2.45267e+06_wp, 2.60747e+06_wp, 2.77439e+06_wp, 2.95467e+06_wp, 3.14954e+06_wp, &
                           3.36024e+06_wp, 3.58800e+06_wp, 3.83406e+06_wp, 4.09965e+06_wp, 4.38601e+06_wp]
    OPEN (NEWUNIT=u, FILE='pint_owc.dat', STATUS='REPLACE', ACTION='WRITE')
    WRITE (u, '(A)') 'Strain      Tension'
    WRITE (u, '(A)') '(-)         (N)'
    DO k = 1, SIZE(OWC_EPS)
      WRITE (u, '(ES14.6,1X,ES14.6)') OWC_EPS(k), OWC_TEN(k)
    END DO
    CLOSE (u)
    OPEN (NEWUNIT=u, FILE='pint_settings.dat', STATUS='REPLACE', ACTION='WRITE')
    WRITE (u, '(A)') 'pint_owc.dat  OWC     - Original working-curve table file'
    WRITE (u, '(A)') 'LINEAR          WCType  - Working-curve formulation'
    WRITE (u, '(A)') '0.5             k1      - First working-curve shape parameter'
    WRITE (u, '(A)') '0.0             k2      - Second working-curve shape parameter'
    CLOSE (u)
  END SUBROUTINE write_syrope_files

  SUBROUTINE init_in_cross_flow(agg, deck, what, u_cross, ok)
    !! Initialise deck on the coupled aggregate with the host's fluid field and its steady
    !! cross-flow u_cross (along +y) for the static start, and hold the cross-flow at every fluid
    !! node.
    TYPE(CD_AGG_ModuleType), INTENT(INOUT) :: agg
    CHARACTER(*), INTENT(IN) :: deck, what
    REAL(wp), INTENT(IN) :: u_cross
    LOGICAL, INTENT(OUT) :: ok
    REAL(wp) :: sc(4, 2)
    INTEGER :: es
    CHARACTER(1024) :: em
    sc(:, 1) = [-250.0_wp, 0.0_wp, u_cross, 0.0_wp]
    sc(:, 2) = [0.0_wp, 0.0_wp, u_cross, 0.0_wp]
    CALL CD_AGG_Init_From_Deck(agg, deck, DT, es, em, external_fluid=.TRUE., static_current=sc)
    ok = es == CD_AGG_OK
    CALL require(ok, '2 '//what//': '//deck//' initialises in the host cross-flow: '//TRIM(em))
    IF (ok) CALL hold_cross_flow(agg, u_cross, ok)
  END SUBROUTINE init_in_cross_flow

  SUBROUTINE hold_cross_flow(agg, u_cross, ok)
    TYPE(CD_AGG_ModuleType), INTENT(INOUT) :: agg
    REAL(wp), INTENT(IN) :: u_cross
    LOGICAL, INTENT(OUT) :: ok
    REAL(wp), ALLOCATABLE :: uf(:, :), af(:, :), wz(:)
    INTEGER :: nf, es
    CHARACTER(1024) :: em
    nf = CD_AGG_NFluidNodes(agg, es, em)
    ALLOCATE (uf(3, nf), af(3, nf), wz(nf))
    uf = 0.0_wp
    uf(2, :) = u_cross
    af = 0.0_wp
    wz = 0.0_wp
    CALL CD_AGG_SetFluidFields(agg, uf, af, wz, es, em)
    ok = es == CD_AGG_OK
    CALL require(ok, '2: the host fluid field is accepted: '//TRIM(em))
  END SUBROUTINE hold_cross_flow

  SUBROUTINE case_control_host_current(kind, span, u_cross, dl)
    !! The controlled rope of kind (anchor span away) in the host's cross-flow u_cross: a 10 s
    !! still run at a zero command, then the first segment's length changed by dl on a half-cosine
    !! over 10 s and held 40 s, against the static start of the deck whose first segment is
    !! 10 + dl long.
    CHARACTER(*), INTENT(IN) :: kind
    REAL(wp), INTENT(IN) :: span, u_cross, dl
    TYPE(CD_AGG_ModuleType) :: agg, ref
    INTEGER, PARAMETER :: NSTILL = 200, NRAMP = 200, NHOLD = 800
    REAL(wp) :: r0(3, 1), vel(3, 1), acc(3, 1), ld(3, 1), t, cmd, cmd_dot, drift, dten, dq, dt_rel, defl
    REAL(wp), ALLOCATABLE :: q0(:), ten0(:), ten(:), ten_ref(:)
    INTEGER :: es, ni, il, ne, s
    LOGICAL :: ok, cv, st
    CHARACTER(1024) :: em
    CHARACTER(64) :: deck, deck_ref

    IF (kind == 'syrope') CALL write_syrope_files()
    deck = 'pint_ctrl_'//kind//'.dat'
    deck_ref = 'pint_ref_'//kind//'.dat'
    CALL write_rope_deck(TRIM(deck), kind, span, 10.0_wp, .TRUE.)
    CALL write_rope_deck(TRIM(deck_ref), kind, span, 10.0_wp + dl, .FALSE.)
    CALL init_in_cross_flow(agg, TRIM(deck), kind, u_cross, ok)
    IF (.NOT. ok) RETURN
    CALL init_in_cross_flow(ref, TRIM(deck_ref), kind, u_cross, ok)
    IF (.NOT. ok) RETURN
    CALL CD_AGG_GetMovingPointMesh(agg, r0, vel, acc, ld, es, em)
    vel = 0.0_wp
    acc = 0.0_wp
    il = agg%ctrl_line(1)
    ne = CD_System_Line_NElem(agg%sys%fast%system, il, es, em)
    ALLOCATE (ten0(ne), ten(ne), ten_ref(ne))
    q0 = agg%sys%fast%system%lines(il)%q
    CALL CD_Get_System_Line_Tension(agg%sys%fast%system, il, ten0, es, em)
    drift = 0.0_wp
    dten = 0.0_wp
    DO s = 1, NSTILL + NRAMP + NHOLD
      t = REAL(s, wp)*DT - REAL(NSTILL, wp)*DT
      cmd = 0.0_wp
      cmd_dot = 0.0_wp
      IF (t >= REAL(NRAMP, wp)*DT) THEN
        cmd = dl
      ELSE IF (t > 0.0_wp) THEN
        cmd = dl*0.5_wp*(1.0_wp - COS(PI*t/(REAL(NRAMP, wp)*DT)))
        cmd_dot = dl*0.5_wp*(PI/(REAL(NRAMP, wp)*DT))*SIN(PI*t/(REAL(NRAMP, wp)*DT))
      END IF
      CALL hold_cross_flow(agg, u_cross, ok)
      IF (.NOT. ok) RETURN
      CALL CD_AGG_Apply_LineControl(agg, [cmd], [cmd_dot], es, em)
      IF (es == CD_AGG_OK) CALL CD_AGG_Step_Moving(agg, DT, r0, vel, acc, cv, st, ni, es, em)
      IF (es /= CD_AGG_OK .OR. .NOT. cv) THEN
        CALL require(.FALSE., '2 '//kind//': step '//TRIM(num(t))//': '//TRIM(em))
        RETURN
      END IF
      IF (s <= NSTILL) THEN
        CALL CD_Get_System_Line_Tension(agg%sys%fast%system, il, ten, es, em)
        drift = MAX(drift, MAXVAL(ABS(agg%sys%fast%system%lines(il)%q - q0)))
        dten = MAX(dten, MAXVAL(ABS(ten - ten0))/MAXVAL(ten0))
      END IF
    END DO
    CALL CD_Get_System_Line_Tension(agg%sys%fast%system, il, ten, es, em)
    CALL CD_Get_System_Line_Tension(ref%sys%fast%system, 1, ten_ref, es, em)
    ! the controlled segment is the deck's first (the fairlead's), as the changed deck's
    CALL require(MAXVAL(ABS(agg%sys%fast%system%lines(il)%l0 - ref%sys%fast%system%lines(1)%l0)) <= 1.0e-12_wp, &
                 '2 '//kind//': the controlled line takes the segment lengths of the changed deck')
    ASSOCIATE (q => agg%sys%fast%system%lines(il)%q, qr => ref%sys%fast%system%lines(1)%q)
      dq = MAXVAL(ABS(q - qr))
      defl = MAXVAL(ABS(qr(2::3)))
    END ASSOCIATE
    dt_rel = MAXVAL(ABS(ten - ten_ref))/MAXVAL(ten_ref)
    WRITE (*, '(A,A,A,ES10.3,A,ES10.3)') '2 ', kind, ': still 10 s at a zero command: node drift ', drift, &
      ' m, tension change / T ', dten
    WRITE (*, '(A,A,A,F6.3,A,ES12.5,A,ES12.5,A,F7.4,A)') '2 ', kind, ': after DeltaL = ', dl, &
      ' m and a 40 s hold: T ', MAXVAL(ten), ' N, the static start of the changed deck ', MAXVAL(ten_ref), &
      ' N (cross-flow deflection ', defl, ' m)'
    WRITE (*, '(A,A,A,ES10.3,A,ES10.3)') '2 ', kind, ': max |x - x_static| ', dq, ' m, max |T - T_static| / T ', dt_rel
    CALL require(drift <= 1.0e-9_wp .AND. dten <= 1.0e-9_wp, &
                 '2 '//kind//': a still run at a zero command keeps the static start in the host current')
    CALL require(defl > 0.05_wp, '2 '//kind//': the cross-flow deflects the rope')
    CALL require(dq <= 1.0e-5_wp .AND. dt_rel <= 1.0e-5_wp, &
                 '2 '//kind//': the controlled line rests at the static start of the changed deck')
    CALL CD_AGG_End(agg, es, em)
    CALL CD_AGG_End(ref, es, em)
  END SUBROUTINE case_control_host_current

  ! --------------------------------------------------------------------------------------------- !
  ! 3. ATTACHMENTS on a line restrained in torsion in a Currents 5 grid                            !
  ! --------------------------------------------------------------------------------------------- !

  SUBROUTINE write_turned_lazy_wave(path, currents)
    !! The lazy wave of lazy_wave_torsion_attachments.dat turned by PSI about z and moved by
    !! (X_OFF, Y_OFF), its END CONNECTIONS directions turned with it, in the MoorDyn-C Currents
    !! mode currents.
    CHARACTER(*), INTENT(IN) :: path
    INTEGER, INTENT(IN) :: currents
    REAL(wp), PARAMETER :: PSI = 30.0_wp*PI/180.0_wp, X_OFF = 100.0_wp, Y_OFF = -50.0_wp
    REAL(wp) :: c, s
    INTEGER :: u
    c = COS(PSI)
    s = SIN(PSI)
    OPEN (NEWUNIT=u, FILE=path, STATUS='REPLACE', ACTION='WRITE')
    WRITE (u, '(A)') 'Turned lazy wave with buoyancy modules, restrained in torsion, in a MoorDyn-C current'
    WRITE (u, '(A)') '--- LINE TYPES ---'
    WRITE (u, '(A)') 'Name Diam Mass EA BA EI GAs GJ Irt Irn Cdn Cdt Can Cat'
    WRITE (u, '(A)') '(-) (m) (kg/m) (N) (-) (Nm2) (N) (Nm2) (kgm) (kgm) (-) (-) (-) (-)'
    WRITE (u, '(A)') 'bare 0.16 36.70 4.69e8 0.0 1.99e4 1.0e8 1.5e4 1.0 1.0 1.2 0.1 1.0 0.0'
    WRITE (u, '(A)') '--- POINTS ---'
    WRITE (u, '(A)') 'ID Type X Y Z'
    WRITE (u, '(A)') '(-) (-) (m) (m) (m)'
    WRITE (u, '(A)') '7 Coupled '//num(X_OFF + 30.0_wp*c)//' '//num(Y_OFF + 30.0_wp*s)//' -20.0'
    WRITE (u, '(A)') '8 Fixed '//num(X_OFF + 500.0_wp*c)//' '//num(Y_OFF + 500.0_wp*s)//' -200.0'
    WRITE (u, '(A)') '--- LINES ---'
    WRITE (u, '(A)') 'ID NodeA NodeB Outputs'
    WRITE (u, '(A)') '(-) (-) (-) (-)'
    WRITE (u, '(A)') '4 7 8 -'
    WRITE (u, '(A)') '--- SECTIONS ---'
    WRITE (u, '(A)') 'LineID LineType Length NumSegs'
    WRITE (u, '(A)') '(-) (-) (m) (-)'
    WRITE (u, '(A)') '4 bare 80.0 20'
    WRITE (u, '(A)') '4 bare 100.0 25'
    WRITE (u, '(A)') '4 bare 420.0 42'
    WRITE (u, '(A)') '--- ATTACHMENTS ---'
    WRITE (u, '(A)') 'LineID ArcLength Mass Volume CdA Ca CdAx'
    WRITE (u, '(A)') '(-) (m) (kg) (m^3) (m^2) (-) (m^2)'
    WRITE (u, '(A)') '4 80.0:4.0:176.0 91.32 0.18378 1.392 1.0 0.0'
    WRITE (u, '(A)') '--- END CONNECTIONS ---'
    WRITE (u, '(A)') 'LineID End Stiffness EzX EzY EzZ TorsStiffness NxX NxY NxZ Pretwist'
    WRITE (u, '(A)') '(-) (-) (N-m/rad) (-) (-) (-) (N-m/rad) (-) (-) (-) (deg)'
    WRITE (u, '(A)') '4 A Rigid '//num(0.1058_wp*c)//' '//num(0.1058_wp*s)//' -0.9944 Rigid '//num(-s)//' '// &
      num(c)//' 0 0'
    WRITE (u, '(A)') '4 B Rigid '//num(c)//' '//num(s)//' 0 Rigid '//num(-s)//' '//num(c)//' 0 360'
    WRITE (u, '(A)') '--- OPTIONS ---'
    WRITE (u, '(A)') '9.80665 g'
    WRITE (u, '(A)') '1025.0 rhoW'
    WRITE (u, '(A)') '3.0e6 kBot'
    WRITE (u, '(A)') '3.0e5 cBot'
    WRITE (u, '(A)') '0.35 frictionMu'
    WRITE (u, '(A)') '200.0 WtrDpth'
    WRITE (u, '(A)') '0.025 dtM'
    WRITE (u, '(A)') '10.0 TMax'
    WRITE (u, '(I0,A)') currents, ' Currents'
    WRITE (u, '(A)') '--- OUTPUTS ---'
    WRITE (u, '(A)') 'FairTen4'
    WRITE (u, '(A)') 'Torq4N1'
    WRITE (u, '(A)') 'Torq4N88'
    WRITE (u, '(A)') 'Twist4'
    WRITE (u, '(A)') '--- END ---'
    CLOSE (u)
  END SUBROUTINE write_turned_lazy_wave

  PURE FUNCTION grid_speed(x, y, z, sheared) RESULT(sp)
    !! The speed of the grid field, across the turned line (direction (-sin 30, cos 30, 0)):
    !! (0.15 + 3e-4 x - 2e-4 y)(1 + z/400) when sheared, else 0.15 (1 + z/400). Trilinear, so the
    !! grid reproduces it between its points.
    REAL(wp), INTENT(IN) :: x, y, z
    LOGICAL, INTENT(IN) :: sheared
    REAL(wp) :: sp
    IF (sheared) THEN
      sp = (0.15_wp + 3.0e-4_wp*x - 2.0e-4_wp*y)*(1.0_wp + z/400.0_wp)
    ELSE
      sp = 0.15_wp*(1.0_wp + z/400.0_wp)
    END IF
  END FUNCTION grid_speed

  SUBROUTINE write_grid(sheared)
    !! current_profile_4d.txt: x in {-100, 300, 700}, y in {-200, 100, 400}, z in {-250, -100, 0},
    !! t in {0, 100} (steady), the velocity grid_speed along (-sin 30, cos 30, 0).
    LOGICAL, INTENT(IN) :: sheared
    REAL(wp), PARAMETER :: XS(3) = [-100.0_wp, 300.0_wp, 700.0_wp], YS(3) = [-200.0_wp, 100.0_wp, 400.0_wp], &
                           ZS(3) = [-250.0_wp, -100.0_wp, 0.0_wp], TS(2) = [0.0_wp, 100.0_wp]
    REAL(wp) :: sp, nx, ny
    INTEGER :: u, ix, iy, iz, it
    nx = -SIN(30.0_wp*PI/180.0_wp)
    ny = COS(30.0_wp*PI/180.0_wp)
    OPEN (NEWUNIT=u, FILE='current_profile_4d.txt', STATUS='REPLACE', ACTION='WRITE')
    WRITE (u, '(A)') '3 3 3 2'
    WRITE (u, '(3(A,1X))') num(XS(1)), num(XS(2)), num(XS(3))
    WRITE (u, '(3(A,1X))') num(YS(1)), num(YS(2)), num(YS(3))
    WRITE (u, '(3(A,1X))') num(ZS(1)), num(ZS(2)), num(ZS(3))
    WRITE (u, '(2(A,1X))') num(TS(1)), num(TS(2))
    WRITE (u, '(A)') 'x y z t ux uy uz'
    DO ix = 1, 3
      DO iy = 1, 3
        DO iz = 1, 3
          DO it = 1, 2
            sp = grid_speed(XS(ix), YS(iy), ZS(iz), sheared)
            WRITE (u, '(7(A,1X))') num(XS(ix)), num(YS(iy)), num(ZS(iz)), num(TS(it)), num(sp*nx), num(sp*ny), &
              num(0.0_wp)
          END DO
        END DO
      END DO
    END DO
    CLOSE (u)
  END SUBROUTINE write_grid

  SUBROUTINE write_profile()
    !! current_profile.txt (Currents 1): the depth-only grid field at the grid's levels.
    REAL(wp), PARAMETER :: ZS(3) = [-250.0_wp, -100.0_wp, 0.0_wp]
    REAL(wp) :: sp, nx, ny
    INTEGER :: u, iz
    nx = -SIN(30.0_wp*PI/180.0_wp)
    ny = COS(30.0_wp*PI/180.0_wp)
    OPEN (NEWUNIT=u, FILE='current_profile.txt', STATUS='REPLACE', ACTION='WRITE')
    WRITE (u, '(A)') 'Currents 1 profile'
    WRITE (u, '(A)') 'the depth-only grid field'
    WRITE (u, '(A)') 'z (m), ux (m/s), uy (m/s), uz (m/s)'
    DO iz = 1, 3
      sp = grid_speed(0.0_wp, 0.0_wp, ZS(iz), .FALSE.)
      WRITE (u, '(4(A,1X))') num(ZS(iz)), num(sp*nx), num(sp*ny), num(0.0_wp)
    END DO
    CLOSE (u)
  END SUBROUTINE write_profile

  SUBROUTINE run_still(root, currents, label, first, spread, ok)
    !! Write and run the turned lazy wave as root.dat in Currents mode currents; first holds the
    !! first output row (FairTen, Torq A, Torq B, Twist) and spread the relative spread of each
    !! column over the 10 s run.
    CHARACTER(*), INTENT(IN) :: root, label
    INTEGER, INTENT(IN) :: currents
    REAL(wp), INTENT(OUT) :: first(4), spread(4)
    LOGICAL, INTENT(OUT) :: ok
    INTEGER, PARAMETER :: MAXROW = 1000
    REAL(wp) :: vals(5, MAXROW)
    INTEGER :: u, ios, nrow, j, es
    LOGICAL :: conv
    CHARACTER(2048) :: em, buf
    first = 0.0_wp
    spread = HUGE(1.0_wp)
    CALL write_turned_lazy_wave(root//'.dat', currents)
    CALL CD_Run_Deck_Driver(root//'.dat', root, conv, es, em)
    ok = es == CD_DECKDRV_OK .AND. conv
    CALL require(ok, '3 '//label//': the turned lazy wave with modules and torsion solves and runs: '//TRIM(em))
    IF (.NOT. ok) RETURN
    nrow = 0
    OPEN (NEWUNIT=u, FILE=root//'.out', STATUS='OLD', ACTION='READ', IOSTAT=ios)
    IF (ios == 0) THEN
      READ (u, '(A)', IOSTAT=ios) buf
      READ (u, '(A)', IOSTAT=ios) buf
      DO WHILE (nrow < MAXROW)
        READ (u, *, IOSTAT=ios) vals(:, nrow + 1)
        IF (ios /= 0) EXIT
        nrow = nrow + 1
      END DO
      CLOSE (u)
    END IF
    ok = nrow == 401
    IF (ok) ok = ALL(IEEE_IS_FINITE(vals(:, 1:nrow)))
    CALL require(ok, '3 '//label//': 401 finite output rows')
    IF (.NOT. ok) RETURN
    first = vals(2:5, 1)
    DO j = 1, 4
      spread(j) = (MAXVAL(vals(j + 1, 1:nrow)) - MINVAL(vals(j + 1, 1:nrow)))/ABS(vals(j + 1, 1))
    END DO
    WRITE (*, '(A,A,A,4ES14.6,A,4ES10.2)') '3 ', label, ': FairTen, Torq A, Torq B, Twist ', first, &
      '; relative spread over 10 s ', spread
  END SUBROUTINE run_still

  SUBROUTINE case_attachments_grid()
    REAL(wp) :: f_grid(4), s_grid(4), f_z(4), s_z(4), f_c1(4), s_c1(4), f_still(4), s_still(4)
    LOGICAL :: ok
    ! the current-free start, for the size of the current's effect
    CALL run_still('pint_lw_still', 0, 'still water', f_still, s_still, ok)
    IF (.NOT. ok) RETURN
    CALL write_grid(.TRUE.)
    CALL run_still('pint_lw_grid', 5, 'Currents 5 grid sheared in x, y and z', f_grid, s_grid, ok)
    IF (.NOT. ok) RETURN
    CALL require(ABS(f_grid(4)) > 300.0_wp, '3: the static start in the grid is twisted (one turn of pretwist)')
    CALL require(MAXVAL(s_grid) <= 1.0e-6_wp, '3: a still run keeps the twisted discrete start in the sheared grid')
    WRITE (*, '(A,4ES10.2)') '3 the grid changes the start (relative to still water): ', &
      ABS(f_grid - f_still)/ABS(f_still)
    CALL require(ABS(f_grid(1) - f_still(1)) > 1.0e-3_wp*ABS(f_still(1)), '3: the grid current loads the line')
    CALL write_grid(.FALSE.)
    CALL run_still('pint_lw_gridz', 5, 'Currents 5 grid in depth only', f_z, s_z, ok)
    IF (.NOT. ok) RETURN
    CALL write_profile()
    CALL run_still('pint_lw_c1', 1, 'Currents 1 profile of the same field', f_c1, s_c1, ok)
    IF (.NOT. ok) RETURN
    WRITE (*, '(A,4ES10.2)') '3 depth-only grid against the Currents 1 profile, relative: ', ABS(f_z - f_c1)/ABS(f_c1)
    CALL require(MAXVAL(s_z) <= 1.0e-6_wp .AND. MAXVAL(s_c1) <= 1.0e-6_wp, &
                 '3: still runs keep the starts in the depth-only grid and in the profile')
    CALL require(MAXVAL(ABS(f_z - f_c1)/ABS(f_c1)) <= 1.0e-9_wp, &
                 '3: a depth-only grid gives the start of the same Currents 1 profile')
  END SUBROUTINE case_attachments_grid

END PROGRAM test_parity_integration
