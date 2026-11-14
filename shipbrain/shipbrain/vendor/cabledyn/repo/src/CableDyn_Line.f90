! File: src/CableDyn_Line.f90
! SPDX-License-Identifier: Apache-2.0
! Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
MODULE CableDyn_Line
  !! Line-object assembly for the positions-only EI=0 cable path -- the OrcaFlex
  !! line-object model. A single line spans end A -> end B and is built from one
  !! or more SECTIONS, each carrying its own line type (EA, mass/length, diameter)
  !! and its own segment count (in-line mesh refinement). This module turns that
  !! declarative description into the flat per-element arrays the element /
  !! assembly / static-solve / catenary-seed routines already consume
  !! (elem_conn, l0, ea, mass_per_length, diameter), plus the per-node seabed
  !! penalty stiffness, so a multi-line-type, multi-mesh-density line solves
  !! through exactly the same kernel as a single uniform line.
  !!
  !! Fortranic and deliberately compact: a line type is
  !! a small value type, a section is an (index, length, n_segments) triple, and
  !! one build subroutine loops the sections filling allocatable element arrays.
  !! It implements per-section concatenation, endpoint-order reversal, and the
  !! per-node tributary-area seabed penalty stiffness.
  !!
  !! Conventions:
  !!  * sections are listed in end_A -> end_B order; the element arrays come out in
  !!    ANCHOR -> FAIRLEAD order. When the anchor is end B (anchor_is_end_b), the
  !!    per-element arrays are reversed so node 1 is the anchor -- the catenary seed
  !!    and the static solve both assume node 1 at the anchor.
  !!  * elem_conn(:, e) = [e, e+1]; node nd owns positions DOFs 3*nd-2:3*nd.
  !!  * a per-node seabed stiffness gives each node its adjacent element's diameter
  !!    x segment-length tributary area, so a chain node and a wire node touch the
  !!    seabed with their own penalty (heterogeneous composite contact).
  !!
  !! Finite-EI (EI > 0) sections are recognised and REJECTED here (clear ErrStat):
  !! the composite finite-EI / lazy-wave-arch path uses the dedicated finite-EI workflow.
  USE CableDyn_Precision, ONLY: wp, CD_ZERO, CD_ONE, CD_All_Finite, CD_Is_Finite
  IMPLICIT NONE
  PRIVATE

  PUBLIC :: CD_LineType, CD_LineSection
  PUBLIC :: CD_Build_Line_Mesh, CD_Nodal_Seabed_Stiffness

  TYPE :: CD_LineType
    !! Structural / hydrodynamic properties of one line material.
    REAL(wp) :: ea = CD_ZERO              !! axial stiffness EA [N] (> 0)
    REAL(wp) :: mass_per_length = CD_ZERO !! dry mass per unstretched metre [kg/m] (>= 0)
    REAL(wp) :: diameter = CD_ZERO        !! hydrodynamic / contact diameter [m] (> 0)
    REAL(wp) :: ei = CD_ZERO              !! bending stiffness EI [N m^2]; > 0 reserved for the
    !! finite-EI composite path (rejected by the EI=0 builder here)
  END TYPE CD_LineType

  TYPE :: CD_LineSection
    !! One section of a line: which line type, its unstretched length, and how many
    !! elements to mesh it into (in-line mesh refinement).
    INTEGER  :: line_type = 0     !! 1-based index into the line_types(:) array
    REAL(wp) :: length = CD_ZERO  !! unstretched section length [m] (> 0)
    INTEGER  :: n_segments = 0    !! elements in this section (>= 1)
  END TYPE CD_LineSection

  ! ErrStat codes: 0 ok; 1 invalid input; 2 unsupported by this builder.
  INTEGER, PARAMETER, PUBLIC :: CD_LINE_OK = 0
  INTEGER, PARAMETER, PUBLIC :: CD_LINE_BADINPUT = 1
  INTEGER, PARAMETER, PUBLIC :: CD_LINE_UNSUPPORTED = 2

CONTAINS

  SUBROUTINE CD_Build_Line_Mesh(sections, line_types, anchor_is_end_b, elem_conn, l0, ea, &
                                mass_per_length, diameter, ErrStat, ErrMsg)
    !! Assemble the flat per-element arrays for a composite (multi-section) line.
    !! sections are in end_A -> end_B order; outputs come back in anchor -> fairlead
    !! order (reversed when anchor_is_end_b). All output arrays are allocated here to
    !! n_elem = sum(sections%n_segments); elem_conn is (2, n_elem). A section's
    !! per-element length is section%length / section%n_segments (uniform within the
    !! section). Fails closed on an empty/invalid schedule, an out-of-range line_type
    !! index, a non-physical line type, or a finite-EI (EI > 0) section.
    TYPE(CD_LineSection), INTENT(IN)  :: sections(:)
    TYPE(CD_LineType), INTENT(IN)  :: line_types(:)
    LOGICAL, INTENT(IN)  :: anchor_is_end_b
    INTEGER, ALLOCATABLE, INTENT(OUT) :: elem_conn(:, :)
    REAL(wp), ALLOCATABLE, INTENT(OUT) :: l0(:), ea(:), mass_per_length(:), diameter(:)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg

    INTEGER :: n_sec, n_lt, n_elem, s, lt, e, off
    REAL(wp) :: seg_len
    TYPE(CD_LineType) :: t

    ErrStat = CD_LINE_OK
    ErrMsg = ''
    n_sec = SIZE(sections)
    n_lt = SIZE(line_types)

    IF (n_lt < 1) THEN
      CALL fail(ErrStat, ErrMsg, 'need at least one line type'); RETURN
    END IF
    IF (n_sec < 1) THEN
      CALL fail(ErrStat, ErrMsg, 'need at least one section'); RETURN
    END IF

    ! --- validate the sections + the line types they REFERENCE, count elements.
    !     Only referenced types are validated (an unused finite-EI type in a shared
    !     type library must not block an EI=0 line). ---
    n_elem = 0
    DO s = 1, n_sec
      lt = sections(s)%line_type
      IF (lt < 1 .OR. lt > n_lt) THEN
        CALL fail(ErrStat, ErrMsg, 'section line_type index out of range'); RETURN
      END IF
      IF (sections(s)%n_segments < 1) THEN
        CALL fail(ErrStat, ErrMsg, 'section n_segments must be >= 1'); RETURN
      END IF
      IF (.NOT. CD_Is_Finite(sections(s)%length) .OR. sections(s)%length <= CD_ZERO) THEN
        CALL fail(ErrStat, ErrMsg, 'section length must be finite and positive'); RETURN
      END IF
      t = line_types(lt)
      IF (.NOT. CD_Is_Finite(t%ea) .OR. t%ea <= CD_ZERO) THEN
        CALL fail(ErrStat, ErrMsg, 'referenced line type EA must be finite and positive'); RETURN
      END IF
      IF (.NOT. CD_Is_Finite(t%mass_per_length) .OR. t%mass_per_length < CD_ZERO) THEN
        CALL fail(ErrStat, ErrMsg, 'referenced line type mass_per_length must be finite and non-negative')
        RETURN
      END IF
      IF (.NOT. CD_Is_Finite(t%diameter) .OR. t%diameter <= CD_ZERO) THEN
        CALL fail(ErrStat, ErrMsg, 'referenced line type diameter must be finite and positive'); RETURN
      END IF
      IF (.NOT. CD_Is_Finite(t%ei) .OR. t%ei < CD_ZERO) THEN
        CALL fail(ErrStat, ErrMsg, 'referenced line type EI must be finite and non-negative'); RETURN
      END IF
      IF (t%ei > CD_ZERO) THEN
        ErrStat = CD_LINE_UNSUPPORTED
        ErrMsg = 'CableDyn_Line: finite-EI (EI > 0) composite sections are unsupported '// &
                 'by the EI=0 builder; use the finite-EI / lazy-wave workflow'
        RETURN
      END IF
      n_elem = n_elem + sections(s)%n_segments
    END DO

    ALLOCATE (elem_conn(2, n_elem), l0(n_elem), ea(n_elem), mass_per_length(n_elem), diameter(n_elem))

    ! --- fill per-element arrays section by section (end_A -> end_B order) ---
    off = 0
    DO s = 1, n_sec
      lt = sections(s)%line_type
      t = line_types(lt)
      seg_len = sections(s)%length/REAL(sections(s)%n_segments, wp)
      DO e = 1, sections(s)%n_segments
        l0(off + e) = seg_len
        ea(off + e) = t%ea
        mass_per_length(off + e) = t%mass_per_length
        diameter(off + e) = t%diameter
      END DO
      off = off + sections(s)%n_segments
    END DO

    ! --- endpoint-order invariance: if the anchor is end B, the deck lists sections
    !     A -> B but the mesh must run anchor -> fairlead, so reverse the per-element
    !     arrays. ---
    IF (anchor_is_end_b) THEN
      l0 = l0(n_elem:1:-1)
      ea = ea(n_elem:1:-1)
      mass_per_length = mass_per_length(n_elem:1:-1)
      diameter = diameter(n_elem:1:-1)
    END IF

    ! topology is order-symmetric: element e joins nodes e, e+1
    DO e = 1, n_elem
      elem_conn(:, e) = [e, e + 1]
    END DO
  END SUBROUTINE CD_Build_Line_Mesh

  SUBROUTINE CD_Nodal_Seabed_Stiffness(kn_base, diameter, l0, kn_node, ErrStat, ErrMsg)
    !! Per-node seabed penalty stiffness [N/m]: node I gets the per-area penalty
    !! kn_base [N/m^3] times its tributary contact area, half of each adjacent element's
    !! diameter*l0:
    !!   kn(I) = kn_base*(d(I-1)*l0(I-1) + d(I)*l0(I))/2,
    !! with only the one adjacent element at the two end nodes. The nodal stiffnesses
    !! therefore sum to kn_base*sum(d*l0), and a line resting on the bed across a change of
    !! element length or section carries a uniform penetration w/(kn_base*d). The arrays
    !! must be in the same (anchor -> fairlead) order CD_Build_Line_Mesh produced.
    REAL(wp), INTENT(IN)  :: kn_base        !! per-area penalty [N/m^3] (> 0)
    REAL(wp), INTENT(IN)  :: diameter(:)    !! per-element diameter [m] (n_elem, > 0)
    REAL(wp), INTENT(IN)  :: l0(:)          !! per-element unstretched length [m] (n_elem, > 0)
    REAL(wp), ALLOCATABLE, INTENT(OUT) :: kn_node(:)   !! per-node stiffness [N/m] (n_elem+1)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg

    INTEGER :: n_elem, ei

    ErrStat = CD_LINE_OK
    ErrMsg = ''
    n_elem = SIZE(diameter)

    IF (n_elem < 1) THEN
      CALL fail(ErrStat, ErrMsg, 'need at least one element'); RETURN
    END IF
    IF (SIZE(l0) /= n_elem) THEN
      CALL fail(ErrStat, ErrMsg, 'diameter and l0 must share shape (n_elem)'); RETURN
    END IF
    IF (.NOT. CD_Is_Finite(kn_base) .OR. kn_base <= CD_ZERO) THEN
      CALL fail(ErrStat, ErrMsg, 'kn_base must be finite and positive'); RETURN
    END IF
    IF (.NOT. CD_All_Finite(diameter) .OR. ANY(diameter <= CD_ZERO)) THEN
      CALL fail(ErrStat, ErrMsg, 'diameter must be finite and positive'); RETURN
    END IF
    IF (.NOT. CD_All_Finite(l0) .OR. ANY(l0 <= CD_ZERO)) THEN
      CALL fail(ErrStat, ErrMsg, 'l0 must be finite and positive'); RETURN
    END IF

    ALLOCATE (kn_node(n_elem + 1))
    kn_node = CD_ZERO
    DO ei = 1, n_elem
      kn_node(ei) = kn_node(ei) + 0.5_wp*kn_base*diameter(ei)*l0(ei)
      kn_node(ei + 1) = kn_node(ei + 1) + 0.5_wp*kn_base*diameter(ei)*l0(ei)
    END DO
  END SUBROUTINE CD_Nodal_Seabed_Stiffness

  ! --------------------------------------------------------------------------- !
  ! private helper                                                              !
  ! --------------------------------------------------------------------------- !

  SUBROUTINE fail(ErrStat, ErrMsg, msg)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    CHARACTER(*), INTENT(IN)  :: msg
    ErrStat = CD_LINE_BADINPUT
    ErrMsg = 'CableDyn_Line: '//msg
  END SUBROUTINE fail

END MODULE CableDyn_Line
