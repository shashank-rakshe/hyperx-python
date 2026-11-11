! File: tests/test_robust_init.f90
! SPDX-License-Identifier: Apache-2.0
! Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
PROGRAM test_robust_init
  !! Integration gate for geometry-only robust static initialisation: the
  !! analytical catenary seed (CableDyn_Catenary) feeding the load-continuation
  !! solve (CableDyn_Static). Given only endpoints, per-element lengths/EA, and the
  !! signed submerged weight -- no hand-supplied node coordinates -- the seed builds
  !! the starting shape and the continuation drives it to the EI=0 grounded
  !! equilibrium. This is the composition the two robust-init rungs exist for
  !! (catenary guess + load continuation).
  USE CableDyn_Precision, ONLY: wp
  USE CableDyn_Catenary, ONLY: CD_Catenary_Seed, CD_CAT_OK
  USE CableDyn_Static, ONLY: CableSolverConfig, CD_Static_Cable_Solve_Continuation, CD_STATIC_OK
  USE CableDyn_Loads, ONLY: CD_Assemble_Distributed_Load
  IMPLICIT NONE

  INTEGER, PARAMETER :: NE = 16, NN = NE + 1, NDOF = 3*NN
  REAL(wp), PARAMETER :: W_NPM = 80.0_wp        ! signed submerged weight [N/m]
  INTEGER  :: nfail, conn(2, NE), fixed(6), es, n_iter_total, n_stages, i
  REAL(wp) :: anchor(3), fairlead(3), lengths(NE), ea(NE), weight(NE)
  REAL(wp) :: q0(NDOF), q(NDOF), f_ext(NDOF), load(3, NE), kn(NN), h, gl
  LOGICAL  :: converged, stalled, at_floor
  TYPE(CableSolverConfig) :: cfg
  CHARACTER(160) :: em
  REAL(wp), PARAMETER :: factors(4) = [0.25_wp, 0.5_wp, 0.75_wp, 1.0_wp]
  nfail = 0

  ! geometry only: anchor on the seabed (z=0), fairlead up and across; total
  ! reference length > chord so the line is slack and lays part on the seabed.
  anchor = [0.0_wp, 0.0_wp, 0.0_wp]
  fairlead = [60.0_wp, 0.0_wp, 35.0_wp]
  DO i = 1, NE
    conn(:, i) = [i, i + 1]
    lengths(i) = 5.0_wp          ! total 80 m over a ~69 m chord
    ea(i) = 5.0e6_wp
    weight(i) = W_NPM
  END DO

  ! 1) seed from geometry alone
  CALL CD_Catenary_Seed(anchor, fairlead, lengths, ea, weight, q0, h, gl, es, em)
  CALL require(es == CD_CAT_OK, 'seed:ErrStat')
  CALL require(h > 0.0_wp .AND. gl > 0.0_wp .AND. gl < SUM(lengths), 'seed:sane')

  ! 2) matching gravity load + penalty seabed, then continuation from the seed
  DO i = 1, NE
    load(:, i) = [0.0_wp, 0.0_wp, -W_NPM]
  END DO
  CALL CD_Assemble_Distributed_Load(conn, lengths, load, f_ext, es, em)
  CALL require(es == 0, 'load:ErrStat')
  fixed = [1, 2, 3, NDOF - 2, NDOF - 1, NDOF]   ! both endpoints pinned
  kn = 1.0e5_wp
  CALL CD_Static_Cable_Solve_Continuation(q0, conn, lengths, ea, .FALSE., f_ext, fixed, cfg, &
                                          factors, q, converged, stalled, at_floor, &
                                          n_iter_total, n_stages, es, em, &
                                          seabed_z_floor=0.0_wp, seabed_kn=kn)
  CALL require(es == CD_STATIC_OK, 'solve:ErrStat')
  CALL require(converged .AND. .NOT. stalled .AND. n_stages == 4, 'solve:converged-geometry-only')

  ! 3) the converged shape is a valid grounded catenary: endpoints honoured, it
  !    sags onto / toward the seabed, and it stays at or above the floor.
  CALL require(nan_max_abs(q(1:3) - anchor) < 1.0e-9_wp, 'equil:anchor-pinned')
  CALL require(nan_max_abs(q(NDOF - 2:NDOF) - fairlead) < 1.0e-9_wp, 'equil:fairlead-pinned')
  ! penalty seabed: the grounded part rests on z=0 with a small penetration
  ! (~ nodal load / k_n ~ a few mm at k_n = 1e5), so bracket rather than pin to 0.
  ! Check INTERIOR (non-endpoint) node z only: the anchor is pinned at z=0, so a
  ! min over all nodes would pass trivially even if every free node lifted off --
  ! the point of this gate is genuine grounded contact on the free span.
  CALL require(MINVAL(q(6:NDOF - 3:3)) > -0.1_wp, 'equil:no-through-seabed')
  CALL require(MINVAL(q(6:NDOF - 3:3)) < 0.01_wp, 'equil:interior-touches-down')
  ! the seed is a good guess: the continuation refines it, not relocates it
  CALL require(nan_max_abs(q - q0) < 5.0_wp, 'equil:near-seed')

  IF (nfail > 0) THEN
    WRITE (*, '(A,I0,A)') 'FAIL: ', nfail, ' assertion(s) failed'
    ERROR STOP 1
  END IF
  WRITE (*, '(A,I0,A)') 'PASS: geometry-only robust static init (seed + continuation), ', &
    n_iter_total, ' total Newton iters'

CONTAINS

  INCLUDE 'nan_max_abs.inc'

  SUBROUTINE require(cond, label)
    LOGICAL, INTENT(IN) :: cond
    CHARACTER(*), INTENT(IN) :: label
    IF (.NOT. cond) THEN
      WRITE (*, '(A,A,A)') 'MISMATCH [', label, ']: condition false'
      nfail = nfail + 1
    END IF
  END SUBROUTINE require

END PROGRAM test_robust_init
