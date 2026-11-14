! File: tests/test_openfast_shell.f90
! SPDX-License-Identifier: Apache-2.0
! Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
PROGRAM test_openfast_shell
  !! Lifecycle gate for CableDyn_OpenFAST. This verifies the thin OpenFAST-facing
  !! module shell over CableDyn_System: init from point bindings, coupled
  !! kinematics update, load output, queries, and clean shutdown.
  USE, INTRINSIC :: IEEE_ARITHMETIC, ONLY: IEEE_VALUE, IEEE_QUIET_NAN
  USE CableDyn_Precision, ONLY: wp
  USE CableDyn_Dynamic, ONLY: GenAlphaConfig
  USE CableDyn_Model, ONLY: CD_ModelType, CD_Init_Model, CD_End_Model, CD_MODEL_OK
  USE CableDyn_System, ONLY: CD_SystemPointType, CD_LineEndpointBinding, CD_POINT_FIXED, &
                             CD_POINT_COUPLED, CD_POINT_FREE, CD_LINE_END_A, CD_LINE_END_B
  USE CableDyn_OpenFAST, ONLY: CD_FAST_ModuleType, CD_FAST_Init_From_Points, CD_FAST_UpdateStates, &
                               CD_FAST_UpdateStates_From_Body, CD_FAST_Step, CD_FAST_CalcOutput, &
                               CD_FAST_CalcBodyWrench, CD_FAST_CalcOutputDerivatives, &
                               CD_FAST_UpdatePointFluidFields, &
                               CD_FAST_End, CD_FAST_NCoupledDOF, CD_FAST_NPoints, CD_FAST_NLines, &
                               CD_FAST_GetCoupledMotion, CD_FAST_IsInitialized, CD_FAST_OK, &
                               CD_FAST_BADINPUT, CD_FAST_NOT_INITIALIZED
  USE CableDyn_OpenFAST_Types, ONLY: CD_InitInputType, CD_InitOutputType, CD_InputType, CD_OutputType, &
                                     CD_ParameterType, CD_OpenFAST_Types_InitExchange, &
                                     CD_OpenFAST_Types_EndExchange, CD_ContinuousStateType, CD_ConstraintStateType, &
                                     CD_DiscreteStateType, CD_OtherStateType, CD_OpenFAST_Types_InitStates, &
                                     CD_OpenFAST_Types_EndStates, CD_OpenFAST_Types_CopyInput, &
                                     CD_OpenFAST_Types_CopyOutput, CD_OpenFAST_Types_CopyParameters, &
                                     CD_OpenFAST_Types_CopyContinuousState, CD_OpenFAST_Types_CopyConstraintState, &
                                     CD_OpenFAST_Types_CopyDiscreteState, CD_OpenFAST_Types_CopyOtherState, &
                                     CD_TYPES_OK, CD_TYPES_BADINPUT
  USE CableDyn_OpenFAST_Mesh, ONLY: CD_FAST_PointMeshType, CD_FAST_Init_PointMesh, CD_FAST_End_PointMesh, &
                                    CD_FAST_Set_PointMesh_State, CD_FAST_Get_PointMesh_State, &
                                    CD_FAST_Set_PointMesh_From_Body, CD_FAST_UpdateStates_From_PointMesh, &
                                    CD_FAST_CalcOutput_To_PointMesh, CD_FAST_CalcBodyWrench_From_PointMesh, &
                                    CD_FAST_PointMesh_IsInitialized, CD_FAST_MESH_OK, CD_FAST_MESH_BADINPUT, &
                                    CD_FAST_MESH_NOT_INITIALIZED
  USE CableDyn_OpenFAST_FMF, ONLY: CD_FMF_ModuleType, CD_FMF_Init_From_Points, CD_FMF_UpdateStates, CD_FMF_Step, &
                                   CD_FMF_UpdatePointFluidFields, &
                                   CD_FMF_Init_From_Deck, CD_FMF_CalcOutput, CD_FMF_CalcBodyWrench, &
                                   CD_FMF_CalcOutputDerivatives, CD_FMF_GetPointMesh, CD_FMF_End, &
                                   CD_FMF_NMovingPoints, CD_FMF_GetMovingPointMesh, CD_FMF_UpdateStates_Moving, &
                                   CD_FMF_Step_Moving, &
                                   CD_FMF_IsInitialized, CD_FMF_OK, CD_FMF_BADINPUT, CD_FMF_NOT_INITIALIZED
  IMPLICIT NONE

  INTEGER :: nfail
  nfail = 0

  CALL case_fast_lifecycle()
  CALL case_output_probe_overlay()
  CALL case_fast_point_mesh()
  CALL case_fmf_lifecycle()
  CALL case_fmf_external_point_fluid()
  CALL case_fmf_deck_init()
  CALL case_fmf_deck_friction()
  CALL case_fmf_rotational_stiffness()
  CALL case_fast_fail_closed()
  CALL case_registry_types()
  CALL case_size_overflow_guards()

  IF (nfail > 0) THEN
    WRITE (*, '(A,I0,A)') 'FAIL: ', nfail, ' assertion(s) failed'
    ERROR STOP 1
  END IF
  WRITE (*, '(A)') 'PASS: CableDyn_OpenFAST shell lifecycle'

CONTAINS

  INCLUDE 'nan_max_abs.inc'

  SUBROUTINE case_output_probe_overlay()
    !! The CompMooring=5 CalcOutput fast path owns an outer full-state mirror and
    !! therefore uses output_probe=.TRUE. for its temporary endpoint overlay.
    !! That mode must update prescribed endpoints while leaving every committed
    !! interior generalized-alpha acceleration bit-identical.
    TYPE(CD_FAST_ModuleType) :: module
    TYPE(CD_ModelType) :: model
    TYPE(CD_SystemPointType) :: points(2)
    TYPE(CD_LineEndpointBinding) :: bindings(2)
    TYPE(GenAlphaConfig) :: cfg
    INTEGER :: es, conn(2, 2), fixed(6)
    REAL(wp) :: q0(9), v0(9), l0(2), ea(2), rho_a(2), f_ext(9)
    REAL(wp) :: q(6), v(6), a(6), q_probe(6), loads0(6), loads1(6), a_interior(3)
    CHARACTER(240) :: em

    conn = RESHAPE([1, 2, 2, 3], SHAPE(conn))
    fixed = [1, 2, 3, 7, 8, 9]
    q0 = [0.0_wp, 0.0_wp, 0.0_wp, 1.0_wp, 0.0_wp, -0.1_wp, 2.0_wp, 0.0_wp, 0.0_wp]
    v0 = 0.0_wp
    l0 = [1.05_wp, 1.05_wp]
    ea = 1.0e4_wp
    rho_a = 5.0_wp
    f_ext = 0.0_wp
    f_ext(6) = -10.0_wp
    CALL CD_Init_Model(model, q0, v0, conn, l0, ea, rho_a, .TRUE., f_ext, fixed, cfg, es, em)
    CALL require(es == CD_MODEL_OK, 'output-probe:model-init: '//TRIM(em))
    IF (es /= CD_MODEL_OK) RETURN
    points = [CD_SystemPointType(id=1, point_type=CD_POINT_FIXED), &
              CD_SystemPointType(id=2, point_type=CD_POINT_COUPLED)]
    bindings = [CD_LineEndpointBinding(line_index=1, line_end=CD_LINE_END_A, point_id=1), &
                CD_LineEndpointBinding(line_index=1, line_end=CD_LINE_END_B, point_id=2)]
    CALL CD_FAST_Init_From_Points(module, [model], points, bindings, es, em)
    CALL require(es == CD_FAST_OK, 'output-probe:module-init: '//TRIM(em))
    CALL CD_End_Model(model, es, em)
    IF (.NOT. CD_FAST_IsInitialized(module)) RETURN

    q = [q0(1:3), q0(7:9)]
    v = 0.0_wp
    a = 0.0_wp
    CALL CD_FAST_UpdateStates(module, q, v, a, es, em)
    CALL require(es == CD_FAST_OK, 'output-probe:baseline-update: '//TRIM(em))
    CALL CD_FAST_CalcOutput(module, loads0, es, em)
    a_interior = module%system%lines(1)%a(4:6)

    q_probe = q
    q_probe(4) = q_probe(4) + 0.05_wp
    a(4) = 0.4_wp
    CALL CD_FAST_UpdateStates(module, q_probe, v, a, es, em, output_probe=.TRUE.)
    CALL require(es == CD_FAST_OK, 'output-probe:probe-update: '//TRIM(em))
    CALL require(nan_max_abs(module%system%lines(1)%a(4:6) - a_interior) <= 0.0_wp, &
                 'output-probe:interior-acceleration-frozen')
    CALL CD_FAST_CalcOutput(module, loads1, es, em)
    CALL require(es == CD_FAST_OK .AND. NORM2(loads1 - loads0) > 1.0_wp, &
                 'output-probe:direct-feedthrough-load-changes')

    CALL CD_FAST_UpdateStates(module, q, v, 0.0_wp*a, es, em, output_probe=.TRUE.)
    CALL require(es == CD_FAST_OK .AND. &
                 nan_max_abs(module%system%lines(1)%a(4:6) - a_interior) <= 0.0_wp, &
                 'output-probe:restore-keeps-interior')
    CALL CD_FAST_End(module, es, em)
  END SUBROUTINE case_output_probe_overlay

  SUBROUTINE init_bar(model, x0, x1, ErrStat, ErrMsg)
    TYPE(CD_ModelType), INTENT(INOUT) :: model
    REAL(wp), INTENT(IN) :: x0, x1
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg

    TYPE(GenAlphaConfig) :: cfg
    INTEGER :: conn(2, 1), fixed(6)
    REAL(wp) :: q0(6), v0(6), l0(1), ea(1), rho_a(1), f_ext(6)

    conn(:, 1) = [1, 2]
    fixed = [1, 2, 3, 4, 5, 6]
    q0 = [x0, 0.0_wp, 0.0_wp, x1, 0.0_wp, 0.0_wp]
    v0 = 0.0_wp
    l0 = [1.0_wp]
    ea = [100.0_wp]
    rho_a = [5.0_wp]
    f_ext = 0.0_wp
    CALL CD_Init_Model(model, q0, v0, conn, l0, ea, rho_a, .TRUE., f_ext, fixed, cfg, ErrStat, ErrMsg)
  END SUBROUTINE init_bar

  SUBROUTINE case_fast_lifecycle()
    TYPE(CD_FAST_ModuleType) :: module
    TYPE(CD_ModelType) :: models(2)
    TYPE(CD_SystemPointType) :: points(3)
    TYPE(CD_LineEndpointBinding) :: bindings(4)
    INTEGER :: es, n
    REAL(wp) :: q(9), v(9), a(9), qout(9), vout(9), aout(9), loads(9), plus(9), minus(9), qp(9), vp(9), ap(9)
    REAL(wp) :: jq(9, 9), jv(9, 9), ja(9, 9), madd(9, 9), bad_jac(8, 9)
    REAL(wp) :: body_q(6), body_v(6), body_a(6), offsets(3, 3), wrench(6), expected_wrench(6)
    REAL(wp) :: h
    LOGICAL :: converged, stalled
    INTEGER :: n_iter
    CHARACTER(240) :: em

    points = [CD_SystemPointType(id=1, point_type=CD_POINT_FIXED), &
              CD_SystemPointType(id=2, point_type=CD_POINT_COUPLED), &
              CD_SystemPointType(id=3, point_type=CD_POINT_FIXED)]
    bindings = [CD_LineEndpointBinding(line_index=1, line_end=CD_LINE_END_A, point_id=1), &
                CD_LineEndpointBinding(line_index=1, line_end=CD_LINE_END_B, point_id=2), &
                CD_LineEndpointBinding(line_index=2, line_end=CD_LINE_END_A, point_id=2), &
                CD_LineEndpointBinding(line_index=2, line_end=CD_LINE_END_B, point_id=3)]
    CALL init_bar(models(1), 0.0_wp, 1.0_wp, es, em)
    CALL require(es == CD_MODEL_OK, 'fast:init-line-1')
    CALL init_bar(models(2), 1.0_wp, 2.0_wp, es, em)
    CALL require(es == CD_MODEL_OK, 'fast:init-line-2')
    CALL CD_FAST_Init_From_Points(module, models, points, bindings, es, em)
    CALL require(es == CD_FAST_OK .AND. CD_FAST_IsInitialized(module), 'fast:init: '//TRIM(em))
    CALL CD_End_Model(models(1), es, em)
    CALL CD_End_Model(models(2), es, em)

    n = CD_FAST_NLines(module, es, em)
    CALL require(es == CD_FAST_OK .AND. n == 2, 'fast:nlines')
    n = CD_FAST_NCoupledDOF(module, es, em)
    CALL require(es == CD_FAST_OK .AND. n == 9, 'fast:ncoupled')
    n = CD_FAST_NPoints(module, es, em)
    CALL require(es == CD_FAST_OK .AND. n == 3, 'fast:npoints')
    q = [0.0_wp, 0.0_wp, 0.0_wp, 1.2_wp, 0.0_wp, 0.0_wp, 2.3_wp, 0.0_wp, 0.0_wp]
    v = 0.0_wp
    a = 0.0_wp
    a(4) = 0.7_wp
    CALL CD_FAST_UpdateStates(module, q, v, a, es, em)
    CALL require(es == CD_FAST_OK, 'fast:update')
    CALL CD_FAST_GetCoupledMotion(module, qout, vout, aout, es, em)
    CALL require(es == CD_FAST_OK .AND. nan_max_abs(qout - q) < 1.0e-12_wp .AND. &
                 nan_max_abs(aout - a) < 1.0e-12_wp, 'fast:get-motion')
    a = 0.0_wp
    CALL CD_FAST_UpdateStates(module, q, v, a, es, em)
    CALL require(es == CD_FAST_OK, 'fast:update-zero-accel')
    CALL CD_FAST_CalcOutput(module, loads, es, em)
    CALL require(es == CD_FAST_OK, 'fast:output')
    CALL require(ABS(loads(4) + 10.0_wp) < 1.0e-12_wp, 'fast:shared-load')
    body_q = 0.0_wp
    body_v = 0.0_wp
    body_a = 0.0_wp
    offsets(:, 1) = [0.0_wp, 0.0_wp, 0.0_wp]
    offsets(:, 2) = [1.2_wp, 0.0_wp, 0.0_wp]
    offsets(:, 3) = [2.3_wp, 0.0_wp, 0.0_wp]
    CALL CD_FAST_UpdateStates_From_Body(module, body_q, body_v, body_a, offsets, es, em)
    CALL require(es == CD_FAST_OK, 'fast:rigid-update: '//TRIM(em))
    CALL require(ALLOCATED(module%q_work) .AND. ALLOCATED(module%v_work) .AND. ALLOCATED(module%a_work), &
                 'fast:rigid-update-reuses-workspace')
    CALL CD_FAST_GetCoupledMotion(module, qout, vout, aout, es, em)
    CALL require(es == CD_FAST_OK .AND. nan_max_abs(qout - q) < 1.0e-12_wp, 'fast:rigid-update-motion')
    CALL CD_FAST_CalcOutput(module, loads, es, em)
    CALL require(es == CD_FAST_OK, 'fast:rigid-output')
    CALL CD_FAST_CalcBodyWrench(module, body_q, offsets, wrench, es, em)
    CALL require(es == CD_FAST_OK, 'fast:body-wrench: '//TRIM(em))
    CALL require(ALLOCATED(module%load_work), 'fast:body-wrench-reuses-workspace')
    expected_wrench = 0.0_wp
    expected_wrench(1:3) = loads(1:3) + loads(4:6) + loads(7:9)
    expected_wrench(4:6) = cross(offsets(:, 1), loads(1:3)) + cross(offsets(:, 2), loads(4:6)) + &
                           cross(offsets(:, 3), loads(7:9))
    CALL require(nan_max_abs(wrench - expected_wrench) < 1.0e-12_wp, 'fast:body-wrench-sum')
    CALL CD_FAST_CalcOutputDerivatives(module, q, v, a, 1.0e-6_wp, loads, jq, jv, ja, madd, es, em)
    CALL require(es == CD_FAST_OK, 'fast:derivatives: '//TRIM(em))
    CALL require(ABS(jq(1, 4) - 100.0_wp) < 1.0e-5_wp, 'fast:jq-left-from-shared')
    CALL require(ABS(jq(4, 4) + 200.0_wp) < 1.0e-5_wp, 'fast:jq-shared-self')
    CALL require(ABS(jq(7, 4) - 100.0_wp) < 1.0e-5_wp, 'fast:jq-right-from-shared')
    CALL require(nan_max_abs(jv) < 1.0e-8_wp, 'fast:jv-zero')
    CALL require(nan_max_abs(ja) > 1.0e-8_wp, 'fast:ja-present')
    CALL require(nan_max_abs(madd + ja) < 1.0e-8_wp, 'fast:added-mass-negative-ja')
    h = 1.0e-6_wp
    qp = q
    qp(4) = qp(4) + h
    CALL CD_FAST_UpdateStates(module, qp, v, a, es, em)
    CALL require(es == CD_FAST_OK, 'fast:jq-fd-plus-state')
    CALL CD_FAST_CalcOutput(module, plus, es, em)
    CALL require(es == CD_FAST_OK, 'fast:jq-fd-plus-load')
    qp = q
    qp(4) = qp(4) - h
    CALL CD_FAST_UpdateStates(module, qp, v, a, es, em)
    CALL require(es == CD_FAST_OK, 'fast:jq-fd-minus-state')
    CALL CD_FAST_CalcOutput(module, minus, es, em)
    CALL require(es == CD_FAST_OK, 'fast:jq-fd-minus-load')
    CALL require(nan_max_abs(jq(:, 4) - (plus - minus)/(2.0_wp*h)) < 1.0e-7_wp, &
                 'fast:analytic-jq-column-matches-independent-fd')
    vp = v
    vp(4) = vp(4) + h
    CALL CD_FAST_UpdateStates(module, q, vp, a, es, em)
    CALL require(es == CD_FAST_OK, 'fast:jv-fd-plus-state')
    CALL CD_FAST_CalcOutput(module, plus, es, em)
    CALL require(es == CD_FAST_OK, 'fast:jv-fd-plus-load')
    vp = v
    vp(4) = vp(4) - h
    CALL CD_FAST_UpdateStates(module, q, vp, a, es, em)
    CALL require(es == CD_FAST_OK, 'fast:jv-fd-minus-state')
    CALL CD_FAST_CalcOutput(module, minus, es, em)
    CALL require(es == CD_FAST_OK, 'fast:jv-fd-minus-load')
    CALL require(nan_max_abs(jv(:, 4) - (plus - minus)/(2.0_wp*h)) < 1.0e-8_wp, &
                 'fast:analytic-jv-column-matches-independent-fd')
    ap = a
    ap(4) = ap(4) + h
    CALL CD_FAST_UpdateStates(module, q, v, ap, es, em)
    CALL require(es == CD_FAST_OK, 'fast:ja-fd-plus-state')
    CALL CD_FAST_CalcOutput(module, plus, es, em)
    CALL require(es == CD_FAST_OK, 'fast:ja-fd-plus-load')
    ap = a
    ap(4) = ap(4) - h
    CALL CD_FAST_UpdateStates(module, q, v, ap, es, em)
    CALL require(es == CD_FAST_OK, 'fast:ja-fd-minus-state')
    CALL CD_FAST_CalcOutput(module, minus, es, em)
    CALL require(es == CD_FAST_OK, 'fast:ja-fd-minus-load')
    CALL require(nan_max_abs(ja(:, 4) - (plus - minus)/(2.0_wp*h)) < 1.0e-8_wp, &
                 'fast:analytic-ja-column-matches-independent-fd')
    CALL CD_FAST_UpdateStates(module, q, v, a, es, em)
    CALL require(es == CD_FAST_OK, 'fast:ja-fd-restore')
    CALL CD_FAST_GetCoupledMotion(module, qout, vout, aout, es, em)
    CALL require(es == CD_FAST_OK .AND. nan_max_abs(qout - q) < 1.0e-12_wp, 'fast:derivative-restores-state')
    CALL CD_FAST_CalcOutputDerivatives(module, q, v, a, 1.0e-6_wp, loads, bad_jac, jv, ja, madd, es, em)
    CALL require(es == CD_FAST_BADINPUT, 'fast:derivative-shape-reject')
    q = [0.0_wp, 0.0_wp, 0.0_wp, 1.1_wp, 0.0_wp, 0.0_wp, 2.2_wp, 0.0_wp, 0.0_wp]
    CALL CD_FAST_Step(module, 0.01_wp, q, v, a, converged, stalled, n_iter, es, em)
    CALL require(es == CD_FAST_OK .AND. converged .AND. .NOT. stalled, 'fast:step: '//TRIM(em))
    CALL CD_FAST_GetCoupledMotion(module, qout, vout, aout, es, em)
    CALL require(es == CD_FAST_OK .AND. nan_max_abs(qout - q) < 1.0e-12_wp, 'fast:step-motion')
    CALL CD_FAST_CalcOutput(module, loads, es, em)
    CALL require(es == CD_FAST_OK .AND. ABS(loads(4)) < 1.0e-10_wp, 'fast:step-shared-load')
    CALL CD_FAST_End(module, es, em)
    CALL require(es == CD_FAST_OK .AND. .NOT. CD_FAST_IsInitialized(module), 'fast:end')
    CALL require(.NOT. ALLOCATED(module%q_work) .AND. .NOT. ALLOCATED(module%load_work), &
                 'fast:end-releases-workspace')
  END SUBROUTINE case_fast_lifecycle

  SUBROUTINE case_fast_point_mesh()
    TYPE(CD_FAST_ModuleType) :: module
    TYPE(CD_FAST_PointMeshType) :: mesh
    TYPE(CD_ModelType) :: models(2)
    TYPE(CD_SystemPointType) :: points(3)
    TYPE(CD_LineEndpointBinding) :: bindings(4)
    INTEGER :: es, n
    REAL(wp) :: q(9), v(9), a(9), loads(9), body_q(6), body_v(6), body_a(6)
    REAL(wp) :: offsets(3, 3), position(3, 3), velocity(3, 3), acceleration(3, 3), load(3, 3)
    REAL(wp) :: bad_position(2, 3), direct_wrench(6), mesh_wrench(6)
    CHARACTER(240) :: em

    points = [CD_SystemPointType(id=1, point_type=CD_POINT_FIXED), &
              CD_SystemPointType(id=2, point_type=CD_POINT_COUPLED), &
              CD_SystemPointType(id=3, point_type=CD_POINT_FIXED)]
    bindings = [CD_LineEndpointBinding(line_index=1, line_end=CD_LINE_END_A, point_id=1), &
                CD_LineEndpointBinding(line_index=1, line_end=CD_LINE_END_B, point_id=2), &
                CD_LineEndpointBinding(line_index=2, line_end=CD_LINE_END_A, point_id=2), &
                CD_LineEndpointBinding(line_index=2, line_end=CD_LINE_END_B, point_id=3)]
    CALL init_bar(models(1), 0.0_wp, 1.0_wp, es, em)
    CALL require(es == CD_MODEL_OK, 'fast-mesh:init-line-1')
    CALL init_bar(models(2), 1.0_wp, 2.0_wp, es, em)
    CALL require(es == CD_MODEL_OK, 'fast-mesh:init-line-2')
    CALL CD_FAST_Init_From_Points(module, models, points, bindings, es, em)
    CALL require(es == CD_FAST_OK, 'fast-mesh:init-module: '//TRIM(em))
    CALL CD_End_Model(models(1), es, em)
    CALL CD_End_Model(models(2), es, em)

    CALL CD_FAST_Init_PointMesh(mesh, 3, es, em)
    CALL require(es == CD_FAST_MESH_OK .AND. CD_FAST_PointMesh_IsInitialized(mesh), 'fast-mesh:init')
    q = [0.0_wp, 0.0_wp, 0.0_wp, 1.2_wp, 0.0_wp, 0.0_wp, 2.3_wp, 0.0_wp, 0.0_wp]
    v = 0.0_wp
    a = 0.0_wp
    position(:, 1) = q(1:3)
    position(:, 2) = q(4:6)
    position(:, 3) = q(7:9)
    velocity = 0.0_wp
    acceleration = 0.0_wp
    acceleration(1, 2) = 0.7_wp
    bad_position = 0.0_wp
    CALL CD_FAST_Set_PointMesh_State(mesh, bad_position, velocity, acceleration, es, em)
    CALL require(es == CD_FAST_MESH_BADINPUT, 'fast-mesh:reject-bad-shape')
    CALL CD_FAST_Set_PointMesh_State(mesh, position, velocity, acceleration, es, em)
    CALL require(es == CD_FAST_MESH_OK, 'fast-mesh:set-state: '//TRIM(em))
    CALL CD_FAST_UpdateStates_From_PointMesh(module, mesh, es, em)
    CALL require(es == CD_FAST_MESH_OK, 'fast-mesh:update-module: '//TRIM(em))
    CALL CD_FAST_CalcOutput(module, loads, es, em)
    CALL require(es == CD_FAST_OK, 'fast-mesh:direct-output')
    CALL CD_FAST_CalcOutput_To_PointMesh(module, mesh, es, em)
    CALL require(es == CD_FAST_MESH_OK, 'fast-mesh:output-to-mesh: '//TRIM(em))
    CALL CD_FAST_Get_PointMesh_State(mesh, position, velocity, acceleration, load, es, em)
    CALL require(es == CD_FAST_MESH_OK, 'fast-mesh:get-state')
    CALL require(nan_max_abs(load(:, 1) - loads(1:3)) < 1.0e-12_wp .AND. &
                 nan_max_abs(load(:, 2) - loads(4:6)) < 1.0e-12_wp .AND. &
                 nan_max_abs(load(:, 3) - loads(7:9)) < 1.0e-12_wp, 'fast-mesh:load-scatter')
    body_q = 0.0_wp
    body_v = 0.0_wp
    body_a = 0.0_wp
    offsets(:, 1) = [0.0_wp, 0.0_wp, 0.0_wp]
    offsets(:, 2) = [1.2_wp, 0.0_wp, 0.0_wp]
    offsets(:, 3) = [2.3_wp, 0.0_wp, 0.0_wp]
    CALL CD_FAST_CalcBodyWrench(module, body_q, offsets, direct_wrench, es, em)
    CALL require(es == CD_FAST_OK, 'fast-mesh:direct-wrench')
    CALL CD_FAST_CalcBodyWrench_From_PointMesh(mesh, body_q, offsets, mesh_wrench, es, em)
    CALL require(es == CD_FAST_MESH_OK, 'fast-mesh:wrench: '//TRIM(em))
    CALL require(nan_max_abs(mesh_wrench - direct_wrench) < 1.0e-12_wp, 'fast-mesh:wrench-matches-direct')
    body_q = 0.0_wp
    body_v = 0.0_wp
    body_a = 0.0_wp
    CALL CD_FAST_Set_PointMesh_From_Body(mesh, body_q, body_v, body_a, offsets, es, em)
    CALL require(es == CD_FAST_MESH_OK, 'fast-mesh:set-from-body: '//TRIM(em))
    CALL CD_FAST_Get_PointMesh_State(mesh, position, velocity, acceleration, load, es, em)
    CALL require(es == CD_FAST_MESH_OK .AND. nan_max_abs(position - offsets) < 1.0e-12_wp, &
                 'fast-mesh:body-position')
    CALL CD_FAST_End_PointMesh(mesh)
    CALL require(.NOT. CD_FAST_PointMesh_IsInitialized(mesh), 'fast-mesh:end')
    CALL CD_FAST_UpdateStates_From_PointMesh(module, mesh, es, em)
    CALL require(es == CD_FAST_MESH_NOT_INITIALIZED, 'fast-mesh:reject-uninit-update')
    CALL CD_FAST_Init_PointMesh(mesh, 3, es, em)
    CALL require(es == CD_FAST_MESH_OK, 'fast-mesh:reinit')
    CALL CD_FAST_End(module, es, em)
    CALL require(es == CD_FAST_OK, 'fast-mesh:end-module')
    n = CD_FAST_NCoupledDOF(module, es, em)
    CALL require(es == CD_FAST_NOT_INITIALIZED .AND. n == 0, 'fast-mesh:module-ended')
    CALL CD_FAST_UpdateStates_From_PointMesh(module, mesh, es, em)
    CALL require(es == CD_FAST_MESH_NOT_INITIALIZED, 'fast-mesh:reject-uninit-module')
    CALL CD_FAST_End_PointMesh(mesh)
  END SUBROUTINE case_fast_point_mesh

  SUBROUTINE case_fmf_lifecycle()
    TYPE(CD_FMF_ModuleType) :: fmf
    TYPE(CD_FAST_ModuleType) :: direct
    TYPE(CD_ModelType) :: models(2)
    TYPE(CD_SystemPointType) :: points(3)
    TYPE(CD_LineEndpointBinding) :: bindings(4)
    TYPE(CD_LineEndpointBinding) :: bad_bindings(4)
    INTEGER :: es
    INTEGER :: n_iter, direct_iter, committed_iter
    REAL(wp) :: position(3, 3), velocity(3, 3), acceleration(3, 3), load(3, 3)
    REAL(wp) :: loads_direct(9), body_q(6), offsets(3, 3), fmf_wrench(6), direct_wrench(6)
    REAL(wp) :: loads_deriv(9), jq(9, 9), jv(9, 9), ja(9, 9), madd(9, 9)
    LOGICAL :: converged, stalled, direct_converged, direct_stalled, committed_converged, committed_stalled
    CHARACTER(240) :: em

    position = 0.0_wp
    velocity = 0.0_wp
    acceleration = 0.0_wp
    load = 999.0_wp
    converged = .TRUE.
    stalled = .TRUE.
    n_iter = 99
    CALL CD_FMF_Step(fmf, 0.01_wp, position, velocity, acceleration, converged, stalled, n_iter, es, em)
    CALL require(es == CD_FMF_NOT_INITIALIZED .AND. .NOT. converged .AND. .NOT. stalled .AND. n_iter == 0, &
                 'fmf-fail:step-uninit')
    CALL CD_FMF_UpdateStates(fmf, position, velocity, acceleration, es, em)
    CALL require(es == CD_FMF_NOT_INITIALIZED, 'fmf-fail:update-uninit')
    CALL CD_FMF_GetPointMesh(fmf, position, velocity, acceleration, load, es, em)
    CALL require(es == CD_FMF_NOT_INITIALIZED .AND. nan_max_abs(load) < 1.0e-12_wp, 'fmf-fail:get-uninit-zeroes')
    CALL CD_FMF_CalcOutputDerivatives(fmf, 1.0e-6_wp, es, em)
    CALL require(es == CD_FMF_NOT_INITIALIZED, 'fmf-fail:derivatives-uninit')
    points = [CD_SystemPointType(id=1, point_type=CD_POINT_FIXED), &
              CD_SystemPointType(id=2, point_type=CD_POINT_COUPLED), &
              CD_SystemPointType(id=3, point_type=CD_POINT_FIXED)]
    bindings = [CD_LineEndpointBinding(line_index=1, line_end=CD_LINE_END_A, point_id=1), &
                CD_LineEndpointBinding(line_index=1, line_end=CD_LINE_END_B, point_id=2), &
                CD_LineEndpointBinding(line_index=2, line_end=CD_LINE_END_A, point_id=2), &
                CD_LineEndpointBinding(line_index=2, line_end=CD_LINE_END_B, point_id=3)]
    CALL init_bar(models(1), 0.0_wp, 1.0_wp, es, em)
    CALL require(es == CD_MODEL_OK, 'fmf:init-line-1')
    CALL init_bar(models(2), 1.0_wp, 2.0_wp, es, em)
    CALL require(es == CD_MODEL_OK, 'fmf:init-line-2')
    CALL CD_FMF_Init_From_Points(fmf, models, points, bindings, -0.01_wp, es, em)
    CALL require(es == CD_FMF_BADINPUT .AND. .NOT. CD_FMF_IsInitialized(fmf), 'fmf:reject-bad-dt')
    CALL CD_FMF_Init_From_Points(fmf, models, points, bindings, 0.01_wp, es, em)
    CALL require(es == CD_FMF_OK .AND. CD_FMF_IsInitialized(fmf), 'fmf:init: '//TRIM(em))
    CALL require(fmf%init_input%n_coupled_dof == 9 .AND. ABS(fmf%init_input%dt - 0.01_wp) < 1.0e-12_wp, &
                 'fmf:init-input')
    CALL require(fmf%init_output%n_lines == 2 .AND. fmf%init_output%n_coupled_dof == 9, 'fmf:init-output')
    CALL require(fmf%p%n_lines == 2 .AND. fmf%p%n_coupled_dof == 9 .AND. ABS(fmf%p%dt - 0.01_wp) < 1.0e-12_wp, &
                 'fmf:params')
    CALL require(ALLOCATED(fmf%x%x) .AND. ALLOCATED(fmf%x%xd) .AND. ALLOCATED(fmf%z%z) .AND. &
                 SIZE(fmf%x%x) == 0 .AND. SIZE(fmf%x%xd) == 0 .AND. SIZE(fmf%z%z) == 0, 'fmf:init-states')
    ! Regression: querying the point mesh immediately after init -- before any UpdateStates --
    ! must return the initialized system geometry, not the zero-filled exchange/mesh allocations.
    ! Points 2/3 sit at x = 1/2, so a stale zero seed would read (0,0,0) here.
    CALL CD_FMF_GetPointMesh(fmf, position, velocity, acceleration, load, es, em)
    CALL require(es == CD_FMF_OK, 'fmf:get-mesh-after-init')
    CALL require(nan_max_abs(position(:, 2) - [1.0_wp, 0.0_wp, 0.0_wp]) < 1.0e-9_wp .AND. &
                 nan_max_abs(position(:, 3) - [2.0_wp, 0.0_wp, 0.0_wp]) < 1.0e-9_wp, &
                 'fmf:point-mesh-seeded-at-init')
    bad_bindings = bindings
    bad_bindings(1)%point_id = 99
    CALL CD_FMF_Init_From_Points(fmf, models, points, bad_bindings, 0.01_wp, es, em)
    CALL require(es == CD_FMF_BADINPUT .AND. CD_FMF_IsInitialized(fmf), 'fmf:bad-reinit-preserves-module')
    CALL require(fmf%init_output%n_lines == 2 .AND. fmf%init_output%n_coupled_dof == 9, &
                 'fmf:bad-reinit-preserves-records')
    CALL CD_FMF_GetPointMesh(fmf, position, velocity, acceleration, load, es, em)
    CALL require(es == CD_FMF_OK .AND. nan_max_abs(position(:, 2) - [1.0_wp, 0.0_wp, 0.0_wp]) < 1.0e-9_wp, &
                 'fmf:bad-reinit-preserves-mesh')
    CALL CD_FAST_Init_From_Points(direct, models, points, bindings, es, em)
    CALL require(es == CD_FAST_OK, 'fmf:direct-init')
    CALL CD_End_Model(models(1), es, em)
    CALL CD_End_Model(models(2), es, em)

    position(:, 1) = [0.0_wp, 0.0_wp, 0.0_wp]
    position(:, 2) = [1.2_wp, 0.0_wp, 0.0_wp]
    position(:, 3) = [2.3_wp, 0.0_wp, 0.0_wp]
    velocity = 0.0_wp
    acceleration = 0.0_wp
    acceleration(1, 2) = 0.7_wp
    CALL CD_FMF_UpdateStates(fmf, position, velocity, acceleration, es, em)
    CALL require(es == CD_FMF_OK, 'fmf:update: '//TRIM(em))
    CALL CD_FAST_UpdateStates(direct, [position(:, 1), position(:, 2), position(:, 3)], &
                              [velocity(:, 1), velocity(:, 2), velocity(:, 3)], &
                              [acceleration(:, 1), acceleration(:, 2), acceleration(:, 3)], es, em)
    CALL require(es == CD_FAST_OK, 'fmf:direct-update')
    CALL CD_FMF_CalcOutput(fmf, es, em)
    CALL require(es == CD_FMF_OK, 'fmf:calc-output: '//TRIM(em))
    CALL CD_FAST_CalcOutput(direct, loads_direct, es, em)
    CALL require(es == CD_FAST_OK, 'fmf:direct-output')
    CALL require(nan_max_abs(fmf%y%coupled_loads - loads_direct) < 1.0e-12_wp, 'fmf:loads-match-direct')
    position(1, 2) = 1.25_wp
    acceleration(1, 2) = 0.3_wp
    CALL CD_FMF_Step(fmf, 0.01_wp, position, velocity, acceleration, converged, stalled, n_iter, es, em)
    CALL require(es == CD_FMF_OK, 'fmf:step-status: '//TRIM(em))
    CALL CD_FAST_Step(direct, 0.01_wp, [position(:, 1), position(:, 2), position(:, 3)], &
                      [velocity(:, 1), velocity(:, 2), velocity(:, 3)], &
                      [acceleration(:, 1), acceleration(:, 2), acceleration(:, 3)], &
                      direct_converged, direct_stalled, direct_iter, es, em)
    CALL require(es == CD_FAST_OK, 'fmf:direct-step')
    CALL require(converged .EQV. direct_converged .AND. stalled .EQV. direct_stalled .AND. n_iter == direct_iter, &
                 'fmf:step-metadata')
    CALL require(fmf%other%last_converged .EQV. converged .AND. fmf%other%last_stalled .EQV. stalled .AND. &
                 fmf%other%last_num_iter == n_iter, 'fmf:step-other-state')
    CALL CD_FMF_CalcOutput(fmf, es, em)
    CALL require(es == CD_FMF_OK, 'fmf:post-step-output: '//TRIM(em))
    CALL CD_FAST_CalcOutput(direct, loads_direct, es, em)
    CALL require(es == CD_FAST_OK .AND. nan_max_abs(fmf%y%coupled_loads - loads_direct) < 1.0e-12_wp, &
                 'fmf:post-step-loads')
    CALL CD_FMF_CalcOutputDerivatives(fmf, 1.0e-6_wp, es, em)
    CALL require(es == CD_FMF_OK, 'fmf:derivatives: '//TRIM(em))
    CALL CD_FMF_CalcOutputDerivatives(fmf, -1.0_wp, es, em)
    CALL require(es == CD_FMF_BADINPUT, 'fmf:derivatives-reject-negative-eps')
    CALL CD_FMF_CalcOutputDerivatives(fmf, 1.0e-6_wp, es, em)
    CALL require(es == CD_FMF_OK, 'fmf:derivatives-after-reject: '//TRIM(em))
    CALL CD_FAST_CalcOutputDerivatives(direct, fmf%u%q_coupled, fmf%u%v_coupled, fmf%u%a_coupled, 1.0e-6_wp, &
                                       loads_deriv, jq, jv, ja, madd, es, em)
    CALL require(es == CD_FAST_OK, 'fmf:direct-derivatives')
    CALL require(nan_max_abs(fmf%y%coupled_loads - loads_deriv) < 1.0e-12_wp, 'fmf:derivative-loads')
    CALL require(nan_max_abs(fmf%y%dload_dq - jq) < 1.0e-12_wp, 'fmf:derivative-jq')
    CALL require(nan_max_abs(fmf%y%dload_dv - jv) < 1.0e-12_wp, 'fmf:derivative-jv')
    CALL require(nan_max_abs(fmf%y%dload_da - ja) < 1.0e-12_wp, 'fmf:derivative-ja')
    CALL require(nan_max_abs(fmf%y%added_mass - madd) < 1.0e-12_wp, 'fmf:derivative-added-mass')
    CALL CD_FMF_GetPointMesh(fmf, position, velocity, acceleration, load, es, em)
    CALL require(es == CD_FMF_OK, 'fmf:get-mesh')
    CALL require(nan_max_abs(load(:, 1) - loads_direct(1:3)) < 1.0e-12_wp .AND. &
                 nan_max_abs(load(:, 2) - loads_direct(4:6)) < 1.0e-12_wp .AND. &
                 nan_max_abs(load(:, 3) - loads_direct(7:9)) < 1.0e-12_wp, 'fmf:mesh-loads')
    body_q = 0.0_wp
    offsets(:, 1) = [0.0_wp, 0.0_wp, 0.0_wp]
    offsets(:, 2) = [1.2_wp, 0.0_wp, 0.0_wp]
    offsets(:, 3) = [2.3_wp, 0.0_wp, 0.0_wp]
    CALL CD_FMF_CalcBodyWrench(fmf, body_q, offsets, fmf_wrench, es, em)
    CALL require(es == CD_FMF_OK, 'fmf:wrench: '//TRIM(em))
    CALL CD_FAST_CalcBodyWrench(direct, body_q, offsets, direct_wrench, es, em)
    CALL require(es == CD_FAST_OK, 'fmf:direct-wrench')
    CALL require(nan_max_abs(fmf_wrench - direct_wrench) < 1.0e-12_wp, 'fmf:wrench-match-direct')
    ! A rejected system step must not publish convergence metadata from the rejected
    ! attempt. The pure-system aggregate relies on this FMF behavior because it takes
    ! no outer snapshot, keeping the normal mooring-only step free of that overhead.
    committed_iter = fmf%other%last_num_iter
    committed_converged = fmf%other%last_converged
    committed_stalled = fmf%other%last_stalled
    fmf%fast%system%lines(1)%f_ext(1) = IEEE_VALUE(fmf%fast%system%lines(1)%f_ext(1), IEEE_QUIET_NAN)
    CALL CD_FMF_Step(fmf, 0.01_wp, position, velocity, acceleration, converged, stalled, n_iter, es, em)
    CALL require(es /= CD_FMF_OK .AND. .NOT. converged, 'fmf:rejected-step-status')
    CALL require(fmf%other%last_num_iter == committed_iter .AND. &
                 (fmf%other%last_converged .EQV. committed_converged) .AND. &
                 (fmf%other%last_stalled .EQV. committed_stalled), 'fmf:rejected-step-metadata-atomic')
    CALL CD_FMF_End(fmf, es, em)
    CALL require(es == CD_FMF_OK .AND. .NOT. CD_FMF_IsInitialized(fmf), 'fmf:end')
    CALL require(.NOT. ALLOCATED(fmf%x%x) .AND. .NOT. ALLOCATED(fmf%x%xd) .AND. .NOT. ALLOCATED(fmf%z%z), &
                 'fmf:end-states')
    CALL CD_FMF_CalcOutput(fmf, es, em)
    CALL require(es == CD_FMF_NOT_INITIALIZED, 'fmf-fail:output-after-end')
    CALL CD_FAST_End(direct, es, em)
    CALL require(es == CD_FAST_OK, 'fmf:direct-end')
  END SUBROUTINE case_fmf_lifecycle

  SUBROUTINE case_fmf_external_point_fluid()
    TYPE(CD_FMF_ModuleType) :: ref, hydro
    TYPE(CD_FAST_ModuleType) :: fast_probe
    TYPE(CD_ModelType) :: models(2)
    TYPE(CD_SystemPointType) :: points(3)
    TYPE(CD_LineEndpointBinding) :: bindings(4)
    INTEGER :: es, n_iter
    REAL(wp) :: position(3, 3), velocity(3, 3), acceleration(3, 3), load(3, 3)
    REAL(wp) :: qout(9), vout(9), aout(9)
    REAL(wp) :: fluid_velocity(3, 3), fluid_acceleration(3, 3), waterline_z(3), bad_fluid(2, 3)
    REAL(wp) :: ref_a(3), ref_v(3), hydro_a(3), hydro_v(3)
    LOGICAL :: converged, stalled
    CHARACTER(240) :: em

    points = [CD_SystemPointType(id=1, point_type=CD_POINT_FIXED, q=[0.0_wp, 0.0_wp, 0.0_wp]), &
              CD_SystemPointType(id=2, point_type=CD_POINT_FREE, q=[1.0_wp, 0.0_wp, -1.0_wp], &
                                 mass=10.0_wp, volume=0.01_wp, cda=2.0_wp, ca=1.0_wp), &
              CD_SystemPointType(id=3, point_type=CD_POINT_FIXED, q=[2.0_wp, 0.0_wp, 0.0_wp])]
    bindings = [CD_LineEndpointBinding(line_index=1, line_end=CD_LINE_END_A, point_id=1), &
                CD_LineEndpointBinding(line_index=1, line_end=CD_LINE_END_B, point_id=2), &
                CD_LineEndpointBinding(line_index=2, line_end=CD_LINE_END_A, point_id=2), &
                CD_LineEndpointBinding(line_index=2, line_end=CD_LINE_END_B, point_id=3)]
    CALL init_bar(models(1), 0.0_wp, 1.0_wp, es, em)
    CALL require(es == CD_MODEL_OK, 'fmf-fluid:init-line-1')
    CALL init_bar(models(2), 1.0_wp, 2.0_wp, es, em)
    CALL require(es == CD_MODEL_OK, 'fmf-fluid:init-line-2')
    CALL CD_FMF_Init_From_Points(ref, models, points, bindings, 0.01_wp, es, em)
    CALL require(es == CD_FMF_OK, 'fmf-fluid:init-ref: '//TRIM(em))
    CALL CD_FMF_Init_From_Points(hydro, models, points, bindings, 0.01_wp, es, em)
    CALL require(es == CD_FMF_OK, 'fmf-fluid:init-hydro: '//TRIM(em))
    CALL CD_FAST_Init_From_Points(fast_probe, models, points, bindings, es, em)
    CALL require(es == CD_FAST_OK, 'fmf-fluid:init-fast-probe: '//TRIM(em))
    CALL CD_End_Model(models(1), es, em)
    CALL CD_End_Model(models(2), es, em)

    position(:, 1) = [0.0_wp, 0.0_wp, 0.0_wp]
    position(:, 2) = [1.0_wp, 0.0_wp, -1.0_wp]
    position(:, 3) = [2.0_wp, 0.0_wp, 0.0_wp]
    velocity = 0.0_wp
    acceleration = 0.0_wp
    fluid_velocity = 0.0_wp
    fluid_acceleration = 0.0_wp
    waterline_z = 0.0_wp
    bad_fluid = 0.0_wp

    CALL CD_FAST_UpdatePointFluidFields(fast_probe, bad_fluid, fluid_acceleration, waterline_z, 1000.0_wp, es, em)
    CALL require(es == CD_FAST_BADINPUT, 'fmf-fluid:fast-reject-bad-shape')
    CALL CD_FAST_UpdatePointFluidFields(fast_probe, fluid_velocity, fluid_acceleration, waterline_z, &
                                        1000.0_wp, es, em)
    CALL require(es == CD_FAST_OK, 'fmf-fluid:fast-update: '//TRIM(em))
    CALL CD_FAST_End(fast_probe, es, em)
    CALL require(es == CD_FAST_OK, 'fmf-fluid:fast-end')

    CALL CD_FMF_UpdatePointFluidFields(hydro, bad_fluid, fluid_acceleration, waterline_z, 1000.0_wp, es, em)
    CALL require(es == CD_FMF_BADINPUT, 'fmf-fluid:reject-bad-shape')
    fluid_velocity(1, 2) = 1.0_wp
    fluid_acceleration(3, 2) = 0.5_wp
    CALL CD_FMF_UpdatePointFluidFields(hydro, fluid_velocity, fluid_acceleration, waterline_z, 1000.0_wp, es, em)
    CALL require(es == CD_FMF_OK, 'fmf-fluid:update: '//TRIM(em))

    CALL CD_FMF_Step(ref, 0.01_wp, position, velocity, acceleration, converged, stalled, n_iter, es, em)
    CALL require(es == CD_FMF_OK .AND. converged .AND. .NOT. stalled, 'fmf-fluid:step-ref: '//TRIM(em))
    CALL CD_FMF_GetPointMesh(ref, position, velocity, acceleration, load, es, em)
    CALL require(es == CD_FMF_OK, 'fmf-fluid:get-ref')
    ref_v = velocity(:, 2)
    ref_a = acceleration(:, 2)

    position(:, 1) = [0.0_wp, 0.0_wp, 0.0_wp]
    position(:, 2) = [1.0_wp, 0.0_wp, -1.0_wp]
    position(:, 3) = [2.0_wp, 0.0_wp, 0.0_wp]
    velocity = 0.0_wp
    acceleration = 0.0_wp
    CALL CD_FMF_Step(hydro, 0.01_wp, position, velocity, acceleration, converged, stalled, n_iter, es, em)
    CALL require(es == CD_FMF_OK .AND. converged .AND. .NOT. stalled, 'fmf-fluid:step-hydro: '//TRIM(em))
    CALL CD_FMF_GetPointMesh(hydro, position, velocity, acceleration, load, es, em)
    CALL require(es == CD_FMF_OK, 'fmf-fluid:get-hydro')
    hydro_v = velocity(:, 2)
    hydro_a = acceleration(:, 2)
    CALL require(hydro_a(1) > ref_a(1) .AND. hydro_v(1) > ref_v(1), 'fmf-fluid:drag-accelerates-free-point')
    CALL require(hydro_a(3) > ref_a(3) .AND. hydro_v(3) > ref_v(3), 'fmf-fluid:fk-accelerates-free-point')
    CALL require(nan_max_abs(position(:, 2) - [1.0_wp, 0.0_wp, -1.0_wp]) > 1.0e-12_wp, &
                 'fmf-fluid:point-mesh-refreshed-after-dynamic-step')

    CALL CD_FMF_End(ref, es, em)
    CALL require(es == CD_FMF_OK, 'fmf-fluid:end-ref')
    CALL CD_FMF_End(hydro, es, em)
    CALL require(es == CD_FMF_OK, 'fmf-fluid:end-hydro')
    CALL CD_FAST_GetCoupledMotion(fast_probe, qout, vout, aout, es, em)
    CALL require(es == CD_FAST_NOT_INITIALIZED .AND. nan_max_abs(qout) < 1.0e-12_wp .AND. &
                 nan_max_abs(vout) < 1.0e-12_wp .AND. nan_max_abs(aout) < 1.0e-12_wp, &
                 'fmf-fluid:fast-ended-zero-motion')
  END SUBROUTINE case_fmf_external_point_fluid

  SUBROUTINE case_fmf_deck_init()
    TYPE(CD_FMF_ModuleType) :: fmf
    INTEGER :: es
    REAL(wp) :: position(3, 2), velocity(3, 2), acceleration(3, 2), load(3, 2)
    CHARACTER(240) :: em

    CALL write_fmf_deck('fmf_deck.dat', 0.0_wp)
    CALL CD_FMF_Init_From_Deck(fmf, 'fmf_deck.dat', 0.01_wp, es, em)
    CALL require(es == CD_FMF_OK .AND. CD_FMF_IsInitialized(fmf), 'fmf-deck:init: '//TRIM(em))
    CALL require(fmf%init_input%n_coupled_dof == 6 .AND. fmf%init_output%n_lines == 1, 'fmf-deck:init-records')
    CALL require(fmf%p%n_coupled_dof == 6 .AND. fmf%p%n_lines == 1 .AND. ABS(fmf%p%dt - 0.01_wp) < 1.0e-12_wp, &
                 'fmf-deck:params')
    CALL require(ALLOCATED(fmf%x%x) .AND. ALLOCATED(fmf%x%xd) .AND. ALLOCATED(fmf%z%z), 'fmf-deck:init-states')
    position(:, 1) = [400.0_wp, 0.0_wp, -50.0_wp]
    position(:, 2) = [0.0_wp, 0.0_wp, 0.0_wp]
    velocity = 0.0_wp
    acceleration = 0.0_wp
    CALL CD_FMF_UpdateStates(fmf, position, velocity, acceleration, es, em)
    CALL require(es == CD_FMF_OK, 'fmf-deck:update: '//TRIM(em))
    CALL CD_FMF_CalcOutput(fmf, es, em)
    CALL require(es == CD_FMF_OK, 'fmf-deck:output: '//TRIM(em))
    CALL CD_FMF_GetPointMesh(fmf, position, velocity, acceleration, load, es, em)
    CALL require(es == CD_FMF_OK, 'fmf-deck:get-mesh')
    CALL require(nan_max_abs(load(:, 1) - fmf%y%coupled_loads(1:3)) < 1.0e-12_wp .AND. &
                 nan_max_abs(load(:, 2) - fmf%y%coupled_loads(4:6)) < 1.0e-12_wp, 'fmf-deck:load-scatter')
    CALL write_fmf_deck('fmf_bad_finite.dat', 1.0_wp)
    CALL CD_FMF_Init_From_Deck(fmf, 'fmf_bad_finite.dat', 0.01_wp, es, em)
    CALL require(es == CD_FMF_BADINPUT .AND. CD_FMF_IsInitialized(fmf), 'fmf-deck:bad-reinit-preserves-module')
    CALL require(fmf%init_input%n_coupled_dof == 6 .AND. fmf%init_output%n_lines == 1, &
                 'fmf-deck:bad-reinit-preserves-records')
    CALL CD_FMF_GetPointMesh(fmf, position, velocity, acceleration, load, es, em)
    CALL require(es == CD_FMF_OK .AND. nan_max_abs(position(:, 1) - [400.0_wp, 0.0_wp, -50.0_wp]) < 1.0e-9_wp, &
                 'fmf-deck:bad-reinit-preserves-mesh')
    CALL CD_FMF_End(fmf, es, em)
    CALL require(es == CD_FMF_OK, 'fmf-deck:end')

    CALL CD_FMF_Init_From_Deck(fmf, 'fmf_bad_finite.dat', 0.01_wp, es, em)
    CALL require(es == CD_FMF_BADINPUT .AND. .NOT. CD_FMF_IsInitialized(fmf), 'fmf-deck:reject-finite')

    ! A viscoelastic (ElasticMod > 1) EI=0 line now BUILDS on the pure
    ! CD_FMF_Init_From_Deck coupled path: the glue checkpoint mirror carries the
    ! per-element dl_1 and the in-process System snapshot carries it too, so the
    ! interior reload restores the SLS partition exactly.
    CALL write_fmf_visco_deck('fmf_visco.dat')
    CALL CD_FMF_Init_From_Deck(fmf, 'fmf_visco.dat', 0.01_wp, es, em)
    CALL require(es == CD_FMF_OK .AND. CD_FMF_IsInitialized(fmf), &
                 'fmf-deck:accept-viscoelastic: '//TRIM(em))
    CALL CD_FMF_End(fmf, es, em)
    CALL require(es == CD_FMF_OK, 'fmf-deck:visco-end')
  END SUBROUTINE case_fmf_deck_init

  SUBROUTINE case_fmf_rotational_stiffness()
    !! L4 rotational-stiffness gate (the coupled-path quantity nothing standalone
    !! exercised): platform rotation must reach the fairleads and come back as a
    !! restoring moment.
    !!
    !! CONVENTIONS (fixed here so a future cross-code A/B cannot misread a sign):
    !! the gated quantity is Delta Fz = Fz(held attitude) - Fz(rest), where F is
    !! the force the mooring exerts ON the platform (so Fz < 0 at rest: the chain
    !! pulls down). Positive pitch theta about +y tips the +x axis DOWN, so the
    !! upwind fairlead at x = -58 m RISES by Delta z = -x sin(theta) = +1.01 m at
    !! 1 deg. A rising catenary fairlead lifts more chain: its TENSION INCREASES
    !! and the downward pull strengthens, hence "tightens" pairs with
    !! Delta Fz < 0 (here -16.0 kN); the dipping downwind pair slackens,
    !! Delta Fz > 0 (+7.8 kN each).
    !!
    !! On the IEA-15MW VolturnUS-S three-line geometry:
    !!   (1) the host-prescribed (moving) mesh contains EXACTLY the Vessel
    !!       fairleads -- never the Fixed anchors (anchors in the mesh
    !!       would cancel the differential response and suppress coupled
    !!       pitch/roll/yaw ~100x);
    !!   (2) under a held 1 deg pure pitch the upwind line tightens
    !!       (Delta Fz < 0) and the two downwind lines slacken symmetrically
    !!       (Delta Fz > 0);
    !!   (3) the fairlead forces produce a RESTORING pitch moment about the
    !!       rotation origin (~7.9e7 N m/rad, ~4% of the hydrostatic pitch
    !!       stiffness -- the moment cell and the three tension cells close on
    !!       each other to first order);
    !!   (4) the response is first-order in the rotation: Delta F(1 deg) tracks
    !!       2 x Delta F(0.5 deg).
    !! COMPLETION (part of the quantitative A/B comparison): the cross-code cell --
    !! stock MoorDyn's fairlead tensions at the SAME held 1 deg attitude, both
    !! codes settled to their own converged statics, converting this gate's
    !! internal consistency into cross-code parity on rotational stiffness
    !! itself.
    TYPE(CD_FMF_ModuleType) :: fmf
    INTEGER :: es, i, n
    CHARACTER(512) :: em
    REAL(wp), PARAMETER :: FAIR(3, 3) = RESHAPE([-58.0_wp, 0.0_wp, -14.0_wp, &
                                                 29.0_wp, 50.229_wp, -14.0_wp, &
                                                 29.0_wp, -50.229_wp, -14.0_wp], [3, 3])
    REAL(wp) :: pos0(3, 3), f0(3, 3), fp(3, 3), fh(3, 3), dF1(3, 3), dFh(3, 3)
    REAL(wp) :: my0, my1

    CALL write_volturnus_moving_deck('fmf_volturnus.dat')
    CALL CD_FMF_Init_From_Deck(fmf, 'fmf_volturnus.dat', 0.05_wp, es, em)
    CALL require(es == CD_FMF_OK .AND. CD_FMF_IsInitialized(fmf), 'l4-rot:init: '//TRIM(em))

    ! (1) the moving mesh is the three Vessel fairleads, in deck point order
    n = CD_FMF_NMovingPoints(fmf, es, em)
    CALL require(es == CD_FMF_OK .AND. n == 3, 'l4-rot:moving-mesh-holds-only-the-fairleads')
    CALL settle_moving(fmf, FAIR, f0, pos0, es, em)
    CALL require(es == CD_FMF_OK, 'l4-rot:rest-settle: '//TRIM(em))
    CALL require(nan_max_abs(pos0 - FAIR) < 1.0e-9_wp, 'l4-rot:moving-positions-are-the-fairleads')
    ! rest state: symmetric pretension, near-zero pitch moment about the origin
    my0 = pitch_moment(FAIR, f0)
    CALL require(ABS(my0) < 1.0e-3_wp*moment_scale(FAIR, f0), 'l4-rot:rest-pitch-moment-near-zero')

    ! (2)+(3) held 1 deg pitch
    CALL settle_moving(fmf, pitched(FAIR, 1.0_wp), fp, pos0, es, em)
    CALL require(es == CD_FMF_OK, 'l4-rot:pitch-settle: '//TRIM(em))
    dF1 = fp - f0
    WRITE (*, '(A,3ES12.4)') 'L4-rot dFz per line at 1 deg pitch (N): ', dF1(3, :)
    ! The upwind fairlead rises (Delta z = +58 sin(theta)): a rising catenary
    ! fairlead lifts more chain, so its tension INCREASES and the downward pull on
    ! the platform strengthens (Delta Fz < 0). The two downwind fairleads dip and
    ! slacken (Delta Fz > 0). This differential IS the mooring pitch stiffness.
    CALL require(dF1(3, 1) < -1.0e3_wp, 'l4-rot:upwind-line-tightens-as-its-fairlead-rises')
    CALL require(dF1(3, 2) > 1.0e3_wp .AND. dF1(3, 3) > 1.0e3_wp, 'l4-rot:downwind-lines-slacken')
    CALL require(ABS(dF1(1, 2) - dF1(1, 3)) <= 1.0e-6_wp*nan_max_abs(f0) .AND. &
                 ABS(dF1(3, 2) - dF1(3, 3)) <= 1.0e-6_wp*nan_max_abs(f0) .AND. &
                 ABS(dF1(2, 2) + dF1(2, 3)) <= 1.0e-6_wp*nan_max_abs(f0), 'l4-rot:downwind-pair-symmetric')
    my1 = pitch_moment(pitched(FAIR, 1.0_wp), fp)
    CALL require(my1 - my0 < -1.0e5_wp, 'l4-rot:mooring-moment-restores-pitch')

    ! (4) first-order in the rotation: half the angle gives half the response
    CALL settle_moving(fmf, pitched(FAIR, 0.5_wp), fh, pos0, es, em)
    CALL require(es == CD_FMF_OK, 'l4-rot:half-pitch-settle: '//TRIM(em))
    dFh = fh - f0
    WRITE (*, '(A,3ES12.4)') 'L4-rot dFz per line at 0.5 deg pitch (N): ', dFh(3, :)
    ! First-order-in-rotation guard: doubling the angle roughly doubles the
    ! response. The band is 30%: the measured catenary force-displacement relation
    ! is visibly curved over the ~1 m fairlead travel (7% stiffening upwind, 22%
    ! softening downwind at 1 deg) -- the assert exists to catch a broken kinematic
    ! chain (zero, sign-flipped, or quadratic response), not to certify linearity.
    DO i = 1, 3
      CALL require(ABS(dF1(3, i) - 2.0_wp*dFh(3, i)) < 0.30_wp*ABS(dF1(3, i)), &
                   'l4-rot:vertical-response-first-order-in-rotation')
    END DO

    ! moving-surface shape guard fails closed
    CALL require(shape_guard_fails(fmf), 'l4-rot:moving-shape-guard')
    CALL CD_FMF_End(fmf, es, em)
    CALL require(es == CD_FMF_OK, 'l4-rot:end')
  END SUBROUTINE case_fmf_rotational_stiffness

  FUNCTION pitched(fair, theta_deg) RESULT(p)
    !! Rigid pure pitch of the fairlead set about +y through the origin.
    REAL(wp), INTENT(IN) :: fair(3, 3), theta_deg
    REAL(wp) :: p(3, 3), c, s
    INTEGER :: i
    c = COS(theta_deg*ACOS(-1.0_wp)/180.0_wp)
    s = SIN(theta_deg*ACOS(-1.0_wp)/180.0_wp)
    DO i = 1, 3
      p(1, i) = c*fair(1, i) + s*fair(3, i)
      p(2, i) = fair(2, i)
      p(3, i) = -s*fair(1, i) + c*fair(3, i)
    END DO
  END FUNCTION pitched

  REAL(wp) FUNCTION pitch_moment(r, f) RESULT(my)
    !! Moment about +y at the origin of the fairlead force set: sum(z Fx - x Fz).
    REAL(wp), INTENT(IN) :: r(3, 3), f(3, 3)
    INTEGER :: i
    my = 0.0_wp
    DO i = 1, 3
      my = my + r(3, i)*f(1, i) - r(1, i)*f(3, i)
    END DO
  END FUNCTION pitch_moment

  REAL(wp) FUNCTION moment_scale(r, f) RESULT(s)
    !! Magnitude scale for moment comparisons: sum |r| |f|.
    REAL(wp), INTENT(IN) :: r(3, 3), f(3, 3)
    INTEGER :: i
    s = 0.0_wp
    DO i = 1, 3
      s = s + NORM2(r(:, i))*NORM2(f(:, i))
    END DO
  END FUNCTION moment_scale

  SUBROUTINE settle_moving(fmf, target_pos, loads, pos_out, ErrStat, ErrMsg)
    !! Bring the moving points to target_pos QUASI-STATICALLY -- a linear ramp from
    !! their current positions with the matching constant velocity (no impulsive
    !! attitude jump, so no lightly-damped lateral transient to outwait) -- then
    !! hold with zero rates until the fairlead loads settle.
    TYPE(CD_FMF_ModuleType), INTENT(INOUT) :: fmf
    REAL(wp), INTENT(IN) :: target_pos(3, 3)
    REAL(wp), INTENT(OUT) :: loads(3, 3), pos_out(3, 3)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    REAL(wp), PARAMETER :: DT = 0.05_wp
    INTEGER, PARAMETER :: N_RAMP = 400, N_HOLD = 4000
    REAL(wp) :: start(3, 3), vel(3, 3), acc(3, 3), prev(3, 3), p(3, 3), v(3, 3), a(3, 3)
    REAL(wp) :: frac
    INTEGER :: k, es, niter, settled
    LOGICAL :: conv, stalled
    CHARACTER(512) :: em
    loads = 0.0_wp
    pos_out = 0.0_wp
    CALL CD_FMF_GetMovingPointMesh(fmf, start, v, a, loads, ErrStat, ErrMsg)
    IF (ErrStat /= CD_FMF_OK) RETURN
    acc = 0.0_wp
    vel = (target_pos - start)/(REAL(N_RAMP, wp)*DT)
    DO k = 1, N_RAMP
      frac = REAL(k, wp)/REAL(N_RAMP, wp)
      p = start + frac*(target_pos - start)
      CALL CD_FMF_Step_Moving(fmf, DT, p, vel, acc, conv, stalled, niter, es, em)
      IF (es /= CD_FMF_OK .OR. .NOT. conv) THEN
        ErrStat = MERGE(es, 2, es /= 0)
        ErrMsg = 'ramp step did not converge: '//TRIM(em)
        RETURN
      END IF
    END DO
    vel = 0.0_wp
    prev = HUGE(1.0_wp)
    settled = 0
    DO k = 1, N_HOLD
      CALL CD_FMF_Step_Moving(fmf, DT, target_pos, vel, acc, conv, stalled, niter, es, em)
      IF (es /= CD_FMF_OK .OR. .NOT. conv) THEN
        ErrStat = MERGE(es, 2, es /= 0)
        ErrMsg = 'hold step did not converge: '//TRIM(em)
        RETURN
      END IF
      CALL CD_FMF_CalcOutput(fmf, es, em)
      IF (es /= CD_FMF_OK) THEN
        ErrStat = es
        ErrMsg = 'settle output failed: '//TRIM(em)
        RETURN
      END IF
      CALL CD_FMF_GetMovingPointMesh(fmf, p, v, a, loads, es, em)
      IF (es /= CD_FMF_OK) THEN
        ErrStat = es
        ErrMsg = 'settle mesh read failed: '//TRIM(em)
        RETURN
      END IF
      IF (nan_max_abs(loads - prev) < 1.0e-5_wp*MAX(1.0_wp, nan_max_abs(loads))) THEN
        settled = settled + 1
        IF (settled >= 3) THEN
          pos_out = p
          ErrStat = 0
          ErrMsg = ''
          RETURN
        END IF
      ELSE
        settled = 0
      END IF
      prev = loads
    END DO
    ErrStat = 2
    ErrMsg = 'held-attitude loads did not settle within the step budget'
  END SUBROUTINE settle_moving

  LOGICAL FUNCTION shape_guard_fails(fmf) RESULT(ok)
    !! The moving surface must reject full-vector-shaped (anchors included) arrays.
    TYPE(CD_FMF_ModuleType), INTENT(INOUT) :: fmf
    REAL(wp) :: p6(3, 6), v6(3, 6), a6(3, 6)
    INTEGER :: es
    CHARACTER(512) :: em
    p6 = 0.0_wp
    v6 = 0.0_wp
    a6 = 0.0_wp
    CALL CD_FMF_UpdateStates_Moving(fmf, p6, v6, a6, es, em)
    ok = (es == CD_FMF_BADINPUT)
  END FUNCTION shape_guard_fails

  SUBROUTINE write_volturnus_moving_deck(path)
    !! IEA-15MW VolturnUS-S three-chain mooring in the CableDyn deck dialect
    !! (End A = Vessel fairlead, End B = Fixed anchor), 20 segments per line.
    CHARACTER(*), INTENT(IN) :: path
    INTEGER :: u, ios
    OPEN (NEWUNIT=u, FILE=path, STATUS='REPLACE', ACTION='WRITE', IOSTAT=ios)
    WRITE (u, '(A)') 'IEA-15MW VolturnUS-S mooring, CableDyn deck (rotational-stiffness gate)'
    WRITE (u, '(A)') '--- LINE TYPES ---'
    WRITE (u, '(A)') 'Name Diam Mass EA BA EI Cdn Cdt Can Cat'
    WRITE (u, '(A)') '(-) (m) (kg/m) (N) (-) (Nm2) (-) (-) (-) (-)'
    WRITE (u, '(A)') 'main 0.333 685.0 3.27e9 -1.0 0.0 2.0 0.4 0.82 0.27'
    WRITE (u, '(A)') '--- POINTS ---'
    WRITE (u, '(A)') 'ID Type X Y Z'
    WRITE (u, '(A)') '(-) (-) (m) (m) (m)'
    WRITE (u, '(A)') '1 Vessel  -58.000   0.000  -14.0'
    WRITE (u, '(A)') '2 Fixed  -837.600   0.000 -200.0'
    WRITE (u, '(A)') '3 Vessel   29.000  50.229  -14.0'
    WRITE (u, '(A)') '4 Fixed   418.800 725.383 -200.0'
    WRITE (u, '(A)') '5 Vessel   29.000 -50.229  -14.0'
    WRITE (u, '(A)') '6 Fixed   418.800 -725.383 -200.0'
    WRITE (u, '(A)') '--- LINES ---'
    WRITE (u, '(A)') 'ID NodeA NodeB Outputs'
    WRITE (u, '(A)') '(-) (-) (-) (-)'
    WRITE (u, '(A)') '1 1 2 -'
    WRITE (u, '(A)') '2 3 4 -'
    WRITE (u, '(A)') '3 5 6 -'
    WRITE (u, '(A)') '--- SECTIONS ---'
    WRITE (u, '(A)') 'LineID LineType Length NumSegs'
    WRITE (u, '(A)') '(-) (-) (m) (-)'
    WRITE (u, '(A)') '1 main 850.0 20'
    WRITE (u, '(A)') '2 main 850.0 20'
    WRITE (u, '(A)') '3 main 850.0 20'
    WRITE (u, '(A)') '--- OPTIONS ---'
    WRITE (u, '(A)') '9.80665 g'
    WRITE (u, '(A)') '1025.0 rhoW'
    WRITE (u, '(A)') '200.0 WtrDpth'
    WRITE (u, '(A)') '3.0e6 kBot'
    WRITE (u, '(A)') '3.0e5 cBot'
    WRITE (u, '(A)') '--- OUTPUTS ---'
    WRITE (u, '(A)') 'FairTen1 FairTen2 FairTen3'
    WRITE (u, '(A)') '--- need this line ---'
    CLOSE (u)
  END SUBROUTINE write_volturnus_moving_deck

  SUBROUTINE case_fast_fail_closed()
    TYPE(CD_FAST_ModuleType) :: module
    REAL(wp) :: q(3), v(3), a(3), loads(3)
    INTEGER :: es, n
    LOGICAL :: converged, stalled
    CHARACTER(240) :: em

    q = 0.0_wp
    v = 0.0_wp
    a = 0.0_wp
    CALL CD_FAST_UpdateStates(module, q, v, a, es, em)
    CALL require(es == CD_FAST_NOT_INITIALIZED, 'fast-fail:update-uninit')
    converged = .TRUE.
    stalled = .TRUE.
    n = 99
    CALL CD_FAST_Step(module, 0.01_wp, q, v, a, converged, stalled, n, es, em)
    CALL require(es == CD_FAST_NOT_INITIALIZED .AND. .NOT. converged .AND. .NOT. stalled .AND. n == 0, &
                 'fast-fail:step-uninit')
    loads = 123.0_wp
    CALL CD_FAST_CalcOutput(module, loads, es, em)
    CALL require(es == CD_FAST_NOT_INITIALIZED .AND. nan_max_abs(loads) < 1.0e-12_wp, 'fast-fail:output-uninit')
    q = 123.0_wp
    v = 456.0_wp
    a = 789.0_wp
    CALL CD_FAST_GetCoupledMotion(module, q, v, a, es, em)
    CALL require(es == CD_FAST_NOT_INITIALIZED .AND. nan_max_abs(q) < 1.0e-12_wp .AND. &
                 nan_max_abs(v) < 1.0e-12_wp .AND. nan_max_abs(a) < 1.0e-12_wp, 'fast-fail:get-motion-uninit')
    n = CD_FAST_NCoupledDOF(module, es, em)
    CALL require(es == CD_FAST_NOT_INITIALIZED .AND. n == 0, 'fast-fail:ncoupled-uninit')
    CALL CD_FAST_End(module, es, em)
    CALL require(es == CD_FAST_OK, 'fast-fail:end-uninit')
  END SUBROUTINE case_fast_fail_closed

  SUBROUTINE case_registry_types()
    TYPE(CD_InitInputType) :: init_input
    TYPE(CD_InitOutputType) :: init_output
    TYPE(CD_InputType) :: input
    TYPE(CD_InputType) :: input_copy
    TYPE(CD_InputType) :: bad_input
    TYPE(CD_OutputType) :: output
    TYPE(CD_OutputType) :: output_copy
    TYPE(CD_ParameterType) :: params
    TYPE(CD_ParameterType) :: params_copy
    TYPE(CD_ContinuousStateType) :: continuous
    TYPE(CD_ContinuousStateType) :: continuous_copy
    TYPE(CD_ConstraintStateType) :: constraint
    TYPE(CD_ConstraintStateType) :: constraint_copy
    TYPE(CD_DiscreteStateType) :: discrete, discrete_copy
    TYPE(CD_OtherStateType) :: other, other_copy
    INTEGER :: es
    CHARACTER(240) :: em

    init_input%n_coupled_dof = 9
    init_input%dt = 0.01_wp
    init_output%n_lines = 2
    init_output%n_coupled_dof = init_input%n_coupled_dof
    CALL require(init_input%n_coupled_dof == 9 .AND. ABS(init_input%dt - 0.01_wp) < 1.0e-12_wp, &
                 'fast-types:init-input')
    CALL require(init_output%n_lines == 2 .AND. init_output%n_coupled_dof == 9, 'fast-types:init-output')
    CALL CD_OpenFAST_Types_InitExchange(input, output, params, 9, es, em)
    CALL require(es == CD_TYPES_OK, 'fast-types:init: '//TRIM(em))
    CALL require(params%n_coupled_dof == 9, 'fast-types:ncoupled')
    CALL require(SIZE(input%q_coupled) == 9 .AND. SIZE(input%v_coupled) == 9, 'fast-types:input-size')
    CALL require(SIZE(output%coupled_loads) == 9, 'fast-types:output-size')
    CALL require(ALL(SHAPE(output%added_mass) == [9, 9]), 'fast-types:added-mass-size')
    CALL require(ALL(SHAPE(output%dload_dq) == [9, 9]), 'fast-types:jac-size')
    input%q_coupled = 1.0_wp
    output%coupled_loads = 2.0_wp
    output%dload_dq(1, 4) = 100.0_wp
    CALL require(ABS(SUM(input%q_coupled) - 9.0_wp) < 1.0e-12_wp, 'fast-types:input-write')
    CALL require(ABS(SUM(output%coupled_loads) - 18.0_wp) < 1.0e-12_wp, 'fast-types:output-write')
    CALL require(ABS(output%dload_dq(1, 4) - 100.0_wp) < 1.0e-12_wp, 'fast-types:jac-write')
    CALL CD_OpenFAST_Types_CopyInput(input, input_copy, es, em)
    CALL require(es == CD_TYPES_OK .AND. ALLOCATED(input_copy%q_coupled), 'fast-types:copy-input: '//TRIM(em))
    input%q_coupled = 3.0_wp
    CALL require(ABS(SUM(input_copy%q_coupled) - 9.0_wp) < 1.0e-12_wp, 'fast-types:copy-input-deep')
    ALLOCATE (bad_input%q_coupled(2))
    CALL CD_OpenFAST_Types_CopyInput(bad_input, input_copy, es, em)
    CALL require(es == CD_TYPES_BADINPUT .AND. .NOT. ALLOCATED(input_copy%q_coupled), 'fast-types:copy-input-partial')
    CALL CD_OpenFAST_Types_CopyOutput(output, output_copy, es, em)
    CALL require(es == CD_TYPES_OK .AND. ALLOCATED(output_copy%coupled_loads), 'fast-types:copy-output: '//TRIM(em))
    output%coupled_loads = 4.0_wp
    CALL require(ABS(SUM(output_copy%coupled_loads) - 18.0_wp) < 1.0e-12_wp, 'fast-types:copy-output-deep')
    params%n_lines = 4
    params%dt = 0.2_wp
    CALL CD_OpenFAST_Types_CopyParameters(params, params_copy)
    CALL require(params_copy%n_lines == 4 .AND. ABS(params_copy%dt - 0.2_wp) < 1.0e-12_wp, &
                 'fast-types:copy-params')
    CALL CD_OpenFAST_Types_InitStates(continuous, constraint, 3, 2, es, em)
    CALL require(es == CD_TYPES_OK .AND. SIZE(continuous%x) == 3 .AND. SIZE(constraint%z) == 2, &
                 'fast-types:init-states: '//TRIM(em))
    continuous%x = [1.0_wp, 2.0_wp, 3.0_wp]
    continuous%xd = [4.0_wp, 5.0_wp, 6.0_wp]
    constraint%z = [7.0_wp, 8.0_wp]
    CALL CD_OpenFAST_Types_CopyContinuousState(continuous, continuous_copy, es, em)
    CALL require(es == CD_TYPES_OK .AND. ABS(SUM(continuous_copy%x) - 6.0_wp) < 1.0e-12_wp, &
                 'fast-types:copy-continuous')
    CALL CD_OpenFAST_Types_CopyConstraintState(constraint, constraint_copy, es, em)
    CALL require(es == CD_TYPES_OK .AND. ABS(SUM(constraint_copy%z) - 15.0_wp) < 1.0e-12_wp, &
                 'fast-types:copy-constraint')
    continuous%x = 9.0_wp
    constraint%z = 10.0_wp
    CALL require(ABS(SUM(continuous_copy%x) - 6.0_wp) < 1.0e-12_wp .AND. &
                 ABS(SUM(constraint_copy%z) - 15.0_wp) < 1.0e-12_wp, 'fast-types:copy-state-deep')
    discrete%reserved = 12
    other%last_num_iter = 13
    other%last_converged = .FALSE.
    other%last_stalled = .TRUE.
    CALL CD_OpenFAST_Types_CopyDiscreteState(discrete, discrete_copy)
    CALL CD_OpenFAST_Types_CopyOtherState(other, other_copy)
    CALL require(discrete_copy%reserved == 12 .AND. other_copy%last_num_iter == 13 .AND. &
                 .NOT. other_copy%last_converged .AND. other_copy%last_stalled, 'fast-types:copy-scalar-states')
    CALL CD_OpenFAST_Types_InitStates(continuous, constraint, -1, 0, es, em)
    CALL require(es == CD_TYPES_BADINPUT .AND. ALLOCATED(continuous%x) .AND. ALLOCATED(constraint%z), &
                 'fast-types:bad-state-init-preserves-allocation')
    CALL CD_OpenFAST_Types_InitExchange(input, output, params, -1, es, em)
    CALL require(es /= CD_TYPES_OK .AND. ALLOCATED(input%q_coupled) .AND. ALLOCATED(output%coupled_loads), &
                 'fast-types:bad-reinit-preserves-allocation')
    CALL require(SIZE(input%q_coupled) == 9 .AND. SIZE(output%coupled_loads) == 9, &
                 'fast-types:bad-reinit-preserves-size')
    CALL require(ABS(SUM(input%q_coupled) - 27.0_wp) < 1.0e-12_wp, &
                 'fast-types:bad-reinit-preserves-input-values')
    CALL require(ABS(SUM(output%coupled_loads) - 36.0_wp) < 1.0e-12_wp, &
                 'fast-types:bad-reinit-preserves-output-values')
    CALL CD_OpenFAST_Types_EndExchange(input, output)
    CALL require(.NOT. ALLOCATED(input%q_coupled) .AND. .NOT. ALLOCATED(output%coupled_loads), 'fast-types:end')
    CALL require(.NOT. ALLOCATED(output%added_mass) .AND. .NOT. ALLOCATED(output%dload_dq), 'fast-types:end-jac')
    CALL CD_OpenFAST_Types_EndExchange(input_copy, output_copy)
    CALL CD_OpenFAST_Types_EndExchange(bad_input, output_copy)
    CALL CD_OpenFAST_Types_EndStates(continuous, constraint)
    CALL CD_OpenFAST_Types_EndStates(continuous_copy, constraint_copy)
    CALL require(.NOT. ALLOCATED(continuous%x) .AND. .NOT. ALLOCATED(constraint%z), 'fast-types:end-states')
  END SUBROUTINE case_registry_types

  SUBROUTINE case_size_overflow_guards()
    !! The OpenFAST-facing init size arithmetic must fail closed on a corrupted /
    !! huge count BEFORE allocating, rather than wrap a default-integer product and
    !! under-size the buffers. (Counts here far exceed any physical mesh/DOF size.)
    TYPE(CD_FAST_PointMeshType) :: mesh
    TYPE(CD_InputType) :: input
    TYPE(CD_OutputType) :: output
    TYPE(CD_ParameterType) :: params
    INTEGER :: es
    CHARACTER(240) :: em

    ! 3 * 800,000,000 = 2.4e9 overflows a 32-bit DOF count -> reject, do not allocate.
    CALL CD_FAST_Init_PointMesh(mesh, 800000000, es, em)
    CALL require(es == CD_FAST_MESH_BADINPUT .AND. .NOT. CD_FAST_PointMesh_IsInitialized(mesh), &
                 'overflow:mesh-3n-rejected')
    ! 50000^2 = 2.5e9 overflows n_coupled_dof^2 -> reject before allocating the n*n blocks.
    CALL CD_OpenFAST_Types_InitExchange(input, output, params, 50000, es, em)
    CALL require(es == CD_TYPES_BADINPUT .AND. .NOT. ALLOCATED(output%added_mass), &
                 'overflow:types-nn-rejected')
  END SUBROUTINE case_size_overflow_guards

  SUBROUTINE require(cond, label)
    LOGICAL, INTENT(IN) :: cond
    CHARACTER(*), INTENT(IN) :: label
    IF (.NOT. cond) THEN
      WRITE (*, '(A,A,A)') 'MISMATCH [', TRIM(label), ']: condition false'
      nfail = nfail + 1
    END IF
  END SUBROUTINE require

  PURE FUNCTION cross(a, b) RESULT(c)
    REAL(wp), INTENT(IN) :: a(3), b(3)
    REAL(wp) :: c(3)
    c = [a(2)*b(3) - a(3)*b(2), a(3)*b(1) - a(1)*b(3), a(1)*b(2) - a(2)*b(1)]
  END FUNCTION cross

  SUBROUTINE write_fmf_deck(path, ei)
    CHARACTER(*), INTENT(IN) :: path
    REAL(wp), INTENT(IN) :: ei
    INTEGER :: u

    OPEN (NEWUNIT=u, FILE=path, STATUS='REPLACE', ACTION='WRITE')
    WRITE (u, '(A)') 'OpenFAST shell deck-init line'
    WRITE (u, '(A)') '--- LINE TYPES ---'
    WRITE (u, '(A)') 'Name Diam Mass EA BA EI Cdn Cdt Can Cat'
    WRITE (u, '(A)') '(-) (m) (kg/m) (N) (-) (Nm2) (-) (-) (-) (-)'
    WRITE (u, '(A,ES12.4,A)') 'chain 0.252 390.0 1.674e9 -1.0 ', ei, ' 1.37 0.64 1.0 0.0'
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
    WRITE (u, '(A)') '--- OUTPUTS ---'
    WRITE (u, '(A)') 'FairTen1 AnchTen1'
    WRITE (u, '(A)') '--- need this line ---'
    CLOSE (u)
  END SUBROUTINE write_fmf_deck

  SUBROUTINE write_fmf_visco_deck(path)
    !! An EI=0 coupled chain with a viscoelastic (ElasticMod 2) EA pipe column:
    !! must fail closed on the coupled FMF facade (no dl_1 in the state mirror).
    CHARACTER(*), INTENT(IN) :: path
    INTEGER :: u

    OPEN (NEWUNIT=u, FILE=path, STATUS='REPLACE', ACTION='WRITE')
    WRITE (u, '(A)') 'OpenFAST shell viscoelastic deck-init line'
    WRITE (u, '(A)') '--- LINE TYPES ---'
    WRITE (u, '(A)') 'Name Diam Mass EA BA EI Cdn Cdt Can Cat'
    WRITE (u, '(A)') '(-) (m) (kg/m) (N) (-) (Nm2) (-) (-) (-) (-)'
    WRITE (u, '(A)') 'rope 0.252 390.0 1.674e9|2.0e9 5.0e9|1.0e6 0.0 1.37 0.64 1.0 0.0'
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
    WRITE (u, '(A)') '1 rope 410.0 41'
    WRITE (u, '(A)') '--- OPTIONS ---'
    WRITE (u, '(A)') '9.80665 g'
    WRITE (u, '(A)') '1025.0 rhoW'
    WRITE (u, '(A)') '50.0 WtrDpth'
    WRITE (u, '(A)') '1.0e5 kBot'
    WRITE (u, '(A)') '--- OUTPUTS ---'
    WRITE (u, '(A)') 'FairTen1 AnchTen1'
    WRITE (u, '(A)') '--- need this line ---'
    CLOSE (u)
  END SUBROUTINE write_fmf_visco_deck

  SUBROUTINE case_fmf_deck_friction()
    !! Regression: a non-dynamic-point (Fixed/Coupled) EI=0 line deck with seabed friction
    !! must initialize through the C/FMF deck path. The friction/motionFile rejection applies
    !! only to Connect/Free/Body/Rod dynamic-point decks; init_one_model wires seabed_mu for the
    !! supported line decks, so this deck must build rather than fail closed.
    TYPE(CD_FMF_ModuleType) :: fmf
    INTEGER :: es
    CHARACTER(240) :: em

    CALL write_fmf_friction_deck('fmf_friction_deck.dat')
    CALL CD_FMF_Init_From_Deck(fmf, 'fmf_friction_deck.dat', 0.01_wp, es, em)
    CALL require(es == CD_FMF_OK .AND. CD_FMF_IsInitialized(fmf), 'fmf-friction:init: '//TRIM(em))
    CALL require(fmf%init_output%n_lines == 1, 'fmf-friction:init-records')
    CALL CD_FMF_End(fmf, es, em)
    CALL require(es == CD_FMF_OK, 'fmf-friction:end')
  END SUBROUTINE case_fmf_deck_friction

  SUBROUTINE write_fmf_friction_deck(path)
    CHARACTER(*), INTENT(IN) :: path
    INTEGER :: u

    OPEN (NEWUNIT=u, FILE=path, STATUS='REPLACE', ACTION='WRITE')
    WRITE (u, '(A)') 'OpenFAST shell friction line deck (non-dynamic-point)'
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
    WRITE (u, '(A)') '0.5 frictionMu'
    WRITE (u, '(A)') '0.01 dtM'
    WRITE (u, '(A)') '1.0 TMax'
    WRITE (u, '(A)') '--- OUTPUTS ---'
    WRITE (u, '(A)') 'FairTen1 AnchTen1'
    WRITE (u, '(A)') '--- need this line ---'
    CLOSE (u)
  END SUBROUTINE write_fmf_friction_deck

END PROGRAM test_openfast_shell
