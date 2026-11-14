! File: tests/test_viscoelastic_control.f90
! SPDX-License-Identifier: Apache-2.0
! Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
PROGRAM test_viscoelastic_control
  !! Active line control (CONTROL, the OpenFAST CableDeltaL route of CD_Init_Deck_Aggregate) of a
  !! viscoelastic segment (MoorDyn ElasticMod 2, Es|Ed, and 3, Es|alphaMBL|vbeta). MoorDyn-F
  !! (MD_CalcContStateDeriv sets l(N) and ld(N); Line_GetStateDeriv) and MoorDyn-C
  !! (Line::setUnstretchedLength; Line::getStateDeriv) keep each segment's slow-branch stretch
  !! dl_1 as its state, leave it as it is when the unstretched length l changes and read it at
  !! the new length: MagT = EA_1 dl_1/l, MagTd = BA ld_1/l,
  !! ld_1 = (EA_D dl - (EA_D + EA_1) dl_1 + BA_D lstrd)/(BA_D + BA), dl = lstr - l,
  !! EA_1 = EA_D EA/(EA_D - EA), and for ElasticMod 3 EA_D(dl_1, l). The oracles below evaluate
  !! these formulas independently of CableDyn_Viscoelastic. The decks are written here: 100 m of
  !! rope (10 segments) held taut between a Coupled fairlead and a Fixed anchor 102 m apart at
  !! mid-depth, nearly neutrally buoyant so that the tension is uniform, with Es = 1e8 N,
  !! Ed = 3e8 N (or alphaMBL = 3e8 N, vbeta = 20) and BA = Bs|Bd = 1e6|1e5 N s (a slow-branch
  !! relaxation time (BA_D + BA)/(EA_D + EA_1) of about 2.4 ms).
  !!   1. Quasi-static pay-out and haul-in: the fairlead segment is paid out by 0.5 m over 20 s,
  !!      hauled in to -1 m over 40 s and paid back to 0 over 20 s, with 4 s holds. Every element's
  !!      tension follows the static viscoelastic law, the composite EA times the line's strain
  !!      D/L(t) - 1: gated over the ramps (the lag of the slow branch) and at the ends of the
  !!      holds (the rest point), for ElasticMod 2 with and without the force blend and for 3.
  !!   2. A length step from rest (pay-out 5 cm, haul-in 4 cm; ElasticMod 2 and 3): the tension
  !!      right after the change is MoorDyn's at the carried stretch dl_1, and dl_1 after one step
  !!      is the backward-Euler step of MoorDyn's ODE at the new length (EA_D at the step-start
  !!      state, as CableDyn lags it); the other elements are untouched. The strain-carrying
  !!      alternative (dl_1 l_2/l_1) is printed for contrast and must differ.
  !!   3. Checkpoint restart in the middle of a pay-out ramp and in the hold after it: a fresh
  !!      instance takes the coupled kinematics, the line interior [q; v; a] and the dl_1 mirror of
  !!      the first, re-applies the command as the committed one (restored), and both continue
  !!      bit for bit.
  !! Every gate stopped at initialisation before (CONTROL on a viscoelastic segment was refused).
  USE CableDyn_Precision, ONLY: wp
  USE CableDyn_OpenFAST_Aggregate, ONLY: CD_AGG_ModuleType, CD_AGG_Init_From_Deck, CD_AGG_GetMovingPointMesh, &
                                         CD_AGG_UpdateStates_Moving, CD_AGG_Step_Moving, CD_AGG_CalcOutput, &
                                         CD_AGG_Apply_LineControl, CD_AGG_Get_Substep_Counts, CD_AGG_End, &
                                         CD_AGG_OK
  USE CableDyn_System, ONLY: CD_System_Line_NDOF, CD_System_Line_NElem, CD_Get_System_Line_State, &
                             CD_Get_System_Line_Tension, CD_Get_System_Line_VE_Dl1, CD_Set_System_Line_VE_Dl1, &
                             CD_Update_System_Line_Interior_State, CD_SYSTEM_OK
  USE, INTRINSIC :: ISO_FORTRAN_ENV, ONLY: INT64
  IMPLICIT NONE

  ! the deck constants: Es, Ed (ElasticMod 2), alphaMBL|vbeta (ElasticMod 3), Bs|Bd
  REAL(wp), PARAMETER :: EA_S = 1.0e8_wp, EA_D2 = 3.0e8_wp, AMBL = 3.0e8_wp, VBETA = 20.0_wp
  REAL(wp), PARAMETER :: BA_S = 1.0e6_wp, BA_D = 1.0e5_wp
  REAL(wp), PARAMETER :: PI = 3.141592653589793_wp, DT = 0.05_wp
  INTEGER :: nfail = 0

  CALL write_deck('vctl_mod2.dat', '1.0e8|3.0e8', .FALSE.)
  CALL write_deck('vctl_mod2_noblend.dat', '1.0e8|3.0e8', .TRUE.)
  CALL write_deck('vctl_mod3.dat', '1.0e8|3.0e8|20.0', .FALSE.)

  CALL case_quasi_static('vctl_mod2.dat', 'ElasticMod 2 quasi-static')
  CALL case_quasi_static('vctl_mod2_noblend.dat', 'ElasticMod 2 quasi-static, False alpha_force_blend')
  CALL case_quasi_static('vctl_mod3.dat', 'ElasticMod 3 quasi-static')
  CALL case_length_step('vctl_mod2.dat', 2, 0.05_wp, 'ElasticMod 2 pay-out step')
  CALL case_length_step('vctl_mod2.dat', 2, -0.04_wp, 'ElasticMod 2 haul-in step')
  CALL case_length_step('vctl_mod3.dat', 3, 0.05_wp, 'ElasticMod 3 pay-out step')
  CALL case_length_step('vctl_mod3.dat', 3, -0.04_wp, 'ElasticMod 3 haul-in step')
  CALL case_restart('vctl_mod2.dat', 'ElasticMod 2')
  CALL case_restart('vctl_mod3.dat', 'ElasticMod 3')

  IF (nfail > 0) THEN
    PRINT '(I0,A)', nfail, ' assertion(s) failed'
    ERROR STOP 1
  END IF
  PRINT '(A)', 'all viscoelastic line-control checks passed'

CONTAINS

  ! ---------------------------------------------------------------------------------------------
  ! 1. quasi-static pay-out and haul-in
  ! ---------------------------------------------------------------------------------------------

  SUBROUTINE case_quasi_static(deck, what)
    CHARACTER(*), INTENT(IN) :: deck, what
    TYPE(CD_AGG_ModuleType) :: agg
    INTEGER, PARAMETER :: NSTEP = 1840
    REAL(wp) :: r0(3, 1), vel(3, 1), acc(3, 1), ld(3, 1), dl, dldot, t, chord, l_tot, t_o, t0
    REAL(wp) :: err_ramp, err_hold, hold_at(3)
    REAL(wp), ALLOCATABLE :: ten(:)
    INTEGER :: es, ni, s, il, ec, ne, k, n_hold
    LOGICAL :: cv, st, ok
    CHARACTER(512) :: em

    CALL CD_AGG_Init_From_Deck(agg, deck, DT, es, em)
    CALL require(es == CD_AGG_OK, what//': the controlled viscoelastic deck initialises: '//TRIM(em))
    IF (es /= CD_AGG_OK) RETURN
    CALL CD_AGG_GetMovingPointMesh(agg, r0, vel, acc, ld, es, em)
    vel = 0.0_wp
    acc = 0.0_wp
    il = agg%ctrl_line(1)
    ec = agg%ctrl_elem(1)
    ne = CD_System_Line_NElem(agg%sys%fast%system, il, es, em)
    ALLOCATE (ten(ne))
    ASSOCIATE (md => agg%sys%fast%system%lines(il))
      CALL require(md%has_viscoelastic .AND. md%ve_mode(ec) /= 0, what//': the controlled segment is viscoelastic')
      chord = NORM2(md%q(3*md%elem_conn(2, ne) - 2:3*md%elem_conn(2, ne)) - &
                    md%q(3*md%elem_conn(1, 1) - 2:3*md%elem_conn(1, 1)))
      l_tot = SUM(md%l0)
    END ASSOCIATE
    CALL CD_Get_System_Line_Tension(agg%sys%fast%system, il, ten, es, em)
    t0 = ten(ec)
    t_o = EA_S*(chord/l_tot - 1.0_wp)
    CALL require(ABS(t0 - t_o) <= 1.0e-6_wp*t_o .AND. MAXVAL(ABS(ten - t0)) <= 1.0e-6_wp*t0, &
                 what//': the line starts on the static law with a uniform tension')
    hold_at = [24.0_wp, 68.0_wp, 92.0_wp]
    err_ramp = 0.0_wp
    err_hold = 0.0_wp
    n_hold = 0
    ok = .TRUE.
    DO s = 1, NSTEP
      t = REAL(s, wp)*DT
      CALL cycle_command(t, dl, dldot)
      CALL CD_AGG_Apply_LineControl(agg, [dl], [dldot], es, em)
      IF (es == CD_AGG_OK) CALL CD_AGG_Step_Moving(agg, DT, r0, vel, acc, cv, st, ni, es, em)
      IF (es /= CD_AGG_OK .OR. .NOT. cv) THEN
        ok = .FALSE.
        CALL require(.FALSE., what//': step at t = '//TRIM(fmt_real(t))//': '//TRIM(em))
        EXIT
      END IF
      CALL CD_Get_System_Line_Tension(agg%sys%fast%system, il, ten, es, em)
      ! the oracle: the static (composite EA) law at the line's strain
      t_o = EA_S*(chord/(l_tot + dl) - 1.0_wp)
      err_ramp = MAX(err_ramp, MAXVAL(ABS(ten - t_o))/t0)
      DO k = 1, 3
        IF (ABS(t - hold_at(k)) < 0.5_wp*DT) THEN
          err_hold = MAX(err_hold, MAXVAL(ABS(ten - t_o))/t_o)
          n_hold = n_hold + 1
        END IF
      END DO
    END DO
    IF (ok) THEN
      PRINT '(A,A,A,ES12.5,A,ES10.3,A,ES10.3)', '  ', what, ': T0 ', t0, ' N; max |T - EA eps| / T0 over the ramps ', &
        err_ramp, ', at the ends of the holds / T ', err_hold
      CALL require(n_hold == 3 .AND. err_hold <= 1.0e-6_wp, what//': at rest the tension is the static law''s')
      CALL require(err_ramp <= 3.0e-3_wp, what//': along the ramps the tension follows the static law')
      CALL require(bits_eq(agg%sys%fast%system%lines(il)%l0(ec), agg%ctrl_base_l0(1)), &
                   what//': the cycle returns the segment to its base length')
    END IF
    CALL CD_AGG_End(agg, es, em)
  END SUBROUTINE case_quasi_static

  SUBROUTINE cycle_command(t, dl, dldot)
    !! Pay out 0.5 m on a half-cosine over 20 s, hold 4 s, haul in to -1 m over 40 s, hold 4 s,
    !! pay back to 0 over 20 s, hold.
    REAL(wp), INTENT(IN) :: t
    REAL(wp), INTENT(OUT) :: dl, dldot
    IF (t < 20.0_wp) THEN
      CALL half_cosine(t, 0.0_wp, 20.0_wp, 0.0_wp, 0.5_wp, dl, dldot)
    ELSE IF (t < 24.0_wp) THEN
      dl = 0.5_wp
      dldot = 0.0_wp
    ELSE IF (t < 64.0_wp) THEN
      CALL half_cosine(t, 24.0_wp, 40.0_wp, 0.5_wp, -1.0_wp, dl, dldot)
    ELSE IF (t < 68.0_wp) THEN
      dl = -1.0_wp
      dldot = 0.0_wp
    ELSE IF (t < 88.0_wp) THEN
      CALL half_cosine(t, 68.0_wp, 20.0_wp, -1.0_wp, 0.0_wp, dl, dldot)
    ELSE
      dl = 0.0_wp
      dldot = 0.0_wp
    END IF
  END SUBROUTINE cycle_command

  SUBROUTINE half_cosine(t, t_start, span, a, b, x, xdot)
    REAL(wp), INTENT(IN) :: t, t_start, span, a, b
    REAL(wp), INTENT(OUT) :: x, xdot
    x = a + (b - a)*0.5_wp*(1.0_wp - COS(PI*(t - t_start)/span))
    xdot = (b - a)*0.5_wp*(PI/span)*SIN(PI*(t - t_start)/span)
  END SUBROUTINE half_cosine

  ! ---------------------------------------------------------------------------------------------
  ! 2. a length step from rest
  ! ---------------------------------------------------------------------------------------------

  SUBROUTINE case_length_step(deck, mode, step_dl, what)
    CHARACTER(*), INTENT(IN) :: deck, what
    INTEGER, INTENT(IN) :: mode
    REAL(wp), INTENT(IN) :: step_dl
    TYPE(CD_AGG_ModuleType) :: agg
    REAL(wp) :: r0(3, 1), vel(3, 1), acc(3, 1), ld(3, 1), l1, l2, length, lstrd, t_md, t_alt, dl1_be
    REAL(wp), ALLOCATABLE :: dl1_0(:), dl1_1(:), ten0(:), ten1(:)
    INTEGER :: es, ni, il, ec, ne, others, max_used
    INTEGER(INT64) :: calls, events, capped, fallbacks
    LOGICAL :: cv, st
    CHARACTER(512) :: em

    CALL CD_AGG_Init_From_Deck(agg, deck, DT, es, em)
    CALL require(es == CD_AGG_OK, what//': the deck initialises: '//TRIM(em))
    IF (es /= CD_AGG_OK) RETURN
    CALL CD_AGG_GetMovingPointMesh(agg, r0, vel, acc, ld, es, em)
    vel = 0.0_wp
    acc = 0.0_wp
    il = agg%ctrl_line(1)
    ec = agg%ctrl_elem(1)
    ne = CD_System_Line_NElem(agg%sys%fast%system, il, es, em)
    ALLOCATE (dl1_0(ne), dl1_1(ne), ten0(ne), ten1(ne))
    CALL CD_Get_System_Line_VE_Dl1(agg%sys%fast%system, il, dl1_0, es, em)
    CALL CD_Get_System_Line_Tension(agg%sys%fast%system, il, ten0, es, em)
    l1 = agg%sys%fast%system%lines(il)%l0(ec)
    CALL CD_AGG_Apply_LineControl(agg, [step_dl], [0.0_wp], es, em)
    CALL require(es == CD_AGG_OK, what//': the command applies: '//TRIM(em))
    IF (es /= CD_AGG_OK) RETURN
    ASSOCIATE (md => agg%sys%fast%system%lines(il))
      l2 = md%l0(ec)
      CALL require(md%ve_mode(ec) == mode .AND. bits_eq(l2, l1 + step_dl), &
                   what//': the viscoelastic segment takes l1 + DeltaL')
      CALL element_kinematics(md%q, md%v, md%elem_conn(:, ec), length, lstrd)
    END ASSOCIATE
    CALL CD_Get_System_Line_Tension(agg%sys%fast%system, il, ten1, es, em)
    t_md = md_tension(mode, dl1_0(ec), length, lstrd, l2)
    t_alt = md_tension(mode, dl1_0(ec)*l2/l1, length, lstrd, l2)
    others = COUNT(.NOT. bits_eq_v(ten1, ten0)) - MERGE(1, 0,.NOT. bits_eq(ten1(ec), ten0(ec)))
    PRINT '(A,A,F6.3,A,ES12.5,A,ES12.5,A,ES12.5,A,ES10.3)', '  ', what, step_dl, ' m: tension ', ten0(ec), &
      ' -> ', ten1(ec), ' N, MoorDyn (stretch carried) ', t_md, ' N, rel. difference ', ABS(ten1(ec) - t_md)/t_md
    PRINT '(A,ES12.5,A,ES10.3,A)', '    strain carried instead: ', t_alt, ' N (', ABS(t_alt - t_md)/t_md, &
      ' off MoorDyn)'
    CALL require(t_md > 0.0_wp .AND. ABS(ten1(ec) - t_md) <= 1.0e-10_wp*t_md, &
                 what//': the tension after the change is MoorDyn''s at the carried stretch')
    CALL require(ABS(t_alt - t_md) > 1.0e-3_wp*t_md, what//': the oracle tells the stretch from the strain carry')
    CALL require(others == 0, what//': the other elements keep their tension')
    CALL CD_AGG_Step_Moving(agg, DT, r0, vel, acc, cv, st, ni, es, em)
    CALL require(es == CD_AGG_OK .AND. cv, what//': the step after the change converges: '//TRIM(em))
    IF (es /= CD_AGG_OK) RETURN
    CALL CD_AGG_Get_Substep_Counts(agg, calls, events, max_used, capped, fallbacks)
    CALL CD_Get_System_Line_VE_Dl1(agg%sys%fast%system, il, dl1_1, es, em)
    ASSOCIATE (md => agg%sys%fast%system%lines(il))
      CALL element_kinematics(md%q, md%v, md%elem_conn(:, ec), length, lstrd)
    END ASSOCIATE
    dl1_be = md_backward_euler(mode, dl1_0(ec), length, lstrd, l2, DT)
    PRINT '(A,ES16.9,A,ES16.9,A,ES10.3,A,I0,A)', '    dl_1 after one step ', dl1_1(ec), ' m, oracle ', dl1_be, &
      ' (rel. ', ABS(dl1_1(ec) - dl1_be)/ABS(dl1_be), '; ', events, ' sub-stepped steps)'
    CALL require(events == 0 .AND. ABS(dl1_1(ec) - dl1_be) <= 1.0e-10_wp*ABS(dl1_be), &
                 what//': the step advances the carried stretch (backward Euler at the new length)')
    CALL CD_AGG_End(agg, es, em)
  END SUBROUTINE case_length_step

  SUBROUTINE element_kinematics(q, v, conn, length, lstrd)
    !! Stretched length and its rate (the chord rate, MoorDyn's lstr and lstrd) of one element.
    REAL(wp), INTENT(IN) :: q(:), v(:)
    INTEGER, INTENT(IN) :: conn(2)
    REAL(wp), INTENT(OUT) :: length, lstrd
    REAL(wp) :: chord(3)
    chord = q(3*conn(2) - 2:3*conn(2)) - q(3*conn(1) - 2:3*conn(1))
    length = NORM2(chord)
    lstrd = DOT_PRODUCT(chord/length, v(3*conn(2) - 2:3*conn(2)) - v(3*conn(1) - 2:3*conn(1)))
  END SUBROUTINE element_kinematics

  SUBROUTINE md_coeffs(mode, dl_1, l, ea_d, ea_1)
    !! MoorDyn's EA_D (ElasticMod 2: Ed; ElasticMod 3: the mean-load-dependent root of
    !! MoorDyn-F Line_GetStateDeriv / MoorDyn-C Line::getStateDeriv at dl_1 > 0) and
    !! EA_1 = EA_D EA/(EA_D - EA).
    INTEGER, INTENT(IN) :: mode
    REAL(wp), INTENT(IN) :: dl_1, l
    REAL(wp), INTENT(OUT) :: ea_d, ea_1
    REAL(wp) :: k
    IF (mode == 2) THEN
      ea_d = EA_D2
    ELSE IF (dl_1 > 0.0_wp) THEN
      k = EA_S/l
      ea_d = 0.5_wp*(AMBL + VBETA*dl_1*k + EA_S + SQRT(AMBL*AMBL + 2.0_wp*AMBL*k*(VBETA*dl_1 - l) + &
                                                       (k*(VBETA*dl_1 + l))**2))
    ELSE
      ea_d = AMBL
    END IF
    ea_1 = ea_d*EA_S/(ea_d - EA_S)
  END SUBROUTINE md_coeffs

  REAL(wp) FUNCTION md_tension(mode, dl_1, length, lstrd, l) RESULT(t)
    !! MoorDyn's segment tension MagT + MagTd at the state dl_1 and unstretched length l.
    INTEGER, INTENT(IN) :: mode
    REAL(wp), INTENT(IN) :: dl_1, length, lstrd, l
    REAL(wp) :: ea_d, ea_1, ld_1
    CALL md_coeffs(mode, dl_1, l, ea_d, ea_1)
    ld_1 = (ea_d*(length - l) - (ea_d + ea_1)*dl_1 + BA_D*lstrd)/(BA_D + BA_S)
    t = BA_S*ld_1/l
    IF (length >= l) t = t + ea_1*dl_1/l
  END FUNCTION md_tension

  REAL(wp) FUNCTION md_backward_euler(mode, dl_1, length, lstrd, l, h) RESULT(dl1_next)
    !! The backward-Euler step of MoorDyn's linear dl_1 ODE at length l, EA_D at the step-start
    !! dl_1 (CableDyn lags it over the step).
    INTEGER, INTENT(IN) :: mode
    REAL(wp), INTENT(IN) :: dl_1, length, lstrd, l, h
    REAL(wp) :: ea_d, ea_1, b
    CALL md_coeffs(mode, dl_1, l, ea_d, ea_1)
    b = BA_D + BA_S
    dl1_next = (dl_1 + h*(ea_d*(length - l) + BA_D*lstrd)/b)/(1.0_wp + h*(ea_d + ea_1)/b)
  END FUNCTION md_backward_euler

  ! ---------------------------------------------------------------------------------------------
  ! 3. checkpoint restart
  ! ---------------------------------------------------------------------------------------------

  SUBROUTINE case_restart(deck, what)
    !! The shell's rebuild recipe (CableDyn_OF): a fresh instance B takes A's coupled kinematics,
    !! re-applies the restored command, then reloads the line interior and the dl_1 mirror.
    CHARACTER(*), INTENT(IN) :: deck, what
    TYPE(CD_AGG_ModuleType) :: agg_a, agg_b
    INTEGER, PARAMETER :: NPOST = 12
    REAL(wp) :: r0(3, 1), vel(3, 1), acc(3, 1), pa(3, 1), la(3, 1), pb(3, 1), lb(3, 1), v2(3, 1), a2(3, 1)
    REAL(wp) :: dl, dldot, dmax
    REAL(wp), ALLOCATABLE :: qL(:), vL(:), aL(:), dl1(:), dl1_b(:)
    INTEGER :: es, ni, s, il, ndof, ne, npre, pass
    LOGICAL :: cv, st, same
    CHARACTER(512) :: em

    DO pass = 1, 2
      npre = MERGE(15, 50, pass == 1)
      CALL CD_AGG_Init_From_Deck(agg_a, deck, DT, es, em)
      CALL require(es == CD_AGG_OK, what//' restart: A initialises: '//TRIM(em))
      IF (es /= CD_AGG_OK) RETURN
      CALL CD_AGG_GetMovingPointMesh(agg_a, r0, vel, acc, la, es, em)
      vel = 0.0_wp
      acc = 0.0_wp
      DO s = 1, npre
        CALL restart_command(s, dl, dldot)
        CALL CD_AGG_Apply_LineControl(agg_a, [dl], [dldot], es, em)
        IF (es == CD_AGG_OK) CALL CD_AGG_Step_Moving(agg_a, DT, r0, vel, acc, cv, st, ni, es, em)
        IF (es /= CD_AGG_OK .OR. .NOT. cv) THEN
          CALL require(.FALSE., what//' restart: A marches: '//TRIM(em))
          RETURN
        END IF
      END DO
      CALL CD_AGG_Init_From_Deck(agg_b, deck, DT, es, em)
      CALL require(es == CD_AGG_OK, what//' restart: B initialises: '//TRIM(em))
      CALL CD_AGG_GetMovingPointMesh(agg_a, pa, v2, a2, la, es, em)
      CALL CD_AGG_UpdateStates_Moving(agg_b, pa, v2, a2, es, em)
      ! the restored command is the one A's committed state was reached with
      CALL restart_command(npre, dl, dldot)
      CALL CD_AGG_Apply_LineControl(agg_b, [dl], [dldot], es, em, restored=.TRUE.)
      CALL require(es == CD_AGG_OK, what//' restart: B re-applies the command: '//TRIM(em))
      il = agg_a%ctrl_line(1)
      ndof = CD_System_Line_NDOF(agg_a%sys%fast%system, il, es, em)
      ne = CD_System_Line_NElem(agg_a%sys%fast%system, il, es, em)
      IF (ALLOCATED(qL)) DEALLOCATE (qL, vL, aL, dl1, dl1_b)
      ALLOCATE (qL(ndof), vL(ndof), aL(ndof), dl1(ne), dl1_b(ne))
      CALL CD_Get_System_Line_State(agg_a%sys%fast%system, il, qL, vL, aL, es, em)
      CALL CD_Update_System_Line_Interior_State(agg_b%sys%fast%system, il, qL(4:ndof - 3), vL(4:ndof - 3), &
                                                es, em, a_interior=aL(4:ndof - 3))
      CALL require(es == CD_SYSTEM_OK, what//' restart: B takes the line interior: '//TRIM(em))
      CALL CD_Get_System_Line_VE_Dl1(agg_a%sys%fast%system, il, dl1, es, em)
      CALL CD_Set_System_Line_VE_Dl1(agg_b%sys%fast%system, il, dl1, es, em)
      CALL require(es == CD_SYSTEM_OK, what//' restart: B takes the dl_1 mirror: '//TRIM(em))
      ASSOCIATE (ma => agg_a%sys%fast%system%lines(il), mb => agg_b%sys%fast%system%lines(il))
        same = ALL(bits_eq_v(ma%l0, mb%l0)) .AND. ALL(bits_eq_v(ma%l0_c, mb%l0_c))
      END ASSOCIATE
      CALL require(same, what//' restart: B carries the lengths and the committed lengths of A')
      dmax = 0.0_wp
      DO s = npre + 1, npre + NPOST
        CALL restart_command(s, dl, dldot)
        CALL CD_AGG_Apply_LineControl(agg_a, [dl], [dldot], es, em)
        CALL CD_AGG_Apply_LineControl(agg_b, [dl], [dldot], es, em)
        CALL CD_AGG_Step_Moving(agg_a, DT, r0, vel, acc, cv, st, ni, es, em)
        same = same .AND. es == CD_AGG_OK .AND. cv
        CALL CD_AGG_Step_Moving(agg_b, DT, r0, vel, acc, cv, st, ni, es, em)
        same = same .AND. es == CD_AGG_OK .AND. cv
        CALL CD_AGG_CalcOutput(agg_a, es, em)
        CALL CD_AGG_CalcOutput(agg_b, es, em)
        CALL CD_AGG_GetMovingPointMesh(agg_a, pa, v2, a2, la, es, em)
        CALL CD_AGG_GetMovingPointMesh(agg_b, pb, v2, a2, lb, es, em)
        CALL CD_Get_System_Line_VE_Dl1(agg_a%sys%fast%system, il, dl1, es, em)
        CALL CD_Get_System_Line_VE_Dl1(agg_b%sys%fast%system, il, dl1_b, es, em)
        dmax = MAX(dmax, MAXVAL(ABS(la - lb)), MAXVAL(ABS(dl1 - dl1_b)))
        same = same .AND. ALL(bits_eq_v(RESHAPE(la, [3]), RESHAPE(lb, [3]))) .AND. ALL(bits_eq_v(dl1, dl1_b)) .AND. &
               ALL(bits_eq_v(agg_a%sys%fast%system%lines(il)%q, agg_b%sys%fast%system%lines(il)%q))
      END DO
      PRINT '(A,A,A,I0,A,ES10.3)', '  ', what, ' restart after step ', npre, &
        ': max difference of the fairlead load and dl_1 ', dmax
      CALL require(same, what//' restart: the restarted run continues bit for bit ('// &
                   MERGE('mid-ramp', 'hold    ', pass == 1)//')')
      CALL CD_AGG_End(agg_a, es, em)
      CALL CD_AGG_End(agg_b, es, em)
    END DO
  END SUBROUTINE case_restart

  SUBROUTINE restart_command(step, dl, dldot)
    !! A 0.4 m pay-out on a half-cosine over 2 s, then held.
    INTEGER, INTENT(IN) :: step
    REAL(wp), INTENT(OUT) :: dl, dldot
    REAL(wp) :: t
    t = REAL(step, wp)*DT
    IF (t < 2.0_wp) THEN
      CALL half_cosine(t, 0.0_wp, 2.0_wp, 0.0_wp, 0.4_wp, dl, dldot)
    ELSE
      dl = 0.4_wp
      dldot = 0.0_wp
    END IF
  END SUBROUTINE restart_command

  ! ---------------------------------------------------------------------------------------------
  ! decks and helpers
  ! ---------------------------------------------------------------------------------------------

  SUBROUTINE write_deck(path, ea, no_force_blend)
    !! A Coupled fairlead at x = 0 and a Fixed anchor 102 m away at mid-depth, 100 m of rope in 10
    !! segments written fairlead first (its only host-driven end at NodeA, the controlled end),
    !! with a CONTROL row on channel 1. The rope is nearly neutrally buoyant (0.05 kg/m above the
    !! displaced water's). no_force_blend writes False alpha_force_blend.
    CHARACTER(*), INTENT(IN) :: path, ea
    LOGICAL, INTENT(IN) :: no_force_blend
    INTEGER :: u
    OPEN (NEWUNIT=u, FILE=path, STATUS='REPLACE', ACTION='WRITE')
    WRITE (u, '(A)') 'Viscoelastic line-control test deck'
    WRITE (u, '(A)') '--- LINE TYPES ---'
    WRITE (u, '(A)') 'Name Diam Mass EA BA EI Cdn Cdt Can Cat'
    WRITE (u, '(A)') '(-) (m) (kg/m) (N) (-) (Nm2) (-) (-) (-) (-)'
    WRITE (u, '(A)') 'rope 0.1438 16.70 '//ea//' 1.0e6|1.0e5 0.0 1.2 0.2 1.0 0.0'
    WRITE (u, '(A)') '--- POINTS ---'
    WRITE (u, '(A)') 'ID Type X Y Z Mass Vol CdA Ca'
    WRITE (u, '(A)') '(-) (-) (m) (m) (m) (kg) (m3) (m2) (-)'
    WRITE (u, '(A)') '1 Coupled 0.0 0.0 -100.0 0 0 0 0'
    WRITE (u, '(A)') '2 Fixed 102.0 0.0 -100.0 0 0 0 0'
    WRITE (u, '(A)') '--- LINES ---'
    WRITE (u, '(A)') 'ID NodeA NodeB Outputs'
    WRITE (u, '(A)') '(-) (-) (-) (-)'
    WRITE (u, '(A)') '1 1 2 -'
    WRITE (u, '(A)') '--- SECTIONS ---'
    WRITE (u, '(A)') 'LineID LineType Length NumSegs'
    WRITE (u, '(A)') '(-) (-) (m) (-)'
    WRITE (u, '(A)') '1 rope 100.0 10'
    WRITE (u, '(A)') '--- CONTROL ---'
    WRITE (u, '(A)') 'ChannelID Lines'
    WRITE (u, '(A)') '(-) (-)'
    WRITE (u, '(A)') '1 1'
    WRITE (u, '(A)') '--- OPTIONS ---'
    WRITE (u, '(A)') '9.80665 g'
    WRITE (u, '(A)') '1025.0 rhoW'
    WRITE (u, '(A)') '200.0 WtrDpth'
    IF (no_force_blend) WRITE (u, '(A)') 'False alpha_force_blend'
    WRITE (u, '(A)') '--- OUTPUTS ---'
    WRITE (u, '(A)') 'FairTen1'
    WRITE (u, '(A)') '--- end ---'
    CLOSE (u)
  END SUBROUTINE write_deck

  ELEMENTAL LOGICAL FUNCTION bits_eq(x, y) RESULT(same)
    REAL(wp), INTENT(IN) :: x, y
    same = TRANSFER(x, 0_INT64) == TRANSFER(y, 0_INT64)
  END FUNCTION bits_eq

  FUNCTION bits_eq_v(x, y) RESULT(same)
    REAL(wp), INTENT(IN) :: x(:), y(:)
    LOGICAL :: same(SIZE(x))
    same = bits_eq(x, y)
  END FUNCTION bits_eq_v

  FUNCTION fmt_real(x) RESULT(s)
    REAL(wp), INTENT(IN) :: x
    CHARACTER(24) :: s
    WRITE (s, '(F10.3)') x
    s = ADJUSTL(s)
  END FUNCTION fmt_real

  SUBROUTINE require(ok, what)
    LOGICAL, INTENT(IN) :: ok
    CHARACTER(*), INTENT(IN) :: what
    IF (ok) THEN
      PRINT '(A)', 'PASS: '//what
    ELSE
      PRINT '(A)', 'FAIL: '//what
      nfail = nfail + 1
    END IF
  END SUBROUTINE require

END PROGRAM test_viscoelastic_control
