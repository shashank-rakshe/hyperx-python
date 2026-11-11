! File: tests/test_hermite_axial_damping.f90
! SPDX-License-Identifier: Apache-2.0
! Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
PROGRAM test_hermite_axial_damping
  !! Axial Kelvin-Voigt damping on the finite-EI Hermite cable. The gates cover the
  !! analytical straight-element limit, rigid-body invariance, positive dissipation,
  !! exact position/velocity Jacobians, the unstretched-length rate of active line
  !! control, and the transactional model setter.
  USE CableDyn_Precision, ONLY: wp
  USE CableDyn_HermiteCable, ONLY: CD_HermiteCable_Axial_Resultant
  USE CableDyn_HermiteCableDynamic, ONLY: CD_HermiteCableDynType, CD_HermiteCable_Dyn_End_Force, &
                                          CD_HermiteCable_Axial_Damping_Element, &
                                          CD_HermiteCable_Axial_Damping_Resultant, &
                                          CD_HermiteCable_Dyn_Init, &
                                          CD_HermiteCable_Dyn_Set_Axial_Damping, &
                                          CD_HermiteCable_Dyn_End, &
                                          CD_HCDYN_OK, CD_HCDYN_BADINPUT
  USE CableDyn_OpenFAST_HermiteFMF, ONLY: CD_HFMF_ModuleType, CD_HFMF_End
  USE CableDyn_System, ONLY: CD_SystemType
  USE CableDyn_DeckDriver, ONLY: CD_Eval_Aggregate_Channel, CD_DECKDRV_OK
  IMPLICIT NONE

  INTEGER :: nfail

  nfail = 0
  CALL check_straight_limit()
  CALL check_jacobians_and_dissipation()
  CALL check_length_rate()
  CALL check_setter_lifecycle()
  IF (nfail > 0) THEN
    WRITE (*, '(A,I0,A)') 'FAIL: ', nfail, ' assertion(s) failed'
    ERROR STOP 1
  END IF
  WRITE (*, '(A)') 'PASS: Hermite axial Kelvin-Voigt damping'

CONTAINS

  INCLUDE 'nan_max_abs.inc'

  SUBROUTINE check_straight_limit()
    REAL(wp), PARAMETER :: l0 = 2.5_wp, ba = 480.0_wp, speed = 0.35_wp
    REAL(wp) :: qe(12), ve(12), f(12), kq(12, 12), kv(12, 12), expected(12), power, td
    INTEGER :: es
    CHARACTER(300) :: em

    qe = [0.0_wp, 0.0_wp, 0.0_wp, 1.0_wp, 0.0_wp, 0.0_wp, &
          l0, 0.0_wp, 0.0_wp, 1.0_wp, 0.0_wp, 0.0_wp]
    ! v(s0) = speed*s0/l0 gives a uniform strain rate speed/l0. The tangent-rate
    ! DOFs are dv/ds0, so the cubic Hermite field reproduces this motion exactly.
    ve = [0.0_wp, 0.0_wp, 0.0_wp, speed/l0, 0.0_wp, 0.0_wp, &
          speed, 0.0_wp, 0.0_wp, speed/l0, 0.0_wp, 0.0_wp]
    CALL CD_HermiteCable_Axial_Damping_Element(qe, ve, l0, ba, f, kq, kv, es, em)
    CALL require(es == CD_HCDYN_OK, 'straight element accepted: '//TRIM(em))
    expected = 0.0_wp
    expected(1) = -ba*speed/l0
    expected(7) = ba*speed/l0
    CALL require(nan_max_abs(f - expected) <= 2.0e-13_wp*MAX(1.0_wp, nan_max_abs(expected)), &
                 'straight element reduces to the 2-node axial dashpot')
    power = DOT_PRODUCT(ve, f)
    CALL require(ABS(power - ba*speed*speed/l0) <= 5.0e-13_wp*MAX(1.0_wp, ABS(power)), &
                 'straight-element damping power matches BA*speed^2/l0')
    CALL CD_HermiteCable_Axial_Damping_Resultant(qe, ve, l0, ba, 0.37_wp, td, es, em)
    CALL require(es == CD_HCDYN_OK .AND. &
                 ABS(td - ba*speed/l0) <= 2.0e-13_wp*MAX(1.0_wp, ABS(td)), &
                 'reported viscous resultant matches the uniform axial dashpot tension')

    ! A rigid translation has v_xi = 0 and therefore no constitutive damping force.
    ve = 0.0_wp
    ve(1:3) = [0.4_wp, -0.2_wp, 0.1_wp]
    ve(7:9) = ve(1:3)
    CALL CD_HermiteCable_Axial_Damping_Element(qe, ve, l0, ba, f, ErrStat=es, ErrMsg=em)
    CALL require(es == CD_HCDYN_OK .AND. nan_max_abs(f) == 0.0_wp, &
                 'rigid translation produces exactly zero axial damping')
  END SUBROUTINE check_straight_limit

  SUBROUTINE check_jacobians_and_dissipation()
    REAL(wp), PARAMETER :: l0 = 2.2_wp, ba = 3.7e4_wp
    REAL(wp) :: qe(12), ve(12), qp(12), qm(12), vp(12), vm(12)
    REAL(wp) :: f(12), fp(12), fm(12), kq(12, 12), kv(12, 12), kqfd(12, 12), kvfd(12, 12)
    REAL(wp) :: h, errq, errv, scaleq, scalev
    INTEGER :: es, j
    CHARACTER(300) :: em

    qe = [0.10_wp, -0.20_wp, 0.30_wp, 0.90_wp, 0.20_wp, 0.15_wp, &
          2.30_wp, 0.50_wp, 0.80_wp, 0.70_wp, -0.10_wp, 0.25_wp]
    ve = [0.12_wp, -0.04_wp, 0.03_wp, 0.02_wp, 0.01_wp, -0.03_wp, &
          -0.06_wp, 0.08_wp, 0.05_wp, -0.01_wp, 0.04_wp, 0.02_wp]
    CALL CD_HermiteCable_Axial_Damping_Element(qe, ve, l0, ba, f, kq, kv, es, em, 6)
    CALL require(es == CD_HCDYN_OK, 'curved element accepted: '//TRIM(em))
    CALL require(DOT_PRODUCT(ve, f) > 0.0_wp, 'curved-element damping is strictly dissipative')

    DO j = 1, 12
      h = 2.0e-7_wp*MAX(1.0_wp, ABS(qe(j)))
      qp = qe; qm = qe
      qp(j) = qp(j) + h; qm(j) = qm(j) - h
      CALL CD_HermiteCable_Axial_Damping_Element(qp, ve, l0, ba, fp, ErrStat=es, ErrMsg=em, &
                                                 quadrature_order=6)
      CALL require(es == CD_HCDYN_OK, 'positive position perturbation accepted')
      CALL CD_HermiteCable_Axial_Damping_Element(qm, ve, l0, ba, fm, ErrStat=es, ErrMsg=em, &
                                                 quadrature_order=6)
      CALL require(es == CD_HCDYN_OK, 'negative position perturbation accepted')
      kqfd(:, j) = (fp - fm)/(2.0_wp*h)

      h = 2.0e-7_wp*MAX(1.0_wp, ABS(ve(j)))
      vp = ve; vm = ve
      vp(j) = vp(j) + h; vm(j) = vm(j) - h
      CALL CD_HermiteCable_Axial_Damping_Element(qe, vp, l0, ba, fp, ErrStat=es, ErrMsg=em, &
                                                 quadrature_order=6)
      CALL require(es == CD_HCDYN_OK, 'positive velocity perturbation accepted')
      CALL CD_HermiteCable_Axial_Damping_Element(qe, vm, l0, ba, fm, ErrStat=es, ErrMsg=em, &
                                                 quadrature_order=6)
      CALL require(es == CD_HCDYN_OK, 'negative velocity perturbation accepted')
      kvfd(:, j) = (fp - fm)/(2.0_wp*h)
    END DO
    scaleq = MAX(1.0_wp, nan_max_abs(kqfd))
    scalev = MAX(1.0_wp, nan_max_abs(kvfd))
    errq = nan_max_abs(kq - kqfd)/scaleq
    errv = nan_max_abs(kv - kvfd)/scalev
    WRITE (*, '(A,ES10.3,A,ES10.3)') '  damping Jacobian relative errors: q=', errq, '  v=', errv
    CALL require(errq < 2.0e-7_wp, 'analytical position Jacobian matches central differences')
    CALL require(errv < 2.0e-8_wp, 'analytical velocity Jacobian matches central differences')
    CALL require(nan_max_abs(kv - TRANSPOSE(kv)) < 1.0e-12_wp*scalev, &
                 'velocity Jacobian is symmetric')
  END SUBROUTINE check_jacobians_and_dissipation

  SUBROUTINE check_length_rate()
    !! Active line control: with an unstretched-length rate l0_dot the damped strain rate is
    !! the time derivative of the strain |r_xi|/l0 - 1 the elastic resultant uses, along
    !! q + v t and l0 + l0_dot t. Gates: a straight element paid out at constant strain
    !! carries no damping force; the viscous resultant matches the central difference of that
    !! strain; a zero rate reproduces the uncontrolled element; and the position and velocity
    !! Jacobians with a rate match central differences.
    REAL(wp), PARAMETER :: l0 = 2.2_wp, ba = 3.7e4_wp, ldot = 0.37_wp, stretch = 1.004_wp
    REAL(wp), PARAMETER :: xs(3) = [0.0_wp, 0.31_wp, 0.83_wp]
    REAL(wp) :: qe(12), ve(12), qp(12), qm(12), vp(12), vm(12)
    REAL(wp) :: f(12), f0(12), fp(12), fm(12), kq(12, 12), kv(12, 12), kq0(12, 12), kv0(12, 12)
    REAL(wp) :: kqfd(12, 12), kvfd(12, 12)
    REAL(wp) :: td, sp, sm, h, errq, errv, scaleq, scalev, rate_fd
    INTEGER :: es, j, k
    CHARACTER(300) :: em

    ! (a) constant-strain pay-out: r_2 moves with the growing reference at the element's
    ! stretch and the tangents keep it, so the strain does not change anywhere
    qe = [0.0_wp, 0.0_wp, 0.0_wp, stretch, 0.0_wp, 0.0_wp, &
          stretch*l0, 0.0_wp, 0.0_wp, stretch, 0.0_wp, 0.0_wp]
    ve = 0.0_wp
    ve(7) = stretch*ldot
    CALL CD_HermiteCable_Axial_Damping_Element(qe, ve, l0, ba, f, kq, kv, es, em, l0_dot=ldot)
    CALL require(es == CD_HCDYN_OK, 'pay-out element accepted: '//TRIM(em))
    CALL require(nan_max_abs(f) <= 1.0e-12_wp*ba*ldot/l0, &
                 'a straight element paid out at constant strain carries no damping force')
    DO k = 1, SIZE(xs)
      CALL CD_HermiteCable_Axial_Damping_Resultant(qe, ve, l0, ba, xs(k), td, es, em, l0_dot=ldot)
      CALL require(es == CD_HCDYN_OK .AND. ABS(td) <= 1.0e-12_wp*ba*ldot/l0, &
                   'constant-strain pay-out has no viscous resultant')
    END DO
    ! without the rate the end velocity reads as stretch: strain rate dH_3 stretch ldot/l0,
    ! so f_r2 = BA stretch ldot/l0 times the integral of dH_3**2 = 36 x**2 (1 - x)**2, 6/5
    CALL CD_HermiteCable_Axial_Damping_Element(qe, ve, l0, ba, f, ErrStat=es, ErrMsg=em)
    CALL require(ABS(f(7) - 1.2_wp*ba*stretch*ldot/l0) <= 1.0e-12_wp*ba*ldot/l0, &
                 'without the rate the same motion reads as a stretching dashpot')

    ! (b) the resultant is BA times the time derivative of the strain along the motion
    qe = [0.10_wp, -0.20_wp, 0.30_wp, 0.90_wp, 0.20_wp, 0.15_wp, &
          2.30_wp, 0.50_wp, 0.80_wp, 0.70_wp, -0.10_wp, 0.25_wp]
    ve = [0.12_wp, -0.04_wp, 0.03_wp, 0.02_wp, 0.01_wp, -0.03_wp, &
          -0.06_wp, 0.08_wp, 0.05_wp, -0.01_wp, 0.04_wp, 0.02_wp]
    h = 1.0e-6_wp
    DO k = 1, SIZE(xs)
      CALL CD_HermiteCable_Axial_Resultant(qe + h*ve, l0 + h*ldot, 1.0_wp, xs(k), sp, es, em)
      CALL CD_HermiteCable_Axial_Resultant(qe - h*ve, l0 - h*ldot, 1.0_wp, xs(k), sm, es, em)
      rate_fd = (sp - sm)/(2.0_wp*h)
      CALL CD_HermiteCable_Axial_Damping_Resultant(qe, ve, l0, ba, xs(k), td, es, em, l0_dot=ldot)
      CALL require(es == CD_HCDYN_OK .AND. ABS(td - ba*rate_fd) <= 1.0e-7_wp*ba*MAX(ABS(rate_fd), 1.0e-3_wp), &
                   'the controlled viscous resultant is BA times the strain rate along q(t), l0(t)')
    END DO

    ! (c) a zero rate is the uncontrolled element
    CALL CD_HermiteCable_Axial_Damping_Element(qe, ve, l0, ba, f0, kq0, kv0, es, em, 6)
    CALL CD_HermiteCable_Axial_Damping_Element(qe, ve, l0, ba, f, kq, kv, es, em, 6, 0.0_wp)
    CALL require(nan_max_abs(f - f0) <= 0.0_wp .AND. nan_max_abs(kq - kq0) <= 0.0_wp .AND. &
                 nan_max_abs(kv - kv0) <= 0.0_wp, 'a zero length rate reproduces the uncontrolled element')

    ! (d) Jacobians with a rate against central differences
    CALL CD_HermiteCable_Axial_Damping_Element(qe, ve, l0, ba, f, kq, kv, es, em, 6, ldot)
    CALL require(es == CD_HCDYN_OK, 'controlled curved element accepted: '//TRIM(em))
    CALL require(nan_max_abs(kq - kq0) > 1.0e-3_wp*nan_max_abs(kq0), 'the length rate enters the position Jacobian')
    DO j = 1, 12
      h = 2.0e-7_wp*MAX(1.0_wp, ABS(qe(j)))
      qp = qe; qm = qe
      qp(j) = qp(j) + h; qm(j) = qm(j) - h
      CALL CD_HermiteCable_Axial_Damping_Element(qp, ve, l0, ba, fp, ErrStat=es, ErrMsg=em, &
                                                 quadrature_order=6, l0_dot=ldot)
      CALL CD_HermiteCable_Axial_Damping_Element(qm, ve, l0, ba, fm, ErrStat=es, ErrMsg=em, &
                                                 quadrature_order=6, l0_dot=ldot)
      kqfd(:, j) = (fp - fm)/(2.0_wp*h)
      h = 2.0e-7_wp*MAX(1.0_wp, ABS(ve(j)))
      vp = ve; vm = ve
      vp(j) = vp(j) + h; vm(j) = vm(j) - h
      CALL CD_HermiteCable_Axial_Damping_Element(qe, vp, l0, ba, fp, ErrStat=es, ErrMsg=em, &
                                                 quadrature_order=6, l0_dot=ldot)
      CALL CD_HermiteCable_Axial_Damping_Element(qe, vm, l0, ba, fm, ErrStat=es, ErrMsg=em, &
                                                 quadrature_order=6, l0_dot=ldot)
      kvfd(:, j) = (fp - fm)/(2.0_wp*h)
    END DO
    scaleq = MAX(1.0_wp, nan_max_abs(kqfd))
    scalev = MAX(1.0_wp, nan_max_abs(kvfd))
    errq = nan_max_abs(kq - kqfd)/scaleq
    errv = nan_max_abs(kv - kvfd)/scalev
    WRITE (*, '(A,ES10.3,A,ES10.3)') '  controlled damping Jacobian relative errors: q=', errq, '  v=', errv
    CALL require(errq < 2.0e-7_wp, 'controlled position Jacobian matches central differences')
    CALL require(errv < 2.0e-8_wp, 'controlled velocity Jacobian matches central differences')
  END SUBROUTINE check_length_rate

  SUBROUTINE check_setter_lifecycle()
    TYPE(CD_HermiteCableDynType) :: model
    TYPE(CD_HFMF_ModuleType), ALLOCATABLE :: cables(:)
    TYPE(CD_SystemType) :: unused_system
    REAL(wp), PARAMETER :: l0(1) = [2.0_wp], ea(1) = [1.0e5_wp], ei(1) = [25.0_wp]
    REAL(wp), PARAMETER :: rhoa(1) = [8.0_wp], weight(1) = [0.0_wp]
    REAL(wp) :: seed(12), a_saved(12), ba_saved(1), bad(1), reported
    LOGICAL :: line_is_cable(1)
    INTEGER :: line_obj_index(1)
    INTEGER, PARAMETER :: fixed(9) = [1, 2, 3, 4, 5, 6, 8, 9, 10]
    INTEGER :: es
    CHARACTER(300) :: em

    seed = [0.0_wp, 0.0_wp, 0.0_wp, 1.0_wp, 0.0_wp, 0.0_wp, &
            2.0_wp, 0.0_wp, 0.0_wp, 1.0_wp, 0.0_wp, 0.0_wp]
    CALL CD_HermiteCable_Dyn_Init(model, l0, ea, ei, rhoa, weight, seed, fixed, &
                                  -100.0_wp, 0.0_wp, 1.0_wp, es, em)
    CALL require(es == CD_HCDYN_OK, 'model init: '//TRIM(em))
    IF (es /= CD_HCDYN_OK) RETURN
    model%v(7) = 0.2_wp
    model%v(10) = 0.1_wp
    CALL CD_HermiteCable_Dyn_Set_Axial_Damping(model, [500.0_wp], es, em)
    CALL require(es == CD_HCDYN_OK, 'setter accepts resolved BA: '//TRIM(em))
    CALL require(model%has_axial_damping .AND. ALLOCATED(model%BA), 'setter enables and stores BA')
    CALL require(model%a(7) < 0.0_wp, 'setter refreshes acceleration against the stretching velocity')
    ALLOCATE (cables(1))
    cables(1)%line = model
    line_is_cable = .TRUE.
    line_obj_index = 1
    CALL CD_Eval_Aggregate_Channel('FairTen1', .FALSE., unused_system, cables, line_is_cable, &
                                   line_obj_index, reported, es, em)
    CALL require(es == CD_DECKDRV_OK, 'fairlead tension channel evaluates: '//TRIM(em))
    ! FairTen is the actual line-end force, as on the EI = 0 lines: the viscous axial resultant
    ! at the end node is part of it. The straight seed carries no elastic stretch, so the end
    ! force is the consistent Kelvin-Voigt nodal force of the stretching end velocity plus the
    ! end node's share of the weight.
    BLOCK
      REAL(wp) :: fdamp(12), fend(3)
      CALL CD_HermiteCable_Axial_Damping_Element(seed, model%v, l0(1), 500.0_wp, fdamp, ErrStat=es, ErrMsg=em)
      CALL require(es == 0 .AND. NORM2(fdamp(7:9)) > 1.0_wp, 'consistent damping end force: '//TRIM(em))
      CALL CD_HermiteCable_Dyn_End_Force(model, 2, fend, es, em)
      CALL require(es == CD_HCDYN_OK, 'end force at rest: '//TRIM(em))
      CALL require(ABS(reported - NORM2(fend)) <= 1.0e-12_wp*MAX(NORM2(fend), 1.0_wp), &
                   'fairlead tension channel is the end force')
      CALL require(NORM2(fend + fdamp(7:9) + [0.0_wp, 0.0_wp, 0.5_wp*model%w(1)*l0(1)]) <= &
                   1.0e-9_wp*MAX(NORM2(fend), 1.0_wp), &
                   'fairlead tension channel includes the viscous axial resultant')
    END BLOCK
    CALL CD_HFMF_End(cables(1))
    DEALLOCATE (cables)

    a_saved = model%a
    ba_saved = model%BA
    bad = -1.0_wp
    CALL CD_HermiteCable_Dyn_Set_Axial_Damping(model, bad, es, em)
    CALL require(es == CD_HCDYN_BADINPUT, 'negative BA fails closed')
    CALL require(model%has_axial_damping .AND. ALL(model%BA == ba_saved) .AND. ALL(model%a == a_saved), &
                 'failed replacement preserves the committed damping state')

    CALL CD_HermiteCable_Dyn_Set_Axial_Damping(model, [0.0_wp], es, em)
    CALL require(es == CD_HCDYN_OK .AND. .NOT. model%has_axial_damping .AND. .NOT. ALLOCATED(model%BA), &
                 'all-zero BA disables the contribution exactly')
    CALL require(nan_max_abs(model%a) < 1.0e-11_wp, 'disabling BA refreshes the undamped acceleration')
    CALL CD_HermiteCable_Dyn_End(model)
  END SUBROUTINE check_setter_lifecycle

  SUBROUTINE require(condition, message)
    LOGICAL, INTENT(IN) :: condition
    CHARACTER(*), INTENT(IN) :: message
    IF (.NOT. condition) THEN
      nfail = nfail + 1
      WRITE (*, '(A)') 'MISMATCH: '//TRIM(message)
    END IF
  END SUBROUTINE require

END PROGRAM test_hermite_axial_damping
