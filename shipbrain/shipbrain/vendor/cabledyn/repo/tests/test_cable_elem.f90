! File: tests/test_cable_elem.f90
! SPDX-License-Identifier: Apache-2.0
! Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
PROGRAM test_cable_elem
  !! Unit test for CableDyn_CableElem (the EI=0 cable element), cross-validated
  !! against independently computed values.
  !! The expected tension / force / tangent values below were computed
  !! independently on the same inputs.
  !!
  !! Plain CTest assertion program: it `error stop 1`s on any mismatch, which CTest
  !! reports as a failed test.
  USE CableDyn_Precision, ONLY: wp
  USE CableDyn_CableElem, ONLY: CD_Compute_Cable_Element
  USE, INTRINSIC :: IEEE_ARITHMETIC, ONLY: IEEE_VALUE, IEEE_POSITIVE_INF, IEEE_QUIET_NAN
  USE, INTRINSIC :: IEEE_EXCEPTIONS, ONLY: IEEE_USUAL, IEEE_GET_HALTING_MODE, IEEE_SET_HALTING_MODE, IEEE_SET_FLAG
  IMPLICIT NONE
  LOGICAL :: fp_halt(3)   ! saved IEEE halting modes around deliberately non-finite inputs

  INTEGER :: nfail
  nfail = 0

  CALL case_axial_tension()
  CALL case_oblique_345()
  CALL case_compression_clamped()
  CALL case_tangent_structure()
  CALL case_invalid_inputs()

  IF (nfail > 0) THEN
    WRITE (*, '(A,I0,A)') 'FAIL: ', nfail, ' assertion(s) failed'
    ERROR STOP 1
  END IF
  WRITE (*, '(A)') 'PASS: CableDyn_CableElem matches the independent reference values'

CONTAINS

  SUBROUTINE expect(got, want, label)
    !! Combined absolute + relative tolerance check (atol 1e-12, rtol 1e-9).
    REAL(wp), INTENT(IN) :: got, want
    CHARACTER(*), INTENT(IN) :: label
    REAL(wp), PARAMETER :: atol = 1.0e-12_wp, rtol = 1.0e-9_wp
    IF (.NOT. (ABS(got - want) <= atol + rtol*ABS(want))) THEN
      WRITE (*, '(A,A,A,ES23.15,A,ES23.15)') 'MISMATCH [', label, ']: got ', got, ' want ', want
      nfail = nfail + 1
    END IF
  END SUBROUTINE expect

  SUBROUTINE case_axial_tension()
    REAL(wp) :: nodes(6), Kt(6, 6), fint(6), T
    INTEGER :: es
    CHARACTER(120) :: em
    nodes = [0._wp, 0._wp, 0._wp, 1.2_wp, 0._wp, 0._wp]
    CALL CD_Compute_Cable_Element(nodes, 100._wp, 1.0_wp, .TRUE., Kt, fint, T, es, em)
    CALL expect(REAL(es, wp), 0._wp, 'axial:ErrStat')
    CALL expect(T, 20._wp, 'axial:tension')
    CALL expect(fint(1), -20._wp, 'axial:fint1')
    CALL expect(fint(2), 0._wp, 'axial:fint2')
    CALL expect(fint(4), 20._wp, 'axial:fint4')
    CALL expect(Kt(1, 1), 100._wp, 'axial:Kt11')
    CALL expect(Kt(2, 2), 16.666666666666664_wp, 'axial:Kt22')
    CALL expect(Kt(1, 4), -100._wp, 'axial:Kt14')
  END SUBROUTINE case_axial_tension

  SUBROUTINE case_oblique_345()
    REAL(wp) :: nodes(6), Kt(6, 6), fint(6), T
    INTEGER :: es
    CHARACTER(120) :: em
    nodes = [0._wp, 0._wp, 0._wp, 3._wp, 4._wp, 0._wp]
    CALL CD_Compute_Cable_Element(nodes, 50._wp, 4.0_wp, .TRUE., Kt, fint, T, es, em)
    CALL expect(T, 12.5_wp, 'oblique:tension')
    CALL expect(fint(1), -7.5_wp, 'oblique:fint1')
    CALL expect(fint(2), -10._wp, 'oblique:fint2')
    CALL expect(fint(4), 7.5_wp, 'oblique:fint4')
    CALL expect(fint(5), 10._wp, 'oblique:fint5')
    CALL expect(Kt(1, 1), 6.1_wp, 'oblique:Kt11')
    CALL expect(Kt(2, 2), 8.9_wp, 'oblique:Kt22')
    CALL expect(Kt(1, 4), -6.1_wp, 'oblique:Kt14')
  END SUBROUTINE case_oblique_345

  SUBROUTINE case_compression_clamped()
    !! A compressed tension-only element carries zero force AND zero tangent.
    REAL(wp) :: nodes(6), Kt(6, 6), fint(6), T
    INTEGER :: es, i, j
    CHARACTER(120) :: em
    nodes = [0._wp, 0._wp, 0._wp, 0.8_wp, 0._wp, 0._wp]
    CALL CD_Compute_Cable_Element(nodes, 100._wp, 1.0_wp, .TRUE., Kt, fint, T, es, em)
    CALL expect(T, 0._wp, 'compression:tension')
    DO i = 1, 6
      CALL expect(fint(i), 0._wp, 'compression:fint')
      DO j = 1, 6
        CALL expect(Kt(i, j), 0._wp, 'compression:Kt')
      END DO
    END DO
  END SUBROUTINE case_compression_clamped

  SUBROUTINE case_tangent_structure()
    !! Kt = [[B, -B], [-B, B]] and B is symmetric, for any configuration.
    REAL(wp) :: nodes(6), Kt(6, 6), fint(6), T
    INTEGER :: es, i, j
    CHARACTER(120) :: em
    nodes = [0.1_wp, -0.2_wp, 0.3_wp, 1.0_wp, 0.7_wp, -0.4_wp]
    CALL CD_Compute_Cable_Element(nodes, 200._wp, 0.9_wp, .FALSE., Kt, fint, T, es, em)
    CALL expect(REAL(es, wp), 0._wp, 'structure:ErrStat')
    DO i = 1, 3
      DO j = 1, 3
        CALL expect(Kt(i, j + 3), -Kt(i, j), 'structure:offdiag=-block')
        CALL expect(Kt(i + 3, j + 3), Kt(i, j), 'structure:lowerdiag=block')
        CALL expect(Kt(i, j), Kt(j, i), 'structure:block-symmetric')
      END DO
    END DO
  END SUBROUTINE case_tangent_structure

  SUBROUTINE case_invalid_inputs()
    !! Collapsed / non-positive / NON-FINITE inputs all fail closed (ErrStat = 1).
    !! +Inf must be rejected too -- `x > 0` alone accepts Inf and would leak NaNs.
    REAL(wp) :: nodes(6), Kt(6, 6), fint(6), T, inf, nan
    INTEGER :: es
    CHARACTER(120) :: em
    inf = IEEE_VALUE(1._wp, IEEE_POSITIVE_INF)
    nan = IEEE_VALUE(1._wp, IEEE_QUIET_NAN)
    nodes = [0._wp, 0._wp, 0._wp, 0._wp, 0._wp, 0._wp]   ! a == b -> zero length
    CALL CD_Compute_Cable_Element(nodes, 100._wp, 1.0_wp, .TRUE., Kt, fint, T, es, em)
    CALL expect(REAL(es, wp), 1._wp, 'invalid:collapsed-ErrStat')
    nodes = [0._wp, 0._wp, 0._wp, 1._wp, 0._wp, 0._wp]
    CALL CD_Compute_Cable_Element(nodes, -1._wp, 1.0_wp, .TRUE., Kt, fint, T, es, em)
    CALL expect(REAL(es, wp), 1._wp, 'invalid:EA-negative')
    CALL CD_Compute_Cable_Element(nodes, 100._wp, 0.0_wp, .TRUE., Kt, fint, T, es, em)
    CALL expect(REAL(es, wp), 1._wp, 'invalid:L0-zero')
    ! non-finite scalars: +Inf and NaN both rejected
    CALL CD_Compute_Cable_Element(nodes, inf, 1.0_wp, .TRUE., Kt, fint, T, es, em)
    CALL expect(REAL(es, wp), 1._wp, 'invalid:EA-inf')
    CALL CD_Compute_Cable_Element(nodes, 100._wp, inf, .TRUE., Kt, fint, T, es, em)
    CALL expect(REAL(es, wp), 1._wp, 'invalid:L0-inf')
    ! deliberately non-finite or overflowing input: must not halt a trapping build
    CALL IEEE_GET_HALTING_MODE(IEEE_USUAL, fp_halt)
    CALL IEEE_SET_HALTING_MODE(IEEE_USUAL, .FALSE.)
    CALL CD_Compute_Cable_Element(nodes, nan, 1.0_wp, .TRUE., Kt, fint, T, es, em)
    CALL IEEE_SET_FLAG(IEEE_USUAL, .FALSE.)
    CALL IEEE_SET_HALTING_MODE(IEEE_USUAL, fp_halt)
    CALL expect(REAL(es, wp), 1._wp, 'invalid:EA-nan')
    ! non-finite node coordinate (+Inf or NaN) -> rejected before any arithmetic
    nodes = [0._wp, 0._wp, 0._wp, inf, 0._wp, 0._wp]
    CALL CD_Compute_Cable_Element(nodes, 100._wp, 1.0_wp, .TRUE., Kt, fint, T, es, em)
    CALL expect(REAL(es, wp), 1._wp, 'invalid:node-inf')
    nodes = [0._wp, 0._wp, 0._wp, nan, 0._wp, 0._wp]
    CALL CD_Compute_Cable_Element(nodes, 100._wp, 1.0_wp, .TRUE., Kt, fint, T, es, em)
    CALL expect(REAL(es, wp), 1._wp, 'invalid:node-nan')
  END SUBROUTINE case_invalid_inputs

END PROGRAM test_cable_elem
