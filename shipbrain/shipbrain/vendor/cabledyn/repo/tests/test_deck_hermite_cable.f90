! File: tests/test_deck_hermite_cable.f90
! SPDX-License-Identifier: Apache-2.0
! Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
PROGRAM test_deck_hermite_cable
  !! Gate for the deck -> coupled cubic-Hermite cable builder.
  !! CD_Init_Deck_HermiteCable parses a finite-EI (EI>0) cable deck and produces a
  !! COUPLED Hermite FMF cable driven at the fairlead. This gate proves the built cable
  !! (a) initializes with the fairlead as the coupled node, (b) reports a physical static
  !! fairlead load, (c) responds to a prescribed heave (the load-out boundary swings),
  !! and (d) yields finite, bounded curvature -- i.e. the cable is a working coupled
  !! object ready for the OpenFAST aggregator, without touching the EI=0 core.
  USE CableDyn_Precision, ONLY: wp
  USE CableDyn_DeckDriver, ONLY: CD_Init_Deck_HermiteCable, CD_DECKDRV_OK, CD_DECKDRV_BADINPUT
  USE CableDyn_OpenFAST_HermiteFMF, ONLY: CD_HFMF_ModuleType, CD_HFMF_UpdateStates, CD_HFMF_CalcOutput, &
                                          CD_HFMF_Curvature, CD_HFMF_Curvature_Exact, &
                                          CD_HFMF_GetCoupledKinematics, &
                                          CD_HFMF_MinSpanZ, CD_HFMF_Snapshot, CD_HFMF_Restore, &
                                          CD_HFMF_End, CD_HFMF_OK
  USE CableDyn_EndConnection, ONLY: CD_ENDCONN_RIGID
  USE CableDyn_HermiteCableDynamic, ONLY: CD_HermiteCable_Dyn_End_Force, CD_HCDYN_OK
  USE, INTRINSIC :: IEEE_ARITHMETIC, ONLY: IEEE_IS_NAN
  IMPLICIT NONE
  INTEGER :: nfail
  nfail = 0
  CALL case_build_and_drive()
  CALL case_adaptive_mesh_refines()
  CALL case_build_no_dtm()
  CALL case_fail_closed()
  CALL case_reject_environment()
  CALL case_reject_bad_endpoint()
  CALL case_end_connections()
  CALL case_end_connection_rejections()
  CALL case_azimuthal_frame_objectivity()
  CALL case_reject_motionfile()
  CALL case_coupled_seabed_contact()
  CALL case_grounded_anchor_end()
  IF (nfail > 0) THEN
    WRITE (*, '(A,I0,A)') 'FAIL: ', nfail, ' assertion(s) failed'
    ERROR STOP 1
  END IF
  WRITE (*, '(A)') 'PASS: deck -> coupled Hermite cable'
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

  SUBROUTINE case_build_and_drive()
    TYPE(CD_HFMF_ModuleType), ALLOCATABLE :: cable   ! see DEVELOPMENT.md (gfortran 16 -Wuninitialized)
    INTEGER :: cn, es, s, cnr, nn
    CHARACTER(256) :: em
    REAL(wp) :: r0(3), yk(3), u_pos(3), u_vel(3), u_acc(3), t, zh, vh, ah, ymin, ymax, ymag
    REAL(wp), ALLOCATABLE :: curv(:)
    REAL(wp), PARAMETER :: DT = 0.05_wp, AMP = 1.0_wp, PER = 12.0_wp
    REAL(wp), PARAMETER :: PI = 3.141592653589793_wp
    INTEGER, PARAMETER :: NSTEP = 220, NSETTLE = 140
    LOGICAL :: stepped_ok

    ALLOCATE (cable)
    CALL write_cable_deck('hcab_deck_hcable.dat')
    CALL CD_Init_Deck_HermiteCable('hcab_deck_hcable.dat', DT, cable, cn, es, em)
    CALL require(es == CD_DECKDRV_OK, 'deck -> Hermite cable init: '//TRIM(em))
    IF (es /= CD_DECKDRV_OK) RETURN

    nn = SIZE(cable%line%q)/6
    CALL require(cn == nn, 'coupled node is the fairlead (node nn)')
    cnr = 6*(cn - 1)
    r0 = cable%line%q(cnr + 1:cnr + 3)

    ! Drive the fairlead in a gentle heave starting from the static position (zero at
    ! t=0), settle, then read the loads-out boundary over the steady window. The reaction
    ! is only valid after the first implicit step (the FMF contract), so no at-rest read.
    ymin = HUGE(1.0_wp)
    ymax = -HUGE(1.0_wp)
    ymag = 0.0_wp
    stepped_ok = .TRUE.
    ALLOCATE (curv(nn))
    DO s = 1, NSTEP
      t = REAL(s, wp)*DT
      ! (1 - cos) heave: starts at rest (v = 0 at t = 0), matching the cable's rest
      ! initial condition -- a sine heave has MAX velocity at t = 0 and jerks the coupled
      ! node from rest, which a stiff cable cannot absorb on the first implicit step.
      zh = AMP*(1.0_wp - COS(2.0_wp*PI*t/PER))
      vh = AMP*(2.0_wp*PI/PER)*SIN(2.0_wp*PI*t/PER)
      ah = AMP*(2.0_wp*PI/PER)**2*COS(2.0_wp*PI*t/PER)
      u_pos = [r0(1), r0(2), r0(3) + zh]
      u_vel = [0.0_wp, 0.0_wp, vh]
      u_acc = [0.0_wp, 0.0_wp, ah]
      CALL CD_HFMF_UpdateStates(cable, u_pos, u_vel, u_acc, es, em)
      IF (es /= CD_HFMF_OK) THEN
        CALL require(.FALSE., 'coupled step converged: '//TRIM(em))
        stepped_ok = .FALSE.
        EXIT
      END IF
      IF (s > NSETTLE) THEN
        CALL CD_HFMF_CalcOutput(cable, yk, es, em)
        CALL require(es == CD_HFMF_OK, 'dynamic CalcOutput')
        ymag = MAX(ymag, SQRT(SUM(yk**2)))
        ymin = MIN(ymin, yk(3))
        ymax = MAX(ymax, yk(3))
      END IF
    END DO
    IF (.NOT. stepped_ok) RETURN
    CALL require(ymag > 1.0e3_wp, 'steady fairlead load is physical (finite, nonzero)')
    CALL require(ymax - ymin > 1.0e2_wp, 'prescribed heave loads the cable (fairlead Fz swings)')

    ! Curvature must stay SMOOTH: a lazy-wave sag/arch bend is O(0.1 /m); a value near 1 /m would
    ! be a sub-element kink (the slack-catenary buckling mode this lazy-wave gate avoids). Bound
    ! well below that so the gate actually fails on a kinked response, not just a non-finite one.
    ! A kink is a defect of the centreline shape, so the gate reads its geometric trace
    ! (CD_HFMF_Curvature_Exact), not the Curv channel's equilibrium moment over EI.
    CALL CD_HFMF_Curvature_Exact(cable, curv, es, em)
    CALL require(es == CD_HFMF_OK .AND. .NOT. ANY(IEEE_IS_NAN(curv)) .AND. nan_max_abs(curv) < 1.0_wp, &
                 'curvature finite, bounded, and smooth (no kink)')
    WRITE (*, '(A,F9.1,A,F9.2,A,ES10.3)') 'deck-Hermite cable: steady |Fair| = ', ymag*1.0e-3_wp, &
      ' kN;  heave Fz swing = ', (ymax - ymin)*1.0e-3_wp, ' kN;  max curvature = ', nan_max_abs(curv)
    CALL CD_HFMF_End(cable)
  END SUBROUTINE case_build_and_drive

  SUBROUTINE case_adaptive_mesh_refines()
    !! The opt-in adaptive_mesh OPTION refines an under-resolved COUPLED cable. The lazy-wave
    !! deck at its as-written 47 segments is diagnosed fragile by the deliberately conservative
    !! h*kappa target; adaptive_mesh true lets the coupled builder refine it (warm-started
    !! cubic-Hermite prolongation of the converged IC) before the dynamic run. Gate: (a) OFF keeps
    !! the deck's mesh EXACTLY (the default, so every other deck stays bit-for-bit); (b) ON yields
    !! MORE nodes, every declared element split into a power of two of equal children (local
    !! refinement keeps the declared element partition, so the hydro/property arrays mapped by
    !! reference arc stay aligned with the refined solution); (c) the coupled node still tracks the
    !! refined fairlead; (d) the refined cable steps stably with smooth, bounded curvature (the
    !! prolongation produced a valid finer equilibrium, not a kink).
    TYPE(CD_HFMF_ModuleType), ALLOCATABLE :: plain, adapt   ! see DEVELOPMENT.md (gfortran 16 -Wuninitialized)
    INTEGER :: cn, es, s, nn_plain, nn_adapt, cnr
    CHARACTER(256) :: em
    REAL(wp) :: r0(3), u_pos(3), u_vel(3), u_acc(3), t, zh, vh, ah
    REAL(wp), ALLOCATABLE :: curv(:)
    REAL(wp), PARAMETER :: DT = 0.05_wp, AMP = 1.0_wp, PER = 12.0_wp
    REAL(wp), PARAMETER :: PI = 3.141592653589793_wp
    INTEGER, PARAMETER :: NSTEP = 30
    LOGICAL :: stepped_ok, nested
    REAL(wp), ALLOCATABLE :: l_deck(:)
    REAL(wp) :: acc, ratio
    INTEGER :: i, j, k

    ALLOCATE (plain, adapt)
    CALL write_cable_deck('hcab_deck_hc_plain.dat')
    CALL CD_Init_Deck_HermiteCable('hcab_deck_hc_plain.dat', DT, plain, cn, es, em)
    CALL require(es == CD_DECKDRV_OK, 'adaptive-mesh: plain deck init: '//TRIM(em))
    IF (es /= CD_DECKDRV_OK) RETURN
    nn_plain = SIZE(plain%line%q)/6
    l_deck = plain%line%l0
    CALL CD_HFMF_End(plain)

    CALL write_cable_deck('hcab_deck_hc_adapt.dat', extra_option='true adaptive_mesh', ba_value=-0.005_wp)
    CALL CD_Init_Deck_HermiteCable('hcab_deck_hc_adapt.dat', DT, adapt, cn, es, em)
    CALL require(es == CD_DECKDRV_OK, 'adaptive-mesh: adaptive deck init: '//TRIM(em))
    IF (es /= CD_DECKDRV_OK) RETURN
    nn_adapt = SIZE(adapt%line%q)/6

    CALL require(nn_adapt > nn_plain, 'adaptive-mesh: accuracy policy refines the declared mesh')
    ! Every declared element is tiled by refined elements of its length / 2^k (k <= 4).
    nested = .TRUE.
    j = 1
    DO i = 1, SIZE(l_deck)
      acc = 0.0_wp
      DO WHILE (acc < l_deck(i)*(1.0_wp - 1.0e-12_wp) .AND. j <= SIZE(adapt%line%l0))
        ratio = l_deck(i)/adapt%line%l0(j)
        k = NINT(LOG(ratio)/LOG(2.0_wp))
        IF (k < 0 .OR. k > 4 .OR. ABS(ratio - 2.0_wp**k) > 1.0e-9_wp*ratio) nested = .FALSE.
        acc = acc + adapt%line%l0(j)
        j = j + 1
      END DO
      IF (ABS(acc - l_deck(i)) > 1.0e-9_wp*l_deck(i)) nested = .FALSE.
    END DO
    IF (j /= SIZE(adapt%line%l0) + 1) nested = .FALSE.
    CALL require(nested, 'adaptive-mesh: refinement preserves the declared element partition')
    CALL require(cn == nn_adapt, 'adaptive-mesh: coupled node tracks the refined fairlead')
    CALL require(adapt%line%has_axial_damping .AND. ALLOCATED(adapt%line%BA), &
                 'adaptive-mesh: deck BA is installed on the finite-EI dynamic cable')
    IF (adapt%line%has_axial_damping) THEN
      CALL require(nan_max_abs((adapt%line%BA - &
                                0.005_wp*adapt%line%l0*SQRT(adapt%line%EA*adapt%line%rho_a))/ &
                               MAX(1.0_wp, ABS(adapt%line%BA))) < 2.0e-14_wp, &
                   'adaptive-mesh: negative-zeta BA is resolved with every final child length')
    END IF

    ! The refined cable must still run: drive a gentle (1 - cos) heave and require every implicit
    ! step converges, then confirm the curvature is smooth (no sub-element kink from a bad seed).
    cnr = 6*(cn - 1)
    r0 = adapt%line%q(cnr + 1:cnr + 3)
    stepped_ok = .TRUE.
    DO s = 1, NSTEP
      t = REAL(s, wp)*DT
      zh = AMP*(1.0_wp - COS(2.0_wp*PI*t/PER))
      vh = AMP*(2.0_wp*PI/PER)*SIN(2.0_wp*PI*t/PER)
      ah = AMP*(2.0_wp*PI/PER)**2*COS(2.0_wp*PI*t/PER)
      u_pos = [r0(1), r0(2), r0(3) + zh]
      u_vel = [0.0_wp, 0.0_wp, vh]
      u_acc = [0.0_wp, 0.0_wp, ah]
      CALL CD_HFMF_UpdateStates(adapt, u_pos, u_vel, u_acc, es, em)
      IF (es /= CD_HFMF_OK) THEN
        CALL require(.FALSE., 'adaptive-mesh: refined cable step converged: '//TRIM(em))
        stepped_ok = .FALSE.
        EXIT
      END IF
    END DO
    IF (stepped_ok) THEN
      ALLOCATE (curv(nn_adapt))
      CALL CD_HFMF_Curvature_Exact(adapt, curv, es, em)   ! geometric trace: a kink is a shape defect
      CALL require(es == CD_HFMF_OK .AND. .NOT. ANY(IEEE_IS_NAN(curv)) .AND. nan_max_abs(curv) < 1.0_wp, &
                   'adaptive-mesh: refined cable curvature finite, bounded, smooth')
      WRITE (*, '(A,I0,A,I0,A)') 'adaptive-mesh: coupled cable refined ', nn_plain, ' -> ', nn_adapt, ' nodes'
    END IF
    CALL CD_HFMF_End(adapt)
  END SUBROUTINE case_adaptive_mesh_refines

  SUBROUTINE case_build_no_dtm()
    !! A CALLER-DRIVEN finite-EI (coupled) deck does not need dtM/TMax: the host supplies the
    !! timestep through the coupling step, and the builder marches at the dt argument, not the
    !! deck's dtM. The same lazy-wave deck WITHOUT dtM/TMax must still build and take a step. (A
    !! standalone finite-EI deck is structurally unaffected: its End A must be Coupled/Vessel/Body,
    !! so the standalone marching contract still demands a motionFile -- and hence dtM.)
    TYPE(CD_HFMF_ModuleType), ALLOCATABLE :: cable   ! see DEVELOPMENT.md (gfortran 16 -Wuninitialized)
    INTEGER :: cn, es
    CHARACTER(256) :: em
    REAL(wp) :: u_pos(3)
    ALLOCATE (cable)
    CALL write_cable_deck('hcab_deck_nodtm.dat', omit_time=.TRUE.)
    CALL CD_Init_Deck_HermiteCable('hcab_deck_nodtm.dat', 0.05_wp, cable, cn, es, em)
    CALL require(es == CD_DECKDRV_OK, 'caller-driven finite-EI deck builds WITHOUT dtM/TMax: '//TRIM(em))
    IF (es /= CD_DECKDRV_OK) RETURN
    ! It is a live coupled cable: hold the fairlead and take one implicit step.
    u_pos = cable%line%q(6*(cn - 1) + 1:6*(cn - 1) + 3)
    CALL CD_HFMF_UpdateStates(cable, u_pos, [0.0_wp, 0.0_wp, 0.0_wp], [0.0_wp, 0.0_wp, 0.0_wp], es, em)
    CALL require(es == CD_HFMF_OK, 'no-dtM coupled cable steps: '//TRIM(em))
    CALL CD_HFMF_End(cable)
  END SUBROUTINE case_build_no_dtm

  SUBROUTINE case_fail_closed()
    !! An EI=0 deck must be rejected (it belongs to CD_Init_Deck_System).
    TYPE(CD_HFMF_ModuleType) :: cable
    INTEGER :: cn, es
    CHARACTER(256) :: em
    CALL write_ei0_deck('hcab_deck_ei0.dat')
    CALL CD_Init_Deck_HermiteCable('hcab_deck_ei0.dat', 0.05_wp, cable, cn, es, em)
    CALL require(es == CD_DECKDRV_BADINPUT, 'EI=0 deck fails closed (belongs to CD_Init_Deck_System)')
  END SUBROUTINE case_fail_closed

  SUBROUTINE case_reject_environment()
    !! The coupled Hermite cable carries structural + drag + added-mass loads only. A deck that
    !! declares an ambient current (or waves / friction) must be REJECTED, not silently run with
    !! the environment dropped -- those enter through the aggregator's shared host fluid field.
    TYPE(CD_HFMF_ModuleType) :: cable
    INTEGER :: cn, es
    CHARACTER(256) :: em
    CALL write_cable_deck('hcab_deck_current.dat', extra_option='uniform 0.5 0.0 0.0 current')
    CALL CD_Init_Deck_HermiteCable('hcab_deck_current.dat', 0.05_wp, cable, cn, es, em)
    CALL require(es == CD_DECKDRV_BADINPUT, 'deck declaring an ambient current fails closed')
    CALL write_cable_deck('hcab_deck_seastate.dat', extra_option='SEASTATE WaterKin')
    CALL CD_Init_Deck_HermiteCable('hcab_deck_seastate.dat', 0.05_wp, cable, cn, es, em)
    CALL require(es == CD_DECKDRV_BADINPUT .AND. INDEX(em, 'SEASTATE') > 0, &
                 'Hermite-only init rejects unconsumed SEASTATE by name')
  END SUBROUTINE case_reject_environment

  SUBROUTINE case_reject_bad_endpoint()
    !! The builder drives End A (fairlead) and holds End B (anchor); a deck whose anchor is a
    !! DYNAMIC point (Free/Connect) -- or any non-Fixed role -- must fail closed, not be silently
    !! coerced into the held anchor boundary (dropping the point's own mass/load state).
    TYPE(CD_HFMF_ModuleType) :: cable
    INTEGER :: cn, es, u, ios
    CHARACTER(256) :: em
    OPEN (NEWUNIT=u, FILE='hcab_deck_freeanchor.dat', STATUS='REPLACE', ACTION='WRITE', IOSTAT=ios)
    WRITE (u, '(A)') 'finite-EI cable with a dynamic (Free) End B'
    WRITE (u, '(A)') '--- LINE TYPES ---'
    WRITE (u, '(A)') 'Name Diam Mass EA BA EI Cdn Cdt Can Cat'
    WRITE (u, '(A)') '(-) (m) (kg/m) (N) (-) (Nm2) (-) (-) (-) (-)'
    WRITE (u, '(A)') 'bare 0.16 36.70 4.69e8 0.0 1.99e4 1.2 0.1 1.0 0.0'
    WRITE (u, '(A)') '--- POINTS ---'
    WRITE (u, '(A)') 'ID Type X Y Z Mass Vol CdA Ca'
    WRITE (u, '(A)') '(-) (-) (m) (m) (m) (kg) (m3) (m2) (-)'
    WRITE (u, '(A)') '1 Free 0.0 0.0 -56.0 1000.0 0.5 1.0 1.0'
    WRITE (u, '(A)') '2 Coupled 90.0 0.0 -14.0 0.0 0.0 0.0 0.0'
    WRITE (u, '(A)') '--- LINES ---'
    WRITE (u, '(A)') 'ID NodeA NodeB Outputs'
    WRITE (u, '(A)') '(-) (-) (-) (-)'
    WRITE (u, '(A)') '1 2 1 -'
    WRITE (u, '(A)') '--- SECTIONS ---'
    WRITE (u, '(A)') 'LineID LineType Length NumSegs'
    WRITE (u, '(A)') '(-) (-) (m) (-)'
    WRITE (u, '(A)') '1 bare 85.0 20'
    WRITE (u, '(A)') '--- OPTIONS ---'
    WRITE (u, '(A)') '9.80665 g'
    WRITE (u, '(A)') '1025.0 rhoW'
    WRITE (u, '(A)') '0.5 rhoInf'
    ! dtM/TMax present so the Free (dynamic) point passes parse_deck's dynamic-point rule and
    ! actually reaches the builder's endpoint-role guard (the case under test), rather than
    ! being rejected earlier for lacking them.
    WRITE (u, '(A)') '0.05 dtM'
    WRITE (u, '(A)') '1.0 TMax'
    WRITE (u, '(A)') '--- need this line ---'
    CLOSE (u)
    CALL CD_Init_Deck_HermiteCable('hcab_deck_freeanchor.dat', 0.05_wp, cable, cn, es, em)
    CALL require(es == CD_DECKDRV_BADINPUT, 'dynamic (Free) anchor endpoint fails closed: '//TRIM(em))
  END SUBROUTINE case_reject_bad_endpoint

  SUBROUTINE case_end_connections()
    !! END CONNECTIONS is a production deck feature, not merely a low-level kernel.
    !! Prove the public End-A row maps to the internal final node, the finite spring
    !! participates in the static seed and dynamic march, and its support moment is
    !! returned. An explicitly Pinned row must remain bit-identical to omission.
    ! ALLOCATABLE: see DEVELOPMENT.md (gfortran 16 -Wuninitialized)
    TYPE(CD_HFMF_ModuleType), ALLOCATABLE :: omitted, pinned, finite, rigid, stock
    INTEGER :: cn_o, cn_p, cn_f, cn_r, cn_s, es, s, i
    CHARACTER(256) :: em
    REAL(wp) :: pos(3), vel(3), acc(3), force(3), moment(3), dcm(3, 3), angle
    REAL(wp) :: d0_saved(3, 2), ymax, tangent(3), tangent_norm

    ALLOCATE (omitted, pinned, finite, rigid, stock)
    cn_o = 0; cn_p = 0; cn_f = 0; cn_r = 0; cn_s = 0

    CALL write_cable_deck('hcab_deck_endconn_omitted.dat')
    CALL CD_Init_Deck_HermiteCable('hcab_deck_endconn_omitted.dat', 0.05_wp, omitted, cn_o, es, em)
    CALL require(es == CD_DECKDRV_OK, 'endconn: omitted deck initializes: '//TRIM(em))
    IF (es /= CD_DECKDRV_OK) RETURN

    CALL write_cable_deck('hcab_deck_endconn_pinned.dat', endconn_row='1 A Pinned 0 0 -1')
    CALL CD_Init_Deck_HermiteCable('hcab_deck_endconn_pinned.dat', 0.05_wp, pinned, cn_p, es, em)
    CALL require(es == CD_DECKDRV_OK, 'endconn: explicit Pinned deck initializes: '//TRIM(em))
    IF (es == CD_DECKDRV_OK) THEN
      CALL require(cn_p == cn_o .AND. nan_max_abs(pinned%line%q - omitted%line%q) <= 0.0_wp, &
                   'endconn: explicit Pinned is bit-identical to omission')
      CALL require(ALL(pinned%line%freemask .EQV. omitted%line%freemask), &
                   'endconn: explicit Pinned preserves the established dynamic DOF topology')
      CALL require(.NOT. pinned%line%has_endconn, 'endconn: Pinned installs no dynamic spring')
    END IF

    CALL write_cable_deck('hcab_deck_endconn_finite.dat', endconn_row='1 A 20000 0 0 -1')
    CALL CD_Init_Deck_HermiteCable('hcab_deck_endconn_finite.dat', 0.05_wp, finite, cn_f, es, em)
    CALL require(es == CD_DECKDRV_OK, 'endconn: finite deck initializes: '//TRIM(em))
    IF (es == CD_DECKDRV_OK) THEN
      CALL require(cn_f == SIZE(finite%line%q)/6, 'endconn: public End A maps to internal final node')
      CALL require(finite%line%has_endconn .AND. ABS(finite%line%endconn_k(1)) <= TINY(1.0_wp) .AND. &
                   ABS(finite%line%endconn_k(2) - 20000.0_wp) <= TINY(1.0_wp), &
                   'endconn: stiffness maps from public [A,B] to internal [B,A]')
      CALL require(nan_max_abs(finite%line%endconn_d0(:, 2) - [0.0_wp, 0.0_wp, 1.0_wp]) <= 1.0e-14_wp, &
                   'endconn: public A-to-B Ez maps to internal anchor-to-fairlead tangent direction')
      CALL CD_HFMF_GetCoupledKinematics(finite, pos, vel, acc, es, em)
      CALL CD_HFMF_CalcOutput(finite, force, es, em, moment)
      CALL require(es == CD_HFMF_OK .AND. SQRT(SUM(moment**2)) > 1.0_wp, &
                   'endconn: finite connection returns a non-zero support moment')
      CALL CD_HFMF_UpdateStates(finite, pos, vel, acc, es, em)
      CALL require(es == CD_HFMF_OK, 'endconn: finite deck completes a held dynamic step: '//TRIM(em))
      CALL CD_HFMF_CalcOutput(finite, force, es, em, moment)
      CALL require(es == CD_HFMF_OK .AND. ALL(ABS(moment) < HUGE(1.0_wp)), &
                   'endconn: dynamic support moment remains finite')

      ! Rotate the host parent about global x while holding its attachment point.
      ! The parent-relative no-moment direction acquires an out-of-plane component;
      ! the production dynamic model must respond in 3D, not merely report a moment
      ! against a cable whose y DOFs were artificially frozen.
      CALL CD_HFMF_Snapshot(finite, es, em)
      CALL require(es == CD_HFMF_OK, 'endconn: snapshot before parent rotation')
      d0_saved = finite%line%endconn_d0
      DO s = 1, 20
        angle = (5.0_wp*3.141592653589793_wp/180.0_wp)*REAL(s, wp)/20.0_wp
        dcm = 0.0_wp
        dcm(1, 1) = 1.0_wp
        dcm(2, 2) = COS(angle); dcm(2, 3) = SIN(angle)
        dcm(3, 2) = -SIN(angle); dcm(3, 3) = COS(angle)
        CALL CD_HFMF_UpdateStates(finite, pos, vel, acc, es, em, u_orientation=dcm)
        IF (es /= CD_HFMF_OK) EXIT
      END DO
      CALL require(es == CD_HFMF_OK, 'endconn: rotating parent direction advances: '//TRIM(em))
      CALL require(ABS(finite%line%endconn_d0(2, 2)) > 1.0e-3_wp, &
                   'endconn: parent rotation updates the coupled no-moment direction')
      ymax = 0.0_wp
      DO i = 2, SIZE(finite%line%q)/6 - 1
        ymax = MAX(ymax, ABS(finite%line%q(6*(i - 1) + 2)))
      END DO
      CALL require(ymax > 1.0e-10_wp, 'endconn: parent rotation produces a physical out-of-plane cable response')
      CALL CD_HFMF_Restore(finite, es, em)
      CALL require(es == CD_HFMF_OK .AND. nan_max_abs(finite%line%endconn_d0 - d0_saved) <= 0.0_wp, &
                   'endconn: snapshot restore rewinds the parent-relative direction exactly')
    END IF

    ! Stock MoorDyn endpoint order is Fixed A -> Coupled B, opposite to the
    ! CableDyn public order used above.  Normalization must move the connection
    ! to the same physical end and reverse its A-to-B reference direction.
    CALL write_cable_deck('hcab_deck_endconn_stock.dat', endconn_row='1 B 20000 0 0 1', stock_order=.TRUE.)
    CALL CD_Init_Deck_HermiteCable('hcab_deck_endconn_stock.dat', 0.05_wp, stock, cn_s, es, em)
    CALL require(es == CD_DECKDRV_OK, 'endconn: stock endpoint-order deck initializes: '//TRIM(em))
    IF (es == CD_DECKDRV_OK) THEN
      CALL require(cn_s == cn_f .AND. &
                   nan_max_abs(stock%line%endconn_k - finite%line%endconn_k) <= 0.0_wp .AND. &
                   nan_max_abs(stock%line%endconn_d0 - finite%line%endconn_d0) <= 0.0_wp, &
                   'endconn: stock-order End B normalizes to the physical coupled end')
    END IF

    CALL write_cable_deck('hcab_deck_endconn_rigid.dat', endconn_row='1 A Rigid -0.24716 0 -0.968975')
    CALL CD_Init_Deck_HermiteCable('hcab_deck_endconn_rigid.dat', 0.05_wp, rigid, cn_r, es, em)
    CALL require(es == CD_DECKDRV_OK, 'endconn: exact Rigid deck initializes: '//TRIM(em))
    IF (es == CD_DECKDRV_OK) THEN
      CALL require(rigid%line%endconn_mode(2) == CD_ENDCONN_RIGID .AND. &
                   ABS(rigid%line%endconn_k(2)) <= TINY(1.0_wp), &
                   'endconn: Rigid maps to an exact constraint, not a penalty stiffness')
      tangent = rigid%line%q(6*(cn_r - 1) + 4:6*(cn_r - 1) + 6)
      tangent_norm = SQRT(DOT_PRODUCT(tangent, tangent))
      CALL require(nan_max_abs(tangent/tangent_norm - rigid%line%endconn_d0(:, 2)) <= &
                   128.0_wp*EPSILON(1.0_wp), &
                   'endconn: deck Rigid direction is enforced to round-off')
      CALL CD_HFMF_GetCoupledKinematics(rigid, pos, vel, acc, es, em)
      CALL CD_HFMF_CalcOutput(rigid, force, es, em, moment)
      CALL require(es == CD_HFMF_OK .AND. SQRT(SUM(moment**2)) > 1.0_wp, &
                   'endconn: exact Rigid connection exports its support moment')
      CALL CD_HFMF_UpdateStates(rigid, pos, vel, acc, es, em)
      CALL require(es == CD_HFMF_OK, 'endconn: exact Rigid deck completes a held dynamic step: '//TRIM(em))
    END IF

    CALL CD_HFMF_End(omitted)
    CALL CD_HFMF_End(pinned)
    CALL CD_HFMF_End(finite)
    CALL CD_HFMF_End(rigid)
    CALL CD_HFMF_End(stock)
  END SUBROUTINE case_end_connections

  SUBROUTINE case_end_connection_rejections()
    TYPE(CD_HFMF_ModuleType) :: cable
    INTEGER :: cn, es
    CHARACTER(256) :: em

    CALL write_cable_deck('hcab_deck_endconn_negative.dat', endconn_row='1 A -1 0 0 -1')
    CALL CD_Init_Deck_HermiteCable('hcab_deck_endconn_negative.dat', 0.05_wp, cable, cn, es, em)
    CALL require(es == CD_DECKDRV_BADINPUT .AND. INDEX(em, 'stiffness') > 0, &
                 'endconn: negative stiffness fails closed')

    CALL write_cable_deck('hcab_deck_endconn_null.dat', endconn_row='1 A 20000 0 0 0')
    CALL CD_Init_Deck_HermiteCable('hcab_deck_endconn_null.dat', 0.05_wp, cable, cn, es, em)
    CALL require(es == CD_DECKDRV_BADINPUT .AND. INDEX(em, 'non-zero') > 0, &
                 'endconn: null no-moment direction fails closed')

    CALL write_cable_deck('hcab_deck_endconn_duplicate.dat', endconn_row='1 A 20000 0 0 -1', &
                          second_endconn_row='1 EndA 10000 1 0 0')
    CALL CD_Init_Deck_HermiteCable('hcab_deck_endconn_duplicate.dat', 0.05_wp, cable, cn, es, em)
    CALL require(es == CD_DECKDRV_BADINPUT .AND. INDEX(em, 'duplicate') > 0, &
                 'endconn: duplicate line-end row fails closed')

  END SUBROUTINE case_end_connection_rejections

  SUBROUTINE case_azimuthal_frame_objectivity()
    !! An AZIMUTHAL cable (nonzero chord y-span) now solves in a chord-local frame -- the
    !! out-of-plane constraint rotates with the chord, and the FMF boundary rotates
    !! kinematics in / loads out. FRAME OBJECTIVITY is the gate: the planar deck rotated
    !! bodily about +z by an arbitrary heading, driven by the SAME physical motion
    !! (rotated), must reproduce the planar solution exactly rotated -- coupled position,
    !! fairlead load, and (rotation-invariant) curvature -- at every compared step. A
    !! frame error anywhere (a missed rotation, a wrong transpose, an over-frozen DOF)
    !! breaks this equality at leading order.
    TYPE(CD_HFMF_ModuleType), ALLOCATABLE :: cab_p, cab_r   ! see DEVELOPMENT.md (gfortran 16 -Wuninitialized)
    INTEGER :: cn_p, cn_r, es, s, nn
    CHARACTER(256) :: em
    REAL(wp), PARAMETER :: DT = 0.05_wp, AMP = 1.0_wp, PER = 12.0_wp
    REAL(wp), PARAMETER :: PI = 3.141592653589793_wp
    REAL(wp), PARAMETER :: THETA = 37.0_wp*PI/180.0_wp
    INTEGER, PARAMETER :: NSTEP = 60
    REAL(wp) :: c, sth, a0(3), f0(3), ends_r(3, 2)
    REAL(wp) :: r0p(3), r0r(3), vp(3), ap(3), t, zh, vh, ah
    REAL(wp) :: up(3), uv(3), ua(3), yp(3), yr(3), yp_rot(3), lerr, lref
    REAL(wp), ALLOCATABLE :: curv_p(:), curv_r(:)

    ALLOCATE (cab_p, cab_r)
    c = COS(THETA); sth = SIN(THETA)
    a0 = [0.0_wp, 0.0_wp, -56.0_wp]
    f0 = [90.0_wp, 0.0_wp, -14.0_wp]
    ends_r(:, 1) = [c*a0(1) - sth*a0(2), sth*a0(1) + c*a0(2), a0(3)]
    ends_r(:, 2) = [c*f0(1) - sth*f0(2), sth*f0(1) + c*f0(2), f0(3)]

    CALL write_cable_deck('hcab_deck_frame_p.dat')
    CALL CD_Init_Deck_HermiteCable('hcab_deck_frame_p.dat', DT, cab_p, cn_p, es, em)
    CALL require(es == CD_DECKDRV_OK, 'frame: planar init: '//TRIM(em))
    IF (es /= CD_DECKDRV_OK) RETURN
    CALL write_cable_deck('hcab_deck_frame_r.dat', endpoints=ends_r)
    CALL CD_Init_Deck_HermiteCable('hcab_deck_frame_r.dat', DT, cab_r, cn_r, es, em)
    CALL require(es == CD_DECKDRV_OK, 'frame: rotated (azimuthal) init: '//TRIM(em))
    IF (es /= CD_DECKDRV_OK) THEN
      CALL CD_HFMF_End(cab_p)
      RETURN
    END IF

    ! the rotated build's GLOBAL coupled position is the rotation of the planar one
    CALL CD_HFMF_GetCoupledKinematics(cab_p, r0p, vp, ap, es, em)
    CALL require(es == CD_HFMF_OK, 'frame: planar coupled read')
    CALL CD_HFMF_GetCoupledKinematics(cab_r, r0r, vp, ap, es, em)
    CALL require(es == CD_HFMF_OK, 'frame: rotated coupled read')
    CALL require(nan_max_abs(r0r - [c*r0p(1) - sth*r0p(2), sth*r0p(1) + c*r0p(2), r0p(3)]) <= 1.0e-8_wp, &
                 'frame: rotated coupled position == Rz(theta) * planar')

    nn = SIZE(cab_p%line%q)/6
    ALLOCATE (curv_p(nn), curv_r(nn))
    DO s = 1, NSTEP
      t = REAL(s, wp)*DT
      zh = AMP*(1.0_wp - COS(2.0_wp*PI*t/PER))
      vh = AMP*(2.0_wp*PI/PER)*SIN(2.0_wp*PI*t/PER)
      ah = AMP*(2.0_wp*PI/PER)**2*COS(2.0_wp*PI*t/PER)
      up = [r0p(1), r0p(2), r0p(3) + zh]
      uv = [0.0_wp, 0.0_wp, vh]
      ua = [0.0_wp, 0.0_wp, ah]
      CALL CD_HFMF_UpdateStates(cab_p, up, uv, ua, es, em)
      CALL require(es == CD_HFMF_OK, 'frame: planar step: '//TRIM(em))
      IF (es /= CD_HFMF_OK) EXIT
      ! the same physical drive, expressed in the rotated global frame
      CALL CD_HFMF_UpdateStates(cab_r, [c*up(1) - sth*up(2), sth*up(1) + c*up(2), up(3)], uv, ua, es, em)
      CALL require(es == CD_HFMF_OK, 'frame: rotated step: '//TRIM(em))
      IF (es /= CD_HFMF_OK) EXIT
      CALL CD_HFMF_CalcOutput(cab_p, yp, es, em)
      CALL CD_HFMF_CalcOutput(cab_r, yr, es, em)
      yp_rot = [c*yp(1) - sth*yp(2), sth*yp(1) + c*yp(2), yp(3)]
      lref = MAX(1.0_wp, SQRT(SUM(yp**2)))
      lerr = SQRT(SUM((yr - yp_rot)**2))/lref
      CALL require(lerr <= 1.0e-6_wp, 'frame: rotated fairlead load == Rz(theta) * planar load')
      IF (lerr > 1.0e-6_wp) EXIT
    END DO
    CALL CD_HFMF_Curvature(cab_p, curv_p, es, em)
    CALL CD_HFMF_Curvature(cab_r, curv_r, es, em)
    CALL require(nan_max_abs(curv_r - curv_p) <= 1.0e-8_wp, &
                 'frame: curvature profile is rotation-invariant')
    CALL CD_HFMF_End(cab_p)
    CALL CD_HFMF_End(cab_r)
  END SUBROUTINE case_azimuthal_frame_objectivity

  SUBROUTINE case_reject_motionfile()
    !! A coupled cable is driven at the fairlead by the host (CD_HFMF_UpdateStates). A deck that
    !! declares a motionFile prescribes the fairlead motion itself -- the wrong boundary -- so it
    !! must fail closed, not be silently dropped. parse_deck accepts a motionFile in caller_driven
    !! mode (it only needs dtM/TMax, which this deck has), so the reject must be the builder's.
    TYPE(CD_HFMF_ModuleType) :: cable
    INTEGER :: cn, es
    CHARACTER(256) :: em
    CALL write_cable_deck('hcab_deck_motion.dat', extra_option='motion.dat motionFile')
    CALL CD_Init_Deck_HermiteCable('hcab_deck_motion.dat', 0.05_wp, cable, cn, es, em)
    CALL require(es == CD_DECKDRV_BADINPUT, 'deck declaring a motionFile fails closed: '//TRIM(em))
  END SUBROUTINE case_reject_motionfile

  SUBROUTINE case_coupled_seabed_contact()
    !! The direct coupled-cable facade uses the same Hermite contact model as the aggregate:
    !! install the flat bed and friction, solve a touchdown equilibrium, and march a held step.
    TYPE(CD_HFMF_ModuleType) :: cable
    INTEGER :: cn, es
    CHARACTER(256) :: em
    REAL(wp) :: u_pos(3), load(3), min_z
    INTEGER :: base
    CALL write_cable_deck('hcab_deck_seabed.dat', extra_option='60.0 WtrDpth', &
                          second_extra_option='0.35 frictionMu')
    CALL CD_Init_Deck_HermiteCable('hcab_deck_seabed.dat', 0.05_wp, cable, cn, es, em)
    CALL require(es == CD_DECKDRV_OK, 'coupled seabed contact initializes: '//TRIM(em))
    IF (es /= CD_DECKDRV_OK) RETURN
    CALL require(cable%line%has_contact, 'coupled seabed contact is installed')
    CALL require(.NOT. cable%line%has_contact_bathymetry, 'WtrDpth selects the flat-bed model')
    CALL require(ABS(cable%line%contact_mu - 0.35_wp) <= 0.0_wp, 'coupled friction is installed')
    min_z = CD_HFMF_MinSpanZ(cable)
    CALL require(min_z >= -60.5_wp .AND. min_z <= -59.9_wp, 'coupled cable touches the declared bed')
    base = 6*(cn - 1)
    u_pos = cable%line%q(base + 1:base + 3)
    CALL CD_HFMF_UpdateStates(cable, u_pos, [0.0_wp, 0.0_wp, 0.0_wp], &
                              [0.0_wp, 0.0_wp, 0.0_wp], es, em)
    CALL require(es == CD_HFMF_OK, 'held coupled contact step converges: '//TRIM(em))
    CALL CD_HFMF_CalcOutput(cable, load, es, em)
    CALL require(es == CD_HFMF_OK .AND. ALL(ABS(load) < HUGE(1.0_wp)), &
                 'coupled contact load is finite')
    CALL CD_HFMF_End(cable)
  END SUBROUTINE case_coupled_seabed_contact

  SUBROUTINE case_grounded_anchor_end()
    !! A lazy-wave power cable laid on a frictional flat bed up to its pinned anchor on the floor
    !! (Line 4 of examples/iea15mw_umaine_mixed_cabledyn.dat on its former mesh: 200 m depth, kBot
    !! 3e6, frictionMu 0.35, 10 m grounded elements). The seabed carries the weight of the anchor
    !! element, so its free end tangent stays along the floor; turned into the floor by the
    !! unbalanced end moment of the weight, the element dipped about 27 mm below the bed, carried
    !! axial forces from -47 kN to +127 kN about the 1.2 kN line tension, and buckled sideways once
    !! the hang-off swayed, after which the friction locked the anchor tension at about 2.5 times
    !! its static value while the line slackened.
    TYPE(CD_HFMF_ModuleType), ALLOCATABLE :: cable
    INTEGER :: cn, es, base, k
    CHARACTER(256) :: em
    REAL(wp) :: u0(3), u_pos(3), u_vel(3), u_acc(3), f(3), t, r, rd, rdd, s, c, ten0, ten_max, tz
    REAL(wp), PARAMETER :: DT = 0.025_wp, AMP = 2.0_wp, PER = 10.0_wp, RAMP = 5.0_wp, TEND = 30.0_wp
    REAL(wp), PARAMETER :: PI = 3.141592653589793_wp
    INTEGER :: u, ios
    OPEN (NEWUNIT=u, FILE='hcab_deck_grounded_anchor.dat', STATUS='REPLACE', ACTION='WRITE', IOSTAT=ios)
    WRITE (u, '(A)') 'lazy-wave power cable laid on a frictional bed up to its anchor'
    WRITE (u, '(A)') '--- LINE TYPES ---'
    WRITE (u, '(A)') 'Name Diam Mass EA BA EI Cdn Cdt Can Cat'
    WRITE (u, '(A)') '(-) (m) (kg/m) (N) (-) (Nm2) (-) (-) (-) (-)'
    WRITE (u, '(A)') 'bare 0.16 36.70 4.69e8 0.0 1.99e4 1.2 0.1 1.0 0.0'
    WRITE (u, '(A)') 'buoy 0.29 59.53 4.69e8 0.0 1.99e4 1.2 0.1 1.0 0.0'
    WRITE (u, '(A)') '--- POINTS ---'
    WRITE (u, '(A)') 'ID Type X Y Z'
    WRITE (u, '(A)') '(-) (-) (m) (m) (m)'
    WRITE (u, '(A)') '1 Coupled 30.0 0.0 -20.0'
    WRITE (u, '(A)') '2 Fixed 500.0 0.0 -200.0'
    WRITE (u, '(A)') '--- LINES ---'
    WRITE (u, '(A)') 'ID NodeA NodeB Outputs'
    WRITE (u, '(A)') '(-) (-) (-) (-)'
    WRITE (u, '(A)') '1 1 2 -'
    WRITE (u, '(A)') '--- SECTIONS ---'
    WRITE (u, '(A)') 'LineID LineType Length NumSegs'
    WRITE (u, '(A)') '(-) (-) (m) (-)'
    WRITE (u, '(A)') '1 bare 80.0 20'
    WRITE (u, '(A)') '1 buoy 100.0 25'
    WRITE (u, '(A)') '1 bare 420.0 42'
    WRITE (u, '(A)') '--- OPTIONS ---'
    WRITE (u, '(A)') '9.80665 g'
    WRITE (u, '(A)') '1025.0 rhoW'
    WRITE (u, '(A)') '200.0 WtrDpth'
    WRITE (u, '(A)') '3.0e6 kBot'
    WRITE (u, '(A)') '3.0e5 cBot'
    WRITE (u, '(A)') '0.35 frictionMu'
    WRITE (u, '(A)') '0.4 rhoInf'
    WRITE (u, '(A)') '--- need this line ---'
    CLOSE (u)
    ALLOCATE (cable)
    CALL CD_Init_Deck_HermiteCable('hcab_deck_grounded_anchor.dat', DT, cable, cn, es, em)
    CALL require(es == CD_DECKDRV_OK, 'grounded-anchor cable initializes: '//TRIM(em))
    IF (es /= CD_DECKDRV_OK) RETURN
    CALL require(cable%line%fr_active, 'grounded-anchor cable carries seabed friction')
    ! The anchor is model node 1: its end tangent lies along the floor in the static state.
    tz = ABS(cable%line%q(6))/NORM2(cable%line%q(4:6))
    CALL require(tz <= 1.0e-3_wp, 'anchor end tangent stays along the floor')
    IF (tz > 1.0e-3_wp) WRITE (*, '(A,ES12.4)') '  anchor tangent z share ', tz
    CALL CD_HermiteCable_Dyn_End_Force(cable%line, 1, f, es, em)
    CALL require(es == CD_HCDYN_OK, 'static anchor force: '//TRIM(em))
    ten0 = NORM2(f)
    ! Sway the hang-off sideways (2 m, 10 s, C2 quintic start): the in-plane line is then
    ! perturbed out of its plane, which seeds the end-element buckling within ~25 s.
    base = 6*(cn - 1)
    u0 = cable%line%q(base + 1:base + 3)
    ten_max = ten0
    DO k = 1, NINT(TEND/DT)
      t = k*DT
      IF (t < RAMP) THEN
        s = t/RAMP
        r = 10.0_wp*s**3 - 15.0_wp*s**4 + 6.0_wp*s**5
        rd = (30.0_wp*s**2 - 60.0_wp*s**3 + 30.0_wp*s**4)/RAMP
        rdd = (60.0_wp*s - 180.0_wp*s**2 + 120.0_wp*s**3)/RAMP**2
      ELSE
        r = 1.0_wp; rd = 0.0_wp; rdd = 0.0_wp
      END IF
      s = SIN(2.0_wp*PI*t/PER)
      c = COS(2.0_wp*PI*t/PER)
      u_pos = u0 + [0.0_wp, AMP*r*s, 0.0_wp]
      u_vel = [0.0_wp, AMP*(rd*s + r*(2.0_wp*PI/PER)*c), 0.0_wp]
      u_acc = [0.0_wp, AMP*(rdd*s + 2.0_wp*rd*(2.0_wp*PI/PER)*c - r*(2.0_wp*PI/PER)**2*s), 0.0_wp]
      CALL CD_HFMF_UpdateStates(cable, u_pos, u_vel, u_acc, es, em)
      IF (es /= CD_HFMF_OK) EXIT
      CALL CD_HermiteCable_Dyn_End_Force(cable%line, 1, f, es, em)
      IF (es /= CD_HCDYN_OK) EXIT
      ten_max = MAX(ten_max, NORM2(f))
    END DO
    CALL require(es == CD_HFMF_OK, 'swayed grounded-anchor march converges: '//TRIM(em))
    CALL require(ten_max <= 1.1_wp*ten0, 'friction does not ratchet the anchor tension up')
    IF (ten_max > 1.1_wp*ten0) WRITE (*, '(A,2ES12.4)') '  anchor tension static / peak ', ten0, ten_max
    CALL CD_HFMF_End(cable)
  END SUBROUTINE case_grounded_anchor_end

  SUBROUTINE write_cable_deck(path, extra_option, fairlead_y, omit_time, endpoints, second_extra_option, &
                              endconn_row, second_endconn_row, stock_order, ba_value)
    !! A realistic dynamic power cable in the LAZY-WAVE configuration -- the flagship regime and
    !! the one the finite-EI Hermite dynamics is robust in (the buoyancy keeps the whole cable in
    !! tension, so it responds smoothly to fairlead heave; a plain slack catenary instead buckles
    !! its slackening elements into a kink under motion). Bare + buoyancy-module properties from
    !! the Humboldt / GoMex 15 MW reference used by the l3_lazywave gates: EA 4.69e8, EI 1.99e4;
    !! bare 36.7 kg/m / D 0.16 (submerged +158 N/m), buoy 59.53 kg/m / D 0.29 (net buoyant
    !! -80 N/m). Three sections bare/buoy/bare form the S; the builder's arch seed + buoyancy
    !! continuation solves it, and the coupled shell drives the hang-off fairlead. EI > 0.
    CHARACTER(*), INTENT(IN) :: path
    CHARACTER(*), INTENT(IN), OPTIONAL :: extra_option
    CHARACTER(*), INTENT(IN), OPTIONAL :: second_extra_option
    CHARACTER(*), INTENT(IN), OPTIONAL :: endconn_row, second_endconn_row
    REAL(wp), INTENT(IN), OPTIONAL :: fairlead_y
    LOGICAL, INTENT(IN), OPTIONAL :: omit_time   ! skip the dtM/TMax OPTIONS (caller-driven decks)
    LOGICAL, INTENT(IN), OPTIONAL :: stock_order
    REAL(wp), INTENT(IN), OPTIONAL :: ba_value
    REAL(wp), INTENT(IN), OPTIONAL :: endpoints(3, 2)   ! [anchor | fairlead] override, round-trip-exact
    REAL(wp) :: fy, ba_deck
    LOGICAL :: no_time
    INTEGER :: u, ios
    fy = 0.0_wp
    IF (PRESENT(fairlead_y)) fy = fairlead_y
    ba_deck = 0.0_wp
    IF (PRESENT(ba_value)) ba_deck = ba_value
    no_time = .FALSE.
    IF (PRESENT(omit_time)) no_time = omit_time
    OPEN (NEWUNIT=u, FILE=path, STATUS='REPLACE', ACTION='WRITE', IOSTAT=ios)
    WRITE (u, '(A)') 'finite-EI lazy-wave power cable, coupled at the fairlead'
    WRITE (u, '(A)') '--- LINE TYPES ---'
    WRITE (u, '(A)') 'Name Diam Mass EA BA EI Cdn Cdt Can Cat'
    WRITE (u, '(A)') '(-) (m) (kg/m) (N) (-) (Nm2) (-) (-) (-) (-)'
    WRITE (u, '(A,ES24.16,A)') 'bare 0.16 36.70 4.69e8 ', ba_deck, ' 1.99e4 1.2 0.1 1.0 0.0'
    WRITE (u, '(A,ES24.16,A)') 'buoy 0.29 59.53 4.69e8 ', ba_deck, ' 1.99e4 1.2 0.1 1.0 0.0'
    WRITE (u, '(A)') '--- POINTS ---'
    WRITE (u, '(A)') 'ID Type X Y Z'
    WRITE (u, '(A)') '(-) (-) (m) (m) (m)'
    IF (PRESENT(endpoints)) THEN
      WRITE (u, '(A,3ES25.16)') '1 Fixed ', endpoints(:, 1)
      WRITE (u, '(A,3ES25.16)') '2 Coupled ', endpoints(:, 2)
    ELSE
      WRITE (u, '(A)') '1 Fixed 0.0 0.0 -56.0'
      WRITE (u, '(A,F0.4,A)') '2 Coupled 90.0 ', fy, ' -14.0'
    END IF
    WRITE (u, '(A)') '--- LINES ---'
    WRITE (u, '(A)') 'ID NodeA NodeB Outputs'
    WRITE (u, '(A)') '(-) (-) (-) (-)'
    IF (PRESENT(stock_order)) THEN
      IF (stock_order) THEN
        WRITE (u, '(A)') '1 1 2 -'
      ELSE
        WRITE (u, '(A)') '1 2 1 -'
      END IF
    ELSE
      WRITE (u, '(A)') '1 2 1 -'
    END IF
    WRITE (u, '(A)') '--- SECTIONS ---'
    WRITE (u, '(A)') 'LineID LineType Length NumSegs'
    WRITE (u, '(A)') '(-) (-) (m) (-)'
    WRITE (u, '(A)') '1 bare 40.0 13'
    WRITE (u, '(A)') '1 buoy 50.0 16'
    WRITE (u, '(A)') '1 bare 55.0 18'
    IF (PRESENT(endconn_row)) THEN
      WRITE (u, '(A)') '--- END CONNECTIONS ---'
      WRITE (u, '(A)') 'LineID End Stiffness EzX EzY EzZ'
      WRITE (u, '(A)') '(-) (-) (N-m/rad) (-) (-) (-)'
      WRITE (u, '(A)') TRIM(endconn_row)
      IF (PRESENT(second_endconn_row)) WRITE (u, '(A)') TRIM(second_endconn_row)
    END IF
    WRITE (u, '(A)') '--- OPTIONS ---'
    WRITE (u, '(A)') '9.80665 g'
    WRITE (u, '(A)') '1025.0 rhoW'
    ! With no WtrDpth/bathymetryFile this is a suspended lazy-wave. Supplying either option
    ! activates the same finite-EI normal-contact/friction model in standalone and coupled use.
    WRITE (u, '(A)') '0.5 rhoInf'
    IF (PRESENT(extra_option)) WRITE (u, '(A)') TRIM(extra_option)
    IF (PRESENT(second_extra_option)) WRITE (u, '(A)') TRIM(second_extra_option)
    ! A caller-driven finite-EI deck does not NEED dtM/TMax -- the coupled builder marches at
    ! the caller-supplied dt argument, not the deck's dtM. omit_time exercises that relaxation;
    ! otherwise write them (a standalone finite-EI deck still requires them).
    IF (.NOT. no_time) THEN
      WRITE (u, '(A)') '0.05 dtM'
      WRITE (u, '(A)') '1.0 TMax'
    END IF
    WRITE (u, '(A)') '--- need this line ---'
    CLOSE (u)
  END SUBROUTINE write_cable_deck

  SUBROUTINE write_ei0_deck(path)
    !! An EI=0 chain (no bending) -- must be rejected by the Hermite-cable builder.
    CHARACTER(*), INTENT(IN) :: path
    INTEGER :: u, ios
    OPEN (NEWUNIT=u, FILE=path, STATUS='REPLACE', ACTION='WRITE', IOSTAT=ios)
    WRITE (u, '(A)') 'EI=0 chain'
    WRITE (u, '(A)') '--- LINE TYPES ---'
    WRITE (u, '(A)') 'Name Diam Mass EA BA EI Cdn Cdt Can Cat'
    WRITE (u, '(A)') '(-) (m) (kg/m) (N) (-) (Nm2) (-) (-) (-) (-)'
    WRITE (u, '(A)') 'chain 0.252 390.0 1.674e9 -1.0 0.0 1.37 0.64 1.0 0.0'
    WRITE (u, '(A)') '--- POINTS ---'
    WRITE (u, '(A)') 'ID Type X Y Z'
    WRITE (u, '(A)') '(-) (-) (m) (m) (m)'
    WRITE (u, '(A)') '1 Fixed 400.0 0.0 -50.0'
    WRITE (u, '(A)') '2 Coupled 0.0 0.0 0.0'
    WRITE (u, '(A)') '--- LINES ---'
    WRITE (u, '(A)') 'ID NodeA NodeB Outputs'
    WRITE (u, '(A)') '(-) (-) (-) (-)'
    WRITE (u, '(A)') '1 2 1 -'
    WRITE (u, '(A)') '--- SECTIONS ---'
    WRITE (u, '(A)') 'LineID LineType Length NumSegs'
    WRITE (u, '(A)') '(-) (-) (m) (-)'
    WRITE (u, '(A)') '1 chain 410.0 41'
    WRITE (u, '(A)') '--- OPTIONS ---'
    WRITE (u, '(A)') '9.80665 g'
    WRITE (u, '(A)') '1025.0 rhoW'
    WRITE (u, '(A)') '50.0 WtrDpth'
    WRITE (u, '(A)') '1.0e5 kBot'
    WRITE (u, '(A)') '--- need this line ---'
    CLOSE (u)
  END SUBROUTINE write_ei0_deck
END PROGRAM test_deck_hermite_cable
