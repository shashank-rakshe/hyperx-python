! File: tests/test_l3_orcaflex_static.f90
! SPDX-License-Identifier: Apache-2.0
! Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
PROGRAM test_l3_orcaflex_static
  !! L3-1 static OrcaFlex parity gate for the Fortran production core.
  !!
  !! This test builds the WD0050 grounded chain directly through the Fortran
  !! line-object/static-solver path and scores the endpoint tensions against
  !! an independently generated OrcaFlex reference. It corresponds to the validation
  !! ladder L3-1 ("static catenary vs OrcaFlex") in ARCHITECTURE.md and uses
  !! a frictionless seabed convention.
  !! Reference scalars were generated on 2026-06-18 from OrcFxAPI:
  !!
  !!   fairlead = 998110.8935321609 N
  !!   anchor   = 832242.1912115519 N
  !!   grounded node count = 26
  !!
  !! The scientific model is the grounded extensible catenary under submerged
  !! self-weight with penalty seabed contact. The gate is CableDyn-vs-OrcaFlex
  !! < 2% at both ends; the embedded external quasi-static values provide the
  !! third-leg sanity check (< 3.2%) used by the L3 reference.
  USE CableDyn_Precision, ONLY: wp
  USE CableDyn_Line, ONLY: CD_LineType, CD_LineSection, CD_Build_Line_Mesh, &
                           CD_Nodal_Seabed_Stiffness, CD_LINE_OK
  USE CableDyn_Loads, ONLY: CD_Submerged_Weight, CD_Assemble_Distributed_Load
  USE CableDyn_Catenary, ONLY: CD_Catenary_Seed, CD_CAT_OK
  USE CableDyn_Static, ONLY: CableSolverConfig, CD_Static_Cable_Solve_Continuation, CD_STATIC_OK
  USE CableDyn_Assemble, ONLY: CD_Compute_Cable_Tension
  IMPLICIT NONE

  REAL(wp), PARAMETER :: G = 9.80665_wp, RHO = 1025.0_wp
  REAL(wp), PARAMETER :: CHAIN_EA = 1.674e9_wp, CHAIN_MASS = 390.0_wp, CHAIN_DIAM = 0.252_wp
  REAL(wp), PARAMETER :: WATER_DEPTH = 50.0_wp, TOTAL_LEN = 410.0_wp, ANCHOR_X = 400.0_wp
  REAL(wp), PARAMETER :: KN_BASE = 1.0e5_wp
  REAL(wp), PARAMETER :: ORCAFLEX_FAIRLEAD_N = 998110.8935321609_wp
  REAL(wp), PARAMETER :: ORCAFLEX_ANCHOR_N = 832242.1912115519_wp
  REAL(wp), PARAMETER :: EXT_FAIRLEAD_N = 991.6e3_wp
  REAL(wp), PARAMETER :: EXT_ANCHOR_N = 826.2e3_wp
  REAL(wp), PARAMETER :: L3_RTOL = 0.02_wp, THREE_WAY_RTOL = 0.032_wp
  REAL(wp), PARAMETER :: factors(4) = [0.25_wp, 0.5_wp, 0.75_wp, 1.0_wp]
  INTEGER, PARAMETER :: NE_IN = 41

  TYPE(CD_LineType) :: lts(1)
  TYPE(CD_LineSection) :: secs(1)
  INTEGER, ALLOCATABLE :: conn(:, :), fixed(:)
  REAL(wp), ALLOCATABLE :: l0(:), ea(:), mpl(:), diam(:), w(:), kn(:)
  REAL(wp), ALLOCATABLE :: q0(:), q(:), f_ext(:), load(:, :), tension(:)
  REAL(wp) :: anchor(3), fairlead(3), h, grounded_len
  REAL(wp) :: fairlead_n, anchor_n, fairlead_err, anchor_err, ext_fairlead_err, ext_anchor_err
  INTEGER :: ne, ndof, i, k, es, n_iter, n_stages, nfail
  LOGICAL :: conv, stalled, at_floor
  CHARACTER(200) :: em
  TYPE(CableSolverConfig) :: cfg

  nfail = 0
  anchor = [ANCHOR_X, 0.0_wp, -WATER_DEPTH]
  fairlead = [0.0_wp, 0.0_wp, 0.0_wp]

  lts(1) = CD_LineType(ea=CHAIN_EA, mass_per_length=CHAIN_MASS, diameter=CHAIN_DIAM)
  secs(1) = CD_LineSection(line_type=1, length=TOTAL_LEN, n_segments=NE_IN)
  CALL CD_Build_Line_Mesh(secs, lts, .FALSE., conn, l0, ea, mpl, diam, es, em)
  CALL require(es == CD_LINE_OK, 'build line mesh')
  ne = SIZE(l0)
  ndof = 3*(ne + 1)
  ALLOCATE (w(ne), q0(ndof), q(ndof), f_ext(ndof), load(3, ne), tension(ne))

  CALL CD_Submerged_Weight(mpl, diam, RHO, G, w, es, em)
  CALL require(es == 0 .AND. ALL(w > 0.0_wp), 'submerged self weight')
  DO i = 1, ne
    load(:, i) = [0.0_wp, 0.0_wp, -w(i)]
  END DO
  CALL CD_Assemble_Distributed_Load(conn, l0, load, f_ext, es, em)
  CALL require(es == 0, 'distributed load assembly')

  CALL CD_Catenary_Seed(anchor, fairlead, l0, ea, w, q0, h, grounded_len, es, em)
  CALL require(es == CD_CAT_OK, 'analytical grounded-catenary seed')
  CALL require(grounded_len > 10.0_wp, 'grounded catenary has real touchdown length')

  CALL CD_Nodal_Seabed_Stiffness(KN_BASE, diam, l0, kn, es, em)
  CALL require(es == CD_LINE_OK, 'seabed stiffness')

  ALLOCATE (fixed(6 + (ne - 1)))
  fixed(1:3) = [1, 2, 3]
  fixed(4:6) = [ndof - 2, ndof - 1, ndof]
  k = 6
  DO i = 2, ne
    k = k + 1
    fixed(k) = 3*i - 1
  END DO

  CALL CD_Static_Cable_Solve_Continuation(q0, conn, l0, ea, .FALSE., f_ext, fixed, cfg, factors, &
                                          q, conv, stalled, at_floor, n_iter, n_stages, es, em, &
                                          seabed_z_floor=-WATER_DEPTH, seabed_kn=kn)
  CALL require(es == CD_STATIC_OK, 'static solve errstat')
  CALL require(conv .AND. .NOT. stalled .AND. n_stages == 4, 'static solve convergence')
  ! Check INTERIOR node z only (q(6:ndof-3:3)): the anchor (node 1) is pinned at
  ! z = -WATER_DEPTH, so a MINVAL over all nodes would satisfy this trivially even if
  ! every free node lifted off -- the point is a genuine grounded span past the anchor.
  CALL require(MINVAL(q(6:ndof - 3:3)) <= -WATER_DEPTH + 0.25_wp, 'static solution has touchdown-zone contact')

  CALL CD_Compute_Cable_Tension(RESHAPE(q, [3, ne + 1]), conn, l0, ea, .FALSE., tension, es, em)
  CALL require(es == 0, 'endpoint tension recovery')
  anchor_n = tension(1)
  fairlead_n = tension(ne)
  fairlead_err = ABS(fairlead_n - ORCAFLEX_FAIRLEAD_N)/ORCAFLEX_FAIRLEAD_N
  anchor_err = ABS(anchor_n - ORCAFLEX_ANCHOR_N)/ORCAFLEX_ANCHOR_N
  ext_fairlead_err = ABS(ORCAFLEX_FAIRLEAD_N - EXT_FAIRLEAD_N)/EXT_FAIRLEAD_N
  ext_anchor_err = ABS(ORCAFLEX_ANCHOR_N - EXT_ANCHOR_N)/EXT_ANCHOR_N

  WRITE (*, '(A,F10.3,A,F10.3,A,F7.3,A)') 'L3-1 Fortran vs OrcaFlex fairlead=', &
    fairlead_n*1.0e-3_wp, ' kN ref=', ORCAFLEX_FAIRLEAD_N*1.0e-3_wp, &
    ' kN err=', 100.0_wp*fairlead_err, '%'
  WRITE (*, '(A,F10.3,A,F10.3,A,F7.3,A)') 'L3-1 Fortran vs OrcaFlex anchor  =', &
    anchor_n*1.0e-3_wp, ' kN ref=', ORCAFLEX_ANCHOR_N*1.0e-3_wp, &
    ' kN err=', 100.0_wp*anchor_err, '%'
  WRITE (*, '(A,F7.3,A,F7.3,A)') 'OrcaFlex vs external sanity err: fairlead=', &
    100.0_wp*ext_fairlead_err, '%, anchor=', 100.0_wp*ext_anchor_err, '%'

  CALL require(fairlead_err < L3_RTOL, 'fairlead tension within 2% OrcaFlex L3 gate')
  CALL require(anchor_err < L3_RTOL, 'anchor tension within 2% OrcaFlex L3 gate')
  CALL require(ext_fairlead_err < THREE_WAY_RTOL, 'OrcaFlex fairlead within external three-way band')
  CALL require(ext_anchor_err < THREE_WAY_RTOL, 'OrcaFlex anchor within external three-way band')

  IF (nfail > 0) THEN
    WRITE (*, '(A,I0,A)') 'FAIL: ', nfail, ' assertion(s) failed'
    ERROR STOP 1
  END IF
  WRITE (*, '(A)') 'PASS: L3-1 static OrcaFlex parity on the Fortran production core'

  DEALLOCATE (conn, l0, ea, mpl, diam, w, kn, q0, q, f_ext, load, tension, fixed)

CONTAINS

  SUBROUTINE require(cond, label)
    LOGICAL, INTENT(IN) :: cond
    CHARACTER(*), INTENT(IN) :: label
    IF (.NOT. cond) THEN
      WRITE (*, '(A,A,A)') 'MISMATCH [', TRIM(label), ']: condition false'
      nfail = nfail + 1
    END IF
  END SUBROUTINE require

END PROGRAM test_l3_orcaflex_static
