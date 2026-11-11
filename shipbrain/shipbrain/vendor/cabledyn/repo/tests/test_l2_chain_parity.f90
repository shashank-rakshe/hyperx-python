! File: tests/test_l2_chain_parity.f90
! SPDX-License-Identifier: Apache-2.0
! Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
PROGRAM test_l2_chain_parity
  !! L2-1 static external-reference chain parity on the Fortran core. For each of the three
  !! grounded-chain rigs (WD0050 / WD0200 / WD0600) build the line through the
  !! line-object assembler (CableDyn_Line), seed it from the analytical catenary
  !! (CableDyn_Catenary), and solve to the grounded EI=0 equilibrium by load
  !! continuation (CableDyn_Static). Score the fairlead (top) and anchor (bottom)
  !! tensions against the MoorDyn-C quasi-static reference values (inlined constants). The
  !! observed differences are 0.13-1.59 % (the largest at the WD0050 anchor); the gate is a
  !! 3 % band, about twice the largest. The rig is independent -- CableDyn builds its own
  !! analytical-catenary seed, and no external solver state enters the initialisation.
  !!
  !! Boundary conditions are a planar solve: BOTH endpoints pinned
  !! (anchor + fairlead, 6 DOFs) AND all interior y-DOFs pinned. The latter is
  !! required, not cosmetic: a long grounded run is slack (tension ~ 0) so the
  !! out-of-plane geometric stiffness ~ T/L0 vanishes there, and a free interior y
  !! would leave the tangent singular. The physics stays in the x-z plane, so pinning
  !! y costs nothing.
  USE CableDyn_Precision, ONLY: wp
  USE CableDyn_Line, ONLY: CD_LineType, CD_LineSection, CD_Build_Line_Mesh, &
                           CD_Nodal_Seabed_Stiffness, CD_LINE_OK
  USE CableDyn_Loads, ONLY: CD_Submerged_Weight, CD_Assemble_Distributed_Load
  USE CableDyn_Catenary, ONLY: CD_Catenary_Seed, CD_CAT_OK
  USE CableDyn_Static, ONLY: CableSolverConfig, CD_Static_Cable_Solve_Continuation, CD_STATIC_OK
  USE CableDyn_Assemble, ONLY: CD_Compute_Cable_Tension
  IMPLICIT NONE

  ! environment and the parity gate
  REAL(wp), PARAMETER :: G = 9.80665_wp, RHO = 1025.0_wp, RTOL = 0.03_wp
  ! chain line type of the WD rigs: EA, dry mass/len, diameter
  REAL(wp), PARAMETER :: CHAIN_EA = 1.674e9_wp, CHAIN_MASS = 390.0_wp, CHAIN_DIAM = 0.252_wp
  ! seabed: per-area penalty k_bot = 1e5 -> per-node k_n = k_bot * diameter * seg_len
  REAL(wp), PARAMETER :: KN_BASE = 1.0e5_wp
  REAL(wp), PARAMETER :: factors(4) = [0.25_wp, 0.5_wp, 0.75_wp, 1.0_wp]
  INTEGER :: nfail
  nfail = 0

  !          name      anchor x   depth   total L   n_elem  ref_fairlead_kN  ref_anchor_kN
  CALL one('WD0050', 400.0_wp, 50.0_wp, 410.0_wp, 41, 991.6_wp, 826.2_wp)
  CALL one('WD0200', 700.0_wp, 200.0_wp, 760.0_wp, 76, 2065.4_wp, 1402.2_wp)
  CALL one('WD0600', 1500.0_wp, 600.0_wp, 1700.0_wp, 170, 5232.6_wp, 3244.2_wp)

  IF (nfail > 0) THEN
    WRITE (*, '(A,I0,A)') 'FAIL: ', nfail, ' assertion(s) failed'
    ERROR STOP 1
  END IF
  WRITE (*, '(A)') 'PASS: L2-1 static external chain parity (WD0050/0200/0600) within the 3% gate'

CONTAINS

  SUBROUTINE one(name, anchor_x, depth, total_len, ne_in, ref_fairlead_kn, ref_anchor_kn)
    CHARACTER(*), INTENT(IN) :: name
    REAL(wp), INTENT(IN) :: anchor_x, depth, total_len, ref_fairlead_kn, ref_anchor_kn
    INTEGER, INTENT(IN) :: ne_in
    TYPE(CD_LineType) :: lts(1)
    TYPE(CD_LineSection) :: secs(1)
    INTEGER, ALLOCATABLE :: conn(:, :), fixed(:)
    REAL(wp), ALLOCATABLE :: l0(:), ea(:), mpl(:), diam(:), w(:), kn(:)
    REAL(wp), ALLOCATABLE :: q0(:), q(:), f_ext(:), load(:, :), tension(:)
    REAL(wp) :: anchor(3), fairlead(3), h, gl, fl_kn, an_kn, fl_err, an_err
    INTEGER  :: ne, ndof, i, k, es, n_iter, n_stages
    LOGICAL  :: conv, st, af
    CHARACTER(200) :: em
    TYPE(CableSolverConfig) :: cfg

    ! geometry: anchor at depth on the seabed plane, fairlead at the surface origin
    anchor = [anchor_x, 0.0_wp, -depth]
    fairlead = [0.0_wp, 0.0_wp, 0.0_wp]

    ! one chain section meshed into ne_in segments
    lts(1) = CD_LineType(ea=CHAIN_EA, mass_per_length=CHAIN_MASS, diameter=CHAIN_DIAM)
    secs(1) = CD_LineSection(line_type=1, length=total_len, n_segments=ne_in)
    CALL CD_Build_Line_Mesh(secs, lts, .FALSE., conn, l0, ea, mpl, diam, es, em)
    CALL require(es == CD_LINE_OK, name//':build')
    ne = SIZE(l0)
    ndof = 3*(ne + 1)
    ALLOCATE (w(ne), q0(ndof), q(ndof), f_ext(ndof), load(3, ne), tension(ne))

    ! submerged self-weight -> consistent nodal load
    CALL CD_Submerged_Weight(mpl, diam, RHO, G, w, es, em)
    CALL require(es == 0 .AND. ALL(w > 0.0_wp), name//':submerged-weight')
    DO i = 1, ne
      load(:, i) = [0.0_wp, 0.0_wp, -w(i)]
    END DO
    CALL CD_Assemble_Distributed_Load(conn, l0, load, f_ext, es, em)
    CALL require(es == 0, name//':load')

    ! analytical grounded-catenary seed (independent of external solver state)
    CALL CD_Catenary_Seed(anchor, fairlead, l0, ea, w, q0, h, gl, es, em)
    CALL require(es == CD_CAT_OK, name//':seed')

    ! per-node tributary seabed penalty
    CALL CD_Nodal_Seabed_Stiffness(KN_BASE, diam, l0, kn, es, em)
    CALL require(es == CD_LINE_OK, name//':seabed-stiffness')

    ! fixed DOFs: both endpoints (xyz) + all interior y (planar solve)
    ALLOCATE (fixed(6 + (ne - 1)))
    fixed(1:3) = [1, 2, 3]
    fixed(4:6) = [ndof - 2, ndof - 1, ndof]
    k = 6
    DO i = 2, ne                         ! interior node i: y-DOF index 3*i-1
      k = k + 1
      fixed(k) = 3*i - 1
    END DO

    CALL CD_Static_Cable_Solve_Continuation(q0, conn, l0, ea, .FALSE., f_ext, fixed, cfg, factors, &
                                            q, conv, st, af, n_iter, n_stages, es, em, &
                                            seabed_z_floor=-depth, seabed_kn=kn)
    CALL require(es == CD_STATIC_OK, name//':solve-errstat')
    CALL require(conv .AND. .NOT. st .AND. n_stages == 4, name//':converged')

    ! per-element tension; fairlead = last element, anchor = first element (kN)
    CALL CD_Compute_Cable_Tension(RESHAPE(q, [3, ne + 1]), conn, l0, ea, .FALSE., tension, es, em)
    CALL require(es == 0, name//':tension')
    fl_kn = tension(ne)*1.0e-3_wp
    an_kn = tension(1)*1.0e-3_wp
    fl_err = ABS(fl_kn - ref_fairlead_kn)/ref_fairlead_kn
    an_err = ABS(an_kn - ref_anchor_kn)/ref_anchor_kn
    WRITE (*, '(A,A,F10.2,A,F8.2,A,F6.3,A,F10.2,A,F8.2,A,F6.3,A)') name, &
      '  fairlead=', fl_kn, ' kN (ref ', ref_fairlead_kn, ', err ', 100.0_wp*fl_err, '%)  anchor=', &
      an_kn, ' kN (ref ', ref_anchor_kn, ', err ', 100.0_wp*an_err, '%)'
    CALL require(fl_err < RTOL, name//':fairlead-within-10pct')
    CALL require(an_err < RTOL, name//':anchor-within-10pct')

    DEALLOCATE (conn, l0, ea, mpl, diam, w, kn, q0, q, f_ext, load, tension, fixed)
  END SUBROUTINE one

  SUBROUTINE require(cond, label)
    LOGICAL, INTENT(IN) :: cond
    CHARACTER(*), INTENT(IN) :: label
    IF (.NOT. cond) THEN
      WRITE (*, '(A,A,A)') 'MISMATCH [', label, ']: condition false'
      nfail = nfail + 1
    END IF
  END SUBROUTINE require

END PROGRAM test_l2_chain_parity
