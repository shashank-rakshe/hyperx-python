! File: tests/test_cable_loads.f90
! SPDX-License-Identifier: Apache-2.0
! Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
PROGRAM test_cable_loads
  !! Unit tests for CableDyn_Loads (submerged weight, distributed-load assembly,
  !! penalty seabed reaction), cross-validated against independently computed values.
  !! Plain CTest program: `error stop 1` on any mismatch.
  USE CableDyn_Precision, ONLY: wp
  USE CableDyn_Loads, ONLY: CD_Submerged_Weight, CD_Assemble_Distributed_Load, &
                            CD_Equivalent_Buoyant_Section, CD_Seabed_Penalty_Load
  USE CableDyn_SeabedContact, ONLY: CD_SEABED_CONTACT_BLEND
  USE, INTRINSIC :: IEEE_ARITHMETIC, ONLY: IEEE_VALUE, IEEE_QUIET_NAN
  IMPLICIT NONE

  INTEGER :: nfail
  nfail = 0

  CALL case_submerged_weight()
  CALL case_equivalent_buoyant_section()
  CALL case_distributed_load()
  CALL case_seabed_penalty()
  CALL case_seabed_penalty_tangent_fd()
  CALL case_seabed_pernode()

  IF (nfail > 0) THEN
    WRITE (*, '(A,I0,A)') 'FAIL: ', nfail, ' assertion(s) failed'
    ERROR STOP 1
  END IF
  WRITE (*, '(A)') 'PASS: CableDyn_Loads matches the independent reference values'

CONTAINS

  INCLUDE 'nan_max_abs.inc'

  SUBROUTINE expect(got, want, label)
    REAL(wp), INTENT(IN) :: got, want
    CHARACTER(*), INTENT(IN) :: label
    REAL(wp), PARAMETER :: atol = 1.0e-9_wp, rtol = 1.0e-12_wp
    IF (.NOT. (ABS(got - want) <= atol + rtol*ABS(want))) THEN
      WRITE (*, '(A,A,A,ES23.15,A,ES23.15)') 'MISMATCH [', label, ']: got ', got, ' want ', want
      nfail = nfail + 1
    END IF
  END SUBROUTINE expect

  SUBROUTINE expect_es(es, want, label)
    INTEGER, INTENT(IN) :: es, want
    CHARACTER(*), INTENT(IN) :: label
    IF (es /= want) THEN
      WRITE (*, '(A,A,A,I0,A,I0)') 'MISMATCH [', label, ']: ErrStat ', es, ' want ', want
      nfail = nfail + 1
    END IF
  END SUBROUTINE expect_es

  SUBROUTINE case_submerged_weight()
    !! reference: w = (mass - rho pi/4 d^2) g. Net-buoyant (w < 0) is allowed
    !! (ErrStat 0); bad diameter / rho fail closed.
    REAL(wp) :: mass(2), dia(2), w(2), wb(1)
    INTEGER :: es
    CHARACTER(120) :: em
    REAL(wp), PARAMETER :: want_w(2) = [3323.2498669189408_wp, 901.71821978441369_wp]
    mass = [390.0_wp, 100.0_wp]
    dia = [0.252_wp, 0.1_wp]
    CALL CD_Submerged_Weight(mass, dia, 1025.0_wp, 9.80665_wp, w, es, em)
    CALL expect_es(es, 0, 'weight:ErrStat')
    CALL expect(w(1), want_w(1), 'weight:w1')
    CALL expect(w(2), want_w(2), 'weight:w2')
    ! net-buoyant element: large diameter, small mass -> w < 0, still ErrStat 0
    CALL CD_Submerged_Weight([1.0_wp], [1.0_wp], 1025.0_wp, 9.80665_wp, wb, es, em)
    CALL expect_es(es, 0, 'weight:buoyant-ErrStat')
    IF (.NOT. (wb(1) < 0.0_wp)) THEN
      WRITE (*, '(A)') 'MISMATCH [weight:buoyant-negative]'
      nfail = nfail + 1
    END IF
    ! fail closed: nonpositive diameter, nonpositive rho
    CALL CD_Submerged_Weight([1.0_wp], [0.0_wp], 1025.0_wp, 9.80665_wp, wb, es, em)
    CALL expect_es(es, 1, 'weight:bad-diameter')
    CALL CD_Submerged_Weight([1.0_wp], [1.0_wp], -1.0_wp, 9.80665_wp, wb, es, em)
    CALL expect_es(es, 1, 'weight:bad-rho')
  END SUBROUTINE case_submerged_weight

  SUBROUTINE case_equivalent_buoyant_section()
    !! Equivalent section helper: solve mass = displaced mass + w_sub/g, then
    !! verify the normal signed-weight routine recovers the target w_sub.
    REAL(wp) :: target_w(3), dia(3), mass(3), recovered_w(3), bad_mass(1)
    INTEGER :: es
    CHARACTER(120) :: em

    target_w = [850.0_wp, -120.0_wp, 0.0_wp]
    dia = [0.18_wp, 0.35_wp, 0.25_wp]
    CALL CD_Equivalent_Buoyant_Section(target_w, dia, 1025.0_wp, 9.80665_wp, mass, es, em)
    CALL expect_es(es, 0, 'equiv-section:ErrStat')
    CALL CD_Submerged_Weight(mass, dia, 1025.0_wp, 9.80665_wp, recovered_w, es, em)
    CALL expect_es(es, 0, 'equiv-section:recovered-weight-status')
    CALL expect(nan_max_abs(recovered_w - target_w), 0.0_wp, 'equiv-section:recovers-target-weight')
    IF (.NOT. (mass(2) > 0.0_wp .AND. recovered_w(2) < 0.0_wp)) THEN
      WRITE (*, '(A)') 'MISMATCH [equiv-section:net-buoyant-positive-mass]'
      nfail = nfail + 1
    END IF

    CALL CD_Equivalent_Buoyant_Section([-1.0e6_wp], [0.1_wp], 1025.0_wp, 9.80665_wp, bad_mass, es, em)
    CALL expect_es(es, 1, 'equiv-section:reject-negative-dry-mass')
    CALL expect(bad_mass(1), 0.0_wp, 'equiv-section:bad-output-zeroed')
  END SUBROUTINE case_equivalent_buoyant_section

  SUBROUTINE case_distributed_load()
    !! reference assemble_cable_distributed_load: each element adds 0.5 L0 load to
    !! both end nodes. Per-element load [0,0,-50] and [1,0,-60] on L0 [1.0,1.2].
    REAL(wp) :: l0(2), load(3, 2), f(9)
    INTEGER :: conn(2, 2), es, i
    CHARACTER(120) :: em
    REAL(wp), PARAMETER :: want_dist(9) = [ &
                           0.0_wp, 0.0_wp, -25.0_wp, &
                           0.59999999999999998_wp, 0.0_wp, -61.0_wp, &
                           0.59999999999999998_wp, 0.0_wp, -36.0_wp]
    conn = RESHAPE([1, 2, 2, 3], [2, 2])
    l0 = [1.0_wp, 1.2_wp]
    load = RESHAPE([0.0_wp, 0.0_wp, -50.0_wp, 1.0_wp, 0.0_wp, -60.0_wp], [3, 2])
    CALL CD_Assemble_Distributed_Load(conn, l0, load, f, es, em)
    CALL expect_es(es, 0, 'dist:ErrStat')
    DO i = 1, 9
      CALL expect(f(i), want_dist(i), 'dist:f')
    END DO
    ! fail closed: out-of-range connectivity
    conn = RESHAPE([1, 2, 2, 4], [2, 2])
    CALL CD_Assemble_Distributed_Load(conn, l0, load, f, es, em)
    CALL expect_es(es, 1, 'dist:out-of-range')
    ! fail closed: nonpositive l0
    conn = RESHAPE([1, 2, 2, 3], [2, 2])
    CALL CD_Assemble_Distributed_Load(conn, [1.0_wp, 0.0_wp], load, f, es, em)
    CALL expect_es(es, 1, 'dist:bad-l0')
  END SUBROUTINE case_distributed_load

  SUBROUTINE case_seabed_penalty()
    !! Per node pen = max(0, z_floor - z); f_z = k_n pen (+z); k_resid (z,z) = k_n
    !! while penetrating. Node 1 above the floor -> no force; nodes 2,3 below.
    REAL(wp) :: nodes(3, 3), f(9), k_resid(9, 9)
    INTEGER :: es, i, j
    CHARACTER(120) :: em
    nodes = RESHAPE([0.0_wp, 0.0_wp, 0.5_wp, 1.0_wp, 0.0_wp, -0.3_wp, 2.0_wp, 0.0_wp, -1.0_wp], [3, 3])
    CALL CD_Seabed_Penalty_Load(nodes, 1000.0_wp, 0.0_wp, f, k_resid, es, em)
    CALL expect_es(es, 0, 'seabed:ErrStat')
    ! forces: only the z DOFs of the two penetrating nodes are non-zero
    CALL expect(f(3), 0.0_wp, 'seabed:node1-z')          ! above the floor
    CALL expect(f(6), 300.0_wp, 'seabed:node2-z')        ! 1000 * 0.3
    CALL expect(f(9), 1000.0_wp, 'seabed:node3-z')       ! 1000 * 1.0
    CALL expect(nan_max_abs(f([1, 2, 4, 5, 7, 8])), 0.0_wp, 'seabed:no-xy-force')
    ! residual Jacobian: +k_n on the penetrating (z,z) diagonals, zero elsewhere
    CALL expect(k_resid(6, 6), 1000.0_wp, 'seabed:kresid-node2')
    CALL expect(k_resid(9, 9), 1000.0_wp, 'seabed:kresid-node3')
    CALL expect(k_resid(3, 3), 0.0_wp, 'seabed:kresid-node1-zero')
    DO i = 1, 9
      DO j = 1, 9
        IF (.NOT. ((i == 6 .AND. j == 6) .OR. (i == 9 .AND. j == 9))) THEN
          CALL expect(k_resid(i, j), 0.0_wp, 'seabed:kresid-offdiag-zero')
        END IF
      END DO
    END DO
    ! on-plane node: the C1 touchdown law returns the midpoint force/tangent of
    ! the micrometre-scale quadratic blend.
    nodes = RESHAPE([0.0_wp, 0.0_wp, 0.0_wp, 1.0_wp, 0.0_wp, 0.5_wp, 2.0_wp, 0.0_wp, -0.2_wp], [3, 3])
    CALL CD_Seabed_Penalty_Load(nodes, 1000.0_wp, 0.0_wp, f, k_resid, es, em)
    CALL expect_es(es, 0, 'seabed:onplane-ErrStat')
    CALL expect(f(3), 250.0_wp*CD_SEABED_CONTACT_BLEND, 'seabed:onplane-force')
    CALL expect(k_resid(3, 3), 500.0_wp, 'seabed:onplane-tangent')
    CALL expect(k_resid(6, 6), 0.0_wp, 'seabed:above-tangent-inactive')   ! node 2 above floor
    CALL expect(f(9), 200.0_wp, 'seabed:below-force')           ! node 3: 1000*0.2
    ! C1 blend zone: at half the blend length, the force and tangent follow
    ! the shared touchdown polynomial.
    nodes(:, 1) = [0.0_wp, 0.0_wp, -0.5_wp*CD_SEABED_CONTACT_BLEND]
    CALL CD_Seabed_Penalty_Load(nodes(:, 1:1), 1000.0_wp, 0.0_wp, f(1:3), k_resid(1:3, 1:3), es, em)
    CALL expect_es(es, 0, 'seabed:blend-ErrStat')
    CALL expect(f(3), 562.5_wp*CD_SEABED_CONTACT_BLEND, 'seabed:blend-force')
    CALL expect(k_resid(3, 3), 750.0_wp, 'seabed:blend-tangent')
    ! fail closed: nonpositive k_n
    CALL CD_Seabed_Penalty_Load(nodes, -1.0_wp, 0.0_wp, f, k_resid, es, em)
    CALL expect_es(es, 1, 'seabed:bad-kn')
    ! fail closed: a non-finite (NaN) node coordinate
    nodes(3, 2) = IEEE_VALUE(1.0_wp, IEEE_QUIET_NAN)
    CALL CD_Seabed_Penalty_Load(nodes, 1000.0_wp, 0.0_wp, f, k_resid, es, em)
    CALL expect_es(es, 1, 'seabed:nan-node')
  END SUBROUTINE case_seabed_penalty

  SUBROUTINE case_seabed_penalty_tangent_fd()
    !! Independent FD gate for the flat penalty contact residual tangent:
    !! k_resid(:,j) = -d f_contact / d q_j for an active penetrating node.
    REAL(wp) :: nodes(3, 1), trial(3, 1), f0(3), fp(3), fm(3), k_resid(3, 3), kbase(3, 3), fd_col(3)
    REAL(wp) :: h
    INTEGER :: es, j
    CHARACTER(120) :: em

    nodes(:, 1) = [1.0_wp, -2.0_wp, -0.25_wp]
    h = 1.0e-6_wp
    CALL CD_Seabed_Penalty_Load(nodes, 4000.0_wp, 0.0_wp, f0, k_resid, es, em)
    CALL expect_es(es, 0, 'seabed-fd:base')
    kbase = k_resid
    CALL expect(f0(3), 1000.0_wp, 'seabed-fd:base-force')
    DO j = 1, 3
      trial = nodes
      trial(j, 1) = trial(j, 1) + h
      CALL CD_Seabed_Penalty_Load(trial, 4000.0_wp, 0.0_wp, fp, k_resid, es, em)
      CALL expect_es(es, 0, 'seabed-fd:plus')
      trial = nodes
      trial(j, 1) = trial(j, 1) - h
      CALL CD_Seabed_Penalty_Load(trial, 4000.0_wp, 0.0_wp, fm, k_resid, es, em)
      CALL expect_es(es, 0, 'seabed-fd:minus')
      fd_col = -(fp - fm)/(2.0_wp*h)
      CALL expect_vec_fd(kbase(:, j), fd_col, 'seabed-fd:kcol')
    END DO
  END SUBROUTINE case_seabed_penalty_tangent_fd

  SUBROUTINE case_seabed_pernode()
    !! Per-node k_n array (the composite-line case): each node gets its own
    !! stiffness, resolved through the generic CD_Seabed_Penalty_Load interface.
    REAL(wp) :: nodes(3, 3), kn(3), f(9), k_resid(9, 9)
    INTEGER :: es
    CHARACTER(120) :: em
    ! node 1 on the floor, node 2 above, node 3 below; distinct per-node stiffness
    nodes = RESHAPE([0.0_wp, 0.0_wp, 0.0_wp, 1.0_wp, 0.0_wp, 0.5_wp, 2.0_wp, 0.0_wp, -0.2_wp], [3, 3])
    kn = [100.0_wp, 200.0_wp, 300.0_wp]
    CALL CD_Seabed_Penalty_Load(nodes, kn, 0.0_wp, f, k_resid, es, em)
    CALL expect_es(es, 0, 'pernode:ErrStat')
    CALL expect(f(3), 25.0_wp*CD_SEABED_CONTACT_BLEND, 'pernode:node1-force')
    CALL expect(k_resid(3, 3), 50.0_wp, 'pernode:node1-tangent')
    CALL expect(k_resid(6, 6), 0.0_wp, 'pernode:node2-inactive') ! above -> inactive
    CALL expect(f(9), 60.0_wp, 'pernode:node3-force')            ! 300 * 0.2
    CALL expect(k_resid(9, 9), 300.0_wp, 'pernode:node3-tangent')! its own k_n
    ! fail closed: wrong-size k_n array
    CALL CD_Seabed_Penalty_Load(nodes, [100.0_wp, 200.0_wp], 0.0_wp, f, k_resid, es, em)
    CALL expect_es(es, 1, 'pernode:bad-size')
  END SUBROUTINE case_seabed_pernode

  SUBROUTINE expect_vec_fd(got, want, label)
    REAL(wp), INTENT(IN) :: got(:), want(:)
    CHARACTER(*), INTENT(IN) :: label
    REAL(wp), PARAMETER :: atol = 2.0e-5_wp, rtol = 1.0e-9_wp
    INTEGER :: i

    DO i = 1, SIZE(got)
      IF (.NOT. (ABS(got(i) - want(i)) <= atol + rtol*ABS(want(i)))) THEN
        WRITE (*, '(A,A,A,ES23.15,A,ES23.15)') 'MISMATCH [', label, ']: got ', got(i), ' want ', want(i)
        nfail = nfail + 1
      END IF
    END DO
  END SUBROUTINE expect_vec_fd

END PROGRAM test_cable_loads
