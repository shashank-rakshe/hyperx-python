! File: tests/test_cable_assemble.f90
! SPDX-License-Identifier: Apache-2.0
! Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
PROGRAM test_cable_assemble
  !! Unit tests for CableDyn_Assemble (dense EI=0 global assembly), cross-validated
  !! against independently computed values. The reference-parity
  !! block embeds Kt / fint / M / tension computed independently on a fixed
  !! non-axis-aligned two-element case. Plain CTest program: `error stop 1` on
  !! any mismatch.
  USE CableDyn_Precision, ONLY: wp
  USE CableDyn_CableElem, ONLY: CD_Compute_Cable_Element
  USE CableDyn_Assemble, ONLY: CD_Assemble_Cable_Tangent_Force, &
                               CD_Assemble_Cable_Tangent_Force_Banded_Free, CD_Cable_Free_Bandwidth, &
                               CD_Assemble_Cable_Internal_Force, &
                               CD_Compute_Cable_Tension, CD_Assemble_Cable_Mass
  IMPLICIT NONE

  INTEGER :: nfail
  nfail = 0

  CALL case_single_element_equals_element_routine()
  CALL case_two_element_straight_chain()
  CALL case_compression_clamp()
  CALL case_compression_capable_bar()
  CALL case_consistent_mass()
  CALL case_reference_parity()
  CALL case_banded_free_matches_dense_free_block()
  CALL case_large_parallel_path_matches_outputs()
  CALL case_invalid_topology()
  CALL case_element_failure_zeros_outputs()
  CALL case_degenerate_mesh_size()

  IF (nfail > 0) THEN
    WRITE (*, '(A,I0,A)') 'FAIL: ', nfail, ' assertion(s) failed'
    ERROR STOP 1
  END IF
  WRITE (*, '(A)') 'PASS: CableDyn_Assemble matches the independent reference values'

CONTAINS

  INCLUDE 'nan_max_abs.inc'

  SUBROUTINE expect(got, want, label)
    !! Tight combined tolerance: atol 1e-10 (near-zero floor), rtol 1e-12.
    REAL(wp), INTENT(IN) :: got, want
    CHARACTER(*), INTENT(IN) :: label
    REAL(wp), PARAMETER :: atol = 1.0e-10_wp, rtol = 1.0e-12_wp
    IF (.NOT. (ABS(got - want) <= atol + rtol*ABS(want))) THEN
      WRITE (*, '(A,A,A,ES23.15,A,ES23.15)') 'MISMATCH [', label, ']: got ', got, ' want ', want
      nfail = nfail + 1
    END IF
  END SUBROUTINE expect

  SUBROUTINE expect_ok(es, label)
    INTEGER, INTENT(IN) :: es
    CHARACTER(*), INTENT(IN) :: label
    IF (es /= 0) THEN
      WRITE (*, '(A,A,A,I0)') 'MISMATCH [', label, ']: ErrStat = ', es
      nfail = nfail + 1
    END IF
  END SUBROUTINE expect_ok

  SUBROUTINE require(cond, label)
    LOGICAL, INTENT(IN) :: cond
    CHARACTER(*), INTENT(IN) :: label
    IF (.NOT. cond) THEN
      WRITE (*, '(A,A,A)') 'MISMATCH [', label, ']: condition false'
      nfail = nfail + 1
    END IF
  END SUBROUTINE require

  SUBROUTINE case_single_element_equals_element_routine()
    !! One element: the assembled Kt / fint / tension equal the element routine.
    REAL(wp) :: nodes(3, 2), l0(1), ea(1)
    REAL(wp) :: Kt(6, 6), fint(6), tension(1)
    REAL(wp) :: nodes6(6), Kt6(6, 6), fint6(6), Te
    INTEGER :: conn(2, 1), es, i, j
    CHARACTER(120) :: em
    nodes = RESHAPE([0.0_wp, 0.0_wp, 0.0_wp, 1.3_wp, 0.4_wp, -0.2_wp], [3, 2])
    conn = RESHAPE([1, 2], [2, 1])
    l0 = [1.0_wp]; ea = [137.0_wp]
    CALL CD_Assemble_Cable_Tangent_Force(nodes, conn, l0, ea, .TRUE., Kt, fint, tension, es, em)
    CALL expect_ok(es, 'single:ErrStat')
    nodes6(1:3) = nodes(:, 1); nodes6(4:6) = nodes(:, 2)
    CALL CD_Compute_Cable_Element(nodes6, ea(1), l0(1), .TRUE., Kt6, fint6, Te, es, em)
    CALL expect(tension(1), Te, 'single:tension')
    DO i = 1, 6
      CALL expect(fint(i), fint6(i), 'single:fint')
      DO j = 1, 6
        CALL expect(Kt(i, j), Kt6(i, j), 'single:Kt')
      END DO
    END DO
  END SUBROUTINE case_single_element_equals_element_routine

  SUBROUTINE case_large_parallel_path_matches_outputs()
    !! Exercise the threaded element branch at its production crossover (8192 elements,
    !! the OMP_AXIAL_MIN_ELEMS threshold). The internal force and tension must equal a
    !! serial element-by-element reference bit for bit, and the serial band assembly's
    !! force, regardless of thread count; a failing element must surface its own
    !! diagnostic and zero every output.
    INTEGER, PARAMETER :: ne = 8192, nn = ne + 1, nd = 3*nn, kl = 5, ku = 5
    REAL(wp), ALLOCATABLE :: nodes(:, :), l0(:), ea(:), Kb(:, :), fint(:), f_only(:), f_ref(:)
    REAL(wp), ALLOCATABLE :: tension(:), t_only(:), t_ref(:)
    INTEGER, ALLOCATABLE :: conn(:, :), free(:)
    REAL(wp) :: n6(6), k6(6, 6), f6(6), te
    INTEGER :: e, es
    CHARACTER(120) :: em

    ALLOCATE (nodes(3, nn), l0(ne), ea(ne), Kb(2*kl + ku + 1, nd), fint(nd), f_only(nd), f_ref(nd), &
              tension(ne), t_only(ne), t_ref(ne), conn(2, ne), free(nd))
    DO e = 1, nn
      nodes(:, e) = [1.01_wp*REAL(e - 1, wp), 0.0_wp, -1.0e-3_wp*REAL(MOD(e, 7), wp)]
    END DO
    DO e = 1, ne
      conn(:, e) = [e, e + 1]
    END DO
    DO e = 1, nd
      free(e) = e
    END DO
    l0 = 1.0_wp
    ea = 1.0e5_wp

    f_ref = 0.0_wp
    DO e = 1, ne
      n6(1:3) = nodes(:, e)
      n6(4:6) = nodes(:, e + 1)
      CALL CD_Compute_Cable_Element(n6, ea(e), l0(e), .TRUE., k6, f6, te, es, em)
      t_ref(e) = te
      f_ref(3*e - 2:3*e) = f_ref(3*e - 2:3*e) + f6(1:3)
      f_ref(3*e + 1:3*e + 3) = f_ref(3*e + 1:3*e + 3) + f6(4:6)
    END DO

    CALL CD_Assemble_Cable_Tangent_Force_Banded_Free(nodes, conn, l0, ea, .TRUE., free, kl, ku, Kb, fint, &
                                                     tension, es, em)
    CALL expect_ok(es, 'large parallel:band tangent force')
    CALL CD_Assemble_Cable_Internal_Force(nodes, conn, l0, ea, .TRUE., f_only, es, em)
    CALL expect_ok(es, 'large parallel:internal force')
    CALL CD_Compute_Cable_Tension(nodes, conn, l0, ea, .TRUE., t_only, es, em)
    CALL expect_ok(es, 'large parallel:tension')
    CALL require(nan_max_abs(f_only - f_ref) <= 0.0_wp .AND. nan_max_abs(fint - f_ref) <= 0.0_wp, &
                 'large parallel:force bit parity')
    CALL require(nan_max_abs(t_only - t_ref) <= 0.0_wp .AND. nan_max_abs(tension - t_ref) <= 0.0_wp, &
                 'large parallel:tension bit parity')
    CALL require(ALL(tension > 0.0_wp), 'large parallel:positive tension')

    ! collapse element 4000 (node 4001 onto node 4000): the threaded loop records only
    ! a status, so the message must come from the serial re-evaluation
    nodes(:, 4001) = nodes(:, 4000)
    CALL CD_Assemble_Cable_Internal_Force(nodes, conn, l0, ea, .TRUE., f_only, es, em)
    CALL require(es /= 0 .AND. INDEX(em, 'collapsed') > 0 .AND. nan_max_abs(f_only) <= 0.0_wp, &
                 'large parallel:internal force failure message and zeroed output')
    CALL CD_Compute_Cable_Tension(nodes, conn, l0, ea, .TRUE., t_only, es, em)
    CALL require(es /= 0 .AND. INDEX(em, 'collapsed') > 0 .AND. nan_max_abs(t_only) <= 0.0_wp, &
                 'large parallel:tension failure message and zeroed output')
  END SUBROUTINE case_large_parallel_path_matches_outputs

  SUBROUTINE case_two_element_straight_chain()
    !! Three colinear nodes, equal stretch: middle-node forces cancel, end forces
    !! are equal and opposite, both segments carry the same tension T = EA*eps.
    REAL(wp) :: nodes(3, 3), l0(2), ea(2)
    REAL(wp) :: fint(9), t_expected
    INTEGER :: conn(2, 2), es
    CHARACTER(120) :: em
    nodes = RESHAPE([0.0_wp, 0.0_wp, 0.0_wp, 1.5_wp, 0.0_wp, 0.0_wp, 3.0_wp, 0.0_wp, 0.0_wp], [3, 3])
    conn = RESHAPE([1, 2, 2, 3], [2, 2])
    l0 = [1.0_wp, 1.0_wp]; ea = [100.0_wp, 100.0_wp]
    CALL CD_Assemble_Cable_Internal_Force(nodes, conn, l0, ea, .TRUE., fint, es, em)
    CALL expect_ok(es, 'chain:ErrStat')
    t_expected = 100.0_wp*(1.5_wp/1.0_wp - 1.0_wp)   ! EA * eps = 50
    ! middle node (DOFs 4:6) internal forces cancel
    CALL expect(fint(4), 0.0_wp, 'chain:mid-x')
    CALL expect(fint(5), 0.0_wp, 'chain:mid-y')
    CALL expect(fint(6), 0.0_wp, 'chain:mid-z')
    ! end nodes equal and opposite along x
    CALL expect(fint(1), -t_expected, 'chain:end1-x')
    CALL expect(fint(7), t_expected, 'chain:end3-x')
    CALL expect(fint(1), -fint(7), 'chain:ends-opposite')
  END SUBROUTINE case_two_element_straight_chain

  SUBROUTINE case_compression_clamp()
    !! A compressed tension-only element assembles to zero force / tangent / tension.
    REAL(wp) :: nodes(3, 2), l0(1), ea(1)
    REAL(wp) :: Kt(6, 6), fint(6), tension(1)
    INTEGER :: conn(2, 1), es, i, j
    CHARACTER(120) :: em
    nodes = RESHAPE([0.0_wp, 0.0_wp, 0.0_wp, 0.8_wp, 0.0_wp, 0.0_wp], [3, 2])
    conn = RESHAPE([1, 2], [2, 1])
    l0 = [1.0_wp]; ea = [100.0_wp]
    CALL CD_Assemble_Cable_Tangent_Force(nodes, conn, l0, ea, .TRUE., Kt, fint, tension, es, em)
    CALL expect_ok(es, 'clamp:ErrStat')
    CALL expect(tension(1), 0.0_wp, 'clamp:tension')
    DO i = 1, 6
      CALL expect(fint(i), 0.0_wp, 'clamp:fint')
      DO j = 1, 6
        CALL expect(Kt(i, j), 0.0_wp, 'clamp:Kt')
      END DO
    END DO
  END SUBROUTINE case_compression_clamp

  SUBROUTINE case_compression_capable_bar()
    !! Same compressed geometry with tension_only=.FALSE.: negative tension and a
    !! nonzero (EA/L0) material tangent on the axial direction.
    REAL(wp) :: nodes(3, 2), l0(1), ea(1)
    REAL(wp) :: Kt(6, 6), fint(6), tension(1)
    INTEGER :: conn(2, 1), es
    CHARACTER(120) :: em
    nodes = RESHAPE([0.0_wp, 0.0_wp, 0.0_wp, 0.8_wp, 0.0_wp, 0.0_wp], [3, 2])
    conn = RESHAPE([1, 2], [2, 1])
    l0 = [1.0_wp]; ea = [100.0_wp]
    CALL CD_Assemble_Cable_Tangent_Force(nodes, conn, l0, ea, .FALSE., Kt, fint, tension, es, em)
    CALL expect_ok(es, 'bar:ErrStat')
    CALL expect(tension(1), -20.0_wp, 'bar:tension')         ! EA*(0.8-1) = -20
    CALL expect(Kt(1, 1), 100.0_wp, 'bar:Kt11-material')     ! EA/L0 along axis
    CALL expect(fint(1), 20.0_wp, 'bar:fint1')               ! -T t_x = -(-20)(+1)
  END SUBROUTINE case_compression_capable_bar

  SUBROUTINE case_consistent_mass()
    !! One element: m = rho_a*L0; block = m/6 [[2I, I], [I, 2I]].
    REAL(wp) :: l0(1), rho_a(1), M(6, 6)
    INTEGER :: conn(2, 1), es
    CHARACTER(120) :: em
    conn = RESHAPE([1, 2], [2, 1])
    l0 = [2.0_wp]; rho_a = [3.0_wp]                          ! m = 6, coeff = 1
    CALL CD_Assemble_Cable_Mass(conn, l0, rho_a, M, es, em)
    CALL expect_ok(es, 'mass:ErrStat')
    CALL expect(M(1, 1), 2.0_wp, 'mass:M11')                 ! 2*coeff
    CALL expect(M(2, 2), 2.0_wp, 'mass:M22')
    CALL expect(M(1, 4), 1.0_wp, 'mass:M14-coupling')        ! coeff
    CALL expect(M(4, 4), 2.0_wp, 'mass:M44')
    CALL expect(M(1, 2), 0.0_wp, 'mass:M12-zero')            ! no intra-node coupling
  END SUBROUTINE case_consistent_mass

  SUBROUTINE case_reference_parity()
    !! Non-axis-aligned two-element case vs the independent reference values (tight 1e-12).
    REAL(wp) :: nodes(3, 3), l0(2), ea(2), rho_a(2)
    REAL(wp) :: Kt(9, 9), fint(9), tension(2), M(9, 9)
    INTEGER :: conn(2, 2), es, i, j
    CHARACTER(120) :: em
    REAL(wp), PARAMETER :: want_tension(2) = [ &
                           90.516780926679004_wp, 58.736244937667067_wp]
    REAL(wp), PARAMETER :: want_fint(9) = [ &
                           -56.082889652127442_wp, -56.082889652127434_wp, 43.62002528498801_wp, &
                           10.680479988326837_wp, 40.948753097527231_wp, -77.671832532838465_wp, &
                           45.402409663800604_wp, 15.134136554600206_wp, 34.051807247850448_wp]
    REAL(wp), PARAMETER :: want_kt(81) = [ &
                           115.1699613205717_wp, 52.85563948487453_wp, -41.109941821569095_wp, &
                           -115.1699613205717_wp, -52.85563948487453_wp, 41.109941821569095_wp, &
                           0.0_wp, 0.0_wp, 0.0_wp, &
                           52.85563948487453_wp, 115.1699613205717_wp, -41.10994182156908_wp, &
                           -52.85563948487453_wp, -115.1699613205717_wp, 41.10994182156908_wp, &
                           0.0_wp, 0.0_wp, 0.0_wp, &
                           -41.109941821569095_wp, -41.10994182156908_wp, 94.288721030250883_wp, &
                           41.109941821569095_wp, 41.10994182156908_wp, -94.288721030250883_wp, &
                           0.0_wp, 0.0_wp, 0.0_wp, &
                           -115.1699613205717_wp, -52.85563948487453_wp, 41.109941821569095_wp, &
                           229.9833559865076_wp, 78.514990578019678_wp, 16.623598138007466_wp, &
                           -114.8133946659359_wp, -25.659351093145144_wp, -57.733539959576561_wp, &
                           -52.85563948487453_wp, -115.1699613205717_wp, 41.10994182156908_wp, &
                           78.514990578019678_wp, 161.55841973812056_wp, -21.865428501710223_wp, &
                           -25.659351093145144_wp, -46.388458417548875_wp, -19.244513319858857_wp, &
                           41.109941821569095_wp, 41.10994182156908_wp, -94.288721030250883_wp, &
                           16.623598138007466_wp, -21.865428501710223_wp, 175.42421738643378_wp, &
                           -57.733539959576561_wp, -19.244513319858857_wp, -81.135496356182912_wp, &
                           0.0_wp, 0.0_wp, 0.0_wp, &
                           -114.8133946659359_wp, -25.659351093145144_wp, -57.733539959576561_wp, &
                           114.8133946659359_wp, 25.659351093145144_wp, 57.733539959576561_wp, &
                           0.0_wp, 0.0_wp, 0.0_wp, &
                           -25.659351093145144_wp, -46.388458417548875_wp, -19.244513319858857_wp, &
                           25.659351093145144_wp, 46.388458417548875_wp, 19.244513319858857_wp, &
                           0.0_wp, 0.0_wp, 0.0_wp, &
                           -57.733539959576561_wp, -19.244513319858857_wp, -81.135496356182912_wp, &
                           57.733539959576561_wp, 19.244513319858857_wp, 81.135496356182912_wp]
    REAL(wp), PARAMETER :: want_m(81) = [ &
                           1.6666666666666667_wp, 0.0_wp, 0.0_wp, &
                           0.83333333333333337_wp, 0.0_wp, 0.0_wp, &
                           0.0_wp, 0.0_wp, 0.0_wp, &
                           0.0_wp, 1.6666666666666667_wp, 0.0_wp, &
                           0.0_wp, 0.83333333333333337_wp, 0.0_wp, &
                           0.0_wp, 0.0_wp, 0.0_wp, &
                           0.0_wp, 0.0_wp, 1.6666666666666667_wp, &
                           0.0_wp, 0.0_wp, 0.83333333333333337_wp, &
                           0.0_wp, 0.0_wp, 0.0_wp, &
                           0.83333333333333337_wp, 0.0_wp, 0.0_wp, &
                           3.666666666666667_wp, 0.0_wp, 0.0_wp, &
                           1.0_wp, 0.0_wp, 0.0_wp, &
                           0.0_wp, 0.83333333333333337_wp, 0.0_wp, &
                           0.0_wp, 3.666666666666667_wp, 0.0_wp, &
                           0.0_wp, 1.0_wp, 0.0_wp, &
                           0.0_wp, 0.0_wp, 0.83333333333333337_wp, &
                           0.0_wp, 0.0_wp, 3.666666666666667_wp, &
                           0.0_wp, 0.0_wp, 1.0_wp, &
                           0.0_wp, 0.0_wp, 0.0_wp, &
                           1.0_wp, 0.0_wp, 0.0_wp, &
                           2.0_wp, 0.0_wp, 0.0_wp, &
                           0.0_wp, 0.0_wp, 0.0_wp, &
                           0.0_wp, 1.0_wp, 0.0_wp, &
                           0.0_wp, 2.0_wp, 0.0_wp, &
                           0.0_wp, 0.0_wp, 0.0_wp, &
                           0.0_wp, 0.0_wp, 1.0_wp, &
                           0.0_wp, 0.0_wp, 2.0_wp]

    nodes = RESHAPE([0.1_wp, -0.2_wp, 0.3_wp, 1.0_wp, 0.7_wp, -0.4_wp, 2.2_wp, 1.1_wp, 0.5_wp], [3, 3])
    conn = RESHAPE([1, 2, 2, 3], [2, 2])
    l0 = [1.0_wp, 1.2_wp]; ea = [200.0_wp, 200.0_wp]; rho_a = [5.0_wp, 5.0_wp]

    CALL CD_Assemble_Cable_Tangent_Force(nodes, conn, l0, ea, .FALSE., Kt, fint, tension, es, em)
    CALL expect_ok(es, 'reference:tf-ErrStat')
    CALL expect(tension(1), want_tension(1), 'reference:tension1')
    CALL expect(tension(2), want_tension(2), 'reference:tension2')
    DO i = 1, 9
      CALL expect(fint(i), want_fint(i), 'reference:fint')
      DO j = 1, 9
        CALL expect(Kt(i, j), want_kt((i - 1)*9 + j), 'reference:Kt')
      END DO
    END DO
    CALL CD_Assemble_Cable_Mass(conn, l0, rho_a, M, es, em)
    CALL expect_ok(es, 'reference:mass-ErrStat')
    DO i = 1, 9
      DO j = 1, 9
        CALL expect(M(i, j), want_m((i - 1)*9 + j), 'reference:M')
      END DO
    END DO
  END SUBROUTINE case_reference_parity

  SUBROUTINE case_banded_free_matches_dense_free_block()
    !! Direct reduced band assembly must match the dense tangent's free/free
    !! submatrix for a non-contiguous free-DOF list. This is the dynamic Newton
    !! fast path: correctness is about the reduced ordering, not only the element.
    REAL(wp) :: nodes(3, 4), l0(3), ea(3)
    REAL(wp) :: Kt(12, 12), fint(12), fint_band(12), tension(3), tension_band(3)
    REAL(wp), ALLOCATABLE :: Kb(:, :), Kfrom_band(:, :), Kfree(:, :)
    INTEGER :: conn(2, 3), free(8), es, kl, ku, ldab, i, j, row
    CHARACTER(120) :: em

    nodes = RESHAPE([ &
                    0.0_wp, 0.0_wp, 0.0_wp, &
                    1.1_wp, 0.1_wp, -0.2_wp, &
                    2.0_wp, 0.4_wp, -0.1_wp, &
                    3.2_wp, 0.2_wp, 0.3_wp], [3, 4])
    conn = RESHAPE([1, 2, 2, 3, 3, 4], [2, 3])
    l0 = [0.9_wp, 1.0_wp, 1.1_wp]
    ea = [1000.0_wp, 700.0_wp, 1200.0_wp]
    free = [2, 3, 4, 6, 7, 8, 10, 12]

    CALL CD_Assemble_Cable_Tangent_Force(nodes, conn, l0, ea, .FALSE., Kt, fint, tension, es, em)
    CALL expect_ok(es, 'banded-free:dense-ErrStat')
    CALL CD_Cable_Free_Bandwidth(conn, 4, free, kl, ku, es, em)
    CALL expect_ok(es, 'banded-free:bandwidth-ErrStat')
    CALL expect(REAL(kl, wp), 3.0_wp, 'banded-free:kl')
    CALL expect(REAL(ku, wp), 3.0_wp, 'banded-free:ku')

    ldab = 2*kl + ku + 1
    ALLOCATE (Kb(ldab, SIZE(free)), Kfrom_band(SIZE(free), SIZE(free)), Kfree(SIZE(free), SIZE(free)))
    CALL CD_Assemble_Cable_Tangent_Force_Banded_Free(nodes, conn, l0, ea, .FALSE., free, kl, ku, &
                                                     Kb, fint_band, tension_band, es, em)
    CALL expect_ok(es, 'banded-free:assemble-ErrStat')
    Kfrom_band = 0.0_wp
    DO j = 1, SIZE(free)
      DO i = MAX(1, j - ku), MIN(SIZE(free), j + kl)
        row = kl + ku + 1 + i - j
        Kfrom_band(i, j) = Kb(row, j)
      END DO
    END DO
    Kfree = Kt(free, free)
    CALL require(nan_max_abs(Kfrom_band - Kfree) < 1.0e-10_wp, 'banded-free:matches-dense')
    CALL require(nan_max_abs(fint_band - fint) < 1.0e-12_wp, 'banded-free:fint')
    CALL require(nan_max_abs(tension_band - tension) < 1.0e-12_wp, 'banded-free:tension')
  END SUBROUTINE case_banded_free_matches_dense_free_block

  SUBROUTINE case_invalid_topology()
    !! Fail closed on a duplicate undirected edge and on an unused node, matching
    !! the independent reference mesh.
    REAL(wp) :: nodes(3, 3), l0(2), ea(2), fint(9)
    INTEGER :: conn(2, 2), es
    CHARACTER(120) :: em
    nodes = RESHAPE([0.0_wp, 0.0_wp, 0.0_wp, 1.5_wp, 0.0_wp, 0.0_wp, 3.0_wp, 0.0_wp, 0.0_wp], [3, 3])
    l0 = [1.0_wp, 1.0_wp]
    ea = [100.0_wp, 100.0_wp]
    ! duplicate undirected edge (1-2 and 2-1)
    conn = RESHAPE([1, 2, 2, 1], [2, 2])
    CALL CD_Assemble_Cable_Internal_Force(nodes, conn, l0, ea, .TRUE., fint, es, em)
    CALL expect(REAL(es, wp), 1.0_wp, 'invalid:duplicate-edge')
    CALL check_unused_node()
  END SUBROUTINE case_invalid_topology

  SUBROUTINE check_unused_node()
    !! Three nodes, a single element 1-2: node 3 is unreferenced -> fail closed.
    REAL(wp) :: nodes(3, 3), l0(1), ea(1), fint(9)
    INTEGER :: conn(2, 1), es
    CHARACTER(120) :: em
    nodes = RESHAPE([0.0_wp, 0.0_wp, 0.0_wp, 1.5_wp, 0.0_wp, 0.0_wp, 3.0_wp, 0.0_wp, 0.0_wp], [3, 3])
    conn = RESHAPE([1, 2], [2, 1])
    l0 = [1.0_wp]
    ea = [100.0_wp]
    CALL CD_Assemble_Cable_Internal_Force(nodes, conn, l0, ea, .TRUE., fint, es, em)
    CALL expect(REAL(es, wp), 1.0_wp, 'invalid:unused-node')
  END SUBROUTINE check_unused_node

  SUBROUTINE case_element_failure_zeros_outputs()
    !! A mid-loop element failure (element 2 collapsed to zero length) fails closed
    !! AND leaves no partial scatter-added loads in the outputs.
    REAL(wp) :: nodes(3, 3), l0(2), ea(2)
    REAL(wp) :: Kt(9, 9), fint(9), tension(2)
    INTEGER :: conn(2, 2), es
    CHARACTER(120) :: em
    ! nodes 2 and 3 coincide -> element 2 (2-3) has zero current length
    nodes = RESHAPE([0.0_wp, 0.0_wp, 0.0_wp, 1.5_wp, 0.0_wp, 0.0_wp, 1.5_wp, 0.0_wp, 0.0_wp], [3, 3])
    conn = RESHAPE([1, 2, 2, 3], [2, 2])
    l0 = [1.0_wp, 1.0_wp]
    ea = [100.0_wp, 100.0_wp]
    CALL CD_Assemble_Cable_Tangent_Force(nodes, conn, l0, ea, .TRUE., Kt, fint, tension, es, em)
    CALL expect(REAL(es, wp), 1.0_wp, 'elemfail:ErrStat')
    CALL expect(nan_max_abs(fint), 0.0_wp, 'elemfail:fint-zeroed')
    CALL expect(nan_max_abs(Kt), 0.0_wp, 'elemfail:Kt-zeroed')
    CALL expect(nan_max_abs(tension), 0.0_wp, 'elemfail:tension-zeroed')
  END SUBROUTINE case_element_failure_zeros_outputs

  SUBROUTINE case_degenerate_mesh_size()
    !! Fail closed on a mesh with no elements or fewer than two nodes
    !! (as in the independent reference mesh).
    REAL(wp) :: nodes2(3, 2), l0z(0), eaz(0), fint2(6)
    REAL(wp) :: nodes1(3, 1), l01(1), ea1(1), fint1(3)
    INTEGER :: connz(2, 0), conn1(2, 1), es
    CHARACTER(120) :: em
    ! zero elements
    nodes2 = RESHAPE([0.0_wp, 0.0_wp, 0.0_wp, 1.0_wp, 0.0_wp, 0.0_wp], [3, 2])
    CALL CD_Assemble_Cable_Internal_Force(nodes2, connz, l0z, eaz, .TRUE., fint2, es, em)
    CALL expect(REAL(es, wp), 1.0_wp, 'degenerate:zero-elements')
    ! single node (< 2 nodes)
    nodes1 = RESHAPE([0.0_wp, 0.0_wp, 0.0_wp], [3, 1])
    conn1 = RESHAPE([1, 1], [2, 1])
    l01 = [1.0_wp]
    ea1 = [100.0_wp]
    CALL CD_Assemble_Cable_Internal_Force(nodes1, conn1, l01, ea1, .TRUE., fint1, es, em)
    CALL expect(REAL(es, wp), 1.0_wp, 'degenerate:single-node')
  END SUBROUTINE case_degenerate_mesh_size

END PROGRAM test_cable_assemble
