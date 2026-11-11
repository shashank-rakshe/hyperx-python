! File: src/CableDyn_HermiteCableDynamic.f90
! SPDX-License-Identifier: Apache-2.0
! Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
MODULE CableDyn_HermiteCableDynamic
  !! Finite-EI DYNAMICS of a cubic-Hermite bending-cable line (CableDyn_HermiteCable).
  !!
  !! The line is a chain of 2-node elements sharing interior nodes; each node carries
  !! [r(3), m(3)] with m = dr/ds, so the global state is 6*n_nodes position-like DOFs. Because
  !! there are NO rotation DOFs the equations of motion are the STANDARD nonlinear structural
  !! dynamics system
  !!   M q_ddot + f_int(q) = f_ext(q, t),
  !! with a CONSTANT consistent mass M (the reference-length cubic-Hermite mass), the closed-form
  !! internal force/tangent from CD_HermiteCable_Element, distributed self-weight, and a penalty
  !! seabed reaction. None of the Cosserat finite-EI complications arise: no |theta| < pi chart,
  !! no additive-vs-spatial angular-velocity bookkeeping, no gyroscopic term, no SO(3) tangent
  !! Jacobians -- q_ddot and q live in the same flat vector space, so the generalised-alpha step
  !! is the textbook Chung & Hulbert (1993) form.
  !!
  !! This is the finite-EI power-cable / lazy-wave DYNAMIC path: it inherits the wall-free Hermite
  !! element that the static solver (CableDyn_HermiteCableStatic) uses, so it can carry the same
  !! buoyant-arch geometries the Cosserat dynamic model cannot. The static solve provides the
  !! at-rest equilibrium seed; this module advances it in time under gravity, seabed contact,
  !! inertia, and optional Morison quadratic drag (CD_HermiteCable_Dyn_Set_Drag) -- the damping that
  !! makes a driven dynamic cable physical, consistently distributed over the Hermite shape functions
  !! (CD_HermiteCable_Drag_Element) so the material-tangent DOFs carry drag too. Boundary DOFs listed
  !! in fixed_dofs are held at rest by default, or driven by a prescribed time history
  !! (a moving fairlead / hang-off heave) via the
  !! optional pres_* arguments to CD_HermiteCable_Dyn_Step. The Newton solve starts from the
  !! Newmark predictor (or, when the motion is smooth, a constant-acceleration predictor) and is
  !! globalised with a backtracking line search so it stays robust at the large implicit dt the
  !! stiff (EA >> EI) cable demands; the velocity-dependent drag Jacobian is folded into the effective
  !! tangent through the Newmark dv/dq coupling. By default (CD_HC_FORCE_BLEND_DEFAULT) the
  !! residual blends the forces, G = M a_am + (1-af) r(q_{n+1}) + af r(q_n)
  !! (CD_HermiteCable_Dyn_Set_ForceBlend), rather than evaluating them at the blended state as
  !! written below, and the factored tangent of a committed step can start the next one
  !! (cross-step reuse, CD_HermiteCable_Dyn_Set_TangentReuse); the constant-acceleration
  !! predictor and the reuse apply to the force blend only. A regular (Airy) wave field
  !! (CD_HermiteCable_Dyn_Set_Waves) feeds the drag's fluid velocity and drives the Froude-Krylov +
  !! fluid-inertia load, evaluated at the generalised-alpha intermediate time each step.
  !!
  !! Generalised-alpha (Chung & Hulbert 1993), spectral radius rho_inf in [0,1]:
  !!   alpha_m = (2 rho_inf - 1)/(rho_inf + 1),  alpha_f = rho_inf/(rho_inf + 1),
  !!   beta = 1/4 (1 - alpha_m + alpha_f)^2,     gamma = 1/2 - alpha_m + alpha_f.
  !! Newmark update in the unknown q_{n+1}:
  !!   a_{n+1} = (q_{n+1}-q_n)/(beta dt^2) - v_n/(beta dt) - (1/(2 beta) - 1) a_n,
  !!   v_{n+1} = v_n + dt((1-gamma) a_n + gamma a_{n+1}).
  !! Residual at the generalised-alpha intermediate point (f_ext may depend on velocity via drag):
  !!   G(q_{n+1}) = M((1-alpha_m) a_{n+1} + alpha_m a_n)
  !!             + f_int((1-alpha_f) q_{n+1} + alpha_f q_n) - f_ext(q_alpha, v_alpha),
  !! effective tangent  dG/dq_{n+1} = (1-alpha_m)/(beta dt^2) M + (1-alpha_f) K(q_alpha)
  !!                                + (1-alpha_f) gamma/(beta dt) Kv(q_alpha, v_alpha),
  !! where Kv = dR/dv is the drag velocity Jacobian and gamma/(beta dt) = d v_{n+1}/d q_{n+1}.
  USE CableDyn_Precision, ONLY: wp, CD_ZERO, CD_ONE, CD_All_Finite, CD_Is_Finite
  USE CableDyn_SO3, ONLY: CD_Log_SO3
  USE CableDyn_FatalReport, ONLY: CD_Fatal_Thread_Init
  USE CableDyn_EndConnection, ONLY: CD_EndConn_Spring, CD_EndConn_Energy, &
                                    CD_EndConn_Reaction_Moment, CD_EndConn_Basis, &
                                    CD_EndConn_Project, CD_ENDCONN_OK, &
                                    CD_ENDCONN_PINNED, CD_ENDCONN_FINITE, CD_ENDCONN_RIGID
  USE CableDyn_HermiteCable, ONLY: CD_HermiteCable_Element, CD_HermiteCable_Mass, &
                                   CD_HermiteCable_Curvature, CD_HermiteCable_Shapes, &
                                   CD_HermiteCable_Gauss_Rule, &
                                   CD_HermiteCable_Axial_Resultant, &
                                   CD_HermiteCable_Axial_Strain_Lower_Bound, CD_HermiteCable_Dry_Buoyancy, &
                                   CD_HCABLE_OK
  USE CableDyn_Linalg, ONLY: CD_Factor_Banded, CD_Solve_Factored_Banded, CD_LINALG_OK
  USE CableDyn_VIV, ONLY: CD_VIV_Lift_Per_Length, CD_VIV_Crossflow_Along, CD_VIV_Phase_Rate, CD_VIV_Mean_Square, &
                          CD_VIV_Wrap_Phase, CD_VIV_TWO_PI, CD_VIV_NM
  USE CableDyn_Hydro, ONLY: CD_Morison_Drag_Per_Length_Jac, CD_Airy_Wave_Kinematics_Precomputed, &
                            CD_Component_Wave_Kinematics, CD_Solve_Dispersion_Wavenumber, CD_HYDRO_OK
  USE CableDyn_SeabedContact, ONLY: CD_Seabed_Normal_Law, CD_Seabed_Contact_Gate, CD_SEABED_CONTACT_BLEND, &
                                    CD_Seabed_Friction_Stick_Slip, CD_Seabed_Friction_Aniso, &
                                    CD_Seabed_Friction_Mu_Dir, CD_FRICTION_STICK_SLIP, CD_Seabed_End_Support, &
                                    CD_Seabed_End_Element_Share, CD_Seabed_Normal_Contact
  USE CableDyn_Bathymetry, ONLY: CD_BathymetryType, CD_Bathymetry_Is_Initialized, &
                                 CD_Bathymetry_Floor_Gradient, CD_End_Bathymetry, CD_BATHY_OK, &
                                 CD_Bathymetry_Rotate_Curvature
  USE CableDyn_Line, ONLY: CD_Nodal_Seabed_Stiffness, CD_LINE_OK
  USE CableDyn_HermiteTorsion, ONLY: CD_HermiteTorsionType, CD_HermiteTorsion_Line, CD_HermiteTorsion_Unwrap, &
                                     CD_HermiteTorsion_Compliance, CD_HermiteTorsion_Validate, CD_HTORS_OK, &
                                     CD_HTORS_MAX_STEP, CD_HermiteTorsionWorkType, CD_HermiteTorsion_Work_Init, &
                                     CD_HermiteTorsion_Work_End, CD_HermiteTorsion_Work_Add_Hessian, &
                                     CD_HermiteTorsion_Element_Stretch, CD_HermiteTorsion_Element, &
                                     CD_HermiteTorsion_Stretch_Derivatives, CD_HermiteTwist_Reference, &
                                     CD_HermiteTwist_Carry, CD_HermiteTwist_Angle, CD_HermiteTwist_Omega, &
                                     CD_HermiteTwist_Omega_Gradient, CD_HTORS_PI, CD_HermiteTorsion_Zeta_Damping
  USE, INTRINSIC :: ISO_FORTRAN_ENV, ONLY: INT64
!$ USE OMP_LIB, ONLY: omp_get_max_threads, omp_in_parallel
  IMPLICIT NONE
  PRIVATE

  PUBLIC :: CD_HermiteCableDynType
  PUBLIC :: CD_HermiteCable_Dyn_Init
  PUBLIC :: CD_HermiteCable_Dyn_Set_Drag
  PUBLIC :: CD_HermiteCable_Dyn_Set_Axial_Damping
  PUBLIC :: CD_HermiteCable_Dyn_Set_EndConnection
  PUBLIC :: CD_HermiteCable_Dyn_Set_Torsion
  PUBLIC :: CD_HermiteCable_Dyn_Torsion_State
  PUBLIC :: CD_HermiteCable_Dyn_Element_Twist
  PUBLIC :: CD_HermiteCable_Dyn_Coupling_Tension
  PUBLIC :: CD_HermiteCable_Dyn_Element_Torque, CD_HermiteCable_Dyn_Node_Torque, CD_HermiteCable_Dyn_End_Twist
  PUBLIC :: CD_HermiteCable_Dyn_Twist_Mirror_Size, CD_HermiteCable_Dyn_Twist_Pack, CD_HermiteCable_Dyn_Twist_Unpack
  PUBLIC :: CD_HermiteCable_Dyn_Twist_Check, CD_HermiteCable_Dyn_Twist_Hessian
  PUBLIC :: CD_HermiteCable_Dyn_Set_Torsion_Drive
  PUBLIC :: CD_HermiteCable_Dyn_Set_Torsion_Frames
  PUBLIC :: CD_HermiteCable_Dyn_EndConnection_Moment
  PUBLIC :: CD_HermiteCable_Dyn_Set_ModifiedNewton
  PUBLIC :: CD_HermiteCable_Dyn_Set_TangentReuse
  PUBLIC :: CD_HermiteCable_Dyn_Set_AdaptiveNewton
  PUBLIC :: CD_HermiteCable_Dyn_Set_Tensile_Safety
  PUBLIC :: CD_HermiteCable_Dyn_Set_Tensile_Monitor
  PUBLIC :: CD_HermiteCable_Dyn_Get_Tensile_Diagnostics
  PUBLIC :: CD_HermiteCable_Dyn_Get_Recovery_Diagnostics
  PUBLIC :: CD_HermiteCable_Dyn_Set_AddedMass
  PUBLIC :: CD_HermiteCable_Dyn_Set_Waves
  PUBLIC :: CD_HermiteCable_Dyn_Set_Held_Fluid
  PUBLIC :: CD_HermiteCable_Dyn_Set_Contact
  PUBLIC :: CD_HermiteCable_Dyn_Set_Attachments
  PUBLIC :: CD_HermiteCable_Attachment_Drag
  PUBLIC :: CD_HermiteCable_Dyn_Recompute_Acceleration
  PUBLIC :: CD_HermiteCable_Dyn_Set_SegmentLength
  PUBLIC :: CD_HermiteCableControlSaveType, CD_HermiteCable_Dyn_Save_Control, CD_HermiteCable_Dyn_Restore_Control
  PUBLIC :: CD_HermiteCable_Dyn_Set_Control_Seabed
  PUBLIC :: CD_HermiteCable_Dyn_On_Seabed
  PUBLIC :: CD_HermiteCable_Dyn_Set_Irregular_Waves
  PUBLIC :: CD_HermiteCable_Drag_Element
  PUBLIC :: CD_HermiteCable_Axial_Damping_Element
  PUBLIC :: CD_HermiteCable_Axial_Damping_Resultant
  PUBLIC :: CD_HermiteCable_AddedMass_Element
  PUBLIC :: CD_HermiteCable_FK_Element
  PUBLIC :: CD_HermiteCable_Dyn_Step
  PUBLIC :: CD_HermiteCable_Dyn_Step_Recovering
  PUBLIC :: CD_HermiteCable_Dyn_Recovery_Count, CD_HermiteCable_Dyn_Recovery_Reset
  PUBLIC :: CD_HermiteCable_Dyn_Snapshot
  PUBLIC :: CD_HermiteCable_Dyn_Set_Friction_Anchors
  PUBLIC :: CD_HermiteCable_Dyn_Set_Friction_Axial
  PUBLIC :: CD_HermiteCable_Dyn_Set_VIV
  PUBLIC :: CD_HermiteCable_Dyn_VIV_Node_Lift
  PUBLIC :: CD_HermiteCable_Dyn_Restore
  PUBLIC :: CD_HermiteCable_Dyn_Energy, CD_HermiteCable_Dyn_Momentum
  PUBLIC :: CD_HermiteCable_Dyn_Curvature
  PUBLIC :: CD_HermiteCable_Dyn_Section_Curvature
  PUBLIC :: CD_HermiteCable_Dyn_Reaction
  PUBLIC :: CD_HermiteCable_Dyn_Curvature_Exact
  PUBLIC :: CD_HermiteCable_Dyn_Side_EI, CD_HermiteCable_Dyn_Side_Curvature
  PUBLIC :: CD_HermiteCable_Dyn_Set_Output_Recovery
  PUBLIC :: CD_HermiteCable_Dyn_Node_Recovery
  PUBLIC :: CD_HermiteCable_Dyn_Node_Values
  PUBLIC :: CD_HermiteCable_Dyn_End_Force
  PUBLIC :: CD_HermiteCable_Dyn_Set_ForceBlend
  PUBLIC :: CD_HermiteCable_Dyn_Max_Step_Rotation
  ! Default generalised-alpha blend of the Hermite dynamics: force blend.
  LOGICAL, PARAMETER, PUBLIC :: CD_HC_FORCE_BLEND_DEFAULT = .TRUE.
  PUBLIC :: CD_HermiteCable_Dyn_End
  PUBLIC :: CD_HermiteCable_Dyn_Reset_Profile, CD_HermiteCable_Dyn_Disable_Profile, &
            CD_HermiteCable_Dyn_Get_Profile, CD_HermiteCable_Dyn_Get_Assembly_Profile
  PUBLIC :: CD_HermiteCable_Dyn_Profile_Enabled
  INTEGER, PARAMETER, PUBLIC :: CD_HCDYN_OK = 0, CD_HCDYN_BADINPUT = 1, CD_HCDYN_NOCONVERGE = 2
  INTEGER, PARAMETER, PUBLIC :: CD_HCDYN_TENSILE_OFF = 0
  INTEGER, PARAMETER, PUBLIC :: CD_HCDYN_TENSILE_WARN = 1
  INTEGER, PARAMETER, PUBLIC :: CD_HCDYN_TENSILE_ERROR = 2
  REAL(wp), PARAMETER :: CD_HCDYN_AXIAL_STRAIN_TOL = 2.0e-6_wp

  !! Diagnostic step-profile counters (performance instrumentation for the banded
  !! dynamic step): wall time and call counts attributed to the dynamic step's
  !! internal phases since the last reset, so a benchmark can split a run into
  !! element/hydro assembly (eval_res), dense effective-tangent formation + free-DOF
  !! reduction, the linear solve, and the frozen added-mass assembly, and can count
  !! the arrays allocated on the step path (zero unless a recovery rewind ran). Same contract as
  !! the Cosserat assembly counters: PROCESS-GLOBAL, single-run, single-threaded
  !! instrumentation -- not per-model and not synchronized; diagnostics only, never
  !! part of a numerical result.
  ! The line is a chain of 2-node elements with 6 DOF/node in nodal order, so every global
  ! operator (mass, stiffness, drag/FK Jacobians, effective tangent) couples DOFs at most 11
  ! apart: a constant half-bandwidth known a priori. All global matrices live in LAPACK
  ! general-band storage (DGBSV layout: entry (i, j) at ab(KL_D + KU_D + 1 + i - j, j), with
  ! KL_D extra top rows for the factorization fill) -- no dense matrices, no bandwidth scan.
  INTEGER, PARAMETER :: KL_D = 11, KU_D = 11
  ! Half-bandwidth of the nodal-twist tangent in 7-DOF-per-node order ([r, m, phi] per node).
  INTEGER, PARAMETER :: KB7 = 13
  INTEGER, PARAMETER :: LDAB_D = 2*KL_D + KU_D + 1
  ! First row of the stored band. Rows 1..KL_D are the factorization's fill-in space: every
  ! band array is allocated with them zero and only an LU factor (ws_Keffb) ever writes them,
  ! so the sweeps over the operators (zeroing, sums, the effective-tangent combination, the
  ! added-mass check) skip them.
  INTEGER, PARAMETER :: BAND_TOP_D = KL_D + 1

  ! Profiling is OFF by default: SYSTEM_CLOCK in the step/residual hot path is measurable
  ! overhead in a production run. CD_HermiteCable_Dyn_Reset_Profile ARMS it (a benchmark
  ! calls it before a timed run); production paths never call it, so they pay one branch.
  LOGICAL, SAVE :: prof_enabled = .FALSE.
  INTEGER, SAVE :: prof_n_step = 0        ! CD_HermiteCable_Dyn_Step calls
  INTEGER, SAVE :: prof_n_resid = 0       ! eval_res calls (predictor + accepted iterates + line-search trials)
  INTEGER, SAVE :: prof_n_tan = 0         ! tangent assemblies (once per continuing solve iteration)
  INTEGER, SAVE :: prof_n_solve = 0       ! effective-tangent linear solves (= Newton iterations)
  INTEGER, SAVE :: prof_n_factor = 0      ! LU factorisations of the effective tangent
  INTEGER, SAVE :: prof_n_correct = 0     ! force-blend corrections after convergence (one back-substitution)
  INTEGER, SAVE :: prof_n_am = 0          ! frozen added-mass assemblies (once per step when enabled)
  ! Arrays heap-allocated on the step path: the plain Step allocates none; the recovery
  ! rewind of CD_HermiteCable_Dyn_Step_Recovering allocates its interval buffers.
  INTEGER, SAVE :: prof_n_alloc = 0
  REAL(wp), SAVE :: prof_t_step = 0.0_wp  ! total Step wall (s)
  REAL(wp), SAVE :: prof_t_resid = 0.0_wp ! eval_res wall: element/drag/FK/contact assembly + inertia band matvec
  REAL(wp), SAVE :: prof_t_tan = 0.0_wp   ! tangent-assembly wall (element Hessian + drag/FK Jacobians + band scatters)
  REAL(wp), SAVE :: prof_t_eff = 0.0_wp   ! banded Keff triad + in-band Dirichlet wall
  REAL(wp), SAVE :: prof_t_solve = 0.0_wp ! back-substitution wall (Newton solves and force-blend corrections)
  REAL(wp), SAVE :: prof_t_factor = 0.0_wp ! LU factorisation wall of the effective tangent
  REAL(wp), SAVE :: prof_t_am = 0.0_wp    ! frozen added-mass assembly wall (band)
  ! assemble_residual split into its sections (asm_mark), summed over every assembly while the
  ! profile is armed: the residual and tangent assemblies above, and those made outside the step
  ! (committed force, reactions, end moments, consistent accelerations). The tangent element
  ! kernels evaluate the structural, damping, drag and wave tangents of each element together,
  ! in parallel.
  INTEGER, PARAMETER, PUBLIC :: HC_ASM_ZERO = 1, HC_ASM_TAN_KERNELS = 2, HC_ASM_SCATTER = 3, &
                                HC_ASM_STRUCT = 4, HC_ASM_WEIGHT = 5, HC_ASM_ATTACH = 6, HC_ASM_BUOY = 7, &
                                HC_ASM_CONTACT = 8, HC_ASM_DAMP = 9, HC_ASM_DRAG = 10, HC_ASM_ENDCONN = 11, &
                                HC_ASM_WAVE = 12, HC_ASM_HELD = 13, HC_ASM_TORSION = 14, HC_ASM_NSEC = 14
  CHARACTER(*), PARAMETER, PUBLIC :: HC_ASM_NAMES(HC_ASM_NSEC) = [CHARACTER(24) :: &
                                                                  'band zeroing', 'tangent element kernels', &
                                                                  'tangent scatter', 'structural residual', &
                                                                  'weight', 'attachments', 'dry buoyancy', &
                                                                  'seabed contact', 'axial damping', 'drag', &
                                                                  'end connections', 'wave Froude-Krylov', &
                                                                  'held Froude-Krylov', 'torsion']
  ! the same sections as one-word report keys (the OpenFAST module's key=value profile lines)
  CHARACTER(*), PARAMETER, PUBLIC :: HC_ASM_KEYS(HC_ASM_NSEC) = [CHARACTER(12) :: &
                                                                 'zero', 'tan_kernels', 'tan_scatter', &
                                                                 'structural', 'weight', 'attachments', &
                                                                 'buoyancy', 'contact', 'damping', 'drag', &
                                                                 'end_conn', 'wave_fk', 'held_fk', 'torsion']
  REAL(wp), SAVE :: prof_t_asm(HC_ASM_NSEC) = 0.0_wp

  ! Coupling intervals completed by internal generalised-alpha substeps (the nominal interval was
  ! too large for the prescribed boundary motion or environmental load), summed over every model
  ! while the profile is armed, for the profile reports of the driver and the OpenFAST module.
  ! Each model counts its own in recovery_event_count (CD_HermiteCable_Dyn_Get_Recovery_Diagnostics).
  INTEGER, SAVE :: prof_n_recover = 0

  TYPE :: CD_HermiteCableDynType
    !! Persistent finite-EI Hermite dynamic model: geometry, gen-alpha constants, and state.
    INTEGER :: ne = 0, nn = 0, ndof = 0
    INTEGER :: axial_quadrature_order = 4, bending_quadrature_order = 4
    REAL(wp), ALLOCATABLE :: l0(:), EA(:), EI(:), rho_a(:), w(:)   ! per element
    ! The cable's own bending stiffness per element, for the outputs: EI less the sleeve of a
    ! bend stiffener (STIFFENERS), and equal to EI on every element without one. The bend
    ! moment outputs report the cable's share EI_line kappa and the sleeve's the rest.
    REAL(wp), ALLOCATABLE :: EI_line(:)
    ! On a line with STIFFENERS, the local bending stiffness EI(s) at each node, one value per
    ! side: EI_node(1, j) the limit from element j - 1, EI_node(2, j) from element j, the same
    ! number where EI(s) is continuous. A one-per-element EI steps at every node of a taper
    ! without the section doing so, so the node outputs read these (node_values). Unallocated on
    ! a line without a stiffener, whose node outputs read EI per element.
    REAL(wp), ALLOCATABLE :: EI_node(:, :)
    ! Optional axial Kelvin-Voigt damping. BA is the axial constitutive dashpot
    ! coefficient [N s] after resolving the deck's direct-BA / negative-zeta convention.
    ! It is integrated over reference arc length with the same Hermite kinematics and
    ! axial quadrature as the elastic resultant. Off by default.
    LOGICAL :: has_axial_damping = .FALSE.
    REAL(wp), ALLOCATABLE :: BA(:)
    ! Active line control (CD_HermiteCable_Dyn_Set_SegmentLength): a host changes the
    ! unstretched lengths l0 of chosen elements between steps. has_ctrl is set by the first
    ! change; from then on l0_dot(ne) holds the unstretched-length rate of every element
    ! (zero outside the controlled span), which the axial damping subtracts from the strain
    ! rate. A model that is never controlled leaves has_ctrl false and l0_dot unallocated, so
    ! every evaluation is unchanged. BA keeps its initial resolution. On a line restrained in
    ! torsion every torsion term reads l0 when it is evaluated (the compliance sum l0/GJ, the
    ! nodal twist's GJ/l0 and Bt/l0, the coupling term (K/GJ)(l - l0), the element shape), the
    ! lumped polar inertia and a -zeta torsional damping are rebuilt with the other caches
    ! (torsion_length_terms), and the torsional damping takes the rate of the twist per length.
    LOGICAL :: has_ctrl = .FALSE.
    REAL(wp), ALLOCATABLE :: l0_dot(:)
    ! The lengths and rates the committed state was reached with (allocated with l0_dot, set
    ! at each commit): the force-blended committed force F_n = R(q_n, v_n, t_n) belongs to
    ! them, so the first step after a length change blends F_n at these lengths with
    ! R(q_{n+1}) at the new ones. ws_recovery_l0_c/ws_recovery_l0_dot_c are the step-start
    ! copies of the recovering step.
    REAL(wp), ALLOCATABLE :: l0_c(:), l0_dot_c(:), ws_recovery_l0_c(:), ws_recovery_l0_dot_c(:)
    ! Seabed recompute inputs of a controlled contact model (CD_HermiteCable_Dyn_Set_Control_Seabed):
    ! the per-area penalty kBot, the per-element contact diameter and cBot/kBot, so a length
    ! change rebuilds contact_kn/contact_cn with the helper the deck used at initialisation.
    LOGICAL :: has_seabed_recompute = .FALSE.
    REAL(wp) :: seabed_kbot = CD_ZERO, seabed_cn_over_kn = CD_ZERO
    REAL(wp), ALLOCATABLE :: seabed_diameter_elem(:)
    REAL(wp) :: seabed_z = CD_ZERO, kn = CD_ZERO
    REAL(wp), ALLOCATABLE :: trib(:)                              ! nodal tributary length
    ! Production standalone contact. contact_kn/contact_cn are nodal coefficients [N/m]
    ! and [N.s/m] of the deck's nodal seabed law. When absent, the scalar kn*tributary
    ! flat-bed term of CD_HermiteCable_Dyn_Init applies.
    LOGICAL :: has_contact = .FALSE., has_contact_bathymetry = .FALSE.
    REAL(wp) :: contact_mu = CD_ZERO, contact_frame_c = CD_ONE, contact_frame_s = CD_ZERO
    ! Anisotropic friction (CD_HermiteCable_Dyn_Set_Friction_Axial): contact_mu is then the
    ! lateral coefficient and contact_mu_axial the one along the nodal tangent.
    LOGICAL :: contact_fr_aniso = .FALSE.
    REAL(wp) :: contact_mu_axial = CD_ZERO
    REAL(wp), ALLOCATABLE :: contact_kn(:), contact_cn(:)
    TYPE(CD_BathymetryType) :: contact_bathymetry
    ! Stick-slip seabed friction (contact with mu > 0). Each node holds a horizontal spring
    ! of stiffness fr_k (the nodal normal stiffness) to its committed anchor
    ! fr_anchor(:, node); the spring force is capped at mu times the normal contact force
    ! and the anchor follows the node when the cap is reached (return mapping at the
    ! committed state). Set_Contact anchors the springs at the present positions;
    ! CD_HermiteCable_Dyn_Set_Friction_Anchors installs the force of a static solve with
    ! friction, which a spring then holds at rest. ws_recovery_fr is the step-start copy of
    ! the recovering step, snap_fr_anchor the aggregate snapshot.
    LOGICAL :: fr_active = .FALSE.
    REAL(wp), ALLOCATABLE :: fr_anchor(:, :), fr_k(:), ws_recovery_fr(:, :), snap_fr_anchor(:, :)
    ! Cross-flow VIV (CD_HermiteCable_Dyn_Set_VIV, CableDyn_VIV): viv_k(e) = 1/2 rho D Cl of each
    ! element (0: no lift), the synchronisation band and diameter per node, the shedding phase
    ! and the running mean squares of the cross-flow velocity and acceleration per node. The lift
    ! of a step takes viv_phi_eval (the committed phase for F_n, the step's predicted phase in
    ! the Newton iterations); viv_rate/viv_ms_next hold the step-start rate and mean squares.
    ! ws_recovery_viv_* is the step-start copy of the recovering step, snap_viv_* the snapshot.
    LOGICAL :: has_viv = .FALSE.
    ! the cross-flow phase of a node at rest (CD_VIV_Phase_Rate phi_rest): pi where the material
    ! tangent runs against MoorDyn's node tangent (End B to End A), 0 where it runs as MoorDyn's
    REAL(wp) :: viv_phi_rest = CD_ZERO
    REAL(wp) :: viv_tw = CD_ZERO
    REAL(wp), ALLOCATABLE :: viv_cl(:), viv_k(:), viv_cf(:), viv_df(:), viv_dn(:), viv_phi(:), viv_phi_eval(:)
    REAL(wp), ALLOCATABLE :: viv_rate(:), viv_ms(:, :), viv_ms_next(:, :)
    REAL(wp), ALLOCATABLE :: ws_recovery_viv_phi(:), ws_recovery_viv_ms(:, :), snap_viv_phi(:), snap_viv_ms(:, :)
    LOGICAL, ALLOCATABLE :: viv_node(:)
    REAL(wp), ALLOCATABLE :: Mgb(:, :)                            ! constant global mass (band)
    LOGICAL, ALLOCATABLE :: freemask(:), solve_mask(:)
    INTEGER, ALLOCATABLE :: fmap(:)                              ! free -> global DOF index
    REAL(wp), ALLOCATABLE :: q(:), v(:), a(:)                    ! dynamic state
    ! Step workspace, allocated ONCE at Init so a dynamic step performs ZERO heap
    ! allocations: the Newmark/gen-alpha state vectors, the residual/direction vectors,
    ! and the banded global operators (position tangent K, velocity tangent Kv, their
    ! line-search trial copies, the effective tangent, the total and added mass).
    REAL(wp), ALLOCATABLE :: ws_qn(:), ws_vn(:), ws_an(:), ws_qk(:), ws_ak(:)
    REAL(wp), ALLOCATABLE :: ws_recovery_q0(:), ws_recovery_v0(:), ws_recovery_a0(:)
    REAL(wp), ALLOCATABLE :: ws_qa(:), ws_aa(:), ws_va(:), ws_vk(:)
    REAL(wp), ALLOCATABLE :: ws_R(:), ws_G(:), ws_Gt(:), ws_inert(:), ws_qtrial(:), ws_dq(:)
    ! Force-blended generalised-alpha: the unblended residual R(q_{n+1}, v_{n+1}, t_{n+1}) of
    ! the current iterate (ws_Rk) and of a line-search trial (ws_Rt), and the force at the
    ! committed state F_n = R(q_n, v_n, t_n). F_n is cached from the previous step's converged
    ! evaluation and keyed on the exact state it was evaluated at (fc_q, fc_v, fc_t, fc_d0)
    ! plus fc_valid, which every load-configuration setter clears (counting the clears in
    ! fc_clears). A key mismatch (host-updated boundary, externally written state) recomputes
    ! it. The cache equals a fresh evaluation in value but not always in its last bits: the
    ! friction return mapping of the commit moves a sliding node's anchor, and the spring force
    ! of the moved anchor reproduces the capped force only to rounding. A run is therefore
    ! bit-reproducible along one path: Snapshot keeps the cache with the state, and Restore
    ! brings it back unless the cache was invalidated since (fc_clears), so a restored model
    ! takes the same path as one that was never rolled back.
    REAL(wp), ALLOCATABLE :: ws_Rk(:), ws_Rt(:), fc_R(:), fc_q(:), fc_v(:)
    REAL(wp) :: fc_t = 0.0_wp, fc_d0(3, 2) = 0.0_wp
    LOGICAL :: fc_valid = .FALSE.
    INTEGER :: fc_clears = 0
    REAL(wp), ALLOCATABLE :: snap_fc_R(:), snap_fc_q(:), snap_fc_v(:)
    REAL(wp) :: snap_fc_t = 0.0_wp, snap_fc_d0(3, 2) = 0.0_wp
    LOGICAL :: snap_fc_valid = .FALSE.
    INTEGER :: snap_fc_clears = 0
    ! fc_clears when the first step after the snapshot began: what happens to the cache after
    ! that (the setters of an output probe) is no part of the path a restored step must repeat
    LOGICAL :: snap_stepped = .FALSE.
    INTEGER :: snap_step_clears = 0
    ! Generalised-alpha blend: .TRUE. blends the forces (the default), .FALSE. evaluates the
    ! forces at the blended configuration q_alpha = (1-af) q_{n+1} + af q_n.
    LOGICAL :: force_blend = CD_HC_FORCE_BLEND_DEFAULT
    ! Largest turn of a nodal tangent over one committed step [rad] (run diagnostic).
    REAL(wp) :: max_step_rotation = 0.0_wp
    REAL(wp), ALLOCATABLE :: ws_Kb(:, :), ws_Kvb(:, :)
    REAL(wp), ALLOCATABLE :: ws_Keffb(:, :), ws_Msumb(:, :), ws_Mamb(:, :)
    INTEGER, ALLOCATABLE :: ws_ipiv(:)                    ! band-factorization pivots
    REAL(wp), ALLOCATABLE :: ws_elem_K(:, :, :), ws_elem_Kdrag(:, :, :)
    REAL(wp), ALLOCATABLE :: ws_elem_Kv(:, :, :), ws_elem_Kwave(:, :, :), ws_elem_Kheld(:, :, :)
    INTEGER, ALLOCATABLE :: ws_elem_es(:)
    CHARACTER(200), ALLOCATABLE :: ws_elem_em(:)
    ! Element tangents kept by a residual evaluation (assemble_residual with stash_tangent): the
    ! element loads of each kernel, ws_elem_f(:, k, e) for k = structure, axial damping, drag, VIV
    ! lift, wave and held Froude-Krylov, the element tangent blocks in ws_elem_K..ws_elem_Kheld,
    ! and the configuration, velocity and time of that evaluation. A tangent assembly at the same
    ! state (use_stash) scatters the kept blocks instead of evaluating the kernels again. Every
    ! other assembly clears ws_stash_ok.
    REAL(wp), ALLOCATABLE :: ws_elem_f(:, :, :), ws_stash_q(:), ws_stash_v(:)
    REAL(wp) :: ws_stash_t = CD_ZERO
    LOGICAL :: ws_stash_ok = .FALSE.
    ! The Newton solves of the last committed step (1 before the first): the predictor, which the
    ! first iteration's tangent follows at the same state, keeps its element tangents when the
    ! last step made a solve (did not converge at its predictor).
    INTEGER :: ws_stash_solves = 1
    ! The tangents the last committed step's line searches assembled at their accepted trial: the
    ! full step of a full-Newton line search keeps its element tangents while the step has
    ! assembled fewer.
    INTEGER :: ws_stash_ls = 0
    REAL(wp) :: alpha_m = CD_ZERO, alpha_f = CD_ZERO, beta = CD_ZERO, gamma = CD_ZERO
    ! Optional Morison drag (transverse + tangential quadratic drag on the submerged cable, relative
    ! to a uniform fluid velocity). Off by default; wired in via CD_HermiteCable_Dyn_Set_Drag.
    LOGICAL :: has_drag = .FALSE.
    REAL(wp) :: rho_w = CD_ZERO, waterline_z = CD_ZERO, current(3) = CD_ZERO
    REAL(wp), ALLOCATABLE :: diam(:), cdn(:), cdt(:)             ! per element
    ! The drag configuration also defines the free surface and the displaced section
    ! (rho_w, diam): the part of the line above the surface regains its buoyancy
    ! rho_w*gravity*pi*diam^2/4 per reference length (see CD_HermiteCable_Dry_Buoyancy).
    REAL(wp) :: gravity = 9.80665_wp
    ! Optional Morison added mass (normal/tangential fluid-inertia coefficients on the submerged
    ! cable). Off by default; wired in via CD_HermiteCable_Dyn_Set_AddedMass. Kept independent of the
    ! drag configuration so either effect can be enabled alone.
    LOGICAL :: has_am = .FALSE.
    REAL(wp) :: am_rho = CD_ZERO, am_wl = CD_ZERO
    REAL(wp), ALLOCATABLE :: am_diam(:), am_can(:), am_cat(:)    ! per element
    ! Optional regular (Airy) wave field. Off by default; wired in via CD_HermiteCable_Dyn_Set_Waves.
    ! The wave velocity feeds the drag's fluid field (requires the drag config); the wave
    ! acceleration feeds the Froude-Krylov + fluid-inertia load with coefficients (1 + Can/Cat) from
    ! the added-mass config (requires it).
    LOGICAL :: has_wave = .FALSE.
    REAL(wp) :: wv_h = CD_ZERO, wv_om = CD_ZERO, wv_k = CD_ZERO, wv_depth = CD_ZERO, wv_dir = CD_ZERO
    ! Optional COMPONENT (irregular) wave field, wired in via
    ! CD_HermiteCable_Dyn_Set_Irregular_Waves: a caller-supplied long-crested component
    ! table (amplitude/frequency/wavenumber/phase per component) sharing wv_depth/wv_dir
    ! with the scalar field above. wv_ncomp = 0 -> the scalar regular field is active
    ! (when has_wave); wv_ncomp > 0 -> the component field is active and the scalar
    ! trio is cleared. The two are mutually exclusive by construction.
    INTEGER :: wv_ncomp = 0
    REAL(wp), ALLOCATABLE :: wv_ampc(:), wv_omc(:), wv_kc(:), wv_phc(:)
    ! exp(-2 wv_kc(i) wv_depth), fixed with the table (refresh_wave_table)
    REAL(wp), ALLOCATABLE :: wv_e2kd(:)
    ! Optional HELD ambient-fluid field, wired in via CD_HermiteCable_Dyn_Set_Held_Fluid:
    ! per-NODE fluid velocity/acceleration and local free-surface elevation prescribed by
    ! an external host (e.g. the OpenFAST shell sampling a SeaState WaveField) and held
    ! FROZEN over each step -- the weak-coupling cadence the coupled loads-out side
    ! documents. Consumed per ELEMENT as the two end nodes' average (the same
    ! granularity the host sampled at). Mutually exclusive with the internal wave
    ! families; requires the drag config (velocity) and adds Froude-Krylov forcing when
    ! the added-mass config is present (acceleration).
    LOGICAL :: has_held_field = .FALSE.
    ! Line-end bending connection at node 1 and node nn. Finite mode uses the
    ! isotropic spring; rigid mode is an exact tangent-direction constraint. The
    ! default pinned mode contributes nothing and remains bit-identical.
    LOGICAL :: has_endconn = .FALSE.
    INTEGER :: endconn_mode(2) = CD_ENDCONN_PINNED
    REAL(wp) :: endconn_k(2) = CD_ZERO
    REAL(wp) :: endconn_d0(3, 2) = CD_ZERO
    REAL(wp), ALLOCATABLE :: hf_u(:, :), hf_ud(:, :), hf_wl(:)   ! (3, nn), (3, nn), (nn)
    ! Discrete point attachments (clumps, buoyancy modules) lumped at nodes: node att_node(k)
    ! carries the net weight att_w(k) = (m - rho V) g [N], the buoyancy att_b(k) = rho g V
    ! [N] it loses above the free surface, the fluid-inertia coefficient att_fk(k) =
    ! rho V (1 + Ca) [kg], and the drag areas normal (att_cda) and axial (att_cdax) to the
    ! line tangent at the node [m^2] with the fluid density att_rho. Its mass
    ! plus added mass m + Ca rho V is part of the constant mass Mgb.
    LOGICAL :: has_attach = .FALSE.
    ! Set by a checkpoint-restart reload (CD_HFMF_UnpackMirror): the committed acceleration is
    ! a generalised-alpha history value, so the first held fluid field after the reload must
    ! preserve it instead of re-deriving an initial-condition acceleration.
    LOGICAL :: a_restored = .FALSE.
    INTEGER, ALLOCATABLE :: att_node(:)
    REAL(wp), ALLOCATABLE :: att_w(:), att_b(:), att_fk(:), att_cda(:), att_cdax(:)
    ! The two nodal mass terms each attachment adds to Mgb, the dry mass m and the added mass
    ! Ca rho V, kept so that a length change rebuilds Mgb in the order initialisation used.
    REAL(wp), ALLOCATABLE :: att_mass(:), att_madd(:)
    REAL(wp) :: att_rho = CD_ZERO
    ! Rollback copies of CD_HermiteCable_Dyn_Set_Held_Fluid, kept so a per-step field update
    ! allocates nothing: a (ndof), hf_u/hf_ud (3, nn), hf_wl (nn).
    REAL(wp), ALLOCATABLE :: ws_hf_a_old(:), ws_hf_u_old(:, :), ws_hf_ud_old(:, :), ws_hf_wl_old(:)
    ! Simulation time (s): 0 at Init, advanced by Step; wave loads evaluate at the generalised-alpha
    ! intermediate time within each step.
    REAL(wp) :: t = CD_ZERO
    ! Snapshot of the COMMITTED step state (q, v, a, t) for the aggregate stage-then-commit
    ! contract: a multi-object caller snapshots every sub-object before stepping and
    ! restores them all if any later sub-step fails, so a failed aggregate step can never
    ! leave partially advanced state. Buffers allocate on first Snapshot (amortised zero;
    ! never touched by Step itself).
    REAL(wp), ALLOCATABLE :: snap_q(:), snap_v(:), snap_a(:)
    ! The unstretched lengths and their rates join the snapshot (active line control): a
    ! restore that changes l0 rebuilds the length-dependent caches from the restored lengths.
    REAL(wp), ALLOCATABLE :: snap_l0(:), snap_l0_dot(:), snap_l0_c(:), snap_l0_dot_c(:)
    LOGICAL :: snap_has_ctrl = .FALSE.
    REAL(wp) :: snap_t = CD_ZERO
    REAL(wp) :: snap_endconn_d0(3, 2) = CD_ZERO
    ! Condensed torsion (CD_HermiteCable_Dyn_Set_Torsion): end frames, GJ, imposed twist Phi and
    ! the accepted (unwrapped) Theta of the committed state; the residual, the tangent, the end
    ! loads and the energy include E_t = (Phi - Theta)**2/(2 C). A step drives the end frames and
    ! Phi to the target of CD_HermiteCable_Dyn_Set_Torsion_Drive (held without one): the step
    ! keeps that target in tors_step_ends/tors_step_phi and the residual uses it (tors_use_step)
    ! once the committed force F_n is evaluated; the commit makes it the committed frames and Phi,
    ! with Theta at q_{n+1}. Allocation-free step scratch: tors_work (the kernel), tors_g
    ! (dTheta/dq at the last tangent), tors_gq (at the last residual), tors_gk and tors_zk (tors_g
    ! in the solve coordinates and K_eff^-1 of it, kept with the factor) and tors_den
    ! (C/(1 - alpha_f) + tors_gk . tors_zk) of the Sherman-Morrison (bordered) solve. snap_* are
    ! the frames, Phi and Theta of the last snapshot.
    TYPE(CD_HermiteTorsionType) :: torsion
    TYPE(CD_HermiteTorsionWorkType) :: tors_work
    REAL(wp), ALLOCATABLE :: tors_g(:), tors_gq(:), tors_gk(:), tors_zk(:)
    REAL(wp) :: tors_den = CD_ZERO
    LOGICAL :: tors_use_step = .FALSE., tors_drive_set = .FALSE.
    REAL(wp) :: tors_step_ends(3, 4) = CD_ZERO, tors_step_phi = CD_ZERO
    REAL(wp) :: tors_drive_ends(3, 4) = CD_ZERO, tors_drive_phi = CD_ZERO
    REAL(wp) :: snap_torsion_theta = CD_ZERO, snap_torsion_phi = CD_ZERO, snap_torsion_ends(3, 4) = CD_ZERO
    ! the committed torque of the snapshot, kept as it was formed (under active line control the
    ! committed state's compliance is that of the committed lengths, not of the present ones)
    REAL(wp) :: snap_torsion_torque = CD_ZERO
    ! Torsion query cache (allocation-free read-only queries): Theta, dTheta/d[w_1, w_2] and
    ! dTheta/dr at both end nodes, evaluated at tors_c_q with the end frames tors_c_ends and
    ! unwrapped against tors_c_prev. A query uses it only when the model's q, end frames and
    ! accepted Theta are bitwise those, so it can never be stale; otherwise it re-evaluates.
    REAL(wp), ALLOCATABLE :: tors_c_q(:)
    REAL(wp) :: tors_c_ends(3, 4) = CD_ZERO, tors_c_prev = CD_ZERO, tors_c_theta = CD_ZERO
    REAL(wp) :: tors_c_eg(6) = CD_ZERO, tors_c_gend(3, 2) = CD_ZERO
    LOGICAL :: tors_c_valid = .FALSE.
    ! Nodal twist (the torsion carries the polar inertia irn; CD_HermiteCable_Dyn_Set_Torsion):
    ! a twist angle phi per node, the angle about the node tangent from the reference director
    ! u to the material director, replaces the condensed torque in the dynamics. The directors
    ! follow the node tangents by the smallest rotation over each step (time-parallel
    ! transport), so the axial angular velocity of a section is phi_dot. Element e twists by
    ! phi_{e+1} - phi_e + rho_e(q), rho_e = beta_e - h_e + (K/GJ)(l_e - l0) (beta_e the angle
    ! from u_e carried to node e + 1 to u_{e+1}, h_e the element holonomy), and carries the
    ! torque M_e = (GJ/l0)(phi_{e+1} - phi_e + rho_e) + (Bt/l0) d/dt(...). An elastic end adds a
    ! spring k (twist of the end node against its end frame); a rigid end takes the end frame's
    ! normal carried to the node as its director and holds phi (0 at end 1, Phi at end 2).
    ! Committed state: tw_phi/tw_w/tw_al (angle, rate, acceleration; nn), tw_u and tw_tn
    ! (directors and unit tangents; 3 x nn), tw_beta (ne), tw_psi (the end-frame reference of
    ! an elastic end) and tw_mt (element torques, ne). tw_mass is the lumped polar inertia.
    ! Step scratch: tw_pn/wn/an (step start), tw_pk/wk/ak (iterate), tw_ptrial, tw_dp, tw_G,
    ! tw_Gt, tw_Rk, tw_Rt, tw_R (phi residual of the last assembly), tw_fcR (the force cache's
    ! phi part), tw_pe/tw_we (the angles and rates the assembly reads in a step), the element
    ! and end-link tangent data of the last tangent assembly (tw_eg, tw_ehv, tw_ek, tw_ed,
    ! tw_lg, tw_lk), the element torques of the last assembly (tw_me), and the 7-DOF-per-node
    ! effective tangent tw_K7 with its pivots and solve vector (KL = KU = 13).
    LOGICAL :: tw_active = .FALSE.
    LOGICAL :: tw_rigid(2) = .FALSE.
    REAL(wp), ALLOCATABLE :: tw_phi(:), tw_w(:), tw_al(:), tw_mass(:), tw_u(:, :), tw_tn(:, :)
    REAL(wp), ALLOCATABLE :: tw_beta(:), tw_mt(:)
    REAL(wp) :: tw_psi(2) = CD_ZERO
    LOGICAL, ALLOCATABLE :: tw_free(:)
    REAL(wp), ALLOCATABLE :: tw_pn(:), tw_wn(:), tw_an(:), tw_pk(:), tw_wk(:), tw_ak(:), tw_ptrial(:), tw_dp(:)
    REAL(wp), ALLOCATABLE :: tw_G(:), tw_Gt(:), tw_Rk(:), tw_Rt(:), tw_R(:), tw_fcR(:), tw_pe(:), tw_we(:)
    REAL(wp), ALLOCATABLE :: tw_eg(:, :), tw_ehv(:, :), tw_ek(:), tw_ed(:), tw_me(:)
    REAL(wp) :: tw_lg(3, 2) = CD_ZERO, tw_lk(2) = CD_ZERO
    REAL(wp), ALLOCATABLE :: tw_K7(:, :), tw_x7(:)
    INTEGER, ALLOCATABLE :: tw_ipiv(:)
    ! tw_tsum: the summed element and end-link twists (Phi less the condensed Theta_eff in a
    ! quasi-static state) of the last assembly; tw_su/tw_stn/tw_sbeta/tw_spsi: the reference
    ! state at q_{n+1} (tw_advance_reference) awaiting the commit; tw_tscale: the torque scale of
    ! the step's residual norm.
    REAL(wp) :: tw_tsum = CD_ZERO, tw_spsi(2) = CD_ZERO, tw_tscale = CD_ONE
    REAL(wp), ALLOCATABLE :: tw_su(:, :), tw_stn(:, :), tw_sbeta(:)
    ! tw_som(:, k): the angular velocity of end frame k over the running step, log(R_{n+1}
    ! R_n^T)/dt (R = [d n d x n]); tw_om: that of the committed step. A turning frame twists
    ! the element at a rigid end through rho, and the torsional damping takes that rate.
    ! tw_oal: the frames' angular acceleration at the committed state, (tw_om - its value one
    ! step earlier)/dt, which turns the held end section's polar inertia (the support reaction).
    REAL(wp) :: tw_som(3, 2) = CD_ZERO, tw_om(3, 2) = CD_ZERO, tw_oal(3, 2) = CD_ZERO
    ! Packed twist state (tw_pack) of the recovering step's interval start and of the snapshot,
    ! and the snapshot's tw_fcR.
    REAL(wp), ALLOCATABLE :: ws_recovery_tw(:), snap_tw(:), snap_tw_fcR(:)
    LOGICAL :: snap_valid = .FALSE.
    ! Adaptive-Newton warmup counters are step-history too: a staged step (aggregate
    ! stage-then-commit) that advances them and is then rolled back must restore them, or the
    ! warmup measurement/decision desyncs from the committed step count.
    INTEGER :: snap_na_steps_done = 0
    REAL(wp) :: snap_na_iter_sum = CD_ZERO
    LOGICAL :: snap_na_mn_active = .FALSE.
    INTEGER :: snap_tensile_event_count = 0, snap_tensile_worst_element = 0
    REAL(wp) :: snap_tensile_worst_force = CD_ZERO, snap_tensile_worst_threshold = CD_ZERO
    REAL(wp) :: snap_tensile_worst_xi = CD_ZERO, snap_tensile_worst_time = CD_ZERO
    REAL(wp) :: snap_max_step_rotation = CD_ZERO
    INTEGER :: snap_recovery_event_count = 0, snap_recovery_max_substeps_used = 0
    ! Modified Newton (tangent reuse): factor the effective tangent ONCE per step (at the
    ! predictor) and reuse the factorization for every subsequent iteration of that step;
    ! a line search that finds no improving step under the stale direction triggers ONE
    ! refresh (rebuild + refactor at the current iterate) before the safe damped fallback.
    ! Within-step reuse is off by default (cross-step reuse, below, is on). Wired in
    ! via CD_HermiteCable_Dyn_Set_ModifiedNewton (the deck OPTIONS modified_newton).
    LOGICAL :: modified_newton = .FALSE.
    ! Cross-step factor reuse (on by default; CD_HermiteCable_Dyn_Set_TangentReuse): the
    ! factored effective tangent of the last committed step (ws_Keffb/ws_ipiv) starts the next
    ! step's Newton when that step continues bitwise from the committed state (the force-cache
    ! key) at the same dt and its predictor test finds the motion smooth (the constant-
    ! acceleration guess runs). The factor is kept while each accepted iterate contracts the residual
    ! to <= 1/4 of the previous one (the modified-Newton gate),
    ! for at most three iterations, and is otherwise refreshed at the current iterate (full
    ! Newton for the rest of the step); a stale direction that finds no improving step refreshes
    ! once before the damped fallback, and a step that fails on the carried factor is re-solved
    ! from the Newmark guess on a fresh tangent. Only the Newton matrix is reused: every step
    ! converges on the exact residual (to 0.3 tol while on the carried factor, so the outputs
    ! stay as close to the converged solution as full Newton's), but the iterate it stops at depends
    ! on the factor's age, which no checkpoint carries, so a restart is exact only with reuse
    ! off. tr_valid marks a usable factor for step size tr_dt; any other writer of ws_Keffb,
    ! every setter and Restore clear it.
    LOGICAL :: tangent_reuse = .TRUE.
    ! Back-off: a step on the carried factor that still factorised at least as often as the
    ! last fresh step (xs_fresh_fact factorisations) saved nothing -- in a fast-changing
    ! geometry, Newton from the stale factor's iterate costs more than from the predictor. It
    ! makes the next xs_skip steps factor fresh; xs_backoff doubles on each consecutive such
    ! step (to XS_MAX_BACKOFF) and resets when a reuse step saves a factorisation.
    INTEGER :: xs_skip = 0, xs_backoff = 0, xs_fresh_fact = 0
    LOGICAL :: tr_valid = .FALSE.
    REAL(wp) :: tr_dt = CD_ZERO
    ! Adaptive modified Newton: run the first na_warmup steps in FULL Newton to measure the
    ! per-step iteration count, then enable tangent reuse for the rest of the run IFF the warmup
    ! averaged more than na_threshold iterations/step -- reuse pays on harder/larger systems
    ! and costs the refresh overhead on easy ones. Off by default (the
    ! explicit modified_newton flag still forces reuse); set via CD_HermiteCable_Dyn_Set_AdaptiveNewton.
    LOGICAL :: newton_adaptive = .FALSE.
    INTEGER :: na_warmup = 4
    REAL(wp) :: na_threshold = 5.0_wp
    INTEGER :: na_steps_done = 0
    REAL(wp) :: na_iter_sum = 0.0_wp
    LOGICAL :: na_mn_active = .FALSE.
    ! Continuous axial-resultant audit. The compatibility logical is true only for the
    ! hard-reject mode; tensile_mode also provides a non-fatal, counted warning mode for long runs.
    LOGICAL :: require_tensile = .FALSE.
    INTEGER :: tensile_mode = CD_HCDYN_TENSILE_OFF
    REAL(wp) :: tensile_strain_tolerance = CD_HCDYN_AXIAL_STRAIN_TOL
    INTEGER :: tensile_event_count = 0, tensile_worst_element = 0
    REAL(wp) :: tensile_worst_force = CD_ZERO, tensile_worst_threshold = CD_ZERO
    REAL(wp) :: tensile_worst_xi = CD_ZERO, tensile_worst_time = CD_ZERO
    INTEGER :: recovery_event_count = 0, recovery_max_substeps_used = 0
    ! Node output definitions (CD_HermiteCable_Dyn_Set_Output_Recovery): equilibrium recovery
    ! by default, the element-mean axial force and exact curvature traces when set.
    LOGICAL :: output_element_recovery = .FALSE.
    ! Smallest bending stiffness [N m^2] whose recovered bend moment resolves a curvature: the largest
    ! consistent-load moment w L0^2/12 of an element over a 1 m bend radius. The moment recovered
    ! from nodal equilibrium carries an error of that order, independent of EI, so over a softer
    ! section it cannot give the curvature (node_values then takes the exact geometric trace).
    REAL(wp) :: ei_resolve = CD_ZERO
    ! Cache of the element end residuals behind the node outputs (CD_HermiteCable_Dyn_Node_Values).
    ! Element e's entry rc_g(:, e) is valid for the time and configuration epoch the cache was
    ! keyed at (rc_t, rc_key_epoch) and for the element's own 12 q, v and a DOFs it was evaluated
    ! at (rc_q/rc_v/rc_a(:, e)), and for the positions of the neighbouring nodes e - 1 and e + 2
    ! (rc_qnb(:, e); their floor contact decides the share of the floor reaction the element
    ! carries), the only state its residual depends on, so a node query costs two element
    ! comparisons and the channels of one output row share one evaluation per element.
    ! Allocated once at initialisation; rc_epoch counts the loads configured after it (drag,
    ! axial damping, waves, added mass, held fluid, contact).
    INTEGER :: rc_epoch = 0, rc_key_epoch = -1
    LOGICAL :: rc_key_ok = .FALSE.
    REAL(wp) :: rc_t = CD_ZERO
    REAL(wp), ALLOCATABLE :: rc_q(:, :), rc_v(:, :), rc_a(:, :), rc_g(:, :), rc_qnb(:, :)
    LOGICAL, ALLOCATABLE :: rc_have(:)
    LOGICAL :: initialized = .FALSE.
  END TYPE CD_HermiteCableDynType

  TYPE :: CD_HermiteCableControlSaveType
    !! What CD_HermiteCable_Dyn_Set_SegmentLength writes, as CD_HermiteCable_Dyn_Save_Control
    !! found it (the length caches are rebuilt from the lengths on a restore).
    LOGICAL :: valid = .FALSE., has_ctrl = .FALSE., tr_valid = .FALSE., rates = .FALSE.
    REAL(wp), ALLOCATABLE :: l0(:), l0_dot(:), l0_c(:), l0_dot_c(:)
  END TYPE CD_HermiteCableControlSaveType

  TYPE :: committed_lengths_aside
    !! The present lengths, rates and length caches of a controlled model, set aside while
    !! one evaluation of the committed state runs with the lengths and rates that state was
    !! reached with (enter_committed_lengths / leave_committed_lengths).
    LOGICAL :: lengths = .FALSE., rates = .FALSE.
    REAL(wp), ALLOCATABLE :: l0(:), rate(:), mgb(:, :), trib(:), kn(:), cn(:), frk(:)
  END TYPE committed_lengths_aside

CONTAINS

  LOGICAL FUNCTION CD_HermiteCable_Dyn_Profile_Enabled() RESULT(enabled)
    !! Process-global profiling counters are intentionally unsynchronised diagnostics.
    !! Aggregate callers query this flag to keep profiled multi-cable runs serial.
    enabled = prof_enabled
  END FUNCTION CD_HermiteCable_Dyn_Profile_Enabled

  SUBROUTINE CD_HermiteCable_Dyn_Reset_Profile()
    !! Zero the diagnostic step-profile counters and ARM the instrumentation (call before a
    !! timed run). Profiling stays off until this is called, so production runs never pay
    !! the SYSTEM_CLOCK overhead in the step/residual hot path.
    prof_enabled = .TRUE.
    prof_n_step = 0; prof_n_resid = 0; prof_n_solve = 0; prof_n_am = 0; prof_n_alloc = 0
    prof_n_tan = 0; prof_n_factor = 0; prof_n_correct = 0; prof_n_recover = 0
    prof_t_step = 0.0_wp; prof_t_resid = 0.0_wp; prof_t_eff = 0.0_wp
    prof_t_tan = 0.0_wp; prof_t_factor = 0.0_wp
    prof_t_solve = 0.0_wp; prof_t_am = 0.0_wp
    prof_t_asm = 0.0_wp
  END SUBROUTINE CD_HermiteCable_Dyn_Reset_Profile

  SUBROUTINE CD_HermiteCable_Dyn_Disable_Profile()
    !! Disarm process-global diagnostic timing. A host library can execute several
    !! sequential cases in one process; a non-profiled case must not inherit the
    !! timing overhead or serial multi-cable policy from an earlier profiled case.
    prof_enabled = .FALSE.
  END SUBROUTINE CD_HermiteCable_Dyn_Disable_Profile

  SUBROUTINE CD_HermiteCable_Dyn_Get_Assembly_Profile(seconds)
    !! Time of each assemble_residual section (HC_ASM_*, names HC_ASM_NAMES) since the last
    !! CD_HermiteCable_Dyn_Reset_Profile; zero unless the profile is armed.
    REAL(wp), INTENT(OUT) :: seconds(HC_ASM_NSEC)
    seconds = prof_t_asm
  END SUBROUTINE CD_HermiteCable_Dyn_Get_Assembly_Profile

  SUBROUTINE asm_mark(section, last)
    !! Add the time since last to section and restart from now (profiled runs only). Called on
    !! the thread that runs assemble_residual, outside its parallel loop; a profiled run steps
    !! its cables one at a time, so the plain update is safe.
    INTEGER, INTENT(IN) :: section
    INTEGER(INT64), INTENT(INOUT) :: last
    INTEGER(INT64) :: now, rate
    IF (.NOT. prof_enabled) RETURN
    CALL SYSTEM_CLOCK(now, rate)
    IF (rate > 0_INT64) prof_t_asm(section) = prof_t_asm(section) + REAL(now - last, wp)/REAL(rate, wp)
    last = now
  END SUBROUTINE asm_mark

  SUBROUTINE CD_HermiteCable_Dyn_Get_Profile(n_step, n_resid, n_solve, n_am, n_alloc, &
                                             t_step, t_resid, t_eff, t_solve, t_am, n_tan, t_tan, &
                                             n_factor, t_factor, n_correct)
    !! Read the diagnostic step-profile counters accumulated since the last reset.
    !! t_step is the total wall inside CD_HermiteCable_Dyn_Step; t_resid + t_tan + t_eff +
    !! t_factor + t_solve + t_am partition its instrumented interior (the remainder is
    !! predictor/commit bookkeeping and workspace allocation). t_solve is the back-substitution
    !! time of the n_solve Newton solves and the n_correct force-blend corrections; t_factor the
    !! time of the n_factor LU factorisations.
    INTEGER, INTENT(OUT) :: n_step, n_resid, n_solve, n_am, n_alloc
    REAL(wp), INTENT(OUT) :: t_step, t_resid, t_eff, t_solve, t_am
    ! n_tan/t_tan report the tangent assemblies separately from the residual evaluations,
    ! so the eval_res averages stay honest (OPTIONAL so callers may omit them).
    INTEGER, INTENT(OUT), OPTIONAL :: n_tan
    REAL(wp), INTENT(OUT), OPTIONAL :: t_tan
    INTEGER, INTENT(OUT), OPTIONAL :: n_factor, n_correct
    REAL(wp), INTENT(OUT), OPTIONAL :: t_factor
    n_step = prof_n_step; n_resid = prof_n_resid; n_solve = prof_n_solve
    n_am = prof_n_am; n_alloc = prof_n_alloc
    t_step = prof_t_step; t_resid = prof_t_resid; t_eff = prof_t_eff
    t_solve = prof_t_solve; t_am = prof_t_am
    IF (PRESENT(n_tan)) n_tan = prof_n_tan
    IF (PRESENT(t_tan)) t_tan = prof_t_tan
    IF (PRESENT(n_factor)) n_factor = prof_n_factor
    IF (PRESENT(t_factor)) t_factor = prof_t_factor
    IF (PRESENT(n_correct)) n_correct = prof_n_correct
  END SUBROUTINE CD_HermiteCable_Dyn_Get_Profile

  SUBROUTINE CD_HermiteCable_Dyn_Init(model, l0, EA, EI, rho_a, w, seed, fixed_dofs, &
                                      seabed_z, kn, rho_inf, ErrStat, ErrMsg, &
                                      axial_quadrature_order, bending_quadrature_order)
    !! Initialise the Hermite dynamic model: validate, assemble the constant mass, store the
    !! at-rest state (v = 0), and solve the consistent initial acceleration M a0 = f_ext - f_int.
    !!
    !! l0/EA/EI/rho_a/w(ne) : per-element rest length, axial/bending stiffness, mass per length,
    !!                        signed submerged weight per length (>0 net-heavy pulls -z).
    !! seed(6*nn)           : initial [r,m] per node (nn = ne + 1); the static equilibrium seed.
    !! fixed_dofs(:)        : global DOF indices held fixed (v = a = 0 there).
    !! seabed_z, kn         : penalty seabed plane and stiffness (kn >= 0).
    !! rho_inf              : gen-alpha spectral radius in [0,1] (0.8 = light high-freq damping).
    TYPE(CD_HermiteCableDynType), INTENT(OUT) :: model
    REAL(wp), INTENT(IN) :: l0(:), EA(:), EI(:), rho_a(:), w(:), seed(:)
    INTEGER, INTENT(IN) :: fixed_dofs(:)
    REAL(wp), INTENT(IN) :: seabed_z, kn, rho_inf
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    INTEGER, INTENT(IN), OPTIONAL :: axial_quadrature_order, bending_quadrature_order

    INTEGER :: ne, nn, ndof, i, e, es, nf, gi
    REAL(wp) :: Me(12, 12), rho
    CHARACTER(1024) :: em2

    ErrStat = CD_HCDYN_OK
    ErrMsg = ''
    model%initialized = .FALSE.
    model%axial_quadrature_order = 4
    model%bending_quadrature_order = 4
    IF (PRESENT(axial_quadrature_order)) model%axial_quadrature_order = axial_quadrature_order
    IF (PRESENT(bending_quadrature_order)) model%bending_quadrature_order = bending_quadrature_order

    ne = SIZE(l0)
    nn = ne + 1
    ndof = 6*nn
    IF (ne < 1 .OR. SIZE(EA) /= ne .OR. SIZE(EI) /= ne .OR. SIZE(rho_a) /= ne .OR. SIZE(w) /= ne) THEN
      CALL fail('l0/EA/EI/rho_a/w must be same length ne >= 1'); RETURN
    END IF
    IF (SIZE(seed) /= ndof) THEN
      CALL fail('seed must be 6*(ne+1)'); RETURN
    END IF
    IF (.NOT. CD_Is_Finite(rho_inf) .OR. rho_inf < CD_ZERO .OR. rho_inf > CD_ONE) THEN
      CALL fail('rho_inf must be finite in [0,1]'); RETURN
    END IF
    IF (model%axial_quadrature_order < 1 .OR. model%axial_quadrature_order > 6 .OR. &
        model%bending_quadrature_order < 1 .OR. model%bending_quadrature_order > 6) THEN
      CALL fail('quadrature orders must lie in [1,6]'); RETURN
    END IF
    IF (kn < CD_ZERO .OR. .NOT. CD_Is_Finite(kn) .OR. .NOT. CD_Is_Finite(seabed_z)) THEN
      CALL fail('kn>=0 and finite seabed_z required'); RETURN
    END IF
    IF (.NOT. CD_All_Finite(seed) .OR. .NOT. CD_All_Finite(l0) .OR. &
        .NOT. CD_All_Finite(EA) .OR. .NOT. CD_All_Finite(EI) .OR. &
        .NOT. CD_All_Finite(rho_a) .OR. .NOT. CD_All_Finite(w)) THEN
      CALL fail('inputs must be finite'); RETURN
    END IF
    IF (ANY(l0 <= CD_ZERO) .OR. ANY(EA < CD_ZERO) .OR. ANY(EI < CD_ZERO) .OR. ANY(rho_a < CD_ZERO)) THEN
      CALL fail('l0>0, EA>=0, EI>=0, rho_a>=0 required'); RETURN
    END IF
    ! A dynamic model needs mass: an all-massless line gives a singular consistent mass, so the
    ! initial-acceleration solve M a0 = f_ext - f_int has no solution. Reject it with a clear message
    ! rather than letting the linear solve fail cryptically (partial masslessness that still leaves
    ! every free node with mass is allowed and is caught by the solve if it does turn singular).
    IF (ALL(rho_a <= CD_ZERO)) THEN
      CALL fail('a dynamic model needs positive mass (all rho_a = 0)'); RETURN
    END IF
    IF (ANY(fixed_dofs < 1) .OR. ANY(fixed_dofs > ndof)) THEN
      CALL fail('fixed_dofs out of range'); RETURN
    END IF

    model%ne = ne; model%nn = nn; model%ndof = ndof
    model%seabed_z = seabed_z; model%kn = kn
    ALLOCATE (model%l0(ne), model%EA(ne), model%EI(ne), model%EI_line(ne), model%rho_a(ne), model%w(ne))
    model%l0 = l0; model%EA = EA; model%EI = EI; model%rho_a = rho_a; model%w = w
    model%EI_line = EI
    model%ei_resolve = MAXVAL(ABS(w)*l0*l0)/12.0_wp

    ! gen-alpha constants
    rho = rho_inf
    model%alpha_m = (2.0_wp*rho - CD_ONE)/(rho + CD_ONE)
    model%alpha_f = rho/(rho + CD_ONE)
    model%beta = 0.25_wp*(CD_ONE - model%alpha_m + model%alpha_f)**2
    model%gamma = 0.5_wp - model%alpha_m + model%alpha_f

    ! nodal tributary lengths (weight + seabed penalty)
    ALLOCATE (model%trib(nn))
    model%trib = CD_ZERO
    DO e = 1, ne
      model%trib(e) = model%trib(e) + 0.5_wp*l0(e)
      model%trib(e + 1) = model%trib(e + 1) + 0.5_wp*l0(e)
    END DO

    ! free/fixed partition
    ALLOCATE (model%freemask(ndof), model%solve_mask(ndof))
    model%freemask = .TRUE.
    DO i = 1, SIZE(fixed_dofs)
      model%freemask(fixed_dofs(i)) = .FALSE.
    END DO
    model%solve_mask = model%freemask
    nf = COUNT(model%freemask)
    ALLOCATE (model%fmap(nf))
    gi = 0
    DO i = 1, ndof
      IF (model%freemask(i)) THEN
        gi = gi + 1; model%fmap(gi) = i
      END IF
    END DO

    ! constant consistent mass, assembled once into band storage
    ALLOCATE (model%Mgb(LDAB_D, ndof))
    model%Mgb = CD_ZERO
    DO e = 1, ne
      CALL CD_HermiteCable_Mass(rho_a(e), l0(e), Me, es, em2)
      IF (es /= CD_HCABLE_OK) THEN
        CALL fail('mass assembly: '//TRIM(em2)); RETURN
      END IF
      CALL scatter12_band(model%Mgb, Me, e)
    END DO

    ! step workspace, allocated once (a dynamic step performs zero heap allocations)
    ALLOCATE (model%ws_qn(ndof), model%ws_vn(ndof), model%ws_an(ndof), model%ws_qk(ndof), &
              model%ws_ak(ndof), model%ws_qa(ndof), model%ws_aa(ndof), model%ws_va(ndof), &
              model%ws_vk(ndof), model%ws_R(ndof), model%ws_G(ndof), model%ws_Gt(ndof), &
              model%ws_inert(ndof), model%ws_qtrial(ndof), model%ws_dq(ndof), &
              model%ws_recovery_q0(ndof), model%ws_recovery_v0(ndof), model%ws_recovery_a0(ndof))
    ALLOCATE (model%ws_Rk(ndof), model%ws_Rt(ndof), model%fc_R(ndof), model%fc_q(ndof), model%fc_v(ndof))
    model%fc_valid = .FALSE.
    model%fc_clears = model%fc_clears + 1
    model%tr_valid = .FALSE.
    model%force_blend = CD_HC_FORCE_BLEND_DEFAULT
    model%max_step_rotation = CD_ZERO
    ALLOCATE (model%ws_Kb(LDAB_D, ndof), model%ws_Kvb(LDAB_D, ndof), &
              model%ws_Keffb(LDAB_D, ndof), model%ws_Msumb(LDAB_D, ndof), &
              model%ws_Mamb(LDAB_D, ndof))
    ! zero fill-in rows (BAND_TOP_D), which the band sweeps then leave untouched
    model%ws_Kb = CD_ZERO; model%ws_Kvb = CD_ZERO; model%ws_Keffb = CD_ZERO
    model%ws_Msumb = CD_ZERO; model%ws_Mamb = CD_ZERO
    ALLOCATE (model%ws_ipiv(ndof))
    ALLOCATE (model%ws_elem_f(12, 6, ne), model%ws_elem_K(12, 12, ne), model%ws_elem_Kdrag(12, 12, ne), &
              model%ws_elem_Kv(12, 12, ne), model%ws_elem_Kwave(12, 12, ne), model%ws_elem_Kheld(12, 12, ne), &
              model%ws_elem_es(ne), model%ws_elem_em(ne), model%ws_stash_q(ndof), model%ws_stash_v(ndof))
    model%ws_stash_ok = .FALSE.
    model%ws_stash_solves = 1
    model%ws_stash_ls = 0

    ! state: at-rest seed, v = 0, consistent a0
    ALLOCATE (model%q(ndof), model%v(ndof), model%a(ndof))
    ALLOCATE (model%rc_q(12, ne), model%rc_v(12, ne), model%rc_a(12, ne), model%rc_g(12, ne), model%rc_have(ne), &
              model%rc_qnb(6, ne))
    model%rc_have = .FALSE.
    model%rc_key_ok = .FALSE.
    model%q = seed
    model%v = CD_ZERO
    model%a = CD_ZERO

    ! Consistent initial acceleration M a0 = f_ext - f_int at the seed state (v = 0). Shared with
    ! Set_Drag so a0 is refreshed when drag is added (e.g. a current gives a non-zero rest drag).
    CALL solve_consistent_acceleration(model, es, em2)
    IF (es /= CD_HCDYN_OK) THEN
      CALL fail(TRIM(em2)); RETURN
    END IF

    model%initialized = .TRUE.

  CONTAINS
    SUBROUTINE fail(msg)
      CHARACTER(*), INTENT(IN) :: msg
      ErrStat = CD_HCDYN_BADINPUT
      ErrMsg = 'CD_HermiteCable_Dyn_Init: '//msg
    END SUBROUTINE fail
  END SUBROUTINE CD_HermiteCable_Dyn_Init

  SUBROUTINE CD_HermiteCable_Dyn_Set_Contact(model, kn_node, cn_node, mu, ErrStat, ErrMsg, &
                                             bathymetry, frame_cs)
    !! Install the standalone deck's nodal seabed law on an initialized Hermite model.
    !! The force/Jacobian convention is that of the deck's nodal seabed law:
    !! C1 normal penalty, compression-only dashpot, and (mu > 0) stick-slip friction springs
    !! anchored at the present node positions (CD_Seabed_Friction_Stick_Slip).
    !! A structured bathymetry is queried in global coordinates; frame_cs maps the
    !! chord-local Hermite solve frame back to global x/y before each query.
    TYPE(CD_HermiteCableDynType), INTENT(INOUT) :: model
    REAL(wp), INTENT(IN) :: kn_node(:), cn_node(:), mu
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    TYPE(CD_BathymetryType), INTENT(IN), OPTIONAL :: bathymetry
    REAL(wp), INTENT(IN), OPTIONAL :: frame_cs(2)

    INTEGER :: es, istat, i_fr
    LOGICAL :: old_fr_active, old_fr_aniso
    REAL(wp), ALLOCATABLE :: old_fr_anchor(:, :), old_fr_k(:), old_fr_recovery(:, :), old_fr_snap(:, :)
    REAL(wp) :: cs(2), old_mu, old_fc, old_fs, old_mu_axial
    REAL(wp), ALLOCATABLE :: new_kn(:), new_cn(:), old_kn(:), old_cn(:), old_a(:)
    LOGICAL :: old_has_contact, old_has_bathymetry
    TYPE(CD_BathymetryType) :: new_bathymetry, old_bathymetry
    CHARACTER(1024) :: em

    ErrStat = CD_HCDYN_OK; ErrMsg = ''
    model%rc_epoch = model%rc_epoch + 1
    ! A load-configuration change invalidates the cached committed force F_n.
    model%fc_valid = .FALSE.
    model%fc_clears = model%fc_clears + 1
    model%tr_valid = .FALSE.
    IF (.NOT. model%initialized) THEN
      CALL fail_contact('model not initialized'); RETURN
    END IF
    IF (SIZE(kn_node) /= model%nn .OR. SIZE(cn_node) /= model%nn) THEN
      CALL fail_contact('kn_node/cn_node must have length n_nodes'); RETURN
    END IF
    IF (.NOT. CD_All_Finite(kn_node) .OR. ANY(kn_node <= CD_ZERO) .OR. &
        .NOT. CD_All_Finite(cn_node) .OR. ANY(cn_node < CD_ZERO) .OR. &
        .NOT. CD_Is_Finite(mu) .OR. mu < CD_ZERO) THEN
      CALL fail_contact('need finite kn_node > 0, cn_node >= 0, and mu >= 0'); RETURN
    END IF
    cs = [CD_ONE, CD_ZERO]
    IF (PRESENT(frame_cs)) THEN
      IF (.NOT. CD_All_Finite(frame_cs) .OR. &
          ABS(SUM(frame_cs*frame_cs) - CD_ONE) > 1.0e-9_wp) THEN
        CALL fail_contact('frame_cs must be a finite unit heading'); RETURN
      END IF
      cs = frame_cs
    END IF
    IF (PRESENT(bathymetry)) THEN
      IF (.NOT. CD_Bathymetry_Is_Initialized(bathymetry)) THEN
        CALL fail_contact('bathymetry is not initialized'); RETURN
      END IF
      new_bathymetry = bathymetry
    END IF
    ALLOCATE (new_kn(model%nn), new_cn(model%nn), old_a(model%ndof), STAT=istat)
    IF (istat /= 0) THEN
      CALL fail_contact('workspace allocation failed'); RETURN
    END IF
    new_kn = kn_node
    new_cn = cn_node

    ! Preserve the complete committed contact configuration until the acceleration
    ! refresh succeeds. Setters are allowed after initialization, so a failed
    ! replacement must not disable or partially overwrite a previously valid bed.
    old_has_contact = model%has_contact
    old_has_bathymetry = model%has_contact_bathymetry
    old_mu = model%contact_mu; old_fc = model%contact_frame_c; old_fs = model%contact_frame_s
    old_bathymetry = model%contact_bathymetry
    old_a = model%a
    CALL MOVE_ALLOC(model%contact_kn, old_kn)
    CALL MOVE_ALLOC(model%contact_cn, old_cn)
    CALL MOVE_ALLOC(new_kn, model%contact_kn)
    CALL MOVE_ALLOC(new_cn, model%contact_cn)
    model%contact_bathymetry = new_bathymetry
    model%has_contact_bathymetry = PRESENT(bathymetry)
    model%contact_mu = mu
    model%contact_frame_c = cs(1)
    model%contact_frame_s = cs(2)
    model%has_contact = .TRUE.
    ! Seabed friction (mu > 0): stick-slip springs anchored at the present node positions,
    ! i.e. carrying no force (CD_HermiteCable_Dyn_Set_Friction_Anchors installs the force
    ! of a static solve with friction). Workspace is allocated once per model.
    old_fr_active = model%fr_active
    old_fr_aniso = model%contact_fr_aniso
    old_mu_axial = model%contact_mu_axial
    IF (ALLOCATED(model%fr_anchor)) THEN
      old_fr_anchor = model%fr_anchor
      old_fr_k = model%fr_k
      old_fr_recovery = model%ws_recovery_fr
      old_fr_snap = model%snap_fr_anchor
    END IF
    ! A new coefficient resets the friction to isotropic; CD_HermiteCable_Dyn_Set_Friction_Axial
    ! (called after this setter) makes it anisotropic against the new lateral coefficient.
    model%contact_fr_aniso = .FALSE.
    model%contact_mu_axial = mu
    model%fr_active = mu > CD_ZERO
    IF (model%fr_active) THEN
      IF (.NOT. ALLOCATED(model%fr_anchor)) THEN
        ALLOCATE (model%fr_anchor(2, model%nn), model%fr_k(model%nn), model%ws_recovery_fr(2, model%nn), &
                  model%snap_fr_anchor(2, model%nn))
        model%snap_fr_anchor = CD_ZERO
      END IF
      model%fr_k = model%contact_kn
      DO i_fr = 1, model%nn
        model%fr_anchor(:, i_fr) = model%q(6*i_fr - 5:6*i_fr - 4)
      END DO
      model%ws_recovery_fr = model%fr_anchor
      ! The new anchors are the committed ones: a later Restore must not bring back
      ! the anchors of the replaced configuration.
      model%snap_fr_anchor = model%fr_anchor
    END IF
    ! The contact set is part of f_ext at t=0; refresh a0 so the first predictor
    ! starts from the same residual subsequently evaluated inside every Newton step.
    CALL solve_consistent_acceleration(model, es, em)
    IF (es /= CD_HCDYN_OK) THEN
      IF (ALLOCATED(model%contact_kn)) DEALLOCATE (model%contact_kn)
      IF (ALLOCATED(model%contact_cn)) DEALLOCATE (model%contact_cn)
      CALL MOVE_ALLOC(old_kn, model%contact_kn)
      CALL MOVE_ALLOC(old_cn, model%contact_cn)
      model%contact_bathymetry = old_bathymetry
      model%has_contact = old_has_contact
      model%has_contact_bathymetry = old_has_bathymetry
      model%contact_mu = old_mu; model%contact_frame_c = old_fc; model%contact_frame_s = old_fs
      model%fr_active = old_fr_active
      model%contact_fr_aniso = old_fr_aniso
      model%contact_mu_axial = old_mu_axial
      IF (ALLOCATED(old_fr_anchor)) THEN
        model%fr_anchor = old_fr_anchor
        model%fr_k = old_fr_k
        model%ws_recovery_fr = old_fr_recovery
        model%snap_fr_anchor = old_fr_snap
      END IF
      model%a = old_a
      CALL fail_contact('initial acceleration refresh failed: '//TRIM(em)); RETURN
    END IF
    ! New nodal coefficients supersede any seabed recompute inputs given for the old ones.
    model%has_seabed_recompute = .FALSE.

  CONTAINS
    SUBROUTINE fail_contact(msg)
      CHARACTER(*), INTENT(IN) :: msg
      ErrStat = CD_HCDYN_BADINPUT
      ErrMsg = 'CD_HermiteCable_Dyn_Set_Contact: '//msg
    END SUBROUTINE fail_contact
  END SUBROUTINE CD_HermiteCable_Dyn_Set_Contact

  SUBROUTINE CD_HermiteCable_Dyn_Set_Friction_Axial(model, mu_axial, ErrStat, ErrMsg)
    !! Make the stick-slip seabed friction anisotropic: contact_mu becomes the lateral
    !! coefficient and mu_axial the coefficient along the horizontal projection of the
    !! nodal tangent (CD_Seabed_Friction_Aniso). Call after CD_HermiteCable_Dyn_Set_Contact;
    !! mu_axial equal to contact_mu keeps the isotropic law bit-for-bit.
    TYPE(CD_HermiteCableDynType), INTENT(INOUT) :: model
    REAL(wp), INTENT(IN) :: mu_axial
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    ErrStat = CD_HCDYN_OK
    ErrMsg = ''
    IF (.NOT. (CD_Is_Finite(mu_axial) .AND. mu_axial > CD_ZERO)) THEN
      ErrStat = CD_HCDYN_BADINPUT
      ErrMsg = 'CD_HermiteCable_Dyn_Set_Friction_Axial: the axial coefficient must be finite and positive'
      RETURN
    END IF
    IF (.NOT. model%initialized) THEN
      ErrStat = CD_HCDYN_BADINPUT
      ErrMsg = 'CD_HermiteCable_Dyn_Set_Friction_Axial: model not initialised'
      RETURN
    END IF
    IF (.NOT. model%fr_active) THEN
      ErrStat = CD_HCDYN_BADINPUT
      ErrMsg = 'CD_HermiteCable_Dyn_Set_Friction_Axial: seabed contact with friction is required'
      RETURN
    END IF
    model%contact_mu_axial = mu_axial
    model%contact_fr_aniso = ABS(mu_axial - model%contact_mu) > CD_ZERO
    ! A friction-law change invalidates the cached committed force F_n and the carried factor.
    model%fc_valid = .FALSE.
    model%fc_clears = model%fc_clears + 1
    model%tr_valid = .FALSE.
  END SUBROUTINE CD_HermiteCable_Dyn_Set_Friction_Axial

  SUBROUTINE CD_HermiteCable_Dyn_Set_VIV(model, cl, cf, df, t_window, ErrStat, ErrMsg, phase_seed, tangent_reversed)
    !! Install the cross-flow VIV synchronisation model (CableDyn_VIV) on a cable with drag:
    !! per element the lift coefficient cl (0: no lift) and the band df/cf, and the running-RMS
    !! averaging time t_window (s; 0 takes 500 steps of the first step). The lift acts on the
    !! wetted Gauss points of every element with cl > 0, its phase lives on the nodes of those
    !! elements; MoorDyn starts node i counted from End A (the model's last node) at 2 pi i/N
    !! with its tangent from End A to End B, and the material tangent here runs from End B to
    !! End A, which turns the lift and the cross-flow axis around: the phases start at 2 pi i/N
    !! plus pi, the same motion. phase_seed, per node, gives the start as a fraction of a turn
    !! instead (CD_Deck_VIV_Phase_Seed: a line whose deck End A the reader turned around, a mesh
    !! refined from the deck's). The phase follows the drag's
    !! current and a held host field (which
    !! carries any waves); the internal wave families (Set_Waves) are refused with VIV. The
    !! committed acceleration is refreshed with the new lift; if that fails, the previous VIV
    !! configuration, its state and the acceleration are restored.
    TYPE(CD_HermiteCableDynType), INTENT(INOUT) :: model
    REAL(wp), INTENT(IN) :: cl(:), cf(:), df(:), t_window
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    REAL(wp), INTENT(IN), OPTIONAL :: phase_seed(:)
    !! tangent_reversed (default .TRUE., the model's own seed): the material tangent runs against
    !! MoorDyn's node tangent, so a node at rest takes the cross-flow phase pi
    !! (CD_VIV_Phase_Rate phi_rest); .FALSE. on a line the reader turned around
    LOGICAL, INTENT(IN), OPTIONAL :: tangent_reversed
    INTEGER :: e, k, ne, nn, es
    REAL(wp) :: wsum, tw_old, rest_old
    LOGICAL :: had_viv
    CHARACTER(LEN=1024) :: em
    REAL(wp), ALLOCATABLE :: a_old(:), o_cl(:), o_k(:), o_cf(:), o_df(:), o_dn(:), o_phi(:), o_phi_eval(:), &
                             o_rate(:), o_ms(:, :), o_ms_next(:, :), o_rec_phi(:), o_rec_ms(:, :), &
                             o_snap_phi(:), o_snap_ms(:, :)
    LOGICAL, ALLOCATABLE :: o_node(:)

    ErrStat = CD_HCDYN_OK; ErrMsg = ''
    IF (.NOT. model%initialized) THEN
      ErrStat = CD_HCDYN_BADINPUT; ErrMsg = 'CD_HermiteCable_Dyn_Set_VIV: model not initialised'; RETURN
    END IF
    ne = model%ne
    nn = model%nn
    IF (SIZE(cl) /= ne .OR. SIZE(cf) /= ne .OR. SIZE(df) /= ne) THEN
      ErrStat = CD_HCDYN_BADINPUT
      ErrMsg = 'CD_HermiteCable_Dyn_Set_VIV: cl, cf and df must each have one value per element'; RETURN
    END IF
    IF (.NOT. (CD_All_Finite(cl) .AND. CD_All_Finite(cf) .AND. CD_All_Finite(df) .AND. &
               CD_Is_Finite(t_window))) THEN
      ErrStat = CD_HCDYN_BADINPUT; ErrMsg = 'CD_HermiteCable_Dyn_Set_VIV: inputs must be finite'; RETURN
    END IF
    IF (ANY(cl < CD_ZERO) .OR. t_window < CD_ZERO .OR. &
        ANY(cl > CD_ZERO .AND. .NOT. (cf > CD_ZERO .AND. df >= CD_ZERO .AND. df < cf))) THEN
      ErrStat = CD_HCDYN_BADINPUT
      ErrMsg = 'CD_HermiteCable_Dyn_Set_VIV: need cl >= 0, t_window >= 0 and 0 <= df < cf where cl > 0'
      RETURN
    END IF
    IF (.NOT. model%has_drag) THEN
      ErrStat = CD_HCDYN_BADINPUT
      ErrMsg = 'CD_HermiteCable_Dyn_Set_VIV: VIV needs the cable''s drag in water (set the drag first)'; RETURN
    END IF
    IF (PRESENT(phase_seed)) THEN
      IF (SIZE(phase_seed) /= nn .OR. .NOT. CD_All_Finite(phase_seed)) THEN
        ErrStat = CD_HCDYN_BADINPUT
        ErrMsg = 'CD_HermiteCable_Dyn_Set_VIV: the phase seed must be finite with one value per node'; RETURN
      END IF
    END IF
    IF (model%has_wave) THEN
      ErrStat = CD_HCDYN_BADINPUT
      ErrMsg = 'CD_HermiteCable_Dyn_Set_VIV: internal waves are configured; VIV takes waves as a held '// &
               'host fluid field (CD_HermiteCable_Dyn_Set_Held_Fluid)'; RETURN
    END IF
    ! the previous configuration and state, kept for a rollback
    had_viv = model%has_viv
    tw_old = model%viv_tw
    rest_old = model%viv_phi_rest
    a_old = model%a
    CALL move_viv(.FALSE.)
    CALL clear_viv(model)
    model%rc_epoch = model%rc_epoch + 1
    model%fc_valid = .FALSE.
    model%fc_clears = model%fc_clears + 1
    model%tr_valid = .FALSE.
    IF (.NOT. ANY(cl > CD_ZERO)) THEN
      IF (had_viv) CALL refresh_acceleration()
      RETURN
    END IF
    ALLOCATE (model%viv_cl(ne), model%viv_k(ne), model%viv_cf(nn), model%viv_df(nn), model%viv_dn(nn), &
              model%viv_phi(nn), &
              model%viv_phi_eval(nn), model%viv_rate(nn), model%viv_ms(2, nn), model%viv_ms_next(2, nn), &
              model%ws_recovery_viv_phi(nn), model%ws_recovery_viv_ms(2, nn), model%snap_viv_phi(nn), &
              model%snap_viv_ms(2, nn), model%viv_node(nn))
    model%viv_cl = cl
    model%viv_cf = CD_ZERO
    model%viv_df = CD_ZERO
    model%viv_node = .FALSE.
    model%viv_phi = CD_ZERO
    model%viv_ms = CD_ZERO
    ! node values: the length-weighted average over the node's lifting elements
    DO k = 1, nn
      wsum = CD_ZERO
      DO e = MAX(1, k - 1), MIN(ne, k)
        IF (.NOT. (cl(e) > CD_ZERO)) CYCLE
        wsum = wsum + model%l0(e)
        model%viv_cf(k) = model%viv_cf(k) + model%l0(e)*cf(e)
        model%viv_df(k) = model%viv_df(k) + model%l0(e)*df(e)
      END DO
      IF (.NOT. (wsum > CD_ZERO)) CYCLE
      model%viv_node(k) = .TRUE.
      model%viv_cf(k) = model%viv_cf(k)/wsum
      model%viv_df(k) = model%viv_df(k)/wsum
      model%viv_phi(k) = CD_VIV_Wrap_Phase(CD_VIV_TWO_PI*(REAL(nn - k, wp)/REAL(ne, wp) + 0.5_wp))
      IF (PRESENT(phase_seed)) model%viv_phi(k) = CD_VIV_TWO_PI*phase_seed(k)
    END DO
    CALL viv_drag_terms(model)
    model%viv_phi_eval = model%viv_phi
    model%viv_rate = CD_ZERO
    model%viv_ms_next = model%viv_ms
    model%ws_recovery_viv_phi = model%viv_phi
    model%ws_recovery_viv_ms = model%viv_ms
    model%snap_viv_phi = model%viv_phi
    model%snap_viv_ms = model%viv_ms
    model%viv_tw = t_window
    model%viv_phi_rest = 0.5_wp*CD_VIV_TWO_PI
    IF (PRESENT(tangent_reversed)) model%viv_phi_rest = MERGE(0.5_wp*CD_VIV_TWO_PI, CD_ZERO, tangent_reversed)
    model%has_viv = .TRUE.
    ! the lift is part of the committed load: the first step's predictor and phase rate need it
    CALL refresh_acceleration()

  CONTAINS
    SUBROUTINE refresh_acceleration()
      CALL solve_consistent_acceleration(model, es, em)
      IF (es == CD_HCDYN_OK) RETURN
      CALL clear_viv(model)
      CALL move_viv(.TRUE.)
      model%has_viv = had_viv
      model%viv_tw = tw_old
      model%viv_phi_rest = rest_old
      model%a = a_old
      ErrStat = es
      ErrMsg = 'CD_HermiteCable_Dyn_Set_VIV: acceleration refresh failed: '//TRIM(em)
    END SUBROUTINE refresh_acceleration

    SUBROUTINE move_viv(back)
      !! Move the VIV arrays from the model into the o_ copies (back = .FALSE.) or back.
      LOGICAL, INTENT(IN) :: back
      IF (back) THEN
        CALL MOVE_ALLOC(o_cl, model%viv_cl); CALL MOVE_ALLOC(o_k, model%viv_k)
        CALL MOVE_ALLOC(o_cf, model%viv_cf); CALL MOVE_ALLOC(o_df, model%viv_df)
        CALL MOVE_ALLOC(o_dn, model%viv_dn); CALL MOVE_ALLOC(o_phi, model%viv_phi)
        CALL MOVE_ALLOC(o_phi_eval, model%viv_phi_eval); CALL MOVE_ALLOC(o_rate, model%viv_rate)
        CALL MOVE_ALLOC(o_ms, model%viv_ms); CALL MOVE_ALLOC(o_ms_next, model%viv_ms_next)
        CALL MOVE_ALLOC(o_rec_phi, model%ws_recovery_viv_phi); CALL MOVE_ALLOC(o_rec_ms, model%ws_recovery_viv_ms)
        CALL MOVE_ALLOC(o_snap_phi, model%snap_viv_phi); CALL MOVE_ALLOC(o_snap_ms, model%snap_viv_ms)
        CALL MOVE_ALLOC(o_node, model%viv_node)
      ELSE
        CALL MOVE_ALLOC(model%viv_cl, o_cl); CALL MOVE_ALLOC(model%viv_k, o_k)
        CALL MOVE_ALLOC(model%viv_cf, o_cf); CALL MOVE_ALLOC(model%viv_df, o_df)
        CALL MOVE_ALLOC(model%viv_dn, o_dn); CALL MOVE_ALLOC(model%viv_phi, o_phi)
        CALL MOVE_ALLOC(model%viv_phi_eval, o_phi_eval); CALL MOVE_ALLOC(model%viv_rate, o_rate)
        CALL MOVE_ALLOC(model%viv_ms, o_ms); CALL MOVE_ALLOC(model%viv_ms_next, o_ms_next)
        CALL MOVE_ALLOC(model%ws_recovery_viv_phi, o_rec_phi); CALL MOVE_ALLOC(model%ws_recovery_viv_ms, o_rec_ms)
        CALL MOVE_ALLOC(model%snap_viv_phi, o_snap_phi); CALL MOVE_ALLOC(model%snap_viv_ms, o_snap_ms)
        CALL MOVE_ALLOC(model%viv_node, o_node)
      END IF
    END SUBROUTINE move_viv
  END SUBROUTINE CD_HermiteCable_Dyn_Set_VIV

  SUBROUTINE clear_viv(model)
    !! Release the VIV storage; the model then carries no lift.
    TYPE(CD_HermiteCableDynType), INTENT(INOUT) :: model
    IF (ALLOCATED(model%viv_k)) DEALLOCATE (model%viv_cl, model%viv_k)
    IF (ALLOCATED(model%viv_cf)) DEALLOCATE (model%viv_cf, model%viv_df, model%viv_dn, model%viv_phi, &
                                             model%viv_phi_eval, model%viv_rate, model%viv_ms, &
                                             model%viv_ms_next, model%ws_recovery_viv_phi, &
                                             model%ws_recovery_viv_ms, model%snap_viv_phi, model%snap_viv_ms, &
                                             model%viv_node)
    model%has_viv = .FALSE.
    model%viv_tw = CD_ZERO
  END SUBROUTINE clear_viv

  SUBROUTINE viv_drag_terms(model)
    !! The VIV quantities taken from the drag configuration, set with VIV and again whenever the
    !! drag is reconfigured: the lift scale viv_k = 1/2 rho D Cl of each element and the node
    !! diameter viv_dn, the length-weighted average over the node's lifting elements.
    TYPE(CD_HermiteCableDynType), INTENT(INOUT) :: model
    INTEGER :: e, k
    REAL(wp) :: wsum
    model%viv_k = 0.5_wp*model%rho_w*model%diam*model%viv_cl
    model%viv_dn = CD_ZERO
    DO k = 1, model%nn
      IF (.NOT. model%viv_node(k)) CYCLE
      wsum = CD_ZERO
      DO e = MAX(1, k - 1), MIN(model%ne, k)
        IF (.NOT. (model%viv_cl(e) > CD_ZERO)) CYCLE
        wsum = wsum + model%l0(e)
        model%viv_dn(k) = model%viv_dn(k) + model%l0(e)*model%diam(e)
      END DO
      model%viv_dn(k) = model%viv_dn(k)/wsum
    END DO
  END SUBROUTINE viv_drag_terms

  SUBROUTINE viv_node_motion(model, k, yd, ydd, un, ok)
    !! Cross-flow velocity and acceleration of node k at the committed state, along its own
    !! tangent (the slope DOFs), in the flow the drag sees there (current plus a held field).
    TYPE(CD_HermiteCableDynType), INTENT(IN) :: model
    INTEGER, INTENT(IN) :: k
    REAL(wp), INTENT(OUT) :: yd, ydd, un
    LOGICAL, INTENT(OUT) :: ok
    REAL(wp) :: uu(3)
    INTEGER :: i0
    i0 = 6*(k - 1)
    uu = model%current
    IF (model%has_held_field) uu = uu + model%hf_u(:, k)
    CALL CD_VIV_Crossflow_Along(model%q(i0 + 4:i0 + 6), model%v(i0 + 1:i0 + 3), model%a(i0 + 1:i0 + 3), uu, &
                                yd, ydd, un, ok)
  END SUBROUTINE viv_node_motion

  SUBROUTINE viv_step_begin(model, dt, ErrStat, ErrMsg)
    !! Step-start VIV quantities from the committed state (q, v, a, phi): the mean squares with
    !! the step-start cross-flow sample (viv_ms_next), the phase rate (viv_rate) and the phase the
    !! step's lift takes (viv_phi_eval): the explicit phase at t_{n+1} under the force blend,
    !! whose in-step force is R(q_{n+1}, v_{n+1}) (F_n keeps phi_n), and at the generalised-alpha
    !! level under the configuration blend.
    TYPE(CD_HermiteCableDynType), INTENT(INOUT) :: model
    REAL(wp), INTENT(IN) :: dt
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    INTEGER :: k
    REAL(wp) :: w, frac, yd, ydd, un
    LOGICAL :: ok
    ErrStat = CD_HCDYN_OK; ErrMsg = ''
    IF (.NOT. (model%viv_tw > CD_ZERO)) model%viv_tw = REAL(CD_VIV_NM, wp)*dt
    w = MIN(CD_ONE, dt/model%viv_tw)
    frac = CD_ONE
    IF (.NOT. model%force_blend) frac = CD_ONE - model%alpha_f
    model%viv_rate = CD_ZERO
    model%viv_ms_next = model%viv_ms
    model%viv_phi_eval = model%viv_phi
    DO k = 1, model%nn
      IF (.NOT. model%viv_node(k)) CYCLE
      CALL viv_node_motion(model, k, yd, ydd, un, ok)
      IF (.NOT. ok) THEN
        ErrStat = CD_HCDYN_NOCONVERGE; ErrMsg = 'VIV phase: degenerate node tangent'; RETURN
      END IF
      model%viv_ms_next(1, k) = CD_VIV_Mean_Square(model%viv_ms(1, k), yd, w)
      model%viv_ms_next(2, k) = CD_VIV_Mean_Square(model%viv_ms(2, k), ydd, w)
      model%viv_rate(k) = CD_VIV_Phase_Rate(yd, ydd, model%viv_ms_next(1, k), model%viv_ms_next(2, k), &
                                            model%viv_phi(k), un, model%viv_dn(k), model%viv_cf(k), &
                                            model%viv_df(k), phi_rest=model%viv_phi_rest)
      model%viv_phi_eval(k) = model%viv_phi(k) + frac*dt*model%viv_rate(k)
    END DO
  END SUBROUTINE viv_step_begin

  SUBROUTINE viv_step_end(model, dt)
    !! Commit the VIV state at the converged end state (q, v, a just committed): the phase by
    !! Heun's rule phi_n + dt/2 (rate_n + rate(state_n+1, phi_n + dt rate_n)), with the end-state
    !! sample added to the mean squares for that rate only, and the step-start mean squares. The
    !! lift then takes the committed phase again. It cannot fail, so the step it ends is never
    !! left half committed: a node whose end tangent is degenerate, or whose end rate is not
    !! finite, takes the step-start rate over the step (phi_n + dt rate_n).
    TYPE(CD_HermiteCableDynType), INTENT(INOUT) :: model
    REAL(wp), INTENT(IN) :: dt
    INTEGER :: k
    REAL(wp) :: w, yd, ydd, un, ms1, ms2, rate_end
    LOGICAL :: ok
    w = MIN(CD_ONE, dt/model%viv_tw)
    DO k = 1, model%nn
      IF (.NOT. model%viv_node(k)) CYCLE
      rate_end = model%viv_rate(k)
      CALL viv_node_motion(model, k, yd, ydd, un, ok)
      IF (ok) THEN
        ms1 = CD_VIV_Mean_Square(model%viv_ms_next(1, k), yd, w)
        ms2 = CD_VIV_Mean_Square(model%viv_ms_next(2, k), ydd, w)
        rate_end = CD_VIV_Phase_Rate(yd, ydd, ms1, ms2, model%viv_phi(k) + dt*model%viv_rate(k), un, &
                                     model%viv_dn(k), model%viv_cf(k), model%viv_df(k), phi_rest=model%viv_phi_rest)
        IF (.NOT. CD_Is_Finite(rate_end)) rate_end = model%viv_rate(k)
      END IF
      model%viv_phi(k) = CD_VIV_Wrap_Phase(model%viv_phi(k) + 0.5_wp*dt*(model%viv_rate(k) + rate_end))
    END DO
    model%viv_ms = model%viv_ms_next
    model%viv_phi_eval = model%viv_phi
  END SUBROUTINE viv_step_end

  SUBROUTINE viv_element_lift(model, q_cfg, v_cfg, e, flift, ErrStat, ErrMsg, djq, djv)
    !! The VIV lift load of element e at the phase viv_phi_eval in the flow the drag sees (current,
    !! held field), with its Jacobians djq, djv (both or neither).
    TYPE(CD_HermiteCableDynType), INTENT(IN) :: model
    REAL(wp), INTENT(IN) :: q_cfg(:), v_cfg(:)
    INTEGER, INTENT(IN) :: e
    REAL(wp), INTENT(OUT) :: flift(12)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    REAL(wp), INTENT(OUT), OPTIONAL :: djq(12, 12), djv(12, 12)
    REAL(wp) :: qe(12), ve(12), uu(3), wl, kn(2)
    flift = CD_ZERO
    IF (PRESENT(djq)) THEN
      djq = CD_ZERO; djv = CD_ZERO
    END IF
    ErrStat = CD_HCDYN_OK; ErrMsg = ''
    IF (.NOT. (model%viv_k(e) > CD_ZERO)) RETURN
    qe(1:6) = q_cfg(6*(e - 1) + 1:6*e); qe(7:12) = q_cfg(6*e + 1:6*(e + 1))
    ve(1:6) = v_cfg(6*(e - 1) + 1:6*e); ve(7:12) = v_cfg(6*e + 1:6*(e + 1))
    uu = model%current
    wl = model%waterline_z
    IF (model%has_held_field) THEN
      uu = uu + 0.5_wp*(model%hf_u(:, e) + model%hf_u(:, e + 1))
      wl = 0.5_wp*(model%hf_wl(e) + model%hf_wl(e + 1))
    END IF
    kn = model%viv_k(e)*[COS(model%viv_phi_eval(e)), COS(model%viv_phi_eval(e + 1))]
    IF (PRESENT(djq)) THEN
      CALL CD_HermiteCable_VIV_Lift_Element(qe, ve, model%l0(e), uu, wl, kn, flift, djq, djv, ErrStat, ErrMsg)
    ELSE
      CALL CD_HermiteCable_VIV_Lift_Element(qe, ve, model%l0(e), uu, wl, kn, flift, ErrStat=ErrStat, &
                                            ErrMsg=ErrMsg)
    END IF
  END SUBROUTINE viv_element_lift

  SUBROUTINE CD_HermiteCable_Dyn_VIV_Node_Lift(model, lift, ErrStat, ErrMsg)
    !! The VIV lift on every node at the committed state [N] (3, nn), in the model frame: the
    !! translational components of the elements' consistent lift loads, summed at the nodes
    !! (MoorDyn's nodal lift on a lumped line). Zero on a cable without VIV.
    TYPE(CD_HermiteCableDynType), INTENT(IN) :: model
    REAL(wp), INTENT(OUT) :: lift(:, :)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    REAL(wp) :: flift(12)
    INTEGER :: e
    lift = CD_ZERO
    ErrStat = CD_HCDYN_OK; ErrMsg = ''
    IF (.NOT. model%initialized) THEN
      ErrStat = CD_HCDYN_BADINPUT; ErrMsg = 'CD_HermiteCable_Dyn_VIV_Node_Lift: model not initialised'; RETURN
    END IF
    IF (SIZE(lift, 1) /= 3 .OR. SIZE(lift, 2) /= model%nn) THEN
      ErrStat = CD_HCDYN_BADINPUT; ErrMsg = 'CD_HermiteCable_Dyn_VIV_Node_Lift: lift must be shaped (3, nn)'; RETURN
    END IF
    IF (.NOT. model%has_viv) RETURN
    DO e = 1, model%ne
      CALL viv_element_lift(model, model%q, model%v, e, flift, ErrStat, ErrMsg)
      IF (ErrStat /= CD_HCDYN_OK) RETURN
      lift(:, e) = lift(:, e) + flift(1:3)
      lift(:, e + 1) = lift(:, e + 1) + flift(7:9)
    END DO
  END SUBROUTINE CD_HermiteCable_Dyn_VIV_Node_Lift

  SUBROUTINE CD_HermiteCable_Dyn_Set_Friction_Anchors(model, anchors, ErrStat, ErrMsg)
    !! Switch the seabed friction of a contact model with mu > 0 to elastic-plastic friction
    !! springs anchored at anchors(1:2, node) (x, y in the solve frame). The spring stiffness
    !! is the nodal normal contact stiffness. A static solve with seabed friction gives each
    !! node its spring force f_s; anchors = x - f_s/k then reproduce f_s at the committed
    !! state, so the march starts in the static equilibrium with every node sticking.
    !! The consistent initial acceleration is refreshed; failure leaves the model unchanged.
    TYPE(CD_HermiteCableDynType), INTENT(INOUT) :: model
    REAL(wp), INTENT(IN) :: anchors(:, :)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    REAL(wp), ALLOCATABLE :: a_old(:), anchor_old(:, :)
    LOGICAL :: active_old
    INTEGER :: es
    CHARACTER(1024) :: em

    ErrStat = CD_HCDYN_OK; ErrMsg = ''
    IF (.NOT. model%initialized) THEN
      CALL fail_fr('model not initialised'); RETURN
    END IF
    IF (.NOT. model%has_contact .OR. .NOT. (model%contact_mu > CD_ZERO)) THEN
      CALL fail_fr('seabed contact with a positive friction coefficient is required'); RETURN
    END IF
    IF (SIZE(anchors, 1) /= 2 .OR. SIZE(anchors, 2) /= model%nn) THEN
      CALL fail_fr('anchors must be (2, n_nodes)'); RETURN
    END IF
    IF (.NOT. CD_All_Finite(anchors)) THEN
      CALL fail_fr('anchors must be finite'); RETURN
    END IF
    IF (.NOT. ALLOCATED(model%fr_anchor)) THEN
      ALLOCATE (model%fr_anchor(2, model%nn), model%fr_k(model%nn), model%ws_recovery_fr(2, model%nn), &
                model%snap_fr_anchor(2, model%nn))
      model%fr_anchor = CD_ZERO
      model%snap_fr_anchor = CD_ZERO
    END IF
    a_old = model%a
    anchor_old = model%fr_anchor
    active_old = model%fr_active
    model%fr_k = model%contact_kn
    model%fr_anchor = anchors
    model%fr_active = .TRUE.
    model%fc_valid = .FALSE.
    model%fc_clears = model%fc_clears + 1
    model%tr_valid = .FALSE.
    CALL solve_consistent_acceleration(model, es, em)
    IF (es /= CD_HCDYN_OK) THEN
      model%a = a_old
      model%fr_anchor = anchor_old
      model%fr_active = active_old
      CALL fail_fr('initial acceleration refresh failed: '//TRIM(em)); RETURN
    END IF
    ! The installed anchors are the committed ones: a later Restore must not bring back
    ! the anchors they replace.
    model%snap_fr_anchor = model%fr_anchor
    model%ws_recovery_fr = model%fr_anchor

  CONTAINS
    SUBROUTINE fail_fr(msg)
      CHARACTER(*), INTENT(IN) :: msg
      ErrStat = CD_HCDYN_BADINPUT
      ErrMsg = 'CD_HermiteCable_Dyn_Set_Friction_Anchors: '//msg
    END SUBROUTINE fail_fr
  END SUBROUTINE CD_HermiteCable_Dyn_Set_Friction_Anchors

  SUBROUTINE CD_HermiteCable_Dyn_Set_Attachments(model, node, mass, volume, cda, cdax, ca, rho_w, gravity, &
                                                 ErrStat, ErrMsg)
    !! Install discrete point attachments (clumps, buoyancy modules) lumped at nodes. Each
    !! carries its weight and buoyancy (m - rho V) g downward, isotropic added mass
    !! Ca rho V (with the dry mass m, a constant nodal mass on the translational DOFs), the
    !! Froude-Krylov plus fluid-inertia force rho V (1 + Ca) du/dt and the quadratic drag
    !! rho [CdA |w_n| w_n + CdAx |w_t| w_t] / 2 of the relative velocity w = u - v split
    !! normal and axial to the line tangent at the node (CD_HermiteCable_Attachment_Drag),
    !! against the held fluid field at the node (still water without one). Above the free
    !! surface an attachment loses its buoyancy and fluid loads. Called once, after Init and
    !! never together with internal waves; the initial acceleration is refreshed. The
    !! kinetic energy (CD_HermiteCable_Dyn_Energy) then includes the attachment mass and its
    !! added mass Ca rho V.
    TYPE(CD_HermiteCableDynType), INTENT(INOUT) :: model
    INTEGER, INTENT(IN) :: node(:)
    REAL(wp), INTENT(IN) :: mass(:), volume(:), cda(:), cdax(:), ca(:), rho_w, gravity
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    INTEGER :: n, k, d, dof, es
    REAL(wp), ALLOCATABLE :: a_old(:), mgb_old(:, :)
    CHARACTER(1024) :: em

    ErrStat = CD_HCDYN_OK; ErrMsg = ''
    n = SIZE(node)
    IF (.NOT. model%initialized) THEN
      ErrStat = CD_HCDYN_BADINPUT; ErrMsg = 'CD_HermiteCable_Dyn_Set_Attachments: model not initialised'; RETURN
    END IF
    IF (model%has_attach) THEN
      ErrStat = CD_HCDYN_BADINPUT; ErrMsg = 'CD_HermiteCable_Dyn_Set_Attachments: attachments are already set'
      RETURN
    END IF
    IF (model%has_wave) THEN
      ErrStat = CD_HCDYN_BADINPUT
      ErrMsg = 'CD_HermiteCable_Dyn_Set_Attachments: attachments take the held fluid field, not internal waves'
      RETURN
    END IF
    IF (n < 1 .OR. SIZE(mass) /= n .OR. SIZE(volume) /= n .OR. SIZE(cda) /= n .OR. SIZE(ca) /= n .OR. &
        SIZE(cdax) /= n) THEN
      ErrStat = CD_HCDYN_BADINPUT
      ErrMsg = 'CD_HermiteCable_Dyn_Set_Attachments: node/mass/volume/cda/ca must share one length >= 1'
      RETURN
    END IF
    IF (ANY(node < 1) .OR. ANY(node > model%nn)) THEN
      ErrStat = CD_HCDYN_BADINPUT; ErrMsg = 'CD_HermiteCable_Dyn_Set_Attachments: node out of range'; RETURN
    END IF
    IF (.NOT. (CD_All_Finite(mass) .AND. CD_All_Finite(volume) .AND. CD_All_Finite(cda) .AND. &
               CD_All_Finite(cdax) .AND. CD_All_Finite(ca) .AND. CD_Is_Finite(rho_w) .AND. CD_Is_Finite(gravity))) THEN
      ErrStat = CD_HCDYN_BADINPUT; ErrMsg = 'CD_HermiteCable_Dyn_Set_Attachments: values must be finite'; RETURN
    END IF
    IF (ANY(mass < CD_ZERO) .OR. ANY(volume < CD_ZERO) .OR. ANY(cda < CD_ZERO) .OR. ANY(ca < CD_ZERO) .OR. &
        ANY(cdax < CD_ZERO) .OR. &
        rho_w <= CD_ZERO .OR. gravity <= CD_ZERO) THEN
      ErrStat = CD_HCDYN_BADINPUT
      ErrMsg = 'CD_HermiteCable_Dyn_Set_Attachments: mass, volume, CdA and Ca must be >= 0; rho_w, g > 0'
      RETURN
    END IF
    model%fc_valid = .FALSE.
    model%fc_clears = model%fc_clears + 1
    model%tr_valid = .FALSE.
    a_old = model%a
    mgb_old = model%Mgb
    ALLOCATE (model%att_node(n), model%att_w(n), model%att_b(n), model%att_fk(n), model%att_cda(n), &
              model%att_cdax(n), model%att_mass(n), model%att_madd(n))
    model%att_node = node
    model%att_w = (mass - rho_w*volume)*gravity
    model%att_b = rho_w*gravity*volume
    model%att_fk = rho_w*volume*(CD_ONE + ca)
    model%att_cda = cda
    model%att_cdax = cdax
    model%att_rho = rho_w
    model%att_mass = mass
    model%att_madd = ca*rho_w*volume
    DO k = 1, n
      DO d = 1, 3
        dof = 6*(node(k) - 1) + d
        model%Mgb(KL_D + KU_D + 1, dof) = model%Mgb(KL_D + KU_D + 1, dof) + model%att_mass(k) + model%att_madd(k)
      END DO
    END DO
    model%has_attach = .TRUE.
    CALL solve_consistent_acceleration(model, es, em)
    IF (es /= CD_HCDYN_OK) THEN
      DEALLOCATE (model%att_node, model%att_w, model%att_b, model%att_fk, model%att_cda, model%att_cdax, &
                  model%att_mass, model%att_madd)
      model%has_attach = .FALSE.
      model%Mgb = mgb_old
      model%a = a_old
      ErrStat = CD_HCDYN_BADINPUT
      ErrMsg = 'CD_HermiteCable_Dyn_Set_Attachments: initial acceleration refresh failed: '//TRIM(em)
    END IF
  END SUBROUTINE CD_HermiteCable_Dyn_Set_Attachments

  SUBROUTINE CD_HermiteCable_Attachment_Drag(rel_velocity, tangent, rho, cda, cdax, force, ErrStat, ErrMsg, &
                                             jac_rel, jac_tan)
    !! Quadratic drag of a line attachment: f = rho [CdA |w_n| w_n + CdAx |w_t| w_t] / 2 with
    !! w the relative fluid velocity split normal and axial to the line tangent (any non-zero
    !! vector; normalised internally). Optional Jacobians d f/d w and d f/d tangent, as a pair.
    !! Shared by the dynamic residual and the deck static solve, so both use one law.
    REAL(wp), INTENT(IN) :: rel_velocity(3), tangent(3), rho, cda, cdax
    REAL(wp), INTENT(OUT) :: force(3)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    REAL(wp), INTENT(OUT), OPTIONAL :: jac_rel(3, 3), jac_tan(3, 3)
    REAL(wp), PARAMETER :: PI_A = 3.14159265358979323846_wp
    ! The Morison per-length primitive with unit diameter is 1/2 rho Cdn |w_n| w_n +
    ! 1/2 rho pi Cdt |w_t| w_t, so Cdn = CdA and Cdt = CdAx/pi.
    IF (PRESENT(jac_rel) .AND. PRESENT(jac_tan)) THEN
      CALL CD_Morison_Drag_Per_Length_Jac(rel_velocity, tangent, rho, CD_ONE, cda, cdax/PI_A, force, &
                                          jac_rel, jac_tan, ErrStat, ErrMsg)
    ELSE
      CALL CD_Morison_Drag_Per_Length_Jac(rel_velocity, tangent, rho, CD_ONE, cda, cdax/PI_A, force, &
                                          ErrStat=ErrStat, ErrMsg=ErrMsg)
    END IF
    IF (ErrStat /= CD_HYDRO_OK) THEN
      ErrStat = CD_HCDYN_BADINPUT; ErrMsg = 'attachment drag: '//TRIM(ErrMsg)
    ELSE
      ErrStat = CD_HCDYN_OK
    END IF
  END SUBROUTINE CD_HermiteCable_Attachment_Drag

  SUBROUTINE assemble_attachments(model, q_cfg, v_cfg, want_residual, want_tangent, R, Kb, Kvb, n_lo, n_hi, &
                                  ErrStat, ErrMsg)
    !! Attachment loads into R = f_int - f_ext, with the velocity tangent dR/dv and the
    !! drag's dependence on the nodal line tangent in dR/dq. The held fluid field is
    !! constant over the step.
    TYPE(CD_HermiteCableDynType), INTENT(IN) :: model
    REAL(wp), INTENT(IN) :: q_cfg(:), v_cfg(:)
    LOGICAL, INTENT(IN) :: want_residual, want_tangent
    REAL(wp), INTENT(INOUT) :: R(:), Kb(:, :), Kvb(:, :)
    INTEGER, INTENT(IN) :: n_lo, n_hi  ! only the attachments at nodes n_lo..n_hi
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    INTEGER :: k, base, a, b
    LOGICAL :: has_jac
    REAL(wp) :: rk(3), jrel(3, 3), jtan(3, 3)
    ErrStat = CD_HCDYN_OK; ErrMsg = ''
    DO k = 1, SIZE(model%att_node)
      IF (model%att_node(k) < n_lo .OR. model%att_node(k) > n_hi) CYCLE
      base = 6*(model%att_node(k) - 1)
      CALL attachment_residual(model, k, q_cfg, v_cfg, want_tangent, rk, has_jac, jrel, jtan, ErrStat, ErrMsg)
      IF (ErrStat /= CD_HCDYN_OK) RETURN
      IF (want_residual) R(base + 1:base + 3) = R(base + 1:base + 3) + rk
      IF (want_tangent .AND. has_jac) THEN
        ! w = u - v, so dR/dv = +df/dw; the tangent DOFs m enter through df/dm
        DO b = 1, 3
          DO a = 1, 3
            Kvb(KL_D + KU_D + 1 + a - b, base + b) = Kvb(KL_D + KU_D + 1 + a - b, base + b) + jrel(a, b)
            Kb(KL_D + KU_D + 1 + a - b - 3, base + b + 3) = Kb(KL_D + KU_D + 1 + a - b - 3, base + b + 3) - &
                                                            jtan(a, b)
          END DO
        END DO
      END IF
    END DO
  END SUBROUTINE assemble_attachments

  SUBROUTINE attachment_residual(model, k, q_cfg, v_cfg, want_jac, rk, has_jac, jrel, jtan, ErrStat, ErrMsg)
    !! Contribution rk of attachment k to R = f_int - f_ext at the translations of its node:
    !! weight, buoyancy, Froude-Krylov force and drag (inertia excluded). With want_jac, the
    !! drag Jacobians d f/d w and d f/d tangent are returned when has_jac is set.
    TYPE(CD_HermiteCableDynType), INTENT(IN) :: model
    INTEGER, INTENT(IN) :: k
    REAL(wp), INTENT(IN) :: q_cfg(:), v_cfg(:)
    LOGICAL, INTENT(IN) :: want_jac
    REAL(wp), INTENT(OUT) :: rk(3), jrel(3, 3), jtan(3, 3)
    LOGICAL, INTENT(OUT) :: has_jac
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    INTEGER :: j, base
    REAL(wp) :: u(3), ud(3), wrel(3), wl, f(3)
    ErrStat = CD_HCDYN_OK; ErrMsg = ''
    rk = CD_ZERO; jrel = CD_ZERO; jtan = CD_ZERO; has_jac = .FALSE.
    j = model%att_node(k)
    base = 6*(j - 1)
    u = CD_ZERO; ud = CD_ZERO; wl = CD_ZERO
    IF (model%has_drag) THEN
      wl = model%waterline_z
      u = model%current
    ELSE IF (model%has_am) THEN
      wl = model%am_wl
    END IF
    IF (model%has_held_field) THEN
      u = u + model%hf_u(:, j); ud = model%hf_ud(:, j); wl = model%hf_wl(j)
    END IF
    IF (q_cfg(base + 3) > wl) THEN
      ! above the free surface: weight only, no buoyancy or fluid load
      rk(3) = model%att_w(k) + model%att_b(k)
      RETURN
    END IF
    rk(3) = model%att_w(k)
    rk = rk - model%att_fk(k)*ud
    IF (.NOT. (model%att_cda(k) > CD_ZERO .OR. model%att_cdax(k) > CD_ZERO)) RETURN
    wrel = u - v_cfg(base + 1:base + 3)
    IF (want_jac) THEN
      CALL CD_HermiteCable_Attachment_Drag(wrel, q_cfg(base + 4:base + 6), model%att_rho, model%att_cda(k), &
                                           model%att_cdax(k), f, ErrStat, ErrMsg, jrel, jtan)
      has_jac = .TRUE.
    ELSE
      CALL CD_HermiteCable_Attachment_Drag(wrel, q_cfg(base + 4:base + 6), model%att_rho, model%att_cda(k), &
                                           model%att_cdax(k), f, ErrStat, ErrMsg)
    END IF
    IF (ErrStat /= CD_HCDYN_OK) RETURN
    rk = rk - f
  END SUBROUTINE attachment_residual

  SUBROUTINE CD_HermiteCable_Dyn_Recompute_Acceleration(model, ErrStat, ErrMsg, pres_dofs, pres_a)
    !! Public lifecycle hook for a non-stepping boundary-state commit. Recompute the
    !! free-DOF acceleration from the complete installed load set at the model's current
    !! q/v/t. Optional prescribed fixed-DOF accelerations enter the consistent-mass RHS,
    !! including their off-diagonal coupling to free DOFs. Failure is atomic with respect
    !! to the previously committed acceleration. Under active line control the acceleration
    !! is the committed state's: between a length change (CD_HermiteCable_Dyn_Set_SegmentLength)
    !! and the next step it is solved with the lengths and rates that state was reached with
    !! (l0_c, l0_dot_c), which stay the committed ones, so the step still blends the old and new
    !! lengths.
    TYPE(CD_HermiteCableDynType), INTENT(INOUT) :: model
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    INTEGER, INTENT(IN), OPTIONAL :: pres_dofs(:)
    REAL(wp), INTENT(IN), OPTIONAL :: pres_a(:)
    REAL(wp), ALLOCATABLE :: a_old(:)

    ErrStat = CD_HCDYN_OK; ErrMsg = ''
    IF (.NOT. model%initialized) THEN
      ErrStat = CD_HCDYN_BADINPUT
      ErrMsg = 'CD_HermiteCable_Dyn_Recompute_Acceleration: model not initialized'; RETURN
    END IF
    a_old = model%a
    IF (PRESENT(pres_dofs) .AND. PRESENT(pres_a)) THEN
      CALL solve_committed_acceleration(model, ErrStat, ErrMsg, pres_dofs=pres_dofs, pres_a=pres_a)
    ELSE IF (PRESENT(pres_dofs) .OR. PRESENT(pres_a)) THEN
      ErrStat = CD_HCDYN_BADINPUT
      ErrMsg = 'CD_HermiteCable_Dyn_Recompute_Acceleration: pres_dofs and pres_a must be supplied together'
      RETURN
    ELSE
      CALL solve_committed_acceleration(model, ErrStat, ErrMsg)
    END IF
    IF (ErrStat /= CD_HCDYN_OK) THEN
      model%a = a_old
      ErrMsg = 'CD_HermiteCable_Dyn_Recompute_Acceleration: '//TRIM(ErrMsg)
    END IF
  END SUBROUTINE CD_HermiteCable_Dyn_Recompute_Acceleration

  SUBROUTINE CD_HermiteCable_Dyn_Set_SegmentLength(model, elems, l0_new, l0_dot, ErrStat, ErrMsg, restored)
    !! Active line control (the OpenFAST cable-control channel): set the unstretched length
    !! and its rate of the listed elements, applied before a step and held over it. Every
    !! term that reads l0 when it is evaluated (elastic force, weight, drag, Froude-Krylov
    !! load, added mass, dry-part buoyancy, the tensile audit and the residual scale) follows
    !! at once. The cached terms are rebuilt from the new lengths in the order initialisation
    !! used, so the model carries what one built with them would: the constant mass Mgb with
    !! the attachment masses, the nodal tributary lengths and, on a contact model, the nodal
    !! seabed coefficients and the friction spring stiffness. The rate enters the axial
    !! damping (CD_HermiteCable_Axial_Damping_Element). The step uses the mass of the new
    !! lengths and leaves out the rate term dM/dt v, as MoorDyn does; the committed
    !! acceleration is kept as the history of the preceding step, and BA keeps its initial
    !! resolution. The committed state keeps the lengths it was reached with (l0_c,
    !! l0_dot_c): the force-blended committed force F_n stays the force at those lengths
    !! (cached or, after a cache loss, evaluated with them), and only the step's new force
    !! R(q_{n+1}) takes the new ones, so a length ramp is not lagged by alpha_f times the
    !! length change. The carried step factor is discarded, and the step after a change starts
    !! from the Newmark predictor (the change is a load step).
    !! A call that changes no length and no rate (bit for bit, a rate of -0 counting as +0)
    !! returns at once, so a zero command of either sign on an uncontrolled model leaves it
    !! untouched. The update is atomic: every check and rebuild runs before the model is
    !! written. On a line restrained in torsion the torsion follows the lengths in the same way:
    !! the terms read at evaluation (the condensed compliance sum l0/GJ, the nodal twist's element
    !! stiffness GJ/l0 and damping Bt/l0, the coupling term (K/GJ)(l - l0)) take l0 there, the
    !! lumped polar inertia Irn l0/2 and a torsional damping given as -zeta (zeta l0 sqrt(GJ Irn))
    !! are rebuilt with the caches, and the committed force keeps its torsion part at l0_c with
    !! the rest. The rate enters the torsional damping as it enters the axial one: the damping
    !! takes the rate of the twist per length (assemble_twist). A contact model without the seabed
    !! recompute inputs is refused, as is a model on the configuration-blended generalised-alpha
    !! (force blend off, CD_HermiteCable_Dyn_Set_ForceBlend), whose blended state has no
    !! committed-length treatment, so a ramp would lag by alpha_f times the length change.
    !! restored = .TRUE. (a checkpoint restart re-applying the command the committed state was
    !! reached with) makes the lengths and rates the committed ones at once; a committed force
    !! reloaded with the state belongs to them and stays valid.
    TYPE(CD_HermiteCableDynType), INTENT(INOUT) :: model
    INTEGER, INTENT(IN) :: elems(:)
    REAL(wp), INTENT(IN) :: l0_new(:), l0_dot(:)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    LOGICAL, INTENT(IN), OPTIONAL :: restored
    INTEGER :: k, n, istat
    LOGICAL :: lengths_changed, rates_changed
    REAL(wp) :: rate_now
    REAL(wp), ALLOCATABLE :: l0_trial(:), rate_new(:)

    ErrStat = CD_HCDYN_OK; ErrMsg = ''
    IF (.NOT. model%initialized) THEN
      CALL fail('model not initialised'); RETURN
    END IF
    n = SIZE(elems)
    IF (n < 1 .OR. SIZE(l0_new) /= n .OR. SIZE(l0_dot) /= n) THEN
      CALL fail('elems, l0_new and l0_dot must share one length >= 1'); RETURN
    END IF
    IF (ANY(elems < 1) .OR. ANY(elems > model%ne)) THEN
      CALL fail('element index out of range'); RETURN
    END IF
    DO k = 2, n
      IF (elems(k) <= elems(k - 1)) THEN
        CALL fail('element indices must be strictly increasing'); RETURN
      END IF
    END DO
    IF (.NOT. (CD_All_Finite(l0_new) .AND. CD_All_Finite(l0_dot))) THEN
      CALL fail('l0 and l0_dot must be finite'); RETURN
    END IF
    IF (ANY(l0_new <= CD_ZERO)) THEN
      CALL fail('l0 must be positive'); RETURN
    END IF
    IF (model%has_contact .AND. .NOT. model%has_seabed_recompute) THEN
      CALL fail('a seabed-contact model needs the seabed recompute inputs '// &
                '(CD_HermiteCable_Dyn_Set_Control_Seabed)'); RETURN
    END IF
    IF (.NOT. model%force_blend) THEN
      CALL fail('the configuration-blended generalised-alpha (force blend off) is not supported: '// &
                'enable the force blend (CD_HermiteCable_Dyn_Set_ForceBlend)'); RETURN
    END IF
    ! a rate of -0 is stored as +0, so a zero command of either sign is inert
    rate_new = positive_zero(l0_dot)
    lengths_changed = .FALSE.
    rates_changed = .FALSE.
    DO k = 1, n
      IF (.NOT. bits_equal(model%l0(elems(k)), l0_new(k))) lengths_changed = .TRUE.
      rate_now = CD_ZERO
      IF (model%has_ctrl) rate_now = model%l0_dot(elems(k))
      IF (.NOT. bits_equal(rate_now, rate_new(k))) rates_changed = .TRUE.
    END DO
    IF (.NOT. (lengths_changed .OR. rates_changed)) THEN
      CALL commit_restored()
      RETURN
    END IF
    IF (.NOT. ALLOCATED(model%l0_dot)) THEN
      ALLOCATE (model%l0_dot(model%ne), model%l0_c(model%ne), model%l0_dot_c(model%ne), &
                model%ws_recovery_l0_c(model%ne), model%ws_recovery_l0_dot_c(model%ne), STAT=istat)
      IF (istat /= 0) THEN
        CALL fail('rate storage allocation failed'); RETURN
      END IF
      model%l0_dot = CD_ZERO
    END IF
    ! the first change: the committed state was reached with the present lengths, at rest
    IF (.NOT. model%has_ctrl) THEN
      model%l0_c = model%l0
      model%l0_dot_c = CD_ZERO
    END IF
    IF (lengths_changed) THEN
      ALLOCATE (l0_trial(model%ne), STAT=istat)
      IF (istat /= 0) THEN
        CALL fail('length storage allocation failed'); RETURN
      END IF
      l0_trial = model%l0
      l0_trial(elems) = l0_new
      CALL rebuild_length_caches(model, l0_trial, ErrStat, ErrMsg)
      IF (ErrStat /= CD_HCDYN_OK) THEN
        ErrMsg = 'CD_HermiteCable_Dyn_Set_SegmentLength: '//TRIM(ErrMsg); RETURN
      END IF
    END IF
    IF (.NOT. model%has_ctrl) model%l0_dot = CD_ZERO
    model%has_ctrl = .TRUE.
    model%l0_dot(elems) = rate_new
    ! the cached committed force stays valid (it is the force at l0_c); the carried factor
    ! holds the tangent of the old lengths
    model%tr_valid = .FALSE.
    CALL commit_restored()

  CONTAINS
    SUBROUTINE fail(msg)
      CHARACTER(*), INTENT(IN) :: msg
      ErrStat = CD_HCDYN_BADINPUT
      ErrMsg = 'CD_HermiteCable_Dyn_Set_SegmentLength: '//msg
    END SUBROUTINE fail

    SUBROUTINE commit_restored()
      !! restored: the present lengths and rates are the committed state's.
      IF (.NOT. PRESENT(restored)) RETURN
      IF (.NOT. (restored .AND. model%has_ctrl)) RETURN
      model%l0_c = model%l0
      model%l0_dot_c = model%l0_dot
    END SUBROUTINE commit_restored
  END SUBROUTINE CD_HermiteCable_Dyn_Set_SegmentLength

  SUBROUTINE CD_HermiteCable_Dyn_Save_Control(model, saved)
    !! Save what CD_HermiteCable_Dyn_Set_SegmentLength writes (the lengths, rates, committed
    !! lengths and rates, the control flag and the carried-factor flag), so that a caller
    !! applying one command to several models can take back the ones it already changed
    !! when a later one fails (CD_HermiteCable_Dyn_Restore_Control).
    TYPE(CD_HermiteCableDynType), INTENT(IN) :: model
    TYPE(CD_HermiteCableControlSaveType), INTENT(INOUT) :: saved
    saved%valid = model%initialized
    IF (.NOT. saved%valid) RETURN
    saved%has_ctrl = model%has_ctrl
    saved%tr_valid = model%tr_valid
    saved%l0 = model%l0
    saved%rates = ALLOCATED(model%l0_dot)
    IF (saved%rates) THEN
      saved%l0_dot = model%l0_dot
      saved%l0_c = model%l0_c
      saved%l0_dot_c = model%l0_dot_c
    END IF
  END SUBROUTINE CD_HermiteCable_Dyn_Save_Control

  SUBROUTINE CD_HermiteCable_Dyn_Restore_Control(model, saved, ErrStat, ErrMsg)
    !! Take the model back to what CD_HermiteCable_Dyn_Save_Control saved. Lengths changed
    !! since get the caches built from the saved lengths, as CD_HermiteCable_Dyn_Restore
    !! rebuilds them: the caches are a function of the lengths (built in the order
    !! initialisation used), so the model is the saved one bit for bit. Fails closed, writing
    !! nothing, when the save does not belong to the model or the rebuild fails.
    TYPE(CD_HermiteCableDynType), INTENT(INOUT) :: model
    TYPE(CD_HermiteCableControlSaveType), INTENT(IN) :: saved
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    REAL(wp), ALLOCATABLE :: l0_back(:)

    ErrStat = CD_HCDYN_OK; ErrMsg = ''
    IF (.NOT. (model%initialized .AND. saved%valid)) THEN
      ErrStat = CD_HCDYN_BADINPUT
      ErrMsg = 'CD_HermiteCable_Dyn_Restore_Control: no saved control state'; RETURN
    END IF
    IF (SIZE(saved%l0) /= model%ne) THEN
      ErrStat = CD_HCDYN_BADINPUT
      ErrMsg = 'CD_HermiteCable_Dyn_Restore_Control: the saved state belongs to another model'; RETURN
    END IF
    IF (.NOT. ALL(bits_equal(model%l0, saved%l0))) THEN
      l0_back = saved%l0
      CALL rebuild_length_caches(model, l0_back, ErrStat, ErrMsg)
      IF (ErrStat /= CD_HCDYN_OK) THEN
        ErrMsg = 'CD_HermiteCable_Dyn_Restore_Control: '//TRIM(ErrMsg); RETURN
      END IF
    END IF
    IF (saved%rates) THEN
      model%l0_dot = saved%l0_dot
      model%l0_c = saved%l0_c
      model%l0_dot_c = saved%l0_dot_c
      IF (.NOT. ALLOCATED(model%ws_recovery_l0_c)) &
        ALLOCATE (model%ws_recovery_l0_c(model%ne), model%ws_recovery_l0_dot_c(model%ne))
    ELSE IF (ALLOCATED(model%l0_dot)) THEN
      DEALLOCATE (model%l0_dot, model%l0_c, model%l0_dot_c, model%ws_recovery_l0_c, model%ws_recovery_l0_dot_c)
    END IF
    model%has_ctrl = saved%has_ctrl
    model%tr_valid = saved%tr_valid
  END SUBROUTINE CD_HermiteCable_Dyn_Restore_Control

  SUBROUTINE CD_HermiteCable_Dyn_Set_Control_Seabed(model, kbot, diameter_elem, cn_over_kn, ErrStat, ErrMsg)
    !! Store the seabed recompute inputs of a contact model for active line control: the
    !! per-area penalty kbot [N/m^3], the per-element contact diameter [m] and the ratio
    !! cn/kn, the inputs from which the deck built the installed nodal coefficients with
    !! CD_Nodal_Seabed_Stiffness. Call after CD_HermiteCable_Dyn_Set_Contact. The inputs
    !! must reproduce the installed contact_kn and contact_cn at the present lengths to within
    !! a few units in the last place, so a length change rebuilds the coefficients a model
    !! built with the new lengths would carry; otherwise the call fails and changes nothing.
    !! (Not bit for bit: an optimising compiler may evaluate the caller's kn*(cBot/kBot) and
    !! the same product here with different rounding, as the Intel release build does.)
    TYPE(CD_HermiteCableDynType), INTENT(INOUT) :: model
    REAL(wp), INTENT(IN) :: kbot, diameter_elem(:), cn_over_kn
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    REAL(wp), ALLOCATABLE :: kn_check(:)
    INTEGER :: es
    CHARACTER(200) :: em

    ErrStat = CD_HCDYN_OK; ErrMsg = ''
    IF (.NOT. model%initialized) THEN
      CALL fail('model not initialised'); RETURN
    END IF
    IF (.NOT. (model%has_contact .AND. ALLOCATED(model%contact_kn) .AND. ALLOCATED(model%contact_cn))) THEN
      CALL fail('seabed contact (CD_HermiteCable_Dyn_Set_Contact) is required'); RETURN
    END IF
    IF (SIZE(diameter_elem) /= model%ne) THEN
      CALL fail('diameter_elem must have one entry per element'); RETURN
    END IF
    IF (.NOT. (CD_Is_Finite(cn_over_kn) .AND. cn_over_kn >= CD_ZERO)) THEN
      CALL fail('cn_over_kn must be finite and non-negative'); RETURN
    END IF
    CALL CD_Nodal_Seabed_Stiffness(kbot, diameter_elem, model%l0, kn_check, es, em)
    IF (es /= CD_LINE_OK) THEN
      CALL fail(TRIM(em)); RETURN
    END IF
    IF (.NOT. ALL(within_ulps(kn_check, model%contact_kn))) THEN
      CALL fail('the inputs do not reproduce the installed nodal contact stiffness'); RETURN
    END IF
    IF (.NOT. ALL(within_ulps(kn_check*cn_over_kn, model%contact_cn))) THEN
      CALL fail('the inputs do not reproduce the installed nodal contact damping'); RETURN
    END IF
    model%seabed_kbot = kbot
    model%seabed_diameter_elem = diameter_elem
    model%seabed_cn_over_kn = cn_over_kn
    model%has_seabed_recompute = .TRUE.

  CONTAINS
    SUBROUTINE fail(msg)
      CHARACTER(*), INTENT(IN) :: msg
      ErrStat = CD_HCDYN_BADINPUT
      ErrMsg = 'CD_HermiteCable_Dyn_Set_Control_Seabed: '//msg
    END SUBROUTINE fail
    ELEMENTAL LOGICAL FUNCTION within_ulps(x, y) RESULT(close)
      !! |x - y| within 8 units in the last place of the larger magnitude (false for a NaN).
      REAL(wp), INTENT(IN) :: x, y
      close = ABS(x - y) <= 8.0_wp*SPACING(MAX(ABS(x), ABS(y)))
    END FUNCTION within_ulps
  END SUBROUTINE CD_HermiteCable_Dyn_Set_Control_Seabed

  LOGICAL FUNCTION CD_HermiteCable_Dyn_On_Seabed(model) RESULT(on)
    !! Whether an interior node of the cable is in seabed contact in its present state: inside
    !! the reach of the normal contact law. The two end nodes, held or driven, do not count.
    TYPE(CD_HermiteCableDynType), INTENT(IN) :: model
    REAL(wp) :: z_floor, xg, yg, gx, gy
    INTEGER :: node, iz, es
    CHARACTER(200) :: em

    on = .FALSE.
    IF (.NOT. (model%has_contact .OR. model%kn > CD_ZERO)) RETURN
    DO node = 2, model%nn - 1
      iz = 6*(node - 1) + 3
      z_floor = model%seabed_z
      gx = CD_ZERO
      gy = CD_ZERO
      IF (model%has_contact_bathymetry) THEN
        xg = model%contact_frame_c*model%q(iz - 2) - model%contact_frame_s*model%q(iz - 1)
        yg = model%contact_frame_s*model%q(iz - 2) + model%contact_frame_c*model%q(iz - 1)
        CALL CD_Bathymetry_Floor_Gradient(model%contact_bathymetry, xg, yg, z_floor, gx, gy, es, em)
        IF (es /= CD_BATHY_OK) CYCLE
      END IF
      IF (z_floor - model%q(iz) > -CD_SEABED_CONTACT_BLEND*SQRT(CD_ONE + gx*gx + gy*gy)) THEN
        on = .TRUE.
        RETURN
      END IF
    END DO
  END FUNCTION CD_HermiteCable_Dyn_On_Seabed

  SUBROUTINE rebuild_length_caches(model, l0_new, ErrStat, ErrMsg)
    !! Install the unstretched lengths l0_new with every cache built from them, in the order
    !! initialisation used, so the model matches one built with these lengths bit for bit:
    !! the constant mass Mgb (element by element, then the attachment masses), the nodal
    !! tributary lengths and, on a contact model, the nodal seabed coefficients
    !! (CD_Nodal_Seabed_Stiffness, as the deck builds them) with the friction spring
    !! stiffness that follows them, and on a line restrained in torsion the torsion terms built
    !! from the lengths (torsion_length_terms). Everything is built first; the model is
    !! written only when every build succeeded.
    TYPE(CD_HermiteCableDynType), INTENT(INOUT) :: model
    REAL(wp), INTENT(IN) :: l0_new(:)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    REAL(wp), ALLOCATABLE :: mgb_new(:, :), trib_new(:), kn_new(:), cn_new(:)
    REAL(wp) :: Me(12, 12)
    INTEGER :: e, k, d, dof, es, istat
    CHARACTER(200) :: em

    ErrStat = CD_HCDYN_OK; ErrMsg = ''
    IF (SIZE(l0_new) /= model%ne) THEN
      ErrStat = CD_HCDYN_BADINPUT; ErrMsg = 'length rebuild: l0 must have one entry per element'; RETURN
    END IF
    ALLOCATE (mgb_new(LDAB_D, model%ndof), trib_new(model%nn), STAT=istat)
    IF (istat /= 0) THEN
      ErrStat = CD_HCDYN_BADINPUT; ErrMsg = 'length rebuild: workspace allocation failed'; RETURN
    END IF
    mgb_new = CD_ZERO
    DO e = 1, model%ne
      CALL CD_HermiteCable_Mass(model%rho_a(e), l0_new(e), Me, es, em)
      IF (es /= CD_HCABLE_OK) THEN
        ErrStat = CD_HCDYN_BADINPUT; ErrMsg = 'length rebuild: mass assembly: '//TRIM(em); RETURN
      END IF
      CALL scatter12_band(mgb_new, Me, e)
    END DO
    IF (model%has_attach) THEN
      DO k = 1, SIZE(model%att_node)
        DO d = 1, 3
          dof = 6*(model%att_node(k) - 1) + d
          mgb_new(KL_D + KU_D + 1, dof) = mgb_new(KL_D + KU_D + 1, dof) + model%att_mass(k) + model%att_madd(k)
        END DO
      END DO
    END IF
    trib_new = CD_ZERO
    DO e = 1, model%ne
      trib_new(e) = trib_new(e) + 0.5_wp*l0_new(e)
      trib_new(e + 1) = trib_new(e + 1) + 0.5_wp*l0_new(e)
    END DO
    IF (model%has_contact) THEN
      IF (.NOT. model%has_seabed_recompute) THEN
        ErrStat = CD_HCDYN_BADINPUT
        ErrMsg = 'length rebuild: the seabed-contact model has no seabed recompute inputs'; RETURN
      END IF
      CALL CD_Nodal_Seabed_Stiffness(model%seabed_kbot, model%seabed_diameter_elem, l0_new, kn_new, es, em)
      IF (es /= CD_LINE_OK) THEN
        ErrStat = CD_HCDYN_BADINPUT; ErrMsg = 'length rebuild: seabed stiffness: '//TRIM(em); RETURN
      END IF
      cn_new = kn_new*model%seabed_cn_over_kn
    END IF
    model%l0 = l0_new
    CALL MOVE_ALLOC(mgb_new, model%Mgb)
    CALL MOVE_ALLOC(trib_new, model%trib)
    IF (model%has_contact) THEN
      CALL MOVE_ALLOC(kn_new, model%contact_kn)
      CALL MOVE_ALLOC(cn_new, model%contact_cn)
      IF (model%fr_active) model%fr_k = model%contact_kn
    END IF
    CALL torsion_length_terms(model)
  END SUBROUTINE rebuild_length_caches

  SUBROUTINE torsion_length_terms(model)
    !! The torsion terms built from the unstretched lengths, from model%l0 in the order
    !! initialisation used (CD_HermiteCable_Dyn_Set_Torsion, the deck's torsion stage): the lumped
    !! polar inertia of the nodal twist, half of each adjacent element's Irn l0 (tw_set_derived),
    !! and the torsional damping of an element given as -zeta, Bt = zeta l0 sqrt(GJ Irn)
    !! (CD_HermiteTorsion_Zeta_Damping), so the element keeps its fraction of critical damping. A
    !! direct Bt is a section property and stays. The torsion query cache, keyed on the state and
    !! not on the lengths, is dropped (Theta depends on l0 through the element shape and the
    !! coupling term). Without torsion nothing is written.
    TYPE(CD_HermiteCableDynType), INTENT(INOUT) :: model
    INTEGER :: e
    IF (.NOT. model%torsion%active) RETURN
    model%tors_c_valid = .FALSE.
    IF (.NOT. model%tw_active) RETURN
    CALL tw_set_derived(model, model%torsion)
    IF (.NOT. (ALLOCATED(model%torsion%bt_zeta) .AND. ALLOCATED(model%torsion%bt))) RETURN
    DO e = 1, model%ne
      IF (model%torsion%bt_zeta(e) > CD_ZERO) &
        model%torsion%bt(e) = CD_HermiteTorsion_Zeta_Damping(model%torsion%bt_zeta(e), model%l0(e), &
                                                             model%torsion%gj(e), model%torsion%irn(e))
    END DO
  END SUBROUTINE torsion_length_terms

  SUBROUTINE enter_committed_lengths(model, aside, ErrStat, ErrMsg)
    !! Install the lengths and rates the committed state was reached with (l0_c, l0_dot_c) for
    !! one evaluation of the committed state, setting the present ones aside: after a length
    !! change the length-dependent caches are rebuilt from l0_c, and leave_committed_lengths
    !! moves the present ones back bit for bit (the torsion terms, rebuilt from them). A model
    !! that is not under active line control,
    !! or whose lengths and rates are the committed ones, is left as it is. On failure nothing
    !! is written.
    TYPE(CD_HermiteCableDynType), INTENT(INOUT) :: model
    TYPE(committed_lengths_aside), INTENT(INOUT) :: aside
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    REAL(wp), ALLOCATABLE :: l0_old(:)

    ErrStat = CD_HCDYN_OK; ErrMsg = ''
    aside%lengths = .FALSE.
    aside%rates = .FALSE.
    IF (.NOT. model%has_ctrl) RETURN
    IF (ALL(bits_equal(model%l0, model%l0_c)) .AND. ALL(bits_equal(model%l0_dot, model%l0_dot_c))) RETURN
    IF (.NOT. ALL(bits_equal(model%l0, model%l0_c))) THEN
      aside%l0 = model%l0
      aside%mgb = model%Mgb
      aside%trib = model%trib
      IF (model%has_contact) THEN
        aside%kn = model%contact_kn
        aside%cn = model%contact_cn
        IF (model%fr_active) aside%frk = model%fr_k
      END IF
      ! a copy, so no subobject of model is associated with a second dummy
      l0_old = model%l0_c
      CALL rebuild_length_caches(model, l0_old, ErrStat, ErrMsg)
      IF (ErrStat /= CD_HCDYN_OK) RETURN
      aside%lengths = .TRUE.
    END IF
    aside%rate = model%l0_dot
    model%l0_dot = model%l0_dot_c
    aside%rates = .TRUE.
  END SUBROUTINE enter_committed_lengths

  SUBROUTINE leave_committed_lengths(model, aside)
    !! Move back the present lengths, rates and caches enter_committed_lengths set aside.
    TYPE(CD_HermiteCableDynType), INTENT(INOUT) :: model
    TYPE(committed_lengths_aside), INTENT(INOUT) :: aside
    IF (aside%lengths) THEN
      model%l0 = aside%l0
      CALL MOVE_ALLOC(aside%mgb, model%Mgb)
      CALL MOVE_ALLOC(aside%trib, model%trib)
      IF (model%has_contact) THEN
        CALL MOVE_ALLOC(aside%kn, model%contact_kn)
        CALL MOVE_ALLOC(aside%cn, model%contact_cn)
        IF (model%fr_active) CALL MOVE_ALLOC(aside%frk, model%fr_k)
      END IF
      ! the torsion terms of the present lengths, rebuilt from them as they were built
      CALL torsion_length_terms(model)
    END IF
    IF (aside%rates) model%l0_dot = aside%rate
    aside%lengths = .FALSE.
    aside%rates = .FALSE.
  END SUBROUTINE leave_committed_lengths

  SUBROUTINE assemble_committed_force(model, ErrStat, ErrMsg)
    !! The committed force F_n = R(q_n, v_n, t_n) into ws_R, with the lengths and rates the
    !! committed state was reached with (l0_c, l0_dot_c; enter_committed_lengths); without a
    !! pending length or rate change this is the plain evaluation.
    TYPE(CD_HermiteCableDynType), INTENT(INOUT) :: model
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    TYPE(committed_lengths_aside) :: aside
    INTEGER :: es
    CHARACTER(1024) :: em

    CALL enter_committed_lengths(model, aside, es, em)
    IF (es /= CD_HCDYN_OK) THEN
      ErrStat = es; ErrMsg = 'committed force: '//TRIM(em); RETURN
    END IF
    CALL assemble_residual(model, model%q, model%v, model%t, .TRUE., .FALSE., ErrStat, ErrMsg)
    CALL leave_committed_lengths(model, aside)
  END SUBROUTINE assemble_committed_force

  SUBROUTINE solve_committed_acceleration(model, ErrStat, ErrMsg, pres_dofs, pres_a)
    !! solve_consistent_acceleration for the committed state: the acceleration is the
    !! committed state's, so under active line control it is solved with the lengths and rates
    !! that state was reached with (l0_c, l0_dot_c; enter_committed_lengths), which stay the
    !! committed ones. Without a pending length or rate change this is the plain solve.
    TYPE(CD_HermiteCableDynType), INTENT(INOUT) :: model
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    INTEGER, INTENT(IN), OPTIONAL :: pres_dofs(:)
    REAL(wp), INTENT(IN), OPTIONAL :: pres_a(:)
    TYPE(committed_lengths_aside) :: aside
    INTEGER :: es
    CHARACTER(1024) :: em

    CALL enter_committed_lengths(model, aside, es, em)
    IF (es /= CD_HCDYN_OK) THEN
      ErrStat = es; ErrMsg = 'committed acceleration: '//TRIM(em); RETURN
    END IF
    CALL solve_consistent_acceleration(model, ErrStat, ErrMsg, pres_dofs=pres_dofs, pres_a=pres_a)
    CALL leave_committed_lengths(model, aside)
  END SUBROUTINE solve_committed_acceleration

  ELEMENTAL LOGICAL FUNCTION bits_equal(a, b) RESULT(same)
    !! Bitwise equality of two reals (so +0 and -0 differ).
    REAL(wp), INTENT(IN) :: a, b
    same = TRANSFER(a, 0_INT64) == TRANSFER(b, 0_INT64)
  END FUNCTION bits_equal

  ELEMENTAL LOGICAL FUNCTION reals_equal(a, b) RESULT(same)
    !! a == b, written so that gfortran does not warn: a NaN never matches, +0 matches -0.
    REAL(wp), INTENT(IN) :: a, b
    same = a <= b .AND. a >= b
  END FUNCTION reals_equal

  ELEMENTAL REAL(wp) FUNCTION positive_zero(x) RESULT(y)
    !! x with a negative zero replaced by +0, on the bits (so no floating-point mode can keep
    !! the sign); every other value is returned unchanged.
    REAL(wp), INTENT(IN) :: x
    INTEGER(INT64) :: bits
    bits = TRANSFER(x, 0_INT64)
    IF (bits == -HUGE(0_INT64) - 1_INT64) bits = 0_INT64
    y = TRANSFER(bits, y)
  END FUNCTION positive_zero

  SUBROUTINE CD_HermiteCable_Dyn_Set_ForceBlend(model, enabled, ErrStat, ErrMsg)
    !! Select the generalised-alpha blend. enabled = .TRUE. (the default): the residual
    !! blends the forces, G = M a_am + (1-af) r(q_{n+1}, v_{n+1}, t_{n+1}) + af r(q_n, v_n, t_n),
    !! with r_n reused from the previous converged step. enabled = .FALSE.: the forces are
    !! evaluated at the blended state (q_af, v_af, t_af), the classical form of Chung and
    !! Hulbert, whose blended Hermite tangents are shortened when the line rotates.
    TYPE(CD_HermiteCableDynType), INTENT(INOUT) :: model
    LOGICAL, INTENT(IN) :: enabled
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    ErrStat = CD_HCDYN_OK
    ErrMsg = ''
    IF (.NOT. model%initialized) THEN
      ErrStat = CD_HCDYN_BADINPUT
      ErrMsg = 'CD_HermiteCable_Dyn_Set_ForceBlend: model not initialised'
      RETURN
    END IF
    IF (model%has_ctrl .AND. .NOT. enabled) THEN
      ! active line control needs the committed-length treatment of the force blend
      ErrStat = CD_HCDYN_BADINPUT
      ErrMsg = 'CD_HermiteCable_Dyn_Set_ForceBlend: a model under active line control needs the force blend'
      RETURN
    END IF
    model%force_blend = enabled
    model%fc_valid = .FALSE.
    model%fc_clears = model%fc_clears + 1
    model%tr_valid = .FALSE.
  END SUBROUTINE CD_HermiteCable_Dyn_Set_ForceBlend

  SUBROUTINE CD_HermiteCable_Dyn_Set_ModifiedNewton(model, enabled, ErrStat, ErrMsg)
    !! Enable/disable modified Newton (within-step tangent reuse) on the (already
    !! initialised) dynamic model: the effective tangent is assembled and factored ONCE
    !! per step at the predictor and the factorization is reused for every subsequent
    !! Newton iteration of that step; a line search that cannot improve under the stale
    !! direction refreshes the tangent once before the safe damped fallback. Disabled
    !! (the default), a step factors a fresh tangent every iteration after any carried
    !! factor (cross-step reuse) is dropped. The committed state still
    !! satisfies the SAME convergence tolerance either way -- reuse changes the iteration
    !! path, not the equations or the convergence criterion.
    TYPE(CD_HermiteCableDynType), INTENT(INOUT) :: model
    LOGICAL, INTENT(IN) :: enabled
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    ErrStat = CD_HCDYN_OK
    ErrMsg = ''
    IF (.NOT. model%initialized) THEN
      ErrStat = CD_HCDYN_BADINPUT
      ErrMsg = 'CD_HermiteCable_Dyn_Set_ModifiedNewton: model not initialised'; RETURN
    END IF
    model%modified_newton = enabled
  END SUBROUTINE CD_HermiteCable_Dyn_Set_ModifiedNewton

  SUBROUTINE CD_HermiteCable_Dyn_Set_TangentReuse(model, enabled, ErrStat, ErrMsg)
    !! Enable (the default) or disable cross-step factor reuse (see the type note): a step
    !! that continues from the last committed state at the same dt starts Newton on that
    !! step's factored tangent and refreshes it when the contraction weakens. Every step
    !! still converges to the same tolerance. A host that restarts from a checkpoint and
    !! must reproduce the uninterrupted run disables it: the factor is not in the state.
    TYPE(CD_HermiteCableDynType), INTENT(INOUT) :: model
    LOGICAL, INTENT(IN) :: enabled
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    ErrStat = CD_HCDYN_OK
    ErrMsg = ''
    IF (.NOT. model%initialized) THEN
      ErrStat = CD_HCDYN_BADINPUT
      ErrMsg = 'CD_HermiteCable_Dyn_Set_TangentReuse: model not initialised'; RETURN
    END IF
    model%tangent_reuse = enabled
    model%tr_valid = .FALSE.
  END SUBROUTINE CD_HermiteCable_Dyn_Set_TangentReuse

  SUBROUTINE CD_HermiteCable_Dyn_Set_Tensile_Safety(model, enabled, ErrStat, ErrMsg)
    !! Require a physically tensile finite-bending response. The element-mean axial force,
    !! averaged over three elements, is checked after nonlinear convergence and before commit.
    TYPE(CD_HermiteCableDynType), INTENT(INOUT) :: model
    LOGICAL, INTENT(IN) :: enabled
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    CALL CD_HermiteCable_Dyn_Set_Tensile_Monitor(model, &
                                                 MERGE(CD_HCDYN_TENSILE_ERROR, &
                                                       CD_HCDYN_TENSILE_OFF, enabled), &
                                                 ErrStat, ErrMsg, &
                                                 strain_tolerance=CD_HCDYN_AXIAL_STRAIN_TOL)
  END SUBROUTINE CD_HermiteCable_Dyn_Set_Tensile_Safety

  SUBROUTINE CD_HermiteCable_Dyn_Set_Tensile_Monitor(model, mode, ErrStat, ErrMsg, strain_tolerance)
    !! Configure the axial-force audit of the converged step (the element-mean axial force,
    !! averaged over three elements; see CD_HermiteCable_Dyn_Step). ERROR is the
    !! tensile_safety=True hard gate. WARN commits the state and records one event per accepted
    !! integration step, allowing long runs to remain auditable without suppressing results.
    TYPE(CD_HermiteCableDynType), INTENT(INOUT) :: model
    INTEGER, INTENT(IN) :: mode
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    REAL(wp), INTENT(IN), OPTIONAL :: strain_tolerance
    ErrStat = CD_HCDYN_OK; ErrMsg = ''
    IF (.NOT. model%initialized) THEN
      ErrStat = CD_HCDYN_BADINPUT
      ErrMsg = 'CD_HermiteCable_Dyn_Set_Tensile_Monitor: model not initialised'; RETURN
    END IF
    IF (mode < CD_HCDYN_TENSILE_OFF .OR. mode > CD_HCDYN_TENSILE_ERROR) THEN
      ErrStat = CD_HCDYN_BADINPUT
      ErrMsg = 'CD_HermiteCable_Dyn_Set_Tensile_Monitor: invalid mode'; RETURN
    END IF
    IF (PRESENT(strain_tolerance)) THEN
      IF (.NOT. CD_Is_Finite(strain_tolerance) .OR. strain_tolerance < CD_ZERO) THEN
        ErrStat = CD_HCDYN_BADINPUT
        ErrMsg = 'CD_HermiteCable_Dyn_Set_Tensile_Monitor: strain_tolerance must be finite and non-negative'
        RETURN
      END IF
      model%tensile_strain_tolerance = strain_tolerance
    END IF
    model%tensile_mode = mode
    model%require_tensile = mode == CD_HCDYN_TENSILE_ERROR
    model%tensile_event_count = 0
    model%tensile_worst_element = 0
    model%tensile_worst_force = CD_ZERO
    model%tensile_worst_threshold = CD_ZERO
    model%tensile_worst_xi = CD_ZERO
    model%tensile_worst_time = CD_ZERO
  END SUBROUTINE CD_HermiteCable_Dyn_Set_Tensile_Monitor

  SUBROUTINE CD_HermiteCable_Dyn_Get_Tensile_Diagnostics(model, event_count, worst_force, &
                                                         worst_threshold, worst_element, worst_xi, &
                                                         worst_time, ErrStat, ErrMsg)
    TYPE(CD_HermiteCableDynType), INTENT(IN) :: model
    INTEGER, INTENT(OUT) :: event_count, worst_element, ErrStat
    REAL(wp), INTENT(OUT) :: worst_force, worst_threshold, worst_xi, worst_time
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    event_count = 0; worst_element = 0
    worst_force = CD_ZERO; worst_threshold = CD_ZERO; worst_xi = CD_ZERO; worst_time = CD_ZERO
    ErrStat = CD_HCDYN_OK; ErrMsg = ''
    IF (.NOT. model%initialized) THEN
      ErrStat = CD_HCDYN_BADINPUT
      ErrMsg = 'CD_HermiteCable_Dyn_Get_Tensile_Diagnostics: model not initialised'; RETURN
    END IF
    event_count = model%tensile_event_count
    worst_force = model%tensile_worst_force
    worst_threshold = model%tensile_worst_threshold
    worst_element = model%tensile_worst_element
    worst_xi = model%tensile_worst_xi
    worst_time = model%tensile_worst_time
  END SUBROUTINE CD_HermiteCable_Dyn_Get_Tensile_Diagnostics

  SUBROUTINE CD_HermiteCable_Dyn_Get_Recovery_Diagnostics(model, event_count, max_substeps_used, &
                                                          ErrStat, ErrMsg)
    TYPE(CD_HermiteCableDynType), INTENT(IN) :: model
    INTEGER, INTENT(OUT) :: event_count, max_substeps_used, ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    event_count = 0; max_substeps_used = 0; ErrStat = CD_HCDYN_OK; ErrMsg = ''
    IF (.NOT. model%initialized) THEN
      ErrStat = CD_HCDYN_BADINPUT
      ErrMsg = 'CD_HermiteCable_Dyn_Get_Recovery_Diagnostics: model not initialised'; RETURN
    END IF
    event_count = model%recovery_event_count
    max_substeps_used = model%recovery_max_substeps_used
  END SUBROUTINE CD_HermiteCable_Dyn_Get_Recovery_Diagnostics

  SUBROUTINE CD_HermiteCable_Dyn_Set_AdaptiveNewton(model, enabled, ErrStat, ErrMsg, warmup, threshold)
    !! Enable/disable ADAPTIVE modified Newton: the solver runs the first `warmup` steps in
    !! full Newton, then latches tangent reuse ON for the rest of the run iff the warmup
    !! averaged more than `threshold` Newton iterations/step -- so reuse is used only where it
    !! pays (harder/larger systems) and full Newton keeps the easy cases cheap. Resets the
    !! measurement counters. Convergence tolerance is unchanged (reuse changes only the
    !! iteration path). warmup defaults to 4, threshold to 5.0. Disabling reverts to the
    !! explicit modified_newton flag.
    !!
    !! CAVEAT (off by default): the warmup-then-latch heuristic is NOT a reliable
    !! win and is not wired into any deck. Forced modified Newton (Set_ModifiedNewton) is the
    !! working reuse path -- it starts reuse at REST where the reference tangent is fresh.
    !! The adaptive latch instead switches ON during the harder transient, where the reference
    !! tangent is immediately stale, and can need more solves per step than both full and
    !! forced modified Newton; the short warmup also under-measures, so a genuinely stiff run
    !! may never latch. A correct auto-selector needs a rebuild-reference-on-activation or
    !! per-step disable-if-not-helping scheme, not a warmup threshold. Prefer
    !! Set_ModifiedNewton; use this only for experiments.
    TYPE(CD_HermiteCableDynType), INTENT(INOUT) :: model
    LOGICAL, INTENT(IN) :: enabled
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    INTEGER, INTENT(IN), OPTIONAL :: warmup
    REAL(wp), INTENT(IN), OPTIONAL :: threshold
    ErrStat = CD_HCDYN_OK
    ErrMsg = ''
    IF (.NOT. model%initialized) THEN
      ErrStat = CD_HCDYN_BADINPUT
      ErrMsg = 'CD_HermiteCable_Dyn_Set_AdaptiveNewton: model not initialised'; RETURN
    END IF
    ! Validate BOTH optional parameters before mutating the model: a rejected call must not
    ! leave a partial change (e.g. a valid warmup applied while an invalid threshold is rejected).
    IF (PRESENT(warmup)) THEN
      IF (warmup < 1) THEN
        ErrStat = CD_HCDYN_BADINPUT
        ErrMsg = 'CD_HermiteCable_Dyn_Set_AdaptiveNewton: warmup must be >= 1'; RETURN
      END IF
    END IF
    IF (PRESENT(threshold)) THEN
      IF (.NOT. (threshold > CD_ZERO)) THEN
        ErrStat = CD_HCDYN_BADINPUT
        ErrMsg = 'CD_HermiteCable_Dyn_Set_AdaptiveNewton: threshold must be > 0'; RETURN
      END IF
    END IF
    IF (PRESENT(warmup)) model%na_warmup = warmup
    IF (PRESENT(threshold)) model%na_threshold = threshold
    model%newton_adaptive = enabled
    model%na_steps_done = 0
    model%na_iter_sum = CD_ZERO
    model%na_mn_active = .FALSE.
  END SUBROUTINE CD_HermiteCable_Dyn_Set_AdaptiveNewton

  SUBROUTINE CD_HermiteCable_Dyn_Set_EndConnection(model, k_rot, d0, ErrStat, ErrMsg, connection_mode)
    !! Attach pinned, finite-stiffness, or exact rigid bending connections to
    !! an initialised dynamic model.
    !!
    !! Finite mode is an isotropic joint carrying rotational stiffness about a
    !! preferred no-moment direction. It enters as a configuration-dependent
    !! generalized load with a consistent symmetric tangent. Rigid mode instead
    !! eliminates the two transverse tangent coordinates in an orthonormal local
    !! basis; it is not a large-stiffness approximation.
    !!
    !! The spring restrains only the tangent DIRECTION: its generalized force satisfies
    !! f . d == 0 identically, so it never acts on |m|, which carries axial stretch.
    !! Clamping that component instead would impose an inextensibility over-constraint.
    !!
    !! k_rot(2)  : rotational stiffness [N m/rad] at end A (node 1) and end B (node nn).
    !!             A zero entry leaves that end pinned. Negative and non-finite values
    !!             are rejected. Rigid mode requires zero here.
    !! d0(3,2)   : preferred no-moment directions for those ends; each must be non-null and
    !!             is normalised here. Required for every non-pinned end.
    !! connection_mode(2), optional: Pinned, Finite, or Rigid. If omitted,
    !!             zero/positive stiffness selects Pinned/Finite.
    TYPE(CD_HermiteCableDynType), INTENT(INOUT) :: model
    REAL(wp), INTENT(IN) :: k_rot(2), d0(3, 2)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    INTEGER, INTENT(IN), OPTIONAL :: connection_mode(2)
    INTEGER :: iend, base, mode_new(2), mode_old(2)
    REAL(wp) :: dn, d_new(3, 2), f_check(3), k_check(3, 3), basis(3, 3), projected(3)
    REAL(wp), ALLOCATABLE :: q_new(:), v_new(:), q_old(:), v_old(:), a_old(:)
    REAL(wp) :: k_old(2), d_old(3, 2)
    LOGICAL :: had_conn, snap_was_valid
    LOGICAL, ALLOCATABLE :: solve_mask_old(:)
    INTEGER :: es
    CHARACTER(1024) :: em

    ErrStat = CD_HCDYN_OK; ErrMsg = ''
    ! A load-configuration change invalidates the cached committed force F_n.
    model%fc_valid = .FALSE.
    model%fc_clears = model%fc_clears + 1
    model%tr_valid = .FALSE.
    IF (.NOT. model%initialized) THEN
      ErrStat = CD_HCDYN_BADINPUT
      ErrMsg = 'CD_HermiteCable_Dyn_Set_EndConnection: model is not initialised'
      RETURN
    END IF
    ! The torsion end frames take a rigid end's director from its connection and its Theta from
    ! the current tangents: changing the connections under an installed torsion would leave both
    ! stale, so the connections come first.
    IF (model%torsion%active) THEN
      ErrStat = CD_HCDYN_BADINPUT
      ErrMsg = 'CD_HermiteCable_Dyn_Set_EndConnection: the model carries torsion; set the end connections '// &
               'before the torsion (CD_HermiteCable_Dyn_Set_Torsion)'
      RETURN
    END IF

    IF (.NOT. CD_All_Finite(k_rot) .OR. ANY(k_rot < CD_ZERO)) THEN
      ErrStat = CD_HCDYN_BADINPUT
      ErrMsg = 'CD_HermiteCable_Dyn_Set_EndConnection: stiffnesses must be finite and non-negative'
      RETURN
    END IF

    ! Validate and normalise BEFORE touching the model, so a rejected call leaves no trace.
    d_new = CD_ZERO
    IF (PRESENT(connection_mode)) THEN
      mode_new = connection_mode
    ELSE
      WHERE (k_rot > CD_ZERO)
        mode_new = CD_ENDCONN_FINITE
      ELSEWHERE
        mode_new = CD_ENDCONN_PINNED
      END WHERE
    END IF
    ALLOCATE (q_new(model%ndof), v_new(model%ndof), q_old(model%ndof), &
              v_old(model%ndof), a_old(model%ndof), solve_mask_old(model%ndof))
    q_new = model%q
    v_new = model%v
    DO iend = 1, 2
      IF (mode_new(iend) < CD_ENDCONN_PINNED .OR. mode_new(iend) > CD_ENDCONN_RIGID) THEN
        ErrStat = CD_HCDYN_BADINPUT
        ErrMsg = 'CD_HermiteCable_Dyn_Set_EndConnection: mode must be Pinned, Finite, or Rigid'
        RETURN
      END IF
      IF (mode_new(iend) == CD_ENDCONN_PINNED) THEN
        IF (k_rot(iend) > CD_ZERO) THEN
          ErrStat = CD_HCDYN_BADINPUT
          ErrMsg = 'CD_HermiteCable_Dyn_Set_EndConnection: Pinned mode requires zero stiffness'
          RETURN
        END IF
        CYCLE
      ELSE IF (mode_new(iend) == CD_ENDCONN_FINITE) THEN
        IF (k_rot(iend) <= CD_ZERO) THEN
          ErrStat = CD_HCDYN_BADINPUT
          ErrMsg = 'CD_HermiteCable_Dyn_Set_EndConnection: Finite mode requires positive stiffness'
          RETURN
        END IF
      ELSE IF (k_rot(iend) > CD_ZERO) THEN
        ErrStat = CD_HCDYN_BADINPUT
        ErrMsg = 'CD_HermiteCable_Dyn_Set_EndConnection: Rigid mode is exact and requires zero stiffness'
        RETURN
      END IF
      IF (.NOT. CD_All_Finite(d0(:, iend))) THEN
        ErrStat = CD_HCDYN_BADINPUT
        ErrMsg = 'CD_HermiteCable_Dyn_Set_EndConnection: preferred directions must be finite'
        RETURN
      END IF
      dn = SQRT(DOT_PRODUCT(d0(:, iend), d0(:, iend)))
      IF (.NOT. CD_Is_Finite(dn) .OR. dn <= SQRT(TINY(CD_ONE))) THEN
        ErrStat = CD_HCDYN_BADINPUT
        ErrMsg = 'CD_HermiteCable_Dyn_Set_EndConnection: preferred direction must be non-null '// &
                 'for a non-pinned end'
        RETURN
      END IF
      d_new(:, iend) = d0(:, iend)/dn
      IF (iend == 1) THEN
        base = 3
      ELSE
        base = 6*(model%nn - 1) + 3
      END IF
      IF (mode_new(iend) == CD_ENDCONN_FINITE) THEN
        CALL CD_EndConn_Spring(model%q(base + 1:base + 3), d_new(:, iend), k_rot(iend), &
                               f_check, k_check, es, em)
        IF (es /= CD_ENDCONN_OK) THEN
          ErrStat = CD_HCDYN_BADINPUT
          ErrMsg = 'CD_HermiteCable_Dyn_Set_EndConnection: '//TRIM(em)
          RETURN
        END IF
      ELSE
        IF (ANY(.NOT. model%freemask(base + 1:base + 3))) THEN
          ErrStat = CD_HCDYN_BADINPUT
          ErrMsg = 'CD_HermiteCable_Dyn_Set_EndConnection: rigid tangent DOFs must not also be fixed'
          RETURN
        END IF
        CALL CD_EndConn_Basis(d_new(:, iend), basis, es, em)
        IF (es == CD_ENDCONN_OK) &
          CALL CD_EndConn_Project(q_new(base + 1:base + 3), d_new(:, iend), projected, es, em)
        IF (es /= CD_ENDCONN_OK) THEN
          ErrStat = CD_HCDYN_BADINPUT
          ErrMsg = 'CD_HermiteCable_Dyn_Set_EndConnection: '//TRIM(em)
          RETURN
        END IF
        q_new(base + 1:base + 3) = projected
        v_new(base + 1:base + 3) = DOT_PRODUCT(v_new(base + 1:base + 3), basis(:, 1))*basis(:, 1)
      END IF
    END DO

    ! Transactional, as Set_Drag is: the acceleration refresh below can fail after the
    ! parameters are installed, and the model must then be restored rather than left in a
    ! partially applied state.
    had_conn = model%has_endconn
    k_old = model%endconn_k
    d_old = model%endconn_d0
    mode_old = model%endconn_mode
    q_old = model%q
    v_old = model%v
    a_old = model%a
    solve_mask_old = model%solve_mask
    snap_was_valid = model%snap_valid

    model%endconn_d0 = d_new
    model%endconn_k = k_rot
    model%endconn_mode = mode_new
    model%has_endconn = ANY(mode_new /= CD_ENDCONN_PINNED)
    model%q = q_new
    model%v = v_new
    model%a = a_old
    model%solve_mask = model%freemask
    DO iend = 1, 2
      IF (mode_new(iend) /= CD_ENDCONN_RIGID) CYCLE
      IF (iend == 1) THEN
        base = 3
      ELSE
        base = 6*(model%nn - 1) + 3
      END IF
      model%a(base + 1:base + 3) = DOT_PRODUCT(model%a(base + 1:base + 3), &
                                               d_new(:, iend))*d_new(:, iend)
      model%solve_mask(base + 2:base + 3) = .FALSE.
    END DO
    model%snap_valid = .FALSE.

    ! Refresh the consistent acceleration now that the load set includes the connection.
    ! Init solved M a0 = f_ext - f_int without it; leaving a0 stale would launch the first
    ! step with an acceleration that omits the connection moment, so a state that is a true
    ! equilibrium WITH the connection would still move.
    CALL solve_consistent_acceleration(model, ErrStat, ErrMsg)
    IF (ErrStat /= CD_HCDYN_OK) THEN
      model%a = a_old
      model%q = q_old
      model%v = v_old
      model%endconn_k = k_old
      model%endconn_d0 = d_old
      model%endconn_mode = mode_old
      model%solve_mask = solve_mask_old
      model%has_endconn = had_conn
      model%snap_valid = snap_was_valid
    END IF
  END SUBROUTINE CD_HermiteCable_Dyn_Set_EndConnection

  SUBROUTINE prepare_endconn_directions(model, requested, prepared, ErrStat, ErrMsg)
    !! Validate and normalise a target set of preferred directions without mutating
    !! the committed model. Every non-pinned connection consumes a direction.
    TYPE(CD_HermiteCableDynType), INTENT(IN) :: model
    REAL(wp), INTENT(IN) :: requested(3, 2)
    REAL(wp), INTENT(OUT) :: prepared(3, 2)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    INTEGER :: iend
    REAL(wp) :: dn

    ErrStat = CD_HCDYN_OK
    ErrMsg = ''
    prepared = model%endconn_d0
    IF (.NOT. model%has_endconn) THEN
      ErrStat = CD_HCDYN_BADINPUT
      ErrMsg = 'moving end-connection directions require a configured connection'
      RETURN
    END IF
    DO iend = 1, 2
      IF (model%endconn_mode(iend) == CD_ENDCONN_PINNED) CYCLE
      IF (.NOT. CD_All_Finite(requested(:, iend))) THEN
        ErrStat = CD_HCDYN_BADINPUT
        ErrMsg = 'moving end-connection directions must be finite'
        RETURN
      END IF
      dn = SQRT(DOT_PRODUCT(requested(:, iend), requested(:, iend)))
      IF (.NOT. CD_Is_Finite(dn) .OR. dn <= SQRT(TINY(CD_ONE))) THEN
        ErrStat = CD_HCDYN_BADINPUT
        ErrMsg = 'moving end-connection direction must be non-null at each connected end'
        RETURN
      END IF
      prepared(:, iend) = requested(:, iend)/dn
    END DO
  END SUBROUTINE prepare_endconn_directions

  SUBROUTINE interpolate_endconn_directions(model, d0, d1, fraction, d, ErrStat, ErrMsg)
    !! Shortest-arc interpolation of the preferred direction over a coupling
    !! interval. This supplies the direction at the generalised-alpha load station
    !! and at each recovery substep without inventing a stiffness-dependent penalty.
    TYPE(CD_HermiteCableDynType), INTENT(IN) :: model
    REAL(wp), INTENT(IN) :: d0(3, 2), d1(3, 2), fraction
    REAL(wp), INTENT(OUT) :: d(3, 2)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    INTEGER :: iend
    REAL(wp) :: dot01, theta, sintheta, dn

    ErrStat = CD_HCDYN_OK
    ErrMsg = ''
    d = d0
    IF (.NOT. CD_Is_Finite(fraction) .OR. fraction < CD_ZERO .OR. fraction > CD_ONE) THEN
      ErrStat = CD_HCDYN_BADINPUT
      ErrMsg = 'end-connection interpolation fraction must lie in [0,1]'
      RETURN
    END IF
    DO iend = 1, 2
      IF (model%endconn_mode(iend) == CD_ENDCONN_PINNED) CYCLE
      dot01 = MAX(-CD_ONE, MIN(CD_ONE, DOT_PRODUCT(d0(:, iend), d1(:, iend))))
      IF (dot01 <= -CD_ONE + 64.0_wp*EPSILON(CD_ONE)) THEN
        ErrStat = CD_HCDYN_BADINPUT
        ErrMsg = 'preferred direction rotates by 180 degrees in one step; subdivide the host motion'
        RETURN
      ELSE IF (dot01 >= CD_ONE - 64.0_wp*EPSILON(CD_ONE)) THEN
        d(:, iend) = (CD_ONE - fraction)*d0(:, iend) + fraction*d1(:, iend)
      ELSE
        theta = ACOS(dot01)
        sintheta = SIN(theta)
        d(:, iend) = SIN((CD_ONE - fraction)*theta)/sintheta*d0(:, iend) + &
                     SIN(fraction*theta)/sintheta*d1(:, iend)
      END IF
      dn = SQRT(DOT_PRODUCT(d(:, iend), d(:, iend)))
      IF (.NOT. CD_Is_Finite(dn) .OR. dn <= SQRT(TINY(CD_ONE))) THEN
        ErrStat = CD_HCDYN_BADINPUT
        ErrMsg = 'preferred-direction interpolation is singular'
        RETURN
      END IF
      d(:, iend) = d(:, iend)/dn
    END DO
  END SUBROUTINE interpolate_endconn_directions

  SUBROUTINE prepare_endconn_derivatives(model, directions, rates, accelerations, ErrStat, ErrMsg, &
                                         requested_rates, requested_accelerations)
    !! Validate first and second derivatives of rigid unit preferred directions. For a
    !! unit vector d, d.d_dot = 0 and d.d_ddot = -d_dot.d_dot. Enforcing these
    !! identities at the API boundary prevents a host from silently changing the
    !! tangent magnitude through malformed angular kinematics.
    TYPE(CD_HermiteCableDynType), INTENT(IN) :: model
    REAL(wp), INTENT(IN) :: directions(3, 2)
    REAL(wp), INTENT(OUT) :: rates(3, 2), accelerations(3, 2)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    REAL(wp), INTENT(IN), OPTIONAL :: requested_rates(3, 2), requested_accelerations(3, 2)
    INTEGER :: iend
    REAL(wp) :: orthogonality, normal_identity, scale

    ErrStat = CD_HCDYN_OK
    ErrMsg = ''
    rates = CD_ZERO
    accelerations = CD_ZERO
    IF (PRESENT(requested_rates) .NEQV. PRESENT(requested_accelerations)) THEN
      ErrStat = CD_HCDYN_BADINPUT
      ErrMsg = 'direction rate and acceleration must be supplied together'
      RETURN
    END IF
    IF (.NOT. PRESENT(requested_rates)) RETURN
    DO iend = 1, 2
      IF (model%endconn_mode(iend) /= CD_ENDCONN_RIGID) CYCLE
      IF (.NOT. (CD_All_Finite(requested_rates(:, iend)) .AND. &
                 CD_All_Finite(requested_accelerations(:, iend)))) THEN
        ErrStat = CD_HCDYN_BADINPUT
        ErrMsg = 'rigid direction derivatives must be finite'
        RETURN
      END IF
      rates(:, iend) = requested_rates(:, iend)
      accelerations(:, iend) = requested_accelerations(:, iend)
      orthogonality = DOT_PRODUCT(directions(:, iend), rates(:, iend))
      normal_identity = DOT_PRODUCT(directions(:, iend), accelerations(:, iend)) + &
                        DOT_PRODUCT(rates(:, iend), rates(:, iend))
      scale = MAX(CD_ONE, SQRT(DOT_PRODUCT(rates(:, iend), rates(:, iend))), &
                  SQRT(DOT_PRODUCT(accelerations(:, iend), accelerations(:, iend))))
      IF (ABS(orthogonality) > 1.0e-9_wp*scale .OR. ABS(normal_identity) > 1.0e-9_wp*scale*scale) THEN
        ErrStat = CD_HCDYN_BADINPUT
        ErrMsg = 'rigid direction derivatives violate unit-vector kinematics'
        RETURN
      END IF
    END DO
  END SUBROUTINE prepare_endconn_derivatives

  SUBROUTINE rigid_tangent_scalar_state(model, directions, q, v, a, magnitude, rate, acceleration)
    !! Recover n, n_dot, and n_ddot from the global tangent state m = n d.
    !! The transverse velocity determines d_dot; d.d_ddot = -|d_dot|^2 then
    !! separates the material magnitude acceleration from m_ddot.
    TYPE(CD_HermiteCableDynType), INTENT(IN) :: model
    REAL(wp), INTENT(IN) :: directions(3, 2), q(:), v(:), a(:)
    REAL(wp), INTENT(OUT) :: magnitude(2), rate(2), acceleration(2)
    INTEGER :: iend, base
    REAL(wp) :: direction_rate(3)
    magnitude = CD_ZERO
    rate = CD_ZERO
    acceleration = CD_ZERO
    DO iend = 1, 2
      IF (model%endconn_mode(iend) /= CD_ENDCONN_RIGID) CYCLE
      IF (iend == 1) THEN
        base = 3
      ELSE
        base = 6*(model%nn - 1) + 3
      END IF
      magnitude(iend) = DOT_PRODUCT(q(base + 1:base + 3), directions(:, iend))
      rate(iend) = DOT_PRODUCT(v(base + 1:base + 3), directions(:, iend))
      direction_rate = (v(base + 1:base + 3) - rate(iend)*directions(:, iend))/magnitude(iend)
      acceleration(iend) = DOT_PRODUCT(a(base + 1:base + 3), directions(:, iend)) + &
                           magnitude(iend)*DOT_PRODUCT(direction_rate, direction_rate)
    END DO
  END SUBROUTINE rigid_tangent_scalar_state

  SUBROUTINE rigid_direction_derivatives_from_state(model, directions, q, v, a, rates, accelerations)
    TYPE(CD_HermiteCableDynType), INTENT(IN) :: model
    REAL(wp), INTENT(IN) :: directions(3, 2), q(:), v(:), a(:)
    REAL(wp), INTENT(OUT) :: rates(3, 2), accelerations(3, 2)
    REAL(wp) :: magnitude(2), magnitude_rate(2), magnitude_acceleration(2)
    INTEGER :: iend, base
    rates = CD_ZERO
    accelerations = CD_ZERO
    CALL rigid_tangent_scalar_state(model, directions, q, v, a, magnitude, magnitude_rate, magnitude_acceleration)
    DO iend = 1, 2
      IF (model%endconn_mode(iend) /= CD_ENDCONN_RIGID) CYCLE
      IF (iend == 1) THEN
        base = 3
      ELSE
        base = 6*(model%nn - 1) + 3
      END IF
      rates(:, iend) = (v(base + 1:base + 3) - magnitude_rate(iend)*directions(:, iend))/magnitude(iend)
      accelerations(:, iend) = (a(base + 1:base + 3) - &
                                magnitude_acceleration(iend)*directions(:, iend) - &
                                2.0_wp*magnitude_rate(iend)*rates(:, iend))/magnitude(iend)
    END DO
  END SUBROUTINE rigid_direction_derivatives_from_state

  SUBROUTINE CD_HermiteCable_Dyn_Set_Drag(model, rho_w, diam, cdn, cdt, waterline_z, current, ErrStat, ErrMsg, &
                                          gravity)
    !! Enable per-element Morison quadratic drag on the (already initialised) dynamic model. The
    !! drag opposes the cable's velocity relative to a uniform fluid velocity `current`; a Gauss
    !! point above waterline_z is dry (no drag). This is the damping that makes a driven dynamic
    !! cable physical (an undamped cable builds up under sustained forcing).
    !!
    !! The same configuration defines the free surface for the self-weight: the part of the line
    !! above the surface displaces no water, so its buoyancy rho_w*gravity*pi*diam^2/4 per
    !! reference length is restored on top of the submerged weight w (exact dry-interval
    !! integration with its waterline-crossing tangent; CD_HermiteCable_Dry_Buoyancy).
    !!
    !! rho_w        : fluid mass density (kg/m^3), > 0.
    !! diam(ne)     : per-element hydrodynamic (drag and displacement) diameter, > 0.
    !! cdn, cdt(ne) : per-element normal / tangential drag coefficients, >= 0.
    !! waterline_z  : still-water level; a Gauss point with z above it is dry.
    !! current(3)   : uniform fluid velocity (0 = still water, drag purely damps the cable's motion).
    !! gravity      : optional gravitational acceleration for the dry-part buoyancy (m/s^2, > 0;
    !!                default 9.80665). Pass the value the submerged weight w was formed with.
    TYPE(CD_HermiteCableDynType), INTENT(INOUT) :: model
    REAL(wp), INTENT(IN) :: rho_w, diam(:), cdn(:), cdt(:), waterline_z, current(3)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    REAL(wp), INTENT(IN), OPTIONAL :: gravity

    REAL(wp), ALLOCATABLE :: diam_old(:), cdn_old(:), cdt_old(:), a_old(:)
    REAL(wp) :: rho_old, wl_old, cur_old(3), grav_old, grav_new
    LOGICAL :: had_drag

    ErrStat = CD_HCDYN_OK; ErrMsg = ''
    model%rc_epoch = model%rc_epoch + 1
    ! A load-configuration change invalidates the cached committed force F_n.
    model%fc_valid = .FALSE.
    model%fc_clears = model%fc_clears + 1
    model%tr_valid = .FALSE.
    IF (.NOT. model%initialized) THEN
      ErrStat = CD_HCDYN_BADINPUT; ErrMsg = 'CD_HermiteCable_Dyn_Set_Drag: model not initialised'; RETURN
    END IF
    IF (SIZE(diam) /= model%ne .OR. SIZE(cdn) /= model%ne .OR. SIZE(cdt) /= model%ne) THEN
      ErrStat = CD_HCDYN_BADINPUT
      ErrMsg = 'CD_HermiteCable_Dyn_Set_Drag: diam/cdn/cdt must have length ne'; RETURN
    END IF
    IF (.NOT. CD_Is_Finite(rho_w) .OR. rho_w <= CD_ZERO .OR. .NOT. CD_Is_Finite(waterline_z) .OR. &
        .NOT. CD_All_Finite(current)) THEN
      ErrStat = CD_HCDYN_BADINPUT
      ErrMsg = 'CD_HermiteCable_Dyn_Set_Drag: need rho_w>0, finite waterline/current'; RETURN
    END IF
    IF (.NOT. CD_All_Finite(diam) .OR. ANY(diam <= CD_ZERO) .OR. &
        .NOT. CD_All_Finite(cdn) .OR. ANY(cdn < CD_ZERO) .OR. &
        .NOT. CD_All_Finite(cdt) .OR. ANY(cdt < CD_ZERO)) THEN
      ErrStat = CD_HCDYN_BADINPUT
      ErrMsg = 'CD_HermiteCable_Dyn_Set_Drag: need diam>0, cdn>=0, cdt>=0 (finite)'; RETURN
    END IF
    grav_new = 9.80665_wp
    IF (PRESENT(gravity)) grav_new = gravity
    IF (.NOT. CD_Is_Finite(grav_new) .OR. grav_new <= CD_ZERO) THEN
      ErrStat = CD_HCDYN_BADINPUT
      ErrMsg = 'CD_HermiteCable_Dyn_Set_Drag: gravity must be finite and positive'; RETURN
    END IF
    ! One free surface: once waves are on, every hydro configuration must share the waterline
    ! (Set_Waves enforces this at enable time; this closes the reversed call order).
    IF (model%has_wave .AND. model%has_am) THEN
      IF (ABS(waterline_z - model%am_wl) > CD_ZERO) THEN
        ErrStat = CD_HCDYN_BADINPUT
        ErrMsg = 'CD_HermiteCable_Dyn_Set_Drag: waterline disagrees with the added-mass config while waves are on'
        RETURN
      END IF
    END IF

    ! Snapshot for rollback: Set_Drag is TRANSACTIONAL. The acceleration refresh below can fail
    ! after the parameters are installed (e.g. a finite but overflowing current makes the rest drag
    ! non-finite); the model must then be restored to its previous valid drag state and previous
    ! consistent acceleration -- not left with a partially applied configuration.
    had_drag = model%has_drag
    a_old = model%a
    rho_old = model%rho_w; wl_old = model%waterline_z; cur_old = model%current
    grav_old = model%gravity
    ! Allocate the snapshots unconditionally (zero when there was no prior drag) so every restore
    ! path reads a defined array.
    ALLOCATE (diam_old(model%ne), cdn_old(model%ne), cdt_old(model%ne))
    IF (had_drag) THEN
      diam_old = model%diam; cdn_old = model%cdn; cdt_old = model%cdt
    ELSE
      diam_old = CD_ZERO; cdn_old = CD_ZERO; cdt_old = CD_ZERO
    END IF

    IF (ALLOCATED(model%diam)) DEALLOCATE (model%diam)
    IF (ALLOCATED(model%cdn)) DEALLOCATE (model%cdn)
    IF (ALLOCATED(model%cdt)) DEALLOCATE (model%cdt)
    ALLOCATE (model%diam(model%ne), model%cdn(model%ne), model%cdt(model%ne))
    model%diam = diam; model%cdn = cdn; model%cdt = cdt
    model%rho_w = rho_w; model%waterline_z = waterline_z; model%current = current
    model%gravity = grav_new
    model%has_drag = .TRUE.
    ! the lift scale and the shedding diameter follow the drag's density and diameters
    IF (model%has_viv) CALL viv_drag_terms(model)

    ! Refresh the consistent acceleration now that the load set includes drag: at v = 0 a current
    ! exerts a non-zero rest drag, so the predictor for the first step must see it.
    CALL solve_consistent_acceleration(model, ErrStat, ErrMsg)
    IF (ErrStat /= CD_HCDYN_OK) THEN
      ! Roll back to the pre-call state: previous acceleration, previous drag configuration.
      model%a = a_old
      model%rho_w = rho_old; model%waterline_z = wl_old; model%current = cur_old
      model%gravity = grav_old
      IF (had_drag) THEN
        model%diam = diam_old; model%cdn = cdn_old; model%cdt = cdt_old
      ELSE
        DEALLOCATE (model%diam, model%cdn, model%cdt)
      END IF
      model%has_drag = had_drag
      ! VIV needs drag, so a VIV model had it: back to the restored configuration
      IF (model%has_viv) CALL viv_drag_terms(model)
    END IF
  END SUBROUTINE CD_HermiteCable_Dyn_Set_Drag

  SUBROUTINE CD_HermiteCable_Dyn_Set_Axial_Damping(model, BA, ErrStat, ErrMsg)
    !! Install the resolved per-element axial Kelvin-Voigt coefficients [N s].
    !! The constitutive viscous resultant is N_v = BA*strain_rate, where strain_rate
    !! follows the deformed centreline and material coordinate. An all-zero array
    !! disables the contribution exactly. The setter is transactional and refreshes
    !! the consistent acceleration because callers may replace the damping after the
    !! cable has acquired a non-zero velocity.
    TYPE(CD_HermiteCableDynType), INTENT(INOUT) :: model
    REAL(wp), INTENT(IN) :: BA(:)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg

    REAL(wp), ALLOCATABLE :: old_BA(:), new_BA(:), old_a(:)
    LOGICAL :: old_has
    INTEGER :: es, istat
    CHARACTER(1024) :: em

    ErrStat = CD_HCDYN_OK
    model%rc_epoch = model%rc_epoch + 1
    ! A load-configuration change invalidates the cached committed force F_n.
    model%fc_valid = .FALSE.
    model%fc_clears = model%fc_clears + 1
    model%tr_valid = .FALSE.
    ErrMsg = ''
    IF (.NOT. model%initialized) THEN
      CALL fail('model not initialised'); RETURN
    END IF
    IF (SIZE(BA) /= model%ne) THEN
      CALL fail('BA must have length ne'); RETURN
    END IF
    IF (.NOT. CD_All_Finite(BA) .OR. ANY(BA < CD_ZERO)) THEN
      CALL fail('BA must be finite and non-negative'); RETURN
    END IF

    ALLOCATE (new_BA(model%ne), old_a(model%ndof), STAT=istat)
    IF (istat /= 0) THEN
      CALL fail('workspace allocation failed'); RETURN
    END IF
    new_BA = BA
    old_a = model%a
    old_has = model%has_axial_damping
    CALL MOVE_ALLOC(model%BA, old_BA)
    IF (ANY(new_BA > CD_ZERO)) THEN
      CALL MOVE_ALLOC(new_BA, model%BA)
      model%has_axial_damping = .TRUE.
    ELSE
      model%has_axial_damping = .FALSE.
    END IF

    CALL solve_consistent_acceleration(model, es, em)
    IF (es /= CD_HCDYN_OK) THEN
      IF (ALLOCATED(model%BA)) DEALLOCATE (model%BA)
      CALL MOVE_ALLOC(old_BA, model%BA)
      model%has_axial_damping = old_has
      model%a = old_a
      CALL fail('initial acceleration refresh failed: '//TRIM(em)); RETURN
    END IF

  CONTAINS
    SUBROUTINE fail(msg)
      CHARACTER(*), INTENT(IN) :: msg
      ErrStat = CD_HCDYN_BADINPUT
      ErrMsg = 'CD_HermiteCable_Dyn_Set_Axial_Damping: '//msg
    END SUBROUTINE fail
  END SUBROUTINE CD_HermiteCable_Dyn_Set_Axial_Damping

  SUBROUTINE CD_HermiteCable_Dyn_Set_AddedMass(model, rho_w, diam, can, cat, waterline_z, ErrStat, ErrMsg)
    !! Enable per-element Morison added mass on the (already initialised) dynamic model: the
    !! submerged cable accelerates surrounding fluid, adding rho_w A (Can (I - t t^T) + Cat t t^T)
    !! per unit length to the inertia. The added mass shifts the wet natural frequencies down by
    !! sqrt(m/(m + m_a)) -- essential for the dynamic (fatigue) response of a submerged power cable.
    !! Within each step the added-mass matrix is FROZEN at the beginning-of-step configuration (an
    !! O(dt) approximation consistent with gen-alpha accuracy, exact at any at-rest fixed point), so
    !! the Newton solve keeps a constant mass. Transactional like Set_Drag: a failed refresh rolls
    !! back to the previous valid state. Independent of the drag configuration.
    !!
    !! rho_w       : fluid mass density (kg/m^3), > 0.
    !! diam(ne)    : per-element hydrodynamic diameter (m), > 0.
    !! can, cat(ne): per-element normal / tangential added-mass coefficients, >= 0.
    !! waterline_z : still-water level; a Gauss point above it carries no added mass.
    TYPE(CD_HermiteCableDynType), INTENT(INOUT) :: model
    REAL(wp), INTENT(IN) :: rho_w, diam(:), can(:), cat(:), waterline_z
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg

    REAL(wp), ALLOCATABLE :: d_old(:), can_old(:), cat_old(:), a_old(:)
    REAL(wp) :: rho_old, wl_old
    LOGICAL :: had_am

    ErrStat = CD_HCDYN_OK; ErrMsg = ''
    model%rc_epoch = model%rc_epoch + 1
    ! A load-configuration change invalidates the cached committed force F_n.
    model%fc_valid = .FALSE.
    model%fc_clears = model%fc_clears + 1
    model%tr_valid = .FALSE.
    IF (.NOT. model%initialized) THEN
      ErrStat = CD_HCDYN_BADINPUT; ErrMsg = 'CD_HermiteCable_Dyn_Set_AddedMass: model not initialised'; RETURN
    END IF
    IF (SIZE(diam) /= model%ne .OR. SIZE(can) /= model%ne .OR. SIZE(cat) /= model%ne) THEN
      ErrStat = CD_HCDYN_BADINPUT
      ErrMsg = 'CD_HermiteCable_Dyn_Set_AddedMass: diam/can/cat must have length ne'; RETURN
    END IF
    IF (.NOT. CD_Is_Finite(rho_w) .OR. rho_w <= CD_ZERO .OR. .NOT. CD_Is_Finite(waterline_z)) THEN
      ErrStat = CD_HCDYN_BADINPUT
      ErrMsg = 'CD_HermiteCable_Dyn_Set_AddedMass: need rho_w>0 and a finite waterline'; RETURN
    END IF
    IF (.NOT. CD_All_Finite(diam) .OR. ANY(diam <= CD_ZERO) .OR. &
        .NOT. CD_All_Finite(can) .OR. ANY(can < CD_ZERO) .OR. &
        .NOT. CD_All_Finite(cat) .OR. ANY(cat < CD_ZERO)) THEN
      ErrStat = CD_HCDYN_BADINPUT
      ErrMsg = 'CD_HermiteCable_Dyn_Set_AddedMass: need diam>0, can>=0, cat>=0 (finite)'; RETURN
    END IF
    ! One free surface: once waves are on, every hydro configuration must share the waterline
    ! (Set_Waves enforces this at enable time; this closes the reversed call order).
    IF (model%has_wave .AND. model%has_drag) THEN
      IF (ABS(waterline_z - model%waterline_z) > CD_ZERO) THEN
        ErrStat = CD_HCDYN_BADINPUT
        ErrMsg = 'CD_HermiteCable_Dyn_Set_AddedMass: waterline disagrees with the drag config while waves are on'
        RETURN
      END IF
    END IF

    ! Snapshot for rollback (transactional; see Set_Drag).
    had_am = model%has_am
    a_old = model%a
    rho_old = model%am_rho; wl_old = model%am_wl
    ALLOCATE (d_old(model%ne), can_old(model%ne), cat_old(model%ne))
    IF (had_am) THEN
      d_old = model%am_diam; can_old = model%am_can; cat_old = model%am_cat
    ELSE
      d_old = CD_ZERO; can_old = CD_ZERO; cat_old = CD_ZERO
    END IF

    IF (ALLOCATED(model%am_diam)) DEALLOCATE (model%am_diam)
    IF (ALLOCATED(model%am_can)) DEALLOCATE (model%am_can)
    IF (ALLOCATED(model%am_cat)) DEALLOCATE (model%am_cat)
    ALLOCATE (model%am_diam(model%ne), model%am_can(model%ne), model%am_cat(model%ne))
    model%am_diam = diam; model%am_can = can; model%am_cat = cat
    model%am_rho = rho_w; model%am_wl = waterline_z
    model%has_am = .TRUE.

    ! Refresh the consistent acceleration with the total (structural + added) mass.
    CALL solve_consistent_acceleration(model, ErrStat, ErrMsg)
    IF (ErrStat /= CD_HCDYN_OK) THEN
      model%a = a_old
      model%am_rho = rho_old; model%am_wl = wl_old
      IF (had_am) THEN
        model%am_diam = d_old; model%am_can = can_old; model%am_cat = cat_old
      ELSE
        DEALLOCATE (model%am_diam, model%am_can, model%am_cat)
      END IF
      model%has_am = had_am
    END IF
  END SUBROUTINE CD_HermiteCable_Dyn_Set_AddedMass

  SUBROUTINE CD_HermiteCable_Dyn_Set_Waves(model, height, period, direction_deg, depth, gravity, &
                                           ErrStat, ErrMsg)
    !! Enable a regular (Airy) wave field on the (already initialised) dynamic model. The wave
    !! VELOCITY feeds the drag's relative-velocity fluid field (requires the drag configuration);
    !! the wave ACCELERATION drives the Froude-Krylov + fluid-inertia load per unit length
    !!   f = rho A [ (1 + Can) a_n + (1 + Cat) a_t ]
    !! with the added-mass configuration's rho/diameter/coefficients (requires it). At least one of
    !! the two hydro configurations must already be set, else the waves would silently do nothing.
    !! When both are set their waterline data must agree (one free surface). Kinematics use Wheeler
    !! stretching and are zero above the instantaneous surface. Transactional: a failed refresh
    !! rolls back. Waves make the wave loads time-dependent, so an at-rest state is NOT a fixed
    !! point once waves are on -- the model's simulation time starts at Init (t = 0) and advances
    !! with each step.
    !!
    !! height        : wave height H (m), > 0 (amplitude H/2).
    !! period        : wave period T (s), > 0.
    !! direction_deg : propagation direction in the x-y plane (deg from +x).
    !! depth         : water depth d (m), > 0 (seabed at waterline - d).
    !! gravity       : gravitational acceleration (m/s^2), > 0.
    TYPE(CD_HermiteCableDynType), INTENT(INOUT) :: model
    REAL(wp), INTENT(IN) :: height, period, direction_deg, depth, gravity
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg

    REAL(wp), PARAMETER :: PI_L = 3.14159265358979323846_wp
    REAL(wp), ALLOCATABLE :: a_old(:)
    REAL(wp) :: h_old, om_old, k_old, dep_old, dir_old, omega, k
    LOGICAL :: had_wave
    INTEGER :: es
    CHARACTER(1024) :: em2

    ErrStat = CD_HCDYN_OK; ErrMsg = ''
    model%rc_epoch = model%rc_epoch + 1
    ! A load-configuration change invalidates the cached committed force F_n.
    model%fc_valid = .FALSE.
    model%fc_clears = model%fc_clears + 1
    model%tr_valid = .FALSE.
    IF (.NOT. model%initialized) THEN
      ErrStat = CD_HCDYN_BADINPUT; ErrMsg = 'CD_HermiteCable_Dyn_Set_Waves: model not initialised'; RETURN
    END IF
    IF (model%has_viv) THEN
      ErrStat = CD_HCDYN_BADINPUT
      ErrMsg = 'CD_HermiteCable_Dyn_Set_Waves: VIV is configured; its phase follows the current and a held host '// &
               'fluid field, so waves reach a VIV cable as a held field'; RETURN
    END IF
    IF (model%has_held_field) THEN
      ErrStat = CD_HCDYN_BADINPUT
      ErrMsg = 'CD_HermiteCable_Dyn_Set_Waves: a held host fluid field is configured; an internal '// &
               'wave family on top of it would double-count the wave kinematics'; RETURN
    END IF
    IF (model%has_attach) THEN
      ErrStat = CD_HCDYN_BADINPUT
      ErrMsg = 'CD_HermiteCable_Dyn_Set_Waves: attachments take the held fluid field, not internal waves'
      RETURN
    END IF
    IF (.NOT. (model%has_drag .OR. model%has_am)) THEN
      ErrStat = CD_HCDYN_BADINPUT
      ErrMsg = 'CD_HermiteCable_Dyn_Set_Waves: needs the drag and/or added-mass config first '// &
               '(waves would otherwise do nothing)'; RETURN
    END IF
    IF (model%has_drag .AND. model%has_am) THEN
      IF (ABS(model%waterline_z - model%am_wl) > CD_ZERO) THEN
        ErrStat = CD_HCDYN_BADINPUT
        ErrMsg = 'CD_HermiteCable_Dyn_Set_Waves: drag and added-mass waterlines disagree'; RETURN
      END IF
    END IF
    IF (.NOT. CD_Is_Finite(height) .OR. height <= CD_ZERO .OR. &
        .NOT. CD_Is_Finite(period) .OR. period <= CD_ZERO .OR. &
        .NOT. CD_Is_Finite(depth) .OR. depth <= CD_ZERO .OR. &
        .NOT. CD_Is_Finite(direction_deg) .OR. .NOT. CD_Is_Finite(gravity) .OR. gravity <= CD_ZERO) THEN
      ErrStat = CD_HCDYN_BADINPUT
      ErrMsg = 'CD_HermiteCable_Dyn_Set_Waves: need height>0, period>0, depth>0, gravity>0 (finite)'; RETURN
    END IF
    omega = 2.0_wp*PI_L/period
    CALL CD_Solve_Dispersion_Wavenumber(omega, depth, gravity, k, es, em2)
    IF (es /= CD_HYDRO_OK) THEN
      ErrStat = CD_HCDYN_BADINPUT; ErrMsg = 'CD_HermiteCable_Dyn_Set_Waves: '//TRIM(em2); RETURN
    END IF

    ! Snapshot for rollback (transactional; see Set_Drag). A previously configured
    ! COMPONENT field is displaced by this regular field (mutual exclusivity), so its
    ! table is part of the snapshot too.
    had_wave = model%has_wave
    a_old = model%a
    h_old = model%wv_h; om_old = model%wv_om; k_old = model%wv_k
    dep_old = model%wv_depth; dir_old = model%wv_dir
    BLOCK
      INTEGER :: nc_old
      REAL(wp), ALLOCATABLE :: ampc_old(:), omc_old(:), kc_old(:), phc_old(:)
      nc_old = model%wv_ncomp
      IF (nc_old > 0) THEN
        ampc_old = model%wv_ampc; omc_old = model%wv_omc
        kc_old = model%wv_kc; phc_old = model%wv_phc
      ELSE
        ALLOCATE (ampc_old(0), omc_old(0), kc_old(0), phc_old(0))
      END IF

      model%wv_h = height; model%wv_om = omega; model%wv_k = k
      model%wv_depth = depth; model%wv_dir = direction_deg
      model%wv_ncomp = 0
      model%has_wave = .TRUE.

      ! Refresh the consistent acceleration under the wave loads at the current simulation time.
      CALL solve_consistent_acceleration(model, ErrStat, ErrMsg)
      IF (ErrStat /= CD_HCDYN_OK) THEN
        model%a = a_old
        model%wv_h = h_old; model%wv_om = om_old; model%wv_k = k_old
        model%wv_depth = dep_old; model%wv_dir = dir_old
        model%wv_ncomp = nc_old
        IF (nc_old > 0) THEN
          model%wv_ampc = ampc_old; model%wv_omc = omc_old
          model%wv_kc = kc_old; model%wv_phc = phc_old
        END IF
        model%has_wave = had_wave
        CALL refresh_wave_table(model)
      END IF
    END BLOCK
  END SUBROUTINE CD_HermiteCable_Dyn_Set_Waves

  SUBROUTINE CD_HermiteCable_Dyn_Set_Irregular_Waves(model, amplitude, period, phase_deg, &
                                                     direction_deg, depth, gravity, ErrStat, ErrMsg)
    !! Enable a COMPONENT (irregular) wave field on the (already initialised) dynamic model: a
    !! caller-supplied long-crested linear component table -- amplitude a_i, period T_i, phase
    !! phi_i per component, one shared direction -- summed by CD_Component_Wave_Kinematics with
    !! total-eta Wheeler stretching (the OrcaFlex irregular-wave convention). The total wave
    !! VELOCITY feeds the drag's relative-velocity fluid field and the total wave ACCELERATION
    !! drives the Froude-Krylov + fluid-inertia load, exactly as the regular field above; the
    !! same hydro-configuration prerequisites and the one-free-surface rule apply. A component
    !! field displaces a previously configured regular field and vice versa (mutually
    !! exclusive). Transactional: a failed refresh rolls back.
    !!
    !! This is the deterministic component-matched irregular-sea path: an external tool
    !! synthesizes ONE spectrum discretization (e.g. JONSWAP) and feeds the SAME table to
    !! CableDyn and to the reference solver, so an irregular-sea parity case carries no
    !! stochastic seed ambiguity.
    !!
    !! amplitude(:)  : component amplitudes a_i (m), >= 0 finite, at least one > 0.
    !! period(:)     : component periods T_i (s), > 0 finite (same length).
    !! phase_deg(:)  : component phases phi_i (deg), finite (same length);
    !!                 eta_i = a_i cos(k_i x - omega_i t + phi_i).
    !! direction_deg : shared propagation direction in the x-y plane (deg from +x).
    !! depth         : water depth d (m), > 0 (seabed at waterline - d).
    !! gravity       : gravitational acceleration (m/s^2), > 0.
    TYPE(CD_HermiteCableDynType), INTENT(INOUT) :: model
    REAL(wp), INTENT(IN) :: amplitude(:), period(:), phase_deg(:)
    REAL(wp), INTENT(IN) :: direction_deg, depth, gravity
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg

    REAL(wp), PARAMETER :: PI_L = 3.14159265358979323846_wp
    REAL(wp), ALLOCATABLE :: a_old(:), ampc_old(:), omc_old(:), kc_old(:), phc_old(:)
    REAL(wp), ALLOCATABLE :: omc(:), kc(:), phc(:)
    REAL(wp) :: h_old, om_old, k_old, dep_old, dir_old
    LOGICAL :: had_wave
    INTEGER :: i, n, nc_old, es
    CHARACTER(1024) :: em2

    ErrStat = CD_HCDYN_OK; ErrMsg = ''
    model%rc_epoch = model%rc_epoch + 1
    ! A load-configuration change invalidates the cached committed force F_n.
    model%fc_valid = .FALSE.
    model%fc_clears = model%fc_clears + 1
    model%tr_valid = .FALSE.
    IF (.NOT. model%initialized) THEN
      ErrStat = CD_HCDYN_BADINPUT
      ErrMsg = 'CD_HermiteCable_Dyn_Set_Irregular_Waves: model not initialised'; RETURN
    END IF
    IF (model%has_viv) THEN
      ErrStat = CD_HCDYN_BADINPUT
      ErrMsg = 'CD_HermiteCable_Dyn_Set_Irregular_Waves: VIV is configured; its phase follows the current and a held host '// &
               'fluid field, so waves reach a VIV cable as a held field'; RETURN
    END IF
    IF (model%has_held_field) THEN
      ErrStat = CD_HCDYN_BADINPUT
      ErrMsg = 'CD_HermiteCable_Dyn_Set_Irregular_Waves: a held host fluid field is configured; '// &
               'an internal wave family on top of it would double-count the wave kinematics'; RETURN
    END IF
    IF (model%has_attach) THEN
      ErrStat = CD_HCDYN_BADINPUT
      ErrMsg = 'CD_HermiteCable_Dyn_Set_Irregular_Waves: attachments take the held fluid field, '// &
               'not internal waves'
      RETURN
    END IF
    IF (.NOT. (model%has_drag .OR. model%has_am)) THEN
      ErrStat = CD_HCDYN_BADINPUT
      ErrMsg = 'CD_HermiteCable_Dyn_Set_Irregular_Waves: needs the drag and/or added-mass '// &
               'config first (waves would otherwise do nothing)'; RETURN
    END IF
    IF (model%has_drag .AND. model%has_am) THEN
      IF (ABS(model%waterline_z - model%am_wl) > CD_ZERO) THEN
        ErrStat = CD_HCDYN_BADINPUT
        ErrMsg = 'CD_HermiteCable_Dyn_Set_Irregular_Waves: drag and added-mass waterlines disagree'
        RETURN
      END IF
    END IF
    n = SIZE(amplitude)
    IF (n < 1 .OR. SIZE(period) /= n .OR. SIZE(phase_deg) /= n) THEN
      ErrStat = CD_HCDYN_BADINPUT
      ErrMsg = 'CD_HermiteCable_Dyn_Set_Irregular_Waves: amplitude/period/phase_deg must share '// &
               'one length >= 1'; RETURN
    END IF
    IF (.NOT. (CD_All_Finite(amplitude) .AND. ALL(amplitude >= CD_ZERO) .AND. &
               ANY(amplitude > CD_ZERO) .AND. &
               CD_All_Finite(period) .AND. ALL(period > CD_ZERO) .AND. &
               CD_All_Finite(phase_deg))) THEN
      ErrStat = CD_HCDYN_BADINPUT
      ErrMsg = 'CD_HermiteCable_Dyn_Set_Irregular_Waves: need finite amplitudes >= 0 (one > 0), '// &
               'periods > 0, finite phases'; RETURN
    END IF
    IF (.NOT. CD_Is_Finite(depth) .OR. depth <= CD_ZERO .OR. &
        .NOT. CD_Is_Finite(direction_deg) .OR. .NOT. CD_Is_Finite(gravity) .OR. gravity <= CD_ZERO) THEN
      ErrStat = CD_HCDYN_BADINPUT
      ErrMsg = 'CD_HermiteCable_Dyn_Set_Irregular_Waves: need depth>0, gravity>0, finite direction'
      RETURN
    END IF

    ALLOCATE (omc(n), kc(n), phc(n))
    DO i = 1, n
      omc(i) = 2.0_wp*PI_L/period(i)
      CALL CD_Solve_Dispersion_Wavenumber(omc(i), depth, gravity, kc(i), es, em2)
      IF (es /= CD_HYDRO_OK) THEN
        ErrStat = CD_HCDYN_BADINPUT
        ErrMsg = 'CD_HermiteCable_Dyn_Set_Irregular_Waves: '//TRIM(em2); RETURN
      END IF
      phc(i) = phase_deg(i)*PI_L/180.0_wp
    END DO

    ! Snapshot for rollback (transactional; see Set_Drag). Displaces any regular field.
    had_wave = model%has_wave
    a_old = model%a
    h_old = model%wv_h; om_old = model%wv_om; k_old = model%wv_k
    dep_old = model%wv_depth; dir_old = model%wv_dir
    nc_old = model%wv_ncomp
    IF (nc_old > 0) THEN
      ampc_old = model%wv_ampc; omc_old = model%wv_omc
      kc_old = model%wv_kc; phc_old = model%wv_phc
    ELSE
      ALLOCATE (ampc_old(0), omc_old(0), kc_old(0), phc_old(0))
    END IF

    model%wv_ampc = amplitude; model%wv_omc = omc; model%wv_kc = kc; model%wv_phc = phc
    model%wv_ncomp = n
    model%wv_h = CD_ZERO; model%wv_om = CD_ZERO; model%wv_k = CD_ZERO
    model%wv_depth = depth; model%wv_dir = direction_deg
    model%has_wave = .TRUE.
    CALL refresh_wave_table(model)

    ! Refresh the consistent acceleration under the wave loads at the current simulation time.
    CALL solve_consistent_acceleration(model, ErrStat, ErrMsg)
    IF (ErrStat /= CD_HCDYN_OK) THEN
      model%a = a_old
      model%wv_h = h_old; model%wv_om = om_old; model%wv_k = k_old
      model%wv_depth = dep_old; model%wv_dir = dir_old
      model%wv_ncomp = nc_old
      IF (nc_old > 0) THEN
        model%wv_ampc = ampc_old; model%wv_omc = omc_old
        model%wv_kc = kc_old; model%wv_phc = phc_old
      END IF
      model%has_wave = had_wave
      CALL refresh_wave_table(model)
    END IF
  END SUBROUTINE CD_HermiteCable_Dyn_Set_Irregular_Waves

  SUBROUTINE refresh_wave_table(model)
    !! exp(-2 k_i depth) of the component wave table, once per table instead of per evaluation
    !! (the same expression CD_Component_Wave_Kinematics would evaluate).
    TYPE(CD_HermiteCableDynType), INTENT(INOUT) :: model
    INTEGER :: i
    IF (model%wv_ncomp < 1) RETURN
    IF (ALLOCATED(model%wv_e2kd)) THEN
      IF (SIZE(model%wv_e2kd) /= model%wv_ncomp) DEALLOCATE (model%wv_e2kd)
    END IF
    IF (.NOT. ALLOCATED(model%wv_e2kd)) ALLOCATE (model%wv_e2kd(model%wv_ncomp))
    DO i = 1, model%wv_ncomp
      model%wv_e2kd(i) = EXP(-2.0_wp*(model%wv_kc(i)*model%wv_depth))
    END DO
  END SUBROUTINE refresh_wave_table

  SUBROUTINE CD_HermiteCable_Dyn_Set_Held_Fluid(model, fluid_velocity, fluid_acceleration, waterline_z, &
                                                ErrStat, ErrMsg)
    !! Prescribe the HELD ambient-fluid field: per-node fluid velocity, fluid
    !! acceleration, and local free-surface elevation, frozen over the coming step(s)
    !! until the next call (the external host's sampling cadence -- a per-step
    !! zero-order hold). The velocity adds to the drag's relative-velocity field (on
    !! top of any constant current from the drag config); the acceleration drives the
    !! Froude-Krylov + fluid-inertia load with the added-mass config's coefficients;
    !! the elevation drives the wetting of both. Consumed per element as the two end
    !! nodes' average -- the same spatial granularity the host sampled at. Requires the
    !! drag configuration; mutually exclusive with the internal wave families (a deck
    !! wave model AND a host field would double-count). The first call establishes a
    !! consistent initial acceleration. Later calls prescribe the load for the next
    !! interval without rewriting the committed generalised-alpha acceleration, which
    !! belongs to the preceding time station.
    TYPE(CD_HermiteCableDynType), INTENT(INOUT) :: model
    REAL(wp), INTENT(IN) :: fluid_velocity(:, :), fluid_acceleration(:, :), waterline_z(:)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    INTEGER :: istat, es
    LOGICAL :: had_field
    CHARACTER(1024) :: em
    ErrStat = CD_HCDYN_OK; ErrMsg = ''
    model%rc_epoch = model%rc_epoch + 1
    ! A load-configuration change invalidates the cached committed force F_n. The carried step
    ! factor stays usable (a per-step field update only perturbs the drag and inertia tangent;
    ! the first field's consistent-acceleration solve drops it).
    model%fc_valid = .FALSE.
    model%fc_clears = model%fc_clears + 1
    IF (.NOT. model%initialized) THEN
      ErrStat = CD_HCDYN_BADINPUT
      ErrMsg = 'CD_HermiteCable_Dyn_Set_Held_Fluid: model not initialised'; RETURN
    END IF
    IF (.NOT. model%has_drag) THEN
      ErrStat = CD_HCDYN_BADINPUT
      ErrMsg = 'CD_HermiteCable_Dyn_Set_Held_Fluid: requires the Morison drag configuration '// &
               '(CD_HermiteCable_Dyn_Set_Drag) -- the held velocity feeds its fluid field'; RETURN
    END IF
    IF (model%has_wave) THEN
      ErrStat = CD_HCDYN_BADINPUT
      ErrMsg = 'CD_HermiteCable_Dyn_Set_Held_Fluid: an internal wave family is configured; a held '// &
               'host field on top of it would double-count the wave kinematics'; RETURN
    END IF
    IF (SIZE(fluid_velocity, 1) /= 3 .OR. SIZE(fluid_velocity, 2) /= model%nn .OR. &
        SIZE(fluid_acceleration, 1) /= 3 .OR. SIZE(fluid_acceleration, 2) /= model%nn .OR. &
        SIZE(waterline_z) /= model%nn) THEN
      ErrStat = CD_HCDYN_BADINPUT
      ErrMsg = 'CD_HermiteCable_Dyn_Set_Held_Fluid: fields must be shaped (3, nn) / (nn)'; RETURN
    END IF
    IF (.NOT. (CD_All_Finite(fluid_velocity) .AND. CD_All_Finite(fluid_acceleration) .AND. &
               CD_All_Finite(waterline_z))) THEN
      ErrStat = CD_HCDYN_BADINPUT
      ErrMsg = 'CD_HermiteCable_Dyn_Set_Held_Fluid: fields must be finite'; RETURN
    END IF
    ! Transactional update. The FIRST held field completes dynamic initialisation and
    ! therefore refreshes a0. A later field is the load over the NEXT interval; replacing
    ! a_n with the acceleration implied by that future load corrupts the Newmark history
    ! and can pump high-frequency energy into a cable driven by SeaState. Validate later
    ! fields at the committed q_n/v_n, but preserve the committed a_n exactly.
    had_field = model%has_held_field
    IF (had_field .AND. .NOT. (ALLOCATED(model%hf_u) .AND. ALLOCATED(model%hf_ud) .AND. &
                               ALLOCATED(model%hf_wl))) THEN
      ErrStat = CD_HCDYN_BADINPUT
      ErrMsg = 'CD_HermiteCable_Dyn_Set_Held_Fluid: committed field storage is incomplete'; RETURN
    END IF
    IF (.NOT. had_field .AND. (ALLOCATED(model%hf_u) .OR. ALLOCATED(model%hf_ud) .OR. &
                               ALLOCATED(model%hf_wl))) THEN
      ErrStat = CD_HCDYN_BADINPUT
      ErrMsg = 'CD_HermiteCable_Dyn_Set_Held_Fluid: uncommitted field storage is present'; RETURN
    END IF
    IF (had_field) THEN
      IF (SIZE(model%hf_u, 1) /= 3 .OR. SIZE(model%hf_u, 2) /= model%nn .OR. &
          SIZE(model%hf_ud, 1) /= 3 .OR. SIZE(model%hf_ud, 2) /= model%nn .OR. &
          SIZE(model%hf_wl) /= model%nn) THEN
        ErrStat = CD_HCDYN_BADINPUT
        ErrMsg = 'CD_HermiteCable_Dyn_Set_Held_Fluid: committed field storage has invalid dimensions'; RETURN
      END IF
    END IF
    istat = 0
    IF (ALLOCATED(model%ws_hf_a_old)) THEN
      IF (SIZE(model%ws_hf_a_old) /= SIZE(model%a) .OR. SIZE(model%ws_hf_wl_old) /= model%nn) &
        DEALLOCATE (model%ws_hf_a_old, model%ws_hf_u_old, model%ws_hf_ud_old, model%ws_hf_wl_old)
    END IF
    IF (.NOT. ALLOCATED(model%ws_hf_a_old)) &
      ALLOCATE (model%ws_hf_a_old(SIZE(model%a)), model%ws_hf_u_old(3, model%nn), &
                model%ws_hf_ud_old(3, model%nn), model%ws_hf_wl_old(model%nn), STAT=istat)
    IF (istat /= 0) THEN
      ErrStat = CD_HCDYN_BADINPUT
      ErrMsg = 'CD_HermiteCable_Dyn_Set_Held_Fluid: rollback storage allocation failed'; RETURN
    END IF
    model%ws_hf_a_old = model%a
    IF (had_field) THEN
      model%ws_hf_u_old = model%hf_u; model%ws_hf_ud_old = model%hf_ud; model%ws_hf_wl_old = model%hf_wl
    END IF
    IF (.NOT. ALLOCATED(model%hf_u)) THEN
      ALLOCATE (model%hf_u(3, model%nn), model%hf_ud(3, model%nn), model%hf_wl(model%nn), STAT=istat)
      IF (istat /= 0) THEN
        ErrStat = CD_HCDYN_BADINPUT
        ErrMsg = 'CD_HermiteCable_Dyn_Set_Held_Fluid: field allocation failed'; RETURN
      END IF
    END IF
    model%hf_u = fluid_velocity
    model%hf_ud = fluid_acceleration
    model%hf_wl = waterline_z
    model%has_held_field = .TRUE.
    IF (.NOT. had_field .AND. .NOT. model%a_restored) THEN
      CALL solve_committed_acceleration(model, ErrStat, ErrMsg)
    ELSE
      CALL assemble_committed_force(model, es, em)
      ErrStat = es
      ErrMsg = em
      IF (es == CD_HCDYN_OK .AND. model%force_blend) THEN
        ! This validation is the next step's committed force F_n = R(q_n, v_n, t_n) under the
        ! new field (at the committed lengths), the evaluation the step would otherwise repeat:
        ! cache it, keyed as usual.
        model%fc_R = model%ws_R
        model%fc_q = model%q
        model%fc_v = model%v
        model%fc_t = model%t
        model%fc_d0 = model%endconn_d0
        model%fc_valid = .TRUE.
      END IF
    END IF
    IF (ErrStat == CD_HCDYN_OK) model%a_restored = .FALSE.
    IF (ErrStat /= CD_HCDYN_OK) THEN
      model%a = model%ws_hf_a_old
      IF (had_field) THEN
        model%hf_u = model%ws_hf_u_old; model%hf_ud = model%ws_hf_ud_old; model%hf_wl = model%ws_hf_wl_old
        model%has_held_field = .TRUE.
      ELSE
        IF (ALLOCATED(model%hf_u)) DEALLOCATE (model%hf_u, model%hf_ud, model%hf_wl)
        model%has_held_field = .FALSE.
      END IF
      ErrMsg = 'CD_HermiteCable_Dyn_Set_Held_Fluid: '//TRIM(ErrMsg)
    END IF
  END SUBROUTINE CD_HermiteCable_Dyn_Set_Held_Fluid

  SUBROUTINE CD_HermiteCable_Dyn_Step(model, dt, max_iter, tol, ErrStat, ErrMsg, iters_out, res_out, &
                                      pres_dofs, pres_q, pres_v, pres_a, residual_history, history_count, &
                                      endconn_direction, endconn_direction_rate, endconn_direction_acceleration, &
                                      tensile_failed)
    !! Advance the state one generalised-alpha step of size dt. Newton-iterates the intermediate
    !! residual to a dimensionless relative tolerance, then commits q_{n+1}, v_{n+1}, a_{n+1}.
    !!
    !! Optional PRESCRIBED MOTION: pres_dofs(:) lists global DOFs (which MUST be in the model's
    !! fixed_dofs set) whose kinematics at t_{n+1} are prescribed to pres_q/pres_v/pres_a(:) --
    !! e.g. a moving fairlead/hang-off heave driving a lazy-wave cable. These DOFs are held at
    !! pres_q during the Newton solve and their prescribed q/v/a enter the free-DOF residual
    !! through the mass and stiffness coupling; all four arrays must be supplied together.
    !!
    !! CONDENSED TORSION (CD_HermiteCable_Dyn_Set_Torsion): the end frames and Phi move to the
    !! target of CD_HermiteCable_Dyn_Set_Torsion_Drive (consumed by this call; held without one).
    !! The torsion is quasi-static (no torsional inertia): it adds -M_t dTheta/dq to the residual,
    !! -M_t d2Theta/dq2 to the tangent and the rank-one (1 - alpha_f) g g^T / C, solved by
    !! Sherman-Morrison on the band factor with g frozen with the factor (so a reused factor stays
    !! consistent). Theta is unwrapped against the committed value and may change by at most pi/2
    !! in a step (a larger change fails the evaluation, and the line search or the recovering step
    !! cuts it). It needs the force-blended generalised-alpha.
    !!
    !! NODAL TWIST (the torsion carries irn; see the type note): the twist angles join the step
    !! with the same Newmark scheme and are solved with the cable in one band of [r, m, phi] per
    !! node; an end frame may turn by at most pi/2 about the line in a step.
    TYPE(CD_HermiteCableDynType), INTENT(INOUT), TARGET :: model
    REAL(wp), INTENT(IN) :: dt, tol
    INTEGER, INTENT(IN) :: max_iter
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    INTEGER, INTENT(OUT), OPTIONAL :: iters_out
    REAL(wp), INTENT(OUT), OPTIONAL :: res_out
    INTEGER, INTENT(IN), OPTIONAL :: pres_dofs(:)
    REAL(wp), INTENT(IN), OPTIONAL :: pres_q(:), pres_v(:), pres_a(:)
    REAL(wp), INTENT(OUT), OPTIONAL :: residual_history(:)
    INTEGER, INTENT(OUT), OPTIONAL :: history_count
    REAL(wp), INTENT(IN), OPTIONAL :: endconn_direction(3, 2)
    REAL(wp), INTENT(IN), OPTIONAL :: endconn_direction_rate(3, 2), endconn_direction_acceleration(3, 2)
    LOGICAL, INTENT(OUT), OPTIONAL :: tensile_failed
    INTEGER :: iend
    REAL(wp) :: dn, dvec(3), nvec(3)

    model%tors_use_step = .FALSE.
    IF (model%torsion%active) THEN
      IF (.NOT. model%force_blend) THEN
        IF (PRESENT(iters_out)) iters_out = 0
        IF (PRESENT(res_out)) res_out = CD_ZERO
        IF (PRESENT(history_count)) history_count = 0
        IF (PRESENT(residual_history)) residual_history = CD_ZERO
        IF (PRESENT(tensile_failed)) tensile_failed = .FALSE.
        model%tors_drive_set = .FALSE.
        ErrStat = CD_HCDYN_BADINPUT
        ErrMsg = 'CD_HermiteCable_Dyn_Step: torsion needs the force-blended generalised-alpha (alpha_force_blend)'
        RETURN
      END IF
      IF (model%tors_drive_set) THEN
        model%tors_step_ends = model%tors_drive_ends
        model%tors_step_phi = model%tors_drive_phi
      ELSE
        model%tors_step_ends = model%torsion%ends
        model%tors_step_phi = model%torsion%phi
      END IF
      model%tors_drive_set = .FALSE.
      ! A rigid end's director is its connection direction: take the step's exactly and keep the
      ! reference normal perpendicular to it (the smallest correction).
      IF (PRESENT(endconn_direction)) THEN
        DO iend = 1, 2
          IF (model%endconn_mode(iend) /= CD_ENDCONN_RIGID) CYCLE
          dn = NORM2(endconn_direction(:, iend))
          IF (.NOT. (dn > CD_ZERO) .OR. .NOT. CD_Is_Finite(dn)) CYCLE
          dvec = endconn_direction(:, iend)/dn
          nvec = model%tors_step_ends(:, 2*iend)
          nvec = nvec - DOT_PRODUCT(nvec, dvec)*dvec
          dn = NORM2(nvec)
          IF (.NOT. (dn > 1.0e-6_wp)) CYCLE
          model%tors_step_ends(:, 2*iend - 1) = dvec
          model%tors_step_ends(:, 2*iend) = nvec/dn
        END DO
      END IF
    END IF
    CALL dyn_step_core(model, dt, max_iter, tol, ErrStat, ErrMsg, iters_out, res_out, pres_dofs, pres_q, pres_v, &
                       pres_a, residual_history, history_count, endconn_direction, endconn_direction_rate, &
                       endconn_direction_acceleration, tensile_failed)
    model%tors_use_step = .FALSE.
    ! every evaluation outside a step takes the committed VIV phase
    IF (model%has_viv) model%viv_phi_eval = model%viv_phi
  END SUBROUTINE CD_HermiteCable_Dyn_Step

  SUBROUTINE CD_HermiteCable_Dyn_Set_Torsion_Drive(model, ends, phi, ErrStat, ErrMsg)
    !! Target end frames (columns d_1, n_1, d_2, n_2 in the solve frame, orthonormal per end) and
    !! imposed twist Phi [rad, unwrapped] of the condensed torsion at the end of the next step
    !! (CD_HermiteCable_Dyn_Step or _Step_Recovering, which interpolates them over its substeps).
    !! A turning parent turns its end frame; an imposed roll history changes Phi. The next step
    !! consumes the target; without one the frames and Phi are held.
    TYPE(CD_HermiteCableDynType), INTENT(INOUT) :: model
    REAL(wp), INTENT(IN) :: ends(3, 4), phi
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    INTEGER :: k
    ErrStat = CD_HCDYN_BADINPUT
    IF (.NOT. model%initialized .OR. .NOT. model%torsion%active) THEN
      ErrMsg = 'CD_HermiteCable_Dyn_Set_Torsion_Drive: the model has no torsion'
      RETURN
    END IF
    IF (.NOT. (CD_All_Finite(RESHAPE(ends, [12])) .AND. CD_Is_Finite(phi))) THEN
      ErrMsg = 'CD_HermiteCable_Dyn_Set_Torsion_Drive: non-finite end frame or imposed twist'
      RETURN
    END IF
    DO k = 1, 3, 2
      IF (ABS(NORM2(ends(:, k)) - CD_ONE) > 1.0e-8_wp .OR. ABS(NORM2(ends(:, k + 1)) - CD_ONE) > 1.0e-8_wp .OR. &
          ABS(DOT_PRODUCT(ends(:, k), ends(:, k + 1))) > 1.0e-8_wp) THEN
        ErrMsg = 'CD_HermiteCable_Dyn_Set_Torsion_Drive: each end director and reference normal must be orthonormal'
        RETURN
      END IF
    END DO
    model%tors_drive_ends = ends
    model%tors_drive_phi = phi
    model%tors_drive_set = .TRUE.
    ErrStat = CD_HCDYN_OK
    ErrMsg = ''
  END SUBROUTINE CD_HermiteCable_Dyn_Set_Torsion_Drive

  SUBROUTINE CD_HermiteCable_Dyn_Set_Torsion_Frames(model, ends, ErrStat, ErrMsg, q_check)
    !! Move the COMMITTED torsion end frames without a step (a host writing its boundary between
    !! steps): Theta is re-evaluated at the committed state with the new frames, unwrapped
    !! against its value (at most pi/2 away), and the torque follows. Fails closed, unchanged.
    !! With q_check, only check that the frames would be accepted at the configuration q_check
    !! (the state a host is about to write) and change nothing but scratch.
    TYPE(CD_HermiteCableDynType), INTENT(INOUT) :: model
    REAL(wp), INTENT(IN) :: ends(3, 4)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    REAL(wp), INTENT(IN), OPTIONAL :: q_check(:)
    REAL(wp) :: th, drive_ends(3, 4), drive_phi
    LOGICAL :: drive_was_set
    drive_was_set = model%tors_drive_set
    drive_ends = model%tors_drive_ends
    drive_phi = model%tors_drive_phi
    ! validate the frames (Set_Torsion_Drive), then put the drive target back as it was
    CALL CD_HermiteCable_Dyn_Set_Torsion_Drive(model, ends, model%torsion%phi, ErrStat, ErrMsg)
    model%tors_drive_set = drive_was_set
    model%tors_drive_ends = drive_ends
    model%tors_drive_phi = drive_phi
    IF (ErrStat /= CD_HCDYN_OK) RETURN
    IF (model%tw_active) THEN
      ! Nodal twist: the reference re-based at the committed (or checked) configuration with the
      ! new frames (tw_advance_reference: a rigid end's element takes the frame's turn, an
      ! elastic end's spring its psi), then the committed torques and Theta_eff.
      IF (PRESENT(q_check)) THEN
        IF (SIZE(q_check) /= model%ndof) THEN
          ErrStat = CD_HCDYN_BADINPUT
          ErrMsg = 'CD_HermiteCable_Dyn_Set_Torsion_Frames: q_check must have ndof entries'
          RETURN
        END IF
        CALL tw_advance_reference(model, q_check, ends, ErrStat, ErrMsg)
      ELSE
        CALL tw_advance_reference(model, model%q, ends, ErrStat, ErrMsg)
      END IF
      IF (ErrStat /= CD_HCDYN_OK) THEN
        ErrMsg = 'CD_HermiteCable_Dyn_Set_Torsion_Frames: '//TRIM(ErrMsg)
        RETURN
      END IF
      IF (PRESENT(q_check)) RETURN
      ! a frame turn within one step of the end-frame constants (the wrapped change is unique)
      model%tors_drive_set = .FALSE.
      CALL tw_commit_reference(model)
      model%torsion%ends = ends
      model%tors_use_step = .FALSE.
      CALL assemble_twist(model, model%q, model%v, .TRUE., .FALSE., model%ws_R, model%ws_Kb, model%ws_Kvb, &
                          ErrStat, ErrMsg)
      IF (ErrStat /= CD_HCDYN_OK) THEN
        ErrMsg = 'CD_HermiteCable_Dyn_Set_Torsion_Frames: '//TRIM(ErrMsg)
        RETURN
      END IF
      model%tw_mt = model%tw_me
      model%torsion%theta = model%torsion%phi - model%tw_tsum
      model%torsion%torque = model%tw_tsum/CD_HermiteTorsion_Compliance(model%torsion, model%l0)
      model%fc_valid = .FALSE.
      model%fc_clears = model%fc_clears + 1
      model%tr_valid = .FALSE.
      RETURN
    END IF
    IF (PRESENT(q_check)) THEN
      IF (SIZE(q_check) /= model%ndof) THEN
        ErrStat = CD_HCDYN_BADINPUT
        ErrMsg = 'CD_HermiteCable_Dyn_Set_Torsion_Frames: q_check must have ndof entries'
        RETURN
      END IF
      CALL torsion_theta_at(model, q_check, ends, th, ErrStat, ErrMsg)
      IF (ErrStat /= CD_HCDYN_OK) ErrMsg = 'CD_HermiteCable_Dyn_Set_Torsion_Frames: '//TRIM(ErrMsg)
      RETURN
    END IF
    CALL torsion_theta_at(model, model%q, ends, th, ErrStat, ErrMsg)
    IF (ErrStat /= CD_HCDYN_OK) THEN
      ErrMsg = 'CD_HermiteCable_Dyn_Set_Torsion_Frames: '//TRIM(ErrMsg)
      RETURN
    END IF
    ! the written frames supersede a pending drive target
    model%tors_drive_set = .FALSE.
    model%torsion%ends = ends
    model%torsion%theta = th
    model%torsion%torque = (model%torsion%phi - th)/CD_HermiteTorsion_Compliance(model%torsion, model%l0)
    model%fc_valid = .FALSE.
    model%fc_clears = model%fc_clears + 1
    model%tr_valid = .FALSE.
  END SUBROUTINE CD_HermiteCable_Dyn_Set_Torsion_Frames

  SUBROUTINE dyn_step_core(model, dt, max_iter, tol, ErrStat, ErrMsg, iters_out, res_out, &
                           pres_dofs, pres_q, pres_v, pres_a, residual_history, history_count, &
                           endconn_direction, endconn_direction_rate, endconn_direction_acceleration, &
                           tensile_failed)
    !! The generalised-alpha step of CD_HermiteCable_Dyn_Step (which sets up the torsion target).
    TYPE(CD_HermiteCableDynType), INTENT(INOUT), TARGET :: model
    REAL(wp), INTENT(IN) :: dt, tol
    INTEGER, INTENT(IN) :: max_iter
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    INTEGER, INTENT(OUT), OPTIONAL :: iters_out
    REAL(wp), INTENT(OUT), OPTIONAL :: res_out
    INTEGER, INTENT(IN), OPTIONAL :: pres_dofs(:)
    REAL(wp), INTENT(IN), OPTIONAL :: pres_q(:), pres_v(:), pres_a(:)
    REAL(wp), INTENT(OUT), OPTIONAL :: residual_history(:)
    INTEGER, INTENT(OUT), OPTIONAL :: history_count
    REAL(wp), INTENT(IN), OPTIONAL :: endconn_direction(3, 2)
    REAL(wp), INTENT(IN), OPTIONAL :: endconn_direction_rate(3, 2), endconn_direction_acceleration(3, 2)
    !! .TRUE. when the step failed the tensile qualification of the converged field (ERROR
    !! mode), as opposed to a Newton failure; the state is not committed in either case.
    LOGICAL, INTENT(OUT), OPTIONAL :: tensile_failed

    INTEGER :: ndof, it, es, i, np, ip, ls, gdof, nsolve_step, axial_element, axial_es
    INTEGER :: axial_worst_element, iv, attempt, n_attempt
    INTEGER :: n_ls_tan  ! tangents the step's line searches assembled at their accepted trial
    REAL(wp) :: c_a, c_v, c_a2, am, af, bt, gm, rnorm, fscale, rnt, lambda, chosen, lam_ok, cw, t_alpha, dth_lin
    REAL(wp) :: e_bal, e_ma, tors_theta_new, tors_mt_new
    REAL(wp) :: axial_qe(12), axial_min
    REAL(wp) :: axial_threshold, axial_margin, axial_worst_margin, axial_worst_force, axial_worst_xi
    REAL(wp) :: axial_worst_threshold
    ! Axial audit window (elements e-1, e, e+1; see the audit after convergence).
    INTEGER :: win_elem(3)
    LOGICAL :: win_clear(3), win_done(3)
    REAL(wp) :: win_mean(3), win_len, win_sum, win_ea
    LOGICAL :: has_pres, scale_set, have_tangent, mn, mn_factored, mn_fresh, has_endconn_motion
    LOGICAL :: fc_hit, xs_active, factor_ok, use_ca, xs_start
    INTEGER :: n_fact
    INTEGER :: n_stale
    REAL(wp) :: step_endconn_target(3, 2), step_endconn_eval(3, 2)
    REAL(wp) :: step_endconn_rate(3, 2), step_endconn_acceleration(3, 2)
    REAL(wp) :: step_rigid_basis(3, 3, 2)
    REAL(wp) :: step_n0(2), step_ndot0(2), step_nddot0(2)
    ! Modified-Newton contraction threshold: an accepted iterate must cut the residual
    ! to <= MN_CONTRACT * rnorm for the reused factor to be kept. ONE constant feeds both
    ! the accept-time validate-and-build decision and the commit-time rebuild schedule --
    ! they must agree, or a weak accept could skip validation yet still get rebuilt at.
    REAL(wp), PARAMETER :: MN_CONTRACT = 0.25_wp
    ! Constant-acceleration predictor gate: relative force imbalance of the committed state.
    REAL(wp), PARAMETER :: PRED_BALANCE = 0.5_wp
    ! Cross-step reuse: at most this many accepted iterations on the carried factor per step;
    ! a solve still short of the tolerance then refreshes (quadratic convergence from there).
    INTEGER, PARAMETER :: XS_MAX_STALE = 3
    ! A carried-factor iterate contracting the residual by less than this abandons the attempt
    ! (see the abandon test in the Newton loop); between MN_CONTRACT and it, the factor is
    ! refreshed at the iterate as usual.
    REAL(wp), PARAMETER :: XS_ABANDON = 0.5_wp
    ! Longest run of fresh-factor steps after repeated refreshes (see xs_backoff).
    INTEGER, PARAMETER :: XS_MAX_BACKOFF = 32
    ! A carried factor converges linearly, so its iterate stops just inside the tolerance where a
    ! fresh tangent's quadratic last step lands far inside it: iterates on it must reach
    ! XS_TOL_FACTOR*tol, which keeps the outputs as close to the converged solution as full
    ! Newton's.
    REAL(wp), PARAMETER :: XS_TOL_FACTOR = 0.3_wp
    INTEGER(INT64) :: pc0, pc1, pcr, pt0, pt1
    CHARACTER(1024) :: em2

    ErrStat = CD_HCDYN_OK
    ErrMsg = ''
    nsolve_step = 0
    ! Clock scratch is defined even when profiling is off, purely so -Wmaybe-uninitialized
    ! can prove it (every read sits under the same prof_enabled guard as its write).
    pt0 = 0_INT64; pc0 = 0_INT64; pcr = 1_INT64
    IF (prof_enabled) THEN
      CALL SYSTEM_CLOCK(pt0, pcr)
      prof_n_step = prof_n_step + 1
    END IF
    IF (PRESENT(iters_out)) iters_out = 0
    IF (PRESENT(res_out)) res_out = CD_ZERO
    IF (PRESENT(history_count)) history_count = 0
    IF (PRESENT(residual_history)) residual_history = CD_ZERO
    IF (PRESENT(tensile_failed)) tensile_failed = .FALSE.
    IF (.NOT. model%initialized) THEN
      ErrStat = CD_HCDYN_BADINPUT; ErrMsg = 'CD_HermiteCable_Dyn_Step: model not initialised'; RETURN
    END IF
    IF (.NOT. CD_Is_Finite(dt) .OR. dt <= CD_ZERO .OR. max_iter < 1 .OR. &
        .NOT. CD_Is_Finite(tol) .OR. tol <= CD_ZERO) THEN
      ErrStat = CD_HCDYN_BADINPUT
      ErrMsg = 'CD_HermiteCable_Dyn_Step: need dt>0, max_iter>=1, finite tol>0'; RETURN
    END IF
    IF (PRESENT(residual_history)) THEN
      IF (SIZE(residual_history) < max_iter) THEN
        ErrStat = CD_HCDYN_BADINPUT
        ErrMsg = 'CD_HermiteCable_Dyn_Step: residual_history must have at least max_iter entries'; RETURN
      END IF
    END IF

    ndof = model%ndof

    has_endconn_motion = PRESENT(endconn_direction)
    step_endconn_target = model%endconn_d0
    step_endconn_eval = model%endconn_d0
    step_endconn_rate = CD_ZERO
    step_endconn_acceleration = CD_ZERO
    IF (PRESENT(endconn_direction_rate) .NEQV. PRESENT(endconn_direction_acceleration)) THEN
      ErrStat = CD_HCDYN_BADINPUT
      ErrMsg = 'CD_HermiteCable_Dyn_Step: direction rate and acceleration must be supplied together'
      RETURN
    END IF
    IF (PRESENT(endconn_direction_rate) .AND. .NOT. has_endconn_motion) THEN
      ErrStat = CD_HCDYN_BADINPUT
      ErrMsg = 'CD_HermiteCable_Dyn_Step: direction derivatives require endconn_direction'
      RETURN
    END IF
    IF (has_endconn_motion) THEN
      CALL prepare_endconn_directions(model, endconn_direction, step_endconn_target, es, em2)
      IF (es /= CD_HCDYN_OK) THEN
        ErrStat = es
        ErrMsg = 'CD_HermiteCable_Dyn_Step: '//TRIM(em2)
        RETURN
      END IF
      CALL prepare_endconn_derivatives(model, step_endconn_target, step_endconn_rate, &
                                       step_endconn_acceleration, es, em2, endconn_direction_rate, &
                                       endconn_direction_acceleration)
      IF (es /= CD_HCDYN_OK) THEN
        ErrStat = es
        ErrMsg = 'CD_HermiteCable_Dyn_Step: '//TRIM(em2)
        RETURN
      END IF
      CALL interpolate_endconn_directions(model, model%endconn_d0, step_endconn_target, &
                                          MERGE(CD_ONE, CD_ONE - model%alpha_f, model%force_blend), &
                                          step_endconn_eval, es, em2)
      IF (es /= CD_HCDYN_OK) THEN
        ErrStat = es
        ErrMsg = 'CD_HermiteCable_Dyn_Step: '//TRIM(em2)
        RETURN
      END IF
    END IF
    CALL build_rigid_bases(model, step_endconn_target, step_rigid_basis, es, em2)
    IF (es /= CD_HCDYN_OK) THEN
      ErrStat = es
      ErrMsg = 'CD_HermiteCable_Dyn_Step: '//TRIM(em2)
      RETURN
    END IF

    ! Prescribed-motion validation: all four arrays together, sizes match, DOFs are fixed + finite.
    ! Reject ANY partial set -- including supplying pres_q/v/a while omitting pres_dofs, which would
    ! otherwise silently skip the drive and advance the boundary as held instead of failing the call.
    has_pres = PRESENT(pres_dofs) .AND. PRESENT(pres_q) .AND. PRESENT(pres_v) .AND. PRESENT(pres_a)
    np = 0
    IF ((PRESENT(pres_dofs) .OR. PRESENT(pres_q) .OR. PRESENT(pres_v) .OR. PRESENT(pres_a)) &
        .AND. .NOT. has_pres) THEN
      ErrStat = CD_HCDYN_BADINPUT
      ErrMsg = 'CD_HermiteCable_Dyn_Step: prescribed motion needs pres_dofs/q/v/a together'; RETURN
    END IF
    IF (has_pres) THEN
      np = SIZE(pres_dofs)
      IF (np < 1) THEN
        ErrStat = CD_HCDYN_BADINPUT
        ErrMsg = 'CD_HermiteCable_Dyn_Step: pres_dofs must not be empty'; RETURN
      END IF
      IF (SIZE(pres_q) /= np .OR. SIZE(pres_v) /= np .OR. SIZE(pres_a) /= np) THEN
        ErrStat = CD_HCDYN_BADINPUT
        ErrMsg = 'CD_HermiteCable_Dyn_Step: pres_q/v/a must match pres_dofs length'; RETURN
      END IF
      DO ip = 1, np
        gdof = pres_dofs(ip)
        IF (gdof < 1 .OR. gdof > ndof) THEN
          ErrStat = CD_HCDYN_BADINPUT; ErrMsg = 'CD_HermiteCable_Dyn_Step: pres_dof out of range'; RETURN
        END IF
        IF (model%freemask(gdof)) THEN
          ErrStat = CD_HCDYN_BADINPUT
          ErrMsg = 'CD_HermiteCable_Dyn_Step: prescribed DOF must be in fixed_dofs'; RETURN
        END IF
        IF (.NOT. CD_Is_Finite(pres_q(ip)) .OR. .NOT. CD_Is_Finite(pres_v(ip)) .OR. &
            .NOT. CD_Is_Finite(pres_a(ip))) THEN
          ErrStat = CD_HCDYN_BADINPUT; ErrMsg = 'CD_HermiteCable_Dyn_Step: prescribed q/v/a must be finite'; RETURN
        END IF
      END DO
    END IF
    am = model%alpha_m; af = model%alpha_f; bt = model%beta; gm = model%gamma
    ! Newmark acceleration-from-displacement coefficients.
    c_a = CD_ONE/(bt*dt*dt)              ! d a_{n+1} / d q_{n+1}
    c_v = CD_ONE/(bt*dt)
    c_a2 = CD_ONE/(2.0_wp*bt) - CD_ONE
    ! Velocity-tangent coupling: d(v_alpha)/d(q_{n+1}) = (1-af) * d(v_{n+1})/d(q_{n+1}) =
    ! (1-af) * gamma/(beta dt). Folds a velocity-dependent load (drag) into the effective tangent.
    cw = (CD_ONE - af)*gm/(bt*dt)
    ! FORCE-BLENDED generalised alpha (force_blend, the default): G = M a_alpha
    ! + (1-af) F(q_{n+1}, v_{n+1}, t_{n+1}) + af F(q_n, v_n, t_n). Blending the
    ! configurations instead evaluates the internal force at (1-af) q_{n+1} + af q_n, whose
    ! rotating Hermite tangents are shortened by the blend: a spurious stretch of order
    ! af (1-af) (omega dt)^2 EA that shifts the mean tension with dt. The force blend has
    ! the same second-order accuracy and tangent (1-af) K(q_{n+1}). Time-dependent (wave)
    ! loads evaluate at t_{n+1}, or at t_alpha for the configuration blend.
    IF (model%force_blend) THEN
      t_alpha = model%t + dt
    ELSE
      t_alpha = model%t + (CD_ONE - af)*dt
    END IF

    ! Workspace lives in the model (allocated once at Init): a dynamic step performs ZERO
    ! heap allocations. Local names below are the model's ws_* arrays.
    DO iv = 1, SIZE(model%ws_qn)
      model%ws_qn(iv) = model%q(iv)
      model%ws_vn(iv) = model%v(iv)
      model%ws_an(iv) = model%a(iv)
    END DO
    IF (model%tw_active) THEN
      DO iv = 1, model%nn
        model%tw_pn(iv) = model%tw_phi(iv)
        model%tw_wn(iv) = model%tw_w(iv)
        model%tw_an(iv) = model%tw_al(iv)
      END DO
    END IF
    CALL rigid_tangent_scalar_state(model, model%endconn_d0, model%ws_qn, model%ws_vn, model%ws_an, &
                                    step_n0, step_ndot0, step_nddot0)
    ! Total mass for this step: structural + added mass FROZEN at the beginning-of-step
    ! configuration q_n (constant within the Newton -> no dM/dq term; O(dt) freeze error consistent
    ! with gen-alpha accuracy, exact at any at-rest fixed point). All band arrays share the
    ! DGBSV layout, so the sum is a plain array operation (one sweep, after the added mass).
    IF (model%has_am) THEN
      IF (prof_enabled) CALL SYSTEM_CLOCK(pc0)
      CALL assemble_added_mass(model, model%ws_qn, es, em2)
      IF (prof_enabled) THEN
        CALL SYSTEM_CLOCK(pc1)
        prof_n_am = prof_n_am + 1
        prof_t_am = prof_t_am + REAL(pc1 - pc0, wp)/REAL(pcr, wp)
      END IF
      IF (es /= CD_HCDYN_OK) THEN
        ErrStat = es; ErrMsg = 'CD_HermiteCable_Dyn_Step: '//TRIM(em2); RETURN
      END IF
      CALL band_sum(model%Mgb, model%ws_Mamb, model%ws_Msumb)
    ELSE
      CALL band_copy(model%Mgb, model%ws_Msumb)
    END IF
    ! A fixed DOF that is NOT prescribed this step is a boundary HELD AT REST: zero its velocity and
    ! acceleration so the predictor keeps it at q_n and the commit leaves v = a = 0. Without this a
    ! DOF driven by pres_* in an earlier step and then released (omitted from pres_dofs) would keep
    ! drifting at its last prescribed rate, since Newton never touches fixed DOFs. Prescribed DOFs
    ! restore their own v_n/a_n history (needed for the gen-alpha blend and the pres_* override).
    DO i = 1, ndof
      IF (.NOT. model%freemask(i)) THEN
        model%ws_vn(i) = CD_ZERO; model%ws_an(i) = CD_ZERO
      END IF
    END DO
    IF (has_pres) THEN
      DO ip = 1, np
        model%ws_vn(pres_dofs(ip)) = model%v(pres_dofs(ip))
        model%ws_an(pres_dofs(ip)) = model%a(pres_dofs(ip))
      END DO
    END IF
    ! Committed force F_n = R(q_n, v_n, t_n) with the current load configuration and the
    ! lengths the committed state was reached with (active line control: l0_c): reused from
    ! the previous step's converged evaluation when its key matches the committed state
    ! exactly, evaluated here otherwise (one residual assembly).
    IF (.NOT. model%snap_stepped) THEN
      model%snap_stepped = .TRUE.
      model%snap_step_clears = model%fc_clears
    END IF
    fc_hit = .FALSE.
    IF (model%force_blend) fc_hit = force_cache_matches()
    ! Cross-step factor reuse needs the step to continue bitwise from the state the carried
    ! factor's step committed (the force-cache key), at the same dt and without a moving rigid
    ! end frame (whose basis transform is baked into the factor). The carried factor is
    ! consumed here: only this step's commit re-validates ws_Keffb.
    xs_active = model%tangent_reuse .AND. model%tr_valid .AND. fc_hit .AND. .NOT. has_endconn_motion
    IF (xs_active) xs_active = .NOT. (ABS(dt - model%tr_dt) > CD_ZERO)
    factor_ok = xs_active
    model%tr_valid = .FALSE.
    IF (model%force_blend .AND. .NOT. fc_hit) THEN
      CALL assemble_committed_force(model, es, em2)
      IF (es /= CD_HCDYN_OK) THEN
        ErrStat = es; ErrMsg = 'CD_HermiteCable_Dyn_Step: '//TRIM(em2); RETURN
      END IF
      DO iv = 1, SIZE(model%fc_R)
        model%fc_R(iv) = model%ws_R(iv)
      END DO
      IF (model%tw_active) THEN
        DO iv = 1, model%nn
          model%tw_fcR(iv) = model%tw_R(iv)
        END DO
      END IF
      ! Key the recomputed force on the state it describes.
      model%fc_q = model%q
      model%fc_v = model%v
      model%fc_t = model%t
      model%fc_d0 = model%endconn_d0
      model%fc_valid = .TRUE.
    END IF
    ! VIV: F_n above took the committed phase; the step's evaluations take its predicted phase.
    IF (model%has_viv) THEN
      CALL viv_step_begin(model, dt, es, em2)
      IF (es /= CD_HCDYN_OK) THEN
        ErrStat = es; ErrMsg = 'CD_HermiteCable_Dyn_Step: '//TRIM(em2); RETURN
      END IF
    END IF
    ! Condensed torsion: F_n above used the committed end frames and Phi; every evaluation of the
    ! step from here on uses the step's target (set by CD_HermiteCable_Dyn_Step).
    model%tors_use_step = model%torsion%active
    IF (model%tw_active) CALL tw_frame_rates(model, dt)
    ! Newton predictor. The standard Newmark guess q_n + dt v_n + dt^2 (1/2 - beta) a_n (the
    ! acceleration map's base a_{n+1} = 0) is a far better start than q_n when the state is
    ! moving. When the committed acceleration is the physical one, the constant-acceleration
    ! guess a_{n+1} = a_n, q_n + dt v_n + dt^2/2 a_n, starts an order of magnitude closer: it
    ! saves an iteration per step and, at a loose tolerance, removes the a = 0 bias of the
    ! Newmark guess. It is NOT safe while an under-resolved (omega dt > 1) mode rings: its
    ! algorithmic acceleration is not a smooth signal, a loosely converged step keeps the
    ! extrapolated value and the mode is no longer damped, whereas the a = 0 guess damps it.
    ! The test uses only the committed state (restart-exact, no history): the extrapolation
    ! runs when the committed acceleration balances the committed force, |M a_n + F_n| <=
    ! PRED_BALANCE |M a_n| on the translational free DOFs (F_n = fc_R, force blend only). A
    ! failed constant-acceleration attempt re-solves the step from the Newmark guess, so
    ! robustness is never below the Newmark-predictor solve.
    n_attempt = 1
    use_ca = .FALSE.
    e_bal = CD_ZERO
    e_ma = CD_ZERO
    IF (model%force_blend) THEN
      CALL band_matvec(model%ws_Msumb, model%ws_an, model%ws_inert)
      DO iv = 1, ndof
        IF (.NOT. model%solve_mask(iv) .OR. MOD(iv - 1, 6) >= 3) CYCLE
        e_bal = e_bal + (model%ws_inert(iv) + model%fc_R(iv))**2
        e_ma = e_ma + model%ws_inert(iv)**2
      END DO
      use_ca = e_ma > CD_ZERO .AND. e_bal <= PRED_BALANCE**2*e_ma
      ! Active line control: after a length or rate change the step's force departs from the
      ! committed balance by the force of the change, a load step the constant-acceleration
      ! guess does not anticipate; the step starts from the Newmark guess, which damps what
      ! the change excites.
      IF (use_ca .AND. model%has_ctrl) use_ca = lengths_committed()
    END IF
    ! The carried factor is used under the same smoothness test: through a transient it
    ! stops each step just inside the tolerance, and those states can lead the start-up of a
    ! stiff cable into a step no Newton converges.
    xs_active = xs_active .AND. use_ca
    IF (xs_active .AND. model%xs_skip > 0) THEN
      model%xs_skip = model%xs_skip - 1
      xs_active = .FALSE.
    END IF
    xs_start = xs_active
    n_fact = 0
    ! Each acceleration is dropped in turn on failure: a failed carried-factor solve retries
    ! the constant-acceleration guess on a fresh tangent (a stale factor can lead the line
    ! search off the smooth solution, while the guess itself is still the best start), and
    ! a failed constant-acceleration solve retries the Newmark guess on a fresh tangent,
    ! i.e. the plain solve. Dropping both at once restarts a step the constant-acceleration
    ! guess converges in one iteration from the a = 0 guess, which at a large dt can reach
    ! a different (spurious) root.
    IF (use_ca) n_attempt = 2
    IF (xs_active) n_attempt = 3
    predict: DO attempt = 1, n_attempt
    IF (attempt > 1) THEN
      ! The retry is a fresh solve: its iteration count is the step's.
      ErrStat = CD_HCDYN_OK
      ErrMsg = ''
      nsolve_step = 0
      IF (PRESENT(iters_out)) iters_out = 0
      IF (PRESENT(res_out)) res_out = CD_ZERO
      IF (PRESENT(history_count)) history_count = 0
      IF (PRESENT(residual_history)) residual_history = CD_ZERO
      IF (.NOT. (xs_start .AND. attempt == 2)) use_ca = .FALSE.
      xs_active = .FALSE.
    END IF
    n_stale = 0
    IF (use_ca) THEN
      DO iv = 1, SIZE(model%ws_qk)
        model%ws_qk(iv) = model%ws_qn(iv) + dt*model%ws_vn(iv) + 0.5_wp*dt*dt*model%ws_an(iv)
      END DO
    ELSE
      DO iv = 1, SIZE(model%ws_qk)
        model%ws_qk(iv) = model%ws_qn(iv) + dt*model%ws_vn(iv) + (0.5_wp - bt)*dt*dt*model%ws_an(iv)
      END DO
    END IF
    ! Hold the prescribed DOFs at their target position for the whole solve (Newton never touches
    ! them -- they are in fixed_dofs, hence not in fmap).
    IF (has_pres) THEN
      DO ip = 1, np
        model%ws_qk(pres_dofs(ip)) = pres_q(ip)
      END DO
    END IF
    ! Nodal twist: the same predictor for the angles; a rigid end holds 0 (end 1) or Phi (end 2).
    IF (model%tw_active) THEN
      DO iv = 1, model%nn
        IF (use_ca) THEN
          model%tw_pk(iv) = model%tw_pn(iv) + dt*model%tw_wn(iv) + 0.5_wp*dt*dt*model%tw_an(iv)
        ELSE
          model%tw_pk(iv) = model%tw_pn(iv) + dt*model%tw_wn(iv) + (0.5_wp - bt)*dt*dt*model%tw_an(iv)
        END IF
      END DO
      IF (model%tw_rigid(1)) model%tw_pk(1) = CD_ZERO
      IF (model%tw_rigid(2)) model%tw_pk(model%nn) = model%tors_step_phi
    END IF
    CALL project_rigid_tangents(model, step_endconn_target, model%ws_qk, es, em2)
    IF (es /= CD_HCDYN_OK) THEN
      ErrStat = es
      ErrMsg = 'CD_HermiteCable_Dyn_Step: '//TRIM(em2)
      IF (attempt < n_attempt) CYCLE predict
      RETURN
    END IF

    ! Residual + tangent at the predictor, then damped (line-searched) Newton. The line search on
    ! the residual norm is what keeps the solve robust at the large implicit dt this element is
    ! meant to exploit (axial stiffness EA >> EI makes an undamped full step overshoot on a stiff
    ! transient) -- mirroring the damped Newton the static solver uses for the same geometry.
    ! The force scale fscale is FROZEN at the predictor so every rnorm in the step (predictor and
    ! all line-search trials) is divided by the same denominator -- otherwise a per-configuration
    ! fscale makes the line-search comparison rnt < rnorm inconsistent and rejects good steps.
    scale_set = .FALSE.
    have_tangent = .FALSE.
    mn = model%modified_newton
    ! Adaptive policy overrides the flag: full Newton during the warmup, then the decided mode.
    IF (model%newton_adaptive) THEN
      IF (model%na_steps_done < model%na_warmup) THEN
        mn = .FALSE.
      ELSE
        mn = model%na_mn_active
      END IF
    END IF
    ! A carried factor starts the iteration already factored (and stale).
    mn_factored = xs_active
    mn_fresh = .FALSE.
    n_ls_tan = 0
    ! The first iteration assembles its tangent at the predictor unless a carried factor is
    ! reused, so the predictor evaluation keeps its element tangents for it (stash), unless the
    ! last step converged at its predictor (made no solve). Either way every result is the same:
    ! only where the element kernels run changes.
    CALL eval_res(model%ws_qk, .FALSE., rnorm, es, em2, &
                  stash=nsolve_step < model%ws_stash_solves .AND. .NOT. ((mn .OR. xs_active) .AND. mn_factored))
    IF (es /= CD_HCDYN_OK) THEN
      ErrStat = es; ErrMsg = 'CD_HermiteCable_Dyn_Step: '//TRIM(em2)
      IF (attempt < n_attempt) CYCLE predict
      RETURN
    END IF

    DO it = 1, max_iter
      IF (PRESENT(residual_history)) residual_history(it) = rnorm
      IF (PRESENT(history_count)) history_count = it
      IF (PRESENT(iters_out)) iters_out = nsolve_step
      IF (PRESENT(res_out)) res_out = rnorm
      IF (rnorm < MERGE(XS_TOL_FACTOR*tol, tol, xs_active)) EXIT
      IF (it == max_iter) THEN
        ErrStat = CD_HCDYN_NOCONVERGE
        BLOCK
          ! Format into a local buffer: a record longer than the caller's ErrMsg
          ! must truncate, not abort the internal write.
          CHARACTER(1024) :: wbuf
          INTEGER :: wios
          wbuf = ''
          WRITE (wbuf, '(A,ES12.5,A,ES12.5)', IOSTAT=wios) &
            'CD_HermiteCable_Dyn_Step: Newton did not converge, ||G||=', rnorm, ' > tol=', tol
          ErrMsg = wbuf
        END BLOCK
        IF (attempt < n_attempt) CYCLE predict
        RETURN
      END IF
      ! Tangent assembly ONCE per solve iteration, at the alpha-blend states (ws_qa/ws_va)
      ! the accepted (or predictor) residual evaluation just stored -- the evaluation point
      ! the Newton iteration linearizes about, so rejected line-search trials and each
      ! step's CONVERGED accepted evaluation do not pay for tangents that are never
      ! factored. An accepted trial that will iterate again
      ! validates and builds its tangent inside the line search (have_tangent), so this
      ! fires only for the predictor iterate.
      !
      ! MODIFIED NEWTON (model%modified_newton): the tangent is assembled + factored once
      ! per STEP (at the predictor iterate) and the FACTORIZATION is reused for every
      ! subsequent iteration -- only the residual back-substitution repeats. The factored
      ! band + pivots persist untouched in ws_Keffb/ws_ipiv between iterations. mn_fresh
      ! records whether the current factor was built at the current iterate (the refresh
      ! path resets it), so a failed line search can tell a stale direction from a
      ! genuinely hard step. The stale-direction refresh retries WITHIN this named
      ! construct -- inside the SAME outer Newton iteration -- so it is never charged
      ! against max_iter (a refresh on the last allowed iteration must still be tried,
      ! not aborted by the budget check before its fresh direction ever runs).
      !
      ! CROSS-STEP REUSE (xs_active): the same machinery runs on the factor carried from the
      ! previous step, with the same MN_CONTRACT gate. Its first refresh ends the reuse for the
      ! rest of the step (full Newton, unless modified_newton keeps reusing within the step).
      mn_retry: DO
      IF (.NOT. ((mn .OR. xs_active) .AND. mn_factored)) THEN
        IF (.NOT. have_tangent) THEN
          IF (prof_enabled) CALL SYSTEM_CLOCK(pc0)
          ! the element tangents the predictor (or refresh) evaluation kept at this very state
          CALL assemble_residual(model, model%ws_qa, model%ws_va, t_alpha, .FALSE., .TRUE., es, em2, &
                                 endconn_direction_eval=step_endconn_eval, use_stash=.TRUE.)
          IF (prof_enabled) THEN
            CALL SYSTEM_CLOCK(pc1)
            prof_n_tan = prof_n_tan + 1
            prof_t_tan = prof_t_tan + REAL(pc1 - pc0, wp)/REAL(pcr, wp)
          END IF
          IF (es /= CD_HCDYN_OK) THEN
            ErrStat = es; ErrMsg = 'CD_HermiteCable_Dyn_Step: '//TRIM(em2)
            IF (attempt < n_attempt) CYCLE predict
            RETURN
          END IF
        END IF
        ! Effective tangent dG/dq_{n+1} = (1-am) c_a M + (1-af) K + cw Kv -- a plain array
        ! operation on the row-aligned band arrays. Dirichlet applies IN-BAND (row/column
        ! zeroed within the band, unit diagonal, zero residual slot), so the full-size banded
        ! solve returns exactly zero update at every fixed DOF -- no free-DOF reduction copy.
        factor_ok = .FALSE.
        IF (prof_enabled) CALL SYSTEM_CLOCK(pc0)
        CALL band_combine((CD_ONE - am)*c_a, model%ws_Msumb, CD_ONE - af, model%ws_Kb, cw, model%ws_Kvb, &
                          model%ws_Keffb)
        IF (has_endconn_motion) CALL add_rigid_transport_tangent()
        CALL transform_rigid_band(model, step_rigid_basis, model%ws_Keffb)
        CALL dirichlet_band(model%ws_Keffb, model%solve_mask)
        IF (prof_enabled) THEN
          CALL SYSTEM_CLOCK(pc1)
          prof_t_eff = prof_t_eff + REAL(pc1 - pc0, wp)/REAL(pcr, wp)
        END IF
        ! Factor with the model-owned pivot workspace (DGBTRF -- exactly what DGBSV runs
        ! internally, without its per-call pivot allocation).
        IF (prof_enabled) CALL SYSTEM_CLOCK(pc0)
        IF (model%tw_active) THEN
          ! nodal twist: the cable's band with the angles interleaved ([r, m, phi] per node)
          CALL tw_build_K7(model, (CD_ONE - am)*c_a, CD_ONE - af, cw, step_rigid_basis, es, em2)
          IF (es /= CD_HCDYN_OK) THEN
            ErrStat = es; ErrMsg = 'CD_HermiteCable_Dyn_Step: '//TRIM(em2)
            IF (attempt < n_attempt) CYCLE predict
            RETURN
          END IF
          CALL CD_Factor_Banded(model%tw_K7, KB7, KB7, model%tw_ipiv, es, em2, matrix_validated=.TRUE.)
        ELSE
          CALL CD_Factor_Banded(model%ws_Keffb, KL_D, KU_D, model%ws_ipiv, es, em2, matrix_validated=.TRUE.)
        END IF
        IF (prof_enabled) THEN
          CALL SYSTEM_CLOCK(pc1)
          prof_n_factor = prof_n_factor + 1
          prof_t_factor = prof_t_factor + REAL(pc1 - pc0, wp)/REAL(pcr, wp)
        END IF
        IF (es /= CD_LINALG_OK) THEN
          ErrStat = CD_HCDYN_NOCONVERGE; ErrMsg = 'CD_HermiteCable_Dyn_Step: tangent factor: '//TRIM(em2)
          IF (attempt < n_attempt) CYCLE predict
          RETURN
        END IF
        IF (model%torsion%active .AND. .NOT. model%tw_active) THEN
          ! Rank-one torsion term (1 - af) g g^T / C of the effective tangent: g in the solve
          ! coordinates (as the residual), its K^-1 image and the Sherman-Morrison denominator,
          ! all kept with this factor.
          CALL torsion_factor(es, em2)
          IF (es /= CD_HCDYN_OK) THEN
            ErrStat = es; ErrMsg = 'CD_HermiteCable_Dyn_Step: '//TRIM(em2)
            IF (attempt < n_attempt) CYCLE predict
            RETURN
          END IF
        END IF
        mn_factored = .TRUE.
        mn_fresh = .TRUE.
        factor_ok = .TRUE.
        xs_active = .FALSE.
        n_fact = n_fact + 1
        ! The line-search build (if any) is now consumed by this factor. Clearing the
        ! flag matters under modified Newton: a weak-contraction accept builds its
        ! tangent, the scheduled rebuild factors it here, and a LATER refresh must not
        ! mistake that already-consumed assembly for one taken at the refresh iterate.
        have_tangent = .FALSE.
      END IF
      DO iv = 1, SIZE(model%ws_dq)
        model%ws_dq(iv) = -model%ws_G(iv)
      END DO
      DO i = 1, ndof
        IF (.NOT. model%solve_mask(i)) model%ws_dq(i) = CD_ZERO
      END DO
      IF (prof_enabled) CALL SYSTEM_CLOCK(pc0)
      IF (model%tw_active) THEN
        DO i = 1, model%nn
          model%tw_dp(i) = MERGE(-model%tw_G(i), CD_ZERO, model%tw_free(i))
        END DO
        CALL tw_solve(model, es, em2)
      ELSE
        CALL CD_Solve_Factored_Banded(model%ws_Keffb, KL_D, KU_D, model%ws_ipiv, model%ws_dq, es, em2, &
                                      factor_validated=.TRUE.)
      END IF
      IF (prof_enabled) THEN
        CALL SYSTEM_CLOCK(pc1)
        prof_n_solve = prof_n_solve + 1
        prof_t_solve = prof_t_solve + REAL(pc1 - pc0, wp)/REAL(pcr, wp)
      END IF
      IF (es /= CD_LINALG_OK) THEN
        ErrStat = CD_HCDYN_NOCONVERGE; ErrMsg = 'CD_HermiteCable_Dyn_Step: tangent solve: '//TRIM(em2)
        IF (attempt < n_attempt) CYCLE predict
        RETURN
      END IF
      IF (model%torsion%active .AND. .NOT. model%tw_active) CALL torsion_sm_correct()
      CALL transform_rigid_vector_to_global(model, step_rigid_basis, model%ws_dq)
      nsolve_step = nsolve_step + 1
      IF (PRESENT(iters_out)) iters_out = nsolve_step
      ! Backtracking line search: accept the first step length that reduces the residual (and gives
      ! a finite element geometry); if none does, take a small safe damped step so the iteration
      ! never commits an overshoot. max_iter then bounds a genuinely stuck solve honestly.
      ! dq(fixed) = 0 by construction, so the whole-vector trial leaves fixed DOFs untouched.
      chosen = -CD_ONE
      lam_ok = -CD_ONE                                    ! smallest step length with a finite eval
      lambda = CD_ONE
      ! Condensed torsion: the linearised twist change of a trial stays within pi/4 (the
      ! post-trial unwrap against the committed Theta cannot tell 3 pi/2 from -pi/2)
      IF (model%torsion%active .AND. .NOT. model%tw_active) THEN
        dth_lin = ABS(DOT_PRODUCT(model%tors_g, model%ws_dq))
        IF (dth_lin > 0.5_wp*CD_HTORS_MAX_STEP) lambda = 0.5_wp*CD_HTORS_MAX_STEP/dth_lin
      END IF
      DO ls = 1, 10
        DO iv = 1, SIZE(model%ws_qtrial)
          model%ws_qtrial(iv) = model%ws_qk(iv) + lambda*model%ws_dq(iv)
        END DO
        IF (model%tw_active) CALL tw_trial(lambda)
        ! The full step of a full-Newton iteration keeps its element tangents while this step's
        ! line searches have assembled fewer tangents than the last step's (an accepted trial that
        ! iterates again assembles its tangent below, at this state).
        CALL eval_res(model%ws_qtrial, .TRUE., rnt, es, em2, &
                      stash=ls == 1 .AND. .NOT. (mn .OR. xs_active) .AND. n_ls_tan < model%ws_stash_ls)
        IF (es == CD_HCDYN_OK) THEN
          lam_ok = lambda                                 ! loop shrinks lambda, so this ends smallest
          IF (rnt < rnorm) THEN
            ! Accepting a trial that will iterate again requires a FINITE tangent at it: a
            ! residual can stay finite where the Hessian/Jacobians overflow (near-degenerate
            ! geometry, extreme stiffness), and accepting such a point would only abort at
            ! the next factor. Validate-and-build here (the trial's alpha states are current)
            ! and treat an assembly failure exactly like a non-finite trial: keep halving.
            ! A CONVERGED accept skips the tangent -- it is never factored.
            ! Under MODIFIED NEWTON only a STRONG-contraction accept skips the
            ! validate-and-build (the existing factor is kept; no rebuild is scheduled
            ! at this point) -- that skip is the reuse saving. A WEAK-contraction accept
            ! (rnt > 0.25 rnorm, the same predicate the commit's contraction gate uses)
            ! schedules an immediate rebuild AT this point, so it validates-and-builds
            ! exactly like full Newton: committing a finite-residual/overflowing-tangent
            ! geometry and then rebuilding there would abort where full Newton halves
            ! to a usable trial.
            IF (rnt < MERGE(XS_TOL_FACTOR*tol, tol, xs_active)) THEN
              chosen = lambda; EXIT
            END IF
            IF ((mn .OR. xs_active) .AND. rnt <= MN_CONTRACT*rnorm) THEN
              chosen = lambda; EXIT
            END IF
            IF (prof_enabled) CALL SYSTEM_CLOCK(pc0)
            CALL assemble_residual(model, model%ws_qa, model%ws_va, t_alpha, .FALSE., .TRUE., es, em2, &
                                   endconn_direction_eval=step_endconn_eval, use_stash=.TRUE.)
            IF (prof_enabled) THEN
              CALL SYSTEM_CLOCK(pc1)
              prof_n_tan = prof_n_tan + 1
              prof_t_tan = prof_t_tan + REAL(pc1 - pc0, wp)/REAL(pcr, wp)
            END IF
            IF (es == CD_HCDYN_OK) THEN
              have_tangent = .TRUE.
              n_ls_tan = n_ls_tan + 1
              chosen = lambda; EXIT
            END IF
          END IF
        END IF
        lambda = 0.5_wp*lambda
      END DO
      IF (xs_active .AND. (chosen < CD_ZERO .OR. &
                           (rnt > XS_ABANDON*rnorm .AND. rnt >= XS_TOL_FACTOR*tol))) THEN
        ! The carried factor is kept only while it contracts like Newton. A weak or failed
        ! contraction abandons the attempt instead of refreshing at the current iterate: the
        ! iterates of a stale direction reduce the residual norm without staying near the
        ! solution, and a fresh Newton from there can crawl to a different root. The retry
        ! restarts from the constant-acceleration guess on a fresh tangent.
        ErrStat = CD_HCDYN_NOCONVERGE
        ErrMsg = 'CD_HermiteCable_Dyn_Step: carried factor stopped contracting'
        CYCLE predict
      END IF
      IF (chosen < CD_ZERO .AND. (mn .OR. xs_active) .AND. .NOT. mn_fresh) THEN
        ! The stale direction found no improving step. Before the safe damped fallback,
        ! refresh ONCE: rebuild + refactor at the CURRENT iterate and re-derive the
        ! direction, WITHIN this outer iteration (CYCLE mn_retry, not the Newton loop --
        ! the refresh is bookkeeping, not a step, and must not consume iteration budget).
        ! The rejected trials overwrote ws_qa/ws_va (eval_res stages the alpha states on
        ! every call), so re-evaluate at the current iterate first -- it restores
        ! ws_qa/ws_va/ws_G/rnorm to the iterate's own values, and the retry-top then
        ! assembles the fresh tangent at the right point. At most one refresh fires per
        ! iteration (the rebuild sets mn_fresh, which blocks this guard). If the fresh
        ! direction still cannot improve, the step is genuinely hard and the fallback
        ! below handles it exactly as full Newton would. The retry-top tangent is at this
        ! evaluation's state, so it keeps its element tangents (stash).
        CALL eval_res(model%ws_qk, .FALSE., rnorm, es, em2, stash=.TRUE.)
        IF (es /= CD_HCDYN_OK) THEN
          ErrStat = es; ErrMsg = 'CD_HermiteCable_Dyn_Step: '//TRIM(em2)
          IF (attempt < n_attempt) CYCLE predict
          RETURN
        END IF
        mn_factored = .FALSE.
        CYCLE mn_retry
      END IF
      EXIT mn_retry
      END DO mn_retry
      IF (chosen < CD_ZERO) THEN
        ! No step length reduced the residual (with a usable tangent): fall back to the
        ! SMALLEST step that at least gave a finite evaluation (a safe damped step). Using
        ! the actual smallest finite trial -- not a fixed 2^-8 -- means a step whose larger
        ! lengths are non-finite but whose smaller ones are valid is still taken, rather
        ! than spuriously reported as a failure. The fallback validates its tangent the
        ! same way, halving further if needed.
        IF (lam_ok < CD_ZERO) THEN
          ErrStat = CD_HCDYN_NOCONVERGE
          ErrMsg = 'CD_HermiteCable_Dyn_Step: line search: element non-finite at all step lengths'
          IF (attempt < n_attempt) CYCLE predict
          RETURN
        END IF
        lambda = lam_ok
        DO ls = 1, 10
          DO iv = 1, SIZE(model%ws_qtrial)
            model%ws_qtrial(iv) = model%ws_qk(iv) + lambda*model%ws_dq(iv)
          END DO
          IF (model%tw_active) CALL tw_trial(lambda)
          CALL eval_res(model%ws_qtrial, .TRUE., rnt, es, em2)
          IF (es == CD_HCDYN_OK) THEN
            ! The fallback step rarely improves the residual, so under modified Newton the
            ! contraction gate will schedule a rebuild at it -- validate-and-build here
            ! exactly like full Newton (the mn saving never came from this rare path).
            IF (rnt < tol) EXIT                           ! converged accept: tangent never factored
            IF (prof_enabled) CALL SYSTEM_CLOCK(pc0)
            CALL assemble_residual(model, model%ws_qa, model%ws_va, t_alpha, .FALSE., .TRUE., es, em2, &
                                   endconn_direction_eval=step_endconn_eval)
            IF (prof_enabled) THEN
              CALL SYSTEM_CLOCK(pc1)
              prof_n_tan = prof_n_tan + 1
              prof_t_tan = prof_t_tan + REAL(pc1 - pc0, wp)/REAL(pcr, wp)
            END IF
            IF (es == CD_HCDYN_OK) THEN
              have_tangent = .TRUE.
              EXIT
            END IF
          END IF
          IF (ls == 10) THEN
            ErrStat = CD_HCDYN_NOCONVERGE
            ErrMsg = 'CD_HermiteCable_Dyn_Step: line search: no step length with a finite '// &
                     'residual and tangent'
            IF (attempt < n_attempt) CYCLE predict
            RETURN
          END IF
          lambda = 0.5_wp*lambda
        END DO
      END IF
      ! commit the accepted iterate + its residual/tangents; the step's reused factor is
      ! now at least one iterate old (stale), so a later stuck line search may refresh it
      IF (mn .OR. xs_active) THEN
        ! CONTRACTION-GATED reuse: keep the factor only while the accepted iterate still
        ! contracts the residual strongly (Newton-like). A stale tangent on a stiff cable
        ! otherwise degrades to slow linear convergence (measured: the pure-reuse variant
        ! plateaus above tol and burns the whole iteration budget), so a weak contraction
        ! schedules a rebuild at the next iteration -- the reuse then pays only in the
        ! well-conditioned phase where it is free.
        IF (rnt > MN_CONTRACT*rnorm) mn_factored = .FALSE.
        IF (xs_active) THEN
          n_stale = n_stale + 1
          IF (n_stale >= XS_MAX_STALE) mn_factored = .FALSE.
        END IF
        mn_fresh = .FALSE.
      END IF
      DO iv = 1, SIZE(model%ws_qk)
        model%ws_qk(iv) = model%ws_qtrial(iv)
      END DO
      DO iv = 1, SIZE(model%ws_G)
        model%ws_G(iv) = model%ws_Gt(iv)
      END DO
      DO iv = 1, SIZE(model%ws_Rk)
        model%ws_Rk(iv) = model%ws_Rt(iv)
      END DO
      IF (model%tw_active) CALL tw_accept()
      rnorm = rnt
    END DO
    EXIT predict
    END DO predict
    model%ws_stash_solves = nsolve_step
    model%ws_stash_ls = n_ls_tan

    ! Force blend: the committed force F_{n+1} enters every later step through af F_n, so the
    ! accepted state is taken one Newton correction beyond the tolerance, with the factor of
    ! the last iteration (one back-substitution and one residual evaluation, no new
    ! factorisation). The correction is kept only when it lowers the residual.
    IF (model%force_blend .AND. nsolve_step > 0 .AND. rnorm > CD_ZERO) THEN
      DO iv = 1, SIZE(model%ws_dq)
        model%ws_dq(iv) = -model%ws_G(iv)
      END DO
      DO i = 1, ndof
        IF (.NOT. model%solve_mask(i)) model%ws_dq(i) = CD_ZERO
      END DO
      IF (prof_enabled) CALL SYSTEM_CLOCK(pc0)
      IF (model%tw_active) THEN
        DO i = 1, model%nn
          model%tw_dp(i) = MERGE(-model%tw_G(i), CD_ZERO, model%tw_free(i))
        END DO
        CALL tw_solve(model, es, em2)
      ELSE
        CALL CD_Solve_Factored_Banded(model%ws_Keffb, KL_D, KU_D, model%ws_ipiv, model%ws_dq, es, em2, &
                                      factor_validated=.TRUE.)
      END IF
      IF (prof_enabled) THEN
        CALL SYSTEM_CLOCK(pc1)
        prof_n_correct = prof_n_correct + 1
        prof_t_solve = prof_t_solve + REAL(pc1 - pc0, wp)/REAL(pcr, wp)
      END IF
      IF (es == CD_LINALG_OK) THEN
        IF (model%torsion%active .AND. .NOT. model%tw_active) CALL torsion_sm_correct()
        CALL transform_rigid_vector_to_global(model, step_rigid_basis, model%ws_dq)
        DO iv = 1, SIZE(model%ws_qtrial)
          model%ws_qtrial(iv) = model%ws_qk(iv) + model%ws_dq(iv)
        END DO
        IF (model%tw_active) CALL tw_trial(CD_ONE)
        CALL eval_res(model%ws_qtrial, .TRUE., rnt, es, em2)
        IF (es == CD_HCDYN_OK .AND. rnt < rnorm) THEN
          DO iv = 1, SIZE(model%ws_qk)
            model%ws_qk(iv) = model%ws_qtrial(iv)
          END DO
          DO iv = 1, SIZE(model%ws_G)
            model%ws_G(iv) = model%ws_Gt(iv)
          END DO
          DO iv = 1, SIZE(model%ws_Rk)
            model%ws_Rk(iv) = model%ws_Rt(iv)
          END DO
          IF (model%tw_active) CALL tw_accept()
          rnorm = rnt
          IF (PRESENT(res_out)) res_out = rnorm
        ELSE
          ! Restore the accepted iterate's staged states (the trial overwrote them).
          CALL eval_res(model%ws_qk, .FALSE., rnorm, es, em2)
          IF (es /= CD_HCDYN_OK) THEN
            ErrStat = es; ErrMsg = 'CD_HermiteCable_Dyn_Step: '//TRIM(em2); RETURN
          END IF
        END IF
      END IF
    END IF

    ! Condensed torsion: Theta at q_{n+1} with the step's end frames, unwrapped against the
    ! committed value (within pi/2: every accepted evaluation already was), before anything is
    ! committed so that a failure leaves the step-start state; its torque enters the axial
    ! audit under torque-tension coupling.
    tors_theta_new = model%torsion%theta
    tors_mt_new = CD_ZERO
    IF (model%tw_active) THEN
      ! nodal twist: the reference state at q_{n+1}, and Theta_eff = Phi less the summed twist
      ! of the converged evaluation, whose element torques (tw_me) enter the audit
      CALL tw_advance_reference(model, model%ws_qk, model%tors_step_ends, es, em2)
      IF (es /= CD_HCDYN_OK) THEN
        ErrStat = es; ErrMsg = 'CD_HermiteCable_Dyn_Step: '//TRIM(em2); RETURN
      END IF
      tors_theta_new = model%tors_step_phi - model%tw_tsum
    ELSE IF (model%torsion%active) THEN
      CALL torsion_theta_at(model, model%ws_qk, model%tors_step_ends, tors_theta_new, es, em2)
      IF (es /= CD_HCDYN_OK) THEN
        ErrStat = es; ErrMsg = 'CD_HermiteCable_Dyn_Step: '//TRIM(em2); RETURN
      END IF
      tors_mt_new = (model%tors_step_phi - tors_theta_new)/CD_HermiteTorsion_Compliance(model%torsion, model%l0)
    END IF

    ! Axial audit of the converged field. ERROR is the hard gate; WARN commits the converged
    ! state and records one event for this accepted step. The audited force is the one that
    ! enters equilibrium, as in the static branch audit: the element-mean axial force (the
    ! three-point Gauss mean of the signed resultant EA (|r'| - 1)), averaged over the element
    ! and its two neighbours weighted by length (clipped at the line ends). The pointwise
    ! trace of a stiff-EA cubic-Hermite element oscillates about that mean, and a single
    ! element mean dips next to a nodal seabed-contact reaction, by amounts that grow with
    ! the element length: judged pointwise, a coarse mesh whose tensions and curvatures are
    ! converged reads as compressed. A compressed span of three or more elements is never
    ! averaged away. The band is tensile_strain_tolerance times the length-weighted EA of the
    ! same three elements; a window whose elements all have a force lower bound inside the
    ! band cannot fall below it and is skipped. Under torque-tension coupling the element's
    ! axial force adds (K/GJ) M_t at the converged torque to the kernel's EA - K^2/GJ resultant.
    IF (model%tensile_mode /= CD_HCDYN_TENSILE_OFF) THEN
      axial_worst_margin = HUGE(CD_ONE)
      axial_worst_force = CD_ZERO; axial_worst_threshold = CD_ZERO
      axial_worst_element = 0; axial_worst_xi = CD_ZERO
      ! Sliding window over elements e-1, e, e+1 (slot 1..3; element 0 = none).
      win_elem = 0
      win_clear = .TRUE.
      win_done = .FALSE.
      win_mean = CD_ZERO
      DO axial_element = 1, model%ne
        IF (axial_element == 1) THEN
          CALL window_load(2, 1)
          IF (model%ne >= 2) CALL window_load(3, 2)
        ELSE
          win_elem(1:2) = win_elem(2:3); win_clear(1:2) = win_clear(2:3)
          win_done(1:2) = win_done(2:3); win_mean(1:2) = win_mean(2:3)
          win_elem(3) = 0; win_clear(3) = .TRUE.; win_done(3) = .FALSE.
          IF (axial_element + 1 <= model%ne) CALL window_load(3, axial_element + 1)
        END IF
        IF (ALL(win_clear)) CYCLE
        win_len = CD_ZERO; win_sum = CD_ZERO; win_ea = CD_ZERO
        DO iv = 1, 3
          IF (win_elem(iv) == 0) CYCLE
          IF (.NOT. win_done(iv)) THEN
            CALL window_mean(iv, axial_es)
            IF (axial_es /= CD_HCABLE_OK) THEN
              ErrStat = CD_HCDYN_NOCONVERGE
              ErrMsg = 'CD_HermiteCable_Dyn_Step: tensile audit failed: '//TRIM(em2)
              IF (PRESENT(tensile_failed)) tensile_failed = .TRUE.
              RETURN
            END IF
          END IF
          win_len = win_len + model%l0(win_elem(iv))
          win_sum = win_sum + model%l0(win_elem(iv))*win_mean(iv)
          win_ea = win_ea + model%l0(win_elem(iv))*model%EA(win_elem(iv))
        END DO
        axial_min = win_sum/win_len
        axial_threshold = model%tensile_strain_tolerance*win_ea/win_len
        axial_margin = axial_min + axial_threshold
        IF (axial_margin < axial_worst_margin) THEN
          axial_worst_margin = axial_margin
          axial_worst_force = axial_min
          axial_worst_threshold = axial_threshold
          axial_worst_element = axial_element
          axial_worst_xi = 0.5_wp   ! the centre of the three-element window (its middle element)
        END IF
      END DO
      IF (axial_worst_margin < CD_ZERO) THEN
        IF (model%tensile_mode == CD_HCDYN_TENSILE_ERROR) THEN
          ErrStat = CD_HCDYN_NOCONVERGE
          BLOCK
            CHARACTER(1024) :: wbuf
            INTEGER :: wios
            wbuf = ''
            WRITE (wbuf, '(A,ES12.4,A,ES12.4,A,I0,A,F7.4,A)', IOSTAT=wios) &
              'CD_HermiteCable_Dyn_Step: axial compression ', axial_worst_force, ' N below -', &
              axial_worst_threshold, ' N (element-mean axial force over elements e-1..e+1) at element ', &
              axial_worst_element, ', xi=', axial_worst_xi, &
              '; increase tensile_strain_tolerance only with an engineering basis, or use warn mode'
            ErrMsg = wbuf
          END BLOCK
          IF (PRESENT(tensile_failed)) tensile_failed = .TRUE.
          RETURN
        END IF
        model%tensile_event_count = model%tensile_event_count + 1
        IF (model%tensile_worst_element == 0 .OR. &
            axial_worst_margin < model%tensile_worst_force + model%tensile_worst_threshold) THEN
          model%tensile_worst_force = axial_worst_force
          model%tensile_worst_threshold = axial_worst_threshold
          model%tensile_worst_element = axial_worst_element
          model%tensile_worst_xi = axial_worst_xi
          model%tensile_worst_time = model%t + dt
        END IF
      END IF
    END IF

    ! Adaptive modified Newton: this step CONVERGED (a non-converged step returned above and
    ! does not count). Accumulate the warmup's full-Newton solve counts and, at the end of
    ! the warmup, latch tangent reuse on for the rest of the run iff the warmup averaged more
    ! than na_threshold solves/step.
    IF (model%newton_adaptive .AND. model%na_steps_done < model%na_warmup) THEN
      model%na_iter_sum = model%na_iter_sum + REAL(nsolve_step, wp)
      model%na_steps_done = model%na_steps_done + 1
      IF (model%na_steps_done == model%na_warmup) THEN
        model%na_mn_active = (model%na_iter_sum/REAL(model%na_warmup, wp)) > model%na_threshold
      END IF
    ELSE IF (model%newton_adaptive) THEN
      model%na_steps_done = model%na_steps_done + 1
    END IF

    ! Commit q_{n+1}, a_{n+1}, v_{n+1}.
    DO iv = 1, SIZE(model%ws_ak)
      model%ws_ak(iv) = c_a*(model%ws_qk(iv) - model%ws_qn(iv)) - c_v*model%ws_vn(iv) - c_a2*model%ws_an(iv)
    END DO
    IF (has_pres) THEN
      DO ip = 1, np
        model%ws_ak(pres_dofs(ip)) = pres_a(ip)
      END DO
    END IF
    DO iv = 1, SIZE(model%q)
      model%q(iv) = model%ws_qk(iv)
    END DO
    DO iv = 1, SIZE(model%a)
      model%a(iv) = model%ws_ak(iv)
    END DO
    DO iv = 1, SIZE(model%v)
      model%v(iv) = model%ws_vn(iv) + dt*((CD_ONE - gm)*model%ws_an(iv) + gm*model%ws_ak(iv))
    END DO
    ! The prescribed DOFs carry their prescribed velocity exactly (not the Newmark blend).
    IF (has_pres) THEN
      DO ip = 1, np
        model%v(pres_dofs(ip)) = pres_v(ip)
      END DO
    END IF
    IF (has_endconn_motion) CALL impose_step_rigid_kinematics(model%q, model%v, model%a)
    IF (model%fr_active) CALL commit_friction_anchors(model)
    IF (model%has_viv) CALL viv_step_end(model, dt)
    model%t = model%t + dt
    IF (has_endconn_motion) model%endconn_d0 = step_endconn_target
    IF (model%tw_active) THEN
      DO iv = 1, model%nn
        model%tw_ak(iv) = c_a*(model%tw_pk(iv) - model%tw_pn(iv)) - c_v*model%tw_wn(iv) - c_a2*model%tw_an(iv)
        model%tw_phi(iv) = model%tw_pk(iv)
        model%tw_al(iv) = model%tw_ak(iv)
        model%tw_w(iv) = model%tw_wn(iv) + dt*((CD_ONE - gm)*model%tw_an(iv) + gm*model%tw_ak(iv))
      END DO
      CALL tw_commit_reference(model)
      model%tw_oal = (model%tw_som - model%tw_om)/dt
      model%tw_om = model%tw_som
      DO iv = 1, model%ne
        model%tw_mt(iv) = model%tw_me(iv)
      END DO
    END IF
    IF (model%torsion%active) THEN
      model%torsion%ends = model%tors_step_ends
      model%torsion%phi = model%tors_step_phi
      model%torsion%theta = tors_theta_new
      model%torsion%torque = (model%torsion%phi - tors_theta_new)/ &
                             CD_HermiteTorsion_Compliance(model%torsion, model%l0)
      ! the read-only queries of the committed state (end loads, energy, channels) from the
      ! cache; a failure here only leaves it invalid (a query then evaluates and reports it).
      ! The nodal twist answers its queries from its own committed state.
      IF (.NOT. model%tw_active) THEN
        BLOCK
          INTEGER :: es_tc
          CHARACTER(1024) :: em_tc
          CALL torsion_cache_fill(model, es_tc, em_tc)
        END BLOCK
      END IF
    END IF
    ! Carry the factor of this step's last iteration to the next step.
    model%tr_valid = model%tangent_reuse .AND. factor_ok
    IF (xs_start) THEN
      IF (n_fact > 0 .AND. n_fact >= model%xs_fresh_fact) THEN
        model%xs_backoff = MIN(MAX(1, 2*model%xs_backoff), XS_MAX_BACKOFF)
        model%xs_skip = model%xs_backoff
      ELSE
        model%xs_backoff = 0
      END IF
    ELSE IF (use_ca) THEN
      ! a fresh step on smooth motion: the reference a reuse step must beat
      model%xs_fresh_fact = n_fact
    END IF
    model%tr_dt = dt
    ! The converged iterate's unblended force is F at the committed state: cache it, keyed
    ! on that state, as the next step's F_n. With VIV it took the step's predicted phase, not
    ! the committed one, so the next step evaluates F_n afresh.
    IF (model%has_viv) THEN
      model%fc_valid = .FALSE.
    ELSE IF (model%force_blend) THEN
      DO iv = 1, SIZE(model%fc_R)
        model%fc_R(iv) = model%ws_Rk(iv)
      END DO
      IF (model%tw_active) THEN
        DO iv = 1, model%nn
          model%tw_fcR(iv) = model%tw_Rk(iv)
        END DO
      END IF
      model%fc_q = model%q
      model%fc_v = model%v
      model%fc_t = model%t
      model%fc_d0 = model%endconn_d0
      model%fc_valid = .TRUE.
    END IF
    ! The committed state was reached with the present lengths and rates.
    IF (model%has_ctrl) THEN
      model%l0_c = model%l0
      model%l0_dot_c = model%l0_dot
    END IF
    ! Largest nodal tangent turn of the step (the time-step diagnostic).
    DO i = 1, model%nn
      model%max_step_rotation = MAX(model%max_step_rotation, &
                                    vector_angle(model%ws_qn(6*(i - 1) + 4:6*i), model%q(6*(i - 1) + 4:6*i)))
    END DO
    ! Step wall accumulates on the success path only; error paths abandon their partial time
    ! (the profile is a diagnostic of converged runs).
    IF (prof_enabled) THEN
      CALL SYSTEM_CLOCK(pt1)
      prof_t_step = prof_t_step + REAL(pt1 - pt0, wp)/REAL(pcr, wp)
    END IF

  CONTAINS

    SUBROUTINE window_load(slot, e)
      !! Axial audit window slot for element e: whether its force lower bound (EA times the
      !! strain lower bound, plus the coupling force) lies inside the band (its element mean
      !! cannot then be below -tolerance*EA); the mean is computed on demand (window_mean).
      INTEGER, INTENT(IN) :: slot, e
      win_elem(slot) = e
      win_done(slot) = .FALSE.
      win_mean(slot) = CD_ZERO
      axial_qe(1:6) = model%ws_qk(6*(e - 1) + 1:6*e)
      axial_qe(7:12) = model%ws_qk(6*e + 1:6*(e + 1))
      IF (.NOT. ABS(audit_coupling(e)) > CD_ZERO) THEN
        win_clear(slot) = CD_HermiteCable_Axial_Strain_Lower_Bound(axial_qe, model%l0(e)) >= &
          -model%tensile_strain_tolerance
      ELSE
        win_clear(slot) = model%EA(e)*CD_HermiteCable_Axial_Strain_Lower_Bound(axial_qe, model%l0(e)) + &
                          audit_coupling(e) >= -model%tensile_strain_tolerance*model%EA(e)
      END IF
    END SUBROUTINE window_load

    REAL(wp) FUNCTION audit_coupling(e) RESULT(tc)
      !! The torque-tension coupling force (K/GJ) M_t of element e at the converged torque (the
      !! nodal twist's own element torque, else the condensed uniform one).
      INTEGER, INTENT(IN) :: e
      tc = CD_ZERO
      IF (.NOT. model%torsion%active) RETURN
      IF (.NOT. ALLOCATED(model%torsion%couple)) RETURN
      IF (model%tw_active) THEN
        tc = model%torsion%couple(e)*model%tw_me(e)
      ELSE
        tc = model%torsion%couple(e)*tors_mt_new
      END IF
    END FUNCTION audit_coupling

    SUBROUTINE window_mean(slot, esx)
      !! Element-mean axial force of the element in window slot: the three-point Gauss mean
      !! of the signed axial resultant (the static branch audit's element mean).
      INTEGER, INTENT(IN) :: slot
      INTEGER, INTENT(OUT) :: esx
      REAL(wp), PARAMETER :: GX(3) = [0.5_wp - 0.5_wp*SQRT(0.6_wp), 0.5_wp, 0.5_wp + 0.5_wp*SQRT(0.6_wp)]
      REAL(wp), PARAMETER :: GW(3) = [5.0_wp/18.0_wp, 8.0_wp/18.0_wp, 5.0_wp/18.0_wp]
      REAL(wp) :: ng
      INTEGER :: e, kg
      e = win_elem(slot)
      axial_qe(1:6) = model%ws_qk(6*(e - 1) + 1:6*e)
      axial_qe(7:12) = model%ws_qk(6*e + 1:6*(e + 1))
      win_mean(slot) = CD_ZERO
      DO kg = 1, 3
        CALL CD_HermiteCable_Axial_Resultant(axial_qe, model%l0(e), model%EA(e), GX(kg), ng, esx, em2)
        IF (esx /= CD_HCABLE_OK) RETURN
        win_mean(slot) = win_mean(slot) + GW(kg)*ng
      END DO
      win_mean(slot) = win_mean(slot) + audit_coupling(e)
      win_done(slot) = .TRUE.
    END SUBROUTINE window_mean

    LOGICAL FUNCTION lengths_committed() RESULT(ok)
      !! The lengths and rates are those the committed state was reached with.
      INTEGER :: ie
      ok = .TRUE.
      DO ie = 1, model%ne
        IF (.NOT. (bits_equal(model%l0(ie), model%l0_c(ie)) .AND. &
                   bits_equal(model%l0_dot(ie), model%l0_dot_c(ie)))) THEN
          ok = .FALSE.
          RETURN
        END IF
      END DO
    END FUNCTION lengths_committed

    LOGICAL FUNCTION force_cache_matches() RESULT(ok)
      !! The cached F_n was evaluated at exactly the committed state and configuration.
      INTEGER :: ii
      ok = model%fc_valid
      IF (.NOT. ok) RETURN
      ok = .NOT. (ABS(model%fc_t - model%t) > CD_ZERO)
      IF (ok) ok = ALL(.NOT. (ABS(model%fc_d0 - model%endconn_d0) > CD_ZERO))
      DO ii = 1, ndof
        IF (.NOT. ok) RETURN
        ok = .NOT. (ABS(model%fc_q(ii) - model%q(ii)) > CD_ZERO .OR. &
                    ABS(model%fc_v(ii) - model%v(ii)) > CD_ZERO)
      END DO
    END FUNCTION force_cache_matches

    SUBROUTINE eval_res(qcur, use_trial, rn, esx, emx, stash)
      !! gen-alpha residual G = M a_alpha + f_int - f_ext, its banded position/velocity
      !! tangents, and the dimensionless per-slot residual norm rn at the trial
      !! configuration qcur. Prescribed DOFs carry their prescribed acceleration/velocity;
      !! the rest follow the Newmark map from qcur. Results land in the model's OWN
      !! buffers -- ws_G (committed) or ws_Gt (line-search trial) selected by use_trial;
      !! evaluations are RESIDUAL-ONLY (the tangent is assembled once per solve iteration
      !! at the loop top, directly into the committed band buffers) -- through pointers into the
      !! host's model, so no model subobject is ever argument-associated alongside the
      !! model itself (which the Fortran aliasing rule would forbid). Uses the ws_* Newmark scratch and the host fscale.
      !! stash (optional): an evaluation the next tangent assembly follows at the same state
      !! also keeps the element tangents (assemble_residual, stash_tangent); the residual is
      !! the same either way.
      REAL(wp), INTENT(IN) :: qcur(:)
      LOGICAL, INTENT(IN) :: use_trial
      REAL(wp), INTENT(OUT) :: rn
      INTEGER, INTENT(OUT) :: esx
      CHARACTER(*), INTENT(OUT) :: emx
      LOGICAL, INTENT(IN), OPTIONAL :: stash
      REAL(wp), POINTER :: Gout(:)
      INTEGER :: ii, nd
      INTEGER(INT64) :: ec0, ec1
      REAL(wp) :: xref, xd, xc, ea_r, ka, kt, tw_round
      REAL(wp), PARAMETER :: RESID_ROUNDOFF = 16.0_wp
      REAL(wp), PARAMETER :: STATE_DIVERGED = 1.0e12_wp
      ec0 = 0_INT64      ! defined even with profiling off (see the step-entry note)
      IF (prof_enabled) THEN
        CALL SYSTEM_CLOCK(ec0)
        prof_n_resid = prof_n_resid + 1
      END IF
      model%ws_stash_ok = .FALSE.   ! kept element tangents never outlive a new evaluation
      IF (use_trial) THEN
        Gout => model%ws_Gt
      ELSE
        Gout => model%ws_G
      END IF
      ! A diverging Newton iterate (or line-search trial) is rejected before the element
      ! kernels see it: their strain and drag powers of a runaway configuration overflow
      ! (a trapped FPE, or Inf in Release) instead of reporting non-convergence.
      IF (.NOT. CD_All_Finite(qcur)) THEN
        esx = CD_HCDYN_NOCONVERGE
        emx = 'the Newton iterate is not finite'
        rn = CD_ZERO
        RETURN
      END IF
      IF (MAXVAL(ABS(qcur)) > STATE_DIVERGED) THEN
        esx = CD_HCDYN_NOCONVERGE
        emx = 'the Newton iterate diverged (a coordinate beyond 1e12 m)'
        rn = CD_ZERO
        RETURN
      END IF
      IF (.NOT. rigid_rays_valid(model, step_endconn_target, qcur)) THEN
        esx = CD_HCDYN_NOCONVERGE
        emx = 'rigid endpoint tangent left the positive prescribed ray'
        rn = CD_ZERO
        IF (prof_enabled) THEN
          CALL SYSTEM_CLOCK(ec1)
          prof_t_resid = prof_t_resid + REAL(ec1 - ec0, wp)/REAL(pcr, wp)
        END IF
        RETURN
      END IF
      CALL newmark_acceleration(c_a, qcur, model%ws_qn, c_v, model%ws_vn, c_a2, model%ws_an, model%ws_ak)
      IF (has_pres) THEN
        DO ii = 1, np
          model%ws_ak(pres_dofs(ii)) = pres_a(ii)
        END DO
      END IF
      ! Newmark velocity v_{n+1} from the current acceleration, with the prescribed boundary carrying
      ! its exact prescribed velocity (held boundaries have v_n = a_n = 0, so vk = 0 there).
      CALL newmark_velocity(dt, CD_ONE - gm, gm, model%ws_vn, model%ws_an, model%ws_ak, model%ws_vk)
      IF (has_pres) THEN
        DO ii = 1, np
          model%ws_vk(pres_dofs(ii)) = pres_v(ii)
        END DO
      END IF
      IF (has_endconn_motion) CALL impose_step_rigid_kinematics(qcur, model%ws_vk, model%ws_ak)
      IF (model%tw_active) CALL tw_stage(use_trial)
      ! Force blend: the configuration the force (and the loop-top tangent) is evaluated at is
      ! the iterate itself; only the inertia uses the alpha_m blend. Configuration blend: the
      ! forces are evaluated at the alpha_f-blended state.
      IF (model%force_blend) THEN
        CALL vector_copy(qcur, model%ws_qa)
        CALL vector_copy(model%ws_vk, model%ws_va)
      ELSE
        CALL vector_blend(CD_ONE - af, qcur, af, model%ws_qn, model%ws_qa)
        CALL vector_blend(CD_ONE - af, model%ws_vk, af, model%ws_vn, model%ws_va)
      END IF
      CALL vector_blend(CD_ONE - am, model%ws_ak, am, model%ws_an, model%ws_aa)
      CALL assemble_residual(model, model%ws_qa, model%ws_va, t_alpha, .TRUE., .FALSE., esx, emx, &
                             endconn_direction_eval=step_endconn_eval, stash_tangent=stash)
      IF (esx /= CD_HCDYN_OK) THEN
        rn = CD_ZERO
        IF (prof_enabled) THEN
          CALL SYSTEM_CLOCK(ec1)
          prof_t_resid = prof_t_resid + REAL(ec1 - ec0, wp)/REAL(pcr, wp)
        END IF
        RETURN
      END IF
      IF (use_trial) THEN
        CALL vector_copy(model%ws_R, model%ws_Rt)
      ELSE
        CALL vector_copy(model%ws_R, model%ws_Rk)
      END IF
      IF (model%tw_active) CALL tw_residual(use_trial)
      ! total (structural + frozen added) mass inertia via the band matvec
      CALL band_matvec(model%ws_Msumb, model%ws_aa, model%ws_inert)
      IF (model%force_blend) THEN
        CALL vector_sum3(model%ws_inert, CD_ONE - af, model%ws_R, af, model%fc_R, Gout)
      ELSE
        CALL vector_sum2(model%ws_inert, model%ws_R, Gout)
      END IF
      CALL transform_rigid_vector_to_local(model, step_rigid_basis, Gout)
      ! Freeze the force scale at the first (predictor) evaluation so it is constant across the
      ! step's line-search trials -- see the caller's note. The scale is taken over the FREE
      ! equations only: a fixed/prescribed boundary can carry a large support/contact/inertial
      ! reaction, and including those constrained entries would inflate the scale and let the free
      ! residual look converged prematurely. The convergence verdict is about the equations solved.
      IF (.NOT. scale_set) THEN
        fscale = CD_ONE
        DO ii = 1, ndof
          IF (.NOT. model%solve_mask(ii)) CYCLE
          fscale = MAX(fscale, ABS(model%ws_inert(ii)), ABS(model%ws_R(ii)))
        END DO
        ! Physical force-scale floor: the peak element gravity load |w|*l0. Without it, a step
        ! taken at or near rest (small inertia, a static seed whose f_int - f_ext residual is
        ! already small) collapses fscale to the CD_ONE floor, which turns the RELATIVE tolerance
        ! into an ABSOLUTE one far below the round-off floor of a stiff cable's O(EA) internal
        ! forces -- so the step can never converge however good the seed. The floor only binds when
        ! the motion is gentle; a vigorous step's inertia/residual already dominates it, so the
        ! validated moving-cable gates (whose fscale is inertia/residual-set) are unaffected.
        DO ii = 1, SIZE(model%w)
          fscale = MAX(fscale, ABS(model%w(ii))*model%l0(ii))
        END DO
        ! Round-off floor: an axial force EA*(|r'| - 1) is formed from coordinate differences,
        ! so its rounding error is about eps*|r|/l0*EA per element. On a finely meshed, stiff,
        ! long cable at rest (e.g. 1024 elements, EA ~ 5e8 N, coordinates ~ 1e3 m) that exceeds
        ! tol*|w|*l0 and a held step stagnates at the floor forever. Raise fscale so tol*fscale
        ! is never below RESID_ROUNDOFF times that error; the floor binds only there. With the
        ! torque-tension coupling K the kernel carries EA - K^2/GJ and the torque the rest: the
        ! coupling force (K/GJ) M_t takes the stretch through M_t = (GJ/l0)(... - (K/GJ)(l - l0)),
        ! whose rounding is (K^2/GJ) eps |r|/l0, so the floor takes the whole axial stiffness
        ! EA - K^2/GJ + K^2/GJ of the line (without it the floor fell by 1 - K^2/(EA GJ): at
        ! K = 0.99 sqrt(EA GJ) to 2 % of the rounding it bounds, and a held line failed its step).
        ! The axial damping force BA d(|r'|)/dt takes the strain rate from the Newmark velocity,
        ! whose rounding is gamma/(beta dt) times that of the coordinates, so the floor adds
        ! BA gamma/(beta dt) to the axial stiffness, as the twist floor below adds Bt: without it a
        ! held line damped near its first axial mode (BA = 2 zeta EA/omega_1, which at small dt
        ! puts the damping term well above EA) stagnated at a residual of a few times the
        ! tolerance and failed its step.
        xref = MAXVAL(model%l0)
        DO ii = 1, ndof
          IF (MOD(ii - 1, 6) < 3) xref = MAX(xref, ABS(qcur(ii)))
        END DO
        ea_r = CD_ZERO
        DO ii = 1, SIZE(model%l0)
          ka = ABS(model%EA(ii))
          IF (model%torsion%active .AND. ALLOCATED(model%torsion%couple)) &
            ka = ka + model%torsion%couple(ii)**2*model%torsion%gj(ii)
          IF (model%has_axial_damping) ka = ka + ABS(model%BA(ii))*gm/(bt*dt)
          ea_r = MAX(ea_r, ka/model%l0(ii))
        END DO
        fscale = MAX(fscale, RESID_ROUNDOFF*EPSILON(CD_ONE)*ea_r*xref/tol)
        ! Nodal twist: the torque scale of the angle rows, frozen with fscale and formed like it
        ! from the nodal loads (a node's torque imbalance, not the torque the line carries,
        ! which accumulates the imbalances along the line as the tension does the force's): the
        ! inertial torques and the predictor's imbalance, at least 1 N m, and the round-off
        ! floor of an element twist, (GJ/l0 + Bt/l0 gamma/(beta dt)) eps (max|phi| + max|x|/l0)
        ! (the damping takes the twist rate, whose Newmark rate amplifies the rounding). With the
        ! torque-tension coupling the twist tau also takes -(K/GJ)(l - l0), the element length l
        ! formed from coordinates with the rounding eps max|x|, so the floor adds
        ! (GJ/l0 + Bt/l0 gamma/(beta dt)) |K/GJ| eps max|x| = |K| eps max|x|/l0 (static share):
        ! K/l0 exceeds GJ/l0^2 by K l0/GJ (165 on a 2 m mesh at K = 0.85 sqrt(EA GJ), EA/GJ =
        ! 9.4e3 m^-2), and without it a held line's rounding of 2.4e-8 N m stood above the
        ! tolerance of its 1 N m scale and the step failed.
        IF (model%tw_active) THEN
          model%tw_tscale = CD_ONE
          DO ii = 1, model%nn
            IF (.NOT. model%tw_free(ii)) CYCLE
            model%tw_tscale = MAX(model%tw_tscale, &
                                  ABS(model%tw_mass(ii)*((CD_ONE - am)*model%tw_ak(ii) + am*model%tw_an(ii))), &
                                  ABS(model%tw_R(ii)))
          END DO
          xd = MAXVAL(model%torsion%gj/model%l0)
          IF (ALLOCATED(model%torsion%bt)) xd = xd + MAXVAL(model%torsion%bt/model%l0)*gm/(bt*dt)
          xc = CD_ZERO
          IF (ALLOCATED(model%torsion%couple)) THEN
            DO ii = 1, SIZE(model%l0)
              kt = model%torsion%gj(ii)/model%l0(ii)
              IF (ALLOCATED(model%torsion%bt)) kt = kt + model%torsion%bt(ii)/model%l0(ii)*gm/(bt*dt)
              xc = MAX(xc, ABS(model%torsion%couple(ii))*kt)
            END DO
          END IF
          tw_round = MAX(CD_ONE, MAXVAL(ABS(model%tw_pe))) + xref/MINVAL(model%l0)
          model%tw_tscale = MAX(model%tw_tscale, RESID_ROUNDOFF*EPSILON(CD_ONE)*xd*tw_round/tol)
          IF (xc > CD_ZERO) &
            model%tw_tscale = MAX(model%tw_tscale, RESID_ROUNDOFF*EPSILON(CD_ONE)*(xd*tw_round + xc*xref)/tol)
        END IF
        scale_set = .TRUE.
      END IF
      rn = CD_ZERO
      DO ii = 1, ndof
        IF (.NOT. model%solve_mask(ii)) CYCLE
        IF (MOD(ii - 1, 6) >= 3) THEN                       ! material-tangent slot (m)
          nd = (ii - 1)/6 + 1
          rn = MAX(rn, ABS(Gout(ii))/(fscale*model%trib(nd)))
        ELSE                                                ! translational slot (r)
          rn = MAX(rn, ABS(Gout(ii))/fscale)
        END IF
      END DO
      IF (model%tw_active) THEN
        DO ii = 1, model%nn
          IF (.NOT. model%tw_free(ii)) CYCLE
          IF (use_trial) THEN
            rn = MAX(rn, ABS(model%tw_Gt(ii))/model%tw_tscale)
          ELSE
            rn = MAX(rn, ABS(model%tw_G(ii))/model%tw_tscale)
          END IF
        END DO
      END IF
      IF (.NOT. CD_Is_Finite(rn)) THEN
        esx = CD_HCDYN_NOCONVERGE; emx = 'non-finite residual'
      END IF
      IF (prof_enabled) THEN
        CALL SYSTEM_CLOCK(ec1)
        prof_t_resid = prof_t_resid + REAL(ec1 - ec0, wp)/REAL(pcr, wp)
      END IF
    END SUBROUTINE eval_res

    SUBROUTINE impose_step_rigid_kinematics(q_state, v_state, a_state)
      !! Eliminate the two prescribed rotational tangent components while leaving
      !! the axial magnitude as the single solved coordinate. The scalar magnitude
      !! follows the same Newmark scheme as every free DOF; d, d_dot, and d_ddot
      !! are prescribed parent kinematics at the interval end.
      REAL(wp), INTENT(IN) :: q_state(:)
      REAL(wp), INTENT(INOUT) :: v_state(:), a_state(:)
      INTEGER :: iend, base
      REAL(wp) :: magnitude, magnitude_rate, magnitude_acceleration
      DO iend = 1, 2
        IF (model%endconn_mode(iend) /= CD_ENDCONN_RIGID) CYCLE
        IF (iend == 1) THEN
          base = 3
        ELSE
          base = 6*(model%nn - 1) + 3
        END IF
        magnitude = DOT_PRODUCT(q_state(base + 1:base + 3), step_endconn_target(:, iend))
        magnitude_acceleration = c_a*(magnitude - step_n0(iend)) - &
                                 c_v*step_ndot0(iend) - c_a2*step_nddot0(iend)
        magnitude_rate = step_ndot0(iend) + &
                         dt*((CD_ONE - gm)*step_nddot0(iend) + gm*magnitude_acceleration)
        v_state(base + 1:base + 3) = magnitude_rate*step_endconn_target(:, iend) + &
                                     magnitude*step_endconn_rate(:, iend)
        a_state(base + 1:base + 3) = magnitude_acceleration*step_endconn_target(:, iend) + &
                                     2.0_wp*magnitude_rate*step_endconn_rate(:, iend) + &
                                     magnitude*step_endconn_acceleration(:, iend)
      END DO
    END SUBROUTINE impose_step_rigid_kinematics

    SUBROUTINE add_rigid_transport_tangent()
      !! Complete dG/dn for m = n d. The baseline effective matrix already
      !! contains the c_a*d and gamma/(beta*dt)*d contributions. Add the terms
      !! from d_dot and d_ddot as a rank-one update whose right vector is d;
      !! after the rigid basis transform this affects only the free axial column.
      !! The left vector (1 - am) M a_x + (1 - af) Kv d_dot has non-zeros only in the band rows
      !! of the three tangent columns, so it is formed on those rows alone: the products of the
      !! three column entries, summed in column order as the band matvec would sum them.
      INTEGER :: iend, base, row, j, lo, hi
      REAL(wp) :: rate_coefficient, extra_acceleration(3), mass_part, damping_part
      REAL(wp) :: transport(KL_D + KU_D + 3)
      rate_coefficient = gm/(bt*dt)
      DO iend = 1, 2
        IF (model%endconn_mode(iend) /= CD_ENDCONN_RIGID) CYCLE
        IF (iend == 1) THEN
          base = 3
        ELSE
          base = 6*(model%nn - 1) + 3
        END IF
        extra_acceleration = 2.0_wp*rate_coefficient*step_endconn_rate(:, iend) + &
                             step_endconn_acceleration(:, iend)
        lo = MAX(1, base + 1 - KU_D)
        hi = MIN(model%ndof, base + 3 + KL_D)
        DO row = lo, hi
          mass_part = CD_ZERO
          damping_part = CD_ZERO
          DO j = 1, 3
            mass_part = mass_part + dynamic_band_entry(model, model%ws_Msumb, row, base + j)*extra_acceleration(j)
            damping_part = damping_part + &
                           dynamic_band_entry(model, model%ws_Kvb, row, base + j)*step_endconn_rate(j, iend)
          END DO
          transport(row - lo + 1) = (CD_ONE - am)*mass_part + (CD_ONE - af)*damping_part
        END DO
        DO j = 1, 3
          DO row = MAX(1, base + j - KU_D), MIN(model%ndof, base + j + KL_D)
            CALL set_dynamic_band_entry(model, model%ws_Keffb, row, base + j, &
                                        dynamic_band_entry(model, model%ws_Keffb, row, base + j) + &
                                        transport(row - lo + 1)*step_endconn_target(j, iend))
          END DO
        END DO
      END DO
    END SUBROUTINE add_rigid_transport_tangent

    SUBROUTINE torsion_factor(esx, emx)
      !! After a factorisation of K_eff = B (band part): g = dTheta/dq at the tangent point in
      !! the solve coordinates (rigid-end basis, held DOFs zeroed), z = B^-1 g and the
      !! Sherman-Morrison denominator C/(1 - af) + g.z of (B + (1 - af) g g^T / C)^-1.
      INTEGER, INTENT(OUT) :: esx
      CHARACTER(*), INTENT(OUT) :: emx
      INTEGER :: ii
      REAL(wp) :: cr, gz
      esx = CD_HCDYN_OK
      emx = ''
      DO ii = 1, ndof
        model%tors_gk(ii) = model%tors_g(ii)
      END DO
      CALL transform_rigid_vector_to_local(model, step_rigid_basis, model%tors_gk)
      DO ii = 1, ndof
        IF (.NOT. model%solve_mask(ii)) model%tors_gk(ii) = CD_ZERO
        model%tors_zk(ii) = model%tors_gk(ii)
      END DO
      CALL CD_Solve_Factored_Banded(model%ws_Keffb, KL_D, KU_D, model%ws_ipiv, model%tors_zk, esx, emx, &
                                    factor_validated=.TRUE.)
      IF (esx /= CD_LINALG_OK) THEN
        esx = CD_HCDYN_NOCONVERGE
        emx = 'torsion: tangent solve: '//TRIM(emx)
        RETURN
      END IF
      esx = CD_HCDYN_OK
      cr = CD_HermiteTorsion_Compliance(model%torsion, model%l0)/(CD_ONE - af)
      gz = DOT_PRODUCT(model%tors_gk, model%tors_zk)
      model%tors_den = cr + gz
      IF (.NOT. (ABS(model%tors_den) > 1.0e-12_wp*(cr + ABS(gz))) .OR. .NOT. CD_Is_Finite(model%tors_den)) THEN
        esx = CD_HCDYN_NOCONVERGE
        emx = 'torsion: the bordered (Sherman-Morrison) tangent is singular'
      END IF
    END SUBROUTINE torsion_factor

    SUBROUTINE torsion_sm_correct()
      !! ws_dq <- ws_dq - z (g . ws_dq)/den: the solve with B turned into one with
      !! B + (1 - af) g g^T / C (Sherman-Morrison), with g, z and den of the current factor.
      REAL(wp) :: mu
      INTEGER :: ii
      mu = DOT_PRODUCT(model%tors_gk, model%ws_dq)/model%tors_den
      DO ii = 1, ndof
        model%ws_dq(ii) = model%ws_dq(ii) - mu*model%tors_zk(ii)
      END DO
    END SUBROUTINE torsion_sm_correct

    SUBROUTINE tw_stage(use_trial)
      !! Nodal twist: the Newmark rates and accelerations of the iterate's (or the trial's)
      !! angles, staged in tw_pe/tw_we for the assembly.
      LOGICAL, INTENT(IN) :: use_trial
      INTEGER :: ii
      REAL(wp) :: p
      DO ii = 1, model%nn
        IF (use_trial) THEN
          p = model%tw_ptrial(ii)
        ELSE
          p = model%tw_pk(ii)
        END IF
        model%tw_ak(ii) = c_a*(p - model%tw_pn(ii)) - c_v*model%tw_wn(ii) - c_a2*model%tw_an(ii)
        model%tw_wk(ii) = model%tw_wn(ii) + dt*((CD_ONE - gm)*model%tw_an(ii) + gm*model%tw_ak(ii))
        model%tw_pe(ii) = p
        model%tw_we(ii) = model%tw_wk(ii)
      END DO
    END SUBROUTINE tw_stage

    SUBROUTINE tw_residual(use_trial)
      !! Nodal twist: the angle rows of the generalised-alpha residual, I ((1 - am) a_{n+1} +
      !! am a_n) + (1 - af) R_phi(n+1) + af R_phi(n) (zero at a held angle), and the
      !! unblended R_phi of the evaluation.
      LOGICAL, INTENT(IN) :: use_trial
      INTEGER :: ii
      REAL(wp) :: gv
      DO ii = 1, model%nn
        gv = CD_ZERO
        IF (model%tw_free(ii)) gv = model%tw_mass(ii)*((CD_ONE - am)*model%tw_ak(ii) + am*model%tw_an(ii)) + &
                                    (CD_ONE - af)*model%tw_R(ii) + af*model%tw_fcR(ii)
        IF (use_trial) THEN
          model%tw_Gt(ii) = gv
          model%tw_Rt(ii) = model%tw_R(ii)
        ELSE
          model%tw_G(ii) = gv
          model%tw_Rk(ii) = model%tw_R(ii)
        END IF
      END DO
    END SUBROUTINE tw_residual

    SUBROUTINE tw_trial(lam)
      !! Nodal twist: the line-search trial angles tw_pk + lam tw_dp.
      REAL(wp), INTENT(IN) :: lam
      INTEGER :: ii
      DO ii = 1, model%nn
        model%tw_ptrial(ii) = model%tw_pk(ii) + lam*model%tw_dp(ii)
      END DO
    END SUBROUTINE tw_trial

    SUBROUTINE tw_accept()
      !! Nodal twist: the accepted trial becomes the iterate.
      INTEGER :: ii
      DO ii = 1, model%nn
        model%tw_pk(ii) = model%tw_ptrial(ii)
        model%tw_G(ii) = model%tw_Gt(ii)
        model%tw_Rk(ii) = model%tw_Rt(ii)
      END DO
    END SUBROUTINE tw_accept

  END SUBROUTINE dyn_step_core

  SUBROUTINE torsion_theta_at(model, q_cfg, ends, theta, ErrStat, ErrMsg)
    !! Theta at q_cfg with end frames ends, unwrapped against the committed Theta; fails when it
    !! moved by more than pi/2 (allocation-free: the model's kernel workspace and tors_gq).
    TYPE(CD_HermiteCableDynType), INTENT(INOUT) :: model
    REAL(wp), INTENT(IN) :: q_cfg(:), ends(3, 4)
    REAL(wp), INTENT(OUT) :: theta
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    REAL(wp) :: raw
    INTEGER :: es
    CHARACTER(1024) :: em
    theta = model%torsion%theta
    CALL CD_HermiteTorsion_Line(q_cfg, model%l0, ends, raw, model%tors_gq, es, em, &
                                couple=model%torsion%couple, quadrature_order=model%torsion%quadrature_order, &
                                work=model%tors_work)
    IF (es /= CD_HTORS_OK) THEN
      ErrStat = CD_HCDYN_NOCONVERGE
      ErrMsg = 'torsion: '//TRIM(em)
      RETURN
    END IF
    theta = CD_HermiteTorsion_Unwrap(raw, model%torsion%theta)
    IF (ABS(theta - model%torsion%theta) > CD_HTORS_MAX_STEP) THEN
      theta = model%torsion%theta
      ErrStat = CD_HCDYN_NOCONVERGE
      ErrMsg = 'torsion: the twist moved more than pi/2 from its committed value in one step; a smaller '// &
               'step resolves it'
      RETURN
    END IF
    ErrStat = CD_HCDYN_OK
    ErrMsg = ''
  END SUBROUTINE torsion_theta_at

  LOGICAL FUNCTION rigid_rays_valid(model, directions, state) RESULT(valid)
    TYPE(CD_HermiteCableDynType), INTENT(IN) :: model
    REAL(wp), INTENT(IN) :: directions(3, 2), state(:)
    INTEGER :: iend, base
    REAL(wp) :: magnitude
    valid = .TRUE.
    DO iend = 1, 2
      IF (model%endconn_mode(iend) /= CD_ENDCONN_RIGID) CYCLE
      IF (iend == 1) THEN
        base = 3
      ELSE
        base = 6*(model%nn - 1) + 3
      END IF
      magnitude = DOT_PRODUCT(state(base + 1:base + 3), directions(:, iend))
      IF (.NOT. CD_Is_Finite(magnitude) .OR. magnitude <= SQRT(TINY(CD_ONE))) THEN
        valid = .FALSE.
        RETURN
      END IF
    END DO
  END FUNCTION rigid_rays_valid

  SUBROUTINE CD_HermiteCable_Dyn_Step_Recovering(model, dt, max_iter, tol, ErrStat, ErrMsg, &
                                                 pres_dofs, pres_q, pres_v, pres_a, max_substeps, &
                                                 endconn_direction, endconn_direction_rate, &
                                                 endconn_direction_acceleration)
    !! Advance one coupling interval of dt, recovering from a non-converged or temporally
    !! under-resolved full step by internal gen-alpha substepping. The common path is ONE call to
    !! CD_HermiteCable_Dyn_Step followed by an O(nn) geometric increment check. A NOCONVERGE return
    !! or an excessive accepted-state increment trips the safety net: restore the step-start
    !! state and re-advance the SAME interval as n substeps of dt/n. Prescribed position, velocity,
    !! and acceleration are joined by one quintic Hermite trajectory, so all three quantities remain
    !! kinematically consistent inside the coupling interval and land exactly on their t+dt targets.
    !!
    !! Subdivision reduces the boundary and load increment seen by each nonlinear solve and sharpens
    !! the Newmark predictor. The host-sampled fluid field and beginning-of-interval added mass remain
    !! fixed within each substep by definition. Landing at t+dt keeps the cable and mooring reactions
    !! at one physical time. Failure at the finest subdivision restores the interval-start state.
    TYPE(CD_HermiteCableDynType), INTENT(INOUT), TARGET :: model
    REAL(wp), INTENT(IN) :: dt, tol
    INTEGER, INTENT(IN) :: max_iter
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    INTEGER, INTENT(IN), OPTIONAL :: pres_dofs(:)
    REAL(wp), INTENT(IN), OPTIONAL :: pres_q(:), pres_v(:), pres_a(:)
    INTEGER, INTENT(IN), OPTIONAL :: max_substeps
    REAL(wp), INTENT(IN), OPTIONAL :: endconn_direction(3, 2)
    REAL(wp), INTENT(IN), OPTIONAL :: endconn_direction_rate(3, 2), endconn_direction_acceleration(3, 2)
    ! Default subdivision ladder: 4, 16, 64, 256, 1024 substeps. A caller may change the final cap;
    ! the geometric ladder itself is fixed, so the recovery cost of the default ladder is unaffected.
    INTEGER, PARAMETER :: DEFAULT_MAX_SUBSTEPS = 1024
    LOGICAL :: has_pres
    INTEGER :: es, nsub, k, ip, np, recovery_cap
    REAL(wp) :: frac, subdt
    REAL(wp), ALLOCATABLE :: q_save(:), v_save(:), a_save(:)
    REAL(wp), ALLOCATABLE :: q0(:), v0(:), a0(:), pq(:), pv(:), pa(:)
    REAL(wp) :: t_save
    REAL(wp) :: d0_save(3, 2), d0_target(3, 2), d0_sub(3, 2)
    REAL(wp) :: d0_rate_save(3, 2), d0_acceleration_save(3, 2)
    REAL(wp) :: d0_rate_target(3, 2), d0_acceleration_target(3, 2)
    REAL(wp) :: d0_rate_sub(3, 2), d0_acceleration_sub(3, 2)
    ! Adaptive-Newton warmup counters mutate inside every successful CD_HermiteCable_Dyn_Step, so they
    ! are part of the interval-start state that a subdivision rewind must restore: a rung that commits
    ! some substeps then diverges would otherwise leave the next rung (or the final failure) running
    ! from the restored physical state but with polluted na_* counters / a flipped modified-Newton mode.
    INTEGER :: na_steps_save
    REAL(wp) :: na_sum_save
    LOGICAL :: na_mn_save
    INTEGER :: tensile_events_save, tensile_element_save
    REAL(wp) :: tensile_force_save, tensile_threshold_save, tensile_xi_save, tensile_time_save
    ! The step-rotation diagnostic must not keep the turn of a step that is rewound.
    REAL(wp) :: rotation_save
    REAL(wp) :: tors_theta0, tors_phi0, tors_phi1, tors_ends0(3, 4), tors_ends1(3, 4), tors_sub(3, 4), tors_torque0
    CHARACTER(1024) :: em
    ! Tensile-qualification failure flag reported by each step (classified by flag, not by
    ! message text, so a short caller buffer cannot change the recovery decision).
    LOGICAL :: tensile_fail

    ! Match the public plain-step contract before touching model-owned snapshot workspace. A default
    ! constructed or already-ended model has no allocated state arrays and must fail closed, not trip
    ! an allocatable access runtime error in the recovery wrapper.
    IF (.NOT. model%initialized) THEN
      ErrStat = CD_HCDYN_BADINPUT
      ErrMsg = 'CD_HermiteCable_Dyn_Step_Recovering: model not initialised'
      RETURN
    END IF
    has_pres = PRESENT(pres_dofs) .AND. PRESENT(pres_q) .AND. PRESENT(pres_v) .AND. PRESENT(pres_a)
    ! Reject a partial prescribed-motion set here too (not just in the underlying step): otherwise a
    ! caller that omits e.g. pres_a makes has_pres false and the common-path call below silently holds
    ! the boundary instead of surfacing the same bad input CD_HermiteCable_Dyn_Step rejects.
    IF ((PRESENT(pres_dofs) .OR. PRESENT(pres_q) .OR. PRESENT(pres_v) .OR. PRESENT(pres_a)) &
        .AND. .NOT. has_pres) THEN
      ErrStat = CD_HCDYN_BADINPUT
      ErrMsg = 'CD_HermiteCable_Dyn_Step_Recovering: prescribed motion needs pres_dofs/q/v/a together'
      RETURN
    END IF
    np = 0
    IF (has_pres) THEN
      np = SIZE(pres_dofs)
      IF (np < 1) THEN
        ErrStat = CD_HCDYN_BADINPUT
        ErrMsg = 'CD_HermiteCable_Dyn_Step_Recovering: pres_dofs must not be empty'
        RETURN
      END IF
    END IF
    recovery_cap = DEFAULT_MAX_SUBSTEPS
    IF (PRESENT(max_substeps)) recovery_cap = max_substeps
    IF (recovery_cap < 4 .OR. recovery_cap > 65536) THEN
      ErrStat = CD_HCDYN_BADINPUT
      ErrMsg = 'CD_HermiteCable_Dyn_Step_Recovering: max_substeps must be in [4,65536]'
      RETURN
    END IF

    d0_save = model%endconn_d0
    d0_target = d0_save
    d0_rate_target = CD_ZERO
    d0_acceleration_target = CD_ZERO
    IF (PRESENT(endconn_direction_rate) .NEQV. PRESENT(endconn_direction_acceleration)) THEN
      ErrStat = CD_HCDYN_BADINPUT
      ErrMsg = 'CD_HermiteCable_Dyn_Step_Recovering: direction rate and acceleration must be supplied together'
      RETURN
    END IF
    IF (PRESENT(endconn_direction_rate) .AND. .NOT. PRESENT(endconn_direction)) THEN
      ErrStat = CD_HCDYN_BADINPUT
      ErrMsg = 'CD_HermiteCable_Dyn_Step_Recovering: direction derivatives require endconn_direction'
      RETURN
    END IF
    IF (PRESENT(endconn_direction)) THEN
      CALL prepare_endconn_directions(model, endconn_direction, d0_target, ErrStat, ErrMsg)
      IF (ErrStat /= CD_HCDYN_OK) THEN
        ErrMsg = 'CD_HermiteCable_Dyn_Step_Recovering: '//TRIM(ErrMsg)
        RETURN
      END IF
      CALL prepare_endconn_derivatives(model, d0_target, d0_rate_target, d0_acceleration_target, &
                                       ErrStat, ErrMsg, endconn_direction_rate, endconn_direction_acceleration)
      IF (ErrStat /= CD_HCDYN_OK) THEN
        ErrMsg = 'CD_HermiteCable_Dyn_Step_Recovering: '//TRIM(ErrMsg)
        RETURN
      END IF
    END IF
    CALL rigid_direction_derivatives_from_state(model, d0_save, model%q, model%v, model%a, &
                                                d0_rate_save, d0_acceleration_save)

    ! Preserve the complete committed state before the full-step attempt in model-owned workspace.
    ! This remains allocation-free on the hot path and makes both genuine Newton failure and a later
    ! quality-gate/subdivision failure atomic. In particular, Step deliberately zeros the history of
    ! fixed DOFs omitted from pres_dofs, so ws_vn/ws_an are not a faithful pre-call snapshot.
    model%ws_recovery_q0 = model%q
    model%ws_recovery_v0 = model%v
    model%ws_recovery_a0 = model%a
    IF (model%fr_active) model%ws_recovery_fr = model%fr_anchor
    IF (model%has_viv) THEN
      model%ws_recovery_viv_phi = model%viv_phi
      model%ws_recovery_viv_ms = model%viv_ms
    END IF
    IF (model%has_ctrl) THEN
      model%ws_recovery_l0_c = model%l0_c
      model%ws_recovery_l0_dot_c = model%l0_dot_c
    END IF
    t_save = model%t
    na_steps_save = model%na_steps_done; na_sum_save = model%na_iter_sum; na_mn_save = model%na_mn_active
    tensile_events_save = model%tensile_event_count
    tensile_element_save = model%tensile_worst_element
    tensile_force_save = model%tensile_worst_force
    tensile_threshold_save = model%tensile_worst_threshold
    tensile_xi_save = model%tensile_worst_xi
    tensile_time_save = model%tensile_worst_time
    rotation_save = model%max_step_rotation
    ! Condensed torsion: the interval-start frames, Phi and Theta, and the interval-end target
    ! (the pending drive, consumed by the full step), for the rewinds and the substep targets.
    tors_theta0 = model%torsion%theta
    tors_phi0 = model%torsion%phi
    tors_ends0 = model%torsion%ends
    tors_torque0 = model%torsion%torque
    IF (model%tw_active) CALL tw_pack(model, model%ws_recovery_tw)
    tors_phi1 = tors_phi0
    tors_ends1 = tors_ends0
    IF (model%torsion%active .AND. model%tors_drive_set) THEN
      tors_phi1 = model%tors_drive_phi
      tors_ends1 = model%tors_drive_ends
    END IF
    ! Common path: one full step. It performs no allocation or snapshot.
    IF (has_pres) THEN
      IF (PRESENT(endconn_direction)) THEN
        CALL CD_HermiteCable_Dyn_Step(model, dt, max_iter, tol, ErrStat, ErrMsg, &
                                      pres_dofs=pres_dofs, pres_q=pres_q, pres_v=pres_v, pres_a=pres_a, &
                                      endconn_direction=d0_target, endconn_direction_rate=d0_rate_target, &
                                      endconn_direction_acceleration=d0_acceleration_target, &
                                      tensile_failed=tensile_fail)
      ELSE
        CALL CD_HermiteCable_Dyn_Step(model, dt, max_iter, tol, ErrStat, ErrMsg, &
                                      pres_dofs=pres_dofs, pres_q=pres_q, pres_v=pres_v, pres_a=pres_a, &
                                      tensile_failed=tensile_fail)
      END IF
    ELSE
      IF (PRESENT(endconn_direction)) THEN
        CALL CD_HermiteCable_Dyn_Step(model, dt, max_iter, tol, ErrStat, ErrMsg, &
                                      endconn_direction=d0_target, endconn_direction_rate=d0_rate_target, &
                                      endconn_direction_acceleration=d0_acceleration_target, &
                                      tensile_failed=tensile_fail)
      ELSE
        CALL CD_HermiteCable_Dyn_Step(model, dt, max_iter, tol, ErrStat, ErrMsg, tensile_failed=tensile_fail)
      END IF
    END IF
    IF (ErrStat == CD_HCDYN_OK) THEN
      IF (temporal_increment_ok(model)) RETURN
      ErrStat = CD_HCDYN_NOCONVERGE
      ErrMsg = 'CD_HermiteCable_Dyn_Step_Recovering: converged full step exceeded the mesh-aware '// &
               'temporal increment limit'
    ELSE IF (tensile_fail) THEN
      ! Spatial subdivision, not temporal subdivision, is required when the
      ! converged interval-end field fails the tensile qualification.  Step has
      ! not committed its candidate state, so return immediately and preserve
      ! the authoritative interval-start state.
      em = ErrMsg
      ErrMsg = 'CD_HermiteCable_Dyn_Step_Recovering: tensile qualification failed: '//TRIM(em)
      RETURN
    ELSE IF (ErrStat /= CD_HCDYN_NOCONVERGE) THEN
      RETURN
    END IF

    ! Recovery and final rollback always use the authoritative pre-call snapshot. The full step may
    ! either have committed a quality-rejected state or left model%q/v/a unchanged after Newton
    ! failure; using one anchor for both paths prevents their failure-atomic semantics from drifting.
    ALLOCATE (q_save(model%ndof), v_save(model%ndof), a_save(model%ndof))
    ALLOCATE (q0(np), v0(np), a0(np), pq(np), pv(np), pa(np))
    IF (prof_enabled) prof_n_alloc = prof_n_alloc + 9
    q_save = model%ws_recovery_q0
    v_save = model%ws_recovery_v0
    a_save = model%ws_recovery_a0
    IF (has_pres) THEN
      DO ip = 1, np
        q0(ip) = q_save(pres_dofs(ip))   ! committed boundary at interval start (local frame)
        v0(ip) = v_save(pres_dofs(ip))
        a0(ip) = a_save(pres_dofs(ip))
      END DO
    END IF

    em = ErrMsg
    nsub = 4
    DO
      subdt = dt/REAL(nsub, wp)
      ! Restore the interval-start state (an earlier rung may have committed some substeps before
      ! diverging on a later one) -- including the adaptive-Newton counters, so each rung starts from
      ! the same warmup state the interval began with.
      model%q = q_save; model%v = v_save; model%a = a_save; model%t = t_save
      model%endconn_d0 = d0_save
      IF (model%fr_active) model%fr_anchor = model%ws_recovery_fr
      IF (model%has_viv) THEN
        model%viv_phi = model%ws_recovery_viv_phi; model%viv_ms = model%ws_recovery_viv_ms
        model%viv_phi_eval = model%viv_phi
      END IF
      IF (model%has_ctrl) model%l0_c = model%ws_recovery_l0_c
      IF (model%has_ctrl) model%l0_dot_c = model%ws_recovery_l0_dot_c
      model%na_steps_done = na_steps_save; model%na_iter_sum = na_sum_save; model%na_mn_active = na_mn_save
      model%tensile_event_count = tensile_events_save
      model%tensile_worst_element = tensile_element_save
      model%tensile_worst_force = tensile_force_save
      model%tensile_worst_threshold = tensile_threshold_save
      model%tensile_worst_xi = tensile_xi_save
      model%tensile_worst_time = tensile_time_save
      model%max_step_rotation = rotation_save
      CALL restore_torsion()
      es = CD_HCDYN_OK
      DO k = 1, nsub
        tensile_fail = .FALSE.
        IF (model%torsion%active) THEN
          frac = REAL(k, wp)/REAL(nsub, wp)
          IF (k == nsub) THEN
            tors_sub = tors_ends1
            model%tors_drive_phi = tors_phi1
          ELSE
            CALL interpolate_torsion_frames(tors_ends0, tors_ends1, frac, tors_sub, es, em)
            IF (es /= CD_HCDYN_OK) EXIT
            model%tors_drive_phi = tors_phi0 + frac*(tors_phi1 - tors_phi0)
          END IF
          model%tors_drive_ends = tors_sub
          model%tors_drive_set = .TRUE.
        END IF
        IF (PRESENT(endconn_direction)) THEN
          frac = REAL(k, wp)/REAL(nsub, wp)
          CALL interpolate_endconn_kinematics(model, d0_save, d0_rate_save, d0_acceleration_save, &
                                              d0_target, d0_rate_target, d0_acceleration_target, dt, frac, &
                                              d0_sub, d0_rate_sub, d0_acceleration_sub, es, em)
          IF (es /= CD_HCDYN_OK) EXIT
        END IF
        IF (has_pres) THEN
          frac = REAL(k, wp)/REAL(nsub, wp)
          CALL quintic_boundary_state(q0, v0, a0, pres_q, pres_v, pres_a, dt, frac, pq, pv, pa)
          ! Avoid endpoint round-off in the polynomial basis. The interior samples remain one C2
          ! trajectory; the final sample is the caller's prescribed state bit for bit.
          IF (k == nsub) THEN
            pq = pres_q; pv = pres_v; pa = pres_a
          END IF
          IF (PRESENT(endconn_direction)) THEN
            CALL CD_HermiteCable_Dyn_Step(model, subdt, max_iter, tol, es, em, &
                                          pres_dofs=pres_dofs, pres_q=pq, pres_v=pv, pres_a=pa, &
                                          endconn_direction=d0_sub, endconn_direction_rate=d0_rate_sub, &
                                          endconn_direction_acceleration=d0_acceleration_sub, &
                                          tensile_failed=tensile_fail)
          ELSE
            CALL CD_HermiteCable_Dyn_Step(model, subdt, max_iter, tol, es, em, &
                                          pres_dofs=pres_dofs, pres_q=pq, pres_v=pv, pres_a=pa, &
                                          tensile_failed=tensile_fail)
          END IF
        ELSE
          IF (PRESENT(endconn_direction)) THEN
            CALL CD_HermiteCable_Dyn_Step(model, subdt, max_iter, tol, es, em, &
                                          endconn_direction=d0_sub, endconn_direction_rate=d0_rate_sub, &
                                          endconn_direction_acceleration=d0_acceleration_sub, &
                                          tensile_failed=tensile_fail)
          ELSE
            CALL CD_HermiteCable_Dyn_Step(model, subdt, max_iter, tol, es, em, tensile_failed=tensile_fail)
          END IF
        END IF
        IF (es == CD_HCDYN_OK) THEN
          IF (.NOT. temporal_increment_ok(model)) THEN
            es = CD_HCDYN_NOCONVERGE
            em = 'substep exceeded mesh-aware temporal increment limit'
          END IF
        END IF
        IF (es /= CD_HCDYN_OK) THEN
          IF (tensile_fail) THEN
            ! Some earlier substeps on this rung may already have committed.
            ! Restore the complete interval-start state before returning.
            model%q = q_save; model%v = v_save; model%a = a_save; model%t = t_save
            model%endconn_d0 = d0_save
            IF (model%fr_active) model%fr_anchor = model%ws_recovery_fr
            IF (model%has_viv) THEN
              model%viv_phi = model%ws_recovery_viv_phi; model%viv_ms = model%ws_recovery_viv_ms
              model%viv_phi_eval = model%viv_phi
            END IF
            IF (model%has_ctrl) model%l0_c = model%ws_recovery_l0_c
            IF (model%has_ctrl) model%l0_dot_c = model%ws_recovery_l0_dot_c
            model%na_steps_done = na_steps_save
            model%na_iter_sum = na_sum_save
            model%na_mn_active = na_mn_save
            model%tensile_event_count = tensile_events_save
            model%tensile_worst_element = tensile_element_save
            model%tensile_worst_force = tensile_force_save
            model%tensile_worst_threshold = tensile_threshold_save
            model%tensile_worst_xi = tensile_xi_save
            model%tensile_worst_time = tensile_time_save
            model%max_step_rotation = rotation_save
            CALL restore_torsion()
            ErrStat = CD_HCDYN_NOCONVERGE
            ErrMsg = 'CD_HermiteCable_Dyn_Step_Recovering: tensile qualification failed during '// &
                     'internal subdivision: '//TRIM(em)
            RETURN
          END IF
          EXIT
        END IF
      END DO
      IF (es == CD_HCDYN_OK) THEN
        IF (prof_enabled) THEN
          !$OMP ATOMIC UPDATE
          prof_n_recover = prof_n_recover + 1
        END IF
        model%recovery_event_count = model%recovery_event_count + 1
        model%recovery_max_substeps_used = MAX(model%recovery_max_substeps_used, nsub)
        ErrStat = CD_HCDYN_OK; ErrMsg = ''
        RETURN
      END IF
      IF (nsub == recovery_cap) EXIT
      IF (nsub > recovery_cap/4) THEN
        nsub = recovery_cap
      ELSE
        nsub = 4*nsub
      END IF
    END DO

    ! Even the finest subdivision diverged: a genuine non-solution (the inexact-tangent residual
    ! plateau at an extreme wave crest, which no step size clears). Fail closed with the interval-start
    ! state restored -- physical state AND adaptive-Newton counters -- so the caller's rollback sees a
    ! consistent step-start.
    model%q = q_save; model%v = v_save; model%a = a_save; model%t = t_save
    model%endconn_d0 = d0_save
    IF (model%fr_active) model%fr_anchor = model%ws_recovery_fr
    IF (model%has_viv) THEN
      model%viv_phi = model%ws_recovery_viv_phi; model%viv_ms = model%ws_recovery_viv_ms
      model%viv_phi_eval = model%viv_phi
    END IF
    IF (model%has_ctrl) model%l0_c = model%ws_recovery_l0_c
    IF (model%has_ctrl) model%l0_dot_c = model%ws_recovery_l0_dot_c
    model%na_steps_done = na_steps_save; model%na_iter_sum = na_sum_save; model%na_mn_active = na_mn_save
    model%tensile_event_count = tensile_events_save
    model%tensile_worst_element = tensile_element_save
    model%tensile_worst_force = tensile_force_save
    model%tensile_worst_threshold = tensile_threshold_save
    model%tensile_worst_xi = tensile_xi_save
    model%tensile_worst_time = tensile_time_save
    model%max_step_rotation = rotation_save
    CALL restore_torsion()
    ErrStat = CD_HCDYN_NOCONVERGE
    BLOCK
      ! Format into a local buffer: a record longer than the caller's ErrMsg
      ! must truncate, not abort the internal write.
      CHARACTER(1024) :: wbuf
      INTEGER :: wios
      wbuf = ''
      IF (has_pres) THEN
        WRITE (wbuf, '(A,ES12.4,A,ES12.4,A,I0,A,ES12.4,A)', IOSTAT=wios) &
          'Cable recovery failed: t=[', t_save, ', ', t_save + dt, '] s; cap=', recovery_cap, &
          '; max prescribed displacement increment=', &
          MAXVAL(ABS(pres_q - q0)), ': '//TRIM(em)
      ELSE
        WRITE (wbuf, '(A,ES12.4,A,ES12.4,A,I0,A)', IOSTAT=wios) &
          'Cable recovery failed: t=[', t_save, ', ', t_save + dt, '] s; cap=', recovery_cap, &
          ': '//TRIM(em)
      END IF
      ErrMsg = wbuf
    END BLOCK

  CONTAINS

    SUBROUTINE restore_torsion()
      !! Interval-start torsion state (frames, Phi, Theta, torque) after a rewind; no pending drive.
      IF (.NOT. model%torsion%active) RETURN
      model%torsion%theta = tors_theta0
      model%torsion%phi = tors_phi0
      model%torsion%ends = tors_ends0
      IF (model%tw_active) CALL tw_unpack(model, model%ws_recovery_tw)
      model%torsion%torque = tors_torque0
      model%tors_drive_set = .FALSE.
    END SUBROUTINE restore_torsion
  END SUBROUTINE CD_HermiteCable_Dyn_Step_Recovering

  SUBROUTINE quintic_boundary_state(q0, v0, a0, q1, v1, a1, duration, u, q, v, a)
    !! C2 trajectory through prescribed position, velocity, and acceleration at both ends of one
    !! coupling interval. u is normalised time in [0,1]; v and a are the exact first and second
    !! time derivatives of q, not independent interpolants.
    REAL(wp), INTENT(IN) :: q0(:), v0(:), a0(:), q1(:), v1(:), a1(:), duration, u
    REAL(wp), INTENT(OUT) :: q(:), v(:), a(:)
    REAL(wp) :: u2, u3, u4, u5, t2

    u2 = u*u; u3 = u2*u; u4 = u3*u; u5 = u4*u
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
  END SUBROUTINE quintic_boundary_state

  SUBROUTINE interpolate_endconn_kinematics(model, d0, v0, a0, d1, v1, a1, duration, fraction, &
                                            d, v, a, ErrStat, ErrMsg)
    !! Interpolate preferred directions during recovery. Finite springs retain
    !! their shortest-arc path; for a rigid end, a Cartesian quintic joins the
    !! complete endpoint states and analytic normalisation restores unit length
    !! plus its first two differential identities at every sample.
    TYPE(CD_HermiteCableDynType), INTENT(IN) :: model
    REAL(wp), INTENT(IN) :: d0(3, 2), v0(3, 2), a0(3, 2), d1(3, 2), v1(3, 2), a1(3, 2)
    REAL(wp), INTENT(IN) :: duration, fraction
    REAL(wp), INTENT(OUT) :: d(3, 2), v(3, 2), a(3, 2)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    INTEGER :: iend
    REAL(wp) :: raw_d(3), raw_v(3), raw_a(3), scale, scale_rate, scale_acceleration

    ErrStat = CD_HCDYN_OK
    ErrMsg = ''
    CALL interpolate_endconn_directions(model, d0, d1, fraction, d, ErrStat, ErrMsg)
    IF (ErrStat /= CD_HCDYN_OK) RETURN
    v = CD_ZERO
    a = CD_ZERO
    DO iend = 1, 2
      ! A finite spring needs only its preferred direction in the residual and
      ! retains the established shortest-arc interpolation above. The complete
      ! C2 direction kinematics below are required only by a rigid tangent.
      IF (model%endconn_mode(iend) /= CD_ENDCONN_RIGID) CYCLE
      CALL quintic_boundary_state(d0(:, iend), v0(:, iend), a0(:, iend), &
                                  d1(:, iend), v1(:, iend), a1(:, iend), &
                                  duration, fraction, raw_d, raw_v, raw_a)
      scale = SQRT(DOT_PRODUCT(raw_d, raw_d))
      IF (.NOT. CD_Is_Finite(scale) .OR. scale <= SQRT(TINY(CD_ONE))) THEN
        ErrStat = CD_HCDYN_BADINPUT
        ErrMsg = 'preferred-direction C2 interpolation is singular'
        RETURN
      END IF
      d(:, iend) = raw_d/scale
      scale_rate = DOT_PRODUCT(d(:, iend), raw_v)
      v(:, iend) = (raw_v - scale_rate*d(:, iend))/scale
      scale_acceleration = (DOT_PRODUCT(raw_v, raw_v) + DOT_PRODUCT(raw_d, raw_a) - &
                            scale_rate*scale_rate)/scale
      a(:, iend) = (raw_a - scale_acceleration*d(:, iend) - 2.0_wp*scale_rate*v(:, iend))/scale
    END DO
    IF (fraction >= CD_ONE) THEN
      d = d1
      v = v1
      a = a1
    END IF
  END SUBROUTINE interpolate_endconn_kinematics

  SUBROUTINE interpolate_torsion_frames(ends0, ends1, fraction, ends, ErrStat, ErrMsg)
    !! Torsion end frames at a fraction of a recovery interval: each end frame (d, n, d x n) turns
    !! from ends0 to ends1 about one fixed axis (the geodesic on SO(3)), by fraction of the angle.
    REAL(wp), INTENT(IN) :: ends0(3, 4), ends1(3, 4), fraction
    REAL(wp), INTENT(OUT) :: ends(3, 4)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    REAL(wp) :: f0(3, 3), f1(3, 3), rq(3, 3), w(3), ang, cth, sk(3, 3), rf(3, 3)
    INTEGER :: k
    ErrStat = CD_HCDYN_OK
    ErrMsg = ''
    ends = ends1
    DO k = 1, 3, 2
      f0(:, 1) = ends0(:, k)
      f0(:, 2) = ends0(:, k + 1)
      f0(:, 3) = tcross(ends0(:, k), ends0(:, k + 1))
      f1(:, 1) = ends1(:, k)
      f1(:, 2) = ends1(:, k + 1)
      f1(:, 3) = tcross(ends1(:, k), ends1(:, k + 1))
      rq = MATMUL(f1, TRANSPOSE(f0))
      cth = MAX(-CD_ONE, MIN(CD_ONE, 0.5_wp*(rq(1, 1) + rq(2, 2) + rq(3, 3) - CD_ONE)))
      ang = ACOS(cth)
      IF (ang > 3.0_wp) THEN
        ErrStat = CD_HCDYN_BADINPUT
        ErrMsg = 'torsion: an end frame turns by nearly 180 degrees within one interval'
        RETURN
      END IF
      w = 0.5_wp*[rq(3, 2) - rq(2, 3), rq(1, 3) - rq(3, 1), rq(2, 1) - rq(1, 2)]
      IF (ang > 1.0e-12_wp) w = w*ang/SIN(ang)
      w = fraction*w
      ang = NORM2(w)
      rf = CD_ZERO
      rf(1, 1) = CD_ONE
      rf(2, 2) = CD_ONE
      rf(3, 3) = CD_ONE
      IF (ang > CD_ZERO) THEN
        sk = RESHAPE([CD_ZERO, w(3), -w(2), -w(3), CD_ZERO, w(1), w(2), -w(1), CD_ZERO], [3, 3])/ang
        rf = rf + SIN(ang)*sk + (CD_ONE - COS(ang))*MATMUL(sk, sk)
      END IF
      ends(:, k) = MATMUL(rf, ends0(:, k))
      ends(:, k + 1) = MATMUL(rf, ends0(:, k + 1))
    END DO
  CONTAINS
    PURE FUNCTION tcross(a, b) RESULT(c)
      REAL(wp), INTENT(IN) :: a(3), b(3)
      REAL(wp) :: c(3)
      c = [a(2)*b(3) - a(3)*b(2), a(3)*b(1) - a(1)*b(3), a(1)*b(2) - a(2)*b(1)]
    END FUNCTION tcross
  END SUBROUTINE interpolate_torsion_frames

  LOGICAL FUNCTION temporal_increment_ok(model) RESULT(ok)
    !! Cheap accepted-step quality gate. Newton convergence proves equilibrium at its discrete
    !! iterate, but not that one coupling interval resolved the nonlinear trajectory. Reject a step
    !! when the chord of any element (the relative position of its two nodes) changes by more
    !! than 20% of its reference length, or a nodal material-tangent direction turns more than
    !! 15 degrees, in one interval. Both measure deformation: a rigid translation of the line,
    !! however fast (a prescribed hang-off drive on short elements), changes neither and is
    !! integrated exactly by the full step, while a large relative nodal motion or a large
    !! local rotation still trips the gate. A separate
    !! geometry floor rejects a nodal |dr/ds| approaching zero: that state is a singular
    !! centreline parametrisation, not a large but admissible cable strain. The 0.01 floor
    !! still permits 99% compression and therefore acts only as a fail-fast corruption guard,
    !! not as a tensile-only constitutive qualification. The increment limits remain
    !! dimensionless and mesh-aware; they impose no cable-specific curvature or load ceiling.
    TYPE(CD_HermiteCableDynType), INTENT(IN) :: model
    REAL(wp), PARAMETER :: POS_FRAC_MAX = 0.20_wp
    REAL(wp), PARAMETER :: COS_TURN_MAX = 0.9659258262890683_wp ! cos(15 deg)
    REAL(wp), PARAMETER :: NORM_FLOOR = 1.0e-12_wp
    REAL(wp), PARAMETER :: MIN_MATERIAL_STRETCH = 1.0e-2_wp
    INTEGER :: i, gi
    REAL(wp) :: dr2, n0, n1, cosine

    ok = .TRUE.
    DO i = 1, model%ne
      gi = 6*(i - 1)
      ! Change of the element chord r_(i+1) - r_i over the interval.
      dr2 = SUM(((model%q(gi + 7:gi + 9) - model%q(gi + 1:gi + 3)) - &
                 (model%ws_qn(gi + 7:gi + 9) - model%ws_qn(gi + 1:gi + 3)))**2)
      IF (.NOT. (dr2 <= (POS_FRAC_MAX*model%l0(i))**2)) THEN
        ok = .FALSE.; RETURN
      END IF
    END DO
    DO i = 1, model%nn
      gi = 6*(i - 1)
      n0 = SQRT(SUM(model%ws_qn(gi + 4:gi + 6)**2))
      n1 = SQRT(SUM(model%q(gi + 4:gi + 6)**2))
      IF (.NOT. CD_Is_Finite(n0) .OR. .NOT. CD_Is_Finite(n1) .OR. &
          n0 <= NORM_FLOOR .OR. n1 < MIN_MATERIAL_STRETCH) THEN
        ok = .FALSE.; RETURN
      END IF
      cosine = DOT_PRODUCT(model%ws_qn(gi + 4:gi + 6), model%q(gi + 4:gi + 6))/(n0*n1)
      IF (cosine < COS_TURN_MAX) THEN
        ok = .FALSE.; RETURN
      END IF
    END DO
  END FUNCTION temporal_increment_ok

  PURE FUNCTION CD_HermiteCable_Dyn_Recovery_Count() RESULT(n)
    !! Coupling intervals of every model that completed only via internal substepping while the
    !! step profile was armed (CD_HermiteCable_Dyn_Reset_Profile), since the last
    !! CD_HermiteCable_Dyn_Recovery_Reset: a process-wide figure of the opt-in profile, like
    !! the other profile counts (a profiled run steps its cables serially). One model's own
    !! count is CD_HermiteCable_Dyn_Get_Recovery_Diagnostics.
    INTEGER :: n
    n = prof_n_recover
  END FUNCTION CD_HermiteCable_Dyn_Recovery_Count

  SUBROUTINE CD_HermiteCable_Dyn_Recovery_Reset()
    !! Zero the profile's substep-recovery count (start of a measured window).
    prof_n_recover = 0
  END SUBROUTINE CD_HermiteCable_Dyn_Recovery_Reset

  SUBROUTINE CD_HermiteCable_Dyn_Energy(model, kinetic, strain, ErrStat, ErrMsg, connection)
    !! Kinetic energy 1/2 v^T M v with the consistent structural mass plus any discrete
    !! attachment's mass and added mass Ca rho V (the line's distributed added mass is fluid
    !! kinetic energy, excluded so the conservation diagnostics track the structure) and total
    !! elastic energy at the current state. The optional
    !! connection output reports the end-spring share already included in strain.
    TYPE(CD_HermiteCableDynType), INTENT(IN) :: model
    REAL(wp), INTENT(OUT) :: kinetic, strain
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    REAL(wp), INTENT(OUT), OPTIONAL :: connection
    INTEGER :: e, es
    REAL(wp) :: qe(12), Ee, fe(12), Ke(12, 12), connection_energy, end_energy
    CHARACTER(1024) :: em2
    ErrStat = CD_HCDYN_OK; ErrMsg = ''; kinetic = CD_ZERO; strain = CD_ZERO
    connection_energy = CD_ZERO
    IF (PRESENT(connection)) connection = CD_ZERO
    IF (.NOT. model%initialized) THEN
      ErrStat = CD_HCDYN_BADINPUT; ErrMsg = 'CD_HermiteCable_Dyn_Energy: model not initialised'; RETURN
    END IF
    BLOCK
      REAL(wp) :: Mv(model%ndof)
      CALL band_matvec(model%Mgb, model%v, Mv)
      kinetic = 0.5_wp*DOT_PRODUCT(model%v, Mv)
    END BLOCK
    DO e = 1, model%ne
      CALL gather_elem(model, e, qe)
      CALL CD_HermiteCable_Element(qe, model%l0(e), model%EA(e), model%EI(e), Ee, fe, Ke, es, em2, &
                                   axial_quadrature_order=model%axial_quadrature_order, &
                                   bending_quadrature_order=model%bending_quadrature_order)
      IF (es /= CD_HCABLE_OK) THEN
        ErrStat = CD_HCDYN_NOCONVERGE; ErrMsg = 'CD_HermiteCable_Dyn_Energy: '//TRIM(em2); RETURN
      END IF
      strain = strain + Ee
    END DO
    IF (model%has_endconn) THEN
      IF (model%endconn_k(1) > CD_ZERO) THEN
        CALL CD_EndConn_Energy(model%q(4:6), model%endconn_d0(:, 1), model%endconn_k(1), &
                               end_energy, es, em2)
        IF (es /= CD_ENDCONN_OK) THEN
          ErrStat = CD_HCDYN_NOCONVERGE
          ErrMsg = 'CD_HermiteCable_Dyn_Energy: node 1 end connection: '//TRIM(em2)
          RETURN
        END IF
        connection_energy = connection_energy + end_energy
      END IF
      IF (model%endconn_k(2) > CD_ZERO) THEN
        CALL CD_EndConn_Energy(model%q(6*(model%nn - 1) + 4:6*(model%nn - 1) + 6), &
                               model%endconn_d0(:, 2), model%endconn_k(2), end_energy, es, em2)
        IF (es /= CD_ENDCONN_OK) THEN
          ErrStat = CD_HCDYN_NOCONVERGE
          ErrMsg = 'CD_HermiteCable_Dyn_Energy: final-node end connection: '//TRIM(em2)
          RETURN
        END IF
        connection_energy = connection_energy + end_energy
      END IF
      strain = strain + connection_energy
    END IF
    IF (model%tw_active) THEN
      ! nodal twist: the element and end-spring energies and the polar kinetic energy, a held
      ! end section's spin chi_dot = -+drho/dw . omega + phi_dot (End 1, End 2) as in its
      ! reaction (CD_HermiteCable_Dyn_EndConnection_Moment)
      BLOCK
        REAL(wp) :: rho, beta, g(12), h(12, 12), tau, psi, gl(3), hl(3, 3), tw, ew(3, 2), ewe(3, 2), spin(2)
        INTEGER :: iend
        ew = CD_ZERO
        DO e = 1, model%ne
          IF (e == 1 .OR. e == model%ne) THEN
            CALL twist_reference(model, e, model%q, model%torsion%ends, .FALSE., rho, beta, g, h, ErrStat, em2, &
                                 end_w=ewe)
            IF (e == 1) ew(:, 1) = ewe(:, 1)
            IF (e == model%ne) ew(:, 2) = ewe(:, 2)
          ELSE
            CALL twist_reference(model, e, model%q, model%torsion%ends, .FALSE., rho, beta, g, h, ErrStat, em2)
          END IF
          IF (ErrStat /= CD_HCDYN_OK) THEN
            ErrMsg = 'CD_HermiteCable_Dyn_Energy: '//TRIM(em2)
            RETURN
          END IF
          tau = model%tw_phi(e + 1) - model%tw_phi(e) + rho
          strain = strain + 0.5_wp*model%torsion%gj(e)/model%l0(e)*tau*tau
        END DO
        DO iend = 1, 2
          IF (.NOT. tw_spring(model, iend)) CYCLE
          CALL twist_link(model, iend, model%q, model%torsion%ends, .FALSE., psi, gl, hl, ErrStat, em2)
          IF (ErrStat /= CD_HCDYN_OK) THEN
            ErrMsg = 'CD_HermiteCable_Dyn_Energy: '//TRIM(em2)
            RETURN
          END IF
          IF (iend == 1) THEN
            tw = model%tw_phi(1) - psi
          ELSE
            tw = psi + model%torsion%phi - model%tw_phi(model%nn)
          END IF
          strain = strain + 0.5_wp*tw*tw/model%torsion%end_compliance(iend)
        END DO
        spin = [model%tw_w(1), model%tw_w(model%nn)]
        IF (model%tw_rigid(1)) spin(1) = spin(1) - DOT_PRODUCT(ew(:, 1), model%tw_om(:, 1))
        IF (model%tw_rigid(2)) spin(2) = spin(2) + DOT_PRODUCT(ew(:, 2), model%tw_om(:, 2))
        kinetic = kinetic + 0.5_wp*SUM(model%tw_mass(2:model%nn - 1)*model%tw_w(2:model%nn - 1)**2) &
                  + 0.5_wp*(model%tw_mass(1)*spin(1)**2 + model%tw_mass(model%nn)*spin(2)**2)
      END BLOCK
    ELSE IF (model%torsion%active) THEN
      BLOCK
        REAL(wp) :: th, mt
        CALL CD_HermiteCable_Dyn_Torsion_State(model, th, mt, ErrStat, em2)
        IF (ErrStat /= CD_HCDYN_OK) THEN
          ErrMsg = 'CD_HermiteCable_Dyn_Energy: '//TRIM(em2)
          RETURN
        END IF
        strain = strain + 0.5_wp*CD_HermiteTorsion_Compliance(model%torsion, model%l0)*mt*mt
      END BLOCK
    END IF
    IF (PRESENT(connection)) connection = connection_energy
  END SUBROUTINE CD_HermiteCable_Dyn_Energy

  SUBROUTINE CD_HermiteCable_Dyn_Momentum(model, p, ErrStat, ErrMsg)
    !! Linear momentum of the line at the current state (solve frame) with the mass matrix of
    !! CD_HermiteCable_Dyn_Energy (the consistent structural mass plus any discrete attachment's
    !! mass and added mass): the sum over the nodes of the translation rows of M v (the position
    !! shape functions of an element sum to one, its tangent ones to zero). A conservation
    !! diagnostic, as the energy.
    TYPE(CD_HermiteCableDynType), INTENT(IN) :: model
    REAL(wp), INTENT(OUT) :: p(3)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    INTEGER :: i
    ErrStat = CD_HCDYN_OK; ErrMsg = ''; p = CD_ZERO
    IF (.NOT. model%initialized) THEN
      ErrStat = CD_HCDYN_BADINPUT; ErrMsg = 'CD_HermiteCable_Dyn_Momentum: model not initialised'; RETURN
    END IF
    BLOCK
      REAL(wp) :: Mv(model%ndof)
      CALL band_matvec(model%Mgb, model%v, Mv)
      DO i = 1, model%nn
        p = p + Mv(6*(i - 1) + 1:6*(i - 1) + 3)
      END DO
    END BLOCK
  END SUBROUTINE CD_HermiteCable_Dyn_Momentum

  SUBROUTINE CD_HermiteCable_Dyn_Curvature(model, curv_out, ErrStat, ErrMsg)
    !! Per-node curvature at the current state, the definition of the Curv<L>N<J> channels: the
    !! bend moment recovered from nodal equilibrium over EI (CD_HermiteCable_Dyn_Node_Recovery),
    !! or, under CD_HermiteCable_Dyn_Set_Output_Recovery(.TRUE.), the larger of the one-sided
    !! values of CD_HermiteCable_Dyn_Side_Curvature.
    TYPE(CD_HermiteCableDynType), INTENT(IN) :: model
    REAL(wp), INTENT(OUT) :: curv_out(:)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    ErrStat = CD_HCDYN_OK; ErrMsg = ''
    IF (model%output_element_recovery) THEN
      CALL CD_HermiteCable_Dyn_Curvature_Exact(model, curv_out, ErrStat, ErrMsg, section=.TRUE.)
      RETURN
    END IF
    IF (.NOT. model%initialized) THEN
      ErrStat = CD_HCDYN_BADINPUT; ErrMsg = 'CD_HermiteCable_Dyn_Curvature: model not initialised'; RETURN
    END IF
    IF (SIZE(curv_out) /= model%nn) THEN
      ErrStat = CD_HCDYN_BADINPUT; ErrMsg = 'CD_HermiteCable_Dyn_Curvature: curv_out must be nn'; RETURN
    END IF
    CALL CD_HermiteCable_Dyn_Node_Recovery(model, ErrStat, ErrMsg, curvature=curv_out)
  END SUBROUTINE CD_HermiteCable_Dyn_Curvature

  SUBROUTINE CD_HermiteCable_Dyn_Curvature_Exact(model, curv_out, ErrStat, ErrMsg, section)
    !! Per-node geometric curvature of the cubic-Hermite centreline at the current state: the
    !! exact curvature of the element interpolation at the node, the larger of the two
    !! one-sided traces at an interior node (the curvature is discontinuous there). With section
    !! .TRUE. the one-sided values are CD_HermiteCable_Dyn_Side_Curvature's, which differ from the
    !! traces only under a bend stiffener.
    TYPE(CD_HermiteCableDynType), INTENT(IN) :: model
    REAL(wp), INTENT(OUT) :: curv_out(:)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    LOGICAL, INTENT(IN), OPTIONAL :: section
    LOGICAL :: to_section
    INTEGER :: a, es
    REAL(wp) :: qe(12), kL, kR
    CHARACTER(1024) :: em2
    ErrStat = CD_HCDYN_OK; ErrMsg = ''
    IF (.NOT. model%initialized) THEN
      ErrStat = CD_HCDYN_BADINPUT; ErrMsg = 'CD_HermiteCable_Dyn_Curvature_Exact: model not initialised'; RETURN
    END IF
    IF (SIZE(curv_out) /= model%nn) THEN
      ErrStat = CD_HCDYN_BADINPUT; ErrMsg = 'CD_HermiteCable_Dyn_Curvature_Exact: curv_out must be nn'; RETURN
    END IF
    to_section = .FALSE.
    IF (PRESENT(section)) to_section = section
    DO a = 1, model%nn
      curv_out(a) = CD_ZERO
      ! A degenerate nodal tangent makes the curvature undefined; propagate that failure rather than
      ! silently reporting zero curvature -- a fatigue assessment reads this channel, so a hidden
      ! zero at a degenerate state would understate the peak sag-bend curvature.
      IF (a <= model%ne) THEN
        IF (to_section) THEN
          CALL CD_HermiteCable_Dyn_Side_Curvature(model, a, a, kR, es, em2)
        ELSE
          CALL gather_elem(model, a, qe)
          CALL CD_HermiteCable_Curvature(qe, model%l0(a), CD_ZERO, kR, es, em2)
        END IF
        IF (es /= CD_HCABLE_OK) THEN
          ErrStat = CD_HCDYN_NOCONVERGE; ErrMsg = 'CD_HermiteCable_Dyn_Curvature_Exact: '//TRIM(em2); RETURN
        END IF
        curv_out(a) = kR
      END IF
      IF (a >= 2) THEN
        IF (to_section) THEN
          CALL CD_HermiteCable_Dyn_Side_Curvature(model, a - 1, a, kL, es, em2)
        ELSE
          CALL gather_elem(model, a - 1, qe)
          CALL CD_HermiteCable_Curvature(qe, model%l0(a - 1), CD_ONE, kL, es, em2)
        END IF
        IF (es /= CD_HCABLE_OK) THEN
          ErrStat = CD_HCDYN_NOCONVERGE; ErrMsg = 'CD_HermiteCable_Dyn_Curvature_Exact: '//TRIM(em2); RETURN
        END IF
        curv_out(a) = MAX(curv_out(a), kL)
      END IF
    END DO
  END SUBROUTINE CD_HermiteCable_Dyn_Curvature_Exact

  PURE FUNCTION CD_HermiteCable_Dyn_Side_EI(model, e, node) RESULT(ei)
    !! The bending stiffness of the section at node (e or e + 1), on the side of its element e:
    !! on a stiffened line the limit of EI(s) there (EI_node), else the element's EI. An element
    !! without bending stiffness keeps its zero.
    TYPE(CD_HermiteCableDynType), INTENT(IN) :: model
    INTEGER, INTENT(IN) :: e, node
    REAL(wp) :: ei
    ei = model%EI(e)
    IF (.NOT. ALLOCATED(model%EI_node) .OR. .NOT. ei > CD_ZERO) RETURN
    IF (model%EI_node(MERGE(2, 1, node == e), node) > CD_ZERO) ei = model%EI_node(MERGE(2, 1, node == e), node)
  END FUNCTION CD_HermiteCable_Dyn_Side_EI

  PURE FUNCTION trace_scale(model, e, node) RESULT(scale)
    !! What turns the curvature of element e's interpolation at node (e or e + 1) into the
    !! curvature of the section there: the element bends under one stiffness, so its curvature is
    !! the moment over that EI, and the section takes the same moment over its own stiffness.
    !! Exactly 1 wherever the two agree, as on every element without a bend stiffener.
    TYPE(CD_HermiteCableDynType), INTENT(IN) :: model
    INTEGER, INTENT(IN) :: e, node
    REAL(wp) :: scale
    scale = CD_ONE
    IF (ALLOCATED(model%EI_node) .AND. model%EI(e) > CD_ZERO) &
      scale = model%EI(e)/CD_HermiteCable_Dyn_Side_EI(model, e, node)
  END FUNCTION trace_scale

  SUBROUTINE CD_HermiteCable_Dyn_Side_Curvature(model, e, node, curvature, ErrStat, ErrMsg, kvec)
    !! The one-sided curvature of element output recovery at node (e or e + 1), on the side of
    !! element e: the exact trace of the element's interpolation. Under a bend stiffener that
    !! trace is the moment over the element's one stiffness, which is no section's: the element
    !! then reports what the section has there, the recovered moment over EI(s), as the
    !! equilibrium recovery does, and its scaled trace on a section too soft to recover the
    !! moment. kvec, when asked for, is the curvature vector kappa n. Read-only.
    TYPE(CD_HermiteCableDynType), INTENT(IN) :: model
    INTEGER, INTENT(IN) :: e, node
    REAL(wp), INTENT(OUT) :: curvature
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    REAL(wp), INTENT(OUT), OPTIONAL :: kvec(3)
    REAL(wp) :: qe(12), g(12), fm(3), mm(3), fp(3), mp(3), mv(3), kv(3), ei, ten, kap, bend
    LOGICAL :: sleeved

    ErrStat = CD_HCDYN_OK; ErrMsg = ''
    sleeved = .FALSE.
    IF (ALLOCATED(model%EI_node)) sleeved = model%EI(e) > CD_ZERO .AND. ABS(model%EI_line(e) - model%EI(e)) > CD_ZERO
    ei = CD_HermiteCable_Dyn_Side_EI(model, e, node)
    IF (.NOT. sleeved .OR. ei < model%ei_resolve) THEN
      CALL gather_elem(model, e, qe)
      CALL CD_HermiteCable_Curvature(qe, model%l0(e), REAL(node - e, wp), curvature, ErrStat, ErrMsg, kvec=kv)
      IF (ErrStat /= CD_HCABLE_OK) RETURN
      IF (sleeved) THEN
        curvature = curvature*trace_scale(model, e, node)
        kv = kv*trace_scale(model, e, node)
      END IF
      IF (PRESENT(kvec)) kvec = kv
      RETURN
    END IF
    fm = CD_ZERO; mm = CD_ZERO; fp = CD_ZERO; mp = CD_ZERO
    IF (node > 1) THEN
      CALL element_end_residual(model, node - 1, g, ErrStat, ErrMsg)
      IF (ErrStat /= CD_HCDYN_OK) RETURN
      fm = g(7:9); mm = g(10:12)
    END IF
    IF (node < model%nn) THEN
      CALL element_end_residual(model, node, g, ErrStat, ErrMsg)
      IF (ErrStat /= CD_HCDYN_OK) RETURN
      fp = -g(1:3); mp = -g(4:6)
    END IF
    CALL node_values(model, node, fm, mm, fp, mp, ten, kap, bend, ErrStat, ErrMsg, moment_vector=mv)
    IF (ErrStat /= CD_HCDYN_OK) RETURN
    curvature = node_stretch(model, node)*NORM2(mv)/ei
    IF (PRESENT(kvec)) kvec = node_stretch(model, node)*mv/ei
  END SUBROUTINE CD_HermiteCable_Dyn_Side_Curvature

  SUBROUTINE CD_HermiteCable_Dyn_Section_Curvature(model, ref_a, kx, ky, ErrStat, ErrMsg, frame)
    !! The two components of the nodal curvature vector on the cross-section axes (the channels
    !! CurvX<L>N<J>, CurvY<L>N<J>), in internal node order (node nn is End A). The curvature
    !! vector kappa n points to the centre of curvature and its length is the curvature of
    !! CD_HermiteCable_Dyn_Curvature: the recovered section moment over EI on the side that
    !! gives it (CD_HermiteCable_Dyn_Node_Recovery), or the larger one-sided element curvature
    !! under element output recovery (CD_HermiteCable_Dyn_Side_Curvature).
    !!
    !! The section axes: d1 at End A is the reference normal -- the End A torsion normal on a
    !! line restrained in torsion, else ref_a (solve frame) -- made normal to the End A tangent.
    !! It is carried to every node by parallel transport along the centreline, NSUB smallest
    !! rotations per element between the Hermite tangents, and on a line in torsion turned
    !! about the tangent by the twist from End A: the torque times the End A compliance plus
    !! l0/GJ summed from End A, right-handed about the End A -> End B tangent t. d2 = t x d1,
    !! kx = kappa n . d1 and ky = kappa n . d2; frame(:, j), when asked for, is d1 at node j.
    !! Read-only.
    TYPE(CD_HermiteCableDynType), INTENT(IN) :: model
    REAL(wp), INTENT(IN) :: ref_a(3)
    REAL(wp), INTENT(OUT) :: kx(:), ky(:)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    REAL(wp), INTENT(OUT), OPTIONAL :: frame(:, :)
    INTEGER, PARAMETER :: NSUB = 8
    REAL(wp) :: kvec(3, model%nn), qe(12), kv(3), kl, kr, d1(3), d(3), t(3), tp(3), tq(3), H(4), dH(4)
    REAL(wp) :: r(3), rn, th, mt, comp, phi
    INTEGER :: a, e, k, es
    CHARACTER(1024) :: em2

    ErrStat = CD_HCDYN_OK; ErrMsg = ''
    kx = CD_ZERO
    ky = CD_ZERO
    IF (.NOT. model%initialized) THEN
      ErrStat = CD_HCDYN_BADINPUT; ErrMsg = 'CD_HermiteCable_Dyn_Section_Curvature: model not initialised'; RETURN
    END IF
    IF (SIZE(kx) /= model%nn .OR. SIZE(ky) /= model%nn) THEN
      ErrStat = CD_HCDYN_BADINPUT; ErrMsg = 'CD_HermiteCable_Dyn_Section_Curvature: kx, ky must be nn'; RETURN
    END IF
    IF (PRESENT(frame)) THEN
      IF (SIZE(frame, 1) /= 3 .OR. SIZE(frame, 2) /= model%nn) THEN
        ErrStat = CD_HCDYN_BADINPUT; ErrMsg = 'CD_HermiteCable_Dyn_Section_Curvature: frame must be (3, nn)'; RETURN
      END IF
      frame = CD_ZERO
    END IF
    IF (model%output_element_recovery) THEN
      ! the larger one-sided element curvature and its vector, in section form
      DO a = 1, model%nn
        kvec(:, a) = CD_ZERO
        kl = -CD_ONE
        IF (a <= model%ne) THEN
          CALL CD_HermiteCable_Dyn_Side_Curvature(model, a, a, kr, es, em2, kvec=kv)
          IF (es /= CD_HCABLE_OK) THEN
            ErrStat = CD_HCDYN_NOCONVERGE; ErrMsg = 'CD_HermiteCable_Dyn_Section_Curvature: '//TRIM(em2); RETURN
          END IF
          kvec(:, a) = kv
          kl = kr
        END IF
        IF (a >= 2) THEN
          CALL CD_HermiteCable_Dyn_Side_Curvature(model, a - 1, a, kr, es, em2, kvec=kv)
          IF (es /= CD_HCABLE_OK) THEN
            ErrStat = CD_HCDYN_NOCONVERGE; ErrMsg = 'CD_HermiteCable_Dyn_Section_Curvature: '//TRIM(em2); RETURN
          END IF
          IF (kr > kl) kvec(:, a) = kv
        END IF
      END DO
    ELSE
      CALL CD_HermiteCable_Dyn_Node_Recovery(model, ErrStat, ErrMsg, curvature_vector=kvec)
      IF (ErrStat /= CD_HCDYN_OK) RETURN
    END IF
    ! d1 at End A, normal to the End A -> End B tangent there
    IF (model%torsion%active) THEN
      r = model%torsion%ends(:, 4)
    ELSE
      r = ref_a
    END IF
    t = -unit_tangent(model, model%nn)
    d1 = r - DOT_PRODUCT(r, t)*t
    rn = NORM2(d1)
    ! (a free End A's torsion frame is a gauge: its section is the material director below)
    IF (.NOT. rn > 1.0e-6_wp*MAX(NORM2(r), TINY(CD_ONE)) .AND. .NOT. (model%tw_active .AND. &
                                                                      model%torsion%end_free(2))) THEN
      ErrStat = CD_HCDYN_BADINPUT
      ErrMsg = 'CD_HermiteCable_Dyn_Section_Curvature: the section reference lies along the End A tangent'; RETURN
    END IF
    IF (rn > CD_ZERO) d1 = d1/rn
    IF (model%tw_active) THEN
      ! Nodal twist: the material director Rot(t_k, phi - Phi) u of every node (t_k the solve
      ! tangent, End 1 -> End 2), on the frame convention above: End A (node nn) takes the
      ! reference normal turned by the End A spring twist only.
      DO a = 1, model%nn
        t = -unit_tangent(model, a)
        phi = model%tw_phi(a) - model%torsion%phi
        d = COS(phi)*model%tw_u(:, a) - SIN(phi)*cross3_local(t, model%tw_u(:, a))
        IF (PRESENT(frame)) frame(:, a) = d
        kx(a) = DOT_PRODUCT(kvec(:, a), d)
        ky(a) = DOT_PRODUCT(kvec(:, a), cross3_local(t, d))
      END DO
      RETURN
    END IF
    mt = CD_ZERO
    comp = CD_ZERO
    IF (model%torsion%active) THEN
      CALL CD_HermiteCable_Dyn_Torsion_State(model, th, mt, ErrStat, ErrMsg)
      IF (ErrStat /= CD_HCDYN_OK) RETURN
      comp = mt*model%torsion%end_compliance(2)
    END IF
    DO a = model%nn, 1, -1
      IF (a < model%nn) THEN
        ! carry d1 from node a + 1 to node a along element a (xi from 1 to 0)
        e = a
        CALL gather_elem(model, e, qe)
        tp = t
        DO k = NSUB - 1, 0, -1
          CALL CD_HermiteCable_Shapes(REAL(k, wp)/REAL(NSUB, wp), model%l0(e), H, dH)
          tq = -(dH(1)*qe(1:3) + dH(2)*qe(4:6) + dH(3)*qe(7:9) + dH(4)*qe(10:12))
          rn = NORM2(tq)
          IF (.NOT. rn > CD_ZERO) THEN
            ErrStat = CD_HCDYN_NOCONVERGE
            ErrMsg = 'CD_HermiteCable_Dyn_Section_Curvature: degenerate centreline tangent'; RETURN
          END IF
          tq = tq/rn
          d1 = rotate_onto(tp, tq, d1)
          tp = tq
        END DO
        t = -unit_tangent(model, a)
        d1 = d1 - DOT_PRODUCT(d1, t)*t
        d1 = d1/NORM2(d1)
        IF (model%torsion%active) comp = comp + element_twist(model, e, mt)
      END IF
      phi = comp
      d = COS(phi)*d1 + SIN(phi)*cross3_local(t, d1)
      IF (PRESENT(frame)) frame(:, a) = d
      kx(a) = DOT_PRODUCT(kvec(:, a), d)
      ky(a) = DOT_PRODUCT(kvec(:, a), cross3_local(t, d))
    END DO

  CONTAINS

    PURE FUNCTION rotate_onto(u, w, v) RESULT(rv)
      !! The smallest rotation taking unit u to unit w, applied to v.
      REAL(wp), INTENT(IN) :: u(3), w(3), v(3)
      REAL(wp) :: rv(3), c, x(3)
      c = DOT_PRODUCT(u, w)
      x = cross3_local(u, w)
      rv = c*v + cross3_local(x, v) + x*DOT_PRODUCT(x, v)/(CD_ONE + c)
    END FUNCTION rotate_onto

    PURE FUNCTION cross3_local(u, w) RESULT(x)
      REAL(wp), INTENT(IN) :: u(3), w(3)
      REAL(wp) :: x(3)
      x = [u(2)*w(3) - u(3)*w(2), u(3)*w(1) - u(1)*w(3), u(1)*w(2) - u(2)*w(1)]
    END FUNCTION cross3_local
  END SUBROUTINE CD_HermiteCable_Dyn_Section_Curvature

  SUBROUTINE CD_HermiteCable_Dyn_Reaction(model, node, freac, ErrStat, ErrMsg, full_assembly)
    !! Constraint reaction at a fixed/prescribed node: the force the LINE exerts ON its
    !! support (fairlead/anchor) at the current committed state, in global coordinates.
    !!
    !! At a fixed translational DOF the equation of motion is not solved; the support
    !! supplies whatever generalized force closes it. With G = M a + f_int - f_ext
    !! evaluated at the committed (q, v, a, t), the support applies +G(dof) TO the line,
    !! so the line applies -G(dof) to the support -- the fairlead load an outer solver
    !! (the OpenFAST FMF coupling) needs. The total mass (structural + added) is
    !! REASSEMBLED here at the committed configuration from the model's current public
    !! fields rather than read from the ws_Msumb scratch: that scratch is only "last
    !! populated by Init / Step / setter refreshes", and a failed transactional hydro
    !! reconfiguration rolls the public fields back while leaving it partially
    !! refreshed -- a stale-mass hazard this output must not inherit.
    !! Meaningful at nodes whose translations are fixed or prescribed; at a free node the
    !! same expression returns the residual (~0 at convergence), not a support load.
    TYPE(CD_HermiteCableDynType), INTENT(INOUT) :: model
    INTEGER, INTENT(IN) :: node
    REAL(wp), INTENT(OUT) :: freac(3)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    ! .TRUE.: evaluate from the full assembly, the reference the node's rows reproduce bit for bit
    LOGICAL, INTENT(IN), OPTIONAL :: full_assembly
    INTEGER :: es, gi
    LOGICAL :: full
    CHARACTER(1024) :: em2
    ErrStat = CD_HCDYN_OK; ErrMsg = ''; freac = CD_ZERO
    full = .FALSE.
    IF (PRESENT(full_assembly)) full = full_assembly
    IF (.NOT. model%initialized) THEN
      ErrStat = CD_HCDYN_BADINPUT; ErrMsg = 'CD_HermiteCable_Dyn_Reaction: model not initialised'; RETURN
    END IF
    IF (node < 1 .OR. node > model%nn) THEN
      ErrStat = CD_HCDYN_BADINPUT; ErrMsg = 'CD_HermiteCable_Dyn_Reaction: node out of range'; RETURN
    END IF
    ! Only the node's rows are needed: assemble them from the elements that reach the node
    ! (bit-identical to the full assembly below, which torsion still needs).
    IF (.NOT. (model%torsion%active .OR. full)) THEN
      CALL node_reaction(model, node, freac, es, em2)
      IF (es /= CD_HCDYN_OK) THEN
        freac = CD_ZERO
        ErrStat = es; ErrMsg = 'CD_HermiteCable_Dyn_Reaction: '//TRIM(em2)
      END IF
      RETURN
    END IF
    ! Residual-only assembly at the committed state: no tangent buffer is touched, so the
    ! committed K/Kv (which callers may still hold between steps) are preserved.
    CALL assemble_residual(model, model%q, model%v, model%t, .TRUE., .FALSE., es, em2)
    IF (es /= CD_HCDYN_OK) THEN
      ErrStat = es; ErrMsg = 'CD_HermiteCable_Dyn_Reaction: '//TRIM(em2); RETURN
    END IF
    ! rebuild the total mass from the CURRENT fields at the committed configuration
    model%ws_Msumb = model%Mgb
    IF (model%has_am) THEN
      CALL assemble_added_mass(model, model%q, es, em2)
      IF (es /= CD_HCDYN_OK) THEN
        ErrStat = es; ErrMsg = 'CD_HermiteCable_Dyn_Reaction: '//TRIM(em2); RETURN
      END IF
      model%ws_Msumb = model%ws_Msumb + model%ws_Mamb
    END IF
    CALL band_matvec(model%ws_Msumb, model%a, model%ws_inert)
    gi = 6*(node - 1)
    freac = -(model%ws_inert(gi + 1:gi + 3) + model%ws_R(gi + 1:gi + 3))
  END SUBROUTINE CD_HermiteCable_Dyn_Reaction

  SUBROUTINE node_reaction(model, node, freac, ErrStat, ErrMsg, tangent_rows)
    !! CD_HermiteCable_Dyn_Reaction from the node's rows only: the residual of the one or two
    !! elements that reach the node and of its nodal terms (assemble_residual node_only), and
    !! the node's rows of the total mass times the acceleration, with the added mass of those
    !! elements. Every row term is formed and summed in the order of the full assembly and of
    !! band_matvec, so the reaction is bit-identical, at the cost of one or two elements
    !! instead of the line, and the model's scratch is not touched. Not for a line with
    !! torsion, which couples every element. tangent_rows = .TRUE. returns the node's three
    !! material-tangent rows instead of its translational ones (a rigid end connection).
    TYPE(CD_HermiteCableDynType), INTENT(INOUT) :: model
    INTEGER, INTENT(IN) :: node
    REAL(wp), INTENT(OUT) :: freac(3)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    LOGICAL, INTENT(IN), OPTIONAL :: tangent_rows
    REAL(wp) :: Rn(SIZE(model%ws_R)), Me(12, 12), mam(3, -KL_D:KU_D), inert(3), m
    INTEGER :: e, a, b, k, gi, gj, j, n, es
    CHARACTER(1024) :: em

    ErrStat = CD_HCDYN_OK; ErrMsg = ''; freac = CD_ZERO
    CALL assemble_residual(model, model%q, model%v, model%t, .TRUE., .FALSE., es, em, node_only=node, R_out=Rn)
    IF (es /= CD_HCDYN_OK) THEN
      ErrStat = es; ErrMsg = TRIM(em); RETURN
    END IF
    gi = 6*(node - 1)
    IF (PRESENT(tangent_rows)) THEN
      IF (tangent_rows) gi = gi + 3
    END IF
    n = SIZE(model%a)
    ! the node's rows of the added mass, mam(k, j - (gi + k)) = Mamb(gi + k, j), summed element
    ! by element from zero as assemble_added_mass scatters them
    mam = CD_ZERO
    IF (model%has_am) THEN
      DO e = MAX(1, node - 1), MIN(model%ne, node)
        CALL added_mass_element(model, model%q, e, Me, es, em)
        IF (es /= CD_HCDYN_OK) THEN
          ErrStat = es; ErrMsg = TRIM(em); RETURN
        END IF
        DO a = 1, 12
          k = elem_gdof(e, a) - gi
          IF (k < 1 .OR. k > 3) CYCLE
          DO b = 1, 12
            gj = elem_gdof(e, b)
            mam(k, gj - (gi + k)) = mam(k, gj - (gi + k)) + Me(a, b)
          END DO
        END DO
      END DO
      IF (.NOT. CD_All_Finite(mam)) THEN
        ErrStat = CD_HCDYN_NOCONVERGE; ErrMsg = 'assemble_added_mass: non-finite global added-mass matrix'; RETURN
      END IF
    END IF
    ! (Mgb + Mamb) a on the node's rows, column by column as band_matvec accumulates them
    inert = CD_ZERO
    DO j = MAX(1, gi + 1 - KL_D), MIN(n, gi + 3 + KU_D)
      DO k = 1, 3
        IF (j < gi + k - KL_D .OR. j > gi + k + KU_D) CYCLE
        m = model%Mgb(KL_D + KU_D + 1 + gi + k - j, j)
        IF (model%has_am) m = m + mam(k, j - (gi + k))
        inert(k) = inert(k) + m*model%a(j)
      END DO
    END DO
    freac = -(inert + Rn(gi + 1:gi + 3))
  END SUBROUTINE node_reaction

  SUBROUTINE CD_HermiteCable_Dyn_End_Force(model, node, force, ErrStat, ErrMsg)
    !! Force the line exerts on the point holding its end node (node = 1 or nn) at the
    !! committed state (q, v): the end element's internal force (elastic plus Kelvin-Voigt
    !! axial damping) plus the end node's share of the distributed external loads --
    !! consistent submerged weight, dry-part buoyancy above the free surface, seabed contact
    !! normal force with its damping, and the drag of the ambient fluid (current, waves or
    !! held host field) at the actual relative velocity, and the weight, buoyancy,
    !! Froude-Krylov force and drag of any discrete attachment on the end node -- i.e.
    !! f_ext - f_int at the node. This is the actual force on the attachment, the EI = 0 lines' CD_Get_Model_EndForces
    !! quantity; inertia (and seabed friction) stay in the coupled load
    !! (CD_HermiteCable_Dyn_Reaction). At rest it is the static end reaction. Read-only: no
    !! model buffer is written.
    TYPE(CD_HermiteCableDynType), INTENT(IN) :: model
    INTEGER, INTENT(IN) :: node
    REAL(wp), INTENT(OUT) :: force(3)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    REAL(wp), PARAMETER :: PI_L = 3.14159265358979323846_wp
    REAL(wp) :: qe(12), ve(12), fe(12), fdrag(12), fdamp(12), energy, fdry(4), kdry(4, 4), r3(3), gate, gate_gap
    REAL(wp) :: dry_wl, dry_b, dry_r, gap, normal, normal_gap, z_floor, xg, yg, gxg, gyg
    REAL(wp) :: gx, gy, sfac, nvec(3), vn, rk(3), jrel(3, 3), jtan(3, 3), fn, wt(3)
    REAL(wp) :: curv_e(3), fcrease_e(3), kcrease_e(3, 3)
    INTEGER :: e, i0, iz, zslot, es, k
    LOGICAL :: dry, has_jac
    CHARACTER(1024) :: em2

    ErrStat = CD_HCDYN_OK; ErrMsg = ''; force = CD_ZERO; gap = -HUGE(CD_ONE); nvec = [CD_ZERO, CD_ZERO, CD_ONE]
    IF (.NOT. model%initialized) THEN
      ErrStat = CD_HCDYN_BADINPUT; ErrMsg = 'CD_HermiteCable_Dyn_End_Force: model not initialised'; RETURN
    END IF
    IF (node /= 1 .AND. node /= model%nn) THEN
      ErrStat = CD_HCDYN_BADINPUT; ErrMsg = 'CD_HermiteCable_Dyn_End_Force: node must be a line end'; RETURN
    END IF
    IF (node == 1) THEN
      e = 1; i0 = 0; zslot = 1
    ELSE
      e = model%ne; i0 = 6; zslot = 3
    END IF
    qe(1:6) = model%q(6*(e - 1) + 1:6*e)
    qe(7:12) = model%q(6*e + 1:6*(e + 1))
    ve(1:6) = model%v(6*(e - 1) + 1:6*e)
    ve(7:12) = model%v(6*e + 1:6*(e + 1))
    ! R = f_int - f_ext at the end node's translations, accumulated below.
    CALL CD_HermiteCable_Element(qe, model%l0(e), model%EA(e), model%EI(e), energy, fe, ErrStat=es, ErrMsg=em2, &
                                 axial_quadrature_order=model%axial_quadrature_order, &
                                 bending_quadrature_order=model%bending_quadrature_order)
    IF (es /= CD_HCABLE_OK) THEN
      ErrStat = CD_HCDYN_NOCONVERGE; ErrMsg = 'CD_HermiteCable_Dyn_End_Force: '//TRIM(em2); RETURN
    END IF
    r3 = fe(i0 + 1:i0 + 3)
    IF (model%has_axial_damping) THEN
      IF (model%has_ctrl) THEN
        CALL CD_HermiteCable_Axial_Damping_Element(qe, ve, model%l0(e), model%BA(e), fdamp, ErrStat=es, ErrMsg=em2, &
                                                   quadrature_order=model%axial_quadrature_order, &
                                                   l0_dot=model%l0_dot(e))
      ELSE
        CALL CD_HermiteCable_Axial_Damping_Element(qe, ve, model%l0(e), model%BA(e), fdamp, ErrStat=es, ErrMsg=em2, &
                                                   quadrature_order=model%axial_quadrature_order)
      END IF
      IF (es /= CD_HCDYN_OK) THEN
        ErrStat = CD_HCDYN_NOCONVERGE; ErrMsg = 'CD_HermiteCable_Dyn_End_Force: '//TRIM(em2); RETURN
      END IF
      r3 = r3 + fdamp(i0 + 1:i0 + 3)
    END IF
    r3(3) = r3(3) + model%w(e)*0.5_wp*model%l0(e)
    IF (model%has_drag .OR. model%has_am) THEN
      IF (model%has_drag) THEN
        dry_wl = model%waterline_z
        dry_b = model%rho_w*model%gravity*0.25_wp*PI_L*model%diam(e)**2
        dry_r = 0.5_wp*model%diam(e)
      ELSE
        dry_wl = model%am_wl
        dry_b = model%am_rho*model%gravity*0.25_wp*PI_L*model%am_diam(e)**2
        dry_r = 0.5_wp*model%am_diam(e)
      END IF
      IF (model%has_held_field) dry_wl = 0.5_wp*(model%hf_wl(e) + model%hf_wl(e + 1))
      CALL CD_HermiteCable_Dry_Buoyancy(qe([3, 6, 9, 12]), model%l0(e), dry_b, dry_wl, fdry, kdry, dry, &
                                        radius=dry_r)
      IF (dry) r3(3) = r3(3) + fdry(zslot)
    END IF
    iz = 6*(node - 1) + 3
    IF (model%has_contact) THEN
      z_floor = model%seabed_z
      gx = CD_ZERO
      gy = CD_ZERO
      IF (model%has_contact_bathymetry) THEN
        xg = model%contact_frame_c*model%q(iz - 2) - model%contact_frame_s*model%q(iz - 1)
        yg = model%contact_frame_s*model%q(iz - 2) + model%contact_frame_c*model%q(iz - 1)
        CALL CD_Bathymetry_Floor_Gradient(model%contact_bathymetry, xg, yg, z_floor, gxg, gyg, es, em2, &
                                          crease_curvature=curv_e)
        IF (es /= CD_BATHY_OK) THEN
          ErrStat = CD_HCDYN_NOCONVERGE; ErrMsg = 'CD_HermiteCable_Dyn_End_Force: '//TRIM(em2); RETURN
        END IF
        gx = model%contact_frame_c*gxg + model%contact_frame_s*gyg
        gy = -model%contact_frame_s*gxg + model%contact_frame_c*gyg
        ! the elastic force in a rounded crease (see assemble_contact)
        IF (ANY(ABS(curv_e) > CD_ZERO)) THEN
          CALL crease_contact_increment(z_floor - model%q(iz), gx, gy, model%contact_kn(node), &
                                        CD_Bathymetry_Rotate_Curvature(curv_e, [model%contact_frame_c, &
                                                                                model%contact_frame_s]), &
                                        fcrease_e, kcrease_e)
          r3 = r3 - fcrease_e
        END IF
      END IF
      ! frictionless: along the upward floor normal, at the normal penetration and velocity
      sfac = SQRT(CD_ONE + gx*gx + gy*gy)
      nvec = [-gx, -gy, CD_ONE]/sfac
      gap = (z_floor - model%q(iz))/sfac
      CALL CD_Seabed_Normal_Law(gap, model%contact_kn(node), normal, normal_gap)
      vn = DOT_PRODUCT(model%v(iz - 2:iz), nvec)
      IF (ALLOCATED(model%contact_cn) .AND. vn < CD_ZERO) THEN
        CALL CD_Seabed_Contact_Gate(gap, gate, gate_gap)
        normal = normal - model%contact_cn(node)*gate*vn
      END IF
      r3 = r3 - normal*nvec
    ELSE IF (model%kn > CD_ZERO) THEN
      gap = model%seabed_z - model%q(iz)
      IF (gap > CD_ZERO) r3(3) = r3(3) - model%kn*gap*model%trib(node)
    END IF
    IF (model%has_drag) THEN
      IF (model%has_wave .AND. model%wv_ncomp > 0) THEN
        CALL CD_HermiteCable_Drag_Element(qe, ve, model%l0(e), model%current, model%waterline_z, &
                                          model%rho_w, model%diam(e), model%cdn(e), model%cdt(e), &
                                          fdrag, ErrStat=es, ErrMsg=em2, &
                                          wv_depth=model%wv_depth, wv_dir=model%wv_dir, wv_t=model%t, &
                                          wvc_amp=model%wv_ampc, wvc_om=model%wv_omc, &
                                          wvc_k=model%wv_kc, wvc_ph=model%wv_phc, &
                                          wvc_e2kd=model%wv_e2kd)
      ELSE IF (model%has_wave) THEN
        CALL CD_HermiteCable_Drag_Element(qe, ve, model%l0(e), model%current, model%waterline_z, &
                                          model%rho_w, model%diam(e), model%cdn(e), model%cdt(e), &
                                          fdrag, ErrStat=es, ErrMsg=em2, &
                                          wv_h=model%wv_h, wv_om=model%wv_om, wv_k=model%wv_k, &
                                          wv_depth=model%wv_depth, wv_dir=model%wv_dir, wv_t=model%t)
      ELSE IF (model%has_held_field) THEN
        CALL CD_HermiteCable_Drag_Element(qe, ve, model%l0(e), &
                                          model%current + 0.5_wp*(model%hf_u(:, e) + model%hf_u(:, e + 1)), &
                                          0.5_wp*(model%hf_wl(e) + model%hf_wl(e + 1)), &
                                          model%rho_w, model%diam(e), model%cdn(e), model%cdt(e), &
                                          fdrag, ErrStat=es, ErrMsg=em2)
      ELSE
        CALL CD_HermiteCable_Drag_Element(qe, ve, model%l0(e), model%current, model%waterline_z, &
                                          model%rho_w, model%diam(e), model%cdn(e), model%cdt(e), &
                                          fdrag, ErrStat=es, ErrMsg=em2)
      END IF
      IF (es /= CD_HCDYN_OK) THEN
        ErrStat = es; ErrMsg = 'CD_HermiteCable_Dyn_End_Force: '//TRIM(em2); RETURN
      END IF
      r3 = r3 - fdrag(i0 + 1:i0 + 3)
    END IF
    IF (model%has_viv) THEN
      CALL viv_element_lift(model, model%q, model%v, e, fdrag, es, em2)
      IF (es /= CD_HCDYN_OK) THEN
        ErrStat = es; ErrMsg = 'CD_HermiteCable_Dyn_End_Force: '//TRIM(em2); RETURN
      END IF
      r3 = r3 - fdrag(i0 + 1:i0 + 3)
    END IF
    IF (model%has_attach) THEN
      ! A clump or buoy on the end node loads the point holding it, exactly as it loads the
      ! end node in the residual (assemble_attachments).
      DO k = 1, SIZE(model%att_node)
        IF (model%att_node(k) /= node) CYCLE
        CALL attachment_residual(model, k, model%q, model%v, .FALSE., rk, has_jac, jrel, jtan, es, em2)
        IF (es /= CD_HCDYN_OK) THEN
          ErrStat = es; ErrMsg = 'CD_HermiteCable_Dyn_End_Force: '//TRIM(em2); RETURN
        END IF
        r3 = r3 + rk
      END DO
    END IF
    force = -r3
    ! Nodal twist: R carries M_e drho_e/dq of the end element (the committed torque M_e).
    IF (model%tw_active) THEN
      BLOCK
        REAL(wp) :: rho, beta, g(12), h(12, 12)
        CALL twist_reference(model, e, model%q, model%torsion%ends, .FALSE., rho, beta, g, h, es, em2)
        IF (es /= CD_HCDYN_OK) THEN
          ErrStat = es; ErrMsg = 'CD_HermiteCable_Dyn_End_Force: '//TRIM(em2); RETURN
        END IF
        force = force - model%tw_mt(e)*g(i0 + 1:i0 + 3)
      END BLOCK
      ! Condensed torsion: R carries -M_t dTheta/dq, so the end force gains +M_t dTheta/dr_end.
    ELSE IF (model%torsion%active) THEN
      BLOCK
        REAL(wp) :: th, mt, gend(3, 2)
        CALL CD_HermiteCable_Dyn_Torsion_State(model, th, mt, es, em2, end_dr=gend)
        IF (es /= CD_HCDYN_OK) THEN
          ErrStat = es; ErrMsg = 'CD_HermiteCable_Dyn_End_Force: '//TRIM(em2); RETURN
        END IF
        force = force + mt*gend(:, MERGE(1, 2, node == 1))
      END BLOCK
    END IF
    ! An end resting on the seabed (at or inside the contact blend) leaves to the floor the part
    ! of its end force pressing into it along the upward normal nvec (the end node's weight on a
    ! flat floor), as the floor carries the grounded nodes beside it: a grounded end on a flat
    ! floor reports the horizontal (grounded-run) tension, and one on a slope keeps the line's
    ! along-floor pull, down-slope component included. On a frictional seabed the floor also
    ! holds the along-floor part of the end node's own weight, up to mu times that normal load
    ! (the line's pull stays with the anchor); without friction it stays with the line, as in
    ! the floor's end-element support (held_end_floor_support).
    IF ((model%has_contact .OR. model%kn > CD_ZERO) .AND. .NOT. (gap <= -CD_SEABED_CONTACT_BLEND)) THEN
      fn = DOT_PRODUCT(force, nvec)
      IF (fn < CD_ZERO) THEN
        force = force - fn*nvec
        IF (model%fr_active .AND. model%w(e) > CD_ZERO) THEN
          wt = -model%w(e)*0.5_wp*model%l0(e)*([CD_ZERO, CD_ZERO, CD_ONE] - nvec(3)*nvec)
          IF (NORM2(wt) > CD_ZERO) &
            force = force - MIN(CD_ONE, MIN(model%contact_mu, model%contact_mu_axial)*(-fn)/NORM2(wt))*wt
        END IF
      END IF
    END IF
  END SUBROUTINE CD_HermiteCable_Dyn_End_Force

  SUBROUTINE CD_HermiteCable_Dyn_Set_Output_Recovery(model, element_recovery)
    !! Definition of the node tension, curvature and bend moment (OPTIONS OutputRecovery).
    !! .FALSE. (equilibrium, the default): recovered from nodal equilibrium
    !! (CD_HermiteCable_Dyn_Node_Recovery). .TRUE. (element): the element-mean axial force
    !! EA (|r'| - 1) and the exact one-sided curvature traces of the element interpolation.
    TYPE(CD_HermiteCableDynType), INTENT(INOUT) :: model
    LOGICAL, INTENT(IN) :: element_recovery
    model%output_element_recovery = element_recovery
  END SUBROUTINE CD_HermiteCable_Dyn_Set_Output_Recovery

  SUBROUTINE CD_HermiteCable_Dyn_Node_Values(model, node, tension, curvature, bend_moment, ErrStat, ErrMsg, &
                                             sleeve_moment)
    !! Equilibrium node values at one node (internal order), from the two adjacent elements;
    !! the same values as CD_HermiteCable_Dyn_Node_Recovery returns for that node. The element end
    !! residuals are kept in the model for the element state they were evaluated at (see the rc_
    !! fields), so the tension, curvature and bend moment of a node, and of neighbouring nodes,
    !! share one evaluation per element; a changed time, load configuration or element state
    !! refreshes them. A query compares the two adjacent elements' states only, so a loop over
    !! every node of a line costs O(nn). No allocation.
    TYPE(CD_HermiteCableDynType), INTENT(INOUT) :: model
    INTEGER, INTENT(IN) :: node
    REAL(wp), INTENT(OUT) :: tension, curvature, bend_moment
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    REAL(wp), INTENT(OUT), OPTIONAL :: sleeve_moment
    REAL(wp) :: g(12), fm(3), mm(3), fp(3), mp(3)

    ErrStat = CD_HCDYN_OK; ErrMsg = ''
    tension = CD_ZERO; curvature = CD_ZERO; bend_moment = CD_ZERO
    IF (PRESENT(sleeve_moment)) sleeve_moment = CD_ZERO
    IF (.NOT. model%initialized) THEN
      ErrStat = CD_HCDYN_BADINPUT; ErrMsg = 'CD_HermiteCable_Dyn_Node_Values: model not initialised'; RETURN
    END IF
    IF (node < 1 .OR. node > model%nn) THEN
      ErrStat = CD_HCDYN_BADINPUT; ErrMsg = 'CD_HermiteCable_Dyn_Node_Values: node out of range'; RETURN
    END IF
    ! the cached residuals belong to the time and load configuration they were computed at, and
    ! each to its element's state (exact comparisons; a NaN never matches and is recomputed)
    IF (.NOT. (model%rc_key_ok .AND. model%rc_key_epoch == model%rc_epoch .AND. reals_equal(model%rc_t, model%t))) THEN
      model%rc_t = model%t; model%rc_key_epoch = model%rc_epoch
      model%rc_key_ok = .TRUE.
      model%rc_have = .FALSE.
    END IF
    fm = CD_ZERO; mm = CD_ZERO; fp = CD_ZERO; mp = CD_ZERO
    IF (node > 1) THEN
      CALL cached_end_residual(node - 1, g)
      IF (ErrStat /= CD_HCDYN_OK) RETURN
      fm = g(7:9); mm = g(10:12)
    END IF
    IF (node < model%nn) THEN
      CALL cached_end_residual(node, g)
      IF (ErrStat /= CD_HCDYN_OK) RETURN
      fp = -g(1:3); mp = -g(4:6)
    END IF
    CALL node_values(model, node, fm, mm, fp, mp, tension, curvature, bend_moment, ErrStat, ErrMsg, &
                     sleeve_moment)

  CONTAINS

    SUBROUTINE cached_end_residual(e, ge)
      INTEGER, INTENT(IN) :: e
      REAL(wp), INTENT(OUT) :: ge(12)
      REAL(wp) :: gl(12), qnb(6)
      INTEGER :: i0
      ! the element's residual depends on its own two nodes' q, v and a and on the floor contact
      ! of the neighbouring nodes, a function of their positions (element_end_residual)
      i0 = 6*(e - 1)
      qnb = CD_ZERO
      IF (e > 1) qnb(1:3) = model%q(i0 - 5:i0 - 3)
      IF (e + 2 <= model%nn) qnb(4:6) = model%q(i0 + 13:i0 + 15)
      IF (model%rc_have(e)) THEN
        IF (ALL(reals_equal(model%rc_q(:, e), model%q(i0 + 1:i0 + 12))) .AND. &
            ALL(reals_equal(model%rc_v(:, e), model%v(i0 + 1:i0 + 12))) .AND. &
            ALL(reals_equal(model%rc_a(:, e), model%a(i0 + 1:i0 + 12))) .AND. &
            ALL(reals_equal(model%rc_qnb(:, e), qnb))) THEN
          ge = model%rc_g(:, e); RETURN
        END IF
      END IF
      model%rc_have(e) = .FALSE.
      CALL element_end_residual(model, e, gl, ErrStat, ErrMsg)
      IF (ErrStat /= CD_HCDYN_OK) THEN
        ge = CD_ZERO; RETURN
      END IF
      model%rc_q(:, e) = model%q(i0 + 1:i0 + 12)
      model%rc_v(:, e) = model%v(i0 + 1:i0 + 12)
      model%rc_a(:, e) = model%a(i0 + 1:i0 + 12)
      model%rc_qnb(:, e) = qnb
      model%rc_g(:, e) = gl
      model%rc_have(e) = .TRUE.
      ge = gl
    END SUBROUTINE cached_end_residual
  END SUBROUTINE CD_HermiteCable_Dyn_Node_Values

  SUBROUTINE CD_HermiteCable_Dyn_Node_Recovery(model, ErrStat, ErrMsg, tension, curvature, bend_moment, &
                                               segment_tension, curvature_vector, moment_vector)
    !! Effective tension, curvature and bend moment at every node (internal order) recovered
    !! from nodal equilibrium, in one pass over the elements.
    !!
    !! For element e the end residual g_e = f_int + f_damp - f_ext + M_e a_e holds the element's
    !! own distributed loads (consistent submerged weight, dry-part buoyancy, drag,
    !! Froude-Krylov force, the seabed contact of its end nodes spread over their tributary
    !! lengths, and the structural and added-mass inertia): it is the generalized force the two
    !! end nodes exert on the element. Its position rows on the End-B side (internal node e+1)
    !! are the section force just before that node, minus its rows on the End-A side the
    !! section force just after node e; its tangent rows are the conjugate of the material
    !! tangent, EI r'' at the node. An interior node reports the mean of its two one-sided
    !! values, whose difference is the point load left at the node, so the nodal section
    !! forces satisfy the discrete equilibrium exactly and do not carry the pointwise
    !! oscillation of the stiff-EA axial strain.
    !!
    !! tension(j) = t_j . F_j (t_j the unit nodal tangent; a line end reports the end force
    !! magnitude of CD_HermiteCable_Dyn_End_Force), the section moment
    !! M_j = (1 + e_j) |m_j - (m_j . t_j) t_j|, 1 + e_j = |r'_j| the stretch at the node (m_j is the
    !! conjugate of the tangent r', the section moment r' x m_j),
    !! curvature(j) = (1 + e_j) M_j/EI, the geometric curvature of the stretched line, the larger
    !! of the two sides at a section junction (under a bend
    !! stiffener EI is the stiffness at the node, not the element's; see node_values), and
    !! bend_moment(j) the cable's own share EI_line curvature (M_j itself where no bend stiffener
    !! sleeves the element; see node_values) (the
    !! exact geometric trace on an element without bending stiffness, or with EI below ei_resolve,
    !! where the recovered moment error w L0^2/12 exceeds the elastic moment of a 1 m bend radius).
    !! segment_tension(e) is the
    !! mean of the axial components of element e's own two end forces. curvature_vector(:, j)
    !! is the curvature vector kappa n of node j in the solve frame, toward the centre of
    !! curvature, of length curvature(j): the section moment vector over EI on the side that
    !! gives curvature(j), or the exact trace's vector. moment_vector(:, j) is the section moment
    !! turned into the plane of the curvature, along kappa n, of length M_j. Every output is
    !! optional (node arrays nn, curvature_vector and moment_vector (3, nn), segment_tension ne);
    !! the routine allocates nothing.
    !!
    !! The condensed torque of a line restrained in torsion is not part of g_e: it adds a shear
    !! normal to the tangent and does no work on bending rotations, so tension and bend moment
    !! are its axial and normal parts without it. Under torque-tension coupling the tension adds
    !! the element's (K/GJ) M_t (coupling_tension), the axial force K tau that the kernel's
    !! EA - K^2/GJ does not carry. Read-only.
    TYPE(CD_HermiteCableDynType), INTENT(IN) :: model
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    REAL(wp), INTENT(OUT), OPTIONAL :: tension(:), curvature(:), bend_moment(:), segment_tension(:)
    REAL(wp), INTENT(OUT), OPTIONAL :: curvature_vector(:, :), moment_vector(:, :)
    REAL(wp) :: g(12), fm(3), mm(3), fp(3), mp(3), ta(3), tb(3)
    INTEGER :: e, nn
    LOGICAL :: want_nodes

    ErrStat = CD_HCDYN_OK; ErrMsg = ''
    IF (.NOT. model%initialized) THEN
      ErrStat = CD_HCDYN_BADINPUT; ErrMsg = 'CD_HermiteCable_Dyn_Node_Recovery: model not initialised'; RETURN
    END IF
    nn = model%nn
    IF (.NOT. (size_ok(tension, nn) .AND. size_ok(curvature, nn) .AND. size_ok(bend_moment, nn) .AND. &
               size_ok(segment_tension, model%ne))) THEN
      ErrStat = CD_HCDYN_BADINPUT
      ErrMsg = 'CD_HermiteCable_Dyn_Node_Recovery: node arrays must be nn, segment_tension ne'; RETURN
    END IF
    IF (PRESENT(curvature_vector)) THEN
      IF (SIZE(curvature_vector, 1) /= 3 .OR. SIZE(curvature_vector, 2) /= nn) THEN
        ErrStat = CD_HCDYN_BADINPUT
        ErrMsg = 'CD_HermiteCable_Dyn_Node_Recovery: curvature_vector must be (3, nn)'; RETURN
      END IF
    END IF
    IF (PRESENT(moment_vector)) THEN
      IF (SIZE(moment_vector, 1) /= 3 .OR. SIZE(moment_vector, 2) /= nn) THEN
        ErrStat = CD_HCDYN_BADINPUT
        ErrMsg = 'CD_HermiteCable_Dyn_Node_Recovery: moment_vector must be (3, nn)'; RETURN
      END IF
    END IF
    want_nodes = PRESENT(tension) .OR. PRESENT(curvature) .OR. PRESENT(bend_moment) .OR. &
                 PRESENT(curvature_vector) .OR. PRESENT(moment_vector)
    fm = CD_ZERO; mm = CD_ZERO
    DO e = 1, model%ne
      CALL element_end_residual(model, e, g, ErrStat, ErrMsg)
      IF (ErrStat /= CD_HCDYN_OK) RETURN
      fp = -g(1:3); mp = -g(4:6)
      IF (want_nodes) THEN
        CALL store_node(e)
        IF (ErrStat /= CD_HCDYN_OK) RETURN
      END IF
      IF (PRESENT(segment_tension)) THEN
        ta = unit_tangent(model, e)
        tb = unit_tangent(model, e + 1)
        segment_tension(e) = 0.5_wp*(DOT_PRODUCT(ta, fp) + DOT_PRODUCT(tb, g(7:9))) + coupling_tension(model, e)
      END IF
      fm = g(7:9); mm = g(10:12)
    END DO
    fp = CD_ZERO; mp = CD_ZERO
    IF (want_nodes) CALL store_node(nn)

  CONTAINS

    SUBROUTINE store_node(node)
      INTEGER, INTENT(IN) :: node
      REAL(wp) :: t_n, k_n, b_n, kv(3), mv(3)
      CALL node_values(model, node, fm, mm, fp, mp, t_n, k_n, b_n, ErrStat, ErrMsg, curvature_vector=kv, &
                       moment_vector=mv)
      IF (PRESENT(curvature_vector)) curvature_vector(:, node) = kv
      IF (PRESENT(moment_vector)) moment_vector(:, node) = mv
      IF (PRESENT(tension)) tension(node) = t_n
      IF (PRESENT(curvature)) curvature(node) = k_n
      IF (PRESENT(bend_moment)) bend_moment(node) = b_n
    END SUBROUTINE store_node

    PURE LOGICAL FUNCTION size_ok(x, n) RESULT(ok)
      REAL(wp), INTENT(IN), OPTIONAL :: x(:)
      INTEGER, INTENT(IN) :: n
      ok = .TRUE.
      IF (PRESENT(x)) ok = SIZE(x) == n
    END FUNCTION size_ok
  END SUBROUTINE CD_HermiteCable_Dyn_Node_Recovery

  PURE REAL(wp) FUNCTION coupling_tension(model, e) RESULT(tc)
    !! The axial force (K/GJ) M_t of element e of a line restrained in torsion under torque-tension
    !! coupling (T = EA eps + K tau with tau = (M_t - K eps)/GJ, the kernel carrying the
    !! EA - K^2/GJ part); zero without coupling, without torsion, or outside the elements.
    TYPE(CD_HermiteCableDynType), INTENT(IN) :: model
    INTEGER, INTENT(IN) :: e
    tc = CD_ZERO
    IF (e < 1 .OR. e > model%ne) RETURN
    IF (.NOT. model%torsion%active) RETURN
    IF (.NOT. ALLOCATED(model%torsion%couple)) RETURN
    IF (model%tw_active) THEN
      tc = model%torsion%couple(e)*model%tw_mt(e)
    ELSE
      tc = model%torsion%couple(e)*model%torsion%torque
    END IF
  END FUNCTION coupling_tension

  PURE REAL(wp) FUNCTION CD_HermiteCable_Dyn_Coupling_Tension(model, e) RESULT(tc)
    !! The axial force of element e (model order, End B first) that torque-tension coupling adds
    !! to the kernel's EA - K^2/GJ resultant at the committed state, (K/GJ) M_t [N]: a host
    !! reading the axial resultant of an element (CD_HermiteCable_Axial_Resultant with the
    !! model's EA) adds it for the section's tension. Zero without coupling or torsion.
    TYPE(CD_HermiteCableDynType), INTENT(IN) :: model
    INTEGER, INTENT(IN) :: e
    tc = coupling_tension(model, e)
  END FUNCTION CD_HermiteCable_Dyn_Coupling_Tension

  REAL(wp) FUNCTION element_twist(model, e, mt) RESULT(tw)
    !! The twist of element e under the torque mt: mt l0/GJ, less the twist its stretch takes up
    !! under torque-tension coupling, (K/GJ)(l_e - l0) [rad].
    TYPE(CD_HermiteCableDynType), INTENT(IN) :: model
    INTEGER, INTENT(IN) :: e
    REAL(wp), INTENT(IN) :: mt
    REAL(wp) :: qe(12), ls
    tw = mt*model%l0(e)/model%torsion%gj(e)
    IF (.NOT. ALLOCATED(model%torsion%couple)) RETURN
    IF (.NOT. ABS(model%torsion%couple(e)) > CD_ZERO) RETURN
    CALL gather_elem(model, e, qe)
    ls = CD_HermiteTorsion_Element_Stretch(qe, model%l0(e), model%torsion%quadrature_order)
    tw = tw - model%torsion%couple(e)*(ls - model%l0(e))
  END FUNCTION element_twist

  SUBROUTINE CD_HermiteCable_Dyn_Element_Twist(model, twist, ErrStat, ErrMsg)
    !! The twist of every element of a line restrained in torsion at the committed state [rad]:
    !! M_t l0/GJ less, under torque-tension coupling, the twist the element's stretch takes up.
    !! Element order is the model's (End B first); zero for a line without torsion.
    TYPE(CD_HermiteCableDynType), INTENT(IN) :: model
    REAL(wp), INTENT(OUT) :: twist(:)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    REAL(wp) :: th, mt
    INTEGER :: e
    twist = CD_ZERO
    ErrStat = CD_HCDYN_OK; ErrMsg = ''
    IF (SIZE(twist) /= model%ne) THEN
      ErrStat = CD_HCDYN_BADINPUT
      ErrMsg = 'CD_HermiteCable_Dyn_Element_Twist: twist must have one entry per element'; RETURN
    END IF
    IF (.NOT. model%torsion%active) RETURN
    IF (model%tw_active) THEN
      ! nodal twist: phi_{e+1} - phi_e + beta_e - h_e at the committed state
      BLOCK
        REAL(wp) :: rho, beta, g(12), h(12, 12), qe(12), ls
        DO e = 1, model%ne
          CALL twist_reference(model, e, model%q, model%torsion%ends, .FALSE., rho, beta, g, h, ErrStat, ErrMsg)
          IF (ErrStat /= CD_HCDYN_OK) RETURN
          twist(e) = model%tw_phi(e + 1) - model%tw_phi(e) + rho
          IF (ALLOCATED(model%torsion%couple)) THEN
            IF (ABS(model%torsion%couple(e)) > CD_ZERO) THEN
              CALL gather_elem(model, e, qe)
              ls = CD_HermiteTorsion_Element_Stretch(qe, model%l0(e), model%torsion%quadrature_order)
              twist(e) = twist(e) - model%torsion%couple(e)*(ls - model%l0(e))
            END IF
          END IF
        END DO
      END BLOCK
      RETURN
    END IF
    CALL CD_HermiteCable_Dyn_Torsion_State(model, th, mt, ErrStat, ErrMsg)
    IF (ErrStat /= CD_HCDYN_OK) RETURN
    DO e = 1, model%ne
      twist(e) = element_twist(model, e, mt)
    END DO
  END SUBROUTINE CD_HermiteCable_Dyn_Element_Twist

  SUBROUTINE CD_HermiteCable_Dyn_Element_Torque(model, torque, ErrStat, ErrMsg)
    !! The torque of every element at the committed state [N m], positive for a right-handed
    !! twist about the solve tangent (End 1 -> End 2): with the nodal twist the element torques
    !! (elastic plus torsional damping), with the condensed torsion the uniform torque, and zero
    !! for a line without torsion. Element order is the model's (End B first).
    TYPE(CD_HermiteCableDynType), INTENT(IN) :: model
    REAL(wp), INTENT(OUT) :: torque(:)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    torque = CD_ZERO
    ErrStat = CD_HCDYN_OK; ErrMsg = ''
    IF (SIZE(torque) /= model%ne) THEN
      ErrStat = CD_HCDYN_BADINPUT
      ErrMsg = 'CD_HermiteCable_Dyn_Element_Torque: torque must have one entry per element'; RETURN
    END IF
    IF (.NOT. model%torsion%active) RETURN
    IF (model%tw_active) THEN
      torque = model%tw_mt
    ELSE
      torque = model%torsion%torque
    END IF
  END SUBROUTINE CD_HermiteCable_Dyn_Element_Torque

  SUBROUTINE CD_HermiteCable_Dyn_Node_Torque(model, torque, ErrStat, ErrMsg)
    !! The torque at every node at the committed state [N m] (the Torq<L>N<J> channels): an end
    !! node takes its element's torque and an interior node the mean of its two elements' (the
    !! uniform torque of the condensed torsion everywhere; zero without torsion). Node order is
    !! the model's (End B first).
    TYPE(CD_HermiteCableDynType), INTENT(IN) :: model
    REAL(wp), INTENT(OUT) :: torque(:)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    INTEGER :: k
    torque = CD_ZERO
    ErrStat = CD_HCDYN_OK; ErrMsg = ''
    IF (SIZE(torque) /= model%nn) THEN
      ErrStat = CD_HCDYN_BADINPUT
      ErrMsg = 'CD_HermiteCable_Dyn_Node_Torque: torque must have one entry per node'; RETURN
    END IF
    IF (.NOT. model%torsion%active) RETURN
    IF (.NOT. model%tw_active) THEN
      torque = model%torsion%torque
      RETURN
    END IF
    torque(1) = model%tw_mt(1)
    torque(model%nn) = model%tw_mt(model%ne)
    DO k = 2, model%nn - 1
      torque(k) = 0.5_wp*(model%tw_mt(k - 1) + model%tw_mt(k))
    END DO
  END SUBROUTINE CD_HermiteCable_Dyn_Node_Torque

  SUBROUTINE CD_HermiteCable_Dyn_End_Twist(model, twist, ErrStat, ErrMsg)
    !! The twist of the two torsional end springs at the committed state [rad] (internal ends 1
    !! and 2; zero at a rigid end): with the nodal twist the end node's against its end frame,
    !! with the condensed torsion the torque times the end compliance.
    TYPE(CD_HermiteCableDynType), INTENT(IN) :: model
    REAL(wp), INTENT(OUT) :: twist(2)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    REAL(wp) :: psi, gl(3), hl(3, 3)
    INTEGER :: iend
    twist = CD_ZERO
    ErrStat = CD_HCDYN_OK; ErrMsg = ''
    IF (.NOT. model%torsion%active) RETURN
    IF (.NOT. model%tw_active) THEN
      twist = model%torsion%torque*model%torsion%end_compliance
      RETURN
    END IF
    DO iend = 1, 2
      IF (.NOT. tw_spring(model, iend)) CYCLE
      CALL twist_link(model, iend, model%q, model%torsion%ends, .FALSE., psi, gl, hl, ErrStat, ErrMsg)
      IF (ErrStat /= CD_HCDYN_OK) THEN
        ErrMsg = 'CD_HermiteCable_Dyn_End_Twist: '//TRIM(ErrMsg)
        RETURN
      END IF
      IF (iend == 1) THEN
        twist(1) = model%tw_phi(1) - psi
      ELSE
        twist(2) = psi + model%torsion%phi - model%tw_phi(model%nn)
      END IF
    END DO
  END SUBROUTINE CD_HermiteCable_Dyn_End_Twist

  SUBROUTINE CD_HermiteCable_Dyn_Twist_Check(model, q_check, ends, ErrStat, ErrMsg)
    !! Read-only check that the nodal twist accepts the configuration q_check with the end
    !! frames ends (a host about to write them): every element's reference twist and every
    !! elastic end's spring evaluate (fold guard, an end frame within pi/2 of its committed
    !! turn). Without the nodal twist it accepts.
    TYPE(CD_HermiteCableDynType), INTENT(IN) :: model
    REAL(wp), INTENT(IN) :: q_check(:), ends(3, 4)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    REAL(wp) :: rho, beta, g(12), h(12, 12), psi, gl(3), hl(3, 3)
    INTEGER :: e, iend
    ErrStat = CD_HCDYN_OK
    ErrMsg = ''
    IF (.NOT. model%tw_active) RETURN
    IF (SIZE(q_check) /= model%ndof) THEN
      ErrStat = CD_HCDYN_BADINPUT
      ErrMsg = 'CD_HermiteCable_Dyn_Twist_Check: q_check must have ndof entries'; RETURN
    END IF
    DO e = 1, model%ne
      CALL twist_reference(model, e, q_check, ends, .FALSE., rho, beta, g, h, ErrStat, ErrMsg)
      IF (ErrStat /= CD_HCDYN_OK) THEN
        ErrMsg = 'CD_HermiteCable_Dyn_Twist_Check: '//TRIM(ErrMsg); RETURN
      END IF
    END DO
    DO iend = 1, 2
      IF (.NOT. tw_spring(model, iend)) CYCLE
      CALL twist_link(model, iend, q_check, ends, .FALSE., psi, gl, hl, ErrStat, ErrMsg)
      IF (ErrStat /= CD_HCDYN_OK) THEN
        ErrMsg = 'CD_HermiteCable_Dyn_Twist_Check: '//TRIM(ErrMsg); RETURN
      END IF
    END DO
  END SUBROUTINE CD_HermiteCable_Dyn_Twist_Check

  SUBROUTINE CD_HermiteCable_Dyn_Twist_Hessian(model, eg, eh, ek, emt, lg, lh, lk, lmt, ErrStat, ErrMsg)
    !! The second variation of the nodal-twist elastic energy at the committed state, for an
    !! undamped modal analysis about it (CableDyn_Modal): the energy is
    !!   sum_e 1/2 (GJ/l0)_e tau_e**2 + sum_(elastic ends) 1/2 k tw**2,
    !!   tau_e = phi_{e+1} - phi_e + rho_e(q),  tw = phi_1 - psi_1(q) (end 1), psi_2(q) + Phi - phi_N (end 2),
    !! with the committed reference and end frames held. Per element: eg = d rho_e/dq and
    !! eh = d2 rho_e/dq2 over its 12 DOFs, ek = GJ/l0 and emt = ek tau_e (the element torque
    !! without damping), so d2E/dq2 = emt eh + ek eg eg^T, d2E/dphi_{e+1} dq = ek eg = -d2E/dphi_e dq
    !! and d2E/dphi2 = ek [[1, -1], [-1, 1]]. Per end k (columns): lg = d psi/dm and lh = d2 psi/dm2
    !! in the end node's tangent handle m, lk the spring stiffness (0 at a rigid end, whose
    !! angle is held, and at a free end, which has no spring) and lmt = lk tw, so
    !! d2E/dm2 = lk lg lg^T -+ lmt lh (- at end 1, + at end 2),
    !! d2E/dphi dm = -lk lg and d2E/dphi2 = lk. Fails closed without the nodal twist.
    TYPE(CD_HermiteCableDynType), INTENT(IN) :: model
    REAL(wp), INTENT(OUT) :: eg(:, :), eh(:, :, :), ek(:), emt(:), lg(3, 2), lh(3, 3, 2), lk(2), lmt(2)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    REAL(wp) :: rho, beta, psi, tw
    INTEGER :: e, iend
    eg = CD_ZERO
    eh = CD_ZERO
    ek = CD_ZERO
    emt = CD_ZERO
    lg = CD_ZERO
    lh = CD_ZERO
    lk = CD_ZERO
    lmt = CD_ZERO
    ErrStat = CD_HCDYN_BADINPUT
    IF (.NOT. model%tw_active) THEN
      ErrMsg = 'CD_HermiteCable_Dyn_Twist_Hessian: the model has no nodal twist'; RETURN
    END IF
    IF (SIZE(eg, 1) /= 12 .OR. SIZE(eg, 2) /= model%ne .OR. SIZE(eh, 1) /= 12 .OR. SIZE(eh, 2) /= 12 .OR. &
        SIZE(eh, 3) /= model%ne .OR. SIZE(ek) /= model%ne .OR. SIZE(emt) /= model%ne) THEN
      ErrMsg = 'CD_HermiteCable_Dyn_Twist_Hessian: the element arrays must have ne columns'; RETURN
    END IF
    ErrStat = CD_HCDYN_OK
    ErrMsg = ''
    DO e = 1, model%ne
      CALL twist_reference(model, e, model%q, model%torsion%ends, .TRUE., rho, beta, eg(:, e), eh(:, :, e), &
                           ErrStat, ErrMsg)
      IF (ErrStat /= CD_HCDYN_OK) THEN
        ErrMsg = 'CD_HermiteCable_Dyn_Twist_Hessian: '//TRIM(ErrMsg); RETURN
      END IF
      ek(e) = model%torsion%gj(e)/model%l0(e)
      emt(e) = ek(e)*(model%tw_phi(e + 1) - model%tw_phi(e) + rho)
    END DO
    DO iend = 1, 2
      ! (a free end, end_free, has no spring: its angle is free and its energy term absent)
      IF (.NOT. tw_spring(model, iend)) CYCLE
      CALL twist_link(model, iend, model%q, model%torsion%ends, .TRUE., psi, lg(:, iend), lh(:, :, iend), &
                      ErrStat, ErrMsg)
      IF (ErrStat /= CD_HCDYN_OK) THEN
        ErrMsg = 'CD_HermiteCable_Dyn_Twist_Hessian: '//TRIM(ErrMsg); RETURN
      END IF
      lk(iend) = CD_ONE/model%torsion%end_compliance(iend)
      IF (iend == 1) THEN
        tw = model%tw_phi(1) - psi
      ELSE
        tw = psi + model%torsion%phi - model%tw_phi(model%nn)
      END IF
      lmt(iend) = lk(iend)*tw
    END DO
  END SUBROUTINE CD_HermiteCable_Dyn_Twist_Hessian

  PURE INTEGER FUNCTION CD_HermiteCable_Dyn_Twist_Mirror_Size(model) RESULT(n)
    !! Reals of the nodal-twist checkpoint mirror (CD_HermiteCable_Dyn_Twist_Pack): the
    !! committed angles, rates and accelerations, directors, reference tangents, reference
    !! twists, element torques, end-frame references and rates, the force cache's angle part,
    !! and the committed mean torque as it was formed (the summed twist over the compliance of
    !! the lengths it was reached with, which a reload does not re-derive, as Restore does not);
    !! 0 without the nodal twist.
    TYPE(CD_HermiteCableDynType), INTENT(IN) :: model
    n = 0
    IF (model%tw_active) n = tw_pack_size(model) + model%nn + 1
  END FUNCTION CD_HermiteCable_Dyn_Twist_Mirror_Size

  SUBROUTINE CD_HermiteCable_Dyn_Twist_Pack(model, buf)
    !! Write the nodal-twist checkpoint mirror (CD_HermiteCable_Dyn_Twist_Mirror_Size reals).
    TYPE(CD_HermiteCableDynType), INTENT(IN) :: model
    REAL(wp), INTENT(OUT) :: buf(:)
    INTEGER :: n
    IF (.NOT. model%tw_active) RETURN
    n = tw_pack_size(model)
    CALL tw_pack(model, buf(1:n))
    buf(n + 1:n + model%nn) = model%tw_fcR
    buf(n + model%nn + 1) = model%torsion%torque
  END SUBROUTINE CD_HermiteCable_Dyn_Twist_Pack

  SUBROUTINE CD_HermiteCable_Dyn_Twist_Unpack(model, buf, ErrStat, ErrMsg, check_only)
    !! Reload the nodal twist from a mirror of CD_HermiteCable_Dyn_Twist_Pack written by a
    !! model built from the same input (the caller restores q, v, a and the force cache with
    !! it), the committed torque included. Fails closed on a size mismatch, a non-finite value
    !! or a non-unit director; with check_only it only checks.
    TYPE(CD_HermiteCableDynType), INTENT(INOUT) :: model
    REAL(wp), INTENT(IN) :: buf(:)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    LOGICAL, INTENT(IN), OPTIONAL :: check_only
    INTEGER :: n, i
    ErrStat = CD_HCDYN_BADINPUT
    IF (.NOT. model%tw_active) THEN
      ErrMsg = 'CD_HermiteCable_Dyn_Twist_Unpack: the model has no nodal twist'; RETURN
    END IF
    n = tw_pack_size(model)
    IF (SIZE(buf) /= n + model%nn + 1) THEN
      ErrMsg = 'CD_HermiteCable_Dyn_Twist_Unpack: the mirror does not match this line'; RETURN
    END IF
    IF (.NOT. CD_All_Finite(buf)) THEN
      ErrMsg = 'CD_HermiteCable_Dyn_Twist_Unpack: non-finite twist state'; RETURN
    END IF
    DO i = 1, model%nn
      IF (ABS(NORM2(buf(3*model%nn + 3*i - 2:3*model%nn + 3*i)) - CD_ONE) > 1.0e-8_wp .OR. &
          ABS(NORM2(buf(6*model%nn + 3*i - 2:6*model%nn + 3*i)) - CD_ONE) > 1.0e-8_wp) THEN
        ErrMsg = 'CD_HermiteCable_Dyn_Twist_Unpack: a director or reference tangent is not a unit vector'; RETURN
      END IF
    END DO
    ErrStat = CD_HCDYN_OK
    ErrMsg = ''
    IF (PRESENT(check_only)) THEN
      IF (check_only) RETURN
    END IF
    CALL tw_unpack(model, buf(1:n))
    model%tw_fcR = buf(n + 1:n + model%nn)
    model%torsion%torque = buf(n + model%nn + 1)
    ErrStat = CD_HCDYN_OK
    ErrMsg = ''
  END SUBROUTINE CD_HermiteCable_Dyn_Twist_Unpack

  SUBROUTINE node_values(model, node, fm, mm, fp, mp, tension, curvature, bend_moment, ErrStat, ErrMsg, &
                         sleeve_moment, curvature_vector, moment_vector)
    !! Node values from the one-sided section force and moment before (fm, mm) and after
    !! (fp, mp) the node; a line end uses its only side (see CD_HermiteCable_Dyn_Node_Recovery).
    !! bend_moment is the cable's own share of the section moment, EI_line kappa on the side of
    !! the larger value (the whole section moment on a side without a bend stiffener), and
    !! sleeve_moment the rest, the share a stiffener sleeve carries. curvature_vector is the
    !! curvature vector kappa n (solve frame, toward the centre of curvature) of the side that
    !! gives curvature: the normal part of the section moment over EI, or the exact trace's.
    !!
    !! The energy EI kappa^2/2 per unstretched length, with kappa the curvature of the stretched
    !! line, gives m = EI kappa n/|r'|^2 as the conjugate of the tangent r'. Rotating the whole
    !! line leaves the energy unchanged, so the moment that balances the forces is r' x m, of
    !! length M = |r'| |m_perp| = EI kappa/|r'|, and kappa = |r'| M/EI.
    !!
    !! The EI of a side is the element's, or on a stiffened line the limit of EI(s) at the node
    !! from that side (EI_node): the element's compliance average stands for its whole length
    !! and, under a taper, steps at every node although the section does not, so the softer side
    !! would overstate the curvature by about h |EI'|/(2 EI). The two limits differ only at a
    !! real step of the section (the bare tip, a junction of two line types, a step between
    !! stiffener rows), where the larger-side rule still applies. The exact trace of a side too
    !! soft to recover takes the same stiffness (trace_scale). moment_vector is the section
    !! moment turned into the plane of the curvature, along kappa n.
    TYPE(CD_HermiteCableDynType), INTENT(IN) :: model
    INTEGER, INTENT(IN) :: node
    REAL(wp), INTENT(IN) :: fm(3), mm(3), fp(3), mp(3)
    REAL(wp), INTENT(OUT) :: tension, curvature, bend_moment
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    REAL(wp), INTENT(OUT), OPTIONAL :: sleeve_moment, curvature_vector(3), moment_vector(3)
    REAL(wp) :: t(3), f(3), m(3), fend(3), qe(12), trace, section_moment, cable_moment, m_perp(3), kv(3), ei_side
    REAL(wp) :: stretch
    INTEGER :: e, side
    CHARACTER(200) :: em2

    ErrStat = CD_HCDYN_OK; ErrMsg = ''
    t = unit_tangent(model, node)
    IF (node == 1) THEN
      f = fp; m = mp
    ELSE IF (node == model%nn) THEN
      f = fm; m = mm
    ELSE
      f = 0.5_wp*(fm + fp); m = 0.5_wp*(mm + mp)
    END IF
    IF (node == 1 .OR. node == model%nn) THEN
      CALL CD_HermiteCable_Dyn_End_Force(model, node, fend, ErrStat, ErrMsg)
      IF (ErrStat /= CD_HCDYN_OK) RETURN
      tension = NORM2(fend)
    ELSE
      tension = DOT_PRODUCT(t, f) + 0.5_wp*(coupling_tension(model, node - 1) + coupling_tension(model, node))
    END IF
    stretch = node_stretch(model, node)
    m_perp = stretch*(m - DOT_PRODUCT(m, t)*t)
    section_moment = NORM2(m_perp)
    IF (PRESENT(moment_vector)) moment_vector = m_perp
    curvature = CD_ZERO
    cable_moment = CD_ZERO
    IF (PRESENT(curvature_vector)) curvature_vector = CD_ZERO
    DO side = 0, 1
      e = node - 1 + side
      IF (e < 1 .OR. e > model%ne) CYCLE
      ei_side = CD_HermiteCable_Dyn_Side_EI(model, e, node)
      IF (model%EI(e) > CD_ZERO .AND. ei_side >= model%ei_resolve) THEN
        IF (PRESENT(curvature_vector) .AND. stretch*section_moment/ei_side > curvature) &
          curvature_vector = stretch*m_perp/ei_side
        curvature = MAX(curvature, stretch*section_moment/ei_side)
        IF (ABS(model%EI_line(e) - ei_side) <= CD_ZERO) THEN
          cable_moment = MAX(cable_moment, section_moment)
        ELSE
          cable_moment = MAX(cable_moment, model%EI_line(e)*(section_moment/ei_side))
        END IF
      ELSE
        CALL gather_elem(model, e, qe)
        CALL CD_HermiteCable_Curvature(qe, model%l0(e), REAL(1 - side, wp), trace, ErrStat, em2, kvec=kv)
        IF (ErrStat /= CD_HCABLE_OK) THEN
          ErrStat = CD_HCDYN_NOCONVERGE; ErrMsg = 'CD_HermiteCable_Dyn_Node_Recovery: '//TRIM(em2); RETURN
        END IF
        trace = trace*trace_scale(model, e, node)
        IF (PRESENT(curvature_vector) .AND. trace > curvature) curvature_vector = kv*trace_scale(model, e, node)
        curvature = MAX(curvature, trace)
        IF (ABS(model%EI_line(e) - model%EI(e)) <= CD_ZERO) THEN
          cable_moment = MAX(cable_moment, section_moment)
        ELSE
          cable_moment = MAX(cable_moment, model%EI_line(e)*trace/stretch)
        END IF
      END IF
    END DO
    bend_moment = cable_moment
    IF (PRESENT(sleeve_moment)) sleeve_moment = MAX(CD_ZERO, section_moment - cable_moment)
  END SUBROUTINE node_values

  PURE FUNCTION node_stretch(model, node) RESULT(stretch)
    !! The stretch |r'| = 1 + e of a node, the length of its material tangent; 1 when degenerate.
    TYPE(CD_HermiteCableDynType), INTENT(IN) :: model
    INTEGER, INTENT(IN) :: node
    REAL(wp) :: stretch
    stretch = NORM2(model%q(6*(node - 1) + 4:6*(node - 1) + 6))
    IF (.NOT. stretch > CD_ZERO) stretch = CD_ONE
  END FUNCTION node_stretch

  PURE FUNCTION unit_tangent(model, node) RESULT(t)
    !! Unit material tangent of a node (internal arc direction); zero when degenerate.
    TYPE(CD_HermiteCableDynType), INTENT(IN) :: model
    INTEGER, INTENT(IN) :: node
    REAL(wp) :: t(3), tn
    t = model%q(6*(node - 1) + 4:6*(node - 1) + 6)
    tn = NORM2(t)
    IF (tn > CD_ZERO) THEN
      t = t/tn
    ELSE
      t = CD_ZERO
    END IF
  END FUNCTION unit_tangent

  SUBROUTINE node_contact_normal(model, node, fc, ErrStat, ErrMsg, clearance)
    !! Frictionless seabed contact force on a node at the committed state, exactly as
    !! assemble_contact applies it: the normal force with its damping and, in a rounded crease
    !! of the bathymetry, the elastic increment of the penalty potential (crease_contact_increment).
    !! clearance is the node's normal distance above the height at which the contact law engages:
    !! negative on the floor, positive above it.
    TYPE(CD_HermiteCableDynType), INTENT(IN) :: model
    INTEGER, INTENT(IN) :: node
    REAL(wp), INTENT(OUT) :: fc(3)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    REAL(wp), INTENT(OUT), OPTIONAL :: clearance
    REAL(wp) :: z_floor, gx, gy, xg, yg, gxg, gyg, sfac, nvec(3), gap, normal, normal_gap, vn, gate, gate_gap
    REAL(wp) :: curv_g(3), fcrease(3), kcrease(3, 3)
    INTEGER :: iz, es
    LOGICAL :: creased
    CHARACTER(200) :: em2
    ErrStat = CD_HCDYN_OK; ErrMsg = ''
    fc = CD_ZERO
    IF (PRESENT(clearance)) clearance = HUGE(CD_ONE)
    iz = 6*(node - 1) + 3
    IF (model%has_contact) THEN
      z_floor = model%seabed_z
      gx = CD_ZERO; gy = CD_ZERO
      creased = .FALSE.
      IF (model%has_contact_bathymetry) THEN
        xg = model%contact_frame_c*model%q(iz - 2) - model%contact_frame_s*model%q(iz - 1)
        yg = model%contact_frame_s*model%q(iz - 2) + model%contact_frame_c*model%q(iz - 1)
        CALL CD_Bathymetry_Floor_Gradient(model%contact_bathymetry, xg, yg, z_floor, gxg, gyg, es, em2, &
                                          crease_curvature=curv_g)
        IF (es /= CD_BATHY_OK) THEN
          ErrStat = CD_HCDYN_NOCONVERGE; ErrMsg = 'node_contact_normal: '//TRIM(em2); RETURN
        END IF
        gx = model%contact_frame_c*gxg + model%contact_frame_s*gyg
        gy = -model%contact_frame_s*gxg + model%contact_frame_c*gyg
        creased = ANY(ABS(curv_g) > CD_ZERO)
      END IF
      sfac = SQRT(CD_ONE + gx*gx + gy*gy)
      nvec = [-gx, -gy, CD_ONE]/sfac
      gap = (z_floor - model%q(iz))/sfac
      IF (PRESENT(clearance)) clearance = -gap - CD_SEABED_CONTACT_BLEND
      CALL CD_Seabed_Normal_Law(gap, model%contact_kn(node), normal, normal_gap)
      CALL CD_Seabed_Contact_Gate(gap, gate, gate_gap)
      IF (normal <= CD_ZERO .AND. gate <= CD_ZERO) RETURN
      vn = DOT_PRODUCT(model%v(iz - 2:iz), nvec)
      IF (ALLOCATED(model%contact_cn) .AND. vn < CD_ZERO) normal = normal - model%contact_cn(node)*gate*vn
      fc = normal*nvec
      IF (creased) THEN
        CALL crease_contact_increment(z_floor - model%q(iz), gx, gy, model%contact_kn(node), &
                                      CD_Bathymetry_Rotate_Curvature(curv_g, [model%contact_frame_c, &
                                                                              model%contact_frame_s]), &
                                      fcrease, kcrease)
        fc = fc + fcrease
      END IF
    ELSE IF (model%kn > CD_ZERO) THEN
      gap = model%seabed_z - model%q(iz)
      IF (PRESENT(clearance)) clearance = -gap
      IF (gap > CD_ZERO) fc(3) = model%kn*gap*model%trib(node)
    END IF
  END SUBROUTINE node_contact_normal

  SUBROUTINE added_mass_force(qe, ae, l0, waterline_z, rho, diam, can, cat, f, ErrStat, ErrMsg)
    !! Added-mass inertia force Ma(qe) ae of one element without forming Ma: the quadrature,
    !! wet/dry culling and deformed length measure of CD_HermiteCable_AddedMass_Element.
    REAL(wp), INTENT(IN) :: qe(12), ae(12), l0, waterline_z, rho, diam, can, cat
    REAL(wp), INTENT(OUT) :: f(12)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    INTEGER, PARAMETER :: NGP = 4
    REAL(wp), PARAMETER :: PI_L = 3.14159265358979323846_wp
    REAL(wp) :: gp(NGP), gw(NGP), H(4), dH(4), rpos(3), rp(3), acc(3), speed, tangent(3), fa(3), area
    INTEGER :: g, sh, c

    ErrStat = CD_HCDYN_OK; ErrMsg = ''
    f = CD_ZERO
    area = 0.25_wp*PI_L*diam*diam
    gp = [0.5_wp*(CD_ONE - 0.8611363115940526_wp), 0.5_wp*(CD_ONE - 0.3399810435848563_wp), &
          0.5_wp*(CD_ONE + 0.3399810435848563_wp), 0.5_wp*(CD_ONE + 0.8611363115940526_wp)]
    gw = 0.5_wp*[0.3478548451374538_wp, 0.6521451548625461_wp, &
                 0.6521451548625461_wp, 0.3478548451374538_wp]
    DO g = 1, NGP
      CALL CD_HermiteCable_Shapes(gp(g), l0, H, dH)
      DO c = 1, 3
        rpos(c) = H(1)*qe(c) + H(2)*qe(3 + c) + H(3)*qe(6 + c) + H(4)*qe(9 + c)
        rp(c) = dH(1)*qe(c) + dH(2)*qe(3 + c) + dH(3)*qe(6 + c) + dH(4)*qe(9 + c)
        acc(c) = H(1)*ae(c) + H(2)*ae(3 + c) + H(3)*ae(6 + c) + H(4)*ae(9 + c)
      END DO
      IF (rpos(3) > waterline_z) CYCLE                 ! dry Gauss point: no added mass
      speed = SQRT(rp(1)**2 + rp(2)**2 + rp(3)**2)
      IF (speed <= 1.0e-12_wp) THEN
        ErrStat = CD_HCDYN_NOCONVERGE
        ErrMsg = 'added-mass force: degenerate centreline (|dr/dxi| ~ 0)'; RETURN
      END IF
      tangent = rp/speed
      fa = gw(g)*speed*rho*area*(can*acc + (cat - can)*DOT_PRODUCT(tangent, acc)*tangent)
      DO sh = 1, 4
        f(3*(sh - 1) + 1:3*sh) = f(3*(sh - 1) + 1:3*sh) + H(sh)*fa
      END DO
    END DO
  END SUBROUTINE added_mass_force

  SUBROUTINE element_end_residual(model, e, g, ErrStat, ErrMsg)
    !! g = f_int + f_damp - f_ext + M_e a_e of element e alone at the committed state, with the
    !! element's own distributed loads (see CD_HermiteCable_Dyn_Node_Recovery).
    TYPE(CD_HermiteCableDynType), INTENT(IN) :: model
    INTEGER, INTENT(IN) :: e
    REAL(wp), INTENT(OUT) :: g(12)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    REAL(wp), PARAMETER :: PI_L = 3.14159265358979323846_wp
    INTEGER, PARAMETER :: ZS(4) = [3, 6, 9, 12]
    REAL(wp) :: qe(12), ve(12), ae(12), fe(12), fx(12), energy, fdry(4), kdry(4, 4)
    REAL(wp) :: dry_wl, dry_b, dry_r, hf_mid(3), l0, fca(3), fcb(3), c, a4(4), m4(4, 4)
    REAL(wp) :: support(3), dsupport(3), nin(3), xa, xb, ca(4), cb(4)
    INTEGER :: es, k, inode
    LOGICAL :: dry
    CHARACTER(200) :: em2

    ErrStat = CD_HCDYN_OK; ErrMsg = ''; em2 = ''
    g = CD_ZERO
    l0 = model%l0(e)
    qe(1:6) = model%q(6*(e - 1) + 1:6*e); qe(7:12) = model%q(6*e + 1:6*(e + 1))
    ve(1:6) = model%v(6*(e - 1) + 1:6*e); ve(7:12) = model%v(6*e + 1:6*(e + 1))
    CALL CD_HermiteCable_Element(qe, l0, model%EA(e), model%EI(e), energy, fe, ErrStat=es, ErrMsg=em2, &
                                 axial_quadrature_order=model%axial_quadrature_order, &
                                 bending_quadrature_order=model%bending_quadrature_order)
    IF (es /= CD_HCABLE_OK) GOTO 900
    g = fe
    IF (model%has_axial_damping) THEN
      CALL CD_HermiteCable_Axial_Damping_Element(qe, ve, l0, model%BA(e), fx, ErrStat=es, ErrMsg=em2, &
                                                 quadrature_order=model%axial_quadrature_order)
      IF (es /= CD_HCDYN_OK) GOTO 900
      g = g + fx
    END IF
    ! consistent submerged weight (as assemble_residual)
    g(3) = g(3) + model%w(e)*0.5_wp*l0
    g(6) = g(6) + model%w(e)*l0*l0/12.0_wp
    g(9) = g(9) + model%w(e)*0.5_wp*l0
    g(12) = g(12) - model%w(e)*l0*l0/12.0_wp
    IF (model%has_drag .OR. model%has_am) THEN
      IF (model%has_drag) THEN
        dry_wl = model%waterline_z
        dry_b = model%rho_w*model%gravity*0.25_wp*PI_L*model%diam(e)**2
        dry_r = 0.5_wp*model%diam(e)
      ELSE
        dry_wl = model%am_wl
        dry_b = model%am_rho*model%gravity*0.25_wp*PI_L*model%am_diam(e)**2
        dry_r = 0.5_wp*model%am_diam(e)
      END IF
      IF (model%has_held_field) dry_wl = 0.5_wp*(model%hf_wl(e) + model%hf_wl(e + 1))
      CALL CD_HermiteCable_Dry_Buoyancy(qe(ZS), l0, dry_b, dry_wl, fdry, kdry, dry, radius=dry_r)
      IF (dry) g(ZS) = g(ZS) + fdry
    END IF
    IF (model%has_drag) THEN
      IF (model%has_wave .AND. model%wv_ncomp > 0) THEN
        CALL CD_HermiteCable_Drag_Element(qe, ve, l0, model%current, model%waterline_z, &
                                          model%rho_w, model%diam(e), model%cdn(e), model%cdt(e), &
                                          fx, ErrStat=es, ErrMsg=em2, &
                                          wv_depth=model%wv_depth, wv_dir=model%wv_dir, wv_t=model%t, &
                                          wvc_amp=model%wv_ampc, wvc_om=model%wv_omc, &
                                          wvc_k=model%wv_kc, wvc_ph=model%wv_phc, &
                                          wvc_e2kd=model%wv_e2kd)
      ELSE IF (model%has_wave) THEN
        CALL CD_HermiteCable_Drag_Element(qe, ve, l0, model%current, model%waterline_z, &
                                          model%rho_w, model%diam(e), model%cdn(e), model%cdt(e), &
                                          fx, ErrStat=es, ErrMsg=em2, &
                                          wv_h=model%wv_h, wv_om=model%wv_om, wv_k=model%wv_k, &
                                          wv_depth=model%wv_depth, wv_dir=model%wv_dir, wv_t=model%t)
      ELSE IF (model%has_held_field) THEN
        CALL CD_HermiteCable_Drag_Element(qe, ve, l0, &
                                          model%current + 0.5_wp*(model%hf_u(:, e) + model%hf_u(:, e + 1)), &
                                          0.5_wp*(model%hf_wl(e) + model%hf_wl(e + 1)), &
                                          model%rho_w, model%diam(e), model%cdn(e), model%cdt(e), &
                                          fx, ErrStat=es, ErrMsg=em2)
      ELSE
        CALL CD_HermiteCable_Drag_Element(qe, ve, l0, model%current, model%waterline_z, &
                                          model%rho_w, model%diam(e), model%cdn(e), model%cdt(e), &
                                          fx, ErrStat=es, ErrMsg=em2)
      END IF
      IF (es /= CD_HCDYN_OK) GOTO 900
      g = g - fx
    END IF
    IF (model%has_viv) THEN
      CALL viv_element_lift(model, model%q, model%v, e, fx, es, em2)
      IF (es /= CD_HCDYN_OK) GOTO 900
      g = g - fx
    END IF
    IF (model%has_am .AND. (model%has_wave .OR. model%has_held_field)) THEN
      IF (model%has_held_field) THEN
        hf_mid = 0.5_wp*(model%hf_ud(:, e) + model%hf_ud(:, e + 1))
        CALL CD_HermiteCable_FK_Element(qe, l0, 0.5_wp*(model%hf_wl(e) + model%hf_wl(e + 1)), &
                                        model%am_rho, model%am_diam(e), model%am_can(e), model%am_cat(e), &
                                        wv_depth=CD_ZERO, wv_dir=CD_ZERO, wv_t=CD_ZERO, &
                                        ffk=fx, ErrStat=es, ErrMsg=em2, hf_a=hf_mid)
      ELSE IF (model%wv_ncomp > 0) THEN
        CALL CD_HermiteCable_FK_Element(qe, l0, model%am_wl, model%am_rho, model%am_diam(e), &
                                        model%am_can(e), model%am_cat(e), &
                                        wv_depth=model%wv_depth, wv_dir=model%wv_dir, wv_t=model%t, &
                                        ffk=fx, ErrStat=es, ErrMsg=em2, &
                                        wvc_amp=model%wv_ampc, wvc_om=model%wv_omc, &
                                        wvc_k=model%wv_kc, wvc_ph=model%wv_phc, wvc_e2kd=model%wv_e2kd)
      ELSE
        CALL CD_HermiteCable_FK_Element(qe, l0, model%am_wl, model%am_rho, model%am_diam(e), &
                                        model%am_can(e), model%am_cat(e), &
                                        wv_h=model%wv_h, wv_om=model%wv_om, wv_k=model%wv_k, &
                                        wv_depth=model%wv_depth, wv_dir=model%wv_dir, wv_t=model%t, &
                                        ffk=fx, ErrStat=es, ErrMsg=em2)
      END IF
      IF (es /= CD_HCDYN_OK) GOTO 900
      g = g - fx
    END IF
    ! Seabed contact acts at the nodes; spread over the grounded line next to each node it is the
    ! distributed floor reaction it stands for. Its consistent share is taken out of the element,
    ! so a line resting on the floor carries no fixed-end moment of its own weight. A node's
    ! reaction is spread uniformly over the grounded part of its two half-elements and shared
    ! between them by that length (grounded_share). The touchdown element, on the floor at one
    ! end only, is grounded from that end to the touchdown point, located on it from the two
    ! nodes' clearances; it takes the reaction of that stretch alone (spreading the reaction over
    ! its half understated the tension of the last suspended node by the floor reaction of half
    ! an element, 5 % on a 10 m lazy-wave mesh). The grounded stretch grows to the half-element
    ! as the suspended node reaches the floor, so the spread, and the node outputs, change
    ! continuously as nodes ground and lift off.
    IF (model%has_contact .OR. model%kn > CD_ZERO) THEN
      CALL node_contact_normal(model, e, fca, es, em2)
      IF (es /= CD_HCDYN_OK) GOTO 900
      CALL node_contact_normal(model, e + 1, fcb, es, em2)
      IF (es /= CD_HCDYN_OK) GOTO 900
      CALL grounded_share(e, e, fca, xa, es)
      IF (es /= CD_HCDYN_OK) GOTO 900
      CALL grounded_share(e + 1, e, fcb, xb, es)
      IF (es /= CD_HCDYN_OK) GOTO 900
      ! A held end whose end element lies on the floor (assemble_residual): the seabed carries the
      ! element's weight with its consistent end moment, which the held end node's own contact
      ! (a point reaction at an anchor sitting on the floor) cannot. The floor reaction of the
      ! end half of that element is the support share of its weight, uniform with the reaction
      ! of the neighbouring node, so that a laid end element carries no fixed-end moment.
      IF (e == 1) THEN
        IF (held_end_floor_support(model, model%q, 1, support, dsupport, inode, nin)) THEN
          fca = (0.5_wp*model%w(1)*l0)*support; xa = 0.5_wp
        END IF
      END IF
      IF (e == model%ne) THEN
        IF (held_end_floor_support(model, model%q, 2, support, dsupport, inode, nin)) THEN
          fcb = (0.5_wp*model%w(e)*l0)*support; xb = 0.5_wp
        END IF
      END IF
      ! the loads fca and fcb spread uniformly over xi in [0, xa] and [1 - xb, 1]: the integrals
      ! of the four shapes over those stretches per unit length of xi (spread_shapes)
      ca = spread_shapes(xa)
      cb = spread_shapes(xb)
      g(1:3) = g(1:3) - (ca(1)*fca + cb(3)*fcb)
      g(4:6) = g(4:6) - l0*(ca(2)*fca - cb(4)*fcb)
      g(7:9) = g(7:9) - (ca(3)*fca + cb(1)*fcb)
      g(10:12) = g(10:12) - l0*(ca(4)*fca - cb(2)*fcb)
    END IF
    ae(1:6) = model%a(6*(e - 1) + 1:6*e); ae(7:12) = model%a(6*e + 1:6*(e + 1))
    IF (ANY(ABS(ae) > CD_ZERO)) THEN
      ! consistent structural mass, closed form of CD_HermiteCable_Mass: per component the
      ! 4 x 4 cubic-Hermite block on [r1, m1, r2, m2]
      c = model%rho_a(e)*l0/420.0_wp
      m4 = RESHAPE([156.0_wp, 22.0_wp*l0, 54.0_wp, -13.0_wp*l0, &
                    22.0_wp*l0, 4.0_wp*l0*l0, 13.0_wp*l0, -3.0_wp*l0*l0, &
                    54.0_wp, 13.0_wp*l0, 156.0_wp, -22.0_wp*l0, &
                    -13.0_wp*l0, -3.0_wp*l0*l0, -22.0_wp*l0, 4.0_wp*l0*l0], [4, 4])
      DO k = 1, 3
        a4 = [ae(k), ae(3 + k), ae(6 + k), ae(9 + k)]
        a4 = c*MATMUL(m4, a4)
        g(k) = g(k) + a4(1); g(3 + k) = g(3 + k) + a4(2)
        g(6 + k) = g(6 + k) + a4(3); g(9 + k) = g(9 + k) + a4(4)
      END DO
      IF (model%has_am) THEN
        dry_wl = model%am_wl
        IF (model%has_held_field) dry_wl = 0.5_wp*(model%hf_wl(e) + model%hf_wl(e + 1))
        CALL added_mass_force(qe, ae, l0, dry_wl, model%am_rho, model%am_diam(e), model%am_can(e), &
                              model%am_cat(e), fx, es, em2)
        IF (es /= CD_HCDYN_OK) GOTO 900
        g = g + fx
      END IF
    END IF
    RETURN
900 ErrStat = CD_HCDYN_NOCONVERGE
    ErrMsg = 'CD_HermiteCable_Dyn_Node_Recovery: element '//TRIM(em2)

  CONTAINS

    SUBROUTINE grounded_share(node, el, fc, x, esx)
      !! Element el's share of the floor reaction fc of node (an end of el), and the grounded
      !! stretch x of el's half beside the node (a fraction of el, at most 1/2) that it is
      !! spread over. Each half-element beside the node is grounded over x = 1/2 when its far
      !! node is on the floor as well, and otherwise up to the touchdown point, where the
      !! clearance interpolated linearly between the node (on the floor) and the far node (above
      !! it) reaches the contact onset; the reaction is shared between the two halves by the
      !! grounded length x l0. The touchdown point reaches the far node as that node reaches
      !! the floor and the node itself as it lifts off (its reaction then vanishing), so the
      !! share and the stretch are continuous in the configuration. A node off the floor with a
      !! reaction (a held end the floor supports) keeps the tributary-length share over the
      !! half-element.
      INTEGER, INTENT(IN) :: node, el
      REAL(wp), INTENT(INOUT) :: fc(3)
      REAL(wp), INTENT(OUT) :: x
      INTEGER, INTENT(OUT) :: esx
      REAL(wp) :: ext, ext_el, grounded_len, c_node, c_far, fdum(3)
      LOGICAL :: grounded
      INTEGER :: k, far
      esx = CD_HCDYN_OK
      x = 0.5_wp
      IF (.NOT. ANY(ABS(fc) > CD_ZERO)) RETURN
      CALL node_contact_normal(model, node, fdum, esx, em2, clearance=c_node)
      IF (esx /= CD_HCDYN_OK) RETURN
      grounded_len = CD_ZERO
      ext_el = CD_ZERO
      DO k = MAX(1, node - 1), MIN(model%ne, node)
        CALL element_on_floor(k, grounded, esx)
        IF (esx /= CD_HCDYN_OK) RETURN
        IF (grounded) THEN
          ext = 0.5_wp
        ELSE
          far = MERGE(k, k + 1, k == node - 1)
          CALL node_contact_normal(model, far, fdum, esx, em2, clearance=c_far)
          IF (esx /= CD_HCDYN_OK) RETURN
          ext = CD_ZERO
          IF (c_node < CD_ZERO .AND. c_far > c_node) ext = MIN(0.5_wp, -c_node/(c_far - c_node))
        END IF
        grounded_len = grounded_len + ext*model%l0(k)
        IF (k == el) ext_el = ext
      END DO
      IF (grounded_len > CD_ZERO) THEN
        fc = fc*(ext_el*model%l0(el)/grounded_len)
        x = ext_el
      ELSE IF (model%trib(node) > CD_ZERO) THEN
        fc = fc*(0.5_wp*model%l0(el)/model%trib(node))
      END IF
    END SUBROUTINE grounded_share

    PURE FUNCTION spread_shapes(xs) RESULT(cs)
      !! Integrals of the cubic Hermite shapes H1, H2/l0, H3, H4/l0 over xi in [0, xs], divided
      !! by xs: the consistent loads of a unit load spread uniformly over that stretch (a point
      !! load at xi = 0 as xs goes to zero). A stretch [1 - xs, 1] at the other end takes
      !! [cs(3), -cs(4), cs(1), -cs(2)].
      REAL(wp), INTENT(IN) :: xs
      REAL(wp) :: cs(4)
      cs(1) = CD_ONE - xs*xs + 0.5_wp*xs**3
      cs(2) = 0.5_wp*xs - 2.0_wp*xs*xs/3.0_wp + 0.25_wp*xs**3
      cs(3) = xs*xs - 0.5_wp*xs**3
      cs(4) = -xs*xs/3.0_wp + 0.25_wp*xs**3
    END FUNCTION spread_shapes

    SUBROUTINE element_on_floor(k, grounded, esx)
      !! Element k is grounded when both its nodes are on the floor (node_on_floor).
      INTEGER, INTENT(IN) :: k
      LOGICAL, INTENT(OUT) :: grounded
      INTEGER, INTENT(OUT) :: esx
      LOGICAL :: on1
      grounded = .FALSE.
      CALL node_on_floor(k, on1, esx)
      IF (esx /= CD_HCDYN_OK .OR. .NOT. on1) RETURN
      CALL node_on_floor(k + 1, grounded, esx)
    END SUBROUTINE element_on_floor

    SUBROUTINE node_on_floor(node, on, esx)
      !! A node is on the floor when it carries a floor reaction, or when it is a held line end
      !! whose end element the floor supports (held_end_floor_support): an anchor held exactly
      !! on the floor has no contact force of its own, yet its laid end element is grounded.
      INTEGER, INTENT(IN) :: node
      LOGICAL, INTENT(OUT) :: on
      INTEGER, INTENT(OUT) :: esx
      REAL(wp) :: fn(3), sup(3), dsup(3), nn_in(3)
      INTEGER :: in_node
      on = .FALSE.
      CALL node_contact_normal(model, node, fn, esx, em2)
      IF (esx /= CD_HCDYN_OK) RETURN
      on = ANY(ABS(fn) > CD_ZERO)
      IF (on) RETURN
      IF (node == 1) THEN
        on = held_end_floor_support(model, model%q, 1, sup, dsup, in_node, nn_in)
      ELSE IF (node == model%nn) THEN
        on = held_end_floor_support(model, model%q, 2, sup, dsup, in_node, nn_in)
      END IF
    END SUBROUTINE node_on_floor
  END SUBROUTINE element_end_residual

  PURE REAL(wp) FUNCTION CD_HermiteCable_Dyn_Max_Step_Rotation(model) RESULT(angle)
    !! Largest angle [rad] through which a nodal tangent turned over one committed step
    !! since initialisation: the time-step resolution of the tangent rotation.
    TYPE(CD_HermiteCableDynType), INTENT(IN) :: model
    angle = model%max_step_rotation
  END FUNCTION CD_HermiteCable_Dyn_Max_Step_Rotation

  PURE REAL(wp) FUNCTION vector_angle(a, b) RESULT(angle)
    !! Angle between two vectors (zero when either vanishes), robust near 0 and pi.
    REAL(wp), INTENT(IN) :: a(3), b(3)
    REAL(wp) :: c(3)
    c = [a(2)*b(3) - a(3)*b(2), a(3)*b(1) - a(1)*b(3), a(1)*b(2) - a(2)*b(1)]
    angle = ATAN2(NORM2(c), DOT_PRODUCT(a, b))
  END FUNCTION vector_angle

  SUBROUTINE CD_HermiteCable_Dyn_EndConnection_Moment(model, node, moment, ErrStat, ErrMsg)
    !! Moment exerted by the line-end connection on its supporting body. Finite
    !! mode evaluates the spring force; rigid mode recovers the exact constraint
    !! reaction from the committed equation of motion. Pinned mode returns zero.
    TYPE(CD_HermiteCableDynType), INTENT(INOUT) :: model
    INTEGER, INTENT(IN) :: node
    REAL(wp), INTENT(OUT) :: moment(3)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg

    INTEGER :: iend, base, es
    REAL(wp) :: f_ec(3), k_ec(3, 3), direction(3), bend_moment(3)
    CHARACTER(1024) :: em

    moment = CD_ZERO
    ErrStat = CD_HCDYN_OK
    ErrMsg = ''
    IF (.NOT. model%initialized) THEN
      ErrStat = CD_HCDYN_BADINPUT
      ErrMsg = 'CD_HermiteCable_Dyn_EndConnection_Moment: model not initialised'
      RETURN
    END IF
    IF (node == 1) THEN
      iend = 1
    ELSE IF (node == model%nn) THEN
      iend = 2
    ELSE
      ErrStat = CD_HCDYN_BADINPUT
      ErrMsg = 'CD_HermiteCable_Dyn_EndConnection_Moment: node must be a cable endpoint'
      RETURN
    END IF
    IF (model%tw_active) THEN
      ! Nodal twist: -dE/dw of the end frame. A rigid end's element twists by rho(w) through
      ! the frame (its normal carried to the end node is the node's director): -M_e drho/dw. An
      ! elastic end's spring twists by -+psi(w): +-k tw dpsi/dw. With f(w) = angle(G(d' -> x) n'
      ! -> u) of the frame turned by exp(w), G(d' -> x) n' = Rot(x, w . d + Omega(d, d', x))
      ! G(d -> x) n to first order, so df/dw = -d - d x dOmega/dy(d, d, x), and the frame's
      ! director in a transport triangle adds d x dOmega/dd. The slaved tangent of a rigid
      ! bending end adds its share through the constraint reaction below. The held end section
      ! turns with the frame and its held angle, chi_dot = -+drho/dw . omega + phi_dot (End 1,
      ! End 2): its polar inertia I adds -I chi_ddot dchi/dw. A free end transmits no torque.
      BLOCK
        REAL(wp) :: rho, beta, g(12), h(12, 12), ew(3, 2), psi, gl(3), hl(3, 3), lw(3), tw, sg, chi_dd
        IF (model%tw_rigid(iend)) THEN
          CALL twist_reference(model, MERGE(1, model%ne, iend == 1), model%q, model%torsion%ends, .FALSE., rho, &
                               beta, g, h, es, em, end_w=ew)
          IF (es /= CD_HCDYN_OK) THEN
            ErrStat = es
            ErrMsg = 'CD_HermiteCable_Dyn_EndConnection_Moment: '//TRIM(em)
            RETURN
          END IF
          moment = -model%tw_mt(MERGE(1, model%ne, iend == 1))*ew(:, iend)
          sg = MERGE(-CD_ONE, CD_ONE, iend == 1)
          chi_dd = sg*DOT_PRODUCT(ew(:, iend), model%tw_oal(:, iend)) + model%tw_al(node)
          moment = moment - model%tw_mass(node)*chi_dd*sg*ew(:, iend)
        ELSE IF (tw_spring(model, iend)) THEN
          CALL twist_link(model, iend, model%q, model%torsion%ends, .FALSE., psi, gl, hl, es, em, end_w=lw)
          IF (es /= CD_HCDYN_OK) THEN
            ErrStat = es
            ErrMsg = 'CD_HermiteCable_Dyn_EndConnection_Moment: '//TRIM(em)
            RETURN
          END IF
          IF (iend == 1) THEN
            tw = model%tw_phi(1) - psi
            moment = tw/model%torsion%end_compliance(1)*lw
          ELSE
            tw = psi + model%torsion%phi - model%tw_phi(model%nn)
            moment = -tw/model%torsion%end_compliance(2)*lw
          END IF
        END IF
      END BLOCK
    ELSE IF (model%torsion%active) THEN
      ! Torque of the condensed torsion on the support: the generalised moment
      ! -dE_t/dw = M_t dTheta/dw of the end frame (its axial part is -+M_t d); the slaved
      ! tangent of a rigid end adds its share through the constraint reaction below.
      BLOCK
        REAL(wp) :: th, mt, eg(6)
        IF (.NOT. torsion_cache_matches(model)) THEN
          CALL torsion_cache_fill(model, es, em)
          IF (es /= CD_HCDYN_OK) THEN
            ErrStat = es
            ErrMsg = 'CD_HermiteCable_Dyn_EndConnection_Moment: '//TRIM(em)
            RETURN
          END IF
        END IF
        CALL CD_HermiteCable_Dyn_Torsion_State(model, th, mt, es, em, end_grad=eg)
        IF (es /= CD_HCDYN_OK) THEN
          ErrStat = es
          ErrMsg = 'CD_HermiteCable_Dyn_EndConnection_Moment: '//TRIM(em)
          RETURN
        END IF
        moment = mt*eg(3*iend - 2:3*iend)
      END BLOCK
    END IF
    IF (.NOT. model%has_endconn) RETURN
    IF (model%endconn_mode(iend) == CD_ENDCONN_PINNED) RETURN

    base = 6*(node - 1) + 3
    IF (model%endconn_mode(iend) == CD_ENDCONN_FINITE) THEN
      CALL CD_EndConn_Spring(model%q(base + 1:base + 3), model%endconn_d0(:, iend), &
                             model%endconn_k(iend), f_ec, k_ec, es, em)
      IF (es /= CD_ENDCONN_OK) THEN
        ErrStat = CD_HCDYN_NOCONVERGE
        ErrMsg = 'CD_HermiteCable_Dyn_EndConnection_Moment: '//TRIM(em)
        RETURN
      END IF
    ELSE
      ! G0 is the unconstrained dynamic residual. The constraint contribution
      ! required in the residual is -G0 in the transverse tangent plane; under
      ! virtual work, m cross that contribution is the line's moment on the
      ! supporting body, matching the finite-spring convention. Only the end tangent's three
      ! rows are needed: without torsion (which couples every element) they come from the
      ! elements at the node, bit-identical to the full assembly (node_reaction).
      IF (model%torsion%active) THEN
        CALL assemble_residual(model, model%q, model%v, model%t, .TRUE., .FALSE., es, em)
        IF (es /= CD_HCDYN_OK) THEN
          ErrStat = es
          ErrMsg = 'CD_HermiteCable_Dyn_EndConnection_Moment: '//TRIM(em)
          RETURN
        END IF
        model%ws_Msumb = model%Mgb
        IF (model%has_am) THEN
          CALL assemble_added_mass(model, model%q, es, em)
          IF (es /= CD_HCDYN_OK) THEN
            ErrStat = es
            ErrMsg = 'CD_HermiteCable_Dyn_EndConnection_Moment: '//TRIM(em)
            RETURN
          END IF
          model%ws_Msumb = model%ws_Msumb + model%ws_Mamb
        END IF
        CALL band_matvec(model%ws_Msumb, model%a, model%ws_inert)
        f_ec = -(model%ws_inert(base + 1:base + 3) + model%ws_R(base + 1:base + 3))
      ELSE
        CALL node_reaction(model, node, f_ec, es, em, tangent_rows=.TRUE.)
        IF (es /= CD_HCDYN_OK) THEN
          ErrStat = es
          ErrMsg = 'CD_HermiteCable_Dyn_EndConnection_Moment: '//TRIM(em)
          RETURN
        END IF
      END IF
      direction = model%endconn_d0(:, iend)
      f_ec = f_ec - DOT_PRODUCT(f_ec, direction)*direction
    END IF
    CALL CD_EndConn_Reaction_Moment(model%q(base + 1:base + 3), f_ec, bend_moment, es, em)
    IF (es /= CD_ENDCONN_OK) THEN
      ErrStat = CD_HCDYN_NOCONVERGE
      ErrMsg = 'CD_HermiteCable_Dyn_EndConnection_Moment: '//TRIM(em)
      moment = CD_ZERO
      RETURN
    END IF
    ! without torsion the reaction moment is the result itself (no +0.0 added, so a -0.0
    ! component keeps its sign as before torsion existed)
    IF (model%torsion%active) THEN
      moment = moment + bend_moment
    ELSE
      moment = bend_moment
    END IF
  END SUBROUTINE CD_HermiteCable_Dyn_EndConnection_Moment

  SUBROUTINE CD_HermiteCable_Dyn_Set_Torsion(model, torsion, ErrStat, ErrMsg)
    !! Install the condensed torsion of a converged static solve (CD_HermiteCable_Static_Solve
    !! with torsion): the end frames and GJ in the model's solve frame, Phi and the accepted
    !! Theta. The residual, the support reaction, the end force, the connection moment (now
    !! including the torque) and the energy then include E_t = (Phi - Theta)**2/(2 C); the
    !! acceleration is recomputed from the complete load set. An inactive description removes
    !! the torsion. The time step then carries the torsion (see CD_HermiteCable_Dyn_Step); its
    !! scratch is sized here, so a step allocates nothing. Like a new end connection, a change
    !! of the load set invalidates the step snapshot (CD_HermiteCable_Dyn_Restore then fails
    !! closed); a failed call leaves the model, its snapshot included, as it was. A description
    !! with the polar inertia irn installs the nodal twist instead of the condensed torsion in
    !! the dynamics (tw_init): the static uniform torque sets the angles, which then carry the
    !! torsional inertia and the damping bt.
    TYPE(CD_HermiteCableDynType), INTENT(INOUT) :: model
    TYPE(CD_HermiteTorsionType), INTENT(IN) :: torsion
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    TYPE(CD_HermiteTorsionType) :: saved
    REAL(wp) :: th, mt
    REAL(wp) :: saved_step_ends(3, 4), saved_step_phi, saved_snap_theta, saved_snap_phi, saved_snap_ends(3, 4)
    REAL(wp) :: saved_snap_torque
    REAL(wp) :: saved_drive_ends(3, 4), saved_drive_phi
    LOGICAL :: saved_snap_valid, saved_drive_set, saved_tw_active
    REAL(wp), ALLOCATABLE :: saved_tw(:)
    INTEGER :: es, iend
    CHARACTER(1024) :: em
    ErrStat = CD_HCDYN_OK
    ErrMsg = ''
    IF (.NOT. model%initialized) THEN
      ErrStat = CD_HCDYN_BADINPUT
      ErrMsg = 'CD_HermiteCable_Dyn_Set_Torsion: model not initialised'
      RETURN
    END IF
    saved = model%torsion
    saved_tw_active = model%tw_active
    IF (saved_tw_active) THEN
      ALLOCATE (saved_tw(tw_pack_size(model)))
      CALL tw_pack(model, saved_tw)
    END IF
    model%tors_c_valid = .FALSE.
    IF (.NOT. torsion%active) THEN
      model%tw_active = .FALSE.
      model%torsion = CD_HermiteTorsionType()
    ELSE
      CALL CD_HermiteTorsion_Validate(torsion, model%l0, es, em)
      IF (es /= CD_HTORS_OK) THEN
        ErrStat = CD_HCDYN_BADINPUT
        ErrMsg = 'CD_HermiteCable_Dyn_Set_Torsion: '//TRIM(em)
        RETURN
      END IF
      IF (.NOT. torsion%has_theta) THEN
        ErrStat = CD_HCDYN_BADINPUT
        ErrMsg = 'CD_HermiteCable_Dyn_Set_Torsion: the torsion state has no accepted Theta (solve the statics first)'
        RETURN
      END IF
      ! as in the statics: a rigid end's director is its connection direction (the tangent there)
      DO iend = 1, 2
        IF (.NOT. model%has_endconn) EXIT
        IF (model%endconn_mode(iend) /= CD_ENDCONN_RIGID) CYCLE
        IF (NORM2(torsion%ends(:, 2*iend - 1) - model%endconn_d0(:, iend)) > 1.0e-8_wp) THEN
          ErrStat = CD_HCDYN_BADINPUT
          WRITE (em, '(A,I0,A)', IOSTAT=es) 'the director at rigid end ', iend, &
            ' must be its connection direction (set the end connections first)'
          ErrMsg = 'CD_HermiteCable_Dyn_Set_Torsion: '//TRIM(em)
          RETURN
        END IF
      END DO
      IF (model%tors_work%nn /= model%nn) THEN
        CALL CD_HermiteTorsion_Work_Init(model%tors_work, model%nn, es, em)
        IF (es /= CD_HTORS_OK) THEN
          ErrStat = CD_HCDYN_BADINPUT
          ErrMsg = 'CD_HermiteCable_Dyn_Set_Torsion: '//TRIM(em)
          RETURN
        END IF
      END IF
      IF (.NOT. ALLOCATED(model%tors_g)) ALLOCATE (model%tors_g(model%ndof), model%tors_gq(model%ndof), &
                                                   model%tors_gk(model%ndof), model%tors_zk(model%ndof))
      IF (.NOT. ALLOCATED(model%tors_c_q)) ALLOCATE (model%tors_c_q(model%ndof))
      model%tors_g = CD_ZERO
      model%tors_gq = CD_ZERO
      model%tors_gk = CD_ZERO
      model%tors_zk = CD_ZERO
      model%tors_den = CD_ONE
      model%tw_active = .FALSE.
      model%torsion = torsion
      model%tors_c_valid = .FALSE.
      CALL CD_HermiteCable_Dyn_Torsion_State(model, th, mt, es, em)
      IF (es /= CD_HCDYN_OK) THEN
        CALL restore_twist()
        model%torsion = saved
        ErrStat = es
        ErrMsg = 'CD_HermiteCable_Dyn_Set_Torsion: '//TRIM(em)
        RETURN
      END IF
      model%torsion%theta = th
      model%torsion%torque = mt
      ! nodal twist dynamics when the torsion carries the polar rotary inertia
      IF (ALLOCATED(torsion%irn)) THEN
        CALL tw_init(model, mt, es, em)
        IF (es /= CD_HCDYN_OK) THEN
          CALL restore_twist()
          model%torsion = saved
          ErrStat = es
          ErrMsg = 'CD_HermiteCable_Dyn_Set_Torsion: '//TRIM(em)
          RETURN
        END IF
      END IF
    END IF
    saved_step_ends = model%tors_step_ends
    saved_step_phi = model%tors_step_phi
    saved_drive_ends = model%tors_drive_ends
    saved_drive_phi = model%tors_drive_phi
    saved_drive_set = model%tors_drive_set
    saved_snap_theta = model%snap_torsion_theta
    saved_snap_phi = model%snap_torsion_phi
    saved_snap_ends = model%snap_torsion_ends
    saved_snap_torque = model%snap_torsion_torque
    saved_snap_valid = model%snap_valid
    model%tors_use_step = .FALSE.
    model%tors_drive_set = .FALSE.
    model%tors_step_ends = model%torsion%ends
    model%tors_step_phi = model%torsion%phi
    model%snap_torsion_theta = model%torsion%theta
    model%snap_torsion_phi = model%torsion%phi
    model%snap_torsion_ends = model%torsion%ends
    model%snap_torsion_torque = model%torsion%torque
    ! the snapshot predates the new load set (as for CD_HermiteCable_Dyn_Set_EndConnection)
    model%snap_valid = .FALSE.
    model%fc_valid = .FALSE.
    model%fc_clears = model%fc_clears + 1
    model%tr_valid = .FALSE.
    CALL CD_HermiteCable_Dyn_Recompute_Acceleration(model, es, em)
    IF (es /= CD_HCDYN_OK) THEN
      CALL restore_twist()
      model%torsion = saved
      model%tors_c_valid = .FALSE.
      model%tors_step_ends = saved_step_ends
      model%tors_step_phi = saved_step_phi
      model%tors_drive_ends = saved_drive_ends
      model%tors_drive_phi = saved_drive_phi
      model%tors_drive_set = saved_drive_set
      model%snap_torsion_theta = saved_snap_theta
      model%snap_torsion_phi = saved_snap_phi
      model%snap_torsion_ends = saved_snap_ends
      model%snap_torsion_torque = saved_snap_torque
      model%snap_valid = saved_snap_valid
      ErrStat = es
      ErrMsg = 'CD_HermiteCable_Dyn_Set_Torsion: '//TRIM(em)
    END IF

  CONTAINS

    SUBROUTINE restore_twist()
      !! The nodal twist as it was before the call (with the torsion description restored
      !! after it, from which the derived rigid ends, held angles and inertia follow).
      model%tw_active = saved_tw_active
      IF (.NOT. saved_tw_active) RETURN
      CALL tw_unpack(model, saved_tw)
      CALL tw_set_derived(model, saved)
    END SUBROUTINE restore_twist
  END SUBROUTINE CD_HermiteCable_Dyn_Set_Torsion

  SUBROUTINE CD_HermiteCable_Dyn_Torsion_State(model, theta, torque, ErrStat, ErrMsg, grad, end_grad, q_eval, &
                                               end_dr)
    !! Theta (unwrapped against the stored accepted value), the torque M_t = (Phi - Theta)/C and,
    !! optionally, dTheta/dq, dTheta/d[w_1, w_2] and dTheta/dr at the first and last node (end_dr
    !! columns) at the committed state (or at q_eval). Read only: the stored Theta is not
    !! advanced. A change of more than pi/2 from the stored value fails closed (a 2 pi branch
    !! could otherwise be lost). At the committed state without grad it reads the query cache
    !! when that matches the state (no heap allocation); otherwise it evaluates the kernel.
    TYPE(CD_HermiteCableDynType), INTENT(IN) :: model
    REAL(wp), INTENT(OUT) :: theta, torque
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    REAL(wp), INTENT(OUT), OPTIONAL :: grad(:), end_grad(6)
    REAL(wp), INTENT(IN), OPTIONAL :: q_eval(:)
    REAL(wp), INTENT(OUT), OPTIONAL :: end_dr(3, 2)
    REAL(wp), ALLOCATABLE :: g(:)
    REAL(wp) :: raw, eg(6), c
    INTEGER :: es, nb
    CHARACTER(1024) :: em
    theta = CD_ZERO
    torque = CD_ZERO
    IF (PRESENT(grad)) grad = CD_ZERO
    IF (PRESENT(end_grad)) end_grad = CD_ZERO
    IF (PRESENT(end_dr)) end_dr = CD_ZERO
    ErrStat = CD_HCDYN_OK
    ErrMsg = ''
    IF (.NOT. model%torsion%active) RETURN
    ! Nodal twist: the committed Theta_eff and mean torque (the condensed kernel answers the
    ! derivative queries, the quasi-static stiffness a static caller takes)
    IF (model%tw_active .AND. .NOT. (PRESENT(grad) .OR. PRESENT(end_grad) .OR. PRESENT(q_eval) .OR. &
                                     PRESENT(end_dr))) THEN
      theta = model%torsion%theta
      torque = model%torsion%torque
      RETURN
    END IF
    IF (.NOT. (PRESENT(grad) .OR. PRESENT(q_eval))) THEN
      IF (torsion_cache_matches(model)) THEN
        theta = model%tors_c_theta
        torque = (model%torsion%phi - theta)/CD_HermiteTorsion_Compliance(model%torsion, model%l0)
        IF (PRESENT(end_grad)) end_grad = model%tors_c_eg
        IF (PRESENT(end_dr)) end_dr = model%tors_c_gend
        RETURN
      END IF
    END IF
    ALLOCATE (g(model%ndof))
    IF (PRESENT(q_eval)) THEN
      CALL CD_HermiteTorsion_Line(q_eval, model%l0, model%torsion%ends, raw, g, es, em, end_grad=eg, &
                                  couple=model%torsion%couple, quadrature_order=model%torsion%quadrature_order)
    ELSE
      CALL CD_HermiteTorsion_Line(model%q, model%l0, model%torsion%ends, raw, g, es, em, end_grad=eg, &
                                  couple=model%torsion%couple, quadrature_order=model%torsion%quadrature_order)
    END IF
    IF (es /= CD_HTORS_OK) THEN
      ErrStat = CD_HCDYN_NOCONVERGE
      ErrMsg = 'torsion: '//TRIM(em)
      RETURN
    END IF
    theta = CD_HermiteTorsion_Unwrap(raw, model%torsion%theta)
    ! (a line free at one end carries no condensed torque on any branch: the nodal twist, not
    ! Theta, holds its state, and its accepted Theta is only the view Phi less the summed twist)
    IF (ABS(theta - model%torsion%theta) > CD_HTORS_MAX_STEP .AND. .NOT. ANY(model%torsion%end_free)) THEN
      ErrStat = CD_HCDYN_NOCONVERGE
      ErrMsg = 'torsion: the twist moved more than pi/2 from its accepted value'
      theta = CD_ZERO
      RETURN
    END IF
    c = CD_HermiteTorsion_Compliance(model%torsion, model%l0)
    torque = (model%torsion%phi - theta)/c
    IF (PRESENT(grad)) grad = g
    IF (PRESENT(end_grad)) end_grad = eg
    IF (PRESENT(end_dr)) THEN
      nb = 6*(model%nn - 1)
      end_dr(:, 1) = g(1:3)
      end_dr(:, 2) = g(nb + 1:nb + 3)
    END IF
  END SUBROUTINE CD_HermiteCable_Dyn_Torsion_State

  LOGICAL FUNCTION torsion_cache_matches(model) RESULT(match)
    !! Whether the torsion query cache holds the evaluation at the model's committed q, end
    !! frames and accepted Theta (bitwise; no temporaries).
    TYPE(CD_HermiteCableDynType), INTENT(IN) :: model
    INTEGER :: i, j
    match = .FALSE.
    IF (.NOT. model%tors_c_valid .OR. .NOT. ALLOCATED(model%tors_c_q) .OR. .NOT. ALLOCATED(model%q)) RETURN
    IF (SIZE(model%tors_c_q) /= SIZE(model%q)) RETURN
    IF (.NOT. same_bits(model%tors_c_prev, model%torsion%theta)) RETURN
    DO j = 1, 4
      DO i = 1, 3
        IF (.NOT. same_bits(model%tors_c_ends(i, j), model%torsion%ends(i, j))) RETURN
      END DO
    END DO
    DO i = 1, SIZE(model%q)
      IF (.NOT. same_bits(model%tors_c_q(i), model%q(i))) RETURN
    END DO
    match = .TRUE.
  CONTAINS
    PURE LOGICAL FUNCTION same_bits(a, b) RESULT(same)
      REAL(wp), INTENT(IN) :: a, b
      same = TRANSFER(a, 0_INT64) == TRANSFER(b, 0_INT64)
    END FUNCTION same_bits
  END FUNCTION torsion_cache_matches

  SUBROUTINE torsion_cache_fill(model, ErrStat, ErrMsg)
    !! Evaluate the torsion query cache at the committed q and end frames, allocation-free (the
    !! kernel workspace and tors_gq). On failure the cache is left invalid and the error named.
    TYPE(CD_HermiteCableDynType), INTENT(INOUT) :: model
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    REAL(wp) :: raw, eg(6), th
    INTEGER :: es, nb, i
    CHARACTER(1024) :: em
    ErrStat = CD_HCDYN_OK
    ErrMsg = ''
    model%tors_c_valid = .FALSE.
    IF (.NOT. model%torsion%active) RETURN
    IF (.NOT. ALLOCATED(model%tors_c_q) .OR. .NOT. ALLOCATED(model%tors_gq)) RETURN
    IF (SIZE(model%tors_c_q) /= SIZE(model%q) .OR. model%tors_work%nn /= model%nn) RETURN
    CALL CD_HermiteTorsion_Line(model%q, model%l0, model%torsion%ends, raw, model%tors_gq, es, em, end_grad=eg, &
                                couple=model%torsion%couple, quadrature_order=model%torsion%quadrature_order, &
                                work=model%tors_work)
    IF (es /= CD_HTORS_OK) THEN
      ErrStat = CD_HCDYN_NOCONVERGE
      ErrMsg = 'torsion: '//TRIM(em)
      RETURN
    END IF
    th = CD_HermiteTorsion_Unwrap(raw, model%torsion%theta)
    IF (ABS(th - model%torsion%theta) > CD_HTORS_MAX_STEP) THEN
      ErrStat = CD_HCDYN_NOCONVERGE
      ErrMsg = 'torsion: the twist moved more than pi/2 from its accepted value'
      RETURN
    END IF
    DO i = 1, SIZE(model%q)
      model%tors_c_q(i) = model%q(i)
    END DO
    nb = 6*(model%nn - 1)
    model%tors_c_ends = model%torsion%ends
    model%tors_c_prev = model%torsion%theta
    model%tors_c_theta = th
    model%tors_c_eg = eg
    model%tors_c_gend(:, 1) = model%tors_gq(1:3)
    model%tors_c_gend(:, 2) = model%tors_gq(nb + 1:nb + 3)
    model%tors_c_valid = .TRUE.
  END SUBROUTINE torsion_cache_fill

  SUBROUTINE CD_HermiteCable_Dyn_Snapshot(model, ErrStat, ErrMsg)
    !! Capture the committed step state (q, v, a, t) and the unstretched lengths with their
    !! rates into the model-owned snapshot buffers (see the type note: the aggregate
    !! stage-then-commit contract). Buffers allocate on first use and are reused thereafter.
    TYPE(CD_HermiteCableDynType), INTENT(INOUT) :: model
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    ErrStat = CD_HCDYN_OK
    ErrMsg = ''
    IF (.NOT. model%initialized) THEN
      ErrStat = CD_HCDYN_BADINPUT
      ErrMsg = 'CD_HermiteCable_Dyn_Snapshot: model not initialised'
      RETURN
    END IF
    IF (.NOT. ALLOCATED(model%snap_q)) THEN
      ALLOCATE (model%snap_q(model%ndof), model%snap_v(model%ndof), model%snap_a(model%ndof), &
                model%snap_l0(model%ne), model%snap_l0_dot(model%ne), model%snap_l0_c(model%ne), &
                model%snap_l0_dot_c(model%ne))
    END IF
    model%snap_q = model%q
    model%snap_v = model%v
    model%snap_a = model%a
    model%snap_l0 = model%l0
    model%snap_has_ctrl = model%has_ctrl
    IF (model%has_ctrl) THEN
      model%snap_l0_dot = model%l0_dot
      model%snap_l0_c = model%l0_c
      model%snap_l0_dot_c = model%l0_dot_c
    ELSE
      model%snap_l0_dot = CD_ZERO
      model%snap_l0_c = model%l0
      model%snap_l0_dot_c = CD_ZERO
    END IF
    model%snap_t = model%t
    model%snap_endconn_d0 = model%endconn_d0
    model%snap_torsion_theta = model%torsion%theta
    model%snap_torsion_phi = model%torsion%phi
    model%snap_torsion_ends = model%torsion%ends
    model%snap_torsion_torque = model%torsion%torque
    IF (model%tw_active) THEN
      IF (.NOT. ALLOCATED(model%snap_tw)) ALLOCATE (model%snap_tw(tw_pack_size(model)), model%snap_tw_fcR(model%nn))
      CALL tw_pack(model, model%snap_tw)
      model%snap_tw_fcR = model%tw_fcR
    END IF
    IF (model%fr_active) model%snap_fr_anchor = model%fr_anchor
    IF (model%has_viv) THEN
      model%snap_viv_phi = model%viv_phi
      model%snap_viv_ms = model%viv_ms
    END IF
    ! the cached committed force goes with the state it describes (see fc_clears)
    model%snap_fc_valid = model%fc_valid .AND. ALLOCATED(model%fc_R)
    model%snap_fc_clears = model%fc_clears
    model%snap_stepped = .FALSE.
    IF (model%snap_fc_valid) THEN
      model%snap_fc_R = model%fc_R
      model%snap_fc_q = model%fc_q
      model%snap_fc_v = model%fc_v
      model%snap_fc_t = model%fc_t
      model%snap_fc_d0 = model%fc_d0
    END IF
    model%snap_na_steps_done = model%na_steps_done
    model%snap_na_iter_sum = model%na_iter_sum
    model%snap_na_mn_active = model%na_mn_active
    model%snap_tensile_event_count = model%tensile_event_count
    model%snap_tensile_worst_element = model%tensile_worst_element
    model%snap_tensile_worst_force = model%tensile_worst_force
    model%snap_tensile_worst_threshold = model%tensile_worst_threshold
    model%snap_tensile_worst_xi = model%tensile_worst_xi
    model%snap_tensile_worst_time = model%tensile_worst_time
    model%snap_max_step_rotation = model%max_step_rotation
    model%snap_recovery_event_count = model%recovery_event_count
    model%snap_recovery_max_substeps_used = model%recovery_max_substeps_used
    model%snap_valid = .TRUE.
  END SUBROUTINE CD_HermiteCable_Dyn_Snapshot

  SUBROUTINE CD_HermiteCable_Dyn_Restore(model, ErrStat, ErrMsg)
    !! Restore the committed step state from the last Snapshot. Fails closed if no valid
    !! snapshot exists (a restore must never silently run on stale or absent state). Lengths
    !! changed by active line control since the snapshot come back with the caches built
    !! from them, so no command need be re-applied.
    TYPE(CD_HermiteCableDynType), INTENT(INOUT) :: model
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    REAL(wp), ALLOCATABLE :: l0_restore(:)
    ErrStat = CD_HCDYN_OK
    ErrMsg = ''
    IF (.NOT. model%initialized) THEN
      ErrStat = CD_HCDYN_BADINPUT
      ErrMsg = 'CD_HermiteCable_Dyn_Restore: model not initialised'
      RETURN
    END IF
    IF (.NOT. model%snap_valid) THEN
      ErrStat = CD_HCDYN_BADINPUT
      ErrMsg = 'CD_HermiteCable_Dyn_Restore: no valid snapshot'
      RETURN
    END IF
    ! Lengths first (active line control): when they moved since the snapshot, the
    ! length-dependent caches are rebuilt from the snapshot lengths before any state is
    ! written, so a failed rebuild leaves the model unchanged.
    IF (.NOT. ALL(bits_equal(model%l0, model%snap_l0))) THEN
      ! a copy, so no subobject of model is associated with a second dummy
      l0_restore = model%snap_l0
      CALL rebuild_length_caches(model, l0_restore, ErrStat, ErrMsg)
      IF (ErrStat /= CD_HCDYN_OK) THEN
        ErrMsg = 'CD_HermiteCable_Dyn_Restore: '//TRIM(ErrMsg)
        RETURN
      END IF
    END IF
    model%has_ctrl = model%snap_has_ctrl
    IF (model%has_ctrl) THEN
      model%l0_dot = model%snap_l0_dot
      model%l0_c = model%snap_l0_c
      model%l0_dot_c = model%snap_l0_dot_c
    END IF
    model%q = model%snap_q
    model%v = model%snap_v
    model%a = model%snap_a
    model%t = model%snap_t
    model%endconn_d0 = model%snap_endconn_d0
    model%torsion%theta = model%snap_torsion_theta
    model%torsion%phi = model%snap_torsion_phi
    model%torsion%ends = model%snap_torsion_ends
    IF (model%torsion%active) model%torsion%torque = model%snap_torsion_torque
    model%tors_drive_set = .FALSE.
    model%tors_use_step = .FALSE.
    IF (model%tw_active) CALL tw_unpack(model, model%snap_tw)
    IF (model%fr_active) model%fr_anchor = model%snap_fr_anchor
    IF (model%has_viv) THEN
      model%viv_phi = model%snap_viv_phi; model%viv_ms = model%snap_viv_ms
      model%viv_phi_eval = model%viv_phi
    END IF
    model%na_steps_done = model%snap_na_steps_done
    model%na_iter_sum = model%snap_na_iter_sum
    model%na_mn_active = model%snap_na_mn_active
    model%tensile_event_count = model%snap_tensile_event_count
    model%tensile_worst_element = model%snap_tensile_worst_element
    model%tensile_worst_force = model%snap_tensile_worst_force
    model%tensile_worst_threshold = model%snap_tensile_worst_threshold
    model%tensile_worst_xi = model%snap_tensile_worst_xi
    model%tensile_worst_time = model%snap_tensile_worst_time
    model%max_step_rotation = model%snap_max_step_rotation
    model%recovery_event_count = model%snap_recovery_event_count
    model%recovery_max_substeps_used = model%snap_recovery_max_substeps_used
    ! The snapshot's cached committed force comes back with its state unless a setter
    ! invalidated the cache between the snapshot and the step that followed it, so the next
    ! step takes the path that step took (the cache differs from a fresh evaluation in the last
    ! bits where a friction anchor slid). Otherwise the next step evaluates it afresh.
    IF (.NOT. model%snap_stepped) model%snap_step_clears = model%fc_clears
    IF (model%snap_fc_valid .AND. model%snap_fc_clears == model%snap_step_clears) THEN
      IF (model%tw_active) model%tw_fcR = model%snap_tw_fcR
      model%fc_R = model%snap_fc_R
      model%fc_q = model%snap_fc_q
      model%fc_v = model%snap_fc_v
      model%fc_t = model%snap_fc_t
      model%fc_d0 = model%snap_fc_d0
      model%fc_valid = .TRUE.
    ELSE
      model%fc_valid = .FALSE.
      model%fc_clears = model%fc_clears + 1
    END IF
    model%tr_valid = .FALSE.
  END SUBROUTINE CD_HermiteCable_Dyn_Restore

  SUBROUTINE CD_HermiteCable_Dyn_End(model)
    !! Release the model's persistent workspaces.
    TYPE(CD_HermiteCableDynType), INTENT(INOUT) :: model
    IF (ALLOCATED(model%att_node)) DEALLOCATE (model%att_node, model%att_w, model%att_b, model%att_fk, &
                                               model%att_cda, model%att_cdax)
    IF (ALLOCATED(model%att_mass)) DEALLOCATE (model%att_mass, model%att_madd)
    model%has_attach = .FALSE.
    IF (ALLOCATED(model%l0_dot)) DEALLOCATE (model%l0_dot, model%l0_c, model%l0_dot_c, model%ws_recovery_l0_c, &
                                             model%ws_recovery_l0_dot_c)
    model%has_ctrl = .FALSE.
    IF (ALLOCATED(model%seabed_diameter_elem)) DEALLOCATE (model%seabed_diameter_elem)
    model%has_seabed_recompute = .FALSE.
    model%seabed_kbot = CD_ZERO
    model%seabed_cn_over_kn = CD_ZERO
    IF (ALLOCATED(model%snap_l0)) DEALLOCATE (model%snap_l0, model%snap_l0_dot, model%snap_l0_c, model%snap_l0_dot_c)
    model%snap_has_ctrl = .FALSE.
    IF (ALLOCATED(model%l0)) DEALLOCATE (model%l0)
    IF (ALLOCATED(model%EA)) DEALLOCATE (model%EA)
    IF (ALLOCATED(model%EI)) DEALLOCATE (model%EI)
    IF (ALLOCATED(model%EI_line)) DEALLOCATE (model%EI_line)
    IF (ALLOCATED(model%EI_node)) DEALLOCATE (model%EI_node)
    IF (ALLOCATED(model%rho_a)) DEALLOCATE (model%rho_a)
    IF (ALLOCATED(model%w)) DEALLOCATE (model%w)
    IF (ALLOCATED(model%BA)) DEALLOCATE (model%BA)
    model%has_axial_damping = .FALSE.
    IF (ALLOCATED(model%trib)) DEALLOCATE (model%trib)
    IF (ALLOCATED(model%contact_kn)) DEALLOCATE (model%contact_kn)
    IF (ALLOCATED(model%contact_cn)) DEALLOCATE (model%contact_cn)
    IF (ALLOCATED(model%fr_anchor)) DEALLOCATE (model%fr_anchor, model%fr_k, model%ws_recovery_fr, &
                                                model%snap_fr_anchor)
    model%fr_active = .FALSE.
    CALL clear_viv(model)
    CALL CD_End_Bathymetry(model%contact_bathymetry)
    model%has_contact = .FALSE.; model%has_contact_bathymetry = .FALSE.
    IF (ALLOCATED(model%Mgb)) DEALLOCATE (model%Mgb)
    IF (ALLOCATED(model%ws_qn)) THEN
      DEALLOCATE (model%ws_qn, model%ws_vn, model%ws_an, model%ws_qk, model%ws_ak, &
                  model%ws_qa, model%ws_aa, model%ws_va, model%ws_vk, model%ws_R, &
                  model%ws_G, model%ws_Gt, model%ws_inert, model%ws_qtrial, model%ws_dq, &
                  model%ws_recovery_q0, model%ws_recovery_v0, model%ws_recovery_a0)
      DEALLOCATE (model%ws_Rk, model%ws_Rt, model%fc_R, model%fc_q, model%fc_v)
      DEALLOCATE (model%ws_Kb, model%ws_Kvb, &
                  model%ws_Keffb, model%ws_Msumb, model%ws_Mamb)
      DEALLOCATE (model%ws_ipiv)
      DEALLOCATE (model%ws_elem_f, model%ws_elem_K, model%ws_elem_Kdrag, model%ws_elem_Kv, &
                  model%ws_elem_Kwave, model%ws_elem_Kheld, &
                  model%ws_elem_es, model%ws_elem_em, model%ws_stash_q, model%ws_stash_v)
      model%ws_stash_ok = .FALSE.
    END IF
    IF (ALLOCATED(model%rc_q)) DEALLOCATE (model%rc_q, model%rc_v, model%rc_a, model%rc_g, model%rc_have, model%rc_qnb)
    model%rc_key_ok = .FALSE.
    IF (ALLOCATED(model%freemask)) DEALLOCATE (model%freemask)
    IF (ALLOCATED(model%solve_mask)) DEALLOCATE (model%solve_mask)
    IF (ALLOCATED(model%fmap)) DEALLOCATE (model%fmap)
    IF (ALLOCATED(model%q)) DEALLOCATE (model%q)
    IF (ALLOCATED(model%v)) DEALLOCATE (model%v)
    IF (ALLOCATED(model%a)) DEALLOCATE (model%a)
    IF (ALLOCATED(model%diam)) DEALLOCATE (model%diam)
    IF (ALLOCATED(model%cdn)) DEALLOCATE (model%cdn)
    IF (ALLOCATED(model%cdt)) DEALLOCATE (model%cdt)
    model%has_drag = .FALSE.
    IF (ALLOCATED(model%am_diam)) DEALLOCATE (model%am_diam)
    IF (ALLOCATED(model%am_can)) DEALLOCATE (model%am_can)
    IF (ALLOCATED(model%am_cat)) DEALLOCATE (model%am_cat)
    model%has_am = .FALSE.
    model%has_wave = .FALSE.
    model%wv_h = CD_ZERO; model%wv_om = CD_ZERO; model%wv_k = CD_ZERO
    model%wv_depth = CD_ZERO; model%wv_dir = CD_ZERO
    model%wv_ncomp = 0
    IF (ALLOCATED(model%wv_ampc)) DEALLOCATE (model%wv_ampc)
    IF (ALLOCATED(model%wv_omc)) DEALLOCATE (model%wv_omc)
    IF (ALLOCATED(model%wv_kc)) DEALLOCATE (model%wv_kc)
    IF (ALLOCATED(model%wv_e2kd)) DEALLOCATE (model%wv_e2kd)
    IF (ALLOCATED(model%wv_phc)) DEALLOCATE (model%wv_phc)
    IF (ALLOCATED(model%hf_u)) DEALLOCATE (model%hf_u, model%hf_ud, model%hf_wl)
    IF (ALLOCATED(model%ws_hf_a_old)) &
      DEALLOCATE (model%ws_hf_a_old, model%ws_hf_u_old, model%ws_hf_ud_old, model%ws_hf_wl_old)
    model%has_held_field = .FALSE.
    model%has_endconn = .FALSE.
    model%endconn_k = CD_ZERO
    model%endconn_d0 = CD_ZERO
    IF (ALLOCATED(model%snap_q)) DEALLOCATE (model%snap_q, model%snap_v, model%snap_a)
    IF (ALLOCATED(model%snap_fc_R)) DEALLOCATE (model%snap_fc_R, model%snap_fc_q, model%snap_fc_v)
    model%snap_fc_valid = .FALSE.
    model%fc_valid = .FALSE.
    model%fc_clears = model%fc_clears + 1
    model%tr_valid = .FALSE.
    model%snap_t = CD_ZERO
    model%snap_endconn_d0 = CD_ZERO
    model%torsion = CD_HermiteTorsionType()
    CALL CD_HermiteTorsion_Work_End(model%tors_work)
    IF (ALLOCATED(model%tors_g)) DEALLOCATE (model%tors_g, model%tors_gq, model%tors_gk, model%tors_zk)
    IF (ALLOCATED(model%tors_c_q)) DEALLOCATE (model%tors_c_q)
    model%tors_c_valid = .FALSE.
    model%tors_c_ends = CD_ZERO
    model%tors_c_prev = CD_ZERO
    model%tors_c_theta = CD_ZERO
    model%tors_c_eg = CD_ZERO
    model%tors_c_gend = CD_ZERO
    model%tors_den = CD_ZERO
    model%tors_use_step = .FALSE.
    model%tors_drive_set = .FALSE.
    model%tors_step_ends = CD_ZERO
    model%tors_step_phi = CD_ZERO
    model%tors_drive_ends = CD_ZERO
    model%tors_drive_phi = CD_ZERO
    model%snap_torsion_theta = CD_ZERO
    model%snap_torsion_phi = CD_ZERO
    model%snap_torsion_ends = CD_ZERO
    model%snap_torsion_torque = CD_ZERO
    CALL tw_release(model)
    model%tw_rigid = .FALSE.
    model%tw_psi = CD_ZERO
    model%tw_lg = CD_ZERO
    model%tw_lk = CD_ZERO
    model%tw_tsum = CD_ZERO
    model%tw_spsi = CD_ZERO
    model%tw_som = CD_ZERO
    model%tw_om = CD_ZERO
    model%tw_oal = CD_ZERO
    model%tw_tscale = CD_ONE
    model%snap_valid = .FALSE.
    model%require_tensile = .FALSE.
    model%tensile_mode = CD_HCDYN_TENSILE_OFF
    model%tensile_strain_tolerance = CD_HCDYN_AXIAL_STRAIN_TOL
    model%tensile_event_count = 0; model%tensile_worst_element = 0
    model%tensile_worst_force = CD_ZERO; model%tensile_worst_threshold = CD_ZERO
    model%tensile_worst_xi = CD_ZERO; model%tensile_worst_time = CD_ZERO
    model%recovery_event_count = 0; model%recovery_max_substeps_used = 0
    model%t = CD_ZERO
    model%ne = 0; model%nn = 0; model%ndof = 0
    model%initialized = .FALSE.
  END SUBROUTINE CD_HermiteCable_Dyn_End

  ! ------------------------------------------------------------------------------------------

  SUBROUTINE assemble_residual(model, q_cfg, v_cfg, t_eval, want_residual, want_tangent, ErrStat, ErrMsg, &
                               endconn_direction_eval, node_only, R_out, stash_tangent, use_stash)
    !! Residual R = f_int(q) - f_ext(q, v, t), banded position tangent Kb = dR/dq, and banded
    !! velocity tangent Kvb = dR/dv at configuration q_cfg with nodal velocity v_cfg at time
    !! t_eval (LAPACK band layout, see the module note), written into the MODEL'S OWN
    !! buffers -- ws_R when want_residual, ws_Kb/ws_Kvb when want_tangent. The two flags
    !! split the Newton's work honestly: residual-only for every evaluation (predictor and
    !! line-search trials, which never solve with a tangent) and tangent-only once per
    !! solve iteration at the accepted iterate -- the tangents land directly in the
    !! committed band buffers, so no trial tangent set and no per-iteration band copies
    !! exist. Buffer access goes through pointers into the single model dummy so no model
    !! subobject is argument-associated alongside the model itself (the Fortran
    !! aliasing/intent rule). f_ext = consistent
    !! self-weight (configuration-independent) + the buoyancy of any part above the drag
    !! configuration's free surface + penalty seabed reaction + optional Morison drag (the
    !! only velocity-dependent term, hence Kvb) + optional wave loads (drag against the wave-plus-
    !! current fluid velocity, and the Froude-Krylov + fluid-inertia load from the wave acceleration)
    !! evaluated at t_eval. The caller folds Kvb into the effective tangent through the Newmark
    !! velocity-displacement coupling dv/dq. q_cfg/v_cfg may be model workspace vectors;
    !! they are only read, never defined, so that association is legal.
    TYPE(CD_HermiteCableDynType), INTENT(INOUT), TARGET :: model
    REAL(wp), INTENT(IN) :: q_cfg(:), v_cfg(:), t_eval
    LOGICAL, INTENT(IN) :: want_residual, want_tangent
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    REAL(wp), INTENT(IN), OPTIONAL :: endconn_direction_eval(3, 2)
    ! node_only: assemble only the residual rows of that node, into R_out (sized like the
    ! residual) instead of the model's residual: the elements that reach the node and its own
    ! nodal terms, each added in the order of the full assembly, so those rows are bit-identical
    ! and the model's scratch is untouched (node_reaction). Residual only, without torsion
    ! (which couples every element). The other rows of R_out are partial.
    INTEGER, INTENT(IN), OPTIONAL :: node_only
    REAL(wp), INTENT(INOUT), TARGET, OPTIONAL :: R_out(:)
    ! stash_tangent: a full residual-only assembly that evaluates each element kernel once for
    ! its load AND its tangent (evaluate_tangent_element with forces, in parallel like the
    ! tangent assembly), adds the loads to R in the order of the residual-only assembly and keeps
    ! the element tangent blocks (ws_stash_ok). R is bit-for-bit that of the residual-only
    ! assembly. If any element evaluation fails (a tangent can overflow where the load stays
    ! finite), this assembly evaluates the loads again residual-only, so its result and message
    ! are those of the residual-only assembly, and keeps nothing.
    ! use_stash: a tangent-only assembly at exactly the configuration, velocity and time of the
    ! last assembly, when that one kept its element tangents, scatters those blocks instead of
    ! evaluating the kernels again. Otherwise it evaluates them as usual.
    LOGICAL, INTENT(IN), OPTIONAL :: stash_tangent, use_stash
    REAL(wp), POINTER :: R(:), Kb(:, :), Kvb(:, :)
    INTEGER :: ne, e, a, gi, es, omp_threads
    INTEGER :: e_lo, e_hi, n_lo, n_hi  ! the elements and nodes assembled (all unless node_only)
    INTEGER(INT64) :: asm_t  ! clock at the last section mark (asm_mark; profiled runs only)
    LOGICAL :: tangent_only
    LOGICAL :: stash   ! this residual assembly keeps its element tangents (stash_tangent)
    LOGICAL :: kept    ! the element loads and tangents of this assembly's kernels are in ws_elem_*
    LOGICAL :: reuse   ! this tangent assembly scatters the element tangents the last one kept
    REAL(wp) :: qe(12), ve(12), Ee, fe(12), Ke(12, 12), pen
    REAL(wp) :: fdrag(12), djq(12, 12), djv(12, 12), ffk(12), fjq(12, 12)
    REAL(wp) :: fdamp(12), kdq(12, 12), kdv(12, 12)
    REAL(wp) :: hf_mid(3)
    REAL(wp), PARAMETER :: PI_L = 3.14159265358979323846_wp
    REAL(wp) :: fdry(4), kdry(4, 4), dry_wl, dry_b, dry_r
    INTEGER :: zdof(4), b
    LOGICAL :: dry
    REAL(wp) :: endconn_d0_eval(3, 2), support(3), dsupport(3), nin(3), mend
    INTEGER :: inode, jr, jc
    CHARACTER(1024) :: em2
    ! em_e takes the messages of the per-element kernels (element, axial damping, drag, wave load),
    ! fixed texts of at most 184 characters with the nested CableDyn_Hydro ones. Each kernel resets
    ! its message at every call, so this buffer stays as short as those texts allow.
    CHARACTER(200) :: em_e

    ErrStat = CD_HCDYN_OK; ErrMsg = ''
    ne = model%ne
    omp_threads = 1
!$  omp_threads = MIN(4, omp_get_max_threads())
!$  IF (omp_in_parallel()) omp_threads = 1
    tangent_only = want_tangent .AND. .NOT. want_residual
    ! The kept element tangents belong to the last assembly alone: decide whether this tangent
    ! assembly is at its exact state, then drop them (a keeping assembly sets them on success).
    reuse = .FALSE.
    IF (PRESENT(use_stash)) THEN
      IF (use_stash .AND. tangent_only .AND. model%ws_stash_ok) THEN
        reuse = bits_equal(t_eval, model%ws_stash_t) .AND. SIZE(q_cfg) == SIZE(model%ws_stash_q) .AND. &
                SIZE(v_cfg) == SIZE(model%ws_stash_v)
        IF (reuse) THEN
          DO gi = 1, SIZE(q_cfg)
            IF (.NOT. (bits_equal(q_cfg(gi), model%ws_stash_q(gi)) .AND. &
                       bits_equal(v_cfg(gi), model%ws_stash_v(gi)))) THEN
              reuse = .FALSE.
              EXIT
            END IF
          END DO
        END IF
      END IF
    END IF
    model%ws_stash_ok = .FALSE.
    stash = .FALSE.
    IF (PRESENT(stash_tangent)) stash = stash_tangent .AND. want_residual .AND. .NOT. want_tangent .AND. &
                                        .NOT. PRESENT(node_only) .AND. .NOT. PRESENT(R_out)
    kept = .FALSE.
    R => model%ws_R
    Kb => model%ws_Kb
    Kvb => model%ws_Kvb
    e_lo = 1; e_hi = ne; n_lo = 1; n_hi = model%nn
    IF (PRESENT(node_only)) THEN
      IF (want_tangent .OR. model%torsion%active .OR. .NOT. PRESENT(R_out)) THEN
        ErrStat = CD_HCDYN_BADINPUT
        ErrMsg = 'a single-node assembly is residual-only, without torsion, into a caller residual'
        RETURN
      END IF
      IF (node_only < 1 .OR. node_only > model%nn) THEN
        ErrStat = CD_HCDYN_BADINPUT; ErrMsg = 'single-node assembly: node out of range'; RETURN
      END IF
      e_lo = MAX(1, node_only - 1); e_hi = MIN(ne, node_only)
      n_lo = node_only; n_hi = node_only
    END IF
    IF (PRESENT(R_out)) THEN
      IF (SIZE(R_out) /= SIZE(model%ws_R)) THEN
        ErrStat = CD_HCDYN_BADINPUT; ErrMsg = 'assemble_residual: R_out must be sized like the residual'; RETURN
      END IF
      R => R_out
    END IF
    endconn_d0_eval = model%endconn_d0
    IF (PRESENT(endconn_direction_eval)) endconn_d0_eval = endconn_direction_eval
    asm_t = 0_INT64
    IF (prof_enabled) CALL SYSTEM_CLOCK(asm_t)
    IF (want_residual) R = CD_ZERO
    IF (want_tangent) THEN
      ! the stored band only: the fill-in rows above it are never written (BAND_TOP_D)
      Kb(BAND_TOP_D:, :) = CD_ZERO; Kvb(BAND_TOP_D:, :) = CD_ZERO
    END IF
    CALL asm_mark(HC_ASM_ZERO, asm_t)

    ! Tangent-only element kernels are independent. Evaluate them in parallel into persistent
    ! buffers, then validate and scatter serially in the original element order. Plain residual
    ! and combined-output requests retain the lower-overhead serial path. A four-thread cap avoids
    ! tiny-kernel oversubscription while respecting a smaller host OpenMP thread limit.
    ! A residual assembly that keeps its element tangents (stash) runs the same parallel
    ! kernels with their loads; the loads then enter R serially, phase by phase, in the
    ! element order of the residual-only assembly below. A tangent assembly at the kept
    ! state (reuse) scatters the kept blocks.
    IF (stash) THEN
      !$OMP PARALLEL DEFAULT(SHARED) NUM_THREADS(omp_threads) IF(ne >= 32)
      CALL CD_Fatal_Thread_Init() ! this thread can report its own stack overflow
      !$OMP DO SCHEDULE(STATIC)
      DO e = 1, ne
        CALL evaluate_tangent_element(model, e, q_cfg, v_cfg, t_eval, model%ws_elem_K(:, :, e), &
                                      model%ws_elem_Kdrag(:, :, e), model%ws_elem_Kv(:, :, e), &
                                      model%ws_elem_Kwave(:, :, e), model%ws_elem_Kheld(:, :, e), &
                                      model%ws_elem_es(e), model%ws_elem_em(e), &
                                      forces=model%ws_elem_f(:, :, e))
      END DO
      !$OMP END DO
      !$OMP END PARALLEL
      CALL asm_mark(HC_ASM_TAN_KERNELS, asm_t)
      kept = .TRUE.
      DO e = 1, ne
        IF (model%ws_elem_es(e) /= CD_HCABLE_OK) THEN
          kept = .FALSE.
          EXIT
        END IF
      END DO
    END IF
    IF (tangent_only) THEN
      IF (.NOT. reuse) THEN
        !$OMP PARALLEL DEFAULT(SHARED) PRIVATE(qe) NUM_THREADS(omp_threads) IF(ne >= 32)
        CALL CD_Fatal_Thread_Init() ! this thread can report its own stack overflow
        !$OMP DO SCHEDULE(STATIC)
        DO e = 1, ne
          CALL evaluate_tangent_element(model, e, q_cfg, v_cfg, t_eval, model%ws_elem_K(:, :, e), &
                                        model%ws_elem_Kdrag(:, :, e), model%ws_elem_Kv(:, :, e), &
                                        model%ws_elem_Kwave(:, :, e), model%ws_elem_Kheld(:, :, e), &
                                        model%ws_elem_es(e), model%ws_elem_em(e))
        END DO
        !$OMP END DO
        !$OMP END PARALLEL
        CALL asm_mark(HC_ASM_TAN_KERNELS, asm_t)
      END IF
      DO e = 1, ne
        IF (model%ws_elem_es(e) /= CD_HCABLE_OK) THEN
          ErrStat = CD_HCDYN_NOCONVERGE; ErrMsg = 'element: '//TRIM(model%ws_elem_em(e)); RETURN
        END IF
        CALL scatter12_band(Kb, model%ws_elem_K(:, :, e), e)
      END DO
      CALL asm_mark(HC_ASM_SCATTER, asm_t)
    ELSE
      DO e = e_lo, e_hi
        IF (kept) THEN
          DO a = 1, 12
            gi = elem_gdof(e, a)
            R(gi) = R(gi) + model%ws_elem_f(a, 1, e)
          END DO
          CYCLE
        END IF
        qe(1:3) = q_cfg(6*(e - 1) + 1:6*(e - 1) + 3)
        qe(4:6) = q_cfg(6*(e - 1) + 4:6*(e - 1) + 6)
        qe(7:9) = q_cfg(6*e + 1:6*e + 3)
        qe(10:12) = q_cfg(6*e + 4:6*e + 6)
        IF (want_tangent) THEN
          CALL CD_HermiteCable_Element(qe, model%l0(e), model%EA(e), model%EI(e), Ee, fe, Ke, es, em_e, &
                                       symmetric_half=.TRUE., &
                                       axial_quadrature_order=model%axial_quadrature_order, &
                                       bending_quadrature_order=model%bending_quadrature_order)
        ELSE
          CALL CD_HermiteCable_Element(qe, model%l0(e), model%EA(e), model%EI(e), Ee, fe, ErrStat=es, ErrMsg=em_e, &
                                       axial_quadrature_order=model%axial_quadrature_order, &
                                       bending_quadrature_order=model%bending_quadrature_order)
        END IF
        IF (es /= CD_HCABLE_OK) THEN
          ErrStat = CD_HCDYN_NOCONVERGE; ErrMsg = 'element: '//TRIM(em_e); RETURN
        END IF
        IF (want_residual) THEN
          DO a = 1, 12
            gi = elem_gdof(e, a)
            R(gi) = R(gi) + fe(a)
          END DO
        END IF
        IF (want_tangent) CALL scatter12_band(Kb, Ke, e)
      END DO
      CALL asm_mark(HC_ASM_STRUCT, asm_t)
    END IF

    IF (want_residual) THEN
      ! consistent cubic-Hermite self-weight on z DOFs (R = fint - fext => -fext adds +w)
      DO e = e_lo, e_hi
        R(6*(e - 1) + 3) = R(6*(e - 1) + 3) + model%w(e)*0.5_wp*model%l0(e)
        R(6*(e - 1) + 6) = R(6*(e - 1) + 6) + model%w(e)*model%l0(e)*model%l0(e)/12.0_wp
        R(6*e + 3) = R(6*e + 3) + model%w(e)*0.5_wp*model%l0(e)
        R(6*e + 6) = R(6*e + 6) - model%w(e)*model%l0(e)*model%l0(e)/12.0_wp
      END DO
      ! A held end whose end element lies on the floor: the seabed carries the element's
      ! weight with its consistent end moment (CD_Seabed_End_Support and
      ! CD_Seabed_End_Element_Share), which the nodal contact cannot.
      IF (model%has_contact .OR. model%kn > CD_ZERO) THEN
        IF (held_end_floor_support(model, q_cfg, 1, support, dsupport, inode, nin)) &
          R(4:6) = R(4:6) - (model%w(1)*model%l0(1)*model%l0(1)/12.0_wp)*support
        IF (held_end_floor_support(model, q_cfg, 2, support, dsupport, inode, nin)) &
          R(6*ne + 4:6*ne + 6) = R(6*ne + 4:6*ne + 6) + (model%w(ne)*model%l0(ne)*model%l0(ne)/12.0_wp)*support
      END IF
    END IF
    CALL asm_mark(HC_ASM_WEIGHT, asm_t)
    IF (model%has_attach) THEN
      CALL assemble_attachments(model, q_cfg, v_cfg, want_residual, want_tangent, R, Kb, Kvb, n_lo, n_hi, es, em2)
      IF (es /= CD_HCDYN_OK) THEN
        ErrStat = CD_HCDYN_NOCONVERGE; ErrMsg = TRIM(em2); RETURN
      END IF
    END IF
    CALL asm_mark(HC_ASM_ATTACH, asm_t)

    ! Dry-part buoyancy recovery. w is the submerged weight; the part of an element above the
    ! free surface of the drag configuration regains its displaced-water buoyancy. The surface
    ! is the still waterline, or with a held host field the element's sampled elevation (the
    ! same surface the drag uses). Fully submerged elements return immediately. Without a
    ! drag configuration the added-mass configuration defines the surface and section, so
    ! the buoyancy is restored whenever either hydrodynamic configuration is present.
    IF (model%has_drag .OR. model%has_am) THEN
      DO e = e_lo, e_hi
        IF (model%has_drag) THEN
          dry_wl = model%waterline_z
          dry_b = model%rho_w*model%gravity*0.25_wp*PI_L*model%diam(e)**2
          dry_r = 0.5_wp*model%diam(e)
        ELSE
          dry_wl = model%am_wl
          dry_b = model%am_rho*model%gravity*0.25_wp*PI_L*model%am_diam(e)**2
          dry_r = 0.5_wp*model%am_diam(e)
        END IF
        IF (model%has_held_field) dry_wl = 0.5_wp*(model%hf_wl(e) + model%hf_wl(e + 1))
        zdof = [6*(e - 1) + 3, 6*(e - 1) + 6, 6*e + 3, 6*e + 6]
        CALL CD_HermiteCable_Dry_Buoyancy(q_cfg(zdof), model%l0(e), dry_b, dry_wl, fdry, kdry, dry, &
                                          radius=dry_r)
        IF (.NOT. dry) CYCLE
        IF (want_residual) R(zdof) = R(zdof) + fdry
        IF (want_tangent) THEN
          DO b = 1, 4
            DO a = 1, 4
              Kb(KL_D + KU_D + 1 + zdof(a) - zdof(b), zdof(b)) = &
                Kb(KL_D + KU_D + 1 + zdof(a) - zdof(b), zdof(b)) + kdry(a, b)
            END DO
          END DO
        END IF
      END DO
    END IF

    CALL asm_mark(HC_ASM_BUOY, asm_t)
    ! Standalone production contact uses the same nodal C1 normal/damper/friction
    ! law as the deck compatibility path, including structured-bed slope terms.
    ! Retain the scalar flat penalty for existing direct API callers.
    IF (model%has_contact) THEN
      CALL assemble_contact(model, q_cfg, v_cfg, want_residual, want_tangent, R, n_lo, n_hi, es, em2)
      IF (es /= CD_HCDYN_OK) THEN
        ErrStat = es; ErrMsg = 'contact: '//TRIM(em2); RETURN
      END IF
    ELSE IF (model%kn > CD_ZERO) THEN
      DO a = n_lo, n_hi
        gi = 6*(a - 1) + 3
        pen = model%seabed_z - q_cfg(gi)
        IF (pen > CD_ZERO) THEN
          IF (want_residual) R(gi) = R(gi) - model%kn*pen*model%trib(a)
          IF (want_tangent) Kb(KL_D + KU_D + 1, gi) = Kb(KL_D + KU_D + 1, gi) + model%kn*model%trib(a)
        END IF
      END DO
    END IF
    ! The floor-carried end moment of a held end follows the contact of the end element's
    ! inner node (inode, floor normal nin): its tangent couples the end tangent to that node.
    IF (want_tangent .AND. (model%has_contact .OR. model%kn > CD_ZERO)) THEN
      IF (held_end_floor_support(model, q_cfg, 1, support, dsupport, inode, nin)) THEN
        mend = model%w(1)*model%l0(1)*model%l0(1)/12.0_wp
        DO jc = 1, 3
          DO jr = 1, 3
            CALL scatter_contact_band(Kb, 3 + jr, 6*inode - 6 + jc, mend*dsupport(jr)*nin(jc))
          END DO
        END DO
      END IF
      IF (held_end_floor_support(model, q_cfg, 2, support, dsupport, inode, nin)) THEN
        mend = model%w(ne)*model%l0(ne)*model%l0(ne)/12.0_wp
        DO jc = 1, 3
          DO jr = 1, 3
            CALL scatter_contact_band(Kb, 6*ne + 3 + jr, 6*inode - 6 + jc, -mend*dsupport(jr)*nin(jc))
          END DO
        END DO
      END IF
    END IF

    CALL asm_mark(HC_ASM_CONTACT, asm_t)
    ! Scatter the element-private hydrodynamic tangents in the same phase and element
    ! order as the serial formulation, retaining its floating-point accumulation order.
    IF (tangent_only .AND. (model%has_drag .OR. model%has_axial_damping)) THEN
      DO e = 1, ne
        CALL scatter12_band(Kb, model%ws_elem_Kdrag(:, :, e), e)
        CALL scatter12_band(Kvb, model%ws_elem_Kv(:, :, e), e)
      END DO
    END IF
    IF (tangent_only .AND. model%has_wave .AND. model%has_am) THEN
      DO e = 1, ne
        CALL scatter12_band(Kb, model%ws_elem_Kwave(:, :, e), e)
      END DO
    END IF
    IF (tangent_only .AND. model%has_held_field .AND. model%has_am) THEN
      DO e = 1, ne
        CALL scatter12_band(Kb, model%ws_elem_Kheld(:, :, e), e)
      END DO
    END IF

    CALL asm_mark(HC_ASM_SCATTER, asm_t)
    ! Axial Kelvin-Voigt damping is an internal constitutive force. It uses the same
    ! reference-arc Hermite interpolation and axial quadrature as the elastic resultant.
    IF (model%has_axial_damping .AND. .NOT. tangent_only) THEN
      DO e = e_lo, e_hi
        IF (kept) THEN
          DO a = 1, 12
            gi = elem_gdof(e, a)
            R(gi) = R(gi) + model%ws_elem_f(a, 2, e)
          END DO
          CYCLE
        END IF
        qe(1:3) = q_cfg(6*(e - 1) + 1:6*(e - 1) + 3); qe(4:6) = q_cfg(6*(e - 1) + 4:6*(e - 1) + 6)
        qe(7:9) = q_cfg(6*e + 1:6*e + 3); qe(10:12) = q_cfg(6*e + 4:6*e + 6)
        ve(1:3) = v_cfg(6*(e - 1) + 1:6*(e - 1) + 3); ve(4:6) = v_cfg(6*(e - 1) + 4:6*(e - 1) + 6)
        ve(7:9) = v_cfg(6*e + 1:6*e + 3); ve(10:12) = v_cfg(6*e + 4:6*e + 6)
        IF (want_tangent .AND. model%has_ctrl) THEN
          CALL CD_HermiteCable_Axial_Damping_Element(qe, ve, model%l0(e), model%BA(e), &
                                                     fdamp, kdq, kdv, es, em_e, &
                                                     model%axial_quadrature_order, model%l0_dot(e))
        ELSE IF (want_tangent) THEN
          CALL CD_HermiteCable_Axial_Damping_Element(qe, ve, model%l0(e), model%BA(e), &
                                                     fdamp, kdq, kdv, es, em_e, &
                                                     model%axial_quadrature_order)
        ELSE IF (model%has_ctrl) THEN
          CALL CD_HermiteCable_Axial_Damping_Element(qe, ve, model%l0(e), model%BA(e), &
                                                     fdamp, ErrStat=es, ErrMsg=em_e, &
                                                     quadrature_order=model%axial_quadrature_order, &
                                                     l0_dot=model%l0_dot(e))
        ELSE
          CALL CD_HermiteCable_Axial_Damping_Element(qe, ve, model%l0(e), model%BA(e), &
                                                     fdamp, ErrStat=es, ErrMsg=em_e, &
                                                     quadrature_order=model%axial_quadrature_order)
        END IF
        IF (es /= CD_HCDYN_OK) THEN
          ErrStat = CD_HCDYN_NOCONVERGE; ErrMsg = TRIM(em_e); RETURN
        END IF
        IF (want_residual) THEN
          DO a = 1, 12
            gi = elem_gdof(e, a)
            R(gi) = R(gi) + fdamp(a)
          END DO
        END IF
        IF (want_tangent) THEN
          CALL scatter12_band(Kb, kdq, e)
          CALL scatter12_band(Kvb, kdv, e)
        END IF
      END DO
    END IF

    CALL asm_mark(HC_ASM_DAMP, asm_t)
    ! Consistent Morison quadratic drag on the submerged cable, distributed over the full cubic-
    ! Hermite shape functions (so the material-tangent DOFs, which move the element interior, also
    ! carry drag). The element returns the 12-DOF generalized drag LOAD fdrag (f_ext) and its force
    ! Jacobians djq = d(fdrag)/dq, djv = d(fdrag)/dv. R = f_int - f_ext, so R -= fdrag, K -= djq,
    ! Kv -= djv over all 12 element DOFs.
    IF (model%has_drag .AND. .NOT. tangent_only) THEN
      DO e = e_lo, e_hi
        IF (kept) THEN
          DO a = 1, 12
            gi = elem_gdof(e, a)
            R(gi) = R(gi) - model%ws_elem_f(a, 3, e)
          END DO
          CYCLE
        END IF
        qe(1:3) = q_cfg(6*(e - 1) + 1:6*(e - 1) + 3); qe(4:6) = q_cfg(6*(e - 1) + 4:6*(e - 1) + 6)
        qe(7:9) = q_cfg(6*e + 1:6*e + 3); qe(10:12) = q_cfg(6*e + 4:6*e + 6)
        ve(1:3) = v_cfg(6*(e - 1) + 1:6*(e - 1) + 3); ve(4:6) = v_cfg(6*(e - 1) + 4:6*(e - 1) + 6)
        ve(7:9) = v_cfg(6*e + 1:6*e + 3); ve(10:12) = v_cfg(6*e + 4:6*e + 6)
        IF (want_tangent) THEN
          IF (model%has_wave .AND. model%wv_ncomp > 0) THEN
            CALL CD_HermiteCable_Drag_Element(qe, ve, model%l0(e), model%current, model%waterline_z, &
                                              model%rho_w, model%diam(e), model%cdn(e), model%cdt(e), &
                                              fdrag, djq, djv, es, em_e, &
                                              wv_depth=model%wv_depth, wv_dir=model%wv_dir, wv_t=t_eval, &
                                              wvc_amp=model%wv_ampc, wvc_om=model%wv_omc, &
                                              wvc_k=model%wv_kc, wvc_ph=model%wv_phc, &
                                              wvc_e2kd=model%wv_e2kd)
          ELSE IF (model%has_wave) THEN
            CALL CD_HermiteCable_Drag_Element(qe, ve, model%l0(e), model%current, model%waterline_z, &
                                              model%rho_w, model%diam(e), model%cdn(e), model%cdt(e), &
                                              fdrag, djq, djv, es, em_e, &
                                              wv_h=model%wv_h, wv_om=model%wv_om, wv_k=model%wv_k, &
                                              wv_depth=model%wv_depth, wv_dir=model%wv_dir, wv_t=t_eval)
          ELSE IF (model%has_held_field) THEN
            ! HELD host field: the element's ambient velocity = the drag config's constant
            ! current + the two end nodes' held-velocity average; the element waterline =
            ! the two nodes' sampled-elevation average (the host's spatial granularity).
            CALL CD_HermiteCable_Drag_Element(qe, ve, model%l0(e), &
                                              model%current + 0.5_wp*(model%hf_u(:, e) + model%hf_u(:, e + 1)), &
                                              0.5_wp*(model%hf_wl(e) + model%hf_wl(e + 1)), &
                                              model%rho_w, model%diam(e), model%cdn(e), model%cdt(e), &
                                              fdrag, djq, djv, es, em_e)
          ELSE
            CALL CD_HermiteCable_Drag_Element(qe, ve, model%l0(e), model%current, model%waterline_z, &
                                              model%rho_w, model%diam(e), model%cdn(e), model%cdt(e), &
                                              fdrag, djq, djv, es, em_e)
          END IF
        ELSE
          IF (model%has_wave .AND. model%wv_ncomp > 0) THEN
            CALL CD_HermiteCable_Drag_Element(qe, ve, model%l0(e), model%current, model%waterline_z, &
                                              model%rho_w, model%diam(e), model%cdn(e), model%cdt(e), &
                                              fdrag, ErrStat=es, ErrMsg=em_e, &
                                              wv_depth=model%wv_depth, wv_dir=model%wv_dir, wv_t=t_eval, &
                                              wvc_amp=model%wv_ampc, wvc_om=model%wv_omc, &
                                              wvc_k=model%wv_kc, wvc_ph=model%wv_phc, &
                                              wvc_e2kd=model%wv_e2kd)
          ELSE IF (model%has_wave) THEN
            CALL CD_HermiteCable_Drag_Element(qe, ve, model%l0(e), model%current, model%waterline_z, &
                                              model%rho_w, model%diam(e), model%cdn(e), model%cdt(e), &
                                              fdrag, ErrStat=es, ErrMsg=em_e, &
                                              wv_h=model%wv_h, wv_om=model%wv_om, wv_k=model%wv_k, &
                                              wv_depth=model%wv_depth, wv_dir=model%wv_dir, wv_t=t_eval)
          ELSE IF (model%has_held_field) THEN
            CALL CD_HermiteCable_Drag_Element(qe, ve, model%l0(e), &
                                              model%current + 0.5_wp*(model%hf_u(:, e) + model%hf_u(:, e + 1)), &
                                              0.5_wp*(model%hf_wl(e) + model%hf_wl(e + 1)), &
                                              model%rho_w, model%diam(e), model%cdn(e), model%cdt(e), &
                                              fdrag, ErrStat=es, ErrMsg=em_e)
          ELSE
            CALL CD_HermiteCable_Drag_Element(qe, ve, model%l0(e), model%current, model%waterline_z, &
                                              model%rho_w, model%diam(e), model%cdn(e), model%cdt(e), &
                                              fdrag, ErrStat=es, ErrMsg=em_e)
          END IF
        END IF
        IF (es /= CD_HCDYN_OK) THEN
          ErrStat = es; ErrMsg = TRIM(em_e); RETURN
        END IF
        IF (want_residual) THEN
          DO a = 1, 12
            gi = elem_gdof(e, a)
            R(gi) = R(gi) - fdrag(a)
          END DO
        END IF
        IF (want_tangent) THEN
          CALL scatter12_band(Kb, -djq, e)
          CALL scatter12_band(Kvb, -djv, e)
        END IF
      END DO
    END IF
    ! Cross-flow VIV lift (an external load like the drag, at the step's phase viv_phi_eval).
    IF (model%has_viv .AND. .NOT. tangent_only) THEN
      DO e = e_lo, e_hi
        IF (kept) THEN
          DO a = 1, 12
            gi = elem_gdof(e, a)
            R(gi) = R(gi) - model%ws_elem_f(a, 4, e)
          END DO
          CYCLE
        END IF
        IF (want_tangent) THEN
          CALL viv_element_lift(model, q_cfg, v_cfg, e, fdrag, es, em_e, djq, djv)
        ELSE
          CALL viv_element_lift(model, q_cfg, v_cfg, e, fdrag, es, em_e)
        END IF
        IF (es /= CD_HCDYN_OK) THEN
          ErrStat = es; ErrMsg = TRIM(em_e); RETURN
        END IF
        IF (want_residual) THEN
          DO a = 1, 12
            gi = elem_gdof(e, a)
            R(gi) = R(gi) - fdrag(a)
          END DO
        END IF
        IF (want_tangent) THEN
          CALL scatter12_band(Kb, -djq, e)
          CALL scatter12_band(Kvb, -djv, e)
        END IF
      END DO
    END IF

    CALL asm_mark(HC_ASM_DRAG, asm_t)
    ! ---- rotational line-end connections ----
    ! A node-local generalized load on the end tangents: the 3x3 tangent block sits on the
    ! band diagonal (|gi - gj| <= 2 against KU_D = 11), so it cannot widen the band. The
    ! spring is a potential, so it enters the residual with the same sign as the internal
    ! force, and f . d == 0 keeps it off the stretch component by construction.
    IF (model%has_endconn) THEN
      IF (n_lo == 1) THEN
        CALL add_endconn_band(R, Kb, q_cfg, 1, model%endconn_k(1), endconn_d0_eval(:, 1), &
                              want_residual, want_tangent, es, em2)
        IF (es /= CD_ENDCONN_OK) THEN
          ErrStat = CD_HCDYN_NOCONVERGE
          ErrMsg = 'end connection at node 1: '//TRIM(em2)
          RETURN
        END IF
      END IF
      IF (n_hi == ne + 1) THEN
        CALL add_endconn_band(R, Kb, q_cfg, ne + 1, model%endconn_k(2), endconn_d0_eval(:, 2), &
                              want_residual, want_tangent, es, em2)
        IF (es /= CD_ENDCONN_OK) THEN
          ErrStat = CD_HCDYN_NOCONVERGE
          ErrMsg = 'end connection at final node: '//TRIM(em2)
          RETURN
        END IF
      END IF
    END IF

    CALL asm_mark(HC_ASM_ENDCONN, asm_t)
    ! Froude-Krylov + fluid-inertia wave load (from the wave ACCELERATION), with the added-mass
    ! configuration's coefficients. An external load: R -= ffk, K -= fjq (geometric tangent chain;
    ! the wave-field spatial gradient is neglected in K -- see the element note).
    IF (model%has_wave .AND. model%has_am .AND. .NOT. tangent_only) THEN
      DO e = e_lo, e_hi
        IF (kept) THEN
          DO a = 1, 12
            gi = elem_gdof(e, a)
            R(gi) = R(gi) - model%ws_elem_f(a, 5, e)
          END DO
          CYCLE
        END IF
        qe(1:3) = q_cfg(6*(e - 1) + 1:6*(e - 1) + 3); qe(4:6) = q_cfg(6*(e - 1) + 4:6*(e - 1) + 6)
        qe(7:9) = q_cfg(6*e + 1:6*e + 3); qe(10:12) = q_cfg(6*e + 4:6*e + 6)
        IF (model%wv_ncomp > 0) THEN
          IF (want_tangent) THEN
            CALL CD_HermiteCable_FK_Element(qe, model%l0(e), model%am_wl, model%am_rho, model%am_diam(e), &
                                            model%am_can(e), model%am_cat(e), &
                                            wv_depth=model%wv_depth, wv_dir=model%wv_dir, wv_t=t_eval, &
                                            ffk=ffk, fjq=fjq, ErrStat=es, ErrMsg=em_e, &
                                            wvc_amp=model%wv_ampc, wvc_om=model%wv_omc, &
                                            wvc_k=model%wv_kc, wvc_ph=model%wv_phc, &
                                            wvc_e2kd=model%wv_e2kd)
          ELSE
            CALL CD_HermiteCable_FK_Element(qe, model%l0(e), model%am_wl, model%am_rho, model%am_diam(e), &
                                            model%am_can(e), model%am_cat(e), &
                                            wv_depth=model%wv_depth, wv_dir=model%wv_dir, wv_t=t_eval, &
                                            ffk=ffk, ErrStat=es, ErrMsg=em_e, &
                                            wvc_amp=model%wv_ampc, wvc_om=model%wv_omc, &
                                            wvc_k=model%wv_kc, wvc_ph=model%wv_phc, &
                                            wvc_e2kd=model%wv_e2kd)
          END IF
        ELSE
          IF (want_tangent) THEN
            CALL CD_HermiteCable_FK_Element(qe, model%l0(e), model%am_wl, model%am_rho, model%am_diam(e), &
                                            model%am_can(e), model%am_cat(e), &
                                            wv_h=model%wv_h, wv_om=model%wv_om, wv_k=model%wv_k, &
                                            wv_depth=model%wv_depth, wv_dir=model%wv_dir, wv_t=t_eval, &
                                            ffk=ffk, fjq=fjq, ErrStat=es, ErrMsg=em_e)
          ELSE
            CALL CD_HermiteCable_FK_Element(qe, model%l0(e), model%am_wl, model%am_rho, model%am_diam(e), &
                                            model%am_can(e), model%am_cat(e), &
                                            wv_h=model%wv_h, wv_om=model%wv_om, wv_k=model%wv_k, &
                                            wv_depth=model%wv_depth, wv_dir=model%wv_dir, wv_t=t_eval, &
                                            ffk=ffk, ErrStat=es, ErrMsg=em_e)
          END IF
        END IF
        IF (es /= CD_HCDYN_OK) THEN
          ErrStat = es; ErrMsg = TRIM(em_e); RETURN
        END IF
        IF (want_residual) THEN
          DO a = 1, 12
            gi = elem_gdof(e, a)
            R(gi) = R(gi) - ffk(a)
          END DO
        END IF
        IF (want_tangent) CALL scatter12_band(Kb, -fjq, e)
      END DO
    END IF

    CALL asm_mark(HC_ASM_WAVE, asm_t)
    ! HELD-FIELD Froude-Krylov + fluid-inertia load: the host-sampled fluid acceleration
    ! (per-element two-node average, frozen over the step) with the added-mass
    ! configuration's coefficients -- the held-mode twin of the wave FK block above.
    IF (model%has_held_field .AND. model%has_am .AND. .NOT. tangent_only) THEN
      DO e = e_lo, e_hi
        IF (kept) THEN
          DO a = 1, 12
            gi = elem_gdof(e, a)
            R(gi) = R(gi) - model%ws_elem_f(a, 6, e)
          END DO
          CYCLE
        END IF
        qe(1:3) = q_cfg(6*(e - 1) + 1:6*(e - 1) + 3); qe(4:6) = q_cfg(6*(e - 1) + 4:6*(e - 1) + 6)
        qe(7:9) = q_cfg(6*e + 1:6*e + 3); qe(10:12) = q_cfg(6*e + 4:6*e + 6)
        IF (want_tangent) THEN
          hf_mid(1) = 0.5_wp*(model%hf_ud(1, e) + model%hf_ud(1, e + 1))
          hf_mid(2) = 0.5_wp*(model%hf_ud(2, e) + model%hf_ud(2, e + 1))
          hf_mid(3) = 0.5_wp*(model%hf_ud(3, e) + model%hf_ud(3, e + 1))
          CALL CD_HermiteCable_FK_Element(qe, model%l0(e), &
                                          0.5_wp*(model%hf_wl(e) + model%hf_wl(e + 1)), &
                                          model%am_rho, model%am_diam(e), &
                                          model%am_can(e), model%am_cat(e), &
                                          wv_depth=CD_ZERO, wv_dir=CD_ZERO, wv_t=CD_ZERO, &
                                          ffk=ffk, fjq=fjq, ErrStat=es, ErrMsg=em_e, &
                                          hf_a=hf_mid)
        ELSE
          hf_mid(1) = 0.5_wp*(model%hf_ud(1, e) + model%hf_ud(1, e + 1))
          hf_mid(2) = 0.5_wp*(model%hf_ud(2, e) + model%hf_ud(2, e + 1))
          hf_mid(3) = 0.5_wp*(model%hf_ud(3, e) + model%hf_ud(3, e + 1))
          CALL CD_HermiteCable_FK_Element(qe, model%l0(e), &
                                          0.5_wp*(model%hf_wl(e) + model%hf_wl(e + 1)), &
                                          model%am_rho, model%am_diam(e), &
                                          model%am_can(e), model%am_cat(e), &
                                          wv_depth=CD_ZERO, wv_dir=CD_ZERO, wv_t=CD_ZERO, &
                                          ffk=ffk, ErrStat=es, ErrMsg=em_e, &
                                          hf_a=hf_mid)
        END IF
        IF (es /= CD_HCDYN_OK) THEN
          ErrStat = es; ErrMsg = TRIM(em_e); RETURN
        END IF
        IF (want_residual) THEN
          DO a = 1, 12
            gi = elem_gdof(e, a)
            R(gi) = R(gi) - ffk(a)
          END DO
        END IF
        IF (want_tangent) CALL scatter12_band(Kb, -fjq, e)
      END DO
    END IF

    CALL asm_mark(HC_ASM_HELD, asm_t)
    ! Condensed torsion: R <- R - M_t dTheta/dq and Kb <- Kb - M_t d2Theta/dq2 at q_cfg (the
    ! rank-one g g^T / C joins the solve by Sherman-Morrison; g is kept in tors_g). Nodal
    ! twist: the element torques and end springs (assemble_twist).
    IF (model%tw_active .AND. (want_residual .OR. want_tangent)) THEN
      CALL assemble_twist(model, q_cfg, v_cfg, want_residual, want_tangent, R, Kb, Kvb, es, em2)
      IF (es /= CD_HCDYN_OK) THEN
        ErrStat = es; ErrMsg = TRIM(em2); RETURN
      END IF
    ELSE IF (model%torsion%active .AND. (want_residual .OR. want_tangent)) THEN
      CALL assemble_torsion(model, q_cfg, want_residual, want_tangent, es, em2)
      IF (es /= CD_HCDYN_OK) THEN
        ErrStat = es; ErrMsg = TRIM(em2); RETURN
      END IF
    END IF
    CALL asm_mark(HC_ASM_TORSION, asm_t)
    ! A complete keeping assembly records the state its element tangents belong to.
    IF (kept) THEN
      model%ws_stash_q = q_cfg
      model%ws_stash_v = v_cfg
      model%ws_stash_t = t_eval
      model%ws_stash_ok = .TRUE.
    END IF
  END SUBROUTINE assemble_residual

  SUBROUTINE assemble_torsion(model, q_cfg, want_residual, want_tangent, ErrStat, ErrMsg)
    !! Condensed-torsion part of assemble_residual, allocation-free: Theta at q_cfg (unwrapped
    !! against the committed Theta, at most pi/2 away) with the committed end frames and Phi, or
    !! the running step's target ones (tors_use_step); M_t = (Phi - Theta)/C; R -= M_t dTheta/dq
    !! (want_residual); Kb -= M_t d2Theta/dq2 and tors_g = dTheta/dq (want_tangent).
    TYPE(CD_HermiteCableDynType), INTENT(INOUT), TARGET :: model
    REAL(wp), INTENT(IN) :: q_cfg(:)
    LOGICAL, INTENT(IN) :: want_residual, want_tangent
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    REAL(wp), POINTER :: g(:)
    REAL(wp) :: raw, th, mt, phi
    INTEGER :: es, i
    CHARACTER(1024) :: em
    ErrStat = CD_HCDYN_OK
    ErrMsg = ''
    IF (want_tangent) THEN
      g => model%tors_g
    ELSE
      g => model%tors_gq
    END IF
    IF (model%tors_use_step) THEN
      phi = model%tors_step_phi
      CALL CD_HermiteTorsion_Line(q_cfg, model%l0, model%tors_step_ends, raw, g, es, em, &
                                  couple=model%torsion%couple, quadrature_order=model%torsion%quadrature_order, &
                                  work=model%tors_work, &
                                  keep_hessian=want_tangent)
    ELSE
      phi = model%torsion%phi
      CALL CD_HermiteTorsion_Line(q_cfg, model%l0, model%torsion%ends, raw, g, es, em, &
                                  couple=model%torsion%couple, quadrature_order=model%torsion%quadrature_order, &
                                  work=model%tors_work, &
                                  keep_hessian=want_tangent)
    END IF
    IF (es /= CD_HTORS_OK) THEN
      ErrStat = CD_HCDYN_NOCONVERGE
      ErrMsg = 'torsion: '//TRIM(em)
      RETURN
    END IF
    th = CD_HermiteTorsion_Unwrap(raw, model%torsion%theta)
    IF (ABS(th - model%torsion%theta) > CD_HTORS_MAX_STEP) THEN
      ErrStat = CD_HCDYN_NOCONVERGE
      ErrMsg = 'torsion: the twist moved more than pi/2 from its accepted value'
      RETURN
    END IF
    mt = (phi - th)/CD_HermiteTorsion_Compliance(model%torsion, model%l0)
    IF (want_residual) THEN
      DO i = 1, model%ndof
        model%ws_R(i) = model%ws_R(i) - mt*g(i)
      END DO
    END IF
    IF (want_tangent) THEN
      CALL CD_HermiteTorsion_Work_Add_Hessian(model%tors_work, model%ws_Kb, -mt, es, em)
      IF (es /= CD_HTORS_OK) THEN
        ErrStat = CD_HCDYN_NOCONVERGE
        ErrMsg = 'torsion: '//TRIM(em)
        RETURN
      END IF
    END IF
  END SUBROUTINE assemble_torsion

  ! ------------------------------------------------------------------------------------------
  ! nodal twist (see the type note)
  ! ------------------------------------------------------------------------------------------

  PURE INTEGER FUNCTION tw_pack_size(model) RESULT(n)
    !! Reals of the packed twist state of tw_pack: the angles, rates and accelerations, the
    !! directors and unit tangents, the reference twists, the element torques, the two
    !! end-frame references and the end frames' angular velocities and accelerations of the
    !! committed step.
    TYPE(CD_HermiteCableDynType), INTENT(IN) :: model
    n = 9*model%nn + 2*model%ne + 14
  END FUNCTION tw_pack_size

  PURE SUBROUTINE tw_pack(model, buf)
    TYPE(CD_HermiteCableDynType), INTENT(IN) :: model
    REAL(wp), INTENT(OUT) :: buf(:)
    INTEGER :: nn, ne
    nn = model%nn
    ne = model%ne
    buf(1:nn) = model%tw_phi
    buf(nn + 1:2*nn) = model%tw_w
    buf(2*nn + 1:3*nn) = model%tw_al
    buf(3*nn + 1:6*nn) = RESHAPE(model%tw_u, [3*nn])
    buf(6*nn + 1:9*nn) = RESHAPE(model%tw_tn, [3*nn])
    buf(9*nn + 1:9*nn + ne) = model%tw_beta
    buf(9*nn + ne + 1:9*nn + 2*ne) = model%tw_mt
    buf(9*nn + 2*ne + 1:9*nn + 2*ne + 2) = model%tw_psi
    buf(9*nn + 2*ne + 3:9*nn + 2*ne + 8) = RESHAPE(model%tw_om, [6])
    buf(9*nn + 2*ne + 9:9*nn + 2*ne + 14) = RESHAPE(model%tw_oal, [6])
  END SUBROUTINE tw_pack

  PURE SUBROUTINE tw_unpack(model, buf)
    TYPE(CD_HermiteCableDynType), INTENT(INOUT) :: model
    REAL(wp), INTENT(IN) :: buf(:)
    INTEGER :: nn, ne
    nn = model%nn
    ne = model%ne
    model%tw_phi = buf(1:nn)
    model%tw_w = buf(nn + 1:2*nn)
    model%tw_al = buf(2*nn + 1:3*nn)
    model%tw_u = RESHAPE(buf(3*nn + 1:6*nn), [3, nn])
    model%tw_tn = RESHAPE(buf(6*nn + 1:9*nn), [3, nn])
    model%tw_beta = buf(9*nn + 1:9*nn + ne)
    model%tw_mt = buf(9*nn + ne + 1:9*nn + 2*ne)
    model%tw_psi = buf(9*nn + 2*ne + 1:9*nn + 2*ne + 2)
    model%tw_om = RESHAPE(buf(9*nn + 2*ne + 3:9*nn + 2*ne + 8), [3, 2])
    model%tw_oal = RESHAPE(buf(9*nn + 2*ne + 9:9*nn + 2*ne + 14), [3, 2])
  END SUBROUTINE tw_unpack

  ELEMENTAL REAL(wp) FUNCTION tw_wrap(x) RESULT(y)
    !! x on (-pi, pi] (an angle change over one step; 0 stays exactly 0).
    REAL(wp), INTENT(IN) :: x
    y = x - 2.0_wp*CD_HTORS_PI*ANINT(x/(2.0_wp*CD_HTORS_PI))
  END FUNCTION tw_wrap

  PURE FUNCTION tw_cross(a, b) RESULT(c)
    REAL(wp), INTENT(IN) :: a(3), b(3)
    REAL(wp) :: c(3)
    c = [a(2)*b(3) - a(3)*b(2), a(3)*b(1) - a(1)*b(3), a(1)*b(2) - a(2)*b(1)]
  END FUNCTION tw_cross

  PURE SUBROUTINE tw_frames(model, ends, phi_end)
    !! The end frames and Phi an evaluation takes: the running step's target, or the committed.
    TYPE(CD_HermiteCableDynType), INTENT(IN) :: model
    REAL(wp), INTENT(OUT) :: ends(3, 4), phi_end
    IF (model%tors_use_step) THEN
      ends = model%tors_step_ends
      phi_end = model%tors_step_phi
    ELSE
      ends = model%torsion%ends
      phi_end = model%torsion%phi
    END IF
  END SUBROUTINE tw_frames

  SUBROUTINE twist_reference(model, e, q_cfg, ends, want_hess, rho, beta, g, h, ErrStat, ErrMsg, end_w)
    !! rho_e(q) of element e (the material twist is phi_{e+1} - phi_e + rho_e less the coupling
    !! term), its gradient g and, with want_hess, Hessian h over the element's 12 DOFs, at q_cfg
    !! with the end frames ends. beta is the reference-twist part: the committed tw_beta(e) plus
    !! the change of the end-frame constant and of the transport solid angles since the
    !! committed state, each formed as a difference so that the committed state and frames give
    !! tw_beta(e) bit for bit. Interior element: beta = beta^n - Omega(a, b, c) - Omega(a, c, d),
    !! a, d the committed and b, c the present unit node tangents. An element at a rigid end
    !! takes the end frame's normal carried to its end node as that node's director (see
    !! CD_HermiteTwist_Reference). end_w(:, k), when asked for, is d rho/d w_k for an incremental
    !! rotation w_k of the end frame k (zero unless the element reaches a rigid end).
    TYPE(CD_HermiteCableDynType), INTENT(IN) :: model
    INTEGER, INTENT(IN) :: e
    REAL(wp), INTENT(IN) :: q_cfg(:), ends(3, 4)
    LOGICAL, INTENT(IN) :: want_hess
    REAL(wp), INTENT(OUT) :: rho, beta, g(12), h(12, 12)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    REAL(wp), INTENT(OUT), OPTIONAL :: end_w(3, 2)
    REAL(wp) :: qe(12), tri(3, 3, 2), sg(2), fg(3, 3, 2), z(3), a(3), d(3), val, oref, cnow, cref
    REAL(wp) :: he, ge(12), hk(12, 12), ls, gs(12), hs(12, 12), om, g9(9), cpl
    REAL(wp) :: dA(3), nA(3), dB(3), nB(3), dAc(3), nAc(3), dBc(3), nBc(3)
    INTEGER :: slot(3, 2), owner(3, 2), kind, es, k, j
    CHARACTER(200) :: em

    rho = CD_ZERO
    beta = CD_ZERO
    g = CD_ZERO
    h = CD_ZERO
    IF (PRESENT(end_w)) end_w = CD_ZERO
    ErrStat = CD_HCDYN_OK
    ErrMsg = ''
    qe = q_cfg(6*e - 5:6*e + 6)
    a = model%tw_tn(:, e)
    d = model%tw_tn(:, e + 1)
    z = CD_ZERO
    dA = ends(:, 1)
    nA = ends(:, 2)
    dB = ends(:, 3)
    nB = ends(:, 4)
    dAc = model%torsion%ends(:, 1)
    nAc = model%torsion%ends(:, 2)
    dBc = model%torsion%ends(:, 3)
    nBc = model%torsion%ends(:, 4)
    kind = 0
    IF (e == 1 .AND. model%tw_rigid(1)) kind = 1
    IF (e == model%ne .AND. model%tw_rigid(2)) kind = kind + 2
    cnow = CD_ZERO
    cref = CD_ZERO
    owner = 0
    sg = -CD_ONE
    oref = CD_ZERO
    SELECT CASE (kind)
    CASE (0)
      tri(:, :, 1) = RESHAPE([a, z, z], [3, 3])
      slot(:, 1) = [0, 1, 2]
      tri(:, :, 2) = RESHAPE([a, z, d], [3, 3])
      slot(:, 2) = [0, 2, 0]
      oref = oref + sg(1)*CD_HermiteTwist_Omega(a, a, d)
      oref = oref + sg(2)*CD_HermiteTwist_Omega(a, d, d)
    CASE (1)
      ! node 1 director G(d_A -> t_1) n_A
      tri(:, :, 1) = RESHAPE([dA, z, z], [3, 3])
      slot(:, 1) = [0, 1, 2]
      owner(1, 1) = 1
      tri(:, :, 2) = RESHAPE([dA, z, d], [3, 3])
      slot(:, 2) = [0, 2, 0]
      owner(1, 2) = 1
      oref = oref + sg(1)*CD_HermiteTwist_Omega(dAc, a, d)
      oref = oref + sg(2)*CD_HermiteTwist_Omega(dAc, d, d)
      cnow = CD_HermiteTwist_Angle(CD_HermiteTwist_Carry(dA, d, nA), model%tw_u(:, e + 1), d)
      cref = CD_HermiteTwist_Angle(CD_HermiteTwist_Carry(dAc, d, nAc), model%tw_u(:, e + 1), d)
    CASE (2)
      ! last-node director G(d_B -> t_N) n_B
      sg = [CD_ONE, -CD_ONE]
      tri(:, :, 1) = RESHAPE([dB, z, a], [3, 3])
      slot(:, 1) = [0, 2, 0]
      owner(1, 1) = 2
      tri(:, :, 2) = RESHAPE([a, z, z], [3, 3])
      slot(:, 2) = [0, 1, 2]
      oref = oref + sg(1)*CD_HermiteTwist_Omega(dBc, d, a)
      oref = oref + sg(2)*CD_HermiteTwist_Omega(a, a, d)
      cnow = CD_HermiteTwist_Angle(model%tw_u(:, e), CD_HermiteTwist_Carry(dB, a, nB), a)
      cref = CD_HermiteTwist_Angle(model%tw_u(:, e), CD_HermiteTwist_Carry(dBc, a, nBc), a)
    CASE (3)
      ! one element, rigid at both ends
      sg = [CD_ONE, -CD_ONE]
      tri(:, :, 1) = RESHAPE([dB, z, dA], [3, 3])
      slot(:, 1) = [0, 2, 0]
      owner(1, 1) = 2
      owner(3, 1) = 1
      tri(:, :, 2) = RESHAPE([dA, z, z], [3, 3])
      slot(:, 2) = [0, 1, 2]
      owner(1, 2) = 1
      oref = oref + sg(1)*CD_HermiteTwist_Omega(dBc, d, dAc)
      oref = oref + sg(2)*CD_HermiteTwist_Omega(dAc, a, d)
      cnow = CD_HermiteTwist_Angle(nA, CD_HermiteTwist_Carry(dB, dA, nB), dA)
      cref = CD_HermiteTwist_Angle(nAc, CD_HermiteTwist_Carry(dBc, dAc, nBc), dAc)
    END SELECT
    IF (want_hess) THEN
      CALL CD_HermiteTwist_Reference(qe, model%l0(e), tri, slot, sg, val, g, es, em, hess=h, holonomy=.FALSE., &
                                     fixed_grad=fg)
    ELSE
      CALL CD_HermiteTwist_Reference(qe, model%l0(e), tri, slot, sg, val, g, es, em, holonomy=.FALSE., fixed_grad=fg)
    END IF
    IF (es /= CD_HTORS_OK) THEN
      ErrStat = CD_HCDYN_NOCONVERGE
      ErrMsg = 'twist: '//TRIM(em)
      RETURN
    END IF
    ! the wrapped change of the end-frame constant is unique while the frame turns by less than
    ! pi between two committed states; pi/2 keeps the margin of the condensed torsion
    IF (ABS(tw_wrap(cnow - cref)) > CD_HTORS_MAX_STEP) THEN
      ErrStat = CD_HCDYN_NOCONVERGE
      ErrMsg = 'twist: an end frame turned by more than pi/2 about the line from its committed state'
      RETURN
    END IF
    beta = model%tw_beta(e) + tw_wrap(cnow - cref) + (val - oref)
    IF (want_hess) THEN
      CALL CD_HermiteTorsion_Element(qe, model%l0(e), he, ge, es, em, hess=hk, &
                                     quadrature_order=model%torsion%quadrature_order)
    ELSE
      CALL CD_HermiteTorsion_Element(qe, model%l0(e), he, ge, es, em, quadrature_order=model%torsion%quadrature_order)
    END IF
    IF (es /= CD_HTORS_OK) THEN
      ErrStat = CD_HCDYN_NOCONVERGE
      ErrMsg = 'twist: '//TRIM(em)
      RETURN
    END IF
    rho = beta - he
    g = g - ge
    IF (want_hess) h = h - hk
    cpl = CD_ZERO
    IF (ALLOCATED(model%torsion%couple)) cpl = model%torsion%couple(e)
    IF (ABS(cpl) > CD_ZERO) THEN
      CALL CD_HermiteTorsion_Stretch_Derivatives(qe, model%l0(e), ls, gs, hs, model%torsion%quadrature_order)
      rho = rho + cpl*(ls - model%l0(e))
      g = g + cpl*gs
      IF (want_hess) h = h + cpl*hs
    END IF
    IF (PRESENT(end_w) .AND. kind > 0) THEN
      ! fixed frame vertices turn with their frame: d Omega/d w = d x dOmega/dd
      DO k = 1, 2
        DO j = 1, 3
          IF (owner(j, k) == 0) CYCLE
          end_w(:, owner(j, k)) = end_w(:, owner(j, k)) + tw_cross(tri(:, j, k), fg(:, j, k))
        END DO
      END DO
      ! the end-frame constants (see the derivation in CD_HermiteCable_Dyn_EndConnection_Moment)
      SELECT CASE (kind)
      CASE (1)
        CALL CD_HermiteTwist_Omega_Gradient(dA, dA, d, om, g9)
        end_w(:, 1) = end_w(:, 1) - dA - tw_cross(dA, g9(4:6))
      CASE (2)
        CALL CD_HermiteTwist_Omega_Gradient(dB, dB, a, om, g9)
        end_w(:, 2) = end_w(:, 2) + dB + tw_cross(dB, g9(4:6))
      CASE (3)
        CALL CD_HermiteTwist_Omega_Gradient(dB, dB, dA, om, g9)
        end_w(:, 2) = end_w(:, 2) + dB + tw_cross(dB, g9(4:6))
        CALL CD_HermiteTwist_Omega_Gradient(dB, dA, dA, om, g9)
        end_w(:, 1) = end_w(:, 1) - dA + tw_cross(dA, g9(4:6))
      END SELECT
    END IF
  END SUBROUTINE twist_reference

  SUBROUTINE twist_link(model, iend, q_cfg, ends, want_hess, psi, gl, hl, ErrStat, ErrMsg, end_w)
    !! The end-frame reference psi of the elastic end iend: the angle about the end node's
    !! tangent from its director to the end frame's normal carried to the node, psi = psi^n +
    !! (change of angle(u^n -> G(d -> t^n) n)) + Omega(d, t, t^n) - Omega(d^n, t^n, t^n), with its
    !! gradient gl and Hessian hl in the end node's tangent handle m, and, when asked for,
    !! end_w = d psi/d w of an incremental rotation of the end frame. The end spring twists by
    !! phi_1 - psi at end 1 and by psi + Phi - phi_N at end 2.
    TYPE(CD_HermiteCableDynType), INTENT(IN) :: model
    INTEGER, INTENT(IN) :: iend
    REAL(wp), INTENT(IN) :: q_cfg(:), ends(3, 4)
    LOGICAL, INTENT(IN) :: want_hess
    REAL(wp), INTENT(OUT) :: psi, gl(3), hl(3, 3)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    REAL(wp), INTENT(OUT), OPTIONAL :: end_w(3)
    REAL(wp) :: qe(12), tri(3, 3, 1), fg(3, 3, 1), g12(12), h12(12, 12), z(3), a(3), u(3), dd(3), nd(3)
    REAL(wp) :: dc(3), nc(3), val, oref, cnow, cref, om, g9(9)
    INTEGER :: node, slot(3, 1), es
    CHARACTER(200) :: em
    psi = CD_ZERO
    gl = CD_ZERO
    hl = CD_ZERO
    IF (PRESENT(end_w)) end_w = CD_ZERO
    ErrStat = CD_HCDYN_OK
    ErrMsg = ''
    node = MERGE(1, model%nn, iend == 1)
    qe = CD_ZERO
    qe(4:6) = q_cfg(6*node - 2:6*node)
    a = model%tw_tn(:, node)
    u = model%tw_u(:, node)
    z = CD_ZERO
    dd = ends(:, 2*iend - 1)
    nd = ends(:, 2*iend)
    dc = model%torsion%ends(:, 2*iend - 1)
    nc = model%torsion%ends(:, 2*iend)
    tri(:, :, 1) = RESHAPE([dd, z, a], [3, 3])
    slot(:, 1) = [0, 1, 0]
    oref = CD_ZERO
    oref = oref + CD_ONE*CD_HermiteTwist_Omega(dc, a, a)
    cnow = CD_HermiteTwist_Angle(u, CD_HermiteTwist_Carry(dd, a, nd), a)
    cref = CD_HermiteTwist_Angle(u, CD_HermiteTwist_Carry(dc, a, nc), a)
    IF (want_hess) THEN
      CALL CD_HermiteTwist_Reference(qe, model%l0(1), tri, slot, [CD_ONE], val, g12, es, em, hess=h12, &
                                     holonomy=.FALSE., fixed_grad=fg)
    ELSE
      CALL CD_HermiteTwist_Reference(qe, model%l0(1), tri, slot, [CD_ONE], val, g12, es, em, holonomy=.FALSE., &
                                     fixed_grad=fg)
    END IF
    IF (es /= CD_HTORS_OK) THEN
      ErrStat = CD_HCDYN_NOCONVERGE
      ErrMsg = 'twist end link: '//TRIM(em)
      RETURN
    END IF
    IF (ABS(tw_wrap(cnow - cref)) > CD_HTORS_MAX_STEP) THEN
      ErrStat = CD_HCDYN_NOCONVERGE
      ErrMsg = 'twist end link: the end frame turned by more than pi/2 about the line from its committed state'
      RETURN
    END IF
    psi = model%tw_psi(iend) + tw_wrap(cnow - cref) + (val - oref)
    gl = g12(4:6)
    IF (want_hess) hl = h12(4:6, 4:6)
    IF (PRESENT(end_w)) THEN
      CALL CD_HermiteTwist_Omega_Gradient(dd, dd, a, om, g9)
      end_w = dd + tw_cross(dd, g9(4:6)) + tw_cross(dd, fg(:, 1, 1))
    END IF
  END SUBROUTINE twist_link

  SUBROUTINE assemble_twist(model, q_cfg, v_cfg, want_residual, want_tangent, R, Kb, Kvb, ErrStat, ErrMsg)
    !! Nodal-twist part of assemble_residual: every element's torque M_e = (GJ/l0) tw_e + (Bt/l0)
    !! d tw_e/dt (tw_e = phi_{e+1} - phi_e + rho_e(q), d/dt from the nodal rates and g . q_dot)
    !! and every elastic end's spring, at q_cfg, v_cfg and the angles and rates of the running
    !! step (tw_pe, tw_we) or of the committed state. R gains M_e drho_e/dq and tw_R the nodal
    !! torques (want_residual); Kb gains M_e d2rho_e/dq2 + (GJ/l0) g g^T (+ the damping's
    !! g (H q_dot)^T) and Kvb (Bt/l0) g g^T, and the coupling to the angles is kept per element
    !! for the solve (tw_eg, tw_ehv, tw_ek, tw_ed, tw_lg, tw_lk; want_tangent). tw_me holds the
    !! element torques and tw_tsum the summed twist.
    !!
    !! An element whose length changes at the rate l0_dot (active line control) damps the rate of
    !! its twist per length, the quantity tau/l0 its elastic torque GJ tau/l0 reads, as the axial
    !! damping takes the rate of the strain: M_e = (GJ/l0) tau + (Bt/l0) (d tau/dt - tau l0_dot/l0),
    !! so a segment paid out at a constant twist per length carries no damping torque. At fixed q,
    !! tau changes with l0 through the coupling term -(K/GJ) l0 and through the element's shape:
    !! rho_e depends on the tangent handles m only through l0 m (the Hermite r' and r'') and m/|m|,
    !! so l0 drho/dl0 = m_1 . drho/dm_1 + m_2 . drho/dm_2 - (K/GJ) l0 (an Euler identity of the
    !! gradient g), and d tau/dt gains (l0_dot/l0)(m . g_m - (K/GJ) l0). The angle stiffness of the
    !! element becomes GJ/l0 - (Bt/l0) l0_dot/l0 and its q-gradient gains (Bt/l0)(l0_dot/l0)
    !! (g_m + H m), H the Hessian of rho_e.
    TYPE(CD_HermiteCableDynType), INTENT(INOUT), TARGET :: model
    REAL(wp), INTENT(IN) :: q_cfg(:), v_cfg(:)
    LOGICAL, INTENT(IN) :: want_residual, want_tangent
    REAL(wp), INTENT(INOUT) :: R(:), Kb(:, :), Kvb(:, :)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    REAL(wp), POINTER :: phi(:), w(:)
    REAL(wp) :: ends(3, 4), phi_end, rho, beta, g(12), h(12, 12), ve(12), hv(12), ke(12, 12), kel, kd
    REAL(wp) :: om(3, 2), ew(3, 2)
    LOGICAL :: turning
    REAL(wp) :: tau, rate, mt, psi, gl(3), hl(3, 3), k, tw
    ! length-rate share of the damping (active line control): l0_dot/l0, the element's tangent
    ! handles (m in the 12-DOF layout, the r slots zero) and the angle stiffness it leaves
    REAL(wp) :: rr, mv(12), gmv(12), kel_t, cpl
    LOGICAL :: ctrl_rate
    INTEGER :: e, iend, node, b, i, j, es
    CHARACTER(1024) :: em

    ErrStat = CD_HCDYN_OK
    ErrMsg = ''
    CALL tw_frames(model, ends, phi_end)
    IF (model%tors_use_step) THEN
      phi => model%tw_pe
      w => model%tw_we
    ELSE
      phi => model%tw_phi
      w => model%tw_w
    END IF
    IF (want_residual) model%tw_R = CD_ZERO
    model%tw_tsum = CD_ZERO
    om = MERGE(model%tw_som, model%tw_om, model%tors_use_step)
    turning = ANY(ABS(om) > CD_ZERO) .AND. ALLOCATED(model%torsion%bt)
    DO e = 1, model%ne
      kd = CD_ZERO
      IF (ALLOCATED(model%torsion%bt)) kd = model%torsion%bt(e)/model%l0(e)
      ! an element at a rigid end twists through rho as its end frame turns: its damping rate
      ! takes d rho/dw . omega of the frames (the tangent keeps the rate's q-dependence through
      ! g only, as the frame's share of it is of order omega dt)
      IF (turning .AND. kd > CD_ZERO .AND. (e == 1 .OR. e == model%ne)) THEN
        CALL twist_reference(model, e, q_cfg, ends, want_tangent, rho, beta, g, h, es, em, end_w=ew)
      ELSE
        CALL twist_reference(model, e, q_cfg, ends, want_tangent, rho, beta, g, h, es, em)
        ew = CD_ZERO
      END IF
      IF (es /= CD_HCDYN_OK) THEN
        ErrStat = es
        ErrMsg = TRIM(em)
        RETURN
      END IF
      ve = v_cfg(6*e - 5:6*e + 6)
      kel = model%torsion%gj(e)/model%l0(e)
      tau = phi(e + 1) - phi(e) + rho
      rate = w(e + 1) - w(e) + DOT_PRODUCT(g, ve)
      IF (turning .AND. kd > CD_ZERO) rate = rate + DOT_PRODUCT(ew(:, 1), om(:, 1)) + DOT_PRODUCT(ew(:, 2), om(:, 2))
      kel_t = kel
      rr = CD_ZERO
      IF (model%has_ctrl .AND. kd > CD_ZERO) rr = model%l0_dot(e)/model%l0(e)
      ctrl_rate = ABS(rr) > CD_ZERO
      mv = CD_ZERO
      IF (ctrl_rate) THEN
        ! the rate of the twist per length (see the header): (l0_dot/l0)(m . g_m - (K/GJ) l0 - tau)
        mv(4:6) = q_cfg(6*e - 2:6*e)
        mv(10:12) = q_cfg(6*e + 4:6*e + 6)
        cpl = CD_ZERO
        IF (ALLOCATED(model%torsion%couple)) cpl = model%torsion%couple(e)
        rate = rate + rr*(DOT_PRODUCT(g, mv) - cpl*model%l0(e) - tau)
        kel_t = kel - kd*rr
      END IF
      mt = kel*tau + kd*rate
      model%tw_me(e) = mt
      model%tw_tsum = model%tw_tsum + tau
      IF (want_residual) THEN
        R(6*e - 5:6*e + 6) = R(6*e - 5:6*e + 6) + mt*g
        model%tw_R(e) = model%tw_R(e) - mt
        model%tw_R(e + 1) = model%tw_R(e + 1) + mt
      END IF
      IF (want_tangent) THEN
        hv = CD_ZERO
        IF (kd > CD_ZERO) hv = MATMUL(h, ve)
        ! the length-rate share: d(m . g_m)/dq = g_m + H m (H symmetric), and -tau rr in kel_t
        IF (ctrl_rate) THEN
          gmv = CD_ZERO
          gmv(4:6) = g(4:6)
          gmv(10:12) = g(10:12)
          hv = MATMUL(h, ve + rr*mv) + rr*gmv
        END IF
        DO j = 1, 12
          DO i = 1, 12
            ke(i, j) = mt*h(i, j) + kel_t*g(i)*g(j) + kd*g(i)*hv(j)
          END DO
        END DO
        CALL scatter12_band(Kb, ke, e)
        IF (kd > CD_ZERO) THEN
          DO j = 1, 12
            DO i = 1, 12
              ke(i, j) = kd*g(i)*g(j)
            END DO
          END DO
          CALL scatter12_band(Kvb, ke, e)
        END IF
        model%tw_eg(:, e) = g
        model%tw_ehv(:, e) = hv
        model%tw_ek(e) = kel_t
        model%tw_ed(e) = kd
      END IF
    END DO
    IF (want_tangent) THEN
      model%tw_lg = CD_ZERO
      model%tw_lk = CD_ZERO
    END IF
    DO iend = 1, 2
      IF (.NOT. tw_spring(model, iend)) CYCLE
      CALL twist_link(model, iend, q_cfg, ends, want_tangent, psi, gl, hl, es, em)
      IF (es /= CD_HCDYN_OK) THEN
        ErrStat = es
        ErrMsg = TRIM(em)
        RETURN
      END IF
      k = CD_ONE/model%torsion%end_compliance(iend)
      node = MERGE(1, model%nn, iend == 1)
      b = 6*node - 3
      IF (iend == 1) THEN
        tw = phi(1) - psi
      ELSE
        tw = psi + phi_end - phi(model%nn)
      END IF
      mt = k*tw
      model%tw_tsum = model%tw_tsum + tw
      IF (want_residual) THEN
        IF (iend == 1) THEN
          R(b + 1:b + 3) = R(b + 1:b + 3) - mt*gl
          model%tw_R(1) = model%tw_R(1) + mt
        ELSE
          R(b + 1:b + 3) = R(b + 1:b + 3) + mt*gl
          model%tw_R(model%nn) = model%tw_R(model%nn) - mt
        END IF
      END IF
      IF (want_tangent) THEN
        DO j = 1, 3
          DO i = 1, 3
            Kb(KL_D + KU_D + 1 + i - j, b + j) = Kb(KL_D + KU_D + 1 + i - j, b + j) + k*gl(i)*gl(j) + &
                                                 MERGE(-mt, mt, iend == 1)*hl(i, j)
          END DO
        END DO
        model%tw_lg(:, iend) = gl
        model%tw_lk(iend) = k
      END IF
    END DO
  END SUBROUTINE assemble_twist

  SUBROUTINE tw_build_K7(model, cm, ck, cv, bases, ErrStat, ErrMsg)
    !! The effective tangent of the nodal-twist step in 7-DOF-per-node order ([r, m, phi] per
    !! node, KL = KU = 13) from the cable's ws_Keffb (already in the rigid-end basis, Dirichlet
    !! applied) and the twist data of the last tangent assembly: cm M + ck K + cv Kv for the
    !! angles' lumped inertia, stiffness and damping and their coupling to q (the q rows and
    !! columns of a rigid end in its basis, those of fixed DOFs and of held angles zeroed).
    TYPE(CD_HermiteCableDynType), INTENT(INOUT) :: model
    REAL(wp), INTENT(IN) :: cm, ck, cv, bases(3, 3, 2)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    INTEGER :: i6, j6, i7, j7, e, a, gi, p, iend, node, b
    REAL(wp) :: colv(12), rowv(12), d, kl3(3)
    ErrStat = CD_HCDYN_OK
    ErrMsg = ''
    model%tw_K7 = CD_ZERO
    DO j6 = 1, model%ndof
      j7 = j6 + (j6 - 1)/6
      DO i6 = MAX(1, j6 - KU_D), MIN(model%ndof, j6 + KL_D)
        i7 = i6 + (i6 - 1)/6
        model%tw_K7(2*KB7 + 1 + i7 - j7, j7) = model%ws_Keffb(KL_D + KU_D + 1 + i6 - j6, j6)
      END DO
    END DO
    DO e = 1, model%ne
      ! q rows of the angle columns, (ck GJ/l0 + cv Bt/l0) g, and angle rows of the q columns,
      ! ck (GJ/l0 g + Bt/l0 H q_dot) + cv Bt/l0 g; both + at phi_{e+1} and - at phi_e
      colv = (ck*model%tw_ek(e) + cv*model%tw_ed(e))*model%tw_eg(:, e)
      rowv = ck*(model%tw_ek(e)*model%tw_eg(:, e) + model%tw_ed(e)*model%tw_ehv(:, e)) + &
             cv*model%tw_ed(e)*model%tw_eg(:, e)
      IF (e == 1) CALL rigid_local(1, colv(4:6), rowv(4:6))
      IF (e == model%ne) CALL rigid_local(2, colv(10:12), rowv(10:12))
      d = ck*model%tw_ek(e) + cv*model%tw_ed(e)
      DO a = 1, 12
        gi = elem_gdof(e, a)
        IF (.NOT. model%solve_mask(gi)) CYCLE
        DO p = e, e + 1
          IF (.NOT. model%tw_free(p)) CYCLE
          CALL add7(gi + (gi - 1)/6, 7*p, MERGE(colv(a), -colv(a), p == e + 1))
          CALL add7(7*p, gi + (gi - 1)/6, MERGE(rowv(a), -rowv(a), p == e + 1))
        END DO
      END DO
      DO p = e, e + 1
        IF (.NOT. model%tw_free(p)) CYCLE
        DO i6 = e, e + 1
          IF (.NOT. model%tw_free(i6)) CYCLE
          CALL add7(7*p, 7*i6, MERGE(d, -d, p == i6))
        END DO
      END DO
    END DO
    DO iend = 1, 2
      IF (.NOT. model%tw_lk(iend) > CD_ZERO) CYCLE
      node = MERGE(1, model%nn, iend == 1)
      IF (.NOT. model%tw_free(node)) CYCLE
      kl3 = -ck*model%tw_lk(iend)*model%tw_lg(:, iend)
      colv(1:3) = kl3
      rowv(1:3) = kl3
      CALL rigid_local(iend, colv(1:3), rowv(1:3))
      b = 6*node - 3
      DO a = 1, 3
        gi = b + a
        IF (.NOT. model%solve_mask(gi)) CYCLE
        CALL add7(gi + (gi - 1)/6, 7*node, colv(a))
        CALL add7(7*node, gi + (gi - 1)/6, rowv(a))
      END DO
      CALL add7(7*node, 7*node, ck*model%tw_lk(iend))
    END DO
    DO p = 1, model%nn
      IF (model%tw_free(p)) THEN
        CALL add7(7*p, 7*p, cm*model%tw_mass(p))
      ELSE
        model%tw_K7(2*KB7 + 1, 7*p) = CD_ONE
      END IF
    END DO
    ! column by column (a reshaped copy would be a heap temporary)
    DO p = 1, SIZE(model%tw_K7, 2)
      IF (.NOT. CD_All_Finite(model%tw_K7(:, p))) THEN
        ErrStat = CD_HCDYN_NOCONVERGE
        ErrMsg = 'twist: non-finite effective tangent'
        RETURN
      END IF
    END DO
  CONTAINS
    SUBROUTINE add7(r7, c7, val)
      INTEGER, INTENT(IN) :: r7, c7
      REAL(wp), INTENT(IN) :: val
      model%tw_K7(2*KB7 + 1 + r7 - c7, c7) = model%tw_K7(2*KB7 + 1 + r7 - c7, c7) + val
    END SUBROUTINE add7
    SUBROUTINE rigid_local(iend_l, cv3, rv3)
      !! The tangent-DOF entries of a rigid end in its basis (as transform_rigid_band).
      INTEGER, INTENT(IN) :: iend_l
      REAL(wp), INTENT(INOUT) :: cv3(3), rv3(3)
      IF (model%endconn_mode(iend_l) /= CD_ENDCONN_RIGID) RETURN
      cv3 = MATMUL(TRANSPOSE(bases(:, :, iend_l)), cv3)
      rv3 = MATMUL(rv3, bases(:, :, iend_l))
    END SUBROUTINE rigid_local
  END SUBROUTINE tw_build_K7

  SUBROUTINE tw_solve(model, ErrStat, ErrMsg)
    !! Solve the factored tw_K7 for the direction [ws_dq, tw_dp] (right-hand sides on entry,
    !! the solution on return).
    TYPE(CD_HermiteCableDynType), INTENT(INOUT) :: model
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    INTEGER :: i
    DO i = 1, model%ndof
      model%tw_x7(i + (i - 1)/6) = model%ws_dq(i)
    END DO
    DO i = 1, model%nn
      model%tw_x7(7*i) = model%tw_dp(i)
    END DO
    CALL CD_Solve_Factored_Banded(model%tw_K7, KB7, KB7, model%tw_ipiv, model%tw_x7, ErrStat, ErrMsg, &
                                  factor_validated=.TRUE.)
    IF (ErrStat /= CD_LINALG_OK) RETURN
    DO i = 1, model%ndof
      model%ws_dq(i) = model%tw_x7(i + (i - 1)/6)
    END DO
    DO i = 1, model%nn
      model%tw_dp(i) = model%tw_x7(7*i)
    END DO
  END SUBROUTINE tw_solve

  SUBROUTINE tw_init(model, mt, ErrStat, ErrMsg)
    !! Install the nodal twist of the committed configuration under the uniform torque mt (the
    !! condensed torque of the static state): directors carried along the line from the End-1
    !! frame (each element's own transport, so every interior reference twist is the element
    !! holonomy), angles accumulated from the element twists mt l0/GJ - rho_e and the end
    !! compliances, rates zero. A rigid end 2 holds phi = Phi: the last element's reference
    !! twist takes the multiple of 2 pi the accumulated angle needs, as an elastic end 2's psi
    !! does; a remainder above STATE_TOL (a static state off equilibrium) fails closed. A free
    !! end (mt = 0) has no reference of its own: a free end 1 starts the directors from its
    !! gauge frame and the angles shift as one to meet the restrained end 2 (its held Phi or a
    !! slack spring); a free end 2 ends the accumulation.
    TYPE(CD_HermiteCableDynType), INTENT(INOUT) :: model
    REAL(wp), INTENT(IN) :: mt
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    REAL(wp), PARAMETER :: STATE_TOL = 1.0e-6_wp
    INTEGER :: nn, ne, i, e, es
    REAL(wp) :: v(3), t(3), he, ge(12), qe(12), rho, beta, g(12), h(12, 12), diff, kk, ends(3, 4), phi_end, psi
    REAL(wp) :: tol
    CHARACTER(200) :: em
    CHARACTER(1024) :: em2
    ErrStat = CD_HCDYN_OK
    ErrMsg = ''
    nn = model%nn
    ne = model%ne
    IF (ALLOCATED(model%tw_phi)) THEN
      IF (SIZE(model%tw_phi) /= nn) CALL tw_release(model)
    END IF
    IF (.NOT. ALLOCATED(model%tw_phi)) THEN
      ALLOCATE (model%tw_phi(nn), model%tw_w(nn), model%tw_al(nn), model%tw_mass(nn), model%tw_u(3, nn), &
                model%tw_tn(3, nn), model%tw_beta(ne), model%tw_mt(ne), model%tw_free(nn))
      ALLOCATE (model%tw_pn(nn), model%tw_wn(nn), model%tw_an(nn), model%tw_pk(nn), model%tw_wk(nn), &
                model%tw_ak(nn), model%tw_ptrial(nn), model%tw_dp(nn), model%tw_G(nn), model%tw_Gt(nn), &
                model%tw_Rk(nn), model%tw_Rt(nn), model%tw_R(nn), model%tw_fcR(nn), model%tw_pe(nn), &
                model%tw_we(nn))
      ALLOCATE (model%tw_eg(12, ne), model%tw_ehv(12, ne), model%tw_ek(ne), model%tw_ed(ne), model%tw_me(ne))
      ALLOCATE (model%tw_K7(3*KB7 + 1, 7*nn), model%tw_x7(7*nn), model%tw_ipiv(7*nn))
      ALLOCATE (model%tw_su(3, nn), model%tw_stn(3, nn), model%tw_sbeta(ne))
      ALLOCATE (model%ws_recovery_tw(tw_pack_size(model)))
    END IF
    model%tw_pn = CD_ZERO; model%tw_wn = CD_ZERO; model%tw_an = CD_ZERO; model%tw_pk = CD_ZERO
    model%tw_wk = CD_ZERO; model%tw_ak = CD_ZERO; model%tw_ptrial = CD_ZERO; model%tw_dp = CD_ZERO
    model%tw_G = CD_ZERO; model%tw_Gt = CD_ZERO; model%tw_Rk = CD_ZERO; model%tw_Rt = CD_ZERO
    model%tw_R = CD_ZERO; model%tw_fcR = CD_ZERO; model%tw_eg = CD_ZERO; model%tw_ehv = CD_ZERO
    model%tw_ek = CD_ZERO; model%tw_ed = CD_ZERO; model%tw_me = CD_ZERO
    CALL tw_set_derived(model, model%torsion)
    DO i = 1, nn
      model%tw_tn(:, i) = model%q(6*i - 2:6*i)/NORM2(model%q(6*i - 2:6*i))
    END DO
    ends = model%torsion%ends
    phi_end = model%torsion%phi
    model%tw_u(:, 1) = unit_perp(CD_HermiteTwist_Carry(ends(:, 1), model%tw_tn(:, 1), ends(:, 2)), model%tw_tn(:, 1))
    DO e = 1, ne
      qe = model%q(6*e - 5:6*e + 6)
      CALL CD_HermiteTorsion_Element(qe, model%l0(e), he, ge, es, em, quadrature_order=model%torsion%quadrature_order)
      IF (es /= CD_HTORS_OK) THEN
        ErrStat = CD_HCDYN_BADINPUT
        ErrMsg = 'twist: '//TRIM(em)
        RETURN
      END IF
      t = model%tw_tn(:, e + 1)
      v = CD_HermiteTwist_Carry(model%tw_tn(:, e), t, model%tw_u(:, e))
      model%tw_u(:, e + 1) = unit_perp(COS(he)*v + SIN(he)*tw_cross(t, v), t)
    END DO
    IF (model%tw_rigid(2)) model%tw_u(:, nn) = unit_perp(CD_HermiteTwist_Carry(ends(:, 3), model%tw_tn(:, nn), &
                                                                               ends(:, 4)), model%tw_tn(:, nn))
    DO e = 1, ne
      model%tw_beta(e) = CD_HermiteTwist_Angle(CD_HermiteTwist_Carry(model%tw_tn(:, e), model%tw_tn(:, e + 1), &
                                                                     model%tw_u(:, e)), model%tw_u(:, e + 1), &
                                               model%tw_tn(:, e + 1))
    END DO
    ! a rigid end's element takes its end-frame constant in tw_beta: its formula at the
    ! committed state is tw_beta itself, so take the director angle of the gauge directly
    model%tw_psi = CD_ZERO
    model%tw_som = CD_ZERO
    model%tw_om = CD_ZERO
    model%tw_oal = CD_ZERO
    IF (tw_spring(model, 1)) model%tw_psi(1) = CD_HermiteTwist_Angle(model%tw_u(:, 1), &
                                                                     CD_HermiteTwist_Carry(ends(:, 1), &
                                                                                           model%tw_tn(:, 1), &
                                                                                           ends(:, 2)), &
                                                                     model%tw_tn(:, 1))
    ! angles from the uniform torque
    tol = STATE_TOL*MAX(CD_ONE, ABS(phi_end))
    model%tw_phi = CD_ZERO
    IF (tw_spring(model, 1)) model%tw_phi(1) = mt*model%torsion%end_compliance(1) + model%tw_psi(1)
    model%tors_use_step = .FALSE.
    DO e = 1, ne
      CALL twist_reference(model, e, model%q, ends, .FALSE., rho, beta, g, h, es, em2)
      IF (es /= CD_HCDYN_OK) THEN
        ErrStat = CD_HCDYN_BADINPUT
        ErrMsg = TRIM(em2)
        RETURN
      END IF
      model%tw_phi(e + 1) = model%tw_phi(e) + mt*model%l0(e)/model%torsion%gj(e) - rho
      IF (e == ne .AND. model%tw_rigid(2) .AND. model%torsion%end_free(1)) THEN
        ! a free end 1: the angles shift as one to the held Phi of end 2
        diff = model%tw_phi(nn) - phi_end
        model%tw_phi = model%tw_phi - diff
        model%tw_phi(nn) = phi_end
      ELSE IF (e == ne .AND. model%tw_rigid(2)) THEN
        diff = model%tw_phi(nn) - phi_end
        kk = ANINT(diff/(2.0_wp*CD_HTORS_PI))
        IF (ABS(diff - 2.0_wp*CD_HTORS_PI*kk) > tol) THEN
          ErrStat = CD_HCDYN_BADINPUT
          WRITE (ErrMsg, '(A,ES10.3,A)') 'twist: the static torsion state misses the End-2 twist by ', &
            ABS(diff - 2.0_wp*CD_HTORS_PI*kk), ' rad (solve the statics with torsion first)'
          RETURN
        END IF
        model%tw_beta(ne) = model%tw_beta(ne) + diff
        model%tw_phi(nn) = phi_end
      END IF
    END DO
    IF (tw_spring(model, 2)) THEN
      ! the End-2 spring: its psi at the committed state is the director angle itself, on the
      ! branch that puts the static end twist mt/k_2 on it (a free end 1: the angles shift as
      ! one to leave the spring slack, mt = 0)
      psi = CD_HermiteTwist_Angle(model%tw_u(:, nn), CD_HermiteTwist_Carry(ends(:, 3), model%tw_tn(:, nn), &
                                                                           ends(:, 4)), model%tw_tn(:, nn))
      IF (model%torsion%end_free(1)) model%tw_phi = model%tw_phi + (psi + phi_end - model%tw_phi(nn))
      diff = mt*model%torsion%end_compliance(2) - (psi + phi_end - model%tw_phi(nn))
      kk = ANINT(diff/(2.0_wp*CD_HTORS_PI))
      IF (ABS(diff - 2.0_wp*CD_HTORS_PI*kk) > tol) THEN
        ErrStat = CD_HCDYN_BADINPUT
        WRITE (ErrMsg, '(A,ES10.3,A)') 'twist: the static torsion state misses the End-2 spring twist by ', &
          ABS(diff - 2.0_wp*CD_HTORS_PI*kk), ' rad (solve the statics with torsion first)'
        RETURN
      END IF
      model%tw_psi(2) = psi + diff
    END IF
    model%tw_w = CD_ZERO
    model%tw_al = CD_ZERO
    model%tw_mt = mt
    model%tw_active = .TRUE.
  CONTAINS
    PURE FUNCTION unit_perp(x, ax) RESULT(y)
      REAL(wp), INTENT(IN) :: x(3), ax(3)
      REAL(wp) :: y(3)
      y = x - DOT_PRODUCT(x, ax)*ax
      y = y/NORM2(y)
    END FUNCTION unit_perp
  END SUBROUTINE tw_init

  SUBROUTINE tw_set_derived(model, tors)
    !! The rigid ends, held angles and lumped polar inertia (half of each adjacent element's
    !! Irn l0) the torsion description tors gives. A free end (tors%end_free) is neither rigid
    !! nor elastic: its angle is free and nothing twists it against its end frame.
    TYPE(CD_HermiteCableDynType), INTENT(INOUT) :: model
    TYPE(CD_HermiteTorsionType), INTENT(IN) :: tors
    INTEGER :: e
    model%tw_rigid = .NOT. (tors%end_compliance > CD_ZERO) .AND. .NOT. tors%end_free
    model%tw_free = .TRUE.
    IF (model%tw_rigid(1)) model%tw_free(1) = .FALSE.
    IF (model%tw_rigid(2)) model%tw_free(model%nn) = .FALSE.
    model%tw_mass = CD_ZERO
    DO e = 1, model%ne
      model%tw_mass(e) = model%tw_mass(e) + 0.5_wp*tors%irn(e)*model%l0(e)
      model%tw_mass(e + 1) = model%tw_mass(e + 1) + 0.5_wp*tors%irn(e)*model%l0(e)
    END DO
  END SUBROUTINE tw_set_derived

  PURE LOGICAL FUNCTION tw_spring(model, iend) RESULT(spring)
    !! End iend of the nodal twist is elastic: a torsional spring between its end node and its
    !! end frame (neither rigid, holding the angle, nor free, without restraint).
    TYPE(CD_HermiteCableDynType), INTENT(IN) :: model
    INTEGER, INTENT(IN) :: iend
    spring = .NOT. (model%tw_rigid(iend) .OR. model%torsion%end_free(iend))
  END FUNCTION tw_spring

  SUBROUTINE tw_settle_committed(model)
    !! After an evaluation of the committed state (solve_consistent_acceleration): the angles'
    !! accelerations staged in tw_ak, the element torques, and the condensed view Theta_eff =
    !! Phi - summed twist with its mean torque (Phi - Theta_eff)/C.
    TYPE(CD_HermiteCableDynType), INTENT(INOUT) :: model
    model%tw_al = model%tw_ak
    model%tw_mt = model%tw_me
    model%torsion%theta = model%torsion%phi - model%tw_tsum
    model%torsion%torque = model%tw_tsum/CD_HermiteTorsion_Compliance(model%torsion, model%l0)
  END SUBROUTINE tw_settle_committed

  SUBROUTINE tw_release(model)
    !! Deallocate the nodal-twist state and scratch.
    TYPE(CD_HermiteCableDynType), INTENT(INOUT) :: model
    model%tw_active = .FALSE.
    IF (ALLOCATED(model%tw_phi)) DEALLOCATE (model%tw_phi, model%tw_w, model%tw_al, model%tw_mass, model%tw_u, &
                                             model%tw_tn, model%tw_beta, model%tw_mt, model%tw_free)
    IF (ALLOCATED(model%tw_pn)) DEALLOCATE (model%tw_pn, model%tw_wn, model%tw_an, model%tw_pk, model%tw_wk, &
                                            model%tw_ak, model%tw_ptrial, model%tw_dp, model%tw_G, model%tw_Gt, &
                                            model%tw_Rk, model%tw_Rt, model%tw_R, model%tw_fcR, model%tw_pe, &
                                            model%tw_we)
    IF (ALLOCATED(model%tw_eg)) DEALLOCATE (model%tw_eg, model%tw_ehv, model%tw_ek, model%tw_ed, model%tw_me)
    IF (ALLOCATED(model%tw_K7)) DEALLOCATE (model%tw_K7, model%tw_x7, model%tw_ipiv)
    IF (ALLOCATED(model%tw_su)) DEALLOCATE (model%tw_su, model%tw_stn, model%tw_sbeta)
    IF (ALLOCATED(model%ws_recovery_tw)) DEALLOCATE (model%ws_recovery_tw)
    IF (ALLOCATED(model%snap_tw)) DEALLOCATE (model%snap_tw)
    IF (ALLOCATED(model%snap_tw_fcR)) DEALLOCATE (model%snap_tw_fcR)
  END SUBROUTINE tw_release

  SUBROUTINE tw_advance_reference(model, q_new, ends_new, ErrStat, ErrMsg)
    !! The twist reference at q_new with the frames ends_new, into the commit scratch: the
    !! reference twists and end-frame references (the step's own formulas, so the committed
    !! state reproduces the converged iterate bit for bit), the unit tangents and the directors
    !! carried over by the smallest rotation (a rigid end's: its end frame's normal carried).
    TYPE(CD_HermiteCableDynType), INTENT(INOUT) :: model
    REAL(wp), INTENT(IN) :: q_new(:), ends_new(3, 4)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    INTEGER :: e, i, iend
    REAL(wp) :: rho, beta, g(12), h(12, 12), psi, gl(3), hl(3, 3), u(3), t(3)
    ErrStat = CD_HCDYN_OK
    ErrMsg = ''
    DO e = 1, model%ne
      CALL twist_reference(model, e, q_new, ends_new, .FALSE., rho, beta, g, h, ErrStat, ErrMsg)
      IF (ErrStat /= CD_HCDYN_OK) RETURN
      model%tw_sbeta(e) = beta
    END DO
    model%tw_spsi = model%tw_psi
    DO iend = 1, 2
      IF (.NOT. tw_spring(model, iend)) CYCLE
      CALL twist_link(model, iend, q_new, ends_new, .FALSE., psi, gl, hl, ErrStat, ErrMsg)
      IF (ErrStat /= CD_HCDYN_OK) RETURN
      model%tw_spsi(iend) = psi
    END DO
    DO i = 1, model%nn
      t = q_new(6*i - 2:6*i)/NORM2(q_new(6*i - 2:6*i))
      model%tw_stn(:, i) = t
      IF (i == 1 .AND. model%tw_rigid(1)) THEN
        u = CD_HermiteTwist_Carry(ends_new(:, 1), t, ends_new(:, 2))
      ELSE IF (i == model%nn .AND. model%tw_rigid(2)) THEN
        u = CD_HermiteTwist_Carry(ends_new(:, 3), t, ends_new(:, 4))
      ELSE
        u = CD_HermiteTwist_Carry(model%tw_tn(:, i), t, model%tw_u(:, i))
      END IF
      u = u - DOT_PRODUCT(u, t)*t
      model%tw_su(:, i) = u/NORM2(u)
    END DO
  END SUBROUTINE tw_advance_reference

  SUBROUTINE tw_frame_rates(model, dt)
    !! tw_som: the angular velocity of each end frame from the committed frames to the step's,
    !! log(R_{n+1} R_n^T)/dt with R = [d n d x n] (spatial, as end_w of twist_reference).
    TYPE(CD_HermiteCableDynType), INTENT(INOUT) :: model
    REAL(wp), INTENT(IN) :: dt
    REAL(wp) :: r0(3, 3), r1(3, 3)
    INTEGER :: k
    model%tw_som = CD_ZERO
    IF (.NOT. dt > CD_ZERO) RETURN
    DO k = 1, 2
      IF (ALL(ABS(model%tors_step_ends(:, 2*k - 1:2*k) - model%torsion%ends(:, 2*k - 1:2*k)) <= CD_ZERO)) CYCLE
      r0(:, 1:2) = model%torsion%ends(:, 2*k - 1:2*k)
      r0(:, 3) = tw_cross(r0(:, 1), r0(:, 2))
      r1(:, 1:2) = model%tors_step_ends(:, 2*k - 1:2*k)
      r1(:, 3) = tw_cross(r1(:, 1), r1(:, 2))
      model%tw_som(:, k) = CD_Log_SO3(MATMUL(r1, TRANSPOSE(r0)))/dt
    END DO
  END SUBROUTINE tw_frame_rates

  SUBROUTINE tw_commit_reference(model)
    !! Make the reference state of tw_advance_reference the committed one.
    TYPE(CD_HermiteCableDynType), INTENT(INOUT) :: model
    model%tw_beta = model%tw_sbeta
    model%tw_psi = model%tw_spsi
    model%tw_tn = model%tw_stn
    model%tw_u = model%tw_su
  END SUBROUTINE tw_commit_reference

  SUBROUTINE add_endconn_band(R, Kb, q_cfg, node, k_rot, d0, want_residual, want_tangent, &
                              ErrStat, ErrMsg)
    !! Scatter one rotational end connection into the dynamic residual and band tangent.
    REAL(wp), INTENT(INOUT) :: R(:), Kb(:, :)
    REAL(wp), INTENT(IN) :: q_cfg(:), k_rot, d0(3)
    INTEGER, INTENT(IN) :: node
    LOGICAL, INTENT(IN) :: want_residual, want_tangent
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    REAL(wp) :: f_ec(3), k_ec(3, 3)
    INTEGER :: base, i, j, gi, gj
    ErrStat = CD_ENDCONN_OK
    ErrMsg = ''
    IF (k_rot <= CD_ZERO) RETURN
    base = 6*(node - 1) + 3                      ! tangent DOFs are base+1 .. base+3
    CALL CD_EndConn_Spring(q_cfg(base + 1:base + 3), d0, k_rot, f_ec, k_ec, ErrStat, ErrMsg)
    IF (ErrStat /= CD_ENDCONN_OK) RETURN
    IF (want_residual) R(base + 1:base + 3) = R(base + 1:base + 3) + f_ec
    IF (want_tangent) THEN
      DO j = 1, 3
        gj = base + j
        DO i = 1, 3
          gi = base + i
          Kb(KL_D + KU_D + 1 + gi - gj, gj) = Kb(KL_D + KU_D + 1 + gi - gj, gj) + k_ec(i, j)
        END DO
      END DO
    END IF
  END SUBROUTINE add_endconn_band

  SUBROUTINE assemble_contact(model, q_cfg, v_cfg, want_residual, want_tangent, R, n_lo, n_hi, ErrStat, ErrMsg)
    !! Assemble the nodal contact of nodes n_lo..n_hi into the residual R (assemble_residual's;
    !! the model's own residual is touched only through R) and the model-owned tangent bands.
    !! The Jacobians are d(f_int-f_ext)/dq and d(f_int-f_ext)/dv.
    TYPE(CD_HermiteCableDynType), INTENT(INOUT) :: model
    REAL(wp), INTENT(IN) :: q_cfg(:), v_cfg(:)
    LOGICAL, INTENT(IN) :: want_residual, want_tangent
    REAL(wp), INTENT(INOUT) :: R(:)
    INTEGER, INTENT(IN) :: n_lo, n_hi
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg

    INTEGER :: i, ix, iy, iz, es, jr, jc
    REAL(wp) :: xl, yl, xg, yg, z_floor, gxg, gyg, gx, gy
    REAL(wp) :: gap, normal, normal_gap, gate, gate_gap
    REAL(wp) :: dnormal_dgap, dnormal_dvz, dnormal_dq(3)
    ! Frictionless contact on a sloped floor acts along its upward normal nvec: normal
    ! penetration gap/sfac, normal velocity vn (sfac = 1 and nvec = e_z on a level floor).
    REAL(wp) :: sfac, nvec(3), vn, dnormal_dv(3)
    REAL(wp) :: d_fr(2), mu_c
    REAL(wp) :: ffr(2), dfr_dd(2, 2), dfr_dc(2)
    REAL(wp) :: curv_g(3), curv_l(3), fcrease(3), kcrease(3, 3)
    LOGICAL :: creased
    CHARACTER(200) :: em

    ErrStat = CD_HCDYN_OK; ErrMsg = ''
    IF (.NOT. model%has_contact .OR. .NOT. ALLOCATED(model%contact_kn) .OR. &
        .NOT. ALLOCATED(model%contact_cn)) THEN
      ErrStat = CD_HCDYN_BADINPUT; ErrMsg = 'contact configuration is incomplete'; RETURN
    END IF
    DO i = n_lo, n_hi
      ix = 6*i - 5; iy = ix + 1; iz = ix + 2
      gx = CD_ZERO; gy = CD_ZERO
      IF (model%has_contact_bathymetry) THEN
        xl = q_cfg(ix); yl = q_cfg(iy)
        xg = model%contact_frame_c*xl - model%contact_frame_s*yl
        yg = model%contact_frame_s*xl + model%contact_frame_c*yl
        CALL CD_Bathymetry_Floor_Gradient(model%contact_bathymetry, xg, yg, z_floor, gxg, gyg, es, em, &
                                          crease_curvature=curv_g)
        IF (es /= CD_BATHY_OK) THEN
          ErrStat = CD_HCDYN_NOCONVERGE; ErrMsg = 'bathymetry query failed: '//TRIM(em); RETURN
        END IF
        ! Chain the global floor gradient through the inverse local-to-global heading.
        gx = model%contact_frame_c*gxg + model%contact_frame_s*gyg
        gy = -model%contact_frame_s*gxg + model%contact_frame_c*gyg
        creased = ANY(ABS(curv_g) > CD_ZERO)
      ELSE
        z_floor = model%seabed_z
        creased = .FALSE.
      END IF
      ! In a rounded crease of the bathymetry the elastic force is the gradient of the
      ! penalty potential of the static solve (CD_Seabed_Normal_Contact with the curvature):
      ! its departure from the normal force F n, and its tangent, are added below.
      IF (creased) THEN
        curv_l = CD_Bathymetry_Rotate_Curvature(curv_g, [model%contact_frame_c, model%contact_frame_s])
        CALL crease_contact_increment(z_floor - q_cfg(iz), gx, gy, model%contact_kn(i), curv_l, fcrease, kcrease)
      END IF

      sfac = SQRT(CD_ONE + gx*gx + gy*gy)
      nvec = [-gx, -gy, CD_ONE]/sfac
      gap = (z_floor - q_cfg(iz))/sfac
      CALL CD_Seabed_Normal_Law(gap, model%contact_kn(i), normal, normal_gap)
      CALL CD_Seabed_Contact_Gate(gap, gate, gate_gap)
      IF (normal <= CD_ZERO .AND. gate <= CD_ZERO) CYCLE
      vn = DOT_PRODUCT(v_cfg(ix:iz), nvec)
      dnormal_dgap = normal_gap
      dnormal_dvz = CD_ZERO
      IF (vn < CD_ZERO) THEN
        normal = normal - model%contact_cn(i)*gate*vn
        dnormal_dgap = dnormal_dgap - model%contact_cn(i)*gate_gap*vn
        dnormal_dvz = -model%contact_cn(i)*gate
      END IF
      ! d(gap/sfac)/dq = (gx, gy, -1)/sfac = -nvec (floor gradient held over the node)
      dnormal_dq = -dnormal_dgap*nvec
      dnormal_dv = dnormal_dvz*nvec

      IF (want_residual) R(ix:iz) = R(ix:iz) - normal*nvec
      IF (want_tangent) THEN
        DO jc = 1, 3
          DO jr = 1, 3
            CALL scatter_contact_band(model%ws_Kb, ix + jr - 1, ix + jc - 1, -nvec(jr)*dnormal_dq(jc))
            CALL scatter_contact_band(model%ws_Kvb, ix + jr - 1, ix + jc - 1, -nvec(jr)*dnormal_dv(jc))
          END DO
        END DO
      END IF
      IF (creased) THEN
        IF (want_residual) R(ix:iz) = R(ix:iz) - fcrease
        IF (want_tangent) THEN
          DO jc = 1, 3
            DO jr = 1, 3
              CALL scatter_contact_band(model%ws_Kb, ix + jr - 1, ix + jc - 1, kcrease(jr, jc))
            END DO
          END DO
        END IF
      END IF

      IF (.NOT. model%fr_active) CYCLE
      ! Stick-slip friction spring to the committed anchor (CD_Seabed_Friction_Stick_Slip):
      ! capacity mu*normal; its dependence on the normal force enters the tangent.
      d_fr(1) = q_cfg(ix) - model%fr_anchor(1, i)
      d_fr(2) = q_cfg(iy) - model%fr_anchor(2, i)
      IF (model%contact_fr_aniso) THEN
        ! dfr_dc is then d(force)/d(normal): the capacity chain factor is one
        CALL CD_Seabed_Friction_Aniso(CD_FRICTION_STICK_SLIP, d_fr, model%fr_k(i), normal, &
                                      model%contact_mu_axial, model%contact_mu, q_cfg(ix + 3:ix + 4), &
                                      ffr, dfr_dd, dfr_dc)
        mu_c = CD_ONE
      ELSE
        CALL CD_Seabed_Friction_Stick_Slip(d_fr, model%fr_k(i), &
                                           model%contact_mu*normal, ffr, dfr_dd, dfr_dc)
        mu_c = model%contact_mu
      END IF
      IF (want_residual) R(ix:iy) = R(ix:iy) + ffr
      IF (want_tangent) THEN
        DO jr = 1, 2
          CALL scatter_contact_band(model%ws_Kb, ix + jr - 1, ix, dfr_dd(jr, 1) + &
                                    mu_c*dfr_dc(jr)*dnormal_dq(1))
          CALL scatter_contact_band(model%ws_Kb, ix + jr - 1, iy, dfr_dd(jr, 2) + &
                                    mu_c*dfr_dc(jr)*dnormal_dq(2))
          CALL scatter_contact_band(model%ws_Kb, ix + jr - 1, iz, mu_c*dfr_dc(jr)*dnormal_dq(3))
          DO jc = 1, 3
            CALL scatter_contact_band(model%ws_Kvb, ix + jr - 1, ix + jc - 1, mu_c*dfr_dc(jr)*dnormal_dv(jc))
          END DO
        END DO
      END IF
    END DO
  END SUBROUTINE assemble_contact

  PURE SUBROUTINE crease_contact_increment(gap_v, gx, gy, kn, curv, fdelta, kdelta)
    !! Elastic contact force and residual tangent of a node in a rounded bathymetry crease
    !! (CD_Seabed_Normal_Contact with the surface curvature) less those of the normal
    !! force F n at the same point: the increment added to the normal-force assembly.
    REAL(wp), INTENT(IN) :: gap_v, gx, gy, kn, curv(3)
    REAL(wp), INTENT(OUT) :: fdelta(3), kdelta(3, 3)
    REAL(wp) :: fp(3), kp(3, 3)
    CALL CD_Seabed_Normal_Contact(gap_v, gx, gy, kn, fdelta, kdelta, curvature=curv)
    CALL CD_Seabed_Normal_Contact(gap_v, gx, gy, kn, fp, kp)
    fdelta = fdelta - fp
    kdelta = kdelta - kp
  END SUBROUTINE crease_contact_increment

  LOGICAL FUNCTION held_end_floor_support(model, q_cfg, iend, support, dsupport, inode, nin) RESULT(held)
    !! Floor reaction carrying the weight of the end element at line end iend (1: node 1,
    !! 2: node nn) of a model with seabed contact, per unit weight: the floor's normal share
    !! cos(slope) n of the weight (n the upward floor normal at the end, e_z on a flat bed)
    !! times the share of the element lying on the floor. Its consistent end moment cancels
    !! the weight's on a grounded end element; the along-floor part of the weight stays with
    !! the line. The share is CD_Seabed_End_Support of the end node (on or below the floor)
    !! times CD_Seabed_End_Element_Share of the element's inner node inode (the normal force
    !! of its elastic contact law against half the element's weight): zero for an element
    !! rising from an anchor on the floor, one for a laid element, smooth in between.
    !! dsupport is d(support)/d(gap) of the inner node, whose gap gradient is -nin (nin its
    !! floor normal). False (support zero) unless the end node's translations are all held
    !! (not free), its end element is net-heavy and the share is positive.
    TYPE(CD_HermiteCableDynType), INTENT(IN) :: model
    REAL(wp), INTENT(IN) :: q_cfg(:)
    INTEGER, INTENT(IN) :: iend
    REAL(wp), INTENT(OUT) :: support(3), dsupport(3), nin(3)
    INTEGER, INTENT(OUT) :: inode
    INTEGER :: node, e, ix, es
    REAL(wp) :: gap, sfac, share, nvec(3), sfac_in, gap_in, normal, normal_gap, elem, delem
    CHARACTER(200) :: em
    support = CD_ZERO
    dsupport = CD_ZERO
    nin = [CD_ZERO, CD_ZERO, CD_ONE]
    held = .FALSE.
    IF (iend == 1) THEN
      node = 1; e = 1; inode = 2
    ELSE
      node = model%nn; e = model%ne; inode = model%nn - 1
    END IF
    IF (.NOT. (model%w(e) > CD_ZERO)) RETURN
    ix = 6*node - 5
    IF (ANY(model%freemask(ix:ix + 2))) RETURN
    CALL floor_gap(node, gap, nvec, sfac, es)
    IF (es /= CD_BATHY_OK) RETURN
    share = CD_Seabed_End_Support(gap)
    IF (.NOT. (share > CD_ZERO)) RETURN
    CALL floor_gap(inode, gap_in, nin, sfac_in, es)
    IF (es /= CD_BATHY_OK) RETURN
    IF (model%has_contact) THEN
      CALL CD_Seabed_Normal_Law(gap_in, model%contact_kn(inode), normal, normal_gap)
    ELSE IF (gap_in > CD_ZERO) THEN
      normal = model%kn*model%trib(inode)*gap_in
      normal_gap = model%kn*model%trib(inode)
    ELSE
      normal = CD_ZERO
      normal_gap = CD_ZERO
    END IF
    CALL CD_Seabed_End_Element_Share(normal, normal_gap, 0.5_wp*model%w(e)*model%l0(e), elem, delem)
    IF (.NOT. (elem > CD_ZERO)) RETURN
    held = .TRUE.
    support = (share*elem/sfac)*nvec
    dsupport = (share*delem/sfac)*nvec

  CONTAINS

    SUBROUTINE floor_gap(k, gap_k, n_k, sfac_k, es_k)
      !! Normal penetration gap_k, upward floor normal n_k and slope factor of node k, on the
      !! floor the contact assembly uses (structured bathymetry or the flat seabed plane). A
      !! failed bathymetry query (es_k) fails closed in the contact assembly at the same point.
      INTEGER, INTENT(IN) :: k
      REAL(wp), INTENT(OUT) :: gap_k, n_k(3), sfac_k
      INTEGER, INTENT(OUT) :: es_k
      REAL(wp) :: xg, yg, z_floor, gxg, gyg, gx, gy
      INTEGER :: kx
      kx = 6*k - 5
      es_k = CD_BATHY_OK
      gx = CD_ZERO
      gy = CD_ZERO
      z_floor = model%seabed_z
      IF (model%has_contact .AND. model%has_contact_bathymetry) THEN
        xg = model%contact_frame_c*q_cfg(kx) - model%contact_frame_s*q_cfg(kx + 1)
        yg = model%contact_frame_s*q_cfg(kx) + model%contact_frame_c*q_cfg(kx + 1)
        CALL CD_Bathymetry_Floor_Gradient(model%contact_bathymetry, xg, yg, z_floor, gxg, gyg, es_k, em)
        IF (es_k /= CD_BATHY_OK) RETURN
        gx = model%contact_frame_c*gxg + model%contact_frame_s*gyg
        gy = -model%contact_frame_s*gxg + model%contact_frame_c*gyg
      END IF
      sfac_k = SQRT(CD_ONE + gx*gx + gy*gy)
      n_k = [-gx, -gy, CD_ONE]/sfac_k
      gap_k = (z_floor - q_cfg(kx + 2))/sfac_k
    END SUBROUTINE floor_gap
  END FUNCTION held_end_floor_support

  SUBROUTINE commit_friction_anchors(model)
    !! Return mapping of the elastic-plastic friction springs at the committed state: a
    !! spring stretched beyond the capacity mu*normal moves its anchor to the capacity
    !! distance behind the node (a node off the seabed, capacity zero, carries its anchor
    !! with it), so the committed force is exactly the one of the converged residual.
    TYPE(CD_HermiteCableDynType), INTENT(INOUT) :: model
    INTEGER :: i, ix, iz, es
    REAL(wp) :: xl, yl, xg, yg, z_floor, gxg, gyg, gap, normal, normal_gap, gate, gate_gap
    REAL(wp) :: dxy(2), dlen, cap, mu_d, q_d, gq_d(2), gx, gy, sfac, nvec(3), vn
    CHARACTER(200) :: em
    DO i = 1, model%nn
      ix = 6*i - 5; iz = ix + 2
      gx = CD_ZERO
      gy = CD_ZERO
      IF (model%has_contact_bathymetry) THEN
        xl = model%q(ix); yl = model%q(ix + 1)
        xg = model%contact_frame_c*xl - model%contact_frame_s*yl
        yg = model%contact_frame_s*xl + model%contact_frame_c*yl
        CALL CD_Bathymetry_Floor_Gradient(model%contact_bathymetry, xg, yg, z_floor, gxg, gyg, es, em)
        IF (es /= CD_BATHY_OK) THEN
          ! Not reached in practice: the converged step's contact assembly queried this
          ! committed position and fails closed on the same error.
          z_floor = model%seabed_z
        ELSE
          gx = model%contact_frame_c*gxg + model%contact_frame_s*gyg
          gy = -model%contact_frame_s*gxg + model%contact_frame_c*gyg
        END IF
      ELSE
        z_floor = model%seabed_z
      END IF
      ! the normal force of assemble_contact (along the floor normal)
      sfac = SQRT(CD_ONE + gx*gx + gy*gy)
      nvec = [-gx, -gy, CD_ONE]/sfac
      gap = (z_floor - model%q(iz))/sfac
      CALL CD_Seabed_Normal_Law(gap, model%contact_kn(i), normal, normal_gap)
      CALL CD_Seabed_Contact_Gate(gap, gate, gate_gap)
      vn = DOT_PRODUCT(model%v(ix:iz), nvec)
      IF (vn < CD_ZERO) normal = normal - model%contact_cn(i)*gate*vn
      dxy = model%q(ix:ix + 1) - model%fr_anchor(:, i)
      IF (model%contact_fr_aniso) THEN
        CALL CD_Seabed_Friction_Mu_Dir(dxy, model%contact_mu_axial, model%contact_mu, model%q(ix + 3:ix + 4), &
                                       mu_d, q_d, gq_d)
        cap = mu_d*MAX(normal, CD_ZERO)
      ELSE
        cap = model%contact_mu*MAX(normal, CD_ZERO)
      END IF
      dlen = SQRT(dxy(1)*dxy(1) + dxy(2)*dxy(2))
      IF (model%fr_k(i)*dlen > cap) THEN
        model%fr_anchor(:, i) = model%q(ix:ix + 1) - (cap/(model%fr_k(i)*dlen))*dxy
      END IF
    END DO
  END SUBROUTINE commit_friction_anchors

  SUBROUTINE scatter_contact_band(ab, row_dof, col_dof, value)
    REAL(wp), INTENT(INOUT) :: ab(:, :)
    INTEGER, INTENT(IN) :: row_dof, col_dof
    REAL(wp), INTENT(IN) :: value
    INTEGER :: brow
    brow = KL_D + KU_D + 1 + row_dof - col_dof
    IF (brow >= 1 .AND. brow <= SIZE(ab, 1)) ab(brow, col_dof) = ab(brow, col_dof) + value
  END SUBROUTINE scatter_contact_band

  SUBROUTINE evaluate_tangent_element(model, e, q_cfg, v_cfg, t_eval, Kstruct, Kdrag, Kvel, Kwave, Kheld, &
                                      ErrStat, ErrMsg, forces)
    !! Evaluate the complete element-local Newton package. Keeping structural, drag and
    !! fluid-inertia tangents in one worker avoids three OpenMP regions per iteration;
    !! the caller scatters these private blocks in deterministic element order.
    !! forces (optional) also returns the element load of each kernel from the same call:
    !! forces(:, k) for k = 1 structure (f_int), 2 axial damping, 3 drag, 4 VIV lift, 5 wave and
    !! 6 held Froude-Krylov (the loads as the kernels return them, before the residual's signs).
    !! Every kernel forms its load by the same statements with or without its tangent, so these
    !! are bit-for-bit the loads of a residual-only evaluation. The columns of the kernels the
    !! model does not configure are not defined.
    TYPE(CD_HermiteCableDynType), INTENT(IN) :: model
    INTEGER, INTENT(IN) :: e
    REAL(wp), INTENT(IN) :: q_cfg(:), v_cfg(:), t_eval
    REAL(wp), INTENT(OUT) :: Kstruct(12, 12), Kdrag(12, 12), Kvel(12, 12)
    REAL(wp), INTENT(OUT) :: Kwave(12, 12), Kheld(12, 12)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    REAL(wp), INTENT(OUT), OPTIONAL :: forces(12, 6)

    REAL(wp) :: qe(12), ve(12), energy, force(12), fload(12)
    REAL(wp) :: djq(12, 12), djv(12, 12), fjq(12, 12)
    REAL(wp) :: hf_mid(3)
    INTEGER :: es
    ! The element kernels write fixed messages of at most 184 characters (nested ones included),
    ! which fit em and the per-element buffer ws_elem_em this fills. Each kernel resets em at every
    ! call, so em stays short; ErrMsg is written only on a failure (the caller reads it only then).
    CHARACTER(200) :: em

    ErrStat = CD_HCDYN_OK
    qe(1:6) = q_cfg(6*(e - 1) + 1:6*e)
    qe(7:12) = q_cfg(6*e + 1:6*(e + 1))
    ve(1:6) = v_cfg(6*(e - 1) + 1:6*e)
    ve(7:12) = v_cfg(6*e + 1:6*(e + 1))
    ! Kdrag and Kvel accumulate their contributors from zero. Kwave and Kheld are each set
    ! whole by their one contributor below and read (scattered) only when it is configured,
    ! so they are not cleared.
    Kdrag = CD_ZERO; Kvel = CD_ZERO

    IF (PRESENT(forces)) THEN
      CALL CD_HermiteCable_Element(qe, model%l0(e), model%EA(e), model%EI(e), energy, forces(:, 1), Kstruct, &
                                   es, em, symmetric_half=.TRUE., &
                                   axial_quadrature_order=model%axial_quadrature_order, &
                                   bending_quadrature_order=model%bending_quadrature_order)
    ELSE
      CALL CD_HermiteCable_Element(qe, model%l0(e), model%EA(e), model%EI(e), energy, force, Kstruct, es, em, &
                                   symmetric_half=.TRUE., tangent_only=.TRUE., &
                                   axial_quadrature_order=model%axial_quadrature_order, &
                                   bending_quadrature_order=model%bending_quadrature_order)
    END IF
    IF (es /= CD_HCABLE_OK) THEN
      ErrStat = CD_HCDYN_NOCONVERGE; ErrMsg = 'element: '//TRIM(em); RETURN
    END IF

    IF (model%has_axial_damping) THEN
      IF (model%has_ctrl) THEN
        CALL CD_HermiteCable_Axial_Damping_Element(qe, ve, model%l0(e), model%BA(e), &
                                                   fload, djq, djv, es, em, &
                                                   model%axial_quadrature_order, model%l0_dot(e))
      ELSE
        CALL CD_HermiteCable_Axial_Damping_Element(qe, ve, model%l0(e), model%BA(e), &
                                                   fload, djq, djv, es, em, &
                                                   model%axial_quadrature_order)
      END IF
      IF (es /= CD_HCDYN_OK) THEN
        ErrStat = CD_HCDYN_NOCONVERGE; ErrMsg = TRIM(em); RETURN
      END IF
      IF (PRESENT(forces)) forces(:, 2) = fload
      Kdrag = Kdrag + djq
      Kvel = Kvel + djv
    END IF

    IF (model%has_drag) THEN
      IF (model%has_wave .AND. model%wv_ncomp > 0) THEN
        CALL CD_HermiteCable_Drag_Element(qe, ve, model%l0(e), model%current, model%waterline_z, &
                                          model%rho_w, model%diam(e), model%cdn(e), model%cdt(e), &
                                          fload, djq, djv, es, em, wv_depth=model%wv_depth, &
                                          wv_dir=model%wv_dir, wv_t=t_eval, wvc_amp=model%wv_ampc, &
                                          wvc_om=model%wv_omc, wvc_k=model%wv_kc, wvc_ph=model%wv_phc, &
                                          wvc_e2kd=model%wv_e2kd)
      ELSE IF (model%has_wave) THEN
        CALL CD_HermiteCable_Drag_Element(qe, ve, model%l0(e), model%current, model%waterline_z, &
                                          model%rho_w, model%diam(e), model%cdn(e), model%cdt(e), &
                                          fload, djq, djv, es, em, wv_h=model%wv_h, wv_om=model%wv_om, &
                                          wv_k=model%wv_k, wv_depth=model%wv_depth, wv_dir=model%wv_dir, &
                                          wv_t=t_eval)
      ELSE IF (model%has_held_field) THEN
        CALL CD_HermiteCable_Drag_Element(qe, ve, model%l0(e), &
                                          model%current + 0.5_wp*(model%hf_u(:, e) + model%hf_u(:, e + 1)), &
                                          0.5_wp*(model%hf_wl(e) + model%hf_wl(e + 1)), model%rho_w, &
                                          model%diam(e), model%cdn(e), model%cdt(e), fload, djq, djv, es, em)
      ELSE
        CALL CD_HermiteCable_Drag_Element(qe, ve, model%l0(e), model%current, model%waterline_z, &
                                          model%rho_w, model%diam(e), model%cdn(e), model%cdt(e), &
                                          fload, djq, djv, es, em)
      END IF
      IF (es /= CD_HCDYN_OK) THEN
        ErrStat = es; ErrMsg = TRIM(em); RETURN
      END IF
      IF (PRESENT(forces)) forces(:, 3) = fload
      Kdrag = Kdrag - djq
      Kvel = Kvel - djv
    END IF

    IF (model%has_viv) THEN
      CALL viv_element_lift(model, q_cfg, v_cfg, e, fload, es, em, djq, djv)
      IF (es /= CD_HCDYN_OK) THEN
        ErrStat = es; ErrMsg = TRIM(em); RETURN
      END IF
      IF (PRESENT(forces)) forces(:, 4) = fload
      Kdrag = Kdrag - djq
      Kvel = Kvel - djv
    END IF

    IF (model%has_wave .AND. model%has_am) THEN
      IF (model%wv_ncomp > 0) THEN
        CALL CD_HermiteCable_FK_Element(qe, model%l0(e), model%am_wl, model%am_rho, model%am_diam(e), &
                                        model%am_can(e), model%am_cat(e), wv_depth=model%wv_depth, &
                                        wv_dir=model%wv_dir, wv_t=t_eval, ffk=fload, fjq=fjq, &
                                        ErrStat=es, ErrMsg=em, wvc_amp=model%wv_ampc, wvc_om=model%wv_omc, &
                                        wvc_k=model%wv_kc, wvc_ph=model%wv_phc, &
                                        wvc_e2kd=model%wv_e2kd)
      ELSE
        CALL CD_HermiteCable_FK_Element(qe, model%l0(e), model%am_wl, model%am_rho, model%am_diam(e), &
                                        model%am_can(e), model%am_cat(e), wv_h=model%wv_h, &
                                        wv_om=model%wv_om, wv_k=model%wv_k, wv_depth=model%wv_depth, &
                                        wv_dir=model%wv_dir, wv_t=t_eval, ffk=fload, fjq=fjq, &
                                        ErrStat=es, ErrMsg=em)
      END IF
      IF (es /= CD_HCDYN_OK) THEN
        ErrStat = es; ErrMsg = TRIM(em); RETURN
      END IF
      IF (PRESENT(forces)) forces(:, 5) = fload
      Kwave = -fjq
    END IF

    IF (model%has_held_field .AND. model%has_am) THEN
      hf_mid(1) = 0.5_wp*(model%hf_ud(1, e) + model%hf_ud(1, e + 1))
      hf_mid(2) = 0.5_wp*(model%hf_ud(2, e) + model%hf_ud(2, e + 1))
      hf_mid(3) = 0.5_wp*(model%hf_ud(3, e) + model%hf_ud(3, e + 1))
      CALL CD_HermiteCable_FK_Element(qe, model%l0(e), 0.5_wp*(model%hf_wl(e) + model%hf_wl(e + 1)), &
                                      model%am_rho, model%am_diam(e), model%am_can(e), model%am_cat(e), &
                                      wv_depth=CD_ZERO, wv_dir=CD_ZERO, wv_t=CD_ZERO, ffk=fload, fjq=fjq, &
                                      ErrStat=es, ErrMsg=em, &
                                      hf_a=hf_mid)
      IF (es /= CD_HCDYN_OK) THEN
        ErrStat = es; ErrMsg = TRIM(em); RETURN
      END IF
      IF (PRESENT(forces)) forces(:, 6) = fload
      Kheld = -fjq
    END IF
  END SUBROUTINE evaluate_tangent_element

  SUBROUTINE CD_HermiteCable_Axial_Damping_Resultant(qe, ve, l0, BA, xi, resultant, ErrStat, ErrMsg, l0_dot)
    !! Signed viscous axial resultant N_v = BA*strain_rate at one material point.
    !! This is the damping share added to the elastic resultant for tension outputs.
    !! l0_dot: the unstretched-length rate of a controlled element (see the element routine).
    REAL(wp), INTENT(IN) :: qe(12), ve(12), l0, BA, xi
    REAL(wp), INTENT(OUT) :: resultant
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    REAL(wp), INTENT(IN), OPTIONAL :: l0_dot
    REAL(wp) :: H(4), dH(4), r_xi(3), v_xi(3), speed
    INTEGER :: s

    ErrStat = CD_HCDYN_OK
    ErrMsg = ''
    resultant = CD_ZERO
    IF (.NOT. CD_Is_Finite(l0) .OR. l0 <= CD_ZERO .OR. &
        .NOT. CD_Is_Finite(BA) .OR. BA < CD_ZERO .OR. &
        .NOT. CD_Is_Finite(xi) .OR. xi < CD_ZERO .OR. xi > CD_ONE) THEN
      CALL fail('need finite l0 > 0, BA >= 0, and xi in [0,1]'); RETURN
    END IF
    IF (.NOT. CD_All_Finite(qe) .OR. .NOT. CD_All_Finite(ve)) THEN
      CALL fail('qe and ve must be finite'); RETURN
    END IF
    IF (PRESENT(l0_dot)) THEN
      IF (.NOT. CD_Is_Finite(l0_dot)) THEN
        CALL fail('l0_dot must be finite'); RETURN
      END IF
    END IF
    IF (.NOT. (BA > CD_ZERO)) RETURN
    CALL CD_HermiteCable_Shapes(xi, l0, H, dH)
    r_xi = CD_ZERO
    v_xi = CD_ZERO
    DO s = 1, 4
      r_xi = r_xi + dH(s)*qe(3*(s - 1) + 1:3*s)
      v_xi = v_xi + dH(s)*ve(3*(s - 1) + 1:3*s)
    END DO
    speed = SQRT(SUM(r_xi*r_xi))
    IF (.NOT. CD_Is_Finite(speed) .OR. speed <= 1.0e-12_wp*MAX(CD_ONE, l0)) THEN
      CALL fail('collapsed or non-finite element tangent'); RETURN
    END IF
    IF (PRESENT(l0_dot)) v_xi = v_xi - (l0_dot/l0)*(dH(1)*qe(1:3) + dH(3)*qe(7:9))
    resultant = BA*DOT_PRODUCT(r_xi/speed, v_xi)/l0
    IF (.NOT. CD_Is_Finite(resultant)) CALL fail('non-finite damping resultant')

  CONTAINS
    SUBROUTINE fail(msg)
      CHARACTER(*), INTENT(IN) :: msg
      ErrStat = CD_HCDYN_BADINPUT
      ErrMsg = 'CD_HermiteCable_Axial_Damping_Resultant: '//msg
      resultant = CD_ZERO
    END SUBROUTINE fail
  END SUBROUTINE CD_HermiteCable_Axial_Damping_Resultant

  SUBROUTINE CD_HermiteCable_Axial_Damping_Element(qe, ve, l0, BA, fdamp, Kq, Kv, ErrStat, ErrMsg, &
                                                   quadrature_order, l0_dot)
    !! Consistent axial Kelvin-Voigt contribution for one cubic-Hermite element.
    !! The material coordinate is reference arc length s0 = l0*xi. With
    !! r_xi = dr/dxi, t = r_xi/|r_xi| and v_xi = dv/dxi,
    !!
    !!   strain_rate = t dot v_xi / l0,
    !!   fdamp_a     = integral BA*strain_rate*dH_a*t dxi.
    !!
    !! fdamp is an INTERNAL generalized force, so v dot fdamp is non-negative.
    !! Kq = d(fdamp)/dq and Kv = d(fdamp)/dv are exact analytical Jacobians.
    !!
    !! l0_dot (optional): the unstretched-length rate of an element under active line
    !! control. The strain |r_xi|/l0 - 1 then also changes with l0: the material-tangent
    !! terms of r_xi carry the factor l0 and cancel, so only the end-position part
    !! p = dH_1 r_1 + dH_3 r_2 contributes, and the strain rate becomes
    !!
    !!   strain_rate = t dot (v_xi - (l0_dot/l0) p) / l0,
    !!
    !! the rate of the strain the elastic resultant uses, so a segment paid out at constant
    !! strain carries no damping force (the MoorDyn-F convention ldot - (l/L0) L0dot of the
    !! EI = 0 lines, taken pointwise). Kq gains -BA dH_a dH_b (l0_dot/l0**2) t t^T on the
    !! end-position columns b, and the transverse part of v_xi becomes that of the same
    !! combination; Kv is unchanged.
    REAL(wp), INTENT(IN) :: qe(12), ve(12), l0, BA
    REAL(wp), INTENT(OUT) :: fdamp(12)
    REAL(wp), INTENT(OUT), OPTIONAL :: Kq(12, 12), Kv(12, 12)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    INTEGER, INTENT(IN), OPTIONAL :: quadrature_order
    REAL(wp), INTENT(IN), OPTIONAL :: l0_dot

    REAL(wp) :: gp(6), gw(6), H(4), dH(4)
    REAL(wp) :: r_xi(3), v_xi(3), tangent(3), pperp(3), projector(3, 3), kq3(3, 3)
    REAL(wp) :: speed, strain_rate, scale_q, scale_v, scale_r, rate_ratio
    INTEGER :: order, ig, s, sp, c, cp, ia, ib

    ErrStat = CD_HCDYN_OK
    ErrMsg = ''
    fdamp = CD_ZERO
    IF (PRESENT(Kq)) Kq = CD_ZERO
    IF (PRESENT(Kv)) Kv = CD_ZERO
    order = 4
    IF (PRESENT(quadrature_order)) order = quadrature_order
    IF (.NOT. CD_Is_Finite(l0) .OR. l0 <= CD_ZERO .OR. &
        .NOT. CD_Is_Finite(BA) .OR. BA < CD_ZERO) THEN
      CALL fail('need finite l0 > 0 and BA >= 0'); RETURN
    END IF
    IF (.NOT. CD_All_Finite(qe) .OR. .NOT. CD_All_Finite(ve)) THEN
      CALL fail('qe and ve must be finite'); RETURN
    END IF
    IF (order < 1 .OR. order > 6) THEN
      CALL fail('quadrature_order must lie in [1,6]'); RETURN
    END IF
    rate_ratio = CD_ZERO
    IF (PRESENT(l0_dot)) THEN
      IF (.NOT. CD_Is_Finite(l0_dot)) THEN
        CALL fail('l0_dot must be finite'); RETURN
      END IF
      rate_ratio = l0_dot/l0
    END IF
    IF (.NOT. (BA > CD_ZERO)) RETURN

    CALL CD_HermiteCable_Gauss_Rule(order, gp, gw)
    DO ig = 1, order
      CALL CD_HermiteCable_Shapes(gp(ig), l0, H, dH)
      r_xi = CD_ZERO
      v_xi = CD_ZERO
      DO s = 1, 4
        r_xi = r_xi + dH(s)*qe(3*(s - 1) + 1:3*s)
        v_xi = v_xi + dH(s)*ve(3*(s - 1) + 1:3*s)
      END DO
      speed = SQRT(SUM(r_xi*r_xi))
      IF (.NOT. CD_Is_Finite(speed) .OR. speed <= 1.0e-12_wp*MAX(CD_ONE, l0)) THEN
        CALL fail('collapsed or non-finite element tangent at a quadrature point'); RETURN
      END IF
      tangent = r_xi/speed
      ! controlled element: the rate of the end-position part of r_xi at fixed q
      IF (PRESENT(l0_dot)) v_xi = v_xi - rate_ratio*(dH(1)*qe(1:3) + dH(3)*qe(7:9))
      strain_rate = DOT_PRODUCT(tangent, v_xi)/l0
      projector = CD_ZERO
      DO c = 1, 3
        projector(c, c) = CD_ONE
      END DO
      DO c = 1, 3
        DO cp = 1, 3
          projector(c, cp) = projector(c, cp) - tangent(c)*tangent(cp)
        END DO
      END DO
      pperp = MATMUL(projector, v_xi)
      ! the 3 x 3 factor of the position Jacobian, formed once per Gauss point
      DO cp = 1, 3
        DO c = 1, 3
          kq3(c, cp) = strain_rate*projector(c, cp) + tangent(c)*pperp(cp)/l0
        END DO
      END DO

      DO s = 1, 4
        DO c = 1, 3
          ia = 3*(s - 1) + c
          fdamp(ia) = fdamp(ia) + gw(ig)*BA*strain_rate*dH(s)*tangent(c)
        END DO
      END DO
      DO sp = 1, 4
        DO s = 1, 4
          scale_v = gw(ig)*BA*dH(s)*dH(sp)/l0
          scale_q = gw(ig)*BA*dH(s)*dH(sp)/speed
          scale_r = gw(ig)*BA*dH(s)*dH(sp)*(rate_ratio/l0)
          DO cp = 1, 3
            ib = 3*(sp - 1) + cp
            DO c = 1, 3
              ia = 3*(s - 1) + c
              IF (PRESENT(Kv)) Kv(ia, ib) = Kv(ia, ib) + scale_v*tangent(c)*tangent(cp)
              IF (PRESENT(Kq)) THEN
                Kq(ia, ib) = Kq(ia, ib) + scale_q*kq3(c, cp)
                ! the length-rate term depends on the end positions (sp = 1, 3) only
                IF (PRESENT(l0_dot) .AND. MOD(sp, 2) == 1) &
                  Kq(ia, ib) = Kq(ia, ib) - scale_r*tangent(c)*tangent(cp)
              END IF
            END DO
          END DO
        END DO
      END DO
    END DO

    IF (.NOT. CD_All_Finite(fdamp)) THEN
      CALL fail('non-finite damping force or Jacobian')
      RETURN
    END IF
    IF (PRESENT(Kq)) THEN
      IF (.NOT. CD_All_Finite(Kq)) THEN
        CALL fail('non-finite damping force or Jacobian'); RETURN
      END IF
    END IF
    IF (PRESENT(Kv)) THEN
      IF (.NOT. CD_All_Finite(Kv)) THEN
        CALL fail('non-finite damping force or Jacobian'); RETURN
      END IF
    END IF

  CONTAINS
    SUBROUTINE fail(msg)
      CHARACTER(*), INTENT(IN) :: msg
      ErrStat = CD_HCDYN_BADINPUT
      ErrMsg = 'CD_HermiteCable_Axial_Damping_Element: '//msg
      fdamp = CD_ZERO
      IF (PRESENT(Kq)) Kq = CD_ZERO
      IF (PRESENT(Kv)) Kv = CD_ZERO
    END SUBROUTINE fail
  END SUBROUTINE CD_HermiteCable_Axial_Damping_Element

  SUBROUTINE CD_HermiteCable_Drag_Element(qe, ve, l0, fluid, waterline_z, rho, diam, cdn, cdt, &
                                          fdrag, djq, djv, ErrStat, ErrMsg, &
                                          wv_h, wv_om, wv_k, wv_depth, wv_dir, wv_t, &
                                          wvc_amp, wvc_om, wvc_k, wvc_ph, wvc_e2kd)
    !! Consistent Gauss-integrated Morison quadratic drag on one cubic-Hermite bending-cable element.
    !! qe(12), ve(12) = [r1, m1, r2, m2] nodal positions and velocities; the interior velocity and
    !! tangent use the SAME cubic-Hermite interpolation as the geometry, so the material-tangent (m)
    !! DOFs -- which move the element interior while the endpoints may be fixed -- also carry drag.
    !! Outputs the 12-DOF generalized drag LOAD fdrag = integral N^T f_perlen ds (f_ext on the cable)
    !! and its force Jacobians djq = d fdrag/d qe, djv = d fdrag/d ve. The per-length drag and its
    !! rel-velocity / tangent Jacobians come from the analytical Morison primitive, so djq/djv are
    !! exact (FD-verified) and vanish smoothly at zero relative velocity (fixed-point safe).
    !!
    !! Submergence is evaluated per Gauss point (a point with r_z above waterline_z contributes no
    !! drag). For a FULLY submerged element -- the production regime for a lazy-wave power cable or a
    !! mooring, which hangs entirely below the free surface -- every Gauss point is wet and the
    !! integral is exact. For an element that STRADDLES the waterline this is a bounded Gauss-sampling
    !! approximation (the wetted length is quantised to the abscissae and the crossing-point
    !! derivative is dropped); surface-piercing elements do not get an exact wet-portion
    !! integration, which fully-submerged cables do not need.
    !! OPTIONAL WAVES: supplying a wave family adds the wave velocity at each wet Gauss point
    !! (Wheeler-stretched, z measured from waterline_z) to the fluid velocity the drag sees.
    !! Exactly one family with the shared wv_depth/wv_dir/wv_t: the scalar REGULAR trio
    !! wv_h/wv_om/wv_k (Airy), or the COMPONENT quartet wvc_amp/wvc_om/wvc_k/wvc_ph (an
    !! irregular long-crested table evaluated by CD_Component_Wave_Kinematics with total-eta
    !! Wheeler stretching). The wave-field SPATIAL GRADIENT is neglected in djq --
    !! the standard explicit-field treatment (the residual is exact; the tangent omits a term of
    !! order k*H*omega, far below the structural stiffness), so Newton convergence is preserved.
    REAL(wp), INTENT(IN) :: qe(12), ve(12), l0, fluid(3), waterline_z, rho, diam, cdn, cdt
    REAL(wp), INTENT(OUT) :: fdrag(12)
    ! djq/djv are OPTIONAL as a pair: a residual-only evaluation (a line-search trial, which
    ! never solves with a tangent) omits both and skips the 12x12 Jacobian accumulation --
    ! the dominant share of the drag-element cost. The force is unchanged.
    REAL(wp), INTENT(OUT), OPTIONAL :: djq(12, 12), djv(12, 12)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    REAL(wp), INTENT(IN), OPTIONAL :: wv_h, wv_om, wv_k, wv_depth, wv_dir, wv_t
    REAL(wp), INTENT(IN), OPTIONAL :: wvc_amp(:), wvc_om(:), wvc_k(:), wvc_ph(:)
    ! exp(-2 k_i depth) of the component table (see CD_Component_Wave_Kinematics)
    REAL(wp), INTENT(IN), OPTIONAL :: wvc_e2kd(:)

    INTEGER, PARAMETER :: NGP = 3
    REAL(wp), PARAMETER :: G3 = 0.7745966692414834_wp   ! sqrt(3/5)
    REAL(wp) :: gp(NGP), gw(NGP), H(4), dH(4)
    REAL(wp) :: rpos(3), vvel(3), rp(3), speed, tangent(3), urel(3), fpl(3), Jrel(3, 3), Jtan(3, 3)
    REAL(wp) :: jq3(3, 3), scale, eta_w, uw(3), aw(3)
    LOGICAL :: has_wv, has_shared, has_trio, has_cmp, any_wv_arg, want_jac
    INTEGER :: g, s, c, sp, cp, a, b, es
    ! the message of a per-Gauss-point CableDyn_Hydro kinematics or Morison call (at most 154
    ! characters): a short buffer, as these calls reset it at every Gauss point
    CHARACTER(200) :: em2

    ErrStat = CD_HCDYN_OK; ErrMsg = ''
    want_jac = PRESENT(djq)
    IF (want_jac .NEQV. PRESENT(djv)) THEN
      ErrStat = CD_HCDYN_BADINPUT
      ErrMsg = 'CD_HermiteCable_Drag_Element: djq and djv must be supplied together (or neither)'; RETURN
    END IF
    fdrag = CD_ZERO
    IF (want_jac) THEN
      djq = CD_ZERO; djv = CD_ZERO
    END IF
    has_shared = PRESENT(wv_depth) .AND. PRESENT(wv_dir) .AND. PRESENT(wv_t)
    has_trio = PRESENT(wv_h) .AND. PRESENT(wv_om) .AND. PRESENT(wv_k)
    has_cmp = PRESENT(wvc_amp) .AND. PRESENT(wvc_om) .AND. PRESENT(wvc_k) .AND. PRESENT(wvc_ph)
    any_wv_arg = PRESENT(wv_h) .OR. PRESENT(wv_om) .OR. PRESENT(wv_k) .OR. PRESENT(wv_depth) .OR. &
                 PRESENT(wv_dir) .OR. PRESENT(wv_t) .OR. PRESENT(wvc_amp) .OR. PRESENT(wvc_om) .OR. &
                 PRESENT(wvc_k) .OR. PRESENT(wvc_ph)
    has_wv = has_shared .AND. (has_trio .NEQV. has_cmp)
    IF (any_wv_arg .AND. .NOT. has_wv) THEN
      ErrStat = CD_HCDYN_BADINPUT
      ErrMsg = 'CD_HermiteCable_Drag_Element: wave arguments must form exactly one family '// &
               '(shared depth/dir/t plus the regular trio OR the component quartet)'; RETURN
    END IF
    IF (has_wv .AND. has_cmp) THEN
      ! component-table validity BEFORE the wet/dry Gauss loop (config validity must not
      ! depend on the element's wet/dry state; the kernel re-checks per call)
      IF (SIZE(wvc_amp) < 1 .OR. SIZE(wvc_om) /= SIZE(wvc_amp) .OR. SIZE(wvc_k) /= SIZE(wvc_amp) .OR. &
          SIZE(wvc_ph) /= SIZE(wvc_amp)) THEN
        ErrStat = CD_HCDYN_BADINPUT
        ErrMsg = 'CD_HermiteCable_Drag_Element: component arrays must share one length >= 1'; RETURN
      END IF
      IF (.NOT. (CD_All_Finite(wvc_amp) .AND. ALL(wvc_amp >= CD_ZERO) .AND. &
                 CD_All_Finite(wvc_om) .AND. ALL(wvc_om > CD_ZERO) .AND. &
                 CD_All_Finite(wvc_k) .AND. ALL(wvc_k > CD_ZERO) .AND. &
                 CD_All_Finite(wvc_ph))) THEN
        ErrStat = CD_HCDYN_BADINPUT
        ErrMsg = 'CD_HermiteCable_Drag_Element: component data must have finite positive omega/k, '// &
                 'non-negative amplitude, finite phase'; RETURN
      END IF
    END IF
    IF (.NOT. CD_All_Finite(qe) .OR. .NOT. CD_All_Finite(ve) .OR. .NOT. CD_Is_Finite(l0) .OR. &
        .NOT. CD_All_Finite(fluid) .OR. .NOT. CD_Is_Finite(waterline_z)) THEN
      ErrStat = CD_HCDYN_BADINPUT; ErrMsg = 'CD_HermiteCable_Drag_Element: inputs must be finite'; RETURN
    END IF
    IF (l0 <= CD_ZERO) THEN
      ErrStat = CD_HCDYN_BADINPUT; ErrMsg = 'CD_HermiteCable_Drag_Element: element length must be positive'; RETURN
    END IF
    ! Validate the hydrodynamic scalars BEFORE the wet/dry Gauss loop: a fully dry element cycles
    ! every Gauss point and would otherwise skip the only scalar check (inside the per-length
    ! primitive), silently returning OK for a malformed drag configuration. Config validity must not
    ! depend on the element's wet/dry state.
    IF (.NOT. CD_Is_Finite(rho) .OR. rho <= CD_ZERO .OR. .NOT. CD_Is_Finite(diam) .OR. diam <= CD_ZERO .OR. &
        .NOT. CD_Is_Finite(cdn) .OR. cdn < CD_ZERO .OR. .NOT. CD_Is_Finite(cdt) .OR. cdt < CD_ZERO) THEN
      ErrStat = CD_HCDYN_BADINPUT
      ErrMsg = 'CD_HermiteCable_Drag_Element: need rho>0, diam>0, cdn>=0, cdt>=0 (finite)'; RETURN
    END IF
    ! 3-point Gauss-Legendre on [0,1].
    gp = [0.5_wp*(CD_ONE - G3), 0.5_wp, 0.5_wp*(CD_ONE + G3)]
    gw = [5.0_wp/18.0_wp, 8.0_wp/18.0_wp, 5.0_wp/18.0_wp]

    DO g = 1, NGP
      CALL CD_HermiteCable_Shapes(gp(g), l0, H, dH)
      DO c = 1, 3
        rpos(c) = H(1)*qe(c) + H(2)*qe(3 + c) + H(3)*qe(6 + c) + H(4)*qe(9 + c)
        vvel(c) = H(1)*ve(c) + H(2)*ve(3 + c) + H(3)*ve(6 + c) + H(4)*ve(9 + c)
        rp(c) = dH(1)*qe(c) + dH(2)*qe(3 + c) + dH(3)*qe(6 + c) + dH(4)*qe(9 + c)
      END DO
      ! Wet/dry culling. Still water: a point above waterline_z is dry. With waves the free surface
      ! is the INSTANTANEOUS elevation eta(x, y, t): a point above still water but below a crest is
      ! wet (and carries drag against current + wave velocity); a point above eta is dry. The
      ! d(eta)/dq contribution is part of the documented neglected field gradient.
      IF (has_wv) THEN
        IF (has_cmp) THEN
          CALL CD_Component_Wave_Kinematics(rpos(1), rpos(2), rpos(3) - waterline_z, wv_t, &
                                            wv_depth, wv_dir, .TRUE., wvc_om, wvc_k, wvc_amp, wvc_ph, &
                                            eta_w, uw, aw, es, em2, inputs_validated=.TRUE., &
                                            exp_m2kd=wvc_e2kd)
        ELSE
          CALL CD_Airy_Wave_Kinematics_Precomputed(rpos(1), rpos(2), rpos(3) - waterline_z, wv_t, &
                                                   wv_h, wv_om, wv_k, wv_depth, wv_dir, .TRUE., &
                                                   eta_w, uw, aw, es, em2)
        END IF
        IF (es /= CD_HYDRO_OK) THEN
          ErrStat = CD_HCDYN_NOCONVERGE; ErrMsg = 'CD_HermiteCable_Drag_Element: '//TRIM(em2); RETURN
        END IF
        IF (rpos(3) - waterline_z > eta_w) CYCLE       ! above the instantaneous surface: dry
      ELSE
        IF (rpos(3) > waterline_z) CYCLE               ! dry Gauss point: no drag, no Jacobian
      END IF
      speed = SQRT(rp(1)**2 + rp(2)**2 + rp(3)**2)     ! |dr/dxi| = deformed arc length per unit xi
      IF (speed <= 1.0e-12_wp) THEN
        ErrStat = CD_HCDYN_NOCONVERGE
        ErrMsg = 'CD_HermiteCable_Drag_Element: degenerate centreline (|dr/dxi| ~ 0)'; RETURN
      END IF
      tangent = rp/speed
      urel = fluid - vvel
      IF (has_wv) urel = urel + uw
      ! Pass the raw dr/dxi as the tangent vector: the primitive normalises it and returns Jtan =
      ! d f_perlen / d(dr/dxi), so d f_perlen/d qe folds in through d(dr/dxi)/d qe = dH directly.
      ! rho, diam, cdn and cdt were validated above, before the Gauss loop.
      IF (want_jac) THEN
        CALL CD_Morison_Drag_Per_Length_Jac(urel, rp, rho, diam, cdn, cdt, fpl, Jrel, Jtan, es, em2, &
                                            scalars_validated=.TRUE.)
      ELSE
        ! same primitive without the Jacobian pair: the force statements are identical, so
        ! the residual-only trial force is bit-for-bit the with-Jacobian force.
        CALL CD_Morison_Drag_Per_Length_Jac(urel, rp, rho, diam, cdn, cdt, fpl, ErrStat=es, ErrMsg=em2, &
                                            scalars_validated=.TRUE.)
      END IF
      IF (es /= CD_HYDRO_OK) THEN
        ErrStat = CD_HCDYN_NOCONVERGE; ErrMsg = 'CD_HermiteCable_Drag_Element: '//TRIM(em2); RETURN
      END IF
      scale = gw(g)*speed                              ! ds = |dr/dxi| dxi (deformed cable length)
      DO s = 1, 4
        DO c = 1, 3
          a = 3*(s - 1) + c
          fdrag(a) = fdrag(a) + scale*H(s)*fpl(c)
        END DO
      END DO
      IF (.NOT. want_jac) CYCLE
      ! position: d[speed * f_perlen_c]/d qe(b) with d(dr/dxi)/d qe = dH(sp) --
      !   speed * Jtan(c,cp) * dH(sp)  (force direction/tangent)
      ! + f_perlen_c * d(speed)/d qe(b),  d(speed)/d qe(b) = tangent(cp) dH(sp);
      ! its 3 x 3 factor jq3 is formed once per Gauss point.
      DO cp = 1, 3
        DO c = 1, 3
          jq3(c, cp) = speed*Jtan(c, cp) + fpl(c)*tangent(cp)
        END DO
      END DO
      DO s = 1, 4
        DO c = 1, 3
          a = 3*(s - 1) + c
          DO sp = 1, 4
            DO cp = 1, 3
              b = 3*(sp - 1) + cp
              ! velocity: d urel/d ve(b) = -H(sp), scaled by the deformed length measure
              djv(a, b) = djv(a, b) - scale*H(s)*H(sp)*Jrel(c, cp)
              djq(a, b) = djq(a, b) + gw(g)*H(s)*dH(sp)*jq3(c, cp)
            END DO
          END DO
        END DO
      END DO
    END DO

    IF (.NOT. CD_All_Finite(fdrag)) THEN
      ErrStat = CD_HCDYN_NOCONVERGE; ErrMsg = 'CD_HermiteCable_Drag_Element: non-finite drag load/Jacobian'
      RETURN
    END IF
    IF (want_jac) THEN
      IF (.NOT. CD_All_Finite(djq) .OR. .NOT. CD_All_Finite(djv)) THEN
        ErrStat = CD_HCDYN_NOCONVERGE; ErrMsg = 'CD_HermiteCable_Drag_Element: non-finite drag load/Jacobian'
      END IF
    END IF
  END SUBROUTINE CD_HermiteCable_Drag_Element

  SUBROUTINE CD_HermiteCable_VIV_Lift_Element(qe, ve, l0, fluid, waterline_z, k_node, flift, djq, djv, &
                                              ErrStat, ErrMsg)
    !! Consistent Gauss-integrated cross-flow VIV lift on one cubic-Hermite element: the load
    !! integral N^T f ds of the per-length lift f = k(xi) U (t x v_r) (CD_VIV_Lift_Per_Length),
    !! with k = 1/2 rho D Cl cos(phi) interpolated linearly between the element's end nodes
    !! (k_node), and its force Jacobians djq = d flift/d qe, djv = d flift/d ve (both or neither).
    !! The interpolation, measure and wet/dry culling are the drag element's (still waterline).
    REAL(wp), INTENT(IN) :: qe(12), ve(12), l0, fluid(3), waterline_z, k_node(2)
    REAL(wp), INTENT(OUT) :: flift(12)
    REAL(wp), INTENT(OUT), OPTIONAL :: djq(12, 12), djv(12, 12)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    INTEGER, PARAMETER :: NGP = 3
    REAL(wp), PARAMETER :: G3 = 0.7745966692414834_wp   ! sqrt(3/5)
    REAL(wp) :: gp(NGP), gw(NGP), H(4), dH(4), rpos(3), vvel(3), rp(3), speed, tangent(3), fpl(3)
    REAL(wp) :: jrel(3, 3), jtan(3, 3), scale, kg
    LOGICAL :: want_jac, ok
    INTEGER :: g, s, c, sp, cp, a, b

    ErrStat = CD_HCDYN_OK; ErrMsg = ''
    want_jac = PRESENT(djq)
    flift = CD_ZERO
    IF (want_jac) THEN
      djq = CD_ZERO; djv = CD_ZERO
    END IF
    gp = [0.5_wp*(CD_ONE - G3), 0.5_wp, 0.5_wp*(CD_ONE + G3)]
    gw = [5.0_wp/18.0_wp, 8.0_wp/18.0_wp, 5.0_wp/18.0_wp]
    DO g = 1, NGP
      CALL CD_HermiteCable_Shapes(gp(g), l0, H, dH)
      DO c = 1, 3
        rpos(c) = H(1)*qe(c) + H(2)*qe(3 + c) + H(3)*qe(6 + c) + H(4)*qe(9 + c)
        vvel(c) = H(1)*ve(c) + H(2)*ve(3 + c) + H(3)*ve(6 + c) + H(4)*ve(9 + c)
        rp(c) = dH(1)*qe(c) + dH(2)*qe(3 + c) + dH(3)*qe(6 + c) + dH(4)*qe(9 + c)
      END DO
      IF (rpos(3) > waterline_z) CYCLE                 ! dry Gauss point: no lift
      kg = (CD_ONE - gp(g))*k_node(1) + gp(g)*k_node(2)
      IF (want_jac) THEN
        CALL CD_VIV_Lift_Per_Length(fluid - vvel, rp, kg, fpl, ok, jrel, jtan)
      ELSE
        CALL CD_VIV_Lift_Per_Length(fluid - vvel, rp, kg, fpl, ok)
      END IF
      IF (.NOT. ok) THEN
        ErrStat = CD_HCDYN_NOCONVERGE
        ErrMsg = 'CD_HermiteCable_VIV_Lift_Element: degenerate centreline (|dr/dxi| ~ 0)'; RETURN
      END IF
      speed = SQRT(rp(1)**2 + rp(2)**2 + rp(3)**2)
      tangent = rp/speed
      scale = gw(g)*speed
      DO s = 1, 4
        DO c = 1, 3
          a = 3*(s - 1) + c
          flift(a) = flift(a) + scale*H(s)*fpl(c)
        END DO
      END DO
      IF (.NOT. want_jac) CYCLE
      DO s = 1, 4
        DO c = 1, 3
          a = 3*(s - 1) + c
          DO sp = 1, 4
            DO cp = 1, 3
              b = 3*(sp - 1) + cp
              djv(a, b) = djv(a, b) - scale*H(s)*H(sp)*jrel(c, cp)
              djq(a, b) = djq(a, b) + gw(g)*H(s)*dH(sp)*(speed*jtan(c, cp) + fpl(c)*tangent(cp))
            END DO
          END DO
        END DO
      END DO
    END DO
    IF (.NOT. CD_All_Finite(flift)) THEN
      ErrStat = CD_HCDYN_NOCONVERGE; ErrMsg = 'CD_HermiteCable_VIV_Lift_Element: non-finite lift load'
    END IF
  END SUBROUTINE CD_HermiteCable_VIV_Lift_Element

  SUBROUTINE CD_HermiteCable_AddedMass_Element(qe, l0, waterline_z, rho, diam, can, cat, Ma, ErrStat, ErrMsg)
    !! Consistent Gauss-integrated Morison ADDED MASS on one cubic-Hermite bending-cable element:
    !!   Ma = integral N^T m_a(t) N ds,   m_a(t) = rho A (Can (I - t t^T) + Cat t t^T),
    !! with A = pi d^2/4, t the unit tangent of the deformed centreline, and ds = |dr/dxi| dxi the
    !! DEFORMED length measure -- the same interpolation, wet/dry culling, and measure as the drag
    !! element, so the two hydro effects are mutually consistent. Symmetric positive semi-definite
    !! (zero for a dry element). The submergence note on CD_HermiteCable_Drag_Element applies.
    REAL(wp), INTENT(IN) :: qe(12), l0, waterline_z, rho, diam, can, cat
    REAL(wp), INTENT(OUT) :: Ma(12, 12)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg

    ! 4-point Gauss: the H_i H_j mass integrand is degree 6, which 4-pt integrates exactly (the same
    ! rule the consistent structural mass uses) -- 3-pt would under-integrate the added mass.
    INTEGER, PARAMETER :: NGP = 4
    REAL(wp), PARAMETER :: PI_L = 3.14159265358979323846_wp
    REAL(wp) :: gp(NGP), gw(NGP), H(4), dH(4)
    REAL(wp) :: rpos(3), rp(3), speed, tangent(3), ma3(3, 3), area, scale
    INTEGER :: g, s, c, sp, cp, a, b

    ErrStat = CD_HCDYN_OK; ErrMsg = ''
    Ma = CD_ZERO
    IF (.NOT. CD_All_Finite(qe) .OR. .NOT. CD_Is_Finite(l0) .OR. .NOT. CD_Is_Finite(waterline_z)) THEN
      ErrStat = CD_HCDYN_BADINPUT; ErrMsg = 'CD_HermiteCable_AddedMass_Element: inputs must be finite'; RETURN
    END IF
    IF (l0 <= CD_ZERO) THEN
      ErrStat = CD_HCDYN_BADINPUT; ErrMsg = 'CD_HermiteCable_AddedMass_Element: element length must be positive'; RETURN
    END IF
    IF (.NOT. CD_Is_Finite(rho) .OR. rho <= CD_ZERO .OR. .NOT. CD_Is_Finite(diam) .OR. diam <= CD_ZERO .OR. &
        .NOT. CD_Is_Finite(can) .OR. can < CD_ZERO .OR. .NOT. CD_Is_Finite(cat) .OR. cat < CD_ZERO) THEN
      ErrStat = CD_HCDYN_BADINPUT
      ErrMsg = 'CD_HermiteCable_AddedMass_Element: need rho>0, diam>0, can>=0, cat>=0 (finite)'; RETURN
    END IF
    area = 0.25_wp*PI_L*diam*diam
    gp = [0.5_wp*(CD_ONE - 0.8611363115940526_wp), 0.5_wp*(CD_ONE - 0.3399810435848563_wp), &
          0.5_wp*(CD_ONE + 0.3399810435848563_wp), 0.5_wp*(CD_ONE + 0.8611363115940526_wp)]
    gw = 0.5_wp*[0.3478548451374538_wp, 0.6521451548625461_wp, &
                 0.6521451548625461_wp, 0.3478548451374538_wp]

    DO g = 1, NGP
      CALL CD_HermiteCable_Shapes(gp(g), l0, H, dH)
      DO c = 1, 3
        rpos(c) = H(1)*qe(c) + H(2)*qe(3 + c) + H(3)*qe(6 + c) + H(4)*qe(9 + c)
        rp(c) = dH(1)*qe(c) + dH(2)*qe(3 + c) + dH(3)*qe(6 + c) + dH(4)*qe(9 + c)
      END DO
      IF (rpos(3) > waterline_z) CYCLE                 ! dry Gauss point: no added mass
      speed = SQRT(rp(1)**2 + rp(2)**2 + rp(3)**2)
      IF (speed <= 1.0e-12_wp) THEN
        ErrStat = CD_HCDYN_NOCONVERGE
        ErrMsg = 'CD_HermiteCable_AddedMass_Element: degenerate centreline (|dr/dxi| ~ 0)'; RETURN
      END IF
      tangent = rp/speed
      ! m_a(t) = rho A (Can I + (Cat - Can) t t^T)
      DO cp = 1, 3
        DO c = 1, 3
          ma3(c, cp) = rho*area*(cat - can)*tangent(c)*tangent(cp)
        END DO
        ma3(cp, cp) = ma3(cp, cp) + rho*area*can
      END DO
      scale = gw(g)*speed                              ! ds = |dr/dxi| dxi (deformed cable length)
      DO s = 1, 4
        DO c = 1, 3
          a = 3*(s - 1) + c
          DO sp = 1, 4
            DO cp = 1, 3
              b = 3*(sp - 1) + cp
              Ma(a, b) = Ma(a, b) + scale*H(s)*H(sp)*ma3(c, cp)
            END DO
          END DO
        END DO
      END DO
    END DO

    ! Fail closed on an overflowed accumulation (finite but huge rho/diam/coefficients): a public
    ! element must never return CD_HCDYN_OK with a non-finite matrix.
    IF (.NOT. CD_All_Finite(Ma)) THEN
      ErrStat = CD_HCDYN_NOCONVERGE
      ErrMsg = 'CD_HermiteCable_AddedMass_Element: non-finite added-mass matrix'
    END IF
  END SUBROUTINE CD_HermiteCable_AddedMass_Element

  SUBROUTINE CD_HermiteCable_FK_Element(qe, l0, waterline_z, rho, diam, can, cat, &
                                        wv_h, wv_om, wv_k, wv_depth, wv_dir, wv_t, &
                                        ffk, fjq, ErrStat, ErrMsg, &
                                        wvc_amp, wvc_om, wvc_k, wvc_ph, hf_a, wvc_e2kd)
    !! Consistent Gauss-integrated FROUDE-KRYLOV + FLUID-INERTIA wave load on one cubic-Hermite
    !! bending-cable element: per wet Gauss point the Airy wave acceleration a_w (Wheeler-stretched,
    !! z measured from waterline_z) drives
    !!   f = rho A [ (1 + Can) a_w + ((1 + Cat) - (1 + Can)) (a_w . t) t ],
    !! distributed as ffk = integral N^T f ds over the deformed wet length (same interpolation,
    !! culling, and measure as the drag/added-mass elements). fjq = d ffk / d qe carries the
    !! GEOMETRIC tangent chain (through t(dr/dxi) and the length measure); the wave-field SPATIAL
    !! GRADIENT is neglected -- the standard explicit-field treatment (residual exact, tangent
    !! omits an O(k H omega^2) term far below the structural stiffness).
    !!
    !! FLUID-ACCELERATION SOURCES (exactly one): the scalar REGULAR trio wv_h/wv_om/wv_k,
    !! the COMPONENT quartet wvc_amp/wvc_om/wvc_k/wvc_ph (an irregular long-crested table
    !! evaluated by CD_Component_Wave_Kinematics with total-eta Wheeler stretching), or the
    !! HELD field hf_a -- a per-element CONSTANT fluid acceleration prescribed by an
    !! external host (sampled at the line nodes and node-averaged per element; frozen over
    !! the step, the documented weak-coupling cadence). With hf_a the caller's waterline_z
    !! already carries the local free-surface elevation, so the wet check uses it directly
    !! (eta_w = 0 relative) and wv_depth/wv_dir/wv_t are unread (pass zeros).
    !! wv_depth/wv_dir/wv_t are shared by both wave families.
    REAL(wp), INTENT(IN) :: qe(12), l0, waterline_z, rho, diam, can, cat
    REAL(wp), INTENT(IN), OPTIONAL :: wv_h, wv_om, wv_k
    REAL(wp), INTENT(IN) :: wv_depth, wv_dir, wv_t
    REAL(wp), INTENT(OUT) :: ffk(12)
    ! fjq is OPTIONAL: a residual-only evaluation (a line-search trial, which never solves
    ! with a tangent) omits it and skips the 12x12 Jacobian accumulation. ffk is unchanged.
    REAL(wp), INTENT(OUT), OPTIONAL :: fjq(12, 12)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    REAL(wp), INTENT(IN), OPTIONAL :: wvc_amp(:), wvc_om(:), wvc_k(:), wvc_ph(:)
    ! exp(-2 k_i depth) of the component table (see CD_Component_Wave_Kinematics)
    REAL(wp), INTENT(IN), OPTIONAL :: wvc_e2kd(:)
    REAL(wp), INTENT(IN), OPTIONAL :: hf_a(3)

    INTEGER, PARAMETER :: NGP = 3
    REAL(wp), PARAMETER :: G3 = 0.7745966692414834_wp   ! sqrt(3/5)
    REAL(wp), PARAMETER :: PI_L = 3.14159265358979323846_wp
    REAL(wp) :: gp(NGP), gw(NGP), H(4), dH(4)
    REAL(wp) :: rpos(3), rp(3), speed, tangent(3), eta_w, uw(3), aw(3), area, alpha
    REAL(wp) :: fpl(3), Jtan(3, 3), proj(3, 3), projk(3), dalpha, jq3(3, 3)
    LOGICAL :: has_trio, has_cmp, has_held, want_jac
    INTEGER :: g, s, c, sp, cp, a, b, k, es
    ! the message of a per-Gauss-point CableDyn_Hydro kinematics call (at most 154 characters): a
    ! short buffer, as these calls reset it at every Gauss point
    CHARACTER(200) :: em2

    ErrStat = CD_HCDYN_OK; ErrMsg = ''
    want_jac = PRESENT(fjq)
    ffk = CD_ZERO
    IF (want_jac) fjq = CD_ZERO
    has_trio = PRESENT(wv_h) .AND. PRESENT(wv_om) .AND. PRESENT(wv_k)
    has_cmp = PRESENT(wvc_amp) .AND. PRESENT(wvc_om) .AND. PRESENT(wvc_k) .AND. PRESENT(wvc_ph)
    IF ((.NOT. has_trio) .AND. (PRESENT(wv_h) .OR. PRESENT(wv_om) .OR. PRESENT(wv_k))) THEN
      ErrStat = CD_HCDYN_BADINPUT
      ErrMsg = 'CD_HermiteCable_FK_Element: the regular-wave trio must be supplied together'; RETURN
    END IF
    IF ((.NOT. has_cmp) .AND. (PRESENT(wvc_amp) .OR. PRESENT(wvc_om) .OR. PRESENT(wvc_k) .OR. &
                               PRESENT(wvc_ph))) THEN
      ErrStat = CD_HCDYN_BADINPUT
      ErrMsg = 'CD_HermiteCable_FK_Element: the component-wave quartet must be supplied together'; RETURN
    END IF
    has_held = PRESENT(hf_a)
    IF (COUNT([has_trio, has_cmp, has_held]) /= 1) THEN
      ErrStat = CD_HCDYN_BADINPUT
      ErrMsg = 'CD_HermiteCable_FK_Element: supply exactly one fluid-acceleration source '// &
               '(regular trio, component quartet, OR the held field hf_a)'; RETURN
    END IF
    IF (has_held) THEN
      IF (.NOT. CD_All_Finite(hf_a)) THEN
        ErrStat = CD_HCDYN_BADINPUT
        ErrMsg = 'CD_HermiteCable_FK_Element: the held fluid acceleration must be finite'; RETURN
      END IF
    END IF
    IF (.NOT. CD_All_Finite(qe) .OR. .NOT. CD_Is_Finite(l0) .OR. .NOT. CD_Is_Finite(waterline_z) .OR. &
        .NOT. CD_Is_Finite(wv_t)) THEN
      ErrStat = CD_HCDYN_BADINPUT; ErrMsg = 'CD_HermiteCable_FK_Element: inputs must be finite'; RETURN
    END IF
    IF (l0 <= CD_ZERO) THEN
      ErrStat = CD_HCDYN_BADINPUT; ErrMsg = 'CD_HermiteCable_FK_Element: element length must be positive'; RETURN
    END IF
    ! Validate all scalars BEFORE the wet/dry Gauss loop (config validity must not depend on the
    ! element's wet/dry state).
    IF (.NOT. CD_Is_Finite(rho) .OR. rho <= CD_ZERO .OR. .NOT. CD_Is_Finite(diam) .OR. diam <= CD_ZERO .OR. &
        .NOT. CD_Is_Finite(can) .OR. can < CD_ZERO .OR. .NOT. CD_Is_Finite(cat) .OR. cat < CD_ZERO) THEN
      ErrStat = CD_HCDYN_BADINPUT
      ErrMsg = 'CD_HermiteCable_FK_Element: need rho>0, diam>0, can>=0, cat>=0 (finite)'; RETURN
    END IF
    IF (.NOT. has_held) THEN
      IF (.NOT. CD_Is_Finite(wv_depth) .OR. wv_depth <= CD_ZERO .OR. .NOT. CD_Is_Finite(wv_dir)) THEN
        ErrStat = CD_HCDYN_BADINPUT
        ErrMsg = 'CD_HermiteCable_FK_Element: need wave depth > 0 and finite direction'; RETURN
      END IF
    END IF
    IF (has_held) THEN
      CONTINUE   ! the held field carries no wave configuration to validate
    ELSE IF (has_trio) THEN
      IF (.NOT. CD_Is_Finite(wv_h) .OR. wv_h <= CD_ZERO .OR. .NOT. CD_Is_Finite(wv_om) .OR. &
          wv_om <= CD_ZERO .OR. .NOT. CD_Is_Finite(wv_k) .OR. wv_k <= CD_ZERO) THEN
        ErrStat = CD_HCDYN_BADINPUT
        ErrMsg = 'CD_HermiteCable_FK_Element: need wave height/omega/k > 0 (finite)'; RETURN
      END IF
    ELSE
      ! component-table validity BEFORE the wet/dry Gauss loop (same rule as the scalars;
      ! the kernel re-checks, but a fully dry element must not skip the config check)
      IF (SIZE(wvc_amp) < 1 .OR. SIZE(wvc_om) /= SIZE(wvc_amp) .OR. SIZE(wvc_k) /= SIZE(wvc_amp) .OR. &
          SIZE(wvc_ph) /= SIZE(wvc_amp)) THEN
        ErrStat = CD_HCDYN_BADINPUT
        ErrMsg = 'CD_HermiteCable_FK_Element: component arrays must share one length >= 1'; RETURN
      END IF
      IF (.NOT. (CD_All_Finite(wvc_amp) .AND. ALL(wvc_amp >= CD_ZERO) .AND. &
                 CD_All_Finite(wvc_om) .AND. ALL(wvc_om > CD_ZERO) .AND. &
                 CD_All_Finite(wvc_k) .AND. ALL(wvc_k > CD_ZERO) .AND. &
                 CD_All_Finite(wvc_ph))) THEN
        ErrStat = CD_HCDYN_BADINPUT
        ErrMsg = 'CD_HermiteCable_FK_Element: component data must have finite positive omega/k, '// &
                 'non-negative amplitude, finite phase'; RETURN
      END IF
    END IF
    area = 0.25_wp*PI_L*diam*diam
    gp = [0.5_wp*(CD_ONE - G3), 0.5_wp, 0.5_wp*(CD_ONE + G3)]
    gw = [5.0_wp/18.0_wp, 8.0_wp/18.0_wp, 5.0_wp/18.0_wp]

    DO g = 1, NGP
      CALL CD_HermiteCable_Shapes(gp(g), l0, H, dH)
      DO c = 1, 3
        rpos(c) = H(1)*qe(c) + H(2)*qe(3 + c) + H(3)*qe(6 + c) + H(4)*qe(9 + c)
        rp(c) = dH(1)*qe(c) + dH(2)*qe(3 + c) + dH(3)*qe(6 + c) + dH(4)*qe(9 + c)
      END DO
      ! Wet/dry culling on the INSTANTANEOUS free surface eta(x, y, t): a point above still water
      ! but below a crest is wet and carries the wave load; a point above eta is dry (the Wheeler
      ! kinematics are zero there anyway). d(eta)/dq is part of the neglected field gradient.
      ! With the HELD field the caller's waterline_z already carries the sampled local elevation,
      ! so the wet check is against it directly (eta_w = 0 relative).
      IF (has_held) THEN
        eta_w = CD_ZERO
        aw = hf_a
        es = CD_HYDRO_OK
      ELSE IF (has_cmp) THEN
        CALL CD_Component_Wave_Kinematics(rpos(1), rpos(2), rpos(3) - waterline_z, wv_t, &
                                          wv_depth, wv_dir, .TRUE., wvc_om, wvc_k, wvc_amp, wvc_ph, &
                                          eta_w, uw, aw, es, em2, inputs_validated=.TRUE., &
                                          exp_m2kd=wvc_e2kd)
      ELSE
        CALL CD_Airy_Wave_Kinematics_Precomputed(rpos(1), rpos(2), rpos(3) - waterline_z, wv_t, &
                                                 wv_h, wv_om, wv_k, wv_depth, wv_dir, .TRUE., &
                                                 eta_w, uw, aw, es, em2)
      END IF
      IF (es /= CD_HYDRO_OK) THEN
        ErrStat = CD_HCDYN_NOCONVERGE; ErrMsg = 'CD_HermiteCable_FK_Element: '//TRIM(em2); RETURN
      END IF
      IF (rpos(3) - waterline_z > eta_w) CYCLE         ! above the instantaneous surface: dry
      speed = SQRT(rp(1)**2 + rp(2)**2 + rp(3)**2)
      IF (speed <= 1.0e-12_wp) THEN
        ErrStat = CD_HCDYN_NOCONVERGE
        ErrMsg = 'CD_HermiteCable_FK_Element: degenerate centreline (|dr/dxi| ~ 0)'; RETURN
      END IF
      tangent = rp/speed
      alpha = DOT_PRODUCT(aw, tangent)
      fpl = rho*area*((CD_ONE + can)*aw + (cat - can)*alpha*tangent)
      IF (want_jac) THEN
        ! Jtan = d fpl / d(dr/dxi): through d t/d rp = (I - t t^T)/speed. Column k uses the
        ! projected direction projk; d fpl = rho A (cat-can) (dalpha t + alpha projk),
        ! dalpha = aw . projk.
        DO k = 1, 3
          DO c = 1, 3
            proj(c, k) = -tangent(c)*tangent(k)/speed
          END DO
          proj(k, k) = proj(k, k) + CD_ONE/speed
        END DO
        DO k = 1, 3
          projk = proj(:, k)
          dalpha = DOT_PRODUCT(aw, projk)
          Jtan(:, k) = rho*area*(cat - can)*(dalpha*tangent + alpha*projk)
        END DO
      END IF
      DO s = 1, 4
        DO c = 1, 3
          a = 3*(s - 1) + c
          ffk(a) = ffk(a) + gw(g)*speed*H(s)*fpl(c)
        END DO
      END DO
      IF (.NOT. want_jac) CYCLE
      ! d[speed * fpl_c]/d qe(b): the tangent chain plus the length-measure derivative, with
      ! its 3 x 3 factor jq3 formed once per Gauss point.
      DO cp = 1, 3
        DO c = 1, 3
          jq3(c, cp) = speed*Jtan(c, cp) + fpl(c)*tangent(cp)
        END DO
      END DO
      DO s = 1, 4
        DO c = 1, 3
          a = 3*(s - 1) + c
          DO sp = 1, 4
            DO cp = 1, 3
              b = 3*(sp - 1) + cp
              fjq(a, b) = fjq(a, b) + gw(g)*H(s)*dH(sp)*jq3(c, cp)
            END DO
          END DO
        END DO
      END DO
    END DO

    IF (.NOT. CD_All_Finite(ffk)) THEN
      ErrStat = CD_HCDYN_NOCONVERGE; ErrMsg = 'CD_HermiteCable_FK_Element: non-finite wave load/Jacobian'
      RETURN
    END IF
    IF (want_jac) THEN
      IF (.NOT. CD_All_Finite(fjq)) THEN
        ErrStat = CD_HCDYN_NOCONVERGE; ErrMsg = 'CD_HermiteCable_FK_Element: non-finite wave load/Jacobian'
      END IF
    END IF
  END SUBROUTINE CD_HermiteCable_FK_Element

  SUBROUTINE assemble_added_mass(model, q_cfg, ErrStat, ErrMsg)
    !! Global consistent added-mass matrix at configuration q_cfg (zero when disabled),
    !! written into the model's own ws_Mamb band buffer through the single model dummy
    !! (no subobject argument-associated alongside the model -- the aliasing rule).
    !! q_cfg may be a model workspace vector; it is only read.
    TYPE(CD_HermiteCableDynType), INTENT(INOUT) :: model
    REAL(wp), INTENT(IN) :: q_cfg(:)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    INTEGER :: e, es
    REAL(wp) :: Me(12, 12)
    CHARACTER(1024) :: em2
    ErrStat = CD_HCDYN_OK; ErrMsg = ''
    ! the stored band only: the fill-in rows above it stay zero (BAND_TOP_D)
    model%ws_Mamb(BAND_TOP_D:, :) = CD_ZERO
    IF (.NOT. model%has_am) RETURN
    DO e = 1, model%ne
      CALL added_mass_element(model, q_cfg, e, Me, es, em2)
      IF (es /= CD_HCDYN_OK) THEN
        ErrStat = es; ErrMsg = TRIM(em2); RETURN
      END IF
      CALL scatter12_band(model%ws_Mamb, Me, e)
    END DO
    ! Every element matrix can be finite while two adjacent contributions
    ! overflow at their shared-node band entry.  Validate the assembled global
    ! operator before it is added to the structural mass or factorised.
    IF (.NOT. CD_All_Finite(model%ws_Mamb(BAND_TOP_D:, :))) THEN
      ErrStat = CD_HCDYN_NOCONVERGE
      ErrMsg = 'assemble_added_mass: non-finite global added-mass matrix'
    END IF
  END SUBROUTINE assemble_added_mass

  SUBROUTINE added_mass_element(model, q_cfg, e, Me, ErrStat, ErrMsg)
    !! Consistent added-mass matrix of element e at configuration q_cfg (assemble_added_mass,
    !! node_reaction).
    TYPE(CD_HermiteCableDynType), INTENT(IN) :: model
    REAL(wp), INTENT(IN) :: q_cfg(:)
    INTEGER, INTENT(IN) :: e
    REAL(wp), INTENT(OUT) :: Me(12, 12)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    REAL(wp) :: qe(12), wl_e
    qe(1:3) = q_cfg(6*(e - 1) + 1:6*(e - 1) + 3); qe(4:6) = q_cfg(6*(e - 1) + 4:6*(e - 1) + 6)
    qe(7:9) = q_cfg(6*e + 1:6*e + 3); qe(10:12) = q_cfg(6*e + 4:6*e + 6)
    ! Held-field mode: the inertia matrix must wet against the SAME free surface the
    ! drag and Froude-Krylov use (the host-sampled elevation, node-averaged per
    ! element) -- against the init-time still-water am_wl a surface-piercing element
    ! would carry the wrong added mass exactly when the host drives waves.
    wl_e = model%am_wl
    IF (model%has_held_field) wl_e = 0.5_wp*(model%hf_wl(e) + model%hf_wl(e + 1))
    CALL CD_HermiteCable_AddedMass_Element(qe, model%l0(e), wl_e, model%am_rho, &
                                           model%am_diam(e), model%am_can(e), model%am_cat(e), Me, ErrStat, ErrMsg)
  END SUBROUTINE added_mass_element

  SUBROUTINE build_rigid_bases(model, directions, bases, ErrStat, ErrMsg)
    TYPE(CD_HermiteCableDynType), INTENT(IN) :: model
    REAL(wp), INTENT(IN) :: directions(3, 2)
    REAL(wp), INTENT(OUT) :: bases(3, 3, 2)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    INTEGER :: iend, es
    CHARACTER(1024) :: em
    bases = CD_ZERO
    ErrStat = CD_HCDYN_OK
    ErrMsg = ''
    DO iend = 1, 2
      IF (model%endconn_mode(iend) /= CD_ENDCONN_RIGID) CYCLE
      CALL CD_EndConn_Basis(directions(:, iend), bases(:, :, iend), es, em)
      IF (es /= CD_ENDCONN_OK) THEN
        ErrStat = CD_HCDYN_BADINPUT
        ErrMsg = 'invalid rigid end direction: '//TRIM(em)
        RETURN
      END IF
    END DO
  END SUBROUTINE build_rigid_bases

  SUBROUTINE project_rigid_tangents(model, directions, q, ErrStat, ErrMsg)
    TYPE(CD_HermiteCableDynType), INTENT(IN) :: model
    REAL(wp), INTENT(IN) :: directions(3, 2)
    REAL(wp), INTENT(INOUT) :: q(:)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    INTEGER :: iend, base, es
    REAL(wp) :: projected(3)
    CHARACTER(1024) :: em
    ErrStat = CD_HCDYN_OK
    ErrMsg = ''
    DO iend = 1, 2
      IF (model%endconn_mode(iend) /= CD_ENDCONN_RIGID) CYCLE
      IF (iend == 1) THEN
        base = 3
      ELSE
        base = 6*(model%nn - 1) + 3
      END IF
      CALL CD_EndConn_Project(q(base + 1:base + 3), directions(:, iend), projected, es, em)
      IF (es /= CD_ENDCONN_OK) THEN
        ErrStat = CD_HCDYN_NOCONVERGE
        ErrMsg = 'rigid endpoint projection failed: '//TRIM(em)
        RETURN
      END IF
      q(base + 1:base + 3) = projected
    END DO
  END SUBROUTINE project_rigid_tangents

  SUBROUTINE transform_rigid_vector_to_local(model, bases, vector)
    TYPE(CD_HermiteCableDynType), INTENT(IN) :: model
    REAL(wp), INTENT(IN) :: bases(3, 3, 2)
    REAL(wp), INTENT(INOUT) :: vector(:)
    INTEGER :: iend, base
    REAL(wp) :: local_values(3)
    DO iend = 1, 2
      IF (model%endconn_mode(iend) /= CD_ENDCONN_RIGID) CYCLE
      IF (iend == 1) THEN
        base = 3
      ELSE
        base = 6*(model%nn - 1) + 3
      END IF
      local_values = MATMUL(TRANSPOSE(bases(:, :, iend)), vector(base + 1:base + 3))
      vector(base + 1:base + 3) = local_values
    END DO
  END SUBROUTINE transform_rigid_vector_to_local

  SUBROUTINE transform_rigid_vector_to_global(model, bases, vector)
    TYPE(CD_HermiteCableDynType), INTENT(IN) :: model
    REAL(wp), INTENT(IN) :: bases(3, 3, 2)
    REAL(wp), INTENT(INOUT) :: vector(:)
    INTEGER :: iend, base
    REAL(wp) :: global_values(3)
    DO iend = 1, 2
      IF (model%endconn_mode(iend) /= CD_ENDCONN_RIGID) CYCLE
      IF (iend == 1) THEN
        base = 3
      ELSE
        base = 6*(model%nn - 1) + 3
      END IF
      global_values = MATMUL(bases(:, :, iend), vector(base + 1:base + 3))
      vector(base + 1:base + 3) = global_values
    END DO
  END SUBROUTINE transform_rigid_vector_to_global

  PURE SUBROUTINE newmark_acceleration(c_a, q, q_n, c_v, v_n, c_a2, a_n, a)
    !! a = c_a*(q - q_n) - c_v*v_n - c_a2*a_n (a distinct from the inputs).
    REAL(wp), INTENT(IN) :: c_a, c_v, c_a2, q(:), q_n(:), v_n(:), a_n(:)
    REAL(wp), INTENT(INOUT) :: a(:)
    a = c_a*(q - q_n) - c_v*v_n - c_a2*a_n
  END SUBROUTINE newmark_acceleration

  PURE SUBROUTINE newmark_velocity(dt, w_n, w_k, v_n, a_n, a_k, v)
    !! v = v_n + dt*(w_n*a_n + w_k*a_k) (v distinct from the inputs).
    REAL(wp), INTENT(IN) :: dt, w_n, w_k, v_n(:), a_n(:), a_k(:)
    REAL(wp), INTENT(INOUT) :: v(:)
    v = v_n + dt*(w_n*a_n + w_k*a_k)
  END SUBROUTINE newmark_velocity

  PURE SUBROUTINE vector_copy(x, y)
    !! y = x (distinct arrays).
    REAL(wp), INTENT(IN) :: x(:)
    REAL(wp), INTENT(INOUT) :: y(:)
    y = x
  END SUBROUTINE vector_copy

  PURE SUBROUTINE vector_blend(a, x, b, y, out)
    !! out = a*x + b*y (out distinct from x and y).
    REAL(wp), INTENT(IN) :: a, b, x(:), y(:)
    REAL(wp), INTENT(INOUT) :: out(:)
    out = a*x + b*y
  END SUBROUTINE vector_blend

  PURE SUBROUTINE vector_sum2(x, y, out)
    !! out = x + y (out distinct from x and y).
    REAL(wp), INTENT(IN) :: x(:), y(:)
    REAL(wp), INTENT(INOUT) :: out(:)
    out = x + y
  END SUBROUTINE vector_sum2

  PURE SUBROUTINE vector_sum3(x, b, y, c, z, out)
    !! out = x + b*y + c*z (out distinct from x, y and z).
    REAL(wp), INTENT(IN) :: b, c, x(:), y(:), z(:)
    REAL(wp), INTENT(INOUT) :: out(:)
    out = x + b*y + c*z
  END SUBROUTINE vector_sum3

  ! The band sweeps below take CONTIGUOUS dummies, which lets the compiler vectorise them.
  ! Every caller passes whole allocatable model arrays, so no copy is ever made; an actual
  ! the compiler cannot prove contiguous (a pointer, an assumed-shape dummy) would be
  ! packed into a temporary at each call. They sweep the stored band rows only: the fill-in
  ! rows of their operands are zero (BAND_TOP_D).

  PURE SUBROUTINE band_copy(x, y)
    !! y = x for band storage (distinct arrays).
    REAL(wp), CONTIGUOUS, INTENT(IN) :: x(:, :)
    REAL(wp), CONTIGUOUS, INTENT(INOUT) :: y(:, :)
    INTEGER :: j
    DO j = 1, SIZE(x, 2)
      y(BAND_TOP_D:, j) = x(BAND_TOP_D:, j)
    END DO
  END SUBROUTINE band_copy

  PURE SUBROUTINE band_sum(x, y, out)
    !! out = x + y for band storage in one sweep (out distinct from x and y).
    REAL(wp), CONTIGUOUS, INTENT(IN) :: x(:, :), y(:, :)
    REAL(wp), CONTIGUOUS, INTENT(INOUT) :: out(:, :)
    INTEGER :: j
    DO j = 1, SIZE(x, 2)
      out(BAND_TOP_D:, j) = x(BAND_TOP_D:, j) + y(BAND_TOP_D:, j)
    END DO
  END SUBROUTINE band_sum

  PURE SUBROUTINE band_combine(a, x, b, y, c, z, out)
    !! out = a*x + b*y + c*z for band storage (out distinct from x, y, z). The fill-in rows of
    !! out, which a previous factorization overwrote, are reset to the zero a*0 + b*0 + c*0
    !! of the operands' fill-in rows.
    REAL(wp), INTENT(IN) :: a, b, c
    REAL(wp), CONTIGUOUS, INTENT(IN) :: x(:, :), y(:, :), z(:, :)
    REAL(wp), CONTIGUOUS, INTENT(INOUT) :: out(:, :)
    INTEGER :: j
    DO j = 1, SIZE(x, 2)
      out(1:BAND_TOP_D - 1, j) = CD_ZERO
      out(BAND_TOP_D:, j) = a*x(BAND_TOP_D:, j) + b*y(BAND_TOP_D:, j) + c*z(BAND_TOP_D:, j)
    END DO
  END SUBROUTINE band_combine

  SUBROUTINE transform_rigid_band(model, bases, matrix)
    TYPE(CD_HermiteCableDynType), INTENT(IN) :: model
    REAL(wp), INTENT(IN) :: bases(3, 3, 2)
    REAL(wp), INTENT(INOUT) :: matrix(:, :)
    INTEGER :: iend, first, row, col, j
    REAL(wp) :: old_values(3), new_values(3)
    DO iend = 1, 2
      IF (model%endconn_mode(iend) /= CD_ENDCONN_RIGID) CYCLE
      IF (iend == 1) THEN
        first = 4
      ELSE
        first = 6*(model%nn - 1) + 4
      END IF
      DO row = MAX(1, first - KU_D), MIN(model%ndof, first + 2 + KL_D)
        DO j = 1, 3
          old_values(j) = dynamic_band_entry(model, matrix, row, first + j - 1)
        END DO
        new_values = MATMUL(old_values, bases(:, :, iend))
        DO j = 1, 3
          CALL set_dynamic_band_entry(model, matrix, row, first + j - 1, new_values(j))
        END DO
      END DO
      DO col = MAX(1, first - KL_D), MIN(model%ndof, first + 2 + KU_D)
        DO j = 1, 3
          old_values(j) = dynamic_band_entry(model, matrix, first + j - 1, col)
        END DO
        new_values = MATMUL(TRANSPOSE(bases(:, :, iend)), old_values)
        DO j = 1, 3
          CALL set_dynamic_band_entry(model, matrix, first + j - 1, col, new_values(j))
        END DO
      END DO
    END DO
  END SUBROUTINE transform_rigid_band

  PURE REAL(wp) FUNCTION dynamic_band_entry(model, matrix, row, col) RESULT(value)
    TYPE(CD_HermiteCableDynType), INTENT(IN) :: model
    REAL(wp), INTENT(IN) :: matrix(:, :)
    INTEGER, INTENT(IN) :: row, col
    value = CD_ZERO
    IF (row < 1 .OR. row > model%ndof .OR. col < 1 .OR. col > model%ndof) RETURN
    IF (row - col < -KU_D .OR. row - col > KL_D) RETURN
    value = matrix(KL_D + KU_D + 1 + row - col, col)
  END FUNCTION dynamic_band_entry

  SUBROUTINE set_dynamic_band_entry(model, matrix, row, col, value)
    TYPE(CD_HermiteCableDynType), INTENT(IN) :: model
    REAL(wp), INTENT(INOUT) :: matrix(:, :)
    INTEGER, INTENT(IN) :: row, col
    REAL(wp), INTENT(IN) :: value
    IF (row < 1 .OR. row > model%ndof .OR. col < 1 .OR. col > model%ndof) RETURN
    IF (row - col < -KU_D .OR. row - col > KL_D) RETURN
    matrix(KL_D + KU_D + 1 + row - col, col) = value
  END SUBROUTINE set_dynamic_band_entry

  SUBROUTINE solve_consistent_acceleration(model, ErrStat, ErrMsg, pres_dofs, pres_a)
    !! Set model%a to the consistent acceleration M a = f_ext(q,v) - f_int(q) on the free DOFs at the
    !! current state. Fixed DOFs keep a = 0 unless pres_dofs/pres_a supplies a prescribed acceleration;
    !! its M_fp*a_p contribution is then included in the free equations. Used at Init and whenever the
    !! load set changes (drag), so the gen-alpha predictor always starts from a physically consistent
    !! acceleration.
    TYPE(CD_HermiteCableDynType), INTENT(INOUT) :: model
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    INTEGER, INTENT(IN), OPTIONAL :: pres_dofs(:)
    REAL(wp), INTENT(IN), OPTIONAL :: pres_a(:)
    INTEGER :: nf, np, i, ip, jp, gdof, es, iend, base
    LOGICAL :: has_pres
    REAL(wp) :: rigid_basis(3, 3, 2), old_acceleration(3), axial_acceleration
    CHARACTER(1024) :: em2
    ErrStat = CD_HCDYN_OK; ErrMsg = ''
    ! This solve factors the mass into ws_Keffb: the carried step factor is gone.
    model%tr_valid = .FALSE.
    nf = COUNT(model%solve_mask)
    has_pres = PRESENT(pres_dofs) .AND. PRESENT(pres_a)
    IF ((PRESENT(pres_dofs) .OR. PRESENT(pres_a)) .AND. .NOT. has_pres) THEN
      ErrStat = CD_HCDYN_BADINPUT
      ErrMsg = 'solve_consistent_acceleration: pres_dofs and pres_a must be supplied together'; RETURN
    END IF
    np = 0
    IF (has_pres) THEN
      np = SIZE(pres_dofs)
      IF (SIZE(pres_a) /= np) THEN
        ErrStat = CD_HCDYN_BADINPUT
        ErrMsg = 'solve_consistent_acceleration: pres_a must match pres_dofs length'; RETURN
      END IF
      DO ip = 1, np
        gdof = pres_dofs(ip)
        IF (gdof < 1 .OR. gdof > model%ndof) THEN
          ErrStat = CD_HCDYN_BADINPUT
          ErrMsg = 'solve_consistent_acceleration: prescribed DOF out of range'; RETURN
        END IF
        IF (model%freemask(gdof)) THEN
          ErrStat = CD_HCDYN_BADINPUT
          ErrMsg = 'solve_consistent_acceleration: prescribed DOF must be in fixed_dofs'; RETURN
        END IF
        IF (.NOT. CD_Is_Finite(pres_a(ip))) THEN
          ErrStat = CD_HCDYN_BADINPUT
          ErrMsg = 'solve_consistent_acceleration: prescribed acceleration must be finite'; RETURN
        END IF
        DO jp = 1, ip - 1
          IF (pres_dofs(jp) == gdof) THEN
            ErrStat = CD_HCDYN_BADINPUT
            ErrMsg = 'solve_consistent_acceleration: prescribed DOFs must be unique'; RETURN
          END IF
        END DO
      END DO
    END IF
    ! Preserve the already committed acceleration of a moving rigid direction.
    ! Load setters may refresh the free acceleration between coupling steps; they
    ! must not erase the kinematic transverse acceleration established by the
    ! preceding constrained step.
    model%ws_vk = model%a
    model%a = CD_ZERO
    ! Assemble (and thereby VALIDATE) the residual even for a fully constrained model: skipping it
    ! would let Init accept a geometrically invalid seed, and Set_Drag report success on a drag
    ! configuration whose loads are non-finite -- deferring the failure to the next Step instead of
    ! failing closed (and rolling back) here. Only the mass solve is skipped when nf = 0.
    ! Uses the model's step workspace (allocated at Init before this is first called).
    CALL assemble_residual(model, model%q, model%v, model%t, .TRUE., .FALSE., es, em2)  ! ws_R = f_int - f_ext
    IF (es /= CD_HCDYN_OK) THEN
      ErrStat = es; ErrMsg = 'solve_consistent_acceleration: '//TRIM(em2); RETURN
    END IF
    ! Nodal twist: the angles' accelerations from their lumped inertia (a held angle keeps its
    ! own), installed with the cable's at the end.
    IF (model%tw_active) THEN
      DO i = 1, model%nn
        model%tw_ak(i) = model%tw_al(i)
        IF (model%tw_free(i)) model%tw_ak(i) = -model%tw_R(i)/model%tw_mass(i)
      END DO
    END IF
    ! Total mass = structural + added (the added-mass matrix at the current configuration).
    model%ws_Msumb = model%Mgb
    IF (model%has_am) THEN
      CALL assemble_added_mass(model, model%q, es, em2)
      IF (es /= CD_HCDYN_OK) THEN
        ErrStat = es; ErrMsg = 'solve_consistent_acceleration: '//TRIM(em2); RETURN
      END IF
      model%ws_Msumb = model%ws_Msumb + model%ws_Mamb
    END IF
    ! Build the fixed-DOF acceleration vector before the early return: a fully constrained
    ! model still has to retain a caller-prescribed boundary acceleration.
    model%ws_an = CD_ZERO
    IF (has_pres) model%ws_an(pres_dofs) = pres_a
    CALL build_rigid_bases(model, model%endconn_d0, rigid_basis, es, em2)
    IF (es /= CD_HCDYN_OK) THEN
      ErrStat = es; ErrMsg = 'solve_consistent_acceleration: '//TRIM(em2); RETURN
    END IF
    DO iend = 1, 2
      IF (model%endconn_mode(iend) /= CD_ENDCONN_RIGID) CYCLE
      IF (iend == 1) THEN
        base = 3
      ELSE
        base = 6*(model%nn - 1) + 3
      END IF
      old_acceleration = model%ws_vk(base + 1:base + 3)
      axial_acceleration = DOT_PRODUCT(old_acceleration, rigid_basis(:, 1, iend))
      model%ws_an(base + 1:base + 3) = old_acceleration - &
                                       axial_acceleration*rigid_basis(:, 1, iend)
    END DO
    IF (nf == 0) THEN
      model%a = model%ws_an
      IF (model%tw_active) CALL tw_settle_committed(model)
      RETURN
    END IF
    ! In-band Dirichlet on a mass copy + full-size banded solve. The free RHS is
    ! f_ext-f_int-M*a_prescribed; fixed RHS slots remain zero for the Dirichlet solve.
    model%ws_Keffb = model%ws_Msumb
    CALL band_matvec(model%ws_Msumb, model%ws_an, model%ws_inert)
    model%ws_dq = -model%ws_R - model%ws_inert
    CALL transform_rigid_vector_to_local(model, rigid_basis, model%ws_dq)
    CALL transform_rigid_band(model, rigid_basis, model%ws_Keffb)
    CALL dirichlet_band(model%ws_Keffb, model%solve_mask)
    DO i = 1, model%ndof
      IF (.NOT. model%solve_mask(i)) model%ws_dq(i) = CD_ZERO
    END DO
    CALL CD_Factor_Banded(model%ws_Keffb, KL_D, KU_D, model%ws_ipiv, es, em2)
    IF (es == CD_LINALG_OK) THEN
      CALL CD_Solve_Factored_Banded(model%ws_Keffb, KL_D, KU_D, model%ws_ipiv, model%ws_dq, es, em2)
    END IF
    IF (es /= CD_LINALG_OK) THEN
      ErrStat = CD_HCDYN_NOCONVERGE; ErrMsg = 'solve_consistent_acceleration: solve failed: '//TRIM(em2); RETURN
    END IF
    CALL transform_rigid_vector_to_global(model, rigid_basis, model%ws_dq)
    model%a = model%ws_dq + model%ws_an
    IF (has_pres) model%a(pres_dofs) = pres_a
    IF (model%tw_active) CALL tw_settle_committed(model)
  END SUBROUTINE solve_consistent_acceleration

  SUBROUTINE scatter12_band(abg, Ke, e)
    !! Scatter a 12x12 element matrix into LAPACK general-band storage for element e
    !! (entry (gi, gj) at abg(KL_D + KU_D + 1 + gi - gj, gj); the chain connectivity
    !! keeps |gi - gj| <= 11 = KU_D, so every entry is in band by construction).
    !! The element's DOFs are the 12 consecutive global DOFs from 6(e - 1) + 1 (elem_gdof), so
    !! column b of Ke lands in one contiguous run of band column 6(e - 1) + b.
    REAL(wp), INTENT(INOUT) :: abg(:, :)
    REAL(wp), INTENT(IN) :: Ke(12, 12)
    INTEGER, INTENT(IN) :: e
    INTEGER :: a, b, gj, row0
    DO b = 1, 12
      gj = 6*(e - 1) + b
      row0 = KL_D + KU_D + 1 - b
      DO a = 1, 12
        abg(row0 + a, gj) = abg(row0 + a, gj) + Ke(a, b)
      END DO
    END DO
  END SUBROUTINE scatter12_band

  PURE SUBROUTINE band_matvec(abg, x, y)
    !! y = A x for A in the module's LAPACK general-band layout.
    REAL(wp), CONTIGUOUS, INTENT(IN) :: abg(:, :), x(:)
    REAL(wp), CONTIGUOUS, INTENT(OUT) :: y(:)
    INTEGER :: i, j, n
    n = SIZE(x)
    y = CD_ZERO
    DO j = 1, n
      DO i = MAX(1, j - KU_D), MIN(n, j + KL_D)
        y(i) = y(i) + abg(KL_D + KU_D + 1 + i - j, j)*x(j)
      END DO
    END DO
  END SUBROUTINE band_matvec

  PURE SUBROUTINE dirichlet_band(abg, freemask)
    !! Apply Dirichlet conditions in band form: zero each fixed DOF's row and column
    !! within the band and set a unit diagonal, so the full-size banded solve returns
    !! exactly zero update at every fixed DOF (with a zero RHS slot).
    REAL(wp), CONTIGUOUS, INTENT(INOUT) :: abg(:, :)
    LOGICAL, INTENT(IN) :: freemask(:)
    INTEGER :: j, gi, gj, n
    n = SIZE(freemask)
    DO j = 1, n
      IF (freemask(j)) CYCLE
      DO gi = MAX(1, j - KL_D), MIN(n, j + KU_D)          ! column j entries (rows gi)
        abg(KL_D + KU_D + 1 + gi - j, j) = CD_ZERO
      END DO
      DO gj = MAX(1, j - KU_D), MIN(n, j + KL_D)          ! row j entries (columns gj)
        abg(KL_D + KU_D + 1 + j - gj, gj) = CD_ZERO
      END DO
      abg(KL_D + KU_D + 1, j) = CD_ONE
    END DO
  END SUBROUTINE dirichlet_band

  SUBROUTINE gather_elem(model, e, qe)
    !! Gather element e's 12 DOFs from the model state.
    TYPE(CD_HermiteCableDynType), INTENT(IN) :: model
    INTEGER, INTENT(IN) :: e
    REAL(wp), INTENT(OUT) :: qe(12)
    qe(1:3) = model%q(6*(e - 1) + 1:6*(e - 1) + 3)
    qe(4:6) = model%q(6*(e - 1) + 4:6*(e - 1) + 6)
    qe(7:9) = model%q(6*e + 1:6*e + 3)
    qe(10:12) = model%q(6*e + 4:6*e + 6)
  END SUBROUTINE gather_elem

  PURE INTEGER FUNCTION elem_gdof(e, a) RESULT(g)
    !! Map element-local DOF a (1..12) of element e to the global DOF index.
    INTEGER, INTENT(IN) :: e, a
    IF (a <= 6) THEN
      g = 6*(e - 1) + a
    ELSE
      g = 6*e + (a - 6)
    END IF
  END FUNCTION elem_gdof

END MODULE CableDyn_HermiteCableDynamic
