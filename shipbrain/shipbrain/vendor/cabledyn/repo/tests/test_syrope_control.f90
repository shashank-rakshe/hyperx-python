! File: tests/test_syrope_control.f90
! SPDX-License-Identifier: Apache-2.0
! Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
PROGRAM test_syrope_control
  !! Active line control (CONTROL, the OpenFAST CableDeltaL route of CD_Init_Deck_Aggregate) of a
  !! Syrope polyester segment. MoorDyn-F and MoorDyn-C keep each segment's slow STRETCH
  !! dl_1 = eps_slow*l as its state and leave it as it is when the unstretched length l changes;
  !! the slow strain after a change is dl_1/l at the new length. The oracles below evaluate the
  !! MoorDyn law from the shipped OWC table and the working-curve formula, independently of the
  !! CableDyn_Syrope kernel. The decks are written here: 100 m of polyester (10 segments) held
  !! taut between a Coupled fairlead and a Fixed anchor 102 m apart at mid-depth, nearly neutrally
  !! buoyant so that the tension is uniform, with a LINEAR working curve (k1 = 0.5) and a light
  !! BA_s|BA_d = 1e6|1e5 N s (slow-spring relaxation time (BA_s + BA_d)/K1 of about 6 ms).
  !!   1. Quasi-static pay-out and haul-in: the fairlead segment is paid out by 0.5 m over 20 s,
  !!      hauled in to -1 m over 40 s and paid back to 0 over 20 s, with 4 s holds. Every element's
  !!      tension follows the rest curve of its load history at the line's strain D/L(t) - 1: the
  !!      working curve of the static tension while unloading, the OWC beyond it (the running
  !!      maximum ratchets), then the working curve of the new maximum, which ends the cycle below
  !!      the initial tension. Gated over the ramps (the lag of the slow spring) and at the ends
  !!      of the holds (the rest point).
  !!   2. A length step from rest (pay-out 5 cm, haul-in 4 cm): the tension right after the
  !!      change is MoorDyn's at the carried stretch, T = T_mean + BA_s d(eps_slow)/dt with
  !!      eps_slow = eps_slow,0 l_1/l_2, and the slow strain after one step is the backward-Euler
  !!      step of d(dl_1)/dt = l_2 d(eps_slow)/dt from the carried stretch; the other elements are
  !!      untouched. The strain-carrying alternative (eps_slow kept) is printed for contrast.
  !!   3. Checkpoint restart in the middle of a pay-out ramp and in the hold after it: a fresh
  !!      instance takes the coupled kinematics, the line interior [q; v; a] and the Syrope states
  !!      of the first, re-applies the command as the committed one (restored), and both continue
  !!      bit for bit.
  !!   4. Composite lines: a polyester-chain line (the controlled segment is Syrope) takes the
  !!      oracle of 2 at its fairlead element and runs a ramp; a chain-polyester-chain line (the
  !!      controlled segment is chain) leaves its Syrope states untouched and runs the ramp.
  !!   5. Without CONTROL, under False alpha_force_blend: the fairlead pulled out 1 m over 40 s and
  !!      held, so the rope rests on its OWC at its new running maximum. The backward-Euler root
  !!      then lies next to the top sample of the working curve, where the safeguarded Newton step
  !!      alone crept and stopped the run (CableDyn_Syrope, CD_Syrope_State_Advance); every step
  !!      converges and the held tension is the OWC tension at the line strain.
  !!   6. A length change inside sub-steps: the fairlead sways sideways, y = 0.05 t^3, while its
  !!      segment is paid out at 0.1 m/s for 2 s, with ei0_substep_angle 1e-5 deg and
  !!      ei0_substep_max 4, so every step (0.05 s) is solved again in 4 sub-steps that spread
  !!      the length change over them. The oracle is the same run with ei0_substeps off in plain
  !!      steps of 0.0125 s with the command at the sub-step times (the
  !!      quintic end motion of a sub-step reproduces the cubic sway, and the interpolated lengths
  !!      the constant pay-out rate), compared at every 0.05 s.
  !! Gates 1-3 and the polyester-chain line of 4 stopped at initialisation before (CONTROL on a
  !! Syrope segment was refused).
  USE CableDyn_Precision, ONLY: wp
  USE CableDyn_OpenFAST_Aggregate, ONLY: CD_AGG_ModuleType, CD_AGG_Init_From_Deck, CD_AGG_GetMovingPointMesh, &
                                         CD_AGG_UpdateStates_Moving, CD_AGG_Step_Moving, CD_AGG_CalcOutput, &
                                         CD_AGG_Apply_LineControl, CD_AGG_Get_Substep_Counts, CD_AGG_End, &
                                         CD_AGG_OK
  USE CableDyn_System, ONLY: CD_System_NLines, CD_System_Line_NDOF, CD_System_Line_NElem, &
                             CD_Get_System_Line_State, CD_Get_System_Line_Tension, &
                             CD_Get_System_Line_Syrope_State, CD_Set_System_Line_Syrope_State, &
                             CD_Update_System_Line_Interior_State, CD_SYSTEM_OK
  USE, INTRINSIC :: ISO_FORTRAN_ENV, ONLY: INT64
  IMPLICIT NONE

  INTEGER, PARAMETER :: NOWC = 30, NWC = 30
  ! the shipped data/syrope/syrope_owc.dat table
  REAL(wp), PARAMETER :: OWC_EPS(NOWC) = [ &
                         0.00000e+00_wp, 2.06897e-03_wp, 4.13793e-03_wp, 6.20690e-03_wp, 8.27586e-03_wp, &
                         1.03448e-02_wp, 1.24138e-02_wp, 1.44828e-02_wp, 1.65517e-02_wp, 1.86207e-02_wp, &
                         2.06897e-02_wp, 2.27586e-02_wp, 2.48276e-02_wp, 2.68966e-02_wp, 2.89655e-02_wp, &
                         3.10345e-02_wp, 3.31034e-02_wp, 3.51724e-02_wp, 3.72414e-02_wp, 3.93103e-02_wp, &
                         4.13793e-02_wp, 4.34483e-02_wp, 4.55172e-02_wp, 4.75862e-02_wp, 4.96552e-02_wp, &
                         5.17241e-02_wp, 5.37931e-02_wp, 5.58621e-02_wp, 5.79310e-02_wp, 6.00000e-02_wp]
  REAL(wp), PARAMETER :: OWC_TEN(NOWC) = [ &
                         0.00000e+00_wp, 1.71768e+05_wp, 3.30952e+05_wp, 4.78788e+05_wp, 6.16510e+05_wp, &
                         7.45355e+05_wp, 8.66556e+05_wp, 9.81351e+05_wp, 1.09097e+06_wp, 1.19666e+06_wp, &
                         1.29964e+06_wp, 1.40116e+06_wp, 1.50245e+06_wp, 1.60474e+06_wp, 1.70927e+06_wp, &
                         1.81728e+06_wp, 1.93000e+06_wp, 2.04866e+06_wp, 2.17450e+06_wp, 2.30876e+06_wp, &
                         2.45267e+06_wp, 2.60747e+06_wp, 2.77439e+06_wp, 2.95467e+06_wp, 3.14954e+06_wp, &
                         3.36024e+06_wp, 3.58800e+06_wp, 3.83406e+06_wp, 4.09965e+06_wp, 4.38601e+06_wp]
  ! the polyester constants of the decks: alpha|beta of the EA column, BA_s|BA_d, the LINEAR k1
  REAL(wp), PARAMETER :: ALPHA = 1.53e8_wp, BETA = 23.12_wp, BA_S = 1.0e6_wp, BA_D = 1.0e5_wp, K1W = 0.5_wp
  REAL(wp), PARAMETER :: PI = 3.141592653589793_wp, DT = 0.05_wp
  INTEGER :: nfail = 0

  CALL write_owc('sctl_owc.dat')
  CALL write_settings('sctl_settings.dat', 'sctl_owc.dat')
  CALL write_deck('sctl_single.dat', 'single')
  CALL write_deck('sctl_poly_chain.dat', 'poly_chain')
  CALL write_deck('sctl_chain_poly_chain.dat', 'chain_poly_chain')
  CALL write_deck('sctl_single_noblend.dat', 'single', no_force_blend=.TRUE.)
  CALL write_deck('sctl_hold_noblend.dat', 'single', no_force_blend=.TRUE., no_control=.TRUE.)
  CALL write_deck('sctl_sub.dat', 'single', options=[CHARACTER(24) :: '1.0e-5 ei0_substep_angle', &
                                                     '4 ei0_substep_max'])
  CALL write_deck('sctl_sub_ref.dat', 'single', options=[CHARACTER(24) :: '1.0e-5 ei0_substep_angle', &
                                                         'off ei0_substeps'])

  CALL case_quasi_static('sctl_single.dat', 'quasi-static')
  CALL case_quasi_static('sctl_single_noblend.dat', 'quasi-static, False alpha_force_blend')
  CALL case_length_step('sctl_single.dat', 0.05_wp, 'pay-out step')
  CALL case_length_step('sctl_single.dat', -0.04_wp, 'haul-in step')
  CALL case_restart()
  CALL case_composite()
  CALL case_hold_at_maximum()
  CALL case_substep_length_change()

  IF (nfail > 0) THEN
    PRINT '(I0,A)', nfail, ' assertion(s) failed'
    ERROR STOP 1
  END IF
  PRINT '(A)', 'all Syrope line-control checks passed'

CONTAINS

  ! ---------------------------------------------------------------------------------------------
  ! 1. quasi-static pay-out and haul-in
  ! ---------------------------------------------------------------------------------------------

  SUBROUTINE case_quasi_static(deck, what)
    CHARACTER(*), INTENT(IN) :: deck, what
    TYPE(CD_AGG_ModuleType) :: agg
    INTEGER, PARAMETER :: NSTEP = 1840
    REAL(wp) :: r0(3, 1), vel(3, 1), acc(3, 1), ld(3, 1), dl, dldot, t, chord, l_tot, eps, t_o, tmax_o
    REAL(wp) :: t0, err_ramp, err_hold, hold_at(3), t_end, wc_lo
    REAL(wp), ALLOCATABLE :: ten(:)
    INTEGER :: es, ni, s, il, ec, ne, k, n_hold
    LOGICAL :: cv, st, ok
    CHARACTER(512) :: em

    CALL CD_AGG_Init_From_Deck(agg, deck, DT, es, em)
    CALL require(es == CD_AGG_OK, what//': the controlled Syrope deck initialises: '//TRIM(em))
    IF (es /= CD_AGG_OK) RETURN
    CALL CD_AGG_GetMovingPointMesh(agg, r0, vel, acc, ld, es, em)
    vel = 0.0_wp
    acc = 0.0_wp
    il = agg%ctrl_line(1)
    ec = agg%ctrl_elem(1)
    ne = CD_System_Line_NElem(agg%sys%fast%system, il, es, em)
    ALLOCATE (ten(ne))
    ASSOCIATE (md => agg%sys%fast%system%lines(il))
      CALL require(md%has_syrope .AND. md%syrope_is(ec), what//': the controlled segment is Syrope')
      chord = NORM2(md%q(3*md%elem_conn(2, ne) - 2:3*md%elem_conn(2, ne)) - &
                    md%q(3*md%elem_conn(1, 1) - 2:3*md%elem_conn(1, 1)))
      l_tot = SUM(md%l0)
    END ASSOCIATE
    CALL CD_Get_System_Line_Tension(agg%sys%fast%system, il, ten, es, em)
    t0 = ten(ec)
    ! a virgin rope: the static tension on the OWC, and the running maximum starts there
    tmax_o = owc_t(chord/l_tot - 1.0_wp)
    PRINT '(A,F9.4,A,F9.4,A,ES12.5,A,ES12.5,A)', '  line chord ', chord, ' m, unstretched ', l_tot, &
      ' m: static tension ', t0, ' N, OWC ', tmax_o, ' N'
    CALL require(ABS(t0 - tmax_o) <= 1.0e-8_wp*tmax_o .AND. MAXVAL(ABS(ten - t0)) <= 1.0e-8_wp*t0, &
                 what//': the line starts on its OWC with a uniform tension')
    hold_at = [24.0_wp, 68.0_wp, 92.0_wp]
    err_ramp = 0.0_wp
    err_hold = 0.0_wp
    n_hold = 0
    wc_lo = HUGE(1.0_wp)
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
      ! the oracle: the rest curve of the load history at the line's strain
      eps = chord/(l_tot + dl) - 1.0_wp
      t_o = rest_tension(eps, tmax_o)
      wc_lo = MIN(wc_lo, t_o)
      err_ramp = MAX(err_ramp, MAXVAL(ABS(ten - t_o))/t0)
      DO k = 1, 3
        IF (ABS(t - hold_at(k)) < 0.5_wp*DT) THEN
          err_hold = MAX(err_hold, MAXVAL(ABS(ten - t_o))/t_o)
          n_hold = n_hold + 1
         PRINT '(A,F6.1,A,F7.3,A,ES12.5,A,ES12.5,A,ES10.3)', '  '//what//', end of hold t = ', t, ' s, DeltaL = ', dl, &
            ' m: tension ', ten(ec), ' N, rest curve ', t_o, ' N, rel. difference ', ABS(ten(ec) - t_o)/t_o
        END IF
      END DO
    END DO
    IF (ok) THEN
      t_end = ten(ec)
      ASSOCIATE (md => agg%sys%fast%system%lines(il))
        PRINT '(A,ES12.5,A,ES12.5,A)', '  running maximum after the haul-in ', md%syrope_tmax(ec), ' N (oracle ', &
          tmax_o, ' N)'
        CALL require(ABS(md%syrope_tmax(ec) - tmax_o) <= 1.0e-6_wp*tmax_o, &
                     what//': the haul-in ratchets the running maximum to the OWC tension at its top')
        CALL require(bits_eq(md%l0(ec), agg%ctrl_base_l0(1)), &
                     what//': the cycle returns the segment to its base length')
      END ASSOCIATE
      PRINT '(A,ES10.3,A,ES10.3)', '  max |T - T_rest| / T0 over the ramps ', err_ramp, &
        '; at the ends of the holds / T_rest ', err_hold
      PRINT '(A,ES12.5,A,ES12.5,A)', '  back at the base length: tension ', t_end, ' N, initial ', t0, &
        ' N (the working curve of the new maximum)'
      CALL require(n_hold == 3 .AND. err_hold <= 1.0e-6_wp, &
                   what//': at rest the tension is the rest-curve tension of the load history')
      CALL require(err_ramp <= 3.0e-3_wp, what//': along the ramps the tension follows the rest curve')
      CALL require(t_end < 0.6_wp*t0, what//': the cycle ends on the lower working curve of the new maximum')
    END IF
    CALL CD_AGG_End(agg, es, em)
  END SUBROUTINE case_quasi_static

  SUBROUTINE cycle_command(t, dl, dldot)
    !! The command of gate 1: pay out 0.5 m on a half-cosine over 20 s, hold 4 s, haul in to
    !! -1 m over 40 s, hold 4 s, pay back to 0 over 20 s, hold.
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
    !! From a to b on a half-cosine over [t_start, t_start + span].
    REAL(wp), INTENT(IN) :: t, t_start, span, a, b
    REAL(wp), INTENT(OUT) :: x, xdot
    x = a + (b - a)*0.5_wp*(1.0_wp - COS(PI*(t - t_start)/span))
    xdot = (b - a)*0.5_wp*(PI/span)*SIN(PI*(t - t_start)/span)
  END SUBROUTINE half_cosine

  REAL(wp) FUNCTION rest_tension(eps, tmax) RESULT(t)
    !! The rest (quasi-static) tension at strain eps of a rope with running maximum tmax: the OWC
    !! beyond the curve's top eps_owc(tmax), where tmax ratchets to it, else the LINEAR working
    !! curve tmax (eps - eps_min)/(eps_max - eps_min), eps_min = eps_0 + k1 (eps_max - eps_0),
    !! zero below eps_min.
    REAL(wp), INTENT(IN) :: eps
    REAL(wp), INTENT(INOUT) :: tmax
    REAL(wp) :: e_max, e_min
    e_max = owc_e(tmax)
    IF (eps >= e_max) THEN
      t = owc_t(eps)
      tmax = MAX(tmax, t)
      RETURN
    END IF
    e_min = OWC_EPS(1) + K1W*(e_max - OWC_EPS(1))
    t = 0.0_wp
    IF (eps > e_min) t = tmax*(eps - e_min)/(e_max - e_min)
  END FUNCTION rest_tension

  ! ---------------------------------------------------------------------------------------------
  ! 2. a length step from rest
  ! ---------------------------------------------------------------------------------------------

  SUBROUTINE case_length_step(deck, step_dl, what)
    CHARACTER(*), INTENT(IN) :: deck, what
    REAL(wp), INTENT(IN) :: step_dl
    TYPE(CD_AGG_ModuleType) :: agg
    REAL(wp) :: r0(3, 1), vel(3, 1), acc(3, 1), ld(3, 1), l1, l2, eps, deps, t_md, t_alt, s_carry, s_be
    REAL(wp), ALLOCATABLE :: slow0(:), tmax0(:), slow1(:), tmax1(:), ten0(:), ten1(:)
    INTEGER :: es, ni, il, ec, ne, others
    INTEGER(INT64) :: calls, events, capped, fallbacks
    INTEGER :: max_used
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
    ALLOCATE (slow0(ne), tmax0(ne), slow1(ne), tmax1(ne), ten0(ne), ten1(ne))
    CALL CD_Get_System_Line_Syrope_State(agg%sys%fast%system, il, slow0, tmax0, es, em)
    CALL CD_Get_System_Line_Tension(agg%sys%fast%system, il, ten0, es, em)
    l1 = agg%sys%fast%system%lines(il)%l0(ec)
    CALL CD_AGG_Apply_LineControl(agg, [step_dl], [0.0_wp], es, em)
    CALL require(es == CD_AGG_OK, what//': the command applies: '//TRIM(em))
    IF (es /= CD_AGG_OK) RETURN
    ASSOCIATE (md => agg%sys%fast%system%lines(il))
      l2 = md%l0(ec)
      CALL require(md%syrope_is(ec) .AND. bits_eq(l2, l1 + step_dl), what//': the Syrope segment takes l1 + DeltaL')
      CALL element_kinematics(md%q, md%v, md%elem_conn(:, ec), l2, eps, deps)
    END ASSOCIATE
    ! right after the change: MoorDyn's tension at the carried stretch, and the strain-carrying
    ! alternative for contrast
    CALL CD_Get_System_Line_Tension(agg%sys%fast%system, il, ten1, es, em)
    s_carry = slow0(ec)*l1/l2
    t_md = kernel_tension(s_carry, eps, deps, tmax0(ec))
    t_alt = kernel_tension(slow0(ec), eps, deps, tmax0(ec))
    others = COUNT(.NOT. bits_eq_v(ten1, ten0)) - MERGE(1, 0,.NOT. bits_eq(ten1(ec), ten0(ec)))
    PRINT '(A,A,F6.3,A,ES12.5,A,ES12.5,A,ES12.5,A,ES10.3)', '  ', what, step_dl, ' m: tension ', ten0(ec), &
      ' -> ', ten1(ec), ' N, MoorDyn (stretch carried) ', t_md, ' N, rel. difference ', ABS(ten1(ec) - t_md)/t_md
    PRINT '(A,ES12.5,A,ES10.3,A)', '    strain carried instead: ', t_alt, ' N (', ABS(t_alt - t_md)/t_md, &
      ' off MoorDyn)'
    CALL require(ABS(ten1(ec) - t_md) <= 1.0e-10_wp*t_md, &
                 what//': the tension after the change is MoorDyn''s at the carried slow stretch')
    CALL require(ABS(t_alt - t_md) > 1.0e-4_wp*t_md, what//': the oracle tells the stretch from the strain carry')
    CALL require(others == 0, what//': the other elements keep their tension')
    ! one step from the carried stretch: the backward-Euler step of d(dl_1)/dt = l2 d(eps_slow)/dt
    CALL CD_AGG_Step_Moving(agg, DT, r0, vel, acc, cv, st, ni, es, em)
    CALL require(es == CD_AGG_OK .AND. cv, what//': the step after the change converges: '//TRIM(em))
    IF (es /= CD_AGG_OK) RETURN
    CALL CD_AGG_Get_Substep_Counts(agg, calls, events, max_used, capped, fallbacks)
    CALL CD_Get_System_Line_Syrope_State(agg%sys%fast%system, il, slow1, tmax1, es, em)
    ASSOCIATE (md => agg%sys%fast%system%lines(il))
      CALL element_kinematics(md%q, md%v, md%elem_conn(:, ec), l2, eps, deps)
    END ASSOCIATE
    s_be = backward_euler(s_carry, eps, deps, tmax0(ec), DT)
    PRINT '(A,ES16.9,A,ES16.9,A,ES10.3,A,I0,A)', '    slow strain after one step ', slow1(ec), ', oracle ', s_be, &
      ' (rel. ', ABS(slow1(ec) - s_be)/s_be, '; ', events, ' sub-stepped steps)'
    CALL require(events == 0 .AND. ABS(slow1(ec) - s_be) <= 1.0e-9_wp*s_be, &
                 what//': the step advances the carried slow stretch (backward Euler at the new length)')
    IF (step_dl < 0.0_wp) THEN
      PRINT '(A,ES12.5,A,ES12.5,A)', '    running maximum ', tmax0(ec), ' -> ', tmax1(ec), ' N'
      CALL require(tmax1(ec) > tmax0(ec), what//': the haul-in onto the OWC ratchets the running maximum')
    ELSE
      CALL require(bits_eq(tmax1(ec), tmax0(ec)), what//': the pay-out leaves the running maximum')
    END IF
    CALL CD_AGG_End(agg, es, em)
  END SUBROUTINE case_length_step

  SUBROUTINE element_kinematics(q, v, conn, l0, eps, deps)
    !! Strain and strain rate of one element, MoorDyn's dl/l and lstrd/l (the chord rate).
    REAL(wp), INTENT(IN) :: q(:), v(:), l0
    INTEGER, INTENT(IN) :: conn(2)
    REAL(wp), INTENT(OUT) :: eps, deps
    REAL(wp) :: chord(3), length
    chord = q(3*conn(2) - 2:3*conn(2)) - q(3*conn(1) - 2:3*conn(1))
    length = NORM2(chord)
    eps = (length - l0)/l0
    deps = DOT_PRODUCT(chord/length, v(3*conn(2) - 2:3*conn(2)) - v(3*conn(1) - 2:3*conn(1)))/l0
  END SUBROUTINE element_kinematics

  REAL(wp) FUNCTION backward_euler(s0, eps, deps, tmax, h) RESULT(s)
    !! The projected backward-Euler step s = max(0, root of s - s0 - h r(s)), by bisection.
    REAL(wp), INTENT(IN) :: s0, eps, deps, tmax, h
    REAL(wp) :: lo, hi, mid, rate, ten
    INTEGER :: it
    lo = 0.0_wp
    CALL kernel_rate(lo, eps, deps, tmax, rate, ten)
    s = 0.0_wp
    IF (lo - s0 - h*rate >= 0.0_wp) RETURN
    hi = 0.2_wp
    DO it = 1, 200
      mid = 0.5_wp*(lo + hi)
      CALL kernel_rate(mid, eps, deps, tmax, rate, ten)
      IF (mid - s0 - h*rate < 0.0_wp) THEN
        lo = mid
      ELSE
        hi = mid
      END IF
    END DO
    s = 0.5_wp*(lo + hi)
  END FUNCTION backward_euler

  REAL(wp) FUNCTION kernel_tension(slow, eps, deps, tmax) RESULT(t)
    REAL(wp), INTENT(IN) :: slow, eps, deps, tmax
    REAL(wp) :: rate
    CALL kernel_rate(slow, eps, deps, tmax, rate, t)
  END FUNCTION kernel_tension

  SUBROUTINE kernel_rate(slow, eps, deps, tmax, rate, ten)
    !! MoorDyn's Syrope segment law (MoorDyn-C Line::getStateDeriv, MoorDyn-F Line_GetStateDeriv,
    !! ElasticMod 4) in strain form: the mean tension from the slow strain on the working curve
    !! of tmax (30 samples) below the OWC's slow strain at tmax and on the OWC from it,
    !! K1 = alpha + beta T_mean, d(eps_slow)/dt = (K1 (eps - eps_curve(T_mean)) + BA_d deps)/(BA_s +
    !! BA_d) and T = T_mean (eps >= 0) + BA_s d(eps_slow)/dt, clamped at zero (a line cannot push).
    REAL(wp), INTENT(IN) :: slow, eps, deps, tmax
    REAL(wp), INTENT(OUT) :: rate, ten
    REAL(wp) :: we(NWC), wt(NWC), ws(NWC), os(NOWC), e_max, e_min, t_mean, e_curve
    INTEGER :: k
    DO k = 1, NOWC
      os(k) = OWC_EPS(k) - fast_strain(OWC_TEN(k))
    END DO
    e_max = owc_e(tmax)
    e_min = OWC_EPS(1) + K1W*(e_max - OWC_EPS(1))
    DO k = 1, NWC
      we(k) = e_min + (e_max - e_min)*REAL(k - 1, wp)/REAL(NWC - 1, wp)
      wt(k) = tmax*(we(k) - e_min)/(e_max - e_min)
      ws(k) = we(k) - fast_strain(wt(k))
    END DO
    IF (slow < lin(tmax, OWC_TEN, os)) THEN
      t_mean = lin(slow, ws, wt)
      e_curve = lin(t_mean, wt, we)
    ELSE
      t_mean = lin(slow, os, OWC_TEN)
      e_curve = lin(t_mean, OWC_TEN, OWC_EPS)
    END IF
    rate = ((ALPHA + BETA*t_mean)*(eps - e_curve) + BA_D*deps)/(BA_S + BA_D)
    ten = BA_S*rate
    IF (eps >= 0.0_wp) ten = ten + t_mean
    ten = MAX(ten, 0.0_wp)
  END SUBROUTINE kernel_rate

  REAL(wp) FUNCTION fast_strain(t) RESULT(e)
    !! The exponential fast spring, eps_fast = ln(1 + (beta/alpha) T)/beta.
    REAL(wp), INTENT(IN) :: t
    e = LOG(1.0_wp + BETA/ALPHA*t)/BETA
  END FUNCTION fast_strain

  ! ---------------------------------------------------------------------------------------------
  ! 3. checkpoint restart
  ! ---------------------------------------------------------------------------------------------

  SUBROUTINE case_restart()
    !! The shell's rebuild recipe (CableDyn_OF): a fresh instance B takes A's coupled kinematics,
    !! re-applies the restored command, then reloads the line interior and the Syrope mirror.
    TYPE(CD_AGG_ModuleType) :: agg_a, agg_b
    INTEGER, PARAMETER :: NPOST = 12
    REAL(wp) :: r0(3, 1), vel(3, 1), acc(3, 1), pa(3, 1), la(3, 1), pb(3, 1), lb(3, 1), v2(3, 1), a2(3, 1)
    REAL(wp) :: dl, dldot, dmax
    REAL(wp), ALLOCATABLE :: qL(:), vL(:), aL(:), slow(:), tmax(:), slow_b(:), tmax_b(:)
    INTEGER :: es, ni, s, il, ndof, ne, npre, pass
    LOGICAL :: cv, st, same
    CHARACTER(512) :: em

    DO pass = 1, 2
      npre = MERGE(15, 50, pass == 1)
      CALL CD_AGG_Init_From_Deck(agg_a, 'sctl_single.dat', DT, es, em)
      CALL require(es == CD_AGG_OK, 'restart: A initialises: '//TRIM(em))
      IF (es /= CD_AGG_OK) RETURN
      CALL CD_AGG_GetMovingPointMesh(agg_a, r0, vel, acc, la, es, em)
      vel = 0.0_wp
      acc = 0.0_wp
      DO s = 1, npre
        CALL restart_command(s, dl, dldot)
        CALL CD_AGG_Apply_LineControl(agg_a, [dl], [dldot], es, em)
        IF (es == CD_AGG_OK) CALL CD_AGG_Step_Moving(agg_a, DT, r0, vel, acc, cv, st, ni, es, em)
        IF (es /= CD_AGG_OK .OR. .NOT. cv) THEN
          CALL require(.FALSE., 'restart: A marches: '//TRIM(em))
          RETURN
        END IF
      END DO
      CALL CD_AGG_Init_From_Deck(agg_b, 'sctl_single.dat', DT, es, em)
      CALL require(es == CD_AGG_OK, 'restart: B initialises: '//TRIM(em))
      CALL CD_AGG_GetMovingPointMesh(agg_a, pa, v2, a2, la, es, em)
      CALL CD_AGG_UpdateStates_Moving(agg_b, pa, v2, a2, es, em)
      ! the restored command is the one A's committed state was reached with
      CALL restart_command(npre, dl, dldot)
      CALL CD_AGG_Apply_LineControl(agg_b, [dl], [dldot], es, em, restored=.TRUE.)
      CALL require(es == CD_AGG_OK, 'restart: B re-applies the command: '//TRIM(em))
      il = agg_a%ctrl_line(1)
      ndof = CD_System_Line_NDOF(agg_a%sys%fast%system, il, es, em)
      ne = CD_System_Line_NElem(agg_a%sys%fast%system, il, es, em)
      IF (ALLOCATED(qL)) DEALLOCATE (qL, vL, aL, slow, tmax, slow_b, tmax_b)
      ALLOCATE (qL(ndof), vL(ndof), aL(ndof), slow(ne), tmax(ne), slow_b(ne), tmax_b(ne))
      CALL CD_Get_System_Line_State(agg_a%sys%fast%system, il, qL, vL, aL, es, em)
      CALL CD_Update_System_Line_Interior_State(agg_b%sys%fast%system, il, qL(4:ndof - 3), vL(4:ndof - 3), &
                                                es, em, a_interior=aL(4:ndof - 3))
      CALL require(es == CD_SYSTEM_OK, 'restart: B takes the line interior: '//TRIM(em))
      CALL CD_Get_System_Line_Syrope_State(agg_a%sys%fast%system, il, slow, tmax, es, em)
      CALL CD_Set_System_Line_Syrope_State(agg_b%sys%fast%system, il, slow, tmax, es, em)
      CALL require(es == CD_SYSTEM_OK, 'restart: B takes the Syrope mirror: '//TRIM(em))
      ASSOCIATE (ma => agg_a%sys%fast%system%lines(il), mb => agg_b%sys%fast%system%lines(il))
        same = ALL(bits_eq_v(ma%l0, mb%l0)) .AND. ALL(bits_eq_v(ma%l0_c, mb%l0_c))
      END ASSOCIATE
      CALL require(same, 'restart: B carries the lengths and the committed lengths of A')
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
        CALL CD_Get_System_Line_Syrope_State(agg_a%sys%fast%system, il, slow, tmax, es, em)
        CALL CD_Get_System_Line_Syrope_State(agg_b%sys%fast%system, il, slow_b, tmax_b, es, em)
        dmax = MAX(dmax, MAXVAL(ABS(la - lb)), MAXVAL(ABS(slow - slow_b)))
        same = same .AND. ALL(bits_eq_v(RESHAPE(la, [3]), RESHAPE(lb, [3]))) .AND. &
               ALL(bits_eq_v(slow, slow_b)) .AND. ALL(bits_eq_v(tmax, tmax_b)) .AND. &
               ALL(bits_eq_v(agg_a%sys%fast%system%lines(il)%q, agg_b%sys%fast%system%lines(il)%q))
      END DO
      PRINT '(A,I0,A,F5.2,A,ES10.3)', '  restart after step ', npre, ' (DeltaL ', &
        agg_a%sys%fast%system%lines(il)%l0(agg_a%ctrl_elem(1)) - agg_a%ctrl_base_l0(1), &
        ' m): max difference of the fairlead load and the slow strains ', dmax
      CALL require(same, 'restart: the restarted run continues bit for bit ('// &
                   MERGE('mid-ramp', 'hold    ', pass == 1)//')')
      CALL CD_AGG_End(agg_a, es, em)
      CALL CD_AGG_End(agg_b, es, em)
    END DO
  END SUBROUTINE case_restart

  SUBROUTINE restart_command(step, dl, dldot)
    !! A 0.4 m pay-out on a half-cosine over 2 s, then held (gate 3).
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
  ! 4. composite lines
  ! ---------------------------------------------------------------------------------------------

  SUBROUTINE case_composite()
    TYPE(CD_AGG_ModuleType) :: agg
    REAL(wp) :: r0(3, 1), vel(3, 1), acc(3, 1), ld(3, 1)
    REAL(wp), ALLOCATABLE :: slow0(:), tmax0(:), slow1(:), tmax1(:), ten0(:), ten1(:)
    INTEGER :: es, il, ec, ne
    CHARACTER(512) :: em

    ! the polyester at the fairlead: the controlled segment is Syrope (the oracle of gate 2)
    CALL case_length_step('sctl_poly_chain.dat', 0.04_wp, 'polyester-chain pay-out step')
    CALL ramp_runs('sctl_poly_chain.dat', 'polyester-chain')

    ! chain at the fairlead: the controlled segment is chain and the Syrope states stay as they are
    CALL CD_AGG_Init_From_Deck(agg, 'sctl_chain_poly_chain.dat', DT, es, em)
    CALL require(es == CD_AGG_OK, 'chain-polyester-chain: the deck initialises: '//TRIM(em))
    IF (es /= CD_AGG_OK) RETURN
    CALL CD_AGG_GetMovingPointMesh(agg, r0, vel, acc, ld, es, em)
    vel = 0.0_wp
    acc = 0.0_wp
    il = agg%ctrl_line(1)
    ec = agg%ctrl_elem(1)
    ne = CD_System_Line_NElem(agg%sys%fast%system, il, es, em)
    ALLOCATE (slow0(ne), tmax0(ne), slow1(ne), tmax1(ne), ten0(ne), ten1(ne))
    CALL require(.NOT. agg%sys%fast%system%lines(il)%syrope_is(ec) .AND. &
                 COUNT(agg%sys%fast%system%lines(il)%syrope_is) == 8, &
                 'chain-polyester-chain: the controlled segment is chain, the polyester Syrope')
    CALL CD_Get_System_Line_Syrope_State(agg%sys%fast%system, il, slow0, tmax0, es, em)
    CALL CD_Get_System_Line_Tension(agg%sys%fast%system, il, ten0, es, em)
    CALL CD_AGG_Apply_LineControl(agg, [0.2_wp], [0.0_wp], es, em)
    CALL CD_Get_System_Line_Syrope_State(agg%sys%fast%system, il, slow1, tmax1, es, em)
    CALL CD_Get_System_Line_Tension(agg%sys%fast%system, il, ten1, es, em)
    ASSOCIATE (md => agg%sys%fast%system%lines(il))
      CALL require(ALL(bits_eq_v(slow1, slow0)) .AND. ALL(bits_eq_v(tmax1, tmax0)) .AND. &
                   ALL(bits_eq_v(PACK(ten1, md%syrope_is), PACK(ten0, md%syrope_is))) .AND. ten1(ec) < ten0(ec), &
                   'chain-polyester-chain: a chain command leaves the Syrope states and tensions as they are')
    END ASSOCIATE
    CALL CD_AGG_End(agg, es, em)
    CALL ramp_runs('sctl_chain_poly_chain.dat', 'chain-polyester-chain')
  END SUBROUTINE case_composite

  SUBROUTINE ramp_runs(deck, what)
    !! Pay the fairlead segment out 0.4 m over 2 s, hold 1 s, haul it in to -0.4 m over 4 s and
    !! hold 1 s: every step converges and the fairlead tension falls and rises with the command.
    CHARACTER(*), INTENT(IN) :: deck, what
    TYPE(CD_AGG_ModuleType) :: agg
    REAL(wp) :: r0(3, 1), vel(3, 1), acc(3, 1), ld(3, 1), dl, dldot, t, t_lo, t_hi, t0
    REAL(wp), ALLOCATABLE :: ten(:)
    INTEGER :: es, ni, s, il, ec, ne
    LOGICAL :: cv, st, ok
    CHARACTER(512) :: em

    CALL CD_AGG_Init_From_Deck(agg, deck, DT, es, em)
    CALL require(es == CD_AGG_OK, what//' ramp: the deck initialises: '//TRIM(em))
    IF (es /= CD_AGG_OK) RETURN
    CALL CD_AGG_GetMovingPointMesh(agg, r0, vel, acc, ld, es, em)
    vel = 0.0_wp
    acc = 0.0_wp
    il = agg%ctrl_line(1)
    ec = agg%ctrl_elem(1)
    ne = CD_System_Line_NElem(agg%sys%fast%system, il, es, em)
    ALLOCATE (ten(ne))
    CALL CD_Get_System_Line_Tension(agg%sys%fast%system, il, ten, es, em)
    t0 = ten(ec)
    t_lo = t0
    t_hi = t0
    ok = .TRUE.
    DO s = 1, 160
      t = REAL(s, wp)*DT
      IF (t < 2.0_wp) THEN
        CALL half_cosine(t, 0.0_wp, 2.0_wp, 0.0_wp, 0.4_wp, dl, dldot)
      ELSE IF (t < 3.0_wp) THEN
        dl = 0.4_wp
        dldot = 0.0_wp
      ELSE IF (t < 7.0_wp) THEN
        CALL half_cosine(t, 3.0_wp, 4.0_wp, 0.4_wp, -0.4_wp, dl, dldot)
      ELSE
        dl = -0.4_wp
        dldot = 0.0_wp
      END IF
      CALL CD_AGG_Apply_LineControl(agg, [dl], [dldot], es, em)
      IF (es == CD_AGG_OK) CALL CD_AGG_Step_Moving(agg, DT, r0, vel, acc, cv, st, ni, es, em)
      IF (es /= CD_AGG_OK .OR. .NOT. cv) THEN
        ok = .FALSE.
        EXIT
      END IF
      CALL CD_Get_System_Line_Tension(agg%sys%fast%system, il, ten, es, em)
      t_lo = MIN(t_lo, ten(ec))
      t_hi = MAX(t_hi, ten(ec))
    END DO
    PRINT '(A,A,A,ES12.5,A,ES12.5,A,ES12.5,A)', '  ', what, ' ramp: fairlead-segment tension ', t0, &
      ' N, from ', t_lo, ' to ', t_hi, ' N'
    CALL require(ok .AND. t_lo < 0.9_wp*t0 .AND. t_hi > 1.05_wp*t0, &
                 what//' ramp: every step converges and the tension follows the command: '//TRIM(em))
    CALL CD_AGG_End(agg, es, em)
  END SUBROUTINE ramp_runs

  ! ---------------------------------------------------------------------------------------------
  ! 5. a rope held at its running maximum, no CONTROL
  ! ---------------------------------------------------------------------------------------------

  SUBROUTINE case_hold_at_maximum()
    TYPE(CD_AGG_ModuleType) :: agg
    REAL(wp) :: r0(3, 1), pos(3, 1), vel(3, 1), acc(3, 1), ld(3, 1), x, xdot, t, chord, l_tot, t_o
    REAL(wp), ALLOCATABLE :: ten(:)
    INTEGER :: es, ni, s, il, ne
    LOGICAL :: cv, st, ok
    CHARACTER(512) :: em

    CALL CD_AGG_Init_From_Deck(agg, 'sctl_hold_noblend.dat', DT, es, em)
    CALL require(es == CD_AGG_OK, 'held at the maximum: the deck initialises: '//TRIM(em))
    IF (es /= CD_AGG_OK) RETURN
    CALL CD_AGG_GetMovingPointMesh(agg, r0, vel, acc, ld, es, em)
    il = 1
    ne = CD_System_Line_NElem(agg%sys%fast%system, il, es, em)
    ALLOCATE (ten(ne))
    ASSOCIATE (md => agg%sys%fast%system%lines(il))
      l_tot = SUM(md%l0)
    END ASSOCIATE
    ok = .TRUE.
    DO s = 1, 960
      t = REAL(s, wp)*DT
      IF (t < 40.0_wp) THEN
        CALL half_cosine(t, 0.0_wp, 40.0_wp, 0.0_wp, -1.0_wp, x, xdot)
      ELSE
        x = -1.0_wp
        xdot = 0.0_wp
      END IF
      pos = r0
      pos(1, 1) = r0(1, 1) + x
      vel = 0.0_wp
      vel(1, 1) = xdot
      acc = 0.0_wp
      CALL CD_AGG_Step_Moving(agg, DT, pos, vel, acc, cv, st, ni, es, em)
      IF (es /= CD_AGG_OK .OR. .NOT. cv) THEN
        ok = .FALSE.
        CALL require(.FALSE., 'held at the maximum: step at t = '//TRIM(fmt_real(t))//': '//TRIM(em))
        EXIT
      END IF
    END DO
    IF (ok) THEN
      CALL CD_Get_System_Line_Tension(agg%sys%fast%system, il, ten, es, em)
      ASSOCIATE (md => agg%sys%fast%system%lines(il))
        chord = NORM2(md%q(3*md%elem_conn(2, ne) - 2:3*md%elem_conn(2, ne)) - &
                      md%q(3*md%elem_conn(1, 1) - 2:3*md%elem_conn(1, 1)))
      END ASSOCIATE
      t_o = owc_t(chord/l_tot - 1.0_wp)
      PRINT '(A,ES12.5,A,ES12.5,A,ES10.3)', '  held at the maximum for 8 s: tension ', MAXVAL(ten), ' N, OWC ', t_o, &
        ' N, rel. difference ', MAXVAL(ABS(ten - t_o))/t_o
      CALL require(MAXVAL(ABS(ten - t_o)) <= 1.0e-6_wp*t_o, &
                   'held at the maximum: every step converges and the rope rests on its OWC')
    END IF
    CALL CD_AGG_End(agg, es, em)
  END SUBROUTINE case_hold_at_maximum

  ! ---------------------------------------------------------------------------------------------
  ! 6. a length change inside sub-steps
  ! ---------------------------------------------------------------------------------------------

  SUBROUTINE case_substep_length_change()
    INTEGER, PARAMETER :: NSTEP = 40, NSUB = 4
    REAL(wp), PARAMETER :: C_SWAY = 0.05_wp, RATE = 0.1_wp
    TYPE(CD_AGG_ModuleType) :: agg, ref
    REAL(wp) :: r0(3, 1), pos(3, 1), vel(3, 1), acc(3, 1), la(3, 1), lr(3, 1), v2(3, 1), a2(3, 1), t, h
    REAL(wp) :: d_load, d_slow, d_ten, load_scale, rate_k
    REAL(wp), ALLOCATABLE :: slow_a(:), tmax_a(:), slow_r(:), tmax_r(:), ten_a(:), ten_r(:)
    INTEGER :: es, ni, s, k, il, ec, ne, max_a, max_r, n_sub, n_ref
    INTEGER(INT64) :: calls, ev_a, ev_prev, ev_r, capped, fallbacks
    LOGICAL :: cv, st, ok, sub
    CHARACTER(512) :: em

    CALL CD_AGG_Init_From_Deck(agg, 'sctl_sub.dat', DT, es, em)
    CALL require(es == CD_AGG_OK, 'sub-steps: the deck initialises: '//TRIM(em))
    IF (es /= CD_AGG_OK) RETURN
    h = DT/REAL(NSUB, wp)
    CALL CD_AGG_Init_From_Deck(ref, 'sctl_sub_ref.dat', h, es, em)
    CALL require(es == CD_AGG_OK, 'sub-steps: the reference deck initialises: '//TRIM(em))
    IF (es /= CD_AGG_OK) RETURN
    CALL CD_AGG_GetMovingPointMesh(agg, r0, vel, acc, la, es, em)
    il = agg%ctrl_line(1)
    ec = agg%ctrl_elem(1)
    ne = CD_System_Line_NElem(agg%sys%fast%system, il, es, em)
    ALLOCATE (slow_a(ne), tmax_a(ne), slow_r(ne), tmax_r(ne), ten_a(ne), ten_r(ne))
    d_load = 0.0_wp
    d_slow = 0.0_wp
    d_ten = 0.0_wp
    load_scale = 0.0_wp
    n_sub = 0
    n_ref = 0
    ev_prev = 0
    ok = .TRUE.
    DO s = 1, NSTEP
      t = REAL(s, wp)*DT
      CALL sway(t, r0, C_SWAY, pos, vel, acc)
      CALL CD_AGG_Apply_LineControl(agg, [RATE*t], [RATE], es, em)
      IF (es == CD_AGG_OK) CALL CD_AGG_Step_Moving(agg, DT, pos, vel, acc, cv, st, ni, es, em)
      ok = ok .AND. es == CD_AGG_OK .AND. cv
      CALL CD_AGG_Get_Substep_Counts(agg, calls, ev_a, max_a, capped, fallbacks)
      sub = ev_a > ev_prev
      ev_prev = ev_a
      ! the reference: the step in NSUB plain steps (A must have sub-stepped it)
      IF (sub) THEN
        n_sub = n_sub + 1
        DO k = 1, NSUB
          t = (REAL(s - 1, wp) + REAL(k, wp)/REAL(NSUB, wp))*DT
          CALL sway(t, r0, C_SWAY, pos, vel, acc)
          ! a sub-step's rate is interpolated from the committed one as its length is (no effect
          ! on a Syrope segment, whose law takes the chord rate)
          rate_k = RATE
          IF (s == 1) rate_k = RATE*REAL(k, wp)/REAL(NSUB, wp)
          CALL CD_AGG_Apply_LineControl(ref, [RATE*t], [rate_k], es, em)
          IF (es == CD_AGG_OK) CALL CD_AGG_Step_Moving(ref, h, pos, vel, acc, cv, st, ni, es, em)
          ok = ok .AND. es == CD_AGG_OK .AND. cv
          n_ref = n_ref + 1
        END DO
      ELSE
        ok = .FALSE.
        em = 'the step was not sub-stepped'
      END IF
      IF (.NOT. ok) THEN
        CALL require(.FALSE., 'sub-steps: step at t = '//TRIM(fmt_real(t))//': '//TRIM(em))
        EXIT
      END IF
      CALL CD_AGG_CalcOutput(agg, es, em)
      CALL CD_AGG_CalcOutput(ref, es, em)
      CALL CD_AGG_GetMovingPointMesh(agg, pos, v2, a2, la, es, em)
      CALL CD_AGG_GetMovingPointMesh(ref, pos, v2, a2, lr, es, em)
      CALL CD_Get_System_Line_Syrope_State(agg%sys%fast%system, il, slow_a, tmax_a, es, em)
      CALL CD_Get_System_Line_Syrope_State(ref%sys%fast%system, il, slow_r, tmax_r, es, em)
      CALL CD_Get_System_Line_Tension(agg%sys%fast%system, il, ten_a, es, em)
      CALL CD_Get_System_Line_Tension(ref%sys%fast%system, il, ten_r, es, em)
      load_scale = MAX(load_scale, NORM2(lr(:, 1)))
      d_load = MAX(d_load, NORM2(la(:, 1) - lr(:, 1)))
      d_slow = MAX(d_slow, MAXVAL(ABS(slow_a - slow_r))/MAXVAL(slow_r))
      d_ten = MAX(d_ten, MAXVAL(ABS(ten_a - ten_r))/MAXVAL(ten_r))
    END DO
    IF (ok) THEN
      CALL CD_AGG_Get_Substep_Counts(ref, calls, ev_r, max_r, capped, fallbacks)
      PRINT '(A,I0,A,I0,A,I0,A,F7.4,A)', '  sub-steps: ', n_sub, ' of ', NSTEP, ' steps sub-stepped (at most ', &
        max_a, '), the segment paid out to ', agg%sys%fast%system%lines(il)%l0(ec) - agg%ctrl_base_l0(1), ' m'
      PRINT '(A,ES10.3,A,ES10.3,A,ES10.3)', '    against the plain reference steps: fairlead load / its peak ', &
        d_load/load_scale, ', tensions ', d_ten, ', slow strains ', d_slow
      CALL require(n_sub == NSTEP .AND. n_ref == NSUB*NSTEP .AND. max_a == NSUB .AND. ev_r == 0, &
                   'sub-steps: every step is solved in 4 sub-steps, the reference in none')
      CALL require(d_load <= 1.0e-10_wp*load_scale .AND. d_ten <= 1.0e-10_wp .AND. d_slow <= 1.0e-10_wp, &
                   'sub-steps: the sub-stepped length change is the plain steps'' at the sub-step times')
    END IF
    CALL CD_AGG_End(agg, es, em)
    CALL CD_AGG_End(ref, es, em)
  END SUBROUTINE case_substep_length_change

  SUBROUTINE sway(t_s, r0, c, p, v, a)
    !! The fairlead moving sideways as y = c t^3 from its static position r0 (at rest at t = 0;
    !! a cubic, which the C2 quintic of a sub-stepped step reproduces).
    REAL(wp), INTENT(IN) :: t_s, r0(3, 1), c
    REAL(wp), INTENT(OUT) :: p(3, 1), v(3, 1), a(3, 1)
    p = r0
    p(2, 1) = r0(2, 1) + c*t_s**3
    v = 0.0_wp
    v(2, 1) = 3.0_wp*c*t_s**2
    a = 0.0_wp
    a(2, 1) = 6.0_wp*c*t_s
  END SUBROUTINE sway

  ! ---------------------------------------------------------------------------------------------
  ! the OWC table, files and helpers
  ! ---------------------------------------------------------------------------------------------

  REAL(wp) FUNCTION owc_t(eps) RESULT(t)
    REAL(wp), INTENT(IN) :: eps
    t = lin(eps, OWC_EPS, OWC_TEN)
  END FUNCTION owc_t

  REAL(wp) FUNCTION owc_e(t) RESULT(eps)
    REAL(wp), INTENT(IN) :: t
    eps = lin(t, OWC_TEN, OWC_EPS)
  END FUNCTION owc_e

  REAL(wp) FUNCTION lin(x, xp, fp) RESULT(y)
    !! Piecewise-linear interpolation, constant beyond the ends.
    REAL(wp), INTENT(IN) :: x, xp(:), fp(:)
    INTEGER :: k, n
    n = SIZE(xp)
    y = fp(n)
    IF (x <= xp(1)) THEN
      y = fp(1)
      RETURN
    END IF
    DO k = 2, n
      IF (x <= xp(k)) THEN
        y = fp(k - 1) + (fp(k) - fp(k - 1))*(x - xp(k - 1))/(xp(k) - xp(k - 1))
        RETURN
      END IF
    END DO
  END FUNCTION lin

  SUBROUTINE write_owc(path)
    CHARACTER(*), INTENT(IN) :: path
    INTEGER :: u, k
    OPEN (NEWUNIT=u, FILE=path, STATUS='REPLACE', ACTION='WRITE')
    WRITE (u, '(A)') 'Strain      Tension'
    WRITE (u, '(A)') '(-)         (N)'
    DO k = 1, NOWC
      WRITE (u, '(ES14.6,1X,ES14.6)') OWC_EPS(k), OWC_TEN(k)
    END DO
    CLOSE (u)
  END SUBROUTINE write_owc

  SUBROUTINE write_settings(path, owc_path)
    CHARACTER(*), INTENT(IN) :: path, owc_path
    INTEGER :: u
    OPEN (NEWUNIT=u, FILE=path, STATUS='REPLACE', ACTION='WRITE')
    WRITE (u, '(A)') owc_path//'  OWC     - Original working-curve table file'
    WRITE (u, '(A)') 'LINEAR          WCType  - Working-curve formulation'
    WRITE (u, '(A)') '0.5             k1      - First working-curve shape parameter'
    WRITE (u, '(A)') '0.0             k2      - Second working-curve shape parameter'
    CLOSE (u)
  END SUBROUTINE write_settings

  SUBROUTINE write_deck(path, kind, no_force_blend, no_control, options)
    !! A Coupled fairlead at x = 0 and a Fixed anchor at mid-depth, the line written fairlead first
    !! (its only host-driven end at NodeA, the controlled end), with a CONTROL row on channel 1:
    !!   single: 100 m of polyester in 10 segments, the anchor 102 m away;
    !!   poly_chain: 80 m of polyester (8 segments) then 20 m of chain (2), 101.6 m;
    !!   chain_poly_chain: 10 m of chain, 80 m of polyester, 10 m of chain (1, 8, 1), 101.6 m.
    !! The polyester is nearly neutrally buoyant (0.05 kg/m above the displaced water's).
    !! no_force_blend writes False alpha_force_blend, no_control leaves the CONTROL section out,
    !! options are further OPTIONS rows.
    CHARACTER(*), INTENT(IN) :: path, kind
    LOGICAL, INTENT(IN), OPTIONAL :: no_force_blend, no_control
    CHARACTER(*), INTENT(IN), OPTIONAL :: options(:)
    LOGICAL :: ctrl
    INTEGER :: u, k
    OPEN (NEWUNIT=u, FILE=path, STATUS='REPLACE', ACTION='WRITE')
    WRITE (u, '(A)') 'Syrope line-control test deck ('//kind//')'
    WRITE (u, '(A)') '--- LINE TYPES ---'
    WRITE (u, '(A)') 'Name Diam Mass EA BA EI Cdn Cdt Can Cat'
    WRITE (u, '(A)') '(-) (m) (kg/m) (N) (-) (Nm2) (-) (-) (-) (-)'
    WRITE (u, '(A)') 'chain 0.2791 480.93 2.058e9 -1.0 0.0 1.37 0.64 1.0 0.0'
    WRITE (u, '(A)') 'poly 0.1438 16.70 "SYROPE:sctl_settings.dat|1.53e8|23.12" 1.0e6|1.0e5 0.0 1.2 0.2 1.0 0.0'
    WRITE (u, '(A)') '--- POINTS ---'
    WRITE (u, '(A)') 'ID Type X Y Z Mass Vol CdA Ca'
    WRITE (u, '(A)') '(-) (-) (m) (m) (m) (kg) (m3) (m2) (-)'
    WRITE (u, '(A)') '1 Coupled 0.0 0.0 -100.0 0 0 0 0'
    IF (kind == 'single') THEN
      WRITE (u, '(A)') '2 Fixed 102.0 0.0 -100.0 0 0 0 0'
    ELSE
      WRITE (u, '(A)') '2 Fixed 101.6 0.0 -100.0 0 0 0 0'
    END IF
    WRITE (u, '(A)') '--- LINES ---'
    WRITE (u, '(A)') 'ID NodeA NodeB Outputs'
    WRITE (u, '(A)') '(-) (-) (-) (-)'
    WRITE (u, '(A)') '1 1 2 -'
    WRITE (u, '(A)') '--- SECTIONS ---'
    WRITE (u, '(A)') 'LineID LineType Length NumSegs'
    WRITE (u, '(A)') '(-) (-) (m) (-)'
    SELECT CASE (kind)
    CASE ('single')
      WRITE (u, '(A)') '1 poly 100.0 10'
    CASE ('poly_chain')
      WRITE (u, '(A)') '1 poly 80.0 8'
      WRITE (u, '(A)') '1 chain 20.0 2'
    CASE DEFAULT
      WRITE (u, '(A)') '1 chain 10.0 1'
      WRITE (u, '(A)') '1 poly 80.0 8'
      WRITE (u, '(A)') '1 chain 10.0 1'
    END SELECT
    ctrl = .TRUE.
    IF (PRESENT(no_control)) ctrl = .NOT. no_control
    IF (ctrl) THEN
      WRITE (u, '(A)') '--- CONTROL ---'
      WRITE (u, '(A)') 'ChannelID Lines'
      WRITE (u, '(A)') '(-) (-)'
      WRITE (u, '(A)') '1 1'
    END IF
    WRITE (u, '(A)') '--- OPTIONS ---'
    WRITE (u, '(A)') '9.80665 g'
    WRITE (u, '(A)') '1025.0 rhoW'
    WRITE (u, '(A)') '200.0 WtrDpth'
    IF (PRESENT(no_force_blend)) THEN
      IF (no_force_blend) WRITE (u, '(A)') 'False alpha_force_blend'
    END IF
    IF (PRESENT(options)) THEN
      DO k = 1, SIZE(options)
        WRITE (u, '(A)') TRIM(options(k))
      END DO
    END IF
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

END PROGRAM test_syrope_control
