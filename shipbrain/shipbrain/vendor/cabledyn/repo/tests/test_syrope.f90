! File: tests/test_syrope.f90
! SPDX-License-Identifier: Apache-2.0
! Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
PROGRAM test_syrope
  !! Gates for the Syrope polyester constitutive kernel against an independent NumPy
  !! implementation of the MoorDyn Syrope model, using the shipped OWC table and BA_s/BA_d
  !! constants -- working-curve generation for all three shapes, the static strain split, the
  !! rate/tension evaluation on
  !! both branches, the running-max regeneration event, and the fail-closed
  !! battery. The backward-Euler state solve also converges when its root sits at the top
  !! sample of the working curve (a rope at rest on its OWC at its running maximum), where the
  !! safeguarded Newton step alone crept along one side of the bracket and the solve failed, and
  !! when R is so steep (light BA) that it changes sign between two adjacent reals.
  USE CableDyn_Precision, ONLY: wp
  USE CableDyn_Syrope, ONLY: CD_SyropeType, CD_Syrope_Init, CD_Syrope_End, &
                             CD_Syrope_Working_Curve, CD_Syrope_Find_Strains, &
                             CD_Syrope_Rate_And_Tension, CD_Syrope_Fast_Strain, &
                             CD_Syrope_Slow_At_Tmax, CD_Syrope_Element_Load, CD_Syrope_State_Advance, &
                             CD_Syrope_Slow_At_Mean, CD_Syrope_Check_Range, CD_Syrope_Branch_Divider, &
                             CD_SYROPE_OK, CD_SYROPE_NWC, &
                             CD_SYROPE_WC_LINEAR, CD_SYROPE_WC_QUADRATIC, CD_SYROPE_WC_EXP
  USE CableDyn_Dynamic, ONLY: GenAlphaConfig, CD_EI0_SUBSTEPS_OFF
  USE CableDyn_Static, ONLY: CableSolverConfig
  USE CableDyn_Line, ONLY: CD_LineType, CD_LineSection
  USE CableDyn_Model, ONLY: CD_ModelType, CD_Init_Model, CD_Init_Line_Model, CD_Step_Model, CD_End_Model, &
                            CD_Copy_Model, CD_Get_Model_Tension, CD_MODEL_OK, &
                            CD_Model_Has_Syrope, CD_Get_Model_Syrope_State, CD_Set_Model_Syrope_State, &
                            CD_Calc_Model_CoupledLoads
  USE, INTRINSIC :: IEEE_ARITHMETIC, ONLY: IEEE_IS_FINITE, IEEE_VALUE, IEEE_QUIET_NAN
  IMPLICIT NONE

  ! the shipped owc.dat table (30 rows to 6% strain)
  REAL(wp), PARAMETER :: OWC_EPS(30) = [0.00000e+00_wp, 2.06897e-03_wp, 4.13793e-03_wp, 6.20690e-03_wp, &
                                        8.27586e-03_wp, 1.03448e-02_wp, 1.24138e-02_wp, 1.44828e-02_wp, &
                                        1.65517e-02_wp, 1.86207e-02_wp, 2.06897e-02_wp, 2.27586e-02_wp, &
                                        2.48276e-02_wp, 2.68966e-02_wp, 2.89655e-02_wp, 3.10345e-02_wp, &
                                        3.31034e-02_wp, 3.51724e-02_wp, 3.72414e-02_wp, 3.93103e-02_wp, &
                                        4.13793e-02_wp, 4.34483e-02_wp, 4.55172e-02_wp, 4.75862e-02_wp, &
                                        4.96552e-02_wp, 5.17241e-02_wp, 5.37931e-02_wp, 5.58621e-02_wp, &
                                        5.79310e-02_wp, 6.00000e-02_wp]
  REAL(wp), PARAMETER :: OWC_TEN(30) = [0.00000e+00_wp, 1.71768e+05_wp, 3.30952e+05_wp, 4.78788e+05_wp, &
                                        6.16510e+05_wp, 7.45355e+05_wp, 8.66556e+05_wp, 9.81351e+05_wp, &
                                        1.09097e+06_wp, 1.19666e+06_wp, 1.29964e+06_wp, 1.40116e+06_wp, &
                                        1.50245e+06_wp, 1.60474e+06_wp, 1.70927e+06_wp, 1.81728e+06_wp, &
                                        1.93000e+06_wp, 2.04866e+06_wp, 2.17450e+06_wp, 2.30876e+06_wp, &
                                        2.45267e+06_wp, 2.60747e+06_wp, 2.77439e+06_wp, 2.95467e+06_wp, &
                                        3.14954e+06_wp, 3.36024e+06_wp, 3.58800e+06_wp, 3.83406e+06_wp, &
                                        4.09965e+06_wp, 4.38601e+06_wp]
  REAL(wp), PARAMETER :: ALPHA = 1.53e8_wp, BETA = 23.12_wp
  REAL(wp), PARAMETER :: C1 = 5.0e10_wp, C2 = 1.0e5_wp
  REAL(wp), PARAMETER :: RTOL = 1.0e-12_wp

  INTEGER :: nfail, evidence_unit, argument_status
  CHARACTER(512) :: evidence_path
  nfail = 0
  evidence_unit = -1
  evidence_path = ''
  CALL GET_COMMAND_ARGUMENT(1, evidence_path, STATUS=argument_status)
  IF (argument_status == 0 .AND. LEN_TRIM(evidence_path) > 0) THEN
    OPEN (NEWUNIT=evidence_unit, FILE=TRIM(evidence_path), STATUS='REPLACE', ACTION='WRITE')
    WRITE (evidence_unit, '(A)') &
      'shape curve_strain evaluated_total_strain slow_strain slow_rate '// &
      'tension_N python_reference_N residual_N relative_residual'
  END IF

  CALL case_fail_closed()
  CALL case_degenerate_wc()
  CALL case_linear()
  CALL case_quadratic()
  CALL case_exp()
  CALL case_owc_branch_and_running_max()
  CALL case_interp_clamps()
  CALL case_projected_state_advance()
  CALL case_state_advance_at_wc_top()
  CALL case_state_advance_steep()
  CALL case_element_load()
  CALL case_model_legacy_ba_mask()
  CALL case_model_held()
  CALL case_syrope_accessor_roundtrip()
  CALL case_model_mixed_ve_syrope()
  CALL case_substeps_restore_law_states()
  CALL case_line_model_syrope()
  CALL case_admissibility()
  CALL case_ic_rest_point()
  CALL case_range_fail_closed()
  CALL case_compressed_segment()
  CALL case_implicit_element()
  CALL case_implicit_dt_convergence()

  IF (evidence_unit /= -1) CLOSE (evidence_unit)

  IF (nfail > 0) THEN
    WRITE (*, '(A,I0,A)') 'FAIL: ', nfail, ' assertion(s) failed'
    ERROR STOP 1
  END IF
  WRITE (*, '(A)') 'PASS: CableDyn_Syrope kernel vs production MoorDyn-F/C equations'

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

  LOGICAL FUNCTION close_rel(a, b) RESULT(ok)
    REAL(wp), INTENT(IN) :: a, b
    ok = ABS(a - b) <= RTOL*MAX(ABS(b), 1.0e-30_wp)
  END FUNCTION close_rel

  SUBROUTINE case_fail_closed()
    TYPE(CD_SyropeType) :: td
    REAL(wp) :: bad_eps(30)
    INTEGER :: es
    CHARACTER(200) :: em
    ! non-increasing strain column
    bad_eps = OWC_EPS
    bad_eps(10) = bad_eps(9)
    CALL CD_Syrope_Init(td, bad_eps, OWC_TEN, CD_SYROPE_WC_LINEAR, 1.25e8_wp, 0.0_wp, &
                        ALPHA, BETA, C1, C2, es, em)
    CALL require(es /= CD_SYROPE_OK .AND. INDEX(em, 'strictly increasing') > 0, 'fail:owc-non-increasing')
    ! a fast spring too soft for the table (alpha tiny): the slow-spring
    ! static strain decreases somewhere
    CALL CD_Syrope_Init(td, OWC_EPS, OWC_TEN, CD_SYROPE_WC_LINEAR, 1.25e8_wp, 0.0_wp, &
                        1.0e6_wp, BETA, C1, C2, es, em)
    CALL require(es /= CD_SYROPE_OK .AND. INDEX(em, 'slow-spring') > 0, 'fail:soft-fast-spring')
    ! both damping coefficients zero makes the state equation singular
    CALL CD_Syrope_Init(td, OWC_EPS, OWC_TEN, CD_SYROPE_WC_LINEAR, 1.25e8_wp, 0.0_wp, &
                        ALPHA, BETA, 0.0_wp, 0.0_wp, es, em)
    CALL require(es /= CD_SYROPE_OK .AND. INDEX(em, 'BA_s + BA_d') > 0, 'fail:zero-damping-sum')
    ! EXP shape with p2 = 0 (degenerate 0/0 curve)
    CALL CD_Syrope_Init(td, OWC_EPS, OWC_TEN, CD_SYROPE_WC_EXP, 0.3_wp, 0.0_wp, &
                        ALPHA, BETA, C1, C2, es, em)
    CALL require(es /= CD_SYROPE_OK .AND. INDEX(em, 'p2') > 0, 'fail:exp-zero-p2')
    ! an OWC tension at or below -alpha/beta (~ -6.62 MN here) drives the fast-spring
    ! log out of its domain -> eps_fast NaN -> owc_slow NaN. NaN slips past the
    ! strictly-increasing comparison, so the finite-value guard must reject it.
    ! shift the whole tension column down by 1e7 -> still strictly increasing (so it
    ! clears the column check) but the low rows sit below -alpha/beta
    BLOCK
      REAL(wp) :: bad_ten(30)
      bad_ten = OWC_TEN - 1.0e7_wp
      CALL CD_Syrope_Init(td, OWC_EPS, bad_ten, CD_SYROPE_WC_LINEAR, 1.25e8_wp, 0.0_wp, &
                          ALPHA, BETA, C1, C2, es, em)
      CALL require(es /= CD_SYROPE_OK .AND. INDEX(em, 'non-finite') > 0, 'fail:owc-nonfinite-slow')
    END BLOCK
    CALL CD_Syrope_End(td)
  END SUBROUTINE case_fail_closed

  SUBROUTINE case_degenerate_wc()
    !! Production MoorDyn shape ranges reject degenerate/nonmonotone curves at init.
    TYPE(CD_SyropeType) :: td
    INTEGER :: es
    CHARACTER(200) :: em
    CALL CD_Syrope_Init(td, OWC_EPS, OWC_TEN, CD_SYROPE_WC_QUADRATIC, 1.0_wp, 0.6_wp, &
                        ALPHA, BETA, C1, C2, es, em)
    CALL require(es /= CD_SYROPE_OK .AND. INDEX(em, '0 <= k1 < 1') > 0, 'degen:init-fails-closed')
    CALL CD_Syrope_End(td)
    ! a QUADRATIC shape parameter just outside the monotone range (p2 = 1.1) dips
    ! the working-curve tension near xi = 0 while the slow strain still rises, so
    ! the tension column -- the abscissa the on-curve interp needs -- must be
    ! rejected as non-monotone rather than silently returning wrong strains
    CALL CD_Syrope_Init(td, OWC_EPS, OWC_TEN, CD_SYROPE_WC_QUADRATIC, 0.3_wp, 1.1_wp, &
                        ALPHA, BETA, C1, C2, es, em)
    CALL require(es /= CD_SYROPE_OK .AND. INDEX(em, '0 < k2 <= 1') > 0, &
                 'degen:nonmono-shape-fails-closed')
    CALL CD_Syrope_End(td)
  END SUBROUTINE case_degenerate_wc

  SUBROUTINE case_linear()
    !! The linear_wc configuration (p1 = 1.25e8 is the >= 1 STIFFNESS form).
    TYPE(CD_SyropeType) :: td
    REAL(wp) :: ws(CD_SYROPE_NWC), wt(CD_SYROPE_NWC), wsl(CD_SYROPE_NWC)
    REAL(wp) :: st, fa, sl, dsl, ten, tm
    INTEGER :: es
    CHARACTER(200) :: em
    CALL CD_Syrope_Init(td, OWC_EPS, OWC_TEN, CD_SYROPE_WC_LINEAR, 1.25e8_wp, 0.0_wp, &
                        ALPHA, BETA, C1, C2, es, em)
    CALL require(es == CD_SYROPE_OK, 'lin:init')
    CALL CD_Syrope_Working_Curve(td, 2.0e6_wp, ws, wt, wsl, es, em)
    CALL require(es == CD_SYROPE_OK, 'lin:wc')
    CALL require(close_rel(ws(1), 0.0183239460980954_wp), 'lin:wc-eps-min')
    CALL require(close_rel(ws(CD_SYROPE_NWC), 0.0343239460980954_wp), 'lin:wc-eps-max')
    CALL require(close_rel(wt(8), 482758.6206896553_wp), 'lin:wc-T8')
    CALL require(close_rel(wt(23), 1517241.3793103453_wp), 'lin:wc-T23')
    CALL CD_Syrope_Find_Strains(td, .TRUE., ws, wt, 1.0e6_wp, st, fa, sl)
    CALL require(close_rel(st, 0.0263239460980954_wp), 'lin:static-strain')
    CALL require(close_rel(fa, 0.006086836483352841_wp), 'lin:fast-strain')
    CALL require(close_rel(sl, 0.02023710961474256_wp), 'lin:slow-strain')
    CALL CD_Syrope_Rate_And_Tension(td, .TRUE., ws, wt, wsl, sl, 0.03_wp, 1.0e-4_wp, &
                                    dsl, ten, tm, es, em)
    CALL require(es == CD_SYROPE_OK, 'lin:rate-ok')
    CALL require(close_rel(dsl, 1.2953759719285311e-05_wp), 'lin:rate')
    CALL require(close_rel(ten, 1647497.1395377084_wp), 'lin:tension')
    CALL write_reference_row('linear', st, sl, dsl, ten, 1647497.1395377074_wp)
    ! the mean tension recovered by inverse interpolation on the slow-spring
    ! curve is NOT the exact inverse of find_strains' interpolation on the
    ! strain curve; piecewise-linear inverse interpolation is not exact
    CALL require(close_rel(tm, 999809.1535734427_wp), 'lin:tmean-recovered')
    CALL CD_Syrope_End(td)
  END SUBROUTINE case_linear

  SUBROUTINE case_quadratic()
    TYPE(CD_SyropeType) :: td
    REAL(wp) :: ws(CD_SYROPE_NWC), wt(CD_SYROPE_NWC), wsl(CD_SYROPE_NWC)
    REAL(wp) :: st, fa, sl, dsl, ten, tm
    INTEGER :: es
    CHARACTER(200) :: em
    CALL CD_Syrope_Init(td, OWC_EPS, OWC_TEN, CD_SYROPE_WC_QUADRATIC, 0.3_wp, 0.6_wp, &
                        ALPHA, BETA, C1, C2, es, em)
    CALL require(es == CD_SYROPE_OK, 'quad:init')
    CALL CD_Syrope_Working_Curve(td, 2.0e6_wp, ws, wt, wsl, es, em)
    CALL require(es == CD_SYROPE_OK, 'quad:wc')
    CALL require(close_rel(ws(1), 0.01029718382942862_wp), 'quad:wc-eps-min')
    CALL require(close_rel(wt(8), 263020.2140309155_wp), 'quad:wc-T8')
    CALL require(close_rel(wt(23), 1297502.972651606_wp), 'quad:wc-T23')
    CALL CD_Syrope_Find_Strains(td, .TRUE., ws, wt, 1.0e6_wp, st, fa, sl)
    CALL require(close_rel(st, 0.025634405979504934_wp), 'quad:static-strain')
    CALL require(close_rel(sl, 0.019547569496152092_wp), 'quad:slow-strain')
    CALL CD_Syrope_Rate_And_Tension(td, .TRUE., ws, wt, wsl, sl, 0.03_wp, 1.0e-4_wp, &
                                    dsl, ten, tm, es, em)
    CALL require(close_rel(dsl, 1.5381995178892446e-05_wp), 'quad:rate')
    CALL require(close_rel(ten, 1768969.752642415_wp), 'quad:tension')
    CALL write_reference_row('quadratic', st, sl, dsl, ten, 1768969.7526424138_wp)
    CALL CD_Syrope_End(td)
  END SUBROUTINE case_quadratic

  SUBROUTINE case_exp()
    TYPE(CD_SyropeType) :: td
    REAL(wp) :: ws(CD_SYROPE_NWC), wt(CD_SYROPE_NWC), wsl(CD_SYROPE_NWC)
    REAL(wp) :: st, fa, sl, dsl, ten, tm
    INTEGER :: es
    CHARACTER(200) :: em
    CALL CD_Syrope_Init(td, OWC_EPS, OWC_TEN, CD_SYROPE_WC_EXP, 0.3_wp, 2.0_wp, &
                        ALPHA, BETA, C1, C2, es, em)
    CALL require(es == CD_SYROPE_OK, 'exp:init')
    CALL CD_Syrope_Working_Curve(td, 2.0e6_wp, ws, wt, wsl, es, em)
    CALL require(es == CD_SYROPE_OK, 'exp:wc')
    CALL require(close_rel(ws(1), 0.01029718382942862_wp), 'exp:wc-eps-min')
    CALL require(close_rel(wt(8), 194250.5070163505_wp), 'exp:wc-T8')
    CALL require(close_rel(wt(23), 1114289.649771604_wp), 'exp:wc-T23')
    CALL CD_Syrope_Find_Strains(td, .TRUE., ws, wt, 1.0e6_wp, st, fa, sl)
    CALL require(close_rel(st, 0.027516965536005664_wp), 'exp:static-strain')
    CALL require(close_rel(sl, 0.021430129052652822_wp), 'exp:slow-strain')
    CALL CD_Syrope_Rate_And_Tension(td, .TRUE., ws, wt, wsl, sl, 0.03_wp, 1.0e-4_wp, &
                                    dsl, ten, tm, es, em)
    CALL require(close_rel(dsl, 8.750782321663552e-06_wp), 'exp:rate')
    CALL require(close_rel(ten, 1437401.7004762_wp), 'exp:tension')
    CALL write_reference_row('exponential', st, sl, dsl, ten, 1437401.7004761999_wp)
    CALL CD_Syrope_End(td)
  END SUBROUTINE case_exp

  SUBROUTINE write_reference_row(shape, curve_strain, slow_strain, slow_rate, tension, reference)
    !! The reference values come from a separate NumPy implementation of the MoorDyn
    !! Syrope model (not part of the repository).
    !! Record enough precision and the residual so exact-looking rounded table
    !! entries cannot be mistaken for reuse of the production code path.
    CHARACTER(*), INTENT(IN) :: shape
    REAL(wp), INTENT(IN) :: curve_strain, slow_strain, slow_rate, tension, reference
    REAL(wp) :: residual
    residual = tension - reference
    CALL require(ABS(residual) <= 1.0e-6_wp, TRIM(shape)//':independent-python-residual')
    IF (evidence_unit /= -1) THEN
      WRITE (evidence_unit, '(A,1X,4(ES18.10,1X),2(ES24.16,1X),ES18.10,1X,ES18.10)') &
        TRIM(shape), curve_strain, 0.03_wp, slow_strain, slow_rate, tension, reference, residual, &
        residual/MAX(ABS(reference), 1.0_wp)
    END IF
  END SUBROUTINE write_reference_row

  SUBROUTINE case_owc_branch_and_running_max()
    !! Committed mean tension AT/ABOVE the running max selects the OWC branch,
    !! and the recovered mean tension above T_max is the caller's regeneration
    !! event: the regenerated curve matches the production formula.
    TYPE(CD_SyropeType) :: td
    REAL(wp) :: ws(CD_SYROPE_NWC), wt(CD_SYROPE_NWC), wsl(CD_SYROPE_NWC)
    REAL(wp) :: st, fa, sl, dsl, ten, tm
    INTEGER :: es
    CHARACTER(200) :: em
    CALL CD_Syrope_Init(td, OWC_EPS, OWC_TEN, CD_SYROPE_WC_LINEAR, 1.25e8_wp, 0.0_wp, &
                        ALPHA, BETA, C1, C2, es, em)
    CALL CD_Syrope_Working_Curve(td, 2.0e6_wp, ws, wt, wsl, es, em)
    CALL CD_Syrope_Find_Strains(td, .FALSE., ws, wt, 2.5e6_wp, st, fa, sl)
    CALL require(close_rel(st, 0.042011895413436695_wp), 'owc:static-strain')
    CALL require(close_rel(fa, 0.013861241145102584_wp), 'owc:fast-strain')
    CALL require(close_rel(sl, 0.02815065426833411_wp), 'owc:slow-strain')
    CALL CD_Syrope_Rate_And_Tension(td, .FALSE., ws, wt, wsl, sl, 0.045_wp, 5.0e-5_wp, &
                                    dsl, ten, tm, es, em)
    CALL require(es == CD_SYROPE_OK, 'owc:rate-ok')
    CALL require(close_rel(dsl, 1.2606308143959109e-05_wp), 'owc:rate')
    CALL require(close_rel(ten, 3130162.871313756_wp), 'owc:tension')
    CALL require(close_rel(tm, 2499847.4641158003_wp), 'owc:tmean-recovered')
    ! the running-max event: t_mean exceeded the 2.0e6 T_max -> regenerate
    CALL require(tm > 2.0e6_wp, 'owc:event-detected')
    CALL CD_Syrope_Working_Curve(td, tm, ws, wt, wsl, es, em)
    CALL require(es == CD_SYROPE_OK, 'owc:regenerated')
    CALL require(close_rel(ws(1), 0.022011076961851315_wp), 'owc:regen-eps-min')
    CALL require(close_rel(wt(23), 1896436.0072602627_wp), 'owc:regen-T23')
    CALL CD_Syrope_End(td)
  END SUBROUTINE case_owc_branch_and_running_max

  SUBROUTINE case_interp_clamps()
    !! Piecewise-linear interpolation clamps at both table ends.
    TYPE(CD_SyropeType) :: td
    REAL(wp) :: ws(CD_SYROPE_NWC), wt(CD_SYROPE_NWC), wsl(CD_SYROPE_NWC)
    REAL(wp) :: st, fa, sl
    INTEGER :: es
    CHARACTER(200) :: em
    CALL CD_Syrope_Init(td, OWC_EPS, OWC_TEN, CD_SYROPE_WC_LINEAR, 1.25e8_wp, 0.0_wp, &
                        ALPHA, BETA, C1, C2, es, em)
    CALL CD_Syrope_Working_Curve(td, 2.0e6_wp, ws, wt, wsl, es, em)
    ! far above the table: the static strain clamps to the last row
    CALL CD_Syrope_Find_Strains(td, .FALSE., ws, wt, 1.0e9_wp, st, fa, sl)
    CALL require(ABS(st - OWC_EPS(30)) <= 0.0_wp, 'clamp:above')
    ! below zero tension: clamps to the first row
    CALL CD_Syrope_Find_Strains(td, .FALSE., ws, wt, -1.0_wp, st, fa, sl)
    CALL require(ABS(st - OWC_EPS(1)) <= 0.0_wp, 'clamp:below')
    CALL CD_Syrope_End(td)
  END SUBROUTINE case_interp_clamps

  SUBROUTINE case_projected_state_advance()
    !! Strong unloading can put the unconstrained backward-Euler root below
    !! zero. The production state is lower-bounded, so the solver must commit
    !! the projected boundary instead of repeating a clamped Newton step.
    TYPE(CD_SyropeType) :: td
    REAL(wp) :: ws(CD_SYROPE_NWC), wt(CD_SYROPE_NWC), wsl(CD_SYROPE_NWC)
    REAL(wp) :: slow_next, t_mean, rate0, tension0, mean0, residual0
    INTEGER :: es
    CHARACTER(200) :: em

    CALL CD_Syrope_Init(td, OWC_EPS, OWC_TEN, CD_SYROPE_WC_LINEAR, 0.6_wp, 0.0_wp, &
                        ALPHA, BETA, 0.0_wp, C2, es, em)
    CALL require(es == CD_SYROPE_OK, 'projected:init')
    CALL CD_Syrope_Working_Curve(td, 2.0e6_wp, ws, wt, wsl, es, em)
    CALL require(es == CD_SYROPE_OK, 'projected:wc')
    CALL CD_Syrope_Rate_And_Tension(td, .TRUE., ws, wt, wsl, 0.0_wp, -0.02_wp, -0.1_wp, &
                                    rate0, tension0, mean0, es, em)
    residual0 = -0.01_wp - 0.1_wp*rate0
    CALL require(residual0 > 0.0_wp, 'projected:unconstrained-root-is-negative')
    CALL CD_Syrope_State_Advance(td, .TRUE., ws, wt, wsl, 0.01_wp, -0.02_wp, -0.1_wp, 0.1_wp, &
                                 slow_next, t_mean, es, em)
    CALL require(es == CD_SYROPE_OK, 'projected:status: '//TRIM(em))
    CALL require(ABS(slow_next) <= TINY(1.0_wp) .AND. IEEE_IS_FINITE(t_mean), 'projected:boundary-commit')
    CALL CD_Syrope_State_Advance(td, .TRUE., ws, wt, wsl, 0.01_wp, 0.03_wp, 1.0e-3_wp, 1.0e-3_wp, &
                                 slow_next, t_mean, es, em)
    CALL require(es == CD_SYROPE_OK .AND. slow_next > 0.0_wp, 'projected:interior-status')
    CALL CD_Syrope_Rate_And_Tension(td, .TRUE., ws, wt, wsl, slow_next, 0.03_wp, 1.0e-3_wp, &
                                    rate0, tension0, mean0, es, em)
    CALL require(ABS(slow_next - 0.01_wp - 1.0e-3_wp*rate0) <= 5.0e-12_wp, &
                 'projected:interior-residual')
    CALL CD_Syrope_State_Advance(td, .TRUE., ws, wt, wsl, -0.01_wp, 0.02_wp, 0.0_wp, 0.1_wp, &
                                 slow_next, t_mean, es, em)
    CALL require(es /= CD_SYROPE_OK .AND. INDEX(em, 'slow_old >= 0') > 0, 'projected:negative-old-fails')
    CALL CD_Syrope_End(td)
  END SUBROUTINE case_projected_state_advance

  SUBROUTINE case_state_advance_at_wc_top()
    !! A rope held at rest on its OWC at its running maximum: the backward-Euler root lies just
    !! above the top sample of the working curve's slow strains, where T_mean(eps_slow) stops
    !! rising (it clamps at T_max up to the branch divider), closer to it than the Newton
    !! step's difference interval. The state of a run (LINEAR, k1 = 0.5, BA_s|BA_d = 1e6|1e5,
    !! a line hauled in and held) on which the safeguarded Newton step crept 80 iterations
    !! along that kink and the solve failed; the bisection that finishes the solve meets the
    !! residual test, between the kink and the divider, at the curve's top tension.
    TYPE(CD_SyropeType) :: td
    REAL(wp), PARAMETER :: TMAX = 1.7790941510791376e6_wp, SLOW0 = 2.0004433178640910e-2_wp, &
                           EPS = 3.0303024894996432e-2_wp, DEPS = -1.4208693414705444e-13_wp, DT = 5.0e-2_wp
    REAL(wp) :: ws(CD_SYROPE_NWC), wt(CD_SYROPE_NWC), wsl(CD_SYROPE_NWC)
    REAL(wp) :: slow_next, t_mean, divider, rate, tension, mean, residual
    INTEGER :: es
    CHARACTER(200) :: em
    CALL CD_Syrope_Init(td, OWC_EPS, OWC_TEN, CD_SYROPE_WC_LINEAR, 0.5_wp, 0.0_wp, &
                        ALPHA, BETA, 1.0e6_wp, 1.0e5_wp, es, em)
    CALL require(es == CD_SYROPE_OK, 'wc-top:init')
    CALL CD_Syrope_Working_Curve(td, TMAX, ws, wt, wsl, es, em)
    CALL require(es == CD_SYROPE_OK, 'wc-top:wc')
    divider = CD_Syrope_Branch_Divider(td, TMAX)
    CALL CD_Syrope_State_Advance(td, SLOW0 < divider, ws, wt, wsl, SLOW0, EPS, DEPS, DT, slow_next, t_mean, &
                                 es, em, divider=divider)
    CALL require(es == CD_SYROPE_OK, 'wc-top:the solve converges: '//TRIM(em))
    CALL CD_Syrope_Rate_And_Tension(td, slow_next < divider, ws, wt, wsl, slow_next, EPS, DEPS, rate, tension, &
                                    mean, es, em)
    residual = slow_next - SLOW0 - DT*rate
    WRITE (*, '(A,ES16.9,A,ES10.3,A,ES12.5,A)') '  wc-top: slow strain ', slow_next, ', residual ', residual, &
      ', mean tension ', mean, ' N'
    CALL require(ABS(residual) <= 5.0e-13_wp .AND. slow_next > wsl(CD_SYROPE_NWC) .AND. slow_next < divider .AND. &
                 bits_same(mean, wt(CD_SYROPE_NWC)) .AND. bits_same(mean, t_mean), 'wc-top:root at the curve top')
    CALL CD_Syrope_End(td)
  END SUBROUTINE case_state_advance_at_wc_top

  SUBROUTINE case_state_advance_steep()
    !! Twelve states of a light rope (QUADRATIC, p2 = 0.5, BA_s|BA_d = 1e4|1e3) next to the top
    !! of the working curve, from a fuzz of the solve, on which it failed: R' = 1 - dt
    !! d(rate)/d(eps_slow) is of order 1e6, so R changes sign between two adjacent reals with |R|
    !! above the residual test on both. The solve returns the root to machine precision: R
    !! changes sign between the result and its neighbour on the other side, and the returned
    !! mean tension is the one at the result.
    INTEGER, PARAMETER :: NS = 12
    ! k1, T_max, slow_old, eps, deps, dt
    REAL(wp), PARAMETER :: ST(6, NS) = RESHAPE([ &
                                               0.5_wp, 1.36633017834277474e6_wp, 1.39304174224812102e-2_wp, &
                                     2.20484956584058520e-2_wp, -2.91917316204991001e-5_wp, 5.00000000000000028e-2_wp, &
                                               0.5_wp, 1.37680196069096052e6_wp, 5.35760113574383894e-3_wp, &
                                    2.22609221334421868e-2_wp, -5.34676314308176825e-13_wp, 2.00000000000000011e-1_wp, &
                                               0.5_wp, 1.36922682379846880e6_wp, 1.39737625858687414e-2_wp, &
                                    2.21031832264193540e-2_wp, -1.54171755685975461e-10_wp, 2.00000000000000011e-1_wp, &
                                               0.5_wp, 1.37055211343974154e6_wp, 1.39940856061747162e-2_wp, &
                                     2.21297981068623792e-2_wp, -1.34624093812978118e-5_wp, 2.00000000000000011e-1_wp, &
                                               0.5_wp, 1.37527118954379787e6_wp, 6.58388926223281434e-3_wp, &
                                     2.22260959754430436e-2_wp, 9.20479632170825829e-10_wp, 2.00000000000000011e-1_wp, &
                                               0.5_wp, 1.37087072085890593e6_wp, 1.35832674506310615e-2_wp, &
                                      2.21347560532284236e-2_wp, 2.40447604051167914e-5_wp, 2.00000000000000011e-1_wp, &
                                               0.5_wp, 1.36645106216464797e6_wp, 1.39322344956098881e-2_wp, &
                                    2.20511942008235519e-2_wp, -2.02603337569392040e-13_wp, 5.00000000000000028e-2_wp, &
                                               0.5_wp, 1.36815732104760036e6_wp, 1.39584978679733341e-2_wp, &
                                     2.20753893183824081e-2_wp, -5.23605833892740875e-6_wp, 2.00000000000000011e-1_wp, &
                                               0.5_wp, 1.37059169344443991e6_wp, 1.39949247390703350e-2_wp, &
                                       2.21338733365970056e-2_wp, 0.00000000000000000e0_wp, 2.00000000000000011e-1_wp, &
                                               0.5_wp, 1.38033403057004604e6_wp, 1.35405334447999213e-2_wp, &
                                       2.23240330306617440e-2_wp, 0.00000000000000000e0_wp, 2.00000000000000011e-1_wp, &
                                               0.3_wp, 4.73718757443073089e5_wp, 3.14555534663941896e-3_wp, &
                                    6.13349734479911885e-3_wp, -1.55116580233012027e-13_wp, 2.00000000000000011e-1_wp, &
                                               0.3_wp, 4.71172300428577990e5_wp, 6.16859346183203398e-4_wp, &
                             6.09875211747266683e-3_wp, -2.98940253643357627e-5_wp, 2.00000000000000011e-1_wp], [6, NS])
    TYPE(CD_SyropeType) :: td
    REAL(wp) :: ws(CD_SYROPE_NWC), wt(CD_SYROPE_NWC), wsl(CD_SYROPE_NWC)
    REAL(wp) :: slow_next, t_mean, divider, rate, tension, mean, r0, r1, other, worst
    INTEGER :: es, k, n_ok
    CHARACTER(200) :: em
    n_ok = 0
    worst = 0.0_wp
    DO k = 1, NS
      CALL CD_Syrope_Init(td, OWC_EPS, OWC_TEN, CD_SYROPE_WC_QUADRATIC, ST(1, k), 0.5_wp, &
                          ALPHA, BETA, 1.0e4_wp, 1.0e3_wp, es, em)
      CALL require(es == CD_SYROPE_OK, 'steep:init')
      CALL CD_Syrope_Working_Curve(td, ST(2, k), ws, wt, wsl, es, em)
      CALL require(es == CD_SYROPE_OK, 'steep:wc')
      divider = CD_Syrope_Branch_Divider(td, ST(2, k))
      CALL CD_Syrope_State_Advance(td, ST(3, k) < divider, ws, wt, wsl, ST(3, k), ST(4, k), ST(5, k), ST(6, k), &
                                   slow_next, t_mean, es, em, divider=divider)
      IF (es /= CD_SYROPE_OK) THEN
        CALL require(.FALSE., 'steep:the solve converges: '//TRIM(em))
        CALL CD_Syrope_End(td)
        CYCLE
      END IF
      CALL CD_Syrope_Rate_And_Tension(td, slow_next < divider, ws, wt, wsl, slow_next, ST(4, k), ST(5, k), rate, &
                                      tension, mean, es, em)
      r0 = slow_next - ST(3, k) - ST(6, k)*rate
      other = NEAREST(slow_next, MERGE(1.0_wp, -1.0_wp, r0 < 0.0_wp))
      CALL CD_Syrope_Rate_And_Tension(td, other < divider, ws, wt, wsl, other, ST(4, k), ST(5, k), rate, &
                                      tension, mean, es, em)
      r1 = other - ST(3, k) - ST(6, k)*rate
      worst = MAX(worst, ABS(r0))
      CALL CD_Syrope_Rate_And_Tension(td, slow_next < divider, ws, wt, wsl, slow_next, ST(4, k), ST(5, k), rate, &
                                      tension, mean, es, em)
      IF ((r0 < 0.0_wp .NEQV. r1 < 0.0_wp) .AND. bits_same(mean, t_mean)) n_ok = n_ok + 1
      CALL CD_Syrope_End(td)
    END DO
    WRITE (*, '(A,I0,A,I0,A,ES10.3)') '  steep: ', n_ok, ' of ', NS, &
      ' roots located to machine precision, largest |R| ', worst
    CALL require(n_ok == NS, 'steep:roots to machine precision')
  END SUBROUTINE case_state_advance_steep

  LOGICAL FUNCTION bits_same(a, b) RESULT(same)
    REAL(wp), INTENT(IN) :: a, b
    same = TRANSFER(a, 0_8) == TRANSFER(b, 0_8)
  END FUNCTION bits_same

  SUBROUTINE case_element_load()
    !! The element load wraps the kernel: a colinear element stretched to a
    !! chosen total strain reports the MoorDyn tension along its tangent, the
    !! recovered mean tension and slow-strain rate for the commit, and a
    !! central-FD-consistent position and velocity Jacobians.
    TYPE(CD_SyropeType) :: td
    REAL(wp) :: ws(CD_SYROPE_NWC), wt(CD_SYROPE_NWC), wsl(CD_SYROPE_NWC)
    REAL(wp) :: qa(3), qb(3), va(3), vb(3), l0, eps, deps_target
    REAL(wp) :: force(6), jac_q(6, 6), jac_v(6, 6), t_mean, dslow
    REAL(wp) :: fp(6), fm(6), jd(6, 6), jvd(6, 6), td_out, ds_out, x(6), vv(6), err
    INTEGER :: es, i, j
    CHARACTER(200) :: em
    CALL CD_Syrope_Init(td, OWC_EPS, OWC_TEN, CD_SYROPE_WC_LINEAR, 0.6_wp, 0.0_wp, &
                        ALPHA, BETA, C1, C2, es, em)
    CALL require(es == CD_SYROPE_OK, 'elem:init')
    CALL CD_Syrope_Working_Curve(td, 2.0e6_wp, ws, wt, wsl, es, em)
    CALL require(es == CD_SYROPE_OK, 'elem:wc')
    CALL require(close_rel(CD_Syrope_Slow_At_Tmax(td, 2.0e6_wp), 0.022902137844953225_wp), 'elem:slow-at-tmax')
    ! colinear element along x: eps = 0.026, deps = 1.0e-3 (vb_x = deps*l0)
    l0 = 1.0_wp
    eps = 0.026_wp
    deps_target = 1.0e-3_wp
    qa = 0.0_wp
    qb = [l0*(1.0_wp + eps), 0.0_wp, 0.0_wp]
    va = 0.0_wp
    vb = [deps_target*l0, 0.0_wp, 0.0_wp]
    CALL CD_Syrope_Element_Load(qa, qb, va, vb, l0, td, ws, wt, wsl, .TRUE., 0.021_wp, .FALSE., &
                                force, jac_q, t_mean, dslow, es, em, jac_v=jac_v)
    CALL require(es == CD_SYROPE_OK, 'elem:load-ok')
    CALL require(close_rel(force(1), 809279.6742719244_wp), 'elem:tension-along-tangent')
    CALL require(ABS(force(1) + force(4)) <= 1.0e-9_wp*ABS(force(1)), 'elem:force-antisymmetric')
    CALL require(close_rel(t_mean, 645092.3340833774_wp), 'elem:t-mean')
    CALL require(close_rel(dslow, 3.2837468037709406e-6_wp), 'elem:dslow')
    ! central-FD position Jacobian
    err = 0.0_wp
    DO j = 1, 6
      x(1:3) = qa; x(4:6) = qb
      x(j) = x(j) + 1.0e-8_wp
      CALL CD_Syrope_Element_Load(x(1:3), x(4:6), va, vb, l0, td, ws, wt, wsl, .TRUE., 0.021_wp, .FALSE., &
                                  fp, jd, td_out, ds_out, es, em, jac_v=jvd)
      x(j) = x(j) - 2.0e-8_wp
      CALL CD_Syrope_Element_Load(x(1:3), x(4:6), va, vb, l0, td, ws, wt, wsl, .TRUE., 0.021_wp, .FALSE., &
                                  fm, jd, td_out, ds_out, es, em, jac_v=jvd)
      DO i = 1, 6
        ! jac_q is the residual convention -dF/dq (matching the axial-damping /
        ! viscoelastic contributors), so compare against -(central difference)
        err = MAX(err, ABS(-(fp(i) - fm(i))/(2.0e-8_wp) - jac_q(i, j))/ &
                  MAX(1.0_wp, ABS(jac_q(i, j))))
      END DO
    END DO
    CALL require(err < 5.0e-6_wp, 'elem:fd-jacobian')
    ! central-FD velocity Jacobian
    err = 0.0_wp
    vv(1:3) = va; vv(4:6) = vb
    DO j = 1, 6
      vv(j) = vv(j) + 1.0e-8_wp
      CALL CD_Syrope_Element_Load(qa, qb, vv(1:3), vv(4:6), l0, td, ws, wt, wsl, .TRUE., 0.021_wp, .FALSE., &
                                  fp, jd, td_out, ds_out, es, em, jac_v=jvd)
      vv(j) = vv(j) - 2.0e-8_wp
      CALL CD_Syrope_Element_Load(qa, qb, vv(1:3), vv(4:6), l0, td, ws, wt, wsl, .TRUE., 0.021_wp, .FALSE., &
                                  fm, jd, td_out, ds_out, es, em, jac_v=jvd)
      vv(j) = vv(j) + 1.0e-8_wp
      DO i = 1, 6
        err = MAX(err, ABS(-(fp(i) - fm(i))/(2.0e-8_wp) - jac_v(i, j))/ &
                  MAX(1.0_wp, ABS(jac_v(i, j))))
      END DO
    END DO
    CALL require(err < 5.0e-6_wp, 'elem:fd-velocity-jacobian')
    ! tension-only clamp: a compressed segment reports zero force but a live rate
    qb = [l0*0.99_wp, 0.0_wp, 0.0_wp]
    CALL CD_Syrope_Element_Load(qa, qb, va, vb, l0, td, ws, wt, wsl, .TRUE., 0.0_wp, .TRUE., &
                                force, jac_q, t_mean, dslow, es, em, jac_v=jac_v)
    CALL require(es == CD_SYROPE_OK .AND. nan_max_abs(force) <= 0.0_wp, 'elem:tension-only-clamp')
    CALL CD_Syrope_End(td)
  END SUBROUTINE case_element_load

  SUBROUTINE case_model_legacy_ba_mask()
    !! A Syrope element owns BA_s internally. Supplying the same value through
    !! the generic model BA boundary must not change its coupled force; this is
    !! the library-level defense behind the deck route's stricter BA isolation.
    TYPE(CD_SyropeType) :: td, stype(1)
    TYPE(CD_ModelType) :: reference, with_legacy_ba
    TYPE(GenAlphaConfig) :: cfg
    INTEGER :: conn(2, 1), fixed(6), es
    REAL(wp) :: q0(6), v0(6), l0(1), ea(1), rho_a(1), f_ext(6), ba(1)
    REAL(wp) :: load_ref(6), load_ba(6), slow0(1), tmax0(1)
    LOGICAL :: sis(1)
    CHARACTER(200) :: em

    CALL CD_Syrope_Init(td, OWC_EPS, OWC_TEN, CD_SYROPE_WC_LINEAR, 0.6_wp, 0.0_wp, &
                        ALPHA, BETA, C1, C2, es, em)
    CALL require(es == CD_SYROPE_OK, 'ba-mask:type-init')
    conn(:, 1) = [1, 2]
    fixed = [1, 2, 3, 4, 5, 6]
    q0 = [0.0_wp, 0.0_wp, 0.0_wp, 1.026_wp, 0.0_wp, 0.0_wp]
    v0 = [0.0_wp, 0.0_wp, 0.0_wp, 1.0e-3_wp, 0.0_wp, 0.0_wp]
    l0 = 1.0_wp
    ea = 1.0e8_wp
    rho_a = 22.42_wp
    f_ext = 0.0_wp
    ba = C1
    sis = .TRUE.
    stype(1) = td
    slow0 = 0.021_wp
    tmax0 = 2.0e6_wp
    CALL CD_Init_Model(reference, q0, v0, conn, l0, ea, rho_a, .FALSE., f_ext, fixed, cfg, es, em, &
                       syrope_is=sis, syrope_type=stype, syrope_slow0=slow0, syrope_tmax0=tmax0)
    CALL require(es == CD_MODEL_OK, 'ba-mask:reference-init')
    CALL CD_Init_Model(with_legacy_ba, q0, v0, conn, l0, ea, rho_a, .FALSE., f_ext, fixed, cfg, es, em, &
                       ba=ba, syrope_is=sis, syrope_type=stype, syrope_slow0=slow0, syrope_tmax0=tmax0)
    CALL require(es == CD_MODEL_OK, 'ba-mask:legacy-init')
    CALL CD_Calc_Model_CoupledLoads(reference, load_ref, es, em)
    CALL require(es == CD_MODEL_OK, 'ba-mask:reference-load')
    CALL CD_Calc_Model_CoupledLoads(with_legacy_ba, load_ba, es, em)
    CALL require(es == CD_MODEL_OK, 'ba-mask:legacy-load')
    CALL require(nan_max_abs(load_ref - load_ba) <= 0.0_wp, 'ba-mask:no-double-count')
    CALL CD_End_Model(reference, es, em)
    CALL CD_End_Model(with_legacy_ba, es, em)
    slow0 = -0.01_wp
    CALL CD_Init_Model(reference, q0, v0, conn, l0, ea, rho_a, .FALSE., f_ext, fixed, cfg, es, em, &
                       syrope_is=sis, syrope_type=stype, syrope_slow0=slow0, syrope_tmax0=tmax0)
    CALL require(es /= CD_MODEL_OK .AND. INDEX(em, 'non-negative') > 0, 'ba-mask:negative-slow0-fails')
    CALL CD_End_Model(reference, es, em)
    slow0 = 0.021_wp
    tmax0 = 1.1e6_wp
    CALL CD_Init_Model(reference, q0, v0, conn, l0, ea, rho_a, .FALSE., f_ext, fixed, cfg, es, em, &
                       syrope_is=sis, syrope_type=stype, syrope_slow0=slow0, syrope_tmax0=tmax0)
    CALL require(es /= CD_MODEL_OK .AND. INDEX(em, 'invalid') > 0, 'ba-mask:ill-posed-tmax0-fails')
    CALL CD_End_Model(reference, es, em)
    CALL CD_Syrope_End(td)
    CALL CD_Syrope_End(stype(1))
  END SUBROUTINE case_model_legacy_ba_mask

  SUBROUTINE case_model_held()
    !! End-to-end model gate: a 3-node colinear line with both ends fixed and a
    !! free midpoint, both elements Syrope at a held stretch. By symmetry the
    !! midpoint force cancels bitwise so the geometry is a fixed point, while
    !! each element's slow strain relaxes -- the reported tension follows the
    !! backward-Euler held-relaxation trajectory. Also covers the deep
    !! copy of the constitutive data (CD_Copy_Model of the OWC array).
    REAL(wp), PARAMETER :: L0E = 1.0_wp, EPS = 0.026_wp, DT = 0.05_wp
    TYPE(CD_SyropeType) :: td
    TYPE(CD_ModelType) :: model, twin
    TYPE(GenAlphaConfig) :: cfg
    INTEGER :: conn(2, 2), fixed(6), es, k, n_iter
    REAL(wp) :: l0(2), eav(2), rho_a(2), q0(9), v0(9), f_ext(9)
    REAL(wp) :: tension(2), ta(2), tb(2)
    LOGICAL :: sis(2), conv, stalled
    TYPE(CD_SyropeType) :: stype(2)
    REAL(wp) :: sslow(2), stmax(2)
    REAL(wp) :: previous_tension
    CHARACTER(200) :: em
    CALL CD_Syrope_Init(td, OWC_EPS, OWC_TEN, CD_SYROPE_WC_LINEAR, 0.6_wp, 0.0_wp, &
                        ALPHA, BETA, C1, C2, es, em)
    CALL require(es == CD_SYROPE_OK, 'model:type-init')
    conn(:, 1) = [1, 2]
    conn(:, 2) = [2, 3]
    l0 = L0E
    eav = 1.0e8_wp    ! masked to ea_dyn = 0 for Syrope elements; Syrope supplies tension
    rho_a = 22.42_wp
    q0 = 0.0_wp
    q0(4) = L0E*(1.0_wp + EPS)
    q0(7) = 2.0_wp*L0E*(1.0_wp + EPS)
    v0 = 0.0_wp
    f_ext = 0.0_wp
    fixed = [1, 2, 3, 7, 8, 9]
    sis = .TRUE.
    stype(1) = td
    stype(2) = td
    sslow = 0.021_wp
    stmax = 2.0e6_wp
    CALL CD_Init_Model(model, q0, v0, conn, l0, eav, rho_a, .FALSE., f_ext, fixed, cfg, es, em, &
                       syrope_is=sis, syrope_type=stype, syrope_slow0=sslow, syrope_tmax0=stmax)
    CALL require(es == CD_MODEL_OK, 'model:init: '//TRIM(em))
    ! a deep copy taken at the IC must track the original bitwise as both step
    CALL CD_Copy_Model(model, twin, es, em)
    CALL require(es == CD_MODEL_OK, 'model:copy')
    previous_tension = HUGE(1.0_wp)
    DO k = 1, 10
      CALL CD_Step_Model(model, DT, conv, stalled, n_iter, es, em)
      CALL require(es == CD_MODEL_OK .AND. (conv .OR. stalled), 'model:step: '//TRIM(em))
      CALL CD_Step_Model(twin, DT, conv, stalled, n_iter, es, em)
      CALL CD_Get_Model_Tension(model, tension, es, em)
      CALL require(es == CD_MODEL_OK, 'model:tension')
      CALL require(ABS(tension(2) - tension(1)) <= 1.0e-9_wp*ABS(tension(1)), 'model:symmetry')
      CALL CD_Get_Model_Tension(twin, tb, es, em)
      ta = tension
      CALL require(nan_max_abs(ta - tb) <= 0.0_wp, 'model:copy-tracks-bitwise')
      CALL require(tension(1) < previous_tension, 'model:held relaxation is monotone')
      previous_tension = tension(1)
    END DO
    CALL CD_End_Model(model, es, em)
    CALL CD_End_Model(twin, es, em)
    CALL CD_Syrope_End(td)
  END SUBROUTINE case_model_held

  SUBROUTINE case_syrope_accessor_roundtrip()
    !! The Syrope state checkpoint accessors the coupled mirror relies on: a stepped
    !! model's committed (slow, tmax) round-trip bit-exactly through get -> set -> get
    !! (the restart contract); set fails closed on invalid shape, finiteness, or state domain.
    REAL(wp), PARAMETER :: L0E = 1.0_wp, EPS = 0.026_wp, DT = 0.05_wp
    TYPE(CD_SyropeType) :: td, stype(2)
    TYPE(CD_ModelType) :: model
    TYPE(GenAlphaConfig) :: cfg
    INTEGER :: conn(2, 2), fixed(6), es, k, n_iter
    REAL(wp) :: l0(2), eav(2), rho_a(2), q0(9), v0(9), f_ext(9)
    REAL(wp) :: s0(2), t0(2), s1(2), t1(2), sbad(3), snan(2)
    LOGICAL :: sis(2), conv, stalled
    CHARACTER(200) :: em
    CALL CD_Syrope_Init(td, OWC_EPS, OWC_TEN, CD_SYROPE_WC_LINEAR, 0.6_wp, 0.0_wp, ALPHA, BETA, C1, C2, es, em)
    CALL require(es == CD_SYROPE_OK, 'syr-rt:type-init')
    conn(:, 1) = [1, 2]
    conn(:, 2) = [2, 3]
    l0 = L0E
    eav = 1.0e8_wp
    rho_a = 22.42_wp
    q0 = 0.0_wp
    q0(4) = L0E*(1.0_wp + EPS)
    q0(7) = 2.0_wp*L0E*(1.0_wp + EPS)
    v0 = 0.0_wp
    f_ext = 0.0_wp
    fixed = [1, 2, 3, 7, 8, 9]
    sis = .TRUE.
    stype(1) = td
    stype(2) = td
    CALL CD_Init_Model(model, q0, v0, conn, l0, eav, rho_a, .FALSE., f_ext, fixed, cfg, es, em, &
                       syrope_is=sis, syrope_type=stype, syrope_slow0=[0.021_wp, 0.021_wp], &
                       syrope_tmax0=[2.0e6_wp, 2.0e6_wp])
    CALL require(es == CD_MODEL_OK, 'syr-rt:init: '//TRIM(em))
    CALL require(CD_Model_Has_Syrope(model), 'syr-rt:has-syrope')
    DO k = 1, 5
      CALL CD_Step_Model(model, DT, conv, stalled, n_iter, es, em)
      CALL require(es == CD_MODEL_OK, 'syr-rt:step: '//TRIM(em))
    END DO
    CALL CD_Get_Model_Syrope_State(model, s0, t0, es, em)
    CALL require(es == CD_MODEL_OK, 'syr-rt:get committed')
    CALL require(nan_max_abs(s0) > 0.0_wp .AND. nan_max_abs(t0) > 0.0_wp, 'syr-rt:committed nonzero')
    ! overwrite with a distinct pattern and read it back exactly
    CALL CD_Set_Model_Syrope_State(model, [0.033_wp, 0.036_wp], [2.0e6_wp, 2.2e6_wp], es, em)
    CALL require(es == CD_MODEL_OK, 'syr-rt:set pattern: '//TRIM(em))
    CALL CD_Get_Model_Syrope_State(model, s1, t1, es, em)
    CALL require(ABS(s1(1) - 0.033_wp) <= 0.0_wp .AND. ABS(t1(2) - 2.2e6_wp) <= 0.0_wp, 'syr-rt:set-then-get exact')
    ! restore the committed state; must round-trip bit-exactly (the restart contract)
    CALL CD_Set_Model_Syrope_State(model, s0, t0, es, em)
    CALL require(es == CD_MODEL_OK, 'syr-rt:restore')
    CALL CD_Get_Model_Syrope_State(model, s1, t1, es, em)
    CALL require(nan_max_abs(s1 - s0) <= 0.0_wp .AND. nan_max_abs(t1 - t0) <= 0.0_wp, 'syr-rt:roundtrip bit-exact')
    ! fail closed: wrong size, non-finite mirror
    sbad = 0.0_wp
    CALL CD_Set_Model_Syrope_State(model, sbad, [1.0_wp, 2.0_wp, 3.0_wp], es, em)
    CALL require(es /= CD_MODEL_OK, 'syr-rt:set wrong-size fails closed')
    snan = [IEEE_VALUE(1.0_wp, IEEE_QUIET_NAN), 0.0_wp]
    CALL CD_Set_Model_Syrope_State(model, snan, [1.0e6_wp, 2.0e6_wp], es, em)
    CALL require(es /= CD_MODEL_OK, 'syr-rt:set non-finite fails closed')
    ! a nonpositive running maximum (a corrupted/edited checkpoint) fails closed at the
    ! reload boundary -- the working curve rejects it, so catch it here not later
    CALL CD_Set_Model_Syrope_State(model, s0, [1.0e6_wp, -5.0e5_wp], es, em)
    CALL require(es /= CD_MODEL_OK, 'syr-rt:set nonpositive tmax fails closed')
    CALL CD_Set_Model_Syrope_State(model, [-0.01_wp, 0.02_wp], [1.0e6_wp, 2.0e6_wp], es, em)
    CALL require(es /= CD_MODEL_OK .AND. INDEX(em, 'non-negative') > 0, 'syr-rt:set negative slow fails closed')
    CALL CD_Set_Model_Syrope_State(model, s0, [1.0e12_wp, 2.0e6_wp], es, em)
    CALL require(es /= CD_MODEL_OK .AND. INDEX(em, 'outside') > 0, 'syr-rt:set out-of-range tmax fails closed')
    ! a slow strain past the last OWC row's slow strain (~0.038 here) fails closed
    CALL CD_Set_Model_Syrope_State(model, [0.033_wp, 0.044_wp], [2.0e6_wp, 2.2e6_wp], es, em)
    CALL require(es /= CD_MODEL_OK .AND. INDEX(em, 'left the OWC table') > 0, &
                 'syr-rt:set beyond-table slow fails closed')
    CALL CD_End_Model(model, es, em)
    CALL CD_Syrope_End(td)
  END SUBROUTINE case_syrope_accessor_roundtrip

  SUBROUTINE case_model_mixed_ve_syrope()
    !! A model carrying BOTH a viscoelastic element and a Syrope element (element 1
    !! Syrope, element 2 SLS mode-2) -- has_viscoelastic AND has_syrope both true,
    !! reachable via CD_Init_Model though not via a deck. All three nodes are held,
    !! so the step is a trivial converged fixed point and each element's internal
    !! state relaxes under its held stretch. This exercises the commit's four-pass
    !! structure (validate every model BEFORE mutating any) that keeps the two
    !! stateful models atomic: a failure in one cannot leave the other advanced.
    REAL(wp), PARAMETER :: L0E = 1.0_wp, EPS = 0.026_wp, DL = 0.03_wp, DT = 0.05_wp
    TYPE(CD_SyropeType) :: td, stype(2)
    TYPE(CD_ModelType) :: model
    TYPE(GenAlphaConfig) :: cfg
    INTEGER :: conn(2, 2), fixed(9), es, k, n_iter
    REAL(wp) :: l0(2), eav(2), rho_a(2), q0(9), v0(9), f_ext(9)
    REAL(wp) :: ve_ead(2), ve_ba(2), ve_bad(2), sslow(2), stmax(2)
    REAL(wp) :: tension(2), t_first(2)
    LOGICAL :: sis(2), conv, stalled
    CHARACTER(200) :: em
    CALL CD_Syrope_Init(td, OWC_EPS, OWC_TEN, CD_SYROPE_WC_LINEAR, 0.6_wp, 0.0_wp, &
                        ALPHA, BETA, C1, C2, es, em)
    CALL require(es == CD_SYROPE_OK, 'mixed:type-init')
    conn(:, 1) = [1, 2]
    conn(:, 2) = [2, 3]
    l0 = L0E
    eav = [1.0e8_wp, 100.0_wp]        ! element 1 masked (Syrope); element 2 = SLS series EA
    rho_a = 1.0_wp
    q0 = 0.0_wp
    q0(4) = L0E*(1.0_wp + EPS)         ! node 2: element 1 (Syrope) stretched by EPS
    q0(7) = q0(4) + L0E*(1.0_wp + DL)  ! node 3: element 2 (SLS) stretched by DL
    v0 = 0.0_wp
    f_ext = 0.0_wp
    fixed = [1, 2, 3, 4, 5, 6, 7, 8, 9]   ! all nodes held: frozen kinematics, states still relax
    sis = [.TRUE., .FALSE.]
    stype(1) = td
    stype(2) = td                       ! ignored where sis is .FALSE.
    sslow = [0.021_wp, 0.0_wp]
    stmax = [2.0e6_wp, 0.0_wp]
    ve_ead = [0.0_wp, 400.0_wp]         ! element 1 not viscoelastic; element 2 mode-2 Ed
    ve_ba = [0.0_wp, 7.0_wp]
    ve_bad = [0.0_wp, 3.0_wp]
    CALL CD_Init_Model(model, q0, v0, conn, l0, eav, rho_a, .FALSE., f_ext, fixed, cfg, es, em, &
                       ve_ea_d=ve_ead, ve_ba=ve_ba, ve_ba_d=ve_bad, &
                       syrope_is=sis, syrope_type=stype, syrope_slow0=sslow, syrope_tmax0=stmax)
    CALL require(es == CD_MODEL_OK, 'mixed:init: '//TRIM(em))
    DO k = 1, 6
      CALL CD_Step_Model(model, DT, conv, stalled, n_iter, es, em)
      CALL require(es == CD_MODEL_OK, 'mixed:step status: '//TRIM(em))
      CALL require(conv .AND. .NOT. stalled, 'mixed:step converges (four-pass commit runs)')
      CALL CD_Get_Model_Tension(model, tension, es, em)
      CALL require(es == CD_MODEL_OK, 'mixed:tension')
      CALL require(IEEE_IS_FINITE(tension(1)) .AND. IEEE_IS_FINITE(tension(2)), 'mixed:tension finite')
      CALL require(tension(1) > 0.0_wp .AND. tension(2) > 0.0_wp, 'mixed:both elements in tension')
      IF (k == 1) t_first = tension
    END DO
    ! the Syrope element's slow strain starts off its held fixed point, so its
    ! tension must move -- proof the Syrope state-advance pass ran alongside the
    ! viscoelastic pass without either erroring (the held VE element sits at its
    ! own steady partition, so its tension legitimately holds constant)
    CALL require(ABS(tension(1) - t_first(1)) > 0.0_wp, 'mixed:Syrope slow state advanced')
    CALL CD_End_Model(model, es, em)
    CALL CD_Syrope_End(td)
  END SUBROUTINE case_model_mixed_ve_syrope

  SUBROUTINE case_substeps_restore_law_states()
    !! The rotation-resolved sub-stepping of a model carrying a Syrope and a viscoelastic
    !! element (case_model_mixed_ve_syrope, the viscoelastic element 1000 times stiffer so that
    !! its law tension counts as taut against the 0.8 MN of the Syrope element), node 2 free and
    !! node 3 driven on a 0.4 m circle at 2 s, so the chords turn by more than a degree per
    !! 0.02 s step: solving the first
    !! sub-stepped pass twice, the second from the restored committed state (TEST-ONLY
    !! sub_test_repeat), changes nothing bit for bit, Syrope slow strain and running maximum and
    !! viscoelastic dl_1 included; a failing sub-step (TEST-ONLY sub_test_fail) returns the plain
    !! step, the run then equals the run with ei0_substeps off bit for bit.
    REAL(wp), PARAMETER :: L0E = 1.0_wp, EPS = 0.026_wp, DL = 0.03_wp, DT = 0.02_wp, R = 0.4_wp
    INTEGER, PARAMETER :: NSTEP = 40
    TYPE(CD_SyropeType) :: td, stype(2)
    TYPE(CD_ModelType) :: auto_m, rep_m, fb_m, off_m
    TYPE(GenAlphaConfig) :: cfg
    INTEGER :: conn(2, 2), fixed(6), es, k, n_iter
    REAL(wp) :: l0(2), eav(2), rho_a(2), q0(9), v0(9), f_ext(9), pq(9), pv(9), pa(9)
    REAL(wp) :: ve_ead(2), ve_ba(2), ve_bad(2), sslow(2), stmax(2), w, t, slow0(2), dl0(2)
    LOGICAL :: sis(2), conv, stalled, all_conv
    CHARACTER(200) :: em
    CALL CD_Syrope_Init(td, OWC_EPS, OWC_TEN, CD_SYROPE_WC_LINEAR, 0.6_wp, 0.0_wp, &
                        ALPHA, BETA, C1, C2, es, em)
    CALL require(es == CD_SYROPE_OK, 'substep-law:type-init')
    conn(:, 1) = [1, 2]
    conn(:, 2) = [2, 3]
    l0 = L0E
    eav = [1.0e8_wp, 1.0e5_wp]
    rho_a = 50.0_wp
    q0 = 0.0_wp
    q0(4) = L0E*(1.0_wp + EPS)
    q0(7) = q0(4) + L0E*(1.0_wp + DL)
    v0 = 0.0_wp
    f_ext = 0.0_wp
    fixed = [1, 2, 3, 7, 8, 9]
    sis = [.TRUE., .FALSE.]
    stype(1) = td
    stype(2) = td
    sslow = [0.021_wp, 0.0_wp]
    stmax = [2.0e6_wp, 0.0_wp]
    ve_ead = [0.0_wp, 4.0e5_wp]
    ve_ba = [0.0_wp, 7.0_wp]
    ve_bad = [0.0_wp, 3.0_wp]
    CALL CD_Init_Model(auto_m, q0, v0, conn, l0, eav, rho_a, .TRUE., f_ext, fixed, cfg, es, em, &
                       ve_ea_d=ve_ead, ve_ba=ve_ba, ve_ba_d=ve_bad, &
                       syrope_is=sis, syrope_type=stype, syrope_slow0=sslow, syrope_tmax0=stmax)
    CALL require(es == CD_MODEL_OK, 'substep-law:init: '//TRIM(em))
    IF (es /= CD_MODEL_OK) RETURN
    slow0 = auto_m%syrope_slow
    dl0 = auto_m%ve_dl_1
    CALL CD_Copy_Model(auto_m, rep_m, es, em)
    rep_m%sub_test_repeat = .TRUE.
    CALL CD_Copy_Model(auto_m, fb_m, es, em)
    fb_m%sub_test_fail = 1
    CALL CD_Copy_Model(auto_m, off_m, es, em)
    off_m%cfg%ei0_substeps = CD_EI0_SUBSTEPS_OFF
    w = 2.0_wp*ACOS(-1.0_wp)/2.0_wp
    all_conv = .TRUE.
    DO k = 1, NSTEP
      ! node 3 on the circle q0(7:9) + R ramp(t) (0, sin wt, 1 - cos wt), ramped over the first second
      t = REAL(k, wp)*DT
      CALL ramped_circle(t, q0, w, R, pq, pv, pa)
      CALL CD_Step_Model(auto_m, DT, conv, stalled, n_iter, es, em, prescribed_q=pq, prescribed_v=pv, prescribed_a=pa)
      all_conv = all_conv .AND. es == CD_MODEL_OK .AND. conv
      CALL CD_Step_Model(rep_m, DT, conv, stalled, n_iter, es, em, prescribed_q=pq, prescribed_v=pv, prescribed_a=pa)
      all_conv = all_conv .AND. es == CD_MODEL_OK .AND. conv
      CALL CD_Step_Model(fb_m, DT, conv, stalled, n_iter, es, em, prescribed_q=pq, prescribed_v=pv, prescribed_a=pa)
      all_conv = all_conv .AND. es == CD_MODEL_OK .AND. conv
      CALL CD_Step_Model(off_m, DT, conv, stalled, n_iter, es, em, prescribed_q=pq, prescribed_v=pv, prescribed_a=pa)
      all_conv = all_conv .AND. es == CD_MODEL_OK .AND. conv
    END DO
    WRITE (*, '(A,I0,A,I0,A,I0,A)') '  sub-steps with Syrope and viscoelastic states: ', auto_m%sub_stats%events, &
      ' of ', auto_m%sub_stats%calls, ' steps sub-stepped, ', fb_m%sub_stats%fallbacks, ' failing-sub-step fallbacks'
    CALL require(all_conv, 'substep-law:converged')
    CALL require(auto_m%sub_stats%events > 0, 'substep-law:sub-stepped')
    CALL require(ANY(auto_m%syrope_slow /= slow0) .AND. ANY(auto_m%ve_dl_1 /= dl0), 'substep-law:states-move')
    CALL require(ALL(rep_m%q == auto_m%q) .AND. ALL(rep_m%v == auto_m%v) .AND. ALL(rep_m%a == auto_m%a) .AND. &
                 ALL(rep_m%syrope_slow == auto_m%syrope_slow) .AND. &
                 ALL(rep_m%syrope_tmax == auto_m%syrope_tmax) .AND. ALL(rep_m%ve_dl_1 == auto_m%ve_dl_1), &
                 'substep-law:restore-is-complete')
    CALL require(fb_m%sub_stats%fallbacks > 0 .AND. ALL(fb_m%q == off_m%q) .AND. ALL(fb_m%v == off_m%v) .AND. &
                 ALL(fb_m%a == off_m%a) .AND. ALL(fb_m%syrope_slow == off_m%syrope_slow) .AND. &
                 ALL(fb_m%syrope_tmax == off_m%syrope_tmax) .AND. ALL(fb_m%ve_dl_1 == off_m%ve_dl_1), &
                 'substep-law:fallback-is-the-plain-step')
    CALL CD_End_Model(auto_m, es, em)
    CALL CD_End_Model(rep_m, es, em)
    CALL CD_End_Model(fb_m, es, em)
    CALL CD_End_Model(off_m, es, em)
    CALL CD_Syrope_End(td)
  END SUBROUTINE case_substeps_restore_law_states

  SUBROUTINE ramped_circle(time, q0, w, R, pq, pv, pa)
      !! Node 3 (DOFs 7:9) on the circle q0 + R ramp(t) (0, sin wt, 1 - cos wt), the C2 quintic
      !! ramp over the first second (case_substeps_restore_law_states).
    REAL(wp), INTENT(IN) :: time, q0(:), w, R
    REAL(wp), INTENT(OUT) :: pq(:), pv(:), pa(:)
    REAL(wp) :: u, r5, rd, rdd, g(2), gd(2), gdd(2)
    u = MIN(time, 1.0_wp)
    r5 = 10.0_wp*u**3 - 15.0_wp*u**4 + 6.0_wp*u**5
    rd = 0.0_wp
    rdd = 0.0_wp
    IF (time < 1.0_wp) THEN
      rd = 30.0_wp*u**2 - 60.0_wp*u**3 + 30.0_wp*u**4
      rdd = 60.0_wp*u - 180.0_wp*u**2 + 120.0_wp*u**3
    END IF
    g = R*[SIN(w*time), 1.0_wp - COS(w*time)]
    gd = R*w*[COS(w*time), SIN(w*time)]
    gdd = R*w*w*[-SIN(w*time), COS(w*time)]
    pq = q0
    pv = 0.0_wp
    pa = 0.0_wp
    pq(8:9) = q0(8:9) + r5*g
    pv(8:9) = rd*g + r5*gd
    pa(8:9) = rdd*g + 2.0_wp*rd*gd + r5*gdd
  END SUBROUTINE ramped_circle

  SUBROUTINE case_line_model_syrope()
    !! The line-object build path with the Syrope pass-through: a straight,
    !! zero-gravity Syrope line built through CD_Init_Line_Model (which runs the
    !! static solve with the OWC-secant EA) initializes at the working-curve
    !! tension for its geometric strain and steps with bounded, finite tension.
    REAL(wp), PARAMETER :: L0T = 2.0_wp, EPS0 = 0.025_wp
    TYPE(CD_SyropeType) :: td, stype(2)
    TYPE(CD_LineType) :: lts(1)
    TYPE(CD_LineSection) :: secs(1)
    TYPE(CD_ModelType) :: model
    TYPE(CableSolverConfig) :: scfg
    TYPE(GenAlphaConfig) :: dcfg
    REAL(wp) :: anchor(3), fairlead(3), factors(4)
    REAL(wp) :: t_ref, secant, fast_ref, slow0(2), tmax0(2), tension(2), t0
    LOGICAL :: sis(2), conv, stalled
    INTEGER :: es, k, n_iter
    CHARACTER(200) :: em
    CALL CD_Syrope_Init(td, OWC_EPS, OWC_TEN, CD_SYROPE_WC_LINEAR, 0.6_wp, 0.0_wp, &
                        ALPHA, BETA, C1, C2, es, em)
    CALL require(es == CD_SYROPE_OK, 'line:type-init')
    ! the working-curve tension at the geometric strain, and the OWC secant EA
    ! that makes the static solve land at exactly that strain
    CALL owc_interp(EPS0, t_ref)
    secant = t_ref/EPS0
    fast_ref = LOG(1.0_wp + BETA/ALPHA*t_ref)/BETA
    slow0 = EPS0 - fast_ref
    tmax0 = t_ref
    stype(1) = td; stype(2) = td
    sis = .TRUE.
    lts(1)%ea = secant
    lts(1)%mass_per_length = 22.42_wp
    lts(1)%diameter = 0.1438_wp
    lts(1)%ei = 0.0_wp
    secs(1)%line_type = 1
    secs(1)%length = L0T
    secs(1)%n_segments = 2
    anchor = [0.0_wp, 0.0_wp, 0.0_wp]
    fairlead = [L0T*(1.0_wp + EPS0), 0.0_wp, 0.0_wp]
    factors = [0.25_wp, 0.5_wp, 0.75_wp, 1.0_wp]
    ! high tension (~1.5 MN) dwarfs the line weight (~0.4 kN), so the taut line
    ! stays nearly straight and the geometric strain stays ~EPS0
    CALL CD_Init_Line_Model(model, anchor, fairlead, lts, secs, 9.80665_wp, 1025.0_wp, .FALSE., &
                            scfg, dcfg, factors, es, em, dynamic_tension_only=.TRUE., anchor_is_end_b=.TRUE., &
                            syrope_is=sis, syrope_type=stype, syrope_slow0=slow0, syrope_tmax0=tmax0)
    CALL require(es == CD_MODEL_OK, 'line:init: '//TRIM(em))
    IF (es /= CD_MODEL_OK) RETURN
    CALL CD_Get_Model_Tension(model, tension, es, em)
    CALL require(es == CD_MODEL_OK, 'line:tension')
    ! the near-straight geometry makes the IC close to the working-curve fixed
    ! point: the initial tension is T_ref to within the small-sag correction
    t0 = tension(1)
    CALL require(ABS(t0 - t_ref) <= 2.0e-2_wp*t_ref, 'line:ic-near-owc-tension')
    DO k = 1, 8
      CALL CD_Step_Model(model, 0.05_wp, conv, stalled, n_iter, es, em)
      CALL require(es == CD_MODEL_OK .AND. (conv .OR. stalled), 'line:step: '//TRIM(em))
      CALL CD_Get_Model_Tension(model, tension, es, em)
      CALL require(tension(1) > 0.0_wp .AND. tension(1) < 5.0e6_wp, 'line:tension-bounded')
      CALL require(ABS(tension(1) - t0) <= 3.0e-2_wp*t_ref, 'line:tension-stays-bounded')
    END DO
    CALL CD_End_Model(model, es, em)
    CALL CD_Syrope_End(td)
  END SUBROUTINE case_line_model_syrope

  SUBROUTINE case_admissibility()
    !! The fast spring must stay stiffer than the working curve (slope < alpha + beta*T)
    !! for the slow strain to be invertible. The shipped EXP constants are admissible
    !! only for T_max above ~7.4e5 N: init records that, and a regeneration below it
    !! names the condition, the offending tension and the next admissible T_max. A
    !! linear stiffness above alpha has no admissible T_max at all and fails at init;
    !! the EXP shape accepts only p2 > 0.
    TYPE(CD_SyropeType) :: td
    REAL(wp) :: ws(CD_SYROPE_NWC), wt(CD_SYROPE_NWC), wsl(CD_SYROPE_NWC)
    INTEGER :: es
    CHARACTER(200) :: em
    CALL CD_Syrope_Init(td, OWC_EPS, OWC_TEN, CD_SYROPE_WC_EXP, 0.2_wp, 1.5_wp, ALPHA, BETA, C1, C2, es, em)
    CALL require(es == CD_SYROPE_OK, 'adm:shipped-init')
    CALL CD_Syrope_Working_Curve(td, 5.0e5_wp, ws, wt, wsl, es, em)
    CALL require(es /= CD_SYROPE_OK .AND. INDEX(em, 'alpha + beta*T') > 0 .AND. &
                 INDEX(em, 'next admissible T_max') > 0, 'adm:low-tmax-names-condition: '//TRIM(em))
    CALL CD_Syrope_Working_Curve(td, 1.0e6_wp, ws, wt, wsl, es, em)
    CALL require(es == CD_SYROPE_OK, 'adm:high-tmax-ok')
    CALL CD_Syrope_Init(td, OWC_EPS, OWC_TEN, CD_SYROPE_WC_LINEAR, 2.0e8_wp, 0.0_wp, ALPHA, BETA, C1, C2, es, em)
    CALL require(es /= CD_SYROPE_OK .AND. INDEX(em, 'no running maximum') > 0 .AND. &
                 INDEX(em, 'alpha + beta*T') > 0, 'adm:stiff-linear-fails-at-init: '//TRIM(em))
    CALL CD_Syrope_Init(td, OWC_EPS, OWC_TEN, CD_SYROPE_WC_EXP, 0.2_wp, -1.5_wp, ALPHA, BETA, C1, C2, es, em)
    CALL require(es /= CD_SYROPE_OK .AND. INDEX(em, 'positive shape parameter p2') > 0, 'adm:exp-negative-p2')
    CALL CD_Syrope_End(td)
  END SUBROUTINE case_admissibility

  SUBROUTINE case_ic_rest_point()
    !! The rest-point slow strain (CD_Syrope_Slow_At_Mean) makes the static strain of
    !! a mean tension an exact fixed point of the kernel on both branches: the
    !! recovered mean tension and the total tension equal it to round-off and the
    !! slow-strain rate vanishes (the exact-log partition misses by up to ~1 %).
    TYPE(CD_SyropeType) :: td
    REAL(wp) :: ws(CD_SYROPE_NWC), wt(CD_SYROPE_NWC), wsl(CD_SYROPE_NWC)
    REAL(wp) :: eps0, t_ref, slow0, rate, ten, tm, st, fa, sl
    INTEGER :: es, k
    CHARACTER(200) :: em
    CALL CD_Syrope_Init(td, OWC_EPS, OWC_TEN, CD_SYROPE_WC_EXP, 0.2_wp, 1.5_wp, ALPHA, BETA, C1, C2, es, em)
    CALL require(es == CD_SYROPE_OK, 'rest:init')
    DO k = 1, 5
      ! the no-IC deck path: OWC frontier at the geometric strain
      eps0 = 0.012_wp + 0.009_wp*REAL(k - 1, wp)
      CALL owc_interp(eps0, t_ref)
      CALL CD_Syrope_Working_Curve(td, t_ref, ws, wt, wsl, es, em)
      CALL require(es == CD_SYROPE_OK, 'rest:owc-wc')
      slow0 = CD_Syrope_Slow_At_Mean(td, .FALSE., wt, wsl, t_ref)
      CALL require(.NOT. (slow0 < CD_Syrope_Slow_At_Tmax(td, t_ref)), 'rest:owc-branch')
      CALL CD_Syrope_Rate_And_Tension(td, .FALSE., ws, wt, wsl, slow0, eps0, 0.0_wp, rate, ten, tm, es, em)
      CALL require(ABS(tm - t_ref) <= 1.0e-10_wp*t_ref .AND. ABS(ten - t_ref) <= 1.0e-10_wp*t_ref, &
                   'rest:owc-tension-exact')
      CALL require(ABS(C1*rate) <= 1.0e-10_wp*t_ref, 'rest:owc-zero-rate')
    END DO
    ! the SYROPE IC path: Tmean0 below Tmax0 on the working curve
    CALL CD_Syrope_Working_Curve(td, 2.0e6_wp, ws, wt, wsl, es, em)
    slow0 = CD_Syrope_Slow_At_Mean(td, .TRUE., wt, wsl, 1.5e6_wp)
    CALL require(slow0 < CD_Syrope_Slow_At_Tmax(td, 2.0e6_wp), 'rest:wc-branch')
    CALL CD_Syrope_Find_Strains(td, .TRUE., ws, wt, 1.5e6_wp, st, fa, sl)
    CALL CD_Syrope_Rate_And_Tension(td, .TRUE., ws, wt, wsl, slow0, st, 0.0_wp, rate, ten, tm, es, em)
    CALL require(ABS(ten - 1.5e6_wp) <= 1.0e-10_wp*1.5e6_wp .AND. ABS(C1*rate) <= 1.0e-10_wp*1.5e6_wp, &
                 'rest:wc-tension-exact')
    CALL CD_Syrope_End(td)
  END SUBROUTINE case_ic_rest_point

  SUBROUTINE case_range_fail_closed()
    !! A state beyond the OWC table fails closed instead of clamping: the range check
    !! rejects a slow strain past the last row and (on the OWC branch) a total strain
    !! past the last row; a held element stretched beyond the table fails its first
    !! step with that message and leaves the committed state untouched, while an
    !! in-range held element steps normally.
    TYPE(CD_SyropeType) :: td, stype(1)
    TYPE(CD_ModelType) :: model
    TYPE(GenAlphaConfig) :: cfg
    REAL(wp) :: ws(CD_SYROPE_NWC), wt(CD_SYROPE_NWC), wsl(CD_SYROPE_NWC)
    REAL(wp) :: q0(6), v0(6), f_ext(6), l0(1), eav(1), rho_a(1), slow0(1), tmax0(1), s1(1), t1(1)
    REAL(wp) :: strains(2)
    INTEGER :: conn(2, 1), fixed(6), es, es2, n_iter, k
    LOGICAL :: sis(1), conv, stalled
    CHARACTER(200) :: em, em2
    CALL CD_Syrope_Init(td, OWC_EPS, OWC_TEN, CD_SYROPE_WC_EXP, 0.2_wp, 1.5_wp, ALPHA, BETA, C1, C2, es, em)
    CALL require(es == CD_SYROPE_OK, 'range:init')
    CALL CD_Syrope_Check_Range(td, td%owc_slow(30), es, em, eps=OWC_EPS(30))
    CALL require(es == CD_SYROPE_OK, 'range:last-row-ok')
    CALL CD_Syrope_Check_Range(td, td%owc_slow(30) + 1.0e-6_wp, es, em)
    CALL require(es /= CD_SYROPE_OK .AND. INDEX(em, 'left the OWC table') > 0, 'range:slow-beyond')
    CALL CD_Syrope_Check_Range(td, 0.02_wp, es, em, eps=0.061_wp)
    CALL require(es /= CD_SYROPE_OK .AND. INDEX(em, 'left the OWC table') > 0, 'range:strain-beyond')
    conn(:, 1) = [1, 2]
    fixed = [1, 2, 3, 4, 5, 6]
    l0 = 1.0_wp
    eav = 1.0e8_wp
    rho_a = 22.42_wp
    v0 = 0.0_wp
    f_ext = 0.0_wp
    sis = .TRUE.
    stype(1) = td
    tmax0 = 4.0e6_wp
    CALL CD_Syrope_Working_Curve(td, tmax0(1), ws, wt, wsl, es, em)
    slow0 = CD_Syrope_Slow_At_Mean(td, .FALSE., wt, wsl, tmax0(1))
    strains = [0.055_wp, 0.07_wp]
    DO k = 1, 2
      q0 = [0.0_wp, 0.0_wp, 0.0_wp, 1.0_wp + strains(k), 0.0_wp, 0.0_wp]
      CALL CD_Init_Model(model, q0, v0, conn, l0, eav, rho_a, .FALSE., f_ext, fixed, cfg, es, em, &
                         syrope_is=sis, syrope_type=stype, syrope_slow0=slow0, syrope_tmax0=tmax0)
      CALL require(es == CD_MODEL_OK, 'range:model-init: '//TRIM(em))
      CALL CD_Step_Model(model, 0.1_wp, conv, stalled, n_iter, es, em)
      CALL CD_Get_Model_Syrope_State(model, s1, t1, es2, em2)
      CALL require(es2 == CD_MODEL_OK, 'range:state-readable')
      IF (k == 1) THEN
        CALL require(es == CD_MODEL_OK, 'range:in-table-steps: '//TRIM(em))
      ELSE
        CALL require(es /= CD_MODEL_OK .AND. INDEX(em, 'left the OWC table') > 0, &
                     'range:beyond-table-step-fails: '//TRIM(em))
        CALL require(ABS(s1(1) - slow0(1)) <= 0.0_wp .AND. ABS(t1(1) - tmax0(1)) <= 0.0_wp, &
                     'range:failed-step-leaves-state')
      END IF
      CALL CD_End_Model(model, es, em)
    END DO
    CALL CD_Syrope_End(stype(1))
    CALL CD_Syrope_End(td)
  END SUBROUTINE case_range_fail_closed

  SUBROUTINE case_compressed_segment()
    !! MoorDyn-C drops the elastic mean tension of a compressed segment (eps < 0) and
    !! keeps only BA_s*d(eps_slow)/dt. With BA_d >> BA_s a shortened segment at rest
    !! therefore pushes (tension_only clamps it to zero) instead of pulling with
    !! ~T_mean; with BA_s = 0 the force vanishes identically; the compressive
    !! tangent (tension_only off) matches central differences.
    TYPE(CD_SyropeType) :: td
    REAL(wp) :: ws(CD_SYROPE_NWC), wt(CD_SYROPE_NWC), wsl(CD_SYROPE_NWC)
    REAL(wp) :: qa(3), qb(3), va(3), vb(3), x(6), f(6), fp(6), fm(6), jq(6, 6), jv(6, 6), jd(6, 6), jvd(6, 6)
    REAL(wp) :: slow, tm, ds, err
    INTEGER :: es, i, j
    CHARACTER(200) :: em
    CALL CD_Syrope_Init(td, OWC_EPS, OWC_TEN, CD_SYROPE_WC_EXP, 0.2_wp, 1.5_wp, ALPHA, BETA, &
                        1.0e7_wp, 1.0e9_wp, es, em)
    CALL require(es == CD_SYROPE_OK, 'comp:init')
    CALL CD_Syrope_Working_Curve(td, 2.0e6_wp, ws, wt, wsl, es, em)
    slow = CD_Syrope_Slow_At_Tmax(td, 2.0e6_wp) - 0.002_wp
    qa = 0.0_wp
    qb = [0.999_wp, 0.0_wp, 0.0_wp]
    va = 0.0_wp
    vb = 0.0_wp
    CALL CD_Syrope_Element_Load(qa, qb, va, vb, 1.0_wp, td, ws, wt, wsl, .TRUE., slow, .TRUE., &
                                f, jq, tm, ds, es, em, jac_v=jv)
    CALL require(es == CD_SYROPE_OK .AND. tm > 1.0e6_wp .AND. nan_max_abs(f) <= 0.0_wp, &
                 'comp:no-pull-on-shortened-segment')
    CALL CD_Syrope_Element_Load(qa, qb, va, vb, 1.0_wp, td, ws, wt, wsl, .TRUE., slow, .FALSE., &
                                f, jq, tm, ds, es, em, jac_v=jv)
    CALL require(close_rel(f(1), 1.0e7_wp*ds) .AND. f(1) < 0.0_wp, 'comp:damping-only-force')
    ! compressive tangent vs central FD (a moving skewed element), lagged and implicit
    qb = [0.995_wp, 0.03_wp, -0.02_wp]
    vb = [-0.01_wp, 0.004_wp, 0.002_wp]
    DO i = 0, 1
      CALL syrope_load_at(td, ws, wt, wsl, slow, qa, qb, va, vb, i == 1, f, jq, jv)
      err = 0.0_wp
      DO j = 1, 6
        x(1:3) = qa; x(4:6) = qb
        x(j) = x(j) + 1.0e-7_wp
        CALL syrope_load_at(td, ws, wt, wsl, slow, x(1:3), x(4:6), va, vb, i == 1, fp, jd, jvd)
        x(j) = x(j) - 2.0e-7_wp
        CALL syrope_load_at(td, ws, wt, wsl, slow, x(1:3), x(4:6), va, vb, i == 1, fm, jd, jvd)
        err = MAX(err, nan_max_abs(-(fp - fm)/2.0e-7_wp - jq(:, j))/MAX(1.0_wp, nan_max_abs(jq)))
      END DO
      CALL require(err < 1.0e-5_wp, 'comp:fd-position-jacobian')
    END DO
    ! BA_s = 0: a compressed segment carries no force at all
    CALL CD_Syrope_Init(td, OWC_EPS, OWC_TEN, CD_SYROPE_WC_EXP, 0.2_wp, 1.5_wp, ALPHA, BETA, &
                        0.0_wp, C2, es, em)
    CALL CD_Syrope_Working_Curve(td, 2.0e6_wp, ws, wt, wsl, es, em)
    CALL CD_Syrope_Element_Load(qa, [0.999_wp, 0.0_wp, 0.0_wp], va, [-0.01_wp, 0.0_wp, 0.0_wp], 1.0_wp, td, &
                                ws, wt, wsl, .TRUE., slow, .FALSE., f, jq, tm, ds, es, em, jac_v=jv, dt=0.1_wp)
    CALL require(es == CD_SYROPE_OK .AND. nan_max_abs(f) <= 0.0_wp, 'comp:zero-bas-no-force')
    CALL CD_Syrope_End(td)
  END SUBROUTINE case_compressed_segment

  SUBROUTINE syrope_load_at(td, ws, wt, wsl, slow, pa, pb, wa, wb, implicit, force, jac_q, jac_v)
    !! One unit-length WC-branch element load with tension_only off, at dt = 0.1 s when implicit.
    TYPE(CD_SyropeType), INTENT(IN) :: td
    REAL(wp), INTENT(IN) :: ws(CD_SYROPE_NWC), wt(CD_SYROPE_NWC), wsl(CD_SYROPE_NWC), slow
    REAL(wp), INTENT(IN) :: pa(3), pb(3), wa(3), wb(3)
    LOGICAL, INTENT(IN) :: implicit
    REAL(wp), INTENT(OUT) :: force(6), jac_q(6, 6), jac_v(6, 6)
    REAL(wp) :: t_mean, dslow
    INTEGER :: es
    CHARACTER(200) :: em
    IF (implicit) THEN
      CALL CD_Syrope_Element_Load(pa, pb, wa, wb, 1.0_wp, td, ws, wt, wsl, .TRUE., slow, .FALSE., &
                                  force, jac_q, t_mean, dslow, es, em, jac_v=jac_v, dt=0.1_wp)
    ELSE
      CALL CD_Syrope_Element_Load(pa, pb, wa, wb, 1.0_wp, td, ws, wt, wsl, .TRUE., slow, .FALSE., &
                                  force, jac_q, t_mean, dslow, es, em, jac_v=jac_v)
    END IF
    CALL require(es == CD_SYROPE_OK, 'comp:load-status')
  END SUBROUTINE syrope_load_at

  SUBROUTINE case_implicit_element()
    !! In-step elimination of the slow strain: with dt the element load solves the
    !! commit's backward-Euler equation itself. (a) Its slow_next is bit-identical to
    !! CD_Syrope_State_Advance at the same kinematics; (b) the force equals the
    !! committed-state force at slow_next bitwise (force felt == tension reported);
    !! (c) the implicit-function position and velocity tangents match central FD,
    !! on both branches, for the shipped and a moderate BA_s|BA_d pair.
    TYPE(CD_SyropeType) :: td
    REAL(wp) :: ws(CD_SYROPE_NWC), wt(CD_SYROPE_NWC), wsl(CD_SYROPE_NWC)
    REAL(wp) :: qa(3), qb(3), va(3), vb(3), x(6), vv(6), f(6), fc(6), fp(6), fm(6)
    REAL(wp) :: jq(6, 6), jv(6, 6), jd(6, 6), jvd(6, 6)
    REAL(wp) :: slow_n, slow_next, slow_adv, tm, tm2, ds, chord(3), length, eps, deps, errq, errv, h
    REAL(wp), PARAMETER :: DT = 0.1_wp
    REAL(wp) :: c1s(2), c2s(2)
    LOGICAL :: on_wc
    INTEGER :: es, i, j, ic, ib
    CHARACTER(200) :: em
    c1s = [C1, 1.0e8_wp]
    c2s = [C2, 2.0e8_wp]
    qa = [0.01_wp, -0.02_wp, 0.005_wp]
    qb = [1.02_wp, 0.12_wp, -0.08_wp]
    va = [0.001_wp, 0.002_wp, -0.001_wp]
    vb = [0.02_wp, -0.004_wp, 0.003_wp]
    DO ic = 1, 2
      CALL CD_Syrope_Init(td, OWC_EPS, OWC_TEN, CD_SYROPE_WC_EXP, 0.2_wp, 1.5_wp, ALPHA, BETA, &
                          c1s(ic), c2s(ic), es, em)
      CALL require(es == CD_SYROPE_OK, 'impl:init')
      DO ib = 1, 2
        ! WC branch: T_max 2 MN, mean 1.4 MN; OWC branch: T_max 1 MN, mean 1.3 MN
        on_wc = ib == 1
        IF (on_wc) THEN
          CALL CD_Syrope_Working_Curve(td, 2.0e6_wp, ws, wt, wsl, es, em)
          slow_n = CD_Syrope_Slow_At_Mean(td, .TRUE., wt, wsl, 1.4e6_wp)
        ELSE
          CALL CD_Syrope_Working_Curve(td, 1.0e6_wp, ws, wt, wsl, es, em)
          slow_n = CD_Syrope_Slow_At_Mean(td, .FALSE., wt, wsl, 1.3e6_wp)
        END IF
        CALL CD_Syrope_Element_Load(qa, qb, va, vb, 1.0_wp, td, ws, wt, wsl, on_wc, slow_n, .TRUE., &
                                    f, jq, tm, ds, es, em, jac_v=jv, dt=DT, slow_next=slow_next)
        CALL require(es == CD_SYROPE_OK .AND. slow_next > 0.0_wp, 'impl:load-ok: '//TRIM(em))
        chord = qb - qa
        length = NORM2(chord)
        eps = (length - 1.0_wp)/1.0_wp
        deps = DOT_PRODUCT(chord/length, vb - va)/1.0_wp
        CALL CD_Syrope_State_Advance(td, on_wc, ws, wt, wsl, slow_n, eps, deps, DT, slow_adv, tm2, es, em)
        CALL require(ABS(slow_adv - slow_next) <= 0.0_wp, 'impl:commit-bit-identical')
        CALL CD_Syrope_Element_Load(qa, qb, va, vb, 1.0_wp, td, ws, wt, wsl, on_wc, slow_next, .TRUE., &
                                    fc, jd, tm2, ds, es, em)
        CALL require(nan_max_abs(f - fc) <= 0.0_wp, 'impl:force-felt-equals-reported')
        h = 1.0e-7_wp
        errq = 0.0_wp
        errv = 0.0_wp
        DO j = 1, 6
          x(1:3) = qa; x(4:6) = qb
          x(j) = x(j) + h
          CALL CD_Syrope_Element_Load(x(1:3), x(4:6), va, vb, 1.0_wp, td, ws, wt, wsl, on_wc, slow_n, .TRUE., &
                                      fp, jd, tm2, ds, es, em, jac_v=jvd, dt=DT)
          x(j) = x(j) - 2.0_wp*h
          CALL CD_Syrope_Element_Load(x(1:3), x(4:6), va, vb, 1.0_wp, td, ws, wt, wsl, on_wc, slow_n, .TRUE., &
                                      fm, jd, tm2, ds, es, em, jac_v=jvd, dt=DT)
          DO i = 1, 6
            errq = MAX(errq, ABS(-(fp(i) - fm(i))/(2.0_wp*h) - jq(i, j))/MAX(1.0_wp, nan_max_abs(jq)))
          END DO
          vv(1:3) = va; vv(4:6) = vb
          vv(j) = vv(j) + h
          CALL CD_Syrope_Element_Load(qa, qb, vv(1:3), vv(4:6), 1.0_wp, td, ws, wt, wsl, on_wc, slow_n, .TRUE., &
                                      fp, jd, tm2, ds, es, em, jac_v=jvd, dt=DT)
          vv(j) = vv(j) - 2.0_wp*h
          CALL CD_Syrope_Element_Load(qa, qb, vv(1:3), vv(4:6), 1.0_wp, td, ws, wt, wsl, on_wc, slow_n, .TRUE., &
                                      fm, jd, tm2, ds, es, em, jac_v=jvd, dt=DT)
          DO i = 1, 6
            errv = MAX(errv, ABS(-(fp(i) - fm(i))/(2.0_wp*h) - jv(i, j))/MAX(1.0_wp, nan_max_abs(jv)))
          END DO
        END DO
        WRITE (*, '(A,I0,A,L1,A,ES9.2,A,ES9.2)') '  implicit tangent case ', ic, ' on_wc=', on_wc, &
          ' FD err q=', errq, ' v=', errv
        CALL require(errq < 1.0e-6_wp, 'impl:fd-position-jacobian')
        CALL require(errv < 1.0e-6_wp, 'impl:fd-velocity-jacobian')
      END DO
    END DO
    CALL CD_Syrope_End(td)
  END SUBROUTINE case_implicit_element

  SUBROUTINE case_implicit_dt_convergence()
    !! Replay of the prescribed-strain history eps(t) = 0.025 + 0.008 sin(2 pi t/10)
    !! through the in-step (implicit) element load and the step commit, with
    !! BA_s|BA_d = 1e8|2e8 (the pair where the former lagged slow state left a
    !! force-vs-report gap of ~3 % of the amplitude at dt = 0.1 s). The force the
    !! nodes feel equals the tension reported after the commit to round-off, and its
    !! error against a dt = 1e-4 s reference falls first-order with dt.
    REAL(wp), PARAMETER :: TEND = 30.0_wp, DT_REF = 1.0e-4_wp
    TYPE(CD_SyropeType) :: td
    REAL(wp), ALLOCATABLE :: ref(:)
    REAL(wp) :: err(3), gap(3), amp, dts(3)
    INTEGER :: es, k
    CHARACTER(200) :: em
    CALL CD_Syrope_Init(td, OWC_EPS, OWC_TEN, CD_SYROPE_WC_EXP, 0.2_wp, 1.5_wp, ALPHA, BETA, &
                        1.0e8_wp, 2.0e8_wp, es, em)
    CALL require(es == CD_SYROPE_OK, 'dtconv:init')
    ALLOCATE (ref(0:NINT(TEND/DT_REF)))
    ref = 0.0_wp
    CALL syrope_march(td, ref, DT_REF, .TRUE., err(1), gap(1), amp)
    dts = [0.4_wp, 0.2_wp, 0.1_wp]
    DO k = 1, 3
      CALL syrope_march(td, ref, dts(k), .FALSE., err(k), gap(k), amp)
      WRITE (*, '(A,F4.2,A,F8.4,A,ES9.2,A)') '  implicit Syrope dt=', dts(k), ' s: force error ', &
        100.0_wp*err(k)/amp, ' % amp, felt-vs-reported gap ', gap(k)/amp, ' amp'
      CALL require(gap(k) <= 1.0e-12_wp*amp, 'dtconv:force-felt-equals-reported')
    END DO
    CALL require(err(3) < 0.02_wp*amp, 'dtconv:dt0.1-error-small')
    CALL require(err(2)/err(1) > 0.35_wp .AND. err(2)/err(1) < 0.65_wp .AND. &
                 err(3)/err(2) > 0.35_wp .AND. err(3)/err(2) < 0.65_wp, 'dtconv:first-order')
    CALL CD_Syrope_End(td)
  END SUBROUTINE case_implicit_dt_convergence

  SUBROUTINE syrope_march(td, ref, dt, is_ref, max_err, max_gap, amplitude)
    !! March the prescribed-strain history through the in-step element load and the
    !! commit; fill ref (is_ref) or score the last period against it.
    REAL(wp), PARAMETER :: PER = 10.0_wp, TEND = 30.0_wp, DT_REF = 1.0e-4_wp, PI = 3.141592653589793_wp
    TYPE(CD_SyropeType), INTENT(IN) :: td
    REAL(wp), INTENT(INOUT) :: ref(0:)
    REAL(wp), INTENT(IN) :: dt
    LOGICAL, INTENT(IN) :: is_ref
    REAL(wp), INTENT(OUT) :: max_err, max_gap, amplitude
    REAL(wp) :: ws(CD_SYROPE_NWC), wt(CD_SYROPE_NWC), wsl(CD_SYROPE_NWC), f(6), jq(6, 6), fr(6)
    REAL(wp) :: slow, tmax, tt, eps, deps, tm, ds, slow_next, t_ref, divider
    INTEGER :: n, k2, n0, es
    LOGICAL :: on_wc
    CHARACTER(200) :: em
    n = NINT(TEND/dt)
    CALL owc_interp(prescribed_strain(0.0_wp), t_ref)
    tmax = t_ref
    CALL CD_Syrope_Working_Curve(td, tmax, ws, wt, wsl, es, em)
    slow = CD_Syrope_Slow_At_Mean(td, .FALSE., wt, wsl, t_ref)
    max_err = 0.0_wp
    max_gap = 0.0_wp
    amplitude = 0.0_wp
    DO k2 = 1, n
      tt = REAL(k2, wp)*dt
      eps = prescribed_strain(tt)
      deps = 0.008_wp*(2.0_wp*PI/PER)*COS(2.0_wp*PI*tt/PER)
      CALL CD_Syrope_Working_Curve(td, tmax, ws, wt, wsl, es, em)
      divider = CD_Syrope_Branch_Divider(td, tmax)
      on_wc = slow < divider
      ! the converged in-step force (implicit elimination) at t_{n+1}
      CALL CD_Syrope_Element_Load([0.0_wp, 0.0_wp, 0.0_wp], [1.0_wp + eps, 0.0_wp, 0.0_wp], &
                                  [0.0_wp, 0.0_wp, 0.0_wp], [deps, 0.0_wp, 0.0_wp], 1.0_wp, td, ws, wt, wsl, &
                                  on_wc, slow, .TRUE., f, jq, tm, ds, es, em, dt=dt, slow_next=slow_next, &
                                  divider=divider)
      CALL require(es == CD_SYROPE_OK, 'dtconv:load-status')
      ! commit: the slow strain the force used, then the running-max ratchet
      slow = slow_next
      IF (tm > tmax) tmax = tm
      ! the tension reported at the committed state
      CALL CD_Syrope_Working_Curve(td, tmax, ws, wt, wsl, es, em)
      divider = CD_Syrope_Branch_Divider(td, tmax)
      on_wc = slow < divider
      CALL CD_Syrope_Element_Load([0.0_wp, 0.0_wp, 0.0_wp], [1.0_wp + eps, 0.0_wp, 0.0_wp], &
                                  [0.0_wp, 0.0_wp, 0.0_wp], [deps, 0.0_wp, 0.0_wp], 1.0_wp, td, ws, wt, wsl, &
                                  on_wc, slow, .TRUE., fr, jq, tm, ds, es, em, divider=divider)
      IF (is_ref) THEN
        ref(k2) = fr(1)
      ELSE IF (tt >= TEND - PER - 1.0e-9_wp) THEN
        max_err = MAX(max_err, ABS(f(1) - ref(NINT(tt/DT_REF))))
        max_gap = MAX(max_gap, ABS(f(1) - fr(1)))
      END IF
    END DO
    ! the reference's last-period half range
    n0 = NINT((TEND - PER)/DT_REF)
    IF (.NOT. is_ref) amplitude = 0.5_wp*(MAXVAL(ref(n0:)) - MINVAL(ref(n0:)))
  END SUBROUTINE syrope_march

  PURE REAL(wp) FUNCTION prescribed_strain(tt) RESULT(e)
    !! eps(t) = 0.025 + 0.008 sin(2 pi t / 10)
    REAL(wp), PARAMETER :: PER = 10.0_wp, PI = 3.141592653589793_wp
    REAL(wp), INTENT(IN) :: tt
    e = 0.025_wp + 0.008_wp*SIN(2.0_wp*PI*tt/PER)
  END FUNCTION prescribed_strain

  SUBROUTINE owc_interp(x, y)
    !! Piecewise-linear interpolation on the OWC strain->tension table (the same
    !! numpy.interp semantics the kernel uses), for the test's reference tension.
    REAL(wp), INTENT(IN) :: x
    REAL(wp), INTENT(OUT) :: y
    INTEGER :: i
    IF (x <= OWC_EPS(1)) THEN; y = OWC_TEN(1); RETURN; END IF
    IF (x >= OWC_EPS(30)) THEN; y = OWC_TEN(30); RETURN; END IF
    DO i = 2, 30
      IF (x <= OWC_EPS(i)) THEN
        y = OWC_TEN(i - 1) + (OWC_TEN(i) - OWC_TEN(i - 1))*(x - OWC_EPS(i - 1))/(OWC_EPS(i) - OWC_EPS(i - 1))
        RETURN
      END IF
    END DO
    y = OWC_TEN(30)
  END SUBROUTINE owc_interp

END PROGRAM test_syrope
