! File: tests/test_l3_orcaflex_current_static.f90
! SPDX-License-Identifier: Apache-2.0
! Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
PROGRAM test_l3_orcaflex_current_static
  !! L3-3 current-deflected static OrcaFlex parity gate for the Fortran core.
  !!
  !! The WD0050 grounded chain is solved to static equilibrium under a depth-uniform
  !! steady current; the Morison drag deflects the suspended span and shifts both end
  !! tensions. CableDyn's anchor (End A) and fairlead (End B) tensions must match an
  !! independent OrcaFlex static solution of the same chain + current to < 2%, for both
  !! an in-plane current (along the catenary plane, the most sensitive case -- it loads
  !! the suspended span head-on and shifts the anchor tension the most) and a transverse
  !! current (out of plane, a genuine 3D deflection). This mirrors the reference
  !! implementation's L3 current case and validates the new continuation-
  !! ramped current-drag wiring in CableDyn_Static (CableCurrentLoad).
  !!
  !! Reference scalars from an OrcaFlex 11.6c (OrcFxAPI) static run of the same case
  !! (frictionless seabed, CableDyn-matched Cd, depth-uniform current set and read back;
  !! the run script is not part of the repository):
  !!
  !!   in-plane   (dir 180 deg): anchor = 919157.0428368117 N, fairlead = 983637.1251296416 N
  !!   transverse (dir  90 deg): anchor = 852907.6351815211 N, fairlead = 1018861.3930679555 N
  !!
  !! The OrcaFlex reference is the same chain solved by an independent tool with the same
  !! drag coefficients and the frictionless-seabed convention, so the comparison is
  !! like-for-like. CableDyn tracks it to < 1% in practice (gate < 2%).
  USE CableDyn_Precision, ONLY: wp
  USE CableDyn_Line, ONLY: CD_LineType, CD_LineSection, CD_Build_Line_Mesh, &
                           CD_Nodal_Seabed_Stiffness, CD_LINE_OK
  USE CableDyn_Loads, ONLY: CD_Submerged_Weight, CD_Assemble_Distributed_Load
  USE CableDyn_Catenary, ONLY: CD_Catenary_Seed, CD_CAT_OK
  USE CableDyn_Static, ONLY: CableSolverConfig, CableCurrentLoad, &
                             CD_Static_Cable_Solve_Continuation, CD_STATIC_OK
  USE CableDyn_Assemble, ONLY: CD_Compute_Cable_Tension
  IMPLICIT NONE

  REAL(wp), PARAMETER :: G = 9.80665_wp, RHO = 1025.0_wp
  REAL(wp), PARAMETER :: CHAIN_EA = 1.674e9_wp, CHAIN_MASS = 390.0_wp, CHAIN_DIAM = 0.252_wp
  REAL(wp), PARAMETER :: WATER_DEPTH = 50.0_wp, TOTAL_LEN = 410.0_wp, ANCHOR_X = 400.0_wp
  REAL(wp), PARAMETER :: KN_BASE = 1.0e5_wp
  REAL(wp), PARAMETER :: CDN = 1.37_wp, CDT = 0.64_wp, SPEED = 1.0_wp
  REAL(wp), PARAMETER :: L3_RTOL = 0.02_wp
  REAL(wp), PARAMETER :: factors(4) = [0.25_wp, 0.5_wp, 0.75_wp, 1.0_wp]
  INTEGER, PARAMETER :: NE_IN = 41
  ! OrcaFlex reference end tensions (N): (anchor, fairlead) x (in-plane, transverse)
  REAL(wp), PARAMETER :: ORCA_ANCHOR(2) = [919157.0428368117_wp, 852907.6351815211_wp]
  REAL(wp), PARAMETER :: ORCA_FAIRLEAD(2) = [983637.1251296416_wp, 1018861.3930679555_wp]
  CHARACTER(*), PARAMETER :: CASE_LABEL(2) = [CHARACTER(10) :: 'in-plane', 'transverse']

  TYPE(CD_LineType) :: lts(1)
  TYPE(CD_LineSection) :: secs(1)
  INTEGER, ALLOCATABLE :: conn(:, :), fixed(:)
  REAL(wp), ALLOCATABLE :: l0(:), ea(:), mpl(:), diam(:), w(:), kn(:)
  REAL(wp), ALLOCATABLE :: q0(:), q(:), f_ext(:), load(:, :), tension(:)
  REAL(wp) :: anchor(3), fairlead(3), h, grounded_len
  REAL(wp) :: fairlead_n, anchor_n, fairlead_err, anchor_err
  INTEGER :: ne, ndof, i, k, es, n_iter, n_stages, nfail, ic
  LOGICAL :: conv, stalled, at_floor
  CHARACTER(200) :: em
  TYPE(CableSolverConfig) :: cfg
  TYPE(CableCurrentLoad) :: current

  nfail = 0
  anchor = [ANCHOR_X, 0.0_wp, -WATER_DEPTH]
  fairlead = [0.0_wp, 0.0_wp, 0.0_wp]

  ! --- mesh + still-water loads (shared by both current cases) ---
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

  ! Shared current scalars; only the heading (velocity vector) and the in-plane vs 3D
  ! constraint set change between the two cases.
  current%rho = RHO
  current%diameter = CHAIN_DIAM
  current%cdn = CDN
  current%cdt = CDT
  current%waterline_z = 0.0_wp

  DO ic = 1, 2
    IF (ic == 1) THEN
      ! In-plane current along -x: the deflection stays in the x-z catenary plane, so the
      ! interior y DOFs are pinned (the planar solve, matching the L3-1 fixed set).
      current%velocity = [-SPEED, 0.0_wp, 0.0_wp]
      IF (ALLOCATED(fixed)) DEALLOCATE (fixed)
      ALLOCATE (fixed(6 + (ne - 1)))
      fixed(1:3) = [1, 2, 3]
      fixed(4:6) = [ndof - 2, ndof - 1, ndof]
      k = 6
      DO i = 2, ne
        k = k + 1
        fixed(k) = 3*i - 1
      END DO
    ELSE
      ! Transverse current along +y: the suspended span deflects OUT of plane, so the
      ! interior y DOFs must be free (the full 3D solve). Only the endpoints are pinned.
      current%velocity = [0.0_wp, SPEED, 0.0_wp]
      IF (ALLOCATED(fixed)) DEALLOCATE (fixed)
      ALLOCATE (fixed(6))
      fixed(1:3) = [1, 2, 3]
      fixed(4:6) = [ndof - 2, ndof - 1, ndof]
    END IF

    CALL CD_Static_Cable_Solve_Continuation(q0, conn, l0, ea, .FALSE., f_ext, fixed, cfg, factors, &
                                            q, conv, stalled, at_floor, n_iter, n_stages, es, em, &
                                            seabed_z_floor=-WATER_DEPTH, seabed_kn=kn, current=current)
    CALL require(es == CD_STATIC_OK, TRIM(CASE_LABEL(ic))//': static current solve errstat')
    CALL require(conv .AND. .NOT. stalled .AND. n_stages == 4, &
                 TRIM(CASE_LABEL(ic))//': static current solve convergence')
    ! Touchdown beyond the fixed anchor: check INTERIOR node z only (q(6:ndof-3:3)); the
    ! anchor (node 1) is pinned at z = -WATER_DEPTH so a MINVAL over all nodes is trivial.
    CALL require(MINVAL(q(6:ndof - 3:3)) <= -WATER_DEPTH + 0.5_wp, &
                 TRIM(CASE_LABEL(ic))//': current solution still has a grounded span')

    CALL CD_Compute_Cable_Tension(RESHAPE(q, [3, ne + 1]), conn, l0, ea, .FALSE., tension, es, em)
    CALL require(es == 0, TRIM(CASE_LABEL(ic))//': endpoint tension recovery')
    anchor_n = tension(1)
    fairlead_n = tension(ne)
    anchor_err = ABS(anchor_n - ORCA_ANCHOR(ic))/ORCA_ANCHOR(ic)
    fairlead_err = ABS(fairlead_n - ORCA_FAIRLEAD(ic))/ORCA_FAIRLEAD(ic)

    WRITE (*, '(A,A,A,F10.3,A,F10.3,A,F7.3,A)') 'L3-3 ', TRIM(CASE_LABEL(ic)), &
      ' anchor  =', anchor_n*1.0e-3_wp, ' kN ref=', ORCA_ANCHOR(ic)*1.0e-3_wp, &
      ' kN err=', 100.0_wp*anchor_err, '%'
    WRITE (*, '(A,A,A,F10.3,A,F10.3,A,F7.3,A)') 'L3-3 ', TRIM(CASE_LABEL(ic)), &
      ' fairlead=', fairlead_n*1.0e-3_wp, ' kN ref=', ORCA_FAIRLEAD(ic)*1.0e-3_wp, &
      ' kN err=', 100.0_wp*fairlead_err, '%'

    CALL require(anchor_err < L3_RTOL, TRIM(CASE_LABEL(ic))//': anchor tension within 2% OrcaFlex gate')
    CALL require(fairlead_err < L3_RTOL, TRIM(CASE_LABEL(ic))//': fairlead tension within 2% OrcaFlex gate')
  END DO

  IF (nfail > 0) THEN
    WRITE (*, '(A,I0,A)') 'FAIL: ', nfail, ' assertion(s) failed'
    ERROR STOP 1
  END IF
  WRITE (*, '(A)') 'PASS: L3-3 current-deflected static OrcaFlex parity on the Fortran core'

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

END PROGRAM test_l3_orcaflex_current_static
