! File: tests/test_core_release_regressions.f90
! SPDX-License-Identifier: Apache-2.0
! Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
PROGRAM test_core_release_regressions
  !! Failure-path contracts of the numerical core:
  !!   1. The system subdivision fallback restores the complete committed line state
  !!      (kinematics AND viscoelastic / Syrope history) when it cannot complete an
  !!      interval, so its best-effort result equals one plain full-dt step; after an
  !!      active-line-control length change that includes the committed lengths.
  !!   1b. A re-derived acceleration between a length change and the next step (the
  !!      model's recompute, and the system update the OpenFAST shell performs) belongs to
  !!      the committed state: it is solved at the committed lengths, which stay committed, so
  !!      the step still blends the old and new lengths.
  !!   2. A segment-length update whose acceleration recompute fails leaves the model
  !!      exactly as it was (lengths, rates, loads, mass, acceleration).
  !!   3. An ElasticMod 3 rope whose alphaMBL does not exceed the static EA fails at
  !!      init even when the initial state is taut.
  !!   4. Formatted diagnostics truncate into a short caller buffer instead of
  !!      aborting the program.
  !!   5. Local axial refinement of a genuinely compressive equilibrium stops and
  !!      fails closed instead of growing the mesh geometrically.
  !!   6. Wheeler stretching fails closed when the wave trough reaches the seabed.
  !!   7. A one-sample static stall window is rejected.
  USE CableDyn_Precision, ONLY: wp
  USE CableDyn_Dynamic, ONLY: GenAlphaConfig
  USE CableDyn_Static, ONLY: CableSolverConfig, CD_Static_Cable_Solve, CD_STATIC_BADINPUT
  USE CableDyn_Syrope, ONLY: CD_SyropeType, CD_Syrope_Init, CD_Syrope_End, CD_SYROPE_OK, CD_SYROPE_WC_LINEAR
  USE CableDyn_Model, ONLY: CD_ModelType, CD_Init_Model, CD_Step_Model, CD_Step_Model_Recovering, &
                            CD_End_Model, CD_Get_Model_State, CD_Get_Model_VE_Dl1, &
                            CD_Get_Model_Syrope_State, CD_Update_Model_SegmentLength, &
                            CD_Recompute_Model_Acceleration, CD_MODEL_OK, CD_MODEL_BADINPUT
  USE CableDyn_System, ONLY: CD_SystemType, CD_Init_System_From_Models, CD_End_System, CD_Step_System, &
                             CD_Get_System_CoupledMotion, CD_System_NCoupledDOF, CD_Get_System_Line_State, &
                             CD_Get_System_Line_VE_Dl1, CD_Get_System_Line_Syrope_State, &
                             CD_System_Fallback_Count, CD_System_Fallback_Reset, CD_SYSTEM_OK, &
                             CD_Update_System_Line_SegmentLength, CD_Update_System_CoupledMotion, &
                             CD_Recompute_System_Acceleration
  USE CableDyn_Hydro, ONLY: CD_Airy_Wave_Kinematics_Precomputed, CD_HYDRO_OK, CD_HYDRO_BADINPUT
  USE CableDyn_HermiteCableStatic, ONLY: CD_HermiteCable_Static_Solve, CD_HermiteCable_Static_Solve_AutoMesh, &
                                         CD_HermiteCable_Trivial_Seed, CD_HermiteResolutionType, &
                                         CD_HCSTAT_OK, CD_HCSTAT_NOCONVERGE, CD_HC_REFINE_CAP
  USE, INTRINSIC :: IEEE_ARITHMETIC, ONLY: IEEE_IS_FINITE
  USE, INTRINSIC :: IEEE_EXCEPTIONS, ONLY: IEEE_USUAL, IEEE_GET_HALTING_MODE, IEEE_SET_HALTING_MODE, IEEE_SET_FLAG
  IMPLICIT NONE
  LOGICAL :: fp_halt(3)   ! saved IEEE halting modes around deliberately non-finite inputs

  REAL(wp), PARAMETER :: OWC_EPS(30) = [0.00000e+00_wp, 2.06897e-03_wp, 4.13793e-03_wp, &
                                        6.20690e-03_wp, 8.27586e-03_wp, 1.03448e-02_wp, 1.24138e-02_wp, &
                                        1.44828e-02_wp, 1.65517e-02_wp, 1.86207e-02_wp, 2.06897e-02_wp, &
                                        2.27586e-02_wp, 2.48276e-02_wp, 2.68966e-02_wp, 2.89655e-02_wp, &
                                        3.10345e-02_wp, 3.31034e-02_wp, 3.51724e-02_wp, 3.72414e-02_wp, &
                                        3.93103e-02_wp, 4.13793e-02_wp, 4.34483e-02_wp, 4.55172e-02_wp, &
                                        4.75862e-02_wp, 4.96552e-02_wp, 5.17241e-02_wp, 5.37931e-02_wp, &
                                        5.58621e-02_wp, 5.79310e-02_wp, 6.00000e-02_wp]
  REAL(wp), PARAMETER :: OWC_TEN(30) = [0.00000e+00_wp, 1.71768e+05_wp, 3.30952e+05_wp, &
                                        4.78788e+05_wp, 6.16510e+05_wp, 7.45355e+05_wp, 8.66556e+05_wp, &
                                        9.81351e+05_wp, 1.09097e+06_wp, 1.19666e+06_wp, 1.29964e+06_wp, &
                                        1.40116e+06_wp, 1.50245e+06_wp, 1.60474e+06_wp, 1.70927e+06_wp, &
                                        1.81728e+06_wp, 1.93000e+06_wp, 2.04866e+06_wp, 2.17450e+06_wp, &
                                        2.30876e+06_wp, 2.45267e+06_wp, 2.60747e+06_wp, 2.77439e+06_wp, &
                                        2.95467e+06_wp, 3.14954e+06_wp, 3.36024e+06_wp, 3.58800e+06_wp, &
                                        3.83406e+06_wp, 4.09965e+06_wp, 4.38601e+06_wp]

  INTEGER :: nfail
  nfail = 0

  CALL case_fallback_restores_constitutive_state()
  CALL case_fallback_restores_committed_lengths()
  CALL case_recompute_keeps_committed_lengths()
  CALL case_segment_length_update_is_atomic()
  CALL case_mode3_premise_over_slack_range()
  CALL case_short_error_buffers()
  CALL case_compressive_local_refinement_is_bounded()
  CALL case_wheeler_trough_at_seabed()
  CALL case_static_stall_window()

  IF (nfail > 0) THEN
    WRITE (*, '(A,I0,A)') 'FAIL: ', nfail, ' assertion(s) failed'
    ERROR STOP 1
  END IF
  WRITE (*, '(A)') 'PASS: core failure-path regressions'

CONTAINS

  INCLUDE 'nan_max_abs.inc'

  SUBROUTINE two_element_chain(stretch, conn, l0, q0, fixed)
    !! Straight 3-node, 2-element chain along x with both ends held.
    REAL(wp), INTENT(IN) :: stretch
    INTEGER, INTENT(OUT) :: conn(2, 2), fixed(6)
    REAL(wp), INTENT(OUT) :: l0(2), q0(9)
    conn(:, 1) = [1, 2]
    conn(:, 2) = [2, 3]
    l0 = 1.0_wp
    q0 = 0.0_wp
    q0(4) = stretch
    q0(7) = 2.0_wp*stretch
    fixed = [1, 2, 3, 7, 8, 9]
  END SUBROUTINE two_element_chain

  SUBROUTINE case_fallback_restores_constitutive_state()
    !! Force every subdivision level to stall (one Newton iteration, unreachable
    !! tolerance) so the fallback exhausts its depth and re-runs the plain full-dt
    !! step. That re-run must start from the complete entry state: the committed
    !! kinematics AND the viscoelastic dl_1 / Syrope slow strain and running maximum
    !! must equal those of a single plain step of the same line.
    REAL(wp), PARAMETER :: DT = 0.02_wp
    TYPE(CD_ModelType) :: models(2), ref(2)
    TYPE(CD_SystemType) :: system
    TYPE(GenAlphaConfig) :: cfg
    TYPE(CD_SyropeType) :: td, stype(2)
    INTEGER :: conn(2, 2), fixed(6), es, n_iter, nc, i, j
    REAL(wp) :: l0(2), q0(9), v0(9), f_ext(9), eav(2), rho_a(2)
    REAL(wp) :: ve_ead(2), ve_ba(2), ve_bad(2)
    REAL(wp), ALLOCATABLE :: qc(:), vc(:), ac(:)
    REAL(wp) :: qs(9), vs(9), as(9), qr(9), vr(9), ar(9), pq(9), pv(9), pa(9)
    REAL(wp) :: dls(2), dlr(2), ss(2), ts(2), sr(2), tr(2)
    LOGICAL :: conv, stalled, sis(2)
    CHARACTER(240) :: em

    cfg%max_iter = 1
    cfg%rel_tol = 1.0e-15_wp
    cfg%abs_tol = 1.0e-300_wp
    v0 = 0.0_wp
    f_ext = 0.0_wp
    rho_a = 22.42_wp
    ! line 1: ElasticMod 2 viscoelastic rope, pre-stretched
    CALL two_element_chain(1.01_wp, conn, l0, q0, fixed)
    eav = 1.424e8_wp
    ve_ead = 1.586e8_wp
    ve_ba = 4.0e9_wp
    ve_bad = 1.1e7_wp
    DO j = 1, 2
      IF (j == 1) THEN
        CALL CD_Init_Model(models(1), q0, v0, conn, l0, eav, rho_a, .FALSE., f_ext, fixed, cfg, es, em, &
                           ve_ea_d=ve_ead, ve_ba=ve_ba, ve_ba_d=ve_bad)
      ELSE
        CALL CD_Init_Model(ref(1), q0, v0, conn, l0, eav, rho_a, .FALSE., f_ext, fixed, cfg, es, em, &
                           ve_ea_d=ve_ead, ve_ba=ve_ba, ve_ba_d=ve_bad)
      END IF
      CALL require(es == CD_MODEL_OK, 'fallback:viscoelastic-init '//TRIM(em))
    END DO
    ! line 2: Syrope rope on its working curve
    CALL CD_Syrope_Init(td, OWC_EPS, OWC_TEN, CD_SYROPE_WC_LINEAR, 0.6_wp, 0.0_wp, &
                        1.53e8_wp, 23.12_wp, 5.0e10_wp, 1.0e5_wp, es, em)
    CALL require(es == CD_SYROPE_OK, 'fallback:syrope-type')
    stype = td
    sis = .TRUE.
    CALL two_element_chain(1.026_wp, conn, l0, q0, fixed)
    eav = 1.0e8_wp
    DO j = 1, 2
      IF (j == 1) THEN
        CALL CD_Init_Model(models(2), q0, v0, conn, l0, eav, rho_a, .FALSE., f_ext, fixed, cfg, es, em, &
                           syrope_is=sis, syrope_type=stype, syrope_slow0=[0.021_wp, 0.021_wp], &
                           syrope_tmax0=[2.0e6_wp, 2.0e6_wp])
      ELSE
        CALL CD_Init_Model(ref(2), q0, v0, conn, l0, eav, rho_a, .FALSE., f_ext, fixed, cfg, es, em, &
                           syrope_is=sis, syrope_type=stype, syrope_slow0=[0.021_wp, 0.021_wp], &
                           syrope_tmax0=[2.0e6_wp, 2.0e6_wp])
      END IF
      CALL require(es == CD_MODEL_OK, 'fallback:syrope-init '//TRIM(em))
    END DO

    CALL CD_Init_System_From_Models(system, models, es, em)
    CALL require(es == CD_SYSTEM_OK, 'fallback:system-init '//TRIM(em))
    nc = CD_System_NCoupledDOF(system, es, em)
    CALL require(es == CD_SYSTEM_OK .AND. nc == 12, 'fallback:coupled-dof-count')
    ALLOCATE (qc(nc), vc(nc), ac(nc))
    CALL CD_Get_System_CoupledMotion(system, qc, vc, ac, es, em)
    CALL require(es == CD_SYSTEM_OK, 'fallback:coupled-motion')
    ! pull both ends of both lines outward, unevenly so the free middle node must move (a
    ! symmetric pull leaves it balanced at its predictor up to round-off)
    DO i = 0, 1
      qc(6*i + 1) = qc(6*i + 1) - 0.004_wp
      vc(6*i + 1) = -0.2_wp
      qc(6*i + 4) = qc(6*i + 4) + 0.010_wp
      vc(6*i + 4) = 0.5_wp
    END DO
    ac = 0.0_wp

    CALL CD_System_Fallback_Reset(system)
    CALL CD_Step_System(system, DT, qc, vc, ac, conv, stalled, n_iter, es, em)
    CALL require(es == CD_SYSTEM_OK, 'fallback:system-step '//TRIM(em))
    CALL require(.NOT. conv, 'fallback:step-stalls-at-every-depth')
    CALL require(CD_System_Fallback_Count(system) > 0, 'fallback:subdivision-entered')
    CALL CD_System_Fallback_Reset(system)

    DO i = 1, 2
      CALL CD_Get_Model_State(ref(i), pq, pv, pa, es, em)
      DO j = 1, 6
        pq(fixed(j)) = qc(6*(i - 1) + j)
        pv(fixed(j)) = vc(6*(i - 1) + j)
        pa(fixed(j)) = ac(6*(i - 1) + j)
      END DO
      CALL CD_Step_Model(ref(i), DT, conv, stalled, n_iter, es, em, prescribed_q=pq, prescribed_v=pv, &
                         prescribed_a=pa)
      CALL require(es == CD_MODEL_OK, 'fallback:reference-step')
      CALL CD_Get_System_Line_State(system, i, qs, vs, as, es, em)
      CALL CD_Get_Model_State(ref(i), qr, vr, ar, es, em)
      CALL require(same(qs, qr) .AND. same(vs, vr) .AND. same(as, ar), &
                   'fallback:kinematics-equal-one-plain-step')
    END DO
    CALL CD_Get_System_Line_VE_Dl1(system, 1, dls, es, em)
    CALL CD_Get_Model_VE_Dl1(ref(1), dlr, es, em)
    CALL require(es == CD_MODEL_OK .AND. same(dls, dlr), 'fallback:viscoelastic-dl1-advanced-once')
    CALL CD_Get_System_Line_Syrope_State(system, 2, ss, ts, es, em)
    CALL CD_Get_Model_Syrope_State(ref(2), sr, tr, es, em)
    CALL require(es == CD_MODEL_OK .AND. same(ss, sr), 'fallback:syrope-slow-advanced-once')
    CALL require(same(ts, tr), 'fallback:syrope-tmax-not-ratcheted')

    CALL CD_End_System(system, es, em)
    DO i = 1, 2
      CALL CD_End_Model(models(i), es, em)
      CALL CD_End_Model(ref(i), es, em)
    END DO
    CALL CD_Syrope_End(stype(1))
    CALL CD_Syrope_End(stype(2))
    CALL CD_Syrope_End(td)
  END SUBROUTINE case_fallback_restores_constitutive_state

  SUBROUTINE case_fallback_restores_committed_lengths()
    !! Active line control: a length and rate change, then a step that stalls at every
    !! subdivision level. The first half-step commits the new lengths as those of the
    !! committed state, so the fallback's restore must bring back the committed lengths of
    !! the entry state as well: the plain full-dt re-run then blends the old and new lengths
    !! and equals one plain step of the same line bit for bit.
    REAL(wp), PARAMETER :: DT = 0.02_wp
    TYPE(CD_ModelType) :: models(1), ref
    TYPE(CD_SystemType) :: system
    TYPE(GenAlphaConfig) :: cfg
    INTEGER :: conn(2, 2), fixed(6), es, n_iter, nc, j
    REAL(wp) :: l0(2), q0(9), v0(9), f_ext(9), eav(2), rho_a(2)
    REAL(wp), ALLOCATABLE :: qc(:), vc(:), ac(:)
    REAL(wp) :: qs(9), vs(9), as(9), qr(9), vr(9), ar(9), pq(9), pv(9), pa(9)
    LOGICAL :: conv, stalled
    CHARACTER(240) :: em

    cfg%max_iter = 1
    cfg%rel_tol = 1.0e-15_wp
    cfg%abs_tol = 1.0e-300_wp
    v0 = 0.0_wp
    f_ext = 0.0_wp
    f_ext(6) = -2.0e3_wp
    rho_a = 22.42_wp
    eav = 1.0e8_wp
    CALL two_element_chain(1.01_wp, conn, l0, q0, fixed)
    CALL CD_Init_Model(models(1), q0, v0, conn, l0, eav, rho_a, .FALSE., f_ext, fixed, cfg, es, em)
    CALL require(es == CD_MODEL_OK, 'fallback-lengths:init '//TRIM(em))
    CALL CD_Init_Model(ref, q0, v0, conn, l0, eav, rho_a, .FALSE., f_ext, fixed, cfg, es, em)
    CALL require(es == CD_MODEL_OK, 'fallback-lengths:reference-init '//TRIM(em))
    CALL CD_Init_System_From_Models(system, models, es, em)
    CALL require(es == CD_SYSTEM_OK, 'fallback-lengths:system-init '//TRIM(em))
    ! pay out the second element: a new length and rate the committed state was not reached with
    CALL CD_Update_System_Line_SegmentLength(system, 1, 2, 1.004_wp, 0.2_wp, es, em)
    CALL require(es == CD_SYSTEM_OK, 'fallback-lengths:system-update '//TRIM(em))
    CALL CD_Update_Model_SegmentLength(ref, 2, 1.004_wp, 0.2_wp, es, em)
    CALL require(es == CD_MODEL_OK, 'fallback-lengths:reference-update '//TRIM(em))
    nc = CD_System_NCoupledDOF(system, es, em)
    CALL require(es == CD_SYSTEM_OK .AND. nc == 6, 'fallback-lengths:coupled-dof-count')
    ALLOCATE (qc(nc), vc(nc), ac(nc))
    CALL CD_Get_System_CoupledMotion(system, qc, vc, ac, es, em)
    CALL require(es == CD_SYSTEM_OK, 'fallback-lengths:coupled-motion')
    qc(4) = qc(4) + 0.004_wp
    vc(4) = 0.2_wp
    ac = 0.0_wp

    CALL CD_System_Fallback_Reset(system)
    CALL CD_Step_System(system, DT, qc, vc, ac, conv, stalled, n_iter, es, em)
    CALL require(es == CD_SYSTEM_OK, 'fallback-lengths:system-step '//TRIM(em))
    CALL require(.NOT. conv, 'fallback-lengths:step-stalls-at-every-depth')
    CALL require(CD_System_Fallback_Count(system) > 0, 'fallback-lengths:subdivision-entered')
    CALL CD_System_Fallback_Reset(system)

    CALL CD_Get_Model_State(ref, pq, pv, pa, es, em)
    DO j = 1, 6
      pq(fixed(j)) = qc(j)
      pv(fixed(j)) = vc(j)
      pa(fixed(j)) = ac(j)
    END DO
    CALL CD_Step_Model(ref, DT, conv, stalled, n_iter, es, em, prescribed_q=pq, prescribed_v=pv, prescribed_a=pa)
    CALL require(es == CD_MODEL_OK, 'fallback-lengths:reference-step')
    CALL CD_Get_System_Line_State(system, 1, qs, vs, as, es, em)
    CALL CD_Get_Model_State(ref, qr, vr, ar, es, em)
    CALL require(same(qs, qr) .AND. same(vs, vr) .AND. same(as, ar), &
                 'fallback-lengths:kinematics-equal-one-blended-plain-step')
    CALL require(same(system%lines(1)%l0_c, ref%l0_c) .AND. same(system%lines(1)%l0_dot_c, ref%l0_dot_c), &
                 'fallback-lengths:committed-lengths-advanced-once')

    CALL CD_End_System(system, es, em)
    CALL CD_End_Model(models(1), es, em)
    CALL CD_End_Model(ref, es, em)
  END SUBROUTINE case_fallback_restores_committed_lengths

  SUBROUTINE case_recompute_keeps_committed_lengths()
    !! Active line control on an EI = 0 line: after a length and rate change, re-deriving the
    !! acceleration (a boundary commit, or the OpenFAST shell's state update) solves it at the
    !! lengths and rates the committed state was reached with. It equals the acceleration of
    !! a line that was never commanded, the committed lengths stay, the new ones stay in
    !! place, and the step that follows is the blended step of a model whose acceleration was
    !! not re-derived. The same holds through the system update (coupled motion + recompute).
    REAL(wp), PARAMETER :: DT = 0.02_wp
    TYPE(CD_ModelType) :: a, b, twin, lines(1)
    TYPE(CD_SystemType) :: system
    TYPE(GenAlphaConfig) :: cfg
    INTEGER :: conn(2, 2), fixed(6), es, n_iter, nc, j
    REAL(wp) :: l0(2), q0(9), v0(9), f_ext(9), eav(2), rho_a(2), pq(9), pv(9), pa(9)
    REAL(wp) :: qs(9), vs(9), as(9)
    REAL(wp), ALLOCATABLE :: qc(:), vc(:), ac(:)
    LOGICAL :: conv, stalled
    CHARACTER(240) :: em

    v0 = 0.0_wp
    f_ext = 0.0_wp
    f_ext(6) = -2.0e3_wp
    rho_a = 22.42_wp
    eav = 1.0e8_wp
    CALL two_element_chain(1.01_wp, conn, l0, q0, fixed)
    CALL CD_Init_Model(a, q0, v0, conn, l0, eav, rho_a, .FALSE., f_ext, fixed, cfg, es, em)
    CALL require(es == CD_MODEL_OK, 'recompute-lengths:init '//TRIM(em))
    CALL CD_Init_Model(twin, q0, v0, conn, l0, eav, rho_a, .FALSE., f_ext, fixed, cfg, es, em)
    CALL require(es == CD_MODEL_OK, 'recompute-lengths:twin-init '//TRIM(em))
    lines(1) = a
    CALL CD_Update_Model_SegmentLength(a, 2, 1.004_wp, 0.2_wp, es, em)
    CALL require(es == CD_MODEL_OK, 'recompute-lengths:update '//TRIM(em))
    b = a
    CALL CD_Recompute_Model_Acceleration(a, es, em)
    CALL require(es == CD_MODEL_OK, 'recompute-lengths:recompute '//TRIM(em))
    CALL CD_Recompute_Model_Acceleration(twin, es, em)
    CALL require(es == CD_MODEL_OK, 'recompute-lengths:twin-recompute '//TRIM(em))
    CALL require(same(a%a, twin%a), 'recompute-lengths:acceleration-of-the-committed-lengths')
    CALL require(same(a%l0_c, l0) .AND. same(a%l0_dot_c, [0.0_wp, 0.0_wp]) .AND. &
                 a%l0(2) == 1.004_wp .AND. a%l0_dot(2) == 0.2_wp .AND. same(a%l0, b%l0) .AND. &
                 same(a%l0_dot, b%l0_dot), 'recompute-lengths:committed-and-present-lengths-kept')
    ! the step after it is the blended step (of a model with the same acceleration)
    b%a = a%a
    CALL CD_Get_Model_State(a, pq, pv, pa, es, em)
    pq(7) = pq(7) + 0.004_wp
    pv(7) = 0.2_wp
    CALL CD_Step_Model(a, DT, conv, stalled, n_iter, es, em, prescribed_q=pq, prescribed_v=pv, prescribed_a=pa)
    CALL require(es == CD_MODEL_OK .AND. conv, 'recompute-lengths:step '//TRIM(em))
    CALL CD_Step_Model(b, DT, conv, stalled, n_iter, es, em, prescribed_q=pq, prescribed_v=pv, prescribed_a=pa)
    CALL require(es == CD_MODEL_OK .AND. conv, 'recompute-lengths:reference-step '//TRIM(em))
    CALL require(same(a%q, b%q) .AND. same(a%v, b%v) .AND. same(a%a, b%a) .AND. same(a%l0_c, a%l0), &
                 'recompute-lengths:the-step-still-blends-the-lengths')

    ! the system update the OpenFAST shell performs between the command and the step
    CALL CD_Init_System_From_Models(system, lines, es, em)
    CALL require(es == CD_SYSTEM_OK, 'recompute-lengths:system-init '//TRIM(em))
    CALL CD_Update_System_Line_SegmentLength(system, 1, 2, 1.004_wp, 0.2_wp, es, em)
    CALL require(es == CD_SYSTEM_OK, 'recompute-lengths:system-update '//TRIM(em))
    nc = CD_System_NCoupledDOF(system, es, em)
    ALLOCATE (qc(nc), vc(nc), ac(nc))
    CALL CD_Get_System_CoupledMotion(system, qc, vc, ac, es, em)
    CALL CD_Update_System_CoupledMotion(system, qc, vc, ac, es, em)
    CALL require(es == CD_SYSTEM_OK, 'recompute-lengths:system-motion '//TRIM(em))
    CALL CD_Recompute_System_Acceleration(system, es, em)
    CALL require(es == CD_SYSTEM_OK, 'recompute-lengths:system-recompute '//TRIM(em))
    CALL CD_Get_System_Line_State(system, 1, qs, vs, as, es, em)
    CALL require(same(as, twin%a) .AND. same(system%lines(1)%l0_c, l0) .AND. system%lines(1)%l0(2) == 1.004_wp, &
                 'recompute-lengths:the-system-update-keeps-the-committed-lengths')
    DO j = 1, 2
      CALL require(system%lines(1)%l0_dot_c(j) == 0.0_wp, 'recompute-lengths:system-committed-rates')
    END DO

    CALL CD_End_System(system, es, em)
    CALL CD_End_Model(a, es, em)
    CALL CD_End_Model(b, es, em)
    CALL CD_End_Model(twin, es, em)
    CALL CD_End_Model(lines(1), es, em)
  END SUBROUTINE case_recompute_keeps_committed_lengths

  SUBROUTINE case_segment_length_update_is_atomic()
    !! A length so large that the reassembled distributed load overflows makes the
    !! acceleration recompute fail after the length-dependent fields were rebuilt.
    !! The failed update must leave every committed field bit-identical.
    TYPE(CD_ModelType) :: model
    TYPE(GenAlphaConfig) :: cfg
    INTEGER :: conn(2, 2), fixed(6), es
    REAL(wp) :: l0(2), q0(9), v0(9), f_ext(9), eav(2), rho_a(2), wpl(3, 2)
    REAL(wp) :: q1(9), v1(9), a1(9), q2(9), v2(9), a2(9), l0_before(2), l0dot_before(2), f_before(9)
    CHARACTER(240) :: em

    CALL two_element_chain(1.001_wp, conn, l0, q0, fixed)
    v0 = 0.0_wp
    eav = 1.0e8_wp
    rho_a = 1.0_wp
    wpl = 0.0_wp
    wpl(3, :) = -1.0e10_wp
    f_ext = 0.0_wp
    f_ext(3) = 0.5_wp*l0(1)*wpl(3, 1)
    f_ext(6) = 0.5_wp*(l0(1) + l0(2))*wpl(3, 1)
    f_ext(9) = 0.5_wp*l0(2)*wpl(3, 1)
    CALL CD_Init_Model(model, q0, v0, conn, l0, eav, rho_a, .FALSE., f_ext, fixed, cfg, es, em, &
                       dist_load_per_length=wpl)
    CALL require(es == CD_MODEL_OK, 'segment:init '//TRIM(em))
    CALL CD_Update_Model_SegmentLength(model, 1, 1.002_wp, 0.01_wp, es, em)
    CALL require(es == CD_MODEL_OK, 'segment:valid-update')
    CALL CD_Get_Model_State(model, q1, v1, a1, es, em)
    l0_before = model%l0
    l0dot_before = model%l0_dot
    f_before = model%f_ext

    ! deliberately non-finite or overflowing input: must not halt a trapping build
    CALL IEEE_GET_HALTING_MODE(IEEE_USUAL, fp_halt)
    CALL IEEE_SET_HALTING_MODE(IEEE_USUAL, .FALSE.)
    CALL CD_Update_Model_SegmentLength(model, 2, 1.0e300_wp, 0.5_wp, es, em)
    CALL IEEE_SET_FLAG(IEEE_USUAL, .FALSE.)
    CALL IEEE_SET_HALTING_MODE(IEEE_USUAL, fp_halt)
    CALL require(es /= CD_MODEL_OK, 'segment:overflowing-update-fails')
    CALL CD_Get_Model_State(model, q2, v2, a2, es, em)
    CALL require(same(q2, q1) .AND. same(v2, v1) .AND. same(a2, a1), 'segment:state-unchanged')
    CALL require(same(model%l0, l0_before) .AND. same(model%l0_dot, l0dot_before), &
                 'segment:lengths-and-rates-unchanged')
    CALL require(same(model%f_ext, f_before), 'segment:external-load-unchanged')
    CALL CD_End_Model(model, es, em)
  END SUBROUTINE case_segment_length_update_is_atomic

  SUBROUTINE case_mode3_premise_over_slack_range()
    !! alphaMBL below the static EA: a taut IC has EA_D >= EA, but a slack segment
    !! has EA_D = alphaMBL < EA. Init must reject the rope by name.
    TYPE(CD_ModelType) :: model
    TYPE(GenAlphaConfig) :: cfg
    INTEGER :: conn(2, 2), fixed(6), es
    REAL(wp) :: l0(2), q0(9), v0(9), f_ext(9), eav(2), rho_a(2)
    CHARACTER(240) :: em

    CALL two_element_chain(2.0_wp, conn, l0, q0, fixed)
    v0 = 0.0_wp
    f_ext = 0.0_wp
    eav = 1.586e8_wp
    rho_a = 22.42_wp
    CALL CD_Init_Model(model, q0, v0, conn, l0, eav, rho_a, .FALSE., f_ext, fixed, cfg, es, em, &
                       ve_ea_d=[0.0_wp, 0.0_wp], ve_ba=[4.0e9_wp, 4.0e9_wp], ve_ba_d=[1.1e7_wp, 1.1e7_wp], &
                       ve_alpha_mbl=[1.424e8_wp, 1.424e8_wp], ve_vbeta=[0.4_wp, 0.4_wp])
    CALL require(es == CD_MODEL_BADINPUT .AND. INDEX(em, 'alphaMBL') > 0, 'mode3:premise-rejected-at-init')
    CALL CD_End_Model(model, es, em)
  END SUBROUTINE case_mode3_premise_over_slack_range

  SUBROUTINE case_short_error_buffers()
    !! Diagnostics longer than the caller's buffer must be truncated.
    TYPE(CD_ModelType) :: model
    TYPE(GenAlphaConfig) :: cfg
    INTEGER :: conn(2, 2), fixed(6), es, n_iter, nfix, i
    REAL(wp) :: l0(2), q0(9), v0(9), f_ext(9), eav(2), rho_a(2), pq(9), pv(9), pa(9)
    REAL(wp), ALLOCATABLE :: hl0(:), hEA(:), hEI(:), hw(:), seed(:), q_out(:), curv(:)
    INTEGER, ALLOCATABLE :: hfixed(:)
    REAL(wp) :: res
    INTEGER :: its
    LOGICAL :: conv, stalled
    CHARACTER(16) :: short_msg
    CHARACTER(240) :: em

    ! EI=0 recovery at its subdivision cap
    cfg%max_iter = 1
    cfg%rel_tol = 1.0e-15_wp
    cfg%abs_tol = 1.0e-300_wp
    CALL two_element_chain(1.01_wp, conn, l0, q0, fixed)
    v0 = 0.0_wp
    f_ext = 0.0_wp
    f_ext(6) = -1.0e4_wp
    eav = 1.0e8_wp
    rho_a = 22.42_wp
    CALL CD_Init_Model(model, q0, v0, conn, l0, eav, rho_a, .FALSE., f_ext, fixed, cfg, es, em)
    CALL require(es == CD_MODEL_OK, 'short-buffer:init')
    CALL CD_Get_Model_State(model, pq, pv, pa, es, em)
    pq(7) = pq(7) + 0.01_wp
    pv(7) = 0.5_wp
    CALL CD_Step_Model_Recovering(model, 0.02_wp, conv, stalled, n_iter, es, short_msg, &
                                  prescribed_q=pq, prescribed_v=pv, prescribed_a=pa, max_substeps=4)
    CALL require(es /= CD_MODEL_OK .AND. short_msg == 'CableDyn_Model: ', 'short-buffer:model-recovery')
    CALL CD_End_Model(model, es, em)

    ! Hermite static solve out of Newton budget
    ALLOCATE (hl0(4), hEA(4), hEI(4), hw(4), seed(30), q_out(30), curv(5), hfixed(6 + 10))
    hl0 = 25.0_wp
    hEA = 1.0e8_wp
    hEI = 1.0e4_wp
    hw = 100.0_wp
    CALL CD_HermiteCable_Trivial_Seed([0.0_wp, 0.0_wp, 0.0_wp], [90.0_wp, 0.0_wp, 0.0_wp], hl0, &
                                      -1000.0_wp, seed, es, em)
    CALL require(es == CD_HCSTAT_OK, 'short-buffer:hermite-seed')
    nfix = 0
    DO i = 1, 3
      nfix = nfix + 1
      hfixed(nfix) = i
      nfix = nfix + 1
      hfixed(nfix) = 24 + i
    END DO
    DO i = 1, 5
      nfix = nfix + 1
      hfixed(nfix) = 6*(i - 1) + 2
      nfix = nfix + 1
      hfixed(nfix) = 6*(i - 1) + 5
    END DO
    CALL CD_HermiteCable_Static_Solve(hl0, hEA, hEI, hw, seed, hfixed(1:nfix), -1000.0_wp, 0.0_wp, &
                                      1, 1, 1.0e-14_wp, 0.7_wp, q_out, curv, res, its, es, short_msg)
    CALL require(es == CD_HCSTAT_NOCONVERGE .AND. short_msg == 'CD_HermiteCable_', &
                 'short-buffer:hermite-static')
    CALL require(ALL(IEEE_IS_FINITE(q_out)), 'short-buffer:hermite-static-output-defined')
  END SUBROUTINE case_short_error_buffers

  SUBROUTINE case_compressive_local_refinement_is_bounded()
    !! A fully held straight rod compressed by 10 %: every element is compressive and
    !! local refinement cannot relieve it. AutoMesh must stop after the no-progress
    !! window and fail closed with a mesh inside the element budget.
    INTEGER, PARAMETER :: NE = 2, NN = NE + 1, NDOF = 6*NN
    REAL(wp) :: l0(NE), EA(NE), EI(NE), w(NE), seed(NDOF)
    REAL(wp), ALLOCATABLE :: l0o(:), EAo(:), EIo(:), wo(:), qo(:), curvo(:)
    INTEGER :: fixed(NDOF), i, scale, its, es
    INTEGER, ALLOCATABLE :: fixo(:)
    TYPE(CD_HermiteResolutionType) :: dg
    REAL(wp) :: res
    CHARACTER(400) :: em

    l0 = 1.0_wp
    EA = 1.0e6_wp
    EI = 1.0e3_wp
    w = 0.0_wp
    seed = 0.0_wp
    DO i = 1, NN
      seed(6*(i - 1) + 1) = 0.9_wp*REAL(i - 1, wp)
      seed(6*(i - 1) + 4) = 0.9_wp
    END DO
    DO i = 1, NDOF
      fixed(i) = i
    END DO
    CALL CD_HermiteCable_Static_Solve_AutoMesh(l0, EA, EI, w, seed, fixed, -1.0e4_wp, 0.0_wp, &
                                               1, 5, 1.0e-10_wp, 1.0_wp, 1.0e3_wp, 0.0_wp, 1, &
                                               [1, 2, 3, 4, 5, 6], &
                                               l0o, EAo, EIo, wo, qo, curvo, fixo, scale, dg, &
                                               res, its, es, em, require_tensile=.TRUE., &
                                               refine_non_axial=.FALSE.)
    CALL require(es == CD_HCSTAT_NOCONVERGE, 'compressive:fails-closed')
    CALL require(INDEX(em, 'local axial refinement stopped') > 0, 'compressive:names-the-stop '//TRIM(em))
    CALL require(SIZE(l0o) <= CD_HC_REFINE_CAP*NE, 'compressive:mesh-within-budget')
  END SUBROUTINE case_compressive_local_refinement_is_bounded

  SUBROUTINE case_wheeler_trough_at_seabed()
    !! Depth 10 m, H = 20 m: the trough sits on the seabed, where the stretched
    !! coordinate is 0/0. The evaluation must report an error, never NaN kinematics.
    REAL(wp), PARAMETER :: PI = 3.14159265358979323846_wp
    REAL(wp) :: eta, vel(3), acc(3)
    INTEGER :: es
    CHARACTER(240) :: em

    CALL CD_Airy_Wave_Kinematics_Precomputed(0.0_wp, 0.0_wp, -10.0_wp, PI, 20.0_wp, 1.0_wp, 0.1_wp, 10.0_wp, &
                                             0.0_wp, .TRUE., eta, vel, acc, es, em)
    CALL require(es == CD_HYDRO_BADINPUT .AND. INDEX(em, 'Wheeler') > 0, 'wheeler:trough-on-seabed-fails')
    CALL require(ALL(IEEE_IS_FINITE(vel)) .AND. ALL(IEEE_IS_FINITE(acc)), 'wheeler:outputs-finite')
    CALL CD_Airy_Wave_Kinematics_Precomputed(0.0_wp, 0.0_wp, -5.0_wp, 0.0_wp, 2.0_wp, 1.0_wp, 0.1_wp, 10.0_wp, &
                                             0.0_wp, .TRUE., eta, vel, acc, es, em)
    CALL require(es == CD_HYDRO_OK .AND. ALL(IEEE_IS_FINITE(vel)), 'wheeler:ordinary-wave-ok')
  END SUBROUTINE case_wheeler_trough_at_seabed

  SUBROUTINE case_static_stall_window()
    TYPE(CableSolverConfig) :: scfg
    INTEGER :: conn(2, 2), fixed(6), es, n_iter
    REAL(wp) :: l0(2), q0(9), q(9), f_ext(9)
    LOGICAL :: conv, stalled, at_floor
    CHARACTER(240) :: em
    CALL two_element_chain(1.0_wp, conn, l0, q0, fixed)
    f_ext = 0.0_wp
    scfg%stall_window = 1
    CALL CD_Static_Cable_Solve(q0, conn, l0, [1.0e8_wp, 1.0e8_wp], .FALSE., f_ext, fixed, scfg, q, &
                               conv, stalled, at_floor, n_iter, es, em)
    CALL require(es == CD_STATIC_BADINPUT, 'static:one-sample-stall-window-rejected')
  END SUBROUTINE case_static_stall_window

  LOGICAL FUNCTION same(x, y)
    !! Bitwise-equal finite vectors of equal shape.
    REAL(wp), INTENT(IN) :: x(:), y(:)
    same = SIZE(x) == SIZE(y)
    IF (.NOT. same) RETURN
    IF (SIZE(x) == 0) RETURN
    same = ALL(IEEE_IS_FINITE(x)) .AND. ALL(IEEE_IS_FINITE(y))
    IF (same) same = nan_max_abs(x - y) <= 0.0_wp
  END FUNCTION same

  SUBROUTINE require(cond, label)
    LOGICAL, INTENT(IN) :: cond
    CHARACTER(*), INTENT(IN) :: label
    IF (.NOT. cond) THEN
      nfail = nfail + 1
      WRITE (*, '(A)') 'MISMATCH ['//TRIM(label)//']'
    END IF
  END SUBROUTINE require

END PROGRAM test_core_release_regressions
