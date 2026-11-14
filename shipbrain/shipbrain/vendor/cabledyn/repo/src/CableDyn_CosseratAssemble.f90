! File: src/CableDyn_CosseratAssemble.f90
! SPDX-License-Identifier: Apache-2.0
! Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
MODULE CableDyn_CosseratAssemble
  !! Dense global assembly for the finite-EI (geometrically-exact) Cosserat path
  !! -- the bridge between the reference-validated element (CableDyn_Cosserat) and
  !! the finite-EI static / dynamic solve: global tangent, internal force, and
  !! reference mass matrix for the 6-DOF/node element.
  !!
  !! Conventions (column-major, 1-based connectivity):
  !!   nodes_ref(3, n_nodes)    reference node positions (build Lam0, L0 per elem)
  !!   elem_conn(2, n_elem)     [node_a; node_b] per element, 1-based
  !!   q(6 n_nodes)             current DOFs: per node [r(3), theta(3)]
  !!   ea/gas/ei/gj(n_elem)     per-element constitutive properties
  !! Node `nd` owns global DOFs `6*nd-5 : 6*nd`; element DOFs [1:6] -> node_a,
  !! [7:12] -> node_b. The residual-only path calls CD_Cosserat_Internal_Force
  !! (closed-form force, no tangent); the tangent path calls CD_Cosserat_Force_Tangent
  !! and scatter-adds Kt(12,12)/fint(12). The static solver can also assemble the
  !! free-DOF tangent block directly into LAPACK DGBSV band storage.
  USE CableDyn_Precision, ONLY: wp, CD_All_Finite, CD_Is_Finite
  USE CableDyn_FatalReport, ONLY: CD_Fatal_Thread_Init
  USE CableDyn_Cosserat, ONLY: CD_Reference_Frame, CD_Cosserat_Internal_Force, CD_Cosserat_Force_Tangent
  USE CableDyn_Mesh, ONLY: CD_Validate_Connectivity
  USE, INTRINSIC :: ISO_FORTRAN_ENV, ONLY: INT64
  IMPLICIT NONE
  PRIVATE
  PUBLIC :: CD_Assemble_Cosserat_Tangent_Force, CD_Assemble_Cosserat_Tangent_Force_Banded_Free
  PUBLIC :: CD_Assemble_Cosserat_Internal_Force
  PUBLIC :: CD_Assemble_Cosserat_Tangent_Force_Banded_Free_Workspace
  PUBLIC :: CD_Assemble_Cosserat_Internal_Force_Workspace
  PUBLIC :: CD_Cosserat_Free_Bandwidth, CD_Cosserat_Free_Bandwidth_Workspace
  PUBLIC :: CD_CosseratAssemblyWorkspace, CD_Clear_CosseratAssembly_Workspace
  PUBLIC :: CD_Reset_Cosserat_Asm_Counts

  TYPE :: CD_CosseratAssemblyWorkspace
    !! Reusable scratch for finite-EI global assembly kernels.
    INTEGER, ALLOCATABLE :: global_to_free(:)
    REAL(wp), ALLOCATABLE :: fe(:, :)
    REAL(wp), ALLOCATABLE :: Ke(:, :, :)
    INTEGER, ALLOCATABLE :: elem_es(:)
    CHARACTER(120), ALLOCATABLE :: elem_em(:)
    ! Diagnostics of the assemblies run on this workspace since CD_Reset_Cosserat_Asm_Counts:
    ! the global tangent and internal-force assemblies and their wall time, so a benchmark can
    ! attribute time to Newton tangents and residual-only evaluations. They belong to the
    ! workspace (one per model), so concurrent models never mix their counts, and no result
    ! depends on them.
    INTEGER :: n_tangent = 0, n_force = 0
    REAL(wp) :: t_tangent = 0.0_wp, t_force = 0.0_wp
  END TYPE CD_CosseratAssemblyWorkspace

CONTAINS

  SUBROUTINE CD_Clear_CosseratAssembly_Workspace(work)
    TYPE(CD_CosseratAssemblyWorkspace), INTENT(INOUT) :: work

    IF (ALLOCATED(work%global_to_free)) DEALLOCATE (work%global_to_free)
    IF (ALLOCATED(work%fe)) DEALLOCATE (work%fe)
    IF (ALLOCATED(work%Ke)) DEALLOCATE (work%Ke)
    IF (ALLOCATED(work%elem_es)) DEALLOCATE (work%elem_es)
    IF (ALLOCATED(work%elem_em)) DEALLOCATE (work%elem_em)
  END SUBROUTINE CD_Clear_CosseratAssembly_Workspace

  SUBROUTINE CD_Reset_Cosserat_Asm_Counts(work)
    !! Zero the diagnostic assembly counters of a workspace (call before a timed solve).
    TYPE(CD_CosseratAssemblyWorkspace), INTENT(INOUT) :: work
    work%n_tangent = 0
    work%n_force = 0
    work%t_tangent = 0.0_wp
    work%t_force = 0.0_wp
  END SUBROUTINE CD_Reset_Cosserat_Asm_Counts

  SUBROUTINE CD_Assemble_Cosserat_Tangent_Force(nodes_ref, elem_conn, ea, gas, ei, gj, q, &
                                                reduced_shear, Kt, fint, ErrStat, ErrMsg)
    !! Assemble the dense global tangent stiffness and internal force for the
    !! finite-EI Cosserat mesh at state q.
    REAL(wp), INTENT(IN) :: nodes_ref(:, :), ea(:), gas(:), ei(:), gj(:), q(:)
    INTEGER, INTENT(IN) :: elem_conn(:, :)
    LOGICAL, INTENT(IN) :: reduced_shear
    REAL(wp), INTENT(OUT) :: Kt(:, :), fint(:)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    INTEGER :: n_nodes, n_elem, e, a, b, ndof, gmap(12), i, j, es
    REAL(wp) :: Lam0(3, 3), L0, qe(12), Kte(12, 12), finte(12)
    REAL(wp), ALLOCATABLE :: fe(:, :), Ke(:, :, :)
    INTEGER, ALLOCATABLE :: elem_es(:)
    CHARACTER(120), ALLOCATABLE :: elem_em(:)
    CHARACTER(120) :: em

    Kt = 0.0_wp
    fint = 0.0_wp
    CALL check_inputs(nodes_ref, elem_conn, ea, gas, ei, gj, q, n_nodes, n_elem, ndof, ErrStat, ErrMsg)
    IF (ErrStat /= 0) RETURN
    IF (SIZE(fint) /= ndof .OR. SIZE(Kt, 1) /= ndof .OR. SIZE(Kt, 2) /= ndof) THEN
      ErrStat = 1; ErrMsg = 'CD_Assemble_Cosserat_Tangent_Force: output shapes inconsistent with mesh'
      RETURN
    END IF

    ALLOCATE (fe(12, n_elem), Ke(12, 12, n_elem), elem_es(n_elem), elem_em(n_elem))
    fe = 0.0_wp
    Ke = 0.0_wp
    elem_es = 0
    ! elem_em(e) is written with elem_es(e) and read only where elem_es(e) /= 0: no blank fill
    !$OMP PARALLEL DEFAULT(NONE) &
    !$OMP SHARED(n_elem, elem_conn, nodes_ref, q, ea, gas, ei, gj, reduced_shear, fe, Ke, elem_es, elem_em) &
    !$OMP PRIVATE(e, a, b, Lam0, L0, qe, finte, Kte, es, em)
    CALL CD_Fatal_Thread_Init() ! this thread can report its own stack overflow
    !$OMP DO SCHEDULE(static)
    DO e = 1, n_elem
      a = elem_conn(1, e)
      b = elem_conn(2, e)
      CALL CD_Reference_Frame(nodes_ref(:, a), nodes_ref(:, b), Lam0, L0)
      qe(1:6) = q(6*a - 5:6*a)
      qe(7:12) = q(6*b - 5:6*b)
      CALL CD_Cosserat_Force_Tangent(qe, ea(e), gas(e), ei(e), gj(e), Lam0, L0, reduced_shear, &
                                     finte, Kte, es, em)
      IF (es /= 0) THEN
        elem_es(e) = es
        elem_em(e) = em
      ELSE
        fe(:, e) = finte
        Ke(:, :, e) = Kte
      END IF
    END DO
    !$OMP END DO
    !$OMP END PARALLEL
    DO e = 1, n_elem
      IF (elem_es(e) /= 0) THEN
        Kt = 0.0_wp; fint = 0.0_wp
        ErrStat = 1; ErrMsg = 'CD_Assemble_Cosserat_Tangent_Force: element '//TRIM(elem_em(e))
        RETURN
      END IF
    END DO
    DO e = 1, n_elem
      a = elem_conn(1, e)
      b = elem_conn(2, e)
      ! global DOF map for the 12 element DOFs
      DO i = 1, 6
        gmap(i) = 6*a - 6 + i
        gmap(6 + i) = 6*b - 6 + i
      END DO
      DO i = 1, 12
        fint(gmap(i)) = fint(gmap(i)) + fe(i, e)
        DO j = 1, 12
          Kt(gmap(i), gmap(j)) = Kt(gmap(i), gmap(j)) + Ke(i, j, e)
        END DO
      END DO
    END DO
  END SUBROUTINE CD_Assemble_Cosserat_Tangent_Force

  SUBROUTINE CD_Cosserat_Free_Bandwidth(elem_conn, n_nodes, free, kl, ku, ErrStat, ErrMsg)
    !! Compute the occupied lower/upper bandwidth of the finite-EI tangent after
    !! reduction to the sorted free-DOF list. This is connectivity-only: every
    !! two-node Cosserat element may couple all 12 local DOFs.
    INTEGER, INTENT(IN) :: elem_conn(:, :), n_nodes, free(:)
    INTEGER, INTENT(OUT) :: kl, ku, ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    INTEGER :: ndof
    INTEGER, ALLOCATABLE :: global_to_free(:)

    ndof = 6*n_nodes
    kl = 0; ku = 0; ErrStat = 0; ErrMsg = ''
    ALLOCATE (global_to_free(ndof))
    CALL CD_Cosserat_Free_Bandwidth_Workspace(elem_conn, n_nodes, free, global_to_free, kl, ku, ErrStat, ErrMsg)
  END SUBROUTINE CD_Cosserat_Free_Bandwidth

  SUBROUTINE CD_Cosserat_Free_Bandwidth_Workspace(elem_conn, n_nodes, free, global_to_free, kl, ku, ErrStat, ErrMsg)
    !! Workspace-backed bandwidth analysis. `global_to_free` is overwritten.
    INTEGER, INTENT(IN) :: elem_conn(:, :), n_nodes, free(:)
    INTEGER, INTENT(INOUT) :: global_to_free(:)
    INTEGER, INTENT(OUT) :: kl, ku, ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    INTEGER :: n_elem, ndof, e, a, b, i, j, fi, fj, gmap(12)

    kl = 0; ku = 0; ErrStat = 0; ErrMsg = ''
    n_elem = SIZE(elem_conn, 2)
    ndof = 6*n_nodes
    CALL CD_Validate_Connectivity(elem_conn, n_nodes, n_elem, ErrStat, ErrMsg)
    IF (ErrStat /= 0) RETURN
    IF (SIZE(global_to_free) < ndof) THEN
      ErrStat = 1; ErrMsg = 'CD_Cosserat_Free_Bandwidth: map workspace is undersized'
      RETURN
    END IF
    IF (ANY(free < 1) .OR. ANY(free > ndof)) THEN
      ErrStat = 1; ErrMsg = 'CD_Cosserat_Free_Bandwidth: free DOF index out of range'
      RETURN
    END IF
    global_to_free(1:ndof) = 0
    DO i = 1, SIZE(free)
      IF (global_to_free(free(i)) /= 0) THEN
        ErrStat = 1; ErrMsg = 'CD_Cosserat_Free_Bandwidth: duplicate free DOF'
        RETURN
      END IF
      global_to_free(free(i)) = i
    END DO

    DO e = 1, n_elem
      a = elem_conn(1, e)
      b = elem_conn(2, e)
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
          IF (fi > fj) kl = MAX(kl, fi - fj)
          IF (fj > fi) ku = MAX(ku, fj - fi)
        END DO
      END DO
    END DO
  END SUBROUTINE CD_Cosserat_Free_Bandwidth_Workspace

  SUBROUTINE CD_Assemble_Cosserat_Tangent_Force_Banded_Free(nodes_ref, elem_conn, ea, gas, ei, gj, q, &
                                                            reduced_shear, free, kl, ku, Kb, fint, &
                                                            ErrStat, ErrMsg)
    !! Assemble the free-DOF tangent directly into LAPACK general-band storage:
    !! Kb(kl+ku+1+i-j, j) = K_free(i,j). The global internal-force vector is
    !! assembled alongside it so callers can compare/debug against the dense path.
    REAL(wp), INTENT(IN) :: nodes_ref(:, :), ea(:), gas(:), ei(:), gj(:), q(:)
    INTEGER, INTENT(IN) :: elem_conn(:, :), free(:), kl, ku
    LOGICAL, INTENT(IN) :: reduced_shear
    REAL(wp), INTENT(OUT) :: Kb(:, :), fint(:)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    TYPE(CD_CosseratAssemblyWorkspace) :: work

    CALL CD_Assemble_Cosserat_Tangent_Force_Banded_Free_Workspace(nodes_ref, elem_conn, ea, gas, ei, gj, q, &
                                                                  reduced_shear, free, kl, ku, work, Kb, fint, &
                                                                  ErrStat, ErrMsg)
  END SUBROUTINE CD_Assemble_Cosserat_Tangent_Force_Banded_Free

  SUBROUTINE CD_Assemble_Cosserat_Tangent_Force_Banded_Free_Workspace(nodes_ref, elem_conn, ea, gas, ei, gj, q, &
                                                                      reduced_shear, free, kl, ku, work, Kb, fint, &
                                                                      ErrStat, ErrMsg, rot_col_chain)
    !! Workspace-backed direct free-band tangent/internal-force assembly. This is
    !! the finite-EI dynamic hot-path entry point; workspace is allocated on
    !! growth and reused across Newton and Armijo evaluations.
    !!
    !! rot_col_chain (optional, 3 x 3 x n_nodes): the multiplicative-SO(3) consistent-
    !! tangent chain Jacobian J_c per node. When present, each element tangent's three
    !! rotation COLUMNS for a node are right-multiplied by that node's J_c before the
    !! band scatter (dfint/dpsi = K . J_c). Absent -> the raw additive tangent dfint/dtheta,
    !! bit-for-bit. Applied on the dense 12x12 element block (matches the FD-verified
    !! dense application in test_finite_ei_mult_tangent), so the band scatter is unchanged.
    REAL(wp), INTENT(IN) :: nodes_ref(:, :), ea(:), gas(:), ei(:), gj(:), q(:)
    INTEGER, INTENT(IN) :: elem_conn(:, :), free(:), kl, ku
    LOGICAL, INTENT(IN) :: reduced_shear
    TYPE(CD_CosseratAssemblyWorkspace), INTENT(INOUT) :: work
    REAL(wp), INTENT(OUT) :: Kb(:, :), fint(:)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    REAL(wp), INTENT(IN), OPTIONAL :: rot_col_chain(:, :, :)
    INTEGER :: n_nodes, n_elem, e, a, b, ndof, gmap(12), i, j, es, fi, fj, row, ldab
    LOGICAL :: apply_chain
    INTEGER(INT64) :: c0, rate
    REAL(wp) :: Lam0(3, 3), L0, qe(12), Kte(12, 12), finte(12)
    CHARACTER(120) :: em

    work%n_tangent = work%n_tangent + 1
    CALL SYSTEM_CLOCK(c0, rate)
    Kb = 0.0_wp
    fint = 0.0_wp
    CALL check_inputs(nodes_ref, elem_conn, ea, gas, ei, gj, q, n_nodes, n_elem, ndof, ErrStat, ErrMsg)
    IF (ErrStat /= 0) RETURN
    ldab = 2*kl + ku + 1
    IF (kl < 0 .OR. ku < 0 .OR. SIZE(Kb, 1) < ldab .OR. SIZE(Kb, 2) /= SIZE(free)) THEN
      ErrStat = 1; ErrMsg = 'CD_Assemble_Cosserat_Tangent_Force_Banded_Free: invalid band storage shape'
      RETURN
    END IF
    IF (SIZE(fint) /= ndof) THEN
      ErrStat = 1; ErrMsg = 'CD_Assemble_Cosserat_Tangent_Force_Banded_Free: fint size inconsistent with mesh'
      RETURN
    END IF
    IF (ANY(free < 1) .OR. ANY(free > ndof)) THEN
      ErrStat = 1; ErrMsg = 'CD_Assemble_Cosserat_Tangent_Force_Banded_Free: free DOF index out of range'
      RETURN
    END IF
    CALL ensure_assembly_workspace(work, ndof, n_elem, .TRUE., ErrStat, ErrMsg)
    IF (ErrStat /= 0) RETURN
    work%global_to_free(1:ndof) = 0
    DO i = 1, SIZE(free)
      IF (work%global_to_free(free(i)) /= 0) THEN
        ErrStat = 1; ErrMsg = 'CD_Assemble_Cosserat_Tangent_Force_Banded_Free: duplicate free DOF'
        RETURN
      END IF
      work%global_to_free(free(i)) = i
    END DO

    apply_chain = PRESENT(rot_col_chain)
    IF (apply_chain) THEN
      IF (SIZE(rot_col_chain, 1) /= 3 .OR. SIZE(rot_col_chain, 2) /= 3 .OR. SIZE(rot_col_chain, 3) /= n_nodes) THEN
        ErrStat = 1
        ErrMsg = 'CD_Assemble_Cosserat_Tangent_Force_Banded_Free: rot_col_chain must be (3,3,n_nodes)'
        RETURN
      END IF
    END IF

    work%fe(:, 1:n_elem) = 0.0_wp
    work%Ke(:, :, 1:n_elem) = 0.0_wp
    work%elem_es(1:n_elem) = 0
    ! elem_em(e) is written with elem_es(e) and read only where elem_es(e) /= 0: no blank fill
    !$OMP PARALLEL DEFAULT(NONE) &
    !$OMP SHARED(n_elem, elem_conn, nodes_ref, q, ea, gas, ei, gj, reduced_shear, work) &
    !$OMP PRIVATE(e, a, b, Lam0, L0, qe, finte, Kte, es, em)
    CALL CD_Fatal_Thread_Init() ! this thread can report its own stack overflow
    !$OMP DO SCHEDULE(static)
    DO e = 1, n_elem
      a = elem_conn(1, e)
      b = elem_conn(2, e)
      CALL CD_Reference_Frame(nodes_ref(:, a), nodes_ref(:, b), Lam0, L0)
      qe(1:6) = q(6*a - 5:6*a)
      qe(7:12) = q(6*b - 5:6*b)
      CALL CD_Cosserat_Force_Tangent(qe, ea(e), gas(e), ei(e), gj(e), Lam0, L0, reduced_shear, &
                                     finte, Kte, es, em)
      IF (es /= 0) THEN
        work%elem_es(e) = es
        work%elem_em(e) = em
      ELSE
        work%fe(:, e) = finte
        work%Ke(:, :, e) = Kte
      END IF
    END DO
    !$OMP END DO
    !$OMP END PARALLEL
    DO e = 1, n_elem
      IF (work%elem_es(e) /= 0) THEN
        Kb = 0.0_wp; fint = 0.0_wp
        ErrStat = 1; ErrMsg = 'CD_Assemble_Cosserat_Tangent_Force_Banded_Free: element '//TRIM(work%elem_em(e))
        RETURN
      END IF
    END DO
    IF (apply_chain) THEN
      ! Multiplicative-SO(3) consistent tangent: right-multiply each element's two nodal
      ! rotation column-triples (cols 4:6 = node a, 10:12 = node b) by that node's chain
      ! Jacobian J_c, on the dense 12x12 block before the band scatter. Serial -- cheap
      ! relative to the parallel tangent assembly, and keeps the optional out of the OMP region.
      DO e = 1, n_elem
        a = elem_conn(1, e)
        b = elem_conn(2, e)
        work%Ke(:, 4:6, e) = MATMUL(work%Ke(:, 4:6, e), rot_col_chain(:, :, a))
        work%Ke(:, 10:12, e) = MATMUL(work%Ke(:, 10:12, e), rot_col_chain(:, :, b))
      END DO
    END IF
    DO e = 1, n_elem
      a = elem_conn(1, e)
      b = elem_conn(2, e)
      DO i = 1, 6
        gmap(i) = 6*a - 6 + i
        gmap(6 + i) = 6*b - 6 + i
      END DO
      DO i = 1, 12
        fint(gmap(i)) = fint(gmap(i)) + work%fe(i, e)
        fi = work%global_to_free(gmap(i))
        IF (fi == 0) CYCLE
        DO j = 1, 12
          fj = work%global_to_free(gmap(j))
          IF (fj == 0) CYCLE
          row = kl + ku + 1 + fi - fj
          IF (row < 1 .OR. row > SIZE(Kb, 1)) THEN
            Kb = 0.0_wp; fint = 0.0_wp
            ErrStat = 1; ErrMsg = 'CD_Assemble_Cosserat_Tangent_Force_Banded_Free: bandwidth too small'
            RETURN
          END IF
          Kb(row, fj) = Kb(row, fj) + work%Ke(i, j, e)
        END DO
      END DO
    END DO
    CALL add_elapsed(work%t_tangent, c0, rate)
  END SUBROUTINE CD_Assemble_Cosserat_Tangent_Force_Banded_Free_Workspace

  SUBROUTINE CD_Assemble_Cosserat_Internal_Force(nodes_ref, elem_conn, ea, gas, ei, gj, q, &
                                                 reduced_shear, fint, ErrStat, ErrMsg)
    !! Assemble only the global internal force (no tangent), for residual-only
    !! evaluations (line search, convergence checks).
    REAL(wp), INTENT(IN) :: nodes_ref(:, :), ea(:), gas(:), ei(:), gj(:), q(:)
    INTEGER, INTENT(IN) :: elem_conn(:, :)
    LOGICAL, INTENT(IN) :: reduced_shear
    REAL(wp), INTENT(OUT) :: fint(:)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    TYPE(CD_CosseratAssemblyWorkspace) :: work

    CALL CD_Assemble_Cosserat_Internal_Force_Workspace(nodes_ref, elem_conn, ea, gas, ei, gj, q, &
                                                       reduced_shear, work, fint, ErrStat, ErrMsg)
  END SUBROUTINE CD_Assemble_Cosserat_Internal_Force

  SUBROUTINE CD_Assemble_Cosserat_Internal_Force_Workspace(nodes_ref, elem_conn, ea, gas, ei, gj, q, &
                                                           reduced_shear, work, fint, ErrStat, ErrMsg)
    !! Workspace-backed global internal-force assembly for residual-only finite-EI
    !! evaluations.
    REAL(wp), INTENT(IN) :: nodes_ref(:, :), ea(:), gas(:), ei(:), gj(:), q(:)
    INTEGER, INTENT(IN) :: elem_conn(:, :)
    LOGICAL, INTENT(IN) :: reduced_shear
    TYPE(CD_CosseratAssemblyWorkspace), INTENT(INOUT) :: work
    REAL(wp), INTENT(OUT) :: fint(:)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    INTEGER :: n_nodes, n_elem, e, a, b, ndof, gmap(12), i, es
    INTEGER(INT64) :: c0, rate
    REAL(wp) :: Lam0(3, 3), L0, qe(12), finte(12)
    CHARACTER(120) :: em

    work%n_force = work%n_force + 1
    CALL SYSTEM_CLOCK(c0, rate)
    fint = 0.0_wp
    CALL check_inputs(nodes_ref, elem_conn, ea, gas, ei, gj, q, n_nodes, n_elem, ndof, ErrStat, ErrMsg)
    IF (ErrStat /= 0) RETURN
    IF (SIZE(fint) /= ndof) THEN
      ErrStat = 1; ErrMsg = 'CD_Assemble_Cosserat_Internal_Force: fint size inconsistent with mesh'
      RETURN
    END IF

    CALL ensure_assembly_workspace(work, 0, n_elem, .FALSE., ErrStat, ErrMsg)
    IF (ErrStat /= 0) RETURN
    work%fe(:, 1:n_elem) = 0.0_wp
    work%elem_es(1:n_elem) = 0
    ! elem_em(e) is written with elem_es(e) and read only where elem_es(e) /= 0: no blank fill
    !$OMP PARALLEL DEFAULT(NONE) &
    !$OMP SHARED(n_elem, elem_conn, nodes_ref, q, ea, gas, ei, gj, reduced_shear, work) &
    !$OMP PRIVATE(e, a, b, Lam0, L0, qe, finte, es, em)
    CALL CD_Fatal_Thread_Init() ! this thread can report its own stack overflow
    !$OMP DO SCHEDULE(static)
    DO e = 1, n_elem
      a = elem_conn(1, e)
      b = elem_conn(2, e)
      CALL CD_Reference_Frame(nodes_ref(:, a), nodes_ref(:, b), Lam0, L0)
      qe(1:6) = q(6*a - 5:6*a)
      qe(7:12) = q(6*b - 5:6*b)
      CALL CD_Cosserat_Internal_Force(qe, ea(e), gas(e), ei(e), gj(e), Lam0, L0, reduced_shear, &
                                      finte, es, em)
      IF (es /= 0) THEN
        work%elem_es(e) = es
        work%elem_em(e) = em
      ELSE
        work%fe(:, e) = finte
      END IF
    END DO
    !$OMP END DO
    !$OMP END PARALLEL
    DO e = 1, n_elem
      IF (work%elem_es(e) /= 0) THEN
        fint = 0.0_wp
        ErrStat = 1; ErrMsg = 'CD_Assemble_Cosserat_Internal_Force: element '//TRIM(work%elem_em(e))
        RETURN
      END IF
    END DO
    DO e = 1, n_elem
      a = elem_conn(1, e)
      b = elem_conn(2, e)
      DO i = 1, 6
        gmap(i) = 6*a - 6 + i
        gmap(6 + i) = 6*b - 6 + i
      END DO
      DO i = 1, 12
        fint(gmap(i)) = fint(gmap(i)) + work%fe(i, e)
      END DO
    END DO
    CALL add_elapsed(work%t_force, c0, rate)
  END SUBROUTINE CD_Assemble_Cosserat_Internal_Force_Workspace

  SUBROUTINE ensure_assembly_workspace(work, ndof, n_elem, need_tangent, ErrStat, ErrMsg)
    TYPE(CD_CosseratAssemblyWorkspace), INTENT(INOUT) :: work
    INTEGER, INTENT(IN) :: ndof, n_elem
    LOGICAL, INTENT(IN) :: need_tangent
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    INTEGER :: istat

    ErrStat = 0
    ErrMsg = ''
    IF (ndof < 0 .OR. n_elem < 0) THEN
      ErrStat = 1
      ErrMsg = 'ensure_assembly_workspace: negative workspace shape'
      RETURN
    END IF
    IF (ndof > 0) THEN
      IF (ALLOCATED(work%global_to_free)) THEN
        IF (SIZE(work%global_to_free) < ndof) DEALLOCATE (work%global_to_free)
      END IF
      IF (.NOT. ALLOCATED(work%global_to_free)) THEN
        ALLOCATE (work%global_to_free(ndof), STAT=istat)
        IF (istat /= 0) THEN
          ErrStat = 1
          ErrMsg = 'ensure_assembly_workspace: global map allocation failed'
          RETURN
        END IF
      END IF
    END IF
    IF (ALLOCATED(work%fe)) THEN
      IF (SIZE(work%fe, 2) < n_elem) DEALLOCATE (work%fe)
    END IF
    IF (.NOT. ALLOCATED(work%fe)) THEN
      ALLOCATE (work%fe(12, n_elem), STAT=istat)
      IF (istat /= 0) THEN
        ErrStat = 1
        ErrMsg = 'ensure_assembly_workspace: element force allocation failed'
        RETURN
      END IF
    END IF
    IF (need_tangent) THEN
      IF (ALLOCATED(work%Ke)) THEN
        IF (SIZE(work%Ke, 3) < n_elem) DEALLOCATE (work%Ke)
      END IF
      IF (.NOT. ALLOCATED(work%Ke)) THEN
        ALLOCATE (work%Ke(12, 12, n_elem), STAT=istat)
        IF (istat /= 0) THEN
          ErrStat = 1
          ErrMsg = 'ensure_assembly_workspace: element tangent allocation failed'
          RETURN
        END IF
      END IF
    END IF
    IF (ALLOCATED(work%elem_es)) THEN
      IF (SIZE(work%elem_es) < n_elem) DEALLOCATE (work%elem_es)
    END IF
    IF (.NOT. ALLOCATED(work%elem_es)) THEN
      ALLOCATE (work%elem_es(n_elem), STAT=istat)
      IF (istat /= 0) THEN
        ErrStat = 1
        ErrMsg = 'ensure_assembly_workspace: element status allocation failed'
        RETURN
      END IF
    END IF
    IF (ALLOCATED(work%elem_em)) THEN
      IF (SIZE(work%elem_em) < n_elem) DEALLOCATE (work%elem_em)
    END IF
    IF (.NOT. ALLOCATED(work%elem_em)) THEN
      ALLOCATE (work%elem_em(n_elem), STAT=istat)
      IF (istat /= 0) THEN
        ErrStat = 1
        ErrMsg = 'ensure_assembly_workspace: element message allocation failed'
      END IF
    END IF
  END SUBROUTINE ensure_assembly_workspace

  SUBROUTINE add_elapsed(total, c0, rate)
    !! Accumulate successful assembly wall-clock time for benchmark diagnostics.
    REAL(wp), INTENT(INOUT) :: total
    INTEGER(INT64), INTENT(IN) :: c0, rate
    INTEGER(INT64) :: c1
    CALL SYSTEM_CLOCK(c1)
    IF (rate > 0_INT64) total = total + REAL(c1 - c0, wp)/REAL(rate, wp)
  END SUBROUTINE add_elapsed

  SUBROUTINE check_inputs(nodes_ref, elem_conn, ea, gas, ei, gj, q, n_nodes, n_elem, ndof, ErrStat, ErrMsg)
    !! Shared connectivity / property / shape / finiteness validation. Connectivity
    !! (range, self-edge, DUPLICATE undirected edge, every-node-referenced) is
    !! delegated to the shared CD_Validate_Connectivity so the finite-EI path
    !! enforces the same mesh contract as the EI=0 path; the zero-length reference
    !! span check is added here because it needs nodes_ref (a collapsed span would
    !! divide by L0 = 0 inside CD_Reference_Frame and emit NaN/Inf).
    REAL(wp), INTENT(IN) :: nodes_ref(:, :), ea(:), gas(:), ei(:), gj(:), q(:)
    INTEGER, INTENT(IN) :: elem_conn(:, :)
    INTEGER, INTENT(OUT) :: n_nodes, n_elem, ndof, ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    INTEGER :: e
    REAL(wp) :: span(3), l0sq
    ErrStat = 0; ErrMsg = ''
    n_nodes = 0; n_elem = 0; ndof = 0
    IF (SIZE(nodes_ref, 1) /= 3) THEN
      ErrStat = 1; ErrMsg = 'check_inputs: nodes_ref must be (3, n_nodes)'; RETURN
    END IF
    IF (SIZE(elem_conn, 1) /= 2) THEN
      ErrStat = 1; ErrMsg = 'check_inputs: elem_conn must be (2, n_elem)'; RETURN
    END IF
    n_nodes = SIZE(nodes_ref, 2)
    n_elem = SIZE(elem_conn, 2)
    ndof = 6*n_nodes
    ! connectivity contract (range / self-edge / duplicate undirected edge /
    ! every-node-referenced / >= 2 nodes / >= 1 element) -- shared with the EI=0 path
    CALL CD_Validate_Connectivity(elem_conn, n_nodes, n_elem, ErrStat, ErrMsg)
    IF (ErrStat /= 0) RETURN
    IF (SIZE(ea) /= n_elem .OR. SIZE(gas) /= n_elem .OR. SIZE(ei) /= n_elem .OR. SIZE(gj) /= n_elem) THEN
      ErrStat = 1; ErrMsg = 'check_inputs: property arrays must have length n_elem'; RETURN
    END IF
    IF (SIZE(q) /= ndof) THEN
      ErrStat = 1; ErrMsg = 'check_inputs: q must have length 6*n_nodes'; RETURN
    END IF
    IF (.NOT. CD_All_Finite(q) .OR. .NOT. CD_All_Finite(nodes_ref)) THEN
      ErrStat = 1; ErrMsg = 'check_inputs: q / nodes_ref contain non-finite values'; RETURN
    END IF
    DO e = 1, n_elem
      IF (.NOT. (ea(e) > 0.0_wp .AND. gas(e) > 0.0_wp .AND. ei(e) > 0.0_wp .AND. gj(e) > 0.0_wp)) THEN
        ErrStat = 1; ErrMsg = 'check_inputs: properties must be finite and positive'; RETURN
      END IF
      ! reject a zero-length (collapsed) reference span: L0 = 0 would divide by
      ! zero in CD_Reference_Frame and propagate NaN into fint/Kt
      span = nodes_ref(:, elem_conn(2, e)) - nodes_ref(:, elem_conn(1, e))
      l0sq = DOT_PRODUCT(span, span)
      IF (.NOT. (l0sq > 0.0_wp) .OR. .NOT. CD_Is_Finite(l0sq)) THEN
        ErrStat = 1; ErrMsg = 'check_inputs: element has a zero-length reference span (L0 = 0)'; RETURN
      END IF
    END DO
  END SUBROUTINE check_inputs

END MODULE CableDyn_CosseratAssemble
