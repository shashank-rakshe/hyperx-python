! File: src/CableDyn_Assemble.f90
! SPDX-License-Identifier: Apache-2.0
! Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
MODULE CableDyn_Assemble
  !! Dense global assembly for the positions-only EI=0 cable path -- the bridge
  !! between the verified element (CableDyn_CableElem) and any future static /
  !! dynamic driver: global tangent + internal force, per-element tension, and
  !! the reference-configuration mass matrix.
  !!
  !! Conventions (column-major, 1-based connectivity):
  !!   nodes(3, n_nodes)        node positions, one column per node
  !!   elem_conn(2, n_elem)     [node_a; node_b] per element, 1-based
  !!   l0(n_elem), ea(n_elem)   per-element properties (rho_a too, for the mass)
  !!   Kt(3 n_nodes, 3 n_nodes), fint(3 n_nodes), tension(n_elem), M(3 n_nodes, ...)
  !! Node `nd` owns global DOFs `3*nd-2 : 3*nd`; element DOFs [1:3] -> node_a,
  !! [4:6] -> node_b. The element force is [-T t ; +T t] (ARCHITECTURE.md sign
  !! convention), scatter-added into the global vector / matrix.
  !!
  !! Dense storage remains the reference path; direct reduced band assembly is
  !! provided for production Newton solves that already know their free-DOF set.
  !! This module adds NO physics -- gravity, buoyancy, seabed, damping, drag, and
  !! the Newton solve live in later modules.
  USE CableDyn_Precision, ONLY: wp, CD_ZERO, CD_ONE, CD_All_Finite
  USE CableDyn_FatalReport, ONLY: CD_Fatal_Thread_Init
  USE CableDyn_CableElem, ONLY: CD_Compute_Cable_Element
  USE CableDyn_Mesh, ONLY: CD_Validate_Connectivity, CD_Validate_Positive, CD_Validate_NonNegative
!$ USE OMP_LIB, ONLY: omp_in_parallel, omp_get_max_threads
  IMPLICIT NONE
  PRIVATE

  ! The axial two-node kernel is small (~30 ns per element), so the element loop is
  ! memory-bound and an OpenMP team only pays off on very long lines. Measured on a
  ! 24-core host (gfortran -O3): a four-thread team first beats the serial loop at
  ! ~8k elements (1.2x; 1.4x at 32k), is slower below 2k at every team size, and larger
  ! teams gain nothing. Real lines therefore stay on the allocation-free serial path;
  ! the team is capped like the per-line team in CableDyn_System.
  INTEGER, PARAMETER :: OMP_AXIAL_MIN_ELEMS = 8192
  INTEGER, PARAMETER :: OMP_AXIAL_MAX_THREADS = 4

  PUBLIC :: CD_Assemble_Cable_Tangent_Force
  PUBLIC :: CD_Cable_Free_Bandwidth
  PUBLIC :: CD_Assemble_Cable_Tangent_Force_Banded_Free
  PUBLIC :: CD_Assemble_Cable_Internal_Force
  PUBLIC :: CD_Compute_Cable_Tension
  PUBLIC :: CD_Assemble_Cable_Mass

CONTAINS

  LOGICAL FUNCTION serial_axial_elements(n_elem)
    INTEGER, INTENT(IN) :: n_elem

    serial_axial_elements = n_elem < OMP_AXIAL_MIN_ELEMS
    ! An independent-line OpenMP worker already owns this line.  Running another
    ! element team here either pays a serialized nested-region cost or
    ! oversubscribes the host when nested parallelism is enabled.
!$  IF (omp_in_parallel()) serial_axial_elements = .TRUE.
    IF (axial_team_size() < 2) serial_axial_elements = .TRUE.
  END FUNCTION serial_axial_elements

  INTEGER FUNCTION axial_team_size() RESULT(n_team)
    !! Thread count for the element loops: the host limit capped at OMP_AXIAL_MAX_THREADS
    !! (1 without OpenMP). Elements are independent and scattered serially afterwards, so
    !! results are identical for every team size.
    n_team = 1
!$  n_team = MAX(1, MIN(OMP_AXIAL_MAX_THREADS, omp_get_max_threads()))
  END FUNCTION axial_team_size

  SUBROUTINE element_failure_message(nodes, elem_conn, l0, ea, tension_only, e, em)
    !! Re-evaluate element e serially to recover the diagnostic of a failure detected
    !! inside a threaded element loop (the loop keeps only per-element status codes).
    REAL(wp), INTENT(IN) :: nodes(:, :), l0(:), ea(:)
    INTEGER, INTENT(IN) :: elem_conn(:, :), e
    LOGICAL, INTENT(IN) :: tension_only
    CHARACTER(*), INTENT(OUT) :: em
    REAL(wp) :: nodes6(6), Kt6(6, 6), fint6(6), Te
    INTEGER :: es

    nodes6(1:3) = nodes(:, elem_conn(1, e))
    nodes6(4:6) = nodes(:, elem_conn(2, e))
    CALL CD_Compute_Cable_Element(nodes6, ea(e), l0(e), tension_only, Kt6, fint6, Te, es, em)
  END SUBROUTINE element_failure_message

  SUBROUTINE CD_Assemble_Cable_Tangent_Force(nodes, elem_conn, l0, ea, &
                                             tension_only, Kt, fint, tension, ErrStat, ErrMsg, topology_validated)
    !! Assemble the dense global tangent stiffness, internal force, and per-element
    !! tension. The EI=0 axial force/tangent depend only on geometry, l0, and ea;
    !! rho_a (mass density) is not an argument here -- the consistent mass is
    !! assembled separately by CD_Assemble_Cable_Mass. topology_validated (default
    !! .FALSE.) skips the connectivity validation for a caller that has already run it on
    !! this elem_conn; the shape and finiteness checks always run.
    REAL(wp), INTENT(IN)  :: nodes(:, :)
    INTEGER, INTENT(IN)  :: elem_conn(:, :)
    REAL(wp), INTENT(IN)  :: l0(:), ea(:)
    LOGICAL, INTENT(IN)  :: tension_only
    REAL(wp), INTENT(OUT) :: Kt(:, :), fint(:), tension(:)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    LOGICAL, INTENT(IN), OPTIONAL :: topology_validated

    INTEGER  :: n_nodes, n_elem, e, a, b, ia, ib, i, j, es
    REAL(wp) :: nodes6(6), Kt6(6, 6), fint6(6), Te
    CHARACTER(120) :: em

    Kt = CD_ZERO
    fint = CD_ZERO
    tension = CD_ZERO
    ! the input checks write messages of at most 80 characters into a 120-character share
    ErrMsg = ''
    CALL check_topology(nodes, elem_conn, n_nodes, n_elem, ErrStat, ErrMsg(1:MIN(LEN(ErrMsg), 120)), &
                        topology_validated)
    IF (ErrStat /= 0) RETURN
    CALL check_props(l0, ea, n_elem, ErrStat, ErrMsg(1:MIN(LEN(ErrMsg), 120)))
    IF (ErrStat /= 0) RETURN
    IF (.NOT. shape_ok_2d(Kt, 3*n_nodes) .OR. SIZE(fint) /= 3*n_nodes &
        .OR. SIZE(tension) /= n_elem) THEN
      CALL fail(ErrStat, ErrMsg, 'output array shapes inconsistent with the mesh')
      RETURN
    END IF

    ! Serial by design: the O(n_dof**2) zero-fill of the dense output dominates, so an
    ! element team cannot pay for itself here (production Newton solves use the band
    ! assembly below).
    DO e = 1, n_elem
      a = elem_conn(1, e)
      b = elem_conn(2, e)
      ia = 3*a - 2
      ib = 3*b - 2
      nodes6(1:3) = nodes(:, a)
      nodes6(4:6) = nodes(:, b)
      CALL CD_Compute_Cable_Element(nodes6, ea(e), l0(e), tension_only, Kt6, fint6, Te, es, em)
      IF (es /= 0) THEN
        Kt = CD_ZERO
        fint = CD_ZERO
        tension = CD_ZERO
        ErrStat = 1
        ErrMsg = 'CD_Assemble_Cable_Tangent_Force: '//elem_label(e)//TRIM(em)
        RETURN
      END IF
      tension(e) = Te
      fint(ia:ia + 2) = fint(ia:ia + 2) + fint6(1:3)
      fint(ib:ib + 2) = fint(ib:ib + 2) + fint6(4:6)
      DO i = 1, 3
        DO j = 1, 3
          Kt(ia + i - 1, ia + j - 1) = Kt(ia + i - 1, ia + j - 1) + Kt6(i, j)
          Kt(ia + i - 1, ib + j - 1) = Kt(ia + i - 1, ib + j - 1) + Kt6(i, 3 + j)
          Kt(ib + i - 1, ia + j - 1) = Kt(ib + i - 1, ia + j - 1) + Kt6(3 + i, j)
          Kt(ib + i - 1, ib + j - 1) = Kt(ib + i - 1, ib + j - 1) + Kt6(3 + i, 3 + j)
        END DO
      END DO
    END DO
  END SUBROUTINE CD_Assemble_Cable_Tangent_Force

  SUBROUTINE CD_Cable_Free_Bandwidth(elem_conn, n_nodes, free, kl, ku, ErrStat, ErrMsg, topology_validated)
    !! Compute the occupied lower/upper bandwidth of the positions-only cable
    !! tangent after reduction to the sorted free-DOF list. This is
    !! connectivity-only: every two-node axial element may couple all 6 local
    !! translational DOFs. topology_validated as in CD_Assemble_Cable_Tangent_Force.
    INTEGER, INTENT(IN) :: elem_conn(:, :), n_nodes, free(:)
    INTEGER, INTENT(OUT) :: kl, ku, ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    LOGICAL, INTENT(IN), OPTIONAL :: topology_validated

    INTEGER :: n_elem, ndof, e, a, b, i, j, fi, fj, gmap(6)
    INTEGER, ALLOCATABLE :: global_to_free(:)

    kl = 0
    ku = 0
    ErrStat = 0
    ErrMsg = ''
    IF (SIZE(elem_conn, 1) /= 2) THEN
      CALL fail(ErrStat, ErrMsg, 'elem_conn must have shape (2, n_elem)')
      RETURN
    END IF
    n_elem = SIZE(elem_conn, 2)
    ndof = 3*n_nodes
    IF (.NOT. flag_set(topology_validated)) THEN
      CALL CD_Validate_Connectivity(elem_conn, n_nodes, n_elem, ErrStat, ErrMsg)
      IF (ErrStat /= 0) RETURN
    END IF
    IF (ANY(free < 1) .OR. ANY(free > ndof)) THEN
      CALL fail(ErrStat, ErrMsg, 'free DOF index out of range')
      RETURN
    END IF

    ALLOCATE (global_to_free(ndof), source=0)
    DO i = 1, SIZE(free)
      IF (global_to_free(free(i)) /= 0) THEN
        CALL fail(ErrStat, ErrMsg, 'duplicate free DOF')
        RETURN
      END IF
      global_to_free(free(i)) = i
    END DO

    DO e = 1, n_elem
      a = elem_conn(1, e)
      b = elem_conn(2, e)
      DO i = 1, 3
        gmap(i) = 3*a - 3 + i
        gmap(3 + i) = 3*b - 3 + i
      END DO
      DO j = 1, 6
        fj = global_to_free(gmap(j))
        IF (fj == 0) CYCLE
        DO i = 1, 6
          fi = global_to_free(gmap(i))
          IF (fi == 0) CYCLE
          IF (fi > fj) kl = MAX(kl, fi - fj)
          IF (fj > fi) ku = MAX(ku, fj - fi)
        END DO
      END DO
    END DO
  END SUBROUTINE CD_Cable_Free_Bandwidth

  SUBROUTINE CD_Assemble_Cable_Tangent_Force_Banded_Free(nodes, elem_conn, l0, ea, tension_only, &
                                                         free, kl, ku, Kb, fint, tension, ErrStat, ErrMsg, &
                                                         topology_validated, free_map)
    !! Assemble the free-DOF tangent directly into LAPACK general-band storage:
    !! Kb(kl+ku+1+i-j, j) = K_free(i,j). The full internal-force vector and
    !! element tensions are assembled alongside the banded tangent.
    !! topology_validated as in CD_Assemble_Cable_Tangent_Force. free_map (optional,
    !! 3 n_nodes entries) is the caller's global-to-free map of this `free` list: the free
    !! index of a free DOF and <= 0 for a fixed one. Without it the map is built here.
    REAL(wp), INTENT(IN)  :: nodes(:, :)
    INTEGER, INTENT(IN)  :: elem_conn(:, :), free(:), kl, ku
    REAL(wp), INTENT(IN)  :: l0(:), ea(:)
    LOGICAL, INTENT(IN)  :: tension_only
    REAL(wp), INTENT(OUT) :: Kb(:, :), fint(:), tension(:)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    LOGICAL, INTENT(IN), OPTIONAL :: topology_validated
    INTEGER, INTENT(IN), OPTIONAL :: free_map(:)

    INTEGER  :: n_nodes, n_elem, ndof, i, ldab
    INTEGER, ALLOCATABLE :: global_to_free(:)

    Kb = CD_ZERO
    fint = CD_ZERO
    tension = CD_ZERO
    ! the input checks write messages of at most 80 characters into a 120-character share
    ErrMsg = ''
    CALL check_topology(nodes, elem_conn, n_nodes, n_elem, ErrStat, ErrMsg(1:MIN(LEN(ErrMsg), 120)), &
                        topology_validated)
    IF (ErrStat /= 0) RETURN
    CALL check_props(l0, ea, n_elem, ErrStat, ErrMsg(1:MIN(LEN(ErrMsg), 120)))
    IF (ErrStat /= 0) RETURN
    ndof = 3*n_nodes
    ldab = 2*kl + ku + 1
    IF (kl < 0 .OR. ku < 0 .OR. SIZE(Kb, 1) < ldab .OR. SIZE(Kb, 2) /= SIZE(free)) THEN
      CALL fail(ErrStat, ErrMsg, 'invalid band storage shape')
      RETURN
    END IF
    IF (SIZE(fint) /= ndof .OR. SIZE(tension) /= n_elem) THEN
      CALL fail(ErrStat, ErrMsg, 'output array shapes inconsistent with the mesh')
      RETURN
    END IF
    IF (ANY(free < 1) .OR. ANY(free > ndof)) THEN
      CALL fail(ErrStat, ErrMsg, 'free DOF index out of range')
      RETURN
    END IF

    IF (PRESENT(free_map)) THEN
      IF (SIZE(free_map) < ndof) THEN
        CALL fail(ErrStat, ErrMsg, 'free_map must cover every DOF')
        RETURN
      END IF
      CALL assemble_elements(free_map)
      RETURN
    END IF
    ALLOCATE (global_to_free(ndof), source=0)
    DO i = 1, SIZE(free)
      IF (global_to_free(free(i)) /= 0) THEN
        CALL fail(ErrStat, ErrMsg, 'duplicate free DOF')
        RETURN
      END IF
      global_to_free(free(i)) = i
    END DO
    CALL assemble_elements(global_to_free)

  CONTAINS

    SUBROUTINE assemble_elements(g2f)
      !! Scatter every element into Kb, fint and tension through the global-to-free map g2f.
      INTEGER, INTENT(IN) :: g2f(:)
      INTEGER  :: e, a, b, i, j, fi, fj, row, gmap(6), elem_es
      REAL(wp) :: nodes6(6), Kt6(6, 6), fint6(6), Te
      CHARACTER(120) :: em

      DO e = 1, n_elem
        a = elem_conn(1, e)
        b = elem_conn(2, e)
        nodes6(1:3) = nodes(:, a)
        nodes6(4:6) = nodes(:, b)
        CALL CD_Compute_Cable_Element(nodes6, ea(e), l0(e), tension_only, Kt6, fint6, Te, elem_es, em)
        IF (elem_es /= 0) THEN
          Kb = CD_ZERO
          fint = CD_ZERO
          tension = CD_ZERO
          ErrStat = 1
          ErrMsg = 'CD_Assemble_Cable_Tangent_Force_Banded_Free: '//elem_label(e)//TRIM(em)
          RETURN
        END IF

        DO j = 1, 3
          gmap(j) = 3*a - 3 + j
          gmap(3 + j) = 3*b - 3 + j
        END DO
        tension(e) = Te
        DO i = 1, 6
          fint(gmap(i)) = fint(gmap(i)) + fint6(i)
          fi = g2f(gmap(i))
          IF (fi <= 0) CYCLE
          DO j = 1, 6
            fj = g2f(gmap(j))
            IF (fj <= 0) CYCLE
            row = kl + ku + 1 + fi - fj
            ! An entry outside the kl/ku band (or past the matrix) would land in the
            ! factorization fill rows or be dropped: fail closed instead.
            IF (fi - fj > kl .OR. fj - fi > ku .OR. fj > SIZE(Kb, 2) .OR. row > SIZE(Kb, 1)) THEN
              Kb = CD_ZERO
              fint = CD_ZERO
              tension = CD_ZERO
              ErrStat = 1
              ErrMsg = 'CD_Assemble_Cable_Tangent_Force_Banded_Free: bandwidth too small'
              RETURN
            END IF
            Kb(row, fj) = Kb(row, fj) + Kt6(i, j)
          END DO
        END DO
      END DO
    END SUBROUTINE assemble_elements
  END SUBROUTINE CD_Assemble_Cable_Tangent_Force_Banded_Free

  SUBROUTINE CD_Assemble_Cable_Internal_Force(nodes, elem_conn, l0, ea, tension_only, &
                                              fint, ErrStat, ErrMsg, topology_validated)
    !! Assemble the dense global internal force without forming a tangent.
    !! topology_validated as in CD_Assemble_Cable_Tangent_Force.
    REAL(wp), INTENT(IN)  :: nodes(:, :)
    INTEGER, INTENT(IN)  :: elem_conn(:, :)
    REAL(wp), INTENT(IN)  :: l0(:), ea(:)
    LOGICAL, INTENT(IN)  :: tension_only
    REAL(wp), INTENT(OUT) :: fint(:)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    LOGICAL, INTENT(IN), OPTIONAL :: topology_validated

    INTEGER  :: n_nodes, n_elem, e, a, b, ia, ib, es
    REAL(wp) :: nodes6(6), Kt6(6, 6), fint6(6), Te
    REAL(wp), ALLOCATABLE :: fe(:, :)
    INTEGER, ALLOCATABLE :: elem_es(:)
    INTEGER :: n_team
    CHARACTER(120) :: em

    fint = CD_ZERO
    ! the input checks write messages of at most 80 characters into a 120-character share
    ErrMsg = ''
    CALL check_topology(nodes, elem_conn, n_nodes, n_elem, ErrStat, ErrMsg(1:MIN(LEN(ErrMsg), 120)), &
                        topology_validated)
    IF (ErrStat /= 0) RETURN
    CALL check_props(l0, ea, n_elem, ErrStat, ErrMsg(1:MIN(LEN(ErrMsg), 120)))
    IF (ErrStat /= 0) RETURN
    IF (SIZE(fint) /= 3*n_nodes) THEN
      CALL fail(ErrStat, ErrMsg, 'fint must have shape (3 n_nodes)')
      RETURN
    END IF

    IF (serial_axial_elements(n_elem)) THEN
      DO e = 1, n_elem
        a = elem_conn(1, e)
        b = elem_conn(2, e)
        ia = 3*a - 2
        ib = 3*b - 2
        nodes6(1:3) = nodes(:, a)
        nodes6(4:6) = nodes(:, b)
        CALL CD_Compute_Cable_Element(nodes6, ea(e), l0(e), tension_only, Kt6, fint6, Te, es, em)
        IF (es /= 0) THEN
          fint = CD_ZERO
          ErrStat = 1
          ErrMsg = 'CD_Assemble_Cable_Internal_Force: '//elem_label(e)//TRIM(em)
          RETURN
        END IF
        fint(ia:ia + 2) = fint(ia:ia + 2) + fint6(1:3)
        fint(ib:ib + 2) = fint(ib:ib + 2) + fint6(4:6)
      END DO
      RETURN
    END IF

    ALLOCATE (fe(6, n_elem), elem_es(n_elem))
    n_team = axial_team_size()
    !$OMP PARALLEL DEFAULT(NONE) NUM_THREADS(n_team) &
    !$OMP SHARED(n_elem, elem_conn, nodes, ea, l0, tension_only, fe, elem_es) &
    !$OMP PRIVATE(e, a, b, nodes6, Kt6, Te, em)
    CALL CD_Fatal_Thread_Init() ! this thread can report its own stack overflow
    !$OMP DO SCHEDULE(static)
    DO e = 1, n_elem
      a = elem_conn(1, e)
      b = elem_conn(2, e)
      nodes6(1:3) = nodes(:, a)
      nodes6(4:6) = nodes(:, b)
      CALL CD_Compute_Cable_Element(nodes6, ea(e), l0(e), tension_only, Kt6, fe(:, e), Te, elem_es(e), em)
    END DO
    !$OMP END DO
    !$OMP END PARALLEL
    DO e = 1, n_elem
      IF (elem_es(e) /= 0) THEN
        ! Re-evaluate the first failing element serially for its message.
        CALL element_failure_message(nodes, elem_conn, l0, ea, tension_only, e, em)
        fint = CD_ZERO
        ErrStat = 1
        ErrMsg = 'CD_Assemble_Cable_Internal_Force: '//elem_label(e)//TRIM(em)
        RETURN
      END IF
    END DO
    DO e = 1, n_elem
      a = elem_conn(1, e)
      b = elem_conn(2, e)
      ia = 3*a - 2
      ib = 3*b - 2
      fint(ia:ia + 2) = fint(ia:ia + 2) + fe(1:3, e)
      fint(ib:ib + 2) = fint(ib:ib + 2) + fe(4:6, e)
    END DO
  END SUBROUTINE CD_Assemble_Cable_Internal_Force

  SUBROUTINE CD_Compute_Cable_Tension(nodes, elem_conn, l0, ea, tension_only, &
                                      tension, ErrStat, ErrMsg, topology_validated)
    !! Return the scalar axial tension of every element.
    REAL(wp), INTENT(IN)  :: nodes(:, :)
    INTEGER, INTENT(IN)  :: elem_conn(:, :)
    REAL(wp), INTENT(IN)  :: l0(:), ea(:)
    LOGICAL, INTENT(IN)  :: tension_only
    REAL(wp), INTENT(OUT) :: tension(:)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    LOGICAL, INTENT(IN), OPTIONAL :: topology_validated

    INTEGER  :: n_nodes, n_elem, e, a, b, es
    REAL(wp) :: nodes6(6), Kt6(6, 6), fint6(6), Te
    REAL(wp), ALLOCATABLE :: te_buf(:)
    INTEGER, ALLOCATABLE :: elem_es(:)
    INTEGER :: n_team
    CHARACTER(120) :: em

    tension = CD_ZERO
    ! the input checks write messages of at most 80 characters into a 120-character share
    ErrMsg = ''
    CALL check_topology(nodes, elem_conn, n_nodes, n_elem, ErrStat, ErrMsg(1:MIN(LEN(ErrMsg), 120)), &
                        topology_validated)
    IF (ErrStat /= 0) RETURN
    CALL check_props(l0, ea, n_elem, ErrStat, ErrMsg(1:MIN(LEN(ErrMsg), 120)))
    IF (ErrStat /= 0) RETURN
    IF (SIZE(tension) /= n_elem) THEN
      CALL fail(ErrStat, ErrMsg, 'tension must have shape (n_elem)')
      RETURN
    END IF

    IF (serial_axial_elements(n_elem)) THEN
      DO e = 1, n_elem
        a = elem_conn(1, e)
        b = elem_conn(2, e)
        nodes6(1:3) = nodes(:, a)
        nodes6(4:6) = nodes(:, b)
        CALL CD_Compute_Cable_Element(nodes6, ea(e), l0(e), tension_only, Kt6, fint6, Te, es, em)
        IF (es /= 0) THEN
          tension = CD_ZERO
          ErrStat = 1
          ErrMsg = 'CD_Compute_Cable_Tension: '//elem_label(e)//TRIM(em)
          RETURN
        END IF
        tension(e) = Te
      END DO
      RETURN
    END IF

    ALLOCATE (te_buf(n_elem), elem_es(n_elem))
    n_team = axial_team_size()
    !$OMP PARALLEL DEFAULT(NONE) NUM_THREADS(n_team) &
    !$OMP SHARED(n_elem, elem_conn, nodes, ea, l0, tension_only, te_buf, elem_es) &
    !$OMP PRIVATE(e, a, b, nodes6, Kt6, fint6, em)
    CALL CD_Fatal_Thread_Init() ! this thread can report its own stack overflow
    !$OMP DO SCHEDULE(static)
    DO e = 1, n_elem
      a = elem_conn(1, e)
      b = elem_conn(2, e)
      nodes6(1:3) = nodes(:, a)
      nodes6(4:6) = nodes(:, b)
      CALL CD_Compute_Cable_Element(nodes6, ea(e), l0(e), tension_only, Kt6, fint6, te_buf(e), elem_es(e), em)
    END DO
    !$OMP END DO
    !$OMP END PARALLEL
    DO e = 1, n_elem
      IF (elem_es(e) /= 0) THEN
        ! Re-evaluate the first failing element serially for its message.
        CALL element_failure_message(nodes, elem_conn, l0, ea, tension_only, e, em)
        tension = CD_ZERO
        ErrStat = 1
        ErrMsg = 'CD_Compute_Cable_Tension: '//elem_label(e)//TRIM(em)
        RETURN
      END IF
    END DO
    tension = te_buf
  END SUBROUTINE CD_Compute_Cable_Tension

  SUBROUTINE CD_Assemble_Cable_Mass(elem_conn, l0, rho_a, M, ErrStat, ErrMsg, topology_validated)
    !! Assemble the dense configuration-independent consistent translational mass.
    !! Per element ``m = rho_a L0``; the 6x6 block is ``m/6 [[2I, I], [I, 2I]]``
    !! (I the 3x3 identity), scatter-added. n_nodes is taken from ``M``'s shape.
    INTEGER, INTENT(IN)  :: elem_conn(:, :)
    REAL(wp), INTENT(IN)  :: l0(:), rho_a(:)
    REAL(wp), INTENT(OUT) :: M(:, :)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    LOGICAL, INTENT(IN), OPTIONAL :: topology_validated

    INTEGER  :: n_nodes, n_elem, e, a, b, ia, ib, i
    REAL(wp) :: eye(3, 3), coeff

    M = CD_ZERO
    ErrStat = 0
    ErrMsg = ''
    IF (SIZE(elem_conn, 1) /= 2) THEN
      CALL fail(ErrStat, ErrMsg, 'elem_conn must have shape (2, n_elem)')
      RETURN
    END IF
    IF (SIZE(M, 1) /= SIZE(M, 2) .OR. MOD(SIZE(M, 1), 3) /= 0) THEN
      CALL fail(ErrStat, ErrMsg, 'M must be square with shape (3 n_nodes, 3 n_nodes)')
      RETURN
    END IF
    n_nodes = SIZE(M, 1)/3
    n_elem = SIZE(elem_conn, 2)
    IF (.NOT. flag_set(topology_validated)) THEN
      CALL CD_Validate_Connectivity(elem_conn, n_nodes, n_elem, ErrStat, ErrMsg)
      IF (ErrStat /= 0) RETURN
    END IF
    CALL CD_Validate_Positive('l0', l0, n_elem, ErrStat, ErrMsg)
    IF (ErrStat /= 0) RETURN
    CALL CD_Validate_Positive('rho_a', rho_a, n_elem, ErrStat, ErrMsg)
    IF (ErrStat /= 0) RETURN

    eye = CD_ZERO
    DO i = 1, 3
      eye(i, i) = CD_ONE
    END DO

    DO e = 1, n_elem
      a = elem_conn(1, e)
      b = elem_conn(2, e)
      coeff = rho_a(e)*l0(e)/6.0_wp
      ia = 3*a - 2
      ib = 3*b - 2
      M(ia:ia + 2, ia:ia + 2) = M(ia:ia + 2, ia:ia + 2) + 2.0_wp*coeff*eye
      M(ia:ia + 2, ib:ib + 2) = M(ia:ia + 2, ib:ib + 2) + coeff*eye
      M(ib:ib + 2, ia:ia + 2) = M(ib:ib + 2, ia:ia + 2) + coeff*eye
      M(ib:ib + 2, ib:ib + 2) = M(ib:ib + 2, ib:ib + 2) + 2.0_wp*coeff*eye
    END DO
  END SUBROUTINE CD_Assemble_Cable_Mass

  ! --------------------------------------------------------------------------- !
  ! private validation helpers                                                  !
  ! --------------------------------------------------------------------------- !

  SUBROUTINE check_topology(nodes, elem_conn, n_nodes, n_elem, ErrStat, ErrMsg, topology_validated)
    !! Shape and finiteness checks, then the connectivity validation unless the caller
    !! has already validated this elem_conn (topology_validated).
    REAL(wp), INTENT(IN)  :: nodes(:, :)
    INTEGER, INTENT(IN)  :: elem_conn(:, :)
    INTEGER, INTENT(OUT) :: n_nodes, n_elem, ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    LOGICAL, INTENT(IN), OPTIONAL :: topology_validated
    ErrStat = 0
    ErrMsg = ''
    n_nodes = SIZE(nodes, 2)
    n_elem = SIZE(elem_conn, 2)
    IF (SIZE(nodes, 1) /= 3) THEN
      CALL fail(ErrStat, ErrMsg, 'nodes must have shape (3, n_nodes)')
      RETURN
    END IF
    IF (SIZE(elem_conn, 1) /= 2) THEN
      CALL fail(ErrStat, ErrMsg, 'elem_conn must have shape (2, n_elem)')
      RETURN
    END IF
    IF (.NOT. CD_All_Finite(nodes)) THEN
      CALL fail(ErrStat, ErrMsg, 'node coordinates must be finite')
      RETURN
    END IF
    IF (flag_set(topology_validated)) RETURN
    CALL CD_Validate_Connectivity(elem_conn, n_nodes, n_elem, ErrStat, ErrMsg)
  END SUBROUTINE check_topology

  PURE LOGICAL FUNCTION flag_set(flag)
    !! An optional logical flag, .FALSE. when absent.
    LOGICAL, INTENT(IN), OPTIONAL :: flag
    flag_set = .FALSE.
    IF (PRESENT(flag)) flag_set = flag
  END FUNCTION flag_set

  SUBROUTINE check_props(l0, ea, n_elem, ErrStat, ErrMsg)
    !! l0 per element: shape (n_elem) and finite-positive. ea: finite and
    !! NON-NEGATIVE -- ea = 0 is the deliberate elastic-off construction the
    !! model uses for viscoelastic elements (their tension comes from the series-Kelvin
    !! load contributor); user-facing entry points still demand ea > 0. (The
    !! element routine re-checks each value, but failing here gives a clearer
    !! message.)
    REAL(wp), INTENT(IN)  :: l0(:), ea(:)
    INTEGER, INTENT(IN)  :: n_elem
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    CALL CD_Validate_Positive('l0', l0, n_elem, ErrStat, ErrMsg)
    IF (ErrStat /= 0) RETURN
    CALL CD_Validate_NonNegative('ea', ea, n_elem, ErrStat, ErrMsg)
  END SUBROUTINE check_props

  LOGICAL FUNCTION shape_ok_2d(arr, n) RESULT(ok)
    REAL(wp), INTENT(IN) :: arr(:, :)
    INTEGER, INTENT(IN) :: n
    ok = (SIZE(arr, 1) == n .AND. SIZE(arr, 2) == n)
  END FUNCTION shape_ok_2d

  SUBROUTINE fail(ErrStat, ErrMsg, msg)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    CHARACTER(*), INTENT(IN)  :: msg
    ErrStat = 1
    ErrMsg = 'CableDyn_Assemble: '//msg
  END SUBROUTINE fail

  PURE FUNCTION elem_label(e) RESULT(label)
    !! 'element <e>: ' for element-failure messages.
    INTEGER, INTENT(IN) :: e
    CHARACTER(:), ALLOCATABLE :: label
    CHARACTER(16) :: buf
    WRITE (buf, '(I0)') e
    label = 'element '//TRIM(buf)//': '
  END FUNCTION elem_label

END MODULE CableDyn_Assemble
