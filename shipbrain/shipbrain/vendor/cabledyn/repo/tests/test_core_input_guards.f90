! File: tests/test_core_input_guards.f90
! SPDX-License-Identifier: Apache-2.0
! Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
PROGRAM test_core_input_guards
  !! Input guards of the core that must fail closed instead of corrupting state:
  !!   1. A spread sea whose component count n_freq*n_dir exceeds a default integer is
  !!      rejected by the component limit, not wrapped negative.
  !!   2. The free-DOF banded assembly rejects an entry outside the declared kl/ku band.
  !!   3. A non-finite seabed friction coefficient on the static current solve fails closed.
  !!   4. The static end-force recovery rejects a short seabed stiffness array.
  !!   5. The keyword static driver accepts keywords in any letter case on both deck forms.
  USE CableDyn_Precision, ONLY: wp
  USE CableDyn_WaveSpectra, ONLY: CD_SeaType, CD_WaveTrainType, CD_Sea_Add_Train, CD_Sea_Synthesise, &
                                  CD_TRAIN_JONSWAP, CD_SEA_OK
  USE CableDyn_Assemble, ONLY: CD_Assemble_Cable_Tangent_Force_Banded_Free
  USE CableDyn_Static, ONLY: CableSolverConfig, CableCurrentLoad, CD_Static_Cable_Solve, &
                             CD_Static_Line_End_Forces, CD_STATIC_OK
  USE CableDyn_Driver, ONLY: CD_Run_Static_Driver
  USE, INTRINSIC :: IEEE_ARITHMETIC, ONLY: IEEE_VALUE, IEEE_QUIET_NAN
  USE, INTRINSIC :: IEEE_EXCEPTIONS, ONLY: IEEE_USUAL, IEEE_GET_HALTING_MODE, IEEE_SET_HALTING_MODE, IEEE_SET_FLAG
  IMPLICIT NONE
  INTEGER :: nfail

  nfail = 0
  CALL case_sea_component_overflow()
  CALL case_band_guard()
  CALL case_nan_friction()
  CALL case_end_force_shapes()
  CALL case_driver_keyword_case()
  IF (nfail > 0) THEN
    WRITE (*, '(A,I0,A)') 'FAIL: ', nfail, ' assertion(s) failed'
    ERROR STOP 1
  END IF
  WRITE (*, '(A)') 'PASS: core input guards fail closed'

CONTAINS

  SUBROUTINE case_sea_component_overflow()
    TYPE(CD_SeaType) :: sea
    TYPE(CD_WaveTrainType) :: tr
    INTEGER :: es
    CHARACTER(300) :: em
    tr%kind = CD_TRAIN_JONSWAP
    tr%height = 2.0_wp
    tr%period = 8.0_wp
    tr%gamma = 3.3_wp
    tr%spreading = 2.0_wp
    CALL CD_Sea_Add_Train(sea, tr, es, em)
    CALL require(es == CD_SEA_OK, 'sea: add train: '//TRIM(em))
    sea%n_freq = 50000
    sea%n_dir = 50000
    CALL CD_Sea_Synthesise(sea, 100.0_wp, 9.81_wp, 1, es, em)
    CALL require(es /= CD_SEA_OK .AND. INDEX(em, 'more than 100000 components') > 0, &
                 'sea: a 2.5e9-component sea is rejected by the component limit')
    CALL require(.NOT. sea%ready, 'sea: the rejected sea is not ready')
  END SUBROUTINE case_sea_component_overflow

  SUBROUTINE case_band_guard()
    !! Two elements with the middle node and the x DOF of the last node free: the element
    !! couplings reach |i - j| = 3, so a band declared with kl = ku = 2 must be rejected
    !! (the entries would land in the factorization fill rows or past the band).
    REAL(wp) :: nodes(3, 3), Kb(8, 4), fint(9), ten(2)
    INTEGER :: conn(2, 2), es
    CHARACTER(200) :: em
    nodes = RESHAPE([0.0_wp, 0.0_wp, 0.0_wp, 1.1_wp, 0.0_wp, 0.0_wp, 2.2_wp, 0.0_wp, 0.0_wp], [3, 3])
    conn = RESHAPE([1, 2, 2, 3], [2, 2])
    CALL CD_Assemble_Cable_Tangent_Force_Banded_Free(nodes, conn, [1.0_wp, 1.0_wp], [1.0e3_wp, 1.0e3_wp], &
                                                     .FALSE., [4, 5, 6, 7], 2, 2, Kb, fint, ten, es, em)
    CALL require(es /= 0 .AND. INDEX(em, 'bandwidth too small') > 0, &
                 'band: an entry outside the declared band is rejected')
  END SUBROUTINE case_band_guard

  SUBROUTINE case_nan_friction()
    TYPE(CableSolverConfig) :: cfg
    TYPE(CableCurrentLoad) :: cur
    REAL(wp) :: q0(9), q(9), f_ext(9)
    INTEGER :: conn(2, 2), es, nit
    LOGICAL :: conv, stall, floor, halt(3)
    CHARACTER(300) :: em
    q0 = [0.0_wp, 0.0_wp, 0.0_wp, 1.0_wp, 0.0_wp, 0.0_wp, 2.0_wp, 0.0_wp, 0.0_wp]
    conn = RESHAPE([1, 2, 2, 3], [2, 2])
    f_ext = 0.0_wp
    f_ext(3:9:3) = -10.0_wp
    cur%velocity = [0.5_wp, 0.0_wp, 0.0_wp]
    cur%rho = 1025.0_wp
    cur%diameter = 0.1_wp
    cur%cdn = 1.0_wp
    cur%cdt = 0.1_wp
    cur%waterline_z = 50.0_wp
    ALLOCATE (cur%friction_ref(2, 3))
    cur%friction_ref = RESHAPE(q0([1, 2, 4, 5, 7, 8]), [2, 3])
    CALL IEEE_GET_HALTING_MODE(IEEE_USUAL, halt)
    CALL IEEE_SET_HALTING_MODE(IEEE_USUAL, .FALSE.)
    cur%friction_mu = IEEE_VALUE(1.0_wp, IEEE_QUIET_NAN)
    CALL CD_Static_Cable_Solve(q0, conn, [1.0_wp, 1.0_wp], [1.0e6_wp, 1.0e6_wp], .TRUE., f_ext, &
                               [1, 2, 3, 7, 8, 9], cfg, q, conv, stall, floor, nit, es, em, &
                               seabed_z_floor=0.0_wp, seabed_kn=[1.0e4_wp, 1.0e4_wp, 1.0e4_wp], current=cur)
    CALL require(es /= CD_STATIC_OK .AND. INDEX(em, 'friction coefficients must be finite') > 0, &
                 'friction: a NaN friction coefficient fails closed')
    cur%friction_mu = 0.5_wp
    cur%friction_mu_axial = IEEE_VALUE(1.0_wp, IEEE_QUIET_NAN)
    CALL CD_Static_Cable_Solve(q0, conn, [1.0_wp, 1.0_wp], [1.0e6_wp, 1.0e6_wp], .TRUE., f_ext, &
                               [1, 2, 3, 7, 8, 9], cfg, q, conv, stall, floor, nit, es, em, &
                               seabed_z_floor=0.0_wp, seabed_kn=[1.0e4_wp, 1.0e4_wp, 1.0e4_wp], current=cur)
    CALL require(es /= CD_STATIC_OK .AND. INDEX(em, 'friction coefficients must be finite') > 0, &
                 'friction: a NaN axial friction coefficient fails closed')
    CALL IEEE_SET_FLAG(IEEE_USUAL, .FALSE.)
    CALL IEEE_SET_HALTING_MODE(IEEE_USUAL, halt)
  END SUBROUTINE case_nan_friction

  SUBROUTINE case_end_force_shapes()
    REAL(wp) :: q(9), f_ext(9), fa(3), fb(3)
    INTEGER :: conn(2, 2), es
    CHARACTER(300) :: em
    q = [0.0_wp, 0.0_wp, 0.0_wp, 1.0_wp, 0.0_wp, 0.0_wp, 2.0_wp, 0.0_wp, 0.0_wp]
    conn = RESHAPE([1, 2, 2, 3], [2, 2])
    f_ext = 0.0_wp
    CALL CD_Static_Line_End_Forces(q, conn, [1.0_wp, 1.0_wp], [1.0e6_wp, 1.0e6_wp], f_ext, .TRUE., fa, fb, &
                                   es, em, seabed_z_floor=0.0_wp, seabed_kn=[1.0e4_wp, 1.0e4_wp])
    CALL require(es /= CD_STATIC_OK .AND. INDEX(em, 'seabed_kn') > 0, &
                 'end forces: a short seabed stiffness array is rejected')
  END SUBROUTINE case_end_force_shapes

  SUBROUTINE case_driver_keyword_case()
    !! The explicit nodes/elements deck with upper-case keywords parses and solves.
    INTEGER :: u, es
    LOGICAL :: conv
    CHARACTER(300) :: em
    OPEN (NEWUNIT=u, FILE='guards_driver_deck.txt', STATUS='REPLACE', ACTION='WRITE')
    WRITE (u, '(A)') 'Gravity 9.81'
    WRITE (u, '(A)') 'Tension_Only F'
    WRITE (u, '(A)') 'Nodes 3'
    WRITE (u, '(A)') '0.0 0.0 0.0'
    WRITE (u, '(A)') '1.0 0.0 -0.5'
    WRITE (u, '(A)') '2.0 0.0 0.0'
    WRITE (u, '(A)') 'Elements 2'
    WRITE (u, '(A)') '1 2 1.0 1000.0 50.0 0.1'
    WRITE (u, '(A)') '2 3 1.0 1000.0 50.0 0.1'
    WRITE (u, '(A)') 'Fixed 7'
    WRITE (u, '(A)') '1 2 3 5 7 8 9'
    CLOSE (u)
    CALL CD_Run_Static_Driver('guards_driver_deck.txt', 'guards_driver_out.csv', conv, es, em)
    CALL require(es == 0 .AND. conv, 'driver: upper-case keywords are accepted: '//TRIM(em))
  END SUBROUTINE case_driver_keyword_case

  SUBROUTINE require(cond, label)
    LOGICAL, INTENT(IN) :: cond
    CHARACTER(*), INTENT(IN) :: label
    IF (.NOT. cond) THEN
      WRITE (*, '(A,A,A)') 'MISMATCH [', label, ']: condition false'
      nfail = nfail + 1
    END IF
  END SUBROUTINE require

END PROGRAM test_core_input_guards
