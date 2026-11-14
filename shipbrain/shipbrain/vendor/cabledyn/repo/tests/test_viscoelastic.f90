! File: tests/test_viscoelastic.f90
! SPDX-License-Identifier: Apache-2.0
! Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
PROGRAM test_viscoelastic
  !! Analytic gates for the MoorDyn four-parameter series-Kelvin element:
  !! parameter derivation and its fatal battery, FD-checked load Jacobians, the
  !! static-composite identity (series(EA_1, EA_D) = EA), the geometric
  !! relaxation closed form of the backward-Euler state, and load/advance
  !! consistency.
  USE CableDyn_Precision, ONLY: wp
  USE CableDyn_Viscoelastic, ONLY: CD_Viscoelastic_Params, CD_Viscoelastic_Element_Load, &
                                   CD_Viscoelastic_State_Advance, CD_Viscoelastic_LoadDependent_EAD, &
                                   CD_VISCO_OK
  USE CableDyn_Dynamic, ONLY: GenAlphaConfig
  USE CableDyn_Model, ONLY: CD_ModelType, CD_Init_Model, CD_Step_Model, CD_End_Model, CD_Copy_Model, &
                            CD_Get_Model_State, CD_Get_Model_Tension, CD_Update_Model_SegmentLength, &
                            CD_Model_Has_Viscoelastic, CD_Get_Model_VE_Dl1, CD_Set_Model_VE_Dl1, &
                            CD_MODEL_OK
  USE, INTRINSIC :: IEEE_ARITHMETIC, ONLY: IEEE_VALUE, IEEE_QUIET_NAN
  IMPLICIT NONE

  INTEGER :: nfail, evidence_unit, argument_status
  CHARACTER(512) :: evidence_path
  nfail = 0
  evidence_unit = -1
  evidence_path = ''
  CALL GET_COMMAND_ARGUMENT(1, evidence_path, STATUS=argument_status)
  IF (argument_status == 0 .AND. LEN_TRIM(evidence_path) > 0) THEN
    OPEN (NEWUNIT=evidence_unit, FILE=TRIM(evidence_path), STATUS='REPLACE', ACTION='WRITE')
    WRITE (evidence_unit, '(A)') &
      'time_s extension_m cabledyn_MN moordyn_MN difference_pct mbl_fraction'
  END IF

  CALL case_params()
  CALL case_static_composite()
  CALL case_relaxation_closed_form()
  CALL case_load_jacobians_fd()
  CALL case_load_advance_consistency()
  CALL case_slack_complementarity()
  CALL case_load_dependent_ead()
  CALL case_model_held_relaxation()
  CALL case_model_mode3()
  CALL case_md_viscoelastic_ab()
  CALL case_working_load_ramp()
  CALL case_model_copy_midstate()
  CALL case_model_fail_closed()
  CALL case_dl1_accessor_roundtrip()

  IF (evidence_unit /= -1) CLOSE (evidence_unit)

  IF (nfail > 0) THEN
    WRITE (*, '(A,I0,A)') 'FAIL: ', nfail, ' assertion(s) failed'
    ERROR STOP 1
  END IF
  WRITE (*, '(A)') 'PASS: CableDyn_Viscoelastic (series-Kelvin solid) vs analytic/FD'

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

  SUBROUTINE case_params()
    REAL(wp) :: ea_1
    INTEGER :: es
    CHARACTER(200) :: em
    ! the r-test rope: Es = 1.424e8, Ed = 1.586e8
    CALL CD_Viscoelastic_Params(1.424e8_wp, 1.586e8_wp, 4.0e9_wp, 11.0e6_wp, ea_1, es, em)
    CALL require(es == CD_VISCO_OK, 'params:ok')
    CALL require(ABS(ea_1 - 1.586e8_wp*1.424e8_wp/(1.586e8_wp - 1.424e8_wp)) <= 0.0_wp, 'params:ea1-formula')
    CALL CD_Viscoelastic_Params(1.424e8_wp, 1.424e8_wp, 1.0_wp, 1.0_wp, ea_1, es, em)
    CALL require(es /= CD_VISCO_OK, 'params:ead-equal-ea-fails')
    CALL CD_Viscoelastic_Params(1.424e8_wp, 1.0e8_wp, 1.0_wp, 1.0_wp, ea_1, es, em)
    CALL require(es /= CD_VISCO_OK, 'params:ead-below-ea-fails')
    CALL CD_Viscoelastic_Params(1.0e8_wp, 1.0001e8_wp, 1.0_wp, 1.0_wp, ea_1, es, em)
    CALL require(es /= CD_VISCO_OK, 'params:ill-conditioned-series-spring-fails')
    CALL CD_Viscoelastic_Params(1.424e8_wp, 1.586e8_wp, 0.0_wp, 0.0_wp, ea_1, es, em)
    CALL require(es /= CD_VISCO_OK, 'params:zero-damping-fails')
    CALL CD_Viscoelastic_Params(1.424e8_wp, 1.586e8_wp, -1.0_wp, 1.0_wp, ea_1, es, em)
    CALL require(es /= CD_VISCO_OK, 'params:negative-ba-fails')
  END SUBROUTINE case_params

  SUBROUTINE case_static_composite()
    !! At rest under a held stretch, the state relaxes to dl_1* with ld_1 = 0:
    !! EA_D*dl = (EA_D + EA_1)*dl_1*, and the tension EA_1*dl_1*/l0 equals the
    !! STATIC composite EA*dl/l0 -- the series identity the parameters encode.
    REAL(wp), PARAMETER :: EA = 100.0_wp, EAD = 400.0_wp, BA = 7.0_wp, BAD = 3.0_wp
    REAL(wp), PARAMETER :: L0 = 2.0_wp, DL = 0.05_wp
    REAL(wp) :: ea_1, dl1, dl1n, magt_inf
    INTEGER :: es, k
    CHARACTER(200) :: em
    REAL(wp) :: qa(3), qb(3), v0(3)
    CALL CD_Viscoelastic_Params(EA, EAD, BA, BAD, ea_1, es, em)
    CALL require(es == CD_VISCO_OK, 'static:params')
    qa = 0.0_wp
    qb = [L0 + DL, 0.0_wp, 0.0_wp]
    v0 = 0.0_wp
    dl1n = 0.0_wp
    DO k = 1, 4000
      CALL CD_Viscoelastic_State_Advance(qa, qb, v0, v0, L0, EAD, ea_1, BA, BAD, dl1n, 0.05_wp, dl1, es, em)
      dl1n = dl1
    END DO
    magt_inf = ea_1*dl1n/L0
    CALL require(ABS(magt_inf - EA*DL/L0) < 1.0e-10_wp, 'static:composite-tension-equals-EA')
    CALL require(ABS(dl1n - DL*EAD/(EAD + ea_1)) < 1.0e-12_wp, 'static:state-fixed-point')
  END SUBROUTINE case_static_composite

  SUBROUTINE case_relaxation_closed_form()
    !! With held kinematics the backward-Euler state is an exact geometric
    !! sequence toward the fixed point: dl_1^k = dl* + (dl_1^0 - dl*) r^k with
    !! r = 1/(1 + dt*(EA_D+EA_1)/B) and dl* the static fixed point.
    REAL(wp), PARAMETER :: EA = 100.0_wp, EAD = 400.0_wp, BA = 7.0_wp, BAD = 3.0_wp
    REAL(wp), PARAMETER :: L0 = 2.0_wp, DL = 0.05_wp, DT = 0.02_wp
    REAL(wp) :: ea_1, dl1, dl1n, r, dlstar, closed
    INTEGER :: es, k
    CHARACTER(200) :: em
    REAL(wp) :: qa(3), qb(3), v0(3)
    CALL CD_Viscoelastic_Params(EA, EAD, BA, BAD, ea_1, es, em)
    qa = 0.0_wp
    qb = [L0 + DL, 0.0_wp, 0.0_wp]
    v0 = 0.0_wp
    r = 1.0_wp/(1.0_wp + DT*(EAD + ea_1)/(BAD + BA))
    dlstar = DL*EAD/(EAD + ea_1)
    dl1n = 0.0_wp
    DO k = 1, 7
      CALL CD_Viscoelastic_State_Advance(qa, qb, v0, v0, L0, EAD, ea_1, BA, BAD, dl1n, DT, dl1, es, em)
      dl1n = dl1
    END DO
    closed = dlstar + (0.0_wp - dlstar)*r**7
    CALL require(ABS(dl1n - closed) < 1.0e-13_wp, 'relax:geometric-closed-form')
  END SUBROUTINE case_relaxation_closed_form

  SUBROUTINE case_load_jacobians_fd()
    !! Central-difference check of -dF/dq and -dF/dv on a stretched, moving,
    !! obliquely oriented element.
    REAL(wp), PARAMETER :: EA = 100.0_wp, EAD = 400.0_wp, BA = 7.0_wp, BAD = 3.0_wp
    REAL(wp), PARAMETER :: L0 = 1.0_wp, DT = 0.02_wp, H = 1.0e-7_wp
    REAL(wp) :: ea_1, qa(3), qb(3), va(3), vb(3)
    REAL(wp) :: f0(6), fp(6), fm(6), jq(6, 6), jv(6, 6), j0q(6, 6), j0v(6, 6)
    REAL(wp) :: x(12), err
    INTEGER :: es, i, j
    CHARACTER(200) :: em
    CALL CD_Viscoelastic_Params(EA, EAD, BA, BAD, ea_1, es, em)
    qa = [0.1_wp, -0.2_wp, 0.05_wp]
    qb = [0.9_wp, 0.5_wp, 0.6_wp]
    va = [0.02_wp, -0.01_wp, 0.03_wp]
    vb = [-0.04_wp, 0.05_wp, 0.01_wp]
    CALL CD_Viscoelastic_Element_Load(qa, qb, va, vb, L0, EAD, ea_1, BA, BAD, 0.01_wp, DT, &
                                      f0, j0q, j0v, es, em)
    CALL require(es == CD_VISCO_OK, 'fd:load-ok')
    ! q columns
    err = 0.0_wp
    DO j = 1, 6
      x(1:3) = qa; x(4:6) = qb
      x(j) = x(j) + H
      CALL CD_Viscoelastic_Element_Load(x(1:3), x(4:6), va, vb, L0, EAD, ea_1, BA, BAD, 0.01_wp, DT, &
                                        fp, jq, jv, es, em)
      x(j) = x(j) - 2.0_wp*H
      CALL CD_Viscoelastic_Element_Load(x(1:3), x(4:6), va, vb, L0, EAD, ea_1, BA, BAD, 0.01_wp, DT, &
                                        fm, jq, jv, es, em)
      DO i = 1, 6
        err = MAX(err, ABS(-(fp(i) - fm(i))/(2.0_wp*H) - j0q(i, j)))
      END DO
    END DO
    CALL require(err < 1.0e-4_wp, 'fd:jac-q')
    ! v columns
    err = 0.0_wp
    DO j = 1, 6
      x(1:3) = va; x(4:6) = vb
      x(j) = x(j) + H
      CALL CD_Viscoelastic_Element_Load(qa, qb, x(1:3), x(4:6), L0, EAD, ea_1, BA, BAD, 0.01_wp, DT, &
                                        fp, jq, jv, es, em)
      x(j) = x(j) - 2.0_wp*H
      CALL CD_Viscoelastic_Element_Load(qa, qb, x(1:3), x(4:6), L0, EAD, ea_1, BA, BAD, 0.01_wp, DT, &
                                        fm, jq, jv, es, em)
      DO i = 1, 6
        err = MAX(err, ABS(-(fp(i) - fm(i))/(2.0_wp*H) - j0v(i, j)))
      END DO
    END DO
    CALL require(err < 1.0e-4_wp, 'fd:jac-v')
  END SUBROUTINE case_load_jacobians_fd

  SUBROUTINE case_load_advance_consistency()
    !! The load's eliminated state equals the commit-time advance at the same
    !! kinematics -- the invariant the step commit relies on.
    REAL(wp), PARAMETER :: EA = 100.0_wp, EAD = 400.0_wp, BA = 7.0_wp, BAD = 3.0_wp
    REAL(wp) :: ea_1, qa(3), qb(3), va(3), vb(3)
    REAL(wp) :: f(6), jq(6, 6), jv(6, 6), dl1_load, dl1_adv
    INTEGER :: es
    CHARACTER(200) :: em
    CALL CD_Viscoelastic_Params(EA, EAD, BA, BAD, ea_1, es, em)
    qa = [0.0_wp, 0.0_wp, 0.0_wp]
    qb = [1.06_wp, 0.0_wp, 0.0_wp]
    va = 0.0_wp
    vb = [0.3_wp, 0.0_wp, 0.0_wp]
    CALL CD_Viscoelastic_Element_Load(qa, qb, va, vb, 1.0_wp, EAD, ea_1, BA, BAD, 0.02_wp, 0.01_wp, &
                                      f, jq, jv, es, em, dl_1_out=dl1_load)
    CALL CD_Viscoelastic_State_Advance(qa, qb, va, vb, 1.0_wp, EAD, ea_1, BA, BAD, 0.02_wp, 0.01_wp, &
                                       dl1_adv, es, em)
    CALL require(ABS(dl1_load - dl1_adv) <= 0.0_wp, 'consistency:load-equals-advance-bitwise')
  END SUBROUTINE case_load_advance_consistency

  SUBROUTINE case_slack_complementarity()
    !! Tension-only series chain: shortening a segment that still remembers a slow-branch
    !! stretch (dl_1 > 0) through slack must never produce a compressive tension, and the
    !! tension and eliminated state must stay CONTINUOUS across the taut/slack switch
    !! (MoorDyn's dl >= 0 clamp of the spring part alone jumps there and stalls Newton).
    !! Slack relaxes the slow branch under zero load, BA*ld_1 + EA_1*dl_1 = 0, and the
    !! load and commit-time advance agree bitwise on both sides; the Jacobians match
    !! central differences away from the kink.
    REAL(wp), PARAMETER :: EA = 100.0_wp, EAD = 400.0_wp, BA = 7.0_wp, BAD = 3.0_wp
    REAL(wp), PARAMETER :: L0 = 1.0_wp, DT = 0.02_wp, DL1N = 0.03_wp, H = 1.0e-7_wp
    REAL(wp) :: ea_1, qa(3), qb(3), va(3), vb(3), f(6), jq(6, 6), jv(6, 6), fp(6), fm(6)
    REAL(wp) :: jq2(6, 6), jv2(6, 6)
    REAL(wp) :: len, lo, hi, t_lo, t_hi, dl1_lo, dl1_hi, ten, dl1_load, dl1_adv, err, tmin, x(6)
    INTEGER :: es, k, i, j
    CHARACTER(200) :: em
    CALL CD_Viscoelastic_Params(EA, EAD, BA, BAD, ea_1, es, em)
    qa = 0.0_wp
    va = 0.0_wp
    vb = [-0.05_wp, 0.0_wp, 0.0_wp]
    ! sweep from taut to slack: tension never negative
    tmin = HUGE(1.0_wp)
    DO k = 0, 400
      len = 1.02_wp - 0.05_wp*REAL(k, wp)/400.0_wp
      qb = [len, 0.0_wp, 0.0_wp]
      CALL CD_Viscoelastic_Element_Load(qa, qb, va, vb, L0, EAD, ea_1, BA, BAD, DL1N, DT, f, jq, jv, es, em)
      tmin = MIN(tmin, f(1))
    END DO
    CALL require(es == CD_VISCO_OK, 'slack:load-ok')
    CALL require(tmin >= 0.0_wp, 'slack:no-compressive-tension')
    ! bisect the switch and require continuity of tension and state across it
    lo = 0.97_wp
    hi = 1.02_wp
    DO k = 1, 200
      len = 0.5_wp*(lo + hi)
      qb = [len, 0.0_wp, 0.0_wp]
      CALL CD_Viscoelastic_Element_Load(qa, qb, va, vb, L0, EAD, ea_1, BA, BAD, DL1N, DT, f, jq, jv, es, em)
      IF (f(1) > 0.0_wp) THEN
        hi = len
      ELSE
        lo = len
      END IF
    END DO
    qb = [lo - 1.0e-9_wp, 0.0_wp, 0.0_wp]
    CALL CD_Viscoelastic_Element_Load(qa, qb, va, vb, L0, EAD, ea_1, BA, BAD, DL1N, DT, f, jq, jv, es, em, &
                                      dl_1_out=dl1_lo)
    t_lo = f(1)
    qb = [hi + 1.0e-9_wp, 0.0_wp, 0.0_wp]
    CALL CD_Viscoelastic_Element_Load(qa, qb, va, vb, L0, EAD, ea_1, BA, BAD, DL1N, DT, f, jq, jv, es, em, &
                                      dl_1_out=dl1_hi)
    t_hi = f(1)
    CALL require(ABS(t_hi - t_lo) < 1.0e-5_wp, 'slack:tension-continuous-at-switch')
    CALL require(ABS(dl1_hi - dl1_lo) < 1.0e-9_wp, 'slack:state-continuous-at-switch')
    ! a clearly slack segment: zero force, zero Jacobians, zero-load relaxation, load == advance
    qb = [0.98_wp, 0.0_wp, 0.0_wp]
    CALL CD_Viscoelastic_Element_Load(qa, qb, va, vb, L0, EAD, ea_1, BA, BAD, DL1N, DT, f, jq, jv, es, em, &
                                      dl_1_out=dl1_load)
    CALL CD_Viscoelastic_State_Advance(qa, qb, va, vb, L0, EAD, ea_1, BA, BAD, DL1N, DT, dl1_adv, es, em)
    CALL require(nan_max_abs(f) <= 0.0_wp .AND. nan_max_abs(jq) <= 0.0_wp .AND. nan_max_abs(jv) <= 0.0_wp, &
                 'slack:zero-force-and-jacobians')
    CALL require(ABS(dl1_load - BA*DL1N/(BA + DT*ea_1)) < 1.0e-15_wp, 'slack:zero-load-relaxation')
    CALL require(ABS(dl1_load - dl1_adv) <= 0.0_wp, 'slack:load-equals-advance-bitwise')
    ! the instantaneous (dt = 0) query of a slack segment reports zero tension, never compression
    CALL CD_Viscoelastic_Element_Load(qa, qb, va, vb, L0, EAD, ea_1, BA, BAD, -0.01_wp, 0.0_wp, f, jq, jv, es, em)
    ten = f(1)
    CALL require(es == CD_VISCO_OK .AND. ten >= 0.0_wp, 'slack:instantaneous-query-tension-only')
    ! taut side just above the switch: the Jacobian still matches central differences
    qb = [hi + 1.0e-3_wp, 0.01_wp, -0.02_wp]
    CALL CD_Viscoelastic_Element_Load(qa, qb, va, vb, L0, EAD, ea_1, BA, BAD, DL1N, DT, f, jq, jv, es, em)
    err = 0.0_wp
    DO j = 4, 6
      x = [qa, qb]
      x(j) = x(j) + H
      CALL CD_Viscoelastic_Element_Load(x(1:3), x(4:6), va, vb, L0, EAD, ea_1, BA, BAD, DL1N, DT, fp, &
                                        jq2, jv2, es, em)
      x(j) = x(j) - 2.0_wp*H
      CALL CD_Viscoelastic_Element_Load(x(1:3), x(4:6), va, vb, L0, EAD, ea_1, BA, BAD, DL1N, DT, fm, &
                                        jq2, jv2, es, em)
      DO i = 1, 6
        err = MAX(err, ABS(-(fp(i) - fm(i))/(2.0_wp*H) - jq(i, j)))
      END DO
    END DO
    CALL require(err < 1.0e-4_wp, 'slack:taut-side-fd-jacobian')
  END SUBROUTINE case_slack_complementarity

  SUBROUTINE case_load_dependent_ead()
    !! MoorDyn's ElasticMod-3 mean-load-dependent dynamic stiffness: the
    !! dl_1 <= 0 branch returns alphaMBL, the positive branch matches the
    !! closed-form expression at a hand-checked point (the md_viscoelastic
    !! r-test rope at unit stretch), and a violated premise fails closed.
    REAL(wp), PARAMETER :: EA = 1.424e8_wp, AMBL = 1.586e8_wp, VB = 0.4_wp, L0 = 1.0_wp
    REAL(wp) :: ea_d, k, disc, expect
    INTEGER :: es
    CHARACTER(200) :: em
    CALL CD_Viscoelastic_LoadDependent_EAD(EA, L0, AMBL, VB, -0.1_wp, ea_d, es, em)
    CALL require(es == CD_VISCO_OK .AND. ABS(ea_d - AMBL) <= 0.0_wp, 'ead3:nonpositive-branch-alphambl')
    CALL CD_Viscoelastic_LoadDependent_EAD(EA, L0, AMBL, VB, 1.0_wp, ea_d, es, em)
    k = EA/L0
    disc = AMBL*AMBL + 2.0_wp*AMBL*k*(VB*1.0_wp - L0) + (k*(VB*1.0_wp + L0))**2
    expect = 0.5_wp*(AMBL + VB*1.0_wp*k + EA + SQRT(disc))
    CALL require(es == CD_VISCO_OK .AND. ABS(ea_d - expect) <= 0.0_wp .AND. ea_d > EA, &
                 'ead3:positive-branch-closed-form')
    ! premise violation: alphaMBL at or below EA with zero mean load
    CALL CD_Viscoelastic_LoadDependent_EAD(EA, L0, 1.0e8_wp, VB, 0.0_wp, ea_d, es, em)
    CALL require(es /= CD_VISCO_OK, 'ead3:premise-violation-fails')
  END SUBROUTINE case_load_dependent_ead

  SUBROUTINE case_model_mode3()
    !! The mode-3 (load-dependent) rope at the md_viscoelastic r-test scale:
    !! the self-consistent steady-partition IC reports EXACTLY the static
    !! composite EA*dl/l0 and holds it under fixed ends, and a pull-out
    !! relaxes along the lagged recursion (replicated here through the same
    !! public EA_D formula the module gates pin).
    REAL(wp), PARAMETER :: EA = 1.424e8_wp, AMBL = 1.586e8_wp, VB = 0.4_wp
    REAL(wp), PARAMETER :: BAS = 4.0e9_wp, BAD = 11.0e6_wp
    REAL(wp), PARAMETER :: L0E = 1.0_wp, DL = 1.0_wp, DT = 0.01_wp
    TYPE(CD_ModelType) :: model
    TYPE(GenAlphaConfig) :: cfg
    INTEGER :: conn(2, 2), fixed(6), es, k, n_iter
    REAL(wp) :: l0(2), eav(2), rho_a(2), q0(9), v0(9), f_ext(9)
    REAL(wp) :: ve_ead(2), ve_ba(2), ve_bad2(2), ve_ambl(2), ve_vbet(2)
    REAL(wp) :: qp(9), vp(9), ap(9), tension(2)
    REAL(wp) :: dl1k, ead_k, ea1_k, dl_b, den, bsum, expect, ld1k
    CHARACTER(200) :: em
    LOGICAL :: conv, stalled
    conn(:, 1) = [1, 2]
    conn(:, 2) = [2, 3]
    l0 = L0E
    eav = EA
    rho_a = 22.42_wp
    q0 = 0.0_wp
    q0(4) = L0E + DL
    q0(7) = 2.0_wp*(L0E + DL)
    v0 = 0.0_wp
    f_ext = 0.0_wp
    fixed = [1, 2, 3, 7, 8, 9]
    ve_ead = 0.0_wp
    ve_ba = BAS
    ve_bad2 = BAD
    ve_ambl = AMBL
    ve_vbet = VB
    CALL CD_Init_Model(model, q0, v0, conn, l0, eav, rho_a, .FALSE., f_ext, fixed, cfg, es, em, &
                       ve_ea_d=ve_ead, ve_ba=ve_ba, ve_ba_d=ve_bad2, &
                       ve_alpha_mbl=ve_ambl, ve_vbeta=ve_vbet)
    CALL require(es == CD_MODEL_OK, 'mode3:init')
    CALL CD_Get_Model_Tension(model, tension, es, em)
    CALL require(es == CD_MODEL_OK .AND. &
                 ABS(tension(1) - EA*DL/L0E) <= 1.0e-9_wp*EA, 'mode3:ic-is-static-composite')
    ! held: fixed point (to round-off)
    expect = tension(1)
    CALL CD_Get_Model_State(model, qp, vp, ap, es, em)
    vp = 0.0_wp
    ap = 0.0_wp
    DO k = 1, 5
      CALL CD_Step_Model(model, DT, conv, stalled, n_iter, es, em, &
                         prescribed_q=qp, prescribed_v=vp, prescribed_a=ap)
      CALL require(es == CD_MODEL_OK .AND. conv, 'mode3:held-step')
    END DO
    CALL CD_Get_Model_Tension(model, tension, es, em)
    CALL require(ABS(tension(1) - expect) <= 1.0e-11_wp*ABS(expect), 'mode3:held-tension-constant')
    ! pull-out by 0.05 per element: relax along the lagged recursion
    qp(1) = -0.05_wp
    qp(7) = 2.0_wp*(L0E + DL) + 0.05_wp
    dl_b = (L0E + DL) - (-0.05_wp) - L0E
    ! seed the replicated state from the model's own reported tension at the
    ! held fixed point (dl_1 = T*l0/EA_1 with EA_1 from EA_D at that state):
    ! at the steady partition T = EA*DL/l0, so dl_1 = DL*(EA_D-EA)/EA_D with
    ! EA_D self-consistent -- iterate exactly like the model init
    dl1k = DL
    DO k = 1, 200
      CALL CD_Viscoelastic_LoadDependent_EAD(EA, L0E, AMBL, VB, dl1k, ead_k, es, em)
      dl1k = DL*(ead_k - EA)/ead_k
    END DO
    bsum = BAS + BAD
    DO k = 1, 8
      ! the lagged recursion the model commits: EA_D at the committed dl_1
      CALL CD_Viscoelastic_LoadDependent_EAD(EA, L0E, AMBL, VB, dl1k, ead_k, es, em)
      CALL require(es == CD_VISCO_OK, 'mode3:recursion-ead')
      ea1_k = ead_k*EA/(ead_k - EA)
      den = 1.0_wp + DT*(ead_k + ea1_k)/bsum
      dl1k = (dl1k + DT*(ead_k*dl_b)/bsum)/den
      CALL CD_Step_Model(model, DT, conv, stalled, n_iter, es, em, &
                         prescribed_q=qp, prescribed_v=vp, prescribed_a=ap)
      ! same degenerate-rig verdict as the mode-2 case: the true residual is
      ! zero by symmetry, so a noise-level r0 may report stalled
      CALL require(es == CD_MODEL_OK .AND. (conv .OR. stalled), 'mode3:pullout-step')
      ! reported tension: coefficients re-lagged at the NEW committed dl_1
      CALL CD_Viscoelastic_LoadDependent_EAD(EA, L0E, AMBL, VB, dl1k, ead_k, es, em)
      ea1_k = ead_k*EA/(ead_k - EA)
      ld1k = (ead_k*dl_b - (ead_k + ea1_k)*dl1k)/bsum
      expect = ea1_k*dl1k/L0E + BAS*ld1k/L0E
      CALL CD_Get_Model_Tension(model, tension, es, em)
      CALL require(ABS(tension(1) - expect) <= 1.0e-9_wp*MAX(ABS(expect), 1.0_wp), &
                   'mode3:per-step-tension-lagged-recursion')
    END DO
    CALL CD_End_Model(model, es, em)
  END SUBROUTINE case_model_mode3

  SUBROUTINE build_held_model(model, ea, ead, ba_s, ba_d, l0e, dl, cfg, es, em)
    !! A 3-node colinear line along x with both END nodes held and the midpoint
    !! free, every element stretched by the same dl: by symmetry the SLS forces
    !! on the free node cancel BITWISE, so zero motion is an exact fixed point
    !! of the step and each element's dl_1 follows the held-kinematics backward-
    !! Euler sequence in closed form.
    TYPE(CD_ModelType), INTENT(INOUT) :: model
    REAL(wp), INTENT(IN) :: ea, ead, ba_s, ba_d, l0e, dl
    TYPE(GenAlphaConfig), INTENT(IN) :: cfg
    INTEGER, INTENT(OUT) :: es
    CHARACTER(*), INTENT(OUT) :: em
    INTEGER :: conn(2, 2), fixed(6)
    REAL(wp) :: l0(2), eav(2), rho_a(2), q0(9), v0(9), f_ext(9)
    REAL(wp) :: ve_ead(2), ve_ba(2), ve_bad(2)
    conn(:, 1) = [1, 2]
    conn(:, 2) = [2, 3]
    l0 = l0e
    eav = ea
    rho_a = 1.0_wp
    q0 = 0.0_wp
    q0(4) = l0e + dl
    q0(7) = 2.0_wp*(l0e + dl)
    v0 = 0.0_wp
    f_ext = 0.0_wp
    fixed = [1, 2, 3, 7, 8, 9]
    ve_ead = ead
    ve_ba = ba_s
    ve_bad = ba_d
    CALL CD_Init_Model(model, q0, v0, conn, l0, eav, rho_a, .FALSE., f_ext, fixed, cfg, es, em, &
                       ve_ea_d=ve_ead, ve_ba=ve_ba, ve_ba_d=ve_bad)
  END SUBROUTINE build_held_model

  SUBROUTINE case_model_held_relaxation()
    !! End-to-end model gate: the steady-partition IC makes the static
    !! equilibrium the EXACT dynamic fixed point (tension = EA*dl/l0 at t = 0
    !! and unchanged under held ends); a sudden symmetric end pull-out then
    !! relaxes dl_1 along the geometric closed form of the committed backward-
    !! Euler sequence, and the long run settles on the new static composite.
    REAL(wp), PARAMETER :: EA = 100.0_wp, EAD = 400.0_wp, BAS = 7.0_wp, BAD = 3.0_wp
    REAL(wp), PARAMETER :: L0E = 1.0_wp, DL = 0.02_wp, DL2 = 0.05_wp, DT = 0.05_wp
    TYPE(CD_ModelType) :: model
    TYPE(GenAlphaConfig) :: cfg
    REAL(wp) :: q(9), v(9), a(9), qp(9), vp(9), ap(9), tension(2)
    REAL(wp) :: ea_1, r, dlstar2, dl1k, ld1k, expect, dl_a, dl_b
    INTEGER :: es, k, n_iter
    CHARACTER(200) :: em
    LOGICAL :: conv, stalled
    CALL build_held_model(model, EA, EAD, BAS, BAD, L0E, DL, cfg, es, em)
    CALL require(es == CD_MODEL_OK, 'model:init')
    ea_1 = EAD*EA/(EAD - EA)
    ! the exact stretches the model computed from its q0 (floating point of
    ! (l0 + dl) - l0 differs from dl in the last bits)
    dl_a = (L0E + DL) - L0E
    CALL CD_Get_Model_Tension(model, tension, es, em)
    CALL require(es == CD_MODEL_OK, 'model:tension-at-ic')
    expect = EA*dl_a/L0E
    CALL require(ABS(tension(1) - expect) <= 1.0e-12_wp*ABS(expect), 'model:ic-is-static-composite')
    ! held ends: the steady partition is the fixed point of the committed
    ! advance (to round-off -- the floating-point map re-derives it through a
    ! division chain, so exact bitwise constancy is not guaranteed)
    expect = tension(1)
    CALL CD_Get_Model_State(model, qp, vp, ap, es, em)
    vp = 0.0_wp
    ap = 0.0_wp
    DO k = 1, 3
      CALL CD_Step_Model(model, DT, conv, stalled, n_iter, es, em, &
                         prescribed_q=qp, prescribed_v=vp, prescribed_a=ap)
      CALL require(es == CD_MODEL_OK .AND. conv, 'model:held-step-converged')
    END DO
    CALL CD_Get_Model_Tension(model, tension, es, em)
    CALL require(ABS(tension(1) - expect) <= 1.0e-12_wp*ABS(expect), 'model:held-tension-constant')
    CALL CD_Get_Model_State(model, q, v, a, es, em)
    CALL require(ABS(q(4) - (L0E + DL)) <= 0.0_wp .AND. nan_max_abs(v) <= 0.0_wp, &
                 'model:held-fixed-point-exact')
    ! sudden symmetric pull-out: both ends move (DL2 - DL) outward, the free
    ! midpoint stays put by symmetry, and each element's stretch becomes DL2
    qp(1) = -(DL2 - DL)
    qp(7) = 2.0_wp*(L0E + DL) + (DL2 - DL)
    dl_b = (L0E + DL) - (-(DL2 - DL)) - L0E
    dl1k = dl_a*(EAD - EA)/EAD
    r = 1.0_wp/(1.0_wp + DT*(EAD + ea_1)/(BAD + BAS))
    dlstar2 = dl_b*EAD/(EAD + ea_1)
    DO k = 1, 12
      CALL CD_Step_Model(model, DT, conv, stalled, n_iter, es, em, &
                         prescribed_q=qp, prescribed_v=vp, prescribed_a=ap)
      ! this rig's true residual is ZERO by symmetry, so what the solver sees
      ! is pure round-off (the pulled geometry leaves the two stretches an ulp
      ! apart); a noise-level r0 cannot shrink relative to itself, so the step
      ! legitimately reports stalled while committing the correct state --
      ! accept either verdict and gate the STATE below
      CALL require(es == CD_MODEL_OK .AND. (conv .OR. stalled), 'model:step-committed')
      dl1k = dlstar2 + (dl1k - dlstar2)*r
      ld1k = (EAD*dl_b - (EAD + ea_1)*dl1k)/(BAD + BAS)
      CALL CD_Get_Model_Tension(model, tension, es, em)
      expect = ea_1*dl1k/L0E + BAS*ld1k/L0E
      CALL require(ABS(tension(1) - expect) <= 1.0e-11_wp*MAX(ABS(expect), 1.0_wp), &
                   'model:per-step-tension-closed-form')
      CALL require(ABS(tension(2) - tension(1)) <= 1.0e-12_wp*MAX(ABS(tension(1)), 1.0_wp), &
                   'model:symmetry')
    END DO
    ! the free midpoint never moved through the pull (forces cancel to the
    ! noise floor and the committed increment stays zero)
    CALL CD_Get_Model_State(model, q, v, a, es, em)
    CALL require(ABS(q(4) - (L0E + DL)) <= 0.0_wp, 'model:midpoint-pinned-through-pull')
    ! long run: the composite relaxes to the NEW static stiffness point
    DO k = 1, 300
      CALL CD_Step_Model(model, DT, conv, stalled, n_iter, es, em, &
                         prescribed_q=qp, prescribed_v=vp, prescribed_a=ap)
    END DO
    CALL CD_Get_Model_Tension(model, tension, es, em)
    CALL require(ABS(tension(1) - EA*dl_b/L0E) <= 1.0e-10_wp, 'model:relaxes-to-static-composite')
    CALL CD_End_Model(model, es, em)
  END SUBROUTINE case_model_held_relaxation

  SUBROUTINE case_md_viscoelastic_ab()
    !! A/B against MoorDyn's shipped md_viscoelastic r-test (driver.MD.out,
    !! MoorDyn v2.3.8): the zero-gravity ElasticMod-3 polyester rope
    !! (Es = 1.424e8 | alphaMBL = 1.586e8 | vbeta = 0.4, BA = 4e9 | 11e6,
    !! UnstrLen 1 m) stretched to 2 m and ramped at 0.05 m/s for 200 s at
    !! dt = 0.01. CableDyn meshes it as two 0.5 m elements with a free
    !! midpoint (the SLS is segment-scale-invariant, including the mode-3
    !! stiffness); zero f_ext IS the zero-gravity environment. The reference
    !! fairlead tension rides 12-21% ABOVE the static-composite line over the
    !! ramp -- the load-dependent dynamic-stiffness signal this gate scores.
    !! Tolerance 2%: covers MoorDyn's explicit-RK2-vs-implicit-lagged
    !! discretization gap and the reference's own ~0.1-0.3% motion-protocol
    !! lag (its NBPX trails the commanded ramp by up to ~0.02 m).
    REAL(wp), PARAMETER :: EA = 1.424e8_wp, AMBL = 1.586e8_wp, VB = 0.4_wp
    REAL(wp), PARAMETER :: BAS = 4.0e9_wp, BAD = 11.0e6_wp
    ! dt = 0.05 (5x the reference's 0.01): the implicit lagged elimination
    ! holds the 2% band at the coarser step -- the dt-advantage measured in
    ! the gate itself
    REAL(wp), PARAMETER :: DT = 0.05_wp, VRAMP = 0.05_wp
    INTEGER, PARAMETER :: NSAMP = 5
    REAL(wp), PARAMETER :: t_ref(NSAMP) = [1.0_wp, 10.0_wp, 50.0_wp, 100.0_wp, 199.95_wp]
    REAL(wp), PARAMETER :: f_ref(NSAMP) = [1.5359515e8_wp, 2.4006040e8_wp, 5.9046880e8_wp, &
                                           9.9594842e8_wp, 1.7229408e9_wp]
    TYPE(CD_ModelType) :: model
    TYPE(GenAlphaConfig) :: cfg
    INTEGER :: conn(2, 2), fixed(6), es, k, n_iter, isamp, nstep
    REAL(wp) :: l0(2), eav(2), rho_a(2), q0(9), v0(9), f_ext(9)
    REAL(wp) :: ve_ead(2), ve_ba(2), ve_bad2(2), ve_ambl(2), ve_vbet(2)
    REAL(wp) :: qp(9), vp(9), ap(9), tension(2), t, x_end, relerr
    CHARACTER(200) :: em
    LOGICAL :: conv, stalled
    conn(:, 1) = [1, 2]
    conn(:, 2) = [2, 3]
    l0 = 0.5_wp
    eav = EA
    rho_a = 22.42_wp
    q0 = 0.0_wp
    q0(4) = 1.0_wp
    q0(7) = 2.0_wp
    v0 = 0.0_wp
    v0(4) = 0.5_wp*VRAMP
    v0(7) = VRAMP
    f_ext = 0.0_wp
    fixed = [1, 2, 3, 7, 8, 9]
    ve_ead = 0.0_wp
    ve_ba = BAS
    ve_bad2 = BAD
    ve_ambl = AMBL
    ve_vbet = VB
    CALL CD_Init_Model(model, q0, v0, conn, l0, eav, rho_a, .FALSE., f_ext, fixed, cfg, es, em, &
                       ve_ea_d=ve_ead, ve_ba=ve_ba, ve_ba_d=ve_bad2, &
                       ve_alpha_mbl=ve_ambl, ve_vbeta=ve_vbet)
    CALL require(es == CD_MODEL_OK, 'ab:init')
    qp = q0
    vp = v0
    ap = 0.0_wp
    isamp = 1
    nstep = NINT(200.0_wp/DT)
    DO k = 1, nstep
      t = k*DT
      x_end = 2.0_wp + VRAMP*t
      qp(7) = x_end
      qp(4) = 0.5_wp*x_end
      CALL CD_Step_Model(model, DT, conv, stalled, n_iter, es, em, &
                         prescribed_q=qp, prescribed_v=vp, prescribed_a=ap)
      IF (es /= CD_MODEL_OK) EXIT
      IF (isamp <= NSAMP) THEN
        IF (ABS(t - t_ref(isamp)) < 0.5_wp*DT) THEN
          CALL CD_Get_Model_Tension(model, tension, es, em)
          relerr = ABS(tension(2) - f_ref(isamp))/f_ref(isamp)
          WRITE (*, '(A,F8.2,A,ES14.7,A,ES14.7,A,F7.4,A)') 'md_viscoelastic A/B t=', t, &
            '  CableDyn ', tension(2), '  MoorDyn ', f_ref(isamp), '  relerr ', 100.0_wp*relerr, ' %'
          CALL require(es == CD_MODEL_OK .AND. relerr <= 0.02_wp, 'ab:fairlead-tension-vs-moordyn')
          isamp = isamp + 1
        END IF
      END IF
    END DO
    CALL require(es == CD_MODEL_OK, 'ab:ran-to-tmax')
    CALL require(isamp == NSAMP + 1, 'ab:all-samples-scored')
    CALL CD_End_Model(model, es, em)
  END SUBROUTINE case_md_viscoelastic_ab

  SUBROUTINE case_working_load_ramp()
    !! A separate engineering-range comparison using the same MoorDyn-F
    !! ElasticMod-3 parameters. The one-metre rope starts from rest and follows
    !! a quintic ramp to 0.3 MBL over 100 s. This avoids interpreting the legacy
    !! 100 per cent strain regression as a physical polyester qualification.
    REAL(wp), PARAMETER :: EA = 1.424e8_wp, AMBL = 1.586e8_wp, VB = 0.4_wp
    REAL(wp), PARAMETER :: BAS = 4.0e9_wp, BAD = 11.0e6_wp, MBL = 10.2e6_wp
    REAL(wp), PARAMETER :: DT = 0.01_wp, TEND = 100.0_wp
    REAL(wp), PARAMETER :: EXTEND = 0.3_wp*MBL/EA
    INTEGER, PARAMETER :: NSAMP = 5
    REAL(wp), PARAMETER :: t_ref(NSAMP) = [20.0_wp, 40.0_wp, 60.0_wp, 80.0_wp, 99.99_wp]
    REAL(wp), PARAMETER :: f_ref(NSAMP) = [0.18417673e6_wp, 0.9895720e6_wp, 2.1093455e6_wp, &
                                           2.8937858e6_wp, 3.0604411e6_wp]
    TYPE(CD_ModelType) :: model
    TYPE(GenAlphaConfig) :: cfg
    INTEGER :: conn(2, 2), fixed(6), es, k, n_iter, isamp, nstep
    REAL(wp) :: l0(2), eav(2), rho_a(2), q0(9), v0(9), f_ext(9)
    REAL(wp) :: ve_ead(2), ve_ba(2), ve_bad2(2), ve_ambl(2), ve_vbet(2)
    REAL(wp) :: qp(9), vp(9), ap(9), tension(2), t, x, shape, shape_d, shape_dd
    REAL(wp) :: extension, velocity, acceleration, relerr
    CHARACTER(200) :: em
    LOGICAL :: conv, stalled

    conn(:, 1) = [1, 2]
    conn(:, 2) = [2, 3]
    l0 = 0.5_wp
    eav = EA
    rho_a = 22.42_wp
    q0 = 0.0_wp
    q0(4) = 0.5_wp
    q0(7) = 1.0_wp
    v0 = 0.0_wp
    f_ext = 0.0_wp
    fixed = [1, 2, 3, 7, 8, 9]
    ve_ead = 0.0_wp
    ve_ba = BAS
    ve_bad2 = BAD
    ve_ambl = AMBL
    ve_vbet = VB
    CALL CD_Init_Model(model, q0, v0, conn, l0, eav, rho_a, .FALSE., f_ext, fixed, cfg, es, em, &
                       ve_ea_d=ve_ead, ve_ba=ve_ba, ve_ba_d=ve_bad2, &
                       ve_alpha_mbl=ve_ambl, ve_vbeta=ve_vbet)
    CALL require(es == CD_MODEL_OK, 'working-ramp:init')
    qp = q0
    vp = 0.0_wp
    ap = 0.0_wp
    isamp = 1
    nstep = NINT(TEND/DT)
    DO k = 1, nstep
      t = k*DT
      x = MIN(1.0_wp, t/TEND)
      shape = x**3*(10.0_wp - 15.0_wp*x + 6.0_wp*x*x)
      shape_d = (30.0_wp*x*x - 60.0_wp*x**3 + 30.0_wp*x**4)/TEND
      shape_dd = (60.0_wp*x - 180.0_wp*x*x + 120.0_wp*x**3)/(TEND*TEND)
      extension = EXTEND*shape
      velocity = EXTEND*shape_d
      acceleration = EXTEND*shape_dd
      qp(4) = 0.5_wp*(1.0_wp + extension)
      qp(7) = 1.0_wp + extension
      vp(4) = 0.5_wp*velocity
      vp(7) = velocity
      ap(4) = 0.5_wp*acceleration
      ap(7) = acceleration
      CALL CD_Step_Model(model, DT, conv, stalled, n_iter, es, em, &
                         prescribed_q=qp, prescribed_v=vp, prescribed_a=ap)
      IF (es /= CD_MODEL_OK) EXIT
      IF (isamp <= NSAMP) THEN
        IF (ABS(t - t_ref(isamp)) < 0.5_wp*DT) THEN
          CALL CD_Get_Model_Tension(model, tension, es, em)
          relerr = ABS(tension(2) - f_ref(isamp))/MAX(f_ref(isamp), 1.0_wp)
          WRITE (*, '(A,F7.2,A,F9.5,A,F9.5,A,F7.4,A)') 'working-load ramp t=', t, &
            '  CableDyn ', tension(2)*1.0e-6_wp, ' MN  MoorDyn-F ', f_ref(isamp)*1.0e-6_wp, &
            ' MN  relerr ', 100.0_wp*relerr, ' %'
          CALL require(es == CD_MODEL_OK .AND. relerr <= 0.01_wp, &
                       'working-ramp:fairlead-tension-vs-moordyn')
          IF (evidence_unit /= -1) THEN
            WRITE (evidence_unit, '(F0.2,1X,ES16.8,1X,F0.8,1X,F0.8,1X,F0.8,1X,F0.8)') &
              t, extension, tension(2)*1.0e-6_wp, f_ref(isamp)*1.0e-6_wp, &
              100.0_wp*relerr, f_ref(isamp)/MBL
          END IF
          isamp = isamp + 1
        END IF
      END IF
    END DO
    CALL require(es == CD_MODEL_OK, 'working-ramp:ran-to-tmax')
    CALL require(isamp == NSAMP + 1, 'working-ramp:all-samples-scored')
    CALL CD_End_Model(model, es, em)
  END SUBROUTINE case_working_load_ramp

  SUBROUTINE case_model_copy_midstate()
    !! CD_Copy_Model carries the committed dl_1 mid-relaxation: the copy and the
    !! original report bitwise-identical tensions on every subsequent step.
    REAL(wp), PARAMETER :: EA = 100.0_wp, EAD = 400.0_wp, BAS = 7.0_wp, BAD = 3.0_wp
    REAL(wp), PARAMETER :: L0E = 1.0_wp, DL = 0.02_wp, DT = 0.05_wp
    TYPE(CD_ModelType) :: model, twin
    TYPE(GenAlphaConfig) :: cfg
    REAL(wp) :: qp(9), vp(9), ap(9), ta(2), tb(2)
    INTEGER :: es, k, n_iter
    CHARACTER(200) :: em
    LOGICAL :: conv, stalled
    CALL build_held_model(model, EA, EAD, BAS, BAD, L0E, DL, cfg, es, em)
    CALL require(es == CD_MODEL_OK, 'copy:init')
    CALL CD_Get_Model_State(model, qp, vp, ap, es, em)
    vp = 0.0_wp
    ap = 0.0_wp
    DO k = 1, 3
      CALL CD_Step_Model(model, DT, conv, stalled, n_iter, es, em, &
                         prescribed_q=qp, prescribed_v=vp, prescribed_a=ap)
    END DO
    CALL CD_Copy_Model(model, twin, es, em)
    CALL require(es == CD_MODEL_OK, 'copy:deep-copy')
    DO k = 1, 4
      CALL CD_Step_Model(model, DT, conv, stalled, n_iter, es, em, &
                         prescribed_q=qp, prescribed_v=vp, prescribed_a=ap)
      CALL CD_Step_Model(twin, DT, conv, stalled, n_iter, es, em, &
                         prescribed_q=qp, prescribed_v=vp, prescribed_a=ap)
      CALL CD_Get_Model_Tension(model, ta, es, em)
      CALL CD_Get_Model_Tension(twin, tb, es, em)
      CALL require(nan_max_abs(ta - tb) <= 0.0_wp, 'copy:trajectories-bitwise')
    END DO
    CALL CD_End_Model(model, es, em)
    CALL CD_End_Model(twin, es, em)
  END SUBROUTINE case_model_copy_midstate

  SUBROUTINE case_model_fail_closed()
    !! The init validation battery and the control composition: a segment-length change on a
    !! viscoelastic element leaves its dl_1 stretch as it is (MoorDyn-F/C), and the line steps.
    TYPE(CD_ModelType) :: model
    TYPE(GenAlphaConfig) :: cfg
    INTEGER :: conn(2, 2), fixed(6), es, n_iter
    REAL(wp) :: l0(2), ea(2), rho_a(2), q0(9), v0(9), f_ext(9)
    REAL(wp) :: ve_ead(2), ve_ba(2), ve_bad(2)
    CHARACTER(200) :: em
    LOGICAL :: conv, stalled
    conn(:, 1) = [1, 2]
    conn(:, 2) = [2, 3]
    l0 = 1.0_wp
    ea = 100.0_wp
    rho_a = 1.0_wp
    q0 = 0.0_wp
    q0(4) = 1.02_wp
    q0(7) = 2.04_wp
    v0 = 0.0_wp
    f_ext = 0.0_wp
    fixed = [1, 2, 3, 7, 8, 9]
    ve_ead = 400.0_wp
    ve_ba = 7.0_wp
    ve_bad = 3.0_wp
    ! partial presence
    CALL CD_Init_Model(model, q0, v0, conn, l0, ea, rho_a, .FALSE., f_ext, fixed, cfg, es, em, &
                       ve_ea_d=ve_ead)
    CALL require(es /= CD_MODEL_OK .AND. INDEX(em, 've_ba') > 0, 'fail:partial-presence')
    ! the load-dependent pair must come together
    CALL CD_Init_Model(model, q0, v0, conn, l0, ea, rho_a, .FALSE., f_ext, fixed, cfg, es, em, &
                       ve_ea_d=ve_ead, ve_ba=ve_ba, ve_ba_d=ve_bad, ve_alpha_mbl=ve_ead)
    CALL require(es /= CD_MODEL_OK .AND. INDEX(em, 've_vbeta') > 0, 'fail:mode3-pair-together')
    ! an element cannot carry both dynamic-stiffness forms
    BLOCK
      REAL(wp) :: ambl2(2), vbet2(2)
      ambl2 = 200.0_wp
      vbet2 = 0.4_wp
      CALL CD_Init_Model(model, q0, v0, conn, l0, ea, rho_a, .FALSE., f_ext, fixed, cfg, es, em, &
                         ve_ea_d=ve_ead, ve_ba=ve_ba, ve_ba_d=ve_bad, ve_alpha_mbl=ambl2, ve_vbeta=vbet2)
      CALL require(es /= CD_MODEL_OK .AND. INDEX(em, 'both') > 0, 'fail:both-forms-on-one-element')
    END BLOCK
    ! EA_D below EA is the params fatal battery through init
    ve_ead = 50.0_wp
    CALL CD_Init_Model(model, q0, v0, conn, l0, ea, rho_a, .FALSE., f_ext, fixed, cfg, es, em, &
                       ve_ea_d=ve_ead, ve_ba=ve_ba, ve_ba_d=ve_bad)
    CALL require(es /= CD_MODEL_OK .AND. INDEX(em, 'dynamic stiffness') > 0, 'fail:ead-below-ea')
    ! a plain element cannot carry SLS dashpots
    ve_ead = [400.0_wp, 0.0_wp]
    CALL CD_Init_Model(model, q0, v0, conn, l0, ea, rho_a, .FALSE., f_ext, fixed, cfg, es, em, &
                       ve_ea_d=ve_ead, ve_ba=ve_ba, ve_ba_d=ve_bad)
    CALL require(es /= CD_MODEL_OK .AND. INDEX(em, 'plain element') > 0, 'fail:plain-with-dashpots')
    ! MIXED line: element 1 viscoelastic, element 2 plain -- the segment-length
    ! control applies to both; the viscoelastic element keeps its dl_1 stretch bit for bit
    ve_ba = [7.0_wp, 0.0_wp]
    ve_bad = [3.0_wp, 0.0_wp]
    CALL CD_Init_Model(model, q0, v0, conn, l0, ea, rho_a, .FALSE., f_ext, fixed, cfg, es, em, &
                       ve_ea_d=ve_ead, ve_ba=ve_ba, ve_ba_d=ve_bad)
    CALL require(es == CD_MODEL_OK, 'fail:mixed-init-ok')
    BLOCK
      REAL(wp) :: dl1_before(2), dl1_after(2)
      CALL CD_Get_Model_VE_Dl1(model, dl1_before, es, em)
      CALL CD_Update_Model_SegmentLength(model, 1, 1.01_wp, 0.0_wp, es, em)
      CALL CD_Get_Model_VE_Dl1(model, dl1_after, es, em)
      CALL require(es == CD_MODEL_OK .AND. ALL(TRANSFER(dl1_after, 0_8, 2) == TRANSFER(dl1_before, 0_8, 2)), &
                   'fail:control-on-viscoelastic-keeps-dl1')
    END BLOCK
    CALL CD_Update_Model_SegmentLength(model, 2, 1.01_wp, 0.0_wp, es, em)
    CALL require(es == CD_MODEL_OK, 'fail:control-on-plain-ok')
    ! the mixed model still steps (the plain element keeps its EA elastic force)
    CALL CD_Step_Model(model, 0.05_wp, conv, stalled, n_iter, es, em)
    CALL require(es == CD_MODEL_OK .AND. conv, 'fail:mixed-steps')
    CALL CD_End_Model(model, es, em)
  END SUBROUTINE case_model_fail_closed

  SUBROUTINE case_dl1_accessor_roundtrip()
    !! The viscoelastic dl_1 checkpoint accessors (the coupled state mirror relies on
    !! them): a stepped model's committed dl_1 round-trips bit-exactly through
    !! get -> set, and set fails closed on a shape mismatch and a non-finite mirror.
    REAL(wp), PARAMETER :: EA = 100.0_wp, EAD = 400.0_wp, BAS = 7.0_wp, BAD = 3.0_wp
    REAL(wp), PARAMETER :: L0E = 1.0_wp, DL = 0.03_wp, DT = 0.05_wp
    TYPE(CD_ModelType) :: model
    TYPE(GenAlphaConfig) :: cfg
    REAL(wp) :: d0(2), d1(2), dbad(3), dnan(2)
    INTEGER :: k, ni, es
    LOGICAL :: cvg, stl
    CHARACTER(200) :: em
    CALL build_held_model(model, EA, EAD, BAS, BAD, L0E, DL, cfg, es, em)
    CALL require(es == CD_MODEL_OK, 'dl1:build: '//TRIM(em))
    CALL require(CD_Model_Has_Viscoelastic(model), 'dl1:has-viscoelastic')
    DO k = 1, 5
      CALL CD_Step_Model(model, DT, cvg, stl, ni, es, em)
      CALL require(es == CD_MODEL_OK, 'dl1:step: '//TRIM(em))
    END DO
    CALL CD_Get_Model_VE_Dl1(model, d0, es, em)
    CALL require(es == CD_MODEL_OK, 'dl1:get committed')
    CALL require(nan_max_abs(d0) > 0.0_wp, 'dl1:committed nonzero after stepping')
    ! overwrite with a distinct pattern and read it back exactly
    CALL CD_Set_Model_VE_Dl1(model, [0.111_wp, -0.222_wp], es, em)
    CALL require(es == CD_MODEL_OK, 'dl1:set pattern')
    CALL CD_Get_Model_VE_Dl1(model, d1, es, em)
    CALL require(ABS(d1(1) - 0.111_wp) <= 0.0_wp .AND. ABS(d1(2) + 0.222_wp) <= 0.0_wp, 'dl1:set-then-get exact')
    ! restore the committed state; must round-trip bit-exactly (the restart contract)
    CALL CD_Set_Model_VE_Dl1(model, d0, es, em)
    CALL require(es == CD_MODEL_OK, 'dl1:restore')
    CALL CD_Get_Model_VE_Dl1(model, d1, es, em)
    CALL require(nan_max_abs(d1 - d0) <= 0.0_wp, 'dl1:roundtrip bit-exact')
    ! fail closed: wrong size, non-finite mirror
    dbad = 0.0_wp
    CALL CD_Set_Model_VE_Dl1(model, dbad, es, em)
    CALL require(es /= CD_MODEL_OK, 'dl1:set wrong-size fails closed')
    dnan = [IEEE_VALUE(1.0_wp, IEEE_QUIET_NAN), 0.0_wp]
    CALL CD_Set_Model_VE_Dl1(model, dnan, es, em)
    CALL require(es /= CD_MODEL_OK, 'dl1:set non-finite fails closed')
    CALL CD_End_Model(model, es, em)
  END SUBROUTINE case_dl1_accessor_roundtrip

END PROGRAM test_viscoelastic
