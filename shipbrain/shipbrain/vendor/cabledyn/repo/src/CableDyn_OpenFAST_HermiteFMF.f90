! File: src/CableDyn_OpenFAST_HermiteFMF.f90
! SPDX-License-Identifier: Apache-2.0
! Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
MODULE CableDyn_OpenFAST_HermiteFMF
  !! OpenFAST-style module-form lifecycle (Init / UpdateStates / CalcOutput / End) over the
  !! Hermite finite-EI DYNAMIC POWER CABLE (CableDyn_HermiteCableDynamic) -- the coupling
  !! boundary a floating-platform solver drives:
  !!
  !!   kinematics IN : the coupled endpoint's position / velocity / acceleration and the
  !!                   parent orientation / angular velocity / angular acceleration at
  !!                   t_{n+1} (the platform hang-off, prescribed through the
  !!                   generalised-alpha step's exact boundary machinery);
  !!   loads OUT     : the force the cable exerts ON the platform at that endpoint (the
  !!                   constraint reaction -[M a + f_int - f_ext] at the coupled node's
  !!                   translational DOFs, evaluated at the committed state).
  !!
  !! This is the finite-EI counterpart of the EI=0 mooring shell (CableDyn_OpenFAST_FMF):
  !! the same lifecycle contract, carried by the bending-cable element the lazy-wave
  !! geometry needs. Solver controls (Newton budget, tolerance) freeze at Init, mirroring
  !! the MoorDyn-F parameter pattern; the optional Morison drag / added-mass / wave
  !! configuration passes through the underlying model's setters before the first step.
  !! One line per module instance (the multi-line registry aggregation is the OpenFAST
  !! integration layer's job, out of scope here).
  USE CableDyn_Precision, ONLY: wp, CD_ZERO, CD_ONE, CD_All_Finite, CD_Is_Finite
  USE CableDyn_HermiteCableDynamic, ONLY: CD_HermiteCableDynType, CD_HermiteCable_Dyn_Init, &
                                          CD_HermiteCable_Dyn_Set_Drag, CD_HermiteCable_Dyn_Set_AddedMass, &
                                          CD_HermiteCable_Dyn_Set_Axial_Damping, &
                                          CD_HermiteCable_Dyn_Set_Waves, CD_HermiteCable_Dyn_Set_Held_Fluid, &
                                          CD_HermiteCable_Dyn_Set_Contact, CD_HermiteCable_Dyn_Set_Attachments, &
                                          CD_HermiteCable_Dyn_Set_EndConnection, &
                                          CD_HermiteCable_Dyn_Recompute_Acceleration, &
                                          CD_HermiteCable_Dyn_Set_ModifiedNewton, &
                                          CD_HermiteCable_Dyn_Set_Tensile_Safety, &
                                          CD_HermiteCable_Dyn_Set_Tensile_Monitor, &
                                          CD_HermiteCable_Dyn_Get_Tensile_Diagnostics, &
                                          CD_HermiteCable_Dyn_Get_Recovery_Diagnostics, &
                                          CD_HermiteCable_Dyn_Step, CD_HermiteCable_Dyn_Step_Recovering, &
                                          CD_HermiteCable_Dyn_Reaction, &
                                          CD_HermiteCable_Dyn_EndConnection_Moment, &
                                          CD_HermiteCable_Dyn_Curvature, CD_HermiteCable_Dyn_Curvature_Exact, &
                                          CD_HermiteCable_Dyn_Section_Curvature, &
                                          CD_HermiteCable_Dyn_Snapshot, CD_HermiteCable_Dyn_Restore, &
                                          CD_HermiteCable_Dyn_End, CD_HCDYN_OK, &
                                          CD_HermiteCable_Dyn_Set_Torsion, CD_HermiteCable_Dyn_Set_Torsion_Drive, &
                                          CD_HermiteCable_Dyn_Set_Torsion_Frames, &
                                          CD_HermiteCable_Dyn_Set_SegmentLength, &
                                          CD_HermiteCable_Dyn_Twist_Mirror_Size, CD_HermiteCable_Dyn_Twist_Pack, &
                                          CD_HermiteCable_Dyn_Twist_Unpack, CD_HermiteCable_Dyn_Twist_Check
  USE CableDyn_HermiteTorsion, ONLY: CD_HermiteTorsionType, CD_HermiteTorsion_Compliance, CD_HermiteTorsion_Line, &
                                     CD_HermiteTorsion_Unwrap, CD_HTORS_OK, CD_HTORS_MAX_STEP
  USE CableDyn_HermiteCable, ONLY: CD_HermiteCable_Shapes
  USE CableDyn_EndConnection, ONLY: CD_EndConn_Project, CD_ENDCONN_OK, CD_ENDCONN_BADINPUT, &
                                    CD_ENDCONN_PINNED, CD_ENDCONN_FINITE, CD_ENDCONN_RIGID
  USE CableDyn_Bathymetry, ONLY: CD_BathymetryType
  IMPLICIT NONE
  PRIVATE

  PUBLIC :: CD_HFMF_ModuleType
  PUBLIC :: CD_HFMF_Init
  PUBLIC :: CD_HFMF_Set_Drag
  PUBLIC :: CD_HFMF_Set_Axial_Damping
  PUBLIC :: CD_HFMF_Set_ModifiedNewton
  PUBLIC :: CD_HFMF_Set_Tensile_Safety
  PUBLIC :: CD_HFMF_Set_Tensile_Monitor
  PUBLIC :: CD_HFMF_Get_Tensile_Diagnostics
  PUBLIC :: CD_HFMF_Get_Recovery_Diagnostics
  PUBLIC :: CD_HFMF_Set_Recovery_Max_Substeps
  PUBLIC :: CD_HFMF_Set_AddedMass
  PUBLIC :: CD_HFMF_Set_Waves
  PUBLIC :: CD_HFMF_Set_Held_Fluid
  PUBLIC :: CD_HFMF_Set_Contact
  PUBLIC :: CD_HFMF_Set_SegmentLength
  PUBLIC :: CD_HFMF_Set_Attachments
  PUBLIC :: CD_HFMF_Set_EndConnection
  PUBLIC :: CD_HFMF_Set_Torsion
  PUBLIC :: CD_HFMF_Refresh_Acceleration
  PUBLIC :: CD_HFMF_Twist_Lin_Count, CD_HFMF_Twist_Lin_Slots, CD_HFMF_Set_Twist_Frame_Rates
  PUBLIC :: CD_HFMF_NNodes
  PUBLIC :: CD_HFMF_GetNodePositions
  PUBLIC :: CD_HFMF_UpdateStates
  PUBLIC :: CD_HFMF_Snapshot
  PUBLIC :: CD_HFMF_Restore
  PUBLIC :: CD_HFMF_PreflightCoupledKinematics
  PUBLIC :: CD_HFMF_SetCoupledKinematics
  PUBLIC :: CD_HFMF_GetCoupledKinematics
  PUBLIC :: CD_HFMF_Set_Moving_End_B, CD_HFMF_GetEndBKinematics
  PUBLIC :: CD_HFMF_CalcOutput
  PUBLIC :: CD_HFMF_Curvature, CD_HFMF_Curvature_Exact
  PUBLIC :: CD_HFMF_Set_Section_Reference, CD_HFMF_Section_Curvature
  PUBLIC :: CD_HFMF_MinSpanZ
  PUBLIC :: CD_HFMF_MirrorSize
  PUBLIC :: CD_HFMF_FrictionMirrorSize
  PUBLIC :: CD_HFMF_BoundaryMirrorSize
  PUBLIC :: CD_HFMF_ForceMirrorSize
  PUBLIC :: CD_HFMF_TorsionMirrorSize
  PUBLIC :: CD_HFMF_VIVMirrorSize
  PUBLIC :: CD_HFMF_PackMirror
  PUBLIC :: CD_HFMF_UnpackMirror
  PUBLIC :: CD_HFMF_End
  INTEGER, PARAMETER, PUBLIC :: CD_HFMF_OK = 0, CD_HFMF_BADINPUT = 1, CD_HFMF_SOLVEFAIL = 2

  TYPE :: CD_HFMF_ModuleType
    !! Module-form owner of one Hermite dynamic power cable behind the FMF lifecycle.
    TYPE(CD_HermiteCableDynType) :: line
    INTEGER :: coupled_node = 0            ! node whose translations the platform drives
    INTEGER :: pdof(3) = 0                 ! that node's global r DOFs
    REAL(wp) :: dt = CD_ZERO               ! coupling step, frozen at Init
    INTEGER :: max_iter = 100              ! Newton budget per step, frozen at Init
    REAL(wp) :: tol = 1.0e-4_wp            ! Newton tolerance, frozen at Init
    INTEGER :: recovery_max_substeps = 1024 ! internal recovery cap; nominal coupling dt is unchanged
    ! Cable-frame heading (cos, sin of the rotation about +z from the CALLER's global
    ! frame to the cable's internal solve frame). The initial static builder uses a frame
    ! whose x-z plane contains the cable chord. Connection-enabled deck models leave the
    ! out-of-plane dynamic DOFs free so a rotating parent can produce a 3D response.
    ! An azimuthal cable stores its heading here and the FMF boundary rotates
    ! kinematics IN (global -> local) and loads OUT (local -> global), so every caller
    ! works purely in global coordinates. Identity (1, 0) leaves all paths bit-for-bit.
    REAL(wp) :: frame_c = 1.0_wp, frame_s = 0.0_wp
    ! The range of the cable's tangent azimuth channels: (-180, 180] when set, otherwise
    ! [0, 360) (the deck line's, set by the deck driver that builds the cable).
    LOGICAL :: azimuth_signed = .FALSE.
    ! A finite or rigid connection at the coupled endpoint is attached to the host, so its
    ! no-moment direction is expressed in parent axes and rotates with the input
    ! mesh orientation. The DCM convention is OpenFAST's global-to-parent matrix.
    LOGICAL :: has_parent_endconn = .FALSE.
    INTEGER :: parent_endconn_index = 0
    REAL(wp) :: parent_endconn_d0(3) = CD_ZERO
    REAL(wp) :: parent_dcm(3, 3) = RESHAPE([CD_ONE, CD_ZERO, CD_ZERO, &
                                            CD_ZERO, CD_ONE, CD_ZERO, &
                                            CD_ZERO, CD_ZERO, CD_ONE], [3, 3])
    ! OpenFAST supplies mesh angular velocity and acceleration in global axes.
    ! Retain them with the parent orientation so an exact rigid connection can
    ! transport its tangent q/v/a consistently through output probes, rewinds,
    ! and the next implicit step.
    REAL(wp) :: parent_omega(3) = CD_ZERO
    REAL(wp) :: parent_alpha(3) = CD_ZERO
    REAL(wp) :: snap_parent_dcm(3, 3) = RESHAPE([CD_ONE, CD_ZERO, CD_ZERO, &
                                                 CD_ZERO, CD_ONE, CD_ZERO, &
                                                 CD_ZERO, CD_ZERO, CD_ONE], [3, 3])
    REAL(wp) :: snap_parent_omega(3) = CD_ZERO
    REAL(wp) :: snap_parent_alpha(3) = CD_ZERO
    ! Condensed torsion with a parent-attached coupled end (CD_HFMF_Set_Torsion with
    ! coupled_frame_parent): that end's torsion frame (director, reference normal) in parent
    ! axes, turned with the parent orientation at every step, also at a bending-pinned end.
    ! tors_index is the coupled end (1 or 2).
    LOGICAL :: tors_parent = .FALSE.
    INTEGER :: tors_index = 0
    REAL(wp) :: tors_frame_parent(3, 2) = CD_ZERO
    ! A second host-driven end (CD_HFMF_Set_Moving_End_B): internal node 1 (deck End B), whose
    ! three translations the host prescribes like the coupled node's -- a line between two moving
    ! points (a cable shared by two floaters, a line between two bodies). Its parent frame, a
    ! parent-attached end connection and a parent-attached torsion frame are the End B twins of
    ! the coupled end's fields above (end index 1). A moving End B the host leaves exactly at rest
    ! (its committed position, zero velocity and acceleration, from rest) is held as a Fixed End B
    ! is, so a Fixed End B and a moving one that does not move march bit for bit alike.
    LOGICAL :: moving_b = .FALSE.
    INTEGER :: pdof_b(3) = 0
    LOGICAL :: has_parent_endconn_b = .FALSE.
    REAL(wp) :: parent_endconn_d0_b(3) = CD_ZERO
    REAL(wp) :: parent_dcm_b(3, 3) = RESHAPE([CD_ONE, CD_ZERO, CD_ZERO, &
                                              CD_ZERO, CD_ONE, CD_ZERO, &
                                              CD_ZERO, CD_ZERO, CD_ONE], [3, 3])
    REAL(wp) :: parent_omega_b(3) = CD_ZERO
    REAL(wp) :: parent_alpha_b(3) = CD_ZERO
    REAL(wp) :: snap_parent_dcm_b(3, 3) = RESHAPE([CD_ONE, CD_ZERO, CD_ZERO, &
                                                   CD_ZERO, CD_ONE, CD_ZERO, &
                                                   CD_ZERO, CD_ZERO, CD_ONE], [3, 3])
    REAL(wp) :: snap_parent_omega_b(3) = CD_ZERO
    REAL(wp) :: snap_parent_alpha_b(3) = CD_ZERO
    LOGICAL :: tors_parent_b = .FALSE.
    REAL(wp) :: tors_frame_parent_b(3, 2) = CD_ZERO
    ! Deck node -> model node map of a line whose mesh the static solve refined: deck_node(J) is
    ! the public node (End A = 1) of the final mesh at the reference arc of deck node J (1 + the
    ! total NumSegs of the deck sections, End A first), 0 if no mesh node lies there. Unallocated
    ! when the mesh is the deck mesh. The node output channels (Ten<L>N<J>, ...) read deck nodes.
    INTEGER, ALLOCATABLE :: deck_node(:)
    ! The cross-section reference of the CurvX/CurvY channels (CD_HFMF_Set_Section_Reference):
    ! the static start's normal at End A in global axes and, for an End A connected to a parent,
    ! in the parent's axes, so it turns with the parent.
    LOGICAL :: has_sect_ref = .FALSE.
    REAL(wp) :: sect_ref_global(3) = CD_ZERO
    REAL(wp) :: sect_ref_parent(3) = CD_ZERO
    ! the last CD_HFMF_Section_Curvature result and the state it was evaluated at (time, load
    ! epoch, reference, q, v, a and, in torsion, the end frames, Theta, Phi and the torque, which
    ! a host rotation turns without moving q): the channels of one output row share one evaluation
    LOGICAL :: sc_valid = .FALSE.
    INTEGER :: sc_epoch = -1
    REAL(wp) :: sc_t = CD_ZERO, sc_ref(3) = CD_ZERO, sc_tors(15) = CD_ZERO
    REAL(wp), ALLOCATABLE :: sc_q(:), sc_v(:), sc_a(:), sc_kx(:), sc_ky(:)
    LOGICAL :: initialized = .FALSE.
  END TYPE CD_HFMF_ModuleType

CONTAINS

  SUBROUTINE CD_HFMF_Init(self, l0, EA, EI, rho_a, w, q_static, fixed_dofs, seabed_z, kn, &
                          rho_inf, dt, coupled_node, ErrStat, ErrMsg, max_iter, tol, frame_cs, &
                          axial_quadrature_order, bending_quadrature_order)
    !! Initialise the module: build the Hermite dynamic model on the static-equilibrium
    !! seed and bind the coupled endpoint. The coupled node's THREE translational DOFs
    !! must be in fixed_dofs (the platform drives them; the module rejects a free coupled
    !! endpoint rather than silently pinning it). max_iter / tol default to the production
    !! step controls (100, 1e-4) and freeze at Init. frame_cs = (cos, sin) of the cable's
    !! frame heading about +z (see CD_HFMF_ModuleType): q_static and fixed_dofs are given
    !! in the LOCAL solve frame; the boundary rotates. Defaults to identity. Initialisation
    !! builds into a local CANDIDATE and replaces self only on success (the EI=0 FMF
    !! wrapper's pattern), so a failed re-initialisation preserves an already-working
    !! module instead of clobbering it on entry.
    TYPE(CD_HFMF_ModuleType), INTENT(INOUT) :: self
    REAL(wp), INTENT(IN) :: l0(:), EA(:), EI(:), rho_a(:), w(:), q_static(:)
    INTEGER, INTENT(IN) :: fixed_dofs(:)
    REAL(wp), INTENT(IN) :: seabed_z, kn, rho_inf, dt
    INTEGER, INTENT(IN) :: coupled_node
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    INTEGER, INTENT(IN), OPTIONAL :: max_iter
    REAL(wp), INTENT(IN), OPTIONAL :: tol
    REAL(wp), INTENT(IN), OPTIONAL :: frame_cs(2)
    INTEGER, INTENT(IN), OPTIONAL :: axial_quadrature_order, bending_quadrature_order
    TYPE(CD_HFMF_ModuleType) :: candidate
    INTEGER :: es, s, gd
    CHARACTER(1024) :: em

    ErrStat = CD_HFMF_OK; ErrMsg = ''
    IF (.NOT. CD_Is_Finite(dt) .OR. dt <= CD_ZERO) THEN
      CALL fail('dt must be finite and positive'); RETURN
    END IF
    IF (coupled_node < 1 .OR. coupled_node > SIZE(l0) + 1) THEN
      CALL fail('coupled_node out of range'); RETURN
    END IF
    DO s = 1, 3
      gd = 6*(coupled_node - 1) + s
      IF (.NOT. ANY(fixed_dofs == gd)) THEN
        CALL fail('the coupled node''s three translational DOFs must be in fixed_dofs'); RETURN
      END IF
    END DO
    IF (PRESENT(max_iter)) THEN
      IF (max_iter < 1) THEN
        CALL fail('max_iter must be >= 1'); RETURN
      END IF
      candidate%max_iter = max_iter
    END IF
    IF (PRESENT(tol)) THEN
      IF (.NOT. CD_Is_Finite(tol) .OR. tol <= CD_ZERO) THEN
        CALL fail('tol must be finite and positive'); RETURN
      END IF
      candidate%tol = tol
    END IF
    IF (PRESENT(frame_cs)) THEN
      IF (.NOT. CD_All_Finite(frame_cs)) THEN
        CALL fail('frame_cs must be finite'); RETURN
      END IF
      IF (ABS(frame_cs(1)**2 + frame_cs(2)**2 - 1.0_wp) > 1.0e-9_wp) THEN
        CALL fail('frame_cs must be a unit heading (cos^2 + sin^2 = 1)'); RETURN
      END IF
      candidate%frame_c = frame_cs(1)
      candidate%frame_s = frame_cs(2)
    END IF
    CALL CD_HermiteCable_Dyn_Init(candidate%line, l0, EA, EI, rho_a, w, q_static, fixed_dofs, &
                                  seabed_z, kn, rho_inf, es, em, axial_quadrature_order, &
                                  bending_quadrature_order)
    IF (es /= CD_HCDYN_OK) THEN
      CALL fail(TRIM(em)); RETURN
    END IF
    candidate%coupled_node = coupled_node
    DO s = 1, 3
      candidate%pdof(s) = 6*(coupled_node - 1) + s
    END DO
    candidate%dt = dt
    candidate%initialized = .TRUE.
    ! success: release any existing module, install the candidate, release its copy
    CALL CD_HFMF_End(self)
    self = candidate
    CALL CD_HFMF_End(candidate)

  CONTAINS
    SUBROUTINE fail(msg)
      CHARACTER(*), INTENT(IN) :: msg
      ErrStat = CD_HFMF_BADINPUT
      ErrMsg = 'CD_HFMF_Init: '//msg
    END SUBROUTINE fail
  END SUBROUTINE CD_HFMF_Init

  SUBROUTINE CD_HFMF_Set_Moving_End_B(self, ErrStat, ErrMsg)
    !! Make internal node 1 (deck End B) a second host-driven end: UpdateStates, SetCoupledKinematics
    !! and Preflight then take its kinematics (ub_*) beside the coupled node's, and the step
    !! prescribes the six end translations. The coupled node must be the last node (deck End A) and
    !! node 1's three translations must be held (in fixed_dofs), as Init requires of the coupled
    !! node. Call it after Init and before an End B parent connection or torsion frame is set.
    TYPE(CD_HFMF_ModuleType), INTENT(INOUT) :: self
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    ErrStat = CD_HFMF_BADINPUT
    IF (.NOT. self%initialized) THEN
      ErrMsg = 'CD_HFMF_Set_Moving_End_B: module not initialised'; RETURN
    END IF
    IF (self%coupled_node /= self%line%nn) THEN
      ErrMsg = 'CD_HFMF_Set_Moving_End_B: the coupled node must be the last node (End A)'; RETURN
    END IF
    IF (ANY(self%line%freemask(1:3))) THEN
      ErrMsg = 'CD_HFMF_Set_Moving_End_B: node 1''s three translational DOFs must be in fixed_dofs'; RETURN
    END IF
    self%moving_b = .TRUE.
    self%pdof_b = [1, 2, 3]
    ErrStat = CD_HFMF_OK
    ErrMsg = ''
  END SUBROUTINE CD_HFMF_Set_Moving_End_B

  SUBROUTINE CD_HFMF_Set_Drag(self, rho_w, diam, cdn, cdt, waterline_z, current, ErrStat, ErrMsg, gravity)
    !! Pass-through to the model's Morison drag configuration (call between Init and the
    !! first UpdateStates). The configuration also sets the free surface above which the
    !! line regains its displaced-water buoyancy; gravity (optional, default 9.80665 m/s^2)
    !! must be the value the submerged weight was formed with.
    TYPE(CD_HFMF_ModuleType), INTENT(INOUT) :: self
    REAL(wp), INTENT(IN) :: rho_w, diam(:), cdn(:), cdt(:), waterline_z, current(3)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    REAL(wp), INTENT(IN), OPTIONAL :: gravity
    INTEGER :: es
    CHARACTER(1024) :: em
    ErrStat = CD_HFMF_OK; ErrMsg = ''
    IF (.NOT. self%initialized) THEN
      ErrStat = CD_HFMF_BADINPUT; ErrMsg = 'CD_HFMF_Set_Drag: module not initialised'; RETURN
    END IF
    CALL CD_HermiteCable_Dyn_Set_Drag(self%line, rho_w, diam, cdn, cdt, waterline_z, current, es, em, &
                                      gravity=gravity)
    IF (es /= CD_HCDYN_OK) THEN
      ErrStat = CD_HFMF_BADINPUT; ErrMsg = 'CD_HFMF_Set_Drag: '//TRIM(em)
    END IF
  END SUBROUTINE CD_HFMF_Set_Drag

  SUBROUTINE CD_HFMF_Set_Attachments(self, node, mass, volume, cda, cdax, ca, rho_w, gravity, ErrStat, ErrMsg)
    !! Install discrete point attachments lumped at cable nodes (internal node order,
    !! anchor = node 1); see CD_HermiteCable_Dyn_Set_Attachments.
    TYPE(CD_HFMF_ModuleType), INTENT(INOUT) :: self
    INTEGER, INTENT(IN) :: node(:)
    REAL(wp), INTENT(IN) :: mass(:), volume(:), cda(:), cdax(:), ca(:), rho_w, gravity
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    INTEGER :: es
    CHARACTER(1024) :: em
    ErrStat = CD_HFMF_OK; ErrMsg = ''
    IF (.NOT. self%initialized) THEN
      ErrStat = CD_HFMF_BADINPUT; ErrMsg = 'CD_HFMF_Set_Attachments: module not initialised'; RETURN
    END IF
    CALL CD_HermiteCable_Dyn_Set_Attachments(self%line, node, mass, volume, cda, cdax, ca, rho_w, gravity, &
                                             es, em)
    IF (es /= CD_HCDYN_OK) THEN
      ErrStat = CD_HFMF_BADINPUT; ErrMsg = TRIM(em)
    END IF
  END SUBROUTINE CD_HFMF_Set_Attachments

  SUBROUTINE CD_HFMF_Set_Axial_Damping(self, BA, ErrStat, ErrMsg)
    !! Pass-through for resolved per-element axial Kelvin-Voigt coefficients [N s].
    TYPE(CD_HFMF_ModuleType), INTENT(INOUT) :: self
    REAL(wp), INTENT(IN) :: BA(:)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    INTEGER :: es
    CHARACTER(1024) :: em
    ErrStat = CD_HFMF_OK
    ErrMsg = ''
    IF (.NOT. self%initialized) THEN
      ErrStat = CD_HFMF_BADINPUT
      ErrMsg = 'CD_HFMF_Set_Axial_Damping: module not initialised'
      RETURN
    END IF
    CALL CD_HermiteCable_Dyn_Set_Axial_Damping(self%line, BA, es, em)
    IF (es /= CD_HCDYN_OK) THEN
      ErrStat = CD_HFMF_BADINPUT
      ErrMsg = 'CD_HFMF_Set_Axial_Damping: '//TRIM(em)
    END IF
  END SUBROUTINE CD_HFMF_Set_Axial_Damping

  SUBROUTINE CD_HFMF_Set_EndConnection(self, k_rot, d0_global, ErrStat, ErrMsg, &
                                       coupled_d0_parent, parent_orientation, connection_mode, &
                                       end_b_d0_parent, end_b_parent_orientation)
    !! Install pinned, finite-stiffness, or exact rigid end connections. End order follows the internal
    !! anchor-to-fairlead model: column 1 is node 1 and column 2 is the final node.
    !! Preferred directions arrive in the caller's global frame and are rotated
    !! into the cable solve frame here. A moving End B (CD_HFMF_Set_Moving_End_B) may have its
    !! direction given in its own parent's axes (end_b_d0_parent with end_b_parent_orientation,
    !! the global-to-parent DCM at the static state): it then turns with End B's orientation.
    TYPE(CD_HFMF_ModuleType), INTENT(INOUT) :: self
    REAL(wp), INTENT(IN) :: k_rot(2), d0_global(3, 2)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    REAL(wp), INTENT(IN), OPTIONAL :: coupled_d0_parent(3), parent_orientation(3, 3)
    INTEGER, INTENT(IN), OPTIONAL :: connection_mode(2)
    REAL(wp), INTENT(IN), OPTIONAL :: end_b_d0_parent(3), end_b_parent_orientation(3, 3)
    INTEGER :: es, iend, coupled_iend, mode_eff(2)
    LOGICAL :: endpoint_connected
    REAL(wp) :: d0_local(3, 2)
    REAL(wp) :: parent_d0(3), parent_d0_norm, dcm(3, 3), parent_d0_b(3), dcm_b(3, 3)
    CHARACTER(1024) :: em

    ErrStat = CD_HFMF_OK
    ErrMsg = ''
    IF (.NOT. self%initialized) THEN
      ErrStat = CD_HFMF_BADINPUT
      ErrMsg = 'CD_HFMF_Set_EndConnection: module not initialised'
      RETURN
    END IF
    IF (PRESENT(coupled_d0_parent) .NEQV. PRESENT(parent_orientation)) THEN
      ErrStat = CD_HFMF_BADINPUT
      ErrMsg = 'CD_HFMF_Set_EndConnection: coupled_d0_parent and parent_orientation must be supplied together'
      RETURN
    END IF
    coupled_iend = 0
    IF (self%coupled_node == 1) coupled_iend = 1
    IF (self%coupled_node == self%line%nn) coupled_iend = 2
    dcm = identity_dcm()
    parent_d0 = CD_ZERO
    IF (PRESENT(connection_mode)) THEN
      mode_eff = connection_mode
    ELSE
      WHERE (k_rot > CD_ZERO)
        mode_eff = CD_ENDCONN_FINITE
      ELSEWHERE
        mode_eff = CD_ENDCONN_PINNED
      END WHERE
    END IF
    IF (PRESENT(coupled_d0_parent)) THEN
      ! Nested tests: Fortran does not short-circuit .OR., so mode_eff(0) must not be read.
      endpoint_connected = coupled_iend /= 0
      IF (endpoint_connected) endpoint_connected = mode_eff(coupled_iend) /= CD_ENDCONN_PINNED
      IF (.NOT. endpoint_connected) THEN
        ErrStat = CD_HFMF_BADINPUT
        ErrMsg = 'CD_HFMF_Set_EndConnection: parent-relative direction requires a connected coupled endpoint'
        RETURN
      END IF
      IF (.NOT. valid_parent_dcm(parent_orientation)) THEN
        ErrStat = CD_HFMF_BADINPUT
        ErrMsg = 'CD_HFMF_Set_EndConnection: parent_orientation must be a finite proper orthogonal DCM'
        RETURN
      END IF
      IF (.NOT. CD_All_Finite(coupled_d0_parent)) THEN
        ErrStat = CD_HFMF_BADINPUT
        ErrMsg = 'CD_HFMF_Set_EndConnection: coupled parent direction must be finite'
        RETURN
      END IF
      parent_d0_norm = SQRT(DOT_PRODUCT(coupled_d0_parent, coupled_d0_parent))
      IF (.NOT. CD_Is_Finite(parent_d0_norm) .OR. parent_d0_norm <= SQRT(TINY(CD_ONE))) THEN
        ErrStat = CD_HFMF_BADINPUT
        ErrMsg = 'CD_HFMF_Set_EndConnection: coupled parent direction must be non-null'
        RETURN
      END IF
      dcm = parent_orientation
      parent_d0 = coupled_d0_parent/parent_d0_norm
    END IF
    IF (PRESENT(end_b_d0_parent) .NEQV. PRESENT(end_b_parent_orientation)) THEN
      ErrStat = CD_HFMF_BADINPUT
      ErrMsg = 'CD_HFMF_Set_EndConnection: end_b_d0_parent and end_b_parent_orientation must be supplied together'
      RETURN
    END IF
    dcm_b = identity_dcm()
    parent_d0_b = CD_ZERO
    IF (PRESENT(end_b_d0_parent)) THEN
      IF (.NOT. self%moving_b .OR. mode_eff(1) == CD_ENDCONN_PINNED) THEN
        ErrStat = CD_HFMF_BADINPUT
        ErrMsg = 'CD_HFMF_Set_EndConnection: an End B parent-relative direction requires a moving, connected End B'
        RETURN
      END IF
      IF (.NOT. valid_parent_dcm(end_b_parent_orientation)) THEN
        ErrStat = CD_HFMF_BADINPUT
        ErrMsg = 'CD_HFMF_Set_EndConnection: end_b_parent_orientation must be a finite proper orthogonal DCM'
        RETURN
      END IF
      parent_d0_norm = SQRT(DOT_PRODUCT(end_b_d0_parent, end_b_d0_parent))
      IF (.NOT. CD_All_Finite(end_b_d0_parent) .OR. .NOT. CD_Is_Finite(parent_d0_norm) .OR. &
          parent_d0_norm <= SQRT(TINY(CD_ONE))) THEN
        ErrStat = CD_HFMF_BADINPUT
        ErrMsg = 'CD_HFMF_Set_EndConnection: the End B parent direction must be finite and non-null'
        RETURN
      END IF
      dcm_b = end_b_parent_orientation
      parent_d0_b = end_b_d0_parent/parent_d0_norm
    END IF
    DO iend = 1, 2
      d0_local(:, iend) = frame_to_local(self, d0_global(:, iend))
    END DO
    IF (PRESENT(coupled_d0_parent)) THEN
      d0_local(:, coupled_iend) = frame_to_local(self, MATMUL(TRANSPOSE(dcm), parent_d0))
    END IF
    IF (PRESENT(end_b_d0_parent)) d0_local(:, 1) = frame_to_local(self, MATMUL(TRANSPOSE(dcm_b), parent_d0_b))
    CALL CD_HermiteCable_Dyn_Set_EndConnection(self%line, k_rot, d0_local, es, em, &
                                               connection_mode=mode_eff)
    IF (es /= CD_HCDYN_OK) THEN
      ErrStat = CD_HFMF_BADINPUT
      ErrMsg = 'CD_HFMF_Set_EndConnection: '//TRIM(em)
      RETURN
    END IF
    self%has_parent_endconn = PRESENT(coupled_d0_parent)
    self%parent_endconn_index = 0
    self%parent_endconn_d0 = CD_ZERO
    self%parent_dcm = identity_dcm()
    self%parent_omega = CD_ZERO
    self%parent_alpha = CD_ZERO
    self%snap_parent_dcm = self%parent_dcm
    self%snap_parent_omega = CD_ZERO
    self%snap_parent_alpha = CD_ZERO
    IF (PRESENT(coupled_d0_parent)) THEN
      self%parent_endconn_index = coupled_iend
      self%parent_endconn_d0 = parent_d0
      self%parent_dcm = dcm
      self%snap_parent_dcm = dcm
    END IF
    self%has_parent_endconn_b = PRESENT(end_b_d0_parent)
    self%parent_endconn_d0_b = parent_d0_b
    self%parent_dcm_b = dcm_b
    self%parent_omega_b = CD_ZERO
    self%parent_alpha_b = CD_ZERO
    self%snap_parent_dcm_b = dcm_b
    self%snap_parent_omega_b = CD_ZERO
    self%snap_parent_alpha_b = CD_ZERO
  END SUBROUTINE CD_HFMF_Set_EndConnection

  SUBROUTINE CD_HFMF_Set_Torsion(self, torsion, ErrStat, ErrMsg, coupled_frame_parent, parent_orientation, &
                                 end_b_frame_parent, end_b_parent_orientation)
    !! Install the condensed torsion of the cable's converged static solve (end frames and GJ in
    !! the cable solve frame; see CD_HermiteCable_Dyn_Set_Torsion). CalcOutput then returns the
    !! end force and connection moment with the torque, and UpdateStates carries the torsion.
    !! coupled_frame_parent (columns: director, reference normal of the coupled end's torsion
    !! frame in parent axes) with parent_orientation (the global-to-parent DCM at which the static
    !! frame was taken) attach that frame to the parent: UpdateStates then turns it with
    !! u_orientation, for any bending connection (also a pinned one). The parent orientation must
    !! agree with that of a parent-relative end connection, and the frame with the static one.
    !! end_b_frame_parent with end_b_parent_orientation attach a moving End B's torsion frame (end 1)
    !! to its own parent in the same way: both end frames then turn with their parents.
    TYPE(CD_HFMF_ModuleType), INTENT(INOUT) :: self
    TYPE(CD_HermiteTorsionType), INTENT(IN) :: torsion
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    REAL(wp), INTENT(IN), OPTIONAL :: coupled_frame_parent(3, 2), parent_orientation(3, 3)
    REAL(wp), INTENT(IN), OPTIONAL :: end_b_frame_parent(3, 2), end_b_parent_orientation(3, 3)
    INTEGER :: es, ci
    REAL(wp) :: dl(3), nl(3)
    CHARACTER(1024) :: em
    ErrStat = CD_HFMF_OK
    ErrMsg = ''
    IF (.NOT. self%initialized) THEN
      ErrStat = CD_HFMF_BADINPUT
      ErrMsg = 'CD_HFMF_Set_Torsion: module not initialised'
      RETURN
    END IF
    ErrStat = CD_HFMF_BADINPUT
    IF (PRESENT(coupled_frame_parent) .NEQV. PRESENT(parent_orientation)) THEN
      ErrMsg = 'CD_HFMF_Set_Torsion: coupled_frame_parent and parent_orientation must be supplied together'
      RETURN
    END IF
    ci = 0
    IF (self%coupled_node == 1) ci = 1
    IF (self%coupled_node == self%line%nn) ci = 2
    IF (PRESENT(coupled_frame_parent) .AND. torsion%active) THEN
      IF (ci == 0) THEN
        ErrMsg = 'CD_HFMF_Set_Torsion: a parent torsion frame needs the coupled node at a line end'
        RETURN
      END IF
      IF (.NOT. valid_parent_dcm(parent_orientation)) THEN
        ErrMsg = 'CD_HFMF_Set_Torsion: parent_orientation must be a finite proper orthogonal DCM'
        RETURN
      END IF
      IF (.NOT. CD_All_Finite(RESHAPE(coupled_frame_parent, [6]))) THEN
        ErrMsg = 'CD_HFMF_Set_Torsion: the parent torsion frame must be finite'
        RETURN
      END IF
      IF (ABS(NORM2(coupled_frame_parent(:, 1)) - CD_ONE) > 1.0e-8_wp .OR. &
          ABS(NORM2(coupled_frame_parent(:, 2)) - CD_ONE) > 1.0e-8_wp .OR. &
          ABS(DOT_PRODUCT(coupled_frame_parent(:, 1), coupled_frame_parent(:, 2))) > 1.0e-8_wp) THEN
        ErrMsg = 'CD_HFMF_Set_Torsion: the parent torsion frame must be orthonormal'
        RETURN
      END IF
      IF (self%has_parent_endconn) THEN
        IF (MAXVAL(ABS(parent_orientation - self%parent_dcm)) > 1.0e-10_wp) THEN
          ErrMsg = 'CD_HFMF_Set_Torsion: parent_orientation differs from the end connection''s'
          RETURN
        END IF
      END IF
      dl = frame_to_local(self, MATMUL(TRANSPOSE(parent_orientation), coupled_frame_parent(:, 1)))
      nl = frame_to_local(self, MATMUL(TRANSPOSE(parent_orientation), coupled_frame_parent(:, 2)))
      IF (NORM2(dl - torsion%ends(:, 2*ci - 1)) > 1.0e-8_wp .OR. NORM2(nl - torsion%ends(:, 2*ci)) > 1.0e-8_wp) THEN
        ErrMsg = 'CD_HFMF_Set_Torsion: the parent torsion frame differs from the static end frame'
        RETURN
      END IF
    END IF
    IF (PRESENT(end_b_frame_parent) .NEQV. PRESENT(end_b_parent_orientation)) THEN
      ErrMsg = 'CD_HFMF_Set_Torsion: end_b_frame_parent and end_b_parent_orientation must be supplied together'
      RETURN
    END IF
    IF (PRESENT(end_b_frame_parent) .AND. torsion%active) THEN
      IF (.NOT. self%moving_b) THEN
        ErrMsg = 'CD_HFMF_Set_Torsion: an End B parent torsion frame needs a moving End B'
        RETURN
      END IF
      IF (.NOT. valid_parent_dcm(end_b_parent_orientation)) THEN
        ErrMsg = 'CD_HFMF_Set_Torsion: end_b_parent_orientation must be a finite proper orthogonal DCM'
        RETURN
      END IF
      IF (.NOT. CD_All_Finite(RESHAPE(end_b_frame_parent, [6]))) THEN
        ErrMsg = 'CD_HFMF_Set_Torsion: the End B parent torsion frame must be finite'
        RETURN
      END IF
      IF (ABS(NORM2(end_b_frame_parent(:, 1)) - CD_ONE) > 1.0e-8_wp .OR. &
          ABS(NORM2(end_b_frame_parent(:, 2)) - CD_ONE) > 1.0e-8_wp .OR. &
          ABS(DOT_PRODUCT(end_b_frame_parent(:, 1), end_b_frame_parent(:, 2))) > 1.0e-8_wp) THEN
        ErrMsg = 'CD_HFMF_Set_Torsion: the End B parent torsion frame must be orthonormal'
        RETURN
      END IF
      IF (self%has_parent_endconn_b) THEN
        IF (MAXVAL(ABS(end_b_parent_orientation - self%parent_dcm_b)) > 1.0e-10_wp) THEN
          ErrMsg = 'CD_HFMF_Set_Torsion: end_b_parent_orientation differs from the End B connection''s'
          RETURN
        END IF
      END IF
      dl = frame_to_local(self, MATMUL(TRANSPOSE(end_b_parent_orientation), end_b_frame_parent(:, 1)))
      nl = frame_to_local(self, MATMUL(TRANSPOSE(end_b_parent_orientation), end_b_frame_parent(:, 2)))
      IF (NORM2(dl - torsion%ends(:, 1)) > 1.0e-8_wp .OR. NORM2(nl - torsion%ends(:, 2)) > 1.0e-8_wp) THEN
        ErrMsg = 'CD_HFMF_Set_Torsion: the End B parent torsion frame differs from the static end frame'
        RETURN
      END IF
    END IF
    CALL CD_HermiteCable_Dyn_Set_Torsion(self%line, torsion, es, em)
    IF (es /= CD_HCDYN_OK) THEN
      ErrMsg = 'CD_HFMF_Set_Torsion: '//TRIM(em)
      RETURN
    END IF
    ErrStat = CD_HFMF_OK
    ErrMsg = ''
    self%tors_parent = .FALSE.
    self%tors_index = 0
    self%tors_frame_parent = CD_ZERO
    IF (PRESENT(coupled_frame_parent) .AND. torsion%active) THEN
      self%tors_parent = .TRUE.
      self%tors_index = ci
      self%tors_frame_parent = coupled_frame_parent
      IF (.NOT. self%has_parent_endconn) THEN
        self%parent_dcm = parent_orientation
        self%snap_parent_dcm = parent_orientation
        self%parent_omega = CD_ZERO
        self%parent_alpha = CD_ZERO
        self%snap_parent_omega = CD_ZERO
        self%snap_parent_alpha = CD_ZERO
      END IF
    END IF
    self%tors_parent_b = .FALSE.
    self%tors_frame_parent_b = CD_ZERO
    IF (PRESENT(end_b_frame_parent) .AND. torsion%active) THEN
      self%tors_parent_b = .TRUE.
      self%tors_frame_parent_b = end_b_frame_parent
      IF (.NOT. self%has_parent_endconn_b) THEN
        self%parent_dcm_b = end_b_parent_orientation
        self%snap_parent_dcm_b = end_b_parent_orientation
        self%parent_omega_b = CD_ZERO
        self%parent_alpha_b = CD_ZERO
        self%snap_parent_omega_b = CD_ZERO
        self%snap_parent_alpha_b = CD_ZERO
      END IF
    END IF
  END SUBROUTINE CD_HFMF_Set_Torsion

  SUBROUTINE CD_HFMF_Set_ModifiedNewton(self, enabled, ErrStat, ErrMsg)
    !! Pass-through to the model's modified-Newton (within-step tangent reuse) switch:
    !! one effective-tangent assembly + factorization per dynamic step, contraction-gated
    !! with a stale-direction refresh (see CD_HermiteCable_Dyn_Set_ModifiedNewton).
    TYPE(CD_HFMF_ModuleType), INTENT(INOUT) :: self
    LOGICAL, INTENT(IN) :: enabled
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    INTEGER :: es
    CHARACTER(1024) :: em
    ErrStat = CD_HFMF_OK; ErrMsg = ''
    IF (.NOT. self%initialized) THEN
      ErrStat = CD_HFMF_BADINPUT; ErrMsg = 'CD_HFMF_Set_ModifiedNewton: module not initialised'; RETURN
    END IF
    CALL CD_HermiteCable_Dyn_Set_ModifiedNewton(self%line, enabled, es, em)
    IF (es /= CD_HCDYN_OK) THEN
      ErrStat = CD_HFMF_BADINPUT; ErrMsg = 'CD_HFMF_Set_ModifiedNewton: '//TRIM(em)
    END IF
  END SUBROUTINE CD_HFMF_Set_ModifiedNewton

  SUBROUTINE CD_HFMF_Set_Tensile_Safety(self, enabled, ErrStat, ErrMsg)
    TYPE(CD_HFMF_ModuleType), INTENT(INOUT) :: self
    LOGICAL, INTENT(IN) :: enabled
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    INTEGER :: es
    CHARACTER(1024) :: em
    ErrStat = CD_HFMF_OK; ErrMsg = ''
    IF (.NOT. self%initialized) THEN
      ErrStat = CD_HFMF_BADINPUT; ErrMsg = 'CD_HFMF_Set_Tensile_Safety: module not initialised'; RETURN
    END IF
    CALL CD_HermiteCable_Dyn_Set_Tensile_Safety(self%line, enabled, es, em)
    IF (es /= CD_HCDYN_OK) THEN
      ErrStat = CD_HFMF_BADINPUT; ErrMsg = 'CD_HFMF_Set_Tensile_Safety: '//TRIM(em)
    END IF
  END SUBROUTINE CD_HFMF_Set_Tensile_Safety

  SUBROUTINE CD_HFMF_Set_Tensile_Monitor(self, mode, ErrStat, ErrMsg, strain_tolerance)
    TYPE(CD_HFMF_ModuleType), INTENT(INOUT) :: self
    INTEGER, INTENT(IN) :: mode
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    REAL(wp), INTENT(IN), OPTIONAL :: strain_tolerance
    INTEGER :: es
    CHARACTER(1024) :: em
    ErrStat = CD_HFMF_OK; ErrMsg = ''
    IF (.NOT. self%initialized) THEN
      ErrStat = CD_HFMF_BADINPUT; ErrMsg = 'CD_HFMF_Set_Tensile_Monitor: module not initialised'; RETURN
    END IF
    CALL CD_HermiteCable_Dyn_Set_Tensile_Monitor(self%line, mode, es, em, strain_tolerance)
    IF (es /= CD_HCDYN_OK) THEN
      ErrStat = CD_HFMF_BADINPUT; ErrMsg = 'CD_HFMF_Set_Tensile_Monitor: '//TRIM(em)
    END IF
  END SUBROUTINE CD_HFMF_Set_Tensile_Monitor

  SUBROUTINE CD_HFMF_Get_Tensile_Diagnostics(self, event_count, worst_force, worst_threshold, &
                                             worst_element, worst_xi, worst_time, ErrStat, ErrMsg)
    TYPE(CD_HFMF_ModuleType), INTENT(IN) :: self
    INTEGER, INTENT(OUT) :: event_count, worst_element, ErrStat
    REAL(wp), INTENT(OUT) :: worst_force, worst_threshold, worst_xi, worst_time
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    INTEGER :: es
    CHARACTER(1024) :: em
    IF (.NOT. self%initialized) THEN
      event_count = 0; worst_element = 0
      worst_force = CD_ZERO; worst_threshold = CD_ZERO; worst_xi = CD_ZERO; worst_time = CD_ZERO
      ErrStat = CD_HFMF_BADINPUT; ErrMsg = 'CD_HFMF_Get_Tensile_Diagnostics: module not initialised'; RETURN
    END IF
    CALL CD_HermiteCable_Dyn_Get_Tensile_Diagnostics(self%line, event_count, worst_force, &
                                                     worst_threshold, worst_element, worst_xi, worst_time, es, em)
    IF (es == CD_HCDYN_OK) THEN
      ErrStat = CD_HFMF_OK; ErrMsg = ''
    ELSE
      ErrStat = CD_HFMF_BADINPUT; ErrMsg = 'CD_HFMF_Get_Tensile_Diagnostics: '//TRIM(em)
    END IF
  END SUBROUTINE CD_HFMF_Get_Tensile_Diagnostics

  SUBROUTINE CD_HFMF_Get_Recovery_Diagnostics(self, event_count, max_substeps_used, ErrStat, ErrMsg)
    TYPE(CD_HFMF_ModuleType), INTENT(IN) :: self
    INTEGER, INTENT(OUT) :: event_count, max_substeps_used, ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    INTEGER :: es
    CHARACTER(1024) :: em
    IF (.NOT. self%initialized) THEN
      event_count = 0; max_substeps_used = 0
      ErrStat = CD_HFMF_BADINPUT; ErrMsg = 'CD_HFMF_Get_Recovery_Diagnostics: module not initialised'; RETURN
    END IF
    CALL CD_HermiteCable_Dyn_Get_Recovery_Diagnostics(self%line, event_count, max_substeps_used, es, em)
    IF (es == CD_HCDYN_OK) THEN
      ErrStat = CD_HFMF_OK; ErrMsg = ''
    ELSE
      ErrStat = CD_HFMF_BADINPUT; ErrMsg = 'CD_HFMF_Get_Recovery_Diagnostics: '//TRIM(em)
    END IF
  END SUBROUTINE CD_HFMF_Get_Recovery_Diagnostics

  SUBROUTINE CD_HFMF_Set_Recovery_Max_Substeps(self, max_substeps, ErrStat, ErrMsg)
    !! Set the maximum internal subdivisions attempted after a failed or under-resolved nominal
    !! coupling step. This does not change the host time grid or the committed interval endpoint.
    TYPE(CD_HFMF_ModuleType), INTENT(INOUT) :: self
    INTEGER, INTENT(IN) :: max_substeps
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    ErrStat = CD_HFMF_OK; ErrMsg = ''
    IF (.NOT. self%initialized) THEN
      ErrStat = CD_HFMF_BADINPUT
      ErrMsg = 'CD_HFMF_Set_Recovery_Max_Substeps: module not initialised'; RETURN
    END IF
    IF (max_substeps < 4 .OR. max_substeps > 65536) THEN
      ErrStat = CD_HFMF_BADINPUT
      ErrMsg = 'CD_HFMF_Set_Recovery_Max_Substeps: max_substeps must be in [4,65536]'; RETURN
    END IF
    self%recovery_max_substeps = max_substeps
  END SUBROUTINE CD_HFMF_Set_Recovery_Max_Substeps

  SUBROUTINE CD_HFMF_Set_AddedMass(self, rho_w, diam, can, cat, waterline_z, ErrStat, ErrMsg)
    !! Pass-through to the model's Morison added-mass configuration.
    TYPE(CD_HFMF_ModuleType), INTENT(INOUT) :: self
    REAL(wp), INTENT(IN) :: rho_w, diam(:), can(:), cat(:), waterline_z
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    INTEGER :: es
    CHARACTER(1024) :: em
    ErrStat = CD_HFMF_OK; ErrMsg = ''
    IF (.NOT. self%initialized) THEN
      ErrStat = CD_HFMF_BADINPUT; ErrMsg = 'CD_HFMF_Set_AddedMass: module not initialised'; RETURN
    END IF
    CALL CD_HermiteCable_Dyn_Set_AddedMass(self%line, rho_w, diam, can, cat, waterline_z, es, em)
    IF (es /= CD_HCDYN_OK) THEN
      ErrStat = CD_HFMF_BADINPUT; ErrMsg = 'CD_HFMF_Set_AddedMass: '//TRIM(em)
    END IF
  END SUBROUTINE CD_HFMF_Set_AddedMass

  SUBROUTINE CD_HFMF_Set_Waves(self, height, period, direction_deg, depth, gravity, ErrStat, ErrMsg)
    !! Pass-through to the model's regular (Airy) wave-field configuration.
    TYPE(CD_HFMF_ModuleType), INTENT(INOUT) :: self
    REAL(wp), INTENT(IN) :: height, period, direction_deg, depth, gravity
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    INTEGER :: es
    CHARACTER(1024) :: em
    ErrStat = CD_HFMF_OK; ErrMsg = ''
    IF (.NOT. self%initialized) THEN
      ErrStat = CD_HFMF_BADINPUT; ErrMsg = 'CD_HFMF_Set_Waves: module not initialised'; RETURN
    END IF
    CALL CD_HermiteCable_Dyn_Set_Waves(self%line, height, period, direction_deg, depth, gravity, es, em)
    IF (es /= CD_HCDYN_OK) THEN
      ErrStat = CD_HFMF_BADINPUT; ErrMsg = 'CD_HFMF_Set_Waves: '//TRIM(em)
    END IF
  END SUBROUTINE CD_HFMF_Set_Waves

  SUBROUTINE CD_HFMF_UpdateStates(self, u_pos, u_vel, u_acc, ErrStat, ErrMsg, u_orientation, &
                                  u_angular_velocity, u_angular_acceleration, u_twist, ub_pos, ub_vel, ub_acc, &
                                  ub_orientation, ub_angular_velocity, ub_angular_acceleration)
    !! Advance the cable one coupling step of dt with the coupled endpoint's kinematics
    !! at t_{n+1} prescribed to (u_pos, u_vel, u_acc) -- the FMF kinematics-in boundary.
    !! With condensed torsion, a parent-attached torsion frame (CD_HFMF_Set_Torsion) turns with
    !! the orientation, and u_twist [rad] sets the imposed twist Phi at t_{n+1} (held otherwise).
    !! A moving End B (CD_HFMF_Set_Moving_End_B) takes its own kinematics at t_{n+1}: ub_pos, ub_vel,
    !! ub_acc (required on such a cable, refused on any other) and, for an End B parent connection
    !! or torsion frame, its parent orientation and rates ub_orientation, ub_angular_*; the step then
    !! prescribes both ends' translations.
    TYPE(CD_HFMF_ModuleType), INTENT(INOUT) :: self
    REAL(wp), INTENT(IN) :: u_pos(3), u_vel(3), u_acc(3)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    REAL(wp), INTENT(IN), OPTIONAL :: u_orientation(3, 3)
    REAL(wp), INTENT(IN), OPTIONAL :: u_angular_velocity(3), u_angular_acceleration(3)
    REAL(wp), INTENT(IN), OPTIONAL :: u_twist
    REAL(wp), INTENT(IN), OPTIONAL :: ub_pos(3), ub_vel(3), ub_acc(3), ub_orientation(3, 3)
    REAL(wp), INTENT(IN), OPTIONAL :: ub_angular_velocity(3), ub_angular_acceleration(3)
    INTEGER :: es
    REAL(wp) :: tors_ends(3, 4), tors_phi
    REAL(wp) :: target_dcm(3, 3), target_d0(3, 2), target_omega(3), target_alpha(3)
    REAL(wp) :: target_d0_rate(3, 2), target_d0_acceleration(3, 2), omega_local(3), alpha_local(3)
    REAL(wp) :: target_dcm_b(3, 3), target_omega_b(3), target_alpha_b(3)
    ! both ends' prescribed translations (End A's, then End B's), fixed size: no allocation per step
    INTEGER :: pd(6)
    REAL(wp) :: pq(6), pv(6), pa(6)
    LOGICAL :: drive_b
    CHARACTER(1024) :: em
    ErrStat = CD_HFMF_OK; ErrMsg = ''
    IF (.NOT. self%initialized) THEN
      ErrStat = CD_HFMF_BADINPUT; ErrMsg = 'CD_HFMF_UpdateStates: module not initialised'; RETURN
    END IF
    IF (.NOT. (CD_All_Finite(u_pos) .AND. CD_All_Finite(u_vel) .AND. &
               CD_All_Finite(u_acc))) THEN
      ErrStat = CD_HFMF_BADINPUT; ErrMsg = 'CD_HFMF_UpdateStates: inputs must be finite'; RETURN
    END IF
    IF (PRESENT(u_angular_velocity) .NEQV. PRESENT(u_angular_acceleration)) THEN
      ErrStat = CD_HFMF_BADINPUT
      ErrMsg = 'CD_HFMF_UpdateStates: angular velocity and acceleration must be supplied together'
      RETURN
    END IF
    target_omega = CD_ZERO
    target_alpha = CD_ZERO
    IF (PRESENT(u_angular_velocity)) THEN
      IF (.NOT. (CD_All_Finite(u_angular_velocity) .AND. &
                 CD_All_Finite(u_angular_acceleration))) THEN
        ErrStat = CD_HFMF_BADINPUT
        ErrMsg = 'CD_HFMF_UpdateStates: angular kinematics must be finite'
        RETURN
      END IF
      target_omega = u_angular_velocity
      target_alpha = u_angular_acceleration
    END IF
    target_dcm = self%parent_dcm
    IF (PRESENT(u_orientation)) THEN
      IF (.NOT. valid_parent_dcm(u_orientation)) THEN
        ErrStat = CD_HFMF_BADINPUT
        ErrMsg = 'CD_HFMF_UpdateStates: orientation must be a finite proper orthogonal DCM'
        RETURN
      END IF
      target_dcm = u_orientation
    END IF
    CALL end_b_inputs(self, target_dcm_b, target_omega_b, target_alpha_b, ErrStat, em, ub_pos, ub_vel, ub_acc, &
                      ub_orientation, ub_angular_velocity, ub_angular_acceleration)
    IF (ErrStat /= CD_HFMF_OK) THEN
      ErrMsg = 'CD_HFMF_UpdateStates: '//TRIM(em); RETURN
    END IF
    target_d0 = self%line%endconn_d0
    target_d0_rate = CD_ZERO
    target_d0_acceleration = CD_ZERO
    IF (self%has_parent_endconn) THEN
      target_d0(:, self%parent_endconn_index) = frame_to_local(self, &
                                                               MATMUL(TRANSPOSE(target_dcm), self%parent_endconn_d0))
      IF (self%line%endconn_mode(self%parent_endconn_index) == CD_ENDCONN_RIGID) THEN
        omega_local = frame_to_local(self, target_omega)
        alpha_local = frame_to_local(self, target_alpha)
        target_d0_rate(:, self%parent_endconn_index) = &
          cross3(omega_local, target_d0(:, self%parent_endconn_index))
        target_d0_acceleration(:, self%parent_endconn_index) = &
          cross3(alpha_local, target_d0(:, self%parent_endconn_index)) + &
          cross3(omega_local, target_d0_rate(:, self%parent_endconn_index))
      END IF
    END IF
    ! End B's connection turns with End B's parent: d = G_B^T d_parent, with the rigid end's
    ! direction rate w x d and acceleration al x d + w x (w x d), as End A's above
    IF (self%has_parent_endconn_b) THEN
      target_d0(:, 1) = frame_to_local(self, MATMUL(TRANSPOSE(target_dcm_b), self%parent_endconn_d0_b))
      IF (self%line%endconn_mode(1) == CD_ENDCONN_RIGID) THEN
        omega_local = frame_to_local(self, target_omega_b)
        alpha_local = frame_to_local(self, target_alpha_b)
        target_d0_rate(:, 1) = cross3(omega_local, target_d0(:, 1))
        target_d0_acceleration(:, 1) = cross3(alpha_local, target_d0(:, 1)) + cross3(omega_local, target_d0_rate(:, 1))
      END IF
    END IF
    IF (PRESENT(u_twist) .AND. .NOT. self%line%torsion%active) THEN
      ErrStat = CD_HFMF_BADINPUT
      ErrMsg = 'CD_HFMF_UpdateStates: u_twist needs a cable with torsion'
      RETURN
    END IF
    IF (self%line%torsion%active) THEN
      ! Condensed torsion target at t_{n+1}: the parent-attached end frame turned with the
      ! orientation, and the imposed twist.
      tors_ends = self%line%torsion%ends
      IF (self%tors_parent) THEN
        tors_ends(:, 2*self%tors_index - 1) = frame_to_local(self, MATMUL(TRANSPOSE(target_dcm), &
                                                                          self%tors_frame_parent(:, 1)))
        tors_ends(:, 2*self%tors_index) = frame_to_local(self, MATMUL(TRANSPOSE(target_dcm), &
                                                                      self%tors_frame_parent(:, 2)))
      END IF
      IF (self%tors_parent_b) THEN
        tors_ends(:, 1) = frame_to_local(self, MATMUL(TRANSPOSE(target_dcm_b), self%tors_frame_parent_b(:, 1)))
        tors_ends(:, 2) = frame_to_local(self, MATMUL(TRANSPOSE(target_dcm_b), self%tors_frame_parent_b(:, 2)))
      END IF
      tors_phi = self%line%torsion%phi
      IF (PRESENT(u_twist)) tors_phi = u_twist
      CALL CD_HermiteCable_Dyn_Set_Torsion_Drive(self%line, tors_ends, tors_phi, es, em)
      IF (es /= CD_HCDYN_OK) THEN
        ErrStat = CD_HFMF_BADINPUT; ErrMsg = 'CD_HFMF_UpdateStates: '//TRIM(em); RETURN
      END IF
    END IF
    ! Advance the finite-EI line over the prescribed interval. Internal substeps are used when the
    ! nominal interval is too large for the boundary-motion or environmental-load increment, while
    ! preserving the requested endpoint time. A moving End B that stays exactly at rest is held (a
    ! held DOF and one prescribed to (q_n, 0, 0) are the same boundary).
    drive_b = .FALSE.
    IF (self%moving_b) drive_b = .NOT. end_b_held(self, ub_pos, ub_vel, ub_acc)
    IF (drive_b) THEN
      pd(1:3) = self%pdof
      pd(4:6) = self%pdof_b
      pq(1:3) = frame_to_local(self, u_pos)
      pq(4:6) = frame_to_local(self, ub_pos)
      pv(1:3) = frame_to_local(self, u_vel)
      pv(4:6) = frame_to_local(self, ub_vel)
      pa(1:3) = frame_to_local(self, u_acc)
      pa(4:6) = frame_to_local(self, ub_acc)
      IF (self%has_parent_endconn .OR. self%has_parent_endconn_b) THEN
        CALL CD_HermiteCable_Dyn_Step_Recovering(self%line, self%dt, self%max_iter, self%tol, es, em, &
                                                 pres_dofs=pd, pres_q=pq, pres_v=pv, pres_a=pa, &
                                                 max_substeps=self%recovery_max_substeps, &
                                                 endconn_direction=target_d0, &
                                                 endconn_direction_rate=target_d0_rate, &
                                                 endconn_direction_acceleration=target_d0_acceleration)
      ELSE
        CALL CD_HermiteCable_Dyn_Step_Recovering(self%line, self%dt, self%max_iter, self%tol, es, em, &
                                                 pres_dofs=pd, pres_q=pq, pres_v=pv, pres_a=pa, &
                                                 max_substeps=self%recovery_max_substeps)
      END IF
    ELSE IF (self%has_parent_endconn .OR. self%has_parent_endconn_b) THEN
      CALL CD_HermiteCable_Dyn_Step_Recovering(self%line, self%dt, self%max_iter, self%tol, es, em, &
                                               pres_dofs=self%pdof, pres_q=frame_to_local(self, u_pos), &
                                               pres_v=frame_to_local(self, u_vel), pres_a=frame_to_local(self, u_acc), &
                                               max_substeps=self%recovery_max_substeps, &
                                               endconn_direction=target_d0, &
                                               endconn_direction_rate=target_d0_rate, &
                                               endconn_direction_acceleration=target_d0_acceleration)
    ELSE
      CALL CD_HermiteCable_Dyn_Step_Recovering(self%line, self%dt, self%max_iter, self%tol, es, em, &
                                               pres_dofs=self%pdof, pres_q=frame_to_local(self, u_pos), &
                                               pres_v=frame_to_local(self, u_vel), pres_a=frame_to_local(self, u_acc), &
                                               max_substeps=self%recovery_max_substeps)
    END IF
    IF (es /= CD_HCDYN_OK) THEN
      ErrStat = CD_HFMF_SOLVEFAIL; ErrMsg = 'CD_HFMF_UpdateStates: '//TRIM(em)
    ELSE
      IF (self%has_parent_endconn .OR. self%tors_parent) THEN
        self%parent_dcm = target_dcm
        self%parent_omega = target_omega
        self%parent_alpha = target_alpha
      END IF
      IF (self%has_parent_endconn_b .OR. self%tors_parent_b) THEN
        self%parent_dcm_b = target_dcm_b
        self%parent_omega_b = target_omega_b
        self%parent_alpha_b = target_alpha_b
      END IF
    END IF
  END SUBROUTINE CD_HFMF_UpdateStates

  SUBROUTINE end_b_inputs(self, dcm_b, omega_b, alpha_b, ErrStat, ErrMsg, ub_pos, ub_vel, ub_acc, &
                          ub_orientation, ub_angular_velocity, ub_angular_acceleration)
    !! Validate the End B kinematics of an update (UpdateStates, SetCoupledKinematics, Preflight):
    !! required (translations) on a cable with a moving End B, refused on any other; returns End B's
    !! target parent orientation and rates (the committed orientation and zero rates when absent).
    TYPE(CD_HFMF_ModuleType), INTENT(IN) :: self
    REAL(wp), INTENT(OUT) :: dcm_b(3, 3), omega_b(3), alpha_b(3)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    REAL(wp), INTENT(IN), OPTIONAL :: ub_pos(3), ub_vel(3), ub_acc(3), ub_orientation(3, 3)
    REAL(wp), INTENT(IN), OPTIONAL :: ub_angular_velocity(3), ub_angular_acceleration(3)
    ErrStat = CD_HFMF_OK
    ErrMsg = ''
    dcm_b = self%parent_dcm_b
    omega_b = CD_ZERO
    alpha_b = CD_ZERO
    IF (.NOT. self%moving_b) THEN
      IF (PRESENT(ub_pos) .OR. PRESENT(ub_vel) .OR. PRESENT(ub_acc) .OR. PRESENT(ub_orientation) .OR. &
          PRESENT(ub_angular_velocity) .OR. PRESENT(ub_angular_acceleration)) THEN
        ErrStat = CD_HFMF_BADINPUT
        ErrMsg = 'End B kinematics need a moving End B (CD_HFMF_Set_Moving_End_B)'
      END IF
      RETURN
    END IF
    ErrStat = CD_HFMF_BADINPUT
    IF (.NOT. (PRESENT(ub_pos) .AND. PRESENT(ub_vel) .AND. PRESENT(ub_acc))) THEN
      ErrMsg = 'a moving End B needs its position, velocity and acceleration (ub_pos, ub_vel, ub_acc)'
      RETURN
    END IF
    IF (.NOT. (CD_All_Finite(ub_pos) .AND. CD_All_Finite(ub_vel) .AND. CD_All_Finite(ub_acc))) THEN
      ErrMsg = 'End B inputs must be finite'
      RETURN
    END IF
    IF (PRESENT(ub_angular_velocity) .NEQV. PRESENT(ub_angular_acceleration)) THEN
      ErrMsg = 'End B angular velocity and acceleration must be supplied together'
      RETURN
    END IF
    IF (PRESENT(ub_angular_velocity)) THEN
      IF (.NOT. (CD_All_Finite(ub_angular_velocity) .AND. CD_All_Finite(ub_angular_acceleration))) THEN
        ErrMsg = 'End B angular kinematics must be finite'
        RETURN
      END IF
      omega_b = ub_angular_velocity
      alpha_b = ub_angular_acceleration
    END IF
    IF (PRESENT(ub_orientation)) THEN
      IF (.NOT. valid_parent_dcm(ub_orientation)) THEN
        ErrMsg = 'End B orientation must be a finite proper orthogonal DCM'
        RETURN
      END IF
      dcm_b = ub_orientation
    END IF
    ErrStat = CD_HFMF_OK
  END SUBROUTINE end_b_inputs

  PURE LOGICAL FUNCTION end_b_at_rest(self) RESULT(at_rest)
    !! The committed End B is at rest: zero velocity and acceleration of its translations. An End B
    !! that is not driven (moving_b false, pdof_b unset) is at rest; Fortran does not short-circuit
    !! a caller's moving_b .AND. ..., so the test must not index pdof_b then.
    TYPE(CD_HFMF_ModuleType), INTENT(IN) :: self
    at_rest = .TRUE.
    IF (.NOT. self%moving_b) RETURN
    at_rest = .NOT. (ANY(ABS(self%line%v(self%pdof_b)) > CD_ZERO) .OR. ANY(ABS(self%line%a(self%pdof_b)) > CD_ZERO))
  END FUNCTION end_b_at_rest

  PURE LOGICAL FUNCTION end_b_held(self, ub_pos, ub_vel, ub_acc) RESULT(held)
    !! End B stays exactly at rest over the step: committed at rest, and the target is its committed
    !! position with zero velocity and acceleration (bit for bit), the boundary a Fixed End B holds.
    !! The position is the committed one in either frame: the solve frame (a target rotated in, as a
    !! motion row is) or the caller's global frame (a target read back by CD_HFMF_GetEndBKinematics,
    !! which a rotation round trip at a non-zero chord heading need not return bit for bit).
    TYPE(CD_HFMF_ModuleType), INTENT(IN) :: self
    REAL(wp), INTENT(IN) :: ub_pos(3), ub_vel(3), ub_acc(3)
    held = end_b_at_rest(self)
    IF (.NOT. held) RETURN
    held = .NOT. (ANY(ABS(ub_vel) > CD_ZERO) .OR. ANY(ABS(ub_acc) > CD_ZERO))
    IF (.NOT. held) RETURN
    held = .NOT. ANY(ABS(frame_to_local(self, ub_pos) - self%line%q(self%pdof_b)) > CD_ZERO)
    IF (held) RETURN
    held = .NOT. ANY(ABS(ub_pos - frame_to_global(self, self%line%q(self%pdof_b))) > CD_ZERO)
  END FUNCTION end_b_held

  SUBROUTINE CD_HFMF_Snapshot(self, ErrStat, ErrMsg)
    !! Capture the cable's committed step state (q, v, a, t) for the aggregate
    !! stage-then-commit contract (delegates to CD_HermiteCable_Dyn_Snapshot).
    TYPE(CD_HFMF_ModuleType), INTENT(INOUT) :: self
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    INTEGER :: es
    CHARACTER(1024) :: em
    ErrStat = CD_HFMF_OK; ErrMsg = ''
    IF (.NOT. self%initialized) THEN
      ErrStat = CD_HFMF_BADINPUT; ErrMsg = 'CD_HFMF_Snapshot: module not initialised'; RETURN
    END IF
    CALL CD_HermiteCable_Dyn_Snapshot(self%line, es, em)
    IF (es /= CD_HCDYN_OK) THEN
      ErrStat = CD_HFMF_BADINPUT; ErrMsg = 'CD_HFMF_Snapshot: '//TRIM(em)
    ELSE
      self%snap_parent_dcm = self%parent_dcm
      self%snap_parent_omega = self%parent_omega
      self%snap_parent_alpha = self%parent_alpha
      self%snap_parent_dcm_b = self%parent_dcm_b
      self%snap_parent_omega_b = self%parent_omega_b
      self%snap_parent_alpha_b = self%parent_alpha_b
    END IF
  END SUBROUTINE CD_HFMF_Snapshot

  SUBROUTINE CD_HFMF_Restore(self, ErrStat, ErrMsg)
    !! Restore the cable's committed step state from the last Snapshot (fails closed
    !! without a valid snapshot).
    TYPE(CD_HFMF_ModuleType), INTENT(INOUT) :: self
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    INTEGER :: es
    CHARACTER(1024) :: em
    ErrStat = CD_HFMF_OK; ErrMsg = ''
    IF (.NOT. self%initialized) THEN
      ErrStat = CD_HFMF_BADINPUT; ErrMsg = 'CD_HFMF_Restore: module not initialised'; RETURN
    END IF
    CALL CD_HermiteCable_Dyn_Restore(self%line, es, em)
    IF (es /= CD_HCDYN_OK) THEN
      ErrStat = CD_HFMF_BADINPUT; ErrMsg = 'CD_HFMF_Restore: '//TRIM(em)
    ELSE
      self%parent_dcm = self%snap_parent_dcm
      self%parent_omega = self%snap_parent_omega
      self%parent_alpha = self%snap_parent_alpha
      self%parent_dcm_b = self%snap_parent_dcm_b
      self%parent_omega_b = self%snap_parent_omega_b
      self%parent_alpha_b = self%snap_parent_alpha_b
    END IF
  END SUBROUTINE CD_HFMF_Restore

  SUBROUTINE CD_HFMF_PreflightCoupledKinematics(self, u_pos, u_vel, u_acc, ErrStat, ErrMsg, u_orientation, &
                                                u_angular_velocity, u_angular_acceleration, ub_pos, ub_vel, ub_acc, &
                                                ub_orientation, ub_angular_velocity, ub_angular_acceleration)
    !! Validate every deterministic failure condition in SetCoupledKinematics without
    !! changing the cable. Aggregate callers use this before updating any sibling
    !! subsystem, so a bad later cable column cannot leave an earlier column mutated.
    !! A moving End B's kinematics (ub_*) are checked with the coupled end's.
    TYPE(CD_HFMF_ModuleType), INTENT(IN) :: self
    REAL(wp), INTENT(IN) :: u_pos(3), u_vel(3), u_acc(3)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    REAL(wp), INTENT(IN), OPTIONAL :: u_orientation(3, 3)
    REAL(wp), INTENT(IN), OPTIONAL :: u_angular_velocity(3), u_angular_acceleration(3)
    REAL(wp), INTENT(IN), OPTIONAL :: ub_pos(3), ub_vel(3), ub_acc(3), ub_orientation(3, 3)
    REAL(wp), INTENT(IN), OPTIONAL :: ub_angular_velocity(3), ub_angular_acceleration(3)
    REAL(wp) :: target_dcm(3, 3), d0_target(3, 2), tangent_q(3), tangent_v(3), tangent_a(3)
    REAL(wp) :: target_omega(3), target_alpha(3)
    REAL(wp) :: target_dcm_b(3, 3), target_omega_b(3), target_alpha_b(3), tangent_b(3, 3)
    CHARACTER(1024) :: em

    CALL prepare_coupled_kinematics(self, u_pos, u_vel, u_acc, target_dcm, target_omega, target_alpha, &
                                    d0_target, tangent_q, tangent_v, tangent_a, ErrStat, em, &
                                    target_dcm_b, target_omega_b, target_alpha_b, tangent_b, &
                                    u_orientation, u_angular_velocity, u_angular_acceleration, &
                                    ub_pos, ub_vel, ub_acc, ub_orientation, ub_angular_velocity, &
                                    ub_angular_acceleration)
    IF (ErrStat /= CD_HFMF_OK) THEN
      ErrMsg = 'CD_HFMF_PreflightCoupledKinematics: '//TRIM(em)
      RETURN
    END IF
    ErrMsg = ''
    IF (self%tors_parent .OR. self%tors_parent_b) THEN
      ! the parent-attached torsion frames at the written state: the same acceptance as the
      ! frame update of SetCoupledKinematics (fold guard, twist change within pi/2)
      BLOCK
        REAL(wp), ALLOCATABLE :: qc(:), g(:)
        REAL(wp) :: ends(3, 4), raw, th
        INTEGER :: ks, k
        CHARACTER(1024) :: km
        ends = coupled_torsion_ends(self, target_dcm, target_dcm_b)
        DO k = 1, 3, 2
          IF (ABS(NORM2(ends(:, k)) - CD_ONE) > 1.0e-8_wp .OR. ABS(NORM2(ends(:, k + 1)) - CD_ONE) > 1.0e-8_wp &
              .OR. ABS(DOT_PRODUCT(ends(:, k), ends(:, k + 1))) > 1.0e-8_wp) THEN
            ErrStat = CD_HFMF_SOLVEFAIL
            ErrMsg = 'CD_HFMF_PreflightCoupledKinematics: each end director and reference normal must be orthonormal'
            RETURN
          END IF
        END DO
        ALLOCATE (qc(SIZE(self%line%q)), g(SIZE(self%line%q)))
        CALL coupled_candidate_q(self, u_pos, tangent_q, qc, ub_pos, tangent_b(:, 1))
        IF (self%line%tw_active) THEN
          ! the nodal twist: its own acceptance of the written state (CD_HermiteCable_Dyn_Twist_Check)
          CALL CD_HermiteCable_Dyn_Twist_Check(self%line, qc, ends, ks, km)
          IF (ks /= CD_HCDYN_OK) THEN
            ErrStat = CD_HFMF_SOLVEFAIL
            ErrMsg = 'CD_HFMF_PreflightCoupledKinematics: '//TRIM(km)
          END IF
          RETURN
        END IF
        CALL CD_HermiteTorsion_Line(qc, self%line%l0, ends, raw, g, ks, km, &
                                    couple=self%line%torsion%couple, &
                                    quadrature_order=self%line%torsion%quadrature_order)
        IF (ks /= CD_HTORS_OK) THEN
          ErrStat = CD_HFMF_SOLVEFAIL
          ErrMsg = 'CD_HFMF_PreflightCoupledKinematics: torsion: '//TRIM(km)
          RETURN
        END IF
        th = CD_HermiteTorsion_Unwrap(raw, self%line%torsion%theta)
        IF (ABS(th - self%line%torsion%theta) > CD_HTORS_MAX_STEP) THEN
          ErrStat = CD_HFMF_SOLVEFAIL
          ErrMsg = 'CD_HFMF_PreflightCoupledKinematics: torsion: the twist would move more than pi/2 from its '// &
                   'committed value'
        END IF
      END BLOCK
    END IF
  END SUBROUTINE CD_HFMF_PreflightCoupledKinematics

  FUNCTION coupled_torsion_ends(self, target_dcm, target_dcm_b) RESULT(ends)
    !! The torsion end frames with the parent-attached ends turned to target_dcm (the coupled end)
    !! and target_dcm_b (a moving End B), in the solve frame.
    TYPE(CD_HFMF_ModuleType), INTENT(IN) :: self
    REAL(wp), INTENT(IN) :: target_dcm(3, 3)
    REAL(wp), INTENT(IN), OPTIONAL :: target_dcm_b(3, 3)
    REAL(wp) :: ends(3, 4)
    ends = self%line%torsion%ends
    IF (self%tors_parent) THEN
      ends(:, 2*self%tors_index - 1) = frame_to_local(self, MATMUL(TRANSPOSE(target_dcm), &
                                                                   self%tors_frame_parent(:, 1)))
      ends(:, 2*self%tors_index) = frame_to_local(self, MATMUL(TRANSPOSE(target_dcm), self%tors_frame_parent(:, 2)))
    END IF
    IF (self%tors_parent_b .AND. PRESENT(target_dcm_b)) THEN
      ends(:, 1) = frame_to_local(self, MATMUL(TRANSPOSE(target_dcm_b), self%tors_frame_parent_b(:, 1)))
      ends(:, 2) = frame_to_local(self, MATMUL(TRANSPOSE(target_dcm_b), self%tors_frame_parent_b(:, 2)))
    END IF
  END FUNCTION coupled_torsion_ends

  SUBROUTINE coupled_candidate_q(self, u_pos, tangent_q, qc, ub_pos, tangent_q_b)
    !! The configuration SetCoupledKinematics writes: the committed q with the coupled node's
    !! translation and, for a rigid parent connection, its transported tangent (built the same
    !! way, in place, by SetCoupledKinematics), and the same for a moving End B (ub_pos, tangent_q_b).
    !! qc must not be part of self.
    TYPE(CD_HFMF_ModuleType), INTENT(IN) :: self
    REAL(wp), INTENT(IN) :: u_pos(3), tangent_q(3)
    REAL(wp), INTENT(OUT) :: qc(:)
    REAL(wp), INTENT(IN), OPTIONAL :: ub_pos(3), tangent_q_b(3)
    INTEGER :: base, i
    DO i = 1, SIZE(qc)
      qc(i) = self%line%q(i)
    END DO
    IF (self%has_parent_endconn) THEN
      IF (self%line%endconn_mode(self%parent_endconn_index) == CD_ENDCONN_RIGID) THEN
        base = MERGE(3, 6*(self%line%nn - 1) + 3, self%parent_endconn_index == 1)
        qc(base + 1:base + 3) = tangent_q
      END IF
    END IF
    IF (self%has_parent_endconn_b .AND. PRESENT(tangent_q_b)) THEN
      IF (self%line%endconn_mode(1) == CD_ENDCONN_RIGID) qc(4:6) = tangent_q_b
    END IF
    qc(self%pdof) = frame_to_local(self, u_pos)
    IF (self%moving_b .AND. PRESENT(ub_pos)) qc(self%pdof_b) = frame_to_local(self, ub_pos)
  END SUBROUTINE coupled_candidate_q

  SUBROUTINE CD_HFMF_SetCoupledKinematics(self, u_pos, u_vel, u_acc, ErrStat, ErrMsg, u_orientation, &
                                          u_angular_velocity, u_angular_acceleration, ub_pos, ub_vel, ub_acc, &
                                          ub_orientation, ub_angular_velocity, ub_angular_acceleration)
    !! Direct-feedthrough transfer: write ONLY the coupled node's three translational (r, v, a)
    !! DOFs into the line state, WITHOUT stepping the interior or advancing simulation time. Used
    !! between an UpdateStates_Moving (the host moves the fairlead) and the following CalcOutput so
    !! the reported reaction reflects the CURRENT coupled kinematics against the FROZEN interior
    !! (the last committed step's shape) -- the instantaneous feedthrough load, rather than the load
    !! at the last committed fairlead. It does not re-solve, does not touch the interior DOFs, and
    !! does not advance self%line%t; the next CD_HFMF_UpdateStates re-prescribes the boundary and
    !! performs the actual implicit advance. A moving End B (ub_*, required on such a cable) is
    !! written in the same way.
    TYPE(CD_HFMF_ModuleType), INTENT(INOUT) :: self
    REAL(wp), INTENT(IN) :: u_pos(3), u_vel(3), u_acc(3)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    REAL(wp), INTENT(IN), OPTIONAL :: u_orientation(3, 3)
    REAL(wp), INTENT(IN), OPTIONAL :: u_angular_velocity(3), u_angular_acceleration(3)
    REAL(wp), INTENT(IN), OPTIONAL :: ub_pos(3), ub_vel(3), ub_acc(3), ub_orientation(3, 3)
    REAL(wp), INTENT(IN), OPTIONAL :: ub_angular_velocity(3), ub_angular_acceleration(3)
    REAL(wp) :: target_dcm(3, 3), d0_target(3, 2)
    REAL(wp) :: tangent_q(3), tangent_v(3), tangent_a(3)
    REAL(wp) :: target_omega(3), target_alpha(3), tors_ends(3, 4)
    REAL(wp) :: target_dcm_b(3, 3), target_omega_b(3), target_alpha_b(3), tangent_b(3, 3)
    INTEGER :: base, es
    CHARACTER(1024) :: em

    CALL prepare_coupled_kinematics(self, u_pos, u_vel, u_acc, target_dcm, target_omega, target_alpha, &
                                    d0_target, tangent_q, tangent_v, tangent_a, ErrStat, em, &
                                    target_dcm_b, target_omega_b, target_alpha_b, tangent_b, &
                                    u_orientation, u_angular_velocity, u_angular_acceleration, &
                                    ub_pos, ub_vel, ub_acc, ub_orientation, ub_angular_velocity, &
                                    ub_angular_acceleration)
    IF (ErrStat /= CD_HFMF_OK) THEN
      ErrMsg = 'CD_HFMF_SetCoupledKinematics: '//TRIM(em)
      RETURN
    END IF
    ! A parent-attached torsion frame is checked at the state about to be written before
    ! anything is written (the update is all or nothing)
    IF (self%tors_parent .OR. self%tors_parent_b) THEN
      tors_ends = coupled_torsion_ends(self, target_dcm, target_dcm_b)
      ! the candidate configuration in the line's trial scratch (as coupled_candidate_q builds it)
      DO base = 1, SIZE(self%line%q)
        self%line%ws_qtrial(base) = self%line%q(base)
      END DO
      IF (self%has_parent_endconn) THEN
        IF (self%line%endconn_mode(self%parent_endconn_index) == CD_ENDCONN_RIGID) THEN
          base = MERGE(3, 6*(self%line%nn - 1) + 3, self%parent_endconn_index == 1)
          self%line%ws_qtrial(base + 1:base + 3) = tangent_q
        END IF
      END IF
      IF (self%has_parent_endconn_b) THEN
        IF (self%line%endconn_mode(1) == CD_ENDCONN_RIGID) self%line%ws_qtrial(4:6) = tangent_b(:, 1)
      END IF
      self%line%ws_qtrial(self%pdof) = frame_to_local(self, u_pos)
      IF (self%moving_b) self%line%ws_qtrial(self%pdof_b) = frame_to_local(self, ub_pos)
      CALL CD_HermiteCable_Dyn_Set_Torsion_Frames(self%line, tors_ends, es, em, q_check=self%line%ws_qtrial)
      IF (es /= CD_HCDYN_OK) THEN
        ErrStat = CD_HFMF_SOLVEFAIL
        ErrMsg = 'CD_HFMF_SetCoupledKinematics: '//TRIM(em)
        RETURN
      END IF
    END IF
    IF (self%has_parent_endconn) THEN
      IF (self%line%endconn_mode(self%parent_endconn_index) == CD_ENDCONN_RIGID) THEN
        IF (self%parent_endconn_index == 1) THEN
          base = 3
        ELSE
          base = 6*(self%line%nn - 1) + 3
        END IF
        self%line%q(base + 1:base + 3) = tangent_q
        self%line%v(base + 1:base + 3) = tangent_v
        self%line%a(base + 1:base + 3) = tangent_a
      END IF
      self%line%endconn_d0(:, self%parent_endconn_index) = d0_target(:, self%parent_endconn_index)
      self%parent_dcm = target_dcm
      self%parent_omega = target_omega
      self%parent_alpha = target_alpha
    END IF
    IF (self%has_parent_endconn_b) THEN
      IF (self%line%endconn_mode(1) == CD_ENDCONN_RIGID) THEN
        self%line%q(4:6) = tangent_b(:, 1)
        self%line%v(4:6) = tangent_b(:, 2)
        self%line%a(4:6) = tangent_b(:, 3)
      END IF
      self%line%endconn_d0(:, 1) = d0_target(:, 1)
      self%parent_dcm_b = target_dcm_b
      self%parent_omega_b = target_omega_b
      self%parent_alpha_b = target_alpha_b
    END IF
    ! self%pdof holds the coupled node's three translational DOFs in the cable's local
    ! frame; the boundary rotates the caller's global kinematics in.
    self%line%q(self%pdof) = frame_to_local(self, u_pos)
    self%line%v(self%pdof) = frame_to_local(self, u_vel)
    self%line%a(self%pdof) = frame_to_local(self, u_acc)
    IF (self%moving_b) THEN
      self%line%q(self%pdof_b) = frame_to_local(self, ub_pos)
      self%line%v(self%pdof_b) = frame_to_local(self, ub_vel)
      self%line%a(self%pdof_b) = frame_to_local(self, ub_acc)
    END IF
    IF (self%tors_parent .OR. self%tors_parent_b) THEN
      ! the parent-attached torsion frames turn with the written orientations (committed state);
      ! checked above at this very state, so they are accepted
      CALL CD_HermiteCable_Dyn_Set_Torsion_Frames(self%line, tors_ends, es, em)
      IF (es /= CD_HCDYN_OK) THEN
        ErrStat = CD_HFMF_SOLVEFAIL
        ErrMsg = 'CD_HFMF_SetCoupledKinematics: '//TRIM(em)
        RETURN
      END IF
      IF (self%tors_parent .AND. .NOT. self%has_parent_endconn) THEN
        self%parent_dcm = target_dcm
        self%parent_omega = target_omega
        self%parent_alpha = target_alpha
      END IF
      IF (self%tors_parent_b .AND. .NOT. self%has_parent_endconn_b) THEN
        self%parent_dcm_b = target_dcm_b
        self%parent_omega_b = target_omega_b
        self%parent_alpha_b = target_alpha_b
      END IF
    END IF
    ErrStat = CD_HFMF_OK
    ErrMsg = ''
  END SUBROUTINE CD_HFMF_SetCoupledKinematics

  SUBROUTINE prepare_coupled_kinematics(self, u_pos, u_vel, u_acc, target_dcm, target_omega, target_alpha, &
                                        d0_target, tangent_q, tangent_v, tangent_a, ErrStat, ErrMsg, &
                                        target_dcm_b, target_omega_b, target_alpha_b, tangent_b, &
                                        u_orientation, u_angular_velocity, u_angular_acceleration, &
                                        ub_pos, ub_vel, ub_acc, ub_orientation, ub_angular_velocity, &
                                        ub_angular_acceleration)
    !! Prepare the complete non-stepping boundary update without mutating self. Keep
    !! every fallible operation here so Preflight and Set have identical acceptance. A moving
    !! End B's target (orientation, rates and the transported rigid tangent q, v, a in the columns
    !! of tangent_b) is prepared the same way.
    TYPE(CD_HFMF_ModuleType), INTENT(IN) :: self
    REAL(wp), INTENT(IN) :: u_pos(3), u_vel(3), u_acc(3)
    REAL(wp), INTENT(OUT) :: target_dcm(3, 3), target_omega(3), target_alpha(3), d0_target(3, 2)
    REAL(wp), INTENT(OUT) :: tangent_q(3), tangent_v(3), tangent_a(3)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    REAL(wp), INTENT(OUT) :: target_dcm_b(3, 3), target_omega_b(3), target_alpha_b(3), tangent_b(3, 3)
    REAL(wp), INTENT(IN), OPTIONAL :: u_orientation(3, 3)
    REAL(wp), INTENT(IN), OPTIONAL :: u_angular_velocity(3), u_angular_acceleration(3)
    REAL(wp), INTENT(IN), OPTIONAL :: ub_pos(3), ub_vel(3), ub_acc(3), ub_orientation(3, 3)
    REAL(wp), INTENT(IN), OPTIONAL :: ub_angular_velocity(3), ub_angular_acceleration(3)

    ErrStat = CD_HFMF_OK
    ErrMsg = ''
    target_dcm = identity_dcm()
    d0_target = CD_ZERO
    tangent_q = CD_ZERO
    tangent_v = CD_ZERO
    tangent_a = CD_ZERO
    target_omega = CD_ZERO
    target_alpha = CD_ZERO
    target_dcm_b = identity_dcm()
    target_omega_b = CD_ZERO
    target_alpha_b = CD_ZERO
    tangent_b = CD_ZERO
    IF (.NOT. self%initialized) THEN
      ErrStat = CD_HFMF_BADINPUT
      ErrMsg = 'module not initialised'
      RETURN
    END IF
    IF (.NOT. (CD_All_Finite(u_pos) .AND. CD_All_Finite(u_vel) .AND. &
               CD_All_Finite(u_acc))) THEN
      ErrStat = CD_HFMF_BADINPUT
      ErrMsg = 'inputs must be finite'
      RETURN
    END IF
    IF (PRESENT(u_angular_velocity) .NEQV. PRESENT(u_angular_acceleration)) THEN
      ErrStat = CD_HFMF_BADINPUT
      ErrMsg = 'angular velocity and acceleration must be supplied together'
      RETURN
    END IF
    IF (PRESENT(u_angular_velocity)) THEN
      IF (.NOT. (CD_All_Finite(u_angular_velocity) .AND. &
                 CD_All_Finite(u_angular_acceleration))) THEN
        ErrStat = CD_HFMF_BADINPUT
        ErrMsg = 'angular kinematics must be finite'
        RETURN
      END IF
      target_omega = u_angular_velocity
      target_alpha = u_angular_acceleration
    END IF
    target_dcm = self%parent_dcm
    IF (PRESENT(u_orientation)) THEN
      IF (.NOT. valid_parent_dcm(u_orientation)) THEN
        ErrStat = CD_HFMF_BADINPUT
        ErrMsg = 'orientation must be a finite proper orthogonal DCM'
        RETURN
      END IF
      target_dcm = u_orientation
    END IF
    CALL end_b_inputs(self, target_dcm_b, target_omega_b, target_alpha_b, ErrStat, ErrMsg, ub_pos, ub_vel, ub_acc, &
                      ub_orientation, ub_angular_velocity, ub_angular_acceleration)
    IF (ErrStat /= CD_HFMF_OK) RETURN
    d0_target = self%line%endconn_d0
    IF (self%has_parent_endconn) THEN
      CALL prepare_parent_end(self, self%parent_endconn_index, self%parent_endconn_d0, self%parent_omega, &
                              target_dcm, target_omega, target_alpha, d0_target(:, self%parent_endconn_index), &
                              tangent_q, tangent_v, tangent_a, ErrStat, ErrMsg)
      IF (ErrStat /= CD_HFMF_OK) RETURN
    END IF
    IF (self%has_parent_endconn_b) THEN
      CALL prepare_parent_end(self, 1, self%parent_endconn_d0_b, self%parent_omega_b, target_dcm_b, &
                              target_omega_b, target_alpha_b, d0_target(:, 1), tangent_b(:, 1), tangent_b(:, 2), &
                              tangent_b(:, 3), ErrStat, ErrMsg)
      IF (ErrStat /= CD_HFMF_OK) ErrMsg = 'End B: '//TRIM(ErrMsg)
    END IF
  END SUBROUTINE prepare_coupled_kinematics

  SUBROUTINE prepare_parent_end(self, iend, parent_d0, old_omega, target_dcm, target_omega, target_alpha, &
                                d0_end, tangent_q, tangent_v, tangent_a, ErrStat, ErrMsg)
    !! The non-stepping update of one parent-attached end connection (end iend: 1 = node 1, 2 = the
    !! last node): its direction d = G^T d_parent at the target orientation and, for an exact rigid
    !! end, the end tangent projected on d and transported with the parent's rotation (q, v, a of
    !! m = |m| d: v = |m|' d + |m| w x d, a = |m|'' d + 2 |m|' w x d + |m| (al x d + w x (w x d))).
    TYPE(CD_HFMF_ModuleType), INTENT(IN) :: self
    INTEGER, INTENT(IN) :: iend
    REAL(wp), INTENT(IN) :: parent_d0(3), old_omega(3), target_dcm(3, 3), target_omega(3), target_alpha(3)
    REAL(wp), INTENT(INOUT) :: d0_end(3)
    REAL(wp), INTENT(OUT) :: tangent_q(3), tangent_v(3), tangent_a(3)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    REAL(wp) :: dn, magnitude, magnitude_rate, magnitude_acceleration
    REAL(wp) :: old_direction(3), old_direction_rate(3), target_direction(3)
    REAL(wp) :: target_direction_rate(3), target_direction_acceleration(3)
    REAL(wp) :: omega_local(3), alpha_local(3), rotation_check(3, 3)
    INTEGER :: base, ecstat
    CHARACTER(1024) :: ecmsg

    ErrStat = CD_HFMF_OK
    ErrMsg = ''
    tangent_q = CD_ZERO
    tangent_v = CD_ZERO
    tangent_a = CD_ZERO
    d0_end = frame_to_local(self, MATMUL(TRANSPOSE(target_dcm), parent_d0))
    dn = SQRT(DOT_PRODUCT(d0_end, d0_end))
    IF (.NOT. CD_Is_Finite(dn) .OR. dn <= SQRT(TINY(CD_ONE))) THEN
      ErrStat = CD_HFMF_BADINPUT
      ErrMsg = 'rotated end-connection direction is singular'
      RETURN
    END IF
    d0_end = d0_end/dn
    IF (self%line%endconn_mode(iend) /= CD_ENDCONN_RIGID) RETURN

    IF (iend == 1) THEN
      base = 3
    ELSE
      base = 6*(self%line%nn - 1) + 3
    END IF
    CALL CD_EndConn_Project(self%line%q(base + 1:base + 3), d0_end, tangent_q, ecstat, ecmsg)
    IF (ecstat /= CD_ENDCONN_OK) THEN
      ErrStat = CD_HFMF_BADINPUT
      ErrMsg = 'rigid tangent projection failed: '//TRIM(ecmsg)
      RETURN
    END IF
    CALL direction_rotation(self%line%endconn_d0(:, iend), d0_end, rotation_check, ecstat, ecmsg)
    IF (ecstat /= CD_ENDCONN_OK) THEN
      ErrStat = CD_HFMF_BADINPUT
      ErrMsg = 'rigid direction update failed: '//TRIM(ecmsg)
      RETURN
    END IF
    old_direction = self%line%endconn_d0(:, iend)
    target_direction = d0_end
    magnitude = SQRT(DOT_PRODUCT(tangent_q, tangent_q))
    omega_local = frame_to_local(self, old_omega)
    old_direction_rate = cross3(omega_local, old_direction)
    magnitude_rate = DOT_PRODUCT(self%line%v(base + 1:base + 3), old_direction)
    magnitude_acceleration = DOT_PRODUCT(self%line%a(base + 1:base + 3), old_direction) + &
                             magnitude*DOT_PRODUCT(old_direction_rate, old_direction_rate)
    omega_local = frame_to_local(self, target_omega)
    alpha_local = frame_to_local(self, target_alpha)
    target_direction_rate = cross3(omega_local, target_direction)
    target_direction_acceleration = cross3(alpha_local, target_direction) + &
                                    cross3(omega_local, target_direction_rate)
    tangent_v = magnitude_rate*target_direction + magnitude*target_direction_rate
    tangent_a = magnitude_acceleration*target_direction + &
                2.0_wp*magnitude_rate*target_direction_rate + magnitude*target_direction_acceleration
    IF (.NOT. (CD_All_Finite(tangent_v) .AND. CD_All_Finite(tangent_a))) THEN
      ErrStat = CD_HFMF_BADINPUT
      ErrMsg = 'rigid tangent transport produced non-finite kinematics'
    END IF
  END SUBROUTINE prepare_parent_end

  SUBROUTINE CD_HFMF_GetCoupledKinematics(self, pos, vel, acc, ErrStat, ErrMsg, orientation, &
                                          angular_velocity, angular_acceleration)
    !! Read the coupled node's committed kinematics in the CALLER's global frame (the
    !! inverse of the SetCoupledKinematics rotation). Encapsulates the frame so no
    !! consumer needs to poke self%line%q directly.
    TYPE(CD_HFMF_ModuleType), INTENT(IN) :: self
    REAL(wp), INTENT(OUT) :: pos(3), vel(3), acc(3)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    REAL(wp), INTENT(OUT), OPTIONAL :: orientation(3, 3)
    REAL(wp), INTENT(OUT), OPTIONAL :: angular_velocity(3), angular_acceleration(3)
    ErrStat = CD_HFMF_OK; ErrMsg = ''
    pos = CD_ZERO; vel = CD_ZERO; acc = CD_ZERO
    IF (PRESENT(orientation)) orientation = identity_dcm()
    IF (PRESENT(angular_velocity)) angular_velocity = CD_ZERO
    IF (PRESENT(angular_acceleration)) angular_acceleration = CD_ZERO
    IF (.NOT. self%initialized) THEN
      ErrStat = CD_HFMF_BADINPUT; ErrMsg = 'CD_HFMF_GetCoupledKinematics: module not initialised'; RETURN
    END IF
    pos = frame_to_global(self, self%line%q(self%pdof))
    vel = frame_to_global(self, self%line%v(self%pdof))
    acc = frame_to_global(self, self%line%a(self%pdof))
    IF (PRESENT(orientation)) orientation = self%parent_dcm
    IF (PRESENT(angular_velocity)) angular_velocity = self%parent_omega
    IF (PRESENT(angular_acceleration)) angular_acceleration = self%parent_alpha
  END SUBROUTINE CD_HFMF_GetCoupledKinematics

  SUBROUTINE CD_HFMF_GetEndBKinematics(self, pos, vel, acc, ErrStat, ErrMsg, orientation, &
                                       angular_velocity, angular_acceleration)
    !! The End B twin of CD_HFMF_GetCoupledKinematics: the committed kinematics of internal node 1
    !! (deck End B) in the CALLER's global frame, with End B's parent orientation and rates (identity
    !! and zero unless a moving End B carries a parent frame). A held End B reads its fixed position.
    TYPE(CD_HFMF_ModuleType), INTENT(IN) :: self
    REAL(wp), INTENT(OUT) :: pos(3), vel(3), acc(3)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    REAL(wp), INTENT(OUT), OPTIONAL :: orientation(3, 3)
    REAL(wp), INTENT(OUT), OPTIONAL :: angular_velocity(3), angular_acceleration(3)
    ErrStat = CD_HFMF_OK; ErrMsg = ''
    pos = CD_ZERO; vel = CD_ZERO; acc = CD_ZERO
    IF (PRESENT(orientation)) orientation = identity_dcm()
    IF (PRESENT(angular_velocity)) angular_velocity = CD_ZERO
    IF (PRESENT(angular_acceleration)) angular_acceleration = CD_ZERO
    IF (.NOT. self%initialized) THEN
      ErrStat = CD_HFMF_BADINPUT; ErrMsg = 'CD_HFMF_GetEndBKinematics: module not initialised'; RETURN
    END IF
    pos = frame_to_global(self, self%line%q(1:3))
    vel = frame_to_global(self, self%line%v(1:3))
    acc = frame_to_global(self, self%line%a(1:3))
    IF (PRESENT(orientation)) orientation = self%parent_dcm_b
    IF (PRESENT(angular_velocity)) angular_velocity = self%parent_omega_b
    IF (PRESENT(angular_acceleration)) angular_acceleration = self%parent_alpha_b
  END SUBROUTINE CD_HFMF_GetEndBKinematics

  SUBROUTINE CD_HFMF_Set_Held_Fluid(self, fluid_velocity, fluid_acceleration, waterline_z, ErrStat, ErrMsg)
    !! Prescribe the host-sampled ambient-fluid field on the cable's nodes: per-node
    !! fluid velocity, acceleration, and local free-surface elevation, held frozen until
    !! the next call (the per-step zero-order hold). Requires the drag config; mutually
    !! exclusive with the internal wave families (the model fails closed). The nodal
    !! vectors arrive in the caller's GLOBAL frame and rotate into the cable's local
    !! solve frame here (frame_to_local per column, exactly as the coupled kinematics
    !! do); the free-surface elevation is invariant under the about-+z heading.
    TYPE(CD_HFMF_ModuleType), INTENT(INOUT) :: self
    REAL(wp), INTENT(IN) :: fluid_velocity(:, :), fluid_acceleration(:, :), waterline_z(:)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    INTEGER :: es, i
    LOGICAL :: has_heading
    CHARACTER(1024) :: em
    ErrStat = CD_HFMF_OK; ErrMsg = ''
    IF (.NOT. self%initialized) THEN
      ErrStat = CD_HFMF_BADINPUT; ErrMsg = 'CD_HFMF_Set_Held_Fluid: module not initialised'; RETURN
    END IF
    IF (SIZE(fluid_velocity, 1) /= 3 .OR. SIZE(fluid_velocity, 2) /= self%line%nn .OR. &
        SIZE(fluid_acceleration, 1) /= 3 .OR. SIZE(fluid_acceleration, 2) /= self%line%nn) THEN
      ErrStat = CD_HFMF_BADINPUT
      ErrMsg = 'CD_HFMF_Set_Held_Fluid: fluid arrays must be shaped (3, nn)'; RETURN
    END IF
    has_heading = ABS(self%frame_s) > CD_ZERO .OR. ABS(self%frame_c - CD_ONE) > CD_ZERO
    IF (has_heading) THEN
      BLOCK
        REAL(wp) :: u_loc(3, self%line%nn), ud_loc(3, self%line%nn)
        DO i = 1, self%line%nn
          u_loc(:, i) = frame_to_local(self, fluid_velocity(:, i))
          ud_loc(:, i) = frame_to_local(self, fluid_acceleration(:, i))
        END DO
        CALL CD_HermiteCable_Dyn_Set_Held_Fluid(self%line, u_loc, ud_loc, waterline_z, es, em)
      END BLOCK
    ELSE
      CALL CD_HermiteCable_Dyn_Set_Held_Fluid(self%line, fluid_velocity, fluid_acceleration, waterline_z, es, em)
    END IF
    IF (es /= CD_HCDYN_OK) THEN
      ErrStat = CD_HFMF_BADINPUT; ErrMsg = 'CD_HFMF_Set_Held_Fluid: '//TRIM(em)
    END IF
  END SUBROUTINE CD_HFMF_Set_Held_Fluid

  SUBROUTINE CD_HFMF_Set_Contact(self, kn_node, cn_node, mu, ErrStat, ErrMsg, bathymetry)
    !! Configure standalone nodal seabed contact through the FMF owner. Bathymetry
    !! coordinates are global; the stored cable heading is forwarded for query rotation.
    TYPE(CD_HFMF_ModuleType), INTENT(INOUT) :: self
    REAL(wp), INTENT(IN) :: kn_node(:), cn_node(:), mu
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    TYPE(CD_BathymetryType), INTENT(IN), OPTIONAL :: bathymetry
    INTEGER :: es
    CHARACTER(1024) :: em

    ErrStat = CD_HFMF_OK; ErrMsg = ''
    IF (.NOT. self%initialized) THEN
      ErrStat = CD_HFMF_BADINPUT; ErrMsg = 'CD_HFMF_Set_Contact: module not initialised'; RETURN
    END IF
    IF (PRESENT(bathymetry)) THEN
      CALL CD_HermiteCable_Dyn_Set_Contact(self%line, kn_node, cn_node, mu, es, em, &
                                           bathymetry=bathymetry, frame_cs=[self%frame_c, self%frame_s])
    ELSE
      CALL CD_HermiteCable_Dyn_Set_Contact(self%line, kn_node, cn_node, mu, es, em, &
                                           frame_cs=[self%frame_c, self%frame_s])
    END IF
    IF (es /= CD_HCDYN_OK) THEN
      ErrStat = CD_HFMF_BADINPUT; ErrMsg = 'CD_HFMF_Set_Contact: '//TRIM(em)
    END IF
  END SUBROUTINE CD_HFMF_Set_Contact

  SUBROUTINE CD_HFMF_Set_SegmentLength(self, elems, l0_new, l0_dot, ErrStat, ErrMsg, restored)
    !! Active line control through the FMF owner: set the unstretched lengths and their rates
    !! of the listed elements before the next UpdateStates (CD_HermiteCable_Dyn_Set_SegmentLength).
    !! Lengths do not depend on the frame, so the cable heading plays no part.
    TYPE(CD_HFMF_ModuleType), INTENT(INOUT) :: self
    INTEGER, INTENT(IN) :: elems(:)
    REAL(wp), INTENT(IN) :: l0_new(:), l0_dot(:)
    LOGICAL, INTENT(IN), OPTIONAL :: restored
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    INTEGER :: es
    CHARACTER(1024) :: em

    ErrStat = CD_HFMF_OK; ErrMsg = ''
    IF (.NOT. self%initialized) THEN
      ErrStat = CD_HFMF_BADINPUT; ErrMsg = 'CD_HFMF_Set_SegmentLength: module not initialised'; RETURN
    END IF
    CALL CD_HermiteCable_Dyn_Set_SegmentLength(self%line, elems, l0_new, l0_dot, es, em, restored=restored)
    IF (es /= CD_HCDYN_OK) THEN
      ErrStat = CD_HFMF_BADINPUT; ErrMsg = 'CD_HFMF_Set_SegmentLength: '//TRIM(em)
    END IF
  END SUBROUTINE CD_HFMF_Set_SegmentLength

  SUBROUTINE CD_HFMF_Refresh_Acceleration(self, ErrStat, ErrMsg)
    !! Recompute free-node acceleration after a direct-feedthrough boundary commit.
    !! The caller-prescribed coupled acceleration participates in the consistent-mass
    !! solve, including its off-diagonal coupling to the interior predictor state.
    TYPE(CD_HFMF_ModuleType), INTENT(INOUT) :: self
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    INTEGER :: es, pd(6)
    REAL(wp) :: coupled_a(3), pa(6)
    CHARACTER(1024) :: em

    ErrStat = CD_HFMF_OK; ErrMsg = ''
    IF (.NOT. self%initialized) THEN
      ErrStat = CD_HFMF_BADINPUT; ErrMsg = 'CD_HFMF_Refresh_Acceleration: module not initialised'; RETURN
    END IF
    IF (self%moving_b .AND. .NOT. end_b_at_rest(self)) THEN
      ! a moving End B's prescribed acceleration enters the consistent-mass solve as End A's does
      pd(1:3) = self%pdof
      pd(4:6) = self%pdof_b
      pa(1:3) = self%line%a(self%pdof)
      pa(4:6) = self%line%a(self%pdof_b)
      CALL CD_HermiteCable_Dyn_Recompute_Acceleration(self%line, es, em, pres_dofs=pd, pres_a=pa)
    ELSE
      coupled_a = self%line%a(self%pdof)
      CALL CD_HermiteCable_Dyn_Recompute_Acceleration(self%line, es, em, &
                                                      pres_dofs=self%pdof, pres_a=coupled_a)
    END IF
    IF (es /= CD_HCDYN_OK) THEN
      ErrStat = CD_HFMF_BADINPUT; ErrMsg = 'CD_HFMF_Refresh_Acceleration: '//TRIM(em); RETURN
    END IF
  END SUBROUTINE CD_HFMF_Refresh_Acceleration

  INTEGER FUNCTION CD_HFMF_Twist_Lin_Count(self) RESULT(n)
    !! Number of the cable's nodal-twist linearisation states of one kind: the free twist angles,
    !! at every node but a torsionally rigid end (whose angle is held). Zero without torsion and
    !! for the condensed torsion, whose torque M = (Phi - Theta(q))/C is an algebraic function of
    !! the configuration and the end frames with no state of its own.
    TYPE(CD_HFMF_ModuleType), INTENT(IN) :: self
    n = 0
    IF (.NOT. self%initialized) RETURN
    IF (.NOT. self%line%tw_active) RETURN
    n = COUNT(self%line%tw_free)
  END FUNCTION CD_HFMF_Twist_Lin_Count

  SUBROUTINE CD_HFMF_Twist_Lin_Slots(self, phi_slot, rate_slot, acc_slot, node, ErrStat, ErrMsg)
    !! The slots, 1-based in this cable's CD_HFMF_PackMirror buffer, of the free twist angles phi,
    !! their rates and their accelerations, with their model nodes (End B = node 1), in node order;
    !! each array is sized CD_HFMF_Twist_Lin_Count. Angles, rates and accelerations are the first
    !! three nn-blocks of the nodal-twist tail that closes the torsion block
    !! (CD_HermiteCable_Dyn_Twist_Pack), so the slots of the free nodes are consecutive.
    TYPE(CD_HFMF_ModuleType), INTENT(IN) :: self
    INTEGER, INTENT(OUT) :: phi_slot(:), rate_slot(:), acc_slot(:), node(:)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    INTEGER :: k0, i, k, n
    ErrStat = CD_HFMF_OK
    ErrMsg = ''
    phi_slot = 0
    rate_slot = 0
    acc_slot = 0
    node = 0
    n = CD_HFMF_Twist_Lin_Count(self)
    IF (SIZE(phi_slot) /= n .OR. SIZE(rate_slot) /= n .OR. SIZE(acc_slot) /= n .OR. SIZE(node) /= n) THEN
      ErrStat = CD_HFMF_BADINPUT
      ErrMsg = 'CD_HFMF_Twist_Lin_Slots: the slot arrays must be sized CD_HFMF_Twist_Lin_Count'
      RETURN
    END IF
    IF (n == 0) RETURN
    k0 = CD_HFMF_MirrorSize(self) - CD_HermiteCable_Dyn_Twist_Mirror_Size(self%line)
    k = 0
    DO i = 1, self%line%nn
      IF (.NOT. self%line%tw_free(i)) CYCLE
      k = k + 1
      phi_slot(k) = k0 + i
      rate_slot(k) = k0 + self%line%nn + i
      acc_slot(k) = k0 + 2*self%line%nn + i
      node(k) = i
    END DO
  END SUBROUTINE CD_HFMF_Twist_Lin_Slots

  SUBROUTINE CD_HFMF_Set_Twist_Frame_Rates(self, ErrStat, ErrMsg)
    !! Linearisation of the nodal twist: give the parent-attached end frame the angular velocity
    !! and acceleration of the parent last written (CD_HFMF_SetCoupledKinematics), the rates a
    !! time step takes from the frame's turn over the step (tw_om, tw_oal of the committed step).
    !! The frame turns rigidly with the parent, so its rates are the parent's, here in the solve
    !! frame. With them the torsional damping of the element at a rigid end takes the frame's
    !! turning rate, (Bt/l0) drho/dw . omega, and the reaction moment the polar inertia of the held
    !! end section, as in the march; without them a linearisation would hold both at the committed
    !! rates. A no-op without the nodal twist or a parent-attached frame. The caller restores the
    !! committed rates with the mirror (CD_HFMF_UnpackMirror).
    TYPE(CD_HFMF_ModuleType), INTENT(INOUT) :: self
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    ErrStat = CD_HFMF_OK
    ErrMsg = ''
    IF (.NOT. self%initialized) THEN
      ErrStat = CD_HFMF_BADINPUT; ErrMsg = 'CD_HFMF_Set_Twist_Frame_Rates: module not initialised'; RETURN
    END IF
    IF (.NOT. (self%tors_parent .AND. self%line%tw_active)) RETURN
    self%line%tw_om(:, self%tors_index) = frame_to_local(self, self%parent_omega)
    self%line%tw_oal(:, self%tors_index) = frame_to_local(self, self%parent_alpha)
  END SUBROUTINE CD_HFMF_Set_Twist_Frame_Rates

  INTEGER FUNCTION CD_HFMF_NNodes(self) RESULT(n)
    !! Node count of the owned cable (the held-fluid sampling surface). Zero if
    !! uninitialised.
    TYPE(CD_HFMF_ModuleType), INTENT(IN) :: self
    n = 0
    IF (self%initialized) n = self%line%nn
  END FUNCTION CD_HFMF_NNodes

  SUBROUTINE CD_HFMF_GetNodePositions(self, xyz, ErrStat, ErrMsg)
    !! Current committed positions of every cable node -- where the host samples its
    !! wave field for CD_HFMF_Set_Held_Fluid. Positions are rotated from the cable's
    !! local solve frame to the caller's global frame (frame_to_global), so the host
    !! always samples at true global coordinates.
    TYPE(CD_HFMF_ModuleType), INTENT(IN) :: self
    REAL(wp), INTENT(OUT) :: xyz(:, :)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    INTEGER :: i
    xyz = CD_ZERO
    ErrStat = CD_HFMF_OK; ErrMsg = ''
    IF (.NOT. self%initialized) THEN
      ErrStat = CD_HFMF_BADINPUT; ErrMsg = 'CD_HFMF_GetNodePositions: module not initialised'; RETURN
    END IF
    IF (SIZE(xyz, 1) /= 3 .OR. SIZE(xyz, 2) /= self%line%nn) THEN
      ErrStat = CD_HFMF_BADINPUT
      ErrMsg = 'CD_HFMF_GetNodePositions: array must be shaped (3, nn)'; RETURN
    END IF
    DO i = 1, self%line%nn
      xyz(:, i) = frame_to_global(self, self%line%q(6*(i - 1) + 1:6*(i - 1) + 3))
    END DO
  END SUBROUTINE CD_HFMF_GetNodePositions

  SUBROUTINE CD_HFMF_CalcOutput(self, y_fair, ErrStat, ErrMsg, y_moment, y_end_b, y_moment_b)
    !! The FMF loads-out boundary: the force the cable exerts ON the platform at the
    !! coupled endpoint, at the current committed state (global coordinates, N). y_end_b and
    !! y_moment_b return the same for internal node 1 (deck End B): the load on a moving End B's
    !! host (or on the anchor of a held one).
    TYPE(CD_HFMF_ModuleType), INTENT(INOUT) :: self
    REAL(wp), INTENT(OUT) :: y_fair(3)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    REAL(wp), INTENT(OUT), OPTIONAL :: y_moment(3), y_end_b(3), y_moment_b(3)
    INTEGER :: es
    CHARACTER(1024) :: em
    ErrStat = CD_HFMF_OK; ErrMsg = ''; y_fair = CD_ZERO
    IF (PRESENT(y_moment)) y_moment = CD_ZERO
    IF (PRESENT(y_end_b)) y_end_b = CD_ZERO
    IF (PRESENT(y_moment_b)) y_moment_b = CD_ZERO
    IF (.NOT. self%initialized) THEN
      ErrStat = CD_HFMF_BADINPUT; ErrMsg = 'CD_HFMF_CalcOutput: module not initialised'; RETURN
    END IF
    CALL CD_HermiteCable_Dyn_Reaction(self%line, self%coupled_node, y_fair, es, em)
    IF (es /= CD_HCDYN_OK) THEN
      ErrStat = CD_HFMF_SOLVEFAIL; ErrMsg = 'CD_HFMF_CalcOutput: '//TRIM(em)
      RETURN
    END IF
    y_fair = frame_to_global(self, y_fair)
    IF (PRESENT(y_moment)) THEN
      CALL CD_HermiteCable_Dyn_EndConnection_Moment(self%line, self%coupled_node, y_moment, es, em)
      IF (es /= CD_HCDYN_OK) THEN
        ErrStat = CD_HFMF_SOLVEFAIL
        ErrMsg = 'CD_HFMF_CalcOutput: '//TRIM(em)
        RETURN
      END IF
      y_moment = frame_to_global(self, y_moment)
    END IF
    IF (PRESENT(y_end_b)) THEN
      CALL CD_HermiteCable_Dyn_Reaction(self%line, 1, y_end_b, es, em)
      IF (es /= CD_HCDYN_OK) THEN
        ErrStat = CD_HFMF_SOLVEFAIL; ErrMsg = 'CD_HFMF_CalcOutput: End B: '//TRIM(em)
        RETURN
      END IF
      y_end_b = frame_to_global(self, y_end_b)
    END IF
    IF (PRESENT(y_moment_b)) THEN
      CALL CD_HermiteCable_Dyn_EndConnection_Moment(self%line, 1, y_moment_b, es, em)
      IF (es /= CD_HCDYN_OK) THEN
        ErrStat = CD_HFMF_SOLVEFAIL; ErrMsg = 'CD_HFMF_CalcOutput: End B: '//TRIM(em)
        RETURN
      END IF
      y_moment_b = frame_to_global(self, y_moment_b)
    END IF
  END SUBROUTINE CD_HFMF_CalcOutput

  PURE FUNCTION identity_dcm() RESULT(dcm)
    REAL(wp) :: dcm(3, 3)
    dcm = CD_ZERO
    dcm(1, 1) = CD_ONE
    dcm(2, 2) = CD_ONE
    dcm(3, 3) = CD_ONE
  END FUNCTION identity_dcm

  PURE FUNCTION cross3(a, b) RESULT(c)
    REAL(wp), INTENT(IN) :: a(3), b(3)
    REAL(wp) :: c(3)
    c = [a(2)*b(3) - a(3)*b(2), a(3)*b(1) - a(1)*b(3), a(1)*b(2) - a(2)*b(1)]
  END FUNCTION cross3

  PURE SUBROUTINE direction_rotation(from_direction, to_direction, rotation, ErrStat, ErrMsg)
    !! Shortest proper rotation carrying one unit direction into another. Used
    !! only by the non-stepping rigid-boundary overlay, so tangent state remains
    !! kinematically aligned when OpenFAST probes loads at a new orientation.
    REAL(wp), INTENT(IN) :: from_direction(3), to_direction(3)
    REAL(wp), INTENT(OUT) :: rotation(3, 3)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    REAL(wp) :: a(3), b(3), v(3), skew(3, 3), n1, n2, c, s2

    rotation = identity_dcm()
    ErrStat = CD_ENDCONN_OK
    ErrMsg = ''
    n1 = SQRT(DOT_PRODUCT(from_direction, from_direction))
    n2 = SQRT(DOT_PRODUCT(to_direction, to_direction))
    IF (.NOT. CD_Is_Finite(n1) .OR. .NOT. CD_Is_Finite(n2) .OR. &
        n1 <= SQRT(TINY(CD_ONE)) .OR. n2 <= SQRT(TINY(CD_ONE))) THEN
      ErrStat = CD_ENDCONN_BADINPUT
      ErrMsg = 'directions must be finite and non-null'
      RETURN
    END IF
    a = from_direction/n1
    b = to_direction/n2
    c = MAX(-CD_ONE, MIN(CD_ONE, DOT_PRODUCT(a, b)))
    IF (c <= -CD_ONE + 64.0_wp*EPSILON(CD_ONE)) THEN
      ErrStat = CD_ENDCONN_BADINPUT
      ErrMsg = 'a 180-degree direction change has no unique shortest rotation'
      RETURN
    END IF
    v = [a(2)*b(3) - a(3)*b(2), a(3)*b(1) - a(1)*b(3), a(1)*b(2) - a(2)*b(1)]
    s2 = DOT_PRODUCT(v, v)
    IF (s2 <= 64.0_wp*EPSILON(CD_ONE)) RETURN
    skew = RESHAPE([CD_ZERO, v(3), -v(2), -v(3), CD_ZERO, v(1), &
                    v(2), -v(1), CD_ZERO], [3, 3])
    rotation = rotation + skew + MATMUL(skew, skew)*(CD_ONE - c)/s2
  END SUBROUTINE direction_rotation

  PURE LOGICAL FUNCTION valid_parent_dcm(dcm) RESULT(valid)
    !! OpenFAST mesh orientations are proper global-to-local direction-cosine
    !! matrices. Reject reflections and matrices that would change vector norms.
    REAL(wp), INTENT(IN) :: dcm(3, 3)
    REAL(wp) :: gram(3, 3), det
    valid = .FALSE.
    IF (.NOT. CD_All_Finite(dcm)) RETURN
    gram = MATMUL(dcm, TRANSPOSE(dcm))
    det = dcm(1, 1)*(dcm(2, 2)*dcm(3, 3) - dcm(2, 3)*dcm(3, 2)) - &
          dcm(1, 2)*(dcm(2, 1)*dcm(3, 3) - dcm(2, 3)*dcm(3, 1)) + &
          dcm(1, 3)*(dcm(2, 1)*dcm(3, 2) - dcm(2, 2)*dcm(3, 1))
    valid = MAXVAL(ABS(gram - identity_dcm())) <= 1.0e-8_wp .AND. ABS(det - CD_ONE) <= 1.0e-8_wp
  END FUNCTION valid_parent_dcm

  PURE FUNCTION frame_is_identity(self) RESULT(is_id)
    !! Exact identity-heading test. Order comparisons preserve the bit-for-bit identity
    !! fast path without tripping -Wcompare-reals.
    TYPE(CD_HFMF_ModuleType), INTENT(IN) :: self
    LOGICAL :: is_id
    is_id = .NOT. (ABS(self%frame_s) > CD_ZERO .OR. ABS(self%frame_c - CD_ONE) > CD_ZERO)
  END FUNCTION frame_is_identity

  PURE FUNCTION frame_to_local(self, v) RESULT(vl)
    !! Rotate a caller-global vector into the cable's local solve frame (about +z by the
    !! stored heading). Identity heading returns v unchanged, preserving bit-for-bit
    !! behavior on every pre-existing (x-z plane) cable.
    TYPE(CD_HFMF_ModuleType), INTENT(IN) :: self
    REAL(wp), INTENT(IN) :: v(3)
    REAL(wp) :: vl(3)
    IF (frame_is_identity(self)) THEN
      vl = v
    ELSE
      vl = [self%frame_c*v(1) + self%frame_s*v(2), &
            -self%frame_s*v(1) + self%frame_c*v(2), v(3)]
    END IF
  END FUNCTION frame_to_local

  PURE FUNCTION frame_to_global(self, v) RESULT(vg)
    !! Rotate a cable-local vector back to the caller's global frame (the transpose of
    !! frame_to_local). Identity heading returns v unchanged.
    TYPE(CD_HFMF_ModuleType), INTENT(IN) :: self
    REAL(wp), INTENT(IN) :: v(3)
    REAL(wp) :: vg(3)
    IF (frame_is_identity(self)) THEN
      vg = v
    ELSE
      vg = [self%frame_c*v(1) - self%frame_s*v(2), &
            self%frame_s*v(1) + self%frame_c*v(2), v(3)]
    END IF
  END FUNCTION frame_to_global

  SUBROUTINE CD_HFMF_Curvature(self, curv_out, ErrStat, ErrMsg)
    !! Nodal curvature at the current state, the definition of the Curv<L>N<J> channels
    !! (CD_HermiteCable_Dyn_Curvature: recovered from nodal equilibrium by default).
    TYPE(CD_HFMF_ModuleType), INTENT(INOUT) :: self
    REAL(wp), INTENT(OUT) :: curv_out(:)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    INTEGER :: es
    CHARACTER(1024) :: em
    ErrStat = CD_HFMF_OK; ErrMsg = ''
    IF (.NOT. self%initialized) THEN
      ErrStat = CD_HFMF_BADINPUT; ErrMsg = 'CD_HFMF_Curvature: module not initialised'; RETURN
    END IF
    CALL CD_HermiteCable_Dyn_Curvature(self%line, curv_out, es, em)
    IF (es /= CD_HCDYN_OK) THEN
      ErrStat = CD_HFMF_BADINPUT; ErrMsg = 'CD_HFMF_Curvature: '//TRIM(em)
    END IF
  END SUBROUTINE CD_HFMF_Curvature

  SUBROUTINE CD_HFMF_Set_Section_Reference(self, ErrStat, ErrMsg)
    !! Freeze the cross-section reference of the CurvX/CurvY channels at the current (static)
    !! state: the normal at End A of the End A -> End B tangent t nearest global +z, the section's
    !! upper side (global +x where t is vertical). It is kept in global axes and, when End A is
    !! connected to a parent (a clamped or finite-stiffness end connection), in the parent's axes,
    !! in which it then turns with the parent. A line restrained in torsion takes its End A torsion
    !! normal instead (CD_HermiteCable_Dyn_Section_Curvature).
    TYPE(CD_HFMF_ModuleType), INTENT(INOUT) :: self
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    REAL(wp) :: t(3), r(3), up(3), tn
    INTEGER :: nn
    ErrStat = CD_HFMF_OK; ErrMsg = ''
    IF (.NOT. self%initialized) THEN
      ErrStat = CD_HFMF_BADINPUT; ErrMsg = 'CD_HFMF_Set_Section_Reference: module not initialised'; RETURN
    END IF
    nn = self%line%nn
    ! End A is the last internal node; its internal tangent points away from End B
    t = -frame_to_global(self, self%line%q(6*(nn - 1) + 4:6*(nn - 1) + 6))
    tn = NORM2(t)
    IF (.NOT. tn > CD_ZERO) THEN
      ErrStat = CD_HFMF_BADINPUT; ErrMsg = 'CD_HFMF_Set_Section_Reference: degenerate End A tangent'; RETURN
    END IF
    t = t/tn
    up = [CD_ZERO, CD_ZERO, CD_ONE]
    IF (ABS(t(3)) > CD_ONE - 1.0e-6_wp) up = [CD_ONE, CD_ZERO, CD_ZERO]
    r = up - DOT_PRODUCT(up, t)*t
    r = r/NORM2(r)
    self%sect_ref_global = r
    self%sect_ref_parent = MATMUL(self%parent_dcm, r)
    self%has_sect_ref = .TRUE.
    self%sc_valid = .FALSE.
  END SUBROUTINE CD_HFMF_Set_Section_Reference

  SUBROUTINE CD_HFMF_Section_Curvature(self, kx, ky, ErrStat, ErrMsg)
    !! The CurvX/CurvY channels of every node (internal order): the curvature vector on the
    !! cross-section axes (CD_HermiteCable_Dyn_Section_Curvature), with the reference of
    !! CD_HFMF_Set_Section_Reference, turned with the parent when End A is connected to one.
    TYPE(CD_HFMF_ModuleType), INTENT(INOUT) :: self
    REAL(wp), INTENT(OUT) :: kx(:), ky(:)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    REAL(wp) :: r(3), tors(15)
    INTEGER :: es, nn
    CHARACTER(1024) :: em
    ErrStat = CD_HFMF_OK; ErrMsg = ''
    kx = CD_ZERO
    ky = CD_ZERO
    IF (.NOT. (self%initialized .AND. self%has_sect_ref)) THEN
      ErrStat = CD_HFMF_BADINPUT
      ErrMsg = 'CD_HFMF_Section_Curvature: module not initialised or without a section reference'; RETURN
    END IF
    nn = self%line%nn
    IF (SIZE(kx) /= nn .OR. SIZE(ky) /= nn) THEN
      ErrStat = CD_HFMF_BADINPUT; ErrMsg = 'CD_HFMF_Section_Curvature: kx, ky must be nn'; RETURN
    END IF
    IF (self%has_parent_endconn) THEN
      r = MATMUL(TRANSPOSE(self%parent_dcm), self%sect_ref_parent)
    ELSE
      r = self%sect_ref_global
    END IF
    r = frame_to_local(self, r)
    tors = CD_ZERO
    IF (self%line%torsion%active) tors = [RESHAPE(self%line%torsion%ends, [12]), self%line%torsion%theta, &
                                          self%line%torsion%phi, self%line%torsion%torque]
    IF (self%sc_valid .AND. self%sc_epoch == self%line%rc_epoch) THEN
      ! exact equality (a NaN never matches)
      IF (ALL(ABS(self%sc_ref - r) <= CD_ZERO) .AND. ABS(self%sc_t - self%line%t) <= CD_ZERO .AND. &
          ALL(ABS(self%sc_tors - tors) <= CD_ZERO) .AND. &
          ALL(ABS(self%sc_q - self%line%q) <= CD_ZERO) .AND. ALL(ABS(self%sc_v - self%line%v) <= CD_ZERO) .AND. &
          ALL(ABS(self%sc_a - self%line%a) <= CD_ZERO)) THEN
        kx = self%sc_kx
        ky = self%sc_ky
        RETURN
      END IF
    END IF
    self%sc_valid = .FALSE.
    CALL CD_HermiteCable_Dyn_Section_Curvature(self%line, r, kx, ky, es, em)
    IF (es /= CD_HCDYN_OK) THEN
      ErrStat = CD_HFMF_BADINPUT; ErrMsg = 'CD_HFMF_Section_Curvature: '//TRIM(em); RETURN
    END IF
    self%sc_ref = r
    self%sc_tors = tors
    self%sc_t = self%line%t
    self%sc_epoch = self%line%rc_epoch
    self%sc_q = self%line%q
    self%sc_v = self%line%v
    self%sc_a = self%line%a
    self%sc_kx = kx
    self%sc_ky = ky
    self%sc_valid = .TRUE.
  END SUBROUTINE CD_HFMF_Section_Curvature

  SUBROUTINE CD_HFMF_Curvature_Exact(self, curv_out, ErrStat, ErrMsg)
    !! Nodal geometric curvature of the cubic-Hermite centreline at the current state, the larger
    !! one-sided trace at an interior node (CD_HermiteCable_Dyn_Curvature_Exact).
    TYPE(CD_HFMF_ModuleType), INTENT(INOUT) :: self
    REAL(wp), INTENT(OUT) :: curv_out(:)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    INTEGER :: es
    CHARACTER(1024) :: em
    ErrStat = CD_HFMF_OK; ErrMsg = ''
    IF (.NOT. self%initialized) THEN
      ErrStat = CD_HFMF_BADINPUT; ErrMsg = 'CD_HFMF_Curvature_Exact: module not initialised'; RETURN
    END IF
    CALL CD_HermiteCable_Dyn_Curvature_Exact(self%line, curv_out, es, em)
    IF (es /= CD_HCDYN_OK) THEN
      ErrStat = CD_HFMF_BADINPUT; ErrMsg = 'CD_HFMF_Curvature_Exact: '//TRIM(em)
    END IF
  END SUBROUTINE CD_HFMF_Curvature_Exact

  REAL(wp) FUNCTION CD_HFMF_MinSpanZ(self) RESULT(zmin)
    !! Minimum global z along the cubic-Hermite CENTRELINE (its static-seeded shape), computed
    !! EXACTLY per element from the cubic's stationary points -- NOT by fixed sampling. On each
    !! element z(xi) is a cubic on [0,1]; a cubic can dip below both endpoint nodes (and below a
    !! declared seabed) BETWEEN any finite set of samples, so its minimum is taken over the two
    !! endpoints {xi=0, xi=1} plus any real root of dz/dxi (a quadratic) that lies in (0,1) --
    !! exact for the cubic. The aggregate uses this to decide whether a suspended cable actually
    !! reaches a declared seabed (a grounded/touchdown cable the pinned kn=0 static cannot
    !! represent). Returns HUGE for an uninitialised module (no shape -> never flagged grounded).
    TYPE(CD_HFMF_ModuleType), INTENT(IN) :: self
    INTEGER :: e, b1, b2, nc, ic
    REAL(wp) :: z1, mz1, z2, mz2, Lel
    REAL(wp) :: Aq, Bq, Cq, dz0, dz1, dzh, disc, sq, scal
    REAL(wp) :: cand(4), Hs(4), dHs(4), zc
    zmin = HUGE(0.0_wp)
    IF (.NOT. self%initialized) RETURN
    DO e = 1, self%line%ne
      b1 = 6*(e - 1)                          ! node e   base DOF (r,m): z at +3, tangent-z at +6
      b2 = 6*e                                ! node e+1 base DOF
      Lel = self%line%l0(e)
      z1 = self%line%q(b1 + 3); mz1 = self%line%q(b1 + 6)
      z2 = self%line%q(b2 + 3); mz2 = self%line%q(b2 + 6)
      ! z(xi) is a cubic; dz/dxi(xi) = Aq xi^2 + Bq xi + Cq is a quadratic. Recover A, B, C from
      ! dz/dxi at xi = 0, 1, 1/2:  Cq = dz(0);  Aq+Bq+Cq = dz(1);  Aq/4+Bq/2+Cq = dz(1/2).
      CALL CD_HermiteCable_Shapes(0.0_wp, Lel, Hs, dHs)
      dz0 = dHs(1)*z1 + dHs(2)*mz1 + dHs(3)*z2 + dHs(4)*mz2
      CALL CD_HermiteCable_Shapes(1.0_wp, Lel, Hs, dHs)
      dz1 = dHs(1)*z1 + dHs(2)*mz1 + dHs(3)*z2 + dHs(4)*mz2
      CALL CD_HermiteCable_Shapes(0.5_wp, Lel, Hs, dHs)
      dzh = dHs(1)*z1 + dHs(2)*mz1 + dHs(3)*z2 + dHs(4)*mz2
      Cq = dz0
      Aq = 2.0_wp*(dz1 + Cq - 2.0_wp*dzh)
      Bq = dz1 - Cq - Aq
      ! Candidate abscissae: the two endpoints always, plus real roots of dz/dxi strictly in (0,1).
      nc = 2
      cand(1) = 0.0_wp
      cand(2) = 1.0_wp
      scal = ABS(Aq) + ABS(Bq) + ABS(Cq)
      IF (scal > 0.0_wp) THEN
        IF (ABS(Aq) <= 1.0e-12_wp*scal) THEN
          ! (near-)linear dz/dxi: a single stationary point at -Cq/Bq when Bq is non-degenerate.
          IF (ABS(Bq) > 1.0e-12_wp*scal) CALL add_interior_root(-Cq/Bq, cand, nc)
        ELSE
          disc = Bq*Bq - 4.0_wp*Aq*Cq
          IF (disc >= 0.0_wp) THEN
            sq = SQRT(disc)
            CALL add_interior_root((-Bq + sq)/(2.0_wp*Aq), cand, nc)
            CALL add_interior_root((-Bq - sq)/(2.0_wp*Aq), cand, nc)
          END IF
        END IF
      END IF
      DO ic = 1, nc
        CALL CD_HermiteCable_Shapes(cand(ic), Lel, Hs, dHs)
        ! z(xi) = H1 z1 + H2 mz1 + H3 z2 + H4 mz2  (DOF order [r1, m1, r2, m2]; z is comp 3)
        zc = Hs(1)*z1 + Hs(2)*mz1 + Hs(3)*z2 + Hs(4)*mz2
        zmin = MIN(zmin, zc)
      END DO
    END DO

  CONTAINS
    SUBROUTINE add_interior_root(xi, xs, n)
      !! Append xi to the candidate list xs (count n) only when it is a strict interior stationary
      !! point (0,1); endpoints are already candidates, so a root at/beyond a boundary adds nothing.
      REAL(wp), INTENT(IN) :: xi
      REAL(wp), INTENT(INOUT) :: xs(:)
      INTEGER, INTENT(INOUT) :: n
      IF (xi > 0.0_wp .AND. xi < 1.0_wp) THEN
        n = n + 1
        xs(n) = xi
      END IF
    END SUBROUTINE add_interior_root
  END FUNCTION CD_HFMF_MinSpanZ

  INTEGER FUNCTION CD_HFMF_MirrorSize(self) RESULT(n)
    !! Number of continuous-state mirror slots this cable contributes to the OpenFAST state
    !! vector: the free (non-prescribed, non-fixed) DOF velocities, positions, and
    !! accelerations, [v_free; q_free; a_free], so n = 3 * (number of free DOFs). The
    !! acceleration block exists for CHECKPOINT-RESTART: the generalised-alpha step
    !! carries the committed acceleration, and unlike the EI=0 side (whose acceleration
    !! is re-derived by CD_Recompute_System_Acceleration) the cable reloads it exactly.
    !! A cable on a frictional seabed appends its stick-slip friction anchors, (x, y) per
    !! node (CD_HFMF_FrictionMirrorSize slots): they are committed state like q. Then come
    !! the committed boundary (CD_HFMF_BoundaryMirrorSize), the force-blend state, the VIV
    !! state and the torsion state. Zero if uninitialised.
    TYPE(CD_HFMF_ModuleType), INTENT(IN) :: self
    n = 0
    IF (.NOT. self%initialized) RETURN
    IF (ALLOCATED(self%line%freemask)) n = 3*COUNT(self%line%freemask)
    n = n + CD_HFMF_FrictionMirrorSize(self) + CD_HFMF_BoundaryMirrorSize(self) + &
        CD_HFMF_ForceMirrorSize(self) + CD_HFMF_VIVMirrorSize(self) + CD_HFMF_TorsionMirrorSize(self)
  END FUNCTION CD_HFMF_MirrorSize

  INTEGER FUNCTION CD_HFMF_BoundaryMirrorSize(self) RESULT(n)
    !! Mirror slots of the committed boundary: [q; v; a] of the held (prescribed or fixed)
    !! DOFs, the end-connection directions (6) and the parent frame the coupled end was
    !! committed with (orientation 9, angular velocity 3, angular acceleration 3). A restart
    !! rebuild moves the coupled end to the host's restored input mesh, the glue's input at
    !! the restart time, which need not carry the bits the uninterrupted run committed (with
    !! NumCrctn = 0 that run stepped with the extrapolated input); reloading this block after
    !! the move continues from exactly the committed state. A moving End B adds its parent frame
    !! (orientation 9, angular velocity 3, angular acceleration 3).
    TYPE(CD_HFMF_ModuleType), INTENT(IN) :: self
    n = 0
    IF (.NOT. self%initialized) RETURN
    n = 3*(self%line%ndof - COUNT(self%line%freemask)) + 21
    IF (self%moving_b) n = n + 15
  END FUNCTION CD_HFMF_BoundaryMirrorSize

  INTEGER FUNCTION CD_HFMF_TorsionMirrorSize(self) RESULT(n)
    !! Mirror slots of the torsion, last: the accepted (unwrapped) Theta, Phi and the four
    !! end-frame vectors (14 values), then the nodal twist's state with its committed torque
    !! (CD_HermiteCable_Dyn_Twist_Mirror_Size); zero without torsion. The condensed torque is
    !! re-derived on a reload, (Phi - Theta)/C at the re-applied (committed) lengths, which is
    !! how every step and frame write forms it.
    TYPE(CD_HFMF_ModuleType), INTENT(IN) :: self
    n = 0
    IF (.NOT. self%initialized) RETURN
    IF (self%line%torsion%active) n = 14 + CD_HermiteCable_Dyn_Twist_Mirror_Size(self%line)
  END FUNCTION CD_HFMF_TorsionMirrorSize

  INTEGER FUNCTION CD_HFMF_ForceMirrorSize(self) RESULT(n)
    !! Mirror slots of the force-blended generalised-alpha integrator state beyond the free
    !! and boundary blocks: a validity flag and the committed force F_n (ndof values); zero
    !! with the configuration blend. The force blend carries F_n into the next step, so a
    !! restart reloads it instead of re-evaluating it.
    TYPE(CD_HFMF_ModuleType), INTENT(IN) :: self
    n = 0
    IF (.NOT. self%initialized) RETURN
    IF (self%line%force_blend) n = 1 + self%line%ndof
  END FUNCTION CD_HFMF_ForceMirrorSize

  INTEGER FUNCTION CD_HFMF_VIVMirrorSize(self) RESULT(n)
    !! Mirror slots of the cross-flow VIV state, before the torsion block: the shedding phase
    !! per node, the running mean squares of the cross-flow velocity and acceleration per node
    !! (interleaved) and the averaging time (3 nn + 1 values); zero without VIV.
    TYPE(CD_HFMF_ModuleType), INTENT(IN) :: self
    n = 0
    IF (.NOT. self%initialized) RETURN
    IF (self%line%has_viv) n = 3*self%line%nn + 1
  END FUNCTION CD_HFMF_VIVMirrorSize

  INTEGER FUNCTION CD_HFMF_FrictionMirrorSize(self) RESULT(n)
    !! Mirror slots of the stick-slip friction anchors (2 per node), zero without friction.
    TYPE(CD_HFMF_ModuleType), INTENT(IN) :: self
    n = 0
    IF (.NOT. self%initialized) RETURN
    IF (self%line%fr_active) n = 2*self%line%nn
  END FUNCTION CD_HFMF_FrictionMirrorSize

  SUBROUTINE CD_HFMF_PackMirror(self, buf, ErrStat, ErrMsg)
    !! Write the cable's continuous state into buf as [v_free; q_free; a_free], then the
    !! friction, boundary, force-blend, VIV and torsion blocks -- the layout CD_HFMF_MirrorSize
    !! sizes. The mirror is written every mooring step and reloaded ONLY by a
    !! checkpoint-restart rebuild or the state-const CalcOutput restore
    !! (CD_HFMF_UnpackMirror); the module stays self-authoritative in normal marching.
    TYPE(CD_HFMF_ModuleType), INTENT(IN) :: self
    REAL(wp), INTENT(OUT) :: buf(:)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    INTEGER :: i, nf, nh, k
    ErrStat = CD_HFMF_OK; ErrMsg = ''
    buf = CD_ZERO
    IF (.NOT. self%initialized) THEN
      ErrStat = CD_HFMF_BADINPUT; ErrMsg = 'CD_HFMF_PackMirror: module not initialised'; RETURN
    END IF
    nf = COUNT(self%line%freemask)
    nh = self%line%ndof - nf
    IF (SIZE(buf) /= CD_HFMF_MirrorSize(self)) THEN
      ErrStat = CD_HFMF_BADINPUT
      ErrMsg = 'CD_HFMF_PackMirror: buffer must be sized CD_HFMF_MirrorSize'
      RETURN
    END IF
    k = 0
    DO i = 1, self%line%ndof
      IF (self%line%freemask(i)) THEN
        k = k + 1
        buf(k) = self%line%v(i)           ! velocity block
        buf(nf + k) = self%line%q(i)      ! position block
        buf(2*nf + k) = self%line%a(i)    ! acceleration block (gen-alpha committed state)
      END IF
    END DO
    k = 3*nf
    ! stick-slip friction anchors, (x, y) per node, after the acceleration block
    IF (self%line%fr_active) THEN
      buf(k + 1:k + 2*self%line%nn) = RESHAPE(self%line%fr_anchor, [2*self%line%nn])
      k = k + 2*self%line%nn
    END IF
    ! committed boundary: [q; v; a] of the held DOFs, end-connection directions, parent frame
    DO i = 1, self%line%ndof
      IF (self%line%freemask(i)) CYCLE
      k = k + 1
      buf(k) = self%line%q(i)
      buf(nh + k) = self%line%v(i)
      buf(2*nh + k) = self%line%a(i)
    END DO
    k = k + 2*nh
    buf(k + 1:k + 6) = RESHAPE(self%line%endconn_d0, [6])
    buf(k + 7:k + 15) = RESHAPE(self%parent_dcm, [9])
    buf(k + 16:k + 18) = self%parent_omega
    buf(k + 19:k + 21) = self%parent_alpha
    k = k + 21
    IF (self%moving_b) THEN
      buf(k + 1:k + 9) = RESHAPE(self%parent_dcm_b, [9])
      buf(k + 10:k + 12) = self%parent_omega_b
      buf(k + 13:k + 15) = self%parent_alpha_b
      k = k + 15
    END IF
    ! force-blend committed force: flag (1 when the cache holds F at the committed state)
    IF (self%line%force_blend) THEN
      IF (self%line%fc_valid .AND. .NOT. (ABS(self%line%fc_t - self%line%t) > CD_ZERO)) THEN
        buf(k + 1) = 1.0_wp
        buf(k + 2:k + 1 + self%line%ndof) = self%line%fc_R
      END IF
      k = k + 1 + self%line%ndof
    END IF
    IF (self%line%has_viv) THEN
      buf(k + 1:k + self%line%nn) = self%line%viv_phi
      buf(k + self%line%nn + 1:k + 3*self%line%nn) = RESHAPE(self%line%viv_ms, [2*self%line%nn])
      buf(k + 3*self%line%nn + 1) = self%line%viv_tw
      k = k + 3*self%line%nn + 1
    END IF
    IF (self%line%torsion%active) THEN
      buf(k + 1) = self%line%torsion%theta
      buf(k + 2) = self%line%torsion%phi
      buf(k + 3:k + 14) = RESHAPE(self%line%torsion%ends, [12])
      IF (self%line%tw_active) &
        CALL CD_HermiteCable_Dyn_Twist_Pack(self%line, buf(k + 15:k + 14 + CD_HermiteCable_Dyn_Twist_Mirror_Size( &
                                                           self%line)))
    END IF
  END SUBROUTINE CD_HFMF_PackMirror

  SUBROUTINE CD_HFMF_UnpackMirror(self, buf, t, ErrStat, ErrMsg)
    !! CHECKPOINT-RESTART reload: overwrite the cable's committed state from a mirror
    !! written by CD_HFMF_PackMirror and set the line clock to the restart time. The held
    !! DOFs, end-connection directions and parent frame reload from the boundary block, so
    !! a caller that first moved the coupled endpoint to the host's restored input mesh
    !! (CD_HFMF_SetCoupledKinematics) continues from the committed boundary bit for bit. The
    !! module must already be initialised from the SAME deck (the rebuild re-runs the
    !! static build first).
    TYPE(CD_HFMF_ModuleType), INTENT(INOUT) :: self
    REAL(wp), INTENT(IN) :: buf(:)
    REAL(wp), INTENT(IN) :: t
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    INTEGER :: i, nf, nh, k, kb, es
    CHARACTER(1024) :: em
    ErrStat = CD_HFMF_OK; ErrMsg = ''
    IF (.NOT. self%initialized) THEN
      ErrStat = CD_HFMF_BADINPUT; ErrMsg = 'CD_HFMF_UnpackMirror: module not initialised'; RETURN
    END IF
    IF (.NOT. CD_Is_Finite(t)) THEN
      ErrStat = CD_HFMF_BADINPUT; ErrMsg = 'CD_HFMF_UnpackMirror: restart time must be finite'; RETURN
    END IF
    nf = COUNT(self%line%freemask)
    IF (SIZE(buf) /= CD_HFMF_MirrorSize(self)) THEN
      ErrStat = CD_HFMF_BADINPUT
      ErrMsg = 'CD_HFMF_UnpackMirror: buffer must be sized CD_HFMF_MirrorSize'
      RETURN
    END IF
    IF (.NOT. CD_All_Finite(buf)) THEN
      ErrStat = CD_HFMF_BADINPUT; ErrMsg = 'CD_HFMF_UnpackMirror: mirror must be finite'; RETURN
    END IF
    IF (self%line%torsion%active) THEN
      ! the torsion block (the last CD_HFMF_TorsionMirrorSize values) is checked before anything
      ! is written: each end's director and reference normal must be orthonormal, as
      ! Set_Torsion_Drive requires, and the nodal twist's directors unit vectors
      k = SIZE(buf) - CD_HFMF_TorsionMirrorSize(self)
      IF (self%line%tw_active) THEN
        CALL CD_HermiteCable_Dyn_Twist_Unpack(self%line, buf(k + 15:SIZE(buf)), es, em, check_only=.TRUE.)
        IF (es /= CD_HCDYN_OK) THEN
          ErrStat = CD_HFMF_BADINPUT
          ErrMsg = 'CD_HFMF_UnpackMirror: '//TRIM(em)
          RETURN
        END IF
      END IF
      DO i = 0, 1
        ASSOCIATE (dv => buf(k + 3 + 6*i:k + 5 + 6*i), nv => buf(k + 6 + 6*i:k + 8 + 6*i))
          IF (ABS(NORM2(dv) - CD_ONE) > 1.0e-8_wp .OR. ABS(NORM2(nv) - CD_ONE) > 1.0e-8_wp .OR. &
              ABS(DOT_PRODUCT(dv, nv)) > 1.0e-8_wp) THEN
            ErrStat = CD_HFMF_BADINPUT
            ErrMsg = 'CD_HFMF_UnpackMirror: the torsion end frames must be orthonormal'
            RETURN
          END IF
        END ASSOCIATE
      END DO
    END IF
    ! the boundary block's parent orientation, checked before anything is written as well
    nh = self%line%ndof - nf
    kb = 3*nf + CD_HFMF_FrictionMirrorSize(self) + 3*nh
    IF (.NOT. valid_parent_dcm(RESHAPE(buf(kb + 7:kb + 15), [3, 3]))) THEN
      ErrStat = CD_HFMF_BADINPUT
      ErrMsg = 'CD_HFMF_UnpackMirror: the parent orientation must be a proper orthogonal DCM'
      RETURN
    END IF
    IF (self%moving_b) THEN
      IF (.NOT. valid_parent_dcm(RESHAPE(buf(kb + 22:kb + 30), [3, 3]))) THEN
        ErrStat = CD_HFMF_BADINPUT
        ErrMsg = 'CD_HFMF_UnpackMirror: the End B parent orientation must be a proper orthogonal DCM'
        RETURN
      END IF
    END IF
    ! and the VIV block's mean squares and averaging time, which cannot be negative
    IF (self%line%has_viv) THEN
      kb = SIZE(buf) - CD_HFMF_TorsionMirrorSize(self) - CD_HFMF_VIVMirrorSize(self) + self%line%nn
      IF (ANY(buf(kb + 1:kb + 2*self%line%nn + 1) < CD_ZERO)) THEN
        ErrStat = CD_HFMF_BADINPUT
        ErrMsg = 'CD_HFMF_UnpackMirror: the VIV mean squares and averaging time must be non-negative'
        RETURN
      END IF
    END IF
    k = 0
    DO i = 1, self%line%ndof
      IF (self%line%freemask(i)) THEN
        k = k + 1
        self%line%v(i) = buf(k)
        self%line%q(i) = buf(nf + k)
        self%line%a(i) = buf(2*nf + k)
      END IF
    END DO
    k = 3*nf
    IF (self%line%fr_active) THEN
      self%line%fr_anchor = RESHAPE(buf(k + 1:k + 2*self%line%nn), [2, self%line%nn])
      self%line%ws_recovery_fr = self%line%fr_anchor
      k = k + 2*self%line%nn
    END IF
    DO i = 1, self%line%ndof
      IF (self%line%freemask(i)) CYCLE
      k = k + 1
      self%line%q(i) = buf(k)
      self%line%v(i) = buf(nh + k)
      self%line%a(i) = buf(2*nh + k)
    END DO
    k = k + 2*nh
    self%line%endconn_d0 = RESHAPE(buf(k + 1:k + 6), [3, 2])
    self%parent_dcm = RESHAPE(buf(k + 7:k + 15), [3, 3])
    self%parent_omega = buf(k + 16:k + 18)
    self%parent_alpha = buf(k + 19:k + 21)
    k = k + 21
    IF (self%moving_b) THEN
      self%parent_dcm_b = RESHAPE(buf(k + 1:k + 9), [3, 3])
      self%parent_omega_b = buf(k + 10:k + 12)
      self%parent_alpha_b = buf(k + 13:k + 15)
      k = k + 15
    END IF
    self%line%t = t
    ! The reloaded acceleration is committed history: a first held fluid field after the
    ! reload (the host re-sampling its field on the restored state) must keep it.
    self%line%a_restored = .TRUE.
    ! Active line control: the reloaded state is committed with the lengths and rates in
    ! place now, so the caller re-applies the command of the checkpointed step BEFORE the
    ! reload (the committed force F_n belongs to those lengths).
    IF (self%line%has_ctrl) THEN
      self%line%l0_c = self%line%l0
      self%line%l0_dot_c = self%line%l0_dot
    END IF
    ! the force-blend committed force reloads with the state it was evaluated at
    self%line%fc_valid = .FALSE.
    self%line%fc_clears = self%line%fc_clears + 1
    IF (self%line%force_blend) THEN
      IF (buf(k + 1) > 0.5_wp) THEN
        self%line%fc_R = buf(k + 2:k + 1 + self%line%ndof)
        self%line%fc_q = self%line%q
        self%line%fc_v = self%line%v
        self%line%fc_t = self%line%t
        self%line%fc_d0 = self%line%endconn_d0
        self%line%fc_valid = .TRUE.
      END IF
      k = k + 1 + self%line%ndof
    END IF
    ! the VIV state, with the step-start copy of a recovering step and the in-step phase
    IF (self%line%has_viv) THEN
      self%line%viv_phi = buf(k + 1:k + self%line%nn)
      self%line%viv_ms = RESHAPE(buf(k + self%line%nn + 1:k + 3*self%line%nn), [2, self%line%nn])
      self%line%viv_tw = buf(k + 3*self%line%nn + 1)
      self%line%viv_phi_eval = self%line%viv_phi
      self%line%viv_ms_next = self%line%viv_ms
      self%line%ws_recovery_viv_phi = self%line%viv_phi
      self%line%ws_recovery_viv_ms = self%line%viv_ms
      k = k + 3*self%line%nn + 1
    END IF
    IF (self%line%torsion%active) THEN
      self%line%torsion%theta = buf(k + 1)
      self%line%torsion%phi = buf(k + 2)
      self%line%torsion%ends = RESHAPE(buf(k + 3:k + 14), [3, 4])
      self%line%torsion%torque = (self%line%torsion%phi - self%line%torsion%theta)/ &
                                 CD_HermiteTorsion_Compliance(self%line%torsion, self%line%l0)
      self%line%tors_drive_set = .FALSE.
      ! the nodal twist, checked above (its force-cache part rides with the cable's); it brings
      ! back the committed torque as it was formed (a summed twist over the compliance)
      IF (self%line%tw_active) CALL CD_HermiteCable_Dyn_Twist_Unpack(self%line, buf(k + 15:SIZE(buf)), es, em)
      ! (a parent-attached torsion frame turns with the parent orientation, which the boundary
      ! block restored as committed, so a later step without u_orientation holds it)
    END IF
  END SUBROUTINE CD_HFMF_UnpackMirror

  SUBROUTINE CD_HFMF_End(self)
    !! Release the module and its line model.
    TYPE(CD_HFMF_ModuleType), INTENT(INOUT) :: self
    CALL CD_HermiteCable_Dyn_End(self%line)
    self%coupled_node = 0
    self%pdof = 0
    self%dt = CD_ZERO
    self%max_iter = 100
    self%tol = 1.0e-4_wp
    self%recovery_max_substeps = 1024
    self%frame_c = CD_ONE
    self%frame_s = CD_ZERO
    self%has_parent_endconn = .FALSE.
    self%parent_endconn_index = 0
    self%parent_endconn_d0 = CD_ZERO
    self%parent_dcm = identity_dcm()
    self%parent_omega = CD_ZERO
    self%parent_alpha = CD_ZERO
    self%snap_parent_dcm = identity_dcm()
    self%snap_parent_omega = CD_ZERO
    self%snap_parent_alpha = CD_ZERO
    self%has_sect_ref = .FALSE.
    self%sect_ref_global = CD_ZERO
    self%sect_ref_parent = CD_ZERO
    self%sc_valid = .FALSE.
    IF (ALLOCATED(self%sc_q)) DEALLOCATE (self%sc_q, self%sc_v, self%sc_a, self%sc_kx, self%sc_ky)
    self%tors_parent = .FALSE.
    self%tors_index = 0
    self%tors_frame_parent = CD_ZERO
    self%moving_b = .FALSE.
    self%pdof_b = 0
    self%has_parent_endconn_b = .FALSE.
    self%parent_endconn_d0_b = CD_ZERO
    self%parent_dcm_b = identity_dcm()
    self%parent_omega_b = CD_ZERO
    self%parent_alpha_b = CD_ZERO
    self%snap_parent_dcm_b = identity_dcm()
    self%snap_parent_omega_b = CD_ZERO
    self%snap_parent_alpha_b = CD_ZERO
    self%tors_parent_b = .FALSE.
    self%tors_frame_parent_b = CD_ZERO
    IF (ALLOCATED(self%deck_node)) DEALLOCATE (self%deck_node)
    self%initialized = .FALSE.
  END SUBROUTINE CD_HFMF_End

END MODULE CableDyn_OpenFAST_HermiteFMF
