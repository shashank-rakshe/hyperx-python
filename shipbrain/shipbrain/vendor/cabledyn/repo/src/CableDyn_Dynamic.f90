! File: src/CableDyn_Dynamic.f90
! SPDX-License-Identifier: Apache-2.0
! Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
MODULE CableDyn_Dynamic
  !! Generalized-alpha (Chung & Hulbert 1993) dynamics for the positions-only EI=0
  !! cable path. The core step advances the axial cable element with
  !! optional dynamic load callbacks, banded load Jacobians, configuration-dependent
  !! added mass, reusable workspaces, and prescribed support motion. It is the
  !! time-integration kernel used by the model, system, deck-driver, OpenFAST-facing,
  !! and C-facing lifecycle layers.
  !!
  !! One consistent-mass step advances (q_n, v_n, a_n) -> (q_{n+1}, v_{n+1}, a_{n+1})
  !! over dt by solving the force-blended residual (GenAlphaConfig%force_blend, default)
  !!   R(q) = M a_alpha + (1 - alpha_f) r(q_{n+1}, v_{n+1}) + alpha_f r(q_n, v_n) = 0,
  !!   r = f_int - f_ext - f_load,
  !! with a release cap on tension-only elements that release within the step (see
  !! apply_release_cap), or the configuration-blended R(q) = M a_alpha + f_int(q_alpha) - ...,
  !! for the Newton variable q = q_{n+1} with a Newton + Armijo line search on the
  !! 1/2||R||^2 merit. Optional callbacks add dynamic loads, force-only residual
  !! evaluations, added mass (at q_alpha either way), and prescribed support motion. The
  !! effective tangent is
  !!   (1 - alpha_m)/(beta dt^2) M + (1 - alpha_f) K_t(q_{n+1} or q_alpha),
  !! and the free-DOF block is assembled and solved directly in banded DGBSV
  !! storage when no arbitrary dense callback Jacobian is active.
  !!
  !! Conventions match the rest of the core: q/v/a are flat positions-only states
  !! (3 n_nodes), node nd owns DOFs 3*nd-2:3*nd, fixed_dofs are 1-based global DOF
  !! indices. f_ext is the constant part of the external load over the step; state- and
  !! time-dependent loads (hydrodynamics, damping, contact, friction, waves) enter through
  !! the load callbacks, which the host evaluates at t_alpha. Structural mass via
  !! CD_Assemble_Cable_Mass; tangent/internal force via CableDyn_Assemble.
  USE CableDyn_Precision, ONLY: wp, CD_ZERO, CD_ONE, CD_All_Finite, CD_Is_Finite
  USE CableDyn_Mesh, ONLY: CD_Validate_Connectivity
  USE CableDyn_Assemble, ONLY: CD_Assemble_Cable_Tangent_Force, &
                               CD_Assemble_Cable_Tangent_Force_Banded_Free, &
                               CD_Assemble_Cable_Internal_Force, CD_Assemble_Cable_Mass, &
                               CD_Cable_Free_Bandwidth
  USE CableDyn_Linalg, ONLY: CD_Factor_Banded, CD_Solve_Banded, CD_Solve_Dense_As_Banded, &
                             CD_Solve_Factored_Banded
  USE CableDyn_Profile, ONLY: CD_Profile_Kernel_Begin, CD_Profile_Kernel_End, CD_PROF_K_RESIDUAL, &
                              CD_PROF_K_TANGENT, CD_PROF_K_FACTOR, CD_PROF_K_SOLVE
  USE, INTRINSIC :: ISO_FORTRAN_ENV, ONLY: int64
  IMPLICIT NONE
  PRIVATE

  PUBLIC :: GenAlphaConfig
  PUBLIC :: CD_CableGenAlphaWorkspace
  PUBLIC :: CD_Clear_GenAlpha_Workspace
  PUBLIC :: CD_Cable_Gen_Alpha_Step
  PUBLIC :: CD_Cable_Initial_Acceleration
  PUBLIC :: CD_Cable_Dynamic_Load_Proc
  PUBLIC :: CD_Cable_Dynamic_Load_Banded_Proc
  PUBLIC :: CD_Cable_Dynamic_Force_Proc
  PUBLIC :: CD_Cable_Added_Mass_Proc
  PUBLIC :: CD_Cable_Added_Mass_Banded_Proc
  PUBLIC :: CD_Cable_Step_Loads

  TYPE :: GenAlphaConfig
    !! Generalized-alpha policy. The Chung-Hulbert parameters (alpha_m, alpha_f, beta, gamma) are derived from
    !! rho_inf (the high-frequency spectral radius / numerical-dissipation knob).
    REAL(wp) :: rho_inf = 0.8_wp                  !! spectral radius at infinity, in [0, 1]
    REAL(wp) :: rel_tol = 1.0e-8_wp               !! ||R||/scale gate
    REAL(wp) :: abs_tol = 1.0e-14_wp              !! absolute ||R|| gate / scale floor
    INTEGER  :: max_iter = 30
    REAL(wp) :: armijo_c1 = 1.0e-4_wp             !! sufficient-decrease constant
    INTEGER  :: armijo_max_backtracks = 12
    LOGICAL  :: modified_newton = .FALSE.         !! reuse first tangent within a step when enabled
    LOGICAL  :: emc_analytic_tangent = .FALSE.    !! EMC only: .TRUE. uses the closed-form consistent
                                                  !! Newton tangent instead of the dense FD Jacobian
                                                  !! (quadratic convergence; default FD is bit-for-bit).
    LOGICAL  :: emc_consistent_mass = .FALSE.     !! EMC only: .TRUE. uses the CONSISTENT translational
                                                  !! mass (matching CD_Cosserat_Mechanical_Energy) rather
                                                  !! than the lumped per-node mass, so the scheme conserves
                                                  !! the consistent-mass energy (velocity formulation).
                                                  !! Free-free lines only; combinable with
                                                  !! emc_analytic_tangent (banded closed-form tangent).
    LOGICAL  :: multiplicative_rotation = .FALSE. !! .TRUE. selects the multiplicative-SO(3) rotation
                                                  !! update (wraps Lambda + spatial gyroscopic
                                                  !! omega x J omega); .FALSE. = the additive small-
                                                  !! rotation update. Only the finite-EI rotational step
                                                  !! (CD_Cosserat_Gen_Alpha_Step) reads it; the EI=0 cable
                                                  !! path has no rotation DOFs. With .TRUE. the step fails
                                                  !! closed on moving supports and dynamic load callbacks.
    LOGICAL  :: force_blend = .TRUE.              !! EI=0 cable step only: .TRUE. blends the internal force
                                                  !! and the dynamic loads, (1 - alpha_f) r(q_{n+1}, v_{n+1})
                                                  !! + alpha_f r(q_n, v_n); .FALSE. evaluates them at the
                                                  !! blended configuration (q_alpha, v_alpha). The finite-EI
                                                  !! paths have their own setting.
    ! Rotation- and snap-resolved sub-stepping of an EI=0 line model (CD_Step_Model of
    ! CableDyn_Model; the kernel step here does not read these). With CD_EI0_SUBSTEPS_AUTO a
    ! converged step whose taut segments turned by more than ei0_substep_angle degrees, or in
    ! which a segment went from slack to taut with a large tension, is solved again from the
    ! same committed state in max(4, ceil(turn/ei0_substep_angle)) equal sub-steps, at most
    ! ei0_substep_max; CD_EI0_SUBSTEPS_OFF takes every step as given.
    INTEGER  :: ei0_substeps = 1                  !! CD_EI0_SUBSTEPS_AUTO (1) or CD_EI0_SUBSTEPS_OFF (0)
    REAL(wp) :: ei0_substep_angle = 1.0_wp        !! largest turn of a taut segment per step, deg, (0, 90]
    INTEGER  :: ei0_substep_max = 16              !! sub-step cap per step, [2, 1024]
  END TYPE GenAlphaConfig

  TYPE :: CD_CableGenAlphaWorkspace
    !! Reusable scratch for one EI=0 generalized-alpha stepper instance.
    !! Public so persistent model owners can allocate it once and pass it into
    !! CD_Cable_Gen_Alpha_Step; callers that omit it use a self-contained
    !! per-call allocation path.
    INTEGER :: n_dof_capacity = 0
    ! The previous step converged at its predictor (no Newton iteration): the next step
    ! first tests the predictor with a residual-only evaluation and builds the effective
    ! tangent only if Newton has to iterate. A performance hint, never state.
    LOGICAL :: resid_first = .FALSE.
    INTEGER :: n_elem_capacity = 0
    INTEGER :: n_fixed_capacity = 0
    INTEGER :: n_free_capacity = 0
    INTEGER :: ldab_capacity = 0
    INTEGER, ALLOCATABLE :: free(:)
    INTEGER, ALLOCATABLE :: fixed(:)
    INTEGER, ALLOCATABLE :: dof_marker(:)
    INTEGER, ALLOCATABLE :: ipiv(:)
    REAL(wp), ALLOCATABLE :: M(:, :)
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
    REAL(wp), ALLOCATABLE :: R_free(:)
    REAL(wp), ALLOCATABLE :: dq(:)
    REAL(wp), ALLOCATABLE :: a_eval(:)
    REAL(wp), ALLOCATABLE :: a_alpha(:)
    REAL(wp), ALLOCATABLE :: q_alpha(:)
    REAL(wp), ALLOCATABLE :: v_eval(:)
    REAL(wp), ALLOCATABLE :: v_alpha(:)
    REAL(wp), ALLOCATABLE :: fint_eval(:)
    REAL(wp), ALLOCATABLE :: tension_eval(:)
    REAL(wp), ALLOCATABLE :: load_eval(:)
    ! force blend (GenAlphaConfig%force_blend): the configuration the internal force and the
    ! dynamic loads are evaluated at (q_{n+1}), and the step-start internal force and dynamic
    ! load (at q_n, v_n) that enter the blend with weight alpha_f
    REAL(wp), ALLOCATABLE :: q_force(:)
    REAL(wp), ALLOCATABLE :: fint_n(:)
    REAL(wp), ALLOCATABLE :: load_n(:)
    ! release cap of the force blend (tension-only elements): the step-start tension, stretch
    ! l - l0 and unit chord of every element, and the bound of its secant stiffness
    ! (start_stiffness of a law element, HUGE otherwise)
    REAL(wp), ALLOCATABLE :: tension_n(:), stretch_n(:), chord_n(:, :), stiff_n(:)
    ! the axial dashpot of an elastic element (axial_damping): BA/l0, the payout rate l0_dot/l0
    ! and the dashpot tension at the step start, zero without one
    REAL(wp), ALLOCATABLE :: dcoef_n(:), rl0dot_n(:), damp_n(:)
    ! fint_n, load_n and the release-cap data hold the step-start values of the last call: a
    ! warm re-solve of the same step (guess_armed, from the same committed state) reuses them
    LOGICAL :: start_valid = .FALSE.
    REAL(wp), ALLOCATABLE :: eff(:, :)
    REAL(wp), ALLOCATABLE :: eff_free(:, :)
    REAL(wp), ALLOCATABLE :: Kt_eval(:, :)
    REAL(wp), ALLOCATABLE :: jac_q_eval(:, :)
    REAL(wp), ALLOCATABLE :: jac_v_eval(:, :)
    REAL(wp), ALLOCATABLE :: M_eff_eval(:, :)
    REAL(wp), ALLOCATABLE :: M_add_eval(:, :)
    REAL(wp), ALLOCATABLE :: dMa_a_dq_eval(:, :)
    REAL(wp), ALLOCATABLE :: M_add_a_eval(:)
    REAL(wp), ALLOCATABLE :: M_band(:, :)
    REAL(wp), ALLOCATABLE :: M_add_band(:, :)
    REAL(wp), ALLOCATABLE :: dMa_a_dq_band(:, :)
    REAL(wp), ALLOCATABLE :: Kt_band(:, :)
    REAL(wp), ALLOCATABLE :: eff_band(:, :)
    REAL(wp), ALLOCATABLE :: eff_band_unfactored(:, :)
    REAL(wp), ALLOCATABLE :: jq_band(:, :)
    REAL(wp), ALLOCATABLE :: jv_band(:, :)
    ! Coupled acceleration-derivative cache (CD_Calc_Model_CoupledAccelDerivative): the
    ! structural and added mass in full-order band storage, the factored free/free band
    ! block, the condensation right-hand sides and the result, keyed by the inputs the mass
    ! depends on (positions when added mass is on, unstretched lengths, mass per length and
    ! the fixed-DOF set). Cleared with the workspace, so a re-initialised model starts cold.
    LOGICAL :: ad_valid = .FALSE.
    ! Connectivity already validated for this workspace (a copy of elem_conn and its node
    ! count) and the free-DOF bandwidth computed for the free list bw_free; the per-step
    ! assembly then skips the connectivity validation and the bandwidth analysis.
    INTEGER, ALLOCATABLE :: topo_conn(:, :), bw_free(:)
    ! (3, n_nodes) nodal copy of a model state for assembly calls outside the step
    REAL(wp), ALLOCATABLE :: nodes_eval(:, :)
    INTEGER :: topo_n_nodes = 0, bw_kl = 0, bw_ku = 0
    LOGICAL :: topo_valid = .FALSE., bw_valid = .FALSE.
    ! M_band holds the element consistent mass band assembled for the remembered connectivity
    ! and free list (bw_free) from the lengths mb_l0 and masses per length mb_rho; a step whose
    ! inputs match reuses it instead of assembling the same band again. Every other writer of
    ! M_band clears mb_valid.
    LOGICAL :: mb_valid = .FALSE.
    REAL(wp), ALLOCATABLE :: mb_l0(:), mb_rho(:)
    ! TEST-ONLY diagnostic: the number of steps that reused the remembered mass band (saturating).
    ! Only the unit tests read it (to assert that the cache hit); no result depends on it.
    INTEGER :: mb_hits = 0
    INTEGER :: ad_kl = 0
    INTEGER, ALLOCATABLE :: ad_finv(:), ad_ipiv(:), ad_fixed(:)
    REAL(wp), ALLOCATABLE :: ad_full(:, :), ad_add(:, :), ad_ab(:, :), ad_x(:, :), ad_result(:, :)
    REAL(wp), ALLOCATABLE :: ad_q(:), ad_l0(:), ad_rho(:)
    ! Junction query of the monolithic body/point coupling (armed per call by the owner, see
    ! CD_Cable_Gen_Alpha_Step): end_request asks a converged step for the alpha-level
    ! reaction rows end_r = R(fixed) at the converged iterate and the condensed dynamic end
    ! tangent end_k = dR_E/dq_E with the free DOFs eliminated (S_EE - S_EF S_FF^-1 S_FE),
    ! for the fixed DOFs flagged in end_active (all when unallocated); end_x = S_FF^-1 S_FE
    ! and q_last keep the linear map that warm-starts the next solve of the same step
    ! (guess_armed). end_valid reports that end_r/end_k describe the last converged call.
    LOGICAL :: end_request = .FALSE.
    ! end_refresh: recompute the condensed tangent even when a valid one of an earlier solve
    ! exists (otherwise that one is kept: the outer Newton tolerates a slightly stale tangent)
    LOGICAL :: end_refresh = .TRUE.
    LOGICAL :: guess_armed = .FALSE.
    LOGICAL :: end_valid = .FALSE.
    ! the factored effective band in eff_band/ipiv belongs to the current step (a junction solve
    ! of this step factored it): a warm re-solve of the same step starts with a chord iteration
    ! on it instead of assembling and factoring a new tangent. Cleared whenever eff_band is
    ! overwritten by a tangent that is not factored.
    LOGICAL :: step_factor = .FALSE.
    ! force scale of the junction solves (largest element tension of the last one): the
    ! residual gate of a warm-started junction solve is relative to it, not to its own
    ! (already small) initial residual
    REAL(wp) :: end_scale = 0.0_wp
    ! end_levels: the prescribed (junction) DOFs follow the objects' own Newmark (end_beta,
    ! end_gamma) and carry their inertia at the objects' alpha_m level (end_alpham), so the
    ! end-node inertia enters the junction equation at the level of the objects' true
    ! accelerations; otherwise they follow the line's parameters
    LOGICAL :: end_levels = .FALSE.
    REAL(wp) :: end_beta = 0.25_wp, end_gamma = 0.5_wp, end_alpham = 0.0_wp
    ! end_level_dofs: the fixed DOFs (model%fixed_dofs order) that take the object levels
    ! (all when unallocated)
    LOGICAL, ALLOCATABLE :: end_level_dofs(:)
    LOGICAL, ALLOCATABLE :: end_active(:)
    REAL(wp), ALLOCATABLE :: end_r(:), end_k(:, :), end_x(:, :), q_last(:)
  END TYPE CD_CableGenAlphaWorkspace

  ! ErrStat codes: 0 success; 1 invalid input; 2 singular/ill-conditioned tangent;
  ! 3 allocation failure (own workspace or propagated from a load/added-mass callback).
  INTEGER, PARAMETER, PUBLIC :: CD_DYN_OK = 0
  INTEGER, PARAMETER, PUBLIC :: CD_DYN_BADINPUT = 1
  INTEGER, PARAMETER, PUBLIC :: CD_DYN_SINGULAR = 2
  INTEGER, PARAMETER, PUBLIC :: CD_DYN_ALLOCFAIL = 3
  ! GenAlphaConfig%ei0_substeps
  INTEGER, PARAMETER, PUBLIC :: CD_EI0_SUBSTEPS_OFF = 0
  INTEGER, PARAMETER, PUBLIC :: CD_EI0_SUBSTEPS_AUTO = 1

  ABSTRACT INTERFACE
    SUBROUTINE CD_Cable_Dynamic_Load_Proc(q, v, force, jac_q, jac_v, ErrStat, ErrMsg)
      !! Dynamic external load callback for the positions-only EI=0 cable path.
      !! `force` is the load to subtract from the residual as `R = ... - force`;
      !! `jac_q` and `jac_v` are residual-Jacobian contributions, i.e.
      !! `-d(force)/dq` and `-d(force)/dv`.
      IMPORT :: wp
      REAL(wp), INTENT(IN) :: q(:), v(:)
      REAL(wp), INTENT(OUT) :: force(:), jac_q(:, :), jac_v(:, :)
      INTEGER, INTENT(OUT) :: ErrStat
      CHARACTER(*), INTENT(OUT) :: ErrMsg
    END SUBROUTINE CD_Cable_Dynamic_Load_Proc

    SUBROUTINE CD_Cable_Dynamic_Load_Banded_Proc(q, v, free, kl, ku, force, jac_q_band, jac_v_band, ErrStat, ErrMsg)
      !! Dynamic external load callback for production banded Newton solves.
      !! `force` is full-sized. `jac_q_band` and `jac_v_band` are the reduced
      !! free/free residual-Jacobian contributions in LAPACK general-band storage
      !! using the supplied free-DOF ordering and bandwidth.
      IMPORT :: wp
      REAL(wp), INTENT(IN) :: q(:), v(:)
      INTEGER, INTENT(IN) :: free(:), kl, ku
      REAL(wp), INTENT(OUT) :: force(:), jac_q_band(:, :), jac_v_band(:, :)
      INTEGER, INTENT(OUT) :: ErrStat
      CHARACTER(*), INTENT(OUT) :: ErrMsg
    END SUBROUTINE CD_Cable_Dynamic_Load_Banded_Proc

    SUBROUTINE CD_Cable_Dynamic_Force_Proc(q, v, force, ErrStat, ErrMsg)
      !! Force-only dynamic external load callback for residual-only evaluations.
      !! It must return the same force vector as CD_Cable_Dynamic_Load_Proc, without
      !! Jacobian work. Full tangent evaluations still use the Jacobian callback.
      IMPORT :: wp
      REAL(wp), INTENT(IN) :: q(:), v(:)
      REAL(wp), INTENT(OUT) :: force(:)
      INTEGER, INTENT(OUT) :: ErrStat
      CHARACTER(*), INTENT(OUT) :: ErrMsg
    END SUBROUTINE CD_Cable_Dynamic_Force_Proc

    SUBROUTINE CD_Cable_Added_Mass_Proc(q, accel, M_add, dMa_a_dq, ErrStat, ErrMsg)
      !! Configuration-dependent Morison added-mass callback for the EI=0 cable
      !! path. `M_add` augments the structural mass, and `dMa_a_dq` is the
      !! derivative d(M_add(q) * accel)/dq for the supplied acceleration vector.
      IMPORT :: wp
      REAL(wp), INTENT(IN) :: q(:), accel(:)
      REAL(wp), INTENT(OUT) :: M_add(:, :), dMa_a_dq(:, :)
      INTEGER, INTENT(OUT) :: ErrStat
      CHARACTER(*), INTENT(OUT) :: ErrMsg
    END SUBROUTINE CD_Cable_Added_Mass_Proc

    SUBROUTINE CD_Cable_Added_Mass_Banded_Proc(q, accel, free, kl, ku, M_add_a, M_add_band, dMa_a_dq_band, &
                                               ErrStat, ErrMsg, need_tangent)
      !! Banded added-mass callback for production Newton solves. `M_add_a`
      !! is the full-sized product M_add(q)*accel. `M_add_band` and
      !! `dMa_a_dq_band` are reduced free/free LAPACK general-band matrices.
      IMPORT :: wp
      REAL(wp), INTENT(IN) :: q(:), accel(:)
      INTEGER, INTENT(IN) :: free(:), kl, ku
      REAL(wp), INTENT(OUT) :: M_add_a(:), M_add_band(:, :), dMa_a_dq_band(:, :)
      INTEGER, INTENT(OUT) :: ErrStat
      CHARACTER(*), INTENT(OUT) :: ErrMsg
      LOGICAL, INTENT(IN), OPTIONAL :: need_tangent
    END SUBROUTINE CD_Cable_Added_Mass_Banded_Proc
  END INTERFACE

  !> The banded dynamic loads of a step as an object (the `loads` argument of
  !> CD_Cable_Gen_Alpha_Step and CD_Cable_Initial_Acceleration), for a caller whose loads are
  !> computed from its own data, such as a line model: an extension carries that data as
  !> components. Such a caller does not pass internal procedures as the callbacks: an internal
  !> procedure passed as an argument is a closure over its host's frame, which Intel ifx
  !> (2025.3, Windows) calls through a trampoline kept in memory every thread shares, so two
  !> threads stepping distinct models through closures corrupt each other's calls.
  !> has_force: the object gives the force and the banded load (load_force_proc and
  !> load_band_proc); has_added_mass: the banded added mass (added_mass_band_proc).
  TYPE, ABSTRACT :: CD_Cable_Step_Loads
    LOGICAL :: has_force = .FALSE.
    LOGICAL :: has_added_mass = .FALSE.
  CONTAINS
    PROCEDURE(step_loads_force), DEFERRED :: force
    PROCEDURE(step_loads_load_banded), DEFERRED :: load_banded
    PROCEDURE(step_loads_added_mass_banded), DEFERRED :: added_mass_banded
  END TYPE CD_Cable_Step_Loads

  ABSTRACT INTERFACE
    SUBROUTINE step_loads_force(self, q, v, force, ErrStat, ErrMsg)
      !! CD_Cable_Dynamic_Force_Proc of the object.
      IMPORT :: wp, CD_Cable_Step_Loads
      CLASS(CD_Cable_Step_Loads), INTENT(INOUT) :: self
      REAL(wp), INTENT(IN) :: q(:), v(:)
      REAL(wp), INTENT(OUT) :: force(:)
      INTEGER, INTENT(OUT) :: ErrStat
      CHARACTER(*), INTENT(OUT) :: ErrMsg
    END SUBROUTINE step_loads_force

    SUBROUTINE step_loads_load_banded(self, q, v, free, kl, ku, force, jac_q_band, jac_v_band, ErrStat, ErrMsg)
      !! CD_Cable_Dynamic_Load_Banded_Proc of the object.
      IMPORT :: wp, CD_Cable_Step_Loads
      CLASS(CD_Cable_Step_Loads), INTENT(INOUT) :: self
      REAL(wp), INTENT(IN) :: q(:), v(:)
      INTEGER, INTENT(IN) :: free(:), kl, ku
      REAL(wp), INTENT(OUT) :: force(:), jac_q_band(:, :), jac_v_band(:, :)
      INTEGER, INTENT(OUT) :: ErrStat
      CHARACTER(*), INTENT(OUT) :: ErrMsg
    END SUBROUTINE step_loads_load_banded

    SUBROUTINE step_loads_added_mass_banded(self, q, accel, free, kl, ku, M_add_a, M_add_band, dMa_a_dq_band, &
                                            ErrStat, ErrMsg, need_tangent)
      !! CD_Cable_Added_Mass_Banded_Proc of the object.
      IMPORT :: wp, CD_Cable_Step_Loads
      CLASS(CD_Cable_Step_Loads), INTENT(INOUT) :: self
      REAL(wp), INTENT(IN) :: q(:), accel(:)
      INTEGER, INTENT(IN) :: free(:), kl, ku
      REAL(wp), INTENT(OUT) :: M_add_a(:), M_add_band(:, :), dMa_a_dq_band(:, :)
      INTEGER, INTENT(OUT) :: ErrStat
      CHARACTER(*), INTENT(OUT) :: ErrMsg
      LOGICAL, INTENT(IN), OPTIONAL :: need_tangent
    END SUBROUTINE step_loads_added_mass_banded
  END INTERFACE

CONTAINS

  SUBROUTINE CD_Clear_GenAlpha_Workspace(work)
    !! Release all allocatable scratch owned by a reusable EI=0 dynamic workspace.
    TYPE(CD_CableGenAlphaWorkspace), INTENT(INOUT) :: work

    IF (ALLOCATED(work%free)) DEALLOCATE (work%free)
    IF (ALLOCATED(work%fixed)) DEALLOCATE (work%fixed)
    IF (ALLOCATED(work%dof_marker)) DEALLOCATE (work%dof_marker)
    IF (ALLOCATED(work%ipiv)) DEALLOCATE (work%ipiv)
    IF (ALLOCATED(work%M)) DEALLOCATE (work%M)
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
    IF (ALLOCATED(work%R_free)) DEALLOCATE (work%R_free)
    IF (ALLOCATED(work%dq)) DEALLOCATE (work%dq)
    IF (ALLOCATED(work%a_eval)) DEALLOCATE (work%a_eval)
    IF (ALLOCATED(work%a_alpha)) DEALLOCATE (work%a_alpha)
    IF (ALLOCATED(work%q_alpha)) DEALLOCATE (work%q_alpha)
    IF (ALLOCATED(work%v_eval)) DEALLOCATE (work%v_eval)
    IF (ALLOCATED(work%v_alpha)) DEALLOCATE (work%v_alpha)
    IF (ALLOCATED(work%fint_eval)) DEALLOCATE (work%fint_eval)
    IF (ALLOCATED(work%tension_eval)) DEALLOCATE (work%tension_eval)
    IF (ALLOCATED(work%load_eval)) DEALLOCATE (work%load_eval)
    IF (ALLOCATED(work%q_force)) DEALLOCATE (work%q_force)
    IF (ALLOCATED(work%fint_n)) DEALLOCATE (work%fint_n)
    IF (ALLOCATED(work%load_n)) DEALLOCATE (work%load_n)
    IF (ALLOCATED(work%tension_n)) DEALLOCATE (work%tension_n)
    IF (ALLOCATED(work%stretch_n)) DEALLOCATE (work%stretch_n)
    IF (ALLOCATED(work%chord_n)) DEALLOCATE (work%chord_n)
    IF (ALLOCATED(work%stiff_n)) DEALLOCATE (work%stiff_n)
    IF (ALLOCATED(work%dcoef_n)) DEALLOCATE (work%dcoef_n)
    IF (ALLOCATED(work%rl0dot_n)) DEALLOCATE (work%rl0dot_n)
    IF (ALLOCATED(work%damp_n)) DEALLOCATE (work%damp_n)
    work%start_valid = .FALSE.
    IF (ALLOCATED(work%eff)) DEALLOCATE (work%eff)
    IF (ALLOCATED(work%eff_free)) DEALLOCATE (work%eff_free)
    IF (ALLOCATED(work%Kt_eval)) DEALLOCATE (work%Kt_eval)
    IF (ALLOCATED(work%jac_q_eval)) DEALLOCATE (work%jac_q_eval)
    IF (ALLOCATED(work%jac_v_eval)) DEALLOCATE (work%jac_v_eval)
    IF (ALLOCATED(work%M_eff_eval)) DEALLOCATE (work%M_eff_eval)
    IF (ALLOCATED(work%M_add_eval)) DEALLOCATE (work%M_add_eval)
    IF (ALLOCATED(work%dMa_a_dq_eval)) DEALLOCATE (work%dMa_a_dq_eval)
    IF (ALLOCATED(work%M_add_a_eval)) DEALLOCATE (work%M_add_a_eval)
    IF (ALLOCATED(work%M_band)) DEALLOCATE (work%M_band)
    IF (ALLOCATED(work%M_add_band)) DEALLOCATE (work%M_add_band)
    IF (ALLOCATED(work%dMa_a_dq_band)) DEALLOCATE (work%dMa_a_dq_band)
    IF (ALLOCATED(work%Kt_band)) DEALLOCATE (work%Kt_band)
    IF (ALLOCATED(work%eff_band)) DEALLOCATE (work%eff_band)
    IF (ALLOCATED(work%eff_band_unfactored)) DEALLOCATE (work%eff_band_unfactored)
    IF (ALLOCATED(work%jq_band)) DEALLOCATE (work%jq_band)
    IF (ALLOCATED(work%jv_band)) DEALLOCATE (work%jv_band)
    work%ad_valid = .FALSE.
    work%ad_kl = 0
    IF (ALLOCATED(work%topo_conn)) DEALLOCATE (work%topo_conn)
    IF (ALLOCATED(work%nodes_eval)) DEALLOCATE (work%nodes_eval)
    IF (ALLOCATED(work%bw_free)) DEALLOCATE (work%bw_free)
    work%topo_n_nodes = 0
    work%bw_kl = 0
    work%bw_ku = 0
    work%topo_valid = .FALSE.
    work%bw_valid = .FALSE.
    work%mb_valid = .FALSE.
    work%mb_hits = 0
    IF (ALLOCATED(work%mb_l0)) DEALLOCATE (work%mb_l0)
    IF (ALLOCATED(work%mb_rho)) DEALLOCATE (work%mb_rho)
    IF (ALLOCATED(work%ad_finv)) DEALLOCATE (work%ad_finv)
    IF (ALLOCATED(work%ad_ipiv)) DEALLOCATE (work%ad_ipiv)
    IF (ALLOCATED(work%ad_fixed)) DEALLOCATE (work%ad_fixed)
    IF (ALLOCATED(work%ad_full)) DEALLOCATE (work%ad_full)
    IF (ALLOCATED(work%ad_add)) DEALLOCATE (work%ad_add)
    IF (ALLOCATED(work%ad_ab)) DEALLOCATE (work%ad_ab)
    IF (ALLOCATED(work%ad_x)) DEALLOCATE (work%ad_x)
    IF (ALLOCATED(work%ad_result)) DEALLOCATE (work%ad_result)
    IF (ALLOCATED(work%ad_q)) DEALLOCATE (work%ad_q)
    IF (ALLOCATED(work%ad_l0)) DEALLOCATE (work%ad_l0)
    IF (ALLOCATED(work%ad_rho)) DEALLOCATE (work%ad_rho)
    IF (ALLOCATED(work%end_active)) DEALLOCATE (work%end_active)
    IF (ALLOCATED(work%end_level_dofs)) DEALLOCATE (work%end_level_dofs)
    IF (ALLOCATED(work%end_r)) DEALLOCATE (work%end_r)
    IF (ALLOCATED(work%end_k)) DEALLOCATE (work%end_k)
    IF (ALLOCATED(work%end_x)) DEALLOCATE (work%end_x)
    IF (ALLOCATED(work%q_last)) DEALLOCATE (work%q_last)
    work%end_request = .FALSE.
    work%end_levels = .FALSE.
    work%guess_armed = .FALSE.
    work%end_valid = .FALSE.
    work%step_factor = .FALSE.
    work%end_scale = 0.0_wp
    work%n_dof_capacity = 0
    work%n_elem_capacity = 0
    work%n_fixed_capacity = 0
    work%n_free_capacity = 0
    work%ldab_capacity = 0
  END SUBROUTINE CD_Clear_GenAlpha_Workspace

  SUBROUTINE CD_Cable_Initial_Acceleration(q, v, elem_conn, l0, ea, rho_a, tension_only, &
                                           f_ext, fixed_dofs, a0, ErrStat, ErrMsg, &
                                           load_proc, added_mass_proc, load_force_proc, structural_mass, workspace, &
                                           added_mass_band_proc, loads)
    !! Consistent-mass initial acceleration: solve M a = f_ext - f_int(q) on the free
    !! DOFs (fixed DOFs get a = 0), without load callbacks. Gives the caller a
    !! consistent a_n to seed CD_Cable_Gen_Alpha_Step; ``v`` is accepted for
    !! signature parity with the loaded case but does not enter the structural solve.
    !! loads (CD_Cable_Step_Loads) stands for load_force_proc (has_force) and
    !! added_mass_band_proc (has_added_mass), which are then not passed.
    REAL(wp), INTENT(IN)  :: q(:), v(:)
    INTEGER, INTENT(IN)  :: elem_conn(:, :)
    REAL(wp), INTENT(IN)  :: l0(:), ea(:), rho_a(:)
    LOGICAL, INTENT(IN)  :: tension_only
    REAL(wp), INTENT(IN)  :: f_ext(:)
    INTEGER, INTENT(IN)  :: fixed_dofs(:)
    REAL(wp), INTENT(OUT) :: a0(:)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    PROCEDURE(CD_Cable_Dynamic_Load_Proc), OPTIONAL :: load_proc
    PROCEDURE(CD_Cable_Added_Mass_Proc), OPTIONAL :: added_mass_proc
    PROCEDURE(CD_Cable_Dynamic_Force_Proc), OPTIONAL :: load_force_proc
    PROCEDURE(CD_Cable_Added_Mass_Banded_Proc), OPTIONAL :: added_mass_band_proc
    REAL(wp), INTENT(IN), OPTIONAL :: structural_mass(:, :)
    TYPE(CD_CableGenAlphaWorkspace), INTENT(INOUT), TARGET, OPTIONAL :: workspace
    CLASS(CD_Cable_Step_Loads), INTENT(INOUT), OPTIONAL :: loads

    INTEGER  :: n_dof, n_elem, n_free, kl, ku, ldab
    INTEGER, POINTER :: free(:)
    REAL(wp), POINTER :: M(:, :), fint(:), M_band(:, :), rhs(:), load(:), jac_q(:, :), jac_v(:, :)
    REAL(wp), POINTER :: M_add(:, :), dMa_a_dq(:, :), zero_accel(:), M_add_a(:), M_add_band(:, :), dMa_band(:, :)
    TYPE(CD_CableGenAlphaWorkspace), TARGET :: local_workspace
    TYPE(CD_CableGenAlphaWorkspace), POINTER :: work
    INTEGER  :: es
    CHARACTER(1024) :: em
    LOGICAL :: use_element_mass_band
    ! the force and the banded added mass: from a callback, or from loads (loads_force, loads_mass)
    LOGICAL :: has_force, has_mass_band, loads_force, loads_mass

    a0 = CD_ZERO
    ErrStat = CD_DYN_OK
    ErrMsg = ''
    loads_force = .FALSE.
    loads_mass = .FALSE.
    IF (PRESENT(loads)) THEN
      loads_force = loads%has_force
      loads_mass = loads%has_added_mass
    END IF
    IF ((loads_force .AND. (PRESENT(load_proc) .OR. PRESENT(load_force_proc))) .OR. &
        (loads_mass .AND. (PRESENT(added_mass_proc) .OR. PRESENT(added_mass_band_proc)))) THEN
      CALL fail(ErrStat, ErrMsg, 'pass a load either as a callback or in loads, not both')
      RETURN
    END IF
    has_force = PRESENT(load_force_proc) .OR. loads_force
    has_mass_band = PRESENT(added_mass_band_proc) .OR. loads_mass
    n_dof = SIZE(q)
    CALL check_state_shapes(n_dof, [SIZE(v), SIZE(a0), SIZE(f_ext)], ErrStat, ErrMsg)
    IF (ErrStat /= 0) RETURN
    IF (.NOT. CD_All_Finite(q) .OR. .NOT. CD_All_Finite(v) &
        .OR. .NOT. CD_All_Finite(f_ext)) THEN
      CALL fail(ErrStat, ErrMsg, 'q, v, f_ext must be finite')
      RETURN
    END IF
    n_elem = SIZE(elem_conn, 2)
    IF (PRESENT(workspace)) THEN
      work => workspace
    ELSE
      work => local_workspace
    END IF
    CALL ensure_dof_workspace(work, n_dof, SIZE(fixed_dofs), ErrStat, ErrMsg)
    IF (ErrStat /= 0) RETURN
    CALL partition_free_dofs_workspace(fixed_dofs, n_dof, work%free, n_free, work%fixed, &
                                       work%dof_marker, ErrStat, ErrMsg)
    IF (ErrStat /= 0) RETURN
    free => work%free(1:n_free)
    IF (PRESENT(added_mass_proc) .AND. has_mass_band) THEN
      CALL fail(ErrStat, ErrMsg, 'pass either added_mass_proc or added_mass_band_proc, not both')
      RETURN
    END IF
    ! Banded added mass requires the banded path; a dense load_proc is incompatible
    ! (mirrors CD_Cable_Gen_Alpha_Step). Keep validation consistent across both entry
    ! points so a banded callback is never mixed with a dense one.
    IF (has_mass_band .AND. PRESENT(load_proc)) THEN
      CALL fail(ErrStat, ErrMsg, 'added_mass_band_proc cannot be mixed with a dense load_proc; use one path')
      RETURN
    END IF
    use_element_mass_band = .NOT. PRESENT(structural_mass) .AND. .NOT. PRESENT(added_mass_proc)
    IF (PRESENT(added_mass_proc)) THEN
      kl = 0
      ku = 0
      ldab = 0
    ELSE
      CALL CD_Cable_Free_Bandwidth(elem_conn, n_dof/3, free, kl, ku, es, em)
      IF (es /= 0) THEN
        CALL fail(ErrStat, ErrMsg, 'bandwidth analysis failed: '//TRIM(em))
        RETURN
      END IF
      ldab = 2*kl + ku + 1
    END IF
    CALL ensure_step_workspace(work, n_dof, n_elem, n_free, ldab,.NOT. PRESENT(added_mass_proc), .FALSE., &
                               PRESENT(load_proc) .OR. PRESENT(added_mass_proc),.NOT. use_element_mass_band, &
                               ErrStat, ErrMsg)
    IF (ErrStat /= 0) RETURN
    ! The dense global mass exists only for a supplied structural mass or a dense added-mass
    ! callback; the element-band path never forms it.
    IF (.NOT. use_element_mass_band) M => work%M(1:n_dof, 1:n_dof)
    fint => work%fint_eval(1:n_dof)
    rhs => work%R_free(1:n_free)
    load => work%load_eval(1:n_dof)
    zero_accel => work%a_eval(1:n_dof)
    IF (PRESENT(load_proc) .OR. PRESENT(added_mass_proc)) THEN
      jac_q => work%jac_q_eval(1:n_dof, 1:n_dof)
      jac_v => work%jac_v_eval(1:n_dof, 1:n_dof)
    END IF
    IF (PRESENT(added_mass_proc)) THEN
      M_add => work%M_add_eval(1:n_dof, 1:n_dof)
      dMa_a_dq => work%dMa_a_dq_eval(1:n_dof, 1:n_dof)
    END IF
    IF (has_mass_band) THEN
      M_add_a => work%M_add_a_eval(1:n_dof)
      M_add_band => work%M_add_band(1:ldab, 1:n_free)
      dMa_band => work%dMa_a_dq_band(1:ldab, 1:n_free)
    END IF
    IF (.NOT. PRESENT(added_mass_proc)) THEN
      M_band => work%M_band(1:ldab, 1:n_free)
    END IF

    IF (PRESENT(structural_mass)) THEN
      IF (SIZE(structural_mass, 1) /= n_dof .OR. SIZE(structural_mass, 2) /= n_dof) THEN
        CALL fail(ErrStat, ErrMsg, 'structural_mass must have shape (n_dof,n_dof)')
        RETURN
      END IF
      IF (.NOT. CD_All_Finite(structural_mass)) THEN
        CALL fail(ErrStat, ErrMsg, 'structural_mass must be finite')
        RETURN
      END IF
      M = structural_mass
    ELSE IF (.NOT. use_element_mass_band) THEN
      CALL CD_Assemble_Cable_Mass(elem_conn, l0, rho_a, M, es, em)
      IF (es /= 0) THEN
        CALL fail(ErrStat, ErrMsg, 'mass assembly failed: '//TRIM(em))
        RETURN
      END IF
    END IF
    CALL CD_Assemble_Cable_Internal_Force(reshape3(q, n_dof), elem_conn, l0, ea, tension_only, &
                                          fint, es, em)
    IF (es /= 0) THEN
      CALL fail(ErrStat, ErrMsg, 'internal-force assembly failed: '//TRIM(em))
      RETURN
    END IF
    IF (has_force) THEN
      IF (loads_force) THEN
        CALL loads%force(q, v, load, es, em)
      ELSE
        CALL load_force_proc(q, v, load, es, em)
      END IF
      IF (es /= 0) THEN
        CALL fail_callback(ErrStat, ErrMsg, 'dynamic force load failed: '//TRIM(em), es)
        RETURN
      END IF
      IF (.NOT. CD_All_Finite(load)) THEN
        CALL fail(ErrStat, ErrMsg, 'dynamic force load returned non-finite force')
        RETURN
      END IF
    ELSE IF (PRESENT(load_proc)) THEN
      CALL load_proc(q, v, load, jac_q, jac_v, es, em)
      IF (es /= 0) THEN
        CALL fail_callback(ErrStat, ErrMsg, 'dynamic load failed: '//TRIM(em), es)
        RETURN
      END IF
      IF (.NOT. CD_All_Finite(load) .OR. .NOT. CD_All_Finite(jac_q) &
          .OR. .NOT. CD_All_Finite(jac_v)) THEN
        CALL fail(ErrStat, ErrMsg, 'dynamic load returned non-finite force/Jacobian')
        RETURN
      END IF
    ELSE
      load = CD_ZERO
    END IF
    IF (PRESENT(added_mass_proc)) THEN
      zero_accel = CD_ZERO
      CALL added_mass_proc(q, zero_accel, M_add, dMa_a_dq, es, em)
      IF (es /= 0) THEN
        CALL fail_callback(ErrStat, ErrMsg, 'added mass failed: '//TRIM(em), es)
        RETURN
      END IF
      IF (.NOT. CD_All_Finite(M_add) .OR. .NOT. CD_All_Finite(dMa_a_dq)) THEN
        CALL fail(ErrStat, ErrMsg, 'added mass returned non-finite matrix/Jacobian')
        RETURN
      END IF
      M = M + M_add
    ELSE IF (has_mass_band) THEN
      zero_accel = CD_ZERO
      IF (loads_mass) THEN
        CALL loads%added_mass_banded(q, zero_accel, free, kl, ku, M_add_a, M_add_band, dMa_band, es, em, &
                                     need_tangent=.TRUE.)
      ELSE
        CALL added_mass_band_proc(q, zero_accel, free, kl, ku, M_add_a, M_add_band, dMa_band, es, em, &
                                  need_tangent=.TRUE.)
      END IF
      IF (es /= 0) THEN
        CALL fail_callback(ErrStat, ErrMsg, 'banded added mass failed: '//TRIM(em), es)
        RETURN
      END IF
      IF (.NOT. CD_All_Finite(M_add_a) .OR. .NOT. CD_All_Finite(M_add_band) .OR. &
          .NOT. CD_All_Finite(dMa_band)) THEN
        CALL fail(ErrStat, ErrMsg, 'banded added mass returned non-finite matrix/Jacobian')
        RETURN
      END IF
    END IF
    IF (n_free == 0) RETURN   ! every DOF prescribed -> a = 0 everywhere

    rhs = f_ext(free) + load(free) - fint(free)
    IF (PRESENT(added_mass_proc)) THEN
      CALL CD_Solve_Dense_As_Banded(M(free, free), rhs, es, em)
    ELSE
      IF (PRESENT(structural_mass)) THEN
        CALL validate_reduced_band_support(M, free, kl, ku, es, em)
        IF (es /= 0) THEN
          CALL fail(ErrStat, ErrMsg, 'structural_mass is not representable in the connectivity band: '//TRIM(em))
          RETURN
        END IF
      END IF
      ! the band is factored in place below: not the step's reusable mass band
      work%mb_valid = .FALSE.
      IF (use_element_mass_band) THEN
        CALL assemble_mass_band_free(elem_conn, l0, rho_a, work%dof_marker(1:n_dof), kl, ku, M_band, es, em)
      ELSE
        CALL pack_dense_free_band(M, free, kl, ku, CD_ONE, M_band, es, em)
      END IF
      IF (es /= 0) THEN
        CALL fail(ErrStat, ErrMsg, 'mass band packing failed: '//TRIM(em))
        RETURN
      END IF
      IF (has_mass_band) M_band = M_band + M_add_band
      CALL CD_Solve_Banded(M_band, kl, ku, rhs, es, em)
    END IF
    IF (es /= 0 .OR. .NOT. CD_All_Finite(rhs)) THEN
      ErrStat = CD_DYN_SINGULAR
      ErrMsg = 'CableDyn_Dynamic: consistent mass is singular (DGBSV): '//TRIM(em)
      RETURN
    END IF
    a0(free) = rhs
  END SUBROUTINE CD_Cable_Initial_Acceleration

  SUBROUTINE CD_Cable_Gen_Alpha_Step(q, v, a, elem_conn, l0, ea, rho_a, tension_only, &
                                     f_ext, fixed_dofs, dt, cfg, q_new, v_new, a_new, &
                                     converged, stalled, n_iter, ErrStat, ErrMsg, &
                                     load_proc, added_mass_proc, load_force_proc, &
                                     load_band_proc, prescribed_q, prescribed_v, prescribed_a, structural_mass, &
                                     workspace, added_mass_band_proc, start_load, start_tension, &
                                     probe_q, probe_R, probe_K, start_stiffness, axial_damping, &
                                     axial_l0_rate, start_l0, mass_l0, start_l0_rate, loads)
    !! One generalized-alpha step: the constant load f_ext plus the optional load,
    !! banded-load, force-only and added-mass callbacks (hydrodynamics, damping, contact).
    !! loads (CD_Cable_Step_Loads) stands for load_force_proc and load_band_proc (has_force)
    !! and for added_mass_band_proc (has_added_mass), which are then not passed.
    !! On a singular effective tangent returns CD_DYN_SINGULAR; on a line-search
    !! stall returns converged=.FALSE., stalled=.TRUE.
    !!
    !! Output-state contract: on a SUCCESS or STALL exit the output is the advanced
    !! state at t_{n+1} (fixed DOFs exactly at q[fixed], v = a = 0). On any FAILURE
    !! exit AFTER the inputs are validated (mass-assembly failure, in-loop assembly
    !! failure, singular tangent), the output is the input state at t_n returned
    !! UNCHANGED -- never partial/zeroed garbage -- so a caller can safely retry the
    !! step (e.g. with a smaller dt) from a valid state. A pre-validation rejection
    !! (malformed shapes / non-finite inputs) leaves the zero-initialised outputs.
    REAL(wp), INTENT(IN)  :: q(:), v(:), a(:)    !! state at t_n, (3 n_nodes)
    INTEGER, INTENT(IN)  :: elem_conn(:, :)
    REAL(wp), INTENT(IN)  :: l0(:), ea(:), rho_a(:)
    LOGICAL, INTENT(IN)  :: tension_only
    REAL(wp), INTENT(IN)  :: f_ext(:)            !! constant external load over the step
    INTEGER, INTENT(IN)  :: fixed_dofs(:)
    REAL(wp), INTENT(IN)  :: dt
    TYPE(GenAlphaConfig), INTENT(IN) :: cfg
    REAL(wp), INTENT(OUT) :: q_new(:), v_new(:), a_new(:)   !! state at t_{n+1}
    LOGICAL, INTENT(OUT) :: converged, stalled
    INTEGER, INTENT(OUT) :: n_iter, ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    PROCEDURE(CD_Cable_Dynamic_Load_Proc), OPTIONAL :: load_proc
    PROCEDURE(CD_Cable_Added_Mass_Proc), OPTIONAL :: added_mass_proc
    PROCEDURE(CD_Cable_Dynamic_Force_Proc), OPTIONAL :: load_force_proc
    PROCEDURE(CD_Cable_Dynamic_Load_Banded_Proc), OPTIONAL :: load_band_proc
    PROCEDURE(CD_Cable_Added_Mass_Banded_Proc), OPTIONAL :: added_mass_band_proc
    PROCEDURE(CD_Cable_Dynamic_Load_Proc), POINTER :: load_proc_cb
    PROCEDURE(CD_Cable_Added_Mass_Proc), POINTER :: added_mass_proc_cb
    PROCEDURE(CD_Cable_Dynamic_Force_Proc), POINTER :: load_force_proc_cb
    PROCEDURE(CD_Cable_Dynamic_Load_Banded_Proc), POINTER :: load_band_proc_cb
    PROCEDURE(CD_Cable_Added_Mass_Banded_Proc), POINTER :: added_mass_band_proc_cb
    !! Prescribed (time-varying Dirichlet) motion at the fixed DOFs for t_{n+1}.
    !! Pass all three or none; full (3 n_nodes) arrays, only the fixed-DOF entries are
    !! read. Absent => the fixed DOFs are held at q_n with zero velocity/acceleration
    !! (the static-support default), bit-for-bit unchanged. Present => the fixed DOFs
    !! are driven to (prescribed_q, prescribed_v, prescribed_a), and their prescribed
    !! acceleration couples into the free-DOF residual through M a (so a moving
    !! support / fairlead injects momentum, not just position).
    REAL(wp), INTENT(IN), OPTIONAL :: prescribed_q(:), prescribed_v(:), prescribed_a(:)
    REAL(wp), INTENT(IN), OPTIONAL :: structural_mass(:, :)
    TYPE(CD_CableGenAlphaWorkspace), INTENT(INOUT), TARGET, OPTIONAL :: workspace
    !! Force blend (cfg%force_blend) with a load callback: the dynamic load at the step-start
    !! state (q, v) as the callbacks return it for the committed state (a constitutive law
    !! with internal state, such as the viscoelastic and Syrope contributors, gives its
    !! committed force there, not one advanced over the step). Absent: the step evaluates the
    !! force-only callback (or load_proc) at (q, v). Full (3 n_nodes) array.
    REAL(wp), INTENT(IN), OPTIONAL :: start_load(:)
    !! Force blend on a tension-only line whose load callbacks carry the axial law of some
    !! elements (ea = 0 there; the viscoelastic and Syrope elements of a line model): the
    !! step-start tension of each element (n_elem), the along-chord force of that law in
    !! start_load (or in the step-start load the step evaluates). The release cap then bounds
    !! the force blend of those elements as it bounds that of the elastic ones; entries of
    !! elements with ea > 0 are ignored. Absent: the cap covers the elastic elements only.
    REAL(wp), INTENT(IN), OPTIONAL :: start_tension(:)
    !! With start_tension: the axial stiffness of each law element at the step-start state
    !! (n_elem, N per metre of elongation, >= 0; the viscoelastic EA_D/l0 and the Syrope
    !! K1/l0 = (alpha + beta T_mean)/l0 of a line model). It bounds the secant stiffness
    !! T_n/e_n with which the release cap estimates the end tension of a law element that ends
    !! taut (see apply_release_cap). Entries of elements with ea > 0 are ignored. Absent: the
    !! secant is not bounded.
    REAL(wp), INTENT(IN), OPTIONAL :: start_stiffness(:)
    !! Force blend on a tension-only line whose load callbacks carry a linear axial dashpot on
    !! elements with ea > 0 (the axial damping of a line model): its coefficient BA per element
    !! (n_elem, N s, >= 0), the dashpot force on node a being (BA/l0) (t . (v_b - v_a)
    !! - (l/l0) l0_dot) t, with axial_l0_rate the unstretched-length rate l0_dot (n_elem; absent:
    !! zero). The release cap then covers the dashpot's step-start share too (see
    !! apply_release_cap). Entries of elements with ea = 0 are ignored. Absent: the cap covers
    !! the elastic force only.
    REAL(wp), INTENT(IN), OPTIONAL :: axial_damping(:), axial_l0_rate(:)
    !! TEST HOOK (unit tests of the tangent; production callers omit it). With probe_q (full
    !! 3 n_nodes array, the fixed DOFs at their t_{n+1} values) present, the step returns after
    !! its setup without iterating: probe_R is the residual (3 n_nodes) and probe_K the free-free
    !! effective tangent (n_free x n_free, free DOFs in ascending order) of the Newton iteration
    !! at probe_q, exactly as the iteration assembles them (banded or dense path). All three
    !! are passed together; the state outputs are the t_n state, converged = .FALSE.
    REAL(wp), INTENT(IN), OPTIONAL :: probe_q(:)
    REAL(wp), INTENT(OUT), OPTIONAL :: probe_R(:), probe_K(:, :)
    !! Unstretched lengths changed between t_n and t_{n+1} (active line control; n_elem each,
    !! finite and positive). l0 is then the length at t_{n+1}, which r(q_{n+1}, v_{n+1}) and
    !! the release cap's end stretch use. start_l0 (force blend only, ignored without it): the
    !! lengths the step-start state was reached with, which the step-start internal force
    !! r(q_n) and the release cap's step-start quantities use: e_n, T_n, W_n and the
    !! step-start dashpot tension T_d,n (start_load, start_tension and start_stiffness must
    !! then be those of these lengths). mass_l0: the lengths of the structural consistent mass
    !! (ignored with structural_mass). Absent: l0. start_l0_rate (force blend with
    !! axial_damping only): the unstretched-length rates the step-start state was reached
    !! with, for T_d,n; axial_l0_rate stays the rate at t_{n+1}, for T_d,n+1. Absent:
    !! axial_l0_rate.
    REAL(wp), INTENT(IN), OPTIONAL :: start_l0(:), mass_l0(:), start_l0_rate(:)
    CLASS(CD_Cable_Step_Loads), INTENT(INOUT), OPTIONAL :: loads

    INTEGER  :: n_dof, n_elem, n_free, bt, kl, ku, ldab
    INTEGER, POINTER :: free(:), fixed(:), ipiv(:)
    REAL(wp), POINTER :: M(:, :), q_n(:), v_n(:), a_n(:), q_pred(:), v_pred(:)
    REAL(wp), POINTER :: qk(:), R(:), eff(:, :), eff_free(:, :), R_free(:), dq(:)
    REAL(wp), POINTER :: q_trial(:), R_trial(:), corr(:)
    REAL(wp), POINTER :: a_eval(:), a_alpha(:), q_alpha(:), v_eval(:), v_alpha(:), fint_eval(:)
    ! q_alpha viewed as (3, n_nodes) nodal coordinates, without a copy
    REAL(wp), POINTER :: q_alpha_nodes(:, :)
    ! force blend: q_force holds q_{n+1} for the force evaluation, fint_n and load_n the
    ! step-start internal force and dynamic load; qf, vf (qf_nodes) are the state the internal
    ! force and the dynamic loads are evaluated at (q_{n+1}, v_{n+1} with the force blend,
    ! q_alpha, v_alpha without)
    REAL(wp), POINTER :: q_force(:), q_n_nodes(:, :), fint_n(:), load_n(:)
    REAL(wp), POINTER :: qf(:), vf(:), qf_nodes(:, :)
    REAL(wp), POINTER :: tension_n(:), stretch_n(:), chord_n(:, :), stiff_n(:)
    REAL(wp), POINTER :: dcoef_n(:), rl0dot_n(:), damp_n(:)
    LOGICAL :: force_blend, release_cap
    LOGICAL :: topo_ok, bw_hit, mb_hit
    INTEGER :: il, jl
    REAL(wp), POINTER :: Kt_eval(:, :), tension_eval(:), load_eval(:), jac_q_eval(:, :), jac_v_eval(:, :)
    REAL(wp), POINTER :: M_eff_eval(:, :), M_add_eval(:, :), dMa_a_dq_eval(:, :)
    REAL(wp), POINTER :: M_band(:, :), M_add_band(:, :), dMa_a_dq_band(:, :)
    REAL(wp), POINTER :: Kt_band(:, :), eff_band(:, :), eff_band_unfactored(:, :)
    REAL(wp), POINTER :: jq_band(:, :), jv_band(:, :), M_add_a_eval(:)
    TYPE(CD_CableGenAlphaWorkspace), TARGET :: local_workspace
    TYPE(CD_CableGenAlphaWorkspace), POINTER :: work
    REAL(wp) :: alpha_m, alpha_f, beta, gamma, rho, scale, r0, norm, merit, merit_trial, step, diag_scale
    REAL(wp) :: beta_e, gamma_e, alpham_e
    LOGICAL :: obj_levels, lev_mask
    REAL(wp) :: slope, stall_rel_tol, norm_before, tension_scale
    REAL(wp) :: diag_scale_cached, op_norm, op_norm_cached
    LOGICAL  :: accepted, has_load_proc, has_load_band_proc, has_added_mass_proc, has_added_mass_band_proc
    LOGICAL  :: has_load_force_proc
    ! the force and banded load (loads_force) and the banded added mass (loads_mass) from loads
    LOGICAL  :: loads_force, loads_mass
    LOGICAL  :: has_prescribed, direct_banded, have_eff, tangent_fresh, use_element_mass_band
    ! clock at the start of a profiled kernel (CABLEDYN_PROFILE; zero when not profiling)
    INTEGER(int64) :: prof_k0
    LOGICAL  :: factored_now, guess_used, prev_end_ok, reuse_factor, reused, warm_call, r_at_qk
    LOGICAL  :: scales_stale, trial_is_iterate
    INTEGER  :: es
    CHARACTER(1024) :: em

    q_new = CD_ZERO
    v_new = CD_ZERO
    a_new = CD_ZERO
    converged = .FALSE.
    stalled = .FALSE.
    n_iter = 0
    ErrStat = CD_DYN_OK
    ErrMsg = ''
    ! Only a warm re-solve of the step whose step-start data the workspace holds may reuse
    ! them (start_valid): any other call drops them before its first return, so an unarmed
    ! call that fails early cannot leave an older step's data to a later armed re-solve.
    IF (PRESENT(workspace)) workspace%start_valid = workspace%start_valid .AND. workspace%guess_armed
    n_dof = SIZE(q)
    loads_force = .FALSE.
    loads_mass = .FALSE.
    IF (PRESENT(loads)) THEN
      loads_force = loads%has_force
      loads_mass = loads%has_added_mass
    END IF
    IF ((loads_force .AND. (PRESENT(load_proc) .OR. PRESENT(load_band_proc) .OR. PRESENT(load_force_proc))) .OR. &
        (loads_mass .AND. (PRESENT(added_mass_proc) .OR. PRESENT(added_mass_band_proc)))) THEN
      CALL fail(ErrStat, ErrMsg, 'pass a load either as a callback or in loads, not both')
      RETURN
    END IF
    has_load_proc = PRESENT(load_proc)
    has_load_band_proc = PRESENT(load_band_proc) .OR. loads_force
    has_added_mass_proc = PRESENT(added_mass_proc)
    has_added_mass_band_proc = PRESENT(added_mass_band_proc) .OR. loads_mass
    has_load_force_proc = PRESENT(load_force_proc) .OR. loads_force
    NULLIFY (load_proc_cb, added_mass_proc_cb, load_force_proc_cb, load_band_proc_cb, added_mass_band_proc_cb)
    IF (has_load_proc) load_proc_cb => load_proc
    IF (PRESENT(load_band_proc)) load_band_proc_cb => load_band_proc
    IF (has_added_mass_proc) added_mass_proc_cb => added_mass_proc
    IF (PRESENT(added_mass_band_proc)) added_mass_band_proc_cb => added_mass_band_proc
    IF (PRESENT(load_force_proc)) load_force_proc_cb => load_force_proc
    IF (has_load_proc .AND. has_load_band_proc) THEN
      CALL fail(ErrStat, ErrMsg, 'pass either load_proc or load_band_proc, not both')
      RETURN
    END IF
    IF (has_load_force_proc .AND. .NOT. (has_load_proc .OR. has_load_band_proc)) THEN
      CALL fail(ErrStat, ErrMsg, 'load_force_proc accelerates residual-only evaluations but a tangent load '// &
                'callback is required')
      RETURN
    END IF
    IF (has_load_band_proc .AND. .NOT. has_load_force_proc) THEN
      CALL fail(ErrStat, ErrMsg, 'load_band_proc requires load_force_proc for residual-only line-search evaluations')
      RETURN
    END IF
    IF (has_added_mass_proc .AND. has_added_mass_band_proc) THEN
      CALL fail(ErrStat, ErrMsg, 'pass either added_mass_proc or added_mass_band_proc, not both')
      RETURN
    END IF
    ! The reduced-band path (load_band_proc / added_mass_band_proc) requires
    ! direct_banded, which a dense load_proc / added_mass_proc forces false -- the
    ! banded workspace would then be unallocated while the banded branch runs (write
    ! through unassociated pointers), and the dense tangent would silently drop a
    ! banded load Jacobian. The path must be entirely dense or entirely banded.
    IF ((has_load_band_proc .OR. has_added_mass_band_proc) .AND. &
        (has_load_proc .OR. has_added_mass_proc)) THEN
      CALL fail(ErrStat, ErrMsg, 'banded callbacks (load_band_proc/added_mass_band_proc) cannot be mixed '// &
                'with dense callbacks (load_proc/added_mass_proc); use one path')
      RETURN
    END IF
    ! prescribed motion: all three arrays together, or none
    IF (PRESENT(prescribed_q) .OR. PRESENT(prescribed_v) .OR. PRESENT(prescribed_a)) THEN
      IF (.NOT. (PRESENT(prescribed_q) .AND. PRESENT(prescribed_v) .AND. PRESENT(prescribed_a))) THEN
        CALL fail(ErrStat, ErrMsg, 'prescribed motion needs all of prescribed_q, prescribed_v, '// &
                  'prescribed_a (or none)')
        RETURN
      END IF
    END IF
    has_prescribed = PRESENT(prescribed_q)

    ! --- input validation (fail closed) ---
    CALL check_state_shapes(n_dof, [SIZE(v), SIZE(a), SIZE(f_ext), SIZE(q_new), &
                                    SIZE(v_new), SIZE(a_new)], ErrStat, ErrMsg)
    IF (ErrStat /= 0) RETURN
    IF (.NOT. CD_All_Finite(q) .OR. .NOT. CD_All_Finite(v) &
        .OR. .NOT. CD_All_Finite(a) .OR. .NOT. CD_All_Finite(f_ext)) THEN
      CALL fail(ErrStat, ErrMsg, 'q, v, a, f_ext must be finite')
      RETURN
    END IF
    IF (has_prescribed) THEN
      IF (SIZE(prescribed_q) /= n_dof .OR. SIZE(prescribed_v) /= n_dof .OR. SIZE(prescribed_a) /= n_dof) THEN
        CALL fail(ErrStat, ErrMsg, 'prescribed_q/v/a must each have shape (3 n_nodes)')
        RETURN
      END IF
      IF (.NOT. CD_All_Finite(prescribed_q) .OR. .NOT. CD_All_Finite(prescribed_v) &
          .OR. .NOT. CD_All_Finite(prescribed_a)) THEN
        CALL fail(ErrStat, ErrMsg, 'prescribed_q/v/a must be finite')
        RETURN
      END IF
    END IF
    ! Shapes conform and inputs are finite: echo the t_n state so that EVERY
    ! later failure return (bad dt/config, mass-assembly failure, in-loop
    ! assembly failure, singular tangent) leaves a valid state, not zeros. The
    ! success / stall path overwrites these with the advanced t_{n+1} state.
    q_new = q
    v_new = v
    a_new = a
    IF (.NOT. (CD_Is_Finite(dt) .AND. dt > CD_ZERO)) THEN
      CALL fail(ErrStat, ErrMsg, 'dt must be finite and positive')
      RETURN
    END IF
    CALL check_config(cfg, ErrStat, ErrMsg)
    IF (ErrStat /= 0) RETURN
    n_elem = SIZE(elem_conn, 2)
    IF (PRESENT(start_l0)) THEN
      IF (SIZE(start_l0) /= n_elem) THEN
        CALL fail(ErrStat, ErrMsg, 'start_l0 must have shape (n_elem)')
        RETURN
      END IF
      IF (.NOT. CD_All_Finite(start_l0) .OR. ANY(start_l0 <= CD_ZERO)) THEN
        CALL fail(ErrStat, ErrMsg, 'start_l0 must be finite and positive')
        RETURN
      END IF
    END IF
    IF (PRESENT(mass_l0)) THEN
      IF (SIZE(mass_l0) /= n_elem) THEN
        CALL fail(ErrStat, ErrMsg, 'mass_l0 must have shape (n_elem)')
        RETURN
      END IF
      IF (.NOT. CD_All_Finite(mass_l0) .OR. ANY(mass_l0 <= CD_ZERO)) THEN
        CALL fail(ErrStat, ErrMsg, 'mass_l0 must be finite and positive')
        RETURN
      END IF
    END IF
    IF (PRESENT(start_l0_rate)) THEN
      IF (SIZE(start_l0_rate) /= n_elem) THEN
        CALL fail(ErrStat, ErrMsg, 'start_l0_rate must have shape (n_elem)')
        RETURN
      END IF
      IF (.NOT. CD_All_Finite(start_l0_rate)) THEN
        CALL fail(ErrStat, ErrMsg, 'start_l0_rate must be finite')
        RETURN
      END IF
    END IF
    IF (PRESENT(workspace)) THEN
      work => workspace
    ELSE
      work => local_workspace
    END IF
    CALL ensure_dof_workspace(work, n_dof, SIZE(fixed_dofs), ErrStat, ErrMsg)
    IF (ErrStat /= 0) RETURN
    CALL partition_free_dofs_workspace(fixed_dofs, n_dof, work%free, n_free, work%fixed, &
                                       work%dof_marker, ErrStat, ErrMsg)
    IF (ErrStat /= 0) RETURN
    free => work%free(1:n_free)
    fixed => work%fixed(1:SIZE(fixed_dofs))
    n_free = SIZE(free)
    direct_banded = .NOT. has_load_proc .AND. .NOT. has_added_mass_proc
    use_element_mass_band = direct_banded .AND. .NOT. PRESENT(structural_mass)
    CALL validate_topology_once(work, elem_conn, n_dof/3, topo_ok)
    bw_hit = .FALSE.
    IF (direct_banded) THEN
      bw_hit = topo_ok .AND. work%bw_valid
      IF (bw_hit) bw_hit = SIZE(work%bw_free) == n_free
      IF (bw_hit) bw_hit = ALL(work%bw_free == free)
      IF (bw_hit) THEN
        kl = work%bw_kl
        ku = work%bw_ku
      ELSE
        work%mb_valid = .FALSE.
        CALL CD_Cable_Free_Bandwidth(elem_conn, n_dof/3, free, kl, ku, es, em, topology_validated=topo_ok)
        IF (es /= 0) THEN
          CALL fail(ErrStat, ErrMsg, 'bandwidth analysis failed: '//TRIM(em))
          RETURN
        END IF
        CALL remember_bandwidth(work, free, kl, ku, topo_ok)
      END IF
      ldab = 2*kl + ku + 1
    ELSE
      kl = 0
      ku = 0
      ldab = 0
    END IF
    CALL ensure_step_workspace(work, n_dof, n_elem, n_free, ldab, direct_banded, has_load_band_proc, &
                               .NOT. direct_banded,.NOT. use_element_mass_band, ErrStat, ErrMsg)
    IF (ErrStat /= 0) RETURN
    CALL bind_step_workspace(work)

    ! --- Chung-Hulbert parameters from rho_inf ---
    rho = cfg%rho_inf
    alpha_m = (2.0_wp*rho - CD_ONE)/(rho + CD_ONE)
    alpha_f = rho/(rho + CD_ONE)
    beta = 0.25_wp*(CD_ONE - alpha_m + alpha_f)**2
    gamma = 0.5_wp - alpha_m + alpha_f

    ! --- structural consistent mass (configuration-independent; reuse when supplied) ---
    IF (PRESENT(structural_mass)) THEN
      IF (SIZE(structural_mass, 1) /= n_dof .OR. SIZE(structural_mass, 2) /= n_dof) THEN
        CALL fail(ErrStat, ErrMsg, 'structural_mass must have shape (n_dof,n_dof)')
        RETURN
      END IF
      IF (.NOT. CD_All_Finite(structural_mass)) THEN
        CALL fail(ErrStat, ErrMsg, 'structural_mass must be finite')
        RETURN
      END IF
      M = structural_mass
    ELSE IF (.NOT. use_element_mass_band) THEN
      IF (PRESENT(mass_l0)) THEN
        CALL CD_Assemble_Cable_Mass(elem_conn, mass_l0, rho_a, M, es, em)
      ELSE
        CALL CD_Assemble_Cable_Mass(elem_conn, l0, rho_a, M, es, em)
      END IF
      IF (es /= 0) THEN
        CALL fail(ErrStat, ErrMsg, 'mass assembly failed: '//TRIM(em))
        RETURN
      END IF
    END IF

    ! --- predictors; fixed DOFs either held static (default) or driven to a
    !     prescribed (q, v, a) at t_{n+1}. For a static support: q_pred = q_n, v_pred
    !     = 0, a_n = 0, so eval_dynamic's a_eval = (q_eval - q_pred)/(beta dt^2) is 0
    !     at the held DOFs. For prescribed motion we want a_eval(fixed) = prescribed_a
    !     with q held at prescribed_q, so set q_pred(fixed) = prescribed_q -
    !     beta dt^2 prescribed_a and v_pred(fixed) = prescribed_v - gamma dt
    !     prescribed_a; then a_eval(fixed) = prescribed_a and v_eval(fixed) =
    !     prescribed_v fall out of the standard gen-alpha relations, and a_n(fixed)
    !     keeps the incoming (previous) acceleration for the alpha-blend. ---
    DO il = 1, n_dof
      q_n(il) = q(il)
      v_n(il) = v(il)
      a_n(il) = a(il)
      q_pred(il) = q_n(il) + dt*v_n(il) + dt*dt*(0.5_wp - beta)*a_n(il)
      v_pred(il) = v_n(il) + dt*(CD_ONE - gamma)*a_n(il)
    END DO
    ! junction object levels (work%end_levels): the fixed DOFs' predictor and alpha blend use
    ! the objects' Newmark and alpha_m (eval_dynamic), so d(a, v)/dq of an end DOF, and with it
    ! the condensed end tangent, is the objects' own
    obj_levels = work%end_request .AND. work%end_levels .AND. has_prescribed
    beta_e = beta
    gamma_e = gamma
    alpham_e = alpha_m
    IF (obj_levels) THEN
      beta_e = work%end_beta
      gamma_e = work%end_gamma
      alpham_e = work%end_alpham
    END IF
    ! lev_mask: work%end_level_dofs selects the DOFs that take them (object_level)
    lev_mask = .FALSE.
    IF (obj_levels .AND. ALLOCATED(work%end_level_dofs)) lev_mask = SIZE(work%end_level_dofs) == SIZE(fixed)
    IF (has_prescribed) THEN
      DO il = 1, SIZE(fixed)
        IF (object_level(il)) THEN
          q_pred(fixed(il)) = prescribed_q(fixed(il)) - beta_e*dt*dt*prescribed_a(fixed(il))
          v_pred(fixed(il)) = prescribed_v(fixed(il)) - gamma_e*dt*prescribed_a(fixed(il))
        ELSE
          q_pred(fixed(il)) = prescribed_q(fixed(il)) - beta*dt*dt*prescribed_a(fixed(il))
          v_pred(fixed(il)) = prescribed_v(fixed(il)) - gamma*dt*prescribed_a(fixed(il))
        END IF
      END DO
      ! a_n(fixed) retains the incoming acceleration (the previous prescribed accel)
    ELSE
      DO il = 1, SIZE(fixed)
        q_pred(fixed(il)) = q_n(fixed(il))
        v_pred(fixed(il)) = CD_ZERO
        a_n(fixed(il)) = CD_ZERO
      END DO
    END IF

    ! --- force blend: the step-start internal force and dynamic load, the alpha_f share of
    !     the blended residual (1 - alpha_f) r(q_{n+1}, v_{n+1}) + alpha_f r(q_n, v_n) ---
    !     A warm re-solve of the same step (the junction coupling re-steps the line from the
    !     same committed state with moved ends) reuses those of the previous call.
    force_blend = cfg%force_blend
    release_cap = .FALSE.
    IF (force_blend) THEN
      IF (work%guess_armed .AND. work%start_valid) THEN
        release_cap = tension_only .AND. alpha_f > CD_ZERO
      ELSE
        work%start_valid = .FALSE.
        CALL start_forces(es, em)
        IF (es /= 0) THEN
          CALL fail_callback(ErrStat, ErrMsg, em, es)
          RETURN
        END IF
        work%start_valid = .TRUE.
      END IF
    ELSE
      work%start_valid = .FALSE.
    END IF

    DO il = 1, n_dof
      qk(il) = q_pred(il)
    END DO
    ! Hold the fixed DOFs at their actual t_{n+1} position throughout the Newton loop
    ! (the free iteration never touches them). Static support => q_n; prescribed =>
    ! prescribed_q. With q_pred(fixed) set above, a_eval(fixed) then evaluates to 0 or
    ! prescribed_a respectively.
    IF (has_prescribed) qk(fixed) = prescribed_q(fixed)
    ! Junction warm start (monolithic body/point coupling): a re-solve of the same step with
    ! moved end DOFs starts from the previous converged interior shifted by the linear map
    ! X = S_FF^-1 S_FE of that solve, q_F = q_F,last - X (q_E - q_E,last).
    factored_now = .FALSE.
    guess_used = .FALSE.
    warm_call = work%guess_armed
    prev_end_ok = work%end_valid
    work%end_valid = .FALSE.
    ! The first solve of a step starts from the generalised-alpha predictor corrected the same
    ! way for the ends' departure from their own predictor, with the previous step's map.
    IF (work%end_request .AND. has_prescribed .AND. prev_end_ok .AND. direct_banded) THEN
      IF (ALLOCATED(work%q_last) .AND. ALLOCATED(work%end_x)) THEN
        IF (SIZE(work%q_last) == n_dof .AND. SIZE(work%end_x, 1) == n_free .AND. &
            SIZE(work%end_x, 2) == SIZE(fixed)) THEN
          IF (.NOT. work%guess_armed) THEN
            DO jl = 1, SIZE(fixed)
              il = fixed(jl)
              work%q_last(il) = q_n(il) + dt*v_n(il) + dt*dt*(0.5_wp - beta)*a_n(il)
            END DO
            DO il = 1, n_free
              work%q_last(free(il)) = q_pred(free(il))
            END DO
          END IF
          DO il = 1, n_free
            scale = work%q_last(free(il))
            DO jl = 1, SIZE(fixed)
              scale = scale - work%end_x(il, jl)*(qk(fixed(jl)) - work%q_last(fixed(jl)))
            END DO
            qk(free(il)) = scale
          END DO
          guess_used = CD_All_Finite(qk)
          IF (.NOT. guess_used) THEN
            DO il = 1, n_free
              qk(free(il)) = q_pred(free(il))
            END DO
          END IF
        END IF
      END IF
    END IF
    ! chord start of a warm re-solve on this step's factor (see step_factor)
    reuse_factor = work%guess_armed .AND. guess_used .AND. work%step_factor .AND. work%end_request
    reused = .FALSE.
    work%step_factor = work%step_factor .AND. reuse_factor
    work%guess_armed = .FALSE.
    IF (direct_banded) THEN
      IF (PRESENT(structural_mass)) THEN
        CALL validate_reduced_band_support(M, free, kl, ku, es, em)
        IF (es /= 0) THEN
          CALL fail(ErrStat, ErrMsg, 'structural_mass is not representable in the connectivity band: '//TRIM(em))
          RETURN
        END IF
      END IF
      es = 0
      IF (use_element_mass_band) THEN
        ! The element mass band depends only on the connectivity, the free list, l0 and
        ! rho_a: a step with the inputs of the remembered band (bw_hit: same connectivity and
        ! free list) reuses it, which is the band the assembly would build again. Its lengths
        ! are mass_l0 when present.
        mb_hit = .FALSE.
        IF (PRESENT(mass_l0)) THEN
          IF (bw_hit) mb_hit = mass_band_matches(work, mass_l0, rho_a)
          IF (.NOT. mb_hit) THEN
            work%mb_valid = .FALSE.
            CALL assemble_mass_band_free(elem_conn, mass_l0, rho_a, work%dof_marker(1:n_dof), kl, ku, M_band, &
                                         es, em)
            IF (es == 0 .AND. work%bw_valid) CALL remember_mass_band(work, mass_l0, rho_a)
          END IF
        ELSE
          IF (bw_hit) mb_hit = mass_band_matches(work, l0, rho_a)
          IF (.NOT. mb_hit) THEN
            work%mb_valid = .FALSE.
            CALL assemble_mass_band_free(elem_conn, l0, rho_a, work%dof_marker(1:n_dof), kl, ku, M_band, es, em)
            IF (es == 0 .AND. work%bw_valid) CALL remember_mass_band(work, l0, rho_a)
          END IF
        END IF
        IF (mb_hit .AND. work%mb_hits < HUGE(work%mb_hits)) work%mb_hits = work%mb_hits + 1
      ELSE
        work%mb_valid = .FALSE.
        CALL pack_dense_free_band(M, free, kl, ku, CD_ONE, M_band, es, em)
      END IF
      IF (es /= 0) THEN
        CALL fail(ErrStat, ErrMsg, 'mass band packing failed: '//TRIM(em))
        RETURN
      END IF
    END IF

    IF (PRESENT(probe_q)) THEN
      CALL probe_tangent()
      RETURN
    END IF

    r0 = CD_ZERO
    scale = CD_ONE
    tension_scale = CD_ZERO
    have_eff = reuse_factor
    scales_stale = reuse_factor
    trial_is_iterate = .FALSE.
    diag_scale_cached = CD_ONE
    diag_scale = CD_ONE
    op_norm_cached = CD_ONE
    op_norm = CD_ONE
    ! Bounded near-tolerance allowance for a residual stuck on its round-off floor just
    ! outside rel_tol: at most a factor two, never looser than sqrt(epsilon).
    stall_rel_tol = MAX(cfg%rel_tol, MIN(SQRT(EPSILON(CD_ONE)), 2.0_wp*cfg%rel_tol))
    ! Residual-first predictor test (see resid_first): the same acceptance test as the first
    ! Newton iteration, without assembling a tangent that a converged predictor never uses.
    ! A failed evaluation or an unconverged predictor falls through to the unchanged loop.
    r_at_qk = .FALSE.
    IF (work%resid_first .OR. (guess_used .AND. warm_call)) THEN
      CALL eval_dynamic(qk, R, es, em)
      ! a chord iteration on this step's factor then starts from this residual
      r_at_qk = es == 0
      IF (es == 0) THEN
        CALL gather_free(R, R_free)
        norm = infnorm(R_free)
        scale = MAX(free_infnorm(f_ext), norm, cfg%abs_tol)
        IF (work%end_request) scale = MAX(scale, work%end_scale)
        IF (norm/scale < cfg%rel_tol .OR. norm < cfg%abs_tol) converged = .TRUE.
      END IF
    END IF
    DO
      IF (converged) EXIT
      tangent_fresh = (.NOT. (cfg%modified_newton .OR. reuse_factor)) .OR. (.NOT. have_eff)
      reused = reuse_factor .AND. .NOT. tangent_fresh
      reuse_factor = .FALSE.
      IF (tangent_fresh) THEN
        IF (direct_banded) THEN
          CALL eval_dynamic(qk, R, es, em, effbandout=eff_band)
          ! factored_now and work%step_factor state that eff_band/ipiv hold the LU of the last
          ! factorization. eff_band now holds the unfactored tangent at qk, and they are set
          ! again only once it is factored below: an exit before that (convergence, or the
          ! near-tolerance allowance at the iteration limit) leaves the junction end query and
          ! a warm re-solve to factor it instead of back-solving with an unfactored band.
          factored_now = .FALSE.
          work%step_factor = .FALSE.
        ELSE
          CALL eval_dynamic(qk, R, es, em, effout=eff)
        END IF
        IF (es == 0) have_eff = .TRUE.
      ELSE IF (trial_is_iterate) THEN
        ! A reused-tangent iteration starts at the accepted trial, whose residual the line
        ! search just evaluated: the same evaluation at the same point, not repeated.
        DO il = 1, n_dof
          R(il) = R_trial(il)
        END DO
        es = 0
      ELSE IF (r_at_qk) THEN
        ! the residual-first evaluation at this iterate
        es = 0
      ELSE
        CALL eval_dynamic(qk, R, es, em)
      END IF
      trial_is_iterate = .FALSE.
      r_at_qk = .FALSE.
      IF (es /= 0) THEN
        CALL fail_callback(ErrStat, ErrMsg, em, es)
        RETURN
      END IF
      CALL gather_free(R, R_free)
      norm = infnorm(R_free)
      IF (n_iter == 0) THEN
        r0 = norm
        scale = MAX(free_infnorm(f_ext), r0, cfg%abs_tol)
        IF (work%end_request) scale = MAX(scale, work%end_scale)
        ! Largest element tension of the latest tangent evaluation (an earlier solve's when
        ! a reused factor or a residual-first predictor skips the tangent here): the
        ! internal-force magnitude every nodal residual row balances. It only bounds the
        ! round-off acceptance below when no external load sets a force scale.
        tension_scale = CD_ZERO
        IF (n_elem > 0) tension_scale = MAXVAL(ABS(tension_eval))
      END IF
      IF (norm/scale < cfg%rel_tol .OR. norm < cfg%abs_tol) THEN
        converged = .TRUE.
        EXIT
      END IF
      IF (n_iter >= cfg%max_iter) THEN
        ! An iteration budget spent on the round-off floor just outside rel_tol (the line
        ! search keeps accepting non-improving tiny steps) gets the same bounded
        ! near-tolerance allowance as the line-search stall below. Subdividing dt cannot
        ! help such a step: the inertia term's round-off grows like 1/dt**2.
        IF (norm/scale <= stall_rel_tol) converged = .TRUE.
        EXIT
      END IF

      DO il = 1, n_free
        dq(il) = -R_free(il)
      END DO
      IF (direct_banded) THEN
        IF (tangent_fresh) THEN
          ! diag_scale/op_norm are needed only by the rare fallback and round-off paths:
          ! evaluated lazily from the retained unfactored band (refresh_band_scales).
          scales_stale = .TRUE.
          DO jl = 1, SIZE(eff_band, 2)
            DO il = 1, SIZE(eff_band, 1)
              eff_band_unfactored(il, jl) = eff_band(il, jl)
            END DO
          END DO
          ! eval_dynamic has just checked this band finite when a banded load or added-mass
          ! callback contributes to it; the factorization then skips repeating that scan.
          CALL CD_Profile_Kernel_Begin(prof_k0)
          CALL CD_Factor_Banded(eff_band, kl, ku, ipiv, es, em, &
                                matrix_validated=has_load_band_proc .OR. has_added_mass_band_proc)
          CALL CD_Profile_Kernel_End(CD_PROF_K_FACTOR, prof_k0)
          factored_now = es == 0
          work%step_factor = factored_now .AND. work%end_request
          IF (es /= 0) THEN
            ErrStat = CD_DYN_SINGULAR
            ErrMsg = 'CableDyn_Dynamic: effective tangent is singular or ill-conditioned (DGBTRF): '//TRIM(em)
            RETURN
          END IF
        END IF
      ELSE
        diag_scale = MAX(CD_ONE, dense_diagonal_scale(eff, free))
        op_norm = MAX(CD_ONE, dense_row_abs_sum_max(eff, free))
      END IF
      IF (direct_banded) THEN
        ! A tangent factored in this iteration is the finite LU CD_Factor_Banded returned; a
        ! reused one keeps the full check.
        CALL CD_Profile_Kernel_Begin(prof_k0)
        CALL CD_Solve_Factored_Banded(eff_band, kl, ku, ipiv, dq, es, em, factor_validated=tangent_fresh)
        CALL CD_Profile_Kernel_End(CD_PROF_K_SOLVE, prof_k0)
      ELSE
        eff_free = eff(free, free)
        ! the dense path factors and solves in one call: profiled as a factorisation
        CALL CD_Profile_Kernel_Begin(prof_k0)
        CALL CD_Solve_Dense_As_Banded(eff_free, dq, es, em)
        CALL CD_Profile_Kernel_End(CD_PROF_K_FACTOR, prof_k0)
      END IF
      IF (es /= 0 .OR. .NOT. CD_All_Finite(dq)) THEN
        ErrStat = CD_DYN_SINGULAR
        ErrMsg = 'CableDyn_Dynamic: effective tangent is singular or ill-conditioned (DGBSV): '//TRIM(em)
        RETURN
      END IF

      merit = 0.5_wp*DOT_PRODUCT(R_free, R_free)
      step = CD_ONE
      accepted = .FALSE.
      DO bt = 0, cfg%armijo_max_backtracks
        CALL form_trial(step)
        CALL eval_dynamic(q_trial, R_trial, es, em)
        IF (es == CD_DYN_ALLOCFAIL) THEN
          ! A resource failure during a trial evaluation is not recoverable by backtracking;
          ! propagate it instead of treating it as a rejected step that ends as a stall.
          CALL fail_callback(ErrStat, ErrMsg, em, es)
          RETURN
        END IF
        IF (es == 0) THEN
          merit_trial = 0.5_wp*free_dot(R_trial)
          IF (merit_trial <= merit*(CD_ONE - cfg%armijo_c1*step)) THEN
            accepted = .TRUE.
            EXIT
          END IF
        END IF
        step = 0.5_wp*step
      END DO
      n_iter = n_iter + 1   ! one count per Newton iteration, accepted or not
      IF (.NOT. accepted) THEN
        IF ((cfg%modified_newton .OR. reused) .AND. .NOT. tangent_fresh) THEN
          have_eff = .FALSE.
          CYCLE
        END IF
        IF (direct_banded) THEN
          CALL refresh_band_scales()
          CALL band_merit_gradient_direction(eff_band_unfactored, kl, ku, R_free, diag_scale, dq)
        ELSE
          CALL dense_merit_gradient_direction(eff, free, R_free, diag_scale, dq)
        END IF
        slope = -diag_scale*diag_scale*DOT_PRODUCT(dq, dq)
        step = CD_ONE
        DO bt = 0, cfg%armijo_max_backtracks
          CALL form_trial(step)
          CALL eval_dynamic(q_trial, R_trial, es, em)
          IF (es == CD_DYN_ALLOCFAIL) THEN
            ! A resource failure during a trial evaluation is not recoverable by backtracking;
            ! propagate it instead of treating it as a rejected step that ends as a stall.
            CALL fail_callback(ErrStat, ErrMsg, em, es)
            RETURN
          END IF
          IF (es == 0) THEN
            merit_trial = 0.5_wp*free_dot(R_trial)
            IF (merit_trial <= merit + cfg%armijo_c1*step*slope) THEN
              accepted = .TRUE.
              EXIT
            END IF
          END IF
          step = 0.5_wp*step
        END DO
      END IF
      IF (.NOT. accepted) THEN
        IF (direct_banded) CALL refresh_band_scales()
        DO il = 1, n_free
          dq(il) = -R_free(il)/diag_scale
        END DO
        step = CD_ONE
        DO bt = 0, cfg%armijo_max_backtracks
          CALL form_trial(step)
          CALL eval_dynamic(q_trial, R_trial, es, em)
          IF (es == CD_DYN_ALLOCFAIL) THEN
            ! A resource failure during a trial evaluation is not recoverable by backtracking;
            ! propagate it instead of treating it as a rejected step that ends as a stall.
            CALL fail_callback(ErrStat, ErrMsg, em, es)
            RETURN
          END IF
          IF (es == 0) THEN
            merit_trial = 0.5_wp*free_dot(R_trial)
            IF (merit_trial < merit) THEN
              accepted = .TRUE.
              EXIT
            END IF
          END IF
          step = 0.5_wp*step
        END DO
      END IF
      IF (.NOT. accepted) THEN
        ! A line search can become round-off limited immediately outside a requested
        ! tolerance near sqrt(epsilon), especially when a BLAS kernel changes the last
        ! bits of the Newton correction. Accept only this bounded near-tolerance state or
        ! a residual at the operator's round-off floor (at_roundoff_floor); materially
        ! unconverged states still report a stall for the system-level recovery.
        IF (direct_banded) CALL refresh_band_scales()
        IF (at_roundoff_floor()) THEN
          converged = .TRUE.
        ELSE
          stalled = .TRUE.
        END IF
        EXIT
      END IF
      DO il = 1, n_dof
        qk(il) = q_trial(il)
      END DO
      trial_is_iterate = .TRUE.
      CALL gather_free(R_trial, R_free)
      norm_before = norm
      norm = infnorm(R_free)
      IF (norm/scale < cfg%rel_tol .OR. norm < cfg%abs_tol) THEN
        converged = .TRUE.
        EXIT
      END IF
      ! Inside the allowance and no longer contracting: the iterate sits on the round-off
      ! floor, where further iterations only shuffle rounding noise (a finely meshed stiff
      ! chain otherwise spends its whole iteration budget here on most steps).
      IF (norm > 0.5_wp*norm_before) THEN
        IF (direct_banded) CALL refresh_band_scales()
        IF (at_roundoff_floor()) THEN
          converged = .TRUE.
          EXIT
        END IF
      END IF
      ! modified Newton keeps the factorised tangent only while each iterate reduces the
      ! residual to at most a quarter of the previous one (a frozen tangent converges
      ! linearly, and a slow contraction would spend the iteration budget)
      IF (.NOT. cfg%modified_newton .OR. norm > 0.25_wp*norm_before) have_eff = .FALSE.
    END DO

    work%resid_first = converged .AND. n_iter == 0 .AND. .NOT. guess_used
    IF (work%end_request .AND. converged .AND. direct_banded) THEN
      CALL end_junction_data()
      IF (ErrStat /= CD_DYN_OK) RETURN
    END IF
    ! --- recover the end-of-step state from the converged/best q ---
    DO il = 1, n_dof
      corr(il) = qk(il) - q_pred(il)
    END DO
    DO il = 1, n_dof
      a_new(il) = corr(il)/(beta*dt*dt)
      v_new(il) = v_pred(il) + gamma*dt*a_new(il)
      q_new(il) = qk(il)
    END DO
    IF (has_prescribed) THEN
      ! the predictor was set so the general formulas already give prescribed_q/v/a
      ! at the fixed DOFs; pin exactly to remove any round-off drift.
      DO il = 1, SIZE(fixed)
        q_new(fixed(il)) = prescribed_q(fixed(il))
        v_new(fixed(il)) = prescribed_v(fixed(il))
        a_new(fixed(il)) = prescribed_a(fixed(il))
      END DO
    ELSE
      DO il = 1, SIZE(fixed)
        q_new(fixed(il)) = q_n(fixed(il))
        v_new(fixed(il)) = CD_ZERO
        a_new(fixed(il)) = CD_ZERO
      END DO
    END IF

  CONTAINS

    LOGICAL FUNCTION object_level(j)
      !! Whether fixed DOF j takes the junction objects' Newmark and inertia level.
      INTEGER, INTENT(IN) :: j
      object_level = obj_levels
      IF (lev_mask) object_level = work%end_level_dofs(j)
    END FUNCTION object_level

    SUBROUTINE end_junction_data()
      !! Alpha-level reaction rows R_E at the converged iterate qk and the condensed dynamic
      !! end tangent K_E = dR_E/dq_E|_{R_F = 0} (the implicit-function derivative the outer
      !! junction Newton needs), by forward differences of the step residual: column j of
      !! S_FE/S_EE from a perturbation of end DOF j, X_j = S_FF^-1 S_FE e_j with the step's
      !! factored effective band, and K = S_EE - S_EF X with S_EF taken as S_FE^T (the mass,
      !! material-stiffness and drag-velocity blocks are symmetric; the asymmetric parts, from
      !! the load terms and, on EI = 0 lines, the force blend's release cap and dashpot share,
      !! only slow the outer Newton, never its converged result). A step that
      !! converged from its warm start without factoring keeps the previous map and tangent
      !! (the end moved by a Newton correction of the same step); a cold step without a factor
      !! factors the tangent at qk once.
      INTEGER :: nfx, j, i, k2, es2
      REAL(wp) :: h, acc
      CHARACTER(1024) :: em2
      LOGICAL :: keep
      LOGICAL :: act(SIZE(fixed))
      REAL(wp), ALLOCATABLE :: sfe(:, :)
      nfx = SIZE(fixed)
      es2 = 0
      keep = .FALSE.
      IF (ALLOCATED(work%end_r) .AND. ALLOCATED(work%end_k) .AND. ALLOCATED(work%end_x)) THEN
        keep = SIZE(work%end_r) == nfx .AND. SIZE(work%end_x, 1) == n_free .AND. SIZE(work%end_x, 2) == nfx
      END IF
      IF (.NOT. keep) THEN
        IF (ALLOCATED(work%end_r)) DEALLOCATE (work%end_r)
        IF (ALLOCATED(work%end_k)) DEALLOCATE (work%end_k)
        IF (ALLOCATED(work%end_x)) DEALLOCATE (work%end_x)
        ALLOCATE (work%end_r(nfx), work%end_k(nfx, nfx), work%end_x(n_free, nfx), STAT=es2)
        IF (es2 /= 0) THEN
          CALL alloc_fail(ErrStat, ErrMsg, 'junction end-query workspace')
          RETURN
        END IF
        prev_end_ok = .FALSE.
      END IF
      IF (.NOT. ALLOCATED(work%q_last)) THEN
        ALLOCATE (work%q_last(n_dof), STAT=es2)
      ELSE IF (SIZE(work%q_last) /= n_dof) THEN
        DEALLOCATE (work%q_last)
        ALLOCATE (work%q_last(n_dof), STAT=es2)
      END IF
      IF (es2 /= 0) THEN
        CALL alloc_fail(ErrStat, ErrMsg, 'junction end-query workspace')
        RETURN
      END IF
      ! the last residual evaluated at the converged iterate: the accepted trial's or the
      ! iteration's own (see trial_is_iterate)
      IF (trial_is_iterate) THEN
        DO i = 1, n_dof
          R(i) = R_trial(i)
        END DO
      END IF
      DO j = 1, nfx
        work%end_r(j) = R(fixed(j))
      END DO
      IF (n_elem > 0) work%end_scale = MAXVAL(ABS(tension_eval))
      DO i = 1, n_dof
        work%q_last(i) = qk(i)
      END DO
      IF (prev_end_ok .AND. .NOT. work%end_refresh) THEN
        work%end_valid = CD_All_Finite(work%end_r)
        RETURN
      END IF
      IF (.NOT. factored_now) THEN
        CALL eval_dynamic(qk, R_trial, es2, em2, effbandout=eff_band)
        IF (es2 == 0) THEN
          DO j = 1, SIZE(eff_band, 2)
            DO i = 1, SIZE(eff_band, 1)
              eff_band_unfactored(i, j) = eff_band(i, j)
            END DO
          END DO
          CALL CD_Profile_Kernel_Begin(prof_k0)
          CALL CD_Factor_Banded(eff_band, kl, ku, ipiv, es2, em2)
          CALL CD_Profile_Kernel_End(CD_PROF_K_FACTOR, prof_k0)
        END IF
        work%step_factor = es2 == 0
        IF (es2 /= 0) THEN
          ErrStat = CD_DYN_SINGULAR
          ErrMsg = 'CableDyn_Dynamic: junction end tangent: effective tangent is singular: '//TRIM(em2)
          RETURN
        END IF
      END IF
      ! finite-difference base: R, the residual at qk (a tangent evaluation's residual equals
      ! the residual-only one the perturbations use)
      work%end_k = CD_ZERO
      work%end_x = CD_ZERO
      act = .TRUE.
      IF (ALLOCATED(work%end_active)) THEN
        IF (SIZE(work%end_active) == nfx) act = work%end_active
      END IF
      ALLOCATE (sfe(n_free, nfx), STAT=es2)
      IF (es2 /= 0) THEN
        CALL alloc_fail(ErrStat, ErrMsg, 'junction end-query workspace')
        RETURN
      END IF
      sfe = CD_ZERO
      DO j = 1, nfx
        IF (.NOT. act(j)) CYCLE
        h = SQRT(EPSILON(CD_ONE))*MAX(CD_ONE, ABS(qk(fixed(j))))
        DO i = 1, n_dof
          q_trial(i) = qk(i)
        END DO
        q_trial(fixed(j)) = qk(fixed(j)) + h
        CALL eval_dynamic(q_trial, R_trial, es2, em2)
        IF (es2 /= 0) THEN
          CALL fail_callback(ErrStat, ErrMsg, 'junction end tangent: '//TRIM(em2), es2)
          RETURN
        END IF
        DO i = 1, n_free
          dq(i) = (R_trial(free(i)) - R(free(i)))/h
          sfe(i, j) = dq(i)
        END DO
        DO i = 1, nfx
          work%end_k(i, j) = (R_trial(fixed(i)) - R(fixed(i)))/h
        END DO
        CALL CD_Profile_Kernel_Begin(prof_k0)
        CALL CD_Solve_Factored_Banded(eff_band, kl, ku, ipiv, dq, es2, em2)
        CALL CD_Profile_Kernel_End(CD_PROF_K_SOLVE, prof_k0)
        IF (es2 /= 0 .OR. .NOT. CD_All_Finite(dq)) THEN
          ErrStat = CD_DYN_SINGULAR
          ErrMsg = 'CableDyn_Dynamic: junction end tangent back-solve failed: '//TRIM(em2)
          RETURN
        END IF
        DO i = 1, n_free
          work%end_x(i, j) = dq(i)
        END DO
      END DO
      DO j = 1, nfx
        IF (.NOT. act(j)) CYCLE
        DO i = 1, nfx
          IF (.NOT. act(i)) CYCLE
          acc = CD_ZERO
          DO k2 = 1, n_free
            acc = acc + sfe(k2, i)*work%end_x(k2, j)
          END DO
          work%end_k(i, j) = work%end_k(i, j) - acc
        END DO
      END DO
      work%end_valid = CD_All_Finite(work%end_k) .AND. CD_All_Finite(work%end_r)
    END SUBROUTINE end_junction_data

    SUBROUTINE start_forces(es_s, em_s)
      !! fint_n = f_int(q_n) and load_n = the dynamic load at (q_n, v_n): start_load when the
      !! caller supplies it, else the force-only callback (or load_proc) evaluated there. The
      !! internal force and the release-cap data take the lengths the step-start state was
      !! reached with (start_l0 when present).
      INTEGER, INTENT(OUT) :: es_s
      CHARACTER(*), INTENT(OUT) :: em_s
      INTEGER :: i
      es_s = 0
      em_s = ''
      IF (PRESENT(start_l0)) THEN
        CALL CD_Assemble_Cable_Internal_Force(q_n_nodes, elem_conn, start_l0, ea, tension_only, fint_n, es_s, &
                                              em_s, topology_validated=topo_ok)
      ELSE
        CALL CD_Assemble_Cable_Internal_Force(q_n_nodes, elem_conn, l0, ea, tension_only, fint_n, es_s, em_s, &
                                              topology_validated=topo_ok)
      END IF
      IF (es_s /= 0) THEN
        es_s = CD_DYN_BADINPUT
        em_s = 'step-start internal-force assembly failed: '//TRIM(em_s)
        RETURN
      END IF
      ! release cap: the step-start tension, stretch and chord of every stretched element (the
      ! assembly above has validated the connectivity and the element lengths). An element
      ! with ea = 0 takes the tension of the law its load callback carries (start_tension) and
      ! the bound of its secant stiffness (start_stiffness).
      release_cap = tension_only .AND. alpha_f > CD_ZERO
      IF (release_cap .AND. PRESENT(start_tension)) THEN
        IF (SIZE(start_tension) /= n_elem) THEN
          es_s = CD_DYN_BADINPUT
          em_s = 'start_tension must have shape (n_elem)'
          RETURN
        END IF
        IF (.NOT. CD_All_Finite(start_tension)) THEN
          es_s = CD_DYN_BADINPUT
          em_s = 'start_tension must be finite'
          RETURN
        END IF
        IF (PRESENT(start_stiffness)) THEN
          IF (SIZE(start_stiffness) /= n_elem) THEN
            es_s = CD_DYN_BADINPUT
            em_s = 'start_stiffness must have shape (n_elem)'
            RETURN
          END IF
          IF (.NOT. CD_All_Finite(start_stiffness) .OR. ANY(start_stiffness < CD_ZERO)) THEN
            es_s = CD_DYN_BADINPUT
            em_s = 'start_stiffness must be finite and non-negative'
            RETURN
          END IF
        END IF
      END IF
      IF (release_cap .AND. PRESENT(axial_damping)) THEN
        IF (SIZE(axial_damping) /= n_elem) THEN
          es_s = CD_DYN_BADINPUT
          em_s = 'axial_damping must have shape (n_elem)'
          RETURN
        END IF
        IF (.NOT. CD_All_Finite(axial_damping) .OR. ANY(axial_damping < CD_ZERO)) THEN
          es_s = CD_DYN_BADINPUT
          em_s = 'axial_damping must be finite and non-negative'
          RETURN
        END IF
        IF (PRESENT(axial_l0_rate)) THEN
          IF (SIZE(axial_l0_rate) /= n_elem) THEN
            es_s = CD_DYN_BADINPUT
            em_s = 'axial_l0_rate must have shape (n_elem)'
            RETURN
          END IF
          IF (.NOT. CD_All_Finite(axial_l0_rate)) THEN
            es_s = CD_DYN_BADINPUT
            em_s = 'axial_l0_rate must be finite'
            RETURN
          END IF
        END IF
      END IF
      IF (release_cap) THEN
        DO i = 1, n_elem
          BLOCK
            REAL(wp) :: d(3), ell, l0s
            d = q_n_nodes(:, elem_conn(2, i)) - q_n_nodes(:, elem_conn(1, i))
            ell = NORM2(d)
            l0s = l0(i)
            IF (PRESENT(start_l0)) l0s = start_l0(i)
            chord_n(:, i) = d/ell
            stretch_n(i) = ell - l0s
            tension_n(i) = CD_ZERO
            stiff_n(i) = HUGE(CD_ONE)
            dcoef_n(i) = CD_ZERO
            rl0dot_n(i) = CD_ZERO
            damp_n(i) = CD_ZERO
            IF (ea(i) > CD_ZERO .AND. PRESENT(axial_damping)) THEN
              IF (axial_damping(i) > CD_ZERO) THEN
                ! the dashpot coefficient and payout rate of the end share (lengths at t_{n+1})
                dcoef_n(i) = axial_damping(i)/l0(i)
                IF (PRESENT(axial_l0_rate)) rl0dot_n(i) = axial_l0_rate(i)/l0(i)
                IF (PRESENT(start_l0) .OR. PRESENT(start_l0_rate)) THEN
                  ! after a length change the start load's dashpot has the step-start lengths
                  ! and rates
                  BLOCK
                    REAL(wp) :: dcs, rrs
                    dcs = axial_damping(i)/l0s
                    rrs = CD_ZERO
                    IF (PRESENT(start_l0_rate)) THEN
                      rrs = start_l0_rate(i)/l0s
                    ELSE IF (PRESENT(axial_l0_rate)) THEN
                      rrs = axial_l0_rate(i)/l0s
                    END IF
                    damp_n(i) = dcs*(DOT_PRODUCT(chord_n(:, i), v_n(3*elem_conn(2, i) - 2:3*elem_conn(2, i)) - &
                                                 v_n(3*elem_conn(1, i) - 2:3*elem_conn(1, i))) - ell*rrs)
                  END BLOCK
                ELSE
                  ! the dashpot tension the start load carries, as the callback evaluates it
                  damp_n(i) = dcoef_n(i)*(DOT_PRODUCT(chord_n(:, i), v_n(3*elem_conn(2, i) - 2:3*elem_conn(2, i)) - &
                                                      v_n(3*elem_conn(1, i) - 2:3*elem_conn(1, i))) - ell*rl0dot_n(i))
                END IF
              END IF
            END IF
            IF (stretch_n(i) > CD_ZERO) THEN
              IF (ea(i) > CD_ZERO) THEN
                tension_n(i) = ea(i)*(ell/l0s - CD_ONE)
              ELSE IF (PRESENT(start_tension)) THEN
                tension_n(i) = MAX(start_tension(i), CD_ZERO)
                IF (PRESENT(start_stiffness)) stiff_n(i) = start_stiffness(i)
              END IF
            END IF
          END BLOCK
        END DO
      END IF
      DO i = 1, n_dof
        load_n(i) = CD_ZERO
      END DO
      IF (.NOT. (has_load_proc .OR. has_load_band_proc)) RETURN
      IF (PRESENT(start_load)) THEN
        IF (SIZE(start_load) /= n_dof) THEN
          es_s = CD_DYN_BADINPUT
          em_s = 'start_load must have shape (3 n_nodes)'
          RETURN
        END IF
        DO i = 1, n_dof
          load_n(i) = start_load(i)
        END DO
      ELSE IF (has_load_force_proc) THEN
        IF (loads_force) THEN
          CALL loads%force(q_n, v_n, load_n, es_s, em_s)
        ELSE
          CALL load_force_proc_cb(q_n, v_n, load_n, es_s, em_s)
        END IF
        IF (es_s /= 0) THEN
          em_s = 'step-start dynamic force load failed: '//TRIM(em_s)
          RETURN
        END IF
      ELSE
        jac_q_eval = CD_ZERO
        jac_v_eval = CD_ZERO
        CALL load_proc_cb(q_n, v_n, load_n, jac_q_eval, jac_v_eval, es_s, em_s)
        IF (es_s /= 0) THEN
          em_s = 'step-start dynamic load failed: '//TRIM(em_s)
          RETURN
        END IF
      END IF
      IF (.NOT. CD_All_Finite(load_n)) THEN
        es_s = CD_DYN_BADINPUT
        em_s = 'step-start dynamic load is non-finite'
      END IF
    END SUBROUTINE start_forces

    SUBROUTINE refresh_band_scales()
      !! Diagonal scale and max absolute row sum of the current (unfactored) effective band.
      IF (.NOT. scales_stale) RETURN
      diag_scale_cached = MAX(CD_ONE, band_diagonal_scale(eff_band_unfactored, kl, ku, n_free))
      op_norm_cached = MAX(CD_ONE, band_row_abs_sum_max(eff_band_unfactored, kl, ku, n_free))
      diag_scale = diag_scale_cached
      op_norm = op_norm_cached
      scales_stale = .FALSE.
    END SUBROUTINE refresh_band_scales

    LOGICAL FUNCTION at_roundoff_floor()
      !! The free residual is within the bounded near-tolerance allowance, or it is below
      !! 1e-4 of the force scale and within the norm-wise backward error of the effective
      !! operator applied to the current coordinates (eps*max|q|*||A||_inf, the maximum
      !! absolute row sum), which no Newton step can reduce: every coordinate is stored to
      !! half an ulp and each residual row combines the rounding of all coordinates it
      !! couples. Stiff or strongly damped lines on fine meshes and small substeps sit there
      !! above rel_tol*scale. Relative to the nodal load scale that floor grows like
      !! (EA/l0)/(w*l0), i.e. with the square of the mesh density (a 410 m chain in 1640
      !! segments sits at ~2e-6); the 1e-4 sanity bound keeps such meshes admissible while
      !! still rejecting a materially unbalanced state that a huge ||A|| would excuse.
      !! The sanity bound uses the larger of the load scale and the element-tension
      !! scale: with no external load (a raw structural line) the load scale is the
      !! initial residual, itself round-off sized at small dt, and would reject every
      !! step even though the residual sits at the inertia round-off floor.
      ! callers refresh the lazily evaluated band scales first (refresh_band_scales)
      at_roundoff_floor = norm/scale <= stall_rel_tol .OR. &
                          (norm <= 1.0e-4_wp*MAX(scale, tension_scale) .AND. &
                           norm <= EPSILON(CD_ONE)*MAXVAL(ABS(qk))*op_norm)
    END FUNCTION at_roundoff_floor

    SUBROUTINE bind_step_workspace(workspace_ref)
      TYPE(CD_CableGenAlphaWorkspace), TARGET, INTENT(INOUT) :: workspace_ref

      IF (.NOT. use_element_mass_band) M => workspace_ref%M(1:n_dof, 1:n_dof)
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
      R_free => workspace_ref%R_free(1:n_free)
      dq => workspace_ref%dq(1:n_free)
      a_eval => workspace_ref%a_eval(1:n_dof)
      a_alpha => workspace_ref%a_alpha(1:n_dof)
      q_alpha => workspace_ref%q_alpha(1:n_dof)
      q_alpha_nodes(1:3, 1:n_dof/3) => workspace_ref%q_alpha(1:n_dof)
      q_force => workspace_ref%q_force(1:n_dof)
      q_n_nodes(1:3, 1:n_dof/3) => workspace_ref%q_n(1:n_dof)
      fint_n => workspace_ref%fint_n(1:n_dof)
      load_n => workspace_ref%load_n(1:n_dof)
      tension_n => workspace_ref%tension_n(1:n_elem)
      stretch_n => workspace_ref%stretch_n(1:n_elem)
      chord_n => workspace_ref%chord_n(1:3, 1:n_elem)
      stiff_n => workspace_ref%stiff_n(1:n_elem)
      dcoef_n => workspace_ref%dcoef_n(1:n_elem)
      rl0dot_n => workspace_ref%rl0dot_n(1:n_elem)
      damp_n => workspace_ref%damp_n(1:n_elem)
      v_eval => workspace_ref%v_eval(1:n_dof)
      v_alpha => workspace_ref%v_alpha(1:n_dof)
      IF (cfg%force_blend) THEN
        qf => workspace_ref%q_force(1:n_dof)
        qf_nodes(1:3, 1:n_dof/3) => workspace_ref%q_force(1:n_dof)
        vf => workspace_ref%v_eval(1:n_dof)
      ELSE
        qf => workspace_ref%q_alpha(1:n_dof)
        qf_nodes(1:3, 1:n_dof/3) => workspace_ref%q_alpha(1:n_dof)
        vf => workspace_ref%v_alpha(1:n_dof)
      END IF
      fint_eval => workspace_ref%fint_eval(1:n_dof)
      tension_eval => workspace_ref%tension_eval(1:n_elem)
      load_eval => workspace_ref%load_eval(1:n_dof)
      IF (direct_banded) THEN
        ! ipiv is allocated only on the banded path (need_band == direct_banded); bind it
        ! here, not unconditionally, or the dense path forms a section of an unallocated
        ! component (benign read under Release, an out-of-bounds trap under -fcheck=all).
        ipiv => workspace_ref%ipiv(1:n_free)
        M_band => workspace_ref%M_band(1:ldab, 1:n_free)
        Kt_band => workspace_ref%Kt_band(1:ldab, 1:n_free)
        eff_band => workspace_ref%eff_band(1:ldab, 1:n_free)
        eff_band_unfactored => workspace_ref%eff_band_unfactored(1:ldab, 1:n_free)
        IF (has_load_band_proc) THEN
          jq_band => workspace_ref%jq_band(1:ldab, 1:n_free)
          jv_band => workspace_ref%jv_band(1:ldab, 1:n_free)
        END IF
        IF (has_added_mass_band_proc) THEN
          M_add_a_eval => workspace_ref%M_add_a_eval(1:n_dof)
          M_add_band => workspace_ref%M_add_band(1:ldab, 1:n_free)
          dMa_a_dq_band => workspace_ref%dMa_a_dq_band(1:ldab, 1:n_free)
        END IF
      ELSE
        eff => workspace_ref%eff(1:n_dof, 1:n_dof)
        eff_free => workspace_ref%eff_free(1:n_free, 1:n_free)
        Kt_eval => workspace_ref%Kt_eval(1:n_dof, 1:n_dof)
        jac_q_eval => workspace_ref%jac_q_eval(1:n_dof, 1:n_dof)
        jac_v_eval => workspace_ref%jac_v_eval(1:n_dof, 1:n_dof)
        M_eff_eval => workspace_ref%M_eff_eval(1:n_dof, 1:n_dof)
        M_add_eval => workspace_ref%M_add_eval(1:n_dof, 1:n_dof)
        dMa_a_dq_eval => workspace_ref%dMa_a_dq_eval(1:n_dof, 1:n_dof)
      END IF
    END SUBROUTINE bind_step_workspace

    SUBROUTINE gather_free(x, x_free)
      !! x_free = x(free), without a vector-subscript temporary.
      REAL(wp), INTENT(IN) :: x(:)
      REAL(wp), INTENT(OUT) :: x_free(:)
      INTEGER :: i
      DO i = 1, n_free
        x_free(i) = x(free(i))
      END DO
    END SUBROUTINE gather_free

    REAL(wp) FUNCTION free_infnorm(x) RESULT(r)
      !! infnorm(x(free)) for finite x, without a vector-subscript temporary.
      REAL(wp), INTENT(IN) :: x(:)
      INTEGER :: i
      r = CD_ZERO
      DO i = 1, n_free
        IF (ABS(x(free(i))) > r) r = ABS(x(free(i)))
      END DO
    END FUNCTION free_infnorm

    REAL(wp) FUNCTION free_dot(x) RESULT(r)
      !! DOT_PRODUCT(x(free), x(free)), summed in the same order.
      REAL(wp), INTENT(IN) :: x(:)
      INTEGER :: i
      r = CD_ZERO
      DO i = 1, n_free
        r = r + x(free(i))*x(free(i))
      END DO
    END FUNCTION free_dot

    SUBROUTINE probe_tangent()
      !! The residual and free-free effective tangent at probe_q (see probe_q).
      INTEGER :: i, j
      IF (.NOT. (PRESENT(probe_R) .AND. PRESENT(probe_K))) THEN
        CALL fail(ErrStat, ErrMsg, 'probe_q needs probe_R and probe_K')
        RETURN
      END IF
      IF (SIZE(probe_q) /= n_dof .OR. SIZE(probe_R) /= n_dof .OR. SIZE(probe_K, 1) /= n_free .OR. &
          SIZE(probe_K, 2) /= n_free) THEN
        CALL fail(ErrStat, ErrMsg, 'probe_q, probe_R must have shape (3 n_nodes), probe_K (n_free, n_free)')
        RETURN
      END IF
      IF (direct_banded) THEN
        CALL eval_dynamic(probe_q, R, es, em, effbandout=eff_band)
      ELSE
        CALL eval_dynamic(probe_q, R, es, em, effout=eff)
      END IF
      IF (es /= 0) THEN
        CALL fail_callback(ErrStat, ErrMsg, em, es)
        RETURN
      END IF
      DO i = 1, n_dof
        probe_R(i) = R(i)
      END DO
      probe_K = CD_ZERO
      DO j = 1, n_free
        IF (direct_banded) THEN
          DO i = MAX(1, j - ku), MIN(n_free, j + kl)
            probe_K(i, j) = eff_band(kl + ku + 1 + i - j, j)
          END DO
        ELSE
          DO i = 1, n_free
            probe_K(i, j) = eff(free(i), free(j))
          END DO
        END IF
      END DO
    END SUBROUTINE probe_tangent

    SUBROUTINE form_trial(stp)
      !! q_trial = qk, then q_trial(free) += stp*dq.
      REAL(wp), INTENT(IN) :: stp
      INTEGER :: i
      DO i = 1, n_dof
        q_trial(i) = qk(i)
      END DO
      DO i = 1, n_free
        q_trial(free(i)) = q_trial(free(i)) + stp*dq(i)
      END DO
    END SUBROUTINE form_trial

    SUBROUTINE eval_dynamic(q_eval, Rout, es_e, em_e, effout, effbandout)
      !! eval_dynamic_core, timed by the run-time profile (CABLEDYN_PROFILE) as a residual-only
      !! evaluation or, with an effective tangent requested, as a residual and tangent one.
      REAL(wp), INTENT(IN)  :: q_eval(:)
      REAL(wp), INTENT(OUT) :: Rout(:)
      INTEGER, INTENT(OUT) :: es_e
      CHARACTER(*), INTENT(OUT) :: em_e
      REAL(wp), INTENT(OUT), OPTIONAL :: effout(:, :)
      REAL(wp), INTENT(OUT), OPTIONAL :: effbandout(:, :)
      INTEGER(int64) :: clock0
      CALL CD_Profile_Kernel_Begin(clock0)
      CALL eval_dynamic_core(q_eval, Rout, es_e, em_e, effout, effbandout)
      IF (PRESENT(effout) .OR. PRESENT(effbandout)) THEN
        CALL CD_Profile_Kernel_End(CD_PROF_K_TANGENT, clock0)
      ELSE
        CALL CD_Profile_Kernel_End(CD_PROF_K_RESIDUAL, clock0)
      END IF
    END SUBROUTINE eval_dynamic

    SUBROUTINE eval_dynamic_core(q_eval, Rout, es_e, em_e, effout, effbandout)
      !! R = M a_alpha + (1-af) r(q_eval, v_eval) + af r(q_n, v_n) with the force blend, else
      !! M a_alpha + f_int(q_alpha) - f_ext - load(q_alpha, v_alpha) (f_ext constant). When
      !! the OPTIONAL effout is present it also returns the effective tangent
      !! (1-am)/(beta dt^2) M + (1-af) K_t(q_eval or q_alpha); when absent only the internal
      !! force is assembled (the residual-only path the line search uses). Host-
      !! associates M, q_pred, q_n, a_n, f_ext, the Chung-Hulbert params, and the mesh.
      REAL(wp), INTENT(IN)  :: q_eval(:)
      REAL(wp), INTENT(OUT) :: Rout(:)
      INTEGER, INTENT(OUT) :: es_e
      CHARACTER(*), INTENT(OUT) :: em_e
      REAL(wp), INTENT(OUT), OPTIONAL :: effout(:, :)
      REAL(wp), INTENT(OUT), OPTIONAL :: effbandout(:, :)
      LOGICAL :: tangent_requested
      INTEGER :: iv, il2
      es_e = 0
      em_e = ''
      tangent_requested = PRESENT(effout) .OR. PRESENT(effbandout)
      ! Elementwise loops: the pointers may not be proven distinct, and a whole-array
      ! assignment would then need an array temporary per evaluation.
      DO iv = 1, n_dof
        a_eval(iv) = (q_eval(iv) - q_pred(iv))/(beta*dt*dt)
        v_eval(iv) = v_pred(iv) + gamma*dt*a_eval(iv)
        a_alpha(iv) = (CD_ONE - alpha_m)*a_eval(iv) + alpha_m*a_n(iv)
        q_alpha(iv) = (CD_ONE - alpha_f)*q_eval(iv) + alpha_f*q_n(iv)
        v_alpha(iv) = (CD_ONE - alpha_f)*v_eval(iv) + alpha_f*v_n(iv)
      END DO
      IF (force_blend) THEN
        DO iv = 1, n_dof
          q_force(iv) = q_eval(iv)
        END DO
      END IF
      IF (obj_levels) THEN
        DO il2 = 1, SIZE(fixed)
          IF (.NOT. object_level(il2)) CYCLE
          iv = fixed(il2)
          a_eval(iv) = (q_eval(iv) - q_pred(iv))/(beta_e*dt*dt)
          v_eval(iv) = v_pred(iv) + gamma_e*dt*a_eval(iv)
          a_alpha(iv) = (CD_ONE - alpham_e)*a_eval(iv) + alpham_e*a_n(iv)
          v_alpha(iv) = (CD_ONE - alpha_f)*v_eval(iv) + alpha_f*v_n(iv)
        END DO
      END IF
      load_eval = CD_ZERO
      IF (PRESENT(effbandout)) THEN
        CALL CD_Assemble_Cable_Tangent_Force_Banded_Free(qf_nodes, elem_conn, l0, ea, &
                                                         tension_only, free, kl, ku, Kt_band, fint_eval, &
                                                         tension_eval, es_e, em_e, topology_validated=topo_ok, &
                                                         free_map=work%dof_marker(1:n_dof))
        IF (es_e /= 0) THEN
          em_e = 'banded tangent assembly failed: '//TRIM(em_e)
          Rout = CD_ZERO
          effbandout = CD_ZERO
          RETURN
        END IF
        IF (has_load_band_proc) THEN
          ! the callback defines every INTENT(OUT) band entry itself
          IF (loads_force) THEN
            CALL loads%load_banded(qf, vf, free, kl, ku, load_eval, jq_band, jv_band, es_e, em_e)
          ELSE
            CALL load_band_proc_cb(qf, vf, free, kl, ku, load_eval, jq_band, jv_band, es_e, em_e)
          END IF
          IF (es_e /= 0) THEN
            em_e = 'dynamic banded load failed: '//TRIM(em_e)
            Rout = CD_ZERO
            effbandout = CD_ZERO
            RETURN
          END IF
          ! the Jacobian bands are validated once, combined, in the effective band below
          IF (.NOT. CD_All_Finite(load_eval)) THEN
            es_e = CD_DYN_BADINPUT
            em_e = 'dynamic banded load returned non-finite force/Jacobian'
            Rout = CD_ZERO
            effbandout = CD_ZERO
            RETURN
          END IF
        END IF
      ELSE IF (PRESENT(effout)) THEN
        CALL CD_Assemble_Cable_Tangent_Force(qf_nodes, elem_conn, l0, ea, &
                                             tension_only, Kt_eval, fint_eval, tension_eval, es_e, em_e, &
                                             topology_validated=topo_ok)
        IF (es_e /= 0) THEN
          em_e = 'tangent assembly failed: '//TRIM(em_e)
          Rout = CD_ZERO
          effout = CD_ZERO
          RETURN
        END IF
      ELSE
        CALL CD_Assemble_Cable_Internal_Force(qf_nodes, elem_conn, l0, ea, &
                                              tension_only, fint_eval, es_e, em_e, topology_validated=topo_ok)
        IF (es_e /= 0) THEN
          em_e = 'internal-force assembly failed: '//TRIM(em_e)
          Rout = CD_ZERO
          RETURN
        END IF
      END IF
      IF (.NOT. direct_banded) M_eff_eval = M
      IF (tangent_requested .AND. has_load_proc) THEN
        jac_q_eval = CD_ZERO
        jac_v_eval = CD_ZERO
        CALL load_proc_cb(qf, vf, load_eval, jac_q_eval, jac_v_eval, es_e, em_e)
        IF (es_e /= 0) THEN
          em_e = 'dynamic load failed: '//TRIM(em_e)
          Rout = CD_ZERO
          IF (PRESENT(effout)) effout = CD_ZERO
          IF (PRESENT(effbandout)) effbandout = CD_ZERO
          RETURN
        END IF
        IF (.NOT. CD_All_Finite(load_eval) .OR. .NOT. CD_All_Finite(jac_q_eval) &
            .OR. .NOT. CD_All_Finite(jac_v_eval)) THEN
          es_e = CD_DYN_BADINPUT
          em_e = 'dynamic load returned non-finite force/Jacobian'
          Rout = CD_ZERO
          IF (PRESENT(effout)) effout = CD_ZERO
          IF (PRESENT(effbandout)) effbandout = CD_ZERO
          RETURN
        END IF
      ELSE IF (has_load_force_proc .AND. .NOT. tangent_requested) THEN
        IF (loads_force) THEN
          CALL loads%force(qf, vf, load_eval, es_e, em_e)
        ELSE
          CALL load_force_proc_cb(qf, vf, load_eval, es_e, em_e)
        END IF
        IF (es_e /= 0) THEN
          em_e = 'dynamic force load failed: '//TRIM(em_e)
          Rout = CD_ZERO
          IF (PRESENT(effout)) effout = CD_ZERO
          RETURN
        END IF
        IF (.NOT. CD_All_Finite(load_eval)) THEN
          es_e = CD_DYN_BADINPUT
          em_e = 'dynamic force load returned non-finite force'
          Rout = CD_ZERO
          IF (PRESENT(effout)) effout = CD_ZERO
          RETURN
        END IF
      ELSE IF (has_load_proc) THEN
        jac_q_eval = CD_ZERO
        jac_v_eval = CD_ZERO
        CALL load_proc_cb(qf, vf, load_eval, jac_q_eval, jac_v_eval, es_e, em_e)
        IF (es_e /= 0) THEN
          em_e = 'dynamic load failed: '//TRIM(em_e)
          Rout = CD_ZERO
          RETURN
        END IF
        IF (.NOT. CD_All_Finite(load_eval) .OR. .NOT. CD_All_Finite(jac_q_eval) &
            .OR. .NOT. CD_All_Finite(jac_v_eval)) THEN
          es_e = CD_DYN_BADINPUT
          em_e = 'dynamic load returned non-finite force/Jacobian'
          Rout = CD_ZERO
          RETURN
        END IF
      END IF
      IF (has_added_mass_proc) THEN
        CALL added_mass_proc_cb(q_alpha, a_alpha, M_add_eval, dMa_a_dq_eval, es_e, em_e)
        IF (es_e /= 0) THEN
          em_e = 'added mass failed: '//TRIM(em_e)
          Rout = CD_ZERO
          IF (PRESENT(effout)) effout = CD_ZERO
          IF (PRESENT(effbandout)) effbandout = CD_ZERO
          RETURN
        END IF
        IF (.NOT. CD_All_Finite(M_add_eval) .OR. .NOT. CD_All_Finite(dMa_a_dq_eval)) THEN
          es_e = CD_DYN_BADINPUT
          em_e = 'added mass returned non-finite matrix/Jacobian'
          Rout = CD_ZERO
          IF (PRESENT(effout)) effout = CD_ZERO
          IF (PRESENT(effbandout)) effbandout = CD_ZERO
          RETURN
        END IF
        M_eff_eval = M_eff_eval + M_add_eval
      ELSE IF (has_added_mass_band_proc) THEN
        IF (loads_mass) THEN
          CALL loads%added_mass_banded(q_alpha, a_alpha, free, kl, ku, M_add_a_eval, M_add_band, &
                                       dMa_a_dq_band, es_e, em_e, PRESENT(effbandout))
        ELSE
          CALL added_mass_band_proc_cb(q_alpha, a_alpha, free, kl, ku, M_add_a_eval, M_add_band, &
                                       dMa_a_dq_band, es_e, em_e, PRESENT(effbandout))
        END IF
        IF (es_e /= 0) THEN
          em_e = 'banded added mass failed: '//TRIM(em_e)
          Rout = CD_ZERO
          IF (PRESENT(effbandout)) effbandout = CD_ZERO
          RETURN
        END IF
        IF (.NOT. CD_All_Finite(M_add_a_eval)) THEN
          es_e = CD_DYN_BADINPUT
          em_e = 'banded added mass returned non-finite matrix/Jacobian'
          Rout = CD_ZERO
          IF (PRESENT(effbandout)) effbandout = CD_ZERO
          RETURN
        END IF
      END IF
      IF (force_blend) THEN
        ! (1 - alpha_f) r(q_{n+1}, v_{n+1}) + alpha_f r(q_n, v_n); the tangent below takes the
        ! (1 - alpha_f) share of the derivatives at q_{n+1}
        DO iv = 1, n_dof
          fint_eval(iv) = (CD_ONE - alpha_f)*fint_eval(iv) + alpha_f*fint_n(iv)
        END DO
        IF (has_load_proc .OR. has_load_band_proc) THEN
          DO iv = 1, n_dof
            load_eval(iv) = (CD_ONE - alpha_f)*load_eval(iv) + alpha_f*load_n(iv)
          END DO
        END IF
      END IF
      IF (has_added_mass_proc) THEN
        Rout = MATMUL(M_eff_eval, a_alpha) + fint_eval - f_ext - load_eval
      ELSE IF (has_added_mass_band_proc) THEN
        ! Structural inertia must use the SAME mass the tangent's M_band was built
        ! from: element consistent mass when use_element_mass_band, else the dense M
        ! (= structural_mass when supplied). Recomputing from elem_conn/l0/rho_a here
        ! would ignore a supplied structural_mass while the Jacobian honored it.
        IF (use_element_mass_band) THEN
          CALL structural_inertia(Rout)
        ELSE
          Rout = MATMUL(M, a_alpha)
        END IF
        Rout = Rout + M_add_a_eval + fint_eval - f_ext - load_eval
      ELSE IF (use_element_mass_band) THEN
        CALL structural_inertia(Rout)
        Rout = Rout + fint_eval - f_ext - load_eval
      ELSE
        Rout = MATMUL(M, a_alpha) + fint_eval - f_ext - load_eval
      END IF
      IF (PRESENT(effout)) THEN
        effout = (CD_ONE - alpha_m)/(beta*dt*dt)*M_eff_eval + (CD_ONE - alpha_f)*Kt_eval
        IF (has_load_proc) effout = effout + (CD_ONE - alpha_f)*jac_q_eval + &
                                    (CD_ONE - alpha_f)*gamma/(beta*dt)*jac_v_eval
        IF (has_added_mass_proc) effout = effout + (CD_ONE - alpha_f)*dMa_a_dq_eval
      ELSE IF (PRESENT(effbandout)) THEN
        effbandout = (CD_ONE - alpha_m)/(beta*dt*dt)*M_band + (CD_ONE - alpha_f)*Kt_band
        IF (has_load_band_proc) effbandout = effbandout + (CD_ONE - alpha_f)*jq_band + &
                                             (CD_ONE - alpha_f)*gamma/(beta*dt)*jv_band
        IF (has_added_mass_band_proc) effbandout = effbandout + &
                                                   (CD_ONE - alpha_m)/(beta*dt*dt)*M_add_band + &
                                                   (CD_ONE - alpha_f)*dMa_a_dq_band
        IF ((has_load_band_proc .OR. has_added_mass_band_proc) .AND. .NOT. CD_All_Finite(effbandout)) THEN
          es_e = CD_DYN_BADINPUT
          em_e = 'dynamic banded load/added mass returned a non-finite Jacobian'
          Rout = CD_ZERO
          effbandout = CD_ZERO
          RETURN
        END IF
      END IF
      IF (force_blend .AND. release_cap) THEN
        IF (PRESENT(effbandout)) THEN
          CALL apply_release_cap(q_eval, Rout, effbandout=effbandout)
        ELSE IF (PRESENT(effout)) THEN
          CALL apply_release_cap(q_eval, Rout, effout=effout)
        ELSE
          CALL apply_release_cap(q_eval, Rout)
        END IF
      END IF
    END SUBROUTINE eval_dynamic_core

    SUBROUTINE structural_inertia(Rout)
      !! Rout = M a_alpha with the element consistent mass (of mass_l0 when present, the lengths
      !! the mass band was built from).
      REAL(wp), INTENT(OUT) :: Rout(:)
      IF (PRESENT(mass_l0)) THEN
        CALL consistent_mass_matvec(elem_conn, mass_l0, rho_a, a_alpha, Rout)
      ELSE
        CALL consistent_mass_matvec(elem_conn, l0, rho_a, a_alpha, Rout)
      END IF
    END SUBROUTINE structural_inertia

    SUBROUTINE apply_release_cap(q_eval, Rout, effout, effbandout)
      !! Release cap of the force blend. A tension-only element taut at t_n (tension T_0,
      !! stretch e_0 = l_n - l0 > 0, chord d_0 = l_n t_0) carries alpha_f T_0 along its
      !! step-start chord t_0 in the blended residual, a constant force over the step. Over the
      !! relative displacement d_1 - d_0 of its ends it returns the work alpha_f T_0 p to the
      !! motion, with the projected shortening p = l_n - t_0 . d_1, not the shortening
      !! e_0 - e_1 = l_n - |d_1|: a segment that turns as it releases has p well above e_0 - e_1
      !! (up to l_n + |d_1| for a reversed chord). The end share (1 - alpha_f) T_1 t_1, T_1 the
      !! tension at t_{n+1}, returns -(1 - alpha_f) T_1 p_1 with p_1 = |d_1| - t_1 . d_0. The
      !! element itself only released its strain energy W_0 = T_0 e_0/2, so the blend of an
      !! element that releases (deeply, or turning) within one step can create energy. The cap
      !! uses an estimate T^_1 of T_1: T^_1 = k e_1 for e_1 > 0 and 0 otherwise, with the secant
      !! k = T_0/e_0. When alpha_f T_0 p exceeds N = W_0 + (1 - alpha_f) T^_1 p_1 the element
      !! carries N/p instead of alpha_f T_0 along t_0 (the smaller of the two is kept, so the
      !! blend is continuous in d_1), so its blend returns at most
      !! W_0 + (1 - alpha_f)(T^_1 - T_1) p_1 over the step, and never more than without the cap.
      !! T^_1 vanishes as the end state crosses the rest length, so the cap fades out
      !! continuously there (a cap on slack end states alone would jump by up to alpha_f T_0).
      !! For an elastic element T^_1 = T_1: its blend returns at most W_0 over every step (an
      !! element that ends slack carries the discrete energy gradient W_0/p and returns exactly
      !! W_0), and the cap acts on a taut end state only when the element turned and
      !! T_1 < alpha_f/(1 - alpha_f) T_0. An element slack at t_n keeps the force blend, but for
      !! the kept share of its dashpot (below).
      !! N >= W_0/2 always (k e_0 <= T_0), so 4 alpha_f p <= e_0 is a sufficient test of an
      !! inactive cap. The residual and the tangent are corrected by the difference.
      !! An element whose axial law a load callback carries (ea = 0, T_0 from start_tension) is
      !! capped the same way with the same W_0 = T_0 e_0/2 (the energy of the viscoelastic
      !! springs at rest, an upper bound of the energy below a stiffening loading curve such as
      !! Syrope's) and k = min(T_0/e_0, k_n), k_n its step-start axial stiffness
      !! (start_stiffness), which bounds the secant where T_0 is mostly damping or lagged state
      !! at a small e_0. Its law tension T_1 is not that of a linear spring, so its blend
      !! returns at most W_0 when (T^_1 - T_1) p_1 <= 0: always when it ends below l0 with no
      !! law tension, and otherwise not guaranteed, e.g. when it ends above l0 with less law
      !! tension than T^_1 (zero once the slow branch has taken up the stretch, or below
      !! Syrope's minimum strain), by up to (1 - alpha_f) k e_1 p_1.
      !! An elastic element with a linear axial dashpot (axial_damping) also keeps alpha_f T_d,0
      !! along t_0, T_d,0 the dashpot tension at t_n, and its end share carries
      !! (1 - alpha_f) T_d,1 t_1 (the dashpot pushes and pulls; it is not tension-only). The
      !! dashpot stores no energy, so the budget stays W_0. Where the end state lies below the
      !! band edge l0 + c e_0, c = alpha_f/(1 - alpha_f), the cap covers the dashpot with the
      !! weight phi = 1 at and below l0, falling linearly to 0 at the band edge: it replaces the
      !! kept force alpha_f (T_0 + phi T_d,0) by N/p when that is smaller, with
      !! N = max(W_0 + (1 - alpha_f)(T^_1 + phi T_d,1) p_1, 0), T_d,1 the dashpot tension the
      !! residual carries at (q_{n+1}, v_{n+1}). Over a step with p > 0 (the cap leaves an
      !! element that does not shorten along t_0) the blend of such an element then returns at
      !! most W_0 + (1 - phi) D, D the work of its uncapped blended dashpot
      !! alpha_f T_d,0 p - (1 - alpha_f) T_d,1 p_1, unless N would be negative (its end share
      !! alone returns more than W_0; the capped kept force is then zero). At and below l0
      !! (phi = 1) that is W_0. Above the band edge (phi = 0), and on every element without a
      !! dashpot, the cap is the one above, so the force-blended dashpot of a taut line keeps the
      !! standard generalised-alpha treatment. The weight is continuous, so is the capped force;
      !! the tangent carries dT_d,1/dq_{n+1} through v_{n+1} (gamma/(beta dt)).
      !! An element with a dashpot that is slack at t_n (T_0 = 0, e_0 <= 0) keeps only
      !! alpha_f T_d,0 along t_0, which returns alpha_f T_d,0 p, with no strain energy behind it,
      !! when the step reverses or turns its ends against the step-start rate. Its budget is the
      !! dashpot's own one-step dissipation W_d = T_d,0 ldot_0 dt, ldot_0 = l0 T_d,0/BA the
      !! dashpot's elongation rate at t_n (the axial rate less the paid-out rate l_n l0_dot/l0;
      !! the axial rate itself without payout), so W_d > 0 whenever T_d,0 /= 0. When
      !! alpha_f T_d,0 p > 0 exceeds W_d + N_d, N_d = max((1 - alpha_f) T_d,1 p_1, 0) the end
      !! share's credit (phi = 1: the band of a slack start is empty), the element carries
      !! (W_d + N_d)/p instead of alpha_f T_d,0 along t_0, so the kept dashpot share of an
      !! element slack at the step start returns at most its own one-step dissipation
      !! T_d,0 |ldot_0| dt plus the end share's credit. The capped force grows without bound as
      !! p -> 0 (W_d > 0), so the force is continuous there; alpha_f |p| <= |ldot_0| dt is a
      !! sufficient test of an inactive cap. The same law covers a compressive T_d,0 (p < 0).
      !! After a length change W_d and ldot_0 take the step-start lengths and rates (BA/l0_c,
      !! l_n l0_dot_c/l0_c), as T_d,0 does, and the end share's T_d,1 the new ones.
      !! After a length change (start_l0) every step-start quantity takes the lengths and rates
      !! the step-start state was reached with: e_0 = l_n - l0_c, T_0, W_0, the secant T_0/e_0,
      !! the law stiffness k_n and the dashpot tension T_d,0 (start_l0_rate); the end-state
      !! quantities take those at t_{n+1}: e_1 = |d_1| - l0, T^_1 = k e_1, T_d,1 and the
      !! dashpot weight phi, whose band runs from l0 to l0 + c e_0 (the end stretch against the
      !! new length, the band width set by the step-start stretch, as without a change). p and
      !! p_1 are the geometric projections above (l_n = l0_c + e_0). A haul-in (l0 < l0_c) can
      !! make p_1 more negative, so N is bounded below by zero there too, and the inactive-cap
      !! test uses the bound N >= W_0 - (1 - alpha_f) T_0 (l_n - l0)^2/(4 e_0), which is W_0/2
      !! without a change.
      REAL(wp), INTENT(IN) :: q_eval(:)
      REAL(wp), INTENT(INOUT) :: Rout(:)
      REAL(wp), INTENT(INOUT), OPTIONAL :: effout(:, :), effbandout(:, :)
      INTEGER :: e, na, nb, i, j, gi(6), fi, fj
      REAL(wp) :: d1(3), l1, e1, e0, t0, p, p1, num, ln, k0, ten1, cosang, dg, delta, t1(3), g(3), blk(3, 3), sgn
      REAL(wp) :: band, phi, dphi, td1, dv(3), dp1(3), dtd1(3), kc, credit, ls, nlb, dcs
      LOGICAL :: taut_end, damped, slack
      band = alpha_f/(CD_ONE - alpha_f)
      DO e = 1, n_elem
        t0 = tension_n(e)
        ! an element slack at t_n is capped only for the kept share of a step-start dashpot force
        slack = .NOT. t0 > CD_ZERO
        IF (slack) THEN
          IF (.NOT. (dcoef_n(e) > CD_ZERO .AND. ABS(damp_n(e)) > CD_ZERO)) CYCLE
        END IF
        na = elem_conn(1, e)
        nb = elem_conn(2, e)
        d1 = q_eval(3*nb - 2:3*nb) - q_eval(3*na - 2:3*na)
        e0 = stretch_n(e)
        ! the rest length of the step-start state (the committed one after a length change)
        ls = l0(e)
        IF (PRESENT(start_l0)) ls = start_l0(e)
        ! projected shortening p = l_n - t_0 . d_1 (l_n = ls + e_0); the common case, an element
        ! that does not release, is decided here without a root
        p = e0 + (ls - (chord_n(1, e)*d1(1) + chord_n(2, e)*d1(2) + chord_n(3, e)*d1(3)))
        ! a damped element taut at t_n whose end state lies below the band edge l0 + band e_0
        damped = .FALSE.
        IF (.NOT. slack) THEN
          damped = dcoef_n(e) > CD_ZERO
          IF (damped) damped = d1(1)*d1(1) + d1(2)*d1(2) + d1(3)*d1(3) < (l0(e) + band*e0)**2
        END IF
        IF (slack) THEN
          ! the kept dashpot share alpha_f T_d,0 returns work only when T_d,0 p > 0, and stays
          ! within W_d = T_d,0^2 dt/(BA/l0) while alpha_f |p| <= |ldot_0| dt (BA/l0_c after a
          ! length change: the dashpot coefficient T_d,0 was evaluated with)
          IF (.NOT. damp_n(e)*p > CD_ZERO) CYCLE
          dcs = dcoef_n(e)
          IF (PRESENT(start_l0)) dcs = axial_damping(e)/ls
          IF (alpha_f*ABS(p)*dcs <= ABS(damp_n(e))*dt) CYCLE
          l1 = NORM2(d1)
          IF (.NOT. l1 > CD_ZERO) CYCLE
          ln = ls + e0
          t1 = d1/l1
          cosang = t1(1)*chord_n(1, e) + t1(2)*chord_n(2, e) + t1(3)*chord_n(3, e)
          p1 = (l1 - ln) + 0.5_wp*ln*((t1(1) - chord_n(1, e))**2 + (t1(2) - chord_n(2, e))**2 + &
                                      (t1(3) - chord_n(3, e))**2)
          dv = v_eval(3*nb - 2:3*nb) - v_eval(3*na - 2:3*na)
          td1 = dcoef_n(e)*(DOT_PRODUCT(t1, dv) - l1*rl0dot_n(e))
          credit = (CD_ONE - alpha_f)*td1*p1
          num = damp_n(e)*damp_n(e)*dt/dcs + MAX(credit, CD_ZERO)
          dg = num/p
          IF (ABS(dg) >= alpha_f*ABS(damp_n(e))) CYCLE
          delta = dg - alpha_f*damp_n(e)
          Rout(3*na - 2:3*na) = Rout(3*na - 2:3*na) - delta*chord_n(:, e)
          Rout(3*nb - 2:3*nb) = Rout(3*nb - 2:3*nb) + delta*chord_n(:, e)
          IF (.NOT. (PRESENT(effout) .OR. PRESENT(effbandout))) CYCLE
          ! d(delta)/d(x_b) = g, d(delta)/d(x_a) = -g: dp/dd_1 = -t_0, and while the credit is
          ! positive dp_1/dd_1 and dT_d,1/dx_b as on the taut damped path
          g = (num/(p*p))*chord_n(:, e)
          IF (credit > CD_ZERO) THEN
            dp1 = t1 - (ln/l1)*(chord_n(:, e) - cosang*t1)
            dtd1 = dcoef_n(e)*((dv - DOT_PRODUCT(t1, dv)*t1)/l1 + (gamma/(beta*dt) - rl0dot_n(e))*t1)
            g = g + ((CD_ONE - alpha_f)/p)*(td1*dp1 + p1*dtd1)
          END IF
        ELSE IF (damped) THEN
          IF (.NOT. p > CD_ZERO) CYCLE
          l1 = NORM2(d1)
          IF (.NOT. l1 > CD_ZERO) CYCLE
          e1 = l1 - l0(e)
          ln = ls + e0
          t1 = d1/l1
          cosang = t1(1)*chord_n(1, e) + t1(2)*chord_n(2, e) + t1(3)*chord_n(3, e)
          p1 = (e1 - e0) + 0.5_wp*ln*((t1(1) - chord_n(1, e))**2 + (t1(2) - chord_n(2, e))**2 + &
                                      (t1(3) - chord_n(3, e))**2)
          ! |d_1| - l_n = (e_1 - e_0) + (l0 - ls) after a length change
          IF (PRESENT(start_l0)) p1 = p1 + (l0(e) - ls)
          k0 = MIN(t0/e0, stiff_n(e))
          ten1 = k0*MAX(e1, CD_ZERO)
          ! the dashpot weight and its slope along t_1 (zero at and below l0)
          phi = CD_ONE
          dphi = CD_ZERO
          IF (e1 > CD_ZERO) THEN
            phi = MAX(CD_ONE - e1/(band*e0), CD_ZERO)
            IF (phi > CD_ZERO) dphi = -CD_ONE/(band*e0)
          END IF
          ! the end share's dashpot tension, as the residual evaluates it at (q_eval, v_eval)
          dv = v_eval(3*nb - 2:3*nb) - v_eval(3*na - 2:3*na)
          td1 = dcoef_n(e)*(DOT_PRODUCT(t1, dv) - l1*rl0dot_n(e))
          num = 0.5_wp*t0*e0 + (CD_ONE - alpha_f)*(ten1 + phi*td1)*p1
          kc = t0 + phi*damp_n(e)
          dg = MAX(num, CD_ZERO)/p
          IF (dg >= alpha_f*kc) CYCLE
          delta = dg - alpha_f*kc
          Rout(3*na - 2:3*na) = Rout(3*na - 2:3*na) - delta*chord_n(:, e)
          Rout(3*nb - 2:3*nb) = Rout(3*nb - 2:3*nb) + delta*chord_n(:, e)
          IF (.NOT. (PRESENT(effout) .OR. PRESENT(effbandout))) CYCLE
          ! d(delta)/d(x_b) = g, d(delta)/d(x_a) = -g: dp/dd_1 = -t_0, dp_1/dd_1 as above,
          ! d(phi)/dd_1 = dphi t_1, and dT_d,1/dx_b = (BA/l0)((dv - (t_1 . dv) t_1)/l_1
          ! + (gamma/(beta dt) - l0_dot/l0) t_1), v_b moving with gamma/(beta dt) x_b
          g = -alpha_f*damp_n(e)*dphi*t1
          IF (num > CD_ZERO) THEN
            dp1 = t1 - (ln/l1)*(chord_n(:, e) - cosang*t1)
            dtd1 = dcoef_n(e)*((dv - DOT_PRODUCT(t1, dv)*t1)/l1 + (gamma/(beta*dt) - rl0dot_n(e))*t1)
            g = g + (num/(p*p))*chord_n(:, e) + ((CD_ONE - alpha_f)/p)*((ten1 + phi*td1)*dp1 + phi*p1*dtd1 + &
                                                                        dphi*td1*p1*t1)
            IF (e1 > CD_ZERO) g = g + ((CD_ONE - alpha_f)/p)*k0*p1*t1
          END IF
        ELSE
          IF (PRESENT(start_l0)) THEN
            ! N >= W_0 - (1 - alpha_f) T_0 (l_n - l0)^2/(4 e_0), l_n - l0 = e_0 + ls - l0
            nlb = 0.5_wp*t0*e0 - (CD_ONE - alpha_f)*t0*MAX(e0 + (ls - l0(e)), CD_ZERO)**2/(4.0_wp*e0)
            ! (p > 0 as well: the bound can be negative after a haul-in)
            IF (.NOT. (p > CD_ZERO .AND. alpha_f*t0*p > nlb)) CYCLE
          ELSE
            IF (.NOT. 4.0_wp*alpha_f*p > e0) CYCLE
          END IF
          num = 0.5_wp*t0*e0
          taut_end = d1(1)*d1(1) + d1(2)*d1(2) + d1(3)*d1(3) > l0(e)*l0(e)
          l1 = CD_ZERO
          e1 = CD_ZERO
          ten1 = CD_ZERO
          IF (taut_end) THEN
            ! the end share's work: p_1 = |d_1| - t_1 . d_0 = (e_1 - e_0) + l_n (1 - t_1 . t_0),
            ! with 1 - t_1 . t_0 = |t_1 - t_0|^2/2 (no cancellation at small turns)
            l1 = NORM2(d1)
            e1 = l1 - l0(e)
            taut_end = e1 > CD_ZERO
          END IF
          IF (taut_end) THEN
            ln = ls + e0
            ! the secant stiffness, bounded for a law element by its step-start axial stiffness
            k0 = MIN(t0/e0, stiff_n(e))
            ten1 = k0*e1
            t1 = d1/l1
            cosang = t1(1)*chord_n(1, e) + t1(2)*chord_n(2, e) + t1(3)*chord_n(3, e)
            p1 = (e1 - e0) + 0.5_wp*ln*((t1(1) - chord_n(1, e))**2 + (t1(2) - chord_n(2, e))**2 + &
                                        (t1(3) - chord_n(3, e))**2)
            IF (PRESENT(start_l0)) p1 = p1 + (l0(e) - ls)
            num = num + (CD_ONE - alpha_f)*ten1*p1
          END IF
          ! num >= W_0/2 > 0 without a length change; a haul-in can drive it below zero
          dg = MAX(num, CD_ZERO)/p
          IF (dg >= alpha_f*t0) CYCLE
          delta = dg - alpha_f*t0
          Rout(3*na - 2:3*na) = Rout(3*na - 2:3*na) - delta*chord_n(:, e)
          Rout(3*nb - 2:3*nb) = Rout(3*nb - 2:3*nb) + delta*chord_n(:, e)
          IF (.NOT. (PRESENT(effout) .OR. PRESENT(effbandout))) CYCLE
          ! d(delta)/d(x_b) = g, d(delta)/d(x_a) = -g, with dp/dd_1 = -t_0,
          ! dT_1/dd_1 = k0 t_1 and dp_1/dd_1 = t_1 - (l_n/|d_1|)(t_0 - (t_1 . t_0) t_1)
          g = CD_ZERO
          IF (num > CD_ZERO) THEN
            g = (num/(p*p))*chord_n(:, e)
            IF (taut_end) g = g + ((CD_ONE - alpha_f)/p)*((k0*p1 + ten1)*t1 - &
                                                          ten1*(ln/l1)*(chord_n(:, e) - cosang*t1))
          END IF
        END IF
        DO j = 1, 3
          DO i = 1, 3
            blk(i, j) = chord_n(i, e)*g(j)
          END DO
        END DO
        DO i = 1, 3
          gi(i) = 3*na - 3 + i
          gi(3 + i) = 3*nb - 3 + i
        END DO
        DO j = 1, 6
          DO i = 1, 6
            ! rows of node a carry -delta t_0, columns of node a d(delta)/d(x_a) = -g
            sgn = MERGE(-CD_ONE, CD_ONE, i <= 3)*MERGE(-CD_ONE, CD_ONE, j <= 3)
            IF (PRESENT(effout)) THEN
              effout(gi(i), gi(j)) = effout(gi(i), gi(j)) + sgn*blk(MOD(i - 1, 3) + 1, MOD(j - 1, 3) + 1)
            ELSE
              fi = work%dof_marker(gi(i))
              fj = work%dof_marker(gi(j))
              IF (fi <= 0 .OR. fj <= 0) CYCLE
              effbandout(kl + ku + 1 + fi - fj, fj) = effbandout(kl + ku + 1 + fi - fj, fj) + &
                                                      sgn*blk(MOD(i - 1, 3) + 1, MOD(j - 1, 3) + 1)
            END IF
          END DO
        END DO
      END DO
    END SUBROUTINE apply_release_cap

  END SUBROUTINE CD_Cable_Gen_Alpha_Step

  ! --------------------------------------------------------------------------- !
  ! private helpers                                                             !
  ! --------------------------------------------------------------------------- !

  SUBROUTINE ensure_dof_workspace(work, n_dof, n_fixed, ErrStat, ErrMsg)
    TYPE(CD_CableGenAlphaWorkspace), INTENT(INOUT) :: work
    INTEGER, INTENT(IN) :: n_dof, n_fixed
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg

    ErrStat = CD_DYN_OK
    ErrMsg = ''
    CALL ensure_int_vector(work%free, n_dof, ErrStat, ErrMsg)
    IF (ErrStat /= CD_DYN_OK) RETURN
    CALL ensure_int_vector(work%fixed, n_fixed, ErrStat, ErrMsg)
    IF (ErrStat /= CD_DYN_OK) RETURN
    CALL ensure_int_vector(work%dof_marker, n_dof, ErrStat, ErrMsg)
    IF (ErrStat /= CD_DYN_OK) RETURN
    work%n_dof_capacity = MAX(work%n_dof_capacity, n_dof)
    work%n_fixed_capacity = MAX(work%n_fixed_capacity, n_fixed)
  END SUBROUTINE ensure_dof_workspace

  SUBROUTINE ensure_step_workspace(work, n_dof, n_elem, n_free, ldab, need_band, need_load_band, &
                                   need_dense, need_dense_mass, ErrStat, ErrMsg)
    !! Grow the step scratch. need_dense_mass requests the dense (n_dof, n_dof) global mass,
    !! which only a supplied structural mass or a dense added-mass callback uses; the
    !! element-band path keeps every buffer O(n_dof * bandwidth).
    TYPE(CD_CableGenAlphaWorkspace), INTENT(INOUT) :: work
    INTEGER, INTENT(IN) :: n_dof, n_elem, n_free, ldab
    LOGICAL, INTENT(IN) :: need_band, need_load_band, need_dense, need_dense_mass
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg

    ErrStat = CD_DYN_OK
    ErrMsg = ''
    IF (need_dense_mass) THEN
      CALL ensure_real_matrix(work%M, n_dof, n_dof, ErrStat, ErrMsg)
      IF (ErrStat /= CD_DYN_OK) RETURN
    END IF
    CALL ensure_real_vector(work%q_n, n_dof, ErrStat, ErrMsg)
    IF (ErrStat /= CD_DYN_OK) RETURN
    CALL ensure_real_vector(work%v_n, n_dof, ErrStat, ErrMsg)
    IF (ErrStat /= CD_DYN_OK) RETURN
    CALL ensure_real_vector(work%a_n, n_dof, ErrStat, ErrMsg)
    IF (ErrStat /= CD_DYN_OK) RETURN
    CALL ensure_real_vector(work%q_pred, n_dof, ErrStat, ErrMsg)
    IF (ErrStat /= CD_DYN_OK) RETURN
    CALL ensure_real_vector(work%v_pred, n_dof, ErrStat, ErrMsg)
    IF (ErrStat /= CD_DYN_OK) RETURN
    CALL ensure_real_vector(work%qk, n_dof, ErrStat, ErrMsg)
    IF (ErrStat /= CD_DYN_OK) RETURN
    CALL ensure_real_vector(work%R, n_dof, ErrStat, ErrMsg)
    IF (ErrStat /= CD_DYN_OK) RETURN
    CALL ensure_real_vector(work%corr, n_dof, ErrStat, ErrMsg)
    IF (ErrStat /= CD_DYN_OK) RETURN
    CALL ensure_real_vector(work%q_trial, n_dof, ErrStat, ErrMsg)
    IF (ErrStat /= CD_DYN_OK) RETURN
    CALL ensure_real_vector(work%R_trial, n_dof, ErrStat, ErrMsg)
    IF (ErrStat /= CD_DYN_OK) RETURN
    CALL ensure_real_vector(work%R_free, n_free, ErrStat, ErrMsg)
    IF (ErrStat /= CD_DYN_OK) RETURN
    CALL ensure_real_vector(work%dq, n_free, ErrStat, ErrMsg)
    IF (ErrStat /= CD_DYN_OK) RETURN
    CALL ensure_real_vector(work%a_eval, n_dof, ErrStat, ErrMsg)
    IF (ErrStat /= CD_DYN_OK) RETURN
    CALL ensure_real_vector(work%a_alpha, n_dof, ErrStat, ErrMsg)
    IF (ErrStat /= CD_DYN_OK) RETURN
    CALL ensure_real_vector(work%q_alpha, n_dof, ErrStat, ErrMsg)
    IF (ErrStat /= CD_DYN_OK) RETURN
    CALL ensure_real_vector(work%v_eval, n_dof, ErrStat, ErrMsg)
    IF (ErrStat /= CD_DYN_OK) RETURN
    CALL ensure_real_vector(work%v_alpha, n_dof, ErrStat, ErrMsg)
    IF (ErrStat /= CD_DYN_OK) RETURN
    CALL ensure_real_vector(work%fint_eval, n_dof, ErrStat, ErrMsg)
    IF (ErrStat /= CD_DYN_OK) RETURN
    CALL ensure_real_vector(work%tension_eval, n_elem, ErrStat, ErrMsg)
    IF (ErrStat /= CD_DYN_OK) RETURN
    CALL ensure_real_vector(work%load_eval, n_dof, ErrStat, ErrMsg)
    IF (ErrStat /= CD_DYN_OK) RETURN
    CALL ensure_real_vector(work%q_force, n_dof, ErrStat, ErrMsg)
    IF (ErrStat /= CD_DYN_OK) RETURN
    CALL ensure_real_vector(work%fint_n, n_dof, ErrStat, ErrMsg)
    IF (ErrStat /= CD_DYN_OK) RETURN
    CALL ensure_real_vector(work%load_n, n_dof, ErrStat, ErrMsg)
    IF (ErrStat /= CD_DYN_OK) RETURN
    CALL ensure_real_vector(work%tension_n, n_elem, ErrStat, ErrMsg)
    IF (ErrStat /= CD_DYN_OK) RETURN
    CALL ensure_real_vector(work%stretch_n, n_elem, ErrStat, ErrMsg)
    IF (ErrStat /= CD_DYN_OK) RETURN
    CALL ensure_real_matrix(work%chord_n, 3, n_elem, ErrStat, ErrMsg)
    IF (ErrStat /= CD_DYN_OK) RETURN
    CALL ensure_real_vector(work%stiff_n, n_elem, ErrStat, ErrMsg)
    IF (ErrStat /= CD_DYN_OK) RETURN
    CALL ensure_real_vector(work%dcoef_n, n_elem, ErrStat, ErrMsg)
    IF (ErrStat /= CD_DYN_OK) RETURN
    CALL ensure_real_vector(work%rl0dot_n, n_elem, ErrStat, ErrMsg)
    IF (ErrStat /= CD_DYN_OK) RETURN
    CALL ensure_real_vector(work%damp_n, n_elem, ErrStat, ErrMsg)
    IF (ErrStat /= CD_DYN_OK) RETURN
    IF (need_band) THEN
      ! a reallocated mass band no longer holds the remembered one
      IF (ALLOCATED(work%M_band)) THEN
        IF (SIZE(work%M_band, 1) < ldab .OR. SIZE(work%M_band, 2) < n_free) work%mb_valid = .FALSE.
      ELSE
        work%mb_valid = .FALSE.
      END IF
      CALL ensure_real_matrix(work%M_band, ldab, n_free, ErrStat, ErrMsg)
      IF (ErrStat /= CD_DYN_OK) RETURN
      CALL ensure_real_vector(work%M_add_a_eval, n_dof, ErrStat, ErrMsg)
      IF (ErrStat /= CD_DYN_OK) RETURN
      CALL ensure_real_matrix(work%M_add_band, ldab, n_free, ErrStat, ErrMsg)
      IF (ErrStat /= CD_DYN_OK) RETURN
      CALL ensure_real_matrix(work%dMa_a_dq_band, ldab, n_free, ErrStat, ErrMsg)
      IF (ErrStat /= CD_DYN_OK) RETURN
      CALL ensure_real_matrix(work%Kt_band, ldab, n_free, ErrStat, ErrMsg)
      IF (ErrStat /= CD_DYN_OK) RETURN
      CALL ensure_real_matrix(work%eff_band, ldab, n_free, ErrStat, ErrMsg)
      IF (ErrStat /= CD_DYN_OK) RETURN
      CALL ensure_real_matrix(work%eff_band_unfactored, ldab, n_free, ErrStat, ErrMsg)
      IF (ErrStat /= CD_DYN_OK) RETURN
      CALL ensure_int_vector(work%ipiv, n_free, ErrStat, ErrMsg)
      IF (ErrStat /= CD_DYN_OK) RETURN
      IF (need_load_band) THEN
        CALL ensure_real_matrix(work%jq_band, ldab, n_free, ErrStat, ErrMsg)
        IF (ErrStat /= CD_DYN_OK) RETURN
        CALL ensure_real_matrix(work%jv_band, ldab, n_free, ErrStat, ErrMsg)
        IF (ErrStat /= CD_DYN_OK) RETURN
      END IF
      work%ldab_capacity = MAX(work%ldab_capacity, ldab)
    END IF
    IF (need_dense) THEN
      CALL ensure_real_matrix(work%eff, n_dof, n_dof, ErrStat, ErrMsg)
      IF (ErrStat /= CD_DYN_OK) RETURN
      CALL ensure_real_matrix(work%eff_free, n_free, n_free, ErrStat, ErrMsg)
      IF (ErrStat /= CD_DYN_OK) RETURN
      CALL ensure_real_matrix(work%Kt_eval, n_dof, n_dof, ErrStat, ErrMsg)
      IF (ErrStat /= CD_DYN_OK) RETURN
      CALL ensure_real_matrix(work%jac_q_eval, n_dof, n_dof, ErrStat, ErrMsg)
      IF (ErrStat /= CD_DYN_OK) RETURN
      CALL ensure_real_matrix(work%jac_v_eval, n_dof, n_dof, ErrStat, ErrMsg)
      IF (ErrStat /= CD_DYN_OK) RETURN
      CALL ensure_real_matrix(work%M_eff_eval, n_dof, n_dof, ErrStat, ErrMsg)
      IF (ErrStat /= CD_DYN_OK) RETURN
      CALL ensure_real_matrix(work%M_add_eval, n_dof, n_dof, ErrStat, ErrMsg)
      IF (ErrStat /= CD_DYN_OK) RETURN
      CALL ensure_real_matrix(work%dMa_a_dq_eval, n_dof, n_dof, ErrStat, ErrMsg)
      IF (ErrStat /= CD_DYN_OK) RETURN
    END IF
    work%n_dof_capacity = MAX(work%n_dof_capacity, n_dof)
    work%n_elem_capacity = MAX(work%n_elem_capacity, n_elem)
    work%n_free_capacity = MAX(work%n_free_capacity, n_free)
  END SUBROUTINE ensure_step_workspace

  SUBROUTINE validate_topology_once(work, elem_conn, n_nodes, validated)
    !! validated = .TRUE. when elem_conn (over n_nodes nodes) is the connectivity already
    !! validated for this workspace, or validates now and is remembered. A connectivity that
    !! fails validation is not remembered: the assembly then validates it again and reports
    !! the failure with its usual message. The copy is reallocated only when its shape changes.
    TYPE(CD_CableGenAlphaWorkspace), INTENT(INOUT) :: work
    INTEGER, INTENT(IN) :: elem_conn(:, :), n_nodes
    LOGICAL, INTENT(OUT) :: validated
    INTEGER :: es, istat
    CHARACTER(1024) :: em

    validated = work%topo_valid
    IF (validated) validated = work%topo_n_nodes == n_nodes
    IF (validated) validated = SIZE(work%topo_conn, 1) == SIZE(elem_conn, 1) .AND. &
                               SIZE(work%topo_conn, 2) == SIZE(elem_conn, 2)
    IF (validated) validated = ALL(work%topo_conn == elem_conn)
    IF (validated) RETURN
    work%topo_valid = .FALSE.
    work%bw_valid = .FALSE.
    CALL CD_Validate_Connectivity(elem_conn, n_nodes, SIZE(elem_conn, 2), es, em)
    IF (es /= 0) RETURN
    IF (ALLOCATED(work%topo_conn)) THEN
      IF (SIZE(work%topo_conn, 1) /= SIZE(elem_conn, 1) .OR. SIZE(work%topo_conn, 2) /= SIZE(elem_conn, 2)) &
        DEALLOCATE (work%topo_conn)
    END IF
    IF (.NOT. ALLOCATED(work%topo_conn)) THEN
      ALLOCATE (work%topo_conn(SIZE(elem_conn, 1), SIZE(elem_conn, 2)), STAT=istat)
      IF (istat /= 0) RETURN
    END IF
    work%topo_conn = elem_conn
    work%topo_n_nodes = n_nodes
    work%topo_valid = .TRUE.
    validated = .TRUE.
  END SUBROUTINE validate_topology_once

  SUBROUTINE remember_bandwidth(work, free, kl, ku, topology_validated)
    !! Keep the free-DOF bandwidth of this free list for the following steps (only for a
    !! validated connectivity, whose change invalidates it).
    TYPE(CD_CableGenAlphaWorkspace), INTENT(INOUT) :: work
    INTEGER, INTENT(IN) :: free(:), kl, ku
    LOGICAL, INTENT(IN) :: topology_validated
    INTEGER :: istat

    work%bw_valid = .FALSE.
    IF (.NOT. topology_validated) RETURN
    IF (ALLOCATED(work%bw_free)) THEN
      IF (SIZE(work%bw_free) /= SIZE(free)) DEALLOCATE (work%bw_free)
    END IF
    IF (.NOT. ALLOCATED(work%bw_free)) THEN
      ALLOCATE (work%bw_free(SIZE(free)), STAT=istat)
      IF (istat /= 0) RETURN
    END IF
    work%bw_free = free
    work%bw_kl = kl
    work%bw_ku = ku
    work%bw_valid = .TRUE.
  END SUBROUTINE remember_bandwidth

  LOGICAL FUNCTION mass_band_matches(work, l0, rho_a) RESULT(match)
    !! work%M_band holds the element mass band of these l0 and rho_a (for the remembered
    !! connectivity and free list). Equality is tested as <= and >= so that a NaN never matches.
    TYPE(CD_CableGenAlphaWorkspace), INTENT(IN) :: work
    REAL(wp), INTENT(IN) :: l0(:), rho_a(:)
    INTEGER :: e

    match = work%mb_valid
    IF (match) match = SIZE(work%mb_l0) == SIZE(l0) .AND. SIZE(work%mb_rho) == SIZE(rho_a)
    IF (.NOT. match) RETURN
    DO e = 1, SIZE(l0)
      IF (.NOT. (work%mb_l0(e) <= l0(e) .AND. work%mb_l0(e) >= l0(e))) THEN
        match = .FALSE.
        RETURN
      END IF
    END DO
    DO e = 1, SIZE(rho_a)
      IF (.NOT. (work%mb_rho(e) <= rho_a(e) .AND. work%mb_rho(e) >= rho_a(e))) THEN
        match = .FALSE.
        RETURN
      END IF
    END DO
  END FUNCTION mass_band_matches

  SUBROUTINE remember_mass_band(work, l0, rho_a)
    !! Record the inputs of the element mass band just assembled into work%M_band.
    TYPE(CD_CableGenAlphaWorkspace), INTENT(INOUT) :: work
    REAL(wp), INTENT(IN) :: l0(:), rho_a(:)
    INTEGER :: istat

    work%mb_valid = .FALSE.
    IF (ALLOCATED(work%mb_l0)) THEN
      IF (SIZE(work%mb_l0) /= SIZE(l0)) DEALLOCATE (work%mb_l0)
    END IF
    IF (ALLOCATED(work%mb_rho)) THEN
      IF (SIZE(work%mb_rho) /= SIZE(rho_a)) DEALLOCATE (work%mb_rho)
    END IF
    IF (.NOT. ALLOCATED(work%mb_l0)) THEN
      ALLOCATE (work%mb_l0(SIZE(l0)), STAT=istat)
      IF (istat /= 0) RETURN
    END IF
    IF (.NOT. ALLOCATED(work%mb_rho)) THEN
      ALLOCATE (work%mb_rho(SIZE(rho_a)), STAT=istat)
      IF (istat /= 0) RETURN
    END IF
    work%mb_l0 = l0
    work%mb_rho = rho_a
    work%mb_valid = .TRUE.
  END SUBROUTINE remember_mass_band

  SUBROUTINE partition_free_dofs_workspace(fixed_dofs, n_dof, free, n_free, fixed, marker, ErrStat, ErrMsg)
    INTEGER, INTENT(IN) :: fixed_dofs(:), n_dof
    INTEGER, INTENT(INOUT) :: free(:), fixed(:)
    INTEGER, INTENT(INOUT) :: marker(:)
    INTEGER, INTENT(OUT) :: n_free, ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg

    INTEGER :: i, j, n_fixed

    ErrStat = CD_DYN_OK
    ErrMsg = ''
    n_fixed = SIZE(fixed_dofs)
    IF (SIZE(free) < n_dof .OR. SIZE(fixed) < n_fixed .OR. SIZE(marker) < n_dof) THEN
      CALL fail(ErrStat, ErrMsg, 'workspace DOF partition arrays are undersized')
      n_free = 0
      RETURN
    END IF
    marker(1:n_dof) = 0
    DO i = 1, n_fixed
      j = fixed_dofs(i)
      IF (j < 1 .OR. j > n_dof) THEN
        CALL fail(ErrStat, ErrMsg, 'fixed_dofs entries must be in [1,n_dof]')
        n_free = 0
        RETURN
      END IF
      IF (marker(j) /= 0) THEN
        CALL fail(ErrStat, ErrMsg, 'fixed_dofs must not contain duplicates')
        n_free = 0
        RETURN
      END IF
      marker(j) = -1
      fixed(i) = j
    END DO
    n_free = 0
    DO i = 1, n_dof
      IF (marker(i) == 0) THEN
        n_free = n_free + 1
        free(n_free) = i
        marker(i) = n_free
      END IF
    END DO
  END SUBROUTINE partition_free_dofs_workspace

  SUBROUTINE ensure_int_vector(x, n, ErrStat, ErrMsg)
    !! The ensure_* helpers run for every workspace array on every step: they write ErrMsg only
    !! on failure, and their callers (ensure_dof_workspace, ensure_step_workspace) clear it.
    INTEGER, ALLOCATABLE, INTENT(INOUT) :: x(:)
    INTEGER, INTENT(IN) :: n
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(INOUT) :: ErrMsg
    INTEGER :: istat

    ErrStat = CD_DYN_OK
    IF (n < 0) THEN
      CALL fail(ErrStat, ErrMsg, 'internal workspace size must be non-negative')
      RETURN
    END IF
    IF (ALLOCATED(x)) THEN
      IF (SIZE(x) >= n) RETURN
      DEALLOCATE (x)
    END IF
    ALLOCATE (x(n), STAT=istat)
    IF (istat /= 0) CALL alloc_fail(ErrStat, ErrMsg, 'integer workspace allocation failed')
  END SUBROUTINE ensure_int_vector

  SUBROUTINE ensure_real_vector(x, n, ErrStat, ErrMsg)
    REAL(wp), ALLOCATABLE, INTENT(INOUT) :: x(:)
    INTEGER, INTENT(IN) :: n
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(INOUT) :: ErrMsg
    INTEGER :: istat

    ErrStat = CD_DYN_OK
    IF (n < 0) THEN
      CALL fail(ErrStat, ErrMsg, 'internal workspace size must be non-negative')
      RETURN
    END IF
    IF (ALLOCATED(x)) THEN
      IF (SIZE(x) >= n) RETURN
      DEALLOCATE (x)
    END IF
    ALLOCATE (x(n), STAT=istat)
    IF (istat /= 0) CALL alloc_fail(ErrStat, ErrMsg, 'real-vector workspace allocation failed')
  END SUBROUTINE ensure_real_vector

  SUBROUTINE ensure_real_matrix(x, n1, n2, ErrStat, ErrMsg)
    REAL(wp), ALLOCATABLE, INTENT(INOUT) :: x(:, :)
    INTEGER, INTENT(IN) :: n1, n2
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(INOUT) :: ErrMsg
    INTEGER :: istat

    ErrStat = CD_DYN_OK
    IF (n1 < 0 .OR. n2 < 0) THEN
      CALL fail(ErrStat, ErrMsg, 'internal workspace shape must be non-negative')
      RETURN
    END IF
    IF (ALLOCATED(x)) THEN
      IF (SIZE(x, 1) >= n1 .AND. SIZE(x, 2) >= n2) RETURN
      DEALLOCATE (x)
    END IF
    ALLOCATE (x(n1, n2), STAT=istat)
    IF (istat /= 0) CALL alloc_fail(ErrStat, ErrMsg, 'real-matrix workspace allocation failed')
  END SUBROUTINE ensure_real_matrix

  PURE FUNCTION reshape3(q, n_dof) RESULT(nodes)
    !! Copy the flat positions-only state into a (3, n_nodes) node array.
    INTEGER, INTENT(IN) :: n_dof
    REAL(wp), INTENT(IN) :: q(n_dof)
    REAL(wp) :: nodes(3, n_dof/3)
    nodes = RESHAPE(q, [3, n_dof/3])
  END FUNCTION reshape3

  SUBROUTINE check_state_shapes(n_dof, sizes, ErrStat, ErrMsg)
    !! n_dof must be a valid positions-only count (multiple of 3, >= 6) and every
    !! companion vector must share it.
    INTEGER, INTENT(IN)  :: n_dof, sizes(:)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    ErrStat = 0
    ErrMsg = ''
    IF (MOD(n_dof, 3) /= 0 .OR. n_dof < 6) THEN
      CALL fail(ErrStat, ErrMsg, 'q must be a positions-only state of shape (3 n_nodes), n_nodes >= 2')
      RETURN
    END IF
    IF (ANY(sizes /= n_dof)) THEN
      CALL fail(ErrStat, ErrMsg, 'q, v, a, f_ext, and the outputs must all share q''s shape')
    END IF
  END SUBROUTINE check_state_shapes

  SUBROUTINE assemble_mass_band_free(elem_conn, l0, rho_a, free_map, kl, ku, ab, ErrStat, ErrMsg)
    !! Assemble the reduced free/free consistent structural mass directly in
    !! LAPACK general-band storage from element connectivity.
    INTEGER, INTENT(IN) :: elem_conn(:, :), free_map(:), kl, ku
    REAL(wp), INTENT(IN) :: l0(:), rho_a(:)
    REAL(wp), INTENT(OUT) :: ab(:, :)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg

    INTEGER :: e, c, a_node, b_node, dof(6), p, q, ip, jq, row, ldab
    REAL(wp) :: coeff, me(6, 6)

    ErrStat = 0
    ErrMsg = ''
    ab = CD_ZERO
    ldab = 2*kl + ku + 1
    IF (SIZE(elem_conn, 1) /= 2 .OR. SIZE(l0) /= SIZE(elem_conn, 2) .OR. SIZE(rho_a) /= SIZE(elem_conn, 2)) THEN
      CALL fail(ErrStat, ErrMsg, 'mass-band assembly received inconsistent element arrays')
      RETURN
    END IF
    IF (kl < 0 .OR. ku < 0 .OR. SIZE(ab, 1) < ldab) THEN
      CALL fail(ErrStat, ErrMsg, 'mass-band assembly received invalid band storage')
      RETURN
    END IF
    IF (.NOT. CD_All_Finite(l0) .OR. .NOT. CD_All_Finite(rho_a) .OR. &
        ANY(l0 <= CD_ZERO) .OR. ANY(rho_a <= CD_ZERO)) THEN
      CALL fail(ErrStat, ErrMsg, 'mass-band assembly requires positive finite l0/rho_a')
      RETURN
    END IF

    DO e = 1, SIZE(elem_conn, 2)
      a_node = elem_conn(1, e)
      b_node = elem_conn(2, e)
      IF (a_node < 1 .OR. b_node < 1 .OR. 3*a_node > SIZE(free_map) .OR. 3*b_node > SIZE(free_map)) THEN
        CALL fail(ErrStat, ErrMsg, 'mass-band assembly connectivity is out of range')
        RETURN
      END IF
      coeff = rho_a(e)*l0(e)/6.0_wp
      me = CD_ZERO
      DO c = 1, 3
        me(c, c) = 2.0_wp*coeff
        me(c, c + 3) = coeff
        me(c + 3, c) = coeff
        me(c + 3, c + 3) = 2.0_wp*coeff
        dof(c) = 3*a_node - 3 + c
        dof(c + 3) = 3*b_node - 3 + c
      END DO
      DO q = 1, 6
        jq = free_map(dof(q))
        IF (jq <= 0) CYCLE
        DO p = 1, 6
          ip = free_map(dof(p))
          IF (ip <= 0) CYCLE
          row = kl + ku + 1 + ip - jq
          IF (row < 1 .OR. row > SIZE(ab, 1) .OR. jq > SIZE(ab, 2)) THEN
            CALL fail(ErrStat, ErrMsg, 'mass-band assembly found an off-band free/free entry')
            RETURN
          END IF
          ab(row, jq) = ab(row, jq) + me(p, q)
        END DO
      END DO
    END DO
  END SUBROUTINE assemble_mass_band_free

  SUBROUTINE consistent_mass_matvec(elem_conn, l0, rho_a, x, y)
    !! y = M*x for the line-consistent structural mass, assembled by element
    !! without forming a dense global matrix.
    INTEGER, INTENT(IN) :: elem_conn(:, :)
    REAL(wp), INTENT(IN) :: l0(:), rho_a(:), x(:)
    REAL(wp), INTENT(OUT) :: y(:)

    INTEGER :: e, c, a_node, b_node, ia, ib
    REAL(wp) :: coeff

    y = CD_ZERO
    DO e = 1, SIZE(elem_conn, 2)
      a_node = elem_conn(1, e)
      b_node = elem_conn(2, e)
      coeff = rho_a(e)*l0(e)/6.0_wp
      DO c = 1, 3
        ia = 3*a_node - 3 + c
        ib = 3*b_node - 3 + c
        y(ia) = y(ia) + 2.0_wp*coeff*x(ia) + coeff*x(ib)
        y(ib) = y(ib) + coeff*x(ia) + 2.0_wp*coeff*x(ib)
      END DO
    END DO
  END SUBROUTINE consistent_mass_matvec

  SUBROUTINE pack_dense_free_band(A, free, kl, ku, scale, ab, ErrStat, ErrMsg)
    !! Pack a known-band dense global matrix into reduced free-DOF LAPACK band
    !! storage without re-detecting the bandwidth. The caller supplies kl/ku from
    !! the element connectivity.
    REAL(wp), INTENT(IN) :: A(:, :), scale
    INTEGER, INTENT(IN) :: free(:), kl, ku
    REAL(wp), INTENT(OUT) :: ab(:, :)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg

    INTEGER :: n, ndof, i, j, row, ldab

    ErrStat = 0
    ErrMsg = ''
    ab = CD_ZERO
    n = SIZE(free)
    ndof = SIZE(A, 1)
    ldab = 2*kl + ku + 1
    IF (SIZE(A, 2) /= ndof) THEN
      CALL fail(ErrStat, ErrMsg, 'band pack source must be square')
      RETURN
    END IF
    IF (kl < 0 .OR. ku < 0 .OR. SIZE(ab, 1) < ldab .OR. SIZE(ab, 2) /= n) THEN
      CALL fail(ErrStat, ErrMsg, 'band pack destination has invalid shape')
      RETURN
    END IF
    IF (ANY(free < 1) .OR. ANY(free > ndof)) THEN
      CALL fail(ErrStat, ErrMsg, 'band pack free DOF index out of range')
      RETURN
    END IF
    IF (.NOT. CD_All_Finite(A)) THEN
      CALL fail(ErrStat, ErrMsg, 'band pack source must be finite')
      RETURN
    END IF

    DO j = 1, n
      DO i = MAX(1, j - ku), MIN(n, j + kl)
        row = kl + ku + 1 + i - j
        ab(row, j) = scale*A(free(i), free(j))
      END DO
    END DO
  END SUBROUTINE pack_dense_free_band

  SUBROUTINE validate_reduced_band_support(A, free, kl, ku, ErrStat, ErrMsg)
    !! Fail closed if a caller-supplied dense matrix has a nonzero reduced
    !! free/free entry outside the element-connectivity band used by DGBSV.
    REAL(wp), INTENT(IN) :: A(:, :)
    INTEGER, INTENT(IN) :: free(:), kl, ku
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg

    INTEGER :: n, ndof, i, j

    ErrStat = 0
    ErrMsg = ''
    n = SIZE(free)
    ndof = SIZE(A, 1)
    IF (SIZE(A, 2) /= ndof) THEN
      CALL fail(ErrStat, ErrMsg, 'band-support source must be square')
      RETURN
    END IF
    IF (kl < 0 .OR. ku < 0) THEN
      CALL fail(ErrStat, ErrMsg, 'band-support bandwidth must be non-negative')
      RETURN
    END IF
    IF (ANY(free < 1) .OR. ANY(free > ndof)) THEN
      CALL fail(ErrStat, ErrMsg, 'band-support free DOF index out of range')
      RETURN
    END IF
    IF (.NOT. CD_All_Finite(A)) THEN
      CALL fail(ErrStat, ErrMsg, 'band-support source must be finite')
      RETURN
    END IF

    DO j = 1, n
      DO i = 1, n
        IF (i >= j - ku .AND. i <= j + kl) CYCLE
        IF (ABS(A(free(i), free(j))) > TINY(CD_ONE)) THEN
          CALL fail(ErrStat, ErrMsg, 'off-band reduced free/free matrix entry detected')
          RETURN
        END IF
      END DO
    END DO
  END SUBROUTINE validate_reduced_band_support

  PURE FUNCTION dense_diagonal_scale(A, free) RESULT(scale)
    !! Maximum absolute diagonal entry of a dense reduced free/free operator.
    REAL(wp), INTENT(IN) :: A(:, :)
    INTEGER, INTENT(IN) :: free(:)
    REAL(wp) :: scale
    INTEGER :: i

    scale = CD_ZERO
    DO i = 1, SIZE(free)
      scale = MAX(scale, ABS(A(free(i), free(i))))
    END DO
  END FUNCTION dense_diagonal_scale

  PURE SUBROUTINE dense_merit_gradient_direction(A, free, residual, diag_scale, direction)
    !! Direction proportional to -J^T R for the merit 1/2 ||R||^2, scaled by
    !! a tangent diagonal estimate so its magnitude remains comparable to a Newton step.
    REAL(wp), INTENT(IN) :: A(:, :), residual(:), diag_scale
    INTEGER, INTENT(IN) :: free(:)
    REAL(wp), INTENT(OUT) :: direction(:)

    INTEGER :: i, j
    REAL(wp) :: denom

    direction = CD_ZERO
    denom = MAX(CD_ONE, diag_scale*diag_scale)
    DO i = 1, SIZE(free)
      DO j = 1, SIZE(free)
        direction(i) = direction(i) - A(free(j), free(i))*residual(j)
      END DO
      direction(i) = direction(i)/denom
    END DO
  END SUBROUTINE dense_merit_gradient_direction

  PURE SUBROUTINE band_merit_gradient_direction(ab, kl, ku, residual, diag_scale, direction)
    !! Reduced-band equivalent of dense_merit_gradient_direction. The matrix is
    !! supplied in unfactored LAPACK general-band storage.
    REAL(wp), INTENT(IN) :: ab(:, :), residual(:), diag_scale
    INTEGER, INTENT(IN) :: kl, ku
    REAL(wp), INTENT(OUT) :: direction(:)

    INTEGER :: i, j, row, n
    REAL(wp) :: denom

    direction = CD_ZERO
    n = SIZE(residual)
    denom = MAX(CD_ONE, diag_scale*diag_scale)
    DO j = 1, n
      DO i = MAX(1, j - ku), MIN(n, j + kl)
        row = kl + ku + 1 + i - j
        direction(j) = direction(j) - ab(row, j)*residual(i)
      END DO
      direction(j) = direction(j)/denom
    END DO
  END SUBROUTINE band_merit_gradient_direction

  PURE FUNCTION dense_row_abs_sum_max(A, free) RESULT(scale)
    !! Infinity norm (maximum absolute row sum) of a dense reduced free/free operator.
    REAL(wp), INTENT(IN) :: A(:, :)
    INTEGER, INTENT(IN) :: free(:)
    REAL(wp) :: scale
    INTEGER :: i, j
    REAL(wp) :: row_sum

    scale = CD_ZERO
    DO i = 1, SIZE(free)
      row_sum = CD_ZERO
      DO j = 1, SIZE(free)
        row_sum = row_sum + ABS(A(free(i), free(j)))
      END DO
      scale = MAX(scale, row_sum)
    END DO
  END FUNCTION dense_row_abs_sum_max

  PURE FUNCTION band_row_abs_sum_max(ab, kl, ku, n) RESULT(scale)
    !! Infinity norm (maximum absolute row sum) of an unfactored LAPACK general-band
    !! operator, A(i,j) = ab(kl+ku+1+i-j, j).
    REAL(wp), INTENT(IN) :: ab(:, :)
    INTEGER, INTENT(IN) :: kl, ku, n
    REAL(wp) :: scale
    INTEGER :: i, j
    REAL(wp) :: row_sum

    scale = CD_ZERO
    IF (2*kl + ku + 1 > SIZE(ab, 1) .OR. n > SIZE(ab, 2)) RETURN
    DO i = 1, n
      row_sum = CD_ZERO
      DO j = MAX(1, i - kl), MIN(n, i + ku)
        row_sum = row_sum + ABS(ab(kl + ku + 1 + i - j, j))
      END DO
      scale = MAX(scale, row_sum)
    END DO
  END FUNCTION band_row_abs_sum_max

  PURE FUNCTION band_diagonal_scale(ab, kl, ku, n) RESULT(scale)
    !! Maximum absolute diagonal entry of a LAPACK general-band operator.
    REAL(wp), INTENT(IN) :: ab(:, :)
    INTEGER, INTENT(IN) :: kl, ku, n
    REAL(wp) :: scale
    INTEGER :: i, row

    scale = CD_ZERO
    row = kl + ku + 1
    IF (row < 1 .OR. row > SIZE(ab, 1)) RETURN
    DO i = 1, n
      scale = MAX(scale, ABS(ab(row, i)))
    END DO
  END FUNCTION band_diagonal_scale

  SUBROUTINE check_config(cfg, ErrStat, ErrMsg)
    !! Validate the gen-alpha policy (rho_inf, tolerances and iteration limits, plus the
    !! armijo_c1 in (0,1) guard the static solver carries).
    TYPE(GenAlphaConfig), INTENT(IN) :: cfg
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    ErrStat = 0
    ErrMsg = ''
    IF (.NOT. CD_Is_Finite(cfg%rho_inf) .OR. cfg%rho_inf < CD_ZERO .OR. cfg%rho_inf > CD_ONE) THEN
      CALL fail(ErrStat, ErrMsg, 'rho_inf must be finite and in [0, 1]')
      RETURN
    END IF
    IF (.NOT. pos_finite(cfg%rel_tol) .OR. .NOT. pos_finite(cfg%abs_tol) &
        .OR. .NOT. pos_finite(cfg%armijo_c1) .OR. cfg%armijo_c1 >= CD_ONE &
        .OR. cfg%max_iter < 1 .OR. cfg%armijo_max_backtracks < 0) THEN
      CALL fail(ErrStat, ErrMsg, 'invalid solver config (tolerances finite/positive, '// &
                'armijo_c1 in (0,1), iteration counts positive)')
    END IF
  END SUBROUTINE check_config

  LOGICAL FUNCTION pos_finite(x) RESULT(ok)
    REAL(wp), INTENT(IN) :: x
    ok = CD_Is_Finite(x) .AND. x > CD_ZERO
  END FUNCTION pos_finite

  REAL(wp) FUNCTION infnorm(x) RESULT(r)
    REAL(wp), INTENT(IN) :: x(:)
    IF (SIZE(x) == 0) THEN
      r = CD_ZERO
    ELSE
      r = MAXVAL(ABS(x))
    END IF
  END FUNCTION infnorm

  SUBROUTINE fail(ErrStat, ErrMsg, msg)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    CHARACTER(*), INTENT(IN)  :: msg
    ErrStat = CD_DYN_BADINPUT
    ErrMsg = 'CableDyn_Dynamic: '//msg
  END SUBROUTINE fail

  SUBROUTINE alloc_fail(ErrStat, ErrMsg, msg)
    !! Own-workspace allocation failure: distinct from bad input so the model wrapper and the
    !! coupling boundaries can report resource exhaustion rather than a generic solve failure.
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    CHARACTER(*), INTENT(IN)  :: msg
    ErrStat = CD_DYN_ALLOCFAIL
    ErrMsg = 'CableDyn_Dynamic: '//msg
  END SUBROUTINE alloc_fail

  SUBROUTINE fail_callback(ErrStat, ErrMsg, msg, sub_es)
    !! Map a failed load/added-mass callback (or a propagated residual status) onto the dynamic
    !! namespace, preserving an allocation failure the callback forwarded as CD_DYN_ALLOCFAIL
    !! instead of collapsing it to bad input.
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    CHARACTER(*), INTENT(IN)  :: msg
    INTEGER, INTENT(IN) :: sub_es
    IF (sub_es == CD_DYN_ALLOCFAIL) THEN
      ErrStat = CD_DYN_ALLOCFAIL
    ELSE
      ErrStat = CD_DYN_BADINPUT
    END IF
    ErrMsg = 'CableDyn_Dynamic: '//msg
  END SUBROUTINE fail_callback

END MODULE CableDyn_Dynamic
