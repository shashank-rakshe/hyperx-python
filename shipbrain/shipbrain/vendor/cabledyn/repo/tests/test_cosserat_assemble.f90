! File: tests/test_cosserat_assemble.f90
! SPDX-License-Identifier: Apache-2.0
! Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
PROGRAM test_cosserat_assemble
  !! reference-parity check for the finite-EI 6-DOF global assembly
  !! (CD_Assemble_Cosserat_Tangent_Force) against independently computed
  !! values. A 2-element straight cantilever along
  !! +z (3 nodes, EA=1e3, GAs=5e2, EI=2e2, GJ=1.5e2, reduced_shear) is bent into a
  !! deformed state; the assembled global fint (18) is checked against the reference
  !! reference vector, the global Kt diagonal / Frobenius / sum against the
  !! reference, the internal-force-only path against the tangent path, and Kt
  !! symmetry. Also checks the undeformed state assembles zero internal force.
  USE CableDyn_Precision, ONLY: wp
  USE CableDyn_CosseratAssemble, ONLY: CD_Assemble_Cosserat_Tangent_Force, &
                                       CD_Assemble_Cosserat_Tangent_Force_Banded_Free, &
                                       CD_Assemble_Cosserat_Internal_Force, &
                                       CD_Cosserat_Free_Bandwidth, &
                                       CD_Assemble_Cosserat_Internal_Force_Workspace, &
                                       CD_CosseratAssemblyWorkspace, CD_Reset_Cosserat_Asm_Counts
  IMPLICIT NONE

  REAL(wp), PARAMETER :: EA = 1.0e3_wp, GAS = 5.0e2_wp, EI = 2.0e2_wp, GJ = 1.5e2_wp
  REAL(wp), PARAMETER :: FTOL = 1.0e-6_wp, RTOL = 1.0e-8_wp, STOL = 1.0e-9_wp
  INTEGER, PARAMETER :: NN = 3, NE = 2, NDOF = 6*NN
  INTEGER :: nfail, conn(2, NE), es, i, j, row, kl, ku, ldab
  INTEGER, ALLOCATABLE :: free(:)
  INTEGER :: bad_conn(2, NE)
  REAL(wp) :: nodes_ref(3, NN), bad_nodes(3, NN), bad_q(NDOF), ea_a(NE), gas_a(NE), ei_a(NE), gj_a(NE)
  REAL(wp) :: q(NDOF), q_plus(NDOF), q_minus(NDOF), dq(NDOF), Kt(NDOF, NDOF), fint(NDOF), fint2(NDOF)
  REAL(wp) :: fplus(NDOF), fminus(NDOF), ffd(NDOF), fref(NDOF), kd(NDOF), frob, ksum, h
  REAL(wp), ALLOCATABLE :: Kb(:, :), Kfree(:, :), Kfrom_band(:, :)
  CHARACTER(120) :: em
  TYPE(CD_CosseratAssemblyWorkspace) :: asm_work
  nfail = 0

  nodes_ref(:, 1) = [0.0_wp, 0.0_wp, 0.0_wp]
  nodes_ref(:, 2) = [0.0_wp, 0.0_wp, 0.5_wp]
  nodes_ref(:, 3) = [0.0_wp, 0.0_wp, 1.0_wp]
  conn(:, 1) = [1, 2]; conn(:, 2) = [2, 3]
  ea_a = EA; gas_a = GAS; ei_a = EI; gj_a = GJ

  ! deformed state: clamp node1 at ref, bend the free end in x with twist about x
  q = 0.0_wp
  q(1:3) = nodes_ref(:, 1)
  q(7:9) = nodes_ref(:, 2)
  q(13:15) = nodes_ref(:, 3)
  q(7) = 0.02_wp; q(10) = 0.04_wp        ! node2 x + theta_x
  q(13) = 0.08_wp; q(16) = 0.08_wp       ! node3 x + theta_x

  CALL CD_Assemble_Cosserat_Tangent_Force(nodes_ref, conn, ea_a, gas_a, ei_a, gj_a, q, .TRUE., &
                                          Kt, fint, es, em)
  CALL require(es == 0, 'assemble-ErrStat')

  fref = [-20.0_wp, -10.005331591297342_wp, 0.06654816795240467_wp, &
          -13.499777931833336_wp, -5.000333218523869_wp, -0.05000944352348731_wp, &
          -40.0_wp, -20.042586428148503_wp, -0.002344557897971028_wp, &
          10.005326616846421_wp, -20.01265503063188_wp, -0.5004186630487837_wp, &
          60.0_wp, 30.047918019445845_wp, -0.06420361005443365_wp, &
          23.521076120358508_wp, -15.030943897092774_wp, -0.45137023066335197_wp]
  CALL require(nan_max_abs(fint - fref) < FTOL, 'fint-vs-reference')

  ! Kt diagonal / Frobenius / sum vs reference
  DO i = 1, NDOF
    kd(i) = Kt(i, i)
  END DO
  frob = SQRT(SUM(Kt*Kt))
  ksum = SUM(Kt)
  CALL require(ABS(frob - 8117.1292882873095_wp) < RTOL*8117.1292882873095_wp, 'Kt-frobenius-vs-reference')
  CALL require(ABS(ksum - 962.6574571492525_wp) < RTOL*ABS(962.6574571492525_wp), 'Kt-sum-vs-reference')
  CALL require(ABS(kd(1) - 1000.0_wp) < FTOL .AND. ABS(kd(9) - 3995.4731925346578_wp) < FTOL .AND. &
               ABS(kd(15) - 1996.1395807237839_wp) < FTOL, 'Kt-diag-spotcheck-vs-reference')

  ! internal-force-only path matches the tangent path
  CALL CD_Assemble_Cosserat_Internal_Force(nodes_ref, conn, ea_a, gas_a, ei_a, gj_a, q, .TRUE., &
                                           fint2, es, em)
  CALL require(es == 0 .AND. nan_max_abs(fint2 - fint) < 1.0e-12_wp, 'internal-force-only-consistent')

  ! Kt symmetry
  CALL require(nan_max_abs(Kt - TRANSPOSE(Kt)) < STOL, 'Kt-symmetric')

  ! The assembled tangent is the derivative of the assembled internal force.
  ! This catches sign/transpose mistakes that reference-value spot checks can miss.
  h = 1.0e-6_wp
  dq = 0.0_wp
  dq(7) = 0.31_wp
  dq(8) = -0.17_wp
  dq(10) = 0.11_wp
  dq(11) = -0.07_wp
  dq(13) = -0.23_wp
  dq(15) = 0.19_wp
  dq(16) = -0.13_wp
  dq(18) = 0.05_wp
  q_plus = q + h*dq
  q_minus = q - h*dq
  CALL CD_Assemble_Cosserat_Internal_Force(nodes_ref, conn, ea_a, gas_a, ei_a, gj_a, q_plus, .TRUE., &
                                           fplus, es, em)
  CALL require(es == 0, 'tangent-fd:plus-force')
  CALL CD_Assemble_Cosserat_Internal_Force(nodes_ref, conn, ea_a, gas_a, ei_a, gj_a, q_minus, .TRUE., &
                                           fminus, es, em)
  CALL require(es == 0, 'tangent-fd:minus-force')
  ffd = (fplus - fminus)/(2.0_wp*h)
  CALL require(nan_max_abs(ffd - MATMUL(Kt, dq)) < 5.0e-6_wp, 'tangent-fd:directional-derivative')

  ! Direct DGBSV-band assembly of a reduced free block matches the dense
  ! assembler's free/free submatrix exactly enough for Newton solves.
  ALLOCATE (free(12))
  free = [7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18]
  CALL CD_Cosserat_Free_Bandwidth(conn, NN, free, kl, ku, es, em)
  CALL require(es == 0 .AND. kl == 11 .AND. ku == 11, 'banded-free:bandwidth')
  ldab = 2*kl + ku + 1
  ALLOCATE (Kb(ldab, SIZE(free)), Kfree(SIZE(free), SIZE(free)), Kfrom_band(SIZE(free), SIZE(free)))
  CALL CD_Assemble_Cosserat_Tangent_Force_Banded_Free(nodes_ref, conn, ea_a, gas_a, ei_a, gj_a, q, &
                                                      .TRUE., free, kl, ku, Kb, fint2, es, em)
  CALL require(es == 0, 'banded-free:assemble-ErrStat')
  Kfree = Kt(free, free)
  Kfrom_band = 0.0_wp
  DO j = 1, SIZE(free)
    DO i = MAX(1, j - ku), MIN(SIZE(free), j + kl)
      row = kl + ku + 1 + i - j
      Kfrom_band(i, j) = Kb(row, j)
    END DO
  END DO
  CALL require(nan_max_abs(Kfrom_band - Kfree) < 1.0e-10_wp, 'banded-free:matches-dense-free-block')
  CALL require(nan_max_abs(fint2 - fint) < 1.0e-12_wp, 'banded-free:fint-matches-dense')

  ! undeformed reference -> zero internal force
  q = 0.0_wp
  q(1:3) = nodes_ref(:, 1); q(7:9) = nodes_ref(:, 2); q(13:15) = nodes_ref(:, 3)
  CALL CD_Assemble_Cosserat_Internal_Force(nodes_ref, conn, ea_a, gas_a, ei_a, gj_a, q, .TRUE., &
                                           fint2, es, em)
  CALL require(es == 0 .AND. nan_max_abs(fint2) < 1.0e-9_wp, 'undeformed-zero-force')

  ! Force-only assembly must remain a true residual-only path: it should not
  ! increment the tangent assembly counter or route through the Hessian path.
  CALL CD_Reset_Cosserat_Asm_Counts(asm_work)
  CALL CD_Assemble_Cosserat_Internal_Force_Workspace(nodes_ref, conn, ea_a, gas_a, ei_a, gj_a, q, .TRUE., &
                                                     asm_work, fint2, es, em)
  CALL require(es == 0 .AND. asm_work%n_force == 1 .AND. asm_work%n_tangent == 0, &
               'force-only-does-not-touch-tangent-counter')

  ! === fail-closed connectivity / property validation (mirrors the reference mesh
  !     __post_init__ + assembler validation: out-of-range / degenerate /
  !     duplicate-edge elements, collapsed reference spans, and non-positive
  !     properties are rejected, not silently assembled) ===
  bad_conn = conn; bad_conn(2, 2) = 9                       ! node index 9 > n_nodes
  CALL assemble_expect_fail(nodes_ref, bad_conn, ea_a, gas_a, ei_a, gj_a, q, 'reject:node-index-out-of-range')
  bad_conn = conn; bad_conn(:, 2) = [2, 2]                  ! degenerate element (a == b)
  CALL assemble_expect_fail(nodes_ref, bad_conn, ea_a, gas_a, ei_a, gj_a, q, 'reject:degenerate-element')
  bad_conn = conn; bad_conn(:, 2) = [2, 1]                  ! duplicate undirected edge {1,2}
  CALL assemble_expect_fail(nodes_ref, bad_conn, ea_a, gas_a, ei_a, gj_a, q, 'reject:duplicate-undirected-edge')
  bad_nodes = nodes_ref; bad_nodes(:, 2) = nodes_ref(:, 1)  ! collapse node 2 onto node 1 -> L0 = 0
  CALL assemble_expect_fail(bad_nodes, conn, ea_a, gas_a, ei_a, gj_a, q, 'reject:zero-length-reference-span')
  CALL assemble_expect_fail(nodes_ref, conn, [EA, -1.0_wp], gas_a, ei_a, gj_a, q, 'reject:non-positive-EA')
  ! mid-loop element failure: node 3 rotation out of chart (|theta| > pi) makes
  ! element 2 fail AFTER element 1 has been scatter-added -- the assembler must
  ! zero the partial accumulation, not leak it past ErrStat /= 0.
  bad_q = q; bad_q(16) = 3.5_wp                             ! node-3 theta_x > pi
  CALL assemble_expect_fail(nodes_ref, conn, ea_a, gas_a, ei_a, gj_a, bad_q, 'reject:mid-loop-failure-clears-assembly')

  IF (nfail > 0) THEN
    WRITE (*, '(A,I0,A)') 'FAIL: ', nfail, ' assertion(s) failed'
    ERROR STOP 1
  END IF
  WRITE (*, '(A)') 'PASS: Fortran Cosserat global assembly matches the independent reference values'

CONTAINS

  INCLUDE 'nan_max_abs.inc'

  SUBROUTINE assemble_expect_fail(nref_in, conn_in, ea_in, gas_in, ei_in, gj_in, q_in, label)
    !! The tangent assembler must fail closed (ErrStat /= 0) on invalid topology,
    !! geometry, or properties, with zeroed outputs.
    REAL(wp), INTENT(IN) :: nref_in(:, :)
    INTEGER, INTENT(IN) :: conn_in(:, :)
    REAL(wp), INTENT(IN) :: ea_in(:), gas_in(:), ei_in(:), gj_in(:), q_in(:)
    CHARACTER(*), INTENT(IN) :: label
    REAL(wp) :: Kt_l(NDOF, NDOF), fint_l(NDOF)
    INTEGER :: es_l
    CHARACTER(120) :: em_l
    CALL CD_Assemble_Cosserat_Tangent_Force(nref_in, conn_in, ea_in, gas_in, ei_in, gj_in, q_in, &
                                            .TRUE., Kt_l, fint_l, es_l, em_l)
    CALL require(es_l /= 0 .AND. nan_max_abs(fint_l) < 1.0e-300_wp .AND. &
                 nan_max_abs(Kt_l) < 1.0e-300_wp, label)
  END SUBROUTINE assemble_expect_fail

  SUBROUTINE require(cond, label)
    LOGICAL, INTENT(IN) :: cond
    CHARACTER(*), INTENT(IN) :: label
    IF (.NOT. cond) THEN
      WRITE (*, '(A,A,A)') 'MISMATCH [', label, ']: condition false'
      nfail = nfail + 1
    END IF
  END SUBROUTINE require

END PROGRAM test_cosserat_assemble
