! File: tests/test_viv_coupled.f90
! SPDX-License-Identifier: Apache-2.0
! Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
PROGRAM test_viv_coupled
  !! Cross-flow VIV on the coupled aggregate route (the OpenFAST and FAST.Farm shells and the
  !! standalone mixed EI = 0 / finite-EI runner), on a deck with an EI = 0 riser and a finite-EI
  !! cable (EI 1 N m^2) side by side: each 100 m long at 50 kN, D 0.1 m, 50 segments, ends held at
  !! 50 m depth, Cl 0.8 with MoorDyn's band (dF 0.08, cF 0.18), in a uniform 0.15 m/s host current
  !! across the lines (the deck of tests/test_viv_lockin.py).
  !!
  !! Gates:
  !! * lock-in: over 60-120 s the mid-span cross-flow amplitude of both lines is MoorDyn-F's
  !!   A/D 0.662 within 0.03 and the response frequency its 0.293 Hz within 0.01 Hz; with Cl = 0
  !!   the lines stay still (A/D below 0.01);
  !! * checkpoint restart (the shell's rebuild recipe: a fresh instance takes the coupled
  !!   kinematics, each EI = 0 line's interior [v; q; a] and VIV block and each cable's mirror,
  !!   then the host field): the restarted run continues bit for bit, and a rebuild that skips the
  !!   VIV reload does not;
  !! * correction rewind: a step taken after CD_AGG_Snapshot and repeated after CD_AGG_Restore
  !!   lands on the same state, phases included, bit for bit;
  !! * averaging window: without VIVrmsWindow both line kinds average over MoorDyn's 500 steps
  !!   of the deck dtM, also when the coupling step differs from it (dtM 0.001 s at a 0.01 s
  !!   step: 0.5 s), and over 500 coupling steps when the deck has no dtM (5 s);
  !! * phase seed: MoorDyn's 2 pi i/N with node i counted from the deck's End A, also on a deck
  !!   written anchor first (which the reader turns around) and, through CD_Deck_VIV_Phase_Seed,
  !!   at the deck nodes of a refined mesh (added nodes interpolated in arc length).
  USE CableDyn_Precision, ONLY: wp
  USE CableDyn_OpenFAST_Aggregate, ONLY: CD_AGG_ModuleType, CD_AGG_Init_From_Deck, CD_AGG_End, CD_AGG_OK, &
                                         CD_AGG_NMovingPoints, CD_AGG_GetMovingPointMesh, CD_AGG_Step_Moving, &
                                         CD_AGG_UpdateStates_Moving, CD_AGG_CalcOutput, CD_AGG_NFluidNodes, &
                                         CD_AGG_SetFluidFields, CD_AGG_Snapshot, CD_AGG_Restore
  USE CableDyn_OpenFAST_HermiteFMF, ONLY: CD_HFMF_MirrorSize, CD_HFMF_VIVMirrorSize, CD_HFMF_PackMirror, &
                                          CD_HFMF_UnpackMirror, CD_HFMF_OK
  USE CableDyn_DeckDriver, ONLY: CD_Deck_VIV_Phase_Seed
  USE CableDyn_System, ONLY: CD_System_NLines, CD_System_Line_NDOF, CD_Get_System_Line_State, &
                             CD_Update_System_Line_Interior_State, CD_System_Line_VIV_MirrorSize, &
                             CD_Get_System_Line_VIV_State, CD_Set_System_Line_VIV_State, CD_SYSTEM_OK
  IMPLICIT NONE

  REAL(wp), PARAMETER :: DT = 0.01_wp, U = 0.15_wp, D = 0.1_wp
  REAL(wp), PARAMETER :: MD_AD = 0.662_wp, MD_F = 0.293_wp
  INTEGER, PARAMETER :: MID = 26
  INTEGER :: nfail

  nfail = 0
  CALL write_deck('viv_coupled.dat', 0.8_wp)
  CALL write_deck('viv_coupled_nolift.dat', 0.0_wp)
  CALL case_lockin()
  CALL case_restart()
  CALL case_rewind()
  CALL case_window()
  CALL case_seed()
  IF (nfail > 0) THEN
    WRITE (*, '(A,I0,A)') 'FAIL: ', nfail, ' coupled VIV check(s) failed'
    ERROR STOP 1
  END IF
  WRITE (*, '(A)') 'PASS: cross-flow VIV on the coupled aggregate route'

CONTAINS

  SUBROUTINE case_lockin()
    !! 120 s in the host current; the response statistics over 60-120 s.
    INTEGER, PARAMETER :: NSTEP = 12000, NSKIP = 6000
    TYPE(CD_AGG_ModuleType) :: agg
    REAL(wp) :: zs(NSTEP - NSKIP, 2), ad(2), f(2)
    INTEGER :: pass, s, k
    CHARACTER(16) :: what(2) = ['EI = 0 riser    ', 'finite-EI cable ']
    DO pass = 1, 2
      IF (.NOT. start(agg, MERGE('viv_coupled.dat       ', 'viv_coupled_nolift.dat', pass == 1))) RETURN
      DO s = 1, NSKIP
        IF (.NOT. advance(agg)) RETURN
      END DO
      DO s = 1, NSTEP - NSKIP
        IF (.NOT. advance(agg)) RETURN
        zs(s, 1) = agg%sys%fast%system%lines(1)%q(3*MID)
        zs(s, 2) = agg%cables(1)%line%q(6*(MID - 1) + 3)
      END DO
      CALL finish(agg)
      DO k = 1, 2
        CALL response(zs(:, k), ad(k), f(k))
        IF (pass == 1) THEN
          WRITE (*, '(2A,F7.4,A,F7.4,A)') '  ', what(k), ad(k), ' A/D at ', f(k), ' Hz (MoorDyn-F 0.662 at 0.293)'
          CALL check(ABS(ad(k) - MD_AD) < 0.03_wp, TRIM(what(k))//' locks in at MoorDyn-F''s amplitude')
          CALL check(ABS(f(k) - MD_F) < 0.01_wp, TRIM(what(k))//' locks in at MoorDyn-F''s frequency')
        ELSE
          WRITE (*, '(2A,ES10.3,A)') '  ', what(k), ad(k), ' A/D with Cl = 0'
          CALL check(ad(k) < 0.01_wp, TRIM(what(k))//' stays still without the lift')
        END IF
      END DO
    END DO
  END SUBROUTINE case_lockin

  SUBROUTINE case_restart()
    !! Checkpoint after 10 s, while the lock-in builds up; 50 steps on.
    INTEGER, PARAMETER :: NPRE = 1000, NPOST = 50
    TYPE(CD_AGG_ModuleType) :: a, b, c
    INTEGER :: s
    LOGICAL :: same_b, same_c
    IF (.NOT. start(a, 'viv_coupled.dat')) RETURN
    DO s = 1, NPRE
      IF (.NOT. advance(a)) RETURN
    END DO
    IF (.NOT. rebuild(a, b, .TRUE.)) RETURN
    IF (.NOT. rebuild(a, c, .FALSE.)) RETURN
    same_b = .TRUE.
    same_c = .TRUE.
    DO s = 1, NPOST
      IF (.NOT. advance(a)) RETURN
      IF (.NOT. advance(b)) RETURN
      IF (.NOT. advance(c)) RETURN
      same_b = same_b .AND. identical(a, b)
      same_c = same_c .AND. identical(a, c)
    END DO
    CALL check(same_b, 'the restarted run continues bit for bit')
    CALL check(.NOT. same_c, 'a restart without the VIV state does not')
    CALL finish(a)
    CALL finish(b)
    CALL finish(c)
  END SUBROUTINE case_restart

  SUBROUTINE case_rewind()
    !! A correction iteration: snapshot, step, restore, the same step again.
    TYPE(CD_AGG_ModuleType) :: a, b
    INTEGER :: s, es
    CHARACTER(512) :: em
    IF (.NOT. start(a, 'viv_coupled.dat')) RETURN
    IF (.NOT. start(b, 'viv_coupled.dat')) RETURN
    DO s = 1, 500
      IF (.NOT. advance(a)) RETURN
      IF (.NOT. advance(b)) RETURN
    END DO
    CALL CD_AGG_Snapshot(a, es, em)
    CALL check(es == CD_AGG_OK, 'snapshot: '//TRIM(em))
    IF (.NOT. advance(a)) RETURN
    CALL CD_AGG_Restore(a, es, em)
    CALL check(es == CD_AGG_OK, 'restore: '//TRIM(em))
    DO s = 1, 20
      IF (.NOT. advance(a)) RETURN
      IF (.NOT. advance(b)) RETURN
    END DO
    CALL check(identical(a, b), 'a rewound step repeats bit for bit')
    CALL CD_AGG_End(a, es, em)
    CALL CD_AGG_End(b, es, em)
  END SUBROUTINE case_rewind

  SUBROUTINE case_window()
    !! The default VIV averaging time of both line kinds, with and without a deck dtM.
    TYPE(CD_AGG_ModuleType) :: agg
    REAL(wp) :: tw_line, tw_cable
    INTEGER :: pass
    CALL write_deck('viv_coupled_dtm.dat', 0.8_wp, window=0.0_wp, dtm=0.001_wp)
    CALL write_deck('viv_coupled_nodtm.dat', 0.8_wp, window=0.0_wp)
    DO pass = 1, 2
      IF (.NOT. start(agg, MERGE('viv_coupled_dtm.dat  ', 'viv_coupled_nodtm.dat', pass == 1))) RETURN
      IF (.NOT. advance(agg)) RETURN
      tw_line = agg%sys%fast%system%lines(1)%viv_tw
      tw_cable = agg%cables(1)%line%viv_tw
      WRITE (*, '(A,2F8.4,A)') '  averaging window (line, cable): ', tw_line, tw_cable, ' s'
      IF (pass == 1) THEN
        CALL check(ABS(tw_line - 0.5_wp) < 1.0e-12_wp .AND. ABS(tw_cable - 0.5_wp) < 1.0e-12_wp, &
                   'both line kinds average over 500 steps of the deck dtM at a coarser coupling step')
      ELSE
        CALL check(ABS(tw_line - 5.0_wp) < 1.0e-12_wp .AND. ABS(tw_cable - 5.0_wp) < 1.0e-12_wp, &
                   'both line kinds average over 500 coupling steps without a deck dtM')
      END IF
      CALL finish(agg)
    END DO
  END SUBROUTINE case_window

  SUBROUTINE case_seed()
    !! MoorDyn's phase seed on a refined mesh and on an anchor-first deck.
    REAL(wp), PARAMETER :: TWO_PI = 8.0_wp*ATAN(1.0_wp)
    TYPE(CD_AGG_ModuleType) :: agg
    REAL(wp) :: seed(5), want(5), worst_line, worst_cable
    INTEGER :: k, pass, nn
    ! four mesh elements (internal order, End B first) over two deck segments: deck nodes at public
    ! nodes 1, 3 and 5, so public node 4 lies 3/4 of the way along the second deck segment
    ! MoorDyn's i/N from the deck's End A; a line kept in the deck order adds half a turn, as the
    ! model's tangent runs against MoorDyn's there (End B to End A)
    CALL CD_Deck_VIV_Phase_Seed([1.0_wp, 3.0_wp, 2.0_wp, 2.0_wp], .FALSE., seed, deck_map=[1, 3, 5])
    want = [1.0_wp, 0.875_wp, 0.5_wp, 0.25_wp, 0.0_wp]
    CALL check(MAXVAL(ABS(seed - MODULO(want + 0.5_wp, 1.0_wp))) < 1.0e-14_wp, &
               'refined mesh: deck nodes keep i/N, added nodes interpolate')
    CALL CD_Deck_VIV_Phase_Seed([1.0_wp, 3.0_wp, 2.0_wp, 2.0_wp], .TRUE., seed, deck_map=[1, 3, 5])
    CALL check(MAXVAL(ABS(seed - (1.0_wp - want))) < 1.0e-14_wp, 'a turned-around line counts from its End B')
    CALL CD_Deck_VIV_Phase_Seed([1.0_wp, 3.0_wp, 2.0_wp, 2.0_wp], .FALSE., seed)
    CALL check(MAXVAL(ABS(seed - [0.5_wp, 0.25_wp, 0.0_wp, 0.75_wp, 0.5_wp])) < 1.0e-14_wp, &
               'the deck mesh keeps the node index')
    CALL CD_Deck_VIV_Phase_Seed([1.0_wp, 3.0_wp, 2.0_wp, 2.0_wp], .FALSE., seed, zero=.TRUE.)
    CALL check(MAXVAL(ABS(seed - 0.5_wp)) < 1.0e-14_wp, 'zero: every phase at 0 in MoorDyn''s frame')
    CALL CD_Deck_VIV_Phase_Seed([1.0_wp, 3.0_wp, 2.0_wp, 2.0_wp], .TRUE., seed, zero=.TRUE.)
    CALL check(MAXVAL(ABS(seed)) < 1.0e-14_wp, 'zero on a turned-around line')
    CALL write_deck('viv_coupled_stock.dat', 0.8_wp, anchor_first=.TRUE.)
    DO pass = 1, 2
      IF (.NOT. start(agg, MERGE('viv_coupled.dat      ', 'viv_coupled_stock.dat', pass == 1))) RETURN
      nn = SIZE(agg%sys%fast%system%lines(1)%viv_phi)
      worst_line = 0.0_wp
      worst_cable = 0.0_wp
      DO k = 2, nn - 1
        ! internal node k (k = 1 at the anchor); MoorDyn's node from the deck's End A
        ! (half a turn on where the reader keeps the deck order: the model's tangent runs against
        ! MoorDyn's there)
        IF (pass == 1) THEN
          worst_line = MAX(worst_line, turn_gap(agg%sys%fast%system%lines(1)%viv_phi(k), &
                                                TWO_PI*(REAL(nn - k, wp)/50.0_wp + 0.5_wp)))
          worst_cable = MAX(worst_cable, turn_gap(agg%cables(1)%line%viv_phi(k), &
                                                  TWO_PI*(REAL(nn - k, wp)/50.0_wp + 0.5_wp)))
        ELSE
          worst_line = MAX(worst_line, turn_gap(agg%sys%fast%system%lines(1)%viv_phi(k), &
                                                TWO_PI*REAL(k - 1, wp)/50.0_wp))
          worst_cable = MAX(worst_cable, turn_gap(agg%cables(1)%line%viv_phi(k), TWO_PI*REAL(k - 1, wp)/50.0_wp))
        END IF
      END DO
      CALL check(worst_line < 1.0e-12_wp .AND. worst_cable < 1.0e-12_wp, &
                 MERGE('fairlead-first deck: the seed counts from the fairlead', &
                       'anchor-first deck: the seed counts from the anchor    ', pass == 1))
      CALL finish(agg)
    END DO
  END SUBROUTINE case_seed

  PURE REAL(wp) FUNCTION turn_gap(a, b) RESULT(gap)
    !! Distance of two phases on the circle (rad).
    REAL(wp), INTENT(IN) :: a, b
    REAL(wp), PARAMETER :: TWO_PI = 8.0_wp*ATAN(1.0_wp)
    gap = MODULO(a - b, TWO_PI)
    gap = MIN(gap, TWO_PI - gap)
  END FUNCTION turn_gap

  LOGICAL FUNCTION start(agg, path) RESULT(ok)
    !! A host-fluid build of the deck at dt.
    TYPE(CD_AGG_ModuleType), INTENT(INOUT) :: agg
    CHARACTER(*), INTENT(IN) :: path
    INTEGER :: es
    CHARACTER(512) :: em
    CALL CD_AGG_Init_From_Deck(agg, TRIM(path), DT, es, em, external_fluid=.TRUE.)
    ok = es == CD_AGG_OK
    CALL check(ok, 'init '//TRIM(path)//': '//TRIM(em))
    IF (ok) ok = agg%ncable == 1 .AND. agg%has_sys
    IF (ok) ok = SIZE(agg%sys%fast%system%lines(1)%q) == 3*(MID*2 - 1)
    CALL check(ok, 'one EI = 0 line and one cable of 50 elements are built')
  END FUNCTION start

  LOGICAL FUNCTION advance(agg) RESULT(ok)
    !! One coupling step with the ends held, after the host samples its current.
    TYPE(CD_AGG_ModuleType), INTENT(INOUT) :: agg
    REAL(wp), ALLOCATABLE :: pos(:, :), vel(:, :), acc(:, :), load(:, :)
    INTEGER :: es, npt, ni
    LOGICAL :: cv, st
    CHARACTER(512) :: em
    CALL set_current(agg)
    npt = CD_AGG_NMovingPoints(agg, es, em)
    ALLOCATE (pos(3, npt), vel(3, npt), acc(3, npt), load(3, npt))
    CALL CD_AGG_GetMovingPointMesh(agg, pos, vel, acc, load, es, em)
    vel = 0.0_wp
    acc = 0.0_wp
    CALL CD_AGG_Step_Moving(agg, DT, pos, vel, acc, cv, st, ni, es, em)
    ok = es == CD_AGG_OK .AND. cv
    IF (.NOT. ok) CALL check(.FALSE., 'step: '//TRIM(em))
    IF (ok) CALL CD_AGG_CalcOutput(agg, es, em)
  END FUNCTION advance

  SUBROUTINE set_current(agg)
    !! The host's uniform current U along +y over every fluid node, still surface at z = 0.
    TYPE(CD_AGG_ModuleType), INTENT(INOUT) :: agg
    REAL(wp), ALLOCATABLE :: fv(:, :), fa(:, :), wl(:)
    INTEGER :: es, nfl
    CHARACTER(512) :: em
    nfl = CD_AGG_NFluidNodes(agg, es, em)
    ALLOCATE (fv(3, nfl), fa(3, nfl), wl(nfl))
    fv = 0.0_wp
    fv(2, :) = U
    fa = 0.0_wp
    wl = 0.0_wp
    CALL CD_AGG_SetFluidFields(agg, fv, fa, wl, es, em)
    IF (es /= CD_AGG_OK) CALL check(.FALSE., 'host current: '//TRIM(em))
  END SUBROUTINE set_current

  LOGICAL FUNCTION rebuild(a, b, with_viv) RESULT(ok)
    !! The shell's checkpoint rebuild of a into a fresh b: the coupled kinematics, each EI = 0
    !! line's interior [v; q; a] and (with_viv) its VIV block, each cable's mirror (which
    !! carries the cable's VIV block; zeroed to the build's state when not with_viv).
    TYPE(CD_AGG_ModuleType), INTENT(INOUT) :: a, b
    LOGICAL, INTENT(IN) :: with_viv
    REAL(wp), ALLOCATABLE :: pos(:, :), vel(:, :), acc(:, :), load(:, :), qL(:), vL(:), aL(:), buf(:), &
                             fresh(:)
    INTEGER :: es, npt, il, ndof, nv, nvc
    CHARACTER(512) :: em
    ok = start(b, 'viv_coupled.dat')
    IF (.NOT. ok) RETURN
    npt = CD_AGG_NMovingPoints(a, es, em)
    ALLOCATE (pos(3, npt), vel(3, npt), acc(3, npt), load(3, npt))
    CALL CD_AGG_GetMovingPointMesh(a, pos, vel, acc, load, es, em)
    CALL CD_AGG_UpdateStates_Moving(b, pos, vel, acc, es, em)
    ok = es == CD_AGG_OK
    DO il = 1, CD_System_NLines(a%sys%fast%system, es, em)
      ndof = CD_System_Line_NDOF(a%sys%fast%system, il, es, em)
      ALLOCATE (qL(ndof), vL(ndof), aL(ndof))
      CALL CD_Get_System_Line_State(a%sys%fast%system, il, qL, vL, aL, es, em)
      CALL CD_Update_System_Line_Interior_State(b%sys%fast%system, il, qL(4:ndof - 3), vL(4:ndof - 3), es, em, &
                                                a_interior=aL(4:ndof - 3))
      ok = ok .AND. es == CD_SYSTEM_OK
      nv = CD_System_Line_VIV_MirrorSize(a%sys%fast%system, il)
      ok = ok .AND. nv == 3*(ndof/3) + 1
      IF (with_viv .AND. nv > 0) THEN
        ALLOCATE (buf(nv))
        CALL CD_Get_System_Line_VIV_State(a%sys%fast%system, il, buf, es, em)
        CALL CD_Set_System_Line_VIV_State(b%sys%fast%system, il, buf, es, em)
        ok = ok .AND. es == CD_SYSTEM_OK
        DEALLOCATE (buf)
      END IF
      DEALLOCATE (qL, vL, aL)
    END DO
    ALLOCATE (buf(CD_HFMF_MirrorSize(a%cables(1))), fresh(CD_HFMF_MirrorSize(b%cables(1))))
    CALL CD_HFMF_PackMirror(a%cables(1), buf, es, em)
    nvc = CD_HFMF_VIVMirrorSize(a%cables(1))
    ok = ok .AND. nvc == 3*a%cables(1)%line%nn + 1
    IF (.NOT. with_viv) THEN
      ! the cable's VIV block as the fresh build has it (the torsion-free cable ends with it)
      CALL CD_HFMF_PackMirror(b%cables(1), fresh, es, em)
      buf(SIZE(buf) - nvc + 1:) = fresh(SIZE(fresh) - nvc + 1:)
    END IF
    CALL CD_HFMF_UnpackMirror(b%cables(1), buf, a%cables(1)%line%t, es, em)
    ok = ok .AND. es == CD_HFMF_OK
    CALL check(ok, 'checkpoint rebuild: '//TRIM(em))
  END FUNCTION rebuild

  LOGICAL FUNCTION identical(a, b) RESULT(same)
    !! Both lines' state and shedding phases are the same bits.
    TYPE(CD_AGG_ModuleType), INTENT(IN) :: a, b
    same = MAXVAL(ABS(a%sys%fast%system%lines(1)%q - b%sys%fast%system%lines(1)%q)) <= 0.0_wp .AND. &
           MAXVAL(ABS(a%sys%fast%system%lines(1)%viv_phi - b%sys%fast%system%lines(1)%viv_phi)) <= 0.0_wp .AND. &
           MAXVAL(ABS(a%cables(1)%line%q - b%cables(1)%line%q)) <= 0.0_wp .AND. &
           MAXVAL(ABS(a%cables(1)%line%viv_phi - b%cables(1)%line%viv_phi)) <= 0.0_wp
  END FUNCTION identical

  SUBROUTINE response(z, ad, f)
    !! Cross-flow amplitude A/D = sqrt(2) std(z)/D and the mean up-crossing frequency of z.
    REAL(wp), INTENT(IN) :: z(:)
    REAL(wp), INTENT(OUT) :: ad, f
    REAL(wp) :: zm, t0, t1
    INTEGER :: i, n
    zm = SUM(z)/SIZE(z)
    ad = SQRT(2.0_wp*SUM((z - zm)**2)/SIZE(z))/D
    n = 0
    t0 = 0.0_wp
    t1 = 0.0_wp
    DO i = 2, SIZE(z)
      IF (z(i - 1) < zm .AND. z(i) >= zm) THEN
        n = n + 1
        t1 = (REAL(i - 1, wp) + (zm - z(i - 1))/(z(i) - z(i - 1)))*DT
        IF (n == 1) t0 = t1
      END IF
    END DO
    f = 0.0_wp
    IF (n > 1) f = REAL(n - 1, wp)/(t1 - t0)
  END SUBROUTINE response

  SUBROUTINE write_deck(path, cl, window, dtm, anchor_first)
    !! The EI = 0 riser (line 1) and the finite-EI cable (line 2), 20 m apart across the current;
    !! VIVrmsWindow 0.25 s unless window is given (0: none), and a deck dtM when dtm is given.
    CHARACTER(*), INTENT(IN) :: path
    REAL(wp), INTENT(IN) :: cl
    REAL(wp), INTENT(IN), OPTIONAL :: window, dtm
    LOGICAL, INTENT(IN), OPTIONAL :: anchor_first
    INTEGER :: u
    LOGICAL :: stock
    REAL(wp) :: tw
    CHARACTER(32) :: len_txt, cl_txt
    WRITE (len_txt, '(F12.6)') 100.0_wp/(1.0_wp + 5.0e4_wp/5.0e7_wp)
    WRITE (cl_txt, '(F4.2)') cl
    OPEN (NEWUNIT=u, FILE=path, STATUS='REPLACE', ACTION='WRITE')
    WRITE (u, '(A)') '--------------------- CableDyn Input File ---'
    WRITE (u, '(A)') 'coupled VIV gate: taut riser and cable in a host cross current'
    WRITE (u, '(A)') '--------------------- LINE TYPES ---'
    WRITE (u, '(A)') 'TypeName Diam Mass/m EA BA/-zeta EI Cd Ca CdAx CaAx Cl dF cF'
    WRITE (u, '(A)') '(name) (m) (kg/m) (N) (N-s/-) (-) (-) (-) (-) (-) (-) (-) (-)'
    WRITE (u, '(A)') 'riser 0.10 10.0 5.0e7 -0.8 0.0 1.2 1.0 0.0 0.0 '//TRIM(cl_txt)//' 0.08 0.18'
    WRITE (u, '(A)') 'cable 0.10 10.0 5.0e7 -0.8 1.0 1.2 1.0 0.0 0.0 '//TRIM(cl_txt)//' 0.08 0.18'
    WRITE (u, '(A)') '--------------------- POINTS ---'
    WRITE (u, '(A)') 'ID Attachment X Y Z M V CdA CA'
    WRITE (u, '(A)') '(#) (-) (m) (m) (m) (kg) (m^3) (m^2) (-)'
    WRITE (u, '(A)') '1 Coupled 0.0 0.0 -50.0 0 0 0 0'
    WRITE (u, '(A)') '2 Fixed 100.0 0.0 -50.0 0 0 0 0'
    WRITE (u, '(A)') '3 Coupled 0.0 20.0 -50.0 0 0 0 0'
    WRITE (u, '(A)') '4 Fixed 100.0 20.0 -50.0 0 0 0 0'
    WRITE (u, '(A)') '--------------------- LINES ---'
    WRITE (u, '(A)') 'ID LineType AttachA AttachB UnstrLen NumSegs Outputs'
    WRITE (u, '(A)') '(#) (name) (#) (#) (m) (-) (-)'
    stock = .FALSE.
    IF (PRESENT(anchor_first)) stock = anchor_first
    IF (stock) THEN
      ! MoorDyn's common row order, AttachA the anchor: the reader turns the lines around
      WRITE (u, '(A)') '1 riser 2 1 '//TRIM(ADJUSTL(len_txt))//' 50 -'
      WRITE (u, '(A)') '2 cable 4 3 '//TRIM(ADJUSTL(len_txt))//' 50 -'
    ELSE
      WRITE (u, '(A)') '1 riser 1 2 '//TRIM(ADJUSTL(len_txt))//' 50 -'
      WRITE (u, '(A)') '2 cable 3 4 '//TRIM(ADJUSTL(len_txt))//' 50 -'
    END IF
    WRITE (u, '(A)') '--------------------- OPTIONS ---'
    WRITE (u, '(A)') '100.0 WtrDpth'
    WRITE (u, '(A)') '1025.0 rhoW'
    WRITE (u, '(A)') '9.80665 g'
    tw = 0.25_wp
    IF (PRESENT(window)) tw = window
    IF (tw > 0.0_wp) WRITE (u, '(F6.3,A)') tw, ' VIVrmsWindow'
    IF (PRESENT(dtm)) WRITE (u, '(ES12.5,A)') dtm, ' dtM'
    WRITE (u, '(A)') '--------------------- need this line ---'
    CLOSE (u)
  END SUBROUTINE write_deck

  SUBROUTINE finish(agg)
    TYPE(CD_AGG_ModuleType), INTENT(INOUT) :: agg
    INTEGER :: es
    CHARACTER(512) :: em
    CALL CD_AGG_End(agg, es, em)
  END SUBROUTINE finish

  SUBROUTINE check(ok, label)
    LOGICAL, INTENT(IN) :: ok
    CHARACTER(*), INTENT(IN) :: label
    IF (ok) THEN
      WRITE (*, '(2A)') '  ok   ', label
    ELSE
      WRITE (*, '(2A)') '  FAIL ', label
      nfail = nfail + 1
    END IF
  END SUBROUTINE check

END PROGRAM test_viv_coupled
