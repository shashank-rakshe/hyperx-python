! File: tests/test_cable_mesh.f90
! SPDX-License-Identifier: Apache-2.0
! Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
PROGRAM test_cable_mesh
  !! Unit tests for CableDyn_Mesh -- the shared topology + per-element property
  !! validators (CD_Validate_Connectivity / CD_Validate_Positive) extracted from
  !! CableDyn_Assemble / CableDyn_Loads. The mesh
  !! contract: >= 2 nodes & 1 element, in-range 1-based
  !! indices, no self-edge, no duplicate undirected edge, every node referenced;
  !! finite-positive per-element properties.
  USE CableDyn_Precision, ONLY: wp
  USE CableDyn_Mesh, ONLY: CD_Validate_Connectivity, CD_Validate_Positive, CD_Partition_Free_Dofs
  USE, INTRINSIC :: IEEE_ARITHMETIC, ONLY: IEEE_VALUE, IEEE_QUIET_NAN, IEEE_POSITIVE_INF
  USE, INTRINSIC :: IEEE_EXCEPTIONS, ONLY: IEEE_USUAL, IEEE_GET_HALTING_MODE, IEEE_SET_HALTING_MODE, IEEE_SET_FLAG
  IMPLICIT NONE
  LOGICAL :: fp_halt(3)   ! saved IEEE halting modes around deliberately non-finite inputs

  INTEGER :: nfail
  nfail = 0

  CALL case_connectivity_valid()
  CALL case_connectivity_invalid()
  CALL case_positive_valid()
  CALL case_positive_invalid()
  CALL case_partition_free_dofs()

  IF (nfail > 0) THEN
    WRITE (*, '(A,I0,A)') 'FAIL: ', nfail, ' assertion(s) failed'
    ERROR STOP 1
  END IF
  WRITE (*, '(A)') 'PASS: CableDyn_Mesh validators match the mesh contract'

CONTAINS

  SUBROUTINE expect_es(es, want, label)
    INTEGER, INTENT(IN) :: es, want
    CHARACTER(*), INTENT(IN) :: label
    IF (es /= want) THEN
      WRITE (*, '(A,A,A,I0,A,I0)') 'MISMATCH [', label, ']: ErrStat ', es, ' want ', want
      nfail = nfail + 1
    END IF
  END SUBROUTINE expect_es

  SUBROUTINE require(cond, label)
    LOGICAL, INTENT(IN) :: cond
    CHARACTER(*), INTENT(IN) :: label
    IF (.NOT. cond) THEN
      WRITE (*, '(A,A,A)') 'MISMATCH [', label, ']: condition false'
      nfail = nfail + 1
    END IF
  END SUBROUTINE require

  SUBROUTINE case_connectivity_valid()
    !! A well-formed chain of 3 nodes / 2 elements passes.
    INTEGER :: conn(2, 2), es
    CHARACTER(120) :: em
    conn = RESHAPE([1, 2, 2, 3], [2, 2])
    CALL CD_Validate_Connectivity(conn, 3, 2, es, em)
    CALL expect_es(es, 0, 'conn:valid-chain')
  END SUBROUTINE case_connectivity_valid

  SUBROUTINE case_connectivity_invalid()
    !! Each violation of the contract fails closed (ErrStat = 1).
    INTEGER :: es
    CHARACTER(120) :: em
    ! too few elements
    CALL CD_Validate_Connectivity(RESHAPE([0], [2, 0]), 2, 0, es, em)
    CALL expect_es(es, 1, 'conn:zero-elements')
    ! too few nodes
    CALL CD_Validate_Connectivity(RESHAPE([1, 2], [2, 1]), 1, 1, es, em)
    CALL expect_es(es, 1, 'conn:one-node')
    ! out-of-range node index
    CALL CD_Validate_Connectivity(RESHAPE([1, 3], [2, 1]), 2, 1, es, em)
    CALL expect_es(es, 1, 'conn:out-of-range')
    ! self-edge
    CALL CD_Validate_Connectivity(RESHAPE([2, 2], [2, 1]), 2, 1, es, em)
    CALL expect_es(es, 1, 'conn:self-edge')
    ! duplicate undirected edge (1-2 and 2-1)
    CALL CD_Validate_Connectivity(RESHAPE([1, 2, 2, 1], [2, 2]), 2, 2, es, em)
    CALL expect_es(es, 1, 'conn:duplicate-edge')
    ! unused node (node 3 referenced by nothing)
    CALL CD_Validate_Connectivity(RESHAPE([1, 2], [2, 1]), 3, 1, es, em)
    CALL expect_es(es, 1, 'conn:unused-node')
    ! wrong first extent: must be (2, n_elem), not (3, n_elem) -- would otherwise
    ! be an out-of-bounds read on a public caller in a non-bounds-check build
    CALL CD_Validate_Connectivity(RESHAPE([1, 2, 3, 4, 5, 6], [3, 2]), 3, 2, es, em)
    CALL expect_es(es, 1, 'conn:wrong-first-extent')
    ! second extent disagrees with the caller-supplied n_elem
    CALL CD_Validate_Connectivity(RESHAPE([1, 2, 2, 3], [2, 2]), 3, 3, es, em)
    CALL expect_es(es, 1, 'conn:nelem-mismatch')
  END SUBROUTINE case_connectivity_invalid

  SUBROUTINE case_positive_valid()
    !! A finite, strictly-positive property array of the right size passes.
    INTEGER :: es
    CHARACTER(120) :: em
    CALL CD_Validate_Positive('l0', [1.0_wp, 2.5_wp, 0.3_wp], 3, es, em)
    CALL expect_es(es, 0, 'pos:valid')
  END SUBROUTINE case_positive_valid

  SUBROUTINE case_positive_invalid()
    !! Wrong size, a non-positive entry, a NaN, and a +Inf each fail closed.
    INTEGER :: es
    CHARACTER(120) :: em
    REAL(wp) :: nan, inf
    nan = IEEE_VALUE(1.0_wp, IEEE_QUIET_NAN)
    inf = IEEE_VALUE(1.0_wp, IEEE_POSITIVE_INF)
    CALL CD_Validate_Positive('ea', [1.0_wp, 2.0_wp], 3, es, em)
    CALL expect_es(es, 1, 'pos:wrong-size')
    CALL CD_Validate_Positive('ea', [1.0_wp, 0.0_wp, 2.0_wp], 3, es, em)
    CALL expect_es(es, 1, 'pos:zero-entry')
    CALL CD_Validate_Positive('ea', [1.0_wp, -1.0_wp, 2.0_wp], 3, es, em)
    CALL expect_es(es, 1, 'pos:negative-entry')
    ! deliberately non-finite or overflowing input: must not halt a trapping build
    CALL IEEE_GET_HALTING_MODE(IEEE_USUAL, fp_halt)
    CALL IEEE_SET_HALTING_MODE(IEEE_USUAL, .FALSE.)
    CALL CD_Validate_Positive('ea', [1.0_wp, nan, 2.0_wp], 3, es, em)
    CALL IEEE_SET_FLAG(IEEE_USUAL, .FALSE.)
    CALL IEEE_SET_HALTING_MODE(IEEE_USUAL, fp_halt)
    CALL expect_es(es, 1, 'pos:nan-entry')
    CALL CD_Validate_Positive('ea', [1.0_wp, inf, 2.0_wp], 3, es, em)
    CALL expect_es(es, 1, 'pos:inf-entry')
  END SUBROUTINE case_positive_invalid

  SUBROUTINE case_partition_free_dofs()
    !! The free list is the sorted complement of fixed_dofs; the OPTIONAL fixed list
    !! is the sorted prescribed set; out-of-range / duplicate indices fail closed.
    INTEGER, ALLOCATABLE :: free(:), fixed(:)
    INTEGER :: es, i
    CHARACTER(120) :: em
    ! 9-DOF mesh, prescribe dofs 1,2,3,7,8,9 (given out of order) -> free = 4,5,6
    CALL CD_Partition_Free_Dofs([3, 1, 9, 2, 8, 7], 9, free, es, em, fixed=fixed)
    CALL expect_es(es, 0, 'part:valid-ErrStat')
    CALL require(SIZE(free) == 3, 'part:free-size')
    CALL require(SIZE(fixed) == 6, 'part:fixed-size')
    CALL require(free(1) == 4 .AND. free(2) == 5 .AND. free(3) == 6, 'part:free-values-sorted')
    CALL require(fixed(1) == 1 .AND. fixed(6) == 9, 'part:fixed-values-sorted')
    ! free and fixed partition 1..9 disjointly and completely
    DO i = 1, 9
      CALL require((COUNT(free == i) + COUNT(fixed == i)) == 1, 'part:disjoint-complete')
    END DO
    ! no fixed DOFs -> every DOF free
    CALL CD_Partition_Free_Dofs([INTEGER ::], 4, free, es, em)
    CALL expect_es(es, 0, 'part:none-fixed-ErrStat')
    CALL require(SIZE(free) == 4, 'part:none-fixed-all-free')
    ! out-of-range index fails closed
    CALL CD_Partition_Free_Dofs([1, 2, 10], 9, free, es, em)
    CALL expect_es(es, 1, 'part:out-of-range')
    ! zero / negative index fails closed
    CALL CD_Partition_Free_Dofs([0, 1], 9, free, es, em)
    CALL expect_es(es, 1, 'part:zero-index')
    ! duplicate index fails closed
    CALL CD_Partition_Free_Dofs([1, 2, 2], 9, free, es, em)
    CALL expect_es(es, 1, 'part:duplicate')
  END SUBROUTINE case_partition_free_dofs

END PROGRAM test_cable_mesh
