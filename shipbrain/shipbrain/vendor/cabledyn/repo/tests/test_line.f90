! File: tests/test_line.f90
! SPDX-License-Identifier: Apache-2.0
! Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
PROGRAM test_line
  !! Gate for the composite (multi-section) line-object assembly in CableDyn_Line:
  !! per-section concatenation, in-line mesh refinement, endpoint-order invariance,
  !! per-node seabed stiffness, fail-closed inputs, and an end-to-end demonstration
  !! that a multi-line-type slack line solves through the existing EI=0 kernel
  !! (catenary seed -> load continuation), the composite-static case.
  USE CableDyn_Precision, ONLY: wp
  USE CableDyn_Line, ONLY: CD_LineType, CD_LineSection, CD_Build_Line_Mesh, &
                           CD_Nodal_Seabed_Stiffness, CD_LINE_OK, CD_LINE_BADINPUT, CD_LINE_UNSUPPORTED
  USE CableDyn_Loads, ONLY: CD_Submerged_Weight, CD_Assemble_Distributed_Load
  USE CableDyn_Catenary, ONLY: CD_Catenary_Seed, CD_CAT_OK
  USE CableDyn_Static, ONLY: CableSolverConfig, CD_Static_Cable_Solve_Continuation, CD_STATIC_OK
  IMPLICIT NONE

  INTEGER :: nfail
  nfail = 0

  CALL case_concatenation()
  CALL case_single_vs_split()
  CALL case_endpoint_order_invariance()
  CALL case_mesh_refinement()
  CALL case_nodal_seabed_per_section()
  CALL case_fail_closed()
  CALL case_composite_solves()

  IF (nfail > 0) THEN
    WRITE (*, '(A,I0,A)') 'FAIL: ', nfail, ' assertion(s) failed'
    ERROR STOP 1
  END IF
  WRITE (*, '(A)') 'PASS: composite line-object assembly (CableDyn_Line)'

CONTAINS

  INCLUDE 'nan_max_abs.inc'

  SUBROUTINE case_concatenation()
    !! Two sections of different line types concatenate into one element array, in
    !! end_A -> anchor order, with elem_conn = [e, e+1] and per-section blocks.
    TYPE(CD_LineType) :: lts(2)
    TYPE(CD_LineSection) :: secs(2)
    INTEGER, ALLOCATABLE :: conn(:, :)
    REAL(wp), ALLOCATABLE :: l0(:), ea(:), m(:), d(:)
    INTEGER :: es, e
    CHARACTER(160) :: em
    lts(1) = CD_LineType(ea=5.0e6_wp, mass_per_length=50.0_wp, diameter=0.10_wp)
    lts(2) = CD_LineType(ea=8.0e6_wp, mass_per_length=20.0_wp, diameter=0.08_wp)
    secs(1) = CD_LineSection(line_type=1, length=30.0_wp, n_segments=3)   ! 10 m chain elems
    secs(2) = CD_LineSection(line_type=2, length=40.0_wp, n_segments=2)   ! 20 m wire elems
    CALL CD_Build_Line_Mesh(secs, lts, .FALSE., conn, l0, ea, m, d, es, em)
    CALL require(es == CD_LINE_OK, 'concat:ok')
    CALL require(SIZE(l0) == 5, 'concat:n_elem')
    CALL require(ALL(ABS(l0(1:3) - 10.0_wp) < 1.0e-12_wp), 'concat:chain-seglen')
    CALL require(ALL(ABS(l0(4:5) - 20.0_wp) < 1.0e-12_wp), 'concat:wire-seglen')
    CALL require(ALL(ABS(ea(1:3) - 5.0e6_wp) < 1.0e-6_wp), 'concat:chain-ea')
    CALL require(ALL(ABS(ea(4:5) - 8.0e6_wp) < 1.0e-6_wp), 'concat:wire-ea')
    CALL require(ALL(ABS(d(1:3) - 0.10_wp) < 1.0e-12_wp), 'concat:chain-diam')
    CALL require(ALL(ABS(d(4:5) - 0.08_wp) < 1.0e-12_wp), 'concat:wire-diam')
    CALL require(ALL(ABS(m(1:3) - 50.0_wp) < 1.0e-12_wp), 'concat:chain-mass')
    DO e = 1, 5
      CALL require(conn(1, e) == e .AND. conn(2, e) == e + 1, 'concat:conn')
    END DO
  END SUBROUTINE case_concatenation

  SUBROUTINE case_single_vs_split()
    !! One section of N segments == two same-type sections summing to the same
    !! length/segments: bit-for-bit identical element arrays (a uniform split is a
    !! special case of the composite path, no spurious difference).
    TYPE(CD_LineType) :: lts(1)
    TYPE(CD_LineSection) :: one(1), two(2)
    INTEGER, ALLOCATABLE :: c1(:, :), c2(:, :)
    REAL(wp), ALLOCATABLE :: l1(:), e1(:), m1(:), d1(:), l2(:), e2(:), m2(:), d2(:)
    INTEGER :: es
    CHARACTER(160) :: em
    lts(1) = CD_LineType(ea=5.0e6_wp, mass_per_length=50.0_wp, diameter=0.10_wp)
    one(1) = CD_LineSection(line_type=1, length=100.0_wp, n_segments=10)
    two(1) = CD_LineSection(line_type=1, length=40.0_wp, n_segments=4)
    two(2) = CD_LineSection(line_type=1, length=60.0_wp, n_segments=6)
    CALL CD_Build_Line_Mesh(one, lts, .FALSE., c1, l1, e1, m1, d1, es, em)
    CALL require(es == CD_LINE_OK, 'split:one-ok')
    CALL CD_Build_Line_Mesh(two, lts, .FALSE., c2, l2, e2, m2, d2, es, em)
    CALL require(es == CD_LINE_OK, 'split:two-ok')
    CALL require(SIZE(l1) == SIZE(l2) .AND. SIZE(l1) == 10, 'split:same-n')
    CALL require(nan_max_abs(l1 - l2) < 1.0e-12_wp, 'split:same-l0')
    CALL require(nan_max_abs(e1 - e2) < 1.0e-6_wp, 'split:same-ea')
    CALL require(nan_max_abs(d1 - d2) < 1.0e-12_wp, 'split:same-diam')
    CALL require(ALL(c1 == c2), 'split:same-conn')
  END SUBROUTINE case_single_vs_split

  SUBROUTINE case_endpoint_order_invariance()
    !! anchor_is_end_b reverses the per-element arrays: building A->B and flagging
    !! the anchor as end B yields the exact reverse of the forward (anchor = end A)
    !! arrays, so the same physical line meshes identically regardless of which end
    !! the deck calls the anchor.
    TYPE(CD_LineType) :: lts(2)
    TYPE(CD_LineSection) :: secs(2)
    INTEGER, ALLOCATABLE :: cf(:, :), cr(:, :)
    REAL(wp), ALLOCATABLE :: lf(:), ef(:), mf(:), df(:), lr(:), er(:), mr(:), dr(:)
    INTEGER :: es, n
    CHARACTER(160) :: em
    lts(1) = CD_LineType(ea=5.0e6_wp, mass_per_length=50.0_wp, diameter=0.10_wp)
    lts(2) = CD_LineType(ea=8.0e6_wp, mass_per_length=20.0_wp, diameter=0.08_wp)
    secs(1) = CD_LineSection(line_type=1, length=30.0_wp, n_segments=3)
    secs(2) = CD_LineSection(line_type=2, length=40.0_wp, n_segments=2)
    CALL CD_Build_Line_Mesh(secs, lts, .FALSE., cf, lf, ef, mf, df, es, em)
    CALL require(es == CD_LINE_OK, 'order:fwd-ok')
    CALL CD_Build_Line_Mesh(secs, lts, .TRUE., cr, lr, er, mr, dr, es, em)
    CALL require(es == CD_LINE_OK, 'order:rev-ok')
    n = SIZE(lf)
    CALL require(nan_max_abs(lr - lf(n:1:-1)) < 1.0e-12_wp, 'order:l0-reversed')
    CALL require(nan_max_abs(er - ef(n:1:-1)) < 1.0e-6_wp, 'order:ea-reversed')
    CALL require(nan_max_abs(dr - df(n:1:-1)) < 1.0e-12_wp, 'order:diam-reversed')
    CALL require(ALL(cf == cr), 'order:conn-symmetric')   ! topology is order-symmetric
  END SUBROUTINE case_endpoint_order_invariance

  SUBROUTINE case_mesh_refinement()
    !! In-line mesh refinement: the same physical section length at a higher segment
    !! count gives more, shorter elements summing to the same length.
    TYPE(CD_LineType) :: lts(1)
    TYPE(CD_LineSection) :: coarse(1), fine(1)
    INTEGER, ALLOCATABLE :: cc(:, :), cfn(:, :)
    REAL(wp), ALLOCATABLE :: lc(:), ec(:), mc(:), dc(:), lfn(:), efn(:), mfn(:), dfn(:)
    INTEGER :: es
    CHARACTER(160) :: em
    lts(1) = CD_LineType(ea=5.0e6_wp, mass_per_length=50.0_wp, diameter=0.10_wp)
    coarse(1) = CD_LineSection(line_type=1, length=100.0_wp, n_segments=5)
    fine(1) = CD_LineSection(line_type=1, length=100.0_wp, n_segments=50)
    CALL CD_Build_Line_Mesh(coarse, lts, .FALSE., cc, lc, ec, mc, dc, es, em)
    CALL require(es == CD_LINE_OK .AND. SIZE(lc) == 5, 'refine:coarse')
    CALL CD_Build_Line_Mesh(fine, lts, .FALSE., cfn, lfn, efn, mfn, dfn, es, em)
    CALL require(es == CD_LINE_OK .AND. SIZE(lfn) == 50, 'refine:fine')
    CALL require(ABS(lc(1) - 20.0_wp) < 1.0e-12_wp, 'refine:coarse-seglen')
    CALL require(ABS(lfn(1) - 2.0_wp) < 1.0e-12_wp, 'refine:fine-seglen')
    CALL require(ABS(SUM(lc) - SUM(lfn)) < 1.0e-9_wp, 'refine:same-total-length')
  END SUBROUTINE case_mesh_refinement

  SUBROUTINE case_nodal_seabed_per_section()
    !! Per-node seabed stiffness uses each node's tributary contact area, half of each
    !! adjacent element's diameter x segment length: the end nodes carry half of their one
    !! element, the section-interface node half of each side, the stiffnesses sum to
    !! kBot*sum(d*l0), and a uniform line has one interior value with halved ends.
    TYPE(CD_LineType) :: lts(2)
    TYPE(CD_LineSection) :: secs(2), uni(1)
    INTEGER, ALLOCATABLE :: conn(:, :)
    REAL(wp), ALLOCATABLE :: l0(:), ea(:), m(:), d(:), kn(:), lu(:), eu(:), mu(:), du(:), knu(:)
    INTEGER :: es, n_nodes
    CHARACTER(160) :: em
    REAL(wp), PARAMETER :: KB = 1.0e5_wp
    lts(1) = CD_LineType(ea=5.0e6_wp, mass_per_length=50.0_wp, diameter=0.10_wp)
    lts(2) = CD_LineType(ea=8.0e6_wp, mass_per_length=20.0_wp, diameter=0.08_wp)
    secs(1) = CD_LineSection(line_type=1, length=30.0_wp, n_segments=3)   ! 10 m chain
    secs(2) = CD_LineSection(line_type=2, length=40.0_wp, n_segments=2)   ! 20 m wire
    CALL CD_Build_Line_Mesh(secs, lts, .FALSE., conn, l0, ea, m, d, es, em)
    CALL require(es == CD_LINE_OK, 'seabed:build')
    CALL CD_Nodal_Seabed_Stiffness(KB, d, l0, kn, es, em)
    CALL require(es == CD_LINE_OK, 'seabed:kn-ok')
    n_nodes = SIZE(l0) + 1
    CALL require(SIZE(kn) == n_nodes, 'seabed:n-nodes')
    ! end nodes: half of the chain (0.10 x 10) and wire (0.08 x 20) elements
    CALL require(ABS(kn(1) - 0.5_wp*KB*0.10_wp*10.0_wp) < 1.0e-6_wp, 'seabed:anchor-node-chain')
    CALL require(ABS(kn(n_nodes) - 0.5_wp*KB*0.08_wp*20.0_wp) < 1.0e-6_wp, 'seabed:fairlead-node-wire')
    CALL require(ABS(kn(2) - KB*0.10_wp*10.0_wp) < 1.0e-6_wp, 'seabed:interior-chain-node')
    CALL require(ABS(kn(4) - 0.5_wp*KB*(0.10_wp*10.0_wp + 0.08_wp*20.0_wp)) < 1.0e-6_wp, &
                 'seabed:interface-node-tributary')
    CALL require(ABS(SUM(kn) - KB*SUM(d*l0)) < 1.0e-6_wp, 'seabed:total-contact-area')
    CALL require(MAXVAL(kn) - MINVAL(kn) > 1.0_wp, 'seabed:genuinely-per-section')
    ! a uniform line: one interior value, halved ends
    uni(1) = CD_LineSection(line_type=1, length=50.0_wp, n_segments=5)
    CALL CD_Build_Line_Mesh(uni, lts, .FALSE., conn, lu, eu, mu, du, es, em)
    CALL require(es == CD_LINE_OK, 'seabed:uni-build')
    CALL CD_Nodal_Seabed_Stiffness(KB, du, lu, knu, es, em)
    CALL require(es == CD_LINE_OK, 'seabed:uni-kn')
    CALL require(MAXVAL(knu(2:SIZE(knu) - 1)) - MINVAL(knu(2:SIZE(knu) - 1)) < 1.0e-6_wp .AND. &
                 ABS(knu(1) - 0.5_wp*knu(2)) < 1.0e-6_wp .AND. ABS(knu(SIZE(knu)) - 0.5_wp*knu(2)) < 1.0e-6_wp, &
                 'seabed:uniform-interior-halved-ends')
  END SUBROUTINE case_nodal_seabed_per_section

  SUBROUTINE case_fail_closed()
    !! Every invalid line description fails closed with a non-OK ErrStat, and a
    !! finite-EI section is rejected by the EI=0 builder (not silently run).
    TYPE(CD_LineType) :: lts(1), lts_ei(1), lts_bad(1)
    TYPE(CD_LineSection) :: ok1(1), badidx(1), badseg(1), badlen(1)
    INTEGER, ALLOCATABLE :: conn(:, :)
    REAL(wp), ALLOCATABLE :: l0(:), ea(:), m(:), d(:), kn(:)
    TYPE(CD_LineSection), ALLOCATABLE :: empty(:)
    INTEGER :: es
    CHARACTER(160) :: em
    lts(1) = CD_LineType(ea=5.0e6_wp, mass_per_length=50.0_wp, diameter=0.10_wp)
    ok1(1) = CD_LineSection(line_type=1, length=30.0_wp, n_segments=3)
    ! empty section list
    ALLOCATE (empty(0))
    CALL CD_Build_Line_Mesh(empty, lts, .FALSE., conn, l0, ea, m, d, es, em)
    CALL require(es == CD_LINE_BADINPUT, 'fail:empty-sections')
    ! line_type index out of range
    badidx(1) = CD_LineSection(line_type=2, length=30.0_wp, n_segments=3)
    CALL CD_Build_Line_Mesh(badidx, lts, .FALSE., conn, l0, ea, m, d, es, em)
    CALL require(es == CD_LINE_BADINPUT, 'fail:bad-line-type-index')
    ! n_segments < 1
    badseg(1) = CD_LineSection(line_type=1, length=30.0_wp, n_segments=0)
    CALL CD_Build_Line_Mesh(badseg, lts, .FALSE., conn, l0, ea, m, d, es, em)
    CALL require(es == CD_LINE_BADINPUT, 'fail:bad-n-segments')
    ! non-positive length
    badlen(1) = CD_LineSection(line_type=1, length=-5.0_wp, n_segments=3)
    CALL CD_Build_Line_Mesh(badlen, lts, .FALSE., conn, l0, ea, m, d, es, em)
    CALL require(es == CD_LINE_BADINPUT, 'fail:bad-length')
    ! non-physical line type (EA <= 0)
    lts_bad(1) = CD_LineType(ea=0.0_wp, mass_per_length=50.0_wp, diameter=0.10_wp)
    CALL CD_Build_Line_Mesh(ok1, lts_bad, .FALSE., conn, l0, ea, m, d, es, em)
    CALL require(es == CD_LINE_BADINPUT, 'fail:bad-line-type-ea')
    ! finite-EI section unsupported by the EI=0 builder
    lts_ei(1) = CD_LineType(ea=5.0e6_wp, mass_per_length=50.0_wp, diameter=0.10_wp, ei=1.0e3_wp)
    CALL CD_Build_Line_Mesh(ok1, lts_ei, .FALSE., conn, l0, ea, m, d, es, em)
    CALL require(es == CD_LINE_UNSUPPORTED, 'fail:finite-ei-unsupported')
    ! ...but an unreferenced finite-EI type in a shared library must NOT block an
    ! EI=0 line: only the types sections reference are validated.
    BLOCK
      TYPE(CD_LineType) :: lib(2)
      lib(1) = CD_LineType(ea=5.0e6_wp, mass_per_length=50.0_wp, diameter=0.10_wp)        ! EI=0, used
      lib(2) = CD_LineType(ea=5.0e6_wp, mass_per_length=50.0_wp, diameter=0.10_wp, ei=1.0e3_wp) ! finite-EI, unused
      CALL CD_Build_Line_Mesh(ok1, lib, .FALSE., conn, l0, ea, m, d, es, em)
      CALL require(es == CD_LINE_OK, 'fail:unused-finite-ei-type-ok')
    END BLOCK
    ! seabed builder rejects a non-positive kn_base
    lts(1) = CD_LineType(ea=5.0e6_wp, mass_per_length=50.0_wp, diameter=0.10_wp)
    CALL CD_Build_Line_Mesh(ok1, lts, .FALSE., conn, l0, ea, m, d, es, em)
    CALL require(es == CD_LINE_OK, 'fail:seabed-build-ok')
    CALL CD_Nodal_Seabed_Stiffness(-1.0_wp, d, l0, kn, es, em)
    CALL require(es == CD_LINE_BADINPUT, 'fail:bad-kn-base')
  END SUBROUTINE case_fail_closed

  SUBROUTINE case_composite_solves()
    !! End-to-end: a two-line-type slack line (chain + wire, different mesh density)
    !! builds, seeds from the analytical catenary, and converges to the EI=0 grounded
    !! equilibrium through load continuation -- the gold-standard multi-line-type
    !! static initialisation, driven by exactly the single-line kernel.
    TYPE(CD_LineType) :: lts(2)
    TYPE(CD_LineSection) :: secs(2)
    INTEGER, ALLOCATABLE :: conn(:, :)
    REAL(wp), ALLOCATABLE :: l0(:), ea(:), mpl(:), d(:), w(:), kn(:)
    INTEGER :: es, n_elem, n_dof, e, n_iter_total, n_stages
    INTEGER, ALLOCATABLE :: fixed(:)
    REAL(wp), ALLOCATABLE :: q0(:), q(:), f_ext(:), load(:, :)
    REAL(wp) :: anchor(3), fairlead(3), h, gl
    LOGICAL  :: converged, stalled, at_floor
    TYPE(CableSolverConfig) :: cfg
    CHARACTER(160) :: em
    REAL(wp), PARAMETER :: factors(4) = [0.25_wp, 0.5_wp, 0.75_wp, 1.0_wp]
    REAL(wp), PARAMETER :: RHO = 1025.0_wp, G = 9.81_wp, KB = 1.0e5_wp

    ! chain (heavier, coarse mesh) + wire (lighter, finer mesh); total 80 m over ~69 m chord
    lts(1) = CD_LineType(ea=5.0e6_wp, mass_per_length=50.0_wp, diameter=0.10_wp)
    lts(2) = CD_LineType(ea=8.0e6_wp, mass_per_length=20.0_wp, diameter=0.08_wp)
    secs(1) = CD_LineSection(line_type=1, length=40.0_wp, n_segments=8)
    secs(2) = CD_LineSection(line_type=2, length=40.0_wp, n_segments=12)
    CALL CD_Build_Line_Mesh(secs, lts, .FALSE., conn, l0, ea, mpl, d, es, em)
    CALL require(es == CD_LINE_OK, 'solve:build')
    n_elem = SIZE(l0)
    n_dof = 3*(n_elem + 1)
    ALLOCATE (w(n_elem), q0(n_dof), q(n_dof), f_ext(n_dof), load(3, n_elem))

    CALL CD_Submerged_Weight(mpl, d, RHO, G, w, es, em)
    CALL require(es == 0 .AND. ALL(w > 0.0_wp), 'solve:all-heavy')

    anchor = [0.0_wp, 0.0_wp, 0.0_wp]
    fairlead = [60.0_wp, 0.0_wp, 35.0_wp]
    CALL CD_Catenary_Seed(anchor, fairlead, l0, ea, w, q0, h, gl, es, em)
    CALL require(es == CD_CAT_OK, 'solve:seed')
    CALL require(h > 0.0_wp .AND. gl > 0.0_wp .AND. gl < SUM(l0), 'solve:seed-sane')

    DO e = 1, n_elem
      load(:, e) = [0.0_wp, 0.0_wp, -w(e)]
    END DO
    CALL CD_Assemble_Distributed_Load(conn, l0, load, f_ext, es, em)
    CALL require(es == 0, 'solve:load')

    CALL CD_Nodal_Seabed_Stiffness(KB, d, l0, kn, es, em)
    CALL require(es == CD_LINE_OK, 'solve:kn')

    ALLOCATE (fixed(6))
    fixed = [1, 2, 3, n_dof - 2, n_dof - 1, n_dof]
    CALL CD_Static_Cable_Solve_Continuation(q0, conn, l0, ea, .FALSE., f_ext, fixed, cfg, &
                                            factors, q, converged, stalled, at_floor, &
                                            n_iter_total, n_stages, es, em, &
                                            seabed_z_floor=0.0_wp, seabed_kn=kn)
    CALL require(es == CD_STATIC_OK, 'solve:errstat')
    CALL require(converged .AND. .NOT. stalled .AND. n_stages == 4, 'solve:converged')
    ! endpoints honoured, interior touches down toward the seabed, stays above floor
    CALL require(nan_max_abs(q(1:3) - anchor) < 1.0e-9_wp, 'solve:anchor-pinned')
    CALL require(nan_max_abs(q(n_dof - 2:n_dof) - fairlead) < 1.0e-9_wp, 'solve:fairlead-pinned')
    CALL require(MINVAL(q(6:n_dof - 3:3)) > -0.1_wp, 'solve:no-through-seabed')
    CALL require(MINVAL(q(6:n_dof - 3:3)) < 0.01_wp, 'solve:interior-touches-down')
    CALL require(n_iter_total >= n_stages, 'solve:at-least-one-newton-iteration-per-stage')
  END SUBROUTINE case_composite_solves

  SUBROUTINE require(cond, label)
    LOGICAL, INTENT(IN) :: cond
    CHARACTER(*), INTENT(IN) :: label
    IF (.NOT. cond) THEN
      WRITE (*, '(A,A,A)') 'MISMATCH [', label, ']: condition false'
      nfail = nfail + 1
    END IF
  END SUBROUTINE require

END PROGRAM test_line
