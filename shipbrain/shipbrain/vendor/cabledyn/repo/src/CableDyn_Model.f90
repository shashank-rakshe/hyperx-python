! File: src/CableDyn_Model.f90
! SPDX-License-Identifier: Apache-2.0
! Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
MODULE CableDyn_Model
  !! Persistent solver model for the Fortran production core. This module is the
  !! lifecycle layer over the EI=0 cable dynamics path described in ARCHITECTURE.md
  !! `src/` and doc/coupling_boundary.md: callers initialise a model once, advance it
  !! by steps, query its state, and release it through one Fortran-native API. The
  !! OpenFAST shell and the C API call this layer rather than owning element arrays
  !! directly.
  !!
  !! Scope of this module:
  !!  * positions-only EI=0 line dynamics,
  !!  * line-object initialisation from CableDyn_Line sections/types,
  !!  * external, hydrodynamic, seabed, and constitutive (viscoelastic / Syrope) loads,
  !!  * optional prescribed motion on the declared fixed/coupled DOFs,
  !!  * generalized-alpha integration via CableDyn_Dynamic.
  !!
  !! The element, assembly, and time-integration kernels live in CableDyn_Dynamic,
  !! CableDyn_Assemble, and CableDyn_Mesh; this module owns the object boundary the
  !! OpenFAST and C shells consume.
  USE CableDyn_Precision, ONLY: wp, CD_ZERO, CD_ONE, CD_All_Finite, CD_Is_Finite
  USE CableDyn_Line, ONLY: CD_LineType, CD_LineSection, CD_Build_Line_Mesh, CD_LINE_OK
  USE CableDyn_Loads, ONLY: CD_Submerged_Weight, CD_Assemble_Distributed_Load, CD_Seabed_Penalty_Load
  USE CableDyn_Line, ONLY: CD_Nodal_Seabed_Stiffness
  USE CableDyn_CableElem, ONLY: CD_Compute_Cable_Element
  USE CableDyn_SeabedContact, ONLY: CD_Seabed_Normal_Law, CD_Seabed_Normal_Contact, CD_Seabed_Contact_Gate, &
                                    CD_SEABED_CONTACT_BLEND, &
                                    CD_Seabed_Friction_Stick_Slip, CD_Seabed_Friction_Aniso, &
                                    CD_Seabed_Friction_Mu_Dir, CD_FRICTION_STICK_SLIP
  USE CableDyn_Bathymetry, ONLY: CD_BathymetryType, CD_Init_Bathymetry, CD_Bathymetry_Is_Initialized, &
                                 CD_Bathymetry_Floor, CD_Bathymetry_Floor_Gradient, &
                                 CD_Bathymetry_Seabed_Load, CD_End_Bathymetry, CD_BATHY_OK
  USE CableDyn_Static, ONLY: CableSolverConfig, CableCurrentLoad, CD_StaticLineReport, CD_Static_Line_Equilibrium, &
                             CD_Static_Friction_Anchors, CD_Static_As_Laid_Reference, &
                             CD_STATIC_FRICTION_AS_LAID, CD_STATIC_FRICTION_NONE, &
                             CD_STATIC_OK
  USE CableDyn_Assemble, ONLY: CD_Assemble_Cable_Internal_Force, CD_Assemble_Cable_Mass, &
                               CD_Assemble_Cable_Tangent_Force, CD_Compute_Cable_Tension
  USE CableDyn_Damping, ONLY: CD_Cable_Axial_Damping_Load, CD_Cable_Axial_Damping_Force, &
                              CD_Axial_Damping_Element_Load, CD_Axial_Damping_Element_Force
  USE CableDyn_Viscoelastic, ONLY: CD_Viscoelastic_Params, CD_Viscoelastic_LoadDependent_EAD, &
                                   CD_Viscoelastic_Steady_State, CD_Viscoelastic_Element_Load, &
                                   CD_Viscoelastic_Element_Force, CD_Viscoelastic_Element_Tension, &
                                   CD_Viscoelastic_State_Advance, CD_VISCO_OK, CD_VISCO_BADINPUT, &
                                   CD_VISCO_TINY_LEN
  USE CableDyn_Syrope, ONLY: CD_SyropeType, CD_Syrope_Init, CD_Syrope_End, CD_Syrope_Is_Ready, &
                             CD_Syrope_Working_Curve, CD_Syrope_Rate_And_Tension, CD_Syrope_Branch_Divider, &
                             CD_Syrope_Element_Load, CD_Syrope_Check_Range, CD_SYROPE_OK, CD_SYROPE_NWC
  USE CableDyn_Hydro, ONLY: CD_CurrentGridType, CD_Cable_Morison_Drag_Load, CD_Cable_Morison_Drag_Force, &
                            CD_Morison_Drag_Element_Load, CD_Morison_Drag_Element_Force, &
                            CD_Cable_Froude_Krylov_Load, CD_Cable_Froude_Krylov_Force, &
                            CD_Froude_Krylov_Element_Load, CD_Froude_Krylov_Element_Force, &
                            CD_Cable_Buoyancy_Recovery_Load, CD_Cable_Buoyancy_Recovery_Force, &
                            CD_Buoyancy_Recovery_Element_Load, CD_Buoyancy_Recovery_Element_Force, &
                            CD_Cable_Added_Mass, CD_Cable_Added_Mass_Matrix, CD_Cable_Added_Mass_Force, &
                            CD_Added_Mass_Element, CD_Added_Mass_Element_Matrix, CD_Added_Mass_Element_Force, &
                            CD_Submerged_Fraction
  USE CableDyn_VIV, ONLY: CD_VIV_Node_Lift, CD_VIV_Crossflow_Motion, CD_VIV_Phase_Rate, CD_VIV_Mean_Square, &
                          CD_VIV_Wrap_Phase, CD_VIV_NM, CD_VIV_TWO_PI
  USE CableDyn_Dynamic, ONLY: GenAlphaConfig, CD_CableGenAlphaWorkspace, CD_Clear_GenAlpha_Workspace, &
                              CD_Cable_Initial_Acceleration, CD_Cable_Gen_Alpha_Step, CD_Cable_Step_Loads, &
                              CD_DYN_OK, CD_DYN_ALLOCFAIL, &
                              CD_EI0_SUBSTEPS_AUTO, CD_EI0_SUBSTEPS_OFF
  USE CableDyn_Mesh, ONLY: CD_Partition_Free_Dofs, CD_Validate_Connectivity
  USE, INTRINSIC :: ISO_FORTRAN_ENV, ONLY: int64
  USE CableDyn_Linalg, ONLY: CD_Solve_Dense_As_Banded, CD_Solve_Dense_As_Banded_Multiple, CD_Factor_Banded, &
                             CD_Solve_Factored_Banded_Multiple
  USE CableDyn_Profile, ONLY: CD_Profile_Count_Line_Step
  USE, INTRINSIC :: ISO_FORTRAN_ENV, ONLY: INT64
  IMPLICIT NONE
  PRIVATE

  PUBLIC :: CD_ModelType
  PUBLIC :: CD_SubstepStats
  PUBLIC :: CD_Init_Model
  PUBLIC :: CD_Init_Line_Model
  PUBLIC :: CD_Step_Model
  PUBLIC :: CD_Step_Model_Recovering
  PUBLIC :: CD_Get_Model_Substep_Counts
  PUBLIC :: CD_End_Model
  PUBLIC :: CD_Model_NCoupledDOF
  PUBLIC :: CD_Model_NDOF
  PUBLIC :: CD_Model_NElem
  PUBLIC :: CD_Get_Model_CoupledDofs
  PUBLIC :: CD_Get_Model_CoupledMotion
  PUBLIC :: CD_Get_Model_State
  PUBLIC :: CD_Model_Has_Viscoelastic
  PUBLIC :: CD_Get_Model_VE_Dl1
  PUBLIC :: CD_Set_Model_VE_Dl1
  PUBLIC :: CD_Model_Has_Syrope
  PUBLIC :: CD_Model_Has_Friction
  PUBLIC :: CD_Get_Model_Friction_Anchors
  PUBLIC :: CD_Set_Model_Friction_Anchors
  PUBLIC :: CD_Set_Model_Friction_Axial
  PUBLIC :: CD_Get_Model_Syrope_State
  PUBLIC :: CD_Set_Model_Syrope_State
  PUBLIC :: CD_Set_Model_VIV
  PUBLIC :: CD_Latch_Model_VIV_Window
  PUBLIC :: CD_Get_Model_VIV_State, CD_Set_Model_VIV_State, CD_Model_Has_VIV, CD_Get_Model_VIV_Lift
  PUBLIC :: CD_Get_Model_Tension
  PUBLIC :: CD_Get_Model_Internal_Rates
  PUBLIC :: CD_Get_Model_EndForces
  PUBLIC :: CD_Get_Model_EndNodeMassDiag
  PUBLIC :: CD_Get_Model_EndNodeAddedMass
  PUBLIC :: CD_Get_Model_EndNodeTangent
  PUBLIC :: CD_Model_Seabed_Point_Load
  PUBLIC :: CD_Set_Model_EndQuery
  PUBLIC :: CD_Get_Model_EndQuery
  PUBLIC :: CD_Update_Model_SegmentLength
  PUBLIC :: CD_ModelControlSaveType, CD_Save_Model_Control, CD_Restore_Model_Control
  PUBLIC :: CD_Calc_Model_CoupledLoads
  PUBLIC :: CD_Calc_Model_CoupledKinematicDerivatives
  PUBLIC :: CD_Calc_Model_CoupledAccelDerivative, CD_Update_Model_CoupledAccelDerivative
  PUBLIC :: CD_Calc_Model_CoupledEndMass
  PUBLIC :: CD_Update_Model_Hydro_Fields
  PUBLIC :: CD_Update_Model_External_Loads
  PUBLIC :: CD_Update_Model_CoupledMotion
  PUBLIC :: CD_Update_Model_Interior_State
  PUBLIC :: CD_Recompute_Model_Acceleration
  PUBLIC :: CD_Model_Is_Initialized
  PUBLIC :: CD_Copy_Model
  PUBLIC :: CD_Audit_Model_Step

  INTEGER, PARAMETER, PUBLIC :: CD_MODEL_OK = 0
  INTEGER, PARAMETER, PUBLIC :: CD_MODEL_BADINPUT = 1
  INTEGER, PARAMETER, PUBLIC :: CD_MODEL_SOLVEFAIL = 2
  INTEGER, PARAMETER, PUBLIC :: CD_MODEL_NOT_INITIALIZED = 3
  INTEGER, PARAMETER, PUBLIC :: CD_MODEL_ALLOCFAIL = 4
  INTEGER, PARAMETER :: MODEL_DEFAULT_MAX_SUBSTEPS = 1024
  ! Rotation- and snap-resolved sub-stepping (CD_Step_Model, cfg%ei0_substeps). The tension
  ! scale of a step is the largest step-start tension, floored at SUB_TAUT_FRACTION of the
  ! line's initial tension (sub_t_init, the largest at CD_Init_Model): a line slack all over at
  ! the step start would otherwise count any segment that ends it barely taut. (Flooring at the
  ! initial tension itself raised the snap threshold in the slack phases of the Lozon semitaut
  ! line, whose anchor snap peaks then came out up to 29 % high.) A segment that ends the step
  ! taut above SUB_TAUT_FRACTION of the scale counts for the turn (the run audit's floor), also
  ! when it was slack at the start:
  ! counting only segments taut at both ends left the Lozon semitaut anchor snap peaks up to
  ! 25 % high. One slack at the step start that ends above SUB_SNAP_FRACTION of the scale is a
  ! snap when the step does not resolve its axial wave (dt c/l0 > 1, c from the dynamic axial
  ! stiffness; a step that does resolves the snap as given). A step solved in sub-steps takes
  ! at least SUB_SNAP_STEPS of them: on the Lozon semitaut line two or three sub-steps of a step
  ! that turned 1 to 3 deg left the anchor snap peaks 8 % high on average (up to 22 %), four
  ! brought them within 3 % of the converged run. The tensions are those the run audit takes:
  ! the dynamic EA times the strain of an elastic segment, the law's tension of a viscoelastic
  ! or Syrope one.
  REAL(wp), PARAMETER :: SUB_TAUT_FRACTION = 1.0e-3_wp, SUB_SNAP_FRACTION = 0.25_wp
  INTEGER, PARAMETER :: SUB_SNAP_STEPS = 4

  ! The state a line step commits, as the sub-stepping (CD_Step_Model) saves it in its two
  ! slots. commit_state_copy holds the one list of that state.
  TYPE :: CD_ModelCommitSlot
    REAL(wp), ALLOCATABLE :: q(:), v(:), a(:), ve_dl_1(:), syrope_slow(:), syrope_tmax(:)
    REAL(wp), ALLOCATABLE :: fr_anchor(:, :), l0_c(:), l0_dot_c(:), viv_phi(:), viv_ms(:, :)
  END TYPE CD_ModelCommitSlot

  ! Diagnostics of the rotation- and snap-resolved sub-stepping (CD_Step_Model): calls counts
  ! the steps it examined, events those it solved in sub-steps (max_used the largest count),
  ! capped those whose turn needed more than cfg%ei0_substep_max, fallbacks those that returned
  ! to the plain step after a sub-step failed, remeasured those whose sub-stepped interval
  ! needed more sub-steps and was solved again. Only committed steps count: the line system
  ! rolls these back with the line states (CableDyn_System), and a stalled step that
  ! CD_Step_Model_Recovering takes again in its rungs (as given) is not counted.
  TYPE :: CD_SubstepStats
    INTEGER(int64) :: calls = 0, events = 0, capped = 0, fallbacks = 0, remeasured = 0
    INTEGER :: max_used = 1
  END TYPE CD_SubstepStats

  TYPE :: CD_ModelControlSaveType
    !! What CD_Update_Model_SegmentLength writes, as CD_Save_Model_Control found it.
    LOGICAL :: valid = .FALSE.
    REAL(wp), ALLOCATABLE :: l0(:), l0_dot(:), l0_c(:), l0_dot_c(:), f_ext(:), seabed_kn(:), seabed_cn(:)
  END TYPE CD_ModelControlSaveType

  TYPE :: model_lengths_aside
    !! The present lengths and rates, and the external load and seabed coefficients that follow
    !! the lengths, that enter_committed_lengths set aside (leave_committed_lengths moves them
    !! back).
    LOGICAL :: active = .FALSE.
    REAL(wp), ALLOCATABLE :: l0(:), l0_dot(:), f_ext(:), kn(:), cn(:)
  END TYPE model_lengths_aside

  ! The per-element and per-node kernels of the load and added-mass assemblies write messages of
  ! at most 187 characters (Hydro, Damping, Viscoelastic, Syrope, bathymetry and band-scatter texts,
  ! with their prefixes) and blank their message on entry, also when inputs_validated skips their
  ! input scan. They receive the first KERNEL_MSG_LEN characters of the caller's message buffer,
  ! so each call resets that much and not the whole (up to 1024-character) buffer.
  INTEGER, PARAMETER :: KERNEL_MSG_LEN = 200

  TYPE :: CD_ModelType
    !! Persistent positions-only EI=0 model state and immutable mesh/properties.
    LOGICAL :: initialized = .FALSE.
    LOGICAL :: tension_only = .FALSE.
    ! The range of the line's tangent azimuth channels: (-180, 180] when set, otherwise
    ! [0, 360) (the deck line's, set by the deck driver that builds the model).
    LOGICAL :: azimuth_signed = .FALSE.
    INTEGER :: n_dof = 0
    INTEGER :: n_elem = 0
    INTEGER, ALLOCATABLE :: elem_conn(:, :)
    INTEGER, ALLOCATABLE :: fixed_dofs(:)
    REAL(wp), ALLOCATABLE :: l0(:)
    REAL(wp), ALLOCATABLE :: ea(:)
    REAL(wp), ALLOCATABLE :: rho_a(:)
    ! Per-element unstretched-length rate (active line control; zero everywhere
    ! until CD_Update_Model_SegmentLength sets it). Feeds the axial-damping
    ! effective stretch rate.
    REAL(wp), ALLOCATABLE :: l0_dot(:)
    ! The unstretched lengths and rates the committed state was reached with (active line
    ! control), so the committed state keeps its own lengths in the generalised-alpha blend of
    ! the step that follows a length change (CD_Step_Model). With the force blend the step-start
    ! force takes l0_c and l0_dot_c (with the external load and seabed coefficients of l0_c),
    ! the end-of-step force the present lengths and rates, and only the inertia the blended
    ! lengths (1 - alpha_f) l0 + alpha_f l0_c; under False alpha_force_blend every alpha-level
    ! term takes the blended lengths and rates. Each successful step makes the present lengths
    ! the committed ones. l0_c_rollback / recovery_l0_c are the copies of the system
    ! stage-then-commit and of the recovering step.
    REAL(wp), ALLOCATABLE :: l0_c(:), l0_dot_c(:)
    REAL(wp), ALLOCATABLE :: l0_c_rollback(:), l0_dot_c_rollback(:), recovery_l0_c(:), recovery_l0_dot_c(:)
    ! Per-element distributed load per unit LENGTH (3, n_elem) plus the
    ! NON-distributed remainder of the init f_ext, stored when the caller supplies
    ! the per-length load: a segment-length update REASSEMBLES the distributed part
    ! from the current lengths (f_ext = remainder + assemble(dist_load, l0)), which
    ! is bit-identical to a fresh build -- a nodal delta (0.5*dl*w added to an
    ! existing share) is NOT, in floating point. Unallocated = no distributed load
    ! to track (point loads and zero f_ext are length-independent).
    REAL(wp), ALLOCATABLE :: dist_load(:, :)
    REAL(wp), ALLOCATABLE :: f_ext_dist_base(:)
    ! Seabed nodal-coefficient recompute inputs (active line control): when the
    ! caller supplies them, a segment-length update rebuilds seabed_kn (and cn via
    ! the stored ratio) through CD_Nodal_Seabed_Stiffness at the current lengths --
    ! the SAME helper the deck used, so a fresh build matches bit-for-bit. Without
    ! them a length update on a seabed model fails closed (a controlled grounded
    ! segment would otherwise keep its old tributary contact area).
    LOGICAL :: has_seabed_recompute = .FALSE.
    REAL(wp) :: seabed_kbot = CD_ZERO
    REAL(wp) :: seabed_cn_over_kn = CD_ZERO
    REAL(wp), ALLOCATABLE :: seabed_diameter_elem(:)
    REAL(wp), ALLOCATABLE :: f_ext(:)
    REAL(wp), ALLOCATABLE :: q(:)
    REAL(wp), ALLOCATABLE :: v(:)
    REAL(wp), ALLOCATABLE :: a(:)
    REAL(wp), ALLOCATABLE :: q_step(:)
    REAL(wp), ALLOCATABLE :: v_step(:)
    REAL(wp), ALLOCATABLE :: a_step(:)
    REAL(wp), ALLOCATABLE :: q_prescribed_work(:)
    REAL(wp), ALLOCATABLE :: v_prescribed_work(:)
    REAL(wp), ALLOCATABLE :: a_prescribed_work(:)
    REAL(wp), ALLOCATABLE :: q_rollback(:)
    REAL(wp), ALLOCATABLE :: v_rollback(:)
    REAL(wp), ALLOCATABLE :: a_rollback(:)
    ! Dedicated nominal-interval snapshot for CD_Step_Model_Recovering.  These
    ! arrays are separate from q_rollback/v_rollback/a_rollback, which belong to
    ! the multi-line system and transactional load-update contracts.
    REAL(wp), ALLOCATABLE :: recovery_q0(:)
    REAL(wp), ALLOCATABLE :: recovery_v0(:)
    REAL(wp), ALLOCATABLE :: recovery_a0(:)
    REAL(wp), ALLOCATABLE :: f_ext_rollback(:)
    INTEGER, ALLOCATABLE :: free_map_work(:)
    TYPE(CD_CableGenAlphaWorkspace) :: dynamic_workspace
    REAL(wp), ALLOCATABLE :: load_force_work(:)
    ! the load contributors at the committed state, the step-start share of the force-blended
    ! generalised-alpha residual (scratch, rebuilt every step)
    REAL(wp), ALLOCATABLE :: load_start_work(:)
    ! the tension of the viscoelastic and Syrope elements in load_start_work (n_elem, zero for
    ! the other elements; allocated only on a model with either law): the release cap of the
    ! force blend bounds their alpha_f share as it bounds that of the elastic elements
    REAL(wp), ALLOCATABLE :: tension_start_work(:)
    ! their axial stiffness at the committed state (EA_D/l0, Syrope K1/l0; n_elem, allocated
    ! with tension_start_work), which bounds the secant end tension of the release cap
    REAL(wp), ALLOCATABLE :: stiffness_start_work(:)
    ! load_start_work holds the committed-state load of the last step: a warm re-solve of the
    ! same step (the junction coupling, dynamic_workspace%guess_armed) reuses it
    LOGICAL :: load_start_valid = .FALSE.
    REAL(wp), ALLOCATABLE :: load_jq_work(:, :)
    REAL(wp), ALLOCATABLE :: load_jv_work(:, :)
    LOGICAL :: has_seabed = .FALSE.
    LOGICAL :: has_bathymetry = .FALSE.
    REAL(wp) :: seabed_z_floor = CD_ZERO
    TYPE(CD_BathymetryType) :: bathymetry
    REAL(wp), ALLOCATABLE :: seabed_kn(:)
    LOGICAL :: has_seabed_damping = .FALSE.
    REAL(wp), ALLOCATABLE :: seabed_cn(:)
    LOGICAL :: has_seabed_friction = .FALSE.
    REAL(wp) :: seabed_mu = CD_ZERO
    ! Anisotropic friction (CD_Set_Model_Friction_Axial): seabed_mu is then the lateral
    ! coefficient and seabed_mu_axial the one along the line (CD_Seabed_Friction_Aniso).
    LOGICAL :: seabed_friction_aniso = .FALSE.
    REAL(wp) :: seabed_mu_axial = CD_ZERO
    ! Stick-slip seabed friction (has_seabed_friction): the committed anchor (x, y) of each
    ! node's friction spring (stiffness seabed_kn, capacity mu times the normal reaction),
    ! a STATE like q, with its system-rollback and step-recovery twins.
    REAL(wp), ALLOCATABLE :: fr_anchor(:, :), fr_anchor_rollback(:, :), recovery_fr_anchor(:, :)
    LOGICAL :: has_damping = .FALSE.
    REAL(wp), ALLOCATABLE :: ba(:)
    ! Viscoelastic axial model (MoorDyn ElasticMod 2, two Kelvin branches in series):
    ! per-element parameters (ve_ea_d == 0 marks a plain element) and the
    ! committed static-branch stretch state dl_1. model%ea keeps the relaxed
    ! composite everywhere it means STATIC stiffness (tension recovery of plain
    ! elements, coupled fscale); the DYNAMIC structural assembly and the
    ! coupled-load residual use ea_dyn (viscoelastic entries zeroed) with the
    ! series-Kelvin load contributor supplying the full elastic + damping tension for
    ! those elements, and ba_dyn likewise masks the plain axial damping there
    ! (the static-branch dashpot Bs lives inside the series law). ve_dt carries the
    ! active step size into the contributors; 0 = the instantaneous
    ! (committed-state) limit used by IC, coupled-load, and tension queries.
    ! ve_dl_1 is a stretch [m], so an unstretched-length change (active line control) leaves
    ! it as it is, as MoorDyn's dl_1 (CD_Update_Model_SegmentLength).
    ! ve_dl_1_rollback is the system-level rollback twin of q_rollback: a line
    ! whose step committed (advancing dl_1) can be rolled back when a sibling
    ! line or the coupled point solve fails.
    ! ve_mode: 0 = plain element, 2 = constant dynamic stiffness (Es|Ed),
    ! 3 = mean-load-dependent dynamic stiffness (Es|alphaMBL|vbeta). Mode 3
    ! evaluates EA_D from the COMMITTED dl_1 (lagged over the step, so the
    ! in-step elimination Jacobians stay exact for the lagged operator).
    LOGICAL :: has_viscoelastic = .FALSE.
    INTEGER, ALLOCATABLE :: ve_mode(:)
    REAL(wp), ALLOCATABLE :: ve_alpha_mbl(:)
    REAL(wp), ALLOCATABLE :: ve_vbeta(:)
    REAL(wp), ALLOCATABLE :: ve_ea_d(:)
    REAL(wp), ALLOCATABLE :: ve_ea_1(:)
    REAL(wp), ALLOCATABLE :: ve_ba(:)
    REAL(wp), ALLOCATABLE :: ve_ba_d(:)
    REAL(wp), ALLOCATABLE :: ve_dl_1(:)
    REAL(wp), ALLOCATABLE :: ve_dl_1_rollback(:)
    REAL(wp), ALLOCATABLE :: recovery_ve_dl_1(:)
    REAL(wp), ALLOCATABLE :: ea_dyn(:)
    REAL(wp), ALLOCATABLE :: ba_dyn(:)
    REAL(wp) :: ve_dt = CD_ZERO
    ! Syrope polyester working-curve constitutive (the SYROPE deck dialect): a
    ! load-history-dependent alternative to the series-Kelvin law. syrope_is(:) marks the Syrope
    ! elements; syrope_type(:) holds each element's constitutive data (OWC
    ! table + working-curve shape + spring/dashpot constants -- immutable after
    ! init). syrope_slow is the committed slow-spring static strain (the STATE), a strain of
    ! the unstretched length the committed state was reached with (l0_c; after a length change
    ! by active line control the element reads it at its present length, model_syrope_slow),
    ! and syrope_tmax the running maximum mean tension (a second, monotone STATE
    ! whose growth regenerates the working curve on demand). Syrope elements
    ! share the ea_dyn/ba_dyn masking with the viscoelastic path (their elastic
    ! EA and plain damping are zeroed; the Syrope contributor supplies the
    ! tension, which has no direct velocity term). The _rollback twins mirror
    ! q_rollback for the system-level stage-then-commit contract.
    LOGICAL :: has_syrope = .FALSE.
    LOGICAL, ALLOCATABLE :: syrope_is(:)
    TYPE(CD_SyropeType), ALLOCATABLE :: syrope_type(:)
    REAL(wp), ALLOCATABLE :: syrope_slow(:)
    REAL(wp), ALLOCATABLE :: syrope_slow_rollback(:)
    REAL(wp), ALLOCATABLE :: syrope_tmax(:)
    REAL(wp), ALLOCATABLE :: syrope_tmax_rollback(:)
    REAL(wp), ALLOCATABLE :: recovery_syrope_slow(:)
    REAL(wp), ALLOCATABLE :: recovery_syrope_tmax(:)
    LOGICAL :: has_morison_drag = .FALSE.
    REAL(wp), ALLOCATABLE :: fluid_velocity(:, :)
    REAL(wp), ALLOCATABLE :: drag_waterline_z(:)
    REAL(wp) :: drag_rho = CD_ZERO
    REAL(wp) :: drag_diameter = CD_ZERO
    REAL(wp) :: drag_cdn = CD_ZERO
    REAL(wp) :: drag_cdt = CD_ZERO
    REAL(wp), ALLOCATABLE :: drag_diameter_elem(:)
    REAL(wp), ALLOCATABLE :: drag_cdn_elem(:)
    REAL(wp), ALLOCATABLE :: drag_cdt_elem(:)
    LOGICAL :: has_froude_krylov = .FALSE.
    REAL(wp), ALLOCATABLE :: fluid_acceleration(:, :)
    REAL(wp), ALLOCATABLE :: fk_waterline_z(:)
    REAL(wp) :: fk_rho = CD_ZERO
    REAL(wp) :: fk_diameter = CD_ZERO
    REAL(wp) :: fk_can = CD_ZERO
    REAL(wp) :: fk_cat = CD_ZERO
    REAL(wp), ALLOCATABLE :: fk_diameter_elem(:)
    REAL(wp), ALLOCATABLE :: fk_can_elem(:)
    REAL(wp), ALLOCATABLE :: fk_cat_elem(:)
    LOGICAL :: has_buoyancy_recovery = .FALSE.
    REAL(wp), ALLOCATABLE :: buoyancy_waterline_z(:)
    REAL(wp) :: buoyancy_rho = CD_ZERO
    REAL(wp) :: buoyancy_diameter = CD_ZERO
    REAL(wp) :: buoyancy_gravity = CD_ZERO
    REAL(wp), ALLOCATABLE :: buoyancy_diameter_elem(:)
    LOGICAL :: has_added_mass = .FALSE.
    REAL(wp), ALLOCATABLE :: added_mass_waterline_z(:)
    REAL(wp) :: added_mass_rho = CD_ZERO
    REAL(wp) :: added_mass_diameter = CD_ZERO
    REAL(wp) :: added_mass_can = CD_ZERO
    REAL(wp) :: added_mass_cat = CD_ZERO
    REAL(wp), ALLOCATABLE :: added_mass_diameter_elem(:)
    REAL(wp), ALLOCATABLE :: added_mass_can_elem(:)
    REAL(wp), ALLOCATABLE :: added_mass_cat_elem(:)
    ! Cross-flow vortex-induced vibration (CableDyn_VIV; MoorDyn LINE TYPES Cl dF cF),
    ! installed by CD_Set_Model_VIV after initialisation. Per element: the lift coefficient
    ! viv_cl (0 = no lift on that element) and diameter viv_d; viv_rho the water density.
    ! Per node: viv_node marks an interior free node next to a Cl > 0 element, with the
    ! synchronisation centre/range viv_cf/viv_df and diameter viv_dn (averaged over the
    ! node's Cl > 0 elements, weighted by unstretched length). The STATE is the shedding
    ! phase viv_phi and the running mean squares of the cross-flow velocity and
    ! acceleration viv_ms(1:2, node), with their system-rollback and step-recovery twins.
    ! viv_tw is the averaging time of the mean squares [s]; 0 until CD_Latch_Model_VIV_Window
    ! (or the first step) sets MoorDyn's 500 steps. viv_phi_eval is the phase the lift
    ! contributor uses: the committed phase, except inside CD_Step_Model, where it is the
    ! explicit generalised-alpha force-level phase. viv_rate (phase rate at the step start)
    ! and viv_ms_next (mean squares updated with the step-start sample) are step scratch.
    LOGICAL :: has_viv = .FALSE.
    ! the cross-flow phase of a node at rest (CD_VIV_Phase_Rate phi_rest): pi where the node
    ! tangent runs against MoorDyn's (End B to End A), 0 where it runs as MoorDyn's
    REAL(wp) :: viv_phi_rest = CD_ZERO
    REAL(wp) :: viv_rho = CD_ZERO
    REAL(wp) :: viv_tw = CD_ZERO
    REAL(wp), ALLOCATABLE :: viv_cl(:), viv_d(:)
    LOGICAL, ALLOCATABLE :: viv_node(:)
    REAL(wp), ALLOCATABLE :: viv_cf(:), viv_df(:), viv_dn(:)
    REAL(wp), ALLOCATABLE :: viv_phi(:), viv_ms(:, :)
    REAL(wp), ALLOCATABLE :: viv_phi_rollback(:), viv_ms_rollback(:, :)
    REAL(wp), ALLOCATABLE :: recovery_viv_phi(:), recovery_viv_ms(:, :)
    REAL(wp), ALLOCATABLE :: viv_phi_eval(:), viv_rate(:), viv_ms_next(:, :), viv_phi_next(:)
    TYPE(GenAlphaConfig) :: cfg
    ! Run audit of the committed host steps (CD_Audit_Model_Step), diagnostics only: never part
    ! of the state, of a copy, or of a result. audit_t holds the segment tensions of the last two
    ! audited states (column 1 the latest; the elastic tension, or that of the viscoelastic or
    ! Syrope law; -1 marks a segment whose law could not be evaluated), audit_u the unit chords
    ! of the latest one, audit_n how many states are held (0 to 2). audit_floor is the largest
    ! tension of the first audited state (the initial state: the driver audits it before its
    ! march). audit_max_turn is the largest turn of a taut segment's chord in one step (deg),
    ! audit_snaps the segments that went from slack to taut above audit_floor in one step and
    ! audit_snap_courant the largest dt*c/l0 (c the axial wave speed) among them. audit_spikes
    ! counts the implausible tension spikes, the first one recorded with its time, segment,
    ! tension and ratio to the largest tension of the line one step before and after.
    INTEGER :: audit_n = 0
    REAL(wp), ALLOCATABLE :: audit_t(:, :), audit_u(:, :), audit_now(:)
    REAL(wp) :: audit_time = CD_ZERO, audit_floor = CD_ZERO, audit_max_turn = CD_ZERO
    REAL(wp) :: audit_snap_courant = CD_ZERO
    INTEGER :: audit_snaps = 0, audit_spikes = 0, audit_spike_elem = 0
    REAL(wp) :: audit_spike_time = CD_ZERO, audit_spike_tension = CD_ZERO, audit_spike_ratio = CD_ZERO
    ! audit_hmax: the largest single solver step committed since the last audit (the nominal
    ! step, or a sub-step of the resolved or the recovering step); the audit measures turns and
    ! axial wave crossings per solver step with it. Diagnostics only.
    REAL(wp) :: audit_hmax = CD_ZERO
    ! Rotation- and snap-resolved sub-stepping (CD_Step_Model): sub_stats its diagnostics and
    ! sub_stats_rollback their twin at the last save of the system-rollback state
    ! (CableDyn_System). sub_t_init is the line's initial tension, which floors the tension
    ! scale of a step (SUB_TAUT_FRACTION of it; the largest segment tension at CD_Init_Model, a
    ! parameter of the line, copied with the model). The other sub_* arrays are scratch:
    ! sub_slot(1) the committed state at the step start, sub_slot(2) the state the plain step
    ! reached, sub_t0 and sub_t1 the segment tensions at the step start and end, and
    ! sub_pq/pv/pa the sub-step boundary motion, sub_target the lengths, rates, external load
    ! and seabed coefficients a pending length change (active line control) sets for the end of
    ! the step (CD_Save_Model_Control).
    TYPE(CD_SubstepStats) :: sub_stats, sub_stats_rollback
    REAL(wp) :: sub_t_init = CD_ZERO
    ! audit_hmax at the last save of the system-rollback state (CableDyn_System)
    REAL(wp) :: audit_hmax_rollback = CD_ZERO
    TYPE(CD_ModelCommitSlot) :: sub_slot(2)
    REAL(wp), ALLOCATABLE :: sub_t0(:), sub_t1(:), sub_pq(:), sub_pv(:), sub_pa(:)
    TYPE(CD_ModelControlSaveType) :: sub_target
    ! TEST-ONLY hooks of the sub-stepping, never set by a production caller: sub_test_fail > 0
    ! makes sub-step number sub_test_fail of every sub-stepped pass report a failure, and
    ! sub_test_repeat solves the first sub-stepped pass twice (the second from the restored
    ! committed state), which must not change the result; sub_test_more makes the re-measure of
    ! every sub-stepped interval ask for one more sub-step.
    INTEGER :: sub_test_fail = 0
    LOGICAL :: sub_test_repeat = .FALSE., sub_test_more = .FALSE.
  END TYPE CD_ModelType

  !> The load contributors and added mass of a model as the dynamic loads of its steps
  !> (CD_Cable_Step_Loads): the integrator calls them on the model this object points to, with
  !> the added mass on the lengths l0_mass when associated (the blended lengths of the inertia
  !> after a length change under the force blend). The model passes this object, never
  !> internal procedures, so that distinct models step concurrently (see CD_Cable_Step_Loads).
  TYPE, EXTENDS(CD_Cable_Step_Loads) :: model_step_loads
    TYPE(CD_ModelType), POINTER :: model => NULL()
    REAL(wp), POINTER :: l0_mass(:) => NULL()
  CONTAINS
    PROCEDURE :: force => model_step_force
    PROCEDURE :: load_banded => model_step_load_banded
    PROCEDURE :: added_mass_banded => model_step_added_mass_banded
  END TYPE model_step_loads

CONTAINS

  SUBROUTINE CD_Init_Model(model, q0, v0, elem_conn, l0, ea, rho_a, tension_only, &
                           f_ext, fixed_dofs, cfg, ErrStat, ErrMsg, seabed_z_floor, seabed_kn, seabed_cn, &
                           seabed_mu, ba, &
                           fluid_velocity, drag_waterline_z, drag_rho, drag_diameter, drag_cdn, drag_cdt, &
                           drag_diameter_elem, drag_cdn_elem, drag_cdt_elem, &
                           fluid_acceleration, fk_waterline_z, fk_rho, fk_diameter, fk_can, fk_cat, &
                           fk_diameter_elem, fk_can_elem, fk_cat_elem, &
                           buoyancy_waterline_z, buoyancy_rho, buoyancy_diameter, buoyancy_gravity, &
                           buoyancy_diameter_elem, &
                           added_mass_waterline_z, added_mass_rho, added_mass_diameter, added_mass_can, &
                           added_mass_cat, added_mass_diameter_elem, added_mass_can_elem, added_mass_cat_elem, &
                           bathymetry, &
                           dist_load_per_length, seabed_kbot, seabed_contact_diameter, seabed_cn_over_kn, &
                           ve_ea_d, ve_ba, ve_ba_d, ve_alpha_mbl, ve_vbeta, &
                           syrope_is, syrope_type, syrope_slow0, syrope_tmax0)
    !! Initialise a persistent EI=0 cable model from already-meshed arrays. The
    !! initial acceleration is computed consistently from the current structure,
    !! load, and fixed DOFs; callers do not provide a0. Existing model storage is
    !! released before the new model is populated.
    TYPE(CD_ModelType), INTENT(INOUT), TARGET :: model
    REAL(wp), INTENT(IN) :: q0(:), v0(:)
    INTEGER, INTENT(IN) :: elem_conn(:, :)
    REAL(wp), INTENT(IN) :: l0(:), ea(:), rho_a(:)
    LOGICAL, INTENT(IN) :: tension_only
    REAL(wp), INTENT(IN) :: f_ext(:)
    INTEGER, INTENT(IN) :: fixed_dofs(:)
    TYPE(GenAlphaConfig), INTENT(IN) :: cfg
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    REAL(wp), INTENT(IN), OPTIONAL :: seabed_z_floor
    REAL(wp), INTENT(IN), OPTIONAL :: seabed_kn(:)
    REAL(wp), INTENT(IN), OPTIONAL :: seabed_cn(:)
    REAL(wp), INTENT(IN), OPTIONAL :: seabed_mu
    REAL(wp), INTENT(IN), OPTIONAL :: ba(:)
    ! Per-element distributed load per unit length (3, n_elem): stored so runtime
    ! segment-length updates (active line control) can rescale f_ext exactly.
    REAL(wp), INTENT(IN), OPTIONAL :: dist_load_per_length(:, :)
    ! Seabed recompute inputs (see the type note): kBot, per-element contact
    ! diameter, and the cn/kn ratio.
    REAL(wp), INTENT(IN), OPTIONAL :: seabed_kbot, seabed_cn_over_kn
    REAL(wp), INTENT(IN), OPTIONAL :: seabed_contact_diameter(:)
    REAL(wp), INTENT(IN), OPTIONAL :: fluid_velocity(:, :)
    REAL(wp), INTENT(IN), OPTIONAL :: drag_waterline_z(:), drag_rho, drag_diameter, drag_cdn, drag_cdt
    REAL(wp), INTENT(IN), OPTIONAL :: drag_diameter_elem(:), drag_cdn_elem(:), drag_cdt_elem(:)
    REAL(wp), INTENT(IN), OPTIONAL :: fluid_acceleration(:, :)
    REAL(wp), INTENT(IN), OPTIONAL :: fk_waterline_z(:), fk_rho, fk_diameter, fk_can, fk_cat
    REAL(wp), INTENT(IN), OPTIONAL :: fk_diameter_elem(:), fk_can_elem(:), fk_cat_elem(:)
    REAL(wp), INTENT(IN), OPTIONAL :: buoyancy_waterline_z(:), buoyancy_rho, buoyancy_diameter, buoyancy_gravity
    REAL(wp), INTENT(IN), OPTIONAL :: buoyancy_diameter_elem(:)
    REAL(wp), INTENT(IN), OPTIONAL :: added_mass_waterline_z(:)
    REAL(wp), INTENT(IN), OPTIONAL :: added_mass_rho, added_mass_diameter, added_mass_can, added_mass_cat
    REAL(wp), INTENT(IN), OPTIONAL :: added_mass_diameter_elem(:), added_mass_can_elem(:), added_mass_cat_elem(:)
    TYPE(CD_BathymetryType), INTENT(IN), OPTIONAL :: bathymetry
    ! Viscoelastic per-element parameters (MoorDyn ElasticMod 2/3): ve_ea_d > 0
    ! marks a constant-Ed element (mode 2); ve_alpha_mbl > 0 with ve_vbeta > 0
    ! marks a mean-load-dependent element (mode 3); zero everywhere = plain.
    ! One element cannot carry both. ve_ba is the static-branch dashpot Bs and
    ! ve_ba_d the dynamic-branch Bd; the first three arrays must be supplied
    ! together (the mode-3 pair together too). For viscoelastic elements the
    ! plain axial damping ba is REPLACED by the series-Kelvin law (ve_ba carries the Bs the
    ! MoorDyn BA column would have supplied).
    REAL(wp), INTENT(IN), OPTIONAL :: ve_ea_d(:), ve_ba(:), ve_ba_d(:)
    REAL(wp), INTENT(IN), OPTIONAL :: ve_alpha_mbl(:), ve_vbeta(:)
    ! Syrope per-element data: syrope_is(e) marks a Syrope element,
    ! syrope_type(e) its (already-initialized) constitutive data, syrope_slow0
    ! the committed slow-strain IC (the caller sets it -- for a fixed point,
    ! the steady partition of the initial stretch), and syrope_tmax0 the initial
    ! running-maximum mean tension. All four are supplied together.
    LOGICAL, INTENT(IN), OPTIONAL :: syrope_is(:)
    TYPE(CD_SyropeType), INTENT(IN), OPTIONAL :: syrope_type(:)
    REAL(wp), INTENT(IN), OPTIONAL :: syrope_slow0(:), syrope_tmax0(:)

    INTEGER :: n_dof, n_elem, n_nodes, es, istat, e
    INTEGER, ALLOCATABLE :: free(:)
    TYPE(CD_ModelType) :: old_model
    TYPE(model_step_loads) :: step_loads
    CHARACTER(1024) :: em
    LOGICAL :: use_seabed, use_seabed_damping, use_seabed_friction
    LOGICAL :: use_damping, use_drag, use_fk, use_buoyancy, use_added_mass, has_load
    LOGICAL :: use_viscoelastic, use_syrope
    LOGICAL :: scalar_drag, elem_drag, scalar_fk, elem_fk, scalar_buoyancy, elem_buoyancy
    LOGICAL :: scalar_added_mass, elem_added_mass
    REAL(wp) :: syrope_ws(CD_SYROPE_NWC), syrope_wt(CD_SYROPE_NWC), syrope_wsl(CD_SYROPE_NWC)

    ErrStat = CD_MODEL_OK
    ErrMsg = ''
    ! Drop transient solver scratch before the rollback snapshot. The dense load-contributor work
    ! matrices and the gen-alpha workspace are rebuilt on demand and are intentionally excluded from
    ! CD_Copy_Model; letting the intrinsic old_model = model snapshot deep-copy them would duplicate
    ! n_dof x n_dof arrays through an unchecked assignment on every reinitialization (and can abort
    ! under memory pressure before any checked allocation runs).
    CALL clear_model_load_contributor_workspace(model)
    CALL CD_Clear_GenAlpha_Workspace(model%dynamic_workspace)
    CALL clear_model_audit(model)
    old_model = model

    n_dof = SIZE(q0)
    n_elem = SIZE(elem_conn, 2)
    n_nodes = n_dof/3
    IF (MOD(n_dof, 3) /= 0 .OR. n_dof < 6) THEN
      CALL fail(ErrStat, ErrMsg, 'q0 must be a positions-only state of shape (3 n_nodes), n_nodes >= 2')
      RETURN
    END IF
    IF (SIZE(v0) /= n_dof .OR. SIZE(f_ext) /= n_dof) THEN
      CALL fail(ErrStat, ErrMsg, 'q0, v0, and f_ext must share shape (3 n_nodes)')
      RETURN
    END IF
    IF (n_elem < 1 .OR. SIZE(elem_conn, 1) /= 2) THEN
      CALL fail(ErrStat, ErrMsg, 'elem_conn must have shape (2, n_elem), n_elem >= 1')
      RETURN
    END IF
    IF (SIZE(l0) /= n_elem .OR. SIZE(ea) /= n_elem .OR. SIZE(rho_a) /= n_elem) THEN
      CALL fail(ErrStat, ErrMsg, 'l0, ea, and rho_a must have shape (n_elem)')
      RETURN
    END IF
    IF (.NOT. CD_All_Finite(q0) .OR. .NOT. CD_All_Finite(v0) &
        .OR. .NOT. CD_All_Finite(f_ext)) THEN
      CALL fail(ErrStat, ErrMsg, 'q0, v0, and f_ext must be finite')
      RETURN
    END IF
    IF (.NOT. CD_All_Finite(l0) .OR. ANY(l0 <= CD_ZERO) &
        .OR. .NOT. CD_All_Finite(ea) .OR. ANY(ea <= CD_ZERO) &
        .OR. .NOT. CD_All_Finite(rho_a) .OR. ANY(rho_a <= CD_ZERO)) THEN
      CALL fail(ErrStat, ErrMsg, 'l0, ea, and rho_a must be finite and positive')
      RETURN
    END IF
    ! the rotation- and snap-resolved sub-stepping settings (CD_Step_Model reads them per step)
    IF (cfg%ei0_substeps /= CD_EI0_SUBSTEPS_AUTO .AND. cfg%ei0_substeps /= CD_EI0_SUBSTEPS_OFF) THEN
      CALL fail(ErrStat, ErrMsg, 'cfg%ei0_substeps must be CD_EI0_SUBSTEPS_AUTO or CD_EI0_SUBSTEPS_OFF')
      RETURN
    END IF
    IF (.NOT. (CD_Is_Finite(cfg%ei0_substep_angle) .AND. cfg%ei0_substep_angle > CD_ZERO .AND. &
               cfg%ei0_substep_angle <= 90.0_wp .AND. cfg%ei0_substep_max >= 2 .AND. &
               cfg%ei0_substep_max <= 1024)) THEN
      CALL fail(ErrStat, ErrMsg, 'ei0_substep_angle must lie in (0, 90] deg and ei0_substep_max in [2, 1024]')
      RETURN
    END IF
    IF (ANY(elem_conn < 1) .OR. ANY(elem_conn > n_dof/3)) THEN
      CALL fail(ErrStat, ErrMsg, 'elem_conn contains a node index outside q0')
      RETURN
    END IF
    CALL CD_Partition_Free_Dofs(fixed_dofs, n_dof, free, es, em)
    IF (es /= 0) THEN
      CALL fail(ErrStat, ErrMsg, 'fixed_dofs rejected: '//TRIM(em))
      RETURN
    END IF
    IF (PRESENT(seabed_kn) .NEQV. (PRESENT(seabed_z_floor) .OR. PRESENT(bathymetry))) THEN
      CALL fail(ErrStat, ErrMsg, 'seabed requires seabed_kn with either seabed_z_floor or bathymetry')
      RETURN
    END IF
    IF (PRESENT(seabed_z_floor) .AND. PRESENT(bathymetry)) THEN
      CALL fail(ErrStat, ErrMsg, 'seabed_z_floor and bathymetry are mutually exclusive')
      RETURN
    END IF
    use_seabed = PRESENT(seabed_kn)
    use_seabed_damping = PRESENT(seabed_cn)
    use_seabed_friction = PRESENT(seabed_mu)
    use_damping = PRESENT(ba)
    use_drag = PRESENT(fluid_velocity) .OR. PRESENT(drag_waterline_z) .OR. PRESENT(drag_rho) .OR. &
               PRESENT(drag_diameter) .OR. PRESENT(drag_cdn) .OR. PRESENT(drag_cdt) .OR. &
               PRESENT(drag_diameter_elem) .OR. PRESENT(drag_cdn_elem) .OR. PRESENT(drag_cdt_elem)
    use_fk = PRESENT(fluid_acceleration) .OR. PRESENT(fk_waterline_z) .OR. PRESENT(fk_rho) .OR. &
             PRESENT(fk_diameter) .OR. PRESENT(fk_can) .OR. PRESENT(fk_cat) .OR. &
             PRESENT(fk_diameter_elem) .OR. PRESENT(fk_can_elem) .OR. PRESENT(fk_cat_elem)
    use_buoyancy = PRESENT(buoyancy_waterline_z) .OR. PRESENT(buoyancy_rho) .OR. &
                   PRESENT(buoyancy_diameter) .OR. PRESENT(buoyancy_gravity) .OR. &
                   PRESENT(buoyancy_diameter_elem)
    use_added_mass = PRESENT(added_mass_waterline_z) .OR. PRESENT(added_mass_rho) .OR. &
                     PRESENT(added_mass_diameter) .OR. PRESENT(added_mass_can) .OR. &
                     PRESENT(added_mass_cat) .OR. PRESENT(added_mass_diameter_elem) .OR. &
                     PRESENT(added_mass_can_elem) .OR. PRESENT(added_mass_cat_elem)
    scalar_drag = .FALSE.
    elem_drag = .FALSE.
    scalar_fk = .FALSE.
    elem_fk = .FALSE.
    scalar_buoyancy = .FALSE.
    elem_buoyancy = .FALSE.
    scalar_added_mass = .FALSE.
    elem_added_mass = .FALSE.
    IF (use_seabed) THEN
      IF (PRESENT(seabed_z_floor)) THEN
        IF (.NOT. CD_Is_Finite(seabed_z_floor)) THEN
          CALL fail(ErrStat, ErrMsg, 'seabed_z_floor must be finite')
          RETURN
        END IF
      ELSE
        IF (.NOT. CD_Bathymetry_Is_Initialized(bathymetry)) THEN
          CALL fail(ErrStat, ErrMsg, 'bathymetry seabed requires an initialized bathymetry object')
          RETURN
        END IF
      END IF
      IF (SIZE(seabed_kn) /= n_nodes) THEN
        CALL fail(ErrStat, ErrMsg, 'seabed_kn must have shape (n_nodes)')
        RETURN
      END IF
      IF (.NOT. CD_All_Finite(seabed_kn) .OR. ANY(seabed_kn <= CD_ZERO)) THEN
        CALL fail(ErrStat, ErrMsg, 'seabed_kn must be finite and positive')
        RETURN
      END IF
    END IF
    IF (use_seabed_damping) THEN
      IF (.NOT. use_seabed) THEN
        CALL fail(ErrStat, ErrMsg, 'seabed_cn requires seabed_z_floor and seabed_kn')
        RETURN
      END IF
      IF (SIZE(seabed_cn) /= n_nodes) THEN
        CALL fail(ErrStat, ErrMsg, 'seabed_cn must have shape (n_nodes)')
        RETURN
      END IF
      IF (.NOT. CD_All_Finite(seabed_cn) .OR. ANY(seabed_cn < CD_ZERO)) THEN
        CALL fail(ErrStat, ErrMsg, 'seabed_cn must be finite and non-negative')
        RETURN
      END IF
    END IF
    IF (use_seabed_friction) THEN
      IF (.NOT. use_seabed) THEN
        CALL fail(ErrStat, ErrMsg, 'seabed_mu requires seabed_z_floor and seabed_kn')
        RETURN
      END IF
      IF (.NOT. CD_Is_Finite(seabed_mu) .OR. seabed_mu < CD_ZERO) THEN
        CALL fail(ErrStat, ErrMsg, 'seabed_mu must be finite and non-negative')
        RETURN
      END IF
      use_seabed_friction = seabed_mu > CD_ZERO
    END IF
    IF (use_damping) THEN
      IF (SIZE(ba) /= n_elem) THEN
        CALL fail(ErrStat, ErrMsg, 'ba must have shape (n_elem)')
        RETURN
      END IF
      IF (.NOT. CD_All_Finite(ba) .OR. ANY(ba < CD_ZERO)) THEN
        CALL fail(ErrStat, ErrMsg, 'ba must be finite and non-negative')
        RETURN
      END IF
    END IF
    IF (use_drag) THEN
      scalar_drag = PRESENT(drag_diameter) .AND. PRESENT(drag_cdn) .AND. PRESENT(drag_cdt)
      elem_drag = PRESENT(drag_diameter_elem) .AND. PRESENT(drag_cdn_elem) .AND. PRESENT(drag_cdt_elem)
      IF (.NOT. (PRESENT(fluid_velocity) .AND. PRESENT(drag_waterline_z) .AND. PRESENT(drag_rho) .AND. &
                 (scalar_drag .OR. elem_drag))) THEN
        CALL fail(ErrStat, ErrMsg, &
                  'Morison drag requires fluid_velocity, waterline_z, rho, and scalar or per-element D/Cdn/Cdt')
        RETURN
      END IF
      IF (scalar_drag .AND. elem_drag) THEN
        CALL fail(ErrStat, ErrMsg, 'Morison drag accepts either scalar or per-element coefficients, not both')
        RETURN
      END IF
      IF (SIZE(fluid_velocity, 1) /= 3 .OR. SIZE(fluid_velocity, 2) /= n_nodes) THEN
        CALL fail(ErrStat, ErrMsg, 'fluid_velocity must have shape (3, n_nodes)')
        RETURN
      END IF
      IF (SIZE(drag_waterline_z) /= n_nodes) THEN
        CALL fail(ErrStat, ErrMsg, 'drag_waterline_z must have shape (n_nodes)')
        RETURN
      END IF
      IF (.NOT. CD_All_Finite(fluid_velocity) .OR. .NOT. CD_All_Finite(drag_waterline_z)) THEN
        CALL fail(ErrStat, ErrMsg, 'fluid_velocity and drag_waterline_z must be finite')
        RETURN
      END IF
      IF (.NOT. (CD_Is_Finite(drag_rho) .AND. drag_rho > CD_ZERO)) THEN
        CALL fail(ErrStat, ErrMsg, 'Morison drag rho must be finite and positive')
        RETURN
      END IF
      IF (scalar_drag) THEN
        IF (.NOT. (CD_Is_Finite(drag_diameter) .AND. drag_diameter > CD_ZERO .AND. &
                   CD_Is_Finite(drag_cdn) .AND. drag_cdn >= CD_ZERO .AND. &
                   CD_Is_Finite(drag_cdt) .AND. drag_cdt >= CD_ZERO)) THEN
          CALL fail(ErrStat, ErrMsg, &
                    'Morison drag scalars must be finite with positive diameter and non-negative Cd')
          RETURN
        END IF
      ELSE
        CALL validate_positive_vector(drag_diameter_elem, n_elem, 'drag_diameter_elem', ErrStat, ErrMsg)
        IF (ErrStat /= CD_MODEL_OK) RETURN
        CALL validate_nonnegative_vector(drag_cdn_elem, n_elem, 'drag_cdn_elem', ErrStat, ErrMsg)
        IF (ErrStat /= CD_MODEL_OK) RETURN
        CALL validate_nonnegative_vector(drag_cdt_elem, n_elem, 'drag_cdt_elem', ErrStat, ErrMsg)
        IF (ErrStat /= CD_MODEL_OK) RETURN
      END IF
    END IF
    IF (use_fk) THEN
      scalar_fk = PRESENT(fk_diameter) .AND. PRESENT(fk_can) .AND. PRESENT(fk_cat)
      elem_fk = PRESENT(fk_diameter_elem) .AND. PRESENT(fk_can_elem) .AND. PRESENT(fk_cat_elem)
      IF (.NOT. (PRESENT(fluid_acceleration) .AND. PRESENT(fk_waterline_z) .AND. PRESENT(fk_rho) .AND. &
                 (scalar_fk .OR. elem_fk))) THEN
        CALL fail(ErrStat, ErrMsg, &
                  'Froude-Krylov requires fluid_acceleration, waterline_z, rho, and scalar or per-element D/Can/Cat')
        RETURN
      END IF
      IF (scalar_fk .AND. elem_fk) THEN
        CALL fail(ErrStat, ErrMsg, 'Froude-Krylov accepts either scalar or per-element coefficients, not both')
        RETURN
      END IF
      IF (SIZE(fluid_acceleration, 1) /= 3 .OR. SIZE(fluid_acceleration, 2) /= n_nodes) THEN
        CALL fail(ErrStat, ErrMsg, 'fluid_acceleration must have shape (3, n_nodes)')
        RETURN
      END IF
      IF (SIZE(fk_waterline_z) /= n_nodes) THEN
        CALL fail(ErrStat, ErrMsg, 'fk_waterline_z must have shape (n_nodes)')
        RETURN
      END IF
      IF (.NOT. CD_All_Finite(fluid_acceleration) .OR. .NOT. CD_All_Finite(fk_waterline_z)) THEN
        CALL fail(ErrStat, ErrMsg, 'fluid_acceleration and fk_waterline_z must be finite')
        RETURN
      END IF
      IF (.NOT. (CD_Is_Finite(fk_rho) .AND. fk_rho > CD_ZERO)) THEN
        CALL fail(ErrStat, ErrMsg, 'Froude-Krylov rho must be finite and positive')
        RETURN
      END IF
      IF (scalar_fk) THEN
        IF (.NOT. (CD_Is_Finite(fk_diameter) .AND. fk_diameter > CD_ZERO .AND. &
                   CD_Is_Finite(fk_can) .AND. fk_can >= CD_ZERO .AND. &
                   CD_Is_Finite(fk_cat) .AND. fk_cat >= CD_ZERO)) THEN
          CALL fail(ErrStat, ErrMsg, &
                    'Froude-Krylov scalars must be finite with positive diameter and non-negative Ca')
          RETURN
        END IF
      ELSE
        CALL validate_positive_vector(fk_diameter_elem, n_elem, 'fk_diameter_elem', ErrStat, ErrMsg)
        IF (ErrStat /= CD_MODEL_OK) RETURN
        CALL validate_nonnegative_vector(fk_can_elem, n_elem, 'fk_can_elem', ErrStat, ErrMsg)
        IF (ErrStat /= CD_MODEL_OK) RETURN
        CALL validate_nonnegative_vector(fk_cat_elem, n_elem, 'fk_cat_elem', ErrStat, ErrMsg)
        IF (ErrStat /= CD_MODEL_OK) RETURN
      END IF
    END IF
    IF (use_buoyancy) THEN
      scalar_buoyancy = PRESENT(buoyancy_diameter)
      elem_buoyancy = PRESENT(buoyancy_diameter_elem)
      IF (.NOT. (PRESENT(buoyancy_waterline_z) .AND. PRESENT(buoyancy_rho) .AND. &
                 PRESENT(buoyancy_gravity) .AND. (scalar_buoyancy .OR. elem_buoyancy))) THEN
        CALL fail(ErrStat, ErrMsg, &
                  'buoyancy recovery requires waterline_z, rho, gravity, and scalar or per-element diameter')
        RETURN
      END IF
      IF (scalar_buoyancy .AND. elem_buoyancy) THEN
        CALL fail(ErrStat, ErrMsg, 'buoyancy recovery accepts either scalar or per-element diameter, not both')
        RETURN
      END IF
      IF (SIZE(buoyancy_waterline_z) /= n_nodes) THEN
        CALL fail(ErrStat, ErrMsg, 'buoyancy_waterline_z must have shape (n_nodes)')
        RETURN
      END IF
      IF (.NOT. CD_All_Finite(buoyancy_waterline_z)) THEN
        CALL fail(ErrStat, ErrMsg, 'buoyancy_waterline_z must be finite')
        RETURN
      END IF
      IF (.NOT. (CD_Is_Finite(buoyancy_rho) .AND. buoyancy_rho > CD_ZERO .AND. &
                 CD_Is_Finite(buoyancy_gravity) .AND. buoyancy_gravity > CD_ZERO)) THEN
        CALL fail(ErrStat, ErrMsg, 'buoyancy recovery rho and gravity must be finite and positive')
        RETURN
      END IF
      IF (scalar_buoyancy) THEN
        IF (.NOT. (CD_Is_Finite(buoyancy_diameter) .AND. buoyancy_diameter > CD_ZERO)) THEN
          CALL fail(ErrStat, ErrMsg, 'buoyancy recovery diameter must be finite and positive')
          RETURN
        END IF
      ELSE
        CALL validate_positive_vector(buoyancy_diameter_elem, n_elem, 'buoyancy_diameter_elem', ErrStat, ErrMsg)
        IF (ErrStat /= CD_MODEL_OK) RETURN
      END IF
    END IF
    IF (use_added_mass) THEN
      scalar_added_mass = PRESENT(added_mass_diameter) .AND. PRESENT(added_mass_can) .AND. PRESENT(added_mass_cat)
      elem_added_mass = PRESENT(added_mass_diameter_elem) .AND. PRESENT(added_mass_can_elem) .AND. &
                        PRESENT(added_mass_cat_elem)
      IF (.NOT. (PRESENT(added_mass_waterline_z) .AND. PRESENT(added_mass_rho) .AND. &
                 (scalar_added_mass .OR. elem_added_mass))) THEN
        CALL fail(ErrStat, ErrMsg, &
                  'added mass requires waterline_z, rho, and scalar or per-element D/Can/Cat')
        RETURN
      END IF
      IF (scalar_added_mass .AND. elem_added_mass) THEN
        CALL fail(ErrStat, ErrMsg, 'added mass accepts either scalar or per-element coefficients, not both')
        RETURN
      END IF
      IF (SIZE(added_mass_waterline_z) /= n_nodes) THEN
        CALL fail(ErrStat, ErrMsg, 'added_mass_waterline_z must have shape (n_nodes)')
        RETURN
      END IF
      IF (.NOT. CD_All_Finite(added_mass_waterline_z)) THEN
        CALL fail(ErrStat, ErrMsg, 'added_mass_waterline_z must be finite')
        RETURN
      END IF
      IF (.NOT. (CD_Is_Finite(added_mass_rho) .AND. added_mass_rho > CD_ZERO)) THEN
        CALL fail(ErrStat, ErrMsg, 'added-mass rho must be finite and positive')
        RETURN
      END IF
      IF (scalar_added_mass) THEN
        IF (.NOT. (CD_Is_Finite(added_mass_diameter) .AND. added_mass_diameter > CD_ZERO .AND. &
                   CD_Is_Finite(added_mass_can) .AND. added_mass_can >= CD_ZERO .AND. &
                   CD_Is_Finite(added_mass_cat) .AND. added_mass_cat >= CD_ZERO)) THEN
          CALL fail(ErrStat, ErrMsg, &
                    'added-mass scalars must be finite with positive diameter and non-negative Ca')
          RETURN
        END IF
      ELSE
        CALL validate_positive_vector(added_mass_diameter_elem, n_elem, 'added_mass_diameter_elem', ErrStat, ErrMsg)
        IF (ErrStat /= CD_MODEL_OK) RETURN
        CALL validate_nonnegative_vector(added_mass_can_elem, n_elem, 'added_mass_can_elem', ErrStat, ErrMsg)
        IF (ErrStat /= CD_MODEL_OK) RETURN
        CALL validate_nonnegative_vector(added_mass_cat_elem, n_elem, 'added_mass_cat_elem', ErrStat, ErrMsg)
        IF (ErrStat /= CD_MODEL_OK) RETURN
      END IF
    END IF

    use_viscoelastic = PRESENT(ve_ea_d) .OR. PRESENT(ve_ba) .OR. PRESENT(ve_ba_d) .OR. &
                       PRESENT(ve_alpha_mbl) .OR. PRESENT(ve_vbeta)
    IF (use_viscoelastic) THEN
      IF (.NOT. (PRESENT(ve_ea_d) .AND. PRESENT(ve_ba) .AND. PRESENT(ve_ba_d))) THEN
        CALL fail(ErrStat, ErrMsg, 'viscoelastic parameters need all of ve_ea_d, ve_ba, ve_ba_d')
        RETURN
      END IF
      IF (PRESENT(ve_alpha_mbl) .NEQV. PRESENT(ve_vbeta)) THEN
        CALL fail(ErrStat, ErrMsg, 'the load-dependent pair ve_alpha_mbl and ve_vbeta must be '// &
                  'supplied together')
        RETURN
      END IF
      IF (SIZE(ve_ea_d) /= n_elem .OR. SIZE(ve_ba) /= n_elem .OR. SIZE(ve_ba_d) /= n_elem) THEN
        CALL fail(ErrStat, ErrMsg, 've_ea_d, ve_ba, and ve_ba_d must have shape (n_elem)')
        RETURN
      END IF
      IF (.NOT. (CD_All_Finite(ve_ea_d) .AND. CD_All_Finite(ve_ba) .AND. &
                 CD_All_Finite(ve_ba_d))) THEN
        CALL fail(ErrStat, ErrMsg, 'viscoelastic parameters must be finite')
        RETURN
      END IF
      IF (ANY(ve_ea_d < CD_ZERO)) THEN
        CALL fail(ErrStat, ErrMsg, 've_ea_d entries must be zero (plain element) or positive')
        RETURN
      END IF
      IF (PRESENT(ve_alpha_mbl)) THEN
        IF (SIZE(ve_alpha_mbl) /= n_elem .OR. SIZE(ve_vbeta) /= n_elem) THEN
          CALL fail(ErrStat, ErrMsg, 've_alpha_mbl and ve_vbeta must have shape (n_elem)')
          RETURN
        END IF
        IF (.NOT. (CD_All_Finite(ve_alpha_mbl) .AND. CD_All_Finite(ve_vbeta))) THEN
          CALL fail(ErrStat, ErrMsg, 'viscoelastic load-dependent parameters must be finite')
          RETURN
        END IF
        IF (ANY(ve_alpha_mbl < CD_ZERO) .OR. ANY(ve_vbeta < CD_ZERO)) THEN
          CALL fail(ErrStat, ErrMsg, 've_alpha_mbl/ve_vbeta entries must be zero (not load-'// &
                    'dependent) or positive')
          RETURN
        END IF
        DO e = 1, n_elem
          IF ((ve_alpha_mbl(e) > CD_ZERO) .NEQV. (ve_vbeta(e) > CD_ZERO)) THEN
            CALL fail(ErrStat, ErrMsg, 'a load-dependent element needs BOTH ve_alpha_mbl > 0 '// &
                      'and ve_vbeta > 0')
            RETURN
          END IF
          IF (ve_alpha_mbl(e) > CD_ZERO .AND. ve_ea_d(e) > CD_ZERO) THEN
            CALL fail(ErrStat, ErrMsg, 'an element cannot carry both a constant dynamic stiffness '// &
                      '(ve_ea_d) and the load-dependent pair (ve_alpha_mbl/ve_vbeta)')
            RETURN
          END IF
        END DO
      END IF
      DO e = 1, n_elem
        IF (ve_ea_d(e) <= CD_ZERO .AND. .NOT. mode3_marked(ve_alpha_mbl, e) .AND. &
            ABS(ve_ba(e)) + ABS(ve_ba_d(e)) > CD_ZERO) THEN
          CALL fail(ErrStat, ErrMsg, 'a plain element (no ve_ea_d, no ve_alpha_mbl) cannot carry '// &
                    'series-Kelvin dashpots (ve_ba/ve_ba_d must be zero there)')
          RETURN
        END IF
      END DO
      ! all-zero arrays mean no viscoelastic elements at all
      use_viscoelastic = ANY(ve_ea_d > CD_ZERO)
      IF (PRESENT(ve_alpha_mbl)) use_viscoelastic = use_viscoelastic .OR. ANY(ve_alpha_mbl > CD_ZERO)
    END IF

    ! Syrope: the four arrays come together; syrope_type entries flagged by
    ! syrope_is must be initialized; a Syrope element cannot also be viscoelastic.
    use_syrope = PRESENT(syrope_is) .OR. PRESENT(syrope_type) .OR. PRESENT(syrope_slow0) .OR. &
                 PRESENT(syrope_tmax0)
    IF (use_syrope) THEN
      IF (.NOT. (PRESENT(syrope_is) .AND. PRESENT(syrope_type) .AND. PRESENT(syrope_slow0) .AND. &
                 PRESENT(syrope_tmax0))) THEN
        CALL fail(ErrStat, ErrMsg, 'Syrope needs all of syrope_is, syrope_type, syrope_slow0, syrope_tmax0')
        RETURN
      END IF
      IF (SIZE(syrope_is) /= n_elem .OR. SIZE(syrope_type) /= n_elem .OR. &
          SIZE(syrope_slow0) /= n_elem .OR. SIZE(syrope_tmax0) /= n_elem) THEN
        CALL fail(ErrStat, ErrMsg, 'the Syrope arrays must have shape (n_elem)')
        RETURN
      END IF
      IF (.NOT. (CD_All_Finite(syrope_slow0) .AND. CD_All_Finite(syrope_tmax0))) THEN
        CALL fail(ErrStat, ErrMsg, 'Syrope IC (slow0, tmax0) must be finite')
        RETURN
      END IF
      DO e = 1, n_elem
        IF (.NOT. syrope_is(e)) CYCLE
        IF (syrope_slow0(e) < CD_ZERO) THEN
          CALL fail(ErrStat, ErrMsg, 'Syrope slow0 must be non-negative on a Syrope element')
          RETURN
        END IF
        IF (.NOT. CD_Syrope_Is_Ready(syrope_type(e))) THEN
          CALL fail(ErrStat, ErrMsg, 'a Syrope element was flagged without initialized constitutive data')
          RETURN
        END IF
        IF (.NOT. (syrope_tmax0(e) > CD_ZERO)) THEN
          CALL fail(ErrStat, ErrMsg, 'Syrope tmax0 must be positive on a Syrope element')
          RETURN
        END IF
        CALL CD_Syrope_Working_Curve(syrope_type(e), syrope_tmax0(e), syrope_ws, syrope_wt, syrope_wsl, es, em)
        IF (es /= CD_SYROPE_OK) THEN
          CALL fail(ErrStat, ErrMsg, 'Syrope tmax0 is invalid: '//TRIM(em))
          RETURN
        END IF
        CALL CD_Syrope_Check_Range(syrope_type(e), syrope_slow0(e), es, em)
        IF (es /= CD_SYROPE_OK) THEN
          CALL fail(ErrStat, ErrMsg, 'Syrope slow0 is invalid: '//TRIM(em))
          RETURN
        END IF
        IF (use_viscoelastic) THEN
          IF (ve_ea_d(e) > CD_ZERO .OR. mode3_marked(ve_alpha_mbl, e)) THEN
            CALL fail(ErrStat, ErrMsg, 'an element cannot be both Syrope and viscoelastic')
            RETURN
          END IF
        END IF
      END DO
      use_syrope = ANY(syrope_is)
    END IF

    CALL CD_End_Model(model, es, em)
    model%n_dof = n_dof
    model%n_elem = n_elem
    model%tension_only = tension_only
    model%cfg = cfg
    ALLOCATE (model%elem_conn(2, n_elem), model%fixed_dofs(SIZE(fixed_dofs)), &
              model%l0(n_elem), model%ea(n_elem), model%ea_dyn(n_elem), model%rho_a(n_elem), model%l0_dot(n_elem), &
              model%l0_c(n_elem), model%l0_dot_c(n_elem), model%l0_c_rollback(n_elem), &
              model%l0_dot_c_rollback(n_elem), model%recovery_l0_c(n_elem), model%recovery_l0_dot_c(n_elem), &
              model%f_ext(n_dof), &
              model%q(n_dof), model%v(n_dof), model%a(n_dof), &
              model%q_step(n_dof), model%v_step(n_dof), model%a_step(n_dof), &
              model%q_prescribed_work(n_dof), model%v_prescribed_work(n_dof), model%a_prescribed_work(n_dof), &
              model%q_rollback(n_dof), model%v_rollback(n_dof), model%a_rollback(n_dof), &
              model%recovery_q0(n_dof), model%recovery_v0(n_dof), model%recovery_a0(n_dof), &
              model%f_ext_rollback(n_dof), model%free_map_work(n_dof), STAT=istat)
    IF (istat /= 0) THEN
      CALL restore_after_init_alloc_fail(model, old_model, 'base model storage', ErrStat, ErrMsg)
      RETURN
    END IF
    model%elem_conn = elem_conn
    model%fixed_dofs = fixed_dofs
    model%l0 = l0
    model%l0_dot = CD_ZERO
    model%l0_c = l0
    model%l0_dot_c = CD_ZERO
    model%l0_c_rollback = l0
    model%l0_dot_c_rollback = CD_ZERO
    model%recovery_l0_c = l0
    model%recovery_l0_dot_c = CD_ZERO
    model%ea = ea
    model%ea_dyn = ea
    model%rho_a = rho_a
    model%f_ext = f_ext
    IF (PRESENT(dist_load_per_length)) THEN
      IF (SIZE(dist_load_per_length, 1) /= 3 .OR. SIZE(dist_load_per_length, 2) /= n_elem .OR. &
          .NOT. CD_All_Finite(dist_load_per_length)) THEN
        ! Restore the previous model, then report the bad input as such.
        CALL restore_after_init_alloc_fail(model, old_model, 'distributed-load shape', ErrStat, ErrMsg)
        ErrStat = CD_MODEL_BADINPUT
        ErrMsg = 'CableDyn_Model: dist_load_per_length must be finite with shape (3, n_elem)'
        RETURN
      END IF
      ALLOCATE (model%dist_load(3, n_elem), model%f_ext_dist_base(n_dof), STAT=istat)
      IF (istat /= 0) THEN
        CALL restore_after_init_alloc_fail(model, old_model, 'distributed-load storage', ErrStat, ErrMsg)
        RETURN
      END IF
      model%dist_load = dist_load_per_length
      ! the non-distributed remainder: for the deck path (f_ext IS the assembled
      ! distributed load) this is exactly zero, so later reassembly reproduces a
      ! fresh build bit-for-bit
      CALL CD_Assemble_Distributed_Load(elem_conn, l0, dist_load_per_length, model%f_ext_dist_base, es, em)
      IF (es /= 0) THEN
        CALL restore_after_init_alloc_fail(model, old_model, 'distributed-load remainder', ErrStat, ErrMsg)
        ErrStat = CD_MODEL_BADINPUT
        ErrMsg = 'CableDyn_Model: distributed-load assembly failed: '//TRIM(em)
        RETURN
      END IF
      model%f_ext_dist_base = model%f_ext - model%f_ext_dist_base
    END IF
    IF (PRESENT(seabed_kbot) .AND. PRESENT(seabed_contact_diameter)) THEN
      BLOCK
        LOGICAL :: ratio_ok
        ! With seabed DAMPING active the recompute rebuilds cn from the ratio; a
        ! missing ratio would silently wipe the damping to zero on the first
        ! length update, so recompute stays DISABLED without it (the update then
        ! fails closed by name instead). Without damping the ratio is irrelevant.
        ratio_ok = .NOT. use_seabed_damping
        IF (PRESENT(seabed_cn_over_kn)) THEN
          IF (CD_Is_Finite(seabed_cn_over_kn) .AND. seabed_cn_over_kn >= CD_ZERO) ratio_ok = .TRUE.
        END IF
        IF (CD_Is_Finite(seabed_kbot) .AND. seabed_kbot > CD_ZERO .AND. &
            SIZE(seabed_contact_diameter) == n_elem .AND. &
            CD_All_Finite(seabed_contact_diameter) .AND. ALL(seabed_contact_diameter > CD_ZERO) .AND. &
            ratio_ok) THEN
          ALLOCATE (model%seabed_diameter_elem(n_elem), STAT=istat)
          IF (istat /= 0) THEN
            CALL restore_after_init_alloc_fail(model, old_model, 'seabed recompute storage', ErrStat, ErrMsg)
            RETURN
          END IF
          model%seabed_diameter_elem = seabed_contact_diameter
          model%has_seabed_recompute = .TRUE.
          model%seabed_kbot = seabed_kbot
          model%seabed_cn_over_kn = CD_ZERO
          IF (PRESENT(seabed_cn_over_kn)) THEN
            IF (CD_Is_Finite(seabed_cn_over_kn) .AND. seabed_cn_over_kn >= CD_ZERO) &
              model%seabed_cn_over_kn = seabed_cn_over_kn
          END IF
        END IF
      END BLOCK
    END IF
    model%q = q0
    model%v = v0
    model%a = CD_ZERO
    model%q_step = CD_ZERO
    model%v_step = CD_ZERO
    model%a_step = CD_ZERO
    model%q_prescribed_work = CD_ZERO
    model%v_prescribed_work = CD_ZERO
    model%a_prescribed_work = CD_ZERO
    model%q_rollback = CD_ZERO
    model%v_rollback = CD_ZERO
    model%a_rollback = CD_ZERO
    model%recovery_q0 = CD_ZERO
    model%recovery_v0 = CD_ZERO
    model%recovery_a0 = CD_ZERO
    model%f_ext_rollback = CD_ZERO
    model%free_map_work = 0
    ! The consistent mass is never stored densely: the step path applies it element by
    ! element (band assembly and matvec) and the coupled-derivative queries assemble it
    ! on demand. Validate the connectivity it is built from here, as the stored mass
    ! assembly did.
    ! validated once here: the connectivity never changes afterwards, so the model's own
    ! assembly calls pass topology_validated
    CALL CD_Validate_Connectivity(model%elem_conn, model%n_dof/3, model%n_elem, es, em)
    IF (es /= 0) THEN
      CALL CD_End_Model(model, ErrStat, ErrMsg)
      model = old_model
      ErrStat = CD_MODEL_SOLVEFAIL
      ErrMsg = 'CableDyn_Model: mesh connectivity rejected: '//TRIM(em)
      RETURN
    END IF
    model%has_seabed = use_seabed
    model%has_bathymetry = use_seabed .AND. PRESENT(bathymetry)
    model%has_seabed_damping = use_seabed_damping
    model%has_seabed_friction = use_seabed_friction
    model%has_damping = use_damping
    model%has_viscoelastic = use_viscoelastic
    model%has_syrope = use_syrope
    model%has_morison_drag = use_drag
    model%has_froude_krylov = use_fk
    model%has_buoyancy_recovery = use_buoyancy
    model%has_added_mass = use_added_mass
    IF (use_seabed) THEN
      IF (PRESENT(seabed_z_floor)) model%seabed_z_floor = seabed_z_floor
      IF (PRESENT(bathymetry)) model%bathymetry = bathymetry
      ALLOCATE (model%seabed_kn(n_nodes), source=seabed_kn, STAT=istat)
      IF (istat /= 0) THEN
        CALL restore_after_init_alloc_fail(model, old_model, 'seabed stiffness storage', ErrStat, ErrMsg)
        RETURN
      END IF
    END IF
    IF (use_seabed_damping) THEN
      ALLOCATE (model%seabed_cn(n_nodes), source=seabed_cn, STAT=istat)
      IF (istat /= 0) THEN
        CALL restore_after_init_alloc_fail(model, old_model, 'seabed damping storage', ErrStat, ErrMsg)
        RETURN
      END IF
    END IF
    IF (use_seabed_friction) THEN
      model%seabed_mu = seabed_mu
      ! Friction springs anchored at the initial positions (no force); a static solve with
      ! friction installs its spring forces through CD_Set_Model_Friction_Anchors.
      ALLOCATE (model%fr_anchor(2, n_nodes), model%fr_anchor_rollback(2, n_nodes), &
                model%recovery_fr_anchor(2, n_nodes), STAT=istat)
      IF (istat /= 0) THEN
        CALL restore_after_init_alloc_fail(model, old_model, 'seabed friction storage', ErrStat, ErrMsg)
        RETURN
      END IF
      DO e = 1, n_nodes
        model%fr_anchor(:, e) = q0(3*e - 2:3*e - 1)
      END DO
      model%fr_anchor_rollback = model%fr_anchor
      model%recovery_fr_anchor = model%fr_anchor
    END IF
    IF (use_damping) THEN
      ALLOCATE (model%ba(n_elem), source=ba, STAT=istat)
      IF (istat == 0) ALLOCATE (model%ba_dyn(n_elem), source=ba, STAT=istat)
      IF (istat /= 0) THEN
        CALL restore_after_init_alloc_fail(model, old_model, 'axial damping storage', ErrStat, ErrMsg)
        RETURN
      END IF
    END IF
    IF (use_viscoelastic) THEN
      ALLOCATE (model%ve_mode(n_elem), model%ve_ea_d(n_elem), model%ve_ea_1(n_elem), &
                model%ve_alpha_mbl(n_elem), model%ve_vbeta(n_elem), model%ve_ba(n_elem), &
                model%ve_ba_d(n_elem), model%ve_dl_1(n_elem), model%ve_dl_1_rollback(n_elem), &
                model%recovery_ve_dl_1(n_elem), STAT=istat)
      IF (istat /= 0) THEN
        CALL restore_after_init_alloc_fail(model, old_model, 'viscoelastic storage', ErrStat, ErrMsg)
        RETURN
      END IF
      model%ve_mode = 0
      model%ve_ea_d = ve_ea_d
      model%ve_ba = ve_ba
      model%ve_ba_d = ve_ba_d
      model%ve_ea_1 = CD_ZERO
      model%ve_alpha_mbl = CD_ZERO
      model%ve_vbeta = CD_ZERO
      IF (PRESENT(ve_alpha_mbl)) THEN
        model%ve_alpha_mbl = ve_alpha_mbl
        model%ve_vbeta = ve_vbeta
      END IF
      model%ve_dl_1 = CD_ZERO
      DO e = 1, n_elem
        IF (ve_ea_d(e) > CD_ZERO) THEN
          model%ve_mode(e) = 2
        ELSE IF (mode3_marked(ve_alpha_mbl, e)) THEN
          model%ve_mode(e) = 3
        ELSE
          CYCLE
        END IF
        ! IC: dl_1 starts at the STEADY-STATE partition of the initial stretch
        ! (the ld_1 = 0 point), at which the series-Kelvin tension equals the static
        ! composite EA*dl/l0 -- the static equilibrium the caller solved IS the
        ! dynamic fixed point. MoorDyn instead seeds dl_1 = lstr - l and
        ! relaxes it to this same partition over its TmaxIC window before
        ! t = 0, so the two codes enter production time in the same state.
        BLOCK
          INTEGER :: na, nb, it
          REAL(wp) :: lstr0, dl0, ea_d_eff, dl1, dl1_new
          na = elem_conn(1, e)
          nb = elem_conn(2, e)
          lstr0 = NORM2(q0(3*nb - 2:3*nb) - q0(3*na - 2:3*na))
          dl0 = lstr0 - l0(e)
          es = CD_VISCO_OK
          IF (model%ve_mode(e) == 2) THEN
            ea_d_eff = ve_ea_d(e)
            CALL CD_Viscoelastic_Steady_State(ea(e), ea_d_eff, dl0, model%ve_dl_1(e))
          ELSE
            ! mode 3: the partition is self-consistent (EA_D depends on dl_1);
            ! fixed-point iteration dl_1 <- dl0*(EA_D(dl_1) - EA)/EA_D(dl_1) --
            ! EA_D is monotone and bounded in dl_1, so the map contracts; fail
            ! closed if it does not settle
            dl1 = dl0
            ea_d_eff = CD_ZERO
            DO it = 1, 200
              CALL CD_Viscoelastic_LoadDependent_EAD(ea(e), l0(e), ve_alpha_mbl(e), ve_vbeta(e), &
                                                     dl1, ea_d_eff, es, em)
              IF (es /= CD_VISCO_OK) EXIT
              CALL CD_Viscoelastic_Steady_State(ea(e), ea_d_eff, dl0, dl1_new)
              IF (ABS(dl1_new - dl1) <= 1.0e-14_wp*MAX(1.0_wp, ABS(dl1_new))) THEN
                dl1 = dl1_new
                EXIT
              END IF
              dl1 = dl1_new
              IF (it == 200) THEN
                es = CD_VISCO_BADINPUT
                em = 'CableDyn_Viscoelastic: the load-dependent steady-state partition did not settle'
              END IF
            END DO
            model%ve_dl_1(e) = dl1
            ! EA_D(dl_1) is increasing in dl_1 with EA_D = alphaMBL at dl_1 <= 0, so
            ! the premise EA_D > EA holds over every admissible state (taut and
            ! slack) exactly when alphaMBL > EA; a check at the initial stretch
            ! alone would pass a taut IC and fail at the first slack segment.
            IF (.NOT. (ve_alpha_mbl(e) > ea(e))) THEN
              es = CD_VISCO_BADINPUT
              em = ''
              WRITE (em, '(A,I0,A,ES12.5,A,ES12.5,A)', IOSTAT=it) &
                'CableDyn_Viscoelastic: ElasticMod 3 element ', e, ' needs alphaMBL (', ve_alpha_mbl(e), &
                ' N) > static EA (', ea(e), ' N); a slack segment has EA_D = alphaMBL'
            END IF
          END IF
          ! the fatal battery (EA_D <= EA, negative dashpots, BA + BA_D = 0);
          ! mode 2 stores the derived EA_1, mode 3 derives both per evaluation
          ! from the committed dl_1 (the ElasticMod 3 premise is required above
          ! over the whole admissible dl_1 range, not only at the IC value)
          IF (es == CD_VISCO_OK) &
            CALL CD_Viscoelastic_Params(ea(e), ea_d_eff, ve_ba(e), ve_ba_d(e), model%ve_ea_1(e), es, em)
          IF (es /= CD_VISCO_OK) THEN
            CALL CD_End_Model(model, ErrStat, ErrMsg)
            model = old_model
            ErrStat = CD_MODEL_BADINPUT
            ErrMsg = 'CableDyn_Model: '//TRIM(em)
            RETURN
          END IF
          ! mode 3 has no stored EA_1 (state-dependent); keep only mode 2's
          IF (model%ve_mode(e) == 3) model%ve_ea_1(e) = CD_ZERO
        END BLOCK
        ! the series-Kelvin law replaces both the elastic EA and the plain axial damping of
        ! this element in the dynamic assembly
        model%ea_dyn(e) = CD_ZERO
        IF (ALLOCATED(model%ba_dyn)) model%ba_dyn(e) = CD_ZERO
      END DO
      model%ve_dl_1_rollback = model%ve_dl_1
      model%recovery_ve_dl_1 = model%ve_dl_1
    END IF
    IF (use_syrope) THEN
      ALLOCATE (model%syrope_is(n_elem), model%syrope_type(n_elem), model%syrope_slow(n_elem), &
                model%syrope_slow_rollback(n_elem), model%syrope_tmax(n_elem), &
                model%syrope_tmax_rollback(n_elem), model%recovery_syrope_slow(n_elem), &
                model%recovery_syrope_tmax(n_elem), STAT=istat)
      IF (istat /= 0) THEN
        CALL restore_after_init_alloc_fail(model, old_model, 'Syrope storage', ErrStat, ErrMsg)
        RETURN
      END IF
      model%syrope_is = .FALSE.
      model%syrope_slow = CD_ZERO
      model%syrope_tmax = CD_ZERO
      DO e = 1, n_elem
        IF (.NOT. syrope_is(e)) CYCLE
        model%syrope_is(e) = .TRUE.
        ! deep-copy the (validated) constitutive data; the Syrope contributor
        ! supplies this element's tension, so its elastic EA and plain axial
        ! damping are masked out of the dynamic structural assembly
        model%syrope_type(e) = syrope_type(e)
        model%syrope_slow(e) = syrope_slow0(e)
        model%syrope_tmax(e) = syrope_tmax0(e)
        model%ea_dyn(e) = CD_ZERO
        IF (ALLOCATED(model%ba_dyn)) model%ba_dyn(e) = CD_ZERO
      END DO
      model%syrope_slow_rollback = model%syrope_slow
      model%syrope_tmax_rollback = model%syrope_tmax
      model%recovery_syrope_slow = model%syrope_slow
      model%recovery_syrope_tmax = model%syrope_tmax
    END IF
    IF (use_drag) THEN
      ALLOCATE (model%fluid_velocity(3, n_nodes), model%drag_waterline_z(n_nodes), STAT=istat)
      IF (istat /= 0) THEN
        CALL restore_after_init_alloc_fail(model, old_model, 'drag field storage', ErrStat, ErrMsg)
        RETURN
      END IF
      model%fluid_velocity = fluid_velocity
      model%drag_waterline_z = drag_waterline_z
      model%drag_rho = drag_rho
      ALLOCATE (model%drag_diameter_elem(n_elem), model%drag_cdn_elem(n_elem), model%drag_cdt_elem(n_elem), &
                STAT=istat)
      IF (istat /= 0) THEN
        CALL restore_after_init_alloc_fail(model, old_model, 'drag coefficient storage', ErrStat, ErrMsg)
        RETURN
      END IF
      IF (scalar_drag) THEN
        model%drag_diameter = drag_diameter
        model%drag_cdn = drag_cdn
        model%drag_cdt = drag_cdt
        model%drag_diameter_elem = drag_diameter
        model%drag_cdn_elem = drag_cdn
        model%drag_cdt_elem = drag_cdt
      ELSE
        model%drag_diameter_elem = drag_diameter_elem
        model%drag_cdn_elem = drag_cdn_elem
        model%drag_cdt_elem = drag_cdt_elem
      END IF
    END IF
    IF (use_fk) THEN
      ALLOCATE (model%fluid_acceleration(3, n_nodes), model%fk_waterline_z(n_nodes), STAT=istat)
      IF (istat /= 0) THEN
        CALL restore_after_init_alloc_fail(model, old_model, 'fluid-acceleration field storage', ErrStat, ErrMsg)
        RETURN
      END IF
      model%fluid_acceleration = fluid_acceleration
      model%fk_waterline_z = fk_waterline_z
      model%fk_rho = fk_rho
      ALLOCATE (model%fk_diameter_elem(n_elem), model%fk_can_elem(n_elem), model%fk_cat_elem(n_elem), STAT=istat)
      IF (istat /= 0) THEN
        CALL restore_after_init_alloc_fail(model, old_model, 'fluid-inertia coefficient storage', ErrStat, ErrMsg)
        RETURN
      END IF
      IF (scalar_fk) THEN
        model%fk_diameter = fk_diameter
        model%fk_can = fk_can
        model%fk_cat = fk_cat
        model%fk_diameter_elem = fk_diameter
        model%fk_can_elem = fk_can
        model%fk_cat_elem = fk_cat
      ELSE
        model%fk_diameter_elem = fk_diameter_elem
        model%fk_can_elem = fk_can_elem
        model%fk_cat_elem = fk_cat_elem
      END IF
    END IF
    IF (use_buoyancy) THEN
      ALLOCATE (model%buoyancy_waterline_z(n_nodes), STAT=istat)
      IF (istat /= 0) THEN
        CALL restore_after_init_alloc_fail(model, old_model, 'buoyancy waterline storage', ErrStat, ErrMsg)
        RETURN
      END IF
      model%buoyancy_waterline_z = buoyancy_waterline_z
      model%buoyancy_rho = buoyancy_rho
      model%buoyancy_gravity = buoyancy_gravity
      ALLOCATE (model%buoyancy_diameter_elem(n_elem), STAT=istat)
      IF (istat /= 0) THEN
        CALL restore_after_init_alloc_fail(model, old_model, 'buoyancy diameter storage', ErrStat, ErrMsg)
        RETURN
      END IF
      IF (scalar_buoyancy) THEN
        model%buoyancy_diameter = buoyancy_diameter
        model%buoyancy_diameter_elem = buoyancy_diameter
      ELSE
        model%buoyancy_diameter_elem = buoyancy_diameter_elem
      END IF
    END IF
    IF (use_added_mass) THEN
      ALLOCATE (model%added_mass_waterline_z(n_nodes), STAT=istat)
      IF (istat /= 0) THEN
        CALL restore_after_init_alloc_fail(model, old_model, 'added-mass waterline storage', ErrStat, ErrMsg)
        RETURN
      END IF
      model%added_mass_waterline_z = added_mass_waterline_z
      model%added_mass_rho = added_mass_rho
      ALLOCATE (model%added_mass_diameter_elem(n_elem), model%added_mass_can_elem(n_elem), &
                model%added_mass_cat_elem(n_elem), STAT=istat)
      IF (istat /= 0) THEN
        CALL restore_after_init_alloc_fail(model, old_model, 'added-mass coefficient storage', ErrStat, ErrMsg)
        RETURN
      END IF
      IF (scalar_added_mass) THEN
        model%added_mass_diameter = added_mass_diameter
        model%added_mass_can = added_mass_can
        model%added_mass_cat = added_mass_cat
        model%added_mass_diameter_elem = added_mass_diameter
        model%added_mass_can_elem = added_mass_can
        model%added_mass_cat_elem = added_mass_cat
      ELSE
        model%added_mass_diameter_elem = added_mass_diameter_elem
        model%added_mass_can_elem = added_mass_can_elem
        model%added_mass_cat_elem = added_mass_cat_elem
      END IF
    END IF

    has_load = model%has_seabed .OR. model%has_seabed_damping .OR. model%has_seabed_friction .OR. &
               model%has_damping .OR. model%has_viscoelastic .OR. model%has_syrope .OR. model%has_morison_drag .OR. &
               model%has_froude_krylov .OR. model%has_buoyancy_recovery
    step_loads%model => model
    step_loads%has_force = has_load
    step_loads%has_added_mass = model%has_added_mass
    IF (has_load .AND. model%has_added_mass) THEN
      CALL CD_Cable_Initial_Acceleration(model%q, model%v, model%elem_conn, model%l0, model%ea_dyn, &
                                         model%rho_a, model%tension_only, model%f_ext, &
                                         model%fixed_dofs, model%a, es, em, &
                                         workspace=model%dynamic_workspace, loads=step_loads)
    ELSE IF (has_load) THEN
      CALL CD_Cable_Initial_Acceleration(model%q, model%v, model%elem_conn, model%l0, model%ea_dyn, &
                                         model%rho_a, model%tension_only, model%f_ext, &
                                         model%fixed_dofs, model%a, es, em, &
                                         workspace=model%dynamic_workspace, loads=step_loads)
    ELSE IF (model%has_added_mass) THEN
      CALL CD_Cable_Initial_Acceleration(model%q, model%v, model%elem_conn, model%l0, model%ea_dyn, &
                                         model%rho_a, model%tension_only, model%f_ext, &
                                         model%fixed_dofs, model%a, es, em, &
                                         workspace=model%dynamic_workspace, loads=step_loads)
    ELSE
      CALL CD_Cable_Initial_Acceleration(model%q, model%v, model%elem_conn, model%l0, model%ea_dyn, &
                                         model%rho_a, model%tension_only, model%f_ext, &
                                         model%fixed_dofs, model%a, es, em, workspace=model%dynamic_workspace)
    END IF
    IF (es /= CD_DYN_OK) THEN
      CALL CD_End_Model(model, ErrStat, ErrMsg)
      model = old_model
      ErrStat = model_status_from_dyn(es)
      ErrMsg = 'CableDyn_Model: initial acceleration failed: '//TRIM(em)
      RETURN
    END IF
    model%initialized = .TRUE.
    ! the line's initial tension, the floor of the tension scale of the sub-stepping (sub_count)
    model%sub_t_init = initial_tension(model)
  END SUBROUTINE CD_Init_Model

  SUBROUTINE CD_Init_Line_Model(model, anchor, fairlead, line_types, sections, gravity, rho_water, &
                                tension_only, static_cfg, dynamic_cfg, load_factors, ErrStat, ErrMsg, &
                                anchor_is_end_b, seabed_z_floor, seabed_kn, seabed_cn, seabed_mu, ba, &
                                fluid_velocity, drag_waterline_z, drag_rho, drag_diameter, drag_cdn, drag_cdt, &
                                drag_diameter_elem, drag_cdn_elem, drag_cdt_elem, &
                                fluid_acceleration, fk_waterline_z, fk_rho, fk_diameter, fk_can, fk_cat, &
                                fk_diameter_elem, fk_can_elem, fk_cat_elem, seabed_mu_axial, &
                                buoyancy_waterline_z, buoyancy_rho, buoyancy_diameter, buoyancy_gravity, &
                                buoyancy_diameter_elem, &
                                added_mass_waterline_z, added_mass_rho, added_mass_diameter, added_mass_can, &
                                added_mass_cat, added_mass_diameter_elem, added_mass_can_elem, added_mass_cat_elem, &
                                bathymetry, dynamic_tension_only, &
                                seabed_kbot, seabed_contact_diameter, seabed_cn_over_kn, &
                                ve_ea_d, ve_ba, ve_ba_d, ve_alpha_mbl, ve_vbeta, &
                                syrope_is, syrope_type, syrope_slow0, syrope_tmax0, &
                                current_profile_z, current_profile_velocity, &
                                static_friction, lay_azimuth, as_laid_tension, current_grid)
    !! Initialise a persistent EI=0 dynamic model from an OrcaFlex-style line object:
    !! line types + sections + end points. This routine builds the mesh, assembles
    !! submerged-weight loads, obtains a static initial condition by load continuation,
    !! and delegates the persistent-state population to CD_Init_Model.
    !!
    !! Optional seabed and axial-damping contributors are stored on the model and
    !! reused during initial acceleration, stepping, and coupled-load extraction so
    !! the static IC and the first dynamic step see the same load model.
    TYPE(CD_ModelType), INTENT(INOUT) :: model
    REAL(wp), INTENT(IN) :: anchor(3), fairlead(3)
    TYPE(CD_LineType), INTENT(IN) :: line_types(:)
    TYPE(CD_LineSection), INTENT(IN) :: sections(:)
    REAL(wp), INTENT(IN) :: gravity, rho_water
    LOGICAL, INTENT(IN) :: tension_only
    ! dynamic_tension_only (default = tension_only): the COMMITTED dynamic model's
    ! compression convention, decoupled from the static IC's. The static continuation
    ! stays compression-capable where requested (a fully slack element has zero tangent
    ! stiffness, so tension-only STATICS on a slack span is singular), while the marched
    ! model can be tension-only -- MoorDyn's lumped-mass convention, the physical one
    ! for chains/ropes: a slack element exerts nothing and reports zero tension.
    TYPE(CableSolverConfig), INTENT(IN) :: static_cfg
    TYPE(GenAlphaConfig), INTENT(IN) :: dynamic_cfg
    REAL(wp), INTENT(IN) :: load_factors(:)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    LOGICAL, INTENT(IN), OPTIONAL :: anchor_is_end_b
    REAL(wp), INTENT(IN), OPTIONAL :: seabed_z_floor
    REAL(wp), INTENT(IN), OPTIONAL :: seabed_kn(:)
    REAL(wp), INTENT(IN), OPTIONAL :: seabed_cn(:)
    ! Anisotropic seabed friction: the coefficient along the line (seabed_mu is then the
    ! lateral one); absent, or equal to seabed_mu, keeps the isotropic law.
    REAL(wp), INTENT(IN), OPTIONAL :: seabed_mu_axial
    REAL(wp), INTENT(IN), OPTIONAL :: seabed_mu
    REAL(wp), INTENT(IN), OPTIONAL :: ba(:)
    REAL(wp), INTENT(IN), OPTIONAL :: fluid_velocity(:, :)
    REAL(wp), INTENT(IN), OPTIONAL :: drag_waterline_z(:), drag_rho, drag_diameter, drag_cdn, drag_cdt
    REAL(wp), INTENT(IN), OPTIONAL :: drag_diameter_elem(:), drag_cdn_elem(:), drag_cdt_elem(:)
    REAL(wp), INTENT(IN), OPTIONAL :: fluid_acceleration(:, :)
    REAL(wp), INTENT(IN), OPTIONAL :: fk_waterline_z(:), fk_rho, fk_diameter, fk_can, fk_cat
    REAL(wp), INTENT(IN), OPTIONAL :: fk_diameter_elem(:), fk_can_elem(:), fk_cat_elem(:)
    REAL(wp), INTENT(IN), OPTIONAL :: buoyancy_waterline_z(:), buoyancy_rho, buoyancy_diameter, buoyancy_gravity
    REAL(wp), INTENT(IN), OPTIONAL :: buoyancy_diameter_elem(:)
    REAL(wp), INTENT(IN), OPTIONAL :: added_mass_waterline_z(:)
    REAL(wp), INTENT(IN), OPTIONAL :: added_mass_rho, added_mass_diameter, added_mass_can, added_mass_cat
    REAL(wp), INTENT(IN), OPTIONAL :: added_mass_diameter_elem(:), added_mass_can_elem(:), added_mass_cat_elem(:)
    TYPE(CD_BathymetryType), INTENT(IN), OPTIONAL :: bathymetry
    ! dynamic_tension_only sits LAST in the argument list: appending (never inserting)
    ! a new optional preserves every existing positional call's meaning (the API-
    ! stability rule for public module routines).
    LOGICAL, INTENT(IN), OPTIONAL :: dynamic_tension_only
    ! Seabed recompute inputs for active line control, passed through to
    ! CD_Init_Model (see the model type note).
    REAL(wp), INTENT(IN), OPTIONAL :: seabed_kbot, seabed_cn_over_kn
    REAL(wp), INTENT(IN), OPTIONAL :: seabed_contact_diameter(:)
    ! Viscoelastic per-element parameters, passed through to CD_Init_Model in
    ! the caller's FINAL element order (callers using anchor_is_end_b reversal
    ! must pre-reverse these alongside ba). The static IC below always solves
    ! with the composite ea (the series-Kelvin law relaxes to it), so only the dynamic model
    ! sees the split.
    REAL(wp), INTENT(IN), OPTIONAL :: ve_ea_d(:), ve_ba(:), ve_ba_d(:)
    REAL(wp), INTENT(IN), OPTIONAL :: ve_alpha_mbl(:), ve_vbeta(:)
    ! Syrope per-element data, passed through to CD_Init_Model in the caller's
    ! FINAL element order (pre-reversed alongside ba for anchor_is_end_b lines).
    ! The caller sets the composite ea to the OWC secant so the static IC solves
    ! at a strain consistent with the working-curve tension.
    LOGICAL, INTENT(IN), OPTIONAL :: syrope_is(:)
    TYPE(CD_SyropeType), INTENT(IN), OPTIONAL :: syrope_type(:)
    REAL(wp), INTENT(IN), OPTIONAL :: syrope_slow0(:), syrope_tmax0(:)
    ! Depth profile of the steady current (levels, velocities): the static initial condition
    ! then samples the current at each node's own elevation, as the dynamic march does, so the
    ! march starts from rest. Without it the static drag uses fluid_velocity as given.
    REAL(wp), INTENT(IN), OPTIONAL :: current_profile_z(:), current_profile_velocity(:, :)
    ! A current grid in space and time (MoorDyn-C Currents 2 and 5): the static initial condition
    ! then samples it at each node's own position at t = 0, in place of the depth profile.
    TYPE(CD_CurrentGridType), INTENT(IN), OPTIONAL :: current_grid
    LOGICAL :: field_on
    ! Static seabed friction (with seabed_mu > 0 on a seabed): the policy
    ! (CD_STATIC_FRICTION_AS_LAID or CD_STATIC_FRICTION_NONE, the default), the lay azimuth
    ! [rad, from global +x toward +y; default: the horizontal direction of the chord from
    ! the line's lower end (anchor -> fairlead, or fairlead -> anchor when the fairlead is
    ! lower), +x from the anchor for a vertical chord] and the as-laid effective tension
    ! [N, default 0] of
    ! CD_Static_As_Laid_Reference. As laid, the static solve resists every grounded node's
    ! horizontal displacement from its as-laid position with the friction springs, and the
    ! stick-slip anchors of the dynamics continue their forces; with none the static solve
    ! is frictionless in still water and the anchors start at the static node positions,
    ! while in a current the friction springs hold the line from its still-water equilibrium
    ! and the anchors continue their forces likewise.
    INTEGER, INTENT(IN), OPTIONAL :: static_friction
    REAL(wp), INTENT(IN), OPTIONAL :: lay_azimuth, as_laid_tension

    INTEGER, ALLOCATABLE :: elem_conn(:, :), fixed_dofs(:)
    REAL(wp), ALLOCATABLE :: l0(:), ea(:), mass_per_length(:), diameter(:)
    REAL(wp), ALLOCATABLE :: weight(:), elem_load(:, :), f_ext(:), q_static(:), v0(:)
    ! the waterline and diameters of the dry part's weight in the static start (unallocated:
    ! the static start keeps the buoyancy everywhere, as a model without buoyancy recovery)
    REAL(wp), ALLOCATABLE :: dry_wl(:), dry_d(:)
    INTEGER :: n_elem, n_dof, e, es, istat, fr_policy
    LOGICAL :: dyn_to, friction_static
    REAL(wp) :: laid_az, laid_t
    LOGICAL :: reverse_line, converged, use_current
    LOGICAL :: use_seabed, use_seabed_damping, use_seabed_friction, use_damping
    CHARACTER(1024) :: em
    TYPE(CableCurrentLoad) :: cur
    TYPE(CD_StaticLineReport) :: report

    ErrStat = CD_MODEL_OK
    ErrMsg = ''
    reverse_line = .FALSE.
    IF (PRESENT(anchor_is_end_b)) reverse_line = anchor_is_end_b
    IF (PRESENT(seabed_kn) .NEQV. (PRESENT(seabed_z_floor) .OR. PRESENT(bathymetry))) THEN
      CALL fail(ErrStat, ErrMsg, 'line model seabed requires seabed_kn with either seabed_z_floor or bathymetry')
      RETURN
    END IF
    IF (PRESENT(seabed_z_floor) .AND. PRESENT(bathymetry)) THEN
      CALL fail(ErrStat, ErrMsg, 'line model seabed_z_floor and bathymetry are mutually exclusive')
      RETURN
    END IF
    use_seabed = PRESENT(seabed_kn)
    use_seabed_damping = PRESENT(seabed_cn)
    use_seabed_friction = PRESENT(seabed_mu)
    use_damping = PRESENT(ba)

    IF (.NOT. CD_All_Finite(anchor) .OR. .NOT. CD_All_Finite(fairlead)) THEN
      CALL fail(ErrStat, ErrMsg, 'anchor and fairlead must be finite')
      RETURN
    END IF
    IF (.NOT. CD_Is_Finite(gravity) .OR. gravity <= CD_ZERO) THEN
      CALL fail(ErrStat, ErrMsg, 'gravity must be finite and positive')
      RETURN
    END IF
    IF (.NOT. CD_Is_Finite(rho_water) .OR. rho_water <= CD_ZERO) THEN
      CALL fail(ErrStat, ErrMsg, 'rho_water must be finite and positive')
      RETURN
    END IF

    CALL CD_Build_Line_Mesh(sections, line_types, reverse_line, elem_conn, l0, ea, &
                            mass_per_length, diameter, es, em)
    IF (es /= CD_LINE_OK) THEN
      CALL fail(ErrStat, ErrMsg, 'line mesh build failed: '//TRIM(em))
      RETURN
    END IF
    n_elem = SIZE(l0)
    n_dof = 3*(n_elem + 1)
    ALLOCATE (weight(n_elem), elem_load(3, n_elem), f_ext(n_dof), q_static(n_dof), v0(n_dof), &
              STAT=istat)
    IF (istat /= 0) THEN
      CALL alloc_fail(ErrStat, ErrMsg, 'line model temporary allocation failed')
      RETURN
    END IF

    CALL CD_Submerged_Weight(mass_per_length, diameter, rho_water, gravity, weight, es, em)
    IF (es /= 0) THEN
      CALL fail(ErrStat, ErrMsg, 'submerged weight failed: '//TRIM(em))
      RETURN
    END IF
    DO e = 1, n_elem
      elem_load(:, e) = [CD_ZERO, CD_ZERO, -weight(e)]
    END DO
    CALL CD_Assemble_Distributed_Load(elem_conn, l0, elem_load, f_ext, es, em)
    IF (es /= 0) THEN
      CALL fail(ErrStat, ErrMsg, 'load assembly failed: '//TRIM(em))
      RETURN
    END IF
    IF (use_seabed) THEN
      IF (PRESENT(seabed_z_floor)) THEN
        IF (.NOT. CD_Is_Finite(seabed_z_floor)) THEN
          CALL fail(ErrStat, ErrMsg, 'seabed_z_floor must be finite')
          RETURN
        END IF
      ELSE
        IF (.NOT. CD_Bathymetry_Is_Initialized(bathymetry)) THEN
          CALL fail(ErrStat, ErrMsg, 'line model bathymetry must be initialized')
          RETURN
        END IF
      END IF
      IF (SIZE(seabed_kn) /= n_elem + 1) THEN
        CALL fail(ErrStat, ErrMsg, 'line model seabed_kn must have shape (n_nodes)')
        RETURN
      END IF
      IF (.NOT. CD_All_Finite(seabed_kn) .OR. ANY(seabed_kn <= CD_ZERO)) THEN
        CALL fail(ErrStat, ErrMsg, 'line model seabed_kn must be finite and positive')
        RETURN
      END IF
    END IF
    IF (use_seabed_damping) THEN
      IF (.NOT. use_seabed) THEN
        CALL fail(ErrStat, ErrMsg, 'line model seabed_cn requires seabed_z_floor and seabed_kn')
        RETURN
      END IF
      IF (SIZE(seabed_cn) /= n_elem + 1) THEN
        CALL fail(ErrStat, ErrMsg, 'line model seabed_cn must have shape (n_nodes)')
        RETURN
      END IF
      IF (.NOT. CD_All_Finite(seabed_cn) .OR. ANY(seabed_cn < CD_ZERO)) THEN
        CALL fail(ErrStat, ErrMsg, 'line model seabed_cn must be finite and non-negative')
        RETURN
      END IF
    END IF
    IF (use_seabed_friction) THEN
      IF (.NOT. use_seabed) THEN
        CALL fail(ErrStat, ErrMsg, 'line model seabed_mu requires seabed_z_floor and seabed_kn')
        RETURN
      END IF
      IF (.NOT. CD_Is_Finite(seabed_mu) .OR. seabed_mu < CD_ZERO) THEN
        CALL fail(ErrStat, ErrMsg, 'line model seabed_mu must be finite and non-negative')
        RETURN
      END IF
    END IF
    IF (use_damping) THEN
      IF (SIZE(ba) /= n_elem) THEN
        CALL fail(ErrStat, ErrMsg, 'line model ba must have shape (n_elem)')
        RETURN
      END IF
      IF (.NOT. CD_All_Finite(ba) .OR. ANY(ba < CD_ZERO)) THEN
        CALL fail(ErrStat, ErrMsg, 'line model ba must be finite and non-negative')
        RETURN
      END IF
    END IF

    dyn_to = tension_only
    IF (PRESENT(dynamic_tension_only)) dyn_to = dynamic_tension_only

    ! Static seabed friction policy, lay azimuth and as-laid tension (validated even when
    ! the line has no friction, so a bad value never passes silently).
    fr_policy = CD_STATIC_FRICTION_NONE
    IF (PRESENT(static_friction)) fr_policy = static_friction
    IF (fr_policy /= CD_STATIC_FRICTION_AS_LAID .AND. fr_policy /= CD_STATIC_FRICTION_NONE) THEN
      CALL fail(ErrStat, ErrMsg, 'line model static_friction must be CD_STATIC_FRICTION_AS_LAID or _NONE')
      RETURN
    END IF
    laid_t = CD_ZERO
    IF (PRESENT(as_laid_tension)) laid_t = as_laid_tension
    IF (.NOT. CD_Is_Finite(laid_t) .OR. laid_t < CD_ZERO) THEN
      CALL fail(ErrStat, ErrMsg, 'line model as_laid_tension must be finite and non-negative')
      RETURN
    END IF
    ! default lay azimuth: the vertical plane through the line ends, from the anchor toward
    ! the fairlead (negated below when the line is laid from its fairlead, the lower end)
    laid_az = CD_ZERO
    IF (NORM2(fairlead(1:2) - anchor(1:2)) > 1.0e-9_wp*MAX(CD_ONE, NORM2(fairlead - anchor))) &
      laid_az = ATAN2(fairlead(2) - anchor(2), fairlead(1) - anchor(1))
    IF (PRESENT(lay_azimuth)) laid_az = lay_azimuth
    IF (.NOT. CD_Is_Finite(laid_az)) THEN
      CALL fail(ErrStat, ErrMsg, 'line model lay_azimuth must be finite')
      RETURN
    END IF
    ! The dynamic model's buoyancy recovery gives the part of the line above the waterline its
    ! dry weight; the static start does the same (CD_Static_Line_Equilibrium), so that a line
    ! held above the surface starts in the equilibrium its march holds.
    IF (PRESENT(buoyancy_waterline_z) .AND. PRESENT(buoyancy_rho) .AND. PRESENT(buoyancy_gravity)) THEN
      IF (SIZE(buoyancy_waterline_z) == n_dof/3) THEN
        IF (PRESENT(buoyancy_diameter_elem)) THEN
          IF (SIZE(buoyancy_diameter_elem) == n_elem .AND. .NOT. PRESENT(buoyancy_diameter)) THEN
            dry_wl = buoyancy_waterline_z
            dry_d = buoyancy_diameter_elem
          END IF
        ELSE IF (PRESENT(buoyancy_diameter)) THEN
          dry_wl = buoyancy_waterline_z
          ALLOCATE (dry_d(n_elem))
          dry_d = buoyancy_diameter
        END IF
      END IF
    END IF
    friction_static = .FALSE.
    IF (use_seabed .AND. use_seabed_friction) friction_static = seabed_mu > CD_ZERO .AND. &
                                                                fr_policy == CD_STATIC_FRICTION_AS_LAID

    ! Static initial condition: the shared robust line initializer (the same one the
    ! static-only deck route uses). The equilibrium obeys the committed model's constitutive
    ! law (dyn_to): a tension-only line gets its tension-only equilibrium, never a compressed
    ! strut. A steady current enters as Morison drag on the line at rest, with the node
    ! velocities and element hydrodynamics the dynamic model is built with, so the first
    ! dynamic step starts from equilibrium.
    ! The static start carries the current wherever the field is non-zero: in the node
    ! velocities, in the depth profile or in the current grid at t = 0 (the node velocities are
    ! sampled on the straight chord, where a current below the chord would be missed).
    use_current = .FALSE.
    IF (PRESENT(fluid_velocity) .AND. PRESENT(drag_rho)) THEN
      IF (SIZE(fluid_velocity, 1) == 3 .AND. SIZE(fluid_velocity, 2) == n_elem + 1) THEN
        field_on = ANY(ABS(fluid_velocity) > CD_ZERO)
        IF (PRESENT(current_profile_z) .AND. PRESENT(current_profile_velocity)) &
          field_on = field_on .OR. ANY(ABS(current_profile_velocity) > CD_ZERO)
        IF (PRESENT(current_grid)) THEN
          IF (ALLOCATED(current_grid%velocity)) &
            field_on = field_on .OR. ANY(ABS(current_grid%velocity(:, :, :, :, 1)) > CD_ZERO)
        END IF
        IF (field_on) THEN
          IF (PRESENT(drag_diameter_elem) .AND. PRESENT(drag_cdn_elem) .AND. PRESENT(drag_cdt_elem)) THEN
            use_current = .TRUE.
            cur%elem_diameter = drag_diameter_elem
            cur%elem_cdn = drag_cdn_elem
            cur%elem_cdt = drag_cdt_elem
          ELSE IF (PRESENT(drag_diameter) .AND. PRESENT(drag_cdn) .AND. PRESENT(drag_cdt)) THEN
            use_current = .TRUE.
            cur%diameter = drag_diameter
            cur%cdn = drag_cdn
            cur%cdt = drag_cdt
          END IF
        END IF
      END IF
    END IF
    IF (use_current) THEN
      cur%rho = drag_rho
      cur%node_velocity = fluid_velocity
      IF (PRESENT(current_profile_z) .AND. PRESENT(current_profile_velocity)) THEN
        cur%profile_z = current_profile_z
        cur%profile_velocity = current_profile_velocity
      END IF
      IF (PRESENT(current_grid)) THEN
        ALLOCATE (cur%grid, SOURCE=current_grid)
      END IF
      IF (PRESENT(drag_waterline_z)) cur%node_waterline = drag_waterline_z
      ! Without the as-laid policy a frictional seabed holds the line against the current
      ! from its still-water laid shape: solve the line without the current first; that
      ! equilibrium is the reference of the static friction springs, and their forces seed
      ! the stick-slip anchors below.
      IF (use_seabed .AND. use_seabed_friction .AND. .NOT. friction_static) THEN
        IF (seabed_mu > CD_ZERO) THEN
          CALL CD_Static_Line_Equilibrium(anchor, fairlead, elem_conn, l0, ea, weight, f_ext, static_cfg, dyn_to, &
                                          q_static, converged, report, es, em, seabed_z_floor=seabed_z_floor, &
                                          seabed_kn=seabed_kn, bathymetry=bathymetry, load_factors=load_factors, &
                                          dry_waterline_z=dry_wl, dry_rho=buoyancy_rho, dry_gravity=buoyancy_gravity, &
                                          dry_diameter=dry_d)
          IF (es /= CD_STATIC_OK .OR. .NOT. converged) THEN
            ErrStat = CD_MODEL_SOLVEFAIL
            ErrMsg = 'CableDyn_Model: still-water reference of the seabed friction failed: '//TRIM(em)// &
                     '; '//TRIM(report%message)
            RETURN
          END IF
          cur%friction_mu = seabed_mu
          IF (PRESENT(seabed_mu_axial)) cur%friction_mu_axial = seabed_mu_axial
          ALLOCATE (cur%friction_ref(2, n_elem + 1))
          DO istat = 1, n_elem + 1
            cur%friction_ref(:, istat) = q_static(3*istat - 2:3*istat - 1)
          END DO
        END IF
      END IF
    ELSE
      ! still water: the object carries only the static seabed friction (if any)
      cur%drag = .FALSE.
    END IF
    ! Static seabed friction (the OrcaFlex "as laid" policy): every grounded node is held
    ! by a friction spring toward its as-laid position -- the line laid from its lower end
    ! (the anchor, or the fairlead when that is lower) along the lay azimuth on the seabed at
    ! the as-laid tension -- capped at mu N; the spring forces then seed the stick-slip
    ! anchors of the march below.
    IF (friction_static) THEN
      cur%friction_mu = seabed_mu
      cur%friction_as_laid = .TRUE.
      IF (PRESENT(seabed_mu_axial)) cur%friction_mu_axial = seabed_mu_axial
      ALLOCATE (cur%friction_ref(2, n_elem + 1))
      BLOCK
        ! static penalty penetration factor w_i/k_i of every node (see the routine)
        REAL(wp) :: sink(n_elem + 1)
        DO istat = 1, n_elem + 1
          sink(istat) = MAX(-f_ext(3*istat), CD_ZERO)/seabed_kn(istat)
        END DO
        IF (fairlead(3) < anchor(3)) THEN
          ! the line is laid from its bottom end, here the last node (the default azimuth
          ! then points from it toward node 1)
          IF (.NOT. PRESENT(lay_azimuth)) laid_az = ATAN2(-SIN(laid_az), -COS(laid_az))
          CALL CD_Static_As_Laid_Reference(fairlead(1:2), laid_az, l0(n_elem:1:-1), ea(n_elem:1:-1), laid_t, &
                                           cur%friction_ref, es, em, bathymetry=bathymetry, &
                                           sink=sink(n_elem + 1:1:-1), kn=seabed_kn(n_elem + 1:1:-1))
          cur%friction_ref = cur%friction_ref(:, n_elem + 1:1:-1)
        ELSE
          CALL CD_Static_As_Laid_Reference(anchor(1:2), laid_az, l0, ea, laid_t, cur%friction_ref, es, em, &
                                           bathymetry=bathymetry, sink=sink, kn=seabed_kn)
        END IF
      END BLOCK
      IF (es /= CD_STATIC_OK) THEN
        CALL fail(ErrStat, ErrMsg, 'line model seabed friction: '//TRIM(em))
        RETURN
      END IF
    END IF
    IF (use_current .OR. friction_static) THEN
      CALL CD_Static_Line_Equilibrium(anchor, fairlead, elem_conn, l0, ea, weight, f_ext, static_cfg, dyn_to, &
                                      q_static, converged, report, es, em, seabed_z_floor=seabed_z_floor, &
                                      seabed_kn=seabed_kn, bathymetry=bathymetry, current=cur, &
                                      load_factors=load_factors, &
                                      dry_waterline_z=dry_wl, dry_rho=buoyancy_rho, dry_gravity=buoyancy_gravity, &
                                      dry_diameter=dry_d)
    ELSE
      CALL CD_Static_Line_Equilibrium(anchor, fairlead, elem_conn, l0, ea, weight, f_ext, static_cfg, dyn_to, &
                                      q_static, converged, report, es, em, seabed_z_floor=seabed_z_floor, &
                                      seabed_kn=seabed_kn, bathymetry=bathymetry, load_factors=load_factors, &
                                      dry_waterline_z=dry_wl, dry_rho=buoyancy_rho, dry_gravity=buoyancy_gravity, &
                                      dry_diameter=dry_d)
    END IF
    IF (es /= CD_STATIC_OK) THEN
      ErrStat = CD_MODEL_SOLVEFAIL
      ErrMsg = 'CableDyn_Model: line static initialisation failed: '//TRIM(em)
      RETURN
    END IF
    IF (.NOT. converged) THEN
      ErrStat = CD_MODEL_SOLVEFAIL
      ErrMsg = 'CableDyn_Model: line static initialisation did not converge: '//TRIM(report%message)
      ! A line that has a still-water equilibrium but none in the current: name the limit.
      IF (use_current .AND. use_seabed) THEN
        BLOCK
          REAL(wp), ALLOCATABLE :: q_sw(:)
          TYPE(CD_StaticLineReport) :: report_sw
          TYPE(CableCurrentLoad) :: cur_sw
          LOGICAL :: conv_sw
          ALLOCATE (q_sw(SIZE(q_static)))
          IF (friction_static) THEN
            ! still water with the same as-laid seabed friction
            cur_sw%drag = .FALSE.
            cur_sw%friction_mu = cur%friction_mu
            cur_sw%friction_mu_axial = cur%friction_mu_axial
            cur_sw%friction_ref = cur%friction_ref
            cur_sw%friction_as_laid = .TRUE.
            CALL CD_Static_Line_Equilibrium(anchor, fairlead, elem_conn, l0, ea, weight, f_ext, static_cfg, &
                                            dyn_to, q_sw, conv_sw, report_sw, es, em, &
                                            seabed_z_floor=seabed_z_floor, seabed_kn=seabed_kn, &
                                            bathymetry=bathymetry, current=cur_sw, load_factors=load_factors, &
                                            dry_waterline_z=dry_wl, dry_rho=buoyancy_rho, &
                                            dry_gravity=buoyancy_gravity, dry_diameter=dry_d)
          ELSE
            CALL CD_Static_Line_Equilibrium(anchor, fairlead, elem_conn, l0, ea, weight, f_ext, static_cfg, &
                                            dyn_to, q_sw, conv_sw, report_sw, es, em, &
                                            seabed_z_floor=seabed_z_floor, seabed_kn=seabed_kn, &
                                            bathymetry=bathymetry, load_factors=load_factors, &
                                            dry_waterline_z=dry_wl, dry_rho=buoyancy_rho, &
                                            dry_gravity=buoyancy_gravity, dry_diameter=dry_d)
          END IF
          IF (es == CD_STATIC_OK .AND. conv_sw) THEN
            IF (ALLOCATED(cur%friction_ref)) THEN
              ErrMsg = 'CableDyn_Model: the line has a still-water equilibrium but none in the current: '// &
                       'the seabed friction cannot hold the line against the current (it pushes the line '// &
                       'along the seabed or into the touchdown harder than the suspended span holds it); '// &
                       TRIM(report%message)
            ELSE
              ErrMsg = 'CableDyn_Model: the line has a still-water equilibrium but none in the current: '// &
                       'the current pushes the line along the frictionless seabed toward its anchor harder '// &
                       'than the suspended span holds it (declare OPTIONS frictionMu where the seabed holds '// &
                       'the run); '//TRIM(report%message)
            END IF
          END IF
        END BLOCK
      END IF
      RETURN
    END IF
    ALLOCATE (fixed_dofs(6), STAT=istat)
    IF (istat /= 0) THEN
      CALL alloc_fail(ErrStat, ErrMsg, 'line model fixed-dof allocation failed')
      RETURN
    END IF
    fixed_dofs = [1, 2, 3, n_dof - 2, n_dof - 1, n_dof]

    v0 = CD_ZERO
    IF (use_seabed .AND. use_damping) THEN
      CALL CD_Init_Model(model, q_static, v0, elem_conn, l0, ea, mass_per_length, dyn_to, &
                         f_ext, fixed_dofs, dynamic_cfg, ErrStat, ErrMsg, &
                         dist_load_per_length=elem_load, &
                         seabed_kbot=seabed_kbot, seabed_contact_diameter=seabed_contact_diameter, &
                         seabed_cn_over_kn=seabed_cn_over_kn, &
                         seabed_z_floor=seabed_z_floor, seabed_kn=seabed_kn, seabed_cn=seabed_cn, &
                         seabed_mu=seabed_mu, ba=ba, &
                         fluid_velocity=fluid_velocity, drag_waterline_z=drag_waterline_z, &
                         drag_rho=drag_rho, drag_diameter=drag_diameter, drag_cdn=drag_cdn, drag_cdt=drag_cdt, &
                         drag_diameter_elem=drag_diameter_elem, drag_cdn_elem=drag_cdn_elem, &
                         drag_cdt_elem=drag_cdt_elem, &
                         fluid_acceleration=fluid_acceleration, fk_waterline_z=fk_waterline_z, &
                         fk_rho=fk_rho, fk_diameter=fk_diameter, fk_can=fk_can, fk_cat=fk_cat, &
                         fk_diameter_elem=fk_diameter_elem, fk_can_elem=fk_can_elem, fk_cat_elem=fk_cat_elem, &
                         buoyancy_waterline_z=buoyancy_waterline_z, buoyancy_rho=buoyancy_rho, &
                         buoyancy_diameter=buoyancy_diameter, buoyancy_gravity=buoyancy_gravity, &
                         buoyancy_diameter_elem=buoyancy_diameter_elem, &
                         added_mass_waterline_z=added_mass_waterline_z, added_mass_rho=added_mass_rho, &
                         added_mass_diameter=added_mass_diameter, added_mass_can=added_mass_can, &
                         added_mass_cat=added_mass_cat, added_mass_diameter_elem=added_mass_diameter_elem, &
                         added_mass_can_elem=added_mass_can_elem, added_mass_cat_elem=added_mass_cat_elem, &
                         bathymetry=bathymetry, ve_ea_d=ve_ea_d, ve_ba=ve_ba, ve_ba_d=ve_ba_d, &
                         ve_alpha_mbl=ve_alpha_mbl, ve_vbeta=ve_vbeta, &
                         syrope_is=syrope_is, syrope_type=syrope_type, syrope_slow0=syrope_slow0, &
                         syrope_tmax0=syrope_tmax0)
    ELSE IF (use_seabed) THEN
      CALL CD_Init_Model(model, q_static, v0, elem_conn, l0, ea, mass_per_length, dyn_to, &
                         f_ext, fixed_dofs, dynamic_cfg, ErrStat, ErrMsg, &
                         dist_load_per_length=elem_load, &
                         seabed_kbot=seabed_kbot, seabed_contact_diameter=seabed_contact_diameter, &
                         seabed_cn_over_kn=seabed_cn_over_kn, &
                         seabed_z_floor=seabed_z_floor, seabed_kn=seabed_kn, seabed_cn=seabed_cn, &
                         seabed_mu=seabed_mu, &
                         fluid_velocity=fluid_velocity, drag_waterline_z=drag_waterline_z, &
                         drag_rho=drag_rho, drag_diameter=drag_diameter, drag_cdn=drag_cdn, drag_cdt=drag_cdt, &
                         drag_diameter_elem=drag_diameter_elem, drag_cdn_elem=drag_cdn_elem, &
                         drag_cdt_elem=drag_cdt_elem, &
                         fluid_acceleration=fluid_acceleration, fk_waterline_z=fk_waterline_z, &
                         fk_rho=fk_rho, fk_diameter=fk_diameter, fk_can=fk_can, fk_cat=fk_cat, &
                         fk_diameter_elem=fk_diameter_elem, fk_can_elem=fk_can_elem, fk_cat_elem=fk_cat_elem, &
                         buoyancy_waterline_z=buoyancy_waterline_z, buoyancy_rho=buoyancy_rho, &
                         buoyancy_diameter=buoyancy_diameter, buoyancy_gravity=buoyancy_gravity, &
                         buoyancy_diameter_elem=buoyancy_diameter_elem, &
                         added_mass_waterline_z=added_mass_waterline_z, added_mass_rho=added_mass_rho, &
                         added_mass_diameter=added_mass_diameter, added_mass_can=added_mass_can, &
                         added_mass_cat=added_mass_cat, added_mass_diameter_elem=added_mass_diameter_elem, &
                         added_mass_can_elem=added_mass_can_elem, added_mass_cat_elem=added_mass_cat_elem, &
                         bathymetry=bathymetry, ve_ea_d=ve_ea_d, ve_ba=ve_ba, ve_ba_d=ve_ba_d, &
                         ve_alpha_mbl=ve_alpha_mbl, ve_vbeta=ve_vbeta, &
                         syrope_is=syrope_is, syrope_type=syrope_type, syrope_slow0=syrope_slow0, &
                         syrope_tmax0=syrope_tmax0)
    ELSE IF (use_damping) THEN
      CALL CD_Init_Model(model, q_static, v0, elem_conn, l0, ea, mass_per_length, dyn_to, &
                         f_ext, fixed_dofs, dynamic_cfg, ErrStat, ErrMsg, ba=ba, &
                         ve_ea_d=ve_ea_d, ve_ba=ve_ba, ve_ba_d=ve_ba_d, ve_alpha_mbl=ve_alpha_mbl, ve_vbeta=ve_vbeta, &
                         syrope_is=syrope_is, syrope_type=syrope_type, syrope_slow0=syrope_slow0, &
                         syrope_tmax0=syrope_tmax0, &
                         dist_load_per_length=elem_load, &
                         seabed_kbot=seabed_kbot, seabed_contact_diameter=seabed_contact_diameter, &
                         seabed_cn_over_kn=seabed_cn_over_kn, &
                         fluid_velocity=fluid_velocity, drag_waterline_z=drag_waterline_z, &
                         drag_rho=drag_rho, drag_diameter=drag_diameter, drag_cdn=drag_cdn, drag_cdt=drag_cdt, &
                         drag_diameter_elem=drag_diameter_elem, drag_cdn_elem=drag_cdn_elem, &
                         drag_cdt_elem=drag_cdt_elem, &
                         fluid_acceleration=fluid_acceleration, fk_waterline_z=fk_waterline_z, &
                         fk_rho=fk_rho, fk_diameter=fk_diameter, fk_can=fk_can, fk_cat=fk_cat, &
                         fk_diameter_elem=fk_diameter_elem, fk_can_elem=fk_can_elem, fk_cat_elem=fk_cat_elem, &
                         buoyancy_waterline_z=buoyancy_waterline_z, buoyancy_rho=buoyancy_rho, &
                         buoyancy_diameter=buoyancy_diameter, buoyancy_gravity=buoyancy_gravity, &
                         buoyancy_diameter_elem=buoyancy_diameter_elem, &
                         added_mass_waterline_z=added_mass_waterline_z, added_mass_rho=added_mass_rho, &
                         added_mass_diameter=added_mass_diameter, added_mass_can=added_mass_can, &
                         added_mass_cat=added_mass_cat, added_mass_diameter_elem=added_mass_diameter_elem, &
                         added_mass_can_elem=added_mass_can_elem, added_mass_cat_elem=added_mass_cat_elem)
    ELSE
      CALL CD_Init_Model(model, q_static, v0, elem_conn, l0, ea, mass_per_length, dyn_to, &
                         f_ext, fixed_dofs, dynamic_cfg, ErrStat, ErrMsg, &
                         ve_ea_d=ve_ea_d, ve_ba=ve_ba, ve_ba_d=ve_ba_d, ve_alpha_mbl=ve_alpha_mbl, ve_vbeta=ve_vbeta, &
                         syrope_is=syrope_is, syrope_type=syrope_type, syrope_slow0=syrope_slow0, &
                         syrope_tmax0=syrope_tmax0, &
                         dist_load_per_length=elem_load, &
                         seabed_kbot=seabed_kbot, seabed_contact_diameter=seabed_contact_diameter, &
                         seabed_cn_over_kn=seabed_cn_over_kn, &
                         fluid_velocity=fluid_velocity, drag_waterline_z=drag_waterline_z, &
                         drag_rho=drag_rho, drag_diameter=drag_diameter, drag_cdn=drag_cdn, drag_cdt=drag_cdt, &
                         drag_diameter_elem=drag_diameter_elem, drag_cdn_elem=drag_cdn_elem, &
                         drag_cdt_elem=drag_cdt_elem, &
                         fluid_acceleration=fluid_acceleration, fk_waterline_z=fk_waterline_z, &
                         fk_rho=fk_rho, fk_diameter=fk_diameter, fk_can=fk_can, fk_cat=fk_cat, &
                         fk_diameter_elem=fk_diameter_elem, fk_can_elem=fk_can_elem, fk_cat_elem=fk_cat_elem, &
                         buoyancy_waterline_z=buoyancy_waterline_z, buoyancy_rho=buoyancy_rho, &
                         buoyancy_diameter=buoyancy_diameter, buoyancy_gravity=buoyancy_gravity, &
                         buoyancy_diameter_elem=buoyancy_diameter_elem, &
                         added_mass_waterline_z=added_mass_waterline_z, added_mass_rho=added_mass_rho, &
                         added_mass_diameter=added_mass_diameter, added_mass_can=added_mass_can, &
                         added_mass_cat=added_mass_cat, added_mass_diameter_elem=added_mass_diameter_elem, &
                         added_mass_can_elem=added_mass_can_elem, added_mass_cat_elem=added_mass_cat_elem)
    END IF
    IF (ErrStat /= CD_MODEL_OK) RETURN
    IF (PRESENT(seabed_mu_axial)) THEN
      IF (CD_Model_Has_Friction(model) .AND. seabed_mu_axial > CD_ZERO) THEN
        CALL CD_Set_Model_Friction_Axial(model, seabed_mu_axial, ErrStat, ErrMsg)
        IF (ErrStat /= CD_MODEL_OK) RETURN
      END IF
    END IF
    ! Continue the static friction springs into the dynamics: the stick-slip anchors carry
    ! the static spring forces, so the march starts in the static equilibrium.
    IF (ALLOCATED(cur%friction_ref) .AND. CD_Model_Has_Friction(model)) THEN
      BLOCK
        REAL(wp), ALLOCATABLE :: anchors(:, :)
        ALLOCATE (anchors(2, n_elem + 1))
        IF (PRESENT(bathymetry)) THEN
          CALL CD_Static_Friction_Anchors(q_static, cur, seabed_kn, anchors, es, em, bathymetry=bathymetry)
        ELSE
          CALL CD_Static_Friction_Anchors(q_static, cur, seabed_kn, anchors, es, em, seabed_z_floor=seabed_z_floor)
        END IF
        IF (es /= CD_STATIC_OK) THEN
          es = CD_MODEL_SOLVEFAIL
        ELSE
          CALL CD_Set_Model_Friction_Anchors(model, anchors, es, em)
          IF (es == CD_MODEL_OK) CALL CD_Recompute_Model_Acceleration(model, es, em)
        END IF
        IF (es /= CD_MODEL_OK) THEN
          ErrStat = CD_MODEL_SOLVEFAIL
          ErrMsg = 'CableDyn_Model: seabed friction anchors failed: '//TRIM(em)
          RETURN
        END IF
      END BLOCK
    END IF
  END SUBROUTINE CD_Init_Line_Model

  SUBROUTINE CD_Step_Model(model, dt, converged, stalled, n_iter, ErrStat, ErrMsg, &
                           prescribed_q, prescribed_v, prescribed_a, as_given)
    !! Advance the persistent model over dt. Optional prescribed_q/v/a arrays are full
    !! model-sized vectors at the end of the step; only entries in model%fixed_dofs are
    !! consumed by CableDyn_Dynamic. On successful or stalled dynamics returns, the model owns
    !! the returned state. On solver failure, the underlying step contract preserves the
    !! previous state.
    !!
    !! Rotation- and snap-resolved sub-stepping (cfg%ei0_substeps = CD_EI0_SUBSTEPS_AUTO, the
    !! default; the settings are checked by CD_Init_Model): the step is solved as given; when it
    !! converges and a segment that ends it taut turned by more than cfg%ei0_substep_angle
    !! degrees, or a segment slack at its start ends it above SUB_SNAP_FRACTION of the tension
    !! scale while the step does not resolve its axial wave (see SUB_SNAP_FRACTION), the
    !! interval is solved again from the same committed state in
    !! n = max(SUB_SNAP_STEPS, ceil(turn/angle)) equal sub-steps, at most cfg%ei0_substep_max.
    !! The trial step under-turns a line whose rotation it does not resolve, so the sub-stepped
    !! interval is measured again and, when its turn needs more sub-steps, solved once more with
    !! them. The prescribed end motion inside the interval follows the C2 quintic of
    !! CD_Step_Model_Recovering and the last sub-step lands on the given end state exactly. The
    !! decision depends only on the committed state, the step's inputs and the line's initial
    !! tension (a parameter of the line), so a run restarted from a checkpoint repeats it. If a
    !! sub-step fails, the plain step's own result is returned. A step of the monolithic junction
    !! coupling (the end query armed, CD_Set_Model_EndQuery) is never sub-stepped: its caller
    !! needs the end reaction and tangent of the nominal step. as_given = .TRUE. takes the step
    !! as given as well: the stall recoveries of CD_Step_Model_Recovering and CD_Step_System,
    !! whose sub-steps are themselves part of a recovery, pass it.
    !!
    !! A pending length change (active line control: CD_Update_Model_SegmentLength set lengths
    !! or rates that differ from those the committed state was reached with, l0_c and l0_dot_c)
    !! is spread over the sub-steps. The committed lengths are part of the state each pass
    !! starts from (commit_state_copy). Sub-step k of n ends at the lengths and rates
    !! interpolated linearly in time between the committed ones and the new ones at k/n, with
    !! the external load and seabed coefficients rebuilt at those lengths as
    !! CD_Update_Model_SegmentLength builds them, and the last sub-step ends at the new lengths,
    !! rates, external load and seabed coefficients bit for bit. Each sub-step treats its own
    !! start and end lengths as the plain step treats the committed and new ones, so the first
    !! starts at the committed lengths. (A constant pay-out rate, the usual command, makes the
    !! interpolated lengths those its rate integrates to.) The trigger takes the step-start
    !! tensions and slack classification at the committed lengths.
    TYPE(CD_ModelType), INTENT(INOUT) :: model
    REAL(wp), INTENT(IN) :: dt
    LOGICAL, INTENT(OUT) :: converged, stalled
    INTEGER, INTENT(OUT) :: n_iter, ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    REAL(wp), INTENT(IN), OPTIONAL :: prescribed_q(:), prescribed_v(:), prescribed_a(:)
    LOGICAL, INTENT(IN), OPTIONAL :: as_given
    INTEGER :: nsub, nsub2, iter_trial
    LOGICAL :: has_pres, resolve, capped, capped2, ok, pending

    has_pres = PRESENT(prescribed_q) .AND. PRESENT(prescribed_v) .AND. PRESENT(prescribed_a)
    pending = .FALSE.
    resolve = model%initialized .AND. model%cfg%ei0_substeps == CD_EI0_SUBSTEPS_AUTO .AND. &
              .NOT. model%dynamic_workspace%end_request
    IF (resolve .AND. PRESENT(as_given)) resolve = .NOT. as_given
    ! partial prescribed motion: the plain step reports the input error
    IF (resolve) resolve = has_pres .OR. .NOT. (PRESENT(prescribed_q) .OR. PRESENT(prescribed_v) .OR. &
                                                PRESENT(prescribed_a))
    IF (resolve) THEN
      resolve = sub_alloc(model, has_pres)
      IF (resolve) THEN
        CALL sub_store(model, 1)
        ! the segment tensions at the step start, for the trigger (sub_count), at the lengths
        ! the committed state was reached with
        pending = .NOT. model_lengths_committed(model)
        IF (pending) THEN
          CALL CD_Save_Model_Control(model, model%sub_target)
          BLOCK
            TYPE(model_lengths_aside) :: aside
            INTEGER :: es_c
            CHARACTER(1024) :: em_c
            ! without the loads nothing is rebuilt, so this cannot fail
            CALL enter_committed_lengths(model, aside, .FALSE., es_c, em_c)
            CALL sub_tensions_scratch(model, 0)
            CALL leave_committed_lengths(model, aside)
          END BLOCK
        ELSE
          CALL sub_tensions_scratch(model, 0)
        END IF
      END IF
    END IF
    IF (.NOT. resolve) THEN
      ! absent optional arguments stay absent
      CALL step_model_plain(model, dt, converged, stalled, n_iter, ErrStat, ErrMsg, &
                            prescribed_q=prescribed_q, prescribed_v=prescribed_v, prescribed_a=prescribed_a)
      IF (ErrStat == CD_MODEL_OK) model%audit_hmax = MAX(model%audit_hmax, dt)
      RETURN
    END IF

    CALL step_model_plain(model, dt, converged, stalled, n_iter, ErrStat, ErrMsg, &
                          prescribed_q=prescribed_q, prescribed_v=prescribed_v, prescribed_a=prescribed_a)
    IF (ErrStat /= CD_MODEL_OK) RETURN
    model%sub_stats%calls = model%sub_stats%calls + 1
    nsub = 1
    capped = .FALSE.
    IF (converged) CALL sub_count(model, dt, nsub, capped)
    IF (nsub <= 1) THEN
      model%audit_hmax = MAX(model%audit_hmax, dt)
      RETURN
    END IF
    ! keep the plain step's result: it is returned should a sub-step fail
    CALL sub_store(model, 2)
    iter_trial = n_iter

    ! Solve the interval again from the committed state in nsub sub-steps. The trial step
    ! under-turns a line whose rotation it does not resolve, so the sub-stepped interval is
    ! measured again: when its turn needs more sub-steps, it is solved once more with them (and
    ! the first count is kept should that fail).
    CALL run_substeps(nsub, ok)
    IF (ok .AND. model%sub_test_repeat) CALL run_substeps(nsub, ok)
    IF (ok) THEN
      CALL sub_count(model, dt, nsub2, capped2)
      IF (model%sub_test_more) nsub2 = MAX(nsub2, MIN(model%cfg%ei0_substep_max, nsub + 1))
      IF (nsub2 > nsub) THEN
        model%sub_stats%remeasured = model%sub_stats%remeasured + 1
        CALL run_substeps(nsub2, ok)
        IF (ok) THEN
          nsub = nsub2
          capped = capped2
        ELSE
          CALL run_substeps(nsub, ok)
        END IF
      END IF
    END IF
    IF (ok) THEN
      converged = .TRUE.
      stalled = .FALSE.
      ErrStat = CD_MODEL_OK
      ErrMsg = ''
      model%sub_stats%events = model%sub_stats%events + 1
      IF (capped) model%sub_stats%capped = model%sub_stats%capped + 1
      model%sub_stats%max_used = MAX(model%sub_stats%max_used, nsub)
      model%audit_hmax = MAX(model%audit_hmax, dt/REAL(nsub, wp))
      RETURN
    END IF
    ! a sub-step failed: return the plain step's own (converged) result
    CALL sub_load(model, 2)
    IF (pending) CALL sub_lengths_target(model)
    converged = .TRUE.
    stalled = .FALSE.
    n_iter = iter_trial
    ErrStat = CD_MODEL_OK
    ErrMsg = ''
    model%sub_stats%fallbacks = model%sub_stats%fallbacks + 1
    model%audit_hmax = MAX(model%audit_hmax, dt)

  CONTAINS

    SUBROUTINE run_substeps(n, ok_run)
      !! The interval from the committed state (slot 1) in n equal sub-steps, the prescribed
      !! end motion on the C2 quintic of the interval, the last sub-step on the given end state.
      INTEGER, INTENT(IN) :: n
      LOGICAL, INTENT(OUT) :: ok_run
      INTEGER :: k, it_k, es_k
      LOGICAL :: conv_k, stall_k
      REAL(wp) :: h
      CHARACTER(1024) :: em_k ! a plain step's message (discarded: the step falls back)
      CALL sub_load(model, 1)
      h = dt/REAL(n, wp)
      ok_run = .TRUE.
      DO k = 1, n
        ! a pending length change: the lengths at the sub-step end (the new ones at the last)
        IF (pending) THEN
          IF (k == n) THEN
            CALL sub_lengths_target(model)
          ELSE
            CALL sub_lengths_at(model, REAL(k, wp)/REAL(n, wp), es_k)
            IF (es_k /= CD_MODEL_OK) THEN
              CALL sub_lengths_target(model)
              ok_run = .FALSE.
              RETURN
            END IF
          END IF
        END IF
        IF (has_pres) THEN
          IF (k == n) THEN
            model%sub_pq = prescribed_q
            model%sub_pv = prescribed_v
            model%sub_pa = prescribed_a
          ELSE
            CALL quintic_model_boundary_state(model%sub_slot(1)%q, model%sub_slot(1)%v, model%sub_slot(1)%a, &
                                              prescribed_q, prescribed_v, prescribed_a, dt, &
                                              REAL(k, wp)/REAL(n, wp), model%sub_pq, model%sub_pv, model%sub_pa)
          END IF
          CALL step_model_plain(model, h, conv_k, stall_k, it_k, es_k, em_k, prescribed_q=model%sub_pq, &
                                prescribed_v=model%sub_pv, prescribed_a=model%sub_pa)
        ELSE
          CALL step_model_plain(model, h, conv_k, stall_k, it_k, es_k, em_k)
        END IF
        IF (k == model%sub_test_fail) conv_k = .FALSE.
        IF (es_k /= CD_MODEL_OK .OR. .NOT. conv_k) THEN
          IF (pending) CALL sub_lengths_target(model)
          ok_run = .FALSE.
          RETURN
        END IF
        n_iter = MAX(n_iter, it_k)
      END DO
    END SUBROUTINE run_substeps
  END SUBROUTINE CD_Step_Model

  LOGICAL FUNCTION sub_alloc(model, has_pres) RESULT(ok)
    !! Allocate the sub-stepping scratch on first use: two slots of the state a step commits
    !! (CD_ModelCommitSlot), the step-start and end segment tensions and the sub-step boundary
    !! motion. .FALSE. when it cannot be allocated (the step is then taken as given).
    TYPE(CD_ModelType), INTENT(INOUT) :: model
    LOGICAL, INTENT(IN) :: has_pres
    INTEGER :: istat, k
    ok = .FALSE.
    istat = 0
    DO k = 1, 2
      ASSOCIATE (s => model%sub_slot(k))
        IF (.NOT. sized(s%q, model%n_dof)) THEN
          IF (ALLOCATED(s%q)) DEALLOCATE (s%q, s%v, s%a)
          ALLOCATE (s%q(model%n_dof), s%v(model%n_dof), s%a(model%n_dof), STAT=istat)
          IF (istat /= 0) RETURN
        END IF
        IF (.NOT. sized(s%l0_c, model%n_elem)) THEN
          IF (ALLOCATED(s%l0_c)) DEALLOCATE (s%l0_c, s%l0_dot_c)
          ALLOCATE (s%l0_c(model%n_elem), s%l0_dot_c(model%n_elem), STAT=istat)
          IF (istat /= 0) RETURN
        END IF
        IF (model%has_viscoelastic) THEN
          IF (.NOT. sized(s%ve_dl_1, SIZE(model%ve_dl_1))) THEN
            IF (ALLOCATED(s%ve_dl_1)) DEALLOCATE (s%ve_dl_1)
            ALLOCATE (s%ve_dl_1(SIZE(model%ve_dl_1)), STAT=istat)
            IF (istat /= 0) RETURN
          END IF
        END IF
        IF (model%has_syrope) THEN
          IF (.NOT. sized(s%syrope_slow, SIZE(model%syrope_slow))) THEN
            IF (ALLOCATED(s%syrope_slow)) DEALLOCATE (s%syrope_slow, s%syrope_tmax)
            ALLOCATE (s%syrope_slow(SIZE(model%syrope_slow)), s%syrope_tmax(SIZE(model%syrope_tmax)), STAT=istat)
            IF (istat /= 0) RETURN
          END IF
        END IF
        IF (model%has_seabed_friction) THEN
          IF (ALLOCATED(s%fr_anchor)) THEN
            IF (SIZE(s%fr_anchor, 1) /= SIZE(model%fr_anchor, 1) .OR. &
                SIZE(s%fr_anchor, 2) /= SIZE(model%fr_anchor, 2)) DEALLOCATE (s%fr_anchor)
          END IF
          IF (.NOT. ALLOCATED(s%fr_anchor)) THEN
            ALLOCATE (s%fr_anchor(SIZE(model%fr_anchor, 1), SIZE(model%fr_anchor, 2)), STAT=istat)
            IF (istat /= 0) RETURN
          END IF
        END IF
        IF (model%has_viv) THEN
          IF (.NOT. sized(s%viv_phi, SIZE(model%viv_phi))) THEN
            IF (ALLOCATED(s%viv_phi)) DEALLOCATE (s%viv_phi, s%viv_ms)
            ALLOCATE (s%viv_phi(SIZE(model%viv_phi)), s%viv_ms(2, SIZE(model%viv_phi)), STAT=istat)
            IF (istat /= 0) RETURN
          END IF
        END IF
      END ASSOCIATE
    END DO
    IF (.NOT. sized(model%sub_t0, model%n_elem)) THEN
      IF (ALLOCATED(model%sub_t0)) DEALLOCATE (model%sub_t0)
      ALLOCATE (model%sub_t0(model%n_elem), STAT=istat)
      IF (istat /= 0) RETURN
    END IF
    IF (.NOT. sized(model%sub_t1, model%n_elem)) THEN
      IF (ALLOCATED(model%sub_t1)) DEALLOCATE (model%sub_t1)
      ALLOCATE (model%sub_t1(model%n_elem), STAT=istat)
      IF (istat /= 0) RETURN
    END IF
    IF (has_pres) THEN
      IF (.NOT. sized(model%sub_pq, model%n_dof)) THEN
        IF (ALLOCATED(model%sub_pq)) DEALLOCATE (model%sub_pq, model%sub_pv, model%sub_pa)
        ALLOCATE (model%sub_pq(model%n_dof), model%sub_pv(model%n_dof), model%sub_pa(model%n_dof), STAT=istat)
        IF (istat /= 0) RETURN
      END IF
    END IF
    ok = .TRUE.
  CONTAINS
    LOGICAL FUNCTION sized(x, n) RESULT(yes)
      REAL(wp), ALLOCATABLE, INTENT(IN) :: x(:)
      INTEGER, INTENT(IN) :: n
      yes = ALLOCATED(x)
      IF (yes) yes = SIZE(x) == n
    END FUNCTION sized
  END FUNCTION sub_alloc

  SUBROUTINE commit_state_copy(model, to_model, q, v, a, ve_dl_1, syrope_slow, syrope_tmax, fr_anchor, &
                               l0_c, l0_dot_c, viv_phi, viv_ms)
    !! The one list of the state a line step commits: the kinematics, the viscoelastic dl_1, the
    !! Syrope slow strain and running maximum tension, the friction anchors, the unstretched
    !! lengths and rates the committed state was reached with (l0_c, l0_dot_c, active line
    !! control), and the VIV shedding phases and running mean squares. to_model =
    !! .FALSE. saves the model's state into the arrays given, .TRUE. returns the model to them.
    !! Every snapshot of the committed state in this module goes through here (the sub-step
    !! slots of CD_Step_Model, save_recovery_state and restore_recovery_state). A state a step
    !! comes to commit is added here, as an optional array its snapshots pass; the rollback of the line system
    !! (CableDyn_System: save_line_states, restore_line_states, CD_System_Snapshot and the
    !! frame snapshot of CD_Step_System) lists the same state and must follow. An optional array
    !! is passed as an allocatable that is allocated with the state it holds, so it is absent
    !! (not allocated) exactly when the model does not carry that state.
    TYPE(CD_ModelType), INTENT(INOUT) :: model
    LOGICAL, INTENT(IN) :: to_model
    REAL(wp), INTENT(INOUT) :: q(:), v(:), a(:)
    REAL(wp), INTENT(INOUT), OPTIONAL :: ve_dl_1(:), syrope_slow(:), syrope_tmax(:), fr_anchor(:, :)
    REAL(wp), INTENT(INOUT), OPTIONAL :: l0_c(:), l0_dot_c(:), viv_phi(:), viv_ms(:, :)
    IF (to_model) THEN
      model%q = q
      model%v = v
      model%a = a
      IF (model%has_viscoelastic .AND. PRESENT(ve_dl_1)) model%ve_dl_1 = ve_dl_1
      IF (model%has_syrope .AND. PRESENT(syrope_slow) .AND. PRESENT(syrope_tmax)) THEN
        model%syrope_slow = syrope_slow
        model%syrope_tmax = syrope_tmax
      END IF
      IF (model%has_seabed_friction .AND. PRESENT(fr_anchor)) model%fr_anchor = fr_anchor
      IF (PRESENT(l0_c) .AND. PRESENT(l0_dot_c)) THEN
        model%l0_c = l0_c
        model%l0_dot_c = l0_dot_c
      END IF
      IF (model%has_viv .AND. PRESENT(viv_phi) .AND. PRESENT(viv_ms)) THEN
        model%viv_phi = viv_phi
        model%viv_ms = viv_ms
        model%viv_phi_eval = viv_phi
      END IF
    ELSE
      q = model%q
      v = model%v
      a = model%a
      IF (model%has_viscoelastic .AND. PRESENT(ve_dl_1)) ve_dl_1 = model%ve_dl_1
      IF (model%has_syrope .AND. PRESENT(syrope_slow) .AND. PRESENT(syrope_tmax)) THEN
        syrope_slow = model%syrope_slow
        syrope_tmax = model%syrope_tmax
      END IF
      IF (model%has_seabed_friction .AND. PRESENT(fr_anchor)) fr_anchor = model%fr_anchor
      IF (PRESENT(l0_c) .AND. PRESENT(l0_dot_c)) THEN
        l0_c = model%l0_c
        l0_dot_c = model%l0_dot_c
      END IF
      IF (model%has_viv .AND. PRESENT(viv_phi) .AND. PRESENT(viv_ms)) THEN
        viv_phi = model%viv_phi
        viv_ms = model%viv_ms
      END IF
    END IF
  END SUBROUTINE commit_state_copy

  SUBROUTINE sub_store(model, slot)
    !! Save the state a step commits into slot 1 (the step start) or 2 (the plain step's result).
    TYPE(CD_ModelType), INTENT(INOUT) :: model
    INTEGER, INTENT(IN) :: slot
    CALL commit_state_copy(model, .FALSE., model%sub_slot(slot)%q, model%sub_slot(slot)%v, model%sub_slot(slot)%a, &
                           model%sub_slot(slot)%ve_dl_1, model%sub_slot(slot)%syrope_slow, &
                           model%sub_slot(slot)%syrope_tmax, model%sub_slot(slot)%fr_anchor, &
                           model%sub_slot(slot)%l0_c, model%sub_slot(slot)%l0_dot_c, &
                           model%sub_slot(slot)%viv_phi, model%sub_slot(slot)%viv_ms)
  END SUBROUTINE sub_store

  SUBROUTINE sub_load(model, slot)
    !! Return the model to the state saved in slot (sub_store).
    TYPE(CD_ModelType), INTENT(INOUT) :: model
    INTEGER, INTENT(IN) :: slot
    CALL commit_state_copy(model, .TRUE., model%sub_slot(slot)%q, model%sub_slot(slot)%v, model%sub_slot(slot)%a, &
                           model%sub_slot(slot)%ve_dl_1, model%sub_slot(slot)%syrope_slow, &
                           model%sub_slot(slot)%syrope_tmax, model%sub_slot(slot)%fr_anchor, &
                           model%sub_slot(slot)%l0_c, model%sub_slot(slot)%l0_dot_c, &
                           model%sub_slot(slot)%viv_phi, model%sub_slot(slot)%viv_ms)
  END SUBROUTINE sub_load

  SUBROUTINE sub_lengths_target(model)
    !! Put back the lengths, rates, external load and seabed coefficients a pending length
    !! change set for the end of the step (sub_target, saved by CD_Step_Model), bit for bit; the
    !! committed lengths are left as they are.
    TYPE(CD_ModelType), INTENT(INOUT) :: model
    model%l0 = model%sub_target%l0
    model%l0_dot = model%sub_target%l0_dot
    model%f_ext = model%sub_target%f_ext
    IF (ALLOCATED(model%sub_target%seabed_kn)) model%seabed_kn = model%sub_target%seabed_kn
    IF (ALLOCATED(model%sub_target%seabed_cn)) model%seabed_cn = model%sub_target%seabed_cn
  END SUBROUTINE sub_lengths_target

  SUBROUTINE sub_lengths_at(model, frac, ErrStat)
    !! The lengths and rates at the fraction frac of a sub-stepped interval with a pending length
    !! change: interpolated linearly in time between those of the committed state at the
    !! interval start (sub_slot(1)) and the new ones (sub_target), an element whose length or
    !! rate does not change keeping it bit for bit; the external load and the seabed
    !! coefficients that follow the lengths are rebuilt at them with the helpers
    !! CD_Update_Model_SegmentLength uses (those of the new lengths when no length changes).
    !! On failure the model is left as it was.
    TYPE(CD_ModelType), INTENT(INOUT) :: model
    REAL(wp), INTENT(IN) :: frac
    INTEGER, INTENT(OUT) :: ErrStat
    REAL(wp) :: l0_k(model%n_elem), l0_dot_k(model%n_elem), f_dist(model%n_dof)
    REAL(wp), ALLOCATABLE :: kn_k(:)
    REAL(wp) :: a, b
    INTEGER :: e, es
    LOGICAL :: moved
    CHARACTER(KERNEL_MSG_LEN) :: em
    ErrStat = CD_MODEL_OK
    moved = .FALSE.
    DO e = 1, model%n_elem
      a = model%sub_slot(1)%l0_c(e)
      b = model%sub_target%l0(e)
      l0_k(e) = b
      IF (.NOT. bits_equal(a, b)) THEN
        l0_k(e) = a + frac*(b - a)
        moved = .TRUE.
      END IF
      a = model%sub_slot(1)%l0_dot_c(e)
      b = model%sub_target%l0_dot(e)
      l0_dot_k(e) = b
      IF (.NOT. bits_equal(a, b)) l0_dot_k(e) = positive_zero(a + frac*(b - a))
    END DO
    IF (moved .AND. ALLOCATED(model%dist_load)) THEN
      CALL CD_Assemble_Distributed_Load(model%elem_conn, l0_k, model%dist_load, f_dist, es, em)
      IF (es /= 0) THEN
        ErrStat = CD_MODEL_BADINPUT
        RETURN
      END IF
      f_dist = model%f_ext_dist_base + f_dist
      IF (.NOT. CD_All_Finite(f_dist)) THEN
        ErrStat = CD_MODEL_BADINPUT
        RETURN
      END IF
    END IF
    IF (moved .AND. model%has_seabed .AND. model%has_seabed_recompute) THEN
      CALL CD_Nodal_Seabed_Stiffness(model%seabed_kbot, model%seabed_diameter_elem, l0_k, kn_k, es, em)
      IF (es /= 0) THEN
        ErrStat = CD_MODEL_BADINPUT
        RETURN
      END IF
    END IF
    CALL sub_lengths_target(model)
    model%l0 = l0_k
    model%l0_dot = l0_dot_k
    IF (moved .AND. ALLOCATED(model%dist_load)) model%f_ext = f_dist
    IF (ALLOCATED(kn_k)) THEN
      CALL MOVE_ALLOC(kn_k, model%seabed_kn)
      IF (ALLOCATED(model%seabed_cn)) model%seabed_cn = model%seabed_kn*model%seabed_cn_over_kn
    END IF
  END SUBROUTINE sub_lengths_at

  SUBROUTINE sub_tensions(model, tension)
    !! The segment tensions at the model's committed state as the run audit takes them
    !! (CD_Audit_Model_Step): the dynamic EA times the strain of an elastic segment, the law's
    !! tension of a viscoelastic or Syrope segment (model_law_tensions; the static EA times the
    !! strain where the law cannot be evaluated).
    TYPE(CD_ModelType), INTENT(IN) :: model
    REAL(wp), INTENT(OUT) :: tension(:)
    INTEGER :: e, na, nb, es
    REAL(wp) :: strain
    CHARACTER(1024) :: em ! model_law_tensions: a law message with its prefix
    DO e = 1, model%n_elem
      na = model%elem_conn(1, e)
      nb = model%elem_conn(2, e)
      strain = NORM2(model%q(3*nb - 2:3*nb) - model%q(3*na - 2:3*na))/model%l0(e) - CD_ONE
      IF (model%ea_dyn(e) > CD_ZERO) THEN
        tension(e) = model%ea_dyn(e)*strain
      ELSE
        tension(e) = model%ea(e)*strain
      END IF
    END DO
    IF (model%has_viscoelastic .OR. model%has_syrope) CALL model_law_tensions(model, tension, es, em)
  END SUBROUTINE sub_tensions

  SUBROUTINE sub_tensions_scratch(model, which)
    !! sub_tensions into the scratch of the sub-stepping, sub_t0 (which = 0, the step start) or
    !! sub_t1 (1, the step end). The array is moved out of the model while the tensions are
    !! evaluated (the law evaluation reads the model), which allocates nothing.
    TYPE(CD_ModelType), INTENT(INOUT) :: model
    INTEGER, INTENT(IN) :: which
    REAL(wp), ALLOCATABLE :: tension(:)
    IF (which == 0) THEN
      CALL MOVE_ALLOC(model%sub_t0, tension)
      CALL sub_tensions(model, tension)
      CALL MOVE_ALLOC(tension, model%sub_t0)
    ELSE
      CALL MOVE_ALLOC(model%sub_t1, tension)
      CALL sub_tensions(model, tension)
      CALL MOVE_ALLOC(tension, model%sub_t1)
    END IF
  END SUBROUTINE sub_tensions_scratch

  REAL(wp) FUNCTION initial_tension(model) RESULT(t_init)
    !! The largest segment tension of the model's committed state (sub_tensions), 0 when none
    !! is positive: the line's initial tension when CD_Init_Model sets it.
    TYPE(CD_ModelType), INTENT(IN) :: model
    REAL(wp), ALLOCATABLE :: tension(:)
    INTEGER :: istat
    t_init = CD_ZERO
    ALLOCATE (tension(model%n_elem), STAT=istat)
    IF (istat /= 0) RETURN
    CALL sub_tensions(model, tension)
    IF (CD_All_Finite(tension)) t_init = MAX(CD_ZERO, MAXVAL(tension))
  END FUNCTION initial_tension

  REAL(wp) FUNCTION segment_wave_stiffness(model, e, tension) RESULT(stiff)
    !! The axial stiffness of segment e that sets its wave speed: the dynamic EA of an elastic
    !! segment, the fast spring of a law (EA_D of the viscoelastic law, alpha + beta*T of the
    !! Syrope law at the segment tension T); the static EA if the law's value is unavailable.
    TYPE(CD_ModelType), INTENT(IN) :: model
    INTEGER, INTENT(IN) :: e
    REAL(wp), INTENT(IN) :: tension
    REAL(wp) :: ea_d_eff, ea_1_eff
    INTEGER :: es
    CHARACTER(KERNEL_MSG_LEN) :: em ! a per-element law message (the kernels' bound)
    stiff = model%ea_dyn(e)
    IF (stiff > CD_ZERO) RETURN
    stiff = model%ea(e)
    IF (model%has_viscoelastic) THEN
      IF (model%ve_mode(e) /= 0) THEN
        CALL model_viscoelastic_coeffs(model, e, ea_d_eff, ea_1_eff, es, em)
        IF (es == CD_MODEL_OK .AND. ea_d_eff > CD_ZERO) stiff = ea_d_eff
        RETURN
      END IF
    END IF
    IF (model%has_syrope) THEN
      IF (model%syrope_is(e)) &
        stiff = model%syrope_type(e)%alpha + model%syrope_type(e)%beta*MAX(tension, CD_ZERO)
    END IF
  END FUNCTION segment_wave_stiffness

  SUBROUTINE sub_count(model, dt, nsub, capped)
    !! The sub-step count of a converged step over dt (model%q) from the committed state (slot 1,
    !! its segment tensions in sub_t0): 1, or max(SUB_SNAP_STEPS, ceil(turn/angle)) when
    !! turn > angle, at most cfg%ei0_substep_max (capped when the turn needs more), turn the
    !! largest chord turn of a segment that ends the step above SUB_TAUT_FRACTION of the tension
    !! scale (the largest step-start tension, at least SUB_TAUT_FRACTION of sub_t_init); at least
    !! SUB_SNAP_STEPS when a segment slack at the start ends above SUB_SNAP_FRACTION of the scale
    !! and its axial wave crosses it more than once in dt. The tensions are those of
    !! sub_tensions. The end state takes the present lengths model%l0, the start state the
    !! lengths it was reached with (slot 1's l0_c; the same bits unless a length change is
    !! pending, see CD_Step_Model).
    TYPE(CD_ModelType), INTENT(INOUT) :: model
    REAL(wp), INTENT(IN) :: dt
    INTEGER, INTENT(OUT) :: nsub
    LOGICAL, INTENT(OUT) :: capped
    REAL(wp), PARAMETER :: DEG = 57.295779513082320876798154814105_wp
    INTEGER :: e, na, nb, nmax
    REAL(wp) :: d0(3), d1(3), l_s, l_e, scale, te, c, turn, ratio, courant
    LOGICAL :: snap
    nsub = 1
    capped = .FALSE.
    CALL sub_tensions_scratch(model, 1)
    scale = MAX(CD_ZERO, SUB_TAUT_FRACTION*model%sub_t_init)
    IF (CD_All_Finite(model%sub_t0)) scale = MAX(scale, MAXVAL(model%sub_t0))
    turn = CD_ZERO
    snap = .FALSE.
    DO e = 1, model%n_elem
      na = model%elem_conn(1, e)
      nb = model%elem_conn(2, e)
      d1 = model%q(3*nb - 2:3*nb) - model%q(3*na - 2:3*na)
      l_e = NORM2(d1)
      IF (.NOT. l_e > model%l0(e)) CYCLE
      te = model%sub_t1(e)
      d0 = model%sub_slot(1)%q(3*nb - 2:3*nb) - model%sub_slot(1)%q(3*na - 2:3*na)
      l_s = NORM2(d0)
      IF (.NOT. snap .AND. l_s <= model%sub_slot(1)%l0_c(e) .AND. te > SUB_SNAP_FRACTION*scale) THEN
        courant = dt*SQRT(segment_wave_stiffness(model, e, te)/model%rho_a(e))/model%l0(e)
        IF (courant > CD_ONE) snap = .TRUE.
      END IF
      IF (te > SUB_TAUT_FRACTION*scale .AND. l_s > CD_ZERO) THEN
        c = DOT_PRODUCT(d0, d1)/(l_s*l_e)
        turn = MAX(turn, ACOS(MAX(-CD_ONE, MIN(CD_ONE, c)))*DEG)
      END IF
    END DO
    nmax = model%cfg%ei0_substep_max
    IF (turn > model%cfg%ei0_substep_angle) THEN
      ratio = turn/model%cfg%ei0_substep_angle
      IF (ratio > REAL(nmax, wp)) THEN
        nsub = nmax
        capped = .TRUE.
      ELSE
        nsub = MIN(nmax, MAX(SUB_SNAP_STEPS, CEILING(ratio)))
      END IF
    END IF
    IF (snap) nsub = MAX(nsub, MIN(SUB_SNAP_STEPS, nmax))
  END SUBROUTINE sub_count

  SUBROUTINE CD_Get_Model_Substep_Counts(model, calls, events, max_used, capped, fallbacks)
    !! Diagnostics of the rotation- and snap-resolved sub-stepping (CD_Step_Model,
    !! CD_SubstepStats): the steps it examined, those it solved in sub-steps (the largest count
    !! used), those whose turn needed more than cfg%ei0_substep_max, and those that kept the
    !! plain step after a sub-step failed.
    TYPE(CD_ModelType), INTENT(IN) :: model
    INTEGER(int64), INTENT(OUT) :: calls, events, capped, fallbacks
    INTEGER, INTENT(OUT) :: max_used
    calls = model%sub_stats%calls
    events = model%sub_stats%events
    max_used = model%sub_stats%max_used
    capped = model%sub_stats%capped
    fallbacks = model%sub_stats%fallbacks
  END SUBROUTINE CD_Get_Model_Substep_Counts

  SUBROUTINE step_model_plain(model, dt, converged, stalled, n_iter, ErrStat, ErrMsg, &
                              prescribed_q, prescribed_v, prescribed_a)
    !! One generalized-alpha step of the model over dt, as given (CD_Step_Model without its
    !! resolved sub-stepping).
    TYPE(CD_ModelType), INTENT(INOUT), TARGET :: model
    REAL(wp), INTENT(IN) :: dt
    LOGICAL, INTENT(OUT) :: converged, stalled
    INTEGER, INTENT(OUT) :: n_iter, ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    REAL(wp), INTENT(IN), OPTIONAL :: prescribed_q(:), prescribed_v(:), prescribed_a(:)

    INTEGER :: es, e
    CHARACTER(1024) :: em
    LOGICAL :: has_load, blend, force_lengths
    REAL(wp) :: af
    REAL(wp), ALLOCATABLE :: l0_new(:), l0_dot_new(:), l0_start(:), f_ext_new(:), f_ext_c(:)
    REAL(wp), ALLOCATABLE, TARGET :: l0_mass(:)
    REAL(wp), ALLOCATABLE :: l0_dot_start(:)
    TYPE(model_lengths_aside) :: aside
    TYPE(model_step_loads) :: step_loads

    converged = .FALSE.
    stalled = .FALSE.
    n_iter = 0
    ErrStat = CD_MODEL_OK
    ErrMsg = ''
    ! Only a warm re-solve of the step whose committed-state load load_start_work holds may
    ! reuse it: any other call drops it before its first return (see the step workspace's
    ! start_valid), so an unarmed call that fails early leaves no older step's load behind.
    IF (.NOT. model%dynamic_workspace%guess_armed) model%load_start_valid = .FALSE.
    IF (.NOT. model%initialized) THEN
      ErrStat = CD_MODEL_NOT_INITIALIZED
      ErrMsg = 'CableDyn_Model: model is not initialized'
      RETURN
    END IF
    IF (PRESENT(prescribed_q) .OR. PRESENT(prescribed_v) .OR. PRESENT(prescribed_a)) THEN
      IF (.NOT. (PRESENT(prescribed_q) .AND. PRESENT(prescribed_v) .AND. PRESENT(prescribed_a))) THEN
        CALL fail(ErrStat, ErrMsg, 'prescribed motion needs all of prescribed_q, prescribed_v, prescribed_a')
        RETURN
      END IF
      IF (SIZE(prescribed_q) /= model%n_dof .OR. SIZE(prescribed_v) /= model%n_dof &
          .OR. SIZE(prescribed_a) /= model%n_dof) THEN
        CALL fail(ErrStat, ErrMsg, 'prescribed_q/v/a must each have shape (3 n_nodes)')
        RETURN
      END IF
    END IF

    has_load = model%has_seabed .OR. model%has_seabed_damping .OR. model%has_seabed_friction .OR. &
               model%has_damping .OR. model%has_viscoelastic .OR. model%has_syrope .OR. model%has_morison_drag .OR. &
               model%has_froude_krylov .OR. model%has_buoyancy_recovery .OR. model%has_viv
    ! Force-blended generalised alpha: the load contributors at the committed state (q_n, v_n)
    ! carry the alpha_f share of the residual. They are evaluated here, in the instantaneous
    ! limit (ve_dt = 0), so the viscoelastic and Syrope elements give their committed force,
    ! whose tension (tension_start_work) the release cap of the step bounds like the elastic
    ! tension. A warm re-solve of the same step (the junction coupling re-steps the line from
    ! the same committed state with moved ends) reuses the load of the previous call.
    !
    ! Active line control: after a length or rate change the committed state keeps the lengths
    ! and rates it was reached with (l0_c, l0_dot_c), and the step that follows treats them as
    ! the generalised-alpha form requires. With the force blend, r(q_{n+1}, v_{n+1}) takes the
    ! present lengths, rates, external load and seabed coefficients, and r(q_n, v_n) those of
    ! the committed state: its load (here) and its internal force and release-cap data (the
    ! step's start_l0) are evaluated at l0_c and l0_dot_c, with the distributed load and the
    ! recomputed seabed coefficients rebuilt at l0_c (enter_committed_lengths), and the
    ! constant external load of the step blends the two, (1 - alpha_f) f_ext + alpha_f f_ext_c.
    ! The inertia, which the force blend keeps at the alpha level (M a_alpha, the added mass
    ! at q_alpha), takes the blended lengths (1 - alpha_f) l0 + alpha_f l0_c. Under
    ! False alpha_force_blend every alpha-level term (internal force, damping, hydrodynamic
    ! loads, the structural and added mass) takes the blended lengths and rates, with the
    ! present external load and seabed coefficients. Either way the lengths are blended element
    ! by element and only where they differ, the new lengths come back with the state at
    ! t_{n+1}, and an unchanged model takes the plain path.
    blend = .NOT. model_lengths_committed(model)
    force_lengths = blend .AND. model%cfg%force_blend
    af = model%cfg%rho_inf/(model%cfg%rho_inf + CD_ONE)
    IF (force_lengths) THEN
      CALL enter_committed_lengths(model, aside, .TRUE., es, em)
      IF (es /= CD_MODEL_OK) THEN
        ErrStat = es
        ErrMsg = 'CableDyn_Model: step-start lengths: '//TRIM(em)
        RETURN
      END IF
      IF (ALLOCATED(aside%f_ext)) f_ext_c = model%f_ext
    END IF
    CALL step_start_load(ErrStat, ErrMsg)
    IF (force_lengths) CALL leave_committed_lengths(model, aside)
    IF (ErrStat /= CD_MODEL_OK) RETURN
    ! VIV: phase rate and mean squares at the step-start state (after the committed-state
    ! load above, which takes the committed phase), and the explicit phase for the in-step
    ! lift (see viv_step_begin). Nothing is
    ! committed until the step succeeds; viv_phi_eval returns to the committed phase on
    ! every exit, as ve_dt below.
    IF (model%has_viv) THEN
      IF (.NOT. (CD_Is_Finite(dt) .AND. dt > CD_ZERO)) THEN
        CALL fail(ErrStat, ErrMsg, 'dt must be finite and positive')
        RETURN
      END IF
      CALL viv_step_begin(model, dt, ErrStat, ErrMsg)
      IF (ErrStat /= CD_MODEL_OK) THEN
        model%viv_phi_eval = model%viv_phi
        RETURN
      END IF
    END IF
    ! arm the viscoelastic contributors with the step size: in-step load
    ! evaluations use the backward-Euler-eliminated dl_1(q, v); it is reset to
    ! the instantaneous limit (0) on EVERY exit below so committed-state queries
    ! (coupled loads, tension) never see a stale step size
    model%ve_dt = dt
    IF (force_lengths) THEN
      ! the release cap's step-start dashpot takes the committed rates (start_l0_rate)
      l0_dot_start = model%l0_dot_c
      IF (.NOT. ALL(bits_equal(model%l0, model%l0_c))) THEN
        l0_start = model%l0_c
        l0_mass = model%l0
        DO e = 1, model%n_elem
          IF (.NOT. bits_equal(model%l0(e), model%l0_c(e))) &
            l0_mass(e) = (CD_ONE - af)*model%l0(e) + af*model%l0_c(e)
        END DO
      END IF
      IF (ALLOCATED(f_ext_c)) THEN
        f_ext_new = model%f_ext
        DO e = 1, model%n_dof
          IF (.NOT. bits_equal(f_ext_new(e), f_ext_c(e))) &
            model%f_ext(e) = (CD_ONE - af)*f_ext_new(e) + af*f_ext_c(e)
        END DO
      END IF
    ELSE IF (blend) THEN
      l0_new = model%l0
      l0_dot_new = model%l0_dot
      DO e = 1, model%n_elem
        IF (.NOT. bits_equal(l0_new(e), model%l0_c(e))) &
          model%l0(e) = (CD_ONE - af)*l0_new(e) + af*model%l0_c(e)
        IF (.NOT. bits_equal(l0_dot_new(e), model%l0_dot_c(e))) &
          model%l0_dot(e) = (CD_ONE - af)*l0_dot_new(e) + af*model%l0_dot_c(e)
      END DO
    END IF
    step_loads%model => model
    step_loads%has_force = has_load
    step_loads%has_added_mass = model%has_added_mass
    IF (ALLOCATED(l0_mass)) step_loads%l0_mass => l0_mass
    IF (PRESENT(prescribed_q) .AND. has_load .AND. model%has_added_mass) THEN
      CALL CD_Cable_Gen_Alpha_Step(model%q, model%v, model%a, model%elem_conn, model%l0, model%ea_dyn, &
                                   model%rho_a, model%tension_only, model%f_ext, model%fixed_dofs, &
                                   dt, model%cfg, model%q_step, model%v_step, model%a_step, converged, stalled, &
                                   n_iter, &
                                   es, em, loads=step_loads, prescribed_q=prescribed_q, &
                                   prescribed_v=prescribed_v, prescribed_a=prescribed_a, &
                                   workspace=model%dynamic_workspace, start_load=model%load_start_work, &
                                   start_tension=model%tension_start_work, &
                                   start_stiffness=model%stiffness_start_work, &
                                   axial_damping=model%ba_dyn, axial_l0_rate=model%l0_dot, &
                                   start_l0=l0_start, mass_l0=l0_mass, start_l0_rate=l0_dot_start)
    ELSE IF (PRESENT(prescribed_q) .AND. has_load) THEN
      CALL CD_Cable_Gen_Alpha_Step(model%q, model%v, model%a, model%elem_conn, model%l0, model%ea_dyn, &
                                   model%rho_a, model%tension_only, model%f_ext, model%fixed_dofs, &
                                   dt, model%cfg, model%q_step, model%v_step, model%a_step, converged, stalled, &
                                   n_iter, &
                                   es, em, loads=step_loads, &
                                   prescribed_q=prescribed_q, prescribed_v=prescribed_v, &
                                   prescribed_a=prescribed_a, workspace=model%dynamic_workspace, &
                                   start_load=model%load_start_work, start_tension=model%tension_start_work, &
                                   start_stiffness=model%stiffness_start_work, &
                                   axial_damping=model%ba_dyn, axial_l0_rate=model%l0_dot, &
                                   start_l0=l0_start, mass_l0=l0_mass, start_l0_rate=l0_dot_start)
    ELSE IF (PRESENT(prescribed_q) .AND. model%has_added_mass) THEN
      CALL CD_Cable_Gen_Alpha_Step(model%q, model%v, model%a, model%elem_conn, model%l0, model%ea_dyn, &
                                   model%rho_a, model%tension_only, model%f_ext, model%fixed_dofs, &
                                   dt, model%cfg, model%q_step, model%v_step, model%a_step, converged, stalled, &
                                   n_iter, &
                                   es, em, loads=step_loads, prescribed_q=prescribed_q, &
                                   prescribed_v=prescribed_v, prescribed_a=prescribed_a, &
                                   workspace=model%dynamic_workspace, &
                                   start_l0=l0_start, mass_l0=l0_mass)
    ELSE IF (PRESENT(prescribed_q)) THEN
      CALL CD_Cable_Gen_Alpha_Step(model%q, model%v, model%a, model%elem_conn, model%l0, model%ea_dyn, &
                                   model%rho_a, model%tension_only, model%f_ext, model%fixed_dofs, &
                                   dt, model%cfg, model%q_step, model%v_step, model%a_step, converged, stalled, &
                                   n_iter, &
                                   es, em, prescribed_q=prescribed_q, prescribed_v=prescribed_v, &
                                   prescribed_a=prescribed_a, workspace=model%dynamic_workspace, &
                                   start_l0=l0_start, mass_l0=l0_mass)
    ELSE IF (has_load .AND. model%has_added_mass) THEN
      CALL CD_Cable_Gen_Alpha_Step(model%q, model%v, model%a, model%elem_conn, model%l0, model%ea_dyn, &
                                   model%rho_a, model%tension_only, model%f_ext, model%fixed_dofs, &
                                   dt, model%cfg, model%q_step, model%v_step, model%a_step, converged, stalled, &
                                   n_iter, es, em, &
                                   loads=step_loads, workspace=model%dynamic_workspace, &
                                   start_load=model%load_start_work, start_tension=model%tension_start_work, &
                                   start_stiffness=model%stiffness_start_work, &
                                   axial_damping=model%ba_dyn, axial_l0_rate=model%l0_dot, &
                                   start_l0=l0_start, mass_l0=l0_mass, start_l0_rate=l0_dot_start)
    ELSE IF (has_load) THEN
      CALL CD_Cable_Gen_Alpha_Step(model%q, model%v, model%a, model%elem_conn, model%l0, model%ea_dyn, &
                                   model%rho_a, model%tension_only, model%f_ext, model%fixed_dofs, &
                                   dt, model%cfg, model%q_step, model%v_step, model%a_step, converged, stalled, &
                                   n_iter, es, em, &
                                   loads=step_loads, &
                                   workspace=model%dynamic_workspace, start_load=model%load_start_work, &
                                   start_tension=model%tension_start_work, &
                                   start_stiffness=model%stiffness_start_work, &
                                   axial_damping=model%ba_dyn, axial_l0_rate=model%l0_dot, &
                                   start_l0=l0_start, mass_l0=l0_mass, start_l0_rate=l0_dot_start)
    ELSE IF (model%has_added_mass) THEN
      CALL CD_Cable_Gen_Alpha_Step(model%q, model%v, model%a, model%elem_conn, model%l0, model%ea_dyn, &
                                   model%rho_a, model%tension_only, model%f_ext, model%fixed_dofs, &
                                   dt, model%cfg, model%q_step, model%v_step, model%a_step, converged, stalled, &
                                   n_iter, es, em, &
                                   loads=step_loads, workspace=model%dynamic_workspace, &
                                   start_l0=l0_start, mass_l0=l0_mass)
    ELSE
      CALL CD_Cable_Gen_Alpha_Step(model%q, model%v, model%a, model%elem_conn, model%l0, model%ea_dyn, &
                                   model%rho_a, model%tension_only, model%f_ext, model%fixed_dofs, &
                                   dt, model%cfg, model%q_step, model%v_step, model%a_step, converged, stalled, &
                                   n_iter, es, em, workspace=model%dynamic_workspace, &
                                   start_l0=l0_start, mass_l0=l0_mass)
    END IF
    IF (ALLOCATED(l0_new)) model%l0 = l0_new
    IF (ALLOCATED(l0_dot_new)) model%l0_dot = l0_dot_new
    IF (ALLOCATED(f_ext_new)) model%f_ext = f_ext_new
    model%ve_dt = CD_ZERO
    IF (model%has_viv) model%viv_phi_eval = model%viv_phi
    CALL CD_Profile_Count_Line_Step(n_iter)
    IF (es /= CD_DYN_OK) THEN
      ErrStat = model_status_from_dyn(es)
      ErrMsg = 'CableDyn_Model: step failed: '//TRIM(em)
      converged = .FALSE.
      RETURN
    END IF
    ! ==== stateful constitutive commit: validate EVERY model (viscoelastic AND
    ! Syrope) BEFORE mutating ANY internal state, so a failure in one model cannot
    ! leave another model's state advanced past a step that never commits q/v/a.
    ! Each pass-1 is exhaustive enough that its pass-2 cannot fail mid-mutation, so
    ! the four passes together are one atomic commit. Each element reads/writes only
    ! its own state, and viscoelastic vs Syrope elements are disjoint segments, so
    ! the pass ordering does not change any success-path result (bit-identical). ====
    IF (model%has_viscoelastic) THEN
      ! Pass 1 (validate): every viscoelastic element length + lagged coefficients
      ! (deterministic from the COMMITTED dl_1), the only failure modes of the advance.
      BLOCK
        INTEGER :: e2, na, nb, es2
        REAL(wp) :: ea_d_eff, ea_1_eff
        CHARACTER(200) :: em2
        DO e2 = 1, model%n_elem
          IF (model%ve_mode(e2) == 0) CYCLE
          na = model%elem_conn(1, e2)
          nb = model%elem_conn(2, e2)
          IF (NORM2(model%q_step(3*nb - 2:3*nb) - model%q_step(3*na - 2:3*na)) <= &
              CD_VISCO_TINY_LEN) THEN
            CALL fail(ErrStat, ErrMsg, 'viscoelastic state advance found a collapsed element in the '// &
                      'converged step state')
            converged = .FALSE.
            RETURN
          END IF
          CALL model_viscoelastic_coeffs(model, e2, ea_d_eff, ea_1_eff, es2, em2)
          IF (es2 /= CD_MODEL_OK) THEN
            ErrStat = es2
            ErrMsg = em2
            converged = .FALSE.
            RETURN
          END IF
        END DO
      END BLOCK
    END IF
    IF (model%has_syrope) THEN
      ! Pass 1 (validate): every Syrope element (collapsed length, working-curve
      ! regeneration at the current AND any ratcheted maximum).
      BLOCK
        INTEGER :: e2, idx_scr(6)
        REAL(wp) :: q2b(6), v2b(6), slow_next, tmean
        DO e2 = 1, model%n_elem
          IF (.NOT. model%syrope_is(e2)) CYCLE
          CALL extract_element_state(model, e2, model%q_step, model%v_step, idx_scr, q2b, v2b)
          CALL model_syrope_state_next(model, e2, q2b, v2b, dt, slow_next, tmean, ErrStat, ErrMsg)
          IF (ErrStat /= CD_MODEL_OK) THEN
            converged = .FALSE.
            RETURN
          END IF
        END DO
      END BLOCK
    END IF
    ! Friction anchors of the converged state, mapped before the state is committed so a
    ! failure leaves the step-start state (and its anchors) intact; the passes below are
    ! validated and cannot fail.
    IF (model%has_seabed_friction) THEN
      CALL mapped_friction_anchors(model, model%q_step, model%v_step, .FALSE., ErrStat, ErrMsg)
      IF (ErrStat /= CD_MODEL_OK) THEN
        converged = .FALSE.
        RETURN
      END IF
    END IF
    ! VIV pass 1: the end-of-step phase (Heun) into viv_phi_next; committed below.
    IF (model%has_viv) THEN
      CALL viv_step_end(model, dt, ErrStat, ErrMsg)
      IF (ErrStat /= CD_MODEL_OK) THEN
        converged = .FALSE.
        RETURN
      END IF
    END IF
    IF (model%has_viscoelastic) THEN
      ! Pass 2 (mutate): commit dl_1 from the SAME lagged coefficients the in-step
      ! loads used (mode 3 reads the still-committed dl_1). Validated above, so no
      ! failure can occur here mid-mutation.
      BLOCK
        INTEGER :: e2, na, nb, es2
        REAL(wp) :: dl1_next, ea_d_eff, ea_1_eff
        CHARACTER(200) :: em2
        DO e2 = 1, model%n_elem
          IF (model%ve_mode(e2) == 0) CYCLE
          CALL model_viscoelastic_coeffs(model, e2, ea_d_eff, ea_1_eff, es2, em2)
          IF (es2 /= CD_MODEL_OK) THEN
            ErrStat = es2
            ErrMsg = em2
            converged = .FALSE.
            RETURN
          END IF
          na = model%elem_conn(1, e2)
          nb = model%elem_conn(2, e2)
          CALL CD_Viscoelastic_State_Advance(model%q_step(3*na - 2:3*na), model%q_step(3*nb - 2:3*nb), &
                                             model%v_step(3*na - 2:3*na), model%v_step(3*nb - 2:3*nb), &
                                             model%l0(e2), ea_d_eff, ea_1_eff, &
                                             model%ve_ba(e2), model%ve_ba_d(e2), model%ve_dl_1(e2), dt, &
                                             dl1_next, es2, em2)
          IF (es2 /= CD_VISCO_OK) THEN
            CALL fail(ErrStat, ErrMsg, TRIM(em2))
            converged = .FALSE.
            RETURN
          END IF
          model%ve_dl_1(e2) = dl1_next
        END DO
      END BLOCK
    END IF
    IF (model%has_syrope) THEN
      ! Pass 2 (mutate): advance the committed slow strain and ratchet the running
      ! maximum. The element re-eval reads the still-committed slow/tmax (mutated
      ! only after), and each element writes only its own state. Validated above.
      BLOCK
        INTEGER :: e2, idx_scr(6)
        REAL(wp) :: q2b(6), v2b(6), tmean, slow_next
        DO e2 = 1, model%n_elem
          IF (.NOT. model%syrope_is(e2)) CYCLE
          CALL extract_element_state(model, e2, model%q_step, model%v_step, idx_scr, q2b, v2b)
          CALL model_syrope_state_next(model, e2, q2b, v2b, dt, slow_next, tmean, ErrStat, ErrMsg)
          IF (ErrStat /= CD_MODEL_OK) THEN
            converged = .FALSE.
            RETURN
          END IF
          model%syrope_slow(e2) = slow_next
          IF (tmean > model%syrope_tmax(e2)) model%syrope_tmax(e2) = tmean
        END DO
      END BLOCK
    END IF
    IF (model%has_viv) THEN
      ! VIV pass 2 (mutate): the phase and the mean squares updated with the step-start
      ! sample (the next step starts by adding its own sample, the end state of this one)
      model%viv_phi = model%viv_phi_next
      model%viv_ms = model%viv_ms_next
      model%viv_phi_eval = model%viv_phi
    END IF
    model%q = model%q_step
    model%v = model%v_step
    model%a = model%a_step
    ! the committed state is now the one of the present lengths and rates
    IF (blend) THEN
      model%l0_c = model%l0
      model%l0_dot_c = model%l0_dot
    END IF
    ! The mapping repeats the queries validated above, so it cannot fail here.
    IF (model%has_seabed_friction) &
      CALL mapped_friction_anchors(model, model%q, model%v, .TRUE., ErrStat, ErrMsg)

  CONTAINS

    SUBROUTINE step_start_load(es_s, em_s)
      !! The force blend's load at the committed state (q_n, v_n) into load_start_work (with the
      !! law tensions and axial stiffnesses of the viscoelastic and Syrope elements in
      !! tension_start_work and stiffness_start_work), unless a
      !! warm re-solve of the same step reuses the previous call's; without the force blend or a
      !! load contributor there is none. Evaluated with the model as the caller left it (the
      !! committed lengths entered after a length change).
      INTEGER, INTENT(OUT) :: es_s
      CHARACTER(*), INTENT(OUT) :: em_s
      CHARACTER(1024) :: em_c
      es_s = CD_MODEL_OK
      em_s = ''
      IF (.NOT. (has_load .AND. model%cfg%force_blend)) THEN
        model%load_start_valid = .FALSE.
        RETURN
      END IF
      IF (model%dynamic_workspace%guess_armed .AND. model%load_start_valid) RETURN
      model%load_start_valid = .FALSE.
      IF (ALLOCATED(model%load_start_work)) THEN
        IF (SIZE(model%load_start_work) /= model%n_dof) DEALLOCATE (model%load_start_work)
      END IF
      IF (.NOT. ALLOCATED(model%load_start_work)) THEN
        ALLOCATE (model%load_start_work(model%n_dof), STAT=es_s)
        IF (es_s /= 0) THEN
          es_s = CD_MODEL_ALLOCFAIL
          em_s = 'CableDyn_Model: step-start load workspace allocation failed'
          RETURN
        END IF
      END IF
      ! tension_start_work stays unallocated without a viscoelastic or Syrope element, and the
      ! step then sees start_tension absent
      IF (ALLOCATED(model%tension_start_work)) THEN
        IF (SIZE(model%tension_start_work) /= model%n_elem .OR. &
            .NOT. (model%has_viscoelastic .OR. model%has_syrope)) DEALLOCATE (model%tension_start_work)
      END IF
      IF ((model%has_viscoelastic .OR. model%has_syrope) .AND. .NOT. ALLOCATED(model%tension_start_work)) THEN
        ALLOCATE (model%tension_start_work(model%n_elem), STAT=es_s)
        IF (es_s /= 0) THEN
          es_s = CD_MODEL_ALLOCFAIL
          em_s = 'CableDyn_Model: step-start tension workspace allocation failed'
          RETURN
        END IF
      END IF
      IF (ALLOCATED(model%stiffness_start_work)) THEN
        IF (.NOT. ALLOCATED(model%tension_start_work)) THEN
          DEALLOCATE (model%stiffness_start_work)
        ELSE IF (SIZE(model%stiffness_start_work) /= model%n_elem) THEN
          DEALLOCATE (model%stiffness_start_work)
        END IF
      END IF
      IF (ALLOCATED(model%tension_start_work) .AND. .NOT. ALLOCATED(model%stiffness_start_work)) THEN
        ALLOCATE (model%stiffness_start_work(model%n_elem), STAT=es_s)
        IF (es_s /= 0) THEN
          es_s = CD_MODEL_ALLOCFAIL
          em_s = 'CableDyn_Model: step-start stiffness workspace allocation failed'
          RETURN
        END IF
      END IF
      model%ve_dt = CD_ZERO
      IF (ALLOCATED(model%tension_start_work)) THEN
        CALL model_contributor_force(model, model%q, model%v, model%load_start_work, es_s, em_c, &
                                     law_tension=model%tension_start_work, &
                                     law_stiffness=model%stiffness_start_work)
      ELSE
        CALL model_contributor_force(model, model%q, model%v, model%load_start_work, es_s, em_c)
      END IF
      IF (es_s /= CD_MODEL_OK) THEN
        em_s = 'CableDyn_Model: step-start load failed: '//TRIM(em_c)
        RETURN
      END IF
      model%load_start_valid = .TRUE.
    END SUBROUTINE step_start_load
  END SUBROUTINE step_model_plain

  SUBROUTINE CD_Step_Model_Recovering(model, dt, converged, stalled, n_iter, ErrStat, ErrMsg, &
                                      prescribed_q, prescribed_v, prescribed_a, max_substeps, substeps_used)
    !! Advance one EI=0 model over a nominal interval, recovering a clean
    !! nonlinear stall by internal temporal subdivision.  The nominal interval
    !! and its prescribed endpoint kinematics remain unchanged.  A C2 quintic
    !! joins the committed and target boundary position, velocity and
    !! acceleration, so the subdivision follows one kinematically consistent
    !! trajectory rather than a sequence of independently interpolated fields.
    !!
    !! Every recovery rung starts from the same complete committed state,
    !! including viscoelastic and Syrope history variables.  If no rung
    !! completes, that state is restored and the routine fails closed.
    TYPE(CD_ModelType), INTENT(INOUT) :: model
    REAL(wp), INTENT(IN) :: dt
    LOGICAL, INTENT(OUT) :: converged, stalled
    INTEGER, INTENT(OUT) :: n_iter, ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    REAL(wp), INTENT(IN), OPTIONAL :: prescribed_q(:), prescribed_v(:), prescribed_a(:)
    INTEGER, INTENT(IN), OPTIONAL :: max_substeps
    INTEGER, INTENT(OUT), OPTIONAL :: substeps_used

    INTEGER :: recovery_cap, nsub, k, es, iter_sub, max_iter_seen
    LOGICAL :: has_pres, conv_sub, stall_sub, rung_ok
    REAL(wp) :: subdt, fraction, hmax0
    TYPE(CD_SubstepStats) :: stats0
    REAL(wp), ALLOCATABLE :: pq(:), pv(:), pa(:)
    CHARACTER(1024) :: em, first_em

    converged = .FALSE.
    stalled = .FALSE.
    n_iter = 0
    IF (PRESENT(substeps_used)) substeps_used = 0
    ErrStat = CD_MODEL_OK
    ErrMsg = ''
    IF (.NOT. model%initialized) THEN
      ErrStat = CD_MODEL_NOT_INITIALIZED
      ErrMsg = 'CableDyn_Model: recovery step requires an initialized model'
      RETURN
    END IF
    has_pres = PRESENT(prescribed_q) .AND. PRESENT(prescribed_v) .AND. PRESENT(prescribed_a)
    IF ((PRESENT(prescribed_q) .OR. PRESENT(prescribed_v) .OR. PRESENT(prescribed_a)) .AND. .NOT. has_pres) THEN
      CALL fail(ErrStat, ErrMsg, 'recovery step needs all of prescribed_q, prescribed_v and prescribed_a')
      RETURN
    END IF
    IF (has_pres) THEN
      IF (SIZE(prescribed_q) /= model%n_dof .OR. SIZE(prescribed_v) /= model%n_dof .OR. &
          SIZE(prescribed_a) /= model%n_dof) THEN
        CALL fail(ErrStat, ErrMsg, 'recovery prescribed_q/v/a must each have shape (3 n_nodes)')
        RETURN
      END IF
      IF (.NOT. (CD_All_Finite(prescribed_q) .AND. CD_All_Finite(prescribed_v) .AND. &
                 CD_All_Finite(prescribed_a))) THEN
        CALL fail(ErrStat, ErrMsg, 'recovery prescribed_q/v/a must be finite')
        RETURN
      END IF
    END IF
    recovery_cap = MODEL_DEFAULT_MAX_SUBSTEPS
    IF (PRESENT(max_substeps)) recovery_cap = max_substeps
    IF (recovery_cap < 4 .OR. recovery_cap > 65536) THEN
      CALL fail(ErrStat, ErrMsg, 'recovery max_substeps must be in [4,65536]')
      RETURN
    END IF
    IF (.NOT. (ALLOCATED(model%recovery_q0) .AND. ALLOCATED(model%recovery_v0) .AND. &
               ALLOCATED(model%recovery_a0))) THEN
      CALL fail(ErrStat, ErrMsg, 'recovery snapshot workspace is not initialized')
      RETURN
    END IF

    ! MoorDyn's VIV averaging window counts NOMINAL steps: latch it before any subdivision
    IF (model%has_viv) CALL CD_Latch_Model_VIV_Window(model, dt)
    CALL save_recovery_state(model)
    hmax0 = model%audit_hmax
    stats0 = model%sub_stats
    IF (has_pres) THEN
      CALL CD_Step_Model(model, dt, converged, stalled, n_iter, ErrStat, ErrMsg, &
                         prescribed_q=prescribed_q, prescribed_v=prescribed_v, prescribed_a=prescribed_a)
    ELSE
      CALL CD_Step_Model(model, dt, converged, stalled, n_iter, ErrStat, ErrMsg)
    END IF
    max_iter_seen = n_iter
    IF (ErrStat /= CD_MODEL_OK) THEN
      CALL restore_recovery_state(model)
      RETURN
    END IF
    IF (converged) THEN
      IF (PRESENT(substeps_used)) substeps_used = 1
      RETURN
    END IF

    first_em = ErrMsg
    CALL restore_recovery_state(model)
    ! the stalled attempt is not committed: the rungs that replace it take their steps as given
    model%sub_stats = stats0
    IF (has_pres) THEN
      ALLOCATE (pq(model%n_dof), pv(model%n_dof), pa(model%n_dof), STAT=es)
      IF (es /= 0) THEN
        ! The committed state was restored above; fail closed without a retry.
        converged = .FALSE.
        stalled = .TRUE.
        ErrStat = CD_MODEL_ALLOCFAIL
        ErrMsg = 'CableDyn_Model: recovery boundary workspace allocation failed'
        RETURN
      END IF
    END IF
    nsub = 4
    DO
      CALL restore_recovery_state(model)
      ! the audit measures the solver steps of the rung that completes
      model%audit_hmax = hmax0
      ! the rungs take their sub-steps as given (step_model_plain, as CD_Step_System's halving
      ! does with as_given): resolving them as well (sub-steps of sub-steps) left the anchor snap
      ! peaks of the Lozon semitaut line 9 % high on average
      subdt = dt/REAL(nsub, wp)
      rung_ok = .TRUE.
      es = CD_MODEL_OK
      em = ''
      DO k = 1, nsub
        IF (has_pres) THEN
          fraction = REAL(k, wp)/REAL(nsub, wp)
          CALL quintic_model_boundary_state(model%recovery_q0, model%recovery_v0, model%recovery_a0, &
                                            prescribed_q, prescribed_v, prescribed_a, dt, fraction, pq, pv, pa)
          IF (k == nsub) THEN
            pq = prescribed_q
            pv = prescribed_v
            pa = prescribed_a
          END IF
          CALL step_model_plain(model, subdt, conv_sub, stall_sub, iter_sub, es, em, &
                                prescribed_q=pq, prescribed_v=pv, prescribed_a=pa)
        ELSE
          CALL step_model_plain(model, subdt, conv_sub, stall_sub, iter_sub, es, em)
        END IF
        max_iter_seen = MAX(max_iter_seen, iter_sub)
        IF (es /= CD_MODEL_OK .OR. .NOT. conv_sub) THEN
          rung_ok = .FALSE.
          EXIT
        END IF
      END DO
      IF (rung_ok) THEN
        converged = .TRUE.
        stalled = .FALSE.
        n_iter = max_iter_seen
        model%audit_hmax = MAX(hmax0, subdt)
        IF (PRESENT(substeps_used)) substeps_used = nsub
        ErrStat = CD_MODEL_OK
        ErrMsg = ''
        RETURN
      END IF
      IF (es /= CD_MODEL_OK) EXIT
      IF (nsub == recovery_cap) EXIT
      IF (nsub > recovery_cap/4) THEN
        nsub = recovery_cap
      ELSE
        nsub = 4*nsub
      END IF
    END DO

    CALL restore_recovery_state(model)
    converged = .FALSE.
    stalled = .TRUE.
    n_iter = max_iter_seen
    IF (es /= CD_MODEL_OK) THEN
      ErrStat = es
    ELSE
      ErrStat = CD_MODEL_SOLVEFAIL
    END IF
    IF (LEN_TRIM(em) == 0) em = first_em
    IF (LEN_TRIM(em) == 0) em = 'nonlinear solve did not converge'
    BLOCK
      CHARACTER(1024) :: wbuf
      INTEGER :: wios
      wbuf = ''
      WRITE (wbuf, '(A,ES12.4,A,I0,A)', IOSTAT=wios) 'CableDyn_Model: recovery failed over dt=', dt, &
        ' s at the subdivision cap ', recovery_cap, ': '//TRIM(em)
      ErrMsg = wbuf
    END BLOCK
  END SUBROUTINE CD_Step_Model_Recovering

  LOGICAL FUNCTION model_lengths_committed(model) RESULT(same)
    !! The unstretched lengths and rates are those the committed state was reached with (bit
    !! for bit). A model without the committed copies counts as committed.
    TYPE(CD_ModelType), INTENT(IN) :: model
    INTEGER :: e
    same = .TRUE.
    IF (.NOT. (ALLOCATED(model%l0_c) .AND. ALLOCATED(model%l0_dot_c))) RETURN
    DO e = 1, SIZE(model%l0)
      IF (.NOT. (bits_equal(model%l0(e), model%l0_c(e)) .AND. bits_equal(model%l0_dot(e), model%l0_dot_c(e)))) THEN
        same = .FALSE.
        RETURN
      END IF
    END DO
  END FUNCTION model_lengths_committed

  ELEMENTAL LOGICAL FUNCTION bits_equal(x, y) RESULT(same)
    !! Bitwise equality of two reals (so +0 and -0 differ).
    REAL(wp), INTENT(IN) :: x, y
    same = TRANSFER(x, 0_INT64) == TRANSFER(y, 0_INT64)
  END FUNCTION bits_equal

  ELEMENTAL REAL(wp) FUNCTION positive_zero(x) RESULT(y)
    !! x with a negative zero replaced by +0, on the bits (so no floating-point mode can keep
    !! the sign); every other value is returned unchanged.
    REAL(wp), INTENT(IN) :: x
    INTEGER(INT64) :: bits
    bits = TRANSFER(x, 0_INT64)
    IF (bits == -HUGE(0_INT64) - 1_INT64) bits = 0_INT64
    y = TRANSFER(bits, y)
  END FUNCTION positive_zero

  SUBROUTINE enter_committed_lengths(model, aside, loads, ErrStat, ErrMsg)
    !! Install the lengths and rates the committed state was reached with (l0_c, l0_dot_c) for
    !! an evaluation of the committed state, setting the present ones aside;
    !! leave_committed_lengths moves them back bit for bit. With loads, the external load and
    !! the seabed coefficients that follow the lengths (the distributed load, and the seabed
    !! stiffness and damping of a model that recomputes them) are rebuilt at l0_c as well, with
    !! the helpers and in the order CD_Update_Model_SegmentLength uses, so they are those of the
    !! committed lengths; they are rebuilt only when a length differs (a rate change alone
    !! leaves them as they are). A model whose lengths and rates are the committed ones is left
    !! as it is. On failure nothing is written.
    TYPE(CD_ModelType), INTENT(INOUT) :: model
    TYPE(model_lengths_aside), INTENT(INOUT) :: aside
    LOGICAL, INTENT(IN) :: loads
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    REAL(wp), ALLOCATABLE :: f_c(:), kn_c(:)
    LOGICAL :: rebuild
    INTEGER :: es
    CHARACTER(KERNEL_MSG_LEN) :: em

    ErrStat = CD_MODEL_OK
    ErrMsg = ''
    aside%active = .FALSE.
    IF (.NOT. model%initialized) RETURN
    IF (model_lengths_committed(model)) RETURN
    rebuild = loads
    IF (rebuild) rebuild = .NOT. ALL(bits_equal(model%l0, model%l0_c))
    IF (rebuild .AND. ALLOCATED(model%dist_load)) THEN
      ALLOCATE (f_c(SIZE(model%f_ext)), STAT=es)
      IF (es /= 0) THEN
        ErrStat = CD_MODEL_ALLOCFAIL
        ErrMsg = 'committed lengths: external-load workspace allocation failed'
        RETURN
      END IF
      CALL CD_Assemble_Distributed_Load(model%elem_conn, model%l0_c, model%dist_load, f_c, es, em)
      IF (es /= 0) THEN
        CALL fail(ErrStat, ErrMsg, 'committed lengths: distributed-load assembly failed: '//TRIM(em))
        RETURN
      END IF
      f_c = model%f_ext_dist_base + f_c
    END IF
    IF (rebuild .AND. model%has_seabed .AND. model%has_seabed_recompute) THEN
      CALL CD_Nodal_Seabed_Stiffness(model%seabed_kbot, model%seabed_diameter_elem, model%l0_c, kn_c, es, em)
      IF (es /= 0) THEN
        CALL fail(ErrStat, ErrMsg, 'committed lengths: seabed stiffness recompute failed: '//TRIM(em))
        RETURN
      END IF
    END IF
    aside%l0 = model%l0
    aside%l0_dot = model%l0_dot
    model%l0 = model%l0_c
    model%l0_dot = model%l0_dot_c
    IF (ALLOCATED(f_c)) THEN
      CALL MOVE_ALLOC(model%f_ext, aside%f_ext)
      CALL MOVE_ALLOC(f_c, model%f_ext)
    END IF
    IF (ALLOCATED(kn_c)) THEN
      CALL MOVE_ALLOC(model%seabed_kn, aside%kn)
      CALL MOVE_ALLOC(kn_c, model%seabed_kn)
      IF (ALLOCATED(model%seabed_cn)) THEN
        CALL MOVE_ALLOC(model%seabed_cn, aside%cn)
        model%seabed_cn = model%seabed_kn*model%seabed_cn_over_kn
      END IF
    END IF
    aside%active = .TRUE.
  END SUBROUTINE enter_committed_lengths

  SUBROUTINE leave_committed_lengths(model, aside)
    !! Move back what enter_committed_lengths set aside.
    TYPE(CD_ModelType), INTENT(INOUT) :: model
    TYPE(model_lengths_aside), INTENT(INOUT) :: aside
    IF (.NOT. aside%active) RETURN
    model%l0 = aside%l0
    model%l0_dot = aside%l0_dot
    IF (ALLOCATED(aside%f_ext)) CALL MOVE_ALLOC(aside%f_ext, model%f_ext)
    IF (ALLOCATED(aside%kn)) CALL MOVE_ALLOC(aside%kn, model%seabed_kn)
    IF (ALLOCATED(aside%cn)) CALL MOVE_ALLOC(aside%cn, model%seabed_cn)
    aside%active = .FALSE.
  END SUBROUTINE leave_committed_lengths

  SUBROUTINE save_recovery_state(model)
    !! Save the committed state into the recovery snapshot (commit_state_copy).
    TYPE(CD_ModelType), INTENT(INOUT) :: model
    CALL commit_state_copy(model, .FALSE., model%recovery_q0, model%recovery_v0, model%recovery_a0, &
                           model%recovery_ve_dl_1, model%recovery_syrope_slow, model%recovery_syrope_tmax, &
                           model%recovery_fr_anchor, model%recovery_l0_c, model%recovery_l0_dot_c, &
                           model%recovery_viv_phi, model%recovery_viv_ms)
  END SUBROUTINE save_recovery_state

  SUBROUTINE restore_recovery_state(model)
    !! Return the model to the recovery snapshot (commit_state_copy).
    TYPE(CD_ModelType), INTENT(INOUT) :: model
    CALL commit_state_copy(model, .TRUE., model%recovery_q0, model%recovery_v0, model%recovery_a0, &
                           model%recovery_ve_dl_1, model%recovery_syrope_slow, model%recovery_syrope_tmax, &
                           model%recovery_fr_anchor, model%recovery_l0_c, model%recovery_l0_dot_c, &
                           model%recovery_viv_phi, model%recovery_viv_ms)
    model%ve_dt = CD_ZERO
  END SUBROUTINE restore_recovery_state

  SUBROUTINE mapped_friction_anchors(model, q, v, commit, ErrStat, ErrMsg)
    !! Return mapping of the stick-slip friction springs at the state (q, v): a spring
    !! stretched beyond its capacity (mu times the normal reaction) moves its anchor to the
    !! capacity distance behind the node, so the committed force is the one the converged
    !! residual used; a node off the seabed (capacity zero) carries its anchor along. With
    !! commit false only the queries run (the step validates them before it commits any
    !! state); with commit true the anchors are updated.
    TYPE(CD_ModelType), INTENT(INOUT) :: model
    REAL(wp), INTENT(IN) :: q(:), v(:)
    LOGICAL, INTENT(IN) :: commit
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    INTEGER :: i, ix, lk
    REAL(wp) :: normal, cap, d(2), dlen, k, mu_d, q_d, gq_d(2)
    ErrStat = CD_MODEL_OK
    ErrMsg = ''
    lk = MIN(LEN(ErrMsg), KERNEL_MSG_LEN) ! the per-node query's share of ErrMsg
    DO i = 1, SIZE(model%fr_anchor, 2)
      ix = 3*i - 2
      normal = seabed_normal_reaction(model, q(ix), q(ix + 1), q(ix + 2), v(ix:ix + 2), i, ErrStat, ErrMsg(1:lk))
      IF (ErrStat /= CD_MODEL_OK) RETURN
      IF (.NOT. commit) CYCLE
      IF (model%seabed_friction_aniso) THEN
        d = q(ix:ix + 1) - model%fr_anchor(:, i)
        CALL CD_Seabed_Friction_Mu_Dir(d, model%seabed_mu_axial, model%seabed_mu, friction_axis(q, i), &
                                       mu_d, q_d, gq_d)
        cap = mu_d*MAX(normal, CD_ZERO)
      ELSE
        cap = model%seabed_mu*MAX(normal, CD_ZERO)
      END IF
      k = model%seabed_kn(i)
      d = q(ix:ix + 1) - model%fr_anchor(:, i)
      dlen = SQRT(d(1)*d(1) + d(2)*d(2))
      IF (k*dlen > cap) model%fr_anchor(:, i) = q(ix:ix + 1) - (cap/(k*dlen))*d
    END DO
  END SUBROUTINE mapped_friction_anchors

  SUBROUTINE quintic_model_boundary_state(q0, v0, a0, q1, v1, a1, duration, u, q, v, a)
    REAL(wp), INTENT(IN) :: q0(:), v0(:), a0(:), q1(:), v1(:), a1(:), duration, u
    REAL(wp), INTENT(OUT) :: q(:), v(:), a(:)
    REAL(wp) :: u2, u3, u4, u5, t2

    u2 = u*u
    u3 = u2*u
    u4 = u3*u
    u5 = u4*u
    t2 = duration*duration
    q = (CD_ONE - 10.0_wp*u3 + 15.0_wp*u4 - 6.0_wp*u5)*q0 + &
        (u - 6.0_wp*u3 + 8.0_wp*u4 - 3.0_wp*u5)*duration*v0 + &
        0.5_wp*(u2 - 3.0_wp*u3 + 3.0_wp*u4 - u5)*t2*a0 + &
        (10.0_wp*u3 - 15.0_wp*u4 + 6.0_wp*u5)*q1 + &
        (-4.0_wp*u3 + 7.0_wp*u4 - 3.0_wp*u5)*duration*v1 + &
        0.5_wp*(u3 - 2.0_wp*u4 + u5)*t2*a1
    v = (-30.0_wp*u2 + 60.0_wp*u3 - 30.0_wp*u4)*q0/duration + &
        (CD_ONE - 18.0_wp*u2 + 32.0_wp*u3 - 15.0_wp*u4)*v0 + &
        (u - 4.5_wp*u2 + 6.0_wp*u3 - 2.5_wp*u4)*duration*a0 + &
        (30.0_wp*u2 - 60.0_wp*u3 + 30.0_wp*u4)*q1/duration + &
        (-12.0_wp*u2 + 28.0_wp*u3 - 15.0_wp*u4)*v1 + &
        (1.5_wp*u2 - 4.0_wp*u3 + 2.5_wp*u4)*duration*a1
    a = (-60.0_wp*u + 180.0_wp*u2 - 120.0_wp*u3)*q0/t2 + &
        (-36.0_wp*u + 96.0_wp*u2 - 60.0_wp*u3)*v0/duration + &
        (CD_ONE - 9.0_wp*u + 18.0_wp*u2 - 10.0_wp*u3)*a0 + &
        (60.0_wp*u - 180.0_wp*u2 + 120.0_wp*u3)*q1/t2 + &
        (-24.0_wp*u + 84.0_wp*u2 - 60.0_wp*u3)*v1/duration + &
        (3.0_wp*u - 12.0_wp*u2 + 10.0_wp*u3)*a1
  END SUBROUTINE quintic_model_boundary_state

  SUBROUTINE ensure_model_query_workspace(model, need_mass, need_added, need_tangent, need_reduced, need_rhs_cols, &
                                          ErrStat, ErrMsg)
    !! Grow reusable model-owned scratch for output/load derivative queries.
    TYPE(CD_ModelType), INTENT(INOUT) :: model
    LOGICAL, INTENT(IN) :: need_mass, need_added, need_tangent
    INTEGER, INTENT(IN) :: need_reduced, need_rhs_cols
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg

    INTEGER :: istat, n

    ErrStat = CD_MODEL_OK
    ErrMsg = ''
    IF (.NOT. model%initialized) THEN
      ErrStat = CD_MODEL_NOT_INITIALIZED
      ErrMsg = 'CableDyn_Model: model is not initialized'
      RETURN
    END IF
    IF (need_reduced < 0 .OR. need_rhs_cols < 0) THEN
      CALL fail(ErrStat, ErrMsg, 'query workspace reduced size must be non-negative')
      RETURN
    END IF
    n = model%n_dof

    IF (vector_needs_capacity(model%dynamic_workspace%R, n)) THEN
      IF (ALLOCATED(model%dynamic_workspace%R)) DEALLOCATE (model%dynamic_workspace%R)
      ALLOCATE (model%dynamic_workspace%R(n), STAT=istat)
      IF (istat /= 0) THEN
        CALL alloc_fail(ErrStat, ErrMsg, 'query residual workspace allocation failed')
        RETURN
      END IF
    END IF
    IF (vector_needs_capacity(model%dynamic_workspace%fint_eval, n)) THEN
      IF (ALLOCATED(model%dynamic_workspace%fint_eval)) DEALLOCATE (model%dynamic_workspace%fint_eval)
      ALLOCATE (model%dynamic_workspace%fint_eval(n), STAT=istat)
      IF (istat /= 0) THEN
        CALL alloc_fail(ErrStat, ErrMsg, 'query internal-force workspace allocation failed')
        RETURN
      END IF
    END IF
    IF (vector_needs_capacity(model%dynamic_workspace%load_eval, n)) THEN
      IF (ALLOCATED(model%dynamic_workspace%load_eval)) DEALLOCATE (model%dynamic_workspace%load_eval)
      ALLOCATE (model%dynamic_workspace%load_eval(n), STAT=istat)
      IF (istat /= 0) THEN
        CALL alloc_fail(ErrStat, ErrMsg, 'query load workspace allocation failed')
        RETURN
      END IF
    END IF

    IF (need_mass) THEN
      IF (matrix_needs_capacity(model%dynamic_workspace%M, n, n)) THEN
        IF (ALLOCATED(model%dynamic_workspace%M)) DEALLOCATE (model%dynamic_workspace%M)
        ALLOCATE (model%dynamic_workspace%M(n, n), STAT=istat)
        IF (istat /= 0) THEN
          CALL alloc_fail(ErrStat, ErrMsg, 'query mass workspace allocation failed')
          RETURN
        END IF
      END IF
    END IF

    IF (need_added) THEN
      IF (matrix_needs_capacity(model%dynamic_workspace%M_add_eval, n, n)) THEN
        IF (ALLOCATED(model%dynamic_workspace%M_add_eval)) DEALLOCATE (model%dynamic_workspace%M_add_eval)
        ALLOCATE (model%dynamic_workspace%M_add_eval(n, n), STAT=istat)
        IF (istat /= 0) THEN
          CALL alloc_fail(ErrStat, ErrMsg, 'query added-mass workspace allocation failed')
          RETURN
        END IF
      END IF
      IF (matrix_needs_capacity(model%dynamic_workspace%dMa_a_dq_eval, n, n)) THEN
        IF (ALLOCATED(model%dynamic_workspace%dMa_a_dq_eval)) DEALLOCATE (model%dynamic_workspace%dMa_a_dq_eval)
        ALLOCATE (model%dynamic_workspace%dMa_a_dq_eval(n, n), STAT=istat)
        IF (istat /= 0) THEN
          CALL alloc_fail(ErrStat, ErrMsg, 'query added-mass tangent workspace allocation failed')
          RETURN
        END IF
      END IF
    END IF

    IF (need_tangent) THEN
      IF (matrix_needs_capacity(model%dynamic_workspace%Kt_eval, n, n)) THEN
        IF (ALLOCATED(model%dynamic_workspace%Kt_eval)) DEALLOCATE (model%dynamic_workspace%Kt_eval)
        ALLOCATE (model%dynamic_workspace%Kt_eval(n, n), STAT=istat)
        IF (istat /= 0) THEN
          CALL alloc_fail(ErrStat, ErrMsg, 'query tangent workspace allocation failed')
          RETURN
        END IF
      END IF
      IF (matrix_needs_capacity(model%dynamic_workspace%jac_q_eval, n, n)) THEN
        IF (ALLOCATED(model%dynamic_workspace%jac_q_eval)) DEALLOCATE (model%dynamic_workspace%jac_q_eval)
        ALLOCATE (model%dynamic_workspace%jac_q_eval(n, n), STAT=istat)
        IF (istat /= 0) THEN
          CALL alloc_fail(ErrStat, ErrMsg, 'query dload/dq workspace allocation failed')
          RETURN
        END IF
      END IF
      IF (matrix_needs_capacity(model%dynamic_workspace%jac_v_eval, n, n)) THEN
        IF (ALLOCATED(model%dynamic_workspace%jac_v_eval)) DEALLOCATE (model%dynamic_workspace%jac_v_eval)
        ALLOCATE (model%dynamic_workspace%jac_v_eval(n, n), STAT=istat)
        IF (istat /= 0) THEN
          CALL alloc_fail(ErrStat, ErrMsg, 'query dload/dv workspace allocation failed')
          RETURN
        END IF
      END IF
      IF (vector_needs_capacity(model%dynamic_workspace%tension_eval, model%n_elem)) THEN
        IF (ALLOCATED(model%dynamic_workspace%tension_eval)) DEALLOCATE (model%dynamic_workspace%tension_eval)
        ALLOCATE (model%dynamic_workspace%tension_eval(model%n_elem), STAT=istat)
        IF (istat /= 0) THEN
          CALL alloc_fail(ErrStat, ErrMsg, 'query tension workspace allocation failed')
          RETURN
        END IF
      END IF
    END IF

    IF (need_reduced > 0) THEN
      IF (matrix_needs_capacity(model%dynamic_workspace%eff_free, need_reduced, need_reduced)) THEN
        IF (ALLOCATED(model%dynamic_workspace%eff_free)) DEALLOCATE (model%dynamic_workspace%eff_free)
        ALLOCATE (model%dynamic_workspace%eff_free(need_reduced, need_reduced), STAT=istat)
        IF (istat /= 0) THEN
          CALL alloc_fail(ErrStat, ErrMsg, 'query reduced-matrix workspace allocation failed')
          RETURN
        END IF
      END IF
    END IF

    IF (need_reduced > 0 .AND. need_rhs_cols > 0) THEN
      IF (matrix_needs_capacity(model%dynamic_workspace%eff, need_reduced, need_rhs_cols)) THEN
        IF (ALLOCATED(model%dynamic_workspace%eff)) DEALLOCATE (model%dynamic_workspace%eff)
        ALLOCATE (model%dynamic_workspace%eff(need_reduced, need_rhs_cols), STAT=istat)
        IF (istat /= 0) THEN
          CALL alloc_fail(ErrStat, ErrMsg, 'query rhs workspace allocation failed')
          RETURN
        END IF
      END IF
      IF (matrix_needs_capacity(model%dynamic_workspace%M_eff_eval, need_reduced, need_rhs_cols)) THEN
        IF (ALLOCATED(model%dynamic_workspace%M_eff_eval)) DEALLOCATE (model%dynamic_workspace%M_eff_eval)
        ALLOCATE (model%dynamic_workspace%M_eff_eval(need_reduced, need_rhs_cols), STAT=istat)
        IF (istat /= 0) THEN
          CALL alloc_fail(ErrStat, ErrMsg, 'query secondary-rhs workspace allocation failed')
          RETURN
        END IF
      END IF
    END IF

  CONTAINS

    LOGICAL FUNCTION vector_needs_capacity(x, n_min) RESULT(needs)
      REAL(wp), ALLOCATABLE, INTENT(IN) :: x(:)
      INTEGER, INTENT(IN) :: n_min

      needs = .NOT. ALLOCATED(x)
      IF (.NOT. needs) needs = SIZE(x) < n_min
    END FUNCTION vector_needs_capacity

    LOGICAL FUNCTION matrix_needs_capacity(x, n1_min, n2_min) RESULT(needs)
      REAL(wp), ALLOCATABLE, INTENT(IN) :: x(:, :)
      INTEGER, INTENT(IN) :: n1_min, n2_min

      needs = .NOT. ALLOCATED(x)
      IF (.NOT. needs) needs = SIZE(x, 1) < n1_min .OR. SIZE(x, 2) < n2_min
    END FUNCTION matrix_needs_capacity
  END SUBROUTINE ensure_model_query_workspace

  SUBROUTINE fill_nodes_workspace(model, ErrStat)
    !! model%dynamic_workspace%nodes_eval = RESHAPE(model%q, [3, n_nodes]), in storage that
    !! is allocated once and reused.
    TYPE(CD_ModelType), INTENT(INOUT) :: model
    INTEGER, INTENT(OUT) :: ErrStat
    INTEGER :: n_nodes, k, istat

    ErrStat = CD_MODEL_OK
    n_nodes = model%n_dof/3
    IF (ALLOCATED(model%dynamic_workspace%nodes_eval)) THEN
      IF (SIZE(model%dynamic_workspace%nodes_eval, 2) /= n_nodes) DEALLOCATE (model%dynamic_workspace%nodes_eval)
    END IF
    IF (.NOT. ALLOCATED(model%dynamic_workspace%nodes_eval)) THEN
      ALLOCATE (model%dynamic_workspace%nodes_eval(3, n_nodes), STAT=istat)
      IF (istat /= 0) THEN
        ErrStat = CD_MODEL_ALLOCFAIL
        RETURN
      END IF
    END IF
    DO k = 1, n_nodes
      model%dynamic_workspace%nodes_eval(:, k) = model%q(3*k - 2:3*k)
    END DO
  END SUBROUTINE fill_nodes_workspace

  SUBROUTINE partition_model_free_workspace(model, n_free, ErrStat, ErrMsg)
    !! Fill model%free_map_work with free DOFs using model-owned marker scratch.
    TYPE(CD_ModelType), INTENT(INOUT) :: model
    INTEGER, INTENT(OUT) :: n_free
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg

    INTEGER :: i, dof, istat
    LOGICAL :: free_map_ready, need_marker

    ErrStat = CD_MODEL_OK
    ErrMsg = ''
    n_free = 0
    free_map_ready = ALLOCATED(model%free_map_work)
    IF (free_map_ready) free_map_ready = SIZE(model%free_map_work) >= model%n_dof
    IF (.NOT. free_map_ready) THEN
      CALL fail(ErrStat, ErrMsg, 'free-DOF partition requires initialized free-map workspace')
      RETURN
    END IF
    need_marker = .NOT. ALLOCATED(model%dynamic_workspace%dof_marker)
    IF (.NOT. need_marker) need_marker = SIZE(model%dynamic_workspace%dof_marker) < model%n_dof
    IF (need_marker) THEN
      IF (ALLOCATED(model%dynamic_workspace%dof_marker)) DEALLOCATE (model%dynamic_workspace%dof_marker)
      ALLOCATE (model%dynamic_workspace%dof_marker(model%n_dof), STAT=istat)
      IF (istat /= 0) THEN
        CALL alloc_fail(ErrStat, ErrMsg, 'free-DOF marker workspace allocation failed')
        RETURN
      END IF
    END IF
    model%dynamic_workspace%dof_marker(1:model%n_dof) = 0
    DO i = 1, SIZE(model%fixed_dofs)
      dof = model%fixed_dofs(i)
      IF (dof < 1 .OR. dof > model%n_dof) THEN
        CALL fail(ErrStat, ErrMsg, 'fixed DOF is out of range')
        RETURN
      END IF
      IF (model%dynamic_workspace%dof_marker(dof) /= 0) THEN
        CALL fail(ErrStat, ErrMsg, 'fixed DOFs contain duplicates')
        RETURN
      END IF
      model%dynamic_workspace%dof_marker(dof) = 1
    END DO
    DO dof = 1, model%n_dof
      IF (model%dynamic_workspace%dof_marker(dof) == 0) THEN
        n_free = n_free + 1
        model%free_map_work(n_free) = dof
      END IF
    END DO
  END SUBROUTINE partition_model_free_workspace

  SUBROUTINE CD_Get_Model_State(model, q, v, a, ErrStat, ErrMsg)
    !! Copy the current model state into caller-owned arrays.
    TYPE(CD_ModelType), INTENT(IN) :: model
    REAL(wp), INTENT(OUT) :: q(:), v(:), a(:)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg

    q = CD_ZERO
    v = CD_ZERO
    a = CD_ZERO
    ErrStat = CD_MODEL_OK
    ErrMsg = ''
    IF (.NOT. model%initialized) THEN
      ErrStat = CD_MODEL_NOT_INITIALIZED
      ErrMsg = 'CableDyn_Model: model is not initialized'
      RETURN
    END IF
    IF (SIZE(q) /= model%n_dof .OR. SIZE(v) /= model%n_dof .OR. SIZE(a) /= model%n_dof) THEN
      CALL fail(ErrStat, ErrMsg, 'q, v, and a outputs must each have shape (3 n_nodes)')
      RETURN
    END IF
    q = model%q
    v = model%v
    a = model%a
  END SUBROUTINE CD_Get_Model_State

  PURE LOGICAL FUNCTION CD_Model_Has_Viscoelastic(model) RESULT(has)
    !! True if the model carries per-element series-Kelvin viscoelastic state.
    TYPE(CD_ModelType), INTENT(IN) :: model
    has = model%has_viscoelastic
  END FUNCTION CD_Model_Has_Viscoelastic

  SUBROUTINE CD_Get_Model_VE_Dl1(model, dl1, ErrStat, ErrMsg)
    !! Copy the per-element viscoelastic internal strain dl_1 (size n_elem) for the
    !! coupled checkpoint mirror. A non-viscoelastic model returns zeros (the mirror
    !! never queries one, but keep the accessor total).
    TYPE(CD_ModelType), INTENT(IN) :: model
    REAL(wp), INTENT(OUT) :: dl1(:)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    dl1 = CD_ZERO
    ErrStat = CD_MODEL_OK
    ErrMsg = ''
    IF (.NOT. model%initialized) THEN
      ErrStat = CD_MODEL_NOT_INITIALIZED
      ErrMsg = 'CableDyn_Model: model is not initialized'
      RETURN
    END IF
    IF (SIZE(dl1) /= model%n_elem) THEN
      CALL fail(ErrStat, ErrMsg, 'dl1 output must have shape (n_elem)')
      RETURN
    END IF
    IF (model%has_viscoelastic) dl1 = model%ve_dl_1
  END SUBROUTINE CD_Get_Model_VE_Dl1

  SUBROUTINE CD_Set_Model_VE_Dl1(model, dl1, ErrStat, ErrMsg)
    !! Overwrite the per-element viscoelastic internal strain dl_1 from a checkpoint
    !! mirror (the cross-process restart reload). Fails closed on a non-viscoelastic
    !! model, a shape mismatch, or a non-finite mirror.
    TYPE(CD_ModelType), INTENT(INOUT) :: model
    REAL(wp), INTENT(IN) :: dl1(:)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    ErrStat = CD_MODEL_OK
    ErrMsg = ''
    IF (.NOT. model%initialized) THEN
      ErrStat = CD_MODEL_NOT_INITIALIZED
      ErrMsg = 'CableDyn_Model: model is not initialized'
      RETURN
    END IF
    IF (.NOT. model%has_viscoelastic) THEN
      CALL fail(ErrStat, ErrMsg, 'model carries no viscoelastic state to set')
      RETURN
    END IF
    IF (SIZE(dl1) /= model%n_elem) THEN
      CALL fail(ErrStat, ErrMsg, 'dl1 input must have shape (n_elem)')
      RETURN
    END IF
    IF (.NOT. CD_All_Finite(dl1)) THEN
      CALL fail(ErrStat, ErrMsg, 'dl1 mirror must be finite')
      RETURN
    END IF
    model%ve_dl_1 = dl1
    ! The rollback and recovery twins follow, so a later rollback cannot bring back the
    ! state this replaces (as CD_Set_Model_Friction_Anchors does).
    model%ve_dl_1_rollback = dl1
    model%recovery_ve_dl_1 = dl1
  END SUBROUTINE CD_Set_Model_VE_Dl1

  PURE LOGICAL FUNCTION CD_Model_Has_Syrope(model) RESULT(has)
    !! True if the model carries per-element Syrope (working-curve) internal state.
    TYPE(CD_ModelType), INTENT(IN) :: model
    has = model%has_syrope
  END FUNCTION CD_Model_Has_Syrope

  SUBROUTINE CD_Get_Model_Syrope_State(model, slow, tmax, ErrStat, ErrMsg)
    !! Copy the per-element Syrope committed states -- the slow-spring static strain
    !! slow and the running-maximum tension tmax (each size n_elem) -- for the coupled
    !! checkpoint mirror. A non-Syrope model returns zeros (total accessor). The slow strain
    !! is that of the lengths the committed state was reached with (l0_c), the lengths a
    !! checkpoint restart re-applies as committed (CD_Update_Model_SegmentLength, restored).
    TYPE(CD_ModelType), INTENT(IN) :: model
    REAL(wp), INTENT(OUT) :: slow(:), tmax(:)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    slow = CD_ZERO
    tmax = CD_ZERO
    ErrStat = CD_MODEL_OK
    ErrMsg = ''
    IF (.NOT. model%initialized) THEN
      ErrStat = CD_MODEL_NOT_INITIALIZED
      ErrMsg = 'CableDyn_Model: model is not initialized'
      RETURN
    END IF
    IF (SIZE(slow) /= model%n_elem .OR. SIZE(tmax) /= model%n_elem) THEN
      CALL fail(ErrStat, ErrMsg, 'slow and tmax outputs must each have shape (n_elem)')
      RETURN
    END IF
    IF (model%has_syrope) THEN
      slow = model%syrope_slow
      tmax = model%syrope_tmax
    END IF
  END SUBROUTINE CD_Get_Model_Syrope_State

  SUBROUTINE CD_Set_Model_Syrope_State(model, slow, tmax, ErrStat, ErrMsg)
    !! Overwrite the per-element Syrope committed states (slow-spring static strain and
    !! running-maximum tension) from a checkpoint mirror (the cross-process restart
    !! reload). Fails closed on a non-Syrope model, a shape mismatch, or a non-finite
    !! mirror.
    TYPE(CD_ModelType), INTENT(INOUT) :: model
    REAL(wp), INTENT(IN) :: slow(:), tmax(:)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    INTEGER :: e, es
    REAL(wp) :: ws(CD_SYROPE_NWC), wt(CD_SYROPE_NWC), wsl(CD_SYROPE_NWC)
    CHARACTER(1024) :: em
    ErrStat = CD_MODEL_OK
    ErrMsg = ''
    IF (.NOT. model%initialized) THEN
      ErrStat = CD_MODEL_NOT_INITIALIZED
      ErrMsg = 'CableDyn_Model: model is not initialized'
      RETURN
    END IF
    IF (.NOT. model%has_syrope) THEN
      CALL fail(ErrStat, ErrMsg, 'model carries no Syrope state to set')
      RETURN
    END IF
    IF (SIZE(slow) /= model%n_elem .OR. SIZE(tmax) /= model%n_elem) THEN
      CALL fail(ErrStat, ErrMsg, 'slow and tmax inputs must each have shape (n_elem)')
      RETURN
    END IF
    IF (.NOT. (CD_All_Finite(slow) .AND. CD_All_Finite(tmax))) THEN
      CALL fail(ErrStat, ErrMsg, 'Syrope state mirror must be finite')
      RETURN
    END IF
    ! CD_Syrope_Working_Curve rejects a nonpositive running maximum, so fail closed at the
    ! reload boundary (a corrupted or edited checkpoint) rather than storing an invalid
    ! tmax that only trips the next load evaluation. Only Syrope elements carry a live tmax.
    IF (ANY(model%syrope_is .AND. .NOT. (tmax > CD_ZERO))) THEN
      CALL fail(ErrStat, ErrMsg, 'Syrope running-maximum tension (tmax) must be positive for every '// &
                'Syrope element')
      RETURN
    END IF
    IF (ANY(model%syrope_is .AND. slow < CD_ZERO)) THEN
      CALL fail(ErrStat, ErrMsg, 'Syrope slow-spring strain must be non-negative for every Syrope element')
      RETURN
    END IF
    DO e = 1, model%n_elem
      IF (.NOT. model%syrope_is(e)) CYCLE
      CALL CD_Syrope_Working_Curve(model%syrope_type(e), tmax(e), ws, wt, wsl, es, em)
      IF (es /= CD_SYROPE_OK) THEN
        CALL fail(ErrStat, ErrMsg, 'Syrope state mirror has invalid tmax: '//TRIM(em))
        RETURN
      END IF
      CALL CD_Syrope_Check_Range(model%syrope_type(e), slow(e), es, em)
      IF (es /= CD_SYROPE_OK) THEN
        CALL fail(ErrStat, ErrMsg, 'Syrope state mirror has invalid slow strain: '//TRIM(em))
        RETURN
      END IF
    END DO
    model%syrope_slow = slow
    model%syrope_tmax = tmax
    ! The rollback and recovery twins follow (see CD_Set_Model_VE_Dl1).
    model%syrope_slow_rollback = slow
    model%syrope_tmax_rollback = tmax
    model%recovery_syrope_slow = slow
    model%recovery_syrope_tmax = tmax
  END SUBROUTINE CD_Set_Model_Syrope_State

  SUBROUTINE CD_Set_Model_VIV(model, rho, cl, diameter, cf, df, t_window, ErrStat, ErrMsg, phase_seed, &
                              tangent_reversed)
    !! Install the cross-flow VIV model (CableDyn_VIV) on an initialised line. Per element:
    !! the lift coefficient cl (0 = no lift on that element), hydrodynamic diameter, and the
    !! synchronisation centre cf and half-range df of the non-dimensional shedding frequency;
    !! rho is the water density. t_window is the averaging time of the running cross-flow mean
    !! squares [s]; 0 selects MoorDyn's 500 time steps, latched at the first step. Every
    !! interior free node next to a cl > 0 element carries a lift and a shedding phase; the
    !! phases start spread over [0, 2 pi) along the line, the mean squares at 0. MoorDyn-C starts
    !! node i from End A at 2 pi i/N with the node tangent from End A to End B; the model's
    !! tangent (from node nd - 1 to nd + 1) runs from End B to End A, which turns the lift and the
    !! cross-flow axis around, so the same motion starts here from those phases plus pi.
    !! phase_seed, per node, gives the start as a fraction of a turn instead
    !! (CD_Deck_VIV_Phase_Seed: a line whose deck End A the reader turned around, a refined mesh).
    !! An all-zero cl leaves the model without VIV. The mesh must be the single chain the
    !! line builder makes (element e joins nodes e and e+1). The caller recomputes the
    !! acceleration if the lift should enter the initial state (CD_Recompute_Model_Acceleration).
    TYPE(CD_ModelType), INTENT(INOUT) :: model
    REAL(wp), INTENT(IN) :: rho, cl(:), diameter(:), cf(:), df(:), t_window
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    REAL(wp), INTENT(IN), OPTIONAL :: phase_seed(:)
    !! tangent_reversed (default .TRUE., the model's own seed): the node tangent runs against
    !! MoorDyn's, so a node at rest takes the cross-flow phase pi (CD_VIV_Phase_Rate phi_rest);
    !! .FALSE. on a line the reader turned around, whose tangent runs as MoorDyn's
    LOGICAL, INTENT(IN), OPTIONAL :: tangent_reversed
    INTEGER :: n_nodes, n_elem, e, nd, istat, k
    REAL(wp) :: wsum

    ErrStat = CD_MODEL_OK
    ErrMsg = ''
    IF (.NOT. model%initialized) THEN
      ErrStat = CD_MODEL_NOT_INITIALIZED
      ErrMsg = 'CableDyn_Model: model is not initialized'
      RETURN
    END IF
    n_elem = model%n_elem
    n_nodes = model%n_dof/3
    IF (SIZE(cl) /= n_elem .OR. SIZE(diameter) /= n_elem .OR. SIZE(cf) /= n_elem .OR. SIZE(df) /= n_elem) THEN
      CALL fail(ErrStat, ErrMsg, 'VIV cl, diameter, cf and df must each have shape (n_elem)')
      RETURN
    END IF
    IF (.NOT. (CD_All_Finite(cl) .AND. CD_All_Finite(diameter) .AND. CD_All_Finite(cf) .AND. &
               CD_All_Finite(df))) THEN
      CALL fail(ErrStat, ErrMsg, 'VIV coefficients must be finite')
      RETURN
    END IF
    IF (ANY(cl < CD_ZERO)) THEN
      CALL fail(ErrStat, ErrMsg, 'VIV lift coefficient Cl must be non-negative')
      RETURN
    END IF
    IF (.NOT. (CD_Is_Finite(t_window) .AND. t_window >= CD_ZERO)) THEN
      CALL fail(ErrStat, ErrMsg, 'VIV averaging time must be finite and non-negative')
      RETURN
    END IF
    IF (PRESENT(phase_seed)) THEN
      IF (SIZE(phase_seed) /= n_nodes .OR. .NOT. CD_All_Finite(phase_seed)) THEN
        CALL fail(ErrStat, ErrMsg, 'VIV phase seed must be finite with shape (n_nodes)')
        RETURN
      END IF
    END IF
    CALL clear_viv(model)
    IF (.NOT. ANY(cl > CD_ZERO)) RETURN
    IF (.NOT. (CD_Is_Finite(rho) .AND. rho > CD_ZERO)) THEN
      CALL fail(ErrStat, ErrMsg, 'VIV water density must be finite and positive')
      RETURN
    END IF
    DO e = 1, n_elem
      IF (.NOT. (cl(e) > CD_ZERO)) CYCLE
      IF (.NOT. (diameter(e) > CD_ZERO)) THEN
        CALL fail(ErrStat, ErrMsg, 'VIV needs a positive diameter on every Cl > 0 element')
        RETURN
      END IF
      IF (.NOT. (cf(e) > CD_ZERO .AND. df(e) >= CD_ZERO .AND. df(e) < cf(e))) THEN
        CALL fail(ErrStat, ErrMsg, 'VIV synchronisation needs cF > 0 and 0 <= dF < cF (a positive '// &
                  'shedding frequency)')
        RETURN
      END IF
    END DO
    DO e = 1, n_elem
      IF (model%elem_conn(1, e) /= e .OR. model%elem_conn(2, e) /= e + 1) THEN
        CALL fail(ErrStat, ErrMsg, 'VIV needs a single-chain line mesh (element e joining nodes e and e+1)')
        RETURN
      END IF
    END DO
    ALLOCATE (model%viv_cl(n_elem), model%viv_d(n_elem), model%viv_node(n_nodes), model%viv_cf(n_nodes), &
              model%viv_df(n_nodes), model%viv_dn(n_nodes), model%viv_phi(n_nodes), model%viv_ms(2, n_nodes), &
              model%viv_phi_rollback(n_nodes), model%viv_ms_rollback(2, n_nodes), &
              model%recovery_viv_phi(n_nodes), model%recovery_viv_ms(2, n_nodes), &
              model%viv_phi_eval(n_nodes), model%viv_rate(n_nodes), model%viv_ms_next(2, n_nodes), &
              model%viv_phi_next(n_nodes), STAT=istat)
    IF (istat /= 0) THEN
      CALL clear_viv(model)
      CALL alloc_fail(ErrStat, ErrMsg, 'VIV storage allocation failed')
      RETURN
    END IF
    model%viv_rho = rho
    model%viv_tw = t_window
    model%viv_cl = MERGE(cl, CD_ZERO, cl > CD_ZERO)
    model%viv_d = MERGE(diameter, CD_ZERO, cl > CD_ZERO)
    model%viv_node = .FALSE.
    model%viv_cf = CD_ZERO
    model%viv_df = CD_ZERO
    model%viv_dn = CD_ZERO
    model%viv_phi = CD_ZERO
    model%viv_ms = CD_ZERO
    DO nd = 2, n_nodes - 1
      IF (.NOT. (cl(nd - 1) > CD_ZERO .OR. cl(nd) > CD_ZERO)) CYCLE
      IF (ANY(model%fixed_dofs >= 3*nd - 2 .AND. model%fixed_dofs <= 3*nd)) CYCLE
      model%viv_node(nd) = .TRUE.
      wsum = CD_ZERO
      DO k = nd - 1, nd
        IF (.NOT. (cl(k) > CD_ZERO)) CYCLE
        wsum = wsum + model%l0(k)
        model%viv_cf(nd) = model%viv_cf(nd) + model%l0(k)*cf(k)
        model%viv_df(nd) = model%viv_df(nd) + model%l0(k)*df(k)
        model%viv_dn(nd) = model%viv_dn(nd) + model%l0(k)*diameter(k)
      END DO
      model%viv_cf(nd) = model%viv_cf(nd)/wsum
      model%viv_df(nd) = model%viv_df(nd)/wsum
      model%viv_dn(nd) = model%viv_dn(nd)/wsum
      ! MoorDyn: phi_i = 2 pi i/N at node i = 0..N counted from End A; the model numbers its
      ! nodes from End B, so node nd is MoorDyn's node n_nodes - nd, and its tangent runs the other
      ! way (half a turn on)
      model%viv_phi(nd) = CD_VIV_Wrap_Phase(CD_VIV_TWO_PI*(REAL(n_nodes - nd, wp)/REAL(n_elem, wp) + 0.5_wp))
      IF (PRESENT(phase_seed)) model%viv_phi(nd) = CD_VIV_TWO_PI*phase_seed(nd)
    END DO
    model%viv_phi_rollback = model%viv_phi
    model%viv_ms_rollback = model%viv_ms
    model%recovery_viv_phi = model%viv_phi
    model%recovery_viv_ms = model%viv_ms
    model%viv_phi_eval = model%viv_phi
    model%viv_rate = CD_ZERO
    model%viv_ms_next = model%viv_ms
    model%viv_phi_next = model%viv_phi
    model%viv_phi_rest = 0.5_wp*CD_VIV_TWO_PI
    IF (PRESENT(tangent_reversed)) model%viv_phi_rest = MERGE(0.5_wp*CD_VIV_TWO_PI, CD_ZERO, tangent_reversed)
    model%has_viv = .TRUE.
  END SUBROUTINE CD_Set_Model_VIV

  SUBROUTINE CD_Latch_Model_VIV_Window(model, dt)
    !! Fix MoorDyn's default VIV averaging time, 500 steps of the nominal step dt, unless the
    !! model already has one (a deck VIVrmsWindow or an earlier latch). Callers that subdivide
    !! a step latch with the nominal step before subdividing; otherwise the first step does.
    TYPE(CD_ModelType), INTENT(INOUT) :: model
    REAL(wp), INTENT(IN) :: dt
    IF (.NOT. model%has_viv) RETURN
    IF (model%viv_tw > CD_ZERO) RETURN
    IF (.NOT. (CD_Is_Finite(dt) .AND. dt > CD_ZERO)) RETURN
    model%viv_tw = REAL(CD_VIV_NM, wp)*dt
  END SUBROUTINE CD_Latch_Model_VIV_Window

  SUBROUTINE CD_Get_Model_VIV_State(model, phi, ms, t_window, ErrStat, ErrMsg)
    !! Copy the committed VIV state for a checkpoint: the shedding phase per node (n_nodes),
    !! the running mean squares of the cross-flow velocity and acceleration (2, n_nodes), and
    !! the averaging time (0 while unlatched). A model without VIV returns zeros.
    TYPE(CD_ModelType), INTENT(IN) :: model
    REAL(wp), INTENT(OUT) :: phi(:), ms(:, :), t_window
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    phi = CD_ZERO
    ms = CD_ZERO
    t_window = CD_ZERO
    ErrStat = CD_MODEL_OK
    ErrMsg = ''
    IF (.NOT. model%initialized) THEN
      ErrStat = CD_MODEL_NOT_INITIALIZED
      ErrMsg = 'CableDyn_Model: model is not initialized'
      RETURN
    END IF
    IF (SIZE(phi) /= model%n_dof/3 .OR. SIZE(ms, 1) /= 2 .OR. SIZE(ms, 2) /= model%n_dof/3) THEN
      CALL fail(ErrStat, ErrMsg, 'VIV state outputs must have shapes (n_nodes) and (2, n_nodes)')
      RETURN
    END IF
    IF (.NOT. model%has_viv) RETURN
    phi = model%viv_phi
    ms = model%viv_ms
    t_window = model%viv_tw
  END SUBROUTINE CD_Get_Model_VIV_State

  SUBROUTINE CD_Set_Model_VIV_State(model, phi, ms, t_window, ErrStat, ErrMsg)
    !! Overwrite the committed VIV state from a checkpoint (see CD_Get_Model_VIV_State).
    !! Fails closed on a model without VIV, a shape mismatch, non-finite values, a negative
    !! mean square or averaging time.
    TYPE(CD_ModelType), INTENT(INOUT) :: model
    REAL(wp), INTENT(IN) :: phi(:), ms(:, :), t_window
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    ErrStat = CD_MODEL_OK
    ErrMsg = ''
    IF (.NOT. model%initialized) THEN
      ErrStat = CD_MODEL_NOT_INITIALIZED
      ErrMsg = 'CableDyn_Model: model is not initialized'
      RETURN
    END IF
    IF (.NOT. model%has_viv) THEN
      CALL fail(ErrStat, ErrMsg, 'model carries no VIV state to set')
      RETURN
    END IF
    IF (SIZE(phi) /= model%n_dof/3 .OR. SIZE(ms, 1) /= 2 .OR. SIZE(ms, 2) /= model%n_dof/3) THEN
      CALL fail(ErrStat, ErrMsg, 'VIV state inputs must have shapes (n_nodes) and (2, n_nodes)')
      RETURN
    END IF
    IF (.NOT. (CD_All_Finite(phi) .AND. CD_All_Finite(ms) .AND. CD_Is_Finite(t_window))) THEN
      CALL fail(ErrStat, ErrMsg, 'VIV state mirror must be finite')
      RETURN
    END IF
    IF (ANY(ms < CD_ZERO) .OR. t_window < CD_ZERO) THEN
      CALL fail(ErrStat, ErrMsg, 'VIV mean squares and averaging time must be non-negative')
      RETURN
    END IF
    model%viv_phi = phi
    model%viv_ms = ms
    model%viv_tw = t_window
    ! the rollback and recovery twins follow (see CD_Set_Model_VE_Dl1)
    model%viv_phi_rollback = phi
    model%viv_ms_rollback = ms
    model%recovery_viv_phi = phi
    model%recovery_viv_ms = ms
    model%viv_phi_eval = phi
  END SUBROUTINE CD_Set_Model_VIV_State

  SUBROUTINE CD_Get_Model_VIV_Lift(model, lift, ErrStat, ErrMsg)
    !! The VIV lift force on every node at the committed state [N] (3, n_nodes); zero on the
    !! end nodes, on nodes without VIV, and on a model without VIV.
    TYPE(CD_ModelType), INTENT(IN) :: model
    REAL(wp), INTENT(OUT) :: lift(:, :)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    INTEGER :: nd, ia
    REAL(wp) :: coef, uu(3)
    LOGICAL :: ok
    lift = CD_ZERO
    ErrStat = CD_MODEL_OK
    ErrMsg = ''
    IF (.NOT. model%initialized) THEN
      ErrStat = CD_MODEL_NOT_INITIALIZED
      ErrMsg = 'CableDyn_Model: model is not initialized'
      RETURN
    END IF
    IF (SIZE(lift, 1) /= 3 .OR. SIZE(lift, 2) /= model%n_dof/3) THEN
      CALL fail(ErrStat, ErrMsg, 'VIV lift output must have shape (3, n_nodes)')
      RETURN
    END IF
    IF (.NOT. model%has_viv) RETURN
    DO nd = 2, model%n_dof/3 - 1
      IF (.NOT. model%viv_node(nd)) CYCLE
      CALL viv_node_coef(model, model%q, nd, coef, uu)
      ia = 3*nd - 2
      CALL CD_VIV_Node_Lift(model%q(ia - 3:ia - 1), model%q(ia + 3:ia + 5), smoothed(model%v, ia), uu, coef, &
                            model%viv_phi(nd), lift(:, nd), ok)
    END DO
  END SUBROUTINE CD_Get_Model_VIV_Lift

  PURE LOGICAL FUNCTION CD_Model_Has_VIV(model) RESULT(has)
    !! True if the model carries the cross-flow VIV phase state.
    TYPE(CD_ModelType), INTENT(IN) :: model
    has = model%has_viv
  END FUNCTION CD_Model_Has_VIV

  SUBROUTINE viv_node_coef(model, q, nd, coef, uu)
    !! Lift scale of interior node nd at positions q, sum over its two elements of
    !! (1/2 l0_e w_e)(1/2 rho D_e Cl_e) with w_e the wetted fraction under the drag waterline
    !! (as MoorDyn's 1/4 rho d Cl (F_i l_i + F_i+1 l_i+1)), and the ambient fluid velocity there.
    TYPE(CD_ModelType), INTENT(IN) :: model
    REAL(wp), INTENT(IN) :: q(:)
    INTEGER, INTENT(IN) :: nd
    REAL(wp), INTENT(OUT) :: coef, uu(3)
    INTEGER :: e
    REAL(wp) :: wla, wlb, frac
    coef = CD_ZERO
    DO e = nd - 1, nd
      IF (.NOT. (model%viv_cl(e) > CD_ZERO)) CYCLE
      wla = CD_ZERO
      wlb = CD_ZERO
      IF (ALLOCATED(model%drag_waterline_z)) THEN
        wla = model%drag_waterline_z(e)
        wlb = model%drag_waterline_z(e + 1)
      END IF
      CALL CD_Submerged_Fraction(q(3*e) - wla, q(3*e + 3) - wlb, frac)
      coef = coef + 0.25_wp*model%viv_rho*model%viv_d(e)*model%viv_cl(e)*model%l0(e)*frac
    END DO
    uu = CD_ZERO
    IF (ALLOCATED(model%fluid_velocity)) uu = model%fluid_velocity(:, nd)
  END SUBROUTINE viv_node_coef

  SUBROUTINE viv_step_begin(model, dt, ErrStat, ErrMsg)
    !! Step-start VIV quantities from the committed state (q_n, v_n, a_n, phi_n): the mean
    !! squares with the step-start cross-flow sample (viv_ms_next), the phase rate
    !! (viv_rate), and the explicit phase the in-step lift uses (viv_phi_eval): at t_{n+1},
    !! phi_n + dt rate_n, under the force blend, whose in-step force is r(q_{n+1}, v_{n+1})
    !! (the committed-state force F_n keeps phi_n); at the generalised-alpha level,
    !! phi_n + (1 - alpha_f) dt rate_n, under the configuration blend.
    TYPE(CD_ModelType), INTENT(INOUT) :: model
    REAL(wp), INTENT(IN) :: dt
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    INTEGER :: nd, ia
    REAL(wp) :: w, alpha_f, yd, ydd, un, coef, uu(3)
    LOGICAL :: ok
    ErrStat = CD_MODEL_OK
    ErrMsg = ''
    CALL CD_Latch_Model_VIV_Window(model, dt)
    w = MIN(CD_ONE, dt/model%viv_tw)
    alpha_f = model%cfg%rho_inf/(model%cfg%rho_inf + CD_ONE)
    IF (model%cfg%force_blend) alpha_f = CD_ZERO
    model%viv_rate = CD_ZERO
    model%viv_ms_next = model%viv_ms
    model%viv_phi_eval = model%viv_phi
    DO nd = 2, model%n_dof/3 - 1
      IF (.NOT. model%viv_node(nd)) CYCLE
      CALL viv_node_coef(model, model%q, nd, coef, uu)
      ia = 3*nd - 2
      CALL CD_VIV_Crossflow_Motion(model%q(ia - 3:ia - 1), model%q(ia + 3:ia + 5), smoothed(model%v, ia), &
                                   smoothed(model%a, ia), uu, yd, ydd, un, ok)
      IF (.NOT. ok) THEN
        CALL fail(ErrStat, ErrMsg, 'VIV phase: the neighbours of a node coincide (no line tangent)')
        RETURN
      END IF
      model%viv_ms_next(1, nd) = CD_VIV_Mean_Square(model%viv_ms(1, nd), yd, w)
      model%viv_ms_next(2, nd) = CD_VIV_Mean_Square(model%viv_ms(2, nd), ydd, w)
      model%viv_rate(nd) = CD_VIV_Phase_Rate(yd, ydd, model%viv_ms_next(1, nd), model%viv_ms_next(2, nd), &
                                             model%viv_phi(nd), un, model%viv_dn(nd), model%viv_cf(nd), &
                                             model%viv_df(nd), phi_rest=model%viv_phi_rest)
      model%viv_phi_eval(nd) = model%viv_phi(nd) + (CD_ONE - alpha_f)*dt*model%viv_rate(nd)
    END DO
  END SUBROUTINE viv_step_begin

  SUBROUTINE viv_step_end(model, dt, ErrStat, ErrMsg)
    !! End-of-step VIV phase by Heun's rule (the trapezoidal corrector of the explicit Euler
    !! predictor): phi_n+1 = phi_n + dt/2 (rate_n + rate(state_n+1, phi_n + dt rate_n)), with
    !! the end-state cross-flow sample added to the mean squares for that rate (not stored:
    !! the next step adds it itself). Writes viv_phi_next only.
    TYPE(CD_ModelType), INTENT(INOUT) :: model
    REAL(wp), INTENT(IN) :: dt
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    INTEGER :: nd, ia
    REAL(wp) :: w, yd, ydd, un, coef, uu(3), ms1, ms2, rate_end
    LOGICAL :: ok
    ErrStat = CD_MODEL_OK
    ErrMsg = ''
    w = MIN(CD_ONE, dt/model%viv_tw)
    model%viv_phi_next = model%viv_phi
    DO nd = 2, model%n_dof/3 - 1
      IF (.NOT. model%viv_node(nd)) CYCLE
      CALL viv_node_coef(model, model%q_step, nd, coef, uu)
      ia = 3*nd - 2
      CALL CD_VIV_Crossflow_Motion(model%q_step(ia - 3:ia - 1), model%q_step(ia + 3:ia + 5), &
                                   smoothed(model%v_step, ia), smoothed(model%a_step, ia), uu, yd, ydd, un, ok)
      IF (.NOT. ok) THEN
        CALL fail(ErrStat, ErrMsg, 'VIV phase: the neighbours of a node coincide (no line tangent)')
        RETURN
      END IF
      ms1 = CD_VIV_Mean_Square(model%viv_ms_next(1, nd), yd, w)
      ms2 = CD_VIV_Mean_Square(model%viv_ms_next(2, nd), ydd, w)
      rate_end = CD_VIV_Phase_Rate(yd, ydd, ms1, ms2, model%viv_phi(nd) + dt*model%viv_rate(nd), un, &
                                   model%viv_dn(nd), model%viv_cf(nd), model%viv_df(nd), phi_rest=model%viv_phi_rest)
      model%viv_phi_next(nd) = CD_VIV_Wrap_Phase(model%viv_phi(nd) + 0.5_wp*dt*(model%viv_rate(nd) + rate_end))
    END DO
    IF (.NOT. CD_All_Finite(model%viv_phi_next)) THEN
      CALL fail(ErrStat, ErrMsg, 'VIV phase update produced a non-finite phase')
    END IF
  END SUBROUTINE viv_step_end

  PURE FUNCTION smoothed(x, ia) RESULT(xs)
    !! Node kinematics for the VIV phase and lift: the node value averaged with its two
    !! neighbours, (x_{i-1} + 2 x_i + x_{i+1})/4, at the node whose x component is ia. Thorsen's
    !! model follows the cross-flow motion of a continuum. The node's own acceleration weights
    !! the mesh-scale zig-zag mode (neighbours moving opposite to the node) by omega^2, so at
    !! steps that resolve that mode it took over the phase, and through the lift the phase
    !! pumped the mode until the line lost lock-in. The average removes the zig-zag mode
    !! exactly and keeps a resolved mode of wavenumber k to cos^2(k l0 / 2). The lift takes the
    !! smoothed velocity as well: through its dependence on the node's own velocity, modulated by
    !! the phase, the zig-zag mode was pumped even with a smoothed phase.
    REAL(wp), INTENT(IN) :: x(:)
    INTEGER, INTENT(IN) :: ia
    REAL(wp) :: xs(3)
    xs = 0.25_wp*(x(ia - 3:ia - 1) + 2.0_wp*x(ia:ia + 2) + x(ia + 3:ia + 5))
  END FUNCTION smoothed

  SUBROUTINE clear_viv(model)
    !! Release the VIV storage; the model then carries no VIV.
    TYPE(CD_ModelType), INTENT(INOUT) :: model
    IF (ALLOCATED(model%viv_cl)) DEALLOCATE (model%viv_cl)
    IF (ALLOCATED(model%viv_d)) DEALLOCATE (model%viv_d)
    IF (ALLOCATED(model%viv_node)) DEALLOCATE (model%viv_node)
    IF (ALLOCATED(model%viv_cf)) DEALLOCATE (model%viv_cf)
    IF (ALLOCATED(model%viv_df)) DEALLOCATE (model%viv_df)
    IF (ALLOCATED(model%viv_dn)) DEALLOCATE (model%viv_dn)
    IF (ALLOCATED(model%viv_phi)) DEALLOCATE (model%viv_phi)
    IF (ALLOCATED(model%viv_ms)) DEALLOCATE (model%viv_ms)
    IF (ALLOCATED(model%viv_phi_rollback)) DEALLOCATE (model%viv_phi_rollback)
    IF (ALLOCATED(model%viv_ms_rollback)) DEALLOCATE (model%viv_ms_rollback)
    IF (ALLOCATED(model%recovery_viv_phi)) DEALLOCATE (model%recovery_viv_phi)
    IF (ALLOCATED(model%recovery_viv_ms)) DEALLOCATE (model%recovery_viv_ms)
    IF (ALLOCATED(model%viv_phi_eval)) DEALLOCATE (model%viv_phi_eval)
    IF (ALLOCATED(model%viv_rate)) DEALLOCATE (model%viv_rate)
    IF (ALLOCATED(model%viv_ms_next)) DEALLOCATE (model%viv_ms_next)
    IF (ALLOCATED(model%viv_phi_next)) DEALLOCATE (model%viv_phi_next)
    model%has_viv = .FALSE.
    model%viv_rho = CD_ZERO
    model%viv_tw = CD_ZERO
  END SUBROUTINE clear_viv

  SUBROUTINE CD_Set_Model_Friction_Axial(model, mu_axial, ErrStat, ErrMsg)
    !! Make the stick-slip seabed friction of a model anisotropic: the model's seabed_mu
    !! becomes the lateral coefficient and mu_axial the coefficient along the line (the
    !! horizontal projection of the node's chord tangent, re-evaluated at every residual
    !! call; the Jacobian omits its dependence on the positions). mu_axial equal to
    !! seabed_mu keeps the isotropic law bit-for-bit.
    TYPE(CD_ModelType), INTENT(INOUT) :: model
    REAL(wp), INTENT(IN) :: mu_axial
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    ErrStat = CD_MODEL_OK
    ErrMsg = ''
    IF (.NOT. (CD_Is_Finite(mu_axial) .AND. mu_axial > CD_ZERO)) THEN
      CALL fail(ErrStat, ErrMsg, 'the axial friction coefficient must be finite and positive')
      RETURN
    END IF
    IF (.NOT. model%has_seabed_friction) THEN
      CALL fail(ErrStat, ErrMsg, 'the model carries no seabed friction')
      RETURN
    END IF
    model%seabed_mu_axial = mu_axial
    model%seabed_friction_aniso = ABS(mu_axial - model%seabed_mu) > CD_ZERO
  END SUBROUTINE CD_Set_Model_Friction_Axial

  PURE FUNCTION friction_axis(q, node) RESULT(axis)
    !! Horizontal line axis at a node for anisotropic friction: the chord through its
    !! neighbours (one-sided at the ends), projected on the horizontal. The neighbours
    !! are nodes node-1 and node+1: the line models number their nodes along the line
    !! (CD_Build_Line_Mesh), which the anisotropic friction assumes.
    REAL(wp), INTENT(IN) :: q(:)
    INTEGER, INTENT(IN) :: node
    REAL(wp) :: axis(2)
    INTEGER :: nn, ia, ib
    nn = SIZE(q)/3
    ia = MAX(1, node - 1)
    ib = MIN(nn, node + 1)
    axis = q(3*ib - 2:3*ib - 1) - q(3*ia - 2:3*ia - 1)
  END FUNCTION friction_axis

  PURE LOGICAL FUNCTION CD_Model_Has_Friction(model) RESULT(has)
    !! True if the model carries stick-slip seabed friction (anchor state).
    TYPE(CD_ModelType), INTENT(IN) :: model
    has = model%initialized .AND. model%has_seabed_friction .AND. ALLOCATED(model%fr_anchor)
  END FUNCTION CD_Model_Has_Friction

  SUBROUTINE CD_Get_Model_Friction_Anchors(model, anchors, ErrStat, ErrMsg)
    !! Copy the committed stick-slip friction anchors, (2, n_nodes).
    TYPE(CD_ModelType), INTENT(IN) :: model
    REAL(wp), INTENT(OUT) :: anchors(:, :)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    ErrStat = CD_MODEL_OK
    ErrMsg = ''
    anchors = CD_ZERO
    IF (.NOT. CD_Model_Has_Friction(model)) THEN
      CALL fail(ErrStat, ErrMsg, 'the model carries no seabed friction state')
      RETURN
    END IF
    IF (SIZE(anchors, 1) /= 2 .OR. SIZE(anchors, 2) /= SIZE(model%fr_anchor, 2)) THEN
      CALL fail(ErrStat, ErrMsg, 'friction anchors must have shape (2, n_nodes)')
      RETURN
    END IF
    anchors = model%fr_anchor
  END SUBROUTINE CD_Get_Model_Friction_Anchors

  SUBROUTINE CD_Set_Model_Friction_Anchors(model, anchors, ErrStat, ErrMsg)
    !! Overwrite the committed stick-slip friction anchors, (2, n_nodes): from a static
    !! solve with friction (then call CD_Recompute_Model_Acceleration) or a checkpoint
    !! mirror. The rollback and recovery twins follow, so a later rollback cannot bring
    !! back the anchors this replaces.
    TYPE(CD_ModelType), INTENT(INOUT) :: model
    REAL(wp), INTENT(IN) :: anchors(:, :)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    ErrStat = CD_MODEL_OK
    ErrMsg = ''
    IF (.NOT. CD_Model_Has_Friction(model)) THEN
      CALL fail(ErrStat, ErrMsg, 'the model carries no seabed friction state')
      RETURN
    END IF
    IF (SIZE(anchors, 1) /= 2 .OR. SIZE(anchors, 2) /= SIZE(model%fr_anchor, 2)) THEN
      CALL fail(ErrStat, ErrMsg, 'friction anchors must have shape (2, n_nodes)')
      RETURN
    END IF
    IF (.NOT. CD_All_Finite(anchors)) THEN
      CALL fail(ErrStat, ErrMsg, 'friction anchors must be finite')
      RETURN
    END IF
    model%fr_anchor = anchors
    model%fr_anchor_rollback = anchors
    model%recovery_fr_anchor = anchors
  END SUBROUTINE CD_Set_Model_Friction_Anchors

  SUBROUTINE CD_Calc_Model_CoupledLoads(model, coupled_loads, ErrStat, ErrMsg)
    !! Return loads exerted BY the CableDyn model ON the externally coupled DOFs.
    !! The internal dynamic residual at prescribed DOFs is
    !!   R_c = M*a + f_int - f_ext,
    !! which is the support force needed on the cable. The equal-and-opposite force
    !! that the cable applies to the coupled object is therefore -R_c. This is the
    !! force-vector half of the OpenFAST/C kinematics-in/loads-out boundary.
    TYPE(CD_ModelType), INTENT(INOUT) :: model
    REAL(wp), INTENT(OUT) :: coupled_loads(:)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg

    INTEGER :: es, istat, k
    CHARACTER(1024) :: em

    ErrStat = CD_MODEL_OK
    ErrMsg = ''
    coupled_loads = CD_ZERO
    IF (.NOT. model%initialized) THEN
      ErrStat = CD_MODEL_NOT_INITIALIZED
      ErrMsg = 'CableDyn_Model: model is not initialized'
      RETURN
    END IF
    IF (SIZE(coupled_loads) /= SIZE(model%fixed_dofs)) THEN
      CALL fail(ErrStat, ErrMsg, 'coupled_loads output must have shape (n_coupled_dof)')
      RETURN
    END IF

    CALL ensure_model_query_workspace(model, need_mass=.FALSE., need_added=.FALSE., &
                                      need_tangent=.FALSE., need_reduced=0, need_rhs_cols=0, &
                                      ErrStat=ErrStat, ErrMsg=ErrMsg)
    IF (ErrStat /= CD_MODEL_OK) RETURN
    IF (model%has_added_mass) THEN
      IF (.NOT. ALLOCATED(model%dynamic_workspace%M_add_a_eval)) THEN
        ALLOCATE (model%dynamic_workspace%M_add_a_eval(model%n_dof), STAT=istat)
      ELSE IF (SIZE(model%dynamic_workspace%M_add_a_eval) < model%n_dof) THEN
        DEALLOCATE (model%dynamic_workspace%M_add_a_eval)
        ALLOCATE (model%dynamic_workspace%M_add_a_eval(model%n_dof), STAT=istat)
      ELSE
        istat = 0
      END IF
      IF (istat /= 0) THEN
        CALL alloc_fail(ErrStat, ErrMsg, 'coupled-load added-mass force workspace allocation failed')
        RETURN
      END IF
    END IF
    ASSOCIATE (fint => model%dynamic_workspace%fint_eval(1:model%n_dof), &
               residual => model%dynamic_workspace%R(1:model%n_dof), &
               load => model%dynamic_workspace%load_eval(1:model%n_dof))
      CALL fill_nodes_workspace(model, es)
      IF (es /= CD_MODEL_OK) THEN
        CALL alloc_fail(ErrStat, ErrMsg, 'nodal workspace allocation failed')
        RETURN
      END IF
      CALL CD_Assemble_Cable_Internal_Force(model%dynamic_workspace%nodes_eval, model%elem_conn, &
                                            model%l0, model%ea_dyn, model%tension_only, fint, es, em, &
                                            topology_validated=.TRUE.)
      IF (es /= 0) THEN
        ErrStat = CD_MODEL_SOLVEFAIL
        ErrMsg = 'CableDyn_Model: internal-force assembly failed during coupled-load calculation: '//TRIM(em)
        RETURN
      END IF
      ! A line coupled at its end nodes only (a line between points): the remaining terms on the
      ! end rows alone (coupled_loads_at_ends), bit-identical to the whole-line residual below.
      ! The whole-line terms validate the accelerations element by element (the added-mass
      ! kernels): with any non-finite one they are formed whole, to fail as they do.
      IF (ALL(model%fixed_dofs <= 3 .OR. model%fixed_dofs > model%n_dof - 3) .AND. CD_All_Finite(model%a)) THEN
        CALL coupled_loads_at_ends(model, fint, coupled_loads, ErrStat, ErrMsg)
        RETURN
      END IF
      CALL model_structural_mass_product(model, model%a, residual)
      residual = residual + fint - model%f_ext
      IF (model%has_added_mass) THEN
        CALL model_added_mass_force(model, model%q, model%a, &
                                    model%dynamic_workspace%M_add_a_eval(1:model%n_dof), es, em)
        IF (es /= 0) THEN
          ErrStat = CD_MODEL_SOLVEFAIL
          ErrMsg = 'CableDyn_Model: added-mass assembly failed during coupled-load calculation: '//TRIM(em)
          RETURN
        END IF
        residual = residual + model%dynamic_workspace%M_add_a_eval(1:model%n_dof)
      END IF
      CALL model_contributor_force(model, model%q, model%v, load, es, em)
      IF (es /= 0) THEN
        ErrStat = CD_MODEL_SOLVEFAIL
        ErrMsg = 'CableDyn_Model: load assembly failed during coupled-load calculation: '//TRIM(em)
        RETURN
      END IF
      residual = residual - load
      DO k = 1, SIZE(model%fixed_dofs)
        coupled_loads(k) = -residual(model%fixed_dofs(k))
      END DO
    END ASSOCIATE
  END SUBROUTINE CD_Calc_Model_CoupledLoads

  SUBROUTINE coupled_loads_at_ends(model, fint, coupled_loads, ErrStat, ErrMsg)
    !! The rest of CD_Calc_Model_CoupledLoads, given the whole-line internal force fint, for a
    !! line whose coupled DOFs all belong to its first or last node and whose accelerations are
    !! finite. Only the two end rows of M a + f_int - f_ext + M_add a - load are formed, from
    !! the elements that touch an end node and the end nodes' own terms (model_contributor_force
    !! end_nodes_only). Each row takes its terms in the element order of the whole-line
    !! assembly and its operations in the same order, so the loads are bit-identical to it, as
    !! in CD_Get_Model_EndForces; the elements that touch no end node, which add nothing to
    !! these rows, are not evaluated.
    TYPE(CD_ModelType), INTENT(IN) :: model
    REAL(wp), INTENT(IN) :: fint(:)
    REAL(wp), INTENT(OUT) :: coupled_loads(:)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg

    INTEGER :: n, nn, e, a, b, ia, ib, sa, sb, k, d, es, idx(6), lk
    REAL(wp) :: inertia(3, 2), added(3, 2), residual(3, 2), load(9)
    REAL(wp) :: coeff, q2(6), a2(6), wl2(2), ma2(6)
    CHARACTER(1024) :: em

    ErrStat = CD_MODEL_OK
    ErrMsg = ''
    coupled_loads = CD_ZERO
    lk = MIN(LEN(em), KERNEL_MSG_LEN)
    n = model%n_dof
    nn = n/3
    ! M a (model_structural_mass_product) on the end rows, from zero in element order
    inertia = CD_ZERO
    DO e = 1, model%n_elem
      a = model%elem_conn(1, e)
      b = model%elem_conn(2, e)
      sa = end_slot(a)
      sb = end_slot(b)
      IF (sa == 0 .AND. sb == 0) CYCLE
      ia = 3*a - 2
      ib = 3*b - 2
      coeff = model%rho_a(e)*model%l0(e)/6.0_wp
      IF (sa /= 0) inertia(:, sa) = inertia(:, sa) + coeff*(2.0_wp*model%a(ia:ia + 2) + model%a(ib:ib + 2))
      IF (sb /= 0) inertia(:, sb) = inertia(:, sb) + coeff*(model%a(ia:ia + 2) + 2.0_wp*model%a(ib:ib + 2))
    END DO
    DO k = 1, 2
      residual(:, k) = inertia(:, k) + fint(end_base(k) + 1:end_base(k) + 3) - &
                       model%f_ext(end_base(k) + 1:end_base(k) + 3)
    END DO
    ! M_add a (model_added_mass_force), from zero in element order
    IF (model%has_added_mass) THEN
      added = CD_ZERO
      DO e = 1, model%n_elem
        sa = end_slot(model%elem_conn(1, e))
        sb = end_slot(model%elem_conn(2, e))
        IF (sa == 0 .AND. sb == 0) CYCLE
        CALL extract_element_positions(model, e, model%q, idx, q2)
        a2 = model%a(idx)
        CALL extract_nodal_scalar(model%added_mass_waterline_z, model, e, wl2)
        em = ''
        CALL CD_Added_Mass_Element_Force(q2(1:3), q2(4:6), a2(1:3), a2(4:6), model%l0(e), wl2(1), wl2(2), &
                                         model%added_mass_rho, model%added_mass_diameter_elem(e), &
                                         model%added_mass_can_elem(e), model%added_mass_cat_elem(e), &
                                         ma2, es, em(1:lk))
        IF (es /= 0) THEN
          ErrStat = CD_MODEL_SOLVEFAIL
          ErrMsg = 'CableDyn_Model: added-mass assembly failed during coupled-load calculation: '//TRIM(em)
          RETURN
        END IF
        ! the far node's share stays finite-checked as in the whole-line force
        IF (.NOT. CD_All_Finite(ma2)) THEN
          CALL fail(es, em, 'added-mass force returned non-finite values')
          ErrStat = CD_MODEL_SOLVEFAIL
          ErrMsg = 'CableDyn_Model: added-mass assembly failed during coupled-load calculation: '//TRIM(em)
          RETURN
        END IF
        IF (sa /= 0) added(:, sa) = added(:, sa) + ma2(1:3)
        IF (sb /= 0) added(:, sb) = added(:, sb) + ma2(4:6)
      END DO
      residual = residual + added
    END IF
    CALL model_contributor_force(model, model%q, model%v, load, es, em, end_nodes_only=.TRUE.)
    IF (es /= 0) THEN
      ErrStat = CD_MODEL_SOLVEFAIL
      ErrMsg = 'CableDyn_Model: load assembly failed during coupled-load calculation: '//TRIM(em)
      RETURN
    END IF
    residual(:, 1) = residual(:, 1) - load(1:3)
    residual(:, 2) = residual(:, 2) - load(4:6)
    DO k = 1, SIZE(model%fixed_dofs)
      d = model%fixed_dofs(k)
      IF (d <= 3) THEN
        coupled_loads(k) = -residual(d, 1)
      ELSE
        coupled_loads(k) = -residual(d - end_base(2), 2)
      END IF
    END DO

  CONTAINS

    PURE INTEGER FUNCTION end_slot(node) RESULT(s)
      !! 1 for the first node, 2 for the last, 0 for an interior node.
      INTEGER, INTENT(IN) :: node
      s = 0
      IF (node == 1) THEN
        s = 1
      ELSE IF (node == nn) THEN
        s = 2
      END IF
    END FUNCTION end_slot

    PURE INTEGER FUNCTION end_base(s) RESULT(base)
      !! DOF offset of end slot s.
      INTEGER, INTENT(IN) :: s
      base = MERGE(0, n - 3, s == 1)
    END FUNCTION end_base
  END SUBROUTINE coupled_loads_at_ends

  SUBROUTINE CD_Calc_Model_CoupledKinematicDerivatives(model, dload_dq, dload_dv, ErrStat, ErrMsg)
    !! Analytic reduced coupled-load derivatives with respect to prescribed
    !! coupled positions and velocities. Free DOFs are statically condensed with
    !! the current effective mass, matching the acceleration recompute boundary.
    TYPE(CD_ModelType), INTENT(INOUT) :: model
    REAL(wp), INTENT(OUT) :: dload_dq(:, :), dload_dv(:, :)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg

    INTEGER :: es, nc, n_free, i, j, row, col
    CHARACTER(1024) :: em

    ErrStat = CD_MODEL_OK
    ErrMsg = ''
    dload_dq = CD_ZERO
    dload_dv = CD_ZERO
    IF (.NOT. model%initialized) THEN
      ErrStat = CD_MODEL_NOT_INITIALIZED
      ErrMsg = 'CableDyn_Model: model is not initialized'
      RETURN
    END IF
    nc = SIZE(model%fixed_dofs)
    IF (SIZE(dload_dq, 1) /= nc .OR. SIZE(dload_dq, 2) /= nc .OR. &
        SIZE(dload_dv, 1) /= nc .OR. SIZE(dload_dv, 2) /= nc) THEN
      CALL fail(ErrStat, ErrMsg, 'dload_dq/dload_dv outputs must have shape (n_coupled_dof, n_coupled_dof)')
      RETURN
    END IF
    IF (nc == 0) RETURN

    CALL partition_model_free_workspace(model, n_free, ErrStat, ErrMsg)
    IF (ErrStat /= CD_MODEL_OK) RETURN
    CALL ensure_model_query_workspace(model, need_mass=.TRUE., need_added=model%has_added_mass, &
                                      need_tangent=.TRUE., need_reduced=n_free, need_rhs_cols=nc, &
                                      ErrStat=ErrStat, ErrMsg=ErrMsg)
    IF (ErrStat /= CD_MODEL_OK) RETURN
    ASSOCIATE (Kt => model%dynamic_workspace%Kt_eval(1:model%n_dof, 1:model%n_dof), &
               fint => model%dynamic_workspace%fint_eval(1:model%n_dof), &
               tension => model%dynamic_workspace%tension_eval(1:model%n_elem), &
               load => model%dynamic_workspace%load_eval(1:model%n_dof), &
               jac_q => model%dynamic_workspace%jac_q_eval(1:model%n_dof, 1:model%n_dof), &
               jac_v => model%dynamic_workspace%jac_v_eval(1:model%n_dof, 1:model%n_dof), &
               M => model%dynamic_workspace%M(1:model%n_dof, 1:model%n_dof))
      CALL fill_nodes_workspace(model, es)
      IF (es /= CD_MODEL_OK) THEN
        CALL alloc_fail(ErrStat, ErrMsg, 'nodal workspace allocation failed')
        RETURN
      END IF
      CALL CD_Assemble_Cable_Tangent_Force(model%dynamic_workspace%nodes_eval, model%elem_conn, model%l0, &
                                           model%ea_dyn, model%tension_only, Kt, fint, tension, es, em, &
                                           topology_validated=.TRUE.)
      IF (es /= 0) THEN
        ErrStat = CD_MODEL_SOLVEFAIL
        ErrMsg = 'CableDyn_Model: tangent assembly failed during kinematic derivative: '//TRIM(em)
        RETURN
      END IF
      CALL model_contributor_load(model, model%q, model%v, load, jac_q, jac_v, es, em)
      IF (es /= 0) THEN
        ! Preserve an allocation failure from the load-contributor workspace; only genuine
        ! solver failures collapse to CD_MODEL_SOLVEFAIL.
        IF (es == CD_MODEL_ALLOCFAIL) THEN
          ErrStat = CD_MODEL_ALLOCFAIL
        ELSE
          ErrStat = CD_MODEL_SOLVEFAIL
        END IF
        ErrMsg = 'CableDyn_Model: load Jacobian assembly failed during kinematic derivative: '//TRIM(em)
        RETURN
      END IF
      CALL CD_Assemble_Cable_Mass(model%elem_conn, model%l0, model%rho_a, M, es, em, topology_validated=.TRUE.)
      IF (es /= 0) THEN
        ErrStat = CD_MODEL_SOLVEFAIL
        ErrMsg = 'CableDyn_Model: mass assembly failed during kinematic derivative: '//TRIM(em)
        RETURN
      END IF
      IF (model%has_added_mass) THEN
        ASSOCIATE (M_add => model%dynamic_workspace%M_add_eval(1:model%n_dof, 1:model%n_dof), &
                   dMa_a_dq => model%dynamic_workspace%dMa_a_dq_eval(1:model%n_dof, 1:model%n_dof))
          CALL model_added_mass_full(model, model%q, model%a, M_add, dMa_a_dq, es, em)
          IF (es /= 0) THEN
            ErrStat = CD_MODEL_SOLVEFAIL
            ErrMsg = 'CableDyn_Model: added-mass Jacobian assembly failed during kinematic derivative: '//TRIM(em)
            RETURN
          END IF
          M = M + M_add
          Kt = Kt + dMa_a_dq
        END ASSOCIATE
      END IF
      Kt = Kt + jac_q

      DO j = 1, nc
        col = model%fixed_dofs(j)
        DO i = 1, nc
          row = model%fixed_dofs(i)
          dload_dq(i, j) = -Kt(row, col)
          dload_dv(i, j) = -jac_v(row, col)
        END DO
      END DO
      IF (n_free == 0) RETURN

      ASSOCIATE (Mff => model%dynamic_workspace%eff_free(1:n_free, 1:n_free), &
                 xq => model%dynamic_workspace%eff(1:n_free, 1:nc), &
                 xv => model%dynamic_workspace%M_eff_eval(1:n_free, 1:nc))
        DO j = 1, n_free
          col = model%free_map_work(j)
          DO i = 1, n_free
            row = model%free_map_work(i)
            Mff(i, j) = M(row, col)
          END DO
        END DO
        DO j = 1, nc
          col = model%fixed_dofs(j)
          DO i = 1, n_free
            row = model%free_map_work(i)
            xq(i, j) = Kt(row, col)
            xv(i, j) = jac_v(row, col)
          END DO
        END DO
        CALL CD_Solve_Dense_As_Banded_Multiple(Mff, xq, es, em)
        IF (es /= 0) THEN
          ErrStat = CD_MODEL_SOLVEFAIL
          ErrMsg = 'CableDyn_Model: position derivative condensation solve failed: '//TRIM(em)
          RETURN
        END IF
        CALL CD_Solve_Dense_As_Banded_Multiple(Mff, xv, es, em)
        IF (es /= 0) THEN
          ErrStat = CD_MODEL_SOLVEFAIL
          ErrMsg = 'CableDyn_Model: velocity derivative condensation solve failed: '//TRIM(em)
          RETURN
        END IF
        DO j = 1, nc
          DO i = 1, nc
            row = model%fixed_dofs(i)
            DO col = 1, n_free
              dload_dq(i, j) = dload_dq(i, j) + M(row, model%free_map_work(col))*xq(col, j)
              dload_dv(i, j) = dload_dv(i, j) + M(row, model%free_map_work(col))*xv(col, j)
            END DO
          END DO
        END DO
      END ASSOCIATE
    END ASSOCIATE
  END SUBROUTINE CD_Calc_Model_CoupledKinematicDerivatives

  SUBROUTINE CD_Update_Model_CoupledAccelDerivative(model, ErrStat, ErrMsg)
    !! Bring the coupled-load derivative with respect to prescribed coupled accelerations
    !! up to date in model%dynamic_workspace%ad_result (n_coupled_dof square; see
    !! CD_Calc_Model_CoupledAccelDerivative, which copies it out). For free DOFs eliminated
    !! by the consistent-mass solve, d(load_c)/d(a_c) = -(M_cc - M_cf M_ff^{-1} M_fc), with M
    !! including added mass.
    !! M is block-tridiagonal in node order, so it is assembled directly in band
    !! storage (structural and added mass summed per entry as in the dense form),
    !! M_ff is factored once and solved for all coupled columns together, and the
    !! result is cached until an input of the mass changes. Work and storage are
    !! O(n_dof); the workspace is reused, so a step allocates nothing.
    TYPE(CD_ModelType), INTENT(INOUT) :: model
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg

    INTEGER :: es, nc, n, n_elem, n_free, i, j, k, e, a, b, ia, ib, bwf, kl, ldab, r, c, g, fi, fj
    INTEGER :: idx(6), conn1(2, 1)
    REAL(wp) :: coeff, s, q2(6), l02(1), wl2(2), m2(6, 6)
    LOGICAL :: hit, ok
    CHARACTER(1024) :: em

    ErrStat = CD_MODEL_OK
    ErrMsg = ''
    IF (.NOT. model%initialized) THEN
      ErrStat = CD_MODEL_NOT_INITIALIZED
      ErrMsg = 'CableDyn_Model: model is not initialized'
      RETURN
    END IF
    nc = SIZE(model%fixed_dofs)
    IF (nc == 0) RETURN
    n = model%n_dof
    n_elem = model%n_elem

    ASSOCIATE (w => model%dynamic_workspace)
      ! Cache hit: the mass depends only on the positions (through the added mass), the
      ! unstretched lengths, the mass per length and the fixed-DOF set; the hydrodynamic
      ! coefficients are set at initialisation, which clears this workspace, and a moved
      ! added-mass waterline clears it in CD_Update_Model_Hydro_Fields. Equality is
      ! tested as <= and >= so that a NaN never matches.
      hit = w%ad_valid
      IF (hit) hit = SIZE(w%ad_fixed) == nc .AND. SIZE(w%ad_l0) == n_elem .AND. SIZE(w%ad_q) == n
      IF (hit) hit = ALL(w%ad_fixed == model%fixed_dofs)
      IF (hit) hit = ALL(w%ad_l0 <= model%l0(1:n_elem) .AND. w%ad_l0 >= model%l0(1:n_elem))
      IF (hit) hit = ALL(w%ad_rho <= model%rho_a(1:n_elem) .AND. w%ad_rho >= model%rho_a(1:n_elem))
      IF (hit .AND. model%has_added_mass) hit = ALL(w%ad_q <= model%q(1:n) .AND. w%ad_q >= model%q(1:n))
      IF (hit) RETURN
      w%ad_valid = .FALSE.

      DO e = 1, n_elem
        IF (.NOT. (model%l0(e) > CD_ZERO .AND. model%rho_a(e) > CD_ZERO) .OR. &
            .NOT. CD_Is_Finite(model%l0(e)) .OR. .NOT. CD_Is_Finite(model%rho_a(e))) THEN
          ErrStat = CD_MODEL_SOLVEFAIL
          ErrMsg = 'CableDyn_Model: mass assembly failed during acceleration derivative: '// &
                   'l0 and rho_a must be positive and finite'
          RETURN
        END IF
      END DO
      ! half-bandwidth of the mass in the full node ordering
      bwf = 2
      DO e = 1, n_elem
        bwf = MAX(bwf, 3*ABS(model%elem_conn(1, e) - model%elem_conn(2, e)) + 2)
      END DO

      ok = ensure_i1(w%ad_finv, n)
      IF (ok) ok = ensure_i1(w%ad_fixed, nc)
      IF (ok) ok = ensure_r1(w%ad_q, n)
      IF (ok) ok = ensure_r1(w%ad_l0, n_elem)
      IF (ok) ok = ensure_r1(w%ad_rho, n_elem)
      IF (ok) ok = ensure_r2(w%ad_result, nc, nc)
      IF (ok) ok = ensure_r2(w%ad_full, 2*bwf + 1, n)
      IF (ok .AND. model%has_added_mass) ok = ensure_r2(w%ad_add, 2*bwf + 1, n)
      IF (.NOT. ok) THEN
        CALL alloc_fail(ErrStat, ErrMsg, 'acceleration-derivative workspace allocation failed')
        RETURN
      END IF

      w%ad_result = CD_ZERO
      ! free-DOF numbering in ascending global order (0 marks a fixed DOF)
      w%ad_finv = 1
      DO i = 1, nc
        g = model%fixed_dofs(i)
        IF (g < 1 .OR. g > n) THEN
          CALL fail(ErrStat, ErrMsg, 'fixed DOF is out of range')
          RETURN
        END IF
        IF (w%ad_finv(g) == 0) THEN
          CALL fail(ErrStat, ErrMsg, 'fixed DOFs contain duplicates')
          RETURN
        END IF
        w%ad_finv(g) = 0
      END DO
      n_free = 0
      DO g = 1, n
        IF (w%ad_finv(g) /= 0) THEN
          n_free = n_free + 1
          w%ad_finv(g) = n_free
        END IF
      END DO

      ! structural consistent mass, element by element: m/6 [[2I, I], [I, 2I]]
      w%ad_full = CD_ZERO
      DO e = 1, n_elem
        a = model%elem_conn(1, e)
        b = model%elem_conn(2, e)
        coeff = model%rho_a(e)*model%l0(e)/6.0_wp
        ia = 3*a - 2
        ib = 3*b - 2
        DO k = 0, 2
          w%ad_full(bwf + 1, ia + k) = w%ad_full(bwf + 1, ia + k) + 2.0_wp*coeff
          w%ad_full(bwf + 1 + ia - ib, ib + k) = w%ad_full(bwf + 1 + ia - ib, ib + k) + coeff
          w%ad_full(bwf + 1 + ib - ia, ia + k) = w%ad_full(bwf + 1 + ib - ia, ia + k) + coeff
          w%ad_full(bwf + 1, ib + k) = w%ad_full(bwf + 1, ib + k) + 2.0_wp*coeff
        END DO
      END DO
      ! added mass, assembled on its own and then summed entry by entry
      IF (model%has_added_mass) THEN
        w%ad_add = CD_ZERO
        conn1(:, 1) = [1, 2]
        DO e = 1, n_elem
          CALL extract_element_positions(model, e, model%q, idx, q2)
          CALL extract_nodal_scalar(model%added_mass_waterline_z, model, e, wl2)
          l02(1) = model%l0(e)
          CALL CD_Cable_Added_Mass_Matrix(q2, conn1, l02, wl2, model%added_mass_rho, &
                                          model%added_mass_diameter_elem(e), model%added_mass_can_elem(e), &
                                          model%added_mass_cat_elem(e), m2, es, em)
          IF (es /= 0) THEN
            ErrStat = CD_MODEL_SOLVEFAIL
            ErrMsg = 'CableDyn_Model: added-mass assembly failed during acceleration derivative: '//TRIM(em)
            RETURN
          END IF
          DO j = 1, 6
            DO i = 1, 6
              r = bwf + 1 + idx(i) - idx(j)
              w%ad_add(r, idx(j)) = w%ad_add(r, idx(j)) + m2(i, j)
            END DO
          END DO
        END DO
        w%ad_full = w%ad_full + w%ad_add
      END IF

      DO j = 1, nc
        c = model%fixed_dofs(j)
        DO i = 1, nc
          r = model%fixed_dofs(i)
          IF (ABS(r - c) <= bwf) w%ad_result(i, j) = -w%ad_full(bwf + 1 + r - c, c)
        END DO
      END DO

      IF (n_free > 0) THEN
        IF (.NOT. CD_All_Finite(w%ad_full)) THEN
          ErrStat = CD_MODEL_SOLVEFAIL
          ErrMsg = 'CableDyn_Model: acceleration derivative mass solve failed: the mass must be finite'
          RETURN
        END IF
        ! half-bandwidth of the free/free block in the free numbering
        kl = 0
        DO c = 1, n
          fj = w%ad_finv(c)
          IF (fj == 0) CYCLE
          DO r = MAX(1, c - bwf), MIN(n, c + bwf)
            fi = w%ad_finv(r)
            IF (fi /= 0) kl = MAX(kl, ABS(fi - fj))
          END DO
        END DO
        ldab = 3*kl + 1
        ok = ensure_r2(w%ad_ab, ldab, n_free)
        IF (ok) ok = ensure_r2(w%ad_x, n_free, nc)
        IF (ok) ok = ensure_i1(w%ad_ipiv, n_free)
        IF (.NOT. ok) THEN
          CALL alloc_fail(ErrStat, ErrMsg, 'acceleration-derivative workspace allocation failed')
          RETURN
        END IF
        w%ad_kl = kl
        ! M_ff in LAPACK general-band storage (kl = ku)
        w%ad_ab = CD_ZERO
        DO c = 1, n
          fj = w%ad_finv(c)
          IF (fj == 0) CYCLE
          DO r = MAX(1, c - bwf), MIN(n, c + bwf)
            fi = w%ad_finv(r)
            IF (fi /= 0) w%ad_ab(2*kl + 1 + fi - fj, fj) = w%ad_full(bwf + 1 + r - c, c)
          END DO
        END DO
        ! right-hand sides M_fc
        w%ad_x = CD_ZERO
        DO j = 1, nc
          c = model%fixed_dofs(j)
          DO r = MAX(1, c - bwf), MIN(n, c + bwf)
            fi = w%ad_finv(r)
            IF (fi /= 0) w%ad_x(fi, j) = w%ad_full(bwf + 1 + r - c, c)
          END DO
        END DO
        CALL CD_Factor_Banded(w%ad_ab, kl, kl, w%ad_ipiv, es, em, matrix_validated=.TRUE.)
        IF (es == 0) CALL CD_Solve_Factored_Banded_Multiple(w%ad_ab, kl, kl, w%ad_ipiv, w%ad_x, es, em)
        IF (es /= 0) THEN
          ErrStat = CD_MODEL_SOLVEFAIL
          ErrMsg = 'CableDyn_Model: acceleration derivative mass solve failed: '//TRIM(em)
          RETURN
        END IF
        ! + M_cf M_ff^{-1} M_fc, summed over the free columns in ascending order
        DO j = 1, nc
          DO i = 1, nc
            r = model%fixed_dofs(i)
            s = w%ad_result(i, j)
            DO g = MAX(1, r - bwf), MIN(n, r + bwf)
              fi = w%ad_finv(g)
              IF (fi /= 0) s = s + w%ad_full(bwf + 1 + r - g, g)*w%ad_x(fi, j)
            END DO
            w%ad_result(i, j) = s
          END DO
        END DO
      END IF

      w%ad_fixed = model%fixed_dofs
      w%ad_l0 = model%l0(1:n_elem)
      w%ad_rho = model%rho_a(1:n_elem)
      w%ad_q = model%q(1:n)
      w%ad_valid = .TRUE.
    END ASSOCIATE

  CONTAINS

    LOGICAL FUNCTION ensure_r1(x, n1) RESULT(ready)
      !! Give x exactly n1 entries, reallocating only when the length differs.
      REAL(wp), ALLOCATABLE, INTENT(INOUT) :: x(:)
      INTEGER, INTENT(IN) :: n1
      INTEGER :: istat

      ready = .TRUE.
      IF (ALLOCATED(x)) THEN
        IF (SIZE(x) == n1) RETURN
        DEALLOCATE (x)
      END IF
      ALLOCATE (x(n1), STAT=istat)
      ready = istat == 0
    END FUNCTION ensure_r1

    LOGICAL FUNCTION ensure_i1(x, n1) RESULT(ready)
      !! Give x exactly n1 entries, reallocating only when the length differs.
      INTEGER, ALLOCATABLE, INTENT(INOUT) :: x(:)
      INTEGER, INTENT(IN) :: n1
      INTEGER :: istat

      ready = .TRUE.
      IF (ALLOCATED(x)) THEN
        IF (SIZE(x) == n1) RETURN
        DEALLOCATE (x)
      END IF
      ALLOCATE (x(n1), STAT=istat)
      ready = istat == 0
    END FUNCTION ensure_i1

    LOGICAL FUNCTION ensure_r2(x, n1, n2) RESULT(ready)
      !! Give x exactly the shape (n1, n2), reallocating only when the shape differs.
      REAL(wp), ALLOCATABLE, INTENT(INOUT) :: x(:, :)
      INTEGER, INTENT(IN) :: n1, n2
      INTEGER :: istat

      ready = .TRUE.
      IF (ALLOCATED(x)) THEN
        IF (SIZE(x, 1) == n1 .AND. SIZE(x, 2) == n2) RETURN
        DEALLOCATE (x)
      END IF
      ALLOCATE (x(n1, n2), STAT=istat)
      ready = istat == 0
    END FUNCTION ensure_r2
  END SUBROUTINE CD_Update_Model_CoupledAccelDerivative

  SUBROUTINE CD_Calc_Model_CoupledAccelDerivative(model, dload_da, ErrStat, ErrMsg)
    !! Analytic coupled-load derivative with respect to prescribed coupled
    !! accelerations. For free DOFs eliminated by the consistent-mass solve,
    !! d(load_c)/d(a_c) = -(M_cc - M_cf M_ff^{-1} M_fc), with M including added mass
    !! (computed by CD_Update_Model_CoupledAccelDerivative and copied out).
    TYPE(CD_ModelType), INTENT(INOUT) :: model
    REAL(wp), INTENT(OUT) :: dload_da(:, :)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    INTEGER :: nc

    ErrStat = CD_MODEL_OK
    ErrMsg = ''
    dload_da = CD_ZERO
    IF (.NOT. model%initialized) THEN
      ErrStat = CD_MODEL_NOT_INITIALIZED
      ErrMsg = 'CableDyn_Model: model is not initialized'
      RETURN
    END IF
    nc = SIZE(model%fixed_dofs)
    IF (SIZE(dload_da, 1) /= nc .OR. SIZE(dload_da, 2) /= nc) THEN
      CALL fail(ErrStat, ErrMsg, 'dload_da output must have shape (n_coupled_dof, n_coupled_dof)')
      RETURN
    END IF
    IF (nc == 0) RETURN
    CALL CD_Update_Model_CoupledAccelDerivative(model, ErrStat, ErrMsg)
    IF (ErrStat == CD_MODEL_OK) dload_da = model%dynamic_workspace%ad_result
  END SUBROUTINE CD_Calc_Model_CoupledAccelDerivative

  SUBROUTINE CD_Calc_Model_CoupledEndMass(model, m_cc, ErrStat, ErrMsg)
    !! The coupled-coupled block M_cc of the line mass (the consistent structural mass plus the
    !! added mass at the current positions, exactly as CD_Update_Model_CoupledAccelDerivative
    !! assembles it), n_coupled_dof square in the compact coupled ordering. -M_cc is the
    !! derivative of CD_Calc_Model_CoupledLoads with respect to the prescribed coupled
    !! accelerations at fixed free-DOF accelerations: the response of the coupled loads when
    !! only the coupled motion changes and the line interior keeps its state (an output probe),
    !! whereas CD_Calc_Model_CoupledAccelDerivative lets the free accelerations follow.
    TYPE(CD_ModelType), INTENT(INOUT) :: model
    REAL(wp), INTENT(OUT) :: m_cc(:, :)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    INTEGER :: nc, bwf, e, i, j, r, c

    ErrStat = CD_MODEL_OK
    ErrMsg = ''
    m_cc = CD_ZERO
    IF (.NOT. model%initialized) THEN
      ErrStat = CD_MODEL_NOT_INITIALIZED
      ErrMsg = 'CableDyn_Model: model is not initialized'
      RETURN
    END IF
    nc = SIZE(model%fixed_dofs)
    IF (SIZE(m_cc, 1) /= nc .OR. SIZE(m_cc, 2) /= nc) THEN
      CALL fail(ErrStat, ErrMsg, 'm_cc output must have shape (n_coupled_dof, n_coupled_dof)')
      RETURN
    END IF
    IF (nc == 0) RETURN
    ! brings the banded full mass ad_full up to date (or confirms its cache)
    CALL CD_Update_Model_CoupledAccelDerivative(model, ErrStat, ErrMsg)
    IF (ErrStat /= CD_MODEL_OK) RETURN
    ! the half-bandwidth ad_full was stored with (CD_Update_Model_CoupledAccelDerivative)
    bwf = 2
    DO e = 1, model%n_elem
      bwf = MAX(bwf, 3*ABS(model%elem_conn(1, e) - model%elem_conn(2, e)) + 2)
    END DO
    DO j = 1, nc
      c = model%fixed_dofs(j)
      DO i = 1, nc
        r = model%fixed_dofs(i)
        IF (ABS(r - c) <= bwf) m_cc(i, j) = model%dynamic_workspace%ad_full(bwf + 1 + r - c, c)
      END DO
    END DO
  END SUBROUTINE CD_Calc_Model_CoupledEndMass

  SUBROUTINE CD_Update_Model_SegmentLength(model, elem, l0_new, l0_dot, ErrStat, ErrMsg, restored)
    !! Active line control (the MoorDyn CtrlChan mechanism): set one element's
    !! unstretched length and its rate. The elastic tension and the per-step mass
    !! assembly read model%l0 directly, so the dynamics track the new length from
    !! the next step; the cached structural mass (the coupled-loads/inertia cache)
    !! is re-assembled here so every consumer sees one consistent length. BA stays
    !! frozen at its init resolution (MoorDyn's convention -- BA derives from the
    !! INITIAL UnstrLen). Callers owning point bindings (the system) must recompute
    !! any end-node mass-diagonal shares after this call.
    !! The committed state keeps its acceleration and the lengths it was reached with
    !! (l0_c, l0_dot_c). With the force blend the next step (CD_Step_Model) evaluates its
    !! step-start force at l0_c and l0_dot_c, its end-of-step force at the new lengths and
    !! rates, and only its inertia at the blended lengths (1 - alpha_f) l0 + alpha_f l0_c;
    !! under False alpha_force_blend it blends the lengths and rates into every alpha-level
    !! term. restored = .TRUE. (a checkpoint restart re-applying the command of
    !! the committed state) makes the new length and rate the committed ones as well. A rate
    !! of -0 is stored as +0, so a zero command of either sign leaves an uncontrolled model
    !! bit-identical (the committed-length test compares bits). On a Syrope element the slow
    !! stretch eps_slow*l0 is carried over the change (model_syrope_slow); on a viscoelastic
    !! element the slow-branch stretch dl_1 is, as it is (both as in MoorDyn-F/C).
    TYPE(CD_ModelType), INTENT(INOUT) :: model
    INTEGER, INTENT(IN) :: elem
    REAL(wp), INTENT(IN) :: l0_new, l0_dot
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    LOGICAL, INTENT(IN), OPTIONAL :: restored
    INTEGER :: es
    REAL(wp) :: rate
    CHARACTER(1024) :: em
    ErrStat = CD_MODEL_OK
    ErrMsg = ''
    rate = positive_zero(l0_dot)
    IF (.NOT. model%initialized) THEN
      ErrStat = CD_MODEL_NOT_INITIALIZED
      ErrMsg = 'CableDyn_Model: model is not initialized'
      RETURN
    END IF
    IF (elem < 1 .OR. elem > SIZE(model%l0)) THEN
      CALL fail(ErrStat, ErrMsg, 'segment-length update: element index out of range')
      RETURN
    END IF
    IF (.NOT. (CD_Is_Finite(l0_new) .AND. CD_Is_Finite(l0_dot) .AND. l0_new > CD_ZERO)) THEN
      CALL fail(ErrStat, ErrMsg, 'segment-length update: l0 must be finite and positive, l0_dot finite')
      RETURN
    END IF
    IF (model%has_seabed .AND. .NOT. model%has_seabed_recompute) THEN
      CALL fail(ErrStat, ErrMsg, 'segment-length update on a seabed-contact model needs the seabed '// &
                'recompute scalars (kBot + contact diameter) supplied at init')
      RETURN
    END IF
    ! A viscoelastic element keeps its slow-branch stretch dl_1 as it is, and every law
    ! evaluation reads it with the present l0: MagT = EA_1 dl_1/l0, MagTd = BA ld_1/l0, the ODE
    ! ld_1 = (EA_D dl - (EA_D + EA_1) dl_1 + BA_D lstrd)/(BA_D + BA) with dl = lstr - l0, and the
    ! ElasticMod 3 EA_D(dl_1, l0). That is MoorDyn's rule: MoorDyn-F (MD_CalcContStateDeriv sets
    ! l(N), ld(N) of a controlled line; Line_GetStateDeriv reads Line%dl_1 against Line%l) and
    ! MoorDyn-C (Line::setUnstretchedLength sets every l[i]; Line::getStateDeriv reads dl_1[i]
    ! against l[i]) never touch dl_1 on a length change. The force blend's committed force reads
    ! the same dl_1 at l0_c.
    ! A Syrope element keeps its states as they are: the slow strain stays the committed state's,
    ! a strain of l0_c, and the element reads it at its present length (model_syrope_slow), so
    ! its slow STRETCH carries over the length change as MoorDyn-F/C carry it; the running
    ! maximum, a tension, does not depend on the length.
    ! The update is atomic: every length-dependent quantity is built from a trial
    ! length vector first, and the committed fields are mutated only once all builds
    ! succeeded.
    BLOCK
      REAL(wp) :: l0_trial(SIZE(model%l0)), f_dist(SIZE(model%f_ext))
      REAL(wp), ALLOCATABLE :: kn_new(:)
      l0_trial = model%l0
      l0_trial(elem) = l0_new
      ! Distributed external load tracks the length: REASSEMBLE the distributed part
      ! from the current lengths onto the stored non-distributed remainder --
      ! bit-identical to a fresh build with the new length (a nodal delta is not,
      ! in floating point).
      IF (ALLOCATED(model%dist_load)) THEN
        CALL CD_Assemble_Distributed_Load(model%elem_conn, l0_trial, model%dist_load, f_dist, es, em)
        IF (es /= 0) THEN
          CALL fail(ErrStat, ErrMsg, 'segment-length update: distributed-load reassembly failed: '//TRIM(em))
          RETURN
        END IF
        ! the external load the new length gives must be finite (an overflowing length
        ! fails here, before anything is written)
        IF (.NOT. CD_All_Finite(model%f_ext_dist_base + f_dist)) THEN
          CALL fail(ErrStat, ErrMsg, 'segment-length update: the external load at the new length is not finite')
          RETURN
        END IF
      END IF
      ! Seabed nodal coefficients track the tributary lengths: rebuild through the
      ! SAME helper the deck used, so a fresh build at the new length matches
      ! bit-for-bit; cn follows via the stored ratio.
      IF (model%has_seabed .AND. model%has_seabed_recompute) THEN
        CALL CD_Nodal_Seabed_Stiffness(model%seabed_kbot, model%seabed_diameter_elem, l0_trial, &
                                       kn_new, es, em)
        IF (es /= 0) THEN
          CALL fail(ErrStat, ErrMsg, 'segment-length update: seabed stiffness recompute failed: '//TRIM(em))
          RETURN
        END IF
        IF (.NOT. CD_All_Finite(kn_new*model%seabed_cn_over_kn)) THEN
          CALL fail(ErrStat, ErrMsg, 'segment-length update: the seabed coefficients at the new length are not finite')
          RETURN
        END IF
      END IF
      ! Commit. The consistent mass follows l0 implicitly (it is applied element by
      ! element from the present lengths, and the step rebuilds its mass band when they change).
      model%l0(elem) = l0_new
      model%l0_dot(elem) = rate
      IF (ALLOCATED(model%dist_load)) model%f_ext = model%f_ext_dist_base + f_dist
      IF (model%has_seabed .AND. model%has_seabed_recompute) THEN
        CALL MOVE_ALLOC(kn_new, model%seabed_kn)
        IF (ALLOCATED(model%seabed_cn)) model%seabed_cn = model%seabed_kn*model%seabed_cn_over_kn
      END IF
      ! The committed acceleration is kept: it is the history of the step that reached the
      ! committed state, at the lengths of that step (re-deriving it under the new length
      ! would carry the force of the length change into the next step's alpha_m blend).
      IF (PRESENT(restored)) THEN
        IF (restored) THEN
          model%l0_c(elem) = l0_new
          model%l0_dot_c(elem) = rate
        END IF
      END IF
    END BLOCK
  END SUBROUTINE CD_Update_Model_SegmentLength

  SUBROUTINE CD_Save_Model_Control(model, saved)
    !! Save what CD_Update_Model_SegmentLength writes (the lengths and rates, the committed
    !! lengths and rates, the external load and the seabed coefficients), so that a caller
    !! applying one command to several lines can take back the ones it already changed when
    !! a later one fails (CD_Restore_Model_Control).
    TYPE(CD_ModelType), INTENT(IN) :: model
    TYPE(CD_ModelControlSaveType), INTENT(INOUT) :: saved
    saved%valid = model%initialized
    IF (.NOT. saved%valid) RETURN
    saved%l0 = model%l0
    saved%l0_dot = model%l0_dot
    saved%l0_c = model%l0_c
    saved%l0_dot_c = model%l0_dot_c
    saved%f_ext = model%f_ext
    IF (ALLOCATED(model%seabed_kn)) THEN
      saved%seabed_kn = model%seabed_kn
    ELSE IF (ALLOCATED(saved%seabed_kn)) THEN
      DEALLOCATE (saved%seabed_kn)
    END IF
    IF (ALLOCATED(model%seabed_cn)) THEN
      saved%seabed_cn = model%seabed_cn
    ELSE IF (ALLOCATED(saved%seabed_cn)) THEN
      DEALLOCATE (saved%seabed_cn)
    END IF
  END SUBROUTINE CD_Save_Model_Control

  SUBROUTINE CD_Restore_Model_Control(model, saved, ErrStat, ErrMsg)
    !! Put back, bit for bit, what CD_Save_Model_Control saved. Fails closed, writing nothing,
    !! when the save does not belong to the model.
    TYPE(CD_ModelType), INTENT(INOUT) :: model
    TYPE(CD_ModelControlSaveType), INTENT(IN) :: saved
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    ErrStat = CD_MODEL_OK
    ErrMsg = ''
    IF (.NOT. (model%initialized .AND. saved%valid)) THEN
      CALL fail(ErrStat, ErrMsg, 'control restore: no saved control state')
      RETURN
    END IF
    IF (SIZE(saved%l0) /= SIZE(model%l0) .OR. SIZE(saved%f_ext) /= SIZE(model%f_ext) .OR. &
        (ALLOCATED(saved%seabed_kn) .NEQV. ALLOCATED(model%seabed_kn)) .OR. &
        (ALLOCATED(saved%seabed_cn) .NEQV. ALLOCATED(model%seabed_cn))) THEN
      CALL fail(ErrStat, ErrMsg, 'control restore: the saved state belongs to another model')
      RETURN
    END IF
    model%l0 = saved%l0
    model%l0_dot = saved%l0_dot
    model%l0_c = saved%l0_c
    model%l0_dot_c = saved%l0_dot_c
    model%f_ext = saved%f_ext
    IF (ALLOCATED(saved%seabed_kn)) model%seabed_kn = saved%seabed_kn
    IF (ALLOCATED(saved%seabed_cn)) model%seabed_cn = saved%seabed_cn
  END SUBROUTINE CD_Restore_Model_Control

  SUBROUTINE CD_Get_Model_EndNodeMassDiag(model, coupled_slot, mass_diag, ErrStat, ErrMsg)
    !! The coupled end node's OWN diagonal share of the consistent structural mass:
    !! sum over elements attached to that node of rho_a*l0/3 (the 2m/6 block diagonal
    !! of CD_Assemble_Cable_Mass). This is the piece of the end-node inertia a point
    !! integrator can treat IMPLICITLY (added to the point's effective mass, with its
    !! lagged product removed from the coupled-loads reaction) so a light or massless
    !! point with attached lines integrates stably; the m/6 neighbour cross term stays
    !! in the lagged reaction. coupled_slot selects the endpoint triple in the model's
    !! compact coupled ordering (1 = fixed_dofs(1:3), 2 = fixed_dofs(4:6)), matching
    !! CD_LINE_END_A/B in the system point map.
    TYPE(CD_ModelType), INTENT(IN) :: model
    INTEGER, INTENT(IN) :: coupled_slot
    REAL(wp), INTENT(OUT) :: mass_diag
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    INTEGER :: e, node, d0
    mass_diag = CD_ZERO
    ErrStat = CD_MODEL_OK
    ErrMsg = ''
    IF (.NOT. model%initialized) THEN
      ErrStat = CD_MODEL_NOT_INITIALIZED
      ErrMsg = 'CableDyn_Model: model is not initialized'
      RETURN
    END IF
    IF (coupled_slot /= 1 .AND. coupled_slot /= 2) THEN
      CALL fail(ErrStat, ErrMsg, 'coupled_slot must be 1 (end A triple) or 2 (end B triple)')
      RETURN
    END IF
    IF (SIZE(model%fixed_dofs) < 3*coupled_slot) THEN
      CALL fail(ErrStat, ErrMsg, 'model does not expose the requested coupled endpoint triple')
      RETURN
    END IF
    d0 = model%fixed_dofs(3*coupled_slot - 2)
    IF (MOD(d0 - 1, 3) /= 0 .OR. &
        model%fixed_dofs(3*coupled_slot - 1) /= d0 + 1 .OR. &
        model%fixed_dofs(3*coupled_slot) /= d0 + 2) THEN
      CALL fail(ErrStat, ErrMsg, 'the requested coupled slot is not a contiguous per-node triple')
      RETURN
    END IF
    node = (d0 + 2)/3
    DO e = 1, SIZE(model%elem_conn, 2)
      IF (model%elem_conn(1, e) == node .OR. model%elem_conn(2, e) == node) THEN
        mass_diag = mass_diag + model%rho_a(e)*model%l0(e)/3.0_wp
      END IF
    END DO
  END SUBROUTINE CD_Get_Model_EndNodeMassDiag

  SUBROUTINE CD_Get_Model_EndNodeAddedMass(model, coupled_slot, ma_block, ErrStat, ErrMsg)
    !! The coupled end node's OWN 3x3 block of the configuration-dependent Morison
    !! added-mass matrix at the current model%q: the sum over elements attached to
    !! that node of the node's self block of CD_Added_Mass_Element_Matrix (the same
    !! element matrix, wetted fraction and orientation whose product M_add(q)*a enters
    !! CD_Calc_Model_CoupledLoads). A point integrator moves this block into its
    !! implicit mass together with the structural diagonal, cancelling the lagged
    !! product it carries in the coupled-loads reaction. Zero when the model has no
    !! added mass. coupled_slot follows CD_Get_Model_EndNodeMassDiag.
    TYPE(CD_ModelType), INTENT(IN) :: model
    INTEGER, INTENT(IN) :: coupled_slot
    REAL(wp), INTENT(OUT) :: ma_block(3, 3)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    INTEGER :: e, node, d0, idx(6), es
    REAL(wp) :: q2(6), wl2(2), m2(6, 6)
    CHARACTER(1024) :: em
    ma_block = CD_ZERO
    ErrStat = CD_MODEL_OK
    ErrMsg = ''
    IF (.NOT. model%initialized) THEN
      ErrStat = CD_MODEL_NOT_INITIALIZED
      ErrMsg = 'CableDyn_Model: model is not initialized'
      RETURN
    END IF
    IF (coupled_slot /= 1 .AND. coupled_slot /= 2) THEN
      CALL fail(ErrStat, ErrMsg, 'coupled_slot must be 1 (end A triple) or 2 (end B triple)')
      RETURN
    END IF
    IF (SIZE(model%fixed_dofs) < 3*coupled_slot) THEN
      CALL fail(ErrStat, ErrMsg, 'model does not expose the requested coupled endpoint triple')
      RETURN
    END IF
    d0 = model%fixed_dofs(3*coupled_slot - 2)
    IF (MOD(d0 - 1, 3) /= 0 .OR. &
        model%fixed_dofs(3*coupled_slot - 1) /= d0 + 1 .OR. &
        model%fixed_dofs(3*coupled_slot) /= d0 + 2) THEN
      CALL fail(ErrStat, ErrMsg, 'the requested coupled slot is not a contiguous per-node triple')
      RETURN
    END IF
    IF (.NOT. model%has_added_mass) RETURN
    node = (d0 + 2)/3
    DO e = 1, model%n_elem
      IF (model%elem_conn(1, e) /= node .AND. model%elem_conn(2, e) /= node) CYCLE
      CALL extract_element_positions(model, e, model%q, idx, q2)
      CALL extract_nodal_scalar(model%added_mass_waterline_z, model, e, wl2)
      CALL CD_Added_Mass_Element_Matrix(q2(1:3), q2(4:6), model%l0(e), wl2(1), wl2(2), &
                                        model%added_mass_rho, model%added_mass_diameter_elem(e), &
                                        model%added_mass_can_elem(e), model%added_mass_cat_elem(e), &
                                        m2, es, em)
      IF (es /= 0) THEN
        ErrStat = CD_MODEL_SOLVEFAIL
        ErrMsg = 'CableDyn_Model: end-node added-mass block failed: '//TRIM(em)
        ma_block = CD_ZERO
        RETURN
      END IF
      ! An element never joins a node to itself, so each attached element
      ! contributes exactly one of its two nodal self blocks.
      IF (model%elem_conn(1, e) == node) THEN
        ma_block = ma_block + m2(1:3, 1:3)
      ELSE
        ma_block = ma_block + m2(4:6, 4:6)
      END IF
    END DO
    IF (.NOT. CD_All_Finite(ma_block)) THEN
      CALL fail(ErrStat, ErrMsg, 'end-node added-mass block is non-finite')
      ma_block = CD_ZERO
    END IF
  END SUBROUTINE CD_Get_Model_EndNodeAddedMass

  SUBROUTINE CD_Set_Model_EndQuery(model, request, active, arm_guess, refresh, levels, level_dofs)
    !! Arm (request = .TRUE.) or disarm the junction query of the next CD_Step_Model: a
    !! converged step then leaves the alpha-level reaction rows of its fixed DOFs and the
    !! condensed dynamic end tangent (CD_Get_Model_EndQuery). active (one flag per fixed DOF,
    !! in model%fixed_dofs order) limits the tangent columns to the junction DOFs; arm_guess
    !! warm-starts the step from the previous converged solve of the same step. arm_guess
    !! must be set only for a re-solve of that step from the same committed state (the
    !! line rolled back to it): the warm re-solve also reuses the step-start force and load
    !! of the force blend computed by the previous call.
    TYPE(CD_ModelType), INTENT(INOUT) :: model
    LOGICAL, INTENT(IN) :: request
    LOGICAL, INTENT(IN), OPTIONAL :: active(:)
    LOGICAL, INTENT(IN), OPTIONAL :: arm_guess
    !! refresh = .FALSE. keeps the condensed tangent of an earlier solve when one is valid
    LOGICAL, INTENT(IN), OPTIONAL :: refresh
    !! levels = [beta, gamma, alpha_m] of the objects that drive the fixed DOFs: their Newmark
    !! and inertia level replace the line's at those DOFs (the monolithic junction)
    REAL(wp), INTENT(IN), OPTIONAL :: levels(3)
    !! level_dofs (one flag per fixed DOF, in model%fixed_dofs order): the DOFs that take levels
    !! (all when absent); the others keep the line's own
    LOGICAL, INTENT(IN), OPTIONAL :: level_dofs(:)
    model%dynamic_workspace%end_request = request
    model%dynamic_workspace%end_levels = PRESENT(levels) .AND. request
    IF (PRESENT(levels)) THEN
      model%dynamic_workspace%end_beta = levels(1)
      model%dynamic_workspace%end_gamma = levels(2)
      model%dynamic_workspace%end_alpham = levels(3)
    END IF
    ! Reuse the array while its size is unchanged (one call per junction iteration).
    IF (PRESENT(level_dofs)) THEN
      IF (ALLOCATED(model%dynamic_workspace%end_level_dofs)) THEN
        IF (SIZE(model%dynamic_workspace%end_level_dofs) /= SIZE(level_dofs)) &
          DEALLOCATE (model%dynamic_workspace%end_level_dofs)
      END IF
      IF (.NOT. ALLOCATED(model%dynamic_workspace%end_level_dofs)) &
        ALLOCATE (model%dynamic_workspace%end_level_dofs(SIZE(level_dofs)))
      model%dynamic_workspace%end_level_dofs = level_dofs
    ELSE IF (ALLOCATED(model%dynamic_workspace%end_level_dofs)) THEN
      DEALLOCATE (model%dynamic_workspace%end_level_dofs)
    END IF
    model%dynamic_workspace%end_refresh = .TRUE.
    IF (PRESENT(refresh)) model%dynamic_workspace%end_refresh = refresh
    model%dynamic_workspace%guess_armed = .FALSE.
    IF (PRESENT(arm_guess)) model%dynamic_workspace%guess_armed = arm_guess .AND. request
    IF (PRESENT(active)) THEN
      IF (ALLOCATED(model%dynamic_workspace%end_active)) THEN
        IF (SIZE(model%dynamic_workspace%end_active) /= SIZE(active)) &
          DEALLOCATE (model%dynamic_workspace%end_active)
      END IF
      IF (.NOT. ALLOCATED(model%dynamic_workspace%end_active)) &
        ALLOCATE (model%dynamic_workspace%end_active(SIZE(active)))
      model%dynamic_workspace%end_active = active
    END IF
  END SUBROUTINE CD_Set_Model_EndQuery

  SUBROUTINE CD_Get_Model_EndQuery(model, reaction, tangent, valid)
    !! The junction query of the last CD_Step_Model (see CD_Set_Model_EndQuery): reaction(j)
    !! is the alpha-level residual row of fixed DOF j (the force the support applies to the
    !! line; the line loads the support with -reaction) and tangent(i, j) = d reaction_i /
    !! d q_{n+1, j} with the free DOFs condensed. valid is false when the last step did not
    !! produce them (not armed, not converged, or a dense-path step).
    TYPE(CD_ModelType), INTENT(IN) :: model
    REAL(wp), INTENT(OUT) :: reaction(:), tangent(:, :)
    LOGICAL, INTENT(OUT) :: valid
    INTEGER :: n
    reaction = CD_ZERO
    tangent = CD_ZERO
    valid = model%dynamic_workspace%end_valid
    IF (.NOT. valid) RETURN
    n = SIZE(model%dynamic_workspace%end_r)
    IF (SIZE(reaction) /= n .OR. SIZE(tangent, 1) /= n .OR. SIZE(tangent, 2) /= n) THEN
      valid = .FALSE.
      RETURN
    END IF
    reaction = model%dynamic_workspace%end_r
    tangent = model%dynamic_workspace%end_k
  END SUBROUTINE CD_Get_Model_EndQuery

  SUBROUTINE CD_Get_Model_EndNodeTangent(model, coupled_slot, k_block, c_block, ErrStat, ErrMsg, kv_neighbour)
    !! The coupled end node's OWN 3x3 stiffness and damping blocks at the current
    !! model%q/v, summed over the elements attached to that node:
    !!   k_block = sum (EA_dyn/l0) t t^T + (max(T, 0)/l) (I - t t^T)   (elastic tangent),
    !!   c_block = sum (BA_dyn/l0) t t^T                             (axial damping).
    !! These are the self blocks of the element tangent and axial-damping Jacobian with
    !! the geometric term clamped to tension, so both blocks are symmetric positive
    !! semi-definite. A point integrator uses them to advance the end-segment spring
    !! and damper linearly implicitly; the reaction itself is still the exact coupled
    !! load, so the blocks only shape the implicit correction. The end node's own seabed
    !! contact is added: the normal penalty tangent to k_block and, while the node moves
    !! down, the normal damping to c_block, so a free line end resting on a stiff seabed
    !! is not limited by the explicit contact frequency. Viscoelastic, Syrope, drag and
    !! seabed friction contributions are not included (they stay in the reaction at the
    !! step-start state). coupled_slot follows CD_Get_Model_EndNodeMassDiag.
    !! kv_neighbour (optional) is sum K_e v_o over the same elements, v_o the velocity of each
    !! element's other node at model%v: the cross-block (-K_e) coupling that carries the
    !! neighbours along with the end node, so an implicit end-node update springs against the
    !! relative motion (v_end - v_o) rather than against neighbours held in place.
    TYPE(CD_ModelType), INTENT(IN) :: model
    INTEGER, INTENT(IN) :: coupled_slot
    REAL(wp), INTENT(OUT) :: k_block(3, 3), c_block(3, 3)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    REAL(wp), INTENT(OUT), OPTIONAL :: kv_neighbour(3)
    INTEGER :: e, node, d0, idx(6), i
    REAL(wp) :: q2(6), chord(3), ell, tang(3), tt(3, 3), strain, material, tension, ke(3, 3), v_other(3)
    REAL(wp) :: z_floor, dfdx, dfdy, gap, fvec(3), jac3(3, 3), damp_force, damp_dgap, damp_dvz, curv_end(3)
    k_block = CD_ZERO
    c_block = CD_ZERO
    IF (PRESENT(kv_neighbour)) kv_neighbour = CD_ZERO
    ErrStat = CD_MODEL_OK
    ErrMsg = ''
    IF (.NOT. model%initialized) THEN
      ErrStat = CD_MODEL_NOT_INITIALIZED
      ErrMsg = 'CableDyn_Model: model is not initialized'
      RETURN
    END IF
    IF (coupled_slot /= 1 .AND. coupled_slot /= 2) THEN
      CALL fail(ErrStat, ErrMsg, 'coupled_slot must be 1 (end A triple) or 2 (end B triple)')
      RETURN
    END IF
    IF (SIZE(model%fixed_dofs) < 3*coupled_slot) THEN
      CALL fail(ErrStat, ErrMsg, 'model does not expose the requested coupled endpoint triple')
      RETURN
    END IF
    d0 = model%fixed_dofs(3*coupled_slot - 2)
    IF (MOD(d0 - 1, 3) /= 0 .OR. &
        model%fixed_dofs(3*coupled_slot - 1) /= d0 + 1 .OR. &
        model%fixed_dofs(3*coupled_slot) /= d0 + 2) THEN
      CALL fail(ErrStat, ErrMsg, 'the requested coupled slot is not a contiguous per-node triple')
      RETURN
    END IF
    node = (d0 + 2)/3
    DO e = 1, model%n_elem
      IF (model%elem_conn(1, e) /= node .AND. model%elem_conn(2, e) /= node) CYCLE
      CALL extract_element_positions(model, e, model%q, idx, q2)
      chord = q2(4:6) - q2(1:3)
      ell = NORM2(chord)
      IF (.NOT. (CD_Is_Finite(ell) .AND. ell > CD_ZERO)) THEN
        CALL fail(ErrStat, ErrMsg, 'end-node tangent: attached element collapsed or non-finite')
        k_block = CD_ZERO
        c_block = CD_ZERO
        RETURN
      END IF
      tang = chord/ell
      DO i = 1, 3
        tt(:, i) = tang*tang(i)
      END DO
      strain = ell/model%l0(e) - CD_ONE
      material = model%ea_dyn(e)/model%l0(e)
      tension = model%ea_dyn(e)*strain
      IF (model%tension_only .AND. strain < CD_ZERO) material = CD_ZERO
      ke = material*tt + (MAX(tension, CD_ZERO)/ell)*(identity3() - tt)
      k_block = k_block + ke
      IF (PRESENT(kv_neighbour)) THEN
        IF (model%elem_conn(1, e) == node) THEN
          v_other = model%v(idx(4:6))
        ELSE
          v_other = model%v(idx(1:3))
        END IF
        kv_neighbour = kv_neighbour + MATMUL(ke, v_other)
      END IF
      IF (model%has_damping) c_block = c_block + (MAX(model%ba_dyn(e), CD_ZERO)/model%l0(e))*tt
    END DO
    IF (model%has_seabed) THEN
      ! the end node's seabed contact (its neighbour is the fixed seabed, so no kv term)
      IF (model%has_bathymetry) THEN
        CALL model_floor_gradient(model, model%q(d0), model%q(d0 + 1), z_floor, dfdx, dfdy, ErrStat, ErrMsg, &
                                  curvature=curv_end)
        IF (ErrStat /= CD_MODEL_OK) THEN
          k_block = CD_ZERO
          c_block = CD_ZERO
          IF (PRESENT(kv_neighbour)) kv_neighbour = CD_ZERO
          RETURN
        END IF
      ELSE
        z_floor = model%seabed_z_floor
        dfdx = CD_ZERO
        dfdy = CD_ZERO
        curv_end = CD_ZERO
      END IF
      gap = z_floor - model%q(d0 + 2)
      CALL CD_Seabed_Normal_Contact(gap, dfdx, dfdy, model%seabed_kn(node), fvec, jac3, curvature=curv_end)
      k_block = k_block + jac3
      IF (model%has_seabed_damping) THEN
        BLOCK
          REAL(wp) :: gap_n, vn, nvec(3)
          LOGICAL :: sloped
          INTEGER :: cb
          CALL node_contact_normal(model, model%q(d0), model%q(d0 + 1), model%q(d0 + 2), model%v(d0:d0 + 2), &
                                   gap_n, vn, nvec, sloped, ErrStat, ErrMsg)
          IF (ErrStat /= CD_MODEL_OK) THEN
            k_block = CD_ZERO
            c_block = CD_ZERO
            IF (PRESENT(kv_neighbour)) kv_neighbour = CD_ZERO
            RETURN
          END IF
          CALL seabed_normal_damping_terms(gap_n, vn, model%seabed_cn(node), damp_force, damp_dgap, damp_dvz)
          IF (sloped) THEN
            DO cb = 1, 3
              c_block(:, cb) = c_block(:, cb) - damp_dvz*nvec*nvec(cb)
            END DO
          ELSE
            c_block(3, 3) = c_block(3, 3) - damp_dvz
          END IF
        END BLOCK
      END IF
    END IF
    IF (PRESENT(kv_neighbour)) THEN
      IF (.NOT. CD_All_Finite(kv_neighbour)) THEN
        CALL fail(ErrStat, ErrMsg, 'end-node neighbour coupling is non-finite')
        k_block = CD_ZERO
        c_block = CD_ZERO
        kv_neighbour = CD_ZERO
        RETURN
      END IF
    END IF
    IF (.NOT. (CD_All_Finite(k_block) .AND. CD_All_Finite(c_block))) THEN
      CALL fail(ErrStat, ErrMsg, 'end-node tangent blocks are non-finite')
      k_block = CD_ZERO
      c_block = CD_ZERO
      IF (PRESENT(kv_neighbour)) kv_neighbour = CD_ZERO
    END IF
  CONTAINS
    PURE FUNCTION identity3() RESULT(eye)
      REAL(wp) :: eye(3, 3)
      INTEGER :: j
      eye = CD_ZERO
      DO j = 1, 3
        eye(j, j) = CD_ONE
      END DO
    END FUNCTION identity3
  END SUBROUTINE CD_Get_Model_EndNodeTangent

  SUBROUTINE CD_Get_Model_EndForces(model, force_first, force_last, ErrStat, ErrMsg)
    !! Force the line exerts on the points holding its first and last node at the
    !! committed state (q, v): the end element's internal force (elastic, axial damping and
    !! any constitutive contributor) plus the end node's lumped external loads (submerged
    !! weight, buoyancy, seabed contact with its damping and friction, drag at the actual
    !! relative velocity, Froude-Krylov), i.e. f_ext + contributors - f_int at the node.
    !! This is the actual force on the attachment, as MoorDyn and OrcaFlex report the end
    !! tension; it equals the coupled load of the node (CD_Calc_Model_CoupledLoads) less the
    !! end node's structural and added-mass inertia. At rest it is the static initializer's
    !! end force. Its norm is the FairTen/AnchTen channel value.
    TYPE(CD_ModelType), INTENT(IN) :: model
    REAL(wp), INTENT(OUT) :: force_first(3), force_last(3)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg

    REAL(wp) :: load(9)
    REAL(wp) :: fint_first(3), fint_last(3), nodes6(6), Kt6(6, 6), fint6(6), Te
    INTEGER :: es, n, nn, e, a, b
    CHARACTER(1024) :: em

    force_first = CD_ZERO
    force_last = CD_ZERO
    ErrStat = CD_MODEL_OK
    ErrMsg = ''
    IF (.NOT. model%initialized) THEN
      ErrStat = CD_MODEL_NOT_INITIALIZED
      ErrMsg = 'CableDyn_Model: model is not initialized'
      RETURN
    END IF
    n = model%n_dof
    nn = n/3
    ! Only the two end nodes are read, so only the elements that touch them are evaluated.
    ! Each end-node sum takes its terms in the element order of the whole-line assembly,
    ! so the result is bit-identical to assembling the full internal and load vectors.
    fint_first = CD_ZERO
    fint_last = CD_ZERO
    DO e = 1, model%n_elem
      a = model%elem_conn(1, e)
      b = model%elem_conn(2, e)
      IF (a /= 1 .AND. a /= nn .AND. b /= 1 .AND. b /= nn) CYCLE
      nodes6(1:3) = model%q(3*a - 2:3*a)
      nodes6(4:6) = model%q(3*b - 2:3*b)
      CALL CD_Compute_Cable_Element(nodes6, model%ea_dyn(e), model%l0(e), model%tension_only, Kt6, fint6, &
                                    Te, es, em)
      IF (es /= 0) THEN
        ErrStat = CD_MODEL_SOLVEFAIL
        ErrMsg = 'CableDyn_Model: internal-force assembly failed during end-force recovery: '// &
                 'CD_Assemble_Cable_Internal_Force: element '//TRIM(em)
        RETURN
      END IF
      IF (a == 1) fint_first = fint_first + fint6(1:3)
      IF (b == 1) fint_first = fint_first + fint6(4:6)
      IF (a == nn) fint_last = fint_last + fint6(1:3)
      IF (b == nn) fint_last = fint_last + fint6(4:6)
    END DO
    ! compact end-node load [first node, last node, other reached nodes]: no heap scratch
    CALL model_contributor_force(model, model%q, model%v, load, es, em, end_nodes_only=.TRUE.)
    IF (es /= 0) THEN
      ErrStat = CD_MODEL_SOLVEFAIL
      ErrMsg = 'CableDyn_Model: load assembly failed during end-force recovery: '//TRIM(em)
      RETURN
    END IF
    force_first = model%f_ext(1:3) + load(1:3) - fint_first
    force_last = model%f_ext(n - 2:n) + load(4:6) - fint_last
  END SUBROUTINE CD_Get_Model_EndForces

  SUBROUTINE CD_Get_Model_Tension(model, tension, ErrStat, ErrMsg)
    !! Recover current element axial tension from the model state.
    TYPE(CD_ModelType), INTENT(IN) :: model
    REAL(wp), INTENT(OUT) :: tension(:)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg

    INTEGER :: es
    CHARACTER(1024) :: em

    tension = CD_ZERO
    ErrStat = CD_MODEL_OK
    ErrMsg = ''
    IF (.NOT. model%initialized) THEN
      ErrStat = CD_MODEL_NOT_INITIALIZED
      ErrMsg = 'CableDyn_Model: model is not initialized'
      RETURN
    END IF
    IF (SIZE(tension) /= model%n_elem) THEN
      CALL fail(ErrStat, ErrMsg, 'tension output must have shape (n_elem)')
      RETURN
    END IF
    CALL CD_Compute_Cable_Tension(RESHAPE(model%q, [3, model%n_dof/3]), model%elem_conn, model%l0, model%ea, &
                                  model%tension_only, tension, es, em, topology_validated=.TRUE.)
    IF (es /= 0) THEN
      ErrStat = CD_MODEL_SOLVEFAIL
      ErrMsg = 'CableDyn_Model: tension recovery failed: '//TRIM(em)
      RETURN
    END IF
    IF (model%has_damping) THEN
      ! The axial Kelvin-Voigt share BA*(strain rate) is part of the reported tension, as it
      ! is of the end forces (CD_Get_Model_EndForces): the same element law, projected on the
      ! chord. It also acts on a slack element. Viscoelastic and Syrope elements have
      ! ba_dyn = 0 here and report their own rate terms below.
      BLOCK
        INTEGER :: e, na, nb
        REAL(wp) :: f2(6), chord(3), clen
        DO e = 1, model%n_elem
          IF (.NOT. (model%ba_dyn(e) > CD_ZERO)) CYCLE
          na = model%elem_conn(1, e)
          nb = model%elem_conn(2, e)
          CALL CD_Axial_Damping_Element_Force(model%q(3*na - 2:3*na), model%q(3*nb - 2:3*nb), &
                                              model%v(3*na - 2:3*na), model%v(3*nb - 2:3*nb), &
                                              model%l0(e), model%ba_dyn(e), f2, es, em, &
                                              l0_dot=model%l0_dot(e))
          IF (es /= 0) THEN
            ErrStat = CD_MODEL_SOLVEFAIL
            ErrMsg = 'CableDyn_Model: axial damping tension recovery failed: '//TRIM(em)
            RETURN
          END IF
          chord = model%q(3*nb - 2:3*nb) - model%q(3*na - 2:3*na)
          clen = NORM2(chord)
          tension(e) = tension(e) + DOT_PRODUCT(f2(1:3), chord/clen)
        END DO
      END BLOCK
    END IF
    ! the viscoelastic and Syrope elements report their own law's tension
    CALL model_law_tensions(model, tension, ErrStat, ErrMsg)
  END SUBROUTINE CD_Get_Model_Tension

  SUBROUTINE CD_Get_Model_Internal_Rates(model, ve_rate, syrope_rate, ErrStat, ErrMsg)
    !! The rates of the per-element constitutive states at the model's current q, v and states,
    !! as the instantaneous (dt = 0) element loads evaluate them: the viscoelastic slow-branch
    !! stretch d(dl_1)/dt (its taut ODE, or the zero-load relaxation of a slack element) and the
    !! Syrope slow strain d(eps_slow)/dt; zero on the other elements.
    TYPE(CD_ModelType), INTENT(IN) :: model
    REAL(wp), INTENT(OUT) :: ve_rate(:), syrope_rate(:)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg

    INTEGER :: e, idx(6), es
    REAL(wp) :: q2(6), v2(6), chord(3), tang(3), length, lstrd, dl, bsum, ld1, ea_d_eff, ea_1_eff
    REAL(wp) :: ws(CD_SYROPE_NWC), wt(CD_SYROPE_NWC), wsl(CD_SYROPE_NWC), f6(6), jq6(6, 6), t_mean, dslow
    REAL(wp) :: slow_at
    CHARACTER(200) :: em

    ve_rate = CD_ZERO
    syrope_rate = CD_ZERO
    ErrStat = CD_MODEL_OK
    ErrMsg = ''
    IF (.NOT. model%initialized) THEN
      ErrStat = CD_MODEL_NOT_INITIALIZED
      ErrMsg = 'CableDyn_Model: model is not initialized'
      RETURN
    END IF
    IF (SIZE(ve_rate) /= model%n_elem .OR. SIZE(syrope_rate) /= model%n_elem) THEN
      CALL fail(ErrStat, ErrMsg, 'internal-rate outputs must have shape (n_elem)')
      RETURN
    END IF
    IF (model%has_viscoelastic) THEN
      DO e = 1, model%n_elem
        IF (model%ve_mode(e) == 0) CYCLE
        CALL model_viscoelastic_coeffs(model, e, ea_d_eff, ea_1_eff, ErrStat, ErrMsg)
        IF (ErrStat /= CD_MODEL_OK) RETURN
        CALL extract_element_state(model, e, model%q, model%v, idx, q2, v2)
        chord = q2(4:6) - q2(1:3)
        length = NORM2(chord)
        IF (length <= CD_VISCO_TINY_LEN) THEN
          CALL fail(ErrStat, ErrMsg, 'viscoelastic element collapsed to zero length')
          RETURN
        END IF
        tang = chord/length
        lstrd = DOT_PRODUCT(tang, v2(4:6) - v2(1:3))
        dl = length - model%l0(e)
        bsum = model%ve_ba_d(e) + model%ve_ba(e)
        ! the taut series-Kelvin ODE; a slack chain (tension max(MagT + MagTd, 0) = 0)
        ! relaxes under zero load, BA*ld_1 + EA_1*dl_1 = 0, as the element load's switch
        ld1 = (ea_d_eff*dl - (ea_d_eff + ea_1_eff)*model%ve_dl_1(e) + model%ve_ba_d(e)*lstrd)/bsum
        IF (ea_1_eff*model%ve_dl_1(e)/model%l0(e) + model%ve_ba(e)*ld1/model%l0(e) < CD_ZERO) THEN
          ld1 = CD_ZERO
          IF (model%ve_ba(e) > CD_ZERO) ld1 = -ea_1_eff*model%ve_dl_1(e)/model%ve_ba(e)
        END IF
        ve_rate(e) = ld1
      END DO
    END IF
    IF (model%has_syrope) THEN
      DO e = 1, model%n_elem
        IF (.NOT. model%syrope_is(e)) CYCLE
        CALL extract_element_state(model, e, model%q, model%v, idx, q2, v2)
        CALL CD_Syrope_Working_Curve(model%syrope_type(e), model%syrope_tmax(e), ws, wt, wsl, es, em)
        IF (es /= CD_SYROPE_OK) THEN
          CALL fail(ErrStat, ErrMsg, TRIM(em)); RETURN
        END IF
        slow_at = CD_Syrope_Branch_Divider(model%syrope_type(e), model%syrope_tmax(e))
        CALL CD_Syrope_Element_Load(q2(1:3), q2(4:6), v2(1:3), v2(4:6), model%l0(e), model%syrope_type(e), &
                                    ws, wt, wsl, model_syrope_slow(model, e) < slow_at, &
                                    model_syrope_slow(model, e), model%tension_only, f6, jq6, t_mean, dslow, &
                                    es, em, dt=CD_ZERO, divider=slow_at)
        IF (es /= CD_SYROPE_OK) THEN
          CALL fail(ErrStat, ErrMsg, TRIM(em)); RETURN
        END IF
        syrope_rate(e) = dslow
      END DO
    END IF
  END SUBROUTINE CD_Get_Model_Internal_Rates

  SUBROUTINE model_law_tensions(model, tension, ErrStat, ErrMsg)
    !! Overwrite the entries of the viscoelastic and Syrope elements of tension (n_elem) with
    !! their law's tension at the committed state (CD_Get_Model_Tension); the other entries
    !! are left as they are.
    TYPE(CD_ModelType), INTENT(IN) :: model
    REAL(wp), INTENT(INOUT) :: tension(:)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    INTEGER :: es
    CHARACTER(KERNEL_MSG_LEN) :: em ! a per-element law message (the kernels' bound)

    ErrStat = CD_MODEL_OK
    ErrMsg = ''
    IF (model%has_viscoelastic) THEN
      ! viscoelastic elements report the series-Kelvin tension MagT + MagTd at the
      ! COMMITTED state and dl_1 (the elastic EA recovery of CD_Get_Model_Tension does not
      ! apply to them -- their dynamic elastic stiffness lives in the state)
      BLOCK
        INTEGER :: e, na, nb
        REAL(wp) :: ea_d_eff, ea_1_eff
        DO e = 1, model%n_elem
          IF (model%ve_mode(e) == 0) CYCLE
          CALL model_viscoelastic_coeffs(model, e, ea_d_eff, ea_1_eff, es, em)
          IF (es /= CD_MODEL_OK) THEN
            ErrStat = es
            ErrMsg = em
            RETURN
          END IF
          na = model%elem_conn(1, e)
          nb = model%elem_conn(2, e)
          CALL CD_Viscoelastic_Element_Tension(model%q(3*na - 2:3*na), model%q(3*nb - 2:3*nb), &
                                               model%v(3*na - 2:3*na), model%v(3*nb - 2:3*nb), &
                                               model%l0(e), ea_d_eff, ea_1_eff, &
                                               model%ve_ba(e), model%ve_ba_d(e), model%ve_dl_1(e), &
                                               tension(e), es, em)
          IF (es /= CD_VISCO_OK) THEN
            ErrStat = CD_MODEL_SOLVEFAIL
            ErrMsg = 'CableDyn_Model: viscoelastic tension recovery failed: '//TRIM(em)
            RETURN
          END IF
        END DO
      END BLOCK
    END IF
    IF (model%has_syrope) THEN
      ! Syrope elements report the working-curve tension at the COMMITTED state
      ! (the along-tangent component of the element force; the elastic EA recovery of
      ! CD_Get_Model_Tension does not apply -- their stiffness lives in the states)
      BLOCK
        INTEGER :: e, idx_scr(6)
        REAL(wp) :: q2b(6), v2b(6), f6(6), j6(6, 6), jv6(6, 6), tmean, dslow, chord(3)
        DO e = 1, model%n_elem
          IF (.NOT. model%syrope_is(e)) CYCLE
          CALL extract_element_state(model, e, model%q, model%v, idx_scr, q2b, v2b)
          CALL model_syrope_element(model, e, q2b, v2b, f6, j6, jv6, tmean, dslow, es, em)
          IF (es /= CD_MODEL_OK) THEN
            ErrStat = es
            ErrMsg = em
            RETURN
          END IF
          chord = q2b(4:6) - q2b(1:3)
          tension(e) = DOT_PRODUCT(f6(1:3), chord/NORM2(chord))
        END DO
      END BLOCK
    END IF
  END SUBROUTINE model_law_tensions

  SUBROUTINE CD_Update_Model_Hydro_Fields(model, ErrStat, ErrMsg, fluid_velocity, drag_waterline_z, &
                                          fluid_acceleration, fk_waterline_z, added_mass_waterline_z, &
                                          buoyancy_waterline_z, fields_changed)
    !! Refresh nodal environmental fields owned by an initialized model. This is
    !! the small time-varying hydro boundary used by the deck drivers and
    !! OpenFAST shells: coefficients are fixed at initialization, while current,
    !! wave acceleration, free surface, and wetting fields can change every step.
    !! This routine does not recompute acceleration. Inside a time march the
    !! committed acceleration is the generalized-alpha ALGORITHMIC acceleration and
    !! must be preserved: replacing it with the equilibrium acceleration implied by
    !! the new fields destroys the scheme's high-frequency dissipation. Only an
    !! initial-condition station (before the first step) should follow a changed
    !! field with CD_Recompute_Model_Acceleration; fields_changed reports whether any
    !! supplied field differs from the stored one, so an unchanged (e.g. zero) field
    !! leaves the model bit-identical to one that was never refreshed.
    TYPE(CD_ModelType), INTENT(INOUT) :: model
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    REAL(wp), INTENT(IN), OPTIONAL :: fluid_velocity(:, :)
    REAL(wp), INTENT(IN), OPTIONAL :: drag_waterline_z(:)
    REAL(wp), INTENT(IN), OPTIONAL :: fluid_acceleration(:, :)
    REAL(wp), INTENT(IN), OPTIONAL :: fk_waterline_z(:)
    REAL(wp), INTENT(IN), OPTIONAL :: added_mass_waterline_z(:)
    REAL(wp), INTENT(IN), OPTIONAL :: buoyancy_waterline_z(:)
    LOGICAL, INTENT(OUT), OPTIONAL :: fields_changed

    INTEGER :: n_nodes
    LOGICAL :: changed

    ErrStat = CD_MODEL_OK
    ErrMsg = ''
    IF (PRESENT(fields_changed)) fields_changed = .FALSE.
    IF (.NOT. model%initialized) THEN
      ErrStat = CD_MODEL_NOT_INITIALIZED
      ErrMsg = 'CableDyn_Model: model is not initialized'
      RETURN
    END IF
    n_nodes = model%n_dof/3
    IF (PRESENT(fluid_velocity)) THEN
      IF (.NOT. model%has_morison_drag) THEN
        CALL fail(ErrStat, ErrMsg, 'fluid_velocity update requires Morison drag configured at initialization')
        RETURN
      END IF
      IF (SIZE(fluid_velocity, 1) /= 3 .OR. SIZE(fluid_velocity, 2) /= n_nodes) THEN
        CALL fail(ErrStat, ErrMsg, 'fluid_velocity update must have shape (3, n_nodes)')
        RETURN
      END IF
      IF (.NOT. CD_All_Finite(fluid_velocity)) THEN
        CALL fail(ErrStat, ErrMsg, 'fluid_velocity update must be finite')
        RETURN
      END IF
    END IF
    IF (PRESENT(drag_waterline_z)) THEN
      IF (.NOT. model%has_morison_drag) THEN
        CALL fail(ErrStat, ErrMsg, 'drag_waterline_z update requires Morison drag configured at initialization')
        RETURN
      END IF
      CALL validate_vector_field(drag_waterline_z, n_nodes, 'drag_waterline_z', ErrStat, ErrMsg)
      IF (ErrStat /= CD_MODEL_OK) RETURN
    END IF
    IF (PRESENT(fluid_acceleration)) THEN
      IF (.NOT. model%has_froude_krylov) THEN
        CALL fail(ErrStat, ErrMsg, 'fluid_acceleration update requires Froude-Krylov configured at initialization')
        RETURN
      END IF
      IF (SIZE(fluid_acceleration, 1) /= 3 .OR. SIZE(fluid_acceleration, 2) /= n_nodes) THEN
        CALL fail(ErrStat, ErrMsg, 'fluid_acceleration update must have shape (3, n_nodes)')
        RETURN
      END IF
      IF (.NOT. CD_All_Finite(fluid_acceleration)) THEN
        CALL fail(ErrStat, ErrMsg, 'fluid_acceleration update must be finite')
        RETURN
      END IF
    END IF
    IF (PRESENT(fk_waterline_z)) THEN
      IF (.NOT. model%has_froude_krylov) THEN
        CALL fail(ErrStat, ErrMsg, 'fk_waterline_z update requires Froude-Krylov configured at initialization')
        RETURN
      END IF
      CALL validate_vector_field(fk_waterline_z, n_nodes, 'fk_waterline_z', ErrStat, ErrMsg)
      IF (ErrStat /= CD_MODEL_OK) RETURN
    END IF
    IF (PRESENT(added_mass_waterline_z)) THEN
      IF (.NOT. model%has_added_mass) THEN
        CALL fail(ErrStat, ErrMsg, 'added_mass_waterline_z update requires added mass configured at initialization')
        RETURN
      END IF
      CALL validate_vector_field(added_mass_waterline_z, n_nodes, 'added_mass_waterline_z', ErrStat, ErrMsg)
      IF (ErrStat /= CD_MODEL_OK) RETURN
    END IF
    IF (PRESENT(buoyancy_waterline_z)) THEN
      IF (.NOT. model%has_buoyancy_recovery) THEN
        CALL fail(ErrStat, ErrMsg, &
                  'buoyancy_waterline_z update requires buoyancy recovery configured at initialization')
        RETURN
      END IF
      CALL validate_vector_field(buoyancy_waterline_z, n_nodes, 'buoyancy_waterline_z', ErrStat, ErrMsg)
    END IF
    IF (ErrStat /= CD_MODEL_OK) RETURN

    IF (PRESENT(fields_changed)) THEN
      changed = .FALSE.
      IF (PRESENT(fluid_velocity)) changed = changed .OR. field2_differs(model%fluid_velocity, fluid_velocity)
      IF (PRESENT(drag_waterline_z)) changed = changed .OR. field1_differs(model%drag_waterline_z, drag_waterline_z)
      IF (PRESENT(fluid_acceleration)) &
        changed = changed .OR. field2_differs(model%fluid_acceleration, fluid_acceleration)
      IF (PRESENT(fk_waterline_z)) changed = changed .OR. field1_differs(model%fk_waterline_z, fk_waterline_z)
      IF (PRESENT(added_mass_waterline_z)) &
        changed = changed .OR. field1_differs(model%added_mass_waterline_z, added_mass_waterline_z)
      IF (PRESENT(buoyancy_waterline_z)) &
        changed = changed .OR. field1_differs(model%buoyancy_waterline_z, buoyancy_waterline_z)
      fields_changed = changed
    END IF
    IF (PRESENT(fluid_velocity)) model%fluid_velocity = fluid_velocity
    IF (PRESENT(drag_waterline_z)) model%drag_waterline_z = drag_waterline_z
    IF (PRESENT(fluid_acceleration)) model%fluid_acceleration = fluid_acceleration
    IF (PRESENT(fk_waterline_z)) model%fk_waterline_z = fk_waterline_z
    IF (PRESENT(added_mass_waterline_z)) THEN
      ! The added mass of a partially wet element depends on the waterline: a moved one
      ! invalidates the cached acceleration derivative (keyed on q, l0, rho_a, fixed DOFs).
      IF (field1_differs(model%added_mass_waterline_z, added_mass_waterline_z)) &
        model%dynamic_workspace%ad_valid = .FALSE.
      model%added_mass_waterline_z = added_mass_waterline_z
    END IF
    IF (PRESENT(buoyancy_waterline_z)) model%buoyancy_waterline_z = buoyancy_waterline_z

  CONTAINS

    LOGICAL FUNCTION field1_differs(stored, new) RESULT(differs)
      !! An unallocated or differently shaped store counts as a change.
      REAL(wp), ALLOCATABLE, INTENT(IN) :: stored(:)
      REAL(wp), INTENT(IN) :: new(:)
      differs = .TRUE.
      IF (.NOT. ALLOCATED(stored)) RETURN
      IF (SIZE(stored) /= SIZE(new)) RETURN
      differs = ANY(ABS(stored - new) > CD_ZERO)
    END FUNCTION field1_differs

    LOGICAL FUNCTION field2_differs(stored, new) RESULT(differs)
      REAL(wp), ALLOCATABLE, INTENT(IN) :: stored(:, :)
      REAL(wp), INTENT(IN) :: new(:, :)
      differs = .TRUE.
      IF (.NOT. ALLOCATED(stored)) RETURN
      IF (SIZE(stored, 1) /= SIZE(new, 1) .OR. SIZE(stored, 2) /= SIZE(new, 2)) RETURN
      differs = ANY(ABS(stored - new) > CD_ZERO)
    END FUNCTION field2_differs
  END SUBROUTINE CD_Update_Model_Hydro_Fields

  SUBROUTINE CD_Update_Model_External_Loads(model, f_ext, ErrStat, ErrMsg)
    !! Replace the model-owned nodal external force vector. The update is consumed
    !! by subsequent coupled-load extraction and dynamic steps. The current
    !! acceleration is recomputed before return so direct load queries see a
    !! state consistent with the updated external force vector.
    TYPE(CD_ModelType), INTENT(INOUT) :: model
    REAL(wp), INTENT(IN) :: f_ext(:)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg

    ErrStat = CD_MODEL_OK
    ErrMsg = ''
    IF (.NOT. model%initialized) THEN
      ErrStat = CD_MODEL_NOT_INITIALIZED
      ErrMsg = 'CableDyn_Model: model is not initialized'
      RETURN
    END IF
    IF (SIZE(f_ext) /= model%n_dof) THEN
      CALL fail(ErrStat, ErrMsg, 'f_ext update must have shape (3 n_nodes)')
      RETURN
    END IF
    IF (.NOT. CD_All_Finite(f_ext)) THEN
      CALL fail(ErrStat, ErrMsg, 'f_ext update must be finite')
      RETURN
    END IF
    IF (.NOT. (ALLOCATED(model%f_ext_rollback) .AND. ALLOCATED(model%a_rollback))) THEN
      CALL fail(ErrStat, ErrMsg, 'external-load update requires initialized rollback workspace')
      RETURN
    END IF
    ! Maintain the distributed-load invariant f_ext = remainder + assemble(dist, l0): a later
    ! segment-length update RECONSTRUCTS f_ext from the remainder, so a runtime external-load
    ! update that skipped this would be silently WIPED by the next control command. The
    ! remainder is stored BEFORE the acceleration recompute, which under the force blend after
    ! a pending length change rebuilds the committed external load from it
    ! (enter_committed_lengths); a failed recompute restores f_ext, the remainder and a.
    BLOCK
      REAL(wp) :: f_dist(SIZE(model%f_ext))
      ! the remainder on entry (f_ext_dist_base has the size of f_ext wherever dist_load exists)
      REAL(wp) :: base_entry(SIZE(model%f_ext))
      INTEGER :: es2
      CHARACTER(1024) :: em2
      IF (ALLOCATED(model%dist_load)) THEN
        CALL CD_Assemble_Distributed_Load(model%elem_conn, model%l0, model%dist_load, f_dist, es2, em2)
        IF (es2 /= 0) THEN
          CALL fail(ErrStat, ErrMsg, 'external-load update: distributed-load remainder failed: '//TRIM(em2))
          RETURN
        END IF
        base_entry = model%f_ext_dist_base
      END IF
      model%f_ext_rollback = model%f_ext
      model%a_rollback = model%a
      model%f_ext = f_ext
      IF (ALLOCATED(model%dist_load)) model%f_ext_dist_base = model%f_ext - f_dist
      CALL CD_Recompute_Model_Acceleration(model, ErrStat, ErrMsg)
      IF (ErrStat /= CD_MODEL_OK) THEN
        model%f_ext = model%f_ext_rollback
        model%a = model%a_rollback
        IF (ALLOCATED(model%dist_load)) model%f_ext_dist_base = base_entry
        RETURN
      END IF
    END BLOCK
  END SUBROUTINE CD_Update_Model_External_Loads

  SUBROUTINE CD_Update_Model_CoupledMotion(model, q_coupled, v_coupled, a_coupled, ErrStat, ErrMsg)
    !! Refresh the model-owned state on externally coupled DOFs without advancing
    !! the internal dynamics. The input order matches CD_Get_Model_CoupledDofs.
    !! This is the light kinematics-in half of the shell boundary used before
    !! CD_Calc_Model_CoupledLoads in loose-coupling or predictor workflows.
    !! Call CD_Recompute_Model_Acceleration after this update when support
    !! acceleration consistency is required before output/load derivatives.
    TYPE(CD_ModelType), INTENT(INOUT) :: model
    REAL(wp), INTENT(IN) :: q_coupled(:), v_coupled(:), a_coupled(:)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg

    INTEGER :: n

    ErrStat = CD_MODEL_OK
    ErrMsg = ''
    IF (.NOT. model%initialized) THEN
      ErrStat = CD_MODEL_NOT_INITIALIZED
      ErrMsg = 'CableDyn_Model: model is not initialized'
      RETURN
    END IF
    n = SIZE(model%fixed_dofs)
    IF (SIZE(q_coupled) /= n .OR. SIZE(v_coupled) /= n .OR. SIZE(a_coupled) /= n) THEN
      CALL fail(ErrStat, ErrMsg, 'coupled motion updates must have shape (n_coupled_dof)')
      RETURN
    END IF
    IF (.NOT. CD_All_Finite(q_coupled) .OR. .NOT. CD_All_Finite(v_coupled) .OR. &
        .NOT. CD_All_Finite(a_coupled)) THEN
      CALL fail(ErrStat, ErrMsg, 'coupled motion updates must be finite')
      RETURN
    END IF
    model%q(model%fixed_dofs) = q_coupled
    model%v(model%fixed_dofs) = v_coupled
    model%a(model%fixed_dofs) = a_coupled
  END SUBROUTINE CD_Update_Model_CoupledMotion

  SUBROUTINE CD_Update_Model_Interior_State(model, q_interior, v_interior, ErrStat, ErrMsg, a_interior)
    !! Overwrite the model's INTERIOR-node state (DOFs 4 .. n_dof-3; both endpoint nodes
    !! untouched) -- the checkpoint-restart reload boundary. The framework state mirror
    !! carries exactly these interior [v; q; a] blocks (endpoints are boundary: coupled
    !! ends are re-prescribed by the host mesh, anchors never move), so a restart
    !! rebuilds the model from the deck and reloads the interiors here. a_interior
    !! reloads the generalised-alpha COMMITTED acceleration exactly; when omitted, call
    !! CD_Recompute_Model_Acceleration afterwards (an equations-consistent re-derivation
    !! that differs from the committed algorithmic acceleration at the solve-tolerance
    !! scale -- measured to move the first restored load evaluation, which is why the
    !! mirror carries the acceleration).
    TYPE(CD_ModelType), INTENT(INOUT) :: model
    REAL(wp), INTENT(IN) :: q_interior(:), v_interior(:)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    REAL(wp), INTENT(IN), OPTIONAL :: a_interior(:)

    INTEGER :: nin

    ErrStat = CD_MODEL_OK
    ErrMsg = ''
    IF (.NOT. model%initialized) THEN
      ErrStat = CD_MODEL_NOT_INITIALIZED
      ErrMsg = 'CableDyn_Model: model is not initialized'
      RETURN
    END IF
    nin = model%n_dof - 6
    IF (nin <= 0) THEN
      CALL fail(ErrStat, ErrMsg, 'interior-state update needs a line with interior nodes')
      RETURN
    END IF
    IF (SIZE(q_interior) /= nin .OR. SIZE(v_interior) /= nin) THEN
      CALL fail(ErrStat, ErrMsg, 'interior-state updates must have shape (n_dof - 6)')
      RETURN
    END IF
    IF (.NOT. (CD_All_Finite(q_interior) .AND. CD_All_Finite(v_interior))) THEN
      CALL fail(ErrStat, ErrMsg, 'interior-state updates must be finite')
      RETURN
    END IF
    IF (PRESENT(a_interior)) THEN
      IF (SIZE(a_interior) /= nin) THEN
        CALL fail(ErrStat, ErrMsg, 'interior-state updates must have shape (n_dof - 6)')
        RETURN
      END IF
      IF (.NOT. CD_All_Finite(a_interior)) THEN
        CALL fail(ErrStat, ErrMsg, 'interior-state updates must be finite')
        RETURN
      END IF
    END IF
    model%q(4:model%n_dof - 3) = q_interior
    model%v(4:model%n_dof - 3) = v_interior
    IF (PRESENT(a_interior)) model%a(4:model%n_dof - 3) = a_interior
  END SUBROUTINE CD_Update_Model_Interior_State

  SUBROUTINE CD_Recompute_Model_Acceleration(model, ErrStat, ErrMsg)
    !! Recompute the model-owned acceleration from the current q/v state,
    !! external loads, environmental loads, added mass, and fixed/coupled DOF map.
    !! Use this after runtime updates when the caller needs a consistent
    !! acceleration before a load exchange or diagnostic query.
    !! Under active line control the acceleration is the committed state's: between a length
    !! change (CD_Update_Model_SegmentLength) and the next step it is solved with the lengths
    !! and rates that state was reached with (l0_c, l0_dot_c), which stay the committed ones,
    !! so the step still treats the old and new lengths as it should. The state is evaluated as
    !! the step evaluates its committed side: with the force blend (the step-start force r_n)
    !! the external load and the seabed coefficients that follow the lengths are rebuilt at
    !! the committed lengths too (enter_committed_lengths); under False alpha_force_blend, as
    !! in that step's blend, only the element lengths and rates take the committed values and
    !! the external load and the seabed coefficients are the present ones. The present values
    !! are put back bit for bit on every exit.
    TYPE(CD_ModelType), INTENT(INOUT) :: model
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    TYPE(model_lengths_aside) :: aside

    CALL enter_committed_lengths(model, aside, model%cfg%force_blend, ErrStat, ErrMsg)
    IF (ErrStat /= CD_MODEL_OK) THEN
      ErrMsg = 'CableDyn_Model: acceleration recompute: '//TRIM(ErrMsg)
      RETURN
    END IF
    CALL recompute_model_acceleration_now(model, ErrStat, ErrMsg)
    CALL leave_committed_lengths(model, aside)
  END SUBROUTINE CD_Recompute_Model_Acceleration

  SUBROUTINE recompute_model_acceleration_now(model, ErrStat, ErrMsg)
    !! CD_Recompute_Model_Acceleration with the lengths and rates in place.
    TYPE(CD_ModelType), INTENT(INOUT), TARGET :: model
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg

    INTEGER :: es
    CHARACTER(1024) :: em
    LOGICAL :: has_load
    INTEGER :: nc
    LOGICAL :: prescribed_workspace_ready
    ! Entry acceleration: every failure below restores it whole, so a failed
    ! recompute leaves the committed state untouched.
    REAL(wp) :: a_entry(model%n_dof)
    TYPE(model_step_loads) :: step_loads

    ErrStat = CD_MODEL_OK
    ErrMsg = ''
    IF (.NOT. model%initialized) THEN
      ErrStat = CD_MODEL_NOT_INITIALIZED
      ErrMsg = 'CableDyn_Model: model is not initialized'
      RETURN
    END IF
    has_load = model%has_seabed .OR. model%has_seabed_damping .OR. model%has_seabed_friction .OR. &
               model%has_damping .OR. model%has_viscoelastic .OR. model%has_syrope .OR. model%has_morison_drag .OR. &
               model%has_froude_krylov .OR. model%has_buoyancy_recovery .OR. model%has_viv
    nc = SIZE(model%fixed_dofs)
    prescribed_workspace_ready = ALLOCATED(model%a_prescribed_work)
    IF (prescribed_workspace_ready) prescribed_workspace_ready = SIZE(model%a_prescribed_work) >= nc
    IF (.NOT. prescribed_workspace_ready) THEN
      CALL fail(ErrStat, ErrMsg, 'acceleration recompute requires initialized prescribed-acceleration workspace')
      RETURN
    END IF
    a_entry = model%a
    model%a_prescribed_work(1:nc) = model%a(model%fixed_dofs)
    step_loads%model => model
    step_loads%has_force = has_load
    step_loads%has_added_mass = model%has_added_mass
    IF (has_load .AND. model%has_added_mass) THEN
      CALL CD_Cable_Initial_Acceleration(model%q, model%v, model%elem_conn, model%l0, model%ea_dyn, &
                                         model%rho_a, model%tension_only, model%f_ext, &
                                         model%fixed_dofs, model%a, es, em, &
                                         workspace=model%dynamic_workspace, loads=step_loads)
    ELSE IF (has_load) THEN
      CALL CD_Cable_Initial_Acceleration(model%q, model%v, model%elem_conn, model%l0, model%ea_dyn, &
                                         model%rho_a, model%tension_only, model%f_ext, &
                                         model%fixed_dofs, model%a, es, em, &
                                         workspace=model%dynamic_workspace, loads=step_loads)
    ELSE IF (model%has_added_mass) THEN
      CALL CD_Cable_Initial_Acceleration(model%q, model%v, model%elem_conn, model%l0, model%ea_dyn, &
                                         model%rho_a, model%tension_only, model%f_ext, &
                                         model%fixed_dofs, model%a, es, em, &
                                         workspace=model%dynamic_workspace, loads=step_loads)
    ELSE
      CALL CD_Cable_Initial_Acceleration(model%q, model%v, model%elem_conn, model%l0, model%ea_dyn, &
                                         model%rho_a, model%tension_only, model%f_ext, &
                                         model%fixed_dofs, model%a, es, em, workspace=model%dynamic_workspace)
    END IF
    IF (es /= CD_DYN_OK) THEN
      model%a = a_entry
      ErrStat = model_status_from_dyn(es)
      ErrMsg = 'CableDyn_Model: acceleration recompute failed: '//TRIM(em)
      RETURN
    END IF
    model%a(model%fixed_dofs) = model%a_prescribed_work(1:nc)
    CALL apply_prescribed_acceleration_coupling(model, model%a_prescribed_work(1:nc), ErrStat, ErrMsg)
    IF (ErrStat /= CD_MODEL_OK) THEN
      model%a = a_entry
      RETURN
    END IF

  CONTAINS

    SUBROUTINE apply_prescribed_acceleration_coupling(model, prescribed_a, ErrStat, ErrMsg)
      TYPE(CD_ModelType), INTENT(INOUT) :: model
      REAL(wp), INTENT(IN) :: prescribed_a(:)
      INTEGER, INTENT(OUT) :: ErrStat
      CHARACTER(*), INTENT(OUT) :: ErrMsg

      INTEGER :: es, n_free, i, j, row, col
      CHARACTER(1024) :: em

      ErrStat = CD_MODEL_OK
      ErrMsg = ''
      IF (SIZE(prescribed_a) == 0) RETURN
      IF (MAXVAL(ABS(prescribed_a)) <= EPSILON(CD_ZERO)) RETURN
      CALL partition_model_free_work(model, n_free, ErrStat, ErrMsg)
      IF (ErrStat /= CD_MODEL_OK) RETURN
      IF (n_free == 0) RETURN
      CALL ensure_support_acceleration_workspace(model, n_free, ErrStat, ErrMsg)
      IF (ErrStat /= CD_MODEL_OK) RETURN
      ASSOCIATE (M => model%dynamic_workspace%M(1:model%n_dof, 1:model%n_dof), &
                 M_free => model%dynamic_workspace%eff_free(1:n_free, 1:n_free), &
                 rhs => model%dynamic_workspace%R_free(1:n_free))
        CALL CD_Assemble_Cable_Mass(model%elem_conn, model%l0, model%rho_a, M, es, em, topology_validated=.TRUE.)
        IF (es /= 0) THEN
          ErrStat = CD_MODEL_SOLVEFAIL
          ErrMsg = 'CableDyn_Model: support-inertia mass assembly failed: '//TRIM(em)
          RETURN
        END IF
        IF (model%has_added_mass) THEN
          ASSOCIATE (M_add => model%dynamic_workspace%M_add_eval(1:model%n_dof, 1:model%n_dof), &
                     dMa_a_dq => model%dynamic_workspace%dMa_a_dq_eval(1:model%n_dof, 1:model%n_dof))
            CALL model_added_mass_full(model, model%q, model%a, M_add, dMa_a_dq, es, em)
            IF (es /= 0) THEN
              ErrStat = CD_MODEL_SOLVEFAIL
              ErrMsg = 'CableDyn_Model: support-inertia added-mass assembly failed: '//TRIM(em)
              RETURN
            END IF
            M = M + M_add
          END ASSOCIATE
        END IF
        DO j = 1, n_free
          col = model%free_map_work(j)
          DO i = 1, n_free
            row = model%free_map_work(i)
            M_free(i, j) = M(row, col)
          END DO
        END DO
        rhs = CD_ZERO
        DO j = 1, SIZE(model%fixed_dofs)
          col = model%fixed_dofs(j)
          DO i = 1, n_free
            row = model%free_map_work(i)
            rhs(i) = rhs(i) + M(row, col)*prescribed_a(j)
          END DO
        END DO
        CALL CD_Solve_Dense_As_Banded(M_free, rhs, es, em)
        IF (es /= 0 .OR. .NOT. CD_All_Finite(rhs)) THEN
          ErrStat = CD_MODEL_SOLVEFAIL
          ErrMsg = 'CableDyn_Model: support-inertia solve failed: '//TRIM(em)
          RETURN
        END IF
        DO i = 1, n_free
          row = model%free_map_work(i)
          model%a(row) = model%a(row) - rhs(i)
        END DO
      END ASSOCIATE
    END SUBROUTINE apply_prescribed_acceleration_coupling

    SUBROUTINE partition_model_free_work(model, n_free, ErrStat, ErrMsg)
      TYPE(CD_ModelType), INTENT(INOUT) :: model
      INTEGER, INTENT(OUT) :: n_free
      INTEGER, INTENT(OUT) :: ErrStat
      CHARACTER(*), INTENT(OUT) :: ErrMsg

      INTEGER :: i, dof
      LOGICAL :: free_map_ready, marker_ready

      ErrStat = CD_MODEL_OK
      ErrMsg = ''
      n_free = 0
      free_map_ready = ALLOCATED(model%free_map_work)
      IF (free_map_ready) free_map_ready = SIZE(model%free_map_work) >= model%n_dof
      IF (.NOT. free_map_ready) THEN
        CALL fail(ErrStat, ErrMsg, 'support-inertia coupling requires initialized free-map workspace')
        RETURN
      END IF
      marker_ready = ALLOCATED(model%dynamic_workspace%dof_marker)
      IF (marker_ready) marker_ready = SIZE(model%dynamic_workspace%dof_marker) >= model%n_dof
      IF (.NOT. marker_ready) THEN
        CALL fail(ErrStat, ErrMsg, 'support-inertia coupling requires initialized DOF marker workspace')
        RETURN
      END IF
      model%dynamic_workspace%dof_marker(1:model%n_dof) = 0
      DO i = 1, SIZE(model%fixed_dofs)
        dof = model%fixed_dofs(i)
        IF (dof < 1 .OR. dof > model%n_dof) THEN
          CALL fail(ErrStat, ErrMsg, 'support-inertia fixed DOF is out of range')
          RETURN
        END IF
        IF (model%dynamic_workspace%dof_marker(dof) /= 0) THEN
          CALL fail(ErrStat, ErrMsg, 'support-inertia fixed DOFs contain duplicates')
          RETURN
        END IF
        model%dynamic_workspace%dof_marker(dof) = 1
      END DO
      DO dof = 1, model%n_dof
        IF (model%dynamic_workspace%dof_marker(dof) == 0) THEN
          n_free = n_free + 1
          model%free_map_work(n_free) = dof
        END IF
      END DO
    END SUBROUTINE partition_model_free_work

    SUBROUTINE ensure_support_acceleration_workspace(model, n_free, ErrStat, ErrMsg)
      TYPE(CD_ModelType), INTENT(INOUT) :: model
      INTEGER, INTENT(IN) :: n_free
      INTEGER, INTENT(OUT) :: ErrStat
      CHARACTER(*), INTENT(OUT) :: ErrMsg

      INTEGER :: istat, n
      LOGICAL :: need_workspace

      ErrStat = CD_MODEL_OK
      ErrMsg = ''
      n = model%n_dof
      need_workspace = .NOT. ALLOCATED(model%dynamic_workspace%M)
      IF (.NOT. need_workspace) need_workspace = SIZE(model%dynamic_workspace%M, 1) < n .OR. &
                                                 SIZE(model%dynamic_workspace%M, 2) < n
      IF (need_workspace) THEN
        IF (ALLOCATED(model%dynamic_workspace%M)) DEALLOCATE (model%dynamic_workspace%M)
        ALLOCATE (model%dynamic_workspace%M(n, n), STAT=istat)
        IF (istat /= 0) THEN
          CALL alloc_fail(ErrStat, ErrMsg, 'support-inertia mass workspace allocation failed')
          RETURN
        END IF
      END IF
      need_workspace = .NOT. ALLOCATED(model%dynamic_workspace%eff_free)
      IF (.NOT. need_workspace) need_workspace = SIZE(model%dynamic_workspace%eff_free, 1) < n_free .OR. &
                                                 SIZE(model%dynamic_workspace%eff_free, 2) < n_free
      IF (need_workspace) THEN
        IF (ALLOCATED(model%dynamic_workspace%eff_free)) DEALLOCATE (model%dynamic_workspace%eff_free)
        ALLOCATE (model%dynamic_workspace%eff_free(n_free, n_free), STAT=istat)
        IF (istat /= 0) THEN
          CALL alloc_fail(ErrStat, ErrMsg, 'support-inertia reduced-mass workspace allocation failed')
          RETURN
        END IF
      END IF
      need_workspace = .NOT. ALLOCATED(model%dynamic_workspace%R_free)
      IF (.NOT. need_workspace) need_workspace = SIZE(model%dynamic_workspace%R_free) < n_free
      IF (need_workspace) THEN
        IF (ALLOCATED(model%dynamic_workspace%R_free)) DEALLOCATE (model%dynamic_workspace%R_free)
        ALLOCATE (model%dynamic_workspace%R_free(n_free), STAT=istat)
        IF (istat /= 0) THEN
          CALL alloc_fail(ErrStat, ErrMsg, 'support-inertia rhs workspace allocation failed')
          RETURN
        END IF
      END IF
      IF (model%has_added_mass) THEN
        need_workspace = .NOT. ALLOCATED(model%dynamic_workspace%M_add_eval)
        IF (.NOT. need_workspace) need_workspace = SIZE(model%dynamic_workspace%M_add_eval, 1) < n .OR. &
                                                   SIZE(model%dynamic_workspace%M_add_eval, 2) < n
        IF (need_workspace) THEN
          IF (ALLOCATED(model%dynamic_workspace%M_add_eval)) DEALLOCATE (model%dynamic_workspace%M_add_eval)
          ALLOCATE (model%dynamic_workspace%M_add_eval(n, n), STAT=istat)
          IF (istat /= 0) THEN
            CALL alloc_fail(ErrStat, ErrMsg, 'support-inertia added-mass workspace allocation failed')
            RETURN
          END IF
        END IF
        need_workspace = .NOT. ALLOCATED(model%dynamic_workspace%dMa_a_dq_eval)
        IF (.NOT. need_workspace) need_workspace = SIZE(model%dynamic_workspace%dMa_a_dq_eval, 1) < n .OR. &
                                                   SIZE(model%dynamic_workspace%dMa_a_dq_eval, 2) < n
        IF (need_workspace) THEN
          IF (ALLOCATED(model%dynamic_workspace%dMa_a_dq_eval)) DEALLOCATE (model%dynamic_workspace%dMa_a_dq_eval)
          ALLOCATE (model%dynamic_workspace%dMa_a_dq_eval(n, n), STAT=istat)
          IF (istat /= 0) THEN
            CALL alloc_fail(ErrStat, ErrMsg, 'support-inertia added-mass tangent workspace allocation failed')
            RETURN
          END IF
        END IF
      END IF
    END SUBROUTINE ensure_support_acceleration_workspace
  END SUBROUTINE recompute_model_acceleration_now

  SUBROUTINE CD_Audit_Model_Step(model, time, dt, new_spike)
    !! Audit one committed host step of an EI=0 line (called by the standalone driver on the
    !! initial state and once per output step, after the step's plausibility guard). Cheap,
    !! O(n_elem) (and one evaluation of the viscoelastic and Syrope laws), and
    !! diagnostic only. It tracks
    !!
    !! * the largest turn of a taut segment's chord over one step, the measure of how well
    !!   dtM resolves the rotation of the line (time-step advisory);
    !! * slack-to-taut snaps above the initial tension scale, with the largest dt*c/l0 among
    !!   them (c = sqrt(EA/m) the axial wave speed; EA the dynamic stiffness: EA_D of a
    !!   viscoelastic segment, alpha + beta*T of a Syrope one): dt*c/l0 > 1 leaves the snap
    !!   peak unresolved in time;
    !! * implausible tension spikes. A segment's tension T_n at the previous audited
    !!   step is a spike when it exceeds four times its own tension one step before and one
    !!   step after, ten times the largest tension anywhere on the line one step before and
    !!   one step after, and the largest tension of the initial state. A physical snap or
    !!   tension wave persists over the axial transit time and is shared by the neighbouring
    !!   segments, so no line, resolved or not, carries such an isolated single-step peak; an
    !!   integrator artefact (an under-resolved slack-taut transition) does.
    !!
    !! new_spike reports the line's first spike (so the caller warns once per line). The
    !! tension is EA*max(strain, 0) of the elastic elements (EA*strain on a line that allows
    !! compression) and the tension of their own law at the committed state for the
    !! viscoelastic and Syrope elements (CD_Get_Model_Tension); the driver calls the audit
    !! once on the initial state, so the "initial tension" is that of t = 0.
    TYPE(CD_ModelType), INTENT(INOUT) :: model
    REAL(wp), INTENT(IN) :: time, dt
    LOGICAL, INTENT(OUT) :: new_spike
    REAL(wp), PARAMETER :: SPIKE_ISOLATION = 4.0_wp, SPIKE_LINE_FACTOR = 10.0_wp
    ! A segment counts as taut for the turn advisory above this fraction of the initial
    ! line tension (a nearly slack segment turns freely, its tension error is irrelevant);
    ! the spike test needs this many segments (the neighbours share the axial wave).
    REAL(wp), PARAMETER :: TURN_TAUT_FRACTION = 1.0e-3_wp
    INTEGER, PARAMETER :: SPIKE_MIN_ELEMS = 3
    INTEGER :: e, na, nb, istat, es
    REAL(wp) :: d(3), ell, strain, u(3), c, line_max, tn, h
    REAL(wp), ALLOCATABLE :: law(:)
    LOGICAL :: fresh, laws
    CHARACTER(1024) :: em

    new_spike = .FALSE.
    IF (.NOT. model%initialized .OR. model%n_elem < 1) RETURN
    ! the largest solver step since the last audit (sub-steps of the resolved or recovering
    ! step): turns and axial wave crossings are measured per solver step
    h = dt
    IF (model%audit_hmax > CD_ZERO) h = MIN(dt, model%audit_hmax)
    model%audit_hmax = CD_ZERO
    fresh = .NOT. (ALLOCATED(model%audit_t) .AND. ALLOCATED(model%audit_u) .AND. ALLOCATED(model%audit_now))
    IF (.NOT. fresh) fresh = SIZE(model%audit_t, 1) /= model%n_elem
    IF (fresh) THEN
      IF (ALLOCATED(model%audit_t)) DEALLOCATE (model%audit_t)
      IF (ALLOCATED(model%audit_u)) DEALLOCATE (model%audit_u)
      IF (ALLOCATED(model%audit_now)) DEALLOCATE (model%audit_now)
      ALLOCATE (model%audit_t(model%n_elem, 2), model%audit_u(3, model%n_elem), model%audit_now(model%n_elem), &
                STAT=istat)
      IF (istat /= 0) RETURN
      model%audit_n = 0
    END IF
    ! the law tensions of the viscoelastic and Syrope segments at the committed state (a
    ! segment whose law cannot be evaluated is left out, -1, as is every segment without a
    ! tension when the evaluation fails)
    laws = model%has_viscoelastic .OR. model%has_syrope
    IF (laws) THEN
      ! a local array, not model%audit_now itself (the law evaluation reads the model)
      ALLOCATE (law(model%n_elem), STAT=istat)
      laws = istat == 0
    END IF
    IF (laws) THEN
      law = -CD_ONE
      CALL model_law_tensions(model, law, es, em)
      laws = es == CD_MODEL_OK
      IF (laws) model%audit_now = law
    END IF
    ! current tensions, chords and the chord turn against the previous audited state
    DO e = 1, model%n_elem
      na = model%elem_conn(1, e)
      nb = model%elem_conn(2, e)
      d = model%q(3*nb - 2:3*nb) - model%q(3*na - 2:3*na)
      ell = NORM2(d)
      IF (.NOT. ell > CD_ZERO) THEN
        u = CD_ZERO
      ELSE
        u = d/ell
      END IF
      IF (model%ea_dyn(e) > CD_ZERO) THEN
        strain = ell/model%l0(e) - CD_ONE
        IF (model%tension_only .AND. strain < CD_ZERO) strain = CD_ZERO
        model%audit_now(e) = model%ea_dyn(e)*strain
      ELSE IF (laws .AND. law_element(e)) THEN
        ! a tension-only law reports no compression; keep a finite value only
        IF (.NOT. CD_Is_Finite(model%audit_now(e))) THEN
          model%audit_now(e) = -CD_ONE
        ELSE IF (model%tension_only) THEN
          model%audit_now(e) = MAX(model%audit_now(e), CD_ZERO)
        END IF
      ELSE
        model%audit_now(e) = -CD_ONE
      END IF
      IF (model%audit_n >= 1) THEN
        ! the turn of a segment taut at both states (a slack segment turns freely and carries
        ! no tension whose accuracy the turn would measure)
        IF (model%audit_now(e) > TURN_TAUT_FRACTION*model%audit_floor .AND. &
            model%audit_now(e) > CD_ZERO .AND. &
            model%audit_t(e, 1) > TURN_TAUT_FRACTION*model%audit_floor .AND. model%audit_t(e, 1) > CD_ZERO) &
          model%audit_max_turn = MAX(model%audit_max_turn, &
                                     ACOS(MAX(-CD_ONE, MIN(CD_ONE, DOT_PRODUCT(u, model%audit_u(:, e)))))* &
                                     (180.0_wp/ACOS(-CD_ONE))*(h/dt))
        ! slack at the previous state, taut above the initial tension scale now
        IF (model%audit_t(e, 1) >= CD_ZERO .AND. .NOT. model%audit_t(e, 1) > CD_ZERO .AND. &
            model%audit_now(e) > model%audit_floor) THEN
          model%audit_snaps = model%audit_snaps + 1
          c = SQRT(segment_wave_stiffness(model, e, model%audit_now(e))/model%rho_a(e))
          model%audit_snap_courant = MAX(model%audit_snap_courant, h*c/model%l0(e))
        END IF
      END IF
      model%audit_u(:, e) = u
    END DO
    IF (model%audit_n == 0) model%audit_floor = MAX(CD_ZERO, MAXVAL(model%audit_now))
    ! spike test on the previous state, between its two neighbours
    IF (model%audit_n >= 2 .AND. model%n_elem >= SPIKE_MIN_ELEMS) THEN
      line_max = MAX(MAXVAL(model%audit_t(:, 2)), MAXVAL(model%audit_now))
      DO e = 1, model%n_elem
        tn = model%audit_t(e, 1)
        IF (.NOT. (tn > model%audit_floor)) CYCLE
        IF (tn <= SPIKE_ISOLATION*MAX(model%audit_t(e, 2), model%audit_now(e))) CYCLE
        IF (tn <= SPIKE_LINE_FACTOR*line_max) CYCLE
        model%audit_spikes = model%audit_spikes + 1
        IF (model%audit_spikes == 1) THEN
          model%audit_spike_time = model%audit_time
          model%audit_spike_elem = e
          model%audit_spike_tension = tn
          model%audit_spike_ratio = tn/MAX(line_max, TINY(CD_ONE))
          new_spike = .TRUE.
        END IF
      END DO
    END IF
    model%audit_t(:, 2) = model%audit_t(:, 1)
    model%audit_t(:, 1) = model%audit_now
    model%audit_time = time
    model%audit_n = MIN(model%audit_n + 1, 2)

  CONTAINS

    LOGICAL FUNCTION law_element(k) RESULT(is_law)
      !! Segment k carries the viscoelastic or the Syrope law.
      INTEGER, INTENT(IN) :: k
      is_law = .FALSE.
      IF (model%has_viscoelastic) is_law = model%ve_mode(k) /= 0
      IF (model%has_syrope .AND. .NOT. is_law) is_law = model%syrope_is(k)
    END FUNCTION law_element

  END SUBROUTINE CD_Audit_Model_Step

  SUBROUTINE clear_model_audit(model)
    !! Reset the run audit (CD_Audit_Model_Step).
    TYPE(CD_ModelType), INTENT(INOUT) :: model
    IF (ALLOCATED(model%audit_t)) DEALLOCATE (model%audit_t)
    IF (ALLOCATED(model%audit_u)) DEALLOCATE (model%audit_u)
    IF (ALLOCATED(model%audit_now)) DEALLOCATE (model%audit_now)
    model%audit_n = 0
    model%audit_time = CD_ZERO
    model%audit_floor = CD_ZERO
    model%audit_max_turn = CD_ZERO
    model%audit_snap_courant = CD_ZERO
    model%audit_snaps = 0
    model%audit_spikes = 0
    model%audit_spike_elem = 0
    model%audit_spike_time = CD_ZERO
    model%audit_spike_tension = CD_ZERO
    model%audit_spike_ratio = CD_ZERO
    model%audit_hmax = CD_ZERO
    model%audit_hmax_rollback = CD_ZERO
    ! the sub-stepping diagnostics and test hooks start afresh with the model
    model%sub_stats = CD_SubstepStats()
    model%sub_stats_rollback = CD_SubstepStats()
    model%sub_test_fail = 0
    model%sub_test_repeat = .FALSE.
    model%sub_test_more = .FALSE.
  END SUBROUTINE clear_model_audit

  SUBROUTINE CD_End_Model(model, ErrStat, ErrMsg)
    !! Release all allocatable model storage. Safe to call on an uninitialised model.
    TYPE(CD_ModelType), INTENT(INOUT) :: model
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg

    IF (ALLOCATED(model%elem_conn)) DEALLOCATE (model%elem_conn)
    IF (ALLOCATED(model%fixed_dofs)) DEALLOCATE (model%fixed_dofs)
    IF (ALLOCATED(model%l0)) DEALLOCATE (model%l0)
    IF (ALLOCATED(model%ea)) DEALLOCATE (model%ea)
    IF (ALLOCATED(model%rho_a)) DEALLOCATE (model%rho_a)
    IF (ALLOCATED(model%f_ext)) DEALLOCATE (model%f_ext)
    IF (ALLOCATED(model%l0_dot)) DEALLOCATE (model%l0_dot)
    IF (ALLOCATED(model%l0_c)) DEALLOCATE (model%l0_c)
    IF (ALLOCATED(model%l0_dot_c)) DEALLOCATE (model%l0_dot_c)
    IF (ALLOCATED(model%l0_c_rollback)) DEALLOCATE (model%l0_c_rollback)
    IF (ALLOCATED(model%l0_dot_c_rollback)) DEALLOCATE (model%l0_dot_c_rollback)
    IF (ALLOCATED(model%recovery_l0_c)) DEALLOCATE (model%recovery_l0_c)
    IF (ALLOCATED(model%recovery_l0_dot_c)) DEALLOCATE (model%recovery_l0_dot_c)
    IF (ALLOCATED(model%dist_load)) DEALLOCATE (model%dist_load)
    IF (ALLOCATED(model%f_ext_dist_base)) DEALLOCATE (model%f_ext_dist_base)
    IF (ALLOCATED(model%seabed_diameter_elem)) DEALLOCATE (model%seabed_diameter_elem)
    ! reset the recompute state with its array: CD_Init_Model only ever SETS the
    ! flag, so a reused model would otherwise inherit .TRUE. without the inputs
    ! and the length update would read a deallocated diameter array
    model%has_seabed_recompute = .FALSE.
    model%seabed_kbot = CD_ZERO
    model%seabed_cn_over_kn = CD_ZERO
    IF (ALLOCATED(model%q)) DEALLOCATE (model%q)
    IF (ALLOCATED(model%v)) DEALLOCATE (model%v)
    IF (ALLOCATED(model%a)) DEALLOCATE (model%a)
    IF (ALLOCATED(model%q_step)) DEALLOCATE (model%q_step)
    IF (ALLOCATED(model%v_step)) DEALLOCATE (model%v_step)
    IF (ALLOCATED(model%a_step)) DEALLOCATE (model%a_step)
    IF (ALLOCATED(model%q_prescribed_work)) DEALLOCATE (model%q_prescribed_work)
    IF (ALLOCATED(model%v_prescribed_work)) DEALLOCATE (model%v_prescribed_work)
    IF (ALLOCATED(model%a_prescribed_work)) DEALLOCATE (model%a_prescribed_work)
    IF (ALLOCATED(model%q_rollback)) DEALLOCATE (model%q_rollback)
    IF (ALLOCATED(model%v_rollback)) DEALLOCATE (model%v_rollback)
    IF (ALLOCATED(model%a_rollback)) DEALLOCATE (model%a_rollback)
    IF (ALLOCATED(model%recovery_q0)) DEALLOCATE (model%recovery_q0)
    model%sub_slot(1) = CD_ModelCommitSlot()
    model%sub_slot(2) = CD_ModelCommitSlot()
    model%sub_target = CD_ModelControlSaveType()
    IF (ALLOCATED(model%sub_t0)) DEALLOCATE (model%sub_t0)
    IF (ALLOCATED(model%sub_t1)) DEALLOCATE (model%sub_t1)
    IF (ALLOCATED(model%sub_pq)) DEALLOCATE (model%sub_pq)
    IF (ALLOCATED(model%sub_pv)) DEALLOCATE (model%sub_pv)
    IF (ALLOCATED(model%sub_pa)) DEALLOCATE (model%sub_pa)
    IF (ALLOCATED(model%recovery_v0)) DEALLOCATE (model%recovery_v0)
    IF (ALLOCATED(model%recovery_a0)) DEALLOCATE (model%recovery_a0)
    IF (ALLOCATED(model%f_ext_rollback)) DEALLOCATE (model%f_ext_rollback)
    IF (ALLOCATED(model%free_map_work)) DEALLOCATE (model%free_map_work)
    CALL CD_Clear_GenAlpha_Workspace(model%dynamic_workspace)
    CALL clear_model_load_contributor_workspace(model)
    CALL clear_model_audit(model)
    IF (ALLOCATED(model%seabed_kn)) DEALLOCATE (model%seabed_kn)
    IF (ALLOCATED(model%seabed_cn)) DEALLOCATE (model%seabed_cn)
    CALL CD_End_Bathymetry(model%bathymetry)
    IF (ALLOCATED(model%ba)) DEALLOCATE (model%ba)
    IF (ALLOCATED(model%ba_dyn)) DEALLOCATE (model%ba_dyn)
    IF (ALLOCATED(model%ea_dyn)) DEALLOCATE (model%ea_dyn)
    IF (ALLOCATED(model%ve_mode)) DEALLOCATE (model%ve_mode)
    IF (ALLOCATED(model%ve_alpha_mbl)) DEALLOCATE (model%ve_alpha_mbl)
    IF (ALLOCATED(model%ve_vbeta)) DEALLOCATE (model%ve_vbeta)
    IF (ALLOCATED(model%ve_ea_d)) DEALLOCATE (model%ve_ea_d)
    IF (ALLOCATED(model%ve_ea_1)) DEALLOCATE (model%ve_ea_1)
    IF (ALLOCATED(model%ve_ba)) DEALLOCATE (model%ve_ba)
    IF (ALLOCATED(model%ve_ba_d)) DEALLOCATE (model%ve_ba_d)
    IF (ALLOCATED(model%ve_dl_1)) DEALLOCATE (model%ve_dl_1)
    IF (ALLOCATED(model%ve_dl_1_rollback)) DEALLOCATE (model%ve_dl_1_rollback)
    IF (ALLOCATED(model%recovery_ve_dl_1)) DEALLOCATE (model%recovery_ve_dl_1)
    IF (ALLOCATED(model%syrope_type)) THEN
      BLOCK
        INTEGER :: e
        DO e = 1, SIZE(model%syrope_type)
          CALL CD_Syrope_End(model%syrope_type(e))
        END DO
      END BLOCK
      DEALLOCATE (model%syrope_type)
    END IF
    IF (ALLOCATED(model%syrope_is)) DEALLOCATE (model%syrope_is)
    IF (ALLOCATED(model%syrope_slow)) DEALLOCATE (model%syrope_slow)
    IF (ALLOCATED(model%syrope_slow_rollback)) DEALLOCATE (model%syrope_slow_rollback)
    IF (ALLOCATED(model%syrope_tmax)) DEALLOCATE (model%syrope_tmax)
    IF (ALLOCATED(model%syrope_tmax_rollback)) DEALLOCATE (model%syrope_tmax_rollback)
    IF (ALLOCATED(model%recovery_syrope_slow)) DEALLOCATE (model%recovery_syrope_slow)
    IF (ALLOCATED(model%recovery_syrope_tmax)) DEALLOCATE (model%recovery_syrope_tmax)
    IF (ALLOCATED(model%fr_anchor)) DEALLOCATE (model%fr_anchor)
    IF (ALLOCATED(model%fr_anchor_rollback)) DEALLOCATE (model%fr_anchor_rollback)
    IF (ALLOCATED(model%recovery_fr_anchor)) DEALLOCATE (model%recovery_fr_anchor)
    IF (ALLOCATED(model%fluid_velocity)) DEALLOCATE (model%fluid_velocity)
    IF (ALLOCATED(model%drag_waterline_z)) DEALLOCATE (model%drag_waterline_z)
    IF (ALLOCATED(model%drag_diameter_elem)) DEALLOCATE (model%drag_diameter_elem)
    IF (ALLOCATED(model%drag_cdn_elem)) DEALLOCATE (model%drag_cdn_elem)
    IF (ALLOCATED(model%drag_cdt_elem)) DEALLOCATE (model%drag_cdt_elem)
    IF (ALLOCATED(model%fluid_acceleration)) DEALLOCATE (model%fluid_acceleration)
    IF (ALLOCATED(model%fk_waterline_z)) DEALLOCATE (model%fk_waterline_z)
    IF (ALLOCATED(model%fk_diameter_elem)) DEALLOCATE (model%fk_diameter_elem)
    IF (ALLOCATED(model%fk_can_elem)) DEALLOCATE (model%fk_can_elem)
    IF (ALLOCATED(model%fk_cat_elem)) DEALLOCATE (model%fk_cat_elem)
    IF (ALLOCATED(model%buoyancy_waterline_z)) DEALLOCATE (model%buoyancy_waterline_z)
    IF (ALLOCATED(model%buoyancy_diameter_elem)) DEALLOCATE (model%buoyancy_diameter_elem)
    IF (ALLOCATED(model%added_mass_waterline_z)) DEALLOCATE (model%added_mass_waterline_z)
    IF (ALLOCATED(model%added_mass_diameter_elem)) DEALLOCATE (model%added_mass_diameter_elem)
    IF (ALLOCATED(model%added_mass_can_elem)) DEALLOCATE (model%added_mass_can_elem)
    IF (ALLOCATED(model%added_mass_cat_elem)) DEALLOCATE (model%added_mass_cat_elem)
    CALL clear_viv(model)
    model%initialized = .FALSE.
    model%tension_only = .FALSE.
    model%has_seabed = .FALSE.
    model%has_bathymetry = .FALSE.
    model%has_seabed_damping = .FALSE.
    model%has_seabed_friction = .FALSE.
    model%has_damping = .FALSE.
    model%has_viscoelastic = .FALSE.
    model%ve_dt = CD_ZERO
    model%has_syrope = .FALSE.
    model%has_morison_drag = .FALSE.
    model%has_froude_krylov = .FALSE.
    model%has_buoyancy_recovery = .FALSE.
    model%has_added_mass = .FALSE.
    model%seabed_z_floor = CD_ZERO
    model%seabed_mu = CD_ZERO
    model%seabed_friction_aniso = .FALSE.
    model%seabed_mu_axial = CD_ZERO
    model%drag_rho = CD_ZERO
    model%drag_diameter = CD_ZERO
    model%drag_cdn = CD_ZERO
    model%drag_cdt = CD_ZERO
    model%fk_rho = CD_ZERO
    model%fk_diameter = CD_ZERO
    model%fk_can = CD_ZERO
    model%fk_cat = CD_ZERO
    model%buoyancy_rho = CD_ZERO
    model%buoyancy_diameter = CD_ZERO
    model%buoyancy_gravity = CD_ZERO
    model%added_mass_rho = CD_ZERO
    model%added_mass_diameter = CD_ZERO
    model%added_mass_can = CD_ZERO
    model%added_mass_cat = CD_ZERO
    model%n_dof = 0
    model%n_elem = 0
    ErrStat = CD_MODEL_OK
    ErrMsg = ''
  END SUBROUTINE CD_End_Model

  SUBROUTINE CD_Copy_Model(src, dst, ErrStat, ErrMsg)
    !! Deep-copy persistent model state with checked allocation. Transient solver
    !! workspaces are intentionally not copied; they are rebuilt on demand.
    TYPE(CD_ModelType), INTENT(IN) :: src
    TYPE(CD_ModelType), INTENT(INOUT) :: dst
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg

    TYPE(CD_ModelType) :: work
    INTEGER :: es
    CHARACTER(1024) :: em

    ErrStat = CD_MODEL_OK
    ErrMsg = ''
    ! Build the copy into a temporary model and commit it into dst only after every checked
    ! allocation succeeds. dst is left untouched on any failure, so a caller's already-initialized
    ! model survives an out-of-memory copy intact. work is a local: its allocatable components are
    ! released automatically on every early return. The final assignment is the single commit point.

    work%tension_only = src%tension_only
    work%azimuth_signed = src%azimuth_signed
    work%n_dof = src%n_dof
    work%n_elem = src%n_elem
    work%has_seabed = src%has_seabed
    work%has_bathymetry = src%has_bathymetry
    work%seabed_z_floor = src%seabed_z_floor
    work%has_seabed_damping = src%has_seabed_damping
    work%has_seabed_friction = src%has_seabed_friction
    work%seabed_mu = src%seabed_mu
    work%seabed_friction_aniso = src%seabed_friction_aniso
    work%seabed_mu_axial = src%seabed_mu_axial
    work%has_seabed_recompute = src%has_seabed_recompute
    work%seabed_kbot = src%seabed_kbot
    work%seabed_cn_over_kn = src%seabed_cn_over_kn
    work%has_damping = src%has_damping
    work%has_viscoelastic = src%has_viscoelastic
    work%ve_dt = src%ve_dt
    work%has_syrope = src%has_syrope
    work%has_morison_drag = src%has_morison_drag
    work%drag_rho = src%drag_rho
    work%drag_diameter = src%drag_diameter
    work%drag_cdn = src%drag_cdn
    work%drag_cdt = src%drag_cdt
    work%has_froude_krylov = src%has_froude_krylov
    work%fk_rho = src%fk_rho
    work%fk_diameter = src%fk_diameter
    work%fk_can = src%fk_can
    work%fk_cat = src%fk_cat
    work%has_buoyancy_recovery = src%has_buoyancy_recovery
    work%buoyancy_rho = src%buoyancy_rho
    work%buoyancy_diameter = src%buoyancy_diameter
    work%buoyancy_gravity = src%buoyancy_gravity
    work%has_added_mass = src%has_added_mass
    work%added_mass_rho = src%added_mass_rho
    work%added_mass_diameter = src%added_mass_diameter
    work%added_mass_can = src%added_mass_can
    work%added_mass_cat = src%added_mass_cat
    work%cfg = src%cfg
    work%sub_t_init = src%sub_t_init

    CALL copy_int2(src%elem_conn, work%elem_conn, 'elem_conn', ErrStat, ErrMsg)
    IF (ErrStat /= CD_MODEL_OK) RETURN
    CALL copy_int1(src%fixed_dofs, work%fixed_dofs, 'fixed_dofs', ErrStat, ErrMsg)
    IF (ErrStat /= CD_MODEL_OK) RETURN
    CALL copy_real1(src%l0, work%l0, 'l0', ErrStat, ErrMsg)
    IF (ErrStat /= CD_MODEL_OK) RETURN
    CALL copy_real1(src%ea, work%ea, 'ea', ErrStat, ErrMsg)
    IF (ErrStat /= CD_MODEL_OK) RETURN
    CALL copy_real1(src%rho_a, work%rho_a, 'rho_a', ErrStat, ErrMsg)
    IF (ErrStat /= CD_MODEL_OK) RETURN
    CALL copy_real1(src%l0_dot, work%l0_dot, 'l0_dot', ErrStat, ErrMsg)
    IF (ErrStat /= CD_MODEL_OK) RETURN
    CALL copy_real1(src%l0_c, work%l0_c, 'l0_c', ErrStat, ErrMsg)
    IF (ErrStat /= CD_MODEL_OK) RETURN
    CALL copy_real1(src%l0_dot_c, work%l0_dot_c, 'l0_dot_c', ErrStat, ErrMsg)
    IF (ErrStat /= CD_MODEL_OK) RETURN
    CALL copy_real1(src%l0_c_rollback, work%l0_c_rollback, 'l0_c_rollback', ErrStat, ErrMsg)
    IF (ErrStat /= CD_MODEL_OK) RETURN
    CALL copy_real1(src%l0_dot_c_rollback, work%l0_dot_c_rollback, 'l0_dot_c_rollback', ErrStat, ErrMsg)
    IF (ErrStat /= CD_MODEL_OK) RETURN
    CALL copy_real1(src%recovery_l0_c, work%recovery_l0_c, 'recovery_l0_c', ErrStat, ErrMsg)
    IF (ErrStat /= CD_MODEL_OK) RETURN
    CALL copy_real1(src%recovery_l0_dot_c, work%recovery_l0_dot_c, 'recovery_l0_dot_c', ErrStat, ErrMsg)
    IF (ErrStat /= CD_MODEL_OK) RETURN
    CALL copy_real2(src%dist_load, work%dist_load, 'dist_load', ErrStat, ErrMsg)
    IF (ErrStat /= CD_MODEL_OK) RETURN
    CALL copy_real1(src%f_ext_dist_base, work%f_ext_dist_base, 'f_ext_dist_base', ErrStat, ErrMsg)
    IF (ErrStat /= CD_MODEL_OK) RETURN
    CALL copy_real1(src%seabed_diameter_elem, work%seabed_diameter_elem, 'seabed_diameter_elem', ErrStat, ErrMsg)
    IF (ErrStat /= CD_MODEL_OK) RETURN
    CALL copy_real1(src%f_ext, work%f_ext, 'f_ext', ErrStat, ErrMsg)
    IF (ErrStat /= CD_MODEL_OK) RETURN
    CALL copy_real1(src%q, work%q, 'q', ErrStat, ErrMsg)
    IF (ErrStat /= CD_MODEL_OK) RETURN
    CALL copy_real1(src%v, work%v, 'v', ErrStat, ErrMsg)
    IF (ErrStat /= CD_MODEL_OK) RETURN
    CALL copy_real1(src%a, work%a, 'a', ErrStat, ErrMsg)
    IF (ErrStat /= CD_MODEL_OK) RETURN
    CALL copy_real1(src%q_step, work%q_step, 'q_step', ErrStat, ErrMsg)
    IF (ErrStat /= CD_MODEL_OK) RETURN
    CALL copy_real1(src%v_step, work%v_step, 'v_step', ErrStat, ErrMsg)
    IF (ErrStat /= CD_MODEL_OK) RETURN
    CALL copy_real1(src%a_step, work%a_step, 'a_step', ErrStat, ErrMsg)
    IF (ErrStat /= CD_MODEL_OK) RETURN
    CALL copy_real1(src%q_prescribed_work, work%q_prescribed_work, 'q_prescribed_work', ErrStat, ErrMsg)
    IF (ErrStat /= CD_MODEL_OK) RETURN
    CALL copy_real1(src%v_prescribed_work, work%v_prescribed_work, 'v_prescribed_work', ErrStat, ErrMsg)
    IF (ErrStat /= CD_MODEL_OK) RETURN
    CALL copy_real1(src%a_prescribed_work, work%a_prescribed_work, 'a_prescribed_work', ErrStat, ErrMsg)
    IF (ErrStat /= CD_MODEL_OK) RETURN
    CALL copy_real1(src%q_rollback, work%q_rollback, 'q_rollback', ErrStat, ErrMsg)
    IF (ErrStat /= CD_MODEL_OK) RETURN
    CALL copy_real1(src%v_rollback, work%v_rollback, 'v_rollback', ErrStat, ErrMsg)
    IF (ErrStat /= CD_MODEL_OK) RETURN
    CALL copy_real1(src%a_rollback, work%a_rollback, 'a_rollback', ErrStat, ErrMsg)
    IF (ErrStat /= CD_MODEL_OK) RETURN
    CALL copy_real1(src%recovery_q0, work%recovery_q0, 'recovery_q0', ErrStat, ErrMsg)
    IF (ErrStat /= CD_MODEL_OK) RETURN
    CALL copy_real1(src%recovery_v0, work%recovery_v0, 'recovery_v0', ErrStat, ErrMsg)
    IF (ErrStat /= CD_MODEL_OK) RETURN
    CALL copy_real1(src%recovery_a0, work%recovery_a0, 'recovery_a0', ErrStat, ErrMsg)
    IF (ErrStat /= CD_MODEL_OK) RETURN
    CALL copy_real1(src%f_ext_rollback, work%f_ext_rollback, 'f_ext_rollback', ErrStat, ErrMsg)
    IF (ErrStat /= CD_MODEL_OK) RETURN
    CALL copy_int1(src%free_map_work, work%free_map_work, 'free_map_work', ErrStat, ErrMsg)
    IF (ErrStat /= CD_MODEL_OK) RETURN

    CALL copy_real1(src%seabed_kn, work%seabed_kn, 'seabed_kn', ErrStat, ErrMsg)
    IF (ErrStat /= CD_MODEL_OK) RETURN
    CALL copy_real1(src%seabed_cn, work%seabed_cn, 'seabed_cn', ErrStat, ErrMsg)
    IF (ErrStat /= CD_MODEL_OK) RETURN
    IF (src%has_bathymetry) THEN
      IF (.NOT. CD_Bathymetry_Is_Initialized(src%bathymetry)) THEN
        ErrStat = CD_MODEL_BADINPUT
        ErrMsg = 'CableDyn_Model: source model has uninitialized bathymetry'
        RETURN
      END IF
      CALL CD_Init_Bathymetry(work%bathymetry, src%bathymetry%x, src%bathymetry%y, src%bathymetry%depth, es, em)
      IF (es /= CD_BATHY_OK) THEN
        ErrStat = CD_MODEL_ALLOCFAIL
        ErrMsg = 'CableDyn_Model: bathymetry copy failed: '//TRIM(em)
        RETURN
      END IF
    END IF
    CALL copy_real1(src%ba, work%ba, 'ba', ErrStat, ErrMsg)
    IF (ErrStat /= CD_MODEL_OK) RETURN
    CALL copy_real1(src%ba_dyn, work%ba_dyn, 'ba_dyn', ErrStat, ErrMsg)
    IF (ErrStat /= CD_MODEL_OK) RETURN
    CALL copy_real1(src%ea_dyn, work%ea_dyn, 'ea_dyn', ErrStat, ErrMsg)
    IF (ErrStat /= CD_MODEL_OK) RETURN
    CALL copy_int1(src%ve_mode, work%ve_mode, 've_mode', ErrStat, ErrMsg)
    IF (ErrStat /= CD_MODEL_OK) RETURN
    CALL copy_real1(src%ve_alpha_mbl, work%ve_alpha_mbl, 've_alpha_mbl', ErrStat, ErrMsg)
    IF (ErrStat /= CD_MODEL_OK) RETURN
    CALL copy_real1(src%ve_vbeta, work%ve_vbeta, 've_vbeta', ErrStat, ErrMsg)
    IF (ErrStat /= CD_MODEL_OK) RETURN
    CALL copy_real1(src%ve_ea_d, work%ve_ea_d, 've_ea_d', ErrStat, ErrMsg)
    IF (ErrStat /= CD_MODEL_OK) RETURN
    CALL copy_real1(src%ve_ea_1, work%ve_ea_1, 've_ea_1', ErrStat, ErrMsg)
    IF (ErrStat /= CD_MODEL_OK) RETURN
    CALL copy_real1(src%ve_ba, work%ve_ba, 've_ba', ErrStat, ErrMsg)
    IF (ErrStat /= CD_MODEL_OK) RETURN
    CALL copy_real1(src%ve_ba_d, work%ve_ba_d, 've_ba_d', ErrStat, ErrMsg)
    IF (ErrStat /= CD_MODEL_OK) RETURN
    CALL copy_real1(src%ve_dl_1, work%ve_dl_1, 've_dl_1', ErrStat, ErrMsg)
    IF (ErrStat /= CD_MODEL_OK) RETURN
    CALL copy_real1(src%ve_dl_1_rollback, work%ve_dl_1_rollback, 've_dl_1_rollback', ErrStat, ErrMsg)
    IF (ErrStat /= CD_MODEL_OK) RETURN
    CALL copy_real1(src%recovery_ve_dl_1, work%recovery_ve_dl_1, 'recovery_ve_dl_1', ErrStat, ErrMsg)
    IF (ErrStat /= CD_MODEL_OK) RETURN
    CALL copy_syrope_types(src%syrope_type, work%syrope_type, ErrStat, ErrMsg)
    IF (ErrStat /= CD_MODEL_OK) RETURN
    CALL copy_logical1(src%syrope_is, work%syrope_is, 'syrope_is', ErrStat, ErrMsg)
    IF (ErrStat /= CD_MODEL_OK) RETURN
    CALL copy_real1(src%syrope_slow, work%syrope_slow, 'syrope_slow', ErrStat, ErrMsg)
    IF (ErrStat /= CD_MODEL_OK) RETURN
    CALL copy_real1(src%syrope_slow_rollback, work%syrope_slow_rollback, 'syrope_slow_rollback', ErrStat, ErrMsg)
    IF (ErrStat /= CD_MODEL_OK) RETURN
    CALL copy_real1(src%syrope_tmax, work%syrope_tmax, 'syrope_tmax', ErrStat, ErrMsg)
    IF (ErrStat /= CD_MODEL_OK) RETURN
    CALL copy_real1(src%syrope_tmax_rollback, work%syrope_tmax_rollback, 'syrope_tmax_rollback', ErrStat, ErrMsg)
    IF (ErrStat /= CD_MODEL_OK) RETURN
    CALL copy_real1(src%recovery_syrope_slow, work%recovery_syrope_slow, 'recovery_syrope_slow', ErrStat, ErrMsg)
    IF (ErrStat /= CD_MODEL_OK) RETURN
    CALL copy_real1(src%recovery_syrope_tmax, work%recovery_syrope_tmax, 'recovery_syrope_tmax', ErrStat, ErrMsg)
    IF (ErrStat /= CD_MODEL_OK) RETURN
    CALL copy_real2(src%fr_anchor, work%fr_anchor, 'fr_anchor', ErrStat, ErrMsg)
    IF (ErrStat /= CD_MODEL_OK) RETURN
    CALL copy_real2(src%fr_anchor_rollback, work%fr_anchor_rollback, 'fr_anchor_rollback', ErrStat, ErrMsg)
    IF (ErrStat /= CD_MODEL_OK) RETURN
    CALL copy_real2(src%recovery_fr_anchor, work%recovery_fr_anchor, 'recovery_fr_anchor', ErrStat, ErrMsg)
    IF (ErrStat /= CD_MODEL_OK) RETURN
    CALL copy_real2(src%fluid_velocity, work%fluid_velocity, 'fluid_velocity', ErrStat, ErrMsg)
    IF (ErrStat /= CD_MODEL_OK) RETURN
    CALL copy_real1(src%drag_waterline_z, work%drag_waterline_z, 'drag_waterline_z', ErrStat, ErrMsg)
    IF (ErrStat /= CD_MODEL_OK) RETURN
    CALL copy_real1(src%drag_diameter_elem, work%drag_diameter_elem, 'drag_diameter_elem', ErrStat, ErrMsg)
    IF (ErrStat /= CD_MODEL_OK) RETURN
    CALL copy_real1(src%drag_cdn_elem, work%drag_cdn_elem, 'drag_cdn_elem', ErrStat, ErrMsg)
    IF (ErrStat /= CD_MODEL_OK) RETURN
    CALL copy_real1(src%drag_cdt_elem, work%drag_cdt_elem, 'drag_cdt_elem', ErrStat, ErrMsg)
    IF (ErrStat /= CD_MODEL_OK) RETURN
    CALL copy_real2(src%fluid_acceleration, work%fluid_acceleration, 'fluid_acceleration', ErrStat, ErrMsg)
    IF (ErrStat /= CD_MODEL_OK) RETURN
    CALL copy_real1(src%fk_waterline_z, work%fk_waterline_z, 'fk_waterline_z', ErrStat, ErrMsg)
    IF (ErrStat /= CD_MODEL_OK) RETURN
    CALL copy_real1(src%fk_diameter_elem, work%fk_diameter_elem, 'fk_diameter_elem', ErrStat, ErrMsg)
    IF (ErrStat /= CD_MODEL_OK) RETURN
    CALL copy_real1(src%fk_can_elem, work%fk_can_elem, 'fk_can_elem', ErrStat, ErrMsg)
    IF (ErrStat /= CD_MODEL_OK) RETURN
    CALL copy_real1(src%fk_cat_elem, work%fk_cat_elem, 'fk_cat_elem', ErrStat, ErrMsg)
    IF (ErrStat /= CD_MODEL_OK) RETURN
    CALL copy_real1(src%buoyancy_waterline_z, work%buoyancy_waterline_z, 'buoyancy_waterline_z', ErrStat, ErrMsg)
    IF (ErrStat /= CD_MODEL_OK) RETURN
    CALL copy_real1(src%buoyancy_diameter_elem, work%buoyancy_diameter_elem, 'buoyancy_diameter_elem', ErrStat, ErrMsg)
    IF (ErrStat /= CD_MODEL_OK) RETURN
    CALL copy_real1(src%added_mass_waterline_z, work%added_mass_waterline_z, 'added_mass_waterline_z', ErrStat, ErrMsg)
    IF (ErrStat /= CD_MODEL_OK) RETURN
    CALL copy_real1(src%added_mass_diameter_elem, work%added_mass_diameter_elem, 'added_mass_diameter_elem', ErrStat, &
                    ErrMsg)
    IF (ErrStat /= CD_MODEL_OK) RETURN
    CALL copy_real1(src%added_mass_can_elem, work%added_mass_can_elem, 'added_mass_can_elem', ErrStat, ErrMsg)
    IF (ErrStat /= CD_MODEL_OK) RETURN
    CALL copy_real1(src%added_mass_cat_elem, work%added_mass_cat_elem, 'added_mass_cat_elem', ErrStat, ErrMsg)
    IF (ErrStat /= CD_MODEL_OK) RETURN
    work%has_viv = src%has_viv
    work%viv_rho = src%viv_rho
    work%viv_tw = src%viv_tw
    work%viv_phi_rest = src%viv_phi_rest
    CALL copy_real1(src%viv_cl, work%viv_cl, 'viv_cl', ErrStat, ErrMsg)
    IF (ErrStat /= CD_MODEL_OK) RETURN
    CALL copy_real1(src%viv_d, work%viv_d, 'viv_d', ErrStat, ErrMsg)
    IF (ErrStat /= CD_MODEL_OK) RETURN
    CALL copy_logical1(src%viv_node, work%viv_node, 'viv_node', ErrStat, ErrMsg)
    IF (ErrStat /= CD_MODEL_OK) RETURN
    CALL copy_real1(src%viv_cf, work%viv_cf, 'viv_cf', ErrStat, ErrMsg)
    IF (ErrStat /= CD_MODEL_OK) RETURN
    CALL copy_real1(src%viv_df, work%viv_df, 'viv_df', ErrStat, ErrMsg)
    IF (ErrStat /= CD_MODEL_OK) RETURN
    CALL copy_real1(src%viv_dn, work%viv_dn, 'viv_dn', ErrStat, ErrMsg)
    IF (ErrStat /= CD_MODEL_OK) RETURN
    CALL copy_real1(src%viv_phi, work%viv_phi, 'viv_phi', ErrStat, ErrMsg)
    IF (ErrStat /= CD_MODEL_OK) RETURN
    CALL copy_real2(src%viv_ms, work%viv_ms, 'viv_ms', ErrStat, ErrMsg)
    IF (ErrStat /= CD_MODEL_OK) RETURN
    CALL copy_real1(src%viv_phi_rollback, work%viv_phi_rollback, 'viv_phi_rollback', ErrStat, ErrMsg)
    IF (ErrStat /= CD_MODEL_OK) RETURN
    CALL copy_real2(src%viv_ms_rollback, work%viv_ms_rollback, 'viv_ms_rollback', ErrStat, ErrMsg)
    IF (ErrStat /= CD_MODEL_OK) RETURN
    CALL copy_real1(src%recovery_viv_phi, work%recovery_viv_phi, 'recovery_viv_phi', ErrStat, ErrMsg)
    IF (ErrStat /= CD_MODEL_OK) RETURN
    CALL copy_real2(src%recovery_viv_ms, work%recovery_viv_ms, 'recovery_viv_ms', ErrStat, ErrMsg)
    IF (ErrStat /= CD_MODEL_OK) RETURN
    CALL copy_real1(src%viv_phi_eval, work%viv_phi_eval, 'viv_phi_eval', ErrStat, ErrMsg)
    IF (ErrStat /= CD_MODEL_OK) RETURN
    CALL copy_real1(src%viv_rate, work%viv_rate, 'viv_rate', ErrStat, ErrMsg)
    IF (ErrStat /= CD_MODEL_OK) RETURN
    CALL copy_real2(src%viv_ms_next, work%viv_ms_next, 'viv_ms_next', ErrStat, ErrMsg)
    IF (ErrStat /= CD_MODEL_OK) RETURN
    CALL copy_real1(src%viv_phi_next, work%viv_phi_next, 'viv_phi_next', ErrStat, ErrMsg)
    IF (ErrStat /= CD_MODEL_OK) RETURN

    work%initialized = src%initialized
    ! Commit: release the caller's previous model, then move the fully-built copy in component by
    ! component. MOVE_ALLOC cannot fail, so the commit itself cannot abort under memory pressure --
    ! an intrinsic dst = work would re-allocate every allocatable component again without STAT.
    CALL CD_End_Model(dst, es, em)
    CALL commit_model_copy(work, dst)
  END SUBROUTINE CD_Copy_Model

  SUBROUTINE commit_model_copy(from, to)
    !! Move every persistent component of a freshly-built model copy into the just-ended destination
    !! without reallocating: scalars are assigned and allocatable arrays (plus the bathymetry grid)
    !! are transferred with MOVE_ALLOC. The transient solver scratch (dynamic_workspace, load_*_work)
    !! is intentionally not carried, matching CD_Copy_Model. The component list mirrors the type
    !! definition and CD_End_Model; every state- or load-bearing field must be moved here, and the
    !! model-copy regression test checks that none is dropped.
    TYPE(CD_ModelType), INTENT(INOUT) :: from
    TYPE(CD_ModelType), INTENT(INOUT) :: to

    to%initialized = from%initialized
    to%tension_only = from%tension_only
    to%azimuth_signed = from%azimuth_signed
    to%n_dof = from%n_dof
    to%n_elem = from%n_elem
    to%has_seabed = from%has_seabed
    to%has_bathymetry = from%has_bathymetry
    to%seabed_z_floor = from%seabed_z_floor
    to%has_seabed_damping = from%has_seabed_damping
    to%has_seabed_friction = from%has_seabed_friction
    to%seabed_mu = from%seabed_mu
    to%seabed_friction_aniso = from%seabed_friction_aniso
    to%seabed_mu_axial = from%seabed_mu_axial
    to%has_seabed_recompute = from%has_seabed_recompute
    to%seabed_kbot = from%seabed_kbot
    to%seabed_cn_over_kn = from%seabed_cn_over_kn
    CALL MOVE_ALLOC(from%seabed_diameter_elem, to%seabed_diameter_elem)
    to%has_damping = from%has_damping
    to%has_viscoelastic = from%has_viscoelastic
    to%ve_dt = from%ve_dt
    to%has_syrope = from%has_syrope
    to%has_morison_drag = from%has_morison_drag
    to%drag_rho = from%drag_rho
    to%drag_diameter = from%drag_diameter
    to%drag_cdn = from%drag_cdn
    to%drag_cdt = from%drag_cdt
    to%has_froude_krylov = from%has_froude_krylov
    to%fk_rho = from%fk_rho
    to%fk_diameter = from%fk_diameter
    to%fk_can = from%fk_can
    to%fk_cat = from%fk_cat
    to%has_buoyancy_recovery = from%has_buoyancy_recovery
    to%buoyancy_rho = from%buoyancy_rho
    to%buoyancy_diameter = from%buoyancy_diameter
    to%buoyancy_gravity = from%buoyancy_gravity
    to%has_added_mass = from%has_added_mass
    to%added_mass_rho = from%added_mass_rho
    to%added_mass_diameter = from%added_mass_diameter
    to%added_mass_can = from%added_mass_can
    to%added_mass_cat = from%added_mass_cat
    to%cfg = from%cfg
    to%sub_t_init = from%sub_t_init

    CALL MOVE_ALLOC(from%elem_conn, to%elem_conn)
    CALL MOVE_ALLOC(from%fixed_dofs, to%fixed_dofs)
    CALL MOVE_ALLOC(from%l0, to%l0)
    CALL MOVE_ALLOC(from%ea, to%ea)
    CALL MOVE_ALLOC(from%rho_a, to%rho_a)
    CALL MOVE_ALLOC(from%l0_dot, to%l0_dot)
    CALL MOVE_ALLOC(from%l0_c, to%l0_c)
    CALL MOVE_ALLOC(from%l0_dot_c, to%l0_dot_c)
    CALL MOVE_ALLOC(from%l0_c_rollback, to%l0_c_rollback)
    CALL MOVE_ALLOC(from%l0_dot_c_rollback, to%l0_dot_c_rollback)
    CALL MOVE_ALLOC(from%recovery_l0_c, to%recovery_l0_c)
    CALL MOVE_ALLOC(from%recovery_l0_dot_c, to%recovery_l0_dot_c)
    CALL MOVE_ALLOC(from%dist_load, to%dist_load)
    CALL MOVE_ALLOC(from%f_ext_dist_base, to%f_ext_dist_base)
    CALL MOVE_ALLOC(from%f_ext, to%f_ext)
    CALL MOVE_ALLOC(from%q, to%q)
    CALL MOVE_ALLOC(from%v, to%v)
    CALL MOVE_ALLOC(from%a, to%a)
    CALL MOVE_ALLOC(from%q_step, to%q_step)
    CALL MOVE_ALLOC(from%v_step, to%v_step)
    CALL MOVE_ALLOC(from%a_step, to%a_step)
    CALL MOVE_ALLOC(from%q_prescribed_work, to%q_prescribed_work)
    CALL MOVE_ALLOC(from%v_prescribed_work, to%v_prescribed_work)
    CALL MOVE_ALLOC(from%a_prescribed_work, to%a_prescribed_work)
    CALL MOVE_ALLOC(from%q_rollback, to%q_rollback)
    CALL MOVE_ALLOC(from%v_rollback, to%v_rollback)
    CALL MOVE_ALLOC(from%a_rollback, to%a_rollback)
    CALL MOVE_ALLOC(from%recovery_q0, to%recovery_q0)
    CALL MOVE_ALLOC(from%recovery_v0, to%recovery_v0)
    CALL MOVE_ALLOC(from%recovery_a0, to%recovery_a0)
    CALL MOVE_ALLOC(from%f_ext_rollback, to%f_ext_rollback)
    CALL MOVE_ALLOC(from%free_map_work, to%free_map_work)
    CALL MOVE_ALLOC(from%seabed_kn, to%seabed_kn)
    CALL MOVE_ALLOC(from%seabed_cn, to%seabed_cn)
    CALL MOVE_ALLOC(from%ba, to%ba)
    CALL MOVE_ALLOC(from%ba_dyn, to%ba_dyn)
    CALL MOVE_ALLOC(from%ea_dyn, to%ea_dyn)
    CALL MOVE_ALLOC(from%ve_mode, to%ve_mode)
    CALL MOVE_ALLOC(from%ve_alpha_mbl, to%ve_alpha_mbl)
    CALL MOVE_ALLOC(from%ve_vbeta, to%ve_vbeta)
    CALL MOVE_ALLOC(from%ve_ea_d, to%ve_ea_d)
    CALL MOVE_ALLOC(from%ve_ea_1, to%ve_ea_1)
    CALL MOVE_ALLOC(from%ve_ba, to%ve_ba)
    CALL MOVE_ALLOC(from%ve_ba_d, to%ve_ba_d)
    CALL MOVE_ALLOC(from%ve_dl_1, to%ve_dl_1)
    CALL MOVE_ALLOC(from%ve_dl_1_rollback, to%ve_dl_1_rollback)
    CALL MOVE_ALLOC(from%recovery_ve_dl_1, to%recovery_ve_dl_1)
    CALL MOVE_ALLOC(from%syrope_is, to%syrope_is)
    CALL MOVE_ALLOC(from%syrope_type, to%syrope_type)
    CALL MOVE_ALLOC(from%syrope_slow, to%syrope_slow)
    CALL MOVE_ALLOC(from%syrope_slow_rollback, to%syrope_slow_rollback)
    CALL MOVE_ALLOC(from%syrope_tmax, to%syrope_tmax)
    CALL MOVE_ALLOC(from%syrope_tmax_rollback, to%syrope_tmax_rollback)
    CALL MOVE_ALLOC(from%recovery_syrope_slow, to%recovery_syrope_slow)
    CALL MOVE_ALLOC(from%recovery_syrope_tmax, to%recovery_syrope_tmax)
    CALL MOVE_ALLOC(from%fr_anchor, to%fr_anchor)
    CALL MOVE_ALLOC(from%fr_anchor_rollback, to%fr_anchor_rollback)
    CALL MOVE_ALLOC(from%recovery_fr_anchor, to%recovery_fr_anchor)
    CALL MOVE_ALLOC(from%fluid_velocity, to%fluid_velocity)
    CALL MOVE_ALLOC(from%drag_waterline_z, to%drag_waterline_z)
    CALL MOVE_ALLOC(from%drag_diameter_elem, to%drag_diameter_elem)
    CALL MOVE_ALLOC(from%drag_cdn_elem, to%drag_cdn_elem)
    CALL MOVE_ALLOC(from%drag_cdt_elem, to%drag_cdt_elem)
    CALL MOVE_ALLOC(from%fluid_acceleration, to%fluid_acceleration)
    CALL MOVE_ALLOC(from%fk_waterline_z, to%fk_waterline_z)
    CALL MOVE_ALLOC(from%fk_diameter_elem, to%fk_diameter_elem)
    CALL MOVE_ALLOC(from%fk_can_elem, to%fk_can_elem)
    CALL MOVE_ALLOC(from%fk_cat_elem, to%fk_cat_elem)
    CALL MOVE_ALLOC(from%buoyancy_waterline_z, to%buoyancy_waterline_z)
    CALL MOVE_ALLOC(from%buoyancy_diameter_elem, to%buoyancy_diameter_elem)
    CALL MOVE_ALLOC(from%added_mass_waterline_z, to%added_mass_waterline_z)
    CALL MOVE_ALLOC(from%added_mass_diameter_elem, to%added_mass_diameter_elem)
    CALL MOVE_ALLOC(from%added_mass_can_elem, to%added_mass_can_elem)
    CALL MOVE_ALLOC(from%added_mass_cat_elem, to%added_mass_cat_elem)
    to%has_viv = from%has_viv
    to%viv_rho = from%viv_rho
    to%viv_tw = from%viv_tw
    to%viv_phi_rest = from%viv_phi_rest
    CALL MOVE_ALLOC(from%viv_cl, to%viv_cl)
    CALL MOVE_ALLOC(from%viv_d, to%viv_d)
    CALL MOVE_ALLOC(from%viv_node, to%viv_node)
    CALL MOVE_ALLOC(from%viv_cf, to%viv_cf)
    CALL MOVE_ALLOC(from%viv_df, to%viv_df)
    CALL MOVE_ALLOC(from%viv_dn, to%viv_dn)
    CALL MOVE_ALLOC(from%viv_phi, to%viv_phi)
    CALL MOVE_ALLOC(from%viv_ms, to%viv_ms)
    CALL MOVE_ALLOC(from%viv_phi_rollback, to%viv_phi_rollback)
    CALL MOVE_ALLOC(from%viv_ms_rollback, to%viv_ms_rollback)
    CALL MOVE_ALLOC(from%recovery_viv_phi, to%recovery_viv_phi)
    CALL MOVE_ALLOC(from%recovery_viv_ms, to%recovery_viv_ms)
    CALL MOVE_ALLOC(from%viv_phi_eval, to%viv_phi_eval)
    CALL MOVE_ALLOC(from%viv_rate, to%viv_rate)
    CALL MOVE_ALLOC(from%viv_ms_next, to%viv_ms_next)
    CALL MOVE_ALLOC(from%viv_phi_next, to%viv_phi_next)

    IF (from%has_bathymetry) THEN
      to%bathymetry%nx = from%bathymetry%nx
      to%bathymetry%ny = from%bathymetry%ny
      to%bathymetry%average_depth = from%bathymetry%average_depth
      to%bathymetry%minimum_depth = from%bathymetry%minimum_depth
      CALL MOVE_ALLOC(from%bathymetry%x, to%bathymetry%x)
      CALL MOVE_ALLOC(from%bathymetry%y, to%bathymetry%y)
      CALL MOVE_ALLOC(from%bathymetry%depth, to%bathymetry%depth)
    END IF
  END SUBROUTINE commit_model_copy

  SUBROUTINE copy_int1(src, dst, label, ErrStat, ErrMsg)
    INTEGER, ALLOCATABLE, INTENT(IN) :: src(:)
    INTEGER, ALLOCATABLE, INTENT(INOUT) :: dst(:)
    CHARACTER(*), INTENT(IN) :: label
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg

    INTEGER :: istat

    ErrStat = CD_MODEL_OK
    ErrMsg = ''
    IF (.NOT. ALLOCATED(src)) RETURN
    ALLOCATE (dst(SIZE(src)), SOURCE=src, STAT=istat)
    IF (istat /= 0) CALL copy_alloc_fail(label, ErrStat, ErrMsg)
  END SUBROUTINE copy_int1

  SUBROUTINE copy_logical1(src, dst, label, ErrStat, ErrMsg)
    LOGICAL, ALLOCATABLE, INTENT(IN) :: src(:)
    LOGICAL, ALLOCATABLE, INTENT(INOUT) :: dst(:)
    CHARACTER(*), INTENT(IN) :: label
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg

    INTEGER :: istat

    ErrStat = CD_MODEL_OK
    ErrMsg = ''
    IF (.NOT. ALLOCATED(src)) RETURN
    ALLOCATE (dst(SIZE(src)), SOURCE=src, STAT=istat)
    IF (istat /= 0) CALL copy_alloc_fail(label, ErrStat, ErrMsg)
  END SUBROUTINE copy_logical1

  SUBROUTINE copy_syrope_types(src, dst, ErrStat, ErrMsg)
    !! Deep-copy the per-element Syrope constitutive array. Each element's
    !! allocatable components (the OWC table + its slow-strain column) are
    !! carried by intrinsic derived-type assignment; the outer allocation is
    !! STAT-checked so an out-of-memory copy leaves the destination model whole.
    TYPE(CD_SyropeType), ALLOCATABLE, INTENT(IN) :: src(:)
    TYPE(CD_SyropeType), ALLOCATABLE, INTENT(INOUT) :: dst(:)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg

    INTEGER :: istat, e, es2
    CHARACTER(1024) :: em2

    ErrStat = CD_MODEL_OK
    ErrMsg = ''
    IF (.NOT. ALLOCATED(src)) RETURN
    ALLOCATE (dst(SIZE(src)), STAT=istat)
    IF (istat /= 0) THEN
      CALL copy_alloc_fail('syrope_type', ErrStat, ErrMsg)
      RETURN
    END IF
    ! Re-Init each populated element from the source's own raw inputs: this is
    ! a STAT-checked deep copy (CD_Syrope_Init allocates with STAT and fails
    ! closed), preserving the "dst survives an out-of-memory copy" contract that
    ! an unchecked intrinsic `dst(e) = src(e)` would break. Plain (uninitialized)
    ! entries stay default -- they carry no Syrope element.
    DO e = 1, SIZE(src)
      IF (.NOT. CD_Syrope_Is_Ready(src(e))) CYCLE
      CALL CD_Syrope_Init(dst(e), src(e)%owc_strain, src(e)%owc_tension, src(e)%wc_mod, &
                          src(e)%p1, src(e)%p2, src(e)%alpha, src(e)%beta, src(e)%c1, src(e)%c2, es2, em2)
      IF (es2 /= CD_SYROPE_OK) THEN
        CALL copy_alloc_fail('syrope_type', ErrStat, ErrMsg)
        RETURN
      END IF
    END DO
  END SUBROUTINE copy_syrope_types

  SUBROUTINE copy_int2(src, dst, label, ErrStat, ErrMsg)
    INTEGER, ALLOCATABLE, INTENT(IN) :: src(:, :)
    INTEGER, ALLOCATABLE, INTENT(INOUT) :: dst(:, :)
    CHARACTER(*), INTENT(IN) :: label
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg

    INTEGER :: istat

    ErrStat = CD_MODEL_OK
    ErrMsg = ''
    IF (.NOT. ALLOCATED(src)) RETURN
    ALLOCATE (dst(SIZE(src, 1), SIZE(src, 2)), SOURCE=src, STAT=istat)
    IF (istat /= 0) CALL copy_alloc_fail(label, ErrStat, ErrMsg)
  END SUBROUTINE copy_int2

  SUBROUTINE copy_real1(src, dst, label, ErrStat, ErrMsg)
    REAL(wp), ALLOCATABLE, INTENT(IN) :: src(:)
    REAL(wp), ALLOCATABLE, INTENT(INOUT) :: dst(:)
    CHARACTER(*), INTENT(IN) :: label
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg

    INTEGER :: istat

    ErrStat = CD_MODEL_OK
    ErrMsg = ''
    IF (.NOT. ALLOCATED(src)) RETURN
    ALLOCATE (dst(SIZE(src)), SOURCE=src, STAT=istat)
    IF (istat /= 0) CALL copy_alloc_fail(label, ErrStat, ErrMsg)
  END SUBROUTINE copy_real1

  SUBROUTINE copy_real2(src, dst, label, ErrStat, ErrMsg)
    REAL(wp), ALLOCATABLE, INTENT(IN) :: src(:, :)
    REAL(wp), ALLOCATABLE, INTENT(INOUT) :: dst(:, :)
    CHARACTER(*), INTENT(IN) :: label
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg

    INTEGER :: istat

    ErrStat = CD_MODEL_OK
    ErrMsg = ''
    IF (.NOT. ALLOCATED(src)) RETURN
    ALLOCATE (dst(SIZE(src, 1), SIZE(src, 2)), SOURCE=src, STAT=istat)
    IF (istat /= 0) CALL copy_alloc_fail(label, ErrStat, ErrMsg)
  END SUBROUTINE copy_real2

  SUBROUTINE copy_alloc_fail(label, ErrStat, ErrMsg)
    CHARACTER(*), INTENT(IN) :: label
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg

    ErrStat = CD_MODEL_ALLOCFAIL
    ErrMsg = 'CableDyn_Model: allocation failed while copying '//TRIM(label)
  END SUBROUTINE copy_alloc_fail

  SUBROUTINE restore_after_init_alloc_fail(model, old_model, label, ErrStat, ErrMsg)
    !! Restore a previously valid model if CD_Init_Model cannot allocate the new state.
    TYPE(CD_ModelType), INTENT(INOUT) :: model
    TYPE(CD_ModelType), INTENT(IN) :: old_model
    CHARACTER(*), INTENT(IN) :: label
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg

    INTEGER :: es
    CHARACTER(1024) :: em

    CALL CD_End_Model(model, es, em)
    model = old_model
    ErrStat = CD_MODEL_ALLOCFAIL
    ErrMsg = 'CableDyn_Model: allocation failed while initializing '//TRIM(label)
  END SUBROUTINE restore_after_init_alloc_fail

  INTEGER FUNCTION CD_Model_NCoupledDOF(model, ErrStat, ErrMsg) RESULT(n)
    !! Number of externally prescribed/coupled DOFs currently represented by the
    !! fixed_dofs list. This is the scalar queried by the C/OpenFAST shells before
    !! exchanging kinematics and loads.
    TYPE(CD_ModelType), INTENT(IN) :: model
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg

    IF (.NOT. model%initialized) THEN
      n = 0
      ErrStat = CD_MODEL_NOT_INITIALIZED
      ErrMsg = 'CableDyn_Model: model is not initialized'
      RETURN
    END IF
    n = SIZE(model%fixed_dofs)
    ErrStat = CD_MODEL_OK
    ErrMsg = ''
  END FUNCTION CD_Model_NCoupledDOF

  INTEGER FUNCTION CD_Model_NDOF(model, ErrStat, ErrMsg) RESULT(n)
    !! Total positions-only state size, 3*n_nodes. Shells use this before
    !! allocating q/v/a arrays for CD_Get_Model_State.
    TYPE(CD_ModelType), INTENT(IN) :: model
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg

    IF (.NOT. model%initialized) THEN
      n = 0
      ErrStat = CD_MODEL_NOT_INITIALIZED
      ErrMsg = 'CableDyn_Model: model is not initialized'
      RETURN
    END IF
    n = model%n_dof
    ErrStat = CD_MODEL_OK
    ErrMsg = ''
  END FUNCTION CD_Model_NDOF

  INTEGER FUNCTION CD_Model_NElem(model, ErrStat, ErrMsg) RESULT(n)
    !! Number of line elements owned by the model. Useful for shell-side diagnostics
    !! and output allocation.
    TYPE(CD_ModelType), INTENT(IN) :: model
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg

    IF (.NOT. model%initialized) THEN
      n = 0
      ErrStat = CD_MODEL_NOT_INITIALIZED
      ErrMsg = 'CableDyn_Model: model is not initialized'
      RETURN
    END IF
    n = model%n_elem
    ErrStat = CD_MODEL_OK
    ErrMsg = ''
  END FUNCTION CD_Model_NElem

  SUBROUTINE CD_Get_Model_CoupledDofs(model, coupled_dofs, ErrStat, ErrMsg)
    !! Copy the 1-based externally prescribed/coupled DOF map. The EI=0 model
    !! represents coupled endpoints through the fixed_dofs list; shells query this
    !! accessor rather than CD_ModelType internals.
    TYPE(CD_ModelType), INTENT(IN) :: model
    INTEGER, INTENT(OUT) :: coupled_dofs(:)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg

    coupled_dofs = 0
    ErrStat = CD_MODEL_OK
    ErrMsg = ''
    IF (.NOT. model%initialized) THEN
      ErrStat = CD_MODEL_NOT_INITIALIZED
      ErrMsg = 'CableDyn_Model: model is not initialized'
      RETURN
    END IF
    IF (SIZE(coupled_dofs) /= SIZE(model%fixed_dofs)) THEN
      CALL fail(ErrStat, ErrMsg, 'coupled_dofs output must have shape (n_coupled_dof)')
      RETURN
    END IF
    coupled_dofs = model%fixed_dofs
  END SUBROUTINE CD_Get_Model_CoupledDofs

  SUBROUTINE CD_Get_Model_CoupledMotion(model, q_coupled, v_coupled, a_coupled, ErrStat, ErrMsg)
    !! Copy the current coupled-DOF state in the same compact ordering returned
    !! by CD_Get_Model_CoupledDofs and accepted by CD_Update_Model_CoupledMotion.
    TYPE(CD_ModelType), INTENT(IN) :: model
    REAL(wp), INTENT(OUT) :: q_coupled(:), v_coupled(:), a_coupled(:)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg

    INTEGER :: n, i

    q_coupled = CD_ZERO
    v_coupled = CD_ZERO
    a_coupled = CD_ZERO
    ErrStat = CD_MODEL_OK
    ErrMsg = ''
    IF (.NOT. model%initialized) THEN
      ErrStat = CD_MODEL_NOT_INITIALIZED
      ErrMsg = 'CableDyn_Model: model is not initialized'
      RETURN
    END IF
    n = SIZE(model%fixed_dofs)
    IF (SIZE(q_coupled) /= n .OR. SIZE(v_coupled) /= n .OR. SIZE(a_coupled) /= n) THEN
      CALL fail(ErrStat, ErrMsg, 'coupled motion outputs must have shape (n_coupled_dof)')
      RETURN
    END IF
    DO i = 1, n
      q_coupled(i) = model%q(model%fixed_dofs(i))
      v_coupled(i) = model%v(model%fixed_dofs(i))
      a_coupled(i) = model%a(model%fixed_dofs(i))
    END DO
  END SUBROUTINE CD_Get_Model_CoupledMotion

  LOGICAL FUNCTION CD_Model_Is_Initialized(model) RESULT(is_initialized)
    !! Query-only helper for shells and tests.
    TYPE(CD_ModelType), INTENT(IN) :: model
    is_initialized = model%initialized
  END FUNCTION CD_Model_Is_Initialized

  SUBROUTINE ensure_model_load_contributor_workspace(model, n, ErrStat, ErrMsg)
    !! Grow reusable dense contributor scratch used by model_contributor_load.
    TYPE(CD_ModelType), INTENT(INOUT) :: model
    INTEGER, INTENT(IN) :: n
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg

    INTEGER :: istat
    LOGICAL :: need_workspace

    ErrStat = CD_MODEL_OK
    ErrMsg = ''
    IF (n < 0) THEN
      CALL fail(ErrStat, ErrMsg, 'load contributor workspace size must be non-negative')
      RETURN
    END IF
    need_workspace = .NOT. ALLOCATED(model%load_force_work)
    IF (.NOT. need_workspace) need_workspace = SIZE(model%load_force_work) < n
    IF (need_workspace) THEN
      CALL clear_model_load_contributor_workspace(model)
      ALLOCATE (model%load_force_work(n), STAT=istat)
      IF (istat /= 0) THEN
        CALL load_workspace_alloc_fail(model, ErrStat, ErrMsg)
        RETURN
      END IF
      ALLOCATE (model%load_jq_work(n, n), STAT=istat)
      IF (istat /= 0) THEN
        CALL load_workspace_alloc_fail(model, ErrStat, ErrMsg)
        RETURN
      END IF
      ALLOCATE (model%load_jv_work(n, n), STAT=istat)
      IF (istat /= 0) THEN
        CALL load_workspace_alloc_fail(model, ErrStat, ErrMsg)
        RETURN
      END IF
    END IF
  END SUBROUTINE ensure_model_load_contributor_workspace

  SUBROUTINE load_workspace_alloc_fail(model, ErrStat, ErrMsg)
    TYPE(CD_ModelType), INTENT(INOUT) :: model
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg

    CALL clear_model_load_contributor_workspace(model)
    ErrStat = CD_MODEL_ALLOCFAIL
    ErrMsg = 'CableDyn_Model: load contributor workspace allocation failed'
  END SUBROUTINE load_workspace_alloc_fail

  SUBROUTINE clear_model_load_contributor_workspace(model)
    TYPE(CD_ModelType), INTENT(INOUT) :: model

    IF (ALLOCATED(model%load_force_work)) DEALLOCATE (model%load_force_work)
    IF (ALLOCATED(model%load_jq_work)) DEALLOCATE (model%load_jq_work)
    IF (ALLOCATED(model%load_jv_work)) DEALLOCATE (model%load_jv_work)
    IF (ALLOCATED(model%load_start_work)) DEALLOCATE (model%load_start_work)
    IF (ALLOCATED(model%tension_start_work)) DEALLOCATE (model%tension_start_work)
    IF (ALLOCATED(model%stiffness_start_work)) DEALLOCATE (model%stiffness_start_work)
    model%load_start_valid = .FALSE.
  END SUBROUTINE clear_model_load_contributor_workspace

  PURE LOGICAL FUNCTION mode3_marked(alpha_mbl, e) RESULT(marked)
    !! Safe probe of the OPTIONAL load-dependent marker array (nested guard --
    !! never short-circuit on an absent OPTIONAL).
    REAL(wp), INTENT(IN), OPTIONAL :: alpha_mbl(:)
    INTEGER, INTENT(IN) :: e
    marked = .FALSE.
    IF (PRESENT(alpha_mbl)) marked = alpha_mbl(e) > CD_ZERO
  END FUNCTION mode3_marked

  SUBROUTINE model_viscoelastic_coeffs(model, e, ea_d_eff, ea_1_eff, ErrStat, ErrMsg)
    !! The effective series-Kelvin stiffness pair of one viscoelastic element: mode 2
    !! returns the stored constants; mode 3 evaluates MoorDyn's mean-load-
    !! dependent EA_D at the COMMITTED dl_1 (lagged over the step -- constant
    !! within it, so the elimination Jacobians remain exact for the lagged
    !! operator) and derives EA_1 from it. Fails closed if the mode-3 premise
    !! is violated at the current state.
    TYPE(CD_ModelType), INTENT(IN) :: model
    INTEGER, INTENT(IN) :: e
    REAL(wp), INTENT(OUT) :: ea_d_eff, ea_1_eff
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    INTEGER :: es
    CHARACTER(200) :: em
    ErrStat = CD_MODEL_OK
    ErrMsg = ''
    ea_d_eff = CD_ZERO
    ea_1_eff = CD_ZERO
    SELECT CASE (model%ve_mode(e))
    CASE (2)
      ea_d_eff = model%ve_ea_d(e)
      ea_1_eff = model%ve_ea_1(e)
    CASE (3)
      CALL CD_Viscoelastic_LoadDependent_EAD(model%ea(e), model%l0(e), model%ve_alpha_mbl(e), &
                                             model%ve_vbeta(e), model%ve_dl_1(e), ea_d_eff, es, em)
      IF (es /= CD_VISCO_OK) THEN
        ErrStat = CD_MODEL_SOLVEFAIL
        ErrMsg = 'CableDyn_Model: '//TRIM(em)
        RETURN
      END IF
      ea_1_eff = ea_d_eff*model%ea(e)/(ea_d_eff - model%ea(e))
    CASE DEFAULT
      CALL fail(ErrStat, ErrMsg, 'viscoelastic coefficients requested for a plain element')
    END SELECT
  END SUBROUTINE model_viscoelastic_coeffs

  SUBROUTINE model_syrope_element(model, e, q2, v2, force, jac_q, jac_v, t_mean, dslow, ErrStat, ErrMsg)
    !! One Syrope element's production MoorDyn force and position/velocity
    !! Jacobians. Regenerates the working curve from the committed running maximum,
    !! selects the branch by the evaluated slow strain vs the branch divider at
    !! that maximum, and calls the element load. Inside a step (ve_dt > 0) the
    !! slow strain is eliminated by the same backward-Euler solve the commit makes;
    !! outside (ve_dt = 0) the committed state is used as is. The slow strain is the committed
    !! one at the element's present length (model_syrope_slow).
    TYPE(CD_ModelType), INTENT(IN) :: model
    INTEGER, INTENT(IN) :: e
    REAL(wp), INTENT(IN) :: q2(6), v2(6)
    REAL(wp), INTENT(OUT) :: force(6), jac_q(6, 6), jac_v(6, 6), t_mean, dslow
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    REAL(wp) :: ws(CD_SYROPE_NWC), wt(CD_SYROPE_NWC), wsl(CD_SYROPE_NWC), slow_at, slow
    LOGICAL :: on_wc
    INTEGER :: es
    CHARACTER(200) :: em
    force = CD_ZERO
    jac_q = CD_ZERO
    jac_v = CD_ZERO
    t_mean = CD_ZERO
    dslow = CD_ZERO
    CALL CD_Syrope_Working_Curve(model%syrope_type(e), model%syrope_tmax(e), ws, wt, wsl, es, em)
    IF (es /= CD_SYROPE_OK) THEN
      CALL fail(ErrStat, ErrMsg, TRIM(em)); RETURN
    END IF
    ! the branch follows the evaluated slow strain against the continuous divider
    slow_at = CD_Syrope_Branch_Divider(model%syrope_type(e), model%syrope_tmax(e))
    slow = model_syrope_slow(model, e)
    on_wc = slow < slow_at
    CALL CD_Syrope_Element_Load(q2(1:3), q2(4:6), v2(1:3), v2(4:6), model%l0(e), model%syrope_type(e), &
                                ws, wt, wsl, on_wc, slow, model%tension_only, &
                                force, jac_q, t_mean, dslow, es, em, jac_v=jac_v, dt=model%ve_dt, &
                                divider=slow_at)
    IF (es /= CD_SYROPE_OK) THEN
      CALL fail(ErrStat, ErrMsg, TRIM(em)); RETURN
    END IF
    ErrStat = CD_MODEL_OK
    ErrMsg = ''
  END SUBROUTINE model_syrope_element

  SUBROUTINE model_syrope_state_next(model, e, q2, v2, dt, slow_next, t_mean, ErrStat, ErrMsg)
    !! Evaluate the backward-Euler Syrope state candidate without mutation. The
    !! caller invokes this for every element before the atomic commit pass. The
    !! candidate comes from the element load's own implicit elimination, so the
    !! committed slow strain is bit-identical to the one the converged in-step
    !! force was evaluated at. A candidate beyond the OWC table fails the step. The advance
    !! starts from the committed slow strain at the element's present length
    !! (model_syrope_slow), so after a length change it integrates MoorDyn's slow stretch.
    TYPE(CD_ModelType), INTENT(IN) :: model
    INTEGER, INTENT(IN) :: e
    REAL(wp), INTENT(IN) :: q2(6), v2(6), dt
    REAL(wp), INTENT(OUT) :: slow_next, t_mean
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    REAL(wp) :: ws(CD_SYROPE_NWC), wt(CD_SYROPE_NWC), wsl(CD_SYROPE_NWC)
    REAL(wp) :: chord(3), length, eps, slow_at, f6(6), jq6(6, 6), dslow, slow
    LOGICAL :: on_wc
    INTEGER :: es
    CHARACTER(200) :: em

    slow = model_syrope_slow(model, e)
    slow_next = slow
    t_mean = CD_ZERO
    chord = q2(4:6) - q2(1:3)
    length = NORM2(chord)
    IF (length <= CD_VISCO_TINY_LEN) THEN
      CALL fail(ErrStat, ErrMsg, 'Syrope state advance found a collapsed element')
      RETURN
    END IF
    IF (.NOT. (dt > CD_ZERO)) THEN
      CALL fail(ErrStat, ErrMsg, 'Syrope state advance needs dt > 0')
      RETURN
    END IF
    eps = (length - model%l0(e))/model%l0(e)
    CALL CD_Syrope_Working_Curve(model%syrope_type(e), model%syrope_tmax(e), ws, wt, wsl, es, em)
    IF (es /= CD_SYROPE_OK) THEN
      CALL fail(ErrStat, ErrMsg, TRIM(em)); RETURN
    END IF
    slow_at = CD_Syrope_Branch_Divider(model%syrope_type(e), model%syrope_tmax(e))
    on_wc = slow < slow_at
    CALL CD_Syrope_Element_Load(q2(1:3), q2(4:6), v2(1:3), v2(4:6), model%l0(e), model%syrope_type(e), &
                                ws, wt, wsl, on_wc, slow, model%tension_only, &
                                f6, jq6, t_mean, dslow, es, em, dt=dt, slow_next=slow_next, divider=slow_at)
    IF (es /= CD_SYROPE_OK) THEN
      CALL fail(ErrStat, ErrMsg, TRIM(em)); RETURN
    END IF
    ! the interpolation clamps at the last OWC row, so a state past it would run on
    ! with a silently wrong tension and unbounded slow-strain creep: fail closed
    ! (the total-strain bound applies on the OWC branch of the new state)
    IF (slow_next < slow_at) THEN
      CALL CD_Syrope_Check_Range(model%syrope_type(e), slow_next, es, em)
    ELSE
      CALL CD_Syrope_Check_Range(model%syrope_type(e), slow_next, es, em, eps=eps)
    END IF
    IF (es /= CD_SYROPE_OK) THEN
      CALL fail(ErrStat, ErrMsg, TRIM(em)); RETURN
    END IF
    IF (t_mean > model%syrope_tmax(e)) THEN
      CALL CD_Syrope_Working_Curve(model%syrope_type(e), t_mean, ws, wt, wsl, es, em)
      IF (es /= CD_SYROPE_OK) THEN
        CALL fail(ErrStat, ErrMsg, TRIM(em)); RETURN
      END IF
    END IF
    ErrStat = CD_MODEL_OK
    ErrMsg = ''
  END SUBROUTINE model_syrope_state_next

  PURE REAL(wp) FUNCTION model_syrope_slow(model, e) RESULT(slow)
    !! The slow strain of Syrope element e at its present unstretched length l0(e). The state
    !! syrope_slow is a strain of the length the committed state was reached with, l0_c(e).
    !! MoorDyn-F and MoorDyn-C keep the slow STRETCH of a segment, dl_1 = eps_slow*l, as its
    !! state, and an unstretched-length change leaves it as it is (MoorDyn-F sets l(N) and ld(N)
    !! of a controlled line; MoorDyn-C's setUnstretchedLength sets every l[i]); their mean
    !! tension reads the slow strain dl_1/l at the new length. So after a length change
    !!   eps_slow(l0) = eps_slow*l0_c/l0,
    !! the stretch carried over, and a step from it, eps_slow^{n+1} = eps_slow^n l0_c/l0 + dt
    !! d(eps_slow)/dt, is the backward-Euler step of MoorDyn's d(dl_1)/dt = l0 d(eps_slow)/dt
    !! (with the chord rate, no paid-out term, as MoorDyn's Syrope rate takes it). The running
    !! maximum, a tension, does not depend on the length. An element whose length is the
    !! committed one (bit for bit, every element of an uncontrolled line) reads the state as is.
    TYPE(CD_ModelType), INTENT(IN) :: model
    INTEGER, INTENT(IN) :: e
    slow = model%syrope_slow(e)
    IF (.NOT. bits_equal(model%l0(e), model%l0_c(e))) slow = slow*(model%l0_c(e)/model%l0(e))
  END FUNCTION model_syrope_slow

  SUBROUTINE model_contributor_load(model, q, v, force, jac_q, jac_v, ErrStat, ErrMsg)
    !! Assemble all configured non-structural model load contributors and tangents.
    TYPE(CD_ModelType), INTENT(INOUT) :: model
    REAL(wp), INTENT(IN) :: q(:), v(:)
    REAL(wp), INTENT(OUT) :: force(:), jac_q(:, :), jac_v(:, :)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg

    INTEGER :: e, idx(6)
    REAL(wp) :: q2(6), v2(6), f2(6), jq2(6, 6), jv2(6, 6), ea_d_eff, ea_1_eff, syr_tm, syr_ds

    force = CD_ZERO
    jac_q = CD_ZERO
    jac_v = CD_ZERO
    IF (SIZE(v) /= SIZE(q)) THEN
      ErrStat = CD_MODEL_BADINPUT
      ErrMsg = 'CableDyn_Model: model load received inconsistent q/v shapes'
      RETURN
    END IF
    ErrStat = CD_MODEL_OK
    ErrMsg = ''
    CALL ensure_model_load_contributor_workspace(model, SIZE(q), ErrStat, ErrMsg)
    IF (ErrStat /= CD_MODEL_OK) RETURN
    ASSOCIATE (f_tmp => model%load_force_work(1:SIZE(q)), &
               jq_tmp => model%load_jq_work(1:SIZE(q), 1:SIZE(q)), &
               jv_tmp => model%load_jv_work(1:SIZE(q), 1:SIZE(q)))
      IF (model%has_seabed) THEN
        f_tmp = CD_ZERO
        jq_tmp = CD_ZERO
        IF (model%has_bathymetry) THEN
          CALL CD_Bathymetry_Seabed_Load(model%bathymetry, reshape3(q, SIZE(q)), model%seabed_kn, &
                                         f_tmp, jq_tmp, ErrStat, ErrMsg)
        ELSE
          CALL CD_Seabed_Penalty_Load(reshape3(q, SIZE(q)), model%seabed_kn, model%seabed_z_floor, &
                                      f_tmp, jq_tmp, ErrStat, ErrMsg)
        END IF
        IF (ErrStat /= 0) THEN
          ErrStat = CD_MODEL_BADINPUT   ! a foreign module's status mapped to the model's
          RETURN
        END IF
        force = force + f_tmp
        jac_q = jac_q + jq_tmp
      END IF
      IF (model%has_seabed_damping) THEN
        f_tmp = CD_ZERO
        jv_tmp = CD_ZERO
        jq_tmp = CD_ZERO
        IF (model%has_bathymetry) THEN
          CALL bathymetry_normal_damping_load(model, q, v, f_tmp, jq_tmp, jv_tmp, ErrStat, ErrMsg)
        ELSE
          CALL seabed_normal_damping_load(q, v, model%seabed_z_floor, model%seabed_cn, f_tmp, jq_tmp, jv_tmp, &
                                          ErrStat, ErrMsg)
        END IF
        IF (ErrStat /= 0) RETURN
        force = force + f_tmp
        jac_q = jac_q + jq_tmp
        jac_v = jac_v + jv_tmp
      END IF
      IF (model%has_seabed_friction) THEN
        f_tmp = CD_ZERO
        jq_tmp = CD_ZERO
        jv_tmp = CD_ZERO
        CALL seabed_friction_load(model, q, v, f_tmp, jq_tmp, jv_tmp, ErrStat, ErrMsg)
        IF (ErrStat /= 0) RETURN
        force = force + f_tmp
        jac_q = jac_q + jq_tmp
        jac_v = jac_v + jv_tmp
      END IF
      IF (model%has_damping) THEN
        f_tmp = CD_ZERO
        jq_tmp = CD_ZERO
        jv_tmp = CD_ZERO
        CALL CD_Cable_Axial_Damping_Load(q, v, model%elem_conn, model%l0, model%ba_dyn, &
                                         f_tmp, jq_tmp, jv_tmp, ErrStat, ErrMsg, &
                                         l0_dot=model%l0_dot)
        IF (ErrStat /= 0) RETURN
        force = force + f_tmp
        jac_q = jac_q + jq_tmp
        jac_v = jac_v + jv_tmp
      END IF
      IF (model%has_viscoelastic) THEN
        DO e = 1, model%n_elem
          IF (model%ve_mode(e) == 0) CYCLE
          CALL model_viscoelastic_coeffs(model, e, ea_d_eff, ea_1_eff, ErrStat, ErrMsg)
          IF (ErrStat /= CD_MODEL_OK) RETURN
          CALL extract_element_state(model, e, q, v, idx, q2, v2)
          CALL CD_Viscoelastic_Element_Load(q2(1:3), q2(4:6), v2(1:3), v2(4:6), model%l0(e), &
                                            ea_d_eff, ea_1_eff, model%ve_ba(e), &
                                            model%ve_ba_d(e), model%ve_dl_1(e), model%ve_dt, &
                                            f2, jq2, jv2, ErrStat, ErrMsg)
          IF (ErrStat /= 0) RETURN
          CALL scatter_element_vector(force, idx, f2)
          CALL scatter_element_matrix(jac_q, idx, jq2)
          CALL scatter_element_matrix(jac_v, idx, jv2)
        END DO
      END IF
      IF (model%has_syrope) THEN
        DO e = 1, model%n_elem
          IF (.NOT. model%syrope_is(e)) CYCLE
          CALL extract_element_state(model, e, q, v, idx, q2, v2)
          CALL model_syrope_element(model, e, q2, v2, f2, jq2, jv2, syr_tm, syr_ds, ErrStat, ErrMsg)
          IF (ErrStat /= CD_MODEL_OK) RETURN
          CALL scatter_element_vector(force, idx, f2)
          CALL scatter_element_matrix(jac_q, idx, jq2)
          CALL scatter_element_matrix(jac_v, idx, jv2)
        END DO
      END IF
      IF (model%has_morison_drag) THEN
        f_tmp = CD_ZERO
        jq_tmp = CD_ZERO
        jv_tmp = CD_ZERO
        CALL model_morison_drag_load(model, q, v, f_tmp, jq_tmp, jv_tmp, ErrStat, ErrMsg)
        IF (ErrStat /= 0) RETURN
        force = force + f_tmp
        jac_q = jac_q + jq_tmp
        jac_v = jac_v + jv_tmp
      END IF
      IF (model%has_froude_krylov) THEN
        f_tmp = CD_ZERO
        jq_tmp = CD_ZERO
        jv_tmp = CD_ZERO
        CALL model_froude_krylov_load(model, q, v, f_tmp, jq_tmp, jv_tmp, ErrStat, ErrMsg)
        IF (ErrStat /= 0) RETURN
        force = force + f_tmp
        jac_q = jac_q + jq_tmp
        jac_v = jac_v + jv_tmp
      END IF
      IF (model%has_buoyancy_recovery) THEN
        f_tmp = CD_ZERO
        jq_tmp = CD_ZERO
        jv_tmp = CD_ZERO
        CALL model_buoyancy_recovery_load(model, q, v, f_tmp, jq_tmp, jv_tmp, ErrStat, ErrMsg)
        IF (ErrStat /= 0) RETURN
        force = force + f_tmp
        jac_q = jac_q + jq_tmp
        jac_v = jac_v + jv_tmp
      END IF
    END ASSOCIATE
    IF (model%has_viv) THEN
      BLOCK
        INTEGER :: nd, ia
        REAL(wp) :: fl(3), jv3(3, 3), jp3(3, 3), jn3(3, 3), coef, uu(3)
        LOGICAL :: ok
        DO nd = 2, SIZE(q)/3 - 1
          IF (.NOT. model%viv_node(nd)) CYCLE
          CALL viv_node_coef(model, q, nd, coef, uu)
          ia = 3*nd - 2
          CALL CD_VIV_Node_Lift(q(ia - 3:ia - 1), q(ia + 3:ia + 5), smoothed(v, ia), uu, coef, &
                                model%viv_phi_eval(nd), fl, ok, jv3, jp3, jn3)
          IF (.NOT. ok) THEN
            CALL fail(ErrStat, ErrMsg, 'VIV lift: the neighbours of a node coincide (no line tangent)')
            RETURN
          END IF
          force(ia:ia + 2) = force(ia:ia + 2) + fl
          ! the lift takes the smoothed velocity (v_{i-1} + 2 v_i + v_{i+1})/4 (smoothed)
          jac_v(ia:ia + 2, ia:ia + 2) = jac_v(ia:ia + 2, ia:ia + 2) + 0.5_wp*jv3
          jac_v(ia:ia + 2, ia - 3:ia - 1) = jac_v(ia:ia + 2, ia - 3:ia - 1) + 0.25_wp*jv3
          jac_v(ia:ia + 2, ia + 3:ia + 5) = jac_v(ia:ia + 2, ia + 3:ia + 5) + 0.25_wp*jv3
          jac_q(ia:ia + 2, ia - 3:ia - 1) = jac_q(ia:ia + 2, ia - 3:ia - 1) + jp3
          jac_q(ia:ia + 2, ia + 3:ia + 5) = jac_q(ia:ia + 2, ia + 3:ia + 5) + jn3
        END DO
      END BLOCK
    END IF
  END SUBROUTINE model_contributor_load

  SUBROUTINE model_contributor_load_banded(model, q, v, free, kl, ku, force, jac_q_band, jac_v_band, &
                                           ErrStat, ErrMsg)
    !! Assemble model-owned sparse-local load contributors into full force and
    !! reduced free/free banded residual-Jacobian blocks. This is the production
    !! Newton path for no-added-mass EI=0 dynamic lines, including flat and structured
    !! bathymetry contact/damping/friction.
    TYPE(CD_ModelType), INTENT(INOUT) :: model
    REAL(wp), INTENT(IN) :: q(:), v(:)
    INTEGER, INTENT(IN) :: free(:), kl, ku
    REAL(wp), INTENT(OUT) :: force(:), jac_q_band(:, :), jac_v_band(:, :)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg

    INTEGER :: n, ldab, e, i, ix, iy, iz, idx(6)
    REAL(wp) :: gap, normal, g(2), z_floor, dfdx, dfdy, tangent, dn_dv(3), dfc(2), nvec(3), vn
    LOGICAL :: sloped
    REAL(wp) :: d_fr(2), mu_c
    REAL(wp) :: damp_force, damp_dgap, damp_dvz, curv_n(3)
    REAL(wp) :: q2(6), v2(6), f2(6), jq2(6, 6), jv2(6, 6), ea_d_eff, ea_1_eff, syr_tm, syr_ds
    LOGICAL :: free_map_ready
    REAL(wp) :: fluid2(3, 2), accel2(3, 2), wl2(2), dfdv(2, 2)
    INTEGER :: lk ! the kernels' share of ErrMsg (KERNEL_MSG_LEN)

    lk = MIN(LEN(ErrMsg), KERNEL_MSG_LEN)
    force = CD_ZERO
    jac_q_band = CD_ZERO
    jac_v_band = CD_ZERO
    ErrStat = CD_MODEL_OK
    ErrMsg = ''
    n = SIZE(q)
    ldab = 2*kl + ku + 1
    IF (SIZE(v) /= n .OR. SIZE(force) /= n) THEN
      CALL fail(ErrStat, ErrMsg, 'banded model load received inconsistent q/v/force shapes')
      RETURN
    END IF
    IF (kl < 0 .OR. ku < 0 .OR. SIZE(jac_q_band, 1) < ldab .OR. SIZE(jac_v_band, 1) < ldab .OR. &
        SIZE(jac_q_band, 2) /= SIZE(free) .OR. SIZE(jac_v_band, 2) /= SIZE(free)) THEN
      CALL fail(ErrStat, ErrMsg, 'banded model load received invalid band storage')
      RETURN
    END IF
    IF (.NOT. CD_All_Finite(q) .OR. .NOT. CD_All_Finite(v)) THEN
      CALL fail(ErrStat, ErrMsg, 'banded model load q/v must be finite')
      RETURN
    END IF

    free_map_ready = ALLOCATED(model%free_map_work)
    IF (free_map_ready) free_map_ready = SIZE(model%free_map_work) >= n
    IF (.NOT. free_map_ready) THEN
      CALL fail(ErrStat, ErrMsg, 'banded model load requires initialized free-map workspace')
      RETURN
    END IF
    model%free_map_work(1:n) = 0
    DO i = 1, SIZE(free)
      IF (free(i) < 1 .OR. free(i) > n) THEN
        CALL fail(ErrStat, ErrMsg, 'banded model load free DOF index out of range')
        RETURN
      END IF
      IF (model%free_map_work(free(i)) /= 0) THEN
        CALL fail(ErrStat, ErrMsg, 'banded model load duplicate free DOF')
        RETURN
      END IF
      model%free_map_work(free(i)) = i
    END DO

    IF (model%has_seabed) THEN
      DO i = 1, n/3
        ix = 3*i - 2
        iy = 3*i - 1
        iz = 3*i
        IF (model%has_bathymetry) THEN
          CALL model_floor_gradient(model, q(ix), q(iy), z_floor, dfdx, dfdy, ErrStat, ErrMsg(1:lk), curvature=curv_n)
          IF (ErrStat /= CD_MODEL_OK) RETURN
        ELSE
          z_floor = model%seabed_z_floor
          dfdx = CD_ZERO
          dfdy = CD_ZERO
          curv_n = CD_ZERO
        END IF
        gap = z_floor - q(iz)
        IF (ABS(dfdx) > CD_ZERO .OR. ABS(dfdy) > CD_ZERO .OR. ANY(ABS(curv_n) > CD_ZERO)) THEN
          ! sloped seabed: frictionless contact along the surface normal (the static
          ! initializer uses the same law, so the initial condition is an equilibrium)
          BLOCK
            REAL(wp) :: fvec(3), jac3(3, 3)
            INTEGER :: ra, cb
            CALL CD_Seabed_Normal_Contact(gap, dfdx, dfdy, model%seabed_kn(i), fvec, jac3, curvature=curv_n)
            force(ix:iz) = force(ix:iz) + fvec
            DO cb = 1, 3
              DO ra = 1, 3
                CALL scatter_scalar_band(jac_q_band, model%free_map_work, kl, ku, ix + ra - 1, ix + cb - 1, &
                                         jac3(ra, cb), ErrStat, ErrMsg(1:lk))
                IF (ErrStat /= CD_MODEL_OK) RETURN
              END DO
            END DO
          END BLOCK
          CYCLE
        END IF
        CALL CD_Seabed_Normal_Law(gap, model%seabed_kn(i), normal, tangent)
        force(iz) = force(iz) + normal
        CALL scatter_scalar_band(jac_q_band, model%free_map_work, kl, ku, iz, iz, tangent, &
                                 ErrStat, ErrMsg(1:lk))
        IF (ErrStat /= CD_MODEL_OK) RETURN
      END DO
    END IF

    IF (model%has_seabed_damping) THEN
      DO i = 1, n/3
        ix = 3*i - 2
        iy = 3*i - 1
        iz = 3*i
        ! damping along the floor normal, at the normal penetration and normal velocity
        CALL node_contact_normal(model, q(ix), q(iy), q(iz), v(ix:iz), gap, vn, nvec, sloped, ErrStat, ErrMsg(1:lk))
        IF (ErrStat /= CD_MODEL_OK) RETURN
        CALL seabed_normal_damping_terms(gap, vn, model%seabed_cn(i), damp_force, damp_dgap, damp_dvz)
        IF (.NOT. sloped) THEN
          force(iz) = force(iz) + damp_force
          CALL scatter_scalar_band(jac_q_band, model%free_map_work, kl, ku, iz, iz, damp_dgap, &
                                   ErrStat, ErrMsg(1:lk))
          IF (ErrStat /= CD_MODEL_OK) RETURN
          CALL scatter_scalar_band(jac_v_band, model%free_map_work, kl, ku, iz, iz, -damp_dvz, &
                                   ErrStat, ErrMsg(1:lk))
          IF (ErrStat /= CD_MODEL_OK) RETURN
          CYCLE
        END IF
        force(ix:iz) = force(ix:iz) + damp_force*nvec
        ! -dF/dq = damp_dgap n n^T (d gap_n/dq = -n); -dF/dv = -damp_dvz n n^T
        BLOCK
          INTEGER :: ra, cb
          DO cb = 1, 3
            DO ra = 1, 3
              CALL scatter_scalar_band(jac_q_band, model%free_map_work, kl, ku, ix + ra - 1, ix + cb - 1, &
                                       damp_dgap*nvec(ra)*nvec(cb), ErrStat, ErrMsg(1:lk))
              IF (ErrStat /= CD_MODEL_OK) RETURN
              CALL scatter_scalar_band(jac_v_band, model%free_map_work, kl, ku, ix + ra - 1, ix + cb - 1, &
                                       -damp_dvz*nvec(ra)*nvec(cb), ErrStat, ErrMsg(1:lk))
              IF (ErrStat /= CD_MODEL_OK) RETURN
            END DO
          END DO
        END BLOCK
      END DO
    END IF

    IF (model%has_seabed_friction) THEN
      DO i = 1, n/3
        ix = 3*i - 2
        iy = 3*i - 1
        iz = 3*i
        normal = seabed_normal_reaction(model, q(ix), q(iy), q(iz), v(ix:iz), i, ErrStat, ErrMsg(1:lk))
        IF (ErrStat /= CD_MODEL_OK) RETURN
        IF (normal <= CD_ZERO) CYCLE
        ! stick-slip spring to the committed anchor; the load on the node is -f
        d_fr(1) = q(ix) - model%fr_anchor(1, i)
        d_fr(2) = q(iy) - model%fr_anchor(2, i)
        IF (model%seabed_friction_aniso) THEN
          ! dfc is then d(force)/d(normal), so the capacity chain factor is one
          CALL CD_Seabed_Friction_Aniso(CD_FRICTION_STICK_SLIP, d_fr, model%seabed_kn(i), normal, &
                                        model%seabed_mu_axial, model%seabed_mu, friction_axis(q, i), g, dfdv, dfc)
          mu_c = CD_ONE
        ELSE
          CALL CD_Seabed_Friction_Stick_Slip(d_fr, model%seabed_kn(i), &
                                             model%seabed_mu*normal, g, dfdv, dfc)
          mu_c = model%seabed_mu
        END IF
        force(ix) = force(ix) - g(1)
        force(iy) = force(iy) - g(2)
        CALL scatter_scalar_band(jac_q_band, model%free_map_work, kl, ku, ix, ix, dfdv(1, 1), ErrStat, ErrMsg(1:lk))
        IF (ErrStat /= CD_MODEL_OK) RETURN
        CALL scatter_scalar_band(jac_q_band, model%free_map_work, kl, ku, ix, iy, dfdv(1, 2), ErrStat, ErrMsg(1:lk))
        IF (ErrStat /= CD_MODEL_OK) RETURN
        CALL scatter_scalar_band(jac_q_band, model%free_map_work, kl, ku, iy, ix, dfdv(2, 1), ErrStat, ErrMsg(1:lk))
        IF (ErrStat /= CD_MODEL_OK) RETURN
        CALL scatter_scalar_band(jac_q_band, model%free_map_work, kl, ku, iy, iy, dfdv(2, 2), ErrStat, ErrMsg(1:lk))
        IF (ErrStat /= CD_MODEL_OK) RETURN
        IF (ABS(dfc(1)) + ABS(dfc(2)) <= CD_ZERO) CYCLE
        ! sliding: the capacity follows the normal reaction
        CALL scatter_seabed_friction_position_band(model, q(ix), q(iy), q(iz), v(ix:iz), i, ix, dfc(1), jac_q_band, &
                                                   model%free_map_work, kl, ku, ErrStat, ErrMsg(1:lk), mu_c)
        IF (ErrStat /= CD_MODEL_OK) RETURN
        CALL scatter_seabed_friction_position_band(model, q(ix), q(iy), q(iz), v(ix:iz), i, iy, dfc(2), jac_q_band, &
                                                   model%free_map_work, kl, ku, ErrStat, ErrMsg(1:lk), mu_c)
        IF (ErrStat /= CD_MODEL_OK) RETURN
        CALL seabed_normal_velocity_gradient(model, q(ix), q(iy), q(iz), v(ix:iz), i, dn_dv, ErrStat, ErrMsg(1:lk))
        IF (ErrStat /= CD_MODEL_OK) RETURN
        BLOCK
          INTEGER :: rr, cc
          DO rr = 1, 2
            DO cc = 1, 3
              ! a level floor has dn_dv = (0, 0, d): skip its structural zeros
              IF (cc < 3 .AND. .NOT. (ABS(dn_dv(cc)) > CD_ZERO)) CYCLE
              CALL scatter_scalar_band(jac_v_band, model%free_map_work, kl, ku, ix + rr - 1, ix + cc - 1, &
                                       mu_c*dn_dv(cc)*dfc(rr), ErrStat, ErrMsg(1:lk))
              IF (ErrStat /= CD_MODEL_OK) RETURN
            END DO
          END DO
        END BLOCK
      END DO
    END IF

    ! q and v are finite (checked above) and every element input the kernels validate -- l0,
    ! the damping coefficients, the nodal fluid fields and waterlines, and the section scalars --
    ! is validated wherever the model sets it (CD_Init_Model, CD_Update_Model_Hydro_Fields,
    ! CD_Update_Model_SegmentLength): the kernels skip their per-element input scan. Every
    ! writer of these fields must validate them (the snapshot restore and the model copies
    ! assign only previously validated states).
    DO e = 1, model%n_elem
      CALL extract_element_state(model, e, q, v, idx, q2, v2)
      IF (model%has_damping) THEN
        CALL CD_Axial_Damping_Element_Load(q2(1:3), q2(4:6), v2(1:3), v2(4:6), model%l0(e), &
                                           model%ba_dyn(e), f2, jq2, jv2, ErrStat, ErrMsg(1:lk), &
                                           l0_dot=model%l0_dot(e), inputs_validated=.TRUE.)
        IF (ErrStat /= 0) RETURN
        CALL scatter_element_vector(force, idx, f2)
        CALL scatter_element_matrix_band(jac_q_band, model%free_map_work, kl, ku, idx, jq2, ErrStat, ErrMsg(1:lk))
        IF (ErrStat /= CD_MODEL_OK) RETURN
        CALL scatter_element_matrix_band(jac_v_band, model%free_map_work, kl, ku, idx, jv2, ErrStat, ErrMsg(1:lk))
        IF (ErrStat /= CD_MODEL_OK) RETURN
      END IF
      IF (model%has_viscoelastic) THEN
        IF (model%ve_mode(e) /= 0) THEN
          CALL model_viscoelastic_coeffs(model, e, ea_d_eff, ea_1_eff, ErrStat, ErrMsg(1:lk))
          IF (ErrStat /= CD_MODEL_OK) RETURN
          CALL CD_Viscoelastic_Element_Load(q2(1:3), q2(4:6), v2(1:3), v2(4:6), model%l0(e), &
                                            ea_d_eff, ea_1_eff, model%ve_ba(e), &
                                            model%ve_ba_d(e), model%ve_dl_1(e), model%ve_dt, &
                                            f2, jq2, jv2, ErrStat, ErrMsg(1:lk))
          IF (ErrStat /= 0) RETURN
          CALL scatter_element_vector(force, idx, f2)
          CALL scatter_element_matrix_band(jac_q_band, model%free_map_work, kl, ku, idx, jq2, ErrStat, ErrMsg(1:lk))
          IF (ErrStat /= CD_MODEL_OK) RETURN
          CALL scatter_element_matrix_band(jac_v_band, model%free_map_work, kl, ku, idx, jv2, ErrStat, ErrMsg(1:lk))
          IF (ErrStat /= CD_MODEL_OK) RETURN
        END IF
      END IF
      IF (model%has_syrope) THEN
        IF (model%syrope_is(e)) THEN
          CALL model_syrope_element(model, e, q2, v2, f2, jq2, jv2, syr_tm, syr_ds, ErrStat, ErrMsg(1:lk))
          IF (ErrStat /= CD_MODEL_OK) RETURN
          CALL scatter_element_vector(force, idx, f2)
          CALL scatter_element_matrix_band(jac_q_band, model%free_map_work, kl, ku, idx, jq2, ErrStat, ErrMsg(1:lk))
          IF (ErrStat /= CD_MODEL_OK) RETURN
          CALL scatter_element_matrix_band(jac_v_band, model%free_map_work, kl, ku, idx, jv2, ErrStat, ErrMsg(1:lk))
          IF (ErrStat /= CD_MODEL_OK) RETURN
        END IF
      END IF
      IF (model%has_morison_drag) THEN
        CALL extract_nodal_vector(model%fluid_velocity, model, e, fluid2)
        CALL extract_nodal_scalar(model%drag_waterline_z, model, e, wl2)
        CALL CD_Morison_Drag_Element_Load(q2(1:3), q2(4:6), v2(1:3), v2(4:6), model%l0(e), &
                                          fluid2(:, 1), fluid2(:, 2), wl2(1), wl2(2), model%drag_rho, &
                                          model%drag_diameter_elem(e), model%drag_cdn_elem(e), &
                                          model%drag_cdt_elem(e), f2, jq2, jv2, ErrStat, ErrMsg(1:lk), &
                                          inputs_validated=.TRUE.)
        IF (ErrStat /= 0) RETURN
        CALL scatter_element_vector(force, idx, f2)
        CALL scatter_element_matrix_band(jac_q_band, model%free_map_work, kl, ku, idx, jq2, ErrStat, ErrMsg(1:lk))
        IF (ErrStat /= CD_MODEL_OK) RETURN
        CALL scatter_element_matrix_band(jac_v_band, model%free_map_work, kl, ku, idx, jv2, ErrStat, ErrMsg(1:lk))
        IF (ErrStat /= CD_MODEL_OK) RETURN
      END IF
      IF (model%has_froude_krylov) THEN
        CALL extract_nodal_vector(model%fluid_acceleration, model, e, accel2)
        CALL extract_nodal_scalar(model%fk_waterline_z, model, e, wl2)
        CALL CD_Froude_Krylov_Element_Load(q2(1:3), q2(4:6), v2(1:3), v2(4:6), model%l0(e), &
                                           accel2(:, 1), accel2(:, 2), wl2(1), wl2(2), model%fk_rho, &
                                           model%fk_diameter_elem(e), model%fk_can_elem(e), &
                                           model%fk_cat_elem(e), f2, jq2, jv2, ErrStat, ErrMsg(1:lk), &
                                           inputs_validated=.TRUE.)
        IF (ErrStat /= 0) RETURN
        CALL scatter_element_vector(force, idx, f2)
        CALL scatter_element_matrix_band(jac_q_band, model%free_map_work, kl, ku, idx, jq2, ErrStat, ErrMsg(1:lk))
        IF (ErrStat /= CD_MODEL_OK) RETURN
        ! jv2 is identically zero (a velocity-independent load), and adding zeros changes no
        ! entry of a band that starts at +0 and only accumulates: its scatter is skipped. The
        ! index and bandwidth checks of this element ran in the jac_q scatter above (the step
        ! passes both bands with the same shape).
      END IF
      IF (model%has_buoyancy_recovery) THEN
        CALL extract_nodal_scalar(model%buoyancy_waterline_z, model, e, wl2)
        CALL CD_Buoyancy_Recovery_Element_Load(q2(1:3), q2(4:6), model%l0(e), wl2(1), wl2(2), &
                                               model%buoyancy_rho, model%buoyancy_diameter_elem(e), &
                                               model%buoyancy_gravity, f2, jq2, jv2, ErrStat, ErrMsg(1:lk), &
                                               inputs_validated=.TRUE.)
        IF (ErrStat /= 0) RETURN
        CALL scatter_element_vector(force, idx, f2)
        CALL scatter_element_matrix_band(jac_q_band, model%free_map_work, kl, ku, idx, jq2, ErrStat, ErrMsg(1:lk))
        IF (ErrStat /= CD_MODEL_OK) RETURN
        ! jv2 is identically zero: no scatter (as for Froude-Krylov above)
      END IF
    END DO

    IF (model%has_viv) THEN
      ! cross-flow VIV lift on the interior nodes (CableDyn_VIV), with its velocity Jacobian
      ! and the position Jacobian through the node tangent (the two neighbours)
      BLOCK
        INTEGER :: nd, ia, ra, cb
        REAL(wp) :: fl(3), jv3(3, 3), jp3(3, 3), jn3(3, 3), coef, uu(3)
        LOGICAL :: ok
        DO nd = 2, n/3 - 1
          IF (.NOT. model%viv_node(nd)) CYCLE
          CALL viv_node_coef(model, q, nd, coef, uu)
          ia = 3*nd - 2
          CALL CD_VIV_Node_Lift(q(ia - 3:ia - 1), q(ia + 3:ia + 5), smoothed(v, ia), uu, coef, &
                                model%viv_phi_eval(nd), fl, ok, jv3, jp3, jn3)
          IF (.NOT. ok) THEN
            CALL fail(ErrStat, ErrMsg, 'VIV lift: the neighbours of a node coincide (no line tangent)')
            RETURN
          END IF
          force(ia:ia + 2) = force(ia:ia + 2) + fl
          DO cb = 1, 3
            DO ra = 1, 3
              ! the lift takes the smoothed velocity (v_{i-1} + 2 v_i + v_{i+1})/4 (smoothed)
              CALL scatter_scalar_band(jac_v_band, model%free_map_work, kl, ku, ia + ra - 1, ia + cb - 1, &
                                       0.5_wp*jv3(ra, cb), ErrStat, ErrMsg)
              IF (ErrStat /= CD_MODEL_OK) RETURN
              CALL scatter_scalar_band(jac_v_band, model%free_map_work, kl, ku, ia + ra - 1, ia + cb - 4, &
                                       0.25_wp*jv3(ra, cb), ErrStat, ErrMsg)
              IF (ErrStat /= CD_MODEL_OK) RETURN
              CALL scatter_scalar_band(jac_v_band, model%free_map_work, kl, ku, ia + ra - 1, ia + cb + 2, &
                                       0.25_wp*jv3(ra, cb), ErrStat, ErrMsg)
              IF (ErrStat /= CD_MODEL_OK) RETURN
              CALL scatter_scalar_band(jac_q_band, model%free_map_work, kl, ku, ia + ra - 1, ia + cb - 4, &
                                       jp3(ra, cb), ErrStat, ErrMsg)
              IF (ErrStat /= CD_MODEL_OK) RETURN
              CALL scatter_scalar_band(jac_q_band, model%free_map_work, kl, ku, ia + ra - 1, ia + cb + 2, &
                                       jn3(ra, cb), ErrStat, ErrMsg)
              IF (ErrStat /= CD_MODEL_OK) RETURN
            END DO
          END DO
        END DO
      END BLOCK
    END IF

    IF (.NOT. CD_All_Finite(force) .OR. .NOT. CD_All_Finite(jac_q_band) .OR. &
        .NOT. CD_All_Finite(jac_v_band)) THEN
      CALL fail(ErrStat, ErrMsg, 'banded model load returned non-finite force/Jacobian')
    END IF
  END SUBROUTINE model_contributor_load_banded

  SUBROUTINE model_contributor_force(model, q, v, force, ErrStat, ErrMsg, end_nodes_only, law_tension, &
                                     law_stiffness)
    !! Assemble all configured non-structural model load contributors without tangents.
    !! end_nodes_only: only the first and last node's entries are needed (end-force recovery);
    !! the other nodes and the elements not touching an end are skipped, and the two end entries
    !! are bit-identical to the full assembly (same terms in the same order). `force` is then the
    !! compact 9-vector [first node (3), last node (3), sum over the other nodes the end
    !! elements reach (3)], so the recovery needs no n_dof-long scratch; the third block only
    !! carries the finiteness check of the full assembly.
    !! law_tension (n_elem; with a full assembly): the along-chord tension of the element force
    !! of the viscoelastic and Syrope laws in `force`, zero for every other element.
    !! law_stiffness (n_elem; with law_tension): the axial stiffness of those laws at (q, v), in
    !! N per metre of elongation: EA_D/l0 (the dynamic branch, at the committed state of a
    !! load-dependent EA_D) and Syrope's K1/l0 = (alpha + beta T_mean)/l0; zero elsewhere.
    TYPE(CD_ModelType), INTENT(IN) :: model
    REAL(wp), INTENT(IN) :: q(:), v(:)
    REAL(wp), INTENT(OUT) :: force(:)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    LOGICAL, INTENT(IN), OPTIONAL :: end_nodes_only
    REAL(wp), INTENT(OUT), OPTIONAL :: law_tension(:)
    REAL(wp), INTENT(OUT), OPTIONAL :: law_stiffness(:)

    INTEGER :: n, e, i, ix, iy, iz, idx(6), nn
    LOGICAL :: ends
    REAL(wp) :: gap, z_floor, normal, tangent, damp_force, damp_dgap, damp_dvz, fr_f(2), fr_dd(2, 2), fr_dc(2)
    REAL(wp) :: d_fr(2)
    REAL(wp) :: q2(6), v2(6), f2(6), ea_d_eff, ea_1_eff, syr_tm, syr_ds, syr_jac(6, 6), syr_jac_v(6, 6)
    REAL(wp) :: fluid2(3, 2), accel2(3, 2), wl2(2)
    INTEGER :: lk ! the kernels' share of ErrMsg (KERNEL_MSG_LEN)

    lk = MIN(LEN(ErrMsg), KERNEL_MSG_LEN)
    force = CD_ZERO
    n = SIZE(q)
    ends = .FALSE.
    IF (PRESENT(end_nodes_only)) ends = end_nodes_only
    IF (SIZE(v) /= n .OR. SIZE(force) /= MERGE(9, n, ends)) THEN
      ErrStat = CD_MODEL_BADINPUT
      ErrMsg = 'CableDyn_Model: model force received inconsistent q/v/force shapes'
      RETURN
    END IF
    IF (PRESENT(law_tension)) THEN
      IF (ends .OR. SIZE(law_tension) /= model%n_elem) THEN
        ErrStat = CD_MODEL_BADINPUT
        ErrMsg = 'CableDyn_Model: model force law tensions need a full assembly and shape (n_elem)'
        RETURN
      END IF
      law_tension = CD_ZERO
    END IF
    IF (PRESENT(law_stiffness)) THEN
      IF (.NOT. PRESENT(law_tension) .OR. SIZE(law_stiffness) /= model%n_elem) THEN
        ErrStat = CD_MODEL_BADINPUT
        ErrMsg = 'CableDyn_Model: model force law stiffnesses need the law tensions and shape (n_elem)'
        RETURN
      END IF
      law_stiffness = CD_ZERO
    END IF
    ErrStat = CD_MODEL_OK
    ErrMsg = ''
    nn = n/3
    IF (.NOT. CD_All_Finite(q) .OR. .NOT. CD_All_Finite(v)) THEN
      CALL fail(ErrStat, ErrMsg, 'model force q/v must be finite')
      RETURN
    END IF

    IF (model%has_seabed) THEN
      DO i = 1, n/3
        IF (ends .AND. i /= 1 .AND. i /= nn) CYCLE
        ix = 3*i - 2
        iy = 3*i - 1
        iz = 3*i
        IF (model%has_bathymetry) THEN
          ! sloped seabed: frictionless contact along the surface normal
          BLOCK
            REAL(wp) :: fvec(3), jac3(3, 3), gx, gy, curv(3)
            CALL model_floor_gradient(model, q(ix), q(iy), z_floor, gx, gy, ErrStat, ErrMsg(1:lk), curvature=curv)
            IF (ErrStat /= CD_MODEL_OK) RETURN
            IF (ABS(gx) > CD_ZERO .OR. ABS(gy) > CD_ZERO .OR. ANY(ABS(curv) > CD_ZERO)) THEN
              CALL CD_Seabed_Normal_Contact(z_floor - q(iz), gx, gy, model%seabed_kn(i), fvec, jac3, curvature=curv)
              force(slot(ix):slot(iz)) = force(slot(ix):slot(iz)) + fvec
              CYCLE
            END IF
          END BLOCK
        ELSE
          z_floor = model%seabed_z_floor
        END IF
        gap = z_floor - q(iz)
        CALL CD_Seabed_Normal_Law(gap, model%seabed_kn(i), normal, tangent)
        force(slot(iz)) = force(slot(iz)) + normal
      END DO
    END IF

    IF (model%has_seabed_damping) THEN
      DO i = 1, n/3
        IF (ends .AND. i /= 1 .AND. i /= nn) CYCLE
        ix = 3*i - 2
        iy = 3*i - 1
        iz = 3*i
        BLOCK
          REAL(wp) :: vn, nvec(3)
          LOGICAL :: sloped
          CALL node_contact_normal(model, q(ix), q(iy), q(iz), v(ix:iz), gap, vn, nvec, sloped, ErrStat, ErrMsg(1:lk))
          IF (ErrStat /= CD_MODEL_OK) RETURN
          CALL seabed_normal_damping_terms(gap, vn, model%seabed_cn(i), damp_force, damp_dgap, damp_dvz)
          IF (sloped) THEN
            force(slot(ix):slot(iz)) = force(slot(ix):slot(iz)) + damp_force*nvec
          ELSE
            force(slot(iz)) = force(slot(iz)) + damp_force
          END IF
        END BLOCK
      END DO
    END IF

    IF (model%has_seabed_friction) THEN
      DO i = 1, n/3
        IF (ends .AND. i /= 1 .AND. i /= nn) CYCLE
        ix = 3*i - 2
        iy = 3*i - 1
        iz = 3*i
        normal = seabed_normal_reaction(model, q(ix), q(iy), q(iz), v(ix:iz), i, ErrStat, ErrMsg(1:lk))
        IF (ErrStat /= CD_MODEL_OK) RETURN
        IF (normal <= CD_ZERO) CYCLE
        d_fr(1) = q(ix) - model%fr_anchor(1, i)
        d_fr(2) = q(iy) - model%fr_anchor(2, i)
        IF (model%seabed_friction_aniso) THEN
          CALL CD_Seabed_Friction_Aniso(CD_FRICTION_STICK_SLIP, d_fr, model%seabed_kn(i), normal, &
                                        model%seabed_mu_axial, model%seabed_mu, friction_axis(q, i), &
                                        fr_f, fr_dd, fr_dc)
        ELSE
          CALL CD_Seabed_Friction_Stick_Slip(d_fr, model%seabed_kn(i), &
                                             model%seabed_mu*normal, fr_f, fr_dd, fr_dc)
        END IF
        force(slot(ix)) = force(slot(ix)) - fr_f(1)
        force(slot(iy)) = force(slot(iy)) - fr_f(2)
      END DO
    END IF

    ! validated element inputs: see model_contributor_load_banded
    DO e = 1, model%n_elem
      IF (ends) THEN
        IF (ALL(model%elem_conn(:, e) /= 1) .AND. ALL(model%elem_conn(:, e) /= nn)) CYCLE
      END IF
      CALL extract_element_state(model, e, q, v, idx, q2, v2)
      IF (ends) idx = [(slot(idx(i)), i=1, 6)]
      IF (model%has_damping) THEN
        CALL CD_Axial_Damping_Element_Force(q2(1:3), q2(4:6), v2(1:3), v2(4:6), model%l0(e), &
                                            model%ba_dyn(e), f2, ErrStat, ErrMsg(1:lk), &
                                            l0_dot=model%l0_dot(e), inputs_validated=.TRUE.)
        IF (ErrStat /= 0) RETURN
        CALL scatter_element_vector(force, idx, f2)
      END IF
      IF (model%has_viscoelastic) THEN
        IF (model%ve_mode(e) /= 0) THEN
          CALL model_viscoelastic_coeffs(model, e, ea_d_eff, ea_1_eff, ErrStat, ErrMsg(1:lk))
          IF (ErrStat /= CD_MODEL_OK) RETURN
          CALL CD_Viscoelastic_Element_Force(q2(1:3), q2(4:6), v2(1:3), v2(4:6), model%l0(e), &
                                             ea_d_eff, ea_1_eff, model%ve_ba(e), &
                                             model%ve_ba_d(e), model%ve_dl_1(e), model%ve_dt, &
                                             f2, ErrStat, ErrMsg(1:lk))
          IF (ErrStat /= 0) RETURN
          CALL scatter_element_vector(force, idx, f2)
          IF (PRESENT(law_tension)) law_tension(e) = element_law_tension()
          IF (PRESENT(law_stiffness)) law_stiffness(e) = ea_d_eff/model%l0(e)
        END IF
      END IF
      IF (model%has_syrope) THEN
        IF (model%syrope_is(e)) THEN
          CALL model_syrope_element(model, e, q2, v2, f2, syr_jac, syr_jac_v, syr_tm, syr_ds, ErrStat, ErrMsg(1:lk))
          IF (ErrStat /= CD_MODEL_OK) RETURN
          CALL scatter_element_vector(force, idx, f2)
          IF (PRESENT(law_tension)) law_tension(e) = element_law_tension()
          IF (PRESENT(law_stiffness)) law_stiffness(e) = (model%syrope_type(e)%alpha + &
                                                          model%syrope_type(e)%beta*syr_tm)/model%l0(e)
        END IF
      END IF
      IF (model%has_morison_drag) THEN
        CALL extract_nodal_vector(model%fluid_velocity, model, e, fluid2)
        CALL extract_nodal_scalar(model%drag_waterline_z, model, e, wl2)
        CALL CD_Morison_Drag_Element_Force(q2(1:3), q2(4:6), v2(1:3), v2(4:6), model%l0(e), &
                                           fluid2(:, 1), fluid2(:, 2), wl2(1), wl2(2), model%drag_rho, &
                                           model%drag_diameter_elem(e), model%drag_cdn_elem(e), &
                                           model%drag_cdt_elem(e), f2, ErrStat, ErrMsg(1:lk), inputs_validated=.TRUE.)
        IF (ErrStat /= 0) RETURN
        CALL scatter_element_vector(force, idx, f2)
      END IF
      IF (model%has_froude_krylov) THEN
        CALL extract_nodal_vector(model%fluid_acceleration, model, e, accel2)
        CALL extract_nodal_scalar(model%fk_waterline_z, model, e, wl2)
        CALL CD_Froude_Krylov_Element_Force(q2(1:3), q2(4:6), v2(1:3), v2(4:6), model%l0(e), &
                                            accel2(:, 1), accel2(:, 2), wl2(1), wl2(2), model%fk_rho, &
                                            model%fk_diameter_elem(e), model%fk_can_elem(e), &
                                            model%fk_cat_elem(e), f2, ErrStat, ErrMsg(1:lk), inputs_validated=.TRUE.)
        IF (ErrStat /= 0) RETURN
        CALL scatter_element_vector(force, idx, f2)
      END IF
      IF (model%has_buoyancy_recovery) THEN
        CALL extract_nodal_scalar(model%buoyancy_waterline_z, model, e, wl2)
        CALL CD_Buoyancy_Recovery_Element_Force(q2(1:3), q2(4:6), model%l0(e), wl2(1), wl2(2), &
                                                model%buoyancy_rho, model%buoyancy_diameter_elem(e), &
                                                model%buoyancy_gravity, f2, ErrStat, ErrMsg(1:lk), &
                                                inputs_validated=.TRUE.)
        IF (ErrStat /= 0) RETURN
        CALL scatter_element_vector(force, idx, f2)
      END IF
    END DO
    ! VIV lift acts on interior nodes only, so an end-node recovery carries none of it
    IF (model%has_viv .AND. .NOT. ends) THEN
      BLOCK
        INTEGER :: nd, ia
        REAL(wp) :: fl(3), coef, uu(3)
        LOGICAL :: ok
        DO nd = 2, nn - 1
          IF (.NOT. model%viv_node(nd)) CYCLE
          CALL viv_node_coef(model, q, nd, coef, uu)
          ia = 3*nd - 2
          CALL CD_VIV_Node_Lift(q(ia - 3:ia - 1), q(ia + 3:ia + 5), smoothed(v, ia), uu, coef, &
                                model%viv_phi_eval(nd), fl, ok)
          IF (.NOT. ok) THEN
            CALL fail(ErrStat, ErrMsg, 'VIV lift: the neighbours of a node coincide (no line tangent)')
            RETURN
          END IF
          force(ia:ia + 2) = force(ia:ia + 2) + fl
        END DO
      END BLOCK
    END IF
    IF (.NOT. CD_All_Finite(force)) CALL fail(ErrStat, ErrMsg, 'model force returned non-finite force')

  CONTAINS

    PURE INTEGER FUNCTION slot(k) RESULT(j)
      !! Storage index of global DOF k: itself in a full assembly, its compact slot in an
      !! end-node recovery.
      INTEGER, INTENT(IN) :: k
      INTEGER :: node
      j = k
      IF (.NOT. ends) RETURN
      node = (k + 2)/3
      j = k - 3*(node - 1)
      IF (node == nn) THEN
        j = j + 3
      ELSE IF (node /= 1) THEN
        j = j + 6
      END IF
    END FUNCTION slot

    REAL(wp) FUNCTION element_law_tension() RESULT(t)
      !! Along-chord tension of the element force f2 on node a (the laws keep the element
      !! longer than their collapse length, so the chord is nonzero).
      REAL(wp) :: chord(3)
      chord = q2(4:6) - q2(1:3)
      t = DOT_PRODUCT(f2(1:3), chord/NORM2(chord))
    END FUNCTION element_law_tension
  END SUBROUTINE model_contributor_force

  SUBROUTINE seabed_normal_damping_load(q, v, z_floor, c_n, force, jac_q, jac_v, ErrStat, ErrMsg)
    !! Contact-only normal seabed damping with the shared C1 touchdown gate.
    !! For fully contacted downward motion, force_z = -c_n*v_z; through the
    !! touchdown blend the force and position tangent ramp continuously.
    REAL(wp), INTENT(IN) :: q(:), v(:), z_floor, c_n(:)
    REAL(wp), INTENT(OUT) :: force(:), jac_q(:, :), jac_v(:, :)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg

    INTEGER :: i, iz, n_nodes
    REAL(wp) :: gap, damp_force, damp_dgap, damp_dvz

    force = CD_ZERO
    jac_q = CD_ZERO
    jac_v = CD_ZERO
    CALL validate_seabed_damping(q, v, z_floor, c_n, force, ErrStat, ErrMsg)
    IF (ErrStat /= CD_MODEL_OK) RETURN
    IF (SIZE(jac_q, 1) /= SIZE(q) .OR. SIZE(jac_q, 2) /= SIZE(q) .OR. &
        SIZE(jac_v, 1) /= SIZE(q) .OR. SIZE(jac_v, 2) /= SIZE(q)) THEN
      CALL fail(ErrStat, ErrMsg, 'seabed damping Jacobian shapes are inconsistent')
      RETURN
    END IF
    n_nodes = SIZE(q)/3
    DO i = 1, n_nodes
      iz = 3*i
      gap = z_floor - q(iz)
      CALL seabed_normal_damping_terms(gap, v(iz), c_n(i), damp_force, damp_dgap, damp_dvz)
      force(iz) = damp_force
      jac_q(iz, iz) = damp_dgap
      jac_v(iz, iz) = -damp_dvz
    END DO
  END SUBROUTINE seabed_normal_damping_load

  SUBROUTINE validate_seabed_damping(q, v, z_floor, c_n, force, ErrStat, ErrMsg)
    REAL(wp), INTENT(IN) :: q(:), v(:), z_floor, c_n(:)
    REAL(wp), INTENT(IN) :: force(:)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    INTEGER :: n_nodes

    ErrStat = CD_MODEL_OK
    ErrMsg = ''
    IF (MOD(SIZE(q), 3) /= 0 .OR. SIZE(q) < 6) THEN
      CALL fail(ErrStat, ErrMsg, 'seabed damping q must be a positions-only state')
      RETURN
    END IF
    n_nodes = SIZE(q)/3
    IF (SIZE(v) /= SIZE(q) .OR. SIZE(force) /= SIZE(q) .OR. SIZE(c_n) /= n_nodes) THEN
      CALL fail(ErrStat, ErrMsg, 'seabed damping q/v/force/c_n shapes are inconsistent')
      RETURN
    END IF
    IF (.NOT. CD_All_Finite(q) .OR. .NOT. CD_All_Finite(v) .OR. &
        .NOT. CD_All_Finite(c_n) .OR. .NOT. CD_Is_Finite(z_floor)) THEN
      CALL fail(ErrStat, ErrMsg, 'seabed damping inputs must be finite')
      RETURN
    END IF
    IF (ANY(c_n < CD_ZERO)) THEN
      CALL fail(ErrStat, ErrMsg, 'seabed damping coefficients must be non-negative')
      RETURN
    END IF
  END SUBROUTINE validate_seabed_damping

  SUBROUTINE bathymetry_normal_damping_load(model, q, v, force, jac_q, jac_v, ErrStat, ErrMsg)
    !! One-sided vertical normal damping against a structured bathymetry floor,
    !! with the same C1 touchdown gate used for flat-floor contact.
    TYPE(CD_ModelType), INTENT(IN) :: model
    REAL(wp), INTENT(IN) :: q(:), v(:)
    REAL(wp), INTENT(OUT) :: force(:), jac_q(:, :), jac_v(:, :)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg

    INTEGER :: i, ix, iy, iz, n_nodes, cb
    REAL(wp) :: gap, vn, nvec(3), damp_force, damp_dgap, damp_dvz
    LOGICAL :: sloped

    force = CD_ZERO
    jac_q = CD_ZERO
    jac_v = CD_ZERO
    CALL validate_bathymetry_damping(model, q, v, force, ErrStat, ErrMsg)
    IF (ErrStat /= CD_MODEL_OK) RETURN
    IF (SIZE(jac_q, 1) /= SIZE(q) .OR. SIZE(jac_q, 2) /= SIZE(q) .OR. &
        SIZE(jac_v, 1) /= SIZE(q) .OR. SIZE(jac_v, 2) /= SIZE(q)) THEN
      CALL fail(ErrStat, ErrMsg, 'bathymetry damping Jacobian shapes are inconsistent')
      RETURN
    END IF
    n_nodes = SIZE(q)/3
    DO i = 1, n_nodes
      ix = 3*i - 2
      iy = ix + 1
      iz = ix + 2
      ! damping along the floor normal, at the normal penetration and normal velocity
      CALL node_contact_normal(model, q(ix), q(iy), q(iz), v(ix:iz), gap, vn, nvec, sloped, ErrStat, ErrMsg)
      IF (ErrStat /= CD_MODEL_OK) RETURN
      CALL seabed_normal_damping_terms(gap, vn, model%seabed_cn(i), damp_force, damp_dgap, damp_dvz)
      IF (.NOT. sloped) THEN
        force(iz) = damp_force
        jac_q(iz, iz) = damp_dgap
        jac_v(iz, iz) = -damp_dvz
        CYCLE
      END IF
      force(ix:iz) = damp_force*nvec
      DO cb = 1, 3
        jac_q(ix:iz, ix + cb - 1) = damp_dgap*nvec*nvec(cb)
        jac_v(ix:iz, ix + cb - 1) = -damp_dvz*nvec*nvec(cb)
      END DO
    END DO
  END SUBROUTINE bathymetry_normal_damping_load

  SUBROUTINE validate_bathymetry_damping(model, q, v, force, ErrStat, ErrMsg)
    TYPE(CD_ModelType), INTENT(IN) :: model
    REAL(wp), INTENT(IN) :: q(:), v(:), force(:)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    INTEGER :: n_nodes

    ErrStat = CD_MODEL_OK
    ErrMsg = ''
    IF (.NOT. model%has_bathymetry .OR. .NOT. CD_Bathymetry_Is_Initialized(model%bathymetry)) THEN
      CALL fail(ErrStat, ErrMsg, 'bathymetry damping requires initialized bathymetry contact')
      RETURN
    END IF
    IF (MOD(SIZE(q), 3) /= 0 .OR. SIZE(q) < 6) THEN
      CALL fail(ErrStat, ErrMsg, 'bathymetry damping q must be a positions-only state')
      RETURN
    END IF
    n_nodes = SIZE(q)/3
    IF (SIZE(v) /= SIZE(q) .OR. SIZE(force) /= SIZE(q) .OR. SIZE(model%seabed_cn) /= n_nodes) THEN
      CALL fail(ErrStat, ErrMsg, 'bathymetry damping q/v/force/c_n shapes are inconsistent')
      RETURN
    END IF
    IF (.NOT. CD_All_Finite(q) .OR. .NOT. CD_All_Finite(v) .OR. &
        .NOT. CD_All_Finite(model%seabed_cn) .OR. ANY(model%seabed_cn < CD_ZERO)) THEN
      CALL fail(ErrStat, ErrMsg, 'bathymetry damping inputs must be finite with c_n >= 0')
      RETURN
    END IF
  END SUBROUTINE validate_bathymetry_damping

  SUBROUTINE seabed_friction_load(model, q, v, force, jac_q, jac_v, ErrStat, ErrMsg)
    !! Stick-slip seabed friction: each node in contact holds a horizontal spring of
    !! stiffness k_n to its committed anchor, capped at mu*N (CD_Seabed_Friction_Stick_Slip),
    !! where N is the active spring normal reaction plus one-sided normal damping.
    TYPE(CD_ModelType), INTENT(IN) :: model
    REAL(wp), INTENT(IN) :: q(:), v(:)
    REAL(wp), INTENT(OUT) :: force(:), jac_q(:, :), jac_v(:, :)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg

    INTEGER :: i, ix, iy, iz, n_nodes, r
    REAL(wp) :: normal, f(2), dfd(2, 2), dfc(2), dn_dq(3), dn_dv(3)
    REAL(wp) :: d_fr(2), mu_c

    force = CD_ZERO
    jac_q = CD_ZERO
    jac_v = CD_ZERO
    dn_dq = CD_ZERO
    dn_dv = CD_ZERO
    CALL validate_seabed_friction(model, q, v, force, ErrStat, ErrMsg)
    IF (ErrStat /= CD_MODEL_OK) RETURN
    n_nodes = SIZE(q)/3
    DO i = 1, n_nodes
      ix = 3*i - 2
      iy = 3*i - 1
      iz = 3*i
      normal = seabed_normal_reaction(model, q(ix), q(iy), q(iz), v(ix:iz), i, ErrStat, ErrMsg)
      IF (ErrStat /= CD_MODEL_OK) RETURN
      IF (normal <= CD_ZERO) CYCLE
      d_fr(1) = q(ix) - model%fr_anchor(1, i)
      d_fr(2) = q(iy) - model%fr_anchor(2, i)
      IF (model%seabed_friction_aniso) THEN
        CALL CD_Seabed_Friction_Aniso(CD_FRICTION_STICK_SLIP, d_fr, model%seabed_kn(i), normal, &
                                      model%seabed_mu_axial, model%seabed_mu, friction_axis(q, i), f, dfd, dfc)
        mu_c = CD_ONE
      ELSE
        CALL CD_Seabed_Friction_Stick_Slip(d_fr, model%seabed_kn(i), &
                                           model%seabed_mu*normal, f, dfd, dfc)
        mu_c = model%seabed_mu
      END IF
      force(ix) = -f(1)
      force(iy) = -f(2)
      jac_q(ix:iy, ix:iy) = jac_q(ix:iy, ix:iy) + dfd
      IF (ABS(dfc(1)) + ABS(dfc(2)) <= CD_ZERO) CYCLE
      CALL seabed_normal_position_gradient(model, q(ix), q(iy), q(iz), v(ix:iz), i, dn_dq, ErrStat, ErrMsg)
      IF (ErrStat /= CD_MODEL_OK) RETURN
      CALL seabed_normal_velocity_gradient(model, q(ix), q(iy), q(iz), v(ix:iz), i, dn_dv, ErrStat, ErrMsg)
      IF (ErrStat /= CD_MODEL_OK) RETURN
      DO r = 1, 2
        jac_q(ix + r - 1, ix:iz) = jac_q(ix + r - 1, ix:iz) + mu_c*dfc(r)*dn_dq
        jac_v(ix + r - 1, ix:iz) = jac_v(ix + r - 1, ix:iz) + mu_c*dfc(r)*dn_dv
      END DO
    END DO
  END SUBROUTINE seabed_friction_load

  SUBROUTINE scatter_seabed_friction_position_band(model, x, y, z, vel, node, row, g_component, jac_q_band, &
                                                   free_map, kl, ku, ErrStat, ErrMsg, mu_c)
    !! mu_c: the factor that turns g_component into d(force)/d(normal) (seabed_mu for the
    !! isotropic law, whose g_component is d(force)/d(capacity); one for the anisotropic law).
    TYPE(CD_ModelType), INTENT(IN) :: model
    REAL(wp), INTENT(IN) :: x, y, z, vel(3), g_component, mu_c
    INTEGER, INTENT(IN) :: node, row, free_map(:), kl, ku
    REAL(wp), INTENT(INOUT) :: jac_q_band(:, :)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg

    INTEGER :: ix, iy, iz
    REAL(wp) :: dn_dq(3)

    ix = 3*node - 2
    iy = ix + 1
    iz = ix + 2
    dn_dq = CD_ZERO
    CALL seabed_normal_position_gradient(model, x, y, z, vel, node, dn_dq, ErrStat, ErrMsg)
    IF (ErrStat /= CD_MODEL_OK) RETURN
    CALL scatter_scalar_band(jac_q_band, free_map, kl, ku, row, ix, &
                             mu_c*dn_dq(1)*g_component, ErrStat, ErrMsg)
    IF (ErrStat /= CD_MODEL_OK) RETURN
    CALL scatter_scalar_band(jac_q_band, free_map, kl, ku, row, iy, &
                             mu_c*dn_dq(2)*g_component, ErrStat, ErrMsg)
    IF (ErrStat /= CD_MODEL_OK) RETURN
    CALL scatter_scalar_band(jac_q_band, free_map, kl, ku, row, iz, &
                             mu_c*dn_dq(3)*g_component, ErrStat, ErrMsg)
  END SUBROUTINE scatter_seabed_friction_position_band

  SUBROUTINE validate_seabed_friction(model, q, v, force, ErrStat, ErrMsg)
    TYPE(CD_ModelType), INTENT(IN) :: model
    REAL(wp), INTENT(IN) :: q(:), v(:), force(:)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    INTEGER :: n_nodes

    ErrStat = CD_MODEL_OK
    ErrMsg = ''
    IF (.NOT. model%has_seabed) THEN
      CALL fail(ErrStat, ErrMsg, 'seabed friction requires seabed contact')
      RETURN
    END IF
    IF (MOD(SIZE(q), 3) /= 0 .OR. SIZE(q) < 6) THEN
      CALL fail(ErrStat, ErrMsg, 'seabed friction q must be a positions-only state')
      RETURN
    END IF
    n_nodes = SIZE(q)/3
    IF (SIZE(v) /= SIZE(q) .OR. SIZE(force) /= SIZE(q) .OR. SIZE(model%seabed_kn) /= n_nodes) THEN
      CALL fail(ErrStat, ErrMsg, 'seabed friction state/contact shapes are inconsistent')
      RETURN
    END IF
    IF (.NOT. CD_All_Finite(q) .OR. .NOT. CD_All_Finite(v) .OR. &
        .NOT. CD_Is_Finite(model%seabed_mu) .OR. model%seabed_mu < CD_ZERO) THEN
      CALL fail(ErrStat, ErrMsg, 'seabed friction inputs must be finite with mu >= 0')
      RETURN
    END IF
    IF (.NOT. ALLOCATED(model%fr_anchor)) THEN
      CALL fail(ErrStat, ErrMsg, 'seabed friction anchors are not initialized')
      RETURN
    END IF
    IF (SIZE(model%fr_anchor, 2) /= n_nodes) THEN
      CALL fail(ErrStat, ErrMsg, 'seabed friction anchors must have shape (2, n_nodes)')
      RETURN
    END IF
  END SUBROUTINE validate_seabed_friction

  SUBROUTINE model_floor_gradient(model, x, y, z_floor, dfdx, dfdy, ErrStat, ErrMsg, curvature)
    !! Seabed elevation and gradient of the model's bathymetry, with the bathymetry status
    !! mapped to the model's (CD_MODEL_BADINPUT on a failed query). curvature (optional):
    !! the curvature of the crease rounding (CD_Bathymetry_Floor_Gradient).
    TYPE(CD_ModelType), INTENT(IN) :: model
    REAL(wp), INTENT(IN) :: x, y
    REAL(wp), INTENT(OUT) :: z_floor, dfdx, dfdy
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    REAL(wp), INTENT(OUT), OPTIONAL :: curvature(3)
    INTEGER :: es
    CHARACTER(160) :: em
    CALL CD_Bathymetry_Floor_Gradient(model%bathymetry, x, y, z_floor, dfdx, dfdy, es, em, &
                                      crease_curvature=curvature)
    IF (es == CD_BATHY_OK) THEN
      ErrStat = CD_MODEL_OK
      ErrMsg = ''
    ELSE
      ErrStat = CD_MODEL_BADINPUT
      ErrMsg = 'CableDyn_Model: bathymetry gradient query failed: '//TRIM(em)
    END IF
  END SUBROUTINE model_floor_gradient

  SUBROUTINE node_contact_normal(model, x, y, z, vel, gap_n, vn, nvec, sloped, ErrStat, ErrMsg)
    !! Contact geometry of a node against the seabed: the penetration normal to the
    !! (locally planar) floor gap_n = (z_floor - z)/s, the velocity along the upward unit
    !! normal vn = v . n and n = (-dfdx, -dfdy, 1)/s, s = sqrt(1 + dfdx^2 + dfdy^2). On a
    !! level floor n = e_z, gap_n = z_floor - z and vn = v_z exactly (sloped = .FALSE.).
    TYPE(CD_ModelType), INTENT(IN) :: model
    REAL(wp), INTENT(IN) :: x, y, z, vel(3)
    REAL(wp), INTENT(OUT) :: gap_n, vn, nvec(3)
    LOGICAL, INTENT(OUT) :: sloped
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    INTEGER :: es
    REAL(wp) :: z_floor, dfdx, dfdy, sfac
    CHARACTER(160) :: em

    ErrStat = CD_MODEL_OK
    ErrMsg = ''
    gap_n = CD_ZERO
    vn = CD_ZERO
    nvec = [CD_ZERO, CD_ZERO, CD_ONE]
    sloped = .FALSE.
    dfdx = CD_ZERO
    dfdy = CD_ZERO
    IF (model%has_bathymetry) THEN
      CALL CD_Bathymetry_Floor_Gradient(model%bathymetry, x, y, z_floor, dfdx, dfdy, es, em)
      IF (es /= 0) THEN
        ErrStat = CD_MODEL_BADINPUT
        ErrMsg = 'CableDyn_Model: bathymetry gradient query failed: '//TRIM(em)
        RETURN
      END IF
    ELSE
      z_floor = model%seabed_z_floor
    END IF
    sloped = ABS(dfdx) > CD_ZERO .OR. ABS(dfdy) > CD_ZERO
    IF (sloped) THEN
      sfac = SQRT(CD_ONE + dfdx*dfdx + dfdy*dfdy)
      nvec = [-dfdx, -dfdy, CD_ONE]/sfac
      gap_n = (z_floor - z)/sfac
      vn = DOT_PRODUCT(vel, nvec)
    ELSE
      gap_n = z_floor - z
      vn = vel(3)
    END IF
  END SUBROUTINE node_contact_normal

  REAL(wp) FUNCTION seabed_normal_reaction(model, x, y, z, vel, node, ErrStat, ErrMsg) RESULT(normal)
    !! Magnitude of the seabed normal reaction (elastic law plus one-sided damping) at the
    !! normal penetration and normal velocity; the friction capacity is mu times it.
    TYPE(CD_ModelType), INTENT(IN) :: model
    REAL(wp), INTENT(IN) :: x, y, z, vel(3)
    INTEGER, INTENT(IN) :: node
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    REAL(wp) :: gap_n, vn, nvec(3), tangent, damping, dgap, dvz
    LOGICAL :: sloped

    normal = CD_ZERO
    CALL node_contact_normal(model, x, y, z, vel, gap_n, vn, nvec, sloped, ErrStat, ErrMsg)
    IF (ErrStat /= CD_MODEL_OK) RETURN
    CALL CD_Seabed_Normal_Law(gap_n, model%seabed_kn(node), normal, tangent)
    IF (model%has_seabed_damping) THEN
      CALL seabed_normal_damping_terms(gap_n, vn, model%seabed_cn(node), damping, dgap, dvz)
      normal = normal + damping
    END IF
  END FUNCTION seabed_normal_reaction

  SUBROUTINE seabed_normal_position_gradient(model, x, y, z, vel, node, dn_dq, ErrStat, ErrMsg)
    !! d(normal reaction)/dq with the floor gradient (and so the normal) held over the node.
    TYPE(CD_ModelType), INTENT(IN) :: model
    REAL(wp), INTENT(IN) :: x, y, z, vel(3)
    INTEGER, INTENT(IN) :: node
    REAL(wp), INTENT(OUT) :: dn_dq(3)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    REAL(wp) :: gap_n, vn, nvec(3), normal, tangent, damping, damp_dgap, damp_dvz
    LOGICAL :: sloped

    dn_dq = CD_ZERO
    CALL node_contact_normal(model, x, y, z, vel, gap_n, vn, nvec, sloped, ErrStat, ErrMsg)
    IF (ErrStat /= CD_MODEL_OK) RETURN
    CALL CD_Seabed_Normal_Law(gap_n, model%seabed_kn(node), normal, tangent)
    IF (model%has_seabed_damping) THEN
      CALL seabed_normal_damping_terms(gap_n, vn, model%seabed_cn(node), damping, damp_dgap, damp_dvz)
      tangent = tangent + damp_dgap
    END IF
    ! d(gap_n)/dq = -n
    dn_dq = -tangent*nvec
  END SUBROUTINE seabed_normal_position_gradient

  SUBROUTINE seabed_normal_velocity_gradient(model, x, y, z, vel, node, dn_dv, ErrStat, ErrMsg)
    !! d(normal reaction)/dv = (d damping/d vn) n.
    TYPE(CD_ModelType), INTENT(IN) :: model
    REAL(wp), INTENT(IN) :: x, y, z, vel(3)
    INTEGER, INTENT(IN) :: node
    REAL(wp), INTENT(OUT) :: dn_dv(3)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    REAL(wp) :: gap_n, vn, nvec(3), damping, damp_dgap, dn_dvn
    LOGICAL :: sloped

    dn_dv = CD_ZERO
    ErrStat = CD_MODEL_OK
    ErrMsg = ''
    IF (.NOT. model%has_seabed_damping) RETURN
    CALL node_contact_normal(model, x, y, z, vel, gap_n, vn, nvec, sloped, ErrStat, ErrMsg)
    IF (ErrStat /= CD_MODEL_OK) RETURN
    CALL seabed_normal_damping_terms(gap_n, vn, model%seabed_cn(node), damping, damp_dgap, dn_dvn)
    dn_dv = dn_dvn*nvec
  END SUBROUTINE seabed_normal_velocity_gradient

  SUBROUTINE CD_Model_Seabed_Point_Load(model, x, vel, k_n, c_n, in_contact, force, jac_q, jac_v, ErrStat, ErrMsg)
    !! The line's own nodal seabed law evaluated for a point that is not one of its nodes (a
    !! Free/Connect point the line is attached to): normal stiffness k_n [N/m] and one-sided
    !! normal damping c_n [N.s/m] against this model's floor (flat or bathymetry, along the
    !! surface normal on a slope, with the crease rounding), exactly as a line node with those
    !! coefficients. force is the seabed load on the point, jac_q = -d(force)/dq and
    !! jac_v = -d(force)/dv its residual tangents. in_contact is .FALSE. (and every output
    !! exactly zero) when the model has no seabed or the point is clear of the contact.
    TYPE(CD_ModelType), INTENT(IN) :: model
    REAL(wp), INTENT(IN) :: x(3), vel(3), k_n, c_n
    LOGICAL, INTENT(OUT) :: in_contact
    REAL(wp), INTENT(OUT) :: force(3), jac_q(3, 3), jac_v(3, 3)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    REAL(wp) :: z_floor, dfdx, dfdy, curv(3), gap, normal, tangent, gap_n, vn, nvec(3)
    REAL(wp) :: damp_force, damp_dgap, damp_dvz
    LOGICAL :: sloped
    INTEGER :: a, b

    in_contact = .FALSE.
    force = CD_ZERO
    jac_q = CD_ZERO
    jac_v = CD_ZERO
    ErrStat = CD_MODEL_OK
    ErrMsg = ''
    IF (.NOT. model%has_seabed) RETURN
    IF (.NOT. (k_n > CD_ZERO .OR. c_n > CD_ZERO)) RETURN
    IF (model%has_bathymetry) THEN
      CALL model_floor_gradient(model, x(1), x(2), z_floor, dfdx, dfdy, ErrStat, ErrMsg, curvature=curv)
      IF (ErrStat /= CD_MODEL_OK) RETURN
    ELSE
      z_floor = model%seabed_z_floor
      dfdx = CD_ZERO
      dfdy = CD_ZERO
      curv = CD_ZERO
    END IF
    gap = z_floor - x(3)
    ! The normal penetration is the vertical one over s >= 1, so a point more than the
    ! touchdown blend above the floor (vertically) is clear of every term below.
    IF (gap <= -CD_SEABED_CONTACT_BLEND*SQRT(CD_ONE + dfdx*dfdx + dfdy*dfdy)) RETURN
    IF (ABS(dfdx) > CD_ZERO .OR. ABS(dfdy) > CD_ZERO .OR. ANY(ABS(curv) > CD_ZERO)) THEN
      CALL CD_Seabed_Normal_Contact(gap, dfdx, dfdy, k_n, force, jac_q, curvature=curv)
    ELSE
      CALL CD_Seabed_Normal_Law(gap, k_n, normal, tangent)
      force(3) = normal
      jac_q(3, 3) = tangent
    END IF
    IF (c_n > CD_ZERO) THEN
      CALL node_contact_normal(model, x(1), x(2), x(3), vel, gap_n, vn, nvec, sloped, ErrStat, ErrMsg)
      IF (ErrStat /= CD_MODEL_OK) THEN
        force = CD_ZERO
        jac_q = CD_ZERO
        RETURN
      END IF
      CALL seabed_normal_damping_terms(gap_n, vn, c_n, damp_force, damp_dgap, damp_dvz)
      force = force + damp_force*nvec
      DO b = 1, 3
        DO a = 1, 3
          jac_q(a, b) = jac_q(a, b) + damp_dgap*nvec(a)*nvec(b)
          jac_v(a, b) = -damp_dvz*nvec(a)*nvec(b)
        END DO
      END DO
    END IF
    in_contact = .TRUE.
  END SUBROUTINE CD_Model_Seabed_Point_Load

  PURE SUBROUTINE seabed_normal_damping_terms(gap, vz, c_n, force, dforce_dgap, dforce_dvz)
    !! One-sided normal seabed damping at normal penetration gap and normal velocity vz
    !! (vertical on a level floor): force = -c_n*gate(gap)*vz for vz < 0.
    REAL(wp), INTENT(IN) :: gap, vz, c_n
    REAL(wp), INTENT(OUT) :: force, dforce_dgap, dforce_dvz
    REAL(wp) :: gate, dgate_dgap

    force = CD_ZERO
    dforce_dgap = CD_ZERO
    dforce_dvz = CD_ZERO
    IF (c_n <= CD_ZERO .OR. vz >= CD_ZERO) RETURN
    CALL CD_Seabed_Contact_Gate(gap, gate, dgate_dgap)
    force = -c_n*gate*vz
    dforce_dgap = -c_n*dgate_dgap*vz
    dforce_dvz = -c_n*gate
  END SUBROUTINE seabed_normal_damping_terms

  SUBROUTINE model_morison_drag_load(model, q, v, force, jac_q, jac_v, ErrStat, ErrMsg)
    TYPE(CD_ModelType), INTENT(IN) :: model
    REAL(wp), INTENT(IN) :: q(:), v(:)
    REAL(wp), INTENT(OUT) :: force(:), jac_q(:, :), jac_v(:, :)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg

    INTEGER :: e, conn1(2, 1), idx(6)
    REAL(wp) :: q2(6), v2(6), l02(1), fluid2(3, 2), wl2(2), f2(6), jq2(6, 6), jv2(6, 6)

    force = CD_ZERO
    jac_q = CD_ZERO
    jac_v = CD_ZERO
    conn1(:, 1) = [1, 2]
    DO e = 1, model%n_elem
      CALL extract_element_state(model, e, q, v, idx, q2, v2)
      CALL extract_nodal_vector(model%fluid_velocity, model, e, fluid2)
      CALL extract_nodal_scalar(model%drag_waterline_z, model, e, wl2)
      l02(1) = model%l0(e)
      CALL CD_Cable_Morison_Drag_Load(q2, v2, conn1, l02, fluid2, wl2, model%drag_rho, &
                                      model%drag_diameter_elem(e), model%drag_cdn_elem(e), &
                                      model%drag_cdt_elem(e), f2, jq2, jv2, ErrStat, ErrMsg)
      IF (ErrStat /= 0) RETURN
      CALL scatter_element_vector(force, idx, f2)
      CALL scatter_element_matrix(jac_q, idx, jq2)
      CALL scatter_element_matrix(jac_v, idx, jv2)
    END DO
    ErrStat = CD_MODEL_OK
    ErrMsg = ''
  END SUBROUTINE model_morison_drag_load

  SUBROUTINE model_froude_krylov_load(model, q, v, force, jac_q, jac_v, ErrStat, ErrMsg)
    TYPE(CD_ModelType), INTENT(IN) :: model
    REAL(wp), INTENT(IN) :: q(:), v(:)
    REAL(wp), INTENT(OUT) :: force(:), jac_q(:, :), jac_v(:, :)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg

    INTEGER :: e, conn1(2, 1), idx(6)
    REAL(wp) :: q2(6), v2(6), l02(1), accel2(3, 2), wl2(2), f2(6), jq2(6, 6), jv2(6, 6)

    force = CD_ZERO
    jac_q = CD_ZERO
    jac_v = CD_ZERO
    conn1(:, 1) = [1, 2]
    DO e = 1, model%n_elem
      CALL extract_element_state(model, e, q, v, idx, q2, v2)
      CALL extract_nodal_vector(model%fluid_acceleration, model, e, accel2)
      CALL extract_nodal_scalar(model%fk_waterline_z, model, e, wl2)
      l02(1) = model%l0(e)
      CALL CD_Cable_Froude_Krylov_Load(q2, v2, conn1, l02, accel2, wl2, model%fk_rho, &
                                       model%fk_diameter_elem(e), model%fk_can_elem(e), &
                                       model%fk_cat_elem(e), f2, jq2, jv2, ErrStat, ErrMsg)
      IF (ErrStat /= 0) RETURN
      CALL scatter_element_vector(force, idx, f2)
      CALL scatter_element_matrix(jac_q, idx, jq2)
      CALL scatter_element_matrix(jac_v, idx, jv2)
    END DO
    ErrStat = CD_MODEL_OK
    ErrMsg = ''
  END SUBROUTINE model_froude_krylov_load

  SUBROUTINE model_buoyancy_recovery_load(model, q, v, force, jac_q, jac_v, ErrStat, ErrMsg)
    TYPE(CD_ModelType), INTENT(IN) :: model
    REAL(wp), INTENT(IN) :: q(:), v(:)
    REAL(wp), INTENT(OUT) :: force(:), jac_q(:, :), jac_v(:, :)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg

    INTEGER :: e, conn1(2, 1), idx(6)
    REAL(wp) :: q2(6), v2(6), l02(1), wl2(2), f2(6), jq2(6, 6), jv2(6, 6)

    force = CD_ZERO
    jac_q = CD_ZERO
    jac_v = CD_ZERO
    conn1(:, 1) = [1, 2]
    DO e = 1, model%n_elem
      CALL extract_element_state(model, e, q, v, idx, q2, v2)
      CALL extract_nodal_scalar(model%buoyancy_waterline_z, model, e, wl2)
      l02(1) = model%l0(e)
      CALL CD_Cable_Buoyancy_Recovery_Load(q2, v2, conn1, l02, wl2, model%buoyancy_rho, &
                                           model%buoyancy_diameter_elem(e), model%buoyancy_gravity, &
                                           f2, jq2, jv2, ErrStat, ErrMsg)
      IF (ErrStat /= 0) RETURN
      CALL scatter_element_vector(force, idx, f2)
      CALL scatter_element_matrix(jac_q, idx, jq2)
      CALL scatter_element_matrix(jac_v, idx, jv2)
    END DO
    ErrStat = CD_MODEL_OK
    ErrMsg = ''
  END SUBROUTINE model_buoyancy_recovery_load

  SUBROUTINE model_added_mass_full(model, q, accel, M_add, dMa_a_dq, ErrStat, ErrMsg)
    TYPE(CD_ModelType), INTENT(IN) :: model
    REAL(wp), INTENT(IN) :: q(:), accel(:)
    REAL(wp), INTENT(OUT) :: M_add(:, :), dMa_a_dq(:, :)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg

    INTEGER :: e, conn1(2, 1), idx(6)
    REAL(wp) :: q2(6), a2(6), l02(1), wl2(2), m2(6, 6), dm2(6, 6)

    M_add = CD_ZERO
    dMa_a_dq = CD_ZERO
    conn1(:, 1) = [1, 2]
    DO e = 1, model%n_elem
      CALL extract_element_state(model, e, q, accel, idx, q2, a2)
      CALL extract_nodal_scalar(model%added_mass_waterline_z, model, e, wl2)
      l02(1) = model%l0(e)
      CALL CD_Cable_Added_Mass(q2, a2, conn1, l02, wl2, model%added_mass_rho, &
                               model%added_mass_diameter_elem(e), model%added_mass_can_elem(e), &
                               model%added_mass_cat_elem(e), m2, dm2, ErrStat, ErrMsg)
      IF (ErrStat /= 0) RETURN
      CALL scatter_element_matrix(M_add, idx, m2)
      CALL scatter_element_matrix(dMa_a_dq, idx, dm2)
    END DO
    ErrStat = CD_MODEL_OK
    ErrMsg = ''
  END SUBROUTINE model_added_mass_full

  SUBROUTINE model_added_mass_banded(model, q, accel, free, kl, ku, M_add_a, M_add_band, dMa_a_dq_band, &
                                     ErrStat, ErrMsg, need_tangent, l0_elem)
    !! l0_elem (n_elem, finite and positive): the element lengths to use instead of model%l0
    !! (the blended lengths of a step after a length change).
    TYPE(CD_ModelType), INTENT(INOUT) :: model
    REAL(wp), INTENT(IN) :: q(:), accel(:)
    INTEGER, INTENT(IN) :: free(:), kl, ku
    REAL(wp), INTENT(OUT) :: M_add_a(:), M_add_band(:, :), dMa_a_dq_band(:, :)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    LOGICAL, INTENT(IN), OPTIONAL :: need_tangent
    REAL(wp), INTENT(IN), OPTIONAL :: l0_elem(:)

    INTEGER :: e, i, n, ldab, idx(6)
    REAL(wp) :: q2(6), a2(6), wl2(2), m2(6, 6), dm2(6, 6), ma2(6), le
    LOGICAL :: want_tangent, zero_accel, free_map_ready
    INTEGER :: lk ! the kernels' share of ErrMsg (KERNEL_MSG_LEN)

    lk = MIN(LEN(ErrMsg), KERNEL_MSG_LEN)
    ErrStat = CD_MODEL_OK
    ErrMsg = ''
    want_tangent = .TRUE.
    IF (PRESENT(need_tangent)) want_tangent = need_tangent
    zero_accel = MAXVAL(ABS(accel)) <= EPSILON(CD_ZERO)
    M_add_a = CD_ZERO
    IF (want_tangent) THEN
      M_add_band = CD_ZERO
      dMa_a_dq_band = CD_ZERO
    END IF
    n = SIZE(q)
    ldab = 2*kl + ku + 1
    IF (SIZE(accel) /= n .OR. SIZE(M_add_a) /= n) THEN
      CALL fail(ErrStat, ErrMsg, 'banded added mass received inconsistent q/accel/output shapes')
      RETURN
    END IF
    IF (want_tangent .AND. &
        (kl < 0 .OR. ku < 0 .OR. SIZE(M_add_band, 1) < ldab .OR. SIZE(dMa_a_dq_band, 1) < ldab .OR. &
         SIZE(M_add_band, 2) /= SIZE(free) .OR. SIZE(dMa_a_dq_band, 2) /= SIZE(free))) THEN
      CALL fail(ErrStat, ErrMsg, 'banded added mass received invalid band storage')
      RETURN
    END IF
    free_map_ready = ALLOCATED(model%free_map_work)
    IF (free_map_ready) free_map_ready = SIZE(model%free_map_work) >= n
    IF (want_tangent .AND. .NOT. free_map_ready) THEN
      CALL fail(ErrStat, ErrMsg, 'banded added mass requires initialized free-map workspace')
      RETURN
    END IF
    IF (.NOT. CD_All_Finite(q) .OR. .NOT. CD_All_Finite(accel)) THEN
      CALL fail(ErrStat, ErrMsg, 'banded added mass q/accel must be finite')
      RETURN
    END IF
    IF (PRESENT(l0_elem)) THEN
      IF (SIZE(l0_elem) /= model%n_elem) THEN
        CALL fail(ErrStat, ErrMsg, 'banded added mass lengths must have shape (n_elem)')
        RETURN
      END IF
      IF (.NOT. CD_All_Finite(l0_elem) .OR. ANY(l0_elem <= CD_ZERO)) THEN
        CALL fail(ErrStat, ErrMsg, 'banded added mass lengths must be finite and positive')
        RETURN
      END IF
    END IF

    IF (want_tangent) THEN
      model%free_map_work(1:n) = 0
      DO i = 1, SIZE(free)
        IF (free(i) < 1 .OR. free(i) > n) THEN
          CALL fail(ErrStat, ErrMsg, 'banded added mass free DOF index out of range')
          RETURN
        END IF
        IF (model%free_map_work(free(i)) /= 0) THEN
          CALL fail(ErrStat, ErrMsg, 'banded added mass duplicate free DOF')
          RETURN
        END IF
        model%free_map_work(free(i)) = i
      END DO
    END IF

    ! validated element inputs (q and accel checked above): see model_contributor_load_banded
    DO e = 1, model%n_elem
      CALL extract_element_state(model, e, q, accel, idx, q2, a2)
      CALL extract_nodal_scalar(model%added_mass_waterline_z, model, e, wl2)
      le = model%l0(e)
      IF (PRESENT(l0_elem)) le = l0_elem(e)
      IF (want_tangent) THEN
        IF (zero_accel) THEN
          CALL CD_Added_Mass_Element_Matrix(q2(1:3), q2(4:6), le, wl2(1), wl2(2), &
                                            model%added_mass_rho, model%added_mass_diameter_elem(e), &
                                            model%added_mass_can_elem(e), model%added_mass_cat_elem(e), &
                                            m2, ErrStat, ErrMsg(1:lk), inputs_validated=.TRUE.)
          IF (ErrStat /= 0) RETURN
          ma2 = CD_ZERO
        ELSE
          CALL CD_Added_Mass_Element(q2(1:3), q2(4:6), a2(1:3), a2(4:6), le, wl2(1), wl2(2), &
                                     model%added_mass_rho, model%added_mass_diameter_elem(e), &
                                     model%added_mass_can_elem(e), model%added_mass_cat_elem(e), &
                                     m2, dm2, ErrStat, ErrMsg(1:lk), inputs_validated=.TRUE.)
          IF (ErrStat /= 0) RETURN
          ma2 = MATMUL(m2, a2)
        END IF
      ELSE
        CALL CD_Added_Mass_Element_Force(q2(1:3), q2(4:6), a2(1:3), a2(4:6), le, wl2(1), wl2(2), &
                                         model%added_mass_rho, model%added_mass_diameter_elem(e), &
                                         model%added_mass_can_elem(e), model%added_mass_cat_elem(e), &
                                         ma2, ErrStat, ErrMsg(1:lk), inputs_validated=.TRUE.)
        IF (ErrStat /= 0) RETURN
      END IF
      CALL scatter_element_vector(M_add_a, idx, ma2)
      IF (want_tangent) THEN
        CALL scatter_element_matrix_band(M_add_band, model%free_map_work, kl, ku, idx, m2, ErrStat, ErrMsg(1:lk))
        IF (ErrStat /= CD_MODEL_OK) RETURN
        IF (.NOT. zero_accel) THEN
          CALL scatter_element_matrix_band(dMa_a_dq_band, model%free_map_work, kl, ku, idx, dm2, ErrStat, ErrMsg(1:lk))
          IF (ErrStat /= CD_MODEL_OK) RETURN
        END IF
      END IF
    END DO
    IF (.NOT. CD_All_Finite(M_add_a) .OR. &
        (want_tangent .AND. (.NOT. CD_All_Finite(M_add_band) .OR. &
                             .NOT. CD_All_Finite(dMa_a_dq_band)))) THEN
      CALL fail(ErrStat, ErrMsg, 'banded added mass returned non-finite force/matrix/Jacobian')
    END IF
  END SUBROUTINE model_added_mass_banded

  PURE SUBROUTINE model_structural_mass_product(model, x, product)
    !! Apply the constant consistent translational mass in O(n_elem) without forming
    !! or traversing its dense storage. Each element is m/6 [[2I,I],[I,2I]].
    TYPE(CD_ModelType), INTENT(IN) :: model
    REAL(wp), INTENT(IN) :: x(:)
    REAL(wp), INTENT(OUT) :: product(:)

    INTEGER :: e, a, b, ia, ib
    REAL(wp) :: coeff

    product = CD_ZERO
    DO e = 1, model%n_elem
      a = model%elem_conn(1, e); b = model%elem_conn(2, e)
      ia = 3*a - 2; ib = 3*b - 2
      coeff = model%rho_a(e)*model%l0(e)/6.0_wp
      product(ia:ia + 2) = product(ia:ia + 2) + coeff*(2.0_wp*x(ia:ia + 2) + x(ib:ib + 2))
      product(ib:ib + 2) = product(ib:ib + 2) + coeff*(x(ia:ia + 2) + 2.0_wp*x(ib:ib + 2))
    END DO
  END SUBROUTINE model_structural_mass_product

  SUBROUTINE model_added_mass_force(model, q, accel, M_add_a, ErrStat, ErrMsg)
    !! Force-only added-mass application for load recovery. This avoids allocating,
    !! zeroing and multiplying an n_dof-square matrix on every CalcOutput call.
    TYPE(CD_ModelType), INTENT(IN) :: model
    REAL(wp), INTENT(IN) :: q(:), accel(:)
    REAL(wp), INTENT(OUT) :: M_add_a(:)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg

    INTEGER :: e, idx(6)
    REAL(wp) :: q2(6), a2(6), wl2(2), ma2(6)
    INTEGER :: lk ! the kernels' share of ErrMsg (KERNEL_MSG_LEN)

    lk = MIN(LEN(ErrMsg), KERNEL_MSG_LEN)
    ErrMsg = '' ! the part past lk stays blank when a kernel fails
    M_add_a = CD_ZERO
    DO e = 1, model%n_elem
      CALL extract_element_positions(model, e, q, idx, q2)
      a2 = accel(idx)
      CALL extract_nodal_scalar(model%added_mass_waterline_z, model, e, wl2)
      CALL CD_Added_Mass_Element_Force(q2(1:3), q2(4:6), a2(1:3), a2(4:6), model%l0(e), wl2(1), wl2(2), &
                                       model%added_mass_rho, model%added_mass_diameter_elem(e), &
                                       model%added_mass_can_elem(e), model%added_mass_cat_elem(e), &
                                       ma2, ErrStat, ErrMsg(1:lk))
      IF (ErrStat /= 0) RETURN
      CALL scatter_element_vector(M_add_a, idx, ma2)
    END DO
    IF (.NOT. CD_All_Finite(M_add_a)) THEN
      CALL fail(ErrStat, ErrMsg, 'added-mass force returned non-finite values')
      RETURN
    END IF
    ErrStat = CD_MODEL_OK
    ErrMsg = ''
  END SUBROUTINE model_added_mass_force

  PURE SUBROUTINE extract_element_state(model, e, q, v, idx, q2, v2)
    TYPE(CD_ModelType), INTENT(IN) :: model
    INTEGER, INTENT(IN) :: e
    REAL(wp), INTENT(IN) :: q(:), v(:)
    INTEGER, INTENT(OUT) :: idx(6)
    REAL(wp), INTENT(OUT) :: q2(6), v2(6)

    INTEGER :: a, b

    a = model%elem_conn(1, e)
    b = model%elem_conn(2, e)
    idx = [3*a - 2, 3*a - 1, 3*a, 3*b - 2, 3*b - 1, 3*b]
    ! the two nodes' contiguous triples (the copies q(idx), v(idx) without a vector subscript)
    q2(1:3) = q(3*a - 2:3*a)
    q2(4:6) = q(3*b - 2:3*b)
    v2(1:3) = v(3*a - 2:3*a)
    v2(4:6) = v(3*b - 2:3*b)
  END SUBROUTINE extract_element_state

  PURE SUBROUTINE extract_element_positions(model, e, q, idx, q2)
    TYPE(CD_ModelType), INTENT(IN) :: model
    INTEGER, INTENT(IN) :: e
    REAL(wp), INTENT(IN) :: q(:)
    INTEGER, INTENT(OUT) :: idx(6)
    REAL(wp), INTENT(OUT) :: q2(6)

    INTEGER :: a, b

    a = model%elem_conn(1, e)
    b = model%elem_conn(2, e)
    idx = [3*a - 2, 3*a - 1, 3*a, 3*b - 2, 3*b - 1, 3*b]
    q2(1:3) = q(3*a - 2:3*a)
    q2(4:6) = q(3*b - 2:3*b)
  END SUBROUTINE extract_element_positions

  PURE SUBROUTINE extract_nodal_vector(field, model, e, field2)
    REAL(wp), INTENT(IN) :: field(:, :)
    TYPE(CD_ModelType), INTENT(IN) :: model
    INTEGER, INTENT(IN) :: e
    REAL(wp), INTENT(OUT) :: field2(3, 2)

    field2(:, 1) = field(:, model%elem_conn(1, e))
    field2(:, 2) = field(:, model%elem_conn(2, e))
  END SUBROUTINE extract_nodal_vector

  PURE SUBROUTINE extract_nodal_scalar(field, model, e, field2)
    REAL(wp), INTENT(IN) :: field(:)
    TYPE(CD_ModelType), INTENT(IN) :: model
    INTEGER, INTENT(IN) :: e
    REAL(wp), INTENT(OUT) :: field2(2)

    field2(1) = field(model%elem_conn(1, e))
    field2(2) = field(model%elem_conn(2, e))
  END SUBROUTINE extract_nodal_scalar

  PURE SUBROUTINE scatter_element_vector(global, idx, local)
    REAL(wp), INTENT(INOUT) :: global(:)
    INTEGER, INTENT(IN) :: idx(6)
    REAL(wp), INTENT(IN) :: local(6)
    INTEGER :: i

    DO i = 1, 6
      global(idx(i)) = global(idx(i)) + local(i)
    END DO
  END SUBROUTINE scatter_element_vector

  PURE SUBROUTINE scatter_element_matrix(global, idx, local)
    REAL(wp), INTENT(INOUT) :: global(:, :)
    INTEGER, INTENT(IN) :: idx(6)
    REAL(wp), INTENT(IN) :: local(6, 6)
    INTEGER :: i, j

    DO j = 1, 6
      DO i = 1, 6
        global(idx(i), idx(j)) = global(idx(i), idx(j)) + local(i, j)
      END DO
    END DO
  END SUBROUTINE scatter_element_matrix

  SUBROUTINE scatter_element_matrix_band(ab, free_map, kl, ku, idx, local, ErrStat, ErrMsg)
    !! Scatter a 6x6 element residual-Jacobian block into reduced free/free
    !! LAPACK band storage. Fixed/prescribed rows or columns are skipped because
    !! Newton only solves the free block. This runs for every contributor of every
    !! element on each Jacobian evaluation, so ErrMsg is written only on failure.
    REAL(wp), INTENT(INOUT) :: ab(:, :)
    INTEGER, INTENT(IN) :: free_map(:), kl, ku, idx(6)
    REAL(wp), INTENT(IN) :: local(6, 6)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(INOUT) :: ErrMsg
    INTEGER :: i, j, row, fmap(6)

    ErrStat = CD_MODEL_OK
    IF (ANY(idx < 1) .OR. ANY(idx > SIZE(free_map))) THEN
      CALL fail(ErrStat, ErrMsg, 'band scatter global index out of range')
      RETURN
    END IF
    fmap = free_map(idx)
    DO j = 1, 6
      IF (fmap(j) == 0) CYCLE
      DO i = 1, 6
        IF (fmap(i) == 0) CYCLE
        row = kl + ku + 1 + fmap(i) - fmap(j)
        IF (row < 1 .OR. row > SIZE(ab, 1)) THEN
          CALL fail(ErrStat, ErrMsg, 'band scatter bandwidth too small')
          RETURN
        END IF
        ab(row, fmap(j)) = ab(row, fmap(j)) + local(i, j)
      END DO
    END DO
  END SUBROUTINE scatter_element_matrix_band

  SUBROUTINE scatter_scalar_band(ab, free_map, kl, ku, gi, gj, value, ErrStat, ErrMsg)
    !! Add one global matrix entry to reduced free/free LAPACK band storage.
    !! ErrMsg is written only on failure (this is a per-node hot path).
    REAL(wp), INTENT(INOUT) :: ab(:, :)
    INTEGER, INTENT(IN) :: free_map(:), kl, ku, gi, gj
    REAL(wp), INTENT(IN) :: value
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(INOUT) :: ErrMsg
    INTEGER :: fi, fj, row

    ErrStat = CD_MODEL_OK
    IF (gi < 1 .OR. gi > SIZE(free_map) .OR. gj < 1 .OR. gj > SIZE(free_map)) THEN
      CALL fail(ErrStat, ErrMsg, 'band scatter global index out of range')
      RETURN
    END IF
    fi = free_map(gi)
    fj = free_map(gj)
    IF (fi == 0 .OR. fj == 0) RETURN
    row = kl + ku + 1 + fi - fj
    IF (row < 1 .OR. row > SIZE(ab, 1)) THEN
      CALL fail(ErrStat, ErrMsg, 'band scatter bandwidth too small')
      RETURN
    END IF
    ab(row, fj) = ab(row, fj) + value
  END SUBROUTINE scatter_scalar_band

  PURE FUNCTION reshape3(q, n_dof) RESULT(nodes)
    !! Copy the flat positions-only state into a (3, n_nodes) node array.
    INTEGER, INTENT(IN) :: n_dof
    REAL(wp), INTENT(IN) :: q(n_dof)
    REAL(wp) :: nodes(3, n_dof/3)
    nodes = RESHAPE(q, [3, n_dof/3])
  END FUNCTION reshape3

  SUBROUTINE validate_vector_field(source, n, name, ErrStat, ErrMsg)
    !! Validate a model-owned nodal scalar field without mutating storage.
    REAL(wp), INTENT(IN) :: source(:)
    INTEGER, INTENT(IN) :: n
    CHARACTER(*), INTENT(IN) :: name
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg

    ErrStat = CD_MODEL_OK
    ErrMsg = ''
    IF (SIZE(source) /= n) THEN
      CALL fail(ErrStat, ErrMsg, TRIM(name)//' update must have shape (n_nodes)')
      RETURN
    END IF
    IF (.NOT. CD_All_Finite(source)) THEN
      CALL fail(ErrStat, ErrMsg, TRIM(name)//' update must be finite')
    END IF
  END SUBROUTINE validate_vector_field

  SUBROUTINE validate_positive_vector(values, n, name, ErrStat, ErrMsg)
    !! Validate a finite positive element-wise coefficient vector.
    REAL(wp), INTENT(IN) :: values(:)
    INTEGER, INTENT(IN) :: n
    CHARACTER(*), INTENT(IN) :: name
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg

    ErrStat = CD_MODEL_OK
    ErrMsg = ''
    IF (SIZE(values) /= n) THEN
      CALL fail(ErrStat, ErrMsg, TRIM(name)//' must have shape (n_elem)')
      RETURN
    END IF
    IF (.NOT. CD_All_Finite(values) .OR. ANY(values <= CD_ZERO)) THEN
      CALL fail(ErrStat, ErrMsg, TRIM(name)//' must be finite and positive')
    END IF
  END SUBROUTINE validate_positive_vector

  SUBROUTINE validate_nonnegative_vector(values, n, name, ErrStat, ErrMsg)
    !! Validate a finite non-negative element-wise coefficient vector.
    REAL(wp), INTENT(IN) :: values(:)
    INTEGER, INTENT(IN) :: n
    CHARACTER(*), INTENT(IN) :: name
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg

    ErrStat = CD_MODEL_OK
    ErrMsg = ''
    IF (SIZE(values) /= n) THEN
      CALL fail(ErrStat, ErrMsg, TRIM(name)//' must have shape (n_elem)')
      RETURN
    END IF
    IF (.NOT. CD_All_Finite(values) .OR. ANY(values < CD_ZERO)) THEN
      CALL fail(ErrStat, ErrMsg, TRIM(name)//' must be finite and non-negative')
    END IF
  END SUBROUTINE validate_nonnegative_vector

  SUBROUTINE fail(ErrStat, ErrMsg, msg)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    CHARACTER(*), INTENT(IN) :: msg
    ErrStat = CD_MODEL_BADINPUT
    ErrMsg = 'CableDyn_Model: '//msg
  END SUBROUTINE fail

  SUBROUTINE alloc_fail(ErrStat, ErrMsg, msg)
    !! Distinct allocation-failure reporter: resource exhaustion is not malformed input, so
    !! these paths return CD_MODEL_ALLOCFAIL and let deck/system/C-ABI callers map it to their
    !! own allocation status rather than collapsing it to bad input or solve failure.
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    CHARACTER(*), INTENT(IN) :: msg
    ErrStat = CD_MODEL_ALLOCFAIL
    ErrMsg = 'CableDyn_Model: '//msg
  END SUBROUTINE alloc_fail

  SUBROUTINE model_step_force(self, q, v, force, ErrStat, ErrMsg)
    !! The force of the model's load contributors at (q, v) (model_step_loads).
    CLASS(model_step_loads), INTENT(INOUT) :: self
    REAL(wp), INTENT(IN) :: q(:), v(:)
    REAL(wp), INTENT(OUT) :: force(:)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    CALL model_contributor_force(self%model, q, v, force, ErrStat, ErrMsg)
    ErrStat = as_dyn_callback_status(ErrStat)
  END SUBROUTINE model_step_force

  SUBROUTINE model_step_load_banded(self, q, v, free, kl, ku, force, jac_q_band, jac_v_band, ErrStat, ErrMsg)
    !! The force and banded Jacobians of the model's load contributors at (q, v)
    !! (model_step_loads).
    CLASS(model_step_loads), INTENT(INOUT) :: self
    REAL(wp), INTENT(IN) :: q(:), v(:)
    INTEGER, INTENT(IN) :: free(:), kl, ku
    REAL(wp), INTENT(OUT) :: force(:), jac_q_band(:, :), jac_v_band(:, :)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    CALL model_contributor_load_banded(self%model, q, v, free, kl, ku, force, jac_q_band, jac_v_band, &
                                       ErrStat, ErrMsg)
  END SUBROUTINE model_step_load_banded

  SUBROUTINE model_step_added_mass_banded(self, q, accel, free, kl, ku, M_add_a, M_add_band, dMa_a_dq_band, &
                                          ErrStat, ErrMsg, need_tangent)
    !! The model's banded added mass at q (model_step_loads), on the lengths l0_mass when
    !! associated (a disassociated pointer is an absent l0_elem).
    CLASS(model_step_loads), INTENT(INOUT) :: self
    REAL(wp), INTENT(IN) :: q(:), accel(:)
    INTEGER, INTENT(IN) :: free(:), kl, ku
    REAL(wp), INTENT(OUT) :: M_add_a(:), M_add_band(:, :), dMa_a_dq_band(:, :)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    LOGICAL, INTENT(IN), OPTIONAL :: need_tangent
    CALL model_added_mass_banded(self%model, q, accel, free, kl, ku, M_add_a, M_add_band, dMa_a_dq_band, &
                                 ErrStat, ErrMsg, need_tangent=need_tangent, l0_elem=self%l0_mass)
    ErrStat = as_dyn_callback_status(ErrStat)
  END SUBROUTINE model_step_added_mass_banded

  PURE INTEGER FUNCTION as_dyn_callback_status(model_es) RESULT(dyn_es)
    !! Translate a model load-callback status into the integrator's namespace so an allocation
    !! failure inside model_contributor_load/_force is forwarded as CD_DYN_ALLOCFAIL (and preserved
    !! by the integrator) rather than collapsed to a generic dynamic failure. Other statuses pass
    !! through unchanged (the integrator treats any nonzero callback status as a failure).
    INTEGER, INTENT(IN) :: model_es
    IF (model_es == CD_MODEL_ALLOCFAIL) THEN
      dyn_es = CD_DYN_ALLOCFAIL
    ELSE
      dyn_es = model_es
    END IF
  END FUNCTION as_dyn_callback_status

  PURE INTEGER FUNCTION model_status_from_dyn(dyn_es) RESULT(model_es)
    !! Map an integrator status back into the model namespace at the dynamic-step / acceleration
    !! wrap sites, preserving a propagated allocation failure as CD_MODEL_ALLOCFAIL.
    INTEGER, INTENT(IN) :: dyn_es
    IF (dyn_es == CD_DYN_ALLOCFAIL) THEN
      model_es = CD_MODEL_ALLOCFAIL
    ELSE
      model_es = CD_MODEL_SOLVEFAIL
    END IF
  END FUNCTION model_status_from_dyn

END MODULE CableDyn_Model
