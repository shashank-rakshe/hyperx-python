! File: tests/test_finite_ei_model.f90
! SPDX-License-Identifier: Apache-2.0
! Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
PROGRAM test_finite_ei_model
  !! Product-boundary checks for CableDyn_FiniteEIModel. The numerical finite-EI
  !! formulation is validated in the Cosserat dynamic L1 gates; this test pins the
  !! lifecycle wrapper: init, load replacement, step, state copy, energy query, bad
  !! input rejection, and idempotent cleanup.
  USE CableDyn_Precision, ONLY: wp
  USE CableDyn_Dynamic, ONLY: CD_DYN_OK, GenAlphaConfig
  USE CableDyn_FiniteEIModel, ONLY: CD_FiniteEIModelType, CD_Init_FiniteEI_Model, &
                                    CD_Step_FiniteEI_Model, CD_Set_FiniteEI_Model_Load, &
                                    CD_Set_FiniteEI_Model_PrescribedDofs, CD_Get_FiniteEI_Model_State, &
                                    CD_FiniteEI_Model_Energy, &
                                    CD_FiniteEI_Model_Is_Initialized, CD_End_FiniteEI_Model
  IMPLICIT NONE

  INTEGER, PARAMETER :: NE = 3, NN = NE + 1, NDOF = 6*NN
  REAL(wp), PARAMETER :: EA0 = 1.0e5_wp, GAS0 = 5.0e4_wp, EI0 = 2.0e3_wp, GJ0 = 1.0e3_wp
  REAL(wp), PARAMETER :: RHOA0 = 10.0_wp, IRT0 = 1.0e-2_wp, IRN0 = 2.0e-2_wp
  TYPE(CD_FiniteEIModelType) :: model, compressed_model
  REAL(wp) :: nodes_ref(3, NN), ea(NE), gas(NE), ei(NE), gj(NE), rho_a(NE), i_rt(NE), i_rn(NE)
  REAL(wp) :: q0(NDOF), q(NDOF), v(NDOF), a(NDOF), q_save(NDOF), v_save(NDOF), a_save(NDOF), f_ext(NDOF)
  REAL(wp) :: strain_e, kinetic_e
  INTEGER :: conn(2, NE), fixed_positions(3*NN), nfail, i, es, n_iter
  LOGICAL :: converged, stalled
  CHARACTER(200) :: em

  nfail = 0
  CALL build_case()

  q = 123.0_wp
  v = 456.0_wp
  a = 789.0_wp
  CALL CD_Get_FiniteEI_Model_State(model, q, v, a, es, em)
  CALL require(es /= CD_DYN_OK .AND. nan_max_abs(q) < 1.0e-12_wp .AND. &
               nan_max_abs(v) < 1.0e-12_wp .AND. nan_max_abs(a) < 1.0e-12_wp, &
               'state:uninit-zeroes-outputs')

  CALL CD_Init_FiniteEI_Model(model, nodes_ref, conn, ea, gas, ei, gj, rho_a, i_rt, i_rn, &
                              .TRUE., es, em, fixed_dofs=[0])
  CALL require(es /= CD_DYN_OK .AND. .NOT. CD_FiniteEI_Model_Is_Initialized(model), &
               'init:reject-out-of-range-fixed-dof')
  CALL CD_Init_FiniteEI_Model(model, nodes_ref, conn, ea, gas, ei, gj, rho_a, i_rt, i_rn, &
                              .TRUE., es, em, fixed_dofs=[1, 1])
  CALL require(es /= CD_DYN_OK .AND. .NOT. CD_FiniteEI_Model_Is_Initialized(model), &
               'init:reject-duplicate-fixed-dof')

  CALL CD_Init_FiniteEI_Model(model, nodes_ref, conn, ea, gas, ei, gj, rho_a, i_rt, i_rn, &
                              .TRUE., es, em, fixed_dofs=[1, 2, 3, 4, 5, 6])
  CALL require(es == CD_DYN_OK .AND. CD_FiniteEI_Model_Is_Initialized(model), 'init:straight-clamped')
  CALL require(ALLOCATED(model%q_step) .AND. ALLOCATED(model%v_step) .AND. ALLOCATED(model%a_step), &
               'init:persistent-step-workspace')
  CALL require(ALLOCATED(model%energy_mass_work), 'init:persistent-energy-workspace')
  CALL require(ALLOCATED(model%dynamic_workspace%fint_eval) .AND. ALLOCATED(model%dynamic_workspace%Mb), &
               'init:persistent-cosserat-accel-workspace')
  CALL require(ALLOCATED(model%dynamic_workspace%assembly%fe), 'init:persistent-cosserat-assembly-workspace')

  CALL CD_Get_FiniteEI_Model_State(model, q, v, a, es, em)
  CALL require(es == CD_DYN_OK, 'state:get-after-init')
  CALL require(nan_max_abs(q - q0) < 1.0e-14_wp, 'state:reference-q')
  CALL require(nan_max_abs(v) < 1.0e-14_wp .AND. nan_max_abs(a) < 1.0e-14_wp, 'state:zero-v-a')

  CALL CD_FiniteEI_Model_Energy(model, strain_e, kinetic_e, es, em)
  CALL require(es == CD_DYN_OK .AND. ABS(strain_e) < 1.0e-12_wp .AND. ABS(kinetic_e) < 1.0e-12_wp, &
               'energy:zero-at-reference')

  CALL CD_Step_FiniteEI_Model(model, 0.01_wp, converged, stalled, n_iter, es, em)
  CALL require(es == CD_DYN_OK .AND. converged .AND. .NOT. stalled, 'step:fixed-point-converged')
  CALL require(ALLOCATED(model%dynamic_workspace%q_n) .AND. ALLOCATED(model%dynamic_workspace%eff_band), &
               'step:persistent-cosserat-workspace')
  CALL require(ALLOCATED(model%dynamic_workspace%assembly%Ke), 'step:persistent-cosserat-tangent-workspace')
  CALL CD_Get_FiniteEI_Model_State(model, q, v, a, es, em)
  CALL require(es == CD_DYN_OK .AND. nan_max_abs(q - q0) < 1.0e-12_wp, 'step:fixed-point-q')
  CALL require(nan_max_abs(v) < 1.0e-12_wp .AND. nan_max_abs(a) < 1.0e-12_wp, 'step:fixed-point-v-a')

  q_save = q
  v_save = v
  a_save = a
  model%reject_axial_compression = .TRUE.
  model%q(9) = model%q(9) - 0.05_wp
  CALL CD_Step_FiniteEI_Model(model, 0.01_wp, converged, stalled, n_iter, es, em)
  CALL require(es /= CD_DYN_OK .AND. .NOT. converged .AND. INDEX(em, 'axial compression') > 0, &
               'step:reject-compressed-finite-ei-cable')
  model%reject_axial_compression = .FALSE.
  model%q = q_save
  model%v = v_save
  model%a = a_save

  ! The committed state can be tensile while prescribed motion makes the
  ! candidate state compressive.  The post-step guard must reject that candidate
  ! and preserve the complete t_n state.
  DO i = 1, NN
    fixed_positions(3*i - 2:3*i) = [6*i - 5, 6*i - 4, 6*i - 3]
  END DO
  CALL CD_Init_FiniteEI_Model(compressed_model, nodes_ref, conn, ea, gas, ei, gj, rho_a, i_rt, i_rn, &
                              .TRUE., es, em, fixed_dofs=fixed_positions)
  CALL require(es == CD_DYN_OK, 'step:post-compression-model-init')
  CALL CD_Get_FiniteEI_Model_State(compressed_model, q, v, a, es, em)
  q_save = q
  v_save = v
  a_save = a
  q(NDOF - 3) = q(NDOF - 3) - 0.2_wp
  compressed_model%reject_axial_compression = .TRUE.
  CALL CD_Step_FiniteEI_Model(compressed_model, 0.01_wp, converged, stalled, n_iter, es, em, &
                              q_fixed_target=q, v_fixed_target=v, a_fixed_target=a)
  CALL require(es /= CD_DYN_OK .AND. .NOT. converged .AND. INDEX(em, 'axial compression') > 0, &
               'step:reject-newly-compressed-candidate')
  CALL CD_Get_FiniteEI_Model_State(compressed_model, q, v, a, es, em)
  CALL require(es == CD_DYN_OK .AND. nan_max_abs(q - q_save) < 1.0e-14_wp .AND. &
               nan_max_abs(v - v_save) < 1.0e-14_wp .AND. nan_max_abs(a - a_save) < 1.0e-14_wp, &
               'step:post-compression-reject-preserves-state')
  CALL CD_End_FiniteEI_Model(compressed_model, es, em)

  CALL CD_Step_FiniteEI_Model(model, 0.0_wp, converged, stalled, n_iter, es, em)
  CALL require(es /= CD_DYN_OK .AND. .NOT. converged, 'step:reject-zero-dt')
  CALL CD_Get_FiniteEI_Model_State(model, q, v, a, es, em)
  CALL require(es == CD_DYN_OK, 'step:state-query-after-zero-dt-reject')
  CALL require(nan_max_abs(q - q_save) < 1.0e-14_wp, 'step:zero-dt-reject-preserves-q')
  CALL require(nan_max_abs(v - v_save) < 1.0e-14_wp, 'step:zero-dt-reject-preserves-v')
  CALL require(nan_max_abs(a - a_save) < 1.0e-14_wp, 'step:zero-dt-reject-preserves-a')

  ! moving-support contract: a partial target set (v without q) fails closed rather than
  ! silently taking the held branch and dropping the supplied velocity.
  q_save = q
  v_save = v
  a_save = a
  CALL CD_Step_FiniteEI_Model(model, 0.01_wp, converged, stalled, n_iter, es, em, v_fixed_target=v)
  CALL require(es /= CD_DYN_OK .AND. .NOT. converged, 'step:reject-partial-fixed-target')
  CALL CD_Get_FiniteEI_Model_State(model, q, v, a, es, em)
  CALL require(es == CD_DYN_OK, 'step:state-query-after-reject')
  CALL require(nan_max_abs(q - q_save) < 1.0e-14_wp, 'step:reject-preserves-q')
  CALL require(nan_max_abs(v - v_save) < 1.0e-14_wp, 'step:reject-preserves-v')
  CALL require(nan_max_abs(a - a_save) < 1.0e-14_wp, 'step:reject-preserves-a')

  CALL CD_Step_FiniteEI_Model(model, 0.01_wp, converged, stalled, n_iter, es, em, &
                              q_fixed_target=q(1:NDOF - 1), v_fixed_target=v, a_fixed_target=a)
  CALL require(es /= CD_DYN_OK .AND. .NOT. converged, 'step:reject-bad-fixed-target-shape')
  CALL CD_Get_FiniteEI_Model_State(model, q, v, a, es, em)
  CALL require(es == CD_DYN_OK, 'step:state-query-after-bad-target-shape')
  CALL require(nan_max_abs(q - q_save) < 1.0e-14_wp, 'step:bad-target-shape-preserves-q')
  CALL require(nan_max_abs(v - v_save) < 1.0e-14_wp, 'step:bad-target-shape-preserves-v')
  CALL require(nan_max_abs(a - a_save) < 1.0e-14_wp, 'step:bad-target-shape-preserves-a')

  f_ext = 0.0_wp
  f_ext(NDOF - 5) = 1.0_wp
  CALL CD_Set_FiniteEI_Model_Load(model, f_ext, es, em)
  CALL require(es == CD_DYN_OK, 'load:set-and-recompute')
  CALL CD_Get_FiniteEI_Model_State(model, q, v, a, es, em)
  CALL require(es == CD_DYN_OK .AND. nan_max_abs(a) > 1.0e-10_wp, 'load:nonzero-consistent-accel')

  q_save = q
  v_save = v
  a_save = a
  CALL CD_Set_FiniteEI_Model_Load(model, f_ext(1:NDOF - 1), es, em)
  CALL require(es /= CD_DYN_OK, 'load:reject-short-vector')
  CALL CD_Get_FiniteEI_Model_State(model, q, v, a, es, em)
  CALL require(es == CD_DYN_OK, 'load:state-query-after-short-vector')
  CALL require(nan_max_abs(q - q_save) < 1.0e-14_wp, 'load:short-vector-reject-preserves-q')
  CALL require(nan_max_abs(v - v_save) < 1.0e-14_wp, 'load:short-vector-reject-preserves-v')
  CALL require(nan_max_abs(a - a_save) < 1.0e-14_wp, 'load:short-vector-reject-preserves-a')

  q_save = q
  v_save = v
  a_save = a
  CALL CD_Set_FiniteEI_Model_PrescribedDofs(model, [4], [4.0_wp], [0.0_wp], [0.0_wp], es, em)
  CALL require(es /= CD_DYN_OK, 'prescribed:reject-out-of-chart-rotation')
  CALL CD_Get_FiniteEI_Model_State(model, q, v, a, es, em)
  CALL require(es == CD_DYN_OK, 'prescribed:state-query-after-reject')
  CALL require(nan_max_abs(q - q_save) < 1.0e-14_wp, 'prescribed:reject-preserves-q')
  CALL require(nan_max_abs(v - v_save) < 1.0e-14_wp, 'prescribed:reject-preserves-v')
  CALL require(nan_max_abs(a - a_save) < 1.0e-14_wp, 'prescribed:reject-preserves-a')

  CALL CD_Set_FiniteEI_Model_PrescribedDofs(model, [1, 1], [1.0_wp, 2.0_wp], [0.0_wp, 0.0_wp], &
                                            [0.0_wp, 0.0_wp], es, em)
  CALL require(es /= CD_DYN_OK, 'prescribed:reject-duplicate-dof')
  CALL CD_Get_FiniteEI_Model_State(model, q, v, a, es, em)
  CALL require(es == CD_DYN_OK, 'prescribed:state-query-after-duplicate-reject')
  CALL require(nan_max_abs(q - q_save) < 1.0e-14_wp, 'prescribed:duplicate-reject-preserves-q')
  CALL require(nan_max_abs(v - v_save) < 1.0e-14_wp, 'prescribed:duplicate-reject-preserves-v')
  CALL require(nan_max_abs(a - a_save) < 1.0e-14_wp, 'prescribed:duplicate-reject-preserves-a')

  q_save = q
  ei(1) = -EI0
  CALL CD_Init_FiniteEI_Model(model, nodes_ref, conn, ea, gas, ei, gj, rho_a, i_rt, i_rn, .TRUE., es, em)
  CALL require(es /= CD_DYN_OK .AND. CD_FiniteEI_Model_Is_Initialized(model), 'init:bad-reinit-preserves-model')
  CALL CD_Get_FiniteEI_Model_State(model, q, v, a, es, em)
  CALL require(es == CD_DYN_OK .AND. nan_max_abs(q - q_save) < 1.0e-14_wp, 'init:bad-reinit-preserves-q')
  ei(1) = EI0

  CALL CD_End_FiniteEI_Model(model, es, em)
  CALL require(es == CD_DYN_OK .AND. .NOT. CD_FiniteEI_Model_Is_Initialized(model), 'end:cleanup')
  CALL require(.NOT. ALLOCATED(model%q_step) .AND. .NOT. ALLOCATED(model%v_step) .AND. &
               .NOT. ALLOCATED(model%a_step), 'end:releases-step-workspace')
  CALL require(.NOT. ALLOCATED(model%energy_mass_work), 'end:releases-energy-workspace')
  CALL require(.NOT. ALLOCATED(model%dynamic_workspace%q_n) .AND. &
               .NOT. ALLOCATED(model%dynamic_workspace%eff_band) .AND. &
               .NOT. ALLOCATED(model%dynamic_workspace%fint_eval) .AND. &
               .NOT. ALLOCATED(model%dynamic_workspace%Mb) .AND. &
               .NOT. ALLOCATED(model%dynamic_workspace%assembly%fe) .AND. &
               .NOT. ALLOCATED(model%dynamic_workspace%assembly%Ke), 'end:releases-cosserat-workspace')
  CALL CD_End_FiniteEI_Model(model, es, em)
  CALL require(es == CD_DYN_OK .AND. .NOT. CD_FiniteEI_Model_Is_Initialized(model), 'end:idempotent')

  ei(1) = -EI0
  CALL CD_Init_FiniteEI_Model(model, nodes_ref, conn, ea, gas, ei, gj, rho_a, i_rt, i_rn, .TRUE., es, em)
  CALL require(es /= CD_DYN_OK .AND. .NOT. CD_FiniteEI_Model_Is_Initialized(model), 'init:reject-negative-ei')

  CALL check_multiplicative_ic()

  IF (nfail > 0) THEN
    WRITE (*, '(A,I0,A)') 'FAIL: ', nfail, ' assertion(s) failed'
    ERROR STOP 1
  END IF
  WRITE (*, '(A)') 'PASS: finite-EI dynamic model lifecycle is well formed'

CONTAINS

  INCLUDE 'nan_max_abs.inc'

  SUBROUTINE check_multiplicative_ic()
    !! Review hardening (model wiring): with cfg%multiplicative_rotation = .TRUE. the model wrapper must
    !! pass v + multiplicative into CD_Cosserat_Initial_Acceleration, so a free asymmetric spin's
    !! initial acceleration is the Euler accel alpha = -I_s^{-1}(omega x I_s omega), not the
    !! frozen-mass zero. Free rod along z (Lam0 = I -> I_s = diag(it,it,in) at theta = 0).
    TYPE(GenAlphaConfig) :: cfg
    REAL(wp) :: v0(NDOF), w(3), euler(3), Iw(3), r(3)
    REAL(wp), PARAMETER :: IT = 10.0_wp, IN_ = 20.0_wp
    INTEGER :: j
    DO j = 1, NE
      conn(:, j) = [j, j + 1]
      ea(j) = EA0; gas(j) = GAS0; ei(j) = EI0; gj(j) = GJ0
      rho_a(j) = RHOA0; i_rt(j) = IT; i_rn(j) = IN_
    END DO
    w = [0.7_wp, -0.5_wp, 0.9_wp]               ! asymmetric: transverse AND axial components
    v0 = 0.0_wp
    DO j = 1, NN
      r = [0.0_wp, 0.0_wp, REAL(j - 1, wp)]
      nodes_ref(:, j) = r
      v0(6*j - 5:6*j - 3) = cross3(w, r)
      v0(6*j - 2:6*j) = w
    END DO
    cfg%multiplicative_rotation = .TRUE.
    CALL CD_Init_FiniteEI_Model(model, nodes_ref, conn, ea, gas, ei, gj, rho_a, i_rt, i_rn, &
                                .TRUE., es, em, v0=v0, cfg=cfg)
    CALL require(es == CD_DYN_OK, 'mult-ic:model-init-ok: '//TRIM(em))
    CALL CD_Get_FiniteEI_Model_State(model, q, v, a, es, em)
    CALL require(es == CD_DYN_OK, 'mult-ic:get-state-ok')
    Iw = [IT*w(1), IT*w(2), IN_*w(3)]
    euler = -cross3(w, Iw)
    euler = [euler(1)/IT, euler(2)/IT, euler(3)/IN_]
    DO j = 1, NN
      CALL require(nan_max_abs(a(6*j - 2:6*j) - euler) < 1.0e-9_wp, 'mult-ic:model-a-is-euler-acceleration')
    END DO
    CALL CD_End_FiniteEI_Model(model, es, em)
  END SUBROUTINE check_multiplicative_ic

  PURE FUNCTION cross3(p, b) RESULT(c)
    REAL(wp), INTENT(IN) :: p(3), b(3)
    REAL(wp) :: c(3)
    c = [p(2)*b(3) - p(3)*b(2), p(3)*b(1) - p(1)*b(3), p(1)*b(2) - p(2)*b(1)]
  END FUNCTION cross3

  SUBROUTINE build_case()
    !! Build a straight, clamped-free finite-EI line at its reference state.
    DO i = 1, NN
      nodes_ref(:, i) = [0.0_wp, 0.0_wp, REAL(i - 1, wp)]
      q0(6*i - 5:6*i - 3) = nodes_ref(:, i)
      q0(6*i - 2:6*i) = 0.0_wp
    END DO
    DO i = 1, NE
      conn(:, i) = [i, i + 1]
      ea(i) = EA0
      gas(i) = GAS0
      ei(i) = EI0
      gj(i) = GJ0
      rho_a(i) = RHOA0
      i_rt(i) = IRT0
      i_rn(i) = IRN0
    END DO
  END SUBROUTINE build_case

  SUBROUTINE require(cond, label)
    !! Record assertion failures without stopping at the first mismatch.
    LOGICAL, INTENT(IN) :: cond
    CHARACTER(*), INTENT(IN) :: label
    IF (.NOT. cond) THEN
      WRITE (*, '(A,A,A)') 'MISMATCH [', label, ']: condition false'
      nfail = nfail + 1
    END IF
  END SUBROUTINE require

END PROGRAM test_finite_ei_model
