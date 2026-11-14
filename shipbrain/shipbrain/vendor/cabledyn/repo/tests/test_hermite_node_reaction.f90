! File: tests/test_hermite_node_reaction.f90
! SPDX-License-Identifier: Apache-2.0
! Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
PROGRAM test_hermite_node_reaction
  !! CD_HermiteCable_Dyn_Reaction assembles only the rows of its node (the one or two elements
  !! that reach it and the node's own terms). It must equal the reaction of the full assembly
  !! bit for bit at every node and leave the model's residual and mass scratch untouched:
  !!   A. hand-built cables with every load section a node can receive (structure, weight,
  !!      dry buoyancy, contact with friction on a controlled seabed, axial damping, drag in a
  !!      current, added mass and Froude-Krylov loads; Airy waves, or a held fluid field with
  !!      attachments; finite, rigid or no end connections), at scattered states;
  !!   B. the maintained IEA-15 MW mixed mooring example through the OpenFAST aggregate, along a
  !!      coupled surge and heave trajectory in a current, and after a fairlead transfer without
  !!      a step (the state the OpenFAST CalcOutput evaluates).
  USE CableDyn_Precision, ONLY: wp
  USE CableDyn_HermiteCableDynamic, ONLY: CD_HermiteCableDynType, CD_HermiteCable_Dyn_Init, &
                                          CD_HermiteCable_Dyn_Reaction, CD_HermiteCable_Dyn_Set_Contact, &
                                          CD_HermiteCable_Dyn_Set_Control_Seabed, &
                                          CD_HermiteCable_Dyn_Set_Attachments, CD_HermiteCable_Dyn_Set_Axial_Damping, &
                                          CD_HermiteCable_Dyn_Set_Drag, CD_HermiteCable_Dyn_Set_AddedMass, &
                                          CD_HermiteCable_Dyn_Set_Waves, CD_HermiteCable_Dyn_Set_Held_Fluid, &
                                          CD_HermiteCable_Dyn_Set_EndConnection, CD_HermiteCable_Dyn_End, &
                                          CD_HCDYN_OK
  USE CableDyn_EndConnection, ONLY: CD_ENDCONN_FINITE, CD_ENDCONN_RIGID
  USE CableDyn_Line, ONLY: CD_Nodal_Seabed_Stiffness, CD_LINE_OK
  USE CableDyn_OpenFAST_Aggregate, ONLY: CD_AGG_ModuleType, CD_AGG_Init_From_Deck, CD_AGG_NMovingPoints, &
                                         CD_AGG_NFluidNodes, CD_AGG_GetMovingPointMesh, CD_AGG_SetFluidFields, &
                                         CD_AGG_Step_Moving, CD_AGG_UpdateStates_Moving, CD_AGG_End, CD_AGG_OK
  USE, INTRINSIC :: ISO_FORTRAN_ENV, ONLY: INT64
  IMPLICIT NONE

  INTEGER :: nfail, ncompared
  INTEGER(INT64) :: seed

  nfail = 0
  ncompared = 0
  seed = 20261021_INT64
  CALL case_hand_built(waves=.TRUE., mode=CD_ENDCONN_FINITE)
  CALL case_hand_built(waves=.FALSE., mode=CD_ENDCONN_FINITE)
  CALL case_hand_built(waves=.FALSE., mode=CD_ENDCONN_RIGID)
  CALL case_hand_built(waves=.TRUE., mode=-1)
  IF (COMMAND_ARGUMENT_COUNT() >= 1) CALL case_mixed_example()
  IF (nfail > 0) THEN
    WRITE (*, '(A,I0,A)') 'FAIL: ', nfail, ' assertion(s) failed'
    ERROR STOP 1
  END IF
  WRITE (*, '(A,I0,A)') 'PASS: node reactions equal the full assembly bit for bit (', ncompared, ' nodes)'

CONTAINS

  SUBROUTINE require(cond, msg)
    LOGICAL, INTENT(IN) :: cond
    CHARACTER(*), INTENT(IN) :: msg
    IF (.NOT. cond) THEN
      WRITE (*, '(A)') 'FAIL: '//TRIM(msg)
      nfail = nfail + 1
    END IF
  END SUBROUTINE require

  REAL(wp) FUNCTION uniform() RESULT(u)
    !! Deterministic uniform deviate in [-1, 1) (xorshift64, no integer overflow), the same on
    !! every platform.
    seed = IEOR(seed, ISHFT(seed, 13))
    seed = IEOR(seed, ISHFT(seed, -7))
    seed = IEOR(seed, ISHFT(seed, 17))
    u = REAL(ISHFT(seed, -11), wp)/REAL(ISHFT(1_INT64, 53), wp)
    u = 2.0_wp*u - 1.0_wp
  END FUNCTION uniform

  LOGICAL FUNCTION same_bits(a, b) RESULT(same)
    REAL(wp), INTENT(IN) :: a(:), b(:)
    same = SIZE(a) == SIZE(b)
    IF (same) same = ALL(TRANSFER(a, 0_INT64, SIZE(a)) == TRANSFER(b, 0_INT64, SIZE(b)))
  END FUNCTION same_bits

  SUBROUTINE compare_nodes(model, label, nodes)
    !! At each node: the node reaction equals the full-assembly reaction bit for bit, and it
    !! leaves the residual and total-mass scratch of the full one untouched.
    TYPE(CD_HermiteCableDynType), INTENT(INOUT) :: model
    CHARACTER(*), INTENT(IN) :: label
    INTEGER, INTENT(IN) :: nodes(:)
    REAL(wp) :: f_full(3), f_node(3)
    REAL(wp), ALLOCATABLE :: r_saved(:), m_saved(:)
    INTEGER :: k, es1, es2
    CHARACTER(512) :: em
    CHARACTER(16) :: tag
    DO k = 1, SIZE(nodes)
      WRITE (tag, '(I0)') nodes(k)
      CALL CD_HermiteCable_Dyn_Reaction(model, nodes(k), f_full, es1, em, full_assembly=.TRUE.)
      CALL require(es1 == CD_HCDYN_OK, label//' node '//TRIM(tag)//': full reaction: '//TRIM(em))
      r_saved = model%ws_R
      m_saved = RESHAPE(model%ws_Msumb, [SIZE(model%ws_Msumb)])
      CALL CD_HermiteCable_Dyn_Reaction(model, nodes(k), f_node, es2, em)
      CALL require(es2 == CD_HCDYN_OK, label//' node '//TRIM(tag)//': node reaction: '//TRIM(em))
      CALL require(same_bits(f_node, f_full), label//' node '//TRIM(tag)//': node reaction equals the full one')
      CALL require(same_bits(model%ws_R, r_saved) .AND. &
                   same_bits(RESHAPE(model%ws_Msumb, [SIZE(model%ws_Msumb)]), m_saved), &
                   label//' node '//TRIM(tag)//': node reaction leaves the scratch untouched')
      IF (.NOT. same_bits(f_node, f_full)) WRITE (*, '(2A,3ES24.16/A,3ES24.16)') '  node ', TRIM(tag), f_node, &
        '  full ', f_full
      ncompared = ncompared + 1
    END DO
  END SUBROUTINE compare_nodes

  SUBROUTINE case_hand_built(waves, mode)
    !! A 20-element cable from a fixed anchor on a controlled seabed rising to a fixed top, with
    !! every node section, compared at all nodes over scattered positions (some below the bed),
    !! velocities and accelerations. Attachments take the held field, so they come with it;
    !! mode < 0 leaves the ends without a connection.
    LOGICAL, INTENT(IN) :: waves
    INTEGER, INTENT(IN) :: mode
    INTEGER, PARAMETER :: NE = 20, NN = NE + 1, NDOF = 6*NN
    REAL(wp), PARAMETER :: L = 2.0_wp, ZBED = -20.0_wp, KBOT = 1.0e5_wp, CBOT = 1.0e4_wp
    TYPE(CD_HermiteCableDynType) :: m
    REAL(wp) :: l0(NE), diam(NE), q(NDOF), d0(3, 2), k_rot(2), fv(3, NN), fa(3, NN), wl(NN), s, z
    REAL(wp), ALLOCATABLE :: kn(:), cn(:)
    INTEGER :: i, k, trial, es
    CHARACTER(512) :: em
    CHARACTER(32) :: label

    WRITE (label, '(A,L1,A,I0)') 'A waves=', waves, ' mode=', mode
    l0 = L
    diam = 0.15_wp
    q = 0.0_wp
    DO i = 1, NN
      ! laid on the bed for the first half, then rising at 45 degrees
      s = REAL(i - 1, wp)*L
      IF (i <= NN/2) THEN
        q(6*(i - 1) + 1) = s
        q(6*(i - 1) + 3) = ZBED
        q(6*(i - 1) + 4) = 1.0_wp
      ELSE
        q(6*(i - 1) + 1) = REAL(NN/2 - 1, wp)*L + (s - REAL(NN/2 - 1, wp)*L)/SQRT(2.0_wp)
        q(6*(i - 1) + 3) = ZBED + (s - REAL(NN/2 - 1, wp)*L)/SQRT(2.0_wp)
        q(6*(i - 1) + 4) = 1.0_wp/SQRT(2.0_wp)
        q(6*(i - 1) + 6) = 1.0_wp/SQRT(2.0_wp)
      END IF
    END DO
    CALL CD_HermiteCable_Dyn_Init(m, l0, [(1.0e6_wp, k=1, NE)], [(100.0_wp, k=1, NE)], [(5.0_wp, k=1, NE)], &
                                  [(30.0_wp, k=1, NE)], q, [1, 2, 3, NDOF - 5, NDOF - 4, NDOF - 3], ZBED, 0.0_wp, &
                                  0.5_wp, es, em)
    CALL require(es == CD_HCDYN_OK, TRIM(label)//': init: '//TRIM(em))
    IF (es /= CD_HCDYN_OK) RETURN
    CALL CD_HermiteCable_Dyn_Set_Axial_Damping(m, [(2.0e4_wp, k=1, NE)], es, em)
    CALL require(es == CD_HCDYN_OK, TRIM(label)//': damping: '//TRIM(em))
    CALL CD_Nodal_Seabed_Stiffness(KBOT, diam, l0, kn, es, em)
    CALL require(es == CD_LINE_OK, TRIM(label)//': seabed stiffness: '//TRIM(em))
    cn = kn*(CBOT/KBOT)
    CALL CD_HermiteCable_Dyn_Set_Contact(m, kn, cn, 0.3_wp, es, em)
    CALL require(es == CD_HCDYN_OK, TRIM(label)//': contact: '//TRIM(em))
    CALL CD_HermiteCable_Dyn_Set_Control_Seabed(m, KBOT, diam, CBOT/KBOT, es, em)
    CALL require(es == CD_HCDYN_OK, TRIM(label)//': control seabed: '//TRIM(em))
    CALL CD_HermiteCable_Dyn_Set_Drag(m, 1025.0_wp, diam, [(1.2_wp, k=1, NE)], [(0.008_wp, k=1, NE)], 0.0_wp, &
                                      [0.6_wp, 0.2_wp, 0.0_wp], es, em)
    CALL require(es == CD_HCDYN_OK, TRIM(label)//': drag: '//TRIM(em))
    CALL CD_HermiteCable_Dyn_Set_AddedMass(m, 1025.0_wp, diam, [(1.0_wp, k=1, NE)], [(0.1_wp, k=1, NE)], 0.0_wp, es, em)
    CALL require(es == CD_HCDYN_OK, TRIM(label)//': added mass: '//TRIM(em))
    IF (waves) THEN
      CALL CD_HermiteCable_Dyn_Set_Waves(m, 3.0_wp, 8.0_wp, 30.0_wp, -ZBED, 9.80665_wp, es, em)
      CALL require(es == CD_HCDYN_OK, TRIM(label)//': waves: '//TRIM(em))
    ELSE
      DO i = 1, NN
        fv(:, i) = [0.5_wp, 0.1_wp*REAL(i, wp)/REAL(NN, wp), 0.05_wp]
        fa(:, i) = [0.2_wp, -0.1_wp, 0.3_wp]
        wl(i) = 0.4_wp*SIN(REAL(i, wp))
      END DO
      CALL CD_HermiteCable_Dyn_Set_Held_Fluid(m, fv, fa, wl, es, em)
      CALL require(es == CD_HCDYN_OK, TRIM(label)//': held fluid: '//TRIM(em))
      ! attachments next to each end and in the span, so both end rows receive one
      CALL CD_HermiteCable_Dyn_Set_Attachments(m, [2, 7, NE], [50.0_wp, 80.0_wp, 20.0_wp], &
                                               [0.01_wp, 0.03_wp, 0.02_wp], [0.1_wp, 0.2_wp, 0.0_wp], &
                                               [0.05_wp, 0.1_wp, 0.0_wp], [1.0_wp, 1.0_wp, 0.5_wp], &
                                               1025.0_wp, 9.80665_wp, es, em)
      CALL require(es == CD_HCDYN_OK, TRIM(label)//': attachments: '//TRIM(em))
    END IF
    IF (mode >= 0) THEN
      d0(:, 1) = [1.0_wp, 0.0_wp, 0.0_wp]
      d0(:, 2) = [1.0_wp, 0.0_wp, 1.0_wp]/SQRT(2.0_wp)
      IF (mode == CD_ENDCONN_RIGID) THEN
        k_rot = 0.0_wp
      ELSE
        k_rot = [5.0e3_wp, 8.0e3_wp]
      END IF
      CALL CD_HermiteCable_Dyn_Set_EndConnection(m, k_rot, d0, es, em, connection_mode=[mode, mode])
      CALL require(es == CD_HCDYN_OK, TRIM(label)//': end connections: '//TRIM(em))
    END IF
    IF (nfail > 0) RETURN

    CALL compare_nodes(m, TRIM(label)//' rest', [(i, i=1, NN)])
    DO trial = 1, 6
      ! scattered state: positions within +-5 cm (bed nodes partly penetrating), velocities and
      ! accelerations of order 1, at a later time
      DO i = 1, NDOF
        m%q(i) = q(i) + 0.05_wp*uniform()
        m%v(i) = uniform()
        m%a(i) = 2.0_wp*uniform()
      END DO
      DO i = 1, NN
        z = q(6*(i - 1) + 3)
        IF (z <= ZBED) m%q(6*(i - 1) + 3) = ZBED - 0.02_wp*ABS(uniform())
      END DO
      m%t = 0.37_wp*REAL(trial, wp)
      CALL compare_nodes(m, TRIM(label)//' scattered', [(i, i=1, NN)])
    END DO
    CALL CD_HermiteCable_Dyn_End(m)
  END SUBROUTINE case_hand_built

  SUBROUTINE case_mixed_example()
    !! The mixed mooring example (EI = 0 chains and a grounded finite-EI power cable with contact,
    !! friction, drag and added mass, host fluid held per step) along 4 s of coupled surge and
    !! heave in a current, at every node of the cable every 0.5 s.
    REAL(wp), PARAMETER :: DT = 0.025_wp, DURATION = 4.0_wp, PERIOD = 4.0_wp
    TYPE(CD_AGG_ModuleType) :: agg
    CHARACTER(1024) :: deck
    CHARACTER(512) :: em
    REAL(wp), ALLOCATABLE :: p0(:, :), p(:, :), v(:, :), a(:, :), load(:, :), fv(:, :), fa(:, :), wl(:)
    REAL(wp) :: t, omega, pi
    INTEGER :: es, ncp, nf, s, ni, nn, i, ccol
    LOGICAL :: converged, stalled

    CALL GET_COMMAND_ARGUMENT(1, deck)
    CALL CD_AGG_Init_From_Deck(agg, TRIM(deck), DT, es, em, external_fluid=.TRUE.)
    CALL require(es == CD_AGG_OK, 'B: init: '//TRIM(em))
    IF (es /= CD_AGG_OK) RETURN
    CALL require(ALLOCATED(agg%cables), 'B: the example builds a finite-EI cable')
    IF (.NOT. ALLOCATED(agg%cables)) RETURN
    nn = agg%cables(1)%line%nn
    ncp = CD_AGG_NMovingPoints(agg, es, em)
    nf = CD_AGG_NFluidNodes(agg, es, em)
    ALLOCATE (p0(3, ncp), p(3, ncp), v(3, ncp), a(3, ncp), load(3, ncp), fv(3, nf), fa(3, nf), wl(nf))
    CALL CD_AGG_GetMovingPointMesh(agg, p0, v, a, load, es, em)
    CALL require(es == CD_AGG_OK, 'B: initial mesh: '//TRIM(em))
    CALL compare_nodes(agg%cables(1)%line, 'B static', [(i, i=1, nn)])
    fv = 0.0_wp
    fv(1, :) = 0.5_wp
    fa = 0.0_wp
    wl = 0.0_wp
    pi = ACOS(-1.0_wp)
    omega = 2.0_wp*pi/PERIOD
    DO s = 1, NINT(DURATION/DT)
      t = REAL(s, wp)*DT
      p = p0
      p(1, :) = p0(1, :) + 1.5_wp*SIN(omega*t)*MIN(t/PERIOD, 1.0_wp)
      p(3, :) = p0(3, :) + 0.8_wp*(1.0_wp - COS(omega*t))*MIN(t/PERIOD, 1.0_wp)
      v = 0.0_wp
      a = 0.0_wp
      CALL CD_AGG_SetFluidFields(agg, fv, fa, wl, es, em)
      IF (es == CD_AGG_OK) CALL CD_AGG_Step_Moving(agg, DT, p, v, a, converged, stalled, ni, es, em, t_committed=t)
      CALL require(es == CD_AGG_OK .AND. converged, 'B: step: '//TRIM(em))
      IF (es /= CD_AGG_OK .OR. .NOT. converged) EXIT
      IF (MOD(s, 20) == 0) CALL compare_nodes(agg%cables(1)%line, 'B march', [(i, i=1, nn)])
    END DO
    ! a fairlead transfer without a step: the end element carries the current kinematics against
    ! the committed interior, as in the OpenFAST CalcOutput
    ccol = agg%ncp_sys + 1
    p(:, ccol) = p(:, ccol) + [0.3_wp, -0.2_wp, 0.25_wp]
    v(:, ccol) = [0.4_wp, 0.1_wp, -0.3_wp]
    CALL CD_AGG_UpdateStates_Moving(agg, p, v, a, es, em)
    CALL require(es == CD_AGG_OK, 'B: transfer: '//TRIM(em))
    CALL compare_nodes(agg%cables(1)%line, 'B transfer', [1, 2, 3, nn - 2, nn - 1, nn])
    CALL CD_AGG_End(agg, es, em)
  END SUBROUTINE case_mixed_example

END PROGRAM test_hermite_node_reaction
