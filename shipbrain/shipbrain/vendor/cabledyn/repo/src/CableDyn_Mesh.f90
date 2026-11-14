! File: src/CableDyn_Mesh.f90
! SPDX-License-Identifier: Apache-2.0
! Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
MODULE CableDyn_Mesh
  !! Shared mesh validation for the positions-only cable path -- the single home for
  !! the topology + per-element property contracts that CableDyn_Assemble,
  !! CableDyn_Loads and the dynamic integrator all enforce, defined once so it cannot
  !! drift between modules.
  !!
  !! Mesh validation contract:
  !! a mesh needs at least two nodes and one
  !! element, 1-based in-range node indices, no self-edge (node_a == node_b), no
  !! duplicate undirected edge ({a,b} == {a',b'}, which would double-add stiffness /
  !! mass), and every node referenced by some element (an unused node leaves a zero
  !! row/column). Per-element properties (l0, ea, rho_a, ...) must be finite with shape
  !! (n_elem) and strictly positive (CD_Validate_Positive), or non-negative where zero is
  !! meaningful (CD_Validate_NonNegative, e.g. ea = 0 on a viscoelastic element).
  !!
  !! Conventions match the rest of the core (1-based elem_conn(2, n_elem)). These are
  !! pure validators: they touch no global state and only set ErrStat / ErrMsg.
  USE CableDyn_Precision, ONLY: wp, CD_ZERO, CD_All_Finite
  IMPLICIT NONE
  PRIVATE

  PUBLIC :: CD_Validate_Connectivity
  PUBLIC :: CD_Validate_Positive
  PUBLIC :: CD_Validate_NonNegative
  PUBLIC :: CD_Partition_Free_Dofs

CONTAINS

  SUBROUTINE CD_Partition_Free_Dofs(fixed_dofs, n_dof, free, ErrStat, ErrMsg, fixed)
    !! Validate 1-based prescribed (Dirichlet) DOF indices and return the free-DOF
    !! list -- the sorted complement of fixed_dofs in 1..n_dof. fixed_dofs must be
    !! in range [1, n_dof] with no duplicates (an out-of-range or duplicated index
    !! fails closed); the order of fixed_dofs is irrelevant. The OPTIONAL ``fixed``
    !! returns the sorted prescribed list for callers that need both partitions
    !! (e.g. the dynamic step's predictor / state recovery). Shared by
    !! CableDyn_Static and CableDyn_Dynamic so the boundary-condition contract is
    !! defined once.
    INTEGER, INTENT(IN)  :: fixed_dofs(:), n_dof
    INTEGER, ALLOCATABLE, INTENT(OUT) :: free(:)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    INTEGER, ALLOCATABLE, INTENT(OUT), OPTIONAL :: fixed(:)
    LOGICAL, ALLOCATABLE :: is_fixed(:)
    INTEGER :: i, d, jf, jx
    ErrStat = 0
    ErrMsg = ''
    IF (n_dof < 1) THEN
      CALL fail(ErrStat, ErrMsg, 'n_dof must be >= 1')
      RETURN
    END IF
    ALLOCATE (is_fixed(n_dof), source=.FALSE.)
    DO i = 1, SIZE(fixed_dofs)
      d = fixed_dofs(i)
      IF (d < 1 .OR. d > n_dof) THEN
        CALL fail(ErrStat, ErrMsg, 'fixed_dofs has an out-of-range index (1-based)')
        RETURN
      END IF
      IF (is_fixed(d)) THEN
        CALL fail(ErrStat, ErrMsg, 'fixed_dofs contains a duplicate index')
        RETURN
      END IF
      is_fixed(d) = .TRUE.
    END DO
    ALLOCATE (free(n_dof - COUNT(is_fixed)))
    IF (PRESENT(fixed)) ALLOCATE (fixed(COUNT(is_fixed)))
    jf = 0
    jx = 0
    DO d = 1, n_dof
      IF (.NOT. is_fixed(d)) THEN
        jf = jf + 1
        free(jf) = d
      ELSE IF (PRESENT(fixed)) THEN
        jx = jx + 1
        fixed(jx) = d
      END IF
    END DO
  END SUBROUTINE CD_Partition_Free_Dofs

  SUBROUTINE CD_Validate_Connectivity(elem_conn, n_nodes, n_elem, ErrStat, ErrMsg)
    !! Validate the element connectivity against the mesh contract:
    !! >= 2 nodes and 1 element, in-range 1-based indices, no self-edge, no duplicate
    !! undirected edge, every node referenced. ``n_nodes`` / ``n_elem`` are supplied
    !! by the caller (derived from whichever array carries the node/element count).
    !! The elem_conn extents are checked first so a public caller cannot drive an
    !! out-of-bounds read (the (2, n_elem) shape is part of the contract, not an
    !! assumption).
    INTEGER, INTENT(IN)  :: elem_conn(:, :), n_nodes, n_elem
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    INTEGER :: e, f, a, b, lo, istat
    LOGICAL, ALLOCATABLE :: referenced(:)   ! heap: avoid a stack automatic sized by n_nodes
    INTEGER, ALLOCATABLE :: bucket_start(:), bucket_fill(:), upper(:)
    ErrStat = 0
    ErrMsg = ''
    IF (SIZE(elem_conn, 1) /= 2) THEN
      CALL fail(ErrStat, ErrMsg, 'elem_conn must have shape (2, n_elem)')
      RETURN
    END IF
    IF (SIZE(elem_conn, 2) /= n_elem) THEN
      CALL fail(ErrStat, ErrMsg, 'elem_conn second extent must equal n_elem')
      RETURN
    END IF
    IF (n_elem < 1) THEN
      CALL fail(ErrStat, ErrMsg, 'mesh requires at least one element')
      RETURN
    END IF
    IF (n_nodes < 2) THEN
      CALL fail(ErrStat, ErrMsg, 'mesh requires at least two nodes')
      RETURN
    END IF
    DO e = 1, n_elem
      a = elem_conn(1, e)
      b = elem_conn(2, e)
      IF (a < 1 .OR. a > n_nodes .OR. b < 1 .OR. b > n_nodes) THEN
        CALL fail(ErrStat, ErrMsg, 'elem_conn has an out-of-range node index (1-based)')
        RETURN
      END IF
      IF (a == b) THEN
        CALL fail(ErrStat, ErrMsg, 'elem_conn has a degenerate element (node_a == node_b)')
        RETURN
      END IF
    END DO
    ! Duplicate undirected edges ({a,b} == {a',b'}) double-add stiffness/mass. Every
    ! assembly call validates the mesh, so the check is linear: a counting sort buckets
    ! each edge under its lower node, then a per-bucket stamp on the upper node finds a
    ! repeated edge in O(n_elem + n_nodes).
    ALLOCATE (bucket_start(n_nodes + 1), bucket_fill(n_nodes), upper(n_elem), STAT=istat)
    IF (istat /= 0) THEN
      CALL fail(ErrStat, ErrMsg, 'connectivity validation workspace allocation failed')
      RETURN
    END IF
    bucket_fill = 0
    DO e = 1, n_elem
      lo = MIN(elem_conn(1, e), elem_conn(2, e))
      bucket_fill(lo) = bucket_fill(lo) + 1
    END DO
    bucket_start(1) = 1
    DO f = 1, n_nodes
      bucket_start(f + 1) = bucket_start(f) + bucket_fill(f)
    END DO
    bucket_fill = bucket_start(1:n_nodes)
    DO e = 1, n_elem
      lo = MIN(elem_conn(1, e), elem_conn(2, e))
      upper(bucket_fill(lo)) = MAX(elem_conn(1, e), elem_conn(2, e))
      bucket_fill(lo) = bucket_fill(lo) + 1
    END DO
    ! bucket_fill is reused as the stamp: stamp(hi) == lo marks edge {lo, hi} as seen.
    bucket_fill = 0
    DO lo = 1, n_nodes
      DO f = bucket_start(lo), bucket_start(lo + 1) - 1
        IF (bucket_fill(upper(f)) == lo) THEN
          CALL fail(ErrStat, ErrMsg, 'elem_conn has a duplicate undirected edge')
          RETURN
        END IF
        bucket_fill(upper(f)) = lo
      END DO
    END DO
    ! Every node must be connected (an unused node would leave a zero row/col).
    ALLOCATE (referenced(n_nodes), source=.FALSE.)
    DO e = 1, n_elem
      referenced(elem_conn(1, e)) = .TRUE.
      referenced(elem_conn(2, e)) = .TRUE.
    END DO
    IF (.NOT. ALL(referenced)) THEN
      CALL fail(ErrStat, ErrMsg, 'a node is not connected to any element')
      RETURN
    END IF
  END SUBROUTINE CD_Validate_Connectivity

  SUBROUTINE CD_Validate_Positive(name, x, n_elem, ErrStat, ErrMsg)
    !! A per-element property array (l0, ea, rho_a, ...) must have shape (n_elem) and
    !! be finite and strictly positive. ``name`` is interpolated into the error
    !! message so the caller's failure is self-describing.
    CHARACTER(*), INTENT(IN)  :: name
    REAL(wp), INTENT(IN)  :: x(:)
    INTEGER, INTENT(IN)  :: n_elem
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    ErrStat = 0
    ErrMsg = ''
    IF (SIZE(x) /= n_elem) THEN
      CALL fail(ErrStat, ErrMsg, 'property array '//name//' must have shape (n_elem)')
      RETURN
    END IF
    IF (.NOT. CD_All_Finite(x) .OR. ANY(x <= CD_ZERO)) THEN
      CALL fail(ErrStat, ErrMsg, 'property array '//name//' must be finite and positive')
    END IF
  END SUBROUTINE CD_Validate_Positive

  SUBROUTINE CD_Validate_NonNegative(name, x, n_elem, ErrStat, ErrMsg)
    !! Like CD_Validate_Positive but admitting exact zeros: used for properties
    !! where zero is a deliberate off-switch (the dynamic elastic stiffness of a
    !! viscoelastic element is masked to zero; its tension comes from the series-Kelvin
    !! load contributor).
    CHARACTER(*), INTENT(IN)  :: name
    REAL(wp), INTENT(IN)  :: x(:)
    INTEGER, INTENT(IN)  :: n_elem
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    ErrStat = 0
    ErrMsg = ''
    IF (SIZE(x) /= n_elem) THEN
      CALL fail(ErrStat, ErrMsg, 'property array '//name//' must have shape (n_elem)')
      RETURN
    END IF
    IF (.NOT. CD_All_Finite(x) .OR. ANY(x < CD_ZERO)) THEN
      CALL fail(ErrStat, ErrMsg, 'property array '//name//' must be finite and non-negative')
    END IF
  END SUBROUTINE CD_Validate_NonNegative

  SUBROUTINE fail(ErrStat, ErrMsg, msg)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    CHARACTER(*), INTENT(IN)  :: msg
    ErrStat = 1
    ErrMsg = 'CableDyn_Mesh: '//msg
  END SUBROUTINE fail

END MODULE CableDyn_Mesh
