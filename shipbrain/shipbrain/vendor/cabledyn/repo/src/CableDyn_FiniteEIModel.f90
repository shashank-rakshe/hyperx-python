! File: src/CableDyn_FiniteEIModel.f90
! SPDX-License-Identifier: Apache-2.0
! Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
MODULE CableDyn_FiniteEIModel
  !! Lifecycle wrapper for the finite-EI dynamic Cosserat line of the secondary
  !! (non-production) Cosserat path: persistent model state owns mesh,
  !! material/inertia properties, constraints, external loads, and generalized-alpha
  !! policy, while the numerical kernel is CableDyn_CosseratDynamic. The formulation is the geometrically
  !! exact Cosserat finite-EI line with Chung-Hulbert generalized-alpha stepping
  !! (Chung & Hulbert 1993; Simo & Vu-Quoc 1988 reference-frame consistent mass).
  USE CableDyn_Precision, ONLY: wp, CD_ZERO, CD_ONE, CD_All_Finite, CD_Is_Finite
  USE CableDyn_Dynamic, ONLY: GenAlphaConfig, CD_DYN_OK, CD_DYN_BADINPUT
  USE CableDyn_CosseratDynamic, ONLY: CD_Cosserat_Initial_Acceleration, &
                                      CD_Cosserat_Gen_Alpha_Step, &
                                      CD_Cosserat_Dynamic_Force_Proc, &
                                      CD_Cosserat_Dynamic_Load_Banded_Proc, &
                                      CD_Cosserat_Mechanical_Energy, &
                                      CD_CosseratGenAlphaWorkspace, &
                                      CD_Clear_CosseratGenAlpha_Workspace
  USE CableDyn_Mesh, ONLY: CD_Validate_Connectivity
  IMPLICIT NONE
  PRIVATE

  PUBLIC :: CD_FiniteEIModelType
  PUBLIC :: CD_Init_FiniteEI_Model
  PUBLIC :: CD_Step_FiniteEI_Model
  PUBLIC :: CD_Set_FiniteEI_Model_PrescribedDofs
  PUBLIC :: CD_Set_FiniteEI_Model_Load
  PUBLIC :: CD_Get_FiniteEI_Model_State
  PUBLIC :: CD_FiniteEI_Model_Energy
  PUBLIC :: CD_FiniteEI_Model_Is_Initialized
  PUBLIC :: CD_End_FiniteEI_Model

  TYPE :: CD_FiniteEIModelType
    !! Persistent finite-EI dynamic line state. DOF ordering is
    !! [x,y,z,theta_x,theta_y,theta_z] per node, 1-based in fixed_dofs.
    LOGICAL :: initialized = .FALSE.
    LOGICAL :: reduced_shear = .TRUE.
    ! DIAGNOSTIC-ONLY opt-in (default off): when .TRUE., a step that leaves any element in axial
    ! compression fails closed (post-buckling cable states are unsupported on this path).
    ! It is deliberately NOT wired into the deck/API product paths -- a taut line can pass through
    ! benign transient micro-compression that a hard reject would spuriously kill; enable it when
    ! diagnosing a suspected post-buckling blow-up.
    LOGICAL :: reject_axial_compression = .FALSE.
    TYPE(GenAlphaConfig) :: cfg
    REAL(wp), ALLOCATABLE :: nodes_ref(:, :)
    INTEGER, ALLOCATABLE :: elem_conn(:, :)
    REAL(wp), ALLOCATABLE :: ea(:), gas(:), ei(:), gj(:)
    REAL(wp), ALLOCATABLE :: rho_a(:), i_rho_t(:), i_rho_n(:)
    REAL(wp), ALLOCATABLE :: q(:), v(:), a(:), f_ext(:)
    REAL(wp), ALLOCATABLE :: q_step(:), v_step(:), a_step(:)
    REAL(wp), ALLOCATABLE :: energy_mass_work(:)
    INTEGER, ALLOCATABLE :: fixed_dofs(:)
    TYPE(CD_CosseratGenAlphaWorkspace) :: dynamic_workspace
  END TYPE CD_FiniteEIModelType

CONTAINS

  SUBROUTINE CD_Init_FiniteEI_Model(model, nodes_ref, elem_conn, ea, gas, ei, gj, &
                                    rho_a, i_rho_t, i_rho_n, reduced_shear, &
                                    ErrStat, ErrMsg, q0, v0, f_ext, fixed_dofs, cfg)
    !! Initialize a finite-EI dynamic line model and compute its consistent
    !! initial acceleration. Optional q0/v0/f_ext/default constraints let callers
    !! seed a restart; absent q0 gives the straight reference state with zero
    !! rotation, absent v0/f_ext gives zero, and absent fixed_dofs gives free-free.
    TYPE(CD_FiniteEIModelType), INTENT(INOUT) :: model
    REAL(wp), INTENT(IN) :: nodes_ref(:, :)
    INTEGER, INTENT(IN) :: elem_conn(:, :)
    REAL(wp), INTENT(IN) :: ea(:), gas(:), ei(:), gj(:)
    REAL(wp), INTENT(IN) :: rho_a(:), i_rho_t(:), i_rho_n(:)
    LOGICAL, INTENT(IN) :: reduced_shear
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    REAL(wp), INTENT(IN), OPTIONAL :: q0(:), v0(:), f_ext(:)
    INTEGER, INTENT(IN), OPTIONAL :: fixed_dofs(:)
    TYPE(GenAlphaConfig), INTENT(IN), OPTIONAL :: cfg

    INTEGER :: n_nodes, n_elem, n_dof, i, es
    TYPE(CD_FiniteEIModelType) :: old_model
    CHARACTER(1024) :: em

    ErrStat = CD_DYN_OK
    ErrMsg = ''
    old_model = model

    IF (SIZE(nodes_ref, 1) /= 3 .OR. SIZE(elem_conn, 1) /= 2) THEN
      CALL fail(ErrStat, ErrMsg, 'CD_Init_FiniteEI_Model: nodes_ref must be (3,n), elem_conn must be (2,e)')
      RETURN
    END IF
    n_nodes = SIZE(nodes_ref, 2)
    n_elem = SIZE(elem_conn, 2)
    n_dof = 6*n_nodes
    IF (n_nodes < 2 .OR. n_elem < 1) THEN
      CALL fail(ErrStat, ErrMsg, 'CD_Init_FiniteEI_Model: need at least two nodes and one element')
      RETURN
    END IF
    CALL CD_Validate_Connectivity(elem_conn, n_nodes, n_elem, es, em)
    IF (es /= 0) THEN
      CALL fail(ErrStat, ErrMsg, 'CD_Init_FiniteEI_Model: '//TRIM(em))
      RETURN
    END IF
    IF (SIZE(ea) /= n_elem .OR. SIZE(gas) /= n_elem .OR. SIZE(ei) /= n_elem .OR. SIZE(gj) /= n_elem .OR. &
        SIZE(rho_a) /= n_elem .OR. SIZE(i_rho_t) /= n_elem .OR. SIZE(i_rho_n) /= n_elem) THEN
      CALL fail(ErrStat, ErrMsg, 'CD_Init_FiniteEI_Model: property arrays must have length n_elem')
      RETURN
    END IF
    IF (.NOT. CD_All_Finite(nodes_ref) .OR. .NOT. CD_All_Finite(ea) .OR. &
        .NOT. CD_All_Finite(gas) .OR. .NOT. CD_All_Finite(ei) .OR. &
        .NOT. CD_All_Finite(gj) .OR. .NOT. CD_All_Finite(rho_a) .OR. &
        .NOT. CD_All_Finite(i_rho_t) .OR. .NOT. CD_All_Finite(i_rho_n)) THEN
      CALL fail(ErrStat, ErrMsg, 'CD_Init_FiniteEI_Model: mesh/properties must be finite')
      RETURN
    END IF
    IF (.NOT. ALL(ea > CD_ZERO) .OR. .NOT. ALL(gas > CD_ZERO) .OR. .NOT. ALL(ei > CD_ZERO) .OR. &
        .NOT. ALL(gj > CD_ZERO) .OR. .NOT. ALL(rho_a > CD_ZERO) .OR. &
        .NOT. ALL(i_rho_t > CD_ZERO) .OR. .NOT. ALL(i_rho_n > CD_ZERO)) THEN
      CALL fail(ErrStat, ErrMsg, 'CD_Init_FiniteEI_Model: stiffness and inertia properties must be positive')
      RETURN
    END IF
    IF (PRESENT(q0)) THEN
      IF (SIZE(q0) /= n_dof .OR. .NOT. CD_All_Finite(q0)) THEN
        CALL fail(ErrStat, ErrMsg, 'CD_Init_FiniteEI_Model: q0 must be finite and length 6*n_nodes')
        RETURN
      END IF
    END IF
    IF (PRESENT(v0)) THEN
      IF (SIZE(v0) /= n_dof .OR. .NOT. CD_All_Finite(v0)) THEN
        CALL fail(ErrStat, ErrMsg, 'CD_Init_FiniteEI_Model: v0 must be finite and length 6*n_nodes')
        RETURN
      END IF
    END IF
    IF (PRESENT(f_ext)) THEN
      IF (SIZE(f_ext) /= n_dof .OR. .NOT. CD_All_Finite(f_ext)) THEN
        CALL fail(ErrStat, ErrMsg, 'CD_Init_FiniteEI_Model: f_ext must be finite and length 6*n_nodes')
        RETURN
      END IF
    END IF
    IF (PRESENT(fixed_dofs)) THEN
      IF (ANY(fixed_dofs < 1) .OR. ANY(fixed_dofs > n_dof)) THEN
        CALL fail(ErrStat, ErrMsg, 'CD_Init_FiniteEI_Model: fixed_dofs contains an out-of-range DOF index')
        RETURN
      END IF
      DO i = 1, SIZE(fixed_dofs) - 1
        IF (ANY(fixed_dofs(i + 1:) == fixed_dofs(i))) THEN
          CALL fail(ErrStat, ErrMsg, 'CD_Init_FiniteEI_Model: fixed_dofs contains duplicate DOF indices')
          RETURN
        END IF
      END DO
    END IF

    CALL CD_End_FiniteEI_Model(model, es, em)
    ALLOCATE (model%nodes_ref(3, n_nodes), model%elem_conn(2, n_elem))
    ALLOCATE (model%ea(n_elem), model%gas(n_elem), model%ei(n_elem), model%gj(n_elem))
    ALLOCATE (model%rho_a(n_elem), model%i_rho_t(n_elem), model%i_rho_n(n_elem))
    ALLOCATE (model%q(n_dof), model%v(n_dof), model%a(n_dof), model%f_ext(n_dof))
    ALLOCATE (model%q_step(n_dof), model%v_step(n_dof), model%a_step(n_dof))
    ALLOCATE (model%energy_mass_work(n_dof))
    model%nodes_ref = nodes_ref
    model%elem_conn = elem_conn
    model%ea = ea
    model%gas = gas
    model%ei = ei
    model%gj = gj
    model%rho_a = rho_a
    model%i_rho_t = i_rho_t
    model%i_rho_n = i_rho_n
    model%reduced_shear = reduced_shear
    IF (PRESENT(cfg)) model%cfg = cfg

    IF (PRESENT(q0)) THEN
      model%q = q0
    ELSE
      model%q = CD_ZERO
      DO i = 1, n_nodes
        model%q(6*i - 5:6*i - 3) = nodes_ref(:, i)
      END DO
    END IF

    IF (PRESENT(v0)) THEN
      model%v = v0
    ELSE
      model%v = CD_ZERO
    END IF

    IF (PRESENT(f_ext)) THEN
      model%f_ext = f_ext
    ELSE
      model%f_ext = CD_ZERO
    END IF
    model%q_step = CD_ZERO
    model%v_step = CD_ZERO
    model%a_step = CD_ZERO
    model%energy_mass_work = CD_ZERO

    IF (PRESENT(fixed_dofs)) THEN
      ALLOCATE (model%fixed_dofs(SIZE(fixed_dofs)))
      model%fixed_dofs = fixed_dofs
    ELSE
      ALLOCATE (model%fixed_dofs(0))
    END IF

    CALL CD_Cosserat_Initial_Acceleration(model%nodes_ref, model%elem_conn, model%ea, model%gas, model%ei, &
                                          model%gj, model%rho_a, model%i_rho_t, model%i_rho_n, &
                                          model%reduced_shear, model%q, model%f_ext, model%fixed_dofs, &
                                          model%a, es, em, workspace=model%dynamic_workspace, &
                                          v=model%v, multiplicative=model%cfg%multiplicative_rotation)
    IF (es /= CD_DYN_OK) THEN
      CALL fail(ErrStat, ErrMsg, 'CD_Init_FiniteEI_Model: initial acceleration failed: '//TRIM(em))
      CALL CD_End_FiniteEI_Model(model, es, em)
      model = old_model
      RETURN
    END IF

    model%initialized = .TRUE.
  END SUBROUTINE CD_Init_FiniteEI_Model

  SUBROUTINE CD_Step_FiniteEI_Model(model, dt, converged, stalled, n_iter, ErrStat, ErrMsg, &
                                    q_fixed_target, v_fixed_target, a_fixed_target, load_force_proc, load_band_proc)
    !! Advance the finite-EI model by one generalized-alpha step. On numerical
    !! success or Newton stall with a retryable advanced state, the stored state is
    !! updated from the kernel outputs; on invalid input/singular solve it is left
    !! unchanged by the kernel contract.
    !!
    !! When q/v/a_fixed_target are supplied (together, full-length; only the fixed-DOF
    !! entries are read), the prescribed (fixed) DOFs follow that trajectory to t_{n+1}
    !! -- a MOVING support whose velocity/acceleration couple into the dynamic residual --
    !! instead of being held at the stored position. Absent -> the held-support contract.
    TYPE(CD_FiniteEIModelType), INTENT(INOUT) :: model
    REAL(wp), INTENT(IN) :: dt
    LOGICAL, INTENT(OUT) :: converged, stalled
    INTEGER, INTENT(OUT) :: n_iter, ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    REAL(wp), INTENT(IN), OPTIONAL :: q_fixed_target(:), v_fixed_target(:), a_fixed_target(:)
    PROCEDURE(CD_Cosserat_Dynamic_Force_Proc), OPTIONAL :: load_force_proc
    PROCEDURE(CD_Cosserat_Dynamic_Load_Banded_Proc), OPTIONAL :: load_band_proc
    INTEGER :: n_dof

    converged = .FALSE.
    stalled = .FALSE.
    n_iter = 0
    ErrStat = CD_DYN_OK
    ErrMsg = ''
    IF (.NOT. model%initialized) THEN
      CALL fail(ErrStat, ErrMsg, 'CD_Step_FiniteEI_Model: model is not initialized')
      RETURN
    END IF
    IF (.NOT. CD_Is_Finite(dt) .OR. dt <= CD_ZERO) THEN
      CALL fail(ErrStat, ErrMsg, 'CD_Step_FiniteEI_Model: dt must be finite and positive')
      RETURN
    END IF
    ! Mirror the integrator's all-three-together contract here so a partial target set fails
    ! closed instead of silently taking the held branch and dropping the supplied v/a.
    IF ((PRESENT(q_fixed_target) .NEQV. PRESENT(v_fixed_target)) .OR. &
        (PRESENT(q_fixed_target) .NEQV. PRESENT(a_fixed_target))) THEN
      CALL fail(ErrStat, ErrMsg, 'CD_Step_FiniteEI_Model: q/v/a_fixed_target must be supplied together')
      RETURN
    END IF
    IF (PRESENT(q_fixed_target)) THEN
      n_dof = SIZE(model%q)
      IF (SIZE(q_fixed_target) /= n_dof .OR. SIZE(v_fixed_target) /= n_dof .OR. &
          SIZE(a_fixed_target) /= n_dof) THEN
        CALL fail(ErrStat, ErrMsg, 'CD_Step_FiniteEI_Model: q/v/a_fixed_target must be length 6*n_nodes')
        RETURN
      END IF
      IF (.NOT. CD_All_Finite(q_fixed_target) .OR. .NOT. CD_All_Finite(v_fixed_target) .OR. &
          .NOT. CD_All_Finite(a_fixed_target)) THEN
        CALL fail(ErrStat, ErrMsg, 'CD_Step_FiniteEI_Model: q/v/a_fixed_target values must be finite')
        RETURN
      END IF
    END IF
    IF (model%reject_axial_compression) THEN
      CALL check_tensile_cable_state(model, model%q, ErrStat, ErrMsg)
      IF (ErrStat /= CD_DYN_OK) RETURN
    END IF
    IF (PRESENT(q_fixed_target)) THEN
      CALL CD_Cosserat_Gen_Alpha_Step(model%nodes_ref, model%elem_conn, model%ea, model%gas, model%ei, model%gj, &
                                      model%rho_a, model%i_rho_t, model%i_rho_n, model%reduced_shear, &
                                      model%q, model%v, model%a, model%f_ext, model%fixed_dofs, dt, &
                                      model%cfg, model%q_step, model%v_step, model%a_step, &
                                      converged, stalled, n_iter, ErrStat, ErrMsg, &
                                      q_fixed_target=q_fixed_target, v_fixed_target=v_fixed_target, &
                                      a_fixed_target=a_fixed_target, load_force_proc=load_force_proc, &
                                      load_band_proc=load_band_proc, workspace=model%dynamic_workspace)
    ELSE
      CALL CD_Cosserat_Gen_Alpha_Step(model%nodes_ref, model%elem_conn, model%ea, model%gas, model%ei, model%gj, &
                                      model%rho_a, model%i_rho_t, model%i_rho_n, model%reduced_shear, &
                                      model%q, model%v, model%a, model%f_ext, model%fixed_dofs, dt, &
                                      model%cfg, model%q_step, model%v_step, model%a_step, &
                                      converged, stalled, n_iter, ErrStat, ErrMsg, load_force_proc=load_force_proc, &
                                      load_band_proc=load_band_proc, &
                                      workspace=model%dynamic_workspace)
    END IF
    IF (ErrStat == CD_DYN_OK) THEN
      ! The diagnostic cable-domain guard applies to the state produced by this
      ! step as well as to q_n.  A moving support or a converged Newton update can
      ! enter compression even when the committed input state was tensile.  Check
      ! the candidate before committing it so a rejected step is transactional.
      IF (model%reject_axial_compression) THEN
        CALL check_tensile_cable_state(model, model%q_step, ErrStat, ErrMsg)
        IF (ErrStat /= CD_DYN_OK) THEN
          converged = .FALSE.
          stalled = .FALSE.
          RETURN
        END IF
      END IF
      model%q = model%q_step
      model%v = model%v_step
      model%a = model%a_step
    END IF
  END SUBROUTINE CD_Step_FiniteEI_Model

  SUBROUTINE CD_Set_FiniteEI_Model_PrescribedDofs(model, dofs, q_vals, v_vals, a_vals, ErrStat, ErrMsg, &
                                                  recompute_acceleration)
    !! Replace prescribed fixed-DOF state values and recompute a consistent free
    !! acceleration. Only DOFs already present in model%fixed_dofs may be updated;
    !! this keeps prescribed support motion out of the free structural unknowns.
    TYPE(CD_FiniteEIModelType), INTENT(INOUT) :: model
    INTEGER, INTENT(IN) :: dofs(:)
    REAL(wp), INTENT(IN) :: q_vals(:), v_vals(:), a_vals(:)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    LOGICAL, INTENT(IN), OPTIONAL :: recompute_acceleration

    INTEGER :: i, d, es
    LOGICAL :: do_recompute
    REAL(wp), ALLOCATABLE :: q_tmp(:), v_tmp(:), a_tmp(:), a_presc(:)
    CHARACTER(1024) :: em

    ErrStat = CD_DYN_OK
    ErrMsg = ''
    do_recompute = .TRUE.
    IF (PRESENT(recompute_acceleration)) do_recompute = recompute_acceleration
    IF (.NOT. model%initialized) THEN
      CALL fail(ErrStat, ErrMsg, 'CD_Set_FiniteEI_Model_PrescribedDofs: model is not initialized')
      RETURN
    END IF
    IF (SIZE(dofs) /= SIZE(q_vals) .OR. SIZE(dofs) /= SIZE(v_vals) .OR. SIZE(dofs) /= SIZE(a_vals)) THEN
      CALL fail(ErrStat, ErrMsg, 'CD_Set_FiniteEI_Model_PrescribedDofs: dofs/q/v/a shapes must match')
      RETURN
    END IF
    IF (.NOT. CD_All_Finite(q_vals) .OR. .NOT. CD_All_Finite(v_vals) .OR. &
        .NOT. CD_All_Finite(a_vals)) THEN
      CALL fail(ErrStat, ErrMsg, 'CD_Set_FiniteEI_Model_PrescribedDofs: q/v/a values must be finite')
      RETURN
    END IF
    DO i = 1, SIZE(dofs)
      d = dofs(i)
      IF (d < 1 .OR. d > SIZE(model%q)) THEN
        CALL fail(ErrStat, ErrMsg, 'CD_Set_FiniteEI_Model_PrescribedDofs: DOF index out of range')
        RETURN
      END IF
      IF (i < SIZE(dofs)) THEN
        IF (ANY(dofs(i + 1:) == d)) THEN
          CALL fail(ErrStat, ErrMsg, 'CD_Set_FiniteEI_Model_PrescribedDofs: duplicate DOF index')
          RETURN
        END IF
      END IF
      IF (.NOT. ANY(model%fixed_dofs == d)) THEN
        CALL fail(ErrStat, ErrMsg, 'CD_Set_FiniteEI_Model_PrescribedDofs: DOF is not a prescribed fixed DOF')
        RETURN
      END IF
    END DO

    q_tmp = model%q
    v_tmp = model%v
    a_tmp = model%a
    DO i = 1, SIZE(dofs)
      d = dofs(i)
      q_tmp(d) = q_vals(i)
      v_tmp(d) = v_vals(i)
      a_tmp(d) = a_vals(i)
    END DO
    IF (.NOT. do_recompute) THEN
      model%q = q_tmp
      model%v = v_tmp
      model%a = a_tmp
      RETURN
    END IF
    ! a_presc carries the prescribed support accelerations at the fixed DOFs so the consistent
    ! free solve keeps the M_fp a_p coupling (an accelerating endpoint). Distinct from a_tmp
    ! because a_tmp is the INTENT(OUT) target (zeroed at entry) -- aliasing would be illegal.
    a_presc = a_tmp
    CALL CD_Cosserat_Initial_Acceleration(model%nodes_ref, model%elem_conn, model%ea, model%gas, model%ei, &
                                          model%gj, model%rho_a, model%i_rho_t, model%i_rho_n, &
                                          model%reduced_shear, q_tmp, model%f_ext, model%fixed_dofs, &
                                          a_tmp, es, em, a_prescribed=a_presc, workspace=model%dynamic_workspace, &
                                          v=v_tmp, multiplicative=model%cfg%multiplicative_rotation)
    IF (es /= CD_DYN_OK) THEN
      CALL fail(ErrStat, ErrMsg, 'CD_Set_FiniteEI_Model_PrescribedDofs: acceleration recompute failed: '//TRIM(em))
      RETURN
    END IF
    DO i = 1, SIZE(dofs)
      v_tmp(dofs(i)) = v_vals(i)
      a_tmp(dofs(i)) = a_vals(i)
    END DO
    model%q = q_tmp
    model%v = v_tmp
    model%a = a_tmp
  END SUBROUTINE CD_Set_FiniteEI_Model_PrescribedDofs

  SUBROUTINE CD_Set_FiniteEI_Model_Load(model, f_ext, ErrStat, ErrMsg, recompute_acceleration)
    !! Replace the stored external load vector. By default this also recomputes a
    !! consistent acceleration for the current state, which is the safe contract
    !! before restarting or before the first dynamic step after a load change.
    TYPE(CD_FiniteEIModelType), INTENT(INOUT) :: model
    REAL(wp), INTENT(IN) :: f_ext(:)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    LOGICAL, INTENT(IN), OPTIONAL :: recompute_acceleration
    LOGICAL :: recompute
    INTEGER :: es
    REAL(wp), ALLOCATABLE :: a_tmp(:), a_presc(:)
    CHARACTER(1024) :: em

    ErrStat = CD_DYN_OK
    ErrMsg = ''
    IF (.NOT. model%initialized) THEN
      CALL fail(ErrStat, ErrMsg, 'CD_Set_FiniteEI_Model_Load: model is not initialized')
      RETURN
    END IF
    IF (SIZE(f_ext) /= SIZE(model%q) .OR. .NOT. CD_All_Finite(f_ext)) THEN
      CALL fail(ErrStat, ErrMsg, 'CD_Set_FiniteEI_Model_Load: f_ext must be finite and length 6*n_nodes')
      RETURN
    END IF
    recompute = .TRUE.
    IF (PRESENT(recompute_acceleration)) recompute = recompute_acceleration
    IF (recompute) THEN
      a_tmp = model%a
      ! Preserve any prescribed support acceleration (and its M_fp coupling) across the load
      ! change; for a rest support (model%a(fixed) = 0) this is bit-for-bit the old recompute.
      a_presc = model%a
      CALL CD_Cosserat_Initial_Acceleration(model%nodes_ref, model%elem_conn, model%ea, model%gas, model%ei, &
                                            model%gj, model%rho_a, model%i_rho_t, model%i_rho_n, &
                                            model%reduced_shear, model%q, f_ext, model%fixed_dofs, &
                                            a_tmp, es, em, a_prescribed=a_presc, workspace=model%dynamic_workspace, &
                                            v=model%v, multiplicative=model%cfg%multiplicative_rotation)
      IF (es /= CD_DYN_OK) THEN
        CALL fail(ErrStat, ErrMsg, 'CD_Set_FiniteEI_Model_Load: acceleration recompute failed: '//TRIM(em))
        RETURN
      END IF
      model%a = a_tmp
    END IF
    model%f_ext = f_ext
  END SUBROUTINE CD_Set_FiniteEI_Model_Load

  SUBROUTINE CD_Get_FiniteEI_Model_State(model, q, v, a, ErrStat, ErrMsg)
    !! Copy the current generalized position, velocity, and acceleration.
    TYPE(CD_FiniteEIModelType), INTENT(IN) :: model
    REAL(wp), INTENT(OUT) :: q(:), v(:), a(:)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    INTEGER :: n_dof

    q = CD_ZERO
    v = CD_ZERO
    a = CD_ZERO
    ErrStat = CD_DYN_OK
    ErrMsg = ''
    IF (.NOT. model%initialized) THEN
      CALL fail(ErrStat, ErrMsg, 'CD_Get_FiniteEI_Model_State: model is not initialized')
      RETURN
    END IF
    n_dof = SIZE(model%q)
    IF (SIZE(q) /= n_dof .OR. SIZE(v) /= n_dof .OR. SIZE(a) /= n_dof) THEN
      CALL fail(ErrStat, ErrMsg, 'CD_Get_FiniteEI_Model_State: state outputs must be length 6*n_nodes')
      RETURN
    END IF
    q = model%q
    v = model%v
    a = model%a
  END SUBROUTINE CD_Get_FiniteEI_Model_State

  SUBROUTINE CD_FiniteEI_Model_Energy(model, strain_e, kinetic_e, ErrStat, ErrMsg)
    !! Compute strain and kinetic energy for the current finite-EI model state.
    TYPE(CD_FiniteEIModelType), INTENT(INOUT) :: model
    REAL(wp), INTENT(OUT) :: strain_e, kinetic_e
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    LOGICAL :: workspace_ready

    strain_e = CD_ZERO
    kinetic_e = CD_ZERO
    ErrStat = CD_DYN_OK
    ErrMsg = ''
    IF (.NOT. model%initialized) THEN
      CALL fail(ErrStat, ErrMsg, 'CD_FiniteEI_Model_Energy: model is not initialized')
      RETURN
    END IF
    workspace_ready = ALLOCATED(model%energy_mass_work)
    IF (workspace_ready) workspace_ready = SIZE(model%energy_mass_work) == SIZE(model%q)
    IF (.NOT. workspace_ready) THEN
      CALL fail(ErrStat, ErrMsg, 'CD_FiniteEI_Model_Energy: persistent energy workspace is not initialized')
      RETURN
    END IF
    ! match the energy to the integrator: the multiplicative-SO(3) path uses the
    ! config-dependent spatial rotational inertia, so its kinetic energy must too (else the
    ! query is inconsistent with the integrated equations).
    CALL CD_Cosserat_Mechanical_Energy(model%nodes_ref, model%elem_conn, model%ea, model%gas, model%ei, &
                                       model%gj, model%rho_a, model%i_rho_t, model%i_rho_n, &
                                       model%reduced_shear, model%q, model%v, strain_e, kinetic_e, &
                                       ErrStat, ErrMsg, mass_workspace=model%energy_mass_work, &
                                       multiplicative=model%cfg%multiplicative_rotation)
  END SUBROUTINE CD_FiniteEI_Model_Energy

  LOGICAL FUNCTION CD_FiniteEI_Model_Is_Initialized(model) RESULT(is_initialized)
    !! Return whether the finite-EI model owns a valid initialized state.
    TYPE(CD_FiniteEIModelType), INTENT(IN) :: model
    is_initialized = model%initialized
  END FUNCTION CD_FiniteEI_Model_Is_Initialized

  SUBROUTINE CD_End_FiniteEI_Model(model, ErrStat, ErrMsg)
    !! Release all allocatable storage and reset the model to the uninitialized
    !! state. The routine is idempotent so callers may use it for cleanup paths.
    TYPE(CD_FiniteEIModelType), INTENT(INOUT) :: model
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg

    IF (ALLOCATED(model%nodes_ref)) DEALLOCATE (model%nodes_ref)
    IF (ALLOCATED(model%elem_conn)) DEALLOCATE (model%elem_conn)
    IF (ALLOCATED(model%ea)) DEALLOCATE (model%ea)
    IF (ALLOCATED(model%gas)) DEALLOCATE (model%gas)
    IF (ALLOCATED(model%ei)) DEALLOCATE (model%ei)
    IF (ALLOCATED(model%gj)) DEALLOCATE (model%gj)
    IF (ALLOCATED(model%rho_a)) DEALLOCATE (model%rho_a)
    IF (ALLOCATED(model%i_rho_t)) DEALLOCATE (model%i_rho_t)
    IF (ALLOCATED(model%i_rho_n)) DEALLOCATE (model%i_rho_n)
    IF (ALLOCATED(model%q)) DEALLOCATE (model%q)
    IF (ALLOCATED(model%v)) DEALLOCATE (model%v)
    IF (ALLOCATED(model%a)) DEALLOCATE (model%a)
    IF (ALLOCATED(model%f_ext)) DEALLOCATE (model%f_ext)
    IF (ALLOCATED(model%q_step)) DEALLOCATE (model%q_step)
    IF (ALLOCATED(model%v_step)) DEALLOCATE (model%v_step)
    IF (ALLOCATED(model%a_step)) DEALLOCATE (model%a_step)
    IF (ALLOCATED(model%energy_mass_work)) DEALLOCATE (model%energy_mass_work)
    IF (ALLOCATED(model%fixed_dofs)) DEALLOCATE (model%fixed_dofs)
    CALL CD_Clear_CosseratGenAlpha_Workspace(model%dynamic_workspace)
    model%initialized = .FALSE.
    model%reduced_shear = .TRUE.
    model%cfg = GenAlphaConfig()
    ErrStat = CD_DYN_OK
    ErrMsg = ''
  END SUBROUTINE CD_End_FiniteEI_Model

  SUBROUTINE check_tensile_cable_state(model, q_state, ErrStat, ErrMsg)
    !! Diagnostic check, run only when reject_axial_compression is set: fail closed when
    !! an element is in axial compression, before the shared element/integrators walk
    !! into an ill-conditioned post-buckling state (the two-node linear Cosserat element
    !! can represent rod compression, but no post-buckling cable regularisation is
    !! validated).
    TYPE(CD_FiniteEIModelType), INTENT(IN) :: model
    REAL(wp), INTENT(IN) :: q_state(:)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg

    INTEGER :: e, a, b, i_min
    REAL(wp) :: xa(3), xb(3), ra(3), rb(3), length, ref_length, tension, min_tension, tol

    ErrStat = CD_DYN_OK
    ErrMsg = ''
    IF (.NOT. model%initialized) RETURN
    IF (SIZE(q_state) /= SIZE(model%q)) THEN
      CALL fail(ErrStat, ErrMsg, 'finite-EI cable-domain check: q_state has wrong size')
      RETURN
    END IF
    IF (.NOT. CD_All_Finite(q_state)) THEN
      CALL fail(ErrStat, ErrMsg, 'finite-EI cable-domain check: q_state is non-finite')
      RETURN
    END IF
    min_tension = HUGE(CD_ONE)
    i_min = 0
    tol = 1.0e-10_wp*MAX(CD_ONE, MAXVAL(model%ea))
    DO e = 1, SIZE(model%elem_conn, 2)
      a = model%elem_conn(1, e)
      b = model%elem_conn(2, e)
      xa = q_state(6*a - 5:6*a - 3)
      xb = q_state(6*b - 5:6*b - 3)
      ra = model%nodes_ref(:, a)
      rb = model%nodes_ref(:, b)
      length = SQRT(DOT_PRODUCT(xb - xa, xb - xa))
      ref_length = SQRT(DOT_PRODUCT(rb - ra, rb - ra))
      IF (.NOT. (CD_Is_Finite(length) .AND. CD_Is_Finite(ref_length) .AND. ref_length > CD_ZERO)) THEN
        CALL fail(ErrStat, ErrMsg, 'finite-EI cable-domain check: invalid element length')
        RETURN
      END IF
      tension = model%ea(e)*(length/ref_length - CD_ONE)
      IF (tension < min_tension) THEN
        min_tension = tension
        i_min = e
      END IF
    END DO
    IF (min_tension < -tol) THEN
      ErrStat = CD_DYN_BADINPUT
      BLOCK
        ! Local buffer: a record longer than the caller's ErrMsg truncates
        ! instead of aborting the internal write.
        CHARACTER(1024) :: wmsg
        INTEGER :: wios
        wmsg = ''
        WRITE (wmsg, '(A,I0,A,ES12.4,A)', IOSTAT=wios) 'CD_FiniteEI_Model: axial compression at element ', i_min, &
          ' (T=', min_tension, ' N); post-buckling cable state is unsupported'
        ErrMsg = wmsg
      END BLOCK
    END IF
  END SUBROUTINE check_tensile_cable_state

  SUBROUTINE fail(ErrStat, ErrMsg, msg)
    !! Set the shared invalid-input failure code and message.
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    CHARACTER(*), INTENT(IN) :: msg
    ErrStat = CD_DYN_BADINPUT
    ErrMsg = msg
  END SUBROUTINE fail

END MODULE CableDyn_FiniteEIModel
