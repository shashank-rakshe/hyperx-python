! File: src/CableDyn_CosseratDynamic.f90
! SPDX-License-Identifier: Apache-2.0
! Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
MODULE CableDyn_CosseratDynamic
  !! Finite-EI (geometrically-exact Cosserat) dynamics of the secondary (non-production)
  !! Cosserat path: the consistent mass and the generalised-α time step with SO(3)
  !! rotational state:
  !!   * CD_Cosserat_Element_Mass -- reference-configuration consistent mass;
  !!   * the global mass assembly and the generalised-α step (CD_Cosserat_Gen_Alpha_Step).
  !!
  !! Consistent mass (Simo & Vu-Quoc 1988; the reference-frame linearised form,
  !! exact for the small-amplitude free-vibration regime of L1-6 / L1-8):
  !! linear-Lagrange kinetic energy with constant rho_A and I_rho gives the
  !! per-direction 2x2 nodal block  L0 * [[1/3, 1/6], [1/6, 1/3]]. Translational
  !! inertia is isotropic (rho_A I3, frame-invariant); rotational inertia is
  !! diagonal in the element-local frame and rotated to global via Lam0:
  !!   I_global = Lam0 . diag(I_rho_t, I_rho_t, I_rho_n) . Lam0^T.
  USE CableDyn_Precision, ONLY: wp, CD_ZERO, CD_ONE, CD_All_Finite, CD_Is_Finite
  USE CableDyn_Cosserat, ONLY: CD_Reference_Frame, CD_Cosserat_Element_Energy, &
                               CD_Cosserat_Validate_Rotation_State
  USE CableDyn_CosseratAssemble, ONLY: CD_Assemble_Cosserat_Tangent_Force_Banded_Free, &
                                       CD_Assemble_Cosserat_Tangent_Force_Banded_Free_Workspace, &
                                       CD_Assemble_Cosserat_Internal_Force, &
                                       CD_Assemble_Cosserat_Internal_Force_Workspace, &
                                       CD_Cosserat_Free_Bandwidth, CD_Cosserat_Free_Bandwidth_Workspace, &
                                       CD_CosseratAssemblyWorkspace, CD_Clear_CosseratAssembly_Workspace
  USE CableDyn_Mesh, ONLY: CD_Validate_Connectivity
  USE CableDyn_SO3, ONLY: CD_Compose_Rotvec, CD_Dexp_Inv_SO3, CD_Dexp_SO3, CD_Hat, CD_Exp_SO3, CD_Dexp_Dir_SO3
  USE CableDyn_Dynamic, ONLY: GenAlphaConfig, CD_DYN_OK, CD_DYN_BADINPUT, CD_DYN_SINGULAR
  USE CableDyn_Linalg, ONLY: CD_Factor_Banded, CD_Solve_Banded, CD_Solve_Factored_Banded
  USE, INTRINSIC :: IEEE_ARITHMETIC, ONLY: IEEE_VALUE, IEEE_QUIET_NAN
  IMPLICIT NONE
  PRIVATE
  PUBLIC :: CD_Cosserat_Element_Mass, CD_Assemble_Cosserat_Mass
  PUBLIC :: CD_Assemble_Cosserat_Mass_Banded_Free, CD_Cosserat_Mass_MatVec
  PUBLIC :: CD_CosseratGenAlphaWorkspace, CD_Clear_CosseratGenAlpha_Workspace
  PUBLIC :: CD_Cosserat_Initial_Acceleration, CD_Cosserat_Gen_Alpha_Step
  PUBLIC :: CD_Cosserat_Dynamic_Force_Proc
  PUBLIC :: CD_Cosserat_Dynamic_Load_Banded_Proc
  PUBLIC :: CD_Cosserat_Mechanical_Energy
  PUBLIC :: CD_Spatial_Inertia, CD_Spatial_Inertia_Dir, CD_Gyro_Torque, CD_Gyro_Torque_DOmega
  PUBLIC :: CD_Reset_Cosserat_Dyn_Counts
  PUBLIC :: CD_COSDYN_HIST_MAX

  ! Histogram bins of the modified-Newton diagnostics of CD_CosseratGenAlphaWorkspace: the
  ! Newton iteration of a stale-tangent outcome, the last bin collecting the later ones.
  INTEGER, PARAMETER :: CD_COSDYN_HIST_MAX = 16

  ABSTRACT INTERFACE
    SUBROUTINE CD_Cosserat_Dynamic_Force_Proc(q, v, force, ErrStat, ErrMsg)
      !! Dynamic external force callback for finite-EI Cosserat lines.
      !! q/v are the alpha-blended 6-DOF/node state used in the residual, and
      !! force has the same sign convention as f_ext in R = M a + f_int - f_ext - force.
      IMPORT :: wp
      REAL(wp), INTENT(IN) :: q(:), v(:)
      REAL(wp), INTENT(OUT) :: force(:)
      INTEGER, INTENT(OUT) :: ErrStat
      CHARACTER(*), INTENT(OUT) :: ErrMsg
    END SUBROUTINE CD_Cosserat_Dynamic_Force_Proc

    SUBROUTINE CD_Cosserat_Dynamic_Load_Banded_Proc(q, v, free, kl, ku, force, jac_q_band, jac_v_band, &
                                                    ErrStat, ErrMsg)
      !! Dynamic external load callback with reduced free/free residual-Jacobian
      !! bands. jac_q_band and jac_v_band follow the residual convention
      !! -d(force)/dq and -d(force)/dv in LAPACK general-band storage.
      IMPORT :: wp
      REAL(wp), INTENT(IN) :: q(:), v(:)
      INTEGER, INTENT(IN) :: free(:), kl, ku
      REAL(wp), INTENT(OUT) :: force(:), jac_q_band(:, :), jac_v_band(:, :)
      INTEGER, INTENT(OUT) :: ErrStat
      CHARACTER(*), INTENT(OUT) :: ErrMsg
    END SUBROUTINE CD_Cosserat_Dynamic_Load_Banded_Proc
  END INTERFACE

  TYPE :: CD_CosseratGenAlphaWorkspace
    !! Reusable scratch for one finite-EI generalized-alpha stepper instance.
    !! Persistent model owners pass this into CD_Cosserat_Gen_Alpha_Step to avoid
    !! allocating Newton/Armijo state, band storage, and DOF partitions every step.
    INTEGER :: n_dof_capacity = 0
    INTEGER :: n_fixed_capacity = 0
    INTEGER :: n_free_capacity = 0
    INTEGER :: ldab_capacity = 0
    INTEGER, ALLOCATABLE :: free(:)
    INTEGER, ALLOCATABLE :: fixed(:)
    INTEGER, ALLOCATABLE :: dof_marker(:)
    INTEGER, ALLOCATABLE :: ipiv(:)
    REAL(wp), ALLOCATABLE :: q_n(:)
    REAL(wp), ALLOCATABLE :: v_n(:)
    REAL(wp), ALLOCATABLE :: a_n(:)
    REAL(wp), ALLOCATABLE :: q_pred(:)
    REAL(wp), ALLOCATABLE :: v_pred(:)
    REAL(wp), ALLOCATABLE :: qk(:)
    REAL(wp), ALLOCATABLE :: R(:)
    REAL(wp), ALLOCATABLE :: corr(:)
    REAL(wp), ALLOCATABLE :: q_trial(:)
    REAL(wp), ALLOCATABLE :: R_trial(:)
    REAL(wp), ALLOCATABLE :: a_eval(:)
    REAL(wp), ALLOCATABLE :: a_alpha(:)
    REAL(wp), ALLOCATABLE :: q_alpha(:)
    REAL(wp), ALLOCATABLE :: v_eval(:)
    REAL(wp), ALLOCATABLE :: v_alpha(:)
    REAL(wp), ALLOCATABLE :: fint_eval(:)
    REAL(wp), ALLOCATABLE :: ma_alpha(:)
    REAL(wp), ALLOCATABLE :: load_eval(:)
    REAL(wp), ALLOCATABLE :: R_free(:)
    REAL(wp), ALLOCATABLE :: dq(:)
    REAL(wp), ALLOCATABLE :: Mb(:, :)
    REAL(wp), ALLOCATABLE :: Kb(:, :)
    REAL(wp), ALLOCATABLE :: load_jq_band(:, :)
    REAL(wp), ALLOCATABLE :: load_jv_band(:, :)
    REAL(wp), ALLOCATABLE :: eff_band(:, :)
    TYPE(CD_CosseratAssemblyWorkspace) :: assembly
    ! Modified-Newton stale-tangent diagnostics of the steps run on this workspace (one per
    ! model, so concurrent models never mix their counts) since CD_Reset_Cosserat_Dyn_Counts:
    ! stale-tangent steps accepted and rejected, refreshes before the first solve (no path
    ! takes one), and histograms over the Newton iteration of each outcome. No result
    ! depends on them.
    INTEGER :: n_stale_accept = 0, n_stale_reject = 0, n_deferred_refresh = 0
    INTEGER :: stale_accept_hist(0:CD_COSDYN_HIST_MAX) = 0
    INTEGER :: stale_reject_hist(0:CD_COSDYN_HIST_MAX) = 0
    INTEGER :: deferred_refresh_hist(0:CD_COSDYN_HIST_MAX) = 0
  END TYPE CD_CosseratGenAlphaWorkspace

CONTAINS

  SUBROUTINE CD_Clear_CosseratGenAlpha_Workspace(work)
    !! Release all allocatable scratch owned by a reusable finite-EI dynamic workspace.
    TYPE(CD_CosseratGenAlphaWorkspace), INTENT(INOUT) :: work

    IF (ALLOCATED(work%free)) DEALLOCATE (work%free)
    IF (ALLOCATED(work%fixed)) DEALLOCATE (work%fixed)
    IF (ALLOCATED(work%dof_marker)) DEALLOCATE (work%dof_marker)
    IF (ALLOCATED(work%ipiv)) DEALLOCATE (work%ipiv)
    IF (ALLOCATED(work%q_n)) DEALLOCATE (work%q_n)
    IF (ALLOCATED(work%v_n)) DEALLOCATE (work%v_n)
    IF (ALLOCATED(work%a_n)) DEALLOCATE (work%a_n)
    IF (ALLOCATED(work%q_pred)) DEALLOCATE (work%q_pred)
    IF (ALLOCATED(work%v_pred)) DEALLOCATE (work%v_pred)
    IF (ALLOCATED(work%qk)) DEALLOCATE (work%qk)
    IF (ALLOCATED(work%R)) DEALLOCATE (work%R)
    IF (ALLOCATED(work%corr)) DEALLOCATE (work%corr)
    IF (ALLOCATED(work%q_trial)) DEALLOCATE (work%q_trial)
    IF (ALLOCATED(work%R_trial)) DEALLOCATE (work%R_trial)
    IF (ALLOCATED(work%a_eval)) DEALLOCATE (work%a_eval)
    IF (ALLOCATED(work%a_alpha)) DEALLOCATE (work%a_alpha)
    IF (ALLOCATED(work%q_alpha)) DEALLOCATE (work%q_alpha)
    IF (ALLOCATED(work%v_eval)) DEALLOCATE (work%v_eval)
    IF (ALLOCATED(work%v_alpha)) DEALLOCATE (work%v_alpha)
    IF (ALLOCATED(work%fint_eval)) DEALLOCATE (work%fint_eval)
    IF (ALLOCATED(work%ma_alpha)) DEALLOCATE (work%ma_alpha)
    IF (ALLOCATED(work%load_eval)) DEALLOCATE (work%load_eval)
    IF (ALLOCATED(work%R_free)) DEALLOCATE (work%R_free)
    IF (ALLOCATED(work%dq)) DEALLOCATE (work%dq)
    IF (ALLOCATED(work%Mb)) DEALLOCATE (work%Mb)
    IF (ALLOCATED(work%Kb)) DEALLOCATE (work%Kb)
    IF (ALLOCATED(work%load_jq_band)) DEALLOCATE (work%load_jq_band)
    IF (ALLOCATED(work%load_jv_band)) DEALLOCATE (work%load_jv_band)
    IF (ALLOCATED(work%eff_band)) DEALLOCATE (work%eff_band)
    CALL CD_Clear_CosseratAssembly_Workspace(work%assembly)
    work%n_dof_capacity = 0
    work%n_fixed_capacity = 0
    work%n_free_capacity = 0
    work%ldab_capacity = 0
  END SUBROUTINE CD_Clear_CosseratGenAlpha_Workspace

  SUBROUTINE CD_Reset_Cosserat_Dyn_Counts(work)
    !! Zero the modified-Newton diagnostic counters of a workspace. These are benchmark-only
    !! diagnostics and do not affect the numerical path.
    TYPE(CD_CosseratGenAlphaWorkspace), INTENT(INOUT) :: work
    work%n_stale_accept = 0
    work%n_stale_reject = 0
    work%n_deferred_refresh = 0
    work%stale_accept_hist = 0
    work%stale_reject_hist = 0
    work%deferred_refresh_hist = 0
  END SUBROUTINE CD_Reset_Cosserat_Dyn_Counts

  SUBROUTINE CD_Cosserat_Mechanical_Energy(nodes_ref, elem_conn, ea, gas, ei, gj, rho_a, &
                                           i_rho_t, i_rho_n, reduced_shear, q, v, &
                                           strain_e, kinetic_e, ErrStat, ErrMsg, mass_workspace, &
                                           multiplicative)
    !! Total mechanical energy of the finite-EI line: strain energy
    !! sum_e U_e(q) (CD_Cosserat_Element_Energy) and kinetic energy 1/2 v^T M v
    !! (the assembled consistent mass). The L1-8 energy-stability diagnostic.
    !!
    !! multiplicative (optional, default .FALSE.): match the energy to the multiplicative-SO(3)
    !! dynamics -- the rotational kinetic energy uses the lumped CONFIG-DEPENDENT spatial inertia
    !!   KE_rot = sum_a (1/2) w_a omega_a . I_s(theta_a) omega_a,   I_s = Lambda J Lambda^T,
    !! the same inertia the multiplicative residual integrates, instead of the frozen reference rotational
    !! mass (1/2 omega^T M_ref omega). Translational KE (consistent mass) is unchanged. Absent ->
    !! the reference-mass form, bit-for-bit (the additive path / L1-8).
    REAL(wp), INTENT(IN) :: nodes_ref(:, :), ea(:), gas(:), ei(:), gj(:)
    REAL(wp), INTENT(IN) :: rho_a(:), i_rho_t(:), i_rho_n(:), q(:), v(:)
    INTEGER, INTENT(IN) :: elem_conn(:, :)
    LOGICAL, INTENT(IN) :: reduced_shear
    REAL(wp), INTENT(OUT) :: strain_e, kinetic_e
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    REAL(wp), INTENT(INOUT), OPTIONAL :: mass_workspace(:)
    LOGICAL, INTENT(IN), OPTIONAL :: multiplicative
    INTEGER :: n_nodes, n_elem, e, a, b, ndof, es, k, nd
    REAL(wp) :: Lam0(3, 3), L0, qe(12), Is(3, 3), om(3), w
    REAL(wp), ALLOCATABLE :: mv(:), v_trans(:)
    LOGICAL :: mult_e
    CHARACTER(120) :: em
    strain_e = CD_ZERO; kinetic_e = CD_ZERO; ErrStat = CD_DYN_OK; ErrMsg = ''
    IF (SIZE(nodes_ref, 1) /= 3 .OR. SIZE(elem_conn, 1) /= 2) THEN
      ErrStat = CD_DYN_BADINPUT; ErrMsg = 'CD_Cosserat_Mechanical_Energy: nodes_ref (3,*) / elem_conn (2,*)'
      RETURN
    END IF
    n_nodes = SIZE(nodes_ref, 2); n_elem = SIZE(elem_conn, 2); ndof = 6*n_nodes
    IF (SIZE(q) /= ndof .OR. SIZE(v) /= ndof) THEN
      ErrStat = CD_DYN_BADINPUT; ErrMsg = 'CD_Cosserat_Mechanical_Energy: q / v must be (6 n_nodes)'
      RETURN
    END IF
    ! The mass assembly validates connectivity / spans / inertia, but the strain
    ! sum indexes ea/gas/ei/gj directly (not via the assembler), so validate the
    ! stiffness arrays here too: length n_elem (else an out-of-bounds read with
    ! bounds checks off) and finite-positive per element (else a corrupted strain
    ! energy returned with ErrStat = CD_DYN_OK).
    IF (SIZE(ea) /= n_elem .OR. SIZE(gas) /= n_elem .OR. SIZE(ei) /= n_elem .OR. SIZE(gj) /= n_elem) THEN
      ErrStat = CD_DYN_BADINPUT; ErrMsg = 'CD_Cosserat_Mechanical_Energy: stiffness arrays must have length n_elem'
      RETURN
    END IF
    IF (.NOT. CD_All_Finite(q) .OR. .NOT. CD_All_Finite(v)) THEN
      ErrStat = CD_DYN_BADINPUT; ErrMsg = 'CD_Cosserat_Mechanical_Energy: q / v non-finite'
      RETURN
    END IF
    ! The strain sum calls CD_Cosserat_Element_Energy directly, which does NOT
    ! enforce the element-domain rotation contract the force/tangent path checks
    ! (the |theta| < pi nodal chart AND a non-log-singular relative rotation). An
    ! out-of-chart or near-pi-relative state would otherwise return a finite strain
    ! energy with ErrStat = CD_DYN_OK for a state the rest of the finite-EI API
    ! rejects, corrupting energy / restart diagnostics. Each element's state is
    ! validated per element below via the SHARED CD_Cosserat_Validate_Rotation_State
    ! (one contract for force, tangent, and energy), so no separate global chart
    ! check is needed here.
    mult_e = .FALSE.
    IF (PRESENT(multiplicative)) mult_e = multiplicative
    ! kinetic 1/2 v^T M v (the element-wise product validates connectivity/spans/inertia)
    IF (mult_e) THEN
      ! Multiplicative-SO(3) kinetic energy, consistent with the gyroscopic dynamics: translational
      ! KE from the consistent mass (block-diagonal -> zero the rotation velocities, then
      ! matvec), plus the lumped CONFIG-DEPENDENT rotational KE sum_a 1/2 w_a omega_a . I_s omega_a.
      ALLOCATE (v_trans(ndof), mv(ndof))
      v_trans = v
      DO nd = 1, n_nodes
        v_trans(6*nd - 2:6*nd) = CD_ZERO
      END DO
      CALL CD_Cosserat_Mass_MatVec(nodes_ref, elem_conn, rho_a, i_rho_t, i_rho_n, v_trans, mv, es, em)
      IF (es /= 0) THEN
        ErrStat = CD_DYN_BADINPUT; ErrMsg = 'mass product failed: '//TRIM(em); DEALLOCATE (v_trans, mv); RETURN
      END IF
      kinetic_e = 0.5_wp*DOT_PRODUCT(v_trans, mv)
      DEALLOCATE (v_trans, mv)
      DO e = 1, n_elem
        a = elem_conn(1, e); b = elem_conn(2, e)
        CALL CD_Reference_Frame(nodes_ref(:, a), nodes_ref(:, b), Lam0, L0)
        w = 0.5_wp*L0
        DO k = 1, 2
          nd = elem_conn(k, e)
          om = v(6*nd - 2:6*nd)
          Is = CD_Spatial_Inertia(q(6*nd - 2:6*nd), Lam0, i_rho_t(e), i_rho_n(e))
          kinetic_e = kinetic_e + 0.5_wp*w*DOT_PRODUCT(om, MATMUL(Is, om))
        END DO
      END DO
    ELSE IF (PRESENT(mass_workspace)) THEN
      IF (SIZE(mass_workspace) /= ndof) THEN
        ErrStat = CD_DYN_BADINPUT
        ErrMsg = 'CD_Cosserat_Mechanical_Energy: mass_workspace must be length 6*n_nodes'
        RETURN
      END IF
      CALL CD_Cosserat_Mass_MatVec(nodes_ref, elem_conn, rho_a, i_rho_t, i_rho_n, v, mass_workspace, es, em)
      IF (es /= 0) THEN
        ErrStat = CD_DYN_BADINPUT; ErrMsg = 'mass product failed: '//TRIM(em); RETURN
      END IF
      kinetic_e = 0.5_wp*DOT_PRODUCT(v, mass_workspace)
    ELSE
      ALLOCATE (mv(ndof))
      CALL CD_Cosserat_Mass_MatVec(nodes_ref, elem_conn, rho_a, i_rho_t, i_rho_n, v, mv, es, em)
      IF (es /= 0) THEN
        ErrStat = CD_DYN_BADINPUT; ErrMsg = 'mass product failed: '//TRIM(em); RETURN
      END IF
      kinetic_e = 0.5_wp*DOT_PRODUCT(v, mv)
    END IF
    ! strain sum_e U_e(q) (spans already validated > 0 by the mass product above)
    DO e = 1, n_elem
      IF (.NOT. (ea(e) > CD_ZERO .AND. gas(e) > CD_ZERO .AND. ei(e) > CD_ZERO .AND. gj(e) > CD_ZERO) .OR. &
          .NOT. (CD_Is_Finite(ea(e)) .AND. CD_Is_Finite(gas(e)) .AND. &
                 CD_Is_Finite(ei(e)) .AND. CD_Is_Finite(gj(e)))) THEN
        ErrStat = CD_DYN_BADINPUT
        ErrMsg = 'CD_Cosserat_Mechanical_Energy: stiffness must be finite and positive'
        strain_e = CD_ZERO; RETURN
      END IF
      a = elem_conn(1, e); b = elem_conn(2, e)
      CALL CD_Reference_Frame(nodes_ref(:, a), nodes_ref(:, b), Lam0, L0)
      qe(1:6) = q(6*a - 5:6*a)
      qe(7:12) = q(6*b - 5:6*b)
      ! shared element-domain rotation contract (chart + singular relative
      ! rotation) -- the same gate the force/tangent path enforces
      CALL CD_Cosserat_Validate_Rotation_State(qe, es, em)
      IF (es /= 0) THEN
        ErrStat = CD_DYN_BADINPUT
        ErrMsg = 'CD_Cosserat_Mechanical_Energy: '//TRIM(em)
        strain_e = CD_ZERO; kinetic_e = CD_ZERO; RETURN
      END IF
      strain_e = strain_e + CD_Cosserat_Element_Energy(qe, ea(e), gas(e), ei(e), gj(e), &
                                                       Lam0, L0, reduced_shear)
    END DO
  END SUBROUTINE CD_Cosserat_Mechanical_Energy

  SUBROUTINE CD_Assemble_Cosserat_Mass(nodes_ref, elem_conn, rho_a, i_rho_t, i_rho_n, M, ErrStat, ErrMsg)
    !! Dense global consistent mass (6 n_nodes square) for the finite-EI mesh:
    !! scatter-add each element's CD_Cosserat_Element_Mass (per-element reference
    !! frame Lam0, L0). Per-element inertia arrays rho_a / i_rho_t / i_rho_n.
    !! Fails closed on the shared connectivity contract, zero-length spans, and
    !! non-positive / non-finite inertia.
    REAL(wp), INTENT(IN) :: nodes_ref(:, :), rho_a(:), i_rho_t(:), i_rho_n(:)
    INTEGER, INTENT(IN) :: elem_conn(:, :)
    REAL(wp), INTENT(OUT) :: M(:, :)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    INTEGER :: n_nodes, n_elem, e, a, b, ndof, gmap(12), i, j
    REAL(wp) :: Lam0(3, 3), L0, Me(12, 12), span(3), l0sq
    ErrStat = 0; ErrMsg = ''
    M = 0.0_wp
    IF (SIZE(nodes_ref, 1) /= 3 .OR. SIZE(elem_conn, 1) /= 2) THEN
      ErrStat = 1; ErrMsg = 'CD_Assemble_Cosserat_Mass: nodes_ref (3,*) / elem_conn (2,*)'; RETURN
    END IF
    n_nodes = SIZE(nodes_ref, 2); n_elem = SIZE(elem_conn, 2); ndof = 6*n_nodes
    CALL CD_Validate_Connectivity(elem_conn, n_nodes, n_elem, ErrStat, ErrMsg)
    IF (ErrStat /= 0) RETURN
    IF (SIZE(rho_a) /= n_elem .OR. SIZE(i_rho_t) /= n_elem .OR. SIZE(i_rho_n) /= n_elem) THEN
      ErrStat = 1; ErrMsg = 'CD_Assemble_Cosserat_Mass: inertia arrays must have length n_elem'; RETURN
    END IF
    IF (SIZE(M, 1) /= ndof .OR. SIZE(M, 2) /= ndof) THEN
      ErrStat = 1; ErrMsg = 'CD_Assemble_Cosserat_Mass: M must be (6 n_nodes, 6 n_nodes)'; RETURN
    END IF
    IF (.NOT. CD_All_Finite(nodes_ref)) THEN
      ErrStat = 1; ErrMsg = 'CD_Assemble_Cosserat_Mass: nodes_ref non-finite'; RETURN
    END IF
    DO e = 1, n_elem
      IF (.NOT. (rho_a(e) > 0.0_wp .AND. i_rho_t(e) > 0.0_wp .AND. i_rho_n(e) > 0.0_wp) .OR. &
          .NOT. (CD_Is_Finite(rho_a(e)) .AND. CD_Is_Finite(i_rho_t(e)) .AND. CD_Is_Finite(i_rho_n(e)))) THEN
        ErrStat = 1; ErrMsg = 'CD_Assemble_Cosserat_Mass: inertia must be finite and positive'; RETURN
      END IF
      a = elem_conn(1, e); b = elem_conn(2, e)
      span = nodes_ref(:, b) - nodes_ref(:, a)
      l0sq = DOT_PRODUCT(span, span)
      IF (.NOT. (l0sq > 0.0_wp) .OR. .NOT. CD_Is_Finite(l0sq)) THEN
        ErrStat = 1; ErrMsg = 'CD_Assemble_Cosserat_Mass: zero-length reference span (L0 = 0)'; RETURN
      END IF
      CALL CD_Reference_Frame(nodes_ref(:, a), nodes_ref(:, b), Lam0, L0)
      Me = CD_Cosserat_Element_Mass(L0, Lam0, rho_a(e), i_rho_t(e), i_rho_n(e))
      DO i = 1, 6
        gmap(i) = 6*a - 6 + i
        gmap(6 + i) = 6*b - 6 + i
      END DO
      DO j = 1, 12
        DO i = 1, 12
          M(gmap(i), gmap(j)) = M(gmap(i), gmap(j)) + Me(i, j)
        END DO
      END DO
    END DO
  END SUBROUTINE CD_Assemble_Cosserat_Mass

  SUBROUTINE CD_Assemble_Cosserat_Mass_Banded_Free(nodes_ref, elem_conn, rho_a, i_rho_t, i_rho_n, free, kl, ku, &
                                                   Mb, ErrStat, ErrMsg)
    !! Assemble the reduced free-DOF consistent mass directly into LAPACK general-band
    !! storage. This is the mass analogue of the free-band tangent assembler:
    !! Mb(kl+ku+1+i-j, j) = M_free(i,j). It avoids forming/packing a dense M_ff
    !! block in the finite-EI dynamic effective tangent.
    REAL(wp), INTENT(IN) :: nodes_ref(:, :), rho_a(:), i_rho_t(:), i_rho_n(:)
    INTEGER, INTENT(IN) :: elem_conn(:, :), free(:), kl, ku
    REAL(wp), INTENT(OUT) :: Mb(:, :)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    INTEGER :: n_nodes, n_elem, ndof
    INTEGER, ALLOCATABLE :: global_to_free(:)

    CALL check_mass_inputs(nodes_ref, elem_conn, rho_a, i_rho_t, i_rho_n, n_nodes, n_elem, ndof, ErrStat, ErrMsg)
    IF (ErrStat /= 0) RETURN
    ALLOCATE (global_to_free(ndof))
    CALL assemble_cosserat_mass_banded_free_workspace(nodes_ref, elem_conn, rho_a, i_rho_t, i_rho_n, &
                                                      free, kl, ku, global_to_free, Mb, ErrStat, ErrMsg)
  END SUBROUTINE CD_Assemble_Cosserat_Mass_Banded_Free

  SUBROUTINE assemble_cosserat_mass_banded_free_workspace(nodes_ref, elem_conn, rho_a, i_rho_t, i_rho_n, &
                                                          free, kl, ku, global_to_free, Mb, ErrStat, ErrMsg, &
                                                          translational_only)
    !! Workspace-backed version of CD_Assemble_Cosserat_Mass_Banded_Free. Callers
    !! on the finite-EI hot path provide a persistent global-to-free map to avoid
    !! heap allocation while preserving the same validation and band assembly.
    !!
    !! translational_only (optional, default .FALSE.): zero the element rotational mass
    !! block before scatter -> Mb carries only the (consistent) translational mass. The
    !! multiplicative-SO(3) path uses this because its rotational inertia tangent is the
    !! config-dependent + gyroscopic per-node block (cosserat_mult_rot_tangent), NOT the
    !! frozen consistent rotational mass; keeping both would double-count it.
    REAL(wp), INTENT(IN) :: nodes_ref(:, :), rho_a(:), i_rho_t(:), i_rho_n(:)
    INTEGER, INTENT(IN) :: elem_conn(:, :), free(:), kl, ku
    INTEGER, INTENT(INOUT) :: global_to_free(:)
    REAL(wp), INTENT(OUT) :: Mb(:, :)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    LOGICAL, INTENT(IN), OPTIONAL :: translational_only
    INTEGER :: n_nodes, n_elem, ndof, e, a, b, gmap(12), i, j, fi, fj, row, ldab
    REAL(wp) :: Lam0(3, 3), L0, Me(12, 12)
    LOGICAL :: trans_only
    trans_only = .FALSE.
    IF (PRESENT(translational_only)) trans_only = translational_only

    Mb = 0.0_wp
    CALL check_mass_inputs(nodes_ref, elem_conn, rho_a, i_rho_t, i_rho_n, n_nodes, n_elem, ndof, ErrStat, ErrMsg)
    IF (ErrStat /= 0) RETURN
    ldab = 2*kl + ku + 1
    IF (kl < 0 .OR. ku < 0 .OR. SIZE(Mb, 1) < ldab .OR. SIZE(Mb, 2) /= SIZE(free)) THEN
      ErrStat = 1; ErrMsg = 'CD_Assemble_Cosserat_Mass_Banded_Free: invalid band storage shape'
      RETURN
    END IF
    IF (SIZE(global_to_free) < ndof) THEN
      ErrStat = 1; ErrMsg = 'CD_Assemble_Cosserat_Mass_Banded_Free: map workspace is undersized'
      RETURN
    END IF
    IF (ANY(free < 1) .OR. ANY(free > ndof)) THEN
      ErrStat = 1; ErrMsg = 'CD_Assemble_Cosserat_Mass_Banded_Free: free DOF index out of range'
      RETURN
    END IF

    global_to_free(1:ndof) = 0
    DO i = 1, SIZE(free)
      IF (global_to_free(free(i)) /= 0) THEN
        ErrStat = 1; ErrMsg = 'CD_Assemble_Cosserat_Mass_Banded_Free: duplicate free DOF'
        RETURN
      END IF
      global_to_free(free(i)) = i
    END DO

    DO e = 1, n_elem
      a = elem_conn(1, e)
      b = elem_conn(2, e)
      CALL CD_Reference_Frame(nodes_ref(:, a), nodes_ref(:, b), Lam0, L0)
      Me = CD_Cosserat_Element_Mass(L0, Lam0, rho_a(e), i_rho_t(e), i_rho_n(e))
      IF (trans_only) THEN
        ! drop the rotational mass block (element DOFs 4:6, 10:12) -> translational mass only
        Me(4:6, :) = CD_ZERO; Me(10:12, :) = CD_ZERO
        Me(:, 4:6) = CD_ZERO; Me(:, 10:12) = CD_ZERO
      END IF
      DO i = 1, 6
        gmap(i) = 6*a - 6 + i
        gmap(6 + i) = 6*b - 6 + i
      END DO
      DO j = 1, 12
        fj = global_to_free(gmap(j))
        IF (fj == 0) CYCLE
        DO i = 1, 12
          fi = global_to_free(gmap(i))
          IF (fi == 0) CYCLE
          row = kl + ku + 1 + fi - fj
          IF (row < 1 .OR. row > SIZE(Mb, 1)) THEN
            Mb = 0.0_wp
            ErrStat = 1; ErrMsg = 'CD_Assemble_Cosserat_Mass_Banded_Free: bandwidth too small'
            RETURN
          END IF
          Mb(row, fj) = Mb(row, fj) + Me(i, j)
        END DO
      END DO
    END DO
  END SUBROUTINE assemble_cosserat_mass_banded_free_workspace

  SUBROUTINE CD_Cosserat_Mass_MatVec(nodes_ref, elem_conn, rho_a, i_rho_t, i_rho_n, x, y, ErrStat, ErrMsg)
    !! Element-wise consistent-mass product y = M x without forming dense M. The
    !! finite-EI dynamic residual uses this in Newton and Armijo evaluations.
    REAL(wp), INTENT(IN) :: nodes_ref(:, :), rho_a(:), i_rho_t(:), i_rho_n(:), x(:)
    INTEGER, INTENT(IN) :: elem_conn(:, :)
    REAL(wp), INTENT(OUT) :: y(:)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    INTEGER :: n_nodes, n_elem, ndof

    y = 0.0_wp
    CALL check_mass_inputs(nodes_ref, elem_conn, rho_a, i_rho_t, i_rho_n, n_nodes, n_elem, ndof, ErrStat, ErrMsg)
    IF (ErrStat /= 0) RETURN
    IF (SIZE(x) /= ndof .OR. SIZE(y) /= ndof) THEN
      ErrStat = 1; ErrMsg = 'CD_Cosserat_Mass_MatVec: x/y must have length 6*n_nodes'
      RETURN
    END IF
    IF (.NOT. CD_All_Finite(x)) THEN
      ErrStat = 1; ErrMsg = 'CD_Cosserat_Mass_MatVec: x contains non-finite values'
      RETURN
    END IF

    CALL cosserat_mass_matvec_unchecked(nodes_ref, elem_conn, rho_a, i_rho_t, i_rho_n, x, y)
  END SUBROUTINE CD_Cosserat_Mass_MatVec

  SUBROUTINE cosserat_mass_matvec_unchecked(nodes_ref, elem_conn, rho_a, i_rho_t, i_rho_n, x, y)
    !! Hot-path mass product after the caller has already validated mesh, inertia,
    !! shape, and finiteness. Kept private so public callers use the guarded wrapper.
    REAL(wp), INTENT(IN) :: nodes_ref(:, :), rho_a(:), i_rho_t(:), i_rho_n(:), x(:)
    INTEGER, INTENT(IN) :: elem_conn(:, :)
    REAL(wp), INTENT(OUT) :: y(:)
    INTEGER :: e, a, b, gmap(12), i
    REAL(wp) :: Lam0(3, 3), L0, Me(12, 12), xe(12)

    y = 0.0_wp
    DO e = 1, SIZE(elem_conn, 2)
      a = elem_conn(1, e)
      b = elem_conn(2, e)
      CALL CD_Reference_Frame(nodes_ref(:, a), nodes_ref(:, b), Lam0, L0)
      Me = CD_Cosserat_Element_Mass(L0, Lam0, rho_a(e), i_rho_t(e), i_rho_n(e))
      DO i = 1, 6
        gmap(i) = 6*a - 6 + i
        gmap(6 + i) = 6*b - 6 + i
      END DO
      xe = x(gmap)
      DO i = 1, 12
        y(gmap(i)) = y(gmap(i)) + DOT_PRODUCT(Me(i, :), xe)
      END DO
    END DO
  END SUBROUTINE cosserat_mass_matvec_unchecked

  SUBROUTINE check_mass_inputs(nodes_ref, elem_conn, rho_a, i_rho_t, i_rho_n, n_nodes, n_elem, ndof, ErrStat, ErrMsg)
    !! Shared finite-EI consistent-mass input contract for dense, banded, and
    !! matvec paths.
    REAL(wp), INTENT(IN) :: nodes_ref(:, :), rho_a(:), i_rho_t(:), i_rho_n(:)
    INTEGER, INTENT(IN) :: elem_conn(:, :)
    INTEGER, INTENT(OUT) :: n_nodes, n_elem, ndof, ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    INTEGER :: e
    REAL(wp) :: span(3), l0sq

    ErrStat = 0
    ErrMsg = ''
    n_nodes = 0
    n_elem = 0
    ndof = 0
    IF (SIZE(nodes_ref, 1) /= 3 .OR. SIZE(elem_conn, 1) /= 2) THEN
      ErrStat = 1; ErrMsg = 'check_mass_inputs: nodes_ref (3,*) / elem_conn (2,*)'
      RETURN
    END IF
    n_nodes = SIZE(nodes_ref, 2)
    n_elem = SIZE(elem_conn, 2)
    ndof = 6*n_nodes
    CALL CD_Validate_Connectivity(elem_conn, n_nodes, n_elem, ErrStat, ErrMsg)
    IF (ErrStat /= 0) RETURN
    IF (SIZE(rho_a) /= n_elem .OR. SIZE(i_rho_t) /= n_elem .OR. SIZE(i_rho_n) /= n_elem) THEN
      ErrStat = 1; ErrMsg = 'check_mass_inputs: inertia arrays must have length n_elem'
      RETURN
    END IF
    IF (.NOT. CD_All_Finite(nodes_ref)) THEN
      ErrStat = 1; ErrMsg = 'check_mass_inputs: nodes_ref non-finite'
      RETURN
    END IF
    DO e = 1, n_elem
      IF (.NOT. (rho_a(e) > 0.0_wp .AND. i_rho_t(e) > 0.0_wp .AND. i_rho_n(e) > 0.0_wp) .OR. &
          .NOT. (CD_Is_Finite(rho_a(e)) .AND. CD_Is_Finite(i_rho_t(e)) .AND. CD_Is_Finite(i_rho_n(e)))) THEN
        ErrStat = 1; ErrMsg = 'check_mass_inputs: inertia must be finite and positive'
        RETURN
      END IF
      span = nodes_ref(:, elem_conn(2, e)) - nodes_ref(:, elem_conn(1, e))
      l0sq = DOT_PRODUCT(span, span)
      IF (.NOT. (l0sq > 0.0_wp) .OR. .NOT. CD_Is_Finite(l0sq)) THEN
        ErrStat = 1; ErrMsg = 'check_mass_inputs: zero-length reference span (L0 = 0)'
        RETURN
      END IF
    END DO
  END SUBROUTINE check_mass_inputs

  PURE FUNCTION CD_Cosserat_Element_Mass(L0, Lam0, rho_A, I_rho_t, I_rho_n) RESULT(M)
    !! PRECONDITION: L0 > 0 and rho_A, I_rho_t, I_rho_n finite and positive. This
    !! low-level PURE primitive carries no ErrStat; the fail-closed public entry
    !! point is CD_Assemble_Cosserat_Mass, which validates these before calling.
    !! 12x12 reference-configuration consistent mass for the 2-node, 6-DOF/node
    !! Cosserat element. DOF ordering [r1(3), theta1(3), r2(3), theta2(3)].
    REAL(wp), INTENT(IN) :: L0, Lam0(3, 3), rho_A, I_rho_t, I_rho_n
    REAL(wp) :: M(12, 12)
    REAL(wp) :: block(2, 2), I_local(3, 3), I_global(3, 3)
    INTEGER :: i, j, a, b
    block(1, 1) = L0/3.0_wp; block(1, 2) = L0/6.0_wp
    block(2, 1) = L0/6.0_wp; block(2, 2) = L0/3.0_wp
    M = 0.0_wp
    ! translational block: isotropic rho_A on the 3 translation DOFs of each node pair
    DO b = 1, 2
      DO a = 1, 2
        DO i = 1, 3
          M((a - 1)*6 + i, (b - 1)*6 + i) = rho_A*block(a, b)
        END DO
      END DO
    END DO
    ! rotational block: I_global = Lam0 . diag(I_rho_t, I_rho_t, I_rho_n) . Lam0^T
    I_local = 0.0_wp
    I_local(1, 1) = I_rho_t; I_local(2, 2) = I_rho_t; I_local(3, 3) = I_rho_n
    I_global = MATMUL(Lam0, MATMUL(I_local, TRANSPOSE(Lam0)))
    DO b = 1, 2
      DO a = 1, 2
        DO j = 1, 3
          DO i = 1, 3
            M((a - 1)*6 + 3 + i, (b - 1)*6 + 3 + j) = I_global(i, j)*block(a, b)
          END DO
        END DO
      END DO
    END DO
  END FUNCTION CD_Cosserat_Element_Mass

  ! --- Spatial rotational-inertia + gyroscopic primitives (multiplicative-SO(3) dynamics) ---
  ! Verified building blocks for the large-rotation rotational dynamics. The cross-section
  ! inertia is J = diag(I_rho_t, I_rho_t, I_rho_n) in the MATERIAL frame; the spatial inertia
  ! co-rotates with the director frame Lambda = exp(theta). These carry no virtual-work
  ! conjugacy choice (the assembly makes it); each is checked against finite differences in
  ! tests/test_finite_ei_gyro_primitives.f90.

  PURE FUNCTION CD_Spatial_Inertia(theta, Lam0, i_rho_t, i_rho_n) RESULT(Is)
    !! Spatial rotational inertia I_s(theta) = Lambda J_ref Lambda^T, Lambda = exp(theta) the
    !! incremental rotation FROM the element reference frame Lam0, and
    !!   J_ref = Lam0 diag(I_rho_t, I_rho_t, I_rho_n) Lam0^T
    !! the section inertia oriented in that reference frame (material axis 3 = the reference
    !! TANGENT, not global z). At theta = 0 this reduces to Lam0 J Lam0^T, matching
    !! CD_Cosserat_Element_Mass; for a non-z reference (horizontal/inclined cable) Lam0 /= I.
    REAL(wp), INTENT(IN) :: theta(3), Lam0(3, 3), i_rho_t, i_rho_n
    REAL(wp) :: Is(3, 3), Lam(3, 3), Jm(3, 3), Jref(3, 3), JL0t(3, 3), JLt(3, 3)
    ! explicit MATMUL temporaries (avoids a gfortran -Wuninitialized false positive on
    ! nested MATMUL under the project warning flags).
    Jm = CD_ZERO
    Jm(1, 1) = i_rho_t; Jm(2, 2) = i_rho_t; Jm(3, 3) = i_rho_n
    JL0t = MATMUL(Jm, TRANSPOSE(Lam0))
    Jref = MATMUL(Lam0, JL0t)
    Lam = CD_Exp_SO3(theta)
    JLt = MATMUL(Jref, TRANSPOSE(Lam))
    Is = MATMUL(Lam, JLt)
  END FUNCTION CD_Spatial_Inertia

  PURE FUNCTION CD_Spatial_Inertia_Dir(theta, Lam0, i_rho_t, i_rho_n, d) RESULT(dIs)
    !! Directional derivative d/dtheta[I_s(theta)] . d (additive theta perturbation d).
    !! D exp(theta)[d] = hat(T d) Lambda with T = dexp (CD_Dexp_SO3), and J_ref is constant, so
    !!   dI_s = [hat(T d), I_s]   (commutator) -- unchanged by the reference-frame fix.
    REAL(wp), INTENT(IN) :: theta(3), Lam0(3, 3), i_rho_t, i_rho_n, d(3)
    REAL(wp) :: dIs(3, 3), Is(3, 3), H(3, 3), Tmat(3, 3), Td(3), HIs(3, 3), IsH(3, 3)
    Is = CD_Spatial_Inertia(theta, Lam0, i_rho_t, i_rho_n)
    Tmat = CD_Dexp_SO3(theta)
    Td = MATMUL(Tmat, d)
    H = CD_Hat(Td)
    HIs = MATMUL(H, Is)
    IsH = MATMUL(Is, H)
    dIs = HIs - IsH
  END FUNCTION CD_Spatial_Inertia_Dir

  PURE FUNCTION CD_Gyro_Torque(Is, omega) RESULT(g)
    !! Spatial gyroscopic torque g = omega x (I_s omega).
    REAL(wp), INTENT(IN) :: Is(3, 3), omega(3)
    REAL(wp) :: g(3), Iw(3), Hw(3, 3)
    Iw = MATMUL(Is, omega)
    Hw = CD_Hat(omega)
    g = MATMUL(Hw, Iw)
  END FUNCTION CD_Gyro_Torque

  PURE FUNCTION CD_Gyro_Torque_DOmega(Is, omega) RESULT(Jw)
    !! d/domega[ omega x (I_s omega) ] = hat(omega) I_s - hat(I_s omega).
    REAL(wp), INTENT(IN) :: Is(3, 3), omega(3)
    REAL(wp) :: Jw(3, 3), Iw(3), Hw(3, 3), HwIs(3, 3)
    Iw = MATMUL(Is, omega)
    Hw = CD_Hat(omega)
    HwIs = MATMUL(Hw, Is)
    Jw = HwIs - CD_Hat(Iw)
  END FUNCTION CD_Gyro_Torque_DOmega

  SUBROUTINE cosserat_mult_rot_inertia(nodes_ref, elem_conn, i_rho_t, i_rho_n, q_alpha, a_alpha, v_alpha, ma_alpha)
    !! Multiplicative-path rotational inertial force: OVERWRITES the rotation DOFs of ma_alpha
    !! (the frozen consistent reference rotational mass term I_global . alpha) with the lumped
    !! additive-virtual-work spatial form, per node, summed over adjacent elements:
    !!   f_rot = sum_e (L0_e/2) T^T(theta_alpha) [ I_s(theta_alpha) alpha_alpha
    !!                                             + omega_alpha x (I_s(theta_alpha) omega_alpha) ]
    !! with I_s = Lambda J Lambda^T (config-dependent, co-rotating) and the spatial gyroscopic
    !! torque -- the physics the frozen, gyro-free reference mass omits. Translation DOFs of
    !! ma_alpha (consistent M_trans . a_alpha) are left intact.
    REAL(wp), INTENT(IN) :: nodes_ref(:, :), i_rho_t(:), i_rho_n(:), q_alpha(:), a_alpha(:), v_alpha(:)
    INTEGER, INTENT(IN) :: elem_conn(:, :)
    REAL(wp), INTENT(INOUT) :: ma_alpha(:)
    INTEGER :: n_elem, n_nodes, e, ab(2), k, nd
    REAL(wp) :: L0, w, Is(3, 3), th(3), al(3), om(3), spatial(3), Tt(3, 3), Lam0(3, 3)
    n_nodes = SIZE(nodes_ref, 2); n_elem = SIZE(elem_conn, 2)
    DO nd = 1, n_nodes
      ma_alpha(6*nd - 2:6*nd) = CD_ZERO
    END DO
    DO e = 1, n_elem
      ab(1) = elem_conn(1, e); ab(2) = elem_conn(2, e)
      CALL CD_Reference_Frame(nodes_ref(:, ab(1)), nodes_ref(:, ab(2)), Lam0, L0)
      w = 0.5_wp*L0
      DO k = 1, 2
        nd = ab(k)
        th = q_alpha(6*nd - 2:6*nd); al = a_alpha(6*nd - 2:6*nd); om = v_alpha(6*nd - 2:6*nd)
        Is = CD_Spatial_Inertia(th, Lam0, i_rho_t(e), i_rho_n(e))
        spatial = MATMUL(Is, al) + CD_Gyro_Torque(Is, om)
        Tt = TRANSPOSE(CD_Dexp_SO3(th))
        ma_alpha(6*nd - 2:6*nd) = ma_alpha(6*nd - 2:6*nd) + w*MATMUL(Tt, spatial)
      END DO
    END DO
  END SUBROUTINE cosserat_mult_rot_inertia

  SUBROUTINE cosserat_mult_rot_tangent(nodes_ref, elem_conn, i_rho_t, i_rho_n, q_alpha, v_alpha, a_alpha, &
                                       q_eval, alpha_m, alpha_f, beta, gamma, dt, global_to_free, kl, ku, effout)
    !! Adds the consistent tangent of the multiplicative rotational inertial force (the per-node
    !! dg/dpsi block, FD-verified in test_finite_ei_gyro_tangent) to the banded effective tangent's
    !! rotation diagonal, accumulated over adjacent elements:
    !!   dg/dpsi = w [ M_Ttheta (1-af) J_c + T^T ( I_s c_alpha + GyroJw c_omega + M_stheta (1-af) J_c ) ]
    !! c_alpha = (1-am)/(beta dt^2), c_omega = (1-af) gamma/(beta dt), J_c = dexp_inv(theta_alpha)
    !! dexp((1-af) psi). The translational-only Mb supplies the rest of the inertia tangent, so
    !! this is purely additive on the rotation DOFs.
    REAL(wp), INTENT(IN) :: nodes_ref(:, :), i_rho_t(:), i_rho_n(:), q_alpha(:), v_alpha(:), a_alpha(:), q_eval(:)
    REAL(wp), INTENT(IN) :: alpha_m, alpha_f, beta, gamma, dt
    INTEGER, INTENT(IN) :: elem_conn(:, :), global_to_free(:), kl, ku
    REAL(wp), INTENT(INOUT) :: effout(:, :)
    INTEGER :: n_elem, e, ab(2), kk, nd, i, j, fc(3), row, ldab
    REAL(wp) :: L0, w, ca, cw, th(3), al(3), om(3), psi(3), Is(3, 3), s(3), Tt(3, 3), Jc(3, 3)
    REAL(wp) :: GyroJw(3, 3), Mstheta(3, 3), MTtheta(3, 3), dIs(3, 3), dTm(3, 3), ds(3, 3), blk(3, 3)
    REAL(wp) :: ej(3), Iw(3), afJc(3, 3), Lam0(3, 3)
    ldab = SIZE(effout, 1)
    n_elem = SIZE(elem_conn, 2)
    ca = (1.0_wp - alpha_m)/(beta*dt*dt)
    cw = (1.0_wp - alpha_f)*gamma/(beta*dt)
    DO e = 1, n_elem
      ab(1) = elem_conn(1, e); ab(2) = elem_conn(2, e)
      CALL CD_Reference_Frame(nodes_ref(:, ab(1)), nodes_ref(:, ab(2)), Lam0, L0)
      w = 0.5_wp*L0
      DO kk = 1, 2
        nd = ab(kk)
        fc(1) = global_to_free(6*nd - 2); fc(2) = global_to_free(6*nd - 1); fc(3) = global_to_free(6*nd)
        IF (fc(1) == 0 .OR. fc(2) == 0 .OR. fc(3) == 0) CYCLE   ! fixed rotational node -> no free columns
        th = q_alpha(6*nd - 2:6*nd); al = a_alpha(6*nd - 2:6*nd); om = v_alpha(6*nd - 2:6*nd)
        psi = q_eval(6*nd - 2:6*nd)
        Is = CD_Spatial_Inertia(th, Lam0, i_rho_t(e), i_rho_n(e))
        s = MATMUL(Is, al) + CD_Gyro_Torque(Is, om)
        Tt = TRANSPOSE(CD_Dexp_SO3(th))
        Jc = MATMUL(CD_Dexp_Inv_SO3(th), CD_Dexp_SO3((1.0_wp - alpha_f)*psi))
        afJc = (1.0_wp - alpha_f)*Jc
        GyroJw = CD_Gyro_Torque_DOmega(Is, om)
        DO j = 1, 3
          ej = CD_ZERO; ej(j) = 1.0_wp
          dIs = CD_Spatial_Inertia_Dir(th, Lam0, i_rho_t(e), i_rho_n(e), ej)
          Iw = MATMUL(dIs, om)
          Mstheta(:, j) = MATMUL(dIs, al) + MATMUL(CD_Hat(om), Iw)
          dTm = CD_Dexp_Dir_SO3(th, ej)
          MTtheta(:, j) = MATMUL(TRANSPOSE(dTm), s)
        END DO
        ds = ca*Is + cw*GyroJw + MATMUL(Mstheta, afJc)
        blk = w*(MATMUL(MTtheta, afJc) + MATMUL(Tt, ds))
        DO j = 1, 3
          DO i = 1, 3
            row = kl + ku + 1 + fc(i) - fc(j)
            IF (row >= 1 .AND. row <= ldab) effout(row, fc(j)) = effout(row, fc(j)) + blk(i, j)
          END DO
        END DO
      END DO
    END DO
  END SUBROUTINE cosserat_mult_rot_tangent

  PURE FUNCTION cd_solve3(A, b) RESULT(x)
    !! Solve the 3x3 system A x = b by Cramer's rule (A well-conditioned here: a sum of
    !! T^T I_s blocks). Returns NaN on a (near-)singular A so the caller's IEEE_IS_FINITE check
    !! fails closed (HUGE would read as a finite "success" with max-real accelerations).
    REAL(wp), INTENT(IN) :: A(3, 3), b(3)
    REAL(wp) :: x(3), det, A1(3, 3), A2(3, 3), A3(3, 3)
    det = A(1, 1)*(A(2, 2)*A(3, 3) - A(2, 3)*A(3, 2)) &
          - A(1, 2)*(A(2, 1)*A(3, 3) - A(2, 3)*A(3, 1)) &
          + A(1, 3)*(A(2, 1)*A(3, 2) - A(2, 2)*A(3, 1))
    IF (ABS(det) <= TINY(1.0_wp)) THEN
      x = IEEE_VALUE(1.0_wp, IEEE_QUIET_NAN)
      RETURN
    END IF
    A1 = A; A1(:, 1) = b
    A2 = A; A2(:, 2) = b
    A3 = A; A3(:, 3) = b
    x(1) = det3(A1)/det
    x(2) = det3(A2)/det
    x(3) = det3(A3)/det
  CONTAINS
    PURE FUNCTION det3(M) RESULT(d)
      REAL(wp), INTENT(IN) :: M(3, 3)
      REAL(wp) :: d
      d = M(1, 1)*(M(2, 2)*M(3, 3) - M(2, 3)*M(3, 2)) &
          - M(1, 2)*(M(2, 1)*M(3, 3) - M(2, 3)*M(3, 1)) &
          + M(1, 3)*(M(2, 1)*M(3, 2) - M(2, 2)*M(3, 1))
    END FUNCTION det3
  END FUNCTION cd_solve3

  SUBROUTINE cosserat_mult_initial_rot_accel(nodes_ref, elem_conn, i_rho_t, i_rho_n, q, v, f_ext, fint, dof_marker, a0)
    !! Velocity-aware multiplicative initial rotational acceleration. For every node whose
    !! rotation DOFs are FREE (dof_marker /= 0), solve the multiplicative residual's rotational
    !! equation for alpha at t_0 so the first step starts CONSISTENT (no spurious gyroscopic
    !! transient): per node
    !!   M_rot alpha = rhs_rot - gyro,
    !!   M_rot = sum_e w_e T^T(theta) I_s^e,  gyro = sum_e w_e T^T(theta) (omega x I_s^e omega),
    !!   rhs_rot = (f_ext - f_int)(rot),  w_e = L0_e/2,  theta = q(rot), omega = v(rot).
    !! For a free asymmetric spin (f_ext = f_int = 0, theta = 0) this gives the Euler
    !! acceleration alpha = -I_s^{-1}(omega x I_s omega). Fixed rotational nodes are untouched
    !! (a0 already 0 / prescribed). Overwrites only free rotation DOFs of a0.
    REAL(wp), INTENT(IN) :: nodes_ref(:, :), i_rho_t(:), i_rho_n(:), q(:), v(:), f_ext(:), fint(:)
    INTEGER, INTENT(IN) :: elem_conn(:, :), dof_marker(:)
    REAL(wp), INTENT(INOUT) :: a0(:)
    INTEGER :: n_nodes, n_elem, e, ab(2), k, nd
    REAL(wp) :: L0, w, Lam0(3, 3), Is(3, 3), Tt(3, 3), th(3), om(3), TtIs(3, 3)
    REAL(wp), ALLOCATABLE :: Mrot(:, :, :), gyro(:, :)
    n_nodes = SIZE(nodes_ref, 2); n_elem = SIZE(elem_conn, 2)
    ALLOCATE (Mrot(3, 3, n_nodes), gyro(3, n_nodes))
    Mrot = CD_ZERO; gyro = CD_ZERO
    DO e = 1, n_elem
      ab(1) = elem_conn(1, e); ab(2) = elem_conn(2, e)
      CALL CD_Reference_Frame(nodes_ref(:, ab(1)), nodes_ref(:, ab(2)), Lam0, L0)
      w = 0.5_wp*L0
      DO k = 1, 2
        nd = ab(k)
        th = q(6*nd - 2:6*nd); om = v(6*nd - 2:6*nd)
        Is = CD_Spatial_Inertia(th, Lam0, i_rho_t(e), i_rho_n(e))
        Tt = TRANSPOSE(CD_Dexp_SO3(th))
        TtIs = MATMUL(Tt, Is)
        Mrot(:, :, nd) = Mrot(:, :, nd) + w*TtIs
        gyro(:, nd) = gyro(:, nd) + w*MATMUL(Tt, CD_Gyro_Torque(Is, om))
      END DO
    END DO
    DO nd = 1, n_nodes
      IF (dof_marker(6*nd - 2) == 0 .OR. dof_marker(6*nd - 1) == 0 .OR. dof_marker(6*nd) == 0) CYCLE
      a0(6*nd - 2:6*nd) = cd_solve3(Mrot(:, :, nd), f_ext(6*nd - 2:6*nd) - fint(6*nd - 2:6*nd) - gyro(:, nd))
    END DO
    DEALLOCATE (Mrot, gyro)
  END SUBROUTINE cosserat_mult_initial_rot_accel

  SUBROUTINE CD_Cosserat_Initial_Acceleration(nodes_ref, elem_conn, ea, gas, ei, gj, &
                                              rho_a, i_rho_t, i_rho_n, reduced_shear, q, f_ext, &
                                              fixed_dofs, a0, ErrStat, ErrMsg, a_prescribed, workspace, &
                                              v, multiplicative)
    !! Consistent-mass initial acceleration: solve M a = f_ext - f_int(q) on the free
    !! DOFs. Mirrors CD_Cable_Initial_Acceleration for the 6-DOF finite-EI path.
    !!
    !! By default the fixed DOFs are taken at rest (a = 0). When a prescribed support
    !! accelerates (a motionFile row with non-zero endpoint acceleration), pass the full
    !! acceleration vector in `a_prescribed`: its fixed-DOF entries set a0(fixed) and the
    !! free solve carries the support-coupling term, M_ff a_f = f_f - fint_f - M_fp a_p,
    !! instead of dropping M_fp a_p (which would leave the interior accelerations
    !! inconsistent with an accelerating boundary). a_prescribed absent == the rest
    !! contract, bit-for-bit.
    REAL(wp), INTENT(IN) :: nodes_ref(:, :), ea(:), gas(:), ei(:), gj(:)
    REAL(wp), INTENT(IN) :: rho_a(:), i_rho_t(:), i_rho_n(:), q(:), f_ext(:)
    INTEGER, INTENT(IN) :: elem_conn(:, :), fixed_dofs(:)
    LOGICAL, INTENT(IN) :: reduced_shear
    REAL(wp), INTENT(OUT) :: a0(:)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    REAL(wp), INTENT(IN), OPTIONAL :: a_prescribed(:)   !! full-length; fixed-DOF entries are the prescribed accels
    TYPE(CD_CosseratGenAlphaWorkspace), INTENT(INOUT), TARGET, OPTIONAL :: workspace
    !! Multiplicative-SO(3) path: pass the spatial angular velocity v and multiplicative=.TRUE.
    !! so the rotational a0 satisfies the gyroscopic residual (the Euler acceleration), making
    !! the first generalized-alpha step consistent. Absent -> the velocity-independent solve.
    REAL(wp), INTENT(IN), OPTIONAL :: v(:)
    LOGICAL, INTENT(IN), OPTIONAL :: multiplicative
    INTEGER :: n_dof, n_free, es, kl, ku, ldab
    LOGICAL :: mult_ic
    TYPE(CD_CosseratGenAlphaWorkspace), TARGET :: local_workspace
    TYPE(CD_CosseratGenAlphaWorkspace), POINTER :: work
    INTEGER, POINTER :: free(:)
    REAL(wp), POINTER :: fint(:), rhs(:), M_band(:, :), support_accel(:), support_force(:)
    CHARACTER(1024) :: em
    a0 = CD_ZERO; ErrStat = CD_DYN_OK; ErrMsg = ''
    n_dof = SIZE(q)
    IF (MOD(n_dof, 6) /= 0 .OR. n_dof < 12 .OR. SIZE(f_ext) /= n_dof .OR. SIZE(a0) /= n_dof) THEN
      ErrStat = CD_DYN_BADINPUT; ErrMsg = 'CD_Cosserat_Initial_Acceleration: bad state shapes'; RETURN
    END IF
    IF (.NOT. CD_All_Finite(q) .OR. .NOT. CD_All_Finite(f_ext)) THEN
      ErrStat = CD_DYN_BADINPUT; ErrMsg = 'CD_Cosserat_Initial_Acceleration: q / f_ext non-finite'; RETURN
    END IF
    IF (PRESENT(a_prescribed)) THEN
      IF (SIZE(a_prescribed) /= n_dof) THEN
        ErrStat = CD_DYN_BADINPUT; ErrMsg = 'CD_Cosserat_Initial_Acceleration: a_prescribed size mismatch'; RETURN
      END IF
      IF (.NOT. CD_All_Finite(a_prescribed)) THEN
        ErrStat = CD_DYN_BADINPUT; ErrMsg = 'CD_Cosserat_Initial_Acceleration: a_prescribed non-finite'; RETURN
      END IF
    END IF
    mult_ic = .FALSE.
    IF (PRESENT(multiplicative)) mult_ic = multiplicative
    IF (mult_ic) THEN
      IF (.NOT. PRESENT(v)) THEN
        ErrStat = CD_DYN_BADINPUT
        ErrMsg = 'CD_Cosserat_Initial_Acceleration: multiplicative path requires the velocity v'; RETURN
      END IF
      IF (SIZE(v) /= n_dof .OR. .NOT. CD_All_Finite(v)) THEN
        ErrStat = CD_DYN_BADINPUT; ErrMsg = 'CD_Cosserat_Initial_Acceleration: v must be (6 n_nodes) and finite'; RETURN
      END IF
    END IF
    IF (PRESENT(workspace)) THEN
      work => workspace
    ELSE
      work => local_workspace
    END IF
    CALL reject_partial_rot(fixed_dofs, n_dof/6, ErrStat, ErrMsg)
    IF (ErrStat /= 0) RETURN
    CALL ensure_cosserat_dof_workspace(work, n_dof, SIZE(fixed_dofs), ErrStat, ErrMsg)
    IF (ErrStat /= CD_DYN_OK) RETURN
    CALL partition_cosserat_free_workspace(fixed_dofs, n_dof, work%free, n_free, work%fixed, work%dof_marker, &
                                           ErrStat, ErrMsg)
    IF (ErrStat /= CD_DYN_OK) RETURN
    IF (PRESENT(a_prescribed)) a0(fixed_dofs) = a_prescribed(fixed_dofs)
    CALL ensure_real_vector(work%fint_eval, n_dof, ErrStat, ErrMsg)
    IF (ErrStat /= CD_DYN_OK) RETURN
    fint => work%fint_eval(1:n_dof)
    CALL CD_Assemble_Cosserat_Internal_Force_Workspace(nodes_ref, elem_conn, ea, gas, ei, gj, q, &
                                                       reduced_shear, work%assembly, fint, es, em)
    IF (es /= 0) THEN
      ErrStat = CD_DYN_BADINPUT; ErrMsg = 'internal-force assembly failed: '//TRIM(em); RETURN
    END IF
    IF (n_free == 0) RETURN                  ! every DOF prescribed -> a set above (else 0)
    free => work%free(1:n_free)
    CALL CD_Cosserat_Free_Bandwidth_Workspace(elem_conn, n_dof/6, free, work%dof_marker, kl, ku, es, em)
    IF (es /= 0) THEN
      ErrStat = CD_DYN_BADINPUT
      ErrMsg = 'CD_Cosserat_Initial_Acceleration: bandwidth analysis failed: '//TRIM(em)
      RETURN
    END IF
    ldab = 2*kl + ku + 1
    CALL ensure_cosserat_step_workspace(work, n_dof, n_free, ldab, ErrStat, ErrMsg)
    IF (ErrStat /= CD_DYN_OK) RETURN
    M_band => work%Mb(1:ldab, 1:n_free)
    rhs => work%R_free(1:n_free)
    CALL assemble_cosserat_mass_banded_free_workspace(nodes_ref, elem_conn, rho_a, i_rho_t, i_rho_n, &
                                                      free, kl, ku, work%dof_marker, M_band, es, em)
    IF (es /= 0) THEN
      ErrStat = CD_DYN_BADINPUT
      ErrMsg = 'CD_Cosserat_Initial_Acceleration: mass band assembly failed: '//TRIM(em)
      RETURN
    END IF
    rhs = f_ext(free) - fint(free)
    IF (PRESENT(a_prescribed) .AND. SIZE(fixed_dofs) > 0) THEN
      support_accel => work%a_eval(1:n_dof)
      support_force => work%ma_alpha(1:n_dof)
      support_accel = CD_ZERO
      support_accel(fixed_dofs) = a_prescribed(fixed_dofs)
      CALL CD_Cosserat_Mass_MatVec(nodes_ref, elem_conn, rho_a, i_rho_t, i_rho_n, support_accel, &
                                   support_force, es, em)
      IF (es /= 0) THEN
        ErrStat = CD_DYN_BADINPUT
        ErrMsg = 'CD_Cosserat_Initial_Acceleration: support-inertia mass product failed: '//TRIM(em)
        RETURN
      END IF
      rhs = rhs - support_force(free)
    END IF
    CALL CD_Solve_Banded(M_band, kl, ku, rhs, es, em)
    IF (es /= 0 .OR. .NOT. CD_All_Finite(rhs)) THEN
      ErrStat = CD_DYN_SINGULAR
      ErrMsg = 'CD_Cosserat_Initial_Acceleration: singular mass (DGBSV): '//TRIM(em)
      RETURN
    END IF
    a0(free) = rhs
    IF (mult_ic) THEN
      ! overwrite the free rotational accelerations with the gyroscopic-consistent values
      ! (the velocity-independent solve above gives the frozen, gyro-free rotational a). The
      ! translational a (block-diagonal in the consistent mass) is unaffected. work%dof_marker
      ! holds the global->free map (set by the mass assembly); fint was assembled above.
      CALL cosserat_mult_initial_rot_accel(nodes_ref, elem_conn, i_rho_t, i_rho_n, q, v, f_ext, fint, &
                                           work%dof_marker, a0)
      IF (.NOT. CD_All_Finite(a0)) THEN
        ErrStat = CD_DYN_SINGULAR
        ErrMsg = 'CD_Cosserat_Initial_Acceleration: singular rotational inertia (multiplicative IC)'
        RETURN
      END IF
    END IF
  END SUBROUTINE CD_Cosserat_Initial_Acceleration

  SUBROUTINE CD_Cosserat_Gen_Alpha_Step(nodes_ref, elem_conn, ea, gas, ei, gj, rho_a, i_rho_t, &
                                        i_rho_n, reduced_shear, q, v, a, f_ext, fixed_dofs, dt, &
                                        cfg, q_new, v_new, a_new, converged, stalled, n_iter, &
                                        ErrStat, ErrMsg, q_fixed_target, v_fixed_target, a_fixed_target, &
                                        load_force_proc, load_band_proc, workspace)
    !! One generalised-α step for the finite-EI Cosserat line: the constant load f_ext plus
    !! the optional force-only and banded load callbacks. Chung-Hulbert: predictor + Newton on
    !!   R = M a_alpha + f_int(q_alpha) - f_ext,
    !! effective tangent (1-am)/(beta dt^2) M + (1-af) K_t(q_alpha), banded DGBSV on
    !! the free block, Armijo backtracking on 1/2||R||^2. The consistent (reference)
    !! mass and the element tangent come from the reference-validated CableDyn_Cosserat*
    !! routines.
    !!
    !! SCOPE: by default rotation DOFs are updated ADDITIVELY (like translations), the
    !! small-rotation regime (|theta| small, where T_so3 = I to round-off and the gyroscopic
    !! torque omega x J omega is negligible). cfg%multiplicative_rotation selects the
    !! multiplicative SO(3) update with the configuration-dependent spatial inertia and the
    !! gyroscopic torque; the energy-conserving alternative is CableDyn_CosseratEMC. Partial
    !! rotational Dirichlet is rejected for the same finite-rotation reason as the static
    !! solver, and the combinations the multiplicative path does not support fail closed.
    REAL(wp), INTENT(IN) :: nodes_ref(:, :), ea(:), gas(:), ei(:), gj(:)
    REAL(wp), INTENT(IN) :: rho_a(:), i_rho_t(:), i_rho_n(:)
    LOGICAL, INTENT(IN) :: reduced_shear
    REAL(wp), INTENT(IN) :: q(:), v(:), a(:), f_ext(:), dt
    INTEGER, INTENT(IN) :: elem_conn(:, :), fixed_dofs(:)
    TYPE(GenAlphaConfig), INTENT(IN) :: cfg
    REAL(wp), INTENT(OUT) :: q_new(:), v_new(:), a_new(:)
    LOGICAL, INTENT(OUT) :: converged, stalled
    INTEGER, INTENT(OUT) :: n_iter, ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    !! Moving-support contract (all three supplied together; full-length, only the fixed-DOF
    !! entries are read): the fixed DOFs follow the PRESCRIBED trajectory to t_{n+1} instead of
    !! being held. q/v_pred(fixed) take the targets, a_n(fixed) keeps the t_n prescribed value,
    !! and the intermediate a_alpha(fixed) carries a_fixed_target into the free residual (the
    !! M_fp support-inertia coupling). Absent -> the held-support contract, bit-for-bit.
    REAL(wp), INTENT(IN), OPTIONAL :: q_fixed_target(:), v_fixed_target(:), a_fixed_target(:)
    PROCEDURE(CD_Cosserat_Dynamic_Force_Proc), OPTIONAL :: load_force_proc
    PROCEDURE(CD_Cosserat_Dynamic_Load_Banded_Proc), OPTIONAL :: load_band_proc
    PROCEDURE(CD_Cosserat_Dynamic_Force_Proc), POINTER :: load_force_proc_cb
    PROCEDURE(CD_Cosserat_Dynamic_Load_Banded_Proc), POINTER :: load_band_proc_cb
    TYPE(CD_CosseratGenAlphaWorkspace), INTENT(INOUT), TARGET, OPTIONAL :: workspace

    INTEGER :: n_dof, n_free, bt, es, kl, ku, ldab
    TYPE(CD_CosseratGenAlphaWorkspace), TARGET :: local_workspace
    TYPE(CD_CosseratGenAlphaWorkspace), POINTER :: work
    INTEGER, POINTER :: free(:), fixed(:), ipiv(:)
    REAL(wp), POINTER :: q_n(:), v_n(:), a_n(:), q_pred(:), v_pred(:)
    REAL(wp), POINTER :: qk(:), R(:), Mb(:, :), Kb(:, :), eff_band(:, :), R_free(:), dq(:)
    REAL(wp), POINTER :: q_trial(:), R_trial(:), corr(:)
    REAL(wp), POINTER :: a_eval(:), a_alpha(:), q_alpha(:), v_eval(:), v_alpha(:)
    REAL(wp), POINTER :: fint_eval(:), ma_alpha(:), load_eval(:)
    REAL(wp), POINTER :: load_jq_band(:, :), load_jv_band(:, :)
    REAL(wp) :: alpha_m, alpha_f, beta, gamma, rho, scale, r0, norm, merit, merit_trial, step
    LOGICAL :: accepted, have_eff, have_cached_residual, tangent_fresh, moving_support, mult
    REAL(wp), ALLOCATABLE :: theta_n_abs(:, :)   ! absolute t_n nodal rotations (multiplicative path)
    REAL(wp), ALLOCATABLE :: rot_chain(:, :, :)  ! per-node consistent-tangent chain Jacobian J_c
    REAL(wp), ALLOCATABLE :: q_cand(:)           ! composed end-of-step candidate pose (validation)
    CHARACTER(1024) :: em

    q_new = CD_ZERO; v_new = CD_ZERO; a_new = CD_ZERO
    converged = .FALSE.; stalled = .FALSE.; n_iter = 0
    ErrStat = CD_DYN_OK; ErrMsg = ''
    n_dof = SIZE(q)
    NULLIFY (load_force_proc_cb, load_band_proc_cb)
    IF (PRESENT(load_force_proc)) load_force_proc_cb => load_force_proc
    IF (PRESENT(load_band_proc)) load_band_proc_cb => load_band_proc

    IF (MOD(n_dof, 6) /= 0 .OR. n_dof < 12) THEN
      ErrStat = CD_DYN_BADINPUT; ErrMsg = 'CD_Cosserat_Gen_Alpha_Step: q must be (6 n_nodes), n_nodes >= 2'; RETURN
    END IF
    IF (SIZE(v) /= n_dof .OR. SIZE(a) /= n_dof .OR. SIZE(f_ext) /= n_dof .OR. &
        SIZE(q_new) /= n_dof .OR. SIZE(v_new) /= n_dof .OR. SIZE(a_new) /= n_dof) THEN
      ErrStat = CD_DYN_BADINPUT; ErrMsg = 'CD_Cosserat_Gen_Alpha_Step: state/output shapes must match q'; RETURN
    END IF
    IF (.NOT. CD_All_Finite(q) .OR. .NOT. CD_All_Finite(v) .OR. &
        .NOT. CD_All_Finite(a) .OR. .NOT. CD_All_Finite(f_ext)) THEN
      ErrStat = CD_DYN_BADINPUT; ErrMsg = 'CD_Cosserat_Gen_Alpha_Step: q,v,a,f_ext must be finite'; RETURN
    END IF
    IF (PRESENT(load_band_proc) .AND. .NOT. PRESENT(load_force_proc)) THEN
      ErrStat = CD_DYN_BADINPUT
      ErrMsg = 'CD_Cosserat_Gen_Alpha_Step: load_band_proc requires load_force_proc for residual-only evaluations'
      RETURN
    END IF
    moving_support = PRESENT(q_fixed_target)
    IF ((moving_support .NEQV. PRESENT(v_fixed_target)) .OR. (moving_support .NEQV. PRESENT(a_fixed_target))) THEN
      ErrStat = CD_DYN_BADINPUT
      ErrMsg = 'CD_Cosserat_Gen_Alpha_Step: q/v/a_fixed_target must be supplied together'; RETURN
    END IF
    IF (moving_support) THEN
      IF (SIZE(q_fixed_target) /= n_dof .OR. SIZE(v_fixed_target) /= n_dof .OR. SIZE(a_fixed_target) /= n_dof) THEN
        ErrStat = CD_DYN_BADINPUT
        ErrMsg = 'CD_Cosserat_Gen_Alpha_Step: q/v/a_fixed_target must be length 6*n_nodes'; RETURN
      END IF
      IF (.NOT. CD_All_Finite(q_fixed_target) .OR. .NOT. CD_All_Finite(v_fixed_target) .OR. &
          .NOT. CD_All_Finite(a_fixed_target)) THEN
        ErrStat = CD_DYN_BADINPUT
        ErrMsg = 'CD_Cosserat_Gen_Alpha_Step: q/v/a_fixed_target must be finite'; RETURN
      END IF
    END IF
    ! echo t_n so every later failure return leaves a valid (retryable) state
    q_new = q; v_new = v; a_new = a
    IF (.NOT. (CD_Is_Finite(dt) .AND. dt > CD_ZERO)) THEN
      ErrStat = CD_DYN_BADINPUT; ErrMsg = 'CD_Cosserat_Gen_Alpha_Step: dt must be finite and positive'; RETURN
    END IF
    IF (.NOT. CD_Is_Finite(cfg%rho_inf) .OR. cfg%rho_inf < CD_ZERO .OR. cfg%rho_inf > CD_ONE .OR. &
        .NOT. pos_finite(cfg%rel_tol) .OR. .NOT. pos_finite(cfg%abs_tol) .OR. &
        .NOT. pos_finite(cfg%armijo_c1) .OR. cfg%armijo_c1 >= CD_ONE .OR. &
        cfg%max_iter < 1 .OR. cfg%armijo_max_backtracks < 0) THEN
      ErrStat = CD_DYN_BADINPUT; ErrMsg = 'CD_Cosserat_Gen_Alpha_Step: invalid gen-alpha config'; RETURN
    END IF
    mult = cfg%multiplicative_rotation
    IF (mult .AND. moving_support) THEN
      ! Scope: a prescribed moving support supplies ABSOLUTE rotational targets,
      ! which the increment (psi) parametrisation would need converted per fixed node.
      ! This combination is unsupported: fail closed rather than mis-apply an absolute
      ! target as an increment.
      ErrStat = CD_DYN_BADINPUT
      ErrMsg = 'CD_Cosserat_Gen_Alpha_Step: multiplicative-SO(3) update with a moving support not yet supported'
      RETURN
    END IF
    IF (mult .AND. (PRESENT(load_force_proc) .OR. PRESENT(load_band_proc))) THEN
      ! Scope: a dynamic load callback is passed q_alpha in ABSOLUTE rotation coordinates
      ! and returns -d(force)/dq, but the Newton unknown is the increment psi. Its rotational
      ! load-stiffness columns therefore need the SAME J_c chain transform as the structural
      ! tangent (and a velocity-chain term), or the effective tangent is inconsistent with the
      ! residual. That load-tangent chain is not implemented, so the combination fails closed
      ! rather than use an inconsistent tangent that would converge slowly or stall.
      ErrStat = CD_DYN_BADINPUT
      ErrMsg = 'CD_Cosserat_Gen_Alpha_Step: multiplicative-SO(3) update with a dynamic load callback not yet supported'
      RETURN
    END IF
    CALL reject_partial_rot(fixed_dofs, n_dof/6, ErrStat, ErrMsg)
    IF (ErrStat /= 0) RETURN
    IF (PRESENT(workspace)) THEN
      work => workspace
    ELSE
      work => local_workspace
    END IF
    CALL ensure_cosserat_dof_workspace(work, n_dof, SIZE(fixed_dofs), ErrStat, ErrMsg)
    IF (ErrStat /= 0) RETURN
    CALL partition_cosserat_free_workspace(fixed_dofs, n_dof, work%free, n_free, work%fixed, &
                                           work%dof_marker, ErrStat, ErrMsg)
    IF (ErrStat /= 0) RETURN
    free => work%free(1:n_free)
    fixed => work%fixed(1:SIZE(fixed_dofs))

    rho = cfg%rho_inf
    alpha_m = (2.0_wp*rho - CD_ONE)/(rho + CD_ONE)
    alpha_f = rho/(rho + CD_ONE)
    beta = 0.25_wp*(CD_ONE - alpha_m + alpha_f)**2
    gamma = 0.5_wp - alpha_m + alpha_f

    CALL CD_Cosserat_Free_Bandwidth_Workspace(elem_conn, n_dof/6, free, work%dof_marker, kl, ku, ErrStat, ErrMsg)
    IF (ErrStat /= 0) THEN
      ErrMsg = 'CD_Cosserat_Gen_Alpha_Step: bandwidth analysis failed: '//TRIM(ErrMsg); RETURN
    END IF
    ldab = 2*kl + ku + 1
    CALL ensure_cosserat_step_workspace(work, n_dof, n_free, ldab, ErrStat, ErrMsg)
    IF (ErrStat /= 0) RETURN
    CALL bind_cosserat_workspace(work)

    q_n = q
    v_n = v
    a_n = a
    IF (mult) THEN
      ! Multiplicative-SO(3) path: parametrise each step by the per-step rotation
      ! INCREMENT psi (from Lambda_n), so every additive Newmark formula below acts on
      ! psi unchanged (linear in the increment) while the absolute rotation is recovered
      ! by SO(3) composition at the element input and at the state update. psi stays
      ! small per step, so the iterate never leaves the |theta| < pi chart even as the
      ! absolute rotation winds past pi. Rebase q_n's rotation DOFs to psi = 0 and stash
      ! the absolute t_n rotations.
      ALLOCATE (theta_n_abs(3, n_dof/6))
      ALLOCATE (rot_chain(3, 3, n_dof/6))
      ALLOCATE (q_cand(n_dof))
      CALL cosserat_rot_rebase_to_increment(q_n, theta_n_abs)
    END IF
    q_pred = q_n + dt*v_n + dt*dt*(0.5_wp - beta)*a_n
    v_pred = v_n + dt*(CD_ONE - gamma)*a_n
    IF (SIZE(fixed) > 0) THEN
      IF (moving_support) THEN
        ! Prescribed-trajectory support: predictor takes the t_{n+1} targets; a_n(fixed) keeps
        ! the t_n prescribed acceleration (input a) so the Chung-Hulbert a_alpha blend is correct.
        q_pred(fixed) = q_fixed_target(fixed)
        v_pred(fixed) = v_fixed_target(fixed)
      ELSE
        q_pred(fixed) = q_n(fixed); v_pred(fixed) = CD_ZERO; a_n(fixed) = CD_ZERO
      END IF
    END IF

    qk = q_pred
    ! Multiplicative path: drop the rotational mass from the tangent Mb -- its rotational
    ! inertia tangent is the config-dependent + gyroscopic per-node block added below
    ! (cosserat_mult_rot_tangent); keeping the frozen consistent rotational mass too would
    ! double-count it. The residual's rotational inertia is likewise replaced (mult branch
    ! of eval_dyn). The additive path keeps the full consistent mass.
    CALL assemble_cosserat_mass_banded_free_workspace(nodes_ref, elem_conn, rho_a, i_rho_t, i_rho_n, &
                                                      free, kl, ku, work%dof_marker, Mb, es, em, &
                                                      translational_only=mult)
    IF (es /= 0) THEN
      ErrStat = CD_DYN_BADINPUT; ErrMsg = 'mass band assembly failed: '//TRIM(em); RETURN
    END IF
    ! validate q_n's per-element rotation state (chart + singular relative rotation,
    ! the shared element-domain contract) after the connectivity/inertia checks
    ! above, so element DOF slicing is known in-range.
    CALL validate_mesh_rotation_state(q, elem_conn, ErrStat, ErrMsg)
    IF (ErrStat /= 0) THEN
      ErrMsg = 'CD_Cosserat_Gen_Alpha_Step (q_n): '//TRIM(ErrMsg); RETURN
    END IF

    r0 = CD_ZERO; scale = CD_ONE
    have_eff = .FALSE.
    have_cached_residual = .FALSE.
    DO
      IF (cfg%modified_newton .AND. have_cached_residual) THEN
        tangent_fresh = .FALSE.
        have_cached_residual = .FALSE.
      ELSE IF (cfg%modified_newton .AND. have_eff) THEN
        tangent_fresh = .FALSE.
        CALL eval_dyn(qk, R, es, em)
      ELSE
        tangent_fresh = .TRUE.
        CALL eval_dyn(qk, R, es, em, effout=eff_band)
        IF (es == 0) THEN
          have_eff = .TRUE.
          CALL CD_Factor_Banded(eff_band, kl, ku, ipiv, es, em)
          IF (es /= 0) THEN
            ErrStat = CD_DYN_SINGULAR
            ErrMsg = 'CD_Cosserat_Gen_Alpha_Step: effective tangent singular/ill-conditioned (DGBTRF): '//TRIM(em)
            RETURN
          END IF
        END IF
      END IF
      IF (es /= 0) THEN
        ErrStat = CD_DYN_BADINPUT; ErrMsg = em; RETURN
      END IF
      R_free = R(free)
      norm = infnorm(R_free)
      IF (n_iter == 0) THEN
        r0 = norm
        scale = MAX(infnorm(f_ext(free)), r0, cfg%abs_tol)
      END IF
      IF (norm/scale < cfg%rel_tol .OR. norm < cfg%abs_tol) THEN
        converged = .TRUE.; EXIT
      END IF
      IF (n_iter >= cfg%max_iter) EXIT
      dq = -R_free
      CALL CD_Solve_Factored_Banded(eff_band, kl, ku, ipiv, dq, es, em)
      IF (es /= 0 .OR. .NOT. CD_All_Finite(dq)) THEN
        IF (cfg%modified_newton .AND. .NOT. tangent_fresh) THEN
          CALL record_stale_reject(work, n_iter)
          have_eff = .FALSE.
          CYCLE
        END IF
        ErrStat = CD_DYN_SINGULAR
        ErrMsg = 'CD_Cosserat_Gen_Alpha_Step: effective tangent singular/ill-conditioned (DGBSV): '//TRIM(em)
        RETURN
      END IF
      merit = 0.5_wp*DOT_PRODUCT(R_free, R_free)
      step = CD_ONE; accepted = .FALSE.
      DO bt = 0, cfg%armijo_max_backtracks
        q_trial = qk
        q_trial(free) = q_trial(free) + step*dq
        CALL eval_dyn(q_trial, R_trial, es, em)
        ! A trial that leaves the element domain (e.g. an out-of-chart rotation
        ! from an over-long Newton step on an ill-conditioned tangent) is a
        ! RECOVERABLE rejection -- backtrack, do not hard-fail the step. Only a
        ! failure at the current iterate qk (handled by the effout eval above) is
        ! fatal; the last accepted qk is always in the element domain.
        IF (es == 0) THEN
          merit_trial = 0.5_wp*DOT_PRODUCT(R_trial(free), R_trial(free))
          IF (merit_trial <= merit*(CD_ONE - cfg%armijo_c1*step)) THEN
            accepted = .TRUE.; EXIT
          END IF
        END IF
        step = 0.5_wp*step
      END DO
      n_iter = n_iter + 1
      IF (.NOT. accepted) THEN
        IF (cfg%modified_newton .AND. .NOT. tangent_fresh) THEN
          CALL record_stale_reject(work, n_iter - 1)
          have_eff = .FALSE.
          CYCLE
        END IF
        stalled = .TRUE.; EXIT
      END IF
      IF (cfg%modified_newton .AND. .NOT. tangent_fresh) CALL record_stale_accept(work, n_iter - 1)
      qk = q_trial
      IF (cfg%modified_newton) THEN
        R = R_trial
        have_cached_residual = .TRUE.
      END IF
      IF (.NOT. cfg%modified_newton) have_eff = .FALSE.
    END DO

    corr = qk - q_pred
    a_new = corr/(beta*dt*dt)
    v_new = v_pred + gamma*dt*a_new
    q_new = qk
    IF (SIZE(fixed) > 0) THEN
      IF (moving_support) THEN
        q_new(fixed) = q_fixed_target(fixed)
        v_new(fixed) = v_fixed_target(fixed)
        a_new(fixed) = a_fixed_target(fixed)
      ELSE
        q_new(fixed) = q_n(fixed); v_new(fixed) = CD_ZERO; a_new(fixed) = CD_ZERO
      END IF
    END IF
    IF (mult) THEN
      ! recover the absolute rotation theta_{n+1} = log(exp(psi) Lambda_n) from the
      ! converged increment psi held in q_new's rotation DOFs. Fixed (held) rotation
      ! DOFs carry psi = 0 -> compose returns theta_n, so they stay pinned. v_new/a_new
      ! rotation DOFs are already the spatial omega_{n+1}/alpha_{n+1} (Newmark on psi).
      CALL cosserat_rot_compose_to_absolute(q_new, theta_n_abs)
      DEALLOCATE (theta_n_abs, rot_chain, q_cand)
    END IF

  CONTAINS

    SUBROUTINE bind_cosserat_workspace(workspace_ref)
      TYPE(CD_CosseratGenAlphaWorkspace), TARGET, INTENT(INOUT) :: workspace_ref

      q_n => workspace_ref%q_n(1:n_dof)
      v_n => workspace_ref%v_n(1:n_dof)
      a_n => workspace_ref%a_n(1:n_dof)
      q_pred => workspace_ref%q_pred(1:n_dof)
      v_pred => workspace_ref%v_pred(1:n_dof)
      qk => workspace_ref%qk(1:n_dof)
      R => workspace_ref%R(1:n_dof)
      corr => workspace_ref%corr(1:n_dof)
      q_trial => workspace_ref%q_trial(1:n_dof)
      R_trial => workspace_ref%R_trial(1:n_dof)
      a_eval => workspace_ref%a_eval(1:n_dof)
      a_alpha => workspace_ref%a_alpha(1:n_dof)
      q_alpha => workspace_ref%q_alpha(1:n_dof)
      v_eval => workspace_ref%v_eval(1:n_dof)
      v_alpha => workspace_ref%v_alpha(1:n_dof)
      fint_eval => workspace_ref%fint_eval(1:n_dof)
      ma_alpha => workspace_ref%ma_alpha(1:n_dof)
      load_eval => workspace_ref%load_eval(1:n_dof)
      R_free => workspace_ref%R_free(1:n_free)
      dq => workspace_ref%dq(1:n_free)
      ipiv => workspace_ref%ipiv(1:n_free)
      Mb => workspace_ref%Mb(1:ldab, 1:n_free)
      Kb => workspace_ref%Kb(1:ldab, 1:n_free)
      load_jq_band => workspace_ref%load_jq_band(1:ldab, 1:n_free)
      load_jv_band => workspace_ref%load_jv_band(1:ldab, 1:n_free)
      eff_band => workspace_ref%eff_band(1:ldab, 1:n_free)
    END SUBROUTINE bind_cosserat_workspace

    SUBROUTINE eval_dyn(q_eval, Rout, es_e, em_e, effout)
      !! R = M a_alpha + f_int(q_alpha) - f_ext; with effout present also returns
      !! (1-am)/(beta dt^2) M + (1-af) K_t(q_alpha). Host-associates the
      !! predictor / blend state, the mesh, and the gen-alpha parameters.
      REAL(wp), INTENT(IN) :: q_eval(:)
      REAL(wp), INTENT(OUT) :: Rout(:)
      INTEGER, INTENT(OUT) :: es_e
      CHARACTER(*), INTENT(OUT) :: em_e
      REAL(wp), INTENT(OUT), OPTIONAL :: effout(:, :)
      INTEGER :: j_node
      es_e = 0; em_e = ''
      Rout = CD_ZERO
      IF (PRESENT(effout)) effout = CD_ZERO
      ! The element only ever sees the blended q_alpha = (1-af) q_eval + af q_n.
      ! At rho_inf > 0 that blend can pull an INVALID q_eval -- out of the |theta|
      ! < pi chart OR with a log-singular relative rotation (e.g. theta1=+pi/2 e_x,
      ! theta2=-pi/2 e_x) -- back into the valid region before assembly, hiding it
      ! from the element-domain check. Validate the iterate ITSELF with the full
      ! shared contract (chart + singular relative rotation), per element, so an
      ! invalid q_eval fails (predictor / current iterate -> fatal) or backtracks
      ! (trial step) rather than yielding a q_new the force/tangent/energy reject.
      ! Multiplicative path: q_eval's rotation DOFs are the per-step INCREMENT psi, so the
      ! chart/singular contract is checked on the composed END-OF-STEP candidate
      ! exp(psi) Lambda_n -- NOT on the (1-alpha_f) alpha-blend pose. The blend can sit below
      ! the singular window while the full increment puts adjacent nodes at a near-pi relative
      ! rotation; validating the candidate (as the additive path validates q_eval) closes that
      ! hole so a converged q_new can never be a state the next step / energy eval rejects. The
      ! alpha pose q_alpha is validated by the element assembly below (as in the additive path).
      IF (.NOT. mult) THEN
        CALL validate_mesh_rotation_state(q_eval, elem_conn, es_e, em_e)
        IF (es_e /= 0) RETURN
      ELSE
        q_cand = q_eval
        CALL cosserat_rot_compose_to_absolute(q_cand, theta_n_abs)
        CALL validate_mesh_rotation_state(q_cand, elem_conn, es_e, em_e)
        IF (es_e /= 0) RETURN
      END IF
      a_eval = (q_eval - q_pred)/(beta*dt*dt)
      v_eval = v_pred + gamma*dt*a_eval
      ! A prescribed moving support carries its own t_{n+1} acceleration (not the Newmark
      ! relation), so the intermediate a_alpha(fixed) couples into the free residual via M_fp.
      IF (moving_support .AND. SIZE(fixed) > 0) a_eval(fixed) = a_fixed_target(fixed)
      a_alpha = (CD_ONE - alpha_m)*a_eval + alpha_m*a_n
      q_alpha = (CD_ONE - alpha_f)*q_eval + alpha_f*q_n
      v_alpha = (CD_ONE - alpha_f)*v_eval + alpha_f*v_n
      IF (mult) THEN
        ! q_alpha's rotation DOFs hold (1-af)*psi (q_n rotation = 0); convert to the absolute
        ! geodesic-blended pose exp((1-af)psi) Lambda_n the element expects. a_alpha/v_alpha
        ! stay the spatial accel/vel blends; the rotational inertia term is formed below with
        ! the configuration-dependent spatial inertia and the gyroscopic torque. The element
        ! assembly validates this pose's per-element contract.
        CALL cosserat_rot_compose_to_absolute(q_alpha, theta_n_abs)
      END IF
      load_eval = CD_ZERO
      IF (PRESENT(effout)) THEN
        IF (mult) THEN
          ! consistent tangent: dfint/dpsi = K . J_c, J_c = dexp_inv(theta_alpha) . dexp((1-af) psi)
          ! per node (theta_alpha = composed q_alpha rotation; psi = q_eval rotation increment).
          ! FD-verified in test_finite_ei_mult_tangent; applied to the element columns in the assembly.
          DO j_node = 1, n_dof/6
            rot_chain(:, :, j_node) = MATMUL(CD_Dexp_Inv_SO3(q_alpha(6*j_node - 2:6*j_node)), &
                                             CD_Dexp_SO3((CD_ONE - alpha_f)*q_eval(6*j_node - 2:6*j_node)))
          END DO
          CALL CD_Assemble_Cosserat_Tangent_Force_Banded_Free_Workspace(nodes_ref, elem_conn, ea, gas, ei, gj, &
                                                                        q_alpha, reduced_shear, free, kl, ku, &
                                                                        work%assembly, Kb, fint_eval, es_e, em_e, &
                                                                        rot_col_chain=rot_chain)
        ELSE
          CALL CD_Assemble_Cosserat_Tangent_Force_Banded_Free_Workspace(nodes_ref, elem_conn, ea, gas, ei, gj, &
                                                                        q_alpha, reduced_shear, free, kl, ku, &
                                                                        work%assembly, Kb, fint_eval, es_e, em_e)
        END IF
        IF (es_e /= 0) THEN
          em_e = 'tangent assembly failed: '//TRIM(em_e); Rout = CD_ZERO; effout = CD_ZERO; RETURN
        END IF
        effout = (CD_ONE - alpha_m)/(beta*dt*dt)*Mb + (CD_ONE - alpha_f)*Kb
        IF (mult) THEN
          ! Mb is translational-only here; add the consistent rotational-inertia tangent
          ! (config-dependent inertia + gyroscopic + T^T, FD-verified) on the rotation DOFs.
          CALL cosserat_mult_rot_tangent(nodes_ref, elem_conn, i_rho_t, i_rho_n, q_alpha, v_alpha, a_alpha, &
                                         q_eval, alpha_m, alpha_f, beta, gamma, dt, work%assembly%global_to_free, &
                                         kl, ku, effout)
        END IF
      ELSE
        CALL CD_Assemble_Cosserat_Internal_Force_Workspace(nodes_ref, elem_conn, ea, gas, ei, gj, q_alpha, &
                                                           reduced_shear, work%assembly, fint_eval, es_e, em_e)
        IF (es_e /= 0) THEN
          em_e = 'internal-force assembly failed: '//TRIM(em_e); Rout = CD_ZERO; RETURN
        END IF
      END IF
      IF (PRESENT(effout) .AND. ASSOCIATED(load_band_proc_cb)) THEN
        load_jq_band = CD_ZERO
        load_jv_band = CD_ZERO
        CALL load_band_proc_cb(q_alpha, v_alpha, free, kl, ku, load_eval, load_jq_band, load_jv_band, es_e, em_e)
        IF (es_e /= 0) THEN
          em_e = 'dynamic banded load callback failed: '//TRIM(em_e); Rout = CD_ZERO; effout = CD_ZERO
          RETURN
        END IF
        IF (SIZE(load_eval) /= n_dof .OR. .NOT. CD_All_Finite(load_eval) .OR. &
            .NOT. CD_All_Finite(load_jq_band) .OR. .NOT. CD_All_Finite(load_jv_band)) THEN
          es_e = CD_DYN_BADINPUT
          em_e = 'dynamic banded load callback returned non-finite values or wrong shape'
          Rout = CD_ZERO
          effout = CD_ZERO
          RETURN
        END IF
        effout = effout + (CD_ONE - alpha_f)*load_jq_band + &
                 (CD_ONE - alpha_f)*gamma/(beta*dt)*load_jv_band
      ELSE IF (ASSOCIATED(load_force_proc_cb)) THEN
        CALL load_force_proc_cb(q_alpha, v_alpha, load_eval, es_e, em_e)
        IF (es_e /= 0) THEN
          em_e = 'dynamic force callback failed: '//TRIM(em_e); Rout = CD_ZERO
          IF (PRESENT(effout)) effout = CD_ZERO
          RETURN
        END IF
        IF (SIZE(load_eval) /= n_dof .OR. .NOT. CD_All_Finite(load_eval)) THEN
          es_e = CD_DYN_BADINPUT
          em_e = 'dynamic force callback returned non-finite force or wrong shape'
          Rout = CD_ZERO
          IF (PRESENT(effout)) effout = CD_ZERO
          RETURN
        END IF
      END IF
      CALL cosserat_mass_matvec_unchecked(nodes_ref, elem_conn, rho_a, i_rho_t, i_rho_n, a_alpha, ma_alpha)
      IF (mult) THEN
        ! multiplicative: replace the frozen, gyro-free rotational mass term with the config-dependent
        ! spatial inertia + gyroscopic torque (additive-virtual-work form). q_alpha rotation is
        ! the composed absolute theta_alpha; a_alpha/v_alpha rotation are the spatial alpha/omega
        ! blends. Translational inertia (consistent M a_alpha) is unchanged.
        CALL cosserat_mult_rot_inertia(nodes_ref, elem_conn, i_rho_t, i_rho_n, q_alpha, a_alpha, v_alpha, ma_alpha)
      END IF
      Rout = ma_alpha + fint_eval - f_ext - load_eval
    END SUBROUTINE eval_dyn

  END SUBROUTINE CD_Cosserat_Gen_Alpha_Step

  SUBROUTINE cosserat_rot_rebase_to_increment(q, theta_save)
    !! Multiplicative-SO(3) step setup. Stash each node's absolute t_n rotation vector
    !! and zero the rotation DOFs of q, so the step's working state carries the per-step
    !! rotation INCREMENT psi (= 0 at t_n). Translation DOFs are untouched.
    REAL(wp), INTENT(INOUT) :: q(:)
    REAL(wp), INTENT(OUT) :: theta_save(:, :)
    INTEGER :: i, n_nodes
    n_nodes = SIZE(q)/6
    DO i = 1, n_nodes
      theta_save(:, i) = q(6*i - 2:6*i)
      q(6*i - 2:6*i) = CD_ZERO
    END DO
  END SUBROUTINE cosserat_rot_rebase_to_increment

  SUBROUTINE cosserat_rot_compose_to_absolute(q, theta_save)
    !! Multiplicative-SO(3) recovery. Replace each node's rotation increment psi held in
    !! q with the absolute rotation log(exp(psi) exp(theta_n)) = compose(theta_n, psi).
    !! psi = 0 (a held/unmoved rotation) returns theta_n exactly. Translation untouched.
    REAL(wp), INTENT(INOUT) :: q(:)
    REAL(wp), INTENT(IN) :: theta_save(:, :)
    INTEGER :: i, n_nodes
    n_nodes = SIZE(q)/6
    DO i = 1, n_nodes
      q(6*i - 2:6*i) = CD_Compose_Rotvec(theta_save(:, i), q(6*i - 2:6*i))
    END DO
  END SUBROUTINE cosserat_rot_compose_to_absolute

  SUBROUTINE ensure_cosserat_dof_workspace(work, n_dof, n_fixed, ErrStat, ErrMsg)
    TYPE(CD_CosseratGenAlphaWorkspace), INTENT(INOUT) :: work
    INTEGER, INTENT(IN) :: n_dof, n_fixed
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg

    LOGICAL :: need_marker

    ErrStat = CD_DYN_OK
    ErrMsg = ''
    IF (n_dof < 1 .OR. n_fixed < 0) THEN
      ErrStat = CD_DYN_BADINPUT
      ErrMsg = 'ensure_cosserat_dof_workspace: invalid workspace size'
      RETURN
    END IF
    IF (work%n_dof_capacity < n_dof) THEN
      CALL CD_Clear_CosseratGenAlpha_Workspace(work)
      CALL alloc_int_vector(work%dof_marker, n_dof, ErrStat, ErrMsg)
      IF (ErrStat /= CD_DYN_OK) RETURN
      work%n_dof_capacity = n_dof
      work%n_fixed_capacity = 0
      work%n_free_capacity = 0
      work%ldab_capacity = 0
    ELSE
      need_marker = .NOT. ALLOCATED(work%dof_marker)
      IF (.NOT. need_marker) need_marker = SIZE(work%dof_marker) < n_dof
      IF (need_marker) THEN
        CALL alloc_int_vector(work%dof_marker, n_dof, ErrStat, ErrMsg)
        IF (ErrStat /= CD_DYN_OK) RETURN
        work%n_dof_capacity = n_dof
      END IF
    END IF
    IF (work%n_fixed_capacity < n_fixed .OR. .NOT. ALLOCATED(work%fixed)) THEN
      CALL alloc_int_vector(work%fixed, n_fixed, ErrStat, ErrMsg)
      IF (ErrStat /= CD_DYN_OK) RETURN
      work%n_fixed_capacity = n_fixed
    END IF
    IF (work%n_free_capacity < n_dof .OR. .NOT. ALLOCATED(work%free)) THEN
      CALL alloc_int_vector(work%free, n_dof, ErrStat, ErrMsg)
      IF (ErrStat /= CD_DYN_OK) RETURN
      work%n_free_capacity = n_dof
    END IF
  END SUBROUTINE ensure_cosserat_dof_workspace

  SUBROUTINE ensure_cosserat_step_workspace(work, n_dof, n_free, ldab, ErrStat, ErrMsg)
    TYPE(CD_CosseratGenAlphaWorkspace), INTENT(INOUT) :: work
    INTEGER, INTENT(IN) :: n_dof, n_free, ldab
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    LOGICAL :: need_ipiv

    ErrStat = CD_DYN_OK
    ErrMsg = ''
    IF (n_dof < 1 .OR. n_free < 0 .OR. ldab < 1) THEN
      ErrStat = CD_DYN_BADINPUT
      ErrMsg = 'ensure_cosserat_step_workspace: invalid workspace shape'
      RETURN
    END IF
    CALL ensure_real_vector(work%q_n, n_dof, ErrStat, ErrMsg); IF (ErrStat /= CD_DYN_OK) RETURN
    CALL ensure_real_vector(work%v_n, n_dof, ErrStat, ErrMsg); IF (ErrStat /= CD_DYN_OK) RETURN
    CALL ensure_real_vector(work%a_n, n_dof, ErrStat, ErrMsg); IF (ErrStat /= CD_DYN_OK) RETURN
    CALL ensure_real_vector(work%q_pred, n_dof, ErrStat, ErrMsg); IF (ErrStat /= CD_DYN_OK) RETURN
    CALL ensure_real_vector(work%v_pred, n_dof, ErrStat, ErrMsg); IF (ErrStat /= CD_DYN_OK) RETURN
    CALL ensure_real_vector(work%qk, n_dof, ErrStat, ErrMsg); IF (ErrStat /= CD_DYN_OK) RETURN
    CALL ensure_real_vector(work%R, n_dof, ErrStat, ErrMsg); IF (ErrStat /= CD_DYN_OK) RETURN
    CALL ensure_real_vector(work%corr, n_dof, ErrStat, ErrMsg); IF (ErrStat /= CD_DYN_OK) RETURN
    CALL ensure_real_vector(work%q_trial, n_dof, ErrStat, ErrMsg); IF (ErrStat /= CD_DYN_OK) RETURN
    CALL ensure_real_vector(work%R_trial, n_dof, ErrStat, ErrMsg); IF (ErrStat /= CD_DYN_OK) RETURN
    CALL ensure_real_vector(work%a_eval, n_dof, ErrStat, ErrMsg); IF (ErrStat /= CD_DYN_OK) RETURN
    CALL ensure_real_vector(work%a_alpha, n_dof, ErrStat, ErrMsg); IF (ErrStat /= CD_DYN_OK) RETURN
    CALL ensure_real_vector(work%q_alpha, n_dof, ErrStat, ErrMsg); IF (ErrStat /= CD_DYN_OK) RETURN
    CALL ensure_real_vector(work%v_eval, n_dof, ErrStat, ErrMsg); IF (ErrStat /= CD_DYN_OK) RETURN
    CALL ensure_real_vector(work%v_alpha, n_dof, ErrStat, ErrMsg); IF (ErrStat /= CD_DYN_OK) RETURN
    CALL ensure_real_vector(work%fint_eval, n_dof, ErrStat, ErrMsg); IF (ErrStat /= CD_DYN_OK) RETURN
    CALL ensure_real_vector(work%ma_alpha, n_dof, ErrStat, ErrMsg); IF (ErrStat /= CD_DYN_OK) RETURN
    CALL ensure_real_vector(work%load_eval, n_dof, ErrStat, ErrMsg); IF (ErrStat /= CD_DYN_OK) RETURN
    CALL ensure_real_vector(work%R_free, n_free, ErrStat, ErrMsg); IF (ErrStat /= CD_DYN_OK) RETURN
    CALL ensure_real_vector(work%dq, n_free, ErrStat, ErrMsg); IF (ErrStat /= CD_DYN_OK) RETURN
    CALL ensure_real_matrix(work%Mb, ldab, n_free, ErrStat, ErrMsg); IF (ErrStat /= CD_DYN_OK) RETURN
    CALL ensure_real_matrix(work%Kb, ldab, n_free, ErrStat, ErrMsg); IF (ErrStat /= CD_DYN_OK) RETURN
    CALL ensure_real_matrix(work%load_jq_band, ldab, n_free, ErrStat, ErrMsg); IF (ErrStat /= CD_DYN_OK) RETURN
    CALL ensure_real_matrix(work%load_jv_band, ldab, n_free, ErrStat, ErrMsg); IF (ErrStat /= CD_DYN_OK) RETURN
    CALL ensure_real_matrix(work%eff_band, ldab, n_free, ErrStat, ErrMsg); IF (ErrStat /= CD_DYN_OK) RETURN
    need_ipiv = .NOT. ALLOCATED(work%ipiv)
    IF (.NOT. need_ipiv) need_ipiv = SIZE(work%ipiv) < n_free
    IF (need_ipiv) THEN
      CALL alloc_int_vector(work%ipiv, n_free, ErrStat, ErrMsg)
      IF (ErrStat /= CD_DYN_OK) RETURN
    END IF
    work%n_dof_capacity = MAX(work%n_dof_capacity, n_dof)
    work%n_free_capacity = MAX(work%n_free_capacity, n_free)
    work%ldab_capacity = MAX(work%ldab_capacity, ldab)
  END SUBROUTINE ensure_cosserat_step_workspace

  SUBROUTINE partition_cosserat_free_workspace(fixed_dofs, n_dof, free, n_free, fixed, marker, ErrStat, ErrMsg)
    INTEGER, INTENT(IN) :: fixed_dofs(:), n_dof
    INTEGER, INTENT(INOUT) :: free(:), fixed(:), marker(:)
    INTEGER, INTENT(OUT) :: n_free, ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    INTEGER :: i, d, jf, jx

    ErrStat = CD_DYN_OK
    ErrMsg = ''
    n_free = 0
    IF (SIZE(marker) < n_dof .OR. SIZE(free) < n_dof .OR. SIZE(fixed) < SIZE(fixed_dofs)) THEN
      ErrStat = CD_DYN_BADINPUT
      ErrMsg = 'partition_cosserat_free_workspace: workspace DOF arrays are undersized'
      RETURN
    END IF
    marker(1:n_dof) = 0
    DO i = 1, SIZE(fixed_dofs)
      d = fixed_dofs(i)
      IF (d < 1 .OR. d > n_dof) THEN
        ErrStat = CD_DYN_BADINPUT
        ErrMsg = 'fixed_dofs has an out-of-range index (1-based)'
        RETURN
      END IF
      IF (marker(d) /= 0) THEN
        ErrStat = CD_DYN_BADINPUT
        ErrMsg = 'fixed_dofs contains a duplicate index'
        RETURN
      END IF
      marker(d) = 1
    END DO
    jf = 0
    jx = 0
    DO d = 1, n_dof
      IF (marker(d) == 0) THEN
        jf = jf + 1
        free(jf) = d
      ELSE
        jx = jx + 1
        fixed(jx) = d
      END IF
    END DO
    n_free = jf
  END SUBROUTINE partition_cosserat_free_workspace

  SUBROUTINE alloc_int_vector(x, n, ErrStat, ErrMsg)
    INTEGER, ALLOCATABLE, INTENT(INOUT) :: x(:)
    INTEGER, INTENT(IN) :: n
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    INTEGER :: istat

    ErrStat = CD_DYN_OK
    ErrMsg = ''
    IF (n < 0) THEN
      ErrStat = CD_DYN_BADINPUT
      ErrMsg = 'alloc_int_vector: negative workspace size'
      RETURN
    END IF
    IF (ALLOCATED(x)) DEALLOCATE (x)
    ALLOCATE (x(n), STAT=istat)
    IF (istat /= 0) THEN
      ErrStat = CD_DYN_BADINPUT
      ErrMsg = 'integer workspace allocation failed'
    END IF
  END SUBROUTINE alloc_int_vector

  SUBROUTINE ensure_real_vector(x, n, ErrStat, ErrMsg)
    REAL(wp), ALLOCATABLE, INTENT(INOUT) :: x(:)
    INTEGER, INTENT(IN) :: n
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    INTEGER :: istat

    ErrStat = CD_DYN_OK
    ErrMsg = ''
    IF (n < 0) THEN
      ErrStat = CD_DYN_BADINPUT
      ErrMsg = 'ensure_real_vector: negative workspace size'
      RETURN
    END IF
    IF (ALLOCATED(x)) THEN
      IF (SIZE(x) >= n) RETURN
      DEALLOCATE (x)
    END IF
    ALLOCATE (x(n), STAT=istat)
    IF (istat /= 0) THEN
      ErrStat = CD_DYN_BADINPUT
      ErrMsg = 'real-vector workspace allocation failed'
    END IF
  END SUBROUTINE ensure_real_vector

  SUBROUTINE ensure_real_matrix(x, nrow, ncol, ErrStat, ErrMsg)
    REAL(wp), ALLOCATABLE, INTENT(INOUT) :: x(:, :)
    INTEGER, INTENT(IN) :: nrow, ncol
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    INTEGER :: istat

    ErrStat = CD_DYN_OK
    ErrMsg = ''
    IF (nrow < 0 .OR. ncol < 0) THEN
      ErrStat = CD_DYN_BADINPUT
      ErrMsg = 'ensure_real_matrix: negative workspace shape'
      RETURN
    END IF
    IF (ALLOCATED(x)) THEN
      IF (SIZE(x, 1) >= nrow .AND. SIZE(x, 2) >= ncol) RETURN
      DEALLOCATE (x)
    END IF
    ALLOCATE (x(nrow, ncol), STAT=istat)
    IF (istat /= 0) THEN
      ErrStat = CD_DYN_BADINPUT
      ErrMsg = 'real-matrix workspace allocation failed'
    END IF
  END SUBROUTINE ensure_real_matrix

  SUBROUTINE record_stale_accept(work, iter)
    TYPE(CD_CosseratGenAlphaWorkspace), INTENT(INOUT) :: work
    INTEGER, INTENT(IN) :: iter
    INTEGER :: idx
    idx = MIN(MAX(iter, 0), CD_COSDYN_HIST_MAX)
    work%n_stale_accept = work%n_stale_accept + 1
    work%stale_accept_hist(idx) = work%stale_accept_hist(idx) + 1
  END SUBROUTINE record_stale_accept

  SUBROUTINE record_stale_reject(work, iter)
    TYPE(CD_CosseratGenAlphaWorkspace), INTENT(INOUT) :: work
    INTEGER, INTENT(IN) :: iter
    INTEGER :: idx
    idx = MIN(MAX(iter, 0), CD_COSDYN_HIST_MAX)
    work%n_stale_reject = work%n_stale_reject + 1
    work%stale_reject_hist(idx) = work%stale_reject_hist(idx) + 1
  END SUBROUTINE record_stale_reject

  PURE REAL(wp) FUNCTION infnorm(x)
    REAL(wp), INTENT(IN) :: x(:)
    IF (SIZE(x) == 0) THEN
      infnorm = CD_ZERO
    ELSE
      infnorm = MAXVAL(ABS(x))
    END IF
  END FUNCTION infnorm

  PURE LOGICAL FUNCTION pos_finite(x)
    REAL(wp), INTENT(IN) :: x
    pos_finite = CD_Is_Finite(x) .AND. x > CD_ZERO
  END FUNCTION pos_finite

  SUBROUTINE validate_mesh_rotation_state(q, elem_conn, ErrStat, ErrMsg)
    !! Validate the whole mesh state q against the SHARED element-domain rotation
    !! contract (CD_Cosserat_Validate_Rotation_State): for every element, both nodal
    !! rotation vectors must lie in the |theta| < pi chart AND their relative
    !! rotation must not be log-singular (near pi). This is the same contract the
    !! force / tangent / energy paths enforce, applied per element -- a chart-only
    !! check would miss the relative-rotation singularity that the gen-alpha alpha-
    !! blend can otherwise hide in q_eval. PRECONDITION: connectivity validated
    !! (elem_conn in range) and q finite -- both checked by the caller before here.
    REAL(wp), INTENT(IN) :: q(:)
    INTEGER, INTENT(IN) :: elem_conn(:, :)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    INTEGER :: e, a, b
    REAL(wp) :: qe(12)
    ErrStat = 0; ErrMsg = ''
    DO e = 1, SIZE(elem_conn, 2)
      a = elem_conn(1, e); b = elem_conn(2, e)
      qe(1:6) = q(6*a - 5:6*a)
      qe(7:12) = q(6*b - 5:6*b)
      CALL CD_Cosserat_Validate_Rotation_State(qe, ErrStat, ErrMsg)
      IF (ErrStat /= 0) RETURN
    END DO
  END SUBROUTINE validate_mesh_rotation_state

  SUBROUTINE reject_partial_rot(fixed_dofs, n_nodes, ErrStat, ErrMsg)
    !! Fail closed on a partial rotational triplet (1 or 2 of a node's 3 rotation
    !! DOFs fixed) -- the same finite-rotation subtlety as the static solver.
    INTEGER, INTENT(IN) :: fixed_dofs(:), n_nodes
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    INTEGER :: nd, base, cnt, k, d
    ErrStat = 0; ErrMsg = ''
    DO nd = 1, n_nodes
      base = 6*(nd - 1)
      cnt = 0
      DO k = 1, SIZE(fixed_dofs)
        d = fixed_dofs(k)
        IF (d == base + 4 .OR. d == base + 5 .OR. d == base + 6) cnt = cnt + 1
      END DO
      IF (cnt /= 0 .AND. cnt /= 3) THEN
        ErrStat = CD_DYN_BADINPUT
        ErrMsg = 'CD_Cosserat dynamics: partial rotational Dirichlet not supported -- fix all 3 or none'
        RETURN
      END IF
    END DO
  END SUBROUTINE reject_partial_rot

END MODULE CableDyn_CosseratDynamic
