! File: tests/test_prescribed_motion.f90
! SPDX-License-Identifier: Apache-2.0
! Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
PROGRAM test_prescribed_motion
  !! Gate for prescribed (time-varying Dirichlet) motion in the EI=0 generalised-alpha
  !! step (CableDyn_Dynamic). The optional prescribed_q/v/a drive the fixed DOFs along
  !! a known trajectory at t_{n+1} -- a moving support / fairlead -- and their
  !! prescribed acceleration couples into the free-DOF residual through M a. Checks:
  !!   1. static reduction: prescribing the at-rest hold (q = q_n, v = a = 0) is
  !!      BIT-FOR-BIT the same as the default (no prescribed args).
  !!   2. kinematics honoured: the output state carries the prescribed q/v/a exactly.
  !!   3. rigid translation (Galilean invariance): a cable moving uniformly at V with
  !!      both ends prescribed to keep translating at V advances rigidly -- every node
  !!      shifts by V dt, velocity stays V, acceleration ~ 0, strains unchanged.
  !!   4. momentum injection: a moving end excites an at-rest line (nonzero interior
  !!      velocity) where an all-static step leaves it at rest.
  !!   5. fail-closed: a partial prescribed set, or a wrong shape, is rejected.
  USE CableDyn_Precision, ONLY: wp
  USE CableDyn_Dynamic, ONLY: GenAlphaConfig, CD_Cable_Gen_Alpha_Step, CD_DYN_OK, CD_DYN_BADINPUT
  USE CableDyn_Loads, ONLY: CD_Assemble_Distributed_Load
  IMPLICIT NONE

  INTEGER :: nfail
  nfail = 0

  CALL case_static_reduces_to_default()
  CALL case_kinematics_honored()
  CALL case_rigid_translation()
  CALL case_momentum_injection()
  CALL case_fail_closed()

  IF (nfail > 0) THEN
    WRITE (*, '(A,I0,A)') 'FAIL: ', nfail, ' assertion(s) failed'
    ERROR STOP 1
  END IF
  WRITE (*, '(A)') 'PASS: prescribed-motion (time-varying Dirichlet) generalised-alpha step'

CONTAINS

  INCLUDE 'nan_max_abs.inc'

  SUBROUTINE straight_cable(ne, conn, l0, ea, rho_a, q0)
    !! ne elements along +x at unit spacing, PRE-TENSIONED (rest length 0.95 < spacing
    !! 1.0, ~5% strain). The uniform pretension gives the transverse DOFs a finite
    !! geometric stiffness ~ T/L0 > 0 -- without it a zero-tension straight cable has a
    !! singular y/z tangent (the EI=0 cable carries no transverse stiffness slack). A
    !! straight uniformly-tensioned cable is in equilibrium at rest (the axial pulls
    !! balance at every interior node), so the no-gravity cases start at a fixed point.
    INTEGER, INTENT(IN)  :: ne
    INTEGER, INTENT(OUT) :: conn(2, ne)
    REAL(wp), INTENT(OUT) :: l0(ne), ea(ne), rho_a(ne), q0(3*(ne + 1))
    INTEGER :: e, i
    DO e = 1, ne
      conn(:, e) = [e, e + 1]
      l0(e) = 0.95_wp; ea(e) = 1.0e6_wp; rho_a(e) = 10.0_wp
    END DO
    DO i = 1, ne + 1
      q0(3*i - 2:3*i) = [REAL(i - 1, wp), 0.0_wp, 0.0_wp]
    END DO
  END SUBROUTINE straight_cable

  SUBROUTINE case_static_reduces_to_default()
    !! Prescribing the static hold (q = q_n, v = a = 0 at the fixed ends) is bit-for-bit
    !! identical to the default no-prescribed-args step, under gravity.
    INTEGER, PARAMETER :: NE = 4, NN = NE + 1, NDOF = 3*NN
    INTEGER :: conn(2, NE), fixed(6), es, n_iter, i
    REAL(wp) :: l0(NE), ea(NE), rho_a(NE), q0(NDOF), f_ext(NDOF), load(3, NE)
    REAL(wp) :: q(NDOF), vel(NDOF), acc(NDOF)
    REAL(wp) :: qd(NDOF), vd(NDOF), ad(NDOF), qp(NDOF), vp(NDOF), ap(NDOF)
    REAL(wp) :: pq(NDOF), pv(NDOF), pa(NDOF)
    LOGICAL  :: conv, st
    TYPE(GenAlphaConfig) :: cfg
    CHARACTER(160) :: em
    CALL straight_cable(NE, conn, l0, ea, rho_a, q0)
    DO i = 1, NE
      load(:, i) = [0.0_wp, 0.0_wp, -50.0_wp]
    END DO
    CALL CD_Assemble_Distributed_Load(conn, l0, load, f_ext, es, em)
    CALL require(es == 0, 'static-reduce:fext')
    fixed = [1, 2, 3, NDOF - 2, NDOF - 1, NDOF]
    q = q0; vel = 0.0_wp; acc = 0.0_wp
    ! default (no prescribed args)
    CALL CD_Cable_Gen_Alpha_Step(q, vel, acc, conn, l0, ea, rho_a, .FALSE., f_ext, fixed, &
                                 0.01_wp, cfg, qd, vd, ad, conv, st, n_iter, es, em)
    CALL require(es == CD_DYN_OK .AND. conv, 'static-reduce:default-ok')
    ! prescribed = the static hold (ends at q_n, zero v/a)
    pq = q0; pv = 0.0_wp; pa = 0.0_wp
    CALL CD_Cable_Gen_Alpha_Step(q, vel, acc, conn, l0, ea, rho_a, .FALSE., f_ext, fixed, &
                                 0.01_wp, cfg, qp, vp, ap, conv, st, n_iter, es, em, &
                                 prescribed_q=pq, prescribed_v=pv, prescribed_a=pa)
    CALL require(es == CD_DYN_OK .AND. conv, 'static-reduce:prescribed-ok')
    ! ABS(.) >= 0, so "<= 0" is an exact bit-for-bit check without a real-equality compare
    CALL require(nan_max_abs(qp - qd) <= 0.0_wp .AND. nan_max_abs(vp - vd) <= 0.0_wp .AND. &
                 nan_max_abs(ap - ad) <= 0.0_wp, 'static-reduce:bit-for-bit')
  END SUBROUTINE case_static_reduces_to_default

  SUBROUTINE case_kinematics_honored()
    !! The output state carries the prescribed q/v/a at the fixed DOFs exactly.
    INTEGER, PARAMETER :: NE = 4, NN = NE + 1, NDOF = 3*NN
    INTEGER :: conn(2, NE), fixed(6), es, n_iter
    REAL(wp) :: l0(NE), ea(NE), rho_a(NE), q0(NDOF), f_ext(NDOF)
    REAL(wp) :: q(NDOF), vel(NDOF), acc(NDOF), q_new(NDOF), v_new(NDOF), a_new(NDOF)
    REAL(wp) :: pq(NDOF), pv(NDOF), pa(NDOF)
    LOGICAL  :: conv, st
    TYPE(GenAlphaConfig) :: cfg
    CHARACTER(160) :: em
    CALL straight_cable(NE, conn, l0, ea, rho_a, q0)
    f_ext = 0.0_wp
    fixed = [1, 2, 3, NDOF - 2, NDOF - 1, NDOF]
    q = q0; vel = 0.0_wp; acc = 0.0_wp
    pq = q0; pv = 0.0_wp; pa = 0.0_wp
    ! drive the fairlead node (last) up with a velocity and acceleration
    pq(NDOF) = q0(NDOF) + 0.05_wp     ! z displacement
    pv(NDOF) = 0.7_wp                  ! z velocity
    pa(NDOF) = 1.3_wp                  ! z acceleration
    CALL CD_Cable_Gen_Alpha_Step(q, vel, acc, conn, l0, ea, rho_a, .FALSE., f_ext, fixed, &
                                 0.02_wp, cfg, q_new, v_new, a_new, conv, st, n_iter, es, em, &
                                 prescribed_q=pq, prescribed_v=pv, prescribed_a=pa)
    CALL require(es == CD_DYN_OK .AND. conv, 'kinematics:ok')
    CALL require(ABS(q_new(NDOF) - pq(NDOF)) < 1.0e-12_wp, 'kinematics:q-honored')
    CALL require(ABS(v_new(NDOF) - pv(NDOF)) < 1.0e-12_wp, 'kinematics:v-honored')
    CALL require(ABS(a_new(NDOF) - pa(NDOF)) < 1.0e-12_wp, 'kinematics:a-honored')
    ! the held anchor end stays put
    CALL require(nan_max_abs(q_new(1:3) - q0(1:3)) < 1.0e-12_wp, 'kinematics:anchor-held')
    CALL require(nan_max_abs(v_new(1:3)) < 1.0e-12_wp, 'kinematics:anchor-vzero')
  END SUBROUTINE case_kinematics_honored

  SUBROUTINE case_rigid_translation()
    !! Galilean invariance: a step taken in a frame translating uniformly at V (the
    !! whole line boosted by V in x, both ends prescribed to keep translating at V)
    !! equals the rest-frame step plus the uniform translation. The equations of
    !! motion are translation-invariant (f_int(q + shift) = f_int(q), gravity
    !! unchanged), so q_boost = q_rest + V dt, v_boost = v_rest + V, a_boost = a_rest.
    !! Both steps run under gravity, so the residual scale is well defined and the
    !! solve converges (a pure f_ext = 0 equilibrium step would be scale-degenerate).
    INTEGER, PARAMETER :: NE = 4, NN = NE + 1, NDOF = 3*NN
    INTEGER :: conn(2, NE), fixed(6), es, n_iter, i
    REAL(wp) :: l0(NE), ea(NE), rho_a(NE), q0(NDOF), f_ext(NDOF), load(3, NE)
    REAL(wp) :: q(NDOF), vel(NDOF), acc(NDOF), vmag, dt
    REAL(wp) :: q_rest(NDOF), v_rest(NDOF), a_rest(NDOF), q_b(NDOF), v_b(NDOF), a_b(NDOF)
    REAL(wp) :: pq(NDOF), pv(NDOF), pa(NDOF)
    LOGICAL  :: conv, st
    TYPE(GenAlphaConfig) :: cfg
    CHARACTER(160) :: em
    CALL straight_cable(NE, conn, l0, ea, rho_a, q0)
    DO i = 1, NE
      load(:, i) = [0.0_wp, 0.0_wp, -50.0_wp]
    END DO
    CALL CD_Assemble_Distributed_Load(conn, l0, load, f_ext, es, em)
    CALL require(es == 0, 'rigid:fext')
    fixed = [1, 2, 3, NDOF - 2, NDOF - 1, NDOF]
    vmag = 2.0_wp; dt = 0.05_wp

    ! rest-frame step: line at rest, ends fixed (default static hold)
    q = q0; vel = 0.0_wp; acc = 0.0_wp
    CALL CD_Cable_Gen_Alpha_Step(q, vel, acc, conn, l0, ea, rho_a, .FALSE., f_ext, fixed, &
                                 dt, cfg, q_rest, v_rest, a_rest, conv, st, n_iter, es, em)
    CALL require(es == CD_DYN_OK .AND. conv, 'rigid:rest-ok')

    ! boosted-frame step: whole line moving at V in +x, ends prescribed to translate at V
    vel = 0.0_wp; vel(1:NDOF:3) = vmag
    acc = 0.0_wp
    pq = q0; pv = 0.0_wp; pa = 0.0_wp
    pv(1:NDOF:3) = vmag
    pq(1) = q0(1) + vmag*dt; pq(NDOF - 2) = q0(NDOF - 2) + vmag*dt
    CALL CD_Cable_Gen_Alpha_Step(q, vel, acc, conn, l0, ea, rho_a, .FALSE., f_ext, fixed, &
                                 dt, cfg, q_b, v_b, a_b, conv, st, n_iter, es, em, &
                                 prescribed_q=pq, prescribed_v=pv, prescribed_a=pa)
    CALL require(es == CD_DYN_OK .AND. conv, 'rigid:boost-ok')

    ! Galilean invariance: boost = rest + uniform translation (x only)
    DO i = 1, NN
      CALL require(ABS(q_b(3*i - 2) - (q_rest(3*i - 2) + vmag*dt)) < 1.0e-7_wp, 'rigid:x-shift')
      CALL require(ABS(q_b(3*i - 1) - q_rest(3*i - 1)) < 1.0e-7_wp .AND. &
                   ABS(q_b(3*i) - q_rest(3*i)) < 1.0e-7_wp, 'rigid:yz-invariant')
    END DO
    CALL require(nan_max_abs(v_b(1:NDOF:3) - (v_rest(1:NDOF:3) + vmag)) < 1.0e-7_wp, 'rigid:vx-boosted')
    CALL require(nan_max_abs(a_b - a_rest) < 1.0e-6_wp, 'rigid:a-invariant')
  END SUBROUTINE case_rigid_translation

  SUBROUTINE case_momentum_injection()
    !! A moving end excites an at-rest line: prescribing the fairlead to heave gives
    !! nonzero interior velocity, where an all-static step leaves the interior at rest.
    INTEGER, PARAMETER :: NE = 4, NN = NE + 1, NDOF = 3*NN
    INTEGER :: conn(2, NE), fixed(6), es, n_iter
    REAL(wp) :: l0(NE), ea(NE), rho_a(NE), q0(NDOF), f_ext(NDOF)
    REAL(wp) :: q(NDOF), vel(NDOF), acc(NDOF)
    REAL(wp) :: qs(NDOF), vs(NDOF), as_(NDOF), qm(NDOF), vm(NDOF), am(NDOF)
    REAL(wp) :: pqs(NDOF), pqm(NDOF), pv(NDOF), pa(NDOF), interior_static, interior_moving
    LOGICAL  :: conv, st
    TYPE(GenAlphaConfig) :: cfg
    CHARACTER(160) :: em
    CALL straight_cable(NE, conn, l0, ea, rho_a, q0)
    f_ext = 0.0_wp
    fixed = [1, 2, 3, NDOF - 2, NDOF - 1, NDOF]
    q = q0; vel = 0.0_wp; acc = 0.0_wp
    ! all-static: both ends held, line at rest -> stays at rest
    pqs = q0; pv = 0.0_wp; pa = 0.0_wp
    CALL CD_Cable_Gen_Alpha_Step(q, vel, acc, conn, l0, ea, rho_a, .FALSE., f_ext, fixed, &
                                 0.02_wp, cfg, qs, vs, as_, conv, st, n_iter, es, em, &
                                 prescribed_q=pqs, prescribed_v=pv, prescribed_a=pa)
    CALL require(es == CD_DYN_OK .AND. conv, 'momentum:static-ok')
    interior_static = nan_max_abs(vs(4:NDOF - 3))
    CALL require(interior_static < 1.0e-9_wp, 'momentum:static-interior-at-rest')
    ! moving fairlead: heave the last node up in z with a velocity
    pqm = q0; pqm(NDOF) = q0(NDOF) + 0.02_wp
    pv = 0.0_wp; pv(NDOF) = 1.0_wp
    pa = 0.0_wp
    CALL CD_Cable_Gen_Alpha_Step(q, vel, acc, conn, l0, ea, rho_a, .FALSE., f_ext, fixed, &
                                 0.02_wp, cfg, qm, vm, am, conv, st, n_iter, es, em, &
                                 prescribed_q=pqm, prescribed_v=pv, prescribed_a=pa)
    CALL require(es == CD_DYN_OK .AND. conv, 'momentum:moving-ok')
    interior_moving = nan_max_abs(vm(4:NDOF - 3))
    CALL require(interior_moving > 1.0e-3_wp, 'momentum:moving-excites-interior')
  END SUBROUTINE case_momentum_injection

  SUBROUTINE case_fail_closed()
    !! A partial prescribed set (only q) and a wrong-shaped prescribed array fail closed.
    INTEGER, PARAMETER :: NE = 4, NN = NE + 1, NDOF = 3*NN
    INTEGER :: conn(2, NE), fixed(6), es, n_iter
    REAL(wp) :: l0(NE), ea(NE), rho_a(NE), q0(NDOF), f_ext(NDOF)
    REAL(wp) :: q(NDOF), vel(NDOF), acc(NDOF), q_new(NDOF), v_new(NDOF), a_new(NDOF)
    REAL(wp) :: pq(NDOF), pv(NDOF), pa(NDOF)
    LOGICAL  :: conv, st
    TYPE(GenAlphaConfig) :: cfg
    CHARACTER(160) :: em
    CALL straight_cable(NE, conn, l0, ea, rho_a, q0)
    f_ext = 0.0_wp
    fixed = [1, 2, 3, NDOF - 2, NDOF - 1, NDOF]
    q = q0; vel = 0.0_wp; acc = 0.0_wp
    pq = q0; pv = 0.0_wp; pa = 0.0_wp
    ! only prescribed_q (missing v and a) -> reject
    CALL CD_Cable_Gen_Alpha_Step(q, vel, acc, conn, l0, ea, rho_a, .FALSE., f_ext, fixed, &
                                 0.02_wp, cfg, q_new, v_new, a_new, conv, st, n_iter, es, em, &
                                 prescribed_q=pq)
    CALL require(es == CD_DYN_BADINPUT, 'fail:partial-prescribed')
    ! wrong shape -> reject
    BLOCK
      REAL(wp) :: pq_bad(NDOF - 1)
      pq_bad = 0.0_wp
      CALL CD_Cable_Gen_Alpha_Step(q, vel, acc, conn, l0, ea, rho_a, .FALSE., f_ext, fixed, &
                                   0.02_wp, cfg, q_new, v_new, a_new, conv, st, n_iter, es, em, &
                                   prescribed_q=pq_bad, prescribed_v=pv, prescribed_a=pa)
      CALL require(es == CD_DYN_BADINPUT, 'fail:wrong-shape')
    END BLOCK
  END SUBROUTINE case_fail_closed

  SUBROUTINE require(cond, label)
    LOGICAL, INTENT(IN) :: cond
    CHARACTER(*), INTENT(IN) :: label
    IF (.NOT. cond) THEN
      WRITE (*, '(A,A,A)') 'MISMATCH [', label, ']: condition false'
      nfail = nfail + 1
    END IF
  END SUBROUTINE require

END PROGRAM test_prescribed_motion
