! File: tests/test_l1_seabed.f90
! SPDX-License-Identifier: Apache-2.0
! Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
PROGRAM test_l1_seabed
  !! L1-9 static seabed contact, scored on the Fortran EI=0 static solve against the
  !! analytical normal-load profile. A heavy line resting fully on a horizontal
  !! penalty seabed (held up only by contact; ends pinned in x,y, every z free) must
  !! carry each node's consistent lumped weight as its contact reaction. The
  !! per-node reaction k_n*max(0, z_floor - z) is compared, in a normalised L2 sense,
  !! to the consistent nodal weight (interior nodes w*L0, end nodes w*L0/2 from the
  !! 2-node linear element's lumped distributed load). Mirrors the L1-9 benchmark
  !! (VALIDATION_SPEC.md): the EI=0 cable IS the small-EI limit used to
  !! collapse the beam-on-elastic-foundation boundary layer.
  USE CableDyn_Precision, ONLY: wp
  USE CableDyn_Loads, ONLY: CD_Assemble_Distributed_Load, CD_Seabed_Penalty_Load
  USE CableDyn_Static, ONLY: CableSolverConfig, CD_Static_Cable_Solve, CD_STATIC_OK
  IMPLICIT NONE

  INTEGER, PARAMETER :: NE = 8, NN = NE + 1
  REAL(wp), PARAMETER :: L0E = 0.9_wp, EA = 1.0e3_wp, WPL = 50.0_wp   ! L0 < span -> taut/conditioned
  REAL(wp), PARAMETER :: KN = 1.0e5_wp, ZFLOOR = 0.0_wp
  REAL(wp), PARAMETER :: GATE = 1.0e-3_wp        ! VALIDATION_SPEC L1-9 reaction-profile L2 gate

  INTEGER  :: nfail, conn(2, NE), fixed(4), es, n_iter, i
  REAL(wp) :: l0(NE), ea_arr(NE), load(3, NE), f_ext(3*NN), q0(3*NN), q(3*NN)
  REAL(wp) :: kn_arr(NN), reaction(3*NN), kr(3*NN, 3*NN)
  REAL(wp) :: lumped(NN), diff2, ref2, err, total_r
  LOGICAL  :: converged, stalled, at_floor
  TYPE(CableSolverConfig) :: cfg
  CHARACTER(120) :: em
  nfail = 0

  ! flat line just below the floor so contact is active from the seed
  DO i = 1, NN
    q0(3*i - 2) = REAL(i - 1, wp)      ! x = 0 .. NE
    q0(3*i - 1) = 0.0_wp
    q0(3*i) = -1.0e-3_wp               ! z just below z_floor
  END DO
  DO i = 1, NE
    conn(1, i) = i; conn(2, i) = i + 1
    l0(i) = L0E; ea_arr(i) = EA
    load(:, i) = [0.0_wp, 0.0_wp, -WPL]
  END DO
  CALL CD_Assemble_Distributed_Load(conn, l0, load, f_ext, es, em)
  CALL require(es == 0, 'fext-ErrStat')

  ! pin node 1 and node NN in x,y only; every z free (held by contact)
  fixed = [1, 2, 3*NN - 2, 3*NN - 1]
  kn_arr = KN
  CALL CD_Static_Cable_Solve(q0, conn, l0, ea_arr, .FALSE., f_ext, fixed, cfg, &
                             q, converged, stalled, at_floor, n_iter, es, em, &
                             seabed_z_floor=ZFLOOR, seabed_kn=kn_arr)
  CALL require(es == CD_STATIC_OK, 'solve-ErrStat')
  CALL require(converged, 'converged')

  ! per-node contact reaction on the converged shape
  CALL CD_Seabed_Penalty_Load(RESHAPE(q, [3, NN]), kn_arr, ZFLOOR, reaction, kr, es, em)
  CALL require(es == 0, 'reaction-ErrStat')

  ! analytical consistent nodal weight: end nodes w*L0/2, interior w*L0
  lumped = WPL*L0E
  lumped(1) = 0.5_wp*WPL*L0E
  lumped(NN) = 0.5_wp*WPL*L0E

  diff2 = 0.0_wp; ref2 = 0.0_wp; total_r = 0.0_wp
  DO i = 1, NN
    diff2 = diff2 + (reaction(3*i) - lumped(i))**2
    ref2 = ref2 + lumped(i)**2
    total_r = total_r + reaction(3*i)
  END DO
  err = SQRT(diff2/ref2)
  WRITE (*, '(A,ES12.4,A,F8.2,A,F8.2)') 'L1-9 seabed: reaction-profile L2 = ', err, &
    '  total reaction = ', total_r, '  total weight = ', WPL*L0E*REAL(NE, wp)
  CALL require(err < GATE, 'L1-9:reaction-profile-vs-analytical')
  ! global balance: total reaction == total weight
  CALL require(ABS(total_r - WPL*L0E*REAL(NE, wp))/(WPL*L0E*REAL(NE, wp)) < 1.0e-4_wp, &
               'L1-9:total-reaction-balances-weight')

  IF (nfail > 0) THEN
    WRITE (*, '(A,I0,A)') 'FAIL: ', nfail, ' assertion(s) failed'
    ERROR STOP 1
  END IF
  WRITE (*, '(A)') 'PASS: Fortran EI=0 seabed reaction matches the analytical profile (L1-9)'

CONTAINS

  SUBROUTINE require(cond, label)
    LOGICAL, INTENT(IN) :: cond
    CHARACTER(*), INTENT(IN) :: label
    IF (.NOT. cond) THEN
      WRITE (*, '(A,A,A)') 'MISMATCH [', label, ']: condition false'
      nfail = nfail + 1
    END IF
  END SUBROUTINE require

END PROGRAM test_l1_seabed
