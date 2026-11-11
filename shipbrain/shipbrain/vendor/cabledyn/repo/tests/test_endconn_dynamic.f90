! File: tests/test_endconn_dynamic.f90
! SPDX-License-Identifier: Apache-2.0
! Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
PROGRAM test_endconn_dynamic
  !! Gates the rotational end connection on the finite-EI DYNAMIC path by
  !! STATIC-DYNAMIC CONSISTENCY: an equilibrium of the static solve must remain an
  !! equilibrium under a dynamic march. Three runs, each answering a different question.
  !!
  !!   REFERENCE  A fully clamped cantilever under gravity with NO end connection.
  !!              Static solve -> dynamic march. Whatever drift this shows is the
  !!              platform's inherent static/dynamic agreement on this problem -- the two
  !!              paths are separate assemblies -- and it is the only fair yardstick for
  !!              the connected case. Measuring it rather than assuming zero is the point:
  !!              a fixed absolute tolerance would either mask a real error or fail on
  !!              behaviour that has nothing to do with this feature.
  !!
  !!   CONNECTED  Root position fixed, root tangent free but restrained by the connection.
  !!              Static solve WITH the connection, dynamic march WITH the same connection.
  !!              Must not drift materially more than the reference: a missing, mis-signed
  !!              or mis-scaled dynamic contribution shows up here immediately.
  !!
  !!   CONTROL    The same seed marched WITHOUT attaching the connection. This MUST drift
  !!              far more. Without it the gate could pass on a dynamic path that ignores
  !!              the connection entirely -- exactly the failure it exists to catch.
  USE CableDyn_Precision, ONLY: wp
  USE CableDyn_HermiteCableStatic, ONLY: CD_HermiteCable_Static_Solve, CD_HCSTAT_OK
  USE CableDyn_HermiteCableDynamic, ONLY: CD_HermiteCableDynType, CD_HermiteCable_Dyn_Init, &
                                          CD_HermiteCable_Dyn_Step, &
                                          CD_HermiteCable_Dyn_Set_EndConnection, &
                                          CD_HermiteCable_Dyn_EndConnection_Moment, &
                                          CD_HermiteCable_Dyn_Snapshot, CD_HermiteCable_Dyn_Restore, &
                                          CD_HCDYN_OK
  USE CableDyn_EndConnection, ONLY: CD_ENDCONN_PINNED, CD_ENDCONN_RIGID
  USE, INTRINSIC :: IEEE_ARITHMETIC, ONLY: IEEE_IS_FINITE
  IMPLICIT NONE

  REAL(wp), PARAMETER :: L = 1.0_wp
  REAL(wp), PARAMETER :: EA = 1.0e8_wp, EI = 1.0e7_wp, RHOA = 10.0_wp
  REAL(wp), PARAMETER :: KROT = 1.0e3_wp, WGT = 50.0_wp
  INTEGER, PARAMETER :: NE = 8
  INTEGER, PARAMETER :: NSTEP = 40
  REAL(wp), PARAMETER :: DT = 1.0e-3_wp
  REAL(wp), PARAMETER :: STOL = 1.0e-7_wp
  REAL(wp), PARAMETER :: DTOL = 1.0e-7_wp

  REAL(wp), ALLOCATABLE :: q_ref(:), q_conn(:)
  REAL(wp) :: drift_ref, drift_on, drift_off, allow
  INTEGER :: nfail
  nfail = 0

  CALL solve_static(.FALSE., q_ref)                  ! clamped root, no connection
  CALL march(q_ref, .FALSE., .FALSE., drift_ref)

  CALL solve_static(.TRUE., q_conn)                  ! free tangent + connection
  CALL march(q_conn, .TRUE., .TRUE., drift_on)
  CALL march(q_conn, .TRUE., .FALSE., drift_off)

  WRITE (*, '(A,ES12.5,A,ES12.5,A,ES12.5)') '  reference drift = ', drift_ref, &
    '   connected = ', drift_on, '   control = ', drift_off

  ! The connected case must be no worse than the platform's own static/dynamic agreement,
  ! with a factor of 5 of headroom for the different root boundary condition.
  allow = MAX(1.0e-9_wp*L, 5.0_wp*drift_ref)
  IF (.NOT. (drift_on <= allow)) THEN
    nfail = nfail + 1
    WRITE (*, '(A,ES13.6,A,ES13.6)') 'FAIL: connected drift exceeds the reference budget, drift=', &
      drift_on, ' allow=', allow
  END IF
  ! The control must move by a wide margin, or the gate proves nothing.
  IF (.NOT. (drift_off > 100.0_wp*MAX(drift_on, 1.0e-14_wp))) THEN
    nfail = nfail + 1
    WRITE (*, '(A)') 'FAIL: control without the connection must drift (gate is not sensitive)'
  END IF
  CALL case_rigid_moving()

  IF (nfail > 0) THEN
    WRITE (*, '(A,I0,A)') 'FAIL: ', nfail, ' assertion(s) failed'
    ERROR STOP 1
  END IF
  WRITE (*, '(A)') 'PASS: end-connection static-dynamic consistency (referenced, with control)'

CONTAINS

  INCLUDE 'nan_max_abs.inc'

  SUBROUTINE build(free_tangent, l0, EAv, EIv, rhoAv, wv, seed, fixed)
    !! free_tangent = .TRUE.  -> root position fixed, root tangent free (connection case)
    !! free_tangent = .FALSE. -> full C1 clamp at the root (reference case)
    LOGICAL, INTENT(IN) :: free_tangent
    REAL(wp), ALLOCATABLE, INTENT(OUT) :: l0(:), EAv(:), EIv(:), rhoAv(:), wv(:), seed(:)
    INTEGER, ALLOCATABLE, INTENT(OUT) :: fixed(:)
    INTEGER :: nn, i, kk, nroot
    REAL(wp) :: le
    nn = NE + 1
    le = L/REAL(NE, wp)
    ALLOCATE (l0(NE), EAv(NE), EIv(NE), rhoAv(NE), wv(NE), seed(6*nn))
    l0 = le; EAv = EA; EIv = EI; rhoAv = RHOA; wv = WGT
    seed = 0.0_wp
    DO i = 1, nn
      seed(6*(i - 1) + 1) = REAL(i - 1, wp)*le
      seed(6*(i - 1) + 4) = 1.0_wp
    END DO
    nroot = MERGE(3, 6, free_tangent)
    ALLOCATE (fixed(nroot + 2*nn))
    IF (free_tangent) THEN
      fixed(1:3) = [1, 2, 3]
    ELSE
      fixed(1:6) = [1, 2, 3, 4, 5, 6]
    END IF
    kk = nroot
    DO i = 1, nn
      fixed(kk + 1) = 6*(i - 1) + 2               ! r_y (planar)
      fixed(kk + 2) = 6*(i - 1) + 5               ! m_y (planar)
      kk = kk + 2
    END DO
  END SUBROUTINE build

  SUBROUTINE solve_static(with_conn, q_out)
    LOGICAL, INTENT(IN) :: with_conn
    REAL(wp), ALLOCATABLE, INTENT(OUT) :: q_out(:)
    REAL(wp), ALLOCATABLE :: l0(:), EAv(:), EIv(:), rhoAv(:), wv(:), seed(:), curv(:)
    INTEGER, ALLOCATABLE :: fixed(:)
    REAL(wp) :: kend(2), dend(3, 2), res
    INTEGER :: es, iters, nn
    CHARACTER(300) :: em
    nn = NE + 1
    CALL build(with_conn, l0, EAv, EIv, rhoAv, wv, seed, fixed)
    ALLOCATE (q_out(6*nn), curv(nn))
    kend = [KROT, 0.0_wp]
    dend = 0.0_wp; dend(1, 1) = 1.0_wp; dend(1, 2) = 1.0_wp
    IF (with_conn) THEN
      CALL CD_HermiteCable_Static_Solve(l0, EAv, EIv, wv, seed, fixed, -1.0e3_wp, 0.0_wp, &
                                        1, 120, STOL, 1.0_wp, q_out, curv, res, iters, es, em, &
                                        endconn_stiffness=kend, endconn_direction=dend)
    ELSE
      CALL CD_HermiteCable_Static_Solve(l0, EAv, EIv, wv, seed, fixed, -1.0e3_wp, 0.0_wp, &
                                        1, 120, STOL, 1.0_wp, q_out, curv, res, iters, es, em)
    END IF
    IF (es /= CD_HCSTAT_OK) THEN
      WRITE (*, '(A,A)') 'FAIL: static seed solve: ', TRIM(em)
      ERROR STOP 1
    END IF
  END SUBROUTINE solve_static

  SUBROUTINE march(q_seed, free_tangent, attach, drift)
    REAL(wp), INTENT(IN) :: q_seed(:)
    LOGICAL, INTENT(IN) :: free_tangent, attach
    REAL(wp), INTENT(OUT) :: drift
    TYPE(CD_HermiteCableDynType) :: m
    REAL(wp), ALLOCATABLE :: l0(:), EAv(:), EIv(:), rhoAv(:), wv(:), seed(:)
    INTEGER, ALLOCATABLE :: fixed(:)
    REAL(wp) :: kend(2), dend(3, 2)
    INTEGER :: es, i
    CHARACTER(300) :: em
    CALL build(free_tangent, l0, EAv, EIv, rhoAv, wv, seed, fixed)
    CALL CD_HermiteCable_Dyn_Init(m, l0, EAv, EIv, rhoAv, wv, q_seed, fixed, &
                                  -1.0e3_wp, 0.0_wp, 0.9_wp, es, em)
    IF (es /= CD_HCDYN_OK) THEN
      WRITE (*, '(A,A)') 'FAIL: dynamic init: ', TRIM(em)
      ERROR STOP 1
    END IF
    IF (attach) THEN
      kend = [KROT, 0.0_wp]
      dend = 0.0_wp; dend(1, 1) = 1.0_wp; dend(1, 2) = 1.0_wp
      CALL CD_HermiteCable_Dyn_Set_EndConnection(m, kend, dend, es, em)
      IF (es /= CD_HCDYN_OK) THEN
        WRITE (*, '(A,A)') 'FAIL: set end connection: ', TRIM(em)
        ERROR STOP 1
      END IF
    END IF
    drift = 0.0_wp
    DO i = 1, NSTEP
      CALL CD_HermiteCable_Dyn_Step(m, DT, 30, DTOL, es, em)
      IF (es /= CD_HCDYN_OK) THEN
        nfail = nfail + 1
        WRITE (*, '(A,I0,A,A)') 'FAIL: dynamic march failed at step ', i, ': ', TRIM(em)
        drift = HUGE(1.0_wp)
        RETURN
      END IF
      drift = MAX(drift, nan_max_abs(m%q - q_seed))
    END DO
  END SUBROUTINE march

  SUBROUTINE case_rigid_moving()
    !! A rigid connection is a moving holonomic direction constraint, not a
    !! high-stiffness spring.  Start from its exact static equilibrium, rotate
    !! the preferred direction, verify the endpoint lands on that direction,
    !! recover a finite support moment, and prove snapshot rollback includes d0.
    TYPE(CD_HermiteCableDynType) :: m
    REAL(wp), ALLOCATABLE :: l0(:), EAv(:), EIv(:), rhoAv(:), wv(:), seed(:), qstat(:), curv(:)
    INTEGER, ALLOCATABLE :: fixed(:)
    INTEGER :: nn, i, kk, es, iters
    INTEGER :: mode(2)
    REAL(wp) :: le, res, target(3, 2), kend(2), dstart(3, 2), tangent(3), tn, moment(3)
    REAL(wp) :: direction_rate(3, 2), direction_acceleration(3, 2)
    REAL(wp) :: q_before(6*(NE + 1)), d0_before(3, 2), direction_error
    CHARACTER(300) :: em

    nn = NE + 1
    le = L/REAL(NE, wp)
    ALLOCATE (l0(NE), EAv(NE), EIv(NE), rhoAv(NE), wv(NE), seed(6*nn), qstat(6*nn), curv(nn))
    l0 = le; EAv = EA; EIv = EI; rhoAv = RHOA; wv = WGT; seed = 0.0_wp
    DO i = 1, nn
      seed(6*(i - 1) + 1) = REAL(i - 1, wp)*le
      seed(6*(i - 1) + 4) = 1.0_wp
    END DO
    ALLOCATE (fixed(3 + nn + nn - 1))
    fixed(1:3) = [1, 2, 3]
    kk = 3
    DO i = 1, nn
      kk = kk + 1; fixed(kk) = 6*(i - 1) + 2
      IF (i == 1) CYCLE
      kk = kk + 1; fixed(kk) = 6*(i - 1) + 5
    END DO
    kend = 0.0_wp
    dstart = 0.0_wp; dstart(1, :) = 1.0_wp
    mode = [CD_ENDCONN_RIGID, CD_ENDCONN_PINNED]
    CALL CD_HermiteCable_Static_Solve(l0, EAv, EIv, wv, seed, fixed, -1.0e3_wp, 0.0_wp, &
                                      1, 120, STOL, 1.0_wp, qstat, curv, res, iters, es, em, &
                                      endconn_stiffness=kend, endconn_direction=dstart, endconn_mode=mode)
    IF (es /= CD_HCSTAT_OK) THEN
      nfail = nfail + 1
      WRITE (*, '(A,A)') 'FAIL: rigid static seed: ', TRIM(em)
      RETURN
    END IF
    CALL CD_HermiteCable_Dyn_Init(m, l0, EAv, EIv, rhoAv, wv, qstat, fixed, &
                                  -1.0e3_wp, 0.0_wp, 0.9_wp, es, em)
    IF (es /= CD_HCDYN_OK) THEN
      nfail = nfail + 1
      WRITE (*, '(A,A)') 'FAIL: rigid dynamic init: ', TRIM(em)
      RETURN
    END IF
    CALL CD_HermiteCable_Dyn_Set_EndConnection(m, kend, dstart, es, em, connection_mode=mode)
    IF (es /= CD_HCDYN_OK) THEN
      nfail = nfail + 1
      WRITE (*, '(A,A)') 'FAIL: rigid dynamic setter: ', TRIM(em)
      RETURN
    END IF
    CALL CD_HermiteCable_Dyn_Snapshot(m, es, em)
    q_before = m%q
    d0_before = m%endconn_d0
    target = dstart
    target(:, 1) = [COS(1.0e-4_wp), 0.0_wp, SIN(1.0e-4_wp)]
    direction_rate = 0.0_wp
    CALL CD_HermiteCable_Dyn_Step(m, DT, 50, DTOL, es, em, endconn_direction=target, &
                                  endconn_direction_rate=direction_rate)
    IF (es == CD_HCDYN_OK .OR. .NOT. (nan_max_abs(m%q - q_before) <= 0.0_wp) .OR. &
        .NOT. (nan_max_abs(m%endconn_d0 - d0_before) <= 0.0_wp)) THEN
      nfail = nfail + 1
      WRITE (*, '(A)') 'FAIL: partial rigid direction derivatives must fail atomically'
    END IF
    direction_acceleration = 0.0_wp
    direction_rate(:, 1) = target(:, 1)
    CALL CD_HermiteCable_Dyn_Step(m, DT, 50, DTOL, es, em, endconn_direction=target, &
                                  endconn_direction_rate=direction_rate, &
                                  endconn_direction_acceleration=direction_acceleration)
    IF (es == CD_HCDYN_OK .OR. INDEX(em, 'unit-vector kinematics') == 0 .OR. &
        .NOT. (nan_max_abs(m%q - q_before) <= 0.0_wp) .OR. .NOT. (nan_max_abs(m%endconn_d0 - d0_before) <= 0.0_wp)) THEN
      nfail = nfail + 1
      WRITE (*, '(A)') 'FAIL: inconsistent rigid direction derivatives must fail atomically'
    END IF
    CALL CD_HermiteCable_Dyn_Step(m, DT, 50, DTOL, es, em, endconn_direction=target)
    IF (es /= CD_HCDYN_OK) THEN
      nfail = nfail + 1
      WRITE (*, '(A,A)') 'FAIL: moving rigid step: ', TRIM(em)
      RETURN
    END IF
    tangent = m%q(4:6)
    tn = SQRT(DOT_PRODUCT(tangent, tangent))
    direction_error = SQRT(DOT_PRODUCT(tangent/tn - target(:, 1), tangent/tn - target(:, 1)))
    IF (.NOT. (direction_error <= 128.0_wp*EPSILON(1.0_wp))) THEN
      nfail = nfail + 1
      WRITE (*, '(A,ES13.6)') 'FAIL: rigid target direction error=', direction_error
    END IF
    CALL CD_HermiteCable_Dyn_EndConnection_Moment(m, 1, moment, es, em)
    IF (es /= CD_HCDYN_OK .OR. .NOT. ALL(IEEE_IS_FINITE(moment)) .OR. nan_max_abs(moment) <= 0.0_wp) THEN
      nfail = nfail + 1
      WRITE (*, '(A,A)') 'FAIL: rigid reaction moment: ', TRIM(em)
    END IF
    CALL CD_HermiteCable_Dyn_Restore(m, es, em)
    IF (es /= CD_HCDYN_OK .OR. .NOT. (nan_max_abs(m%q - q_before) <= 0.0_wp) .OR. &
        .NOT. (nan_max_abs(m%endconn_d0 - d0_before) <= 0.0_wp)) THEN
      nfail = nfail + 1
      WRITE (*, '(A)') 'FAIL: rigid snapshot restore must be exact'
    END IF

    target = dstart
    target(:, 1) = -dstart(:, 1)
    CALL CD_HermiteCable_Dyn_Step(m, DT, 50, DTOL, es, em, endconn_direction=target)
    IF (es == CD_HCDYN_OK .OR. .NOT. (nan_max_abs(m%q - q_before) <= 0.0_wp) .OR. &
        .NOT. (nan_max_abs(m%endconn_d0 - d0_before) <= 0.0_wp)) THEN
      nfail = nfail + 1
      WRITE (*, '(A)') 'FAIL: singular rigid direction jump must fail atomically'
    END IF
  END SUBROUTINE case_rigid_moving

END PROGRAM test_endconn_dynamic
